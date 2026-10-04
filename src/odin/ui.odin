package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// ui.c port: attached-UI list, cursor/mode/mouse state, refresh/flush,
// event-callback registry. Publics are @(export); statics are _o plains.
// ui_call_* dispatchers (generated in ui_events_call.generated.h) are ported
// in Batch U3; remote_ui_*/ui_comp_* stay C (ui_client.c/ui_compositor.c).

foreign _ {
	@(link_name = "remote_ui_mode_info_set")
	remote_ui_mode_info_set_e :: proc "c" (ui: rawptr, enabled: bool, cursor_styles: Api_Array) ---
	@(link_name = "remote_ui_update_menu")
	remote_ui_update_menu_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_busy_start")
	remote_ui_busy_start_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_busy_stop")
	remote_ui_busy_stop_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_mouse_on")
	remote_ui_mouse_on_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_mouse_off")
	remote_ui_mouse_off_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_mode_change")
	remote_ui_mode_change_e :: proc "c" (ui: rawptr, mode: Api_String, mode_idx: i64) ---
	@(link_name = "remote_ui_bell")
	remote_ui_bell_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_visual_bell")
	remote_ui_visual_bell_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_flush")
	remote_ui_flush_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_suspend")
	remote_ui_suspend_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_set_title")
	remote_ui_set_title_e :: proc "c" (ui: rawptr, title: Api_String) ---
	@(link_name = "remote_ui_set_icon")
	remote_ui_set_icon_e :: proc "c" (ui: rawptr, icon: Api_String) ---
	@(link_name = "remote_ui_screenshot")
	remote_ui_screenshot_e :: proc "c" (ui: rawptr, path: Api_String) ---
	@(link_name = "remote_ui_option_set")
	remote_ui_option_set_e :: proc "c" (ui: rawptr, name: Api_String, value: Api_Object) ---
	@(link_name = "remote_ui_chdir")
	remote_ui_chdir_e :: proc "c" (ui: rawptr, path: Api_String) ---
	@(link_name = "remote_ui_stop")
	remote_ui_stop_e :: proc "c" (ui: rawptr) ---
	@(link_name = "remote_ui_ui_send")
	remote_ui_ui_send_e :: proc "c" (ui: rawptr, content: Api_String) ---
	@(link_name = "remote_ui_default_colors_set")
	remote_ui_default_colors_set_e :: proc "c" (ui: rawptr, rgb_fg: i64, rgb_bg: i64, rgb_sp: i64, cterm_fg: i64, cterm_bg: i64) ---
	@(link_name = "remote_ui_hl_attr_define")
	remote_ui_hl_attr_define_e :: proc "c" (ui: rawptr, id: i64, rgb_attrs: HlAttrs, cterm_attrs: HlAttrs, info: Api_Array) ---
	@(link_name = "remote_ui_hl_group_set")
	remote_ui_hl_group_set_e :: proc "c" (ui: rawptr, name: Api_String, id: i64) ---
	@(link_name = "remote_ui_grid_clear")
	remote_ui_grid_clear_e :: proc "c" (ui: rawptr, grid: i64) ---
	@(link_name = "remote_ui_grid_resize")
	remote_ui_grid_resize_e :: proc "c" (ui: rawptr, grid: i64, width: i64, height: i64) ---
	@(link_name = "remote_ui_grid_cursor_goto")
	remote_ui_grid_cursor_goto_e :: proc "c" (ui: rawptr, grid: i64, row: i64, col: i64) ---
	@(link_name = "remote_ui_grid_scroll")
	remote_ui_grid_scroll_e :: proc "c" (ui: rawptr, grid: i64, top: i64, bot: i64, left: i64, right: i64, rows: i64, cols: i64) ---
	@(link_name = "remote_ui_raw_line")
	remote_ui_raw_line_e :: proc "c" (ui: rawptr, grid: i64, row: i64, startcol: i64, endcol: i64, clearcol: i64, clearattr: i64, flags: C.int, chunk: ^u32, attrs: ^C.int32_t) ---
	@(link_name = "remote_ui_win_viewport")
	remote_ui_win_viewport_e :: proc "c" (ui: rawptr, grid: i64, win: i64, topline: i64, botline: i64, curline: i64, curcol: i64, line_count: i64, scroll_delta: i64) ---
	@(link_name = "remote_ui_win_viewport_margins")
	remote_ui_win_viewport_margins_e :: proc "c" (ui: rawptr, grid: i64, win: i64, top: i64, bottom: i64, left: i64, right: i64) ---
	@(link_name = "remote_ui_msg_set_pos")
	remote_ui_msg_set_pos_e :: proc "c" (ui: rawptr, grid: i64, row: i64, scrolled: bool, sep_char: Api_String, zindex: i64, compindex: i64) ---
	@(link_name = "remote_ui_error_exit")
	remote_ui_error_exit_e :: proc "c" (ui: rawptr, status: i64) ---
	@(link_name = "remote_ui__set_restart_on_crash_exit")
	remote_ui__set_restart_on_crash_exit_e :: proc "c" (ui: rawptr, progpath: Api_String, argv: Api_Array) ---
	@(link_name = "remote_ui_event")
	remote_ui_event_e :: proc "c" (ui: rawptr, name: cstring, args: Api_Array) ---
	@(link_name = "ui_comp_init")
	ui_comp_init_e :: proc "c" () ---
	@(link_name = "ui_comp_attach")
	ui_comp_attach_e :: proc "c" (ui: rawptr) ---
	@(link_name = "ui_comp_detach")
	ui_comp_detach_e :: proc "c" (ui: rawptr) ---
	@(link_name = "ui_comp_should_draw")
	ui_comp_should_draw_e :: proc "c" () -> bool ---
	@(link_name = "ui_comp_grid_resize")
	ui_comp_grid_resize_e :: proc "c" (grid: i64, width: i64, height: i64) ---
	@(link_name = "ui_comp_grid_cursor_goto")
	ui_comp_grid_cursor_goto_e :: proc "c" (grid: i64, r: i64, c: i64) ---
	@(link_name = "ui_comp_grid_scroll")
	ui_comp_grid_scroll_e :: proc "c" (grid: i64, top: i64, bot: i64, left: i64, right: i64, rows: i64, cols: i64) ---
	@(link_name = "ui_comp_raw_line")
	ui_comp_raw_line_e :: proc "c" (grid: i64, row: i64, startcol: i64, endcol: i64, clearcol: i64, clearattr: i64, flags: C.int, chunk: ^u32, attrs: ^C.int32_t) ---
	@(link_name = "ui_comp_msg_set_pos")
	ui_comp_msg_set_pos_e :: proc "c" (grid: i64, row: i64, scrolled: bool, sep_char: Api_String, zindex: i64, compindex: i64) ---
	@(link_name = "highlight_use_hlstate")
	highlight_use_hlstate_e :: proc "c" () -> bool ---
	@(link_name = "ui_send_all_hls")
	ui_send_all_hls_e :: proc "c" (ui: rawptr) ---
	@(link_name = "do_autocmd_uienter")
	do_autocmd_uienter_e :: proc "c" (chanid: u64, attached: bool) ---
	@(link_name = "describe_ns")
	describe_ns_e :: proc "c" (ns_id: u32, unknown: cstring) -> cstring ---
	@(link_name = "nlua_call_ref_ctx")
	nlua_call_ref_ctx_e :: proc "c" (fast: bool, ref: C.int, name: cstring, args: Api_Array, mode: C.int, arena: rawptr, err: ^Api_Error) -> Api_Object ---
	@(link_name = "api_err_invalid")
	api_err_invalid_e :: proc "c" (err: ^Api_Error, name: cstring, val_s: cstring, val_n: i64, quote_val: bool) ---
	// msg now defined in message.odin — call directly.
	@(link_name = "msg_schedule_semsg_multiline")
	msg_schedule_semsg_multiline_e :: proc "c" (fmt: cstring, #c_vararg args: ..any) ---
	// msg_ui_refresh now defined in message.odin — call directly.
	@(link_name = "cmdline_ui_flush")
	cmdline_ui_flush_e :: proc "c" () ---
	@(link_name = "p_wd")
	p_wd_g: C.longlong
	@(link_name = "p_vb")
	p_vb_g: C.int
	@(link_name = "p_debug")
	p_debug_g: ^u8
	@(link_name = "bo_flags")
	bo_flags_g: C.uint
	@(link_name = "normal_fg")
	normal_fg_g: C.int
	@(link_name = "normal_sp")
	normal_sp_g: C.int
	@(link_name = "cterm_normal_fg_color")
	cterm_normal_fg_color_g: C.int
	@(link_name = "ui_refresh_cmdheight")
	ui_refresh_cmdheight_g: bool
	@(link_name = "msg_ext_fast")
	msg_ext_fast_g: bool
	@(link_name = "resize_events")
	resize_events_g: ^MultiQueue
	@(link_name = "ui_ext_names")
	ui_ext_names_g: [10]cstring
	@(link_name = "ui_event_ns_id")
	ui_event_ns_id_g: u32
}

MAX_UI_COUNT_O :: 16
KUIEXTCOUNT_O :: 10
KUIGLOBALCOUNT_O :: 5
KUIPOPUPMENU_O :: 1
KUIWILDMENU_O :: 3
KUILINEGRID_O :: 5
KUIHLSTATE_O :: 7
KUITERMCCOLORS_O :: 8
KUIFLOATDEBUG_O :: 9
KOPTBOFLAGALL_O :: 0x01
KOPTRDBFLAGLINE_O :: 0x10
KOPTRDBFLAGFLUSH_O :: 0x20
CB_MAX_ERROR_O :: 3

// RemoteUI header mirror (cc-probed; full struct is 240B).
RemoteUI_O :: struct {
	rgb:          bool,
	override:     bool,
	composed:     bool,
	ui_ext:       [10]bool,
	_pad0:        [3]u8,
	width:        C.int,
	height:       C.int,
	pum_nlines:   C.int,
	pum_pos:      bool,
	_pad1:        [3]u8,
	pum_row:      f64,
	pum_col:      f64,
	pum_height:   f64,
	pum_width:    f64,
	term_name:    rawptr,
	term_background: rawptr,
	term_colors:  C.int,
	stdin_tty:    bool,
	stdout_tty:   bool,
	_pad2:        [2]u8,
	channel_id:   u64,
	_pad3:        [144]u8,
}
#assert(size_of(RemoteUI_O) == 240)

// UIEventCallback mirror (Odin-allocated; no C readers).
UIEventCallback_O :: struct {
	cb:          C.int,
	errors:      u8,
	ext_widgets: [10]bool,
}
#assert(size_of(UIEventCallback_O) == 16)

// Moved file-statics (single copy; no C readers outside ui.c).
uis_g: [16]rawptr
ui_ext_g: [10]bool
ui_cb_ext_g: [10]bool
ui_count_g: C.size_t
ui_mode_idx_g: C.int = 0
cursor_row_g: C.int = 0
cursor_col_g: C.int = 0
pending_cursor_update_g: bool = false
busy_g: C.int = 0
pending_mode_info_update_g: bool = false
pending_mode_update_g: bool = false
cursor_grid_handle_g: C.int = 1
ui_event_cbs_g: Map_uint32_t_ptr_t
has_mouse_g: bool = false
pending_has_mouse_g: C.int = -1
pending_default_colors_g: bool = false
vim_beep_beeps_g: C.int = 0
vim_beep_start_g: u64 = 0
ui_flush_was_busy_g: bool = false
ui_flush_cursor_obscured_g: bool = false

cstr_as_string_o :: proc "c" (s: cstring) -> Api_String {
	context = runtime.default_context()
	if s == nil {
		return Api_String{}
	}
	return Api_String{data = transmute(^u8)(s), size = libc.strlen(s)}
}

string_obj_o :: proc "c" (s: Api_String) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 4}
	(^Api_String)(uintptr(&obj) + 8)^ = s
	return obj
}

