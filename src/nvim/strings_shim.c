// strings_shim.c — minimal C companion for the Odin strings.c port.
//
// Odin cannot manipulate C va_list (va_copy/va_end/va_arg are inexpressible
// outside C; same category as log_shim.c). These 6 helpers perform ONLY the
// va_* operations; all format/parse logic lives in strings.odin.
// The thin variadic wrappers (vim_snprintf etc.) move here at cutover.

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "nvim/strings.h"

// TYPE_* tags must match strings.odin (values from strings.c enum).
enum {
  TYPE_UNKNOWN = -1,
  TYPE_INT,
  TYPE_LONGINT,
  TYPE_LONGLONGINT,
  TYPE_SIGNEDSIZET,
  TYPE_UNSIGNEDINT,
  TYPE_UNSIGNEDLONGINT,
  TYPE_UNSIGNEDLONGLONGINT,
  TYPE_SIZET,
  TYPE_POINTER,
  TYPE_PERCENT,
  TYPE_CHAR,
  TYPE_STRING,
  TYPE_FLOAT,
};

// Newer Odin backends emit a second memmove declaration with different LLVM
// parameter attributes for compiler-generated copies; LLVM disambiguates it
// as memmove.1, which no library provides. Same semantics — alias it.
void *memmove_dot1(void *dst, const void *src, size_t n) __asm__("memmove.1");
void *memmove_dot1(void *dst, const void *src, size_t n)
{
  return memmove(dst, src, n);
}

void nvim_odin_va_copy(void *dst, void *src)
{
  va_list *d = (va_list *)dst;
  va_list *s = (va_list *)src;
  va_copy(*d, *s);
}

void nvim_odin_va_end(void *ap)
{
  va_list *a = (va_list *)ap;
  va_end(*a);
}

int64_t nvim_odin_va_arg_i64(void *ap_p, int type)
{
  va_list *ap = (va_list *)ap_p;
  switch (type) {
  case TYPE_INT: return va_arg(*ap, int);
  case TYPE_LONGINT: return va_arg(*ap, long);
  case TYPE_LONGLONGINT: return va_arg(*ap, long long);
  default: break;
  }
  // TYPE_SIGNEDSIZET: implementation-defined, usually ptrdiff_t
  return va_arg(*ap, ptrdiff_t);
}

uint64_t nvim_odin_va_arg_u64(void *ap_p, int type)
{
  va_list *ap = (va_list *)ap_p;
  switch (type) {
  case TYPE_UNSIGNEDINT: return va_arg(*ap, unsigned);
  case TYPE_UNSIGNEDLONGINT: return va_arg(*ap, unsigned long);
  case TYPE_UNSIGNEDLONGLONGINT: return va_arg(*ap, unsigned long long);
  default: break;
  }
  return va_arg(*ap, size_t);
}

double nvim_odin_va_arg_f64(void *ap_p)
{
  va_list *ap = (va_list *)ap_p;
  return va_arg(*ap, double);
}

void *nvim_odin_va_arg_ptr(void *ap_p, int type)
{
  va_list *ap = (va_list *)ap_p;
  switch (type) {
  case TYPE_CHAR: return (void *)(uintptr_t)va_arg(*ap, int);
  case TYPE_STRING: return (void *)va_arg(*ap, const char *);
  default: break;
  }
  return va_arg(*ap, void *);
}

// Thin variadic trampolines: Odin cannot emit implemented #c_vararg procs as
// linkable symbols (log_shim.c precedent). All logic is in the _v exports;
// these forward va_list only. Declarations of the _v targets:
extern int vim_snprintf_add_v(char *str, size_t str_m, const char *fmt, va_list ap);
extern int vim_snprintf_v(char *str, size_t str_m, const char *fmt, va_list ap);
extern size_t vim_snprintf_safelen_v(char *str, size_t str_m, const char *fmt, va_list ap);
extern int kv_do_printf_v(StringBuilder *str, const char *fmt, va_list ap);
extern String arena_printf_v(Arena *arena, const char *fmt, va_list ap);

int vim_snprintf_add(char *str, size_t str_m, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int ret = vim_snprintf_add_v(str, str_m, fmt, ap);
  va_end(ap);
  return ret;
}

int vim_snprintf(char *str, size_t str_m, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int ret = vim_snprintf_v(str, str_m, fmt, ap);
  va_end(ap);
  return ret;
}

size_t vim_snprintf_safelen(char *str, size_t str_m, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  size_t ret = vim_snprintf_safelen_v(str, str_m, fmt, ap);
  va_end(ap);
  return ret;
}

int kv_do_printf(StringBuilder *str, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int ret = kv_do_printf_v(str, fmt, ap);
  va_end(ap);
  return ret;
}

String arena_printf(Arena *arena, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  String ret = arena_printf_v(arena, fmt, ap);
  va_end(ap);
  return ret;
}
