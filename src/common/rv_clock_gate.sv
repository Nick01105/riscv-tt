// rv_clock_gate - glitch-free clock gate: gclk_o = clk_i & (en_i latched
// while clk_i is low). Define SKY130_CELLS to use the real ICG cell
// (sky130_fd_sc_hd__dlclkp_1, 17.5 um2); otherwise a behavioural model with
// the same function is used (simulation, FPGA, area estimates).
module rv_clock_gate (
  input  logic clk_i,
  input  logic en_i,
  output logic gclk_o
);
`ifdef SKY130_CELLS
  sky130_fd_sc_hd__dlclkp_1 u_icg (.CLK(clk_i), .GATE(en_i), .GCLK(gclk_o));
`else
  logic en_l;
  always_latch begin
    if (!clk_i) en_l = en_i;
  end
  assign gclk_o = clk_i & en_l;
`endif
endmodule
