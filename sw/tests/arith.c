// M extension and ALU edge cases, checked two ways.
#include "rt.h"

static volatile int32_t vs[] = {0, 1, -1, 7, -7, 0x7fffffff, (int32_t)0x80000000, 12345, -98765, 3};

static uint32_t mul_slow(uint32_t a, uint32_t b) {
    uint32_t r = 0;
    for (int i = 0; i < 32; i++) if (b & (1u << i)) r += a << i;
    return r;
}

static uint32_t mulhu_slow(uint32_t a, uint32_t b) {
    uint32_t hi = 0, lo = 0;
    for (int i = 0; i < 32; i++) {
        if (b & (1u << i)) {
            uint32_t add_lo = a << i, add_hi = i ? a >> (32 - i) : 0;
            uint32_t nlo = lo + add_lo;
            hi += add_hi + (nlo < lo);
            lo = nlo;
        }
    }
    return hi;
}

int main(void) {
    int n = sizeof(vs) / sizeof(vs[0]);
    uint32_t acc = 0;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            int32_t a = vs[i], b = vs[j];
            uint32_t ua = (uint32_t)a, ub = (uint32_t)b;
            CHECK(ua * ub == mul_slow(ua, ub));
#if __riscv_xlen == 32
            uint32_t hu;
            __asm__ volatile("mulhu %0, %1, %2" : "=r"(hu) : "r"(ua), "r"(ub));
            CHECK(hu == mulhu_slow(ua, ub));
#else
            CHECK((uint32_t)(((uint64_t)ua * ub) >> 32) == mulhu_slow(ua, ub));
#endif
            if (b != 0) {
                if (!(a == (int32_t)0x80000000 && b == -1)) {
                    CHECK((a / b) * b + (a % b) == a);
                }
                CHECK((ua / ub) * ub + (ua % ub) == ua);
            }
            int32_t q, r;
            uint32_t qu, ru;
#if __riscv_xlen == 32
            __asm__ volatile("div %0, %1, %2" : "=r"(q) : "r"(a), "r"(b));
            __asm__ volatile("rem %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
            __asm__ volatile("divu %0, %1, %2" : "=r"(qu) : "r"(ua), "r"(ub));
            __asm__ volatile("remu %0, %1, %2" : "=r"(ru) : "r"(ua), "r"(ub));
#else
            __asm__ volatile("divw %0, %1, %2" : "=r"(q) : "r"(a), "r"(b));
            __asm__ volatile("remw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
            __asm__ volatile("divuw %0, %1, %2" : "=r"(qu) : "r"(ua), "r"(ub));
            __asm__ volatile("remuw %0, %1, %2" : "=r"(ru) : "r"(ua), "r"(ub));
#endif
            if (b == 0) {
                CHECK(q == -1 && r == a && qu == 0xffffffffu && ru == ua);
            } else if (a == (int32_t)0x80000000 && b == -1) {
                CHECK(q == a && r == 0);
            }
            acc += ua * 3 + (ua >> (j & 31)) + (uint32_t)(a >> (i & 31)) + (ua < ub) + (a < b);
        }
    }
    rt_puts("arith ok ");
    rt_puthex(acc);
    rt_putc('\n');
    return 0;
}
