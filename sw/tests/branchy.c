// Control-flow mix for the branch-predictor study: data-dependent branches,
// loops, recursion deeper than the RAS, switch tables, function pointers.
#include "rt.h"

static uint32_t lcg(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s; }
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int op_add(int a, int b) { return a + b; }
static int op_sub(int a, int b) { return a - b; }
static int op_xor(int a, int b) { return a ^ b; }
static int (*const ops[3])(int, int) = {op_add, op_sub, op_xor};

static int classify(uint32_t v) {
    switch (v & 7) {
        case 0: return 3;
        case 1: return 1;
        case 2: return 4;
        case 3: return 1;
        case 4: return 5;
        case 5: return 9;
        case 6: return 2;
        default: return 6;
    }
}

int main(void) {
    uint32_t s = 7, acc = 0;
    CHECK(fib(15) == 610);
    for (int i = 0; i < 400; i++) {
        uint32_t r = lcg(&s);
        if (r & 0x100) acc += classify(r);           // random: hard to predict
        if ((i & 3) == 0) acc ^= i;                  // periodic: learnable with history
        if (i % 7 == 3) acc += ops[i % 3](acc, i);   // indirect calls
        for (int k = 0; k < (i & 7); k++) acc += k;  // short variable loops
    }
    rt_puts("branchy ");
    rt_puthex(acc);
    rt_putc('\n');
    return 0;
}
