// frontend_pkg.sv - shared parameters and interface types.
// Values must match docs/spec.md sections 3 and 4.
// Default build is TT (RV32E). Define RV_CFG_FULL for the document's RV64 config.

package frontend_pkg;

  // Parameters are consumed by blocks at Levels 1-3; not all are used yet.
  /* verilator lint_off UNUSEDPARAM */

`ifdef RV_CFG_FULL
  localparam int XLEN              = 64;
  localparam int PADDR_W           = 64;
  localparam int FETCH_BYTES       = 16;
  localparam int DECODE_W          = 4;
  localparam int IC_BYTES          = 32768;
  localparam int IC_WAYS           = 4;
  localparam int IC_LINE_BYTES     = 64;
  localparam int IC_MSHRS          = 4;
  localparam int AXI_DATA_W        = 64;
  localparam int BTB_ENTRIES       = 1024;
  localparam int RAS_DEPTH         = 16;
  localparam int FTQ_DEPTH         = 16;
  localparam int TAGE_BASE_ENTRIES = 2048;
  localparam int TAGE_NTABLES      = 4;
  localparam int TAGE_ENTRIES      = 512;
  localparam int TAGE_TAG_W        = 10;
  localparam int GHR_LEN           = 130;
  localparam int SRAM_LATCH        = 0;     // flop arrays (simulation, FPGA)
  localparam int RVE               = 0;     // 32 registers
  localparam int CACHE_PA_W        = 64;    // address bits kept in cache tags and BTB targets
  localparam int BTB_TAG_W         = 10;
  localparam logic [31:0] TAGE_HLENS = {8'd130, 8'd44, 8'd15, 8'd5};   // table t at [8t +: 8]
`else
  localparam int XLEN              = 32;
  localparam int PADDR_W           = 32;
  localparam int FETCH_BYTES       = 4;
  localparam int DECODE_W          = 1;
  localparam int IC_BYTES          = 32;    // 64 B (option C), then 32 B after the first hardening run (14 Oct)
  localparam int IC_WAYS           = 1;
  localparam int IC_LINE_BYTES     = 16;
  localparam int IC_MSHRS          = 1;
  localparam int AXI_DATA_W        = 32;
  localparam int BTB_ENTRIES       = 4;     // area cut of 14 Oct (was 8)
  localparam int RAS_DEPTH         = 2;     // area cut of 14 Oct (was 4)
  localparam int FTQ_DEPTH         = 4;     // >= 3: the youngest committed entry stays live, and a
                                           // straddling 32-bit instruction needs two more (2 deadlocks)
  localparam int TAGE_BASE_ENTRIES = 64;
  localparam int TAGE_NTABLES      = 0;     // area cut of 14 Oct: bimodal only in silicon (TAGE: 2, GHR_LEN 12)
  localparam int TAGE_ENTRIES      = 16;
  localparam int TAGE_TAG_W        = 6;
  localparam int GHR_LEN           = 2;     // unused by the bimodal predictor (rv_ghr minimum)
  localparam int SRAM_LATCH        = 1;     // latch arrays to fit in 16 tiles
  localparam int RVE               = 1;     // option A: RV32E, 16 registers
  localparam int CACHE_PA_W        = 25;    // flash + PSRAM span 32 MB (0x0000_0000-0x01FF_FFFF)
  localparam int BTB_TAG_W         = 6;
  localparam logic [15:0] TAGE_HLENS = {8'd12, 8'd4};                  // table t at [8t +: 8]
`endif

  localparam int AXI_ID_W      = 2;
`ifdef RV_CFG_FULL
  localparam int IQ_DEPTH      = 16;
`else
  localparam int IQ_DEPTH      = 2;       // area cut of 14 Oct (was 4)
`endif
  localparam int TAGE_CTR_W    = 3;
  localparam int TAGE_U_W      = 2;

  // Backend
