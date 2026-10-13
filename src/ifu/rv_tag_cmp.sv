// rv_tag_cmp - parallel tag compare across the ways of one set.
// multi_hit_o flags a corrupted set (two valid ways with the same tag);
// the cache controller treats it as a miss in debug builds.
module rv_tag_cmp #(
  parameter int WAYS  = 2,
  parameter int TAG_W = 20,
  parameter int WAY_W = (WAYS > 1) ? $clog2(WAYS) : 1   // derived, do not override
) (
  input  logic [WAYS*TAG_W-1:0] tags_i,    // way w at [w*TAG_W +: TAG_W]
  input  logic [WAYS-1:0]       valid_i,
  input  logic [TAG_W-1:0]      tag_i,
  output logic [WAYS-1:0]       hit_vec_o,
  output logic                  hit_o,
  output logic [WAY_W-1:0]      hit_way_o, // index of the lowest hitting way
  output logic                  multi_hit_o
);
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      hit_vec_o[w] = valid_i[w] && (tags_i[w*TAG_W +: TAG_W] == tag_i);
    end
  end

  always_comb begin
    hit_way_o = '0;
    for (int w = WAYS - 1; w >= 0; w--) begin
      if (hit_vec_o[w]) hit_way_o = WAY_W'(w);
    end
  end

  assign hit_o       = |hit_vec_o;
  assign multi_hit_o = |(hit_vec_o & (hit_vec_o - 1'b1));
endmodule
