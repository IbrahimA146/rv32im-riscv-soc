# Plan: DOOM on this CPU

**Goal:** DOOM running on the processor in this repository — the actual RTL, not an imitation of it — captured
as a video with honest performance numbers.

Each stage ends with something visible, and nothing moves on until its "done when" check passes and the
existing regression is still green.

| # | Stage | You can see | State |
|---|---|---|---|
| 0 | Groundwork | measured simulator speed, this plan | done |
| 1 | Screen, keys, memory | a test pattern drawn by the chip | done |
| 2 | Fast harness | the whole regression in seconds | next |
| 3 | C library | malloc/printf/qsort working on the chip | |
| 4 | DOOM port | the title screen, rendered by the pipeline | |
| 5 | Video | DOOM running, as an mp4 in the README | |
| 6 | Browser (stretch) | DOOM playable in a tab, live CPU panel | |

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
  runs in seconds instead of minutes, and the harness sustains ≥ 5 M cycles/s. Also resolve the known
  1-cycle difference in the testbench's own cycle counter between the two simulators (counting artifact, not
  a design difference — but it must be explained, not ignored).

## Stage 3 — C library

DOOM's source expects `malloc`, `fopen`/`fread`, `sprintf`, `qsort`, `atoi`. The firmware's hand-written
library has none of them.

* **Build:** a RISC-V toolchain with a real C library (newlib), unpacked inside the repo. Retarget its system
  calls onto the SoC: `write` → UART, `exit` → SYSCON, plus a heap in RAM. The WAD is linked in as a
  read-only blob behind a tiny in-memory file shim, so no block device is needed.
* **Done when:** a test app that mallocs, sprintfs, qsorts and reads the embedded WAD header runs correctly
  on the chip, and the regression still passes with the new toolchain.

## Stage 4 — DOOM port

`doomgeneric` exists precisely for this: it reduces DOOM to five functions a platform must provide.

* **Build:** `fw/apps/doom/` — implement `DG_Init`, `DG_DrawFrame` (copy to framebuffer), `DG_SleepMs`,
  `DG_GetTicksMs` (from `mtime`), `DG_GetKey` (from the key FIFO). Freedoom supplies the game data.
* **Done when:** the title screen, rendered by the RTL, is saved as a PNG that looks like DOOM.

## Stage 5 — Video

* **Build:** run DOOM's built-in demo playback — deterministic, needs no keyboard — dump every frame, and
  assemble them with ffmpeg. Print measured cycles/frame, instructions/frame, CPI and branch-prediction
  accuracy from the hardware counters alongside.
* **Done when:** the README shows a video of DOOM running on the CPU, labelled with its real frame rate and
  how much faster than real time the playback is.

## Stage 6 — Browser (stretch, only after stage 5)

Compile the Verilator model to WebAssembly with emscripten, add a canvas, keyboard input, and a panel showing
pipeline activity and counters live. Attempt only once the video exists.

---

## What can honestly be claimed

* "DOOM runs on a RISC-V CPU I designed from scratch, in RTL simulation, at ~N fps."
* "The same RTL is verified against a golden reference model instruction by instruction, and the test suite
  catches 26/26 injected bugs."

Not claimable without an FPGA: that it runs on real hardware. Keep that distinction explicit everywhere.

## Tools and downloads

Installed system-wide: Icarus Verilog, Verilator, RISC-V GCC, Python (all free).
Inside the repo and deletable with it: the newlib toolchain, `doomgeneric` source (GPL), Freedoom game data
(free and redistributable — the original commercial WAD is never required).
