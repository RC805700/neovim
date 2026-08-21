package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:mem"

// ── Port of src/nvim/os/input.c ──
// Reuses Odin event-loop primitives (rstream_*, loop_poll_events,
// multiqueue_*) and FFIs to the remaining C-only helpers (getchar,
// autocmd, keycodes, profile, insexpand, main).

READ_BUFFER_SIZE :: 0xfff
MAX_KEY_CODE_LEN_INPUT :: 6
INPUT_BUFFER_SIZE :: (READ_BUFFER_SIZE * 4) + MAX_KEY_CODE_LEN_INPUT

// ── keycode / mode constants (from keycodes.h / state_defs.h) ──
K_SPECIAL_INPUT :: 0x80
KS_SPECIAL :: 254
KS_EXTRA :: 253
KS_MODIFIER :: 252
KE_FILLER :: 88 // 'X'
KE_EVENT :: 102
KE_COMPLETE_DELAY :: 110
KE_LEFTMOUSE :: 44
KE_MIDDLEMOUSE :: 47
KE_RIGHTMOUSE :: 50
KE_RIGHTRELEASE :: 52
KE_MOUSEDOWN :: 75
KE_MOUSERIGHT :: 78
KE_X1MOUSE :: 89
KE_X2MOUSE :: 92
KE_X2RELEASE :: 94
KE_MOUSEMOVE :: 100
MOD_MASK_CTRL :: 0x04
MOD_MASK_2CLICK :: 0x20
MOD_MASK_3CLICK :: 0x40
MOD_MASK_4CLICK :: 0x60
Ctrl_C :: 3
MODE_INSERT :: 0x10
FSK_KEYCODE :: 0x01

EVENT_CURSORHOLD :: 37
EVENT_CURSORHOLDI :: 38
VV_USERACTIVE :: 106

// UV_TTY, silent_mode, Rows, Columns, p_ut, uv_guess_handle, curbuf are
// declared elsewhere in the package (stream.odin / main.odin / uv_defs.odin).

// buf_T.b_mapped_ctrl_c offset (verified via __builtin_offsetof)
BUF_MAPPED_CTRL_C_OFFSET :: 12504

TriState :: enum c.int {
	kNone  = -1,
	kFalse = 0,
	kTrue  = 1,
}

// ── package-global state (was static in input.c) ──
@(private = "file")
read_stream_input := RStream{s = {closed = true}}
@(private = "file")
input_buffer: [INPUT_BUFFER_SIZE]u8
@(private = "file")
input_read_pos: uintptr
@(private = "file")
input_write_pos: uintptr

@(private = "file")
input_eof := false
@(private = "file")
blocking := false
@(private = "file")
cursorhold_time: c.int = 0
@(private = "file")
cursorhold_tb_change_cnt: c.int = 0
@(private = "file")
breakcheck_count: c.int = 0

// multiclick statics (were function-static in check_multiclick)
@(private = "file")
mc_orig_num_clicks: c.int = 0
@(private = "file")
mc_orig_mouse_code: c.int = 0
@(private = "file")
mc_orig_mouse_grid: c.int = 0
@(private = "file")
mc_orig_mouse_col: c.int = 0
@(private = "file")
mc_orig_mouse_row: c.int = 0
@(private = "file")
mc_orig_mouse_time: u64 = 0

// push_event_key static
@(private = "file")
pek_key_idx: c.int = 0

@(private = "file")
input_init_done := false

@(private = "file")
input_buffers_init :: proc "contextless" () {
	if !input_init_done {
		input_read_pos = uintptr(&input_buffer[0])
		input_write_pos = uintptr(&input_buffer[0])
		input_init_done = true
	}
}

BREAKCHECK_SKIP :: 1000

