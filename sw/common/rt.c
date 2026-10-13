#include "rt.h"

void rt_putc(char c) {
#ifdef SPIKE
    *(volatile uint8_t *)0x10000000 = (uint8_t)c;   /* Spike's ns16550 takes byte stores only */
#else
    while (!(UART_STATUS & 1)) { }
    UART_DATA = (uint8_t)c;
#endif
}

void rt_puts(const char *s) {
    while (*s) rt_putc(*s++);
}

void rt_puthex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) rt_putc("0123456789abcdef"[(v >> i) & 15]);
}

void rt_putdec(uint32_t v) {
    char b[11];
    int n = 0;
    do { b[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) rt_putc(b[--n]);
}

void rt_exit(int code) {
    extern volatile uint32_t tohost;
    tohost = ((uint32_t)code << 1) | 1;
    for (;;) { }
}
