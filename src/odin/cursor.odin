package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// cursor.c port: cursor positioning (virtcol advance, cursor validation).
// All 20 publics are @(export); coladvance2 is a dormant _o plain.

foreign _ {
	@(link_name = "set_valid_virtcol")
	set_valid_virtcol_e :: proc "c" (wp: rawptr, vcol: C.int) ---
	@(link_name = "ml_get_buf_mut")
	ml_get_buf_mut_e :: proc "c" (buf: rawptr, lnum: C.int) -> ^u8 ---
	@(link_name = "linetabsize")
	linetabsize_e :: proc "c" (wp: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "dec")
	dec_e :: proc "c" (lp: ^Pos_T) -> C.int ---
}

KOPT_VE_ONEMORE_O :: 0x08 // kOptVeFlagOnemore
KOPT_VE_ALL_O :: 0x04 // kOptVeFlagAll

// getvvcol/getvcol stay in C (plines.c) — single decls, all callers use these.
foreign _ {
	@(link_name = "getvvcol")
	getvvcol :: proc "c" (wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) ---
	@(link_name = "getvcol")
	getvcol :: proc "c" (wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) ---
}

// Screen position of the cursor.
@(export)
getviscol :: proc "c" () -> C.int {
	context = runtime.default_context()
	x: C.int
	getvvcol(curwin, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF), &x, nil, nil, 0)
	return x
}

// Screen position of character col with coladd in the cursor line.
@(export)
getviscol2 :: proc "c" (col: C.int, coladd: C.int) -> C.int {
	context = runtime.default_context()
	x: C.int
	pos := Pos_T{lnum = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum, col = col, coladd = coladd}
	getvvcol(curwin, &pos, &x, nil, nil, 0)
	return x
}

// Go to column wcol, adding/inserting whitespace as necessary.
@(export)
coladvance_force :: proc "c" (wcol: C.int) -> C.int {
	context = runtime.default_context()
	rc := coladvance2_o(curwin, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF), true, false, wcol)
	if wcol == MAXCOL {
		(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_VIRTCOL_O)
	} else {
		set_valid_virtcol_e(curwin, wcol)
	}
	return rc
}

// Advance the cursor to the specified screen column.
@(export)
coladvance :: proc "c" (wp: rawptr, wcol: C.int) -> C.int {
	context = runtime.default_context()
	rc := getvpos(wp, (^Pos_T)(uintptr(wp) + W_CURSOR_OFF), wcol)
	if wcol == MAXCOL || rc == FAIL_E {
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_VIRTCOL_O)
	} else if ([^]u8)(ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, (^Pos_T)(uintptr(wp) + W_CURSOR_OFF).lnum))[(^Pos_T)(uintptr(wp) + W_CURSOR_OFF).col] != 9 {
		set_valid_virtcol_e(curwin, wcol)
	}
	return rc
}

