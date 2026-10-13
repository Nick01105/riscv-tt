# Startup for riscv-tt (RV32E: only x0-x15 exist).
    .section .text.init, "ax"
    .globl _start
_start:
    # The register file has no reset: give every register a defined value.
    li      x1, 0
    li      x2, 0
    li      x3, 0
    li      x4, 0
    li      x5, 0
    li      x6, 0
    li      x7, 0
    li      x8, 0
    li      x9, 0
    li      x10, 0
    li      x11, 0
    li      x12, 0
    li      x13, 0
    li      x14, 0
    li      x15, 0
#ifndef __riscv_32e
    li      x16, 0
    li      x17, 0
    li      x18, 0
    li      x19, 0
    li      x20, 0
    li      x21, 0
    li      x22, 0
    li      x23, 0
    li      x24, 0
    li      x25, 0
    li      x26, 0
    li      x27, 0
    li      x28, 0
    li      x29, 0
    li      x30, 0
    li      x31, 0
#endif
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    la      a0, __data_load
    la      a1, __data_start
    la      a2, __data_end
1:  bgeu    a1, a2, 2f
    lw      t0, 0(a0)
    sw      t0, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    j       1b
2:  la      a0, __bss_start
    la      a1, __bss_end
3:  bgeu    a0, a1, 4f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       3b
4:  la      t0, trap_entry
    csrw    mtvec, t0
    call    main
    tail    rt_exit

# Default trap handler: any unexpected trap ends the test as a failure with
# code 0x100 + mcause. Tests that expect traps override trap_entry.
    .weak   trap_entry
    .align  2
trap_entry:
    csrr    a0, mcause
    addi    a0, a0, 0x100
    tail    rt_exit
