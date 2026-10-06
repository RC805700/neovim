#pragma once

#include "nvim/ex_cmds_defs.h"  // IWYU pragma: keep
#include "nvim/pos_defs.h"  // IWYU pragma: keep
#include "nvim/types_defs.h"  // IWYU pragma: keep

#include "bufwrite.h.generated.h"

// Hand-written: bufwrite.c is fully ported to Odin (src/odin/bufwrite.odin);
// the generated header is empty once the C source is gone.
char *buf_get_backup_name(char *fname, char **dirp, bool no_prepend_dot, char *backup_ext);
int buf_write(buf_T *buf, char *fname, char *sfname, linenr_T start, linenr_T end, exarg_T *eap, bool append, bool forceit, bool reset_changed, bool filtering);
