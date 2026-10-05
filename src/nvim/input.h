#pragma once

#include "nvim/event/defs.h"  // IWYU pragma: keep

#include "input.h.generated.h"

// Hand-written declarations for the input.c port (src/odin/input.odin).
// input.c was cut over to bak/, so input.h.generated.h no longer emits these.
// Signatures copied verbatim from the last generated header.
int ask_yesno(const char *const str);
int get_keystroke(MultiQueue *events);
int prompt_for_input(char *prompt, int hl_id, bool one_key, bool *mouse_used);