array_obj_o :: proc "c" (a: Api_Array) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 5}
	(^Api_Array)(uintptr(&obj) + 8)^ = a
	return obj
}

float_obj_o :: proc "c" (f: f64) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 3}
	(^f64)(uintptr(&obj) + 8)^ = f
	return obj
}

handle_obj_o :: proc "c" (typ: C.int, id: i64) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = typ}
	(^i64)(uintptr(&obj) + 8)^ = id
	return obj
}

optobj_to_api_o :: proc "c" (o: Api_Object_Opt) -> Api_Object {
	context = runtime.default_context()
	r := Api_Object{t = o.typ}
	for i in 0 ..< 16 {
		r.data[i] = o.data[i]
	}
	return r
}

bool_cint_o :: proc "c" (b: bool) -> C.int {
	context = runtime.default_context()
	if b {
		return 1
	}
	return 0
}

@(export)
ui_init :: proc "c" () {
	context = runtime.default_context()
	(^ScreenGrid)(&default_grid_u8).handle = 1
	(^GridView)(&msg_grid_adj_u8).target = (^ScreenGrid)(&default_grid_u8)
	ui_comp_init_e()
}

// True if any rgb=true UI is attached.
@(export)
ui_rgb_attached :: proc "c" () -> bool {
	context = runtime.default_context()
	if p_tgc_g != 0 {
		return true
	}
	for i := 0; i < int(ui_count_g); i += 1 {
		ui := (^RemoteUI_O)(uis_g[i])
		tui := ui.stdin_tty || ui.stdout_tty
		if !tui && ui.rgb {
			return true
		}
	}
	return false
}

// True if a GUI is attached.
@(export)
ui_gui_attached :: proc "c" () -> bool {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		ui := (^RemoteUI_O)(uis_g[i])
		tui := ui.stdin_tty || ui.stdout_tty
		if !tui {
			return true
		}
	}
	return false
}

// True if any UI requested override=true.
@(export)
ui_override :: proc "c" () -> bool {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).override {
			return true
		}
	}
	return false
}

// Number of UIs connected to this server.
@(export)
ui_active :: proc "c" () -> C.size_t {
	context = runtime.default_context()
	return ui_count_g
}

@(export)
ui_refresh :: proc "c" () {
	context = runtime.default_context()
	if ui_client_channel_id != 0 {
		libc.abort()
	}
	width := max(C.int)
	height := max(C.int)
	ext_widgets: [10]bool
	inclusive := ui_override()
	for i in 0 ..< 10 {
		ext_widgets[i] = ui_count_g != 0
	}
	for i := 0; i < int(ui_count_g); i += 1 {
		ui := (^RemoteUI_O)(uis_g[i])
		width = min(ui.width, width)
		height = min(ui.height, height)
		for j in 0 ..< 10 {
			ext_widgets[j] = ext_widgets[j] && (ui.ui_ext[j] || inclusive)
		}
	}
	cursor_row_g = 0
	cursor_col_g = 0
	pending_cursor_update_g = true
	had_message := ui_ext_g[4]
	for i in 0 ..< 10 {
		b := 0
		if ext_widgets[i] || ui_cb_ext_g[i] {
			b = 1
		}
		ui_ext_g[i] = ext_widgets[i] || ui_cb_ext_g[i]
		if i < 5 {
			ui_call_option_set(cstr_as_string_o(ui_ext_names_g[i]), BOOL_OBJ(C.int(b)))
		}
	}
	if had_message != ui_ext_g[4] {
		if ui_refresh_cmdheight_g {
			nv := C.longlong(0)
			if had_message {
				nv = 1
			}
			set_option_value(kOptCmdheight_E, num_optval(nv), 0)
			tp := first_tabpage
			for tp != nil {
				(^C.longlong)(uintptr(tp) + uintptr(TP_CH_USED_OFF))^ = nv
				tp = (^rawptr)(uintptr(tp) + uintptr(TP_NEXT_OFF))^
			}
		}
		msg_scroll_flush()
	}
	msg_ui_refresh()
	if ui_count_g == 0 {
		return
	}
	if updating_screen_g {
		ui_schedule_refresh()
		return
	}
	ui_default_colors_set()
	save_p_lz := p_lz_g
	p_lz_g = 0
	screen_resize(width, height)
	p_lz_g = save_p_lz
	ui_mode_info_set()
	pending_mode_update_g = true
	ui_cursor_shape()
	pending_has_mouse_g = -1
}

@(export)
ui_pum_get_height :: proc "c" () -> C.int {
	context = runtime.default_context()
	pum_height: C.int = 0
	for i := 0; i < int(ui_count_g); i += 1 {
		h := (^RemoteUI_O)(uis_g[i]).pum_nlines
		if h != 0 {
			if pum_height != 0 {
				pum_height = min(pum_height, h)
			} else {
				pum_height = h
			}
		}
	}
	return pum_height
}

