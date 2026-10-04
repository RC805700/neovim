package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// winfloat.c port: floating windows (create/config/remove/anchor/valid).
// All 14 publics are @(export); float_zindex_cmp + error cleanup are plains.

foreign _ {
	@(link_name = "nvim_create_buf")
	nvim_create_buf_e :: proc "c" (listed: bool, scratch: bool, err: rawptr) -> i64 ---
	@(link_name = "find_buffer_by_handle")
	find_buffer_by_handle_e :: proc "c" (buffer: i64, err: rawptr) -> rawptr ---
	@(link_name = "mouse_find_win_inner")
	mouse_find_win_inner_e :: proc "c" (gridp: ^C.int, rowp: ^C.int, colp: ^C.int) -> rawptr ---
}

// WinConfig relative offsets (cc-probed; WinConfig size 480).
WCFG_REL_WINDOW_O :: 0
WCFG_REL_BUFPOS_COL_O :: 8
WCFG_REL_HEIGHT_O :: 12
WCFG_REL_WIDTH_O :: 16
WCFG_REL_ROW_O :: 24
WCFG_REL_COL_O :: 32
WCFG_REL_ANCHOR_O :: 40
WCFG_REL_EXTERNAL_O :: 48
WCFG_REL_BORDER_O :: 64
WCFG_REL_NOAUTOCMD_O :: 468
// relative@44/focusable@49/mouse@50/zindex@56/style@60/border@64/
// border_chars@66/border_hl_ids@324/hide@470 reuse window.odin's WCFG_REL_*.

KFLOAT_REL_CURSOR_O :: 2
KFLOAT_REL_MOUSE_O :: 3
KFLOAT_REL_EDITOR_O :: 0
K_ERRTYPE_EXC_O :: 0 // kErrorTypeException (api/private/defs.h)

W_P_STL_OFF_O :: 1096 // w_p_stl slot (cc-probed: w_onebuf_opt@816 + wo_stl@280)
W_P_FCS_OFF_O :: 1208 // w_p_fcs slot (cc-probed)
W_P_FCS_EOB_OFF_O :: 348 // w_p_fcs_chars.eob schar (cc-probed)
W_FLOAT_IS_INFO_OFF :: 10554 // w_float_is_info (cc-probed)

