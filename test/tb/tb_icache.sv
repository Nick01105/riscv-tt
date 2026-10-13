// Test top: rv_icache + rv_axi_rd_master with flat AXI ports for the model.
module tb_icache #(
  parameter int WAYS = 1, parameter int SETS = 4, parameter int LINE_BYTES = 16,
  parameter int BEAT_BYTES = 4, parameter int FETCH_BYTES = 4, parameter int MSHRS = 1,
  parameter int PA_W = 32, parameter int C_W = 25, parameter int LATCH = 0
) (
  input  logic clk, rst_n,
  input  logic req_valid_i, output logic req_ready_o, input logic [PA_W-1:0] req_addr_i,
  input  logic kill_i, flush_i,
  output logic resp_valid_o, output logic [FETCH_BYTES*8-1:0] resp_data_o, output logic resp_fault_o,
  output logic ev_hit_o, ev_miss_o,
  output logic ar_valid, input logic ar_ready, output logic [frontend_pkg::AXI_AR_W-1:0] ar,
  input  logic r_valid, output logic r_ready, input logic [frontend_pkg::AXI_R_W-1:0] r
);
  localparam int MIDX_W = (MSHRS > 1) ? $clog2(MSHRS) : 1;
  logic refill_valid, refill_ready, beat_valid, beat_last, beat_err;
  logic [C_W-1:0] refill_addr;
  logic [MIDX_W-1:0] refill_mshr, beat_mshr;
  logic [BEAT_BYTES*8-1:0] beat_data;
  frontend_pkg::axi_ar_t ar_s;
  frontend_pkg::axi_r_t  r_s;
  assign ar  = ar_s;
  assign r_s = r;

  rv_icache #(.WAYS(WAYS), .SETS(SETS), .LINE_BYTES(LINE_BYTES), .BEAT_BYTES(BEAT_BYTES),
              .FETCH_BYTES(FETCH_BYTES), .MSHRS(MSHRS), .PA_W(PA_W), .C_W(C_W), .LATCH(LATCH)) u_ic (
    .clk, .rst_n, .req_valid_i, .req_ready_o, .req_addr_i, .kill_i, .flush_i,
    .resp_valid_o, .resp_data_o, .resp_fault_o,
    .refill_valid_o(refill_valid), .refill_ready_i(refill_ready), .refill_addr_o(refill_addr),
    .refill_mshr_o(refill_mshr), .beat_valid_i(beat_valid), .beat_mshr_i(beat_mshr),
    .beat_last_i(beat_last), .beat_err_i(beat_err), .beat_data_i(beat_data),
    .ev_hit_o, .ev_miss_o
  );

  rv_axi_rd_master #(.C_W(C_W), .LINE_BYTES(LINE_BYTES), .BEAT_BYTES(BEAT_BYTES), .IDX_W(MIDX_W)) u_axi (
    .clk, .rst_n, .req_valid_i(refill_valid), .req_ready_o(refill_ready), .req_addr_i(refill_addr),
    .req_mshr_i(refill_mshr), .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_o(ar_s),
    .r_valid_i(r_valid), .r_ready_o(r_ready), .r_i(r_s), .beat_valid_o(beat_valid), .beat_mshr_o(beat_mshr),
    .beat_last_o(beat_last), .beat_err_o(beat_err), .beat_data_o(beat_data)
  );
endmodule