@(export)
ui_pum_get_pos :: proc "c" (pwidth: ^f64, pheight: ^f64, prow: ^f64, pcol: ^f64) -> bool {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		ui := (^RemoteUI_O)(uis_g[i])
		if !ui.pum_pos {
			continue
		}
		pwidth^ = ui.pum_width
		pheight^ = ui.pum_height
		prow^ = ui.pum_row
		pcol^ = ui.pum_col
		return true
	}
	return false
}

ui_refresh_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	ui_refresh()
}

@(export)
ui_schedule_refresh :: proc "c" () {
	context = runtime.default_context()
	multiqueue_put_event(resize_events_g, event_create(ui_refresh_event_o))
}

@(export)
ui_default_colors_set :: proc "c" () {
	context = runtime.default_context()
	pending_default_colors_g = true
	if starting == 0 {
		ui_may_set_default_colors_o()
	}
}

ui_may_set_default_colors_o :: proc "c" () {
	context = runtime.default_context()
	if pending_default_colors_g {
		pending_default_colors_g = false
		ui_call_default_colors_set(i64(normal_fg_g), i64(normal_bg_g), i64(normal_sp_g), i64(cterm_normal_fg_color_g), i64(cterm_normal_bg_color_g))
	}
}

@(export)
ui_busy_start :: proc "c" () {
	context = runtime.default_context()
	busy_g += 1
	if busy_g == 1 {
		ui_call_busy_start()
	}
}

@(export)
ui_busy_stop :: proc "c" () {
	context = runtime.default_context()
	busy_g -= 1
	if busy_g == 0 {
		ui_call_busy_stop()
	}
}

// Emit a bell or visualbell as a warning.
@(export)
vim_beep :: proc "c" (val: C.uint) {
	context = runtime.default_context()
	called_vim_beep_g = true
	if emsg_silent != 0 || in_assert_fails_g {
		return
	}
	if (bo_flags_g & val) == 0 && (bo_flags_g & u32(KOPTBOFLAGALL_O)) == 0 {
		if vim_beep_start_g == 0 || os_hrtime() - vim_beep_start_g > 500000000 {
			vim_beep_beeps_g = 0
			vim_beep_start_g = os_hrtime()
		}
		vim_beep_beeps_g += 1
		if vim_beep_beeps_g <= 3 {
			if p_vb_g != 0 {
				ui_call_visual_bell()
			} else {
				ui_call_bell()
			}
		}
	}
	if vim_strchr(transmute(cstring)(p_debug_g), C.int('e')) != nil {
		msg_source(26)
		msg(_t(cstring("Beep!")), 26)
	}
}

// Trigger UIEnter for all attached UIs (after VimEnter).
@(export)
do_autocmd_uienter_all :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		do_autocmd_uienter_e((^RemoteUI_O)(uis_g[i]).channel_id, true)
	}
}

@(export)
ui_can_attach_more :: proc "c" () -> bool {
	context = runtime.default_context()
	return ui_count_g < MAX_UI_COUNT_O
}

@(export)
ui_attach_impl :: proc "c" (ui_raw: rawptr, chanid: u64) {
	context = runtime.default_context()
	ui := (^RemoteUI_O)(ui_raw)
	if ui_count_g >= MAX_UI_COUNT_O {
		libc.abort()
	}
	if !ui.ui_ext[6] && !ui.ui_ext[9] && ui_client_channel_id == 0 {
		ui_comp_attach_e(ui_raw)
	}
	uis_g[int(ui_count_g)] = ui_raw
	ui_count_g += 1
	ui_refresh_options()
	resettitle()
	cwd: [4096]u8
	cwdlen: C.size_t = 4096
	if uv_cwd(&cwd[0], &cwdlen) == 0 {
		ui_call_chdir(Api_String{data = &cwd[0], size = cwdlen})
	}
	for i in 5 ..< 10 {
		ui_set_ext_option(ui_raw, C.int(i), ui.ui_ext[i])
	}
	sent := false
	if ui.ui_ext[7] {
		sent = highlight_use_hlstate_e()
	}
	if !sent {
		ui_send_all_hls_e(ui_raw)
	}
	ui_refresh()
	do_autocmd_uienter_e(chanid, true)
}

@(export)
ui_detach_impl :: proc "c" (ui_raw: rawptr, chanid: u64) {
	context = runtime.default_context()
	ui := (^RemoteUI_O)(ui_raw)
	if ui_count_g > MAX_UI_COUNT_O {
		libc.abort()
	}
	shift_index := int(MAX_UI_COUNT_O)
	for i := 0; i < int(ui_count_g); i += 1 {
		if uis_g[i] == ui_raw {
			shift_index = i
			break
		}
	}
	if shift_index >= int(MAX_UI_COUNT_O) {
		libc.abort()
	}
	for shift_index < int(ui_count_g) - 1 {
		uis_g[shift_index] = uis_g[shift_index + 1]
		shift_index += 1
	}
	ui_count_g -= 1
	if ui_count_g != 0 && !exiting {
		ui_schedule_refresh()
	}
	if !ui.ui_ext[6] && !ui.ui_ext[9] {
		ui_comp_detach_e(ui_raw)
	}
	do_autocmd_uienter_e(chanid, false)
}

@(export)
ui_set_ext_option :: proc "c" (ui_raw: rawptr, ext: C.int, active: bool) {
	context = runtime.default_context()
	ui := (^RemoteUI_O)(ui_raw)
	if ext < 5 {
		ui_refresh()
		return
	}
	if ([^]u8)(rawptr(ui_ext_names_g[int(ext)]))[0] != '_' || active {
		bv := 0
		if active {
			bv = 1
		}
		remote_ui_option_set_e(ui_raw, cstr_as_string_o(ui_ext_names_g[int(ext)]), BOOL_OBJ(C.int(bv)))
	}
	if ext == 8 {
		ui_default_colors_set()
	}
}

@(export)
ui_line :: proc "c" (grid_raw: rawptr, row: C.int, invalid_row: bool, startcol: C.int, endcol: C.int, clearcol: C.int, clearattr: C.int, wrap: bool) {
	context = runtime.default_context()
	grid := (^ScreenGrid)(grid_raw)
	if !(0 <= row && row < grid.rows) {
		libc.abort()
	}
	flags: C.int = 0
	if wrap {
		flags = 1
	}
	if startcol == 0 && invalid_row {
		flags |= 2
	}
	ui_may_set_default_colors_o()
	off := int(grid.line_offset[int(row)]) + int(startcol)
	ui_call_raw_line(i64(grid.handle), i64(row), i64(startcol), i64(endcol), i64(clearcol), i64(clearattr), flags, &grid.chars[off], transmute(^C.int32_t)(&grid.attrs[off]))
	if p_wd_g != 0 && (rdb_flags_g & KOPTRDBFLAGLINE_O) != 0 {
		cc := clearcol
		if grid.cols - 1 < cc {
			cc = grid.cols - 1
		}
		ui_call_grid_cursor_goto(i64(grid.handle), i64(row), i64(cc))
		ui_call_flush()
		wd := u64(abs(p_wd_g))
		os_sleep(wd)
		pending_cursor_update_g = true
	}
}

@(export)
ui_cursor_goto :: proc "c" (new_row: C.int, new_col: C.int) {
	context = runtime.default_context()
	ui_grid_cursor_goto(1, new_row, new_col)
}

@(export)
ui_grid_cursor_goto :: proc "c" (grid_handle: C.int, new_row: C.int, new_col: C.int) {
	context = runtime.default_context()
	if new_row == cursor_row_g && new_col == cursor_col_g && grid_handle == cursor_grid_handle_g {
		return
	}
	cursor_row_g = new_row
	cursor_col_g = new_col
	cursor_grid_handle_g = grid_handle
	pending_cursor_update_g = true
}

// Moving the cursor grid implicitly moves the cursor.
@(export)
ui_check_cursor_grid :: proc "c" (grid_handle: C.int) {
	context = runtime.default_context()
	if cursor_grid_handle_g == grid_handle {
		pending_cursor_update_g = true
	}
}

@(export)
ui_mode_info_set :: proc "c" () {
	context = runtime.default_context()
	pending_mode_info_update_g = true
}

@(export)
ui_current_row :: proc "c" () -> C.int {
	context = runtime.default_context()
	return cursor_row_g
}

@(export)
ui_current_col :: proc "c" () -> C.int {
	context = runtime.default_context()
	return cursor_col_g
}

