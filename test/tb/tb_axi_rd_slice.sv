// Test wrapper for rv_axi_rd_slice: flat payload ports plus a width check.
module tb_axi_rd_slice (
  input  logic clk, rst_n,
  input  logic s_ar_valid_i, output logic s_ar_ready_o, input  logic [frontend_pkg::AXI_AR_W-1:0] s_ar_i,
  output logic m_ar_valid_o, input  logic m_ar_ready_i, output logic [frontend_pkg::AXI_AR_W-1:0] m_ar_o,
  input  logic m_r_valid_i,  output logic m_r_ready_o,  input  logic [frontend_pkg::AXI_R_W-1:0]  m_r_i,
  output logic s_r_valid_o,  input  logic s_r_ready_i,  output logic [frontend_pkg::AXI_R_W-1:0]  s_r_o
);
  frontend_pkg::axi_ar_t ar_in, ar_out;
  frontend_pkg::axi_r_t  r_in, r_out;
  assign ar_in = s_ar_i;
  assign r_in  = m_r_i;
  assign m_ar_o = ar_out;
  assign s_r_o  = r_out;

  rv_axi_rd_slice dut (
    .clk, .rst_n,
    .s_ar_valid_i, .s_ar_ready_o, .s_ar_i(ar_in), .m_ar_valid_o, .m_ar_ready_i, .m_ar_o(ar_out),
    .m_r_valid_i, .m_r_ready_o, .m_r_i(r_in), .s_r_valid_o, .s_r_ready_i, .s_r_o(r_out)
  );

  initial begin
    if ($bits(frontend_pkg::axi_ar_t) != frontend_pkg::AXI_AR_W) $fatal(1, "AXI_AR_W mismatch");
    if ($bits(frontend_pkg::axi_r_t)  != frontend_pkg::AXI_R_W)  $fatal(1, "AXI_R_W mismatch");
  end
endmodule
