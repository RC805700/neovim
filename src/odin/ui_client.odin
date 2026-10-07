package main

import "base:runtime"
import C "core:c"
import "core:c/libc"
import "core:sys/linux"

// —— ui_client.c port (Batch U1: mirrors + lifecycle) ——

foreign _ {
	@(link_name = "tui_start")
	tui_start_e :: proc "c" (tui: ^rawptr, width: ^C.int, height: ^C.int, term: ^cstring, rgb: ^bool) ---
	@(link_name = "tui_stop")
	tui_stop_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_is_stopped")
	tui_is_stopped_e :: proc "c" (tui: rawptr) -> bool ---
	@(link_name = "tui_grid_resize")
	tui_grid_resize_e :: proc "c" (tui: rawptr, g: C.longlong, width: C.longlong, height: C.longlong) ---
	@(link_name = "tui_raw_line")
	tui_raw_line_e :: proc "c" (tui: rawptr, g: C.longlong, linerow: C.longlong, startcol: C.longlong, endcol: C.longlong, clearcol: C.longlong, clearattr: C.longlong, flags: C.int, chunk: ^u32, attrs: ^i32) ---
	@(link_name = "dict2hlattrs")
	dict2hlattrs_e :: proc "c" (dict: rawptr, use_rgb: bool, link_id: ^C.int, base: rawptr, err: ^Api_Error) -> HlAttrs ---
	@(link_name = "tui_add_url")
	tui_add_url_e :: proc "c" (tui: rawptr, url: cstring) -> i32 ---
	@(link_name = "tui_mode_info_set")
	tui_mode_info_set_e :: proc "c" (tui: rawptr, guicursor_enabled: bool, args: Api_Array) ---
	@(link_name = "tui_update_menu")
	tui_update_menu_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_busy_start")
	tui_busy_start_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_busy_stop")
	tui_busy_stop_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_mouse_on")
	tui_mouse_on_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_mouse_off")
	tui_mouse_off_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_mode_change")
	tui_mode_change_e :: proc "c" (tui: rawptr, mode: NvimString, mode_idx: C.longlong) ---
	@(link_name = "tui_bell")
	tui_bell_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_visual_bell")
	tui_visual_bell_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_flush")
	tui_flush_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_suspend")
	tui_suspend_e :: proc "c" (tui: rawptr) ---
	@(link_name = "tui_set_title")
	tui_set_title_e :: proc "c" (tui: rawptr, title: NvimString) ---
	@(link_name = "tui_set_icon")
	tui_set_icon_e :: proc "c" (tui: rawptr, icon: NvimString) ---
	@(link_name = "tui_screenshot")
	tui_screenshot_e :: proc "c" (tui: rawptr, path: NvimString) ---
	@(link_name = "tui_option_set")
	tui_option_set_e :: proc "c" (tui: rawptr, name: NvimString, value: Api_Object) ---
	@(link_name = "tui_chdir")
	tui_chdir_e :: proc "c" (tui: rawptr, path: NvimString) ---
	@(link_name = "tui_ui_send")
	tui_ui_send_e :: proc "c" (tui: rawptr, content: NvimString) ---
	@(link_name = "tui_default_colors_set")
	tui_default_colors_set_e :: proc "c" (tui: rawptr, rgb_fg: C.longlong, rgb_bg: C.longlong, rgb_sp: C.longlong, cterm_fg: C.longlong, cterm_bg: C.longlong) ---
	@(link_name = "tui_hl_attr_define")
	tui_hl_attr_define_e :: proc "c" (tui: rawptr, id: C.longlong, attrs: HlAttrs, cterm_attrs: HlAttrs, info: Api_Array) ---
	@(link_name = "tui_grid_clear")
	tui_grid_clear_e :: proc "c" (tui: rawptr, g: C.longlong) ---
	@(link_name = "tui_grid_cursor_goto")
	tui_grid_cursor_goto_e :: proc "c" (tui: rawptr, grid: C.longlong, row: C.longlong, col: C.longlong) ---
	@(link_name = "tui_grid_scroll")
	tui_grid_scroll_e :: proc "c" (tui: rawptr, g: C.longlong, startrow: C.longlong, endrow: C.longlong, startcol: C.longlong, endcol: C.longlong, rows: C.longlong, cols: C.longlong) ---
	@(link_name = "api_dict_to_keydict")
	api_dict_to_keydict_e :: proc "c" (retval: rawptr, hashy: proc "c" (str: cstring, len: C.size_t) -> rawptr, dict: Api_Dict, err: ^Api_Error) -> bool ---
	@(link_name = "KeyDict_highlight_get_field")
	keydict_highlight_get_field_e :: proc "c" (str: cstring, len: C.size_t) -> rawptr ---
	@(link_name = "api_metadata")
	api_metadata_e :: proc "c" () -> Api_Object ---
	@(link_name = "ui_client_attached")
	ui_client_attached_g: bool
	@(link_name = "ui_client_error_exit")
	ui_client_error_exit_g: C.int
	grid_line_buf_size: C.size_t
	grid_line_buf_char: ^u32
	grid_line_buf_attr: ^i32
}

