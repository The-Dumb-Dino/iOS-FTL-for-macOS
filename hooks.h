// Game patches and game state, see hooks.c.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool hooks_active(void);           // the known build, and patching worked
void *game_addr(uint64_t addr);    // an address in game.h, slid
int code_write(void *dst, const void *src, size_t n);
void *code_alloc(size_t size);     // read + execute, within branch range of the game

// SIL key codes (the game's own numbering)
enum {
    SIL_A = 1, SIL_0 = 27, SIL_TAB = 37, SIL_ENTER = 38, SIL_SPACE = 39, SIL_QUOTE = 46,
    SIL_COMMA = 51, SIL_MINUS = 52, SIL_PERIOD = 53, SIL_SLASH = 54, SIL_SEMICOLON = 56,
    SIL_EQUALS = 58, SIL_LBRACKET = 62, SIL_BACKSLASH = 63, SIL_RBRACKET = 64, SIL_GRAVE = 67,
    SIL_LSHIFT = 75, SIL_RSHIFT = 76, SIL_LCTRL = 77, SIL_RCTRL = 78, SIL_LALT = 79, SIL_RALT = 80,
    SIL_LMETA = 81, SIL_RMETA = 82, SIL_CAPSLOCK = 86, SIL_BACKSPACE = 92, SIL_FORWARD_DEL = 95,
    SIL_HOME = 96, SIL_END = 97, SIL_PAGE_UP = 98, SIL_PAGE_DOWN = 99, SIL_UP = 100, SIL_DOWN = 101,
    SIL_LEFT = 102, SIL_RIGHT = 103, SIL_ESCAPE = 104, SIL_F1 = 105, SIL_NUMPAD_0 = 128,
    SIL_NUMPAD_ENTER = 144,
};
void game_key(int sil_code, bool down);  // main thread
double game_time_base_debug(double *now);

#ifdef __cplusplus
}
#endif
