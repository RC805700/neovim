package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// message.c port: user-visible messaging engine.
// Publics are @(export); C-statics are _o dormant plains.

// KZINDEX_MESSAGES_O already in window.odin — reuse directly.

foreign _ {
	@(link_name = "msg_grid_pos")
	msg_grid_pos_g: C.int
	// msg_keep: see export below — call directly.
	// msg_outtrans_len: see export below — call directly.
	// msg_clr_eos: use eval.odin's msg_clr_eos_e — call directly.
	// msg_putchar_hl: use register.odin's msg_puts_hl_r until Batch 9 ports msg_puts_hl.
	// (msg_putchar_hl itself is exported below.)
	// msg_puts/msg_outtrans: use shell.odin's decls — call directly.
	// msg_puts_hl: use register.odin's msg_puts_hl_r until Batch 9 ports it.
	// msg_hist_add: see msg_hist_add_o plain below — call directly.
	// msg_start/end: see exports below — call directly.
	// msg_outtrans: use shell.odin's decl until Batch 9 ports it.
	// set_keep_msg: see export below — call directly.
	@(link_name = "keep_msg")
	keep_msg_g: ^u8
	@(link_name = "msg_hist_last")
	msg_hist_last_g: rawptr
	@(link_name = "msg_hist_off")
	msg_hist_off_g: bool
	@(link_name = "ex_exitval")
	ex_exitval_g: C.int
	@(link_name = "p_eb")
	p_eb_g: C.int
	@(link_name = "cause_errthrow")
	cause_errthrow_e :: proc "c" (mesg: cstring, multiline: bool, concat: bool, severe: bool, ignore: ^bool) -> bool ---
	// redirecting: use ex_docmd.odin's redirecting_e — call directly.
	// redir_write_o (below) is used directly — no shim needed.
	// str2special: see export below — call directly.
	// vim_vsnprintf now defined in strings.odin — call directly.
	@(link_name = "siemsg")
	siemsg_call_e :: proc "c" (s: cstring, #c_vararg args: ..any) ---
}

FLUSH_MINIMAL_O :: 0
// VV_ERRMSG_O already in testing.odin — reuse directly.
// HLF_E_O already in eval.odin — reuse directly.

foreign _ {
	// msg_hist_clear/clear_temp: see exports below — call directly.
	// hl_msg_free: see export below — call directly.
	@(link_name = "nvim_odin_hist_first")
	hist_first_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_hist_first_set")
	hist_first_set_e :: proc "c" (e: rawptr) ---
	@(link_name = "nvim_odin_hist_temp")
	hist_temp_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_hist_temp_set")
	hist_temp_set_e :: proc "c" (e: rawptr) ---
	@(link_name = "nvim_odin_hist_last")
	hist_last_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_hist_last_set")
	hist_last_set_e :: proc "c" (e: rawptr) ---
	@(link_name = "nvim_odin_hist_len")
	hist_len_e :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_hist_len_set")
	hist_len_set_e :: proc "c" (n: C.int) ---
	// msg_hist_max: moved Odin single-copy global — use directly.
	// msg_ext_kind/append/history/trigger: moved Odin single-copy globals below.

	@(link_name = "nvim_odin_do_clear_hist_temp")
	do_clear_hist_temp_e :: proc "c" () -> bool ---
	@(link_name = "nvim_odin_do_clear_hist_temp_set")
	do_clear_hist_temp_set_e :: proc "c" (v: bool) ---
}

HIST_NEXT_O :: 0
HIST_PREV_O :: 8
HIST_MSG_O :: 16
HIST_KIND_O :: 40
HIST_TEMP_O :: 48
HIST_APPEND_O :: 49
HIST_SIZE_O :: 56
CHUNK_TEXT_O :: 0
CHUNK_HLID_O :: 16
CHUNK_SIZE_O :: 24

HlMessage_O :: struct {
	size:  C.size_t,
	cap:   C.size_t,
	items: rawptr,
}
#assert(size_of(HlMessage_O) == 24)

msg_hist_add_o :: proc "c" (s_in: cstring, len_in: C.int, hl_id: C.int) {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	size := C.size_t(len_in)
	if len_in < 0 {
		size = libc.strlen(s_in)
	}
	for size > 0 && ([^]u8)(s)[0] == '\n' {
		size -= 1
		s = transmute(^u8)(rawptr(uintptr(s) + 1))
	}
	for size > 0 && ([^]u8)(s)[uintptr(size) - 1] == '\n' {
		size -= 1
	}
	if size == 0 {
		return
	}
	data := xmemdupz(rawptr(s), size)
	items := transmute(^u8)(xmalloc(24))
	([^]rawptr)(items)[0] = rawptr(data)
	([^]C.size_t)(items)[1] = C.size_t(size)
	([^]C.int)(items)[4] = hl_id
	hlmsg := HlMessage_O{size = 1, cap = 1, items = rawptr(items)}
	msg_hist_add_multihl_o(hlmsg, false)
}

msg_hist_add_multihl_o :: proc "c" (hlmsg: HlMessage_O, temp: bool) {
	context = runtime.default_context()
	if do_clear_hist_temp_e() {
		msg_hist_clear_temp()
		do_clear_hist_temp_set_e(false)
	}
	if msg_hist_off_g || msg_silent != 0 {
		hl_msg_free(hlmsg)
		return
	}
	entry := transmute(^u8)(xmalloc(HIST_SIZE_O))
	([^]C.size_t)(entry)[2] = hlmsg.size
	([^]C.size_t)(entry)[3] = hlmsg.cap
	([^]rawptr)(entry)[4] = rawptr(hlmsg.items)
	kind := msg_ext_kind
	if kind == nil {
		([^]rawptr)(entry)[5] = nil
	} else {
		([^]rawptr)(entry)[5] = rawptr(xstrdup(transmute(^u8)(kind)))
	}
	([^]rawptr)(entry)[0] = nil
	([^]rawptr)(entry)[1] = hist_last_e()
	([^]bool)(entry)[HIST_TEMP_O] = temp
	([^]bool)(entry)[HIST_APPEND_O] = msg_ext_append
	last := hist_last_e()
	first := hist_first_e()
	if first == nil {
		hist_first_set_e(rawptr(entry))
	}
	if last != nil {
		([^]rawptr)(last)[0] = rawptr(entry)
	}
	tmp := hist_temp_e()
	if tmp == nil {
		hist_temp_set_e(rawptr(entry))
	}
	if !temp {
		hist_len_set_e(hist_len_e() + 1)
	}
	hist_last_set_e(rawptr(entry))
	msg_ext_history = true
	msg_hist_clear(msg_hist_max)
}

is_multihl_g: C.int = 0
msg_keep_entered_g: C.int = 0

@(export)
msg_keep :: proc "c" (s_in: cstring, hl_id: C.int, keep: bool, multiline: bool) -> bool {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	if keep && multiline {
		libc.abort()
	}
	if !emsg_on_display_g && message_filtered(s_in) {
		return true
	}
	if hl_id == 0 {
		set_vim_var_string(5, s_in, -1)
	}
	if msg_keep_entered_g >= 3 {
		return true
	}
	msg_keep_entered_g += 1
	if is_multihl_g == 0 {
		add_hist := true
		if s == keep_msg_g {
			if ([^]u8)(s)[0] != '<' && msg_hist_last_g != nil {
				first_data := (^u8)((^rawptr)(uintptr(msg_hist_last_g) + 32)^)
				if libc.strcmp(s_in, transmute(cstring)(first_data)) == 0 {
					add_hist = false
				}
			} else {
				add_hist = false
			}
		}
		if add_hist {
			msg_hist_add_o(s_in, -1, hl_id)
		}
	}
	if is_multihl_g == 0 {
		msg_start()
	}
	buf := transmute(^u8)(msg_strtrunc(s_in, 0))
	if buf != nil {
		s = buf
	}
	need_clear := true
	if multiline {
		msg_multiline(String{data = transmute(cstring)(s), size = libc.strlen(transmute(cstring)(s))}, hl_id, false, false, &need_clear)
	} else {
		msg_outtrans(transmute(cstring)(s), hl_id, false)
	}
	if need_clear {
		msg_clr_eos()
	}
	retval := true
	if is_multihl_g == 0 {
		retval = msg_end()
	}
	if keep && retval && vim_strsize(s_in) < (Rows - cmdline_row - 1) * Columns + sc_col {
		set_keep_msg(transmute(cstring)(s), 0)
	}
	need_fileinfo_g = false
	xfree(rawptr(buf))
	msg_keep_entered_g -= 1
	return retval
}

@(export)
msg_strtrunc :: proc "c" (s: cstring, force: C.int) -> cstring {
	context = runtime.default_context()
	buf: ^u8 = nil
	if ((msg_scroll == 0 && !need_wait_return_g && shortmess(C.int('T')) && !exmode_active && msg_silent == 0 && !ui_has(K_UIMESSAGES_O)) || force != 0) {
		room: C.int = 0
		length := vim_strsize(s)
		if msg_scrolled != 0 {
			room = (Rows - msg_row) * Columns - 1
		} else {
			room = (Rows - msg_row - 1) * Columns + sc_col - 1
		}
		if length > room && room > 0 {
			length = (room + 2) * 18
			buf = transmute(^u8)(xmalloc(C.size_t(length)))
			trunc_string(s, transmute(^u8)(buf), room, length)
		}
	}
	return transmute(cstring)(buf)
}

@(export)
trunc_string :: proc "c" (s_in: cstring, buf_in: ^u8, room_in: C.int, buflen: C.int) {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	buf := buf_in
	room := room_in - 3
	length: C.int = 0
	e: C.int = 0
	i: C.int = 0
	n: C.int = 0
	if ([^]u8)(s)[0] == 0 {
		if buflen > 0 {
			([^]u8)(buf)[0] = 0
		}
		return
	}
	if room_in < 3 {
		room = 0
	}
	half := room / 2
	for length < half && e < buflen {
		if ([^]u8)(s)[uintptr(e)] == 0 {
			([^]u8)(buf)[uintptr(e)] = 0
			return
		}
		n = ptr2cells(transmute(cstring)(rawptr(uintptr(s) + uintptr(e))))
		if length + n > half {
			break
		}
		length += n
		([^]u8)(buf)[uintptr(e)] = ([^]u8)(s)[uintptr(e)]
		n = utfc_ptr2len(transmute(cstring)(rawptr(uintptr(s) + uintptr(e))))
		for n -= 1; n > 0; n -= 1 {
			e += 1
			if e == buflen {
				break
			}
			([^]u8)(buf)[uintptr(e)] = ([^]u8)(s)[uintptr(e)]
		}
		e += 1
	}
	half = C.int(libc.strlen(s_in))
	i = half
	for {
		half = half - utf_head_off(s_in, transmute(cstring)(rawptr(uintptr(s) + uintptr(half) - 1))) - 1
		n = ptr2cells(transmute(cstring)(rawptr(uintptr(s) + uintptr(half))))
		if length + n > room || half == 0 {
			break
		}
		length += n
		i = half
	}
	if i <= e + 3 {
		if s != buf {
			length = C.int(libc.strlen(s_in))
			if length >= buflen {
				length = buflen - 1
			}
			length = length - e + 1
			if length < 1 {
				([^]u8)(buf)[uintptr(e) - 1] = 0
			} else {
				libc.memmove(rawptr(uintptr(buf) + uintptr(e)), rawptr(uintptr(s) + uintptr(e)), C.size_t(length))
			}
		}
	} else if e + 3 < buflen {
		libc.memmove(rawptr(uintptr(buf) + uintptr(e)), rawptr(transmute(^u8)(cstring("..."))), 3)
		length = C.int(libc.strlen(transmute(cstring)(rawptr(uintptr(s) + uintptr(i))))) + 1
		if length >= buflen - e - 3 {
			length = buflen - e - 3 - 1
		}
		libc.memmove(rawptr(uintptr(buf) + uintptr(e) + 3), rawptr(uintptr(s) + uintptr(i)), C.size_t(length))
		([^]u8)(buf)[uintptr(e + 3 + length) - 1] = 0
	} else {
		([^]u8)(buf)[uintptr(buflen) - 1] = 0
	}
}

KOPT_BO_SHELL_O :: 0x10000

@(export)
verb_msg :: proc "c" (s: cstring) -> C.int {
	context = runtime.default_context()
	verbose_enter()
	n := C.int(0)
	if msg_keep(s, 0, false, false) {
		n = 1
	}
	verbose_leave()
	return n
}

@(export)
msg :: proc "c" (s: cstring, hl_id: C.int) -> bool {
	context = runtime.default_context()
	return msg_keep(s, hl_id, false, false)
}

@(export)
msg_multiline :: proc "c" (str: String, hl_id: C.int, check_int: bool, hist: bool, need_clear: ^bool) {
	context = runtime.default_context()
	s := transmute(^u8)(str.data)
	chunk := s
	for uintptr(s) - uintptr(transmute(^u8)(str.data)) < uintptr(str.size) {
		if check_int && got_int {
			return
		}
		if ([^]u8)(s)[0] == '\n' || ([^]u8)(s)[0] == 9 || ([^]u8)(s)[0] == '\r' || ([^]u8)(s)[0] == 7 {
			msg_outtrans_len(transmute(cstring)(chunk), C.int(uintptr(s) - uintptr(chunk)), hl_id, hist)
			if ([^]u8)(s)[0] != 9 && need_clear^ {
				msg_clr_eos()
				need_clear^ = false
			}
			if ([^]u8)(s)[0] == 7 {
				vim_beep(C.uint(KOPT_BO_SHELL_O))
			} else {
				msg_putchar_hl(C.int(([^]u8)(s)[0]), hl_id)
			}
			chunk = transmute(^u8)(rawptr(uintptr(s) + 1))
		}
		s = transmute(^u8)(rawptr(uintptr(s) + 1))
	}
	if ([^]u8)(chunk)[0] != 0 || chunk == transmute(^u8)(str.data) {
		msg_outtrans_len(transmute(cstring)(chunk), C.int(uintptr(str.size) - (uintptr(chunk) - uintptr(transmute(^u8)(str.data)))), hl_id, hist)
	}
}

@(export) msg_grid_pos_at_flush: C.int = 0

@(export)
msg_id_exists :: proc "c" (id: C.longlong) -> bool {
	context = runtime.default_context()
	return id > 0 && id < msg_id_next
}

ui_ext_msg_set_pos_o :: proc "c" (row: C.int, scrolled: bool) {
	context = runtime.default_context()
	buf: [32]u8
	msgsep := (^u32)(uintptr(curwin) + W_P_FCS_CHARS_OFF + 64)^
	size := schar_get(&buf[0], msgsep)
	mg := (^ScreenGrid)(&msg_grid_u8)
	ui_call_msg_set_pos(C.longlong(mg.handle), C.longlong(row), scrolled, Api_String{data = &buf[0], size = size}, C.longlong(mg.zindex), C.longlong(mg.comp_index))
	mg.pending_comp_index_update = false
}

@(export)
msg_grid_set_pos :: proc "c" (row: C.int, scrolled: bool) {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	if !bool(mg.throttled) {
		ui_ext_msg_set_pos_o(row, scrolled)
		msg_grid_pos_at_flush = row
	}
	msg_grid_pos_g = row
	if mg.chars != nil {
		(^GridView)(&msg_grid_adj_u8).row_offset = -row
	}
}

@(export)
msg_use_grid :: proc "c" () -> bool {
	context = runtime.default_context()
	dg := (^ScreenGrid)(&default_grid_u8)
	return dg.chars != nil && !ui_has(K_UIMESSAGES_O)
}

@(export)
msg_grid_validate :: proc "c" () {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	grid_assign_handle(mg)
	should_alloc := msg_use_grid()
	max_rows := Rows - C.int(p_ch)
	if should_alloc && (mg.rows != Rows || mg.cols != Columns || mg.chars == nil) {
		grid_alloc(mg, Rows, Columns, false, true)
		mg.zindex = KZINDEX_MESSAGES_O
		xfree(mg.dirty_col)
		mg.dirty_col = transmute(^C.int)(xcalloc(C.size_t(Rows), size_of(C.int)))
		pos: C.int = 0
		if (State & MODE_ASKMORE_O) == 0 {
			pos = max(max_rows - msg_scrolled, 0)
		}
		mg.throttled = false
		msg_grid_set_pos(pos, msg_scrolled != 0)
		ui_comp_put_grid_r(rawptr(mg), pos, 0, mg.rows, mg.cols, false, true)
		ui_call_grid_resize(C.longlong(mg.handle), C.longlong(mg.cols), C.longlong(mg.rows))
		msg_scrolled_at_flush_g = msg_scrolled
		mg.mouse_enabled = false
		(^GridView)(&msg_grid_adj_u8).target = mg
	} else if !should_alloc && mg.chars != nil {
		ui_comp_remove_grid_r(rawptr(mg))
		grid_free(mg)
		xfree(mg.dirty_col)
		mg.dirty_col = nil
		ui_call_grid_destroy(C.longlong(mg.handle))
		mg.throttled = false
		(^GridView)(&msg_grid_adj_u8).row_offset = 0
		(^GridView)(&msg_grid_adj_u8).target = (^ScreenGrid)(&default_grid_u8)
		redraw_cmdline_g = true
	} else if mg.chars != nil && msg_scrolled == 0 && msg_grid_pos_g != max_rows {
		diff := msg_grid_pos_g - max_rows
		msg_grid_set_pos(max_rows, false)
		if diff > 0 {
			grid_clear((^GridView)(&msg_grid_adj_u8), Rows - diff, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
		}
	}
	if mg.chars != nil && msg_scrolled == 0 && cmdline_row < msg_grid_pos_g {
		cmdline_row = msg_grid_pos_g
	}
}

last_sourcing_lnum_g: C.int = 0
last_sourcing_name_g: ^u8 = nil
msg_source_recursive_g: bool = false

@(export)
reset_last_sourcing :: proc "c" () {
	context = runtime.default_context()
	xfree(rawptr(last_sourcing_name_g))
	last_sourcing_name_g = nil
	last_sourcing_lnum_g = 0
}

other_sourcing_name_o :: proc "c" () -> bool {
	context = runtime.default_context()
	sname := sourcing_name_o()
	if sname != nil {
		if last_sourcing_name_g != nil {
			return libc.strcmp(transmute(cstring)(sname), transmute(cstring)(last_sourcing_name_g)) != 0
		}
		return true
	}
	return false
}

get_emsg_source_o :: proc "c" () -> ^u8 {
	context = runtime.default_context()
	if sourcing_name_o() != nil && other_sourcing_name_o() {
		sname := estack_sfile_e(ESTACK_NONE_O)
		tofree := sname
		if sname == nil {
			sname = transmute(^u8)(sourcing_name_o())
		}
		buf := transmute(^u8)(xmalloc(C.size_t(libc.strlen(transmute(cstring)(sname))) + 32))
		libc.snprintf(buf, C.size_t(libc.strlen(transmute(cstring)(sname))) + 32, cstring("Error in %s:"), transmute(cstring)(sname))
		xfree(rawptr(tofree))
		return buf
	}
	return nil
}

get_emsg_lnum_o :: proc "c" () -> ^u8 {
	context = runtime.default_context()
	if sourcing_name_o() != nil && (other_sourcing_name_o() || sourcing_lnum_o() != last_sourcing_lnum_g) && sourcing_lnum_o() != 0 {
		buf := transmute(^u8)(xmalloc(64))
		libc.snprintf(buf, 64, cstring("line %4d:"), sourcing_lnum_o())
		return buf
	}
	return nil
}

@(export)
msg_source :: proc "c" (hl_id: C.int) {
	context = runtime.default_context()
	if msg_source_recursive_g {
		return
	}
	msg_source_recursive_g = true
	no_wait_return += 1
	p := get_emsg_source_o()
	if p != nil {
		msg_scroll = 1
		msg(transmute(cstring)(p), hl_id)
		xfree(rawptr(p))
	}
	p = get_emsg_lnum_o()
	if p != nil {
		msg(transmute(cstring)(p), HLF_N_O)
		xfree(rawptr(p))
		last_sourcing_lnum_g = sourcing_lnum_o()
	}
	if sourcing_name_o() == nil || other_sourcing_name_o() {
		xfree(rawptr(last_sourcing_name_g))
		last_sourcing_name_g = nil
		if sourcing_name_o() != nil {
			last_sourcing_name_g = xstrdup(transmute(^u8)(sourcing_name_o()))
			if redirecting() == 0 {
				msg_putchar_hl('\n', hl_id)
			}
		}
	}
	no_wait_return -= 1
	msg_source_recursive_g = false
}

emsg_not_now_o :: proc "c" () -> bool {
	context = runtime.default_context()
	if ((emsg_off > 0 && vim_strchr(transmute(cstring)(p_debug_g), 'm') == nil && vim_strchr(transmute(cstring)(p_debug_g), 't') == nil) || emsg_skip > 0) {
		return true
	}
	return false
}

@(export)
emsg_multiline :: proc "c" (s: cstring, kind: cstring, hl_id: C.int, multiline: bool) -> bool {
	context = runtime.default_context()
	ignore := false
	if emsg_not_now_o() {
		return true
	}
	called_emsg += 1
	severe := emsg_severe_g
	emsg_severe_g = false
	if emsg_off == 0 || vim_strchr(transmute(cstring)(p_debug_g), 't') != nil {
		if cause_errthrow_e(s, multiline, is_multihl_g > 1, severe, &ignore) {
			if !ignore {
				did_emsg_flag += 1
			}
			return true
		}
		if in_assert_fails_g && emsg_assert_fails_msg_g == nil {
			emsg_assert_fails_msg_g = transmute(cstring)(xstrdup(transmute(^u8)(s)))
			emsg_assert_fails_lnum_g = C.long(sourcing_lnum_o())
			xfree(rawptr(emsg_assert_fails_context_g))
			ctx := sourcing_name_o()
			if ctx == nil {
				emsg_assert_fails_context_g = transmute(cstring)(xstrdup(transmute(^u8)(cstring(""))))
			} else {
				emsg_assert_fails_context_g = transmute(cstring)(xstrdup(transmute(^u8)(ctx)))
			}
		}
		set_vim_var_string(VV_ERRMSG_O, s, -1)
		if emsg_silent != 0 {
			if !emsg_noredir_g {
				msg_start()
				p := get_emsg_source_o()
				if p != nil {
					p_len := libc.strlen(transmute(cstring)(p))
					([^]u8)(p)[p_len] = '\n'
					redir_write_o(transmute(cstring)(p), C.ptrdiff_t(p_len) + 1)
					xfree(rawptr(p))
				}
				p = get_emsg_lnum_o()
				if p != nil {
					p_len := libc.strlen(transmute(cstring)(p))
					([^]u8)(p)[p_len] = '\n'
					redir_write_o(transmute(cstring)(p), C.ptrdiff_t(p_len) + 1)
					xfree(rawptr(p))
				}
				redir_write_o(s, C.ptrdiff_t(libc.strlen(s)))
			}
			return true
		}
		ex_exitval_g = 1
		msg_silent = 0
		cmd_silent = false
		if global_busy != 0 {
			global_busy += 1
		}
		if p_eb_g != 0 {
			beep_flush_r()
		} else {
			flush_buffers_e(FLUSH_MINIMAL_O)
		}
		did_emsg_flag += 1
	}
	emsg_on_display_g = true
	if msg_scrolled != 0 {
		need_wait_return_g = true
	}
	msg_ext_set_kind(kind)
	msg_scroll = 1
	save_skip := msg_ext_skip_flush
	msg_ext_skip_flush = true
	msg_source(hl_id)
	msg_nowait = false
	rv := msg_keep(s, hl_id, false, multiline)
	msg_ext_skip_flush = save_skip
	return rv
}

@(export)
emsg :: proc "c" (s: cstring) -> bool {
	context = runtime.default_context()
	return emsg_multiline(s, cstring("emsg"), HLF_E_O, false)
}

@(export)
emsg_invreg :: proc "c" (name: C.int) {
	context = runtime.default_context()
	semsg(cstring("E354: Invalid register name: '%s'"), transchar_buf(nil, name))
}

@(export)
iemsg :: proc "c" (s: cstring) {
	context = runtime.default_context()
	if emsg_not_now_o() {
		return
	}
	emsg(s)
}

@(export)
internal_error :: proc "c" (loc: cstring) {
	context = runtime.default_context()
	siemsg_call_e(cstring("E685: Internal error: %s"), loc)
}

@(export)
msg_trunc :: proc "c" (s_in: ^u8, force: bool, hl_id: C.int) -> ^u8 {
	context = runtime.default_context()
	s := s_in
	msg_hist_add_o(transmute(cstring)(s), -1, hl_id)
	ts := transmute(^u8)(msg_may_trunc(force, transmute(cstring)(s)))
	msg_hist_off_g = true
	n := msg(transmute(cstring)(ts), hl_id)
	msg_hist_off_g = false
	if n {
		return ts
	}
	return nil
}

@(export)
msg_may_trunc :: proc "c" (force: bool, s_in: cstring) -> cstring {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	if ui_has(K_UIMESSAGES_O) {
		return s_in
	}
	room := (Rows - cmdline_row - 1) * Columns + sc_col - 1
	if room > 0 && (force || (shortmess(C.int('t')) && !exmode_active)) && C.int(libc.strlen(s_in)) - room > 0 {
		size := vim_strsize(s_in)
		if size <= room {
			return s_in
		}
		n: C.int = 0
		for size >= room {
			size -= ptr2cells(transmute(cstring)(rawptr(uintptr(s) + uintptr(n))))
			n += utfc_ptr2len(transmute(cstring)(rawptr(uintptr(s) + uintptr(n))))
		}
		n -= 1
		s = transmute(^u8)(rawptr(uintptr(s) + uintptr(n)))
		([^]u8)(s)[0] = '<'
	}
	return transmute(cstring)(s)
}

@(export)
hl_msg_free :: proc "c" (hlmsg: HlMessage_O) {
	context = runtime.default_context()
	n := C.size_t(0)
	for n < hlmsg.size {
		xfree(([^]rawptr)(hlmsg.items)[n])
		n += 1
	}
	xfree(hlmsg.items)
}

@(export)
smsg_v :: proc "c" (hl_id: C.int, s: cstring, ap: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), s, ap)
	if msg(transmute(cstring)(&IObuff[0]), hl_id) {
		return 1
	}
	return 0
}

