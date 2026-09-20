/* trap.c - C-level trap dispatcher */
#include "hal.h"

volatile uint32_t irq_count_timer;
volatile uint32_t irq_count_ext;
volatile uint32_t irq_count_soft;

__attribute__((weak)) void handle_timer_irq(void) { timer_isr(); }
__attribute__((weak)) void handle_ext_irq(void)   { uart_isr(); }
__attribute__((weak)) void handle_soft_irq(void)  { REG32(CLINT_MSIP) = 0; }

__attribute__((weak))
bool handle_exception(uint32_t cause, uint32_t epc, uint32_t tval,
                      trap_frame_t *frame, uint32_t *resume)
{
    (void)cause; (void)epc; (void)tval; (void)frame; (void)resume;
    return false;
}

static const char *const cause_names[] = {
    "instruction address misaligned", "instruction access fault",
    "illegal instruction", "breakpoint", "load address misaligned",
    "load access fault", "store address misaligned", "store access fault",
    "", "", "", "environment call from M-mode",
};

uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval, trap_frame_t *frame)
{
    if (mcause & MCAUSE_IRQ) {
        switch (mcause & 0x1f) {
        case IRQ_TIMER: irq_count_timer++; handle_timer_irq(); break;
        case IRQ_EXT:   irq_count_ext++;   handle_ext_irq();   break;
        case IRQ_SOFT:  irq_count_soft++;  handle_soft_irq();  break;
        default: break;
        }
        return mepc;                     /* interrupted instruction re-executes */
    }

    uint32_t resume = mepc + 4;
    if (handle_exception(mcause, mepc, mtval, frame, &resume))
        return resume;

    printf("\n!!! unhandled exception: %s (mcause=%u) at pc=%08x tval=%08x\n",
           mcause < 12 ? cause_names[mcause] : "?", mcause, mepc, mtval);
    REG32(SYSCON_EXIT) = 0x100 | mcause;
    for (;;) {}
}
