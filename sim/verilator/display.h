// -----------------------------------------------------------------------------
// display.h - live window and keyboard for the simulated SoC (SDL2)
//
// Interactive mode turns the harness into something you can actually play on:
// the framebuffer is blitted to a window whenever the chip presents a frame,
// and host key presses are converted into the scancodes the SoC's keyboard
// device delivers, exactly as the testbench injects them in batch mode.
//
// Built only when SDL2 is available (-DUSE_SDL); without it the harness still
// compiles and runs headless.
// -----------------------------------------------------------------------------
#ifndef DISPLAY_H
#define DISPLAY_H

#include <cstdint>
#include <deque>

#ifdef USE_SDL

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>

class Display {
public:
    bool open(int w, int h, int scale) {
        w_ = w;
        h_ = h;
        SDL_SetMainReady();
        if (SDL_Init(SDL_INIT_VIDEO) != 0) {
            fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
            return false;
        }
        window_ = SDL_CreateWindow("DOOM on rv32im (RTL simulation)",
                                   SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                   w * scale, h * scale, SDL_WINDOW_SHOWN);
        if (!window_) {
            fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
            return false;
        }
        renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED);
        if (!renderer_)
            renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_SOFTWARE);
        texture_ = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_ARGB8888,
                                     SDL_TEXTUREACCESS_STREAMING, w, h);
        pixels_.resize(static_cast<size_t>(w) * h);
        return renderer_ && texture_;
    }

    void close() {
        if (texture_) SDL_DestroyTexture(texture_);
        if (renderer_) SDL_DestroyRenderer(renderer_);
        if (window_) SDL_DestroyWindow(window_);
        SDL_Quit();
    }

    // Convert one presented frame (colour indices + palette) and show it.
    template <typename PixArray, typename PalArray>
    void present(const PixArray &pix, const PalArray &pal) {
        for (size_t i = 0; i < pixels_.size(); i++) {
            uint8_t index = (pix[i >> 2] >> (8 * (i & 3))) & 0xFF;
            pixels_[i] = 0xFF000000u | pal[index];
        }
        SDL_UpdateTexture(texture_, nullptr, pixels_.data(), w_ * 4);
        SDL_RenderCopy(renderer_, texture_, nullptr, nullptr);
        SDL_RenderPresent(renderer_);
    }

    void set_title(const char *text) {
        if (window_) SDL_SetWindowTitle(window_, text);
    }

    // Drain host input. Returns false when the window is closed.
    bool poll(std::deque<uint16_t> &key_events) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT)
                return false;
            if (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) {
                if (e.key.repeat)
                    continue;
                uint8_t code = scancode(e.key.keysym.scancode);
                if (code)
                    key_events.push_back((e.type == SDL_KEYDOWN ? 0x100 : 0) | code);
            }
        }
        return true;
    }

private:
    // Host key -> the scancodes fw/apps/doom/main.c maps onto DOOM's keys.
    static uint8_t scancode(SDL_Scancode sc) {
        switch (sc) {
        case SDL_SCANCODE_ESCAPE:    return 1;
        case SDL_SCANCODE_RETURN:    return 28;
        case SDL_SCANCODE_SPACE:     return 57;
        case SDL_SCANCODE_LCTRL:
        case SDL_SCANCODE_RCTRL:     return 29;
        case SDL_SCANCODE_LALT:
        case SDL_SCANCODE_RALT:      return 56;
        case SDL_SCANCODE_LSHIFT:
        case SDL_SCANCODE_RSHIFT:    return 42;
        case SDL_SCANCODE_UP:        return 72;
        case SDL_SCANCODE_DOWN:      return 80;
        case SDL_SCANCODE_LEFT:      return 75;
        case SDL_SCANCODE_RIGHT:     return 77;
        case SDL_SCANCODE_W:         return 17;
        case SDL_SCANCODE_A:         return 30;
        case SDL_SCANCODE_S:         return 31;
        case SDL_SCANCODE_D:         return 32;
        case SDL_SCANCODE_P:         return 25;
        case SDL_SCANCODE_Y:         return 21;
        case SDL_SCANCODE_N:         return 49;
        default:                     return 0;
        }
    }

    SDL_Window   *window_ = nullptr;
    SDL_Renderer *renderer_ = nullptr;
    SDL_Texture  *texture_ = nullptr;
    std::vector<uint32_t> pixels_;
    int w_ = 0, h_ = 0;
};

#else  // no SDL: a stub so the harness still builds headless

class Display {
public:
    bool open(int, int, int) {
        fprintf(stderr, "this build has no SDL2 support: rebuild with --sdl\n");
        return false;
    }
    void close() {}
    template <typename PixArray, typename PalArray>
    void present(const PixArray &, const PalArray &) {}
    void set_title(const char *) {}
    bool poll(std::deque<uint16_t> &) { return false; }
};

#endif  // USE_SDL
#endif  // DISPLAY_H