// ── C-only globals / procs (FFI) ──
@(default_calling_convention = "c")
foreign _ {
	@(link_name = "used_stdin")
	used_stdin: bool
	@(link_name = "current_ui")
	current_ui: u64
	@(link_name = "did_cursorhold")
	did_cursorhold: bool
	@(link_name = "typebuf_was_filled")
	typebuf_was_filled: bool
	@(link_name = "ctrl_c_interrupts")
	ctrl_c_interrupts: bool
	@(link_name = "mapped_ctrl_c")
	mapped_ctrl_c: c.int
	@(link_name = "mouse_grid")
	mouse_grid: c.int
	@(link_name = "mouse_row")
	mouse_row: c.int
	@(link_name = "mouse_col")
	mouse_col: c.int
	@(link_name = "p_acl")
	p_acl: c.long
	@(link_name = "p_mouset")
	p_mouset: c.long
	@(link_name = "ch_before_blocking_events")
	ch_before_blocking_events: ^MultiQueue

	@(link_name = "trans_special")
	trans_special :: proc(srcp: ^rawptr, src_len: c.size_t, dst: rawptr, flags: c.int, escape_ks: bool, did_simplify: rawptr) -> c.uint ---
	@(link_name = "trigger_cursorhold")
	trigger_cursorhold :: proc() -> bool ---
	@(link_name = "before_blocking")
	before_blocking :: proc() ---
	@(link_name = "typebuf_changed")
	typebuf_changed :: proc(tb_change_cnt: c.int) -> bool ---
	@(link_name = "get_real_state")
	get_real_state :: proc() -> c.int ---
	@(link_name = "getout")
	getout :: proc(exitval: c.int) ---
	@(link_name = "ins_compl_autocomplete_pending")
	ins_compl_autocomplete_pending :: proc() -> bool ---
	@(link_name = "ins_compl_autocomplete_elapsed")
	ins_compl_autocomplete_elapsed :: proc() -> i64 ---
	@(link_name = "ins_compl_active")
	ins_compl_active :: proc() -> bool ---
	@(link_name = "prof_input_start")
	prof_input_start :: proc() ---
	@(link_name = "prof_input_end")
	prof_input_end :: proc() ---
	@(link_name = "typebuf")
	typebuf: typebuf_T
}

// mirror of getchar_defs.h typebuf_T (sizeof 48; tb_len @24 is all we read)
typebuf_T :: struct {
	tb_buf:        rawptr, // @0
	tb_noremap:    rawptr, // @8
	tb_buflen:     c.int,  // @16
	tb_off:        c.int,  // @20
	tb_len:        c.int,  // @24
	tb_maplen:     c.int,  // @28
	tb_silent:     c.int,  // @32
	tb_no_abbr_cnt: c.int, // @36
	tb_change_cnt: c.int,  // @40
	_tail:         c.int,  // @44 pad to 48
}
#assert(size_of(typebuf_T) == 48)
#assert(offset_of(typebuf_T, tb_len) == 24)

@(private = "file")
curbuf_mapped_ctrl_c :: proc "contextless" () -> c.int {
	if curbuf == nil {
		return 0
	}
	return (^c.int)(uintptr(curbuf) + BUF_MAPPED_CTRL_C_OFFSET)^
}

// ── input_start / input_stop ──
@(export)
input_start :: proc "c" () {
	context = runtime.default_context()
	input_buffers_init()
	if !read_stream_input.s.closed {
		return
	}
	used_stdin = true
	rstream_init_fd(&main_loop, &read_stream_input, 0) // STDIN_FILENO
	rstream_start(&read_stream_input, input_read_cb, nil)
}

@(export)
input_stop :: proc "c" () {
	context = runtime.default_context()
	if read_stream_input.s.closed {
		return
	}
	rstream_stop(&read_stream_input)
	rstream_may_close(&read_stream_input)
}

// ── cursorhold ──
@(private = "file")
cursorhold_event :: proc(argv: ^rawptr) {
	context = runtime.default_context()
	event: c.int = (State & MODE_INSERT != 0) ? EVENT_CURSORHOLDI : EVENT_CURSORHOLD
	apply_autocmds(event, nil, nil, false, curbuf)
	did_cursorhold = true
}

@(private = "file")
create_cursorhold_event :: proc "contextless" (events_enabled: bool) {
	context = runtime.default_context()
	assert(!events_enabled || multiqueue_empty(main_loop.events))
	ev := event_create(cursorhold_event)
	multiqueue_put_event(main_loop.events, ev)
}

