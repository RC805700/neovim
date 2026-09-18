// User-settable options. Checklist for adding a new option:
// - Put it in options.lua
// - For a global option: Add a variable for it in option_vars.h.
// - For a buffer or window local option:
//   - Add a variable to the window or buffer struct in buffer_defs.h.
//   - For a window option, add some code to copy_winopt().
//   - For a window string option, add code to check_winopt()
//     and clear_winopt(). If setting the option needs parsing,
//     add some code to didset_window_options().
//   - For a buffer option, add some code to buf_copy_options().
//   - For a buffer string option, add code to check_buf_options().
// - If it's a numeric option, add any necessary bounds checks to check_num_option_bounds().
// - If it's a list of flags, add some code in do_set(), search for WW_ALL.
// - If it depends on options values, add it to didset_string_options().
// - Add documentation! "desc" in options.lua, and any other related places.
// - Add an entry in runtime/scripts/optwin.lua.

#define IN_OPTION_C



#include <assert.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "auto/config.h"
#include "klib/kvec.h"
#include "nvim/api/extmark.h"
#include "nvim/api/private/defs.h"
#include "nvim/api/private/helpers.h"
#include "nvim/api/private/validate.h"
#include "nvim/ascii_defs.h"
#include "nvim/assert_defs.h"
#include "nvim/autocmd.h"
#include "nvim/autocmd_defs.h"
#include "nvim/buffer.h"
#include "nvim/buffer_defs.h"
#include "nvim/change.h"
#include "nvim/charset.h"
#include "nvim/cmdexpand.h"
#include "nvim/cmdexpand_defs.h"
#include "nvim/cursor_shape.h"
#include "nvim/decoration_defs.h"
#include "nvim/decoration_provider.h"
#include "nvim/diff.h"
#include "nvim/drawscreen.h"
#include "nvim/errors.h"
#include "nvim/eval.h"
#include "nvim/eval/typval.h"
#include "nvim/eval/typval_defs.h"
#include "nvim/eval/vars.h"
#include "nvim/eval/window.h"
#include "nvim/ex_cmds_defs.h"
#include "nvim/ex_docmd.h"
#include "nvim/ex_getln.h"
#include "nvim/ex_session.h"
#include "nvim/fold.h"
#include "nvim/fuzzy.h"
#include "nvim/garray.h"
#include "nvim/garray_defs.h"
#include "nvim/gettext_defs.h"
#include "nvim/globals.h"
#include "nvim/grid_defs.h"
#include "nvim/highlight.h"
#include "nvim/highlight_defs.h"
#include "nvim/highlight_group.h"
#include "nvim/indent.h"
#include "nvim/indent_c.h"
#include "nvim/insexpand.h"
#include "nvim/keycodes.h"
#include "nvim/log.h"
#include "nvim/lua/executor.h"
#include "nvim/macros_defs.h"
#include "nvim/mapping.h"
#include "nvim/mbyte.h"
#include "nvim/memfile.h"
#include "nvim/memline.h"
#include "nvim/memory.h"
#include "nvim/memory_defs.h"
#include "nvim/message.h"
#include "nvim/mouse.h"
#include "nvim/move.h"
#include "nvim/normal.h"
#include "nvim/ops.h"
#include "nvim/option.h"
#include "nvim/option_defs.h"
#include "nvim/option_vars.h"
#include "nvim/optionstr.h"
#include "nvim/os/input.h"
#include "nvim/os/lang.h"
#include "nvim/os/os.h"
#include "nvim/os/os_defs.h"
#include "nvim/path.h"
#include "nvim/popupmenu.h"
#include "nvim/pos_defs.h"
#include "nvim/regexp.h"
#include "nvim/regexp_defs.h"
#include "nvim/runtime.h"
#include "nvim/spell.h"
#include "nvim/spellfile.h"
#include "nvim/spellsuggest.h"
#include "nvim/state_defs.h"
#include "nvim/strings.h"
#include "nvim/tag.h"
#include "nvim/terminal.h"
#include "nvim/types_defs.h"
#include "nvim/ui.h"
#include "nvim/undo.h"
#include "nvim/undo_defs.h"
#include "nvim/vim_defs.h"
#include "nvim/window.h"
#include "nvim/winfloat.h"

#ifdef BACKSLASH_IN_FILENAME
# include "nvim/arglist.h"
#endif

static const char e_unknown_option[]
  = N_("E518: Unknown option");
static const char e_not_allowed_in_modeline[]
  = N_("E520: Not allowed in a modeline");
static const char e_not_allowed_in_modeline_when_modelineexpr_is_off[]
  = N_("E992: Not allowed in a modeline when 'modelineexpr' is off");
static const char e_number_required_after_equal[]
  = N_("E521: Number required after =");
static const char e_preview_window_already_exists[]
  = N_("E590: A preview window already exists");
static const char e_cannot_have_negative_or_zero_number_of_quickfix[]
  = N_("E1542: Cannot have a negative or zero number of quickfix/location lists");
static const char e_cannot_have_more_than_hundred_quickfix[]
  = N_("E1543: Cannot have more than a hundred quickfix/location lists");

static char *p_term = NULL;
static char *p_ttytype = NULL;

// Saved values for when 'bin' is set.
static int p_et_nobin;
static int p_ml_nobin;
static OptInt p_tw_nobin;
static OptInt p_wm_nobin;

// Saved values for when 'paste' is set.
static int p_ai_nopaste;
static int p_et_nopaste;
static OptInt p_sts_nopaste;
static OptInt p_tw_nopaste;
static OptInt p_wm_nopaste;
static char *p_vsts_nopaste;

#define OPTION_COUNT ARRAY_SIZE(options)

#include "option_shim.c.generated.h"

static void didset_options_sctx(int opt_flags, int *buf)
{
  for (int i = 0;; i++) {
    if (buf[i] == kOptInvalid) {
      break;
    }
    set_option_sctx(buf[i], opt_flags, current_sctx);
  }
}



static void didset_options_sctx(int opt_flags, int *buf);


// options[] is initialized in options.generated.h.
// The options with a NULL variable are 'hidden': a set command for them is
// ignored and they are not printed.

#include "options.generated.h"
#include "options_map.generated.h"

// Odin port: these functions are now defined in src/odin/option.odin.
// The C definitions below remain as weak fallbacks; the strong Odin
// definitions win at link time. See AGENTS.md option.c entry.
#pragma weak apply_optionset_autocmd_now
#pragma weak buf_copy_options
#pragma weak can_bs
#pragma weak check_blending
#pragma weak check_options
#pragma weak check_redraw
#pragma weak check_redraw_for
#pragma weak clear_winopt
#pragma weak copy_winopt
#pragma weak csh_like_shell
#pragma weak default_fileformat
#pragma weak did_set_buflocal_undolevels
#pragma weak did_set_global_undolevels
#pragma weak did_set_title
#pragma weak do_set
#pragma weak escape_option_str_cmdline
#pragma weak ExpandOldSetting
#pragma weak ExpandSettings
#pragma weak ExpandSettingSubtract
#pragma weak ExpandStringSetting
#pragma weak ex_set
#pragma weak fill_culopt_flags
#pragma weak find_option
#pragma weak find_option_end
#pragma weak find_option_len
#pragma weak fish_like_shell
#pragma weak get_all_vimoptions
#pragma weak get_bkc_flags
#pragma weak get_equalprg
#pragma weak get_fileformat
#pragma weak get_fileformat_force
#pragma weak get_findfunc
#pragma weak get_flp_value
#pragma weak get_option
#pragma weak get_option_default
#pragma weak get_option_flags
#pragma weak get_option_newval
#pragma weak get_option_sctx
#pragma weak get_option_value
#pragma weak get_option_value_for
#pragma weak get_scrolloffpad_value
#pragma weak get_scrolloff_value
#pragma weak get_showbreak_value
#pragma weak get_sidescrolloff_value
#pragma weak get_tty_option
#pragma weak get_vimoption
#pragma weak get_winbuf_options
#pragma weak insecure_flag
#pragma weak is_option_hidden
#pragma weak magic_isset
#pragma weak makefoldset
#pragma weak makeset
#pragma weak object_as_optval
#pragma weak object_as_optval_for
#pragma weak option_has_scope
#pragma weak option_has_type
#pragma weak option_scope_idx
#pragma weak option_set_callback_func
#pragma weak option_was_set
#pragma weak optval_as_object
#pragma weak optval_copy
#pragma weak optval_equal
#pragma weak optval_free
#pragma weak optval_from_varp
#pragma weak redraw_titles
#pragma weak reset_modifiable
#pragma weak reset_option_was_set
#pragma weak set_context_in_set_cmd
#pragma weak set_fileformat
#pragma weak set_helplang_default
#pragma weak set_iminsert_global
#pragma weak set_imsearch_global
#pragma weak set_init_tablocal
#pragma weak set_option_direct
#pragma weak set_option_direct_for
#pragma weak set_options_bin
#pragma weak set_option_value
#pragma weak set_option_value_for
#pragma weak set_option_value_give_err
#pragma weak set_option_value_handle_tty
#pragma weak set_title_defaults
#pragma weak set_tty_option
#pragma weak skip_to_option_part
#pragma weak string_to_key
#pragma weak ui_refresh_options
#pragma weak valid_name
#pragma weak vimrc_found
#pragma weak was_set_insecurely
#pragma weak win_copy_options

static int p_bin_dep_opts[] = {
  kOptTextwidth, kOptWrapmargin, kOptModeline, kOptExpandtab, kOptInvalid
};

static int p_paste_dep_opts[] = {
  kOptAutoindent, kOptExpandtab, kOptRuler, kOptShowmatch, kOptSmarttab, kOptSofttabstop,
  kOptTextwidth, kOptWrapmargin, kOptRevins, kOptVarsofttabstop, kOptInvalid
};

/* === removed: implemented in src/odin/option.odin === */


/// Initialize the 'shell' option to a default value.
static void set_init_default_shell(void)
{
  // Find default value for 'shell' option.
  // Don't use it if it is empty.
  char *shell = os_getenv("SHELL");
  if (shell != NULL) {
    if (vim_strchr(shell, ' ') != NULL) {
      const size_t len = strlen(shell) + 3;  // two quotes and a trailing NUL
      char *const cmd = xmalloc(len);
      snprintf(cmd, len, "\"%s\"", shell);
      set_string_default(kOptShell, cmd, true);
    } else {
      set_string_default(kOptShell, shell, false);
    }
    xfree(shell);
  }
}

/// Set the default for 'backupskip' to include environment variables for
/// temp files.
static void set_init_default_backupskip(void)
{
#ifdef UNIX
  static char *(names[4]) = { "", "TMPDIR", "TEMP", "TMP" };
#else
  static char *(names[3]) = { "TMPDIR", "TEMP", "TMP" };
#endif
  garray_T ga;
  OptIndex opt_idx = kOptBackupskip;

  ga_init(&ga, 1, 100);
  for (size_t i = 0; i < ARRAY_SIZE(names); i++) {
    bool mustfree = true;
    char *p;
    size_t plen;
#ifdef UNIX
    if (*names[i] == NUL) {
# ifdef __APPLE__
      p = "/private/tmp";
      plen = STRLEN_LITERAL("/private/tmp");
# else
      p = "/tmp";
      plen = STRLEN_LITERAL("/tmp");
# endif
      mustfree = false;
    } else
#endif
    {
      p = vim_getenv(names[i]);
      plen = 0;  // will be calculated below
    }
    if (p != NULL && *p != NUL) {
      bool has_trailing_path_sep = false;

      if (plen == 0) {
        // the value was retrieved from the environment
        plen = strlen(p);
        // does the value include a trailing path separator?
        if (after_pathsep(p, p + plen)) {
          has_trailing_path_sep = true;
        }
      }

      // item size needs to be large enough to include "/*" and a trailing NUL
      // note: the value (and therefore plen) may already include a path separator
      size_t itemsize = plen + (has_trailing_path_sep ? 0 : 1) + 2;
      char *item = xmalloc(itemsize);
      // add a preceding comma as a separator after the first item
      size_t itemseplen = (ga.ga_len == 0) ? 0 : 1;

      size_t itemlen = (size_t)vim_snprintf(item, itemsize, "%s%s*", p,
                                            has_trailing_path_sep ? "" : PATHSEPSTR);

      if (find_dup_item(ga.ga_data, item, itemlen, options[opt_idx].flags) == NULL) {
        ga_grow(&ga, (int)(itemseplen + itemlen + 1));
        ga.ga_len += vim_snprintf((char *)ga.ga_data + ga.ga_len,
                                  itemseplen + itemlen + 1,
                                  "%s%s", (itemseplen > 0) ? "," : "", item);
      }
      xfree(item);
    }
    if (mustfree) {
      xfree(p);
    }
  }
  if (ga.ga_data != NULL) {
    set_string_default(kOptBackupskip, ga.ga_data, true);
  }
}

/// Initialize the 'cdpath' option to a default value.
static void set_init_default_cdpath(void)
{
  char *cdpath = vim_getenv("CDPATH");
  if (cdpath == NULL) {
    return;
  }

  char *buf = xmalloc(2 * strlen(cdpath) + 2);
  buf[0] = ',';               // start with ",", current dir first
  int j = 1;
  for (int i = 0; cdpath[i] != NUL; i++) {
    if (vim_ispathlistsep(cdpath[i])) {
      buf[j++] = ',';
    } else {
      if (cdpath[i] == ' ' || cdpath[i] == ',') {
        buf[j++] = '\\';
      }
      buf[j++] = cdpath[i];
    }
  }
  buf[j] = NUL;
  change_option_default(kOptCdpath, CSTR_AS_OPTVAL(buf));

  xfree(cdpath);
}

/// Expand environment variables and things like "~" for the defaults.
/// If option_expand() returns non-NULL the variable is expanded.  This can
/// only happen for non-indirect options.
/// Also set the default to the expanded value, so ":set" does not list
/// them.
static void set_init_expand_env(void)
{
  for (OptIndex opt_idx = 0; opt_idx < kOptCount; opt_idx++) {
    vimoption_T *opt = &options[opt_idx];
    if (opt->flags & kOptFlagNoDefExp) {
      continue;
    }
    char *p;
    if ((opt->flags & kOptFlagGettext) && opt->var != NULL) {
      p = _(*(char **)opt->var);
    } else {
      p = option_expand(opt_idx, NULL);
    }
    if (p != NULL) {
      set_option_varp(opt_idx, opt->var, CSTR_TO_OPTVAL(p), true);
      change_option_default(opt_idx, CSTR_TO_OPTVAL(p));
    }
  }
}

/// Initialize the encoding used for "default" in 'fileencodings'.
static void set_init_fenc_default(void)
{
  // enc_locale() will try to find the encoding of the current locale.
  // This will be used when "default" is used as encoding specifier
  // in 'fileencodings'.
  char *p = enc_locale();
  if (p == NULL) {
    // Use utf-8 as "default" if locale encoding can't be detected.
    p = xmemdupz(S_LEN("utf-8"));
  }
  fenc_default = p;
}

/// Initialize the options, first part.
///
/// Called only once from main(), just after creating the first buffer.
/// If "clean_arg" is true, Nvim was started with --clean.
///
/// NOTE: ELOG() etc calls are not allowed here, as log location depends on
/// env var expansion which depends on expression evaluation and other
/// editor state initialized here. Do logging in set_init_2 or later.
void set_init_1(bool clean_arg)
{
  langmap_init();

  // Allocate the default option values.
  alloc_options_default();

  set_init_default_shell();
  set_init_default_backupskip();
  set_init_default_cdpath();

  char *backupdir = stdpaths_user_state_subpath("backup", 2, true);
  const size_t backupdir_len = strlen(backupdir);
  backupdir = xrealloc(backupdir, backupdir_len + 3);
  memmove(backupdir + 2, backupdir, backupdir_len + 1);
  memmove(backupdir, ".,", 2);
  set_string_default(kOptBackupdir, backupdir, true);
  set_string_default(kOptViewdir, stdpaths_user_state_subpath("view", 2, false),
                     true);
  set_string_default(kOptDirectory, stdpaths_user_state_subpath("swap", 2, true),
                     true);
  set_string_default(kOptUndodir, stdpaths_user_state_subpath("undo", 2, true),
                     true);
  // Set default for &runtimepath. All necessary expansions are performed in
  // this function.
  char *rtp = runtimepath_default(clean_arg);
  if (rtp) {
    set_string_default(kOptRuntimepath, rtp, true);
    // Make a copy of 'rtp' for 'packpath'
    set_string_default(kOptPackpath, rtp, false);
    rtp = NULL;  // ownership taken
  }

  // Set all the options (except the terminal options) to their default
  // value.  Also set the global value for local options.
  set_options_default(0);

  curbuf->b_p_initialized = true;
  curbuf->b_p_ac = -1;
  curbuf->b_p_ar = -1;          // no local 'autoread' value
  curbuf->b_p_fs = -1;          // no local 'fsync' value
  curbuf->b_p_ul = NO_LOCAL_UNDOLEVEL;
  check_buf_options(curbuf);
  check_win_options(curwin);
  check_options();

  // set 'laststatus'
  last_status(false);

  // Must be before option_expand(), because that one needs vim_isIDc()
  didset_options();

  // Use the current chartab for the generic chartab. This is not in
  // didset_options() because it only depends on 'encoding'.
  init_spell_chartab();

  // Expand environment variables and things like "~" for the defaults.
  set_init_expand_env();

  // Allow disabling ttyfast during startup to disable features such as
  // automatic background detection over slow connections.
  if (os_env_exists("NVIM_NOTTYFAST", false)) {
    set_option_value_give_err(kOptTtyfast, BOOLEAN_OPTVAL(false), 0);
  }

  save_file_ff(curbuf);         // Buffer is unchanged

  // Detect use of mlterm.
  // Mlterm is a terminal emulator akin to xterm that has some special
  // abilities (bidi namely).
  // NOTE: mlterm's author is being asked to 'set' a variable
  //       instead of an environment variable due to inheritance.
  if (os_env_exists("MLTERM", false)) {
    set_option_value_give_err(kOptTermbidi, BOOLEAN_OPTVAL(true), 0);
  }

  didset_options2();

  lang_init();
  set_init_fenc_default();

#ifdef HAVE_WORKING_LIBINTL
  // GNU gettext 0.10.37 supports this feature: set the codeset used for
  // translated messages independently from the current locale.
  (void)bind_textdomain_codeset(PROJECT_NAME, p_enc);
#endif

  // Set the default for 'helplang'.
  set_helplang_default(get_mess_lang());
}

/// Get default value for option, based on the option's type and scope.
///
/// @param  opt_idx    Option index in options[] table.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
///
/// @return Default value of option for the scope specified in opt_flags.
/* === removed: implemented in src/odin/option.odin === */


/// Allocate the default values for all options by copying them from the stack.
/// This ensures that we don't need to always check if the option default is allocated or not.
static void alloc_options_default(void)
{
  for (OptIndex opt_idx = 0; opt_idx < kOptCount; opt_idx++) {
    options[opt_idx].def_val = optval_copy(options[opt_idx].def_val);
  }
}

/// Change the default value for an option.
///
/// @param  opt_idx  Option index in options[] table.
/// @param  value    New default value. Must be allocated.
static void change_option_default(const OptIndex opt_idx, OptVal value)
{
  optval_free(options[opt_idx].def_val);
  options[opt_idx].def_val = value;
}

/// Set an option to its default value.
/// This does not take care of side effects!
///
/// @param  opt_idx    Option index in options[] table.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
static void set_option_default(const OptIndex opt_idx, int opt_flags)
{
  bool both = (opt_flags & (OPT_LOCAL | OPT_GLOBAL)) == 0;
  OptVal def_val = get_option_default(opt_idx, opt_flags);
  set_option_direct(opt_idx, def_val, opt_flags, current_sctx.sc_sid);

  if (opt_idx == kOptScroll) {
    win_comp_scroll(curwin);
  }

  // The default value is not insecure.
  uint32_t *flagsp = insecure_flag(curwin, opt_idx, opt_flags);
  *flagsp = *flagsp & ~(unsigned)kOptFlagInsecure;
  if (both) {
    flagsp = insecure_flag(curwin, opt_idx, OPT_LOCAL);
    *flagsp = *flagsp & ~(unsigned)kOptFlagInsecure;
  }
}

