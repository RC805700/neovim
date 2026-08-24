package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import "core:sys/posix"
import "core:terminal"
import "core:c/libc"

foreign import nvim "../../build/lib/libnvim.a"

@(default_calling_convention = "c")
foreign _ {
	backtrace_symbols :: proc(buffer: [^]rawptr, size: c.int) -> ^^cstring ---
	signal            :: proc(signum: c.int, handler: proc "c" (c.int)) -> rawptr ---
}

bt_handler :: proc "c" (signum: c.int) {
	buffer: [128]rawptr
	n := backtrace(raw_data(buffer[:]), 128)
	syms := backtrace_symbols(raw_data(buffer[:]), n)
	libc.fprintf(libc.stderr, "=== BACKTRACE (n=%d) ===\n", n)
	for i in 0 ..< int(n) {
		libc.fprintf(libc.stderr, "#%d %s\n", i, ([^]cstring)(syms)[i])
	}
}

// ── Type mirrors for klib map/set infrastructure ──

String :: struct {
  data: cstring,
  size: c.size_t,
}

HlAttrs :: struct {
  rgb_ae_attr:     i32,
  cterm_ae_attr:   i32,
  rgb_fg_color:    i32,
  rgb_bg_color:    i32,
  rgb_sp_color:    i32,
  cterm_fg_color:  i16,
  cterm_bg_color:  i16,
  hl_blend:        i32,
  url:             i32,
  font:            i32,
}

HlKind :: enum c.int {
  kHlUnknown,
  kHlUI,
  kHlSyntax,
  kHlTerminal,
  kHlCombine,
  kHlBlend,
  kHlBlendThrough,
  kHlInvalid,
}

HlEntry :: struct {
  attr:  HlAttrs,
  kind:  HlKind,
  id1:   c.int,
  id2:   c.int,
  winid: c.int,
}

@(export)
attr_entries: Set_HlEntry

HLATTRS_INIT :: HlAttrs {
  rgb_ae_attr    = 0,
  cterm_ae_attr  = 0,
  rgb_fg_color   = -1,
  rgb_bg_color   = -1,
  rgb_sp_color   = -1,
  cterm_fg_color = 0,
  cterm_bg_color = 0,
  hl_blend       = -1,
  url            = -1,
  font           = -1,
}

@(export)
highlight_init :: proc "c" () {
  dummy := HlEntry {
    attr = HLATTRS_INIT,
    kind = .kHlInvalid,
  }
  status: MHPutStatus
  mh_put_HlEntry(&attr_entries, dummy, &status)
}

ColorKey :: struct {
  ns_id: c.int,
  syn_id: c.int,
}

ColorItem :: struct {
  attr_id:     c.int,
  link_id:     c.int,
  version:     c.int,
  is_default:  bool,
  link_global: bool,
}

MTDamage :: struct {
  old:  rawptr,
  new:  rawptr,
  old_i: c.int,
  new_i: c.int,
}

MTDamagePair :: struct {
  start: MTDamage,
  end:   MTDamage,
}

StlClickDefinition :: struct {
  type:   c.int,
  tabnr:  c.int,
  func:   cstring,
}

StcClick :: struct {
  def:  ^StlClickDefinition,
  size: c.size_t,
}

// StcClicks = Map(int, StcClick) — referenced by klib.odin
// (struct layout mirrors C: { Set_int set; StcClick *values; })
StcClicks :: struct {
  set:    Set_int,
  values: [^]StcClick,
}

