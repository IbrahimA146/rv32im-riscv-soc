# What this project put on your machine, and how to remove it

A complete record, so the laptop can be returned to its previous state after the
repository is pushed. Nothing here is needed to *read* the code on GitHub — only
to build and run it.

Last updated: 2026-10-04 (SDL2 added for interactive play)

---

## 1. Inside the project folder

Everything lives under `C:\Users\ibrah\Desktop\rv32-doom` (304 MB total).
Deleting that one folder removes all of it.

| Path | Size | What it is | In git? |
|---|---:|---|---|
| `build/` | 286 MB | Generated: compiled simulators, test programs, captured frames, `doom.mp4` | no (ignored) |
| `external/` | 12 MB | Downloaded: DOOM source + the shareware WAD | no (ignored) |
| `.git/` | 3 MB | The repository itself | — |
| everything else | ~3 MB | The actual work: RTL, firmware, tests, docs | **yes** |

**Only the last row matters.** It is all pushed to
https://github.com/IbrahimA146/rv32im-riscv-soc, so deleting the folder loses
nothing. `build/` is recreated by running the tests; `external/` by running
`python scripts/fetch_doom.py`.

To free space without deleting the project:

```bash
rm -rf build external          # or delete those two folders in File Explorer
```

---

## 2. Downloaded from the internet

Both land in `external/`, both are free to redistribute, neither is committed:

| What | Size | From | Why |
|---|---:|---|---|
| doomgeneric | 2 MB | github.com/ozkl/doomgeneric | DOOM source, reduced to a few platform hooks |
| doom1.wad | 4.2 MB | shareware DOOM 1 episode | the game data DOOM reads at startup |

---

## 3. Installed system-wide (MSYS2)

These were installed with MSYS2's package manager and are **outside** the
project folder, so deleting the project does not remove them.

| Package | Size | What it does |
|---|---:|---|
| `mingw-w64-ucrt-x86_64-riscv64-unknown-elf-gcc` | 783 MB | compiles C for the RISC-V CPU |
| `mingw-w64-ucrt-x86_64-riscv64-unknown-elf-newlib` | 262 MB | the C library that compiler links against |
| `mingw-w64-ucrt-x86_64-verilator` | 25 MB | turns the chip design into a fast simulator |
| `mingw-w64-ucrt-x86_64-riscv64-unknown-elf-binutils` | 17 MB | assembler and linker for RISC-V |
| `mingw-w64-ucrt-x86_64-iverilog` | 6 MB | the other simulator (used for cross-checking) |
| `mingw-w64-ucrt-x86_64-SDL2` (+ vulkan-loader) | ~40 MB | opens the window and reads the keyboard when playing |
| `make` | 1.6 MB | build runner |
| `perl-Pod-Parser` | 0.2 MB | pulled in while fixing a Verilator launcher issue |

Roughly **1.2 GB** in total.

### Removing them

Open **MSYS2 UCRT64** from the Start menu and run:

```bash
pacman -R mingw-w64-ucrt-x86_64-verilator mingw-w64-ucrt-x86_64-iverilog mingw-w64-ucrt-x86_64-riscv64-unknown-elf-gcc mingw-w64-ucrt-x86_64-riscv64-unknown-elf-newlib mingw-w64-ucrt-x86_64-riscv64-unknown-elf-binutils mingw-w64-ucrt-x86_64-SDL2 make perl-Pod-Parser
```

Two cautions:

* **`make` and `perl-Pod-Parser` are shared tools.** Other things you have may
  use them. Leave them installed unless you are sure; they are tiny.
* Do **not** uninstall MSYS2 itself if you use it for anything else — it was
  already on this machine before this project started.

The package manager also keeps a download cache (239 MB today), which is shared
with everything else you have ever installed through MSYS2. Clear it with:

```bash
pacman -Scc
```

---

## 4. Nothing else was touched

No system settings, no PATH changes, no services, no startup entries, no files
outside the project folder and the MSYS2 packages listed above.

---

## 5. Clean-slate checklist

1. Confirm the work is pushed: `git status` shows nothing to commit, and the
   GitHub page shows the latest commit.
2. Delete `C:\Users\ibrah\Desktop\rv32-doom`.
3. Optionally remove the MSYS2 packages above (~1.1 GB).
4. To work on it again later, anywhere:

   ```bash
   git clone https://github.com/IbrahimA146/rv32im-riscv-soc.git
   cd rv32im-riscv-soc
   python scripts/fetch_doom.py
   python scripts/run_tests.py
   ```
