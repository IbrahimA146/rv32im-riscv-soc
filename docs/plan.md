# Plan: DOOM on this CPU

**Goal:** open a web page, play DOOM, and watch the processor from this repository execute it live.

Six stages. Each one ends with something you can see, and nothing moves on until its "done when" check passes
and the existing regression is still green.

| # | Stage | You can see | State |
|---|---|---|---|
| 0 | Setup | this plan, tidy repo | done |
| 1 | Screen, keys, memory | a test pattern drawn by the chip | next |
| 2 | Fast model | the firmware booting instantly | |
| 3 | DOOM port | the title screen as an image | |
| 4 | Browser | DOOM playable in a tab | |
| 5 | Live CPU panel | the pipeline working next to the game | |
| 6 | Proof and polish | real-hardware frames matching the model | |

---

## Stage 1 — Screen, keys, memory

The chip has 64 KiB of memory and can only print text. DOOM needs megabytes, a screen and a keyboard.

* **Build:** RAM size becomes a parameter (64 KiB for the tests, 16 MiB for DOOM). Two new devices in
  `rtl/soc/`: a 320×200 framebuffer and a key-event register. Both mirrored in the Python reference model.
* **Done when:** a small firmware app draws a test pattern, the testbench saves it as an image, new device
  tests pass in co-simulation, and the full regression plus mutation score are unchanged.

## Stage 2 — Fast model

The full regression gets through about half a million instructions in a minute and a half. DOOM needs tens
of millions per second.

* **Build:** `model/` — the CPU and its devices re-implemented in C, executing the same instructions the
  hardware does, one at a time.
* **Done when:** every regression test produces the same commit trace on the C model as on the Python
  reference (and therefore the hardware), and it runs at 30 million instructions per second or better.

## Stage 3 — DOOM port

* **Build:** `fw/apps/doom/` — the open-source DOOM engine compiled for this CPU with no operating system
  underneath. Four small hooks connect it to the chip: draw a frame, read keys, read the clock, wait. The game
  data is packed into the firmware image because there is no disk.
* **Done when:** the fast model writes out the title screen and a frame of the first level, and a recorded
  demo replays to the same checksum every run.

## Stage 4 — Browser

* **Build:** `web/` — the C model compiled to WebAssembly, plus a page with a canvas and keyboard input.
* **Done when:** the game is playable in Chrome at 20 frames per second or better from a hosted link.

## Stage 5 — Live CPU panel

* **Build:** a timing layer on the model that reproduces what the pipeline does each cycle: branch
  predictions, load-use stalls, divide stalls, flushes. A panel beside the game shows the five stages, cycles
  per instruction, and branch-prediction accuracy.
* **Done when:** on the benchmark firmware, the model's cycle and misprediction counts equal the numbers the
  hardware's own counters report.

## Stage 6 — Proof and polish

* **Build:** a run of the real hardware design (compiled with Verilator) from boot through the first frames,
  a slow-motion mode that shows those frames, and a 60-second demo script.
* **Done when:** frames from the real design are pixel-identical to the model's, with matching commit traces.

---

## What we can honestly claim

The playable version runs on a **model of the CPU that is checked instruction-for-instruction against the
hardware design**, not on the hardware design itself, which is far too slow to simulate in real time. Stage 6
closes the gap by running the true design for a short stretch and showing identical output.

## Tools

| Tool | Used for | Have it? |
|---|---|---|
| Icarus Verilog 12 | hardware simulation | yes |
| RISC-V GCC 12.2 + newlib | compiling firmware and DOOM | yes |
| GCC 13 (native), make, Python 3.13 | building the model, scripts | yes |
| clang + lld | WebAssembly build (stage 4) | **no** |
| Verilator | fast run of the real design (stage 6) | **no** |

## Open decisions

* **Game data.** The shareware `DOOM1.WAD` (about 4 MB) is free to download but not ours to redistribute, so
  it stays out of the repository and is fetched by a script. Freedoom is the fully open alternative.
* **Licence.** The DOOM engine source is GPL-2.0. Either it is fetched at build time like the game data, or
  `fw/apps/doom/` carries that licence. Decide at stage 3.
* **Sound.** Left out. It is a stretch goal after stage 6.