/// Set all options (except terminal options) to their default value.
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
static void set_options_default(int opt_flags)
{
  for (OptIndex opt_idx = 0; opt_idx < kOptCount; opt_idx++) {
    if (!(options[opt_idx].flags & kOptFlagNoDefault)) {
      set_option_default(opt_idx, opt_flags);
    }
  }

  // The 'scroll' option must be computed for all windows.
  FOR_ALL_TAB_WINDOWS(tp, wp) {
    win_comp_scroll(wp);
  }

  parse_cino(curbuf);
}

/// Set the Vi-default value of a string option.
/// Used for 'sh', 'backupskip' and 'term'.
///
/// @param  opt_idx    Option index in options[] table.
/// @param  val        The value of the option.
/// @param  allocated  If true, do not copy default as it was already allocated.
///
/// TODO(famiu): Remove this.
static void set_string_default(OptIndex opt_idx, char *val, bool allocated)
  FUNC_ATTR_NONNULL_ALL
{
  assert(opt_idx != kOptInvalid);
  change_option_default(opt_idx, CSTR_AS_OPTVAL(allocated ? val : xstrdup(val)));
}

/// For an option value that contains comma separated items, find "newval" in
/// "origval".  Return NULL if not found.
static const char *find_dup_item(const char *origval, const char *newval, const size_t newvallen,
                                 uint32_t flags)
  FUNC_ATTR_NONNULL_ARG(2)
{
  if (origval == NULL) {
    return NULL;
  }

  int bs = 0;

  for (const char *s = origval; *s != NUL; s++) {
    if ((!(flags & kOptFlagComma) || s == origval || (s[-1] == ',' && !(bs & 1)))
        && strncmp(s, newval, newvallen) == 0
        && (!(flags & kOptFlagComma) || s[newvallen] == ',' || s[newvallen] == NUL)) {
      return s;
    }
    // Count backslashes.  Only a comma with an even number of backslashes
    // or a single backslash preceded by a comma before it is recognized as
    // a separator.
    if ((s > origval + 1 && s[-1] == '\\' && s[-2] != ',')
        || (s == origval + 1 && s[-1] == '\\')) {
      bs++;
    } else {
      bs = 0;
    }
  }
  return NULL;
}

#ifdef EXITFREE
/// Free all options.
/* === removed: implemented in src/odin/option.odin === */

#endif

/// Initialize the options, part two: After getting Rows and Columns.
void set_init_2(bool headless)
{
  // set in set_init_1 but logging is not allowed there
  ILOG("startup runtimepath/packpath value: %s", p_rtp);

  // 'scroll' defaults to half the window height. The stored default is zero,
  // which results in the actual value computed from the window height.
  if (!(options[kOptScroll].flags & kOptFlagWasSet)) {
    set_option_default(kOptScroll, OPT_LOCAL);
  }
  comp_col();

  // 'window' is only for backwards compatibility with Vi.
  // Default is Rows - 1.
  if (!option_was_set(kOptWindow)) {
    p_window = Rows - 1;
  }
  change_option_default(kOptWindow, NUMBER_OPTVAL(Rows - 1));
}

static const struct {
  const char *pat;
  const char *shcf;
  const char *sp;
  const char *srr;
  const char *sxq;
} shell_rules[] = {
#ifdef MSWIN
  { "cmd",        "/s /c",    NULL,        NULL,       "\"" },
  { "powershell", "-Command", NULL,        NULL,       NULL },
#endif
  { "csh",        NULL,       "|& tee",    ">&",       NULL },
  { "sh",         NULL,       "2>&1| tee", ">%s 2>&1", NULL },
};

static void change_option_and_default_if_unset(OptIndex idx, const char *val)
{
  if (val == NULL || options[idx].flags & kOptFlagWasSet) {
    return;
  }
  OptVal optval = CSTR_AS_OPTVAL(val);
  set_option_direct(idx, optval, 0, SID_NONE);
  change_option_default(idx, optval_copy(optval));
}

/// Initialize the options, part three: After reading the .vimrc
void set_init_3(void)
{
  parse_shape_opt(SHAPE_CURSOR);   // set cursor shapes from 'guicursor'

  size_t len;
  char name[MAXPATHL];
  const char *p = invocation_path_tail(p_sh, &len);
  xmemcpyz(name, p, len);
  for (size_t i = 0; i < ARRAY_SIZE(shell_rules); i++) {
    if (strstr(name, shell_rules[i].pat) == NULL) {
      continue;
    }
    change_option_and_default_if_unset(kOptShellcmdflag, shell_rules[i].shcf);
    change_option_and_default_if_unset(kOptShellpipe, shell_rules[i].sp);
    change_option_and_default_if_unset(kOptShellredir, shell_rules[i].srr);
    change_option_and_default_if_unset(kOptShellxquote, shell_rules[i].sxq);
#ifdef MSWIN
    if (i > 0 && !(options[kOptShellslash].flags & kOptFlagWasSet)) {
      // Use `/` as path separator on Unix-like shells or powershell on Windows
      set_option_direct(kOptShellslash, BOOLEAN_OPTVAL(true), 0, SID_NONE);
      change_option_default(kOptShellslash, BOOLEAN_OPTVAL(true));
    }
#endif
    break;
  }

  if (buf_is_empty(curbuf)) {
    // Apply the first entry of 'fileformats' to the initial buffer.
    if (options[kOptFileformats].flags & kOptFlagWasSet) {
      set_fileformat(default_fileformat(), OPT_LOCAL);
    }
  }

  set_title_defaults();  // 'title', 'icon'
}

/// When 'helplang' is still at its default value, set it to "lang".
/// Only the first two characters of "lang" are used.
/* === removed: implemented in src/odin/option.odin === */


/// 'title' and 'icon' only default to true if they have not been set or reset
/// in .vimrc and we can read the old value.
/// When 'title' and 'icon' have been reset in .vimrc, we won't even check if
/// they can be reset.  This reduces startup time when using X on a remote
/// machine.
/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


/// Copy the new string value into allocated memory for the option.
/// Can't use set_option_direct(), because we need to remove the backslashes.
static char *stropt_copy_value(const char *origval, char **argp, set_op_T op,
                               uint32_t flags FUNC_ATTR_UNUSED)
{
  char *arg = *argp;

  // get a bit too much
  size_t newlen = strlen(arg) + 1;
  if (op != OP_NONE) {
    newlen += strlen(origval) + 1;
  }
  char *newval = xmalloc(newlen);
  char *s = newval;

  // Copy the string, skip over escaped chars.
  // For MS-Windows backslashes before normal file name characters
  // are not removed, and keep backslash at start, for "\\machine\path",
  // but do remove it for "\\\\machine\\path".
  // The reverse is found in escape_option_str_cmdline().
  while (*arg != NUL && !ascii_iswhite(*arg)) {
    if (*arg == '\\' && arg[1] != NUL
#ifdef BACKSLASH_IN_FILENAME
        && !((flags & kOptFlagExpand)
             && vim_isfilec((uint8_t)arg[1])
             && !ascii_iswhite(arg[1])
             && (arg[1] != '\\'
                 || (s == newval && arg[2] != '\\')))
#endif
        ) {
      arg++;  // remove backslash
    }
    int i = utfc_ptr2len(arg);
    if (i > 1) {
      // copy multibyte char
      memmove(s, arg, (size_t)i);
      arg += i;
      s += i;
    } else {
      *s++ = *arg++;
    }
  }
  *s = NUL;

  *argp = arg;
  return newval;
}

/// Expand environment variables and ~ in string option value 'newval'.
static char *stropt_expand_envvar(OptIndex opt_idx, const char *origval, char *newval, set_op_T op)
{
  char *s = option_expand(opt_idx, newval);
  if (s == NULL) {
    return newval;
  }

  xfree(newval);
  uint32_t newlen = (unsigned)strlen(s) + 1;
  if (op != OP_NONE) {
    newlen += (unsigned)strlen(origval) + 1;
  }
  newval = xmalloc(newlen);
  STRCPY(newval, s);

  return newval;
}

/// Concatenate the original and new values of a string option, adding a "," if
/// needed.
static void stropt_concat_with_comma(const char *origval, char *newval, set_op_T op, uint32_t flags)
{
  int len = 0;
  int comma = ((flags & kOptFlagComma) && *origval != NUL && *newval != NUL);
  if (op == OP_ADDING) {
    len = (int)strlen(origval);
    // Strip a trailing comma, would get 2.
    if (comma && len > 1
        && (flags & kOptFlagOneComma) == kOptFlagOneComma
        && origval[len - 1] == ','
        && origval[len - 2] != '\\') {
      len--;
    }
    memmove(newval + len + comma, newval, strlen(newval) + 1);
    memmove(newval, origval, (size_t)len);
  } else {
    len = (int)strlen(newval);
    STRMOVE(newval + len + comma, origval);
  }
  if (comma) {
    newval[len] = ',';
  }
}

/// Remove a value from a string option.  Copy string option value in "origval"
/// to "newval" and then remove the string "strval" of length "len".
static void stropt_remove_val(const char *origval, char *newval, uint32_t flags, const char *strval,
                              int len)
{
  // Remove newval[] from origval[]. (Note: "len" has been set above
  // and is used here).
  STRCPY(newval, origval);
  if (*strval) {
    // may need to remove a comma
    if (flags & kOptFlagComma) {
      if (strval == origval) {
        // include comma after string
        if (strval[len] == ',') {
          len++;
        }
      } else {
        // include comma before string
        strval--;
        len++;
      }
    }
    STRMOVE(newval + (strval - origval), strval + len);
  }
}

/// Find a comma-separated item in "src" that matches the key part of "key".
/// The key is the part before ':'.  "keylen" is the length including ':'.
/// Returns a pointer to the found item in "src", or NULL if not found.
/// Sets "*itemlenp" to the length of the found item (up to ',' or NUL).
static char *find_key_item(char *src, char *key, ptrdiff_t keylen, ptrdiff_t *itemlenp)
{
  char *p = src;

  while (*p != NUL) {
    // Check if this item starts with the same key
    if ((p == src || *(p - 1) == ',') && strncmp(p, key, (size_t)keylen) == 0) {
      // Find the end of this item
      char *end = vim_strchr(p, ',');
      if (end == NULL) {
        end = p + strlen(p);
      }
      *itemlenp = end - p;
      return p;
    }
    p++;
  }
  return NULL;
}

/// Remove one item of length "itemlen" at position "item" from comma-separated
/// string "str" in-place.  Handles the comma before or after the item.
static void remove_comma_item(const char *str, char *item, ptrdiff_t itemlen)
{
  if (item[itemlen] == ',') {
    // Remove item and trailing comma
    STRMOVE(item, item + itemlen + 1);
  } else if (item > str && *(item - 1) == ',') {
    // Last item: remove leading comma and item
    STRMOVE(item - 1, item + itemlen);
  } else {
    // Only item
    *item = NUL;
  }
}

/// Remove all items matching "key" (with ':') from comma-separated string "str"
/// in-place.  If "skip" is not NULL, the item at that position is kept.
static void remove_key_item(char *str, char *key, ptrdiff_t keylen, const char *skip)
{
  ptrdiff_t itemlen;
  char *found;

  while ((found = find_key_item(str, key, keylen, &itemlen)) != NULL) {
    if (found == skip) {
      // Search for the next match after this one.
      char *next = found + itemlen;
      if (*next == ',') {
        next++;
      }
      found = find_key_item(next, key, keylen, &itemlen);
      if (found == NULL) {
        break;
      }
    }

    remove_comma_item(str, found, itemlen);
  }
}

/// Append a comma-separated item to the end of "str" in-place.
/// Adds a comma before the item if "str" is not empty.
static void append_item(char *str, char *item, ptrdiff_t item_len)
{
  ptrdiff_t len = (ptrdiff_t)strlen(str);

  if (len > 0) {
    str[len++] = ',';
  }
  memmove(str + len, item, (size_t)item_len);
  str[len + item_len] = NUL;
}

/// Prepend a comma-separated item to the beginning of "str" in-place.
/// Adds a comma after the item if "str" is not empty.
static void prepend_item(char *str, char *item, ptrdiff_t item_len)
{
  ptrdiff_t len = (ptrdiff_t)strlen(str);
  int comma = (len > 0) ? 1 : 0;

  memmove(str + item_len + comma, str, (size_t)len + 1);
  memmove(str, item, (size_t)item_len);
  if (comma) {
    str[item_len] = ',';
  }
}

/// For a P_COMMA option: process "key:value" items in "newval" individually.
/// Each comma-separated item in "newval" is checked against "origval":
///
/// For OP_ADDING/OP_PREPENDING, each item is handled as follows:
///   - colon item, key exists with different value: replace (remove old, add)
///   - colon item, exact duplicate: do nothing
///   - colon item, not found: add to end
///   - non-colon item, exists: do nothing
///   - non-colon item, not found: add to end
///
/// For OP_REMOVING, each item is handled as follows:
///   - colon item: remove by key match
///   - non-colon item: remove by exact match
///
/// The result is written to "newval".
/// Returns true if the operation was fully handled (caller should skip the
/// normal add/remove logic).  Returns false if newval is a single non-colon
/// item, meaning the caller should use the existing code path.
static bool stropt_handle_keymatch(const char *origval, char *newval, set_op_T op, uint32_t flags)
{
  // Check if newval contains any "key:value" item or multiple
  // comma-separated items.  If neither, let the caller use the existing
  // code path.
  if (vim_strchr(newval, ':') == NULL && vim_strchr(newval, ',') == NULL) {
    return false;
  }

  // Work on a copy of newval for iteration.
  char *newval_copy = xstrdup(newval);

  // Build the result in newval.  Start with a copy of origval, then
  // modify it per-item.  newval buffer has room for origval + arg.
  STRCPY(newval, origval);

  // Process each item individually, modifying newval in-place.
  char *item_start = newval_copy;
  while (true) {
    char *p = vim_strchr(item_start, ',');
    ptrdiff_t item_len = p == NULL ? (ptrdiff_t)strlen(item_start) : p - item_start;

    if (item_len > 0) {
      char *colon = vim_strchr(item_start, ':');
      if (colon != NULL && colon < item_start + item_len) {
        ptrdiff_t keylen = (colon - item_start) + 1;

        if (op == OP_ADDING || op == OP_PREPENDING) {
          ptrdiff_t old_itemlen;
          char *found = find_key_item(newval, item_start, keylen, &old_itemlen);
          if (found != NULL) {
            if (old_itemlen == item_len
                && strncmp(found, item_start, (size_t)item_len) == 0) {
              // Exact duplicate: keep it in place, but
              // remove other items with the same key.
              remove_key_item(newval, item_start, keylen, found);
            } else {
              // Key match with different value: remove all
              // items with the same key, then add.
              remove_key_item(newval, item_start, keylen, NULL);
              if (op == OP_PREPENDING) {
                prepend_item(newval, item_start, item_len);
              } else {
                append_item(newval, item_start, item_len);
              }
            }
          } else {
            // New item.
            if (op == OP_PREPENDING) {
              prepend_item(newval, item_start, item_len);
            } else {
              append_item(newval, item_start, item_len);
            }
          }
        } else if (op == OP_REMOVING) {
          remove_key_item(newval, item_start, keylen, NULL);
        }
      } else {
        if (op == OP_ADDING || op == OP_PREPENDING) {
          const char *found = find_dup_item(newval, item_start, (size_t)item_len,
                                            kOptFlagComma);
          if (found == NULL) {
            // New item.
            if (op == OP_PREPENDING) {
              prepend_item(newval, item_start, item_len);
            } else {
              append_item(newval, item_start, item_len);
            }
          }
          // else: exact duplicate — do nothing
        } else if (op == OP_REMOVING) {
          char *found = (char *)find_dup_item(newval, item_start, (size_t)item_len,
                                              kOptFlagComma);
          if (found != NULL) {
            remove_comma_item(newval, found, item_len);
          }
        }
      }
    }

    if (p == NULL) {
      break;
    }
    item_start = p + 1;
  }

  xfree(newval_copy);

  return true;
}

/// Remove flags that appear twice in the string option value 'newval'.
static void stropt_remove_dupflags(char *newval, uint32_t flags)
{
  char *s = newval;
  // Remove flags that appear twice.
  for (s = newval; *s;) {
    // if options have kOptFlagFlagList and kOptFlagOneComma such as 'whichwrap'
    if (flags & kOptFlagOneComma) {
      if (*s != ',' && *(s + 1) == ','
          && vim_strchr(s + 2, (uint8_t)(*s)) != NULL) {
        // Remove the duplicated value and the next comma.
        STRMOVE(s, s + 2);
        continue;
      }
    } else {
      if ((!(flags & kOptFlagComma) || *s != ',')
          && vim_strchr(s + 1, (uint8_t)(*s)) != NULL) {
        STRMOVE(s, s + 1);
        continue;
      }
    }
    s++;
  }
}

/// Get the string value specified for a ":set" command.  The following set options are supported:
///     set {opt}={val}
///     set {opt}:{val}
static char *stropt_get_newval(OptIndex opt_idx, char **argp, void *varp, const char *origval,
                               set_op_T *op_arg)
{
  char *arg = *argp;
  set_op_T op = *op_arg;
  char *save_arg = NULL;
  char *newval;
  const char *s = NULL;
  uint32_t flags = options[opt_idx].flags;

  arg++;  // jump to after the '=' or ':'

  // Set 'keywordprg' to ":help" if an empty
  // value was passed to :set by the user.
  if (varp == &p_kp && (*arg == NUL || *arg == ' ')) {
    save_arg = arg;
    arg = ":help";
  }

  // Copy the new string into allocated memory.
  newval = stropt_copy_value(origval, &arg, op, flags);

  // Expand environment variables and ~.
  // Don't do it when adding without inserting a comma.
  if (op == OP_NONE || (flags & kOptFlagComma)) {
    newval = stropt_expand_envvar(opt_idx, origval, newval, op);
  }

  // For kOptFlagComma|kOptFlagColon options with "key:value" items: process each item
  // individually by matching on the key part.
  // If handled, skip the normal add/remove logic below.
  if ((flags & kOptFlagComma) && (flags & kOptFlagColon) && op != OP_NONE
      && stropt_handle_keymatch(origval, newval, op, flags)) {
    // fully handled
  } else {
    // locate newval[] in origval[] when removing it and when
    // adding to avoid duplicates
    int len = 0;
    if (op == OP_REMOVING || (flags & kOptFlagNoDup)) {
      len = (int)strlen(newval);
      s = find_dup_item(origval, newval, (size_t)len, flags);

      // do not add if already there
      if ((op == OP_ADDING || op == OP_PREPENDING) && s != NULL) {
        op = OP_NONE;
        STRCPY(newval, origval);
      }

      // if no duplicate, move pointer to end of original value
      if (s == NULL) {
        s = origval + (int)strlen(origval);
      }
    }

    // concatenate the two strings; add a ',' if needed
    if (op == OP_ADDING || op == OP_PREPENDING) {
      stropt_concat_with_comma(origval, newval, op, flags);
    } else if (op == OP_REMOVING) {
      // Remove newval[] from origval[]. (Note: "len" has been
      // set above and is used here).
      stropt_remove_val(origval, newval, flags, s, len);
    }
  }

  if (flags & kOptFlagFlagList) {
    // Remove flags that appear twice.
    stropt_remove_dupflags(newval, flags);
  }

  if (save_arg != NULL) {
    arg = save_arg;  // arg was temporarily changed, restore it
  }
  *argp = arg;
  *op_arg = op;

  return newval;
}

static set_op_T get_op(const char *arg)
{
  set_op_T op = OP_NONE;
  if (*arg != NUL && *(arg + 1) == '=') {
    if (*arg == '+') {
      op = OP_ADDING;          // "+="
    } else if (*arg == '^') {
      op = OP_PREPENDING;      // "^="
    } else if (*arg == '-') {
      op = OP_REMOVING;        // "-="
    }
  }
  return op;
}

static set_prefix_T get_option_prefix(char **argp)
{
  if (strncmp(*argp, "no", 2) == 0) {
    *argp += 2;
    return PREFIX_NO;
  } else if (strncmp(*argp, "inv", 3) == 0) {
    *argp += 3;
    return PREFIX_INV;
  }

  return PREFIX_NONE;
}

