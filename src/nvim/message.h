#pragma once

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>  // IWYU pragma: keep

#include "nvim/ex_cmds_defs.h"  // IWYU pragma: keep
#include "nvim/grid_defs.h"
#include "nvim/macros_defs.h"
#include "nvim/message_defs.h"  // IWYU pragma: keep

/// Types of dialogs passed to do_dialog().
enum {
  VIM_GENERIC   = 0,
  VIM_ERROR     = 1,
  VIM_WARNING   = 2,
  VIM_INFO      = 3,
  VIM_QUESTION  = 4,
  VIM_LAST_TYPE = 4,  ///< sentinel value
};

/// Return values for functions like vim_dialogyesno()
enum {
  VIM_YES        = 2,
  VIM_NO         = 3,
  VIM_CANCEL     = 4,
  VIM_ALL        = 5,
  VIM_DISCARDALL = 6,
};

extern MessageHistoryEntry *msg_hist_last;

EXTERN bool msg_ext_need_clear INIT( = false);
/// Set to true to force grouping a set of message chunks into a single `cmdline_show` event.
EXTERN bool msg_ext_skip_flush INIT( = false);
/// Set to true when previous message should be overwritten.
EXTERN bool msg_ext_overwrite INIT( = false);
/// Set to true to avoid setting "verbose" kind for "last set" messages.
EXTERN bool msg_ext_skip_verbose INIT( = false);
/// Set to false for non-internal messages to determine UI callback |api-fast| context.
EXTERN bool msg_ext_fast INIT( = true);

/// allocated grid for messages. Used unless ext_messages is active.
/// See also the description at msg_scroll_flush()
EXTERN ScreenGrid msg_grid INIT( = SCREEN_GRID_INIT);
EXTERN int msg_grid_pos INIT( = 0);

/// "adjusted" message grid. This grid accepts positions relative to
/// default_grid. Internally it will be translated to a position on msg_grid
/// relative to the start of the message area, or directly mapped to default_grid
/// for legacy (display-=msgsep) message scroll behavior.
/// TODO(bfredl): refactor "internal" message logic, msg_row etc
/// to use the correct positions already.
EXTERN GridView msg_grid_adj INIT( = { 0 });

/// value of msg_scrolled at latest msg_scroll_flush.
EXTERN int msg_scrolled_at_flush INIT( = 0);

EXTERN int msg_grid_scroll_discount INIT( = 0);

EXTERN int msg_listdo_overwrite INIT( = 0);

#include "message.h.generated.h"

