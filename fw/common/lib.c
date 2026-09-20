/* lib.c - minimal freestanding libc: mem*, str*, printf */
#include "hal.h"

typedef __builtin_va_list va_list;
#define va_start(v, l) __builtin_va_start(v, l)
#define va_end(v)      __builtin_va_end(v)
#define va_arg(v, t)   __builtin_va_arg(v, t)

void *memset(void *d, int c, size_t n)
{
    uint8_t *p = d;
    while (n--)
        *p++ = (uint8_t)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *dp = d;
    const uint8_t *sp = s;
    while (n--)
        *dp++ = *sp++;
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y)
            return *x - *y;
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return p - s;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (uint8_t)*a - (uint8_t)*b;
}

/* printf subset: %c %s %d %u %x %X %p %%, optional '0'/'-' flag and width */
static int put_num(uint32_t v, unsigned base, bool neg, int width, char pad, bool upper)
{
    char buf[12];
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0, count = 0;
    do {
        buf[n++] = digits[v % base];
        v /= base;
    } while (v);
    if (neg) {
        if (pad == '0') {
            uart_putc('-');
            count++;
            width--;
        } else {
            buf[n++] = '-';
        }
    }
    for (; width > n; width--, count++)
        uart_putc(pad);
    while (n) {
        uart_putc(buf[--n]);
        count++;
    }
    return count;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int count = 0;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*fmt == '\n') {
                uart_putc('\r');
                count++;
            }
            uart_putc(*fmt);
            count++;
            continue;
        }
        fmt++;
        char pad = ' ';
        int width = 0;
        bool left = false;
        if (*fmt == '-') {
            left = true;
            fmt++;
        }
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        switch (*fmt) {
        case 'c':
            uart_putc((char)va_arg(ap, int));
            count++;
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            int len = strlen(s);
            if (!left)
                for (; width > len; width--, count++)
                    uart_putc(' ');
            uart_puts(s);
            count += len;
            if (left)
                for (; width > len; width--, count++)
                    uart_putc(' ');
            break;
        }
        case 'd': {
            int32_t v = va_arg(ap, int32_t);
            count += put_num(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, v < 0, width, pad, false);
            break;
        }
        case 'u':
            count += put_num(va_arg(ap, uint32_t), 10, false, width, pad, false);
            break;
        case 'x':
        case 'X':
            count += put_num(va_arg(ap, uint32_t), 16, false, width, pad, *fmt == 'X');
            break;
        case 'p':
            count += put_num(va_arg(ap, uint32_t), 16, false, 8, '0', false);
            break;
        case '%':
            uart_putc('%');
            count++;
            break;
        default:
            break;
        }
    }
    va_end(ap);
    return count;
}
