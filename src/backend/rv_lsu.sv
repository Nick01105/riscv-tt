// rv_lsu - load/store unit for the MEM stage (uncached, one access at a time).
//
// The MEM stage is the commit point, so the instruction here is the oldest
// in flight and may touch memory: every access waits for its response, and
// a bus error becomes a precise access fault.
//
// * Loads and stores: one bus access. Misaligned addresses trap.
// * LR / SC: the reservation is one address. SC succeeds only on the exact
//   address of the last LR; any SC clears it, and so does any store or AMO
//   to the same 8-byte granule. A failing SC does not touch the bus.
// * AMOs: a read, then a write of the new value. The core is the only data
//   master, so the pair is atomic. Atomics are legal only in PSRAM; elsewhere
//   they raise an access fault (load fault for LR, store fault otherwise).
//
// Data bus: a request (addr, we, size, byte enables, lane-aligned wdata) is
// held until req_ready_i; the response comes in a later cycle with the
// naturally aligned XLEN-bit word that holds the address, or err.
module rv_lsu #(
  parameter int XLEN = 32,
  parameter int PW   = 32
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              valid_i,      // MEM holds an LSU uop with no earlier exception
  input  logic [4:0]        op_i,         // frontend_pkg::lsu_op_e
  input  logic [2:0]        f3_i,         // size (1:0) and unsigned (2)
  input  logic [PW-1:0]     addr_i,
  input  logic [XLEN-1:0]   wdata_i,      // rs2
  output logic              done_o,       // completes this cycle (with or without exception)
  output logic              exc_o,
  output logic [3:0]        exc_cause_o,
  output logic [XLEN-1:0]   rd_val_o,
  output logic              stall_o,      // waiting for memory (performance event)
  // data bus
  output logic              req_valid_o,
  input  logic              req_ready_i,
  output logic [PW-1:0]     req_addr_o,
  output logic              req_we_o,
  output logic [1:0]        req_size_o,
  output logic [XLEN/8-1:0] req_be_o,
  output logic [XLEN-1:0]   req_wdata_o,
  input  logic              rsp_valid_i,
  input  logic [XLEN-1:0]   rsp_rdata_i,
  input  logic              rsp_err_i
);
  localparam int OW = $clog2(XLEN / 8);
  localparam logic [1:0] S_ISSUE1 = 2'd0, S_WAIT1 = 2'd1, S_ISSUE2 = 2'd2, S_WAIT2 = 2'd3;

  logic [1:0]      st_q;
  logic [XLEN-1:0] old_q;
  logic            resv_v_q;
  logic [PW-1:0]   resv_a_q;

  // ---- decode -------------------------------------------------------------------
  logic is_load, is_store, is_lr, is_sc, is_amo, is_atomic, reads_first;
  assign is_load     = (op_i == frontend_pkg::LSU_LOAD);
  assign is_store    = (op_i == frontend_pkg::LSU_STORE);
  assign is_lr       = (op_i == frontend_pkg::LSU_LR);
  assign is_sc       = (op_i == frontend_pkg::LSU_SC);
  assign is_amo      = (op_i >= frontend_pkg::LSU_AMOSWAP);
  assign is_atomic   = is_lr || is_sc || is_amo;
  assign reads_first = is_load || is_lr || is_amo;

  logic [1:0]    size;
  logic [OW-1:0] off;
  logic          misal, region_bad, sc_fail, pre_exc;
  logic [3:0]    pre_cause;
  assign size = f3_i[1:0];
  assign off  = addr_i[OW-1:0];
  always_comb begin
    case (size)
      2'd0:    misal = 1'b0;
      2'd1:    misal = addr_i[0];
      2'd2:    misal = |addr_i[1:0];
      default: misal = |addr_i[2:0];
    endcase
  end
  assign region_bad = is_atomic && (addr_i[PW-1:frontend_pkg::PSRAM_BITS] !=
                                    (PW - frontend_pkg::PSRAM_BITS)'(PW'(frontend_pkg::PSRAM_BASE) >> frontend_pkg::PSRAM_BITS));
  assign sc_fail    = is_sc && !(resv_v_q && resv_a_q == addr_i);
  assign pre_exc    = misal || region_bad;
  // misaligned: 4 load / 6 store-AMO; region: 5 LR / 7 SC-AMO
  assign pre_cause  = misal ? ((is_load || is_lr) ? 4'd4 : 4'd6) : (is_lr ? 4'd5 : 4'd7);

  // ---- sizing helpers ---------------------------------------------------------------
  function automatic logic [XLEN-1:0] extend(input logic [XLEN-1:0] v, input logic [1:0] sz, input logic sgn);
    case (sz)
      2'd0:    extend = sgn ? {{(XLEN-8){v[7]}},   v[7:0]}  : {{(XLEN-8){1'b0}},  v[7:0]};
      2'd1:    extend = sgn ? {{(XLEN-16){v[15]}}, v[15:0]} : {{(XLEN-16){1'b0}}, v[15:0]};
      2'd2:    extend = (sgn || XLEN == 32) ? {{(XLEN-32){v[31]}}, v[31:0]} : {{(XLEN-32){1'b0}}, v[31:0]};
      default: extend = v;
    endcase
  endfunction

  logic [XLEN-1:0] rsp_shift, ld_val, old_ext, old_u, b_s, b_u, amo_new, wsrc;
  assign rsp_shift = rsp_rdata_i >> {off, 3'b000};
  assign ld_val    = extend(rsp_shift, size, !f3_i[2]);
  assign old_ext   = extend(old_q, size, 1'b1);
  assign old_u     = extend(old_q, size, 1'b0);
  assign b_s       = extend(wdata_i, size, 1'b1);
  assign b_u       = extend(wdata_i, size, 1'b0);

  always_comb begin
    case (op_i)
      frontend_pkg::LSU_AMOSWAP: amo_new = wdata_i;
      frontend_pkg::LSU_AMOADD:  amo_new = old_q + wdata_i;
      frontend_pkg::LSU_AMOXOR:  amo_new = old_q ^ wdata_i;
      frontend_pkg::LSU_AMOAND:  amo_new = old_q & wdata_i;
      frontend_pkg::LSU_AMOOR:   amo_new = old_q | wdata_i;
      frontend_pkg::LSU_AMOMIN:  amo_new = ($signed(old_ext) < $signed(b_s)) ? old_q : wdata_i;
      frontend_pkg::LSU_AMOMAX:  amo_new = ($signed(old_ext) > $signed(b_s)) ? old_q : wdata_i;
      frontend_pkg::LSU_AMOMINU: amo_new = (old_u < b_u) ? old_q : wdata_i;
      default:                   amo_new = (old_u > b_u) ? old_q : wdata_i;   // AMOMAXU
    endcase
  end

  // ---- bus ----------------------------------------------------------------------------
  logic go;
  assign go   = valid_i && !pre_exc && !sc_fail;
  assign wsrc = (st_q == S_ISSUE2) ? amo_new : wdata_i;

  logic [XLEN/8-1:0] be_base;
  always_comb begin
    case (size)
      2'd0:    be_base = (XLEN/8)'(8'h01);
      2'd1:    be_base = (XLEN/8)'(8'h03);
      2'd2:    be_base = (XLEN/8)'(8'h0F);
      default: be_base = (XLEN/8)'(8'hFF);
    endcase
  end

  assign req_valid_o = go && (st_q == S_ISSUE1 || st_q == S_ISSUE2);
  assign req_addr_o  = addr_i;
  assign req_we_o    = (st_q == S_ISSUE2) || is_store || is_sc;
  assign req_size_o  = size;
  assign req_be_o    = be_base << off;
  assign req_wdata_o = wsrc << {off, 3'b000};

  logic fin1, fin2;
  assign fin1 = go && st_q == S_WAIT1 && rsp_valid_i && (rsp_err_i || !is_amo);
  assign fin2 = go && st_q == S_WAIT2 && rsp_valid_i;

  assign done_o      = valid_i && (pre_exc || sc_fail || fin1 || fin2);
  assign exc_o       = valid_i && (pre_exc || ((fin1 || fin2) && rsp_err_i));
  assign exc_cause_o = pre_exc ? pre_cause : (reads_first && !is_amo ? 4'd5 : 4'd7);
  assign stall_o     = valid_i && !done_o;

  always_comb begin
    if (is_sc)       rd_val_o = {{(XLEN-1){1'b0}}, sc_fail};
    else if (is_amo) rd_val_o = old_ext;
    else             rd_val_o = ld_val;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st_q     <= S_ISSUE1;
      resv_v_q <= 1'b0;
    end else begin
      case (st_q)
        S_ISSUE1: if (req_valid_o && req_ready_i) st_q <= S_WAIT1;
        S_WAIT1:  if (rsp_valid_i) begin
          if (is_amo && !rsp_err_i) begin
            st_q  <= S_ISSUE2;
            old_q <= rsp_shift;
          end else begin
            st_q <= S_ISSUE1;
          end
        end
        S_ISSUE2: if (req_valid_o && req_ready_i) st_q <= S_WAIT2;
        default:  if (rsp_valid_i) st_q <= S_ISSUE1;
      endcase
      if (done_o && !exc_o) begin
        if (is_lr) begin
          resv_v_q <= 1'b1;
          resv_a_q <= addr_i;
        end else if (is_sc) begin
          resv_v_q <= 1'b0;
        end else if ((is_store || is_amo) && resv_a_q[PW-1:3] == addr_i[PW-1:3]) begin
          resv_v_q <= 1'b0;
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{reads_first};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