@(export)
smsg_keep_v :: proc "c" (hl_id: C.int, s: cstring, ap: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), s, ap)
	if msg_keep(transmute(cstring)(&IObuff[0]), hl_id, true, false) {
		return 1
	}
	return 0
}

semsgv_o :: proc "c" (fmt: cstring, ap: ^libc.va_list) -> bool {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), fmt, ap)
	return emsg(transmute(cstring)(&IObuff[0]))
}

@(export)
semsg_v :: proc "c" (fmt: cstring, ap: ^libc.va_list) -> bool {
	context = runtime.default_context()
	return semsgv_o(fmt, ap)
}

semsg_multiline_buf_g: [8192]u8

@(export)
semsg_multiline_v :: proc "c" (kind: cstring, fmt: cstring, ap: ^libc.va_list) -> bool {
	context = runtime.default_context()
	if emsg_not_now_o() {
		return true
	}
	vim_vsnprintf(&semsg_multiline_buf_g[0], 8192, fmt, ap)
	return emsg_multiline(transmute(cstring)(&semsg_multiline_buf_g[0]), kind, HLF_E_O, true)
}

@(export)
siemsg_v :: proc "c" (s: cstring, ap: ^libc.va_list) {
	context = runtime.default_context()
	if emsg_not_now_o() {
		return
	}
	semsgv_o(s, ap)
}

msg_semsg_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	s := transmute(cstring)(([^]rawptr)(argv)[0])
	emsg(s)
	xfree(rawptr(([^]rawptr)(argv)[0]))
}

@(export)
msg_schedule_semsg_v :: proc "c" (fmt: cstring, ap: ^libc.va_list) {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), fmt, ap)
	s := xstrdup(&IObuff[0])
	loop_schedule_deferred(&main_loop, event_create(msg_semsg_event_o, rawptr(s)))
}

msg_semsg_multiline_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	s := transmute(cstring)(([^]rawptr)(argv)[0])
	emsg_multiline(s, cstring("emsg"), HLF_E_O, true)
	xfree(rawptr(([^]rawptr)(argv)[0]))
}

@(export)
msg_schedule_semsg_multiline_v :: proc "c" (fmt: cstring, ap: ^libc.va_list) {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), fmt, ap)
	s := xstrdup(&IObuff[0])
	loop_schedule_deferred(&main_loop, event_create(msg_semsg_multiline_event_o, rawptr(s)))
}

foreign _ {
	@(link_name = "apply_autocmds_group")
	apply_autocmds_group_e :: proc "c" (event: C.int, fname: cstring, fname_io: cstring, force: bool, group: C.int, buf: rawptr, eap: rawptr, data: ^Api_Object, with_buf: bool) -> bool ---
	@(link_name = "syn_check_group")
	syn_check_group_e :: proc "c" (name: ^u8, len: C.size_t) -> C.int ---
	// msg_did_scroll/msg_grid_scroll_discount: use drawscreen.odin's — direct.
	// ui_active: use ui.odin's port — call directly.
	@(link_name = "cmdmsg_rl")
	cmdmsg_rl_g: bool
}

SB_CLEAR_NONE_O :: 0
SB_CLEAR_ALL_O :: 1
SB_CLEAR_CMDLINE_BUSY_O :: 2
SB_CLEAR_CMDLINE_DONE_O :: 3
VV_SCROLLSTART_O :: 46
KOPT_RDB_NOTHROTTLE_O :: 0x02
MSGCHUNK_NEXT_O :: 0
MSGCHUNK_PREV_O :: 8
MSGCHUNK_EOL_O :: 16
MSGCHUNK_COL_O :: 20
MSGCHUNK_HL_O :: 24
MSGCHUNK_TEXT_O :: 28
	// UPD_VALID_O already in optionstr.odin — reuse directly.

last_msgchunk_g: rawptr = nil
do_clear_sb_text_g: C.int = SB_CLEAR_NONE_O

@(export)
msg_line_flush :: proc "c" () {
	context = runtime.default_context()
	if cmdmsg_rl_g {
		grid_line_mirror(msg_grid_cols_o())
	}
	grid_line_flush_if_valid_row()
}

msg_grid_cols_o :: proc "c" () -> C.int {
	context = runtime.default_context()
	return (^ScreenGrid)(&msg_grid_u8).cols
}

@(export)
msg_cursor_goto :: proc "c" (row: C.int, col: C.int) {
	context = runtime.default_context()
	r := row
	c := col
	if cmdmsg_rl_g {
		c = Columns - 1 - col
	}
	grid := grid_adjust((^GridView)(&msg_grid_adj_u8), &r, &c)
	ui_grid_cursor_goto((^ScreenGrid)(grid).handle, r, c)
}

@(export)
msg_scrollsize :: proc "c" () -> C.int {
	context = runtime.default_context()
	extra := C.int(0)
	if p_ch > 0 || msg_scrolled > 1 {
		extra = 1
	}
	return msg_scrolled + C.int(p_ch) + extra
}

@(export)
msg_do_throttle :: proc "c" () -> bool {
	context = runtime.default_context()
	return msg_use_grid() && (rdb_flags_g & KOPT_RDB_NOTHROTTLE_O) == 0
}

@(export)
msg_scroll_up :: proc "c" (may_throttle: bool, zerocmd: bool) {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	if may_throttle && msg_do_throttle() {
		mg.throttled = true
	}
	msg_did_scroll_g = true
	if msg_grid_pos_g > 0 {
		msg_grid_set_pos(msg_grid_pos_g - 1, !zerocmd)
		if zerocmd && mg.chars != nil {
			grid_clear_line(mg, mg.line_offset[0], mg.cols, false)
		}
	} else {
		grid_del_lines(mg, 0, 1, mg.rows, 0, mg.cols)
		libc.memmove(rawptr(mg.dirty_col), rawptr(uintptr(mg.dirty_col) + 4), C.size_t(mg.rows - 1) * 4)
		([^]C.int)(mg.dirty_col)[uintptr(mg.rows) - 1] = 0
	}
	grid_clear((^GridView)(&msg_grid_adj_u8), Rows - 1, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
}

inc_msg_scrolled_o :: proc "c" () {
	context = runtime.default_context()
	if ([^]u8)(transmute(^u8)(get_vim_var_str(VV_SCROLLSTART_O)))[0] == 0 {
		p_data := sourcing_name_o()
		tofree: ^u8 = nil
		p_size: C.size_t = 0
		if p_data == nil {
			p_data = cstring("Unknown")
			p_size = 7
		} else {
			tofreesize := libc.strlen(p_data) + 40
			tofree = transmute(^u8)(xmalloc(tofreesize))
			p_size = vim_snprintf_safelen_e(tofree, tofreesize, cstring("%s line %ld"), p_data, C.longlong(sourcing_lnum_o()))
			p_data = transmute(cstring)(tofree)
		}
		set_vim_var_string(VV_SCROLLSTART_O, p_data, C.ptrdiff_t(p_size))
		xfree(rawptr(tofree))
	}
	msg_scrolled += 1
	set_must_redraw(UPD_VALID_O)
}

EVENT_PROGRESS_O :: 88
PROGRESS_TARGET_CMD_O :: 1

MsgID_O :: struct {
	type: C.int,
	_pad: [4]u8,
	data: [24]u8,
}
#assert(size_of(MsgID_O) == 32)

// Single-copy moves from message.c (Batch 11): C statics deleted, C uses extern.
@(export) msg_ext_kind: cstring = nil
@(export) msg_ext_trigger: cstring = nil
@(export) msg_ext_id: MsgID_O = {type = 2, _pad = {0, 0, 0, 0}, data = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
@(export) msg_id_next: i64 = 1
@(export) progress_msg_target: C.int = PROGRESS_TARGET_CMD_O
@(export) msg_ext_append: bool = false
@(export) msg_ext_history: bool = false
@(export) keep_msg_more: bool = false
@(export) redir_col: C.int = 0

int64_obj_o :: proc "c" (i: i64) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 2}
	([^]i64)(&obj.data[0])[0] = i
	return obj
}

str_obj_o :: proc "c" (s: String) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 4}
	([^]String)(&obj.data[0])[0] = s
	return obj
}