// ── Foreign globals (C extern variables) ──
// NOTE: No `---` suffix for variable declarations.
@(link_prefix = "")
foreign nvim {
  headless_mode: bool
  stdin_isatty: bool
  stdout_isatty: bool
  stderr_isatty: bool
  embedded_mode: bool
  silent_mode: bool
  recoverymode: bool
  exmode_active: bool
  ui_client_channel_id: u64
  ui_client_exit_status: c.int
  ui_client_forward_stdin: bool
  exiting: bool
  RedrawingDisabled: c.int
  full_screen: bool
  cmdline_row: c.int
  msg_row: c.int
  Rows: c.int
  Columns: c.int
  msg_scroll: bool
  no_wait_return: bool
  debug_break_level: c.int
  starting: c.int
  scriptout: rawptr
  firstwin: rawptr
  curwin: rawptr
  curbuf: rawptr
  curtab: rawptr
  stdin_fd: c.int
  p_ch: c.long
  p_uc: c.long
  p_ut: c.long
  p_lpl: c.int
  p_shada: cstring
  ccline: CmdlineInfo
  nv_max_linear: c.int
}

// ── Foreign functions ──
@(link_prefix = "", default_calling_convention = "c")
foreign nvim {
  // Startup sequence
  event_init :: proc() ---
  set_argv_var :: proc(argv: [^]cstring, argc: c.int) ---
  command_line_scan :: proc(parmp: ^Mparm) ---
  set_argf_var :: proc() ---
  nlua_init :: proc(argv: [^]cstring, argc: c.int, lua_arg0: c.int) ---
  server_init :: proc(listen_addr: cstring) -> bool ---
  win_init_size :: proc() ---
  default_grid_alloc :: proc() ---
  set_init_2 :: proc(headless: bool) ---
  init_highlight :: proc(load_defaults: bool, reinit: bool) ---
  ui_comp_syn_init :: proc() ---
  screenclear :: proc() ---
  win_new_screensize :: proc() ---
  nlua_init_defaults :: proc() ---
  exe_pre_commands :: proc(parmp: ^Mparm) ---
  source_startup_scripts :: proc(parmp: ^Mparm) ---
  load_plugins :: proc() ---
  set_init_3 :: proc() ---
  shada_read_everything :: proc(fname: cstring, forced: bool, mfp: bool) ---
  create_windows :: proc(parmp: ^Mparm) ---
  edit_buffers :: proc(parmp: ^Mparm) ---
  exe_commands :: proc(parmp: ^Mparm) ---
  normal_enter :: proc(noexmode: bool) ---

  // early_init helpers (formerly called inside C's early_init)
  exestack: Garray
  ga_grow :: proc(gap: ^Garray, n: c.int) ---
  eval_init :: proc() ---
  // os_realtime — PORTED to Odin (time.odin)
  runtime_init :: proc() ---
  // highlight_init — PORTED to Odin
  // init_locale — PORTED to Odin (os_lang.odin)
  // set_init_tablocal — PORTED to Odin (option.odin)
  win_alloc_first :: proc() ---
  startup_alist_init :: proc() ---
  // init_homedir           — PORTED to Odin (uses startup_set_homedir + os.getwd)
  // startup_set_homedir    — PORTED to Odin (os_env.odin; sets `homedir` global)
  set_init_1 :: proc(clean: bool) ---
  log_mutex_init :: proc() ---
  // log_init — PORTED to Odin
  // set_lang_var      — PORTED to Odin
  qf_init_stack :: proc() ---

  // Mid-startup helpers
  remote_request :: proc(params: ^Mparm, remote_args: c.int, server_addr: cstring, argc: c.int, argv: [^]cstring, ui_only: bool) ---
  ui_client_start_server :: proc(progpath: cstring, argc: c.size_t, argv: [^]cstring) -> u64 ---
  ui_client_run :: proc() ---
  remote_ui_wait_for_attach :: proc() ---
  edit_stdin :: proc(parmp: ^Mparm) -> bool ---
  open_scriptin :: proc(fname: cstring) -> bool ---
  // os_fopen now provided by os_fs.odin (Odin implementation)
  get_fname :: proc(parmp: ^Mparm) -> cstring ---
  set_window_layout :: proc(paramp: ^Mparm) ---
  handle_quickfix :: proc(paramp: ^Mparm) ---
  handle_tag :: proc(tagname: cstring) ---
  read_stdin :: proc() ---
  diff_win_options :: proc(win: rawptr, startup: bool) ---
  shorten_fnames :: proc(force: bool) ---
  setmouse :: proc() ---
  redraw_later :: proc(win: rawptr, type_: c.int) ---
  qf_jump :: proc(eap: rawptr, forceit: c.int, errornr: c.int, FILE_IT: bool) ---
  apply_autocmds :: proc "c" (event: c.int, fname: cstring, fname2: cstring, group: bool, buf: rawptr) -> bool ---

  // Vim variable access
  set_vim_var_nr :: proc(idx: c.int, val: i64) ---
  set_vim_var_string :: proc(idx: c.int, val: cstring, len: c.ssize_t) ---
  get_vim_var_str :: proc(idx: c.int) -> cstring ---
  get_vim_var_list :: proc(idx: c.int) -> rawptr ---
  set_vim_var_list :: proc(idx: c.int, val: rawptr) ---
  tv_list_alloc :: proc(n: c.ssize_t) -> rawptr ---

  // Startup helpers
  do_autochdir :: proc() ---
  do_autocmd_uienter_all :: proc() ---
  set_reg_var :: proc(c: c.int) ---
  redraw_all_later :: proc(type_: c.int) ---

  os_exit :: proc(r: c.int) ---

  // Wrappers added for Odin
  startup_gargcount :: proc() -> c.int ---
  startup_set_cursor_last_line :: proc() ---
  startup_save_firstwin_height :: proc() ---
  startup_shada_nonempty :: proc() -> bool ---
  startup_channel_from_stdio :: proc() ---
  startup_diff_win_options_all :: proc() ---
  startup_recovery_list_swaps :: proc() ---
  startup_setbuf_stdout_null :: proc() ---
  startup_restart_edit_check :: proc() ---
  startup_cb_flags_check :: proc() ---
  startup_diff_scrollbind_check :: proc() ---
  startup_exec_luaf :: proc(luaf: cstring) ---
  startup_nv_cmds_size :: proc() -> c.int ---
  startup_nv_cmds_ptr :: proc() -> rawptr ---
  startup_nv_cmd_idx_ptr :: proc() -> rawptr ---
 
  // Startup timing (--startuptime)
  time_init :: proc(fname: cstring, proc_name: cstring) ---
  time_start :: proc(message: cstring) ---
  time_msg :: proc(message: cstring, start: rawptr) ---
}

