#pragma once

#include <stdbool.h>

#include "nvim/decoration_defs.h"  // IWYU pragma: keep
#include "nvim/macros_defs.h"
#include "nvim/types_defs.h"  // IWYU pragma: keep

#include "decoration_provider.h.generated.h"

// Hand-written declarations (Odin owns all definitions; the generated
// header vanishes with the .c source, so these keep live C includers
// compiling on clean configures).
void decor_providers_invoke_spell(win_T *wp, int start_row, int start_col, int end_row, int end_col);
bool decor_providers_invoke_conceal_line(win_T *wp, int row);
void decor_providers_start(void);
void decor_providers_invoke_win(win_T *wp);
void decor_providers_invoke_line(win_T *wp, int row);
void decor_providers_invoke_range(win_T *wp, int start_row, int start_col, int end_row, int end_col);
void decor_providers_invoke_buf(buf_T *buf);
void decor_providers_invoke_end(void);
void decor_provider_invalidate_hl(void);
DecorProvider *get_decor_provider(NS ns_id, bool force);
void decor_provider_clear(DecorProvider *p);
void decor_free_all_mem(void);