@(export)
ui_flush :: proc "c" () {
	context = runtime.default_context()
	if ui_client_channel_id != 0 {
		libc.abort()
	}
	if ui_count_g == 0 {
		return
	}
	if (State & MODE_CMDLINE_O) == 0 && (^bool)(uintptr(curwin) + uintptr(W_FLOATING_OFF))^ && (^bool)(uintptr(curwin) + uintptr(WCFG_HIDE_OFF))^ {
		if !ui_flush_was_busy_g {
			ui_call_busy_start()
			ui_flush_was_busy_g = true
		}
	} else if ui_flush_was_busy_g {
		ui_call_busy_stop()
		ui_flush_was_busy_g = false
	}
	win_ui_flush(false)
	if textlock == 0 && expr_map_lock_g == 0 {
		cmdline_ui_flush_e()
		msg_ext_ui_flush()
	}
	msg_scroll_flush()
	if pending_cursor_update_g {
		ui_call_grid_cursor_goto(i64(cursor_grid_handle_g), i64(cursor_row_g), i64(cursor_col_g))
		pending_cursor_update_g = false
		win_ui_flush(false)
	}
	if pending_mode_info_update_g {
		arena := Arena_O{}
		style := mode_style_array(rawptr(&arena))
		enabled := p_guicursor_g^ != 0
		ui_call_mode_info_set(enabled, style)
		arena_mem_free(arena_finish(rawptr(&arena)))
		pending_mode_info_update_g = false
	}
	cursor_obscured := ui_cursor_is_behind_floatwin_o()
	if (cursor_obscured != ui_flush_cursor_obscured_g || pending_mode_update_g) && starting == 0 {
		idx := ui_mode_idx_g
		if cursor_obscured {
			idx = SHAPE_IDX_R_O
		}
		ui_call_mode_change(cstr_as_string_o(shape_table[int(idx)].full_name), i64(idx))
		pending_mode_update_g = false
		ui_flush_cursor_obscured_g = cursor_obscured
	}
	if pending_has_mouse_g != bool_cint_o(has_mouse_g) {
		if has_mouse_g {
			ui_call_mouse_on()
			pending_has_mouse_g = 1
		} else {
			ui_call_mouse_off()
			pending_has_mouse_g = 0
		}
	}
	ui_call_flush()
	if p_wd_g != 0 && (rdb_flags_g & KOPTRDBFLAGFLUSH_O) != 0 {
		os_sleep(u64(abs(p_wd_g)))
	}
}

// Check if mouse is active for the current mode.
@(export)
ui_check_mouse :: proc "c" () {
	context = runtime.default_context()
	has_mouse_g = false
	if p_mouse_g^ == 0 {
		return
	}
	checkfor: C.int = C.int('n')
	if VIsual_active {
		checkfor = C.int('v')
	} else if State == MODE_HITRETURN_O || State == MODE_ASKMORE_O || State == MODE_SETWSIZE_O {
		checkfor = C.int('r')
	} else if (State & MODE_INSERT) != 0 {
		checkfor = C.int('i')
	} else if (State & MODE_CMDLINE_O) != 0 {
		checkfor = C.int('c')
	} else if State == MODE_EXTERNCMD_O {
		checkfor = C.int(' ')
	}
	if ui_mouse_has(checkfor) {
		has_mouse_g = true
	}
}

// True if mouse is active for the given mode.
@(export)
ui_mouse_has :: proc "c" (mode: C.int) -> bool {
	context = runtime.default_context()
	p := ([^]u8)(p_mouse_g)
	i := 0
	for p[i] != 0 {
		c := p[i]
		if c == 'a' {
			if vim_strchr(cstring("nvich"), mode) != nil {
				return true
			}
		} else if c == 'h' {
			if mode != C.int('r') && (^bool)(uintptr(curbuf) + uintptr(B_HELP_OFF))^ {
				return true
			}
		} else if mode == C.int(c) {
			return true
		}
		i += 1
	}
	return false
}

// Check if current mode changed (may update cursor shape).
@(export)
ui_cursor_shape_no_check_conceal :: proc "c" () {
	context = runtime.default_context()
	if !full_screen {
		return
	}
	new_mode_idx := cursor_get_mode_idx()
	if new_mode_idx != ui_mode_idx_g {
		ui_mode_idx_g = new_mode_idx
		pending_mode_update_g = true
	}
}

@(export)
ui_cursor_shape :: proc "c" () {
	context = runtime.default_context()
	ui_cursor_shape_no_check_conceal()
	conceal_check_cursor_line()
}

// True if cursor is obscured by a float (zindex exceeds window by 50).
ui_cursor_is_behind_floatwin_o :: proc "c" () -> bool {
	context = runtime.default_context()
	if (State & MODE_CMDLINE_O) != 0 || !ui_comp_should_draw_e() {
		return false
	}
	crow := (^C.int)(uintptr(curwin) + uintptr(W_WINROW_OFF))^ + (^C.int)(uintptr(curwin) + uintptr(W_WINROW_OFF2_OFF))^ + (^C.int)(uintptr(curwin) + uintptr(W_WROW_OFF))^
	ccol := (^C.int)(uintptr(curwin) + uintptr(W_WINCOL_OFF))^ + (^C.int)(uintptr(curwin) + uintptr(W_WINCOL_OFF2_OFF))^
	if (^C.int)(uintptr(curwin) + uintptr(W_P_RL_OFF))^ != 0 {
		ccol += (^C.int)(uintptr(curwin) + uintptr(W_VIEW_WIDTH_OFF))^ - (^C.int)(uintptr(curwin) + uintptr(W_WCOL_OFF))^ - 1
	} else {
		ccol += (^C.int)(uintptr(curwin) + uintptr(W_WCOL_OFF))^
	}
	top_grid := ui_comp_get_grid_at_coord_e(crow, ccol)
	return top_grid != (^ScreenGrid)(uintptr(curwin) + uintptr(W_GRID_ALLOC_OFF)) && top_grid != (^ScreenGrid)(&default_grid_u8) && top_grid.zindex >= (^ScreenGrid)(uintptr(curwin) + uintptr(W_GRID_ALLOC_OFF)).zindex + 50
}

// True if the given UI extension is enabled.
@(export)
ui_has :: proc "c" (ext: C.int) -> bool {
	context = runtime.default_context()
	return ui_ext_g[int(ext)]
}

@(export)
ui_array :: proc "c" (arena_raw: rawptr) -> Api_Array {
	context = runtime.default_context()
	all_uis := arena_array_e(arena_raw, ui_count_g)
	for i := 0; i < int(ui_count_g); i += 1 {
		ui := (^RemoteUI_O)(uis_g[i])
		info := arena_dict_c(arena_raw, 20)
		dict_put_obj_o(&info, cstring("width"), INT_OBJ(i64(ui.width)))
		dict_put_obj_o(&info, cstring("height"), INT_OBJ(i64(ui.height)))
		dict_put_obj_o(&info, cstring("rgb"), BOOL_OBJ(bool_cint_o(ui.rgb)))
		dict_put_obj_o(&info, cstring("override"), BOOL_OBJ(bool_cint_o(ui.override)))
		dict_put_obj_o(&info, cstring("term_name"), string_obj_o(cstr_as_string_o(transmute(cstring)(ui.term_name))))
		dict_put_obj_o(&info, cstring("term_background"), CSTR_AS_OBJ(transmute(^u8)(cstring(""))))
		dict_put_obj_o(&info, cstring("term_colors"), INT_OBJ(i64(ui.term_colors)))
		dict_put_obj_o(&info, cstring("stdin_tty"), BOOL_OBJ(bool_cint_o(ui.stdin_tty)))
		dict_put_obj_o(&info, cstring("stdout_tty"), BOOL_OBJ(bool_cint_o(ui.stdout_tty)))
		for j in 0 ..< 10 {
			if ([^]u8)(rawptr(ui_ext_names_g[j]))[0] != '_' || ui.ui_ext[j] {
				dict_put_obj_o(&info, ui_ext_names_g[j], BOOL_OBJ(bool_cint_o(ui.ui_ext[j])))
			}
		}
		dict_put_obj_o(&info, cstring("chan"), INT_OBJ(i64(ui.channel_id)))
		arr_add_obj_o(&all_uis, DICT_OBJ(info))
	}
	return all_uis
}

