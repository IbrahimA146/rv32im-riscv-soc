/*
 * demo/main.c - bring-up firmware for the RV32IM SoC
 *
 *  1. Identify the CPU from misa
 *  2. Run self-checking workloads and report cycle-accurate performance
 *     (CPI, branch-prediction accuracy) from the hardware counters
 *  3. Exercise traps: ecall "syscalls", illegal-instruction recovery
 *  4. Timer interrupts drive a GPIO LED animation
 *  5. Interrupt-driven UART shell
 */
#include "hal.h"

/* ------------------------------------------------------------------------ */
/* Performance measurement using the core's hardware counters               */
/* ------------------------------------------------------------------------ */
typedef struct {
    uint32_t cycles, insns, branches, mispredicts;
} perf_t;

static void perf_begin(perf_t *p)
{
    p->cycles      = csr_read_mcycle();
    p->insns       = csr_read_minstret();
    p->branches    = csr_read_branches();
    p->mispredicts = csr_read_mispredicts();
}

static void perf_end(perf_t *p)
{
    p->cycles      = csr_read_mcycle() - p->cycles;
    p->insns       = csr_read_minstret() - p->insns;
    p->branches    = csr_read_branches() - p->branches;
    p->mispredicts = csr_read_mispredicts() - p->mispredicts;
}

static void print_fixed3(uint32_t num, uint32_t den)     /* num/den with 3 decimals */
{
    uint32_t whole = num / den;
    uint32_t frac = ((num % den) * 1000u) / den;
    printf("%u.%03u", whole, frac);
}

static int failures;

static void report(const char *name, bool ok, const perf_t *p)
{
    printf("  %-16s %s  %7u insns  CPI ", name, ok ? "PASS" : "FAIL", p->insns);
    print_fixed3(p->cycles, p->insns ? p->insns : 1);
    if (p->branches) {
        printf("  bpred %3u%%", ((p->branches - p->mispredicts) * 100u) / p->branches);
    }
    printf("\n");
    if (!ok)
        failures++;
}

/* ------------------------------------------------------------------------ */
/* Workloads                                                                */
/* ------------------------------------------------------------------------ */
static uint32_t crc32(const uint8_t *data, size_t len)
{
    static uint32_t table[256];
    if (!table[1]) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++)
                c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    }
    uint32_t crc = 0xFFFFFFFFu;
    while (len--)
        crc = table[(crc ^ *data++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static bool test_crc32(void)
{
    static const char msg[] = "123456789";
    return crc32((const uint8_t *)msg, 9) == 0xCBF43926u;
}

static bool test_sieve(void)
{
    #define SIEVE_N 8192
    static uint8_t composite[SIEVE_N];
    uint32_t count = 0;
    memset(composite, 0, sizeof composite);
    for (uint32_t i = 2; i < SIEVE_N; i++) {
        if (composite[i])
            continue;
        count++;
        for (uint32_t j = i * i; j < SIEVE_N; j += i)
            composite[j] = 1;
    }
    return count == 1028;                 /* pi(8192) */
}

static uint32_t lcg_state = 0x2545F491u;
static uint32_t lcg(void)
{
    lcg_state = lcg_state * 1664525u + 1013904223u;
    return lcg_state;
}

static void quicksort(int32_t *a, int lo, int hi)
{
    while (lo < hi) {
        int32_t pivot = a[(lo + hi) / 2];
        int i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pivot) i++;
            while (a[j] > pivot) j--;
            if (i <= j) {
                int32_t t = a[i]; a[i] = a[j]; a[j] = t;
                i++; j--;
            }
        }
        if (j - lo < hi - i) { quicksort(a, lo, j); lo = i; }
        else                 { quicksort(a, i, hi); hi = j; }
    }
}

