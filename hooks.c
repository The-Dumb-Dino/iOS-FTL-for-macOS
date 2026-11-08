// hooks.c
//
// Patches the game's code at startup, before main() runs: keyboard shortcuts,
// the door hotkeys and the game's logger. Also posts key events to the game.
// The addresses (game.h) are for FTL for iPad 1.6.21 only; any other build
// runs without these patches.
//
// Writing code: the game's __TEXT is mapped from the signed file, and
// mprotect() refuses to make it writable (EACCES). vm_protect() with
// VM_PROT_COPY gives the process a private copy of the page instead, which
// can then be made executable again. Trampolines live in anonymous pages
// allocated within branch range (+-128 MB) of the game.

#include "hooks.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <libkern/OSCacheControl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game.h"
#include "hyperspace.h"
#include "png.h"

extern const struct mach_header_64 *_NSGetMachExecuteHeader(void);

static intptr_t g_slide;
static bool g_ok;  // the known build, patched
static uintptr_t g_image_start, g_image_end;

#define GAME(addr) ((void *)((uintptr_t)(addr) + g_slide))

// ---------------------------------------------------------------------------------
// writing code

int code_write(void *dst, const void *src, size_t n) {
    vm_size_t page = vm_page_size;
    vm_address_t start = (uintptr_t)dst & ~(page - 1);
    vm_size_t len = (((uintptr_t)dst + n + page - 1) & ~(page - 1)) - start;
    kern_return_t kr = vm_protect(mach_task_self(), start, len, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[ftlmac] vm_protect(RW) at %p failed: %d\n", dst, kr);
        return -1;
    }
    memcpy(dst, src, n);
    kr = vm_protect(mach_task_self(), start, len, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(dst, n);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[ftlmac] vm_protect(RX) at %p failed: %d\n", dst, kr);
        return -1;
    }
    return 0;
}

// Executable memory within branch range of the game: the free gap closest
// to it, found by walking the address space. Returned read + execute; fill it
// with code_write.
void *code_alloc(size_t size) {
    const uint64_t reach = 120ull << 20, align = 0x10000;
    size = (size + align - 1) & ~(align - 1);
    uint64_t lo = g_image_start > reach ? g_image_start - reach : 0, hi = g_image_end + reach;
    struct { uint64_t at, dist; } cand[64];
    int n = 0;
    vm_address_t at = lo, prev_end = lo;
    for (;;) {
        vm_size_t len = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        bool more = vm_region_64(mach_task_self(), &at, &len, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                   &count, &obj) == KERN_SUCCESS;
        uint64_t gap_lo = (prev_end + align - 1) & ~(align - 1), gap_hi = more ? at : hi;
        if (gap_hi > hi) gap_hi = hi;
        if (gap_hi > gap_lo && gap_hi - gap_lo >= size && n < 64) {
            // the end of the gap next to the game
            uint64_t a = gap_lo >= g_image_end ? gap_lo : ((gap_hi - size) & ~(align - 1));
            uint64_t d = a >= g_image_end ? a + size - g_image_start : g_image_end - a;
            if (a >= gap_lo && d < reach) cand[n++] = (typeof(cand[0])){a, d};
        }
        if (!more || at >= hi) break;
        prev_end = at + len;
        at = prev_end;
    }
    // closest first; some gaps can't be allocated (the reserved space below the image)
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && cand[j].dist < cand[j - 1].dist; j--) {
            typeof(cand[0]) t = cand[j];
            cand[j] = cand[j - 1];
            cand[j - 1] = t;
        }
    for (int i = 0; i < n; i++) {
        vm_address_t a = cand[i].at;
        if (vm_allocate(mach_task_self(), &a, size, VM_FLAGS_FIXED) != KERN_SUCCESS) continue;
        if (vm_protect(mach_task_self(), a, size, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS)
            return (void *)a;
        vm_deallocate(mach_task_self(), a, size);
    }
    fprintf(stderr, "[ftlmac] no executable memory near the game\n");
    return NULL;
}

// A small pool of trampolines.
static uint8_t *g_tramp;
static size_t g_tramp_used;

// Replace the instruction at `addr` (unslid) with a branch to `target`,
// through a trampoline that jumps via x17 (like ftl-linux, so Hyperspace,
// which jumps through x16, can hook the same functions later).
static int patch_branch(uint64_t addr, void *target) {
    uint32_t *code = GAME(addr);
    if (!g_tramp && !(g_tramp = code_alloc(vm_page_size))) return -1;
    if (g_tramp_used + 16 > vm_page_size) return -1;
    uint32_t jump[4] = {0x58000051, 0xD61F0220};  // ldr x17, #8; br x17
    memcpy(&jump[2], &target, 8);
    uint8_t *t = g_tramp + g_tramp_used;
    if (code_write(t, jump, sizeof jump)) return -1;
    g_tramp_used += 16;
    intptr_t delta = (intptr_t)(t - (uint8_t *)code);
    if (delta >= (1 << 27) || delta < -(1 << 27)) return -1;
    uint32_t b = 0x14000000u | ((uint32_t)(delta >> 2) & 0x03ffffffu);
    return code_write(code, &b, 4);
}

