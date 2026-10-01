/* video.S - framebuffer, palette and key-queue registers (co-simulated) */
#include "test_macros.h"

RVTEST_CODE_BEGIN

  /* ---- pixel memory: byte and word access ---- */
  TEST_CASE( 1, x14, 0x000000ab, li x1, VID_PIX; li x2, 0xab; sb x2, 0(x1); lbu x14, 0(x1))
  TEST_CASE( 2, x14, 0xdeadbeef, li x1, VID_PIX; li x2, 0xdeadbeef; sw x2, 4(x1); lw x14, 4(x1))
  TEST_CASE( 3, x14, 0x000000be, li x1, VID_PIX; lbu x14, 5(x1))
  TEST_CASE( 4, x14, 0xdea5beef, li x1, VID_PIX; li x2, 0xa5; sb x2, 6(x1); lw x14, 4(x1))
  TEST_CASE( 5, x14, 0x0000beef, li x1, VID_PIX; lhu x14, 4(x1))

  /* last visible pixel (320*200-1 = 63999) and the first word past it */
  TEST_CASE( 6, x14, 0x00000077, li x1, VID_PIX; li x2, 0x77; li x3, 63999; add x3, x1, x3; sb x2, 0(x3); lbu x14, 0(x3))
  TEST_CASE( 7, x14, 0x00000011, li x1, VID_PIX; li x2, 0x11; li x3, 64000; add x3, x1, x3; sw x2, 0(x3); lw x14, 0(x3))

  /* ---- palette: 24 bits wide, upper byte dropped ---- */
  TEST_CASE(10, x14, 0x00123456, li x1, VID_PAL; li x2, 0xff123456; sw x2, 0(x1); lw x14, 0(x1))
  TEST_CASE(11, x14, 0x00ff8800, li x1, VID_PAL; li x2, 0x00ff8800; sw x2, 4(x1); lw x14, 4(x1))
  /* reset value is a grayscale ramp: entry 200 reads 0xc8c8c8 */
  TEST_CASE(12, x14, 0x00c8c8c8, li x1, VID_PAL; lw x14, 800(x1))
  /* the 256-entry table repeats through the window */
  TEST_CASE(13, x14, 0x00123456, li x1, VID_PAL; li x3, 1024; add x3, x1, x3; lw x14, 0(x3))

  /* ---- control registers ---- */
  TEST_CASE(20, x14, 0x00c80140, li x1, VID_CTL; lw x14, 8(x1))      /* 200<<16 | 320 */
  TEST_CASE(21, x14, 0x00000000, li x1, VID_CTL; lw x14, 4(x1))      /* no frames yet */
  TEST_CASE(22, x14, 0x00000002, li x1, VID_CTL; sw x0, 0(x1); sw x0, 0(x1); lw x14, 4(x1))

  /* ---- key queue: empty, and the control bit is writable ---- */
  TEST_CASE(30, x14, 0x80000000, li x1, KEYS_BASE; lw x14, 0(x1))    /* bit31 = empty */
  TEST_CASE(31, x14, 0x00000000, li x1, KEYS_BASE; lw x14, 4(x1))    /* nothing pending */
  TEST_CASE(32, x14, 0x00000001, li x1, KEYS_BASE; li x2, 1; sw x2, 8(x1); lw x14, 8(x1))
  TEST_CASE(33, x14, 0x00000000, li x1, KEYS_BASE; sw x0, 8(x1); lw x14, 8(x1))

  TEST_PASSFAIL

RVTEST_CODE_END