@(export)
do_autocmd_progress :: proc "c" (msg_id: MsgID_O, hlmsg: HlMessage_O, msg_data: rawptr) {
	context = runtime.default_context()
	if !has_event(EVENT_PROGRESS_O) {
		return
	}
	n := hlmsg.size
	arr_items := transmute(^Api_Object)(xmalloc(n * 32))
	for i: C.size_t = 0; i < n; i += 1 {
		chunk_text := ([^]String)(uintptr(hlmsg.items) + uintptr(i) * 24)[0]
		([^]Api_Object)(arr_items)[i] = str_obj_o(chunk_text)
	}
	arr := Api_Array{size = n, capacity = n, items = arr_items}
	ditems := transmute(^Key_Value_Pair)(xmalloc(7 * 48))
	dn: C.size_t = 0
	idc := msg_id
	id_obj := Api_Object{t = idc.type}
	libc.memmove(rawptr(&id_obj.data[0]), rawptr(&idc.data[0]), 16)
	put_obj(ditems, &dn, cstring("id"), 2, id_obj)
	arrval := Api_Object{t = 5}
	([^]Api_Array)(&arrval.data[0])[0] = arr
	put_obj(ditems, &dn, cstring("text"), 4, arrval)
	if msg_data != nil && (^i64)(uintptr(msg_data) + 16)^ >= 0 {
		put_obj(ditems, &dn, cstring("percent"), 7, int64_obj_o((^i64)(uintptr(msg_data) + 16)^))
	}
	put_obj(ditems, &dn, cstring("source"), 6, str_obj_o(([^]String)(uintptr(msg_data) + 0)[0]))
	put_obj(ditems, &dn, cstring("status"), 6, str_obj_o(([^]String)(uintptr(msg_data) + 40)[0]))
	put_obj(ditems, &dn, cstring("title"), 5, str_obj_o(([^]String)(uintptr(msg_data) + 24)[0]))
	dval := Api_Object{t = 6}
	([^]Api_Dict)(&dval.data[0])[0] = ([^]Api_Dict)(uintptr(msg_data) + 56)[0]
	put_obj(ditems, &dn, cstring("data"), 4, dval)
	d := Api_Dict{size = dn, capacity = 7, items = ditems}
	dobj := Api_Object{t = 6}
	([^]Api_Dict)(&dobj.data[0])[0] = d
	fname := cstring("")
	if msg_data != nil && ([^]C.size_t)(uintptr(msg_data) + 8)[0] > 0 {
		fname = transmute(cstring)(([^]rawptr)(uintptr(msg_data) + 0)[0])
	}
	apply_autocmds_group_e(EVENT_PROGRESS_O, fname, nil, true, AUGROUP_ALL, nil, nil, &dobj, false)
	xfree(rawptr(arr_items))
	xfree(rawptr(ditems))
}

put_obj :: proc(ditems: ^Key_Value_Pair, dn: ^C.size_t, key: cstring, klen: C.size_t, val: Api_Object) {
	([^]Key_Value_Pair)(ditems)[dn^] = Key_Value_Pair{key = Api_String{data = transmute(^u8)(key), size = klen}, value = val}
	dn^ += 1
}

format_progress_message_o :: proc "c" (hlmsg: ^HlMessage_O, msg_data: rawptr) -> bool {
	context = runtime.default_context()
	title_size := ([^]C.size_t)(uintptr(msg_data) + 32)[0]
	percent := (^i64)(uintptr(msg_data) + 16)^
	nbase := hlmsg.size
	extra: C.size_t = 0
	if title_size != 0 {
		extra += 2
	}
	if percent >= 0 {
		extra += 1
	}
	if extra == 0 {
		return false
	}
	items := transmute(^u8)(xmalloc((hlmsg.size + extra) * 24))
	n: C.size_t = 0
	if title_size != 0 {
		status_data := ([^]rawptr)(uintptr(msg_data) + 40)[0]
		hl_id: C.int = 0
		if status_data == nil {
			hl_id = 0
		} else if libc.strcmp(transmute(cstring)(status_data), cstring("success")) == 0 {
			hl_id = syn_check_group_e(transmute(^u8)(cstring("OkMsg")), 5)
		} else if libc.strcmp(transmute(cstring)(status_data), cstring("failed")) == 0 {
			hl_id = syn_check_group_e(transmute(^u8)(cstring("ErrorMsg")), 8)
		} else if libc.strcmp(transmute(cstring)(status_data), cstring("running")) == 0 {
			hl_id = syn_check_group_e(transmute(^u8)(cstring("MoreMsg")), 7)
		} else if libc.strcmp(transmute(cstring)(status_data), cstring("cancel")) == 0 {
			hl_id = syn_check_group_e(transmute(^u8)(cstring("WarningMsg")), 10)
		}
		title_copy := xmemdupz(rawptr(([^]rawptr)(uintptr(msg_data) + 24)[0]), title_size)
		([^]rawptr)(items)[n * 3 + 0] = rawptr(title_copy)
		([^]C.size_t)(items)[n * 3 + 1] = title_size
		([^]C.int)(items)[n * 6 + 4] = hl_id
		n += 1
		colon := xmemdupz(rawptr(transmute(^u8)(cstring(": "))), 2)
		([^]rawptr)(items)[n * 3 + 0] = rawptr(colon)
		([^]C.size_t)(items)[n * 3 + 1] = 2
		([^]C.int)(items)[n * 6 + 4] = 0
		n += 1
	}
	if percent >= 0 {
		percent_buf: [10]u8
		libc.snprintf(&percent_buf[0], 10, cstring("%3ld%% "), C.long(percent))
		pct := xmemdupz(rawptr(&percent_buf[0]), libc.strlen(transmute(cstring)(&percent_buf[0])))
		([^]rawptr)(items)[n * 3 + 0] = rawptr(pct)
		([^]C.size_t)(items)[n * 3 + 1] = libc.strlen(transmute(cstring)(&percent_buf[0]))
		([^]C.int)(items)[n * 6 + 4] = syn_check_group_e(transmute(^u8)(cstring("WarningMsg")), 10)
		n += 1
	}
	for i: C.size_t = 0; i < hlmsg.size; i += 1 {
		src_text := ([^]String)(uintptr(hlmsg.items) + uintptr(i) * 24)[0]
		src_hl := ([^]C.int)(uintptr(hlmsg.items) + uintptr(i) * 24 + 16)[0]
		dup := xmemdupz(rawptr(transmute(^u8)(src_text.data)), src_text.size)
		([^]rawptr)(items)[n * 3 + 0] = rawptr(dup)
		([^]C.size_t)(items)[n * 3 + 1] = src_text.size
		([^]C.int)(items)[n * 6 + 4] = src_hl
		n += 1
	}
	hlmsg.size = nbase + extra
	hlmsg.cap = nbase + extra
	hlmsg.items = rawptr(items)
	return true
}

@(export)
msg_multihl :: proc "c" (id_in: MsgID_O, hlmsg_in: HlMessage_O, kind: cstring, history: bool, err: bool, msg_data: rawptr, needs_msg_clear: ^bool) -> MsgID_O {
	context = runtime.default_context()
	id := id_in
	hlmsg := hlmsg_in
	if id.type == 0 {
		id.type = 2
		([^]i64)(&id.data[0])[0] = msg_id_next
		msg_id_next += 1
	} else if id.type == 2 && !msg_id_exists(([^]i64)(&id.data[0])[0]) {
		libc.abort()
	}
	hl_msg_updated := false
	if kind != nil && strequal(kind, cstring("progress")) {
		do_autocmd_progress(id, hlmsg, msg_data)
		if (progress_msg_target & PROGRESS_TARGET_CMD_O) == 0 {
			needs_msg_clear^ = true
			return id
		}
		if msg_data != nil && format_progress_message_o(&hlmsg, msg_data) {
			needs_msg_clear^ = true
			hl_msg_updated = true
		}
	}
	no_wait_return += 1
	msg_start()
	msg_clr_eos()
	need_clear := false
	if kind != nil {
		msg_ext_set_kind(kind)
	}
	msg_ext_skip_flush = true
	msg_ext_id = id
	for i: C.size_t = 0; i < hlmsg.size; i += 1 {
		chunk_text := ([^]String)(uintptr(hlmsg.items) + uintptr(i) * 24)[0]
		chunk_hl := ([^]C.int)(uintptr(hlmsg.items) + uintptr(i) * 24 + 16)[0]
		is_multihl_g += 1
		if err {
			emsg_multiline(transmute(cstring)(chunk_text.data), kind, chunk_hl, true)
		} else {
			msg_multiline(chunk_text, chunk_hl, true, false, &need_clear)
		}
		if !(!ui_has(K_UIMESSAGES_O) || kind == nil || msg_ext_kind == kind) {
			libc.abort()
		}
	}
	if history && hlmsg.size != 0 {
		msg_hist_add_multihl_o(hlmsg, false)
	}
	msg_ext_skip_flush = false
	is_multihl_g = 0
	no_wait_return -= 1
	msg_end()
	if hl_msg_updated && !(history && hlmsg.size != 0) {
		hl_msg_free(hlmsg)
	}
	return id
}

@(export)
msg_progress :: proc "c" (s_in: ^u8, id: cstring, status: cstring, hl_id: C.int, hist: bool, trunc: bool) -> ^u8 {
	context = runtime.default_context()
	s := s_in
	if hist && (!trunc || ui_has(K_UIMESSAGES_O)) {
		msg_hist_add_o(transmute(cstring)(s), -1, 0)
	}
	if trunc {
		s = transmute(^u8)(msg_may_trunc(false, transmute(cstring)(s)))
	}
	clear := false
	data_buf: [80]u8
	src := String{data = cstring("nvim"), size = 4}
	libc.memmove(rawptr(&data_buf[0]), rawptr(&src), 16)
	([^]i64)(&data_buf[16])[0] = -1
	st := String{data = status, size = libc.strlen(status)}
	libc.memmove(rawptr(&data_buf[40]), rawptr(&st), 16)
	chunk_items := transmute(^u8)(xmalloc(24))
	([^]rawptr)(chunk_items)[0] = rawptr(s)
	([^]C.size_t)(chunk_items)[1] = libc.strlen(transmute(cstring)(s))
	([^]C.int)(chunk_items)[4] = hl_id
	chunks := HlMessage_O{size = 1, cap = 1, items = rawptr(chunk_items)}
	mid := MsgID_O{type = 4}
	mid_str := String{data = id, size = libc.strlen(id)}
	libc.memmove(rawptr(&mid.data[0]), rawptr(&mid_str), 16)
	msg_ext_no_fast()
	msg_multihl(mid, chunks, cstring("progress"), false, false, rawptr(&data_buf[0]), &clear)
	xfree(rawptr(chunk_items))
	ui_flush()
	return s
}

@(export)
msg_starthere :: proc "c" () {
	context = runtime.default_context()
	lines_left = cmdline_row
	msg_didany_g = false
}

@(export)
msg_putchar :: proc "c" (c: C.int) {
	context = runtime.default_context()
	msg_putchar_hl(c, 0)
}

@(export)
msg_putchar_hl :: proc "c" (c: C.int, hl_id: C.int) {
	context = runtime.default_context()
	buf: [7]u8
	if IS_SPECIAL(c) {
		buf[0] = u8(K_SPECIAL_O)
		if c == 0x80 {
			buf[1] = u8(KS_SPECIAL)
		} else if c == 0 {
			buf[1] = u8(KS_ZERO)
		} else {
			buf[1] = u8(C.int(-c) & 0xff)
		}
		if c == 0x80 || c == 0 {
			buf[2] = u8(KE_FILLER)
		} else {
			buf[2] = u8((C.int(-c) >> 8) & 0xff)
		}
		buf[3] = 0
	} else {
		buf[utf_char2bytes(c, transmute(^u8)(&buf[0]))] = 0
	}
	msg_puts_hl(transmute(cstring)(&buf[0]), hl_id, false)
}

@(export)
msg_outnum :: proc "c" (n: C.int) {
	context = runtime.default_context()
	buf: [20]u8
	libc.snprintf(&buf[0], 20, cstring("%d"), n)
	msg_puts(transmute(cstring)(&buf[0]))
}

@(export)
msg_home_replace :: proc "c" (fname: cstring) {
	context = runtime.default_context()
	msg_home_replace_hl_o(fname, 0)
}

msg_home_replace_hl_o :: proc "c" (fname: cstring, hl_id: C.int) {
	context = runtime.default_context()
	name := home_replace_save(nil, fname)
	msg_outtrans(name, hl_id, false)
	xfree(rawptr(name))
}

@(export)
msg_advance :: proc "c" (col: C.int) {
	context = runtime.default_context()
	if msg_silent != 0 {
		msg_col = col
		return
	}
ccol := col
	if ccol > Columns - 1 {
		ccol = Columns - 1
	}
	for msg_col < ccol {
		msg_putchar(' ')
	}
}

@(export)
msg_outtrans :: proc "c" (str: cstring, hl_id: C.int, hist: bool) -> C.int {
	context = runtime.default_context()
	return msg_outtrans_len(str, C.int(libc.strlen(str)), hl_id, hist)
}

@(export)
msg_outtrans_one :: proc "c" (p_in: cstring, hl_id: C.int, hist: bool) -> cstring {
	context = runtime.default_context()
	p := transmute(^u8)(p_in)
	l := utfc_ptr2len(p_in)
	if l > 1 {
		msg_outtrans_len(p_in, l, hl_id, hist)
		return transmute(cstring)(rawptr(uintptr(p) + uintptr(l)))
	}
	hid := hl_id
	if hl_id == 0 {
		hid = HLF_8_O
	}
	msg_puts_hl(transmute(cstring)(transchar_byte_buf(nil, C.int(([^]u8)(p)[0]))), hid, hist)
	return transmute(cstring)(rawptr(uintptr(p) + 1))
}

@(export)
msg_outtrans_len :: proc "c" (msgstr_in: cstring, len_in: C.int, hl_id: C.int, hist: bool) -> C.int {
	context = runtime.default_context()
	retval: C.int = 0
	str := transmute(^u8)(msgstr_in)
	plain_start := str
	len := len_in
	save_got_int := got_int
	got_int = false
	if hist {
		msg_hist_add_o(msgstr_in, len, hl_id)
	}
	if msg_silent == 0 && len > 0 && msg_row >= cmdline_row && msg_col == 0 {
		clear_cmdline_g = false
		mode_displayed_g = false
	}
	for len -= 1; len >= 0 && !got_int; len -= 1 {
		mb_l := utfc_ptr2len_len_r(transmute(cstring)(str), len + 1)
		if mb_l > 1 {
			c := utf_ptr2char(transmute(cstring)(str))
			if vim_isprintc(c) {
				retval += utf_ptr2cells_r(transmute(cstring)(str))
			} else {
				if uintptr(str) > uintptr(plain_start) {
					msg_puts_len(transmute(cstring)(plain_start), C.ptrdiff_t(uintptr(str) - uintptr(plain_start)), hl_id, hist)
				}
				plain_start = transmute(^u8)(rawptr(uintptr(str) + uintptr(mb_l)))
				hid2 := hl_id
				if hl_id == 0 {
					hid2 = HLF_8_O
				}
				msg_puts_hl(transmute(cstring)(transchar_buf(nil, c)), hid2, false)
				retval += char2cells(c)
			}
			len -= mb_l - 1
			str = transmute(^u8)(rawptr(uintptr(str) + uintptr(mb_l)))
		} else {
			s := transchar_byte_buf(nil, C.int(([^]u8)(str)[0]))
			if ([^]u8)(transmute(^u8)(s))[1] != 0 {
				if uintptr(str) > uintptr(plain_start) {
					msg_puts_len(transmute(cstring)(plain_start), C.ptrdiff_t(uintptr(str) - uintptr(plain_start)), hl_id, hist)
				}
				plain_start = transmute(^u8)(rawptr(uintptr(str) + 1))
				hid3 := hl_id
				if hl_id == 0 {
					hid3 = HLF_8_O
				}
				msg_puts_hl(transmute(cstring)(s), hid3, false)
				retval += C.int(libc.strlen(transmute(cstring)(s)))
			} else {
				retval += 1
			}
			str = transmute(^u8)(rawptr(uintptr(str) + 1))
		}
	}
	if (uintptr(str) > uintptr(plain_start) || plain_start == transmute(^u8)(msgstr_in)) && !got_int {
		msg_puts_len(transmute(cstring)(plain_start), C.ptrdiff_t(uintptr(str) - uintptr(plain_start)), hl_id, hist)
	}
	got_int = got_int || save_got_int
	return retval
}

@(export)
msg_make :: proc "c" (arg_in: cstring) {
	context = runtime.default_context()
	arg := skipwhite(arg_in)
	i: C.int = 5
	for ([^]u8)(transmute(^u8)(arg))[0] != 0 && i >= 0 {
		if ([^]u8)(transmute(^u8)(arg))[0] != ([^]u8)(transmute(^u8)(cstring("eeffoc")))[uintptr(i)] {
			break
		}
		arg = transmute(cstring)(rawptr(uintptr(transmute(^u8)(arg)) + 1))
		i -= 1
	}
	if i < 0 {
		msg_putchar('\n')
		rs := cstring("Plon#dqg#vxjduB")
		for j: C.int = 0; ([^]u8)(transmute(^u8)(rs))[uintptr(j)] != 0; j += 1 {
			msg_putchar(C.int(([^]u8)(transmute(^u8)(rs))[uintptr(j)]) - 3)
		}
	}
}

@(export)
msg_outtrans_special :: proc "c" (strstart: cstring, from: bool, maxlen: C.int) -> C.int {
	context = runtime.default_context()
	if strstart == nil {
		return 0
	}
	str := transmute(^u8)(strstart)
	start := str
	retval: C.int = 0
	hl_id: C.int = HLF_8_O
	for ([^]u8)(str)[0] != 0 {
		text: cstring
		first := str == start
		second_last := ([^]u8)(transmute(^u8)(rawptr(uintptr(str) + 1)))[0] == 0
		if ((first || second_last) && ([^]u8)(str)[0] == ' ') {
			text = cstring("<Space>")
			str = transmute(^u8)(rawptr(uintptr(str) + 1))
		} else {
			sp := transmute(cstring)(str)
			text = str2special(&sp, from, 0)
			str = transmute(^u8)(sp)
		}
		if ([^]u8)(transmute(^u8)(text))[0] != 0 && ([^]u8)(transmute(^u8)(text))[1] == 0 {
			text = transmute(cstring)(transchar_byte_buf(nil, C.int(([^]u8)(transmute(^u8)(text))[0])))
		}
		length := vim_strsize(text)
		if maxlen > 0 && retval + length >= maxlen {
			break
		}
		put_hl: C.int = 0
		if length > 1 && utfc_ptr2len(text) <= 1 {
			put_hl = hl_id
		}
		msg_puts_hl(text, put_hl, false)
		retval += length
	}
	return retval
}

