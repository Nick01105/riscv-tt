"""Branch traces from the reference ISS: conditional branches as
(block number, taken), where the block is the fetch block holding the
branch's last parcel (docs/spec.md, interface 1)."""
from rv_iss import Hart, load_elf, run


def branch_trace(elf, xlen=32, rve=True, fetch_bytes=4, pc_w=23, max_steps=5_000_000):
    h = Hart(xlen=xlen, rve=rve)
    h.pc = load_elf(h, elf)
    out, n = [], [0]
    off = (fetch_bytes - 1).bit_length()

    def rec(r):
        n[0] += 1
        if r.trap is not None:
            return
        size = 2 if r.insn & 3 != 3 else 4
        op = r.insn & 0x7F if size == 4 else None
        is_cond = (size == 4 and op == 0x63) or (size == 2 and (r.insn & 3) == 1 and (r.insn >> 13) in (6, 7))
        if is_cond:
            end = r.pc + size - 2
            out.append(((end >> off) & ((1 << pc_w) - 1), int(r.next_pc != r.pc + size)))
    code = run(h, max_steps, rec)
    assert code == 1, f"{elf}: program failed (tohost={code})"
    return out, n[0]