@(private = "file")
reset_cursorhold_wait :: proc "contextless" (tb_change_cnt: c.int) {
	cursorhold_time = 0
	cursorhold_tb_change_cnt = tb_change_cnt
}

@(private = "file")
try_read :: proc "contextless" (buf: ^u8, maxlen: c.int, tb_change_cnt: c.int) -> (c.int, bool) {
	if maxlen != 0 && input_available() > 0 {
		reset_cursorhold_wait(tb_change_cnt)
		avail := input_available()
		to_read := c.size_t(maxlen)
		if avail < to_read {
			to_read = avail
		}
		mem.copy(buf, rawptr(input_read_pos), int(to_read))
		input_read_pos += uintptr(to_read)
		return c.int(to_read), true
	}
	return 0, false
}

@(export)
input_get :: proc "c" (buf: ^u8, maxlen: c.int, ms: c.int, tb_change_cnt: c.int, events: ^MultiQueue) -> c.int {
	context = runtime.default_context()
	input_buffers_init()

	if tb_change_cnt != cursorhold_tb_change_cnt {
		reset_cursorhold_wait(tb_change_cnt)
	}

	if n, ok := try_read(buf, maxlen, tb_change_cnt); ok {
		return n
	}

	if (mapped_ctrl_c | curbuf_mapped_ctrl_c()) & get_real_state() != 0 {
		ctrl_c_interrupts = false
	}

	result: TriState
	if ms >= 0 {
		result = inbuf_poll(ms, events)
		if result == .kFalse {
			return 0
		}
	} else {
		wait_start := os_hrtime()
		if cursorhold_time > c.int(p_ut) {
			cursorhold_time = c.int(p_ut)
		}
		delay_pending :=
			ins_compl_autocomplete_pending() &&
			p_acl > 0 &&
			typebuf.tb_len == 0 &&
			!ins_compl_active() &&
			(get_real_state() & MODE_INSERT) != 0
		wait_time := i64(p_ut) - i64(cursorhold_time)
		if delay_pending {
			delay_left := i64(p_acl) - ins_compl_autocomplete_elapsed()
			if delay_left < 0 {
				delay_left = 0
			}
			if delay_left < wait_time {
				wait_time = delay_left
			}
		}
		result = inbuf_poll(c.int(wait_time), events)
		if result == .kFalse {
			if read_stream_input.s.closed && silent_mode {
				read_error_exit()
			}
			if delay_pending &&
			   ins_compl_autocomplete_elapsed() >= i64(p_acl) &&
			   (buf == nil || maxlen >= 3) &&
			   !typebuf_changed(tb_change_cnt) {
				if buf == nil {
					ibuf: [3]u8 = {K_SPECIAL_INPUT, KS_EXTRA, KE_COMPLETE_DELAY}
					input_enqueue_raw(&ibuf[0], 3)
					return 0
				}
				b := ([^]u8)(buf)
				b[0] = K_SPECIAL_INPUT
				b[1] = KS_EXTRA
				b[2] = KE_COMPLETE_DELAY
				return 3
			}
			reset_cursorhold_wait(tb_change_cnt)
			if trigger_cursorhold() && !typebuf_changed(tb_change_cnt) {
				create_cursorhold_event(events == main_loop.events)
			} else {
				before_blocking()
				result = inbuf_poll(-1, events)
			}
		} else {
			cursorhold_time += c.int((os_hrtime() - wait_start) / 1000000)
		}
	}

	ctrl_c_interrupts = true

	if typebuf_changed(tb_change_cnt) {
		return 0
	}

	if n, ok := try_read(buf, maxlen, tb_change_cnt); ok {
		return n
	}

	if maxlen != 0 && pending_events(events) {
		return push_event_key(buf, maxlen)
	}

	if result == .kNone && ms != 0 {
		read_error_exit()
	}

	return 0
}

@(export)
os_char_avail :: proc "c" () -> bool {
	context = runtime.default_context()
	return inbuf_poll(0, nil) == .kTrue
}

@(export)
os_breakcheck :: proc "c" () {
	context = runtime.default_context()
	if got_int {
		return
	}
	loop_poll_events(&main_loop, 0)
}

