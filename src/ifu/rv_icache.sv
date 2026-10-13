// rv_icache - non-blocking instruction cache controller.
//
// One demand request at a time, answered in order: a hit answers the cycle
// after the request and a new request can be accepted in that same cycle,
// so hits run at one block per cycle. A miss allocates an MSHR, invalidates
// the victim way and requests a WRAP refill; the critical beat is forwarded
// to the fetch unit as soon as it arrives (when a fetch block is one beat).
//
// Non-blocking: kill_i (a fetch redirect) abandons the request at once while
// its refill keeps going in the background, so the new path can hit, or miss
// into another MSHR. A request to a line already being filled joins that
// MSHR instead of refetching it. Ways being filled are never chosen as
// victims.
//
// Addresses above the cacheable range (C_W bits) answer with a fault without
// touching the bus; a bus error on any beat of a refill makes the request
// fault and leaves the line invalid.
module rv_icache #(
  parameter int WAYS        = 1,
  parameter int SETS        = 4,
  parameter int LINE_BYTES  = 16,
  parameter int BEAT_BYTES  = 4,
  parameter int FETCH_BYTES = 4,
  parameter int MSHRS       = 1,
  parameter int PA_W        = 32,
  parameter int C_W         = 25,
  parameter int LATCH       = 0,
  parameter int MIDX_W      = (MSHRS > 1) ? $clog2(MSHRS) : 1   // derived, do not override
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // fetch side
  input  logic                     req_valid_i,
  output logic                     req_ready_o,
  input  logic [PA_W-1:0]          req_addr_i,
  input  logic                     kill_i,
  input  logic                     flush_i,
  output logic                     resp_valid_o,
  output logic [FETCH_BYTES*8-1:0] resp_data_o,
  output logic                     resp_fault_o,
  // refill requests to rv_axi_rd_master
  output logic                     refill_valid_o,
  input  logic                     refill_ready_i,
  output logic [C_W-1:0]           refill_addr_o,
  output logic [MIDX_W-1:0]        refill_mshr_o,
  // refill beats from rv_axi_rd_master
  input  logic                     beat_valid_i,
  input  logic [MIDX_W-1:0]        beat_mshr_i,
  input  logic                     beat_last_i,
  input  logic                     beat_err_i,
  input  logic [BEAT_BYTES*8-1:0]  beat_data_i,
  // events for the performance counters
  output logic                     ev_hit_o,
  output logic                     ev_miss_o
);
  localparam int WAY_W  = (WAYS > 1) ? $clog2(WAYS) : 1;
  localparam int OFF_W  = $clog2(LINE_BYTES);
  localparam int SET_W  = (SETS > 1) ? $clog2(SETS) : 0;
  localparam int LW     = C_W - OFF_W;
  localparam int NBANK  = FETCH_BYTES / BEAT_BYTES;
  localparam int BEAT_B = $clog2(BEAT_BYTES);

  typedef enum logic [2:0] {S_IDLE, S_LOOKUP, S_RETRY, S_BEAT, S_LINE, S_REPLAY} state_e;
  state_e           state_q, state_d;
  logic [PA_W-1:0]  addr_q;
  logic [MIDX_W-1:0] my_mshr_q;
  logic             replay_q;

  logic [C_W-1:0]   caddr;
  logic             uncached;
  assign caddr    = addr_q[C_W-1:0];
  assign uncached = (PA_W > C_W) && ((addr_q >> C_W) != '0);

  // ---- arrays and MSHRs ----------------------------------------------------
  logic                     rd_valid;
  logic [C_W-1:0]           rd_addr;
  logic                     a_hit, a_multi;
  logic [WAY_W-1:0]         a_way, a_victim;
  logic [FETCH_BYTES*8-1:0] a_data;
  logic                     inv_valid;
  logic [WAY_W-1:0]         alloc_way;

  logic                     wd_valid, wt_valid;
  logic [WAY_W-1:0]         wd_way, wt_way;
  logic [C_W-1:0]           wd_addr, wt_addr;

  rv_icache_arrays #(.WAYS(WAYS), .SETS(SETS), .LINE_BYTES(LINE_BYTES), .BEAT_BYTES(BEAT_BYTES),
                     .FETCH_BYTES(FETCH_BYTES), .PW(C_W), .LATCH(LATCH)) u_arrays (
    .clk, .rst_n,
    .rd_valid_i(rd_valid), .rd_addr_i(rd_addr),
    .rd_hit_o(a_hit), .rd_way_o(a_way), .rd_data_o(a_data), .rd_victim_o(a_victim), .rd_multi_o(a_multi),
    .wd_valid_i(wd_valid), .wd_way_i(wd_way), .wd_addr_i(wd_addr), .wd_data_i(beat_data_i),
    .wt_valid_i(wt_valid), .wt_way_i(wt_way), .wt_addr_i(wt_addr),
    .inv_valid_i(inv_valid), .inv_way_i(alloc_way), .inv_addr_i(caddr),
    .flush_i(flush_i)
  );

  logic                  m_free, alloc;
  logic [MIDX_W-1:0]     m_alloc_idx, m_lk_idx, m_done_idx;
  logic                  m_lk_hit, m_lk_ready, m_done, m_done_err, m_mismatch;
  logic [MSHRS-1:0]      m_pend;
  logic [MSHRS*LW-1:0]   m_pend_line;
  logic [MSHRS*WAY_W-1:0] m_pend_way;

  rv_mshr_file #(.N(MSHRS), .PW(C_W), .LINE_BYTES(LINE_BYTES), .BEAT_BYTES(BEAT_BYTES), .WAYS(WAYS)) u_mshr (
    .clk, .rst_n, .flush_i(flush_i),
    .free_o(m_free), .alloc_idx_o(m_alloc_idx), .alloc_i(alloc), .alloc_addr_i(caddr), .alloc_way_i(alloc_way),
    .lookup_addr_i(caddr), .lookup_hit_o(m_lk_hit), .lookup_idx_o(m_lk_idx), .lookup_beat_ready_o(m_lk_ready),
    .beat_valid_i, .beat_mshr_i, .beat_last_i, .beat_err_i,
    .wd_valid_o(wd_valid), .wd_way_o(wd_way), .wd_addr_o(wd_addr),
    .wt_valid_o(wt_valid), .wt_way_o(wt_way), .wt_addr_o(wt_addr),
    .done_o(m_done), .done_idx_o(m_done_idx), .done_err_o(m_done_err), .last_mismatch_o(m_mismatch),
    .pend_valid_o(m_pend), .pend_line_o(m_pend_line), .pend_way_o(m_pend_way)
  );

  // ---- victim: never a way that a pending refill is filling in this set -------
  logic [WAYS-1:0] busy;
  logic            way_ok;

  always_comb begin
    busy = '0;
    for (int i = 0; i < MSHRS; i++) begin
      if (m_pend[i] && (SET_W == 0 || m_pend_line[i*LW +: (SET_W > 0 ? SET_W : 1)] ==
                        caddr[OFF_W +: (SET_W > 0 ? SET_W : 1)])) begin
        busy[m_pend_way[i*WAY_W +: WAY_W]] = 1'b1;
      end
    end
    alloc_way = a_victim;
    way_ok    = !busy[a_victim];
    if (!way_ok) begin
      for (int w = WAYS - 1; w >= 0; w--) begin
        if (!busy[w]) begin
          alloc_way = WAY_W'(w);
          way_ok    = 1'b1;
        end
      end
    end
  end

  // ---- control -------------------------------------------------------------
  logic in_lookup, miss_now, can_alloc, beat_mine, beat_now, just_filled;
  logic wt_q;
  logic [LW-1:0] wt_line_q;

  // A line validated in the cycle of our array read is invisible to it
  // (read-first); without this the lookup would refill the line again.
  assign just_filled = wt_q && (wt_line_q == caddr[C_W-1:OFF_W]);

  assign in_lookup = (state_q == S_LOOKUP);
  assign miss_now  = in_lookup && !kill_i && !uncached && !a_hit && !just_filled;
  assign can_alloc = m_free && refill_ready_i && way_ok;
  // the beat for our MSHR that carries the word we asked for
  assign beat_mine = beat_valid_i && (beat_mshr_i == my_mshr_q) &&
                     (wd_addr[C_W-1:BEAT_B] == caddr[C_W-1:BEAT_B]);
  assign beat_now  = beat_valid_i && (beat_mshr_i == m_lk_idx) &&
                     (wd_addr[C_W-1:BEAT_B] == caddr[C_W-1:BEAT_B]);

  always_comb begin
    state_d        = state_q;
    alloc          = 1'b0;
    inv_valid      = 1'b0;
    refill_valid_o = 1'b0;
    resp_valid_o   = 1'b0;
    resp_fault_o   = 1'b0;
    resp_data_o    = a_data;
    rd_valid       = 1'b0;
    rd_addr        = req_addr_i[C_W-1:0];
    req_ready_o    = 1'b0;

    case (state_q)
      S_LOOKUP: begin
        if (uncached) begin
          resp_valid_o = 1'b1;
          resp_fault_o = 1'b1;
          state_d      = S_IDLE;
        end else if (a_hit) begin
          resp_valid_o = 1'b1;
          state_d      = S_IDLE;
        end else if (just_filled) begin                   // validated after our read: look again
          state_d = S_REPLAY;
        end else if (m_lk_hit) begin                      // line already being filled
          if (NBANK == 1 && beat_now) begin                // our beat arrives this very cycle
            resp_valid_o = 1'b1;
            resp_fault_o = beat_err_i;
            resp_data_o  = {NBANK{beat_data_i}};
            state_d      = S_IDLE;
          end else if (m_done && m_done_idx == m_lk_idx) begin   // the fill ends this cycle
            if (m_done_err) begin
              resp_valid_o = 1'b1;
              resp_fault_o = 1'b1;
              state_d      = S_IDLE;
            end else begin
              state_d = S_REPLAY;
            end
          end else begin
            if (NBANK == 1 && !m_lk_ready) state_d = S_BEAT;
            else                           state_d = S_LINE;
          end
        end else if (can_alloc) begin
          alloc          = 1'b1;
          inv_valid      = 1'b1;
          refill_valid_o = 1'b1;
          if (NBANK == 1) state_d = S_BEAT;
          else            state_d = S_LINE;
        end else begin
          state_d = S_RETRY;
        end
      end
      S_RETRY:  if (m_free && refill_ready_i) state_d = S_REPLAY;
      S_BEAT: begin
        if (beat_mine) begin
          resp_valid_o = 1'b1;
          resp_fault_o = beat_err_i;
          resp_data_o  = {NBANK{beat_data_i}};
          state_d      = S_IDLE;
        end
      end
      S_LINE: begin
        if (m_done && m_done_idx == my_mshr_q) begin
          if (m_done_err) begin
            resp_valid_o = 1'b1;
            resp_fault_o = 1'b1;
            state_d      = S_IDLE;
          end else begin
            state_d = S_REPLAY;
          end
        end
      end
      S_REPLAY: begin
        rd_valid = 1'b1;
        rd_addr  = caddr;
        state_d  = S_LOOKUP;
      end
      default: ;
    endcase

    // accept a new request when idle, after a hit or fault answer, or on a kill
    req_ready_o = kill_i || (state_q == S_IDLE) || (in_lookup && (a_hit || uncached));
    if (kill_i) begin
      resp_valid_o   = 1'b0;
      alloc          = 1'b0;
      inv_valid      = 1'b0;
      refill_valid_o = 1'b0;
      state_d        = S_IDLE;
    end
    if (req_valid_i && req_ready_o) begin
      rd_valid = 1'b1;
      rd_addr  = req_addr_i[C_W-1:0];
      state_d  = S_LOOKUP;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wt_q <= 1'b0;
    end else begin
      wt_q      <= wt_valid;
      wt_line_q <= wt_addr[C_W-1:OFF_W];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q  <= S_IDLE;
      replay_q <= 1'b0;
    end else begin
      state_q <= state_d;
      if (req_valid_i && req_ready_o) begin
        addr_q   <= req_addr_i;
        replay_q <= 1'b0;
      end else if (state_q == S_REPLAY) begin
        replay_q <= 1'b1;
      end
      if (in_lookup && !kill_i) begin
        if (alloc)         my_mshr_q <= m_alloc_idx;
        else if (m_lk_hit) my_mshr_q <= m_lk_idx;
      end
    end
  end

  assign refill_addr_o = caddr;
  assign refill_mshr_o = m_alloc_idx;
  assign ev_hit_o      = in_lookup && !kill_i && !uncached && a_hit && !replay_q;
  assign ev_miss_o     = miss_now && !replay_q;

  // a_way and the protocol flags are for debug only
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{a_way, a_multi, m_mismatch};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
