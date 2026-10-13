// rv_icache_arrays - storage of a set-associative instruction cache.
//
// Per way: a tag array and the data array, split into NBANK banks of one AXI
// beat each so that a fetch block (FETCH_BYTES) is read in one cycle while
// a refill writes one beat per cycle. Valid bits and PLRU state are flops.
//
// Read (synchronous): request in cycle N, result in N+1. A hit also updates
// the set's PLRU state (in N+1). rd_victim_o is the way to refill on a miss:
// the lowest invalid way, else the PLRU victim.
// Writes: a data beat, a tag (which also sets valid), an invalidate (used on
// the victim when its refill starts), and a full flush (fence.i). All of them
// are read-first with respect to a read in the same cycle, except the flush:
// a read in the flush cycle already misses (fence.i must not let any later
// fetch see a line from before it).
module rv_icache_arrays #(
  parameter int WAYS        = 2,
  parameter int SETS        = 8,
  parameter int LINE_BYTES  = 16,
  parameter int BEAT_BYTES  = 4,
  parameter int FETCH_BYTES = 4,
  parameter int PW          = 32,
  parameter int LATCH       = 0,
  parameter int WAY_W       = (WAYS > 1) ? $clog2(WAYS) : 1   // derived, do not override
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // read
  input  logic                    rd_valid_i,
  input  logic [PW-1:0]           rd_addr_i,
  output logic                    rd_hit_o,
  output logic [WAY_W-1:0]        rd_way_o,
  output logic [FETCH_BYTES*8-1:0] rd_data_o,
  output logic [WAY_W-1:0]        rd_victim_o,
  output logic                    rd_multi_o,
  // refill writes
  input  logic                    wd_valid_i,
  input  logic [WAY_W-1:0]        wd_way_i,
  input  logic [PW-1:0]           wd_addr_i,     // address of the beat
  input  logic [BEAT_BYTES*8-1:0] wd_data_i,
  input  logic                    wt_valid_i,
  input  logic [WAY_W-1:0]        wt_way_i,
  input  logic [PW-1:0]           wt_addr_i,     // any address in the line
  input  logic                    inv_valid_i,
  input  logic [WAY_W-1:0]        inv_way_i,
  input  logic [PW-1:0]           inv_addr_i,
  input  logic                    flush_i
);
  localparam int OFF_W  = $clog2(LINE_BYTES);
  localparam int SET_W  = (SETS > 1) ? $clog2(SETS) : 1;
  localparam int SETB   = (SETS > 1) ? $clog2(SETS) : 0;     // set bits in the address
  localparam int TAG_W  = PW - OFF_W - SETB;
  localparam int BEATS  = LINE_BYTES / BEAT_BYTES;
  localparam int NBANK  = FETCH_BYTES / BEAT_BYTES;
  localparam int BROWS  = BEATS / NBANK;                     // rows per set in one bank
  localparam int BEAT_B = $clog2(BEAT_BYTES);
  localparam int FB_B   = $clog2(FETCH_BYTES);
  localparam int NBK_W  = (NBANK > 1) ? $clog2(NBANK) : 1;
  localparam int ROW_W  = (SETS * BROWS > 1) ? $clog2(SETS * BROWS) : 1;
  localparam int BW     = BEAT_BYTES * 8;
  localparam int PL_W   = (WAYS > 1) ? WAYS - 1 : 1;

  // ---- address helpers -----------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [SET_W-1:0] set_of(input logic [PW-1:0] a);
    set_of = (SETS > 1) ? a[OFF_W +: SET_W] : '0;
  endfunction
  function automatic logic [TAG_W-1:0] tag_of(input logic [PW-1:0] a);
    tag_of = a[PW-1 -: TAG_W];
  endfunction
  // Row inside a bank: {set, fetch block within the line}. A beat lives in the
  // row of the fetch block that contains it, in bank (beat index mod NBANK).
  function automatic logic [ROW_W-1:0] row_of(input logic [PW-1:0] a);
    logic [SET_W+OFF_W-1:0] so;
    so     = {set_of(a), a[OFF_W-1:0]};
    row_of = ROW_W'(so >> FB_B);
  endfunction
  function automatic logic [NBK_W-1:0] bank_of(input logic [PW-1:0] a);
    bank_of = (NBANK > 1) ? NBK_W'(a[FB_B-1:0] >> BEAT_B) : '0;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- arrays --------------------------------------------------------------
  logic [WAYS*TAG_W-1:0]        rd_tags;
  logic [WAYS*FETCH_BYTES*8-1:0] rd_lines;

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    rv_sram_1r1w #(.W(TAG_W), .DEPTH(SETS), .LATCH(LATCH)) u_tag (
      .clk(clk), .re_i(rd_valid_i), .raddr_i(set_of(rd_addr_i)), .rdata_o(rd_tags[w*TAG_W +: TAG_W]),
      .we_i(wt_valid_i && wt_way_i == WAY_W'(w)), .waddr_i(set_of(wt_addr_i)), .wdata_i(tag_of(wt_addr_i))
    );
    for (genvar b = 0; b < NBANK; b++) begin : g_bank
      rv_sram_1r1w #(.W(BW), .DEPTH(SETS * BROWS), .LATCH(LATCH)) u_data (
        .clk(clk), .re_i(rd_valid_i), .raddr_i(row_of(rd_addr_i)),
        .rdata_o(rd_lines[(w*NBANK + b)*BW +: BW]),
        .we_i(wd_valid_i && wd_way_i == WAY_W'(w) && bank_of(wd_addr_i) == NBK_W'(b)),
        .waddr_i(row_of(wd_addr_i)), .wdata_i(wd_data_i)
      );
    end
  end

  // ---- valid bits and PLRU state -------------------------------------------
  logic [SETS*WAYS-1:0] valid_q;     // set s, way w at bit s*WAYS + w
  logic [SETS*PL_W-1:0] plru_q;

  logic             rd_q;
  logic [SET_W-1:0] rd_set_q;
  logic [TAG_W-1:0] rd_tag_q;
  logic [WAYS-1:0]  rd_vld_q;
  logic [PL_W-1:0]  rd_plru_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_q <= 1'b0;
    end else begin
      rd_q <= rd_valid_i;
      if (rd_valid_i) begin
        rd_set_q  <= set_of(rd_addr_i);
        rd_tag_q  <= tag_of(rd_addr_i);
        rd_vld_q  <= flush_i ? '0 : valid_q[set_of(rd_addr_i)*WAYS +: WAYS];   // a read in the flush cycle sees the flush
        rd_plru_q <= plru_q[set_of(rd_addr_i)*PL_W +: PL_W];
      end
    end
  end

  logic [WAYS-1:0] hit_vec;
  logic            hit;
  logic [WAY_W-1:0] hit_way;

  rv_tag_cmp #(.WAYS(WAYS), .TAG_W(TAG_W)) u_cmp (
    .tags_i(rd_tags), .valid_i(rd_vld_q), .tag_i(rd_tag_q),
    .hit_vec_o(hit_vec), .hit_o(hit), .hit_way_o(hit_way), .multi_hit_o(rd_multi_o)
  );

  logic [PL_W-1:0]  plru_next;
  logic [WAY_W-1:0] plru_victim;

  if (WAYS > 1) begin : g_plru
    rv_plru #(.WAYS(WAYS)) u_plru (
      .state_i(rd_plru_q), .access_i(1'b1), .access_way_i(hit_way),
      .state_o(plru_next), .victim_o(plru_victim)
    );
  end else begin : g_noplru
    assign plru_next   = '0;
    assign plru_victim = '0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush_i) begin
      valid_q <= '0;
    end else begin
      if (inv_valid_i) valid_q[set_of(inv_addr_i)*WAYS + 32'(inv_way_i)] <= 1'b0;
      if (wt_valid_i)  valid_q[set_of(wt_addr_i)*WAYS + 32'(wt_way_i)]   <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      plru_q <= '0;
    end else if (rd_q && hit) begin
      plru_q[rd_set_q*PL_W +: PL_W] <= plru_next;
    end
  end

  // ---- outputs -------------------------------------------------------------
  always_comb begin
    rd_victim_o = plru_victim;
    for (int w = WAYS - 1; w >= 0; w--) begin
      if (!rd_vld_q[w]) rd_victim_o = WAY_W'(w);
    end
  end

  assign rd_hit_o  = rd_q && hit;
  assign rd_way_o  = hit_way;
  assign rd_data_o = rd_lines[hit_way*FETCH_BYTES*8 +: FETCH_BYTES*8];

  // hit_vec is summarised by rv_tag_cmp; PLRU state is unused with one way.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{hit_vec, rd_plru_q};
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    if (FETCH_BYTES < BEAT_BYTES || LINE_BYTES < FETCH_BYTES) $error("rv_icache_arrays: need BEAT <= FETCH <= LINE");
  end
endmodule
