// rv_bimodal - table of saturating counters (TAGE base predictor).
// After reset a walker writes "weakly not taken" into every entry, one per
// cycle; until it finishes (init_done_o) reads return weakly-not-taken and
// writes are dropped. Reads are synchronous (result next cycle); a read and a
// write to the same entry in one cycle return the old value.
module rv_bimodal #(
  parameter int ENTRIES = 64,
  parameter int CTR_W   = 2,
  parameter int LATCH   = 0,
  parameter int IDX_W   = $clog2(ENTRIES)        // derived, do not override
) (
  input  logic             clk,
  input  logic             rst_n,
  output logic             init_done_o,
  input  logic             rd_valid_i,
  input  logic [IDX_W-1:0] rd_idx_i,
  output logic [CTR_W-1:0] rd_ctr_o,
  input  logic             wr_valid_i,
  input  logic [IDX_W-1:0] wr_idx_i,
  input  logic [CTR_W-1:0] wr_ctr_i
);
  localparam logic [CTR_W-1:0] WEAK_NT = {1'b0, {(CTR_W-1){1'b1}}};
  localparam logic [IDX_W-1:0] LAST    = IDX_W'(ENTRIES - 1);

  logic             init_q, rd_init_q;
  logic [IDX_W-1:0] init_idx_q;
  logic [CTR_W-1:0] rdata;

  rv_sram_1r1w #(.W(CTR_W), .DEPTH(ENTRIES), .LATCH(LATCH)) u_mem (
    .clk    (clk),
    .re_i   (rd_valid_i),
    .raddr_i(rd_idx_i),
    .rdata_o(rdata),
    .we_i   (init_q || wr_valid_i),
    .waddr_i(init_q ? init_idx_q : wr_idx_i),
    .wdata_i(init_q ? WEAK_NT : wr_ctr_i)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      init_q     <= 1'b1;
      init_idx_q <= '0;
      rd_init_q  <= 1'b1;
    end else begin
      if (init_q) begin
        init_idx_q <= init_idx_q + 1'b1;
        if (init_idx_q == LAST) init_q <= 1'b0;
      end
      if (rd_valid_i) rd_init_q <= init_q;
    end
  end

  assign init_done_o = !init_q;
  assign rd_ctr_o    = rd_init_q ? WEAK_NT : rdata;
endmodule
