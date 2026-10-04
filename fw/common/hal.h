/* hal.h - hardware abstraction layer for the RV32IM SoC */
#ifndef HAL_H
#define HAL_H

#include "soc.h"
#include "types.h"

/* ---- trap frame pushed by crt0.S trap_entry ----------------------------- */
typedef struct {
    uint32_t ra, t0, t1, t2;
    uint32_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint32_t t3, t4, t5, t6;
} trap_frame_t;

#define MCAUSE_IRQ          0x80000000u
#define CAUSE_ILLEGAL_INSN  2
#define CAUSE_BREAKPOINT    3
#define CAUSE_ECALL_M       11
#define IRQ_SOFT            3
#define IRQ_TIMER           7
#define IRQ_EXT             11

/* ---- CSR helpers (csr.S) ------------------------------------------------ */
uint32_t csr_read_mcycle(void);
uint32_t csr_read_minstret(void);
uint32_t csr_read_branches(void);
uint32_t csr_read_mispredicts(void);
uint32_t csr_read_misa(void);
uint32_t csr_read_mhartid(void);
void     irq_enable(void);
void     irq_disable(void);
void     irq_unmask(uint32_t mie_bits);
void     irq_mask(uint32_t mie_bits);

/* ---- trap dispatch (trap.c) --------------------------------------------- */
/* Handlers are weak; applications override the ones they need. */
void     handle_timer_irq(void);
void     handle_soft_irq(void);
void     handle_ext_irq(void);
/* Return true if the exception was handled; *resume may be updated. */
bool     handle_exception(uint32_t cause, uint32_t epc, uint32_t tval,
                          trap_frame_t *frame, uint32_t *resume);

extern volatile uint32_t irq_count_timer;
extern volatile uint32_t irq_count_ext;
extern volatile uint32_t irq_count_soft;

/* ---- UART (uart.c) ------------------------------------------------------ */
void     uart_init(void);
void     uart_putc(char c);
void     uart_puts(const char *s);
void     uart_flush(void);                   /* wait until the last bit is sent */
int      uart_getc(void);                    /* -1 if nothing received */
void     uart_isr(void);

/* ---- timer (timer.c) ---------------------------------------------------- */
void     timer_start(uint32_t period_ticks);
void     timer_stop(void);
uint32_t timer_ticks(void);
uint32_t mtime_read(void);
void     timer_isr(void);

/* ---- GPIO --------------------------------------------------------------- */
static inline void     gpio_write(uint32_t v) { REG32(GPIO_OUT) = v; }
static inline uint32_t gpio_read_out(void)    { return REG32(GPIO_OUT); }
static inline uint32_t gpio_read_in(void)     { return REG32(GPIO_IN); }
static inline void     gpio_set_oe(uint32_t v) { REG32(GPIO_OE) = v; }

/* ---- C library ----------------------------------------------------------- */
/* newlib provides malloc/printf/qsort/string/stdio; syscalls.c wires its
   primitives to this SoC. romfs_add() publishes a blob as a read-only file,
   which is how the DOOM WAD is served without a block device. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void romfs_add(const char *name, const void *data, size_t size);

#endif
