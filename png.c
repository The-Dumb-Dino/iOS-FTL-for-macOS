// png.c
//
// PNG images. The iPad build was compiled without its PNG reader (SIL's
// png_parse() is a stub that returns NULL): all its art ships as .tex textures.
// Mods add PC-style .png files (Hyperspace.ftl too), so hooks.c puts a real
// decoder behind it. From ftl-linux (native/src/ux/png.c).

#include "png.h"

#include <stdio.h>
#include <string.h>

#include "game.h"
#include "hooks.h"

#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_ASSERT(x) ((void)0)
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "third_party/stb_image.h"
#pragma clang diagnostic pop

// Returns straight-alpha RGBA pixels in a buffer from the game's allocator,
// which the caller frees with mem_free().
void *png_parse(const void *data, uint32_t size, int mem_flags, int *w_ret, int *h_ret) {
    int w, h, n;
    unsigned char *px = stbi_load_from_memory(data, (int)size, &w, &h, &n, 4);
    if (!px) {
        fprintf(stderr, "[ftlmac] png: can't decode image (%s)\n", stbi_failure_reason());
        return NULL;
    }
    void *(*mem_alloc)(size_t, unsigned, unsigned long) = (void *(*)(size_t, unsigned, unsigned long))game_addr(G_MEM_ALLOC);
    size_t bytes = (size_t)w * h * 4;
    void *out = mem_alloc(bytes, 0, (unsigned long)mem_flags & ~1ul);
    if (out) {
        memcpy(out, px, bytes);
        *w_ret = w;
        *h_ret = h;
    }
    stbi_image_free(px);
    return out;
}
