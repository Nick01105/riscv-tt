// rv_fold_step - incremental update of a folded history (Seznec's TAGE).
// When a new bit enters a LEN-bit history and the oldest bit leaves:
//   fold' = rotl(fold, 1) ^ new_bit ^ (out_bit << (LEN mod W))
// so fold' equals rv_hist_fold of the shifted history, without an XOR tree.
module rv_fold_step #(
  parameter int LEN = 12,
  parameter int W   = 4
) (
  input  logic [W-1:0] fold_i,
  input  logic         new_bit_i,
  input  logic         out_bit_i,   // hist[LEN-1] before the shift
  output logic [W-1:0] fold_o
);
  localparam int OUT_POS = LEN % W;

  always_comb begin
    fold_o          = {fold_i[W-2:0], fold_i[W-1]};
    fold_o[0]       = fold_o[0] ^ new_bit_i;
    fold_o[OUT_POS] = fold_o[OUT_POS] ^ out_bit_i;
  end

  initial begin
    if (W < 2) $error("rv_fold_step: W must be >= 2");
  end
endmodule
