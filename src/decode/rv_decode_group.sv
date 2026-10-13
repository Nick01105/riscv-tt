// rv_decode_group - DECODE_W decoders side by side, plus intra-group
// dependency information: for each slot and each source register, whether
// an older slot in the same group writes it, and which one (the youngest
// such producer). The backend uses this to stall or forward inside a group.
// With DECODE_W = 1 (TT build) the dependency outputs are always 0.
module rv_decode_group #(
  parameter int W  = 1,
  parameter int IW = (W > 1) ? $clog2(W) : 1     // derived, do not override
) (
  input  logic [W*frontend_pkg::SLOT_W-1:0] slots_i,
  input  logic [W-1:0]                      valid_i,
  output logic [W*frontend_pkg::UOP_W-1:0]  uops_o,
  output logic [W-1:0]                      dep1_v_o,   // rs1 produced by an older slot
  output logic [W*IW-1:0]                   dep1_i_o,
  output logic [W-1:0]                      dep2_v_o,   // rs2 produced by an older slot
  output logic [W*IW-1:0]                   dep2_i_o
);
  localparam int SW = frontend_pkg::SLOT_W;
  localparam int UW = frontend_pkg::UOP_W;

  // Register fields of the flat uop, by position in uop_t (MSB first:
  // valid, pc, is_rvc, fu, op, f3, rd, rd_we, rs1, rs1_en, rs2, rs2_en, ...).
  // tb_decode_group checks these against the struct.
  localparam int RD_HI = UW - frontend_pkg::PADDR_W - 14;
  logic [W*5-1:0] rd, rs1, rs2;
  logic [W-1:0]   we, e1, e2;

  for (genvar k = 0; k < W; k++) begin : g_dec
    frontend_pkg::fetch_slot_t s;
    frontend_pkg::uop_t        o;
    logic [SW-1:0]             s_raw;
    logic [UW-1:0]             o_raw;
    assign s_raw = slots_i[k*SW +: SW];
    // valid comes from valid_i, the rest of the slot is passed through
    assign s = {valid_i[k], s_raw[SW-2:0]};
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_v;
    assign unused_v = s_raw[SW-1];
    /* verilator lint_on UNUSEDSIGNAL */
    rv_decoder u_dec (.slot_i(s), .uop_o(o));
    assign o_raw = o;
    assign uops_o[k*UW +: UW] = o_raw;
    assign rd[k*5 +: 5]  = o_raw[RD_HI -: 5];
    assign we[k]         = o_raw[RD_HI - 5];
    assign rs1[k*5 +: 5] = o_raw[RD_HI - 6 -: 5];
    assign e1[k]         = o_raw[RD_HI - 11];
    assign rs2[k*5 +: 5] = o_raw[RD_HI - 12 -: 5];
    assign e2[k]         = o_raw[RD_HI - 17];
  end

  always_comb begin
    dep1_v_o = '0;
    dep2_v_o = '0;
    dep1_i_o = '0;
    dep2_i_o = '0;
    for (int j = 0; j < W; j++) begin
      for (int i = 0; i < j; i++) begin
        if (valid_i[i] && we[i] && e1[j] && rd[i*5 +: 5] == rs1[j*5 +: 5]) begin
          dep1_v_o[j] = 1'b1;
          dep1_i_o[j*IW +: IW] = IW'(i);
        end
        if (valid_i[i] && we[i] && e2[j] && rd[i*5 +: 5] == rs2[j*5 +: 5]) begin
          dep2_v_o[j] = 1'b1;
          dep2_i_o[j*IW +: IW] = IW'(i);
        end
      end
    end
  end
endmodule
