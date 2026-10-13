// rv_btb - branch target buffer, one entry per fetch block, direct mapped.
// An entry records the predicted control-flow instruction of a block: the
// parcel where it ends (same convention as taken_mask), its type and target.
//
// Lookup is synchronous: request in cycle N, result in N+1. A hit needs a
// valid entry, a matching partial tag, and the instruction's end parcel at
// or after the parcel where fetch entered the block (so a branch that lies
// before a jump target in the same block is ignored).
// Targets keep TGT_W bits (the TT build stores 25: all code lives in the
// 32 MB cacheable space); a target above that range always mispredicts,
// which costs time, never correctness.
// Updates write the whole entry. A lookup and an update to the same index in
// one cycle see the old entry (read-first, like rv_sram_1r1w).
module rv_btb #(
  parameter int ENTRIES = 16,
  parameter int TAG_W   = 8,
  parameter int LATCH   = 0,
  parameter int TGT_W   = frontend_pkg::PADDR_W,  // target bits stored; upper bits read as 0
  parameter int IDX_W   = $clog2(ENTRIES)     // derived, do not override
) (
  input  logic                           clk,
  input  logic                           rst_n,
  // lookup
  input  logic                           lk_valid_i,
  input  frontend_pkg::paddr_t           lk_pc_i,
  output logic                           lk_hit_o,
  output logic [frontend_pkg::NPARCEL-1:0] lk_end_mask_o,   // one-hot end parcel
  output logic [2:0]                     lk_type_o,       // br_type_e
  output frontend_pkg::paddr_t           lk_target_o,
  // update
  input  logic                           up_valid_i,
  input  logic                           up_inval_i,      // clear the entry instead of writing it
  input  frontend_pkg::paddr_t           up_pc_i,         // any pc in the block
  input  logic [frontend_pkg::NPARCEL-1:0] up_end_mask_i,
  input  logic [2:0]                     up_type_i,
  input  frontend_pkg::paddr_t           up_target_i
);
  localparam int PW    = frontend_pkg::PADDR_W;
  localparam int NP    = frontend_pkg::NPARCEL;
  localparam int OFF_W = $clog2(frontend_pkg::FETCH_BYTES);
  localparam int SW    = $clog2(NP);
  localparam int DW    = TAG_W + SW + 3 + (TGT_W - 1);      // tag, end parcel, type, target[TGT_W-1:1]

  // The helpers look at a slice of the pc only.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [IDX_W-1:0] idx_of(input frontend_pkg::paddr_t pc);
    idx_of = pc[OFF_W +: IDX_W];
  endfunction
  function automatic logic [TAG_W-1:0] tag_of(input frontend_pkg::paddr_t pc);
    tag_of = pc[OFF_W + IDX_W +: TAG_W];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic [SW-1:0] enc(input logic [NP-1:0] onehot);
    enc = '0;
    for (int i = 0; i < NP; i++) if (onehot[i]) enc = SW'(i);
  endfunction

  logic [ENTRIES-1:0] valid_q;
  logic               rd_valid_q;
  logic [TAG_W-1:0]   rd_tag_q;
  logic [SW-1:0]      rd_start_q;
  logic [DW-1:0]      rdata;

  rv_sram_1r1w #(.W(DW), .DEPTH(ENTRIES), .LATCH(LATCH)) u_mem (
    .clk    (clk),
    .re_i   (lk_valid_i),
    .raddr_i(idx_of(lk_pc_i)),
    .rdata_o(rdata),
    .we_i   (up_valid_i && !up_inval_i),
    .waddr_i(idx_of(up_pc_i)),
    .wdata_i({tag_of(up_pc_i), enc(up_end_mask_i), up_type_i, up_target_i[TGT_W-1:1]})
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
    end else if (up_valid_i) begin
      valid_q[idx_of(up_pc_i)] <= !up_inval_i;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_valid_q <= 1'b0;
    end else if (lk_valid_i) begin
      rd_valid_q <= valid_q[idx_of(lk_pc_i)];
      rd_tag_q   <= tag_of(lk_pc_i);
      rd_start_q <= lk_pc_i[OFF_W-1:1];
    end else begin
      rd_valid_q <= 1'b0;
    end
  end

  logic [TAG_W-1:0] e_tag;
  logic [SW-1:0]    e_end;

  assign e_tag         = rdata[DW-1 -: TAG_W];
  assign e_end         = rdata[DW-1-TAG_W -: SW];
  assign lk_type_o     = rdata[TGT_W-1 +: 3];
  assign lk_target_o   = PW'({rdata[TGT_W-2:0], 1'b0});
  assign lk_hit_o      = rd_valid_q && (e_tag == rd_tag_q) && (e_end >= rd_start_q);
  assign lk_end_mask_o = NP'(1) << e_end;

  // Only the index and tag bits of the pcs are used; bit 0 of targets is 0.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{lk_pc_i, up_pc_i, up_target_i};
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    if (OFF_W + IDX_W + TAG_W > PW) $error("rv_btb: tag runs past the address");
    if ((ENTRIES & (ENTRIES - 1)) != 0) $error("rv_btb: ENTRIES must be a power of 2");
  end
endmodule
