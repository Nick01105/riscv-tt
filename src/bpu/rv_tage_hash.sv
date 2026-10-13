// rv_tage_hash - index and tag hash for one TAGE tagged table.
//   idx = pc[IDX_W-1:0] ^ pc[2*IDX_W-1:IDX_W] ^ fold(hist, IDX_W)
//   tag = pc[TAG_W-1:0] ^ fold(hist, TAG_W) ^ (fold(hist, TAG_W-1) << 1)
// pc_i is the PC with its always-zero low bits already removed by the caller
// (for example pc >> 1, or the fetch-block address).
module rv_tage_hash #(
  parameter int PC_W  = 31,
  parameter int HLEN  = 12,
  parameter int IDX_W = 4,
  parameter int TAG_W = 6
) (
  input  logic [PC_W-1:0]  pc_i,
  input  logic [HLEN-1:0]  hist_i,   // the table's own history length (low HLEN bits of the GHR)
  output logic [IDX_W-1:0] idx_o,
  output logic [TAG_W-1:0] tag_o
);
  logic [IDX_W-1:0] f_idx;
  logic [TAG_W-1:0] f_tag1;
  logic [TAG_W-2:0] f_tag2;

  rv_hist_fold #(.LEN(HLEN), .W(IDX_W))   u_fi (.hist_i(hist_i), .fold_o(f_idx));
  rv_hist_fold #(.LEN(HLEN), .W(TAG_W))   u_f1 (.hist_i(hist_i), .fold_o(f_tag1));
  rv_hist_fold #(.LEN(HLEN), .W(TAG_W-1)) u_f2 (.hist_i(hist_i), .fold_o(f_tag2));

  assign idx_o = pc_i[IDX_W-1:0] ^ pc_i[2*IDX_W-1:IDX_W] ^ f_idx;
  assign tag_o = pc_i[TAG_W-1:0] ^ f_tag1 ^ {f_tag2, 1'b0};

  // Upper PC bits are not hashed.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_pc;
  assign unused_pc = ^pc_i;
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    if (PC_W < 2 * IDX_W || PC_W < TAG_W) $error("rv_tage_hash: PC_W too small");
    if (TAG_W < 3) $error("rv_tage_hash: TAG_W must be >= 3");
  end
endmodule
