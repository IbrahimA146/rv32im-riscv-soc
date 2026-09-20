/* ---------------------------------------------------------------------------
 * test_macros.h - self-checking ISA test framework
 *
 * Each test writes its number into TESTNUM (gp) before checking; on failure the
 * test number is written to SYSCON_EXIT, on success 0 is written. The testbench
 * turns that into PASS/FAIL. Every macro ends in a data-dependent branch, so the
 * same programs also exercise forwarding and branch prediction.
 * ------------------------------------------------------------------------- */
#ifndef TEST_MACROS_H
#define TEST_MACROS_H

#include "soc.h"

#define TESTNUM gp

#define RVTEST_CODE_BEGIN                                               \
        .section .text.start, "ax";                                     \
        .globl _start;                                                  \
_start:                                                                 \
        la t0, unexpected_trap;                                         \
        csrw mtvec, t0;                                                 \
        li TESTNUM, 0;

#define RVTEST_CODE_END                                                 \
pass:                                                                   \
        li t0, SYSCON_EXIT;                                             \
        sw zero, 0(t0);                                                 \
1:      j 1b;                                                           \
fail:                                                                   \
        li t0, SYSCON_EXIT;                                             \
        seqz t1, TESTNUM;                /* never report 0 on failure */\
        add TESTNUM, TESTNUM, t1;                                       \
        sw TESTNUM, 0(t0);                                              \
2:      j 2b;                                                           \
        .align 2;                                                       \
unexpected_trap:                                                        \
        li t0, SYSCON_EXIT;                                             \
        li TESTNUM, 0xDEAD;                                             \
        sw TESTNUM, 0(t0);                                              \
3:      j 3b;

#define TEST_CASE(n, reg, expected, code...)                            \
test_ ## n:                                                             \
        li TESTNUM, n;                                                  \
        code;                                                           \
        li x7, expected;                                                \
        bne reg, x7, fail;

/* --- register-register ops ---------------------------------------------- */
#define TEST_RR_OP(n, inst, result, val1, val2)                         \
        TEST_CASE(n, x14, result,                                       \
          li x1, val1;                                                  \
          li x2, val2;                                                  \
          inst x14, x1, x2 )

#define TEST_RR_SRC1_EQ_DEST(n, inst, result, val1, val2)               \
        TEST_CASE(n, x1, result,                                        \
          li x1, val1;                                                  \
          li x2, val2;                                                  \
          inst x1, x1, x2 )

#define TEST_RR_SRC12_EQ_DEST(n, inst, result, val1)                    \
        TEST_CASE(n, x1, result,                                        \
          li x1, val1;                                                  \
          inst x1, x1, x1 )

#define TEST_RR_ZERODEST(n, inst, val1, val2)                           \
        TEST_CASE(n, x0, 0,                                             \
          li x1, val1;                                                  \
          li x2, val2;                                                  \
          inst x0, x1, x2 )

/* result used 0/1/2 instructions later -> MEM/WB/regfile forwarding paths */
#define TEST_RR_DEST_BYPASS(n, nop_cycles, inst, result, val1, val2)    \
        TEST_CASE(n, x6, result,                                        \
          li x4, 0;                                                     \
1:        li x1, val1;                                                  \
          li x2, val2;                                                  \
          inst x14, x1, x2;                                             \
          .rept nop_cycles; nop; .endr;                                 \
          addi x6, x14, 0;                                              \
          addi x4, x4, 1;                                               \
          li x5, 2;                                                     \
          bne x4, x5, 1b )

/* operands produced 0/1/2 instructions earlier */
#define TEST_RR_SRC_BYPASS(n, nop1, nop2, inst, result, val1, val2)     \
        TEST_CASE(n, x14, result,                                       \
          li x4, 0;                                                     \
1:        li x1, val1;                                                  \
          .rept nop1; nop; .endr;                                       \
          li x2, val2;                                                  \
          .rept nop2; nop; .endr;                                       \
          inst x14, x1, x2;                                             \
          addi x4, x4, 1;                                               \
          li x5, 2;                                                     \
          bne x4, x5, 1b )

/* --- register-immediate ops --------------------------------------------- */
#define TEST_IMM_OP(n, inst, result, val1, imm)                         \
        TEST_CASE(n, x14, result,                                       \
          li x1, val1;                                                  \
          inst x14, x1, imm )

#define TEST_IMM_SRC1_EQ_DEST(n, inst, result, val1, imm)               \
        TEST_CASE(n, x1, result,                                        \
          li x1, val1;                                                  \
          inst x1, x1, imm )

#define TEST_IMM_DEST_BYPASS(n, nop_cycles, inst, result, val1, imm)    \
        TEST_CASE(n, x6, result,                                        \
          li x4, 0;                                                     \
1:        li x1, val1;                                                  \
          inst x14, x1, imm;                                            \
          .rept nop_cycles; nop; .endr;                                 \
          addi x6, x14, 0;                                              \
          addi x4, x4, 1;                                               \
          li x5, 2;                                                     \
          bne x4, x5, 1b )

/* --- branches ----------------------------------------------------------- */
#define TEST_BR2_TAKEN(n, inst, val1, val2)                             \
test_ ## n:                                                             \
        li TESTNUM, n;                                                  \
        li x1, val1;                                                    \
        li x2, val2;                                                    \
        inst x1, x2, 2f;                                                \
        bne x0, TESTNUM, fail;                                          \
1:      bne x0, TESTNUM, 3f;                                            \
2:      inst x1, x2, 1b;                                                \
        bne x0, TESTNUM, fail;                                          \
3:

#define TEST_BR2_NOTTAKEN(n, inst, val1, val2)                          \
test_ ## n:                                                             \
        li TESTNUM, n;                                                  \
        li x1, val1;                                                    \
        li x2, val2;                                                    \
        inst x1, x2, 1f;                                                \
        bne x0, TESTNUM, 2f;                                            \
1:      bne x0, TESTNUM, fail;                                          \
2:      inst x1, x2, 1b;                                                \
3:

#define TEST_PASSFAIL                                                   \
        bne x0, TESTNUM, pass;                                          \
        j fail;

#endif
