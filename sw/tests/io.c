// UART receive and GPIO, for the chip-level test (test_soc.py), which sends
// "riscv\n" on UART RX and drives GPIO in. Not for Spike or the core test:
// it waits for input.
#include "rt.h"

static int getc_timeout(void) {
    for (int i = 0; i < 200000; i++) {
        if (UART_STATUS & 2) return (int)(UART_DATA & 0xFF);
    }
    return -1;
}

int main(void) {
    GPIO_OUT = 0x2A;
    uint32_t in = GPIO_IN;                  // test bench drives 0b101101
    CHECK(in == 0x2D);
    GPIO_OUT = in ^ 0x7F;                   // test bench checks uo_out
    const char *want = "riscv\n";
    for (int i = 0; want[i]; i++) {
        int c = getc_timeout();
        CHECK(c == want[i]);
        rt_putc(c >= 'a' && c <= 'z' ? (char)(c - 32) : (char)c);
    }
    CHECK(!(UART_STATUS & 2));              // nothing left
    CHECK(UART_DATA == 0);                  // empty receiver reads 0
    return 0;
}
