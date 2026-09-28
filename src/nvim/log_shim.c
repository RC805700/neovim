// Variadic entry trampoline for the Odin log engine (log.odin).
//
// Odin does not emit implemented #c_vararg procs as linkable symbols, so C
// callers cannot bind an Odin `logmsg` directly (undefined reference at
// link). This 10-line forwarder is pure ABI glue: it bundles the C varargs
// into a va_list and tail-calls the Odin `logmsg_v` export, which holds all
// real logic. Odin-side callers keep using logmsg_e (same symbol).

#include <stdarg.h>
#include <stdbool.h>

bool logmsg_v(int log_level, const char *context, const char *func_name, int line_num, bool eol,
              const char *fmt, va_list args);

bool logmsg(int log_level, const char *context, const char *func_name, int line_num, bool eol,
            const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  bool ret = logmsg_v(log_level, context, func_name, line_num, eol, fmt, args);
  va_end(args);
  return ret;
}