static int validate_opt_idx(win_T *win, OptIndex opt_idx, int opt_flags, uint32_t flags,
                            set_prefix_T prefix, const char **errmsg)
{
  // Only bools can have a prefix of 'inv' or 'no'
  if (!option_has_type(opt_idx, kOptValTypeBoolean) && prefix != PREFIX_NONE) {
    *errmsg = e_invarg;
    return FAIL;
  }

  // Skip all options that are not window-local (used when showing
  // an already loaded buffer in a window).
  if ((opt_flags & OPT_WINONLY) && !option_is_window_local(opt_idx)) {
    return FAIL;
  }

  // Skip all options that are window-local (used for :vimgrep).
  if ((opt_flags & OPT_NOWIN) && option_is_window_local(opt_idx)) {
    return FAIL;
  }

  // Disallow changing some options from modelines.
  if (opt_flags & OPT_MODELINE) {
    if (flags & kOptFlagSecure) {
      *errmsg = e_not_allowed_in_modeline;
      return FAIL;
    }
    if ((flags & kOptFlagMLE) && !p_mle) {
      *errmsg = e_not_allowed_in_modeline_when_modelineexpr_is_off;
      return FAIL;
    }
    // In diff mode some options are overruled.  This avoids that
    // 'foldmethod' becomes "marker" instead of "diff" and that
    // "wrap" gets set.
    if (win->w_p_diff && (opt_idx == kOptFoldmethod || opt_idx == kOptWrap)) {
      return FAIL;
    }
  }

  // Disallow changing some options in the sandbox
  if (sandbox != 0 && (flags & kOptFlagSecure)) {
    *errmsg = e_sandbox;
    return FAIL;
  }

  return OK;
}

/// Skip over the name of a TTY option or keycode option.
///
/// @param[in]  arg  Start of TTY or keycode option name.
///
/// @return NULL when option isn't a TTY or keycode option. Otherwise pointer to the char after the
/// option name.
static const char *find_tty_option_end(const char *arg)
{
  if (strequal(arg, "term")) {
    return arg + sizeof("term") - 1;
  } else if (strequal(arg, "ttytype")) {
    return arg + sizeof("ttytype") - 1;
  }

  const char *p = arg;
  bool delimit = false;  // whether to delimit <

  if (arg[0] == '<') {
    // look out for <t_>;>
    delimit = true;
    p++;
  }
  if (p[0] == 't' && p[1] == '_' && p[2] && p[3]) {
    // "t_xx" ("t_Co") option.
    p += 4;
  } else if (delimit) {
    // Search for delimiting >.
    while (*p != NUL && *p != '>') {
      p++;
    }
  }
  // Return NULL when delimiting > is not found.
  if (delimit) {
    if (*p != '>') {
      return NULL;
    }
    p++;
  }

  return arg == p ? NULL : p;
}

/// Skip over the name of an option.
///
/// @param[in]   arg       Start of option name.
/// @param[out]  opt_idxp  Set to option index in options[] table.
///
/// @return NULL when no option name found. Otherwise pointer to the char after the option name.
const char *find_option_end(const char *arg, OptIndex *opt_idxp)
{
  const char *p;

  // Handle TTY and keycode options separately.
  if ((p = find_tty_option_end(arg)) != NULL) {
    *opt_idxp = kOptInvalid;
    return p;
  } else {
    p = arg;
  }

  if (!ASCII_ISALPHA(*p)) {
    *opt_idxp = kOptInvalid;
    return NULL;
  }
  while (ASCII_ISALPHA(*p)) {
    p++;
  }

  *opt_idxp = find_option_len(arg, (size_t)(p - arg));
  return p;
}

/// Get new option value from argp. Allocated OptVal must be freed by caller.
/// Can unset local value of an option when ":set {option}<" is used.
/* === removed: implemented in src/odin/option.odin === */


static void do_one_set_option(int opt_flags, char **argp, bool *did_show, char *errbuf,
                              size_t errbuflen, const char **errmsg)
{
  // 1: nothing, 0: "no", 2: "inv" in front of name
  set_prefix_T prefix = get_option_prefix(argp);

  char *arg = *argp;

  // find end of name
  OptIndex opt_idx;
  const char *const option_end = find_option_end(arg, &opt_idx);

  if (opt_idx != kOptInvalid) {
    assert(option_end >= arg);
  } else if (is_tty_option(arg)) {  // Silently ignore TTY options.
    return;
  } else {                          // Invalid option name, skip.
    *errmsg = e_unknown_option;
    return;
  }

  // Remember character after option name.
  uint8_t afterchar = (uint8_t)(*option_end);
  char *p = (char *)option_end;

  // Skip white space, allow ":set ai  ?".
  while (ascii_iswhite(*p)) {
    p++;
  }

  set_op_T op = get_op(p);
  if (op != OP_NONE) {
    p++;
  }

  uint8_t nextchar = (uint8_t)(*p);  // next non-white char after option name
  // flags for current option
  uint32_t flags = options[opt_idx].flags;
  // pointer to variable for current option
  void *varp = get_varp_scope(&(options[opt_idx]), opt_flags);

  if (validate_opt_idx(curwin, opt_idx, opt_flags, flags, prefix, errmsg) == FAIL) {
    return;
  }

  if (vim_strchr("?=:!&<", nextchar) != NULL) {
    *argp = p;

    if (nextchar == '&' && (*argp)[1] == 'v' && (*argp)[2] == 'i') {
      if ((*argp)[3] == 'm') {  // "opt&vim": set to Vim default
        *argp += 3;
      } else {  // "opt&vi": set to Vi default
        *argp += 2;
      }
    }
    if (vim_strchr("?!&<", nextchar) != NULL
        && (*argp)[1] != NUL && !ascii_iswhite((*argp)[1])) {
      *errmsg = e_trailing;
      return;
    }
  }

  // Allow '=' and ':' as MS-DOS command.com allows only one '=' character per "set" command line.
  if (nextchar == '?'
      || (prefix == PREFIX_NONE && vim_strchr("=:&<", nextchar) == NULL
          && !option_has_type(opt_idx, kOptValTypeBoolean))) {
    // print value
    if (*did_show) {
      msg_putchar('\n');                // cursor below last one
    } else {
      msg_ext_set_kind("list_cmd");
      gotocmdline(true);                // cursor at status line
      *did_show = true;                 // remember that we did a line
    }
    showoneopt(&options[opt_idx], opt_flags);

    if (p_verbose > 0) {
      // Mention where the option was last set.
      if (varp == options[opt_idx].var) {
        last_set_msg(options[opt_idx].script_ctx);
      } else if (option_has_scope(opt_idx, kOptScopeWin)) {
        last_set_msg(curwin->w_p_script_ctx[option_scope_idx(opt_idx, kOptScopeWin)]);
      } else if (option_has_scope(opt_idx, kOptScopeBuf)) {
        last_set_msg(curbuf->b_p_script_ctx[option_scope_idx(opt_idx, kOptScopeBuf)]);
      }
    }

    if (nextchar != '?' && nextchar != NUL && !ascii_iswhite(afterchar)) {
      *errmsg = e_trailing;
    }
    return;
  }

  if (option_has_type(opt_idx, kOptValTypeBoolean)) {
    if (vim_strchr("=:", nextchar) != NULL) {
      *errmsg = e_invarg;
      return;
    }

    if (vim_strchr("!&<", nextchar) == NULL && nextchar != NUL && !ascii_iswhite(afterchar)) {
      *errmsg = e_trailing;
      return;
    }
  } else {
    if (vim_strchr("=:&<", nextchar) == NULL) {
      *errmsg = e_invarg;
      return;
    }
  }

  OptVal newval = get_option_newval(opt_idx, opt_flags, prefix, argp, nextchar, op, flags, varp,
                                    NULL, errbuf, errbuflen, errmsg);

  if (newval.type == kOptValTypeNil || *errmsg != NULL) {
    return;
  }

  *errmsg = set_option(opt_idx, newval, opt_flags, 0, false, op == OP_NONE, errbuf, errbuflen);
}

/// Parse 'arg' for option settings.
///
/// 'arg' may be IObuff, but only when no errors can be present and option
/// does not need to be expanded with option_expand().
/// "opt_flags":
/// 0 for ":set"
/// OPT_GLOBAL   for ":setglobal"
/// OPT_LOCAL    for ":setlocal" and a modeline
/// OPT_MODELINE for a modeline
/// OPT_WINONLY  to only set window-local options
/// OPT_NOWIN    to skip setting window-local options
///
/// @param arg  option string (may be written to!)
///
/// @return  FAIL if an error is detected, OK otherwise
/* === removed: implemented in src/odin/option.odin === */


// Translate a string like "t_xx", "<t_xx>" or "<S-Tab>" to a key number.
// When "has_lt" is true there is a '<' before "*arg_arg".
// Returns 0 when the key is not recognized.
static int find_key_len(const char *arg_arg, size_t len, bool has_lt)
{
  int key = 0;
  const char *arg = arg_arg;

  // Don't use get_special_key_code() for t_xx, we don't want it to call
  // add_termcap_entry().
  if (len >= 4 && arg[0] == 't' && arg[1] == '_') {
    if (!has_lt || arg[4] == '>') {
      key = TERMCAP2KEY((uint8_t)arg[2], (uint8_t)arg[3]);
    }
  } else if (has_lt) {
    arg--;  // put arg at the '<'
    int modifiers = 0;
    key = find_special_key(&arg, len + 1, &modifiers, FSK_KEYCODE | FSK_KEEP_X_KEY | FSK_SIMPLIFY,
                           NULL);
    if (modifiers) {  // can't handle modifiers here
      key = 0;
    }
  }
  return key;
}

/// Convert a key name or string into a key value.
/// Used for 'cedit', 'wildchar' and 'wildcharm' options.
/* === removed: implemented in src/odin/option.odin === */


// When changing 'title', 'titlestring', 'icon' or 'iconstring', call
// maketitle() to create and display it.
// When switching the title or icon off, call ui_set_{icon,title}(NULL) to get
// the old value back.
/* === removed: implemented in src/odin/option.odin === */


/// set_options_bin -  called when 'bin' changes value.
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/* === removed: implemented in src/odin/option.odin === */


/// Expand environment variables for some string options.
/// These string options cannot be indirect!
/// If "val" is NULL expand the current value of the option.
/// Return pointer to NameBuff, or NULL when not expanded.
static char *option_expand(OptIndex opt_idx, const char *val)
{
  // if option doesn't need expansion nothing to do
  if (!(options[opt_idx].flags & kOptFlagExpand) || is_option_hidden(opt_idx)) {
    return NULL;
  }

  if (val == NULL) {
    val = *(char **)options[opt_idx].var;
  }

  // If val is longer than MAXPATHL no meaningful expansion can be done,
  // expand_env() would truncate the string.
  if (val == NULL || strlen(val) > MAXPATHL) {
    return NULL;
  }

  // Expanding this with NameBuff, expand_env() must not be passed IObuff.
  // Escape spaces when expanding 'tags' or 'path', they are used to separate
  // file names.
  // For 'spellsuggest' expand after "file:".
  char **var = (char **)options[opt_idx].var;
  bool esc = var == &p_tags || var == &p_path;
  expand_env_esc(val, NameBuff, MAXPATHL, esc ? (char *)" \t" : NULL, false,
                 (char **)options[opt_idx].var == &p_sps ? "file:" : NULL);
  if (strcmp(NameBuff, val) == 0) {   // they are the same
    return NULL;
  }

  return NameBuff;
}

/// After setting various option values: recompute variables that depend on
/// option values.
static void didset_options(void)
{
  // initialize the table for 'iskeyword' et.al.
  init_chartab();

  didset_string_options();

  spell_check_msm();
  spell_check_sps();
  compile_cap_prog(curwin->w_s);
  did_set_spell_option();
  // set cedit_key
  did_set_cedit(NULL);
  // initialize the table for 'breakat'.
  did_set_breakat(NULL);
  didset_window_options(curwin, true);
}

// More side effects of setting options.
static void didset_options2(void)
{
  // Initialize the highlight_attr[] table.
  highlight_changed();

  // Parse default for 'fillchars'.
  set_chars_option(curwin, curwin->w_p_fcs, kFillchars, true, NULL, 0);

  // Parse default for 'listchars'.
  set_chars_option(curwin, curwin->w_p_lcs, kListchars, true, NULL, 0);

  // Parse default for 'wildmode'.
  check_opt_wim();
  xfree(curbuf->b_p_vsts_array);
  tabstop_set(curbuf->b_p_vsts, &curbuf->b_p_vsts_array);
  xfree(curbuf->b_p_vts_array);
  tabstop_set(curbuf->b_p_vts,  &curbuf->b_p_vts_array);
}

/// Repair UI state after `:set all&`.
///
/// `set_options_default` resets option values via `set_option_default` and
/// `set_option_direct` without invoking per-option `did_set` callbacks, so
/// UI-derived state (cursor shape, statusline, tabline) can get out of sync.
/// This function patches the known cases.
///
/// Note: We intentionally do not replay all `did_set` callbacks
/// (`opt_did_set_cb`) because they have order-dependent side effects and
/// old/new transition logic that does not hold when values are already reset.
static void didset_options_all(void)
{
  const char *errmsg = parse_shape_opt(SHAPE_CURSOR);
  assert(errmsg == NULL);
  (void)errmsg;
  last_status(false);
  win_float_update_statusline();
  win_new_screen_rows();
}

/// Check for string options that are NULL (normally only termcap options).
/* === removed: implemented in src/odin/option.odin === */


/// Check if option was set insecurely.
///
/// @param  wp         Window.
/// @param  opt_idx    Option index in options[] table.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
///
/// @return  True if option was set from a modeline or in secure mode, false if it wasn't.
/* === removed: implemented in src/odin/option.odin === */


/// Get a pointer to the flags used for the kOptFlagInsecure flag of option
/// "opt_idx".  For some local options a local flags field is used.
/// NOTE: Caller must make sure that "wp" is set to the window from which
/// the option is used.
uint32_t *insecure_flag(win_T *const wp, OptIndex opt_idx, int opt_flags)
{
  if (opt_flags & OPT_LOCAL) {
    assert(wp != NULL);
    switch (opt_idx) {
    case kOptWrap:
      return &wp->w_p_wrap_flags;
    case kOptStatusline:
      return &wp->w_p_stl_flags;
    case kOptWinbar:
      return &wp->w_p_wbr_flags;
    case kOptFoldexpr:
      return &wp->w_p_fde_flags;
    case kOptFoldtext:
      return &wp->w_p_fdt_flags;
    case kOptIndentexpr:
      return &wp->w_buffer->b_p_inde_flags;
    case kOptFormatexpr:
      return &wp->w_buffer->b_p_fex_flags;
    case kOptIncludeexpr:
      return &wp->w_buffer->b_p_inex_flags;
    default:
      break;
    }
  } else {
    // For global value of window-local options, use flags in w_allbuf_opt.
    switch (opt_idx) {
    case kOptWrap:
      return &wp->w_allbuf_opt.wo_wrap_flags;
    case kOptFoldexpr:
      return &wp->w_allbuf_opt.wo_fde_flags;
    case kOptFoldtext:
      return &wp->w_allbuf_opt.wo_fdt_flags;
    default:
      break;
    }
  }
  // Nothing special, return global flags field.
  return &options[opt_idx].flags;
}

/// Redraw the window title and/or tab page text later.
/* === removed: implemented in src/odin/option.odin === */


/// Return true if "val" is a valid name: only consists of alphanumeric ASCII
/// characters or characters in "allowed".
/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


/// Handle setting `winhighlight' in window "wp"
///
/// @param winhl  when NULL: use "wp->w_p_winhl"
/// @param wp     when NULL: only parse "winhl"
///
/// @return  whether the option value is valid.
/* === removed: implemented in src/odin/option.odin === */


/// Get the script context of global option at index opt_idx.
sctx_T *get_option_sctx(OptIndex opt_idx)
{
  assert(opt_idx != kOptInvalid);
  return &options[opt_idx].script_ctx;
}

/// Set the script_ctx for an option, taking care of setting the buffer- or
/// window-local value.
void set_option_sctx(OptIndex opt_idx, int opt_flags, sctx_T script_ctx)
{
  bool both = (opt_flags & (OPT_LOCAL | OPT_GLOBAL)) == 0;

  // Modeline already has the line number set.
  if (!(opt_flags & OPT_MODELINE)) {
    script_ctx.sc_lnum += SOURCING_LNUM;
  }
  nlua_set_sctx(&script_ctx);

  // Remember where the option was set.  For local options need to do that
  // in the buffer or window structure.
  if (both || (opt_flags & OPT_GLOBAL) || option_is_global_only(opt_idx)) {
    options[opt_idx].script_ctx = script_ctx;
  }
  if (both || (opt_flags & OPT_LOCAL)) {
    if (option_has_scope(opt_idx, kOptScopeBuf)) {
      curbuf->b_p_script_ctx[option_scope_idx(opt_idx, kOptScopeBuf)] = script_ctx;
    } else if ((option_has_scope(opt_idx, kOptScopeWin))) {
      curwin->w_p_script_ctx[option_scope_idx(opt_idx, kOptScopeWin)] = script_ctx;
      if (both) {
        // also setting the "all buffers" value
        curwin->w_allbuf_opt.wo_script_ctx[option_scope_idx(opt_idx, kOptScopeWin)] = script_ctx;
      }
    }
  }
}

/// Execute OptionSet autocmd now (not deferred).
/* === removed: implemented in src/odin/option.odin === */


/// For 'modified', the event is deferred.
static void apply_optionset_autocmd(OptIndex opt_idx, int opt_flags, OptVal oldval, OptVal oldval_g,
                                    OptVal oldval_l, OptVal newval, const char *errmsg)
{
  if (starting || errmsg != NULL) {
    return;
  }
  if (opt_idx == kOptModified) {
    aucmd_defer_modified(curbuf, newval.data.boolean);
    return;
  }
  apply_optionset_autocmd_now(opt_idx, opt_flags, oldval, oldval_g, oldval_l, newval, errmsg);
}

/// Process the updated 'arabic' option value.
static const char *did_set_arabic(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  const char *errmsg = NULL;

  if (win->w_p_arab) {
    // 'arabic' is set, handle various sub-settings.
    if (!p_tbidi) {
      // set rightleft mode
      if (!win->w_p_rl) {
        win->w_p_rl = true;
        changed_window_setting(win);
      }

      // Enable Arabic shaping (major part of what Arabic requires)
      if (!p_arshape) {
        p_arshape = true;
        redraw_all_later(UPD_NOT_VALID);
      }
    }

    // Arabic requires a utf-8 encoding, inform the user if it's not
    // set.
    if (strcmp(p_enc, "utf-8") != 0) {
      static char *w_arabic = N_("W17: Arabic requires UTF-8, do ':set encoding=utf-8'");

      msg_source(HLF_W);
      msg(_(w_arabic), HLF_W);
      set_vim_var_string(VV_WARNINGMSG, _(w_arabic), -1);
    }

    // set 'delcombine'
    p_deco = true;

    // Force-set the necessary keymap for arabic.
    errmsg = set_option_value(kOptKeymap, STATIC_CSTR_AS_OPTVAL("arabic"), OPT_LOCAL);
  } else {
    // 'arabic' is reset, handle various sub-settings.
    if (!p_tbidi) {
      // reset rightleft mode
      if (win->w_p_rl) {
        win->w_p_rl = false;
        changed_window_setting(win);
      }

      // 'arabicshape' isn't reset, it is a global option and
      // another window may still need it "on".
    }

    // 'delcombine' isn't reset, it is a global option and another
    // window may still want it "on".

    // Revert to the default keymap
    win->w_buffer->b_p_iminsert = B_IMODE_NONE;
    win->w_buffer->b_p_imsearch = B_IMODE_USE_INSERT;
  }

  return errmsg;
}

/// Process the updated 'autochdir' option value.
static const char *did_set_autochdir(optset_T *args FUNC_ATTR_UNUSED)
{
  // Change directories when the 'acd' option is set now.
  do_autochdir();
  return NULL;
}

/// Process the updated 'binary' option value.
static const char *did_set_binary(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;

  // when 'bin' is set also set some other options
  set_options_bin((int)args->os_oldval.boolean, buf->b_p_bin, args->os_flags);
  redraw_titles();

  return NULL;
}