@(export)
ui_grid_resize :: proc "c" (grid_handle: C.int, width: C.int, height: C.int, err: ^Api_Error) {
	context = runtime.default_context()
	if grid_handle == DEFAULT_GRID_HANDLE_O {
		screen_resize(width, height)
		return
	}
	wp := get_win_by_grid_handle(grid_handle)
	if wp == nil {
		api_err_invalid_e(err, "window handle", nil, i64(grid_handle), false)
		return
	}
	if (^bool)(uintptr(wp) + uintptr(W_FLOATING_OFF))^ {
		if width != (^C.int)(uintptr(wp) + uintptr(W_WIDTH_OFF))^ || height != (^C.int)(uintptr(wp) + uintptr(W_HEIGHT_OFF))^ {
			(^C.int)(uintptr(wp) + uintptr(WC_WIDTH_OFF))^ = max(width, 1)
			(^C.int)(uintptr(wp) + uintptr(WC_HEIGHT_OFF))^ = max(height, 1)
			cfg := (^WinConfig_Opaque)(uintptr(wp) + uintptr(W_CONFIG_OFF))^
			win_config_float(wp, cfg)
		}
	} else {
		hm := height
		if hm < 0 {
			hm = 0
		}
		wm := width
		if wm < 0 {
			wm = 0
		}
		(^C.int)(uintptr(wp) + uintptr(W_HEIGHT_REQUEST_OFF))^ = hm
		(^C.int)(uintptr(wp) + uintptr(W_WIDTH_REQUEST_OFF))^ = wm
		win_set_inner_size(wp, true)
	}
}

@(export)
ui_call_event :: proc "c" (name: cstring, args: Api_Array) {
	context = runtime.default_context()
	save_expr_map_lock := expr_map_lock_g
	save_textlock := textlock
	expr_map_lock_g = 0
	textlock = 0
	handled := false
	fast := msg_ext_fast_g && libc.strcmp(cstring("msg_show"), name) == 0
	cbmap := &ui_event_cbs_g
	i: u32 = 0
	for i < cbmap.set.h.n_keys {
		ui_event_ns_id_g = cbmap.set.keys[uintptr(i)]
		event_cb := (^UIEventCallback_O)(cbmap.values[uintptr(i)])
		err := Api_Error{typ = -1}
		ns_id := ui_event_ns_id_g
		res := nlua_call_ref_ctx_e(fast, event_cb.cb, name, args, KRETNILBOOL_O, nil, &err)
		ui_event_ns_id_g = 0
		if luaret_truthy_o(&res) {
			handled = true
		}
		if ERROR_SET(rawptr(&err)) {
			ui_attach_error_o(ns_id, name, transmute(cstring)(err.msg))
			ui_remove_cb(ns_id, true)
		}
		api_clear_error_r(&err)
		i += 1
	}
	expr_map_lock_g = save_expr_map_lock
	textlock = save_textlock
	if !handled {
		for j := 0; j < int(ui_count_g); j += 1 {
			remote_ui_event_e(uis_g[j], name, args)
		}
	}
}

ui_cb_update_ext_o :: proc "c" () {
	context = runtime.default_context()
	for i in 0 ..< 10 {
		ui_cb_ext_g[i] = false
	}
	for i in 0 ..< 5 {
		cbmap := &ui_event_cbs_g
		for k: u32 = 0; k < cbmap.set.h.n_keys; k += 1 {
			if (^UIEventCallback_O)(cbmap.values[uintptr(k)]).ext_widgets[i] {
				ui_cb_ext_g[i] = true
				break
			}
		}
	}
}

free_ui_event_callback_o :: proc "c" (event_cb: ^UIEventCallback_O) {
	context = runtime.default_context()
	api_free_luaref_e(event_cb.cb)
	xfree(event_cb)
}

@(export)
ui_add_cb :: proc "c" (ns_id: u32, cb: C.int, ext_widgets: ^bool) {
	context = runtime.default_context()
	event_cb := (^UIEventCallback_O)(xcalloc(1, size_of(UIEventCallback_O)))
	event_cb.cb = cb
	libc.memcpy(rawptr(&event_cb.ext_widgets[0]), ext_widgets, 10)
	if event_cb.ext_widgets[4] {
		event_cb.ext_widgets[0] = true
	}
	item := map_put_ref_uint32_t_ptr_t(&ui_event_cbs_g, ns_id, nil, nil)
	if item^ != nil {
		free_ui_event_callback_o((^UIEventCallback_O)(item^))
	}
	item^ = event_cb
	ui_cb_update_ext_o()
	ui_refresh()
}

@(export)
ui_remove_cb :: proc "c" (ns_id: u32, checkerr: bool) {
	context = runtime.default_context()
	slot := map_ref_uint32_t_ptr_t(&ui_event_cbs_g, ns_id, nil)
	if slot == nil {
		return
	}
	item := (^UIEventCallback_O)(slot^)
	if checkerr && item != nil {
		item.errors += 1
	}
	if item != nil && (!checkerr || item.errors > CB_MAX_ERROR_O) {
		map_del_uint32_t_ptr_t(&ui_event_cbs_g, ns_id, nil)
		free_ui_event_callback_o(item)
		ui_cb_update_ext_o()
		ui_refresh()
		if checkerr {
			msg_schedule_semsg(cstring("Excessive errors in vim.ui_attach() callback (ns=%s)"), describe_ns_e(ns_id, cstring("(UNKNOWN PLUGIN)")))
		}
	}
}

ui_attach_error_o :: proc "c" (ns_id: u32, name: cstring, msg: cstring) {
	context = runtime.default_context()
	ns := describe_ns_e(ns_id, cstring("(UNKNOWN PLUGIN)"))
	logmsg_e(4, nil, cstring("ui_attach_error"), 787, true, cstring("Error in \"%s\" UI event handler (ns=%s):\n%s"), name, ns, msg)
	msg_schedule_semsg_multiline_e(cstring("Error in \"%s\" UI event handler (ns=%s):\n%s"), name, ns, msg)
}

// —— Batch U3: ui_call_* dispatchers (generated in ui_events_call.generated.h) ——

@(export)
ui_call_mode_info_set :: proc "c" (enabled: bool, cursor_styles: Api_Array) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_mode_info_set_e(uis_g[i], enabled, cursor_styles)
	}
}

@(export)
ui_call_update_menu :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_update_menu_e(uis_g[i])
	}
}

@(export)
ui_call_busy_start :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_busy_start_e(uis_g[i])
	}
}

@(export)
ui_call_busy_stop :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_busy_stop_e(uis_g[i])
	}
}

@(export)
ui_call_mouse_on :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_mouse_on_e(uis_g[i])
	}
}

@(export)
ui_call_mouse_off :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_mouse_off_e(uis_g[i])
	}
}

@(export)
ui_call_mode_change :: proc "c" (mode: Api_String, mode_idx: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_mode_change_e(uis_g[i], mode, mode_idx)
	}
}

@(export)
ui_call_bell :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_bell_e(uis_g[i])
	}
}

@(export)
ui_call_visual_bell :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_visual_bell_e(uis_g[i])
	}
}

@(export)
ui_call_flush :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_flush_e(uis_g[i])
	}
}

ui_call_restart_entered_g: bool = false

@(export)
ui_call_restart :: proc "c" (listen_addr: Api_String) {
	context = runtime.default_context()
	if ui_call_restart_entered_g {
		return
	}
	ui_call_restart_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, string_obj_o(listen_addr))
	ui_call_event(cstring("restart"), args)
	ui_call_restart_entered_g = false
}

@(export)
ui_call_suspend :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_suspend_e(uis_g[i])
	}
}

@(export)
ui_call_set_title :: proc "c" (title: Api_String) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_set_title_e(uis_g[i], title)
	}
}

@(export)
ui_call_set_icon :: proc "c" (icon: Api_String) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_set_icon_e(uis_g[i], icon)
	}
}

@(export)
ui_call_screenshot :: proc "c" (path: Api_String) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_screenshot_e(uis_g[i], path)
	}
}

@(export)
ui_call_option_set :: proc "c" (name: Api_String, value: Api_Object) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_option_set_e(uis_g[i], name, value)
	}
}

@(export)
ui_call_chdir :: proc "c" (path: Api_String) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_chdir_e(uis_g[i], path)
	}
}

@(export)
ui_call_stop :: proc "c" () {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_stop_e(uis_g[i])
	}
}

@(export)
ui_call_ui_send :: proc "c" (content: Api_String) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_ui_send_e(uis_g[i], content)
	}
}

ui_call_update_fg_entered_g: bool = false

