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

// ── Batch 2b: buf_range/status family + cursorline ────────────────────────────

foreign _ {
	@(link_name = "win_check_ns_hl")
	win_check_ns_hl_r :: proc "c"(wp: rawptr) -> bool ---
	@(link_name = "win_redr_winbar")
	win_redr_winbar_r :: proc "c"(wp: rawptr) ---
	@(link_name = "win_redr_status")
	win_redr_status_r :: proc "c"(wp: rawptr) ---
	@(link_name = "draw_tabline")
	draw_tabline_r :: proc "c"() ---
}

@(export)
redraw_buf_range_later :: proc "c"(buf: rawptr, first: C.int, last: C.int) {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
			redraw_win_range_later(wp, first, last)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Status bars for buffer buf need update.
@(export)
redraw_buf_status_later :: proc "c"(buf: rawptr) {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
			((^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0 ||
				(wp == curwin && global_stl_height() != 0) ||
				(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ != 0) {
			(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
			set_must_redraw(UPD_VALID_O)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Mark all status lines and window bars for redraw; used after first :cd.
@(export)
status_redraw_all :: proc "c"() {
	is_stl_global := global_stl_height() != 0
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if ((!is_stl_global && (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0) ||
			wp == curwin ||
			(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ != 0) {
			(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
			redraw_later(wp, UPD_VALID_O)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Marks all status lines and window bars of the current buffer for redraw.
@(export)
status_redraw_curbuf :: proc "c"() {
	status_redraw_buf(curbuf)
}

// Marks all status lines and window bars of the given buffer for redraw.
@(export)
status_redraw_buf :: proc "c"(buf: rawptr) {
	is_stl_global := global_stl_height() != 0
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
			((!is_stl_global && (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0) ||
				(is_stl_global && wp == curwin) ||
				(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ != 0) {
			(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
			redraw_later(wp, UPD_VALID_O)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	// Redraw the ruler if in the command line and not marked above.
	if p_ru_g != 0 && (^C.int)(uintptr(curwin) + W_STATUS_HEIGHT_OFF)^ == 0 &&
		!(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ {
		redraw_cmdline_g = true
		redraw_later(curwin, UPD_VALID_O)
	}
}

// Redraw all status lines that need to be redrawn.
@(export)
redraw_statuslines :: proc "c"() {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ {
			win_check_ns_hl_r(wp)
			win_redr_winbar_r(wp)
			win_redr_status_r(wp)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}

	win_check_ns_hl_r(nil)
	if redraw_tabline_opt {
		draw_tabline_r()
	}

	if need_maketitle_opt {
		maketitle()
	}
}

// Redraw all status lines at the bottom of frame frp.
@(export)
win_redraw_last_status :: proc "c"(frp_in: rawptr) {
	frp := frp_in
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		win := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
		(^bool)(uintptr(win) + W_REDR_STATUS_OFF)^ = true
	} else if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			win_redraw_last_status(child)
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
	} else {
		// FR_COL: only the last child has the bottom status line.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for (^rawptr)(uintptr(child) + FR_NEXT_OFF)^ != nil {
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
		win_redraw_last_status(child)
	}
}

// Update w_cursorline, folding the cursor line into a closed fold's start.
@(export)
win_update_cursorline :: proc "c"(wp: rawptr, foldinfo: ^Foldinfo_T) {
	if win_cursorline_standout(wp) {
		(^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ =
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	} else {
		(^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ = 0
	}
	if (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 {
		// Make sure the cursorline on a closed fold is redrawn.
		foldinfo^ = fold_info(wp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
		if foldinfo.fi_level != 0 && foldinfo.fi_lines > 0 {
			(^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ = foldinfo.fi_lnum
		}
	}
}

// ── Batch 3: small leaves ─────────────────────────────────────────────────────

COL_RULER_O :: 17 // columns needed by standard ruler (drawscreen.c:1135)
SHOWCMD_COLS_O :: 10 // columns needed by shown command (normal_defs.h:75)
VV_ECHOSPACE_O :: 87 // v:echospace (eval_defs.h, 0-based count)
W_P_NUW_OFF :: 984 // w_p_nuw (OptInt i64; abs 816+168)
K_MTMETA_SIGNTEXT_O :: 3 // marktree_defs.h MetaIndex

foreign _ {
	@(link_name = "redraw_mode")
	redraw_mode_g: bool
	@(link_name = "ru_col")
	ru_col_g: C.int
	@(link_name = "p_sc")
	p_sc_g: C.int
	@(link_name = "p_sloc")
	p_sloc_g: ^u8
}

// Mark title/icon for redraw if either uses statusline format.
@(export)
redraw_custom_title_later :: proc "c"() -> bool {
	if (p_icon_g != 0 && (stl_syntax_g & STL_IN_ICON_O) != 0) ||
		(p_title_g != 0 && (stl_syntax_g & STL_IN_TITLE_O) != 0) {
		need_maketitle_opt = true
		return true
	}
	return false
}

// True when postponing the mode message: not redrawing or inside a mapping.
@(export)
skip_showmode :: proc "c"() -> bool {
	// char_avail() costs a bit; redrawing() may also call it.
	if global_busy != 0 || msg_silent != 0 || !redrawing() ||
		(char_avail_r() && !KeyTyped) {
		redraw_mode_g = true // show mode later
		return true
	}
	return false
}

// Compute sc_col/ru_col (showcmd/ruler positions) and set v:echospace.
@(export)
comp_col :: proc "c"() {
	last_has_status := last_stl_height(false) > 0

	sc_col = 0
	ru_col_g = 0
	if p_ru_g != 0 {
		if ru_wid_g != 0 {
			ru_col_g = ru_wid_g + 1
		} else {
			ru_col_g = COL_RULER_O + 1
		}
		// No last status line: adjust sc_col.
		if !last_has_status {
			sc_col = ru_col_g
		}
	}
	if p_sc_g != 0 && p_sloc_g^ == 'l' {
		sc_col += SHOWCMD_COLS_O
		if p_ru_g == 0 || last_has_status { // no need for separating space
			sc_col += 1
		}
	}
	sc_col = Columns - sc_col
	ru_col_g = Columns - ru_col_g
	if sc_col <= 0 { // screen too narrow, will become a mess
		sc_col = 1
	}
	if ru_col_g <= 0 {
		ru_col_g = 1
	}
	set_vim_var_nr(VV_ECHOSPACE_O, i64(sc_col - 1))
}

// Scroll window lines via the grid (used outside update_screen, e.g. curs_columns).
@(export)
win_scroll_lines :: proc "c"(wp: rawptr, row: C.int, line_count: C.int) {
	if !redrawing() || line_count == 0 {
		return
	}

	col: C.int = 0
	row_off: C.int = 0
	grid := grid_adjust((^GridView)(uintptr(wp) + W_GRID_OFF), &row_off, &col)

	checked_width := min(grid.cols - col, (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^)
	checked_height := min(grid.rows - row_off, (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^)

	// No lines moved: just draw over the entire area.
	if row + abs(line_count) >= checked_height {
		return
	}

	if line_count < 0 {
		grid_del_lines(grid, row + row_off, -line_count,
			checked_height + row_off, col, checked_width)
	} else {
		grid_ins_lines(grid, row + row_off, line_count,
			checked_height + row_off, col, checked_width)
	}
}

// Clear lines near the window end; mark unused lines with c1.
@(export)
win_draw_end :: proc "c"(wp: rawptr, c1: u32, draw_margin: bool, startrow: C.int, endrow: C.int, hl: C.int) {
	view_width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^
	fdc := compute_foldcolumn(wp, 0)
	scwidth := (^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^

	for row := startrow; row < endrow; row += 1 {
		grid_line_start((^GridView)(uintptr(wp) + W_GRID_OFF), row)

		n: C.int = 0
		if draw_margin {
			// Fold column.
			if fdc > 0 {
				n = grid_line_fill(n, min(view_width, n + fdc),
					32, win_hl_attr_o(wp, HLF_FC_O)) // schar_from_ascii(' ')
			}

			// Sign column.
			if scwidth > 0 {
				n = grid_line_fill(n, min(view_width, n + scwidth * SIGN_WIDTH_O),
					32, win_hl_attr_o(wp, HLF_SC_O))
			}

			// Number column.
			if ((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
				(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0) &&
				vim_strchr_c(p_cpo, CPO_NUMCOL_O) == nil {
				width := number_width(wp) + 1
				n = grid_line_fill(n, min(view_width, n + width),
					32, win_hl_attr_o(wp, HLF_N_O))
			}
		}

		attr := win_hl_attr_o(wp, hl)

		if n < view_width {
			grid_line_put_schar(n, c1, attr)
			n += 1
		}

		grid_line_clear_end(n, view_width, win_bg_attr_r(wp), attr)

		if (^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 {
			grid_line_mirror(view_width)
		}
		grid_line_flush()
	}
}

// Width of the foldcolumn: 'foldcolumn' limited by space minus col.
@(export)
compute_foldcolumn :: proc "c"(wp: rawptr, col: C.int) -> C.int {
	fdc := win_fdccol_count(wp)
	wmw: C.int
	if wp == curwin && p_wmw_opt == 0 {
		wmw = 1
	} else {
		wmw = C.int(p_wmw_opt)
	}
	n := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - (col + wmw)

	return min(fdc, n)
}

// Width of the 'number'/'relativenumber' column (caller checks nu/rnu set).
@(export)
number_width :: proc "c"(wp: rawptr) -> C.int {	lnum: C.int
	if (^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 &&
		(^C.int)(uintptr(wp) + W_P_NU_OFF)^ == 0 {
		// Cursor line shows "0".
		lnum = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	} else {
		// Cursor line shows absolute line number.
		lnum = (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^
	}

	if lnum == (^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ {
		return (^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^
	}
	(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ = lnum

	// Reset for 'statuscolumn'.
	if (([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF)^))[0] != 0 { // NUL
		(^C.int)(uintptr(wp) + W_STATUSCOL_LINE_COUNT_OFF)^ = 0 // re-estimate width
		nuw := C.int((^C.longlong)(uintptr(wp) + W_P_NUW_OFF)^)
		w: C.int = 0
		if (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
			(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
			w = nuw
		}
		(^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^ = w
		return w
	}

	n: C.int = 0
	for {
		lnum /= 10
		n += 1
		if lnum <= 0 {
			break
		}
	}

	// 'numberwidth' gives the minimal width plus one.
	nuw := C.int((^C.longlong)(uintptr(wp) + W_P_NUW_OFF)^)
	if n < nuw - 1 {
		n = nuw - 1
	}

	// 'signcolumn' number: minimal width 2 when a sign shows.
	if n < 2 && buf_meta_total_o((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, K_MTMETA_SIGNTEXT_O) != 0 &&
		(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ == SCL_NUM_E {
		n = 2
	}

	(^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^ = n
	return n
}

// ── Batch 4: cursor info + mode clear ─────────────────────────────────────────

W_STL_CURSOR_OFF :: 720 // w_stl_cursor (pos_T 12B: lnum@0/col@4/coladd@8)
W_STL_VIRTCOL_OFF :: 732 // w_stl_virtcol (colnr_T)
W_STL_TOPLINE_OFF :: 736 // w_stl_topline (linenr_T)
W_STL_LINE_COUNT_OFF :: 740 // w_stl_line_count (linenr_T)
W_STL_TOPFILL_OFF :: 744 // w_stl_topfill (int)
W_STL_EMPTY_OFF :: 748 // w_stl_empty (char)
W_STL_RECORDING_OFF :: 752 // w_stl_recording (int)
W_STL_STATE_OFF :: 756 // w_stl_state (int)
W_STL_VISUAL_MODE_OFF :: 760 // w_stl_visual_mode (int)
W_STL_VISUAL_POS_OFF :: 764 // w_stl_visual_pos (pos_T 12B)
HLF_CM_O :: 11 // Mode (e.g. "-- INSERT --")
SHM_RECORDING_O :: 'q' // no recording message
SHM_COMPLETIONMENU_O :: 'c' // completion menu messages

foreign _ {
	@(link_name = "msg_ext_ui_flush")
	msg_ext_ui_flush_r :: proc "c"() ---
	@(link_name = "msg_ext_flush_showmode")
	msg_ext_flush_showmode_r :: proc "c"() ---
	@(link_name = "p_smd")
	p_smd_g: C.int
	@(link_name = "p_paste")
	p_paste_g: C.int
	@(link_name = "edit_submode")
	edit_submode_g: ^u8
	@(link_name = "edit_submode_pre")
	edit_submode_pre_g: ^u8
	@(link_name = "edit_submode_extra")
	edit_submode_extra_g: ^u8
	@(link_name = "edit_submode_highl")
	edit_submode_highl_g: C.int
	@(link_name = "VIsual_select")
	VIsual_select_g: bool
	@(link_name = "msg_clr_cmdline")
	msg_clr_cmdline_r :: proc "c"() ---
	@(link_name = "clear_showcmd")
	clear_showcmd_r :: proc "c"() ---
	@(link_name = "redraw_ruler")
	redraw_ruler_r :: proc "c"() ---
}

// Show cursor info in ruler and other places; marks status/cmdline for redraw.
@(export)
show_cursor_info_later :: proc "c"(force: bool) {
	state := get_real_state_r()
	empty_line: C.int = 0
	if State & MODE_INSERT == 0 &&
		b_at(ml_get_buf((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^,
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^), 0) == 0 { // NUL
		empty_line = 1
	}

	// Only draw when something changed.
	validate_virtcol_r(curwin)
	if force ||
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != (^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF)^ ||
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ != (^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF + 4)^ ||
		(^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ != (^C.int)(uintptr(curwin) + W_STL_VIRTCOL_OFF)^ ||
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ != (^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF + 8)^ ||
		(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ != (^C.int)(uintptr(curwin) + W_STL_TOPLINE_OFF)^ ||
		(^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ != (^C.int)(uintptr(curwin) + W_STL_LINE_COUNT_OFF)^ ||
		(^C.int)(uintptr(curwin) + W_TOPFILL)^ != (^C.int)(uintptr(curwin) + W_STL_TOPFILL_OFF)^ ||
		empty_line != C.int((^u8)(uintptr(curwin) + W_STL_EMPTY_OFF)^) ||
		reg_recording != (^C.int)(uintptr(curwin) + W_STL_RECORDING_OFF)^ ||
		state != (^C.int)(uintptr(curwin) + W_STL_STATE_OFF)^ ||
		(VIsual_active && (VIsual_mode != (^C.int)(uintptr(curwin) + W_STL_VISUAL_MODE_OFF)^ ||
			VIsual_g.lnum != (^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF)^ ||
			VIsual_g.col != (^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF + 4)^ ||
			VIsual_g.coladd != (^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF + 8)^)) {
		if (^C.int)(uintptr(curwin) + W_STATUS_HEIGHT_OFF)^ != 0 || global_stl_height() != 0 {
			(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
		} else {
			redraw_cmdline_g = true
		}

		if p_wbr_g^ != 0 || b_at((^u8)((^rawptr)(uintptr(curwin) + W_P_WBR_OFF)^), 0) != 0 {
			(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
		}

		redraw_custom_title_later()
	}

	// Snapshot current state for next comparison.
	(^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	(^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF + 4)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	(^C.int)(uintptr(curwin) + W_STL_CURSOR_OFF + 8)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^
	(^C.int)(uintptr(curwin) + W_STL_VIRTCOL_OFF)^ = (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^
	(^u8)(uintptr(curwin) + W_STL_EMPTY_OFF)^ = u8(empty_line)
	(^C.int)(uintptr(curwin) + W_STL_TOPLINE_OFF)^ = (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
	(^C.int)(uintptr(curwin) + W_STL_LINE_COUNT_OFF)^ = (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^
	(^C.int)(uintptr(curwin) + W_STL_TOPFILL_OFF)^ = (^C.int)(uintptr(curwin) + W_TOPFILL)^
	(^C.int)(uintptr(curwin) + W_STL_RECORDING_OFF)^ = reg_recording
	(^C.int)(uintptr(curwin) + W_STL_STATE_OFF)^ = state
	if VIsual_active {
		(^C.int)(uintptr(curwin) + W_STL_VISUAL_MODE_OFF)^ = VIsual_mode
		(^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF)^ = VIsual_g.lnum
		(^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF + 4)^ = VIsual_g.col
		(^C.int)(uintptr(curwin) + W_STL_VISUAL_POS_OFF + 8)^ = VIsual_g.coladd
	}
}

// Position for a mode message (C static).
msg_pos_mode_o :: proc "c"() {
	msg_col = 0
	msg_row = Rows - 1
}

// Delete mode message; callers check mode_displayed. ESC path.
@(export)
unshowmode :: proc "c"(force: bool) {
	// Don't delete right now when not redrawing or inside a mapping.
	if !redrawing() || (!force && char_avail_r() && !KeyTyped) {
		redraw_cmdline_g = true // delete mode later
	} else {
		clearmode()
	}
}

// Clear the mode message.
@(export)
clearmode :: proc "c"() {
	save_msg_row := msg_row
	save_msg_col := msg_col

	msg_ext_ui_flush_r()
	msg_pos_mode_o()
	if reg_recording != 0 {
		recording_mode_o(HLF_CM_O)
	}
	msg_clr_eos_r()
	msg_ext_flush_showmode_r()

	msg_col = save_msg_col
	msg_row = save_msg_row
}

// "recording @x" message unless 'shortmess' has q (C static).
recording_mode_o :: proc "c"(hl_id: C.int) {
	if shortmess(SHM_RECORDING_O) {
		return
	}

	msg_puts_hl_r(gettext("recording"), hl_id, false)
	s: [4]u8
	libc.snprintf(&s[0], 4, " @%c", C.int(reg_recording))
	msg_puts_hl_r(cstring(&s[0]), hl_id, false)
}

// ── Batch 5: showmode ─────────────────────────────────────────────────────────

VREPLACE_FLAG_O :: 0x200 // state_defs.h
W_P_ARAB_OFF :: 816 // w_p_arab (int)
// Show the current mode and ruler; returns message length (0 if none).
@(export)
showmode :: proc "c"() -> C.int {
	length: C.int = 0

	// Don't make non-flushed message part of the showmode.
	msg_ext_ui_flush_r()

	msg_grid_validate_r()

	do_mode := (p_smd_g != 0 && msg_silent == 0) &&
		((State & MODE_TERMINAL_S) != 0 ||
			(State & MODE_INSERT) != 0 ||
			restart_edit != 0 ||
			VIsual_active)

	can_show_mode := (p_ch != 0 || ui_has_r(K_UIMESSAGES_O))
	if (do_mode || reg_recording != 0) && can_show_mode {
		if skip_showmode() {
			return 0 // show mode later
		}

		nwr_save := need_wait_return_g

		// Wait a bit before overwriting an important message.
		msg_check_for_delay_r(false)

		// If the cmdline is more than one line high, erase top lines.
		need_clear := clear_cmdline_g
		if clear_cmdline_g && cmdline_row < Rows - 1 {
			msg_clr_cmdline_r() // resets clear_cmdline
		}

		// Position on the last line, column 0.
		msg_pos_mode_o()
		hl_id: C.int = HLF_CM_O

		// Narrow screen: truncate instead of scrolling.
		msg_no_more = 1
		save_lines_left := lines_left
		lines_left = 0

		if do_mode {
			msg_puts_hl_r("--", hl_id, false)
			// CTRL-X in Insert mode.
			if edit_submode_g != nil && !shortmess(SHM_COMPLETIONMENU_O) {
				// Long messages: avoid wrap in a narrow window.
				if ui_has_r(K_UIMESSAGES_O) {
					length = max(C.int)
				} else {
					length = (Rows - msg_row) * Columns - 3
				}
				if edit_submode_extra_g != nil {
					length -= vim_strsize_r(transmute(cstring)(edit_submode_extra_g))
				}
				if length > 0 {
					if edit_submode_pre_g != nil {
						length -= vim_strsize_r(transmute(cstring)(edit_submode_pre_g))
					}
					if length - vim_strsize_r(transmute(cstring)(edit_submode_g)) > 0 {
						if edit_submode_pre_g != nil {
							msg_puts_hl_r(transmute(cstring)(edit_submode_pre_g), hl_id, false)
						}
						msg_puts_hl_r(transmute(cstring)(edit_submode_g), hl_id, false)
					}
					if edit_submode_extra_g != nil {
						msg_puts_hl_r(" ", hl_id, false) // space in between
						sub_id := hl_id
						if edit_submode_highl_g < HLF_COUNT_O {
							sub_id = edit_submode_highl_g
						}
						msg_puts_hl_r(transmute(cstring)(edit_submode_extra_g), sub_id, false)
					}
				}
			} else {
				if State & MODE_TERMINAL_S != 0 {
					msg_puts_hl_r(gettext(" TERMINAL"), hl_id, false)
				} else if State & VREPLACE_FLAG_O != 0 {
					msg_puts_hl_r(gettext(" VREPLACE"), hl_id, false)
				} else if State & REPLACE_FLAG != 0 {
					msg_puts_hl_r(gettext(" REPLACE"), hl_id, false)
				} else if State & MODE_INSERT != 0 {
					if p_ri != 0 {
						msg_puts_hl_r(gettext(" REVERSE"), hl_id, false)
					}
					msg_puts_hl_r(gettext(" INSERT"), hl_id, false)
				} else if restart_edit == 'I' || restart_edit == 'i' ||
					restart_edit == 'a' || restart_edit == 'A' {
					if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
						msg_puts_hl_r(gettext(" (terminal)"), hl_id, false)
					} else {
						msg_puts_hl_r(gettext(" (insert)"), hl_id, false)
					}
				} else if restart_edit == 'R' {
					msg_puts_hl_r(gettext(" (replace)"), hl_id, false)
				} else if restart_edit == 'V' {
					msg_puts_hl_r(gettext(" (vreplace)"), hl_id, false)
				}
				if State & MODE_LANGMAP != 0 {
					if (^C.int)(uintptr(curwin) + W_P_ARAB_OFF)^ != 0 {
						msg_puts_hl_r(gettext(" Arabic"), hl_id, false)
					} else if get_keymap_str(curwin, transmute(^u8)cstring(" (%s)"),
						&name_buff[0], MAXPATHL) > 0 {
						msg_puts_hl_r(cstring(&name_buff[0]), hl_id, false)
					}
				}
				if (State & MODE_INSERT) != 0 && p_paste_g != 0 {
					msg_puts_hl_r(gettext(" (paste)"), hl_id, false)
				}

				if VIsual_active {
					// Separate words (no concatenation): translation safety.
					sel: C.int = 0
					if VIsual_select_g {
						sel += 4
					}
					if VIsual_mode == Ctrl_V {
						sel += 2
					}
					if VIsual_mode == 'V' {
						sel += 1
					}
					p: cstring
					switch sel {
					case 0:
						p = " VISUAL"
					case 1:
						p = " VISUAL LINE"
					case 2:
						p = " VISUAL BLOCK"
					case 4:
						p = " SELECT"
					case 5:
						p = " SELECT LINE"
					case:
						p = " SELECT BLOCK"
					}
					msg_puts_hl_r(gettext(p), hl_id, false)
				}
				msg_puts_hl_r(" --", hl_id, false)
			}

			need_clear = true
		}
		if reg_recording != 0 &&
			edit_submode_g == nil { // otherwise too long
			recording_mode_o(hl_id)
			need_clear = true
		}

		mode_displayed_g = true
		if need_clear || clear_cmdline_g || redraw_mode_g {
			msg_clr_eos_r()
		}
		msg_didout_g = false // overwrite this message
		length = msg_col
		msg_col = 0
		msg_no_more = 0
		lines_left = save_lines_left
		need_wait_return_g = nwr_save // never hit-return for this
	} else if clear_cmdline_g && msg_silent == 0 {
		// Clear the whole command line (resets clear_cmdline).
		msg_clr_cmdline_r()
	} else if redraw_mode_g {
		msg_pos_mode_o()
		msg_clr_eos_r()
	}

	// Also clears showmode when empty or disabled.
	msg_ext_flush_showmode_r()

	// In Visual mode the selected-area size must be redrawn.
	if VIsual_active {
		clear_showcmd_r()
	}

	redraw_ruler_r() // check if ruler should be redrawn
	redraw_cmdline_g = false
	redraw_mode_g = false
	clear_cmdline_g = false

	return length
}

// ── Batch 7: screen_resize ────────────────────────────────────────────────────

MODE_HITRETURN_O :: 0x2001 // 0x2000|MODE_NORMAL
MODE_ASKMORE_O :: 0x3000
MODE_SETWSIZE_O :: 0x4000
EVENT_VIMRESIZED_O :: 139 // auevents_enum.generated.h
CCLINE_ONE_KEY_OFF :: 168 // CmdlineInfo.one_key (bool)
CCLINE_MOUSE_USED_OFF :: 176 // CmdlineInfo.mouse_used (ptr)

// File-static (drawscreen.c:136). NOTE: C's update_screen still reads C's own
// copy until ported — benign (only guards re-entrant redraw during resize).
@(private="file")
resizing_autocmd_f: bool = false

foreign _ {
	@(link_name = "p_lines")
	p_lines_g: C.longlong
	@(link_name = "p_columns")
	p_columns_g: C.longlong
	@(link_name = "get_cmdline_info")
	get_cmdline_info_r :: proc "c"() -> rawptr ---
	@(link_name = "repeat_message")
	repeat_message_r :: proc "c"() ---
	@(link_name = "do_check_scrollbind")
	do_check_scrollbind_r :: proc "c"(check: bool) ---
	@(link_name = "redrawcmdline")
	redrawcmdline_r :: proc "c"() ---
	@(link_name = "pum_drawn")
	pum_drawn_r :: proc "c"() -> bool ---
	@(link_name = "cmdline_pum_display")
	cmdline_pum_display_r :: proc "c"(changed_array: bool) ---
	@(link_name = "ins_compl_show_pum")
	ins_compl_show_pum_r :: proc "c"() ---
}

// Unlike one_key prompts, the prompt message part is not stored (C static).
cmdline_number_prompt_o :: proc "c"() -> bool {
	return !ui_has_r(K_UIMESSAGES_O) && (State & MODE_CMDLINE_O) != 0 &&
		(^rawptr)(uintptr(get_cmdline_info_r()) + CCLINE_MOUSE_USED_OFF)^ != nil
}

// Set dimensions of the Nvim application screen.
@(export)
screen_resize :: proc "c"(width_in: C.int, height_in: C.int) {
	// Avoid recursion from window-changed signals during resize.
	if updating_screen_g || resizing_screen_g || cmdline_number_prompt_o() {
		return
	}

	if width_in < 0 || height_in < 0 { // just checking...
		return
	}

	if State == MODE_HITRETURN_O || State == MODE_SETWSIZE_O {
		// Postpone the resizing.
		State = MODE_SETWSIZE_O
		return
	}

	resizing_screen_g = true

	Rows = height_in
	Columns = width_in
	check_screensize()
	if !ui_has_r(K_UIMESSAGES_O) {
		// Clamp 'cmdheight'.
		max_p_ch := Rows - min_rows(curtab) + 1
		if p_ch > 0 && p_ch > C.long(max_p_ch) {
			p_ch = max(C.long(max_p_ch), 1)
			(^C.longlong)(uintptr(curtab) + TP_CH_USED_OFF)^ = C.longlong(p_ch)
		}
		// Clamp 'cmdheight' for other tab pages.
		tp := first_tabpage
		for tp != nil {
			if tp != curtab {
				max_tp_ch := Rows - min_rows(tp) + 1
				tp_ch := (^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^
				if tp_ch > 0 && tp_ch > C.longlong(max_tp_ch) {
					(^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^ =
						C.longlong(max(C.int(max_tp_ch), 1))
				}
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
	}
	height := Rows
	width := Columns
	p_lines_g = C.longlong(Rows)
	p_columns_g = C.longlong(Columns)

	ui_call_grid_resize_r(1, C.longlong(width), C.longlong(height))

	retry_count: C.int = 0
	resizing_autocmd_f = true

	// Autocommands may alter Rows/Columns; retry the alloc.
	for default_grid_alloc() {
		// Recompute floats position; compositor redraw comes later.
		ui_comp_set_screen_valid_r(false)
		if (^rawptr)(uintptr(transmute(rawptr)(&msg_grid_u8)) + 8)^ != nil {
			msg_grid_invalid_f = true
		}

		RedrawingDisabled += 1

		win_new_screensize() // fit windows in the new screen

		comp_col() // recompute showcmd/ruler columns

		RedrawingDisabled -= 1

		// At most 3 autocmd rounds (endless-loop guard).
		retry_count += 1
		if retry_count > 3 {
			break
		}

		apply_autocmds(EVENT_VIMRESIZED_O, nil, nil, false, curbuf)
	}

	resizing_autocmd_f = false
	redraw_all_later(UPD_CLEAR_O)

	if State != MODE_ASKMORE_O && State != MODE_EXTERNCMD {
		screenclear()
	}

	if starting != NO_SCREEN_O {
		maketitle()

		changed_line_abv_curs_r()
		invalidate_botline_win_r(curwin)

		// Redraw when needed:
		// - more prompt / external command: position cursor only.
		// - command line editing: redraw that (plus pager fixup).
		// - Ex mode: nothing.  Otherwise redraw now + position cursor.
		if State == MODE_ASKMORE_O || State == MODE_EXTERNCMD || exmode_active ||
			((State & MODE_CMDLINE_O) != 0 &&
				(^bool)(uintptr(get_cmdline_info_r()) + CCLINE_ONE_KEY_OFF)^) {
			if (State & MODE_CMDLINE_O) != 0 {
				_ = update_screen()
			}
			if (^rawptr)(uintptr(transmute(rawptr)(&msg_grid_u8)) + 8)^ != nil {
				msg_grid_validate_r()
			}
			// TODO(bfredl): sometimes messes up pager output.
			ui_comp_set_screen_valid_r(true)
			repeat_message_r()
		} else {
			if (^bool)(uintptr(curwin) + W_P_SCB_OFF)^ {
				do_check_scrollbind_r(true)
			}
			if (State & MODE_CMDLINE_O) != 0 {
				redraw_popupmenu_f = false
				_ = update_screen()
				redrawcmdline_r()
				if pum_drawn_r() {
					cmdline_pum_display_r(false)
				}
			} else {
				update_topline_r(curwin)
				if pum_drawn_r() {
					// ins_compl_show_pum wants redraw first: suppress the
					// nested update_screen() pum redraw at the old position.
					redraw_popupmenu_f = false
					ins_compl_show_pum_r()
				}
				_ = update_screen()
				if redrawing() {
					setcursor()
				}
			}
		}
		ui_flush_s()
	}
	resizing_screen_g = false
}

// ── Batch 8: update_screen + separator statics ────────────────────────────────

WC_TOP_LEFT_O :: 0
WC_TOP_RIGHT_O :: 1
WC_BOTTOM_LEFT_O :: 2
WC_BOTTOM_RIGHT_O :: 3
W_GRID_ALLOC_CHARS_OFF :: 10464 // w_grid_alloc.chars (10456+8)
FCS_HORIZ_O :: 12
FCS_HORIZUP_O :: 16
FCS_HORIZDOWN_O :: 20
FCS_VERT_O :: 24
FCS_VERTLEFT_O :: 28
FCS_VERTRIGHT_O :: 32
FCS_VERTHORIZ_O :: 36
HLF_C_O :: 21 // window separators (counted hlf_T: SNC20→C21)
B_MOD_SET_OFF :: 273 // b_mod_set (bool)
B_MOD_TICK_SYN_OFF :: 312 // b_mod_tick_syn (u64)
B_MOD_TICK_DECOR_OFF :: 320 // b_mod_tick_decor (u64)

// File-static (drawscreen.c:446).
@(private="file")
still_may_intro_f: bool = true

foreign _ {
	@(link_name = "may_show_intro")
	may_show_intro_r :: proc "c"() -> bool ---
	@(link_name = "diff_redraw")
	diff_redraw_r :: proc "c"(dofold: bool) ---
	@(link_name = "autocmd_save_curwin")
	autocmd_save_curwin_g: C.int
	@(link_name = "msg_did_scroll")
	msg_did_scroll_g: bool
	@(link_name = "msg_scrolled_at_flush")
	msg_scrolled_at_flush_g: C.int
	@(link_name = "msg_grid_scroll_discount")
	msg_grid_scroll_discount_g: C.int
	@(link_name = "msg_scrollsize")
	msg_scrollsize_r :: proc "c"() -> C.int ---
	@(link_name = "msg_grid_set_pos")
	msg_grid_set_pos_r :: proc "c"(row: C.int, scrolled: bool) ---
	@(link_name = "need_highlight_changed")
	need_highlight_changed_g: bool
	@(link_name = "cmdline_screen_cleared")
	cmdline_screen_cleared_r :: proc "c"() ---
	@(link_name = "ui_call_msg_clear")
	ui_call_msg_clear_r :: proc "c"() ---
	@(link_name = "decor_providers_start")
	decor_providers_start_r :: proc "c"() ---
	@(link_name = "decor_providers_invoke_buf")
	decor_providers_invoke_buf_r :: proc "c"(buf: rawptr) ---
	@(link_name = "decor_providers_invoke_end")
	decor_providers_invoke_end_r :: proc "c"() ---
	@(link_name = "update_curswant")
	update_curswant_r :: proc "c"() ---
	@(link_name = "update_window_hl")
	update_window_hl_r :: proc "c"(wp: rawptr, invalid: bool) ---
	@(link_name = "syn_stack_apply_changes")
	syn_stack_apply_changes_r :: proc "c"(buf: rawptr) ---
	@(link_name = "must_redraw_pum")
	must_redraw_pum_g: bool
	@(link_name = "pum_redraw")
	pum_redraw_r :: proc "c"() ---
	@(link_name = "pum_check_clear")
	pum_check_clear_r :: proc "c"() ---
	@(link_name = "intro_message")
	intro_message_r :: proc "c"(colon: bool) ---
}

// Check hsep connection at a window corner (global stl assumed; C static).
hsep_connected_o :: proc "c"(wp: rawptr, corner: C.int) -> bool {
	before := corner == WC_TOP_LEFT_O || corner == WC_BOTTOM_LEFT_O
	sep_row: C.int
	if corner == WC_TOP_LEFT_O || corner == WC_TOP_RIGHT_O {
		sep_row = (^C.int)(uintptr(wp) + W_WINROW_OFF)^ - 1
	} else {
		sep_row = (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
	}
	fr := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^

	for (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^ != nil {
		parent := (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		prev := (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
		next := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
			(before ? prev : next) != nil {
			if before {
				fr = prev
			} else {
				fr = next
			}
			break
		}
		fr = parent
	}
	if (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^ == nil {
		return false
	}
	for b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) != FR_LEAF_O {
		fr = (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
		parent := (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O && before {
			for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
				fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
			}
		} else {
			for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil &&
				(^C.int)(uintptr(frame2win(fr)) + W_WINROW_OFF)^ +
					(^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ < sep_row {
				fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
			}
		}
	}

	win := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
	return sep_row == (^C.int)(uintptr(win) + W_WINROW_OFF)^ - 1 ||
		sep_row == (^C.int)(uintptr(win) + W_WINROW_OFF)^ + (^C.int)(uintptr(win) + W_HEIGHT_OFF)^
}

// Check vsep connection at a window corner (C static).
vsep_connected_o :: proc "c"(wp: rawptr, corner: C.int) -> bool {
	before := corner == WC_TOP_LEFT_O || corner == WC_TOP_RIGHT_O
	sep_col: C.int
	if corner == WC_TOP_LEFT_O || corner == WC_BOTTOM_LEFT_O {
		sep_col = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ - 1
	} else {
		sep_col = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + (^C.int)(uintptr(wp) + W_WIDTH_OFF)^
	}
	fr := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^

	for (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^ != nil {
		parent := (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		prev := (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
		next := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
			(before ? prev : next) != nil {
			if before {
				fr = prev
			} else {
				fr = next
			}
			break
		}
		fr = parent
	}
	if (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^ == nil {
		return false
	}
	for b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) != FR_LEAF_O {
		fr = (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
		parent := (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_COL_O && before {
			for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
				fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
			}
		} else {
			for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil &&
				(^C.int)(uintptr(frame2win(fr)) + W_WINCOL_OFF)^ +
					(^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ < sep_col {
				fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
			}
		}
	}

	win := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
	return sep_col == (^C.int)(uintptr(win) + W_WINCOL_OFF)^ - 1 ||
		sep_col == (^C.int)(uintptr(win) + W_WINCOL_OFF)^ + (^C.int)(uintptr(win) + W_WIDTH_OFF)^
}

// Separator connector for a window corner (C static).
get_corner_sep_connector_o :: proc "c"(wp: rawptr, corner: C.int) -> u32 {
	fcs := (^rawptr)(uintptr(wp) + W_P_FCS_CHARS_OFF)^
	// Windows always connect one way; not-vertical implies horizontal.
	if vsep_connected_o(wp, corner) {
		if hsep_connected_o(wp, corner) {
			return (^u32)(uintptr(fcs) + FCS_VERTHORIZ_O)^
		} else if corner == WC_TOP_LEFT_O || corner == WC_BOTTOM_LEFT_O {
			return (^u32)(uintptr(fcs) + FCS_VERTRIGHT_O)^
		} else {
			return (^u32)(uintptr(fcs) + FCS_VERTLEFT_O)^
		}
	} else if corner == WC_TOP_LEFT_O || corner == WC_TOP_RIGHT_O {
		return (^u32)(uintptr(fcs) + FCS_HORIZDOWN_O)^
	} else {
		return (^u32)(uintptr(fcs) + FCS_HORIZUP_O)^
	}
}

// Draw separator connectors on wp corners (global stl only; C static).
draw_sep_connectors_win_o :: proc "c"(wp: rawptr) {
	// Skip unless global statusline and 1-cell separators exist.
	if global_stl_height() == 0 ||
		!((^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ == 1 ||
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 1) {
		return
	}

	hl := win_hl_attr_o(wp, HLF_C_O)

	// Screen edges need no connectors on contained corners.
	win_at_bottom := (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ == 0
	win_at_right := (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 0
	frp: rawptr
	win_at_top: bool
	win_at_left: bool

	frp = (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	for (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ != nil {
		parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
			(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
			break
		}
		frp = parent
	}
	win_at_top = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ == nil
	frp = (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	for (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ != nil {
		parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
			(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
			break
		}
		frp = parent
	}
	win_at_left = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ == nil

	// Cursor position updates stay suppressed (grid_line_* only).
	dgv := (^GridView)(&default_gridview_u8)
	if !(win_at_top || win_at_left) {
		grid_line_start(dgv, (^C.int)(uintptr(wp) + W_WINROW_OFF)^ - 1)
		grid_line_put_schar((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ - 1,
			get_corner_sep_connector_o(wp, WC_TOP_LEFT_O), hl)
		grid_line_flush()
	}
	if !(win_at_top || win_at_right) {
		grid_line_start(dgv, (^C.int)(uintptr(wp) + W_WINROW_OFF)^ - 1)
		grid_line_put_schar((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ +
			(^C.int)(uintptr(wp) + W_WIDTH_OFF)^,
			get_corner_sep_connector_o(wp, WC_TOP_RIGHT_O), hl)
		grid_line_flush()
	}
	if !(win_at_bottom || win_at_left) {
		grid_line_start(dgv, (^C.int)(uintptr(wp) + W_WINROW_OFF)^ +
			(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^)
		grid_line_put_schar((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ - 1,
			get_corner_sep_connector_o(wp, WC_BOTTOM_LEFT_O), hl)
		grid_line_flush()
	}
	if !(win_at_bottom || win_at_right) {
		grid_line_start(dgv, (^C.int)(uintptr(wp) + W_WINROW_OFF)^ +
			(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^)
		grid_line_put_schar((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ +
			(^C.int)(uintptr(wp) + W_WIDTH_OFF)^,
			get_corner_sep_connector_o(wp, WC_BOTTOM_RIGHT_O), hl)
		grid_line_flush()
	}
}

// Redraw the parts of the screen marked for redraw.
@(export)
update_screen :: proc "c"() -> C.int {
	if still_may_intro_f {
		if !may_show_intro_r() {
			redraw_later(firstwin, UPD_NOT_VALID)
			still_may_intro_f = false
		}
	}

	is_stl_global := global_stl_height() > 0

	// Screen structures invalid (e.g. VimResized autocmd mid-resize).
	if resizing_autocmd_f || (^rawptr)(uintptr(transmute(rawptr)(&default_grid_u8)) + 8)^ == nil {
		return FAIL
	}

	// Postponed diff updates.
	if need_diff_redraw {
		diff_redraw_r(true)
	}

	// Postpone when not needed or called recursively.
	if !redrawing() || updating_screen_g || cmdline_number_prompt_o() {
		return FAIL
	}

	// Restore actual curwin before redrawing.
	save_curwin: rawptr = nil
	if autocmd_save_curwin_g != 0 {
		save_curwin = win_find_by_handle(autocmd_save_curwin_g)
	}
	restore_curwin: rawptr = nil
	if save_curwin != nil {
		restore_curwin = curwin
	}
	if save_curwin != nil {
		curwin = save_curwin
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	}

	type_ := must_redraw

	// Reset here: redraws triggered while busy (async scroll,
	// update_topline scroll, decor providers) mark for later/win_update.
	must_redraw = 0

	updating_screen_g = true

	display_tick_g += 1 // next display round for syntax code

	// Glyph cache full (very rare): contents can't be compared.
	if schar_cache_clear_if_full() {
		// TODO(bfredl): cached schar_T (fcs/lcs) need revalidation too!
		type_ = max(type_, UPD_CLEAR_O)
	}

	// msg_scrolled bookkeeping (vim may reset it behind our back).
	if msg_did_scroll_g {
		msg_did_scroll_g = false
		msg_scrolled_at_flush_g = 0
	}

	dg := (^ScreenGrid)(&default_grid_u8)
	if type_ >= UPD_CLEAR_O || !dg.valid {
		ui_comp_set_screen_valid_r(false)
	}

	// Screen scrolled up for a message: scroll it down.
	if msg_scrolled != 0 || msg_grid_invalid_f {
		clear_cmdline_g = true
		scrollsize := msg_scrollsize_r()
		valid := max(Rows - scrollsize, 0)
		mg := (^ScreenGrid)(&msg_grid_u8)
		if mg.chars != nil {
			// Non-displayed msg_grid part is invalid.
			n := min(scrollsize, mg.rows)
			for i: C.int = 0; i < n; i += 1 {
				grid_clear_line(mg, mg.line_offset[uintptr(i)], mg.cols, C.longlong(i) < p_ch)
			}
		}
		mg.throttled = false
		was_invalidated := false

		// UPD_CLEAR already handled.
		if type_ == UPD_NOT_VALID && !ui_has_r(K_UIMULTIGRID_O) && msg_scrolled != 0 {
			was_invalidated = ui_comp_set_screen_valid_r(false)
			for i := valid; i < Rows - C.int(p_ch); i += 1 {
				grid_clear_line(dg, dg.line_offset[uintptr(i)], Columns, false)
			}
			tp := curtab
			wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
					continue
				}
				if (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ > valid {
					// TODO(bfredl): pessimistic for windows above separator.
					if (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ < UPD_NOT_VALID {
						(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = UPD_NOT_VALID
					}
				}
				if !is_stl_global &&
					(^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ +
						(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ > valid {
					(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			if is_stl_global && Rows - C.int(p_ch) - 1 > valid {
				(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
			}
		}
		msg_grid_set_pos_r(Rows - C.int(p_ch), false)
		msg_grid_invalid_f = false
		if was_invalidated {
			// Only the msgarea part was invalid.
			// @TODO(bfredl): same "valid" flag for messages+floats is a mess.
			ui_comp_set_screen_valid_r(true)
		}
		msg_scrolled = 0
		msg_scrolled_at_flush_g = 0
		msg_grid_scroll_discount_g = 0
		need_wait_return_g = false
	}

	win_ui_flush(true)

	// cmdline_row may have changed temporarily; reset now.
	compute_cmdrow_r()

	hl_changed := false
	// Check for changed highlighting.
	if need_highlight_changed_g {
		highlight_changed_r()
		hl_changed = true
	}

	if type_ == UPD_CLEAR_O { // clear screen first
		screenclear() // resets clear_cmdline; sets UPD_NOT_VALID per window
		cmdline_screen_cleared_r() // clear external cmdline state
		if ui_has_r(K_UIMESSAGES_O) {
			ui_call_msg_clear_r()
		}
		type_ = UPD_NOT_VALID
		// must_redraw may be set indirectly; avoid another redraw later.
		must_redraw = 0
	} else if !dg.valid {
		grid_invalidate(dg)
		dg.valid = true
	}

	// Clear space on default_grid for the message area.
	if type_ == UPD_NOT_VALID && clear_cmdline_g && !ui_has_r(K_UIMESSAGES_O) {
		grid_clear((^GridView)(&default_gridview_u8), Rows - C.int(p_ch), Rows, 0, Columns, 0)
	}

	ui_comp_set_screen_valid_r(true)

	decor_providers_start_r()

	// "start" callback may change global-element highlights.
	if win_check_ns_hl_r(nil) {
		redraw_cmdline_g = true
		redraw_tabline_opt = true
	}

	if clear_cmdline_g { // cmdline cleared below
		msg_check_for_delay_r(false)
	}

	// Force redraw when number-column width changes.
	// TODO(bfredl): curwin special-case is SÅ JÄVLA BULL.
	if (^C.int)(uintptr(curwin) + W_REDR_TYPE_OFF)^ < UPD_NOT_VALID &&
		(^C.int)(uintptr(curwin) + W_NRWIDTH_VAL_OFF)^ !=
			((^C.int)(uintptr(curwin) + W_P_NU_OFF)^ != 0 ||
				(^C.int)(uintptr(curwin) + W_P_RNU_OFF)^ != 0 ||
				b_at((^u8)((^rawptr)(uintptr(curwin) + W_P_STC_OFF)^), 0) != 0 ?
				number_width(curwin) : 0) {
		(^C.int)(uintptr(curwin) + W_REDR_TYPE_OFF)^ = UPD_NOT_VALID
	}

	if (^C.int)(uintptr(curwin) + W_REDR_TYPE_OFF)^ == UPD_INVERTED_F {
		// Visual end needs w_curswant updated.
		update_curswant_r()
	}

	// Redraw the tab pages line if needed.
	if redraw_tabline_opt || type_ >= UPD_NOT_VALID {
		update_window_hl_r(curwin, type_ >= UPD_NOT_VALID)
		tp := first_tabpage
		for tp != nil {
			if tp != curtab {
				update_window_hl_r((^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^, type_ >= UPD_NOT_VALID)
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		draw_tabline_r()
	}

	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ &&
			(^rawptr)(uintptr(wp) + W_GRID_ALLOC_CHARS_OFF)^ != nil {
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			continue // hidden window, allocated: skip
		}
		// Stored syntax hl info per displayed buffer (once each).
		update_window_hl_r(wp, type_ >= UPD_NOT_VALID || hl_changed)

		buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		if (^bool)(uintptr(buf) + B_MOD_SET_OFF)^ {
			if (^u64)(uintptr(buf) + B_MOD_TICK_SYN_OFF)^ < display_tick_g &&
				syntax_present_r(wp) {
				syn_stack_apply_changes_r(buf)
				(^u64)(uintptr(buf) + B_MOD_TICK_SYN_OFF)^ = display_tick_g
			}

			if (^u64)(uintptr(buf) + B_MOD_TICK_DECOR_OFF)^ < display_tick_g {
				decor_providers_invoke_buf_r(buf)
				(^u64)(uintptr(buf) + B_MOD_TICK_DECOR_OFF)^ = display_tick_g
			}
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}

	// Top to bottom through windows, redrawing those that need it.
	did_one := false
	// screen_search_hl.rm.regprog is first in match_T.
	(^rawptr)(transmute(rawptr)(&screen_search_hl_u8))^ = nil

	tp = curtab
	wp = tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ &&
			(^rawptr)(uintptr(wp) + W_GRID_ALLOC_CHARS_OFF)^ != nil {
			if wp == curwin && global_stl_height() > 0 {
				win_redr_status_r(wp)
			}
			(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = 0
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			continue // hidden window, allocated: skip
		}

		if (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ == UPD_CLEAR_O &&
			(^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
			(^rawptr)(uintptr(wp) + W_GRID_ALLOC_CHARS_OFF)^ != nil {
			grid_invalidate((^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF))
			(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = UPD_NOT_VALID
		}

		win_check_ns_hl_r(wp)

		// Reallocate grid if needed.
		win_grid_alloc(wp)

		if (^bool)(uintptr(wp) + W_REDR_BORDER_OFF)^ ||
			(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ >= UPD_NOT_VALID {
			grid_draw_border((^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF),
				transmute(rawptr)(uintptr(wp) + W_CONFIG_OFF),
				(^C.int)(uintptr(wp) + W_BORDER_ADJ_OFF),
				C.int((^C.longlong)(uintptr(wp) + W_P_WINBL_OFF)^),
				([^]C.int)((^rawptr)(uintptr(wp) + W_NS_HL_ATTR_OFF)^))
		}

		if (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ != 0 {
			if !did_one {
				did_one = true
				start_search_hl()
			}
			win_update(wp)
		}

		// Status line + winbar after the window (less cursor movement).
		if (^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ {
			win_redr_winbar_r(wp)
			win_redr_status_r(wp)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}

	// Separators after all windows (connectors overwrite vsep/hsep).
	if did_one {
		tp = curtab
		wp = tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			draw_sep_connectors_win_o(wp)
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}

	end_search_hl()

	// Popup menu may need redraw.
	if pum_drawn_r() && must_redraw_pum_g {
		win_check_ns_hl_r(curwin)
		pum_redraw_r()
	} else if (State & MODE_CMDLINE_O) != 0 {
		pum_check_clear_r()
	}

	win_check_ns_hl_r(nil)

	// Reset b_mod_set (windows fewer than buffers, usually).
	tp = curtab
	wp = tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		(^bool)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_MOD_SET_OFF)^ = false
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}

	updating_screen_g = false

	if need_maketitle_opt {
		maketitle()
	}

	// Command line last: scrolling may mess it up.
	if clear_cmdline_g || redraw_cmdline_g || redraw_mode_g {
		_ = showmode()
	}

	// Introductory message when not editing a file.
	if still_may_intro_f {
		intro_message_r(false)
	}
	repeat_message_r()

	decor_providers_invoke_end_r()

	// Cmdline cleared/not drawn/mode last drawn (not always ext cmdline).
	if !ui_has_r(K_UICMDLINE_O) {
		cmdline_was_last_drawn_g = false
	}

	// Restore temporary autocmd curwin.
	if restore_curwin != nil {
		curwin = restore_curwin
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	}

	return OK
}

// ── Batch 9a: win_update prologue (dormant; C:1420-1655) ──────────────────────
// win_update_new grows chunk by chunk; activated once complete (win_line 12a
// precedent). temp-return tail keeps each chunk compiling.

// File-static (drawscreen.c:1443): recursive win_update guard.
@(private="file")
recursive_f: bool = false

B_SIGNCOLS_MAX_OFF :: 12440 // b_signcols.max (int)
B_SIGNCOLS_LAST_MAX_OFF :: 12444 // b_signcols.last_max (int)
B_SIGNCOLS_COUNT_OFF :: 12448 // b_signcols.count[9] (int)
B_SIGNCOLS_AUTOM_OFF :: 12484 // b_signcols.autom (bool; 12440+44)
B_MOD_TOP_OFF :: 276 // b_mod_top (linenr_T)
B_MOD_BOT_OFF :: 280 // b_mod_bot (linenr_T)
B_MOD_XLINES_OFF :: 284 // b_mod_xlines (int)
B_SYN_SYNC_LB_OFF :: 684 // synblock_T.b_syn_sync_linebreaks (rel. w_s)
W_MATCH_HEAD_OFF :: 9136 // w_match_head (ptr)
W_UPD_ROWS_OFF :: 696 // w_upd_rows (int)
W_OLD_BOTFILL_OFF :: 381 // w_old_botfill (bool)
W_OLD_TOPFILL_OFF :: 376 // w_old_topfill (int)
W_OLD_CURSOR_LNUM_OFF :: 168 // w_old_cursor_lnum
W_OLD_VISUAL_LNUM_OFF :: 180
W_OLD_VISUAL_COL_OFF :: 184
MIT_NEXT_OFF :: 0
MIT_MATCH_OFF :: 24 // mit_match.regprog (regmmatch first field)
DID_NONE_O :: 1
DID_LINE_O :: 2
DID_FOLD_O :: 3
DECOR_PRIORITY_BASE_O :: 0x1000

foreign _ {
	@(link_name = "decor_providers_invoke_win")
	decor_providers_invoke_win_r :: proc "c"(wp: rawptr) ---
	@(link_name = "terminal_suspended")
	terminal_suspended_r :: proc "c"(term: rawptr) -> bool ---
	@(link_name = "decor_range_add_virt")
	decor_range_add_virt_r :: proc "c"(state: rawptr, sr: C.int, sc: C.int, er: C.int, ec: C.int, vt: rawptr, owned: bool) ---
	@(link_name = "init_search_hl")
	init_search_hl_r :: proc "c"(wp: rawptr, hl: rawptr) ---
	@(link_name = "syn_set_timeout")
	syn_set_timeout_r :: proc "c"(tm: rawptr) ---
	@(link_name = "win_lines_concealed")
	win_lines_concealed_r :: proc "c"(wp: rawptr) -> bool ---
	@(link_name = "search_hl_has_cursor_lnum")
	search_hl_has_cursor_lnum_g: C.int
	@(link_name = "buf_signcols_count_range")
	buf_signcols_count_range_r :: proc "c"(buf: rawptr, row1: C.int, row2: C.int, add: C.int, clear: C.int) ---
	@(link_name = "ui_call_win_extmark")
	ui_call_win_extmark_r :: proc "c"(grid: C.longlong, win: C.int, ns_id: C.longlong, mark_id: C.longlong, row: C.longlong, col: C.longlong) ---
	@(link_name = "prepare_search_hl")
	prepare_search_hl_r :: proc "c"(wp: rawptr, hl: rawptr, lnum: C.int) ---
	@(link_name = "syntax_end_parsing")
	syntax_end_parsing_r :: proc "c"(wp: rawptr, lnum: C.int) ---
	@(link_name = "syntax_check_changed")
	syntax_check_changed_r :: proc "c"(lnum: C.int) -> bool ---
	@(link_name = "plines_m_win")
	plines_m_win_r :: proc "c"(wp: rawptr, first: C.int, last: C.int, max: C.int) -> C.int ---
	@(link_name = "win_may_fill")
	win_may_fill_r :: proc "c"(wp: rawptr) -> bool ---
	@(link_name = "plines_correct_topline")
	plines_correct_topline_r :: proc "c"(wp: rawptr, lnum: C.int, nextp: ^C.int, limit_winheight: bool, foldedp: ^bool) -> C.int ---
	@(link_name = "getvcols")
	getvcols_r :: proc "c"(wp: rawptr, pos1: ^Pos_T, pos2: ^Pos_T, left: ^C.int, right: ^C.int, flags: C.int) ---
}

// Suspended-terminal "[Process suspended]" statics (drawscreen.c:1495-1499).
@(private="file")
susp_chunk_f: VirtTextChunk
@(private="file")
susp_vt_f: DecorVirtText_O

// Redraw window if auto signcolumn width changed (C static).
win_redraw_signcols_o :: proc "c"(wp: rawptr) -> bool {
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^

	if !(^bool)(uintptr(buf) + B_SIGNCOLS_AUTOM_OFF)^ &&
		(([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF)^))[0] != 0 ||
		((^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ > 1 &&
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ != (^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^) {
		(^bool)(uintptr(buf) + B_SIGNCOLS_AUTOM_OFF)^ = true
		buf_signcols_count_range_r(buf, 0,
			(^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ - 1, MAXLNUM, 0)
	}

	for (^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ > 0 &&
		(^C.int)(uintptr(buf) + B_SIGNCOLS_COUNT_OFF +
			uintptr((^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ - 1) * 4)^ == 0 {
		(^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ -= 1
	}

	width := min((^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^,
		(^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^)
	rebuild_stc := (^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ !=
		(^C.int)(uintptr(buf) + B_SIGNCOLS_LAST_MAX_OFF)^ &&
		(([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF)^))[0] != 0

	if rebuild_stc {
		(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ = 0
	} else if (^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ == 0 &&
		(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ == 1 {
		if buf_meta_total_o(buf, K_MTMETA_SIGNTEXT_O) > 0 {
			width = 1
		} else {
			width = 0
		}
	}

	scwidth := (^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^
	(^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^ = max(max(0,
		(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^), width)
	return (^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^ != scwidth || rebuild_stc
}

// Draw vertical separator right of wp (C static).
draw_vsep_win_o :: proc "c"(wp: rawptr) {
	if (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 0 {
		return
	}

	dgv := (^GridView)(&default_gridview_u8)
	endrow := (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
	for row := (^C.int)(uintptr(wp) + W_WINROW_OFF)^; row < endrow; row += 1 {
		grid_line_start(dgv, row)
		grid_line_put_schar((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ +
			(^C.int)(uintptr(wp) + W_WIDTH_OFF)^,
			(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_VERT_O)^,
			win_hl_attr_o(wp, HLF_C_O))
		grid_line_flush()
	}
}

// Draw horizontal separator below wp (C static).
draw_hsep_win_o :: proc "c"(wp: rawptr) {
	if (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ == 0 {
		return
	}

	dgv := (^GridView)(&default_gridview_u8)
	endrow := (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
	grid_line_start(dgv, endrow)
	grid_line_fill((^C.int)(uintptr(wp) + W_WINCOL_OFF)^,
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + (^C.int)(uintptr(wp) + W_WIDTH_OFF)^,
		(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_HORIZ_O)^,
		win_hl_attr_o(wp, HLF_C_O))
	grid_line_flush()
}

// Update a single window (drawscreen.c:1420-2511; UPD_* semantics in doc above).
@(export)
win_update :: proc "c"(wp: rawptr) {
	// Overflow guard: window past shrunk terminal width.
	if ((^GridView)(uintptr(wp) + W_GRID_OFF)^).target == (^ScreenGrid)(&default_grid_u8) &&
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ >= Columns {
		return
	}

	top_end: C.int = 0
	mid_start: C.int = 999
	mid_end: C.int = 0
	bot_start: C.int = 999
	scrolled_down := false
	scrolled_for_mod := false
	top_to_mod := false

	bot_scroll_start: C.int = 999

	did_update: C.int = DID_NONE_O

	syntax_last_parsed: C.int = 0
	mod_top: C.int = 0
	mod_bot: C.int = 0

	type_ := (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^

	if type_ >= UPD_NOT_VALID {
		(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
		(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
	}

	// Zero-height: only the separator below.
	if (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ == 0 {
		draw_hsep_win_o(wp)
		(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = 0
		return
	}

	// Zero-width: only the separator right of it.
	if (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ == 0 {
		draw_vsep_win_o(wp)
		(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = 0
		return
	}

	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^

	// Reset got_int or regexp won't work.
	save_got_int := got_int
	got_int = false
	// Time limit from 'redrawtime'.
	syntax_tm := profile_setlimit_r(p_rdt_g)
	syn_set_timeout_r(transmute(rawptr)(&syntax_tm))

	win_extmark_arr_g.n = 0

	decor_redraw_reset_r(wp, transmute(rawptr)(&decor_state_g))

	decor_providers_invoke_win_r(wp)

	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
		terminal_suspended_r((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^) {
		susp_chunk_f = VirtTextChunk{text = transmute(^u8)cstring("[Process suspended]"), hl_id = -1}
		susp_vt_f = DecorVirtText_O{}
		susp_vt_f.prio = DECOR_PRIORITY_BASE_O
		susp_vt_f.pos = K_VPOS_WINCOL_O
		susp_vt_f.data.items = &susp_chunk_f
		susp_vt_f.data.n = 1
		line_count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		decor_range_add_virt_r(transmute(rawptr)(&decor_state_g),
			line_count - 1, 0, line_count - 1, 0, transmute(rawptr)(&susp_vt_f), false)
	}

	tp := curtab
	win := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for win != nil {
		if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf && win_redraw_signcols_o(win) {
			changed_line_abv_curs_win_r(win)
			redraw_later(win, UPD_NOT_VALID)
		}
		win = (^rawptr)(uintptr(win) + W_NEXT_OFF)^
	}
	(^C.int)(uintptr(buf) + B_SIGNCOLS_LAST_MAX_OFF)^ =
		(^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^

	// w_virtcol validation may change the redraw type.
	validate_virtcol_r(wp)
	type_ = (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^

	init_search_hl_r(wp, transmute(rawptr)(&screen_search_hl_u8))

	// Clamp skipcol to a valid tab stop.
	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 &&
		(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ > win_col_off_r(wp) {
		w: C.int = 0
		width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp)
		width2 := width1 + win_col_off2_r(wp)
		add := width1
		for w < (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ {
			if w > 0 {
				add = width2
			}
			w += add
		}
		if w != (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ {
			// Round down; the higher value may be invalid.
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = w - add
		}
	}

	nrwidth_before := (^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^
	nrwidth_new: C.int
	if (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
		(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 ||
		b_at((^u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF)^), 0) != 0 {
		nrwidth_new = number_width(wp)
	} else {
		nrwidth_new = 0
	}
	// Force redraw when number-column width changes.
	if (^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ != nrwidth_new {
		type_ = UPD_NOT_VALID
		changed_line_abv_curs_win_r(wp)
		(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ = nrwidth_new
	} else {
		// First line needing display for changes; first line after.
		mod_top = (^C.int)(uintptr(wp) + W_REDRAW_TOP_OFF)^
		if (^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ != 0 {
			mod_bot = (^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ + 1
		} else {
			mod_bot = 0
		}
		if (^bool)(uintptr(buf) + B_MOD_SET_OFF)^ {
			if mod_top == 0 || mod_top > (^C.int)(uintptr(buf) + B_MOD_TOP_OFF)^ {
				mod_top = (^C.int)(uintptr(buf) + B_MOD_TOP_OFF)^
				// Lines above the change may match a pattern.
				if syntax_present_r(wp) {
					mod_top -= (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_S_OFF)^) + uintptr(B_SYN_SYNC_LB_OFF))^
					mod_top = max(mod_top, 1)
				}
			}
			if mod_bot == 0 || mod_bot < (^C.int)(uintptr(buf) + B_MOD_BOT_OFF)^ {
				mod_bot = (^C.int)(uintptr(buf) + B_MOD_BOT_OFF)^
			}

			// Multi-line hlsearch/match: redraw all visible lines above.
			if (^rawptr)(transmute(rawptr)(&screen_search_hl_u8))^ != nil &&
				re_multiline_r((^rawptr)(transmute(rawptr)(&screen_search_hl_u8))^) {
				top_to_mod = true
			} else {
				cur := (^rawptr)(uintptr(wp) + W_MATCH_HEAD_OFF)^
				for cur != nil {
					if (^rawptr)(uintptr(cur) + MIT_MATCH_OFF)^ != nil &&
						re_multiline_r((^rawptr)(uintptr(cur) + MIT_MATCH_OFF)^) {
						top_to_mod = true
						break
					}
					cur = (^rawptr)(uintptr(cur) + MIT_NEXT_OFF)^
				}
			}
		}

		if search_hl_has_cursor_lnum_g > 0 {
			// CurSearch line needs redraw (avoid double highlight).
			if mod_top == 0 || mod_top > search_hl_has_cursor_lnum_g {
				mod_top = search_hl_has_cursor_lnum_g
			}
			if mod_bot == 0 || mod_bot < search_hl_has_cursor_lnum_g + 1 {
				mod_bot = search_hl_has_cursor_lnum_g + 1
			}
		}

		if mod_top != 0 && win_lines_concealed_r(wp) {
			// Change may fold/unfold lines above: find topmost affected.
			lnumt: C.int = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			lnumb: C.int = MAXLNUM
			for i: C.int = 0; i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^; i += 1 {
				wl := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)[uintptr(i)]
				lastlnum := (^C.int)(uintptr(&wl) + 12)^
				if wl.wl_valid {
					if lastlnum < mod_top {
						lnumt = lastlnum + 1
					}
					if lnumb == MAXLNUM && wl.wl_lnum >= mod_bot {
						lnumb = wl.wl_lnum
						// Fold column may need next-line update.
						if compute_foldcolumn(wp, 0) > 0 {
							lnumb += 1
						}
					}
				}
			}

			hasFolding(wp, mod_top, &mod_top, nil)
			mod_top = min(mod_top, lnumt)

			// Same for the bottom line (one above mod_bot).
			mod_bot -= 1
			hasFolding(wp, mod_bot, nil, &mod_bot)
			mod_bot += 1
			mod_bot = max(mod_bot, lnumb)
		}

		// Change starts above topline: start at topline, or redraw
		// first line for syntax if change ends above topline.
		if mod_top != 0 && mod_top < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			if mod_bot > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
				mod_top = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			} else if syntax_present_r(wp) {
				top_end = 1
			}
		}
	}

	(^C.int)(uintptr(wp) + W_REDRAW_TOP_OFF)^ = 0 // reset for next time
	(^C.int)(uintptr(wp) + W_REDRAW_BOT_OFF)^ = 0
	search_hl_has_cursor_lnum_g = 0

	// CHUNK-9b: top area + scroll/invert (C:1656-2027).
	UPD_REDRAW_TOP_O :: 30
	UPD_SOME_VALID_O :: 35
	UPD_INVERTED_ALL_O :: 25
	VALID_BOTLINE_O :: 0x20
	GETVCOL_END_EXCL_LBR_O :: 1
	K_OPT_VE_FLAG_BLOCK_O :: 0x05
	W_OLD_VISUAL_MODE_OFF :: 164
	W_OLD_CURSOR_FCOL_OFF :: 172
	W_OLD_CURSOR_LCOL_OFF :: 176
	W_OLD_CURSWANT_OFF :: 188

	// Top-only display (scrolled down for msg_scrolled).
	if type_ == UPD_REDRAW_TOP_O {
		j: C.int = 0
		for i: C.int = 0; i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^; i += 1 {
			j += C.int(([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)[uintptr(i)].wl_size)
			if j >= (^C.int)(uintptr(wp) + W_UPD_ROWS_OFF)^ {
				top_end = j
				break
			}
		}
		if top_end == 0 {
			// Not found (cannot happen?): redraw everything.
			type_ = UPD_NOT_VALID
		} else {
			// Top area defined, rest is UPD_VALID.
			type_ = UPD_VALID_O
		}
	}

	// Adjusted topline (concealed lines may sit below w_topline).
	topline_conceal := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	line_count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	for topline_conceal < line_count &&
		decor_conceal_line_r(wp, topline_conceal - 1, false) {
		topline_conceal += 1
		hasFolding(wp, topline_conceal, nil, &topline_conceal)
	}

	// Scroll stik: off-top (down), below-old-top (up), or same (find first stale).
	if (type_ == UPD_VALID_O || type_ == UPD_SOME_VALID_O ||
		type_ == UPD_INVERTED_F || type_ == UPD_INVERTED_ALL_O) &&
		!(^bool)(uintptr(wp) + W_BOTFILL_OFF)^ && !(^bool)(uintptr(wp) + W_OLD_BOTFILL_OFF)^ {
		lines0 := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
		if mod_top != 0 &&
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == mod_top &&
			(!lines0[0].wl_valid ||
				topline_conceal == lines0[0].wl_lnum) {
			// Topline is first changed line, not scrolled: changed-line
			// scrolling happens further down.
		} else if lines0[0].wl_valid &&
			(topline_conceal < lines0[0].wl_lnum ||
				(topline_conceal == lines0[0].wl_lnum &&
					(^C.int)(uintptr(wp) + W_TOPFILL)^ > (^C.int)(uintptr(wp) + W_OLD_TOPFILL_OFF)^)) {
			// New topline above old: may scroll down.
			j: C.int
			if win_lines_concealed_r(wp) {
				// Count off-lines (fold runs count once), skip concealed.
				j = 0
				ln := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
				for ln < lines0[0].wl_lnum {
					if !decor_conceal_line_r(wp, ln - 1, false) {
						j += 1
					}
					if j >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 2 {
						break
					}
					hasFolding(wp, ln, nil, &ln)
				}
			} else {
				j = lines0[0].wl_lnum - (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			}
			if j < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 2 { // not too far
				i := plines_m_win_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^,
					lines0[0].wl_lnum - 1, (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^)
				// Extra lines for previously invisible filler.
				if lines0[0].wl_lnum != (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					i += win_get_fill_r(wp, lines0[0].wl_lnum) -
						(^C.int)(uintptr(wp) + W_OLD_TOPFILL_OFF)^
				}
				if i != 0 && i < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 2 {
					// Insert lines; delete at bottom unless last window
					// (win_ins_lines may fail on dumb terminals).
					win_scroll_lines(wp, 0, i)
					bot_scroll_start = 0
					if (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ != 0 {
						// New rows first; stop at first scrolled-down one.
						top_end = i
						scrolled_down = true

						// Shift scrolled entries down; invalidate redrawn ones.
						(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ += j
						if (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ >
							(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
							(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ =
								(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
						}
						lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
						idx2 := (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^
						for idx2 - j >= 0 {
							lines[uintptr(idx2)] = lines[uintptr(idx2 - j)]
							idx2 -= 1
						}
						for idx2 >= 0 {
							lines[uintptr(idx2)].wl_valid = false
							idx2 -= 1
						}
					}
				} else {
					mid_start = 0 // redraw all lines
				}
			} else {
				mid_start = 0 // redraw all lines
			}
		} else {
			// New topline at/below old: may scroll up (or find first stale
			// entry when unchanged).

			// Find w_topline in w_lines[].wl_lnum.
			j := C.int(-1)
			row2: C.int = 0
			lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
			for i: C.int = 0; i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^; i += 1 {
				if lines[uintptr(i)].wl_valid &&
					lines[uintptr(i)].wl_lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					j = i
					break
				}
				row2 += C.int(lines[uintptr(i)].wl_size)
			}
			if j == -1 {
				// Topline not in w_lines[]: redraw all.
				mid_start = 0
			} else {
				// Delete the correct number of lines.
				if lines[0].wl_lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					row2 += (^C.int)(uintptr(wp) + W_OLD_TOPFILL_OFF)^
				} else {
					row2 += win_get_fill_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)
				}
				// ... but not new filler lines.
				row2 -= (^C.int)(uintptr(wp) + W_TOPFILL)^
				if row2 > 0 {
					win_scroll_lines(wp, 0, -row2)
					bot_start = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - row2
					bot_scroll_start = bot_start
				}
				if (row2 == 0 || bot_start < 999) &&
					(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ != 0 {
					// Skip still-valid lines below deleted ones: copy
					// their info up; bot_start is first redraw row.
					bot_start = 0
					idx2: C.int = 0
					for {
						lines[uintptr(idx2)] = lines[uintptr(j)]
						// Stop at a line that won't fit (unless valid).
						if row2 > 0 && bot_start + row2 +
							C.int(lines[uintptr(j)].wl_size) >
							(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
							(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = idx2 + 1
							break
						}
						bot_start += C.int(lines[uintptr(idx2)].wl_size)
						idx2 += 1

						// Stop at last valid w_lines[] entry.
						j += 1
						if j >= (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ {
							(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = idx2
							break
						}
					}

					// Fix first entry for top filler when not updated below.
					if win_may_fill_r(wp) && bot_start > 0 {
						lines[0].wl_size = u16(plines_correct_topline_r(wp,
							(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, nil, true, nil))
					}
				}
			}
		}

		// Redraw from the first line when starting there.
		if mid_start == 0 {
			mid_end = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
		}
	} else {
		// Not UPD_VALID/INVERTED: redraw all lines.
		mid_start = 0
		mid_end = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	}

	if type_ == UPD_SOME_VALID_O {
		// UPD_SOME_VALID: redraw all lines.
		mid_start = 0
		mid_end = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
		type_ = UPD_NOT_VALID
	}

	// Inverted-part (Visual) update or removal.
	if (VIsual_active && buf == (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) ||
		((^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ != 0 && type_ != UPD_NOT_VALID) {
		from: C.int
		to: C.int

		if VIsual_active {
			if VIsual_mode != (^C.int)(uintptr(wp) + W_OLD_VISUAL_MODE_OFF)^ ||
				type_ == UPD_INVERTED_ALL_O {
				// Visual type changed (or X selection ownership):
				// redraw the whole selection.
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < VIsual_g.lnum {
					from = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					to = VIsual_g.lnum
				} else {
					from = VIsual_g.lnum
					to = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				}
				// Redraw more when the cursor moved as well.
				from = min(min(from, (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^),
					(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^)
				to = max(max(to, (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^),
					(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^)
			} else {
				// Lines between old and current cursor + Visual moves.
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ <
					(^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ {
					from = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					to = (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^
				} else {
					from = (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^
					to = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					if from == 0 { // Visual just started
						from = to
					}
				}

				if VIsual_g.lnum != (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ ||
					VIsual_g.col != (^C.int)(uintptr(wp) + W_OLD_VISUAL_COL_OFF)^ {
					if (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ < from &&
						(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ != 0 {
						from = (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^
					}
					to = max(max(to, (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^), VIsual_g.lnum)
					from = min(from, VIsual_g.lnum)
				}
			}

			// Block mode with changed column/curswant: update all lines.
			if VIsual_mode == Ctrl_V {
				fromc: C.int
				toc: C.int
				getvcols_r(wp, &VIsual_g,
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF), &fromc, &toc, GETVCOL_END_EXCL_LBR_O)
				toc += 1
				// To end of line unless 'virtualedit' has "block".
				if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
					if get_ve_flags(curwin) & K_OPT_VE_FLAG_BLOCK_O != 0 {
						pos: Pos_T
						cursor_above := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < VIsual_g.lnum
						pos.coladd = 0

						// Longest line in the block.
						pos.lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
						for cursor_above ? pos.lnum <= VIsual_g.lnum : pos.lnum >= VIsual_g.lnum {
							t: C.int

							pos.col = ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum)
							getvvcol_r(wp, &pos, nil, nil, &t, 0)
							toc = max(toc, t)
							if cursor_above {
								pos.lnum += 1
							} else {
								pos.lnum -= 1
							}
						}
						toc += 1
					} else {
						toc = MAXCOL
					}
				}

				if fromc != (^C.int)(uintptr(wp) + W_OLD_CURSOR_FCOL_OFF)^ ||
					toc != (^C.int)(uintptr(wp) + W_OLD_CURSOR_LCOL_OFF)^ {
					from = min(from, VIsual_g.lnum)
					to = max(to, VIsual_g.lnum)
				}
				(^C.int)(uintptr(wp) + W_OLD_CURSOR_FCOL_OFF)^ = fromc
				(^C.int)(uintptr(wp) + W_OLD_CURSOR_LCOL_OFF)^ = toc
			}
		} else {
			// Old Visual area line numbers.
			if (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ <
				(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ {
				from = (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^
				to = (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^
			} else {
				from = (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^
				to = (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^
			}
		}

		// No need to update above the window top.
		from = max(from, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^)

		// Restrict to visible lines when w_botline is known.
		if (^C.int)(uintptr(wp) + W_VALID_OFF)^ & VALID_BOTLINE_O != 0 {
			from = min(from, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1)
			to = min(to, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1)
		}

		// Minimal part, watching for scroll-invalidated w_lines[].
		// (CTRL-U invalidates the first half + sets top_end; mouse
		// click may reset wl_valid above the Visual area: count for
		// mid_end via srow.)
		if mid_start > 0 {
			lnum2 := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			idx3: C.int = 0
			srow2: C.int = 0
			lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
			if scrolled_down {
				mid_start = top_end
			} else {
				mid_start = 0
			}
			for lnum2 < from && idx3 < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ { // find start
				if lines[uintptr(idx3)].wl_valid {
					mid_start += C.int(lines[uintptr(idx3)].wl_size)
				} else if !scrolled_down {
					srow2 += C.int(lines[uintptr(idx3)].wl_size)
				}
				idx3 += 1
				if idx3 < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ &&
					lines[uintptr(idx3)].wl_valid {
					lnum2 = lines[uintptr(idx3)].wl_lnum
				} else {
					lnum2 += 1
				}
			}
			srow2 += mid_start
			mid_end = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
			for ; idx3 < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^; idx3 += 1 { // find end
				if lines[uintptr(idx3)].wl_valid &&
					lines[uintptr(idx3)].wl_lnum >= to + 1 {
					// Only update until first row of this line.
					mid_end = srow2
					break
				}
				srow2 += C.int(lines[uintptr(idx3)].wl_size)
			}
		}
	}

	if VIsual_active && buf == (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ {
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_MODE_OFF)^ = VIsual_mode
		(^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ = VIsual_g.lnum
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_COL_OFF)^ = VIsual_g.col
		(^C.int)(uintptr(wp) + W_OLD_CURSWANT_OFF)^ = (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
	} else {
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_MODE_OFF)^ = 0
		(^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ = 0
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ = 0
		(^C.int)(uintptr(wp) + W_OLD_VISUAL_COL_OFF)^ = 0
	}

	cursorline_fi := Foldinfo_T{}
	win_update_cursorline(wp, &cursorline_fi)
	if wp == curwin {
		conceal_cursor_used_f = conceal_cursor_line(curwin)
	}

	win_check_ns_hl_r(wp)

	spv := Spellvars_O{}
	lnum := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ // first shown line
	// Spell vars for the first drawn line.
	if spell_check_window(wp) {
		spv.spv_has_spell = true
		spv.spv_unchanged = mod_top == 0
	}

	// CHUNK-9c: main row loop (C:2036-2358). Temp tail for 9d.
	W_DISPLAY_TICK_OFF :: 712 // w_display_tick (u64)
	VALID_TOPLINE_O :: 0x80 // buffer_defs.h:53
	W_VIEWPORT_INVALID_OFF :: 564 // w_viewport_invalid (bool, cc-probed)	W_EMPTY_ROWS_OFF :: 616 // w_empty_rows (int)
	W_FILLER_ROWS_OFF :: 620 // w_filler_rows (int)
	W_LAST_CURSORLINE_OFF :: 160 // w_last_cursorline
	W_LAST_CURSOR_LNUM_RNU_OFF :: 192
	K_OPT_DY_LASTLINE_O :: 0x01
	K_OPT_DY_TRUNCATE_O :: 0x02
	HLF_EOB_O :: 2
	FCS_EOB_O :: 68
	FCS_LASTLINE_O :: 72

	// Update all the window rows.
	idx: C.int = 0 // first w_lines[] entry
	row: C.int = 0 // current window row
	srow: C.int = 0 // starting row of the current line

	eof := false // hit the end of the file
	didline := false // finished the last line
	// Redo wrapper: post-loop redr_statuscol restarts the row loop (C goto).
	sc_redo := true
	for sc_redo {
		sc_redo = false
	for {
		// Past the end of the window: stop (checked at loop end too).
		if row == (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
			didline = true
			break
		}
		// End of the file: stop.
		if lnum > line_count {
			eof = true
			break
		}

		// Starting row of this line (used when it doesn't fit).
		srow = row

		lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
		// Update when in an area needing it, changed, or w_lines stale.
		// bot_start may sit mid-wrap after win_scroll_lines().
		// Syntax folding: states already updated, run to window end.
		if row < top_end ||
			(row >= mid_start && row < mid_end) ||
			top_to_mod ||
			idx >= (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ ||
			(row + C.int(lines[uintptr(idx)].wl_size) > bot_start) ||
			(mod_top != 0 &&
				(lnum == mod_top ||
					(lnum >= mod_top &&
						(lnum < mod_bot || did_update == DID_FOLD_O ||
							(did_update == DID_LINE_O && syntax_present_r(wp) &&
								((foldmethodIsSyntax(wp) && hasAnyFolding(wp) != 0) ||
									syntax_check_changed_r(lnum))) ||
							((^rawptr)(uintptr(wp) + W_MATCH_HEAD_OFF)^ != nil &&
								(^bool)(uintptr(buf) + B_MOD_SET_OFF)^ &&
								(^C.int)(uintptr(buf) + B_MOD_XLINES_OFF)^ != 0))))) ||
			lnum == (^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ ||
			lnum == (^C.int)(uintptr(wp) + W_LAST_CURSORLINE_OFF)^ {
			if lnum == mod_top {
				top_to_mod = false
			}

			// Folded lines display once; else normally (wraps possible).
			foldinfo: Foldinfo_T
			if (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 &&
				lnum == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
				foldinfo = cursorline_fi
			} else {
				foldinfo = fold_info(wp, lnum)
			}

			// Concealed line without filler: skip it.
			concealed := decor_conceal_line_r(wp, lnum - 1, false)
			if concealed && win_get_fill_r(wp, lnum) == 0 {
				if lnum == mod_top && lnum < mod_bot {
					if foldinfo.fi_lines != 0 {
						mod_top += foldinfo.fi_lines
					} else {
						mod_top += 1
					}
				}
				if foldinfo.fi_lines != 0 {
					lnum += foldinfo.fi_lines
				} else {
					lnum += 1
				}
				spv.spv_capcol_lnum = 0
				continue
			}

			// Start of changed lines: scroll followers to minimize redraw.
			// Not when the change runs to the end, nor for top-area
			// changes already scrolled above (but do scroll below).
			if !scrolled_for_mod && mod_bot != MAXLNUM &&
				lnum >= mod_top && lnum < max(mod_bot, mod_top + 1) &&
				(!scrolled_down || row >= top_end) {
				scrolled_for_mod = true

				old_cline_height: C.int = 0
				old_rows: C.int = 0
				l: C.int
				i: C.int

				// Old row count from w_lines[] (as currently displayed).
				i = idx
				for i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ {
					lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
					// Invalid lines belong to the changed area.
					if lines[uintptr(i)].wl_valid &&
						lines[uintptr(i)].wl_lnum == mod_bot {
						break
					}
					if lines[uintptr(i)].wl_lnum == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
						old_cline_height = C.int(lines[uintptr(i)].wl_size)
					}
					old_rows += C.int(lines[uintptr(i)].wl_size)
					if lines[uintptr(i)].wl_valid &&
						([^]C.int)(uintptr(&lines[uintptr(i)]) + 12)[0] + 1 == mod_bot {
						// Last valid entry above mod_bot: add following
						// invalid entries.
						i += 1
						for i < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ &&
							!lines[uintptr(i)].wl_valid {
							old_rows += C.int(lines[uintptr(i)].wl_size)
							i += 1
						}
						break
					}
					i += 1
				}

				if i >= (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ {
					// No valid line below changes: redraw to window end.
					bot_start = 0
					bot_scroll_start = 0
				} else {
					new_rows: C.int = 0
					// Count new rows; may insert/delete lines.
					j := idx
					l = lnum
					for l < mod_bot {
						if dollar_vcol >= 0 && wp == curwin &&
							old_cline_height > 0 && l == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
							// dollar_vcol: cursor line keeps its height.
							new_rows += old_cline_height
							j += 1
						} else {
							n := plines_correct_topline_r(wp, l, &l, true, nil)
							new_rows += n
							if n > 0 { // concealed lines don't count
								j += 1
							}
						}
						if new_rows > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - row - 2 {
							// Too much: redraw the rest.
							new_rows = 9999
							break
						}
					}
					xtra_rows := new_rows - old_rows
					if xtra_rows < 0 {
						// Scroll text up (or redraw rest when no room).
						if row - xtra_rows >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 2 {
							mod_bot = MAXLNUM
						} else {
							win_scroll_lines(wp, row, xtra_rows)
							bot_start = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + xtra_rows
							bot_scroll_start = bot_start
						}
					} else if xtra_rows > 0 {
						// Scroll text down (or redraw rest when no room).
						if row + xtra_rows >= (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 2 {
							mod_bot = MAXLNUM
						} else {
							win_scroll_lines(wp, row + old_rows, xtra_rows)
							bot_scroll_start = 0
							if top_end > row + old_rows {
								// Scrolled top part needing update down.
								top_end += xtra_rows
							}
						}
					}

					// Move w_lines[] entries unless updating the rest.
					if mod_bot != MAXLNUM && i != j {
						lines := ([^]Wline_T)((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
						if j < i {
							x := row + new_rows

							// Move entries upwards.
							for {
								// Stop at last valid w_lines[] entry.
								if i >= (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ {
									(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = j
									break
								}
								lines[uintptr(j)] = lines[uintptr(i)]
								// Stop at a line that won't fit.
								if x + C.int(lines[uintptr(j)].wl_size) >
									(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
									(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = j + 1
									break
								}
								x += C.int(lines[uintptr(j)].wl_size)
								j += 1
								i += 1
							}
							bot_start = min(bot_start, x)
						} else { // j > i: move entries downwards
							j -= i
							(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ += j
							if (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ >
								(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
								(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ =
									(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
							}
							for i = (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^;
								i - j >= idx; i -= 1 {
								lines[uintptr(i)] = lines[uintptr(i - j)]
							}

							// Inserted lines invalid (wl_size reused above:
							// reset to zero).
							for i >= idx {
								lines[uintptr(i)].wl_size = 0
								lines[uintptr(i)].wl_valid = false
								i -= 1
							}
						}
					}
				}
			}

			if foldinfo.fi_lines == 0 &&
				idx < (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ &&
				lines[uintptr(idx)].wl_valid &&
				lines[uintptr(idx)].wl_lnum == lnum &&
				lnum > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ &&
				(dy_flags_g & (K_OPT_DY_LASTLINE_O | K_OPT_DY_TRUNCATE_O)) == 0 &&
				srow + C.int(lines[uintptr(idx)].wl_size) >
					(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ &&
				win_get_fill_r(wp, lnum) == 0 {
				// Line won't fit: draw nothing, "@  " lines below.
				row = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + 1
			} else {
				prepare_search_hl_r(wp, transmute(rawptr)(&screen_search_hl_u8), lnum)
				// Tell syntax of skipped lines.
				if syntax_last_parsed != 0 && syntax_last_parsed + 1 < lnum &&
					syntax_present_r(wp) {
					syntax_end_parsing_r(wp, syntax_last_parsed + 1)
				}

				display_buf_line := !concealed &&
					(foldinfo.fi_lines == 0 ||
						b_at((^u8)((^rawptr)(uintptr(wp) + W_P_FDT_OFF)^), 0) == 0)

				// Display one line.
				zero_spv := Spellvars_O{}
				if display_buf_line {
					row = win_line(wp, lnum, srow,
						(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, 0, concealed,
						&spv, transmute(Wlv_Foldinfo)foldinfo)
				} else {
					row = win_line(wp, lnum, srow,
						(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, 0, concealed,
						&zero_spv, transmute(Wlv_Foldinfo)foldinfo)
				}

				if display_buf_line {
					syntax_last_parsed = lnum
				} else {
					spv.spv_capcol_lnum = 0
				}

				lastlnum := lnum + foldinfo.fi_lines -
					(foldinfo.fi_lines > 0 ? 1 : 0)
				lines[uintptr(idx)].wl_folded = foldinfo.fi_lines > 0
				lines[uintptr(idx)].wl_foldend = lastlnum
				(^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^ = lastlnum
				if foldinfo.fi_lines > 0 {
					did_update = DID_FOLD_O
				} else {
					did_update = DID_LINE_O
				}

				// Extend wl_lastlnum over concealed lines below (unless
				// below-virt_lines of this line still draw).
				virt_below := decor_virt_lines_r(wp, lastlnum, lastlnum + 1, nil, nil, true) > 0
				for !virt_below &&
					(^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^ < line_count &&
					decor_conceal_line_r(wp,
						(^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^, false) {
					virt_below = false
					(^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^ += 1
					hasFolding(wp, (^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^,
						nil, (^C.int)(uintptr(&lines[uintptr(idx)]) + 12))
				}
			}

			lines[uintptr(idx)].wl_lnum = lnum
			lines[uintptr(idx)].wl_valid = true

			is_curline := wp == curwin &&
				lnum == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^

			if row > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ { // past grid
				// Size of the too-long line may be needed later.
				if dollar_vcol == -1 || !is_curline {
					lines[uintptr(idx)].wl_size = u16(plines_win_r(wp, lnum, true))
				}
				idx += 1
				break
			}
			if dollar_vcol == -1 || !is_curline {
				lines[uintptr(idx)].wl_size = u16(row - srow)
			}
			lnum = (^C.int)(uintptr(&lines[uintptr(idx)]) + 12)^ + 1
			idx += 1
		} else {
			// Number column only (inserted/deleted lines below, or
			// relativenumber after vertical cursor move).
			if ((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 && mod_top != 0 && lnum >= mod_bot &&
				(^bool)(uintptr(buf) + B_MOD_SET_OFF)^ &&
				(^C.int)(uintptr(buf) + B_MOD_XLINES_OFF)^ != 0) ||
				((^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 &&
					(^C.int)(uintptr(wp) + W_LAST_CURSOR_LNUM_RNU_OFF)^ !=
						(^C.int)(uintptr(wp) + W_CURSOR_OFF)^) {
				info: Foldinfo_T
				if (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 &&
					lnum == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
					info = cursorline_fi
				} else {
					info = fold_info(wp, lnum)
				}
				win_line(wp, lnum, srow,
					(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^,
					C.int(lines[uintptr(idx)].wl_size), false, &spv,
					transmute(Wlv_Foldinfo)info)
			}

			// Line needs no draw: advance past it.
			row += C.int(lines[uintptr(idx)].wl_size)
			idx += 1
			if row > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ { // past screen
				break
			}
			lnum = (^C.int)(uintptr(&lines[uintptr(idx - 1)]) + 12)^ + 1
			did_update = DID_NONE_O
			spv.spv_capcol_lnum = 0
		}

		// 'statuscolumn' width changed or errored: restart from the top.
		if (^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ {
			(^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ = false
			idx = 0
			row = 0
			lnum = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WCOL_O)
			decor_redraw_reset_r(wp, transmute(rawptr)(&decor_state_g))
			decor_providers_invoke_win_r(wp)
			continue
		}

		if lnum > line_count {
			eof = true
			break
		}
	}
	// End of loop over all window lines.

	// Old and new cursor line redrawn: update w_last_cursorline.
	(^C.int)(uintptr(wp) + W_LAST_CURSORLINE_OFF)^ =
		(^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^

	if (^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
		(^C.int)(uintptr(wp) + W_LAST_CURSOR_LNUM_RNU_OFF)^ =
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	} else {
		(^C.int)(uintptr(wp) + W_LAST_CURSOR_LNUM_RNU_OFF)^ = 0
	}

	if (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ < idx {
		(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = idx
	}

	(^u64)(uintptr(wp) + W_DISPLAY_TICK_OFF)^ = display_tick_g

	// Syntax stops parsing here.
	if syntax_last_parsed != 0 && syntax_present_r(wp) {
		syntax_end_parsing_r(wp, syntax_last_parsed + 1)
	}

	old_botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^

	// Line didn't fit and file not exhausted: mark the overlay.
	(^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF)^ = 0
	if !eof && !didline {
		at_attr := hl_combine_attr_r(win_bg_attr_r(wp), win_hl_attr_o(wp, HLF_AT_O))
		if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
			// Single line that does not fit (editable, don't overwrite).
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum + 1
		} else if win_get_fill_r(wp, lnum) >=
			(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - srow {
			// Window ends in filler lines.
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
			(^C.int)(uintptr(wp) + W_FILLER_ROWS_OFF)^ =
				(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - srow
		} else if (dy_flags_g & K_OPT_DY_TRUNCATE_O) != 0 { // 'display' "truncate"
			// Last line unfinished: "@@@" in the last screen line.
			grid_line_start((^GridView)(uintptr(wp) + W_GRID_OFF),
				(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1)
			grid_line_fill(0, min((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^, 3),
				(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_LASTLINE_O)^,
				at_attr)
			grid_line_fill(3, (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^,
				32, at_attr) // schar_from_ascii(' ')
			grid_line_flush()
			set_empty_rows_r(wp, srow)
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
		} else if (dy_flags_g & K_OPT_DY_LASTLINE_O) != 0 { // 'display' "lastline"
			// Last line unfinished: "@@@" at the end ( "@@@@" if it would
			// split a doublewidth char).
			grid_line_start((^GridView)(uintptr(wp) + W_GRID_OFF),
				(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - 1)
			width: C.int = grid_line_getchar(
				max((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - 3, 0), nil) == 0 ? 4 : 3
			grid_line_fill(max((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - width, 0),
				(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^,
				(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_LASTLINE_O)^,
				at_attr)
			grid_line_flush()
			set_empty_rows_r(wp, srow)
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
		} else {
			win_draw_end(wp,
				(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_LASTLINE_O)^,
				true, srow, (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, HLF_AT_O)
			set_empty_rows_r(wp, srow)
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
		}
	} else {
		if eof { // end of the file
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = line_count + 1
			j := win_get_fill_r(wp, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^)
			if j > 0 && !(^bool)(uintptr(wp) + W_BOTFILL_OFF)^ &&
				row < (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
				// Filler text below last line (win_line handles
				// ml_line_count+1 as filler-only).
				zero_spv := Spellvars_O{}
				zero_foldinfo := Foldinfo_T{}
				row = win_line(wp, (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^, row,
					(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, 0, false,
					&zero_spv, transmute(Wlv_Foldinfo)zero_foldinfo)
				if (^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ {
					eof = false
					// redr_statuscol: restart from the top (C goto).
					(^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ = false
					idx = 0
					row = 0
					lnum = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
					(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
					(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WCOL_O)
					decor_redraw_reset_r(wp, transmute(rawptr)(&decor_state_g))
					decor_providers_invoke_win_r(wp)
					sc_redo = true
					continue
				}
			}
		} else if dollar_vcol == -1 || wp != curwin {
			(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = lnum
		}

		// Blank the rest ("eob" fillchar on non-file rows).
		// TODO(bfredl): track the valid EOB area from last redraw.
		lastline := bot_scroll_start
		if mid_end >= row {
			lastline = min(lastline, mid_start)
		}
		if mod_bot > line_count {
			lastline = 0
		}

		win_draw_end(wp,
			(^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_EOB_O)^,
			false, max(lastline, row),
			(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, HLF_EOB_O)
		set_empty_rows_r(wp, row)
	}

	if (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ >= UPD_REDRAW_TOP_O {
		draw_vsep_win_o(wp)
		draw_hsep_win_o(wp)
	}
	syn_set_timeout_r(nil)

	// Window updated: reset redraw type and fillers.
	(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_OLD_TOPFILL_OFF)^ = (^C.int)(uintptr(wp) + W_TOPFILL)^
	(^bool)(uintptr(wp) + W_OLD_BOTFILL_OFF)^ = (^bool)(uintptr(wp) + W_BOTFILL_OFF)^

	// Send win_extmarks if needed.
	we_n := win_extmark_arr_g.n
	we_grid := (^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF)
	for we_i: C.size_t = 0; we_i < we_n; we_i += 1 {
		m := win_extmark_arr_g.items[uintptr(we_i)]
		ui_call_win_extmark_r(C.longlong(we_grid.handle),
			(^C.int)(uintptr(wp) + W_HANDLE_OFF)^, C.longlong(m.ns_id),
			C.longlong(m.mark_id), C.longlong(m.win_row), C.longlong(m.win_col))
	}

	if dollar_vcol == -1 || wp != curwin {
		// w_botline is approximated (plines_win() is expensive): validate
		// w_topline when it was wrong (cursor off-screen). Mostly just
		// scrolls up a bit; current window only.
		(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_BOTLINE_O
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = true
		if wp == curwin && (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ != old_botline &&
			!recursive_f {
			recursive_f = true
			(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_TOPLINE_O)
			update_topline_r(curwin) // may invalidate w_botline again
			// New redraw from updated topline or reset skipcol.
			if must_redraw != 0 {
				// Don't update for buffer changes again.
				mod_set := (^bool)(uintptr(curbuf) + B_MOD_SET_OFF)^
				(^bool)(uintptr(curbuf) + B_MOD_SET_OFF)^ = false
				curs_columns_r(curwin, 1)
				win_update(curwin)
				must_redraw = 0
				(^bool)(uintptr(curbuf) + B_MOD_SET_OFF)^ = mod_set
			}
			recursive_f = false
		}
	}

	if nrwidth_before != (^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ &&
		(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^)
	}

	// Restore got_int, unless CTRL-C hit while redrawing.
	if !got_int {
		got_int = save_got_int
	}
	} // closes redo wrapper (sc_redo)
}

// ── Batch 6: grid alloc + screenclear ─────────────────────────────────────────

NO_SCREEN_O :: 2 // globals.h:91
UPD_CLEAR_O :: 50 // drawscreen.h:18
DEFAULT_GRID_HANDLE_O :: 1 // grid.h:22
HLF_MSG_O :: 63 // Message area (counted hlf_T order)

// File-statics (drawscreen.c:134-135).
@(private="file")
redraw_popupmenu_f: bool = false
@(private="file")
msg_grid_invalid_f: bool = false
@(private="file")
resizing_f: bool = false // default_grid_alloc re-entry guard

foreign _ {
	@(link_name = "tab_page_click_defs")
	tab_page_click_defs_g: rawptr
	@(link_name = "tab_page_click_defs_size")
	tab_page_click_defs_size_g: C.size_t
	@(link_name = "stl_alloc_click_defs")
	stl_alloc_click_defs_r :: proc "c"(cdp: rawptr, width: C.int, size: ^C.size_t) -> rawptr ---
	@(link_name = "ui_call_grid_clear")
	ui_call_grid_clear_r :: proc "c"(grid: C.longlong) ---
	@(link_name = "ui_comp_set_screen_valid")
	ui_comp_set_screen_valid_r :: proc "c"(valid: bool) -> bool ---
	@(link_name = "cmdline_was_last_drawn")
	cmdline_was_last_drawn_g: bool
	@(link_name = "msg_didany")
	msg_didany_g: bool
	@(link_name = "pum_invalidate")
	pum_invalidate_r :: proc "c"() ---
	@(link_name = "msg_reset_scroll")
	msg_reset_scroll_r :: proc "c"() ---
	@(link_name = "msg_use_grid")
	msg_use_grid_r :: proc "c"() -> bool ---
	@(link_name = "msg_grid")
	msg_grid_u8: u8 // address-of only (ScreenGrid)
}

// Resize default_grid to Rows and Columns; true when resized.
@(export)
default_grid_alloc :: proc "c"() -> bool {
	// OOM message below may re-enter; break the loop.
	if resizing_f {
		return false
	}
	resizing_f = true

	dg := (^ScreenGrid)(&default_grid_u8)
	// Only realloc when size changed and set.
	if ((dg.chars != nil && Rows == dg.rows && Columns == dg.cols) ||
		Rows == 0 || Columns == 0) {
		resizing_f = false
		return false
	}

	// Changing size: alloc new arrays (copies lines), free old.
	// On failure arrays are NULL — never keep wrong-sized arrays.
	grid_alloc(dg, Rows, Columns, true, true)

	stl_clear_click_defs_r(tab_page_click_defs_g, tab_page_click_defs_size_g)
	tab_page_click_defs_g = stl_alloc_click_defs_r(tab_page_click_defs_g, Columns,
		&tab_page_click_defs_size_g)

	dg.comp_height = Rows
	dg.comp_width = Columns

	dg.handle = DEFAULT_GRID_HANDLE_O

	resizing_f = false
	return true
}

@(export)
screenclear :: proc "c"() {
	msg_check_for_delay_r(false)

	dg := (^ScreenGrid)(&default_grid_u8)
	if starting == NO_SCREEN_O || dg.chars == nil {
		return
	}

	// Blank out the default grid.
	for i: C.int = 0; i < dg.rows; i += 1 {
		grid_clear_line(dg, dg.line_offset[uintptr(i)], dg.cols, true)
	}

	ui_call_grid_clear_r(1) // clear the display
	ui_comp_set_screen_valid_r(true)

	ns_hl_fast_g = -1

	clear_cmdline_g = false
	mode_displayed_g = false

	redraw_all_later(UPD_NOT_VALID)
	cmdline_was_last_drawn_g = false
	redraw_cmdline_g = true
	redraw_tabline_opt = true
	redraw_popupmenu_f = true
	pum_invalidate_r()
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
			(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ = UPD_CLEAR_O
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if must_redraw == UPD_CLEAR_O {
		must_redraw = UPD_NOT_VALID // no need to clear again
	}
	compute_cmdrow_r()
	msg_row = cmdline_row // cursor on last line for messages
	msg_col = 0
	msg_reset_scroll_r() // can't scroll back
	msg_didany_g = false
	msg_didout_g = false
	if hl_attr_active_g[HLF_MSG_O] > 0 && msg_use_grid_r() &&
		(^rawptr)(uintptr(transmute(rawptr)(&msg_grid_u8)) + 8)^ != nil {
		mg := (^ScreenGrid)(&msg_grid_u8)
		grid_invalidate(mg)
		msg_grid_validate_r()
		msg_grid_invalid_f = false
		clear_cmdline_g = true
	}
}
