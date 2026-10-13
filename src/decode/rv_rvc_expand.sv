// rv_rvc_expand - expand a 16-bit compressed instruction (Zca) to 32 bits.
// Supports RV32 (XLEN=32) and RV64 (XLEN=64). There is no F or D, so the
// compressed float/double loads and stores are illegal. Zcb/Zcmp are not
// supported (their encodings are reserved here, so illegal).
//
// * 32-bit input (instr_i[1:0] == 2'b11): passed through, is_rvc_o = 0.
// * Legal compressed: instr_o is the base-ISA equivalent, is_rvc_o = 1.
//   HINTs (e.g. c.addi x0, n) are legal and expand to their base form.
// * Illegal or reserved: illegal_o = 1 and instr_o = {16'b0, instr_i[15:0]},
//   so the original parcel survives for mtval.
module rv_rvc_expand #(
  parameter int XLEN = 32
) (
  input  logic [31:0] instr_i,
  output logic [31:0] instr_o,
  output logic        is_rvc_o,
  output logic        illegal_o
);
  localparam bit RV64 = (XLEN == 64);

  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_IMM_32 = 7'b0011011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_OP_32  = 7'b0111011;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;

  localparam logic [4:0] X0 = 5'd0;
  localparam logic [4:0] RA = 5'd1;
  localparam logic [4:0] SP = 5'd2;

  // ---- base-format encoders (no 'return': Yosys 0.33) ----------------------
  function automatic logic [31:0] enc_i(input logic [11:0] imm, input logic [4:0] rs1,
                                        input logic [2:0] f3, input logic [4:0] rd,
                                        input logic [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] enc_s(input logic [11:0] imm, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3,
                                        input logic [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction

  // Branch and jump offsets are even, so imm[0] is never encoded.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] enc_b(input logic [12:0] imm, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], OP_BRANCH};
  endfunction

  function automatic logic [31:0] enc_j(input logic [20:0] imm, input logic [4:0] rd);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, OP_JAL};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [31:0] enc_r(input logic [6:0] f7, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3,
                                        input logic [4:0] rd, input logic [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op};
  endfunction

  // ---- fields --------------------------------------------------------------
  logic [15:0] c;
  logic [4:0]  rd, rs2, rdp, rs1p, rs2p;
  logic [5:0]  imm6, shamt6;
  logic [11:0] imm6_sx;
  logic [9:0]  addi4spn_imm;
  logic [6:0]  lw_off;
  logic [7:0]  ld_off, lwsp_off, swsp_off;
  logic [8:0]  ldsp_off, sdsp_off;
  logic [9:0]  addi16sp_imm;
  logic [11:0] j_off;
  logic [8:0]  b_off;

  assign c            = instr_i[15:0];
  assign rd           = c[11:7];               // also rs1 in CR/CI formats
  assign rs2          = c[6:2];
  assign rdp          = {2'b01, c[4:2]};       // x8..x15
  assign rs1p         = {2'b01, c[9:7]};
  assign rs2p         = {2'b01, c[4:2]};
  assign imm6         = {c[12], c[6:2]};
  assign shamt6       = {c[12], c[6:2]};
  assign imm6_sx      = {{6{c[12]}}, imm6};
  assign addi4spn_imm = {c[10:7], c[12:11], c[5], c[6], 2'b00};
  assign lw_off       = {c[5], c[12:10], c[6], 2'b00};
  assign ld_off       = {c[6:5], c[12:10], 3'b000};
  assign lwsp_off     = {c[3:2], c[12], c[6:4], 2'b00};
  assign ldsp_off     = {c[4:2], c[12], c[6:5], 3'b000};
  assign swsp_off     = {c[8:7], c[12:9], 2'b00};
  assign sdsp_off     = {c[9:7], c[12:10], 3'b000};
  assign addi16sp_imm = {c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
  assign j_off        = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
  assign b_off        = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};

  logic [31:0] x;
  logic        ill;

  always_comb begin
    x   = 32'b0;
    ill = 1'b0;
    case (c[1:0])
      // ---------------------------------------------------------- quadrant 0
      2'b00: begin
        case (c[15:13])
          3'b000: begin  // c.addi4spn -> addi rd', x2, nzuimm
            x   = enc_i({2'b00, addi4spn_imm}, SP, 3'b000, rdp, OP_IMM);
            ill = (addi4spn_imm == '0);              // includes the all-zero parcel
          end
          3'b010: x = enc_i({5'b0, lw_off}, rs1p, 3'b010, rdp, OP_LOAD);          // c.lw
          3'b011: begin                                                           // c.ld (RV64)
            x   = enc_i({4'b0, ld_off}, rs1p, 3'b011, rdp, OP_LOAD);
            ill = !RV64;                                                          // c.flw on RV32
          end
          3'b110: x = enc_s({5'b0, lw_off}, rs2p, rs1p, 3'b010, OP_STORE);        // c.sw
          3'b111: begin                                                           // c.sd (RV64)
            x   = enc_s({4'b0, ld_off}, rs2p, rs1p, 3'b011, OP_STORE);
            ill = !RV64;                                                          // c.fsw on RV32
          end
          default: ill = 1'b1;   // c.fld, c.fsd, reserved
        endcase
      end

      // ---------------------------------------------------------- quadrant 1
      2'b01: begin
        case (c[15:13])
          3'b000: x = enc_i(imm6_sx, rd, 3'b000, rd, OP_IMM);                     // c.addi / c.nop
          3'b001: begin
            if (RV64) begin                                                       // c.addiw
              x   = enc_i(imm6_sx, rd, 3'b000, rd, OP_IMM_32);
              ill = (rd == X0);
            end else begin                                                        // c.jal
              x   = enc_j({{9{j_off[11]}}, j_off}, RA);
            end
          end
          3'b010: x = enc_i(imm6_sx, X0, 3'b000, rd, OP_IMM);                     // c.li
          3'b011: begin
            if (rd == SP) begin                                                   // c.addi16sp
              x   = enc_i({{2{addi16sp_imm[9]}}, addi16sp_imm}, SP, 3'b000, SP, OP_IMM);
              ill = (addi16sp_imm == '0);
            end else begin                                                        // c.lui
              x   = {{14{c[12]}}, imm6, rd, OP_LUI};
              ill = (imm6 == '0);
            end
          end
          3'b100: begin
            case (c[11:10])
              2'b00: begin                                                        // c.srli
                x   = enc_i({6'b000000, shamt6}, rs1p, 3'b101, rs1p, OP_IMM);
                ill = !RV64 && c[12];
              end
              2'b01: begin                                                        // c.srai
                x   = enc_i({6'b010000, shamt6}, rs1p, 3'b101, rs1p, OP_IMM);
                ill = !RV64 && c[12];
              end
              2'b10: x = enc_i(imm6_sx, rs1p, 3'b111, rs1p, OP_IMM);              // c.andi
              default: begin
                if (!c[12]) begin
                  case (c[6:5])
                    2'b00:   x = enc_r(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_OP);  // c.sub
                    2'b01:   x = enc_r(7'b0000000, rs2p, rs1p, 3'b100, rs1p, OP_OP);  // c.xor
                    2'b10:   x = enc_r(7'b0000000, rs2p, rs1p, 3'b110, rs1p, OP_OP);  // c.or
                    default: x = enc_r(7'b0000000, rs2p, rs1p, 3'b111, rs1p, OP_OP);  // c.and
                  endcase
                end else begin
                  case (c[6:5])
                    2'b00: begin                                                  // c.subw
                      x   = enc_r(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_OP_32);
                      ill = !RV64;
                    end
                    2'b01: begin                                                  // c.addw
                      x   = enc_r(7'b0000000, rs2p, rs1p, 3'b000, rs1p, OP_OP_32);
                      ill = !RV64;
                    end
                    default: ill = 1'b1;                                          // reserved
                  endcase
                end
              end
            endcase
          end
          3'b101: x = enc_j({{9{j_off[11]}}, j_off}, X0);                         // c.j
          3'b110: x = enc_b({{4{b_off[8]}}, b_off}, X0, rs1p, 3'b000);            // c.beqz
          default: x = enc_b({{4{b_off[8]}}, b_off}, X0, rs1p, 3'b001);           // c.bnez
        endcase
      end

      // ---------------------------------------------------------- quadrant 2
      2'b10: begin
        case (c[15:13])
          3'b000: begin                                                           // c.slli
            x   = enc_i({6'b000000, shamt6}, rd, 3'b001, rd, OP_IMM);
            ill = !RV64 && c[12];
          end
          3'b010: begin                                                           // c.lwsp
            x   = enc_i({4'b0, lwsp_off}, SP, 3'b010, rd, OP_LOAD);
            ill = (rd == X0);
          end
          3'b011: begin                                                           // c.ldsp (RV64)
            x   = enc_i({3'b0, ldsp_off}, SP, 3'b011, rd, OP_LOAD);
            ill = !RV64 || (rd == X0);                                            // c.flwsp on RV32
          end
          3'b100: begin
            if (!c[12]) begin
              if (rs2 == X0) begin                                                // c.jr
                x   = enc_i(12'b0, rd, 3'b000, X0, OP_JALR);
                ill = (rd == X0);
              end else begin                                                      // c.mv
                x   = enc_r(7'b0, rs2, X0, 3'b000, rd, OP_OP);
              end
            end else begin
              if (rd == X0 && rs2 == X0) begin                                    // c.ebreak
                x   = 32'h0010_0073;
              end else if (rs2 == X0) begin                                       // c.jalr
                x   = enc_i(12'b0, rd, 3'b000, RA, OP_JALR);
              end else begin                                                      // c.add
                x   = enc_r(7'b0, rs2, rd, 3'b000, rd, OP_OP);
              end
            end
          end
          3'b110: x = enc_s({4'b0, swsp_off}, rs2, SP, 3'b010, OP_STORE);         // c.swsp
          3'b111: begin                                                           // c.sdsp (RV64)
            x   = enc_s({3'b0, sdsp_off}, rs2, SP, 3'b011, OP_STORE);
            ill = !RV64;                                                          // c.fswsp on RV32
          end
          default: ill = 1'b1;                                                    // c.fldsp, c.fsdsp
        endcase
      end

      default: begin
        x   = instr_i;   // 32-bit instruction
        ill = 1'b0;
      end
    endcase
  end

  assign is_rvc_o  = (instr_i[1:0] != 2'b11);
  assign illegal_o = is_rvc_o && ill;
  assign instr_o   = (is_rvc_o && ill) ? {16'b0, c} : x;
endmodule