msg_sb_start_o :: proc "c" (mps: rawptr) -> rawptr {
	context = runtime.default_context()
	mp := mps
	for mp != nil && ([^]rawptr)(mp)[1] != nil && !([^]bool)(mp)[16] {
		mp = ([^]rawptr)(mp)[1]
	}
	return mp
}

// disp_sb_line_o deferred to Batch 11 (needs msg_puts_display).

@(export)
sb_text_start_cmdline :: proc "c" () {
	context = runtime.default_context()
	if do_clear_sb_text_g == SB_CLEAR_CMDLINE_BUSY_O {
		sb_text_restart_cmdline()
	} else {
		msg_sb_eol()
		do_clear_sb_text_g = SB_CLEAR_CMDLINE_BUSY_O
	}
}

@(export)
sb_text_restart_cmdline :: proc "c" () {
	context = runtime.default_context()
	do_clear_sb_text_g = SB_CLEAR_CMDLINE_BUSY_O
	if last_msgchunk_g == nil || ([^]bool)(last_msgchunk_g)[MSGCHUNK_EOL_O] {
		return
	}
	tofree := msg_sb_start_o(last_msgchunk_g)
	last_msgchunk_g = ([^]rawptr)(tofree)[1]
	if last_msgchunk_g != nil {
		([^]rawptr)(last_msgchunk_g)[0] = nil
	}
	for tofree != nil {
		tofree_next := ([^]rawptr)(tofree)[0]
		xfree(tofree)
		tofree = tofree_next
	}
}

@(export)
sb_text_end_cmdline :: proc "c" () {
	context = runtime.default_context()
	do_clear_sb_text_g = SB_CLEAR_CMDLINE_DONE_O
}

@(export)
clear_sb_text :: proc "c" (all: bool) {
	context = runtime.default_context()
	if all {
		for last_msgchunk_g != nil {
			mp := ([^]rawptr)(last_msgchunk_g)[1]
			xfree(last_msgchunk_g)
			last_msgchunk_g = mp
		}
	} else {
		if last_msgchunk_g == nil {
			return
		}
		prev_slot := rawptr(uintptr(msg_sb_start_o(last_msgchunk_g)) + MSGCHUNK_PREV_O)
		for ([^]rawptr)(prev_slot)[0] != nil {
			mp := ([^]rawptr)(([^]rawptr)(prev_slot)[0])[1]
			xfree(([^]rawptr)(prev_slot)[0])
			([^]rawptr)(prev_slot)[0] = mp
		}
	}
}

@(export)
may_clear_sb_text :: proc "c" () {
	context = runtime.default_context()
	msg_ext_ui_flush()
	do_clear_sb_text_g = SB_CLEAR_ALL_O
	do_clear_hist_temp_set_e(true)
}

@(export)
msg_sb_eol :: proc "c" () {
	context = runtime.default_context()
	if last_msgchunk_g != nil {
		([^]bool)(last_msgchunk_g)[MSGCHUNK_EOL_O] = true
	}
}

@(export)
msg_use_printf :: proc "c" () -> C.int {
	context = runtime.default_context()
	if embedded_mode || ui_active() != 0 || ui_has(K_UIMESSAGES_O) {
		return 0
	}
	return 1
}

msg_puts_printf_o :: proc "c" (str_in: cstring, maxlen: C.ptrdiff_t) {
	context = runtime.default_context()
	str := transmute(^u8)(str_in)
	s := str
	buf: [7]u8
	p: ^u8
	if on_print_g.type != 0 {
		argv: [1]Typval_T
		argv[0].v_type = VAR_STRING
		argv[0].v_lock = VAR_UNLOCKED
		argv[0].vval = rawptr(transmute(^u8)(str_in))
		rettv := Typval_T{}
		callback_call(rawptr(&on_print_g), 1, &argv[0], &rettv)
		tv_clear(&rettv)
		return
	}
	for (maxlen < 0 || C.ptrdiff_t(uintptr(s) - uintptr(str)) < maxlen) && ([^]u8)(s)[0] != 0 {
		length := utfc_ptr2len(transmute(cstring)(s))
		if !(silent_mode && p_verbose == 0) {
			p = &buf[0]
			if ([^]u8)(s)[0] == '\n' && !info_message_g2 && !silent_mode && !headless_mode {
				([^]u8)(p)[0] = '\r'
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			libc.memmove(rawptr(p), rawptr(s), C.size_t(length))
			([^]u8)(p)[uintptr(length)] = 0
			if info_message_g2 {
				libc.printf(cstring("%s"), transmute(cstring)(&buf[0]))
			} else {
				libc.fprintf(libc.stderr, cstring("%s"), transmute(cstring)(&buf[0]))
			}
		}
		cw := utf_char2cells_e(utf_ptr2char(transmute(cstring)(s)))
		if ([^]u8)(s)[0] == '\r' || ([^]u8)(s)[0] == '\n' {
			msg_col = 0
			msg_didany_g = false
		} else {
			msg_col += C.int(cw)
			msg_didany_g = true
		}
		s = transmute(^u8)(rawptr(uintptr(s) + uintptr(length)))
	}
}

@(export)
msg_reset_scroll :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	(^ScreenGrid)(&msg_grid_u8).throttled = false
	msg_grid_set_pos(Rows - C.int(p_ch), false)
	clear_cmdline_g = true
	mg := (^ScreenGrid)(&msg_grid_u8)
	if mg.chars != nil {
		i: C.int = 0
		limit := msg_scrollsize()
		if mg.rows < limit {
			limit = mg.rows
		}
		for i < limit {
			grid_clear_line(mg, mg.line_offset[C.size_t(i)], mg.cols, false)
			i += 1
		}
	}
	msg_scrolled = 0
	msg_scrolled_at_flush_g = 0
	msg_grid_scroll_discount_g = 0
}

@(export)
msg_ui_refresh :: proc "c" () {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	if ui_has(K_UIMULTIGRID_O) && mg.chars != nil {
		ui_call_grid_resize(C.longlong(mg.handle), C.longlong(mg.cols), C.longlong(mg.rows))
		ui_ext_msg_set_pos_o(msg_grid_pos_g, msg_scrolled != 0)
	}
}

@(export)
msg_ui_flush :: proc "c" () {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	if ui_has(K_UIMULTIGRID_O) && mg.chars != nil && mg.pending_comp_index_update {
		ui_ext_msg_set_pos_o(msg_grid_pos_g, msg_scrolled != 0)
	}
}

@(export)
msg_end_prompt :: proc "c" () {
	context = runtime.default_context()
	need_wait_return_g = false
	emsg_on_display_g = false
	cmdline_row = msg_row
	msg_col = 0
	msg_clr_eos()
	lines_left = -1
}

// —— Batch 11: message leaves (filter/keep/more/ext-setters/puts) ——

foreign _ {
	@(link_name = "keep_msg_hl_id")
	keep_msg_hl_id_g: C.int
}

HLF_T_O :: 23
CMOD_FILTER_REGMATCH_OFF_O :: 24
CMOD_FILTER_FORCE_OFF_O :: 200

@(export)
message_filtered :: proc "c" (s: cstring) -> bool {
	context = runtime.default_context()
	rmp := (^Regmatch_T)(uintptr(&cmdmod_cmod_flags) + CMOD_FILTER_REGMATCH_OFF_O)
	if rmp.regprog == nil {
		return false
	}
	matched := vim_regexec_r(rmp, transmute(^u8)(s), 0) != 0
	force := (^bool)(uintptr(&cmdmod_cmod_flags) + CMOD_FILTER_FORCE_OFF_O)^
	if force {
		return matched
	}
	return !matched
}

@(export)
set_keep_msg :: proc "c" (s: cstring, hl_id: C.int) {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	xfree(keep_msg_g)
	if s != nil && msg_silent == 0 {
		keep_msg_g = transmute(^u8)(xstrdup(transmute(^u8)(s)))
	} else {
		keep_msg_g = nil
	}
	keep_msg_more = false
	keep_msg_hl_id_g = hl_id
}

@(export)
messaging :: proc "c" () -> bool {
	context = runtime.default_context()
	if p_lz_g != 0 && char_avail_r() && !KeyTyped {
		return false
	}
	return p_ch > 0 || ui_has(K_UIMESSAGES_O)
}

@(export)
msgmore :: proc "c" (n: C.int) {
	context = runtime.default_context()
	if global_busy != 0 || !messaging() {
		return
	}
	if keep_msg_g != nil && !keep_msg_more {
		return
	}
	pn := n
	if pn < 0 {
		pn = -pn
	}
	if i64(pn) > p_report {
		if n > 0 {
			vim_snprintf(&msg_buf_g[0], C.size_t(480), ngettext_r(cstring("%d more line"), cstring("%d more lines"), C.long(pn)), pn)
		} else {
			vim_snprintf(&msg_buf_g[0], C.size_t(480), ngettext_r(cstring("%d line less"), cstring("%d fewer lines"), C.long(pn)), pn)
		}
		if got_int {
			xstrlcat(&msg_buf_g[0], transmute(^u8)(_t(cstring(" (Interrupted)"))), C.size_t(480))
		}
		if msg(transmute(cstring)(&msg_buf_g[0]), 0) {
			set_keep_msg(transmute(cstring)(&msg_buf_g[0]), 0)
			keep_msg_more = true
		}
	}
}

// MSG_BUF_LEN_O already in ex_cmds.odin (480) — reuse directly.

@(export)
msg_ext_set_kind :: proc "c" (msg_kind: cstring) {
	context = runtime.default_context()
	msg_ext_ui_flush()
	msg_ext_kind = msg_kind
	if !msg_ext_append {
		redir_col = 0
	}
	if libc.strcmp(cstring("list_cmd"), msg_kind) == 0 {
		msg_ext_no_fast()
	}
}

@(export)
msg_ext_set_append :: proc "c" (append: bool) {
	context = runtime.default_context()
	msg_ext_ui_flush()
	msg_ext_append = append
}

@(export)
msg_ext_set_trigger :: proc "c" (trigger: cstring) {
	context = runtime.default_context()
	msg_ext_ui_flush()
	msg_ext_trigger = trigger
}

@(export)
msg_ext_no_fast :: proc "c" () {
	context = runtime.default_context()
	msg_ext_ui_flush()
	msg_ext_fast_g = false
}

@(export)
msg_puts :: proc "c" (s: cstring) {
	context = runtime.default_context()
	msg_puts_hl(s, 0, false)
}

@(export)
msg_puts_title :: proc "c" (s: cstring) {
	context = runtime.default_context()
	ss := s
	if ui_has(K_UIMESSAGES_O) && ([^]u8)(transmute(^u8)(ss))[0] == '\n' {
		ss = transmute(cstring)(rawptr(uintptr(transmute(^u8)(ss)) + 1))
	}
	msg_puts_hl(ss, HLF_T_O, false)
}

@(export)
msg_puts_hl :: proc "c" (s: cstring, hl_id: C.int, hist: bool) {
	context = runtime.default_context()
	msg_puts_len(s, -1, hl_id, hist)
}

// —— Batch 12: redirect/verbose/warning leaves ——

// Single-copy moves from message.c (Batch 12): C statics deleted, C uses extern.
@(export) verbose_fd: rawptr = nil
@(export) verbose_did_open: bool = false

pre_verbose_kind_g: cstring = nil
verbose_kind_g: cstring = cstring("verbose")

// VV_WARNINGMSG_O already in change.odin; E_NOTOPEN_S already in eval.odin — reuse both.

@(export)
redirecting :: proc "c" () -> C.int {
	context = runtime.default_context()
	if redir_fd_g != nil || ([^]u8)(p_vfile_g)[0] != 0 || redir_reg != 0 || redir_vname_g || capture_ga_g != nil {
		return 1
	}
	return 0
}

@(export)
verbose_enter :: proc "c" () {
	context = runtime.default_context()
	if ([^]u8)(p_vfile_g)[0] != 0 {
		msg_silent += 1
	}
	if !msg_ext_skip_verbose_e {
		if msg_ext_kind != verbose_kind_g {
			pre_verbose_kind_g = msg_ext_kind
		}
		msg_ext_set_kind(verbose_kind_g)
	}
	msg_ext_skip_verbose_e = false
}

@(export)
verbose_leave :: proc "c" () {
	context = runtime.default_context()
	if ([^]u8)(p_vfile_g)[0] != 0 {
		msg_silent -= 1
		if msg_silent < 0 {
			msg_silent = 0
		}
	}
	if pre_verbose_kind_g != nil {
		msg_ext_set_kind(pre_verbose_kind_g)
		pre_verbose_kind_g = nil
	}
}

@(export)
verbose_enter_scroll :: proc "c" () {
	context = runtime.default_context()
	verbose_enter()
	if ([^]u8)(p_vfile_g)[0] == 0 {
		msg_scroll = 1
	}
}

@(export)
verbose_leave_scroll :: proc "c" () {
	context = runtime.default_context()
	verbose_leave()
	if ([^]u8)(p_vfile_g)[0] == 0 {
		cmdline_row = msg_row
	}
}

@(export)
verbose_stop :: proc "c" () {
	context = runtime.default_context()
	if verbose_fd != nil {
		libc.fclose(transmute(^libc.FILE)(verbose_fd))
		verbose_fd = nil
	}
	verbose_did_open = false
}

@(export)
verbose_open :: proc "c" () -> C.int {
	context = runtime.default_context()
	if verbose_fd == nil && !verbose_did_open {
		verbose_did_open = true
		verbose_fd = os_fopen(transmute(cstring)(p_vfile_g), cstring("a"))
		if verbose_fd == nil {
			semsg(cstring(E_NOTOPEN_S), transmute(cstring)(p_vfile_g))
			return 0
		}
	}
	return 1
}

@(export)
give_warning :: proc "c" (message: cstring, hl: bool, hist: bool) {
	context = runtime.default_context()
	if msg_silent != 0 {
		return
	}
	save_msg_hist_off := msg_hist_off_g
	msg_hist_off_g = !hist
	no_wait_return += 1
	set_vim_var_string(VV_WARNINGMSG_O, message, -1)
	xfree(keep_msg_g)
	keep_msg_g = nil
	if hl {
		keep_msg_hl_id_g = HLF_W_O
	} else {
		keep_msg_hl_id_g = 0
	}
	if msg_ext_kind == nil {
		msg_ext_set_kind(cstring("wmsg"))
	}
	if msg(transmute(cstring)(message), keep_msg_hl_id_g) && msg_scrolled == 0 {
		set_keep_msg(message, keep_msg_hl_id_g)
	}
	msg_didout_g = false
	msg_nowait = true
	msg_col = 0
	no_wait_return -= 1
	msg_hist_off_g = save_msg_hist_off
}

@(export)
swmsg_v :: proc "c" (hl: bool, fmt: cstring, ap: ^libc.va_list) {
	context = runtime.default_context()
	vim_vsnprintf(&IObuff[0], C.size_t(IOSIZE_O), fmt, ap)
	give_warning(transmute(cstring)(&IObuff[0]), hl, true)
}

// —— Batch 13: history-clear + messagesopt + str2special ——

// Single-copy moves from message.c (Batch 13): C statics deleted, C uses extern.
@(export) msg_flags: C.int = 0x01 | 0x04 | 0x08
@(export) msg_wait: C.int = 0
@(export) msg_hist_max: C.int = 500

foreign _ {
	@(link_name = "p_mopt")
	p_mopt_g: ^u8
	@(link_name = "mb_unescape")
	mb_unescape_e :: proc "c" (pp: ^cstring) -> cstring ---
}

KOPT_MOPT_HIT_ENTER_O :: 0x01
KOPT_MOPT_WAIT_O :: 0x02
KOPT_MOPT_HISTORY_O :: 0x04
KOPT_MOPT_PROGRESS_O :: 0x08

msg_hist_free_msg_o :: proc "c" (entry: rawptr) {
	context = runtime.default_context()
	next := ([^]rawptr)(entry)[0]
	prev := ([^]rawptr)(entry)[1]
	if next == nil {
		hist_last_set_e(prev)
	} else {
		([^]rawptr)(next)[1] = prev
	}
	if prev == nil {
		hist_first_set_e(next)
	} else {
		([^]rawptr)(prev)[0] = next
	}
	if entry == hist_temp_e() {
		hist_temp_set_e(next)
	}
	hlmsg := HlMessage_O{size = ([^]C.size_t)(entry)[2], cap = ([^]C.size_t)(entry)[3], items = ([^]rawptr)(entry)[4]}
	hl_msg_free(hlmsg)
	xfree(([^]rawptr)(entry)[5])
	xfree(entry)
}

@(export)
msg_hist_clear :: proc "c" (keep: C.int) {
	context = runtime.default_context()
	for hist_len_e() > keep || (keep == 0 && hist_first_e() != nil) {
		first := hist_first_e()
		delta: C.int = 0
		if !([^]bool)(first)[HIST_TEMP_O] {
			delta = 1
		}
		hist_len_set_e(hist_len_e() - delta)
		msg_hist_free_msg_o(first)
	}
}

@(export)
msg_hist_clear_temp :: proc "c" () {
	context = runtime.default_context()
	for hist_temp_e() != nil {
		next := ([^]rawptr)(hist_temp_e())[0]
		if ([^]bool)(hist_temp_e())[HIST_TEMP_O] {
			msg_hist_free_msg_o(hist_temp_e())
		}
		hist_temp_set_e(next)
	}
}

