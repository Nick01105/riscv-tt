// Test wrapper for rv_decode_group: per-slot fields unpacked from the real
// uop_t struct, plus width checks for SLOT_W and UOP_W.
module tb_decode_group #(parameter int W = 1, parameter int IW = (W > 1) ? $clog2(W) : 1) (
  input  logic [W*32-1:0] raw,
  input  logic [W-1:0]    valid,
  output logic [W*5-1:0]  rd, rs1, rs2,
  output logic [W-1:0]    rd_we, rs1_en, rs2_en, illegal,
  output logic [W-1:0]    dep1_v, dep2_v,
  output logic [W*IW-1:0] dep1_i, dep2_i
);
  logic [W*frontend_pkg::SLOT_W-1:0] slots;
  logic [W*frontend_pkg::UOP_W-1:0]  uops;
  for (genvar k = 0; k < W; k++) begin : g
    frontend_pkg::fetch_slot_t s;
    frontend_pkg::uop_t u;
    always_comb begin
      s = '0;
      s.raw32 = raw[k*32 +: 32];
    end
    assign slots[k*frontend_pkg::SLOT_W +: frontend_pkg::SLOT_W] = s;
    assign u = uops[k*frontend_pkg::UOP_W +: frontend_pkg::UOP_W];
    assign rd[k*5 +: 5] = u.rd;
    assign rs1[k*5 +: 5] = u.rs1;
    assign rs2[k*5 +: 5] = u.rs2;
    assign rd_we[k] = u.rd_we;
    assign rs1_en[k] = u.rs1_en;
    assign rs2_en[k] = u.rs2_en;
    assign illegal[k] = u.illegal;
  end
  rv_decode_group #(.W(W)) dut (.slots_i(slots), .valid_i(valid), .uops_o(uops),
    .dep1_v_o(dep1_v), .dep1_i_o(dep1_i), .dep2_v_o(dep2_v), .dep2_i_o(dep2_i));
  initial begin
    if ($bits(frontend_pkg::uop_t) != frontend_pkg::UOP_W) $fatal(1, "UOP_W %0d != %0d", frontend_pkg::UOP_W, $bits(frontend_pkg::uop_t));
    if ($bits(frontend_pkg::fetch_slot_t) != frontend_pkg::SLOT_W) $fatal(1, "SLOT_W mismatch");
  end
endmodule