// KeyDict_highlight mirror (cc-probed: sizeof 384, link@312/blend@336/
// url@352/font@368/cterm@32/fg@56/fallback@328).
KeyDict_Highlight_O :: struct {
	is_set:      u64,
	altfont:     bool,
	blink:       bool,
	bold:        bool,
	conceal:     bool,
	dim:         bool,
	italic:      bool,
	nocombine:   bool,
	overline:    bool,
	reverse:     bool,
	standout:    bool,
	strikethrough: bool,
	undercurl:   bool,
	underdashed: bool,
	underdotted: bool,
	underdouble: bool,
	underline:   bool,
	default_:    bool,
	cterm:       Api_Dict,
	foreground:  Api_Object,
	fg:          Api_Object,
	background:  Api_Object,
	bg:          Api_Object,
	ctermfg:     Api_Object,
	ctermbg:     Api_Object,
	special:     Api_Object,
	sp:          Api_Object,
	link:        C.longlong,
	link_global: C.longlong,
	fallback:    bool,
	_pad329:     [7]u8,
	blend:       C.longlong,
	fg_indexed:  bool,
	bg_indexed:  bool,
	force:       bool,
	update:      bool,
	_pad348:     [4]u8,
	url:         NvimString,
	font:        NvimString,
}
#assert(size_of(KeyDict_Highlight_O) == 384)

// GridLineEvent mirror (grid_defs.h; cc-probed 36B).
GridLineEvent_O :: struct {
	args:        [3]C.int,
	icell:       C.int,
	ncells:      C.int,
	coloff:      C.int,
	cur_attr:    C.int,
	clear_width: C.int,
	wrap:        bool,
	_pad:        [3]u8,
}
#assert(size_of(GridLineEvent_O) == 36)

// UIClientHandler mirror (ui_defs.h; cc-probed 16B).
UIClientHandler_O :: struct {
	name: cstring,
	fn:   rawptr,
}
#assert(size_of(UIClientHandler_O) == 16)

UI_CLIENT_STDIN_FD_O :: 3
KOBJTYPE_DICT_O :: 6

// File-static state (single copies; only this file touches them).
@(private = "file")
tui_g: rawptr = nil
@(private = "file")
tui_width_g: C.int = 0
@(private = "file")
tui_height_g: C.int = 0
@(private = "file")
tui_term_g: cstring = ""
@(private = "file")
tui_rgb_g: bool = false

win_obj_uc_o :: proc "c" (h: C.int) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 9}
	(^C.longlong)(uintptr(&obj) + 8)^ = C.longlong(h)
	return obj
}

buf_obj_uc_o :: proc "c" (h: C.int) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 8}
	(^C.longlong)(uintptr(&obj) + 8)^ = C.longlong(h)
	return obj
}

dict_obj_uc_o :: proc "c" (d: Api_Dict) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 6}
	(^Api_Dict)(&obj.data[0])^ = d
	return obj
}

cstr_obj_uc_o :: proc "c" (s: cstring) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 4}
	(^NvimString)(&obj.data[0])^ = NvimString{data = s, size = libc.strlen(s)}
	return obj
}

cb_reader_init_o :: proc "c" () -> CallbackReader_E {
	context = runtime.default_context()
	r := CallbackReader_E{}
	r.ga_growsize = 1 // GA_EMPTY_INIT_VALUE growsize
	return r
}

@(export)
ui_client_start_server :: proc "c" (exepath: cstring, argc: C.size_t, argv: [^]cstring) -> u64 {
	context = runtime.default_context()
	args := (^rawptr)(xmalloc(C.size_t((2 + i64(argc)) * 8)))
	args_idx: C.size_t = 0
	([^]rawptr)(args)[args_idx] = rawptr(xstrdup(transmute(^u8)(argv[0])))
	args_idx += 1
	([^]rawptr)(args)[args_idx] = rawptr(xstrdup(transmute(^u8)(cstring("--embed"))))
	args_idx += 1
	for i: C.size_t = 1; i < argc; i += 1 {
		([^]rawptr)(args)[args_idx] = rawptr(xstrdup(transmute(^u8)(argv[i])))
		args_idx += 1
	}
	([^]rawptr)(args)[args_idx] = nil

	on_err := cb_reader_init_o()
	on_err.fwd_err = true

	detach := true
	exit_status: C.longlong = 0
	channel := channel_job_start(rawptr(args), exepath, cb_reader_init_o(), on_err, Callback_E{}, false, true, true, detach, KCHSTDIN_PIPE_O, nil, 0, 0, nil, rawptr(&exit_status))
	if channel == nil {
		return 0
	}

	// If stdin is not a pty, it is forwarded to the client.
	// Replace stdin in the TUI process with the tty fd.
	if ui_client_forward_stdin {
		linux.close(linux.Fd(0))
		if stderr_isatty {
			_, _ = linux.dup(linux.Fd(2))
		} else {
			_, _ = linux.dup(linux.Fd(1))
		}
	}

	return (^Channel_O)(channel).id
}

