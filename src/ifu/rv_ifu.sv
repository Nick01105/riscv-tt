// rv_ifu - fetch unit: FTQ entries -> I-cache requests -> aligner -> IQ.
//
// Requests are issued in FTQ order. A small FIFO remembers each request in
// flight (pc, taken mask, FTQ index) until the I-cache answers, in order.
// Flow control is by credits: a request is issued only if the IQ is sure to
// have room for its block (NP slots) and for every block still in flight,
// so the aligner never has to stall. A redirect (flush_i) kills the I-cache
// request and empties the FIFO, the aligner carry and the IQ.
module rv_ifu (
  input  logic                                  clk,
  input  logic                                  rst_n,
  input  logic                                  flush_i,
  // FTQ
  input  logic                                  ftq_valid_i,
  input  frontend_pkg::paddr_t                  ftq_pc_i,
  input  logic [frontend_pkg::NPARCEL-1:0]      ftq_mask_i,
  input  frontend_pkg::ftq_idx_t                ftq_idx_i,
  output logic                                  ftq_take_o,
  // I-cache
  output logic                                  ic_req_valid_o,
  input  logic                                  ic_req_ready_i,
  output frontend_pkg::paddr_t                  ic_req_addr_o,
  output logic                                  ic_kill_o,
  input  logic                                  ic_resp_valid_i,
  input  logic [frontend_pkg::FETCH_BYTES*8-1:0] ic_resp_data_i,
  input  logic                                  ic_resp_fault_i,
  // to decode
  output logic [frontend_pkg::DECODE_W-1:0]     out_valid_o,
  output logic [frontend_pkg::DECODE_W*frontend_pkg::SLOT_W-1:0] out_slots_o,
  input  logic [frontend_pkg::DECODE_W-1:0]     out_ready_i,
  output logic                                  overflow_o    // credit bug: must never be 1
);
  localparam int PW  = frontend_pkg::PADDR_W;
  localparam int NP  = frontend_pkg::NPARCEL;
  localparam int FW  = frontend_pkg::FTQ_IDX_W;
  localparam int SW  = frontend_pkg::SLOT_W;
  localparam int IQD = frontend_pkg::IQ_DEPTH;
  localparam int INF = (IQD >= 2 * NP) ? 2 : 1;             // requests in flight at most (credits allow no more)
  localparam int ICW = $clog2(INF + 1);
  localparam int MW  = PW + NP + FW;

  // ---- in-flight requests ----------------------------------------------------------
  logic          inf_in_ready, inf_out_valid;
  logic [MW-1:0] inf_head;
  logic [ICW-1:0] inf_count;
  logic          issue;
  logic [$clog2(IQD+1)-1:0] iq_count;

  rv_fifo #(.W(MW), .DEPTH(INF)) u_inflight (
    .clk, .rst_n, .flush_i(flush_i),
    .in_valid_i(issue), .in_ready_o(inf_in_ready), .in_data_i({ftq_pc_i, ftq_mask_i, ftq_idx_i}),
    .out_valid_o(inf_out_valid), .out_ready_i(ic_resp_valid_i), .out_data_o(inf_head),
    .count_o(inf_count)
  );

  logic credit_ok;
  assign credit_ok      = (32'(iq_count) + NP * (32'(inf_count) + 1) <= IQD);
  assign ic_req_valid_o = ftq_valid_i && credit_ok && inf_in_ready && !flush_i;
  assign ic_req_addr_o  = ftq_pc_i;
  assign issue          = ic_req_valid_o && ic_req_ready_i;
  assign ftq_take_o     = issue;
  assign ic_kill_o      = flush_i;

  // ---- aligner and IQ ----------------------------------------------------------------
  logic [NP-1:0]    al_valid;
  logic [NP*SW-1:0] al_slots;
  logic             iq_in_ready, al_in_ready;

  rv_aligner u_align (
    .clk, .rst_n, .flush_i(flush_i),
    .in_valid_i(ic_resp_valid_i && inf_out_valid), .in_ready_o(al_in_ready),
    .in_pc_i(inf_head[MW-1 -: PW]), .in_data_i(ic_resp_data_i),
    .in_taken_i(inf_head[FW +: NP]),
    .in_fault_i(ic_resp_fault_i ? frontend_pkg::FAULT_ACCESS : frontend_pkg::FAULT_NONE),
    .in_ftq_i(inf_head[FW-1:0]),
    .out_valid_o(al_valid), .out_slots_o(al_slots), .out_ready_i(iq_in_ready)
  );

  rv_iq #(.NP(NP), .OUT_W(frontend_pkg::DECODE_W), .DEPTH(IQD), .SW(SW)) u_iq (
    .clk, .rst_n, .flush_i(flush_i),
    .in_valid_i(ic_resp_valid_i && !flush_i), .in_ready_o(iq_in_ready),
    .in_mask_i(al_valid), .in_slots_i(al_slots),
    .out_valid_o, .out_slots_o, .out_ready_i, .count_o(iq_count)
  );

  assign overflow_o = ic_resp_valid_i && (!iq_in_ready || !inf_out_valid);

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = al_in_ready;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
