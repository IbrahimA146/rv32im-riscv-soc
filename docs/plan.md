# Plan: DOOM on this CPU

**Goal:** DOOM running on the processor in this repository — the actual RTL, not an imitation of it — captured
as a video with honest performance numbers.

Each stage ends with something visible, and nothing moves on until its "done when" check passes and the
existing regression is still green.

| # | Stage | You can see | State |
|---|---|---|---|
| 0 | Groundwork | measured simulator speed, this plan | done |
| 1 | Screen, keys, memory | a test pattern drawn by the chip | done |
| 2 | Fast harness | the whole regression in seconds | done |
| 3 | C library | malloc/printf/qsort working on the chip | done |
| 4 | DOOM port | the title screen, rendered by the pipeline | done |
| 5 | Video | DOOM running, as an mp4 in the README | done |
| 6 | Playable | DOOM playable live, with a keyboard | done |

---

## What stands in the way

Four concrete problems, with measurements rather than guesses.

| Problem | Today | DOOM needs |
|---|---|---|
| Memory | 64 KiB | ~8 MiB |
| Output | text over a serial port | a 320×200 framebuffer |
| Input | none | keyboard events |
| Speed | see below | ~3–5 M instructions per frame |

**Speed, measured on 2026-10-01** (same testbench, same firmware image, identical instruction counts):

| Simulator | Rate | Relative |
|---|---:|---:|
| Icarus Verilog (`vvp`) | ~10 k cycles/s | 1× |
| Verilator 5.024, `--binary --timing`, `-O3 -CFLAGS -O2` | **1.63 M cycles/s** | **~170×** |
| Verilator + dedicated C++ harness (stage 2 target) | ≥ 5 M cycles/s | ≥ 500× |

At 5 M cycles/s and ~4 M instructions per frame, expect **roughly 1 frame per second**. DOOM at 35 fps is not
the goal and will not be claimed; a recorded video with the real numbers printed next to it is.

### Why Verilator and not a hand-written C emulator

Verilator compiles *this repository's RTL* into fast C++. A hand-written emulator would be a second CPU
implementation to build, debug and keep in sync, and DOOM running on it would prove nothing about the
hardware design. The Verilator route keeps the claim literally true: the pipeline, the forwarding logic, the
branch predictor and the divider are all executing DOOM.

---

## Stage 1 — Screen, keys, memory

* **Build:** make RAM size a parameter (64 KiB for tests, 16 MiB for DOOM). Two new devices in `rtl/soc/`:
  a framebuffer (320×200, 8-bit palette + 256-entry palette RAM) and a key-event FIFO with an interrupt.
  Both added to the Python reference model so co-simulation still works.
* **Done when:** a small firmware app draws a test pattern, the testbench writes it out as a PNG, new device
  tests pass in co-simulation, and the full regression plus the 26/26 mutation score are unchanged.
* **Done.** `soc_video.sv` (indexed framebuffer + palette) and `soc_keys.sv` (event queue with interrupt)
  are in the SoC and in the Python reference model; `tests/isa/video.S` co-simulates every new register;
  `fw/apps/testpat` draws [this pattern](images/testpat.png) in 1.67 M cycles (26 per pixel) and self-checks
  the read-back; the testbench captures frames as PPM and `scripts/ppm2png.py` converts them. RAM is a
  parameter and a 16 MiB build runs. Two bugs found and fixed on the way: named palette entries overlapped
  the grayscale ramp (stray colour in the gradient), and the testbench drove key events on the same clock
  edge the FIFO sampled them (events arrived as code 0).

## Stage 2 — Fast harness

The coroutine-based testbench costs speed. DOOM needs a purpose-built harness.

* **Build:** `sim/verilator/main.cpp` — drives the clock directly, loads the memory image, serves the
  framebuffer and keyboard, writes frames to disk. Verilator becomes a second signoff simulator in
  `run_tests.py` (`--sim=verilator`).
* **Done when:** every regression test produces a commit trace identical to Icarus and to the ISS, the suite
  runs in seconds instead of minutes, and the harness sustains ≥ 5 M cycles/s.
* **Done.** `sim/verilator/main.cpp` drives the clock directly and re-implements the testbench's jobs in C++
  (serial decode, key injection, frame capture, commit trace). The full suite runs in **6.4 s instead of
  189 s**, at **4.5 M cycles/s**, and `--sim=both` runs every test on both simulators: traces match the ISS
  under each, and captured frames are byte-identical between them. The earlier 1-cycle counter difference was
  the SystemVerilog testbench counting one extra cycle around `$finish`; both harnesses now agree.
  Verilator also rejected resetting 256 palette entries in a loop — a fair complaint, since that would have
  cost 6k flip-flops, so the palette now initialises like block RAM.

## Stage 3 — C library

DOOM's source expects `malloc`, `fopen`/`fread`, `sprintf`, `qsort`, `atoi`. The firmware's hand-written
library has none of them.

* **Build:** a RISC-V toolchain with a real C library (newlib), unpacked inside the repo. Retarget its system
  calls onto the SoC: `write` → UART, `exit` → SYSCON, plus a heap in RAM. The WAD is linked in as a
  read-only blob behind a tiny in-memory file shim, so no block device is needed.
* **Done when:** a test app that mallocs, sprintfs, qsorts and reads the embedded WAD header runs correctly
  on the chip, and the regression still passes with the new toolchain.