@(export)
ui_client_attach :: proc "c" (width: C.int, height: C.int, term: cstring, rgb: bool) {
	context = runtime.default_context()
	items: [3]Api_Object
	args := Api_Array{size = 0, capacity = 3, items = &items[0]}
	arr_add_obj_o(&args, int_obj_bu_o(C.longlong(width)))
	arr_add_obj_o(&args, int_obj_bu_o(C.longlong(height)))
	info_items: [9]Key_Value_Pair
	opts := Api_Dict{size = 0, capacity = 9, items = &info_items[0]}
	dict_put_obj_o(&opts, cstring("rgb"), bool_obj_bu_o(rgb))
	dict_put_obj_o(&opts, cstring("ext_linegrid"), bool_obj_bu_o(true))
	dict_put_obj_o(&opts, cstring("ext_termcolors"), bool_obj_bu_o(true))
	if term != nil {
		dict_put_obj_o(&opts, cstring("term_name"), cstr_obj_uc_o(term))
	}
	dict_put_obj_o(&opts, cstring("term_colors"), int_obj_bu_o(C.longlong(t_colors_g)))
	dict_put_obj_o(&opts, cstring("stdin_tty"), bool_obj_bu_o(stdin_isatty))
	dict_put_obj_o(&opts, cstring("stdout_tty"), bool_obj_bu_o(stdout_isatty))
	if ui_client_forward_stdin {
		dict_put_obj_o(&opts, cstring("stdin_fd"), int_obj_bu_o(C.longlong(UI_CLIENT_STDIN_FD_O)))
		ui_client_forward_stdin = false // stdin shouldn't be forwarded again #22292
	}
	arr_add_obj_o(&args, dict_obj_uc_o(opts))

	rpc_send_event_e(ui_client_channel_id, cstring("nvim_ui_attach"), args)
	ui_client_attached_g = true

	time_msg(cstring("nvim_ui_attach"), nil)

	items2: [5]Api_Object
	args2 := Api_Array{size = 0, capacity = 5, items = &items2[0]}
	arr_add_obj_o(&args2, cstr_obj_uc_o(cstring("nvim-tui")))
	m := api_metadata_e()
	version := Api_Dict{}
	if m.t != KOBJTYPE_DICT_O {
		libc.abort()
	}
	d := (^Api_Dict)(&m.data[0])^
	for i: C.size_t = 0; i < d.size; i += 1 {
		k := ([^]Key_Value_Pair)(d.items)[i].key
		if strequal(transmute(cstring)(k.data), cstring("version")) {
			version = (^Api_Dict)(&([^]Key_Value_Pair)(d.items)[i].value.data[0])^
			break
		} else if i + 1 == d.size {
			libc.abort()
		}
	}
	arr_add_obj_o(&args2, dict_obj_uc_o(version))
	arr_add_obj_o(&args2, cstr_obj_uc_o(cstring("ui")))
	// We don't send api_metadata.functions as the "methods" because:
	// 1. it consumes memory.
	// 2. it is unlikely to be useful, since the peer can just call `nvim_get_api`.
	// 3. nvim_set_client_info expects a dict instead of an array.
	arr_add_obj_o(&args2, arr_obj_bu_o(Api_Array{}))
	attr_items: [9]Key_Value_Pair
	info := Api_Dict{size = 0, capacity = 9, items = &attr_items[0]}
	dict_put_obj_o(&info, cstring("website"), cstr_obj_uc_o(cstring("https://neovim.io")))
	dict_put_obj_o(&info, cstring("license"), cstr_obj_uc_o(cstring("Apache 2")))
	dict_put_obj_o(&info, cstring("pid"), int_obj_bu_o(C.longlong(os_get_pid())))
	arr_add_obj_o(&args2, dict_obj_uc_o(info))
	rpc_send_event_e(ui_client_channel_id, cstring("nvim_set_client_info"), args2)

	time_msg(cstring("nvim_set_client_info"), nil)
}

@(export)
ui_client_detach :: proc "c" () {
	context = runtime.default_context()
	rpc_send_event_e(ui_client_channel_id, cstring("nvim_ui_detach"), Api_Array{})
	ui_client_attached_g = false
}