/// Process the updated 'buflisted' option value.
static const char *did_set_buflisted(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;

  // when 'buflisted' changes, trigger autocommands
  if (args->os_oldval.boolean != buf->b_p_bl) {
    apply_autocmds(buf->b_p_bl ? EVENT_BUFADD : EVENT_BUFDELETE,
                   NULL, NULL, true, buf);
  }
  return NULL;
}

/// Process the new 'cmdheight' option value.
static const char *did_set_cmdheight(optset_T *args)
{
  OptInt old_value = args->os_oldval.number;

  if (p_ch > Rows - min_rows(curtab) + 1) {
    p_ch = Rows - min_rows(curtab) + 1;
  }

  // if p_ch changed value, change the command line height
  // Only compute the new window layout when startup has been
  // completed. Otherwise the frame sizes may be wrong.
  if ((p_ch != old_value
       || tabline_height() + global_stl_height() + topframe->fr_height != Rows - p_ch)
      && full_screen) {
    command_height();
  }

  return NULL;
}

/// Process the updated 'diff' option value.
static const char *did_set_diff(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  // May add or remove the buffer from the list of diff buffers.
  diff_buf_adjust(win);
  if (foldmethodIsDiff(win)) {
    foldUpdateAll(win);
  }
  return NULL;
}

/// Process the updated 'endoffile' or 'endofline' or 'fixendofline' or 'bomb'
/// option value.
static const char *did_set_eof_eol_fixeol_bomb(optset_T *args FUNC_ATTR_UNUSED)
{
  // redraw the window title and tab page text
  redraw_titles();
  return NULL;
}

/// Process the updated 'equalalways' option value.
static const char *did_set_equalalways(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  if (p_ea && !args->os_oldval.boolean) {
    win_equal(win, false, 0);
  }

  return NULL;
}

/// Process the new 'foldlevel' option value.
static const char *did_set_foldlevel(optset_T *args FUNC_ATTR_UNUSED)
{
  newFoldLevel();
  return NULL;
}

/// Process the new 'foldminlines' option value.
static const char *did_set_foldminlines(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  foldUpdateAll(win);
  return NULL;
}

/// Process the new 'foldnestmax' option value.
static const char *did_set_foldnestmax(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  if (foldmethodIsSyntax(win) || foldmethodIsIndent(win)) {
    foldUpdateAll(win);
  }
  return NULL;
}

/// Process the new 'helpheight' option value.
static const char *did_set_helpheight(optset_T *args)
{
  // Change window height NOW
  if (!ONE_WINDOW) {
    if (curbuf->b_help && curwin->w_height < p_hh) {
      win_setheight((int)p_hh);
    }
  }

  return NULL;
}

/// Process the updated 'hlsearch' option value.
static const char *did_set_hlsearch(optset_T *args FUNC_ATTR_UNUSED)
{
  // when 'hlsearch' is set or reset: reset no_hlsearch
  set_no_hlsearch(false);
  return NULL;
}

/// Process the updated 'ignorecase' option value.
static const char *did_set_ignorecase(optset_T *args FUNC_ATTR_UNUSED)
{
  // when 'ignorecase' is set or reset and 'hlsearch' is set, redraw
  if (p_hls) {
    redraw_all_later(UPD_SOME_VALID);
  }
  return NULL;
}

/// Process the new 'iminset' option value.
static const char *did_set_iminsert(optset_T *args FUNC_ATTR_UNUSED)
{
  showmode();
  // Show/unshow value of 'keymap' in status lines.
  status_redraw_curbuf();

  return NULL;
}

/// Process the updated 'langnoremap' option value.
static const char *did_set_langnoremap(optset_T *args FUNC_ATTR_UNUSED)
{
  // 'langnoremap' -> !'langremap'
  p_lrm = !p_lnr;
  return NULL;
}

/// Process the updated 'langremap' option value.
static const char *did_set_langremap(optset_T *args FUNC_ATTR_UNUSED)
{
  // 'langremap' -> !'langnoremap'
  p_lnr = !p_lrm;
  return NULL;
}

/// Process the new 'laststatus' option value.
static const char *did_set_laststatus(optset_T *args)
{
  OptInt old_value = args->os_oldval.number;
  OptInt value = args->os_newval.number;

  // When switching to global statusline, decrease topframe height
  // Also clear the cmdline to remove the ruler if there is one
  if (value == 3 && old_value != 3) {
    frame_new_height(topframe, topframe->fr_height - STATUS_HEIGHT, false, false, false);
    win_comp_pos();
    clear_cmdline = true;
  }
  // When switching from global statusline, increase height of topframe by STATUS_HEIGHT
  // in order to to re-add the space that was previously taken by the global statusline
  if (old_value == 3 && value != 3) {
    frame_new_height(topframe, topframe->fr_height + STATUS_HEIGHT, false, false, false);
    win_comp_pos();
  }

  status_redraw_curbuf();
  last_status(false);  // (re)set last window status line.
  win_float_update_statusline();
  return NULL;
}

/// Process the updated 'lines' or 'columns' option value.
static const char *did_set_lines_or_columns(optset_T *args)
{
  // If the screen (shell) height has been changed, assume it is the
  // physical screenheight.
  if (p_lines != Rows || p_columns != Columns) {
    // Changing the screen size is not allowed while updating the screen.
    if (updating_screen) {
      OptVal oldval = (OptVal){ .type = kOptValTypeNumber, .data = args->os_oldval };
      set_option_varp(args->os_idx, args->os_varp, oldval, false);
    } else if (full_screen) {
      screen_resize((int)p_columns, (int)p_lines);
    } else {
      // TODO(bfredl): is this branch ever needed?
      // Postpone the resizing; check the size and cmdline position for
      // messages.
      Rows = (int)p_lines;
      Columns = (int)p_columns;
      check_screensize();
      int new_row = (int)(Rows - MAX(p_ch, 1));
      if (cmdline_row > new_row && Rows > p_ch) {
        assert(p_ch >= 0 && new_row <= INT_MAX);
        cmdline_row = new_row;
      }
    }
    if (p_window >= Rows || !option_was_set(kOptWindow)) {
      p_window = Rows - 1;
    }
  }

  // Adjust 'scrolljump' if needed.
  if (p_sj >= Rows && full_screen) {
    p_sj = Rows / 2;
  }

  return NULL;
}

/// Process the updated 'lisp' option value.
static const char *did_set_lisp(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  // When 'lisp' option changes include/exclude '-' in keyword characters.
  buf_init_chartab(buf, false);          // ignore errors
  return NULL;
}

/// Process the updated 'modifiable' option value.
static const char *did_set_modifiable(optset_T *args FUNC_ATTR_UNUSED)
{
  // when 'modifiable' is changed, redraw the window title
  redraw_titles();

  return NULL;
}

/// Process the updated 'modified' option value.
static const char *did_set_modified(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  if (!args->os_newval.boolean) {
    save_file_ff(buf);  // Buffer is unchanged
  }
  redraw_titles();
  buf->b_modified_was_set = !!(int)args->os_newval.boolean;
  return NULL;
}

/// Process the updated 'number' or 'relativenumber' option value.
static const char *did_set_number_relativenumber(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  if (*win->w_p_stc != NUL) {
    // When 'relativenumber'/'number' is changed and 'statuscolumn' is set, reset width.
    win->w_nrwidth_line_count = 0;
  }
  check_signcolumn(NULL, win);
  return NULL;
}

/// Process the new 'numberwidth' option value.
static const char *did_set_numberwidth(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  win->w_nrwidth_line_count = 0;  // trigger a redraw

  return NULL;
}

/// Process the updated 'paste' option value.
static const char *did_set_paste(optset_T *args FUNC_ATTR_UNUSED)
{
  static int old_p_paste = false;
  static int save_sm = 0;
  static int save_sta = 0;
  static int save_ru = 0;
  static int save_ri = 0;

  if (p_paste) {
    // Paste switched from off to on.
    // Save the current values, so they can be restored later.
    if (!old_p_paste) {
      // save options for each buffer
      FOR_ALL_BUFFERS(buf) {
        buf->b_p_tw_nopaste = buf->b_p_tw;
        buf->b_p_wm_nopaste = buf->b_p_wm;
        buf->b_p_sts_nopaste = buf->b_p_sts;
        buf->b_p_ai_nopaste = buf->b_p_ai;
        buf->b_p_et_nopaste = buf->b_p_et;
        if (buf->b_p_vsts_nopaste) {
          xfree(buf->b_p_vsts_nopaste);
        }
        buf->b_p_vsts_nopaste = buf->b_p_vsts && buf->b_p_vsts != empty_string_option
                                ? xstrdup(buf->b_p_vsts)
                                : NULL;
      }

      // save global options
      save_sm = p_sm;
      save_sta = p_sta;
      save_ru = p_ru;
      save_ri = p_ri;
      // save global values for local buffer options
      p_ai_nopaste = p_ai;
      p_et_nopaste = p_et;
      p_sts_nopaste = p_sts;
      p_tw_nopaste = p_tw;
      p_wm_nopaste = p_wm;
      if (p_vsts_nopaste) {
        xfree(p_vsts_nopaste);
      }
      p_vsts_nopaste = p_vsts && p_vsts != empty_string_option ? xstrdup(p_vsts) : NULL;
    }

    // Always set the option values, also when 'paste' is set when it is
    // already on.
    // set options for each buffer
    FOR_ALL_BUFFERS(buf) {
      buf->b_p_tw = 0;              // textwidth is 0
      buf->b_p_wm = 0;              // wrapmargin is 0
      buf->b_p_sts = 0;             // softtabstop is 0
      buf->b_p_ai = 0;              // no auto-indent
      buf->b_p_et = 0;              // no expandtab
      if (buf->b_p_vsts) {
        free_string_option(buf->b_p_vsts);
      }
      buf->b_p_vsts = empty_string_option;
      XFREE_CLEAR(buf->b_p_vsts_array);
    }

    // set global options
    p_sm = 0;                       // no showmatch
    p_sta = 0;                      // no smarttab
    if (p_ru) {
      status_redraw_all();          // redraw to remove the ruler
    }
    p_ru = 0;                       // no ruler
    p_ri = 0;                       // no reverse insert
    // set global values for local buffer options
    p_tw = 0;
    p_wm = 0;
    p_sts = 0;
    p_ai = 0;
    p_et = 0;
    if (p_vsts) {
      free_string_option(p_vsts);
    }
    p_vsts = empty_string_option;
  } else if (old_p_paste) {
    // Paste switched from on to off: Restore saved values.

    // restore options for each buffer
    FOR_ALL_BUFFERS(buf) {
      buf->b_p_tw = buf->b_p_tw_nopaste;
      buf->b_p_wm = buf->b_p_wm_nopaste;
      buf->b_p_sts = buf->b_p_sts_nopaste;
      buf->b_p_ai = buf->b_p_ai_nopaste;
      buf->b_p_et = buf->b_p_et_nopaste;
      if (buf->b_p_vsts) {
        free_string_option(buf->b_p_vsts);
      }
      buf->b_p_vsts = buf->b_p_vsts_nopaste ? xstrdup(buf->b_p_vsts_nopaste) : empty_string_option;
      xfree(buf->b_p_vsts_array);
      if (buf->b_p_vsts && buf->b_p_vsts != empty_string_option) {
        tabstop_set(buf->b_p_vsts, &buf->b_p_vsts_array);
      } else {
        buf->b_p_vsts_array = NULL;
      }
    }

    // restore global options
    p_sm = save_sm;
    p_sta = save_sta;
    if (p_ru != save_ru) {
      status_redraw_all();          // redraw to draw the ruler
    }
    p_ru = save_ru;
    p_ri = save_ri;
    // set global values for local buffer options
    p_ai = p_ai_nopaste;
    p_et = p_et_nopaste;
    p_sts = p_sts_nopaste;
    p_tw = p_tw_nopaste;
    p_wm = p_wm_nopaste;
    if (p_vsts) {
      free_string_option(p_vsts);
    }
    p_vsts = p_vsts_nopaste ? xstrdup(p_vsts_nopaste) : empty_string_option;
  }

  old_p_paste = p_paste;

  // Remember where the dependent options were reset
  didset_options_sctx((OPT_LOCAL | OPT_GLOBAL), p_paste_dep_opts);

  return NULL;
}

/// Process the updated 'previewwindow' option value.
static const char *did_set_previewwindow(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;

  if (!win->w_p_pvw) {
    return NULL;
  }

  // There can be only one window with 'previewwindow' set.
  FOR_ALL_WINDOWS_IN_TAB(wp, curtab) {
    if (wp->w_p_pvw && wp != win) {
      win->w_p_pvw = false;
      return e_preview_window_already_exists;
    }
  }

  return NULL;
}

/// Process the new 'pumblend' option value.
static const char *did_set_pumblend(optset_T *args FUNC_ATTR_UNUSED)
{
  hl_invalidate_blends();
  if (pum_drawn()) {
    pum_redraw();
  }

  return NULL;
}

/// Process the updated 'readonly' option value.
static const char *did_set_readonly(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;

  // when 'readonly' is reset globally, also reset readonlymode
  if (!buf->b_p_ro && (args->os_flags & OPT_LOCAL) == 0) {
    readonlymode = false;
  }

  // when 'readonly' is set may give W10 again
  if (buf->b_p_ro) {
    buf->b_did_warn = false;
  }

  redraw_titles();

  return NULL;
}

/// Process the new 'scrollback' option value.
static const char *did_set_scrollback(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  OptInt old_value = args->os_oldval.number;
  OptInt value = args->os_newval.number;

  if (buf->terminal && value < old_value) {
    // Force the scrollback to take immediate effect only when decreasing it.
    on_scrollback_option_changed(buf->terminal);
  }
  return NULL;
}

/// Process the updated 'scrollbind' option value.
static const char *did_set_scrollbind(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;

  // when 'scrollbind' is set: snapshot the current position to avoid a jump
  // at the end of normal_cmd()
  if (!win->w_p_scb) {
    return NULL;
  }
  do_check_scrollbind(false);
  win->w_scbind_pos = get_vtopline(win);
  return NULL;
}

#ifdef BACKSLASH_IN_FILENAME
/// Process the updated 'shellslash' option value.
/// TODO(ntdiary): Remove this once we're confident that the `shellslash`
/// option is no longer needed.
static const char *did_set_shellslash(optset_T *args FUNC_ATTR_UNUSED)
{
  if (p_ssl) {
    psepc = '/';
    psepcN = '\\';
    pseps[0] = '/';
  } else {
    psepc = '\\';
    psepcN = '/';
    pseps[0] = '\\';
  }

  // TODO(ntdiary): Remove these in the follow PR.
  // need to adjust the file name arguments and buffer names.
  // buflist_slash_adjust();
  // alist_slash_adjust();
  // scriptnames_slash_adjust();
  return NULL;
}
#endif

/// Process the new 'shiftwidth' or the 'tabstop' option value.
static const char *did_set_shiftwidth_tabstop(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  win_T *win = (win_T *)args->os_win;
  OptInt *pp = (OptInt *)args->os_varp;

  if (foldmethodIsIndent(win)) {
    foldUpdateAll(win);
  }
  // When 'shiftwidth' changes, or it's zero and 'tabstop' changes:
  // parse 'cinoptions'.
  if (pp == &buf->b_p_sw || buf->b_p_sw == 0) {
    parse_cino(buf);
  }

  return NULL;
}

/// Process the new 'showtabline' option value.
static const char *did_set_showtabline(optset_T *args FUNC_ATTR_UNUSED)
{
  // (re)set tab page line
  win_new_screen_rows();  // recompute window positions and heights
  return NULL;
}

/// Process the updated 'smoothscroll' option value.
static const char *did_set_smoothscroll(optset_T *args FUNC_ATTR_UNUSED)
{
  win_T *win = (win_T *)args->os_win;
  if (!win->w_p_sms) {
    win->w_skipcol = 0;
  }

  return NULL;
}

/// Process the updated 'spell' option value.
static const char *did_set_spell(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  if (win->w_p_spell) {
    return parse_spelllang(win);
  }

  return NULL;
}

/// Process the updated 'swapfile' option value.
static const char *did_set_swapfile(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  // when 'swf' is set, create swapfile, when reset remove swapfile
  if (buf->b_p_swf && p_uc) {
    ml_open_file(buf);                     // create the swap file
  } else {
    // no need to reset buf->b_may_swap, ml_open_file() will check buf->b_p_swf
    mf_close_file(buf, true);              // remove the swap file
  }
  return NULL;
}

/// Process the new 'textwidth' option value.
static const char *did_set_textwidth(optset_T *args FUNC_ATTR_UNUSED)
{
  FOR_ALL_TAB_WINDOWS(tp, wp) {
    check_colorcolumn(NULL, wp);
  }

  return NULL;
}

/// Process the updated 'title' or the 'icon' option value.
static const char *did_set_title_icon(optset_T *args FUNC_ATTR_UNUSED)
{
  // when 'title' changed, may need to change the title; same for 'icon'
  did_set_title();
  return NULL;
}

/// Process the new 'titlelen' option value.
static const char *did_set_titlelen(optset_T *args)
{
  OptInt old_value = args->os_oldval.number;

  // if 'titlelen' has changed, redraw the title
  if (starting != NO_SCREEN && old_value != p_titlelen) {
    need_maketitle = true;
  }

  return NULL;
}

/// Process the updated 'undofile' option value.
static const char *did_set_undofile(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;

  // Only take action when the option was set.
  if (!buf->b_p_udf && !p_udf) {
    return NULL;
  }

  // When reset we do not delete the undo file, the option may be set again
  // without making any changes in between.
  uint8_t hash[UNDO_HASH_SIZE];

  FOR_ALL_BUFFERS(bp) {
    // When 'undofile' is set globally: for every buffer, otherwise
    // only for the current buffer: Try to read in the undofile,
    // if one exists, the buffer wasn't changed and the buffer was
    // loaded
    if ((buf == bp
         || (args->os_flags & OPT_GLOBAL) || args->os_flags == 0)
        && !bufIsChanged(bp) && bp->b_ml.ml_mfp != NULL) {
      u_compute_hash(bp, hash);
      u_read_undo(NULL, hash, bp->b_fname);
    }
  }

  return NULL;
}

/// Process the new global 'undolevels' option value.
const char *did_set_global_undolevels(OptInt value, OptInt old_value)
{
  // sync undo before 'undolevels' changes
  // use the old value, otherwise u_sync() may not work properly
  p_ul = old_value;
  u_sync(true);
  p_ul = value;
  return NULL;
}

/// Process the new buffer local 'undolevels' option value.
const char *did_set_buflocal_undolevels(buf_T *buf, OptInt value, OptInt old_value)
{
  // use the old value, otherwise u_sync() may not work properly
  buf->b_p_ul = old_value;
  u_sync(true);
  buf->b_p_ul = value;
  return NULL;
}

/// Process the new 'undolevels' option value.
static const char *did_set_undolevels(optset_T *args)
{
  buf_T *buf = (buf_T *)args->os_buf;
  OptInt *pp = (OptInt *)args->os_varp;

  if (pp == &p_ul) {                  // global 'undolevels'
    did_set_global_undolevels(args->os_newval.number, args->os_oldval.number);
  } else if (pp == &buf->b_p_ul) {      // buffer local 'undolevels'
    did_set_buflocal_undolevels(buf, args->os_newval.number, args->os_oldval.number);
  }

  return NULL;
}

/// Process the new 'updatecount' option value.
static const char *did_set_updatecount(optset_T *args)
{
  OptInt old_value = args->os_oldval.number;

  // when 'updatecount' changes from zero to non-zero, open swap files
  if (p_uc && !old_value) {
    ml_open_files();
  }

  return NULL;
}

/// Process the new 'wildchar' / 'wildcharm' option value.
static const char *did_set_wildchar(optset_T *args)
{
  OptInt c = *(OptInt *)args->os_varp;

  // Don't allow key values that wouldn't work as wildchar.
  if (c == Ctrl_C || c == '\n' || c == '\r' || c == K_KENTER) {
    return e_invarg;
  }

  return NULL;
}

/// Process the new 'winblend' option value.
static const char *did_set_winblend(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  OptInt old_value = args->os_oldval.number;
  OptInt value = args->os_newval.number;

  if (value != old_value) {
    win->w_p_winbl = MAX(MIN(win->w_p_winbl, 100), 0);
    win->w_hl_needs_update = true;
    check_blending(win);
  }

  return NULL;
}

