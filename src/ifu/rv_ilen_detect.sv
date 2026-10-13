// rv_ilen_detect - find instruction boundaries in a fetch block of 16-bit
// parcels (RV C extension: 16- and 32-bit instructions only).
//
// Parcels below start_i are skipped (fetch entered the block mid-way after a
// jump). carry_i says parcel 0 is the upper half of a 32-bit instruction that
// began in the previous block; it is ignored unless start_i == 0.
// carry_o says the last instruction spills into the next block.
module rv_ilen_detect #(
  parameter int NP = 8,                      // parcels per block
  parameter int SW = (NP > 1) ? $clog2(NP) : 1  // derived, do not override
) (
  input  logic [NP*16-1:0] parcels_i,        // parcel p at [p*16 +: 16]
  input  logic [SW-1:0]    start_i,
  input  logic             carry_i,
  output logic [NP-1:0]    start_mask_o,     // parcel p begins an instruction
  output logic [NP-1:0]    rvc_mask_o,       // ... and that instruction is 16-bit
  output logic             carry_o
);
  always_comb begin : scan
    logic cont;
    cont         = carry_i && (start_i == '0);
    start_mask_o = '0;
    rvc_mask_o   = '0;
    for (int p = 0; p < NP; p++) begin
      if (p >= 32'(start_i)) begin
        if (cont) begin
          cont = 1'b0;                      // upper half of a 32-bit instruction
        end else begin
          start_mask_o[p] = 1'b1;
          if (parcels_i[p*16 +: 2] != 2'b11) rvc_mask_o[p] = 1'b1;
          else                               cont = 1'b1;
        end
      end
    end
    carry_o = cont;
  end

  // Only the low two bits of each parcel are inspected.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_parcels;
  assign unused_parcels = ^parcels_i;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
