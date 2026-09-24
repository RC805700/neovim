// vars_shim.c — C-retained state for eval/vars.c (cut over to Odin).
// Holds the vimvars[] table, scope dicts, compat hashtable, msgpack type
// list array, plus accessor shims used by Odin FFI. No logic lives here.

#include <stdbool.h>
#include <stddef.h>
#include "nvim/eval/typval_defs.h"
#include "nvim/eval_defs.h"
#include "nvim/hashtab_defs.h"

// --- scope stores (verbatim from vars.c) ---
static hashtab_T compat_hashtab;

/// Variable used for g:
static ScopeDictDictItem globvars_var;
static dict_T globvardict;                  // Dict with g: variables
/// g: value
#define globvarht globvardict.dv_hashtab

static ScopeDictDictItem vimvars_var;
static dict_T vimvardict;                   // Dict with v: variables
/// v: hashtab
#define vimvarht  vimvardict.dv_hashtab

// --- vimvars table macros + definition (verbatim from vars.c) ---
// values for vv_flags:
#define VV_COMPAT       1       // compatible, also used without "v:"
#define VV_RO           2       // read-only
#define VV_RO_SBX       4       // read-only in the sandbox

#define VV(idx, name, type, flags) \
  [idx] = { \
    .vv_name = (name), \
    .vv_di = { \
      .di_tv = { .v_type = (type) }, \
      .di_flags = 0, \
      .di_key = name, \
    }, \
    .vv_flags = (flags), \
  }

#define VIMVAR_KEY_LEN 16  // Maximum length of the key of v:variables

