#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "nvim/grid_defs.h"  // IWYU pragma: keep
#include "nvim/macros_defs.h"
#include "nvim/types_defs.h"
#include "nvim/ui_defs.h"  // IWYU pragma: keep

// Temporary buffer for converting a single grid_line event
EXTERN size_t grid_line_buf_size INIT( = 0);
EXTERN schar_T *grid_line_buf_char INIT( = NULL);
EXTERN sattr_T *grid_line_buf_attr INIT( = NULL);

// Client-side UI channel. Zero during early startup or if not a (--remote-ui) UI client.
EXTERN uint64_t ui_client_channel_id INIT( = 0);

/// `status` argument of the last "error_exit" UI event, or -1 if none has been seen.
/// NOTE: This assumes "error_exit" never has a negative `status` argument.
EXTERN int ui_client_error_exit INIT( = -1);

/// Server exit code.
EXTERN int ui_client_exit_status INIT( = 0);

/// Whether ui client has sent nvim_ui_attach yet
EXTERN bool ui_client_attached INIT( = false);

/// The ui client should forward its stdin to the nvim process
/// by convention, this uses fd=3 (next free number after stdio)
EXTERN bool ui_client_forward_stdin INIT( = false);

#define UI_CLIENT_STDIN_FD 3
// uncrustify:off
# include "ui_client.h.generated.h"
# include "ui_events_client.h.generated.h"
// uncrustify:on

// Hand-written declarations (Odin owns all definitions; the generated
// headers vanish with the .c source, so these keep live C includers
// compiling on clean configures).
uint64_t ui_client_start_server(const char *exepath, size_t argc, char **argv);
void ui_client_attach(int width, int height, char *term, bool rgb);
void ui_client_detach(void);
void ui_client_run(void);
void ui_client_stop(void);
void ui_client_set_size(int width, int height);
UIClientHandler ui_client_get_redraw_handler(const char *name, size_t name_len, Error *error);
Object handle_ui_client_redraw(uint64_t channel_id, Array args, Arena *arena, Error *error);
void ui_client_event_grid_resize(Array args);
void ui_client_event_grid_line(Array args);
void ui_client_event_raw_line(GridLineEvent *g);
void ui_client_event_connect(Array args);
void ui_client_event_restart(Array args);
void ui_client_event__set_restart_on_crash_exit(Array args);
void ui_client_attach_to_restarted_server(bool error_restart);
void ui_client_event_error_exit(Array args);