// ── Foreign libc / libuv functions ──
Dl_info :: struct {
  dli_fname:  cstring,
  dli_fbase:  rawptr,
  dli_sname:  cstring,
  dli_saddr:  rawptr,
}

@(default_calling_convention = "c")
foreign _ {
  setlocale :: proc(category: c.int, locale: cstring) -> cstring ---
  atexit :: proc(fn: proc "c" ()) -> c.int ---
  dladdr :: proc(addr: rawptr, info: ^Dl_info) -> c.int ---
}

// ── Constants (mirroring C enums/defines) ──

WindowLayout :: enum c.int {
  WIN_HOR  = 1,
  WIN_VER  = 2,
  WIN_TABS = 3,
}

EditType :: enum c.int {
  EDIT_NONE  = 0,
  EDIT_FILE  = 1,
  EDIT_STDIN = 2,
  EDIT_TAG   = 3,
  EDIT_QF    = 4,
}

NO_BUFFERS :: 1

// Locale category constants (from locale.h)
LC_CTYPE :: 0
LC_TIME :: 2
LC_COLLATE :: 3
LC_MESSAGES :: 5

// VimVarIndex values (from eval_defs.h)
VV_SWAPCOMMAND :: 49
VV_OLDFILES :: 58
VV_PROGPATH :: 60
VV_PROGNAME :: 27
VV_VIM_DID_INIT :: 94
VV_VIM_DID_ENTER :: 75
VV_STARTTIME :: 104
VV_LANG :: 13
VV_LC_TIME :: 14
VV_CTYPE :: 15
VV_COLLATE :: 90

