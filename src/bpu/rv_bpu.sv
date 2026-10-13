// rv_bpu - branch prediction unit and next-PC generator (with the FTQ).
//
// Two stages. s0 looks up the BTB and TAGE with the next block's pc and the
// global history; s1 forms the prediction and allocates an FTQ entry:
//   * BTB hit, conditional: direction from TAGE; jal/call/jalr: taken;
//     ret: taken to the RAS top. Calls push the return address, returns pop.
//   * taken: next block = target; otherwise the next sequential block.
// s0 guesses the sequential block every cycle. s1 squashes that guess when
// it predicts taken (new pc) or when its block has a conditional branch
// (the history changed, so the guess must be looked up again). History is
// therefore exact, at the cost of one bubble after such blocks.
//
// Each FTQ entry keeps what training and repair need: fetch pc, taken mask,
// predicted target, BTB info, TAGE meta, the history the lookup used (which
// is also the checkpoint before the block's own push) and the RAS state.
//
// Backend interface:
//   resolve_i  every branch and every predicted-taken instruction, in order
//              (trains TAGE and the BTB; br_type NONE invalidates the entry)
//   redirect_i restart at target; GHR and RAS are restored from the entry of
//              redirect_i.ftq_idx, then take the resolved branch's own effect
//   retire_i   frees FTQ entries older than its index
//   tgt_idx_i / tgt_o  predicted target of a block, for the mispredict check
module rv_bpu #(
  parameter logic [frontend_pkg::PADDR_W-1:0] RESET_PC = '0
) (
  input  logic                          clk,
  input  logic                          rst_n,
  // fetch unit
  output logic                          ifu_valid_o,
  output frontend_pkg::paddr_t          ifu_pc_o,
  output logic [frontend_pkg::NPARCEL-1:0] ifu_mask_o,
  output frontend_pkg::ftq_idx_t        ifu_idx_o,
  input  logic                          ifu_take_i,
  // backend
  input  frontend_pkg::redirect_t       redirect_i,
  input  frontend_pkg::br_resolve_t     resolve_i,
  input  frontend_pkg::ftq_retire_t     retire_i,
  input  frontend_pkg::ftq_idx_t        tgt_idx_i,
  output frontend_pkg::paddr_t          tgt_o,
  // events
  output logic                          ev_pred_o,       // a block was predicted
  output logic                          ev_taken_o       // ... and predicted taken
);
  localparam int PW     = frontend_pkg::PADDR_W;
  localparam int NP     = frontend_pkg::NPARCEL;
  localparam int SW     = $clog2(NP);
  localparam int FB     = frontend_pkg::FETCH_BYTES;
  localparam int OFF_W  = $clog2(FB);
  localparam int TGT_W  = frontend_pkg::CACHE_PA_W;   // stored target / RAS bits (+ bit 0)
  localparam int RW     = TGT_W - 1;
  localparam int RPTR   = $clog2(frontend_pkg::RAS_DEPTH);
  localparam int PCB_W  = frontend_pkg::CACHE_PA_W - OFF_W;   // block-number bits for TAGE
  localparam int NT     = frontend_pkg::TAGE_NTABLES;
  localparam int CW     = frontend_pkg::TAGE_CTR_W;
  localparam int UW     = frontend_pkg::TAGE_U_W;
  localparam int META_W = 2 + NT * (1 + CW + UW);
  localparam int HL     = frontend_pkg::GHR_LEN;
  localparam int FTQ_D  = frontend_pkg::FTQ_DEPTH;
  localparam int CNT_W_FTQ = $clog2(FTQ_D + 1);
  localparam logic [2:0] T_NONE = 3'd0, T_COND = 3'd1, T_CALL = 3'd4, T_RET = 3'd5;


  // ---- FTQ entry layout ------------------------------------------------------
  localparam int E_PC   = 0;
  localparam int E_MASK = E_PC + PW;
  localparam int E_TGT  = E_MASK + NP;
  localparam int E_HIT  = E_TGT + RW;
  localparam int E_END  = E_HIT + 1;
  localparam int E_TYP  = E_END + SW;
  localparam int E_META = E_TYP + 3;
  localparam int E_HIST = E_META + META_W;
  localparam int E_RPTR = E_HIST + HL;
  localparam int E_RTOP = E_RPTR + RPTR;
  localparam bit CK_TOP = (frontend_pkg::RAS_CKPT_TOP != 0);
  localparam int RTW    = CK_TOP ? RW : 1;             // checkpointed RAS top (1 dummy bit when off)
  localparam int DW     = E_RTOP + RTW;

  // ---- state -----------------------------------------------------------------
  logic [PW-1:0]           s0_pc_q, s1_pc_q;
  logic             s1_v_q;
  logic [HL-1:0]    s1_hist_q;
  logic [HL-1:0]    ghr;
  logic [RW-1:0]    ras_top;
  logic [RPTR-1:0]  ras_ptr;

  // ---- predictors --------------------------------------------------------------
  logic             btb_hit;
  logic [NP-1:0]    btb_end_mask;
  logic [2:0]       btb_type;
  logic [PW-1:0]           btb_tgt;
  logic             tage_taken;
  logic [META_W-1:0] tage_meta;

  logic             s0_fire;
  logic [DW-1:0]    e_rd, e_rd2, e_new, e_rd2_ifu;
  logic [CNT_W_FTQ-1:0] ftq_free;

  // training / repair inputs from the FTQ entry of the resolving instruction
  logic [PW-1:0]           e_pc;
  logic             e_hit;
  logic [SW-1:0]    e_end;
  logic [2:0]       e_typ;
  logic [META_W-1:0] e_meta;
  logic [HL-1:0]    e_hist;
  logic [RPTR-1:0]  e_rptr;
  logic [RW-1:0]    e_rtop;
  logic [RTW-1:0]   e_rtop_f;
  assign e_pc   = e_rd[E_PC +: PW];
  assign e_hit  = e_rd[E_HIT];
  assign e_end  = e_rd[E_END +: SW];
  assign e_typ  = e_rd[E_TYP +: 3];
  assign e_meta = e_rd[E_META +: META_W];
  assign e_hist = e_rd[E_HIST +: HL];
  assign e_rptr = e_rd[E_RPTR +: RPTR];
  assign e_rtop_f = e_rd[E_RTOP +: RTW];
  assign e_rtop   = CK_TOP ? RW'(e_rtop_f) : '0;

  // resolved instruction
  logic [PW-1:0]        r_end_addr, r_link;
  logic [SW-1:0] r_endp;
  assign r_end_addr = resolve_i.pc + (resolve_i.is_rvc ? PW'(0) : PW'(2));
  assign r_endp     = r_end_addr[1 +: SW];
  assign r_link     = resolve_i.pc + (resolve_i.is_rvc ? PW'(2) : PW'(4));

  logic r_cond, r_none, up_tage, up_btb, up_btb_inval;
  assign r_cond       = resolve_i.valid && resolve_i.br_type == T_COND;
  assign r_none       = resolve_i.valid && resolve_i.br_type == T_NONE;
  assign up_tage      = r_cond && (!e_hit || e_end == r_endp);
  assign up_btb_inval = r_none && e_hit;
  assign up_btb       = up_btb_inval || (resolve_i.valid && resolve_i.taken && !r_none &&
                        (!e_hit || e_end != r_endp || e_typ != resolve_i.br_type || resolve_i.mispredict));

  rv_btb #(.ENTRIES(frontend_pkg::BTB_ENTRIES), .TAG_W(frontend_pkg::BTB_TAG_W), .LATCH(frontend_pkg::SRAM_LATCH), .TGT_W(TGT_W)) u_btb (
    .clk, .rst_n,
    .lk_valid_i(s0_fire), .lk_pc_i(s0_pc_q),
    .lk_hit_o(btb_hit), .lk_end_mask_o(btb_end_mask), .lk_type_o(btb_type), .lk_target_o(btb_tgt),
    .up_valid_i(up_btb), .up_inval_i(up_btb_inval), .up_pc_i(e_pc),
    .up_end_mask_i(NP'(1) << r_endp), .up_type_i(resolve_i.br_type), .up_target_i(resolve_i.target)
  );

  generate
    if (NT == 0) begin : g_bim
      // TAGE_NTABLES = 0: bimodal predictor only (the TAGE base table on its
      // own). The meta is the 2-bit counter read at prediction time.
      localparam int BIDX_W = $clog2(frontend_pkg::TAGE_BASE_ENTRIES);
      logic [1:0] b_ctr, b_new;
      /* verilator lint_off PINCONNECTEMPTY */
      rv_bimodal #(.ENTRIES(frontend_pkg::TAGE_BASE_ENTRIES), .CTR_W(2), .LATCH(frontend_pkg::SRAM_LATCH)) u_bim (
        .clk, .rst_n, .init_done_o(),
        .rd_valid_i(s0_fire), .rd_idx_i(s0_pc_q[OFF_W +: BIDX_W]), .rd_ctr_o(b_ctr),
        .wr_valid_i(up_tage), .wr_idx_i(e_pc[OFF_W +: BIDX_W]), .wr_ctr_i(b_new)
      );
      /* verilator lint_on PINCONNECTEMPTY */
      always_comb begin
        b_new = e_meta[1:0];
        if (resolve_i.taken && b_new != 2'b11) b_new = b_new + 2'd1;
        if (!resolve_i.taken && b_new != 2'b00) b_new = b_new - 2'd1;
      end
      assign tage_taken = b_ctr[1];
      assign tage_meta  = b_ctr;
    end else begin : g_tage
      rv_tage #(.PC_W(PCB_W), .GHR_LEN(HL), .BASE_ENTRIES(frontend_pkg::TAGE_BASE_ENTRIES), .NT(NT), .ENTRIES(frontend_pkg::TAGE_ENTRIES),
                .TAG_W(frontend_pkg::TAGE_TAG_W), .CTR_W(CW), .U_W(UW), .HLENS(frontend_pkg::TAGE_HLENS),
                .RESET_LOG((NT > 2) ? 18 : 9), .LATCH(frontend_pkg::SRAM_LATCH)) u_tage (
        .clk, .rst_n,
        .pd_valid_i(s0_fire), .pd_pc_i(s0_pc_q[OFF_W +: PCB_W]), .pd_hist_i(ghr),
        .pd_taken_o(tage_taken), .pd_meta_o(tage_meta),
        .up_valid_i(up_tage), .up_pc_i(e_pc[OFF_W +: PCB_W]), .up_hist_i(e_hist),
        .up_taken_i(resolve_i.taken), .up_meta_i(e_meta)
      );
    end
  endgenerate

  // ---- s1: form the prediction -------------------------------------------------
  logic          is_cond, dir, taken, squash, s1_alloc;
  logic [SW-1:0] s1_end;
  logic [PW-1:0]        s1_base, s1_seq, s1_tgt, s1_next, s1_ret;

  always_comb begin
    s1_end = '0;
    for (int i = 0; i < NP; i++) if (btb_end_mask[i]) s1_end = SW'(i);
  end

  assign is_cond  = s1_v_q && btb_hit && btb_type == T_COND;
  assign dir      = tage_taken;
  assign taken    = s1_v_q && btb_hit && (btb_type != T_COND || dir);
  assign s1_tgt   = (btb_type == T_RET) ? PW'({ras_top, 1'b0}) : btb_tgt;
  assign s1_base  = {s1_pc_q[PW-1:OFF_W], {OFF_W{1'b0}}};
  assign s1_seq   = s1_base + PW'(FB);
  assign s1_next  = taken ? s1_tgt : s1_seq;
  assign s1_ret   = s1_base + PW'({s1_end, 1'b0}) + PW'(2);
  assign squash   = taken || is_cond;
  assign s1_alloc = s1_v_q && !redirect_i.valid;

  always_comb begin
    e_new = '0;
    e_new[E_PC +: PW]       = s1_pc_q;
    e_new[E_MASK +: NP]     = taken ? (NP'(1) << s1_end) : '0;
    e_new[E_TGT +: RW]      = s1_tgt[1 +: RW];
    e_new[E_HIT]            = btb_hit;
    e_new[E_END +: SW]      = s1_end;
    e_new[E_TYP +: 3]       = btb_type;
    e_new[E_META +: META_W] = tage_meta;
    e_new[E_HIST +: HL]     = s1_hist_q;
    e_new[E_RPTR +: RPTR]   = ras_ptr;
    e_new[E_RTOP +: RTW]    = CK_TOP ? RTW'(ras_top) : '0;
  end

  // ---- FTQ ---------------------------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  rv_ftq #(.DEPTH(FTQ_D), .DW(DW), .LATCH(frontend_pkg::SRAM_LATCH)) u_ftq (
    .clk, .rst_n,
    .alloc_i(s1_alloc), .alloc_data_i(e_new), .alloc_idx_o(), .free_o(ftq_free),
    .ifu_valid_o, .ifu_idx_o, .ifu_data_o(e_rd2_ifu), .ifu_take_i,
    .rd_idx_i(resolve_i.valid ? resolve_i.ftq_idx : redirect_i.ftq_idx), .rd_data_o(e_rd),
    .rd2_idx_i(tgt_idx_i), .rd2_data_o(e_rd2),
    .redir_i(redirect_i.valid), .redir_idx_i(redirect_i.ftq_idx),
    .ret_i(retire_i.valid), .ret_idx_i(retire_i.ftq_idx)
  );
  assign ifu_pc_o   = e_rd2_ifu[E_PC +: PW];
  assign ifu_mask_o = e_rd2_ifu[E_MASK +: NP];
  assign tgt_o      = PW'({e_rd2[E_TGT +: RW], 1'b0});

  // ---- global history and RAS (speculative in s1, repaired on redirect) -------
  logic r_same;                    // the resolve belongs to the redirecting instruction
  assign r_same = resolve_i.valid && resolve_i.ftq_idx == redirect_i.ftq_idx;

  rv_ghr #(.LEN(HL)) u_ghr (
    .clk, .rst_n,
    .spec_push_i(is_cond && !redirect_i.valid), .spec_bit_i(dir),
    .restore_i(redirect_i.valid), .restore_val_i(e_hist),
    .restore_push_i(r_same && resolve_i.br_type == T_COND), .restore_bit_i(resolve_i.taken),
    .hist_o(ghr), .out_bit_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic          ras_push, ras_pop;
  logic [RW-1:0] ras_push_addr;
  assign ras_push      = s1_v_q && btb_hit && btb_type == T_CALL && !redirect_i.valid;
  assign ras_pop       = s1_v_q && btb_hit && btb_type == T_RET && !redirect_i.valid;
  assign ras_push_addr = redirect_i.valid ? r_link[1 +: RW] : s1_ret[1 +: RW];

  rv_ras #(.DEPTH(frontend_pkg::RAS_DEPTH), .W(RW), .RESTORE_TOP(CK_TOP)) u_ras (
    .clk, .rst_n,
    .push_i(ras_push), .push_addr_i(ras_push_addr), .pop_i(ras_pop),
    .restore_i(redirect_i.valid), .restore_ptr_i(e_rptr), .restore_top_i(e_rtop),
    .restore_push_i(r_same && resolve_i.br_type == T_CALL),
    .restore_pop_i(r_same && resolve_i.br_type == T_RET),
    .top_o(ras_top), .ptr_o(ras_ptr)
  );

  // ---- s0 / s1 sequencing --------------------------------------------------------
  assign s0_fire = !redirect_i.valid && !(s1_v_q && squash) &&
                   (32'(ftq_free) - (s1_alloc ? 1 : 0) >= 1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s0_pc_q <= RESET_PC;
      s1_v_q  <= 1'b0;
    end else if (redirect_i.valid) begin
      s0_pc_q <= redirect_i.target;
      s1_v_q  <= 1'b0;
    end else if (s1_v_q && squash) begin
      s0_pc_q <= s1_next;
      s1_v_q  <= 1'b0;
    end else if (s0_fire) begin
      s1_v_q    <= 1'b1;
      s1_pc_q   <= s0_pc_q;
      s1_hist_q <= ghr;
      s0_pc_q   <= {s0_pc_q[PW-1:OFF_W], {OFF_W{1'b0}}} + PW'(FB);
    end else begin
      s1_v_q <= 1'b0;
    end
  end

  assign ev_pred_o  = s1_alloc;
  assign ev_taken_o = s1_alloc && taken;

  // pc bit 0 and bits above the cacheable range do not reach the predictors
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{e_rd2, e_rd2_ifu, resolve_i.mispredict, redirect_i.cause, s0_pc_q, e_pc, r_end_addr, r_link, s1_ret, s1_tgt};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
