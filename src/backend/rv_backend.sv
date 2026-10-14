// rv_backend - in-order scalar pipeline behind rv_frontend.
//
//   ID  uop from the frontend's decoder; register-file read issued
//   EX  forwarding, ALU, branch unit (resolve / mispredict redirect),
//       iterative mul/div, address generation, interrupt sampling
//   MEM commit point: loads/stores/atomics (rv_lsu), CSRs, traps, mret,
//       fence.i; frees FTQ entries
//   WB  register-file write (the register file's own write staging)
// With the frontend's fetch stage this is the classic five-stage pipeline.
//
// The register file is read every cycle: for the uop entering EX, or again
// for the uop held in EX, so a stalled uop never misses a write. Forwarding
// into EX comes from MEM (results computed in EX) and from the write of the
// previous cycle (the register file shows a write one cycle late). Results
// produced in MEM (loads, CSR reads) stall a dependent EX uop until the
// cycle after they complete.
//
// Precise traps: exceptions are carried to MEM and taken there, where the
// instruction is the oldest in flight. Interrupts are sampled when a uop
// moves from EX to MEM: it is marked, does not resolve or execute, and MEM
// takes the interrupt with mepc = its pc. No sampling while MEM holds a CSR
// instruction, so a write that disables interrupts takes effect at once.
//
// Frontend contract (rv_frontend): every branch and every pred_taken uop
// resolves in order from EX, against tgt_i for pred_taken uops; a
// FAULT_REFETCH uop resolves as BR_NONE, mispredicts, and refetches its own
// pc; FENCE.I redirects with cause FENCE_I; retire carries the FTQ index of
// the youngest committed uop (MEM redirects need their entry alive).
//
// Only slot 0 of a decode group is taken (scalar backend; the FULL build's
// 4-wide frontend therefore runs at most one uop per cycle here).
module rv_backend (
  input  logic                                   clk,
  input  logic                                   rst_n,
  // uops
  input  logic [frontend_pkg::DECODE_W-1:0]      uop_valid_i,
  input  logic [frontend_pkg::DECODE_W*frontend_pkg::UOP_W-1:0] uop_i,
  output logic [frontend_pkg::DECODE_W-1:0]      uop_ready_o,
  // to the frontend
  output frontend_pkg::redirect_t                redirect_o,
  output frontend_pkg::br_resolve_t              resolve_o,
  output frontend_pkg::ftq_retire_t              retire_o,
  output frontend_pkg::ftq_idx_t                 tgt_idx_o,
  input  frontend_pkg::paddr_t                   tgt_i,
  // data bus
  output logic                                   dreq_valid_o,
  input  logic                                   dreq_ready_i,
  output frontend_pkg::paddr_t                   dreq_addr_o,
  output logic                                   dreq_we_o,
  output logic [1:0]                             dreq_size_o,
  output logic [frontend_pkg::XLEN/8-1:0]        dreq_be_o,
  output logic [frontend_pkg::XLEN-1:0]          dreq_wdata_o,
  input  logic                                   drsp_valid_i,
  input  logic [frontend_pkg::XLEN-1:0]          drsp_rdata_i,
  input  logic                                   drsp_err_i,
  // interrupts, time, events
  input  logic                                   mtip_i,
  input  logic                                   msip_i,
  input  logic [63:0]                            mtime_i,
  input  logic                                   ev_ic_miss_i,
  // commit trace (simulation and debug)
  output logic                                   trc_valid_o,
  output frontend_pkg::paddr_t                   trc_pc_o,
  output logic [31:0]                            trc_insn_o,
  output logic                                   trc_trap_o,
  output logic [frontend_pkg::XLEN-1:0]          trc_cause_o,
  output logic [4:0]                             trc_rd_o,      // 0: no register written
  output logic [frontend_pkg::XLEN-1:0]          trc_rd_val_o,
  output logic                                   trc_mispredict_o
);
  localparam int XLEN = frontend_pkg::XLEN;
  localparam int PW   = frontend_pkg::PADDR_W;
  localparam int UW   = frontend_pkg::UOP_W;
  localparam int DW   = frontend_pkg::DECODE_W;
  localparam int RA_W = $clog2(frontend_pkg::NREGS);

  // ==== ID ===========================================================================
  frontend_pkg::uop_t d_u;
  assign d_u = uop_i[0 +: UW];

  logic redir_any, d_accept;
  logic ex_v_q, ex_fire;
  frontend_pkg::uop_t ex_u_q;

  assign d_accept    = uop_valid_i[0] && !redir_any && (!ex_v_q || ex_fire);
  assign uop_ready_o = DW'(!redir_any && (!ex_v_q || ex_fire));

  logic [XLEN-1:0] rf_rd1, rf_rd2;
  logic            rf_we, ex_hold;
  logic [4:0]      rf_wa;
  logic [RA_W-1:0] rs1_rd, rs2_rd;
  logic [XLEN-1:0] rf_wd;
  logic            w_v_q;                // the write of the previous cycle, for forwarding
  logic [4:0]      w_rd_q;
  logic [XLEN-1:0] w_data_q;

  assign rs1_rd = ex_hold ? ex_u_q.rs1[RA_W-1:0] : d_u.rs1[RA_W-1:0];
  assign rs2_rd = ex_hold ? ex_u_q.rs2[RA_W-1:0] : d_u.rs2[RA_W-1:0];

  rv_regfile #(.W(XLEN), .NREGS(frontend_pkg::NREGS), .LATCH(frontend_pkg::SRAM_LATCH)) u_rf (
    .clk, .re_i(1'b1), .raddr1_i(rs1_rd), .raddr2_i(rs2_rd),
    .rdata1_o(rf_rd1), .rdata2_o(rf_rd2),
    .we_i(rf_we), .waddr_i(rf_wa[RA_W-1:0]), .wdata_i(rf_wd)
  );

  // ==== EX ===========================================================================
  frontend_pkg::uop_t mem_u_q;
  logic            mem_v_q, mem_late, mem_done, mem_redir;
  logic [XLEN-1:0] mem_res_q;

  assign mem_late = (mem_u_q.fu == frontend_pkg::FU_LSU) || (mem_u_q.fu == frontend_pkg::FU_CSR);

  function automatic logic [XLEN-1:0] fwd(
    input logic [4:0] rs, input logic [XLEN-1:0] raw,
    input logic mv, input logic mwe, input logic ml, input logic [4:0] mrd, input logic [XLEN-1:0] mres,
    input logic wv, input logic [4:0] wrd, input logic [XLEN-1:0] wdat);
    if (mv && mwe && !ml && mrd == rs) fwd = mres;
    else if (wv && wrd == rs)          fwd = wdat;
    else                               fwd = raw;
  endfunction

  logic [XLEN-1:0] a, b;
  assign a = fwd(ex_u_q.rs1, rf_rd1, mem_v_q, mem_u_q.rd_we, mem_late, mem_u_q.rd, mem_res_q, w_v_q, w_rd_q, w_data_q);
  assign b = fwd(ex_u_q.rs2, rf_rd2, mem_v_q, mem_u_q.rd_we, mem_late, mem_u_q.rd, mem_res_q, w_v_q, w_rd_q, w_data_q);

  logic hazard;
  assign hazard = mem_v_q && mem_u_q.rd_we && mem_late &&
                  ((ex_u_q.rs1_en && ex_u_q.rs1 == mem_u_q.rd) || (ex_u_q.rs2_en && ex_u_q.rs2 == mem_u_q.rd));

  logic ok, refetch, is_br, is_md, is_jalr;
  assign ok      = (ex_u_q.fault == frontend_pkg::FAULT_NONE);
  assign refetch = (ex_u_q.fault == frontend_pkg::FAULT_REFETCH);
  assign is_br   = ok && (ex_u_q.fu == frontend_pkg::FU_BRU);
  assign is_md   = ok && (ex_u_q.fu == frontend_pkg::FU_MUL || ex_u_q.fu == frontend_pkg::FU_DIV);
  assign is_jalr = (ex_u_q.op == frontend_pkg::BRU_JALR);

  // ALU
  logic [XLEN-1:0] opa, opb, alu_y;
  assign opa = ex_u_q.use_pc ? XLEN'(ex_u_q.pc) : a;
  assign opb = ex_u_q.use_imm ? ex_u_q.imm : b;
  rv_alu #(.XLEN(XLEN)) u_alu (.op_i(ex_u_q.op), .word_i(ex_u_q.word_op), .a_i(opa), .b_i(opb), .y_o(alu_y));

  // branch unit and address generation share one adder
  logic [XLEN-1:0] base, sum, tgt, link;
  assign base = ((is_br && is_jalr) || ex_u_q.fu == frontend_pkg::FU_LSU) ? a : XLEN'(ex_u_q.pc);
  assign sum  = base + ex_u_q.imm;
  assign tgt  = is_jalr ? {sum[XLEN-1:1], 1'b0} : sum;
  assign link = XLEN'(ex_u_q.pc) + (ex_u_q.is_rvc ? XLEN'(2) : XLEN'(4));

  logic eq, lt, ltu, cond, taken;
  assign eq   = (a == b);
  assign lt   = $signed(a) < $signed(b);
  assign ltu  = a < b;
  assign cond = (ex_u_q.op[2] ? (ex_u_q.op[1] ? ltu : lt) : eq) ^ ex_u_q.op[0];
  assign taken = is_br && (ex_u_q.op[3] || cond);           // BRU_JAL / BRU_JALR have op[3] set

  logic [PW-1:0] act_npc, pred_npc;
  logic          need_res, mispred;
  assign act_npc  = refetch ? ex_u_q.pc : PW'(taken ? tgt : link);
  assign pred_npc = ex_u_q.pred_taken ? tgt_i : PW'(link);
  assign need_res = is_br || ex_u_q.pred_taken || refetch;
  assign mispred  = refetch || (act_npc != pred_npc);
  assign tgt_idx_o = ex_u_q.ftq_idx;

  // multiply / divide
  logic            md_busy, md_done, md_start;
  logic [XLEN-1:0] md_y;
  assign md_start = ex_v_q && is_md && !hazard && !md_busy && !md_done;
  generate
    if (frontend_pkg::HAS_M != 0) begin : g_md
      rv_muldiv #(.XLEN(XLEN)) u_md (
        .clk, .rst_n, .kill_i(mem_redir), .start_i(md_start), .f3_i(ex_u_q.f3), .word_i(ex_u_q.word_op),
        .a_i(a), .b_i(b), .busy_o(md_busy), .done_o(md_done), .ack_i(ex_fire), .y_o(md_y)
      );
    end else begin : g_no_md
      // no M extension: the decoder makes every MUL/DIV encoding illegal
      assign md_busy = 1'b0;
      assign md_done = 1'b0;
      assign md_y    = '0;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_md;
      assign unused_md = md_start;
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endgenerate

  logic ex_ready, mem_free, irq_pending, irq_mark;
  logic [3:0] irq_cause;
  assign ex_ready = !hazard && (!is_md || md_done);
  assign mem_free = !mem_v_q || mem_done;
  assign ex_fire  = ex_v_q && ex_ready && mem_free && !mem_redir;
  assign ex_hold  = ex_v_q && !ex_fire;
  assign irq_mark = ex_fire && irq_pending && !refetch && !(mem_v_q && mem_u_q.fu == frontend_pkg::FU_CSR);

  logic ex_redir;
  assign ex_redir = ex_fire && need_res && mispred && !irq_mark;

  logic [XLEN-1:0] ex_res;
  always_comb begin
    case (ex_u_q.fu)
      frontend_pkg::FU_ALU:                     ex_res = alu_y;
      frontend_pkg::FU_BRU:                     ex_res = link;
      frontend_pkg::FU_MUL, frontend_pkg::FU_DIV: ex_res = md_y;
      default:                                  ex_res = '0;
    endcase
  end

  always_comb begin
    resolve_o            = '0;
    resolve_o.valid      = ex_fire && need_res && !irq_mark;
    resolve_o.pc         = ex_u_q.pc;
    resolve_o.is_rvc     = ex_u_q.is_rvc;
    resolve_o.taken      = taken;
    resolve_o.target     = PW'(is_br ? tgt : link);
    resolve_o.br_type    = is_br ? ex_u_q.br_type : frontend_pkg::BR_NONE;
    resolve_o.mispredict = mispred;
    resolve_o.ftq_idx    = ex_u_q.ftq_idx;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ex_v_q <= 1'b0;
    end else begin
      if (d_accept) begin
        ex_v_q <= 1'b1;
        ex_u_q <= d_u;
      end else if (ex_fire || mem_redir || ex_redir) begin
        ex_v_q <= 1'b0;
      end
    end
  end

  // ==== MEM ==========================================================================
  logic [XLEN-1:0] mem_sd_q;
  logic            mem_irq_q;
  logic [3:0]      mem_irq_cause_q;
  logic            mem_mispred_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_v_q <= 1'b0;
    end else if (ex_fire) begin
      mem_v_q         <= !refetch;
      mem_u_q         <= ex_u_q;
      mem_res_q       <= (ex_u_q.fu == frontend_pkg::FU_LSU) ? sum : ex_res;   // LSU: the address
      mem_sd_q        <= (ex_u_q.fu == frontend_pkg::FU_CSR) ? a : b;
      mem_irq_q       <= irq_mark;
      mem_irq_cause_q <= irq_cause;
      mem_mispred_q   <= ex_redir;
    end else if (mem_done) begin
      mem_v_q <= 1'b0;
    end
  end

  frontend_pkg::uop_t m;
  assign m = mem_u_q;

  logic m_fault, m_pre, m_ecall, m_ebreak, m_mret, m_fencei, m_csr, m_lsu;
  assign m_fault  = (m.fault != frontend_pkg::FAULT_NONE);
  assign m_pre    = mem_irq_q || m_fault || m.illegal;             // nothing executes
  assign m_ecall  = !m_pre && m.sys == frontend_pkg::SYS_ECALL;
  assign m_ebreak = !m_pre && m.sys == frontend_pkg::SYS_EBREAK;
  assign m_mret   = !m_pre && m.sys == frontend_pkg::SYS_MRET;
  assign m_fencei = !m_pre && m.sys == frontend_pkg::SYS_FENCE_I;
  assign m_csr    = !m_pre && m.fu == frontend_pkg::FU_CSR && m.sys == frontend_pkg::SYS_NONE;
  assign m_lsu    = !m_pre && m.fu == frontend_pkg::FU_LSU;

  // CSR instruction
  logic [11:0]     csr_addr;
  logic [4:0]      csr_rs1;
  logic [1:0]      csr_kind;
  logic [XLEN-1:0] csr_src, csr_old, csr_new;
  logic            csr_exists, csr_wr, csr_ill;
  assign csr_addr = m.raw32[31:20];
  assign csr_rs1  = m.raw32[19:15];
  assign csr_kind = m.f3[1:0];
  assign csr_src  = m.f3[2] ? XLEN'(csr_rs1) : mem_sd_q;
  assign csr_wr   = (csr_kind == 2'd1) || (csr_rs1 != 5'd0);
  assign csr_ill  = m_csr && (!csr_exists || (csr_wr && csr_addr[11:10] == 2'b11));
  always_comb begin
    case (csr_kind)
      2'd1:    csr_new = csr_src;
      2'd2:    csr_new = csr_old | csr_src;
      default: csr_new = csr_old & ~csr_src;
    endcase
  end

  // load / store
  logic            lsu_done, lsu_exc, lsu_stall;
  logic [3:0]      lsu_cause;
  logic [XLEN-1:0] lsu_rd;
  rv_lsu #(.XLEN(XLEN), .PW(PW)) u_lsu (
    .clk, .rst_n, .valid_i(mem_v_q && m_lsu), .op_i(m.op), .f3_i(m.f3), .addr_i(PW'(mem_res_q)), .wdata_i(mem_sd_q),
    .done_o(lsu_done), .exc_o(lsu_exc), .exc_cause_o(lsu_cause), .rd_val_o(lsu_rd), .stall_o(lsu_stall),
    .req_valid_o(dreq_valid_o), .req_ready_i(dreq_ready_i), .req_addr_o(dreq_addr_o), .req_we_o(dreq_we_o),
    .req_size_o(dreq_size_o), .req_be_o(dreq_be_o), .req_wdata_o(dreq_wdata_o),
    .rsp_valid_i(drsp_valid_i), .rsp_rdata_i(drsp_rdata_i), .rsp_err_i(drsp_err_i)
  );

  assign mem_done = mem_v_q && (!m_lsu || lsu_done);

  // trap selection
  logic            trap;
  logic [3:0]      cause;
  logic [XLEN-1:0] tval;
  always_comb begin
    trap  = 1'b1;
    cause = 4'd0;
    tval  = '0;
    if (mem_irq_q)                                begin cause = mem_irq_cause_q; end
    else if (m.fault == frontend_pkg::FAULT_ACCESS) begin cause = 4'd1;  tval = XLEN'(m.pc); end
    else if (m.illegal || csr_ill)                begin cause = 4'd2;  tval = XLEN'(m.raw32); end
    else if (m_ecall)                             begin cause = 4'd11; end
    else if (m_ebreak)                            begin cause = 4'd3;  tval = XLEN'(m.pc); end
    else if (m_lsu && lsu_exc)                    begin cause = lsu_cause; tval = XLEN'(PW'(mem_res_q)); end
    else                                          trap = 1'b0;
    trap = trap && mem_done;
  end

  logic            commit;
  logic [XLEN-1:0] trap_vec, mepc, m_link;
  assign commit   = mem_done && !trap;
  assign m_link   = XLEN'(m.pc) + (m.is_rvc ? XLEN'(2) : XLEN'(4));
  assign mem_redir = trap || (commit && (m_mret || m_fencei));

  logic [3:0] ev;
  assign ev[0] = ex_redir && !refetch;
  assign ev[1] = ev_ic_miss_i;
  assign ev[2] = !uop_valid_i[0] && !redir_any && (!ex_v_q || ex_fire);
  assign ev[3] = lsu_stall;

  rv_csr #(.XLEN(XLEN), .HPM_W(frontend_pkg::HPM_W), .HPM_N(frontend_pkg::HPM_N), .RVE(frontend_pkg::RVE != 0), .HAS_M(frontend_pkg::HAS_M != 0)) u_csr (
    .clk, .rst_n,
    .addr_i(csr_addr), .rdata_o(csr_old), .exists_o(csr_exists),
    .we_i(commit && m_csr && csr_wr), .wdata_i(csr_new),
    .trap_i(trap), .trap_irq_i(mem_irq_q), .trap_cause_i(cause), .trap_pc_i(XLEN'(m.pc)), .trap_tval_i(tval),
    .trap_vec_o(trap_vec), .mret_i(commit && m_mret), .mepc_o(mepc),
    .instret_i(commit), .ev_i(ev), .mtime_i,
    .mtip_i, .msip_i, .irq_pending_o(irq_pending), .irq_cause_o(irq_cause)
  );

  // ==== redirect / retire ================================================================
  always_comb begin
    redirect_o = '0;
    if (mem_redir) begin
      redirect_o.valid   = 1'b1;
      redirect_o.target  = PW'(trap ? trap_vec : (m_mret ? mepc : m_link));
      redirect_o.ftq_idx = m.ftq_idx;
      redirect_o.cause   = (!trap && m_fencei) ? frontend_pkg::RDR_FENCE_I : frontend_pkg::RDR_EXCEPTION;
    end else if (ex_redir) begin
      redirect_o.valid   = 1'b1;
      redirect_o.target  = act_npc;
      redirect_o.ftq_idx = ex_u_q.ftq_idx;
      redirect_o.cause   = frontend_pkg::RDR_MISPREDICT;
    end
  end
  assign redir_any = redirect_o.valid;

  assign retire_o.valid   = commit;
  assign retire_o.ftq_idx = m.ftq_idx;

  // ==== WB ===========================================================================
  logic [XLEN-1:0] m_rd_val;
  assign m_rd_val = m_lsu ? lsu_rd : (m_csr ? csr_old : mem_res_q);

  assign rf_we = commit && m.rd_we;
  assign rf_wa = m.rd;
  assign rf_wd = m_rd_val;

  always_ff @(posedge clk) begin
    if (!rst_n) w_v_q <= 1'b0;
    else        w_v_q <= rf_we;
    w_rd_q   <= rf_wa;
    w_data_q <= rf_wd;
  end

  // ==== trace ==========================================================================
  assign trc_valid_o      = mem_done;
  assign trc_pc_o         = m.pc;
  assign trc_insn_o       = m.raw32;
  assign trc_trap_o       = trap;
  assign trc_cause_o      = {mem_irq_q, {(XLEN-5){1'b0}}, cause};
  assign trc_rd_o         = (commit && m.rd_we) ? m.rd : 5'd0;
  assign trc_rd_val_o     = m_rd_val;
  assign trc_mispredict_o = mem_mispred_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{uop_valid_i, uop_i, sum, m};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