// Redraw priority values (from drawscreen.h)
UPD_NOT_VALID :: 40

// event_T values (from auevents_enum.generated.h)
EVENT_BUFENTER :: 3
EVENT_VIMENTER :: 136

// ── mparm_T mirror struct ──
MAX_ARG_CMDS :: 10

Mparm :: struct {
  argc:                  c.int,
  argv:                  [^]cstring,
  use_vimrc:             cstring,
  clean:                 bool,
  n_commands:            c.int,
  commands:              [MAX_ARG_CMDS]cstring,
  cmds_tofree:           [MAX_ARG_CMDS]i8,
  n_pre_commands:        c.int,
  pre_commands:          [MAX_ARG_CMDS]cstring,
  luaf:                  cstring,
  lua_arg0:              c.int,
  edit_type:             c.int,
  tagname:               cstring,
  use_ef:                cstring,
  input_istext:          bool,
  no_swap_file:          c.int,
  use_debug_break_level: c.int,
  window_count:          c.int,
  window_layout:         c.int,
  diff_mode:             c.int,
  listen_addr:           cstring,
  remote:                c.int,
  server_addr:           cstring,
  scriptin:              cstring,
  scriptout:             cstring,
  scriptout_append:      bool,
  had_stdin_file:        bool,
}

Etype :: enum c.int {
  ETYPE_TOP      = 0,
  ETYPE_SCRIPT   = 1,
  ETYPE_UFUNC    = 2,
  ETYPE_AUCMD    = 3,
  ETYPE_MODELINE = 4,
  ETYPE_EXCEPT   = 5,
  ETYPE_ARGS     = 6,
  ETYPE_ENV      = 7,
  ETYPE_INTERNAL = 8,
  ETYPE_SPELL    = 9,
}

Garray :: struct {
  ga_len:      c.int,
  ga_maxlen:   c.int,
  ga_itemsize: c.int,
  ga_growsize: c.int,
  ga_data:     rawptr,
}

Estack :: struct {
  es_lnum: i32,
  es_name: cstring,
  es_type: Etype,
  es_info: rawptr,
}

NvCmd :: struct {
  cmd_char: c.int,
  cmd_func: rawptr,
  cmd_flags: u16,
  cmd_arg: i16,
}

CmdlineColorChunk :: struct {
  start: c.int,
  end:   c.int,
  hl_id: c.int,
}

CmdlineColors :: struct {
  size:     c.size_t,
  capacity: c.size_t,
  items:    ^CmdlineColorChunk,
}

ColoredCmdline :: struct {
  prompt_id: c.uint,
  cmdbuff:   cstring,
  colors:    CmdlineColors,
}

CmdRedraw :: enum c.int {
  kCmdRedrawNone = 0,
  kCmdRedrawPos  = 1,
  kCmdRedrawAll  = 2,
}

CallbackType :: enum c.int {
  kCallbackNone    = 0,
  kCallbackFuncref = 1,
  kCallbackPartial = 2,
  kCallbackLua     = 3,
}

Callback :: struct {
  data: rawptr,
  type: CallbackType,
}

CmdlineInfo :: cmdline_info

cmdline_info :: struct {
  cmdbuff:            cstring,
  cmdbufflen:         c.int,
  cmdlen:             c.int,
  cmdpos:             c.int,
  cmdspos:            c.int,
  cmdfirstc:          c.int,
  cmdindent:          c.int,
  cmdprompt:          cstring,
  hl_id:              c.int,
  overstrike:         c.int,
  xpc:                rawptr,
  xp_context:         c.int,
  xp_arg:             cstring,
  input_fn:           c.int,
  cmdbuff_replaced:   bool,
  prompt_id:          c.uint,
  highlight_callback: Callback,
  last_colors:        ColoredCmdline,
  level:              c.int,
  prev_ccline:        rawptr,
  special_char:       c.char,
  special_shift:      bool,
  redraw_state:       CmdRedraw,
  one_key:            bool,
  mouse_used:         ^bool,
}

