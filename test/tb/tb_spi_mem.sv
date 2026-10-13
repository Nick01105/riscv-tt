// Test top for rv_spi_mem: AXI payloads as flat vectors.
module tb_spi_mem #(parameter int DIV = 1) (
  input  logic clk, rst_n,
  input  logic ar_valid, output logic ar_ready, input logic [frontend_pkg::AXI_AR_W-1:0] ar,
  output logic r_valid, input logic r_ready, output logic [frontend_pkg::AXI_R_W-1:0] r,
  input  logic d_valid, output logic d_ready, input logic [31:0] d_addr, input logic d_we,
  input  logic [3:0] d_be, input logic [31:0] d_wdata,
  output logic d_rsp_valid, output logic [31:0] d_rdata, output logic d_err,
  output logic sck, mosi, input logic miso, output logic [2:0] cs_n
);
  frontend_pkg::axi_ar_t ar_s;
  frontend_pkg::axi_r_t  r_s;
  assign ar_s = ar;
  assign r    = r_s;
  rv_spi_mem #(.DIV(DIV)) u_dut (
    .clk, .rst_n, .ar_valid_i(ar_valid), .ar_ready_o(ar_ready), .ar_i(ar_s),
    .r_valid_o(r_valid), .r_ready_i(r_ready), .r_o(r_s),
    .d_valid_i(d_valid), .d_ready_o(d_ready), .d_addr_i(d_addr), .d_we_i(d_we), .d_be_i(d_be), .d_wdata_i(d_wdata),
    .d_rsp_valid_o(d_rsp_valid), .d_rdata_o(d_rdata), .d_err_o(d_err),
    .sck_o(sck), .mosi_o(mosi), .miso_i(miso), .cs_n_o(cs_n)
  );
endmodule