@(export)
messagesopt_changed :: proc "c" () -> C.int {
	context = runtime.default_context()
	flags_new: C.int = 0
	wait_new: C.int = 0
	history_new: C.int = 0
	target_flag: C.int = 0
	p := p_mopt_g
	for {
		if strnequal(transmute(cstring)(p), cstring("hit-enter"), 9) {
			p = transmute(^u8)(rawptr(uintptr(p) + 9))
			flags_new |= KOPT_MOPT_HIT_ENTER_O
		} else if strnequal(transmute(cstring)(p), cstring("wait:"), 5) && ascii_isdigit(([^]u8)(p)[5]) {
			p = transmute(^u8)(rawptr(uintptr(p) + 5))
			pp := p
			wait_new = getdigits_int(&pp, false, max(C.int))
			p = pp
			flags_new |= KOPT_MOPT_WAIT_O
		} else if strnequal(transmute(cstring)(p), cstring("history:"), 8) && ascii_isdigit(([^]u8)(p)[8]) {
			p = transmute(^u8)(rawptr(uintptr(p) + 8))
			pp := p
			history_new = getdigits_int(&pp, false, max(C.int))
			p = pp
			flags_new |= KOPT_MOPT_HISTORY_O
		} else if strnequal(transmute(cstring)(p), cstring("progress:"), 9) {
			p = transmute(^u8)(rawptr(uintptr(p) + 9))
			flags_new |= KOPT_MOPT_PROGRESS_O
			if ([^]u8)(p)[0] == 'c' {
				target_flag |= PROGRESS_TARGET_CMD_O
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
		}
		if ([^]u8)(p)[0] != ',' && ([^]u8)(p)[0] != 0 {
			return 0
		}
		if ([^]u8)(p)[0] == ',' {
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		} else {
			break
		}
	}
	if (flags_new & (KOPT_MOPT_HIT_ENTER_O | KOPT_MOPT_WAIT_O)) == 0 {
		return 0
	}
	if (flags_new & KOPT_MOPT_HISTORY_O) == 0 {
		return 0
	}
	if history_new < 0 {
		libc.abort()
	}
	if history_new > 10000 {
		return 0
	}
	if wait_new < 0 {
		libc.abort()
	}
	if wait_new > 10000 {
		return 0
	}
	msg_flags = flags_new
	msg_wait = wait_new
	progress_msg_target = target_flag
	msg_hist_max = history_new
	msg_hist_clear(msg_hist_max)
	return 1
}

str2special_buf_g: [7]u8

@(export)
str2special :: proc "c" (sp: ^cstring, replace_spaces: bool, replace_others: C.int) -> cstring {
	context = runtime.default_context()
	p := mb_unescape_e(sp)
	if p != nil {
		return p
	}
	str := transmute(^u8)(sp^)
	c: C.int = C.int(([^]u8)(str)[0])
	modifiers: C.int = 0
	special := false
	if c == 0x80 && ([^]u8)(str)[1] != 0 && ([^]u8)(str)[2] != 0 {
		if ([^]u8)(str)[1] == u8(KS_MODIFIER) {
			modifiers = C.int(([^]u8)(str)[2])
			str = transmute(^u8)(rawptr(uintptr(str) + 3))
			c = C.int(([^]u8)(str)[0])
		}
		if c == 0x80 && ([^]u8)(str)[1] != 0 && ([^]u8)(str)[2] != 0 {
			a := C.int(([^]u8)(str)[1])
			b := C.int(([^]u8)(str)[2])
			if a == 254 {
				c = 0x80
			} else if a == 255 {
				c = K_ZERO
			} else {
				c = -(a + (b << 8))
			}
			str = transmute(^u8)(rawptr(uintptr(str) + 2))
		}
		if c < 0 || modifiers != 0 {
			special = true
		}
	}
	if !(c < 0) && C.int(utf8len_tab_g[u8(c)]) > 1 {
		sp^ = transmute(cstring)(str)
		p = mb_unescape_e(sp)
		if p != nil {
			c = utf_ptr2char(p)
		} else {
			sp^ = transmute(cstring)(rawptr(uintptr(str) + 1))
		}
	} else {
		adv := 1
		if ([^]u8)(str)[0] == 0 {
			adv = 0
		}
		sp^ = transmute(cstring)(rawptr(uintptr(str) + uintptr(adv)))
	}
	if special || c < 32 || (replace_spaces && c == 32) || (replace_others != 0 && c == '<') || (replace_others == 1 && (c == '|' || c == '\\')) {
		return get_special_key_name(c, modifiers)
	}
	str2special_buf_g[0] = u8(c)
	str2special_buf_g[1] = 0
	return transmute(cstring)(&str2special_buf_g[0])
}

@(export)
str2special_save :: proc "c" (str: cstring, replace_spaces: bool, replace_others: C.int) -> cstring {
	context = runtime.default_context()
	ga := Garray{}
	ga_init(&ga, 1, 40)
	p := str
	for ([^]u8)(transmute(^u8)(p))[0] != 0 {
		ga_concat(&ga, str2special(&p, replace_spaces, replace_others))
	}
	ga_append(&ga, 0)
	return transmute(cstring)(ga.ga_data)
}

@(export)
str2special_arena :: proc "c" (str: cstring, replace_spaces: bool, replace_others: C.int, arena: rawptr) -> cstring {
	context = runtime.default_context()
	p := str
	length: C.size_t = 0
	for ([^]u8)(transmute(^u8)(p))[0] != 0 {
		length += libc.strlen(str2special(&p, replace_spaces, replace_others))
	}
	buf := transmute(^u8)(arena_alloc(arena, length + 1, false))
	pos: C.size_t = 0
	p = str
	for ([^]u8)(transmute(^u8)(p))[0] != 0 {
		s := str2special(&p, replace_spaces, replace_others)
		s_len := libc.strlen(s)
		libc.memmove(rawptr(uintptr(buf) + uintptr(pos)), rawptr(transmute(^u8)(s)), s_len)
		pos += s_len
	}
	([^]u8)(buf)[pos] = 0
	return transmute(cstring)(buf)
}

@(export)
str2specialbuf :: proc "c" (sp_in: cstring, buf_in: ^u8, len_in: C.size_t) {
	context = runtime.default_context()
	sp := sp_in
	buf := buf_in
	length := len_in
	for ([^]u8)(transmute(^u8)(sp))[0] != 0 {
		s := str2special(&sp, false, 0)
		s_len := libc.strlen(s)
		if length <= s_len {
			break
		}
		libc.memmove(rawptr(buf), rawptr(transmute(^u8)(s)), s_len)
		buf = transmute(^u8)(rawptr(uintptr(buf) + uintptr(s_len)))
		length -= s_len
	}
	([^]u8)(buf)[0] = 0
}

// —— Batch 14: display-support plains (dormant; activate with msg_puts_display) ——

redir_write_o :: proc "c" (str_in: cstring, maxlen: C.ptrdiff_t) {
	context = runtime.default_context()
	s := transmute(^u8)(str_in)
	str := s
	if maxlen == 0 {
		return
	}
	if redir_off_g {
		return
	}
	if ([^]u8)(p_vfile_g)[0] != 0 && verbose_fd == nil {
		verbose_open()
	}
	if redirecting() != 0 {
		if ([^]u8)(s)[0] != '\n' && ([^]u8)(s)[0] != '\r' {
			for redir_col < msg_col {
				if capture_ga_g != nil {
					ga_concat_len(transmute(^Garray)(capture_ga_g), cstring(" "), 1)
				}
				if redir_reg != 0 {
					write_reg_contents(redir_reg, cstring(" "), 1, 1)
				} else if redir_vname_g {
					var_redir_str(cstring(" "), -1)
				} else if redir_fd_g != nil {
					libc.fprintf(transmute(^libc.FILE)(redir_fd_g), cstring("%s"), cstring(" "))
				}
				if verbose_fd != nil {
					libc.fprintf(transmute(^libc.FILE)(verbose_fd), cstring("%s"), cstring(" "))
				}
				redir_col += 1
			}
		}
		length: C.size_t = C.size_t(maxlen)
		if maxlen == -1 {
			length = libc.strlen(str_in)
		}
		if capture_ga_g != nil {
			ga_concat_len(transmute(^Garray)(capture_ga_g), str_in, length)
		}
		if redir_reg != 0 {
			write_reg_contents(redir_reg, str_in, i64(length), 1)
		}
		if redir_vname_g {
			var_redir_str(str_in, C.int(maxlen))
		}
		for ([^]u8)(s)[0] != 0 && (maxlen < 0 || C.int(uintptr(s) - uintptr(str)) < C.int(maxlen)) {
			if redir_reg == 0 && !redir_vname_g && capture_ga_g == nil {
				if redir_fd_g != nil {
					libc.fputc(C.int(([^]u8)(s)[0]), transmute(^libc.FILE)(redir_fd_g))
				}
			}
			if verbose_fd != nil {
				libc.fputc(C.int(([^]u8)(s)[0]), transmute(^libc.FILE)(verbose_fd))
			}
			if ([^]u8)(s)[0] == '\r' || ([^]u8)(s)[0] == '\n' {
				redir_col = 0
			} else if ([^]u8)(s)[0] == '\t' {
				redir_col += (8 - redir_col % 8)
			} else {
				redir_col += 1
			}
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
		}
		if msg_silent != 0 {
			msg_col = redir_col
		}
	}
}

store_sb_text_o :: proc "c" (sb_str: ^cstring, s_in: cstring, hl_id: C.int, sb_col: ^C.int, finish: bool) {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	if do_clear_sb_text_g == SB_CLEAR_ALL_O || do_clear_sb_text_g == SB_CLEAR_CMDLINE_DONE_O {
		clear_sb_text(do_clear_sb_text_g == SB_CLEAR_ALL_O)
		msg_sb_eol()
		if do_clear_sb_text_g == SB_CLEAR_CMDLINE_DONE_O && uintptr(s) > uintptr(transmute(^u8)(sb_str^)) && ([^]u8)(transmute(^u8)(sb_str^))[0] == '\n' {
			sb_str^ = transmute(cstring)(rawptr(uintptr(transmute(^u8)(sb_str^)) + 1))
		}
		do_clear_sb_text_g = SB_CLEAR_NONE_O
	}
	if uintptr(s) > uintptr(transmute(^u8)(sb_str^)) {
		mp := transmute(^u8)(xmalloc(28 + C.size_t(uintptr(s) - uintptr(transmute(^u8)(sb_str^))) + 1))
		([^]bool)(mp)[MSGCHUNK_EOL_O] = finish
		([^]C.int)(mp)[MSGCHUNK_COL_O / 4] = sb_col^
		([^]C.int)(mp)[MSGCHUNK_HL_O / 4] = hl_id
		libc.memmove(rawptr(uintptr(mp) + MSGCHUNK_TEXT_O), rawptr(transmute(^u8)(sb_str^)), C.size_t(uintptr(s) - uintptr(transmute(^u8)(sb_str^))))
		([^]u8)(mp)[MSGCHUNK_TEXT_O + (uintptr(s) - uintptr(transmute(^u8)(sb_str^)))] = 0
		if last_msgchunk_g == nil {
			last_msgchunk_g = rawptr(mp)
			([^]rawptr)(mp)[1] = nil
		} else {
			([^]rawptr)(mp)[1] = last_msgchunk_g
			([^]rawptr)(last_msgchunk_g)[0] = rawptr(mp)
			last_msgchunk_g = rawptr(mp)
		}
		([^]rawptr)(mp)[0] = nil
	} else if finish && last_msgchunk_g != nil {
		([^]bool)(last_msgchunk_g)[MSGCHUNK_EOL_O] = true
	}
	sb_str^ = transmute(cstring)(s)
	sb_col^ = 0
}

// —— Batch 15: more-prompt + display plains (dormant; activate with msg_puts_len) ——

// Single-copy moves from message.c (Batch 15): C statics deleted, C uses extern.
@(export) msg_ext_chunks: rawptr = nil
@(export) msg_ext_last_chunk: Garray = {ga_len = 0, ga_maxlen = 0, ga_itemsize = 1, ga_growsize = 40, ga_data = nil}
@(export) msg_ext_last_attr: C.int = -1
@(export) msg_ext_last_hl_id: C.int = 0
@(export) confirm_buttons: ^u8 = nil
@(export) confirm_msg_used: C.int = 0

foreign _ {
	@(link_name = "p_more")
	p_more_g: C.int
	@(link_name = "quit_more")
	quit_more_g: bool
	// get_keystroke now defined in input.odin — call directly.
	@(link_name = "typeahead_noflush")
	typeahead_noflush_e :: proc "c" (c: C.int) ---
	@(link_name = "did_wait_return")
	did_wait_return_g: bool
	@(link_name = "redrawing_cmdline")
	redrawing_cmdline_g: bool
}

HLF_M_O :: 10
K_PAGEUP_O :: -(107 + (80 << 8))
K_PAGEDOWN_O :: -(107 + (78 << 8))
K_LEFTMOUSE_O :: -(253 + (44 << 8))

msg_moremsg_o :: proc "c" (full: bool) {
	context = runtime.default_context()
	attr := hl_combine_attr_r(hl_attr_active_g[HLF_MSG_O], hl_attr_active_g[HLF_M_O])
	grid_line_start((^GridView)(&msg_grid_adj_u8), Rows - 1)
	length := grid_line_puts(0, cstring("-- More --"), -1, attr)
	if full {
		length += grid_line_puts(length, cstring(" SPACE/d/j: screen/page/line down, b/u/k: up, q: quit "), -1, attr)
	}
	grid_line_cursor_goto(length)
	grid_line_flush()
}

disp_sb_line_o :: proc "c" (row: C.int, smp: rawptr) -> rawptr {
	context = runtime.default_context()
	mp := smp
	for {
		msg_row = row
		msg_col = (^C.int)(uintptr(mp) + MSGCHUNK_COL_O)^
		p := transmute(^u8)(uintptr(mp) + MSGCHUNK_TEXT_O)
		msg_puts_display_o(transmute(cstring)(p), -1, (^C.int)(uintptr(mp) + MSGCHUNK_HL_O)^, true)
		if ([^]bool)(mp)[MSGCHUNK_EOL_O] || ([^]rawptr)(mp)[0] == nil {
			break
		}
		mp = ([^]rawptr)(mp)[0]
	}
	return ([^]rawptr)(mp)[0]
}

msg_ext_emit_chunk_o :: proc "c" () {
	context = runtime.default_context()
	if msg_ext_chunks == nil {
		msg_ext_init_chunks_o()
	}
	if msg_ext_last_attr == -1 {
		return
	}
	items := transmute(^Api_Object)(xmalloc(3 * 32))
	([^]Api_Object)(items)[0] = int64_obj_o(i64(msg_ext_last_attr))
	msg_ext_last_attr = -1
	taken_data := msg_ext_last_chunk.ga_data
	taken_len := msg_ext_last_chunk.ga_len
	msg_ext_last_chunk.ga_data = nil
	msg_ext_last_chunk.ga_len = 0
	msg_ext_last_chunk.ga_maxlen = 0
	([^]Api_Object)(items)[1] = str_obj_o(String{data = transmute(cstring)(taken_data), size = C.size_t(taken_len)})
	([^]Api_Object)(items)[2] = int64_obj_o(i64(msg_ext_last_hl_id))
	chunkobj := Api_Object{t = 5}
	([^]Api_Array)(&chunkobj.data[0])[0] = Api_Array{size = 3, capacity = 3, items = items}
	outer_size := ([^]C.size_t)(msg_ext_chunks)[0]
	outer_cap := ([^]C.size_t)(msg_ext_chunks)[1]
	if outer_size >= outer_cap {
		newcap := outer_cap * 2
		if newcap == 0 {
			newcap = 4
		}
		outer_items := transmute(^Api_Object)(xmalloc(newcap * 32))
		if outer_size > 0 {
			libc.memmove(rawptr(outer_items), ([^]rawptr)(msg_ext_chunks)[2], outer_size * 32)
			xfree(([^]rawptr)(msg_ext_chunks)[2])
		}
		([^]C.size_t)(msg_ext_chunks)[1] = newcap
		([^]rawptr)(msg_ext_chunks)[2] = rawptr(outer_items)
	}
	([^]Api_Object)(([^]rawptr)(msg_ext_chunks)[2])[outer_size] = chunkobj
	([^]C.size_t)(msg_ext_chunks)[0] = outer_size + 1
}

msg_ext_init_chunks_o :: proc "c" () -> rawptr {
	context = runtime.default_context()
	tofree := msg_ext_chunks
	msg_ext_chunks = xmalloc(24)
	([^]C.size_t)(msg_ext_chunks)[0] = 0
	([^]C.size_t)(msg_ext_chunks)[1] = 0
	([^]rawptr)(msg_ext_chunks)[2] = nil
	msg_col = 0
	return tofree
}

msg_puts_display_o :: proc "c" (str_in: cstring, maxlen_in: C.int, hl_id: C.int, recurse: bool) {
	context = runtime.default_context()
	s := transmute(^u8)(str_in)
	str0 := s
	sb_str := str_in
	sb_col := msg_col
	maxlen := maxlen_in
	attr := C.int(0)
	if hl_id != 0 {
		attr = syn_id2attr_r(hl_id)
	}
	did_wait_return_g = false
	if ui_has(K_UIMESSAGES_O) {
		if attr != msg_ext_last_attr {
			msg_ext_emit_chunk_o()
			msg_ext_last_attr = attr
			msg_ext_last_hl_id = hl_id
		}
		length: C.size_t = libc.strlen(str_in)
		if maxlen >= 0 {
			length = 0
			for length < C.size_t(maxlen) && ([^]u8)(transmute(^u8)(str_in))[length] != 0 {
				length += 1
			}
		}
		ga_concat_len(&msg_ext_last_chunk, str_in, length)
		lastline := xmemrchr(str_in, '\n', length)
		if lastline != nil {
			maxlen -= C.int(uintptr(transmute(^u8)(lastline)) - uintptr(transmute(^u8)(str_in)))
		}
		p := str_in
		if lastline != nil {
			p = transmute(cstring)(rawptr(uintptr(transmute(^u8)(lastline)) + 1))
		}
		col := C.int(0)
		if maxlen < 0 {
			col = C.int(mb_string2cells_s(p))
		} else {
			col = C.int(mb_string2cells_len(p, C.size_t(maxlen)))
		}
		if lastline != nil {
			msg_col = col
		} else {
			msg_col += col
		}
		return
	}
	print_attr := hl_combine_attr_r(hl_attr_active_g[HLF_MSG_O], attr)
	msg_grid_validate()
	cmdline_was_last_drawn_g = redrawing_cmdline_g
	msg_row_pending := C.int(-1)
	for {
		if msg_col >= Columns {
			if p_more_g != 0 && !recurse {
				store_sb_text_o(&sb_str, transmute(cstring)(s), hl_id, &sb_col, true)
			}
			if msg_no_more != 0 && lines_left == 0 {
				break
			}
			msg_col = 0
			msg_row += 1
			msg_didout_g = false
		}
		if msg_row >= Rows {
			msg_row = Rows - 1
			if msg_no_more != 0 && lines_left == 0 {
				break
			}
			if !recurse {
				if msg_row_pending >= 0 {
					msg_line_flush()
					msg_row_pending = -1
				}
				msg_scroll_up(true, false)
				inc_msg_scrolled_o()
				need_wait_return_g = true
				redraw_cmdline_g = true
				if cmdline_row > 0 && !exmode_active {
					cmdline_row -= 1
				}
				if lines_left > 0 {
					lines_left -= 1
				}
				if p_more_g != 0 && lines_left == 0 && State != MODE_HITRETURN_O && msg_no_more == 0 && !exmode_active {
					if do_more_prompt_o(0) {
						s = confirm_buttons
					}
					if quit_more_g {
						return
					}
				}
			}
		}
		if !((maxlen < 0 || C.int(uintptr(s) - uintptr(str0)) < maxlen) && ([^]u8)(s)[0] != 0) {
			break
		}
		if msg_row != msg_row_pending && (([^]u8)(s)[0] >= 0x20 || ([^]u8)(s)[0] == 9) {
			if msg_row_pending >= 0 {
				msg_line_flush()
			}
			grid_line_start((^GridView)(&msg_grid_adj_u8), msg_row)
			msg_row_pending = msg_row
		}
		if ([^]u8)(s)[0] >= 0x20 {
			cw := utf_ptr2cells_r(transmute(cstring)(s))
			l := utfc_ptr2len(transmute(cstring)(s))
			if maxlen >= 0 {
				l = utfc_ptr2len_len_r(transmute(cstring)(s), C.int(uintptr(str0) + uintptr(maxlen) - uintptr(s)))
			}
			if cw > 1 && msg_col == Columns - 1 {
				grid_line_puts(msg_col, cstring(">"), 1, hl_attr_active_g[HLF_AT_O])
				cw = 1
			} else {
				grid_line_puts(msg_col, transmute(cstring)(s), l, print_attr)
				s = transmute(^u8)(rawptr(uintptr(s) + uintptr(l)))
			}
			msg_didout_g = true
			msg_col += cw
		} else {
			ch := ([^]u8)(s)[0]
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
			if ch == '\n' {
				msg_didout_g = false
				msg_col = 0
				msg_row += 1
				if p_more_g != 0 && !recurse {
					store_sb_text_o(&sb_str, transmute(cstring)(s), hl_id, &sb_col, true)
				}
			} else if ch == '\r' {
				msg_col = 0
			} else if ch == '\b' {
				if msg_col != 0 {
					msg_col -= 1
				}
			} else if ch == 9 {
				for {
					grid_line_puts(msg_col, cstring(" "), 1, print_attr)
					msg_col += 1
					if msg_col == Columns {
						break
					}
					if (msg_col & 7) == 0 {
						break
					}
				}
			} else if ch == 7 {
				vim_beep(C.uint(KOPT_BO_SHELL_O))
			}
		}
	}
	if msg_row_pending >= 0 {
		msg_line_flush()
	}
	msg_cursor_goto(msg_row, msg_col)
	if p_more_g != 0 && !recurse {
		store_sb_text_o(&sb_str, transmute(cstring)(s), hl_id, &sb_col, false)
	}
	msg_check()
}

do_more_prompt_o :: proc "c" (typed_char: C.int) -> bool {
	context = runtime.default_context()
	used_typed_char := typed_char
	oldState := State
	c: C.int = 0
	retval := false
	to_redraw := false
	mp_last: rawptr = nil
	mp: rawptr = nil
	no_need_more := headless_mode && !embedded_mode && ui_active() == 0
	if no_need_more || do_more_entered_g || (State == MODE_HITRETURN_O && typed_char == 0) {
		return false
	}
	do_more_entered_g = true
	if typed_char == 'G' {
		mp_last = msg_sb_start_o(last_msgchunk_g)
		i: C.int = 0
		for i < Rows - 2 && mp_last != nil && ([^]rawptr)(mp_last)[1] != nil {
			mp_last = msg_sb_start_o(([^]rawptr)(mp_last)[1])
			i += 1
		}
	}
	State = MODE_ASKMORE_O
	setmouse()
	if typed_char == 0 {
		msg_moremsg_o(false)
	}
	for {
		if used_typed_char != 0 {
			c = used_typed_char
			used_typed_char = 0
		} else {
			c = get_keystroke(resize_events_g)
		}
		toscroll: C.int = 0
		if c == 8 || c == K_BS || c == 'k' || c == K_UP {
			toscroll = -1
		} else if c == 13 || c == 10 || c == 'j' || c == K_DOWN {
			toscroll = 1
		} else if c == 'u' {
			toscroll = -(Rows / 2)
		} else if c == 'd' {
			toscroll = Rows / 2
		} else if c == 'b' || c == 2 || c == K_PAGEUP_O {
			toscroll = -(Rows - 1)
		} else if c == ' ' || c == 'f' || c == 6 || c == K_PAGEDOWN_O || c == K_LEFTMOUSE_O {
			toscroll = Rows - 1
		} else if c == 'g' {
			toscroll = -999999
		} else if c == 'G' {
			toscroll = 999999
			lines_left = 999999
		} else if c == ':' || c == 'q' || c == 3 || c == 27 {
			if c == ':' && confirm_msg_used == 0 {
				typeahead_noflush_e(C.int(':'))
				cmdline_row = Rows - 1
				skip_redraw_g = true
				need_wait_return_g = false
			}
			if confirm_msg_used != 0 {
				retval = true
			} else {
				got_int = true
				quit_more_g = true
			}
			lines_left = Rows - 1
		} else if c == K_EVENT_O {
			multiqueue_process_events(resize_events_g)
			to_redraw = true
		} else {
			msg_moremsg_o(true)
			continue
		}
		if toscroll != 0 && to_redraw {
			libc.abort()
		}
		if toscroll != 0 || to_redraw {
			if toscroll < 0 || to_redraw {
				if mp_last == nil {
					mp = msg_sb_start_o(last_msgchunk_g)
				} else if ([^]rawptr)(mp_last)[1] != nil {
					mp = msg_sb_start_o(([^]rawptr)(mp_last)[1])
				} else {
					mp = nil
				}
				i: C.int = 0
				for i < Rows - 2 && mp != nil && ([^]rawptr)(mp)[1] != nil {
					mp = msg_sb_start_o(([^]rawptr)(mp)[1])
					i += 1
				}
				if mp != nil && (([^]rawptr)(mp)[1] != nil || to_redraw) {
					i = 0
					for i > toscroll {
						if mp == nil || ([^]rawptr)(mp)[1] == nil {
							break
						}
						mp = msg_sb_start_o(([^]rawptr)(mp)[1])
						if mp_last == nil {
							mp_last = msg_sb_start_o(last_msgchunk_g)
						} else {
							mp_last = msg_sb_start_o(([^]rawptr)(mp_last)[1])
						}
						i -= 1
					}
					if toscroll == -1 && !to_redraw {
						mg := (^ScreenGrid)(&msg_grid_u8)
						grid_ins_lines(mg, 0, 1, Rows, 0, Columns)
						grid_clear_line(mg, mg.line_offset[0], mg.cols, false)
						disp_sb_line_o(0, mp)
					} else {
						grid_clear((^GridView)(&msg_grid_adj_u8), 0, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
						i = 0
						for mp != nil && i < Rows - 1 {
							mp = disp_sb_line_o(i, mp)
							msg_scrolled += 1
							i += 1
						}
						to_redraw = false
					}
					toscroll = 0
				}
			} else {
				if cmdline_row >= Rows && !ui_has(K_UIMESSAGES_O) {
					msg_scroll_up(true, false)
					msg_scrolled += 1
				}
				for toscroll > 0 && mp_last != nil {
					if msg_do_throttle() && !(^ScreenGrid)(&msg_grid_u8).throttled {
						msg_scrolled_at_flush_g -= 1
						msg_grid_scroll_discount_g += 1
					}
					msg_scroll_up(true, false)
					inc_msg_scrolled_o()
					grid_clear((^GridView)(&msg_grid_adj_u8), Rows - 2, Rows - 1, 0, Columns, hl_attr_active_g[HLF_MSG_O])
					mp_last = disp_sb_line_o(Rows - 2, mp_last)
					toscroll -= 1
				}
			}
			if toscroll <= 0 {
				grid_clear((^GridView)(&msg_grid_adj_u8), Rows - 1, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
				msg_moremsg_o(false)
				continue
			}
			lines_left = toscroll
		}
		break
	}
	grid_clear((^GridView)(&msg_grid_adj_u8), Rows - 1, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
	redraw_cmdline_g = true
	clear_cmdline_g = false
	mode_displayed_g = false
	State = oldState
	setmouse()
	if quit_more_g {
		msg_row = Rows - 1
		msg_col = 0
	}
	do_more_entered_g = false
	return retval
}

do_more_entered_g: bool = false

foreign _ {
	// msg_scrolled_ign: use ex_cmds.odin's msg_scrolled_ign_g — direct.
}

@(export)
msg_puts_len :: proc "c" (str_in: cstring, len_in: C.ptrdiff_t, hl_id: C.int, hist: bool) {
	context = runtime.default_context()
	if len_in >= 0 && libc.memchr(rawptr(transmute(^u8)(str_in)), 0, C.size_t(len_in)) != nil {
		libc.abort()
	}
	redir_write_o(str_in, len_in)
	if msg_silent != 0 || ([^]u8)(transmute(^u8)(str_in))[0] == 0 {
		if ([^]u8)(transmute(^u8)(str_in))[0] == 0 && ui_has(K_UIMESSAGES_O) {
			msg_ext_no_fast()
			ui_call_msg_show(cstr_as_string_o(cstring("empty")), Api_Array{}, false, false, false, int64_obj_o(-1), Api_String{})
			cmdline_was_last_drawn_g = false
		}
		return
	}
	if hist {
		msg_hist_add_o(str_in, C.int(len_in), hl_id)
	}
	overflow := !ui_has(K_UIMESSAGES_O) && msg_scrolled > C.int(1 if p_ch == 0 else 0)
	if overflow && !msg_scrolled_ign_g && libc.strcmp(str_in, cstring("\r")) != 0 {
		need_wait_return_g = true
	}
	msg_didany_g = true
	if msg_use_printf() != 0 {
		saved_msg_col := msg_col
		msg_puts_printf_o(str_in, len_in)
		if headless_mode {
			msg_col = saved_msg_col
		}
	}
	if msg_use_printf() == 0 || (headless_mode && (^ScreenGrid)(&default_grid_u8).chars != nil) {
		msg_puts_display_o(str_in, C.int(len_in), hl_id, false)
	}
	need_fileinfo_g = false
}

// —— Batch 17: open/close bracket (msg_start/msg_end/msg_clr_*) ——

@(export)
msg_start :: proc "c" () {
	context = runtime.default_context()
	did_return := false
	msg_row = max(msg_row, cmdline_row)
	if msg_silent == 0 {
		xfree(keep_msg_g)
		keep_msg_g = nil
		need_fileinfo_g = false
	}
	if need_highlight_changed_g {
		highlight_changed_r()
	}
	if need_clr_eos_g || (p_ch == 0 && redrawing_cmdline_g) {
		need_clr_eos_g = false
		msg_clr_eos()
	}
	if p_ch == 0 && !ui_has(K_UIMESSAGES_O) && msg_scrolled == 0 {
		msg_grid_validate()
		msg_scroll_up(false, true)
		msg_scrolled += 1
		cmdline_row = Rows - 1
	}
	if msg_scroll == 0 && full_screen {
		msg_row = cmdline_row
		msg_col = 0
	} else if (msg_didout_g || p_ch == 0) && !ui_has(K_UIMESSAGES_O) {
		if p_ch == 0 && !msg_didout_g && msg_use_printf() != 0 {
			msg_puts_display_o(cstring("\n"), 1, 0, false)
		} else {
			msg_putchar('\n')
		}
		did_return = true
		cmdline_row = msg_row
	}
	if !msg_didany_g || lines_left < 0 {
		msg_starthere()
	}
	if msg_silent == 0 {
		msg_didout_g = false
	}
	if ui_has(K_UIMESSAGES_O) {
		msg_ext_ui_flush()
	}
	if !did_return {
		redir_write_o(cstring("\n"), 1)
	}
}

@(export)
msg_clr_eos :: proc "c" () {
	context = runtime.default_context()
	if msg_silent == 0 {
		msg_clr_eos_force()
	}
}

@(export)
msg_clr_eos_force :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	msg_startcol := msg_col
	if cmdmsg_rl_g {
		msg_startcol = 0
	}
	msg_endcol := Columns
	if cmdmsg_rl_g {
		msg_endcol = Columns - msg_col
	}
	if (^ScreenGrid)(&msg_grid_u8).chars != nil && msg_row < msg_grid_pos_g {
		msg_grid_validate()
		if msg_row < msg_grid_pos_g {
			msg_row = msg_grid_pos_g
		}
	}
	grid_clear((^GridView)(&msg_grid_adj_u8), msg_row, msg_row + 1, msg_startcol, msg_endcol, hl_attr_active_g[HLF_MSG_O])
	grid_clear((^GridView)(&msg_grid_adj_u8), msg_row + 1, Rows, 0, Columns, hl_attr_active_g[HLF_MSG_O])
	redraw_cmdline_g = true
	if msg_row < Rows - 1 || msg_col == 0 {
		clear_cmdline_g = false
		mode_displayed_g = false
		cmdline_was_last_drawn_g = false
	}
}

@(export)
msg_clr_cmdline :: proc "c" () {
	context = runtime.default_context()
	msg_row = cmdline_row
	msg_col = 0
	msg_clr_eos_force()
}

@(export)
msg_end :: proc "c" () -> bool {
	context = runtime.default_context()
	if !exiting && need_wait_return_g && (State & MODE_CMDLINE_O) == 0 {
		wait_return(0)
		return false
	}
	msg_ext_ui_flush()
	return true
}

// —— Batch 18: check/delay/flush/ext-flush/outtrans-long ——

foreign _ {
	@(link_name = "msg_ext_overwrite")
	msg_ext_overwrite_g: bool
}

@(export)
msg_outtrans_long :: proc "c" (longstr: cstring, hl_id: C.int) {
	context = runtime.default_context()
	length := C.int(libc.strlen(longstr))
	slen := length
	room := Columns - msg_col
	if !ui_has(K_UIMESSAGES_O) && length > room && room >= 20 {
		slen = (room - 3) / 2
		msg_outtrans_len(longstr, slen, hl_id, false)
		msg_puts_hl(cstring("..."), HLF_8_O, false)
	}
	msg_outtrans_len(transmute(cstring)(rawptr(uintptr(transmute(^u8)(longstr)) + uintptr(length - slen))), slen, hl_id, false)
}

@(export)
msg_check :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	if msg_row == Rows - 1 && msg_col >= sc_col {
		need_wait_return_g = true
		redraw_cmdline_g = true
	}
}

@(export)
msg_delay :: proc "c" (ms: u64, ignoreinput: bool) {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	m := ms
	if nvim_testing {
		m = 100
	}
	ui_flush()
	os_delay(m, ignoreinput)
}

@(export)
msg_check_for_delay :: proc "c" (check_msg_scroll: bool) {
	context = runtime.default_context()
	if ((emsg_on_display_g || (check_msg_scroll && msg_scroll != 0)) && !did_wait_return_g && emsg_silent == 0 && !in_assert_fails_g && !ui_has(K_UIMESSAGES_O)) {
		msg_delay(1006, true)
		emsg_on_display_g = false
		if check_msg_scroll {
			msg_scroll = 0
		}
	}
}

@(export)
msg_scroll_flush :: proc "c" () {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	if mg.throttled {
		mg.throttled = false
		pos_delta := msg_grid_pos_at_flush - msg_grid_pos_g
		if pos_delta < 0 {
			libc.abort()
		}
		delta := msg_scrolled - msg_scrolled_at_flush_g
		if delta > mg.rows {
			delta = mg.rows
		}
		if pos_delta > 0 {
			ui_ext_msg_set_pos_o(msg_grid_pos_g, true)
		}
		to_scroll := delta - pos_delta - msg_grid_scroll_discount_g
		if to_scroll < 0 {
			libc.abort()
		}
		if to_scroll > 0 && msg_grid_pos_g == 0 {
			ui_call_grid_scroll(C.longlong(mg.handle), 0, C.longlong(Rows), 0, C.longlong(Columns), C.longlong(to_scroll), 0)
		}
		i := Rows - delta
		if i < Rows - 1 {
			i = Rows - 1
		}
		if i < 0 {
			i = 0
		}
		for i < Rows {
			row := i - msg_grid_pos_g
			if row < 0 {
				libc.abort()
			}
			ui_line(rawptr(mg), row, false, 0, mg.dirty_col[row], mg.cols, hl_attr_active_g[HLF_MSG_O], false)
			mg.dirty_col[row] = 0
			i += 1
		}
	}
	msg_scrolled_at_flush_g = msg_scrolled
	msg_grid_scroll_discount_g = 0
	msg_grid_pos_at_flush = msg_grid_pos_g
}

@(export)
msg_ext_ui_flush :: proc "c" () {
	context = runtime.default_context()
	if !ui_has(K_UIMESSAGES_O) {
		msg_ext_kind = nil
		return
	} else if msg_ext_skip_flush {
		return
	}
	msg_ext_emit_chunk_o()
	if ([^]C.size_t)(msg_ext_chunks)[0] > 0 {
		tofree := msg_ext_init_chunks_o()
		tofree_arr := (^Api_Array)(tofree)^
		ui_call_msg_show(cstr_as_string_o(msg_ext_kind), tofree_arr, msg_ext_overwrite_g, msg_ext_history, msg_ext_append, msg_ext_id_obj_o(), cstr_as_string_o(msg_ext_trigger))
		if msg_ext_history {
			api_free_array_e(tofree_arr)
		} else {
			n := tofree_arr.size
			items := transmute(^u8)(xmalloc(n * 24))
			count: C.size_t = 0
			for k: C.size_t = 0; k < n; k += 1 {
				chunk := ([^]Api_Object)(tofree_arr.items)[k]
				chunk_arr := ([^]Api_Array)(&chunk.data[0])[0]
				chunk_items := chunk_arr.items
				text := ([^]Api_Object)(chunk_items)[1]
				text_str := ([^]String)(&text.data[0])[0]
				hl := ([^]Api_Object)(chunk_items)[2]
				hl_n := (^i64)(&hl.data[0])^
				([^]rawptr)(items)[count * 3 + 0] = rawptr(transmute(^u8)(text_str.data))
				([^]C.size_t)(items)[count * 3 + 1] = text_str.size
				([^]C.int)(items)[count * 6 + 4] = C.int(hl_n)
				count += 1
				xfree(chunk_items)
			}
			xfree(tofree_arr.items)
			msg_hist_add_multihl_o(HlMessage_O{size = count, cap = count, items = rawptr(items)}, true)
		}
		xfree(tofree)
		msg_ext_overwrite_g = false
		msg_ext_history = false
		msg_ext_append = false
		msg_ext_fast_g = true
		msg_ext_kind = nil
		if (^i64)(&msg_ext_id.data[0])^ == msg_id_next {
			msg_id_next += 1
		}
		msg_ext_id = MsgID_O{type = 2}
		(^i64)(&msg_ext_id.data[0])^ = msg_id_next
	}
}

msg_ext_id_obj_o :: proc "c" () -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = msg_ext_id.type}
	libc.memmove(rawptr(&obj.data[0]), rawptr(&msg_ext_id.data[0]), 16)
	return obj
}