// Hand-added prototypes (message.c ported to Odin; generated header
// no longer provides these after cutover). See ex_docmd.h precedent.
DLLEXPORT bool msg_id_exists(int64_t id);
DLLEXPORT void msg_grid_set_pos(int row, bool scrolled);
DLLEXPORT bool msg_use_grid(void);
DLLEXPORT void msg_grid_validate(void);
DLLEXPORT int verb_msg(const char *s);
DLLEXPORT bool msg(const char *s, const int hl_id) FUNC_ATTR_NONNULL_ARG(1);
DLLEXPORT void msg_multiline(String str, int hl_id, bool check_int, bool hist, bool *need_clear) FUNC_ATTR_NONNULL_ALL;
DLLEXPORT MsgID msg_multihl(MsgID id, HlMessage hl_msg, const char *kind, bool history, bool err, MessageData *msg_data, bool *needs_msg_clear);
DLLEXPORT bool msg_keep(const char *s, int hl_id, bool keep, bool multiline) FUNC_ATTR_NONNULL_ALL;
DLLEXPORT char *msg_strtrunc(const char *s, int force);
DLLEXPORT void trunc_string(const char *s, char *buf, int room_in, int buflen);
DLLEXPORT MessageHistoryEntry *nvim_odin_hist_first(void);
DLLEXPORT void nvim_odin_hist_first_set(MessageHistoryEntry *e);
DLLEXPORT MessageHistoryEntry *nvim_odin_hist_temp(void);
DLLEXPORT void nvim_odin_hist_temp_set(MessageHistoryEntry *e);
DLLEXPORT MessageHistoryEntry *nvim_odin_hist_last(void);
DLLEXPORT void nvim_odin_hist_last_set(MessageHistoryEntry *e);
DLLEXPORT int nvim_odin_hist_len(void);
DLLEXPORT void nvim_odin_hist_len_set(int n);
DLLEXPORT bool nvim_odin_do_clear_hist_temp(void);
DLLEXPORT void nvim_odin_do_clear_hist_temp_set(bool v);
DLLEXPORT int smsg(int hl_id, const char *s, ...) FUNC_ATTR_PRINTF(2, 3);
DLLEXPORT int smsg_keep(int hl_id, const char *s, ...) FUNC_ATTR_PRINTF(2, 3);
DLLEXPORT void reset_last_sourcing(void);
DLLEXPORT void msg_source(int hl_id);
DLLEXPORT bool emsg_multiline(const char *s, const char *kind, int hl_id, bool multiline);
DLLEXPORT bool emsg(const char *s);
DLLEXPORT void emsg_invreg(int name);
DLLEXPORT bool semsg(const char *const fmt, ...) FUNC_ATTR_PRINTF(1, 2);
DLLEXPORT bool semsg_multiline(const char *kind, const char *const fmt, ...);
DLLEXPORT void iemsg(const char *s);
DLLEXPORT void siemsg(const char *s, ...);
DLLEXPORT void internal_error(const char *where);
DLLEXPORT void msg_schedule_semsg(const char *const fmt, ...) FUNC_ATTR_PRINTF(1, 2);
DLLEXPORT void msg_schedule_semsg_multiline(const char *const fmt, ...);
DLLEXPORT char *msg_trunc(char *s, bool force, int hl_id);
DLLEXPORT char *msg_may_trunc(bool force, char *s);
DLLEXPORT char *msg_progress(char *s, char *id, char *status, int hl_id, bool hist, bool trunc);
DLLEXPORT void hl_msg_free(HlMessage hl_msg);
DLLEXPORT void do_autocmd_progress(MsgID msg_id, HlMessage msg, MessageData *msg_data);
DLLEXPORT void msg_hist_clear(int keep);
DLLEXPORT void msg_hist_clear_temp(void);
DLLEXPORT int messagesopt_changed(void);
DLLEXPORT void ex_messages(exarg_T *eap) FUNC_ATTR_NONNULL_ALL;
DLLEXPORT void msg_end_prompt(void);
DLLEXPORT void wait_return(int redraw);
DLLEXPORT void set_keep_msg(const char *s, int hl_id);
DLLEXPORT bool messaging(void);
DLLEXPORT void msgmore(int n);
DLLEXPORT void msg_ext_set_kind(const char *msg_kind);
DLLEXPORT void msg_ext_set_append(bool append);
DLLEXPORT void msg_ext_set_trigger(const char *trigger);
DLLEXPORT void msg_ext_no_fast(void);
DLLEXPORT void msg_start(void);
DLLEXPORT void msg_starthere(void);
DLLEXPORT void msg_putchar(int c);
DLLEXPORT void msg_putchar_hl(int c, int hl_id);
DLLEXPORT void msg_outnum(int n);
DLLEXPORT void msg_home_replace(const char *fname);
DLLEXPORT int msg_outtrans(const char *str, int hl_id, bool hist);
DLLEXPORT const char *msg_outtrans_one(const char *p, int hl_id, bool hist);
DLLEXPORT int msg_outtrans_len(const char *msgstr, int len, int hl_id, bool hist);
DLLEXPORT void msg_make(const char *arg);
DLLEXPORT int msg_outtrans_special(const char *strstart, bool from, int maxlen);
DLLEXPORT char *str2special_save(const char *const str, const bool replace_spaces, const TriState replace_others) FUNC_ATTR_NONNULL_ALL FUNC_ATTR_WARN_UNUSED_RESULT FUNC_ATTR_MALLOC FUNC_ATTR_NONNULL_RET;
DLLEXPORT char *str2special_arena(const char *const str, const bool replace_spaces, const TriState replace_others, Arena *const arena) FUNC_ATTR_NONNULL_ALL FUNC_ATTR_WARN_UNUSED_RESULT FUNC_ATTR_MALLOC FUNC_ATTR_NONNULL_RET;
DLLEXPORT const char *str2special(const char **const sp, const bool replace_spaces, const TriState replace_others) FUNC_ATTR_NONNULL_ALL FUNC_ATTR_WARN_UNUSED_RESULT FUNC_ATTR_NONNULL_RET;
DLLEXPORT void str2specialbuf(const char *sp, char *buf, size_t len) FUNC_ATTR_NONNULL_ALL;
DLLEXPORT void msg_prt_line(const char *s, bool list);
DLLEXPORT void msg_puts(const char *s);
DLLEXPORT void msg_puts_title(const char *s);
DLLEXPORT void msg_outtrans_long(const char *longstr, int hl_id);
DLLEXPORT void msg_puts_hl(const char *const s, const int hl_id, const bool hist);
DLLEXPORT void msg_puts_len(const char *const str, const ptrdiff_t len, int hl_id, bool hist) FUNC_ATTR_NONNULL_ALL;
DLLEXPORT void msg_line_flush(void);
DLLEXPORT void msg_cursor_goto(int row, int col);
DLLEXPORT bool message_filtered(const char *msg);
DLLEXPORT int msg_scrollsize(void);
DLLEXPORT bool msg_do_throttle(void);
DLLEXPORT void msg_scroll_up(bool may_throttle, bool zerocmd);
DLLEXPORT void msg_scroll_flush(void);
DLLEXPORT void msg_reset_scroll(void);
DLLEXPORT void msg_ui_refresh(void);
DLLEXPORT void msg_ui_flush(void);
DLLEXPORT void may_clear_sb_text(void);
DLLEXPORT void sb_text_start_cmdline(void);
DLLEXPORT void sb_text_restart_cmdline(void);
DLLEXPORT void sb_text_end_cmdline(void);
DLLEXPORT void clear_sb_text(bool all);
DLLEXPORT void show_sb_text(void);
DLLEXPORT void msg_sb_eol(void);
DLLEXPORT int msg_use_printf(void);
DLLEXPORT void repeat_message(void);
DLLEXPORT void msg_clr_eos(void);
DLLEXPORT void msg_clr_eos_force(void);
DLLEXPORT void msg_clr_cmdline(void);
DLLEXPORT bool msg_end(void);
DLLEXPORT void msg_ext_ui_flush(void);
DLLEXPORT void msg_ext_flush_showmode(void);
DLLEXPORT void msg_check(void);
DLLEXPORT int redirecting(void);
DLLEXPORT void verbose_enter(void);
DLLEXPORT void verbose_leave(void);
DLLEXPORT void verbose_enter_scroll(void);
DLLEXPORT void verbose_leave_scroll(void);
DLLEXPORT void verbose_stop(void);
DLLEXPORT int verbose_open(void);
DLLEXPORT void give_warning(const char *message, bool hl, bool hist) FUNC_ATTR_NONNULL_ARG(1);
DLLEXPORT void swmsg(bool hl, const char *const fmt, ...) FUNC_ATTR_PRINTF(2, 3);
DLLEXPORT void msg_advance(int col);
DLLEXPORT int do_dialog(int type, const char *title, const char *message, const char *buttons, int dfltbutton, const char *textfield, int ex_cmd);
DLLEXPORT int vim_dialog_yesno(int type, char *title, char *message, int dflt);
DLLEXPORT int vim_dialog_yesnocancel(int type, char *title, char *message, int dflt);
DLLEXPORT int vim_dialog_yesnoallcancel(int type, char *title, char *message, int dflt);
DLLEXPORT void msg_delay(uint64_t ms, bool ignoreinput);
DLLEXPORT void msg_check_for_delay(bool check_msg_scroll);


// Prefer using semsg(), because perror() may send the output to the wrong
// destination and mess up the screen.
#define PERROR(msg) (void)semsg("%s: %s", (msg), strerror(errno))
