// rv_imm_gen - immediate extraction for 32-bit RISC-V instructions.
// The format comes from the major opcode. Unknown opcodes give IMM_NONE / 0.
// CSR immediates (zimm in the rs1 field) are taken by the decoder directly.
module rv_imm_gen #(
  parameter int XLEN = 32
) (
  input  logic [31:0]     instr_i,
  output logic [XLEN-1:0] imm_o,
  output logic [2:0]      fmt_o
);
  localparam logic [2:0] IMM_NONE = 3'd0;
  localparam logic [2:0] IMM_I    = 3'd1;
  localparam logic [2:0] IMM_S    = 3'd2;
  localparam logic [2:0] IMM_B    = 3'd3;
  localparam logic [2:0] IMM_U    = 3'd4;
  localparam logic [2:0] IMM_J    = 3'd5;

  localparam logic [6:0] OP_LOAD     = 7'b0000011;
  localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OP_IMM      = 7'b0010011;
  localparam logic [6:0] OP_AUIPC    = 7'b0010111;
  localparam logic [6:0] OP_IMM_32   = 7'b0011011;
  localparam logic [6:0] OP_STORE    = 7'b0100011;
  localparam logic [6:0] OP_LUI      = 7'b0110111;
  localparam logic [6:0] OP_BRANCH   = 7'b1100011;
  localparam logic [6:0] OP_JALR     = 7'b1100111;
  localparam logic [6:0] OP_JAL      = 7'b1101111;
  localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

  logic [31:0] i_imm, s_imm, b_imm, u_imm, j_imm, imm32;
  logic        s;

  assign s     = instr_i[31];
  assign i_imm = {{20{s}}, instr_i[31:20]};
  assign s_imm = {{20{s}}, instr_i[31:25], instr_i[11:7]};
  assign b_imm = {{19{s}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
  assign u_imm = {instr_i[31:12], 12'b0};
  assign j_imm = {{11{s}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};

  always_comb begin
    fmt_o = IMM_NONE;
    imm32 = 32'b0;
    case (instr_i[6:0])
      OP_LOAD, OP_MISC_MEM, OP_IMM, OP_IMM_32, OP_JALR, OP_SYSTEM: begin
        fmt_o = IMM_I; imm32 = i_imm;
      end
      OP_STORE:          begin fmt_o = IMM_S; imm32 = s_imm; end
      OP_BRANCH:         begin fmt_o = IMM_B; imm32 = b_imm; end
      OP_LUI, OP_AUIPC:  begin fmt_o = IMM_U; imm32 = u_imm; end
      OP_JAL:            begin fmt_o = IMM_J; imm32 = j_imm; end
      default:           begin fmt_o = IMM_NONE; imm32 = 32'b0; end
    endcase
  end

  // Sign-extend to XLEN (all RISC-V immediates are sign-extended).
  generate
    if (XLEN > 32) begin : g_wide
      assign imm_o = {{(XLEN-32){imm32[31]}}, imm32};
    end else begin : g_32
      assign imm_o = imm32;
    end
  endgenerate
endmodule
