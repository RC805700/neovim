package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// move.c port: cursor motion, topline/botline validation, scrolling.
// Publics are @(export); C-statics are _o dormant plains.

foreign _ {
	@(link_name = "p_sj")
	p_sj_g: C.longlong
	// curs_columns now defined below — call directly.
	// set_empty_rows now defined below — call directly.
	@(link_name = "p_ss")
	p_ss_g: C.longlong
	@(link_name = "mouse_dragging")
	mouse_dragging_g: C.int
	// scroll_cursor_top/bot now defined below — call directly.
	@(link_name = "cursor_down")
	cursor_down_e :: proc "c" (n: C.int, upd_topline: bool) -> C.int ---
	@(link_name = "cursor_up")
	cursor_up_e :: proc "c" (n: C.int, upd_topline: bool) -> C.int ---
	@(link_name = "nv_screengo")
	nv_screengo_e :: proc "c" (oap: rawptr, dir: C.int, dist: C.int, skip_conceal: bool) -> bool ---
	@(link_name = "nv_g_home_m_cmd")
	nv_g_home_m_cmd_e :: proc "c" (cap: rawptr) ---
	@(link_name = "diff_get_corresponding_line")
	diff_get_corresponding_line_e :: proc "c" (buf1: rawptr, lnum1: C.int) -> C.int ---
	@(link_name = "vcol2col")
	vcol2col_e :: proc "c" (wp: rawptr, lnum: C.int, vcol: C.int, coladdp: ^C.int) -> C.int ---
	// win_check_anchored_floats is an Odin export (winfloat.odin) — call directly.
}

W_VALID_CURSOR_OFF_O :: 544
W_VALID_LEFTCOL_OFF_O :: 556
W_VALID_SKIPCOL_OFF_O :: 560
W_LEFTCOL_OFF_O :: 384
W_WCOL_OFF_O :: 604
W_WROW_OFF_O :: 600
W_LINES_OFF_O :: 632
W_LINES_VALID_OFF_O :: 624
W_P_SO_OFF_O :: 1176
W_P_NU_OFF_O :: 960
W_P_STC_OFF_O :: 1088
W_SCWIDTH_OFF_O :: 680
VALID_BOTLINE_AP_O :: 64
VALID_BOTLINE_O :: 0x20

@(export)
win_col_off :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	nu := (^C.int)(uintptr(wp) + W_P_NU_OFF_O)^ != 0 || (^C.int)(uintptr(wp) + W_P_RNU_OFF_O)^ != 0 || ([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF_O)^)[0] != 0
	n := C.int(0)
	if nu {
		stc_empty := C.int(0)
		if ([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF_O)^)[0] == 0 {
			stc_empty = 1
		}
		n = number_width(wp) + stc_empty
	}
	return n + win_fdccol_count(wp) + (^C.int)(uintptr(wp) + W_SCWIDTH_OFF_O)^ * SIGN_WIDTH_O
}

@(export)
win_col_off2 :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	stc := (^rawptr)(uintptr(wp) + W_P_STC_OFF_O)^
	has_col := false
	if (^C.int)(uintptr(wp) + W_P_NU_OFF_O)^ != 0 {
		has_col = true
	}
	if (^C.int)(uintptr(wp) + W_P_RNU_OFF_O)^ != 0 {
		has_col = true
	}
	if ([^]u8)(stc)[0] != 0 {
		has_col = true
	}
	if has_col && vim_strchr(p_cpo, C.int(CPO_NUMCOL_O)) != nil {
		stc_empty := C.int(0)
		if ([^]u8)(stc)[0] == 0 {
			stc_empty = 1
		}
		return number_width(wp) + stc_empty
	}
	return 0
}

@(export)
set_valid_virtcol :: proc "c" (wp: rawptr, vcol: C.int) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ = vcol
	redraw_for_cursorcolumn_o(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_VIRTCOL_O
}

@(export)
sms_marker_overlap :: proc "c" (wp: rawptr, extra2_in: C.int) -> C.int {
	context = runtime.default_context()
	extra2 := extra2_in
	if extra2 == -1 {
		extra2 = win_col_off(wp) - win_col_off2(wp)
	}
	if get_showbreak_value(wp)^ != 0 {
		return 0
	}
	if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && ([^]u8)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_PREC_OFF)[0] != 0 {
		return 1
	}
	if extra2 > 3 {
		return 0
	}
	return 3 - extra2
}

// Number of screen lines skipped with w_skipcol.
adjust_plines_for_skipcol_o :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 {
		return 0
	}
	width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	w2 := width + win_col_off2(wp)
	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ >= width && w2 > 0 {
		return ((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ - width) / w2 + 1
	}
	return 0
}

@(export)
plines_correct_topline :: proc "c" (wp: rawptr, lnum: C.int, nextp: ^C.int, limit_winheight: bool, foldedp: ^bool) -> C.int {
	context = runtime.default_context()
	n := plines_win_full(wp, lnum, nextp, foldedp, true, false)
	if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		n -= adjust_plines_for_skipcol_o(wp)
	}
	if limit_winheight && n > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		return (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	}
	return n
}

redraw_for_cursorline_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_CROW_O != 0 {
		return
	}
	if (^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 || win_cursorline_standout(wp) {
		redraw_later(wp, UPD_VALID_O)
	}
}

