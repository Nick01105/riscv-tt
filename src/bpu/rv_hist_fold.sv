// rv_hist_fold - fold a LEN-bit history into W bits by XOR-ing W-bit chunks.
// fold[j] = XOR of hist[i] for all i with i mod W == j.
// Computed from scratch every cycle; fine for short histories and for the
// FULL build in simulation. rv_fold_step is the incremental equivalent.
module rv_hist_fold #(
  parameter int LEN = 12,
  parameter int W   = 4
) (
  input  logic [LEN-1:0] hist_i,
  output logic [W-1:0]   fold_o
);
  always_comb begin
    fold_o = '0;
    for (int i = 0; i < LEN; i++) begin
      fold_o[i % W] = fold_o[i % W] ^ hist_i[i];
    end
  end
endmodule