// ---------------------------------------------------------------------------------
// the game's logger

static void game_log(const char *fmt, ...) {
    char buf[1024];
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);  // the game was built for the same (Apple arm64) variadic ABI
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    fprintf(stderr, "[FTL] %s\n", buf);
}

// ---------------------------------------------------------------------------------
// keyboard shortcuts: the iOS build keeps the desktop hotkey handling but its
// binding lookup always answers 0. Answer with the desktop game's defaults
// (SDL 1.2 keysyms), as ftl-linux does.

enum { K_SPACE = 32, K_F1 = 282 };
static const struct { const char *action; int key; } HOTKEYS[] = {
    {"pause", K_SPACE}, {"jump", 'j'}, {"ship_info", 'u'}, {"ship_crew", 'c'}, {"ship_inv", 'i'},
    {"autofire", 'v'}, {"open", 'z'}, {"close", 'x'}, {"send_tele", 't'}, {"ret_tele", 'r'},
    {"lockdown", 'l'}, {"savePositions", '['}, {"loadPositions", ']'}, {"crew_all", '`'},
    // systems (Shift + key removes power)
    {"shields", 'a'}, {"engines", 's'}, {"oxygen", 'f'}, {"medbay", 'd'}, {"clonebay", 'd'},
    {"weapons", 'w'}, {"drones", 'e'}, {"teleporter", 'g'}, {"cloaking", 'h'}, {"artillery", 'y'},
    {"battery", 'b'}, {"mind", 'n'}, {"hacking", 'm'},
    // weapon slots then drone slots (Shift + key removes power)
    {"power_1", '1'}, {"power_2", '2'}, {"power_3", '3'}, {"power_4", '4'},
    {"power_5", '5'}, {"power_6", '6'}, {"power_7", '7'}, {"power_8", '8'},
    {"crew1", K_F1}, {"crew2", K_F1 + 1}, {"crew3", K_F1 + 2}, {"crew4", K_F1 + 3},
    {"crew5", K_F1 + 4}, {"crew6", K_F1 + 5}, {"crew7", K_F1 + 6}, {"crew8", K_F1 + 7},
    // Hyperspace's command console, for mods that turn it on (Multiverse does)
    {"console", '\\'},
};

// libc++ std::string (Apple's alternate layout)
static const char *cxx_str(const void *s, size_t *len) {
    const uint8_t *b = s;
    if (b[23] & 0x80) {
        *len = *(const size_t *)(b + 8);
        return *(const char *const *)b;
    }
    *len = b[23];
    return (const char *)b;
}

static bool g_debug;  // FTLMAC_DEBUG: log keys and hotkey lookups

static int hotkey_lookup(const void *action) {
    if (!action) return 0;
    size_t n;
    const char *a = cxx_str(action, &n);
    int key = 0;
    for (size_t i = 0; i < sizeof HOTKEYS / sizeof *HOTKEYS && !key; i++)
        if (strlen(HOTKEYS[i].action) == n && !memcmp(HOTKEYS[i].action, a, n)) key = HOTKEYS[i].key;
    if (g_debug) fprintf(stderr, "[ftlmac] hotkey '%.*s' -> %d\n", (int)n, a, key);
    return key;
}

// ---------------------------------------------------------------------------------
// setup

static const uint8_t KNOWN_UUID[16] = {0x87, 0x3d, 0x2b, 0x34, 0xd7, 0x07, 0x3d, 0x6b,
                                       0xab, 0x83, 0x26, 0x7b, 0xf4, 0xc5, 0xbb, 0xc0};

// Checks the build, sets the slide and the image's end.
static bool known_build(const struct mach_header_64 *h) {
    bool uuid_ok = false;
    uint64_t text_vmaddr = 0, end = 0;
    const uint8_t *lc = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *c = (const void *)lc;
        if (c->cmd == LC_UUID) uuid_ok = !memcmp(((const struct uuid_command *)c)->uuid, KNOWN_UUID, 16);
        if (c->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *s = (const void *)c;
            if (!strcmp(s->segname, "__TEXT")) text_vmaddr = s->vmaddr;
            if (s->vmaddr + s->vmsize > end) end = s->vmaddr + s->vmsize;
        }
        lc += c->cmdsize;
    }
    g_slide = (intptr_t)h - (intptr_t)text_vmaddr;
    g_image_start = (uintptr_t)h;
    g_image_end = (uintptr_t)(end + g_slide);
    return uuid_ok && text_vmaddr == 0x100000000ull;
}

// Whether the code at addr is what this build has there (`n` words).
static bool expect(uint64_t addr, const uint32_t *words, size_t n) { return !memcmp(GAME(addr), words, n * 4); }
#define EXPECT(addr, ...) expect(addr, (const uint32_t[]){__VA_ARGS__}, sizeof((uint32_t[]){__VA_ARGS__}) / 4)

