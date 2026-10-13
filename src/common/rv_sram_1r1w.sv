// rv_sram_1r1w - one read port, one write port, synchronous read.
// Every array in the design goes through this wrapper.
//
// Behaviour (identical for both implementations):
// * Read data appears the cycle after re_i and holds until the next read.
// * A read and a write to the same address in one cycle return the OLD data;
//   the new data is visible to a read issued the next cycle.
// * Contents are not reset; callers keep valid bits in separate flops.
//
// LATCH = 0: flip-flop array (FPGA, FULL build). About 44 um2/bit on SKY130.
// LATCH = 1: latch array (TT build). The write is captured in flops at the
//   clock edge, then the target row's latches are opened during the LOW
//   half of the next cycle through a per-row clock gate on the inverted
//   clock. Nothing samples on the falling edge, so there is no race between
//   the write and a read flop, in simulation or on silicon.
module rv_sram_1r1w #(
  parameter int W      = 32,
  parameter int DEPTH  = 16,
  parameter int LATCH  = 0,          // 1 = latch array (TT build)
  parameter int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1   // derived, do not override
) (
  input  logic              clk,
  input  logic              re_i,
  input  logic [ADDR_W-1:0] raddr_i,
  output logic [W-1:0]      rdata_o,
  input  logic              we_i,
  input  logic [ADDR_W-1:0] waddr_i,
  input  logic [W-1:0]      wdata_i
);
  generate
    if (LATCH == 0) begin : g_flop
      logic [W-1:0] mem [DEPTH];

      always_ff @(posedge clk) begin
        if (we_i) mem[waddr_i] <= wdata_i;
      end

      always_ff @(posedge clk) begin
        if (re_i) rdata_o <= mem[raddr_i];
      end

    end else begin : g_latch
      logic                 we_q;
      logic [ADDR_W-1:0]    waddr_q;
      logic [W-1:0]         wdata_q;
      logic                 clk_n;
      logic [DEPTH*W-1:0]   rows;

      // Stage the write. we_q has no reset: before the first clock edge it
      // can only open a row whose contents are undefined anyway.
      always_ff @(posedge clk) begin
        we_q <= we_i;
        if (we_i) begin
          waddr_q <= waddr_i;
          wdata_q <= wdata_i;
        end
      end

      assign clk_n = ~clk;

      for (genvar r = 0; r < DEPTH; r++) begin : g_row
        logic         gclk;
        logic [W-1:0] q;

        rv_clock_gate u_cg (
          .clk_i (clk_n),
          .en_i  (we_q && (waddr_q == ADDR_W'(r))),
          .gclk_o(gclk)
        );

        always_latch begin
          if (gclk) q = wdata_q;
        end

        assign rows[r*W +: W] = q;
      end

      always_ff @(posedge clk) begin
        if (re_i) rdata_o <= rows[raddr_i*W +: W];
      end
    end
  endgenerate
endmodule
