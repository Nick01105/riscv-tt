"""rv_iss - instruction-set simulator for the riscv-tt core (reference model).

RV32/RV64 IMAC (+E) + Zicsr + Zifencei, M-mode only, with the riscv-tt
memory map (docs/spec.md section 5). Used as:
  * the golden model in lockstep with the RTL (step() returns a retirement
    record comparable to the core's trace port);
  * a source of branch traces for the predictor studies.

It is written from the ISA manuals independently of the RTL, and cross-checked
against Spike (scripts/iss_vs_spike.py).

Simplifications that match the RTL:
  * misaligned loads/stores raise address-misaligned exceptions;
  * MMIO registers are 32-bit; sub-word loads return byte lanes, and the only
    sub-word store accepted is a byte store to the UART data register;
  * no PMP, no S/U modes, single hart; LR/SC reservation is one address;
  * mcycle / mhpmcounters cannot be predicted by an ISS: in lockstep the
    RTL's value is taken (see `volatile_csr`).
"""
from dataclasses import dataclass, field

# ---- memory map (docs/spec.md section 5) -------------------------------------
FLASH_BASE, FLASH_SIZE = 0x0000_0000, 16 << 20
PSRAM_BASE, PSRAM_SIZE = 0x0100_0000, 16 << 20      # PSRAM A + B, contiguous
CLINT_BASE = 0x0200_0000
MSIP, MTIMECMP, MTIME = CLINT_BASE + 0x0, CLINT_BASE + 0x4000, CLINT_BASE + 0xBFF8
UART_BASE = 0x1000_0000          # +0 data (write: TX, read: RX), +4 status (bit0 tx ready, bit1 rx valid), +8 divisor
GPIO_BASE = 0x1000_0100          # +0 out, +4 in
TOHOST = 0x1000_0300             # simulation-only: write 1 = pass, (code<<1)|1 = fail

# ---- CSR numbers ---------------------------------------------------------------
CSR = dict(mstatus=0x300, misa=0x301, mie=0x304, mtvec=0x305, mcountinhibit=0x320,
           mscratch=0x340, mepc=0x341, mcause=0x342, mtval=0x343, mip=0x344,
           mcycle=0xB00, minstret=0xB02, mcycleh=0xB80, minstreth=0xB82,
           cycle=0xC00, time=0xC01, instret=0xC02, cycleh=0xC80, timeh=0xC81, instreth=0xC82,
           mvendorid=0xF11, marchid=0xF12, mimpid=0xF13, mhartid=0xF14)
HPM_FIRST, HPM_LAST = 3, 6       # mhpmcounter3..6 implemented (mispredicts, I-cache misses, ...)
VOLATILE_CSRS = ({CSR["mcycle"], CSR["mcycleh"], CSR["cycle"], CSR["cycleh"], CSR["time"], CSR["timeh"]}
                 | {0xB00 + i for i in range(HPM_FIRST, HPM_LAST + 1)}
                 | {0xB80 + i for i in range(HPM_FIRST, HPM_LAST + 1)}
                 | {0xC00 + i for i in range(HPM_FIRST, HPM_LAST + 1)}
                 | {0xC80 + i for i in range(HPM_FIRST, HPM_LAST + 1)})

# exception causes
INSN_MISALIGNED, INSN_ACCESS, ILLEGAL, BREAKPOINT = 0, 1, 2, 3
LOAD_MISALIGNED, LOAD_ACCESS, STORE_MISALIGNED, STORE_ACCESS, ECALL_M = 4, 5, 6, 7, 11
IRQ_MSI, IRQ_MTI = 3, 7


class Trap(Exception):
    def __init__(self, cause, tval=0):
        super().__init__(cause, tval)
        self.cause, self.tval = cause, tval


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


@dataclass
class Retire:
    """One retired instruction (or a trap taken instead of it)."""
    pc: int
    insn: int                  # raw bits (16-bit for compressed)
    rd: int = 0                # 0 when nothing is written
    rd_val: int = 0
    trap: int | None = None    # mcause if this instruction trapped / an interrupt was taken
    next_pc: int = 0
    mem: tuple | None = None   # (addr, size, value, is_store)


