// Test top for rv_core: AXI payloads as flat vectors, everything else as is.
module tb_core (
  input  logic clk, rst_n,
  output logic ar_valid, input logic ar_ready, output logic [frontend_pkg::AXI_AR_W-1:0] ar,
  input  logic r_valid, output logic r_ready, input logic [frontend_pkg::AXI_R_W-1:0] r,
  output logic dreq_valid, input logic dreq_ready,
  output logic [frontend_pkg::PADDR_W-1:0] dreq_addr,
  output logic dreq_we, output logic [1:0] dreq_size,
  output logic [frontend_pkg::XLEN/8-1:0] dreq_be, output logic [frontend_pkg::XLEN-1:0] dreq_wdata,
  input  logic drsp_valid, input logic [frontend_pkg::XLEN-1:0] drsp_rdata, input logic drsp_err,
  input  logic mtip, msip, input logic [63:0] mtime,
  output logic trc_valid, output logic [frontend_pkg::PADDR_W-1:0] trc_pc, output logic [31:0] trc_insn,
  output logic trc_trap, output logic [frontend_pkg::XLEN-1:0] trc_cause, output logic [4:0] trc_rd,
  output logic [frontend_pkg::XLEN-1:0] trc_rd_val, output logic trc_mispredict,
  output logic ev_ic_hit, ev_ic_miss, ev_pred, ev_pred_taken, overflow
);
  frontend_pkg::axi_ar_t ar_s;
  frontend_pkg::axi_r_t  r_s;
  assign ar  = ar_s;
  assign r_s = r;

  rv_core u_core (
    .clk, .rst_n,
    .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_o(ar_s), .r_valid_i(r_valid), .r_ready_o(r_ready), .r_i(r_s),
    .dreq_valid_o(dreq_valid), .dreq_ready_i(dreq_ready), .dreq_addr_o(dreq_addr), .dreq_we_o(dreq_we),
    .dreq_size_o(dreq_size), .dreq_be_o(dreq_be), .dreq_wdata_o(dreq_wdata),
    .drsp_valid_i(drsp_valid), .drsp_rdata_i(drsp_rdata), .drsp_err_i(drsp_err),
    .mtip_i(mtip), .msip_i(msip), .mtime_i(mtime),
    .trc_valid_o(trc_valid), .trc_pc_o(trc_pc), .trc_insn_o(trc_insn), .trc_trap_o(trc_trap),
    .trc_cause_o(trc_cause), .trc_rd_o(trc_rd), .trc_rd_val_o(trc_rd_val), .trc_mispredict_o(trc_mispredict),
    .ev_ic_hit_o(ev_ic_hit), .ev_ic_miss_o(ev_ic_miss), .ev_pred_o(ev_pred), .ev_pred_taken_o(ev_pred_taken),
    .overflow_o(overflow)
  );
endmodule
