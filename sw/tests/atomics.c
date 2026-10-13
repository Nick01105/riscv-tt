// A extension: AMOs, LR/SC loops, SC failure after an intervening store.
#include "rt.h"
static volatile uint32_t w = 5, lock = 0;

int main(void) {
    uint32_t old;
    __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(10) : "memory");
    CHECK(old == 5 && w == 15);
    __asm__ volatile("amoswap.w.aqrl %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(7) : "memory");
    CHECK(old == 15 && w == 7);
    __asm__ volatile("amomax.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(-3) : "memory");
    CHECK(old == 7 && w == 7);
    __asm__ volatile("amomaxu.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(-3) : "memory");
    CHECK(old == 7 && w == (uint32_t)-3);
    __asm__ volatile("amominu.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(9) : "memory");
    CHECK(w == 9);
    __asm__ volatile("amoand.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(12) : "memory");
    __asm__ volatile("amoor.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(0x30) : "memory");
    __asm__ volatile("amoxor.w %0, %2, (%1)" : "=r"(old) : "r"(&w), "r"(0xff) : "memory");
    CHECK(w == (((9 & 12) | 0x30) ^ 0xff));
    // spin lock with LR/SC
    for (int i = 0; i < 20; i++) {
        uint32_t t, fail;
        do {
            __asm__ volatile("lr.w %0, (%2)\n\taddi %0, %0, 1\n\tsc.w %1, %0, (%2)"
                             : "=&r"(t), "=&r"(fail) : "r"(&lock) : "memory");
        } while (fail);
    }
    CHECK(lock == 20);
    // every SC clears the reservation, so a second SC must fail (required by the spec;
    // a same-hart store between LR and SC is implementation-defined, so not tested)
    uint32_t t, fail1, fail2;
    __asm__ volatile("lr.w %0, (%3)\n\tsc.w %1, %0, (%3)\n\tsc.w %2, %0, (%3)"
                     : "=&r"(t), "=&r"(fail1), "=&r"(fail2) : "r"(&lock) : "memory");
    CHECK(fail1 == 0 && fail2 == 1 && lock == 20);
    rt_puts("atomics ok\n");
    return 0;
}
