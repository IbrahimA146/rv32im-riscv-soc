/* csr.S - Zicsr instruction semantics, WARL fields, CSR value forwarding */
#include "test_macros.h"

RVTEST_CODE_BEGIN

  TEST_CASE( 1, x14, 0x12345678, li x5, 0x12345678; csrw mscratch, x5; csrr x14, mscratch)

  /* CSRRW returns old value */
  TEST_CASE( 2, x14, 0x12345678, li x5, 0xcafebabe; csrrw x14, mscratch, x5)
  TEST_CASE( 3, x14, 0xcafebabe, csrr x14, mscratch)

  /* CSRRS / CSRRC */
  TEST_CASE( 4, x14, 0xcafebabe, li x5, 0x0000000f; csrrs x14, mscratch, x5)
  TEST_CASE( 5, x14, 0xcafebabf, csrr x14, mscratch)
  TEST_CASE( 6, x14, 0xcafebabf, li x5, 0xf0000000; csrrc x14, mscratch, x5)
  TEST_CASE( 7, x14, 0x0afebabf, csrr x14, mscratch)

  /* immediate forms */
  TEST_CASE( 8, x14, 0x0afebabf, csrrwi x14, mscratch, 0x1f)
  TEST_CASE( 9, x14, 0x0000001f, csrrci x14, mscratch, 0x03)
  TEST_CASE(10, x14, 0x0000001c, csrrsi x14, mscratch, 0x00)
  TEST_CASE(11, x14, 0x0000001c, csrrsi x14, mscratch, 0x01; csrr x14, mscratch; addi x14, x14, -1)

  /* read-only / identification CSRs */
  TEST_CASE(12, x14, 0x40001100, csrr x14, misa)
  TEST_CASE(13, x14, 0x00000000, csrr x14, mhartid)
  TEST_CASE(14, x14, 0x00001800, csrr x14, mstatus; li x5, 0x1800; and x14, x14, x5)

  /* WARL: mtvec bit 1 is hardwired to 0, mepc bits 1:0 are hardwired to 0 */
  TEST_CASE(15, x14, 0x00001101, li x5, 0x1103; csrrw x6, mtvec, x5; csrr x14, mtvec; csrw mtvec, x6)
  TEST_CASE(16, x14, 0x00002000, li x5, 0x2003; csrw mepc, x5; csrr x14, mepc)

  /* mstatus: only MIE/MPIE are writable */
  TEST_CASE(17, x14, 0x00001880, li x5, 0xffffff87; csrw mstatus, x5; csrr x14, mstatus)
  TEST_CASE(18, x14, 0x00001800, csrw mstatus, x0; csrr x14, mstatus)

  /* mie: only MSIE/MTIE/MEIE are writable */
  TEST_CASE(19, x14, 0x00000888, li x5, 0xffffffff; csrw mie, x5; csrr x14, mie; csrw mie, x0)

  /* forwarding: CSR read value used by the very next instruction (MEM->EX) */
  TEST_CASE(20, x14, 0x00000006, li x5, 5; csrw mscratch, x5; csrr x6, mscratch; addi x14, x6, 1)
  /* ...and two instructions later (WB->EX) */
  TEST_CASE(21, x14, 0x0000000a, csrr x6, mscratch; nop; add x14, x6, x6)
  /* CSR operand produced by the previous instruction */
  TEST_CASE(22, x14, 0x0000004d, li x5, 77; csrw mscratch, x5; csrr x14, mscratch)
  /* back-to-back CSR writes */
  TEST_CASE(23, x14, 0x00000003, csrwi mscratch, 1; csrsi mscratch, 2; csrr x14, mscratch)

  TEST_PASSFAIL

RVTEST_CODE_END
