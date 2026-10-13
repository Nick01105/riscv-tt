#!/usr/bin/env python3
"""Generate decode test vectors with GNU binutils as the encoding oracle.

The script only chooses operands. Every instruction encoding comes from
riscv64-unknown-elf-as/ld, so the vectors are independent of the RTL.

Outputs (checked in, so tests do not need the toolchain):
  test/vectors/rvc_rv32.json, rvc_rv64.json : [compressed16, expanded32] pairs
  test/vectors/imm_rv32.json, imm_rv64.json : [instr32, expected_imm, fmt] triples
  test/vectors/dec_rv32.json, dec_rv64.json, dec_rv32e.json (x0-x15 only) : [instr32, {fields}, asm]
  test/vectors/legal_rv32.json, legal_rv64.json : [instr32, objdump mnemonic or null, operands]

Usage: python3 scripts/gen_vectors.py [--seed N] [--per-class N]
"""
import argparse
import json
import random
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test" / "vectors"
AS, LD, OBJCOPY = "riscv64-unknown-elf-as", "riscv64-unknown-elf-ld", "riscv64-unknown-elf-objcopy"
TEXT_BASE = 0x40000000

GPR = list(range(1, 32))
CREG = list(range(8, 16))            # x8..x15, encodable in 3 bits


def assemble(lines, xlen):
    """Assemble and link `lines`; return the raw .text bytes."""
    march = "rv32ic_zicsr" if xlen == 32 else "rv64ic_zicsr"
    mabi = "ilp32" if xlen == 32 else "lp64"
    emul = "elf32lriscv" if xlen == 32 else "elf64lriscv"
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "a.s").write_text(".option norelax\n.globl _start\n_start:\n" + "\n".join(lines) + "\n")
        subprocess.run([AS, f"-march={march}", f"-mabi={mabi}", "-o", d / "a.o", d / "a.s"], check=True)
        subprocess.run([LD, "-m", emul, "--no-relax", f"-Ttext=0x{TEXT_BASE:x}", "-o", d / "a.elf", d / "a.o"],
                       check=True)
        subprocess.run([OBJCOPY, "-O", "binary", "-j", ".text", d / "a.elf", d / "a.bin"], check=True)
        return (d / "a.bin").read_bytes()


# ---------------------------------------------------------------------------
# Compressed instruction pairs: (compressed asm, expanded asm). Branch and jump
# targets are written relative to a per-pair label so both forms encode the
# same offset.
# ---------------------------------------------------------------------------

