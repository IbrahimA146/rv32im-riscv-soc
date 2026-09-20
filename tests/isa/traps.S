/* traps.S - synchronous exceptions: cause, epc, tval, precision and recovery */
#include "test_macros.h"

/*
 * TEST_TRAP: run `insn`, which must trap with `cause`. Operands are set up
 * before the macro. The handler records mcause->x28, mepc->x29, mtval->x30
 * and resumes at x31.
 */
#define TEST_TRAP(n, cause, insn...)                                    \
test_ ## n:                                                             \
        li TESTNUM, n;                                                  \
        la x31, 3f;                                                     \
        li x28, -1;                                                     \
2:      insn;                                                           \
        j fail;                                                         \
3:      li x7, cause;                                                   \
        bne x28, x7, fail;                                              \
        la x7, 2b;                                                      \
        bne x29, x7, fail;

#define CHECK_TVAL(value)                                               \
        li x7, value;                                                   \
        bne x30, x7, fail;

RVTEST_CODE_BEGIN
  la t0, handler
  csrw mtvec, t0

  TEST_TRAP( 1, 11, ecall)
  CHECK_TVAL(0)

  TEST_TRAP( 2, 3, ebreak)
  bne x30, x29, fail                      /* tval = pc for ebreak */

  TEST_TRAP( 3, 2, .word 0x00000000)
  CHECK_TVAL(0)

  TEST_TRAP( 4, 2, .word 0xffffffff)
  CHECK_TVAL(0xffffffff)

  TEST_TRAP( 5, 2, .word 0x04001033)  /* OP with funct7=0000010 */
  CHECK_TVAL(0x04001033)

  TEST_TRAP( 6, 2, csrr x5, 0x7c0)    /* unimplemented CSR */

  TEST_TRAP( 7, 2, csrw mhartid, x0)  /* write to read-only CSR */

  TEST_TRAP( 8, 2, .word 0x00002063)  /* branch funct3=010 */

  /* access faults */
  li x5, 0x40000000
  TEST_TRAP(10, 5, lw x6, 0(x5))
  CHECK_TVAL(0x40000000)
  li x5, 0x40000010
  TEST_TRAP(11, 7, sw x6, 4(x5))
  CHECK_TVAL(0x40000014)

  /* address-misaligned loads / stores */
  li x5, 0x1001
  TEST_TRAP(12, 4, lw x6, 0(x5))
  CHECK_TVAL(0x1001)
  li x5, 0x1000
  TEST_TRAP(13, 6, sh x6, 3(x5))
  CHECK_TVAL(0x1003)

  /* misaligned jump target: trap on the jump, rd must not be written */
  li x6, 0x55
  la x5, 4f
  TEST_TRAP(14, 0, jalr x6, 2(x5))
  li x7, 0x55
  bne x6, x7, fail
4:

  /* precise: a store before the trap commits, instructions after do not */
  li TESTNUM, 15
  la x1, scratch
  li x12, 0
  la x31, 5f
  li x5, 0x1234
  sw x5, 0(x1)
  ecall
  li x12, 1
  sw x0, 0(x1)
5:
  bnez x12, fail
  lw x6, 0(x1)
  bne x5, x6, fail

  /* a trap in MEM aborts a divide already running in EX */
  li TESTNUM, 16
  li x5, 0x77
  li x6, 1000
  li x7, 7
  la x31, 6f
  ecall
  div x5, x6, x7
  j fail
6:
  li x8, 0x77
  bne x5, x8, fail
  div x5, x6, x7                          /* divider must still work */
  li x8, 142
  bne x5, x8, fail

  /* fetch from unmapped memory -> instruction access fault, epc = target */
  li TESTNUM, 17
  la x31, 7f
  li x5, 0x00100000
  jr x5
  j fail
7:
  li x7, 1
  bne x28, x7, fail
  li x7, 0x00100000
  bne x29, x7, fail
  bne x30, x7, fail

  /* mret restores MIE from MPIE and sets MPIE */
  li TESTNUM, 18
  csrw mstatus, x0
  li x31, 0
  la x31, 8f
  ecall
8:
  csrr x5, mstatus
  li x7, 0x1880
  bne x5, x7, fail

  TEST_PASSFAIL

  .align 2
handler:
  csrr x28, mcause
  csrr x29, mepc
  csrr x30, mtval
  csrw mepc, x31
  mret

RVTEST_CODE_END

  .data
scratch:
  .word 0
