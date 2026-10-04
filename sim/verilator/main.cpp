// -----------------------------------------------------------------------------
// main.cpp - Verilator harness for soc_top
//
// Does the same jobs as sim/tb_soc.sv (load the image, decode the UART line,
// inject key events, capture frames, log the commit trace, print statistics)
// but drives the clock directly from C++ instead of through a coroutine
// testbench, which is what makes it fast enough to run DOOM.
//
// The RTL is identical; this is a second way to drive it, and the commit traces
// from the two simulators must match exactly.
// -----------------------------------------------------------------------------
#include "Vsoc_top.h"
#include "Vsoc_top___024root.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr uint32_t EXIT_ADDR = 0x30000000u;

struct Options {
    std::string hex, trace, frames, uart_in, keys;
    uint64_t timeout = 3000000;
    int      uart_div = 8;
    int      max_frames = 0;       // 0 = unlimited
    bool     quiet = false;
};

// ---------------------------------------------------------------- UART models
// Decodes the DUT's TX pin bit by bit, exactly like a USB-serial adapter.
class UartRx {
public:
    UartRx(int div, bool quiet) : div_(div), quiet_(quiet) {}

    void sample(uint8_t tx) {
        switch (state_) {
        case IDLE:
            if (!tx) { state_ = START; countdown_ = div_ / 2; }
            break;
        case START:
            if (--countdown_ <= 0) {
                if (tx) { state_ = IDLE; break; }      // glitch
                state_ = DATA; countdown_ = div_; bit_ = 0; shift_ = 0;
            }
            break;
        case DATA:
            if (--countdown_ <= 0) {
                shift_ |= (tx & 1) << bit_;
                countdown_ = div_;
                if (++bit_ == 8) state_ = STOP;
            }
            break;
        case STOP:
            if (--countdown_ <= 0) {
                emit(shift_);
                state_ = IDLE;
            }
            break;
        }
    }

    bool prompt_seen() { bool p = prompt_; prompt_ = false; return p; }
    const std::string &text() const { return text_; }

private:
    void emit(uint8_t c) {
        text_ += static_cast<char>(c);
        if (!quiet_ && c != '\r') { fputc(c, stdout); fflush(stdout); }
        if (prev_ == '>' && c == ' ') prompt_ = true;
        prev_ = c;
    }
    enum State { IDLE, START, DATA, STOP };
    State       state_ = IDLE;
    int         div_, countdown_ = 0, bit_ = 0;
    uint8_t     shift_ = 0, prev_ = 0;
    bool        quiet_, prompt_ = false;
    std::string text_;
};

// Types one comma-separated command per "> " prompt.
class UartTx {
public:
    UartTx(int div, const std::string &script) : div_(div) {
        if (script.empty()) return;
        size_t start = 0;
        while (start <= script.size()) {
            size_t comma = script.find(',', start);
            if (comma == std::string::npos) comma = script.size();
            lines_.push_back(script.substr(start, comma - start) + "\r");
            start = comma + 1;
        }
    }

    void on_prompt() { if (line_ < lines_.size()) { pending_ = true; delay_ = 50 * div_; } }

    uint8_t tick() {
        if (pending_ && --delay_ <= 0) { pending_ = false; sending_ = true; pos_ = 0; load(); }
        if (!sending_) return 1;
        if (--countdown_ <= 0) {                 // move to the next bit of the frame
            countdown_ = div_;
            if (++bits_ >= 10) {                 // start + 8 data + stop sent
                if (++pos_ >= lines_[line_].size()) { line_++; sending_ = false; return 1; }
                load();
            } else {
                level_ = frame_ & 1;
                frame_ >>= 1;
            }
        }
        return level_;
    }

    bool done() const { return line_ >= lines_.size() && !sending_ && !pending_; }

private:
    // 8N1: start bit, 8 data bits LSB first, stop bit
    void load() {
        frame_ = (1u << 9) | (static_cast<uint32_t>(lines_[line_][pos_] & 0xFF) << 1);
        bits_ = 0;
        countdown_ = div_;
        level_ = frame_ & 1;                     // start bit goes out first
        frame_ >>= 1;
    }
    int                      div_, countdown_ = 0, bits_ = 0, delay_ = 0;
    size_t                   line_ = 0, pos_ = 0;
    uint32_t                 frame_ = 0;
    uint8_t                  level_ = 1;
    bool                     pending_ = false, sending_ = false;
    std::vector<std::string> lines_;
};

