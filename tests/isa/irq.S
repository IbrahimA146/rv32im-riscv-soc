/* irq.S - timer/software interrupts, vectored mode, precise interrupts under
 *         heavy pipeline activity, and hardware performance counters.
 *         (RTL-only: interrupt timing is not modelled by the ISS.) */
#include "test_macros.h"

#define WAIT_FOR_IRQ(count_reg, limit)                                  \
        li x24, limit;                                                  \
1:      bnez count_reg, 2f;                                             \
        addi x24, x24, -1;                                              \
        bnez x24, 1b;                                                   \
        j fail;                                                         \
2:

RVTEST_CODE_BEGIN
  la sp, _stack_top
  la t0, handler
  csrw mtvec, t0
  li x20, 0                           /* interrupt count          */
  li x25, 0                           /* timer period (0=one-shot) */

  /* 1: one-shot timer interrupt */
  li TESTNUM, 1
  li x5, CLINT_MTIME
  lw x6, 0(x5)
  addi x6, x6, 100
  li x5, CLINT_MTIMECMP
  sw x6, 0(x5)
  sw zero, 4(x5)
  li x5, MIE_MTIE
  csrw mie, x5
  csrsi mstatus, MSTATUS_MIE
  WAIT_FOR_IRQ(x20, 1000)
  li x7, 0x80000007
  bne x28, x7, fail
  li x7, 0x1880                       /* in handler: MIE=0, MPIE=1 */
  bne x22, x7, fail
  csrr x5, mstatus                    /* after mret: MIE restored */
  andi x5, x5, MSTATUS_MIE
  beqz x5, fail

  /* 2: software interrupt */
  li TESTNUM, 2
  li x20, 0
  li x5, MIE_MSIE
  csrw mie, x5
  li x5, CLINT_MSIP
  li x6, 1
  sw x6, 0(x5)
  WAIT_FOR_IRQ(x20, 100)
  li x7, 0x80000003
  bne x28, x7, fail

  /* 3: pending interrupt is held off while MIE=0, taken immediately after */
  li TESTNUM, 3
  csrci mstatus, MSTATUS_MIE
  li x20, 0
  li x5, CLINT_MSIP
  li x6, 1
  sw x6, 0(x5)
  li x24, 200
4:
  addi x24, x24, -1
  bnez x24, 4b
  bnez x20, fail
  csrsi mstatus, MSTATUS_MIE
  nop
  nop
  nop
  beqz x20, fail

  /* 4: vectored mode dispatches to base + 4*cause */
  li TESTNUM, 4
  csrci mstatus, MSTATUS_MIE
  la t0, vector_table
  ori t0, t0, 1
  csrw mtvec, t0
  li x21, 0
  li x20, 0
  li x5, CLINT_MSIP
  li x6, 1
  sw x6, 0(x5)
  csrsi mstatus, MSTATUS_MIE
  WAIT_FOR_IRQ(x20, 100)
  li x7, 0x3
  bne x21, x7, fail
  csrci mstatus, MSTATUS_MIE
  la t0, handler
  csrw mtvec, t0

  /* 5: precise interrupts: a workload mixing divides, loads, stores, calls and
   *    mispredicts produces the same checksum with a timer firing every 37
   *    cycles as it does with interrupts disabled. */
  li TESTNUM, 5
  csrci mstatus, MSTATUS_MIE
  call workload
  mv s1, a0
  li x20, 0
  li x25, 37
  li x5, CLINT_MTIME
  lw x6, 0(x5)
  addi x6, x6, 37
  li x5, CLINT_MTIMECMP
  sw x6, 0(x5)
  sw zero, 4(x5)
  li x5, MIE_MTIE
  csrw mie, x5
  csrsi mstatus, MSTATUS_MIE
  call workload
  csrci mstatus, MSTATUS_MIE
  bne a0, s1, fail
  li x7, 20                           /* the timer really did fire, a lot */
  bltu x20, x7, fail

  /* 6: minstret counts exactly the committed instructions */
  li TESTNUM, 6
  csrr x5, minstret
  nop
  nop
  csrr x6, minstret
  sub x7, x6, x5
  li x8, 3
  bne x7, x8, fail

  /* 7: mcycle >= minstret progress; branch counters move */
  li TESTNUM, 7
  csrr x5, mcycle
  csrr x6, mhpmcounter3
  li x9, 10
