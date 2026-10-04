/*
 * syscalls.c - retarget newlib onto the SoC
 *
 * newlib supplies malloc, printf, qsort, string handling and stdio, but it
 * needs a handful of primitives from the platform. This provides them:
 *
 *   _write  -> UART (stdout/stderr)
 *   _sbrk   -> heap growing up towards the stack
 *   _exit   -> SYSCON halt register
 *   open/read/close/lseek/fstat -> a tiny read-only in-memory filesystem,
 *   which is how the DOOM WAD is served without a block device.
 */
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/times.h>

#include "hal.h"

#undef errno
extern int errno;

/* ------------------------------------------------------------------------ */
/* In-memory read-only files                                                 */
/* ------------------------------------------------------------------------ */
#define MAX_FILES 4
#define FD_BASE   3            /* 0,1,2 are stdin/stdout/stderr */

typedef struct {
    const char    *name;
    const uint8_t *data;
    size_t         size;
} romfile_t;

typedef struct {
    const romfile_t *file;
    size_t           pos;
    int              open;
} fdesc_t;

static romfile_t rom_files[MAX_FILES];
static int       rom_count;
static fdesc_t   fds[MAX_FILES];

/* Register a blob so it can be opened by name (see fw/apps/doom). */
void romfs_add(const char *name, const void *data, size_t size)
{
    if (rom_count < MAX_FILES) {
        rom_files[rom_count].name = name;
        rom_files[rom_count].data = (const uint8_t *)data;
        rom_files[rom_count].size = size;
        rom_count++;
    }
}

static const romfile_t *romfs_find(const char *path)
{
    /* match on the basename so "./doom1.wad" and "doom1.wad" both work */
    const char *base = path;
    for (const char *p = path; *p; p++)
        if (*p == '/' || *p == '\\')
            base = p + 1;
    for (int i = 0; i < rom_count; i++)
        if (!strcmp(rom_files[i].name, base))
            return &rom_files[i];
    return NULL;
}

/* ------------------------------------------------------------------------ */
/* Newlib syscall surface                                                    */
/* ------------------------------------------------------------------------ */
int _write(int fd, const char *buf, int len)
{
    if (fd == 1 || fd == 2) {
        for (int i = 0; i < len; i++)
            uart_putc(buf[i]);
        return len;
    }
    errno = EBADF;
    return -1;
}

int _open(const char *path, int flags, int mode)
{
    (void)flags; (void)mode;
    const romfile_t *f = romfs_find(path);
    if (!f) {
        errno = ENOENT;
        return -1;
    }
    for (int i = 0; i < MAX_FILES; i++) {
        if (!fds[i].open) {
            fds[i].open = 1;
            fds[i].file = f;
            fds[i].pos = 0;
            return FD_BASE + i;
        }
    }
    errno = EMFILE;
    return -1;
}

static fdesc_t *lookup(int fd)
{
    int i = fd - FD_BASE;
    if (i < 0 || i >= MAX_FILES || !fds[i].open)
        return NULL;
    return &fds[i];
}

int _close(int fd)
{
    fdesc_t *d = lookup(fd);
    if (!d) { errno = EBADF; return -1; }
    d->open = 0;
    return 0;
}

int _read(int fd, char *buf, int len)
{
    fdesc_t *d = lookup(fd);
    if (!d) { errno = EBADF; return -1; }
    size_t left = d->file->size - d->pos;
    size_t n = (size_t)len < left ? (size_t)len : left;
    memcpy(buf, d->file->data + d->pos, n);
    d->pos += n;
    return (int)n;
}

off_t _lseek(int fd, off_t off, int whence)
{
    fdesc_t *d = lookup(fd);
    if (!d) { errno = EBADF; return -1; }
    size_t base = whence == SEEK_CUR ? d->pos : whence == SEEK_END ? d->file->size : 0;
    off_t pos = (off_t)base + off;
    if (pos < 0 || (size_t)pos > d->file->size) { errno = EINVAL; return -1; }
    d->pos = (size_t)pos;
    return pos;
}

int _fstat(int fd, struct stat *st)
{
    fdesc_t *d = lookup(fd);
    st->st_mode = d ? S_IFREG : S_IFCHR;
    st->st_size = d ? (off_t)d->file->size : 0;
    return 0;
}

int _stat(const char *path, struct stat *st)
{
    const romfile_t *f = romfs_find(path);
    if (!f) { errno = ENOENT; return -1; }
    st->st_mode = S_IFREG;
    st->st_size = (off_t)f->size;
    return 0;
}

int _isatty(int fd)
{
    return fd <= 2;
}

/* Heap: grows from the end of .bss towards the stack. */
extern char __heap_start;
void *_sbrk(ptrdiff_t incr)
{
    static char *brk;
    extern char  _stack_top;
    if (!brk)
        brk = &__heap_start;
    char *prev = brk;
    char *want = brk + incr;
    /* leave room for the stack */
    if (want > &_stack_top - 8192) {
        errno = ENOMEM;
        return (void *)-1;
    }
    brk = want;
    return prev;
}

void _exit(int code)
{
    uart_flush();
    REG32(SYSCON_EXIT) = (uint32_t)code;
    for (;;) {}
}

int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void)           { return 1; }

clock_t _times(struct tms *buf)
{
    uint32_t t = REG32(CLINT_MTIME);
    if (buf) {
        buf->tms_utime = (clock_t)t;
        buf->tms_stime = buf->tms_cutime = buf->tms_cstime = 0;
    }
    return (clock_t)t;
}

int _gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    uint32_t t = REG32(CLINT_MTIME);           /* one tick per clock cycle */
    tv->tv_sec = t / CLK_HZ;
    tv->tv_usec = (t % CLK_HZ) / (CLK_HZ / 1000000);
    return 0;
}
