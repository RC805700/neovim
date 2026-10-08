package main

import C "core:c"
import "base:runtime"

// plines.c port: visual cell/size engine (charsize/plines/getvcol).
// Publics are @(export); border/cursor-off helpers are _o plains.
// Reuses drawline.odin mirrors: CharsizeArg_O/CharSize_O/StrCharInfo_O,
// DecorVirtText_O, K_CHARSIZE_*_O, K_VPOS_INLINE_O.

foreign _ {
	// marktree_itr_get_filter/next_filter/current now defined in marktree.odin — call directly.
	@(link_name = "nvim_odin_ns_in_win")
	ns_in_win_e :: proc "c" (ns_id: C.uint32_t, wp: rawptr) -> bool ---
	@(link_name = "diffopt_filler")
	diffopt_filler_e :: proc "c" () -> bool ---
}

MT_FLAG_END_O :: 0x02
MT_FLAG_INVALID_O :: 0x40
MT_FLAG_DECOR_EXT_O :: 0x80
MT_FLAG_RIGHT_GRAVITY_O :: 0x4000

kMTMetaInline_O :: 0
kMTFilterSelect_O :: 0xFFFFFFFF
kVTIsLines_O :: 1
kVPosInline_O :: 2
kInvalidByteCells_O :: 4

GETVCOL_END_EXCL_LBR_O :: 1

// MTPos mirror (8B).
MTPos_O :: struct {
	row: C.int32_t,
	col: C.int32_t,
}

// MTKey mirror (cc-probed, 40B). Row/col as C.int (ABI-identical to int32_t).
MTKey_O :: struct {
	pos:   MTPos_O,
	ns:    C.uint32_t,
	id:    C.uint32_t,
	flags: u16,
	_pad:  [6]u8,
	decor: [16]u8,
}
#assert(size_of(MTKey_O) == 40)

// DecorExt.vt pointer inside a key (decor@24, vt@decor+8).
mt_decor_vt_o :: proc "c" (key: ^MTKey_O) -> rawptr {
	context = runtime.default_context()
	return (^rawptr)(uintptr(key) + 32)^
}

// CharsizeArg.iter slot address (iter@40).
csarg_iter_o :: proc "c" (csarg: ^CharsizeArg_O) -> rawptr {
	context = runtime.default_context()
	return rawptr(&csarg.iter[0])
}

// File-private filter table: {[Inline] = Select}.
@(private = "file")
inline_filter_g: [2]C.uint32_t = {kMTFilterSelect_O, 0}

// Tab-aware width of char at p in window.
@(export)
win_chartabsize :: proc "c" (wp: rawptr, p: ^u8, col: C.int) -> C.int {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if ([^]u8)(p)[0] == TAB_O && ((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 || (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^ != 0) {
		return tabstop_padding(col, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
	}
	return ptr2cells(transmute(cstring)(p))
}

// Width of string s starting at virtual column startvcol.
@(export)
linetabsize_col :: proc "c" (startvcol: C.int, s: ^u8) -> C.int {
	context = runtime.default_context()
	csarg: CharsizeArg_O
	cstype := init_charsize_arg(&csarg, curwin, 0, s)
	if cstype == K_CHARSIZE_FAST_O {
		return linesize_fast(&csarg, startvcol, MAXCOL)
	}
	return linesize_regular(&csarg, startvcol, MAXCOL)
}

// Header-inline engine (plines.h): width of line slice.
win_linetabsize_o :: proc "c" (wp: rawptr, lnum: C.int, line: ^u8, len: C.int) -> C.int {
	context = runtime.default_context()
	csarg: CharsizeArg_O
	cstype := init_charsize_arg(&csarg, wp, lnum, line)
	if cstype == K_CHARSIZE_FAST_O {
		return linesize_fast(&csarg, 0, len)
	}
	return linesize_regular(&csarg, 0, len)
}

// Width of buffer line lnum in window (no 'listchars' eol).
@(export)
linetabsize :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	return win_linetabsize_o(wp, lnum, ml_get_buf(buf, lnum), MAXCOL)
}

// Like linetabsize(), plus 'listchars' eol.
@(export)
linetabsize_eol :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	n := linetabsize(wp, lnum)
	if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && ([^]u8)(rawptr(uintptr(wp) + W_P_LCS_CHARS_OFF))[0] != 0 {
		n += 1
	}
	return n
}

// Fast char width (no virt text/linebreak/showbreak).
charsize_fast_impl_o :: proc "c" (wp: rawptr, cur: ^u8, use_tabstop: bool, vcol: C.int, cur_char: C.int32_t) -> CharSize_O {
	context = runtime.default_context()
	if cur_char == TAB_O && use_tabstop {
		buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		return CharSize_O{width = tabstop_padding(vcol, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))}
	}
	width: C.int
	if cur_char < 0 {
		width = kInvalidByteCells_O
	} else {
		width = ptr2cells(transmute(cstring)(cur))
	}
	if width == 2 && cur_char >= 0x80 && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && in_win_border_o(wp, vcol) {
		return CharSize_O{width = 3, head = 1}
	}
	return CharSize_O{width = width}
}

