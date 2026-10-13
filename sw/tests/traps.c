// Exceptions, mret and CSRs. Each trap is caught by trap_entry below, which
// records mcause/mepc/mtval and skips the faulting instruction.
#include "rt.h"

volatile uint32_t g_cause, g_epc, g_tval, g_count;

#if __riscv_xlen == 64
#define RS "sd"
#define RL "ld"
#else
#define RS "sw"
#define RL "lw"
#endif

__asm__(
    ".section .text\n"
    ".globl trap_entry\n"
    ".align 2\n"
    "trap_entry:\n"
    "  addi sp, sp, -32\n"
    "  " RS " t0, 0(sp)\n  " RS " t1, 8(sp)\n  " RS " t2, 16(sp)\n"
    "  csrr t0, mcause\n  la t1, g_cause\n  sw t0, 0(t1)\n"
    "  csrr t0, mepc\n    la t1, g_epc\n    sw t0, 0(t1)\n"
    "  csrr t0, mtval\n   la t1, g_tval\n   sw t0, 0(t1)\n"
    "  la t1, g_count\n   lw t2, 0(t1)\n    addi t2, t2, 1\n  sw t2, 0(t1)\n"
    "  csrr t0, mepc\n    lhu t1, 0(t0)\n   andi t1, t1, 3\n  li t2, 3\n"
    "  addi t0, t0, 2\n   bne t1, t2, 1f\n  addi t0, t0, 2\n"
    "1: csrw mepc, t0\n"
    "  " RL " t0, 0(sp)\n  " RL " t1, 8(sp)\n  " RL " t2, 16(sp)\n  addi sp, sp, 32\n"
    "  mret\n");

#define EXPECT(cause_) do { CHECK(g_count == n + 1); CHECK(g_cause == (cause_)); n++; } while (0)

static volatile uint32_t word = 0x11223344;

int main(void) {
    uint32_t n = g_count;
    unsigned long here;

    __asm__ volatile("auipc %0, 0\n\tecall" : "=r"(here));
    EXPECT(11); CHECK(g_epc == (uint32_t)(here + 4));
    __asm__ volatile("ebreak");
    EXPECT(3);
    __asm__ volatile(".option push\n.option rvc\nc.ebreak\n.option pop");
    EXPECT(3);
#ifdef __riscv_32e
    __asm__ volatile(".4byte 0x00000833");                   // add x16, x0, x0: illegal on RV32E
    EXPECT(2); CHECK(g_tval == 0x00000833);
#else
    __asm__ volatile(".4byte 0x0000007f");                   // reserved opcode
    EXPECT(2); CHECK(g_tval == 0x0000007f);
#endif
    __asm__ volatile(".2byte 0x0000");                       // all-zero parcel is illegal
    EXPECT(2); CHECK(g_tval == 0);
    __asm__ volatile(".4byte 0xfff0007f");                   // unknown opcode
    EXPECT(2); CHECK(g_tval == 0xfff0007f);

    unsigned long v, a = (unsigned long)&word + 1;
    __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(a));
    EXPECT(4); CHECK(g_tval == (uint32_t)a);
    __asm__ volatile("sh zero, 0(%0)" :: "r"(a));
    EXPECT(6); CHECK(g_tval == (uint32_t)a);
    __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(0x30000000));
    EXPECT(5); CHECK(g_tval == 0x30000000);
    __asm__ volatile("sw zero, 0(%0)" :: "r"(0x00000100));   // flash is read-only
    EXPECT(7);
    __asm__ volatile("csrw mhartid, zero");                  // read-only CSR
    EXPECT(2);
    __asm__ volatile("csrr %0, 0x7c0" : "=r"(v));            // nonexistent CSR
    EXPECT(2);

    write_csr(mscratch, 0x5a5a1234);
    CHECK(read_csr(mscratch) == 0x5a5a1234);
    unsigned long old;
    __asm__ volatile("csrrw %0, mscratch, %1" : "=r"(old) : "r"(7));
    CHECK(old == 0x5a5a1234 && read_csr(mscratch) == 7);
    __asm__ volatile("csrrsi %0, mscratch, 8" : "=r"(old));
    CHECK(old == 7 && read_csr(mscratch) == 15);
    __asm__ volatile("csrrci %0, mscratch, 3" : "=r"(old));
    CHECK(read_csr(mscratch) == 12);
#if __riscv_xlen == 32
    CHECK((read_csr(misa) >> 30) == 1);                       // MXL = 32
#endif
#ifdef __riscv_32e
    CHECK(read_csr(misa) & (1 << 4));                         // E
#else
    CHECK(read_csr(misa) & (1 << 8));                         // I
#endif
    CHECK(read_csr(mhartid) == 0);
    uint32_t ms = read_csr(mstatus);
    CHECK(((ms >> 11) & 3) == 3);                             // MPP = M
    CHECK(word == 0x11223344);
    CHECK(g_count == 12);
    rt_puts("traps ok\n");
    return 0;
}
