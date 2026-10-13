// rv_decoder - one 32-bit instruction (compressed ones already expanded by
// rv_rvc_expand) to a uop_t. Covers RV32/RV64 IMAC (or RV32E when
// frontend_pkg::RVE is set) + Zicsr + Zifencei with M-mode system
// instructions; XLEN comes from frontend_pkg.
//
// Conventions:
// * rd_we is set only when rd != x0, so hazard logic can ignore x0.
// * Illegal instructions clear rd_we, rs*_en and fu, so they reach the
//   backend as an exception with no side effects.
// * Shifts carry the shift amount (not the raw I-immediate) in imm.
// * CSR instructions carry the zero-extended CSR address in imm.
// * br_type follows the RAS hints in the unprivileged spec (x1/x5 are links).
//   jalr with rd and rs1 both links and different is "pop then push"; it is
//   reported as BR_CALL (push only), which costs one RAS entry, never a
//   wrong-path fetch.
module rv_decoder (
  input  frontend_pkg::fetch_slot_t slot_i,
  output frontend_pkg::uop_t        uop_o
);
  localparam bit RV64 = (frontend_pkg::XLEN == 64);
  localparam bit RVE  = (frontend_pkg::RVE != 0);
  localparam int XLEN = frontend_pkg::XLEN;

  localparam logic [6:0] OP_LOAD     = 7'b0000011;
  localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OP_IMM      = 7'b0010011;
  localparam logic [6:0] OP_AUIPC    = 7'b0010111;
  localparam logic [6:0] OP_IMM_32   = 7'b0011011;
  localparam logic [6:0] OP_STORE    = 7'b0100011;
  localparam logic [6:0] OP_AMO      = 7'b0101111;
  localparam logic [6:0] OP_OP       = 7'b0110011;
  localparam logic [6:0] OP_LUI      = 7'b0110111;
  localparam logic [6:0] OP_OP_32    = 7'b0111011;
  localparam logic [6:0] OP_BRANCH   = 7'b1100011;
  localparam logic [6:0] OP_JALR     = 7'b1100111;
  localparam logic [6:0] OP_JAL      = 7'b1101111;
  localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

  logic [31:0] ins;
  logic [6:0]  opc, f7;
  logic [2:0]  f3;
  logic [4:0]  rd, rs1, rs2, f5;
  logic [XLEN-1:0] imm_raw;
  logic [2:0]  imm_fmt;
  logic        rd_link, rs1_link;

  assign ins      = slot_i.raw32;
  assign opc      = ins[6:0];
  assign rd       = ins[11:7];
  assign f3       = ins[14:12];
  assign rs1      = ins[19:15];
  assign rs2      = ins[24:20];
  assign f7       = ins[31:25];
  assign f5       = ins[31:27];
  assign rd_link  = (rd == 5'd1) || (rd == 5'd5);
  assign rs1_link = (rs1 == 5'd1) || (rs1 == 5'd5);

  rv_imm_gen #(.XLEN(XLEN)) i_imm_gen (.instr_i(ins), .imm_o(imm_raw), .fmt_o(imm_fmt));

  // Shift-immediate legality: RV32 needs ins[31:25] in {0, 0x20}; RV64 lets
  // bit 25 be shamt[5], so it checks ins[31:26] instead.
  logic sh_ok_l, sh_ok_r;     // slli / srli+srai
  assign sh_ok_l = RV64 ? (ins[31:26] == 6'b000000) : (f7 == 7'b0000000);
  assign sh_ok_r = RV64 ? (ins[31:26] == 6'b000000 || ins[31:26] == 6'b010000)
                        : (f7 == 7'b0000000 || f7 == 7'b0100000);

  logic [XLEN-1:0] shamt;
  assign shamt = RV64 ? XLEN'(ins[25:20]) : XLEN'(ins[24:20]);

  frontend_pkg::uop_t u;
  logic writes, legal;

  always_comb begin
    u            = '0;
    u.valid      = slot_i.valid;
    u.pc         = slot_i.pc;
    u.is_rvc     = slot_i.is_rvc;
    u.pred_taken = slot_i.pred_taken;
    u.fault      = slot_i.fault;
    u.raw32      = ins;
    u.ftq_idx    = slot_i.ftq_idx;
    u.f3         = f3;
    u.rd         = rd;
    u.rs1        = rs1;
    u.rs2        = rs2;
    u.imm        = imm_raw;
    u.fu         = frontend_pkg::FU_NONE;
    u.br_type    = frontend_pkg::BR_NONE;
    u.sys        = frontend_pkg::SYS_NONE;
    writes       = 1'b0;
    legal        = 1'b0;

    if (ins[1:0] == 2'b11) begin
      case (opc)
        OP_LUI: begin
          legal = 1'b1; writes = 1'b1;
          u.fu = frontend_pkg::FU_ALU; u.op = frontend_pkg::ALU_PASSB; u.use_imm = 1'b1;
        end

        OP_AUIPC: begin
          legal = 1'b1; writes = 1'b1;
          u.fu = frontend_pkg::FU_ALU; u.op = frontend_pkg::ALU_ADD;
          u.use_pc = 1'b1; u.use_imm = 1'b1;
        end

        OP_JAL: begin
          legal = 1'b1; writes = 1'b1;
          u.fu = frontend_pkg::FU_BRU; u.op = frontend_pkg::BRU_JAL; u.use_pc = 1'b1;
          u.br_type = rd_link ? frontend_pkg::BR_CALL : frontend_pkg::BR_JAL;
        end

        OP_JALR: begin
          legal = (f3 == 3'b000); writes = 1'b1;
          u.fu = frontend_pkg::FU_BRU; u.op = frontend_pkg::BRU_JALR; u.rs1_en = 1'b1;
          if (rd_link)       u.br_type = frontend_pkg::BR_CALL;
          else if (rs1_link) u.br_type = frontend_pkg::BR_RET;
          else               u.br_type = frontend_pkg::BR_JALR;
        end

        OP_BRANCH: begin
          legal = (f3 != 3'b010) && (f3 != 3'b011);
          u.fu = frontend_pkg::FU_BRU; u.op = {2'b00, f3};
          u.rs1_en = 1'b1; u.rs2_en = 1'b1; u.br_type = frontend_pkg::BR_COND;
        end

        OP_LOAD: begin
          legal = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2) || (f3 == 3'd4) || (f3 == 3'd5)
               || (RV64 && ((f3 == 3'd3) || (f3 == 3'd6)));
          writes = 1'b1;
          u.fu = frontend_pkg::FU_LSU; u.op = frontend_pkg::LSU_LOAD;
          u.rs1_en = 1'b1; u.use_imm = 1'b1;
        end

        OP_STORE: begin
          legal = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2) || (RV64 && (f3 == 3'd3));
          u.fu = frontend_pkg::FU_LSU; u.op = frontend_pkg::LSU_STORE;
          u.rs1_en = 1'b1; u.rs2_en = 1'b1; u.use_imm = 1'b1;
        end

        OP_IMM: begin
          writes = 1'b1; u.fu = frontend_pkg::FU_ALU; u.rs1_en = 1'b1; u.use_imm = 1'b1;
          legal = 1'b1;
          case (f3)
            3'd0: u.op = frontend_pkg::ALU_ADD;
            3'd1: begin u.op = frontend_pkg::ALU_SLL; legal = sh_ok_l; u.imm = shamt; end
            3'd2: u.op = frontend_pkg::ALU_SLT;
            3'd3: u.op = frontend_pkg::ALU_SLTU;
            3'd4: u.op = frontend_pkg::ALU_XOR;
            3'd5: begin
              u.op = ins[30] ? frontend_pkg::ALU_SRA : frontend_pkg::ALU_SRL;
              legal = sh_ok_r; u.imm = shamt;
            end
            3'd6: u.op = frontend_pkg::ALU_OR;
            default: u.op = frontend_pkg::ALU_AND;
          endcase
        end

        OP_IMM_32: begin
          writes = 1'b1; u.fu = frontend_pkg::FU_ALU; u.rs1_en = 1'b1; u.use_imm = 1'b1;
          u.word_op = 1'b1;
          case (f3)
            3'd0: begin u.op = frontend_pkg::ALU_ADD; legal = RV64; end
            3'd1: begin
              u.op = frontend_pkg::ALU_SLL; legal = RV64 && (f7 == 7'b0000000);
              u.imm = XLEN'(ins[24:20]);
            end
            3'd5: begin
              u.op = ins[30] ? frontend_pkg::ALU_SRA : frontend_pkg::ALU_SRL;
              legal = RV64 && ((f7 == 7'b0000000) || (f7 == 7'b0100000));
              u.imm = XLEN'(ins[24:20]);
            end
            default: legal = 1'b0;
          endcase
        end

        OP_OP, OP_OP_32: begin
          writes = 1'b1; u.rs1_en = 1'b1; u.rs2_en = 1'b1;
          u.word_op = (opc == OP_OP_32);
          if (f7 == 7'b0000001) begin                        // M extension
            u.fu = f3[2] ? frontend_pkg::FU_DIV : frontend_pkg::FU_MUL;
            u.op = {2'b00, f3};
            legal = (opc == OP_OP) || (RV64 && (f3 == 3'd0 || f3[2]));
          end else begin
            u.fu = frontend_pkg::FU_ALU;
            case ({f7, f3})
              {7'b0000000, 3'd0}: begin u.op = frontend_pkg::ALU_ADD;  legal = 1'b1; end
              {7'b0100000, 3'd0}: begin u.op = frontend_pkg::ALU_SUB;  legal = 1'b1; end
              {7'b0000000, 3'd1}: begin u.op = frontend_pkg::ALU_SLL;  legal = 1'b1; end
              {7'b0000000, 3'd2}: begin u.op = frontend_pkg::ALU_SLT;  legal = (opc == OP_OP); end
              {7'b0000000, 3'd3}: begin u.op = frontend_pkg::ALU_SLTU; legal = (opc == OP_OP); end
              {7'b0000000, 3'd4}: begin u.op = frontend_pkg::ALU_XOR;  legal = (opc == OP_OP); end
              {7'b0000000, 3'd5}: begin u.op = frontend_pkg::ALU_SRL;  legal = 1'b1; end
              {7'b0100000, 3'd5}: begin u.op = frontend_pkg::ALU_SRA;  legal = 1'b1; end
              {7'b0000000, 3'd6}: begin u.op = frontend_pkg::ALU_OR;   legal = (opc == OP_OP); end
              {7'b0000000, 3'd7}: begin u.op = frontend_pkg::ALU_AND;  legal = (opc == OP_OP); end
              default:            legal = 1'b0;
            endcase
            if (opc == OP_OP_32) legal = legal && RV64;
          end
        end

        OP_AMO: begin
          writes = 1'b1; u.fu = frontend_pkg::FU_LSU; u.rs1_en = 1'b1; u.rs2_en = 1'b1;
          u.imm = '0;
          legal = (f3 == 3'd2) || (RV64 && (f3 == 3'd3));
          case (f5)
            5'b00010: begin u.op = frontend_pkg::LSU_LR; u.rs2_en = 1'b0; legal = legal && (rs2 == 5'd0); end
            5'b00011: u.op = frontend_pkg::LSU_SC;
            5'b00001: u.op = frontend_pkg::LSU_AMOSWAP;
            5'b00000: u.op = frontend_pkg::LSU_AMOADD;
            5'b00100: u.op = frontend_pkg::LSU_AMOXOR;
            5'b01100: u.op = frontend_pkg::LSU_AMOAND;
            5'b01000: u.op = frontend_pkg::LSU_AMOOR;
            5'b10000: u.op = frontend_pkg::LSU_AMOMIN;
            5'b10100: u.op = frontend_pkg::LSU_AMOMAX;
            5'b11000: u.op = frontend_pkg::LSU_AMOMINU;
            5'b11100: u.op = frontend_pkg::LSU_AMOMAXU;
            default:  legal = 1'b0;
          endcase
        end

        OP_MISC_MEM: begin
          // Unused fields of FENCE and FENCE.I are ignored, as the spec requires.
          if (f3 == 3'd0)      begin legal = 1'b1; u.sys = frontend_pkg::SYS_FENCE;   end
          else if (f3 == 3'd1) begin legal = 1'b1; u.sys = frontend_pkg::SYS_FENCE_I; end
        end

        OP_SYSTEM: begin
          u.fu = frontend_pkg::FU_CSR;
          if (f3 == 3'd0) begin
            legal = 1'b1;
            case (ins)
              32'h0000_0073: u.sys = frontend_pkg::SYS_ECALL;
              32'h0010_0073: u.sys = frontend_pkg::SYS_EBREAK;
              32'h3020_0073: u.sys = frontend_pkg::SYS_MRET;
              32'h1050_0073: u.sys = frontend_pkg::SYS_WFI;
              default:       legal = 1'b0;
            endcase
          end else if (f3 != 3'd4) begin                     // csrrw/s/c and immediate forms
            legal = 1'b1; writes = 1'b1;
            u.op = {2'b00, f3};
            u.rs1_en = !f3[2];
            u.imm = XLEN'(ins[31:20]);
          end
        end

        default: legal = 1'b0;
      endcase
    end

    // RV32E: encodings that name x16-x31 are reserved; this core traps them.
    if (RVE && ((writes && rd[4]) || (u.rs1_en && rs1[4]) || (u.rs2_en && rs2[4]))) legal = 1'b0;

    u.rd_we   = legal && writes && (rd != 5'd0);
    u.illegal = !legal;
    if (!legal) begin
      u.fu      = frontend_pkg::FU_NONE;
      u.rs1_en  = 1'b0;
      u.rs2_en  = 1'b0;
      u.br_type = frontend_pkg::BR_NONE;
      u.sys     = frontend_pkg::SYS_NONE;
    end
  end

  assign uop_o = u;

  // The format output is only used for debugging the immediate generator.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_fmt;
  assign unused_fmt = ^imm_fmt;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