// Creates a new float, or transforms an existing window into a float.
@(export)
win_new_float :: proc "c" (wp_in: rawptr, last: bool, fconfig_in: WinConfig_Opaque, err: rawptr) -> rawptr {
	context = runtime.default_context()
	wp := wp_in
	fc := fconfig_in
	fbase := rawptr(&fc)
	if wp == nil {
		tp: rawptr = nil
		tp_last := lastwin_g
		if !last {
			tp_last = lastwin_nofloating(nil)
		}
		if (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_WINDOW_O))^ != 0 {
			if last {
				libc.abort()
			}
			parent_wp := find_window_by_handle_r((^C.int)(rawptr(uintptr(fbase) + WCFG_REL_WINDOW_O))^, err)
			if parent_wp == nil {
				return nil
			}
			tp = win_find_tabpage(parent_wp)
			if tp == nil {
				return nil
			}
			if tp == curtab {
				tp_last = lastwin_nofloating(nil)
			} else {
				tp_last = lastwin_nofloating(tp)
			}
		}
		wp = win_alloc(tp_last, false)
		win_init(wp, curwin, 0)
		wbr := (^rawptr)(uintptr(wp) + W_P_WBR_OFF)^
		if wbr != nil && (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_HEIGHT_O))^ == 1 {
			if transmute(^u8)(wbr) != empty_string_opt() {
				free_string_option(transmute(^u8)(wbr))
			}
			(^rawptr)(uintptr(wp) + W_P_WBR_OFF)^ = rawptr(empty_string_opt())
		}
		stl := (^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^
		if stl != nil && transmute(^u8)(stl) != empty_string_opt() {
			free_string_option(transmute(^u8)(stl))
			(^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^ = rawptr(empty_string_opt())
		}
	} else {
		if last {
			libc.abort()
		}
		if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
			libc.abort()
		}
		win_tp := win_find_tabpage(wp)
		if win_tp == nil {
			libc.abort()
		}
		if (win_tp == curtab && firstwin == wp && lastwin_nofloating(nil) == wp) || (win_tp != curtab && (^rawptr)(uintptr(win_tp) + TP_FIRSTWIN_OFF)^ == wp && lastwin_nofloating(win_tp) == wp) {
			api_set_error_r(err, K_ERRTYPE_EXC_O, cstring("Cannot change last window into float"), nil)
			return nil
		}
		tp: rawptr = nil
		if win_tp != curtab {
			tp = win_tp
		}
		dir: C.int
		winframe_remove(wp, &dir, tp, nil)
		fr := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
		xfree(fr)
		(^rawptr)(uintptr(wp) + W_FRAME_OFF)^ = nil
		win_remove(wp, tp)
		if win_tp == curtab {
			last_status(false)
			win_comp_pos()
		}
		win_append(lastwin_nofloating(tp), wp, tp)
	}
	(^bool)(uintptr(wp) + W_FLOATING_OFF)^ = true
	stl2 := (^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^
	show := stl2 != nil && ([^]u8)(rawptr(stl2))[0] != 0 && (p_ls_g == 1 || p_ls_g == 2)
	sh: C.int = 0
	if show {
		sh = STATUS_HEIGHT_O
	}
	(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = sh
	(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 0
	win_config_float(wp, fc)
	redraw_later(wp, UPD_VALID_O)
	return wp
}

@(export)
win_set_minimal_style :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(wp) + W_P_NU_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_P_CUL_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_P_CUC_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_P_SPELL_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_P_LIST_OFF)^ = 0
	if ([^]u32)(rawptr(uintptr(wp) + W_P_FCS_CHARS_OFF + 68))[0] != u32(' ') {
		old := (^u8)((^rawptr)(uintptr(wp) + W_P_FCS_OFF_O)^)
		if old^ == 0 {
			(^rawptr)(uintptr(wp) + W_P_FCS_OFF_O)^ = rawptr(xstrdup(transmute(^u8)(cstring("eob: "))))
		} else {
			(^rawptr)(uintptr(wp) + W_P_FCS_OFF_O)^ = rawptr(concat_str(transmute(cstring)(old), cstring(",eob: ")))
		}
		free_string_option(old)
	}
	old := (^u8)((^rawptr)(uintptr(wp) + W_P_WINHL_OFF)^)
	if old^ == 0 {
		(^rawptr)(uintptr(wp) + W_P_WINHL_OFF)^ = rawptr(xstrdup(transmute(^u8)(cstring("EndOfBuffer:"))))
	} else {
		(^rawptr)(uintptr(wp) + W_P_WINHL_OFF)^ = rawptr(concat_str(transmute(cstring)(old), cstring(",EndOfBuffer:")))
	}
	free_string_option(old)
	parse_winhl_opt((^u8)((^rawptr)(uintptr(wp) + W_P_WINHL_OFF)^), wp)
	scl := (^u8)((^rawptr)(uintptr(wp) + W_P_SCL_OFF)^)
	if scl^ != 'a' || libc.strlen(transmute(cstring)(scl)) >= 8 {
		free_string_option(scl)
		(^rawptr)(uintptr(wp) + W_P_SCL_OFF)^ = rawptr(xstrdup(transmute(^u8)(cstring("auto"))))
	}
	fdc := (^u8)((^rawptr)(uintptr(wp) + W_P_FDC_OFF)^)
	if fdc^ != '0' {
		free_string_option(fdc)
		(^rawptr)(uintptr(wp) + W_P_FDC_OFF)^ = rawptr(xstrdup(transmute(^u8)(cstring("0"))))
	}
	cc := (^rawptr)(uintptr(wp) + W_P_CC_OFF)^
	if cc != nil && ([^]u8)(rawptr(cc))[0] != 0 {
		free_string_option(transmute(^u8)(cc))
		(^rawptr)(uintptr(wp) + W_P_CC_OFF)^ = rawptr(xstrdup(transmute(^u8)(cstring(""))))
	}
	stc := (^rawptr)(uintptr(wp) + W_P_STC_OFF)^
	if stc != nil && ([^]u8)(rawptr(stc))[0] != 0 {
		free_string_option(transmute(^u8)(stc))
		(^rawptr)(uintptr(wp) + W_P_STC_OFF)^ = rawptr(empty_string_opt())
	}
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		stl := (^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^
		if stl != nil && ([^]u8)(rawptr(stl))[0] != 0 {
			free_string_option(transmute(^u8)(stl))
			(^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^ = rawptr(empty_string_opt())
			if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ > 0 {
				win_config_float(wp, (^WinConfig_Opaque)(uintptr(wp) + W_CONFIG_OFF)^)
			}
		}
	}
}

@(export)
win_border_height :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	adj := ([^]C.int)(uintptr(wp) + W_BORDER_ADJ_OFF)
	return adj[0] + adj[2]
}

