package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// indent.c port: tabstop/shiftwidth/indent computation.
// Publics are @(export); C-statics are _o dormant plains.

TABSTOP_MAX_O :: 9999

@(export)
tabstop_set :: proc "c" (var_in: ^u8, array: ^^C.int) -> bool {
	context = runtime.default_context()
	var := var_in
	if ([^]u8)(var)[0] == 0 || (([^]u8)(var)[0] == '0' && ([^]u8)(var)[1] == 0) {
		array^ = nil
		return true
	}
	valcount: C.int = 1
	cp := var
	for ([^]u8)(cp)[0] != 0 {
		if cp == var || ([^]u8)(cp)[-1] == ',' {
			end := cp
			end_cs := transmute(cstring)(end)
			if getdigits(&end_cs, false, 1) <= 0 {
				end = transmute(^u8)(end_cs)
				if cp != end {
					emsg(cstring("E487: Argument must be positive"))
				} else {
					semsg(e_invarg2, transmute(cstring)(cp))
				}
				return false
			}
		}
		if ascii_isdigit(([^]u8)(cp)[0]) {
			cp = transmute(^u8)(rawptr(uintptr(cp) + 1))
			continue
		}
		if ([^]u8)(cp)[0] == ',' && uintptr(cp) > uintptr(var) && ([^]u8)(cp)[-1] != ',' && ([^]u8)(cp)[1] != 0 {
			valcount += 1
			cp = transmute(^u8)(rawptr(uintptr(cp) + 1))
			continue
		}
		semsg(e_invarg2, transmute(cstring)(var))
		return false
	}
	arr := transmute(^C.int)(xmalloc(C.size_t(valcount + 1) * 4))
	([^]C.int)(arr)[0] = valcount
	array^ = arr
	t: C.int = 1
	cp = var
	for ([^]u8)(cp)[0] != 0 {
		n := C.int(libc.atoi(transmute(cstring)(cp)))
		if n <= 0 || n > TABSTOP_MAX_O {
			semsg(e_invarg2, transmute(cstring)(cp))
			xfree(rawptr(arr))
			array^ = nil
			return false
		}
		([^]C.int)(arr)[uintptr(t)] = n
		t += 1
		for ([^]u8)(cp)[0] != 0 && ([^]u8)(cp)[0] != ',' {
			cp = transmute(^u8)(rawptr(uintptr(cp) + 1))
		}
		if ([^]u8)(cp)[0] != 0 {
			cp = transmute(^u8)(rawptr(uintptr(cp) + 1))
		}
	}
	return true
}

@(export)
tabstop_padding :: proc "c" (col: C.int, ts_arg: C.longlong, vts: ^C.int) -> C.int {
	context = runtime.default_context()
	ts := ts_arg
	if ts == 0 {
		ts = 8
	}
	if vts == nil || ([^]C.int)(vts)[0] == 0 {
		return C.int(ts - C.longlong(col) % ts)
	}
	tabcol: C.int = 0
	tabcount := ([^]C.int)(vts)[0]
	t: C.int = 1
	padding: C.int = 0
	for t <= tabcount {
		tabcol += ([^]C.int)(vts)[uintptr(t)]
		if tabcol > col {
			padding = tabcol - col
			break
		}
		t += 1
	}
	if t > tabcount {
		padding = ([^]C.int)(vts)[uintptr(tabcount)] - ((col - tabcol) % ([^]C.int)(vts)[uintptr(tabcount)])
	}
	return padding
}

@(export)
tabstop_at :: proc "c" (col: C.int, ts: C.longlong, vts: ^C.int, left: bool) -> C.int {
	context = runtime.default_context()
	if vts == nil || ([^]C.int)(vts)[0] == 0 {
		return C.int(ts)
	}
	tabcol: C.int = 0
	t: C.int = 1
	tab_size: C.int = 0
	tabcount := ([^]C.int)(vts)[0]
	for t <= tabcount {
		tabcol += ([^]C.int)(vts)[uintptr(t)]
		if tabcol > col {
			if left && t == 1 {
				tab_size = col
			} else {
				idx := t
				if left {
					idx -= 1
				}
				tab_size = ([^]C.int)(vts)[uintptr(idx)]
			}
			break
		}
		t += 1
	}
	if t > tabcount {
		tab_size = ([^]C.int)(vts)[uintptr(tabcount)]
	}
	return tab_size
}

@(export)
tabstop_start :: proc "c" (col: C.int, ts: C.int, vts: ^C.int) -> C.int {
	context = runtime.default_context()
	if vts == nil || ([^]C.int)(vts)[0] == 0 {
		return col - col % ts
	}
	tabcol: C.int = 0
	tabcount := ([^]C.int)(vts)[0]
	for t: C.int = 1; t <= tabcount; t += 1 {
		tabcol += ([^]C.int)(vts)[uintptr(t)]
		if tabcol > col {
			return tabcol - ([^]C.int)(vts)[uintptr(t)]
		}
	}
	excess := tabcol % ([^]C.int)(vts)[uintptr(tabcount)]
	return col - (col - excess) % ([^]C.int)(vts)[uintptr(tabcount)]
}

