/* CoreMark port for riscv-tt: mcycle as the clock, UART output through rt.h. */
#include "coremark.h"
#include "rt.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415, seed2_volatile = 0x3415, seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0, seed2_volatile = 0x0, seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8, seed2_volatile = 0x8, seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS, seed5_volatile = 0;

#define CLOCKS_PER_SEC 50000000u
static CORETIMETYPE start_time_val, stop_time_val;
static CORETIMETYPE now(void) { return read_csr(mcycle); }
void start_time(void) { start_time_val = now(); }
void stop_time(void) { stop_time_val = now(); }
CORE_TICKS get_time(void) { return stop_time_val - start_time_val; }
secs_ret time_in_secs(CORE_TICKS ticks) { return ticks / CLOCKS_PER_SEC; }

ee_u32 default_num_contexts = 1;
void portable_init(core_portable *p, int *argc, char *argv[]) { (void)argc; (void)argv; p->portable_id = 1; }
void portable_fini(core_portable *p) { p->portable_id = 0; }

/* Small printf: %d %u %x %s %c with optional width/zero padding (all CoreMark needs). */
#include <stdarg.h>
static void put_num(ee_u32 v, int base, int neg, int width, char pad) {
    char b[12];
    int n = 0;
    do { b[n++] = "0123456789abcdef"[v % base]; v /= base; } while (v);
    if (neg) b[n++] = '-';
    while (n < width) { rt_putc(pad); width--; }
    while (n) rt_putc(b[--n]);
}
int ee_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { rt_putc(*fmt); continue; }
        fmt++;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') fmt++;
        switch (*fmt) {
            case 'd': { int v = va_arg(ap, int); put_num(v < 0 ? -v : v, 10, v < 0, width, pad); break; }
            case 'u': put_num(va_arg(ap, unsigned), 10, 0, width, pad); break;
            case 'x': case 'X': put_num(va_arg(ap, unsigned), 16, 0, width, pad); break;
            case 's': { const char *s = va_arg(ap, const char *); rt_puts(s); break; }
            case 'c': rt_putc((char)va_arg(ap, int)); break;
            case 'f': (void)va_arg(ap, int); rt_puts("?"); break;
            default: rt_putc(*fmt); break;
        }
    }
    va_end(ap);
    return 0;
}
