// rv_mshr_file - miss status holding registers for the non-blocking I-cache.
// Each entry tracks one line refill: line address, the way being filled, the
// beat the miss started on (WRAP bursts return it first), beats received,
// and whether the fill must be discarded (fence.i during the refill) or hit
// a bus error.
//
// * alloc_i takes the lowest free entry (free_o / alloc_idx_o say which).
//   The caller must not allocate a line that lookup_hit_o reports as pending.
// * Each refill beat (from AXI R, routed by ID) produces a data write for the
//   cache arrays. The last beat also produces the tag write that makes the
//   line valid, unless the fill was flushed or saw an error, and frees the
//   entry. All of these outputs are combinational from the beat inputs.
// * lookup_* lets the fetch unit see whether a missing line is already being
//   fetched, and whether the beat it wants has already arrived (its data is
//   in the array even though the line is not valid yet). Fills started before
//   a flush are not reported: their data may predate a fence.i.
module rv_mshr_file #(
  parameter int N          = 2,
  parameter int PW         = 32,
  parameter int LINE_BYTES = 16,
  parameter int BEAT_BYTES = 4,
  parameter int WAYS       = 2,
  parameter int IDX_W      = (N > 1) ? $clog2(N) : 1,          // derived, do not override
  parameter int WAY_W      = (WAYS > 1) ? $clog2(WAYS) : 1     // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             flush_i,          // fence.i: pending fills must not validate
  // allocation
  output logic             free_o,
  output logic [IDX_W-1:0] alloc_idx_o,
  input  logic             alloc_i,
  input  logic [PW-1:0]    alloc_addr_i,     // missing address (any byte of the line)
  input  logic [WAY_W-1:0] alloc_way_i,
  // lookup
  input  logic [PW-1:0]    lookup_addr_i,
  output logic             lookup_hit_o,
  output logic [IDX_W-1:0] lookup_idx_o,
  output logic             lookup_beat_ready_o,
  // refill beats
  input  logic             beat_valid_i,
  input  logic [IDX_W-1:0] beat_mshr_i,
  input  logic             beat_last_i,
  input  logic             beat_err_i,
  // writes to rv_icache_arrays
  output logic             wd_valid_o,
  output logic [WAY_W-1:0] wd_way_o,
  output logic [PW-1:0]    wd_addr_o,
  output logic             wt_valid_o,
  output logic [WAY_W-1:0] wt_way_o,
  output logic [PW-1:0]    wt_addr_o,
  // completion
  output logic             done_o,
  output logic [IDX_W-1:0] done_idx_o,
  output logic             done_err_o,
  output logic             last_mismatch_o,  // RLAST disagrees with the beat count (protocol error)
  // pending fills, so the controller never picks a way that is being filled
  output logic [N-1:0]               pend_valid_o,
  output logic [N*(PW-$clog2(LINE_BYTES))-1:0] pend_line_o,
  output logic [N*WAY_W-1:0]         pend_way_o
);
  localparam int OFF_W  = $clog2(LINE_BYTES);
  localparam int BEATS  = LINE_BYTES / BEAT_BYTES;
  localparam int BB     = $clog2(BEATS);
  localparam int BEAT_B = $clog2(BEAT_BYTES);
  localparam int LW     = PW - OFF_W;
  localparam int CNT_W  = $clog2(BEATS + 1);

  logic [N-1:0]     v_q, nofill_q, err_q;
  logic [LW-1:0]    line_q  [N];
  logic [WAY_W-1:0] way_q   [N];
  logic [BB-1:0]    start_q [N];
  logic [CNT_W-1:0] cnt_q   [N];
  logic [BEATS-1:0] recv_q  [N];

  // ---- allocation ----------------------------------------------------------
  always_comb begin
    free_o      = 1'b0;
    alloc_idx_o = '0;
    for (int i = N - 1; i >= 0; i--) begin
      if (!v_q[i]) begin
        free_o      = 1'b1;
        alloc_idx_o = IDX_W'(i);
      end
    end
  end

  // ---- lookup ----------------------------------------------------------------
  logic [BB-1:0] lk_beat;
  assign lk_beat = lookup_addr_i[OFF_W-1:BEAT_B];

  always_comb begin
    lookup_hit_o        = 1'b0;
    lookup_idx_o        = '0;
    lookup_beat_ready_o = 1'b0;
    for (int i = N - 1; i >= 0; i--) begin
      if (v_q[i] && !nofill_q[i] && line_q[i] == lookup_addr_i[PW-1:OFF_W]) begin
        lookup_hit_o        = 1'b1;
        lookup_idx_o        = IDX_W'(i);
        lookup_beat_ready_o = recv_q[i][lk_beat];
      end
    end
  end

  // ---- refill beat ---------------------------------------------------------
  logic [BB-1:0]    beat_idx;
  logic [CNT_W-1:0] cnt_cur;
  logic             last_by_count;

  assign cnt_cur       = cnt_q[beat_mshr_i];
  assign beat_idx      = BB'(start_q[beat_mshr_i] + BB'(cnt_cur));     // WRAP order
  assign last_by_count = (cnt_cur == CNT_W'(BEATS - 1));

  assign wd_valid_o = beat_valid_i;
  assign wd_way_o   = way_q[beat_mshr_i];
  assign wd_addr_o  = {line_q[beat_mshr_i], beat_idx, {BEAT_B{1'b0}}};

  assign done_o          = beat_valid_i && beat_last_i;
  assign done_idx_o      = beat_mshr_i;
  assign done_err_o      = err_q[beat_mshr_i] || beat_err_i;
  assign wt_valid_o      = done_o && !nofill_q[beat_mshr_i] && !done_err_o && !flush_i;
  assign wt_way_o        = way_q[beat_mshr_i];
  assign wt_addr_o       = {line_q[beat_mshr_i], {OFF_W{1'b0}}};
  assign last_mismatch_o = beat_valid_i && (beat_last_i != last_by_count);

  // ---- state ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_q      <= '0;
      nofill_q <= '0;
      err_q    <= '0;
    end else begin
      if (beat_valid_i) begin
        cnt_q[beat_mshr_i]            <= cnt_cur + 1'b1;
        recv_q[beat_mshr_i][beat_idx] <= 1'b1;
        if (beat_err_i) err_q[beat_mshr_i] <= 1'b1;
        if (beat_last_i) v_q[beat_mshr_i]  <= 1'b0;
      end
      if (flush_i) nofill_q <= nofill_q | v_q;
      if (alloc_i && free_o) begin
        v_q[alloc_idx_o]      <= 1'b1;
        nofill_q[alloc_idx_o] <= 1'b0;
        err_q[alloc_idx_o]    <= 1'b0;
        line_q[alloc_idx_o]   <= alloc_addr_i[PW-1:OFF_W];
        way_q[alloc_idx_o]    <= alloc_way_i;
        start_q[alloc_idx_o]  <= alloc_addr_i[OFF_W-1:BEAT_B];
        cnt_q[alloc_idx_o]    <= '0;
        recv_q[alloc_idx_o]   <= '0;
      end
    end
  end

  for (genvar i = 0; i < N; i++) begin : g_pend
    assign pend_line_o[i*LW +: LW]       = line_q[i];
    assign pend_way_o[i*WAY_W +: WAY_W]  = way_q[i];
  end
  assign pend_valid_o = v_q;

  // Address bits below the beat are not used.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{alloc_addr_i[BEAT_B-1:0], lookup_addr_i[BEAT_B-1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    if (BEATS < 2) $error("rv_mshr_file: a line must be at least two beats");
  end
endmodule