def rvc_pairs(xlen, r, n):
    rv64 = xlen == 64
    x = lambda i: f"x{i}"
    pairs = []

    def add(cls, gen):
        for _ in range(n):
            pairs.append((cls, *gen()))

    def nz(lo, hi):
        v = 0
        while v == 0:
            v = r.randint(lo, hi)
        return v

    add("c.addi4spn", lambda: (lambda rd, imm: (f"c.addi4spn {x(rd)}, x2, {imm}", f"addi {x(rd)}, x2, {imm}"))(
        r.choice(CREG), 4 * r.randint(1, 255)))
    add("c.lw", lambda: (lambda rd, rs, o: (f"c.lw {x(rd)}, {o}({x(rs)})", f"lw {x(rd)}, {o}({x(rs)})"))(
        r.choice(CREG), r.choice(CREG), 4 * r.randint(0, 31)))
    add("c.sw", lambda: (lambda a, b, o: (f"c.sw {x(a)}, {o}({x(b)})", f"sw {x(a)}, {o}({x(b)})"))(
        r.choice(CREG), r.choice(CREG), 4 * r.randint(0, 31)))
    pairs.append(("c.nop", "c.nop", "addi x0, x0, 0"))
    add("c.addi", lambda: (lambda rd, imm: (f"c.addi {x(rd)}, {imm}", f"addi {x(rd)}, {x(rd)}, {imm}"))(
        r.choice(GPR), nz(-32, 31)))
    add("c.li", lambda: (lambda rd, imm: (f"c.li {x(rd)}, {imm}", f"addi {x(rd)}, x0, {imm}"))(
        r.choice(GPR), r.randint(-32, 31)))
    add("c.addi16sp", lambda: (lambda imm: (f"c.addi16sp x2, {imm}", f"addi x2, x2, {imm}"))(
        16 * nz(-32, 31)))

    def lui():
        rd = r.choice([g for g in GPR if g != 2])
        v = r.choice([r.randint(1, 31), r.randint(0xFFFE0, 0xFFFFF)])
        return f"c.lui {x(rd)}, {v:#x}", f"lui {x(rd)}, {v:#x}"
    add("c.lui", lui)

    shmax = 63 if rv64 else 31
    for op in ("srli", "srai"):
        add(f"c.{op}", lambda op=op: (lambda rd, s: (f"c.{op} {x(rd)}, {s}", f"{op} {x(rd)}, {x(rd)}, {s}"))(
            r.choice(CREG), r.randint(1, shmax)))
    add("c.andi", lambda: (lambda rd, imm: (f"c.andi {x(rd)}, {imm}", f"andi {x(rd)}, {x(rd)}, {imm}"))(
        r.choice(CREG), r.randint(-32, 31)))
    for op in ("sub", "xor", "or", "and"):
        add(f"c.{op}", lambda op=op: (lambda a, b: (f"c.{op} {x(a)}, {x(b)}", f"{op} {x(a)}, {x(a)}, {x(b)}"))(
            r.choice(CREG), r.choice(CREG)))

    def jump(link):
        def g():
            off = 2 * r.randint(-1024, 1023)
            k = len(pairs) * 4 + r.randint(0, 1 << 20)
            cm = "c.jal" if link else "c.j"
            rd = "x1" if link else "x0"
            return (f"C{k}: {cm} C{k}+{off}", f"E{k}: jal {rd}, E{k}+{off}")
        return g
    add("c.j", jump(False))
    if not rv64:
        add("c.jal", jump(True))

    for op, base in (("beqz", "beq"), ("bnez", "bne")):
        def br(op=op, base=base):
            off = 2 * r.randint(-128, 127)
            rs = r.choice(CREG)
            k = len(pairs) * 4 + r.randint(0, 1 << 20)
            return (f"C{k}: c.{op} {x(rs)}, C{k}+{off}", f"E{k}: {base} {x(rs)}, x0, E{k}+{off}")
        add(f"c.{op}", br)

    add("c.slli", lambda: (lambda rd, s: (f"c.slli {x(rd)}, {s}", f"slli {x(rd)}, {x(rd)}, {s}"))(
        r.choice(GPR), r.randint(1, shmax)))
    add("c.lwsp", lambda: (lambda rd, o: (f"c.lwsp {x(rd)}, {o}(x2)", f"lw {x(rd)}, {o}(x2)"))(
        r.choice(GPR), 4 * r.randint(0, 63)))
    add("c.swsp", lambda: (lambda rs, o: (f"c.swsp {x(rs)}, {o}(x2)", f"sw {x(rs)}, {o}(x2)"))(
        r.choice(range(0, 32)), 4 * r.randint(0, 63)))
    add("c.jr", lambda: (lambda rs: (f"c.jr {x(rs)}", f"jalr x0, 0({x(rs)})"))(r.choice(GPR)))
    add("c.jalr", lambda: (lambda rs: (f"c.jalr {x(rs)}", f"jalr x1, 0({x(rs)})"))(r.choice(GPR)))
    add("c.mv", lambda: (lambda rd, rs: (f"c.mv {x(rd)}, {x(rs)}", f"add {x(rd)}, x0, {x(rs)}"))(
        r.choice(GPR), r.choice(GPR)))
    add("c.add", lambda: (lambda rd, rs: (f"c.add {x(rd)}, {x(rs)}", f"add {x(rd)}, {x(rd)}, {x(rs)}"))(
        r.choice(GPR), r.choice(GPR)))
    pairs.append(("c.ebreak", "c.ebreak", "ebreak"))

    if rv64:
        add("c.ld", lambda: (lambda rd, rs, o: (f"c.ld {x(rd)}, {o}({x(rs)})", f"ld {x(rd)}, {o}({x(rs)})"))(
            r.choice(CREG), r.choice(CREG), 8 * r.randint(0, 31)))
        add("c.sd", lambda: (lambda a, b, o: (f"c.sd {x(a)}, {o}({x(b)})", f"sd {x(a)}, {o}({x(b)})"))(
            r.choice(CREG), r.choice(CREG), 8 * r.randint(0, 31)))
        add("c.addiw", lambda: (lambda rd, imm: (f"c.addiw {x(rd)}, {imm}", f"addiw {x(rd)}, {x(rd)}, {imm}"))(
            r.choice(GPR), r.randint(-32, 31)))
        for op in ("subw", "addw"):
            add(f"c.{op}", lambda op=op: (lambda a, b: (f"c.{op} {x(a)}, {x(b)}", f"{op} {x(a)}, {x(a)}, {x(b)}"))(
                r.choice(CREG), r.choice(CREG)))
        add("c.ldsp", lambda: (lambda rd, o: (f"c.ldsp {x(rd)}, {o}(x2)", f"ld {x(rd)}, {o}(x2)"))(
            r.choice(GPR), 8 * r.randint(0, 63)))
        add("c.sdsp", lambda: (lambda rs, o: (f"c.sdsp {x(rs)}, {o}(x2)", f"sd {x(rs)}, {o}(x2)"))(
            r.choice(range(0, 32)), 8 * r.randint(0, 63)))
    return pairs


