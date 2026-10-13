// Self-modifying code: run a function from PSRAM, patch its immediate,
// fence.i, run it again. Without a working fence.i the old code would run.
#include "rt.h"

typedef int (*fn_t)(void);
static uint16_t code[16] __attribute__((aligned(4)));

int main(void) {
    // li a0, 5 ; ret   (c.li a0,5 = 0x4515, c.jr ra = 0x8082)
    code[0] = 0x4515;
    code[1] = 0x8082;
    __asm__ volatile("fence.i" ::: "memory");
    fn_t f = (fn_t)(void *)code;
    CHECK(f() == 5);
    for (int i = 1; i <= 20; i++) {
        code[0] = 0x4501 | ((i & 31) << 2);        // c.li a0, i
        __asm__ volatile("fence.i" ::: "memory");
        CHECK(f() == (i & 31));
    }
    rt_puts("selfmod ok\n");
    return 0;
}
