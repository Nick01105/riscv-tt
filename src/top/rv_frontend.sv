// rv_frontend - the complete instruction frontend.
//
//   rv_bpu (BTB + TAGE + RAS + GHR + FTQ)  ->  rv_ifu (I-cache requests,
//   rv_aligner, rv_iq)  ->  rv_decode_group  ->  uops to the backend
//   rv_icache + rv_axi_rd_master  <->  AXI4 read channels
//
// Backend contract (docs/spec.md section 4):
// * uops leave in program order; slot k is taken only with slots 0..k-1.
// * resolve_i: every branch and every uop with pred_taken, in program order,
//   with mispredict computed against tgt_o (the predicted target of the
//   uop's FTQ entry) when pred_taken, or pc + length otherwise.
//   A uop with fault FAULT_REFETCH resolves as br_type NONE, mispredict,
//   and redirects to its own pc.
// * redirect_i: restart fetch; cause FENCE_I also flushes the I-cache.
//   When resolve_i is valid in the same cycle it must be the same uop.
// * retire_i: the FTQ index of the youngest uop that passed resolve.
module rv_frontend #(
  parameter logic [frontend_pkg::PADDR_W-1:0] RESET_PC = '0
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  // uops to the backend
  output logic [frontend_pkg::DECODE_W-1:0]      uop_valid_o,
  output logic [frontend_pkg::DECODE_W*frontend_pkg::UOP_W-1:0] uop_o,
  input  logic [frontend_pkg::DECODE_W-1:0]      uop_ready_i,
  output logic [frontend_pkg::DECODE_W-1:0]      dep1_v_o,
  output logic [frontend_pkg::DECODE_W*((frontend_pkg::DECODE_W > 1) ? $clog2(frontend_pkg::DECODE_W) : 1)-1:0] dep1_i_o,
  output logic [frontend_pkg::DECODE_W-1:0]      dep2_v_o,
  output logic [frontend_pkg::DECODE_W*((frontend_pkg::DECODE_W > 1) ? $clog2(frontend_pkg::DECODE_W) : 1)-1:0] dep2_i_o,
  // backend -> frontend
  input  frontend_pkg::redirect_t                redirect_i,
  input  frontend_pkg::br_resolve_t              resolve_i,
  input  frontend_pkg::ftq_retire_t              retire_i,
  input  frontend_pkg::ftq_idx_t                 tgt_idx_i,
  output frontend_pkg::paddr_t                   tgt_o,
  // AXI4 read master
  output logic                                   ar_valid_o,
  input  logic                                   ar_ready_i,
  output frontend_pkg::axi_ar_t                  ar_o,
  input  logic                                   r_valid_i,
  output logic                                   r_ready_o,
  input  frontend_pkg::axi_r_t                   r_i,
  // events for the performance counters
  output logic                                   ev_ic_hit_o,
  output logic                                   ev_ic_miss_o,
  output logic                                   ev_pred_o,
  output logic                                   ev_pred_taken_o,
  output logic                                   overflow_o
);
  localparam int PW  = frontend_pkg::PADDR_W;
  localparam int NP  = frontend_pkg::NPARCEL;
  localparam int FB  = frontend_pkg::FETCH_BYTES;
  localparam int CW  = frontend_pkg::CACHE_PA_W;
  localparam int BB  = frontend_pkg::AXI_DATA_W / 8;
  localparam int MI  = frontend_pkg::MSHR_IDX_W;

  // ---- BPU / FTQ -------------------------------------------------------------------------
  logic                     ftq_valid, ftq_take;
  frontend_pkg::paddr_t     ftq_pc;
  logic [NP-1:0]            ftq_mask;
  frontend_pkg::ftq_idx_t   ftq_idx;

  rv_bpu #(.RESET_PC(RESET_PC)) u_bpu (
    .clk, .rst_n,
    .ifu_valid_o(ftq_valid), .ifu_pc_o(ftq_pc), .ifu_mask_o(ftq_mask), .ifu_idx_o(ftq_idx), .ifu_take_i(ftq_take),
    .redirect_i, .resolve_i, .retire_i, .tgt_idx_i, .tgt_o,
    .ev_pred_o, .ev_taken_o(ev_pred_taken_o)
  );

  // ---- fetch unit ------------------------------------------------------------------------
  logic                     ic_req_valid, ic_req_ready, ic_kill, ic_resp_valid, ic_resp_fault;
  frontend_pkg::paddr_t     ic_req_addr;
  logic [FB*8-1:0]          ic_resp_data;
  logic [frontend_pkg::DECODE_W-1:0] iq_valid;
  logic [frontend_pkg::DECODE_W*frontend_pkg::SLOT_W-1:0] iq_slots;

  rv_ifu u_ifu (
    .clk, .rst_n, .flush_i(redirect_i.valid),
    .ftq_valid_i(ftq_valid), .ftq_pc_i(ftq_pc), .ftq_mask_i(ftq_mask), .ftq_idx_i(ftq_idx), .ftq_take_o(ftq_take),
    .ic_req_valid_o(ic_req_valid), .ic_req_ready_i(ic_req_ready), .ic_req_addr_o(ic_req_addr), .ic_kill_o(ic_kill),
    .ic_resp_valid_i(ic_resp_valid), .ic_resp_data_i(ic_resp_data), .ic_resp_fault_i(ic_resp_fault),
    .out_valid_o(iq_valid), .out_slots_o(iq_slots), .out_ready_i(uop_ready_i), .overflow_o
  );

  // ---- I-cache and AXI master ------------------------------------------------------------
  logic            rf_valid, rf_ready, bt_valid, bt_last, bt_err;
  logic [CW-1:0]   rf_addr;
  logic [MI-1:0]   rf_mshr, bt_mshr;
  logic [BB*8-1:0] bt_data;

  rv_icache #(.WAYS(frontend_pkg::IC_WAYS), .SETS(frontend_pkg::IC_SETS), .LINE_BYTES(frontend_pkg::IC_LINE_BYTES),
              .BEAT_BYTES(BB), .FETCH_BYTES(FB), .MSHRS(frontend_pkg::IC_MSHRS), .PA_W(PW), .C_W(CW),
              .LATCH(frontend_pkg::SRAM_LATCH)) u_icache (
    .clk, .rst_n,
    .req_valid_i(ic_req_valid), .req_ready_o(ic_req_ready), .req_addr_i(ic_req_addr),
    .kill_i(ic_kill), .flush_i(redirect_i.valid && redirect_i.cause == frontend_pkg::RDR_FENCE_I),
    .resp_valid_o(ic_resp_valid), .resp_data_o(ic_resp_data), .resp_fault_o(ic_resp_fault),
    .refill_valid_o(rf_valid), .refill_ready_i(rf_ready), .refill_addr_o(rf_addr), .refill_mshr_o(rf_mshr),
    .beat_valid_i(bt_valid), .beat_mshr_i(bt_mshr), .beat_last_i(bt_last), .beat_err_i(bt_err), .beat_data_i(bt_data),
    .ev_hit_o(ev_ic_hit_o), .ev_miss_o(ev_ic_miss_o)
  );

  rv_axi_rd_master #(.C_W(CW), .LINE_BYTES(frontend_pkg::IC_LINE_BYTES), .BEAT_BYTES(BB), .IDX_W(MI)) u_axi (
    .clk, .rst_n,
    .req_valid_i(rf_valid), .req_ready_o(rf_ready), .req_addr_i(rf_addr), .req_mshr_i(rf_mshr),
    .ar_valid_o, .ar_ready_i, .ar_o, .r_valid_i, .r_ready_o, .r_i,
    .beat_valid_o(bt_valid), .beat_mshr_o(bt_mshr), .beat_last_o(bt_last), .beat_err_o(bt_err), .beat_data_o(bt_data)
  );

  // ---- decode ----------------------------------------------------------------------------
  rv_decode_group #(.W(frontend_pkg::DECODE_W)) u_dec (
    .slots_i(iq_slots), .valid_i(iq_valid), .uops_o(uop_o),
    .dep1_v_o, .dep1_i_o, .dep2_v_o, .dep2_i_o
  );
  assign uop_valid_o = iq_valid;
endmodule