coladvance2_o :: proc "c" (wp: rawptr, pos: ^Pos_T, addspaces: bool, finetune: bool, wcol_arg: C.int) -> C.int {
	context = runtime.default_context()
	if !(wp == curwin || !addspaces) {
		libc.abort()
	}
	wcol := wcol_arg
	idx: C.int
	col: C.int = 0
	head: C.int = 0
	one_more: C.int = 0
	if (State & MODE_INSERT) != 0 || (State & MODE_TERMINAL_O) != 0 || restart_edit != 0 || (VIsual_active && p_sel^ != 'o') || ((get_ve_flags(wp) & KOPT_VE_ONEMORE_O) != 0 && wcol < MAXCOL) {
		one_more = 1
	}
	line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum)
	linelen := ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum)
	if wcol >= MAXCOL {
		idx = linelen - 1 + one_more
		col = wcol
		if (addspaces || finetune) && !VIsual_active {
			(^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ = linetabsize_e(wp, pos.lnum) + one_more
			if (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ > 0 {
				(^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ -= 1
			}
		}
	} else {
		width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp)
		csize: C.int = 0
		if finetune && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ != 0 && wcol >= width && width > 0 {
			csize = linetabsize_eol(wp, pos.lnum)
			if csize > 0 {
				csize -= 1
			}
			if wcol / width > csize / width && ((State & MODE_INSERT) == 0 || wcol > csize + 1) {
				wcol = (csize / width + 1) * width - 1
			}
		}
		csarg: CharsizeArg_O
		cstype := init_charsize_arg_r(&csarg, wp, pos.lnum, line)
		ci := utf_ptr2StrCharInfo_o(line)
		col = 0
		for col <= wcol && ci.ptr^ != 0 {
			cs := win_charsize_o(cstype, col, ci.ptr, ci.chr.value, &csarg)
			csize = cs.width
			head = cs.head
			col += cs.width
			ci = utfc_next_o(ci)
		}
		idx = C.int(uintptr(ci.ptr) - uintptr(line))
		if col > wcol || (!virtual_active(wp) && one_more == 0) {
			idx -= 1
			csize -= head
			col -= csize
		}
		if virtual_active(wp) && addspaces && wcol >= 0 && ((col != wcol && col != wcol + 1) || csize > 1) {
			if ([^]u8)(line)[idx] == 0 {
				correct := wcol - col
				newline_size := C.size_t(idx + correct)
				if newline_size < C.size_t(idx) {
					libc.abort()
				}
				newline := xmallocz(newline_size)
				libc.memcpy(rawptr(newline), rawptr(line), C.size_t(idx))
				libc.memset(rawptr(uintptr(newline) + uintptr(idx)), ' ', C.size_t(correct))
				ml_replace_c(pos.lnum, newline, false)
				inserted_bytes_r(pos.lnum, idx, 0, correct)
				idx += correct
				col = wcol
			} else {
				correct := wcol - col - csize + 1
				if -correct > csize {
					return FAIL_E
				}
				n := C.size_t(linelen - 1 + csize)
				if n < C.size_t(linelen - 1) {
					libc.abort()
				}
				newline := xmallocz(n)
				libc.memcpy(rawptr(newline), rawptr(line), C.size_t(idx))
				libc.memset(rawptr(uintptr(newline) + uintptr(idx)), ' ', C.size_t(csize))
				n = C.size_t(linelen - idx)
				n = n - 1
				libc.memcpy(rawptr(uintptr(newline) + uintptr(idx) + uintptr(csize)), rawptr(uintptr(line) + uintptr(idx) + 1), n)
				ml_replace_c(pos.lnum, newline, false)
				inserted_bytes_r(pos.lnum, idx, 1, csize)
				idx += (csize - 1 + correct)
				col += correct
			}
		}
	}
	pos.col = max(idx, 0)
	pos.coladd = 0
	if finetune {
		if wcol == MAXCOL {
			if one_more == 0 {
				scol, ecol: C.int
				getvcol(wp, pos, &scol, nil, &ecol, 0)
				pos.coladd = ecol - scol
			}
		} else {
			b := wcol - col
			if b > 0 && b < (MAXCOL - 2 * (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) {
				pos.coladd = b
			}
			col += b
		}
	}
	mark_mb_adjustpos((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos)
	if wcol < 0 || col < wcol {
		return FAIL_E
	}
	return OK_E
}

// Position of the cursor advanced to screen column wcol.
@(export)
getvpos :: proc "c" (wp: rawptr, pos: ^Pos_T, wcol: C.int) -> C.int {
	context = runtime.default_context()
	return coladvance2_o(wp, pos, false, virtual_active(wp), wcol)
}

// Increment the cursor position.
@(export)
inc_cursor :: proc "c" () -> C.int {
	context = runtime.default_context()
	return incl_pos((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF))
}

// Decrement the cursor position.
@(export)
dec_cursor :: proc "c" () -> C.int {
	context = runtime.default_context()
	return dec_e((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF))
}

// Line number relative to the cursor, skipping folds.
@(export)
get_cursor_rel_lnum :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	cursor := (^Pos_T)(uintptr(wp) + W_CURSOR_OFF).lnum
	if lnum == cursor || hasAnyFolding(wp) == 0 {
		return lnum - cursor
	}
	from_line := lnum if lnum < cursor else cursor
	to_line := lnum if lnum > cursor else cursor
	retval: C.int = 0
	for ; from_line < to_line; from_line, retval = from_line + 1, retval + 1 {
		hasFolding(wp, from_line, nil, &from_line)
	}
	if from_line > to_line {
		retval -= 1
	}
	if lnum < cursor {
		return -retval
	}
	return retval
}

// Make sure pos.lnum/col are valid in buf (col may be on NUL).
@(export)
check_pos :: proc "c" (buf: rawptr, pos: ^Pos_T) {
	context = runtime.default_context()
	pos.lnum = min(pos.lnum, (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^)
	if pos.col > 0 {
		pos.col = min(pos.col, ml_get_buf_len(buf, pos.lnum))
	}
}

// Make sure win->w_cursor.lnum is valid.
@(export)
check_cursor_lnum :: proc "c" (win: rawptr) {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(win) + W_BUFFER_OFF)^
	if (^Pos_T)(uintptr(win) + W_CURSOR_OFF).lnum > (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ {
		if !hasFolding(win, (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^, (^C.int)(uintptr(win) + W_CURSOR_OFF), nil) {
			(^Pos_T)(uintptr(win) + W_CURSOR_OFF).lnum = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		}
	}
	if (^Pos_T)(uintptr(win) + W_CURSOR_OFF).lnum <= 0 {
		(^Pos_T)(uintptr(win) + W_CURSOR_OFF).lnum = 1
	}
}

// Make sure win->w_cursor.col is valid (insert-mode aware).
@(export)
check_cursor_col :: proc "c" (win: rawptr) {
	context = runtime.default_context()
	oldcol := (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col
	oldcoladd := (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col + (^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd
	cur_ve_flags := get_ve_flags(win)
	len := ml_get_buf_len((^rawptr)(uintptr(win) + W_BUFFER_OFF)^, (^Pos_T)(uintptr(win) + W_CURSOR_OFF).lnum)
	if len == 0 {
		(^Pos_T)(uintptr(win) + W_CURSOR_OFF).col = 0
	} else if (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col >= len {
		if (State & MODE_INSERT) != 0 || restart_edit != 0 || (State & MODE_TERMINAL_O) != 0 || (VIsual_active && p_sel^ != 'o') || (cur_ve_flags & KOPT_VE_ONEMORE_O) != 0 || virtual_active(win) {
			(^Pos_T)(uintptr(win) + W_CURSOR_OFF).col = len
		} else {
			(^Pos_T)(uintptr(win) + W_CURSOR_OFF).col = len - 1
			mark_mb_adjustpos((^rawptr)(uintptr(win) + W_BUFFER_OFF)^, (^Pos_T)(uintptr(win) + W_CURSOR_OFF))
		}
	} else if (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col < 0 {
		(^Pos_T)(uintptr(win) + W_CURSOR_OFF).col = 0
	}
	if oldcol == MAXCOL {
		(^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd = 0
	} else if cur_ve_flags == KOPT_VE_ALL_O {
		if oldcoladd > (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col {
			(^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd = oldcoladd - (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col
			if (^Pos_T)(uintptr(win) + W_CURSOR_OFF).col + 1 < len {
				if !((^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd > 0) {
					libc.abort()
				}
				cs, ce: C.int
				getvcol(win, (^Pos_T)(uintptr(win) + W_CURSOR_OFF), &cs, nil, &ce, 0)
				(^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd = min((^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd, ce - cs)
			}
		} else {
			(^Pos_T)(uintptr(win) + W_CURSOR_OFF).coladd = 0
		}
	}
}

// Make sure wp->w_cursor is on a valid character.
@(export)
check_cursor :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	check_cursor_lnum(wp)
	check_cursor_col(wp)
}

// Check if VIsual position is valid, correct it if not.
@(export)
check_visual_pos :: proc "c" () {
	context = runtime.default_context()
	if VIsual_g.lnum > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
		VIsual_g.lnum = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		VIsual_g.col = 0
		VIsual_g.coladd = 0
	} else {
		len := ml_get_len_r2(VIsual_g.lnum)
		if VIsual_g.col > len {
			VIsual_g.col = len
			VIsual_g.coladd = 0
		}
	}
}

// Keep curwin->w_cursor off the line-end NUL.
@(export)
adjust_cursor_col :: proc "c" () {
	context = runtime.default_context()
	if (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col > 0 && (!VIsual_active || p_sel^ == 'o') && gchar_cursor() == 0 {
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col -= 1
	}
}

// Set curwin->w_leftcol, adjusting the cursor if needed.
@(export)
set_leftcol :: proc "c" (leftcol: C.int) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ == leftcol {
		return false
	}
	(^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ = leftcol
	changed_cline_bef_curs_r(curwin)
	lastcol := i64((^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^) + i64((^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^) - i64(win_col_off_r(curwin)) - 1
	validate_virtcol_r(curwin)
	retval := false
	siso := get_sidescrolloff_value(curwin)
	if i64((^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^) > lastcol - i64(siso) {
		retval = true
		coladvance(curwin, C.int(lastcol - i64(siso)))
	} else if i64((^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^) < i64((^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^) + i64(siso) {
		retval = true
		coladvance(curwin, C.int(i64((^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^) + i64(siso)))
	}
	s, e: C.int
	getvvcol(curwin, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF), &s, nil, &e, 0)
	if i64(e) > lastcol {
		retval = true
		coladvance(curwin, s - 1)
	} else if s < (^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ {
		retval = true
		if coladvance(curwin, e + 1) == FAIL_E {
			(^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ = s
			changed_cline_bef_curs_r(curwin)
		}
	}
	if retval {
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	}
	redraw_later(curwin, UPD_NOT_VALID)
	return retval
}

@(export)
gchar_cursor :: proc "c" () -> C.int {
	context = runtime.default_context()
	return utf_ptr2char(transmute(cstring)(get_cursor_pos_ptr()))
}

// Character immediately before the cursor (-1 at col 0).
@(export)
char_before_cursor :: proc "c" () -> C.int {
	context = runtime.default_context()
	if (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col == 0 {
		return -1
	}
	line := get_cursor_line_ptr()
	p := (^u8)(uintptr(line) + uintptr((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col))
	prev_len := utf_head_off(transmute(cstring)(line), transmute(cstring)((^u8)(uintptr(p) - 1))) + 1
	return utf_ptr2char(transmute(cstring)((^u8)(uintptr(p) - uintptr(prev_len))))
}

// Write a character directly into the block at the cursor.
@(export)
pchar_cursor :: proc "c" (c: u8) {
	context = runtime.default_context()
	([^]u8)(ml_get_buf_mut_e(curbuf, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum))[(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col] = c
}

// Pointer to the cursor line.
@(export)
get_cursor_line_ptr :: proc "c" () -> ^u8 {
	context = runtime.default_context()
	return ml_get_buf(curbuf, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum)
}

// Pointer to the cursor position.
@(export)
get_cursor_pos_ptr :: proc "c" () -> ^u8 {
	context = runtime.default_context()
	return (^u8)(uintptr(ml_get_buf(curbuf, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum)) + uintptr((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col))
}

// Length of the cursor line (excluding NUL).
@(export)
get_cursor_line_len :: proc "c" () -> C.int {
	context = runtime.default_context()
	return ml_get_buf_len(curbuf, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum)
}

// Length from the cursor to end of line.
@(export)
get_cursor_pos_len :: proc "c" () -> C.int {
	context = runtime.default_context()
	return ml_get_buf_len(curbuf, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum) - (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col
}