Memory :: struct {
  arena: virtual.Arena,
  track: mem.Tracking_Allocator,
}

_memory: Memory

// ── Ported startup functions ──

// appname_is_valid() is defined (exported, C-callable) in os_stdpaths.odin.
// It is called both from Odin startup below and from C code that links the symbol.

/// Initialize global startuptime file if "--startuptime" passed as an argument.
init_startuptime :: proc(paramp: ^Mparm) {
  is_embed := false
  for i in 1 ..< int(paramp.argc) - 1 {
    arg := string(paramp.argv[i])
    if strings.equal_fold(arg, "--embed") {
      is_embed = true
      break
    }
  }
  for i in 1 ..< int(paramp.argc) - 1 {
    arg := string(paramp.argv[i])
    if strings.equal_fold(arg, "--startuptime") {
      if is_embed {
        time_init(paramp.argv[i + 1], "Embedded")
      } else {
        time_init(paramp.argv[i + 1], "Primary (or UI client)")
      }
      time_start("--- NVIM STARTING ---")
      break
    }
  }
}

/// Check whether stdin/stdout/stderr are connected to a terminal.
check_and_set_isatty :: proc(paramp: ^Mparm) {
  stdin_isatty = terminal.is_terminal(os.stdin)
  stdout_isatty = terminal.is_terminal(os.stdout)
  stderr_isatty = terminal.is_terminal(os.stderr)
  time_msg("window checked", nil)
}

/// Sets v:progname and v:progpath from the executable path.
init_path :: proc(exename: cstring) {
  exepath_str: string
  if path, err := os.get_executable_path(context.temp_allocator); err == nil {
    exepath_str = path
  } else {
    exepath_str = string(exename)
  }
  exepath_cstr := strings.clone_to_cstring(exepath_str, context.temp_allocator)
  set_vim_var_string(VV_PROGPATH, exepath_cstr, -1)

  progname := filepath.base(string(exename))
  progname_cstr := strings.clone_to_cstring(progname, context.temp_allocator)
  set_vim_var_string(VV_PROGNAME, progname_cstr, -1)
  free_all(context.temp_allocator)
}

/// Read $HOME and set the C `homedir` static. Falls back to getpwuid then CWD.

/// Initialize the execution stack with a sentinel ETYPE_TOP entry.
estack_init :: proc() {
  ga_grow(&exestack, 10)
  entry := ([^]Estack)(exestack.ga_data)
  entry[exestack.ga_len] = Estack {
    es_lnum = 0,
    es_name = nil,
    es_type = .ETYPE_TOP,
    es_info = nil,
  }
  exestack.ga_len += 1
}

/// Build the sorted index table for normal-mode command dispatch.
init_normal_cmds :: proc() {
  n := startup_nv_cmds_size()
  cmds := ([^]NvCmd)(startup_nv_cmds_ptr())
  idx := ([^]i16)(startup_nv_cmd_idx_ptr())
  idx_slice := idx[:n]

  for i in 0 ..< n {
    idx_slice[i] = i16(i)
  }

  sort.quick_sort_proc(idx_slice, proc(a, b: i16) -> int {
    ca := ([^]NvCmd)(startup_nv_cmds_ptr())[a].cmd_char
    cb := ([^]NvCmd)(startup_nv_cmds_ptr())[b].cmd_char
    if ca < 0 { ca = -ca }
    if cb < 0 { cb = -cb }
    return int(ca - cb)
  })

  i: i16
  for i = 0; i < i16(n); i += 1 {
    if c.int(i) != cmds[idx[i]].cmd_char {
      break
    }
  }
  nv_max_linear = c.int(i - 1)
}

