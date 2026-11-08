// PNG support for the iPad build, which was compiled without it (see png.c).
#pragma once
#include <stdint.h>

// Takes the place of the game's png_parse (G_PNG_PARSE)
void *png_parse(const void *data, uint32_t size, int mem_flags, int *w_ret, int *h_ret);
