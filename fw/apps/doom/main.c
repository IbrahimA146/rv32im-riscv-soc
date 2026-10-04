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
#include "i_video.h"

/* Where the harness drops the WAD: {magic, size} then the data itself. */
#define WAD_ADDR  0x01000000u
#define WAD_MAGIC 0x57414442u   /* "WADB" */

#define SCREEN_W 320
#define SCREEN_H 200

/* ------------------------------------------------------------------------ */
/* Platform hooks                                                            */
/* ------------------------------------------------------------------------ */
void DG_Init(void)
{
    gpio_set_oe(0xFF);
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

    /* word-at-a-time copy: four pixels per store instead of one */
    const uint32_t *src = (const uint32_t *)DG_ScreenBuffer;
    volatile uint32_t *dst = (volatile uint32_t *)VID_PIX;
    for (int i = 0; i < SCREEN_W * SCREEN_H / 4; i++)
        dst[i] = src[i];

    REG32(VID_CTL_PRESENT) = 1;
    gpio_write(REG32(VID_CTL_FRAME));          /* frame counter on the LEDs */
}

uint32_t DG_GetTicksMs(void)
{
    return REG32(CLINT_MTIME) / (CLK_HZ / 1000);
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

    const uint32_t *hdr = (const uint32_t *)WAD_ADDR;
    if (hdr[0] != WAD_MAGIC) {
        printf("no WAD at %08x (magic %08x) - pass --wad to the harness\n",
               WAD_ADDR, hdr[0]);
        return 1;
    }
    uint32_t wad_size = hdr[1];
    romfs_add("doom1.wad", hdr + 2, wad_size);
    printf("\nDOOM on RV32IM: WAD %u bytes at %08x\n", wad_size, WAD_ADDR);

    static char arg0[] = "doom";
    static char arg1[] = "-iwad";
    static char arg2[] = "doom1.wad";
    static char arg3[] = "-mb";          /* zone size in MiB */
    static char arg4[] = "6";
    char *argv[] = { arg0, arg1, arg2, arg3, arg4, NULL };

    doomgeneric_Create(5, argv);

    for (;;)
        doomgeneric_Tick();

    return 0;
}