@(export)
msg_ext_flush_showmode :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) && (msg_ext_last_attr != -1 || showmode_clear_g) {
		showmode_clear_g = msg_ext_last_attr != -1
		msg_ext_emit_chunk_o()
		tofree := msg_ext_init_chunks_o()
		ui_call_msg_showmode((^Api_Array)(tofree)^)
		api_free_array_e((^Api_Array)(tofree)^)
		xfree(tofree)
	}
}

showmode_clear_g: bool = false

// —— Batch 19: dialog cluster ——

// Single-copy move from message.c (Batch 19): C static deleted, C uses extern.
@(export) confirm_msg: ^u8 = nil

foreign _ {
	@(link_name = "input_available")
	input_available_e :: proc "c" () -> C.size_t ---
	@(link_name = "mb_tolower")
	mb_tolower_e :: proc "c" (a: C.int) -> C.int ---
	@(link_name = "ins_char_typebuf")
	ins_char_typebuf_e :: proc "c" (c: C.int, modifiers: C.int, on_key_ignore: bool) ---
}

// VIM_YES/NO/ALL/DISCARDALL_O already in ex_cmds/ex_cmds2.odin — reuse directly.
VIM_CANCEL_O :: 4
HAS_HOTKEY_LEN_O :: 30
HOTK_LEN_O :: 21
DLG_BUTTON_SEP_O :: '\n'
DLG_HOTKEY_CHAR_O :: '&'