/// Copy argc/argv into the mparm_T struct with sensible defaults.
init_params :: proc(paramp: ^Mparm, argc: c.int, argv: [^]cstring) {
  paramp^ = Mparm {
    argc                  = argc,
    argv                  = argv,
    use_debug_break_level = -1,
    window_count          = -1,
    lua_arg0              = -1,
  }
}

// ── Main ──
main :: proc() {
  libc.signal(10, bt_handler)  // SIGUSR1 -> backtrace to stderr
  mem.tracking_allocator_init(&_memory.track, context.allocator)
  context.allocator = mem.tracking_allocator(&_memory.track)

  alloc_err := virtual.arena_init_growing(&_memory.arena)
  assert(alloc_err == .None)

  // Capture tracking allocator for C-side xmalloc/xfree overrides
  init_memory()

  atexit(proc "c" () {
    context = runtime.default_context()
    if len(alloc_sizes) > 0 {
      fmt.eprintf("=== %v C allocations not freed: ===\n", len(alloc_sizes))
      for ptr, info in alloc_sizes {
        dlinfo: Dl_info
        if dladdr(info.caller, &dlinfo) != 0 && dlinfo.dli_sname != nil {
          offset := uintptr(info.caller) - uintptr(dlinfo.dli_saddr)
          fmt.eprintf("- %v bytes @ %p (caller %s+%#x in %s)\n", info.size, ptr, dlinfo.dli_sname, offset, dlinfo.dli_fname)
        } else if dladdr(info.caller, &dlinfo) != 0 && dlinfo.dli_fname != nil {
          base_offset := uintptr(info.caller) - uintptr(dlinfo.dli_fbase)
          fmt.eprintf("- %v bytes @ %p (caller %p, offset +%#x in %s)\n", info.size, ptr, info.caller, base_offset, dlinfo.dli_fname)
        } else {
          fmt.eprintf("- %v bytes @ %p (caller %p)\n", info.size, ptr, info.caller)
        }
      }
    }
    n_odin_leaks := len(_memory.track.allocation_map)
    if n_odin_leaks > 0 {
      fmt.eprintf("=== %v Odin allocations not freed: ===\n", n_odin_leaks)
      for ptr, entry in _memory.track.allocation_map {
        fmt.eprintf("- %v bytes @ %p (%v:%v)\n", entry.size, ptr, entry.location.file_path, entry.location.line)
      }
    }
    if len(_memory.track.bad_free_array) > 0 {
      fmt.eprintf("=== %v incorrect frees: ===\n", len(_memory.track.bad_free_array))
      for entry in _memory.track.bad_free_array {
        fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
      }
    }
    mem.tracking_allocator_destroy(&_memory.track)
    virtual.arena_destroy(&_memory.arena)
    fmt.println("Done!!")
  })

  allocator := virtual.arena_allocator(&_memory.arena)
  args := os.args
  c_args := make([^]cstring, len(args), allocator)
  // NOTE: c_args allocations are leaked intentionally — normal_enter never returns.

  for a, i in args {
    c_args[i] = strings.clone_to_cstring(a, allocator)
  }
  argc := c.int(len(args))

  // ── Step 1: appname_is_valid() ──
  if !appname_is_valid() {
    fmt.eprintln("$NVIM_APPNAME must be a name or relative path.")
    os_exit(1)
  }

  // ── Step 2: init_params, init_startuptime ──
  params: Mparm
  init_params(&params, argc, c_args)
  init_startuptime(&params)

  // ── Step 3: --clean scan (inline, ported to Odin) ──
  for i in 1 ..< int(params.argc) {
    arg := string(params.argv[i])
    if arg == "--clean" {
      params.clean = true
      break
    }
  }

  // ── Step 4: event_init ──
  event_init()

  // ── Step 5: early_init (broken apart from C's monolithic function) ──
  os_hint_priority()
  estack_init()
  // cmdline_init not needed — C globals are zero-initialized by the C runtime
  eval_init()
  set_vim_var_nr(VV_STARTTIME, os_realtime())
  init_path(c_args[0]) // Odin version replaces C's init_path(argv0)
  init_normal_cmds()
  runtime_init()
  highlight_init()
  time_msg("early init", nil)

  init_locale()
  set_init_tablocal()
  win_alloc_first()
  time_msg("init first window", nil)

  startup_alist_init()
  init_homedir()
  set_init_1(params.clean)
  log_init()
  time_msg("inits 1", nil)

  set_lang_var()
  qf_init_stack()

  // ── Step 6-9: set_argv_var, check_isatty, command_line_scan, set_argf_var ──
  set_argv_var(c_args, argc)
  check_and_set_isatty(&params)
  command_line_scan(&params)
  set_argf_var()

  // ── Step 10: nlua_init ──
  nlua_init(c_args, argc, params.lua_arg0)

  // ── Step 11: inline — embedded_mode channel_from_stdio ──
  // (MSWIN startup_stderr_fd save omitted — Linux only)
  if embedded_mode {
    startup_channel_from_stdio()
  }

  // ── Step 12: get_fname ──
  fname: cstring = nil
  if startup_gargcount() > 0 {
    fname = get_fname(&params)
  }

  // ── Step 13: TUI client detection and startup ──
  if recoverymode && fname == nil {
    headless_mode = true
  }

  has_term := stdin_isatty || stdout_isatty || stderr_isatty
  use_builtin_ui := has_term && !headless_mode && !embedded_mode && !silent_mode

  if params.remote != 0 {
    remote_request(&params, params.remote, params.server_addr, argc, c_args, use_builtin_ui)
  }

  remote_ui := ui_client_channel_id != 0

  // Start the built-in TUI client (forks a child process)
  if use_builtin_ui && !remote_ui {
    ui_client_forward_stdin = !stdin_isatty
    rv := ui_client_start_server(get_vim_var_str(VV_PROGPATH), c.size_t(params.argc), params.argv)
    if rv == 0 {
      fmt.eprintln("Failed to start Nvim server!")
      os_exit(1)
    }
    ui_client_channel_id = rv
  }

  if ui_client_channel_id != 0 {
    ui_client_run() // NORETURN — never returns
  }

  // ── Step 14: server_init ──
  if !server_init(params.listen_addr) {
    fmt.eprintf("Failed to listen: %s\n", params.listen_addr)
    os_exit(1)
  }

  // ── Step 15: diff mode / window options ──
  if params.diff_mode != 0 && params.window_count == -1 {
    params.window_count = 0
  }

  RedrawingDisabled += 1
  startup_setbuf_stdout_null()
  full_screen = !silent_mode

  // ── Step 16: win_init_size ──
  win_init_size()
  if params.diff_mode != 0 {
    diff_win_options(firstwin, false)
  }

  // ── Step 17: screen setup ──
  cmdline_row = Rows - c.int(p_ch)
  msg_row = cmdline_row
  default_grid_alloc()
  set_init_2(headless_mode)

  msg_scroll = true
  no_wait_return = true
  init_highlight(true, false)
  ui_comp_syn_init()

  debug_break_level = params.use_debug_break_level

  // ── Step 18: input_start for -es mode ──
  if !stdin_isatty && !params.input_istext && silent_mode && exmode_active {
    input_start()
  }

  // ── Step 19: remote UI wait (embedded mode) ──
  use_remote_ui := embedded_mode && !headless_mode
  if use_remote_ui {
    remote_ui_wait_for_attach()
    startup_save_firstwin_height()
  }

  // ── Step 20: screen init ──
  starting = NO_BUFFERS
  screenclear()
  win_new_screensize()

  // ── Step 21: edit_stdin ──
  if edit_stdin(&params) {
    params.edit_type = c.int(EditType.EDIT_STDIN)
  }

  // ── Step 22: scriptin / scriptout ──
  if params.scriptin != nil {
    if !open_scriptin(params.scriptin) {
      os_exit(2)
    }
  }
  if params.scriptout != nil {
    mode: cstring = "wb"
    if params.scriptout_append {
      mode = "ab"
    }
    scriptout = os_fopen(params.scriptout, mode)
    if scriptout == nil {
      fmt.eprintf("Cannot open for script output: \"%s\"\n", params.scriptout)
      os_exit(2)
    }
  }

  // ── Step 23: nlua_init_defaults ──
  nlua_init_defaults()

  // ── Step 24: vimrc_none, exe_pre_commands ──
  vimrc_none := params.use_vimrc != nil && string(params.use_vimrc) == "NONE"
  if vimrc_none {
    p_lpl = params.clean ? 1 : 0
  }

  exe_pre_commands(&params)

  if !vimrc_none || params.clean {
    filetype_plugin_enable()
  }

  // ── Step 25: source_startup_scripts ──
  source_startup_scripts(&params)

  if !vimrc_none || params.clean {
    filetype_maybe_enable()
    syn_maybe_enable()
  }

  // ── Step 26: set VV_VIM_DID_INIT, load_plugins ──
  set_vim_var_nr(VV_VIM_DID_INIT, 1)
  load_plugins()

  // ── Step 27: set_window_layout ──
  set_window_layout(&params)

  // ── Step 28: recovery mode listing ──
  if recoverymode && fname == nil {
    startup_recovery_list_swaps() // never returns
  }

  // ── Step 29: set_init_3, ShaDa ──
  set_init_3()

  if params.no_swap_file != 0 {
    p_uc = 0
  }
  if silent_mode {
    p_ut = 1
  }

  if startup_shada_nonempty() {
    shada_read_everything(nil, false, true)
  }
  if get_vim_var_list(VV_OLDFILES) == nil {
    set_vim_var_list(VV_OLDFILES, tv_list_alloc(0))
  }

  // ── Step 30: handle_quickfix ──
  handle_quickfix(&params)

  // ── Step 31: prepare screen ──
  starting = NO_BUFFERS
  no_wait_return = false
  if !exmode_active {
    msg_scroll = false
  }

  if params.edit_type == c.int(EditType.EDIT_STDIN) && !recoverymode {
    read_stdin()
  }

  setmouse()
  redraw_later(curwin, 10) // UPD_VALID = 10
  no_wait_return = true

  // ── Step 32: create_windows ──
  create_windows(&params)
  set_vim_var_string(VV_SWAPCOMMAND, nil, -1)

  if exmode_active {
    startup_set_cursor_last_line()
  }

  _ = apply_autocmds(EVENT_BUFENTER, nil, nil, false, curbuf)
  setpcmark()

  if params.edit_type == c.int(EditType.EDIT_QF) {
    qf_jump(nil, 0, 0, false)
  }

  // ── Step 33: edit_buffers, diff, shorten, tag ──
  edit_buffers(&params)

  if params.diff_mode != 0 {
    startup_diff_win_options_all()
  }

  shorten_fnames(false)
  handle_tag(params.tagname)

  if params.n_commands > 0 {
    exe_commands(&params)
  }

  // ── Step 34: enter normal mode ──
  starting = 0
  RedrawingDisabled = 0
  redraw_all_later(UPD_NOT_VALID)
  no_wait_return = false
  do_autochdir()
  set_vim_var_nr(VV_VIM_DID_ENTER, 1)
  _ = apply_autocmds(EVENT_VIMENTER, nil, nil, false, curbuf)
  if use_remote_ui {
    do_autocmd_uienter_all()
  }
  set_reg_var(get_default_register_name())
  startup_diff_scrollbind_check()
  startup_restart_edit_check()
  startup_cb_flags_check()
  startup_exec_luaf(params.luaf)

  normal_enter(false) // never returns
}

// ── C function declarations for filetype/syntax enable ──
@(link_prefix = "", default_calling_convention = "c")
foreign nvim {
  filetype_plugin_enable :: proc() ---
  filetype_maybe_enable :: proc() ---
  syn_maybe_enable :: proc() ---
}
