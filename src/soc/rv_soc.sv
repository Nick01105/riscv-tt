// rv_soc - rv_core plus memories and peripherals (TT build, XLEN 32).
//
//   0x0000_0000-0x01FF_FFFF  flash, PSRAM A, PSRAM B   rv_spi_mem (fetch + data)
//   0x0200_0000-0x0200_FFFF  CLINT                     rv_clint
//   0x1000_0000              UART data / +4 status / +8 divisor
//   0x1000_0100              GPIO out (7 bits) / +4 in (6 bits)
//   0x1000_0300              TOHOST (write: test result, simulation)
//
// MMIO rules (as in model/rv_iss.py): registers are 32-bit; a narrower load
// returns the containing word (the core picks the bytes); the only narrower
// store accepted is a byte store to the UART data register; other narrow
// stores and unmapped addresses return an access fault. MMIO answers one
// cycle after the request.
module rv_soc #(
  parameter logic [15:0] UART_DIV = 16'd433,
  parameter int          SPI_DIV  = 1
) (
  input  logic        clk,
  input  logic        rst_n,
  // SPI memories
  output logic        spi_sck_o,
  output logic        spi_mosi_o,
  input  logic        spi_miso_i,
  output logic [2:0]  spi_cs_n_o,
  // UART, GPIO
  output logic        uart_tx_o,
  input  logic        uart_rx_i,
  output logic [6:0]  gpio_o,
  input  logic [5:0]  gpio_i,
  // simulation and debug
  output logic        tohost_valid_o,
  output logic [31:0] tohost_o
);
  // ---- core -------------------------------------------------------------------------
  logic                  ar_valid, ar_ready, r_valid, r_ready;
  frontend_pkg::axi_ar_t ar;
  frontend_pkg::axi_r_t  r;
  logic                  dreq_valid, dreq_ready, dreq_we, drsp_valid, drsp_err;
  logic [31:0]           dreq_addr, dreq_wdata, drsp_rdata;
  logic [1:0]            dreq_size;
  logic [3:0]            dreq_be;
  logic                  mtip, msip;
  logic [63:0]           mtime;

  /* verilator lint_off PINCONNECTEMPTY */
  rv_core u_core (
    .clk, .rst_n,
    .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_o(ar), .r_valid_i(r_valid), .r_ready_o(r_ready), .r_i(r),
    .dreq_valid_o(dreq_valid), .dreq_ready_i(dreq_ready), .dreq_addr_o(dreq_addr), .dreq_we_o(dreq_we),
    .dreq_size_o(dreq_size), .dreq_be_o(dreq_be), .dreq_wdata_o(dreq_wdata),
    .drsp_valid_i(drsp_valid), .drsp_rdata_i(drsp_rdata), .drsp_err_i(drsp_err),
    .mtip_i(mtip), .msip_i(msip), .mtime_i(mtime),
    .trc_valid_o(), .trc_pc_o(), .trc_insn_o(), .trc_trap_o(), .trc_cause_o(), .trc_rd_o(), .trc_rd_val_o(),
    .trc_mispredict_o(), .ev_ic_hit_o(), .ev_ic_miss_o(), .ev_pred_o(), .ev_pred_taken_o(), .overflow_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- address decode ---------------------------------------------------------------
  logic        is_mem, is_clint, is_uart, is_gpio, is_tohost;
  logic [31:0] wa;                       // word address
  assign wa        = {dreq_addr[31:2], 2'b00};
  assign is_mem    = (dreq_addr[31:25] == 7'd0);
  assign is_clint  = (dreq_addr[31:16] == 16'h0200);
  assign is_uart   = (wa == 32'h1000_0000) || (wa == 32'h1000_0004) || (wa == 32'h1000_0008);
  assign is_gpio   = (wa == 32'h1000_0100) || (wa == 32'h1000_0104);
  assign is_tohost = (wa == 32'h1000_0300);

  // ---- memories -------------------------------------------------------------------------
  logic        m_ready, m_rsp, m_err;
  logic [31:0] m_rdata;
  rv_spi_mem #(.DIV(SPI_DIV)) u_mem (
    .clk, .rst_n,
    .ar_valid_i(ar_valid), .ar_ready_o(ar_ready), .ar_i(ar), .r_valid_o(r_valid), .r_ready_i(r_ready), .r_o(r),
    .d_valid_i(dreq_valid && is_mem), .d_ready_o(m_ready), .d_addr_i(dreq_addr), .d_we_i(dreq_we),
    .d_be_i(dreq_be), .d_wdata_i(dreq_wdata),
    .d_rsp_valid_o(m_rsp), .d_rdata_o(m_rdata), .d_err_o(m_err),
    .sck_o(spi_sck_o), .mosi_o(spi_mosi_o), .miso_i(spi_miso_i), .cs_n_o(spi_cs_n_o)
  );

  // ---- MMIO -----------------------------------------------------------------------------
  logic        io_req, io_ok, io_we, narrow, narrow_ok;
  assign io_req    = dreq_valid && !is_mem;
  assign narrow    = (dreq_size != 2'd2);
  assign narrow_ok = (dreq_addr == 32'h1000_0000) && (dreq_size == 2'd0);
  assign io_we     = io_req && dreq_we && (!narrow || narrow_ok);

  logic        c_hit;
  logic [31:0] c_rdata, u_rdata;
  rv_clint u_clint (
    .clk, .rst_n, .off_i(wa[15:0]), .hit_o(c_hit), .we_i(io_we && is_clint && c_hit),
    .wdata_i(dreq_wdata), .rdata_o(c_rdata), .mtip_o(mtip), .msip_o(msip), .mtime_o(mtime)
  );

  rv_uart #(.DIV_RESET(UART_DIV)) u_uart (
    .clk, .rst_n, .reg_i(wa[3:2]), .re_i(io_req && !dreq_we && is_uart), .we_i(io_we && is_uart),
    .wdata_i(dreq_wdata), .rdata_o(u_rdata), .tx_o(uart_tx_o), .rx_i(uart_rx_i)
  );

  logic [6:0] gpio_q;
  always_ff @(posedge clk) begin
    if (!rst_n) gpio_q <= '0;
    else if (io_we && wa == 32'h1000_0100) gpio_q <= dreq_wdata[6:0];
  end
  assign gpio_o = gpio_q;

  always_comb begin
    io_ok = 1'b0;
    if (is_clint)       io_ok = c_hit;
    else if (is_uart)   io_ok = 1'b1;
    else if (is_gpio)   io_ok = !dreq_we || wa == 32'h1000_0100;    // GPIO in is read-only
    else if (is_tohost) io_ok = dreq_we;
    if (dreq_we && narrow && !narrow_ok) io_ok = 1'b0;
  end

  logic        io_rsp_q, io_err_q, tohost_v_q;
  logic [31:0] io_rdata_q, tohost_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      io_rsp_q   <= 1'b0;
      tohost_v_q <= 1'b0;
    end else begin
      io_rsp_q <= io_req;
      if (io_we && is_tohost) begin
        tohost_v_q <= 1'b1;
        tohost_q   <= dreq_wdata;
      end
    end
    io_err_q <= !io_ok;
    if (is_clint)                     io_rdata_q <= c_rdata;
    else if (is_uart)                 io_rdata_q <= u_rdata;
    else if (wa == 32'h1000_0100)     io_rdata_q <= {25'b0, gpio_q};
    else                              io_rdata_q <= {26'b0, gpio_i};
  end

  assign dreq_ready = is_mem ? m_ready : 1'b1;
  assign drsp_valid = m_rsp || io_rsp_q;
  assign drsp_rdata = m_rsp ? m_rdata : io_rdata_q;
  assign drsp_err   = m_rsp ? m_err : io_err_q;

  assign tohost_valid_o = tohost_v_q;
  assign tohost_o       = tohost_q;
endmodule
