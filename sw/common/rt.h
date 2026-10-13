// Minimal runtime for riscv-tt programs.
#ifndef RT_H
#define RT_H
#include <stdint.h>

#define MMIO32(a) (*(volatile uint32_t *)(a))
#define UART_DATA   MMIO32(0x10000000)
#define UART_STATUS MMIO32(0x10000004)
#define UART_DIV    MMIO32(0x10000008)
#define GPIO_OUT    MMIO32(0x10000100)
#define GPIO_IN     MMIO32(0x10000104)
#define CLINT_MSIP  MMIO32(0x02000000)
#define MTIMECMP_LO MMIO32(0x02004000)
#define MTIMECMP_HI MMIO32(0x02004004)
#define MTIME_LO    MMIO32(0x0200BFF8)
#define MTIME_HI    MMIO32(0x0200BFFC)

#define read_csr(r) ({ unsigned long v_; __asm__ volatile("csrr %0, " #r : "=r"(v_)); (uint32_t)v_; })
#define write_csr(r, v) __asm__ volatile("csrw " #r ", %0" :: "rK"(v))

void rt_putc(char c);
void rt_puts(const char *s);
void rt_puthex(uint32_t v);
void rt_putdec(uint32_t v);
void __attribute__((noreturn)) rt_exit(int code);   // 0 = pass
#define CHECK(c) do { if (!(c)) rt_exit(__LINE__); } while (0)
#endif
