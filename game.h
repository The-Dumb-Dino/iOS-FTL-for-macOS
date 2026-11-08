// Addresses and struct offsets in FTL for iPad 1.6.21 (arm64 slice, LC_UUID
// 873d2b34-d707-3d6b-ab83-267bf4c5bbc0). Unslid vmaddrs (base 0x100000000).
// Taken from ftl-linux (native/src/ux/game.h). hooks.c checks the UUID first.
#pragma once

// ---- functions ----
#define G_LOG_FN 0x10006051cull      // printf-style logger, compiled to `ret`
#define G_POST_EVENT 0x100117268ull  // void post_event(sil_event *)
#define G_TIME_BASE 0x100250c88ull   // double, event timestamp base (s)
#define G_HOTKEY 0x100040728ull      // int (const std::string *action): `return 0` on iOS
// DoorBox::KeyDown: `cbz` that skips the open / close hotkey while that button is hidden
#define G_DOOR_KEY_OPEN 0x100097f9cull
#define G_DOOR_KEY_CLOSE 0x100097fe4ull
// The platform's input caps (4 instructions): the byte at +0x10 says whether a
// hardware keyboard is there; without one the game's key state reads as all up.
#define G_INPUT_CAPS 0x1001171a8ull
#define G_PNG_PARSE 0x1000092d0ull  // void *png_parse(const void *data, uint32_t size, int mem_flags, int *w, int *h): a stub
#define G_MEM_ALLOC 0x1001be780ull  // void *mem_alloc(size_t size, unsigned align, int flags): freed with mem_free
