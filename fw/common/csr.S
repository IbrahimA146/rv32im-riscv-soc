/* csr.S - tiny leaf functions for CSR access from C */

    .text

    .globl  csr_read_mcycle
csr_read_mcycle:
    csrr    a0, mcycle
    ret

    .globl  csr_read_minstret
csr_read_minstret:
    csrr    a0, minstret
    ret

    .globl  csr_read_branches
csr_read_branches:
    csrr    a0, mhpmcounter3
    ret

    .globl  csr_read_mispredicts
csr_read_mispredicts:
    csrr    a0, mhpmcounter4
    ret

    .globl  csr_read_misa
csr_read_misa:
    csrr    a0, misa
    ret

    .globl  csr_read_mhartid
csr_read_mhartid:
    csrr    a0, mhartid
    ret

    .globl  irq_enable
irq_enable:
    csrsi   mstatus, 8
    ret

    .globl  irq_disable
irq_disable:
    csrci   mstatus, 8
    ret

    /* void irq_unmask(uint32_t mie_bits) */
    .globl  irq_unmask
irq_unmask:
    csrs    mie, a0
    ret

    /* void irq_mask(uint32_t mie_bits) */
    .globl  irq_mask
irq_mask:
    csrc    mie, a0
    ret