/// Process the new 'window' option value.
static const char *did_set_window(optset_T *args FUNC_ATTR_UNUSED)
{
  if (p_window < 1) {
    p_window = Rows - 1;
  } else if (p_window >= Rows) {
    p_window = Rows - 1;
  }
  return NULL;
}

/// Process the new 'winheight' value.
static const char *did_set_winheight(optset_T *args)
{
  // Change window height NOW
  if (!ONE_WINDOW) {
    if (curwin->w_height < p_wh) {
      win_setheight((int)p_wh);
    }
  }

  return NULL;
}

/// Process the new 'winwidth' option value.
static const char *did_set_winwidth(optset_T *args)
{
  if (!ONE_WINDOW && curwin->w_width < p_wiw) {
    win_setwidth((int)p_wiw);
  }
  return NULL;
}

/// Process the updated 'wrap' option value.
static const char *did_set_wrap(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  // Set w_leftcol or w_skipcol to zero.
  if (win->w_p_wrap) {
    win->w_leftcol = 0;
  } else {
    win->w_skipcol = 0;
  }

  return NULL;
}

/// Process the new 'chistory' or 'lhistory' option value. 'chistory' will
/// be used if args->os_varp is the same as p_chi, else 'lhistory'.
static const char *did_set_xhistory(optset_T *args)
{
  win_T *win = (win_T *)args->os_win;
  bool is_p_chi = (OptInt *)args->os_varp == &p_chi;
  OptInt *arg = is_p_chi ? &p_chi : (OptInt *)args->os_varp;

  if (is_p_chi) {
    qf_resize_stack((int)(*arg));
  } else {
    ll_resize_stack(win, (int)(*arg));
  }

  return NULL;
}

// When 'syntax' is set, load the syntax of that name
static void do_syntax_autocmd(buf_T *buf, bool value_changed)
{
  static int syn_recursive = 0;

  syn_recursive++;
  buf->b_flags |= BF_SYN_SET;
  // Only pass true for "force" when the value changed or not used
  // recursively, to avoid endless recurrence.
  apply_autocmds(EVENT_SYNTAX, buf->b_p_syn, buf->b_fname,
                 value_changed || syn_recursive == 1, buf);
  syn_recursive--;
}

static void do_spelllang_source(win_T *win)
{
  char fname[200];
  char *q = win->w_s->b_p_spl;

  // Skip the first name if it is "cjk".
  if (strncmp(q, "cjk,", 4) == 0) {
    q += 4;
  }

  // Source the spell/LANG.{vim,lua} in 'runtimepath'.
  // They could set 'spellcapcheck' depending on the language.
  // Use the first name in 'spelllang' up to '_region' or
  // '.encoding'.
  char *p;
  for (p = q; *p != NUL; p++) {
    if (!ASCII_ISALNUM(*p) && *p != '-') {
      break;
    }
  }
  if (p > q) {
    vim_snprintf(fname, sizeof(fname), "spell/%.*s.*", (int)(p - q), q);
    source_runtime_vim_lua(fname, DIP_ALL);
  }
}

/// Check the bounds of numeric options.
///
/// @param          opt_idx    Index in options[] table. Must not be kOptInvalid.
/// @param[in,out]  newval     Pointer to new option value. Will be set to bound checked value.
/// @param[out]     errbuf     Buffer for error message. Cannot be NULL.
/// @param          errbuflen  Length of error buffer.
///
/// @return Error message, if any.
static const char *check_num_option_bounds(OptIndex opt_idx, OptInt *newval, char *errbuf,
                                           size_t errbuflen)
  FUNC_ATTR_NONNULL_ARG(3)
{
  const char *errmsg = NULL;

  switch (opt_idx) {
  case kOptLines:
    if (*newval < min_rows_for_all_tabpages() && full_screen) {
      vim_snprintf(errbuf, errbuflen, _("E593: Need at least %d lines"),
                   min_rows_for_all_tabpages());
      errmsg = errbuf;
      *newval = min_rows_for_all_tabpages();
    }
    // True max size is defined by check_screensize().
    *newval = MIN(*newval, INT_MAX);
    break;
  case kOptColumns:
    if (*newval < MIN_COLUMNS && full_screen) {
      vim_snprintf(errbuf, errbuflen, _("E594: Need at least %d columns"), MIN_COLUMNS);
      errmsg = errbuf;
      *newval = MIN_COLUMNS;
    }
    // True max size is defined by check_screensize().
    *newval = MIN(*newval, INT_MAX);
    break;
  case kOptPumblend:
    *newval = MAX(MIN(*newval, 100), 0);
    break;
  case kOptScrolljump:
    if ((*newval < -100 || *newval >= Rows) && full_screen) {
      errmsg = e_scroll;
      *newval = 1;
    }
    break;
  case kOptScroll:
    if ((*newval <= 0 || (*newval > curwin->w_view_height && curwin->w_view_height > 0))
        && full_screen) {
      if (*newval != 0) {
        errmsg = e_scroll;
      }
      *newval = win_default_scroll(curwin);
    }
    break;
  default:
    break;
  }

  return errmsg;
}

/// Validate and bound check option value.
///
/// @param          opt_idx    Index in options[] table. Must not be kOptInvalid.
/// @param[in,out]  newval     Pointer to new option value. Will be set to bound checked value.
/// @param[out]     errbuf     Buffer for error message. Cannot be NULL.
/// @param          errbuflen  Length of error buffer.
///
/// @return Error message, if any.
static const char *validate_num_option(OptIndex opt_idx, OptInt *newval, char *errbuf,
                                       size_t errbuflen)
{
  OptInt value = *newval;

  // Many number options assume their value is in the signed int range.
  if (value < INT_MIN || value > INT_MAX) {
    return e_invarg;
  }

  // if you increase this, also increase SEARCH_STAT_BUF_LEN in search.c
  enum { MAX_SEARCH_COUNT = 9999, };

  switch (opt_idx) {
  case kOptHelpheight:
  case kOptTitlelen:
  case kOptUpdatecount:
  case kOptReport:
  case kOptUpdatetime:
  case kOptSidescroll:
  case kOptFoldlevel:
  case kOptShiftwidth:
  case kOptTextwidth:
  case kOptWritedelay:
  case kOptTimeoutlen:
    if (value < 0) {
      return e_positive;
    }
    break;
  case kOptWinheight:
    if (value < 1) {
      return e_positive;
    } else if (p_wmh > value) {
      return e_winheight;
    }
    break;
  case kOptWinminheight:
    if (value < 0) {
      return e_positive;
    } else if (value > p_wh) {
      return e_winheight;
    }
    break;
  case kOptWinwidth:
    if (value < 1) {
      return e_positive;
    } else if (p_wmw > value) {
      return e_winwidth;
    }
    break;
  case kOptWinminwidth:
    if (value < 0) {
      return e_positive;
    } else if (value > p_wiw) {
      return e_winwidth;
    }
    break;
  case kOptMaxcombine:
    *newval = MAX_MCO;
    break;
  case kOptCmdheight:
    if (value < 0) {
      return e_positive;
    }
    break;
  case kOptHistory:
    if (value < 0) {
      return e_positive;
    } else if (value > 10000) {
      return e_invarg;
    }
    break;
  case kOptPyxversion:
    if (value == 0) {
      *newval = 3;
    } else if (value != 3) {
      return e_invarg;
    }
    break;
  case kOptRegexpengine:
    if (value < 0 || value > 2) {
      return e_invarg;
    }
    break;
  case kOptScrolloff:
    if (value < 0 && full_screen) {
      return e_positive;
    }
    break;
  case kOptScrolloffpad:
    // if (value < 0 && full_screen) {
    if (value < 0) {
      return e_invarg;
    }
    break;
  case kOptSidescrolloff:
    if (value < 0 && full_screen) {
      return e_positive;
    }
    break;
  case kOptCmdwinheight:
    if (value < 1) {
      return e_positive;
    }
    break;
  case kOptConceallevel:
    if (value < 0) {
      return e_positive;
    } else if (value > 3) {
      return e_invarg;
    }
    break;
  case kOptNumberwidth:
    if (value < 1) {
      return e_positive;
    } else if (value > MAX_NUMBERWIDTH) {
      return e_invarg;
    }
    break;
  case kOptIminsert:
    if (value < 0 || value > B_IMODE_LAST) {
      return e_invarg;
    }
    break;
  case kOptImsearch:
    if (value < -1 || value > B_IMODE_LAST) {
      return e_invarg;
    }
    break;
  case kOptChannel:
    return e_invarg;
  case kOptScrollback:
    if (value < -1 || value > SB_MAX) {
      return e_invarg;
    }
    break;
  case kOptTabstop:
    if (value < 1) {
      return e_positive;
    } else if (value > TABSTOP_MAX) {
      return e_invarg;
    }
    break;
  case kOptChistory:
  case kOptLhistory:
    if (value < 1) {
      return e_cannot_have_negative_or_zero_number_of_quickfix;
    } else if (value > 100) {
      return e_cannot_have_more_than_hundred_quickfix;
    }
    break;
  case kOptMaxsearchcount:
    if (value <= 0) {
      return e_positive;
    } else if (value > MAX_SEARCH_COUNT) {
      return e_invarg;
    }
    break;
  default:
    break;
  }

  return check_num_option_bounds(opt_idx, newval, errbuf, errbuflen);
}

/// Called after an option changed: check if something needs to be redrawn.
/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


/// Get value of TTY option.
///
/// @param  name  Name of TTY option.
///
/// @return [allocated] TTY option value. Returns NIL_OPTVAL if option isn't a TTY option.
/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


/// Find index for an option. Don't go beyond `len` length.
///
/// @param[in]  name  Option name.
/// @param      len   Option name length.
///
/// @return Option index or kOptInvalid if option was not found.
OptIndex find_option_len(const char *const name, size_t len)
  FUNC_ATTR_NONNULL_ALL
{
  int index = find_option_hash(name, len);
  return index >= 0 ? option_hash_elems[index].opt_idx : kOptInvalid;
}

/// Find index for an option.
///
/// @param[in]  name  Option name.
///
/// @return Option index or kOptInvalid if option was not found.
OptIndex find_option(const char *const name)
  FUNC_ATTR_NONNULL_ALL
{
  return find_option_len(name, strlen(name));
}

/// Free an allocated OptVal.
/* === removed: implemented in src/odin/option.odin === */


/// Copy an OptVal.
/* === removed: implemented in src/odin/option.odin === */


/// Check if two option values are equal.
/* === removed: implemented in src/odin/option.odin === */


/// Get type of option.
/* === removed: implemented in src/odin/option.odin === */


/// Create OptVal from var pointer.
///
/// @param       opt_idx  Option index in options[] table.
/// @param[out]  varp     Pointer to option variable.
///
/// @return Option value stored in varp.
/* === removed: implemented in src/odin/option.odin === */


/// Set option var pointer value from OptVal.
///
/// @param       opt_idx      Option index in options[] table.
/// @param[out]  varp         Pointer to option variable.
/// @param[in]   value        New option value.
/// @param       free_oldval  Free old value.
static void set_option_varp(OptIndex opt_idx, void *varp, OptVal value, bool free_oldval)
  FUNC_ATTR_NONNULL_ARG(2)
{
  assert(option_has_type(opt_idx, value.type));

  if (free_oldval) {
    optval_free(optval_from_varp(opt_idx, varp));
  }

  switch (value.type) {
  case kOptValTypeNil:
    abort();
  case kOptValTypeBoolean:
    *(int *)varp = value.data.boolean;
    return;
  case kOptValTypeNumber:
    *(OptInt *)varp = value.data.number;
    return;
  case kOptValTypeString:
    *(char **)varp = value.data.string.data;
    return;
  }
  UNREACHABLE;
}

/// Return C-string representation of OptVal. Caller must free the returned C-string.
static char *optval_to_cstr(OptVal o)
{
  switch (o.type) {
  case kOptValTypeNil:
    return xstrdup("");
  case kOptValTypeBoolean:
    return xstrdup(o.data.boolean ? "true" : "false");
  case kOptValTypeNumber: {
    char *buf = xmalloc(NUMBUFLEN);
    snprintf(buf, NUMBUFLEN, "%" PRId64, o.data.number);
    return buf;
  }
  case kOptValTypeString: {
    char *buf = xmalloc(o.data.string.size + 3);
    snprintf(buf, o.data.string.size + 3, "\"%s\"", o.data.string.data);
    return buf;
  }
  }
  UNREACHABLE;
}

/// Convert an OptVal to an API Object.
/* === removed: implemented in src/odin/option.odin === */


/// Convert an API Object to an OptVal.
/* === removed: implemented in src/odin/option.odin === */


/// Converts a structured option (API Object) to an OptVal (stringly-typed ":set" string). Each
/// option impl internally expects a ":set" string (unfortunately).
///
/// Example: 'listchars' `{ eol = "~" }` => "eol:~".
///
/// @param op  The :set operation; "key:value" removals are normalized to match by key.
/// @return OptVal (owned; free with optval_free).
/* === removed: implemented in src/odin/option.odin === */


/// Check if option is hidden.
///
/// @param  opt_idx  Option index in options[] table.
///
/// @return  True if option is hidden, false otherwise. Returns false if option name is invalid.
/* === removed: implemented in src/odin/option.odin === */


/// Check if option supports a specific type.
/* === removed: implemented in src/odin/option.odin === */


/// Check if option supports a specific scope.
/* === removed: implemented in src/odin/option.odin === */


/// Check if option is global-local (has global AND buffer/window scope).
/// Tab scope is independent and does not make an option "global-local".
static inline bool option_is_global_local(OptIndex opt_idx)
{
  if (opt_idx == kOptInvalid) {
    return false;
  }
  const OptScopeFlags bw = (1 << kOptScopeBuf) | (1 << kOptScopeWin);
  return (options[opt_idx].scope_flags & bw) != 0
         && option_has_scope(opt_idx, kOptScopeGlobal);
}

/// Check if option only supports global scope (ignoring tab scope, which is independent).
static inline bool option_is_global_only(OptIndex opt_idx)
{
  if (opt_idx == kOptInvalid) {
    return false;
  }
  const OptScopeFlags bw = (1 << kOptScopeBuf) | (1 << kOptScopeWin);
  return (options[opt_idx].scope_flags & bw) == 0
         && option_has_scope(opt_idx, kOptScopeGlobal);
}

/// Check if option only supports window scope (ignoring tab scope, which is independent).
static inline bool option_is_window_local(OptIndex opt_idx)
{
  if (opt_idx == kOptInvalid) {
    return false;
  }
  const OptScopeFlags exclude = (1 << kOptScopeGlobal) | (1 << kOptScopeBuf);
  return (options[opt_idx].scope_flags & exclude) == 0
         && option_has_scope(opt_idx, kOptScopeWin);
}

/// Get option index for scope.
/* === removed: implemented in src/odin/option.odin === */


/// Get option flags.
///
/// @param  opt_idx  Option index in options[] table.
///
/// @return  Option flags. Returns 0 for invalid option name.
/* === removed: implemented in src/odin/option.odin === */


/// Gets the value for an option.
///
/// @param  opt_idx    Option index in options[] table.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
///
/// @return [allocated] Option value. Returns NIL_OPTVAL for invalid option index.
/* === removed: implemented in src/odin/option.odin === */


/// Return information for option at 'opt_idx'
vimoption_T *get_option(OptIndex opt_idx)
{
  assert(opt_idx != kOptInvalid);
  return &options[opt_idx];
}

/// Get option value that represents an unset local value for an option.
/// TODO(famiu): Remove this once we have a dedicated OptVal type for unset local options.
///
/// @param      opt_idx  Option index in options[] table.
/// @param[in]  varp  Pointer to option variable.
///
/// @return Option value equal to the unset value for the option.
static OptVal get_option_unset_value(OptIndex opt_idx)
{
  assert(opt_idx != kOptInvalid);
  vimoption_T *opt = &options[opt_idx];

  // For global-local options, use the unset value of the local value.
  if (option_is_global_local(opt_idx)) {
    // String global-local options always use an empty string for the unset value.
    if (option_has_type(opt_idx, kOptValTypeString)) {
      return STATIC_CSTR_AS_OPTVAL("");
    }

    switch (opt_idx) {
    case kOptAutocomplete:
    case kOptAutoread:
    case kOptFsync:
      return BOOLEAN_OPTVAL(kNone);
    case kOptScrolloff:
    case kOptScrolloffpad:
    case kOptSidescrolloff:
      return NUMBER_OPTVAL(-1);
    case kOptUndolevels:
      return NUMBER_OPTVAL(NO_LOCAL_UNDOLEVEL);
    default:
      abort();
    }
  }

  // For options that aren't global-local, use the global value to represent an unset local value.
  return optval_from_varp(opt_idx, get_varp_scope(opt, OPT_GLOBAL));
}

/// Check if local value of global-local option is unset for current buffer / window.
/// Always returns false for options that aren't global-local.
///
/// TODO(famiu): Remove this once we have an OptVal type to indicate an unset local value.
static bool is_option_local_value_unset(OptIndex opt_idx)
{
  vimoption_T *opt = get_option(opt_idx);

  // Local value of option that isn't global-local is always considered set.
  if (!option_is_global_local(opt_idx)) {
    return false;
  }

  void *varp_local = get_varp_scope(opt, OPT_LOCAL);
  OptVal local_value = optval_from_varp(opt_idx, varp_local);
  OptVal unset_local_value = get_option_unset_value(opt_idx);

  return optval_equal(local_value, unset_local_value);
}

