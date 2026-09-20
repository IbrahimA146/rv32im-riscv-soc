/* uart.c - polled transmit, interrupt-driven receive with a ring buffer */
#include "hal.h"

#define RX_BUF_SIZE 64                      /* power of two */

static char              rx_buf[RX_BUF_SIZE];
static volatile uint32_t rx_head, rx_tail;  /* head: ISR writes, tail: reader */

void uart_init(void)
{
    rx_head = rx_tail = 0;
    REG32(UART_CTRL) = UART_CTRL_RXIE;
    irq_unmask(MIE_MEIE);
}

void uart_putc(char c)
{
    while (REG32(UART_STATUS) & UART_STATUS_TXFULL)
        ;
    REG32(UART_TXDATA) = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_flush(void)
{
    while (!(REG32(UART_STATUS) & UART_STATUS_TXIDLE))
        ;
}

void uart_isr(void)
{
    for (;;) {
        uint32_t v = REG32(UART_RXDATA);
        if (v & 0x80000000u)
            break;                          /* FIFO drained */
        uint32_t next = (rx_head + 1) & (RX_BUF_SIZE - 1);
        if (next != rx_tail) {              /* drop on overflow */
            rx_buf[rx_head] = (char)v;
            rx_head = next;
        }
    }
}

int uart_getc(void)
{
    if (rx_tail == rx_head)
        return -1;
    char c = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) & (RX_BUF_SIZE - 1);
    return (uint8_t)c;
}
