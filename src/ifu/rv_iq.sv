// rv_iq - instruction queue between the aligner and decode.
// Takes the valid slots of one fetch block per cycle (up to NP, sparse by
// parcel position) and packs them in program order; hands out up to OUT_W
// slots per cycle from the head. in_ready_o needs room for a whole block
// and depends only on the queue's count.
module rv_iq #(
  parameter int NP     = 2,
  parameter int OUT_W  = 1,
  parameter int DEPTH  = 4,
  parameter int SW     = 64,                  // slot width
  parameter int CNT_W  = $clog2(DEPTH + 1)    // derived, do not override
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               flush_i,
  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [NP-1:0]      in_mask_i,
  input  logic [NP*SW-1:0]   in_slots_i,
  output logic [OUT_W-1:0]   out_valid_o,
  output logic [OUT_W*SW-1:0] out_slots_o,
  input  logic [OUT_W-1:0]   out_ready_i,     // slot k is taken only if slots 0..k-1 are taken
  output logic [CNT_W-1:0]   count_o
);
  localparam int PW_ = $clog2(DEPTH);

  logic [SW-1:0]    mem [DEPTH];
  logic [PW_-1:0]   head_q, tail_q;
  logic [CNT_W-1:0] count_q;
  logic [CNT_W-1:0] n_in, n_out;

  assign in_ready_o = (32'(count_q) + NP <= DEPTH);
  assign count_o    = count_q;

  always_comb begin
    n_in = '0;
    if (in_valid_i && in_ready_o) begin
      for (int p = 0; p < NP; p++) if (in_mask_i[p]) n_in = n_in + 1'b1;
    end
    n_out = '0;
    for (int k = 0; k < OUT_W; k++) begin
      if (32'(n_out) == k && out_valid_o[k] && out_ready_i[k]) n_out = n_out + 1'b1;
    end
  end

  for (genvar k = 0; k < OUT_W; k++) begin : g_out
    assign out_valid_o[k]           = (32'(count_q) > k);
    assign out_slots_o[k*SW +: SW]  = mem[PW_'(32'(head_q) + k)];
  end

  always_ff @(posedge clk) begin
    if (in_valid_i && in_ready_o) begin : wr
      int pos;
      pos = 0;
      for (int p = 0; p < NP; p++) begin
        if (in_mask_i[p]) begin
          mem[PW_'(32'(tail_q) + pos)] <= in_slots_i[p*SW +: SW];
          pos = pos + 1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush_i) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      head_q  <= PW_'(32'(head_q) + 32'(n_out));
      tail_q  <= PW_'(32'(tail_q) + 32'(n_in));
      count_q <= count_q + n_in - n_out;
    end
  end

  initial begin
    if ((DEPTH & (DEPTH - 1)) != 0 || DEPTH < NP) $error("rv_iq: DEPTH must be a power of 2 and >= NP");
  end
endmodule
