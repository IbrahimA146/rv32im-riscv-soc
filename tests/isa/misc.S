/* misc.S - LUI/AUIPC, FENCE/WFI as no-ops */
#include "test_macros.h"

RVTEST_CODE_BEGIN

  TEST_CASE( 1, x1, 0x00000000, lui x1, 0x00000)
  TEST_CASE( 2, x1, 0xfffff800, lui x1, 0xfffff; srai x1, x1, 1)
  TEST_CASE( 3, x1, 0x7ffff000, lui x1, 0x7ffff)
  TEST_CASE( 4, x1, 0x80000000, lui x1, 0x80000)
  TEST_CASE( 5, x0, 0x00000000, lui x0, 0x80000)

  TEST_CASE( 6, x13, 0x00001004, auipc x1, 0; auipc x2, 1; sub x13, x2, x1)
  TEST_CASE( 7, x13, 0xfffff004, auipc x1, 0; auipc x2, 0xfffff; sub x13, x2, x1)

  /* AUIPC gives the absolute pc */
  li TESTNUM, 8
1:
  auipc x5, 0
  la x6, 1b
  bne x5, x6, fail

  /* FENCE, FENCE.I and WFI are no-ops */
  TEST_CASE( 9, x14, 0x00000042, li x14, 0x42; fence; .word 0x0000100f; wfi)

  TEST_PASSFAIL

RVTEST_CODE_END
