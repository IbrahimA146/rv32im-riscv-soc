/* memory.S - all load/store widths, sign extension, offsets, store->load, load-use, MMIO */
#include "test_macros.h"

RVTEST_CODE_BEGIN

  /* ---- loads ---- */
  TEST_CASE( 1, x14, 0xffffffff, la x1, tdat; lb  x14, 0(x1))
  TEST_CASE( 2, x14, 0x00000000, la x1, tdat; lb  x14, 1(x1))
  TEST_CASE( 3, x14, 0xfffffff0, la x1, tdat; lb  x14, 2(x1))
  TEST_CASE( 4, x14, 0x0000000f, la x1, tdat; lb  x14, 3(x1))
  TEST_CASE( 5, x14, 0x000000ff, la x1, tdat; lbu x14, 0(x1))
  TEST_CASE( 6, x14, 0x000000f0, la x1, tdat; lbu x14, 2(x1))
  TEST_CASE( 7, x14, 0x000000ff, la x1, tdat; lh  x14, 4(x1))
  TEST_CASE( 8, x14, 0xffffff00, la x1, tdat; lh  x14, 8(x1))
  TEST_CASE( 9, x14, 0x0000ff00, la x1, tdat; lhu x14, 8(x1))
  TEST_CASE(10, x14, 0xffffff00, la x1, tdat; lh  x14, 10(x1))
  TEST_CASE(11, x14, 0x00ff00ff, la x1, tdat; lw  x14, 4(x1))
  TEST_CASE(12, x14, 0xff00ff00, la x1, tdat; lw  x14, 8(x1))
  TEST_CASE(13, x14, 0x0ff00ff0, la x1, tdat; lw  x14, 12(x1))
  TEST_CASE(14, x14, 0xf00ff00f, la x1, tdat; lw  x14, 16(x1))
  TEST_CASE(15, x14, 0x00ff00ff, la x1, tdat + 8; lw x14, -4(x1))
  TEST_CASE(16, x14, 0x0000000f, la x1, tdat + 8; lbu x14, -5(x1))

  /* ---- stores (read back whole word to check untouched bytes) ---- */
  TEST_CASE(20, x14, 0xaabbccdd, la x1, tdat2; li x2, 0xaabbccdd; sw x2, 0(x1); lw x14, 0(x1))
  TEST_CASE(21, x14, 0xdead78ef, la x1, tdat2; li x2, 0x12345678; sb x2, 5(x1); lw x14, 4(x1))
  TEST_CASE(22, x14, 0x9abcbeef, la x1, tdat2; li x2, 0x55559abc; sh x2, 10(x1); lw x14, 8(x1))
  TEST_CASE(23, x14, 0xdead9abc, la x1, tdat2; li x2, 0x9abc; sh x2, 12(x1); lw x14, 12(x1))
  TEST_CASE(24, x14, 0x11adbeef, la x1, tdat2; li x2, 0x11; sb x2, 19(x1); lw x14, 16(x1))
  TEST_CASE(25, x14, 0xffffffaa, la x1, tdat2 + 32; li x2, 0xaa; sb x2, -8(x1); lb x14, -8(x1))

  /* ---- load-use stalls ---- */
  TEST_CASE(30, x14, 0x00ff0100, la x1, tdat; lw x5, 4(x1); addi x14, x5, 1)
  TEST_CASE(31, x14, 0x00ff00ff, la x1, tdat; lw x5, 4(x1); sw x5, 0(x1); lw x14, 0(x1))
  TEST_CASE(32, x14, 0x01fe01fe, la x1, tdat; lw x5, 4(x1); add x14, x5, x5)
  TEST_CASE(33, x14, 0x00ff00ff, la x1, tdat; lw x5, 4(x1); lw x6, 4(x1); and x14, x5, x6)

  /* load-use into a branch */
  li TESTNUM, 34
  la x1, tdat
  li x6, 0x00ff00ff
  lw x5, 4(x1)
  bne x5, x6, fail

  /* load-use into JALR */
  li TESTNUM, 35
  la x1, jump_slot
  la x2, 2f
  sw x2, 0(x1)
  lw x5, 0(x1)
  jalr x0, 0(x5)
  j fail
2:

  /* ---- MMIO ---- */
  TEST_CASE(40, x14, 0x5a5a1234, li x1, GPIO_OUT; li x2, 0x5a5a1234; sw x2, 0(x1); lw x14, 0(x1))
  TEST_CASE(41, x14, 0xa5a50000, li x1, GPIO_IN; lw x14, 0(x1))
  TEST_CASE(42, x14, 0x000000a5, li x1, GPIO_IN; lbu x14, 3(x1))

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
  .align 2
tdat:
  .byte 0xff, 0x00, 0xf0, 0x0f
  .word 0x00ff00ff
  .word 0xff00ff00
  .word 0x0ff00ff0
  .word 0xf00ff00f
tdat2:
  .word 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef
  .word 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef
jump_slot:
  .word 0
