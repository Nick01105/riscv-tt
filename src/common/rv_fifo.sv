// rv_fifo - registered synchronous FIFO with valid/ready on both sides.
// in_ready_o depends only on state (no combinational path from out_ready_i),
// so a full FIFO does not accept a push in the same cycle as a pop.
// flush_i empties the FIFO (used on frontend redirects).
module rv_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 4,
  parameter int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,   // derived, do not override
  parameter int CNT_W = $clog2(DEPTH + 1)                   // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             flush_i,
  input  logic             in_valid_i,
  output logic             in_ready_o,
  input  logic [W-1:0]     in_data_i,
  output logic             out_valid_o,
  input  logic             out_ready_i,
  output logic [W-1:0]     out_data_o,
  output logic [CNT_W-1:0] count_o
);
  localparam logic [PTR_W-1:0] LAST  = PTR_W'(DEPTH - 1);
  localparam logic [CNT_W-1:0] FULL  = CNT_W'(DEPTH);
  localparam logic [PTR_W-1:0] P_ONE = {{(PTR_W-1){1'b0}}, 1'b1};
  localparam logic [CNT_W-1:0] C_ONE = {{(CNT_W-1){1'b0}}, 1'b1};

  logic [W-1:0]     mem [DEPTH];
  logic [PTR_W-1:0] rd_ptr, wr_ptr;
  logic [CNT_W-1:0] count;
  logic             push, pop;

  assign in_ready_o  = (count != FULL);
  assign out_valid_o = (count != '0);
  assign out_data_o  = mem[rd_ptr];
  assign count_o     = count;
  assign push        = in_valid_i && in_ready_o;
  assign pop         = out_valid_o && out_ready_i;

  always_ff @(posedge clk) begin
    if (push) mem[wr_ptr] <= in_data_i;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush_i) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count  <= '0;
    end else begin
      if (push) wr_ptr <= (wr_ptr == LAST) ? '0 : wr_ptr + P_ONE;
      if (pop)  rd_ptr <= (rd_ptr == LAST) ? '0 : rd_ptr + P_ONE;
      if (push && !pop)      count <= count + C_ONE;
      else if (pop && !push) count <= count - C_ONE;
    end
  end
endmodule
