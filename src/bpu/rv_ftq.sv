// rv_ftq - fetch target queue: one entry per predicted fetch block, from
// prediction until all of the block's instructions have resolved.
// The payload (DW bits) is opaque here; rv_bpu packs and unpacks it.
//
// Three pointers: head (oldest live entry), ifu (next entry to fetch) and
// tail (next entry to allocate), each with a wrap bit.
// * redirect: entries younger than redir_idx are discarded, and fetch
//   continues with whatever the predictor allocates next;
// * retire: entries older than ret_idx are freed (the backend reports the
//   FTQ index of each instruction as it passes the resolve stage).
// Two combinational read ports serve training/repair and the backend's
// predicted-target check.
//
// LATCH = 1 stores the entries in latch rows (TT build): the write is staged
// in flops and lands in the low half of the next cycle (as in rv_sram_1r1w);
// during that cycle the read ports bypass from the staging register.
module rv_ftq #(
  parameter int DEPTH = 4,
  parameter int DW    = 64,
  parameter int LATCH = 0,
  parameter int IDX_W = $clog2(DEPTH),           // derived, do not override
  parameter int CNT_W = $clog2(DEPTH + 1)        // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             alloc_i,
  input  logic [DW-1:0]    alloc_data_i,
  output logic [IDX_W-1:0] alloc_idx_o,
  output logic [CNT_W-1:0] free_o,
  output logic             ifu_valid_o,
  output logic [IDX_W-1:0] ifu_idx_o,
  output logic [DW-1:0]    ifu_data_o,
  input  logic             ifu_take_i,
  input  logic [IDX_W-1:0] rd_idx_i,
  output logic [DW-1:0]    rd_data_o,
  input  logic [IDX_W-1:0] rd2_idx_i,
  output logic [DW-1:0]    rd2_data_o,
  input  logic             redir_i,
  input  logic [IDX_W-1:0] redir_idx_i,
  input  logic             ret_i,
  input  logic [IDX_W-1:0] ret_idx_i
);
  localparam int P_W = IDX_W + 1;

  logic [P_W-1:0] head_q, ifu_q, tail_q;

  // full pointer of the live entry whose index is idx (idx is in [head, tail))
  function automatic logic [P_W-1:0] ptr_of(input logic [IDX_W-1:0] idx, input logic [P_W-1:0] head);
    ptr_of = head + P_W'(IDX_W'(idx - head[IDX_W-1:0]));
  endfunction

  assign free_o      = CNT_W'(DEPTH) - CNT_W'(tail_q - head_q);
  assign alloc_idx_o = tail_q[IDX_W-1:0];
  assign ifu_valid_o = (ifu_q != tail_q);
  assign ifu_idx_o   = ifu_q[IDX_W-1:0];

  logic we;
  assign we = alloc_i && !redir_i;

  generate
    if (LATCH == 0) begin : g_flop
      logic [DW-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (we) mem[tail_q[IDX_W-1:0]] <= alloc_data_i;
      end
      assign ifu_data_o = mem[ifu_q[IDX_W-1:0]];
      assign rd_data_o  = mem[rd_idx_i];
      assign rd2_data_o = mem[rd2_idx_i];
    end else begin : g_latch
      logic             we_q;
      logic [IDX_W-1:0] wa_q;
      logic [DW-1:0]    wd_q;
      logic [DEPTH*DW-1:0] rows;
      logic             clk_n;

      always_ff @(posedge clk) begin
        we_q <= we && rst_n;
        if (we) begin
          wa_q <= tail_q[IDX_W-1:0];
          wd_q <= alloc_data_i;
        end
      end
      assign clk_n = ~clk;

      for (genvar r = 0; r < DEPTH; r++) begin : g_row
        logic          gclk;
        logic [DW-1:0] q;
        rv_clock_gate u_cg (.clk_i(clk_n), .en_i(we_q && wa_q == IDX_W'(r)), .gclk_o(gclk));
        always_latch begin
          if (gclk) q = wd_q;
        end
        assign rows[r*DW +: DW] = q;
      end

      // read ports, with the bypass for the row being written this cycle
      assign ifu_data_o = (we_q && wa_q == ifu_q[IDX_W-1:0]) ? wd_q : rows[ifu_q[IDX_W-1:0]*DW +: DW];
      assign rd_data_o  = (we_q && wa_q == rd_idx_i)          ? wd_q : rows[rd_idx_i*DW +: DW];
      assign rd2_data_o = (we_q && wa_q == rd2_idx_i)         ? wd_q : rows[rd2_idx_i*DW +: DW];
    end
  endgenerate

  logic [P_W-1:0] redir_p, ret_p;
  assign redir_p = ptr_of(redir_idx_i, head_q) + 1'b1;
  assign ret_p   = ptr_of(ret_idx_i, head_q);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q <= '0;
      ifu_q  <= '0;
      tail_q <= '0;
    end else begin
      if (redir_i) begin
        tail_q <= redir_p;
        ifu_q  <= redir_p;
      end else begin
        if (alloc_i) tail_q <= tail_q + 1'b1;
        if (ifu_take_i && ifu_valid_o) ifu_q <= ifu_q + 1'b1;
      end
      if (ret_i) head_q <= ret_p;
    end
  end

  initial begin
    if ((DEPTH & (DEPTH - 1)) != 0 || DEPTH < 2) $error("rv_ftq: DEPTH must be a power of 2 >= 2");
  end
endmodule
