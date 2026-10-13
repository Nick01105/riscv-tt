// rv_rr_arbiter - round-robin arbiter, one-hot grant.
// The grant is combinational from req_i. When accept_i is high the priority
// moves to the requester after the one granted, so every steady requester is
// served within N accepted grants.
module rv_rr_arbiter #(
  parameter int N     = 4,
  parameter int IDX_W = (N > 1) ? $clog2(N) : 1   // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [N-1:0]     req_i,
  input  logic             accept_i,     // the granted requester was served
  output logic [N-1:0]     grant_o,
  output logic [IDX_W-1:0] grant_idx_o,
  output logic             any_o
);
  localparam logic [N-1:0] ONE = {{(N-1){1'b0}}, 1'b1};

  logic [N-1:0] mask_q;          // 1 = may win before wrapping around
  logic [N-1:0] masked, pick_from;

  assign masked    = req_i & mask_q;
  assign pick_from = (masked != '0) ? masked : req_i;
  assign grant_o   = pick_from & (~pick_from + ONE);   // lowest set bit
  assign any_o     = (req_i != '0);

  always_comb begin
    grant_idx_o = '0;
    for (int i = 0; i < N; i++) begin
      if (grant_o[i]) grant_idx_o = IDX_W'(i);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                mask_q <= '1;
    else if (accept_i && any_o) mask_q <= ~((grant_o << 1) - ONE);   // bits above the winner
  end
endmodule
