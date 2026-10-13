// Our RVC expander and Ibex's compressed decoder (Zca only, plain RV32I)
// side by side on the same input.
module tb_xcheck (
  input  logic        clk,
  input  logic [31:0] instr,
  output logic [31:0] ours,
  output logic        our_ill,
  output logic        our_rvc,
  output logic [31:0] theirs,
  output logic        their_ill,
  output logic        their_rvc
);
  rv_rvc_expand #(.XLEN(32)) u_ours (
    .instr_i(instr), .instr_o(ours), .is_rvc_o(our_rvc), .illegal_o(our_ill)
  );

  /* verilator lint_off PINCONNECTEMPTY */
  ibex_compressed_decoder #(
    .RV32ZC (ibex_pkg::RV32Zca),
    .BaseIsa(ibex_pkg::BaseIsaRV32I)
  ) u_ibex (
    .clk_i(clk), .rst_ni(1'b1), .valid_i(1'b1), .id_in_ready_i(1'b1),
    .instr_i(instr), .cheriot_enable_i(ibex_pkg::IbexMuBiOff),
    .instr_o(theirs), .is_compressed_o(their_rvc), .gets_expanded_o(),
    .flush_expanded_i(1'b0), .illegal_instr_o(their_ill)
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
