// rv_ghr - global branch history register with speculative update and
// checkpoint restore. Bit 0 is the most recent branch outcome.
//
// The BPU pushes each predicted direction speculatively. The FTQ saves
// hist_o (before the push) as the checkpoint for that fetch block. On a
// mispredict the backend's resolution restores the checkpoint and pushes the
// real outcome in the same cycle. Restore wins over a speculative push.
module rv_ghr #(
  parameter int LEN = 12
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic           spec_push_i,
  input  logic           spec_bit_i,
  input  logic           restore_i,
  input  logic [LEN-1:0] restore_val_i,
  input  logic           restore_push_i,  // also push restore_bit_i after restoring
  input  logic           restore_bit_i,
  output logic [LEN-1:0] hist_o,
  output logic           out_bit_o        // bit that leaves on the next push (for folded registers)
);
  logic [LEN-1:0] hist_q, hist_d;

  always_comb begin
    hist_d = hist_q;
    if (restore_i) begin
      hist_d = restore_val_i;
      if (restore_push_i) hist_d = {restore_val_i[LEN-2:0], restore_bit_i};
    end else if (spec_push_i) begin
      hist_d = {hist_q[LEN-2:0], spec_bit_i};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) hist_q <= '0;
    else        hist_q <= hist_d;
  end

  assign hist_o    = hist_q;
  assign out_bit_o = hist_q[LEN-1];

  initial begin
    if (LEN < 2) $error("rv_ghr: LEN must be >= 2");
  end
endmodule
