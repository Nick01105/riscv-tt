// rv_tage - TAGE conditional-branch direction predictor (Seznec & Michaud):
// a bimodal base table plus NT tagged tables indexed with geometrically
// longer global histories.
//
// One prediction per fetch block. The block is identified by its block
// number pc[PW-1:OFF_W] (the block where the branch ends, as for the BTB).
//
// Predict: request in cycle N, pd_taken_o and pd_meta_o in N+1. The FTQ keeps
//   pc, the history checkpoint and the meta with the block.
// Update: one cycle, write-only. Indices and tags are recomputed from the
//   saved pc and history; the read values come from the saved meta, so the
//   tables need no extra read port.
//   * provider = longest hitting table, alt = next hit or the base;
//   * provider counter (or base if none) moves toward the outcome;
//   * provider useful bit moves when provider and alt disagree;
//   * on a misprediction, allocate in a longer table whose useful bits are
//     0 (first or second candidate, chosen by an LFSR); if none, age the
//     useful bits of all longer tables;
//   * every 2^RESET_LOG updates one useful-bit plane is cleared, alternating
//     between the high and the low bit.
// The USE_ALT_ON_NA refinement is not implemented.
module rv_tage #(
  parameter int PC_W         = 23,          // block-number bits used for hashing
  parameter int GHR_LEN      = 12,
  parameter int BASE_ENTRIES = 64,
  parameter int NT           = 2,
  parameter int ENTRIES      = 16,
  parameter int TAG_W        = 6,
  parameter int CTR_W        = 3,
  parameter int U_W          = 2,
  parameter logic [8*NT-1:0] HLENS = {8'd12, 8'd4},   // table t at [8t +: 8], increasing
  parameter int RESET_LOG    = 9,
  parameter int LATCH        = 0,
  parameter int META_W       = 2 + NT * (1 + CTR_W + U_W)   // derived, do not override
) (
  input  logic               clk,
  input  logic               rst_n,
  // predict
  input  logic               pd_valid_i,
  input  logic [PC_W-1:0]    pd_pc_i,
  input  logic [GHR_LEN-1:0] pd_hist_i,
  output logic               pd_taken_o,
  output logic [META_W-1:0]  pd_meta_o,
  // update (resolved conditional branch)
  input  logic               up_valid_i,
  input  logic [PC_W-1:0]    up_pc_i,
  input  logic [GHR_LEN-1:0] up_hist_i,
  input  logic               up_taken_i,
  input  logic [META_W-1:0]  up_meta_i
);
  localparam int BIDX_W = $clog2(BASE_ENTRIES);
  localparam int IDX_W  = $clog2(ENTRIES);
  localparam int TE_W   = 1 + CTR_W + U_W;            // per-table meta: hit, ctr, u
  localparam logic [CTR_W-1:0] C_WT = {1'b1, {(CTR_W-1){1'b0}}};
  localparam logic [CTR_W-1:0] C_WN = {1'b0, {(CTR_W-1){1'b1}}};
  localparam logic [U_W-1:0]   U_MAX = {U_W{1'b1}};

  // ---- hashes for the predict and update addresses ---------------------------
  logic [NT*IDX_W-1:0] pd_idx, up_idx;
  logic [NT*TAG_W-1:0] pd_tag, up_tag;

  for (genvar t = 0; t < NT; t++) begin : g_hash
    localparam int HL = 32'(HLENS[8*t +: 8]);
    rv_tage_hash #(.PC_W(PC_W), .HLEN(HL), .IDX_W(IDX_W), .TAG_W(TAG_W)) u_hp (
      .pc_i(pd_pc_i), .hist_i(pd_hist_i[HL-1:0]),
      .idx_o(pd_idx[t*IDX_W +: IDX_W]), .tag_o(pd_tag[t*TAG_W +: TAG_W])
    );
    rv_tage_hash #(.PC_W(PC_W), .HLEN(HL), .IDX_W(IDX_W), .TAG_W(TAG_W)) u_hu (
      .pc_i(up_pc_i), .hist_i(up_hist_i[HL-1:0]),
      .idx_o(up_idx[t*IDX_W +: IDX_W]), .tag_o(up_tag[t*TAG_W +: TAG_W])
    );
  end

  // ---- unpack the update meta --------------------------------------------------
  logic [1:0]          m_base;
  logic [NT-1:0]       m_hit;
  logic [NT*CTR_W-1:0] m_ctr;
  logic [NT*U_W-1:0]   m_u;

  always_comb begin
    m_base = up_meta_i[1:0];
    for (int t = 0; t < NT; t++) begin
      m_hit[t]                = up_meta_i[2 + t*TE_W];
      m_ctr[t*CTR_W +: CTR_W] = up_meta_i[2 + t*TE_W + 1 +: CTR_W];
      m_u[t*U_W +: U_W]       = up_meta_i[2 + t*TE_W + 1 + CTR_W +: U_W];
    end
  end

  // ---- update decisions ------------------------------------------------------
  logic             have_prov, prov_pred, alt_pred, final_pred, mispred;
  int               prov, alt;
  logic [NT-1:0]    cand;                 // allocation candidates (longer, u == 0)
  int               first_c, second_c;
  logic             any_c, two_c, found;
  logic [15:0]      lfsr_q;
  logic [RESET_LOG-1:0] upd_cnt_q;
  logic             plane_q;

  always_comb begin
    have_prov = 1'b0;
    prov      = 0;
    alt       = -1;
    for (int t = 0; t < NT; t++) begin
      if (m_hit[t]) begin
        alt       = have_prov ? prov : -1;
        prov      = t;
        have_prov = 1'b1;
      end
    end
    prov_pred  = m_ctr[prov*CTR_W + CTR_W - 1];
    alt_pred   = (alt >= 0) ? m_ctr[alt*CTR_W + CTR_W - 1] : m_base[1];
    final_pred = have_prov ? prov_pred : m_base[1];
    mispred    = (final_pred != up_taken_i);

    cand = '0;
    for (int t = 0; t < NT; t++) begin
      if ((!have_prov || t > prov) && m_u[t*U_W +: U_W] == '0) cand[t] = 1'b1;
    end
    any_c    = (cand != '0);
    first_c  = 0;
    second_c = 0;
    two_c    = 1'b0;
    found    = 1'b0;
    for (int t = 0; t < NT; t++) begin
      if (cand[t]) begin
        if (!found) begin
          first_c = t;
          found   = 1'b1;
        end else if (!two_c) begin
          second_c = t;
          two_c    = 1'b1;
        end
      end
    end
  end

  // ---- write ports -------------------------------------------------------------
  logic             b_we;
  logic [1:0]       b_wctr;
  logic [NT-1:0]    t_we, u_we;
  logic [NT*CTR_W-1:0] t_wctr;
  logic [NT*U_W-1:0]   u_wval;
  logic [U_W-1:0]   u_clear;
  int               alloc_t;

  function automatic logic [1:0] sat2(input logic [1:0] c, input logic up);
    sat2 = up ? ((c == 2'b11) ? c : c + 2'b01) : ((c == 2'b00) ? c : c - 2'b01);
  endfunction
  function automatic logic [CTR_W-1:0] satc(input logic [CTR_W-1:0] c, input logic up);
    satc = up ? ((c == {CTR_W{1'b1}}) ? c : c + 1'b1) : ((c == '0) ? c : c - 1'b1);
  endfunction
  function automatic logic [U_W-1:0] satu(input logic [U_W-1:0] c, input logic up);
    satu = up ? ((c == U_MAX) ? c : c + 1'b1) : ((c == '0) ? c : c - 1'b1);
  endfunction

  always_comb begin
    b_we    = up_valid_i && !have_prov;
    b_wctr  = sat2(m_base, up_taken_i);
    t_we    = '0;
    u_we    = '0;
    t_wctr  = '0;
    u_wval  = '0;
    alloc_t = (two_c && lfsr_q[0]) ? second_c : first_c;
    if (up_valid_i) begin
      if (have_prov) begin
        t_we[prov] = 1'b1;
        t_wctr[prov*CTR_W +: CTR_W] = satc(m_ctr[prov*CTR_W +: CTR_W], up_taken_i);
        if (prov_pred != alt_pred) begin
          u_we[prov] = 1'b1;
          u_wval[prov*U_W +: U_W] = satu(m_u[prov*U_W +: U_W], prov_pred == up_taken_i);
        end
      end
      if (mispred && (!have_prov || prov < NT - 1)) begin
        if (any_c) begin
          t_we[alloc_t] = 1'b1;
          t_wctr[alloc_t*CTR_W +: CTR_W] = up_taken_i ? C_WT : C_WN;
          u_we[alloc_t] = 1'b1;
          u_wval[alloc_t*U_W +: U_W] = '0;
        end else begin
          for (int t = 0; t < NT; t++) begin
            if (!have_prov || t > prov) begin
              u_we[t] = 1'b1;
              u_wval[t*U_W +: U_W] = satu(m_u[t*U_W +: U_W], 1'b0);
            end
          end
        end
      end
    end
    u_clear = '0;
    if (up_valid_i && upd_cnt_q == '1) u_clear[plane_q ? 0 : U_W-1] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr_q    <= 16'hACE1;
      upd_cnt_q <= '0;
      plane_q   <= 1'b0;
    end else if (up_valid_i) begin
      lfsr_q    <= {lfsr_q[14:0], lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
      upd_cnt_q <= upd_cnt_q + 1'b1;
      if (upd_cnt_q == '1) plane_q <= !plane_q;
    end
  end

  // ---- tables ------------------------------------------------------------------
  logic [1:0]          r_base;
  logic [NT-1:0]       r_hit;
  logic [NT*CTR_W-1:0] r_ctr;
  logic [NT*U_W-1:0]   r_u;
  logic                b_init_done;
  logic [NT-1:0]       t_init_done;

  rv_bimodal #(.ENTRIES(BASE_ENTRIES), .CTR_W(2), .LATCH(LATCH)) u_base (
    .clk, .rst_n, .init_done_o(b_init_done),
    .rd_valid_i(pd_valid_i), .rd_idx_i(pd_pc_i[BIDX_W-1:0]), .rd_ctr_o(r_base),
    .wr_valid_i(b_we), .wr_idx_i(up_pc_i[BIDX_W-1:0]), .wr_ctr_i(b_wctr)
  );

  for (genvar t = 0; t < NT; t++) begin : g_tab
    rv_tage_table #(.ENTRIES(ENTRIES), .TAG_W(TAG_W), .CTR_W(CTR_W), .U_W(U_W), .LATCH(LATCH)) u_t (
      .clk, .rst_n, .init_done_o(t_init_done[t]),
      .rd_valid_i(pd_valid_i), .rd_idx_i(pd_idx[t*IDX_W +: IDX_W]), .rd_tag_i(pd_tag[t*TAG_W +: TAG_W]),
      .rd_hit_o(r_hit[t]), .rd_ctr_o(r_ctr[t*CTR_W +: CTR_W]), .rd_u_o(r_u[t*U_W +: U_W]),
      .wr_valid_i(t_we[t]), .wr_idx_i(up_idx[t*IDX_W +: IDX_W]), .wr_tag_i(up_tag[t*TAG_W +: TAG_W]),
      .wr_ctr_i(t_wctr[t*CTR_W +: CTR_W]),
      .u_wr_valid_i(u_we[t]), .u_wr_idx_i(up_idx[t*IDX_W +: IDX_W]), .u_wr_i(u_wval[t*U_W +: U_W]),
      .u_clear_i(u_clear)
    );
  end

  // ---- prediction ----------------------------------------------------------------
  always_comb begin
    pd_taken_o = r_base[1];
    for (int t = 0; t < NT; t++) begin
      if (r_hit[t]) pd_taken_o = r_ctr[t*CTR_W + CTR_W - 1];
    end
    pd_meta_o[1:0] = r_base;
    for (int t = 0; t < NT; t++) begin
      pd_meta_o[2 + t*TE_W]                    = r_hit[t];
      pd_meta_o[2 + t*TE_W + 1 +: CTR_W]       = r_ctr[t*CTR_W +: CTR_W];
      pd_meta_o[2 + t*TE_W + 1 + CTR_W +: U_W] = r_u[t*U_W +: U_W];
    end
  end

  // init status is visible through predictions (weak not taken, no hits)
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = b_init_done ^ (^t_init_done) ^ (^up_pc_i[PC_W-1:BIDX_W]) ^ (^pd_pc_i[PC_W-1:BIDX_W]);
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
