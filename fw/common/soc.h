/* soc.h - memory map and register definitions (usable from C and assembly) */
#ifndef SOC_H
#define SOC_H

#define RAM_BASE          0x00000000
#define RAM_SIZE          0x00010000

#define CLINT_BASE        0x02000000
#define CLINT_MSIP        (CLINT_BASE + 0x0000)
#define CLINT_MTIMECMP    (CLINT_BASE + 0x4000)
#define CLINT_MTIMECMPH   (CLINT_BASE + 0x4004)
#define CLINT_MTIME       (CLINT_BASE + 0xBFF8)
#define CLINT_MTIMEH      (CLINT_BASE + 0xBFFC)

#define UART_BASE         0x10000000
#define UART_TXDATA       (UART_BASE + 0x00)
#define UART_RXDATA       (UART_BASE + 0x04)
#define UART_STATUS       (UART_BASE + 0x08)
#define UART_CTRL         (UART_BASE + 0x0C)
#define UART_BAUDDIV      (UART_BASE + 0x10)

#define UART_STATUS_TXFULL   (1 << 0)
#define UART_STATUS_TXIDLE   (1 << 1)
#define UART_STATUS_RXVALID  (1 << 2)
#define UART_STATUS_OVERRUN  (1 << 3)
#define UART_CTRL_RXIE       (1 << 0)
#define UART_CTRL_TXIE       (1 << 1)

#define GPIO_BASE         0x20000000
#define GPIO_OUT          (GPIO_BASE + 0x00)
#define GPIO_IN           (GPIO_BASE + 0x04)
#define GPIO_OE           (GPIO_BASE + 0x08)

#define SYSCON_BASE       0x30000000
#define SYSCON_EXIT       (SYSCON_BASE + 0x00)

#define MSTATUS_MIE       (1 << 3)
#define MIE_MSIE          (1 << 3)
#define MIE_MTIE          (1 << 7)
#define MIE_MEIE          (1 << 11)

#ifndef __ASSEMBLER__
#include "types.h"

#define REG32(addr)       (*(volatile uint32_t *)(addr))
#endif

#endif