@(export)
ui_call_update_fg :: proc "c" (fg: i64) {
	context = runtime.default_context()
	if ui_call_update_fg_entered_g {
		return
	}
	ui_call_update_fg_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(fg))
	ui_call_event(cstring("update_fg"), args)
	ui_call_update_fg_entered_g = false
}

ui_call_update_bg_entered_g: bool = false

@(export)
ui_call_update_bg :: proc "c" (bg: i64) {
	context = runtime.default_context()
	if ui_call_update_bg_entered_g {
		return
	}
	ui_call_update_bg_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(bg))
	ui_call_event(cstring("update_bg"), args)
	ui_call_update_bg_entered_g = false
}

ui_call_update_sp_entered_g: bool = false

@(export)
ui_call_update_sp :: proc "c" (sp: i64) {
	context = runtime.default_context()
	if ui_call_update_sp_entered_g {
		return
	}
	ui_call_update_sp_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(sp))
	ui_call_event(cstring("update_sp"), args)
	ui_call_update_sp_entered_g = false
}

ui_call_resize_entered_g: bool = false

@(export)
ui_call_resize :: proc "c" (width: i64, height: i64) {
	context = runtime.default_context()
	if ui_call_resize_entered_g {
		return
	}
	ui_call_resize_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(width))
	arr_add_obj_o(&args, INT_OBJ(height))
	ui_call_event(cstring("resize"), args)
	ui_call_resize_entered_g = false
}

ui_call_clear_entered_g: bool = false

@(export)
ui_call_clear :: proc "c" () {
	context = runtime.default_context()
	if ui_call_clear_entered_g {
		return
	}
	ui_call_clear_entered_g = true
	ui_call_event(cstring("clear"), Api_Array{})
	ui_call_clear_entered_g = false
}

ui_call_eol_clear_entered_g: bool = false

@(export)
ui_call_eol_clear :: proc "c" () {
	context = runtime.default_context()
	if ui_call_eol_clear_entered_g {
		return
	}
	ui_call_eol_clear_entered_g = true
	ui_call_event(cstring("eol_clear"), Api_Array{})
	ui_call_eol_clear_entered_g = false
}

ui_call_cursor_goto_entered_g: bool = false

@(export)
ui_call_cursor_goto :: proc "c" (row: i64, col: i64) {
	context = runtime.default_context()
	if ui_call_cursor_goto_entered_g {
		return
	}
	ui_call_cursor_goto_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(row))
	arr_add_obj_o(&args, INT_OBJ(col))
	ui_call_event(cstring("cursor_goto"), args)
	ui_call_cursor_goto_entered_g = false
}

ui_call_put_entered_g: bool = false

@(export)
ui_call_put :: proc "c" (str: Api_String) {
	context = runtime.default_context()
	if ui_call_put_entered_g {
		return
	}
	ui_call_put_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, string_obj_o(str))
	ui_call_event(cstring("put"), args)
	ui_call_put_entered_g = false
}

ui_call_set_scroll_region_entered_g: bool = false

@(export)
ui_call_set_scroll_region :: proc "c" (top: i64, bot: i64, left: i64, right: i64) {
	context = runtime.default_context()
	if ui_call_set_scroll_region_entered_g {
		return
	}
	ui_call_set_scroll_region_entered_g = true
	items: [4]Api_Object
	args := Api_Array{size = 0, capacity = 4, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(top))
	arr_add_obj_o(&args, INT_OBJ(bot))
	arr_add_obj_o(&args, INT_OBJ(left))
	arr_add_obj_o(&args, INT_OBJ(right))
	ui_call_event(cstring("set_scroll_region"), args)
	ui_call_set_scroll_region_entered_g = false
}

ui_call_scroll_entered_g: bool = false

@(export)
ui_call_scroll :: proc "c" (count: i64) {
	context = runtime.default_context()
	if ui_call_scroll_entered_g {
		return
	}
	ui_call_scroll_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(count))
	ui_call_event(cstring("scroll"), args)
	ui_call_scroll_entered_g = false
}

@(export)
ui_call_default_colors_set :: proc "c" (rgb_fg: i64, rgb_bg: i64, rgb_sp: i64, cterm_fg: i64, cterm_bg: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_default_colors_set_e(uis_g[i], rgb_fg, rgb_bg, rgb_sp, cterm_fg, cterm_bg)
	}
}

@(export)
ui_call_hl_attr_define :: proc "c" (id: i64, rgb_attrs: HlAttrs, cterm_attrs: HlAttrs, info: Api_Array) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_hl_attr_define_e(uis_g[i], id, rgb_attrs, cterm_attrs, info)
	}
}

@(export)
ui_call_hl_group_set :: proc "c" (name: Api_String, id: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_hl_group_set_e(uis_g[i], name, id)
	}
}

@(export)
ui_call_grid_resize :: proc "c" (grid: i64, width: i64, height: i64) {
	context = runtime.default_context()
	ui_comp_grid_resize_e(grid, width, height)
	for i := 0; i < int(ui_count_g); i += 1 {
		if !(^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_resize_e(uis_g[i], grid, width, height)
		}
	}
}

@(export)
ui_composed_call_grid_resize :: proc "c" (grid: i64, width: i64, height: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_resize_e(uis_g[i], grid, width, height)
		}
	}
}

@(export)
ui_call_grid_clear :: proc "c" (grid: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_grid_clear_e(uis_g[i], grid)
	}
}

@(export)
ui_call_grid_cursor_goto :: proc "c" (grid: i64, row: i64, col: i64) {
	context = runtime.default_context()
	ui_comp_grid_cursor_goto_e(grid, row, col)
	for i := 0; i < int(ui_count_g); i += 1 {
		if !(^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_cursor_goto_e(uis_g[i], grid, row, col)
		}
	}
}

@(export)
ui_composed_call_grid_cursor_goto :: proc "c" (grid: i64, row: i64, col: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_cursor_goto_e(uis_g[i], grid, row, col)
		}
	}
}

ui_call_grid_line_entered_g: bool = false

@(export)
ui_call_grid_line :: proc "c" (grid: i64, row: i64, col_start: i64, data: Api_Array, wrap: bool) {
	context = runtime.default_context()
	if ui_call_grid_line_entered_g {
		return
	}
	ui_call_grid_line_entered_g = true
	items: [5]Api_Object
	args := Api_Array{size = 0, capacity = 5, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	arr_add_obj_o(&args, INT_OBJ(row))
	arr_add_obj_o(&args, INT_OBJ(col_start))
	arr_add_obj_o(&args, array_obj_o(data))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(wrap)))
	ui_call_event(cstring("grid_line"), args)
	ui_call_grid_line_entered_g = false
}

@(export)
ui_call_grid_scroll :: proc "c" (grid: i64, top: i64, bot: i64, left: i64, right: i64, rows: i64, cols: i64) {
	context = runtime.default_context()
	ui_comp_grid_scroll_e(grid, top, bot, left, right, rows, cols)
	for i := 0; i < int(ui_count_g); i += 1 {
		if !(^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_scroll_e(uis_g[i], grid, top, bot, left, right, rows, cols)
		}
	}
}

@(export)
ui_composed_call_grid_scroll :: proc "c" (grid: i64, top: i64, bot: i64, left: i64, right: i64, rows: i64, cols: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_grid_scroll_e(uis_g[i], grid, top, bot, left, right, rows, cols)
		}
	}
}

ui_call_grid_destroy_entered_g: bool = false

@(export)
ui_call_grid_destroy :: proc "c" (grid: i64) {
	context = runtime.default_context()
	if ui_call_grid_destroy_entered_g {
		return
	}
	ui_call_grid_destroy_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	ui_call_event(cstring("grid_destroy"), args)
	ui_call_grid_destroy_entered_g = false
}

@(export)
ui_call_raw_line :: proc "c" (grid: i64, row: i64, startcol: i64, endcol: i64, clearcol: i64, clearattr: i64, flags: C.int, chunk: ^u32, attrs: ^C.int32_t) {
	context = runtime.default_context()
	ui_comp_raw_line_e(grid, row, startcol, endcol, clearcol, clearattr, flags, chunk, attrs)
	for i := 0; i < int(ui_count_g); i += 1 {
		if !(^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_raw_line_e(uis_g[i], grid, row, startcol, endcol, clearcol, clearattr, flags, chunk, attrs)
		}
	}
}