// Fast entry point (kCharsizeFast only).
@(export)
charsize_fast :: proc "c" (csarg: ^CharsizeArg_O, cur: ^u8, vcol: C.int, cur_char: C.int32_t) -> CharSize_O {
	context = runtime.default_context()
	return charsize_fast_impl_o(csarg.win, cur, csarg.use_tabstop, vcol, cur_char)
}

// Width at virtual column without wrap/linebreak handling.
@(export)
charsize_nowrap :: proc "c" (buf: rawptr, cur: ^u8, use_tabstop: bool, vcol: C.int, cur_char: C.int32_t) -> C.int {
	context = runtime.default_context()
	if cur_char == TAB_O && use_tabstop {
		return tabstop_padding(vcol, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
	} else if cur_char < 0 {
		return kInvalidByteCells_O
	}
	return ptr2cells(transmute(cstring)(cur))
}

// True if vcol is in the rightmost window column.
in_win_border_o :: proc "c" (wp: rawptr, vcol: C.int) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ == 0 {
		return false
	}
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	if C.int(vcol) < width1 - 1 {
		return false
	}
	if C.int(vcol) == width1 - 1 {
		return true
	}
	width2 := width1 + win_col_off2(wp)
	if width2 <= 0 {
		return false
	}
	return (vcol - width1) % width2 == width2 - 1
}