static bool test_qsort(void)
{
    #define QS_N 400
    static int32_t a[QS_N];
    uint32_t sum_before = 0, sum_after = 0;
    for (int i = 0; i < QS_N; i++) {
        a[i] = (int32_t)lcg();
        sum_before += (uint32_t)a[i];
    }
    quicksort(a, 0, QS_N - 1);
    for (int i = 0; i < QS_N; i++) {
        sum_after += (uint32_t)a[i];
        if (i && a[i - 1] > a[i])
            return false;
    }
    return sum_before == sum_after;
}

static bool test_matmul(void)
{
    #define MN 12
    static int32_t A[MN][MN], B[MN][MN], C1[MN][MN], C2[MN][MN];
    for (int i = 0; i < MN; i++)
        for (int j = 0; j < MN; j++) {
            A[i][j] = (int32_t)(lcg() >> 20) - 2048;
            B[i][j] = (int32_t)(lcg() >> 20) - 2048;
        }
    for (int i = 0; i < MN; i++)                       /* i-j-k order */
        for (int j = 0; j < MN; j++) {
            int32_t s = 0;
            for (int k = 0; k < MN; k++)
                s += A[i][k] * B[k][j];
            C1[i][j] = s;
        }
    memset(C2, 0, sizeof C2);
    for (int i = 0; i < MN; i++)                       /* i-k-j order */
        for (int k = 0; k < MN; k++) {
            int32_t aik = A[i][k];
            for (int j = 0; j < MN; j++)
                C2[i][j] += aik * B[k][j];
        }
    return memcmp(C1, C2, sizeof C1) == 0;
}

static bool test_divide(void)
{
    for (int i = 0; i < 150; i++) {
        int32_t  a = (int32_t)lcg();
        int32_t  b = (int32_t)(lcg() >> (i % 31));
        uint32_t ua = lcg(), ub = lcg() >> (i % 29);
        if (b == 0 || ub == 0)
            continue;
        if ((a / b) * b + (a % b) != a)             return false;
        if ((ua / ub) * ub + (ua % ub) != ua)       return false;
        if ((a % b) != 0 && ((a % b) < 0) != (a < 0)) return false;
    }
    return true;
}

/* ------------------------------------------------------------------------ */
/* Trap tests                                                               */
/* ------------------------------------------------------------------------ */
#define SYS_ADD   1
#define SYS_MAGIC 2

static volatile uint32_t illegal_seen;

bool handle_exception(uint32_t cause, uint32_t epc, uint32_t tval,
                      trap_frame_t *frame, uint32_t *resume)
{
    (void)epc;
    if (cause == CAUSE_ECALL_M) {
        switch (frame->a7) {
        case SYS_ADD:   frame->a0 = frame->a0 + frame->a1; return true;
        case SYS_MAGIC: frame->a0 = 0xC0FFEE;              return true;
        default:        return false;
        }
    }
    if (cause == CAUSE_ILLEGAL_INSN && tval == 0xFFFFFFFFu) {
        illegal_seen++;
        return true;                        /* skip it: *resume = epc + 4 */
    }
    (void)resume;
    return false;
}

extern uint32_t do_ecall(uint32_t a0, uint32_t a1, uint32_t nr);
extern void     do_illegal(void);

static bool test_ecall(void)
{
    return do_ecall(40, 2, SYS_ADD) == 42 && do_ecall(0, 0, SYS_MAGIC) == 0xC0FFEE;
}

static bool test_illegal(void)
{
    illegal_seen = 0;
    do_illegal();
    do_illegal();
    return illegal_seen == 2;
}

/* ------------------------------------------------------------------------ */
/* Timer-driven LED animation                                               */
/* ------------------------------------------------------------------------ */
static bool test_timer_leds(void)
{
    uint32_t pos = 0, dir = 1, last = 0;
    gpio_set_oe(0xFF);
    timer_start(4000);
    irq_enable();
    while (timer_ticks() < 15) {
        uint32_t t = timer_ticks();
        if (t != last) {                    /* knight-rider scanner */
            last = t;
            gpio_write(1u << pos);
            printf("    tick %2u  leds ", t);
            for (int b = 7; b >= 0; b--)
                uart_putc((gpio_read_out() >> b) & 1 ? '*' : '.');
            printf("\n");
            if (pos == 7) dir = 0;
            if (pos == 0) dir = 1;
            pos = dir ? pos + 1 : pos - 1;
        }
    }
    timer_stop();
    return timer_ticks() >= 15 && gpio_read_out() != 0;
}