copy_char_o :: proc "c" (from_in: cstring, to_in: ^u8, lowercase: bool) -> C.int {
	context = runtime.default_context()
	from := transmute(^u8)(from_in)
	to := to_in
	if lowercase {
		c := mb_tolower_e(utf_ptr2char(from_in))
		return utf_char2bytes(c, to)
	}
	length := utfc_ptr2len(from_in)
	libc.memmove(rawptr(to), rawptr(from), C.size_t(length))
	return length
}

console_dialog_alloc_o :: proc "c" (message: cstring, buttons: cstring, has_hotkey: ^bool) -> ^u8 {
	context = runtime.default_context()
	lenhotkey := HOTK_LEN_O
	([^]bool)(has_hotkey)[0] = false
	msg_len: C.int = 0
	button_len: C.int = 0
	idx: C.int = 0
	r := transmute(^u8)(buttons)
	for ([^]u8)(r)[0] != 0 {
		if ([^]u8)(r)[0] == DLG_BUTTON_SEP_O {
			button_len += 3
			lenhotkey += HOTK_LEN_O
			if idx < HAS_HOTKEY_LEN_O - 1 {
				idx += 1
				([^]bool)(has_hotkey)[uintptr(idx)] = false
			}
		} else if ([^]u8)(r)[0] == DLG_HOTKEY_CHAR_O {
			r = transmute(^u8)(rawptr(uintptr(r) + 1))
			button_len += 1
			if idx < HAS_HOTKEY_LEN_O - 1 {
				([^]bool)(has_hotkey)[uintptr(idx)] = true
			}
		}
		r = transmute(^u8)(rawptr(uintptr(r) + uintptr(utfc_ptr2len(transmute(cstring)(r)))))
	}
	msg_len += C.int(libc.strlen(message)) + 3
	button_len += C.int(libc.strlen(buttons)) + 3
	lenhotkey += 1
	if !([^]bool)(has_hotkey)[0] {
		button_len += 2
	}
	confirm_msg = transmute(^u8)(xmalloc(C.size_t(msg_len)))
	if ui_has(K_UIMESSAGES_O) {
		libc.snprintf(confirm_msg, C.size_t(msg_len), cstring("%s"), message)
	} else {
		libc.snprintf(confirm_msg, C.size_t(msg_len), cstring("\n%s\n"), message)
	}
	xfree(confirm_buttons)
	confirm_buttons = transmute(^u8)(xmalloc(C.size_t(button_len)))
	return transmute(^u8)(xmalloc(C.size_t(lenhotkey)))
}

copy_confirm_hotkeys_o :: proc "c" (buttons: cstring, default_button_idx: C.int, has_hotkey: ^bool, hotkeys_ptr: ^u8) {
	context = runtime.default_context()
	([^]u8)(hotkeys_ptr)[uintptr(copy_char_o(buttons, hotkeys_ptr, true))] = 0
	first_hotkey := false
	if !([^]bool)(has_hotkey)[0] {
		first_hotkey = true
	}
	msgp := confirm_buttons
	idx: C.int = 0
	r := transmute(^u8)(buttons)
	hk := hotkeys_ptr
	dflt := default_button_idx
	for ([^]u8)(r)[0] != 0 {
		if ([^]u8)(r)[0] == DLG_BUTTON_SEP_O {
			([^]u8)(msgp)[0] = ','
			([^]u8)(msgp)[1] = ' '
			msgp = transmute(^u8)(rawptr(uintptr(msgp) + 2))
			hk = transmute(^u8)(rawptr(uintptr(hk) + uintptr(libc.strlen(transmute(cstring)(hk)))))
			([^]u8)(hk)[uintptr(copy_char_o(transmute(cstring)(rawptr(uintptr(r) + 1)), hk, true))] = 0
			if dflt != 0 {
				dflt -= 1
			}
			if idx < HAS_HOTKEY_LEN_O - 1 {
				idx += 1
				if !([^]bool)(has_hotkey)[uintptr(idx)] {
					first_hotkey = true
				}
			}
		} else if ([^]u8)(r)[0] == DLG_HOTKEY_CHAR_O || first_hotkey {
			if ([^]u8)(r)[0] == DLG_HOTKEY_CHAR_O {
				r = transmute(^u8)(rawptr(uintptr(r) + 1))
			}
			first_hotkey = false
			if ([^]u8)(r)[0] == DLG_HOTKEY_CHAR_O {
				([^]u8)(msgp)[0] = ([^]u8)(r)[0]
				msgp = transmute(^u8)(rawptr(uintptr(msgp) + 1))
			} else {
				if dflt == 1 {
					([^]u8)(msgp)[0] = '['
				} else {
					([^]u8)(msgp)[0] = '('
				}
				msgp = transmute(^u8)(rawptr(uintptr(msgp) + 1))
				msgp = transmute(^u8)(rawptr(uintptr(msgp) + uintptr(copy_char_o(transmute(cstring)(r), msgp, false))))
				if dflt == 1 {
					([^]u8)(msgp)[0] = ']'
				} else {
					([^]u8)(msgp)[0] = ')'
				}
				msgp = transmute(^u8)(rawptr(uintptr(msgp) + 1))
				([^]u8)(hk)[uintptr(copy_char_o(transmute(cstring)(r), hk, true))] = 0
			}
		} else {
			msgp = transmute(^u8)(rawptr(uintptr(msgp) + uintptr(copy_char_o(transmute(cstring)(r), msgp, false))))
		}
		r = transmute(^u8)(rawptr(uintptr(r) + uintptr(utfc_ptr2len(transmute(cstring)(r)))))
	}
	([^]u8)(msgp)[0] = ':'
	([^]u8)(msgp)[1] = ' '
	([^]u8)(msgp)[2] = 0
}

msg_show_console_dialog_o :: proc "c" (message: cstring, buttons: cstring, dfltbutton: C.int) -> ^u8 {
	context = runtime.default_context()
	has_hotkey: [HAS_HOTKEY_LEN_O]bool
	hotk := console_dialog_alloc_o(message, buttons, &has_hotkey[0])
	copy_confirm_hotkeys_o(buttons, dfltbutton, &has_hotkey[0], hotk)
	display_confirm_msg_o()
	return hotk
}

display_confirm_msg_o :: proc "c" () {
	context = runtime.default_context()
	confirm_msg_used += 1
	if confirm_msg != nil {
		msg_ext_set_kind(cstring("confirm"))
		msg_puts_hl(transmute(cstring)(confirm_msg), HLF_M_O, false)
	}
	confirm_msg_used -= 1
}

@(export)
do_dialog :: proc "c" (type: C.int, title: cstring, message: cstring, buttons: cstring, dfltbutton: C.int, textfield: cstring, ex_cmd: bool) -> C.int {
	context = runtime.default_context()
	retval: C.int = 0
	if silent_mode {
		return dfltbutton
	}
	save_msg_silent := msg_silent
	oldState := State
	msg_silent = 0
	no_wait_return += 1
	hotkeys := msg_show_console_dialog_o(message, buttons, dfltbutton)
	for {
		if ui_active() == 0 && input_available_e() == 0 {
			retval = dfltbutton
			break
		}
		c := prompt_for_input(transmute(cstring)(confirm_buttons), HLF_M_O, true, nil)
		if c == 13 || c == 0 {
			retval = dfltbutton
			break
		} else if c == 3 || c == 27 {
			retval = 0
			break
		} else {
			if c < 0 {
				msg_didout_g = false
				msg_didany_g = false
				continue
			}
			if c == ':' && ex_cmd {
				retval = dfltbutton
				ins_char_typebuf_e(C.int(':'), 0, false)
				break
			}
			c = mb_tolower_e(c)
			retval = 1
			i: C.int = 0
			for ([^]u8)(hotkeys)[uintptr(i)] != 0 {
				if utf_ptr2char(transmute(cstring)(rawptr(uintptr(hotkeys) + uintptr(i)))) == c {
					break
				}
				i += utfc_ptr2len(transmute(cstring)(rawptr(uintptr(hotkeys) + uintptr(i)))) - 1
				retval += 1
				i += 1
			}
			if ([^]u8)(hotkeys)[uintptr(i)] != 0 {
				break
			}
			msg_didout_g = false
			msg_didany_g = false
			continue
		}
		break
	}
	xfree(hotkeys)
	xfree(confirm_msg)
	confirm_msg = nil
	msg_silent = save_msg_silent
	State = oldState
	setmouse()
	no_wait_return -= 1
	msg_end_prompt()
	return retval
}

