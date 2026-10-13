// rv_core - rv_frontend + rv_backend: the complete hart.
//
// Memory: the AXI4 read master fetches instructions (cacheable regions);
// the data bus (valid/ready request, response a later cycle) serves loads,
// stores and atomics, uncached. rv_soc connects both to the QSPI memories
// and the peripherals.
module rv_core #(
  parameter logic [frontend_pkg::PADDR_W-1:0] RESET_PC = '0
) (
  input  logic                            clk,
  input  logic                            rst_n,
  // instruction fetch (AXI4 read)
  output logic                            ar_valid_o,
  input  logic                            ar_ready_i,
  output frontend_pkg::axi_ar_t           ar_o,
  input  logic                            r_valid_i,
  output logic                            r_ready_o,
  input  frontend_pkg::axi_r_t            r_i,
  // data bus
  output logic                            dreq_valid_o,
  input  logic                            dreq_ready_i,
  output frontend_pkg::paddr_t            dreq_addr_o,
  output logic                            dreq_we_o,
  output logic [1:0]                      dreq_size_o,
  output logic [frontend_pkg::XLEN/8-1:0] dreq_be_o,
  output logic [frontend_pkg::XLEN-1:0]   dreq_wdata_o,
  input  logic                            drsp_valid_i,
  input  logic [frontend_pkg::XLEN-1:0]   drsp_rdata_i,
  input  logic                            drsp_err_i,
  // interrupts and time (from the CLINT)
  input  logic                            mtip_i,
  input  logic                            msip_i,
  input  logic [63:0]                     mtime_i,
  // commit trace
  output logic                            trc_valid_o,
  output frontend_pkg::paddr_t            trc_pc_o,
  output logic [31:0]                     trc_insn_o,
  output logic                            trc_trap_o,
  output logic [frontend_pkg::XLEN-1:0]   trc_cause_o,
  output logic [4:0]                      trc_rd_o,
  output logic [frontend_pkg::XLEN-1:0]   trc_rd_val_o,
  output logic                            trc_mispredict_o,
  // frontend events (performance counters, debug)
  output logic                            ev_ic_hit_o,
  output logic                            ev_ic_miss_o,
  output logic                            ev_pred_o,
  output logic                            ev_pred_taken_o,
  output logic                            overflow_o
);
  localparam int DW = frontend_pkg::DECODE_W;
  localparam int IW = (DW > 1) ? $clog2(DW) : 1;

  logic [DW-1:0]                     uop_valid, uop_ready;
  logic [DW*frontend_pkg::UOP_W-1:0] uops;
  frontend_pkg::redirect_t           redirect;
  frontend_pkg::br_resolve_t         resolve;
  frontend_pkg::ftq_retire_t         retire;
  frontend_pkg::ftq_idx_t            tgt_idx;
  frontend_pkg::paddr_t              tgt;

  /* verilator lint_off UNUSEDSIGNAL */
  logic [DW-1:0]    dep1_v, dep2_v;      // intra-group dependencies: unused by the scalar backend
  logic [DW*IW-1:0] dep1_i, dep2_i;
  /* verilator lint_on UNUSEDSIGNAL */

  rv_frontend #(.RESET_PC(RESET_PC)) u_fe (
    .clk, .rst_n,
    .uop_valid_o(uop_valid), .uop_o(uops), .uop_ready_i(uop_ready),
    .dep1_v_o(dep1_v), .dep1_i_o(dep1_i), .dep2_v_o(dep2_v), .dep2_i_o(dep2_i),
    .redirect_i(redirect), .resolve_i(resolve), .retire_i(retire), .tgt_idx_i(tgt_idx), .tgt_o(tgt),
    .ar_valid_o, .ar_ready_i, .ar_o, .r_valid_i, .r_ready_o, .r_i,
    .ev_ic_hit_o, .ev_ic_miss_o, .ev_pred_o, .ev_pred_taken_o, .overflow_o
  );

  rv_backend u_be (
    .clk, .rst_n,
    .uop_valid_i(uop_valid), .uop_i(uops), .uop_ready_o(uop_ready),
    .redirect_o(redirect), .resolve_o(resolve), .retire_o(retire), .tgt_idx_o(tgt_idx), .tgt_i(tgt),
    .dreq_valid_o, .dreq_ready_i, .dreq_addr_o, .dreq_we_o, .dreq_size_o, .dreq_be_o, .dreq_wdata_o,
    .drsp_valid_i, .drsp_rdata_i, .drsp_err_i,
    .mtip_i, .msip_i, .mtime_i, .ev_ic_miss_i(ev_ic_miss_o),
    .trc_valid_o, .trc_pc_o, .trc_insn_o, .trc_trap_o, .trc_cause_o, .trc_rd_o, .trc_rd_val_o, .trc_mispredict_o
  );
endmodule
