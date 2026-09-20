/* hazards.S - pipeline stress: stalls, forwarding corner cases, prediction, recursion */
#include "test_macros.h"

RVTEST_CODE_BEGIN
  la sp, _stack_top

  /* ---- divider stall with forwarding in and out ---- */
  TEST_CASE( 1, x5, 142, li x6, 1000; li x7, 7; div x5, x6, x7)
  TEST_CASE( 2, x9, 426, li x6, 1000; li x7, 7; div x5, x6, x7; add x8, x5, x5; add x9, x5, x8)
  TEST_CASE( 3, x8, 2,   li x6, 1000; li x7, 7; div x5, x6, x7; rem x8, x5, x7)
  TEST_CASE( 4, x5, 142, la x1, val1000; li x7, 7; lw x6, 0(x1); div x5, x6, x7)
  TEST_CASE( 5, x5, 20,  li x6, 1000; li x7, 7; div x5, x6, x7; divu x5, x5, x7)
  TEST_CASE( 6, x10, 0x8e, li x6, 1000; li x7, 7; div x5, x6, x7; sw x5, -8(sp); lw x10, -8(sp))

  /* divider result feeding a branch */
  li TESTNUM, 7
  li x6, 99
  li x7, 9
  li x8, 11
  divu x5, x6, x7
  bne x5, x8, fail

  /* ---- writes to x0 are never forwarded ---- */
  TEST_CASE( 8, x14, 0, li x5, 123; addi x0, x5, 1; add x14, x0, x0)
  TEST_CASE( 9, x14, 0, la x1, val1000; lw x0, 0(x1); add x14, x0, x0)

  /* ---- MEM stage wins over WB when both write the same register ---- */
  TEST_CASE(10, x14, 3, li x5, 1; li x5, 2; li x5, 3; addi x14, x5, 0)
  TEST_CASE(11, x14, 6, li x5, 1; addi x5, x5, 1; addi x5, x5, 1; add x14, x5, x5)

  /* ---- mispredict immediately followed by stall sources ---- */
  li TESTNUM, 12
  li x10, 0
  li x6, 1000
  li x7, 10
  la x1, val1000
  li x8, 0
  li x9, 5
1:
  beq x8, x9, 2f                       /* not taken 5x, then taken */
  div x5, x6, x7
  lw x11, 0(x1)
  add x10, x10, x5
  addi x8, x8, 1
  j 1b
2:
  li x7, 500
  bne x10, x7, fail

  /* ---- data-dependent branch pattern (predictor thrash) ---- */
  li TESTNUM, 13
  li x5, 0
  li x6, 0
  li x7, 200
3:
  andi x8, x5, 3
  beqz x8, 4f
  addi x6, x6, 1
4:
  addi x5, x5, 1
  bne x5, x7, 3b
  li x7, 150
  bne x6, x7, fail

  /* ---- recursion: fib(15) exercises call/ret, stack load/store ---- */
  li TESTNUM, 14
  li a0, 15
  call fib
  li x7, 610
  bne a0, x7, fail

  /* ---- nested loops ---- */
  li TESTNUM, 15
  li x10, 0
  li x5, 12
5:
  li x6, 13
6:
  add x10, x10, x6
  addi x6, x6, -1
  bnez x6, 6b
  addi x5, x5, -1
  bnez x5, 5b
  li x7, 1092                          /* 12 * (13*14/2) */
  bne x10, x7, fail

  TEST_PASSFAIL

/* int fib(int n) { return n < 2 ? n : fib(n-1) + fib(n-2); } */
fib:
  li t0, 2
  blt a0, t0, 9f
  addi sp, sp, -12
  sw ra, 8(sp)
  sw s0, 4(sp)
  sw s1, 0(sp)
  mv s0, a0
  addi a0, s0, -1
  call fib
  mv s1, a0
  addi a0, s0, -2
  call fib
  add a0, a0, s1
  lw s1, 0(sp)
  lw s0, 4(sp)
  lw ra, 8(sp)
  addi sp, sp, 12
9:
  ret

RVTEST_CODE_END

  .data
  .align 2
val1000:
  .word 1000
