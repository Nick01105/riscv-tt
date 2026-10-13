// Test wrapper: unpacks uop_t into plain ports so cocotb can read each field.
module tb_decoder (
  input  logic [31:0]                 raw32,
  output logic                        valid,
  output logic                        illegal,
  output logic [2:0]                  fu,
  output logic [4:0]                  op,
  output logic [2:0]                  f3,
  output logic [4:0]                  rd,
  output logic                        rd_we,
  output logic [4:0]                  rs1,
  output logic                        rs1_en,
  output logic [4:0]                  rs2,
  output logic                        rs2_en,
  output logic [frontend_pkg::XLEN-1:0] imm,
  output logic                        use_imm,
  output logic                        use_pc,
  output logic                        word_op,
  output logic [2:0]                  br_type,
  output logic [2:0]                  sys
);
  frontend_pkg::fetch_slot_t s;
  frontend_pkg::uop_t        u;

  always_comb begin
    s            = '0;
    s.valid      = 1'b1;
    s.raw32      = raw32;
  end

  rv_decoder dut (.slot_i(s), .uop_o(u));

  assign valid   = u.valid;
  assign illegal = u.illegal;
  assign fu      = u.fu;
  assign op      = u.op;
  assign f3      = u.f3;
  assign rd      = u.rd;
  assign rd_we   = u.rd_we;
  assign rs1     = u.rs1;
  assign rs1_en  = u.rs1_en;
  assign rs2     = u.rs2;
  assign rs2_en  = u.rs2_en;
  assign imm     = u.imm;
  assign use_imm = u.use_imm;
  assign use_pc  = u.use_pc;
  assign word_op = u.word_op;
  assign br_type = u.br_type;
  assign sys     = u.sys;
endmodule