@(export)
ui_client_run :: proc "c" () {
	context = runtime.default_context()
	tui_start_e(&tui_g, &tui_width_g, &tui_height_g, &tui_term_g, &tui_rgb_g)
	ui_client_attach(tui_width_g, tui_height_g, tui_term_g, tui_rgb_g)

	// TODO(justinmk): this is for log_spec. Can remove this after nvim_log #7062 is merged.
	if os_env_exists(cstring("__NVIM_TEST_LOG"), true) {
		logmsg_e(4, nil, cstring("ui_client_run"), 163, true, cstring("test log message"))
	}

	time_finish()

	// os_exit() will be invoked when the client channel detaches
	for {
		// Need to process main_loop.events,
		// otherwise channels closed due to server restart are never freed.
		loop_process_events_q(&main_loop, main_loop.events, i64(-1))
	}
}

@(export)
ui_client_stop :: proc "c" () {
	context = runtime.default_context()
	ui_client_attached_g = false
	if !tui_is_stopped_e(tui_g) {
		tui_stop_e(tui_g)
	}
}

@(export)
ui_client_set_size :: proc "c" (width: C.int, height: C.int) {
	context = runtime.default_context()
	// The currently known size will be sent when attaching
	if ui_client_attached_g {
		items: [2]Api_Object
		args := Api_Array{size = 0, capacity = 2, items = &items[0]}
		arr_add_obj_o(&args, int_obj_bu_o(C.longlong(width)))
		arr_add_obj_o(&args, int_obj_bu_o(C.longlong(height)))
		rpc_send_event_e(ui_client_channel_id, cstring("nvim_ui_try_resize"), args)
	}
	tui_width_g = width
	tui_height_g = height
}

// —— Batch U2: dispatch + restart + grid + hlattr-convert ——
// NOTE: grid_line_buf_size/char/attr are C-owned EXTERN globals
// (ui_client.h, defined in main.c.o); C's unpacker.c reads them
// directly, so the resize handler below must grow the C copies —
// Odin-private shadows would split-brain the parser (flaky exit-1).

@(private = "file")
restart_args_g: Api_Array = Api_Array{}
@(private = "file")
restart_pending_g: bool = false
@(private = "file")
restart_args_after_crash_exit_g: Api_Array = Api_Array{}

@(export)
handle_ui_client_redraw :: proc "c" (channel_id: u64, args: Api_Array, arena: rawptr, err: ^Api_Error) -> Api_Object {
	context = runtime.default_context()
	(^Api_Error)(err).typ = 1
	(^Api_Error)(err).msg = xstrdup(transmute(^u8)(cstring("'redraw' cannot be sent as a request")))
	return Api_Object{t = 0}
}

@(export)
ui_client_event_grid_resize :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 3 {
		logmsg_e(4, nil, cstring("ui_client_event_grid_resize"), 241, true, cstring("Error handling ui event 'grid_resize'"))
		return
	}
	ok := true
	for i: C.size_t = 0; i < 3; i += 1 {
		if ([^]Api_Object)(args.items)[i].t != 2 {
			ok = false
		}
	}
	if !ok {
		logmsg_e(4, nil, cstring("ui_client_event_grid_resize"), 241, true, cstring("Error handling ui event 'grid_resize'"))
		return
	}
	grid := (^C.longlong)(&([^]Api_Object)(args.items)[0].data[0])^
	width := (^C.longlong)(&([^]Api_Object)(args.items)[1].data[0])^
	height := (^C.longlong)(&([^]Api_Object)(args.items)[2].data[0])^
	tui_grid_resize_e(tui_g, grid, width, height)

	if grid_line_buf_size < C.size_t(width) {
		xfree(rawptr(grid_line_buf_char))
		xfree(rawptr(grid_line_buf_attr))
		grid_line_buf_size = C.size_t(width)
		grid_line_buf_char = (^u32)(xmalloc(grid_line_buf_size * 4))
		grid_line_buf_attr = (^i32)(xmalloc(grid_line_buf_size * 4))
	}
}

@(export)
ui_client_event_grid_line :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	libc.abort() // unreachable
}

@(export)
ui_client_event_raw_line :: proc "c" (g: ^GridLineEvent_O) {
	context = runtime.default_context()
	grid := g.args[0]
	row := g.args[1]
	startcol := g.args[2]
	endcol := C.longlong(startcol) + C.longlong(g.coloff)
	clearcol := endcol + C.longlong(g.clear_width)
	lineflags: C.int = 0
	if g.wrap {
		lineflags = 1
	}
	tui_raw_line_e(tui_g, C.longlong(grid), C.longlong(row), C.longlong(startcol), endcol, clearcol, C.longlong(g.cur_attr), lineflags, grid_line_buf_char, grid_line_buf_attr)
}