@(export)
ui_composed_call_raw_line :: proc "c" (grid: i64, row: i64, startcol: i64, endcol: i64, clearcol: i64, clearattr: i64, flags: C.int, chunk: ^u32, attrs: ^C.int32_t) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_raw_line_e(uis_g[i], grid, row, startcol, endcol, clearcol, clearattr, flags, chunk, attrs)
		}
	}
}

ui_call_win_pos_entered_g: bool = false

@(export)
ui_call_win_pos :: proc "c" (grid: i64, win: i64, startrow: i64, startcol: i64, width: i64, height: i64) {
	context = runtime.default_context()
	if ui_call_win_pos_entered_g {
		return
	}
	ui_call_win_pos_entered_g = true
	items: [6]Api_Object
	args := Api_Array{size = 0, capacity = 6, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	arr_add_obj_o(&args, handle_obj_o(9, win))
	arr_add_obj_o(&args, INT_OBJ(startrow))
	arr_add_obj_o(&args, INT_OBJ(startcol))
	arr_add_obj_o(&args, INT_OBJ(width))
	arr_add_obj_o(&args, INT_OBJ(height))
	ui_call_event(cstring("win_pos"), args)
	ui_call_win_pos_entered_g = false
}

ui_call_win_float_pos_entered_g: bool = false

@(export)
ui_call_win_float_pos :: proc "c" (grid: i64, win: i64, anchor: Api_String, anchor_grid: i64, anchor_row: f64, anchor_col: f64, mouse_enabled: bool, zindex: i64, compindex: i64, screen_row: i64, screen_col: i64) {
	context = runtime.default_context()
	if ui_call_win_float_pos_entered_g {
		return
	}
	ui_call_win_float_pos_entered_g = true
	items: [11]Api_Object
	args := Api_Array{size = 0, capacity = 11, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	arr_add_obj_o(&args, handle_obj_o(9, win))
	arr_add_obj_o(&args, string_obj_o(anchor))
	arr_add_obj_o(&args, INT_OBJ(anchor_grid))
	arr_add_obj_o(&args, float_obj_o(anchor_row))
	arr_add_obj_o(&args, float_obj_o(anchor_col))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(mouse_enabled)))
	arr_add_obj_o(&args, INT_OBJ(zindex))
	arr_add_obj_o(&args, INT_OBJ(compindex))
	arr_add_obj_o(&args, INT_OBJ(screen_row))
	arr_add_obj_o(&args, INT_OBJ(screen_col))
	ui_call_event(cstring("win_float_pos"), args)
	ui_call_win_float_pos_entered_g = false
}

ui_call_win_external_pos_entered_g: bool = false

@(export)
ui_call_win_external_pos :: proc "c" (grid: i64, win: i64) {
	context = runtime.default_context()
	if ui_call_win_external_pos_entered_g {
		return
	}
	ui_call_win_external_pos_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	arr_add_obj_o(&args, handle_obj_o(9, win))
	ui_call_event(cstring("win_external_pos"), args)
	ui_call_win_external_pos_entered_g = false
}

ui_call_win_hide_entered_g: bool = false

@(export)
ui_call_win_hide :: proc "c" (grid: i64) {
	context = runtime.default_context()
	if ui_call_win_hide_entered_g {
		return
	}
	ui_call_win_hide_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	ui_call_event(cstring("win_hide"), args)
	ui_call_win_hide_entered_g = false
}

ui_call_win_close_entered_g: bool = false

@(export)
ui_call_win_close :: proc "c" (grid: i64) {
	context = runtime.default_context()
	if ui_call_win_close_entered_g {
		return
	}
	ui_call_win_close_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	ui_call_event(cstring("win_close"), args)
	ui_call_win_close_entered_g = false
}

@(export)
ui_call_msg_set_pos :: proc "c" (grid: i64, row: i64, scrolled: bool, sep_char: Api_String, zindex: i64, compindex: i64) {
	context = runtime.default_context()
	ui_comp_msg_set_pos_e(grid, row, scrolled, sep_char, zindex, compindex)
	for i := 0; i < int(ui_count_g); i += 1 {
		if !(^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_msg_set_pos_e(uis_g[i], grid, row, scrolled, sep_char, zindex, compindex)
		}
	}
}

@(export)
ui_composed_call_msg_set_pos :: proc "c" (grid: i64, row: i64, scrolled: bool, sep_char: Api_String, zindex: i64, compindex: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		if (^RemoteUI_O)(uis_g[i]).composed {
			remote_ui_msg_set_pos_e(uis_g[i], grid, row, scrolled, sep_char, zindex, compindex)
		}
	}
}

@(export)
ui_call_win_viewport :: proc "c" (grid: i64, win: i64, topline: i64, botline: i64, curline: i64, curcol: i64, line_count: i64, scroll_delta: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_win_viewport_e(uis_g[i], grid, win, topline, botline, curline, curcol, line_count, scroll_delta)
	}
}

@(export)
ui_call_win_viewport_margins :: proc "c" (grid: i64, win: i64, top: i64, bottom: i64, left: i64, right: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_win_viewport_margins_e(uis_g[i], grid, win, top, bottom, left, right)
	}
}

ui_call_win_extmark_entered_g: bool = false

@(export)
ui_call_win_extmark :: proc "c" (grid: i64, win: i64, ns_id: i64, mark_id: i64, row: i64, col: i64) {
	context = runtime.default_context()
	if ui_call_win_extmark_entered_g {
		return
	}
	ui_call_win_extmark_entered_g = true
	items: [6]Api_Object
	args := Api_Array{size = 0, capacity = 6, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(grid))
	arr_add_obj_o(&args, handle_obj_o(9, win))
	arr_add_obj_o(&args, INT_OBJ(ns_id))
	arr_add_obj_o(&args, INT_OBJ(mark_id))
	arr_add_obj_o(&args, INT_OBJ(row))
	arr_add_obj_o(&args, INT_OBJ(col))
	ui_call_event(cstring("win_extmark"), args)
	ui_call_win_extmark_entered_g = false
}

ui_call_popupmenu_show_entered_g: bool = false

@(export)
ui_call_popupmenu_show :: proc "c" (items_arr: Api_Array, selected: i64, row: i64, col: i64, grid: i64) {
	context = runtime.default_context()
	if ui_call_popupmenu_show_entered_g {
		return
	}
	ui_call_popupmenu_show_entered_g = true
	items: [5]Api_Object
	args := Api_Array{size = 0, capacity = 5, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(items_arr))
	arr_add_obj_o(&args, INT_OBJ(selected))
	arr_add_obj_o(&args, INT_OBJ(row))
	arr_add_obj_o(&args, INT_OBJ(col))
	arr_add_obj_o(&args, INT_OBJ(grid))
	ui_call_event(cstring("popupmenu_show"), args)
	ui_call_popupmenu_show_entered_g = false
}

ui_call_popupmenu_hide_entered_g: bool = false

@(export)
ui_call_popupmenu_hide :: proc "c" () {
	context = runtime.default_context()
	if ui_call_popupmenu_hide_entered_g {
		return
	}
	ui_call_popupmenu_hide_entered_g = true
	ui_call_event(cstring("popupmenu_hide"), Api_Array{})
	ui_call_popupmenu_hide_entered_g = false
}

ui_call_popupmenu_select_entered_g: bool = false

@(export)
ui_call_popupmenu_select :: proc "c" (selected: i64) {
	context = runtime.default_context()
	if ui_call_popupmenu_select_entered_g {
		return
	}
	ui_call_popupmenu_select_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(selected))
	ui_call_event(cstring("popupmenu_select"), args)
	ui_call_popupmenu_select_entered_g = false
}

ui_call_tabline_update_entered_g: bool = false

@(export)
ui_call_tabline_update :: proc "c" (current: i64, tabs: Api_Array, current_buffer: i64, buffers: Api_Array) {
	context = runtime.default_context()
	if ui_call_tabline_update_entered_g {
		return
	}
	ui_call_tabline_update_entered_g = true
	items: [4]Api_Object
	args := Api_Array{size = 0, capacity = 4, items = &items[0]}
	arr_add_obj_o(&args, handle_obj_o(10, current))
	arr_add_obj_o(&args, array_obj_o(tabs))
	arr_add_obj_o(&args, handle_obj_o(8, current_buffer))
	arr_add_obj_o(&args, array_obj_o(buffers))
	ui_call_event(cstring("tabline_update"), args)
	ui_call_tabline_update_entered_g = false
}

ui_call_cmdline_show_entered_g: bool = false

