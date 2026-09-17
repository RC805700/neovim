// drawscreen.odin — port of src/nvim/drawscreen.c (screen redraw top level)
package main

import C "core:c"
import "core:c/libc"

// ── Batch 1: trivial leaves ─────────────────────────────────────────────────

MODE_VISUAL_O :: 0x02
MIN_COLUMNS_O :: 12

foreign _ {
	@(link_name = "do_redraw")
	do_redraw_g: bool
}

// Redraw when size/validity demands (pure option/global reads).
@(export)
check_screensize :: proc "c"() {
	// Limit Rows and Columns (room for one window + command line).
	r := Rows
	if r < C.int(min_rows_for_all_tabpages()) {
		r = C.int(min_rows_for_all_tabpages())
	}
	if r > 1000 {
		r = 1000
	}
	Rows = r
	c := Columns
	if c < MIN_COLUMNS_O {
		c = MIN_COLUMNS_O
	}
	if c > 10000 {
		c = 10000
	}
	Columns = c
}

// True when redrawing should currently be done.
@(export)
redrawing :: proc "c"() -> bool {
	return RedrawingDisabled == 0 &&
		!(p_lz_g != 0 && char_avail_r() && !KeyTyped && !do_redraw_g)
}

// Cursor line needs redraw for 'concealcursor'.
@(export)
conceal_check_cursor_line :: proc "c"() {
	should_conceal := conceal_cursor_line(curwin)
	if (^C.int)(uintptr(curwin) + W_P_COLE_OFF)^ <= 0 ||
		conceal_cursor_used_f == should_conceal {
		return
	}

	redrawWinline(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)

	// Concealed line visibility toggled.
	if decor_conceal_line_r(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, true) {
		changed_window_setting_r(curwin)
	}
	// Recompute cursor column (e.g. starting Visual without concealing).
	curs_columns_r(curwin, 1)
}

// File-private: conceal visibility cache (drawscreen.c:137).
@(private="file")
conceal_cursor_used_f: bool = false

// Start 'hlsearch' highlighting.
@(export)
start_search_hl :: proc "c"() {
	if p_hls == 0 || no_hlsearch {
		return
	}

	end_search_hl() // in case it wasn't called before
	last_pat_prog(transmute(^Regmmatch_T)(&screen_search_hl_u8))
	// Time limit from 'redrawtime'.
	(^proftime_T)(uintptr(transmute(rawptr)(&screen_search_hl_u8)) + 224)^ =
		profile_setlimit_r(p_rdt_g)
}

// Clean up for 'hlsearch' highlighting.
@(export)
end_search_hl :: proc "c"() {
	// regprog is first in regmmatch_T = first in match_T.
	regprog := (^rawptr)(transmute(rawptr)(&screen_search_hl_u8))^
	if regprog == nil {
		return
	}

	vim_regfree(regprog)
	(^rawptr)(transmute(rawptr)(&screen_search_hl_u8))^ = nil
}

// Cursor to its position in the current window.
@(export)
setcursor :: proc "c"() {
	setcursor_mayforce(curwin, false)
}

