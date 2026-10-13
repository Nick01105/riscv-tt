// Interrupts and counters: CLINT timer and software interrupts, direct and
// vectored mtvec, MIE masking, wfi, minstret / mcountinhibit.
#include "rt.h"

#define MIP_MSIP (1u << 3)
#define MIP_MTIP (1u << 7)
#define LIMIT 200000

volatile uint32_t n_tim, n_sw, n_other, last_vec, rearm;

static inline unsigned long csr_mcause(void) {
    unsigned long v;
    __asm__ volatile("csrr %0, mcause" : "=r"(v));
    return v;
}

static void timer_off(void) {
    MTIMECMP_HI = 0xFFFFFFFF;
    MTIMECMP_LO = 0xFFFFFFFF;
}

static void timer_in(uint32_t ticks) {
    uint32_t hi, lo;
    do {                                   // consistent 64-bit read of mtime
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (hi != MTIME_HI);
    uint32_t t = lo + ticks;
    MTIMECMP_HI = 0xFFFFFFFF;              // no spurious match while the halves change
    MTIMECMP_LO = t;
    MTIMECMP_HI = hi + (t < lo);
}

void __attribute__((interrupt("machine"), aligned(4))) trap_entry(void) {
    unsigned long c = csr_mcause();
    last_vec = read_csr(mscratch);
    if (!(read_csr(mstatus) & 0x80)) rt_exit(0x300);   // MPIE: interrupts were enabled when it hit
    if ((long)c < 0) {
        if ((c & 0xF) == 7) {
            n_tim++;
            rearm = 0;                       // section 7: the main loop re-arms
            timer_off();
        } else if ((c & 0xF) == 3) {
            n_sw++;
            CLINT_MSIP = 0;
        } else {
            n_other++;
        }
    } else {
        rt_exit(0x200 + (int)c);           // no exceptions expected
    }
}

// Vectored table: entry n jumps to trap_entry after tagging mscratch with n.
__asm__(
    ".section .text\n"
    ".align 6\n"
    ".option push\n.option norvc\n"     // entries must be 4 bytes
    "vec_table:\n"
    "  j trap_entry\n"                     // 0: exceptions
    "  j trap_entry\n  j trap_entry\n"
    "  j vec3\n"                           // 3: machine software
    "  j trap_entry\n  j trap_entry\n  j trap_entry\n"
    "  j vec7\n"                           // 7: machine timer
    "  j trap_entry\n  j trap_entry\n  j trap_entry\n  j trap_entry\n"
    "vec3: csrwi mscratch, 3\n  j trap_entry\n"
    "vec7: csrwi mscratch, 7\n  j trap_entry\n"
    ".option pop\n");
extern char vec_table[];

static int wait_for(volatile uint32_t *p, uint32_t v) {
    for (int i = 0; i < LIMIT; i++) {
        if (*p == v) return 1;
    }
    return 0;
}

int main(void) {
    timer_off();
    write_csr(mscratch, 0);

    // 1. timer interrupt, direct mode
    write_csr(mie, MIP_MTIP);
    timer_in(300);
    __asm__ volatile("csrsi mstatus, 8");
    CHECK(wait_for(&n_tim, 1));
    CHECK(last_vec == 0);

    // 2. masked while MIE = 0, taken as soon as MIE is set again
    __asm__ volatile("csrci mstatus, 8");
    timer_in(1);
    for (int i = 0; i < LIMIT && !(read_csr(mip) & MIP_MTIP); i++) { }   // pending, but masked
    CHECK(read_csr(mip) & MIP_MTIP);
    for (volatile int i = 0; i < 50; i++) { }
    CHECK(n_tim == 1);
    __asm__ volatile("csrsi mstatus, 8");
    CHECK(wait_for(&n_tim, 2));

    // 3. software interrupt
    write_csr(mie, MIP_MTIP | MIP_MSIP);
    CLINT_MSIP = 1;
    CHECK(wait_for(&n_sw, 1));
    CHECK(!(read_csr(mip) & MIP_MSIP));

    // 4. wfi until the timer fires
    timer_in(200);
    while (n_tim < 3) __asm__ volatile("wfi");

    // 5. vectored mode
    write_csr(mtvec, (unsigned long)vec_table | 1);
    timer_in(100);
    CHECK(wait_for(&n_tim, 4));
    CHECK(last_vec == 7);
    CLINT_MSIP = 1;
    CHECK(wait_for(&n_sw, 2));
    CHECK(last_vec == 3);
    __asm__ volatile("csrci mstatus, 8");
    write_csr(mtvec, (unsigned long)trap_entry);

    // 7 (before 6, with mtvec direct). Interrupts never land where MIE is
    //    clear: toggle MIE with a timer firing every few dozen ticks.
    //    The main loop arms the timer with a delay that varies, so the
    //    interrupt arrives at every phase of the toggle sequence.
    write_csr(mie, MIP_MTIP);
    uint32_t t0 = n_tim;
#ifdef SPIKE
    const int iters = 20000;                                // Spike's mtime ticks every 100 instructions
#else
    const int iters = 400;
#endif
    for (int i = 0; i < iters; i++) {
        if (!rearm) {
            rearm = 1;
            timer_in(1 + (uint32_t)i % 29);
        }
        __asm__ volatile("csrsi mstatus, 8\n\tnop\n\tcsrci mstatus, 8\n\tnop\n\tnop\n\tnop");
    }
    timer_off();
    CHECK(n_tim - t0 >= 3);

    // 6. counters
    unsigned long a, b;
    __asm__ volatile("csrr %0, minstret\n\tnop\n\tnop\n\tcsrr %1, minstret" : "=r"(a), "=r"(b));
    CHECK(b - a == 3);
#ifndef SPIKE                                               // Spike ignores mcountinhibit.IR
    write_csr(mcountinhibit, 4);                            // stop minstret
    __asm__ volatile("csrr %0, minstret\n\tnop\n\tcsrr %1, minstret" : "=r"(a), "=r"(b));
    CHECK(a == b);
    write_csr(mcountinhibit, 0);
#endif
    a = read_csr(mcycle);
    b = read_csr(mcycle);
    CHECK(b != a);
    (void)read_csr(mhpmcounter3);
    (void)read_csr(mhpmcounter6);

    CHECK(n_other == 0);
    rt_puts("irq ok\n");
    return 0;
}