@(export)
line_breakcheck :: proc "c" () {
	context = runtime.default_context()
	breakcheck_count += 1
	if breakcheck_count >= BREAKCHECK_SKIP {
		breakcheck_count = 0
		os_breakcheck()
	}
}

@(export)
fast_breakcheck :: proc "c" () {
	context = runtime.default_context()
	breakcheck_count += 1
	if breakcheck_count >= BREAKCHECK_SKIP * 10 {
		breakcheck_count = 0
		os_breakcheck()
	}
}

@(export)
veryfast_breakcheck :: proc "c" () {
	context = runtime.default_context()
	breakcheck_count += 1
	if breakcheck_count >= BREAKCHECK_SKIP * 100 {
		breakcheck_count = 0
		os_breakcheck()
	}
}

@(export)
os_isatty :: proc "c" (fd: c.int) -> bool {
	return uv_guess_handle(fd) == UV_TTY
}

@(export)
input_available :: proc "c" () -> c.size_t {
	input_buffers_init()
	return c.size_t(input_write_pos - input_read_pos)
}

@(private = "file")
input_space :: proc "contextless" () -> c.size_t {
	return c.size_t(uintptr(&input_buffer[0]) + INPUT_BUFFER_SIZE - input_write_pos)
}

@(export)
input_enqueue_raw :: proc "c" (data: ^u8, size: c.size_t) {
	context = runtime.default_context()
	input_buffers_init()
	base := uintptr(&input_buffer[0])
	if input_read_pos > base {
		available := input_available()
		mem.copy(rawptr(base), rawptr(input_read_pos), int(available))
		input_read_pos = base
		input_write_pos = base + uintptr(available)
	}

	to_write := size
	sp := input_space()
	if sp < to_write {
		to_write = sp
	}
	mem.copy(rawptr(input_write_pos), data, int(to_write))
	input_write_pos += uintptr(to_write)
}

@(export)
input_enqueue :: proc "c" (chan_id: u64, keys: String) -> c.size_t {
	context = runtime.default_context()
	input_buffers_init()
	current_ui = chan_id

	if input_read_pos == input_write_pos {
		base := uintptr(&input_buffer[0])
		input_read_pos = base
		input_write_pos = base
	}

	if keys.size > 0 {
		set_vim_var_nr(VV_USERACTIVE, os_realtime())
	}

	ptr := uintptr(rawptr(keys.data))
	end := ptr + uintptr(keys.size)
	start := ptr

	for input_space() >= 19 && ptr < end {
		buf: [19]u8 = {}
		p := rawptr(ptr)
		new_size := trans_special(&p, c.size_t(end - ptr), &buf[0], FSK_KEYCODE, true, nil)
		ptr = uintptr(p)

		if new_size > 0 {
			ptr_slot := rawptr(ptr)
			new_size = handle_mouse_event(&ptr_slot, &buf[0], new_size)
			ptr = uintptr(ptr_slot)
			if new_size > 0 {
				input_enqueue_raw(&buf[0], c.size_t(new_size))
			}
			continue
		}

		cur := ([^]u8)(rawptr(ptr))
		if cur[0] == '<' {
			old_ptr := ptr
			for {
				ptr += 1
				if !(ptr < end && ([^]u8)(rawptr(ptr))[0] != '>') {
					break
				}
			}
			if ([^]u8)(rawptr(ptr))[0] != '>' {
				ptr = old_ptr
				break
			}
			ptr += 1
			continue
		}

		if cur[0] == K_SPECIAL_INPUT {
			b0: u8 = K_SPECIAL_INPUT
			b1: u8 = KS_SPECIAL
			b2: u8 = KE_FILLER
			input_enqueue_raw(&b0, 1)
			input_enqueue_raw(&b1, 1)
			input_enqueue_raw(&b2, 1)
		} else {
			input_enqueue_raw(&cur[0], 1)
		}
		ptr += 1
	}

	rv := c.size_t(ptr - start)
	process_ctrl_c()
	return rv
}

