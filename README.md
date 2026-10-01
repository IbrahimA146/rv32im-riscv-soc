# DOOM on a CPU I designed

A RISC-V processor built from scratch, the small computer around it, and the firmware that runs on it,
now being extended until it plays DOOM in a browser tab with the processor's pipeline visible live.

## Where it stands

* **Working today:** the CPU, the system-on-chip, bare-metal firmware, and a verification flow that checks
  every instruction against a reference model.
* **In progress:** the DOOM port. Stage 1 of 6 is next.

## The pieces

| Folder | What it is | State |
|---|---|---|
| `rtl/` | **The chip.** A 5-stage pipelined RV32IM CPU plus timer, serial port and GPIO. | working |
| `fw/` | **The program.** C firmware that boots the chip and runs on it. | working |
| `tests/` `scripts/` `sim/` | **The proof.** Test programs, a reference model, and the tools that compare them. | working |
| `model/` | **The fast model.** The same CPU in C, quick enough to run a game. | stage 2 |
| `fw/apps/doom/` | **The game.** DOOM ported to the chip. | stage 3 |
| `web/` | **The page.** The model in a browser, with the live CPU panel. | stages 4–5 |

## Roadmap

| # | Stage | You can see |
|---|---|---|
| 1 | Screen, keys, memory | a test pattern drawn by the chip |
| 2 | Fast model | the firmware booting instantly |
| 3 | DOOM port | the title screen as an image |
| 4 | Browser | DOOM playable in a tab |
| 5 | Live CPU panel | the pipeline working next to the game |
| 6 | Proof and polish | real-hardware frames matching the model |

Details and the "done when" check for each stage are in [docs/plan.md](docs/plan.md).

## Run it

Needs Icarus Verilog, a RISC-V GCC and Python 3 ([setup](docs/getting-started.md)).

```bash
python scripts/run_tests.py fw -v     # boot the chip and watch its console
python scripts/run_tests.py           # every test, checked against the reference model
python scripts/mutation_test.py       # break the chip 26 ways, confirm the tests notice
```

## Read more

* [Getting started](docs/getting-started.md) — what each command shows, in plain language
* [Architecture](docs/architecture.md) — pipeline, memory map, performance, design decisions
* [Verification](docs/verification.md) — co-simulation, random tests, mutation testing, bugs found
* [Plan](docs/plan.md) — the six DOOM stages
