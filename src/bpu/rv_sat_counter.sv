// rv_sat_counter - W-bit saturating up/down counter (combinational next state).
// Used for the bimodal base table, TAGE prediction counters and useful bits.
// The MSB is the prediction: 1 = taken.
module rv_sat_counter #(
  parameter int W = 2
) (
  input  logic [W-1:0] cnt_i,
  input  logic         upd_i,     // apply an update this cycle
  input  logic         taken_i,   // update direction: 1 = count up
  output logic [W-1:0] cnt_o,     // next value
  output logic         pred_o,    // MSB of cnt_i
  output logic         weak_o,    // cnt_i is one of the two middle values
  output logic         sat_o      // cnt_i is at the minimum or maximum
);
  localparam logic [W-1:0] MAX = {W{1'b1}};
  localparam logic [W-1:0] MIN = {W{1'b0}};
  localparam logic [W-1:0] ONE = {{(W-1){1'b0}}, 1'b1};
  localparam logic [W-1:0] WT  = {1'b1, {(W-1){1'b0}}};   // weakly taken      10..0
  localparam logic [W-1:0] WN  = {1'b0, {(W-1){1'b1}}};   // weakly not taken  01..1

  always_comb begin
    cnt_o = cnt_i;
    if (upd_i) begin
      if (taken_i && (cnt_i != MAX))       cnt_o = cnt_i + ONE;
      else if (!taken_i && (cnt_i != MIN)) cnt_o = cnt_i - ONE;
    end
  end

  assign pred_o = cnt_i[W-1];
  assign weak_o = (cnt_i == WT) || (cnt_i == WN);
  assign sat_o  = (cnt_i == MAX) || (cnt_i == MIN);

  // W must be at least 2 (the replications above need W-1 >= 1).
  initial begin
    if (W < 2) $error("rv_sat_counter: W must be >= 2");
  end
endmodule