def build_rvc(xlen, r, n):
    pairs = rvc_pairs(xlen, r, n)
    lines = []
    for _, c, e in pairs:
        lines += [".option rvc", c, ".option norvc", e]
    blob = assemble(lines, xlen)
    out, pos = [], 0
    for cls, c, e in pairs:
        c16 = int.from_bytes(blob[pos:pos + 2], "little")
        e32 = int.from_bytes(blob[pos + 2:pos + 6], "little")
        assert c16 & 3 != 3, f"{c} did not assemble to 16 bits"
        assert e32 & 3 == 3, f"{e} did not assemble to 32 bits"
        out.append([c16, e32, cls])
        pos += 6
    assert pos == len(blob), "unexpected extra bytes"
    return out


# ---------------------------------------------------------------------------
# Immediate vectors
# ---------------------------------------------------------------------------

FMT = {"I": 1, "S": 2, "B": 3, "U": 4, "J": 5}


def build_imm(xlen, r, n):
    rv64 = xlen == 64
    sx = lambda v, bits: v - (1 << bits) if v >> (bits - 1) else v
    items = []                                   # (asm, expected_imm, fmt)
    regs = lambda: (r.randint(0, 31), r.randint(0, 31))
    for _ in range(n):
        a, b = regs()
        i12 = r.randint(-2048, 2047)
        for m in ("addi", "slti", "sltiu", "xori", "ori", "andi"):
            items.append((f"{m} x{a}, x{b}, {i12}", i12, "I"))
        for m in ("lb", "lh", "lw", "lbu", "lhu") + (("ld", "lwu") if rv64 else ()):
            items.append((f"{m} x{a}, {i12}(x{b})", i12, "I"))
        items.append((f"jalr x{a}, {i12}(x{b})", i12, "I"))
        csr = r.randint(0, 4095)
        items.append((f"csrrw x{a}, {csr:#x}, x{b}", sx(csr, 12), "I"))
        for m in ("sb", "sh", "sw") + (("sd",) if rv64 else ()):
            items.append((f"{m} x{a}, {i12}(x{b})", i12, "S"))
        u20 = r.randint(0, 0xFFFFF)
        items.append((f"lui x{a}, {u20:#x}", sx(u20 << 12, 32), "U"))
        items.append((f"auipc x{a}, {u20:#x}", sx(u20 << 12, 32), "U"))
        k = len(items)
        boff = 2 * r.randint(-2048, 2047)
        for m in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            k += 1
            items.append((f"B{k}: {m} x{a}, x{b}, B{k}+{boff}", boff, "B"))
        joff = 2 * r.randint(-(1 << 19), (1 << 19) - 1)
        items.append((f"J{k}: jal x{a}, J{k}+{joff}", joff, "J"))
        if rv64:
            items.append((f"addiw x{a}, x{b}, {i12}", i12, "I"))
            items.append((f"slli x{a}, x{b}, {r.randint(0, 63)}", None, "I"))
    lines = [".option norvc"] + [asm for asm, _, _ in items]
    blob = assemble(lines, xlen)
    assert len(blob) == 4 * len(items)
    out = []
    for i, (asm, imm, fmt) in enumerate(items):
        word = int.from_bytes(blob[4 * i:4 * i + 4], "little")
        if imm is None:                          # shifts: the I-immediate is the raw 12-bit field
            imm = sx(word >> 20, 12)
        out.append([word, imm, FMT[fmt]])
    return out


