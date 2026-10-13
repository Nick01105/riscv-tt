// rv_axi_rd_slice - register slice for the AXI4 read channels (AR and R).
// Both directions go through a skid buffer, so every valid, ready and payload
// signal is registered and the slice still moves one beat per cycle. It
// keeps the AXI rule that a valid payload stays stable until accepted.
module rv_axi_rd_slice (
  input  logic                  clk,
  input  logic                  rst_n,
  // AR: master side in, slave side out
  input  logic                  s_ar_valid_i,
  output logic                  s_ar_ready_o,
  input  frontend_pkg::axi_ar_t s_ar_i,
  output logic                  m_ar_valid_o,
  input  logic                  m_ar_ready_i,
  output frontend_pkg::axi_ar_t m_ar_o,
  // R: slave side in, master side out
  input  logic                  m_r_valid_i,
  output logic                  m_r_ready_o,
  input  frontend_pkg::axi_r_t  m_r_i,
  output logic                  s_r_valid_o,
  input  logic                  s_r_ready_i,
  output frontend_pkg::axi_r_t  s_r_o
);
  logic [frontend_pkg::AXI_AR_W-1:0] ar_q;
  logic [frontend_pkg::AXI_R_W-1:0]  r_q;

  rv_skid_buffer #(.W(frontend_pkg::AXI_AR_W)) u_ar (
    .clk, .rst_n, .flush_i(1'b0),
    .in_valid_i(s_ar_valid_i), .in_ready_o(s_ar_ready_o), .in_data_i(s_ar_i),
    .out_valid_o(m_ar_valid_o), .out_ready_i(m_ar_ready_i), .out_data_o(ar_q)
  );

  rv_skid_buffer #(.W(frontend_pkg::AXI_R_W)) u_r (
    .clk, .rst_n, .flush_i(1'b0),
    .in_valid_i(m_r_valid_i), .in_ready_o(m_r_ready_o), .in_data_i(m_r_i),
    .out_valid_o(s_r_valid_o), .out_ready_i(s_r_ready_i), .out_data_o(r_q)
  );

  assign m_ar_o = ar_q;
  assign s_r_o  = r_q;
endmodule
