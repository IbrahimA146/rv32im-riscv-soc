/* jumps.S - JAL / JALR link values, rd==rs1, bit-0 clearing, call/ret patterns */
#include "test_macros.h"

RVTEST_CODE_BEGIN

  /* 1: JAL writes pc+4 into rd */
  li TESTNUM, 1
  jal x4, target1
link1:
  nop
  j fail
target1:
  la x2, link1
  bne x2, x4, fail

  /* 2: JALR through a register */
  li TESTNUM, 2
  la x6, target2
  jalr x19, 0(x6)
link2:
  j fail
target2:
  la x2, link2
  bne x2, x19, fail

  /* 3: JALR with rd == rs1 (target uses the old value) */
  li TESTNUM, 3
  la x5, target3
  jalr x5, 0(x5)
link3:
  j fail
target3:
  la x2, link3
  bne x2, x5, fail

  /* 4: JALR clears bit 0 of the target */
  li TESTNUM, 4
  la x5, target4
  jalr x0, 1(x5)
  j fail
target4:

  /* 5: negative JALR offset */
  li TESTNUM, 5
  la x5, target5 + 8
  jalr x0, -8(x5)
  j fail
target5:

  /* 6: instructions after a taken JAL must be squashed */
  li TESTNUM, 6
  li x12, 0
  jal x0, 1f
  addi x12, x12, 1
  addi x12, x12, 1
  addi x12, x12, 1
1:
  bnez x12, fail

  /* 7: hot call/ret loop (BTB learns the return) */
  li TESTNUM, 7
  li x10, 0
  li x11, 50
2:
  call func_add3
  addi x11, x11, -1
  bnez x11, 2b
  li x7, 150
  bne x10, x7, fail

  /* 8: two call sites -> return target alternates (forces JALR mispredicts) */
  li TESTNUM, 8
  li x10, 0
  li x11, 20
3:
  call func_add3
  addi x10, x10, 1
  call func_add3
  addi x11, x11, -1
  bnez x11, 3b
  li x7, 140
  bne x10, x7, fail

  /* 9: JAL with rd=x0 does not write */
  li TESTNUM, 9
  jal x0, 4f
4:
  li x7, 0
  bne x0, x7, fail

  /* 10: link register used immediately (forwarding of pc+4) */
  li TESTNUM, 10
  jal x13, 5f
link10:
  j fail
5:
  addi x14, x13, 0
  la x7, link10
  bne x14, x7, fail

  TEST_PASSFAIL

func_add3:
  addi x10, x10, 3
  ret

RVTEST_CODE_END