* **Done, with no download at all.** The installed toolchain already ships an `rv32im/ilp32` newlib; the
  earlier "no rv32 libc" conclusion was wrong because `-march=rv32im_zicsr` matches no multilib name, so GCC
  silently fell back to the 64-bit libraries. Asking the plain `rv32im` driver for its library directories and
  putting those first on the link line fixes it. `fw/common/syscalls.c` retargets newlib onto the SoC
  (`_write` to the UART, `_sbrk` to a heap that stops short of the stack, `_exit` to SYSCON) and adds a small
  read-only in-memory filesystem, which is how the WAD is served without a block device. `fw/apps/libctest`
  checks heap, printf, qsort/bsearch, strings and file I/O on the chip; newlib-nano keeps it inside 64 KiB.

## Stage 4 — DOOM port

`doomgeneric` exists precisely for this: it reduces DOOM to five functions a platform must provide.

* **Build:** `fw/apps/doom/` — implement `DG_Init`, `DG_DrawFrame` (copy to framebuffer), `DG_SleepMs`,
  `DG_GetTicksMs` (from `mtime`), `DG_GetKey` (from the key FIFO). Freedoom supplies the game data.
* **Done when:** the title screen, rendered by the RTL, is saved as a PNG that looks like DOOM.
* **Done.** `fw/apps/doom/main.c` implements the five hooks against this chip's devices. DOOM is built in
  CMAP256 mode at 320x200, so its 8-bit framebuffer and 256-entry palette map onto `soc_video.sv` with no
  conversion. The WAD is dropped into RAM by the harness and published through the stage-3 in-memory
  filesystem, so DOOM's own `fopen`/`fread` works unchanged and the program image stays small.
  `i_sound_stub.c` replaces the SDL_mixer backend with silence. The title screen appears after 14.4 M
  instructions.

## Stage 5 — Video

* **Build:** run DOOM's built-in demo playback — deterministic, needs no keyboard — dump every frame, and
  assemble them with ffmpeg. Print measured cycles/frame, instructions/frame, CPI and branch-prediction
  accuracy from the hardware counters alongside.
* **Done when:** the README shows a video of DOOM running on the CPU, labelled with its real frame rate.
* **Done.** `-timedemo demo1` plays DOOM's built-in demo with no input needed, which also makes the run
  deterministic. 400 frames measured:

  | | |
  |---|---|
  | instructions | 531,900,311 |
  | CPI | 1.165 |
  | branch prediction | 90.7 % |
  | cycles per frame | 1,507,304 mean / 2,072,143 worst |
  | implied rate at 50 MHz | 33.1 fps |
  | simulation speed | ~6 M cycles/s, about 4 frames/s wall clock |

  The frame rate is a projection from measured cycles per frame, assuming the design meets its 50 MHz target;
  it has never been synthesized, so that assumption is untested.

## Stage 6 — Playable

* **Build:** `sim/verilator/display.h` adds an SDL window and live keyboard to the C++ harness: frames are
  blitted when the chip presents them, host keys become the scancodes the SoC's keyboard device delivers.
* **Done when:** you can play it with a keyboard at a frame rate that responds.
* **Done, ~12 fps.** Three things got it there, and profiling decided all three:
  * A sampling profiler (`--profile`, `scripts/profile_report.py`) samples the committed PC, which showed
    58% of gameplay inside `R_DrawSpan`/`R_DrawColumn` — the renderer, exactly as expected — but also 23% in
    the clock function, because it divided and division costs ~34 cycles on this core. Replacing the divide
    with a multiply by a reciprocal removed that.
  * DOOM's screen buffer now *is* the framebuffer (`DG_Init` repoints it), so a full-screen copy per frame
    disappeared.
  * A smaller viewport with low detail costs 1.8x fewer cycles per frame (1.33 M -> 0.74 M measured), which
    is the difference between a slideshow and something controllable. Both are the game's own settings and
    can be changed from its menu while playing.
* **Watching the hardware while playing.** The CPU counts stall and flush events itself in
  `mhpmcounter3-6` (branches, mispredictions, load-use stall cycles, divider stall cycles) and the harness
  reads those registers once a second. The first attempt instead exposed the combinational `load_use`,
  `ex_stall` and `mispredict` signals to the simulator with `/*verilator public*/`, which cost **4x
  simulation speed** (7 M down to 1.8 M cycles/s): a public signal cannot be optimised away, so Verilator has
  to materialise it every cycle. Counting in hardware is both faster to read and what a real CPU does.
* **A second trap, worth remembering.** Left to itself DOOM compares against the clock and runs several game
  tics per frame when rendering is slower than real time, which snowballs - more tics make the next frame
  slower still, and the frame rate collapsed to 1.3 fps. `singletics` runs exactly one tic per frame; the
  game then runs at whatever pace the simulation sustains, smoothly and responsively.
* **Not done:** the browser/WebAssembly version, which was the original stretch idea. Playing locally turned
  out to be the better answer to the same question.

## What can honestly be claimed

* "DOOM runs on a RISC-V CPU I designed from scratch, in RTL simulation, at ~N fps."
* "The same RTL is verified against a golden reference model instruction by instruction, and the test suite
  catches 26/26 injected bugs."

Not claimable without an FPGA: that it runs on real hardware. Keep that distinction explicit everywhere.

## Tools and downloads

Installed system-wide: Icarus Verilog, Verilator, RISC-V GCC, Python (all free).
Inside the repo and deletable with it: the newlib toolchain, `doomgeneric` source (GPL), Freedoom game data
(free and redistributable — the original commercial WAD is never required).
