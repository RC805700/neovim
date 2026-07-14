#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>

#include <uv.h>

#include "auto/config.h"
#include "nvim/event/loop.h"
#include "nvim/event/multiqueue.h"
#include "nvim/gettext_defs.h"
#include "nvim/globals.h"
#include "nvim/log.h"
#include "nvim/main.h"
#include "nvim/memory.h"
#include "nvim/os/input.h"
#include "nvim/os/os.h"
#include "nvim/os/time.h"

#include "os/time.c.generated.h"

#if 0
// Ported to Odin — see src/odin/time.odin.
// Kept here only for reference; the C code is no longer compiled.

uint64_t os_hrtime(void)
  FUNC_ATTR_WARN_UNUSED_RESULT
{
  return uv_hrtime();
}

int64_t os_realtime(void)
  FUNC_ATTR_WARN_UNUSED_RESULT
{
  uv_timespec64_t ts = { 0 };
  int error_number;
  if ((error_number = uv_clock_gettime(UV_CLOCK_REALTIME, &ts)) != 0) {
    ELOG("uv_clock_gettime failed: %d %s", error_number, uv_err_name(error_number));
    return 0;
  }
  return ts.tv_sec * 1000000000L + ts.tv_nsec;
}

void os_sleep(uint64_t ms)
{
  if (ms > UINT_MAX) {
    ms = UINT_MAX;
  }
  uv_sleep((unsigned)ms);
}

static char tz_cache[64];

struct tm *os_localtime_r(const time_t *restrict clock,
                          struct tm *restrict result) FUNC_ATTR_NONNULL_ALL
{
#ifdef UNIX
  const char *tz = os_getenv_noalloc("TZ");
  if (!tz) {
    tz = "";
  }
  if (strncmp(tz_cache, tz, sizeof(tz_cache) - 1) != 0) {
    tzset();
    xstrlcpy(tz_cache, tz, sizeof(tz_cache));
  }
  return localtime_r(clock, result);
#else
  struct tm *local_time = localtime(clock);
  if (!local_time) {
    return NULL;
  }
  *result = *local_time;
  return result;
#endif
}

struct tm *os_localtime(struct tm *result) FUNC_ATTR_NONNULL_ALL
{
  time_t rawtime = time(NULL);
  return os_localtime_r(&rawtime, result);
}

char *os_ctime_r(const time_t *restrict clock, char *restrict result, size_t result_len,
                 bool add_newline)
  FUNC_ATTR_NONNULL_ALL FUNC_ATTR_NONNULL_RET
{
  struct tm clock_local;
  struct tm *clock_local_ptr = os_localtime_r(clock, &clock_local);
  if (clock_local_ptr == NULL) {
    xstrlcpy(result, _("(Invalid)"), result_len - 1);
  } else {
    if (strftime(result, result_len - 1, _("%a %b %d %H:%M:%S %Y"), clock_local_ptr) == 0) {
      xstrlcpy(result, _("(Invalid)"), result_len - 1);
    }
  }
  if (add_newline) {
    xstrlcat(result, "\n", result_len);
  }
  return result;
}

char *os_ctime(char *result, size_t result_len, bool add_newline)
  FUNC_ATTR_NONNULL_ALL FUNC_ATTR_NONNULL_RET
{
  time_t rawtime = time(NULL);
  return os_ctime_r(&rawtime, result, result_len, add_newline);
}

char *os_strptime(const char *str, const char *format, struct tm *tm)
  FUNC_ATTR_NONNULL_ALL
{
#ifdef HAVE_STRPTIME
  return strptime(str, format, tm);
#else
  return NULL;
#endif
}

Timestamp os_time(void)
  FUNC_ATTR_WARN_UNUSED_RESULT
{
  return (Timestamp)time(NULL);
}
#endif

/// Gets a millisecond-resolution, monotonically-increasing time relative to an
/// arbitrary time in the past.
///
/// Not related to the time of day and therefore not subject to clock drift.
/// The value is cached by the loop, it will not change until the next
/// loop-tick (unless uv_update_time is called).
///
/// @return Relative time value with millisecond precision.
uint64_t os_now(void)
  FUNC_ATTR_WARN_UNUSED_RESULT
{
  return uv_now(&main_loop.uv);
}

/// Sleeps for `ms` milliseconds.
///
/// @see uv_sleep() (libuv v1.34.0)
///
/// @param ms          Number of milliseconds to sleep
/// @param ignoreinput If true, only SIGINT (CTRL-C) can interrupt.
void os_delay(uint64_t ms, bool ignoreinput)
{
  DLOG("%" PRIu64 " ms", ms);
  if (ms > INT_MAX) {
    ms = INT_MAX;
  }
  LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, (int)ms,
                            ignoreinput ? got_int : os_input_ready(NULL));
}