@(export)
ui_client_event_connect :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_connect"), 283, true, cstring("Error handling UI event 'connect'"))
		return
	}
	s := (^NvimString)(&([^]Api_Object)(args.items)[0].data[0])^
	server_addr := xmemdupz(transmute(^u8)(s.data), s.size)
	multiqueue_put_event(main_loop.fast_events, event_create(channel_connect_event_o, rawptr(server_addr)))
	// Set a dummy channel ID to prevent client exit when server detaches.
	ui_client_channel_id = max(u64)
}

channel_connect_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	server_addr := transmute(cstring)(([^]rawptr)(argv)[0])
	is_tcp := socket_address_tcp_host_end(server_addr) != nil
	on_data := cb_reader_init_o()
	err_msg: cstring = ""
	chan := channel_connect(is_tcp, server_addr, true, on_data, 50, &err_msg)
	if !strequal(err_msg, cstring("")) {
		logmsg_e(4, nil, cstring("channel_connect_event_o"), 303, true, cstring("Cannot connect to server %s: %s"), server_addr, err_msg)
		xfree(rawptr(server_addr))
		ui_client_exit_status = 1
		os_exit(1)
	}
	ui_client_channel_id = chan
	ui_client_attach(tui_width_g, tui_height_g, tui_term_g, tui_rgb_g)
	logmsg_e(2, nil, cstring("channel_connect_event_o"), 312, true, cstring("Connected to server %s on channel %lld"), server_addr, C.longlong(chan))
	xfree(rawptr(server_addr))
}

@(export)
ui_client_event_restart :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	// NB: don't send nvim_ui_detach to server, as it may have already exited.
	// ui_client_detach();
	// Save the arguments for ui_client_attach_to_restarted_server() later.
	api_free_array_e(restart_args_g)
	restart_args_g = copy_array_e(args, nil)
	restart_pending_g = true
}

@(export)
ui_client_event__set_restart_on_crash_exit :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	// Save the arguments for ui_client_may_restart_server() later.
	api_free_array_e(restart_args_after_crash_exit_g)
	restart_args_after_crash_exit_g = copy_array_e(args, nil)
}

@(export)
ui_client_attach_to_restarted_server :: proc "c" (error_restart: bool) {
	context = runtime.default_context()
	args := restart_args_g
	restart := false
	if !restart_pending_g {
		if error_restart && ui_client_error_exit_g == -1 && restart_args_after_crash_exit_g.size > 0 {
			restart = true
			args = restart_args_after_crash_exit_g
		} else {
			return
		}
	}
	restart_pending_g = false
	failed := false
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_attach_to_restarted_server"), 361, true, cstring("Error handling ui event 'restart'"))
		failed = true
	}
	chan_id: u64 = 0
	first_arg: cstring = nil
	if !failed {
		first_arg = (^NvimString)(&([^]Api_Object)(args.items)[0].data[0]).data
		if restart {
			if args.size < 2 || ([^]Api_Object)(args.items)[1].t != 5 {
				logmsg_e(4, nil, cstring("ui_client_attach_to_restarted_server"), 369, true, cstring("Error handling ui event 'restart'"))
				failed = true
			} else {
				cmdargs := (^Api_Array)(&([^]Api_Object)(args.items)[1].data[0])^
				argv := ([^]cstring)(xcalloc(cmdargs.size + 1, 8))
				for i: C.size_t = 0; i < cmdargs.size; i += 1 {
					if ([^]Api_Object)(cmdargs.items)[i].t == 4 {
						argv[i] = (^NvimString)(&([^]Api_Object)(cmdargs.items)[i].data[0]).data
					}
					if argv[i] == nil {
						argv[i] = cstring("")
					}
				}
				chan_id = ui_client_start_server(first_arg, cmdargs.size, argv)
				xfree(argv)
				ui_client_error_exit_g = -1
			}
		} else {
			is_tcp := socket_address_tcp_host_end(first_arg) != nil
			err_msg: cstring = nil
			chan_id = channel_connect(is_tcp, first_arg, true, cb_reader_init_o(), 50, &err_msg)
			if err_msg != nil {
				logmsg_e(4, nil, cstring("ui_client_attach_to_restarted_server"), 390, true, cstring("cannot connect to server %s: %s"), first_arg, err_msg)
				failed = true
			}
		}
	}
	if !failed {
		// Client-side server re-attach.
		ui_client_channel_id = chan_id
		ui_client_attach(tui_width_g, tui_height_g, tui_term_g, tui_rgb_g)
		logmsg_e(2, nil, cstring("ui_client_attach_to_restarted_server"), 399, true, cstring("restarted server address=%s id=%lld"), first_arg, C.longlong(chan_id))
	}
	api_free_array_e(restart_args_g)
	restart_args_g = Api_Array{}
	api_free_array_e(restart_args_after_crash_exit_g)
	restart_args_after_crash_exit_g = Api_Array{}
}

