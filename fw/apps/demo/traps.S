/* traps.S - helpers that deliberately enter the trap handler */

    .text

    /* uint32_t do_ecall(uint32_t a0, uint32_t a1, uint32_t nr) */
    .globl  do_ecall
do_ecall:
    mv      a7, a2
    ecall
    ret

    /* void do_illegal(void) - executes an all-ones word (illegal) */
    .globl  do_illegal
do_illegal:
    .word   0xffffffff
    ret
