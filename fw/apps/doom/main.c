/*
 * fw/apps/doom/main.c - DOOM on the RV32IM SoC
 *
 * doomgeneric reduces DOOM to a handful of functions a platform must provide.
 * This is that platform layer, written against this chip's devices:
 *
 *   DG_DrawFrame   -> copy the 8-bit screen into the framebuffer, update the
 *                     palette when DOOM changes it, then present the frame
 *   DG_GetKey      -> pop the keyboard event queue
 *   DG_GetTicksMs  -> derive milliseconds from the CLINT's mtime counter
 *   DG_SleepMs     -> no-op: simulated time only advances when the CPU runs
 *
 * DOOM is built in CMAP256 mode, so it renders into 8-bit colour indices and
 * keeps a 256-entry palette - exactly what soc_video.sv consumes, with no
 * conversion in between.
 *
 * The WAD is placed in RAM by the simulation harness and published to newlib's
 * file layer, so DOOM's ordinary fopen()/fread() code works unchanged.
 */
#include "hal.h"

#include "doomgeneric.h"
#include "doomkeys.h"
#include "doomtype.h"
#include "i_video.h"

/* Where the harness drops the WAD. The header carries the size and the DOOM
 * command line, so options can change without rebuilding the firmware. */
#define WAD_ADDR     0x01000000u
#define WAD_MAGIC    0x57414442u   /* "WADB" */
#define WAD_ARGS_LEN 120

typedef struct {
    uint32_t magic;
    uint32_t size;
    uint32_t ticks_per_ms;   /* how fast the game should believe time passes */
    uint8_t  screen_blocks;  /* 3..11 viewport size, 0 = leave alone   */
    uint8_t  detail_level;   /* 1 = low detail (half horizontal pixels) */
    uint8_t  fixed_step;     /* one game tic per frame instead of chasing the clock */
    uint8_t  pad;
    char     args[WAD_ARGS_LEN];
} wad_header_t;

/* doomgeneric compiles out DOOM's config-file reader, so these are set
 * directly. DOOM's init calls R_SetViewSize(screenblocks, detailLevel), so the
 * values must be in place before the game starts; they are the same two
 * settings the in-game options menu changes. */
extern int screenblocks;
extern int detailLevel;

/* With this set, DOOM advances exactly one game tic per rendered frame. Left
 * clear, it compares against the clock and runs several tics per frame when
 * rendering is slower than real time, which snowballs: more tics make the next
 * frame slower still. One tic per frame keeps the game responsive and smooth,
 * it simply runs at the pace the simulation can sustain. */
extern boolean singletics;

static uint32_t ticks_per_ms = CLK_HZ / 1000;
/* Reciprocal of ticks_per_ms, scaled by 2^32. Profiling the game showed 23% of
 * all time inside the clock function, because dividing costs ~34 cycles on this
 * core; a multiply-high is one cycle. */
static uint32_t ticks_recip = (uint32_t)(((uint64_t)1 << 32) / (CLK_HZ / 1000));

#define SCREEN_W 320
#define SCREEN_H 200

/* ------------------------------------------------------------------------ */
/* Platform hooks                                                            */
/* ------------------------------------------------------------------------ */
void DG_Init(void)
{
    gpio_set_oe(0xFF);

    /* doomgeneric has just malloc'd a screen buffer that we would otherwise
     * copy into video memory every frame. Point it at the framebuffer instead,
     * so the game renders straight into the hardware and one full-screen copy
     * per frame disappears. */
    free(DG_ScreenBuffer);
    DG_ScreenBuffer = (pixel_t *)VID_PIX;
}

void DG_DrawFrame(void)
{
    if (palette_changed) {
        for (int i = 0; i < 256; i++)
            REG32(VID_PAL + 4 * i) = ((uint32_t)colors[i].r << 16)
                                   | ((uint32_t)colors[i].g << 8)
                                   | (uint32_t)colors[i].b;
        palette_changed = false;
    }

    /* DG_ScreenBuffer is the framebuffer itself (see DG_Init), so the frame is
     * already in video memory: just tell the display it is complete. */
    REG32(VID_CTL_PRESENT) = 1;
    gpio_write(REG32(VID_CTL_FRAME));          /* frame counter on the LEDs */
}

