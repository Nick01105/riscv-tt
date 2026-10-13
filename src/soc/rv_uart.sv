// rv_uart - 8N1 UART. One bit lasts div + 1 clock cycles.
//   +0 data   write: transmit (ignored while busy); read: received byte, 0 if none
//              (reading clears rx valid)
//   +4 status bit 0 transmitter ready, bit 1 received byte valid
//   +8 divisor (16 bits), reset value DIV_RESET
// The receiver samples mid-bit after a 2-flop synchronizer; a new byte
// overwrites an unread one.
module rv_uart #(
  parameter logic [15:0] DIV_RESET = 16'd216       // 115200 baud at 25 MHz
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [1:0]  reg_i,         // 0 data, 1 status, 2 divisor
  input  logic        re_i,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic        tx_o,
  input  logic        rx_i
);
  logic [15:0] div_q;

  // ---- transmitter ---------------------------------------------------------------
  logic [9:0]  tx_sh_q;
  logic [3:0]  tx_bits_q;
  logic [15:0] tx_cnt_q;
  logic        tx_busy;
  assign tx_busy = (tx_bits_q != 4'd0);

  // ---- receiver ------------------------------------------------------------------
  logic [1:0]  rx_sync_q;
  logic        rx_s;
  logic [3:0]  rx_bits_q;            // 0 idle, 1-8 data, 9 stop (10 = start)
  logic [15:0] rx_cnt_q;
  logic [7:0]  rx_sh_q, rx_buf_q;
  logic        rx_valid_q;
  assign rx_s = rx_sync_q[1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_q      <= DIV_RESET;
      tx_sh_q    <= '1;
      tx_bits_q  <= '0;
      tx_cnt_q   <= '0;
      rx_sync_q  <= 2'b11;
      rx_bits_q  <= '0;
      rx_cnt_q   <= '0;
      rx_valid_q <= 1'b0;
      rx_buf_q   <= '0;
    end else begin
      // registers
      if (we_i && reg_i == 2'd2) div_q <= wdata_i[15:0];
      if (we_i && reg_i == 2'd0 && !tx_busy) begin
        tx_sh_q   <= {1'b1, wdata_i[7:0], 1'b0};
        tx_bits_q <= 4'd10;
        tx_cnt_q  <= div_q;
      end else if (tx_busy) begin
        if (tx_cnt_q == 16'd0) begin
          tx_sh_q   <= {1'b1, tx_sh_q[9:1]};
          tx_bits_q <= tx_bits_q - 4'd1;
          tx_cnt_q  <= div_q;
        end else begin
          tx_cnt_q <= tx_cnt_q - 16'd1;
        end
      end
      if (re_i && reg_i == 2'd0) rx_valid_q <= 1'b0;

      // receiver
      rx_sync_q <= {rx_sync_q[0], rx_i};
      if (rx_bits_q == 4'd0) begin
        if (!rx_s) begin                               // start bit: go to its middle
          rx_bits_q <= 4'd10;
          rx_cnt_q  <= {1'b0, div_q[15:1]};
        end
      end else if (rx_cnt_q != 16'd0) begin
        rx_cnt_q <= rx_cnt_q - 16'd1;
      end else begin
        rx_cnt_q <= div_q;
        if (rx_bits_q == 4'd10) begin
          rx_bits_q <= rx_s ? 4'd0 : 4'd1;              // false start: back to idle
        end else if (rx_bits_q == 4'd9) begin
          rx_bits_q <= 4'd0;
          if (rx_s) begin                              // valid stop bit
            rx_buf_q   <= rx_sh_q;
            rx_valid_q <= 1'b1;
          end
        end else begin
          rx_sh_q   <= {rx_s, rx_sh_q[7:1]};           // LSB first
          rx_bits_q <= rx_bits_q + 4'd1;
        end
      end
    end
  end

  always_comb begin
    case (reg_i)
      2'd0:    rdata_o = {24'b0, rx_valid_q ? rx_buf_q : 8'h00};
      2'd1:    rdata_o = {30'b0, rx_valid_q, !tx_busy};
      default: rdata_o = {16'b0, div_q};
    endcase
  end

  assign tx_o = tx_sh_q[0];

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^wdata_i[31:16];
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
