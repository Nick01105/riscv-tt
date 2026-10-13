// rv_plru - tree pseudo-LRU for one cache set (combinational).
// State has WAYS-1 bits, one per tree node, heap-numbered: node n (1-based)
// lives in state[n-1], its children are 2n and 2n+1, leaves are ways.
// A node bit points at the side holding the victim: 0 = left, 1 = right.
// An access sets every node on the way's path to point away from it.
// For WAYS = 2 this is exact LRU.
module rv_plru #(
  parameter int WAYS  = 4,
  parameter int WAY_W = $clog2(WAYS)          // derived, do not override
) (
  input  logic [WAYS-2:0]  state_i,
  input  logic             access_i,
  input  logic [WAY_W-1:0] access_way_i,
  output logic [WAYS-2:0]  state_o,
  output logic [WAY_W-1:0] victim_o
);
  localparam int LEVELS = WAY_W;

  // Victim: walk from the root following the node bits.
  always_comb begin : victim_walk
    int node;
    node = 1;
    for (int l = 0; l < LEVELS; l++) begin
      node = 2 * node + (state_i[node-1] ? 1 : 0);
    end
    victim_o = WAY_W'(node - WAYS);
  end

  // Update: node n at level l is on the path of way w when
  // (w >> (LEVELS - l)) == n - 2^l. Its new value is the inverse of the
  // direction taken at that level, bit (LEVELS-1-l) of w.
  always_comb begin
    state_o = state_i;
    if (access_i) begin
      for (int l = 0; l < LEVELS; l++) begin
        for (int k = 0; k < (1 << l); k++) begin
          if ((32'(access_way_i) >> (LEVELS - l)) == k) begin
            state_o[(1 << l) + k - 1] = ~access_way_i[LEVELS-1-l];
          end
        end
      end
    end
  end

  initial begin
    if (WAYS < 2 || (WAYS & (WAYS - 1)) != 0) $error("rv_plru: WAYS must be a power of 2 >= 2");
  end
endmodule
