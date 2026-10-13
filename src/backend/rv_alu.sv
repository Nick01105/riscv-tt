// rv_alu - integer ALU (op = frontend_pkg::alu_op_e). word_i selects the
// RV64 *W form: operate on the low 32 bits and sign-extend the result.
// One adder serves add, sub and the set-less-than compares.
module rv_alu #(
  parameter int XLEN = 32
) (
  input  logic [4:0]      op_i,
  input  logic            word_i,
  input  logic [XLEN-1:0] a_i,
  input  logic [XLEN-1:0] b_i,
  output logic [XLEN-1:0] y_o
);
  localparam int SH_W = $clog2(XLEN);

  logic            sub;
  logic [XLEN:0]   sum;          // a + ~b + 1 for sub/compares, with carry out
  logic            lt, ltu;
  logic [SH_W-1:0] shamt;
  logic [XLEN-1:0] sh_in, srl_v, sra_v, sll_v, y;

  assign sub = (op_i == frontend_pkg::ALU_SUB) || (op_i == frontend_pkg::ALU_SLT) || (op_i == frontend_pkg::ALU_SLTU);
  assign sum = {1'b0, a_i} + {1'b0, sub ? ~b_i : b_i} + {{XLEN{1'b0}}, sub};

  // a < b unsigned  <=>  no carry out of a + ~b + 1
  assign ltu = !sum[XLEN];
  assign lt  = (a_i[XLEN-1] != b_i[XLEN-1]) ? a_i[XLEN-1] : sum[XLEN-1];

  // shifts: for *W forms the source is the low word, zero- or sign-extended
  generate
    if (XLEN == 64) begin : g_w
      assign shamt = word_i ? {1'b0, b_i[4:0]} : b_i[SH_W-1:0];
      always_comb begin
        sh_in = a_i;
        if (word_i) sh_in = (op_i == frontend_pkg::ALU_SRA) ? {{32{a_i[31]}}, a_i[31:0]} : {32'b0, a_i[31:0]};
      end
    end else begin : g_n
      assign shamt = b_i[SH_W-1:0];
      assign sh_in = a_i;
    end
  endgenerate

  assign sll_v = a_i << shamt;
  assign srl_v = sh_in >> shamt;
  assign sra_v = $unsigned($signed(sh_in) >>> shamt);

  always_comb begin
    case (op_i)
      frontend_pkg::ALU_ADD,
      frontend_pkg::ALU_SUB:   y = sum[XLEN-1:0];
      frontend_pkg::ALU_SLL:   y = sll_v;
      frontend_pkg::ALU_SLT:   y = {{(XLEN-1){1'b0}}, lt};
      frontend_pkg::ALU_SLTU:  y = {{(XLEN-1){1'b0}}, ltu};
      frontend_pkg::ALU_XOR:   y = a_i ^ b_i;
      frontend_pkg::ALU_SRL:   y = srl_v;
      frontend_pkg::ALU_SRA:   y = sra_v;
      frontend_pkg::ALU_OR:    y = a_i | b_i;
      frontend_pkg::ALU_AND:   y = a_i & b_i;
      default:                 y = b_i;                 // ALU_PASSB (lui)
    endcase
  end

  generate
    if (XLEN == 64) begin : g_wy
      assign y_o = word_i ? {{32{y[31]}}, y[31:0]} : y;
    end else begin : g_ny
      assign y_o = y;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused;
      assign unused = word_i;
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endgenerate
endmodule