@(export)
ui_client_event_error_exit :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 2 {
		logmsg_e(4, nil, cstring("ui_client_event_error_exit"), 413, true, cstring("Error handling ui event 'error_exit'"))
		return
	}
	ui_client_error_exit_g = C.int((^C.longlong)(&([^]Api_Object)(args.items)[0].data[0])^)
}

ui_client_dict2hlattrs_o :: proc "c" (d: Api_Dict, rgb: bool) -> HlAttrs {
	context = runtime.default_context()
	err := Api_Error{typ = -1, msg = nil}
	dict := KeyDict_Highlight_O{}
	if !api_dict_to_keydict_e(rawptr(&dict), keydict_highlight_get_field_e, d, &err) {
		// TODO(bfredl): log "err"
		return HLATTRS_INIT
	}
	attrs := dict2hlattrs_e(rawptr(&dict), rgb, nil, nil, &err)
	if dict.is_set & (1 << 5) != 0 {
		attrs.url = tui_add_url_e(tui_g, dict.url.data)
	}
	return attrs
}

// —— Batch U3: generated event bodies + dispatch table + hash ——

ev_int_o :: proc "c" (args: Api_Array, i: C.size_t) -> C.longlong {
	context = runtime.default_context()
	return (^C.longlong)(&([^]Api_Object)(args.items)[i].data[0])^
}

ev_str_o :: proc "c" (args: Api_Array, i: C.size_t) -> NvimString {
	context = runtime.default_context()
	return (^NvimString)(&([^]Api_Object)(args.items)[i].data[0])^
}

@(export)
ui_client_event_mode_info_set :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 2 || ([^]Api_Object)(args.items)[0].t != 1 || ([^]Api_Object)(args.items)[1].t != 5 {
		logmsg_e(4, nil, cstring("ui_client_event_mode_info_set"), 1, true, cstring("Error handling ui event 'mode_info_set'"))
		return
	}
	tui_mode_info_set_e(tui_g, (^bool)(&([^]Api_Object)(args.items)[0].data[0])^, (^Api_Array)(&([^]Api_Object)(args.items)[1].data[0])^)
}

@(export)
ui_client_event_update_menu :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_update_menu_e(tui_g)
}

@(export)
ui_client_event_busy_start :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_busy_start_e(tui_g)
}

@(export)
ui_client_event_busy_stop :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_busy_stop_e(tui_g)
}

@(export)
ui_client_event_mouse_on :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_mouse_on_e(tui_g)
}

@(export)
ui_client_event_mouse_off :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_mouse_off_e(tui_g)
}

@(export)
ui_client_event_mode_change :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 2 || ([^]Api_Object)(args.items)[0].t != 4 || ([^]Api_Object)(args.items)[1].t != 2 {
		logmsg_e(4, nil, cstring("ui_client_event_mode_change"), 1, true, cstring("Error handling ui event 'mode_change'"))
		return
	}
	tui_mode_change_e(tui_g, ev_str_o(args, 0), ev_int_o(args, 1))
}

@(export)
ui_client_event_bell :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_bell_e(tui_g)
}

@(export)
ui_client_event_visual_bell :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_visual_bell_e(tui_g)
}

@(export)
ui_client_event_flush :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_flush_e(tui_g)
}

@(export)
ui_client_event_suspend :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	tui_suspend_e(tui_g)
}

@(export)
ui_client_event_set_title :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_set_title"), 1, true, cstring("Error handling ui event 'set_title'"))
		return
	}
	tui_set_title_e(tui_g, ev_str_o(args, 0))
}

@(export)
ui_client_event_set_icon :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_set_icon"), 1, true, cstring("Error handling ui event 'set_icon'"))
		return
	}
	tui_set_icon_e(tui_g, ev_str_o(args, 0))
}

@(export)
ui_client_event_screenshot :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_screenshot"), 1, true, cstring("Error handling ui event 'screenshot'"))
		return
	}
	tui_screenshot_e(tui_g, ev_str_o(args, 0))
}

@(export)
ui_client_event_option_set :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 2 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_option_set"), 1, true, cstring("Error handling ui event 'option_set'"))
		return
	}
	tui_option_set_e(tui_g, ev_str_o(args, 0), ([^]Api_Object)(args.items)[1])
}

@(export)
ui_client_event_chdir :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_chdir"), 1, true, cstring("Error handling ui event 'chdir'"))
		return
	}
	tui_chdir_e(tui_g, ev_str_o(args, 0))
}

@(export)
ui_client_event_ui_send :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 4 {
		logmsg_e(4, nil, cstring("ui_client_event_ui_send"), 1, true, cstring("Error handling ui event 'ui_send'"))
		return
	}
	tui_ui_send_e(tui_g, ev_str_o(args, 0))
}