// Array to hold the value of v: variables.
// The value is in a dictitem, so that it can also be used in the v: scope.
// The reason to use this table anyway is for very quick access to the
// variables with the VV_ defines.
static struct vimvar {
  char *vv_name;  ///< Name of the variable, without v:.
  TV_DICTITEM_STRUCT(VIMVAR_KEY_LEN + 1) vv_di;  ///< Value and name for key (max 16 chars).
  char vv_flags;  ///< Flags: #VV_COMPAT, #VV_RO, #VV_RO_SBX.
} vimvars[] = {
  // VV_ tails differing from upcased string literals:
  // VV_CC_FROM "charconvert_from"
  // VV_CC_TO "charconvert_to"
  // VV_SEND_SERVER "servername"
  // VV_REG "register"
  // VV_OP "operator"
  VV(VV_COUNT,            "count",            VAR_NUMBER, VV_RO),
  VV(VV_COUNT1,           "count1",           VAR_NUMBER, VV_RO),
  VV(VV_PREVCOUNT,        "prevcount",        VAR_NUMBER, VV_RO),
  VV(VV_ERRMSG,           "errmsg",           VAR_STRING, 0),
  VV(VV_WARNINGMSG,       "warningmsg",       VAR_STRING, 0),
  VV(VV_STATUSMSG,        "statusmsg",        VAR_STRING, 0),
  VV(VV_SHELL_ERROR,      "shell_error",      VAR_NUMBER, VV_RO),
  VV(VV_THIS_SESSION,     "this_session",     VAR_STRING, 0),
  VV(VV_VERSION,          "version",          VAR_NUMBER, VV_COMPAT + VV_RO),
  VV(VV_LNUM,             "lnum",             VAR_NUMBER, VV_RO_SBX),
  VV(VV_TERMRESPONSE,     "termresponse",     VAR_STRING, VV_RO),
  VV(VV_TERMREQUEST,      "termrequest",      VAR_STRING, VV_RO),
  VV(VV_FNAME,            "fname",            VAR_STRING, VV_RO),
  VV(VV_LANG,             "lang",             VAR_STRING, VV_RO),
  VV(VV_LC_TIME,          "lc_time",          VAR_STRING, VV_RO),
  VV(VV_CTYPE,            "ctype",            VAR_STRING, VV_RO),
  VV(VV_CC_FROM,          "charconvert_from", VAR_STRING, VV_RO),
  VV(VV_CC_TO,            "charconvert_to",   VAR_STRING, VV_RO),
  VV(VV_FNAME_IN,         "fname_in",         VAR_STRING, VV_RO),
  VV(VV_FNAME_OUT,        "fname_out",        VAR_STRING, VV_RO),
  VV(VV_FNAME_NEW,        "fname_new",        VAR_STRING, VV_RO),
  VV(VV_FNAME_DIFF,       "fname_diff",       VAR_STRING, VV_RO),
  VV(VV_CMDARG,           "cmdarg",           VAR_STRING, VV_RO),
  VV(VV_FOLDSTART,        "foldstart",        VAR_NUMBER, VV_RO_SBX),
  VV(VV_FOLDEND,          "foldend",          VAR_NUMBER, VV_RO_SBX),
  VV(VV_FOLDDASHES,       "folddashes",       VAR_STRING, VV_RO_SBX),
  VV(VV_FOLDLEVEL,        "foldlevel",        VAR_NUMBER, VV_RO_SBX),
  VV(VV_PROGNAME,         "progname",         VAR_STRING, VV_RO),
  VV(VV_SEND_SERVER,      "servername",       VAR_STRING, VV_RO),
  VV(VV_DYING,            "dying",            VAR_NUMBER, VV_RO),
  VV(VV_EXCEPTION,        "exception",        VAR_STRING, VV_RO),
  VV(VV_THROWPOINT,       "throwpoint",       VAR_STRING, VV_RO),
  VV(VV_REG,              "register",         VAR_STRING, VV_RO),
  VV(VV_CMDBANG,          "cmdbang",          VAR_NUMBER, VV_RO),
  VV(VV_INSERTMODE,       "insertmode",       VAR_STRING, VV_RO),
  VV(VV_VAL,              "val",              VAR_UNKNOWN, VV_RO),
  VV(VV_KEY,              "key",              VAR_UNKNOWN, VV_RO),
  VV(VV_PROFILING,        "profiling",        VAR_NUMBER, VV_RO),
  VV(VV_FCS_REASON,       "fcs_reason",       VAR_STRING, VV_RO),
  VV(VV_FCS_CHOICE,       "fcs_choice",       VAR_STRING, 0),
  VV(VV_BEVAL_BUFNR,      "beval_bufnr",      VAR_NUMBER, VV_RO),
  VV(VV_BEVAL_WINNR,      "beval_winnr",      VAR_NUMBER, VV_RO),
  VV(VV_BEVAL_WINID,      "beval_winid",      VAR_NUMBER, VV_RO),
  VV(VV_BEVAL_LNUM,       "beval_lnum",       VAR_NUMBER, VV_RO),
  VV(VV_BEVAL_COL,        "beval_col",        VAR_NUMBER, VV_RO),
  VV(VV_BEVAL_TEXT,       "beval_text",       VAR_STRING, VV_RO),
  VV(VV_SCROLLSTART,      "scrollstart",      VAR_STRING, 0),
  VV(VV_SWAPNAME,         "swapname",         VAR_STRING, VV_RO),
  VV(VV_SWAPCHOICE,       "swapchoice",       VAR_STRING, 0),
  VV(VV_SWAPCOMMAND,      "swapcommand",      VAR_STRING, VV_RO),
  VV(VV_CHAR,             "char",             VAR_STRING, 0),
  VV(VV_MOUSE_WIN,        "mouse_win",        VAR_NUMBER, 0),
  VV(VV_MOUSE_WINID,      "mouse_winid",      VAR_NUMBER, 0),
  VV(VV_MOUSE_LNUM,       "mouse_lnum",       VAR_NUMBER, 0),
  VV(VV_MOUSE_COL,        "mouse_col",        VAR_NUMBER, 0),
  VV(VV_OP,               "operator",         VAR_STRING, VV_RO),
  VV(VV_SEARCHFORWARD,    "searchforward",    VAR_NUMBER, 0),
  VV(VV_HLSEARCH,         "hlsearch",         VAR_NUMBER, 0),
  VV(VV_OLDFILES,         "oldfiles",         VAR_LIST, 0),
  VV(VV_WINDOWID,         "windowid",         VAR_NUMBER, VV_RO_SBX),
  VV(VV_PROGPATH,         "progpath",         VAR_STRING, VV_RO),
  VV(VV_COMPLETED_ITEM,   "completed_item",   VAR_DICT, 0),
  VV(VV_OPTION_NEW,       "option_new",       VAR_STRING, VV_RO),
  VV(VV_OPTION_OLD,       "option_old",       VAR_STRING, VV_RO),
  VV(VV_OPTION_OLDLOCAL,  "option_oldlocal",  VAR_STRING, VV_RO),
  VV(VV_OPTION_OLDGLOBAL, "option_oldglobal", VAR_STRING, VV_RO),
  VV(VV_OPTION_COMMAND,   "option_command",   VAR_STRING, VV_RO),
  VV(VV_OPTION_TYPE,      "option_type",      VAR_STRING, VV_RO),
  VV(VV_ERRORS,           "errors",           VAR_LIST, 0),
  VV(VV_FALSE,            "false",            VAR_BOOL, VV_RO),
  VV(VV_TRUE,             "true",             VAR_BOOL, VV_RO),
  VV(VV_NULL,             "null",             VAR_SPECIAL, VV_RO),
  VV(VV_NUMBERMAX,        "numbermax",        VAR_NUMBER, VV_RO),
  VV(VV_NUMBERMIN,        "numbermin",        VAR_NUMBER, VV_RO),
  VV(VV_NUMBERSIZE,       "numbersize",       VAR_NUMBER, VV_RO),
  VV(VV_VIM_DID_ENTER,    "vim_did_enter",    VAR_NUMBER, VV_RO),
  VV(VV_TESTING,          "testing",          VAR_NUMBER, 0),
  VV(VV_TYPE_NUMBER,      "t_number",         VAR_NUMBER, VV_RO),
  VV(VV_TYPE_STRING,      "t_string",         VAR_NUMBER, VV_RO),
  VV(VV_TYPE_FUNC,        "t_func",           VAR_NUMBER, VV_RO),
  VV(VV_TYPE_LIST,        "t_list",           VAR_NUMBER, VV_RO),
  VV(VV_TYPE_DICT,        "t_dict",           VAR_NUMBER, VV_RO),
  VV(VV_TYPE_FLOAT,       "t_float",          VAR_NUMBER, VV_RO),
  VV(VV_TYPE_BOOL,        "t_bool",           VAR_NUMBER, VV_RO),
  VV(VV_TYPE_BLOB,        "t_blob",           VAR_NUMBER, VV_RO),
  VV(VV_EVENT,            "event",            VAR_DICT, VV_RO),
  VV(VV_VERSIONLONG,      "versionlong",      VAR_NUMBER, VV_RO),
  VV(VV_ECHOSPACE,        "echospace",        VAR_NUMBER, VV_RO),
  VV(VV_ARGF,             "argf",             VAR_LIST, VV_RO),
  VV(VV_ARGV,             "argv",             VAR_LIST, VV_RO),
  VV(VV_COLLATE,          "collate",          VAR_STRING, VV_RO),
  VV(VV_EXITING,          "exiting",          VAR_NUMBER, VV_RO),
  VV(VV_MAXCOL,           "maxcol",           VAR_NUMBER, VV_RO),
  VV(VV_STACKTRACE,       "stacktrace",       VAR_LIST, VV_RO),
  VV(VV_VIM_DID_INIT,     "vim_did_init",     VAR_NUMBER, VV_RO),
  // Neovim
  VV(VV_STDERR,           "stderr",           VAR_NUMBER, VV_RO),
  VV(VV_MSGPACK_TYPES,    "msgpack_types",    VAR_DICT, VV_RO),
  VV(VV__NULL_STRING,     "_null_string",     VAR_STRING, VV_RO),
  VV(VV__NULL_LIST,       "_null_list",       VAR_LIST, VV_RO),
  VV(VV__NULL_DICT,       "_null_dict",       VAR_DICT, VV_RO),
  VV(VV__NULL_BLOB,       "_null_blob",       VAR_BLOB, VV_RO),
  VV(VV_LUA,              "lua",              VAR_PARTIAL, VV_RO),
  VV(VV_RELNUM,           "relnum",           VAR_NUMBER, VV_RO),
  VV(VV_VIRTNUM,          "virtnum",          VAR_NUMBER, VV_RO),
  VV(VV_STARTTIME,        "starttime",        VAR_NUMBER, VV_RO),
  VV(VV_EXITREASON,       "exitreason",       VAR_STRING, VV_RO),
  VV(VV_USERACTIVE,       "useractive",       VAR_NUMBER, VV_RO),
  VV(VV_STARTREASON,      "startreason",      VAR_STRING, VV_RO),
};

