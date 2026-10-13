// Firmware for the Tiny Tapeout CI test (test/test.py, RTL and gate level):
// a fast UART so the gate-level simulation stays short, a GPIO pattern, a
// message. Checks only what is visible on the pins.
#include "rt.h"

int main(void) {
#ifndef SPIKE                              // Spike has neither register
    UART_DIV = 3;                          // 4 cycles per bit
    GPIO_OUT = 0x55;
#endif
    volatile uint32_t x = 6;
    x = x * 7;                             // a multiply and a PSRAM round trip
    CHECK(x == 42);
    rt_puts("tt ok\n");
#ifndef SPIKE
    GPIO_OUT = 0x2A;
#endif
    return 0;
}
