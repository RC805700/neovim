// window.odin — port of src/nvim/window.c (window/tabpage model)
package main

import C "core:c"
import "core:c/libc"

// ── Batch 1: pure window-list predicates ─────────────────────────────────────

W_HANDLE_OFF :: 0
TP_FIRSTWIN_OFF :: 40
TP_NEXT_OFF :: 8
W_NEXT_OFF :: 112
W_PREV_OFF :: 104

// firstwin/first_tabpage/curtab/curwin from main.odin;
// W_FLOATING_OFF (10553) from option.odin.

// Check if "win" is a pointer to an existing window in the current tabpage.
@(export)
win_valid :: proc "c"(win: rawptr) -> bool {
	return tabpage_win_valid(curtab, win)
}

// Check if "win" is a pointer to an existing window in tabpage "tp".
@(export)
tabpage_win_valid :: proc "c"(tp: rawptr, win: rawptr) -> bool {
	if win == nil {
		return false
	}
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if wp == win {
			return true
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return false
}

// Find window "handle" in the current tab page.
// Return NULL if not found.
@(export)
win_find_by_handle :: proc "c"(handle: C.int) -> rawptr {
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if (^C.int)(uintptr(wp) + W_HANDLE_OFF)^ == handle {
			return wp
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return nil
}

// Check if "win" is a pointer to an existing window in any tabpage.
@(export)
win_valid_any_tab :: proc "c"(win: rawptr) -> bool {
	if win == nil {
		return false
	}

	// NOTE: FOR_ALL_TAB_WINDOWS uses tp == curtab ? firstwin for the
	// inner walk (firstwin and tp_firstwin can transiently diverge) —
	// replicate exactly, do NOT walk tp_firstwin unconditionally.
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if wp == win {
				return true
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	return false
}

// Return the number of windows.
@(export)
win_count :: proc "c"() -> C.int {
	count: C.int = 0
	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		count += 1
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return count
}

// Check if "win" is the last non-floating window that exists.
@(export)
last_window :: proc "c"(win: rawptr) -> bool {
	return one_window(win, nil) && (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil
}

// Check if "win" is the only non-floating window in tabpage "tp",
// or NULL for current tabpage.
@(export)
one_window :: proc "c"(win: rawptr, tp: rawptr) -> bool {
	first := tp != nil ? (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ : firstwin
	if first != win {
		return false
	}
	next := (^rawptr)(uintptr(win) + W_NEXT_OFF)^
	return next == nil || (^bool)(uintptr(next) + W_FLOATING_OFF)^
}

// ── Batch 2: small predicates ────────────────────────────────────────────────

W_P_FDC_OFF :: 840
W_P_WFB_OFF :: 992

E1513_S :: "E1513: Cannot switch buffer. 'winfixbuf' is enabled"

foreign _ {
	@(link_name = "is_in_cmdwin")
	is_in_cmdwin_r :: proc "c" () -> bool ---
	@(link_name = "prevwin")
	prevwin_g: rawptr
}
// getDeepestNesting/emsg/curwin reused from sibling files.

@(export)
win_fdccol_count :: proc "c"(wp: rawptr) -> C.int {
	fdc := (^^u8)(uintptr(wp) + W_P_FDC_OFF)^

	// auto:<NUM>
	if libc.strncmp(transmute(cstring)(fdc), "auto", 4) == 0 {
		fdccol := b_at(fdc, 4) == ':' ? C.int(b_at(fdc, 5)) - '0' : 1
		needed_fdccols := getDeepestNesting(wp)
		return min(fdccol, needed_fdccols)
	}
	return C.int(b_at(fdc, 0)) - '0'
}

// @return the current window, unless in the cmdline window and "prevwin" is
// set, then return "prevwin".
@(export)
prevwin_curwin :: proc "c"() -> rawptr {
	// In cmdwin, the alternative buffer should be used.
	return is_in_cmdwin_r() && prevwin_g != nil ? prevwin_g : curwin
}

// Check if the current window is allowed to move to a different buffer.
//
// @return If the window has 'winfixbuf', or this function will return false.
@(export)
check_can_set_curbuf_disabled :: proc "c"() -> bool {
	if (^C.int)(uintptr(curwin) + W_P_WFB_OFF)^ != 0 {
		emsg(cstring(E1513_S))
		return false
	}

	return true
}

// Check if the current window is allowed to move to a different buffer.
//
// @param forceit If true, do not error. If false and 'winfixbuf' is enabled, error.
//
// @return If the window has 'winfixbuf', then forceit must be true
//     or this function will return false.
@(export)
check_can_set_curbuf_forceit :: proc "c"(forceit: C.int) -> bool {
	if forceit == 0 && (^C.int)(uintptr(curwin) + W_P_WFB_OFF)^ != 0 {
		emsg(cstring(E1513_S))
		return false
	}

	return true
}

// ── Batch 3: frame leaf + layout locks ───────────────────────────────────────

FR_WIN_OFF :: 56
FR_CHILD_OFF :: 48

CMD_TABNEW_O :: 465
CMD_SIZE_O :: 561
K_ERROR_TYPE_EXCEPTION_O :: 2

E1159_S :: "E1159: Cannot split a window when closing the buffer"
E1312_S :: "E1312: Not allowed to change the window layout in this autocmd"

foreign _ {
	@(link_name = "nvim_odin_get_frame_locked")
	nvim_odin_get_frame_locked_r :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_frame_locked_inc")
	nvim_odin_frame_locked_inc_r :: proc "c" () ---
	@(link_name = "nvim_odin_frame_locked_dec")
	nvim_odin_frame_locked_dec_r :: proc "c" () ---
	@(link_name = "nvim_odin_window_layout_lock")
	nvim_odin_window_layout_lock_r :: proc "c" () ---
	@(link_name = "nvim_odin_window_layout_unlock")
	nvim_odin_window_layout_unlock_r :: proc "c" () ---
	@(link_name = "nvim_odin_get_split_disallowed")
	nvim_odin_get_split_disallowed_r :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_get_close_disallowed")
	nvim_odin_get_close_disallowed_r :: proc "c" () -> C.int ---
}
// api_set_error_r/api_clear_error_r/emsg reused from option.odin.

@(export)
frame2win :: proc "c"(frp: rawptr) -> rawptr {
	fr := frp
	for (^rawptr)(uintptr(fr) + FR_WIN_OFF)^ == nil {
		fr = (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
	}
	return (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
}

@(export)
frames_locked :: proc "c"() -> bool {
	return nvim_odin_get_frame_locked_r() != 0
}

frame_locked_inc_o :: proc "c"() {
	nvim_odin_frame_locked_inc_r()
}

frame_locked_dec_o :: proc "c"() {
	nvim_odin_frame_locked_dec_r()
}

@(export)
window_layout_lock :: proc "c"() {
	nvim_odin_window_layout_lock_r()
}

@(export)
window_layout_unlock :: proc "c"() {
	nvim_odin_window_layout_unlock_r()
}

@(export)
window_layout_locked :: proc "c"(cmd: C.int) -> bool {
	err: Api_Error
	err.typ = -1 // kErrorTypeNone
	err.msg = nil
	locked := window_layout_locked_err(cmd, &err)
	if err.typ != -1 {
		emsg(transmute(cstring)(err.msg))
		api_clear_error_r(&err)
	}
	return locked
}

// Like `window_layout_locked`, but set `err` to the (untranslated) error
// message when locked.
@(export)
window_layout_locked_err :: proc "c"(cmd: C.int, err: ^Api_Error) -> bool {
	if nvim_odin_get_split_disallowed_r() > 0 || nvim_odin_get_close_disallowed_r() > 0 {
		if nvim_odin_get_close_disallowed_r() == 0 && cmd == CMD_TABNEW_O {
			api_set_error_r(err, K_ERROR_TYPE_EXCEPTION_O, "%s",
				transmute(rawptr)(cstring(E1159_S)))
		} else {
			api_set_error_r(err, K_ERROR_TYPE_EXCEPTION_O, "%s",
				transmute(rawptr)(cstring(E1312_S)))
		}
		return true
	}
	return false
}

// ── Batch 4: structural frame helpers (C-static; plain procs for Batch 5) ────

FR_LAYOUT_OFF :: 0
FR_PARENT_OFF :: 24
FR_NEXT_OFF :: 32
FR_HEIGHT_OFF :: 12
FR_WIDTH_OFF :: 4
TP_CURWIN_OFF :: 24
FR_PREV_OFF :: 40
W_FRAME_OFF :: 128
W_P_WFH_OFF :: 996
W_P_WFW_OFF :: 1000
W_VSEP_WIDTH_OFF :: 452
W_WIDTH_OFF :: 444
W_WINROW_OFF :: 416
W_WINCOL_OFF :: 440
W_HSEP_HEIGHT_OFF :: 448
W_POS_CHANGED_OFF :: 10552

FR_LEAF_O :: 0
FR_ROW_O :: 1
FR_COL_O :: 2

K_OPT_TCL_FLAG_LEFT_O :: 0x01
K_OPT_TCL_FLAG_USELAST_O :: 0x02

foreign _ {
	@(link_name = "topframe")
	topframe_g: rawptr
	@(link_name = "lastused_tabpage")
	lastused_tabpage_g: rawptr
	@(link_name = "tcl_flags")
	tcl_flags_g: C.uint
	@(link_name = "p_sb")
	p_sb_g: C.int
 	@(link_name = "p_spr")
 	p_spr_g: C.int
}
// redraw_later_r/UPD_NOT_VALID/xfree/first_tabpage/firstwin/curwin/curtab/
// one_window/frame2win reused.

frame_fixed_height_o :: proc "c" (wp_frame: rawptr) -> bool {
	frp := wp_frame
	// frame with one window: fixed height if 'winfixheight' set.
	if (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil {
		return (^C.int)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFH_OFF)^ != 0
	}
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		// The frame is fixed height if one of the frames in the row is fixed
		// height.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			if frame_fixed_height_o(child) {
				return true
			}
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
		return false
	}

	// fr_layout == FR_COL: fixed if all frames are fixed height.
	child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	for child != nil {
		if !frame_fixed_height_o(child) {
			return false
		}
		child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
	}
	return true
}

frame_fixed_width_o :: proc "c" (wp_frame: rawptr) -> bool {
	frp := wp_frame
	// frame with one window: fixed width if 'winfixwidth' set.
	if (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil {
		return (^C.int)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFW_OFF)^ != 0
	}
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		// The frame is fixed width if one of the frames in the col is fixed
		// width.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			if frame_fixed_width_o(child) {
				return true
			}
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
		return false
	}

	// fr_layout == FR_ROW: fixed if all frames are fixed width.
	child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	for child != nil {
		if !frame_fixed_width_o(child) {
			return false
		}
		child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
	}
	return true
}

frame_set_vsep_o :: proc "c" (frp_in: rawptr, add: bool) {
	frp := frp_in
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		wp := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
		if add && (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 0 {
			if (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ > 0 { // don't make it negative
				win_new_width(wp, (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ - 1)
			}
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 1
		} else if !add && (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 1 {
			win_new_width(wp, (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ + 1)
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 0
		}
	} else if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		// Handle all the frames in the column.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			frame_set_vsep_o(child, add)
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
	} else {
		// Only need to handle the last frame in the row.
		fr := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
		frame_set_vsep_o(fr, add)
	}
}

frame_remove_o :: proc "c" (frp: rawptr) {
	prev := (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
	next := (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	if prev != nil {
		(^rawptr)(uintptr(prev) + FR_NEXT_OFF)^ = next
	} else {
		parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
		(^rawptr)(uintptr(parent) + FR_CHILD_OFF)^ = next
	}
	if next != nil {
		(^rawptr)(uintptr(next) + FR_PREV_OFF)^ = prev
	}
}

frame_flatten_o :: proc "c" (frp_in: rawptr) {
	frp := frp_in
	if (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil ||
	(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
		return
	}

	// There is no other frame in this list, move its info to the parent
	// and remove it.
	parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
	(^u8)(uintptr(parent) + FR_LAYOUT_OFF)^ = b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0)
	(^rawptr)(uintptr(parent) + FR_CHILD_OFF)^ = (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	frp2 := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	for frp2 != nil {
		(^rawptr)(uintptr(frp2) + FR_PARENT_OFF)^ = parent
		frp2 = (^rawptr)(uintptr(frp2) + FR_NEXT_OFF)^
	}
	(^rawptr)(uintptr(parent) + FR_WIN_OFF)^ = (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
	if (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil {
		(^rawptr)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_FRAME_OFF)^ = parent
	}
	frp2 = parent
	if (^rawptr)(uintptr(topframe_g) + FR_CHILD_OFF)^ == frp {
		(^rawptr)(uintptr(topframe_g) + FR_CHILD_OFF)^ = frp2
	}
	xfree(frp)

	frp = (^rawptr)(uintptr(frp2) + FR_PARENT_OFF)^
	if frp != nil && b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) ==
	b_at((^u8)(uintptr(frp2) + FR_LAYOUT_OFF), 0) {
		// The frame above the parent has the same layout, have to merge
		// the frames into this list.
		if (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^ == frp2 {
			(^rawptr)(uintptr(frp) + FR_CHILD_OFF)^ = (^rawptr)(uintptr(frp2) + FR_CHILD_OFF)^
		}
		frp2_child := (^rawptr)(uintptr(frp2) + FR_CHILD_OFF)^
		(^rawptr)(uintptr(frp2_child) + FR_PREV_OFF)^ = (^rawptr)(uintptr(frp2) + FR_PREV_OFF)^
		if (^rawptr)(uintptr(frp2) + FR_PREV_OFF)^ != nil {
			(^rawptr)(uintptr((^rawptr)(uintptr(frp2) + FR_PREV_OFF)^) + FR_NEXT_OFF)^ = frp2_child
		}
		frp3 := frp2_child
		for {
			(^rawptr)(uintptr(frp3) + FR_PARENT_OFF)^ = frp
			if (^rawptr)(uintptr(frp3) + FR_NEXT_OFF)^ == nil {
				(^rawptr)(uintptr(frp3) + FR_NEXT_OFF)^ = (^rawptr)(uintptr(frp2) + FR_NEXT_OFF)^
				if (^rawptr)(uintptr(frp2) + FR_NEXT_OFF)^ != nil {
					(^rawptr)(uintptr((^rawptr)(uintptr(frp2) + FR_NEXT_OFF)^) + FR_PREV_OFF)^ = frp3
				}
				break
			}
			frp3 = (^rawptr)(uintptr(frp3) + FR_NEXT_OFF)^
		}
	}
}

frame_comp_pos_o :: proc "c" (topfrp: rawptr, row: ^C.int, col: ^C.int) {
	wp := (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^
	if wp != nil {
		if (^C.int)(uintptr(wp) + W_WINROW_OFF)^ != row^ ||
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ != col^ {
			// position changed, redraw
			(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = row^
			(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = col^
			redraw_later_r(wp, UPD_NOT_VALID)
			(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		}
		h := (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ +
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ +
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^
		fr_h := (^C.int)(uintptr(topfrp) + FR_HEIGHT_OFF)^
		row^ += h > fr_h ? fr_h : h
		col^ += (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ +
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
	} else {
		startrow := row^
		startcol := col^
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
				row^ = startrow // all frames are at the same row
			} else {
				col^ = startcol // all frames are at the same col
			}
			frame_comp_pos_o(frp, row, col)
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	}
}

// Return the tabpage that will be used if the current one is closed.
alt_tabpage_o :: proc "c" () -> rawptr {
	// Use the last accessed tab page, if possible.
	if (tcl_flags_g & K_OPT_TCL_FLAG_USELAST_O) != 0 && valid_tabpage(lastused_tabpage_g) {
		return lastused_tabpage_g
	}

	// Use the next tab page, if possible.
	forward := (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^ != nil &&
		((tcl_flags_g & K_OPT_TCL_FLAG_LEFT_O) == 0 || curtab == first_tabpage)

	tp: rawptr
	if forward {
		tp = (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
	} else {
		// Use the previous tab page.
		tp = first_tabpage
		for (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != curtab {
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
	}

	return tp
}

win_altframe_o :: proc "c" (win: rawptr, tp: rawptr) -> rawptr {
	if one_window(win, tp) {
		return (^rawptr)(uintptr(alt_tabpage_o()) + TP_CURWIN_OFF)^
	}

	frp := (^rawptr)(uintptr(win) + W_FRAME_OFF)^

	if (^rawptr)(uintptr(frp) + FR_PREV_OFF)^ == nil {
		return (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	}
	if (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ == nil {
		return (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
	}

	// By default the next window will get the space that was abandoned by this
	// window
	target_fr := (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	other_fr := (^rawptr)(uintptr(frp) + FR_PREV_OFF)^

	// If this is part of a column of windows and 'splitbelow' is true then the
	// previous window will get the space.
	parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
	if parent != nil && b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
	p_sb_g != 0 {
		target_fr = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
		other_fr = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	}

	// If this is part of a row of windows, and 'splitright' is true then the
	// previous window will get the space.
	if parent != nil && b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
	p_spr_g != 0 {
		target_fr = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
		other_fr = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	}

	// If 'wfh' or 'wfw' is set for the target and not for the alternate
	// window, reverse the selection.
	if parent != nil && b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		if frame_fixed_width_o(target_fr) && !frame_fixed_width_o(other_fr) {
			target_fr = other_fr
		}
	} else {
		if frame_fixed_height_o(target_fr) && !frame_fixed_height_o(other_fr) {
			target_fr = other_fr
		}
	}

	return target_fr
}

// ── Batch 5: winframe_remove cluster (exports + static helpers) ──────────────

W_WINBAR_HEIGHT_OFF :: 436
STATUS_HEIGHT_O :: 1

foreign _ {
	@(link_name = "nvim_odin_get_min_set_ch")
	nvim_odin_get_min_set_ch_r :: proc "c" () -> C.longlong ---
	@(link_name = "nvim_odin_set_min_set_ch")
	nvim_odin_set_min_set_ch_r :: proc "c" (v: C.longlong) ---
}
// set_option_value/num_optval/Rows/p_ch/kOptCmdheight_E/global_stl_height_r reused.

is_bottom_win_o :: proc "c" (wp: rawptr) -> bool {
	frp := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	for (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ != nil {
		parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
		if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
		(^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
			return false
		}
		frp = parent
	}
	return true
}

frame_minheight_o :: proc "c" (topfrp: rawptr, next_curwin: rawptr) -> C.int {
	m: C.int = 0

	if (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^ != nil {
		wp := (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^
		// Combined height of window bar and separator column or status line.
		extra_height := (^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ +
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ +
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^

		if wp == next_curwin {
			m = C.int(p_wh_opt) + extra_height
		} else {
			m = C.int(p_wmh_opt) + extra_height
			if wp == curwin && next_curwin == nil {
				// Current window is minimal one line high.
				if p_wmh_opt == 0 {
					m += 1
				}
			}
		}
	} else if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		// get the minimal height from each frame in this row
		m = 0
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			n := frame_minheight_o(frp, next_curwin)
			if n > m {
				m = n
			}
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	} else {
		// Add up the minimal heights for all frames in this column.
		m = 0
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			m += frame_minheight_o(frp, next_curwin)
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	}

	return m
}

frame_minwidth_o :: proc "c" (topfrp: rawptr, next_curwin: rawptr) -> C.int {
	m: C.int = 0

	if (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^ != nil {
		wp := (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^
		if wp == next_curwin {
			m = C.int(p_wiw_opt) + (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
		} else {
			// window: minimal width of the window plus separator column
			m = C.int(p_wmw_opt) + (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
			// Current window is minimal one column wide
			if p_wmw_opt == 0 && wp == curwin && next_curwin == nil {
				m += 1
			}
		}
	} else if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		// get the minimal width from each frame in this column
		m = 0
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			n := frame_minwidth_o(frp, next_curwin)
			if n > m {
				m = n
			}
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	} else {
		// Add up the minimal widths for all frames in this row.
		m = 0
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			m += frame_minwidth_o(frp, next_curwin)
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	}

	return m
}

@(export)
frame_new_height :: proc "c"(topfrp: rawptr, height_in: C.int, topfirst: bool, wfh: bool, set_ch: bool) {
	height := height_in
	if (^rawptr)(uintptr(topfrp) + FR_PARENT_OFF)^ == nil && set_ch {
		// topframe: update the command line height, with side effects.
		new_ch := max(nvim_odin_get_min_set_ch_r(),
			C.longlong(p_ch) + C.longlong((^C.int)(uintptr(topfrp) + FR_HEIGHT_OFF)^) - C.longlong(height))
		if new_ch != C.longlong(p_ch) {
			save_ch := nvim_odin_get_min_set_ch_r()
			set_option_value(kOptCmdheight_E, num_optval(new_ch), 0)
			nvim_odin_set_min_set_ch_r(save_ch)
		}
		height = min(Rows - C.int(p_ch) - 		tabline_height() - 		global_stl_height(), height)
	}
	if (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^ != nil {
		// Simple case: just one window.
		wp := (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^
		if is_bottom_win_o(wp) {
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 0
		}
		win_new_height(wp, height - (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ -
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^)
	} else if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		frp: rawptr
		for {
			// All frames in this row get the same new height.
			done := true
			child := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
			for child != nil {
				frp = child
				frame_new_height(child, height, topfirst, wfh, set_ch)
				if (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ > height {
					// Could not fit the windows, make the whole row higher.
					height = (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^
					done = false
					break
				}
				child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
			}
			if done {
				frp = nil
			}
			if frp == nil {
				break
			}
		}
	} else { // fr_layout == FR_COL
		// Complicated case: Resize a column of frames.  Resize the bottom
		// frame first, frames above that when needed.

		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		if wfh {
			// Advance past frames with one window with 'wfh' set.
			for frame_fixed_height_o(frp) {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
				if frp == nil {
					return // no frame without 'wfh', give up
				}
			}
		}
		if !topfirst {
			// Find the bottom frame of this column
			for (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			if wfh {
				// Advance back for frames with one window with 'wfh' set.
				for frame_fixed_height_o(frp) {
					frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
				}
			}
		}

		extra_lines := height - (^C.int)(uintptr(topfrp) + FR_HEIGHT_OFF)^
		if extra_lines < 0 {
			// reduce height of contained frames, bottom or top frame first
			for frp != nil {
				h := frame_minheight_o(frp, nil)
				if (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ + extra_lines < h {
					extra_lines += (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - h
					frame_new_height(frp, h, topfirst, wfh, set_ch)
				} else {
					frame_new_height(frp, (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ + extra_lines,
						topfirst, wfh, set_ch)
					break
				}
				if topfirst {
					for {
						frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
						if !(wfh && frp != nil && frame_fixed_height_o(frp)) {
							break
						}
					}
				} else {
					for {
						frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
						if !(wfh && frp != nil && frame_fixed_height_o(frp)) {
							break
						}
					}
				}
				// Increase "height" if we could not reduce enough frames.
				if frp == nil {
					height -= extra_lines
				}
			}
		} else if extra_lines > 0 {
			// increase height of bottom or top frame
			frame_new_height(frp, (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ + extra_lines,
				topfirst, wfh, set_ch)
		}
	}
	(^C.int)(uintptr(topfrp) + FR_HEIGHT_OFF)^ = height
}

@(export)
frame_new_width :: proc "c"(topfrp: rawptr, width_in: C.int, leftfirst: bool, wfw: bool) {
	width := width_in
	if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		// Simple case: just one window.
		wp := (^rawptr)(uintptr(topfrp) + FR_WIN_OFF)^
		// Find out if there are any windows right of this one.
		frp := topfrp
		for (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ != nil {
			parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
			if b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
			(^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
				break
			}
			frp = parent
		}
		if (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ == nil {
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 0
		}
		win_new_width(wp, width - (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^)
	} else if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		frp: rawptr
		for {
			// All frames in this column get the same new width.
			done := true
			child := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
			for child != nil {
				frp = child
				frame_new_width(frp, width, leftfirst, wfw)
				if (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ > width {
					// Could not fit the windows, make whole column wider.
					width = (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^
					done = false
					break
				}
				child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
			}
			if done {
				frp = nil
			}
			if frp == nil {
				break
			}
		}
	} else { // fr_layout == FR_ROW
		// Complicated case: Resize a row of frames.  Resize the rightmost
		// frame first, frames left of it when needed.

		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		if wfw {
			// Advance past frames with one window with 'wfw' set.
			for frame_fixed_width_o(frp) {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
				if frp == nil {
					return // no frame without 'wfw', give up
				}
			}
		}
		if !leftfirst {
			// Find the rightmost frame of this row
			for (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			if wfw {
				// Advance back for frames with one window with 'wfw' set.
				for frame_fixed_width_o(frp) {
					frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
				}
			}
		}

		extra_cols := width - (^C.int)(uintptr(topfrp) + FR_WIDTH_OFF)^
		if extra_cols < 0 {
			// reduce frame width, rightmost frame first
			for frp != nil {
				w := frame_minwidth_o(frp, nil)
				if (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ + extra_cols < w {
					extra_cols += (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - w
					frame_new_width(frp, w, leftfirst, wfw)
				} else {
					frame_new_width(frp, (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ + extra_cols,
						leftfirst, wfw)
					break
				}
				if leftfirst {
					for {
						frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
						if !(wfw && frp != nil && frame_fixed_width_o(frp)) {
							break
						}
					}
				} else {
					for {
						frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
						if !(wfw && frp != nil && frame_fixed_width_o(frp)) {
							break
						}
					}
				}
				// Increase "width" if we could not reduce enough frames.
				if frp == nil {
					width -= extra_cols
				}
			}
		} else if extra_cols > 0 {
			// increase width of rightmost frame
			frame_new_width(frp, (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ + extra_cols,
				leftfirst, wfw)
		}
	}
	(^C.int)(uintptr(topfrp) + FR_WIDTH_OFF)^ = width
}

@(export)
winframe_find_altwin :: proc "c"(win: rawptr, dirp: ^C.int, tp: rawptr, altfr: ^rawptr) -> rawptr {
	// If there is only one non-floating window there is nothing to remove.
	if one_window(win, tp) {
		return nil
	}

	frp_close := (^rawptr)(uintptr(win) + W_FRAME_OFF)^

	// Find the window and frame that gets the space.
	frp2 := win_altframe_o(win, tp)
	wp := frame2win(frp2)

	if b_at((^u8)(uintptr((^rawptr)(uintptr(frp_close) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		// When 'winfixheight' is set, try to find another frame in the column
		// (as close to the closed frame as possible) to distribute the height
		// to.
		frp2_win := (^rawptr)(uintptr(frp2) + FR_WIN_OFF)^
		if frp2_win != nil && (^C.int)(uintptr(frp2_win) + W_P_WFH_OFF)^ != 0 {
			frp := (^rawptr)(uintptr(frp_close) + FR_PREV_OFF)^
			frp3 := (^rawptr)(uintptr(frp_close) + FR_NEXT_OFF)^
			for frp != nil || frp3 != nil {
				if frp != nil {
					if !frame_fixed_height_o(frp) {
						frp2 = frp
						wp = frame2win(frp2)
						break
					}
					frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
				}
				if frp3 != nil {
					frp3_win := (^rawptr)(uintptr(frp3) + FR_WIN_OFF)^
					if frp3_win != nil && (^C.int)(uintptr(frp3_win) + W_P_WFH_OFF)^ == 0 {
						frp2 = frp3
						wp = frp3_win
						break
					}
					frp3 = (^rawptr)(uintptr(frp3) + FR_NEXT_OFF)^
				}
			}
		}
		dirp^ = 'v'
	} else {
		// When 'winfixwidth' is set, try to find another frame in the column
		// (as close to the closed frame as possible) to distribute the width
		// to.
		frp2_win := (^rawptr)(uintptr(frp2) + FR_WIN_OFF)^
		if frp2_win != nil && (^C.int)(uintptr(frp2_win) + W_P_WFW_OFF)^ != 0 {
			frp := (^rawptr)(uintptr(frp_close) + FR_PREV_OFF)^
			frp3 := (^rawptr)(uintptr(frp_close) + FR_NEXT_OFF)^
			for frp != nil || frp3 != nil {
				if frp != nil {
					if !frame_fixed_width_o(frp) {
						frp2 = frp
						wp = frame2win(frp2)
						break
					}
					frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
				}
				if frp3 != nil {
					frp3_win := (^rawptr)(uintptr(frp3) + FR_WIN_OFF)^
					if frp3_win != nil && (^C.int)(uintptr(frp3_win) + W_P_WFW_OFF)^ == 0 {
						frp2 = frp3
						wp = frp3_win
						break
					}
					frp3 = (^rawptr)(uintptr(frp3) + FR_NEXT_OFF)^
				}
			}
		}
		dirp^ = 'h'
	}

	if altfr != nil {
		altfr^ = frp2
	}

	return wp
}

@(export)
winframe_remove :: proc "c"(win: rawptr, dirp: ^C.int, tp: rawptr, unflat_altfr: ^rawptr) -> rawptr {	altfr: rawptr = nil
	wp := winframe_find_altwin(win, dirp, tp, &altfr)
	if wp == nil {
		return nil
	}

	frp_close := (^rawptr)(uintptr(win) + W_FRAME_OFF)^

	frame_locked_inc_o()

	// Save the position of the containing frame (which will also contain the
	// altframe) before we remove anything, to recompute window positions later.
	parent := (^rawptr)(uintptr(frp_close) + FR_PARENT_OFF)^
	topleft := frame2win(parent)
	row := (^C.int)(uintptr(topleft) + W_WINROW_OFF)^
	col := (^C.int)(uintptr(topleft) + W_WINCOL_OFF)^

	// If this is a rightmost window, remove vertical separators to the left.
	if (^C.int)(uintptr(win) + W_VSEP_WIDTH_OFF)^ == 0 &&
	b_at((^u8)(uintptr(parent) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
	(^rawptr)(uintptr(frp_close) + FR_PREV_OFF)^ != nil {
		frame_set_vsep_o((^rawptr)(uintptr(frp_close) + FR_PREV_OFF)^, false)
	}

	// Remove this frame from the list of frames.
	frame_remove_o(frp_close)

	if dirp^ == 'v' {
		frame_new_height(altfr,
			(^C.int)(uintptr(altfr) + FR_HEIGHT_OFF)^ +
			(^C.int)(uintptr(frp_close) + FR_HEIGHT_OFF)^,
			altfr == (^rawptr)(uintptr(frp_close) + FR_NEXT_OFF)^, false, false)
	} else {
		frame_new_width(altfr,
			(^C.int)(uintptr(altfr) + FR_WIDTH_OFF)^ +
			(^C.int)(uintptr(frp_close) + FR_WIDTH_OFF)^,
			altfr == (^rawptr)(uintptr(frp_close) + FR_NEXT_OFF)^, false)
	}

	// If the altframe wasn't adjacent and left/above, resizing it will have
	// changed window positions within the parent frame.  Recompute them.
	if altfr != (^rawptr)(uintptr(frp_close) + FR_PREV_OFF)^ {
		frame_comp_pos_o(parent, &row, &col)
	}

	if unflat_altfr == nil {
		frame_flatten_o(altfr)
	} else {
		unflat_altfr^ = altfr
	}

	frame_locked_dec_o()

	return wp
}

// ── Batch 9: win_free ────────────────────────────────────────────────────────
W_LINES_OFF :: 632
W_STATUS_CLICK_DEFS_OFF :: 11080
W_STATUS_CLICK_DEFS_SIZE_OFF :: 11088
W_WINBAR_CLICK_DEFS_OFF :: 11096
W_WINBAR_CLICK_DEFS_SIZE_OFF :: 11104
W_STATUSCOL_CLICK_DEFS_OFF :: 11112
W_P_CC_COLS_OFF :: 4224
TP_PREVWIN_OFF :: 32
DV_HASHTAB_OFF :: 16
WC_TITLE_CHUNKS_OFF :: 400
WC_FOOTER_CHUNKS_OFF :: 440

foreign _ {
	@(link_name = "alist_unlink")
	alist_unlink_r :: proc "c" (al: rawptr) ---
	@(link_name = "vars_clear")
	vars_clear_r :: proc "c" (ht: rawptr) ---
	@(link_name = "unref_var_dict")
	unref_var_dict_r :: proc "c" (dict: rawptr) ---
	@(link_name = "tagstack_clear_entry")
	tagstack_clear_entry_r :: proc "c" (item: rawptr) ---
	@(link_name = "stl_clear_click_defs")
	stl_clear_click_defs_r :: proc "c" (click_defs: rawptr, click_defs_size: C.size_t) ---
	@(link_name = "clear_matches")
	clear_matches_r :: proc "c" (wp: rawptr) ---
	@(link_name = "qf_free_all")
	qf_free_all_r :: proc "c" (wp: rawptr) ---
	@(link_name = "au_pending_free_win")
	au_pending_free_win_g: rawptr
	@(link_name = "autocmd_busy")
	autocmd_busy_g: bool
}
// clearFolding/clear_winopt/deleteFoldRecurse/free_jumplist/win_free_grid_r/
// xfree/block+unblock/win_valid_any_tab/set_destroy-via-xfree reused.

// Free one WinInfo.
@(export)
free_wininfo :: proc "c"(wip: rawptr, bp: rawptr) {
	if (^bool)(uintptr(wip) + WI_OPTSET_OFF)^ {
		clear_winopt(transmute(rawptr)(uintptr(wip) + WI_OPT_OFF))
		deleteFoldRecurse(bp, (^Garray)(uintptr(wip) + WI_FOLDS_OFF))
	}
	xfree(wip)
}

// Remove window 'wp' from the window list and free the structure.
//
// @param tp tab page "win" is in, NULL for current
@(export)
win_free :: proc "c"(wp: rawptr, tp: rawptr) {
	map_del_int_ptr_t(&window_handles_g, (^C.int)(uintptr(wp) + W_HANDLE_OFF)^, nil)
	clearFolding(wp)

	// reduce the reference count to the argument list.
	alist_unlink_r((^rawptr)(uintptr(wp) + W_ALIST_OFF)^)

	// Don't execute autocommands while the window is halfway being deleted.
	block_autocmds_r()

	// set_destroy(uint32_t): C khash layout {4xu32, flags@16, keys@24}.
	ns_set := uintptr(wp) + W_NS_SET_OFF
	xfree((^rawptr)(ns_set + 16)^)
	xfree((^rawptr)(ns_set + 24)^)

	clear_winopt(transmute(rawptr)(uintptr(wp) + W_ONEBUF_OPT_OFF))
	clear_winopt(transmute(rawptr)(uintptr(wp) + W_ALLBUF_OPT_OFF))

	xfree((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + 56)^)
	xfree((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + 64)^)

	vars := (^rawptr)(uintptr(wp) + W_VARS_OFF)^
	vars_clear_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF))
	hash_init_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF))
	unref_var_dict_r(vars)

	if prevwin_g == wp {
		prevwin_g = nil
	}
	tp2 := first_tabpage
	for tp2 != nil {
		if (^rawptr)(uintptr(tp2) + TP_PREVWIN_OFF)^ == wp {
			(^rawptr)(uintptr(tp2) + TP_PREVWIN_OFF)^ = nil
		}
		tp2 = (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^
	}

	xfree((^rawptr)(uintptr(wp) + W_LINES_OFF)^)

	for i: C.int = 0; i < (^C.int)(uintptr(wp) + W_TAGSTACKLEN_OFF)^; i += 1 {
		tagstack_clear_entry_r(transmute(rawptr)(uintptr(wp) + W_TAGSTACK_OFF + uintptr(i) * TAGGY_SIZE_O))
	}

	xfree((^rawptr)(uintptr(wp) + W_LOCALDIR_OFF)^)
	xfree((^rawptr)(uintptr(wp) + W_PREVDIR_OFF)^)

	stl_clear_click_defs_r((^rawptr)(uintptr(wp) + W_STATUS_CLICK_DEFS_OFF)^,
		(^C.size_t)(uintptr(wp) + W_STATUS_CLICK_DEFS_SIZE_OFF)^)
	xfree((^rawptr)(uintptr(wp) + W_STATUS_CLICK_DEFS_OFF)^)

	stl_clear_click_defs_r((^rawptr)(uintptr(wp) + W_WINBAR_CLICK_DEFS_OFF)^,
		(^C.size_t)(uintptr(wp) + W_WINBAR_CLICK_DEFS_SIZE_OFF)^)
	xfree((^rawptr)(uintptr(wp) + W_WINBAR_CLICK_DEFS_OFF)^)

	sc_map := (^rawptr)(uintptr(wp) + W_STATUSCOL_CLICK_DEFS_OFF)^
	if sc_map != nil {
		sc_mp := (^Map_int_StcClicks)(sc_map)
		// values[] is dense 0..n_keys (key index space, not buckets).
		for i: u32 = 0; i < sc_mp.set.h.n_keys; i += 1 {
			inner := sc_mp.values[i] // StcClicks map
			for j: u32 = 0; j < inner.set.h.n_keys; j += 1 {
				row_defs := inner.values[j] // StcClick
				stl_clear_click_defs_r(transmute(rawptr)(row_defs.def),
					C.size_t(row_defs.size))
				xfree(transmute(rawptr)(row_defs.def))
			}
			// map_destroy(int, &inner): free keys+hash arrays.
			xfree(transmute(rawptr)(inner.set.keys))
			xfree(transmute(rawptr)(inner.set.h.hash))
		}
		// map_destroy(int, wp->w_statuscol_click_defs): frees internals only
		// (C does not free the Map struct itself — mirror exactly).
		xfree(transmute(rawptr)(sc_mp.set.keys))
		xfree(transmute(rawptr)(sc_mp.set.h.hash))
	}

	// Remove the window from the b_wininfo lists, it may happen that the
	// freed memory is re-used for another window.
	buf := firstbuf
	for buf != nil {
		n := wininfo_count_o(buf)
		pos_wip: u64 = n
		pos_null: u64 = n
		wip_wp: rawptr = nil
		for i: u64 = 0; i < n; i += 1 {
			wip := wininfo_at_o(buf, i)
			if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == wp {
				wip_wp = wip
				pos_wip = i
			} else if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == nil {
				pos_null = i
			}
		}

		if wip_wp != nil {
			(^rawptr)(uintptr(wip_wp) + WI_WIN_OFF)^ = nil
			// Discard saved options if the style is minimal.
			if (^C.int)(uintptr(wp) + W_CONFIG_OFF)^ == K_WIN_STYLE_MINIMAL_O &&
			(^bool)(uintptr(wip_wp) + WI_OPTSET_OFF)^ {
				clear_winopt(transmute(rawptr)(uintptr(wip_wp) + WI_OPT_OFF))
				deleteFoldRecurse(buf, (^Garray)(uintptr(wip_wp) + WI_FOLDS_OFF))
				(^bool)(uintptr(wip_wp) + WI_OPTSET_OFF)^ = false
			}
			// If there already is an entry with "wi_win" set to NULL, only
			// the first entry with NULL will ever be used, delete the other one.
			if pos_null < n {
				pos_delete := max(pos_null, pos_wip)
				free_wininfo(wininfo_at_o(buf, pos_delete), buf)
				// kv_shift(buf->b_wininfo, pos_delete, 1)
				items := ([^]rawptr)((^rawptr)(uintptr(buf) + B_WININFO_OFF + 16)^)
				for j := pos_delete + 1; j < n; j += 1 {
					items[j - 1] = items[j]
				}
				(^u64)(uintptr(buf) + B_WININFO_OFF)^ = n - 1
			}
		}
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}

	// free the border text
	clear_virttext_r((^Kvec_VT)(uintptr(wp) + W_CONFIG_OFF + WC_TITLE_CHUNKS_OFF))
	clear_virttext_r((^Kvec_VT)(uintptr(wp) + W_CONFIG_OFF + WC_FOOTER_CHUNKS_OFF))

	clear_matches_r(wp)

	free_jumplist(wp)

	qf_free_all_r(wp)

	xfree((^rawptr)(uintptr(wp) + W_P_CC_COLS_OFF)^)

	win_free_grid(wp, false)

	if win_valid_any_tab(wp) {
		win_remove(wp, tp)
	}
	if autocmd_busy_g {
		(^rawptr)(uintptr(wp) + W_NEXT_OFF)^ = au_pending_free_win_g
		au_pending_free_win_g = wp
	} else {
		xfree(wp)
	}

	unblock_autocmds_r()
}

// ── win_split_ins ────────────────────────────────────────────────────────────
// When "new_wp" is NULL: split the current window in two.
// When "new_wp" is not NULL: insert this window at the far
// top/left/right/bottom.
// When "to_flatten" is not NULL: flatten this frame before reorganising frames;
// remains unflattened on failure.
//
// On failure, if "new_wp" was not NULL, no changes will have been made to the
// window layout or sizes.
// @return NULL for failure, or pointer to new window
@(export)
win_split_ins :: proc "c"(size: C.int, flags: C.int, new_wp: rawptr, dir: C.int, to_flatten: rawptr) -> rawptr {
	wp := new_wp

	// aucmd_win[] should always remain floating
	if new_wp != nil && is_aucmd_win_r(new_wp) {
		return nil
	}

	if new_wp == nil {
		trigger_winnewpre_o()
	}

	oldwin: rawptr
	if (flags & WSP_TOP_O) != 0 {
		oldwin = firstwin
	} else if (flags & WSP_BOT_O) != 0 || (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
		// can't split float, use last nonfloating window instead
		oldwin = lastwin_nofloating(nil)
	} else {
		oldwin = curwin
	}

	need_status: C.int = 0
	new_size := size
	vertical := (flags & WSP_VERT_O) != 0
	toplevel := (flags & (WSP_TOP_O | WSP_BOT_O)) != 0

	// add a status line when p_ls == 1 and splitting the first window
	if one_window(firstwin, nil) && p_ls_g == 1 &&
	(^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^ == 0 {
		if (^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^ <= C.int(p_wmh_opt) {
			emsg(cstring(E36_S))
			return nil
		}
		need_status = STATUS_HEIGHT_O
		win_float_anchor_laststatus_r()
	}

	do_equal := false
	oldwin_height: C.int = 0
	layout := vertical ? FR_ROW_O : FR_COL_O
	did_set_fraction := false

	if vertical {
		// Check if we are able to split the current window and compute its
		// width. Current window requires at least 1 space.
		wmw1 := p_wmw_opt == 0 ? 1 : C.int(p_wmw_opt)
		needed := wmw1 + 1
		if (flags & WSP_ROOM_O) != 0 {
			needed += C.int(p_wiw_opt) - wmw1
		}
		minwidth: C.int = 0
		available: C.int = 0
		if toplevel {
			minwidth = frame_minwidth_o(topframe_g, nowin_o())
			available = (^C.int)(uintptr(topframe_g) + FR_WIDTH_OFF)^
			needed += minwidth
		} else if p_ea_g != 0 {
			minwidth = frame_minwidth_o((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^, nowin_o())
			prevfrp := (^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^
			frp := (^rawptr)(uintptr(prevfrp) + FR_PARENT_OFF)^
			for frp != nil {
				if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
					child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
					for child != nil {
						if child != prevfrp {
							minwidth += frame_minwidth_o(child, nowin_o())
						}
						child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
					}
				}
				prevfrp = frp
				frp = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
			}
			available = (^C.int)(uintptr(topframe_g) + FR_WIDTH_OFF)^
			needed += minwidth
		} else {
			minwidth = frame_minwidth_o((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^, nowin_o())
			available = (^C.int)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^
			needed += minwidth
		}
		if available < needed {
			emsg(cstring(E36_S))
			return nil
		}
		if new_size == 0 {
			new_size = (^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ / 2
		}
		new_size = max(min(new_size, available - minwidth - 1), wmw1)

		// if it doesn't fit in the current window, need win_equal()
		if (^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ - new_size - 1 < C.int(p_wmw_opt) {
			do_equal = true
		}

		// We don't like to take lines for the new window from a
		// 'winfixwidth' window. Take them from a window to the left or right
		// instead, if possible. Add one for the separator.
		if (^C.int)(uintptr(oldwin) + W_P_WFW_OFF)^ != 0 {
			win_setwidth_win((^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ + new_size + 1,
				oldwin, true)
		}

		// Only make all windows the same width if one of them (except oldwin)
		// is wider than one of the split windows.
		if !do_equal && p_ea_g != 0 && size == 0 && b_at(p_ead_g, 0) != 'v' &&
		(^rawptr)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^ != nil {
			frp := (^rawptr)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_CHILD_OFF)^
			// NOTE: C walks fr_parent->fr_child; same thing via oldwin frame parent.
			frp = (^rawptr)(uintptr((^rawptr)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^
			for frp != nil {
				frp_win := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
				if frp_win != oldwin && frp_win != nil &&
				((^C.int)(uintptr(frp_win) + W_WIDTH_OFF)^ > new_size ||
				(^C.int)(uintptr(frp_win) + W_WIDTH_OFF)^ >
				(^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ - new_size - 1) {
					do_equal = true
					break
				}
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
		}
	} else {
		// Check if we are able to split the current window and compute its height.
		// Current window requires at least 1 space plus space for the window bar.
		wmh1 := max(C.int(p_wmh_opt), 1) + (^C.int)(uintptr(oldwin) + W_WINBAR_HEIGHT_OFF)^
		needed := wmh1 + STATUS_HEIGHT_O
		if (flags & WSP_ROOM_O) != 0 {
			needed += C.int(p_wh_opt) - wmh1 + (^C.int)(uintptr(oldwin) + W_WINBAR_HEIGHT_OFF)^
		}
		if C.longlong(p_ch) < 1 {
			needed += 1 // Adjust for cmdheight=0.
		}
		minheight: C.int = 0
		available: C.int = 0
		if toplevel {
			minheight = frame_minheight_o(topframe_g, nowin_o()) + need_status
			available = (^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^
			needed += minheight
		} else if p_ea_g != 0 {
			minheight = frame_minheight_o((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^, nowin_o()) + need_status
			prevfrp := (^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^
			frp := (^rawptr)(uintptr(prevfrp) + FR_PARENT_OFF)^
			for frp != nil {
				if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
					child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
					for child != nil {
						if child != prevfrp {
							minheight += frame_minheight_o(child, nowin_o())
						}
						child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
					}
				}
				prevfrp = frp
				frp = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
			}
			available = (^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^
			needed += minheight
		} else {
			minheight = frame_minheight_o((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^, nowin_o()) + need_status
			available = (^C.int)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_HEIGHT_OFF)^
			needed += minheight
		}
		if available < needed {
			emsg(cstring(E36_S))
			return nil
		}
		oldwin_height = (^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^
		if need_status != 0 {
			(^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
			oldwin_height -= STATUS_HEIGHT_O
		}
		if new_size == 0 {
			new_size = oldwin_height / 2
		}

		new_size = max(min(new_size, available - minheight - STATUS_HEIGHT_O), wmh1)

		// if it doesn't fit in the current window, need win_equal()
		if oldwin_height - new_size - STATUS_HEIGHT_O < C.int(p_wmh_opt) {
			do_equal = true
		}

		// We don't like to take lines for the new window from a
		// 'winfixheight' window. Take them from a window above or below
		// instead, if possible.
		if (^C.int)(uintptr(oldwin) + W_P_WFH_OFF)^ != 0 {
			// Set w_fraction now so that the cursor keeps the same relative
			// vertical position using the old height.
			set_fraction(oldwin)
			did_set_fraction = true

			win_setheight_win((^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^ + new_size + STATUS_HEIGHT_O,
				oldwin, true)
			oldwin_height = (^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^
			if need_status != 0 {
				oldwin_height -= STATUS_HEIGHT_O
			}
		}

		// Only make all windows the same height if one of them (except oldwin)
		// is higher than one of the split windows.
		if !do_equal && p_ea_g != 0 && size == 0 &&
		b_at(p_ead_g, 0) != 'h' &&
		(^rawptr)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^ != nil {
			frp := (^rawptr)(uintptr((^rawptr)(uintptr((^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^
			for frp != nil {
				frp_win := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
				if frp_win != oldwin && frp_win != nil &&
				((^C.int)(uintptr(frp_win) + W_HEIGHT_OFF)^ > new_size ||
				(^C.int)(uintptr(frp_win) + W_HEIGHT_OFF)^ >
				oldwin_height - new_size - STATUS_HEIGHT_O) {
					do_equal = true
					break
				}
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
		}
	}

	// allocate new window structure and link it in the window list
	if (flags & WSP_TOP_O) == 0 &&
	((flags & WSP_BOT_O) != 0 || (flags & WSP_BELOW_O) != 0 ||
	((flags & WSP_ABOVE_O) == 0 && (vertical ? p_spr_g != 0 : p_sb_g != 0))) {
		// new window below/right of current one
		if new_wp == nil {
			wp = win_alloc(oldwin, false)
		} else {
			win_append(oldwin, wp, nil)
		}
	} else {
		if new_wp == nil {
			wp = win_alloc((^rawptr)(uintptr(oldwin) + W_PREV_OFF)^, false)
		} else {
			win_append((^rawptr)(uintptr(oldwin) + W_PREV_OFF)^, wp, nil)
		}
	}

	if new_wp == nil {
		if wp == nil {
			return nil
		}

		new_frame_o(wp)

		// make the contents of the new window the same as the current one
		win_init(wp, curwin, flags)
	} else if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		ui_comp_remove_grid_r(transmute(rawptr)(uintptr(wp) + W_GRID_HANDLE_OFF))
		if ui_has(K_UIMULTIGRID_O) {
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		} else {
			// No longer a float, a non-multigrid UI shouldn't draw it as such
			ui_call_win_hide_r((^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^)
			win_free_grid(wp, true)
		}

		// External windows are independent of tabpages, and may have been the curwin of others.
		if (^bool)(uintptr(wp) + WCFG_EXTERNAL_OFF)^ {
			tp := first_tabpage
			for tp != nil {
				if tp != curtab && (^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ == wp {
					(^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
				}
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}
		}

		(^bool)(uintptr(wp) + W_FLOATING_OFF)^ = false
		new_frame_o(wp)

		// non-floating window doesn't store float config or have a border.
		clear_float_config(transmute(rawptr)(uintptr(wp) + W_CONFIG_OFF), true)
		libc.memset(transmute(rawptr)(uintptr(wp) + W_BORDER_ADJ_OFF), 0, W_BORDER_ADJ_SIZE)
	}

	// Going to reorganize frames now, make sure they're flat.
	if to_flatten != nil {
		frame_flatten_o(to_flatten)
	}

	before: bool = false
	curfrp: rawptr = nil

	// Reorganise the tree of frames to insert the new window.
	if toplevel {
		if ((b_at((^u8)(uintptr(topframe_g) + FR_LAYOUT_OFF), 0) == FR_COL_O && !vertical) ||
		(b_at((^u8)(uintptr(topframe_g) + FR_LAYOUT_OFF), 0) == FR_ROW_O && vertical)) {
			curfrp = (^rawptr)(uintptr(topframe_g) + FR_CHILD_OFF)^
			if (flags & WSP_BOT_O) != 0 {
				for (^rawptr)(uintptr(curfrp) + FR_NEXT_OFF)^ != nil {
					curfrp = (^rawptr)(uintptr(curfrp) + FR_NEXT_OFF)^
				}
			}
		} else {
			curfrp = topframe_g
		}
		before = (flags & WSP_TOP_O) != 0
	} else {
		curfrp = (^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^
		if (flags & WSP_BELOW_O) != 0 {
			before = false
		} else if (flags & WSP_ABOVE_O) != 0 {
			before = true
		} else if vertical {
			before = p_spr_g == 0
		} else {
			before = p_sb_g == 0
		}
	}
	if (^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^ == nil ||
	b_at((^u8)(uintptr((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) != u8(layout) {
		// Need to create a new frame in the tree to make a branch.
		frp := (^rawptr)(xcalloc(1, 64))
		libc.memcpy(frp, curfrp, 64)
		b_set((^u8)(uintptr(curfrp) + FR_LAYOUT_OFF), 0, u8(layout))
		(^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ = curfrp
		(^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ = nil
		(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ = nil
		(^rawptr)(uintptr(curfrp) + FR_CHILD_OFF)^ = frp
		(^rawptr)(uintptr(curfrp) + FR_WIN_OFF)^ = nil
		curfrp = frp
		if (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil {
			(^rawptr)(uintptr(oldwin) + W_FRAME_OFF)^ = frp
		} else {
			child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
			for child != nil {
				(^rawptr)(uintptr(child) + FR_PARENT_OFF)^ = curfrp
				child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
			}
		}
	}

	frp: rawptr = nil
	if new_wp == nil {
		frp = (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	} else {
		frp = (^rawptr)(uintptr(new_wp) + W_FRAME_OFF)^
	}
	(^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ = (^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^

	// Insert the new frame at the right place in the frame list.
	if before {
		frame_insert_o(curfrp, frp)
	} else {
		frame_append_o(curfrp, frp)
	}

	// Set w_fraction now so that the cursor keeps the same relative
	// vertical position.
	if !did_set_fraction {
		set_fraction(oldwin)
	}
	(^C.int)(uintptr(wp) + W_FRACTION_OFF)^ = (^C.int)(uintptr(oldwin) + W_FRACTION_OFF)^

	if vertical {
		(^C.int)(uintptr(wp) + W_P_SCR_OFF)^ = (^C.int)(uintptr(curwin) + W_P_SCR_OFF)^

		if need_status != 0 {
			win_new_height(oldwin, (^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^ - 1)
			(^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^ = need_status
		}
		if toplevel {
			// set height and row of new window to full height
			(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = 		tabline_height()
			win_new_height(wp, (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^ - (p_ls_g == 1 || p_ls_g == 2 ? 1 : 0))
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = (p_ls_g == 1 || p_ls_g == 2) ? 1 : 0
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 0
		} else {
			// height and row of new window is same as current window
			(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINROW_OFF)^
			win_new_height(wp, (^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^)
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = (^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = (^C.int)(uintptr(oldwin) + W_HSEP_HEIGHT_OFF)^
		}
		(^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ = (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^

		// "new_size" of the current window goes to the new window, use
		// one column for the vertical separator
		win_new_width(wp, new_size)
		if before {
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 1
		} else {
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = (^C.int)(uintptr(oldwin) + W_VSEP_WIDTH_OFF)^
			(^C.int)(uintptr(oldwin) + W_VSEP_WIDTH_OFF)^ = 1
		}
		if toplevel {
			if (flags & WSP_BOT_O) != 0 {
				frame_set_vsep_o(curfrp, true)
			}
			// Set width of neighbor frame
			frame_new_width((^rawptr)(curfrp), (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^ -
				(new_size + (((flags & WSP_TOP_O) != 0) ? 1 : 0)),
				(flags & WSP_TOP_O) != 0, false)
		} else {
			win_new_width(oldwin, (^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ - (new_size + 1))
		}
		if before { // new window left of current one
			(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINCOL_OFF)^
			(^C.int)(uintptr(oldwin) + W_WINCOL_OFF)^ += new_size + 1
		} else { // new window right of current one
			(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINCOL_OFF)^ +
				(^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^ + 1
		}
		frame_fix_width_o(oldwin)
		frame_fix_width_o(wp)
	} else {
		is_stl_global := 		global_stl_height() > 0
		// width and column of new window is same as current window
		if toplevel {
			(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = 0
			win_new_width(wp, Columns)
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = 0
		} else {
			(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINCOL_OFF)^
			win_new_width(wp, (^C.int)(uintptr(oldwin) + W_WIDTH_OFF)^)
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = (^C.int)(uintptr(oldwin) + W_VSEP_WIDTH_OFF)^
		}
		(^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ = (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^

		// "new_size" of the current window goes to the new window, use
		// one row for the status line
		win_new_height(wp, new_size)
		old_status_height := (^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^
		if before {
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = is_stl_global ? 1 : 0
		} else {
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = (^C.int)(uintptr(oldwin) + W_HSEP_HEIGHT_OFF)^
			(^C.int)(uintptr(oldwin) + W_HSEP_HEIGHT_OFF)^ = is_stl_global ? 1 : 0
		}
		if toplevel {
			new_fr_height := (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^ - new_size
			if is_stl_global {
				if (flags & WSP_BOT_O) != 0 {
					frame_add_hsep_o(curfrp)
				} else {
					new_fr_height -= 1
				}
			} else {
				if !(((flags & WSP_BOT_O) != 0) && p_ls_g == 0) {
					new_fr_height -= STATUS_HEIGHT_O
				}
				if (flags & WSP_BOT_O) != 0 {
					frame_add_statusline_o(curfrp)
				}
			}
			frame_new_height(curfrp, new_fr_height, (flags & WSP_TOP_O) != 0, false, false)
		} else {
			win_new_height(oldwin, oldwin_height - (new_size + STATUS_HEIGHT_O))
		}

		if before { // new window above current one
			(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINROW_OFF)^
			if is_stl_global {
				(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = 0
				(^C.int)(uintptr(oldwin) + W_WINROW_OFF)^ += (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ + 1
			} else {
				(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
				(^C.int)(uintptr(oldwin) + W_WINROW_OFF)^ += (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ + STATUS_HEIGHT_O
			}
		} else { // new window below current one
			if is_stl_global {
				(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINROW_OFF)^ +
					(^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^ + 1
				(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = 0
			} else {
				(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = (^C.int)(uintptr(oldwin) + W_WINROW_OFF)^ +
					(^C.int)(uintptr(oldwin) + W_HEIGHT_OFF)^ + STATUS_HEIGHT_O
				(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = old_status_height
				if ((flags & WSP_BOT_O) == 0) {
					(^C.int)(uintptr(oldwin) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
				}
			}
		}
		frame_fix_height_o(oldwin)
		frame_fix_height_o(wp)
	}

	if toplevel {
		win_comp_pos()
	}

	// Both windows need redrawing. Update all status lines, in case they
	// show something related to the window count or position.
	redraw_later_r(wp, UPD_NOT_VALID_O)
	redraw_later_r(oldwin, UPD_NOT_VALID_O)
	status_redraw_all_r()

	if need_status != 0 {
		msg_row = Rows - 1
		msg_col = sc_col
		msg_clr_eos_force_r() // Old command/ruler may still be there
		comp_col_r()
		msg_row = Rows - 1
		msg_col = 0 // put position back at start of line
	}

	// equalize the window sizes.
	if do_equal || dir != 0 {
		win_equal(wp, true, vertical ? (dir == 'v' ? 'b' : 'h') : (dir == 'h' ? 'b' : 'v'))
	} else if !is_aucmd_win_r(wp) {
		win_fix_scroll(false)
	}

	i: C.int = 0

	// Don't change the window height/width to 'winheight' / 'winwidth' if a
	// size was given.
	if (flags & WSP_VERT_O) != 0 {
		i = C.int(p_wiw_opt)
		if size != 0 {
			p_wiw_opt = C.longlong(size)
		}
	} else {
		i = C.int(p_wh_opt)
		if size != 0 {
			p_wh_opt = C.longlong(size)
		}
	}

	if ((flags & WSP_NOENTER_O) == 0) {
		// make the new window the current window
		win_enter_ext_o(wp, (new_wp == nil ? WEE_TRIGGER_NEW_AUTOCMDS_O : 0) |
			WEE_TRIGGER_ENTER_AUTOCMDS_O | WEE_TRIGGER_LEAVE_AUTOCMDS_O)
	}
	if vertical {
		p_wiw_opt = C.longlong(i)
	} else {
		p_wh_opt = C.longlong(i)
	}

	if win_valid(oldwin) {
		// Send the window positions to the UI
		(^bool)(uintptr(oldwin) + W_POS_CHANGED_OFF)^ = true
	}

	return wp
}

// ── Batch 7: win_split_ins + win_enter_ext + frame fix/add helpers ────────────

WSP_NOENTER_O :: 0x200
WEE_UNDO_SYNC_O :: 0x01
WEE_CURWIN_INVALID_O :: 0x02
WEE_TRIGGER_NEW_AUTOCMDS_O :: 0x04
WEE_TRIGGER_ENTER_AUTOCMDS_O :: 0x08
WEE_TRIGGER_LEAVE_AUTOCMDS_O :: 0x10
MODE_NORMAL_O :: 0x01
MODE_CMDLINE_O :: 0x08
MODE_TERMINAL_O :: 0x80
BCO_ENTER_O :: 1
BCO_NOHELP_O :: 4
EVENT_BUFENTER_O :: 3
EVENT_BUFLEAVE_O :: 7
EVENT_WINENTER_O :: 143
EVENT_WINLEAVE_O :: 144
EVENT_WINNEW_O :: 145
EVENT_WINNEWPRE_O :: 146
E36_S :: "E36: Not enough room"
K_UIMULTIGRID_O :: 6
FRACTION_MULT_O :: 16384

W_P_SCR_OFF :: 1040
WCFG_EXTERNAL_OFF :: 10608
WCFG_FOCUSABLE_OFF :: 10609
WCFG_MOUSE_OFF :: 10610
WCFG_ZINDEX_OFF :: 10616
WCFG_BUFPOS_LNUM_OFF :: 10564
WCFG_CMDLINE_OFF_OFF :: 11032
KZINDEX_FLOAT_DEFAULT_O :: 50
INT_MAX_O :: 2147483647
W_BORDER_ADJ_OFF :: 516
W_BORDER_ADJ_SIZE :: 16

nowin_o :: proc "c"() -> rawptr {
	return transmute(rawptr)(~uintptr(0))
}

// Insert frame "frp" in a frame list before frame "before".
frame_insert_o :: proc "c"(before: rawptr, frp: rawptr) {
	(^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ = before
	(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ = (^rawptr)(uintptr(before) + FR_PREV_OFF)^
	(^rawptr)(uintptr(before) + FR_PREV_OFF)^ = frp
	if (^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
		(^rawptr)(uintptr((^rawptr)(uintptr(frp) + FR_PREV_OFF)^) + FR_NEXT_OFF)^ = frp
	} else {
		(^rawptr)(uintptr((^rawptr)(uintptr(frp) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^ = frp
	}
}

// Append frame "frp" in a frame list after frame "after".
frame_append_o :: proc "c"(after: rawptr, frp: rawptr) {
	(^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ = (^rawptr)(uintptr(after) + FR_NEXT_OFF)^
	(^rawptr)(uintptr(after) + FR_NEXT_OFF)^ = frp
	if (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
		(^rawptr)(uintptr((^rawptr)(uintptr(frp) + FR_NEXT_OFF)^) + FR_PREV_OFF)^ = frp
	}
	(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ = after
}

W_DO_WIN_FIX_CURSOR_OFF :: 488
W_HL_NORMAL_OFF :: 92
W_HL_NORMALNC_OFF :: 96
W_GRID_HANDLE_OFF :: 10456 // w_grid_alloc.handle @+0

foreign _ {
	@(link_name = "is_aucmd_win")
	is_aucmd_win_r :: proc "c" (wp: rawptr) -> bool ---
	@(link_name = "lastwin")
	lastwin_g: rawptr
	@(link_name = "win_float_anchor_laststatus")
	win_float_anchor_laststatus_r :: proc "c" () ---
	@(link_name = "ui_comp_remove_grid")
	ui_comp_remove_grid_r :: proc "c" (grid: rawptr) ---
 	@(link_name = "ui_call_win_hide")
 	ui_call_win_hide_r :: proc "c" (grid: C.int) ---
 	@(link_name = "msg_clr_eos_force")
	msg_clr_eos_force_r :: proc "c" () ---
 	@(link_name = "changed_line_abv_curs")
	changed_line_abv_curs_r :: proc "c" () ---
	@(link_name = "get_real_state")
	get_real_state_r :: proc "c" () -> C.int ---
 	@(link_name = "do_autochdir")
 	do_autochdir_r :: proc "c" () ---
	@(link_name = "aborting")
	aborting_r :: proc "c" () -> bool ---
	@(link_name = "cursor_down_inner")
	cursor_down_inner_r :: proc "c" (wp: rawptr, n: C.int, skip_conceal: bool) ---
	@(link_name = "cursor_up_inner")
 	cursor_up_inner_r :: proc "c" (wp: rawptr, n: C.long, skip_conceal: bool) ---
  	@(link_name = "validate_botline_win")
 	validate_botline_win_r :: proc "c" (wp: rawptr) ---
 	@(link_name = "p_ls")
	p_ls_g: C.longlong
	@(link_name = "p_ea")
	p_ea_g: C.int
	@(link_name = "p_ead")
	p_ead_g: ^u8
}
// sc_col (search.odin), msg_row/Rows/Columns (main.odin), p_ru?, redraw_cmdline?
// lastwin/prevwin/curwin/curbuf/firstwin/first_tabpage/curtab/topframe from main.odin.

new_frame_o :: proc "c"(wp: rawptr) {
	frp := (^rawptr)(xcalloc(1, 64))

	(^rawptr)(uintptr(wp) + W_FRAME_OFF)^ = frp
	b_set((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0, FR_LEAF_O)
	(^rawptr)(uintptr(frp) + FR_WIN_OFF)^ = wp
}

trigger_winnewpre_o :: proc "c"() {
	window_layout_lock()
	apply_autocmds(EVENT_WINNEWPRE_O, nil, nil, false, nil)
	window_layout_unlock()
}

// Set frame width from the window it contains.
frame_fix_width_o :: proc "c"(wp: rawptr) {
	(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^ =
		(^C.int)(uintptr(wp) + W_WIDTH_OFF)^ + (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
}

// Set frame height from the window it contains.
frame_fix_height_o :: proc "c"(wp: rawptr) {
	(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_FRAME_OFF)^) + FR_HEIGHT_OFF)^ =
		(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ + (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ +
		(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^
}

// Add the horizontal separator to windows at the bottom of "frp".
frame_add_hsep_o :: proc "c"(frp_in: rawptr) {
	frp := frp_in
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		wp := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
		(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 1
	} else if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		// Handle all the frames in the row.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			frame_add_hsep_o(child)
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
	} else {
		// Only need to handle the last frame in the column.
		fr := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
		frame_add_hsep_o(fr)
	}
}

frame_add_statusline_o :: proc "c"(frp_in: rawptr) {
	frp := frp_in
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		wp := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
		(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
	} else if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		// Handle all the frames in the row.
		child := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for child != nil {
			frame_add_statusline_o(child)
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
	} else {
		// Only need to handle the last frame in the column.
		frp = (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
		for (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
		frame_add_statusline_o(frp)
	}
}

win_fix_cursor_o :: proc "c"(normal: bool) {
	wp := curwin

	if !(^bool)(uintptr(wp) + W_DO_WIN_FIX_CURSOR_OFF)^ ||
	(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ <
	(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
		return
	}

	(^bool)(uintptr(wp) + W_DO_WIN_FIX_CURSOR_OFF)^ = false
	// Determine valid cursor range.
	so := C.int(min((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2,
		C.int(get_scrolloff_value(wp))))
	lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^

	(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
	cursor_down_inner_r(wp, so, false)
	top := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^

	(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1
	cursor_up_inner_r(wp, C.long(so), false)
	bot := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^

	(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = lnum
	// Check if cursor position is above or below valid cursor range.
	nlnum: C.int = 0
	if lnum > bot && ((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ -
	(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^) != 1 {
		nlnum = bot
	} else if lnum < top && (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ != 1 {
		nlnum = (so == (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2) ? bot : top
	}

	if nlnum != 0 { // Cursor is invalid for current scroll position.
		if normal { // Save to jumplist and set cursor to avoid scrolling.
			setmark('\'')
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = nlnum
		} else { // Scroll instead when not in normal mode.
			(^C.int)(uintptr(wp) + W_FRACTION_OFF)^ = (nlnum == bot) ? FRACTION_MULT_O : 0
			scroll_to_fraction(wp, (^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^)
			validate_botline_win_r(curwin)
		}
	}
}

win_enter_ext_o :: proc "c"(wp: rawptr, flags: C.int) {
	other_buffer := false
	curwin_invalid := (flags & WEE_CURWIN_INVALID_O) != 0

	if wp == curwin && !curwin_invalid { // nothing to do
		return
	}

	if !curwin_invalid {
		leaving_window(curwin)
	}

	if !curwin_invalid && (flags & WEE_TRIGGER_LEAVE_AUTOCMDS_O) != 0 {
		// Be careful: If autocommands delete the window, return now.
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
			apply_autocmds(EVENT_BUFLEAVE_O, nil, nil, false, curbuf)
			other_buffer = true
			if !win_valid(wp) {
				return
			}
		}
		apply_autocmds(EVENT_WINLEAVE_O, nil, nil, false, curbuf)
		if !win_valid(wp) {
			return
		}
		// autocmds may abort script processing
		if aborting_r() {
			return
		}
	}

	// sync undo before leaving the current buffer
	if ((flags & WEE_UNDO_SYNC_O) != 0 && curbuf != (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
		u_sync(false)
	}

	// Might need to scroll the old window before switching, e.g., when the
	// cursor was moved.
	if b_at(p_spk_g, 0) == 'c' && !curwin_invalid {
		update_topline_r(curwin)
	}

	// may have to copy the buffer options when 'cpo' contains 'S'
	if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
		buf_copy_options((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, BCO_ENTER_O | BCO_NOHELP_O)
	}
	if !curwin_invalid {
		prevwin_g = curwin // remember for CTRL-W p
		(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
	}
	curwin = wp
	curbuf = (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^

	check_cursor_r(curwin)
	if !virtual_active_r(curwin) {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0 // w_cursor.coladd
	}
	if b_at(p_spk_g, 0) == 'c' {
		changed_line_abv_curs_r() // assume cursor position needs updating
	} else {
		// Make sure the cursor position is valid, either by moving the cursor
		// or by scrolling the text.
		win_fix_cursor_o(get_real_state_r() & (MODE_NORMAL_O | MODE_CMDLINE_O | MODE_TERMINAL_O) != 0)
	}

	win_fix_current_dir()

	entering_window(curwin)
	// Careful: autocommands may close the window and make "wp" invalid
	if (flags & WEE_TRIGGER_NEW_AUTOCMDS_O) != 0 {
		apply_autocmds(EVENT_WINNEW_O, nil, nil, false, curbuf)
	}
	if (flags & WEE_TRIGGER_ENTER_AUTOCMDS_O) != 0 {
		apply_autocmds(EVENT_WINENTER_O, nil, nil, false, curbuf)
		if other_buffer {
			apply_autocmds(EVENT_BUFENTER_O, nil, nil, false, curbuf)
		}
	}

	maketitle_r()
	(^bool)(uintptr(curwin) + W_REDR_STATUS_OFF)^ = true
	redraw_tabline_opt = true
	if restart_edit != 0 {
		redraw_later_r(curwin, UPD_VALID_O)
	}

	// change background color according to NormalNC,
	// but only if actually defined (otherwise no extra redraw)
	if (^C.int)(uintptr(curwin) + W_HL_NORMAL_OFF)^ !=
	(^C.int)(uintptr(curwin) + W_HL_NORMALNC_OFF)^ {
		redraw_later_r(curwin, UPD_NOT_VALID_O)
	}
	if prevwin_g != nil {
		if (^C.int)(uintptr(prevwin_g) + W_HL_NORMAL_OFF)^ !=
		(^C.int)(uintptr(prevwin_g) + W_HL_NORMALNC_OFF)^ {
			redraw_later_r(prevwin_g, UPD_NOT_VALID_O)
		}
	}

	// set window height to desired minimal value
	if (^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ < C.int(p_wh_opt) &&
	(^C.int)(uintptr(curwin) + W_P_WFH_OFF)^ == 0 &&
 	(^bool)(uintptr(curwin) + W_FLOATING_OFF)^ == false {
 		win_setheight(C.int(p_wh_opt))
 	} else if (^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ == 0 {
 		win_setheight(1)
 	}

	// set window width to desired minimal value
	if (^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ < C.int(p_wiw_opt) &&
	(^C.int)(uintptr(curwin) + W_P_WFW_OFF)^ == 0 &&
 	(^bool)(uintptr(curwin) + W_FLOATING_OFF)^ == false {
 		win_setwidth(C.int(p_wiw_opt))
 	}

	setmouse_r() // in case jumped to/from help buffer

	// Change directories when the 'acd' option is set.
	do_autochdir_r()
}

// ── Batch 6: splits (win_split/win_init) + snapshots ─────────────────────────

WSP_ROOM_O :: 0x01
WSP_VERT_O :: 0x02
WSP_HOR_O :: 0x04
WSP_TOP_O :: 0x08
WSP_BOT_O :: 0x10
WSP_HELP_O :: 0x20
WSP_BELOW_O :: 0x40
WSP_ABOVE_O :: 0x80
WSP_NEWLOC_O :: 0x100
WSP_QUICKFIX_O :: 0x400

SNAP_HELP_IDX_O :: 0
SNAP_QUICKFIX_IDX_O :: 2

E442_S :: "E442: Can't split topleft and botright at the same time"
EVENT_TABNEWENTERED_O :: 118

// cmdmod fields via mark.odin's cmdmod_cmod_flags (@0): split@4, tab@8.
CMOD_SPLIT_OFF :: 4
CMOD_TAB_OFF :: 8

cmdmod_split_o :: proc "c"() -> C.int {
	return (^C.int)(uintptr(&cmdmod_cmod_flags) + CMOD_SPLIT_OFF)^
}

cmdmod_tab_o :: proc "c"() -> C.int {
	return (^C.int)(uintptr(&cmdmod_cmod_flags) + CMOD_TAB_OFF)^
}

set_cmdmod_tab_o :: proc "c"(v: C.int) {
	(^C.int)(uintptr(&cmdmod_cmod_flags) + CMOD_TAB_OFF)^ = v
}
TP_SNAPSHOT_OFF :: 168
AL_REFCOUNT_OFF :: 24

W_BUFFER_OFF :: 8
W_VALID_OFF :: 540
W_CURSWANT_OFF :: 148
W_SET_CURSWANT_OFF :: 152
W_TOPLINE_OFF :: 364
W_TOPFILL_OFF :: 372
W_PCMARK_OFF :: 4296
W_PREV_PCMARK_OFF :: 4308
W_WROW_OFF :: 600
W_FRACTION_OFF :: 11040
W_PREV_FRACTION_ROW_OFF :: 11044
W_LLIST_OFF :: 11064
W_LLIST_REF_OFF :: 11072
W_LOCALDIR_OFF :: 800
W_PREVDIR_OFF :: 808
W_BOTLINE_OFF :: 612
W_PREV_WINROW_OFF :: 424
W_TAGSTACK_OFF :: 9152
W_TAGSTACKLEN_OFF :: 10436
W_TAGSTACKIDX_OFF :: 10432
W_CHANGELISTIDX_OFF :: 9128
W_ALIST_OFF :: 784
W_ARG_IDX_OFF :: 792
B_NWINDOWS_OFF :: 136
TAGGY_SIZE_O :: 64
TAGGY_TAGNAME_OFF :: 0
TAGGY_USERDATA_OFF :: 56

foreign _ {
	@(link_name = "copy_loclist_stack")
	copy_loclist_stack_r :: proc "c" (from: rawptr, to: rawptr) ---
	@(link_name = "p_spk")
	p_spk_g: ^u8
	@(link_name = "postponed_split_tab")
	postponed_split_tab_g: C.int
}
// make_snapshot/clear_snapshot are C-exported? No — make_snapshot is exported,
// clear_snapshot* are static: port all three + rec helpers below.

@(export)
win_split :: proc "c"(size: C.int, flags_in: C.int) -> C.int {
	flags := flags_in
	if check_split_disallowed(curwin) == FAIL_S {
		return FAIL_S
	}

	// When the ":tab" modifier was used open a new tab page instead.
	if may_open_tabpage_o() == OK_S {
		return OK_S
	}

	// Add flags from ":vertical", ":topleft" and ":botright".
	flags |= cmdmod_split_o()
	if (flags & WSP_TOP_O) != 0 && (flags & WSP_BOT_O) != 0 {
		emsg(cstring(E442_S))
		return FAIL_S
	}

	// When creating the help window make a snapshot of the window layout.
	// Otherwise clear the snapshot, it's now invalid.
	if (flags & WSP_HELP_O) != 0 {
		make_snapshot(SNAP_HELP_IDX_O)
	} else {
		clear_snapshot_o(curtab, SNAP_HELP_IDX_O)
	}

	if (flags & WSP_QUICKFIX_O) != 0 {
		make_snapshot(SNAP_QUICKFIX_IDX_O)
	} else {
		clear_snapshot_o(curtab, SNAP_QUICKFIX_IDX_O)
	}

	return win_split_ins(size, flags, nil, 0, nil) == nil ? FAIL_S : OK_S
}

may_open_tabpage_o :: proc "c"() -> C.int {
	n := cmdmod_tab_o() == 0 ? postponed_split_tab_g : cmdmod_tab_o()

	if n == 0 {
		return FAIL_S
	}

	set_cmdmod_tab_o(0) // reset it to avoid doing it twice
	postponed_split_tab_g = 0

	if n == 0 {
		return FAIL_S
	}

		status: C.int = win_new_tabpage(n, nil, true, nil) != nil ? OK_S : FAIL_S
	if status == OK_S {
		apply_autocmds(EVENT_TABNEWENTERED_O, nil, nil, false, curbuf)
	}
	return status
}

@(export)
make_snapshot :: proc "c"(idx: C.int) {
	clear_snapshot_o(curtab, idx)
	slot := (^rawptr)(uintptr(curtab) + TP_SNAPSHOT_OFF + uintptr(idx) * 8)
	make_snapshot_rec_o(topframe_g, slot)
}

make_snapshot_rec_o :: proc "c"(fr: rawptr, frp: ^rawptr) {
	frp^ = xcalloc(1, 64)
	dst := frp^
	libc.memcpy(transmute(rawptr)(uintptr(dst) + FR_LAYOUT_OFF),
		transmute(rawptr)(uintptr(fr) + FR_LAYOUT_OFF), 1)
	(^C.int)(uintptr(dst) + FR_WIDTH_OFF)^ = (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^
	(^C.int)(uintptr(dst) + FR_HEIGHT_OFF)^ = (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^
	if (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
		make_snapshot_rec_o((^rawptr)(uintptr(fr) + FR_NEXT_OFF)^,
			(^rawptr)(uintptr(dst) + FR_NEXT_OFF))
	}
	if (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^ != nil {
		make_snapshot_rec_o((^rawptr)(uintptr(fr) + FR_CHILD_OFF)^,
			(^rawptr)(uintptr(dst) + FR_CHILD_OFF))
	}
	if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O &&
	(^rawptr)(uintptr(fr) + FR_WIN_OFF)^ == curwin {
		(^rawptr)(uintptr(dst) + FR_WIN_OFF)^ = curwin
	}
}

// Remove any existing snapshot.
clear_snapshot_o :: proc "c"(tp: rawptr, idx: C.int) {
	slot := (^rawptr)(uintptr(tp) + TP_SNAPSHOT_OFF + uintptr(idx) * 8)
	clear_snapshot_rec_o(slot^)
	slot^ = nil
}

clear_snapshot_rec_o :: proc "c"(fr: rawptr) {
	if fr == nil {
		return
	}
	clear_snapshot_rec_o((^rawptr)(uintptr(fr) + FR_NEXT_OFF)^)
	clear_snapshot_rec_o((^rawptr)(uintptr(fr) + FR_CHILD_OFF)^)
	xfree(fr)
}

xstrdup_o :: proc "c"(s: ^u8) -> ^u8 {
	n := libc.strlen(transmute(cstring)(s))
	dup := (^u8)(xmalloc_sp(n + 1))
	libc.memcpy(dup, s, n + 1)
	return dup
}

@(export)
win_init :: proc "c"(newp: rawptr, oldp: rawptr, flags: C.int) {
	(^rawptr)(uintptr(newp) + W_BUFFER_OFF)^ = (^rawptr)(uintptr(oldp) + W_BUFFER_OFF)^
	(^rawptr)(uintptr(newp) + W_S_OFF)^ = (^rawptr)(uintptr(oldp) + W_S_OFF)^
	(^C.int)(uintptr((^rawptr)(uintptr(oldp) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ += 1
	libc.memcpy(transmute(rawptr)(uintptr(newp) + W_CURSOR_OFF),
		transmute(rawptr)(uintptr(oldp) + W_CURSOR_OFF), 12)
	(^C.int)(uintptr(newp) + W_VALID_OFF)^ = 0
	(^C.int)(uintptr(newp) + W_CURSWANT_OFF)^ = (^C.int)(uintptr(oldp) + W_CURSWANT_OFF)^
	(^bool)(uintptr(newp) + W_SET_CURSWANT_OFF)^ = (^bool)(uintptr(oldp) + W_SET_CURSWANT_OFF)^
	(^C.int)(uintptr(newp) + W_TOPLINE_OFF)^ = (^C.int)(uintptr(oldp) + W_TOPLINE_OFF)^
	(^C.int)(uintptr(newp) + W_TOPFILL_OFF)^ = (^C.int)(uintptr(oldp) + W_TOPFILL_OFF)^
	(^C.int)(uintptr(newp) + W_LEFTCOL_OFF)^ = (^C.int)(uintptr(oldp) + W_LEFTCOL_OFF)^
	libc.memcpy(transmute(rawptr)(uintptr(newp) + W_PCMARK_OFF),
		transmute(rawptr)(uintptr(oldp) + W_PCMARK_OFF), 12)
	libc.memcpy(transmute(rawptr)(uintptr(newp) + W_PREV_PCMARK_OFF),
		transmute(rawptr)(uintptr(oldp) + W_PREV_PCMARK_OFF), 12)
	(^C.int)(uintptr(newp) + W_ALT_FNUM)^ = (^C.int)(uintptr(oldp) + W_ALT_FNUM)^
	(^C.int)(uintptr(newp) + W_WROW_OFF)^ = (^C.int)(uintptr(oldp) + W_WROW_OFF)^
	(^C.int)(uintptr(newp) + W_FRACTION_OFF)^ = (^C.int)(uintptr(oldp) + W_FRACTION_OFF)^
	(^C.int)(uintptr(newp) + W_PREV_FRACTION_ROW_OFF)^ = (^C.int)(uintptr(oldp) + W_PREV_FRACTION_ROW_OFF)^
	copy_jumplist(oldp, newp)
	if (flags & WSP_NEWLOC_O) != 0 {
		// Don't copy the location list.
		(^rawptr)(uintptr(newp) + W_LLIST_OFF)^ = nil
		(^rawptr)(uintptr(newp) + W_LLIST_REF_OFF)^ = nil
	} else {
		copy_loclist_stack_r(oldp, newp)
	}
	old_local := (^rawptr)(uintptr(oldp) + W_LOCALDIR_OFF)^
	(^rawptr)(uintptr(newp) + W_LOCALDIR_OFF)^ = old_local == nil ? nil : transmute(rawptr)(xstrdup_o(transmute(^u8)(old_local)))
	old_prev := (^rawptr)(uintptr(oldp) + W_PREVDIR_OFF)^
	(^rawptr)(uintptr(newp) + W_PREVDIR_OFF)^ = old_prev == nil ? nil : transmute(rawptr)(xstrdup_o(transmute(^u8)(old_prev)))

	if b_at(p_spk_g, 0) != 'c' {
		if b_at(p_spk_g, 0) == 't' {
			(^C.int)(uintptr(newp) + W_SKIPCOL_OFF)^ = (^C.int)(uintptr(oldp) + W_SKIPCOL_OFF)^
		}
		(^C.int)(uintptr(newp) + W_BOTLINE_OFF)^ = (^C.int)(uintptr(oldp) + W_BOTLINE_OFF)^
		(^C.int)(uintptr(newp) + W_PREV_HEIGHT_OFF)^ = (^C.int)(uintptr(oldp) + W_HEIGHT_OFF)^
		(^C.int)(uintptr(newp) + W_PREV_WINROW_OFF)^ = (^C.int)(uintptr(oldp) + W_WINROW_OFF)^
	}

	// copy tagstack and folds
	for i: C.int = 0; i < (^C.int)(uintptr(oldp) + W_TAGSTACKLEN_OFF)^; i += 1 {
		tag := (^u8)(uintptr(newp) + W_TAGSTACK_OFF + uintptr(i) * TAGGY_SIZE_O)
		otag := (^u8)(uintptr(oldp) + W_TAGSTACK_OFF + uintptr(i) * TAGGY_SIZE_O)
		libc.memcpy(tag, otag, TAGGY_SIZE_O)
		if ((^rawptr)(uintptr(tag) + TAGGY_TAGNAME_OFF))^ != nil {
			((^rawptr)(uintptr(tag) + TAGGY_TAGNAME_OFF))^ =
				transmute(rawptr)(xstrdup_o(transmute(^u8)(((^rawptr)(uintptr(tag) + TAGGY_TAGNAME_OFF))^)))
		}
		if ((^rawptr)(uintptr(tag) + TAGGY_USERDATA_OFF))^ != nil {
			((^rawptr)(uintptr(tag) + TAGGY_USERDATA_OFF))^ =
				transmute(rawptr)(xstrdup_o(transmute(^u8)(((^rawptr)(uintptr(tag) + TAGGY_USERDATA_OFF))^)))
		}
	}
	(^C.int)(uintptr(newp) + W_TAGSTACKIDX_OFF)^ = (^C.int)(uintptr(oldp) + W_TAGSTACKIDX_OFF)^
	(^C.int)(uintptr(newp) + W_TAGSTACKLEN_OFF)^ = (^C.int)(uintptr(oldp) + W_TAGSTACKLEN_OFF)^

	// Keep same changelist position in new window.
	(^C.int)(uintptr(newp) + W_CHANGELISTIDX_OFF)^ = (^C.int)(uintptr(oldp) + W_CHANGELISTIDX_OFF)^

	copyFoldingState(oldp, newp)

	win_init_some_o(newp, oldp)

	(^C.int)(uintptr(newp) + W_WINBAR_HEIGHT_OFF)^ = (^C.int)(uintptr(oldp) + W_WINBAR_HEIGHT_OFF)^
}

// Initialize window "newp" from window "old".
// Only the essential things are copied.
win_init_some_o :: proc "c"(newp: rawptr, oldp: rawptr) {
	// Use the same argument list.
	(^rawptr)(uintptr(newp) + W_ALIST_OFF)^ = (^rawptr)(uintptr(oldp) + W_ALIST_OFF)^
	(^C.int)(uintptr((^rawptr)(uintptr(newp) + W_ALIST_OFF)^) + AL_REFCOUNT_OFF)^ += 1
	(^C.int)(uintptr(newp) + W_ARG_IDX_OFF)^ = (^C.int)(uintptr(oldp) + W_ARG_IDX_OFF)^

	// copy options from existing window
	win_copy_options(oldp, newp)
}

// ── Batch 8: win_alloc/win_append ────────────────────────────────────────────

WIN_SIZE_O :: 11160
TP_LASTWIN_OFF :: 48
W_GRID_MOUSE_OFF :: 10515
W_VARS_OFF :: 4288
W_WINVAR_OFF :: 4264
W_NS_SET_SIZE :: 32 // C Set(uint32_t): 4xu32 + 2ptr
W_NS_SET_OFF :: 48
W_ALLBUF_SO_OFF :: 2880
W_SCBOUND_POS_OFF :: 4256
W_VIEWPORT_INVALID_OFF :: 564
W_VIEWPORT_LAST_TOPLINE_OFF :: 568
W_ALLBUF_SOP_OFF :: 2888
W_P_SOP_OFF :: 1184
W_ALLBUF_SISO_OFF :: 2872
W_P_SISO_OFF :: 1168
W_P_SO_OFF :: 1176
W_NEXT_MATCH_ID_OFF :: 9144
VAR_SCOPE_O :: 1

foreign _ {
	@(link_name = "nvim_odin_next_win_id")
	nvim_odin_next_win_id_r :: proc "c" () -> C.int ---
	@(link_name = "window_handles")
	window_handles_g: Map_int_ptr_t
	@(link_name = "grid_assign_handle")
	grid_assign_handle_r :: proc "c" (grid: rawptr) ---
	@(link_name = "tv_dict_alloc")
	tv_dict_alloc_r :: proc "c" () -> rawptr ---
	@(link_name = "init_var_dict")
	init_var_dict_r :: proc "c" (dict: rawptr, dict_var: rawptr, scope: C.int) ---
	@(link_name = "nvim_odin_init_winopt")
	nvim_odin_init_winopt_r :: proc "c" (win: rawptr) ---
}
// nvim_odin_init_winopt (option_shim.c) reused.

@(export)
win_alloc :: proc "c"(after: rawptr, hidden: bool) -> rawptr {
	// allocate window structure and linesizes arrays
	new_wp := xcalloc(1, WIN_SIZE_O)

	// Initialize window string options to empty_string_option so that they
	// are never NULL before the option defaults have been applied.
	nvim_odin_init_winopt_r(new_wp)

	(^C.int)(uintptr(new_wp) + W_HANDLE_OFF)^ = nvim_odin_next_win_id_r()
	new_item: bool = false
	slot := map_put_ref_int_ptr_t(&window_handles_g,
		(^C.int)(uintptr(new_wp) + W_HANDLE_OFF)^, nil, &new_item)
	slot^ = new_wp

	(^bool)(uintptr(new_wp) + W_GRID_MOUSE_OFF)^ = true

	grid_assign_handle_r(transmute(rawptr)(uintptr(new_wp) + W_GRID_ALLOC_OFF))

	// Init w: variables.
	vars := tv_dict_alloc_r()
	(^rawptr)(uintptr(new_wp) + W_VARS_OFF)^ = vars
	init_var_dict_r(vars, transmute(rawptr)(uintptr(new_wp) + W_WINVAR_OFF), VAR_SCOPE_O)

	// Don't execute autocommands while the window is not properly
	// initialized yet. gui_create_scrollbar() may trigger a FocusGained
	// event.
	block_autocmds_r()
	// link the window in the window list
	if !hidden {
		tp: rawptr = nil
		if after != nil {
			tp = win_find_tabpage(after)
			if tp == curtab {
				tp = nil
			}
		}
		win_append(after, new_wp, tp)
	}

	(^C.int)(uintptr(new_wp) + W_WINCOL_OFF)^ = 0
	(^C.int)(uintptr(new_wp) + W_WIDTH_OFF)^ = Columns

	// position the display and the cursor at the top of the file.
	(^C.int)(uintptr(new_wp) + W_TOPLINE_OFF)^ = 1
	(^C.int)(uintptr(new_wp) + W_TOPFILL_OFF)^ = 0
	(^C.int)(uintptr(new_wp) + W_BOTLINE_OFF)^ = 2
	(^C.int)(uintptr(new_wp) + W_CURSOR_OFF)^ = 1
	(^C.int)(uintptr(new_wp) + W_SCBOUND_POS_OFF)^ = 1
	(^bool)(uintptr(new_wp) + W_FLOATING_OFF)^ = false
	// w_config = WIN_CONFIG_INIT (xcalloc zeroed the rest): focusable,
	// mouse, zindex, bufpos.lnum, _cmdline_offset are nonzero.
	(^bool)(uintptr(new_wp) + WCFG_FOCUSABLE_OFF)^ = true
	(^bool)(uintptr(new_wp) + WCFG_MOUSE_OFF)^ = true
	(^C.int)(uintptr(new_wp) + WCFG_ZINDEX_OFF)^ = KZINDEX_FLOAT_DEFAULT_O
	(^C.int)(uintptr(new_wp) + WCFG_BUFPOS_LNUM_OFF)^ = -1
	(^C.int)(uintptr(new_wp) + WCFG_CMDLINE_OFF_OFF)^ = INT_MAX_O
	(^bool)(uintptr(new_wp) + W_VIEWPORT_INVALID_OFF)^ = true
	(^C.int)(uintptr(new_wp) + W_VIEWPORT_LAST_TOPLINE_OFF)^ = 1

	(^C.int)(uintptr(new_wp) + W_NS_HL_OFF)^ = -1

	libc.memset(transmute(rawptr)(uintptr(new_wp) + W_NS_SET_OFF), 0, W_NS_SET_SIZE)

	// use global option for global-local options
	(^C.longlong)(uintptr(new_wp) + W_ALLBUF_SO_OFF)^ = -1
	(^C.longlong)(uintptr(new_wp) + W_P_SO_OFF)^ = -1
	(^C.longlong)(uintptr(new_wp) + W_ALLBUF_SOP_OFF)^ = -1
	(^C.longlong)(uintptr(new_wp) + W_P_SOP_OFF)^ = -1
	(^C.longlong)(uintptr(new_wp) + W_ALLBUF_SISO_OFF)^ = -1
	(^C.longlong)(uintptr(new_wp) + W_P_SISO_OFF)^ = -1

	// We won't calculate w_fraction until resizing the window
	(^C.int)(uintptr(new_wp) + W_FRACTION_OFF)^ = 0
	(^C.int)(uintptr(new_wp) + W_PREV_FRACTION_ROW_OFF)^ = -1

	foldInitWin(new_wp)
	unblock_autocmds_r()
	(^C.int)(uintptr(new_wp) + W_NEXT_MATCH_ID_OFF)^ = 1000 // up to 1000 can be picked by the user
	return new_wp
}

// Append window "wp" in the window list after window "after".
//
// @param tp tab page "win" (and "after", if not NULL) is in, NULL for current
@(export)
win_append :: proc "c"(after: rawptr, wp: rawptr, tp: rawptr) {
	first := tp == nil ? &firstwin : transmute(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)
	last := tp == nil ? &lastwin_g : transmute(^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)

	// after NULL is in front of the first
	before := after == nil ? first^ : (^rawptr)(uintptr(after) + W_NEXT_OFF)^

	(^rawptr)(uintptr(wp) + W_NEXT_OFF)^ = before
	(^rawptr)(uintptr(wp) + W_PREV_OFF)^ = after
	if after == nil {
		first^ = wp
	} else {
		(^rawptr)(uintptr(after) + W_NEXT_OFF)^ = wp
	}
	if before == nil {
		last^ = wp
	} else {
		(^rawptr)(uintptr(before) + W_PREV_OFF)^ = wp
	}
}

// ── Batch 10: win_init_empty + tabpage walks ─────────────────────────────────

W_LINES_VALID_OFF :: 624

@(export)
win_init_empty :: proc "c"(wp: rawptr) {
	redraw_later_r(wp, UPD_NOT_VALID_O)
	(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = 1
	(^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ = 0 // w_cursor.col
	(^C.int)(uintptr(wp) + W_CURSOR_OFF + 8)^ = 0 // w_cursor.coladd
	(^C.int)(uintptr(wp) + W_PCMARK_OFF)^ = 1 // pcmark not cleared but set to line 1
	(^C.int)(uintptr(wp) + W_PCMARK_OFF + 4)^ = 0
	(^C.int)(uintptr(wp) + W_PREV_PCMARK_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_PREV_PCMARK_OFF + 4)^ = 0
	(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ = 1
	(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ = 0
	(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ = 2
	(^C.int)(uintptr(wp) + W_VALID_OFF)^ = 0
	(^rawptr)(uintptr(wp) + W_S_OFF)^ =
		transmute(rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_S_OFF)
}

// Init the current window "curwin".
// Called when a new file is being edited.
@(export)
curwin_init :: proc "c"() {
	win_init_empty(curwin)
}

@(export)
valid_tabpage :: proc "c"(tpc: rawptr) -> bool {
	tp := first_tabpage
	for tp != nil {
		if tp == tpc {
			return true
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	return false
}

// Returns true when `tpc` is valid and at least one window is valid.
@(export)
valid_tabpage_win :: proc "c"(tpc: rawptr) -> C.int {
	tp := first_tabpage
	for tp != nil {
		if tp == tpc {
			wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if win_valid_any_tab(wp) {
					return 1
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			return 0
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	// shouldn't happen
	return 0
}

// Get index of tab page "tp". First one has index 1.
// When not found returns number of tab pages plus one.
@(export)
tabpage_index :: proc "c"(ftp: rawptr) -> C.int {
	i: C.int = 1
	tp := first_tabpage
	for tp != nil && tp != ftp {
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		i += 1
	}
	return i
}

@(export)
win_find_tabpage :: proc "c"(win: rawptr) -> rawptr {
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if wp == win {
				return tp
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	return nil
}

@(export)
lastwin_nofloating :: proc "c"(tp: rawptr) -> rawptr {
	res := tp != nil ? (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ : lastwin_g
	for (^bool)(uintptr(res) + W_FLOATING_OFF)^ {
		res = (^rawptr)(uintptr(res) + W_PREV_OFF)^
	}
	return res
}

// ── Batch 11: startup alloc path + win_new_tabpage ───────────────────────────
// Offsets probed 2026-09-05 via off11/off11b (cc offsetof against real headers).

TP_TOPFRAME_OFF :: 16
TP_OLD_ROWS_AVAIL_OFF :: 56
TP_OLD_COLUMNS_OFF :: 64
TP_CH_USED_OFF :: 72
TP_DIFF_INVALID_OFF :: 160
TP_WINVAR_OFF :: 192
TP_VARS_OFF :: 216
TP_LOCALDIR_OFF :: 224
TP_PREVDIR_OFF :: 232
W_HEIGHT_OUTER_OFF :: 532
W_VIEW_WIDTH_OFF :: 504
W_WIDTH_OUTER_OFF :: 536
W_WINROW_OFF_OFF :: 492 // w_winrow_off (vs w_winrow@416)
W_P_SCB_OFF :: 1112
W_P_CRB_OFF :: 1152
TABPAGE_SIZE_O :: 240
BLN_LISTED_O :: 2
EVENT_TABLEAVE_O :: 115
EVENT_TABNEW_O :: 117
EVENT_TABENTER_O :: 114

// switchwin_T (eval/window.h): 2 ptrs + 2 bools = 24 bytes.
Switchwin_T :: struct {
	sw_curwin:       rawptr,
	sw_curtab:       rawptr,
	sw_same_win:     bool,
	sw_visual_active: bool,
}
#assert(size_of(Switchwin_T) == 24)

@(private="file")
last_tp_handle_b11: C.int = 0

foreign _ {
	@(link_name = "reset_VIsual_and_resel")
	reset_VIsual_and_resel_r :: proc "c" () ---
	@(link_name = "reset_dragwin")
	reset_dragwin_r :: proc "c" () ---
	@(link_name = "redraw_all_later")
	redraw_all_later_r :: proc "c" (type: C.int) ---
	@(link_name = "terminal_check_size")
	terminal_check_size_r :: proc "c" (term: rawptr) ---
	@(link_name = "switch_win_noblock")
	switch_win_noblock_r :: proc "c" (switchwin: rawptr, win: rawptr, tp: rawptr, no_display: bool) -> C.int ---
	@(link_name = "restore_win_noblock")
	restore_win_noblock_r :: proc "c" (switchwin: rawptr, no_display: bool) ---
	@(link_name = "tabpage_handles")
	tabpage_handles_g: Map_int_ptr_t
	@(link_name = "global_alist")
	global_alist_u8: u8 // address-of only (&global_alist); never read as value
}

// Allocate a new tabpage_T and init the values (C static: no export/weak).
alloc_tabpage_o :: proc "c"() -> rawptr {
	tp := xcalloc(1, TABPAGE_SIZE_O)
	last_tp_handle_b11 += 1
	(^C.int)(tp)^ = last_tp_handle_b11
	new_item: bool = false
	slot := map_put_ref_int_ptr_t(&tabpage_handles_g,
		(^C.int)(tp)^, nil, &new_item)
	slot^ = tp
	// Init t: variables.
	vars := tv_dict_alloc_r()
	(^rawptr)(uintptr(tp) + TP_VARS_OFF)^ = vars
	init_var_dict_r(vars, transmute(rawptr)(uintptr(tp) + TP_WINVAR_OFF), VAR_SCOPE_O)
	(^bool)(uintptr(tp) + TP_DIFF_INVALID_OFF)^ = true
	(^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^ = C.longlong(p_ch)
	return tp
}

// rows_avail shared helper (ROWS_AVAIL macro: Rows - p_ch - tabline - stl).
rows_avail_o :: proc "c"() -> C.int {
	return Rows - C.int(p_ch) - 		tabline_height() - 		global_stl_height()
}

// Allocate the first window or the first window in a new tab page
// (C static: no export/weak).
win_alloc_firstwin_o :: proc "c"(oldwin: rawptr) -> C.int {
	curwin = win_alloc(nil, false)
	if oldwin == nil {
		// Very first window, need to create an empty buffer for it and
		// initialize from scratch.
		curbuf = buflist_new(nil, nil, 1, BLN_LISTED_O)
		if curbuf == nil {
			return FAIL
		}
		(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = curbuf
		// ADDRESS of embedded b_s (Batch-10 lesson: never deref).
		(^rawptr)(uintptr(curwin) + W_S_OFF)^ =
			transmute(rawptr)(uintptr(curbuf) + B_S_OFF)
		(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ = 1
		(^rawptr)(uintptr(curwin) + W_ALIST_OFF)^ = transmute(rawptr)(&global_alist_u8)
		curwin_init() // init current window
	} else {
		// First window in new tab page, initialize it from "oldwin".
		win_init(curwin, oldwin, 0)
		// We don't want cursor- and scroll-binding in the first window.
		(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false // RESET_BINDING
		(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
	}
	new_frame_o(curwin)
	topframe_g = (^rawptr)(uintptr(curwin) + W_FRAME_OFF)^
	(^C.int)(uintptr(topframe_g) + FR_WIDTH_OFF)^ = Columns
	(^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^ =
		Rows - C.int(p_ch) - 		global_stl_height()
	return OK
}

// Allocate the first window and put an empty buffer in it.
// Only called from main().
@(export)
win_alloc_first :: proc "c"() {
	if win_alloc_firstwin_o(nil) == FAIL {
		// allocating first buffer before any autocmds should not fail.
		libc.abort()
	}
	first_tabpage = alloc_tabpage_o()
	curtab = first_tabpage
	unuse_tabpage(first_tabpage)
}

// Initialize the window and frame size to the maximum.
@(export)
win_init_size :: proc "c"() {
	(^C.int)(uintptr(firstwin) + W_HEIGHT_OFF)^ = rows_avail_o()
	(^C.int)(uintptr(firstwin) + W_PREV_HEIGHT_OFF)^ = rows_avail_o()
	(^C.int)(uintptr(firstwin) + W_VIEW_HEIGHT_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_HEIGHT_OFF)^ -
		(^C.int)(uintptr(firstwin) + W_WINBAR_HEIGHT_OFF)^
	(^C.int)(uintptr(firstwin) + W_HEIGHT_OUTER_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_HEIGHT_OFF)^
	(^C.int)(uintptr(firstwin) + W_WINROW_OFF_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_WINBAR_HEIGHT_OFF)^
	(^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^ = rows_avail_o()
	(^C.int)(uintptr(firstwin) + W_WIDTH_OFF)^ = Columns
	(^C.int)(uintptr(firstwin) + W_VIEW_WIDTH_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_WIDTH_OFF)^
	(^C.int)(uintptr(firstwin) + W_WIDTH_OUTER_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_WIDTH_OFF)^
	(^C.int)(uintptr(topframe_g) + FR_WIDTH_OFF)^ = Columns
}

// Stop using the current tab page: save window state into it (C static).
leave_tabpage_o :: proc "c"(new_curbuf: rawptr, trigger_leave_autocmds: bool) -> C.int {
	tp := curtab
	leaving_window(curwin)
	reset_VIsual_and_resel_r() // stop Visual mode
	if trigger_leave_autocmds {
		if new_curbuf != curbuf {
			apply_autocmds(EVENT_BUFLEAVE_O, nil, nil, false, curbuf)
			if curtab != tp {
				return FAIL
			}
		}
		apply_autocmds(EVENT_WINLEAVE_O, nil, nil, false, curbuf)
		if curtab != tp {
			return FAIL
		}
		apply_autocmds(EVENT_TABLEAVE_O, nil, nil, false, curbuf)
		if curtab != tp {
			return FAIL
		}
	}
	reset_dragwin_r()
	(^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ = curwin
	(^rawptr)(uintptr(tp) + TP_PREVWIN_OFF)^ = prevwin_g
	(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ = firstwin
	(^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ = lastwin_g
	(^C.longlong)(uintptr(tp) + TP_OLD_ROWS_AVAIL_OFF)^ = C.longlong(rows_avail_o())
	if (^C.longlong)(uintptr(tp) + TP_OLD_COLUMNS_OFF)^ != -1 {
		(^C.longlong)(uintptr(tp) + TP_OLD_COLUMNS_OFF)^ = C.longlong(Columns)
	}
	firstwin = nil
	lastwin_g = nil
	return OK
}

// Move external floats to curtab; mark windows pos-changed (C static).
tabpage_check_windows_o :: proc "c"(old_curtab: rawptr) {
	wp := (^rawptr)(uintptr(old_curtab) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		next_wp := (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
			if (^bool)(uintptr(wp) + WCFG_EXTERNAL_OFF)^ {
				win_remove(wp, old_curtab)
				win_append(lastwin_nofloating(nil), wp, nil)
			} else {
				ui_comp_remove_grid_r(transmute(rawptr)(uintptr(wp) + W_GRID_HANDLE_OFF))
			}
		}
		(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		wp = next_wp
	}
}

// Create a new tabpage with one window. Edits the current buffer, like :split.
@(export)
win_new_tabpage :: proc "c"(after: C.int, filename: cstring, enter: bool, first: ^rawptr) -> rawptr {
	old_curtab := curtab
	if window_layout_locked(CMD_TABNEW_O) {
		return nil
	}
	newtp := alloc_tabpage_o()
	// Remember the current windows in this Tab page.
	// Avoid side-effects via unuse_tabpage when not entering.
	if enter {
		if leave_tabpage_o(curbuf, true) == FAIL {
			xfree(newtp)
			return nil
		}
	} else {
		unuse_tabpage(curtab)
		// Save this to tell if we need to make room for the tabline.
		(^C.longlong)(uintptr(curtab) + TP_OLD_ROWS_AVAIL_OFF)^ = C.longlong(rows_avail_o())
		firstwin = nil
		lastwin_g = nil
	}
	old_local := (^rawptr)(uintptr(old_curtab) + TP_LOCALDIR_OFF)^
	(^rawptr)(uintptr(newtp) + TP_LOCALDIR_OFF)^ =
		old_local == nil ? nil : transmute(rawptr)(xstrdup_o(transmute(^u8)(old_local)))
	curtab = newtp
	// Create a new empty window (does not fail for first window of new tabpage).
	win_alloc_firstwin_o((^rawptr)(uintptr(old_curtab) + TP_CURWIN_OFF)^)
	if first != nil {
		first^ = curwin
	}
	// Make the new Tab page the new topframe.
	if after == 1 {
		// New tab page becomes the first one.
		(^rawptr)(uintptr(newtp) + TP_NEXT_OFF)^ = first_tabpage
		first_tabpage = newtp
	} else {
		tp := old_curtab
		if after > 0 {
			// Put new tab page before tab page "after".
			n: C.int = 2
			tp = first_tabpage
			for (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil && n < after {
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
				n += 1
			}
		}
		(^rawptr)(uintptr(newtp) + TP_NEXT_OFF)^ = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		(^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ = newtp
	}
	(^rawptr)(uintptr(newtp) + TP_FIRSTWIN_OFF)^ = curwin
	(^rawptr)(uintptr(newtp) + TP_LASTWIN_OFF)^ = curwin
	(^rawptr)(uintptr(newtp) + TP_CURWIN_OFF)^ = curwin
	win_init_size()
	(^C.int)(uintptr(firstwin) + W_WINROW_OFF)^ = 		tabline_height()
	(^C.int)(uintptr(firstwin) + W_PREV_WINROW_OFF)^ =
		(^C.int)(uintptr(firstwin) + W_WINROW_OFF)^
	win_comp_scroll(curwin)
	(^rawptr)(uintptr(newtp) + TP_TOPFRAME_OFF)^ = topframe_g
	last_status(false)
	if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^)
	}
	if enter {
		redraw_all_later_r(UPD_NOT_VALID_O)
		tabpage_check_windows_o(old_curtab)
		lastused_tabpage_g = old_curtab
		entering_window(curwin)
		apply_autocmds(EVENT_WINNEW_O, nil, nil, false, curbuf)
		apply_autocmds(EVENT_WINENTER_O, nil, nil, false, curbuf)
		apply_autocmds(EVENT_TABNEW_O, filename, filename, false, curbuf)
		apply_autocmds(EVENT_TABENTER_O, nil, nil, false, curbuf)
	} else {
		unuse_tabpage(curtab)
		use_tabpage(old_curtab)
		// Tabline maybe added, or its contents changed.
		redraw_tabline_opt = true
		if (^C.longlong)(uintptr(curtab) + TP_OLD_ROWS_AVAIL_OFF)^ != C.longlong(rows_avail_o()) {
			win_new_screen_rows()
		}
		// Trigger autocommands in the context of the new window.
		switchwin: Switchwin_T
		// tp_curwin is valid in newtp: does not fail.
		switch_win_noblock_r(&switchwin, (^rawptr)(uintptr(newtp) + TP_CURWIN_OFF)^, newtp, true)
		apply_autocmds(EVENT_WINNEW_O, nil, nil, false, curbuf)
		apply_autocmds(EVENT_TABNEW_O, filename, filename, false, curbuf)
		restore_win_noblock_r(&switchwin, true)
	}
	return newtp
}

// ── Batch 12: tabpage navigation (enter/goto/find) ───────────────────────────

foreign _ {
	@(link_name = "set_keep_msg")
	set_keep_msg_r :: proc "c" (s: cstring, hl_id: C.int) ---
	@(link_name = "skip_win_fix_scroll")
	skip_win_fix_scroll_g: bool
	@(link_name = "diff_need_scrollbind")
	diff_need_scrollbind_g: bool
	@(link_name = "nvim_odin_set_command_frame_height")
	nvim_odin_set_command_frame_height_r :: proc "c" (v: bool) ---
}

// Start using tab page "tp" (C static: no export/weak).
// Only to be used after leave_tabpage() or freeing the current tab page.
enter_tabpage_o :: proc "c"(tp: rawptr, old_curbuf: rawptr, trigger_enter_autocmds: bool, trigger_leave_autocmds: bool) {
	old_off := (^C.int)(uintptr((^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^) + W_WINROW_OFF)^
	next_prevwin := (^rawptr)(uintptr(tp) + TP_PREVWIN_OFF)^
	old_curtab := curtab
	prev_p_ch := p_ch
	use_tabpage(tp)
	if old_curtab != curtab && p_ch != prev_p_ch {
		tabpage_check_windows_o(old_curtab)
		// use_tabpage() loaded a different cmdheight for the new tab. Fire
		// OptionSet and adjust the cmdline row without touching frame sizes.
		new_ch := p_ch
		p_ch = prev_p_ch
		nvim_odin_set_command_frame_height_r(false)
		set_option_value(kOptCmdheight_E, num_optval(new_ch), 0)
		nvim_odin_set_command_frame_height_r(true)
	} else if old_curtab != curtab {
		tabpage_check_windows_o(old_curtab)
	}
	// We would like doing the TabEnter event first, but we don't have a
	// valid current window yet, which may break some commands.
	win_enter_ext_o((^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^, WEE_CURWIN_INVALID_O |
		(trigger_enter_autocmds ? WEE_TRIGGER_ENTER_AUTOCMDS_O : 0) |
		(trigger_leave_autocmds ? WEE_TRIGGER_LEAVE_AUTOCMDS_O : 0))
	prevwin_g = next_prevwin
	last_status(false) // status line may appear or disappear
	win_float_update_statusline_r(nil)
	win_comp_pos() // recompute w_winrow for all windows
	diff_need_scrollbind_g = true
	// If there was a click in a window, it won't be usable for a following drag.
	reset_dragwin_r()
	// The tabpage line may have appeared or disappeared, may need to resize
	// the frames for that. When the Vim window was resized or ROWS_AVAIL
	// changed need to update frame sizes too.
	if (^C.longlong)(uintptr(curtab) + TP_OLD_ROWS_AVAIL_OFF)^ != C.longlong(rows_avail_o()) ||
		old_off != (^C.int)(uintptr(firstwin) + W_WINROW_OFF)^ {
		win_new_screen_rows()
	}
	if (^C.longlong)(uintptr(curtab) + TP_OLD_COLUMNS_OFF)^ != C.longlong(Columns) {
		if starting == 0 {
			win_new_screen_cols() // update window widths
			(^C.longlong)(uintptr(curtab) + TP_OLD_COLUMNS_OFF)^ = C.longlong(Columns)
		} else {
			(^C.longlong)(uintptr(curtab) + TP_OLD_COLUMNS_OFF)^ = -1 // update later
		}
	}
	lastused_tabpage_g = old_curtab
	// Apply autocommands after updating the display, when 'rows' and
	// 'columns' have been set correctly.
	if trigger_enter_autocmds {
		apply_autocmds(EVENT_TABENTER_O, nil, nil, false, curbuf)
		if old_curbuf != curbuf {
			apply_autocmds(EVENT_BUFENTER_O, nil, nil, false, curbuf)
		}
	}
	redraw_all_later_r(UPD_NOT_VALID_O)
}

// Find tab page "n" (first one is 1). Returns NULL when not found.
@(export)
find_tabpage :: proc "c"(n: C.int) -> rawptr {
	if n == 0 {
		return curtab
	}
	i: C.int = 1
	tp := first_tabpage
	for tp != nil && i != n {
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		i += 1
	}
	return tp
}

@(export)
goto_tabpage :: proc "c"(n: C.int) {
	if text_locked_r() {
		// Not allowed when editing the command line.
		text_locked_msg_r()
		return
	}
	// If there is only one it can't work.
	if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil {
		if n > 1 {
			beep_flush_r()
		}
		return
	}
	tp: rawptr = nil // shut up compiler
	if n == 0 {
		// No count, go to next tab page, wrap around end.
		if (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^ == nil {
			tp = first_tabpage
		} else {
			tp = (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
		}
	} else if n < 0 {
		// "gT": go to previous tab page, wrap around end. "N gT" repeats this N times.
		ttp := curtab
		for i := n; i < 0; i += 1 {
			tp = first_tabpage
			for (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != ttp &&
				(^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil {
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}
			ttp = tp
		}
	} else if n == 9999 {
		// Go to last tab page.
		tp = first_tabpage
		for (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil {
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
	} else {
		// Go to tab page "n".
		tp = find_tabpage(n)
		if tp == nil {
			beep_flush_r()
			return
		}
	}
	goto_tabpage_tp(tp, true, true)
}

// Go to tabpage "tp". Note: doesn't update the GUI tab.
@(export)
goto_tabpage_tp :: proc "c"(tp: rawptr, trigger_enter_autocmds: bool, trigger_leave_autocmds: bool) {
	// Don't repeat a message in another tab page.
	set_keep_msg_r(nil, 0)
	skip_win_fix_scroll_g = true
	if tp != curtab &&
		leave_tabpage_o((^rawptr)(uintptr((^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^) + W_BUFFER_OFF)^,
			trigger_leave_autocmds) == OK {
		if valid_tabpage(tp) {
			enter_tabpage_o(tp, curbuf, trigger_enter_autocmds, trigger_leave_autocmds)
		} else {
			enter_tabpage_o(curtab, curbuf, trigger_enter_autocmds, trigger_leave_autocmds)
		}
	}
	skip_win_fix_scroll_g = false
}

// Go to the last accessed tab page, if there is one.
@(export)
goto_tabpage_lastused :: proc "c"() -> bool {
	if !valid_tabpage(lastused_tabpage_g) {
		return false
	}
	goto_tabpage_tp(lastused_tabpage_g, true, true)
	return true
}

// Enter window "wp" in tab page "tp". Also updates the GUI tab.
@(export)
goto_tabpage_win :: proc "c"(tp: rawptr, wp: rawptr) {
	goto_tabpage_tp(tp, true, true)
	if curtab == tp && win_valid(wp) {
		win_enter(wp, true)
	}
}

// ── Batch 13: close_tabpage + win_goto + neighbor walks ──────────────────────
// w_wcol@604 / w_p_cole@1144 probed 2026-09-05 via off13 (w_wrow@600,
// w_wincol@440, w_winrow@416, w_cursor@136 all matched existing consts).

W_WCOL_OFF :: 604
W_P_COLE_OFF :: 1144
WCFG_HIDE_OFF :: 11030 // w_config.hide (WinConfig+470, probed off15b)

foreign _ {
	@(link_name = "text_or_buf_locked")
	text_or_buf_locked_r :: proc "c" () -> bool ---
}

// Close tabpage "tab", assuming it has no windows in it.
// There must be another tabpage or this will crash.
@(export)
close_tabpage :: proc "c"(tab: rawptr) {
	ptp: rawptr
	if tab == first_tabpage {
		first_tabpage = (^rawptr)(uintptr(tab) + TP_NEXT_OFF)^
		ptp = first_tabpage
	} else {
		ptp = first_tabpage
		for ptp != nil && (^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^ != tab {
			// do nothing
			ptp = (^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^
		}
		// ptp != NULL (there must be another tabpage).
		(^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^ = (^rawptr)(uintptr(tab) + TP_NEXT_OFF)^
	}
	goto_tabpage_tp(ptp, false, false)
		free_tabpage(tab)
}

// Go to another window. When jumping to another buffer, stop Visual mode.
@(export)
win_goto :: proc "c"(wp: rawptr) {
	owp := curwin
	if text_or_buf_locked_r() {
		beep_flush_r()
		return
	}
	if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
		// careful: triggers ModeChanged autocommand
		reset_VIsual_and_resel_r()
	} else if VIsual_active {
		libc.memcpy(transmute(rawptr)(uintptr(wp) + W_CURSOR_OFF),
			transmute(rawptr)(uintptr(curwin) + W_CURSOR_OFF), 12)
	}
	// autocommand may have made wp invalid
	if !win_valid(wp) {
		return
	}
	win_enter(wp, true)
	// Conceal cursor line in previous window, unconceal in current window.
	if win_valid(owp) && (^C.int)(uintptr(owp) + W_P_COLE_OFF)^ > 0 && msg_scrolled == 0 {
		redrawWinline_r(owp, (^C.int)(uintptr(owp) + W_CURSOR_OFF)^)
	}
	if (^C.int)(uintptr(curwin) + W_P_COLE_OFF)^ > 0 && msg_scrolled == 0 {
		redrawWinline_r(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
	}
}

// Get the above or below neighbor window of the specified window.
@(export)
win_vert_neighbor :: proc "c"(tp: rawptr, wp: rawptr, up: bool, count: C.int) -> rawptr {
	foundfr := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		return win_valid(prevwin_g) && !(^bool)(uintptr(prevwin_g) + W_FLOATING_OFF)^ ? prevwin_g : firstwin
	}
	n := count
	done := false
	for n > 0 && !done {
		n -= 1
		nfr: rawptr = nil
		// First go upwards in the tree of frames until we find an upwards or
		// downwards neighbor.
		fr := foundfr
		up_done := false
		for !up_done && !done {
			if fr == (^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^ {
				done = true
			} else {
				if up {
					nfr = (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
				} else {
					nfr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
				if b_at((^u8)(uintptr((^rawptr)(uintptr(fr) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_COL_O && nfr != nil {
					up_done = true
				} else {
					fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
				}
			}
		}
		if done {
			break
		}
		// Now go downwards to find the bottom or top frame in it.
		for {
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
				foundfr = nfr
				break
			}
			fr = (^rawptr)(uintptr(nfr) + FR_CHILD_OFF)^
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
				// Find the frame at the cursor row.
				for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil &&
					(^C.int)(uintptr(frame2win(fr)) + W_WINCOL_OFF)^ +
					(^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ <=
					(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + (^C.int)(uintptr(wp) + W_WCOL_OFF)^ {
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
			}
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_COL_O && up {
				for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
			}
			nfr = fr
		}
	}
	if foundfr != nil {
		return (^rawptr)(uintptr(foundfr) + FR_WIN_OFF)^
	}
	return nil
}

// Move to window above or below "count" times (C static: no export/weak).
win_goto_ver_o :: proc "c"(up: bool, count: C.int) {
	win := win_vert_neighbor(curtab, curwin, up, count)
	if win != nil {
		win_goto(win)
	}
}

// Get the left or right neighbor window of the specified window.
@(export)
win_horz_neighbor :: proc "c"(tp: rawptr, wp: rawptr, left: bool, count: C.int) -> rawptr {
	foundfr := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		return win_valid(prevwin_g) && !(^bool)(uintptr(prevwin_g) + W_FLOATING_OFF)^ ? prevwin_g : firstwin
	}
	n := count
	done := false
	for n > 0 && !done {
		n -= 1
		nfr: rawptr = nil
		// First go upwards in the tree of frames until we find a left or
		// right neighbor.
		fr := foundfr
		up_done := false
		for !up_done && !done {
			if fr == (^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^ {
				done = true
			} else {
				if left {
					nfr = (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
				} else {
					nfr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
				if b_at((^u8)(uintptr((^rawptr)(uintptr(fr) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_ROW_O && nfr != nil {
					up_done = true
				} else {
					fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
				}
			}
		}
		if done {
			break
		}
		// Now go downwards to find the leftmost or rightmost frame in it.
		for {
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
				foundfr = nfr
				break
			}
			fr = (^rawptr)(uintptr(nfr) + FR_CHILD_OFF)^
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_COL_O {
				// Find the frame at the cursor row.
				for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil &&
					(^C.int)(uintptr(frame2win(fr)) + W_WINROW_OFF)^ +
					(^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ <=
					(^C.int)(uintptr(wp) + W_WINROW_OFF)^ + (^C.int)(uintptr(wp) + W_WROW_OFF)^ {
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
			}
			if b_at((^u8)(uintptr(nfr) + FR_LAYOUT_OFF), 0) == FR_ROW_O && left {
				for (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ != nil {
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
			}
			nfr = fr
		}
	}
	if foundfr != nil {
		return (^rawptr)(uintptr(foundfr) + FR_WIN_OFF)^
	}
	return nil
}

// Move to left or right window (C static: no export/weak).
win_goto_hor_o :: proc "c"(left: bool, count: C.int) {
	win := win_horz_neighbor(curtab, curwin, left, count)
	if win != nil {
		win_goto(win)
	}
}

// Make window "wp" the current window.
@(export)
win_enter :: proc "c"(wp: rawptr, undo_sync: bool) {
	win_enter_ext_o(wp, (undo_sync ? WEE_UNDO_SYNC_O : 0) |
		WEE_TRIGGER_ENTER_AUTOCMDS_O | WEE_TRIGGER_LEAVE_AUTOCMDS_O)
}

// ── Batch 14: win_close helper statics ───────────────────────────────────────
// b_p_bl@10172 (bool) / w_locked@120 (int) probed 2026-09-05 via off14
// (w_buffer@8 matched existing W_BUFFER_OFF).

W_LOCKED_OFF :: 120
B_P_BL_OFF :: 10172
DOBUF_UNLOAD_O :: 2
EVENT_WINCLOSED_O :: 142

@(private="file")
do_autocmd_winclosed_busy: bool = false

foreign _ {
	@(link_name = "reset_synblock")
	reset_synblock_r :: proc "c" (wp: rawptr) ---
	@(link_name = "close_buffer")
	close_buffer_r :: proc "c" (win: rawptr, buf: rawptr, action: C.int, abort_if_last: bool, ignore_abort: bool, set_context: bool) -> bool ---
	@(link_name = "has_event")
	has_event_r :: proc "c" (e: C.int) -> bool ---
}

// Close the possibly last window in a tab page (C static: no export/weak).
// Returns false if there are other windows and nothing is done.
close_last_window_tabpage_o :: proc "c"(win: rawptr, free_buf: bool, prev_curtab: rawptr) -> bool {
	if firstwin != lastwin_g { // !ONE_WINDOW
		return false
	}
	old_curbuf := curbuf
	term: rawptr = nil
	if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
		term = (^rawptr)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^
	}
	fb := free_buf
	if term != nil {
		// Don't free terminal buffers
		fb = false
	}
	// Closing the last window in a tab page. First go to another tab page
	// and then close the window and the tab page.
	goto_tabpage_tp(alt_tabpage_o(), false, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil)
	// Safety check: Autocommands may have switched back to the old tab page
	// or closed the window when jumping to the other tab page.
	if curtab != prev_curtab && valid_tabpage(prev_curtab) &&
		(^rawptr)(uintptr(prev_curtab) + TP_FIRSTWIN_OFF)^ == win {
		win_close_othertab(win, fb ? 1 : 0, prev_curtab, false)
	}
	entering_window(curwin)
	// Since goto_tabpage_tp above did not trigger *Enter autocommands, do
	// that now.
	apply_autocmds(EVENT_WINENTER_O, nil, nil, false, curbuf)
	apply_autocmds(EVENT_TABENTER_O, nil, nil, false, curbuf)
	if old_curbuf != curbuf {
		apply_autocmds(EVENT_BUFENTER_O, nil, nil, false, curbuf)
	}
	return true
}

// Close the buffer of "win" and unload it if "action" is DOBUF_UNLOAD
// (C static: no export/weak).
win_close_buffer_o :: proc "c"(win: rawptr, action: C.int, abort_if_last: bool) -> bool {
	// Free independent synblock before the buffer is freed.
	if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
		reset_synblock_r(win)
	}
	// When a quickfix/location list window is closed and the buffer is
	// displayed in only one window, then unlist the buffer.
	buf := (^rawptr)(uintptr(win) + W_BUFFER_OFF)^
	if buf != nil && bt_quickfix(buf) && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 1 {
		(^bool)(uintptr(buf) + B_P_BL_OFF)^ = false
	}
	retval := false
	// Close the link to the buffer.
	if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
		bufref: Bufref_T
		set_bufref(&bufref, curbuf)
		(^C.int)(uintptr(win) + W_LOCKED_OFF)^ += 1
		retval = close_buffer_r(win, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^,
			action, abort_if_last, true, true)
		if win_valid_any_tab(win) {
			(^C.int)(uintptr(win) + W_LOCKED_OFF)^ -= 1
		}
		// Make sure curbuf is valid. It can become invalid if 'bufhidden'
		// is "wipe".
		if !bufref_valid(&bufref) {
			curbuf = firstbuf
		}
	}
	return retval
}

// When failing to close a window after already calling close_buffer() on it,
// call this to make the window have a buffer again (C static).
win_unclose_buffer_o :: proc "c"(win: rawptr, bufref: ^Bufref_T) {
	if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == nil {
		// If the buffer was removed from the window we have to give it any buffer.
		(^rawptr)(uintptr(win) + W_BUFFER_OFF)^ = firstbuf
		(^C.int)(uintptr(firstbuf) + B_NWINDOWS_OFF)^ += 1
		if win == curwin {
			curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
		}
		win_init_empty(win)
	}
}

// Fire WinClosed just before starting to free window resources (C static).
do_autocmd_winclosed_o :: proc "c"(win: rawptr) {
	if do_autocmd_winclosed_busy || !has_event_r(EVENT_WINCLOSED_O) {
		return
	}
	do_autocmd_winclosed_busy = true
	winid: [NUMBUFLEN]u8
	libc.snprintf(&winid[0], NUMBUFLEN, cstring("%d"),
		(^C.int)(uintptr(win) + W_HANDLE_OFF)^)
	apply_autocmds(EVENT_WINCLOSED_O, cstring(&winid[0]), cstring(&winid[0]),
		false, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^)
	do_autocmd_winclosed_busy = false
}

// ── Batch 15: win_close proper ───────────────────────────────────────────────
// Offsets probed 2026-09-05 via off15: B_LOCKED 144/B_LOCKED_SPLIT 148 (int),
// TP_DID_TABCLOSEDPRE 80 (bool), W_STATUS_HEIGHT 432 (int), W_P_PVW 1008 (int),
// CMD_close 79. Error strings from source: E444/E813/E5601/E814.

B_LOCKED_OFF :: 144
B_LOCKED_SPLIT_OFF :: 148
TP_DID_TABCLOSEDPRE_OFF :: 80
W_P_PVW_OFF :: 1008
CMD_CLOSE_O :: 79
EVENT_TABCLOSED_O :: 112
EVENT_TABCLOSEDPRE_O :: 113
E_CANNOT_CLOSE_LAST_WINDOW_S :: "E444: Cannot close last window"
E_AUTOCMD_CLOSE_S :: "E813: Cannot close autocmd window"
E_FLOATONLY_S :: "E5601: Cannot close window, only floating window would remain"
E_AUCMD_ONLY_S :: "E814: Cannot close window, only autocmd window would remain"

@(private="file")
trigger_tabclosedpre_busy: bool = false

foreign _ {
	@(link_name = "win_float_find_altwin")
	win_float_find_altwin_r :: proc "c" (win: rawptr, tp: rawptr) -> rawptr ---
 	@(link_name = "diffopt_closeoff")
	diffopt_closeoff_r :: proc "c" () -> bool ---
	@(link_name = "ui_call_win_close")
	ui_call_win_close_r :: proc "c" (grid: C.longlong) ---
	@(link_name = "nvim_odin_set_split_disallowed")
	nvim_odin_set_split_disallowed_r :: proc "c" (v: C.int) ---
	@(link_name = "p_ru")
	p_ru_g: C.int
	@(link_name = "redraw_cmdline")
	redraw_cmdline_g: bool
	@(link_name = "cmdline_win")
	cmdline_win_g: rawptr
}

// Check if floating windows in tabpage "tp" can be closed (C static).
can_close_floating_windows_o :: proc "c"(tp: rawptr) -> bool {
	for wp := tp != nil ? (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ : lastwin_g;
		(^bool)(uintptr(wp) + W_FLOATING_OFF)^;
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^ {
		buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		need_hide := bufIsChanged(buf) && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 1
		if need_hide && !buf_hide(buf) {
			return false
		}
	}
	return true
}

@(export)
trigger_tabclosedpre :: proc "c"(tp: rawptr) {
	ptp := curtab
	// Quickly return when no TabClosedPre autocommands to be executed or
	// already executing.
	if !has_event_r(EVENT_TABCLOSEDPRE_O) || trigger_tabclosedpre_busy {
		return
	}
	if valid_tabpage(tp) {
		goto_tabpage_tp(tp, false, false)
	}
	trigger_tabclosedpre_busy = true
	window_layout_lock()
	apply_autocmds(EVENT_TABCLOSEDPRE_O, nil, nil, false, nil)
	window_layout_unlock()
	trigger_tabclosedpre_busy = false
	// tabpage may have been modified or deleted by autocmds
	if valid_tabpage(ptp) {
		// try to recover the tabpage first
		goto_tabpage_tp(ptp, false, false)
	} else {
		// fall back to the first tabpage
		goto_tabpage_tp(first_tabpage, false, false)
	}
}

// Traverse a snapshot to find the previous curwin (C statics).
get_snapshot_curwin_rec_o :: proc "c"(ft: rawptr) -> rawptr {
	wp: rawptr
	if (^rawptr)(uintptr(ft) + FR_NEXT_OFF)^ != nil {
		wp = get_snapshot_curwin_rec_o((^rawptr)(uintptr(ft) + FR_NEXT_OFF)^)
		if wp != nil {
			return wp
		}
	}
	if (^rawptr)(uintptr(ft) + FR_CHILD_OFF)^ != nil {
		wp = get_snapshot_curwin_rec_o((^rawptr)(uintptr(ft) + FR_CHILD_OFF)^)
		if wp != nil {
			return wp
		}
	}
	return (^rawptr)(uintptr(ft) + FR_WIN_OFF)^
}

get_snapshot_curwin_o :: proc "c"(idx: C.int) -> rawptr {
	if (^rawptr)(uintptr(curtab) + TP_SNAPSHOT_OFF + uintptr(idx) * 8)^ == nil {
		return nil
	}
	return get_snapshot_curwin_rec_o((^rawptr)(uintptr(curtab) + TP_SNAPSHOT_OFF + uintptr(idx) * 8)^)
}

// Close window "win" in tab page "tp", which is not the current tab page.
@(export)
win_close_othertab :: proc "c"(win: rawptr, free_buf: C.int, tp: rawptr, force: bool) -> bool {
	bufref: Bufref_T // (declared up front: leave_open sites below use it)
	leave_open := false
	// Commands that may call win_close_othertab() already check this, but
	// check here again just in case.
	if window_layout_locked(CMD_SIZE_O) {
		return false
	}
	// Get here with win->w_buffer == NULL when win_close() detects the tab
	// page changed.
	if win_locked(win) != 0 ||
		((^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil &&
			(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_LOCKED_OFF)^ > 0) {
		return false // window is already being closed
	}
	if is_aucmd_win_r(win) {
		emsg(cstring(E_AUTOCMD_CLOSE_S))
		return false
	}
	// Check if closing this window would leave only floating windows.
	if (^bool)(uintptr((^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^) + W_FLOATING_OFF)^ &&
		one_window(win, tp) {
		if force || can_close_floating_windows_o(tp) {
			// close the last window until the there are no floating windows
			for (^bool)(uintptr((^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^) + W_FLOATING_OFF)^ && !leave_open {
				// `force` flag isn't actually used when closing a floating window.
				lastw := (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^
				hide: C.int = buf_hide((^rawptr)(uintptr(lastw) + W_BUFFER_OFF)^) ? 0 : 1
				if !win_close_othertab(lastw, hide, tp, true) {
					// If closing the window fails give up, to avoid looping forever.
					leave_open = true
				}
			}
			if !leave_open && !win_valid_any_tab(win) {
				return false // window already closed by autocommands
			}
		} else {
			emsg(cstring(E_FLOATONLY_S))
			leave_open = true
		}
	}
	if !leave_open {
		// Fire WinClosed just before starting to free window-related resources.
		// If the buffer is NULL, it isn't safe to trigger autocommands,
		// and win_close() should have already triggered WinClosed.
		if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
			do_autocmd_winclosed_o(win)
			// autocmd may have freed the window already.
			if !win_valid_any_tab(win) {
				return false
			}
		}
		if (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ == (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ &&
			!(^bool)(uintptr(tp) + TP_DID_TABCLOSEDPRE_OFF)^ {
			trigger_tabclosedpre(tp)
			// autocmd may have freed the window already.
			if !win_valid_any_tab(win) {
				return false
			}
		}
		set_bufref(&bufref, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^)
		if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
			// Close the link to the buffer.
			fb := free_buf
			close_buffer_r(win, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^,
				fb != 0 ? DOBUF_UNLOAD_O : 0, false, true, true)
		}
		// Careful: Autocommands may have closed the tab page or made it the
		// current tab page.
		if !valid_tabpage(tp) || tp == curtab {
			leave_open = true
		} else if !tabpage_win_valid(tp, win) {
			// Autocommands may have closed the window already, or
			// nvim_win_set_config moved it to a different tab page.
			leave_open = true
		} else if (^bool)(uintptr((^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^) + W_FLOATING_OFF)^ &&
			one_window(win, tp) {
			// Autocommands may again cause closing this window to leave only
			// floats. Check again; we'll not bother closing floating windows
			// this time.
			emsg(cstring(E_FLOATONLY_S))
			leave_open = true
		}
	}
	if !leave_open {
		free_tp_idx: C.int = 0
		// When closing the last window in a tab page remove the tab page.
		if (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ == (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ {
			free_tp_idx = tabpage_index(tp)
			h := 		tabline_height()
			if tp == first_tabpage {
				first_tabpage = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			} else {
				ptp := first_tabpage
				for ptp != nil && (^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^ != tp {
					// loop
					ptp = (^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^
				}
				if ptp == nil {
					_internal_error(cstring("win_close_othertab()"))
					return false
				}
				(^rawptr)(uintptr(ptp) + TP_NEXT_OFF)^ = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}
			redraw_tabline_opt = true
			if h != 		tabline_height() {
				win_new_screen_rows()
			}
		}
		// About to free the window. Remember its final buffer for
		// terminal_check_size/TabClosed, which may have changed since the
		// last set_bufref. (e.g: close_buffer autocmds)
		set_bufref(&bufref, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^)
		if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
			(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ -= 1
		}
		// Free the memory used for the window.
		dir: C.int = 0
		win_free_mem_o(win, &dir, tp)
		if bufref.br_buf != nil && bufref_valid(&bufref) &&
			(^rawptr)(uintptr(bufref.br_buf) + B_TERMINAL_OFF)^ != nil {
			terminal_check_size_r((^rawptr)(uintptr(bufref.br_buf) + B_TERMINAL_OFF)^)
		}
		if free_tp_idx > 0 {
			free_tabpage(tp)
			if has_event_r(EVENT_TABCLOSED_O) {
				prev_idx: [NUMBUFLEN]u8
				libc.snprintf(&prev_idx[0], NUMBUFLEN, cstring("%i"), free_tp_idx)
				apply_autocmds(EVENT_TABCLOSED_O, cstring(&prev_idx[0]),
					cstring(&prev_idx[0]), false,
					bufref.br_buf != nil && bufref_valid(&bufref) ? bufref.br_buf : curbuf)
			}
		}
		return true
	}
	if win_valid_any_tab(win) {
		win_unclose_buffer_o(win, &bufref)
	}
	return false
}

// Free the memory used for a window (C static: no export/weak).
// Returns a pointer to the window that got the freed up space.
win_free_mem_o :: proc "c"(win: rawptr, dirp: ^C.int, tp: rawptr) -> rawptr {
	win_tp := tp != nil ? tp : curtab
	wp: rawptr
	if !(^bool)(uintptr(win) + W_FLOATING_OFF)^ {
		// Remove the window and its frame from the tree of frames.
		frp := (^rawptr)(uintptr(win) + W_FRAME_OFF)^
		wp = winframe_remove(win, dirp, tp, nil)
		xfree(frp)
	} else {
		dirp^ = C.int('h') // Dummy value.
		wp = win_float_find_altwin_r(win, tp)
	}
	win_free(win, tp)
	// When deleting the current window in the tab, select a new current window.
	if win == (^rawptr)(uintptr(win_tp) + TP_CURWIN_OFF)^ {
		(^rawptr)(uintptr(win_tp) + TP_CURWIN_OFF)^ = wp
	}
	// Avoid executing cmdline_win logic after it is closed.
	if win == cmdline_win_g {
		cmdline_win_g = nil
	}
	return wp
}

// Close window "win". Only works for the current tab page.
// Called by :quit, :close, :xit, :wq and findtag().
// Returns FAIL when the window was not closed.
@(export)
win_close :: proc "c"(win: rawptr, free_buf: bool, force: bool) -> C.int {
	prev_curtab := curtab
	win_frame: rawptr = nil
	if !(^bool)(uintptr(win) + W_FLOATING_OFF)^ {
		win_frame = (^rawptr)(uintptr((^rawptr)(uintptr(win) + W_FRAME_OFF)^) + FR_PARENT_OFF)^
	}
	had_diffmode := (^C.int)(uintptr(win) + W_P_DIFF_OFF)^
	if last_window(win) {
		emsg(cstring(E_CANNOT_CLOSE_LAST_WINDOW_S))
		return FAIL
	}
	if !(^bool)(uintptr(win) + W_FLOATING_OFF)^ && window_layout_locked(CMD_CLOSE_O) {
		return FAIL
	}
	if win_locked(win) != 0 ||
		((^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil &&
			(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_LOCKED_OFF)^ > 0) {
		return FAIL // window is already being closed
	}
	if is_aucmd_win_r(win) {
		emsg(cstring(E_AUTOCMD_CLOSE_S))
		return FAIL
	}
	if (^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^ && one_window(win, nil) {
		if is_aucmd_win_r(lastwin_g) {
			emsg(cstring(E_AUCMD_ONLY_S))
			return FAIL
		}
		if force || can_close_floating_windows_o(nil) {
			// close the last window until the there are no floating windows
			for (^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^ {
				// `force` flag isn't actually used when closing a floating window.
				hide := buf_hide((^rawptr)(uintptr(lastwin_g) + W_BUFFER_OFF)^) ? 0 : 1
				if win_close(lastwin_g, hide != 0, true) == FAIL {
					// If closing the window fails give up, to avoid looping forever.
					return FAIL
				}
			}
			if !win_valid_any_tab(win) {
				return FAIL // window already closed by autocommands
			}
			// Autocommands may have closed all other tabpages; check again.
			if last_window(win) {
				emsg(cstring(E_CANNOT_CLOSE_LAST_WINDOW_S))
				return FAIL
			}
		} else {
			emsg(cstring(E_FLOATONLY_S))
			return FAIL
		}
	}
	// When closing the last window in a tab page first go to another tab page
	// and then close the window and the tab page to avoid that curwin and
	// curtab are invalid while we are freeing memory.
	if close_last_window_tabpage_o(win, free_buf, prev_curtab) {
		return FAIL
	}
	help_window := false
	quickfix_window := false
	// When closing the help window, try restoring a snapshot after closing
	// the window. Otherwise clear the snapshot, it's now invalid.
	if bt_help((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) {
		help_window = true
	} else {
		clear_snapshot_o(curtab, SNAP_HELP_IDX_O)
	}
	if bt_quickfix((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) {
		quickfix_window = true
	} else {
		clear_snapshot_o(curtab, SNAP_QUICKFIX_IDX_O)
	}
	other_buffer := false
	if win == curwin {
		leaving_window(curwin)
		// Guess which window is going to be the new current window.
		// This may change because of the autocommands (sigh).
		wp: rawptr
		if (^bool)(uintptr(win) + W_FLOATING_OFF)^ {
			wp = win_float_find_altwin_r(win, nil)
		} else {
			wp = frame2win(win_altframe_o(win, nil))
		}
		// Be careful: If autocommands delete the window or cause this window
		// to be the last one left, return now.
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
			reset_VIsual_and_resel_r() // stop Visual mode
			other_buffer = true
			if !win_valid(win) {
				return FAIL
			}
			(^C.int)(uintptr(win) + W_LOCKED_OFF)^ += 1
			apply_autocmds(EVENT_BUFLEAVE_O, nil, nil, false, curbuf)
			if !win_valid(win) {
				return FAIL
			}
			(^C.int)(uintptr(win) + W_LOCKED_OFF)^ -= 1
			if last_window(win) {
				return FAIL
			}
		}
		(^C.int)(uintptr(win) + W_LOCKED_OFF)^ += 1
		apply_autocmds(EVENT_WINLEAVE_O, nil, nil, false, curbuf)
		if !win_valid(win) {
			return FAIL
		}
		(^C.int)(uintptr(win) + W_LOCKED_OFF)^ -= 1
		if last_window(win) {
			return FAIL
		}
		// autocmds may abort script processing
		if aborting_r() {
			return FAIL
		}
	}
	// Fire WinClosed just before starting to free window-related resources.
	do_autocmd_winclosed_o(win)
	// autocmd may have freed the window already.
	if !win_valid_any_tab(win) {
		return OK
	}
	bufref: Bufref_T
	set_bufref(&bufref, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^)
	fb := free_buf
	win_close_buffer_o(win, fb ? DOBUF_UNLOAD_O : 0, true)
	if win_valid(win) && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == nil &&
		!(^bool)(uintptr(win) + W_FLOATING_OFF)^ && last_window(win) {
		// Autocommands have closed all windows, quit now. Restore
		// curwin->w_buffer, otherwise writing ShaDa file may fail.
		if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == nil {
			(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = curbuf
		}
		getout(0)
	}
	// Autocommands may have moved to another tab page.
	if curtab != prev_curtab && win_valid_any_tab(win) &&
		(^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == nil {
		// Need to close the window anyway, since the buffer is NULL.
		win_close_othertab(win, 0, prev_curtab, force)
		return FAIL
	}
	// Autocommands may have closed the window already, or closed the only
	// other window or moved to another tab page.
	if !win_valid(win) {
		return FAIL
	}
	if one_window(win, nil) &&
		((^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil ||
			(^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^) {
		if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ != nil {
			emsg(cstring(E_FLOATONLY_S))
		}
		win_unclose_buffer_o(win, &bufref)
		return FAIL
	}
	if close_last_window_tabpage_o(win, free_buf, prev_curtab) {
		return FAIL
	}
	// Now we are really going to close the window. Disallow any autocommand
	// to split a window to avoid trouble.
	nvim_odin_set_split_disallowed_r(nvim_odin_get_split_disallowed_r() + 1)
	was_floating := (^bool)(uintptr(win) + W_FLOATING_OFF)^
	if ui_has(K_UIMULTIGRID_O) {
		ui_call_win_close_r(C.longlong((^C.int)(uintptr(win) + W_GRID_HANDLE_OFF)^))
	}
	if (^bool)(uintptr(win) + W_FLOATING_OFF)^ {
		ui_comp_remove_grid_r(transmute(rawptr)(uintptr(win) + W_GRID_HANDLE_OFF))
		if (^bool)(uintptr(win) + WCFG_EXTERNAL_OFF)^ {
			tp := first_tabpage
			for tp != nil {
				if tp != curtab &&
					(^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ == win {
					// NB: an autocmd can still abort the closing of this
					// window, but carrying out this change anyway shouldn't
					// be a catastrophe.
					(^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ =
						(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
				}
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}
		}
	}
	// About to free the window. Remember its final buffer for
	// terminal_check_size, which may have changed since the last set_bufref.
	// (e.g: close_buffer autocmds)
	set_bufref(&bufref, (^rawptr)(uintptr(win) + W_BUFFER_OFF)^)
	if (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ != nil {
		(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ -= 1
	}
	had_cmdline_ruler := p_ru_g != 0 && win == curwin &&
		(^C.int)(uintptr(win) + W_STATUS_HEIGHT_OFF)^ == 0
	// Free the memory used for the window and get the window that received
	// the screen space.
	dir: C.int = 0
	wp := win_free_mem_o(win, &dir, nil)
	if help_window || quickfix_window {
		// Closing the help window moves the cursor back to the current window
		// of the snapshot.
		prev_win := get_snapshot_curwin_o(help_window ? SNAP_HELP_IDX_O : SNAP_QUICKFIX_IDX_O)
		if win_valid(prev_win) {
			wp = prev_win
		}
	}
	close_curwin := false
	// Make sure curwin isn't invalid. It can cause severe trouble when
	// printing an error message. For win_equal() curbuf needs to be valid too.
	if win == curwin {
		curwin = wp
		if (^C.int)(uintptr(wp) + W_P_PVW_OFF)^ != 0 ||
			bt_quickfix((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
			// If the cursor goes to the preview or the quickfix window, try
			// finding another window to go to.
			for {
				if (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ == nil {
					wp = firstwin
				} else {
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				}
				if wp == curwin {
					break
				}
				if (^C.int)(uintptr(wp) + W_P_PVW_OFF)^ == 0 &&
					!bt_quickfix((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) &&
					!((^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
						((^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ ||
							!(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^)) {
					curwin = wp
					break
				}
			}
		}
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
		close_curwin = true
		// The cursor position may be invalid if the buffer changed after last
		// using the window.
		check_cursor_r(curwin)
	}
	if !was_floating {
		// If last window has a status line now and we don't want one,
		// remove the status line. Do this before win_equal(), because
		// it may change the height of a window.
		last_status(false)
		if !((^bool)(uintptr(curwin) + W_FLOATING_OFF)^) && p_ea_g != 0 &&
			(b_at(p_ead_g, 0) == 'b' || C.int(b_at(p_ead_g, 0)) == dir) {
			// If the frame of the closed window contains the new current
			// window, only resize that frame. Otherwise resize all windows.
			win_equal(curwin,
				(^rawptr)(uintptr(curwin) + W_FRAME_OFF)^ != nil &&
				(^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^ == win_frame, dir)
		} else {
			win_comp_pos()
			win_fix_scroll(false)
		}
	} else if had_cmdline_ruler && (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ > 0 {
		redraw_cmdline_g = true // clear cmdline 'ruler'
	}
	if bufref.br_buf != nil && bufref_valid(&bufref) &&
		(^rawptr)(uintptr(bufref.br_buf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(bufref.br_buf) + B_TERMINAL_OFF)^)
	}
	if close_curwin {
		win_enter_ext_o(wp, WEE_CURWIN_INVALID_O | WEE_TRIGGER_ENTER_AUTOCMDS_O |
			WEE_TRIGGER_LEAVE_AUTOCMDS_O)
		if other_buffer {
			// careful: after this wp and win may be invalid!
			apply_autocmds(EVENT_BUFENTER_O, nil, nil, false, curbuf)
		}
	}
	if firstwin == lastwin_g && (^C.int)(uintptr(curwin) + W_LOCKED_OFF)^ != 0 &&
		(^C.int)(uintptr(curbuf) + B_LOCKED_SPLIT_OFF)^ != 0 &&
		(^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ != nil {
		// The new curwin is the last window in the current tab page, and it
		// is already being closed. Trigger TabLeave now, as after its buffer
		// is removed it's no longer safe to do that.
		apply_autocmds(EVENT_TABLEAVE_O, nil, nil, false, curbuf)
	}
	nvim_odin_set_split_disallowed_r(nvim_odin_get_split_disallowed_r() - 1)
	// After closing the help or quickfix window, try restoring the window
	// layout from before it was opened.
	if help_window || quickfix_window {
		restore_snapshot(help_window ? SNAP_HELP_IDX_O : SNAP_QUICKFIX_IDX_O,
			close_curwin ? 1 : 0)
	}
	// If the window had 'diff' set and now there is only one window left in
	// the tab page with 'diff' set, and "closeoff" is in 'diffopt', then
	// execute ":diffoff!".
	if diffopt_closeoff_r() && had_diffmode != 0 && curtab == prev_curtab {
		diffcount: C.int = 0
		// FOR_ALL_WINDOWS_IN_TAB(dwin, curtab) = firstwin (curtab nuance).
		dwin := firstwin
		for dwin != nil {
			if (^C.int)(uintptr(dwin) + W_P_DIFF_OFF)^ != 0 {
				diffcount += 1
			}
			dwin = (^rawptr)(uintptr(dwin) + W_NEXT_OFF)^
		}
		if diffcount == 1 {
			do_cmdline_cmd_r(cstring("diffoff!"))
		}
	}
	(^bool)(uintptr(curwin) + W_POS_CHANGED_OFF)^ = true
	if !was_floating {
		// TODO(bfredl): how about no?
		redraw_all_later_r(UPD_NOT_VALID_O)
	}
	return OK
}

// ── Batch 16: win_equal family ───────────────────────────────────────────────

FR_NEWWIDTH_OFF :: 8
FR_NEWHEIGHT_OFF :: 16

// True when frame "frp" contains window "wp" (C static: no export/weak).
frame_has_win_o :: proc "c"(frp: rawptr, wp: rawptr) -> bool {
	if b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		return (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ == wp
	}
	p := (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	for p != nil {
		if frame_has_win_o(p, wp) {
			return true
		}
		p = (^rawptr)(uintptr(p) + FR_NEXT_OFF)^
	}
	return false
}

// Compute maximum windows fitting within "height" in frame "fr" (C static).
get_maximum_wincount_o :: proc "c"(fr: rawptr, height: C.int) -> C.int {
	if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) != FR_COL_O {
		return height / (C.int(p_wmh_opt) + STATUS_HEIGHT_O +
			(^C.int)(uintptr(frame2win(fr)) + W_WINBAR_HEIGHT_OFF)^)
	} else if global_winbar_height() != 0 {
		// Winbar globally enabled: no per-window check needed.
		return height / (C.int(p_wmh_opt) + STATUS_HEIGHT_O + 1)
	}
	total_wincount: C.int = 0
	h := height
	// First, try to fit all child frames of "fr" into "height".
	frp := (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
	for frp != nil {
		wp := frame2win(frp)
		if h < C.int(p_wmh_opt) + STATUS_HEIGHT_O +
			(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ {
			break
		}
		h -= C.int(p_wmh_opt) + STATUS_HEIGHT_O +
			(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^
		total_wincount += 1
		frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	}
	// Remaining room fits more windows at default winbar height (0).
	total_wincount += h / (C.int(p_wmh_opt) + STATUS_HEIGHT_O)
	return total_wincount
}

// Make all windows the same height/width.
@(export)
win_equal :: proc "c"(next_curwin: rawptr, current: bool, dir: C.int) {
	d := dir
	if d == 0 {
		d = C.int(b_at(p_ead_g, 0))
	}
	win_equal_rec_o(next_curwin == nil ? curwin : next_curwin, current,
		topframe_g, d, 0, 		tabline_height(), Columns,
		(^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^)
	if !is_aucmd_win_r(next_curwin) {
		win_fix_scroll(true)
	}
}

// Set frame sizes equally (recursive worker; C static: no export/weak).
win_equal_rec_o :: proc "c"(next_curwin: rawptr, current: bool, topfr: rawptr, dir: C.int, col: C.int, row: C.int, width: C.int, height: C.int) {
	extra_sep: C.int = 0
	totwincount: C.int = 0
	next_curwin_size: C.int = 0
	room: C.int = 0
	has_next_curwin := false
	w := width
	h := height
	c := col
	r := row
	if b_at((^u8)(uintptr(topfr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		// Set the width/height of this frame; redraw on change.
		if (^C.int)(uintptr(topfr) + FR_HEIGHT_OFF)^ != h ||
			(^C.int)(uintptr((^rawptr)(uintptr(topfr) + FR_WIN_OFF)^) + W_WINROW_OFF)^ != r ||
			(^C.int)(uintptr(topfr) + FR_WIDTH_OFF)^ != w ||
			(^C.int)(uintptr((^rawptr)(uintptr(topfr) + FR_WIN_OFF)^) + W_WINCOL_OFF)^ != c {
			(^C.int)(uintptr((^rawptr)(uintptr(topfr) + FR_WIN_OFF)^) + W_WINROW_OFF)^ = r
			frame_new_height(topfr, h, false, false, false)
			(^C.int)(uintptr((^rawptr)(uintptr(topfr) + FR_WIN_OFF)^) + W_WINCOL_OFF)^ = c
			frame_new_width(topfr, w, false, false)
			redraw_all_later_r(UPD_NOT_VALID_O)
		}
	} else if b_at((^u8)(uintptr(topfr) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		(^C.int)(uintptr(topfr) + FR_WIDTH_OFF)^ = w
		(^C.int)(uintptr(topfr) + FR_HEIGHT_OFF)^ = h
		if dir != 'v' { // equalize frame widths
			n := frame_minwidth_o(topfr, nowin_o())
			// add one for the rightmost window (no separator)
			if c + w == Columns {
				extra_sep = 1
			}
			totwincount = (n + extra_sep) / (C.int(p_wmw_opt) + 1)
			has_next_curwin = frame_has_win_o(topfr, next_curwin)
			// "m" is the minimal width counting p_wiw for "next_curwin".
			m := frame_minwidth_o(topfr, next_curwin)
			room = w - m
			if room < 0 {
				next_curwin_size = C.int(p_wiw_opt) + room
				room = 0
			} else {
				next_curwin_size = -1
				fr := (^rawptr)(uintptr(topfr) + FR_CHILD_OFF)^
				for fr != nil {
					if !frame_fixed_width_o(fr) {
						fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
						continue
					}
					// If 'winfixwidth' set keep the window width if possible.
					n = frame_minwidth_o(fr, nowin_o())
					new_size := (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^
					if frame_has_win_o(fr, next_curwin) {
						room += C.int(p_wiw_opt) - C.int(p_wmw_opt)
						next_curwin_size = 0
						new_size = max(new_size, C.int(p_wiw_opt))
					} else {
						// These windows don't use up room.
						nxtnull := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil
						totwincount -= (n + (nxtnull ? extra_sep : 0)) / (C.int(p_wmw_opt) + 1)
					}
					room -= new_size - n
					if room < 0 {
						new_size += room
						room = 0
					}
					(^C.int)(uintptr(fr) + FR_NEWWIDTH_OFF)^ = new_size
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
				if next_curwin_size == -1 {
					if !has_next_curwin {
						next_curwin_size = 0
					} else if totwincount > 1 &&
						(room + (totwincount - 2)) / (totwincount - 1) > C.int(p_wiw_opt) {
						// Can make all windows wider than 'winwidth'.
						next_curwin_size = C.int(room + C.int(p_wiw_opt) +
							(totwincount - 1) * C.int(p_wmw_opt) +
							(totwincount - 1)) / totwincount
						room -= next_curwin_size - C.int(p_wiw_opt)
					} else {
						next_curwin_size = C.int(p_wiw_opt)
					}
				}
			}
			if has_next_curwin {
				totwincount -= 1 // don't count curwin
			}
		}
		fr := (^rawptr)(uintptr(topfr) + FR_CHILD_OFF)^
		for fr != nil {
			wincount: C.int = 1
			new_size: C.int
			if (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil {
				// last frame gets all that remains (avoid roundoff error)
				new_size = w
			} else if dir == 'v' {
				new_size = (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^
			} else if frame_fixed_width_o(fr) {
				new_size = (^C.int)(uintptr(fr) + FR_NEWWIDTH_OFF)^
				wincount = 0 // doesn't count as a sizeable window
			} else {
				n := frame_minwidth_o(fr, nowin_o())
				nxtnull := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil
				wincount = (n + (nxtnull ? extra_sep : 0)) / (C.int(p_wmw_opt) + 1)
				m := frame_minwidth_o(fr, next_curwin)
				hnc := has_next_curwin && frame_has_win_o(fr, next_curwin)
				if hnc { // don't count next_curwin
					wincount -= 1
				}
				if totwincount == 0 {
					new_size = room
				} else {
					new_size = (wincount * room + (totwincount / 2)) / totwincount
				}
				if hnc { // add next_curwin size
					next_curwin_size -= C.int(p_wiw_opt) - (m - n)
					next_curwin_size = max(next_curwin_size, 0)
					new_size += next_curwin_size
					room -= new_size - next_curwin_size
				} else {
					room -= new_size
				}
				new_size += n
			}
			// Skip full-width frame when splitting/closing, unless equalizing.
			if !current || dir != 'v' || (^rawptr)(uintptr(topfr) + FR_PARENT_OFF)^ != nil ||
				new_size != (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ ||
				frame_has_win_o(fr, next_curwin) {
				win_equal_rec_o(next_curwin, current, fr, dir, c, r, new_size, h)
			}
			c += new_size
			w -= new_size
			totwincount -= wincount
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
	} else { // topfr->fr_layout == FR_COL
		(^C.int)(uintptr(topfr) + FR_WIDTH_OFF)^ = w
		(^C.int)(uintptr(topfr) + FR_HEIGHT_OFF)^ = h
		if dir != 'h' { // equalize frame heights
			n := frame_minheight_o(topfr, nowin_o())
			// add one for the bottom window (no statusline/separator)
			if r + h >= cmdline_row && p_ls_g == 0 {
				extra_sep = STATUS_HEIGHT_O
			} else if 		global_stl_height() > 0 {
				extra_sep = 1
			}
			totwincount = get_maximum_wincount_o(topfr, n + extra_sep)
			has_next_curwin = frame_has_win_o(topfr, next_curwin)
			// "m" is the minimal height counting p_wh for "next_curwin".
			m := frame_minheight_o(topfr, next_curwin)
			room = h - m
			if room < 0 {
				next_curwin_size = C.int(p_wh_opt) + room
				room = 0
			} else {
				next_curwin_size = -1
				fr := (^rawptr)(uintptr(topfr) + FR_CHILD_OFF)^
				for fr != nil {
					if !frame_fixed_height_o(fr) {
						fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
						continue
					}
					// If 'winfixheight' set keep the window height if possible.
					n = frame_minheight_o(fr, nowin_o())
					new_size := (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^
					if frame_has_win_o(fr, next_curwin) {
						room += C.int(p_wh_opt) - C.int(p_wmh_opt)
						next_curwin_size = 0
						new_size = max(new_size, C.int(p_wh_opt))
					} else {
						// These windows don't use up room.
						nxtnull := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil
						totwincount -= get_maximum_wincount_o(fr,
							n + (nxtnull ? extra_sep : 0))
					}
					room -= new_size - n
					if room < 0 {
						new_size += room
						room = 0
					}
					(^C.int)(uintptr(fr) + FR_NEWHEIGHT_OFF)^ = new_size
					fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
				}
				if next_curwin_size == -1 {
					if !has_next_curwin {
						next_curwin_size = 0
					} else if totwincount > 1 &&
						(room + (totwincount - 2)) / (totwincount - 1) > C.int(p_wh_opt) {
						// Can make all windows higher than 'winheight'.
						next_curwin_size = C.int(room + C.int(p_wh_opt) +
							(totwincount - 1) * C.int(p_wmh_opt) +
							(totwincount - 1)) / totwincount
						room -= next_curwin_size - C.int(p_wh_opt)
					} else {
						next_curwin_size = C.int(p_wh_opt)
					}
				}
			}
			if has_next_curwin {
				totwincount -= 1 // don't count curwin
			}
		}
		fr := (^rawptr)(uintptr(topfr) + FR_CHILD_OFF)^
		for fr != nil {
			new_size: C.int
			wincount: C.int = 1
			if (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil {
				// last frame gets all that remains (avoid roundoff error)
				new_size = h
			} else if dir == 'h' {
				new_size = (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^
			} else if frame_fixed_height_o(fr) {
				new_size = (^C.int)(uintptr(fr) + FR_NEWHEIGHT_OFF)^
				wincount = 0 // doesn't count as a sizeable window
			} else {
				n := frame_minheight_o(fr, nowin_o())
				nxtnull := (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil
				wincount = get_maximum_wincount_o(fr, n + (nxtnull ? extra_sep : 0))
				m := frame_minheight_o(fr, next_curwin)
				hnc := has_next_curwin && frame_has_win_o(fr, next_curwin)
				if hnc { // don't count next_curwin
					wincount -= 1
				}
				if totwincount == 0 {
					new_size = room
				} else {
					new_size = (wincount * room + (totwincount / 2)) / totwincount
				}
				if hnc { // add next_curwin size
					next_curwin_size -= C.int(p_wh_opt) - (m - n)
					new_size += next_curwin_size
					room -= new_size - next_curwin_size
				} else {
					room -= new_size
				}
				new_size += n
			}
			// Skip full-width frame when splitting/closing, unless equalizing.
			if !current || dir != 'h' || (^rawptr)(uintptr(topfr) + FR_PARENT_OFF)^ != nil ||
				new_size != (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ ||
				frame_has_win_o(fr, next_curwin) {
				win_equal_rec_o(next_curwin, current, fr, dir, c, r, w, new_size)
			}
			r += new_size
			h -= new_size
			totwincount -= wincount
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
	}
}

// ── Batch 17: screen resize ──────────────────────────────────────────────────

foreign _ {
	@(link_name = "win_reconfig_floats")
	win_reconfig_floats_r :: proc "c" () ---
	@(link_name = "compute_cmdrow")
	compute_cmdrow_r :: proc "c" () ---
}

// Check that "topfrp" and its children are at the right height (C static).
frame_check_height_o :: proc "c"(topfrp: rawptr, height: C.int) -> bool {
	if (^C.int)(uintptr(topfrp) + FR_HEIGHT_OFF)^ != height {
		return false
	}
	if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			if (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ != height {
				return false
			}
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	}
	return true
}

// Check that "topfrp" and its children are at the right width (C static).
frame_check_width_o :: proc "c"(topfrp: rawptr, width: C.int) -> bool {
	if (^C.int)(uintptr(topfrp) + FR_WIDTH_OFF)^ != width {
		return false
	}
	if b_at((^u8)(uintptr(topfrp) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		frp := (^rawptr)(uintptr(topfrp) + FR_CHILD_OFF)^
		for frp != nil {
			if (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ != width {
				return false
			}
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	}
	return true
}

// Recompute window heights for the current tab page (e.g. after 'rows').
@(export)
win_new_screen_rows :: proc "c"() {
	if firstwin == nil { // not initialized yet
		return
	}
	h := max(rows_avail_o(), frame_minheight_o(topframe_g, nil))
	// First try setting the heights of windows with 'winfixheight'. If
	// that doesn't result in the right height, forget about that option.
	frame_new_height(topframe_g, h, false, true, false)
	if !frame_check_height_o(topframe_g, h) {
		frame_new_height(topframe_g, h, false, false, false)
	}
	win_comp_pos() // recompute w_winrow and w_wincol
	win_reconfig_floats_r() // The size of floats might change
	compute_cmdrow_r()
	(^C.longlong)(uintptr(curtab) + TP_CH_USED_OFF)^ = C.longlong(p_ch)
	if !skip_win_fix_scroll_g {
		win_fix_scroll(true)
	}
}

// Recompute window widths for the current tab page (after 'columns').
@(export)
win_new_screen_cols :: proc "c"() {
	if firstwin == nil { // not initialized yet
		return
	}
	// First try setting the widths of windows with 'winfixwidth'. If that
	// doesn't result in the right width, forget about that option.
	frame_new_width(topframe_g, Columns, false, true)
	if !frame_check_width_o(topframe_g, Columns) {
		frame_new_width(topframe_g, Columns, false, false)
	}
	win_comp_pos() // recompute w_winrow and w_wincol
	win_reconfig_floats_r() // The size of floats might change
}

// ── Batch 18: win_setheight/width + frame_set helpers ────────────────────────
// WinConfig.height@12/width@16 (relative to w_config) probed via off29.

WC_HEIGHT_OFF :: 10572 // W_CONFIG_OFF + 12
WC_WIDTH_OFF :: 10576 // W_CONFIG_OFF + 16

@(export)
win_setheight :: proc "c"(height: C.int) {
	win_setheight_win(height, curwin, true)
}

// Set window height of "win", repositioning others to fit.
@(export)
win_setheight_win :: proc "c"(height: C.int, win: rawptr, from_top: bool) {
	// Keep current window >= 1 line (>= 2 with winbar), others >= 'winminheight'.
	h := max(height, C.int(win == curwin ? max(p_wmh_opt, 1) : p_wmh_opt) +
		(^C.int)(uintptr(win) + W_WINBAR_HEIGHT_OFF)^)
	if (^bool)(uintptr(win) + W_FLOATING_OFF)^ {
		(^C.int)(uintptr(win) + WC_HEIGHT_OFF)^ = max(h, 1)
		win_config_float_r(win, (^WinConfig_Opaque)(uintptr(win) + W_CONFIG_OFF)^)
		redraw_later(win, UPD_VALID_O)
	} else {
		frame_setheight_o((^rawptr)(uintptr(win) + W_FRAME_OFF)^,
			h + (^C.int)(uintptr(win) + W_HSEP_HEIGHT_OFF)^ +
			(^C.int)(uintptr(win) + W_STATUS_HEIGHT_OFF)^, from_top)
		// recompute the window positions
		win_comp_pos()
		win_fix_scroll(true)
		redraw_all_later_r(UPD_NOT_VALID_O)
		redraw_cmdline_g = true
	}
}

// Set frame height, resizing neighbors (C static: no export/weak).
frame_setheight_o :: proc "c"(curfrp: rawptr, height_in: C.int, from_top: bool) {
	// If the height already is the desired value, nothing to do.
	if (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^ == height_in {
		return
	}
	height := height_in
	if (^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^ == nil {
		// topframe: can only change the command line height
		if height > 0 {
			frame_new_height(curfrp, height, false, false, true)
		}
	} else if b_at((^u8)(uintptr((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_ROW_O {
		// Row of frames: also resize frames left/right of this one.
		h := frame_minheight_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, nil)
		height = max(height, h)
		frame_setheight_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, height, from_top)
	} else {
		// Column of frames: try to change only frames in this column.
		room: C.int // total lines available
		room_cmdline: C.int // lines available from cmdline
		room_reserved: C.int
		// Do this twice: 1) compute room, resize parent if not enough;
		// 2) compute room and adjust height to it.
		// Try not to reduce the height of a 'winfixheight' window.
		for run := 1; run <= 2; run += 1 {
			room = 0
			room_reserved = 0
			frp := (^rawptr)(uintptr((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^
			for frp != nil {
				if frp != curfrp && (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil &&
					(^bool)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFH_OFF)^ {
					room_reserved += (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^
				}
				room += (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^
				if frp != curfrp {
					room -= frame_minheight_o(frp, nil)
				}
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			// For bottom-anchored resize, treat cmdline room as zero.
			if !from_top || (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^ != Columns {
				room_cmdline = 0
			} else {
				wp := lastwin_nofloating(nil)
				room_cmdline = Rows - C.int(p_ch) - 		global_stl_height() -
					((^C.int)(uintptr(wp) + W_WINROW_OFF)^ +
						(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ +
						(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ +
						(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^)
				room_cmdline = max(room_cmdline, 0)
			}
			if height <= room + room_cmdline {
				break
			}
			if run == 2 || (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^ == Columns {
				height = room + room_cmdline
				break
			}
			frame_setheight_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^,
				height + frame_minheight_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, nowin_o()) -
				C.int(p_wmh_opt) - 1, from_top)
			// NOTREACHED
		}
		// Lines we will take from other frames (can be negative!).
		take := height - (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^
		// If there is not enough room, also reduce the height of a
		// 'winfixheight' window.
		if height > room + room_cmdline - room_reserved {
			room_reserved = room + room_cmdline - height
		}
		// If only a 'winfixheight' window and making smaller, need to make
		// the other window taller.
		if take < 0 && room - (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^ <= room_reserved {
			room_reserved = 0
		}
		if take > 0 && room_cmdline > 0 {
			// use lines from cmdline first
			room_cmdline = min(room_cmdline, take)
			take -= room_cmdline
			(^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^ += room_cmdline
		}
		// set the current frame to the new height
		frame_new_height(curfrp, height, false, false, true)
		// First take lines from frames after current; if not enough, from
		// frames above. 1st run: non-anchored side; 2nd: anchored side.
		for run := 0; run < 2; run += 1 {
			forward := (run == 0) == from_top
			frp := forward ? (^rawptr)(uintptr(curfrp) + FR_NEXT_OFF)^ :
				(^rawptr)(uintptr(curfrp) + FR_PREV_OFF)^
			for frp != nil && take != 0 {
				h := frame_minheight_o(frp, nil)
				if room_reserved > 0 && (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil &&
					(^bool)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFH_OFF)^ {
					if room_reserved >= (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ {
						room_reserved -= (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^
					} else {
						if (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - room_reserved > take {
							room_reserved = (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - take
						}
						take -= (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - room_reserved
						frame_new_height(frp, room_reserved, false, false, true)
						room_reserved = 0
					}
				} else {
					if (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - take < h {
						take -= (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - h
						frame_new_height(frp, h, false, false, true)
					} else {
						frame_new_height(frp, (^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - take, false, false, true)
						take = 0
					}
				}
				frp = forward ? (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ :
					(^rawptr)(uintptr(frp) + FR_PREV_OFF)^
			}
		}
	}
}

// Set current window width, repositioning other windows to fit.
@(export)
win_setwidth :: proc "c"(width: C.int) {
	win_setwidth_win(width, curwin, true)
}

@(export)
win_setwidth_win :: proc "c"(width: C.int, wp: rawptr, from_left: bool) {
	// Always keep current window >= 1 column, even when 'winminwidth' is 0.
	w := width
	if wp == curwin {
		w = max(max(w, C.int(p_wmw_opt)), 1)
	} else if w < 0 {
		w = 0
	}
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		(^C.int)(uintptr(wp) + WC_WIDTH_OFF)^ = w
		win_config_float_r(wp, (^WinConfig_Opaque)(uintptr(wp) + W_CONFIG_OFF)^)
		redraw_later(wp, UPD_NOT_VALID_O)
	} else {
		frame_setwidth_o((^rawptr)(uintptr(wp) + W_FRAME_OFF)^,
			w + (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^, from_left)
		// recompute the window positions
		win_comp_pos()
		redraw_all_later_r(UPD_NOT_VALID_O)
	}
}

// Set frame width, resizing neighbors (C static: no export/weak).
frame_setwidth_o :: proc "c"(curfrp: rawptr, width_in: C.int, from_left: bool) {
	// If the width already is the desired value, nothing to do.
	if (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^ == width_in {
		return
	}
	width := width_in
	if (^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^ == nil {
		// topframe: can't change width
		return
	}
	if b_at((^u8)(uintptr((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_COL_O {
		// Column of frames: also resize frames above/below of this one.
		w := frame_minwidth_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, nil)
		width = max(width, w)
		frame_setwidth_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, width, from_left)
	} else {
		// Row of frames: try to change only frames in this row.
		// Do this twice (see frame_setheight_o).
		room: C.int // total columns available
		room_reserved: C.int
		for run := 1; run <= 2; run += 1 {
			room = 0
			room_reserved = 0
			frp := (^rawptr)(uintptr((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^
			for frp != nil {
				if frp != curfrp && (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil &&
					(^bool)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFW_OFF)^ {
					room_reserved += (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^
				}
				room += (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^
				if frp != curfrp {
					room -= frame_minwidth_o(frp, nil)
				}
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			if width <= room {
				break
			}
			if run == 2 || (^C.int)(uintptr(curfrp) + FR_HEIGHT_OFF)^ >= rows_avail_o() {
				width = room
				break
			}
			frame_setwidth_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^,
				width + frame_minwidth_o((^rawptr)(uintptr(curfrp) + FR_PARENT_OFF)^, nowin_o()) -
				C.int(p_wmw_opt) - 1, from_left)
		}
		// Columns we will take from other frames (can be negative!).
		take := width - (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^
		// If there is not enough room, also reduce the width of a
		// 'winfixwidth' window.
		if width > room - room_reserved {
			room_reserved = room - width
		}
		// If only a 'winfixwidth' window and making smaller, need to make
		// the other window narrower.
		if take < 0 && room - (^C.int)(uintptr(curfrp) + FR_WIDTH_OFF)^ < room_reserved {
			room_reserved = 0
		}
		// set the current frame to the new width
		frame_new_width(curfrp, width, false, false)
		// First take from frames right of current; if not enough, from
		// frames left. 1st run: non-anchored side; 2nd: anchored side.
		for run := 0; run < 2; run += 1 {
			forward := (run == 0) == from_left
			frp := forward ? (^rawptr)(uintptr(curfrp) + FR_NEXT_OFF)^ :
				(^rawptr)(uintptr(curfrp) + FR_PREV_OFF)^
			for frp != nil && take != 0 {
				w := frame_minwidth_o(frp, nil)
				if room_reserved > 0 && (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ != nil &&
					(^bool)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFW_OFF)^ {
					if room_reserved >= (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ {
						room_reserved -= (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^
					} else {
						if (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - room_reserved > take {
							room_reserved = (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - take
						}
						take -= (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - room_reserved
						frame_new_width(frp, room_reserved, false, false)
						room_reserved = 0
					}
				} else {
					if (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - take < w {
						take -= (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - w
						frame_new_width(frp, w, false, false)
					} else {
						frame_new_width(frp, (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ - take, false, false)
						take = 0
					}
				}
				frp = forward ? (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ :
					(^rawptr)(uintptr(frp) + FR_PREV_OFF)^
			}
		}
	}
}

// ── Batch 19: :only engine + tabpage use/free ────────────────────────────────
// W_P_WP (w_onebuf_opt@816 + wo_wp@188) probed via off30.

W_P_WP_OFF :: 1004
SNAP_COUNT_O :: 3
M_ONLYONE_S :: "Already only one window"
E445_S :: "E445: Other window contains changes"

foreign _ {
	@(link_name = "msg")
	msg_r :: proc "c" (s: cstring, hl_id: C.int) -> bool ---
	@(link_name = "diff_clear")
	diff_clear_r :: proc "c" (tp: rawptr) ---
}

// Store the relevant window pointers for tab page "tp" (before use_tabpage).
@(export)
unuse_tabpage :: proc "c"(tp: rawptr) {
	(^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^ = topframe_g
	(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ = firstwin
	(^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ = lastwin_g
	(^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^ = curwin
	// This tab's stored cmdheight (restored later by use_tabpage).
	(^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^ = C.longlong(p_ch)
}

// Set the relevant pointers to use tab page "tp" (after unuse_tabpage).
@(export)
use_tabpage :: proc "c"(tp: rawptr) {
	curtab = tp
	topframe_g = (^rawptr)(uintptr(curtab) + TP_TOPFRAME_OFF)^
	firstwin = (^rawptr)(uintptr(curtab) + TP_FIRSTWIN_OFF)^
	lastwin_g = (^rawptr)(uintptr(curtab) + TP_LASTWIN_OFF)^
	curwin = (^rawptr)(uintptr(curtab) + TP_CURWIN_OFF)^
	// Restore this tab's cmdheight (layout work is the caller's job, see
	// enter_tabpage()).
	p_ch = (^C.longlong)(uintptr(curtab) + TP_CH_USED_OFF)^
}

// Close all windows but the current one (:only).
@(export)
close_others :: proc "c"(message: C.int, forceit: C.int, ignore_pinned: bool) {
	old_curwin := curwin
	if (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
		if message != 0 && !autocmd_busy_g {
			emsg(cstring(E_FLOATONLY_S))
		}
		return
	}
	if one_window(firstwin, nil) && !(^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^ {
		if message != 0 && !autocmd_busy_g {
			msg_r(cstring(M_ONLYONE_S), 0)
		}
		return
	}
	// Be very careful here: autocommands may change the window layout.
	nextwp: rawptr
	wp := firstwin
	for win_valid(wp) {
		nextwp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		// autocommands messed this one up
		if old_curwin != curwin && win_valid(old_curwin) {
			curwin = old_curwin
			curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
		}
		// don't close current window or pinned windows
		if wp == curwin || ((^C.int)(uintptr(wp) + W_P_WP_OFF)^ != 0 && !ignore_pinned) {
			wp = nextwp
			continue
		}
		// autocommands messed this one up
		if !buf_valid((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) && win_valid(wp) {
			(^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ = nil
			win_close(wp, false, false)
			wp = nextwp
			continue
		}
		// Check if it's allowed to abandon this window
		r := can_abandon_r((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, forceit != 0)
		if !win_valid(wp) { // autocommands messed wp up
			nextwp = firstwin
			wp = nextwp
			continue
		}
		if !r {
			if message != 0 && (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && p_write_g != 0 {
				dialog_changed_r((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, false)
				if !win_valid(wp) { // autocommands messed wp up
					nextwp = firstwin
					wp = nextwp
					continue
				}
			}
			if bufIsChanged((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
				wp = nextwp
				continue
			}
		}
		win_close(wp, !(buf_hide((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^)) &&
			!bufIsChanged((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^), false)
		wp = nextwp
	}
	if message != 0 && firstwin != lastwin_g {
		// Check if remaining windows are non-pinned
		has_non_pinned := false
		wp = firstwin
		for wp != nil {
			if wp != curwin && (^C.int)(uintptr(wp) + W_P_WP_OFF)^ == 0 {
				has_non_pinned = true
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if has_non_pinned {
			emsg(cstring(E445_S))
		}
	}
}

// True when there is effectively only one window (for :quit etc).
@(export)
only_one_window :: proc "c"() -> bool {
	// If there is another tab page there always is another window.
	if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ != nil {
		return false
	}
	count: C.int = 0
	// FOR_ALL_WINDOWS_IN_TAB(wp, curtab) = firstwin (curtab nuance).
	wp := firstwin
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != nil &&
			(!((bt_help((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) &&
				!bt_help(curbuf)) ||
				(^bool)(uintptr(wp) + W_FLOATING_OFF)^ ||
				(^C.int)(uintptr(wp) + W_P_PVW_OFF)^ != 0) || wp == curwin) &&
			!is_aucmd_win_r(wp) {
			count += 1
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return count <= 1
}

// Free a tabpage struct (windows must already be gone).
@(export)
free_tabpage :: proc "c"(tp: rawptr) {
	map_del_int_ptr_t(&tabpage_handles_g, (^C.int)(tp)^, nil)
	diff_clear_r(tp)
	for idx: C.int = 0; idx < SNAP_COUNT_O; idx += 1 {
		clear_snapshot_o(tp, idx)
	}
	vars := (^rawptr)(uintptr(tp) + TP_VARS_OFF)^
	vars_clear_r2(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF)) // free t: vars
	hash_init_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF))
	unref_var_dict_r(vars)
	if tp == lastused_tabpage_g {
		lastused_tabpage_g = nil
	}
	xfree((^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^)
	xfree((^rawptr)(uintptr(tp) + TP_PREVDIR_OFF)^)
	xfree(tp)
}

// ── Batch 20: command_height + scroll defaults ───────────────────────────────

KWINOPT_SCROLL_O :: 33
SID_WINLAYOUT_O :: -7

foreign _ {
	@(link_name = "nvim_odin_get_command_frame_height")
	nvim_odin_get_command_frame_height_r :: proc "c" () -> bool ---
	@(link_name = "grid_clear")
	grid_clear_r :: proc "c" (grid: rawptr, start_row: C.int, end_row: C.int, start_col: C.int, end_col: C.int, attr: C.int) ---
	@(link_name = "default_gridview")
	default_gridview_u8: u8 // address-of only
	@(link_name = "msg_grid_adj")
	msg_grid_adj_u8: u8 // address-of only
}

// Default 'scroll' value: half the view height, at least 1 (C static inline).
@(export)
win_default_scroll :: proc "c"(wp: rawptr) -> C.longlong {
	h := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2
	return C.longlong(max(h, 1))
}

@(export)
win_comp_scroll :: proc "c"(wp: rawptr) {
	old := (^C.longlong)(uintptr(wp) + W_P_SCR_OFF)^
	(^C.longlong)(uintptr(wp) + W_P_SCR_OFF)^ = win_default_scroll(wp)
	if (^C.longlong)(uintptr(wp) + W_P_SCR_OFF)^ != old {
		// Used by "verbose set scroll".
		(^C.int)(uintptr(wp) + W_P_SCRIPT_CTX_OFF + uintptr(KWINOPT_SCROLL_O) * SCCTX_STRIDE)^ = SID_WINLAYOUT_O
		(^C.int)(uintptr(wp) + W_P_SCRIPT_CTX_OFF + uintptr(KWINOPT_SCROLL_O) * SCCTX_STRIDE + 8)^ = 0
	}
}

// Resize frame "frp" to be "n" lines higher (and parents). (C static.)
frame_add_height_o :: proc "c"(frp_in: rawptr, n: C.int) {
	frame_new_height(frp_in, (^C.int)(uintptr(frp_in) + FR_HEIGHT_OFF)^ + n, false, false, false)
	frp := (^rawptr)(uintptr(frp_in) + FR_PARENT_OFF)^
	for {
		if frp == nil {
			break
		}
		(^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ += n
		frp = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
	}
}

// command_height: called whenever p_ch has been changed.
@(export)
command_height :: proc "c"() {
	old_p_ch := C.int((^C.longlong)(uintptr(curtab) + TP_CH_USED_OFF)^)
	// Find bottom frame with width of screen.
	frp := (^rawptr)(uintptr(lastwin_nofloating(nil)) + W_FRAME_OFF)^
	for (^C.int)(uintptr(frp) + FR_WIDTH_OFF)^ != Columns &&
		(^rawptr)(uintptr(frp) + FR_PARENT_OFF)^ != nil {
		frp = (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
	}
	// Avoid changing the height of a window with 'winfixheight' set.
	for (^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil &&
		b_at((^u8)(uintptr(frp) + FR_LAYOUT_OFF), 0) == FR_LEAF_O &&
		(^C.int)(uintptr((^rawptr)(uintptr(frp) + FR_WIN_OFF)^) + W_P_WFH_OFF)^ != 0 {
		frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
	}
	for p_ch > C.longlong(old_p_ch) && nvim_odin_get_command_frame_height_r() {
		if frp == nil {
			emsg(cstring(E36_S))
			p_ch = C.longlong(old_p_ch)
			break
		}
		h := min(C.int(C.longlong(p_ch) - C.longlong(old_p_ch)),
			(^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^ - frame_minheight_o(frp, nil))
		frame_add_height_o(frp, -h)
		old_p_ch += h
		frp = (^rawptr)(uintptr(frp) + FR_PREV_OFF)^
	}
	if C.longlong(p_ch) < C.longlong(old_p_ch) &&
		nvim_odin_get_command_frame_height_r() && frp != nil {
		frame_add_height_o(frp, C.int(C.longlong(old_p_ch) - C.longlong(p_ch)))
	}
	// Recompute window positions.
	win_comp_pos()
	win_fix_scroll(true)
	cmdline_row = Rows - C.int(p_ch)
	redraw_cmdline_g = true
	// Clear the cmdheight area.
	if msg_scrolled == 0 && full_screen {
		grid := transmute(rawptr)(&default_gridview_u8)
		if !ui_has(kUIMessages_S) {
			msg_grid_validate_r()
			grid = transmute(rawptr)(&msg_grid_adj_u8)
		}
		grid_clear_r(grid, cmdline_row, Rows, 0, Columns, 0)
		msg_row = cmdline_row
	}
	// Use the value of p_ch that we remembered. This is needed for when
	// the GUI starts up and when p_ch was changed in another tab page.
	(^C.longlong)(uintptr(curtab) + TP_CH_USED_OFF)^ = C.longlong(p_ch)
	nvim_odin_set_min_set_ch_r(C.longlong(p_ch))
}

// ── Batch 21: prompt-window enter/leave ──────────────────────────────────────

B_PROMPT_INSERT_OFF :: 11220

foreign _ {
	@(link_name = "clear_cmdline")
	clear_cmdline_g: bool
	@(link_name = "mode_displayed")
	mode_displayed_g: bool
	@(link_name = "stop_insert_mode")
	stop_insert_mode_g: bool
}

@(export)
leaving_window :: proc "c"(win: rawptr) {
	// Only matters for a prompt window. No mode changes for a prompt
	// buffer in an autocommand window (temporary use during autocmd).
	if !bt_prompt((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) || is_aucmd_win_r(win) {
		return
	}
	// When leaving a prompt window stop Insert mode and perhaps restart
	// it when entering that window again.
	(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_PROMPT_INSERT_OFF)^ = restart_edit
	if restart_edit != 0 && mode_displayed_g {
		clear_cmdline_g = true // unshow mode later
	}
	restart_edit = 0
	// When leaving the window (or closing it) was done from a callback we
	// need to break out of the Insert mode loop and restart Insert mode
	// when entering the window again.
	if (State & MODE_INSERT) != 0 && !stop_insert_mode_g {
		stop_insert_mode_g = true
		if (^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_PROMPT_INSERT_OFF)^ == 0 {
			(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_PROMPT_INSERT_OFF)^ = 'A'
		}
	}
}

@(export)
entering_window :: proc "c"(win: rawptr) {
	// Only matters for a prompt window. No mode changes for a prompt
	// buffer in an autocommand window (temporary use during autocmd).
	if !bt_prompt((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) || is_aucmd_win_r(win) {
		return
	}
	// When switching to a prompt buffer that was in Insert mode, don't
	// stop Insert mode (may have been set in leaving_window()).
	if (^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_PROMPT_INSERT_OFF)^ != 0 {
		stop_insert_mode_g = false
	}
	// When entering the prompt window restart Insert mode if we were in
	// Insert mode when we left it and not already in Insert mode.
	if (State & MODE_INSERT) == 0 {
		restart_edit = (^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_PROMPT_INSERT_OFF)^
	}
}

// ── Batch 22: tabpage_move ───────────────────────────────────────────────────

EVENT_TABMOVED_O :: 116

foreign _ {
	@(link_name = "tabpage_move_disallowed")
	tabpage_move_disallowed_g: C.int
}

// Move the current tab page to after tab page "nr".
@(export)
tabpage_move :: proc "c"(nr: C.int) {
	if curtab == nil {
		return
	}
	if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil {
		return
	}
	if tabpage_move_disallowed_g != 0 {
		return
	}
	n: C.int = 1
	tp := first_tabpage
	for (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil && n < nr {
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		n += 1
	}
	if tp == curtab || (nr > 0 && (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil &&
		(^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ == curtab) {
		return
	}
	old_nr := tabpage_index(curtab)
	tp_dst := tp
	// Remove the current tab page from the list of tab pages.
	if curtab == first_tabpage {
		first_tabpage = (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
	} else {
		tp = nil
		tp2 := first_tabpage
		for tp2 != nil {
			if (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^ == curtab {
				tp = tp2
				break
			}
			tp2 = (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^
		}
		if tp == nil { // "cannot happen"
			return
		}
		(^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ = (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
	}
	// Re-insert it at the specified position.
	if nr <= 0 {
		(^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^ = first_tabpage
		first_tabpage = curtab
	} else {
		(^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^ = (^rawptr)(uintptr(tp_dst) + TP_NEXT_OFF)^
		(^rawptr)(uintptr(tp_dst) + TP_NEXT_OFF)^ = curtab
	}
	// Need to redraw the tabline. Tab page contents doesn't change.
	redraw_tabline_opt = true
	if has_event_r(EVENT_TABMOVED_O) {
		prev_idx: [NUMBUFLEN]u8
		libc.snprintf(&prev_idx[0], NUMBUFLEN, cstring("%i"), old_nr)
		// MAXSIZE_TEMP_DICT(data, 2) + PUT_C tabnr_old/tabnr_new (mark.odin pattern).
		items: [2]Key_Value_Pair
		d := Api_Dict{0, 2, &items[0]}
		items[d.size] = Key_Value_Pair{
			key = Api_String{data = transmute(^u8)(cstring("tabnr_old")), size = 9},
			value = Api_Object{t = kObjectTypeInteger_API},
		}
		(^i64)(uintptr(&items[d.size]) + 8)^ = i64(old_nr)
		d.size += 1
		items[d.size] = Key_Value_Pair{
			key = Api_String{data = transmute(^u8)(cstring("tabnr_new")), size = 9},
			value = Api_Object{t = kObjectTypeInteger_API},
		}
		(^i64)(uintptr(&items[d.size]) + 8)^ = i64(tabpage_index(curtab))
		d.size += 1
		obj: Api_Object
		obj.t = kObjectTypeDict_API
		(^Api_Dict)(uintptr(&obj) + 8)^ = d
		aucmd_defer(EVENT_TABMOVED_O, &prev_idx[0], nil, AUGROUP_ALL, curbuf, nil, &obj)
	}
}

// ── Batch 23: statusline-height cluster ──────────────────────────────────────

// Look for a horizontally resizable frame from "fr" (C static).
find_horizontally_resizable_frame_o :: proc "c"(fr_in: rawptr) -> rawptr {
	fp := fr_in
	for (^C.int)(uintptr(fp) + FR_HEIGHT_OFF)^ <= frame_minheight_o(fp, nil) {
		if fp == topframe_g {
			return nil
		}
		// In a column of frames: go to frame above. If already at the top
		// or in a row of frames: go to parent.
		if b_at((^u8)(uintptr((^rawptr)(uintptr(fp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
			(^rawptr)(uintptr(fp) + FR_PREV_OFF)^ != nil {
			fp = (^rawptr)(uintptr(fp) + FR_PREV_OFF)^
		} else {
			fp = (^rawptr)(uintptr(fp) + FR_PARENT_OFF)^
		}
	}
	return fp
}

// Take lines from resizable frames to make room for the statusline (C static).
resize_frame_for_status_o :: proc "c"(fr: rawptr) -> bool {
	wp := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
	fp := find_horizontally_resizable_frame_o(fr)
	if fp == nil {
		emsg(cstring(E36_S))
		return false
	} else if fp != fr {
		frame_new_height(fp, (^C.int)(uintptr(fp) + FR_HEIGHT_OFF)^ - 1, false, false, false)
		frame_fix_height_o(wp)
		win_comp_pos()
	} else {
		win_new_height(wp, (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ - 1)
	}
	return true
}

// Add or remove status lines per 'laststatus' (recursive; C static).
last_status_rec_o :: proc "c"(fr: rawptr, statusline: bool, is_stl_global: bool) {
	if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		wp := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
		is_last := is_bottom_win_o(wp)
		if is_last {
			if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0 &&
				(!statusline || is_stl_global) {
				win_remove_status_line(wp, false)
			} else if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ == 0 &&
				!is_stl_global && statusline {
				// Add statusline to window if needed
				(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
				if !resize_frame_for_status_o(fr) {
					return
				}
				comp_col_r()
			}
			// Set prev_height when difference is due to 'laststatus'.
			if abs((^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ -
				(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^) == 1 {
				(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^ =
					(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
			}
		} else if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0 && is_stl_global {
			// Global statusline: replace window statusline with separator.
			win_remove_status_line(wp, true)
		} else if (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ == 0 && !is_stl_global {
			// Non-global statusline: re-add it.
			(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = STATUS_HEIGHT_O
			(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 0
			comp_col_r()
		}
	} else {
		// Column or row frame: recurse over all child frames.
		fp := (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
		for fp != nil {
			last_status_rec_o(fp, statusline, is_stl_global)
			fp = (^rawptr)(uintptr(fp) + FR_NEXT_OFF)^
		}
	}
}

// Add or remove a status line from window(s) per 'laststatus'.
@(export)
last_status :: proc "c"(morewin: bool) {
	// Don't make a difference between horizontal or vertical split.
	last_status_rec_o(topframe_g, last_stl_height(morewin) > 0, global_stl_height() > 0)
	win_float_anchor_laststatus_r()
}

// Remove status line from window (hsep instead if add_hsep).
@(export)
win_remove_status_line :: proc "c"(wp: rawptr, add_hsep: bool) {
	(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = 0
	if add_hsep {
		(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = 1
	} else {
		win_new_height(wp,
			((^bool)(uintptr(wp) + W_FLOATING_OFF)^ ?
				(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ :
				(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^) + STATUS_HEIGHT_O)
	}
	comp_col_r()
	stl_clear_click_defs_r((^rawptr)(uintptr(wp) + W_STATUS_CLICK_DEFS_OFF)^,
		(^C.size_t)(uintptr(wp) + W_STATUS_CLICK_DEFS_SIZE_OFF)^)
	xfree((^rawptr)(uintptr(wp) + W_STATUS_CLICK_DEFS_OFF)^)
	(^C.size_t)(uintptr(wp) + W_STATUS_CLICK_DEFS_SIZE_OFF)^ = 0
	(^rawptr)(uintptr(wp) + W_STATUS_CLICK_DEFS_OFF)^ = nil
}

// Lines used by the global statusline.
@(export)
global_stl_height :: proc "c"() -> C.int {
	return p_ls_g == 3 ? STATUS_HEIGHT_O : 0
}

// Height of the last window's statusline (or global one if set).
@(export)
last_stl_height :: proc "c"(morewin: bool) -> C.int {
	if p_ls_g > 1 || (p_ls_g == 1 && (morewin || !one_window(firstwin, nil))) {
		return STATUS_HEIGHT_O
	}
	return 0
}

// Lines used by default by the window bar.
@(export)
global_winbar_height :: proc "c"() -> C.int {
	return b_at(p_wbr_g, 0) != 0 ? 1 : 0
}

// ── Batch 24: winbar + tabline heights ───────────────────────────────────────

W_P_WBR_OFF :: 1104
KUITABLINE_O :: 2
NOTDONE_O :: 2

foreign _ {
	@(link_name = "p_stal")
	p_stal_g: C.longlong
}

// Take lines to make room for the winbar (C static: no export/weak).
resize_frame_for_winbar_o :: proc "c"(fr: rawptr) -> bool {
	wp := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
	fp := find_horizontally_resizable_frame_o(fr)
	if fp == nil || fp == fr {
		emsg(cstring(E36_S))
		return false
	}
	frame_new_height(fp, (^C.int)(uintptr(fp) + FR_HEIGHT_OFF)^ - 1, false, false, false)
	win_new_height(wp, (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ + 1)
	frame_fix_height_o(wp)
	win_comp_pos()
	return true
}

// Add or remove window bar from window "wp".
@(export)
set_winbar_win :: proc "c"(wp: rawptr, make_room: bool, valid_cursor: bool) -> C.int {
	// Require the local value to be set in order to show winbar on a float.
	wbr := (^cstring)(uintptr(wp) + W_P_WBR_OFF)^
	local_set := wbr != nil && b_at(transmute(^u8)(wbr), 0) != 0
	winbar_height: C.int = 0
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		if local_set {
			winbar_height = 1
		}
	} else if b_at(p_wbr_g, 0) != 0 || local_set {
		winbar_height = 1
	}
	if (^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ != winbar_height {
		if winbar_height == 1 && (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ <= 1 {
			if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
				emsg(cstring(E36_S))
				return NOTDONE_O
			} else if !make_room || !resize_frame_for_winbar_o((^rawptr)(uintptr(wp) + W_FRAME_OFF)^) {
				return FAIL
			}
		}
		(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ = winbar_height
		win_set_inner_size(wp, valid_cursor)
		if winbar_height == 0 {
			// When removing winbar, deallocate the click defs array.
			stl_clear_click_defs_r((^rawptr)(uintptr(wp) + W_WINBAR_CLICK_DEFS_OFF)^,
				(^C.size_t)(uintptr(wp) + W_WINBAR_CLICK_DEFS_SIZE_OFF)^)
			xfree((^rawptr)(uintptr(wp) + W_WINBAR_CLICK_DEFS_OFF)^)
			(^C.size_t)(uintptr(wp) + W_WINBAR_CLICK_DEFS_SIZE_OFF)^ = 0
			(^rawptr)(uintptr(wp) + W_WINBAR_CLICK_DEFS_OFF)^ = nil
		}
	}
	return OK
}

// Add or remove window bars in current tab per 'winbar'.
@(export)
set_winbar :: proc "c"(make_room: bool) {
	// FOR_ALL_WINDOWS_IN_TAB(wp, curtab) = firstwin (curtab nuance).
	wp := firstwin
	for wp != nil {
		if set_winbar_win(wp, make_room, true) == FAIL {
			break
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Lines used by the tab page line.
@(export)
tabline_height :: proc "c"() -> C.int {
	if ui_has(KUITABLINE_O) {
		return 0
	}
	if p_stal_g == 0 {
		return 0
	}
	if p_stal_g == 1 {
		return (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil ? 0 : 1
	}
	return 1
}

// ── Batch 25: close_windows + min_rows ───────────────────────────────────────

MIN_LINES_O :: 2

// Close all windows showing buffer "buf" (e.g. before wiping it).
@(export)
close_windows :: proc "c"(buf: rawptr, keep_curwin: bool) {
	RedrawingDisabled += 1
	defer RedrawingDisabled -= 1 // C: theend label
	// Start from lastwin to close floating windows with the same buffer
	// first. When the autocommand window is involved win_close() may need
	// to print an error message.
	wp := lastwin_g
	for wp != nil && (is_aucmd_win_r(lastwin_g) || !one_window(wp, nil)) {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
			(!keep_curwin || wp != curwin) &&
			!(win_locked(wp) != 0 ||
				(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_LOCKED_OFF)^ > 0) {
			if window_layout_locked(CMD_SIZE_O) {
				return // Only give one error message.
			}
			if win_close(wp, false, false) == FAIL {
				// If closing the window fails give up, to avoid looping forever.
				break
			}
			// Start all over, autocommands may change the window layout.
			wp = lastwin_g
		} else {
			wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
		}
	}
	nexttp: rawptr
	// Also check windows in other tab pages.
	tp := first_tabpage
	for tp != nil {
		nexttp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		if tp != curtab {
			// Start from tp_lastwin to close floating windows first.
			wp = (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
					!(win_locked(wp) != 0 ||
						(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_LOCKED_OFF)^ > 0) {
					if window_layout_locked(CMD_SIZE_O) {
						return // Only give one error message.
					}
					if !win_close_othertab(wp, 0, tp, false) {
						// If closing the window fails give up, to avoid looping.
						break
					}
					// Start all over, the tab page may be closed and
					// autocommands may change the window layout.
					nexttp = first_tabpage
					break
				}
				wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
			}
		}
		tp = nexttp
	}
}

// Minimal rows needed to display the windows of tab page "tp".
@(export)
min_rows :: proc "c"(tp: rawptr) -> C.int {
	if firstwin == nil { // not initialized yet
		return MIN_LINES_O
	}
	total := frame_minheight_o((^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^, nil)
	total += tabline_height() + global_stl_height()
	if (tp == curtab ? C.longlong(p_ch) :
		(^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^) > 0 {
		total += 1 // count the room for the command line
	}
	return total
}

// Minimal rows needed for all tab pages.
@(export)
min_rows_for_all_tabpages :: proc "c"() -> C.int {
	if firstwin == nil { // not initialized yet
		return MIN_LINES_O
	}
	total: C.int = 0
	tp := first_tabpage
	for tp != nil {
		n := frame_minheight_o((^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^, nil)
		if (tp == curtab ? C.longlong(p_ch) :
			(^C.longlong)(uintptr(tp) + TP_CH_USED_OFF)^) > 0 {
			n += 1 // count the room for the command line
		}
		total = max(total, n)
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	total += tabline_height() + global_stl_height()
	return total
}

// ── Batch 26: scroll/size/lock leaves ────────────────────────────────────────

VALID_WCOL_O :: 0x02
VALID_CROW_O :: 0x10

foreign _ {
	@(link_name = "skip_update_topline")
	skip_update_topline_g: bool
	@(link_name = "nvim_odin_get_last_win_id")
	nvim_odin_get_last_win_id_r :: proc "c" () -> C.int ---
}

// Set the fraction of the cursor position in the window (for scroll restore).
@(export)
set_fraction :: proc "c"(wp: rawptr) {
	if (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ > 1 {
		// Cursor in first line counts as halfway that line, etc.
		(^C.int)(uintptr(wp) + W_FRACTION_OFF)^ =
			((^C.int)(uintptr(wp) + W_WROW_OFF)^ * FRACTION_MULT_O +
				FRACTION_MULT_O / 2) / (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	}
}

// Handle scroll position per 'splitkeep' after resize (current tab only).
@(export)
win_fix_scroll :: proc "c"(resize: bool) {
	if b_at(p_spk_g, 0) == 'c' {
		return // 'splitkeep' is "cursor"
	}
	skip_update_topline_g = true
	wp := firstwin
	for wp != nil {
		// Skip when window height has not changed or when floating.
		if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
			(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ !=
			(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^ {
			// Cursor may now be invalid (kept so until made current).
			(^bool)(uintptr(wp) + W_DO_WIN_FIX_CURSOR_OFF)^ = true
			// If window has moved update botline to keep same screenlines.
			if b_at(p_spk_g, 0) == 's' &&
				(^C.int)(uintptr(wp) + W_WINROW_OFF)^ !=
				(^C.int)(uintptr(wp) + W_PREV_WINROW_OFF)^ &&
				(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1 <=
				(^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ {
				diff := ((^C.int)(uintptr(wp) + W_WINROW_OFF)^ -
					(^C.int)(uintptr(wp) + W_PREV_WINROW_OFF)^) +
					((^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ -
						(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^)
				cursor: Pos_T
				libc.memcpy(&cursor, transmute(rawptr)(uintptr(wp) + W_CURSOR_OFF), size_of(Pos_T))
				(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ =
					(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1
				// Add difference in height and row to botline.
				if diff > 0 {
					cursor_down_inner_r(wp, diff, false)
				} else {
					cursor_up_inner_r(wp, C.long(diff), false)
				}
				// Scroll to put the new cursor at the bottom of the screen.
				(^C.int)(uintptr(wp) + W_FRACTION_OFF)^ = FRACTION_MULT_O
				scroll_to_fraction(wp, (^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^)
				libc.memcpy(transmute(rawptr)(uintptr(wp) + W_CURSOR_OFF), &cursor, size_of(Pos_T))
				(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WCOL_O)
			} else if wp == curwin {
				(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_CROW_O)
			}
			invalidate_botline_win_r(wp)
			validate_botline_win_r(wp)
		}
		(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^ = (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
		(^C.int)(uintptr(wp) + W_PREV_WINROW_OFF)^ = (^C.int)(uintptr(wp) + W_WINROW_OFF)^
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	skip_update_topline_g = false
	// Ensure cursor is valid when not in normal mode or when resized.
	if (get_real_state_r() & (MODE_NORMAL_O | MODE_CMDLINE_O | MODE_TERMINAL_O)) == 0 {
		win_fix_cursor_o(false)
	} else if resize {
		win_fix_cursor_o(true)
	}
}

// Set window height (recomputes inner size).
@(export)
win_new_height :: proc "c"(wp: rawptr, height_in: C.int) {
	// Don't want a negative height (equalize will fix it soon).
	height := max(height_in, 0)
	if (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ == height {
		return // nothing to do
	}
	(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ = height
	(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
	win_set_inner_size(wp, true)
}

// Set window width (recomputes inner size).
@(export)
win_new_width :: proc "c"(wp: rawptr, width_in: C.int) {
	// Should we give an error if width < 0?
	width := max(width_in, 0)
	(^C.int)(uintptr(wp) + W_WIDTH_OFF)^ = width
	(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
	win_set_inner_size(wp, true)
}

// Last allocated window handle.
@(export)
get_last_winid :: proc "c"() -> C.int {
	return nvim_odin_get_last_win_id_r()
}

// Don't let autocommands close the given window (lock count).
@(export)
win_locked :: proc "c"(wp: rawptr) -> C.int {
	return (^C.int)(uintptr(wp) + W_LOCKED_OFF)^
}

// ── Batch 27: scroll_to_fraction ─────────────────────────────────────────────

UPD_SOME_VALID_O :: 35

foreign _ {
	@(link_name = "plines_win")
	plines_win_r :: proc "c" (wp: rawptr, lnum: C.int, limit_winheight: bool) -> C.int ---
	@(link_name = "plines_win_col")
	plines_win_col_r :: proc "c" (wp: rawptr, lnum: C.int, column: C.long) -> C.int ---
	@(link_name = "plines_win_nofill")
	plines_win_nofill_r :: proc "c" (wp: rawptr, lnum: C.int, limit_winheight: bool) -> C.int ---
	@(link_name = "decor_conceal_line")
	decor_conceal_line_r :: proc "c" (wp: rawptr, row: C.int, check_cursor: bool) -> bool ---
	@(link_name = "curs_columns")
	curs_columns_r :: proc "c" (wp: rawptr, may_scroll: C.int) ---
	@(link_name = "win_col_off")
	win_col_off_r :: proc "c" (wp: rawptr) -> C.int ---
	@(link_name = "win_col_off2")
	win_col_off2_r :: proc "c" (wp: rawptr) -> C.int ---
}

// Scroll so the cursor sits at the same relative height as before.
@(export)
scroll_to_fraction :: proc "c"(wp: rawptr, prev_height: C.int) {
	height := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	// Don't change w_topline in any of these cases:
	// - window height is 0
	// - 'scrollbind' is set and this isn't the current window
	// - window height is sufficient to display the whole buffer and the
	//   first line is visible.
	if height > 0 &&
		((^C.int)(uintptr(wp) + W_P_SCB_OFF)^ == 0 || wp == curwin) &&
		(height < (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ ||
			(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ > 1) {
		// Find a topline showing the cursor at the same relative
		// position in the window as before (more or less).
		lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
		// can happen when starting up
		lnum = max(lnum, 1)
		(^C.int)(uintptr(wp) + W_WROW_OFF)^ =
			((^C.int)(uintptr(wp) + W_FRACTION_OFF)^ * height - 1) / FRACTION_MULT_O
		line_size := plines_win_col_r(wp, lnum, C.long((^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^)) - 1
		sline := (^C.int)(uintptr(wp) + W_WROW_OFF)^ - line_size
		if sline >= 0 {
			// Make sure the whole cursor line is visible, if possible.
			rows := plines_win_r(wp, lnum, false)
			if sline > (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - rows {
				sline = (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ - rows
				(^C.int)(uintptr(wp) + W_WROW_OFF)^ -= rows - line_size
			}
		}
		if sline < 0 {
			// Cursor line would go off top of screen if w_wrow was this
			// high. Make cursor line the first line in the window. If not
			// enough room use w_skipcol.
			(^C.int)(uintptr(wp) + W_WROW_OFF)^ = line_size
			if (^C.int)(uintptr(wp) + W_WROW_OFF)^ >=
				(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ &&
				(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp) > 0 {
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ +=
					(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp)
				(^C.int)(uintptr(wp) + W_WROW_OFF)^ -= 1
				for (^C.int)(uintptr(wp) + W_WROW_OFF)^ >=
					(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ {
					(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ +=
						(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp) +
						win_col_off2_r(wp)
					(^C.int)(uintptr(wp) + W_WROW_OFF)^ -= 1
				}
			}
		} else if sline > 0 {
			for sline > 0 && lnum > 1 {
				hasFolding(wp, lnum, &lnum, nil)
				if lnum == 1 {
					// first line in buffer is folded
					line_size = !decor_conceal_line_r(wp, lnum - 1, false) ? 1 : 0
					sline -= 1
					break
				}
				lnum -= 1
				if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					line_size = plines_win_nofill_r(wp, lnum, true) +
						(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
				} else {
					line_size = plines_win_r(wp, lnum, true)
				}
				sline -= line_size
			}
			if sline < 0 {
				// Line we want at top would go off top of screen. Use next
				// line instead.
				hasFolding(wp, lnum, nil, &lnum)
				lnum += 1
				(^C.int)(uintptr(wp) + W_WROW_OFF)^ -= line_size + sline
			} else if sline > 0 {
				// First line of file reached, use that as topline.
				lnum = 1
				(^C.int)(uintptr(wp) + W_WROW_OFF)^ -= sline
			}
		}
		set_topline(wp, lnum)
	}
	if wp == curwin {
		curs_columns_r(wp, 0) // validate w_wrow
	}
	if prev_height > 0 {
		(^C.int)(uintptr(wp) + W_PREV_FRACTION_ROW_OFF)^ =
			(^C.int)(uintptr(wp) + W_WROW_OFF)^
	}
	redraw_later(wp, UPD_SOME_VALID_O)
	invalidate_botline_win_r(wp)
}

// ── Batch 28: win_comp_pos ───────────────────────────────────────────────────
// WinConfig.relative@44 (→10604 abs), kFloatRelativeWindow=1 probed/checked.

WCFG_RELATIVE_OFF :: 10604
KFLOAT_REL_WINDOW_O :: 1

// Recompute window positions and return last row used.
@(export)
win_comp_pos :: proc "c"() -> C.int {
	row := tabline_height()
	col: C.int = 0
	frame_comp_pos_o(topframe_g, &row, &col)
	wp := lastwin_g
	for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		// float might be anchored to moved window
		if (^C.int)(uintptr(wp) + WCFG_RELATIVE_OFF)^ == KFLOAT_REL_WINDOW_O {
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
		}
		wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
	return row + global_stl_height()
}

// ── Batch 29: win_remove + win_get_tabwin ────────────────────────────────────

foreign _ {
	@(link_name = "win_has_winnr")
	win_has_winnr_r :: proc "c" (wp: rawptr, tp: rawptr) -> bool ---
}

// Unlink window "wp" from the window list of tab page "tp"
// (NULL tp = current tab page).
@(export)
win_remove :: proc "c"(wp: rawptr, tp: rawptr) {
	if (^rawptr)(uintptr(wp) + W_PREV_OFF)^ != nil {
		(^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_PREV_OFF)^) + W_NEXT_OFF)^ =
			(^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	} else if tp == nil {
		firstwin = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		(^rawptr)(uintptr(curtab) + TP_FIRSTWIN_OFF)^ =
			(^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	} else {
		(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^ =
			(^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ != nil {
		(^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_NEXT_OFF)^) + W_PREV_OFF)^ =
			(^rawptr)(uintptr(wp) + W_PREV_OFF)^
	} else if tp == nil {
		lastwin_g = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
		(^rawptr)(uintptr(curtab) + TP_LASTWIN_OFF)^ =
			(^rawptr)(uintptr(wp) + W_PREV_OFF)^
	} else {
		(^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ =
			(^rawptr)(uintptr(wp) + W_PREV_OFF)^
	}
}

// Find tab/window numbers for window handle "id".
@(export)
win_get_tabwin :: proc "c"(id: C.int, tabnr: ^C.int, winnr: ^C.int) {
	tabnr^ = 0
	winnr^ = 0
	tnum: C.int = 1
	wnum: C.int = 1
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^C.int)(uintptr(wp) + W_HANDLE_OFF)^ == id {
				if win_has_winnr_r(wp, tp) {
					winnr^ = wnum
					tabnr^ = tnum
				}
				return
			}
			if win_has_winnr_r(wp, tp) {
				wnum += 1
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tnum += 1
		wnum = 1
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// ── Batch 30: screensize + snapshot restore ──────────────────────────────────

KOPT_WINDOW_O :: 360

foreign _ {
	@(link_name = "p_window")
	p_window_g: C.longlong
}

// Update window sizes after Rows/Columns changed.
@(export)
win_new_screensize :: proc "c"() {
	if old_rows_b30 != Rows {
		// If 'window' uses the whole screen, keep it using that.
		// Don't change it when set with "-w size" on the command line.
		if p_window_g == C.longlong(old_rows_b30) - 1 ||
			(old_rows_b30 == 0 && !option_was_set(KOPT_WINDOW_O)) {
			p_window_g = C.longlong(Rows) - 1
		}
		old_rows_b30 = Rows
		win_new_screen_rows() // update window sizes
	}
	if old_columns_b30 != Columns {
		old_columns_b30 = Columns
		win_new_screen_cols() // update window sizes
	}
}

@(private="file")
old_rows_b30: C.int = 0

@(private="file")
old_columns_b30: C.int = 0

// Check snapshot vs live layout/validity (C static: no export/weak).
check_snapshot_rec_o :: proc "c"(sn: rawptr, fr: rawptr) -> C.int {
	if b_at((^u8)(uintptr(sn) + FR_LAYOUT_OFF), 0) !=
		b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) ||
		((^rawptr)(uintptr(sn) + FR_NEXT_OFF)^ == nil) !=
		((^rawptr)(uintptr(fr) + FR_NEXT_OFF)^ == nil) ||
		((^rawptr)(uintptr(sn) + FR_CHILD_OFF)^ == nil) !=
		((^rawptr)(uintptr(fr) + FR_CHILD_OFF)^ == nil) ||
		((^rawptr)(uintptr(sn) + FR_NEXT_OFF)^ != nil &&
			check_snapshot_rec_o((^rawptr)(uintptr(sn) + FR_NEXT_OFF)^,
				(^rawptr)(uintptr(fr) + FR_NEXT_OFF)^) == FAIL) ||
		((^rawptr)(uintptr(sn) + FR_CHILD_OFF)^ != nil &&
			check_snapshot_rec_o((^rawptr)(uintptr(sn) + FR_CHILD_OFF)^,
				(^rawptr)(uintptr(fr) + FR_CHILD_OFF)^) == FAIL) ||
		((^rawptr)(uintptr(sn) + FR_WIN_OFF)^ != nil &&
			!win_valid((^rawptr)(uintptr(sn) + FR_WIN_OFF)^)) {
		return FAIL
	}
	return OK
}

// Restore frame sizes from snapshot, return stored curwin (C static).
restore_snapshot_rec_o :: proc "c"(sn: rawptr, fr: rawptr) -> rawptr {
	wp: rawptr = nil
	(^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ = (^C.int)(uintptr(sn) + FR_HEIGHT_OFF)^
	(^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ = (^C.int)(uintptr(sn) + FR_WIDTH_OFF)^
	if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) == FR_LEAF_O {
		frame_new_height(fr, (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^, false, false, false)
		frame_new_width(fr, (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^, false, false)
		wp = (^rawptr)(uintptr(sn) + FR_WIN_OFF)^
	}
	if (^rawptr)(uintptr(sn) + FR_NEXT_OFF)^ != nil {
		wp2 := restore_snapshot_rec_o((^rawptr)(uintptr(sn) + FR_NEXT_OFF)^,
			(^rawptr)(uintptr(fr) + FR_NEXT_OFF)^)
		if wp2 != nil {
			wp = wp2
		}
	}
	if (^rawptr)(uintptr(sn) + FR_CHILD_OFF)^ != nil {
		wp2 := restore_snapshot_rec_o((^rawptr)(uintptr(sn) + FR_CHILD_OFF)^,
			(^rawptr)(uintptr(fr) + FR_CHILD_OFF)^)
		if wp2 != nil {
			wp = wp2
		}
	}
	return wp
}

// Restore a previously created snapshot, if layout still matches.
@(export)
restore_snapshot :: proc "c"(idx: C.int, close_curwin: C.int) {
	snap := (^rawptr)(uintptr(curtab) + TP_SNAPSHOT_OFF + uintptr(idx) * 8)^
	if snap != nil &&
		(^C.int)(uintptr(snap) + FR_WIDTH_OFF)^ ==
		(^C.int)(uintptr(topframe_g) + FR_WIDTH_OFF)^ &&
		(^C.int)(uintptr(snap) + FR_HEIGHT_OFF)^ ==
		(^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^ &&
		check_snapshot_rec_o(snap, topframe_g) == OK {
		wp := restore_snapshot_rec_o(snap, topframe_g)
		win_comp_pos()
		if wp != nil && close_curwin != 0 {
			win_goto(wp)
		}
		redraw_all_later_r(UPD_NOT_VALID_O)
	}
	clear_snapshot_o(curtab, idx)
}

// ── Batch 31: check_lnums family ─────────────────────────────────────────────
// w_save_cursor@456; pos_save_T 32B {topline_save@0, topline_corr@4,
// cursor_save@8 (12B), cursor_corr@20 (12B)} — cc-probed via off38.

W_SAVE_CURSOR_OFF :: 456
PS_TOPLINE_SAVE_OFF :: 0
PS_TOPLINE_CORR_OFF :: 4
PS_CURSOR_SAVE_OFF :: 8
PS_CURSOR_CORR_OFF :: 20

// pos_T equality (C static inline equalpos).
equalpos_o :: proc "c"(a: Pos_T, b: Pos_T) -> bool {
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

// Clamp cursors/toplines to buffer line count, saving originals (C static).
check_lnums_both_o :: proc "c"(do_curwin: bool, nested: bool) {
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (do_curwin || wp != curwin) &&
				(^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
				sc := uintptr(wp) + W_SAVE_CURSOR_OFF
				if !nested {
					// save the original cursor position and topline
					(^Pos_T)(sc + PS_CURSOR_SAVE_OFF)^ = (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
					(^C.int)(sc + PS_TOPLINE_SAVE_OFF)^ =
						(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
				}
				need_adjust := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ >
					(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
				if need_adjust {
					(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ =
						(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
				}
				if need_adjust || !nested {
					// save the (corrected) cursor position
					(^Pos_T)(sc + PS_CURSOR_CORR_OFF)^ = (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
				}
				need_adjust = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ >
					(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
				if need_adjust {
					(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ =
						(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
				}
				if need_adjust || !nested {
					// save the (corrected) topline
					(^C.int)(sc + PS_TOPLINE_CORR_OFF)^ =
						(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// Correct cursor lnum in other windows (after changing current buffer).
@(export)
check_lnums :: proc "c"(do_curwin: bool) {
	check_lnums_both_o(do_curwin, false)
}

// Like check_lnums() but for when check_lnums() was already called.
@(export)
check_lnums_nested :: proc "c"(do_curwin: bool) {
	check_lnums_both_o(do_curwin, true)
}

// Restore cursor/topline stored by check_lnums().
@(export)
reset_lnums :: proc "c"() {
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
				sc := uintptr(wp) + W_SAVE_CURSOR_OFF
				// Restore the value if the autocommand didn't change it and
				// it was set.
				if equalpos_o((^Pos_T)(sc + PS_CURSOR_CORR_OFF)^,
					(^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^) &&
					(^C.int)(sc + PS_CURSOR_SAVE_OFF)^ != 0 {
					(^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^ =
						(^Pos_T)(sc + PS_CURSOR_SAVE_OFF)^
				}
				if (^C.int)(sc + PS_TOPLINE_CORR_OFF)^ ==
					(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ &&
					(^C.int)(sc + PS_TOPLINE_SAVE_OFF)^ != 0 {
					(^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ =
						(^C.int)(sc + PS_TOPLINE_SAVE_OFF)^
				}
				if (^C.int)(sc + PS_TOPLINE_SAVE_OFF)^ >
					(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
					(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_TOPLINE_O)
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// ── Batch 32: win_set_inner_size ─────────────────────────────────────────────
// w_width_request@512/w_height_request@508/w_height_outer@532/w_width_outer@536/
// w_winrow_off@492/w_wincol_off@496/w_border_adj@516 — cc-probed via off39.

W_WIDTH_REQUEST_OFF :: 512
W_HEIGHT_REQUEST_OFF :: 508
W_WINROW_OFF2_OFF :: 492 // w_winrow_off (vs w_winrow@416)
W_WINCOL_OFF2_OFF :: 496 // w_wincol_off (vs w_wincol@440)

foreign _ {
	@(link_name = "changed_line_abv_curs_win")
	changed_line_abv_curs_win_r :: proc "c" (wp: rawptr) ---
	@(link_name = "win_border_height")
	win_border_height_r :: proc "c" (wp: rawptr) -> C.int ---
	@(link_name = "win_border_width")
	win_border_width_r :: proc "c" (wp: rawptr) -> C.int ---
	@(link_name = "ui_call_win_viewport_margins")
	ui_call_win_viewport_margins_r :: proc "c" (grid: C.longlong, win: C.int, top: C.int, bottom: C.int, left: C.int, right: C.int) ---
	@(link_name = "win_grid_alloc")
	win_grid_alloc_r :: proc "c" (wp: rawptr) ---
}

// Recompute inner size/outer rect after height/width change.
@(export)
win_set_inner_size :: proc "c"(wp: rawptr, valid_cursor: bool) {
	width := (^C.int)(uintptr(wp) + W_WIDTH_REQUEST_OFF)^
	if width == 0 {
		width = (^C.int)(uintptr(wp) + W_WIDTH_OFF)^
	}
	prev_height := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	height := (^C.int)(uintptr(wp) + W_HEIGHT_REQUEST_OFF)^
	if height == 0 {
		height = max(0, (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ -
			(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^)
	}
	if height != prev_height {
		if height > 0 && valid_cursor {
			if wp == curwin && (b_at(p_spk_g, 0) == 'c' || (^bool)(uintptr(wp) + W_FLOATING_OFF)^) {
				// w_wrow needs to be valid (may recurse via laststatus).
				validate_cursor_r(curwin)
			}
			if (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ != prev_height {
				return // Recursive call already changed the size, bail out.
			}
			if (^C.int)(uintptr(wp) + W_WROW_OFF)^ !=
				(^C.int)(uintptr(wp) + W_PREV_FRACTION_ROW_OFF)^ {
				set_fraction(wp)
			}
		}
		(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ = height
		win_comp_scroll(wp)
		// No point adjusting scroll when exiting (values may be invalid).
		if valid_cursor && !exiting && (b_at(p_spk_g, 0) == 'c' || (^bool)(uintptr(wp) + W_FLOATING_OFF)^) {
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
			scroll_to_fraction(wp, prev_height)
		}
		redraw_later(wp, UPD_SOME_VALID_O)
	}
	if width != (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ {
		(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ = width
		(^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^ = 0
		if valid_cursor {
			changed_line_abv_curs_win_r(wp)
			invalidate_botline_win_r(wp)
			if wp == curwin && (b_at(p_spk_g, 0) == 'c' || (^bool)(uintptr(wp) + W_FLOATING_OFF)^) {
				curs_columns_r(wp, 1) // validate w_wrow
			}
		}
		redraw_later(wp, UPD_NOT_VALID_O)
	}
	if (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^)
	}
	float_stl_height: C.int = 0
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
		(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ != 0 {
		float_stl_height = STATUS_HEIGHT_O
	}
	(^C.int)(uintptr(wp) + W_HEIGHT_OUTER_OFF)^ =
		(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ + win_border_height_r(wp) +
		(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^ + float_stl_height
	(^C.int)(uintptr(wp) + W_WIDTH_OUTER_OFF)^ =
		(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ + win_border_width_r(wp)
	(^C.int)(uintptr(wp) + W_WINROW_OFF2_OFF)^ =
		(^C.int)(uintptr(wp) + W_BORDER_ADJ_OFF)^ +
		(^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^
	(^C.int)(uintptr(wp) + W_WINCOL_OFF2_OFF)^ =
		(^C.int)(uintptr(wp) + W_BORDER_ADJ_OFF + 3 * 4)^
	if ui_has(K_UIMULTIGRID_O) {
		ui_call_win_viewport_margins_r(
			C.longlong((^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^),
			(^C.int)(uintptr(wp) + W_HANDLE_OFF)^,
			(^C.int)(uintptr(wp) + W_WINROW_OFF2_OFF)^,
			(^C.int)(uintptr(wp) + W_BORDER_ADJ_OFF + 2 * 4)^,
			(^C.int)(uintptr(wp) + W_WINCOL_OFF2_OFF)^,
			(^C.int)(uintptr(wp) + W_BORDER_ADJ_OFF + 1 * 4)^)
	}
	(^bool)(uintptr(wp) + W_REDR_STATUS_OFF)^ = true
	// Must keep grid dimensions updated during redraw.
	if updating_screen_g {
		win_grid_alloc_r(wp)
	}
}

// ── Batch 33: win_size save/restore ──────────────────────────────────────────

// Save window sizes (width+vsep, height per window + total avail).
@(export)
win_size_save :: proc "c"(gap: ^Garray) {
	ga_init_r2(gap, size_of(C.int), 1)
	ga_grow(gap, win_count() * 2 + 1)
	// first entry is the total lines available for windows
	([^]C.int)(gap.ga_data)[gap.ga_len] =
		C.int(rows_avail_o()) + global_stl_height() - last_stl_height(false)
	gap.ga_len += 1
	wp := firstwin // FOR_ALL_WINDOWS_IN_TAB(wp, curtab): curtab nuance
	for wp != nil {
		([^]C.int)(gap.ga_data)[gap.ga_len] =
			(^C.int)(uintptr(wp) + W_WIDTH_OFF)^ +
			(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
		gap.ga_len += 1
		([^]C.int)(gap.ga_data)[gap.ga_len] =
			(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
		gap.ga_len += 1
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Restore window sizes if layout unchanged. Does not free the growarray.
@(export)
win_size_restore :: proc "c"(gap: ^Garray) {
	if win_count() * 2 + 1 == gap.ga_len &&
		([^]C.int)(gap.ga_data)[0] ==
		C.int(rows_avail_o()) + global_stl_height() - last_stl_height(false) {
		// The order matters, because frames contain other frames, but it's
		// difficult to get right. The easy way out is to do it twice.
		for j := 0; j < 2; j += 1 {
			i: C.int = 1
			wp := firstwin // curtab nuance, as above
			for wp != nil {
				width := ([^]C.int)(gap.ga_data)[i]
				i += 1
				height := ([^]C.int)(gap.ga_data)[i]
				i += 1
				if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
					frame_setwidth_o((^rawptr)(uintptr(wp) + W_FRAME_OFF)^, width, true)
					win_setheight_win(height, wp, true)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
		}
	}
}

// ── Batch 35: promotions + win_move_after ────────────────────────────────────

// Move window "win1" to below/right of "win2" and make it current.
// Only works within the same frame!
@(export)
win_move_after :: proc "c"(win1: rawptr, win2: rawptr) {
	// check if the arguments are reasonable
	if win1 == win2 {
		return
	}
	// check if there is something to do
	if (^rawptr)(uintptr(win2) + W_NEXT_OFF)^ != win1 {
		if (^rawptr)(uintptr((^rawptr)(uintptr(win1) + W_FRAME_OFF)^) + FR_PARENT_OFF)^ !=
			(^rawptr)(uintptr((^rawptr)(uintptr(win2) + W_FRAME_OFF)^) + FR_PARENT_OFF)^ {
			iemsg_r(cstring("INTERNAL: trying to move a window into another frame"))
			return
		}
		// may need to move the status line, window bar, horizontal or
		// vertical separator of the last window
		if win1 == lastwin_g {
			height := (^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_STATUS_HEIGHT_OFF)^
			(^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_STATUS_HEIGHT_OFF)^ =
				(^C.int)(uintptr(win1) + W_STATUS_HEIGHT_OFF)^
			(^C.int)(uintptr(win1) + W_STATUS_HEIGHT_OFF)^ = height
			height = (^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_HSEP_HEIGHT_OFF)^
			(^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_HSEP_HEIGHT_OFF)^ =
				(^C.int)(uintptr(win1) + W_HSEP_HEIGHT_OFF)^
			(^C.int)(uintptr(win1) + W_HSEP_HEIGHT_OFF)^ = height
			if (^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_VSEP_WIDTH_OFF)^ == 1 {
				// Remove the vertical separator from the last-but-one
				// window, add it to the last window. Adjust frame widths.
				(^C.int)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_VSEP_WIDTH_OFF)^ = 0
				(^C.int)(uintptr((^rawptr)(uintptr((^rawptr)(uintptr(win1) + W_PREV_OFF)^) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^ -= 1
				(^C.int)(uintptr(win1) + W_VSEP_WIDTH_OFF)^ = 1
				(^C.int)(uintptr((^rawptr)(uintptr(win1) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^ += 1
			}
		} else if win2 == lastwin_g {
			height := (^C.int)(uintptr(win1) + W_STATUS_HEIGHT_OFF)^
			(^C.int)(uintptr(win1) + W_STATUS_HEIGHT_OFF)^ =
				(^C.int)(uintptr(win2) + W_STATUS_HEIGHT_OFF)^
			(^C.int)(uintptr(win2) + W_STATUS_HEIGHT_OFF)^ = height
			height = (^C.int)(uintptr(win1) + W_HSEP_HEIGHT_OFF)^
			(^C.int)(uintptr(win1) + W_HSEP_HEIGHT_OFF)^ =
				(^C.int)(uintptr(win2) + W_HSEP_HEIGHT_OFF)^
			(^C.int)(uintptr(win2) + W_HSEP_HEIGHT_OFF)^ = height
			if (^C.int)(uintptr(win1) + W_VSEP_WIDTH_OFF)^ == 1 {
				// Remove the vertical separator from win1, add it to the
				// last window, win2. Adjust the frame widths.
				(^C.int)(uintptr(win2) + W_VSEP_WIDTH_OFF)^ = 1
				(^C.int)(uintptr((^rawptr)(uintptr(win2) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^ += 1
				(^C.int)(uintptr(win1) + W_VSEP_WIDTH_OFF)^ = 0
				(^C.int)(uintptr((^rawptr)(uintptr(win1) + W_FRAME_OFF)^) + FR_WIDTH_OFF)^ -= 1
			}
		}
		win_remove(win1, nil)
		frame_remove_o((^rawptr)(uintptr(win1) + W_FRAME_OFF)^)
		win_append(win2, win1, nil)
		frame_append_o((^rawptr)(uintptr(win2) + W_FRAME_OFF)^,
			(^rawptr)(uintptr(win1) + W_FRAME_OFF)^)
		win_comp_pos() // recompute w_winrow for all windows
		redraw_later(curwin, UPD_NOT_VALID_O)
	}
	(^bool)(uintptr(win1) + W_POS_CHANGED_OFF)^ = true
	(^bool)(uintptr(win2) + W_POS_CHANGED_OFF)^ = true
	win_enter(win1, false)
}

// ── Batch 36: split-guard + grid free + make_windows ─────────────────────────

E242_S :: "E242: Can't split a window while closing another"
SCREEN_GRID_SIZE_O :: 96

foreign _ {
	@(link_name = "ui_call_grid_destroy")
	ui_call_grid_destroy_r :: proc "c" (grid: C.longlong) ---
	@(link_name = "grid_free")
	grid_free_r :: proc "c" (grid: rawptr) ---
}

// Error if splitting is currently disallowed (e.g. buffer is closing).
@(export)
check_split_disallowed_err :: proc "c"(wp: rawptr, err: rawptr) -> bool {
	if nvim_odin_get_split_disallowed_r() > 0 {
		api_set_error_r(err, 2, cstring(E242_S), nil)
		return false
	}
	if (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_LOCKED_SPLIT_OFF)^ != 0 {
		api_set_error_r(err, 2, cstring("%s"), transmute(rawptr)(cstring(E1159_S)))
		return false
	}
	return true
}

// Free the grid of window "wp" (reinit clears for reuse as split).
@(export)
win_free_grid :: proc "c"(wp: rawptr, reinit: bool) {
	if (^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^ != 0 && ui_has(K_UIMULTIGRID_O) {
		ui_call_grid_destroy_r(C.longlong((^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^))
	}
	grid_free_r(transmute(rawptr)(uintptr(wp) + W_GRID_ALLOC_OFF))
	if reinit {
		// if a float is turned into a split, the grid data structure
		// will be reused
		libc.memset(transmute(rawptr)(uintptr(wp) + W_GRID_ALLOC_OFF), 0, SCREEN_GRID_SIZE_O)
	}
}

// Split into "count" windows (vertical if set). Returns actual number made.
@(export)
make_windows :: proc "c"(count_in: C.int, vertical: bool) -> C.int {
	count := count_in
	maxcount: C.int
	if vertical {
		// Each window needs at least 'winminwidth' lines and a separator.
		maxcount = C.int((^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ +
			(^C.int)(uintptr(curwin) + W_VSEP_WIDTH_OFF)^ -
			(C.int(p_wiw_opt) - C.int(p_wmw_opt))) / (C.int(p_wmw_opt) + 1)
	} else {
		// Each window needs at least 'winminheight' lines.
		// If statusline isn't global, each window also needs a statusline.
		// If 'winbar' is set, each window also needs a winbar.
		maxcount = C.int((^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ +
			(^C.int)(uintptr(curwin) + W_HSEP_HEIGHT_OFF)^ +
			(^C.int)(uintptr(curwin) + W_STATUS_HEIGHT_OFF)^ -
			(C.int(p_wh_opt) - C.int(p_wmh_opt))) /
			(C.int(p_wmh_opt) + STATUS_HEIGHT_O + global_winbar_height())
	}
	maxcount = max(maxcount, 2)
	count = min(count, maxcount)
	// add status line now, otherwise first window will be too big
	if count > 1 {
		last_status(true)
	}
	// Don't execute autocommands while creating the windows. Must do that
	// when putting the buffers in the windows.
	block_autocmds_r()
	todo := count - 1
	for todo > 0 {
		todo -= 1
		if vertical {
			if win_split((^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ -
				((^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ - todo) / (todo + 1) - 1,
				WSP_VERT_O | WSP_ABOVE_O) == FAIL {
				break
			}
		} else {
			if win_split((^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ -
				((^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ - todo * STATUS_HEIGHT_O) /
				(todo + 1) - STATUS_HEIGHT_O, WSP_ABOVE_O) == FAIL {
				break
			}
		}
	}
	unblock_autocmds_r()
	// return actual number of tab pages
	return count - todo
}

// ── Batch 42: mouse-dragged separators ───────────────────────────────────────

// Status line of "dragwin" is dragged "offset" lines down (negative is up).
@(export)
win_drag_status_line :: proc "c"(dragwin: rawptr, offset_in: C.int) {
	offset := offset_in
	fr := (^rawptr)(uintptr(dragwin) + W_FRAME_OFF)^
	curfr := fr
	if fr != topframe_g { // more than one window
		fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		// When the parent frame is not a column of frames, its parent
		// should be.
		if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) != FR_COL_O {
			curfr = fr
			if fr != topframe_g { // only a row of windows, may drag statusline
				fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
			}
		}
	}
	// If this is the last frame in a column, may want to resize the parent
	// frame instead (go two up to skip a row of frames).
	for curfr != topframe_g && (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ == nil {
		if fr != topframe_g {
			fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		}
		curfr = fr
		if fr != topframe_g {
			fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		}
	}
	room: C.int
	up := offset < 0 // if true, drag status line up, otherwise down
	if up { // drag up
		offset = -offset
		// sum up the room of the current frame and above it
		if fr == curfr {
			// only one window
			room = (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - frame_minheight_o(fr, nil)
		} else {
			room = 0
			fr = (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
			for {
				room += (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - frame_minheight_o(fr, nil)
				if fr == curfr {
					break
				}
				fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
			}
		}
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ // put fr at frame that grows
	} else { // drag down
		// Only dragging the last status line can reduce p_ch.
		room = Rows - cmdline_row
		if (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ != nil {
			room -= C.int(p_ch) + global_stl_height()
		} else if nvim_odin_get_min_set_ch_r() > 0 {
			room -= 1
		}
		room = max(room, 0)
		// sum up the room of frames below of the current one
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^
		for fr != nil {
			room += (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - frame_minheight_o(fr, nil)
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
		fr = curfr // put fr at window that grows
	}
	// If not enough room then move as far as we can
	offset = min(offset, room)
	if offset <= 0 {
		return
	}
	// Grow frame fr by "offset" lines.
	// Doesn't happen when dragging the last status line up.
	if fr != nil {
		frame_new_height(fr, (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ + offset, up, false, true)
	}
	if up {
		fr = curfr // current frame gets smaller
	} else {
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ // next frame gets smaller
	}
	// Now make the other frames smaller.
	for fr != nil && offset > 0 {
		n := frame_minheight_o(fr, nil)
		if (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - offset <= n {
			offset -= (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - n
			frame_new_height(fr, n, !up, false, true)
		} else {
			frame_new_height(fr, (^C.int)(uintptr(fr) + FR_HEIGHT_OFF)^ - offset, !up, false, true)
			break
		}
		if up {
			fr = (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
		} else {
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
	}
	win_comp_pos()
	win_fix_scroll(true)
	redraw_all_later_r(UPD_SOME_VALID_O)
	showmode_r()
}

// Separator line of "dragwin" is dragged "offset" lines right (neg is left).
@(export)
win_drag_vsep_line :: proc "c"(dragwin: rawptr, offset_in: C.int) {
	offset := offset_in
	fr := (^rawptr)(uintptr(dragwin) + W_FRAME_OFF)^
	if fr == topframe_g { // only one window (cannot happen?)
		return
	}
	curfr := fr
	fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
	// When the parent frame is not a row of frames, its parent should be.
	if b_at((^u8)(uintptr(fr) + FR_LAYOUT_OFF), 0) != FR_ROW_O {
		if fr == topframe_g { // only a column of windows (cannot happen?)
			return
		}
		curfr = fr
		fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
	}
	// If this is the last frame in a row, may want to resize a parent
	// frame instead.
	for (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ == nil {
		if fr == topframe_g {
			break
		}
		curfr = fr
		fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		if fr != topframe_g {
			curfr = fr
			fr = (^rawptr)(uintptr(fr) + FR_PARENT_OFF)^
		}
	}
	room: C.int
	left := offset < 0 // if true, drag separator line left, otherwise right
	if left { // drag left
		offset = -offset
		// sum up the room of the current frame and left of it
		room = 0
		fr = (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
		for {
			room += (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ - frame_minwidth_o(fr, nil)
			if fr == curfr {
				break
			}
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ // put fr at frame that grows
	} else { // drag right
		// sum up the room of frames right of the current one
		room = 0
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^
		for fr != nil {
			room += (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ - frame_minwidth_o(fr, nil)
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
		fr = curfr // put fr at window that grows
	}
	// If not enough room then move as far as we can
	offset = min(offset, room)
	// No room at all, quit.
	if offset <= 0 {
		return
	}
	if fr == nil {
		// This can happen when calling win_move_separator() on the
		// rightmost window. Just don't do anything.
		return
	}
	// grow frame fr by offset lines
	frame_new_width(fr, (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ + offset, left, false)
	// shrink other frames: current and at the left or at the right
	if left {
		fr = curfr // current frame gets smaller
	} else {
		fr = (^rawptr)(uintptr(curfr) + FR_NEXT_OFF)^ // next frame gets smaller
	}
	for fr != nil && offset > 0 {
		w := frame_minwidth_o(fr, nil)
		if (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ - offset <= w {
			offset -= (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ - w
			frame_new_width(fr, w, !left, false)
		} else {
			frame_new_width(fr, (^C.int)(uintptr(fr) + FR_WIDTH_OFF)^ - offset, !left, false)
			break
		}
		if left {
			fr = (^rawptr)(uintptr(fr) + FR_PREV_OFF)^
		} else {
			fr = (^rawptr)(uintptr(fr) + FR_NEXT_OFF)^
		}
	}
	win_comp_pos()
	redraw_all_later_r(UPD_NOT_VALID_O)
}

// ── Batch 41: dir fix + jump-open + scroll-snapshot flag ─────────────────────
// w_localdir@800 (existing W_LOCALDIR_OFF) cc-probed via off44.
MAXPATHL_O :: 4096
KCD_SCOPE_WINDOW_O :: 0
KCD_SCOPE_TABPAGE_O :: 1
KCD_SCOPE_GLOBAL_O :: 2
KCD_CAUSE_WINDOW_O :: 1

@(private="file")
did_initial_scroll_size_snapshot_b41: bool = false

foreign _ {
	@(link_name = "globaldir")
	globaldir_g: rawptr
	@(link_name = "last_chdir_reason")
	last_chdir_reason_g: rawptr
	@(link_name = "pathcmp")
	pathcmp_r :: proc "c" (p: cstring, q: cstring, maxlen: C.int) -> C.int ---
	@(link_name = "do_autocmd_dirchanged")
	do_autocmd_dirchanged_r :: proc "c" (new_dir: cstring, scope: C.int, cause: C.int, pre: bool) ---
}

// Jump to the first open window containing buffer "buf" (NULL if none).
@(export)
buf_jump_open_win :: proc "c"(buf: rawptr) -> rawptr {
	if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf {
		win_enter(curwin, false)
		return curwin
	}
	wp := firstwin // FOR_ALL_WINDOWS_IN_TAB(wp, curtab): curtab nuance
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
			win_enter(wp, false)
			return wp
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return nil
}

// Change to the directory of the current window/tab (unless starting up).
@(export)
win_fix_current_dir :: proc "c"() {
	// New directory is either the local directory of the window, tab or NULL.
	w_localdir := (^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^
	new_dir := w_localdir != nil ? transmute(cstring)(w_localdir) :
		transmute(cstring)((^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^)
	cwd: [MAXPATHL_O]u8
	if os_dirname(transmute(cstring)(&cwd[0]), MAXPATHL_O) != OK {
		cwd[0] = 0
	}
	if new_dir != nil {
		// Window/tab has a local directory: Save current directory as
		// global (unless that was done already) and change to the local one.
		if globaldir_g == nil {
			if cwd[0] != 0 {
				globaldir_g = transmute(rawptr)(xstrdup_o(&cwd[0]))
			}
		}
		dir_differs := pathcmp_r(new_dir, transmute(cstring)(&cwd[0]), -1) != 0
		if p_acd_g == 0 && dir_differs {
			do_autocmd_dirchanged_r(new_dir,
				w_localdir != nil ? KCD_SCOPE_WINDOW_O : KCD_SCOPE_TABPAGE_O,
				KCD_CAUSE_WINDOW_O, true)
		}
		if os_chdir(new_dir) == 0 {
			if p_acd_g == 0 && dir_differs {
				do_autocmd_dirchanged_r(new_dir,
					w_localdir != nil ? KCD_SCOPE_WINDOW_O : KCD_SCOPE_TABPAGE_O,
					KCD_CAUSE_WINDOW_O, false)
			}
		}
		last_chdir_reason_g = nil
		shorten_fnames(true)
	} else if globaldir_g != nil {
		// No local directory and not in the global directory: change back.
		dir_differs := pathcmp_r(transmute(cstring)(globaldir_g),
			transmute(cstring)(&cwd[0]), -1) != 0
		if p_acd_g == 0 && dir_differs {
			do_autocmd_dirchanged_r(transmute(cstring)(globaldir_g),
				KCD_SCOPE_GLOBAL_O, KCD_CAUSE_WINDOW_O, true)
		}
		if os_chdir(transmute(cstring)(globaldir_g)) == 0 {
			if p_acd_g == 0 && dir_differs {
				do_autocmd_dirchanged_r(transmute(cstring)(globaldir_g),
					KCD_SCOPE_GLOBAL_O, KCD_CAUSE_WINDOW_O, false)
			}
		}
		xfree(globaldir_g)
		globaldir_g = nil
		last_chdir_reason_g = nil
		shorten_fnames(true)
	}
}

// Take the initial scroll-size snapshot once (for WinScrolled/WinResized).
@(export)
may_make_initial_scroll_size_snapshot :: proc "c"() {
	if !did_initial_scroll_size_snapshot_b41 {
		did_initial_scroll_size_snapshot_b41 = true
		snapshot_windows_scroll_size()
	}
}

// ── Batch 40: frame restore + split guard + aucmd window ─────────────────────
// aucmdwin_T 16B {auc_win@0}; kvec {size,capacity: size_t, items@16}.

Aucmdwin_T :: struct {
	win:  rawptr,
	used: bool,
	_pad: [7]u8,
}
#assert(size_of(Aucmdwin_T) == 16)

Aucmdwin_Kvec :: struct {
	size:     C.size_t,
	capacity: C.size_t,
	items:    rawptr,
}

WCFG_REL_HIDE :: 470

foreign _ {
	@(link_name = "aucmd_win_vec")
	aucmd_win_vec_g: Aucmdwin_Kvec
	@(link_name = "win_new_float")
	win_new_float_r :: proc "c" (wp: rawptr, last: bool, fconfig: WinConfig_Opaque, err: rawptr) -> rawptr ---
}

// Put "wp"'s frame back where it was (undo of winframe_remove).
@(export)
winframe_restore :: proc "c"(wp: rawptr, dir: C.int, unflat_altfr: rawptr) {
	frp := (^rawptr)(uintptr(wp) + W_FRAME_OFF)^
	// Put "wp"'s frame back where it was.
	if (^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
		frame_append_o((^rawptr)(uintptr(frp) + FR_PREV_OFF)^, frp)
	} else {
		frame_insert_o((^rawptr)(uintptr(frp) + FR_NEXT_OFF)^, frp)
	}
	// Vertical separators to the left may have been lost. Restore them.
	if (^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ == 0 &&
		b_at((^u8)(uintptr((^rawptr)(uintptr(frp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_ROW_O &&
		(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
		frame_set_vsep_o((^rawptr)(uintptr(frp) + FR_PREV_OFF)^, true)
	}
	// Statuslines or horizontal separators above may have been lost.
	if b_at((^u8)(uintptr((^rawptr)(uintptr(frp) + FR_PARENT_OFF)^) + FR_LAYOUT_OFF), 0) == FR_COL_O &&
		(^rawptr)(uintptr(frp) + FR_PREV_OFF)^ != nil {
		if global_stl_height() == 0 && (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ == 0 {
			frame_add_statusline_o((^rawptr)(uintptr(frp) + FR_PREV_OFF)^)
		} else if global_stl_height() > 0 && (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ == 0 {
			frame_add_hsep_o((^rawptr)(uintptr(frp) + FR_PREV_OFF)^)
		}
	}
	// Restore the lost room redistributed to the altframe.
	if dir == 'v' {
		frame_new_height(unflat_altfr,
			(^C.int)(uintptr(unflat_altfr) + FR_HEIGHT_OFF)^ -
			(^C.int)(uintptr(frp) + FR_HEIGHT_OFF)^,
			unflat_altfr == (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^, false, false)
	} else if dir == 'h' {
		frame_new_width(unflat_altfr,
			(^C.int)(uintptr(unflat_altfr) + FR_WIDTH_OFF)^ -
			(^C.int)(uintptr(frp) + FR_WIDTH_OFF)^,
			unflat_altfr == (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^, false)
	}
	// Recompute positions within the parent frame (unchanged if the
	// altframe was adjacent and left/above).
	if unflat_altfr != (^rawptr)(uintptr(frp) + FR_PREV_OFF)^ {
		topleft := frame2win((^rawptr)(uintptr(frp) + FR_PARENT_OFF)^)
		row := (^C.int)(uintptr(topleft) + W_WINROW_OFF)^
		col := (^C.int)(uintptr(topleft) + W_WINCOL_OFF)^
		frame_comp_pos_o((^rawptr)(uintptr(frp) + FR_PARENT_OFF)^, &row, &col)
	}
}

// True when splitting is allowed (false + emsg otherwise).
@(export)
check_split_disallowed :: proc "c"(wp: rawptr) -> C.int {
	err: Api_Error = {typ = -1, msg = nil} // ERROR_INIT
	ok := check_split_disallowed_err(wp, transmute(rawptr)(&err))
	if ERROR_SET(transmute(rawptr)(&err)) {
		emsg(transmute(cstring)(err.msg))
		api_clear_error_r(&err)
	}
	return ok ? OK : FAIL
}

// Allocate the floating window used for autocommands at index "idx".
@(export)
win_alloc_aucmd_win :: proc "c"(idx: C.int) {
	err: Api_Error = {typ = -1, msg = nil} // ERROR_INIT
	fc: WinConfig_Opaque
	win_config_init_assign_o(&fc)
	([^]C.int)(&fc)[4] = Columns // width@16
	([^]C.int)(&fc)[3] = 5 // height@12
	([^]u8)(&fc)[49] = 0 // focusable = false
	([^]u8)(&fc)[50] = 0 // mouse = false
	([^]u8)(&fc)[470] = 1 // hide = true
	auw := &([^]Aucmdwin_T)(aucmd_win_vec_g.items)[idx]
	auw.win = win_new_float_r(nil, true, fc, transmute(rawptr)(&err))
	(^C.int)(uintptr((^rawptr)(uintptr(auw.win) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ -= 1
	(^bool)(uintptr(auw.win) + W_P_SCB_OFF)^ = false // RESET_BINDING
	(^bool)(uintptr(auw.win) + W_P_CRB_OFF)^ = false
}

// ── Batch 37: win_set_buf + merge_win_config ─────────────────────────────────
// WinConfig.title_chunks@400/footer_chunks@440 (Kvec_VT.items@16) cc-probed.

WC_TITLE_ITEMS_OFF :: 416 // W_CONFIG + 400 + 16
WC_FOOTER_ITEMS_OFF :: 456 // W_CONFIG + 440 + 16
WINCONFIG_SIZE_O :: 480

foreign _ {
	@(link_name = "p_acd")
	p_acd_g: C.int
}

// Merge float config "src" into "dst" (freeing replaced virttext).
@(export)
merge_win_config :: proc "c"(dst: rawptr, src: rawptr) {
	if (^rawptr)(uintptr(dst) + WC_TITLE_ITEMS_OFF)^ !=
		(^rawptr)(uintptr(src) + WC_TITLE_ITEMS_OFF)^ {
		clear_virttext_r(transmute(^Kvec_VT)(uintptr(dst) + W_CONFIG_OFF + WC_TITLE_CHUNKS_OFF))
	}
	if (^rawptr)(uintptr(dst) + WC_FOOTER_ITEMS_OFF)^ !=
		(^rawptr)(uintptr(src) + WC_FOOTER_ITEMS_OFF)^ {
		clear_virttext_r(transmute(^Kvec_VT)(uintptr(dst) + W_CONFIG_OFF + WC_FOOTER_CHUNKS_OFF))
	}
	libc.memcpy(dst, src, WINCONFIG_SIZE_O)
}

// Set buffer "buf" in window "win" (API nvim_win_set_buf path).
@(export)
win_set_buf :: proc "c"(win: rawptr, buf: rawptr, err: rawptr) {
	win_handle := (^C.int)(uintptr(win) + W_HANDLE_OFF)^
	tab := win_find_tabpage(win)
	// no redrawing and don't set the window title
	RedrawingDisabled += 1
	switchwin: Switchwin_T
	win_result: C.int = 0
	// TRY_WRAP: wrapped calls don't throw; plain block is exact.
	win_result = switch_win_noblock_r(&switchwin, win, tab, true)
	if win_result != FAIL {
		save_acd := p_acd_g
		if !switchwin.sw_same_win {
			// Temporarily disable 'autochdir' in another window.
			p_acd_g = 0
		}
		do_buffer(DOBUF_GOTO_O, DOBUF_FIRST_O, FORWARD_DIR, (^C.int)(uintptr(buf) + B_FNUM_OFF)^, 0)
		if !switchwin.sw_same_win {
			p_acd_g = save_acd
		}
	}
	if win_result == FAIL && !ERROR_SET(err) {
		msg: [64]u8
		libc.snprintf(&msg[0], size_of(msg), cstring("Failed to switch to window %d"), win_handle)
		api_set_error_r(err, 2, cstring("%s"), transmute(rawptr)(&msg[0]))
	}
	// If window is not current, state logic will not validate its cursor.
	validate_cursor_r(curwin)
	restore_win_noblock_r(&switchwin, true)
	RedrawingDisabled -= 1
}

// ── Batch 38: float-config clear + tabpage maker + scroll snapshot ───────────
// WinConfig: zindex@56/bufpos@4(WCFG_BUFPOS_LNUM=+0)/style@60/_cmdline_offset@472
// (relative); w_last_topline@392/topfill@396/leftcol@400/skipcol@404/width@408/
// height@412 — cc-probed via off42 (focusable/mouse/zindex/bufpos/cmdline-off
// WIN_CONFIG_INIT fields already in B8).

WCFG_STYLE_OFF :: 10620 // W_CONFIG + 60
W_LAST_TOPLINE_OFF :: 392
W_LAST_TOPFILL_OFF :: 396
// WinConfig-relative offsets (for bare WinConfig*, e.g. clear_float_config).
WCFG_REL_BUFPOS_LNUM :: 4
WCFG_REL_FOCUSABLE :: 49
WCFG_REL_MOUSE :: 50
WCFG_REL_ZINDEX :: 56
WCFG_REL_STYLE :: 60
WCFG_REL_CMDLINE_OFF :: 472
W_LAST_LEFTCOL_OFF :: 400
W_LAST_SKIPCOL_OFF :: 404
W_LAST_WIDTH_OFF :: 408
W_LAST_HEIGHT_OFF :: 412

foreign _ {
	@(link_name = "p_tpm")
	p_tpm_g: C.longlong
}

// Fill "fconfig" with WIN_CONFIG_INIT (zeros + 5 nonzero fields, B8).
win_config_init_assign_o :: proc "c"(fconfig: rawptr) {
	libc.memset(fconfig, 0, WINCONFIG_SIZE_O)
	(^bool)(uintptr(fconfig) + WCFG_REL_FOCUSABLE)^ = true
	(^bool)(uintptr(fconfig) + WCFG_REL_MOUSE)^ = true
	(^C.int)(uintptr(fconfig) + WCFG_REL_ZINDEX)^ = KZINDEX_FLOAT_DEFAULT_O
	(^C.int)(uintptr(fconfig) + WCFG_REL_BUFPOS_LNUM)^ = -1
	(^C.int)(uintptr(fconfig) + WCFG_REL_CMDLINE_OFF)^ = INT_MAX_O
}

// Clear float-only fields in "fconfig" (full reset if free_fields).
// NOTE: fconfig is a bare WinConfig* → RELATIVE offsets (style@60,
// _cmdline_offset@472), not the absolute WCFG_*_OFF consts.
@(export)
clear_float_config :: proc "c"(fconfig: rawptr, free_fields: bool) {
	saved_style := (^C.int)(uintptr(fconfig) + WCFG_REL_STYLE)^
	saved_cmdline_offset := (^C.int)(uintptr(fconfig) + WCFG_REL_CMDLINE_OFF)^
	if free_fields {
		init: WinConfig_Opaque // zeroed; fill below
		win_config_init_assign_o(&init)
		merge_win_config(fconfig, transmute(rawptr)(&init))
	} else {
		win_config_init_assign_o(fconfig)
	}
	(^C.int)(uintptr(fconfig) + WCFG_REL_STYLE)^ = saved_style
	(^C.int)(uintptr(fconfig) + WCFG_REL_CMDLINE_OFF)^ = saved_cmdline_offset
}

// Create up to "maxcount" tabpages. Returns actual number made.
@(export)
make_tabpages :: proc "c"(maxcount: C.int) -> C.int {
	count := maxcount
	// Limit to 'tabpagemax' tabs.
	count = min(count, C.int(p_tpm_g))
	// Don't execute autocommands while creating the tab pages. Must do
	// that when putting the buffers in the windows.
	block_autocmds_r()
	todo := count - 1
	for todo > 0 {
		todo -= 1
		if win_new_tabpage(0, nil, true, nil) == nil {
			break
		}
	}
	unblock_autocmds_r()
	// return actual number of tab pages
	return count - todo
}

// Save scroll/size of all windows in current tab (for :mksession restore).
@(export)
snapshot_windows_scroll_size :: proc "c"() {
	wp := firstwin // FOR_ALL_WINDOWS_IN_TAB(wp, curtab): curtab nuance
	for wp != nil {
		(^C.int)(uintptr(wp) + W_LAST_TOPLINE_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		(^C.int)(uintptr(wp) + W_LAST_TOPFILL_OFF)^ = (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		(^C.int)(uintptr(wp) + W_LAST_LEFTCOL_OFF)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
		(^C.int)(uintptr(wp) + W_LAST_SKIPCOL_OFF)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
		(^C.int)(uintptr(wp) + W_LAST_WIDTH_OFF)^ = (^C.int)(uintptr(wp) + W_WIDTH_OFF)^
		(^C.int)(uintptr(wp) + W_LAST_HEIGHT_OFF)^ = (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// ── Batch 39: win_splitmove ──────────────────────────────────────────────────

foreign _ {
	@(link_name = "winframe_restore")
	winframe_restore_r :: proc "c" (wp: rawptr, dir: C.int, unflat_altfr: rawptr) ---
}

// Move "wp" into a new split in a given direction (CTRL-W H/J/K/L).
@(export)
win_splitmove :: proc "c"(wp: rawptr, size: C.int, flags: C.int) -> C.int {
	dir: C.int = 0
	height := (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
	if one_window(wp, nil) {
		return OK // nothing to do
	}
	if is_aucmd_win_r(wp) || check_split_disallowed(wp) == FAIL {
		return FAIL
	}
	unflat_altfr: rawptr = nil
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		win_remove(wp, nil)
	} else {
		// Remove the window and frame from the tree of frames. Don't
		// flatten any frames yet so we can restore things if win_split_ins
		// fails.
		winframe_remove(wp, &dir, nil, &unflat_altfr)
		win_remove(wp, nil)
		last_status(false) // may need to remove last status line
		win_comp_pos() // recompute window positions
	}
	// Split a window on the desired side and put "wp" there.
	if win_split_ins(size, flags, wp, dir, unflat_altfr) == nil {
		if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
			// win_split_ins doesn't change sizes or layout if it fails to
			// insert an existing window, so just undo winframe_remove.
			winframe_restore_r(wp, dir, unflat_altfr)
		}
		win_append((^rawptr)(uintptr(wp) + W_PREV_OFF)^, wp, nil)
		return FAIL
	}
	// If splitting horizontally, try to preserve height.
	// Note that win_split_ins autocommands may have immediately closed
	// "wp", or made it floating!
	if size == 0 && (flags & WSP_VERT_O) == 0 && win_valid(wp) &&
		!(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		win_setheight_win(height, wp, true)
		if p_ea_g != 0 {
			// Equalize windows. Note that win_split_ins autocommands may
			// have made a window other than "wp" current.
			win_equal(curwin, curwin == wp, 'v')
		}
	}
	return OK
}

// ── Batch 43a: do_window helpers (dormant; dispatcher ports next) ────────────

E5602_S :: "E5602: Cannot exchange or rotate float"
E443_S :: "E443: Cannot rotate when another window is split"

// Build ":cmd [count]" string (C static: no export/weak).
cmd_with_count_o :: proc "c"(cmd: cstring, bufp: rawptr, bufsize: C.size_t, prenum: C.longlong) {
	length := xstrlcpy(transmute(cstring)(bufp), cmd, bufsize)
	if prenum > 0 && C.size_t(length) < bufsize {
		libc.snprintf(transmute([^]u8)(uintptr(bufp) + uintptr(length)),
			bufsize - C.size_t(length), cstring("%ld"), prenum)
	}
}

// Exchange current and next window (C static: no export/weak).
win_exchange_o :: proc "c"(prenum_in: C.int) {
	prenum := prenum_in
	if (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
		emsg(cstring(E5602_S))
		return
	}
	if one_window(curwin, nil) {
		// just one window
		beep_flush_r()
		return
	}
	if text_or_buf_locked_r() {
		beep_flush_r()
		return
	}
	frp: rawptr
	// find window to exchange with
	if prenum != 0 {
		frp = (^rawptr)(uintptr((^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^) + FR_CHILD_OFF)^
		for frp != nil && prenum - 1 > 0 {
			prenum -= 1
			frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
		}
	} else if (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_NEXT_OFF)^ != nil {
		frp = (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_NEXT_OFF)^
	} else { // Swap last window in row/col with previous
		frp = (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PREV_OFF)^
	}
	// We can only exchange a window with another window, not with a frame
	// containing windows.
	if frp == nil || (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ == nil ||
		(^rawptr)(uintptr(frp) + FR_WIN_OFF)^ == curwin {
		return
	}
	wp := (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
	// 1. remove curwin from the list. Remember after which window it was.
	// 2. insert curwin before wp in the list; if wp != wp2:
	// 3. remove wp, 4. insert wp after wp2.
	// 5. exchange heights/separators.
	wp2 := (^rawptr)(uintptr(curwin) + W_PREV_OFF)^
	frp2 := (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PREV_OFF)^
	if (^rawptr)(uintptr(wp) + W_PREV_OFF)^ != curwin {
		win_remove(curwin, nil)
		frame_remove_o((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^)
		win_append((^rawptr)(uintptr(wp) + W_PREV_OFF)^, curwin, nil)
		frame_insert_o(frp, (^rawptr)(uintptr(curwin) + W_FRAME_OFF)^)
	}
	if wp != wp2 {
		win_remove(wp, nil)
		frame_remove_o((^rawptr)(uintptr(wp) + W_FRAME_OFF)^)
		win_append(wp2, wp, nil)
		if frp2 == nil {
			parent := (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_FRAME_OFF)^) + FR_PARENT_OFF)^
			frame_insert_o((^rawptr)(uintptr(parent) + FR_CHILD_OFF)^,
				(^rawptr)(uintptr(wp) + W_FRAME_OFF)^)
		} else {
			frame_append_o(frp2, (^rawptr)(uintptr(wp) + W_FRAME_OFF)^)
		}
	}
	temp := (^C.int)(uintptr(curwin) + W_STATUS_HEIGHT_OFF)^
	(^C.int)(uintptr(curwin) + W_STATUS_HEIGHT_OFF)^ =
		(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^
	(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ = temp
	temp = (^C.int)(uintptr(curwin) + W_VSEP_WIDTH_OFF)^
	(^C.int)(uintptr(curwin) + W_VSEP_WIDTH_OFF)^ =
		(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^
	(^C.int)(uintptr(wp) + W_VSEP_WIDTH_OFF)^ = temp
	temp = (^C.int)(uintptr(curwin) + W_HSEP_HEIGHT_OFF)^
	(^C.int)(uintptr(curwin) + W_HSEP_HEIGHT_OFF)^ =
		(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^
	(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ = temp
	frame_fix_height_o(curwin)
	frame_fix_height_o(wp)
	frame_fix_width_o(curwin)
	frame_fix_width_o(wp)
	win_comp_pos() // recompute window positions
	if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
		reset_VIsual_and_resel_r()
	} else if VIsual_active {
		libc.memcpy(transmute(rawptr)(uintptr(wp) + W_CURSOR_OFF),
			transmute(rawptr)(uintptr(curwin) + W_CURSOR_OFF), 12)
	}
	win_enter(wp, true)
	redraw_later(curwin, UPD_NOT_VALID_O)
	redraw_later(wp, UPD_NOT_VALID_O)
}

// Rotate windows up/down (C static: no export/weak).
win_rotate_o :: proc "c"(upwards: bool, count_in: C.int) {
	count := count_in
	if (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
		emsg(cstring(E5602_S))
		return
	}
	if count <= 0 || one_window(curwin, nil) {
		// nothing to do
		beep_flush_r()
		return
	}
	// Check if all frames in this row/col have one window.
	frp := (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^
	frp = (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
	for frp != nil {
		if (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ == nil {
			emsg(cstring(E443_S))
			return
		}
		frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
	}
	wp1: rawptr
	wp2: rawptr
	for count > 0 {
		count -= 1
		if upwards { // first window becomes last window
			// remove first window/frame from the list
			frp = (^rawptr)(uintptr((^rawptr)(uintptr(curwin) + W_FRAME_OFF)^) + FR_PARENT_OFF)^
			frp = (^rawptr)(uintptr(frp) + FR_CHILD_OFF)^
			wp1 = (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
			win_remove(wp1, nil)
			frame_remove_o(frp)
			// find last frame and append removed window/frame after it
			for (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			win_append((^rawptr)(uintptr(frp) + FR_WIN_OFF)^, wp1, nil)
			frame_append_o(frp, (^rawptr)(uintptr(wp1) + W_FRAME_OFF)^)
			wp2 = (^rawptr)(uintptr(frp) + FR_WIN_OFF)^ // previously last window
		} else { // last window becomes first window
			// find last window/frame in the list and remove it
			frp = (^rawptr)(uintptr(curwin) + W_FRAME_OFF)^
			for (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^ != nil {
				frp = (^rawptr)(uintptr(frp) + FR_NEXT_OFF)^
			}
			wp1 = (^rawptr)(uintptr(frp) + FR_WIN_OFF)^
			wp2 = (^rawptr)(uintptr(wp1) + W_PREV_OFF)^ // will become last window
			win_remove(wp1, nil)
			frame_remove_o(frp)
			// append the removed window/frame before the first in the list
			parent := (^rawptr)(uintptr(frp) + FR_PARENT_OFF)^
			first_child := (^rawptr)(uintptr(parent) + FR_CHILD_OFF)^
			win_append((^rawptr)(uintptr((^rawptr)(uintptr(first_child) + FR_WIN_OFF)^) + W_PREV_OFF)^, wp1, nil)
			frame_insert_o(first_child, frp)
		}
		// exchange status/winbar/hsep heights and vsep width of old/new last
		n := (^C.int)(uintptr(wp2) + W_STATUS_HEIGHT_OFF)^
		(^C.int)(uintptr(wp2) + W_STATUS_HEIGHT_OFF)^ = (^C.int)(uintptr(wp1) + W_STATUS_HEIGHT_OFF)^
		(^C.int)(uintptr(wp1) + W_STATUS_HEIGHT_OFF)^ = n
		n = (^C.int)(uintptr(wp2) + W_HSEP_HEIGHT_OFF)^
		(^C.int)(uintptr(wp2) + W_HSEP_HEIGHT_OFF)^ = (^C.int)(uintptr(wp1) + W_HSEP_HEIGHT_OFF)^
		(^C.int)(uintptr(wp1) + W_HSEP_HEIGHT_OFF)^ = n
		frame_fix_height_o(wp1)
		frame_fix_height_o(wp2)
		n = (^C.int)(uintptr(wp2) + W_VSEP_WIDTH_OFF)^
		(^C.int)(uintptr(wp2) + W_VSEP_WIDTH_OFF)^ = (^C.int)(uintptr(wp1) + W_VSEP_WIDTH_OFF)^
		(^C.int)(uintptr(wp1) + W_VSEP_WIDTH_OFF)^ = n
		frame_fix_width_o(wp1)
		frame_fix_width_o(wp2)
		// recompute w_winrow and w_wincol for all windows
		win_comp_pos()
	}
	(^bool)(uintptr(wp1) + W_POS_CHANGED_OFF)^ = true
	(^bool)(uintptr(wp2) + W_POS_CHANGED_OFF)^ = true
	redraw_all_later_r(UPD_NOT_VALID_O)
}

// ── Batch 44: do_window dispatcher ───────────────────────────────────────────
// Key codes: Ctrl_* are control chars; K_* probed via offkeys
// (DOWN -25707/UP -30059/LEFT -27755/RIGHT -29291/BS -25195/KENTER -16715/
// TAB -14077).

Ctrl_S_O :: 19
Ctrl_Q_O :: 17
Ctrl_Z_O :: 26
Ctrl_O_O :: 15
Ctrl_N_O :: 14
Ctrl_HAT_O :: 30
Ctrl_J_O :: 10
Ctrl_K_O :: 11
Ctrl_T_O :: 20
Ctrl_B_O :: 2
Ctrl_X_O :: 24
Ctrl_I_O :: 9
Ctrl_D_O :: 4
Ctrl_G_O :: 7
Ctrl__O :: 31
Ctrl_RSB_O :: 29
K_DOWN_O :: -25707
K_UP_O :: -30059
K_LEFT_O :: -27755
K_RIGHT_O :: -29291
K_KENTER_O :: -16715
K_TAB_O :: -14077
TAB_O :: 9
CAR_O :: 13
FIND_DEFINE_O :: 2
FIND_ANY_O :: 1
ACTION_SPLIT_O :: 3
ECMD_LASTL_O :: 0
ECMD_HIDE_O :: 0x01
KOPT_SWB_USEOPEN_O :: 0x01
KOPT_SWB_USETAB_O :: 0x02
E441_S :: "E441: There is no preview window"

foreign _ {
	@(link_name = "curbuf_locked")
	curbuf_locked_r :: proc "c" () -> bool ---
	@(link_name = "postponed_split")
	postponed_split_g: C.int
	@(link_name = "p_pvh")
	p_pvh_g: C.longlong
	@(link_name = "do_nv_ident")
	do_nv_ident_r :: proc "c" (c1: C.int, c2: C.int) ---
	@(link_name = "check_text_or_curbuf_locked")
	check_text_or_curbuf_locked_r :: proc "c" (oap: rawptr) -> bool ---
	@(link_name = "grab_file_name")
	grab_file_name_r :: proc "c" (count: C.int, file_lnum: ^C.int) -> ^u8 ---
	@(link_name = "qf_view_result")
	qf_view_result_r :: proc "c" (split: bool) ---
	@(link_name = "p_langmap")
	p_langmap_g: ^u8
	@(link_name = "p_lrm")
	p_lrm_g: C.int
	@(link_name = "vgetc_busy")
	vgetc_busy_g: C.int
	@(link_name = "typebuf_maplen")
	typebuf_maplen_r :: proc "c" () -> C.int ---
	@(link_name = "langmap_mapchar")
	langmap_mapchar_g: [256]u8
	@(link_name = "langmap_adjust_mb")
	langmap_adjust_mb_r :: proc "c" (c: C.int) -> C.int ---
	@(link_name = "find_pattern_in_path")
	find_pattern_in_path_r :: proc "c" (ptr: ^u8, dir: C.int, len: C.size_t, whole: bool, skip_comments: bool, type: C.int, count: C.int, action: C.int, start_lnum: C.int, end_lnum: C.int, forceit: bool, silent: bool) ---
}

// "gf" body shared by CTRL-W f/F and CTRL-W gf/gF (C: wingotofile label).
wingotofile_o :: proc "c"(nchar: C.int, prenum: C.int, prenum1: C.int) {
	if check_text_or_curbuf_locked_r(nil) {
		return
	}
	lnum: C.int = -1
	ptr := grab_file_name_r(prenum1, &lnum)
	if ptr != nil {
		oldtab := curtab
		oldwin := curwin
		setpcmark()
		// If 'switchbuf' is set to 'useopen'/'usetab' and the file is
		// already opened in a window, then jump to it.
		wp: rawptr = nil
		if (swb_flags_g & (KOPT_SWB_USEOPEN_O | KOPT_SWB_USETAB_O)) != 0 &&
			(^C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_TAB_OFF)^ == 0 {
			wp = swbuf_goto_win_with_buf_r(buflist_findname_exp(transmute(cstring)(ptr)))
		}
		if wp == nil && win_split(0, 0) == OK {
			(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false // RESET_BINDING
			(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
			if do_ecmd_r(0, transmute(cstring)(ptr), nil, nil, ECMD_LASTL_O, ECMD_HIDE_O, nil) == FAIL {
				// Failed to open the file, close the window opened for
				// it. Save/restore got_int around win_close (which fails
				// unconditionally when got_int is set).
				old_got_int := got_int
				got_int = false
				win_close(curwin, false, false)
				got_int = got_int || old_got_int
				goto_tabpage_win(oldtab, oldwin)
			} else {
				wp = curwin
			}
		}
		if wp != nil && nchar == 'F' && lnum >= 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
			check_cursor_lnum_r(curwin)
			beginline(BL_SOL | BL_FIX)
		}
		xfree(transmute(rawptr)(ptr))
	}
}

// All CTRL-W window commands, called from normal_cmd().
@(export)
do_window :: proc "c"(nchar: C.int, prenum_in: C.int, xchar_in: C.int) {
	prenum := prenum_in
	xchar := xchar_in
	type: C.int = FIND_DEFINE_O
	cbuf: [40]u8
	prenum1 := prenum == 0 ? 1 : prenum
	switch nchar {
	// split current window in two parts, horizontally
	case 'S', Ctrl_S_O, 's':
		reset_VIsual_and_resel_r() // stop Visual mode
		// When splitting the quickfix window open a new buffer in it,
		// don't replicate the quickfix buffer (C: goto newwindow).
		if bt_quickfix(curbuf) {
			do_window_newwindow(nchar, prenum)
		} else {
			win_split(prenum, 0)
		}
	// split current window in two parts, vertically
	case Ctrl_V, 'v':
		reset_VIsual_and_resel_r() // stop Visual mode
		if bt_quickfix(curbuf) {
			do_window_newwindow(nchar, prenum)
		} else {
			win_split(prenum, WSP_VERT_O)
		}
	// split current window and edit alternate file
	case Ctrl_HAT_O, '^':
		reset_VIsual_and_resel_r() // stop Visual mode
		alt := prenum == 0 ? (^C.int)(uintptr(curwin) + W_ALT_FNUM)^ : prenum
		if buflist_findnr(alt) == nil {
			if prenum == 0 {
				emsg(cstring(E_NOALT_S))
			} else {
				semsg_int_o(cstring(E_BUFNOTFOUND_S), prenum)
			}
			break
		}
		if !curbuf_locked_r() && win_split(0, 0) == OK {
			buflist_getfile(alt, 0, GETF_ALT_O, 0)
		}
	// open new window (C: newwindow label)
	case Ctrl_N_O, 'n':
		reset_VIsual_and_resel_r() // stop Visual mode
		do_window_newwindow(nchar, prenum)
	// quit current window
	case Ctrl_Q_O, 'q':
		reset_VIsual_and_resel_r() // stop Visual mode
		cmd_with_count_o(cstring("quit"), &cbuf[0], size_of(cbuf), C.longlong(prenum))
		do_cmdline_cmd_r(transmute(cstring)(&cbuf[0]))
	// close current window
	case Ctrl_C, 'c':
		reset_VIsual_and_resel_r() // stop Visual mode
		cmd_with_count_o(cstring("close"), &cbuf[0], size_of(cbuf), C.longlong(prenum))
		do_cmdline_cmd_r(transmute(cstring)(&cbuf[0]))
	// close preview window
	case Ctrl_Z_O, 'z':
		reset_VIsual_and_resel_r() // stop Visual mode
		do_cmdline_cmd_r(cstring("pclose"))
	// cursor to preview window
	case 'P':
		wp: rawptr = nil
		walk := firstwin // FOR_ALL_WINDOWS_IN_TAB(wp2, curtab)
		for walk != nil {
			if (^C.int)(uintptr(walk) + W_P_PVW_OFF)^ != 0 {
				wp = walk
				break
			}
			walk = (^rawptr)(uintptr(walk) + W_NEXT_OFF)^
		}
		if wp == nil {
			emsg(cstring(E441_S))
		} else {
			win_goto(wp)
		}
	// close all but current window
	case Ctrl_O_O, 'o':
		reset_VIsual_and_resel_r() // stop Visual mode
		cmd_with_count_o(cstring("only"), &cbuf[0], size_of(cbuf), C.longlong(prenum))
		do_cmdline_cmd_r(transmute(cstring)(&cbuf[0]))
	// cursor to next/previous window with wrap around
	case Ctrl_W, 'w', 'W':
		if firstwin == lastwin_g && prenum != 1 { // just one window
			beep_flush_r()
		} else {
			wp: rawptr
			if prenum != 0 { // go to specified window
				last_focusable := firstwin
				wp = firstwin
				pn := prenum
				for wp != nil && pn - 1 > 0 {
					if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ ||
						(!(^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ &&
							(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^) {
						last_focusable = wp
					}
					if (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ == nil {
						break
					}
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
					pn -= 1
				}
				for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
					((^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ ||
						!(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^) {
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				}
				if wp == nil { // went past the last focusable window
					wp = last_focusable
				}
			} else {
				if nchar == 'W' { // go to previous window
					wp = (^rawptr)(uintptr(curwin) + W_PREV_OFF)^
					if wp == nil {
						wp = lastwin_g // wrap around
					}
					for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
						((^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ ||
							!(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^) {
						wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
					}
				} else { // go to next window
					wp = (^rawptr)(uintptr(curwin) + W_NEXT_OFF)^
					for wp != nil && (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
						((^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ ||
							!(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^) {
						wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
					}
					if wp == nil {
						wp = firstwin // wrap around
					}
				}
			}
			win_goto(wp)
		}
	// cursor to window below/above/left/right
	case 'j', K_DOWN_O, Ctrl_J_O, 'k', K_UP_O, Ctrl_K_O,
		'h', K_LEFT_O, Ctrl_H, K_BS, 'l', K_RIGHT_O, Ctrl_L:
		if nchar == 'j' || nchar == K_DOWN_O || nchar == Ctrl_J_O {
			win_goto_ver_o(false, prenum1)
		} else if nchar == 'k' || nchar == K_UP_O || nchar == Ctrl_K_O {
			win_goto_ver_o(true, prenum1)
		} else if nchar == 'h' || nchar == K_LEFT_O || nchar == Ctrl_H || nchar == K_BS {
			win_goto_hor_o(true, prenum1)
		} else {
			win_goto_hor_o(false, prenum1)
		}
	// move window to new tab page
	case 'T':
		if one_window(curwin, nil) {
			msg_r(cstring(M_ONLYONE_S), 0)
		} else {
			oldtab := curtab
			// First create a new tab with the window, then go back to
			// the old tab and close the window there.
			wp := curwin
			if win_new_tabpage(prenum, nil, true, nil) != nil && valid_tabpage(oldtab) {
				newtab := curtab
				goto_tabpage_tp(oldtab, true, true)
				if curwin == wp {
					win_close(curwin, false, false)
				}
				if valid_tabpage(newtab) {
					goto_tabpage_tp(newtab, true, true)
					apply_autocmds(EVENT_TABNEWENTERED_O, nil, nil, false, curbuf)
				}
			}
		}
	// cursor to top-left / bottom-right / last-accessed window
	case 't', Ctrl_T_O:
		win_goto(firstwin)
	case 'b', Ctrl_B_O:
		win_goto(lastwin_nofloating(nil))
	case 'p', Ctrl_P:
		if !win_valid(prevwin_g) || (^bool)(uintptr(prevwin_g) + WCFG_HIDE_OFF)^ ||
			!(^bool)(uintptr(prevwin_g) + WCFG_FOCUSABLE_OFF)^ {
			beep_flush_r()
		} else {
			win_goto(prevwin_g)
		}
	// exchange current and next window
	case 'x', Ctrl_X_O:
		win_exchange_o(prenum)
	// rotate windows downwards/upwards
	case Ctrl_R, 'r':
		reset_VIsual_and_resel_r() // stop Visual mode
		win_rotate_o(false, prenum1) // downwards
	case 'R':
		reset_VIsual_and_resel_r() // stop Visual mode
		win_rotate_o(true, prenum1) // upwards
	// move window to the very top/bottom/left/right
	case 'K', 'J', 'H', 'L':
		if one_window(curwin, nil) {
			beep_flush_r()
		} else {
			dir: C.int = ((nchar == 'H' || nchar == 'L') ? WSP_VERT_O : 0) |
				((nchar == 'H' || nchar == 'K') ? WSP_TOP_O : WSP_BOT_O)

			win_splitmove(curwin, prenum, dir)
		}
	// make all windows the same width and/or height
	case '=':
		mod := (^C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_SPLIT_OFF)^ &
			(WSP_VERT_O | WSP_HOR_O)
		win_equal(nil, false, mod == WSP_VERT_O ? 'v' : mod == WSP_HOR_O ? 'h' : 'b')
	// increase/decrease/set height/width
	case '+':
		win_setheight((^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ + prenum1)
	case '-':
		win_setheight((^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ - prenum1)
	case Ctrl__O, '_':
		win_setheight(prenum != 0 ? prenum : Rows - C.int(nvim_odin_get_min_set_ch_r()))
	case '>':
		win_setwidth((^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ + prenum1)
	case '<':
		win_setwidth((^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ - prenum1)
	case '|':
		win_setwidth(prenum != 0 ? prenum : Columns)
	// jump to tag in preview window / split
	case '}':
		if prenum != 0 {
			g_do_tagpreview = prenum
		} else {
			g_do_tagpreview = C.int(p_pvh_g)
		}
		fallthrough
	case ']', Ctrl_RSB_O:
		// Keep visual mode, can select words to use as a tag.
		if prenum != 0 {
			postponed_split_g = prenum
		} else {
			postponed_split_g = -1
		}
		if nchar != '}' {
			g_do_tagpreview = 0
		}
		// Execute the command right here, required when
		// "wincmd ]" was used in a function.
		do_nv_ident_r(Ctrl_RSB_O, 0)
		postponed_split_g = 0
	// edit file name under cursor in a new window
	case 'f', 'F', Ctrl_F:
		wingotofile_o(nchar, prenum, prenum1)
	// identifier search in a new window
	case 'i', Ctrl_I_O:
		type = FIND_ANY_O
		fallthrough
	case 'd', Ctrl_D_O:
		ptr: ^u8
		length := find_ident_under_cursor_r(&ptr, FIND_IDENT, nil)
		if length == 0 {
			break
		}
		// Make a copy, if the line was changed it will be freed.
		ptr = xmemdupz_o2(ptr, length)
		find_pattern_in_path_r(ptr, 0, length, true, prenum == 0, type,
			prenum1, ACTION_SPLIT_O, 1, MAXLNUM, false, false)
		xfree(transmute(rawptr)(ptr))
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	// Quickfix window only: view result in a new split
	case K_KENTER_O, CAR_O:
		if bt_quickfix(curbuf) {
			qf_view_result_r(true)
		}
	// CTRL-W g extended commands
	case 'g', Ctrl_G_O:
		no_mapping += 1
		allow_keys += 1 // no mapping for xchar, but allow key codes
		if xchar == 0 {
			xchar = plain_vgetc()
		}
		// LANGMAP_ADJUST(xchar, true), expanded (mapping.h).
		if p_langmap_g != nil && b_at(p_langmap_g, 0) != 0 &&
			(p_lrm_g != 0 || (vgetc_busy_g != 0 ?
				typebuf_maplen_r() == 0 : KeyTyped)) &&
			!KeyStuffed && xchar >= 0 {
			if xchar < 256 {
				xchar = C.int(langmap_mapchar_g[u8(xchar)])
			} else {
				xchar = langmap_adjust_mb_r(xchar)
			}
		}
		no_mapping -= 1
		allow_keys -= 1
		add_to_showcmd(xchar)
		switch xchar {
		case '}':
			xchar = Ctrl_RSB_O
			if prenum != 0 {
				g_do_tagpreview = prenum
			} else {
				g_do_tagpreview = C.int(p_pvh_g)
			}
			fallthrough
		case ']', Ctrl_RSB_O:
			// Keep visual mode, can select words to use as a tag.
			if prenum != 0 {
				postponed_split_g = prenum
			} else {
				postponed_split_g = -1
			}
			// Execute the command right here, required when
			// "wincmd g}" was used in a function.
			do_nv_ident_r('g', xchar)
			postponed_split_g = 0
		case 'f', 'F': // CTRL-W gf: "gf" in a new tab page
			(^C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_TAB_OFF)^ =
				tabpage_index(curtab) + 1
			wingotofile_o(xchar, prenum, prenum1)
		case 't': // CTRL-W gt: go to next tab page
			goto_tabpage(0)
		case 'T': // CTRL-W gT: go to previous tab page
			goto_tabpage(-prenum1)
		case TAB_O: // CTRL-W g<Tab>: go to last used tab page
			if !goto_tabpage_lastused() {
				beep_flush_r()
			}
		case 'e':
			if (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ || !ui_has(K_UIMULTIGRID_O) {
				beep_flush_r()
				break
			}
			fc: WinConfig_Opaque
			win_config_init_assign_o(&fc)
			([^]C.int)(&fc)[4] = (^C.int)(uintptr(curwin) + W_WIDTH_OFF)^
			([^]C.int)(&fc)[3] = (^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^
			([^]u8)(&fc)[48] = 1 // external = true
			err: Api_Error = {typ = -1, msg = nil}
			if win_new_float_r(curwin, false, fc, transmute(rawptr)(&err)) == nil {
				emsg(transmute(cstring)(err.msg))
				api_clear_error_r(&err)
				beep_flush_r()
			}
		case:
			beep_flush_r()
		}
	case:
		beep_flush_r()
	}
}

// ":new [height]" body shared by CTRL-W s/v/n (C: newwindow label).
do_window_newwindow :: proc "c"(nchar: C.int, prenum: C.int) {
	cbuf: [40]u8
	if prenum != 0 {
		// window height
		libc.snprintf(&cbuf[0], size_of(cbuf) - 5, cstring("%ld"), C.longlong(prenum))
	} else {
		cbuf[0] = 0
	}
	if nchar == 'v' || nchar == Ctrl_V {
		xstrlcat(&cbuf[0], transmute(^u8)(cstring("v")), size_of(cbuf))
	}
	xstrlcat(&cbuf[0], transmute(^u8)(cstring("new")), size_of(cbuf))
	do_cmdline_cmd_r(transmute(cstring)(&cbuf[0]))
}

// ── Batch 45: viewport + ui flush ────────────────────────────────────────────
// w_viewport_invalid@564/last_topline@568 (+botline/topfill/skipcol below) and
// grid.pending_comp_index_update@89/chars@8 cc-probed via off46 (matching the
// pre-existing B8 consts above).

W_VIEWPORT_LAST_BOTLINE_OFF :: 572
W_VIEWPORT_LAST_TOPFILL_OFF :: 576
W_VIEWPORT_LAST_SKIPCOL_OFF :: 580
W_REDR_TYPE_OFF :: 692
W_EMPTY_ROWS_OFF :: 616
GRID_PENDING_COMP_OFF :: 89
GRID_CHARS_OFF :: 8

foreign _ {
	@(link_name = "win_text_height")
	win_text_height_r :: proc "c" (wp: rawptr, start_lnum: C.int, start_vcol: C.longlong, end_lnum: ^C.int, end_vcol: ^C.longlong, fill: rawptr, max: C.longlong) -> C.longlong ---
 	@(link_name = "ui_call_win_viewport")
 	ui_call_win_viewport_r :: proc "c" (grid: C.longlong, win: C.int, topline: C.longlong, botline: C.longlong, curline: C.longlong, curcol: C.longlong, line_count: C.longlong, scroll_delta: C.longlong) ---
 	@(link_name = "pum_ui_flush")
	pum_ui_flush_r :: proc "c" () ---
	@(link_name = "msg_ui_flush")
	msg_ui_flush_r :: proc "c" () ---
}

@(export)
ui_ext_win_viewport :: proc "c"(wp: rawptr) {
	// NOTE: win_viewport is delayed until next flush when updates pending.
	do_viewport := wp == curwin || ui_has(K_UIMULTIGRID_O)
	if do_viewport && (^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ &&
		(^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ == 0 {
		line_count := (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^
		// Avoid ml_get errors when producing "scroll_delta".
		cur_topline := min((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, line_count)
		cur_botline := min((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^, line_count)
		delta: C.longlong = 0
		last_topline := (^C.int)(uintptr(wp) + W_VIEWPORT_LAST_TOPLINE_OFF)^
		last_botline := (^C.int)(uintptr(wp) + W_VIEWPORT_LAST_BOTLINE_OFF)^
		last_topfill := (^C.int)(uintptr(wp) + W_VIEWPORT_LAST_TOPFILL_OFF)^
		last_skipcol := (^C.longlong)(uintptr(wp) + W_VIEWPORT_LAST_SKIPCOL_OFF)^
		if last_topline > line_count {
			delta -= C.longlong(last_topline - line_count)
			last_topline = line_count
			last_topfill = 0
			last_skipcol = MAXCOL
		}
		last_botline = min(last_botline, line_count)
		if cur_topline < last_topline ||
			(cur_topline == last_topline &&
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ < C.int(last_skipcol)) {
			vcole := last_skipcol
			lnume := last_topline
			if last_topline > 0 && cur_botline < last_topline {
				// Scrolling too many lines: only approximate "scroll_delta".
				delta -= C.longlong(last_topline - cur_botline)
				lnume = cur_botline
				vcole = 0
			}
			delta -= win_text_height_r(wp, cur_topline,
				C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^), &lnume, &vcole, nil, 0x7fffffffffffffff)
		} else if cur_topline > last_topline ||
			(cur_topline == last_topline &&
				(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > C.int(last_skipcol)) {
			vcole := (^C.longlong)(uintptr(wp) + W_SKIPCOL_OFF)^
			lnume := cur_topline
			if last_botline > 0 && cur_topline > last_botline {
				// Scrolling too many lines: only approximate "scroll_delta".
				delta += C.longlong(cur_topline - last_botline)
				lnume = last_botline
				vcole = 0
			}
			delta += win_text_height_r(wp, last_topline, last_skipcol, &lnume, &vcole, nil, 0x7fffffffffffffff)
		}
		delta += C.longlong(last_topfill)
		delta -= C.longlong((^C.int)(uintptr(wp) + W_TOPFILL_OFF)^)
		ev_botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
		if ev_botline == line_count + 1 && (^C.int)(uintptr(wp) + W_EMPTY_ROWS_OFF)^ == 0 {
			ev_botline = line_count
		}
		ui_call_win_viewport_r(
			C.longlong((^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^),
			(^C.int)(uintptr(wp) + W_HANDLE_OFF)^,
			C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 1),
			C.longlong(ev_botline),
			C.longlong((^C.int)(uintptr(wp) + W_CURSOR_OFF)^ - 1),
			C.longlong((^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^),
			C.longlong(line_count), delta)
		(^bool)(uintptr(wp) + W_VIEWPORT_INVALID_OFF)^ = false
		(^C.int)(uintptr(wp) + W_VIEWPORT_LAST_TOPLINE_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
		(^C.int)(uintptr(wp) + W_VIEWPORT_LAST_BOTLINE_OFF)^ = (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
		(^C.int)(uintptr(wp) + W_VIEWPORT_LAST_TOPFILL_OFF)^ = (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		(^C.longlong)(uintptr(wp) + W_VIEWPORT_LAST_SKIPCOL_OFF)^ = C.longlong((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^)
	}
}

@(export)
win_ui_flush :: proc "c"(validate: bool) {
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			grid := uintptr(wp) + W_GRID_ALLOC_OFF
			if ((^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ ||
				(^bool)(grid + GRID_PENDING_COMP_OFF)^) &&
				(^rawptr)(grid + GRID_CHARS_OFF)^ != nil {
				if tp == curtab {
					ui_ext_win_position(wp, validate)
				} else {
					ui_call_win_hide_r((^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^)
					(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = false
				}
				(^bool)(grid + GRID_PENDING_COMP_OFF)^ = false
			}
			if tp == curtab {
				ui_ext_win_viewport(wp)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	// The popupmenu could also have moved or changed its comp_index
	pum_ui_flush_r()
	// And the message
	msg_ui_flush_r()
}

// ── Batch 46: ui_ext_win_position ────────────────────────────────────────────
// ScreenGrid: handle@0/chars@8(float-grid ptr)/valid@56/mouse@59/zindex@60/
// comp_row@64/comp_col@68/comp_index@80; WinConfig: window@0/bufpos@4{lnum,col}/
// row@24(f64)/col@32(f64)/anchor@40/relative@44/external@48/mouse@50/
// zindex@56/fixed@469/hide@470; w_grid@10440 — cc-probed via off47/off48.

W_GRID_OFF :: 10440
GRID_HANDLE_OFF2 :: 0
GRID_VALID_OFF :: 56
GRID_MOUSE_OFF2 :: 59
GRID_ZINDEX_OFF :: 60
GRID_COMP_ROW_OFF :: 64
GRID_COMP_COL_OFF :: 68
GRID_COMP_INDEX_OFF :: 80
WCFG_WINDOW_OFF :: 0
WCFG_BUFPOS_COL_OFF :: 8
WCFG_ROW_OFF :: 24
WCFG_COL_OFF :: 32
WCFG_ANCHOR_OFF :: 40
WCFG_FIXED_OFF :: 469
WCFG_MOUSE_OFF2 :: 50
WCFG_ZINDEX_OFF2 :: 56
KFLOAT_REL_TABLINE_O :: 4
KFLOAT_REL_LASTSTATUS_O :: 5
KFLOAT_ANCHOR_EAST_O :: 1
KFLOAT_ANCHOR_SOUTH_O :: 2
KZINDEX_MESSAGES_O :: 200

foreign _ {
	@(link_name = "find_window_by_handle")
	find_window_by_handle_r :: proc "c" (window: C.int, err: rawptr) -> rawptr ---
	@(link_name = "grid_adjust")
	grid_adjust_r :: proc "c" (grid: rawptr, row_off: ^C.int, col_off: ^C.int) -> rawptr ---
	@(link_name = "textpos2screenpos")
	textpos2screenpos_r :: proc "c" (wp: rawptr, pos: ^Pos_T, rowp: ^C.int, scolp: ^C.int, ccolp: ^C.int, ecolp: ^C.int, local: bool) ---
	@(link_name = "ui_comp_layers_adjust")
	ui_comp_layers_adjust_r :: proc "c" (layer_idx: C.size_t, raise: bool) ---
	@(link_name = "ui_comp_put_grid")
	ui_comp_put_grid_r :: proc "c" (grid: rawptr, row: C.int, col: C.int, height: C.int, width: C.int, valid: bool, on_top: bool) -> bool ---
	@(link_name = "ui_call_win_pos")
	ui_call_win_pos_r :: proc "c" (grid: C.longlong, win: C.int, startrow: C.longlong, startcol: C.longlong, width: C.longlong, height: C.longlong) ---
	@(link_name = "ui_call_win_float_pos")
	ui_call_win_float_pos_r :: proc "c" (grid: C.longlong, win: C.int, anchor: NvimString, anchor_grid: C.longlong, anchor_row: f64, anchor_col: f64, mouse_enabled: bool, zindex: C.longlong, compindex: C.longlong, screen_row: C.longlong, screen_col: C.longlong) ---
	@(link_name = "ui_call_win_external_pos")
	ui_call_win_external_pos_r :: proc "c" (grid: C.longlong, win: C.int) ---
	@(link_name = "ui_check_cursor_grid")
	ui_check_cursor_grid_r :: proc "c" (grid_handle: C.int) ---
	@(link_name = "default_grid")
	default_grid_u8: u8 // address-of only
	@(link_name = "float_anchor_str")
	float_anchor_str_g: [4]cstring
}

@(export)
ui_ext_win_position :: proc "c"(wp: rawptr, validate: bool) {
	wcfg := uintptr(wp) + W_CONFIG_OFF
	wgrid := uintptr(wp) + W_GRID_ALLOC_OFF
	(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = false
	if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		if ui_has(K_UIMULTIGRID_O) {
			// Windows on the default grid don't necessarily have comp_col
			// and comp_row set, but the rest relies on it.
			(^C.int)(wgrid + GRID_COMP_COL_OFF)^ = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^
			(^C.int)(wgrid + GRID_COMP_ROW_OFF)^ = (^C.int)(uintptr(wp) + W_WINROW_OFF)^
		}
		ui_call_win_pos_r(
			C.longlong((^C.int)(wgrid + GRID_HANDLE_OFF2)^),
			(^C.int)(uintptr(wp) + W_HANDLE_OFF)^,
			C.longlong((^C.int)(uintptr(wp) + W_WINROW_OFF)^),
			C.longlong((^C.int)(uintptr(wp) + W_WINCOL_OFF)^),
			C.longlong((^C.int)(uintptr(wp) + W_WIDTH_OFF)^),
			C.longlong((^C.int)(uintptr(wp) + W_HEIGHT_OFF)^))
		return
	}
	cfg_external := (^bool)(wcfg + 48)^
	if !cfg_external {
		grid := transmute(rawptr)(&default_grid_u8)
		row := (^f64)(wcfg + WCFG_ROW_OFF)^
		col := (^f64)(wcfg + WCFG_COL_OFF)^
		if (^C.int)(wcfg + WCFG_RELATIVE_OFF)^ == KFLOAT_REL_WINDOW_O {
			dummy: Api_Error = {typ = -1, msg = nil}
			win := find_window_by_handle_r((^C.int)(wcfg + WCFG_WINDOW_OFF)^,
				transmute(rawptr)(&dummy))
			api_clear_error_r(&dummy)
			if win != nil {
				// Anchored window first, if it moved.
				if (^bool)(uintptr(win) + W_POS_CHANGED_OFF)^ &&
					(^rawptr)(uintptr(win) + W_GRID_ALLOC_OFF + GRID_CHARS_OFF)^ != nil &&
					win_valid(win) {
					ui_ext_win_position(win, validate)
				}
				row_off: C.int = 0
				col_off: C.int = 0
				win_grid_alloc_r(win)
				grid = grid_adjust_r(transmute(rawptr)(uintptr(win) + W_GRID_OFF),
					&row_off, &col_off)
				row += f64(row_off)
				col += f64(col_off)
				if (^C.int)(wcfg + WCFG_BUFPOS_LNUM_OFF)^ >= 0 {
					lnum := min((^C.int)(wcfg + WCFG_BUFPOS_LNUM_OFF)^ + 1,
						(^C.int)(uintptr((^rawptr)(uintptr(win) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^)
					pos := Pos_T{lnum, (^C.int)(wcfg + WCFG_BUFPOS_COL_OFF)^, 0}
					trow, tcol, tcolc, tcole: C.int
					textpos2screenpos_r(win, &pos, &trow, &tcol, &tcolc, &tcole, true)
					row += f64(trow - 1)
					col += f64(tcol - 1)
				}
			}
		} else if (^C.int)(wcfg + WCFG_RELATIVE_OFF)^ == KFLOAT_REL_LASTSTATUS_O {
			row += f64(Rows - C.int(p_ch) - last_stl_height(false))
		} else if (^C.int)(wcfg + WCFG_RELATIVE_OFF)^ == KFLOAT_REL_TABLINE_O {
			row += f64(tabline_height())
		}
		resort := (^C.size_t)(wgrid + GRID_COMP_INDEX_OFF)^ != 0 &&
			(^C.int)(wgrid + GRID_ZINDEX_OFF)^ != (^C.int)(wcfg + WCFG_ZINDEX_OFF2)^
		raise := resort && (^C.int)(wgrid + GRID_ZINDEX_OFF)^ < (^C.int)(wcfg + WCFG_ZINDEX_OFF2)^
		(^C.int)(wgrid + GRID_ZINDEX_OFF)^ = (^C.int)(wcfg + WCFG_ZINDEX_OFF2)^
		if resort {
			ui_comp_layers_adjust_r((^C.size_t)(wgrid + GRID_COMP_INDEX_OFF)^, raise)
		}
		valid := (^C.int)(uintptr(wp) + W_REDR_TYPE_OFF)^ == 0 || ui_has(K_UIMULTIGRID_O)
		if !valid && !validate {
			(^bool)(uintptr(wp) + W_POS_CHANGED_OFF)^ = true
			return
		}
		east := (^C.int)(wcfg + WCFG_ANCHOR_OFF)^ & KFLOAT_ANCHOR_EAST_O != 0
		south := (^C.int)(wcfg + WCFG_ANCHOR_OFF)^ & KFLOAT_ANCHOR_SOUTH_O != 0
		comp_row := C.int(row) - (south ? (^C.int)(uintptr(wp) + W_HEIGHT_OUTER_OFF)^ : 0)
		comp_col := C.int(col) - (east ? (^C.int)(uintptr(wp) + W_WIDTH_OUTER_OFF)^ : 0)
		above_ch := (^C.int)(wcfg + WCFG_ZINDEX_OFF2)^ < KZINDEX_MESSAGES_O ? C.int(p_ch) : 0
		comp_row += (^C.int)(uintptr(grid) + GRID_COMP_ROW_OFF)^
		comp_col += (^C.int)(uintptr(grid) + GRID_COMP_COL_OFF)^
		comp_row = max(min(comp_row, Rows - (^C.int)(uintptr(wp) + W_HEIGHT_OUTER_OFF)^ - above_ch), 0)
		if !(^bool)(wcfg + WCFG_FIXED_OFF)^ || east {
			comp_col = max(min(comp_col, Columns - (^C.int)(uintptr(wp) + W_WIDTH_OUTER_OFF)^), 0)
		}
		(^C.int)(uintptr(wp) + W_WINROW_OFF)^ = comp_row
		(^C.int)(uintptr(wp) + W_WINCOL_OFF)^ = comp_col
		if !(^bool)(wcfg + WCFG_REL_HIDE)^ {
			ui_comp_put_grid_r(transmute(rawptr)(wgrid), comp_row, comp_col,
				(^C.int)(uintptr(wp) + W_HEIGHT_OUTER_OFF)^,
				(^C.int)(uintptr(wp) + W_WIDTH_OUTER_OFF)^, valid, false)
			if ui_has(K_UIMULTIGRID_O) {
				anchor_s := float_anchor_str_g[(^C.int)(wcfg + WCFG_ANCHOR_OFF)^]
				anchor := NvimString{data = anchor_s,
					size = C.size_t(libc.strlen(anchor_s))}
				ui_call_win_float_pos_r(
					C.longlong((^C.int)(wgrid + GRID_HANDLE_OFF2)^),
					(^C.int)(uintptr(wp) + W_HANDLE_OFF)^,
					anchor,
					C.longlong((^C.int)(uintptr(grid) + GRID_HANDLE_OFF2)^),
					row, col,
					(^bool)(wgrid + GRID_MOUSE_OFF2)^,
					C.longlong((^C.int)(wgrid + GRID_ZINDEX_OFF)^),
					C.longlong((^C.size_t)(wgrid + GRID_COMP_INDEX_OFF)^),
					C.longlong((^C.int)(uintptr(wp) + W_WINROW_OFF)^),
					C.longlong((^C.int)(uintptr(wp) + W_WINCOL_OFF)^))
			}
			ui_check_cursor_grid_r((^C.int)(wgrid + GRID_HANDLE_OFF2)^)
			(^bool)(wgrid + GRID_MOUSE_OFF2)^ = (^bool)(wcfg + WCFG_MOUSE_OFF2)^
			if !valid {
				(^bool)(wgrid + GRID_VALID_OFF)^ = false
				redraw_later(wp, UPD_NOT_VALID_O)
			}
		} else {
			if ui_has(K_UIMULTIGRID_O) {
				ui_call_win_hide_r((^C.int)(wgrid + GRID_HANDLE_OFF2)^)
			}
			ui_comp_remove_grid_r(transmute(rawptr)(wgrid))
		}
	} else {
		ui_call_win_external_pos_r(
			C.longlong((^C.int)(wgrid + GRID_HANDLE_OFF2)^),
			(^C.int)(uintptr(wp) + W_HANDLE_OFF)^)
	}
}

// ── Batch 47: WinScrolled/WinResized trigger ─────────────────────────────────
// w_p_eiw@848 (^u8 slot)/w_leftcol@384/save_v_event_T 304B — cc-probed.

W_P_EIW_OFF :: 848
SAVE_V_EVENT_SIZE_O :: 304
EVENT_WINRESIZED_O :: 147
EVENT_WINSCROLLED_O :: 148
VAR_UNLOCKED_O :: 0

@(private="file")
may_trigger_recursive_b47: bool = false

foreign _ {
	@(link_name = "event_ignored")
	event_ignored_r :: proc "c" (event: C.int, ei: cstring) -> bool ---
	@(link_name = "tv_list_append_owned_tv")
	tv_list_append_owned_tv_r :: proc "c" (l: rawptr, tv: Typval_T) -> rawptr ---
	@(link_name = "tv_list_alloc")
	tv_list_alloc_r :: proc "c" (len: C.long) -> rawptr ---
	@(link_name = "tv_dict_add_tv")
	tv_dict_add_tv_r :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, tv: rawptr) -> C.int ---
	@(link_name = "tv_dict_add_dict")
	tv_dict_add_dict_r :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, dict: rawptr) -> C.int ---
	@(link_name = "tv_dict_add_list")
	tv_dict_add_list_r :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, list: rawptr) -> C.int ---
	@(link_name = "tv_dict_unref")
 	tv_dict_unref_r :: proc "c" (d: rawptr) ---
 	@(link_name = "tv_dict_extend")
 	tv_dict_extend_r :: proc "c" (d1: rawptr, d2: rawptr, action: cstring) ---
}

// Dict with size/scroll changes of one window (refcount 1; NULL on error).
make_win_info_dict_o :: proc "c"(width: C.int, height: C.int, topline: C.int, topfill: C.int, leftcol: C.int, skipcol: C.int) -> rawptr {
	d := tv_dict_alloc_r()
	(^C.int)(uintptr(d) + DV_REFCOUNT_OFF)^ = 1
	// not actually looping, for breaking out on error
	for {
		tv: Typval_T
		tv.v_lock = VAR_FIXED_O - VAR_FIXED_O + VAR_UNLOCKED_O // 0
		tv.v_type = VAR_NUMBER_O
		tv.vval = transmute(rawptr)C.longlong(width)
		if tv_dict_add_tv_r(d, cstring("width"), 5, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		tv.vval = transmute(rawptr)C.longlong(height)
		if tv_dict_add_tv_r(d, cstring("height"), 6, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		tv.vval = transmute(rawptr)C.longlong(topline)
		if tv_dict_add_tv_r(d, cstring("topline"), 7, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		tv.vval = transmute(rawptr)C.longlong(topfill)
		if tv_dict_add_tv_r(d, cstring("topfill"), 7, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		tv.vval = transmute(rawptr)C.longlong(leftcol)
		if tv_dict_add_tv_r(d, cstring("leftcol"), 7, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		tv.vval = transmute(rawptr)C.longlong(skipcol)
		if tv_dict_add_tv_r(d, cstring("skipcol"), 7, transmute(rawptr)(&tv)) == FAIL {
			break
		}
		return d
	}
	tv_dict_unref_r(d)
	return nil
}

// Scan windows for size/scroll changes (3 modes via NULL args; C static).
check_window_scroll_resize_o :: proc "c"(size_count: ^C.int, first_scroll_win: ^rawptr, first_size_win: ^rawptr, winlist: rawptr, v_event: rawptr) {
	tot_width: C.int = 0
	tot_height: C.int = 0
	tot_topline: C.int = 0
	tot_topfill: C.int = 0
	tot_leftcol: C.int = 0
	tot_skipcol: C.int = 0
	wp := firstwin // FOR_ALL_WINDOWS_IN_TAB(wp, curtab): curtab nuance
	for wp != nil {
		// Skip floats without a snapshot (newly-created): creating floats
		// doesn't resize other windows (unlike splits).
		if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
			(^C.int)(uintptr(wp) + W_LAST_TOPLINE_OFF)^ == 0 {
			(^C.int)(uintptr(wp) + W_LAST_TOPLINE_OFF)^ = (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			(^C.int)(uintptr(wp) + W_LAST_TOPFILL_OFF)^ = (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
			(^C.int)(uintptr(wp) + W_LAST_LEFTCOL_OFF)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
			(^C.int)(uintptr(wp) + W_LAST_SKIPCOL_OFF)^ = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
			(^C.int)(uintptr(wp) + W_LAST_WIDTH_OFF)^ = (^C.int)(uintptr(wp) + W_WIDTH_OFF)^
			(^C.int)(uintptr(wp) + W_LAST_HEIGHT_OFF)^ = (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			continue
		}
		eiw := (^cstring)(uintptr(wp) + W_P_EIW_OFF)^
		ignore_scroll := event_ignored_r(EVENT_WINSCROLLED_O, eiw)
		size_changed := !event_ignored_r(EVENT_WINRESIZED_O, eiw) &&
			((^C.int)(uintptr(wp) + W_LAST_WIDTH_OFF)^ != (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ ||
				(^C.int)(uintptr(wp) + W_LAST_HEIGHT_OFF)^ != (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^)
		if size_changed {
			if winlist != nil {
				// Add this window to the list of changed windows.
				tv: Typval_T
				tv.v_lock = VAR_UNLOCKED_O
				tv.v_type = VAR_NUMBER_O
				tv.vval = transmute(rawptr)C.longlong((^C.int)(uintptr(wp) + W_HANDLE_OFF)^)
				tv_list_append_owned_tv_r(winlist, tv)
			} else if size_count != nil {
				size_count^ += 1
				if first_size_win^ == nil {
					first_size_win^ = wp
				}
				// For WinScrolled the first size-changed window is used
				// even when it didn't scroll.
				if first_scroll_win^ == nil && !ignore_scroll {
					first_scroll_win^ = wp
				}
			}
		}
		scroll_changed := !ignore_scroll &&
			((^C.int)(uintptr(wp) + W_LAST_TOPLINE_OFF)^ != (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ ||
				(^C.int)(uintptr(wp) + W_LAST_TOPFILL_OFF)^ != (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ ||
				(^C.int)(uintptr(wp) + W_LAST_LEFTCOL_OFF)^ != (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ ||
				(^C.int)(uintptr(wp) + W_LAST_SKIPCOL_OFF)^ != (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^)
		if scroll_changed && first_scroll_win != nil && first_scroll_win^ == nil {
			first_scroll_win^ = wp
		}
		if (size_changed || scroll_changed) && v_event != nil {
			// Add info about this window to the v:event dictionary.
			width := (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_WIDTH_OFF)^
			height := (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_HEIGHT_OFF)^
			topline := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_TOPLINE_OFF)^
			topfill := (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_TOPFILL_OFF)^
			leftcol := (^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_LEFTCOL_OFF)^
			skipcol := (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ - (^C.int)(uintptr(wp) + W_LAST_SKIPCOL_OFF)^
			d := make_win_info_dict_o(width, height, topline, topfill, leftcol, skipcol)
			if d == nil {
				break
			}
			winid: [NUMBUFLEN]u8
			key_len := libc.snprintf(&winid[0], NUMBUFLEN, cstring("%d"),
				(^C.int)(uintptr(wp) + W_HANDLE_OFF)^)
			if tv_dict_add_dict_r(v_event, transmute(cstring)(&winid[0]), C.size_t(key_len), d) == FAIL {
				tv_dict_unref_r(d)
				break
			}
			(^C.int)(uintptr(d) + DV_REFCOUNT_OFF)^ -= 1
			tot_width += abs(width)
			tot_height += abs(height)
			tot_topline += abs(topline)
			tot_topfill += abs(topfill)
			tot_leftcol += abs(leftcol)
			tot_skipcol += abs(skipcol)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if v_event != nil {
		alldict := make_win_info_dict_o(tot_width, tot_height, tot_topline,
			tot_topfill, tot_leftcol, tot_skipcol)
		if alldict != nil {
			if tv_dict_add_dict_r(v_event, cstring("all"), 3, alldict) == FAIL {
				tv_dict_unref_r(alldict)
			} else {
				(^C.int)(uintptr(alldict) + DV_REFCOUNT_OFF)^ -= 1
			}
		}
	}
}

// Trigger WinScrolled and/or WinResized for changed windows.
@(export)
may_trigger_win_scrolled_resized :: proc "c"() {
	do_resize := has_event_r(EVENT_WINRESIZED_O)
	do_scroll := has_event_r(EVENT_WINSCROLLED_O)
	if may_trigger_recursive_b47 || !(do_scroll || do_resize) ||
		!did_initial_scroll_size_snapshot_b41 {
		return
	}
	size_count: C.int = 0
	first_scroll_win: rawptr = nil
	first_size_win: rawptr = nil
	check_window_scroll_resize_o(&size_count, &first_scroll_win, &first_size_win, nil, nil)
	trigger_resize := do_resize && size_count > 0
	trigger_scroll := do_scroll && first_scroll_win != nil
	if !trigger_resize && !trigger_scroll {
		return // no relevant changes
	}
	windows_list: rawptr = nil
	if trigger_resize {
		// Create the list for v:event.windows before making the snapshot.
		windows_list = tv_list_alloc_r(C.long(size_count))
		check_window_scroll_resize_o(nil, nil, nil, windows_list, nil)
	}
	scroll_dict: rawptr = nil
	if trigger_scroll {
		// Create the dict with entries for v:event before the snapshot.
		scroll_dict = tv_dict_alloc_r()
		(^C.int)(uintptr(scroll_dict) + DV_REFCOUNT_OFF)^ = 1
		check_window_scroll_resize_o(nil, nil, nil, nil, scroll_dict)
	}
	// WinScrolled/WinResized trigger only once, even with multiple
	// windows. Store current values before triggering (later side-effect
	// scrolls/resizes trigger again later).
	snapshot_windows_scroll_size()
	may_trigger_recursive_b47 = true
	// Save window info before autocmds since they can free windows
	resize_winid: [NUMBUFLEN]u8
	resize_bufref: Bufref_T
	if trigger_resize {
		libc.snprintf(&resize_winid[0], NUMBUFLEN, cstring("%d"),
			(^C.int)(uintptr(first_size_win) + W_HANDLE_OFF)^)
		set_bufref(&resize_bufref, (^rawptr)(uintptr(first_size_win) + W_BUFFER_OFF)^)
	}
	scroll_winid: [NUMBUFLEN]u8
	scroll_bufref: Bufref_T
	if trigger_scroll {
		libc.snprintf(&scroll_winid[0], NUMBUFLEN, cstring("%d"),
			(^C.int)(uintptr(first_scroll_win) + W_HANDLE_OFF)^)
		set_bufref(&scroll_bufref, (^rawptr)(uintptr(first_scroll_win) + W_BUFFER_OFF)^)
	}
	// If both are to be triggered do WinResized first.
	if trigger_resize && windows_list != nil {
		save_v_event: [SAVE_V_EVENT_SIZE_O]u8
		v_event := get_v_event_r(&save_v_event[0])
		if tv_dict_add_list_r(v_event, cstring("windows"), 7, windows_list) == OK {
			tv_dict_set_keys_readonly_r(v_event)
			buf := bufref_valid(&resize_bufref) ? resize_bufref.br_buf : curbuf
			apply_autocmds(EVENT_WINRESIZED_O, transmute(cstring)(&resize_winid[0]),
				transmute(cstring)(&resize_winid[0]), false, buf)
		}
		restore_v_event_r(v_event, &save_v_event[0])
	}
	if trigger_scroll && scroll_dict != nil {
		save_v_event: [SAVE_V_EVENT_SIZE_O]u8
		v_event := get_v_event_r(&save_v_event[0])
		// Move the entries from scroll_dict to v_event.
		tv_dict_extend_r(v_event, scroll_dict, cstring("move"))
		tv_dict_set_keys_readonly_r(v_event)
		tv_dict_unref_r(scroll_dict)
		buf := bufref_valid(&scroll_bufref) ? scroll_bufref.br_buf : curbuf
		apply_autocmds(EVENT_WINSCROLLED_O, transmute(cstring)(&scroll_winid[0]),
			transmute(cstring)(&scroll_winid[0]), false, buf)
	}
	may_trigger_recursive_b47 = false
}
