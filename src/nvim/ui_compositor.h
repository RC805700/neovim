#pragma once

#include "nvim/api/private/defs.h"  // IWYU pragma: keep
#include "nvim/grid_defs.h"  // IWYU pragma: keep
#include "nvim/types_defs.h"  // IWYU pragma: keep
#include "nvim/ui_defs.h"  // IWYU pragma: keep

#include "ui_compositor.h.generated.h"

// Hand-written declarations (Odin owns all definitions; the generated
// header vanishes with the .c source, so these keep live C includers
// compiling on clean configures).
void ui_comp_init(void);
void ui_comp_syn_init(void);
void ui_comp_attach(RemoteUI *ui);
void ui_comp_detach(RemoteUI *ui);
bool ui_comp_should_draw(void);
void ui_comp_layers_adjust(size_t layer_idx, bool raise);
bool ui_comp_put_grid(ScreenGrid *grid, int row, int col, int height, int width, bool valid, bool on_top);
void ui_comp_remove_grid(ScreenGrid *grid);
bool ui_comp_set_grid(handle_T handle);
void ui_comp_raise_grid(ScreenGrid *grid, size_t new_index);
void ui_comp_grid_cursor_goto(Integer grid_handle, Integer r, Integer c);
ScreenGrid *ui_comp_mouse_focus(int row, int col);
ScreenGrid *ui_comp_get_grid_at_coord(int row, int col);
void ui_comp_compose_grid(ScreenGrid *grid);
void ui_comp_raw_line(Integer grid, Integer row, Integer startcol, Integer endcol, Integer clearcol, Integer clearattr, LineFlags flags, const schar_T *chunk, const sattr_T *attrs);
bool ui_comp_set_screen_valid(bool valid);
void ui_comp_msg_set_pos(Integer grid, Integer row, Boolean scrolled, String sep_char, Integer zindex, Integer compindex);
void ui_comp_grid_scroll(Integer grid, Integer top, Integer bot, Integer left, Integer right, Integer rows, Integer cols);
void ui_comp_grid_resize(Integer grid, Integer width, Integer height);
