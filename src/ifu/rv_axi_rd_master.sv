// rv_axi_rd_master - AXI4 read master for I-cache line refills.
// A refill request becomes one WRAP burst of a whole line that starts at the
// missing beat (critical word first). The MSHR index is the AXI ID, so
// returning beats are routed back to their MSHR; bursts with different IDs
// may interleave. The AR channel is registered and holds its payload until
// accepted. R is always accepted (the cache arrays take a beat every cycle).
module rv_axi_rd_master #(
  parameter int C_W        = 25,      // address bits of a refill request
  parameter int LINE_BYTES = 16,
  parameter int BEAT_BYTES = 4,
  parameter int IDX_W      = 1
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // refill requests
  input  logic                   req_valid_i,
  output logic                   req_ready_o,
  input  logic [C_W-1:0]         req_addr_i,     // missing address
  input  logic [IDX_W-1:0]       req_mshr_i,
  // AXI AR
  output logic                   ar_valid_o,
  input  logic                   ar_ready_i,
  output frontend_pkg::axi_ar_t  ar_o,
  // AXI R
  input  logic                   r_valid_i,
  output logic                   r_ready_o,
  input  frontend_pkg::axi_r_t   r_i,
  // refill beats
  output logic                   beat_valid_o,
  output logic [IDX_W-1:0]       beat_mshr_o,
  output logic                   beat_last_o,
  output logic                   beat_err_o,
  output logic [BEAT_BYTES*8-1:0] beat_data_o
);
  localparam int PW     = frontend_pkg::PADDR_W;
  localparam int BEAT_B = $clog2(BEAT_BYTES);
  localparam int BEATS  = LINE_BYTES / BEAT_BYTES;

  logic                  ar_valid_q;
  frontend_pkg::axi_ar_t ar_q;

  assign req_ready_o = !ar_valid_q || ar_ready_i;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar_valid_q <= 1'b0;
    end else if (req_ready_o) begin
      ar_valid_q <= req_valid_i;
      if (req_valid_i) begin
        ar_q.id    <= frontend_pkg::AXI_ID_W'(req_mshr_i);
        ar_q.addr  <= PW'({req_addr_i[C_W-1:BEAT_B], {BEAT_B{1'b0}}});
        ar_q.len   <= 8'(BEATS - 1);
        ar_q.size  <= 3'(BEAT_B);
        ar_q.burst <= frontend_pkg::AXI_BURST_WRAP;
        ar_q.lock  <= 1'b0;
        ar_q.cache <= 4'b0010;          // normal, non-cacheable at the slave
        ar_q.prot  <= 3'b100;           // instruction, secure, unprivileged
      end
    end
  end

  assign ar_valid_o   = ar_valid_q;
  assign ar_o         = ar_q;
  assign r_ready_o    = 1'b1;
  assign beat_valid_o = r_valid_i;
  assign beat_mshr_o  = IDX_W'(r_i.id);
  assign beat_last_o  = r_i.last;
  assign beat_err_o   = r_i.resp[1];      // SLVERR or DECERR
  assign beat_data_o  = r_i.data[BEAT_BYTES*8-1:0];

  // Address bits below the beat are not sent; IDs above IDX_W are never used.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{req_addr_i[BEAT_B-1:0], r_i.id, r_i.resp[0], r_i.data};
  /* verilator lint_on UNUSEDSIGNAL */

  initial begin
    if (BEAT_BYTES * 8 != frontend_pkg::AXI_DATA_W) $error("rv_axi_rd_master: beat width must equal AXI_DATA_W");
    if (IDX_W > frontend_pkg::AXI_ID_W) $error("rv_axi_rd_master: MSHR index wider than AXI ID");
  end
endmodule