/* ------------------------------------------------------------------------ */
/* UART shell                                                               */
/* ------------------------------------------------------------------------ */
static int read_line(char *buf, int max)
{
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c < 0)
            continue;                        /* RX arrives via interrupt */
        if (c == '\r' || c == '\n') {
            printf("\n");
            buf[n] = 0;
            return n;
        }
        if (n < max - 1) {
            buf[n++] = (char)c;
            uart_putc((char)c);              /* echo */
        }
    }
}

static void cmd_stats(void)
{
    uint32_t cyc = csr_read_mcycle(), ins = csr_read_minstret();
    uint32_t br = csr_read_branches(), mp = csr_read_mispredicts();
    printf("  mcycle        %u\n", cyc);
    printf("  minstret      %u\n", ins);
    printf("  CPI           ");
    print_fixed3(cyc, ins);
    printf("\n  branches      %u (%u mispredicted, %u%% accuracy)\n", br, mp,
           br ? ((br - mp) * 100u) / br : 0);
    printf("  irqs          timer=%u uart=%u soft=%u\n",
           irq_count_timer, irq_count_ext, irq_count_soft);
}

static int shell(void)
{
    char line[32];
    printf("\nUART shell ready (type 'help')\n");
    for (;;) {
        printf("> ");
        read_line(line, sizeof line);
        if (!strcmp(line, "help")) {
            printf("  help   this text\n  ping   liveness check\n  stats  hardware perf counters\n"
                   "  led    walk the GPIO LEDs\n  exit   end simulation\n");
        } else if (!strcmp(line, "ping")) {
            printf("  pong\n");
        } else if (!strcmp(line, "stats")) {
            cmd_stats();
        } else if (!strcmp(line, "led")) {
            for (uint32_t v = 1; v < 0x100; v = (v << 1) | 1)
                gpio_write(v);
            printf("  gpio_out = 0x%02x\n", gpio_read_out());
        } else if (!strcmp(line, "exit")) {
            printf("  bye\n");
            uart_flush();
            return failures;
        } else if (line[0]) {
            printf("  unknown command '%s'\n", line);
        }
    }
}

/* ------------------------------------------------------------------------ */
int main(void)
{
    uart_init();

    uint32_t misa = csr_read_misa();
    printf("\n");
    printf("==================================================\n");
    printf("  RV32IM SoC  |  5-stage pipeline  |  bare metal\n");
    printf("==================================================\n");
    printf("  misa     0x%08x  (RV%u", misa, (misa >> 30) == 1 ? 32 : 64);
    for (int i = 0; i < 26; i++)
        if (misa & (1u << i))
            uart_putc('A' + i);
    printf(")\n  hartid   %u\n\n", csr_read_mhartid());

    struct { const char *name; bool (*fn)(void); } tests[] = {
        { "crc32",        test_crc32 },
        { "sieve",        test_sieve },
        { "quicksort",    test_qsort },
        { "matmul",       test_matmul },
        { "div/rem",      test_divide },
        { "ecall",        test_ecall },
        { "illegal-insn", test_illegal },
    };

    printf("Self-test / benchmark\n");
    for (size_t i = 0; i < sizeof tests / sizeof tests[0]; i++) {
        perf_t p;
        perf_begin(&p);
        bool ok = tests[i].fn();
        perf_end(&p);
        report(tests[i].name, ok, &p);
    }

    printf("\nTimer interrupts -> GPIO\n");
    perf_t p;
    perf_begin(&p);
    bool ok = test_timer_leds();
    perf_end(&p);
    report("timer-irq", ok, &p);

    printf("\n%s: %d failure(s)\n", failures ? "SELF-TEST FAILED" : "ALL SELF-TESTS PASSED", failures);

    return shell();
}