// Prepare charsize state; fast when no virt text/wrap extras.
@(export)
init_charsize_arg :: proc "c" (csarg: ^CharsizeArg_O, wp: rawptr, lnum: C.int, line: ^u8) -> bool {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	csarg.win = wp
	csarg.line = line
	csarg.max_head_vcol = 0
	csarg.cur_text_width_left = 0
	csarg.cur_text_width_right = 0
	csarg.virt_row = -1
	csarg.indent_width = INT_MIN_O
	csarg.use_tabstop = (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 || (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^ != 0
	if lnum > 0 {
		if marktree_itr_get_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), lnum - 1, 0, lnum, 0, ([^]u32)(&inline_filter_g[0]), csarg_iter_o(csarg)) {
			csarg.virt_row = lnum - 1
		}
	}
	if csarg.virt_row >= 0 || ((^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && ((^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 || (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ != 0 || ([^]u8)(get_showbreak_value(wp))[0] != 0)) {
		return K_CHARSIZE_REGULAR_O
	}
	return K_CHARSIZE_FAST_O
}

// Inline virt-text cursor offset for regular charsize.
virt_text_cursor_off_o :: proc "c" (csarg: ^CharsizeArg_O, on_NUL: bool) -> C.int {
	context = runtime.default_context()
	off: C.int = 0
	if !on_NUL || (State & MODE_NORMAL_O) == 0 {
		off += csarg.cur_text_width_left
	}
	if !on_NUL && (State & MODE_NORMAL_O) != 0 {
		off += csarg.cur_text_width_right
	}
	return off
}

// Virtual column up to len (regular engine).
@(export)
linesize_regular :: proc "c" (csarg: ^CharsizeArg_O, vcol_arg: C.int, len: C.int) -> C.int {
	context = runtime.default_context()
	line := csarg.line
	vcol: C.longlong = C.longlong(vcol_arg)
	vcol_arg_mut := vcol_arg
	ci := utf_ptr2StrCharInfo_o(line)
	for C.int(uintptr(ci.ptr) - uintptr(rawptr(line))) < len && ([^]u8)(ci.ptr)[0] != 0 {
		vcol += C.longlong(charsize_regular(csarg, ci.ptr, vcol_arg_mut, ci.chr.value).width)
		ci = utfc_next_o(ci)
		if vcol > MAXCOL {
			vcol_arg_mut = MAXCOL
			break
		} else {
			vcol_arg_mut = C.int(vcol)
		}
	}
	if len == MAXCOL && csarg.virt_row >= 0 && ([^]u8)(ci.ptr)[0] == 0 {
		head := charsize_regular(csarg, ci.ptr, vcol_arg_mut, ci.chr.value).head
		vcol += C.longlong(csarg.cur_text_width_left + csarg.cur_text_width_right + head)
		if vcol > MAXCOL {
			vcol_arg_mut = MAXCOL
		} else {
			vcol_arg_mut = C.int(vcol)
		}
	}
	return vcol_arg_mut
}

// Virtual column up to len (fast engine).
@(export)
linesize_fast :: proc "c" (csarg: ^CharsizeArg_O, vcol_arg: C.int, len: C.int) -> C.int {
	context = runtime.default_context()
	wp := csarg.win
	use_tabstop := csarg.use_tabstop
	line := csarg.line
	vcol: C.longlong = C.longlong(vcol_arg)
	vcol_arg_mut := vcol_arg
	ci := utf_ptr2StrCharInfo_o(line)
	for C.int(uintptr(ci.ptr) - uintptr(rawptr(line))) < len && ([^]u8)(ci.ptr)[0] != 0 {
		vcol += C.longlong(charsize_fast_impl_o(wp, ci.ptr, use_tabstop, vcol_arg_mut, ci.chr.value).width)
		ci = utfc_next_o(ci)
		if vcol > MAXCOL {
			vcol_arg_mut = MAXCOL
			break
		} else {
			vcol_arg_mut = C.int(vcol)
		}
	}
	return vcol_arg_mut
}

// Virtual column of pos (start/cursor/end of the char).
@(export)
getvcol :: proc "c" (wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) {
	context = runtime.default_context()
	line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum)
	end_col := pos.col
	csarg: CharsizeArg_O
	on_NUL := false
	cstype := init_charsize_arg(&csarg, wp, pos.lnum, line)
	csarg.max_head_vcol = -1
	vcol: C.int = 0
	char_size: CharSize_O
	ci := utf_ptr2StrCharInfo_o(line)
	if cstype == K_CHARSIZE_FAST_O {
		use_tabstop := csarg.use_tabstop
		for {
			if ([^]u8)(ci.ptr)[0] == 0 {
				char_size = CharSize_O{width = 1}
				break
			}
			char_size = charsize_fast_impl_o(wp, ci.ptr, use_tabstop, vcol, ci.chr.value)
			next := utfc_next_o(ci)
			if C.int(uintptr(next.ptr) - uintptr(rawptr(line))) > end_col {
				break
			}
			ci = next
			vcol += char_size.width
		}
	} else {
		for {
			char_size = charsize_regular(&csarg, ci.ptr, vcol, ci.chr.value)
			if ([^]u8)(ci.ptr)[0] == 0 {
				char_size.width = 1 + csarg.cur_text_width_left + csarg.cur_text_width_right
				on_NUL = true
				break
			}
			next := utfc_next_o(ci)
			if C.int(uintptr(next.ptr) - uintptr(rawptr(line))) > end_col {
				break
			}
			ci = next
			vcol += char_size.width
		}
	}
	if ([^]u8)(ci.ptr)[0] == 0 && end_col < MAXCOL && end_col > C.int(uintptr(ci.ptr) - uintptr(rawptr(line))) {
		pos.col = C.int(uintptr(ci.ptr) - uintptr(rawptr(line)))
	}
	incr := char_size.width
	head := char_size.head
	tail := char_size.tail
	if start != nil {
		start^ = vcol + head
	}
	if end != nil {
		excl: C.int = 0
		if (flags & GETVCOL_END_EXCL_LBR_O) != 0 {
			excl = tail
		}
		end^ = vcol + incr - excl - 1
	}
	if cursor != nil {
		if ci.chr.value == TAB_O && (State & MODE_NORMAL_O) != 0 && (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 && !virtual_active(wp) && !(VIsual_active && (([^]u8)(p_sel)[0] == 'e' || ltoreq_o(pos^, VIsual_g))) {
			cursor^ = vcol + incr - 1
		} else {
			vcol += virt_text_cursor_off_o(&csarg, on_NUL)
			cursor^ = vcol + head
		}
	}
}

// Virtual column, pretending 'list' is off.
@(export)
getvcol_nolist :: proc "c" (posp: ^Pos_T) -> C.int {
	context = runtime.default_context()
	list_save := (^C.int)(uintptr(curwin) + W_P_LIST_OFF)^
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = 0
	vcol: C.int
	if posp.coladd != 0 {
		getvvcol(curwin, posp, nil, &vcol, nil, 0)
	} else {
		getvcol(curwin, posp, nil, &vcol, nil, 0)
	}
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = list_save
	return vcol
}

// Virtual column in virtual mode.
@(export)
getvvcol :: proc "c" (wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) {
	context = runtime.default_context()
	if virtual_active(wp) {
		getvcol(wp, pos, &pos.col, nil, nil, flags)
		col := pos.col
		coladd := pos.coladd
		endadd: C.int = 0
		ptr := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum)
		if pos.col < ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum) {
			c := utf_ptr2char(transmute(cstring)((^u8)(uintptr(ptr) + uintptr(pos.col))))
			if c != TAB_O && vim_isprintc(c) {
				endadd = C.int(ptr2cells(transmute(cstring)((^u8)(uintptr(ptr) + uintptr(pos.col))))) - 1
				if coladd > endadd {
					endadd = 0
				} else {
					coladd = 0
				}
			}
		}
		col += coladd
		if start != nil {
			start^ = col
		}
		if cursor != nil {
			cursor^ = col
		}
		if end != nil {
			end^ = col + endadd
		}
	} else {
		getvcol(wp, pos, start, cursor, end, flags)
	}
}

// Leftmost/rightmost virtual columns of two positions (block visual).
@(export)
getvcols :: proc "c" (wp: rawptr, pos1: ^Pos_T, pos2: ^Pos_T, left: ^C.int, right: ^C.int, flags: C.int) {
	context = runtime.default_context()
	from1, from2, to1, to2: C.int
	p1 := pos1^
	p2 := pos2^
	first_le := p1.lnum < p2.lnum || (p1.lnum == p2.lnum && p1.col <= p2.col)
	if first_le {
		getvvcol(wp, pos1, &from1, nil, &to1, flags)
		getvvcol(wp, pos2, &from2, nil, &to2, flags)
	} else {
		getvvcol(wp, pos2, &from1, nil, &to1, flags)
		getvvcol(wp, pos1, &from2, nil, &to2, flags)
	}
	if from2 < from1 {
		left^ = from2
	} else {
		left^ = from1
	}
	if to2 > to1 {
		if ([^]u8)(p_sel)[0] == 'e' && from2 - 1 >= to1 {
			right^ = from2 - 1
		} else {
			right^ = to2
		}
	} else {
		right^ = to1
	}
}

kMTMetaLines_O :: 1

// True if filler lines may exist anywhere in window.
@(export)
win_may_fill :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	return ((^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ != 0 && diffopt_filler_e()) || buf_meta_total_o(buf, kMTMetaLines_O) != 0
}

// Filler lines above lnum.
@(export)
win_get_fill :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	return decor_virt_lines(wp, lnum - 1, lnum, nil, nil, true) + diff_check_fill_r(wp, lnum)
}