@(export)
ui_call_cmdline_show :: proc "c" (content: Api_Array, pos: i64, firstc: Api_String, prompt: Api_String, indent: i64, level: i64, hl_id: i64) {
	context = runtime.default_context()
	if ui_call_cmdline_show_entered_g {
		return
	}
	ui_call_cmdline_show_entered_g = true
	items: [7]Api_Object
	args := Api_Array{size = 0, capacity = 7, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(content))
	arr_add_obj_o(&args, INT_OBJ(pos))
	arr_add_obj_o(&args, string_obj_o(firstc))
	arr_add_obj_o(&args, string_obj_o(prompt))
	arr_add_obj_o(&args, INT_OBJ(indent))
	arr_add_obj_o(&args, INT_OBJ(level))
	arr_add_obj_o(&args, INT_OBJ(hl_id))
	ui_call_event(cstring("cmdline_show"), args)
	ui_call_cmdline_show_entered_g = false
}

ui_call_cmdline_pos_entered_g: bool = false

@(export)
ui_call_cmdline_pos :: proc "c" (pos: i64, level: i64) {
	context = runtime.default_context()
	if ui_call_cmdline_pos_entered_g {
		return
	}
	ui_call_cmdline_pos_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(pos))
	arr_add_obj_o(&args, INT_OBJ(level))
	ui_call_event(cstring("cmdline_pos"), args)
	ui_call_cmdline_pos_entered_g = false
}

ui_call_cmdline_special_char_entered_g: bool = false

@(export)
ui_call_cmdline_special_char :: proc "c" (c: Api_String, shift: bool, level: i64) {
	context = runtime.default_context()
	if ui_call_cmdline_special_char_entered_g {
		return
	}
	ui_call_cmdline_special_char_entered_g = true
	items: [3]Api_Object
	args := Api_Array{size = 0, capacity = 3, items = &items[0]}
	arr_add_obj_o(&args, string_obj_o(c))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(shift)))
	arr_add_obj_o(&args, INT_OBJ(level))
	ui_call_event(cstring("cmdline_special_char"), args)
	ui_call_cmdline_special_char_entered_g = false
}

ui_call_cmdline_hide_entered_g: bool = false

@(export)
ui_call_cmdline_hide :: proc "c" (level: i64, abort: bool) {
	context = runtime.default_context()
	if ui_call_cmdline_hide_entered_g {
		return
	}
	ui_call_cmdline_hide_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(level))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(abort)))
	ui_call_event(cstring("cmdline_hide"), args)
	ui_call_cmdline_hide_entered_g = false
}

ui_call_cmdline_block_show_entered_g: bool = false

@(export)
ui_call_cmdline_block_show :: proc "c" (lines: Api_Array) {
	context = runtime.default_context()
	if ui_call_cmdline_block_show_entered_g {
		return
	}
	ui_call_cmdline_block_show_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(lines))
	ui_call_event(cstring("cmdline_block_show"), args)
	ui_call_cmdline_block_show_entered_g = false
}

ui_call_cmdline_block_append_entered_g: bool = false

@(export)
ui_call_cmdline_block_append :: proc "c" (lines: Api_Array) {
	context = runtime.default_context()
	if ui_call_cmdline_block_append_entered_g {
		return
	}
	ui_call_cmdline_block_append_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(lines))
	ui_call_event(cstring("cmdline_block_append"), args)
	ui_call_cmdline_block_append_entered_g = false
}

ui_call_cmdline_block_hide_entered_g: bool = false

@(export)
ui_call_cmdline_block_hide :: proc "c" () {
	context = runtime.default_context()
	if ui_call_cmdline_block_hide_entered_g {
		return
	}
	ui_call_cmdline_block_hide_entered_g = true
	ui_call_event(cstring("cmdline_block_hide"), Api_Array{})
	ui_call_cmdline_block_hide_entered_g = false
}

ui_call_wildmenu_show_entered_g: bool = false

@(export)
ui_call_wildmenu_show :: proc "c" (items_arr: Api_Array) {
	context = runtime.default_context()
	if ui_call_wildmenu_show_entered_g {
		return
	}
	ui_call_wildmenu_show_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(items_arr))
	ui_call_event(cstring("wildmenu_show"), args)
	ui_call_wildmenu_show_entered_g = false
}

ui_call_wildmenu_select_entered_g: bool = false

@(export)
ui_call_wildmenu_select :: proc "c" (selected: i64) {
	context = runtime.default_context()
	if ui_call_wildmenu_select_entered_g {
		return
	}
	ui_call_wildmenu_select_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, INT_OBJ(selected))
	ui_call_event(cstring("wildmenu_select"), args)
	ui_call_wildmenu_select_entered_g = false
}

ui_call_wildmenu_hide_entered_g: bool = false

@(export)
ui_call_wildmenu_hide :: proc "c" () {
	context = runtime.default_context()
	if ui_call_wildmenu_hide_entered_g {
		return
	}
	ui_call_wildmenu_hide_entered_g = true
	ui_call_event(cstring("wildmenu_hide"), Api_Array{})
	ui_call_wildmenu_hide_entered_g = false
}

ui_call_msg_show_entered_g: bool = false

@(export)
ui_call_msg_show :: proc "c" (kind: Api_String, content: Api_Array, replace_last: bool, history: bool, append: bool, id: Api_Object, trigger: Api_String) {
	context = runtime.default_context()
	if ui_call_msg_show_entered_g {
		return
	}
	ui_call_msg_show_entered_g = true
	items: [7]Api_Object
	args := Api_Array{size = 0, capacity = 7, items = &items[0]}
	arr_add_obj_o(&args, string_obj_o(kind))
	arr_add_obj_o(&args, array_obj_o(content))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(replace_last)))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(history)))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(append)))
	arr_add_obj_o(&args, id)
	arr_add_obj_o(&args, string_obj_o(trigger))
	ui_call_event(cstring("msg_show"), args)
	ui_call_msg_show_entered_g = false
}

ui_call_msg_clear_entered_g: bool = false

@(export)
ui_call_msg_clear :: proc "c" () {
	context = runtime.default_context()
	if ui_call_msg_clear_entered_g {
		return
	}
	ui_call_msg_clear_entered_g = true
	ui_call_event(cstring("msg_clear"), Api_Array{})
	ui_call_msg_clear_entered_g = false
}

ui_call_msg_showcmd_entered_g: bool = false

@(export)
ui_call_msg_showcmd :: proc "c" (content: Api_Array) {
	context = runtime.default_context()
	if ui_call_msg_showcmd_entered_g {
		return
	}
	ui_call_msg_showcmd_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(content))
	ui_call_event(cstring("msg_showcmd"), args)
	ui_call_msg_showcmd_entered_g = false
}

ui_call_msg_showmode_entered_g: bool = false

@(export)
ui_call_msg_showmode :: proc "c" (content: Api_Array) {
	context = runtime.default_context()
	if ui_call_msg_showmode_entered_g {
		return
	}
	ui_call_msg_showmode_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(content))
	ui_call_event(cstring("msg_showmode"), args)
	ui_call_msg_showmode_entered_g = false
}

ui_call_msg_ruler_entered_g: bool = false

@(export)
ui_call_msg_ruler :: proc "c" (content: Api_Array) {
	context = runtime.default_context()
	if ui_call_msg_ruler_entered_g {
		return
	}
	ui_call_msg_ruler_entered_g = true
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(content))
	ui_call_event(cstring("msg_ruler"), args)
	ui_call_msg_ruler_entered_g = false
}

ui_call_msg_history_show_entered_g: bool = false

@(export)
ui_call_msg_history_show :: proc "c" (entries: Api_Array, prev_cmd: bool) {
	context = runtime.default_context()
	if ui_call_msg_history_show_entered_g {
		return
	}
	ui_call_msg_history_show_entered_g = true
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arr_add_obj_o(&args, array_obj_o(entries))
	arr_add_obj_o(&args, BOOL_OBJ(bool_cint_o(prev_cmd)))
	ui_call_event(cstring("msg_history_show"), args)
	ui_call_msg_history_show_entered_g = false
}

@(export)
ui_call_error_exit :: proc "c" (status: i64) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui_error_exit_e(uis_g[i], status)
	}
}

@(export)
ui_call__set_restart_on_crash_exit :: proc "c" (progpath: Api_String, argv: Api_Array) {
	context = runtime.default_context()
	for i := 0; i < int(ui_count_g); i += 1 {
		remote_ui__set_restart_on_crash_exit_e(uis_g[i], progpath, argv)
	}
}
