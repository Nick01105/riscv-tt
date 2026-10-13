// rv_regfile - integer register file: NREGS-1 rows (x0 reads as zero),
// two synchronous read ports, one write port.
//
// Same timing as rv_sram_1r1w: read data appears the cycle after re_i; a
// write is visible to reads issued the cycle after we_i (a read in the same
// cycle as the write returns the old value, so the backend forwards it).
//
// LATCH = 0: flop rows. LATCH = 1: latch rows written in the low phase
// through per-row clock gates (see rv_sram_1r1w), both read ports share the
// storage, so the second port costs only its multiplexer.
module rv_regfile #(
  parameter int W      = 32,
  parameter int NREGS  = 16,
  parameter int LATCH  = 0,
  parameter int ADDR_W = $clog2(NREGS)              // derived, do not override
) (
  input  logic              clk,
  input  logic              re_i,
  input  logic [ADDR_W-1:0] raddr1_i,
  input  logic [ADDR_W-1:0] raddr2_i,
  output logic [W-1:0]      rdata1_o,
  output logic [W-1:0]      rdata2_o,
  input  logic              we_i,
  input  logic [ADDR_W-1:0] waddr_i,
  input  logic [W-1:0]      wdata_i
);
  logic [NREGS*W-1:0] rows;              // row 0 is constant zero

  assign rows[W-1:0] = '0;

  generate
    if (LATCH == 0) begin : g_flop
      for (genvar r = 1; r < NREGS; r++) begin : g_row
        logic [W-1:0] q;
        always_ff @(posedge clk) begin
          if (we_i && waddr_i == ADDR_W'(r)) q <= wdata_i;
        end
        assign rows[r*W +: W] = q;
      end
    end else begin : g_latch
      logic              we_q;
      logic [ADDR_W-1:0] waddr_q;
      logic [W-1:0]      wdata_q;
      logic              clk_n;

      always_ff @(posedge clk) begin
        we_q <= we_i;
        if (we_i) begin
          waddr_q <= waddr_i;
          wdata_q <= wdata_i;
        end
      end

      assign clk_n = ~clk;

      for (genvar r = 1; r < NREGS; r++) begin : g_row
        logic         gclk;
        logic [W-1:0] q;
        rv_clock_gate u_cg (.clk_i(clk_n), .en_i(we_q && (waddr_q == ADDR_W'(r))), .gclk_o(gclk));
        always_latch begin
          if (gclk) q = wdata_q;
        end
        assign rows[r*W +: W] = q;
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (re_i) begin
      rdata1_o <= rows[raddr1_i*W +: W];
      rdata2_o <= rows[raddr2_i*W +: W];
    end
  end

  initial begin
    if ((NREGS & (NREGS - 1)) != 0) $error("rv_regfile: NREGS must be a power of 2");
  end
endmodule