// Window lines for buffer line (with filler).
@(export)
plines_win :: proc "c" (wp: rawptr, lnum: C.int, limit_winheight: bool) -> C.int {
	context = runtime.default_context()
	return plines_win_nofill(wp, lnum, limit_winheight) + win_get_fill(wp, lnum)
}

// Window lines for buffer line (no filler).
@(export)
plines_win_nofill :: proc "c" (wp: rawptr, lnum: C.int, limit_winheight: bool) -> C.int {
	context = runtime.default_context()
	if decor_conceal_line(wp, lnum - 1, false) {
		return 0
	}
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 {
		return 1
	}
	if (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ == 0 {
		return 1
	}
	if lineFolded(wp, lnum) {
		return 1
	}
	lines := plines_win_nofold(wp, lnum)
	if limit_winheight && lines > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		return (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	}
	return lines
}

// Screen lines for physical line (no fold/wrap/filler handling).
@(export)
plines_win_nofold :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	s := ml_get_buf(buf, lnum)
	csarg: CharsizeArg_O
	cstype := init_charsize_arg(&csarg, wp, lnum, s)
	if ([^]u8)(s)[0] == 0 && csarg.virt_row < 0 {
		return 1
	}
	col: C.longlong
	if cstype == K_CHARSIZE_FAST_O {
		col = C.longlong(linesize_fast(&csarg, 0, MAXCOL))
	} else {
		col = C.longlong(linesize_regular(&csarg, 0, MAXCOL))
	}
	if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && ([^]u8)(rawptr(uintptr(wp) + W_P_LCS_CHARS_OFF))[0] != 0 {
		col += 1
	}
	width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	if width <= 0 {
		return 32000
	}
	if col <= C.longlong(width) {
		return 1
	}
	col -= C.longlong(width)
	width += win_col_off2(wp)
	lines := (col + C.longlong(width) - 1) / C.longlong(width) + 1
	if lines > 0 && lines <= C.longlong(INT_MAX_O) {
		return C.int(lines)
	}
	return INT_MAX_O
}

