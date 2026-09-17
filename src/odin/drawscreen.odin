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

	redrawWinline_r(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)

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