/// Handle side-effects of setting an option.
///
/// @param       opt_idx         Index in options[] table. Must not be kOptInvalid.
/// @param[in]   varp            Option variable pointer, cannot be NULL.
/// @param       old_value       Old option value.
/// @param       opt_flags       Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/// @param       set_sid         Script ID. Special values:
///                                0: Use current script ID.
///                                SID_NONE: Don't set script ID.
/// @param       direct          Don't process side-effects.
/// @param       value_replaced  Value was replaced completely.
/// @param[out]  errbuf          Buffer for error message.
/// @param       errbuflen       Length of error buffer.
///
/// @return  NULL on success, an untranslated error message on error.
static const char *did_set_option(OptIndex opt_idx, void *varp, OptVal old_value, OptVal new_value,
                                  int opt_flags, scid_T set_sid, const bool direct,
                                  const bool value_replaced, char *errbuf, size_t errbuflen)
{
  vimoption_T *opt = &options[opt_idx];
  const char *errmsg = NULL;
  bool restore_chartab = false;
  bool value_changed = false;
  bool value_checked = false;

  optset_T did_set_cb_args = {
    .os_varp = varp,
    .os_idx = opt_idx,
    .os_flags = opt_flags,
    .os_oldval = old_value.data,
    .os_newval = new_value.data,
    .os_value_checked = false,
    .os_value_changed = false,
    .os_restore_chartab = false,
    .os_errbuf = errbuf,
    .os_errbuflen = errbuflen,
    .os_buf = curbuf,
    .os_win = curwin,
  };

  if (direct) {
    // Don't do any extra processing if setting directly.
  }
  // Disallow changing immutable options.
  else if (opt->immutable && !optval_equal(old_value, new_value)) {
    errmsg = e_unsupportedoption;
  }
  // Disallow changing some options from secure mode.
  else if ((secure || sandbox != 0) && (opt->flags & kOptFlagSecure)) {
    errmsg = e_secure;
  }
  // Check for a "normal" directory or file name in some string options.
  else if (new_value.type == kOptValTypeString
           && check_illegal_path_names(*(char **)varp, opt->flags)) {
    errmsg = e_invarg;
  } else if (opt->opt_did_set_cb != NULL) {
    // Invoke the option specific callback function to validate and apply the new value.
    errmsg = opt->opt_did_set_cb(&did_set_cb_args);
    // The 'filetype' and 'syntax' option callback functions may change the os_value_changed field.
    value_changed = did_set_cb_args.os_value_changed;
    // The 'keymap', 'filetype' and 'syntax' option callback functions may change the
    // os_value_checked field.
    value_checked = did_set_cb_args.os_value_checked;
    // The 'isident', 'iskeyword', 'isprint' and 'isfname' options may change the character table.
    // On failure, this needs to be restored.
    restore_chartab = did_set_cb_args.os_restore_chartab;
  }

  // If option is hidden or if an error is detected, restore the previous value and don't do any
  // further processing.
  if (errmsg != NULL) {
    set_option_varp(opt_idx, varp, old_value, true);
    // When resetting some values, need to act on it.
    if (restore_chartab) {
      buf_init_chartab(curbuf, true);
    }

    return errmsg;
  }

  // Re-assign the new value as its value may get freed or modified by the option callback.
  new_value = optval_from_varp(opt_idx, varp);

  if (set_sid != SID_NONE) {
    sctx_T script_ctx = set_sid == 0 ? current_sctx : (sctx_T){ .sc_sid = set_sid };
    // Remember where the option was set.
    set_option_sctx(opt_idx, opt_flags, script_ctx);
  }

  optval_free(old_value);

  const bool scope_both = (opt_flags & (OPT_LOCAL | OPT_GLOBAL)) == 0;

  if (scope_both) {
    if (option_is_global_local(opt_idx)) {
      // Global option with local value set to use global value.
      // Free the local value and clear it.
      void *varp_local = get_varp_scope(opt, OPT_LOCAL);
      OptVal local_unset_value = get_option_unset_value(opt_idx);
      set_option_varp(opt_idx, varp_local, optval_copy(local_unset_value), true);
    } else {
      // May set global value for local option.
      void *varp_global = get_varp_scope(opt, OPT_GLOBAL);
      set_option_varp(opt_idx, varp_global, optval_copy(new_value), true);
    }
  }

  // Don't do anything else if setting the option directly.
  if (direct) {
    return errmsg;
  }

  // Trigger the autocommand only after setting the flags.
  if (varp == &curbuf->b_p_syn) {
    do_syntax_autocmd(curbuf, value_changed);
  } else if (varp == &curbuf->b_p_ft) {
    // 'filetype' is set, trigger the FileType autocommand
    // Skip this when called from a modeline
    // Force autocmd when the filetype was changed
    if (!(opt_flags & OPT_MODELINE) || value_changed) {
      do_filetype_autocmd(curbuf, value_changed);
    }
  } else if (varp == &curwin->w_s->b_p_spl) {
    do_spelllang_source(curwin);
  }

  // In case 'ruler' or 'showcmd' or 'columns' or 'ls' changed.
  comp_col();

  if (varp == &p_mouse) {
    setmouse();  // in case 'mouse' changed
  } else if ((varp == &p_flp || varp == &(curbuf->b_p_flp)) && curwin->w_briopt_list) {
    // Changing Formatlistpattern when briopt includes the list setting:
    // redraw
    redraw_all_later(UPD_NOT_VALID);
  } else if (varp == &p_wbr || varp == &(curwin->w_p_wbr)) {
    // add / remove window bars for 'winbar'
    set_winbar(true);
  }

  if (curwin->w_curswant != MAXCOL
      && (opt->flags & (kOptFlagCurswant | kOptFlagRedrAll)) != 0
      && (opt->flags & kOptFlagHLOnly) == 0) {
    curwin->w_set_curswant = true;
  }

  check_redraw(opt->flags);

  if (errmsg == NULL) {
    opt->flags |= kOptFlagWasSet;

    uint32_t *flagsp = insecure_flag(curwin, opt_idx, opt_flags);
    uint32_t *flagsp_local = scope_both ? insecure_flag(curwin, opt_idx, OPT_LOCAL) : NULL;
    // When an option is set in the sandbox, from a modeline or in secure mode set the
    // kOptFlagInsecure flag.  Otherwise, if a new value is stored reset the flag.
    if (!value_checked && (secure || sandbox != 0 || (opt_flags & OPT_MODELINE))) {
      *flagsp |= kOptFlagInsecure;
      if (flagsp_local != NULL) {
        *flagsp_local |= kOptFlagInsecure;
      }
    } else if (value_replaced) {
      *flagsp &= ~(unsigned)kOptFlagInsecure;
      if (flagsp_local != NULL) {
        *flagsp_local &= ~(unsigned)kOptFlagInsecure;
      }
    }
  }

  return errmsg;
}

/// Validate the new value for an option.
///
/// @param  opt_idx         Index in options[] table. Must not be kOptInvalid.
/// @param  newval[in,out]  New option value. Might be modified.
static const char *validate_option_value(const OptIndex opt_idx, OptVal *newval, int opt_flags,
                                         char *errbuf, size_t errbuflen)
{
  const char *errmsg = NULL;
  vimoption_T *opt = &options[opt_idx];

  // Always allow unsetting local value of global-local option.
  if (option_is_global_local(opt_idx) && (opt_flags & OPT_LOCAL)
      && optval_equal(*newval, get_option_unset_value(opt_idx))) {
    return NULL;
  }

  if (newval->type == kOptValTypeNil) {
    // Don't try to unset local value if scope is global.
    // TODO(famiu): Change this to forbid changing all non-local scopes when the API scope bug is
    // fixed.
    if (opt_flags == OPT_GLOBAL) {
      errmsg = _("Cannot unset global option value");
    } else {
      *newval = optval_copy(get_option_unset_value(opt_idx));
    }
  } else if (!option_has_type(opt_idx, newval->type)) {
    char *rep = optval_to_cstr(*newval);
    const char *type_str = optval_type_get_name(opt->type);
    snprintf(errbuf, IOSIZE, _("Invalid value for option '%s': expected %s, got %s %s"),
             opt->fullname, type_str, optval_type_get_name(newval->type), rep);
    xfree(rep);
    errmsg = errbuf;
  } else if (newval->type == kOptValTypeNumber) {
    // Validate and bound check num option values.
    errmsg = validate_num_option(opt_idx, &newval->data.number, errbuf, errbuflen);
  }

  return errmsg;
}

/// Set the value of an option using an OptVal.
///
/// @param       opt_idx         Index in options[] table. Must not be kOptInvalid.
/// @param       value           New option value. Might get freed.
/// @param       opt_flags       Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/// @param       set_sid         Script ID. Special values:
///                                0: Use current script ID.
///                                SID_NONE: Don't set script ID.
/// @param       direct          Don't process side-effects.
/// @param       value_replaced  Value was replaced completely.
/// @param[out]  errbuf          Buffer for error message.
/// @param       errbuflen       Length of error buffer.
///
/// @return  NULL on success, an untranslated error message on error.
static const char *set_option(const OptIndex opt_idx, OptVal value, int opt_flags, scid_T set_sid,
                              const bool direct, const bool value_replaced, char *errbuf,
                              size_t errbuflen)
{
  assert(opt_idx != kOptInvalid);

  const char *errmsg = NULL;

  if (!direct) {
    errmsg = validate_option_value(opt_idx, &value, opt_flags, errbuf, errbuflen);

    if (errmsg != NULL) {
      optval_free(value);
      return errmsg;
    }
  }

#ifdef BACKSLASH_IN_FILENAME
  // Ensure "/" slashes in various options.
  uint32_t flags = options[opt_idx].flags;
  if ((flags & kOptFlagExpand)
      && opt_idx != kOptEqualprg
      && opt_idx != kOptFormatprg
      && opt_idx != kOptGrepprg
      && opt_idx != kOptKeywordprg
      && opt_idx != kOptMakeprg
      && opt_idx != kOptShell) {
    bool allow_comma = flags & kOptFlagComma;
    bool allow_space = (opt_idx == kOptCdpath || opt_idx == kOptPath || opt_idx == kOptTags);
    for (char *p = value.data.string.data; *p; p++) {
      if (*p != '\\'
          || (p[1] == ',' && allow_comma)
          || (p[1] == ' ' && allow_space)) {
        continue;
      }
      *p = '/';
    }
  }
#endif

  vimoption_T *opt = &options[opt_idx];
  const bool scope_local = opt_flags & OPT_LOCAL;
  const bool scope_global = opt_flags & OPT_GLOBAL;
  const bool scope_both = !scope_local && !scope_global;
  // Whether local value of global-local option is unset.
  // NOTE: When this is true, it also implies that the option is global-local.
  const bool is_opt_local_unset = is_option_local_value_unset(opt_idx);

  // When using ":set opt=val" for a global option with a local value the local value will be reset,
  // use the global value in that case.
  void *varp
    = scope_both && option_is_global_local(opt_idx) ? opt->var : get_varp_scope(opt, opt_flags);
  void *varp_local = get_varp_scope(opt, OPT_LOCAL);
  void *varp_global = get_varp_scope(opt, OPT_GLOBAL);

  OptVal old_value = optval_from_varp(opt_idx, varp);
  OptVal old_global_value = optval_from_varp(opt_idx, varp_global);
  // If local value of global-local option is unset, use global value as local value.
  OptVal old_local_value = is_opt_local_unset
                           ? old_global_value
                           : optval_from_varp(opt_idx, varp_local);
  // Value that's actually being used.
  // For local scope of a global-local option, it's equal to the global value if the local value is
  // unset. In every other case, it is the same as old_value.
  // This value is used instead of old_value when triggering the OptionSet autocommand.
  OptVal used_old_value = (scope_local && is_opt_local_unset)
                          ? optval_from_varp(opt_idx, get_varp(opt))
                          : old_value;

  // Save the old values and the new value in case they get changed.
  OptVal saved_used_value = optval_copy(used_old_value);
  OptVal saved_old_global_value = optval_copy(old_global_value);
  OptVal saved_old_local_value = optval_copy(old_local_value);
  // New value (and varp) may become invalid if the buffer is closed by autocommands.
  OptVal saved_new_value = optval_copy(value);

  uint32_t *p = insecure_flag(curwin, opt_idx, opt_flags);
  const int secure_saved = secure;

  // When an option is set in the sandbox, from a modeline or in secure mode, then deal with side
  // effects in secure mode. Also when the value was set with the kOptFlagInsecure flag and is not
  // completely replaced.
  if ((opt_flags & OPT_MODELINE) || sandbox != 0 || (!value_replaced && (*p & kOptFlagInsecure))) {
    secure = 1;
  }

  // Set option through its variable pointer.
  set_option_varp(opt_idx, varp, value, false);
  // Process any side effects.
  errmsg = did_set_option(opt_idx, varp, old_value, value, opt_flags, set_sid, direct,
                          value_replaced, errbuf, errbuflen);

  secure = secure_saved;

  if (errmsg == NULL && !direct) {
    if (!starting) {
      apply_optionset_autocmd(opt_idx, opt_flags, saved_used_value, saved_old_global_value,
                              saved_old_local_value, saved_new_value, errmsg);
    }
    if (opt->flags & kOptFlagUIOption) {
      ui_call_option_set(cstr_as_string(opt->fullname), optval_as_object(saved_new_value));
    }
  }

  // Free copied values as they are not needed anymore
  optval_free(saved_used_value);
  optval_free(saved_old_local_value);
  optval_free(saved_old_global_value);
  optval_free(saved_new_value);

  return errmsg;
}

/// Set option value directly, without processing any side effects.
///
/// @param  opt_idx    Option index in options[] table.
/// @param  value      Option value.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/// @param  set_sid    Script ID. Special values:
///                      0: Use current script ID.
///                      SID_NONE: Don't set script ID.
/* === removed: implemented in src/odin/option.odin === */


/// Set option value directly for buffer / window, without processing any side effects.
///
/// @param      opt_idx    Option index in options[] table.
/// @param      value      Option value.
/// @param      opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/// @param      set_sid    Script ID. Special values:
///                          0: Use current script ID.
///                          SID_NONE: Don't set script ID.
/// @param      scope      Option scope. See OptScope in option.h.
/// @param[in]  from       Target buffer/window.
/* === removed: implemented in src/odin/option.odin === */


/// Sets the value of an (non-tty) option.
///
/// @param      opt_idx    Index in options[] table. Must not be kOptInvalid.
/// @param[in]  value      Option value. If NIL_OPTVAL, the option value is cleared.
/// @param[in]  opt_flags  Flags: OPT_LOCAL, OPT_GLOBAL, or 0 (both).
///
/// @return  NULL on success, an untranslated error message on error.
const char *set_option_value(const OptIndex opt_idx, const OptVal value, int opt_flags)
{
  assert(opt_idx != kOptInvalid);

  static char errbuf[IOSIZE];
  uint32_t flags = options[opt_idx].flags;

  // Disallow changing some options in the sandbox
  if (sandbox > 0 && (flags & kOptFlagSecure)) {
    return _(e_sandbox);
  }

  return set_option(opt_idx, optval_copy(value), opt_flags, 0, false, true, errbuf, sizeof(errbuf));
}

/// Unset the local value of a global-local option.
///
/// @param      opt_idx    Index in options[] table. Must not be kOptInvalid.
///
/// @return  NULL on success, an untranslated error message on error.
static inline const char *unset_option_local_value(const OptIndex opt_idx)
{
  assert(option_is_global_local(opt_idx));
  return set_option_value(opt_idx, get_option_unset_value(opt_idx), OPT_LOCAL);
}

/// Set the value of an option. Supports TTY options, unlike set_option_value().
///
/// @param      name       Option name. Used for error messages and for setting TTY options.
/// @param      opt_idx    Option indx in options[] table. If kOptInvalid, `name` is used to
///                        check if the option is a TTY option, and an error is shown if it's not.
///                        If the option is a TTY option, the function fails silently.
/// @param      value      Option value. If NIL_OPTVAL, the option value is cleared.
/// @param[in]  opt_flags  Flags: OPT_LOCAL, OPT_GLOBAL, or 0 (both).
///
/// @return  NULL on success, an untranslated error message on error.
const char *set_option_value_handle_tty(const char *name, OptIndex opt_idx, const OptVal value,
                                        int opt_flags)
  FUNC_ATTR_NONNULL_ARG(1)
{
  static char errbuf[IOSIZE];

  if (opt_idx == kOptInvalid) {
    if (is_tty_option(name)) {
      return NULL;  // Fail silently; many old vimrcs set t_xx options.
    }

    snprintf(errbuf, sizeof(errbuf), _(e_unknown_option2), name);
    return errbuf;
  }

  return set_option_value(opt_idx, value, opt_flags);
}

/// Call set_option_value() and when an error is returned, report it.
///
/// @param  opt_idx    Option index in options[] table.
/// @param  value      Option value. If NIL_OPTVAL, the option value is cleared.
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/* === removed: implemented in src/odin/option.odin === */


/// Switch current context to get/set option value for the target window/buffer/tabpage.
///
/// Tab-scope switch is GET-only (SET requires side-effects, see set_option_value_for()).
///
/// @param[out]  ctx   Switched-from context, restored by restore_option_context():
///                    - kOptScopeWin: switchwin_T
///                    - kOptScopeBuf: aco_save_T
///                    - kOptScopeTab: tabpage_T * (saved curtab)
///                    - kOptScopeGlobal: unused
/// @param       scope Option scope. See OptScope in option.h.
/// @param[in]   from  Target win_T/buf_T/tabpage_T.
/// @param[out]  err   Error message, if any.
///
/// @return  true if context was switched, false otherwise.
static bool switch_option_context(void *const ctx, OptScope scope, void *const from, Error *err)
{
  switch (scope) {
  case kOptScopeGlobal:
    return false;
  case kOptScopeWin: {
    win_T *const win = (win_T *)from;
    switchwin_T *const switchwin = (switchwin_T *)ctx;

    if (win == curwin) {
      return false;
    }

    if (FAIL == switch_win_noblock(switchwin, win, win_find_tabpage(win), true)) {
      restore_win_noblock(switchwin, true);

      if (ERROR_SET(err)) {
        return false;
      }
      api_set_error(err, kErrorTypeException, "Problem while switching windows");
      return false;
    }
    return true;
  }
  case kOptScopeBuf: {
    buf_T *const buf = (buf_T *)from;
    aco_save_T *const aco = (aco_save_T *)ctx;

    if (buf == curbuf) {
      return false;
    }
    aucmd_prepbuf(aco, buf);
    return true;
  }
  case kOptScopeTab: {
    // GET-only: swap curtab so get_option_value() reads the target tab's stored value (p_ch).
    // SET on a non-current tab cannot use this path, see comment in set_option_value_for().
    tabpage_T *const tab = (tabpage_T *)from;
    tabpage_T **const saved_curtab = (tabpage_T **)ctx;

    if (tab == curtab) {
      return false;
    }
    *saved_curtab = curtab;
    unuse_tabpage(curtab);
    use_tabpage(tab);
    return true;
  }
  }
  UNREACHABLE;
}

/// Restore context after getting/setting option for window/buffer. See switch_option_context() for
/// params.
static void restore_option_context(void *const ctx, OptScope scope)
{
  switch (scope) {
  case kOptScopeGlobal:
    break;
  case kOptScopeWin:
    restore_win_noblock((switchwin_T *)ctx, true);
    break;
  case kOptScopeBuf:
    aucmd_restbuf((aco_save_T *)ctx);
    break;
  case kOptScopeTab: {
    tabpage_T *const saved_curtab = *(tabpage_T **)ctx;
    unuse_tabpage(curtab);
    use_tabpage(saved_curtab);
    break;
  }
  }
}

/// Get option value for buffer / window.
///
/// @param       opt_idx    Option index in options[] table.
/// @param[out]  flagsp     Set to the option flags (see OptFlags) (if not NULL).
/// @param[in]   scope      Option scope (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/// @param[out]  hidden     Whether option is hidden.
/// @param       scope      Option scope. See OptScope in option.h.
/// @param[in]   from       Target buffer/window.
/// @param[out]  err        Error message, if any.
///
/// @return  Option value. Must be freed by caller.
/* === removed: implemented in src/odin/option.odin === */


/// Set option value for buffer / window.
///
/// @param       name        Option name.
/// @param       opt_idx     Option index in options[] table.
/// @param[in]   value       Option value.
/// @param[in]   opt_flags   Flags: OPT_LOCAL, OPT_GLOBAL, or 0 (both).
/// @param       scope       Option scope. See OptScope in option.h.
/// @param[in]   from        Target buffer/window.
/// @param[out]  err         Error message, if any.
/* === removed: implemented in src/odin/option.odin === */


/// if 'all' == false: show changed options
/// if 'all' == true: show all normal options
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
static void showoptions(bool all, int opt_flags)
{
#define INC 20
#define GAP 3

  vimoption_T **items = xmalloc(sizeof(vimoption_T *) * OPTION_COUNT);

  msg_ext_set_kind("list_cmd");
  // Highlight title
  if (opt_flags & OPT_GLOBAL) {
    msg_puts_title(_("\n--- Global option values ---"));
  } else if (opt_flags & OPT_LOCAL) {
    msg_puts_title(_("\n--- Local option values ---"));
  } else {
    msg_puts_title(_("\n--- Options ---"));
  }

  // Do the loop two times:
  // 1. display the short items
  // 2. display the long items (only strings and numbers)
  // When "opt_flags" has OPT_ONECOLUMN do everything in run 2.
  for (int run = 1; run <= 2 && !got_int; run++) {
    // collect the items in items[]
    int item_count = 0;
    vimoption_T *opt;
    for (OptIndex opt_idx = 0; opt_idx < kOptCount; opt_idx++) {
      opt = &options[opt_idx];
      // apply :filter /pat/
      if (message_filtered(opt->fullname)) {
        continue;
      }

      void *varp = NULL;
      if ((opt_flags & (OPT_LOCAL | OPT_GLOBAL)) != 0) {
        if (!option_is_global_only(opt_idx)) {
          varp = get_varp_scope(opt, opt_flags);
        }
      } else {
        varp = get_varp(opt);
      }
      if (varp != NULL && (all || !optval_default(opt_idx, varp))) {
        int len;
        if (opt_flags & OPT_ONECOLUMN) {
          len = Columns;
        } else if (option_has_type(opt_idx, kOptValTypeBoolean)) {
          len = 1;                      // a toggle option fits always
        } else {
          option_value2string(opt, opt_flags);
          len = (int)strlen(opt->fullname) + vim_strsize(NameBuff) + 1;
        }
        if ((len <= INC - GAP && run == 1)
            || (len > INC - GAP && run == 2)) {
          items[item_count++] = opt;
        }
      }
    }

    int rows;

    // display the items
    if (run == 1) {
      assert(Columns <= INT_MAX - GAP
             && Columns + GAP >= INT_MIN + 3
             && (Columns + GAP - 3) / INC >= INT_MIN
             && (Columns + GAP - 3) / INC <= INT_MAX);
      int cols = (Columns + GAP - 3) / INC;
      if (cols == 0) {
        cols = 1;
      }
      rows = (item_count + cols - 1) / cols;
    } else {    // run == 2
      rows = item_count;
    }
    for (int row = 0; row < rows && !got_int; row++) {
      msg_putchar('\n');                        // go to next line
      if (got_int) {                            // 'q' typed in more
        break;
      }
      int col = 0;
      for (int i = row; i < item_count; i += rows) {
        msg_advance(col);                       // make columns
        showoneopt(items[i], opt_flags);
        col += INC;
      }
      os_breakcheck();
    }
  }
  xfree(items);
}