5:
  addi x9, x9, -1
  bnez x9, 5b
  csrr x7, mcycle
  csrr x8, mhpmcounter3
  sub x7, x7, x5
  li x10, 20
  bltu x7, x10, fail
  sub x8, x8, x6
  li x10, 10
  bltu x8, x10, fail

  /* 8: an interrupt landing on a CSR instruction must cancel its write.
   *    csrrw x5, mscratch, x5 swaps two values; it is not idempotent, so a
   *    write that leaked before the (re-executed) instruction breaks the chain. */
  li TESTNUM, 8
  csrw mscratch, x0
  li x10, 0
  li x20, 0
  li x25, 23
  li x5, CLINT_MTIME
  lw x6, 0(x5)
  addi x6, x6, 23
  li x5, CLINT_MTIMECMP
  sw x6, 0(x5)
  sw zero, 4(x5)
  li x5, MIE_MTIE
  csrw mie, x5
  csrsi mstatus, MSTATUS_MIE
  li x11, 3000
8:
  addi x10, x10, 1
  mv x5, x10
  csrrw x5, mscratch, x5
  addi x7, x10, -1
  bne x5, x7, fail
  addi x11, x11, -1
  bnez x11, 8b
  csrci mstatus, MSTATUS_MIE
  li x7, 100
  bltu x20, x7, fail

  /* 9: a trapping instruction is not counted by minstret */
  li TESTNUM, 9
  la t0, count_handler
  csrw mtvec, t0
  la x31, 9f
  csrr x12, minstret       /* counted: this csrr                        */
  ecall                    /* NOT counted: trapped                      */
9:
  csrr x13, minstret       /* counted: handler's csrw + mret -> delta 3 */
  la t0, handler
  csrw mtvec, t0
  sub x7, x13, x12
  li x8, 3
  bne x7, x8, fail

  TEST_PASSFAIL

  .align 2
count_handler:
  csrw mepc, x31
  mret

/* --------------------------------------------------------------------------
 * a0 = checksum of a pipeline-heavy loop. Uses only a0-a5, t1-t2, ra.
 * ------------------------------------------------------------------------ */
workload:
  addi sp, sp, -4
  sw ra, 0(sp)
  li a0, 0x1234
  li a1, 300
  la a2, work_buf
6:
  divu a3, a0, a1
  remu a4, a0, a1
  sw a3, 0(a2)
  lw a5, 0(a2)
  add a0, a0, a5
  xor a0, a0, a4
  andi t1, a1, 1
  beqz t1, 7f
  slli a0, a0, 3
  srli t2, a0, 29
  or a0, a0, t2
7:
  call mix
  addi a1, a1, -1
  bnez a1, 6b
  lw ra, 0(sp)
  addi sp, sp, 4
  ret

mix:
  mul t1, a0, a1
  mulhu t2, a0, a1
  add a0, t1, t2
  ret

/* -------------------------------------------------------------------------- */
  .align 2
handler:
  csrr x28, mcause
  csrr x22, mstatus
  addi x20, x20, 1
  li x27, 0x80000007
  beq x28, x27, h_timer
  li x27, 0x80000003
  beq x28, x27, h_soft
  j unexpected_trap
h_timer:
  bnez x25, h_timer_periodic
  li x27, CLINT_MTIMECMP
  li x26, -1
  sw x26, 0(x27)
  sw x26, 4(x27)
  mret
h_timer_periodic:
  li x27, CLINT_MTIME
  lw x26, 0(x27)
  add x26, x26, x25
  li x27, CLINT_MTIMECMP
  sw x26, 0(x27)
  sw zero, 4(x27)
  mret
h_soft:
  li x27, CLINT_MSIP
  sw zero, 0(x27)
  mret

  .align 2
vector_table:
  j unexpected_trap       /* 0 */
  j unexpected_trap       /* 1 */
  j unexpected_trap       /* 2 */
  j vt_soft               /* 3: machine software */
  j unexpected_trap
  j unexpected_trap
  j unexpected_trap
  j unexpected_trap       /* 7: machine timer */
vt_soft:
  li x21, 3
  j handler

RVTEST_CODE_END

  .data
  .align 2
work_buf:
  .word 0