@(export)
ui_client_event_default_colors_set :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	ok := args.size >= 5
	for i: C.size_t = 0; ok && i < 5; i += 1 {
		if ([^]Api_Object)(args.items)[i].t != 2 {
			ok = false
		}
	}
	if !ok {
		logmsg_e(4, nil, cstring("ui_client_event_default_colors_set"), 1, true, cstring("Error handling ui event 'default_colors_set'"))
		return
	}
	tui_default_colors_set_e(tui_g, ev_int_o(args, 0), ev_int_o(args, 1), ev_int_o(args, 2), ev_int_o(args, 3), ev_int_o(args, 4))
}

@(export)
ui_client_event_hl_attr_define :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 4 || ([^]Api_Object)(args.items)[0].t != 2 || ([^]Api_Object)(args.items)[1].t != 6 || ([^]Api_Object)(args.items)[2].t != 6 || ([^]Api_Object)(args.items)[3].t != 5 {
		logmsg_e(4, nil, cstring("ui_client_event_hl_attr_define"), 1, true, cstring("Error handling ui event 'hl_attr_define'"))
		return
	}
	tui_hl_attr_define_e(tui_g, ev_int_o(args, 0), ui_client_dict2hlattrs_o((^Api_Dict)(&([^]Api_Object)(args.items)[1].data[0])^, true), ui_client_dict2hlattrs_o((^Api_Dict)(&([^]Api_Object)(args.items)[2].data[0])^, false), (^Api_Array)(&([^]Api_Object)(args.items)[3].data[0])^)
}

@(export)
ui_client_event_grid_clear :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	if args.size < 1 || ([^]Api_Object)(args.items)[0].t != 2 {
		logmsg_e(4, nil, cstring("ui_client_event_grid_clear"), 1, true, cstring("Error handling ui event 'grid_clear'"))
		return
	}
	tui_grid_clear_e(tui_g, ev_int_o(args, 0))
}

@(export)
ui_client_event_grid_cursor_goto :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	ok := args.size >= 3
	for i: C.size_t = 0; ok && i < 3; i += 1 {
		if ([^]Api_Object)(args.items)[i].t != 2 {
			ok = false
		}
	}
	if !ok {
		logmsg_e(4, nil, cstring("ui_client_event_grid_cursor_goto"), 1, true, cstring("Error handling ui event 'grid_cursor_goto'"))
		return
	}
	tui_grid_cursor_goto_e(tui_g, ev_int_o(args, 0), ev_int_o(args, 1), ev_int_o(args, 2))
}

@(export)
ui_client_event_grid_scroll :: proc "c" (args: Api_Array) {
	context = runtime.default_context()
	ok := args.size >= 7
	for i: C.size_t = 0; ok && i < 7; i += 1 {
		if ([^]Api_Object)(args.items)[i].t != 2 {
			ok = false
		}
	}
	if !ok {
		logmsg_e(4, nil, cstring("ui_client_event_grid_scroll"), 1, true, cstring("Error handling ui event 'grid_scroll'"))
		return
	}
	tui_grid_scroll_e(tui_g, ev_int_o(args, 0), ev_int_o(args, 1), ev_int_o(args, 2), ev_int_o(args, 3), ev_int_o(args, 4), ev_int_o(args, 5), ev_int_o(args, 6))
}

// Dispatch table + perfect hash (transcribed from
// build/src/nvim/auto/ui_events_client.generated.h; order is load-bearing).
@(private = "file")
uc_handlers_g: [28]UIClientHandler_O
@(private = "file")
uc_handlers_ready_g: bool = false