@(private = "file")
check_multiclick :: proc "contextless" (code, grid, row, col: c.int, skip_event: ^bool) -> u8 {
	if code >= KE_MOUSEDOWN && code <= KE_MOUSERIGHT {
		return 0
	}

	no_move := mc_orig_mouse_grid == grid && mc_orig_mouse_col == col && mc_orig_mouse_row == row

	if code == KE_MOUSEMOVE {
		if no_move {
			skip_event^ = true
			return 0
		}
	} else if code == KE_LEFTMOUSE || code == KE_RIGHTMOUSE || code == KE_MIDDLEMOUSE ||
	   code == KE_X1MOUSE || code == KE_X2MOUSE {
		mouse_time := os_hrtime()
		timediff := mouse_time - mc_orig_mouse_time
		mouset := u64(p_mouset) * 1000000
		if code == mc_orig_mouse_code && no_move && timediff < mouset && mc_orig_num_clicks != 4 {
			mc_orig_num_clicks += 1
		} else {
			mc_orig_num_clicks = 1
		}
		mc_orig_mouse_code = code
		mc_orig_mouse_time = mouse_time
	}

	mc_orig_mouse_grid = grid
	mc_orig_mouse_col = col
	mc_orig_mouse_row = row

	modifiers: u8 = 0
	if code != KE_MOUSEMOVE {
		if mc_orig_num_clicks == 2 {
			modifiers |= MOD_MASK_2CLICK
		} else if mc_orig_num_clicks == 3 {
			modifiers |= MOD_MASK_3CLICK
		} else if mc_orig_num_clicks == 4 {
			modifiers |= MOD_MASK_4CLICK
		}
	}
	return modifiers
}

@(private = "file")
handle_mouse_event :: proc "c" (ptr: ^rawptr, buf: ^u8, bufsize: c.uint) -> c.uint {
	context = runtime.default_context()
	b := ([^]u8)(buf)
	mouse_code: c.int = 0
	type: c.int = 0

	if bufsize == 3 {
		mouse_code = c.int(b[2])
		type = c.int(b[1])
	} else if bufsize == 6 {
		mouse_code = c.int(b[5])
		type = c.int(b[4])
	}

	if type != KS_EXTRA ||
	   !((mouse_code >= KE_LEFTMOUSE && mouse_code <= KE_RIGHTRELEASE) ||
			   (mouse_code >= KE_X1MOUSE && mouse_code <= KE_X2RELEASE) ||
			   (mouse_code >= KE_MOUSEDOWN && mouse_code <= KE_MOUSERIGHT) ||
			   mouse_code == KE_MOUSEMOVE) {
		return bufsize
	}

	col: c.int = 0
	row: c.int = 0
	advance: c.int = 0
	fmt := cstring("<%d,%d>%n")
	if libc.sscanf(cstring(ptr^), fmt, &col, &row, &advance) != -1 && advance != 0 {
		if col >= 0 && row >= 0 {
			if col >= Columns {
				col = Columns - 1
			}
			if row >= Rows {
				row = Rows - 1
			}
			mouse_grid = 0
			mouse_row = row
			mouse_col = col
		}
		ptr^ = rawptr(uintptr(ptr^) + uintptr(advance))
	}

	skip_event := false
	modifiers := check_multiclick(mouse_code, mouse_grid, mouse_row, mouse_col, &skip_event)
	if skip_event {
		return 0
	}

	rv := bufsize
	if modifiers != 0 {
		if b[1] != KS_MODIFIER {
			mem.copy(&b[3], &b[0], 3)
			b[0] = K_SPECIAL_INPUT
			b[1] = KS_MODIFIER
			b[2] = modifiers
			rv += 3
		} else {
			b[2] |= modifiers
		}
	}

	return rv
}

@(export)
input_enqueue_mouse :: proc "c" (code: c.int, modifier: u8, grid, row, col: c.int) {
	context = runtime.default_context()
	skip_event := false
	m := modifier | check_multiclick(code, grid, row, col, &skip_event)
	if skip_event {
		return
	}
	buf: [7]u8
	off := 0
	if m != 0 {
		buf[0] = K_SPECIAL_INPUT
		buf[1] = KS_MODIFIER
		buf[2] = m
		off = 3
	}
	buf[off + 0] = K_SPECIAL_INPUT
	buf[off + 1] = KS_EXTRA
	buf[off + 2] = u8(code)

	mouse_grid = grid
	mouse_row = row
	mouse_col = col

	written := c.size_t(3 + off)
	input_enqueue_raw(&buf[0], written)
}

