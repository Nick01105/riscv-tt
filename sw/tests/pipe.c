// Pipeline hazards, back to back: same-register writes, load-use on rs1 and
// rs2 (ALU, store data, branch compare, jalr base), mul/div-use, CSR-use.
// Each sequence runs several times so later passes come from the I-cache
// at full speed.
#include "rt.h"

static volatile uint32_t buf[4] = {5, 7, 0, 0};

static void (*volatile fp)(void);
static volatile uint32_t hits;
static void target(void) { hits++; }

int main(void) {
    for (int pass = 0; pass < 4; pass++) {
        unsigned long r, s, t;
        volatile uint32_t *p = buf;

        // three writes to one register, then a use of the youngest
        __asm__ volatile("li %0, 1\n\taddi %0, %0, 1\n\taddi %0, %0, 1\n\tadd %1, %0, %0"
                         : "=&r"(r), "=r"(s));
        CHECK(r == 3 && s == 6);

        // load-use: rs2 of an ALU op, rs1 of an ALU op
        __asm__ volatile("li %1, 100\n\tlw %0, 0(%2)\n\tsub %1, %1, %0" : "=&r"(r), "=&r"(s) : "r"(p));
        CHECK(s == 95);
        __asm__ volatile("lw %0, 4(%2)\n\taddi %1, %0, 1" : "=&r"(r), "=r"(s) : "r"(p));
        CHECK(s == 8);

        // load-use: store data (rs2) and store address (rs1)
        __asm__ volatile("lw %0, 0(%1)\n\tsw %0, 8(%1)" : "=&r"(r) : "r"(p) : "memory");
        CHECK(buf[2] == 5);
        unsigned long pp = (unsigned long)p;
        __asm__ volatile("sw %1, 12(%2)\n\tlw %0, 12(%2)\n\tsw %0, 12(%0)"
                         : "=&r"(r) : "r"(pp), "r"(p) : "memory");
        CHECK(buf[3] == (uint32_t)pp);       // written through the just-loaded address

        // load-use: branch compare on rs2 and on rs1
        __asm__ volatile("li %1, 7\n\tlw %0, 4(%2)\n\tbne %1, %0, 1f\n\tli %1, 0\n1:" : "=&r"(r), "=&r"(s) : "r"(p));
        CHECK(s == 0);
        __asm__ volatile("li %1, 5\n\tlw %0, 0(%2)\n\tbeq %0, %1, 1f\n\tli %1, 9\n1:" : "=&r"(r), "=&r"(s) : "r"(p));
        CHECK(s == 5);

        // load-use: jalr base
        fp = target;
        uint32_t h0 = hits;
        fp();
        CHECK(hits == h0 + 1);

        // multiply and divide results used at once (rs1 and rs2)
        __asm__ volatile("li %0, 6\n\tli %1, 7\n\tmul %2, %0, %1\n\tsub %2, %0, %2" : "=&r"(r), "=&r"(s), "=&r"(t));
        CHECK((long)t == 6 - 42);
        __asm__ volatile("li %0, 100\n\tli %1, 7\n\tdivu %2, %0, %1\n\tadd %2, %1, %2" : "=&r"(r), "=&r"(s), "=&r"(t));
        CHECK(t == 7 + 14);
        __asm__ volatile("li %0, 100\n\tli %1, 7\n\tremu %2, %0, %1\n\tmul %2, %2, %2" : "=&r"(r), "=&r"(s), "=&r"(t));
        CHECK(t == 4);

        // CSR read used at once
        __asm__ volatile("csrw mscratch, %2\n\tcsrr %0, mscratch\n\tadd %1, %2, %0"
                         : "=&r"(r), "=&r"(s) : "r"(21UL));
        CHECK(s == 42);

        // load followed by a load that uses it as the address
        volatile uint32_t *q = &buf[1];
        volatile uint32_t *volatile *qq = &q;
        __asm__ volatile(
#if __riscv_xlen == 64
            "ld %0, 0(%1)\n\tlw %0, 0(%0)"
#else
            "lw %0, 0(%1)\n\tlw %0, 0(%0)"
#endif
            : "=&r"(r) : "r"(qq));
        CHECK(r == 7);
    }
    rt_puts("pipe ok\n");
    return 0;
}
