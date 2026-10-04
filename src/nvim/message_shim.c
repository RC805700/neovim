// message_shim.c — minimal C companion for the Odin message.c port.
//
// Owns (single copy, Odin accesses via these accessors):
//   - message history list state (msg_hist_first/temp/last/len)
//   - do_clear_hist_temp flag
//   - msg_hist_last definition (extern for unittest)
// Provides ABI trampolines for C-variadic entries (Odin cannot emit
// implemented #c_vararg procs as linkable symbols; see log_shim.c).

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>

#include "nvim/message_defs.h"

// --- history list state (was C statics in message.c) ---
MessageHistoryEntry *msg_hist_last = NULL;          // Last message (extern for unittest)
static MessageHistoryEntry *msg_hist_first = NULL;  // First message
static MessageHistoryEntry *msg_hist_temp = NULL;   // First potentially temporary message
static int msg_hist_len = 0;
static bool do_clear_hist_temp = true;

MessageHistoryEntry *nvim_odin_hist_first(void) { return msg_hist_first; }
void nvim_odin_hist_first_set(MessageHistoryEntry *e) { msg_hist_first = e; }
MessageHistoryEntry *nvim_odin_hist_temp(void) { return msg_hist_temp; }
void nvim_odin_hist_temp_set(MessageHistoryEntry *e) { msg_hist_temp = e; }
MessageHistoryEntry *nvim_odin_hist_last(void) { return msg_hist_last; }
void nvim_odin_hist_last_set(MessageHistoryEntry *e) { msg_hist_last = e; }
int nvim_odin_hist_len(void) { return msg_hist_len; }
void nvim_odin_hist_len_set(int n) { msg_hist_len = n; }
bool nvim_odin_do_clear_hist_temp(void) { return do_clear_hist_temp; }
void nvim_odin_do_clear_hist_temp_set(bool v) { do_clear_hist_temp = v; }

// --- variadic ABI trampolines (logic lives in message.odin *_v exports) ---
extern int smsg_v(int hl_id, const char *s, va_list ap);
extern int smsg_keep_v(int hl_id, const char *s, va_list ap);
extern bool semsg_v(const char *fmt, va_list ap);
extern bool semsg_multiline_v(const char *kind, const char *fmt, va_list ap);
extern void siemsg_v(const char *s, va_list ap);
extern void swmsg_v(bool hl, const char *fmt, va_list ap);
extern void msg_schedule_semsg_v(const char *fmt, va_list ap);
extern void msg_schedule_semsg_multiline_v(const char *fmt, va_list ap);

int smsg(int hl_id, const char *s, ...)
{
  va_list arglist;
  va_start(arglist, s);
  int ret = smsg_v(hl_id, s, arglist);
  va_end(arglist);
  return ret;
}

int smsg_keep(int hl_id, const char *s, ...)
{
  va_list arglist;
  va_start(arglist, s);
  int ret = smsg_keep_v(hl_id, s, arglist);
  va_end(arglist);
  return ret;
}

bool semsg(const char *const fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  bool ret = semsg_v(fmt, ap);
  va_end(ap);
  return ret;
}

bool semsg_multiline(const char *kind, const char *const fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  bool ret = semsg_multiline_v(kind, fmt, ap);
  va_end(ap);
  return ret;
}

void siemsg(const char *s, ...)
{
  va_list ap;
  va_start(ap, s);
  siemsg_v(s, ap);
  va_end(ap);
}

void swmsg(bool hl, const char *const fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  swmsg_v(hl, fmt, args);
  va_end(args);
}

void msg_schedule_semsg(const char *const fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  msg_schedule_semsg_v(fmt, ap);
  va_end(ap);
}

void msg_schedule_semsg_multiline(const char *const fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  msg_schedule_semsg_multiline_v(fmt, ap);
  va_end(ap);
}