uint32_t DG_GetTicksMs(void)
{
    /* The timer counts simulated cycles. Dividing by the real 50 MHz figure
     * makes the game run in slow motion when simulation is slower than
     * hardware, so the harness passes the rate it actually achieves and the
     * game then moves at the right speed, just with fewer frames.
     * The divide is done as a multiply by the reciprocal: this function is
     * called constantly, and division is the slowest thing this CPU does. */
    return (uint32_t)(((uint64_t)REG32(CLINT_MTIME) * ticks_recip) >> 32);
}

void DG_SleepMs(uint32_t ms)
{
    /* Nothing to wait for: in simulation the clock only advances while the CPU
     * executes, so sleeping would just burn cycles and slow the frame rate. */
    (void)ms;
}

void DG_SetWindowTitle(const char *title)
{
    printf("[doom] %s\n", title);
}

/* Scancodes injected by the harness, mapped onto DOOM's keys. */
static unsigned char map_key(unsigned char code)
{
    switch (code) {
    case 1:   return KEY_ESCAPE;
    case 28:  return KEY_ENTER;
    case 57:  return KEY_USE;          /* space */
    case 29:  return KEY_FIRE;         /* ctrl  */
    case 56:  return KEY_RALT;
    case 42:  return KEY_RSHIFT;
    case 72:  return KEY_UPARROW;
    case 80:  return KEY_DOWNARROW;
    case 75:  return KEY_LEFTARROW;
    case 77:  return KEY_RIGHTARROW;
    case 31:  return 's';
    case 17:  return 'w';
    case 30:  return 'a';
    case 32:  return 'd';
    case 25:  return 'p';
    default:  return (unsigned char)('0' + (code % 10));
    }
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    uint32_t ev = REG32(KEYS_DATA);
    if (ev & KEYS_DATA_EMPTY)
        return 0;
    *pressed = (ev & KEYS_PRESSED) ? 1 : 0;
    *key = map_key((unsigned char)(ev & 0xFF));
    return 1;
}

/* ------------------------------------------------------------------------ */
int main(void)
{
    uart_init();

    const wad_header_t *hdr = (const wad_header_t *)WAD_ADDR;
    if (hdr->magic != WAD_MAGIC) {
        printf("no WAD at %08x (magic %08x) - pass --wad to the harness\n",
               WAD_ADDR, hdr->magic);
        return 1;
    }
    if (hdr->ticks_per_ms) {
        ticks_per_ms = hdr->ticks_per_ms;
        ticks_recip  = (uint32_t)(((uint64_t)1 << 32) / ticks_per_ms);
    }
    romfs_add("doom1.wad", hdr + 1, hdr->size);
    printf("\nDOOM on RV32IM: WAD %u bytes at %08x\n", hdr->size, WAD_ADDR);

    /* fixed options, then whatever command line the harness passed in */
    static char arg0[] = "doom";
    static char arg1[] = "-iwad";
    static char arg2[] = "doom1.wad";
    static char arg3[] = "-mb";
    static char arg4[] = "6";            /* zone size in MiB */
    static char cmdline[WAD_ARGS_LEN];

    char *argv[16];
    int argc = 0;
    argv[argc++] = arg0;
    argv[argc++] = arg1;
    argv[argc++] = arg2;
    argv[argc++] = arg3;
    argv[argc++] = arg4;

    memcpy(cmdline, hdr->args, WAD_ARGS_LEN - 1);
    for (char *p = cmdline; *p && argc < 15;) {
        while (*p == ' ') p++;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ') p++;
        if (*p) *p++ = 0;
    }
    argv[argc] = NULL;
    if (argc > 5) {
        printf("doom args:");
        for (int i = 5; i < argc; i++)
            printf(" %s", argv[i]);
        printf("\n");
    }

    /* A smaller viewport and low detail cost far fewer cycles per frame, which
     * is what makes the game playable at simulation speed. */
    if (hdr->fixed_step)
        singletics = true;
    if (hdr->screen_blocks) {
        screenblocks = hdr->screen_blocks;
        detailLevel  = hdr->detail_level;
        printf("view size %u, %s detail\n", screenblocks, detailLevel ? "low" : "high");
    }

    doomgeneric_Create(argc, argv);

    for (;;)
        doomgeneric_Tick();

    return 0;
}