// Cursor to position, optionally forcing outside redraw.
@(export)
setcursor_mayforce :: proc "c"(wp: rawptr, force: bool) {
	if force || redrawing() {
		validate_cursor_r(wp)

		row := (^C.int)(uintptr(wp) + W_WROW_OFF)^
		col := (^C.int)(uintptr(wp) + W_WCOL_OFF)^
		if (^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 {
			// 'rightleft' on double-wide char: use leftmost column.
			cursor := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^,
				(^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
			cursor = (^u8)(uintptr(cursor) + uintptr((^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^))
			cells := utf_ptr2cells_r(cstring(cursor))
			printable := vim_isprintc(utf_ptr2char(cstring(cursor)))
			dec := 1
			if cells == 2 && printable {
				dec = 2
			}
			col = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - (^C.int)(uintptr(wp) + W_WCOL_OFF)^ - C.int(dec)
		}

		grid := grid_adjust((^GridView)(uintptr(wp) + W_GRID_OFF), &row, &col)
		if grid != nil {
			ui_grid_cursor_goto_r(grid.handle, row, col)
		}
	}
}

// Whether conceal applies on the cursor line for wp's mode.
@(export)
conceal_cursor_line :: proc "c"(wp: rawptr) -> bool {
	c: u8
	if (([^]u8)((^rawptr)(uintptr(wp) + W_P_COCU_OFF)^))[0] == 0 { // NUL
		return false
	}
	if get_real_state_r() & MODE_VISUAL_O != 0 {
		c = 'v'
	} else if State & MODE_INSERT != 0 {
		c = 'i'
	} else if State & MODE_NORMAL_O != 0 {
		c = 'n'
	} else if State & MODE_CMDLINE_O != 0 {
		c = 'c'
	} else {
		return false
	}
	return vim_strchr_c(transmute(^u8)((^rawptr)(uintptr(wp) + W_P_COCU_OFF)^), C.int(c)) != nil
}

// Whether cursorline draws in a special way (both lines need redraw on move).
@(export)
win_cursorline_standout :: proc "c"(wp: rawptr) -> bool {
	return (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 ||
		(wp == curwin && (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ > 0 &&
			!conceal_cursor_line(wp))
}

// ── Batch 2a: redraw_later invalidation family ────────────────────────────────

W_REDRAW_TOP_OFF :: 700 // w_redraw_top (linenr_T)
W_REDRAW_BOT_OFF :: 704 // w_redraw_bot (linenr_T)
W_GRID_VALID_OFF :: 10512 // w_grid_alloc.valid (bool abs: 10456+56)

foreign _ {
	@(link_name = "redraw_not_allowed")
	redraw_not_allowed_g: bool
}

// Redraw window later; must_redraw tracks the max over all windows.
@(export)
redraw_later :: proc "c"(wp: rawptr, type_: C.int) {
	// curwin may be NULL when exiting; nothing to mark then.
	if wp == nil {
		return
	}
	if !exiting && !redraw_not_allowed_g &&
		(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ < type_ {
		(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = type_
		if type_ >= UPD_NOT_VALID {
			(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
		}
		must_redraw = max(must_redraw, type_)
	}
}

// Mark all windows in the current tabpage for later redraw.
@(export)
redraw_all_later :: proc "c"(type_: C.int) {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		redraw_later(wp, type_)
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	// Needed when switching tabs.
	set_must_redraw(type_)
}

// Set must_redraw unless already higher or currently not allowed.
@(export)
set_must_redraw :: proc "c"(type_: C.int) {
	if !redraw_not_allowed_g {
		must_redraw = max(must_redraw, type_)
	}
}

// Invalidate highlights in all windows (grids need realloc).
@(export)
screen_invalidate_highlights :: proc "c"() {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		redraw_later(wp, UPD_NOT_VALID)
		(^bool)(uintptr(wp) + W_GRID_VALID_OFF)^ = false
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Mark all windows editing the current buffer for later update.
@(export)
redraw_curbuf_later :: proc "c"(type_: C.int) {
	redraw_buf_later(curbuf, type_)
}

@(export)
redraw_buf_later :: proc "c"(buf: rawptr, type_: C.int) {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
			redraw_later(wp, type_)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

@(export)
redraw_buf_line_later :: proc "c"(buf: rawptr, line: C.int, force: bool) {
	line_count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
			redrawWinline(wp, min(line, line_count))
			if force && line > line_count {
				(^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ = line
			}
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

@(export)
redraw_win_range_later :: proc "c"(wp: rawptr, first: C.int, last: C.int) {
	if last >= (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ &&
		first < (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ {
		if (^C.int)(uintptr(wp) + W_REDRAW_TOP_OFF)^ == 0 ||
			(^C.int)(uintptr(wp) + W_REDRAW_TOP_OFF)^ > first {
			(^C.int)(uintptr(wp) + W_REDRAW_TOP_OFF)^ = first
		}
		if (^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ == 0 ||
			(^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ < last {
			(^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ = last
		}
		redraw_later(wp, UPD_VALID_O)
	}
}

// Changed something at buffer line lnum: redraw it (plus maybe more).
@(export)
redrawWinline :: proc "c"(wp: rawptr, lnum: C.int) {
	redraw_win_range_later(wp, lnum, lnum)
}
