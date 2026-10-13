// rv_ras - return address stack, circular (overflow overwrites the oldest).
// top_o is the predicted return address; ptr_o is the checkpoint the FTQ
// saves with each fetch block. On a mispredict, restore_i puts the pointer
// back and rewrites the top entry with the value saved alongside it, which
// repairs the common case of a wrong-path call or return.
// push and pop in the same cycle (jalr with rd and rs1 both links) replace
// the top entry. restore_i wins over push/pop; with restore_push_i or
// restore_pop_i the restored stack then takes the resolved instruction's
// own call or return.
// RESTORE_TOP = 0 restores the pointer only (no top value is checkpointed;
// TT build, saves the FTQ field).
module rv_ras #(
  parameter int DEPTH = 4,
  parameter bit RESTORE_TOP = 1'b1,
  parameter int W     = 31,                       // stored address bits (pc[PW-1:1])
  parameter int PTR_W = $clog2(DEPTH)             // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             push_i,
  input  logic [W-1:0]     push_addr_i,
  input  logic             pop_i,
  input  logic             restore_i,
  input  logic [PTR_W-1:0] restore_ptr_i,
  input  logic [W-1:0]     restore_top_i,
  input  logic             restore_push_i,
  input  logic             restore_pop_i,
  output logic [W-1:0]     top_o,
  output logic [PTR_W-1:0] ptr_o
);
  logic [W-1:0]     stack_q [DEPTH];
  logic [PTR_W-1:0] ptr_q;

  localparam logic [PTR_W-1:0] ONE = {{(PTR_W-1){1'b0}}, 1'b1};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ptr_q <= '0;
      for (int i = 0; i < DEPTH; i++) stack_q[i] <= '0;
    end else if (restore_i) begin
      if (restore_push_i) begin
        ptr_q                        <= restore_ptr_i + ONE;
        if (RESTORE_TOP) stack_q[restore_ptr_i] <= restore_top_i;
        stack_q[restore_ptr_i + ONE] <= push_addr_i;
      end else if (restore_pop_i) begin
        ptr_q                  <= restore_ptr_i - ONE;
        if (RESTORE_TOP) stack_q[restore_ptr_i] <= restore_top_i;
      end else begin
        ptr_q                  <= restore_ptr_i;
        if (RESTORE_TOP) stack_q[restore_ptr_i] <= restore_top_i;
      end
    end else if (push_i && pop_i) begin
      stack_q[ptr_q] <= push_addr_i;
    end else if (push_i) begin
      ptr_q                <= ptr_q + ONE;
      stack_q[ptr_q + ONE] <= push_addr_i;
    end else if (pop_i) begin
      ptr_q <= ptr_q - ONE;
    end
  end

  assign top_o = stack_q[ptr_q];

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^restore_top_i;    // RESTORE_TOP = 0
  /* verilator lint_on UNUSEDSIGNAL */
  assign ptr_o = ptr_q;

  initial begin
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) $error("rv_ras: DEPTH must be a power of 2 >= 2");
  end
endmodule
