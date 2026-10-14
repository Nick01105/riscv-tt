// tt_um_rvcore - Tiny Tapeout top: riscv-tt RV32EAC core with the QSPI Pmod
// (flash + 2 PSRAMs, plain SPI), UART and GPIO.
//
//   uio[0] CS flash   uio[1] MOSI (SD0)  uio[2] MISO (SD1, input)  uio[3] SCK
//   uio[4] SD2 = 1    uio[5] SD3 = 1     uio[6] CS PSRAM A          uio[7] CS PSRAM B
//   ui_in[0] debug halt: core held in reset, SPI pins released (so the
//            RP2040 can program the flash)
//   ui_in[3] UART RX       uo_out[4] UART TX
//   ui_in[2:1], ui_in[7:4] GPIO in      uo_out[3:0], uo_out[7:5] GPIO out
module tt_um_rvcore #(
  parameter logic [15:0] UART_DIV = 16'd216       // 115200 baud at 25 MHz (tests use a small value)
) (
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
);
  // reset synchronizer, and halt (also synchronized)
  logic [1:0] rst_q, halt_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_q <= 2'b00;
    else        rst_q <= {rst_q[0], 1'b1};
  end
  always_ff @(posedge clk) halt_q <= {halt_q[0], ui_in[0]};

  logic run_n;
  assign run_n = rst_q[1] && !halt_q[1];

  logic       sck, mosi, tx;
  logic [2:0] cs_n;
  logic [6:0] gpio_out;

  /* verilator lint_off PINCONNECTEMPTY */
  rv_soc #(.UART_DIV(UART_DIV)) u_soc (
    .clk, .rst_n(run_n),
    .spi_sck_o(sck), .spi_mosi_o(mosi), .spi_miso_i(uio_in[2]), .spi_cs_n_o(cs_n),
    .uart_tx_o(tx), .uart_rx_i(ui_in[3]),
    .gpio_o(gpio_out), .gpio_i({ui_in[7:4], ui_in[2:1]}),
    .tohost_valid_o(), .tohost_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign uio_out = {cs_n[2], cs_n[1], 1'b1, 1'b1, sck, 1'b0, mosi, cs_n[0]};
  assign uio_oe  = run_n ? 8'b1111_1011 : 8'b0000_0000;
  assign uo_out  = {gpio_out[6:4], tx, gpio_out[3:0]};

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{ena, uio_in[7:3], uio_in[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