/// Return true if option "p" has its default value.
static int optval_default(OptIndex opt_idx, void *varp)
{
  vimoption_T *opt = &options[opt_idx];

  // Hidden options always use their default value.
  if (is_option_hidden(opt_idx)) {
    return true;
  }

  OptVal current_val = optval_from_varp(opt_idx, varp);
  OptVal default_val = opt->def_val;

  return optval_equal(current_val, default_val);
}

/// Send update to UIs with values of UI relevant options
/* === removed: implemented in src/odin/option.odin === */


/// showoneopt: show the value of one option
/// must not be called with a hidden option!
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
static void showoneopt(vimoption_T *opt, int opt_flags)
{
  int save_silent = silent_mode;

  silent_mode = false;
  info_message = true;          // use stdout, not stderr

  OptIndex opt_idx = get_opt_idx(opt);
  void *varp = get_varp_scope(opt, opt_flags);

  // for 'modified' we also need to check if 'ff' or 'fenc' changed.
  if (option_has_type(opt_idx, kOptValTypeBoolean)
      && ((int *)varp == &curbuf->b_changed ? !curbufIsChanged() : !*(int *)varp)) {
    msg_puts("no");
  } else if (option_has_type(opt_idx, kOptValTypeBoolean) && *(int *)varp < 0) {
    msg_puts("--");
  } else {
    msg_puts("  ");
  }
  msg_puts(opt->fullname);
  if (!(option_has_type(opt_idx, kOptValTypeBoolean))) {
    msg_putchar('=');
    // put value string in NameBuff
    option_value2string(opt, opt_flags);
    if (*NameBuff != NUL) {
      msg_outtrans(NameBuff, 0, false);
    }
  }

  silent_mode = save_silent;
  info_message = false;
}

/// Write modified options as ":set" commands to a file.
///
/// There are three values for "opt_flags":
/// OPT_GLOBAL:         Write global option values and fresh values of
///             buffer-local options (used for start of a session
///             file).
/// OPT_GLOBAL + OPT_LOCAL: Idem, add fresh values of window-local options for
///             curwin (used for a vimrc file).
/// OPT_LOCAL:          Write buffer-local option values for curbuf, fresh
///             and local values for window-local options of
///             curwin.  Local values are also written when at the
///             default value, because a modeline or autocommand
///             may have set them when doing ":edit file" and the
///             user has set them back at the default or fresh
///             value.
///             When "local_only" is true, don't write fresh
///             values, only local values (for ":mkview").
/// (fresh value = value used for a new buffer or window for a local option).
///
/// Return FAIL on error, OK otherwise.
/* === removed: implemented in src/odin/option.odin === */


/// Generate set commands for the local fold options only.  Used when
/// 'sessionoptions' or 'viewoptions' contains "folds" but not "options".
/* === removed: implemented in src/odin/option.odin === */


/// Print the ":set" command to set a single option to file.
///
/// @param  fd       File descriptor.
/// @param  cmd      Command name.
/// @param  opt_idx  Option index in options[] table.
/// @param  varp     Pointer to option variable.
///
/// @return FAIL on error, OK otherwise.
static int put_set(FILE *fd, char *cmd, OptIndex opt_idx, void *varp)
{
  OptVal value = optval_from_varp(opt_idx, varp);
  vimoption_T *opt = &options[opt_idx];
  char *name = opt->fullname;
  uint64_t flags = opt->flags;

  if (option_is_global_local(opt_idx) && varp != opt->var
      && optval_equal(value, get_option_unset_value(opt_idx))) {
    // Processing unset local value of global-local option. Do nothing.
    return OK;
  }

  switch (value.type) {
  case kOptValTypeNil:
    abort();
  case kOptValTypeBoolean: {
    assert(value.data.boolean != kNone);
    bool value_bool = TRISTATE_TO_BOOL(value.data.boolean, false);

    if (fprintf(fd, "%s %s%s", cmd, value_bool ? "" : "no", name) < 0) {
      return FAIL;
    }
    break;
  }
  case kOptValTypeNumber: {
    if (fprintf(fd, "%s %s=", cmd, name) < 0) {
      return FAIL;
    }

    OptInt value_num = value.data.number;

    OptInt wc;
    if (wc_use_keyname(varp, &wc)) {
      // print 'wildchar' and 'wildcharm' as a key name
      if (fputs(get_special_key_name((int)wc, 0), fd) < 0) {
        return FAIL;
      }
    } else if (fprintf(fd, "%" PRId64, value_num) < 0) {
      return FAIL;
    }
    break;
  }
  case kOptValTypeString: {
    if (fprintf(fd, "%s %s=", cmd, name) < 0) {
      return FAIL;
    }

    const char *value_str = value.data.string.data;
    char *buf = NULL;
    char *part = NULL;

    if (value_str != NULL) {
      if ((flags & kOptFlagExpand) != 0) {
        size_t size = (size_t)strlen(value_str) + 1;

        // replace home directory in the whole option value into "buf"
        buf = xmalloc(size);
        home_replace(NULL, value_str, buf, size, false);

        // If the option value is longer than MAXPATHL, we need to append
        // each comma separated part of the option separately, so that it
        // can be expanded when read back.
        if (size >= MAXPATHL && (flags & kOptFlagComma) != 0
            && vim_strchr(value_str, ',') != NULL) {
          part = xmalloc(size);

          // write line break to clear the option, e.g. ':set rtp='
          if (put_eol(fd) == FAIL) {
            goto fail;
          }
          char *p = buf;
          while (*p != NUL) {
            // for each comma separated option part, append value to
            // the option, :set rtp+=value
            if (fprintf(fd, "%s %s+=", cmd, name) < 0) {
              goto fail;
            }
            copy_option_part(&p, part, size, ",");
            if (put_escstr(fd, part, 2) == FAIL || put_eol(fd) == FAIL) {
              goto fail;
            }
          }
          xfree(buf);
          xfree(part);
          return OK;
        }
        if (put_escstr(fd, buf, 2) == FAIL) {
          xfree(buf);
          return FAIL;
        }
        xfree(buf);
      } else if (put_escstr(fd, value_str, 2) == FAIL) {
        return FAIL;
      }
    }
    break;
  fail:
    xfree(buf);
    xfree(part);
    return FAIL;
  }
  }

  if (put_eol(fd) < 0) {
    return FAIL;
  }
  return OK;
}

void *get_varp_scope_from(vimoption_T *p, int opt_flags, buf_T *buf, win_T *win)
{
  OptIndex opt_idx = get_opt_idx(p);

  if ((opt_flags & OPT_GLOBAL) && !option_is_global_only(opt_idx)) {
    if (option_is_window_local(opt_idx)) {
      return GLOBAL_WO(get_varp_from(p, buf, win));
    }
    return p->var;
  }

  if ((opt_flags & OPT_LOCAL) && option_is_global_local(opt_idx)) {
    switch (opt_idx) {
    case kOptFormatprg:
      return &(buf->b_p_fp);
    case kOptFsync:
      return &(buf->b_p_fs);
    case kOptFindfunc:
      return &(buf->b_p_ffu);
    case kOptErrorformat:
      return &(buf->b_p_efm);
    case kOptGrepformat:
      return &(buf->b_p_gefm);
    case kOptGrepprg:
      return &(buf->b_p_gp);
    case kOptMakeprg:
      return &(buf->b_p_mp);
    case kOptEqualprg:
      return &(buf->b_p_ep);
    case kOptKeywordprg:
      return &(buf->b_p_kp);
    case kOptPath:
      return &(buf->b_p_path);
    case kOptAutocomplete:
      return &(buf->b_p_ac);
    case kOptAutoread:
      return &(buf->b_p_ar);
    case kOptTags:
      return &(buf->b_p_tags);
    case kOptTagcase:
      return &(buf->b_p_tc);
    case kOptSidescrolloff:
      return &(win->w_p_siso);
    case kOptScrolloff:
      return &(win->w_p_so);
    case kOptScrolloffpad:
      return &(win->w_p_sop);
    case kOptDefine:
      return &(buf->b_p_def);
    case kOptInclude:
      return &(buf->b_p_inc);
    case kOptCompleteopt:
      return &(buf->b_p_cot);
    case kOptDictionary:
      return &(buf->b_p_dict);
    case kOptDiffanchors:
      return &(buf->b_p_dia);
    case kOptThesaurus:
      return &(buf->b_p_tsr);
    case kOptThesaurusfunc:
      return &(buf->b_p_tsrfu);
    case kOptTagfunc:
      return &(buf->b_p_tfu);
    case kOptShowbreak:
      return &(win->w_p_sbr);
    case kOptStatusline:
      return &(win->w_p_stl);
    case kOptWinbar:
      return &(win->w_p_wbr);
    case kOptUndolevels:
      return &(buf->b_p_ul);
    case kOptLispwords:
      return &(buf->b_p_lw);
    case kOptBackupcopy:
      return &(buf->b_p_bkc);
    case kOptMakeencoding:
      return &(buf->b_p_menc);
    case kOptFillchars:
      return &(win->w_p_fcs);
    case kOptListchars:
      return &(win->w_p_lcs);
    case kOptVirtualedit:
      return &(win->w_p_ve);
    default:
      abort();
    }
  }
  return get_varp_from(p, buf, win);
}

/// Get pointer to option variable, depending on local or global scope.
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
void *get_varp_scope(vimoption_T *p, int opt_flags)
{
  return get_varp_scope_from(p, opt_flags, curbuf, curwin);
}

/// Get pointer to option variable at 'opt_idx', depending on local or global
/// scope.
void *get_option_varp_scope_from(OptIndex opt_idx, int opt_flags, buf_T *buf, win_T *win)
{
  return get_varp_scope_from(&(options[opt_idx]), opt_flags, buf, win);
}

void *get_varp_from(vimoption_T *p, buf_T *buf, win_T *win)
{
  OptIndex opt_idx = get_opt_idx(p);

  // Hidden options and global-only options always use the same var pointer
  if (is_option_hidden(opt_idx) || option_is_global_only(opt_idx)) {
    return p->var;
  }

  switch (opt_idx) {
  // global option with local value: use local value if it's been set
  case kOptEqualprg:
    return *buf->b_p_ep != NUL ? &buf->b_p_ep : p->var;
  case kOptKeywordprg:
    return *buf->b_p_kp != NUL ? &buf->b_p_kp : p->var;
  case kOptPath:
    return *buf->b_p_path != NUL ? &(buf->b_p_path) : p->var;
  case kOptAutocomplete:
    return buf->b_p_ac >= 0 ? &(buf->b_p_ac) : p->var;
  case kOptAutoread:
    return buf->b_p_ar >= 0 ? &(buf->b_p_ar) : p->var;
  case kOptTags:
    return *buf->b_p_tags != NUL ? &(buf->b_p_tags) : p->var;
  case kOptTagcase:
    return *buf->b_p_tc != NUL ? &(buf->b_p_tc) : p->var;
  case kOptSidescrolloff:
    return win->w_p_siso >= 0 ? &(win->w_p_siso) : p->var;
  case kOptScrolloff:
    return win->w_p_so >= 0 ? &(win->w_p_so) : p->var;
  case kOptScrolloffpad:
    return win->w_p_sop >= 0 ? &(win->w_p_sop) : p->var;
  case kOptBackupcopy:
    return *buf->b_p_bkc != NUL ? &(buf->b_p_bkc) : p->var;
  case kOptDefine:
    return *buf->b_p_def != NUL ? &(buf->b_p_def) : p->var;
  case kOptInclude:
    return *buf->b_p_inc != NUL ? &(buf->b_p_inc) : p->var;
  case kOptCompleteopt:
    return *buf->b_p_cot != NUL ? &(buf->b_p_cot) : p->var;
  case kOptDictionary:
    return *buf->b_p_dict != NUL ? &(buf->b_p_dict) : p->var;
  case kOptDiffanchors:
    return *buf->b_p_dia != NUL ? &(buf->b_p_dia) : p->var;
  case kOptThesaurus:
    return *buf->b_p_tsr != NUL ? &(buf->b_p_tsr) : p->var;
  case kOptThesaurusfunc:
    return *buf->b_p_tsrfu != NUL ? &(buf->b_p_tsrfu) : p->var;
  case kOptFormatprg:
    return *buf->b_p_fp != NUL ? &(buf->b_p_fp) : p->var;
  case kOptFsync:
    return buf->b_p_fs >= 0 ? &(buf->b_p_fs) : p->var;
  case kOptFindfunc:
    return *buf->b_p_ffu != NUL ? &(buf->b_p_ffu) : p->var;
  case kOptErrorformat:
    return *buf->b_p_efm != NUL ? &(buf->b_p_efm) : p->var;
  case kOptGrepformat:
    return *buf->b_p_gefm != NUL ? &(buf->b_p_gefm) : p->var;
  case kOptGrepprg:
    return *buf->b_p_gp != NUL ? &(buf->b_p_gp) : p->var;
  case kOptMakeprg:
    return *buf->b_p_mp != NUL ? &(buf->b_p_mp) : p->var;
  case kOptShowbreak:
    return *win->w_p_sbr != NUL ? &(win->w_p_sbr) : p->var;
  case kOptStatusline:
    return *win->w_p_stl != NUL ? &(win->w_p_stl) : p->var;
  case kOptWinbar:
    return *win->w_p_wbr != NUL ? &(win->w_p_wbr) : p->var;
  case kOptUndolevels:
    return buf->b_p_ul != NO_LOCAL_UNDOLEVEL ? &(buf->b_p_ul) : p->var;
  case kOptLispwords:
    return *buf->b_p_lw != NUL ? &(buf->b_p_lw) : p->var;
  case kOptMakeencoding:
    return *buf->b_p_menc != NUL ? &(buf->b_p_menc) : p->var;
  case kOptFillchars:
    return *win->w_p_fcs != NUL ? &(win->w_p_fcs) : p->var;
  case kOptListchars:
    return *win->w_p_lcs != NUL ? &(win->w_p_lcs) : p->var;
  case kOptVirtualedit:
    return *win->w_p_ve != NUL ? &win->w_p_ve : p->var;

  case kOptArabic:
    return &(win->w_p_arab);
  case kOptList:
    return &(win->w_p_list);
  case kOptSpell:
    return &(win->w_p_spell);
  case kOptCursorcolumn:
    return &(win->w_p_cuc);
  case kOptCursorline:
    return &(win->w_p_cul);
  case kOptCursorlineopt:
    return &(win->w_p_culopt);
  case kOptColorcolumn:
    return &(win->w_p_cc);
  case kOptDiff:
    return &(win->w_p_diff);
  case kOptEventignorewin:
    return &(win->w_p_eiw);
  case kOptFoldcolumn:
    return &(win->w_p_fdc);
  case kOptFoldenable:
    return &(win->w_p_fen);
  case kOptFoldignore:
    return &(win->w_p_fdi);
  case kOptFoldlevel:
    return &(win->w_p_fdl);
  case kOptFoldmethod:
    return &(win->w_p_fdm);
  case kOptFoldminlines:
    return &(win->w_p_fml);
  case kOptFoldnestmax:
    return &(win->w_p_fdn);
  case kOptFoldexpr:
    return &(win->w_p_fde);
  case kOptFoldtext:
    return &(win->w_p_fdt);
  case kOptFoldmarker:
    return &(win->w_p_fmr);
  case kOptNumber:
    return &(win->w_p_nu);
  case kOptRelativenumber:
    return &(win->w_p_rnu);
  case kOptNumberwidth:
    return &(win->w_p_nuw);
  case kOptWinfixbuf:
    return &(win->w_p_wfb);
  case kOptWinfixheight:
    return &(win->w_p_wfh);
  case kOptWinfixwidth:
    return &(win->w_p_wfw);
  case kOptWinpinned:
    return &(win->w_p_wp);
  case kOptPreviewwindow:
    return &(win->w_p_pvw);
  case kOptLhistory:
    return &(win->w_p_lhi);
  case kOptRightleft:
    return &(win->w_p_rl);
  case kOptRightleftcmd:
    return &(win->w_p_rlc);
  case kOptScroll:
    return &(win->w_p_scr);
  case kOptSmoothscroll:
    return &(win->w_p_sms);
  case kOptWrap:
    return &(win->w_p_wrap);
  case kOptLinebreak:
    return &(win->w_p_lbr);
  case kOptBreakindent:
    return &(win->w_p_bri);
  case kOptBreakindentopt:
    return &(win->w_p_briopt);
  case kOptScrollbind:
    return &(win->w_p_scb);
  case kOptCursorbind:
    return &(win->w_p_crb);
  case kOptConcealcursor:
    return &(win->w_p_cocu);
  case kOptConceallevel:
    return &(win->w_p_cole);

  case kOptAutoindent:
    return &(buf->b_p_ai);
  case kOptBinary:
    return &(buf->b_p_bin);
  case kOptBomb:
    return &(buf->b_p_bomb);
  case kOptBufhidden:
    return &(buf->b_p_bh);
  case kOptBuftype:
    return &(buf->b_p_bt);
  case kOptBuflisted:
    return &(buf->b_p_bl);
  case kOptBusy:
    return &(buf->b_p_busy);
  case kOptChannel:
    return &(buf->b_p_channel);
  case kOptCopyindent:
    return &(buf->b_p_ci);
  case kOptCindent:
    return &(buf->b_p_cin);
  case kOptCinkeys:
    return &(buf->b_p_cink);
  case kOptCinoptions:
    return &(buf->b_p_cino);
  case kOptCinscopedecls:
    return &(buf->b_p_cinsd);
  case kOptCinwords:
    return &(buf->b_p_cinw);
  case kOptComments:
    return &(buf->b_p_com);
  case kOptCommentstring:
    return &(buf->b_p_cms);
  case kOptComplete:
    return &(buf->b_p_cpt);
#ifdef BACKSLASH_IN_FILENAME
  case kOptCompleteslash:
    return &(buf->b_p_csl);
#endif
  case kOptCompletefunc:
    return &(buf->b_p_cfu);
  case kOptOmnifunc:
    return &(buf->b_p_ofu);
  case kOptEndoffile:
    return &(buf->b_p_eof);
  case kOptEndofline:
    return &(buf->b_p_eol);
  case kOptFixendofline:
    return &(buf->b_p_fixeol);
  case kOptExpandtab:
    return &(buf->b_p_et);
  case kOptFileencoding:
    return &(buf->b_p_fenc);
  case kOptFileformat:
    return &(buf->b_p_ff);
  case kOptFiletype:
    return &(buf->b_p_ft);
  case kOptFormatoptions:
    return &(buf->b_p_fo);
  case kOptFormatlistpat:
    return &(buf->b_p_flp);
  case kOptIminsert:
    return &(buf->b_p_iminsert);
  case kOptImsearch:
    return &(buf->b_p_imsearch);
  case kOptInfercase:
    return &(buf->b_p_inf);
  case kOptIskeyword:
    return &(buf->b_p_isk);
  case kOptIncludeexpr:
    return &(buf->b_p_inex);
  case kOptIndentexpr:
    return &(buf->b_p_inde);
  case kOptIndentkeys:
    return &(buf->b_p_indk);
  case kOptFormatexpr:
    return &(buf->b_p_fex);
  case kOptLisp:
    return &(buf->b_p_lisp);
  case kOptLispoptions:
    return &(buf->b_p_lop);
  case kOptModeline:
    return &(buf->b_p_ml);
  case kOptMatchpairs:
    return &(buf->b_p_mps);
  case kOptModifiable:
    return &(buf->b_p_ma);
  case kOptModified:
    return &(buf->b_changed);
  case kOptNrformats:
    return &(buf->b_p_nf);
  case kOptPreserveindent:
    return &(buf->b_p_pi);
  case kOptQuoteescape:
    return &(buf->b_p_qe);
  case kOptReadonly:
    return &(buf->b_p_ro);
  case kOptScrollback:
    return &(buf->b_p_scbk);
  case kOptSmartindent:
    return &(buf->b_p_si);
  case kOptSofttabstop:
    return &(buf->b_p_sts);
  case kOptSuffixesadd:
    return &(buf->b_p_sua);
  case kOptSwapfile:
    return &(buf->b_p_swf);
  case kOptSynmaxcol:
    return &(buf->b_p_smc);
  case kOptSyntax:
    return &(buf->b_p_syn);
  case kOptSpellcapcheck:
    return &(win->w_s->b_p_spc);
  case kOptSpellfile:
    return &(win->w_s->b_p_spf);
  case kOptSpelllang:
    return &(win->w_s->b_p_spl);
  case kOptSpelloptions:
    return &(win->w_s->b_p_spo);
  case kOptShiftwidth:
    return &(buf->b_p_sw);
  case kOptTagfunc:
    return &(buf->b_p_tfu);
  case kOptTabstop:
    return &(buf->b_p_ts);
  case kOptTextwidth:
    return &(buf->b_p_tw);
  case kOptUndofile:
    return &(buf->b_p_udf);
  case kOptWrapmargin:
    return &(buf->b_p_wm);
  case kOptVarsofttabstop:
    return &(buf->b_p_vsts);
  case kOptVartabstop:
    return &(buf->b_p_vts);
  case kOptKeymap:
    return &(buf->b_p_keymap);
  case kOptSigncolumn:
    return &(win->w_p_scl);
  case kOptWinhighlight:
    return &(win->w_p_winhl);
  case kOptWinblend:
    return &(win->w_p_winbl);
  case kOptStatuscolumn:
    return &(win->w_p_stc);
  default:
    iemsg(_("E356: get_varp ERROR"));
  }
  // always return a valid pointer to avoid a crash!
  return &(buf->b_p_wm);
}