# ---------------------------------------------------------------------------
# Decoder field vectors. Expected values use the enum names of frontend_pkg;
# the test resolves them to numbers by reading the package.
# ---------------------------------------------------------------------------

def build_decode(xlen, r, n, nregs=32):
    rv64 = xlen == 64
    sx = lambda v, bits: v - (1 << bits) if v >> (bits - 1) else v
    link = lambda x: x in (1, 5)
    items = []                    # (asm, fields)

    def reg():
        return r.choice([0, 1, 2, 5] + list(range(nregs)))

    def emit(asm, **f):
        items.append((asm, f))

    alu_r = [("add", "ALU_ADD", False), ("sub", "ALU_SUB", False), ("sll", "ALU_SLL", False),
             ("slt", "ALU_SLT", False), ("sltu", "ALU_SLTU", False), ("xor", "ALU_XOR", False),
             ("srl", "ALU_SRL", False), ("sra", "ALU_SRA", False), ("or", "ALU_OR", False),
             ("and", "ALU_AND", False)]
    if rv64:
        alu_r += [("addw", "ALU_ADD", True), ("subw", "ALU_SUB", True), ("sllw", "ALU_SLL", True),
                  ("srlw", "ALU_SRL", True), ("sraw", "ALU_SRA", True)]
    alu_i = [("addi", "ALU_ADD"), ("slti", "ALU_SLT"), ("sltiu", "ALU_SLTU"), ("xori", "ALU_XOR"),
             ("ori", "ALU_OR"), ("andi", "ALU_AND")]
    shifts = [("slli", "ALU_SLL", False), ("srli", "ALU_SRL", False), ("srai", "ALU_SRA", False)]
    if rv64:
        shifts += [("slliw", "ALU_SLL", True), ("srliw", "ALU_SRL", True), ("sraiw", "ALU_SRA", True)]
    muldiv = [("mul", 0), ("mulh", 1), ("mulhsu", 2), ("mulhu", 3), ("div", 4), ("divu", 5),
              ("rem", 6), ("remu", 7)]
    muldiv_w = [("mulw", 0), ("divw", 4), ("divuw", 5), ("remw", 6), ("remuw", 7)] if rv64 else []
    loads = [("lb", 0), ("lh", 1), ("lw", 2), ("lbu", 4), ("lhu", 5)] + ([("ld", 3), ("lwu", 6)] if rv64 else [])
    stores = [("sb", 0), ("sh", 1), ("sw", 2)] + ([("sd", 3)] if rv64 else [])
    branches = [("beq", 0), ("bne", 1), ("blt", 4), ("bge", 5), ("bltu", 6), ("bgeu", 7)]
    amos = [("amoswap", "LSU_AMOSWAP"), ("amoadd", "LSU_AMOADD"), ("amoxor", "LSU_AMOXOR"),
            ("amoand", "LSU_AMOAND"), ("amoor", "LSU_AMOOR"), ("amomin", "LSU_AMOMIN"),
            ("amomax", "LSU_AMOMAX"), ("amominu", "LSU_AMOMINU"), ("amomaxu", "LSU_AMOMAXU")]
    sizes = ["w"] + (["d"] if rv64 else [])
    shmax = 63 if rv64 else 31

    for _ in range(n):
        rd, a, b = reg(), reg(), reg()
        i12 = r.randint(-2048, 2047)
        for m, op, w in alu_r:
            emit(f"{m} x{rd}, x{a}, x{b}", fu="FU_ALU", op=op, rd_we=int(rd != 0), rs1_en=1, rs2_en=1,
                 use_imm=0, use_pc=0, word_op=int(w))
        for m, op in alu_i:
            emit(f"{m} x{rd}, x{a}, {i12}", fu="FU_ALU", op=op, rd_we=int(rd != 0), rs1_en=1, rs2_en=0,
                 use_imm=1, imm=i12, word_op=0)
        if rv64:
            emit(f"addiw x{rd}, x{a}, {i12}", fu="FU_ALU", op="ALU_ADD", rd_we=int(rd != 0), rs1_en=1,
                 use_imm=1, imm=i12, word_op=1)
        for m, op, w in shifts:
            sh = r.randint(0, 31 if w else shmax)
            emit(f"{m} x{rd}, x{a}, {sh}", fu="FU_ALU", op=op, rd_we=int(rd != 0), rs1_en=1, rs2_en=0,
                 use_imm=1, imm=sh, word_op=int(w))
        u20 = r.randint(0, 0xFFFFF)
        emit(f"lui x{rd}, {u20:#x}", fu="FU_ALU", op="ALU_PASSB", rd_we=int(rd != 0), rs1_en=0, rs2_en=0,
             use_imm=1, use_pc=0, imm=sx(u20 << 12, 32))
        emit(f"auipc x{rd}, {u20:#x}", fu="FU_ALU", op="ALU_ADD", rd_we=int(rd != 0), rs1_en=0, rs2_en=0,
             use_imm=1, use_pc=1, imm=sx(u20 << 12, 32))
        for m, f3 in muldiv:
            emit(f"{m} x{rd}, x{a}, x{b}", fu="FU_DIV" if f3 >= 4 else "FU_MUL", op=f3, f3=f3,
                 rd_we=int(rd != 0), rs1_en=1, rs2_en=1, word_op=0)
        for m, f3 in muldiv_w:
            emit(f"{m} x{rd}, x{a}, x{b}", fu="FU_DIV" if f3 >= 4 else "FU_MUL", op=f3, f3=f3,
                 rd_we=int(rd != 0), rs1_en=1, rs2_en=1, word_op=1)
        for m, f3 in loads:
            emit(f"{m} x{rd}, {i12}(x{a})", fu="FU_LSU", op="LSU_LOAD", f3=f3, rd_we=int(rd != 0),
                 rs1_en=1, rs2_en=0, use_imm=1, imm=i12)
        for m, f3 in stores:
            emit(f"{m} x{b}, {i12}(x{a})", fu="FU_LSU", op="LSU_STORE", f3=f3, rd_we=0,
                 rs1_en=1, rs2_en=1, use_imm=1, imm=i12)
        k = len(items)
        boff = 2 * r.randint(-2048, 2047)
        for m, f3 in branches:
            k += 1
            emit(f"D{k}: {m} x{a}, x{b}, D{k}+{boff}", fu="FU_BRU", op=f3, br_type="BR_COND",
                 rd_we=0, rs1_en=1, rs2_en=1, imm=boff)
        joff = 2 * r.randint(-(1 << 19), (1 << 19) - 1)
        k += 1
        emit(f"D{k}: jal x{rd}, D{k}+{joff}", fu="FU_BRU", op="BRU_JAL", rd_we=int(rd != 0), rs1_en=0,
             use_pc=1, imm=joff, br_type="BR_CALL" if link(rd) else "BR_JAL")
        bt = "BR_CALL" if link(rd) else ("BR_RET" if link(a) else "BR_JALR")
        emit(f"jalr x{rd}, {i12}(x{a})", fu="FU_BRU", op="BRU_JALR", rd_we=int(rd != 0), rs1_en=1,
             rs2_en=0, imm=i12, br_type=bt)
        for sz in sizes:
            f3 = 2 if sz == "w" else 3
            sfx = r.choice(["", ".aq", ".rl", ".aqrl"])
            emit(f"lr.{sz}{sfx} x{rd}, (x{a})", fu="FU_LSU", op="LSU_LR", f3=f3, rd_we=int(rd != 0),
                 rs1_en=1, rs2_en=0)
            emit(f"sc.{sz}{sfx} x{rd}, x{b}, (x{a})", fu="FU_LSU", op="LSU_SC", f3=f3, rd_we=int(rd != 0),
                 rs1_en=1, rs2_en=1)
            for m, op in amos:
                emit(f"{m}.{sz}{sfx} x{rd}, x{b}, (x{a})", fu="FU_LSU", op=op, f3=f3, rd_we=int(rd != 0),
                     rs1_en=1, rs2_en=1, imm=0)
        csr = r.randint(0, 4095)
        for m, f3 in (("csrrw", 1), ("csrrs", 2), ("csrrc", 3)):
            emit(f"{m} x{rd}, {csr:#x}, x{a}", fu="FU_CSR", op=f3, f3=f3, rd_we=int(rd != 0), rs1_en=1,
                 rs2_en=0, imm=csr, sys="SYS_NONE")
        z = r.randint(0, 31)
        for m, f3 in (("csrrwi", 5), ("csrrsi", 6), ("csrrci", 7)):
            emit(f"{m} x{rd}, {csr:#x}, {z}", fu="FU_CSR", op=f3, f3=f3, rd_we=int(rd != 0), rs1_en=0,
                 rs2_en=0, imm=csr, rs1=z)
    for asm, sysn in (("ecall", "SYS_ECALL"), ("ebreak", "SYS_EBREAK"), ("mret", "SYS_MRET"), ("wfi", "SYS_WFI")):
        emit(asm, fu="FU_CSR", sys=sysn, rd_we=0, rs1_en=0, rs2_en=0)
    for asm in ("fence", "fence rw, rw", "fence iorw, iorw", "fence w, r", "fence.tso", "pause"):
        emit(asm, fu="FU_NONE", sys="SYS_FENCE", rd_we=0, rs1_en=0, rs2_en=0)
    emit("fence.i", fu="FU_NONE", sys="SYS_FENCE_I", rd_we=0, rs1_en=0, rs2_en=0)

    march = ("rv32imac" if xlen == 32 else "rv64imac") + "_zicsr_zifencei_zihintpause"
    lines = [".option norvc"] + [a for a, _ in items]
    blob = assemble_arch(lines, xlen, march)
    assert len(blob) == 4 * len(items)
    out = []
    for i, (asm, f) in enumerate(items):
        word = int.from_bytes(blob[4 * i:4 * i + 4], "little")
        f = dict(f)
        f.setdefault("illegal", 0)
        f.setdefault("rd", (word >> 7) & 31)
        f.setdefault("rs1", (word >> 15) & 31)
        f.setdefault("rs2", (word >> 20) & 31)
        f.setdefault("br_type", "BR_NONE")
        f.setdefault("sys", "SYS_NONE")
        out.append([word, f, asm.split(":")[-1].strip()])
    return out


