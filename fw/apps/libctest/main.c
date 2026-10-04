/*
 * libctest/main.c - exercise the C library DOOM depends on
 *
 * newlib supplies the code; syscalls.c connects it to this SoC. This checks the
 * pieces DOOM actually uses: the heap, formatted printing, sorting, string
 * handling, and reading a file out of the in-memory filesystem (which is how
 * the WAD will be served).
 */
#include "hal.h"

static int failures;

static void check(const char *what, bool ok)
{
    printf("  %-22s %s\n", what, ok ? "ok" : "FAILED");
    if (!ok)
        failures++;
}

/* ---- a fake "file" living in ROM, standing in for the WAD ---- */
static const uint8_t wad_stub[] = {
    'I', 'W', 'A', 'D',  0x0A, 0x00, 0x00, 0x00,  0x20, 0x01, 0x00, 0x00,
    'D', 'E', 'M', 'O',  'D', 'A', 'T', 'A',
};

static bool test_heap(void)
{
    /* sized to fit the 64 KiB test machine: ~4.5 KiB in total */
    enum { N = 32, UNIT = 9 };
    void *blocks[N];
    for (int i = 0; i < N; i++) {
        blocks[i] = malloc((size_t)(i + 1) * UNIT);
        if (!blocks[i])
            return false;
        memset(blocks[i], i, (size_t)(i + 1) * UNIT);
    }
    for (int i = 0; i < N; i++) {                 /* nothing overlapped */
        const uint8_t *p = blocks[i];
        for (size_t j = 0; j < (size_t)(i + 1) * UNIT; j++)
            if (p[j] != (uint8_t)i)
                return false;
    }
    for (int i = 0; i < N; i += 2)
        free(blocks[i]);
    char *big = realloc(blocks[1], 2048);
    if (!big)
        return false;
    memset(big, 0xAB, 2048);
    free(big);
    for (int i = 3; i < N; i += 2)
        free(blocks[i]);
    return true;
}

static bool test_printf(void)
{
    char buf[128];
    snprintf(buf, sizeof buf, "%d|%u|%08x|%s|%c|%5d|%-5d|", -42, 4000000000u,
             0xDEADBEEF, "str", 'Z', 7, 7);
    if (strcmp(buf, "-42|4000000000|deadbeef|str|Z|    7|7    |"))
        return false;
    snprintf(buf, sizeof buf, "%ld %p", 123456789L, (void *)0x1234);
    return strstr(buf, "123456789") != NULL;
}

static int cmp_int(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

static bool test_qsort(void)
{
    enum { N = 500 };
    static int a[N];
    unsigned seed = 12345;
    for (int i = 0; i < N; i++) {
        seed = seed * 1103515245u + 12345u;
        a[i] = (int)(seed >> 8);
    }
    qsort(a, N, sizeof a[0], cmp_int);
    for (int i = 1; i < N; i++)
        if (a[i - 1] > a[i])
            return false;
    int key = a[N / 3];
    return bsearch(&key, a, N, sizeof a[0], cmp_int) != NULL;
}

static bool test_strings(void)
{
    char buf[64];
    strcpy(buf, "doom");
    strcat(buf, "1.wad");
    if (strcmp(buf, "doom1.wad") || strlen(buf) != 9)
        return false;
    if (!strstr(buf, "1.wad") || strchr(buf, '.') != buf + 5)
        return false;
    if (strncmp(buf, "doom", 4) || memcmp(buf, "doom", 4))
        return false;
    return atoi("1234") == 1234 && strtol("ff", NULL, 16) == 255;
}

static bool test_file(void)
{
    romfs_add("doom1.wad", wad_stub, sizeof wad_stub);

    FILE *f = fopen("doom1.wad", "rb");
    if (!f)
        return false;

    char magic[5] = {0};
    if (fread(magic, 1, 4, f) != 4 || strcmp(magic, "IWAD")) { fclose(f); return false; }

    uint32_t numlumps = 0;
    if (fread(&numlumps, 4, 1, f) != 1 || numlumps != 10) { fclose(f); return false; }

    if (fseek(f, 0, SEEK_END) != 0 || ftell(f) != (long)sizeof wad_stub) { fclose(f); return false; }
    if (fseek(f, 12, SEEK_SET) != 0) { fclose(f); return false; }

    char name[9] = {0};
    bool ok = fread(name, 1, 8, f) == 8 && !strcmp(name, "DEMODATA");
    fclose(f);

    /* a path prefix still resolves, and a missing file fails */
    FILE *g = fopen("./doom1.wad", "rb");
    ok = ok && g != NULL;
    if (g) fclose(g);
    return ok && fopen("nope.wad", "rb") == NULL;
}

int main(void)
{
    uart_init();
    printf("\nC library on the SoC\n");

    uint32_t t0 = csr_read_mcycle();
    check("heap (malloc/free)", test_heap());
    check("printf formatting", test_printf());
    check("qsort + bsearch", test_qsort());
    check("string functions", test_strings());
    check("file I/O (romfs)", test_file());
    uint32_t cycles = csr_read_mcycle() - t0;

    printf("%d failure(s), %u cycles\n", failures, cycles);
    uart_flush();
    return failures;
}
