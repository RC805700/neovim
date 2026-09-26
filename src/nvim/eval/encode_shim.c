// encode_shim.c — C-retained state for the Odin encode.c port.
//
// After `git mv src/nvim/eval/encode.c → src/nvim/bak/`, the file-static
// `did_echo_string_emsg` flag would vanish. These shims own it here so the
// Odin string/echo/json RECURSE paths keep working (vars_shim.c precedent).

#include <stdbool.h>

static bool odin_echo_string_emsg = false;

bool nvim_odin_get_echo_emsg(void)
{
  return odin_echo_string_emsg;
}

void nvim_odin_set_echo_emsg(bool v)
{
  odin_echo_string_emsg = v;
}

void nvim_odin_reset_echo_emsg(void)
{
  odin_echo_string_emsg = false;
}
