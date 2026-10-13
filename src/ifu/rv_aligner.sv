// rv_aligner - turn a fetch block of 16-bit parcels into instruction slots.
//
// * Finds instruction boundaries (rv_ilen_detect) and expands compressed
//   instructions (rv_rvc_expand, one per slot).
// * A 32-bit instruction whose first half is the block's last parcel is held
//   in a carry register and emitted with the next block. It gets the pc where
//   it starts and the ftq_idx of the block where it ends.
// * in_taken_i marks the parcel where the predicted-taken instruction ENDS
//   (a mark on the first half of a 32-bit instruction also marks it).
//   Instructions after it are dropped and the carry is not kept. A mark on
//   the last parcel when it starts a 32-bit instruction is also honoured:
//   that instruction is still carried, and the backend corrects the stream.
// * A block with a fetch fault emits only its first instruction, marked with
//   the fault (raw32 = 0); the backend raises the exception and redirects.
// * If the predicted-taken mark sits on a last parcel that starts a 32-bit
//   instruction, that instruction is incomplete and the next block is the
//   target: the slot is emitted as FAULT_REFETCH (raw32 = 0). The backend
//   squashes it, refetches from its pc and invalidates the BTB entry.
// * Slot p holds the instruction that starts at parcel p; slot 0 holds the
//   carried instruction instead when there is one (its upper half is parcel 0).
//
// in_ready_o = out_ready_i: the consumer takes all slots of a block at once.
module rv_aligner (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   flush_i,      // redirect: drop the carry
  input  logic                                   in_valid_i,
  output logic                                   in_ready_o,
  input  frontend_pkg::paddr_t                   in_pc_i,      // first byte to use
  input  logic [frontend_pkg::FETCH_BYTES*8-1:0] in_data_i,    // whole aligned block
  input  logic [frontend_pkg::NPARCEL-1:0]       in_taken_i,
  input  frontend_pkg::fault_e                   in_fault_i,
  input  frontend_pkg::ftq_idx_t                 in_ftq_i,
  output logic [frontend_pkg::NPARCEL-1:0]       out_valid_o,
  output logic [frontend_pkg::NPARCEL*frontend_pkg::SLOT_W-1:0] out_slots_o,
  input  logic                                   out_ready_i
);
  localparam int NP     = frontend_pkg::NPARCEL;
  localparam int FB     = frontend_pkg::FETCH_BYTES;
  localparam int OFF_W  = $clog2(FB);
  localparam int SW     = $clog2(NP);
  localparam int PW     = frontend_pkg::PADDR_W;
  localparam int SLOT_W = frontend_pkg::SLOT_W;
  localparam int                   LAST_I   = 2 * NP - 2;
  localparam frontend_pkg::paddr_t LAST_OFF = PW'(LAST_I);

  // ---- carry register ------------------------------------------------------
  logic                  carry_q;
  logic [15:0]           carry_lo_q;
  frontend_pkg::paddr_t  carry_pc_q;
  frontend_pkg::fault_e  carry_fault_q;

  logic [SW-1:0]         start;
  frontend_pkg::paddr_t  base;
  logic                  carry_use;
  logic                  faulted;

  assign start     = in_pc_i[OFF_W-1:1];
  assign base      = {in_pc_i[PW-1:OFF_W], {OFF_W{1'b0}}};
  assign carry_use = carry_q && (start == '0);
  assign faulted   = (in_fault_i != frontend_pkg::FAULT_NONE);

  logic [NP-1:0] start_mask, rvc_mask;
  logic          spills;

  rv_ilen_detect #(.NP(NP)) u_ilen (
    .parcels_i   (in_data_i),
    .start_i     (start),
    .carry_i     (carry_use),
    .start_mask_o(start_mask),
    .rvc_mask_o  (rvc_mask),
    .carry_o     (spills)
  );

  // ---- which slots are live, and which one is predicted taken ---------------
  logic [NP-1:0] valid, taken;
  logic          carry_next;

  logic          refetch_p;                     // slot NP-1 is a refetch marker

  always_comb begin : walk
    logic alive;
    logic first;
    alive     = 1'b1;
    first     = 1'b1;
    valid     = '0;
    taken     = '0;
    refetch_p = 1'b0;
    if (carry_use) begin                                 // carried instruction ends at parcel 0
      valid[0] = 1'b1;
      taken[0] = in_taken_i[0];
      first    = 1'b0;
      if (in_taken_i[0] || faulted) alive = 1'b0;
    end
    for (int p = 0; p < NP; p++) begin
      if (start_mask[p] && alive) begin
        if (rvc_mask[p]) begin
          valid[p] = 1'b1;
          taken[p] = in_taken_i[p];
          if (in_taken_i[p]) alive = 1'b0;
        end else if (p < NP - 1) begin
          // A mark on either parcel counts: a stale or aliased BTB entry may
          // point at the first half, and the stream still jumps after it.
          valid[p] = 1'b1;
          taken[p] = in_taken_i[(p + 1) % NP] || in_taken_i[p];
          if (in_taken_i[(p + 1) % NP] || in_taken_i[p]) alive = 1'b0;
        end else if (faulted && first) begin
          valid[p] = 1'b1;                               // faulting block: report the start
        end else if (in_taken_i[p]) begin
          // Predicted taken at the first half of a 32-bit instruction that
          // spills into the next block: the next block fetched is the target,
          // not the second half. Emit a refetch marker instead of gluing.
          valid[p]  = 1'b1;
          taken[p]  = 1'b1;
          refetch_p = 1'b1;
          alive     = 1'b0;
        end
        if (faulted) alive = 1'b0;                       // only the first instruction
        first = 1'b0;
      end
    end
    carry_next = alive && spills && !faulted;
  end

  // ---- build the slots -----------------------------------------------------
  // Slots are built by concatenation in fetch_slot_t field order
  // {valid, pc, raw32, is_rvc, pred_taken, fault, ftq_idx}: Yosys 0.33 cannot
  // assign members of a struct declared inside a generate block.
  logic [NP-1:0] unused_ill;

  for (genvar p = 0; p < NP; p++) begin : g_slot
    localparam frontend_pkg::paddr_t OFF = PW'(2 * p);
    logic [31:0]          raw, expanded, raw_o;
    logic                 exp_rvc, rvc_o, v_o, is_carry;
    frontend_pkg::paddr_t pc_o;
    logic [1:0]           flt_o;      // plain vector: Icarus wants enum casts, Yosys rejects them

    assign is_carry = (p == 0) && carry_use;

    always_comb begin
      if (is_carry)          raw = {in_data_i[15:0], carry_lo_q};
      else if (rvc_mask[p])  raw = {16'b0, in_data_i[p*16 +: 16]};
      else                   raw = {in_data_i[((p + 1) % NP)*16 +: 16], in_data_i[p*16 +: 16]};
    end

    rv_rvc_expand #(.XLEN(frontend_pkg::XLEN)) u_exp (
      .instr_i(raw), .instr_o(expanded), .is_rvc_o(exp_rvc), .illegal_o(unused_ill[p])
    );

    assign v_o   = valid[p] && in_valid_i;
    assign pc_o  = is_carry ? carry_pc_q : (base | OFF);
    assign flt_o = (is_carry && carry_fault_q != frontend_pkg::FAULT_NONE) ? carry_fault_q :
                   (p == NP - 1 && refetch_p && in_fault_i == frontend_pkg::FAULT_NONE) ? frontend_pkg::FAULT_REFETCH :
                   in_fault_i;
    assign raw_o = (flt_o != frontend_pkg::FAULT_NONE) ? 32'b0 : expanded;
    assign rvc_o = (flt_o != frontend_pkg::FAULT_NONE) ? 1'b0  : exp_rvc;

    assign out_slots_o[p*SLOT_W +: SLOT_W] = {v_o, pc_o, raw_o, rvc_o, taken[p], flt_o, in_ftq_i};
    assign out_valid_o[p]                  = v_o;
  end

  assign in_ready_o = out_ready_i;

  // in_pc_i[0] is always 0 (instructions are 2-byte aligned); the expanders'
  // illegal flags are not needed (the decoder sees the raw parcel).
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = in_pc_i[0] ^ (^unused_ill);
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clk) begin
    if (!rst_n || flush_i) begin
      carry_q <= 1'b0;
    end else if (in_valid_i && out_ready_i) begin
      carry_q       <= carry_next;
      carry_lo_q    <= in_data_i[(NP-1)*16 +: 16];
      carry_pc_q    <= base | LAST_OFF;
      carry_fault_q <= in_fault_i;
    end
  end
endmodule
