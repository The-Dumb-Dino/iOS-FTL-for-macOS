// Hyperspace, when it's installed and the applied mods include it; see hyperspace.c.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void hyperspace_start(void);  // before the game's code runs; exits if it fails
// Right clicks for mods' scripts: action is HS_RIGHT_BUTTON_*, x and y the game's
// screen pixels (the drawable's)
bool hyperspace_wants_right_click(void);
void hyperspace_right_button(int action, int x, int y);

#ifdef __cplusplus
}
#endif