@dataclass
class Hart:
    xlen: int = 32
    rve: bool = True
    rvm: bool | None = None          # M extension; None = as the build: TT (RV32E) has none, FULL has it
    reset_pc: int = 0
    flash_base: int = FLASH_BASE     # 0x2000_0000 for the Spike cross-check builds
    tohost_addr: int = TOHOST        # 0x01FF_F000 (in PSRAM) for the Spike builds
    x: list = field(default_factory=lambda: [0] * 32)
    pc: int = 0
    uart_out: bytearray = field(default_factory=bytearray)
    uart_in: bytearray = field(default_factory=bytearray)
    tohost: int | None = None

    def __post_init__(self):
        self.mask = (1 << self.xlen) - 1
        self.flash = bytearray(FLASH_SIZE)
        self.psram = bytearray(PSRAM_SIZE)
        self.pc = self.reset_pc
        self.reservation = None
        self.mtime = 0
        self.mtimecmp = self.mask if self.xlen == 64 else (1 << 64) - 1
        self.msip = 0
        self.gpio_out = 0
        self.gpio_in = 0
        mxl = 1 if self.xlen == 32 else 2
        if self.rvm is None:
            self.rvm = not self.rve
        ext = sum(1 << (ord(c) - 65) for c in ("AC" + ("M" if self.rvm else "") + ("E" if self.rve else "I")))
        self.csr = {CSR["mstatus"]: 0, CSR["misa"]: (mxl << (self.xlen - 2)) | ext, CSR["mie"]: 0,
                    CSR["mtvec"]: 0, CSR["mscratch"]: 0, CSR["mepc"]: 0, CSR["mcause"]: 0,
                    CSR["mtval"]: 0, CSR["mcountinhibit"]: 0, CSR["mvendorid"]: 0, CSR["marchid"]: 0,
                    CSR["mimpid"]: 0, CSR["mhartid"]: 0}
        self.cycle = 0
        self.instret = 0
        self.hpm = [0] * (HPM_LAST + 1)
        self.volatile_csr = None       # set by lockstep: value the RTL read
        self.mtime_rate = 1
        self.uart_div = 216                            # rv_uart reset value (115200 baud at 25 MHz)

    # ---- memory --------------------------------------------------------------
    def load_image(self, addr, data):
        reg, base = self._region(addr, len(data))
        reg[addr - base:addr - base + len(data)] = data

    def _region(self, addr, size):
        fb = self.flash_base
        if fb <= addr and addr + size <= fb + FLASH_SIZE:
            return self.flash, fb
        if PSRAM_BASE <= addr and addr + size <= PSRAM_BASE + PSRAM_SIZE:
            return self.psram, PSRAM_BASE
        return None, None

    def read(self, addr, size, fetch=False):
        reg, base = self._region(addr, size)
        if reg is not None:
            return int.from_bytes(reg[addr - base:addr - base + size], "little")
        if fetch:
            raise Trap(INSN_ACCESS, addr)
        if size != 4:                                  # sub-word MMIO read: byte lanes of the word
            word = self.read(addr & ~3, 4)
            return (word >> (8 * (addr & 3))) & ((1 << (8 * size)) - 1)
        if addr == MSIP:
            return self.msip
        if addr == MTIMECMP:
            return self.mtimecmp & 0xFFFFFFFF
        if addr == MTIMECMP + 4:
            return (self.mtimecmp >> 32) & 0xFFFFFFFF
        if addr == MTIME:
            return self.mtime & 0xFFFFFFFF
        if addr == MTIME + 4:
            return (self.mtime >> 32) & 0xFFFFFFFF
        if addr == UART_BASE:
            return self.uart_in.pop(0) if self.uart_in else 0
        if addr == UART_BASE + 4:
            return 1 | (2 if self.uart_in else 0)
        if addr == UART_BASE + 8:
            return self.uart_div
        if addr == GPIO_BASE:
            return self.gpio_out
        if addr == GPIO_BASE + 4:
            return self.gpio_in
        raise Trap(LOAD_ACCESS, addr)

    def write(self, addr, size, val):
        if addr == self.tohost_addr:
            self.tohost = val & 0xFFFFFFFF
        reg, base = self._region(addr, size)
        if reg is self.psram:
            reg[addr - base:addr - base + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, "little")
            return
        if reg is self.flash:
            raise Trap(STORE_ACCESS, addr)
        if size != 4:                                  # sub-word MMIO write: only the UART data byte
            if (addr & ~3) == UART_BASE and (addr & 3) == 0:
                self.uart_out.append(val & 0xFF)
                return
            raise Trap(STORE_ACCESS, addr)
        val &= 0xFFFFFFFF
        if addr == MSIP:
            self.msip = val & 1
        elif addr == MTIMECMP:
            self.mtimecmp = (self.mtimecmp & ~0xFFFFFFFF) | val
        elif addr == MTIMECMP + 4:
            self.mtimecmp = (self.mtimecmp & 0xFFFFFFFF) | (val << 32)
        elif addr == MTIME:
            self.mtime = (self.mtime & ~0xFFFFFFFF) | val
        elif addr == MTIME + 4:
            self.mtime = (self.mtime & 0xFFFFFFFF) | (val << 32)
        elif addr == UART_BASE:
            self.uart_out.append(val & 0xFF)
        elif addr == UART_BASE + 4:
            pass
        elif addr == UART_BASE + 8:
            self.uart_div = val & 0xFFFF
        elif addr == GPIO_BASE:
            self.gpio_out = val & 0x7F
        elif addr == self.tohost_addr:
            pass
        else:
            raise Trap(STORE_ACCESS, addr)

    # ---- registers -----------------------------------------------------------
    def rr(self, i):
        return self.x[i]

    def wr(self, i, v, rec):
        if i:
            self.x[i] = v & self.mask
            rec.rd, rec.rd_val = i, self.x[i]

    def s(self, v):
        return sext(v, self.xlen)

    # ---- CSRs ----------------------------------------------------------------
    def csr_read(self, n):
        if self.volatile_csr is not None and n in VOLATILE_CSRS:
            return self.volatile_csr
        x32 = self.xlen == 32
        if n in (CSR["mcycle"], CSR["cycle"]):
            return self.cycle & self.mask
        if n in (CSR["mcycleh"], CSR["cycleh"]) and x32:
            return self.cycle >> 32
        if n in (CSR["minstret"], CSR["instret"]):
            return self.instret & self.mask
        if n in (CSR["minstreth"], CSR["instreth"]) and x32:
            return (self.instret >> 32) & self.mask
        if n == CSR["time"]:
            return self.mtime & self.mask
        if n == CSR["timeh"] and x32:
            return self.mtime >> 32
        if n == CSR["mip"]:
            return (IRQ_BIT(IRQ_MTI) if self.mtime >= self.mtimecmp else 0) | (IRQ_BIT(IRQ_MSI) if self.msip else 0)
        for i in range(HPM_FIRST, HPM_LAST + 1):
            if n in (0xB00 + i, 0xC00 + i):
                return self.hpm[i] & self.mask
            if n in (0xB80 + i, 0xC80 + i) and x32:
                return self.hpm[i] >> 32
        if 0xB03 <= n <= 0xB1F or 0xB83 <= n <= 0xB9F or 0x323 <= n <= 0x33F:
            return 0                                   # unimplemented hpm counters/events read as 0
        if n in self.csr:
            return self.csr[n]
        raise Trap(ILLEGAL)

    def csr_write(self, n, v):
        if (n >> 10) == 3:
            raise Trap(ILLEGAL)                        # read-only CSR
        v &= self.mask
        x32 = self.xlen == 32
        if n == CSR["mstatus"]:
            # MIE (3), MPIE (7), MPP (12:11) fixed to M (11)
            self.csr[n] = (v & 0x88) | (3 << 11)
        elif n == CSR["mie"]:
            self.csr[n] = v & (IRQ_BIT(IRQ_MTI) | IRQ_BIT(IRQ_MSI))
        elif n == CSR["mtvec"]:
            self.csr[n] = v & ~2                       # modes 0 (direct) and 1 (vectored)
        elif n == CSR["mepc"]:
            self.csr[n] = v & ~1
        elif n in (CSR["mscratch"], CSR["mtval"]):
            self.csr[n] = v
        elif n == CSR["mcause"]:
            self.csr[n] = v & ((1 << (self.xlen - 1)) | 0xF)
        elif n == CSR["mcountinhibit"]:
            self.csr[n] = v & 0x7D                     # CY, IR, HPM3..6
        elif n == CSR["mcycle"]:
            self.cycle = (self.cycle & ~0xFFFFFFFF if x32 else 0) | v
        elif n == CSR["mcycleh"] and x32:
            self.cycle = (self.cycle & 0xFFFFFFFF) | (v << 32)
        elif n == CSR["minstret"]:
            self.instret = ((self.instret & ~0xFFFFFFFF) if x32 else 0) | v
            self._instret_written = True
        elif n == CSR["minstreth"] and x32:
            self.instret = (self.instret & 0xFFFFFFFF) | (v << 32)
            self._instret_written = True
        elif any(n in (0xB00 + i, 0xB80 + i) for i in range(HPM_FIRST, HPM_LAST + 1)):
            i = n & 0x1F
            if n < 0xB80:
                self.hpm[i] = ((self.hpm[i] & ~0xFFFFFFFF) if x32 else 0) | v
            else:
                self.hpm[i] = (self.hpm[i] & 0xFFFFFFFF) | (v << 32)
        elif 0xB03 <= n <= 0xB1F or 0xB83 <= n <= 0xB9F or 0x323 <= n <= 0x33F or n in (CSR["misa"], CSR["mip"]):
            pass                                       # WARL, writes ignored
        elif n in self.csr:
            pass                                       # read-only machine info
        else:
            raise Trap(ILLEGAL)

    # ---- traps ---------------------------------------------------------------
    def take_trap(self, cause, tval, pc, interrupt=False):
        ms = self.csr[CSR["mstatus"]]
        mie = (ms >> 3) & 1
        self.csr[CSR["mstatus"]] = (ms & ~0x88) | (mie << 7) | (3 << 11)
        self.csr[CSR["mepc"]] = pc & ~1
        self.csr[CSR["mcause"]] = ((1 << (self.xlen - 1)) if interrupt else 0) | cause
        self.csr[CSR["mtval"]] = tval & self.mask
        tv = self.csr[CSR["mtvec"]]
        base = tv & ~3
        return base + 4 * cause if (interrupt and tv & 1) else base

    def pending_irq(self):
        if not (self.csr[CSR["mstatus"]] >> 3) & 1:
            return None
        pend = self.csr_read(CSR["mip"]) & self.csr[CSR["mie"]]
        for irq in (IRQ_MSI, IRQ_MTI):                 # priority: MSI over MTI (spec order MEI > MSI > MTI)
            if pend & IRQ_BIT(irq):
                return irq
        return None

    # ---- one instruction -----------------------------------------------------
    def step(self, irq_ok=True):
        rec = Retire(pc=self.pc, insn=0)
        self._instret_written = False
        irq = self.pending_irq() if irq_ok else None
        if irq is not None:
            rec.trap = (1 << (self.xlen - 1)) | irq
            self.pc = self.take_trap(irq, 0, self.pc, interrupt=True)
            rec.next_pc = self.pc
            self._tick()
            return rec
        try:
            lo = self.read(self.pc, 2, fetch=True)
            if lo & 3 == 3:
                insn = lo | (self.read(self.pc + 2, 2, fetch=True) << 16)
                rec.insn = insn
                npc = self.exec32(insn, rec, self.pc + 4)
            else:
                rec.insn = lo
                npc = self.exec16(lo, rec)
            self.pc = npc & self.mask
            if not self._instret_written and not (self.csr[CSR["mcountinhibit"]] >> 2) & 1:
                self.instret += 1
        except Trap as t:
            rec.trap = t.cause
            rec.rd, rec.rd_val, rec.mem = 0, 0, None
            tval = t.tval if t.cause != ILLEGAL else rec.insn
            self.pc = self.take_trap(t.cause, tval, self.pc)
        rec.next_pc = self.pc
        self._tick()
        return rec

    def _tick(self):
        if not self.csr[CSR["mcountinhibit"]] & 1:
            self.cycle += 1
        self.mtime += self.mtime_rate                  # CLINT time base: ticks per instruction

    # ---- 32-bit instructions -------------------------------------------------
    def exec32(self, ins, rec, npc):
        X = self.xlen
        op, rd, f3, rs1, rs2, f7 = ins & 0x7F, (ins >> 7) & 31, (ins >> 12) & 7, (ins >> 15) & 31, (ins >> 20) & 31, ins >> 25
        i_imm = sext(ins >> 20, 12)
        s_imm = sext(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        b_imm = sext(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        u_imm = sext(ins & 0xFFFFF000, 32)
        j_imm = sext(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
        rv64 = X == 64

        def need(*regs):
            if self.rve and any(r >= 16 for r in regs):
                raise Trap(ILLEGAL)

        a, b = self.x[rs1], self.x[rs2]
        if op == 0x37:
            need(rd); self.wr(rd, u_imm, rec)
        elif op == 0x17:
            need(rd); self.wr(rd, rec.pc + u_imm, rec)
        elif op == 0x6F:
            need(rd); self.wr(rd, npc, rec); return self._target(rec.pc + j_imm)
        elif op == 0x67:
            if f3:
                raise Trap(ILLEGAL)
            need(rd, rs1)
            t = (a + i_imm) & ~1 & self.mask
            self.wr(rd, npc, rec)
            return self._target(t)
        elif op == 0x63:
            if f3 in (2, 3):
                raise Trap(ILLEGAL)
            need(rs1, rs2)
            sa, sb = self.s(a), self.s(b)
            take = [a == b, a != b, None, None, sa < sb, sa >= sb, a < b, a >= b][f3]
            if take:
                return self._target(rec.pc + b_imm)
        elif op == 0x03:
            sizes = {0: (1, 1), 1: (2, 1), 2: (4, 1), 4: (1, 0), 5: (2, 0)}
            if rv64:
                sizes.update({3: (8, 1), 6: (4, 0)})
            if f3 not in sizes:
                raise Trap(ILLEGAL)
            need(rd, rs1)
            size, signed = sizes[f3]
            addr = (a + i_imm) & self.mask
            if addr % size:
                raise Trap(LOAD_MISALIGNED, addr)
            v = self.read(addr, size)
            rec.mem = (addr, size, v, False)
            self.wr(rd, sext(v, 8 * size) if signed else v, rec)
        elif op == 0x23:
            if f3 > (3 if rv64 else 2):
                raise Trap(ILLEGAL)
            need(rs1, rs2)
            size = 1 << f3
            addr = (a + s_imm) & self.mask
            if addr % size:
                raise Trap(STORE_MISALIGNED, addr)
            v = b & ((1 << (8 * size)) - 1)
            self.write(addr, size, v)
            rec.mem = (addr, size, v, True)
            self._sc_clear(addr)
        elif op == 0x13:
            need(rd, rs1)
            sh = (ins >> 20) & (63 if rv64 else 31)
            hi = ins >> (26 if rv64 else 25)
            if f3 == 1:
                if hi != 0:
                    raise Trap(ILLEGAL)
                r = a << sh
            elif f3 == 5:
                if rv64:
                    if hi not in (0, 0x10):
                        raise Trap(ILLEGAL)
                else:
                    if hi not in (0, 0x20):
                        raise Trap(ILLEGAL)
                r = (self.s(a) >> sh) if (ins >> 30) & 1 else (a >> sh)
            else:
                r = self._alu(f3, 0, a, i_imm & self.mask, imm=True)
            self.wr(rd, r, rec)
        elif op == 0x1B and rv64:
            need(rd, rs1)
            a32 = a & 0xFFFFFFFF
            if f3 == 0:
                r = sext(a32 + i_imm, 32)
            elif f3 == 1 and f7 == 0:
                r = sext(a32 << rs2, 32)
            elif f3 == 5 and f7 in (0, 0x20):
                r = sext((sext(a32, 32) >> rs2) if f7 else (a32 >> rs2), 32)
            else:
                raise Trap(ILLEGAL)
            self.wr(rd, r, rec)
        elif op == 0x33:
            need(rd, rs1, rs2)
            if f7 == 1 and not self.rvm:
                raise Trap(ILLEGAL)
            if f7 == 1:
                r = self._muldiv(f3, a, b, X)
            elif f7 == 0 or (f7 == 0x20 and f3 in (0, 5)):
                r = self._alu(f3, f7, a, b)
            else:
                raise Trap(ILLEGAL)
            self.wr(rd, r, rec)
        elif op == 0x3B and rv64:
            need(rd, rs1, rs2)
            a32, b32 = a & 0xFFFFFFFF, b & 0xFFFFFFFF
            if f7 == 1 and not self.rvm:
                raise Trap(ILLEGAL)
            if f7 == 1 and f3 in (0, 4, 5, 6, 7):
                r = sext(self._muldiv(f3, sext(a32, 32) & 0xFFFFFFFF, sext(b32, 32) & 0xFFFFFFFF, 32), 32)
            elif f7 == 0 and f3 == 0:
                r = sext(a32 + b32, 32)
            elif f7 == 0x20 and f3 == 0:
                r = sext(a32 - b32, 32)
            elif f7 == 0 and f3 == 1:
                r = sext(a32 << (b & 31), 32)
            elif f7 == 0 and f3 == 5:
                r = sext(a32 >> (b & 31), 32)
            elif f7 == 0x20 and f3 == 5:
                r = sext(sext(a32, 32) >> (b & 31), 32)
            else:
                raise Trap(ILLEGAL)
            self.wr(rd, r, rec)
        elif op == 0x2F:
            self._amo(ins, rd, f3, rs1, rs2, rec)
        elif op == 0x0F:
            if f3 not in (0, 1):
                raise Trap(ILLEGAL)
        elif op == 0x73:
            return self._system(ins, rd, f3, rs1, rec, npc)
        else:
            raise Trap(ILLEGAL)
        return npc

    def _target(self, t):
        if t & 1:
            raise Trap(INSN_MISALIGNED, t)
        return t

    def _alu(self, f3, f7, a, b, imm=False):
        M = self.mask
        if f3 == 0:
            return (a - b) if (f7 == 0x20 and not imm) else (a + b)
        if f3 == 1:
            return a << (b & (self.xlen - 1))
        if f3 == 2:
            return int(self.s(a) < self.s(b))
        if f3 == 3:
            return int((a & M) < (b & M))
        if f3 == 4:
            return a ^ b
        if f3 == 5:
            sh = b & (self.xlen - 1)
            return (self.s(a) >> sh) if f7 == 0x20 else (a >> sh)
        if f3 == 6:
            return a | b
        return a & b

    def _muldiv(self, f3, a, b, X):
        M = (1 << X) - 1
        sa, sb = sext(a, X), sext(b, X)
        if f3 == 0:
            return (a * b) & M
        if f3 == 1:
            return ((sa * sb) >> X) & M
        if f3 == 2:
            return ((sa * b) >> X) & M
        if f3 == 3:
            return ((a * b) >> X) & M
        if f3 == 4:
            if b == 0:
                return M
            if sa == -(1 << (X - 1)) and sb == -1:
                return a
            q = abs(sa) // abs(sb)
            return (q if (sa < 0) == (sb < 0) else -q) & M
        if f3 == 5:
            return M if b == 0 else a // b
        if f3 == 6:
            if b == 0:
                return a
            if sa == -(1 << (X - 1)) and sb == -1:
                return 0
            rem = abs(sa) % abs(sb)
            return (rem if sa >= 0 else -rem) & M
        return a if b == 0 else a % b

    def _sc_clear(self, addr):
        if self.reservation is not None and (addr & ~7) == (self.reservation & ~7):
            self.reservation = None

    def _amo(self, ins, rd, f3, rs1, rs2, rec):
        f5 = ins >> 27
        if f3 not in ((2, 3) if self.xlen == 64 else (2,)):
            raise Trap(ILLEGAL)
        size = 4 if f3 == 2 else 8
        ops = {0x02: "lr", 0x03: "sc", 0x01: "swap", 0x00: "add", 0x04: "xor", 0x0C: "and", 0x08: "or",
               0x10: "min", 0x14: "max", 0x18: "minu", 0x1C: "maxu"}
        if f5 not in ops or (f5 == 0x02 and rs2 != 0):
            raise Trap(ILLEGAL)
        if self.rve and (rd >= 16 or rs1 >= 16 or (f5 != 0x02 and rs2 >= 16)):
            raise Trap(ILLEGAL)
        name = ops[f5]
        addr = self.x[rs1]
        if addr % size:
            raise Trap(LOAD_MISALIGNED if name == "lr" else STORE_MISALIGNED, addr)
        if self._region(addr, size)[0] is not self.psram:      # atomics only to PSRAM
            raise Trap(LOAD_ACCESS if name == "lr" else STORE_ACCESS, addr)
        if name == "lr":
            v = self.read(addr, size)
            self.reservation = addr
            rec.mem = (addr, size, v, False)
            self.wr(rd, sext(v, 8 * size), rec)
            return
        if name == "sc":
            ok = self.reservation == addr
            self.reservation = None
            if ok:
                v = self.x[rs2] & ((1 << (8 * size)) - 1)
                self.write(addr, size, v)
                rec.mem = (addr, size, v, True)
            self.wr(rd, 0 if ok else 1, rec)
            return
        old = self.read(addr, size)
        bits = 8 * size
        m = (1 << bits) - 1
        so, sb = sext(old, bits), sext(self.x[rs2], bits)
        b = self.x[rs2] & m
        new = {"swap": b, "add": old + b, "xor": old ^ b, "and": old & b, "or": old | b,
               "min": old if so < sb else b, "max": old if so > sb else b,
               "minu": min(old, b), "maxu": max(old, b)}[name] & m
        self.write(addr, size, new)
        self._sc_clear(addr)
        rec.mem = (addr, size, new, True)
        self.wr(rd, sext(old, bits), rec)

    def _system(self, ins, rd, f3, rs1, rec, npc):
        if f3 == 0:
            if ins == 0x00000073:
                raise Trap(ECALL_M)
            if ins == 0x00100073:
                raise Trap(BREAKPOINT, rec.pc)
            if ins == 0x30200073:
                ms = self.csr[CSR["mstatus"]]
                mpie = (ms >> 7) & 1
                self.csr[CSR["mstatus"]] = (ms & ~0x88) | (mpie << 3) | (1 << 7) | (3 << 11)
                return self.csr[CSR["mepc"]]
            if ins == 0x10500073:
                return npc                              # wfi: no-op
            raise Trap(ILLEGAL)
        if f3 == 4:
            raise Trap(ILLEGAL)
        if self.rve and (rd >= 16 or (f3 < 4 and rs1 >= 16)):
            raise Trap(ILLEGAL)
        n = ins >> 20
        src = self.x[rs1] if f3 < 4 else rs1
        kind = f3 & 3
        do_read = not (kind == 1 and rd == 0)
        do_write = kind == 1 or rs1 != 0
        if do_write and (n >> 10) == 3:
            raise Trap(ILLEGAL)
        old = self.csr_read(n) if do_read or kind != 1 else 0
        if not do_read and n not in self.csr and not self._csr_exists(n):
            raise Trap(ILLEGAL)
        if do_write:
            new = src if kind == 1 else (old | src if kind == 2 else old & ~src)
            self.csr_write(n, new)
        self.wr(rd, old, rec)
        return npc

    def _csr_exists(self, n):
        try:
            self.csr_read(n)
            return True
        except Trap:
            return False

    # ---- 16-bit instructions ---------------------------------------------------
    def exec16(self, c, rec):
        """Compressed instructions, decoded directly (not via expansion)."""
        X = self.xlen
        rv64 = X == 64
        npc = rec.pc + 2
        q, f3 = c & 3, c >> 13
        r1p, r2p = 8 + ((c >> 7) & 7), 8 + ((c >> 2) & 7)
        rd, rs2 = (c >> 7) & 31, (c >> 2) & 31
        imm6 = sext(((c >> 12) & 1) << 5 | ((c >> 2) & 31), 6)
        bit = lambda i: (c >> i) & 1

        def need(*regs):
            if self.rve and any(r >= 16 for r in regs):
                raise Trap(ILLEGAL)

        def ld(addr, size, signed=True):
            if addr % size:
                raise Trap(LOAD_MISALIGNED, addr)
            v = self.read(addr, size)
            rec.mem = (addr, size, v, False)
            return sext(v, 8 * size) if signed else v

        def st(addr, size, v):
            if addr % size:
                raise Trap(STORE_MISALIGNED, addr)
            v &= (1 << (8 * size)) - 1
            self.write(addr, size, v)
            rec.mem = (addr, size, v, True)
            self._sc_clear(addr)

        x = self.x
        if q == 0:
            if f3 == 0:
                nz = (bit(5) << 3) | (bit(6) << 2) | (((c >> 7) & 0xF) << 6) | (((c >> 11) & 3) << 4)
                if nz == 0:
                    raise Trap(ILLEGAL)
                self.wr(r2p, x[2] + nz, rec)
            elif f3 in (2, 6) or (rv64 and f3 in (3, 7)):
                if f3 & 1:
                    off = (((c >> 10) & 7) << 3) | (((c >> 5) & 3) << 6)
                    size = 8
                else:
                    off = (((c >> 10) & 7) << 3) | (bit(6) << 2) | (bit(5) << 6)
                    size = 4
                addr = (x[r1p] + off) & self.mask
                if f3 < 4:
                    self.wr(r2p, ld(addr, size), rec)
                else:
                    st(addr, size, x[r2p])
            else:
                raise Trap(ILLEGAL)
        elif q == 1:
            if f3 == 0:
                need(rd); self.wr(rd, x[rd] + imm6, rec)
            elif f3 == 1 and not rv64:
                self.wr(1, npc, rec); return self._target(rec.pc + self._cj(c))
            elif f3 == 1:
                if rd == 0:
                    raise Trap(ILLEGAL)
                need(rd); self.wr(rd, sext((x[rd] + imm6) & 0xFFFFFFFF, 32), rec)
            elif f3 == 2:
                need(rd); self.wr(rd, imm6, rec)
            elif f3 == 3:
                if rd == 2:
                    nz = sext((bit(12) << 9) | (bit(6) << 4) | (bit(5) << 6) | (((c >> 3) & 3) << 7) | (bit(2) << 5), 10)
                    if nz == 0:
                        raise Trap(ILLEGAL)
                    self.wr(2, x[2] + nz, rec)
                else:
                    if imm6 == 0:
                        raise Trap(ILLEGAL)
                    need(rd); self.wr(rd, imm6 << 12, rec)
            elif f3 == 4:
                f2 = (c >> 10) & 3
                sh = (bit(12) << 5) | ((c >> 2) & 31)
                if f2 in (0, 1):
                    if not rv64 and bit(12):
                        raise Trap(ILLEGAL)
                    v = x[r1p]
                    self.wr(r1p, (self.s(v) >> sh) if f2 else (v >> sh), rec)
                elif f2 == 2:
                    self.wr(r1p, x[r1p] & (imm6 & self.mask), rec)
                else:
                    a, b = x[r1p], x[r2p]
                    sel = (bit(12) << 2) | ((c >> 5) & 3)
                    if sel == 0:
                        r = a - b
                    elif sel == 1:
                        r = a ^ b
                    elif sel == 2:
                        r = a | b
                    elif sel == 3:
                        r = a & b
                    elif sel == 4 and rv64:
                        r = sext((a - b) & 0xFFFFFFFF, 32)
                    elif sel == 5 and rv64:
                        r = sext((a + b) & 0xFFFFFFFF, 32)
                    else:
                        raise Trap(ILLEGAL)
                    self.wr(r1p, r, rec)
            elif f3 == 5:
                return self._target(rec.pc + self._cj(c))
            else:
                off = sext((bit(12) << 8) | (((c >> 10) & 3) << 3) | (((c >> 5) & 3) << 6) | (((c >> 3) & 3) << 1) | (bit(2) << 5), 9)
                z = x[r1p] == 0
                if z == (f3 == 6):
                    return self._target(rec.pc + off)
        elif q == 2:
            if f3 == 0:
                sh = (bit(12) << 5) | ((c >> 2) & 31)
                if not rv64 and bit(12):
                    raise Trap(ILLEGAL)
                need(rd); self.wr(rd, x[rd] << sh, rec)
            elif f3 == 2 or (f3 == 3 and rv64):
                if rd == 0:
                    raise Trap(ILLEGAL)
                need(rd)
                if f3 == 2:
                    off = (bit(12) << 5) | (((c >> 4) & 7) << 2) | (((c >> 2) & 3) << 6)
                    self.wr(rd, ld((x[2] + off) & self.mask, 4), rec)
                else:
                    off = (bit(12) << 5) | (((c >> 5) & 3) << 3) | (((c >> 2) & 7) << 6)
                    self.wr(rd, ld((x[2] + off) & self.mask, 8), rec)
            elif f3 == 4:
                if not bit(12):
                    if rs2 == 0:
                        if rd == 0:
                            raise Trap(ILLEGAL)
                        need(rd); return self._target(x[rd] & ~1)
                    need(rd, rs2); self.wr(rd, x[rs2], rec)
                else:
                    if rd == 0 and rs2 == 0:
                        raise Trap(BREAKPOINT, rec.pc)
                    if rs2 == 0:
                        need(rd)
                        t = x[rd] & ~1
                        self.wr(1, npc, rec)
                        return self._target(t)
                    need(rd, rs2); self.wr(rd, x[rd] + x[rs2], rec)
            elif f3 == 6 or (f3 == 7 and rv64):
                need(rs2)
                if f3 == 6:
                    off = (((c >> 9) & 0xF) << 2) | (((c >> 7) & 3) << 6)
                    st((x[2] + off) & self.mask, 4, x[rs2])
                else:
                    off = (((c >> 10) & 7) << 3) | (((c >> 7) & 7) << 6)
                    st((x[2] + off) & self.mask, 8, x[rs2])
            else:
                raise Trap(ILLEGAL)
        return npc

    def _cj(self, c):
        b = lambda i: (c >> i) & 1
        return sext((b(12) << 11) | (b(11) << 4) | (((c >> 9) & 3) << 8) | (b(8) << 10) | (b(7) << 6)
                    | (b(6) << 7) | (((c >> 3) & 7) << 1) | (b(2) << 5), 12)


def IRQ_BIT(n):
    return 1 << n


def load_elf(hart, path):
    """Load PT_LOAD segments of an ELF into the hart's memory; return the entry point."""
    import struct
    data = open(path, "rb").read()
    assert data[:4] == b"\x7fELF"
    is64 = data[4] == 2
    if is64:
        e_entry, e_phoff = struct.unpack_from("<QQ", data, 24)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    else:
        e_entry, e_phoff = struct.unpack_from("<II", data, 24)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if is64:
            p_type, _, p_offset, _, p_paddr, p_filesz, p_memsz = struct.unpack_from("<IIQQQQQ", data, off)
        else:
            p_type, p_offset, _, p_paddr, p_filesz, p_memsz = struct.unpack_from("<IIIIII", data, off)
        if p_type == 1 and p_memsz:
            hart.load_image(p_paddr, data[p_offset:p_offset + p_filesz] + bytes(p_memsz - p_filesz))
    return e_entry


def run(hart, max_steps=10_000_000, on_retire=None):
    """Run until the program writes TOHOST (or max_steps). Returns the tohost value."""
    for _ in range(max_steps):
        rec = hart.step()
        if on_retire:
            on_retire(rec)
        if hart.tohost is not None:
            return hart.tohost
    return None
