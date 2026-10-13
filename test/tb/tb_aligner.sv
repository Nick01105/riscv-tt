// Test wrapper for rv_aligner: unpacks the flat slot bundle into per-field
// vectors and checks that SLOT_W matches the real struct width.
module tb_aligner (
  input  logic clk,
  input  logic rst_n,
  input  logic flush_i,
  input  logic in_valid_i,
  output logic in_ready_o,
  input  logic [frontend_pkg::PADDR_W-1:0] in_pc_i,
  input  logic [frontend_pkg::FETCH_BYTES*8-1:0] in_data_i,
  input  logic [frontend_pkg::NPARCEL-1:0] in_taken_i,
  input  logic [1:0] in_fault_i,
  input  logic [frontend_pkg::FTQ_IDX_W-1:0] in_ftq_i,
  input  logic out_ready_i,
  output logic [frontend_pkg::NPARCEL-1:0] o_valid,
  output logic [frontend_pkg::NPARCEL*frontend_pkg::PADDR_W-1:0] o_pc,
  output logic [frontend_pkg::NPARCEL*32-1:0] o_raw,
  output logic [frontend_pkg::NPARCEL-1:0] o_rvc,
  output logic [frontend_pkg::NPARCEL-1:0] o_taken,
  output logic [frontend_pkg::NPARCEL*2-1:0] o_fault,
  output logic [frontend_pkg::NPARCEL*frontend_pkg::FTQ_IDX_W-1:0] o_ftq
);
  localparam int NP = frontend_pkg::NPARCEL;
  localparam int SW = frontend_pkg::SLOT_W;
  logic [NP*SW-1:0] slots;

  rv_aligner dut (
    .clk, .rst_n, .flush_i, .in_valid_i, .in_ready_o, .in_pc_i, .in_data_i, .in_taken_i,
    .in_fault_i(frontend_pkg::fault_e'(in_fault_i)), .in_ftq_i, .out_valid_o(o_valid),
    .out_slots_o(slots), .out_ready_i
  );

  initial begin
    if ($bits(frontend_pkg::fetch_slot_t) != SW) $fatal(1, "SLOT_W %0d != $bits(fetch_slot_t) %0d", SW, $bits(frontend_pkg::fetch_slot_t));
  end

  for (genvar p = 0; p < NP; p++) begin : g_unpack
    frontend_pkg::fetch_slot_t s;
    assign s = slots[p*SW +: SW];
    assign o_pc[p*frontend_pkg::PADDR_W +: frontend_pkg::PADDR_W] = s.pc;
    assign o_raw[p*32 +: 32] = s.raw32;
    assign o_rvc[p]   = s.is_rvc;
    assign o_taken[p] = s.pred_taken;
    assign o_fault[p*2 +: 2] = s.fault;
    assign o_ftq[p*frontend_pkg::FTQ_IDX_W +: frontend_pkg::FTQ_IDX_W] = s.ftq_idx;
  end
endmodule