@(export)
input_blocking :: proc "c" () -> bool {
	return blocking
}

@(private = "file")
inbuf_poll :: proc "c" (ms: c.int, events: ^MultiQueue) -> TriState {
	context = runtime.default_context()
	if os_input_ready(events) {
		return .kTrue
	}

	if do_profiling == PROF_YES && ms != 0 {
		prof_input_start()
	}

	if (ms == -1 || ms > 0) && events != main_loop.events && !input_eof {
		blocking = true
		multiqueue_process_events(ch_before_blocking_events)
	}

	// LOOP_PROCESS_EVENTS_UNTIL(&main_loop, NULL, ms, os_input_ready||input_eof)
	deadline := i64(-1)
	if ms >= 0 {
		deadline = i64(os_hrtime() / 1000000) + i64(ms)
	}
	for {
		if os_input_ready(events) || input_eof {
			break
		}
		remaining := i64(-1)
		if ms >= 0 {
			now := i64(os_hrtime() / 1000000)
			remaining = deadline - now
			if remaining <= 0 {
				loop_poll_events(&main_loop, 0)
				break
			}
		}
		if !multiqueue_empty(main_loop.events) {
			multiqueue_process_events(main_loop.events)
			continue
		}
		loop_poll_events(&main_loop, remaining)
		if os_input_ready(events) || input_eof {
			break
		}
		if ms == 0 {
			break
		}
	}
	blocking = false

	if do_profiling == PROF_YES && ms != 0 {
		prof_input_end()
	}

	if os_input_ready(events) {
		return .kTrue
	}
	return input_eof ? .kNone : .kFalse
}

@(private = "file")
input_read_cb :: proc(stream: ^RStream, buf: ^u8, count: c.size_t, data: rawptr, at_eof: bool) -> c.size_t {
	context = runtime.default_context()
	if at_eof {
		input_eof = true
	}
	assert(input_space() >= count)
	input_enqueue_raw(buf, count)
	return count
}

@(private = "file")
process_ctrl_c :: proc "contextless" () {
	if !ctrl_c_interrupts {
		return
	}

	available := int(input_available())
	rp := ([^]u8)(rawptr(input_read_pos))
	i := available - 1
	for ; i >= 0; i -= 1 {
		ch := rp[i]
		if ch == Ctrl_C ||
		   (ch == 'C' && i >= 3 &&
				   rp[i - 3] == K_SPECIAL_INPUT &&
				   rp[i - 2] == KS_MODIFIER &&
				   rp[i - 1] == MOD_MASK_CTRL) {
			rp[i] = Ctrl_C
			got_int = true
			break
		}
	}

	if got_int && i > 0 {
		input_read_pos += uintptr(i)
	}
}

@(private = "file")
push_event_key :: proc "contextless" (buf: ^u8, maxlen: c.int) -> c.int {
	key := [3]u8{K_SPECIAL_INPUT, KS_EXTRA, KE_EVENT}
	b := ([^]u8)(buf)
	buf_idx: c.int = 0
	for {
		b[buf_idx] = key[pek_key_idx]
		buf_idx += 1
		pek_key_idx += 1
		pek_key_idx %= 3
		if !(pek_key_idx > 0 && buf_idx < maxlen) {
			break
		}
	}
	return buf_idx
}

@(export)
os_input_ready :: proc "c" (events: ^MultiQueue) -> bool {
	context = runtime.default_context()
	return typebuf_was_filled || input_available() > 0 || pending_events(events)
}

@(private = "file")
read_error_exit :: proc "contextless" () {
	context = runtime.default_context()
	if silent_mode {
		getout(0)
	}
	preserve_exit(cstring("Nvim: Error reading input, exiting...\n"))
}

@(private = "file")
pending_events :: proc "contextless" (events: ^MultiQueue) -> bool {
	return events != nil && !multiqueue_empty(events)
}