@(export)
win_border_width :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	adj := ([^]C.int)(uintptr(wp) + W_BORDER_ADJ_OFF)
	return adj[1] + adj[3]
}

@(export)
win_config_float :: proc "c" (wp: rawptr, fconfig_in: WinConfig_Opaque) {
	context = runtime.default_context()
	fc := fconfig_in
	fbase := rawptr(&fc)
	stl := (^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^
	show_stl := stl != nil && ([^]u8)(rawptr(stl))[0] != 0 && (p_ls_g == 1 || p_ls_g == 2)
	if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0 && !show_stl {
		win_remove_status_line(wp, false)
	} else if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ == 0 && show_stl {
		(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
	}
	w := (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_WIDTH_O))^
	if w < 1 {
		w = 1
	}
	(^C.int)(uintptr(wp) + W_WIDTH_OFF)^ = w
	h := (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_HEIGHT_O))^
	if h < 1 {
		h = 1
	}
	(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ = h
	if (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_RELATIVE_OFF))^ == KFLOAT_REL_CURSOR_O {
		(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_RELATIVE_OFF))^ = KFLOAT_REL_WINDOW_O
		(^f64)(rawptr(uintptr(fbase) + WCFG_REL_ROW_O))^ += f64((^C.int)(uintptr(curwin) + W_WROW_OFF)^)
		(^f64)(rawptr(uintptr(fbase) + WCFG_REL_COL_O))^ += f64((^C.int)(uintptr(curwin) + W_WCOL_OFF)^)
		(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_WINDOW_O))^ = (^C.int)(uintptr(curwin) + W_HANDLE_OFF)^
	} else if (^C.int)(rawptr(uintptr(fbase) + WCFG_REL_RELATIVE_OFF))^ == KFLOAT_REL_MOUSE_O {
		row := mouse_row
		col := mouse_col
		grid := mouse_grid
		mouse_win := mouse_find_win_inner_e(&grid, &row, &col)
		if mouse_win != nil {
			(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_RELATIVE_OFF))^ = KFLOAT_REL_WINDOW_O
			(^f64)(rawptr(uintptr(fbase) + WCFG_REL_ROW_O))^ += f64(row)
			(^f64)(rawptr(uintptr(fbase) + WCFG_REL_COL_O))^ += f64(col)
			(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_WINDOW_O))^ = (^C.int)(uintptr(mouse_win) + W_HANDLE_OFF)^
		}
	}
	change_external := ([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_EXTERNAL_O))[0] != ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_EXTERNAL_O))[0]
	change_border := ([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_BORDER_O))[0] != ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_BORDER_O))[0] || libc.memcmp(rawptr(uintptr(fbase) + 324), rawptr(uintptr(wp) + W_CONFIG_OFF + 324), 32) != 0
	merge_win_config(rawptr(uintptr(wp) + W_CONFIG_OFF), fc)
	has_border := (^bool)(uintptr(wp) + W_FLOATING_OFF)^ && ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_BORDER_O))[0] != 0
	adj := ([^]C.int)(uintptr(wp) + W_BORDER_ADJ_OFF)
	for i: C.int = 0; i < 4; i += 1 {
		new_adj: C.int = 0
		if has_border && ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 66))[(2 * i + 1) * 32] != 0 {
			new_adj = 1
		}
		if new_adj != adj[i] {
			change_border = true
			adj[i] = new_adj
		}
	}
	if !ui_has(K_UIMULTIGRID_O) {
		above_ch: C.int = 0
		if (^C.int)(uintptr(wp) + W_CONFIG_OFF + 56)^ < KZINDEX_MESSAGES_O {
			above_ch = C.int(p_ch)
		}
		(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ = min((^C.int)(uintptr(wp) + W_HEIGHT_OFF)^, Rows - win_border_height(wp) - above_ch)
		(^C.int)(uintptr(wp) + W_WIDTH_OFF)^ = min((^C.int)(uintptr(wp) + W_WIDTH_OFF)^, Columns - win_border_width(wp))
	}
	win_set_inner_size(wp, true)
	set_must_redraw(UPD_VALID_O)
	(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0
	(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
	if change_external || change_border {
		(^C.int)(uintptr(wp) + W_HL_NEEDS_UPDATE_OFF)^ = 1
		redraw_later(wp, UPD_NOT_VALID)
	}
	if (^C.int)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_RELATIVE_OFF)^ == KFLOAT_REL_WINDOW_O {
		row := C.int((^f64)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_ROW_O)^)
		col := C.int((^f64)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_COL_O)^)
		dummy := Api_Error{typ = -1}
		parent := find_window_by_handle_r((^C.int)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_WINDOW_O)^, rawptr(&dummy))
		if parent != nil {
			row += (^C.int)(uintptr(parent) + W_WINROW_OFF)^
			col += (^C.int)(uintptr(parent) + W_WINCOL_OFF)^
			grid_adjust((^GridView)(uintptr(parent) + W_GRID_OFF), &row, &col)
			if (^C.int)(uintptr(wp) + W_CONFIG_OFF + 4)^ >= 0 {
				pos := Pos_T{}
				lc := (^C.int)(uintptr((^rawptr)(uintptr(parent) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^
				bl := (^C.int)(uintptr(wp) + W_CONFIG_OFF + 4)^ + 1
				if bl < lc {
					lc = bl
				}
				pos.lnum = lc
				pos.col = (^C.int)(uintptr(wp) + W_CONFIG_OFF + 8)^
				trow, tcol, tcolc, tcole: C.int
				textpos2screenpos(parent, &pos, &trow, &tcol, &tcolc, &tcole, true)
				row += trow - 1
				col += tcol - 1
			}
		}
		api_clear_error_r(&dummy)
		(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = row
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = col
	} else {
		(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = C.int((^f64)(rawptr(uintptr(fbase) + WCFG_REL_ROW_O))^)
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = C.int((^f64)(rawptr(uintptr(fbase) + WCFG_REL_COL_O))^)
	}
	if ([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_BORDER_O))[0] != 0 {
		(^bool)(uintptr(wp) + W_REDR_BORDER_OFF)^ = true
		redraw_later(wp, UPD_VALID_O)
	}
}

prof_float_cmp_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	a := (^rawptr)(s1)^
	b := (^rawptr)(s2)^
	za := (^C.int)(uintptr(a) + W_CONFIG_OFF + 56)^
	zb := (^C.int)(uintptr(b) + W_CONFIG_OFF + 56)^
	if za == zb {
		return 0
	}
	if za < zb {
		return 1
	}
	return -1
}

@(export)
win_float_remove :: proc "c" (bang: bool, count_in: C.int) {
	context = runtime.default_context()
	count := count_in
	size: C.size_t = 0
	capa: C.size_t = 0
	items: [^]rawptr = nil
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		if ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 470))[0] == 0 && (^C.int)(uintptr(wp) + W_P_WP_OFF)^ == 0 {
			if size >= capa {
				if capa == 0 {
					capa = 8
				} else {
					capa *= 2
				}
				items = ([^]rawptr)(xrealloc(rawptr(items), capa * C.size_t(size_of(rawptr))))
			}
			items[size] = wp
			size += 1
		}
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
	if size > 0 {
		qsort_e(rawptr(items), size, C.size_t(size_of(rawptr)), prof_float_cmp_o)
	}
	i: C.size_t = 0
	for i < size {
		w := items[i]
		if win_valid(w) && win_close(w, false, false) == FAIL_E {
			break
		}
		if !bang {
			count -= 1
			if count == 0 {
				break
			}
		}
		i += 1
	}
	xfree(rawptr(items))
}

