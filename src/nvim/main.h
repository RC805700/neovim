#pragma once

#include <stdbool.h>

#include "nvim/types_defs.h"

// Maximum number of commands from + or -c arguments.
#define MAX_ARG_CMDS 10

extern Loop main_loop;

// Struct for various parameters passed between main() and other functions.
typedef struct {
  int argc;
  char **argv;

  char *use_vimrc;                      // vimrc from -u argument
  bool clean;                           // --clean argument

  int n_commands;                       // no. of commands from + or -c
  char *commands[MAX_ARG_CMDS];         // commands from + or -c arg
  char cmds_tofree[MAX_ARG_CMDS];       // commands that need free()
  int n_pre_commands;                   // no. of commands from --cmd
  char *pre_commands[MAX_ARG_CMDS];     // commands from --cmd argument
  char *luaf;                           // Lua script filename from "-l"
  int lua_arg0;                         // Lua script args start index.

  int edit_type;                        // type of editing to do
  char *tagname;                        // tag from -t argument
  char *use_ef;                         // 'errorfile' from -q argument

  bool input_istext;                    // stdin is text, not executable (-E/-Es)

  int no_swap_file;                     // "-n" argument used
  int use_debug_break_level;
  int window_count;                     // number of windows to use
  int window_layout;                    // 0, WIN_HOR, WIN_VER or WIN_TABS

  int diff_mode;                        // start with 'diff' set

  char *listen_addr;                    // --listen {address}
  int remote;                           // --remote-[subcmd] {file1} {file2}
  char *server_addr;                    // --server {address}
  char *scriptin;                       // -s {filename}
  char *scriptout;                      // -w/-W {filename}
  bool scriptout_append;                // append (-w) instead of overwrite (-W)
  bool had_stdin_file;                  // explicit - as a file to edit
} mparm_T;

// Startup sequence functions — called from Odin entry point.
// (static removed so they are exported from libnvim.a).
void init_path(const char *exename);
void early_init(mparm_T *paramp);
void command_line_scan(mparm_T *parmp);
void init_params(mparm_T *paramp, int argc, char **argv);
void init_startuptime(mparm_T *paramp);
void check_and_set_isatty(mparm_T *paramp);
void set_argf_var(void);
void create_windows(mparm_T *parmp);
void edit_buffers(mparm_T *parmp);
void exe_pre_commands(mparm_T *parmp);
void exe_commands(mparm_T *parmp);
void source_startup_scripts(const mparm_T *const parmp);
void remote_request(mparm_T *params, int remote_args, char *server_addr, int argc,
                    char **argv, bool ui_only);
bool edit_stdin(mparm_T *parmp);
char *get_fname(mparm_T *parmp);
void set_window_layout(mparm_T *paramp);
void handle_quickfix(mparm_T *paramp);
void handle_tag(char *tagname);
void read_stdin(void);

// Wrappers for Odin startup — expose struct-heavy inline logic.
int startup_gargcount(void);
void startup_set_cursor_last_line(void);
void startup_save_firstwin_height(void);
void startup_diff_win_options_all(void);
bool startup_shada_nonempty(void);
void startup_channel_from_stdio(void);
void startup_recovery_list_swaps(void);
void startup_setbuf_stdout_null(void);
void startup_restart_edit_check(void);
void startup_cb_flags_check(void);
void startup_diff_scrollbind_check(void);
void startup_exec_luaf(const char *luaf);

#if defined(MSWIN) && !defined(ENABLE_ASAN_UBSAN)
# define __asan_default_options vim__asan_default_options
# define __ubsan_default_options vim__ubsan_default_options
#endif

#include "main.h.generated.h"