// ------------------------------------------------------------------- helpers
bool load_hex(const std::string &path, Vsoc_top &dut, size_t words) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "ERROR: cannot open %s\n", path.c_str()); return false; }
    char line[64];
    size_t i = 0;
    while (fgets(line, sizeof line, f) && i < words)
        dut.rootp->soc_top__DOT__u_ram__DOT__mem[i++] = strtoul(line, nullptr, 16);
    fclose(f);
    return true;
}

void save_frame(Vsoc_top &dut, const std::string &prefix, uint32_t n, int w, int h) {
    char name[512];
    snprintf(name, sizeof name, "%s%04u.ppm", prefix.c_str(), n);
    FILE *f = fopen(name, "wb");
    if (!f) { fprintf(stderr, "ERROR: cannot write %s\n", name); return; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    const auto &pix = dut.rootp->soc_top__DOT__u_video__DOT__pix;
    const auto &pal = dut.rootp->soc_top__DOT__u_video__DOT__pal;
    std::vector<uint8_t> row(static_cast<size_t>(w) * 3);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t   idx = static_cast<size_t>(y) * w + x;
            uint8_t  ci  = (pix[idx >> 2] >> (8 * (idx & 3))) & 0xFF;
            uint32_t rgb = pal[ci];
            row[x * 3 + 0] = (rgb >> 16) & 0xFF;
            row[x * 3 + 1] = (rgb >> 8) & 0xFF;
            row[x * 3 + 2] = rgb & 0xFF;
        }
        fwrite(row.data(), 1, row.size(), f);
    }
    fclose(f);
}

const char *arg_value(int argc, char **argv, int &i) {
    const char *eq = strchr(argv[i], '=');
    if (eq) return eq + 1;
    if (i + 1 < argc) return argv[++i];
    return "";
}

}  // namespace