@(export)
win_check_anchored_floats :: proc "c" (win: rawptr) {
	context = runtime.default_context()
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		if (^C.int)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_RELATIVE_OFF)^ == KFLOAT_REL_WINDOW_O && (^C.int)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_WINDOW_O)^ == (^C.int)(uintptr(win) + W_HANDLE_OFF)^ {
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		}
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
}

@(export)
win_float_update_statusline :: proc "c" () {
	context = runtime.default_context()
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		has_status := (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ > 0
		stl := (^rawptr)(uintptr(wp) + W_P_STL_OFF_O)^
		should_show := stl != nil && ([^]u8)(rawptr(stl))[0] != 0 && (p_ls_g == 1 || p_ls_g == 2)
		if should_show != has_status {
			win_config_float(wp, (^WinConfig_Opaque)(uintptr(wp) + W_CONFIG_OFF)^)
		}
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
}

@(export)
win_float_anchor_laststatus :: proc "c" () {
	context = runtime.default_context()
	wp := firstwin
	if curtab != nil {
		wp = (^rawptr)(uintptr(curtab) + TP_FIRSTWIN_OFF)^
	}
	for wp != nil {
		if (^C.int)(uintptr(wp) + W_CONFIG_OFF + WCFG_REL_RELATIVE_OFF)^ == KFLOAT_REL_LASTSTATUS_O {
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

@(export)
win_reconfig_floats :: proc "c" () {
	context = runtime.default_context()
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		win_config_float(wp, (^WinConfig_Opaque)(uintptr(wp) + W_CONFIG_OFF)^)
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
}

// True when win is a floating window in the current tab page.
@(export)
win_float_valid :: proc "c" (win: rawptr) -> bool {
	context = runtime.default_context()
	if win == nil {
		return false
	}
	wp := firstwin
	if curtab != nil {
		wp = (^rawptr)(uintptr(curtab) + TP_FIRSTWIN_OFF)^
	}
	for wp != nil {
		if wp == win {
			return (^bool)(uintptr(wp) + W_FLOATING_OFF)^
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return false
}

@(export)
win_float_find_preview :: proc "c" () -> rawptr {
	context = runtime.default_context()
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		if (^bool)(uintptr(wp) + W_FLOAT_IS_INFO_OFF)^ {
			return wp
		}
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
	return nil
}

// Alternative window for a closing/moving float.
@(export)
win_float_find_altwin :: proc "c" (win: rawptr, tp: rawptr) -> rawptr {
	context = runtime.default_context()
	wp := prevwin_g
	if tp == nil {
		if win_valid(wp) && wp != win && ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 49))[0] != 0 && ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 470))[0] == 0 {
			return wp
		}
		return firstwin
	}
	if tp == curtab {
		libc.abort()
	}
	if tabpage_win_valid(tp, (^rawptr)(uintptr(tp) + TP_PREVWIN_OFF)^) {
		wp = (^rawptr)(uintptr(tp) + TP_PREVWIN_OFF)^
	} else {
		wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	}
	if ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 49))[0] != 0 && ([^]u8)(rawptr(uintptr(wp) + W_CONFIG_OFF + 470))[0] == 0 {
		return wp
	}
	return (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
}

handle_error_and_cleanup_o :: proc "c" (wp: rawptr, err: ^Api_Error) -> rawptr {
	context = runtime.default_context()
	if ERROR_SET(rawptr(err)) {
		emsg(transmute(cstring)(err.msg))
		api_clear_error_r(err)
	}
	if wp != nil {
		win_remove(wp, nil)
		win_free(wp, nil)
	}
	unblock_autocmds_r()
	return nil
}

// Creates a floating preview window.
@(export)
win_float_create_preview :: proc "c" (enter: bool, new_buf: bool) -> rawptr {
	context = runtime.default_context()
	fc := WinConfig_Opaque{}
	fbase := rawptr(&fc)
	(^f64)(rawptr(uintptr(fbase) + WCFG_REL_COL_O))^ = f64((^C.int)(uintptr(curwin) + W_WCOL_OFF)^)
	(^f64)(rawptr(uintptr(fbase) + WCFG_REL_ROW_O))^ = f64((^C.int)(uintptr(curwin) + W_WROW_OFF)^)
	(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_RELATIVE_OFF))^ = KFLOAT_REL_EDITOR_O
	([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_MOUSE))[0] = 1
	([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_NOAUTOCMD_O))[0] = 1
	([^]u8)(rawptr(uintptr(fbase) + WCFG_REL_HIDE))[0] = 1
	(^C.int)(rawptr(uintptr(fbase) + WCFG_REL_STYLE))^ = K_WIN_STYLE_MINIMAL_O
	err := Api_Error{typ = -1}
	block_autocmds_r()
	wp := win_new_float(nil, false, fc, rawptr(&err))
	if wp == nil {
		return handle_error_and_cleanup_o(wp, &err)
	}
	if new_buf {
		b := nvim_create_buf_e(false, true, rawptr(&err))
		if b == 0 {
			return handle_error_and_cleanup_o(wp, &err)
		}
		buf := find_buffer_by_handle_e(b, rawptr(&err))
		if buf == nil {
			return handle_error_and_cleanup_o(wp, &err)
		}
		(^C.int)(uintptr(buf) + B_P_BL_OFF)^ = 0
		set_option_direct_for(kOptBufhidden_E, str_optval(transmute(^u8)(cstring("wipe")), 4), OPT_LOCAL_S, 0, kOptScopeBuf_S, buf)
		win_set_buf(wp, buf, rawptr(&err))
		if ERROR_SET(rawptr(&err)) {
			return handle_error_and_cleanup_o(wp, &err)
		}
	}
	unblock_autocmds_r()
	(^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ = 0
	(^bool)(uintptr(wp) + W_FLOAT_IS_INFO_OFF)^ = true
	(^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ = 1
	(^C.longlong)(uintptr(wp) + W_P_SO_OFF)^ = 0
	if enter {
		win_enter(wp, false)
	}
	return wp
}
