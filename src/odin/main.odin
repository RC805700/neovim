package main

import "core:os"
import "core:fmt"
import "core:c"
import "core:strings"
import "core:terminal"

foreign import nvim "../../build/lib/libnvim.a"

// ── Foreign globals (C extern variables) ──
// NOTE: No `---` suffix for variable declarations.
@(link_prefix="")
foreign nvim {
    headless_mode:        bool
    stdin_isatty:         bool
    stdout_isatty:        bool
    stderr_isatty:        bool
    embedded_mode:        bool
    silent_mode:          bool
    recoverymode:         bool
    exmode_active:        bool
    ui_client_channel_id: u64
    ui_client_forward_stdin: bool
    RedrawingDisabled:    c.int
    full_screen:          bool
    cmdline_row:          c.int
    msg_row:              c.int
    Rows:                 c.int
    Columns:              c.int
    msg_scroll:           bool
    no_wait_return:       bool
    debug_break_level:    c.int
    starting:             c.int
    scriptout:            rawptr
    firstwin:             rawptr
    curwin:               rawptr
    curbuf:               rawptr
    curtab:               rawptr
    stdin_fd:             c.int
    p_ch:                 c.long
    p_uc:                 c.long
    p_ut:                 c.long
    p_lpl:                c.int
    p_shada:              cstring
}

