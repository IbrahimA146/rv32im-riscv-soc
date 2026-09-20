# Start here

## What this project is

A **CPU designed from scratch** (the kind of chip inside an Arduino), plus the **program that runs on it**.

Real chips are designed as text files in a language called SystemVerilog and then run on a **simulator** — a
program that pretends to be the chip and obeys the description exactly. That is how chips are developed long
before physical silicon exists, and it is what happens when you run the commands below.

Two halves:

| Folder | What it is |
|---|---|
| `rtl/` | **The chip.** The CPU itself, plus a timer, serial port (UART) and GPIO pins. |
| `fw/` | **The program.** C code that runs *on* that CPU: boots it, runs benchmarks, blinks LEDs, answers typed commands. |
| `tests/`, `scripts/` | **The proof it works.** Test programs, a reference model, and the tools that compare them. |

## Tools you need (already installed on this machine)

Installed from MSYS2 with
`pacman -S mingw-w64-ucrt-x86_64-iverilog mingw-w64-ucrt-x86_64-riscv64-unknown-elf-gcc make`:

1. **Icarus Verilog** — the simulator that pretends to be the chip.
2. **RISC-V GCC** — the compiler that turns the C firmware into a program the chip can run.
3. **make** — a convenience runner (optional, the Python commands below do the same thing).

Python 3 is also required and is already installed.

## Command 1: watch the chip boot and run (~1 min)

```
cd C:\Users\ibrah\Desktop\recitation
python scripts/run_tests.py fw -v
```

What you are looking at:

* **Banner + `misa`** — the CPU booting and reporting what kind of CPU it is.
* **Self-test list** — real workloads (CRC-32, prime sieve, quicksort, matrix multiply) running on the CPU.
  `CPI 1.088` = it averaged 1.088 clock cycles per instruction. `bpred 97%` = its branch predictor guessed
  right 97% of the time. The chip measures this about itself, in hardware counters.
* **LED ticks** — a hardware timer interrupting the CPU 15 times; each interrupt walks a light across 8 LEDs.
* **The `>` shell** — the chip talking over a simulated serial port, one bit at a time, exactly like a real
  board plugged in over USB. The testbench types `help`, `ping`, `stats`, `led`, `exit`; the firmware replies.

## Command 2: run every test (~1-2 min)

```
python scripts/run_tests.py
```

61 tests. Each one runs **twice** — once on the chip, once on a separate reference model written in Python —
and the two are compared instruction by instruction. This is what proves the CPU is correct rather than just
"seems to work". Expect `61/61 passed`.

## Command 3: test the tests (~5 min)

```
python scripts/mutation_test.py
```

Deliberately breaks the chip 26 different ways (one at a time, on a private copy) and checks that the test
suite notices every break. Expect `26/26 mutants killed`.

## Other useful commands

```
python scripts/run_tests.py isa          # just the instruction tests
python scripts/run_tests.py random -n 50 # 50 randomly generated test programs
python scripts/run_tests.py isa -k div   # only tests whose name contains "div"
make wave                                # write build/wave.vcd to open in a waveform viewer
```

Nothing you run modifies the design — everything lands in `build/`, which you can delete at any time.

## Where to read next

`README.md` is the version written for recruiters and engineers: architecture diagrams, memory map,
verification strategy, and the three real bugs this flow caught.