uc_handlers_init_o :: proc "c" () {
	context = runtime.default_context()
	uc_handlers_g[0] = UIClientHandler_O{cstring("bell"), transmute(rawptr)(ui_client_event_bell)}
	uc_handlers_g[1] = UIClientHandler_O{cstring("chdir"), transmute(rawptr)(ui_client_event_chdir)}
	uc_handlers_g[2] = UIClientHandler_O{cstring("flush"), transmute(rawptr)(ui_client_event_flush)}
	uc_handlers_g[3] = UIClientHandler_O{cstring("connect"), transmute(rawptr)(ui_client_event_connect)}
	uc_handlers_g[4] = UIClientHandler_O{cstring("restart"), transmute(rawptr)(ui_client_event_restart)}
	uc_handlers_g[5] = UIClientHandler_O{cstring("suspend"), transmute(rawptr)(ui_client_event_suspend)}
	uc_handlers_g[6] = UIClientHandler_O{cstring("ui_send"), transmute(rawptr)(ui_client_event_ui_send)}
	uc_handlers_g[7] = UIClientHandler_O{cstring("mouse_on"), transmute(rawptr)(ui_client_event_mouse_on)}
	uc_handlers_g[8] = UIClientHandler_O{cstring("set_icon"), transmute(rawptr)(ui_client_event_set_icon)}
	uc_handlers_g[9] = UIClientHandler_O{cstring("busy_stop"), transmute(rawptr)(ui_client_event_busy_stop)}
	uc_handlers_g[10] = UIClientHandler_O{cstring("grid_line"), transmute(rawptr)(ui_client_event_grid_line)}
	uc_handlers_g[11] = UIClientHandler_O{cstring("mouse_off"), transmute(rawptr)(ui_client_event_mouse_off)}
	uc_handlers_g[12] = UIClientHandler_O{cstring("set_title"), transmute(rawptr)(ui_client_event_set_title)}
	uc_handlers_g[13] = UIClientHandler_O{cstring("busy_start"), transmute(rawptr)(ui_client_event_busy_start)}
	uc_handlers_g[14] = UIClientHandler_O{cstring("error_exit"), transmute(rawptr)(ui_client_event_error_exit)}
	uc_handlers_g[15] = UIClientHandler_O{cstring("grid_clear"), transmute(rawptr)(ui_client_event_grid_clear)}
	uc_handlers_g[16] = UIClientHandler_O{cstring("option_set"), transmute(rawptr)(ui_client_event_option_set)}
	uc_handlers_g[17] = UIClientHandler_O{cstring("screenshot"), transmute(rawptr)(ui_client_event_screenshot)}
	uc_handlers_g[18] = UIClientHandler_O{cstring("mode_change"), transmute(rawptr)(ui_client_event_mode_change)}
	uc_handlers_g[19] = UIClientHandler_O{cstring("update_menu"), transmute(rawptr)(ui_client_event_update_menu)}
	uc_handlers_g[20] = UIClientHandler_O{cstring("visual_bell"), transmute(rawptr)(ui_client_event_visual_bell)}
	uc_handlers_g[21] = UIClientHandler_O{cstring("grid_resize"), transmute(rawptr)(ui_client_event_grid_resize)}
	uc_handlers_g[22] = UIClientHandler_O{cstring("grid_scroll"), transmute(rawptr)(ui_client_event_grid_scroll)}
	uc_handlers_g[23] = UIClientHandler_O{cstring("mode_info_set"), transmute(rawptr)(ui_client_event_mode_info_set)}
	uc_handlers_g[24] = UIClientHandler_O{cstring("hl_attr_define"), transmute(rawptr)(ui_client_event_hl_attr_define)}
	uc_handlers_g[25] = UIClientHandler_O{cstring("grid_cursor_goto"), transmute(rawptr)(ui_client_event_grid_cursor_goto)}
	uc_handlers_g[26] = UIClientHandler_O{cstring("default_colors_set"), transmute(rawptr)(ui_client_event_default_colors_set)}
	uc_handlers_g[27] = UIClientHandler_O{cstring("_set_restart_on_crash_exit"), transmute(rawptr)(ui_client_event__set_restart_on_crash_exit)}
	uc_handlers_ready_g = true
}

ui_client_handler_hash_o :: proc "c" (str: cstring, len: C.size_t) -> C.int {
	context = runtime.default_context()
	s := ([^]u8)(str)
	low: C.int = -1
	switch len {
	case 4:
		low = 0
	case 5:
		switch s[0] {
		case 'c':
			low = 1
		case 'f':
			low = 2
		}
	case 7:
		switch s[0] {
		case 'c':
			low = 3
		case 'r':
			low = 4
		case 's':
			low = 5
		case 'u':
			low = 6
		}
	case 8:
		switch s[0] {
		case 'm':
			low = 7
		case 's':
			low = 8
		}
	case 9:
		switch s[0] {
		case 'b':
			low = 9
		case 'g':
			low = 10
		case 'm':
			low = 11
		case 's':
			low = 12
		}
	case 10:
		switch s[0] {
		case 'b':
			low = 13
		case 'e':
			low = 14
		case 'g':
			low = 15
		case 'o':
			low = 16
		case 's':
			low = 17
		}
	case 11:
		switch s[5] {
		case 'c':
			low = 18
		case 'e':
			low = 19
		case 'l':
			low = 20
		case 'r':
			low = 21
		case 's':
			low = 22
		}
	case 13:
		low = 23
	case 14:
		low = 24
	case 16:
		low = 25
	case 18:
		low = 26
	case 26:
		low = 27
	}
	if low < 0 || libc.memcmp(rawptr(str), rawptr(uc_handlers_g[low].name), len) != 0 {
		return -1
	}
	return low
}

@(export)
ui_client_get_redraw_handler :: proc "c" (name: cstring, name_len: C.size_t, error: rawptr) -> UIClientHandler_O {
	context = runtime.default_context()
	if !uc_handlers_ready_g {
		uc_handlers_init_o()
	}
	hash := ui_client_handler_hash_o(name, name_len)
	if hash < 0 {
		return UIClientHandler_O{nil, nil}
	}
	return uc_handlers_g[hash]
}