/// Get option index from option pointer
static inline OptIndex get_opt_idx(vimoption_T *opt)
  FUNC_ATTR_NONNULL_ALL FUNC_ATTR_WARN_UNUSED_RESULT FUNC_ATTR_PURE
{
  return (OptIndex)(opt - options);
}

/// Get pointer to option variable.
static inline void *get_varp(vimoption_T *p)
{
  return get_varp_from(p, curbuf, curwin);
}

/// Get the value of 'equalprg', either the buffer-local one or the global one.
char *get_equalprg(void)
{
  if (*curbuf->b_p_ep == NUL) {
    return p_ep;
  }
  return curbuf->b_p_ep;
}

/// Get the value of 'findfunc', either the buffer-local one or the global one.
char *get_findfunc(void)
{
  if (*curbuf->b_p_ffu == NUL) {
    return p_ffu;
  }
  return curbuf->b_p_ffu;
}

/// Copy options from one window to another.
/// Used when splitting a window.
/* === removed: implemented in src/odin/option.odin === */


static char *copy_option_val(const char *val)
{
  if (val == empty_string_option) {
    return empty_string_option;  // no need to allocate memory
  }
  return xstrdup(val);
}

/// Copy the options from one winopt_T to another.
/// Doesn't free the old option values in "to", use clear_winopt() for that.
/// The 'scroll' option is not copied, because it depends on the window height.
/// The 'previewwindow' option is reset, there can be only one preview window.
/* === removed: implemented in src/odin/option.odin === */


/// Check string options in a window for a NULL value.
static void check_win_options(win_T *win)
{
  check_winopt(&win->w_onebuf_opt);
  check_winopt(&win->w_allbuf_opt);
}

/// Odin port helper: initialize window string options so that they are
/// never NULL before the option defaults have been applied. Called from
/// win_alloc().
void nvim_odin_init_winopt(win_T *win)
{
  check_winopt(&win->w_onebuf_opt);
  check_winopt(&win->w_allbuf_opt);
}

/// Check for NULL pointers in a winopt_T and replace them with empty_string_option.
static void check_winopt(winopt_T *wop)
{
  check_string_option(&wop->wo_fdc);
  check_string_option(&wop->wo_fdc_save);
  check_string_option(&wop->wo_fdi);
  check_string_option(&wop->wo_fdm);
  check_string_option(&wop->wo_fdm_save);
  check_string_option(&wop->wo_fde);
  check_string_option(&wop->wo_fdt);
  check_string_option(&wop->wo_fmr);
  check_string_option(&wop->wo_eiw);
  check_string_option(&wop->wo_scl);
  check_string_option(&wop->wo_rlc);
  check_string_option(&wop->wo_sbr);
  check_string_option(&wop->wo_stl);
  check_string_option(&wop->wo_culopt);
  check_string_option(&wop->wo_cc);
  check_string_option(&wop->wo_cocu);
  check_string_option(&wop->wo_briopt);
  check_string_option(&wop->wo_winhl);
  check_string_option(&wop->wo_lcs);
  check_string_option(&wop->wo_fcs);
  check_string_option(&wop->wo_ve);
  check_string_option(&wop->wo_wbr);
  check_string_option(&wop->wo_stc);
}

/// Free the allocated memory inside a winopt_T.
/* === removed: implemented in src/odin/option.odin === */


/* === removed: implemented in src/odin/option.odin === */


#define COPY_OPT_SCTX(buf, bv) buf->b_p_script_ctx[bv] = options[buf_opt_idx[bv]].script_ctx

/// Copy global option values to local options for one buffer.
/// Used when creating a new buffer and sometimes when entering a buffer.
/// flags:
/// BCO_ENTER    We will enter the buffer "buf".
/// BCO_ALWAYS   Always copy the options, but only set b_p_initialized when
///      appropriate.
/// BCO_NOHELP   Don't copy the values to a help buffer.
/* === removed: implemented in src/odin/option.odin === */


/// Reset the 'modifiable' option and its default value.
/* === removed: implemented in src/odin/option.odin === */


/// Set the global value for 'iminsert' to the local value.
/* === removed: implemented in src/odin/option.odin === */


/// Set the global value for 'imsearch' to the local value.
/* === removed: implemented in src/odin/option.odin === */


static OptIndex expand_option_idx = kOptInvalid;
static int expand_option_start_col = 0;
static char expand_option_name[5] = { 't', '_', NUL, NUL, NUL };
static int expand_option_flags = 0;
static bool expand_option_append = false;

/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
/* === removed: implemented in src/odin/option.odin === */


/// Returns true if "str" either matches "regmatch" or fuzzy matches "pat".
///
/// If "test_only" is true and "fuzzy" is false and if "str" matches the regular
/// expression "regmatch", then returns true.  Otherwise returns false.
///
/// If "test_only" is false and "fuzzy" is false and if "str" matches the
/// regular expression "regmatch", then stores the match in matches[idx] and
/// returns true.
///
/// If "test_only" is true and "fuzzy" is true and if "str" fuzzy matches
/// "fuzzystr", then returns true. Otherwise returns false.
///
/// If "test_only" is false and "fuzzy" is true and if "str" fuzzy matches
/// "fuzzystr", then stores the match details in fuzmatch[idx] and returns true.
static bool match_str(char *const str, regmatch_T *const regmatch, char **const matches,
                      const int idx, const bool test_only, const bool fuzzy,
                      const char *const fuzzystr, fuzmatch_str_T *const fuzmatch)
{
  if (!fuzzy) {
    if (vim_regexec(regmatch, str, 0)) {
      if (!test_only) {
        matches[idx] = xstrdup(str);
      }
      return true;
    }
  } else {
    const int score = fuzzy_match_str(str, fuzzystr);
    if (score != FUZZY_SCORE_NONE) {
      if (!test_only) {
        fuzmatch[idx].idx = idx;
        fuzmatch[idx].str = xstrdup(str);
        fuzmatch[idx].score = score;
      }
      return true;
    }
  }
  return false;
}

/* === removed: implemented in src/odin/option.odin === */


/// Escape an option value that can be used on the command-line with :set.
/// Caller needs to free the returned string, unless NULL is returned.
char *escape_option_str_cmdline(char *var)
{
  // A backslash is required before some characters.  This is the reverse of
  // what happens in do_set().
  char *buf = vim_strsave_escaped(var, escape_chars);

#ifdef BACKSLASH_IN_FILENAME
  // For MS-Windows et al. we don't double backslashes at the start and
  // before a file name character.
  // The reverse is found at stropt_copy_value().
  for (var = buf; *var != NUL; MB_PTR_ADV(var)) {
    if (var[0] == '\\' && var[1] == '\\'
        && expand_option_idx != kOptInvalid
        && (options[expand_option_idx].flags & kOptFlagExpand)
        && vim_isfilec((uint8_t)var[2])
        && (var[2] != '\\' || (var == buf && var[4] != '\\'))) {
      STRMOVE(var, var + 1);
    }
  }
#endif
  return buf;
}

/// Expansion handler for :set= when we just want to fill in with the existing value.
/* === removed: implemented in src/odin/option.odin === */


/// Expansion handler for :set=/:set+= when the option has a custom expansion handler.
/* === removed: implemented in src/odin/option.odin === */


/// Expansion handler for :set-=
/* === removed: implemented in src/odin/option.odin === */


/// Get the value for the numeric or string option///opp in a nice format into
/// NameBuff[].  Must not be called with a hidden option!
///
/// @param  opt_flags  Option flags (can be OPT_LOCAL, OPT_GLOBAL or a combination).
///
/// TODO(famiu): Replace this with optval_to_cstr() if possible.
static void option_value2string(vimoption_T *opt, int opt_flags)
{
  void *varp = get_varp_scope(opt, opt_flags);
  assert(varp != NULL);

  if (option_has_type(get_opt_idx(opt), kOptValTypeNumber)) {
    OptInt wc = 0;

    if (wc_use_keyname(varp, &wc)) {
      xstrlcpy(NameBuff, get_special_key_name((int)wc, 0), sizeof(NameBuff));
    } else if (wc != 0) {
      xstrlcpy(NameBuff, transchar((int)wc), sizeof(NameBuff));
    } else {
      snprintf(NameBuff,
               sizeof(NameBuff),
               "%" PRId64,
               (int64_t)(*(OptInt *)varp));
    }
  } else {  // string
    varp = *(char **)varp;

    if (opt->flags & kOptFlagExpand) {
      home_replace(NULL, varp, NameBuff, MAXPATHL, false);
    } else {
      xstrlcpy(NameBuff, varp, MAXPATHL);
    }
  }
}

/// Return true if "varp" points to 'wildchar' or 'wildcharm' and it can be
/// printed as a keyname.
/// "*wcp" is set to the value of the option if it's 'wildchar' or 'wildcharm'.
static int wc_use_keyname(const void *varp, OptInt *wcp)
{
  if (((OptInt *)varp == &p_wc) || ((OptInt *)varp == &p_wcm)) {
    *wcp = *(OptInt *)varp;
    if (IS_SPECIAL(*wcp) || find_special_key_in_table((int)(*wcp)) >= 0) {
      return true;
    }
  }
  return false;
}

/// @returns true if "x" is present in 'shortmess' option, or
/// 'shortmess' contains 'a' and "x" is present in SHM_ALL_ABBREVIATIONS.
/* === removed: implemented in src/odin/option.odin === */


/// vimrc_found() - Called when a vimrc or "VIMINIT" has been found.
///
/// Set the values for options that didn't get set yet to the defaults.
/// When "fname" is not NULL, use it to set $"envname" when it wasn't set yet.
/* === removed: implemented in src/odin/option.odin === */


/// Check whether global option has been set.
///
/// @param[in]  name  Option name.
///
/// @return True if option was set.
/* === removed: implemented in src/odin/option.odin === */


/// Reset the flag indicating option "name" was set.
///
/// @param[in]  name  Option name.
/* === removed: implemented in src/odin/option.odin === */


/// fill_culopt_flags() -- called when 'culopt' changes value
/* === removed: implemented in src/odin/option.odin === */


/// Get the value of 'magic' taking "magic_overruled" into account.
/* === removed: implemented in src/odin/option.odin === */


/// Set the callback function value for an option that accepts a function name,
/// lambda, et al. (e.g. 'operatorfunc', 'tagfunc', etc.)
/// @return  OK if the option is successfully set to a function, otherwise FAIL
static OptValType option_get_type(const OptIndex opt_idx)
{
  return options[opt_idx].type;
}

static Dict vimoption2dict(vimoption_T *opt, int opt_flags, buf_T *buf, win_T *win, Arena *arena)
{
  OptIndex opt_idx = get_opt_idx(opt);
  Dict dict = arena_dict(arena, 13);

  PUT_C(dict, "name", CSTR_AS_OBJ(opt->fullname));
  PUT_C(dict, "shortname", CSTR_AS_OBJ(opt->shortname));

  const char *scope;
  if (option_has_scope(opt_idx, kOptScopeBuf)) {
    scope = "buf";
  } else if (option_has_scope(opt_idx, kOptScopeWin)) {
    scope = "win";
  } else if (option_has_scope(opt_idx, kOptScopeTab)) {
    scope = "tab";
  } else {
    scope = "global";
  }

  PUT_C(dict, "scope", CSTR_AS_OBJ(scope));

  // welcome to the jungle
  PUT_C(dict, "global_local", BOOLEAN_OBJ(option_is_global_local(opt_idx)));
  PUT_C(dict, "commalist", BOOLEAN_OBJ(opt->flags & kOptFlagComma));
  PUT_C(dict, "flaglist", BOOLEAN_OBJ(opt->flags & kOptFlagFlagList));

  PUT_C(dict, "was_set", BOOLEAN_OBJ(opt->flags & kOptFlagWasSet));

  sctx_T script_ctx = { .sc_sid = 0 };
  if (opt_flags == OPT_GLOBAL) {
    script_ctx = opt->script_ctx;
  } else {
    // Scope is either OPT_LOCAL or a fallback mode was requested.
    if (option_has_scope(opt_idx, kOptScopeBuf)) {
      script_ctx = buf->b_p_script_ctx[opt->scope_idx[kOptScopeBuf]];
    }
    if (option_has_scope(opt_idx, kOptScopeWin)) {
      script_ctx = win->w_p_script_ctx[opt->scope_idx[kOptScopeWin]];
    }
    if (opt_flags != OPT_LOCAL && script_ctx.sc_sid == 0) {
      script_ctx = opt->script_ctx;
    }
  }

  PUT_C(dict, "last_set_sid", INTEGER_OBJ(script_ctx.sc_sid));
  PUT_C(dict, "last_set_linenr", INTEGER_OBJ(script_ctx.sc_lnum));
  PUT_C(dict, "last_set_chan", INTEGER_OBJ((int64_t)script_ctx.sc_chan));

  PUT_C(dict, "type", CSTR_AS_OBJ(optval_type_get_name(option_get_type(get_opt_idx(opt)))));
  PUT_C(dict, "default", optval_as_object(opt->def_val));
  PUT_C(dict, "allows_duplicates", BOOLEAN_OBJ(!(opt->flags & kOptFlagNoDup)));

  return dict;
}

vimoption_T *nvim_odin_opt_table(void)
{
  return &options[0];
}

int nvim_odin_opt_count(void)
{
  return (int)kOptCount;
}

// Variable pointer for an option index (global var or scope table entry).
void *nvim_odin_opt_varp(int opt_idx)
{
  return get_varp_scope(&options[opt_idx], OPT_GLOBAL);
}

// Scope-aware varp: wraps get_varp_scope_from (the big switch stays in C).
void *nvim_odin_get_varp_scope_from(int opt_idx, int opt_flags, buf_T *buf, win_T *win)
{
  return get_varp_scope_from(&options[opt_idx], opt_flags, buf, win);
}

void *nvim_odin_get_varp_scope(int opt_idx, int opt_flags)
{
  return get_varp_scope(&options[opt_idx], opt_flags);
}

void *nvim_odin_get_varp_from(int opt_idx, buf_T *buf, win_T *win)
{
  return get_varp_from(&options[opt_idx], buf, win);
}

bool nvim_odin_option_is_global_local(int opt_idx)
{
  return option_is_global_local(opt_idx);
}

OptVal nvim_odin_get_option_unset_value(int opt_idx)
{
  return get_option_unset_value(opt_idx);
}

uint32_t *nvim_odin_insecure_flag(win_T *wp, int opt_idx, int opt_flags)
{
  return insecure_flag(wp, opt_idx, opt_flags);
}

// Static helpers exposed for the Odin port (src/odin/option.odin).
void nvim_odin_do_syntax_autocmd(buf_T *buf, bool value_changed)
{
  do_syntax_autocmd(buf, value_changed);
}

void nvim_odin_do_spelllang_source(win_T *win)
{
  do_spelllang_source(win);
}

OptIndex nvim_odin_find_option_len(const char *name, size_t len)
{
  return find_option_len(name, len);
}

// Startup wrappers: set_init_* have deep static dependencies; keep them callable
// from Odin via shims until the full port lands.
void nvim_odin_set_init_1(bool clean_arg)
{
  set_init_1(clean_arg);
}

void nvim_odin_set_init_2(bool headless)
{
  set_init_2(headless);
}

void nvim_odin_set_init_3(void)
{
  set_init_3();
}

void nvim_odin_set_init_tablocal(void)
{
  set_init_tablocal();
}

char *nvim_odin_get_p_term(void)
{
  return p_term;
}

char *nvim_odin_get_p_ttytype(void)
{
  return p_ttytype;
}

void nvim_odin_set_p_term(char *val)
{
  p_term = val;
}

void nvim_odin_set_p_ttytype(char *val)
{
  p_ttytype = val;
}

void nvim_odin_change_option_default(int opt_idx, OptVal val)
{
  change_option_default(opt_idx, val);
}

void nvim_odin_clear_p_term_ttytype(void)
{
  XFREE_CLEAR(p_term);
  XFREE_CLEAR(p_ttytype);
}

bool nvim_odin_switch_option_context(void *ctx, int scope, void *from, Error *err)
{
  return switch_option_context(ctx, (OptScope)scope, from, err);
}

void nvim_odin_restore_option_context(void *ctx, int scope)
{
  restore_option_context(ctx, (OptScope)scope);
}

void nvim_odin_apply_optionset_autocmd(int opt_idx, int opt_flags, OptVal oldval, OptVal oldval_g,
                                       OptVal oldval_l, OptVal newval, const char *errmsg)
{
  apply_optionset_autocmd(opt_idx, opt_flags, oldval, oldval_g, oldval_l, newval, errmsg);
}

OptInt nvim_odin_get_p_tw_nobin(void) { return p_tw_nobin; }
OptInt nvim_odin_get_p_wm_nobin(void) { return p_wm_nobin; }
int nvim_odin_get_p_ml_nobin(void) { return p_ml_nobin; }
int nvim_odin_get_p_et_nobin(void) { return p_et_nobin; }
void nvim_odin_set_p_tw_nobin(OptInt v) { p_tw_nobin = v; }
void nvim_odin_set_p_wm_nobin(OptInt v) { p_wm_nobin = v; }
void nvim_odin_set_p_ml_nobin(int v) { p_ml_nobin = v; }
void nvim_odin_set_p_et_nobin(int v) { p_et_nobin = v; }

char *nvim_odin_option_expand(int opt_idx, const char *val) { return option_expand(opt_idx, val); }

Dict nvim_odin_vimoption2dict(vimoption_T *opt, int opt_flags, buf_T *buf, win_T *win, Arena *arena)
{
  return vimoption2dict(opt, opt_flags, buf, win, arena);
}

void nvim_odin_put_c(Dict *d, const char *key, Object value)
{
  PUT_C(*d, key, value);
}

int nvim_odin_get_p_ai_nopaste(void) { return p_ai_nopaste; }
OptInt nvim_odin_get_p_tw_nopaste(void) { return p_tw_nopaste; }
OptInt nvim_odin_get_p_wm_nopaste(void) { return p_wm_nopaste; }
int nvim_odin_get_p_et_nopaste(void) { return p_et_nopaste; }
OptInt nvim_odin_get_p_sts_nopaste(void) { return p_sts_nopaste; }
char *nvim_odin_get_p_vsts_nopaste(void) { return p_vsts_nopaste; }

void nvim_odin_didset_options_sctx(int opt_flags, int *opts)
{
  didset_options_sctx(opt_flags, opts);
}

int *nvim_odin_get_p_bin_dep_opts(void) { return p_bin_dep_opts; }
int *nvim_odin_get_p_paste_dep_opts(void) { return p_paste_dep_opts; }
