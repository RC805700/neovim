#include "nvim/api/extmark.h"  // ns_in_win (static inline)
#include "nvim/buffer_defs.h"  // win_T

// ABI glue for the Odin plines port: C static inline, no linkable symbol.
bool nvim_odin_ns_in_win(uint32_t ns_id, win_T *wp)
{
  return ns_in_win(ns_id, wp);
}