@(export)
vim_dialog_yesno :: proc "c" (type: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int {
	context = runtime.default_context()
	t := title
	if t == nil {
		t = cstring("Question")
	}
	if do_dialog(type, t, message, cstring("&Yes\n&No"), dflt, nil, false) == 1 {
		return VIM_YES_O
	}
	return VIM_NO_O
}

@(export)
vim_dialog_yesnocancel :: proc "c" (type: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int {
	context = runtime.default_context()
	t := title
	if t == nil {
		t = cstring("Question")
	}
	ret := do_dialog(type, t, message, cstring("&Yes\n&No\n&Cancel"), dflt, nil, false)
	if ret == 1 {
		return VIM_YES_O
	} else if ret == 2 {
		return VIM_NO_O
	}
	return VIM_CANCEL_O
}

@(export)
vim_dialog_yesnoallcancel :: proc "c" (type: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int {
	context = runtime.default_context()
	t := title
	if t == nil {
		t = cstring("Question")
	}
	ret := do_dialog(type, t, message, cstring("&Yes\n&No\nSave &All\n&Discard All\n&Cancel"), dflt, nil, false)
	if ret == 1 {
		return VIM_YES_O
	} else if ret == 2 {
		return VIM_NO_O
	} else if ret == 3 {
		return VIM_ALL_O
	} else if ret == 4 {
		return VIM_DISCARDALL_O
	}
	return VIM_CANCEL_O
}

// —— Batch 20: wait_return cluster ——

foreign _ {
	@(link_name = "vgetc_char")
	vgetc_char_g: C.int
	@(link_name = "vgetc_mod_mask")
	vgetc_mod_mask_g: C.int
	@(link_name = "jump_to_mouse")
	jump_to_mouse_e :: proc "c" (flags: C.int, inclusive: ^bool, which_button: C.int) -> C.int ---
	// ex_messages: see export below — call directly.
}

MOUSE_SETPOS_O :: 0x08
K_IGNORE_O :: -(253 + (53 << 8))
K_LEFTDRAG_O :: -(253 + (45 << 8))
K_LEFTRELEASE_O :: -(253 + (46 << 8))
K_MIDDLEDRAG_O :: -(253 + (48 << 8))
K_MIDDLERELEASE_O :: -(253 + (49 << 8))
K_RIGHTDRAG_O :: -(253 + (51 << 8))
K_RIGHTRELEASE_O :: -(253 + (52 << 8))
K_MOUSELEFT_O :: -(253 + (77 << 8))
K_MOUSERIGHT_O :: -(253 + (78 << 8))
K_MOUSEDOWN_O :: -(253 + (75 << 8))
K_MOUSEUP_O :: -(253 + (76 << 8))
K_MOUSEMOVE_O :: -(253 + (100 << 8))
K_MIDDLEMOUSE_O :: -(253 + (47 << 8))
K_RIGHTMOUSE_O :: -(253 + (50 << 8))
K_X1MOUSE_O :: -(253 + (89 << 8))
K_X2MOUSE_O :: -(253 + (92 << 8))
HLF_R_O :: 18

hit_return_msg_o :: proc "c" (newline_sb: bool) {
	context = runtime.default_context()
	save_p_more := p_more_g
	if !newline_sb {
		p_more_g = 0
	}
	if msg_didout_g {
		msg_putchar('\n')
	}
	p_more_g = 0
	if got_int {
		msg_puts(cstring("Interrupt: "))
	}
	msg_puts_hl(cstring("Press ENTER or type command to continue"), HLF_R_O, false)
	if msg_use_printf() == 0 {
		msg_clr_eos()
	}
	p_more_g = save_p_more
}

@(export)
wait_return :: proc "c" (redraw: C.int) {
	context = runtime.default_context()
	c: C.int = 0
	had_got_int := false
	if redraw != 0 {
		redraw_all_later(UPD_NOT_VALID)
	}
	if ui_has(K_UIMESSAGES_O) {
		prompt_for_input(cstring("Press any key to continue"), HLF_M_O, true, nil)
		return
	}
	if msg_silent != 0 {
		return
	}
	if headless_mode && ui_active() == 0 {
		return
	}
	if vgetc_busy_g > 0 {
		return
	}
	need_wait_return_g = true
	if no_wait_return != 0 {
		if !exmode_active {
			cmdline_row = msg_row
		}
		return
	}
	redir_off_g = true
	oldState := State
	if quit_more_g {
		c = 13
		quit_more_g = false
		got_int = false
	} else if exmode_active {
		msg_puts(cstring(" "))
		c = 13
		got_int = false
	} else if !stuff_empty_e() {
		c = 13
	} else {
		State = MODE_HITRETURN_O
		setmouse()
		cmdline_row = msg_row
		if need_check_timestamps_g {
			check_timestamps_e(false)
		}
		if p_ch == 0 && !ui_has(K_UIMESSAGES_O) && msg_scrolled == 0 {
			msg_grid_validate()
			msg_scroll_up(false, true)
			msg_scrolled += 1
			cmdline_row = Rows - 1
		}
		if (msg_flags & KOPT_MOPT_HIT_ENTER_O) != 0 {
			hit_return_msg_o(true)
			for {
				had_got_int = got_int
				no_mapping += 1
				allow_keys += 1
				save_reg_recording := reg_recording
				save_scriptout := scriptout
				reg_recording = 0
				scriptout = nil
				c = safe_vgetc_e()
				if had_got_int && global_busy == 0 {
					got_int = false
				}
				no_mapping -= 1
				allow_keys -= 1
				reg_recording = save_reg_recording
				scriptout = save_scriptout
				if p_more_g != 0 {
					if c == 'b' || c == 2 || c == 'k' || c == 'u' || c == 'g' || c == K_UP || c == K_PAGEUP_O {
						if msg_scrolled > Rows {
							do_more_prompt_o(c)
						} else {
							msg_didout_g = false
							c = K_IGNORE_O
							msg_col = 0
						}
						if quit_more_g {
							c = 13
							quit_more_g = false
							got_int = false
						} else if c != K_IGNORE_O {
							c = K_IGNORE_O
							hit_return_msg_o(false)
						}
					} else if msg_scrolled > Rows - 2 && (c == 'j' || c == 'd' || c == 'f' || c == 6 || c == K_DOWN || c == K_PAGEDOWN_O) {
						c = K_IGNORE_O
					}
				}
				if !((had_got_int && c == 3) || c == K_IGNORE_O || c == K_LEFTDRAG_O || c == K_LEFTRELEASE_O || c == K_MIDDLEDRAG_O || c == K_MIDDLERELEASE_O || c == K_RIGHTDRAG_O || c == K_RIGHTRELEASE_O || c == K_MOUSELEFT_O || c == K_MOUSERIGHT_O || c == K_MOUSEDOWN_O || c == K_MOUSEUP_O || c == K_MOUSEMOVE_O) {
					break
				}
			}
			os_breakcheck()
			if c == K_LEFTMOUSE_O || c == K_MIDDLEMOUSE_O || c == K_RIGHTMOUSE_O || c == K_X1MOUSE_O || c == K_X2MOUSE_O {
				jump_to_mouse_e(MOUSE_SETPOS_O, nil, 0)
			} else if vim_strchr(cstring("\r\n "), c) == nil && c != 3 && c != 'q' {
				ins_char_typebuf_e(vgetc_char_g, vgetc_mod_mask_g, true)
				do_redraw_g = true
			}
		} else {
			c = 13
			do_sleep(i64(msg_wait), true)
		}
	}
	redir_off_g = false
	if c == ':' || c == '?' || c == '/' {
		if !exmode_active {
			cmdline_row = msg_row
		}
		skip_redraw_g = true
		do_redraw_g = false
	}
	tmpState := State
	State = oldState
	setmouse()
	msg_check()
	need_wait_return_g = false
	did_wait_return_g = true
	emsg_on_display_g = false
	lines_left = -1
	reset_last_sourcing()
	if keep_msg_g != nil && vim_strsize(transmute(cstring)(keep_msg_g)) >= (Rows - cmdline_row - 1) * Columns + sc_col {
		xfree(keep_msg_g)
		keep_msg_g = nil
	}
	if tmpState == MODE_SETWSIZE_O {
		ui_refresh()
	} else if !skip_redraw_g {
		if redraw != 0 || (msg_scrolled != 0 && redraw != -1) {
			redraw_later(curwin, UPD_VALID_O)
		}
	}
}

@(export)
repeat_message :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		return
	}
	if State == MODE_ASKMORE_O {
		msg_moremsg_o(true)
		msg_row = Rows - 1
	} else if (State & MODE_CMDLINE_O) != 0 && confirm_msg != nil {
		display_confirm_msg_o()
		msg_row = Rows - 1
	} else if State == MODE_EXTERNCMD_O {
		ui_cursor_goto(msg_row, msg_col)
	} else if State == MODE_HITRETURN_O || State == MODE_SETWSIZE_O {
		if msg_row == Rows - 1 {
			msg_didout_g = false
			msg_col = 0
			msg_clr_eos()
		}
		hit_return_msg_o(false)
		msg_row = Rows - 1
	}
}

@(export)
show_sb_text :: proc "c" () {
	context = runtime.default_context()
	if ui_has(K_UIMESSAGES_O) {
		ea: [192]u8
		libc.memset(rawptr(&ea[0]), 0, 192)
		([^]cstring)(&ea[0])[0] = cstring("")
		([^]C.int)(&ea[0])[18] = 1
		ex_messages(rawptr(&ea[0]))
		return
	}
	mp := msg_sb_start_o(last_msgchunk_g)
	if mp == nil || ([^]rawptr)(mp)[1] == nil {
		vim_beep(C.uint(KOPT_BO_SHELL_O))
	} else {
		do_more_prompt_o('G')
		wait_return(0)
	}
}

// —— Batch 21: ex_messages + msg_prt_line ——

@(export)
ex_messages :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(eap)^
	if libc.strcmp(arg, cstring("clear")) == 0 {
		keep := C.int(0)
		if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ != 0 {
			keep = (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
		}
		msg_hist_clear(keep)
		return
	}
	if ([^]u8)(transmute(^u8)(arg))[0] != 0 {
		emsg(cstring("E474: Invalid argument"))
		return
	}
	entries_items: ^Api_Object = nil
	entries_size: C.size_t = 0
	entries_cap: C.size_t = 0
	p := hist_temp_e()
	sk0 := (^C.int)(uintptr(eap) + EXARG_SKIP_OFF)^
	if sk0 == 0 {
		p = hist_first_e()
	}
	skip := C.int(0)
	if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ != 0 {
		skip = hist_len_e() - (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	}
	for p != nil {
		temp := ([^]bool)(p)[HIST_TEMP_O]
		sk := (^C.int)(uintptr(eap) + EXARG_SKIP_OFF)^
		cond1 := temp && sk == 0
		if cond1 || skip > 0 {
			if !cond1 {
				skip -= 1
			}
			p = ([^]rawptr)(p)[0]
			continue
		}
		if ui_has(K_UIMESSAGES_O) && msg_silent == 0 {
			entry_items := transmute(^Api_Object)(xmalloc(3 * 32))
			kind_ptr := ([^]rawptr)(p)[5]
			kind_str := String{data = nil, size = 0}
			if kind_ptr != nil {
				kind_str = String{data = transmute(cstring)(kind_ptr), size = libc.strlen(transmute(cstring)(kind_ptr))}
			}
			([^]Api_Object)(entry_items)[0] = str_obj_o(kind_str)
			hlmsg_size := ([^]C.size_t)(p)[2]
			hlmsg_items := ([^]rawptr)(p)[4]
			content_items := transmute(^Api_Object)(xmalloc(hlmsg_size * 32))
			for i: C.size_t = 0; i < hlmsg_size; i += 1 {
				ch_text := ([^]String)(uintptr(hlmsg_items) + uintptr(i) * 24)[0]
				ch_hl := ([^]C.int)(uintptr(hlmsg_items) + uintptr(i) * 24 + 16)[0]
				ce_items := transmute(^Api_Object)(xmalloc(3 * 32))
				attr := C.int(0)
				if ch_hl != 0 {
					attr = syn_id2attr_r(ch_hl)
				}
				([^]Api_Object)(ce_items)[0] = int64_obj_o(i64(attr))
				dup_data := xmemdupz(rawptr(transmute(^u8)(ch_text.data)), ch_text.size)
				([^]Api_Object)(ce_items)[1] = str_obj_o(String{data = transmute(cstring)(dup_data), size = ch_text.size})
				([^]Api_Object)(ce_items)[2] = int64_obj_o(i64(ch_hl))
				([^]Api_Object)(content_items)[i] = Api_Object{t = 5}
				([^]Api_Array)(&([^]Api_Object)(content_items)[i].data[0])[0] = Api_Array{size = 3, capacity = 3, items = ce_items}
			}
			content := Api_Object{t = 5}
			([^]Api_Array)(&content.data[0])[0] = Api_Array{size = hlmsg_size, capacity = hlmsg_size, items = content_items}
			([^]Api_Object)(entry_items)[1] = content
			bobj := Api_Object{t = 1}
			([^]i64)(&bobj.data[0])[0] = 1 if ([^]bool)(p)[HIST_APPEND_O] else 0
			([^]Api_Object)(entry_items)[2] = bobj
			entry := Api_Object{t = 5}
			([^]Api_Array)(&entry.data[0])[0] = Api_Array{size = 3, capacity = 3, items = entry_items}
			if entries_size >= entries_cap {
				newcap := entries_cap * 2
				if newcap == 0 {
					newcap = 4
				}
				nb := transmute(^Api_Object)(xmalloc(newcap * 32))
				if entries_size > 0 {
					libc.memmove(rawptr(nb), rawptr(entries_items), entries_size * 32)
					xfree(entries_items)
				}
				entries_cap = newcap
				entries_items = nb
			}
			([^]Api_Object)(entries_items)[entries_size] = entry
			entries_size += 1
		}
		if redirecting() != 0 || !ui_has(K_UIMESSAGES_O) {
			if ui_has(K_UIMESSAGES_O) {
				msg_silent += 1
			}
			need_clear := false
			hlmsg := HlMessage_O{size = ([^]C.size_t)(p)[2], cap = ([^]C.size_t)(p)[3], items = ([^]rawptr)(p)[4]}
			kind := transmute(cstring)(([^]rawptr)(p)[5])
			msg_multihl(MsgID_O{}, hlmsg, kind, false, false, nil, &need_clear)
			if ui_has(K_UIMESSAGES_O) {
				msg_silent -= 1
			}
		}
		p = ([^]rawptr)(p)[0]
	}
	if entries_size > 0 {
		ui_call_msg_history_show(Api_Array{size = entries_size, capacity = entries_cap, items = entries_items}, (^C.int)(uintptr(eap) + EXARG_SKIP_OFF)^ != 0)
		api_free_array_e(Api_Array{size = entries_size, capacity = entries_cap, items = entries_items})
	}
}

// LCS field offsets within w_p_lcs_chars (optionstr.odin Lcs_Chars layout).
LCS_EOL_OFF_O :: 0
LCS_NBSP_OFF_O :: 12
LCS_SPACE_OFF_O :: 16
LCS_TAB1_OFF_O :: 20
LCS_TAB2_OFF_O :: 24
LCS_TAB3_OFF_O :: 28
LCS_LEADTAB1_OFF_O :: 32
LCS_LEADTAB2_OFF_O :: 36
LCS_LEADTAB3_OFF_O :: 40
LCS_LEAD_OFF_O :: 44
LCS_TRAIL_OFF_O :: 48
LCS_MULTISPACE_OFF_O :: 56
LCS_LEADMULTISPACE_OFF_O :: 64

@(export)
msg_prt_line :: proc "c" (s_in: cstring, list: bool) {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	lcs := uintptr(curwin) + W_P_LCS_CHARS_OFF
	sc: u32 = 0
	col: C.int = 0
	n_extra: C.int = 0
	sc_extra: u32 = 0
	sc_final: u32 = 0
	p_extra: ^u8 = nil
	n: C.int = 0
	hl_id: C.int = 0
	lead: ^u8 = nil
	in_multispace := false
	multispace_pos: C.int = 0
	trail: ^u8 = nil
	lis := list
	if (^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ != 0 {
		lis = true
	}
	if lis {
		if (^u32)(lcs + LCS_TRAIL_OFF_O)^ != 0 {
			trail = transmute(^u8)(rawptr(uintptr(s) + uintptr(libc.strlen(s_in))))
			for uintptr(trail) > uintptr(s) && (([^]u8)(rawptr(uintptr(trail) - 1))[0] == ' ' || ([^]u8)(rawptr(uintptr(trail) - 1))[0] == 9) {
				trail = transmute(^u8)(rawptr(uintptr(trail) - 1))
			}
		}
		if (^u32)(lcs + LCS_LEAD_OFF_O)^ != 0 || (^rawptr)(lcs + LCS_LEADMULTISPACE_OFF_O)^ != nil || ([^]u8)(rawptr(lcs + LCS_LEADTAB1_OFF_O))[0] != 0 {
			lead = s
			for ([^]u8)(lead)[0] == ' ' || ([^]u8)(lead)[0] == 9 {
				lead = transmute(^u8)(rawptr(uintptr(lead) + 1))
			}
			if ([^]u8)(lead)[0] == 0 {
				lead = nil
			}
		}
	}
	if ([^]u8)(s)[0] == 0 && !(lis && (^u32)(lcs + LCS_EOL_OFF_O)^ != 0) {
		msg_putchar(' ')
	}
	for !got_int {
		if n_extra > 0 {
			n_extra -= 1
			if n_extra == 0 && sc_final != 0 {
				sc = sc_final
			} else if sc_extra != 0 {
				sc = sc_extra
			} else {
				if p_extra == nil {
					libc.abort()
				}
				sc = u32(([^]u8)(p_extra)[0])
				p_extra = transmute(^u8)(rawptr(uintptr(p_extra) + 1))
			}
		} else if utfc_ptr2len(transmute(cstring)(s)) > 1 {
			l := utfc_ptr2len(transmute(cstring)(s))
			col += utf_ptr2cells_r(transmute(cstring)(s))
			buf: [22]u8
			if l >= 21 {
				buf[0] = '?'
				buf[1] = 0
			} else if (^u32)(lcs + LCS_NBSP_OFF_O)^ != 0 && lis && ((utf_ptr2char(transmute(cstring)(s)) == 160) || (utf_ptr2char(transmute(cstring)(s)) == 0x202f)) {
				schar_get(&buf[0], (^u32)(lcs + LCS_NBSP_OFF_O)^)
			} else {
				libc.memmove(rawptr(&buf[0]), rawptr(s), C.size_t(l))
				buf[l] = 0
			}
			msg_puts(transmute(cstring)(&buf[0]))
			s = transmute(^u8)(rawptr(uintptr(s) + uintptr(l)))
			continue
		} else {
			hl_id = 0
			c := ([^]u8)(s)[0]
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
			if c >= 0x80 {
				col += utf_char2cells_e(C.int(c))
				msg_putchar(C.int(c))
				continue
			}
			sc_extra = 0
			sc_final = 0
			if lis {
				in_multispace = c == ' ' && (([^]u8)(s)[0] == ' ' || (col > 0 && ([^]u8)(rawptr(uintptr(s) - 2))[0] == ' '))
				if !in_multispace {
					multispace_pos = 0
				}
			}
			if c == 9 && (!lis || (^u32)(lcs + LCS_TAB1_OFF_O)^ != 0) {
				n_extra = tabstop_padding(col, C.longlong((^i64)(uintptr(curbuf) + B_P_TS)^), (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)) - 1
				if !lis {
					sc = u32(' ')
					sc_extra = u32(' ')
				} else {
					lcs_tab1 := (^u32)(lcs + LCS_TAB1_OFF_O)^
					lcs_tab2 := (^u32)(lcs + LCS_TAB2_OFF_O)^
					lcs_tab3 := (^u32)(lcs + LCS_TAB3_OFF_O)^
					if lead != nil && uintptr(s) <= uintptr(lead) && ([^]u8)(rawptr(lcs + LCS_LEADTAB1_OFF_O))[0] != 0 {
						lcs_tab1 = (^u32)(lcs + LCS_LEADTAB1_OFF_O)^
						lcs_tab2 = (^u32)(lcs + LCS_LEADTAB2_OFF_O)^
						lcs_tab3 = (^u32)(lcs + LCS_LEADTAB3_OFF_O)^
					}
					if n_extra == 0 && lcs_tab3 != 0 {
						sc = lcs_tab3
					} else {
						sc = lcs_tab1
					}
					sc_extra = lcs_tab2
					sc_final = lcs_tab3
					hl_id = HLF_0_O
				}
			} else if c == 0 && lis && (^u32)(lcs + LCS_EOL_OFF_O)^ != 0 {
				p_extra = transmute(^u8)(cstring(""))
				n_extra = 1
				sc = (^u32)(lcs + LCS_EOL_OFF_O)^
				hl_id = HLF_AT_O
				s = transmute(^u8)(rawptr(uintptr(s) - 1))
			} else if c != 0 && char2cells(C.int(c)) > 1 {
				n = char2cells(C.int(c)) - 1
				n_extra = n
				p_extra = transmute(^u8)(transchar_byte_buf(nil, C.int(c)))
				sc = u32(([^]u8)(p_extra)[0])
				p_extra = transmute(^u8)(rawptr(uintptr(p_extra) + 1))
				hl_id = HLF_0_O
			} else if c == ' ' {
				if lead != nil && uintptr(s) <= uintptr(lead) && in_multispace && (^rawptr)(lcs + LCS_MULTISPACE_OFF_O)^ != nil {
					ms := (^u32)((^rawptr)(lcs + LCS_MULTISPACE_OFF_O)^)
					sc = ([^]u32)(ms)[uintptr(multispace_pos)]
					multispace_pos += 1
					if ([^]u32)(ms)[uintptr(multispace_pos)] == 0 {
						multispace_pos = 0
					}
					hl_id = HLF_0_O
				} else if lead != nil && uintptr(s) <= uintptr(lead) && (^u32)(lcs + LCS_LEAD_OFF_O)^ != 0 {
					sc = (^u32)(lcs + LCS_LEAD_OFF_O)^
					hl_id = HLF_0_O
				} else if trail != nil && uintptr(s) > uintptr(trail) {
					sc = (^u32)(lcs + LCS_TRAIL_OFF_O)^
					hl_id = HLF_0_O
				} else if in_multispace && (^rawptr)(lcs + LCS_MULTISPACE_OFF_O)^ != nil {
					ms := (^u32)((^rawptr)(lcs + LCS_MULTISPACE_OFF_O)^)
					sc = ([^]u32)(ms)[uintptr(multispace_pos)]
					multispace_pos += 1
					if ([^]u32)(ms)[uintptr(multispace_pos)] == 0 {
						multispace_pos = 0
					}
					hl_id = HLF_0_O
				} else if lis && (^u32)(lcs + LCS_SPACE_OFF_O)^ != 0 {
					sc = (^u32)(lcs + LCS_SPACE_OFF_O)^
					hl_id = HLF_0_O
				} else {
					sc = u32(' ')
				}
			} else {
				sc = u32(c)
			}
		}
		if sc == 0 {
			break
		}
		buf: [32]u8
		schar_get(&buf[0], sc)
		msg_puts_hl(transmute(cstring)(&buf[0]), hl_id, false)
		col += 1
	}
	msg_clr_eos()
}