redraw_for_cursorcolumn_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if wp == curwin && (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ > 0 && conceal_cursor_line(wp) {
		redrawWinline(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
	}
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_VIRTCOL_O != 0 {
		return
	}
	if (^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 {
		redraw_later(wp, UPD_SOME_VALID_O)
	} else if (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 && ((^C.int)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ & kOptCuloptFlagScreenline_S) != 0 {
		redraw_later(wp, UPD_VALID_O)
	}
	if VIsual_active && (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
		redraw_buf_later(curbuf, UPD_INVERTED_S)
	}
}

// Compute w_botline for the current w_topline.
comp_botline_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	lnum: C.int
	done: C.int
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_CROW_O != 0 {
		lnum = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
		done = (^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^
	} else {
		lnum = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		done = 0
	}
	ml := (^Memline_O)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + 8)
	for lnum <= ml.line_count {
		last := lnum
		folded := false
		n := plines_correct_topline(wp, lnum, &last, true, &folded)
		if lnum <= (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ && last >= (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
			(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ = done
			(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ = n
			(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ = folded
			redraw_for_cursorline_o(wp)
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_CROW_O | VALID_CHEIGHT_O)
		}
		if done + n > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			break
		}
		done += n
		lnum = last
		lnum += 1
	}
	(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
	(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	set_empty_rows(wp, done)
	win_check_anchored_floats(wp)
}

skipcol_from_plines_o :: proc "c" (wp: rawptr, plines_off: C.int) -> C.int {
	context = runtime.default_context()
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	skipcol: C.int = 0
	if plines_off > 0 {
		skipcol += width1
	}
	if plines_off > 1 {
		skipcol += (width1 + win_col_off2(wp)) * (plines_off - 1)
	}
	return skipcol
}

reset_skipcol_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 {
		return
	}
	(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
	redraw_later(wp, UPD_SOME_VALID_O)
}

use_scrolloffpad_o :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	return get_scrolloff_value(wp) > 0 && get_scrolloffpad_value(wp) > 0
}

scrolloffpad_eof_pressure_o :: proc "c" (wp: rawptr, lnum: C.int, so: C.longlong) -> bool {
	context = runtime.default_context()
	if !use_scrolloffpad_o(wp) || so <= 0 {
		return false
	}
	ml := (^Memline_O)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + 8)
	return C.longlong(lnum) > C.longlong(ml.line_count) - so
}

scrolljump_value_o :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	if p_sj_g >= 0 {
		return C.int(p_sj_g)
	}
	return (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ * C.int(-p_sj_g) / 100
}

@(export)
update_curswant_force :: proc "c" () {
	context = runtime.default_context()
	validate_virtcol(curwin)
	(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^
	(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = false
}

@(export)
update_curswant :: proc "c" () {
	context = runtime.default_context()
	if (^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ {
		update_curswant_force()
	}
}

@(export)
check_cursor_moved :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	wvc := (^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^
	cur := (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
	if cur.lnum != wvc.lnum {
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O | VALID_CHEIGHT_O | VALID_CROW_O | VALID_TOPLINE_O)
		conceal_hit := false
		if wp == curwin && wvc.lnum > 0 && (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ >= 2 && !conceal_cursor_line(wp) {
			if decor_conceal_line_r(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ - 1, true) {
				conceal_hit = true
			}
			if decor_conceal_line_r(wp, wvc.lnum - 1, true) {
				conceal_hit = true
			}
		}
		// Concealed line visibility toggled.
		if conceal_hit {
			changed_window_setting(wp)
		}
		(^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^ = cur
		(^C.int)(uintptr(wp) + W_VALID_LEFTCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
		(^C.int)(uintptr(wp) + W_VALID_SKIPCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF_O)^
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	} else if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != (^C.int)(uintptr(wp) + W_VALID_SKIPCOL_OFF_O)^ {
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O | VALID_CHEIGHT_O | VALID_CROW_O | VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
		(^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^ = cur
		(^C.int)(uintptr(wp) + W_VALID_LEFTCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
		(^C.int)(uintptr(wp) + W_VALID_SKIPCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF_O)^
	} else if cur.col != wvc.col || (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^ != (^C.int)(uintptr(wp) + W_VALID_LEFTCOL_OFF_O)^ || cur.coladd != wvc.coladd {
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O)
		wvc2 := (^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^
		wvc2.col = cur.col
		(^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^ = wvc2
		(^C.int)(uintptr(wp) + W_VALID_LEFTCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
		wvc3 := (^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^
		wvc3.coladd = cur.coladd
		(^Pos_T)(uintptr(wp) + W_VALID_CURSOR_OFF_O)^ = wvc3
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	}
}

@(export)
changed_window_setting :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_LINES_VALID_OFF_O)^ = 0
	changed_line_abv_curs_win(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_BOTLINE_O | VALID_BOTLINE_AP_O | VALID_TOPLINE_O)
	redraw_later(wp, UPD_NOT_VALID_O)
}

@(export)
changed_window_setting_all :: proc "c" () {
	context = runtime.default_context()
	tp := first_tabpage
	for tp != nil {
		wp := firstwin
		if tp != curtab {
			wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		}
		for wp != nil {
			changed_window_setting(wp)
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

@(export)
set_topline :: proc "c" (wp: rawptr, lnum_in: C.int) {
	context = runtime.default_context()
	lnum := lnum_in
	prev_topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	hasFolding(wp, lnum, &lnum, nil)
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	bot := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ + lnum - (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	if bot > ml.line_count + 1 {
		bot = ml.line_count + 1
	}
	(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = bot
	(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = lnum
	(^bool)(uintptr(wp) + W_TOPLINE_WAS_SET_OFF)^ = true
	if lnum != prev_topline {
		(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = 0
	}
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O | VALID_TOPLINE_O)
	redraw_later(wp, UPD_VALID_O)
}

@(export)
changed_cline_bef_curs :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O | VALID_CROW_O | VALID_CHEIGHT_O | VALID_TOPLINE_O)
}

@(export)
changed_line_abv_curs :: proc "c" () {
	context = runtime.default_context()
	(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O | VALID_CROW_O | VALID_CHEIGHT_O | VALID_TOPLINE_O)
}

@(export)
changed_line_abv_curs_win :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O | VALID_CROW_O | VALID_CHEIGHT_O | VALID_TOPLINE_O)
}

@(export)
validate_botline_win :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_BOTLINE_O == 0 {
		comp_botline_o(wp)
	}
}

@(export)
invalidate_botline_win :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
}

@(export)
approximate_botline_win :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_BOTLINE_O)
}

@(export)
cursor_valid :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & (VALID_WROW_O | VALID_WCOL_O) == (VALID_WROW_O | VALID_WCOL_O) {
		return 1
	}
	return 0
}

@(export)
validate_cursor :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	check_cursor_lnum(wp)
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & (VALID_WCOL_O | VALID_WROW_O) != (VALID_WCOL_O | VALID_WROW_O) {
		curs_columns(wp, 1)
	}
}

curs_rows_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	all_invalid := !redrawing() || (^C.int)(uintptr(wp) + W_LINES_VALID_OFF_O)^ == 0 || (^Wline_T)(uintptr(wp) + W_LINES_OFF_O)^.wl_lnum > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	i: C.int = 0
	(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ = 0
	lnum := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	for lnum < (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
		valid := false
		if !all_invalid && i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF_O)^ {
			wl := (^Wline_T)(uintptr(wp) + W_LINES_OFF_O + uintptr(i) * 16)
			if wl.wl_lnum < lnum || !wl.wl_valid {
			} else if wl.wl_lnum == lnum {
				wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
				mod_set := (^bool)(uintptr(wbuf) + B_MOD_SET_OFF)^
				mod_top := (^C.int)(uintptr(wbuf) + B_MOD_TOP_OFF)^
				lastlnum := (^C.int)(uintptr(wl) + 12)^
				if !mod_set || lastlnum < (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ || mod_top > lastlnum + 1 {
					valid = true
				}
			} else if wl.wl_lnum > lnum {
				i -= 1
			}
		}
		if valid && (lnum != (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ || ((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 && !win_may_fill(wp))) {
			lnum = (^C.int)(uintptr(wp) + W_LINES_OFF_O + uintptr(i) * 16 + 12)^ + 1
			if lnum > (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
				break
			}
			(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ += C.int((^Wline_T)(uintptr(wp) + W_LINES_OFF_O + uintptr(i) * 16)^.wl_size)
		} else {
			last := lnum
			folded := false
			n := plines_correct_topline(wp, lnum, &last, true, &folded)
			lnum = last + 1
			if lnum + C.int(decor_conceal_line_r(wp, lnum - 1, false)) > (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
				break
			}
			(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ += n
		}
		i += 1
	}
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_CHEIGHT_O == 0 {
		n_valid := (^C.int)(uintptr(wp) + W_LINES_VALID_OFF_O)^
		if all_invalid || i == n_valid {
			folded := false
			(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ = plines_win_full(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, nil, &folded, true, true)
			(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ = folded
		} else if i > n_valid {
			(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ = 0
			(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ = hasFolding(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, nil, nil)
		} else {
			wl := (^Wline_T)(uintptr(wp) + W_LINES_OFF_O + uintptr(i) * 16)
			(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ = C.int(wl.wl_size)
			(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ = wl.wl_folded
		}
	}
	redraw_for_cursorline_o(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_CROW_O | VALID_CHEIGHT_O)
}

@(export)
validate_virtcol :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_VIRTCOL_O != 0 {
		return
	}
	getvvcol(wp, (^Pos_T)(rawptr(uintptr(wp) + W_CURSOR_OFF)), nil, (^C.int)(rawptr(uintptr(wp) + W_VIRTCOL_OFF)), nil, 0)
	redraw_for_cursorcolumn_o(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_VIRTCOL_O
}

@(export)
validate_cheight :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_CHEIGHT_O != 0 {
		return
	}
	folded := false
	(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ = plines_win_full(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, nil, &folded, true, true)
	(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ = folded
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_CHEIGHT_O
}

@(export)
validate_cursor_col :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	validate_virtcol(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_WCOL_O != 0 {
		return
	}
	col := (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
	off := win_col_off(wp)
	col += off
	width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - off + win_col_off2(wp)
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && col >= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ && width > 0 {
		col -= ((col - (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) / width + 1) * width
	}
	if col > (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^ {
		col -= (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
	} else {
		col = 0
	}
	(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ = col
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_WCOL_O
}

W_P_SMS_OFF_O :: 1048
W_FILLER_ROWS_OFF_O :: 620
W_WINROW_OFF2_O :: 492
W_WINCOL_OFF2_O :: 496

@(export)
curs_columns :: proc "c" (wp: rawptr, may_scroll: C.int) {
	context = runtime.default_context()
	startcol: C.int
	endcol: C.int
	update_topline(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_CROW_O == 0 {
		curs_rows_o(wp)
	}
	if (^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ {
		startcol = (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
		(^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ = startcol
		endcol = startcol
	} else {
		getvvcol(wp, (^Pos_T)(rawptr(uintptr(wp) + W_CURSOR_OFF)), &startcol, (^C.int)(rawptr(uintptr(wp) + W_VIRTCOL_OFF)), &endcol, 0)
	}
	if startcol > dollar_vcol {
		dollar_vcol = -1
	}
	extra := win_col_off(wp)
	(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ + extra
	endcol += extra
	(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ = (^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^
	n: C.int
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - extra
	width2: C.int = 0
	did_sub_skipcol := false
	if width1 <= 0 {
		(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - 1
		if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1
		} else {
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1 - (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
		}
	} else if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ != 0 {
		width2 = width1 + win_col_off2(wp)
		if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && (^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ >= (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ {
			if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ <= width1 {
				(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ -= width2
			} else {
				(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ -= width2 * (((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ - width1) / width2 + 1)
			}
			did_sub_skipcol = true
		}
		if (^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ >= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ {
			n = ((^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ - (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) / width2 + 1
			(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ -= n * width2
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ += n
		}
	} else if may_scroll != 0 && !(^bool)(uintptr(wp) + W_CLINE_FOLDED_OFF)^ {
		siso := get_sidescrolloff_value(wp)
		leftcol := C.longlong((^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^)
		off_left := C.longlong(startcol) - leftcol - siso
		off_right := C.longlong(endcol) - leftcol - (C.longlong((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) - siso) + 1
		if off_left < 0 || off_right > 0 {
			diff := off_right
			if off_left < 0 {
				diff = -off_left
			}
			new_leftcol: C.longlong
			if p_ss_g == 0 || diff >= C.longlong(width1) / 2 || off_right >= off_left {
				new_leftcol = C.longlong((^C.int)(uintptr(wp) + W_WCOL_OFF_O)^) - C.longlong(extra) - C.longlong(width1) / 2
			} else {
				if diff < p_ss_g {
					diff = p_ss_g
				}
				if off_left < 0 {
					new_leftcol = leftcol - diff
				} else {
					new_leftcol = leftcol + diff
				}
			}
			if new_leftcol < 0 {
				new_leftcol = 0
			}
			if new_leftcol != leftcol {
				(^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^ = C.int(new_leftcol)
				win_check_anchored_floats(wp)
				redraw_later(wp, UPD_NOT_VALID_O)
			}
		}
		(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ -= (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
	} else if (^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ > (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^ {
		(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ -= (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
	} else {
		(^C.int)(uintptr(wp) + W_WCOL_OFF_O)^ = 0
	}
	if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ += (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
	} else {
		(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ += win_get_fill(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
	}
	plines: C.int = 0
	so := get_scrolloff_value(wp)
	prev_skipcol := (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
	skip_big := false
	if (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		skip_big = true
	} else {
		need_plines := false
		if prev_skipcol > 0 {
			need_plines = true
		}
		if (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ + C.int(so) >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			need_plines = true
		}
		if need_plines {
			plines = plines_win_nofill(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, false) - 1
			if plines >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
				skip_big = true
			}
		}
	}
	if skip_big && (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ && width2 > 0 && (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ != 0 {
		extra = 0
		if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ + C.int(so * C.longlong(width2)) > (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
			extra = 1
		}
		if plines == 0 {
			plines = plines_win(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, false)
		}
		plines -= 1
		if plines > (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ + C.int(so) {
			n = (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ + C.int(so)
		} else {
			n = plines
		}
		if C.longlong(n) >= C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) + C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^) / C.longlong(width2) - so {
			extra += 2
		}
		if extra == 3 || C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) <= so * 2 {
			n = (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ / width2
			if n > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2 {
				n -= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2
			} else {
				n = 0
			}
			if n > plines - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + 1 {
				n = plines - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + 1
			}
			if n > 0 {
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = width1 + (n - 1) * width2
			} else {
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
			}
		} else if extra == 1 {
			extra = C.int((C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^) + so * C.longlong(width2) - C.longlong((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^) + C.longlong(width2) - 1) / C.longlong(width2))
			if extra > 0 {
				if C.longlong(extra * width2) > C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^) {
					extra = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ / width2
				}
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ -= extra * width2
			}
		} else if extra == 2 {
			endcol = (n - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + 1) * width2
			for endcol > (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
				endcol -= width2
			}
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = max((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^, endcol)
		}
		if did_sub_skipcol {
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ -= ((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ - prev_skipcol) / width2
		} else {
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ -= (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ / width2
		}
		if (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			extra = (^C.int)(uintptr(wp) + W_WROW_OFF_O)^ - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + 1
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ += extra * width2
			(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ -= extra
		}
		extra = (prev_skipcol - (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^) / width2
		if (^GridView)(uintptr(wp) + W_GRID_OFF)^.target != nil {
			win_scroll_lines(wp, 0, extra)
		}
	} else if (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ == 0 {
		(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
	}
	if prev_skipcol != (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ {
		redraw_later(wp, UPD_SOME_VALID_O)
	}
	redraw_for_cursorcolumn_o(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_WCOL_O | VALID_WROW_O | VALID_VIRTCOL_O)
}

lineoff_T :: struct {
	lnum:   C.int,
	fill:   C.int,
	height: C.int,
}
#assert(size_of(lineoff_T) == 12)

topline_back_winheight_o :: proc "c" (wp: rawptr, lp: ^lineoff_T) {
	topline_back_winheight_full_o(wp, lp, 1)
}

topline_back_winheight_full_o :: proc "c" (wp: rawptr, lp: ^lineoff_T, winheight: C.int) {
	context = runtime.default_context()
	if lp.fill < win_get_fill(wp, lp.lnum) {
		lp.fill += 1
		lp.height = 1
	} else {
		lp.lnum -= 1
		lp.fill = 0
		if lp.lnum < 1 {
			lp.height = MAXCOL
		} else if hasFolding(wp, lp.lnum, &lp.lnum, nil) {
			if !decor_conceal_line_r(wp, lp.lnum - 1, false) {
				lp.height = 1
			} else {
				lp.height = 0
			}
		} else {
			lp.height = plines_win_nofill(wp, lp.lnum, winheight != 0)
		}
	}
}

topline_back_o :: proc "c" (wp: rawptr, lp: ^lineoff_T) {
	context = runtime.default_context()
	topline_back_winheight_full_o(wp, lp, 1)
}

botline_forw_o :: proc "c" (wp: rawptr, lp: ^lineoff_T) {
	context = runtime.default_context()
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if lp.fill < win_get_fill(wp, lp.lnum + 1) {
		lp.fill += 1
		lp.height = 1
	} else {
		lp.lnum += 1
		lp.fill = 0
		if lp.lnum > ml.line_count {
			lp.height = MAXCOL
		} else if hasFolding(wp, lp.lnum, nil, &lp.lnum) {
			if !decor_conceal_line_r(wp, lp.lnum - 1, false) {
				lp.height = 1
			} else {
				lp.height = 0
			}
		} else {
			lp.height = plines_win_nofill(wp, lp.lnum, true)
		}
	}
}

check_top_offset_o :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	so := get_scrolloff_value(wp)
	if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ + C.int(so) || win_lines_concealed_r(wp) {
		loff := lineoff_T{(^C.int)(uintptr(wp) + W_CURSOR_OFF)^, 0, 0}
		n := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		for C.longlong(n) < so {
			topline_back_o(wp, &loff)
			if loff.lnum < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ || (loff.lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ && loff.fill > 0) {
				break
			}
			n += loff.height
		}
		if C.longlong(n) < so {
			return true
		}
	}
	return false
}

@(export)
update_topline :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	check_botline := false
	use_wp_so := (^C.longlong)(uintptr(wp) + W_P_SO_OFF_O)^ >= 0
	so_val := (^C.longlong)(uintptr(wp) + W_P_SO_OFF_O)^
	if !use_wp_so {
		so_val = p_so_g
	}
	save_so := so_val
	if skip_update_topline_g {
		return
	}
	if (^ScreenGrid)(&default_grid_u8)^.chars == nil || (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ == 0 {
		check_cursor_lnum(wp)
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
		(^C.int)(uintptr(wp) + W_SCBIND_POS_OFF)^ = 1
		return
	}
	check_cursor_moved(wp)
	if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_TOPLINE_O != 0 {
		return
	}
	if mouse_dragging_g > 0 {
		so_val = C.longlong(mouse_dragging_g) - 1
	}
	eof_pressure := scrolloffpad_eof_pressure_o(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, so_val)
	old_topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	old_topfill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if buf_is_empty(wbuf) {
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != 1 {
			redraw_later(wp, UPD_NOT_VALID_O)
		}
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = 1
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = 2
		(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
		(^C.int)(uintptr(wp) + W_SCBIND_POS_OFF)^ = 1
	} else {
		check_topline := false
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > 1 || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 {
			if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
				check_topline = true
			} else if check_top_offset_o(wp) {
				check_topline = true
			} else if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
				vcol: C.int
				getvvcol(wp, (^Pos_T)(rawptr(uintptr(wp) + W_CURSOR_OFF)), &vcol, nil, nil, 0)
				overlap := sms_marker_overlap(wp, -1)
				if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ + overlap > vcol {
					check_topline = true
				}
			}
		}
		if !check_topline && (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ > win_get_fill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) {
			check_topline = true
		}
		if check_topline {
			halfheight := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2 - 1
			if halfheight < 2 {
				halfheight = 2
			}
			n: C.longlong
			if win_lines_concealed_r(wp) {
				n = 0
				lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
				for C.longlong(lnum) < C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) + so_val {
					if lnum >= ml.line_count {
						break
					}
					if !decor_conceal_line_r(wp, lnum, false) {
						n += 1
					}
					if n >= C.longlong(halfheight) {
						break
					}
					hasFolding(wp, lnum, nil, &lnum)
					lnum += 1
				}
			} else {
				n = C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) + so_val - C.longlong((^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
			}
			min_scroll := scrolljump_value_o(wp)
			if eof_pressure {
				scroll_cursor_halfway(wp, true, true)
			} else if n >= C.longlong(halfheight) && C.longlong(min_scroll) < C.longlong(halfheight) {
				scroll_cursor_halfway(wp, false, false)
			} else {
				scroll_cursor_top(wp, min_scroll, 0)
				check_botline = true
			}
		} else {
			top := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			hasFolding(wp, top, &top, nil)
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = top
			check_botline = true
		}
	}
	if check_botline {
		if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_BOTLINE_AP_O == 0 {
			validate_botline_win(wp)
		}
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == nil {
			libc.abort()
		}
		if (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ <= ml.line_count || use_scrolloffpad_o(wp) {
			if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
				if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ >= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - C.int(so_val) || win_lines_concealed_r(wp) {
					loff := lineoff_T{(^C.int)(uintptr(wp) + W_CURSOR_OFF)^, 0, 0}
					hasFolding(wp, loff.lnum, nil, &loff.lnum)
					loff.fill = 0
					n := (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
					n += (^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^
					loff.height = 0
					still_check := true
					for loff.lnum < (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
						if loff.lnum + 1 >= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && loff.fill != 0 {
							break
						}
						n += loff.height
						if C.longlong(n) >= so_val {
							still_check = false
							break
						}
						botline_forw_o(wp, &loff)
					}
					if still_check {
						if C.longlong(n) >= so_val && !eof_pressure {
							check_botline = false
						}
					}
				} else {
					check_botline = false
				}
			}
			if check_botline {
				n: C.longlong = 0
				if win_lines_concealed_r(wp) {
					lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
					for C.longlong(lnum) >= C.longlong((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^) - so_val {
						if lnum <= 0 {
							break
						}
						if !decor_conceal_line_r(wp, lnum, false) {
							n += 1
						}
						if n > C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) + 1 {
							break
						}
						hasFolding(wp, lnum, &lnum, nil)
						lnum -= 1
					}
				} else {
					n = C.longlong((^C.int)(uintptr(wp) + W_CURSOR_OFF)^) - C.longlong((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^) + 1 + so_val
				}
				if n <= C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) + 1 {
					if eof_pressure {
						scroll_cursor_halfway(wp, true, true)
					} else {
						scroll_cursor_bot(wp, scrolljump_value_o(wp), false)
					}
				} else {
					scroll_cursor_halfway(wp, eof_pressure, eof_pressure)
				}
			}
		}
	}
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_TOPLINE_O
	(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	win_check_anchored_floats(wp)
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != old_topline || (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ != old_topfill {
		dollar_vcol = -1
		redraw_later(wp, UPD_VALID_O)
		if (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ == 0 {
			reset_skipcol_o(wp)
		} else if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != 0 {
			redraw_later(wp, UPD_SOME_VALID_O)
		}
		if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			validate_cursor(wp)
		}
	}
	if use_wp_so {
		(^C.longlong)(uintptr(wp) + W_P_SO_OFF_O)^ = save_so
	} else {
		p_so_g = save_so
	}
}

@(export)
scroll_redraw :: proc "c" (up: C.int, count: C.int) {
	context = runtime.default_context()
	prev_topline := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
	prev_skipcol := (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^
	prev_topfill := (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^
	prev_lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	moved := false
	if up != 0 {
		moved = scrollup(curwin, count, true)
	} else {
		moved = scrolldown(curwin, count, 1)
	}
	if get_scrolloff_value(curwin) > 0 {
		cursor_correct(curwin)
		check_cursor_moved(curwin)
		(^C.int)(uintptr(curwin) + W_VALID_OFF)^ |= VALID_TOPLINE_O
		for (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ == prev_topline && (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ == prev_skipcol && (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ == prev_topfill {
			if up != 0 {
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > prev_lnum || cursor_down_e(1, false) == FAIL_E {
					break
				}
			} else {
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < prev_lnum || prev_topline == 1 || cursor_up_e(1, false) == FAIL_E {
					break
				}
			}
			check_cursor_moved(curwin)
			(^C.int)(uintptr(curwin) + W_VALID_OFF)^ |= VALID_TOPLINE_O
		}
	}
	if moved {
		(^bool)(uintptr(curwin) + W_VIEWPORT_INVALID_OFF)^ = true
	}
	cursor_correct_sms_o(curwin)
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != prev_lnum {
		coladvance(curwin, (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^)
	}
	redraw_later(curwin, UPD_VALID_O)
}

@(export)
scrolldown :: proc "c" (wp: rawptr, line_count: C.int, byfold: C.int) -> bool {
	context = runtime.default_context()
	done: C.int = 0
	width1: C.int = 0
	width2: C.int = 0
	do_sms := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ != 0
	if do_sms {
		width1 = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
		width2 = width1 + win_col_off2(wp)
	}
	top := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	hasFolding(wp, top, &top, nil)
	(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = top
	validate_cursor(wp)
	todo := line_count
	for todo > 0 {
		todo -= 1
		can_fill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1 && (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ < win_get_fill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == 1 && !can_fill && (!do_sms || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ < width1) {
			break
		}
		if do_sms && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ >= width1 {
			if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ >= width1 + width2 {
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ -= width2
			} else {
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ -= width1
			}
			redraw_later(wp, UPD_NOT_VALID_O)
			done += 1
		} else if can_fill {
			(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ += 1
			done += 1
		} else {
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ -= 1
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
			(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = 0
			first: C.int = 0
			if hasFolding(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, &first, nil) {
				if !decor_conceal_line_r(wp, first - 1, false) {
					done += 1
				}
				if byfold == 0 {
					todo -= (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - first - 1
				}
				(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ -= (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - first
				(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = first
			} else if decor_conceal_line_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 1, false) {
				todo += 1
			} else {
				if do_sms {
					size := linetabsize_eol(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
					if size > width1 {
						(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = width1
						size -= width1
						redraw_later(wp, UPD_NOT_VALID_O)
					}
					for size > width2 {
						(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ += width2
						size -= width2
					}
					done += 1
				} else {
					done += plines_win_nofill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, true)
				}
			}
		}
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ -= 1
		invalidate_botline_win(wp)
	}
	for (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > 1 && decor_conceal_line_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 2, false) {
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ -= 1
		top2 := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		hasFolding(wp, top2, &top2, nil)
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = top2
	}
	(^C.int)(uintptr(wp) + W_WROW_OFF_O)^ += done
	(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ += done
	if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		(^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ = 0
	}
	check_topfill(wp, true)
	wrow := (^C.int)(uintptr(wp) + W_WROW_OFF_O)^
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ != 0 {
		validate_virtcol(wp)
		validate_cheight(wp)
		wrow += (^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ - 1 - (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ / (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^
	}
	moved := false
	for wrow >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ && (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ > 1 {
		first: C.int = 0
		if hasFolding(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, &first, nil) {
			if !decor_conceal_line_r(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ - 1, false) {
				wrow -= 1
			}
			ln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
			if first - 1 < 1 {
				ln = 1
			} else {
				ln = first - 1
			}
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = ln
		} else {
			ln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
			wrow -= plines_win(wp, ln, true)
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = ln - 1
		}
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_CHEIGHT_O | VALID_CROW_O | VALID_VIRTCOL_O)
		moved = true
	}
	if moved {
		foldAdjustCursor(wp)
		coladvance(wp, (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^)
	}
	ln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	top3 := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	if ln < top3 {
		ln = top3
	}
	(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = ln
	return moved
}

@(export)
scrollup :: proc "c" (wp: rawptr, line_count: C.int, byfold: bool) -> bool {
	context = runtime.default_context()
	topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
	do_sms := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ != 0
	if do_sms || (byfold && win_lines_concealed_r(wp)) || win_may_fill(wp) {
		width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
		width2 := width1 + win_col_off2(wp)
		size: C.int = 0
		prev_skipcol := (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
		if do_sms {
			size = linetabsize_eol(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
		}
		todo := line_count
		for todo > 0 {
			todo -= 1
			if decor_conceal_line_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 1, false) {
				todo += 1
			}
			if (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ > 0 {
				(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ -= 1
			} else {
				lnum := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
				if byfold {
					hasFolding(wp, lnum, nil, &lnum)
				}
				if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ && do_sms {
					add := width1
					if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 {
						add = width2
					}
					(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ += add
					if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ >= size {
						wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
						ml := (^Memline_O)(uintptr(wbuf) + 8)
						if lnum == ml.line_count {
							(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ -= add
							break
						}
						lnum += 1
					}
				} else {
					wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
					ml := (^Memline_O)(uintptr(wbuf) + 8)
					if lnum >= ml.line_count {
						break
					}
					lnum += 1
				}
				if lnum > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ += lnum - (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
					(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = lnum
					(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = win_get_fill(wp, lnum)
					(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
					if todo > 1 && do_sms {
						size = linetabsize_eol(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
					}
				}
			}
		}
		if prev_skipcol > 0 || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 {
			redraw_later(wp, UPD_NOT_VALID_O)
		}
	} else {
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ += line_count
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ += line_count
	}
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > ml.line_count {
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = ml.line_count
	}
	if (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ > ml.line_count + 1 {
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = ml.line_count + 1
	}
	check_topfill(wp, false)
	top5 := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	hasFolding(wp, top5, &top5, nil)
	(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = top5
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O)
	if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_CHEIGHT_O | VALID_CROW_O | VALID_VIRTCOL_O)
		coladvance(wp, (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^)
	}
	moved := topline != (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ || botline != (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
	return moved
}

@(export)
adjust_skipcol :: proc "c" () {
	context = runtime.default_context()
	if (^C.int)(uintptr(curwin) + W_P_WRAP_OFF)^ == 0 || (^C.int)(uintptr(curwin) + W_P_SMS_OFF_O)^ == 0 || (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ {
		return
	}
	width1 := (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - win_col_off(curwin)
	if width1 <= 0 {
		return
	}
	width2 := width1 + win_col_off2(curwin)
	so := get_scrolloff_value(curwin)
	scrolloff_cols: C.longlong = 0
	if so != 0 {
		scrolloff_cols = C.longlong(width1) + (so - 1) * C.longlong(width2)
	}
	scrolled := false
	validate_cheight(curwin)
	if (^C.int)(uintptr(curwin) + W_CLINE_HEIGHT_OFF)^ == (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ && plines_win(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, false) <= (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ {
		reset_skipcol_o(curwin)
		return
	}
	validate_virtcol(curwin)
	overlap := sms_marker_overlap(curwin, (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - width2)
	for (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ > 0 && (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ < (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ + overlap + C.int(scrolloff_cols) {
		if (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ >= width1 + width2 {
			(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ -= width2
		} else {
			(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ -= width1
		}
		scrolled = true
	}
	if scrolled {
		validate_virtcol(curwin)
		redraw_later(curwin, UPD_NOT_VALID_O)
		return
	}
	row: C.int = 0
	col := C.longlong((^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^) + scrolloff_cols
	if scrolloff_cols > 0 {
		size := linetabsize_eol(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^)
		size = width1 + width2 * ((size - width1 + width2 - 1) / width2)
		for col > C.longlong(size) {
			col -= C.longlong(width2)
		}
	}
	col -= C.longlong((^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^)
	if col >= C.longlong(width1) {
		col -= C.longlong(width1)
		row += 1
	}
	if col > C.longlong(width2) {
		row += C.int(col / C.longlong(width2))
	}
	if row >= (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ {
		if (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ == 0 {
			(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ += width1
			row -= 1
		}
		if row >= (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ {
			(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ += (row - (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^) * width2
		}
		redraw_later(curwin, UPD_NOT_VALID_O)
	}
}

@(export)
check_topfill :: proc "c" (wp: rawptr, down: bool) {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ > 0 {
		n := plines_win_nofill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, true)
		if (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ + n > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			if down && (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > 1 {
				(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ -= 1
				(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = 0
			} else {
				(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - n
				topfill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
				if topfill < 0 {
					topfill = 0
				}
				(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = topfill
			}
		}
	}
	win_check_anchored_floats(wp)
}

@(export)
scrolldown_clamp :: proc "c" () {
	context = runtime.default_context()
	can_fill := (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ < win_get_fill(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^)
	if (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ <= 1 && !can_fill {
		return
	}
	validate_cursor(curwin)
	end_row := (^C.int)(uintptr(curwin) + W_WROW_OFF_O)^
	if can_fill {
		end_row += 1
	} else {
		end_row += plines_win_nofill(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ - 1, true)
	}
	if (^C.int)(uintptr(curwin) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ != 0 {
		validate_cheight(curwin)
		validate_virtcol(curwin)
		end_row += (^C.int)(uintptr(curwin) + W_CLINE_HEIGHT_OFF)^ - 1 - (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ / (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^
	}
	if C.longlong(end_row) < C.longlong((^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^) - get_scrolloff_value(curwin) {
		if can_fill {
			(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ += 1
			check_topfill(curwin, true)
		} else {
			(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ -= 1
			(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ = 0
		}
		top_cl := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
		hasFolding(curwin, top_cl, &top_cl, nil)
		(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = top_cl
		(^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^ -= 1
		(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O)
	}
}

@(export)
scrollup_clamp :: proc "c" () {
	context = runtime.default_context()
	wbuf := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ == ml.line_count && (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ == 0 {
		return
	}
	validate_cursor(curwin)
	start_row := (^C.int)(uintptr(curwin) + W_WROW_OFF_O)^ - plines_win_nofill(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^, true) - (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^
	if (^C.int)(uintptr(curwin) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ != 0 {
		validate_virtcol(curwin)
		start_row -= (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ / (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^
	}
	if C.longlong(start_row) >= get_scrolloff_value(curwin) {
		if (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ > 0 {
			(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ -= 1
		} else {
			top := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
			hasFolding(curwin, top, nil, &top)
			(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = top + 1
		}
		(^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^ += 1
		(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O)
	}
}

@(export)
textpos2screenpos :: proc "c" (wp: rawptr, pos: ^Pos_T, rowp: ^C.int, scolp: ^C.int, ccolp: ^C.int, ecolp: ^C.int, local: bool) {
	context = runtime.default_context()
	scol: C.int = 0
	ccol: C.int = 0
	ecol: C.int = 0
	row: C.int = 0
	coloff: C.int = 0
	visible_row := false
	is_folded := false
	lnum := pos.lnum
	if lnum >= (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ && lnum <= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
		is_folded = hasFolding(wp, lnum, &lnum, nil)
		row = plines_m_win(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, lnum - 1, max(C.int))
		row -= adjust_plines_for_skipcol_o(wp)
		if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			row += (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		} else {
			row += win_get_fill(wp, lnum)
		}
		visible_row = true
	} else if !local || lnum < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		row = 0
	} else {
		row = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1
	}
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	existing_row := lnum > 0 && lnum <= (^C.int)(uintptr(wbuf) + B_ML_LINE_COUNT_OFF)^
	do_col := false
	if local {
		do_col = true
	}
	if visible_row {
		do_col = true
	}
	if do_col && existing_row {
		off := win_col_off(wp)
		if is_folded {
			add: C.int = 0
			if !local {
				add = (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_WINROW_OFF2_O)^
			}
			row += add + 1
			add2: C.int = 0
			if !local {
				add2 = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + (^C.int)(uintptr(wp) + W_WINCOL_OFF2_O)^
			}
			coloff = add2 + 1 + off
		} else {
			getvcol(wp, pos, &scol, &ccol, &ecol, 0)
			col := scol
			col += off
			width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - off + win_col_off2(wp)
			if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && col >= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ && width > 0 {
				rowoff := C.int(0)
				if visible_row {
					rowoff = (col - (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) / width + 1
				}
				col -= rowoff * width
				row += rowoff
			}
			col -= (^C.int)(uintptr(wp) + W_LEFTCOL_OFF_O)^
			if col >= 0 && col < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ && row >= 0 && row < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
				add: C.int = 0
				if !local {
					add = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + (^C.int)(uintptr(wp) + W_WINCOL_OFF2_O)^
				}
				coloff = col - scol + add + 1
				add3: C.int = 0
				if !local {
					add3 = (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_WINROW_OFF2_O)^
				}
				row += add3 + 1
			} else {
				scol = 0
				ccol = 0
				ecol = 0
				if local {
					if col < 0 {
						coloff = -1
					} else {
						coloff = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ + 1
					}
				} else {
					row = 0
				}
			}
		}
	}
	rowp^ = row
	scolp^ = scol + coloff
	ccolp^ = ccol + coloff
	ecolp^ = ecol + coloff
}

@(export)
f_screenpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(rettv)
	dict := (^rawptr)(uintptr(rettv) + 8)^
	wp := find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
	if wp == nil {
		return
	}
	pos := Pos_T{C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16))), C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 32))) - 1, 0}
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if pos.lnum > (^C.int)(uintptr(wbuf) + B_ML_LINE_COUNT_OFF)^ {
		semsg(cstring(E966_S), C.longlong(pos.lnum))
		return
	}
	if pos.col < 0 {
		pos.col = 0
	}
	row: C.int = 0
	scol: C.int = 0
	ccol: C.int = 0
	ecol: C.int = 0
	textpos2screenpos(wp, &pos, &row, &scol, &ccol, &ecol, false)
	tv_dict_add_nr(dict, cstring("row"), 3, C.longlong(row))
	tv_dict_add_nr(dict, cstring("col"), 3, C.longlong(scol))
	tv_dict_add_nr(dict, cstring("curscol"), 7, C.longlong(ccol))
	tv_dict_add_nr(dict, cstring("endcol"), 6, C.longlong(ecol))
}

virtcol2col_o :: proc "c" (wp: rawptr, lnum: C.int, vcol: C.int) -> C.int {
	context = runtime.default_context()
	offset := vcol2col_e(wp, lnum, vcol - 1, nil)
	line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
	p := transmute(^u8)(rawptr(uintptr(line) + uintptr(offset)))
	if ([^]u8)(p)[0] == 0 {
		if p == line {
			return 0
		}
		p = transmute(^u8)(rawptr(uintptr(p) - uintptr(C.int(utf_head_off(transmute(cstring)(line), transmute(cstring)(rawptr(uintptr(p) - 1)))) + 1)))
	}
	return C.int(uintptr(p) - uintptr(line) + 1)
}

@(export)
f_virtcol2col :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^rawptr)(uintptr(rettv) + 8)^ = transmute(rawptr)(C.longlong(-1))
	if tv_check_for_number_arg(argvars, 0) == FAIL_E || tv_check_for_number_arg(argvars, 1) == FAIL_E || tv_check_for_number_arg(argvars, 2) == FAIL_E {
		return
	}
	wp := find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
	if wp == nil {
		return
	}
	error := false
	lnum := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error))
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if error || lnum < 0 || lnum > (^C.int)(uintptr(wbuf) + B_ML_LINE_COUNT_OFF)^ {
		return
	}
	screencol := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error))
	if error || screencol < 0 {
		return
	}
	(^rawptr)(uintptr(rettv) + 8)^ = transmute(rawptr)(C.longlong(virtcol2col_o(wp, lnum, screencol)))
}

cursor_correct_sms_o :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ == 0 || (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 || (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ != (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		return
	}
	so := get_scrolloff_value(wp)
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
	width2 := width1 + win_col_off2(wp)
	so_cols: C.longlong = 0
	if so != 0 {
		so_cols = C.longlong(width1) + (so - 1) * C.longlong(width2)
	}
	space_cols := ((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1) * width2
	size: C.int = 0
	if so != 0 {
		size = linetabsize_eol(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
	}
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == 1 && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 {
		so_cols = 0
	} else if so_cols > C.longlong(space_cols) / 2 {
		so_cols = C.longlong(space_cols) / 2
	}
	for so_cols > C.longlong(size) && so_cols - C.longlong(width2) >= C.longlong(width1) && width1 > 0 {
		so_cols -= C.longlong(width2)
	}
	if so_cols >= C.longlong(width1) && so_cols > C.longlong(size) {
		so_cols -= C.longlong(width1)
	}
	overlap := C.int(0)
	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != 0 {
		overlap = sms_marker_overlap(wp, (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - width2)
	}
	top := C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^)
	if so_cols != 0 {
		top += so_cols
	} else {
		top += C.longlong(overlap)
	}
	bot := C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^) + C.longlong(width1) + C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1) * C.longlong(width2) - so_cols
	validate_virtcol(wp)
	col := (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
	if col < C.int(top) {
		if col < width1 {
			col += width1
		}
		for width2 > 0 && col < C.int(top) {
			col += width2
		}
	} else {
		for width2 > 0 && col >= C.int(bot) {
			col -= width2
		}
	}
	if col != (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
		(^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ = col
		rc := coladvance(wp, (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^)
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_CHEIGHT_O | VALID_CROW_O | VALID_VIRTCOL_O)
		if rc == FAIL_E && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ {
			validate_virtcol(wp)
			if (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ < (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ + overlap {
				(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ += 1
				(^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ = 0
				(^C.int)(uintptr(wp) + W_CURSOR_OFF + 8)^ = 0
				(^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ = 0
				(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_VIRTCOL_O)
			}
		}
	}
}

pos_equal_mv_o :: proc "c" (a: Pos_T, b: Pos_T) -> bool {
	context = runtime.default_context()
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

@(private="file")
prev_curwin_mv_g: rawptr
@(private="file")
prev_cursor_mv_g: Pos_T

@(export)
scroll_cursor_top :: proc "c" (wp: rawptr, min_scroll: C.int, always: C.int) {
	context = runtime.default_context()
	old_topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	old_skipcol := (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
	old_topfill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
	off := get_scrolloff_value(wp)
	if mouse_dragging_g > 0 {
		off = C.longlong(mouse_dragging_g) - 1
	}
	validate_cheight(wp)
	scrolled: C.int = 0
	used := (^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^
	if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		scrolled = used
	}
	top: C.int
	bot: C.int
	if hasFolding(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, &top, &bot) {
		top -= 1
		bot += 1
	} else {
		top = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ - 1
		bot = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ + 1
	}
	new_topline := top + 1
	extra := win_get_fill(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
	for top > 0 {
		i := plines_win_nofill(wp, top, true)
		top2 := top
		hasFolding(wp, top2, &top2, nil)
		top = top2
		if top < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			scrolled += i
		}
		should_break := false
		if new_topline >= (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			should_break = true
		}
		if scrolled > min_scroll {
			should_break = true
		}
		if should_break && C.longlong(extra) >= off {
			break
		}
		used += i
		wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		ml := (^Memline_O)(uintptr(wbuf) + 8)
		if C.longlong(extra) + C.longlong(i) <= off && bot < ml.line_count {
			used += plines_win_full(wp, bot, &bot, nil, true, true)
		}
		if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			break
		}
		extra += i
		new_topline = top
		top -= 1
		bot += 1
	}
	if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		scroll_cursor_halfway(wp, false, false)
	} else {
		if new_topline < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ || always != 0 {
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = new_topline
		}
		top3 := new_topline
		cur3 := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
		if top3 > cur3 {
			top3 = cur3
		}
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = top3
		(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = win_get_fill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
		if (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ > 0 && C.longlong(extra) > off {
			(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ -= extra - C.int(off)
			if (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ < 0 {
				(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = 0
			}
		}
		check_topfill(wp, false)
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != old_topline {
			reset_skipcol_o(wp)
		} else if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
			validate_virtcol(wp)
			if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ >= (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
				reset_skipcol_o(wp)
			}
		}
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != old_topline || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != old_skipcol || (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ != old_topfill {
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
		}
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_TOPLINE_O
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	}
}

@(export)
set_empty_rows :: proc "c" (wp: rawptr, used: C.int) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^ = 0
	if used == 0 {
		(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ = 0
	} else {
		(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - used
		wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		ml := (^Memline_O)(uintptr(wbuf) + 8)
		if (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ <= ml.line_count {
			(^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^ = win_get_fill(wp, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^)
			if (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ > (^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^ {
				(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ -= (^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^
			} else {
				(^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^ = (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
				(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ = 0
			}
		}
	}
}

@(export)
scroll_cursor_bot :: proc "c" (wp: rawptr, min_scroll: C.int, set_topbot: bool) {
	context = runtime.default_context()
	loff := lineoff_T{0, 0, 0}
	boff := lineoff_T{0, 0, 0}
	old_topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	old_skipcol := (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
	old_topfill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
	old_botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
	old_valid := (^C.int)(uintptr(wp) + W_VALID_OFF)^
	old_empty_rows := (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
	cln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	do_sms := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ != 0
	if set_topbot {
		used: C.int = 0
		cln_last := cln
		hasFolding(wp, cln, nil, &cln_last)
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = cln_last + 1
		loff.lnum = cln_last + 1
		loff.fill = 0
		for {
			topline_back_winheight_full_o(wp, &loff, 0)
			if loff.height == MAXCOL {
				break
			}
			wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
			ml := (^Memline_O)(uintptr(wbuf) + 8)
			if used + loff.height > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
				if do_sms {
					if used < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
						plines_offset := used + loff.height - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
						used = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
						(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = loff.fill
						(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = loff.lnum
						(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = skipcol_from_plines_o(wp, plines_offset)
					}
				}
				break
			}
			(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = loff.fill
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = loff.lnum
			used += loff.height
		}
		set_empty_rows(wp, used)
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= C.int(VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
		if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != old_topline || (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ != old_topfill || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != old_skipcol || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != 0 {
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O)
			if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != old_skipcol {
				redraw_later(wp, UPD_NOT_VALID_O)
			} else {
				reset_skipcol_o(wp)
			}
		}
	} else {
		validate_botline_win(wp)
	}
	used := plines_win_nofill(wp, cln, true)
	scrolled: C.int = 0
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if cln >= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
		scrolled = used
		if cln == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
			scrolled -= (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
		}
		if do_sms {
			top_plines := plines_win_nofill(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, false)
			width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off(wp)
			if width1 > 0 {
				width2 := width1 + win_col_off2(wp)
				skip_lines: C.int = 0
				if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > width1 {
					skip_lines += ((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ - width1) / width2 + 1
				} else if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 {
					skip_lines = 1
				}
				top_plines -= skip_lines
				if top_plines > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
					scrolled += top_plines - (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
				}
			}
		}
	}
	if !hasFolding(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^, &loff.lnum, &boff.lnum) {
		loff.lnum = cln
		boff.lnum = cln
	}
	loff.fill = 0
	boff.fill = 0
	fill_below_window := win_get_fill(wp, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^) - (^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^
	extra: C.int = 0
	so := get_scrolloff_value(wp)
	for loff.lnum > 1 {
		cond_a := scrolled <= 0 || scrolled >= min_scroll
		cond_b := false
		md := mouse_dragging_g
		thresh := so
		if md > 0 {
			thresh = C.longlong(md) - 1
		}
		if cond_a && C.longlong(extra) >= thresh {
			cond_b = true
		}
		cond_c := boff.lnum + 1 > ml.line_count
		cond_d := loff.lnum <= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
		cond_e := false
		if loff.lnum < (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
			cond_e = true
		}
		if loff.lnum == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && loff.fill >= fill_below_window {
			cond_e = true
		}
		stop_now := false
		if cond_a && cond_b {
			stop_now = true
		}
		if cond_c {
			stop_now = true
		}
		if stop_now && cond_d && cond_e {
			break
		}
		topline_back_o(wp, &loff)
		if loff.height == MAXCOL {
			used = MAXCOL
		} else {
			used += loff.height
		}
		if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			break
		}
		if loff.lnum >= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
			below_ok := loff.lnum > (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
			if loff.lnum == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && loff.fill <= fill_below_window {
				below_ok = true
			}
			if below_ok {
				scrolled += loff.height
				if loff.lnum == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && loff.fill == 0 {
					scrolled -= (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
				}
			}
		}
		if boff.lnum < ml.line_count {
			botline_forw_o(wp, &boff)
			if boff.height == MAXCOL {
				libc.abort()
			}
			used += boff.height
			if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
				break
			}
			need_extra := false
			if C.longlong(extra) < thresh {
				need_extra = true
			}
			if scrolled < min_scroll {
				need_extra = true
			}
			if need_extra {
				extra += boff.height
				hit_below := false
				if boff.lnum >= (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
					hit_below = true
				}
				if boff.lnum + 1 == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && boff.fill > (^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^ {
					hit_below = true
				}
				if hit_below {
					scrolled += boff.height
					if boff.lnum == (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ && boff.fill == 0 {
						scrolled -= (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^
					}
				}
			}
		}
	}
	line_count: C.int
	if scrolled <= 0 {
		line_count = 0
	} else if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		line_count = used
	} else {
		line_count = 0
		boff.fill = (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		boff.lnum = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 1
		i: C.int = 0
		for i < scrolled && boff.lnum < (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
			botline_forw_o(wp, &boff)
			i += boff.height
			line_count += 1
		}
		if i < scrolled {
			line_count = 9999
		}
	}
	eof_pressure := scrolloffpad_eof_pressure_o(wp, cln, so)
	if C.longlong(line_count) >= C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) && line_count > min_scroll {
		scroll_cursor_halfway(wp, eof_pressure, true)
	} else if line_count > 0 {
		if do_sms {
			scrollup(wp, scrolled, true)
		} else {
			scrollup(wp, line_count, true)
		}
	}
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == old_topline && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == old_skipcol && set_topbot {
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = old_botline
		(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ = old_empty_rows
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ = old_valid
	}
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_TOPLINE_O
	(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
	if set_topbot {
		cursor_correct_sms_o(wp)
	}
}

@(export)
scroll_cursor_halfway :: proc "c" (wp: rawptr, atend: bool, prefer_above: bool) {
	context = runtime.default_context()
	old_topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	loff := lineoff_T{(^C.int)(uintptr(wp) + W_CURSOR_OFF)^, 0, 0}
	boff := lineoff_T{(^C.int)(uintptr(wp) + W_CURSOR_OFF)^, 0, 0}
	top_tmp := loff.lnum
	bot_tmp := boff.lnum
	hasFolding(wp, top_tmp, &top_tmp, &bot_tmp)
	loff.lnum = top_tmp
	boff.lnum = bot_tmp
	used := plines_win_nofill(wp, loff.lnum, true)
	loff.fill = 0
	boff.fill = 0
	topline := loff.lnum
	skipcol: C.int = 0
	want_height: C.int = 0
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	do_sms := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 && (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ != 0
	if do_sms {
		if atend {
			want_height = ((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - used) / 2
			used = 0
		} else {
			want_height = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
		}
	}
	topfill: C.int = 0
	for topline > 1 {
		if do_sms {
			topline_back_winheight_full_o(wp, &loff, 0)
			if loff.height == MAXCOL {
				break
			}
			used += loff.height
			if !atend && boff.lnum < ml.line_count {
				botline_forw_o(wp, &boff)
				used += boff.height
			}
			if used > want_height {
				if used - loff.height < want_height {
					topline = loff.lnum
					topfill = loff.fill
					skipcol = skipcol_from_plines_o(wp, used - want_height)
				}
				break
			}
			topline = loff.lnum
			topfill = loff.fill
			continue
		}
		done := false
		above: C.int = 0
		below: C.int = 0
		for round: C.int = 1; round <= 2; round += 1 {
			take_below := false
			if prefer_above {
				if round == 2 && below < above {
					take_below = true
				}
			} else {
				if round == 1 && below <= above {
					take_below = true
				}
			}
			if take_below {
				if boff.lnum < ml.line_count {
					botline_forw_o(wp, &boff)
					used += boff.height
					if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
						done = true
						break
					}
					below += boff.height
				} else {
					below += 1
					if atend {
						used += 1
					}
				}
			}
			take_above := false
			if prefer_above {
				if round == 1 && below >= above {
					take_above = true
				}
			} else {
				if round == 1 && below > above {
					take_above = true
				}
			}
			if take_above {
				topline_back_o(wp, &loff)
				if loff.height == MAXCOL {
					used = MAXCOL
				} else {
					used += loff.height
				}
				if used > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
					done = true
					break
				}
				above += loff.height
				topline = loff.lnum
				topfill = loff.fill
			}
		}
		if done {
			break
		}
	}
	wt := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	r := hasFolding(wp, topline, &wt, nil)
	(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = wt
	if !r && (wt != topline || skipcol != 0 || (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ != 0) {
		(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = topline
		if skipcol != 0 {
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = skipcol
			redraw_later(wp, UPD_NOT_VALID_O)
		} else if do_sms {
			reset_skipcol_o(wp)
		}
	}
	(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = topfill
	if old_topline > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ + (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		(^bool)(uintptr(wp) + W_BOTFILL_OFF)^ = false
	}
	check_topfill(wp, false)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_CROW_O | VALID_BOTLINE_O | VALID_BOTLINE_AP_O)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_TOPLINE_O
}

@(export)
cursor_correct :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	above_wanted := get_scrolloff_value(wp)
	below_wanted := get_scrolloff_value(wp)
	if mouse_dragging_g > 0 {
		above_wanted = C.longlong(mouse_dragging_g) - 1
		below_wanted = C.longlong(mouse_dragging_g) - 1
	}
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == 1 {
		above_wanted = 0
		max_off := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2
		if below_wanted > C.longlong(max_off) {
			below_wanted = C.longlong(max_off)
		}
	}
	validate_botline_win(wp)
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(wbuf) + 8)
	if (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ == ml.line_count + 1 && mouse_dragging_g == 0 {
		if !use_scrolloffpad_o(wp) {
			below_wanted = 0
		}
		max_off := ((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1) / 2
		if above_wanted > C.longlong(max_off) {
			above_wanted = C.longlong(max_off)
		}
	}
	cln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	if C.longlong(cln) >= C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) + above_wanted && C.longlong(cln) < C.longlong((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^) - below_wanted && !win_lines_concealed_r(wp) {
		return
	}
	if (^C.int)(uintptr(wp) + W_P_SMS_OFF_O)^ != 0 && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 {
		if (^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^ == (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			reset_skipcol_o(wp)
			return
		}
	}
	topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1
	above := C.longlong((^C.int)(uintptr(wp) + W_TOPFILL_OFF)^)
	below := C.longlong((^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF_O)^)
	for topline < botline {
		if above >= above_wanted && below >= below_wanted {
			break
		}
		take_below := false
		if below < below_wanted {
			if below <= above {
				take_below = true
			}
			if above >= above_wanted {
				take_below = true
			}
		}
		if take_below {
			below += C.longlong(plines_win_full(wp, botline, nil, nil, true, true))
			bot2 := botline
			hasFolding(wp, bot2, &bot2, nil)
			botline = bot2
			botline -= 1
		}
		take_above := false
		if above < above_wanted {
			if above < below {
				take_above = true
			}
			if below >= below_wanted {
				take_above = true
			}
		}
		if take_above {
			above += C.longlong(plines_win_nofill(wp, topline, true))
			top2 := topline
			hasFolding(wp, top2, nil, &top2)
			topline = top2
			if topline < botline {
				above += C.longlong(win_get_fill(wp, topline + 1))
			}
			topline += 1
		}
	}
	if topline == botline || botline == 0 {
		(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = topline
	} else if topline > botline {
		(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = botline
	} else {
		if cln < topline && (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > 1 {
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = topline
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_CHEIGHT_O | VALID_CROW_O)
		}
		if cln > botline && (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ <= ml.line_count {
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = botline
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_CHEIGHT_O | VALID_CROW_O)
		}
	}
	check_cursor_moved(wp)
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_TOPLINE_O
	(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
}

get_scroll_overlap_o :: proc "c" (dir: C.int) -> C.int {
	context = runtime.default_context()
	loff := lineoff_T{0, 0, 0}
	min_height := (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ - 2
	validate_botline_win(curwin)
	if (dir == BACKWARD_O && (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ == 1) || (dir == FORWARD_O && (^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^ > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^) {
		return min_height + 2
	}
	if dir == FORWARD_O {
		loff.lnum = (^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^
	} else {
		loff.lnum = (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ - 1
	}
	back_one := 0
	if dir == BACKWARD_O {
		back_one = 1
	}
	loff.fill = win_get_fill(curwin, loff.lnum + C.int(back_one))
	if dir == FORWARD_O {
		loff.fill -= (^C.int)(uintptr(curwin) + W_FILLER_ROWS_OFF_O)^
	} else {
		loff.fill -= (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^
	}
	if loff.fill > 0 {
		loff.height = 1
	} else {
		loff.height = plines_win_nofill(curwin, loff.lnum, true)
	}
	h1 := loff.height
	if h1 > min_height {
		return min_height + 2
	}
	if dir == FORWARD_O {
		topline_back_o(curwin, &loff)
	} else {
		botline_forw_o(curwin, &loff)
	}
	h2 := loff.height
	if h2 == MAXCOL || h2 + h1 > min_height {
		return min_height + 2
	}
	if dir == FORWARD_O {
		topline_back_o(curwin, &loff)
	} else {
		botline_forw_o(curwin, &loff)
	}
	h3 := loff.height
	if h3 == MAXCOL || h3 + h2 > min_height {
		return min_height + 2
	}
	if dir == FORWARD_O {
		topline_back_o(curwin, &loff)
	} else {
		botline_forw_o(curwin, &loff)
	}
	h4 := loff.height
	if h4 == MAXCOL || h4 + h3 + h2 > min_height || h3 + h2 + h1 > min_height {
		return min_height + 1
	} else {
		return min_height
	}
}

scroll_with_sms_o :: proc "c" (dir: C.int, count_in: C.int, curscount: ^C.int) -> bool {
	context = runtime.default_context()
	count := count_in
	prev_sms := (^C.int)(uintptr(curwin) + W_P_SMS_OFF_O)^
	prev_skipcol := (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^
	prev_topline := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
	prev_topfill := (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^
	(^C.int)(uintptr(curwin) + W_P_SMS_OFF_O)^ = 1
	up := C.int(0)
	if dir == FORWARD_O {
		up = 1
	}
	scroll_redraw(up, count)
	if prev_sms == 0 && (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ > 0 {
		fixdir := dir
		thresh: C.int = 0
		if dir == BACKWARD_O {
			thresh = 1
		}
		if abs((^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ - prev_topline) > thresh {
			fixdir = dir * -1
		}
		width1 := (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - win_col_off(curwin)
		width2 := width1 + win_col_off2(curwin)
		count = 1 + ((^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ - width1 - 1) / width2
		if fixdir == FORWARD_O {
			count = 1 + (linetabsize_eol(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^) - (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ - width1 + width2 - 1) / width2
		}
		up2 := C.int(0)
		if fixdir == FORWARD_O {
			up2 = 1
		}
		scroll_redraw(up2, count)
		if fixdir == dir {
			curscount^ += count
		} else {
			curscount^ -= count
		}
	}
	(^C.int)(uintptr(curwin) + W_P_SMS_OFF_O)^ = prev_sms
	return (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ != prev_topline || (^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ != prev_topfill || (^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ != prev_skipcol
}

@(export)
pagescroll :: proc "c" (dir: C.int, count_in: C.int, half: bool) -> C.int {
	context = runtime.default_context()
	count := count_in
	did_move := false
	wbuf := (^rawptr)(uintptr(curbuf) + W_BUFFER_OFF)^
	_ = wbuf
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	buflen := ml.line_count
	prev_col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	prev_curswant := (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
	prev_lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	oa: [88]u8
	ca: [88]u8
	(^rawptr)(&ca[0])^ = rawptr(&oa[0])
	if half {
		if count != 0 {
			scr := (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^
			if count < scr {
				scr = count
			}
			(^C.longlong)(uintptr(curwin) + W_P_SCR_OFF)^ = C.longlong(scr)
		}
		count = (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^
		if C.longlong(count) > (^C.longlong)(uintptr(curwin) + W_P_SCR_OFF)^ {
			count = C.int((^C.longlong)(uintptr(curwin) + W_P_SCR_OFF)^)
		}
		curscount := count
		adj_eob := false
		if dir == FORWARD_O {
			if (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ + (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ + count > buflen {
				adj_eob = true
			}
			if win_lines_concealed_r(curwin) {
				adj_eob = true
			}
		}
		if adj_eob {
			n := plines_correct_topline(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^, nil, false, nil)
			if n - count < (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ && (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ < buflen {
				n += plines_m_win(curwin, (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ + 1, buflen, (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ + count)
			}
			if n < (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^ + count {
				count = n - (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^
			}
		}
		if count > 0 {
			did_move = scroll_with_sms_o(dir, count, &curscount)
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = prev_lnum
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = prev_col
			(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = prev_curswant
		}
		if (^C.int)(uintptr(curwin) + W_P_WRAP_OFF)^ != 0 {
			nv_screengo_e(rawptr(&oa[0]), dir, curscount, true)
		} else if dir == FORWARD_O {
			cursor_down_inner_r(curwin, curscount, true)
		} else {
			cursor_up_inner_r(curwin, C.long(curscount), true)
		}
	} else {
		per := get_scroll_overlap_o(dir)
		if firstwin == lastwin_g && p_window_g > 0 && C.longlong(p_window_g) < C.longlong(Rows) - 1 {
			m := C.longlong(1)
			if p_window_g - 2 > m {
				m = p_window_g - 2
			}
			per = C.int(m)
		}
		count *= per
		did_move = scroll_with_sms_o(dir, count, &count)
		if did_move {
			validate_botline_win(curwin)
			lnum := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
			if dir != FORWARD_O {
				lnum = (^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^ - 1
			}
			if lnum < 1 {
				lnum = 1
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
		}
	}
	if get_scrolloff_value(curwin) > 0 {
		cursor_correct(curwin)
	}
	foldAdjustCursor(curwin)
	if !did_move {
		if prev_col != (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ {
			did_move = true
		}
		if prev_lnum != (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
			did_move = true
		}
	}
	if !did_move {
		beep_flush_r()
	} else if (^C.int)(uintptr(curwin) + W_P_SMS_OFF_O)^ == 0 {
		beginline(BL_SOL | BL_FIX)
	} else if p_sol_g != 0 {
		nv_g_home_m_cmd_e(rawptr(&ca[0]))
	}
	if did_move {
		return OK
	}
	return FAIL
}

@(export)
do_check_cursorbind :: proc "c" () {
	context = runtime.default_context()
	if curwin == prev_curwin_mv_g && pos_equal_mv_o((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^, prev_cursor_mv_g) {
		return
	}
	prev_curwin_mv_g = curwin
	prev_cursor_mv_g = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	line := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	coladd := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^
	curswant := (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
	set_curswant := (^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^
	old_curwin := curwin
	old_curbuf := curbuf
	old_VIsual_select := VIsual_select_g
	old_VIsual_active := VIsual_active
	VIsual_select_g = false
	VIsual_active = false
	wp := firstwin
	for wp != nil {
		curwin = wp
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
		if curwin != old_curwin && (^C.int)(uintptr(curwin) + W_P_CRB_OFF)^ != 0 {
			if (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0 {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = diff_get_corresponding_line_e(old_curbuf, line)
			} else {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = coladd
			(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = curswant
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = set_curswant
			restart_edit_save := restart_edit
			restart_edit = 1
			check_cursor(curwin)
			if (^C.int)(uintptr(curwin) + W_P_SCB_OFF)^ == 0 {
				validate_cursor(curwin)
			}
			restart_edit = restart_edit_save
			mb_adjust_cursor_r()
			redraw_later(curwin, UPD_VALID_O)
			if (^C.int)(uintptr(curwin) + W_P_SCB_OFF)^ == 0 {
				update_topline(curwin)
			}
			(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	VIsual_select_g = old_VIsual_select
	VIsual_active = old_VIsual_active
	curwin = old_curwin
	curbuf = old_curbuf
}
