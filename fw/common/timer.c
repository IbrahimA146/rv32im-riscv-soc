/* timer.c - periodic tick from the CLINT machine timer */
#include "hal.h"

static uint32_t          period;
static volatile uint32_t ticks;

uint32_t mtime_read(void)
{
    return REG32(CLINT_MTIME);
}

static void arm(uint32_t delta)
{
    uint32_t lo = REG32(CLINT_MTIME);
    uint32_t hi = REG32(CLINT_MTIMEH);
    uint32_t cmp = lo + delta;
    if (cmp < lo)
        hi++;
    REG32(CLINT_MTIMECMPH) = hi;
    REG32(CLINT_MTIMECMP)  = cmp;
}

void timer_start(uint32_t period_ticks)
{
    period = period_ticks;
    ticks = 0;
    arm(period);
    irq_unmask(MIE_MTIE);
}

void timer_stop(void)
{
    irq_mask(MIE_MTIE);
    REG32(CLINT_MTIMECMPH) = 0xffffffffu;
    REG32(CLINT_MTIMECMP)  = 0xffffffffu;
}

uint32_t timer_ticks(void)
{
    return ticks;
}

void timer_isr(void)
{
    ticks++;
    arm(period);
}
