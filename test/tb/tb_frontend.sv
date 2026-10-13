// Test top for rv_frontend: flat backend ports, uop fields unpacked per slot.
module tb_frontend (
  input  logic clk, rst_n,
  // uops (per slot k at [k*w +: w])
  output logic [frontend_pkg::DECODE_W-1:0] u_valid,
  input  logic [frontend_pkg::DECODE_W-1:0] u_ready,
  output logic [frontend_pkg::DECODE_W*frontend_pkg::PADDR_W-1:0] u_pc,
  output logic [frontend_pkg::DECODE_W*32-1:0] u_raw,
  output logic [frontend_pkg::DECODE_W-1:0] u_rvc, u_taken, u_illegal,
  output logic [frontend_pkg::DECODE_W*2-1:0] u_fault,
  output logic [frontend_pkg::DECODE_W*3-1:0] u_br, u_sys,
  output logic [frontend_pkg::DECODE_W*frontend_pkg::FTQ_IDX_W-1:0] u_ftq,
  // backend -> frontend
  input  logic rd_valid, input logic [frontend_pkg::PADDR_W-1:0] rd_target,
  input  logic [frontend_pkg::FTQ_IDX_W-1:0] rd_ftq, input logic [1:0] rd_cause,
  input  logic rs_valid, input logic [frontend_pkg::PADDR_W-1:0] rs_pc, input logic rs_rvc, rs_taken,
  input  logic [frontend_pkg::PADDR_W-1:0] rs_target, input logic [2:0] rs_br, input logic rs_mispredict,
  input  logic [frontend_pkg::FTQ_IDX_W-1:0] rs_ftq,
  input  logic rt_valid, input logic [frontend_pkg::FTQ_IDX_W-1:0] rt_ftq,
  input  logic [frontend_pkg::FTQ_IDX_W-1:0] tgt_idx, output logic [frontend_pkg::PADDR_W-1:0] tgt,
  // AXI
  output logic ar_valid, input logic ar_ready, output logic [frontend_pkg::AXI_AR_W-1:0] ar,
  input  logic r_valid, output logic r_ready, input logic [frontend_pkg::AXI_R_W-1:0] r,
  output logic ev_ic_hit, ev_ic_miss, ev_pred, ev_pred_taken, overflow
);
  localparam int DW = frontend_pkg::DECODE_W;
  localparam int UW = frontend_pkg::UOP_W;
  localparam int PW = frontend_pkg::PADDR_W;
  localparam int FW = frontend_pkg::FTQ_IDX_W;
  localparam int IW = (DW > 1) ? $clog2(DW) : 1;

  frontend_pkg::redirect_t   rdr;
  frontend_pkg::br_resolve_t res;
  frontend_pkg::ftq_retire_t ret;
  frontend_pkg::axi_ar_t     ar_s;
  frontend_pkg::axi_r_t      r_s;
  logic [DW*UW-1:0]          uops;
  logic [DW-1:0]             d1v, d2v;
  logic [DW*IW-1:0]          d1i, d2i;

  always_comb begin
    rdr.valid = rd_valid; rdr.target = rd_target; rdr.ftq_idx = rd_ftq;
    rdr.cause = frontend_pkg::redirect_cause_e'(rd_cause);
    res.valid = rs_valid; res.pc = rs_pc; res.is_rvc = rs_rvc; res.taken = rs_taken; res.target = rs_target;
    res.br_type = frontend_pkg::br_type_e'(rs_br); res.mispredict = rs_mispredict; res.ftq_idx = rs_ftq;
    ret.valid = rt_valid; ret.ftq_idx = rt_ftq;
  end
  assign ar = ar_s;
  assign r_s = r;

  rv_frontend dut (
    .clk, .rst_n, .uop_valid_o(u_valid), .uop_o(uops), .uop_ready_i(u_ready),
    .dep1_v_o(d1v), .dep1_i_o(d1i), .dep2_v_o(d2v), .dep2_i_o(d2i),
    .redirect_i(rdr), .resolve_i(res), .retire_i(ret), .tgt_idx_i(tgt_idx), .tgt_o(tgt),
    .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_o(ar_s), .r_valid_i(r_valid), .r_ready_o(r_ready), .r_i(r_s),
    .ev_ic_hit_o(ev_ic_hit), .ev_ic_miss_o(ev_ic_miss), .ev_pred_o(ev_pred), .ev_pred_taken_o(ev_pred_taken),
    .overflow_o(overflow)
  );

  for (genvar k = 0; k < DW; k++) begin : g
    frontend_pkg::uop_t u;
    assign u = uops[k*UW +: UW];
    assign u_pc[k*PW +: PW]  = u.pc;
    assign u_raw[k*32 +: 32] = u.raw32;
    assign u_rvc[k]          = u.is_rvc;
    assign u_taken[k]        = u.pred_taken;
    assign u_illegal[k]      = u.illegal;
    assign u_fault[k*2 +: 2] = u.fault;
    assign u_br[k*3 +: 3]    = u.br_type;
    assign u_sys[k*3 +: 3]   = u.sys;
    assign u_ftq[k*FW +: FW] = u.ftq_idx;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{d1v, d2v, d1i, d2i};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
