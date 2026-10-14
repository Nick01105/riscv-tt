// rv_csr - machine-mode CSRs, counters and interrupt state.
//
// Implemented (all M-mode, no S/U):
//   mstatus (MIE, MPIE; MPP reads 3), misa (read-only: XLEN, A C M, E or I),
//   mie / mip (MSI bit 3, MTI bit 7), mtvec (direct or vectored), mscratch,
//   mepc, mcause, mtval, mcountinhibit (CY, IR, HPM3-6),
//   mcycle, minstret (64-bit), mhpmcounter3-6 (HPM_W bits), their RV32 *h
//   halves, the user aliases cycle/time/instret/hpmcounter3-6, and the
//   read-only ID registers (zero). mhpmcounter7-31 and mhpmevent3-31 read
//   zero and ignore writes. Every other address is illegal.
//
// The backend reads (comb) and writes at its commit point; a write lands at
// the clock edge. Read-only (addr[11:10] == 3) write checks are done by the
// caller, which knows whether the instruction writes at all.
//
// Counter events: hpm3 branch mispredicts, hpm4 I-cache misses, hpm5 cycles
// the backend waited for the frontend, hpm6 cycles waiting for data memory.
module rv_csr #(
  parameter int XLEN  = 32,
  parameter int HPM_W = 32,               // <= XLEN; RV32 *h halves of hpm counters read 0
  parameter int HPM_N = 4,                // mhpmcounter3..(2+HPM_N) count; the rest of 3-6 read 0 (0 allowed)
  parameter bit RVE   = 1'b1
) (
  input  logic            clk,
  input  logic            rst_n,
  // access
  input  logic [11:0]     addr_i,
  output logic [XLEN-1:0] rdata_o,
  output logic            exists_o,
  input  logic            we_i,
  input  logic [XLEN-1:0] wdata_i,
  // traps
  input  logic            trap_i,
  input  logic            trap_irq_i,
  input  logic [3:0]      trap_cause_i,
  input  logic [XLEN-1:0] trap_pc_i,
  input  logic [XLEN-1:0] trap_tval_i,
  output logic [XLEN-1:0] trap_vec_o,
  input  logic            mret_i,
  output logic [XLEN-1:0] mepc_o,
  // counters
  input  logic            instret_i,
  input  logic [3:0]      ev_i,
  input  logic [63:0]     mtime_i,
  // interrupts
  input  logic            mtip_i,
  input  logic            msip_i,
  output logic            irq_pending_o,
  output logic [3:0]      irq_cause_o
);
  localparam bit X32 = (XLEN == 32);

  logic            mie_q, mpie_q;
  logic            mtie_q, msie_q;
  logic [XLEN-1:0] mtvec_q, mscratch_q, mepc_q, mtval_q;
  logic            mcause_irq_q;
  logic [3:0]      mcause_q;
  logic [6:0]      minh_q;                       // mcountinhibit bits 6:0 (bit 1 is zero)
  logic [63:0]     mcycle_q, minstret_q;
  localparam int HQ = (HPM_N > 0) ? HPM_N : 1;     // storage rows (one unused row when HPM_N = 0)
  logic [HQ*HPM_W-1:0] hpm_q;

  // ---- read ------------------------------------------------------------------
  logic [XLEN-1:0] misa, mstatus, mip, mie, mcause;
  logic [1:0]      mxl;
  assign mxl     = X32 ? 2'd1 : 2'd2;
  assign misa    = {mxl, {(XLEN-28){1'b0}}, 26'(1 << 12 | 1 << 2 | 1 << 0 | (RVE ? (1 << 4) : (1 << 8)))};
  assign mstatus = XLEN'({mpie_q, 3'b000, mie_q, 3'b000}) | XLEN'(32'h1800);
  assign mip     = XLEN'({mtip_i, 3'b000, msip_i, 3'b000});
  assign mie     = XLEN'({mtie_q, 3'b000, msie_q, 3'b000});
  assign mcause  = {mcause_irq_q, {(XLEN-5){1'b0}}, mcause_q};

  logic [4*HPM_W-1:0] hpm_all;          // counters 3-6, unimplemented ones zero
  assign hpm_all = (HPM_N > 0) ? (4*HPM_W)'(hpm_q) : '0;

  function automatic logic [63:0] hpm64(input logic [4*HPM_W-1:0] v, input logic [1:0] i);
    hpm64 = 64'(v[i*HPM_W +: HPM_W]);
  endfunction

  logic [63:0] cnt;            // selected 64-bit counter for the counter address ranges
  logic        cnt_hit;
  logic [4:0]  cidx;
  assign cidx = addr_i[4:0];

  always_comb begin
    cnt_hit = 1'b0;
    cnt     = '0;
    if (addr_i[11:8] == 4'hB || addr_i[11:8] == 4'hC) begin
      // B00-B1F / B80-B9F (machine), C00-C1F / C80-C9F (user aliases)
      if (addr_i[6:5] == 2'b00 && (!addr_i[7] || X32)) begin
        case (cidx)
          5'd0: begin cnt_hit = 1'b1; cnt = mcycle_q; end
          5'd1: begin cnt_hit = (addr_i[11:8] == 4'hC); cnt = mtime_i; end   // time: user only
          5'd2: begin cnt_hit = 1'b1; cnt = minstret_q; end
          5'd3, 5'd4, 5'd5, 5'd6: begin cnt_hit = 1'b1; cnt = hpm64(hpm_all, 2'(cidx - 5'd3)); end
          default: begin cnt_hit = (addr_i[11:8] == 4'hB); cnt = '0; end     // mhpmcounter7-31 read 0
        endcase
      end
    end
  end

  always_comb begin
    exists_o = 1'b1;
    rdata_o  = '0;
    if (cnt_hit) begin
      if (X32) rdata_o = addr_i[7] ? XLEN'(cnt[63:32]) : XLEN'(cnt[31:0]);
      else     rdata_o = XLEN'(cnt);
    end else begin
      case (addr_i)
        12'h300: rdata_o = mstatus;
        12'h301: rdata_o = misa;
        12'h304: rdata_o = mie;
        12'h305: rdata_o = mtvec_q;
        12'h320: rdata_o = XLEN'(minh_q);
        12'h340: rdata_o = mscratch_q;
        12'h341: rdata_o = mepc_q;
        12'h342: rdata_o = mcause;
        12'h343: rdata_o = mtval_q;
        12'h344: rdata_o = mip;
        12'hF11, 12'hF12, 12'hF13, 12'hF14: rdata_o = '0;
        default: begin
          exists_o = (addr_i >= 12'h323 && addr_i <= 12'h33F);       // mhpmevent3-31 read 0
        end
      endcase
    end
  end

  // ---- interrupts ------------------------------------------------------------------
  logic msi, mti;
  assign msi           = msip_i && msie_q;
  assign mti           = mtip_i && mtie_q;
  assign irq_pending_o = mie_q && (msi || mti);
  assign irq_cause_o   = msi ? 4'd3 : 4'd7;

  assign trap_vec_o = (trap_irq_i && mtvec_q[0]) ? ({mtvec_q[XLEN-1:2], 2'b00} + XLEN'({trap_cause_i, 2'b00}))
                                                 : {mtvec_q[XLEN-1:2], 2'b00};
  assign mepc_o     = mepc_q;

  // ---- write -----------------------------------------------------------------------
  logic wr_cycle_lo, wr_cycle_hi, wr_instret_lo, wr_instret_hi;
  assign wr_cycle_lo   = we_i && addr_i == 12'hB00;
  assign wr_cycle_hi   = we_i && addr_i == 12'hB80 && X32;
  assign wr_instret_lo = we_i && addr_i == 12'hB02;
  assign wr_instret_hi = we_i && addr_i == 12'hB82 && X32;
  logic wr_inhibit;
  assign wr_inhibit    = we_i && addr_i == 12'h320;

  logic [63:0] wd64;
  assign wd64 = 64'(wdata_i);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mie_q        <= 1'b0;
      mpie_q       <= 1'b0;
      mtie_q       <= 1'b0;
      msie_q       <= 1'b0;
      mtvec_q      <= '0;
      mscratch_q   <= '0;
      mepc_q       <= '0;
      mtval_q      <= '0;
      mcause_irq_q <= 1'b0;
      mcause_q     <= '0;
      minh_q       <= '0;
      mcycle_q     <= '0;
      minstret_q   <= '0;
      hpm_q        <= '0;
    end else begin
      // counters (a write in the same cycle wins)
      if (!minh_q[0]) mcycle_q <= mcycle_q + 64'd1;
      // a write to mcountinhibit already applies to the writing instruction (as in the reference ISS)
      if (instret_i && !(wr_inhibit ? wdata_i[2] : minh_q[2]) && !wr_instret_lo && !wr_instret_hi)
        minstret_q <= minstret_q + 64'd1;
      for (int i = 0; i < HPM_N; i++) begin
        if (ev_i[i] && !minh_q[3 + i]) hpm_q[i*HPM_W +: HPM_W] <= hpm_q[i*HPM_W +: HPM_W] + 1'b1;
      end

      if (trap_i) begin
        mpie_q       <= mie_q;
        mie_q        <= 1'b0;
        mepc_q       <= {trap_pc_i[XLEN-1:1], 1'b0};
        mcause_irq_q <= trap_irq_i;
        mcause_q     <= trap_cause_i;
        mtval_q      <= trap_tval_i;
      end else if (mret_i) begin
        mie_q  <= mpie_q;
        mpie_q <= 1'b1;
      end else if (we_i) begin
        case (addr_i)
          12'h300: begin mie_q <= wdata_i[3]; mpie_q <= wdata_i[7]; end
          12'h304: begin msie_q <= wdata_i[3]; mtie_q <= wdata_i[7]; end
          12'h305: mtvec_q <= {wdata_i[XLEN-1:2], 1'b0, wdata_i[0]};
          12'h320: minh_q <= {wdata_i[6:2], 1'b0, wdata_i[0]};
          12'h340: mscratch_q <= wdata_i;
          12'h341: mepc_q <= {wdata_i[XLEN-1:1], 1'b0};
          12'h342: begin mcause_irq_q <= wdata_i[XLEN-1]; mcause_q <= wdata_i[3:0]; end
          12'h343: mtval_q <= wdata_i;
          default: ;
        endcase
        if (wr_cycle_lo)   mcycle_q   <= X32 ? {mcycle_q[63:32], wd64[31:0]} : wd64;
        if (wr_cycle_hi)   mcycle_q   <= {wd64[31:0], mcycle_q[31:0]};
        if (wr_instret_lo) minstret_q <= X32 ? {minstret_q[63:32], wd64[31:0]} : wd64;
        if (wr_instret_hi) minstret_q <= {wd64[31:0], minstret_q[31:0]};
        for (int i = 0; i < HPM_N; i++) begin
          if (addr_i == 12'hB03 + 12'(i)) hpm_q[i*HPM_W +: HPM_W] <= HPM_W'(wd64);
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{wd64[63:32], trap_pc_i[0], ev_i};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
