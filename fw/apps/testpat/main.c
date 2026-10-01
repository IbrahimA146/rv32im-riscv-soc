/*
 * testpat/main.c - draw a test pattern through the framebuffer
 *
 * Proves the whole display path works: the CPU writes colour indices into
 * pixel memory, sets up the palette, presents the frame, and the testbench
 * captures exactly what a monitor would have shown.
 *
 * Also self-checks: pixels are read back and compared, and the key queue is
 * drained if the testbench injected any events.
 */
#include "hal.h"

#define W 320
#define H 200

/* Named colours live above the ramps: putting them inside the grayscale range
 * makes them show up as stray colour in the gradient. */
#define C_BLACK   248
#define C_RED     249
#define C_GREEN   250
#define C_BLUE    251
#define C_YELLOW  252
#define C_CYAN    253
#define C_MAGENTA 254
#define C_WHITE   255

#define GRAY_BASE 192          /* 192..247: grayscale ramp */
#define GRAY_COUNT 56
#define RED_BASE    1          /*   1..63 : red ramp       */
#define GREEN_BASE 64          /*  64..127: green ramp     */
#define BLUE_BASE 128          /* 128..191: blue ramp      */

static inline void put(int x, int y, uint8_t c)
{
    *(volatile uint8_t *)(VID_PIX + (uint32_t)y * W + x) = c;
}

static inline uint8_t get(int x, int y)
{
    return *(volatile uint8_t *)(VID_PIX + (uint32_t)y * W + x);
}

static void pal(int i, uint32_t r, uint32_t g, uint32_t b)
{
    REG32(VID_PAL + 4 * i) = (r << 16) | (g << 8) | b;
}

static void setup_palette(void)
{
    pal(0, 0, 0, 0);
    for (int i = 0; i < 63; i++) {
        uint32_t v = (uint32_t)(i * 4 + 3);
        pal(RED_BASE + i,   v, 0, 0);
        pal(GREEN_BASE + i, 0, v, 0);
        pal(BLUE_BASE + i,  0, 0, v);
    }
    for (int i = 0; i < GRAY_COUNT; i++) {
        uint32_t v = (uint32_t)((i * 255) / (GRAY_COUNT - 1));
        pal(GRAY_BASE + i, v, v, v);
    }
    pal(C_BLACK, 0, 0, 0);
    pal(C_RED, 255, 0, 0);
    pal(C_GREEN, 0, 255, 0);
    pal(C_BLUE, 0, 0, 255);
    pal(C_YELLOW, 255, 255, 0);
    pal(C_CYAN, 0, 255, 255);
    pal(C_MAGENTA, 255, 0, 255);
    pal(C_WHITE, 255, 255, 255);
}

static void draw(void)
{
    static const uint8_t bars[8] = { C_WHITE, C_YELLOW, C_CYAN, C_GREEN,
                                     C_MAGENTA, C_RED, C_BLUE, C_BLACK };

    /* band 1: colour bars */
    for (int y = 0; y < 50; y++)
        for (int x = 0; x < W; x++)
            put(x, y, bars[x / (W / 8)]);

    /* band 2: grayscale gradient */
    for (int y = 50; y < 80; y++)
        for (int x = 0; x < W; x++)
            put(x, y, (uint8_t)(GRAY_BASE + (x * GRAY_COUNT) / W));

    /* band 3: 8x8 checkerboard in red and blue ramps */
    for (int y = 80; y < 130; y++)
        for (int x = 0; x < W; x++) {
            int cell = ((x >> 3) + (y >> 3)) & 1;
            put(x, y, (uint8_t)(cell ? RED_BASE + 50 : BLUE_BASE + 50));
        }

    /* band 4: a filled circle with a shaded edge, plus diagonals */
    const int cx = W / 2, cy = 165, r = 32;
    for (int y = 130; y < H; y++)
        for (int x = 0; x < W; x++) {
            int dx = x - cx, dy = y - cy;
            int d2 = dx * dx + dy * dy;
            uint8_t c;
            if (d2 <= r * r)
                c = (uint8_t)(GREEN_BASE + (d2 * 62) / (r * r));
            else if (x == y + 60 || x + y == 320 + 60)
                c = C_YELLOW;
            else
                c = 0;
            put(x, y, c);
        }

    /* a 1-pixel white frame around the screen */
    for (int x = 0; x < W; x++) {
        put(x, 0, C_WHITE);
        put(x, H - 1, C_WHITE);
    }
    for (int y = 0; y < H; y++) {
        put(0, y, C_WHITE);
        put(W - 1, y, C_WHITE);
    }
}

static int check(void)
{
    int bad = 0;

    /* the corners are part of the white frame */
    if (get(0, 0) != C_WHITE || get(W - 1, H - 1) != C_WHITE) bad++;
    /* middle of the first colour bar */
    if (get(10, 25) != C_WHITE) bad++;
    /* second bar is yellow */
    if (get(W / 8 + 10, 25) != C_YELLOW) bad++;
    /* gradient endpoints */
    if (get(1, 60) != GRAY_BASE || get(W - 2, 60) != GRAY_BASE + GRAY_COUNT - 1) bad++;
    /* centre of the circle is the darkest green */
    if (get(W / 2, 165) != GREEN_BASE) bad++;
    /* palette read-back */
    if (REG32(VID_PAL + 4 * C_RED) != 0x00FF0000) bad++;
    /* mode register */
    if (REG32(VID_CTL_MODE) != ((H << 16) | W)) bad++;

    return bad;
}

int main(void)
{
    uart_init();

    uint32_t mode = REG32(VID_CTL_MODE);
    printf("\nframebuffer %ux%u, %u bytes\n", mode & 0xFFFF, mode >> 16,
           (mode & 0xFFFF) * (mode >> 16));

    uint32_t t0 = csr_read_mcycle();
    setup_palette();
    draw();
    uint32_t cycles = csr_read_mcycle() - t0;

    int bad = check();
    printf("drawn in %u cycles (%u per pixel), %d check failures\n",
           cycles, cycles / (W * H), bad);

    REG32(VID_CTL_PRESENT) = 1;
    printf("frames presented: %u\n", REG32(VID_CTL_FRAME));

    /* drain anything the testbench typed on the keyboard */
    uint32_t ev;
    int keys = 0;
    while (((ev = REG32(KEYS_DATA)) & KEYS_DATA_EMPTY) == 0) {
        printf("key %s code %u\n", (ev & KEYS_PRESSED) ? "down" : "up  ",
               ev & 0xFF);
        keys++;
    }
    if (keys)
        printf("%d key events\n", keys);

    uart_flush();
    return bad;
}