// shorthand (verbatim from vars.c)
#define vv_type         vv_di.di_tv.v_type
#define vv_str          vv_di.di_tv.vval.v_string
#define vv_list         vv_di.di_tv.vval.v_list
#define vv_tv           vv_di.di_tv

// --- msgpack type list array (verbatim, kept global: encode.c reads it) ---
const list_T *eval_msgpack_type_lists[] = {
  [kMPNil] = NULL,
  [kMPBoolean] = NULL,
  [kMPInteger] = NULL,
  [kMPFloat] = NULL,
  [kMPString] = NULL,
  [kMPArray] = NULL,
  [kMPMap] = NULL,
  [kMPExt] = NULL,
};

// --- Odin accessor shims (verbatim from vars.c tail) ---
hashtab_T *nvim_odin_compat_hashtab(void)
{
  return &compat_hashtab;
}

typval_T *nvim_odin_vimvar_tv(int idx)
{
  return &vimvars[idx].vv_tv;
}

void *nvim_odin_globvars_var(void)
{
  return &globvars_var;
}

void *nvim_odin_vimvars_var(void)
{
  return &vimvars_var;
}

// Shims for Odin: g: scope store (read-only; C retains mutation).
dict_T *nvim_odin_globvardict(void)
{
  return &globvardict;
}

hashtab_T *nvim_odin_globvarht(void)
{
  return &globvarht;
}

dict_T *nvim_odin_vimvardict(void)
{
  return &vimvardict;
}