@(export)
tabstop_fromto :: proc "c" (start_col: C.int, end_col: C.int, ts_arg: C.int, vts: ^C.int, ntabs: ^C.int, nspcs: ^C.int) {
	context = runtime.default_context()
	spaces := end_col - start_col
	tabcol: C.int = 0
	padding: C.int = 0
	t: C.int = 0
	ts := ts_arg
	if ts == 0 {
		ts = C.int((^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^)
	}
	if ts == 0 {
		libc.abort()
	}
	if vts == nil || ([^]C.int)(vts)[0] == 0 {
		tabs: C.int = 0
		initspc := ts - (start_col % ts)
		if spaces >= initspc {
			spaces -= initspc
			tabs += 1
		}
		tabs += spaces / ts
		spaces -= (spaces / ts) * ts
		ntabs^ = tabs
		nspcs^ = spaces
		return
	}
	tabcount := ([^]C.int)(vts)[0]
	t = 1
	for t <= tabcount {
		tabcol += ([^]C.int)(vts)[uintptr(t)]
		if tabcol > start_col {
			padding = tabcol - start_col
			break
		}
		t += 1
	}
	if t > tabcount {
		padding = ([^]C.int)(vts)[uintptr(tabcount)] - ((start_col - tabcol) % ([^]C.int)(vts)[uintptr(tabcount)])
	}
	if spaces < padding {
		ntabs^ = 0
		nspcs^ = spaces
		return
	}
	ntabs^ = 1
	spaces -= padding
	for spaces != 0 {
		t += 1
		if t > tabcount {
			break
		}
		padding = ([^]C.int)(vts)[uintptr(t)]
		if spaces < padding {
			nspcs^ = spaces
			return
		}
		ntabs^ += 1
		spaces -= padding
	}
	ntabs^ += spaces / ([^]C.int)(vts)[uintptr(tabcount)]
	nspcs^ = spaces % ([^]C.int)(vts)[uintptr(tabcount)]
}

tabstop_eq_o :: proc "c" (ts1: ^C.int, ts2: ^C.int) -> bool {
	context = runtime.default_context()
	if (ts1 == nil && ts2 != nil) || (ts1 != nil && ts2 == nil) {
		return false
	}
	if ts1 == ts2 {
		return true
	}
	if ([^]C.int)(ts1)[0] != ([^]C.int)(ts2)[0] {
		return false
	}
	for t: C.int = 1; t <= ([^]C.int)(ts1)[0]; t += 1 {
		if ([^]C.int)(ts1)[uintptr(t)] != ([^]C.int)(ts2)[uintptr(t)] {
			return false
		}
	}
	return true
}

@(export)
tabstop_copy :: proc "c" (oldts: ^C.int) -> ^C.int {
	context = runtime.default_context()
	if oldts == nil {
		return nil
	}
	newts := transmute(^C.int)(xmalloc(C.size_t(([^]C.int)(oldts)[0] + 1) * 4))
	for t: C.int = 0; t <= ([^]C.int)(oldts)[0]; t += 1 {
		([^]C.int)(newts)[uintptr(t)] = ([^]C.int)(oldts)[uintptr(t)]
	}
	return newts
}

@(export)
tabstop_count :: proc "c" (ts: ^C.int) -> C.int {
	context = runtime.default_context()
	if ts != nil {
		return ([^]C.int)(ts)[0]
	}
	return 0
}

@(export)
tabstop_first :: proc "c" (ts: ^C.int) -> C.int {
	context = runtime.default_context()
	if ts != nil {
		return ([^]C.int)(ts)[1]
	}
	return 8
}

get_sw_value_pos_o :: proc "c" (buf: rawptr, pos: ^Pos_T, left: bool) -> C.int {
	context = runtime.default_context()
	save_cursor := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos^
	sw_value := get_sw_value_col(buf, get_nolist_virtcol_e(), left)
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
	return sw_value
}

@(export)
get_sw_value_indent :: proc "c" (buf: rawptr, left: bool) -> C.int {
	context = runtime.default_context()
	pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	pos.col = C.int(getwhitecols_curline())
	return get_sw_value_pos_o(buf, &pos, left)
}

@(export)
get_sw_value_col :: proc "c" (buf: rawptr, col: C.int, left: bool) -> C.int {
	context = runtime.default_context()
	sw := (^C.longlong)(uintptr(buf) + B_P_SW_OFF)^
	if sw != 0 {
		return C.int(sw)
	}
	ts := (^C.longlong)(uintptr(buf) + B_P_TS_OFF)^
	vts := (^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^)
	return tabstop_at(col, ts, vts, left)
}

@(export)
get_sw_value :: proc "c" (buf: rawptr) -> C.int {
	context = runtime.default_context()
	return get_sw_value_col(buf, 0, false)
}

@(export)
get_sts_value :: proc "c" () -> C.int {
	context = runtime.default_context()
	sts := (^C.longlong)(uintptr(curbuf) + B_P_STS_OFF)^
	if sts < 0 {
		return get_sw_value(curbuf)
	}
	return C.int(sts)
}

@(export)
get_indent :: proc "c" () -> C.int {
	context = runtime.default_context()
	return indent_size_ts(transmute(cstring)(get_cursor_line_ptr()), (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
}

@(export)
get_indent_lnum :: proc "c" (lnum: C.int) -> C.int {
	context = runtime.default_context()
	return indent_size_ts(transmute(cstring)(ml_get(lnum)), (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
}

@(export)
get_indent_buf :: proc "c" (buf: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	return indent_size_ts(transmute(cstring)(ml_get_buf(buf, lnum)), (^C.longlong)(uintptr(buf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
}

@(export)
indent_size_no_ts :: proc "c" (ptr_in: ^u8) -> C.int {
	context = runtime.default_context()
	tab_size := byte2cells(9)
	vcol: C.int = 0
	ptr := ptr_in
	for {
		c := ([^]u8)(ptr)[0]
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
		if c == ' ' {
			vcol += 1
		} else if c == 9 {
			vcol += tab_size
		} else {
			return vcol
		}
	}
}

@(export)
indent_size_ts :: proc "c" (ptr_in: cstring, ts: C.longlong, vts: ^C.int) -> C.int {
	context = runtime.default_context()
	vcol: C.int = 0
	tabstop_width: C.int
	next_tab_vcol: C.int
	ptr := transmute(^u8)(ptr_in)
	if vts == nil || ([^]C.int)(vts)[0] < 1 {
		if ts == 0 {
			tabstop_width = 8
		} else {
			tabstop_width = C.int(ts)
		}
		next_tab_vcol = tabstop_width
	} else {
		cur_tabstop: C.int = 1
		last_tabstop := ([^]C.int)(vts)[0]
		for cur_tabstop != last_tabstop {
			cur_vcol := vcol
			vcol += ([^]C.int)(vts)[uintptr(cur_tabstop)]
			cur_tabstop += 1
			if cur_vcol >= vcol {
				libc.abort()
			}
			for cur_vcol != vcol {
				c := ([^]u8)(ptr)[0]
				ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
				if c == ' ' {
					cur_vcol += 1
				} else if c == 9 {
					break
				} else {
					return cur_vcol
				}
			}
		}
		tabstop_width = ([^]C.int)(vts)[uintptr(last_tabstop)]
		next_tab_vcol = vcol + tabstop_width
	}
	if tabstop_width == 0 {
		libc.abort()
	}
	for {
		c := ([^]u8)(ptr)[0]
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
		if c == ' ' {
			vcol += 1
			if vcol == next_tab_vcol {
				next_tab_vcol += tabstop_width
			}
		} else if c == 9 {
			vcol = next_tab_vcol
			next_tab_vcol += tabstop_width
		} else {
			return vcol
		}
	}
}

@(export)
get_number_indent :: proc "c" (lnum: C.int) -> C.int {
	context = runtime.default_context()
	pos := Pos_T{}
	lead_len: C.int = 0
	line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	if lnum > line_count {
		return -1
	}
	pos.lnum = 0
	if (State & MODE_INSERT) != 0 || has_format_option(C.int(FO_Q_COMS_O)) {
		lead_len = get_leader_len(ml_get(lnum), nil, false, true)
	}
	flp := (^u8)((^rawptr)(uintptr(curbuf) + B_P_FLP_OFF)^)
	regmatch: Regmatch_T
	regmatch.regprog = vim_regcomp(transmute(cstring)(flp), RE_MAGIC)
	if regmatch.regprog != nil {
		regmatch.rm_ic = 0
		if vim_regexec_r(&regmatch, transmute(^u8)(rawptr(uintptr(ml_get(lnum)) + uintptr(lead_len))), 0) != 0 {
			pos.lnum = lnum
			pos.col = C.int(uintptr(regmatch.endp[0]) - uintptr(ml_get(lnum)))
			pos.coladd = 0
		}
		vim_regfree(regmatch.regprog)
	}
	if pos.lnum == 0 || ([^]u8)(ml_get_pos(rawptr(&pos)))[0] == 0 {
		return -1
	}
	col: C.int = 0
	getvcol(curwin, &pos, &col, nil, nil, 0)
	return col
}

W_BRIOPT_SHIFT_OFF_O :: 4240
W_BRIOPT_MIN_OFF_O :: 4236
W_BRIOPT_VCOL_OFF_O :: 4252
RE_AUTO_O :: 8
RE_STRICT_O :: 4

foreign _ {
	// msg_progress now defined in message.odin — call directly.
}

@(export)
briopt_check :: proc "c" (briopt_in: ^u8, wp: rawptr) -> bool {
	context = runtime.default_context()
	bri_shift: C.int = 0
	bri_min: C.int = 20
	bri_sbr := false
	bri_list: C.int = 0
	bri_vcol: C.int = 0
	briopt := briopt_in
	p: ^u8 = empty_string_opt()
	if briopt != nil {
		p = briopt
	} else if wp != nil {
		p = (^u8)((^rawptr)(uintptr(wp) + W_P_BRIOPT_OFF)^)
	}
	for ([^]u8)(p)[0] != 0 {
		if libc.strncmp(transmute(cstring)(p), cstring("shift:"), 6) == 0 && ((([^]u8)(p)[6] == '-' && ascii_isdigit(([^]u8)(p)[7])) || ascii_isdigit(([^]u8)(p)[6])) {
			p = transmute(^u8)(rawptr(uintptr(p) + 6))
			bri_shift = getdigits_int(&p, true, 0)
		} else if libc.strncmp(transmute(cstring)(p), cstring("min:"), 4) == 0 && ascii_isdigit(([^]u8)(p)[4]) {
			p = transmute(^u8)(rawptr(uintptr(p) + 4))
			bri_min = getdigits_int(&p, true, 0)
		} else if libc.strncmp(transmute(cstring)(p), cstring("sbr"), 3) == 0 {
			p = transmute(^u8)(rawptr(uintptr(p) + 3))
			bri_sbr = true
		} else if libc.strncmp(transmute(cstring)(p), cstring("list:"), 5) == 0 {
			p = transmute(^u8)(rawptr(uintptr(p) + 5))
			pp := transmute(cstring)(p)
			bri_list = C.int(getdigits(&pp, false, 0))
			p = transmute(^u8)(pp)
		} else if libc.strncmp(transmute(cstring)(p), cstring("column:"), 7) == 0 {
			p = transmute(^u8)(rawptr(uintptr(p) + 7))
			pp := transmute(cstring)(p)
			bri_vcol = C.int(getdigits(&pp, false, 0))
			p = transmute(^u8)(pp)
		}
		if ([^]u8)(p)[0] != ',' && ([^]u8)(p)[0] != 0 {
			return false
		}
		if ([^]u8)(p)[0] == ',' {
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
	}
	if wp == nil {
		return true
	}
	(^C.int)(uintptr(wp) + W_BRIOPT_SHIFT_OFF_O)^ = bri_shift
	(^C.int)(uintptr(wp) + W_BRIOPT_MIN_OFF_O)^ = bri_min
	(^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ = bri_sbr
	(^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^ = bri_list
	(^C.int)(uintptr(wp) + W_BRIOPT_VCOL_OFF_O)^ = bri_vcol
	return true
}

bri_prev_indent_g: C.int = 0
bri_prev_ts_g: C.longlong = 0
bri_prev_vts_g: ^C.int = nil
bri_prev_fnum_g: C.int = 0
bri_prev_line_g: ^u8 = nil
bri_prev_tick_g: C.longlong = 0
bri_prev_list_g: C.int = 0
bri_prev_listopt_g: C.int = 0
bri_prev_no_ts_g: bool = false
bri_prev_dy_uhex_g: C.uint = 0
bri_prev_flp_g: ^u8 = nil
SIN_UNDO_O :: 4
// INDENT_SET_O already in textformat.odin — reuse directly.
INDENT_INC_O :: 2
INDENT_DEC_O :: 3
B_IND_HASH_COMMENT_OFF_O :: 11080
B_P_ET_OFF_O :: 10388

foreign _ {
	@(link_name = "replace_join")
	replace_join_e :: proc "c" (off: C.int) ---
}

@(export)
set_indent :: proc "c" (size: C.int, flags: C.int) -> bool {
	context = runtime.default_context()
	newline: ^u8
	oldline: ^u8
	s: ^u8
	doit := false
	ind_done: C.int = 0
	tab_pad: C.int = 0
	retval := false
	orig_char_len: C.int = -1
	todo := size
	ind_len: C.int = 0
	p := get_cursor_line_ptr()
	oldline = p
	line_len := get_cursor_line_len() + 1
	b_p_et := (^C.int)(uintptr(curbuf) + B_P_ET_OFF_O)^
	b_p_pi := (^C.int)(uintptr(curbuf) + B_P_PI_OFF)^
	if b_p_et == 0 || ((flags & SIN_INSERT_O) == 0 && b_p_pi != 0) {
		ind_col: C.int = 0
		if ((flags & SIN_INSERT_O) == 0 && b_p_pi != 0) {
			ind_done = 0
			for todo > 0 && ascii_iswhite(([^]u8)(p)[0]) {
				if ([^]u8)(p)[0] == 9 {
					tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
					if todo < tab_pad {
						break
					}
					todo -= tab_pad
					ind_len += 1
					ind_done += tab_pad
				} else {
					todo -= 1
					ind_len += 1
					ind_done += 1
				}
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			ind_col = ind_done
			if b_p_et != 0 {
				orig_char_len = ind_len
			}
			tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
			if todo >= tab_pad && orig_char_len == -1 {
				doit = true
				todo -= tab_pad
				ind_len += 1
				ind_col += tab_pad
			}
		}
		for {
			tab_pad = tabstop_padding(ind_col, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
			if todo < tab_pad {
				break
			}
			if ([^]u8)(p)[0] != 9 {
				doit = true
			} else {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			todo -= tab_pad
			ind_len += 1
			ind_col += tab_pad
		}
	}
	for todo > 0 {
		if ([^]u8)(p)[0] != ' ' {
			doit = true
		} else {
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
		todo -= 1
		ind_len += 1
	}
	if !doit && !ascii_iswhite(([^]u8)(p)[0]) && (flags & SIN_INSERT_O) == 0 {
		return false
	}
	if (flags & SIN_INSERT_O) != 0 {
		p = oldline
	} else {
		p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
		line_len -= C.int(uintptr(p) - uintptr(oldline))
	}
	skipcols: C.int = 0
	if orig_char_len != -1 {
		newline_size := orig_char_len + size - ind_done + line_len
		newline = transmute(^u8)(xmalloc(C.size_t(newline_size)))
		todo = size - ind_done
		ind_len = orig_char_len + todo
		p = oldline
		s = newline
		skipcols = orig_char_len
		for orig_char_len > 0 {
			([^]u8)(s)[0] = ([^]u8)(p)[0]
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			orig_char_len -= 1
		}
		for ascii_iswhite(([^]u8)(p)[0]) {
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
	} else {
		todo = size
		newline = transmute(^u8)(xmalloc(C.size_t(ind_len + line_len)))
		s = newline
	}
	if b_p_et == 0 {
		if ((flags & SIN_INSERT_O) == 0 && b_p_pi != 0) {
			p = oldline
			ind_done = 0
			for todo > 0 && ascii_iswhite(([^]u8)(p)[0]) {
				if ([^]u8)(p)[0] == 9 {
					tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
					if todo < tab_pad {
						break
					}
					todo -= tab_pad
					ind_done += tab_pad
				} else {
					todo -= 1
					ind_done += 1
				}
				([^]u8)(s)[0] = ([^]u8)(p)[0]
				s = transmute(^u8)(rawptr(uintptr(s) + 1))
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				skipcols += 1
			}
			tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
			if todo >= tab_pad {
				([^]u8)(s)[0] = 9
				s = transmute(^u8)(rawptr(uintptr(s) + 1))
				todo -= tab_pad
				ind_done += tab_pad
			}
			p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
		}
		for {
			tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
			if todo < tab_pad {
				break
			}
			([^]u8)(s)[0] = 9
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
			todo -= tab_pad
			ind_done += tab_pad
		}
	}
	for todo > 0 {
		([^]u8)(s)[0] = ' '
		s = transmute(^u8)(rawptr(uintptr(s) + 1))
		todo -= 1
	}
	libc.memmove(rawptr(s), rawptr(p), C.size_t(line_len))
	if ((flags & SIN_UNDO_O) == 0 || u_savesub((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^) == OK) {
		old_offset := C.int(uintptr(p) - uintptr(oldline))
		new_offset := C.int(uintptr(s) - uintptr(newline))
		ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, newline, false)
		if (flags & SIN_NOMARK_O) == 0 {
			extmark_splice_cols(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, skipcols, old_offset - skipcols, new_offset - skipcols, kExtmarkUndo)
		}
		if (flags & SIN_CHANGED_O) != 0 {
			changed_bytes((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0)
		}
		if saved_cursor.lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
			if saved_cursor.col >= old_offset {
				saved_cursor.col += ind_len - old_offset
			} else if saved_cursor.col >= new_offset {
				saved_cursor.col = new_offset
			}
		}
		retval = true
	} else {
		xfree(rawptr(newline))
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = ind_len
	return retval
}

@(export)
may_do_si :: proc "c" () -> bool {
	context = runtime.default_context()
	return (^C.int)(uintptr(curbuf) + B_P_SI_OFF)^ != 0 && (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ == 0 && ([^]u8)((^u8)((^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^))[0] == 0 && p_paste_g == 0
}

@(export)
preprocs_left :: proc "c" () -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(curbuf) + B_P_SI_OFF)^ != 0 && (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ == 0 {
		return true
	}
	return (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ != 0 && in_cinkeys('#', ' ', true) && (^C.int)(uintptr(curbuf) + B_IND_HASH_COMMENT_OFF_O)^ == 0
}

@(export)
copy_indent :: proc "c" (size: C.int, src: ^u8) -> bool {
	context = runtime.default_context()
	p: ^u8 = nil
	line: ^u8 = nil
	ind_len: C.int = 0
	line_len: C.int = 0
	tab_pad: C.int = 0
	for round: C.int = 1; round <= 2; round += 1 {
		todo := size
		ind_len = 0
		ind_done: C.int = 0
		ind_col: C.int = 0
		s := src
		for todo > 0 && ascii_iswhite(([^]u8)(s)[0]) {
			if ([^]u8)(s)[0] == 9 {
				tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
				if todo < tab_pad {
					break
				}
				todo -= tab_pad
				ind_done += tab_pad
				ind_col += tab_pad
			} else {
				todo -= 1
				ind_done += 1
				ind_col += 1
			}
			ind_len += 1
			if p != nil {
				([^]u8)(p)[0] = ([^]u8)(s)[0]
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			s = transmute(^u8)(rawptr(uintptr(s) + 1))
		}
		tab_pad = tabstop_padding(ind_done, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
		if todo >= tab_pad && (^C.int)(uintptr(curbuf) + B_P_ET_OFF_O)^ == 0 {
			todo -= tab_pad
			ind_len += 1
			ind_col += tab_pad
			if p != nil {
				([^]u8)(p)[0] = 9
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
		}
		if (^C.int)(uintptr(curbuf) + B_P_ET_OFF_O)^ == 0 {
			for {
				tab_pad = tabstop_padding(ind_col, (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^))
				if todo < tab_pad {
					break
				}
				todo -= tab_pad
				ind_len += 1
				ind_col += tab_pad
				if p != nil {
					([^]u8)(p)[0] = 9
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
			}
		}
		for todo > 0 {
			todo -= 1
			ind_len += 1
			if p != nil {
				([^]u8)(p)[0] = ' '
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
		}
		if p == nil {
			line_len = get_cursor_line_len() + 1
			line = transmute(^u8)(xmalloc(C.size_t(ind_len + line_len)))
			p = line
		}
	}
	libc.memmove(rawptr(p), rawptr(get_cursor_line_ptr()), C.size_t(line_len))
	ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, line, false)
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = ind_len
	return true
}

@(export)
ins_try_si :: proc "c" (c: C.int) {
	context = runtime.default_context()
	if ((did_si_g || can_si_back_g) && c == '{') || (can_si_g && c == '}' && inindent(0)) {
		old_pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
		ptr: ^u8
		i: C.int = 0
		temp := false
		if c == '}' {
			pos := findmatch(nil, '{')
			if pos != nil {
				old_pos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				ptr = ml_get(pos.lnum)
				i = pos.col
				if i > 0 {
					i -= 1
					for i > 0 && ascii_iswhite(([^]u8)(ptr)[uintptr(i)]) {
						i -= 1
					}
				}
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = pos.lnum
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = i
				if ([^]u8)(ptr)[uintptr(i)] == ')' {
					pos2 := findmatch(nil, '(')
					if pos2 != nil {
						(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos2^
					}
				}
				i = get_indent()
				(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_pos
				if (State & VREPLACE_FLAG_O) != 0 {
					change_indent(INDENT_SET_O, i, false, true)
				} else {
					set_indent(i, SIN_CHANGED_O)
				}
			}
		} else if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 {
			temp = true
			if c == '{' && can_si_back_g && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > 1 {
				old_pos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				i = get_indent()
				for (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > 1 {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
					ptr = transmute(^u8)(skipwhite(transmute(cstring)(ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^))))
					if ([^]u8)(ptr)[0] != '#' && ([^]u8)(ptr)[0] != 0 {
						break
					}
				}
				if get_indent() >= i {
					temp = false
				}
				(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_pos
			}
			if temp {
				shift_line(true, false, 1, 1)
			}
		}
	}
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 && can_si_g && c == '#' && inindent(0) {
		old_indent_g = get_indent()
		set_indent(0, SIN_CHANGED_O)
	}
	ai_col_g = min(ai_col_g, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)
}

@(export)
change_indent :: proc "c" (type: C.int, amount: C.int, round: bool, call_changed_bytes: bool) {
	context = runtime.default_context()
	insstart_less: C.int = 0
	orig_col: C.int = 0
	orig_line: ^u8 = nil
	if (State & VREPLACE_FLAG_O) != 0 {
		orig_line = xstrnsave_c(transmute(cstring)(get_cursor_line_ptr()), C.size_t(get_cursor_line_len()))
		orig_col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	}
	save_p_list := (^C.int)(uintptr(curwin) + W_P_LIST_OFF)^
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = 0
	vc := getvcol_nolist((^Pos_T)(rawptr(uintptr(curwin) + W_CURSOR_OFF)))
	vcol := vc
	start_col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	new_cursor_col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	beginline(BL_WHITE)
	new_cursor_col -= (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	insstart_less = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	if new_cursor_col < 0 {
		vcol = get_indent() - vcol
	}
	if new_cursor_col > 0 {
		start_col = -1
	}
	if type == INDENT_SET_O {
		sin := C.int(0)
		if call_changed_bytes {
			sin = SIN_CHANGED_O
		}
		set_indent(amount, sin)
	} else {
		save_State := State
		if (State & VREPLACE_FLAG_O) != 0 {
			State = MODE_INSERT
		}
		ccb := C.int(0)
		if call_changed_bytes {
			ccb = 1
		}
		shift_line(type == INDENT_DEC_O, round, 1, ccb)
		State = save_State
	}
	insstart_less -= (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	if new_cursor_col >= 0 {
		if new_cursor_col == 0 {
			insstart_less = MAXCOL
		}
		new_cursor_col += (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	} else if (State & MODE_INSERT) == 0 {
		new_cursor_col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	} else {
		vcol = get_indent() - vcol
		end_vcol := vcol
		if end_vcol < 0 {
			end_vcol = 0
		}
		(^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ = end_vcol
		new_cursor_col = 0
		line := get_cursor_line_ptr()
		vcol = 0
		if ([^]u8)(line)[0] != 0 {
			csarg: CharsizeArg_O
			cstype := init_charsize_arg(&csarg, curwin, 0, line)
			ci := utf_ptr2StrCharInfo_o(line)
			for {
				next_vcol := vcol + win_charsize_o(cstype, vcol, ci.ptr, ci.chr.value, &csarg).width
				if next_vcol > end_vcol {
					break
				}
				vcol = next_vcol
				ci = utfc_next_o(ci)
				if ([^]u8)(ci.ptr)[0] == 0 {
					break
				}
			}
			new_cursor_col = C.int(uintptr(ci.ptr) - uintptr(line))
		}
		if vcol != (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = new_cursor_col
			ptrlen := C.size_t((^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ - vcol)
			ptr := transmute(^u8)(xmallocz(ptrlen))
			libc.memset(rawptr(ptr), C.int(32), ptrlen)
			new_cursor_col += C.int(ptrlen)
			ins_str(ptr, ptrlen)
			xfree(rawptr(ptr))
		}
		insstart_less = MAXCOL
	}
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = save_p_list
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = max(C.int(0), new_cursor_col)
	(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	changed_cline_bef_curs(curwin)
	if (State & MODE_INSERT) != 0 {
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == Insstart_g.lnum && Insstart_g.col != 0 {
			if C.int(Insstart_g.col) <= insstart_less {
				Insstart_g.col = 0
			} else {
				Insstart_g.col -= insstart_less
			}
		}
		if ai_col_g <= insstart_less {
			ai_col_g = 0
		} else {
			ai_col_g -= insstart_less
		}
	}
	replace_normal := (State & REPLACE_FLAG) != 0 && (State & VREPLACE_FLAG_O) == 0
	if replace_normal && start_col >= 0 {
		for start_col > (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ {
			replace_join_e(0)
			start_col -= 1
		}
		for start_col < (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ {
			replace_push_nul_e()
			start_col += 1
		}
	}
	if (State & VREPLACE_FLAG_O) != 0 {
		new_line := xstrnsave_c(transmute(cstring)(get_cursor_line_ptr()), C.size_t(get_cursor_line_len()))
		([^]u8)(new_line)[uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)] = 0
		new_col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
		ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, orig_line, false)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = orig_col
		curbuf_splice_pending_g += 1
		backspace_until_column_e(0)
		ins_bytes(new_line)
		xfree(rawptr(new_line))
		curbuf_splice_pending_g -= 1
		delta := orig_col - new_col
		delta_pos := C.int(0)
		delta_neg := C.int(0)
		if delta < 0 {
			delta_neg = -delta
		}
		if delta > 0 {
			delta_pos = delta
		}
		extmark_splice_cols(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, new_col, delta_neg, delta_pos, kExtmarkUndo)
	}
}

@(export)
get_breakindent_win :: proc "c" (wp: rawptr, line_in: ^u8) -> C.int {
	context = runtime.default_context()
	line := line_in
	bri: C.int = 0
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	eff_wwidth := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp) + win_col_off2(wp)
	lcs_tab1 := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^
	no_ts := (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && lcs_tab1 == 0
	if bri_prev_fnum_g != (^C.int)(uintptr(buf) + B_FNUM_OFF)^ || bri_prev_ts_g != (^C.longlong)(uintptr(buf) + B_P_TS_OFF)^ || bri_prev_vts_g != (^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^) || bri_prev_tick_g != buf_changedtick_inline(buf) || bri_prev_listopt_g != (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^ || bri_prev_no_ts_g != no_ts || bri_prev_dy_uhex_g != (dy_flags_g & K_OPT_DY_UHEX_O) || bri_prev_flp_g == nil || libc.strcmp(transmute(cstring)(bri_prev_flp_g), transmute(cstring)(get_flp_value(buf))) != 0 || bri_prev_line_g == nil || libc.strcmp(transmute(cstring)(bri_prev_line_g), transmute(cstring)(line)) != 0 {
		bri_prev_fnum_g = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
		xfree(rawptr(bri_prev_line_g))
		bri_prev_line_g = xstrdup(line)
		bri_prev_ts_g = (^C.longlong)(uintptr(buf) + B_P_TS_OFF)^
		bri_prev_vts_g = (^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^)
		if (^C.int)(uintptr(wp) + W_BRIOPT_VCOL_OFF_O)^ == 0 {
			if no_ts {
				bri_prev_indent_g = indent_size_no_ts(line)
			} else {
				bri_prev_indent_g = indent_size_ts(transmute(cstring)(line), (^C.longlong)(uintptr(buf) + B_P_TS_OFF)^, (^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
			}
		}
		bri_prev_tick_g = buf_changedtick_inline(buf)
		bri_prev_listopt_g = (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^
		bri_prev_list_g = 0
		bri_prev_no_ts_g = no_ts
		bri_prev_dy_uhex_g = dy_flags_g & K_OPT_DY_UHEX_O
		xfree(rawptr(bri_prev_flp_g))
		bri_prev_flp_g = xstrdup(get_flp_value(buf))
		if (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_BRIOPT_VCOL_OFF_O)^ == 0 {
			regmatch: Regmatch_T
			regmatch.regprog = vim_regcomp(transmute(cstring)(bri_prev_flp_g), RE_MAGIC + RE_STRING_O + RE_AUTO_O + RE_STRICT_O)
			if regmatch.regprog != nil {
				regmatch.rm_ic = 0
				if vim_regexec_r(&regmatch, line, 0) != 0 {
					if (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^ > 0 {
						bri_prev_list_g += (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^
					} else {
						ptr := regmatch.startp[0]
						end_ptr := regmatch.endp[0]
						indent: C.int = 0
						for uintptr(ptr) < uintptr(end_ptr) {
							indent += win_chartabsize(wp, ptr, indent)
							ptr = transmute(^u8)(rawptr(uintptr(ptr) + uintptr(utfc_ptr2len(transmute(cstring)(ptr)))))
						}
						bri_prev_indent_g = indent
					}
				}
				vim_regfree(regmatch.regprog)
			}
		}
	}
	if (^C.int)(uintptr(wp) + W_BRIOPT_VCOL_OFF_O)^ != 0 {
		bri = (^C.int)(uintptr(wp) + W_BRIOPT_VCOL_OFF_O)^
		bri_prev_list_g = 0
	} else {
		bri = bri_prev_indent_g + (^C.int)(uintptr(wp) + W_BRIOPT_SHIFT_OFF_O)^
	}
	bri += win_col_off2(wp)
	if (^C.int)(uintptr(wp) + W_BRIOPT_LIST_OFF)^ > 0 {
		bri += bri_prev_list_g
	}
	if (^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ {
		bri -= vim_strsize(transmute(cstring)(get_showbreak_value(wp)))
	}
	if bri < 0 {
		bri = 0
	} else if bri > eff_wwidth - (^C.int)(uintptr(wp) + W_BRIOPT_MIN_OFF_O)^ {
		if eff_wwidth - (^C.int)(uintptr(wp) + W_BRIOPT_MIN_OFF_O)^ < 0 {
			bri = 0
		} else {
			bri = eff_wwidth - (^C.int)(uintptr(wp) + W_BRIOPT_MIN_OFF_O)^
		}
	}
	return bri
}

@(export)
inindent :: proc "c" (extra: C.int) -> bool {
	context = runtime.default_context()
	col: C.int = 0
	ptr := get_cursor_line_ptr()
	for ascii_iswhite(([^]u8)(ptr)[0]) {
		col += 1
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
	}
	if col >= (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ + extra {
		return true
	}
	return false
}

@(export)
op_reindent :: proc "c" (oap: rawptr, how: Indenter_T) {
	context = runtime.default_context()
	i: C.int = 0
	first_changed: C.int = 0
	last_changed: C.int = 0
	start_lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	if (^C.int)(uintptr(curbuf) + B_P_MA_OFF)^ == 0 {
		emsg(e_modifiable)
		return
	}
	if u_savecommon(curbuf, start_lnum - 1, start_lnum + line_count, start_lnum + line_count, false) == OK {
		amount: C.int = 0
		i = line_count - 1
		for i >= 0 && !got_int {
			if i > 1 && (i % 50 == 0 || i == line_count - 1) && i64(line_count) > p_report {
				libc.snprintf(&IObuff[0], C.size_t(IOSIZE_O), cstring("%lld lines to indent... "), C.longlong(i))
				save_lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = start_lnum
				msg_progress(transmute(^u8)(&IObuff[0]), cstring("nvim.indent"), cstring("running"), 0, true, false)
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = save_lnum
			}
			lisp_indent := how == get_lisp_indent
			if i != line_count - 1 || line_count == 1 || !lisp_indent {
				l := skipwhite(transmute(cstring)(get_cursor_line_ptr()))
				if ([^]u8)(transmute(^u8)(l))[0] == 0 {
					amount = 0
				} else {
					amount = how()
				}
				if amount >= 0 && set_indent(amount, 0) {
					if first_changed == 0 {
						first_changed = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					}
					last_changed = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				}
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
			i -= 1
		}
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = start_lnum
	beginline(BL_SOL | BL_FIX)
	if last_changed != 0 {
		end_ln := last_changed + 1
		if (^bool)(uintptr(oap) + OAP_IS_VISUAL)^ {
			end_ln = start_lnum + line_count
		}
		changed_lines(curbuf, first_changed, 0, end_ln, 0, true)
	} else if (^bool)(uintptr(oap) + OAP_IS_VISUAL)^ {
		redraw_curbuf_later(UPD_INVERTED_S)
	}
	if i64(line_count) > p_report {
		n := line_count - (i + 1)
		single := n == 1
		fmt := cstring("%lld lines indented ")
		if single {
			fmt = cstring("%lld line indented ")
		}
		libc.snprintf(&IObuff[0], C.size_t(IOSIZE_O), fmt, C.longlong(n))
		msg_progress(transmute(^u8)(&IObuff[0]), cstring("nvim.indent"), cstring("success"), 0, true, false)
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
	}
}

emsg_text_too_long_o :: proc "c" () {
	context = runtime.default_context()
	emsg(cstring("E1240: Resulting text too long"))
	if trylevel_g == 0 {
		got_int = true
	}
}

@(export)
ex_retab :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	got_tab := false
	num_spaces: C.int = 0
	start_col: C.int = 0
	start_vcol: C.longlong = 0
	new_line: ^u8 = transmute(^u8)(rawptr(uintptr(1)))
	new_vts_array: ^C.int = nil
	new_ts_str: ^u8
	first_line: C.int = 0
	last_line: C.int = 0
	is_indent_only := false
	save_list := (^C.int)(uintptr(curwin) + W_P_LIST_OFF)^
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = 0
	ptr := (^u8)((^rawptr)(uintptr(eap) + EXARG_ARG_OFF)^)
	if libc.strncmp(transmute(cstring)(ptr), cstring("-indentonly"), 11) == 0 && (ascii_iswhite(([^]u8)(ptr)[11]) || ([^]u8)(ptr)[11] == 0) {
		is_indent_only = true
		ptr = transmute(^u8)(skipwhite(transmute(cstring)(rawptr(uintptr(ptr) + 11))))
	}
	new_ts_str = ptr
	if !tabstop_set(ptr, &new_vts_array) {
		return
	}
	for ascii_isdigit(([^]u8)(ptr)[0]) || ([^]u8)(ptr)[0] == ',' {
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
	}
	if new_vts_array == nil {
		new_vts_array = (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
		new_ts_str = nil
	} else {
		new_ts_str = xmemdupz(rawptr(new_ts_str), C.size_t(uintptr(ptr) - uintptr(new_ts_str)))
	}
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	forceit := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^
	lnum := line1
	for !got_int && lnum <= line2 {
		ptr = ml_get(lnum)
		old_len := ml_get_len(lnum)
		col: C.int = 0
		vcol: C.longlong = 0
		did_undo := false
		for {
			if ascii_iswhite(([^]u8)(ptr)[uintptr(col)]) {
				if !got_tab && num_spaces == 0 {
					start_vcol = vcol
					start_col = col
				}
				if ([^]u8)(ptr)[uintptr(col)] == ' ' {
					num_spaces += 1
				} else {
					got_tab = true
				}
			} else {
				if got_tab || (forceit != 0 && num_spaces > 1) {
					len := C.int(vcol - start_vcol)
					num_spaces = len
					num_tabs: C.int = 0
					if (^C.int)(uintptr(curbuf) + B_P_ET_OFF_O)^ == 0 {
						t: C.int = 0
						s: C.int = 0
						tabstop_fromto(C.int(start_vcol), C.int(vcol), C.int((^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^), new_vts_array, &t, &s)
						num_tabs = t
						num_spaces = s
					}
					if (^C.int)(uintptr(curbuf) + B_P_ET_OFF_O)^ != 0 || got_tab || (num_spaces + num_tabs < len) {
						if !did_undo {
							did_undo = true
							if u_save(lnum - 1, lnum + 1) == 0 {
								new_line = nil
								break
							}
						}
						len = num_spaces + num_tabs
						new_len := old_len - col + start_col + len + 1
						if new_len <= 0 || new_len >= MAXCOL {
							emsg_text_too_long_o()
							break
						}
						new_line = transmute(^u8)(xmalloc(C.size_t(new_len)))
						if start_col > 0 {
							libc.memmove(rawptr(new_line), rawptr(ptr), C.size_t(start_col))
						}
						libc.memmove(rawptr(uintptr(new_line) + uintptr(start_col) + uintptr(len)), rawptr(uintptr(ptr) + uintptr(col)), C.size_t(old_len) - C.size_t(col) + 1)
						np := transmute(^u8)(rawptr(uintptr(new_line) + uintptr(start_col)))
						ptr = np
						for cc: C.int = 0; cc < len; cc += 1 {
							([^]u8)(ptr)[uintptr(cc)] = ' '
							if cc < num_tabs {
								([^]u8)(ptr)[uintptr(cc)] = 9
							}
						}
						if ml_replace(lnum, new_line, false) == OK {
							new_line = (^Memline_O)(uintptr(curbuf) + 8).line_ptr
							extmark_splice_cols(curbuf, lnum - 1, 0, old_len, new_len - 1, kExtmarkUndo)
						}
						if first_line == 0 {
							first_line = lnum
						}
						last_line = lnum
						ptr = new_line
						old_len = new_len - 1
						col = start_col + len
					}
				}
				got_tab = false
				num_spaces = 0
				if is_indent_only {
					break
				}
			}
			if ([^]u8)(ptr)[uintptr(col)] == 0 {
				break
			}
			vcol += C.longlong(win_chartabsize(curwin, transmute(^u8)(rawptr(uintptr(ptr) + uintptr(col))), C.int(vcol)))
			if vcol >= MAXCOL {
				emsg_text_too_long_o()
				break
			}
			col += utfc_ptr2len(transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
		}
		if new_line == nil {
			break
		}
		line_breakcheck()
		lnum += 1
	}
	if got_int {
		emsg(cstring("Interrupted"))
	}
	if tabstop_count((^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)) == 0 && tabstop_count(new_vts_array) == 1 && (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^ == C.longlong(tabstop_first(new_vts_array)) {
	} else if tabstop_count((^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)) > 0 && tabstop_eq_o((^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^), new_vts_array) {
	} else {
		redraw_curbuf_later(UPD_NOT_VALID)
	}
	if first_line != 0 {
		changed_lines(curbuf, first_line, 0, last_line + 1, 0, true)
	}
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = save_list
	if new_ts_str != nil {
		old_vts_ary := (^rawptr)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
		if tabstop_count(transmute(^C.int)(old_vts_ary)) > 0 || tabstop_count(new_vts_array) > 1 {
			set_option_direct(kOptVartabstop_E, str_optval(new_ts_str, C.size_t(libc.strlen(transmute(cstring)(new_ts_str)))), OPT_LOCAL_S, 0)
			(^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^ = rawptr(new_vts_array)
			xfree(rawptr(old_vts_ary))
		} else {
			(^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^ = C.longlong(tabstop_first(new_vts_array))
			xfree(rawptr(new_vts_array))
		}
		xfree(rawptr(new_ts_str))
	}
	coladvance(curwin, (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^)
	u_clearline(curbuf)
}

KBUFOPT_INDENTEXPR_O :: 47

foreign _ {
	@(link_name = "p_lispwords")
	p_lispwords_g: ^u8
}

@(export)
get_expr_indent :: proc "c" () -> C.int {
	context = runtime.default_context()
	use_sandbox := was_set_insecurely(curwin, kOptIndentexpr_E, OPT_LOCAL_S) != 0
	save_sctx := current_sctx_buf
	save_pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	save_curswant := (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
	save_set_curswant := (^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^
	set_vim_var_nr(VV_LNUM_F, i64((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^))
	if use_sandbox {
		sandbox += 1
	}
	textlock += 1
	libc.memmove(rawptr(&current_sctx_buf[0]), rawptr(uintptr(curbuf) + B_P_SCRIPT_CTX_OFF + uintptr(KBUFOPT_INDENTEXPR_O * 24)), 24)
	inde_copy := xstrdup((^u8)((^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^))
	indent := C.int(eval_to_number(transmute(cstring)(inde_copy), true))
	xfree(rawptr(inde_copy))
	if use_sandbox {
		sandbox -= 1
	}
	textlock -= 1
	current_sctx_buf = save_sctx
	save_State := State
	State = MODE_INSERT
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_pos
	(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = save_curswant
	(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = save_set_curswant
	check_cursor(curwin)
	State = save_State
	if did_throw_g && (vim_strchr(p_debug_g, 't') == nil || trylevel_g == 0) {
		handle_did_throw()
		did_throw_g = false
	}
	if indent < 0 {
		indent = get_indent()
	}
	return indent
}

@(export)
get_lisp_indent :: proc "c" () -> C.int {
	context = runtime.default_context()
	paren := Pos_T{}
	amount: C.int = 0
	realpos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	pos := findmatch(nil, C.int('('))
	if pos == nil {
		pos = findmatch(nil, C.int('['))
	} else {
		paren = pos^
		pos = findmatch(nil, C.int('['))
		if pos == nil || lt_pos_o(pos^, paren) {
			pos = &paren
		}
	}
	if pos != nil {
		amount = -1
		parencount: C.int = 0
		for {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < pos.lnum {
				break
			}
			if linewhite((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^) {
				continue
			}
			that := get_cursor_line_ptr()
			for ([^]u8)(that)[0] != 0 {
				tc := ([^]u8)(that)[0]
				if tc == ';' {
					for ([^]u8)(transmute(^u8)(rawptr(uintptr(that) + 1)))[0] != 0 {
						that = transmute(^u8)(rawptr(uintptr(that) + 1))
					}
					break
				}
				if tc == '\\' {
					if ([^]u8)(transmute(^u8)(rawptr(uintptr(that) + 1)))[0] != 0 {
						that = transmute(^u8)(rawptr(uintptr(that) + 1))
					}
					that = transmute(^u8)(rawptr(uintptr(that) + 1))
					continue
				}
				if tc == '"' && ([^]u8)(transmute(^u8)(rawptr(uintptr(that) + 1)))[0] != 0 {
					inner_done := false
					for {
						that = transmute(^u8)(rawptr(uintptr(that) + 1))
						if ([^]u8)(that)[0] == 0 {
							inner_done = true
							break
						}
						if ([^]u8)(that)[0] != '"' {
							continue
						}
						break
					}
					if inner_done {
						break
					}
					that = transmute(^u8)(rawptr(uintptr(that) + 1))
					continue
				}
				if tc == '(' || tc == '[' {
					parencount += 1
				} else if tc == ')' || tc == ']' {
					parencount -= 1
				}
				that = transmute(^u8)(rawptr(uintptr(that) + 1))
			}
			if parencount == 0 {
				amount = get_indent()
				break
			}
		}
		if amount == -1 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = pos.lnum
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = pos.col
			col := pos.col
			line := get_cursor_line_ptr()
			csarg: CharsizeArg_O
			cstype := init_charsize_arg(&csarg, curwin, pos.lnum, line)
			sci := utf_ptr2StrCharInfo_o(line)
			amount = 0
			for ([^]u8)(sci.ptr)[0] != 0 && col > 0 {
				amount += win_charsize_o(cstype, amount, sci.ptr, sci.chr.value, &csarg).width
				sci = utfc_next_o(sci)
				col -= 1
			}
			that := sci.ptr
			if (([^]u8)(that)[0] == '(' || ([^]u8)(that)[0] == '[') && lisp_match_o(transmute(^u8)(rawptr(uintptr(that) + 1))) {
				amount += 2
			} else {
				if ([^]u8)(that)[0] != 0 {
					that = transmute(^u8)(rawptr(uintptr(that) + 1))
					amount += 1
				}
				firsttry := amount
				for ascii_iswhite(([^]u8)(that)[0]) {
					amount += win_charsize_o(cstype, amount, that, C.int32_t(([^]u8)(that)[0]), &csarg).width
					that = transmute(^u8)(rawptr(uintptr(that) + 1))
				}
				if ([^]u8)(that)[0] != 0 && ([^]u8)(that)[0] != ';' {
					if ([^]u8)(that)[0] != '(' && ([^]u8)(that)[0] != '[' {
						firsttry += 1
					}
					parencount = 0
					ci := utf_ptr2CharInfo_o(that)
					if ci.value != '"' && ci.value != '\'' && ci.value != '#' && (ci.value < '0' || ci.value > '9') {
						quotecount: C.int = 0
						for ([^]u8)(that)[0] != 0 && (ci.value != 32 && ci.value != 9 || quotecount != 0 || parencount != 0) {
							if ci.value == '"' {
								if quotecount != 0 {
									quotecount = 0
								} else {
									quotecount = 1
								}
							}
							if (ci.value == '(' || ci.value == '[') && quotecount == 0 {
								parencount += 1
							}
							if (ci.value == ')' || ci.value == ']') && quotecount == 0 {
								parencount -= 1
							}
							if ci.value == '\\' && ([^]u8)(transmute(^u8)(rawptr(uintptr(that) + 1)))[0] != 0 {
								amount += win_charsize_o(cstype, amount, that, ci.value, &csarg).width
								next_sci := utfc_next_o(StrCharInfo_O{ptr = that, chr = ci})
								that = next_sci.ptr
								ci = next_sci.chr
							}
							amount += win_charsize_o(cstype, amount, that, ci.value, &csarg).width
							next_sci := utfc_next_o(StrCharInfo_O{ptr = that, chr = ci})
							that = next_sci.ptr
							ci = next_sci.chr
						}
					}
					for ascii_iswhite(([^]u8)(that)[0]) {
						amount += win_charsize_o(cstype, amount, that, C.int32_t(([^]u8)(that)[0]), &csarg).width
						that = transmute(^u8)(rawptr(uintptr(that) + 1))
					}
					if ([^]u8)(that)[0] == 0 || ([^]u8)(that)[0] == ';' {
						amount = firsttry
					}
				}
			}
		}
	} else {
		amount = 0
	}
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = realpos
	return amount
}

lisp_match_o :: proc "c" (p_in: ^u8) -> bool {
	context = runtime.default_context()
	p := p_in
	buf: [512]u8
	lw := (^u8)((^rawptr)(uintptr(curbuf) + B_P_LW_OFF)^)
	word := p_lispwords_g
	if lw != nil && ([^]u8)(lw)[0] != 0 {
		word = lw
	}
	for ([^]u8)(word)[0] != 0 {
		length := copy_option_part(&word, &buf[0], 512, cstring(","))
		if libc.strncmp(transmute(cstring)(&buf[0]), transmute(cstring)(p), length) == 0 {
			nc := ([^]u8)(p)[uintptr(length)]
			if ascii_iswhite(nc) || nc == 0 {
				return true
			}
		}
	}
	return false
}

@(export)
fixthisline :: proc "c" (get_the_indent: Indenter_T) {
	context = runtime.default_context()
	amount := get_the_indent()
	if amount < 0 {
		return
	}
	change_indent(INDENT_SET_O, amount, false, true)
	if linewhite((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^) {
		did_ai_g = true
	}
}

@(export)
use_indentexpr_for_lisp :: proc "c" () -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(curbuf) + B_P_LISP_OFF)^ == 0 {
		return false
	}
	inde := (^u8)((^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^)
	if inde == nil || ([^]u8)(inde)[0] == 0 {
		return false
	}
	lop := (^u8)((^rawptr)(uintptr(curbuf) + B_P_LOP_OFF)^)
	return libc.strcmp(transmute(cstring)(lop), cstring("expr:1")) == 0
}

@(export)
fix_indent :: proc "c" () {
	context = runtime.default_context()
	if p_paste_g != 0 {
		return
	}
	if (^C.int)(uintptr(curbuf) + B_P_LISP_OFF)^ != 0 && (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 {
		if use_indentexpr_for_lisp() {
			do_c_expr_indent()
		} else {
			fixthisline(get_lisp_indent)
		}
	} else if cindent_on_e() != 0 {
		do_c_expr_indent()
	}
}

@(export)
f_indent :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	lnum := tv_get_lnum(argvars)
	if lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
		rettv.vval = transmute(rawptr)(C.longlong(get_indent_lnum(lnum)))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	}
}

@(export)
f_lispindent :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	lnum := tv_get_lnum(argvars)
	if lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
		rettv.vval = transmute(rawptr)(C.longlong(get_lisp_indent()))
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	}
}