static void apply(void) {
    g_debug = getenv("FTLMAC_DEBUG") != NULL;
    const struct mach_header_64 *h = _NSGetMachExecuteHeader();
    if (!h || h->magic != MH_MAGIC_64 || !known_build(h)) {
        fprintf(stderr, "[ftlmac] not the FTL 1.6.21 iPad build; keyboard and logger hooks disabled\n");
        return;
    }
    int fails = 0;
    if (EXPECT(G_LOG_FN, 0xD65F03C0u))  // ret
        fails += patch_branch(G_LOG_FN, (void *)game_log) != 0;
    else
        fprintf(stderr, "[ftlmac] unexpected code at the game's logger; not hooking it\n");
    if (EXPECT(G_HOTKEY, 0x52800000u, 0xD65F03C0u))  // mov w0, #0; ret
        fails += patch_branch(G_HOTKEY, (void *)hotkey_lookup) != 0;
    else
        fprintf(stderr, "[ftlmac] unexpected code at the hotkey lookup; keyboard shortcuts disabled\n");
    // The open/close-all-doors keys are tied to the door control buttons, which
    // the iPad build only shows in door mode. Accept them any time, like the
    // desktop game; the ship still checks that the door system is working.
    if (EXPECT(G_DOOR_KEY_OPEN, 0x34000228u) && EXPECT(G_DOOR_KEY_CLOSE, 0x34000228u)) {  // cbz w8, ...
        uint32_t nop = 0xD503201Fu;
        fails += code_write(GAME(G_DOOR_KEY_OPEN), &nop, 4) != 0;
        fails += code_write(GAME(G_DOOR_KEY_CLOSE), &nop, 4) != 0;
    } else {
        fprintf(stderr, "[ftlmac] unexpected code in the door hotkeys; Z/X only work in door mode\n");
    }
    // The iOS platform layer reports "no hardware keyboard" every frame, and
    // while it does the game ignores held keys, so Shift + hotkey (remove
    // power) never works. Report one: same instructions, reordered so the
    // flag gets w8's low byte (1) instead of wzr.
    uint32_t *caps = GAME(G_INPUT_CAPS);
    static const uint32_t caps_ios[4] = {
        0x3900427fu,  // strb wzr, [x19, #0x10]  keyboard: no
        0x39004a7fu,  // strb wzr, [x19, #0x12]
        0x3200c3e8u,  // mov w8, #0x1010101
        0xb8013268u,  // stur w8, [x19, #0x13]
    };
    static const uint32_t caps_mac[4] = {
        0x3200c3e8u,  // mov w8, #0x1010101
        0x39004268u,  // strb w8, [x19, #0x10]   keyboard: yes
        0x39004a7fu,  // strb wzr, [x19, #0x12]
        0xb8013268u,  // stur w8, [x19, #0x13]
    };
    if (expect(G_INPUT_CAPS, caps_ios, 4))
        fails += code_write(caps, caps_mac, sizeof caps_mac) != 0;
    else
        fprintf(stderr, "[ftlmac] unexpected code in the input caps; Shift + hotkey won't remove power\n");
    // PNG images from mods (png.c)
    if (EXPECT(G_PNG_PARSE, 0xD2800000u, 0xD65F03C0u))  // mov x0, #0; ret
        fails += patch_branch(G_PNG_PARSE, (void *)png_parse) != 0;
    else
        fprintf(stderr, "[ftlmac] unexpected code at png_parse; PNG images from mods won't load\n");
    g_ok = fails == 0;
    fprintf(stderr, "[ftlmac] FTL 1.6.21, slide %#lx: hooks %s\n", (long)g_slide, g_ok ? "applied" : "FAILED");
}

// Runs before the game's main(), while only this thread exists. Hyperspace hooks
// the game after these patches (some of the same functions), as on ftl-linux.
__attribute__((constructor)) static void hooks_init(void) {
    apply();
    hyperspace_start();
}

bool hooks_active(void) { return g_ok; }

void *game_addr(uint64_t addr) { return GAME(addr); }

// ---------------------------------------------------------------------------------
// game state and events (main thread)

typedef struct {
    int32_t cls, type;
    double time;
    int32_t i0;  // key code
    float f1, f2, f3, f4;
    int32_t i5;
} sil_event;
_Static_assert(sizeof(sil_event) == 40, "sil_event");
enum { SIL_CLS_KEY = 2, SIL_KEY_DOWN = 7, SIL_KEY_UP = 8 };

// The game's event clock: mach_absolute_time in seconds.
static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}

void game_key(int sil_code, bool down) {
    if (!g_ok || sil_code <= 0) return;
    if (g_debug) fprintf(stderr, "[ftlmac] key %d %s\n", sil_code, down ? "down" : "up");
    sil_event e = {SIL_CLS_KEY, down ? SIL_KEY_DOWN : SIL_KEY_UP, 0, sil_code, 0, 0, 0, 0, 0};
    double base = *(double *)GAME(G_TIME_BASE);
    e.time = base > 0 ? now_s() - base : 0;
    ((void (*)(sil_event *))GAME(G_POST_EVENT))(&e);
}

double game_time_base_debug(double *now) {
    *now = now_s();
    return g_ok ? *(double *)GAME(G_TIME_BASE) : -1;
}
