// funcs_shim.c — hosts the gperf-generated functions[] DATA table for the
// Odin port (Batch 28bn) plus the three foreign-subsystem glue functions whose
// addresses the table takes (math wrapper, API dispatcher, Lua bridge).
// All eval-owned LOGIC (find/check/call/get_*) lives in src/odin/eval.odin.
// Auto-globbed into the build (CONFIGURE_DEPENDS).
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "nvim/api/private/converter.h"
#include "nvim/api/private/defs.h"
#include "nvim/api/private/dispatch.h"
#include "nvim/api/private/helpers.h"
#include "nvim/errors.h"
#include "nvim/eval.h"
#include "nvim/eval/funcs.h"
#include "nvim/eval/typval.h"
#include "nvim/ex_cmds.h"
#include "nvim/lua/executor.h"
#include "nvim/memory.h"
#include "nvim/message.h"
#include "nvim/os/os.h"
#include "nvim/strings.h"

// Forward declarations for table initializers (defined below).
static void float_op_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr);
static void api_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr);
static void lua_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr);

#include "funcs.generated.h"

#pragma weak find_internal_func_hash

/// Row accessor for the generated table (Odin reads rows opaquely).
const EvalFuncDef *nvim_odin_funcdef_at(int i) { return &functions[i]; }

/// Address exposure for lua-entry detection (Odin compares fdef->func).
void *nvim_odin_lua_wrapper_addr(void) { return (void *)&lua_wrapper; }

/// Math-function wrapper (moved verbatim from funcs.c; address taken by table).
static void float_op_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  float_T f;

  rettv->v_type = VAR_FLOAT;
  if (tv_get_float_chk(argvars, &f)) {
    rettv->vval.v_float = fptr.func_float(f);
  } else {
    rettv->vval.v_float = 0.0;
  }
}

/// API-function wrapper (moved verbatim from funcs.c; address taken by table).
static void api_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  if (check_secure()) {
    return;
  }

  MsgpackRpcRequestHandler handler = *fptr.func_api;

  MAXSIZE_TEMP_ARRAY(args, MAX_FUNC_ARGS);
  Arena arena = ARENA_EMPTY;

  for (typval_T *tv = argvars; tv->v_type != VAR_UNKNOWN; tv++) {
    ADD_C(args, vim_to_object(tv, &arena, false));
  }

  Error err = ERROR_INIT;
  Object result = handler.fn(VIML_INTERNAL_CALL, args, &arena, &err);

  if (ERROR_SET(&err)) {
    semsg_multiline("emsg", e_api_error, err.msg);
    goto end;
  }

  object_to_vim_take_luaref(&result, rettv, true, &err);

end:
  if (handler.ret_alloc) {
    api_free_object(result);
  }
  arena_mem_free(arena_finish(&arena));
  api_clear_error(&err);
}

/// Lua-implemented vimfn wrapper (moved verbatim from funcs.c).
static void lua_wrapper(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  MAXSIZE_TEMP_ARRAY(args, MAX_FUNC_ARGS);
  Arena arena = ARENA_EMPTY;

  for (typval_T *tv = argvars; tv->v_type != VAR_UNKNOWN; tv++) {
    ADD_C(args, vim_to_object(tv, &arena, false));
  }

  char buf[256];
  snprintf(buf, sizeof(buf), "return require('vim._core.vimfn').%s(...)", fptr.func_lua);

  Error err = ERROR_INIT;
  Object result = nlua_exec(cstr_as_string(buf), NULL, args, kRetObject, &arena, &err);

  if (ERROR_SET(&err)) {
    semsg_multiline("emsg", e_api_error, err.msg);
    goto end;
  }

  object_to_vim_take_luaref(&result, rettv, true, &err);

end:
  arena_mem_free(arena_finish(&arena));
  api_clear_error(&err);
}
