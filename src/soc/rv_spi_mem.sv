// rv_spi_mem - SPI memory controller for the TT QSPI Pmod: one flash and
// two PSRAMs on a shared bus, plain single-bit SPI (mode 0).
//
//   flash   0x0000_0000-0x00FF_FFFF  CS0  read 0x03 (writes: error)
//   PSRAM A 0x0100_0000-0x017F_FFFF  CS1  read 0x03, write 0x02
//   PSRAM B 0x0180_0000-0x01FF_FFFF  CS2  read 0x03, write 0x02
// Anything else returns an error (SLVERR beats / d_err_o) without SPI traffic.
//
// Two clients, one transaction at a time, the data port first:
// * fetch: AXI4 read bursts of 32-bit beats, INCR or WRAP. A WRAP burst that
//   starts mid-line reads to the end of the line, then issues a second
//   command for the start of the line (critical word first).
//   SCK stops while an R beat waits for r_ready.
// * data: one access, read of the aligned word or a write of the enabled
//   bytes (contiguous, as aligned RISC-V stores are).
//
// SCK = clk / (2 * DIV). MOSI changes after the falling edge; MISO is
// sampled at the end of the high phase, just before the falling edge.
// CS stays low one cycle after the last SCK edge, then high for GAP cycles
// between transactions (PSRAM tCPH).
module rv_spi_mem #(
  parameter int DIV = 1,
  parameter int GAP = 2
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // fetch (AXI4 read)
  input  logic                   ar_valid_i,
  output logic                   ar_ready_o,
  input  frontend_pkg::axi_ar_t  ar_i,
  output logic                   r_valid_o,
  input  logic                   r_ready_i,
  output frontend_pkg::axi_r_t   r_o,
  // data
  input  logic                   d_valid_i,
  output logic                   d_ready_o,
  input  logic [31:0]            d_addr_i,
  input  logic                   d_we_i,
  input  logic [3:0]             d_be_i,
  input  logic [31:0]            d_wdata_i,
  output logic                   d_rsp_valid_o,
  output logic [31:0]            d_rdata_o,
  output logic                   d_err_o,
  // SPI pins
  output logic                   sck_o,
  output logic                   mosi_o,
  input  logic                   miso_i,
  output logic [2:0]             cs_n_o
);
  localparam int IDW = frontend_pkg::AXI_ID_W;
  localparam int DCW = (DIV > 1) ? $clog2(DIV) : 1;
  localparam int GCW = $clog2(GAP + 2);

  typedef enum logic [2:0] {S_IDLE, S_CMD, S_RD, S_WR, S_BEAT, S_ERR, S_GAP} st_e;
  logic [2:0] st_q;                      // st_e values (plain logic: Yosys rule)

  logic           fetch_q, err_q;
  logic [IDW-1:0] id_q;
  logic [3:0]     beats_q;               // beats left after the current one
  logic [23:0]    addr_q;                // device address of the next byte to read
  logic [23:0]    wrap_q;                // wrap mask (bytes in the burst - 1), 0 = INCR
  logic [2:0]     cs_q;                  // one-hot device select
  logic [31:0]    sh_q;                  // output shift register (MSB first)
  logic [5:0]     bits_q;                // bits left in this phase
  logic [31:0]    word_q;                // assembled read word (little endian)
  logic [1:0]     byte_q;                // byte index within word_q
  logic [2:0]     bit_q;                 // bit index within the byte
  logic [2:0]     wbytes_q;              // bytes to write
  logic           sck_q, mosi_q;
  logic [DCW-1:0] div_q;
  logic [GCW-1:0] gap_q;
  logic           rsp_q;
  logic [2:0]     cs_line_q;             // device of the current fetch (wrap restart)
  logic           restart_q;

  // ---- decode -------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [2:0] cs_of(input logic [31:0] a);
    if (a[31:24] == 8'h00)      cs_of = 3'b001;
    else if (a[31:24] == 8'h01) cs_of = a[23] ? 3'b100 : 3'b010;
    else                        cs_of = 3'b000;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [23:0] dev_of(input logic [31:0] a);
    dev_of = (a[31:24] == 8'h00) ? a[23:0] : {1'b0, a[22:0]};
  endfunction

  // first enabled byte and number of enabled bytes
  logic [1:0] be_first;
  logic [2:0] be_count;
  always_comb begin
    be_first = 2'd0;
    for (int i = 3; i >= 0; i--) if (d_be_i[i]) be_first = 2'(i);
    be_count = 3'(d_be_i[0]) + 3'(d_be_i[1]) + 3'(d_be_i[2]) + 3'(d_be_i[3]);
  end

  logic [2:0]  d_cs, f_cs;
  logic [23:0] d_dev_w, d_dev_r, f_dev;
  logic        d_bad;
  assign d_cs    = cs_of(d_addr_i);
  assign f_cs    = cs_of(ar_i.addr[31:0]);
  assign d_dev_w = dev_of({d_addr_i[31:2], be_first});
  assign d_dev_r = dev_of({d_addr_i[31:2], 2'b00});
  assign f_dev   = dev_of({ar_i.addr[31:2], 2'b00});
  assign d_bad   = (d_cs == 3'b000) || (d_we_i && d_cs == 3'b001);

  assign d_ready_o  = (st_q == S_IDLE);
  assign ar_ready_o = (st_q == S_IDLE) && !d_valid_i;

  // ---- SPI bit clock -----------------------------------------------------------------
  logic shifting, tick, fall, rise;
  assign shifting = (st_q == S_CMD) || (st_q == S_RD) || (st_q == S_WR);
  assign tick     = shifting && (div_q == DCW'(DIV - 1));
  assign fall     = tick && sck_q;       // end of a bit: sample MISO, next MOSI
  assign rise     = tick && !sck_q;

  logic [23:0] next_addr;
  assign next_addr = (wrap_q != 0) ? ((addr_q & ~wrap_q) | ((addr_q + 24'd4) & wrap_q)) : (addr_q + 24'd4);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st_q   <= S_IDLE;
      sck_q  <= 1'b0;
      mosi_q <= 1'b0;
      cs_q   <= 3'b000;
      div_q  <= '0;
      rsp_q  <= 1'b0;
      restart_q <= 1'b0;
    end else begin
      rsp_q <= 1'b0;
      if (shifting) div_q <= tick ? '0 : div_q + 1'b1;
      else          div_q <= '0;
      if (rise) sck_q <= 1'b1;
      if (fall) sck_q <= 1'b0;

      case (st_q)
        S_IDLE: begin
          if (d_valid_i) begin
            fetch_q <= 1'b0;
            err_q   <= d_bad;
            if (d_bad) begin
              rsp_q <= 1'b1;                                   // error, no SPI traffic
            end else begin
              cs_q     <= d_cs;
              sh_q     <= {d_we_i ? 8'h02 : 8'h03, d_we_i ? d_dev_w : d_dev_r};
              mosi_q   <= 1'b0;                                // bit 31 of both commands is 0
              bits_q   <= 6'd32;
              word_q   <= d_wdata_i >> {be_first, 3'b000};
              wbytes_q <= d_we_i ? be_count : 3'd0;
              byte_q   <= 2'd0;
              bit_q    <= 3'd0;
              st_q     <= S_CMD;
            end
          end else if (ar_valid_i) begin
            fetch_q <= 1'b1;
            id_q    <= ar_i.id;
            beats_q <= ar_i.len[3:0];
            wrap_q  <= (ar_i.burst == frontend_pkg::AXI_BURST_WRAP) ? ((24'(ar_i.len) + 24'd1) * 24'd4 - 24'd1) : 24'd0;
            addr_q  <= f_dev;
            cs_line_q <= f_cs;
            restart_q <= 1'b0;
            if (f_cs == 3'b000) begin
              st_q <= S_ERR;
            end else begin
              cs_q     <= f_cs;
              sh_q     <= {8'h03, f_dev};
              mosi_q   <= 1'b0;
              bits_q   <= 6'd32;
              wbytes_q <= 3'd0;
              byte_q   <= 2'd0;
              bit_q    <= 3'd0;
              st_q     <= S_CMD;
            end
          end
        end

        S_CMD: if (fall) begin
          sh_q   <= {sh_q[30:0], 1'b0};
          bits_q <= bits_q - 6'd1;
          mosi_q <= sh_q[30];
          if (bits_q == 6'd1) begin
            if (wbytes_q != 3'd0) begin
              st_q   <= S_WR;
              sh_q   <= {word_q[7:0], word_q[15:8], word_q[23:16], word_q[31:24]};   // byte 0 first, MSB first
              mosi_q <= word_q[7];
              bits_q <= {wbytes_q, 3'b000};
            end else begin
              st_q <= S_RD;
            end
          end
        end

        S_WR: if (fall) begin
          sh_q   <= {sh_q[30:0], 1'b0};
          mosi_q <= sh_q[30];
          bits_q <= bits_q - 6'd1;
          if (bits_q == 6'd1) begin
            st_q  <= S_GAP;
            gap_q <= GCW'(GAP + 1);
            err_q <= 1'b0;
            rsp_q <= 1'b1;
          end
        end

        S_RD: if (fall) begin
          word_q[8*byte_q + (7 - bit_q)] <= miso_i;            // MSB of each byte first
          bit_q <= bit_q + 3'd1;
          if (bit_q == 3'd7) begin
            byte_q <= byte_q + 2'd1;
            if (byte_q == 2'd3) begin
              if (fetch_q) begin
                st_q <= S_BEAT;
              end else begin
                st_q  <= S_GAP;
                gap_q <= GCW'(GAP + 1);
                err_q <= 1'b0;
                rsp_q <= 1'b1;
              end
            end
          end
        end

        S_BEAT: if (r_ready_i) begin
          addr_q  <= next_addr;
          beats_q <= beats_q - 4'd1;
          if (beats_q == 4'd0 || (wrap_q != 0 && (next_addr & wrap_q) == 24'd0)) begin
            // done, or wrapped to the start of the line (new read command after the gap)
            restart_q <= (beats_q != 4'd0);
            st_q      <= S_GAP;
            gap_q     <= GCW'(GAP);
            cs_q      <= 3'b000;
          end else begin
            st_q <= S_RD;
          end
        end

        S_ERR: if (r_ready_i) begin
          beats_q <= beats_q - 4'd1;
          if (beats_q == 4'd0) st_q <= S_IDLE;
        end

        S_GAP: begin                     // first cycle: CS held after the last SCK edge
          gap_q <= gap_q - 1'b1;
          cs_q  <= 3'b000;
          if (gap_q == GCW'(1)) begin
            if (restart_q) begin
              restart_q <= 1'b0;
              st_q      <= S_CMD;
              cs_q      <= cs_line_q;
              sh_q      <= {8'h03, addr_q};
              mosi_q    <= 1'b0;
              bits_q    <= 6'd32;
              byte_q    <= 2'd0;
              bit_q     <= 3'd0;
              wbytes_q  <= 3'd0;
            end else begin
              st_q <= S_IDLE;
            end
          end
        end

        default: st_q <= S_IDLE;
      endcase
    end
  end

  // ---- outputs ---------------------------------------------------------------------
  assign sck_o  = sck_q;
  assign mosi_o = mosi_q;
  assign cs_n_o = ~cs_q;

  assign r_valid_o = (st_q == S_BEAT) || (st_q == S_ERR);
  always_comb begin
    r_o      = '0;
    r_o.id   = id_q;
    r_o.data = (st_q == S_BEAT) ? frontend_pkg::AXI_DATA_W'(word_q) : '0;
    r_o.resp = (st_q == S_ERR) ? 2'b10 : 2'b00;
    r_o.last = (beats_q == 4'd0);
  end

  assign d_rsp_valid_o = rsp_q;
  assign d_rdata_o     = word_q;
  assign d_err_o       = err_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{ar_i, sh_q[31]};   // sh_q[31] is preloaded into mosi_q
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