// Verilated runtime hook: this harness has no notion of wall-clock time.
double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Options opt;
    std::vector<int> key_codes;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto starts = [&](const char *p) { return a.rfind(p, 0) == 0; };
        if      (starts("--hex"))      opt.hex = arg_value(argc, argv, i);
        else if (starts("--trace"))    opt.trace = arg_value(argc, argv, i);
        else if (starts("--frames"))   opt.frames = arg_value(argc, argv, i);
        else if (starts("--uart-in"))  opt.uart_in = arg_value(argc, argv, i);
        else if (starts("--keys"))     opt.keys = arg_value(argc, argv, i);
        else if (starts("--timeout"))  opt.timeout = strtoull(arg_value(argc, argv, i), nullptr, 0);
        else if (starts("--uart-div")) opt.uart_div = atoi(arg_value(argc, argv, i));
        else if (starts("--max-frames")) opt.max_frames = atoi(arg_value(argc, argv, i));
        else if (starts("--quiet"))    opt.quiet = true;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (opt.hex.empty()) { fprintf(stderr, "usage: %s --hex=<image> [...]\n", argv[0]); return 2; }

    for (size_t p = 0; p < opt.keys.size();) {
        size_t comma = opt.keys.find(',', p);
        if (comma == std::string::npos) comma = opt.keys.size();
        key_codes.push_back(atoi(opt.keys.substr(p, comma - p).c_str()));
        p = comma + 1;
    }

    Verilated::commandArgs(argc, argv);
    Vsoc_top dut;

    // One eval first: the RTL's initial blocks (which clear memories) run on
    // the first evaluation, so loading the image before this would be undone.
    dut.clk_i = 0;
    dut.rst_ni = 0;
    dut.eval();

    if (!load_hex(opt.hex, dut, RAM_WORDS)) return 2;

    FILE *trace = opt.trace.empty() ? nullptr : fopen(opt.trace.c_str(), "w");
    UartRx uart_rx(opt.uart_div, opt.quiet);
    UartTx uart_tx(opt.uart_div, opt.uart_in);

    dut.clk_i = 0;
    dut.rst_ni = 0;
    dut.uart_rx_i = 1;
    dut.gpio_i = 0xA5A50000;
    dut.key_valid_i = 0;
    dut.key_event_i = 0;

    uint64_t cycles = 0, instret = 0;
    uint32_t frames = 0;
    size_t   key_i = 0;
    uint64_t next_key = 20000;
    bool     key_down = false;
    int      exit_code = -1;

    auto tick = [&](int v) { dut.clk_i = v; dut.eval(); };

    for (uint64_t c = 0; c < opt.timeout; c++) {
        if (c == 5) dut.rst_ni = 1;

        // stimulus changes between edges, like the falling-edge driving in the
        // SystemVerilog testbench
        tick(0);
        dut.uart_rx_i = uart_tx.tick();
        dut.key_valid_i = 0;
        if (dut.rst_ni && key_i < key_codes.size() && c >= next_key) {
            dut.key_valid_i = 1;
            dut.key_event_i = static_cast<uint16_t>((key_down ? 0 : 0x100) | (key_codes[key_i] & 0xFF));
            if (key_down) { key_i++; key_down = false; } else { key_down = true; }
            next_key = c + 20000;
        }
        tick(1);

        if (!dut.rst_ni) continue;
        cycles++;

        uart_rx.sample(dut.uart_tx_o);
        if (uart_rx.prompt_seen()) uart_tx.on_prompt();

        auto *root = dut.rootp;
        if (root->soc_top__DOT__u_core__DOT__wb_valid) {
            instret++;
            uint32_t pc   = root->soc_top__DOT__u_core__DOT__wb_pc;
            uint32_t insn = root->soc_top__DOT__u_core__DOT__wb_insn;
            uint32_t addr = root->soc_top__DOT__u_core__DOT__wb_mem_addr;
            if (trace) {
                if (root->soc_top__DOT__u_core__DOT__wb_mem_we) {
                    uint32_t sz   = root->soc_top__DOT__u_core__DOT__wb_mem_size;
                    uint32_t mask = sz == 0 ? 0xFF : sz == 1 ? 0xFFFF : 0xFFFFFFFF;
                    fprintf(trace, "%08x %08x mem %08x %08x\n", pc, insn, addr,
                            root->soc_top__DOT__u_core__DOT__wb_mem_wdata & mask);
                } else if (root->soc_top__DOT__u_core__DOT__wb_reg_we) {
                    fprintf(trace, "%08x %08x x%u %08x\n", pc, insn,
                            root->soc_top__DOT__u_core__DOT__wb_rd,
                            root->soc_top__DOT__u_core__DOT__wb_value);
                } else {
                    fprintf(trace, "%08x %08x\n", pc, insn);
                }
            }
            if (root->soc_top__DOT__u_core__DOT__wb_mem_we && addr == EXIT_ADDR) {
                exit_code = static_cast<int>(root->soc_top__DOT__u_core__DOT__wb_mem_wdata);
                break;
            }
        }

        if (dut.frame_strobe_o && !opt.frames.empty()) {
            save_frame(dut, opt.frames, dut.frame_count_o, VID_WIDTH, VID_HEIGHT);
            if (opt.max_frames && ++frames >= static_cast<uint32_t>(opt.max_frames)) {
                exit_code = 0;
                break;
            }
        }
    }

    dut.final();
    if (trace) fclose(trace);

    uint32_t branches = dut.rootp->soc_top__DOT__u_core__DOT__u_csr__DOT__hpm3_q;
    uint32_t misses   = dut.rootp->soc_top__DOT__u_core__DOT__u_csr__DOT__hpm4_q;
    printf("\n---------------------------------------------------------------\n");
    printf(" cycles        : %llu\n", (unsigned long long)cycles);
    printf(" instructions  : %llu\n", (unsigned long long)instret);
    if (instret)
        printf(" CPI           : %llu.%03llu\n", (unsigned long long)(cycles / instret),
               (unsigned long long)((cycles % instret) * 1000 / instret));
    if (branches)
        printf(" branch pred.  : %u/%u correct (%u.%u%%)\n", branches - misses, branches,
               (branches - misses) * 100 / branches, ((branches - misses) * 1000 / branches) % 10);
    printf("---------------------------------------------------------------\n");

    if (exit_code < 0) {
        printf("*** TIMEOUT after %llu cycles ***\n", (unsigned long long)cycles);
        return 3;
    }
    if (exit_code == 0) printf("*** PASS ***\n");
    else                printf("*** FAIL (exit code %d) ***\n", exit_code);
    return exit_code == 0 ? 0 : 1;
}
