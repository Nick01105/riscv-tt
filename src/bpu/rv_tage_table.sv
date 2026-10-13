// rv_tage_table - one TAGE tagged component: {tag, prediction counter} in an
// array, useful counters in flops (so they can be cleared all at once).
//
// * Reads are synchronous: hit_o compares the stored tag with rd_tag_i of the
//   request. Until the init walker finishes, reads miss.
// * The entry write (tag + counter) and the useful-counter write are separate
//   ports, so allocation and usefulness updates can happen in one cycle.
// * u_clear_i[b] clears bit b of every useful counter (Seznec's periodic
//   graceful reset alternates between the high and low bit).
module rv_tage_table #(
  parameter int ENTRIES = 16,
  parameter int TAG_W   = 6,
  parameter int CTR_W   = 3,
  parameter int U_W     = 2,
  parameter int LATCH   = 0,
  parameter int IDX_W   = $clog2(ENTRIES)        // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  output logic             init_done_o,
  // read
  input  logic             rd_valid_i,
  input  logic [IDX_W-1:0] rd_idx_i,
  input  logic [TAG_W-1:0] rd_tag_i,
  output logic             rd_hit_o,
  output logic [CTR_W-1:0] rd_ctr_o,
  output logic [U_W-1:0]   rd_u_o,
  // entry write
  input  logic             wr_valid_i,
  input  logic [IDX_W-1:0] wr_idx_i,
  input  logic [TAG_W-1:0] wr_tag_i,
  input  logic [CTR_W-1:0] wr_ctr_i,
  // useful counters
  input  logic             u_wr_valid_i,
  input  logic [IDX_W-1:0] u_wr_idx_i,
  input  logic [U_W-1:0]   u_wr_i,
  input  logic [U_W-1:0]   u_clear_i
);
  localparam logic [CTR_W-1:0] WEAK_NT = {1'b0, {(CTR_W-1){1'b1}}};
  localparam logic [IDX_W-1:0] LAST    = IDX_W'(ENTRIES - 1);

  logic             init_q, rd_init_q;
  logic [IDX_W-1:0] init_idx_q;
  logic [TAG_W-1:0] rd_tag_q;
  logic [ENTRIES*U_W-1:0] u_q, u_d;     // entry i at [i*U_W +: U_W]
  logic [U_W-1:0]   rd_u_q;
  logic [TAG_W+CTR_W-1:0] rdata;

  rv_sram_1r1w #(.W(TAG_W + CTR_W), .DEPTH(ENTRIES), .LATCH(LATCH)) u_mem (
    .clk    (clk),
    .re_i   (rd_valid_i),
    .raddr_i(rd_idx_i),
    .rdata_o(rdata),
    .we_i   (init_q || wr_valid_i),
    .waddr_i(init_q ? init_idx_q : wr_idx_i),
    .wdata_i(init_q ? {{TAG_W{1'b0}}, WEAK_NT} : {wr_tag_i, wr_ctr_i})
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      init_q     <= 1'b1;
      init_idx_q <= '0;
      rd_init_q  <= 1'b1;
    end else begin
      if (init_q) begin
        init_idx_q <= init_idx_q + 1'b1;
        if (init_idx_q == LAST) init_q <= 1'b0;
      end
      if (rd_valid_i) begin
        rd_init_q <= init_q;
        rd_tag_q  <= rd_tag_i;
        rd_u_q    <= u_q[rd_idx_i*U_W +: U_W];
      end
    end
  end

  // Useful counters: a clear and a write in the same cycle both apply
  // (the write lands, then the cleared bit is forced to 0 everywhere).
  always_comb begin
    u_d = u_q & ~{ENTRIES{u_clear_i}};
    if (u_wr_valid_i && !init_q) u_d[u_wr_idx_i*U_W +: U_W] = u_wr_i & ~u_clear_i;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) u_q <= '0;
    else        u_q <= u_d;
  end

  assign init_done_o = !init_q;
  assign rd_hit_o    = !rd_init_q && (rdata[TAG_W+CTR_W-1:CTR_W] == rd_tag_q);
  assign rd_ctr_o    = rd_init_q ? WEAK_NT : rdata[CTR_W-1:0];
  assign rd_u_o      = rd_u_q;
endmodule