`ifdef RV_CFG_FULL
  localparam int HPM_W         = 64;    // mhpmcounter width
  localparam int HPM_N         = 4;     // mhpmcounter3..6 implemented
  localparam int RAS_CKPT_TOP  = 1;     // FTQ checkpoints the RAS top value as well as the pointer
`else
  localparam int HPM_W         = 32;    // TT: 32-bit event counters (mhpmcounterNh read 0)
  localparam int HPM_N         = 2;     // TT: mhpmcounter3-4 (mispredicts, I-cache misses); 5-6 read 0
  localparam int RAS_CKPT_TOP  = 0;     // TT: pointer only (area cut of 14 Oct)
`endif
  // Memory map (spec section 5). Atomics are legal only in PSRAM.
  localparam logic [31:0] PSRAM_BASE  = 32'h0100_0000;
  localparam int          PSRAM_BITS  = 24;                     // 16 MB (PSRAM A + B)

  // Derived
  localparam int NPARCEL       = FETCH_BYTES / 2;               // 16-bit parcels per fetch block
  localparam int REFILL_BEATS  = IC_LINE_BYTES / (AXI_DATA_W / 8);
  localparam int FTQ_IDX_W     = (FTQ_DEPTH > 1) ? $clog2(FTQ_DEPTH) : 1;
  localparam int MSHR_IDX_W    = (IC_MSHRS  > 1) ? $clog2(IC_MSHRS)  : 1;
  localparam int IC_SETS       = IC_BYTES / (IC_LINE_BYTES * IC_WAYS);
  localparam int NREGS         = (RVE != 0) ? 16 : 32;

  typedef logic [XLEN-1:0]      xlen_t;
  typedef logic [PADDR_W-1:0]   paddr_t;
  typedef logic [FTQ_IDX_W-1:0] ftq_idx_t;
  typedef logic [GHR_LEN-1:0]   ghist_t;

  // ---------------------------------------------------------------------------
  // Common enums
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    FAULT_NONE   = 2'd0,
    FAULT_ACCESS = 2'd1,   // AXI SLVERR/DECERR on fetch
    FAULT_PAGE   = 2'd2,   // reserved for the Sv32 MMU project
    FAULT_REFETCH = 2'd3   // not a fault: squash this slot and refetch from its pc
  } fault_e;

  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_COND = 3'd1,        // conditional branch
    BR_JAL  = 3'd2,        // direct jump, no link
    BR_JALR = 3'd3,        // indirect jump, no link
    BR_CALL = 3'd4,        // jal/jalr with rd = x1 or x5 (push RAS)
    BR_RET  = 3'd5         // jalr with rs1 = x1/x5, rd != link (pop RAS)
  } br_type_e;

  typedef enum logic [2:0] {
    FU_NONE = 3'd0,
    FU_ALU  = 3'd1,
    FU_BRU  = 3'd2,
    FU_MUL  = 3'd3,
    FU_DIV  = 3'd4,
    FU_LSU  = 3'd5,
    FU_CSR  = 3'd6
  } fu_e;

  typedef enum logic [2:0] {
    SYS_NONE    = 3'd0,
    SYS_ECALL   = 3'd1,
    SYS_EBREAK  = 3'd2,
    SYS_MRET    = 3'd3,
    SYS_WFI     = 3'd4,
    SYS_FENCE   = 3'd5,
    SYS_FENCE_I = 3'd6
  } sys_e;

  // uop_t.op encodings, one set per functional unit. MUL/DIV and CSR use
  // the instruction's funct3 directly (uop_t.f3).
  typedef enum logic [4:0] {
    ALU_ADD  = 5'd0,  ALU_SUB  = 5'd1,  ALU_SLL  = 5'd2,  ALU_SLT  = 5'd3,
    ALU_SLTU = 5'd4,  ALU_XOR  = 5'd5,  ALU_SRL  = 5'd6,  ALU_SRA  = 5'd7,
    ALU_OR   = 5'd8,  ALU_AND  = 5'd9,  ALU_PASSB = 5'd10   // lui: result = imm
  } alu_op_e;

  typedef enum logic [4:0] {
    BRU_BEQ  = 5'd0,  BRU_BNE  = 5'd1,  BRU_BLT  = 5'd4,  BRU_BGE  = 5'd5,
    BRU_BLTU = 5'd6,  BRU_BGEU = 5'd7,  BRU_JAL  = 5'd8,  BRU_JALR = 5'd9
  } bru_op_e;                          // conditional ops equal their funct3

  typedef enum logic [4:0] {
    LSU_LOAD    = 5'd0,  LSU_STORE   = 5'd1,  LSU_LR      = 5'd2,  LSU_SC      = 5'd3,
    LSU_AMOSWAP = 5'd4,  LSU_AMOADD  = 5'd5,  LSU_AMOXOR  = 5'd6,  LSU_AMOAND  = 5'd7,
    LSU_AMOOR   = 5'd8,  LSU_AMOMIN  = 5'd9,  LSU_AMOMAX  = 5'd10, LSU_AMOMINU = 5'd11,
    LSU_AMOMAXU = 5'd12
  } lsu_op_e;                          // access size and sign come from uop_t.f3

  typedef enum logic [1:0] {
    RDR_MISPREDICT = 2'd0,
    RDR_EXCEPTION  = 2'd1,
    RDR_FENCE_I    = 2'd2,   // also flushes the I-cache
    RDR_SERIALIZE  = 2'd3    // CSR write or other refetch
  } redirect_cause_e;

  // ---------------------------------------------------------------------------
  // 1. BPU -> fetch
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                valid;
    paddr_t              pc;          // first byte to fetch (may be mid-block after a jump)
    logic [NPARCEL-1:0]  taken_mask;  // parcel where the predicted-taken instruction ENDS
    logic                block_end;   // block ends here (taken branch or block boundary)
    ftq_idx_t            ftq_idx;
  } fetch_req_t;

  // ---------------------------------------------------------------------------
  // 2. Fetch -> decode (one slot; a bundle is DECODE_W slots)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    paddr_t      pc;
    logic [31:0] raw32;       // expanded to 32 bits when is_rvc
    logic        is_rvc;
    logic        pred_taken;
    fault_e      fault;
    ftq_idx_t    ftq_idx;
  } fetch_slot_t;

  // Width of fetch_slot_t. Bundles of slots are passed as flat vectors of
  // SLOT_W-bit chunks, because Yosys 0.33 silently miscompiles member access on
  // packed arrays of structs. tb_aligner checks this against $bits().
  localparam int SLOT_W = 1 + PADDR_W + 32 + 1 + 1 + 2 + FTQ_IDX_W;

  // ---------------------------------------------------------------------------
  // 3. Decode -> backend
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    paddr_t      pc;
    logic        is_rvc;      // pc + 2 is the link/fall-through address
    fu_e         fu;
    logic [4:0]  op;          // FU-specific: alu_op_e, bru_op_e, lsu_op_e; funct3 for MUL/DIV/CSR
    logic [2:0]  f3;          // raw funct3 (memory size/sign, MUL/DIV and CSR variant)
    logic [4:0]  rd;
    logic        rd_we;
    logic [4:0]  rs1;
    logic        rs1_en;
    logic [4:0]  rs2;
    logic        rs2_en;
    xlen_t       imm;         // CSR ops: zero-extended CSR address; rs1 field is zimm for CSR*I
    logic        use_imm;     // operand B is imm
    logic        use_pc;      // operand A is pc (auipc, jal)
    logic        word_op;     // RV64 *W instruction
    br_type_e    br_type;
    logic        pred_taken;
    sys_e        sys;
    logic        illegal;
    fault_e      fault;
    logic [31:0] raw32;       // for mtval and tracing
    ftq_idx_t    ftq_idx;
  } uop_t;

  // Width of uop_t, for flat bundles (checked against $bits in tb_decode_group)
  localparam int UOP_W = 1 + PADDR_W + 1 + 3 + 5 + 3 + 5 + 1 + 5 + 1 + 5 + 1 + XLEN + 1 + 1 + 1 + 3 + 1 + 3
                       + 1 + 2 + 32 + FTQ_IDX_W;

  // ---------------------------------------------------------------------------
  // 4. Backend -> frontend
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic            valid;
    paddr_t          target;     // fetch restarts here
    ftq_idx_t        ftq_idx;    // FTQ entries younger than this are discarded
    redirect_cause_e cause;
  } redirect_t;

  typedef struct packed {
    logic      valid;
    paddr_t    pc;
    logic      is_rvc;           // instruction length, to find its end parcel
    logic      taken;
    paddr_t    target;
    br_type_e  br_type;          // BR_NONE for a predicted-taken non-branch
    logic      mispredict;
    ftq_idx_t  ftq_idx;          // FTQ entry holds the history checkpoint
  } br_resolve_t;

  // Backend -> frontend: instructions of FTQ entries older than ftq_idx have
  // all retired, so those entries can be freed.
  typedef struct packed {
    logic      valid;
    ftq_idx_t  ftq_idx;
  } ftq_retire_t;

  // FTQ -> predictor training port (adds the checkpoint looked up by ftq_idx)
  typedef struct packed {
    logic      valid;
    paddr_t    pc;
    logic      taken;
    paddr_t    target;
    br_type_e  br_type;
    logic      mispredict;
    ghist_t    hist;             // global history at prediction time
  } bp_train_t;

  // ---------------------------------------------------------------------------
  // 5. I-cache -> AXI master
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                  valid;
    paddr_t                addr;   // address of the missing word (critical word first)
    logic [MSHR_IDX_W-1:0] mshr;
  } refill_req_t;

  typedef struct packed {
    logic                  valid;
    logic [AXI_DATA_W-1:0] data;
    logic                  last;
    logic                  err;    // SLVERR or DECERR on this beat
    logic [MSHR_IDX_W-1:0] mshr;
  } refill_beat_t;

  // ---------------------------------------------------------------------------
  // AXI4 read channels (valid/ready kept outside the structs)
  // ---------------------------------------------------------------------------
  localparam logic [1:0] AXI_BURST_FIXED = 2'b00;
  localparam logic [1:0] AXI_BURST_INCR  = 2'b01;
  localparam logic [1:0] AXI_BURST_WRAP  = 2'b10;

  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_EXOKAY = 2'b01;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;

  typedef struct packed {
    logic [AXI_ID_W-1:0] id;
    paddr_t              addr;
    logic [7:0]          len;     // beats - 1
    logic [2:0]          size;    // log2(bytes per beat)
    logic [1:0]          burst;
    logic                lock;
    logic [3:0]          cache;
    logic [2:0]          prot;
  } axi_ar_t;

  typedef struct packed {
    logic [AXI_ID_W-1:0]   id;
    logic [AXI_DATA_W-1:0] data;
    logic [1:0]            resp;
    logic                  last;
  } axi_r_t;

  // Flat widths of the AXI payloads (checked against $bits in tb_axi_rd_slice)
  localparam int AXI_AR_W = AXI_ID_W + PADDR_W + 8 + 3 + 2 + 1 + 4 + 3;
  localparam int AXI_R_W  = AXI_ID_W + AXI_DATA_W + 2 + 1;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  // Geometric history length of tagged table t. A function (not an array
  // parameter) and no 'return' statement, so Icarus, Verilator and Yosys 0.33
  // all accept it.
  function automatic int tage_hist_len(input int t);
`ifdef RV_CFG_FULL
    case (t)
      0: tage_hist_len = 5;
      1: tage_hist_len = 15;
      2: tage_hist_len = 44;
      default: tage_hist_len = 130;
    endcase
`else
    case (t)
      0: tage_hist_len = 4;
      default: tage_hist_len = 12;
    endcase
`endif
  endfunction

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // A 16-bit parcel starts a compressed instruction unless its low bits are 11.
  function automatic logic parcel_is_rvc(input logic [1:0] lo);
    parcel_is_rvc = (lo != 2'b11);
  endfunction

  /* verilator lint_on UNUSEDPARAM */
endpackage