def assemble_arch(lines, xlen, march):
    mabi = "ilp32" if xlen == 32 else "lp64"
    emul = "elf32lriscv" if xlen == 32 else "elf64lriscv"
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "a.s").write_text(".option norelax\n.globl _start\n_start:\n" + "\n".join(lines) + "\n")
        subprocess.run([AS, f"-march={march}", f"-mabi={mabi}", "-o", d / "a.o", d / "a.s"], check=True)
        subprocess.run([LD, "-m", emul, "--no-relax", f"-Ttext=0x{TEXT_BASE:x}", "-o", d / "a.elf", d / "a.o"],
                       check=True)
        subprocess.run([OBJCOPY, "-O", "binary", "-j", ".text", d / "a.elf", d / "a.bin"], check=True)
        return (d / "a.bin").read_bytes()


# ---------------------------------------------------------------------------
# Legality oracle: random 32-bit words, disassembled by objdump with the
# exact ISA string in the ELF attributes. objdump prints ".insn" for words it
# does not recognise.
# ---------------------------------------------------------------------------

MAJOR_OPCODES = [0x03, 0x07, 0x0B, 0x0F, 0x13, 0x17, 0x1B, 0x23, 0x27, 0x2B, 0x2F, 0x33, 0x37, 0x3B,
                 0x43, 0x47, 0x4B, 0x4F, 0x53, 0x5B, 0x63, 0x67, 0x6B, 0x6F, 0x73, 0x77, 0x7B]