// Screen lines used from line start to column number.
@(export)
plines_win_col :: proc "c" (wp: rawptr, lnum: C.int, column_in: C.long) -> C.int {	context = runtime.default_context()
	column := column_in
	lines := win_get_fill(wp, lnum)
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 {
		return lines + 1
	}
	if (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ == 0 {
		return lines + 1
	}
	line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
	csarg: CharsizeArg_O
	cstype := init_charsize_arg(&csarg, wp, lnum, line)
	vcol: C.int = 0
	ci := utf_ptr2StrCharInfo_o(line)
	if cstype == K_CHARSIZE_FAST_O {
		use_tabstop := csarg.use_tabstop
		for ([^]u8)(ci.ptr)[0] != 0 && column > 0 {
			column -= 1
			vcol += charsize_fast_impl_o(wp, ci.ptr, use_tabstop, vcol, ci.chr.value).width
			ci = utfc_next_o(ci)
		}
	} else {
		for ([^]u8)(ci.ptr)[0] != 0 && column > 0 {
			column -= 1
			vcol += charsize_regular(&csarg, ci.ptr, vcol, ci.chr.value).width
			ci = utfc_next_o(ci)
		}
	}
	col := vcol
	if ci.chr.value == TAB_O && (State & MODE_NORMAL_O) != 0 && csarg.use_tabstop {
		col += win_charsize_o(cstype, col, ci.ptr, ci.chr.value, &csarg).width - 1
	}
	width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	if width <= 0 {
		return 9999
	}
	lines += 1
	if col > width {
		lines += (col - width) / (width + win_col_off2(wp)) + 1
	}
	return lines
}

// Full char width with virt text/linebreak/showbreak.
@(export)
charsize_regular :: proc "c" (csarg: ^CharsizeArg_O, cur: ^u8, vcol: C.int, cur_char: C.int32_t) -> CharSize_O {
	context = runtime.default_context()
	csarg.cur_text_width_left = 0
	csarg.cur_text_width_right = 0
	wp := csarg.win
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	line := csarg.line
	use_tabstop := cur_char == TAB_O && csarg.use_tabstop
	mb_added: C.int = 0
	has_lcs_eol := (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && ([^]u8)(rawptr(uintptr(wp) + W_P_LCS_CHARS_OFF))[0] != 0
	size: C.int
	is_doublewidth := false
	if use_tabstop {
		size = tabstop_padding(vcol, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
	} else if ([^]u8)(cur)[0] == 0 {
		if has_lcs_eol {
			size = 1
		} else {
			size = 0
		}
	} else if cur_char < 0 {
		size = kInvalidByteCells_O
	} else {
		size = ptr2cells(transmute(cstring)(cur))
		is_doublewidth = size == 2 && cur_char >= 0x80
	}
	if csarg.virt_row >= 0 {
		tab_size := size
		col := C.int(uintptr(rawptr(cur)) - uintptr(rawptr(line)))
		for {
			mark := marktree_itr_current(csarg_iter_o(csarg))
			if mark.pos.row != csarg.virt_row || mark.pos.col > col {
				break
			}
			if mark.pos.col == col {
				if (mark.flags & MT_FLAG_INVALID_O) == 0 && ns_in_win_e(mark.ns, wp) {
					ext := (mark.flags & MT_FLAG_DECOR_EXT_O) != 0
					vt: rawptr = nil
					if ext {
						vt = mt_decor_vt_o(&mark)
					}
					for vt != nil {
						v := (^DecorVirtText_O)(vt)
						if (v.flags & kVTIsLines_O) == 0 && v.pos == kVPosInline_O {
							if (mark.flags & MT_FLAG_RIGHT_GRAVITY_O) != 0 {
								csarg.cur_text_width_right += v.width
							} else {
								csarg.cur_text_width_left += v.width
							}
							size += v.width
							if use_tabstop {
								size -= tab_size
								tab_size = tabstop_padding(vcol + size, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
								size += tab_size
							}
						}
						vt = v.next
					}
				}
			}
			marktree_itr_next_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), csarg_iter_o(csarg), csarg.virt_row + 1, 0, ([^]u32)(&inline_filter_g[0]))
		}
	}
	if is_doublewidth && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && in_win_border_o(wp, vcol + size - 2) {
		size += 1
		mb_added = 1
	}
	sbr := get_showbreak_value(wp)
	head := mb_added
	if size > 0 && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (([^]u8)(sbr)[0] != 0 || (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ != 0) {
		col_off_prev := win_col_off(wp)
		width2 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - col_off_prev + win_col_off2(wp)
		wcol := vcol + col_off_prev
		max_head_vcol := csarg.max_head_vcol
		added: C.int = 0
		head_prev: C.int = 0
		if wcol >= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ {
			wcol -= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^
			col_off_prev = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - width2
			if wcol >= width2 && width2 > 0 {
				wcol %= width2
			}
			head_prev = csarg.indent_width
			if head_prev == INT_MIN_O {
				head_prev = 0
				if ([^]u8)(sbr)[0] != 0 {
					head_prev += vim_strsize(transmute(cstring)(sbr))
				}
				if (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ != 0 {
					head_prev += get_breakindent_win(wp, line)
				}
				csarg.indent_width = head_prev
			}
			if wcol < head_prev {
				head_prev -= wcol
				wcol += head_prev
				added += head_prev
				if max_head_vcol <= 0 || vcol < max_head_vcol {
					head += head_prev
				}
			} else {
				head_prev = 0
			}
			wcol += col_off_prev
		}
		if wcol + size > (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ {
			head_mid := csarg.indent_width
			if head_mid == INT_MIN_O {
				head_mid = 0
				if ([^]u8)(sbr)[0] != 0 {
					head_mid += vim_strsize(transmute(cstring)(sbr))
				}
				if (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ != 0 {
					head_mid += get_breakindent_win(wp, line)
				}
				csarg.indent_width = head_mid
			}
			if head_mid > 0 {
				prev_rem := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - wcol
				width := width2 - head_mid
				if width <= 0 {
					width = 1
				}
				cnt := (size - prev_rem + width - 1) / width
				added += cnt * head_mid
				if max_head_vcol == 0 || vcol + size + added < max_head_vcol {
					head += cnt * head_mid
				} else if width2 > 0 && max_head_vcol > vcol + head_prev + prev_rem {
					head += (max_head_vcol - (vcol + head_prev + prev_rem) + width2 - 1) / width2 * head_mid
				} else if max_head_vcol < 0 {
					off := mb_added + virt_text_cursor_off_o(csarg, ([^]u8)(cur)[0] == 0)
					if off >= prev_rem {
						if size > off {
							head += (1 + (off - prev_rem) / width) * head_mid
						} else {
							head += (off - prev_rem + width - 1) / width * head_mid
						}
					}
				}
			}
		}
		size += added
	}
	size_before_lbr := size
	need_lbr := false
	if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ != 0 && vim_isbreak_o(C.int(([^]u8)(cur)[0])) && !vim_isbreak_o(C.int(([^]u8)(cur)[1])) {
		t := line
		for vim_isbreak_o(C.int(([^]u8)(t)[0])) {
			t = (^u8)(uintptr(t) + 1)
		}
		need_lbr = uintptr(rawptr(cur)) >= uintptr(rawptr(t))
	}
	if need_lbr {
		s := cur
		numberextra := win_col_off(wp)
		col_adj := size - 1
		colmax := C.int((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - numberextra - col_adj)
		if vcol >= colmax {
			colmax += col_adj
			n := colmax + win_col_off2(wp)
			if n > 0 {
				colmax += ((vcol - colmax) / n + 1) * n - col_adj
			}
		}
		vcol2 := vcol
		for {
			ps := s
			s = (^u8)(uintptr(s) + uintptr(utfc_ptr2len(transmute(cstring)(s))))
			c := C.int(([^]u8)(s)[0])
			if !(c != 0 && (vim_isbreak_o(c) || vcol2 == vcol || !vim_isbreak_o(C.int(([^]u8)(ps)[0])))) {
				break
			}
			vcol2 += win_chartabsize(wp, s, vcol2)
			if vcol2 >= colmax {
				size = colmax - vcol + col_adj
				break
			}
		}
	}
	tail := size - size_before_lbr
	return CharSize_O{width = size, head = head, tail = tail}
}

// Screen lines for lnum with folds and topfill.
@(export)
plines_win_full :: proc "c" (wp: rawptr, lnum_in: C.int, nextp: ^C.int, foldedp: ^bool, cache: bool, limit_winheight: bool) -> C.int {
	context = runtime.default_context()
	lnum := lnum_in
	folded := hasFoldingWin(wp, lnum, &lnum, nextp, cache, nil)
	if foldedp != nil {
		foldedp^ = folded
	}
	filler_lines: C.int
	if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		filler_lines = (^C.int)(uintptr(wp) + W_TOPFILL)^
	} else {
		filler_lines = win_get_fill(wp, lnum)
	}
	if decor_conceal_line(wp, lnum - 1, false) {
		return filler_lines
	}
	if folded {
		return 1 + filler_lines
	}
	return plines_win_nofill(wp, lnum, limit_winheight) + filler_lines
}

// Window lines for a physical line range.
@(export)
plines_m_win :: proc "c" (wp: rawptr, first_in: C.int, last: C.int, max: C.int) -> C.int {
	context = runtime.default_context()
	first := first_in
	count: C.int = 0
	for first <= last && count < max {
		next := first
		count += plines_win_full(wp, first, &next, nil, false, false)
		first = next + 1
	}
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if first == (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ + 1 {
		count += win_get_fill(wp, first)
	}
	if max < count {
		return max
	}
	return count
}

// Physical + filler lines in a range (no fold/wrap expansion).
@(export)
plines_m_win_fill :: proc "c" (wp: rawptr, first: C.int, last: C.int) -> C.int {
	context = runtime.default_context()
	count := last - first + 1 + decor_virt_lines(wp, first - 1, last, nil, nil, false)
	if diffopt_filler_e() {
		lnum := first
		for lnum <= last {
			n := diff_check_fill_r(wp, lnum)
			if n > 0 {
				count += n
			}
			lnum += 1
		}
	}
	if count < 0 {
		return 0
	}
	return count
}

// Screen-line height of a text range.
@(export)
win_text_height :: proc "c" (wp: rawptr, start_lnum: C.int, start_vcol: C.longlong, end_lnum: ^C.int, end_vcol: ^C.longlong, fill: rawptr, max: C.longlong) -> C.longlong {
	context = runtime.default_context()
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	width2 := width1 + win_col_off2(wp)
	if width1 < 0 {
		width1 = 0
	}
	if width2 < 0 {
		width2 = 0
	}
	height_sum_fill: C.longlong = 0
	height_cur_nofill: C.longlong = 0
	height_sum_nofill: C.longlong = 0
	lnum := start_lnum
	cur_lnum := lnum
	cur_folded := false
	if start_vcol >= 0 {
		lnum_next := lnum
		cur_folded = hasFolding(wp, lnum, &lnum, &lnum_next)
		height_cur_nofill = C.longlong(plines_win_nofill(wp, lnum, false))
		height_sum_nofill += height_cur_nofill
		row_off: C.longlong
		if start_vcol < C.longlong(width1) || width2 <= 0 {
			row_off = 0
		} else {
			row_off = 1 + (start_vcol - C.longlong(width1)) / C.longlong(width2)
		}
		above := row_off
		if above > height_cur_nofill {
			above = height_cur_nofill
		}
		height_sum_nofill -= above
		lnum = lnum_next + 1
	}
	for lnum <= end_lnum^ && height_sum_nofill + height_sum_fill < max {
		lnum_next := lnum
		cur_folded = hasFolding(wp, lnum, &lnum, &lnum_next)
		height_sum_fill += C.longlong(win_get_fill(wp, lnum))
		height_cur_nofill = C.longlong(plines_win_nofill(wp, lnum, false))
		height_sum_nofill += height_cur_nofill
		cur_lnum = lnum
		lnum = lnum_next + 1
	}
	vcol_end := end_vcol^
	use_vcol := vcol_end >= 0 && lnum > end_lnum^
	if use_vcol {
		height_sum_nofill -= height_cur_nofill
		row_off: C.longlong
		if vcol_end == 0 {
			row_off = 0
		} else if vcol_end <= C.longlong(width1) || width2 <= 0 {
			row_off = 1
		} else {
			row_off = 1 + (vcol_end - C.longlong(width1) + C.longlong(width2) - 1) / C.longlong(width2)
		}
		add := row_off
		if add > height_cur_nofill {
			add = height_cur_nofill
		}
		height_sum_nofill += add
	}
	if cur_folded {
		vcol_end = 0
	} else {
		linesize := C.longlong(linetabsize_eol(wp, cur_lnum))
		if use_vcol && vcol_end < linesize {
			linesize = vcol_end
		}
		vcol_end = linesize
	}
	overflow := height_sum_nofill + height_sum_fill - max
	if overflow > 0 && width2 > 0 && vcol_end > C.longlong(width2) {
		vcol_end -= (vcol_end - C.longlong(width1)) % C.longlong(width2) + (overflow - 1) * C.longlong(width2)
	}
	end_lnum^ = cur_lnum
	end_vcol^ = vcol_end
	if fill != nil {
		(^C.longlong)(fill)^ = height_sum_fill
	}
	return height_sum_fill + height_sum_nofill
}