// ── Foreign functions ──
@(link_prefix="", default_calling_convention="c")
foreign nvim {
    // Startup sequence
    init_path            :: proc(exename: cstring) ---
    init_params          :: proc(paramp: ^Mparm, argc: c.int, argv: [^]cstring) ---
    event_init           :: proc() ---
    early_init           :: proc(paramp: ^Mparm) ---
    set_argv_var         :: proc(argv: [^]cstring, argc: c.int) ---
    command_line_scan    :: proc(parmp: ^Mparm) ---
    set_argf_var         :: proc() ---
    nlua_init            :: proc(argv: [^]cstring, argc: c.int, lua_arg0: c.int) ---
    server_init          :: proc(listen_addr: cstring) -> bool ---
    win_init_size        :: proc() ---
    default_grid_alloc   :: proc() ---
    set_init_2           :: proc(headless: bool) ---
    init_highlight       :: proc(load_defaults: bool, reinit: bool) ---
    ui_comp_syn_init     :: proc() ---
    screenclear          :: proc() ---
    win_new_screensize   :: proc() ---
    nlua_init_defaults   :: proc() ---
    exe_pre_commands     :: proc(parmp: ^Mparm) ---
    source_startup_scripts :: proc(parmp: ^Mparm) ---
    load_plugins         :: proc() ---
    set_init_3           :: proc() ---
    shada_read_everything :: proc(fname: cstring, forced: bool, mfp: bool) ---
    create_windows       :: proc(parmp: ^Mparm) ---
    edit_buffers         :: proc(parmp: ^Mparm) ---
    exe_commands         :: proc(parmp: ^Mparm) ---
    normal_enter         :: proc(noexmode: bool) ---

    // Mid-startup helpers
    remote_request       :: proc(params: ^Mparm, remote_args: c.int, server_addr: cstring, argc: c.int, argv: [^]cstring, ui_only: bool) ---
    ui_client_start_server :: proc(progpath: cstring, argc: c.size_t, argv: [^]cstring) -> u64 ---
    ui_client_run        :: proc() ---
    remote_ui_wait_for_attach :: proc() ---
    input_start          :: proc() ---
    edit_stdin           :: proc(parmp: ^Mparm) -> bool ---
    open_scriptin        :: proc(fname: cstring) -> bool ---
    os_fopen             :: proc(path: cstring, mode: cstring) -> rawptr ---
    get_fname            :: proc(parmp: ^Mparm) -> cstring ---
    set_window_layout    :: proc(paramp: ^Mparm) ---
    handle_quickfix      :: proc(paramp: ^Mparm) ---
    handle_tag           :: proc(tagname: cstring) ---
    read_stdin           :: proc() ---
    diff_win_options     :: proc(win: rawptr, startup: bool) ---
    shorten_fnames       :: proc(force: bool) ---
    setmouse             :: proc() ---
    redraw_later         :: proc(win: rawptr, type_: c.int) ---
    setpcmark            :: proc() ---
    qf_jump              :: proc(eap: rawptr, forceit: c.int, errornr: c.int, FILE_IT: bool) ---
    apply_autocmds       :: proc(event: c.int, fname: cstring, fname2: cstring, group: bool, buf: rawptr) ---

    // Vim variable access
    set_vim_var_nr       :: proc(idx: c.int, val: i64) ---
    set_vim_var_string   :: proc(idx: c.int, val: cstring, len: c.int) ---
    get_vim_var_str      :: proc(idx: c.int) -> cstring ---
    get_vim_var_list     :: proc(idx: c.int) -> rawptr ---
    set_vim_var_list     :: proc(idx: c.int, val: rawptr) ---
    tv_list_alloc        :: proc(n: c.int) -> rawptr ---

    // Startup helpers
    do_autochdir           :: proc() ---
    do_autocmd_uienter_all :: proc() ---
    set_reg_var            :: proc(c: c.int) ---
    get_default_register_name :: proc() -> c.int ---
    redraw_all_later       :: proc(type_: c.int) ---

    // Exit
    os_exit              :: proc(r: c.int) ---

    // Wrappers added for Odin
    startup_gargcount               :: proc() -> c.int ---
    startup_set_cursor_last_line    :: proc() ---
    startup_save_firstwin_height    :: proc() ---
    startup_shada_nonempty          :: proc() -> bool ---
    startup_channel_from_stdio      :: proc() ---
    startup_diff_win_options_all    :: proc() ---
    startup_recovery_list_swaps     :: proc() ---
    startup_setbuf_stdout_null      :: proc() ---
    startup_restart_edit_check      :: proc() ---
    startup_cb_flags_check          :: proc() ---
    startup_diff_scrollbind_check   :: proc() ---
    startup_exec_luaf               :: proc(luaf: cstring) ---

    // Startup timing (--startuptime)
    time_init       :: proc(fname: cstring, proc_name: cstring) ---
    time_start      :: proc(message: cstring) ---
    time_msg        :: proc(message: cstring, start: rawptr) ---
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

// VimVarIndex values (from eval_defs.h)
VV_SWAPCOMMAND :: 49
VV_OLDFILES    :: 58
VV_PROGPATH    :: 60
VV_VIM_DID_INIT :: 94
VV_VIM_DID_ENTER :: 75
VV_STARTTIME   :: 104

// Redraw priority values (from drawscreen.h)
UPD_NOT_VALID :: 40

// event_T values (from auevents_enum.generated.h)
EVENT_BUFENTER :: 3
EVENT_VIMENTER :: 136

// ── mparm_T mirror struct ──
MAX_ARG_CMDS :: 10

Mparm :: struct {
    argc:              c.int,
    argv:              [^]cstring,
    use_vimrc:         cstring,
    clean:             bool,
    n_commands:        c.int,
    commands:          [MAX_ARG_CMDS]cstring,
    cmds_tofree:       [MAX_ARG_CMDS]i8,
    n_pre_commands:    c.int,
    pre_commands:      [MAX_ARG_CMDS]cstring,
    luaf:              cstring,
    lua_arg0:          c.int,
    edit_type:         c.int,
    tagname:           cstring,
    use_ef:            cstring,
    input_istext:      bool,
    no_swap_file:      c.int,
    use_debug_break_level: c.int,
    window_count:      c.int,
    window_layout:     c.int,
    diff_mode:         c.int,
    listen_addr:       cstring,
    remote:            c.int,
    server_addr:       cstring,
    scriptin:          cstring,
    scriptout:         cstring,
    scriptout_append:  bool,
    had_stdin_file:    bool,
}

// ── Ported startup functions ──

/// Reads $NVIM_APPNAME (defaults to "nvim") and validates it.
/// Must be a relative name or path — not absolute, not ".", "..", "/", "\\",
/// and must not contain parent-directory traversal segments.
appname_is_valid :: proc() -> bool {
    buf: [256]u8
    appname := os.get_env(buf[:], "NVIM_APPNAME")
    if appname == "" {
        appname = "nvim"
    }

    if strings.has_prefix(appname, "/") {
        return false
    }
    if appname == "/" || appname == "\\" {
        return false
    }
    if appname == "." || appname == ".." {
        return false
    }
    if strings.contains(appname, "/..") || strings.contains(appname, "../") {
        return false
    }

    return true
}

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

// ── Main ──
main :: proc() {
    args := os.args
    c_args := make([^]cstring, len(args))
    // NOTE: c_args allocations are leaked intentionally — normal_enter never returns.

    for a, i in args {
        c_args[i] = strings.clone_to_cstring(a)
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
    for i in 1..<int(params.argc) {
        arg := string(params.argv[i])
        if arg == "--clean" {
            params.clean = true
            break
        }
    }

    // ── Step 4: event_init ──
    event_init()

    // ── Step 5: early_init ──
    early_init(&params)

    // ── Step 6-9: set_argv_var, init_path, check_isatty, command_line_scan, set_argf_var ──
    set_argv_var(c_args, argc)
    init_path(c_args[0])
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
        ui_client_run()  // NORETURN — never returns
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
        startup_recovery_list_swaps()  // never returns
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
    redraw_later(curwin, 10)  // UPD_VALID = 10
    no_wait_return = true

    // ── Step 32: create_windows ──
    create_windows(&params)
    set_vim_var_string(VV_SWAPCOMMAND, nil, -1)

    if exmode_active {
        startup_set_cursor_last_line()
    }

    apply_autocmds(EVENT_BUFENTER, nil, nil, false, curbuf)
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
    apply_autocmds(EVENT_VIMENTER, nil, nil, false, curbuf)
    if use_remote_ui {
        do_autocmd_uienter_all()
    }
    set_reg_var(get_default_register_name())
    startup_diff_scrollbind_check()
    startup_restart_edit_check()
    startup_cb_flags_check()
    startup_exec_luaf(params.luaf)

    normal_enter(false)  // never returns
}

// ── C function declarations for filetype/syntax enable ──
@(link_prefix="", default_calling_convention="c")
foreign nvim {
    filetype_plugin_enable :: proc() ---
    filetype_maybe_enable  :: proc() ---
    syn_maybe_enable       :: proc() ---
}