OBJDUMP = "riscv64-unknown-elf-objdump"


def build_legality(xlen, r, n):
    words = []
    for _ in range(n):
        op = r.choice(MAJOR_OPCODES + [0x13, 0x33, 0x3B, 0x1B, 0x2F, 0x73, 0x73, 0x0F, 0x63, 0x67, 0x03, 0x23])
        w = (r.getrandbits(25) << 7) | op
        # bias the funct7/funct5 field toward values that are legal somewhere
        if r.random() < 0.5:
            hi = r.choice([0x00, 0x20, 0x01, 0x02, 0x04, 0x08, 0x10, 0x0C, 0x14, 0x18, 0x1C, 0x30, 0x10, 0x18])
            w = (w & 0x01FFFFFF) | (hi << 25)
        if r.random() < 0.2:
            w = r.choice([0x00000073, 0x00100073, 0x30200073, 0x10500073, 0x10200073, 0x0000100F]) | \
                (r.choice([0, 0, 1 << 7, 1 << 15, 1 << 20]))
        words.append(w)
    march = ("rv32imac" if xlen == 32 else "rv64imac") + "_zicsr_zifencei"
    mabi = "ilp32" if xlen == 32 else "lp64"
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "a.s").write_text(".option norvc\n" + "".join(f".insn 4, {w:#010x}\n" for w in words))
        subprocess.run([AS, f"-march={march}", f"-mabi={mabi}", "-o", d / "a.o", d / "a.s"], check=True)
        dis = subprocess.run([OBJDUMP, "-d", "-M", "no-aliases,numeric", d / "a.o"],
                             capture_output=True, text=True, check=True).stdout
    out = []
    for line in dis.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0].strip().endswith(":") and parts[1].strip():
            word = int(parts[1].strip(), 16)
            mnem = parts[2].strip()
            ops = parts[3].strip() if len(parts) > 3 else ""
            out.append([word, None if mnem == ".insn" else mnem, ops])
    assert len(out) == len(words), (len(out), len(words))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--per-class", type=int, default=60)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for xlen in (32, 64):
        r = random.Random(args.seed + xlen)
        rvc = build_rvc(xlen, r, args.per_class)
        (OUT / f"rvc_rv{xlen}.json").write_text(json.dumps(rvc))
        imm = build_imm(xlen, r, args.per_class)
        (OUT / f"imm_rv{xlen}.json").write_text(json.dumps(imm))
        dec = build_decode(xlen, r, args.per_class // 3)
        (OUT / f"dec_rv{xlen}.json").write_text(json.dumps(dec))
        if xlen == 32:
            dec_e = build_decode(32, random.Random(args.seed + 7), args.per_class // 3, nregs=16)
            (OUT / "dec_rv32e.json").write_text(json.dumps(dec_e))
        legal = build_legality(xlen, r, 20000)
        (OUT / f"legal_rv{xlen}.json").write_text(json.dumps(legal))
        classes = sorted({c for _, _, c in rvc})
        mnems = sorted({a.split()[0] for _, _, a in dec})
        print(f"RV{xlen}: {len(rvc)} compressed pairs over {len(classes)} classes, {len(imm)} immediates, "
              f"{len(dec)} decode vectors over {len(mnems)} mnemonics, "
              f"{len(legal)} legality words ({sum(m is not None for _, m, _ in legal)} legal per objdump)")


if __name__ == "__main__":
    main()
