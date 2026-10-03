package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// change.c port: buffer-change notification (dirty flag, redraw invalidation).
// Publics are @(export); C-statics are _o dormant plains.

foreign _ {
	@(link_name = "aucmd_defer_modified")
	aucmd_defer_modified_e :: proc "c" (buf: rawptr, new_val: bool) ---
	// approximate_botline_win now defined in move.odin — call directly.
	@(link_name = "diff_internal")
	diff_internal_e :: proc "c" () -> C.int ---
	@(link_name = "diff_update_line")
	diff_update_line_e :: proc "c" (lnum: C.int) ---
	// sms_marker_overlap now defined in move.odin — call directly.
	@(link_name = "last_cursormoved_win")
	last_cursormoved_win_g: rawptr
	@(link_name = "last_cursormoved")
	last_cursormoved_g: Pos_T
	@(link_name = "utf_composinglike")
	utf_composinglike_e :: proc "c" (p1: cstring, p2: cstring, state: ^C.int) -> bool ---
	@(link_name = "replace_push")
	replace_push_e :: proc "c" (str: ^u8, len: C.size_t) ---
	@(link_name = "replace_push_nul")
	replace_push_nul_e :: proc "c" () ---
	@(link_name = "ins_compl_active")
	ins_compl_active_e :: proc "c" () -> bool ---
	@(link_name = "p_sm")
	p_sm_g: C.int
	@(link_name = "p_deco")
	p_deco_g: C.int
	@(link_name = "p_sr")
	p_sr_g: C.int
	@(link_name = "ai_col")
	ai_col_g: C.int
	@(link_name = "orig_line_count")
	orig_line_count_g: C.int
	@(link_name = "end_comment_pending")
	end_comment_pending_g: C.int
	@(link_name = "vr_lines_changed")
	vr_lines_changed_g: C.int
	// may_do_si/copy_indent/set_indent now defined in indent.odin — call directly.
	// indent_size_ts/get_indent/get_sw_value now defined in indent.odin — call directly.
	cin_is_cinword :: proc "c" (line: cstring) -> bool ---
	in_cinkeys :: proc "c" (keytyped: C.int, when_key: C.int, line_is_empty: bool) -> bool ---
	check_linecomment :: proc "c" (line: cstring) -> C.int ---
	// get_lisp_indent/fixthisline/use_indentexpr_for_lisp now defined in indent.odin — call directly.
	do_c_expr_indent :: proc "c" () ---
	// get_sw_value now defined in indent.odin — call directly.
	truncate_spaces :: proc "c" (line: ^u8, len: C.size_t) ---
	prompt_text :: proc "c" () -> ^u8 ---
}

W_READONLY_S :: "W10: Warning: Changing a readonly file"
EVENT_FILECHANGEDRO_O :: 51
VV_WARNINGMSG_O :: 4
B_RO_LOCKED_OFF_O :: 152
B_START_FFC_OFF_O :: 11112
CPO_DOLLAR_O :: '$'
COM_MAX_LEN_O :: 50
COM_NEST_O :: 'n'
COM_BLANK_O :: 'b'
COM_NOBACK_O :: 'O'
CPO_LISTWM_O :: 'L'
BACKWARD_O :: -1
OPENLINE_FORCE_INDENT_O :: 0x40
COM_RIGHT_O :: 'r'
COM_LEFT_O :: 'l'
COM_AUTO_END_O :: 'x'
FO_NO_OPEN_COMS_O :: '/'
SIN_INSERT_O :: 2
SIN_NOMARK_O :: 8
KEY_OPEN_FORW_O :: 0x101
KEY_OPEN_BACK_O :: 0x102
W_CHANGELISTIDX_OFF_O :: 9128
W_REDR_TYPE_OFF_O :: 692
W_REDRAW_TOP_OFF_O :: 700
W_SKIPCOL_OFF_O :: 388
W_TOPLINE_OFF_O :: 364
W_CLINE_FOLDED_OFF_O :: 588
W_P_RNU_OFF_O :: 964
W_LAST_RNU_OFF_O :: 192
W_P_CUL_OFF_O :: 1060
W_LAST_CUL_OFF_O :: 160
TP_DIFF_UPDATE_OFF_O :: 164

@(export)
change_warning :: proc "c" (buf: rawptr, col: C.int) {
	context = runtime.default_context()
	if (^bool)(uintptr(buf) + B_DID_WARN)^ == false && !curbufIsChanged() && !autocmd_busy_g && (^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0 {
		(^C.int)(uintptr(buf) + B_RO_LOCKED_OFF_O)^ += 1
		apply_autocmds(EVENT_FILECHANGEDRO_O, nil, nil, false, buf)
		(^C.int)(uintptr(buf) + B_RO_LOCKED_OFF_O)^ -= 1
		if (^C.int)(uintptr(buf) + B_P_RO_OFF)^ == 0 {
			return
		}
		msg_start()
		if msg_row == Rows - 1 {
			msg_col = col
		}
		msg_source_e(HLF_W_O)
		msg_ext_set_kind(cstring("wmsg"))
		msg_puts_hl_s(cstring(W_READONLY_S), HLF_W_O, true)
		set_vim_var_string(VV_WARNINGMSG_O, cstring(W_READONLY_S), -1)
		msg_clr_eos_r()
		msg_end()
		if msg_silent == 0 && !silent_mode && ui_active() != 0 {
			msg_delay_r(1002, true)
		}
		(^bool)(uintptr(buf) + B_DID_WARN)^ = true
		redraw_cmdline_g = false
		if msg_row < Rows - 1 {
			showmode()
		}
	}
}

@(export)
changed :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	if !(^bool)(uintptr(buf) + B_CHANGED_OFF)^ {
		save_msg_scroll := msg_scroll
		change_warning(buf, 0)
		if (^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ && !bt_dontwrite(buf) {
			save_need_wait_return := need_wait_return_g
			need_wait_return_g = false
			ml_open_file(buf)
			if need_wait_return_g && emsg_silent == 0 && !in_assert_fails_g && !ui_has(K_UIMESSAGES_O) {
				msg_delay_r(2002, true)
				wait_return(1)
				msg_scroll = save_msg_scroll
			} else {
				need_wait_return_g = save_need_wait_return
			}
		}
		changed_internal(buf)
	}
	buf_inc_changedtick(buf)
	highlight_match_g = false
}

@(export)
changed_internal :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	was_changed := (^bool)(uintptr(buf) + B_CHANGED_OFF)^
	(^bool)(uintptr(buf) + B_CHANGED_OFF)^ = true
	ml_setflags(buf)
	redraw_buf_status_later(buf)
	redraw_tabline_opt = true
	need_maketitle_opt = true
	if !was_changed {
		aucmd_defer_modified_e(buf, true)
	}
}

// Invalidate one window's w_valid flags and w_lines after a change.
changed_lines_invalidate_win_o :: proc "c" (wp: rawptr, lnum: C.int, col: C.int, lnume: C.int, xtra: C.int) {
	context = runtime.default_context()
	cursor_lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	if cursor_lnum <= lnum {
		i := find_wl_entry(wp, lnum)
		if i >= 0 {
			wl_lnum := (^C.int)(uintptr(wp) + W_LINES_OFF + uintptr(i) * 16)^
			if cursor_lnum > wl_lnum {
				changed_line_abv_curs_win(wp)
			}
		}
	}
	cursor_lnum = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
	cursor_col := (^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^
	if cursor_lnum > lnum {
		changed_line_abv_curs_win(wp)
	} else if cursor_lnum == lnum && cursor_col >= col {
		changed_cline_bef_curs(wp)
	}
	if (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ >= lnum {
		if xtra < 0 {
			invalidate_botline_win(wp)
		} else {
			approximate_botline_win(wp)
		}
	}
	wrap := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ln := lnume
	if ((xtra < 0 && wrap && buf_meta_total_o(wbuf, K_MTMETA_INLINE_O) != 0) || (xtra != 0 && buf_meta_total_o(wbuf, K_MTMETA_LINES_O) != 0)) {
		ln += 1
	}
	n_valid := (^C.int)(uintptr(wp) + W_LINES_VALID_OFF)^
	i: C.int = 0
	for i < n_valid {
		base := uintptr(wp) + W_LINES_OFF + uintptr(i) * 16
		if ([^]u8)(base + 6)[0] != 0 {
			wl_lnum := (^C.int)(base)^
			if wl_lnum >= lnum {
				if i == 0 || wl_lnum < ln {
					([^]u8)(base + 6)[0] = 0
				} else if xtra != 0 {
					(^C.int)(base)^ = wl_lnum + xtra
					(^C.int)(base + 8)^ = (^C.int)(base + 8)^ + xtra
					(^C.int)(base + 12)^ = (^C.int)(base + 12)^ + xtra
				}
			} else if (^C.int)(base + 12)^ >= lnum {
				([^]u8)(base + 6)[0] = 0
			}
		}
		i += 1
	}
}

@(export)
changed_lines_invalidate_buf :: proc "c" (buf: rawptr, lnum: C.int, col: C.int, lnume: C.int, xtra: C.int) {
	context = runtime.default_context()
	tp := first_tabpage
	for tp != nil {
		wp := firstwin
		if tp != curtab {
			wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		}
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				changed_lines_invalidate_win_o(wp, lnum, col, lnume, xtra)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

@(export)
changed_bytes :: proc "c" (lnum: C.int, col: C.int) {
	context = runtime.default_context()
	changed_lines_redraw_buf(curbuf, lnum, lnum + 1, 0)
	changed_common(curbuf, lnum, col, lnum + 1, 0)
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if spell_check_window(curwin) && lnum < ml.line_count && vim_strchr(p_cpo, C.int(CPO_DOLLAR_O)) == nil {
		redrawWinline(curwin, lnum + 1)
	}
	buf_updates_send_changes(curbuf, lnum, 1, 1)
	if (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0 {
		wp := firstwin
		for wp != nil {
			if (^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ != 0 && wp != curwin {
				redraw_later(wp, UPD_VALID_O)
				wlnum := diff_lnum_win_r(lnum, wp)
				if wlnum > 0 {
					changed_lines_redraw_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, wlnum, wlnum + 1, 0)
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
}

@(export)
inserted_bytes :: proc "c" (lnum: C.int, start_col: C.int, old_col: C.int, new_col: C.int) {
	context = runtime.default_context()
	if curbuf_splice_pending_g == 0 {
		extmark_splice_cols(curbuf, C.int(lnum) - 1, start_col, old_col, new_col, kExtmarkUndo)
	}
	changed_bytes(lnum, start_col)
}

@(export)
appended_lines_buf :: proc "c" (buf: rawptr, lnum: C.int, count: C.int) {
	context = runtime.default_context()
	changed_lines(buf, lnum + 1, 0, lnum + 1, count, true)
}

@(export)
appended_lines :: proc "c" (lnum: C.int, count: C.int) {
	context = runtime.default_context()
	appended_lines_buf(curbuf, lnum, count)
}

@(export)
appended_lines_mark :: proc "c" (lnum: C.int, count: C.int) {
	context = runtime.default_context()
	mark_adjust(lnum + 1, MAXLNUM, count, 0, kExtmarkUndo)
	changed_lines(curbuf, lnum + 1, 0, lnum + 1, count, true)
}

@(export)
deleted_lines_buf :: proc "c" (buf: rawptr, lnum: C.int, count: C.int) {
	context = runtime.default_context()
	changed_lines(buf, lnum, 0, lnum + count, -count, true)
}

@(export)
deleted_lines :: proc "c" (lnum: C.int, count: C.int) {
	context = runtime.default_context()
	deleted_lines_buf(curbuf, lnum, count)
}

@(export)
deleted_lines_mark :: proc "c" (lnum: C.int, count: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	made_empty := count > 0 && (ml.flags & ML_EMPTY_O) != 0
	mark_adjust(lnum, lnum + count - 1, MAXLNUM, -count, kExtmarkNOOP)
	amt := -count
	if made_empty {
		amt += 1
	}
	extmark_adjust(curbuf, lnum, lnum + count - 1, MAXLNUM, amt, kExtmarkUndo)
	changed_lines(curbuf, lnum, 0, lnum + count, -count, true)
}

@(export)
changed_lines_redraw_buf :: proc "c" (buf: rawptr, lnum: C.int, lnume_in: C.int, xtra: C.int) {
	context = runtime.default_context()
	lnume := lnume_in
	if xtra != 0 && (^C.size_t)(uintptr(buf) + B_MARKTREE_OFF + 32)^ > 0 {
		lnume += 1
		if xtra < 0 && buf_meta_total_o(buf, K_MTMETA_LINES_O) != 0 {
			lnume += 1
		}
	}
	if (^bool)(uintptr(buf) + B_MOD_SET_OFF)^ {
		top := (^C.int)(uintptr(buf) + B_MOD_TOP_OFF)^
		if lnum < top {
			top = lnum
		}
		(^C.int)(uintptr(buf) + B_MOD_TOP_OFF)^ = top
		bot := (^C.int)(uintptr(buf) + B_MOD_BOT_OFF)^
		if lnum < bot {
			bot += xtra
			if bot < lnum {
				bot = lnum
			}
		}
		if bot < lnume + xtra {
			bot = lnume + xtra
		}
		(^C.int)(uintptr(buf) + B_MOD_BOT_OFF)^ = bot
		(^C.int)(uintptr(buf) + B_MOD_XLINES_OFF)^ += xtra
	} else {
		(^bool)(uintptr(buf) + B_MOD_SET_OFF)^ = true
		(^C.int)(uintptr(buf) + B_MOD_TOP_OFF)^ = lnum
		(^C.int)(uintptr(buf) + B_MOD_BOT_OFF)^ = lnume + xtra
		(^C.int)(uintptr(buf) + B_MOD_XLINES_OFF)^ = xtra
	}
}

@(export)
changed_lines :: proc "c" (buf: rawptr, lnum: C.int, col: C.int, lnume: C.int, xtra: C.int, do_buf_event: bool) {
	context = runtime.default_context()
	changed_lines_redraw_buf(buf, lnum, lnume, xtra)
	if xtra == 0 && (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0 && (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf && diff_internal_e() == 0 {
		wp := firstwin
		for wp != nil {
			if (^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ != 0 && wp != curwin {
				redraw_later(wp, UPD_VALID_O)
				wlnum := diff_lnum_win_r(lnum, wp)
				if wlnum > 0 {
					changed_lines_redraw_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, wlnum, lnume - lnum + wlnum, 0)
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	changed_common(buf, lnum, col, lnume, xtra)
	if do_buf_event {
		buf_updates_send_changes(buf, lnum, C.longlong(lnume + xtra - lnum), C.longlong(lnume - lnum))
	}
}

@(export)
unchanged :: proc "c" (buf: rawptr, ff: bool, always_inc_changedtick: bool) {
	context = runtime.default_context()
	if (^bool)(uintptr(buf) + B_CHANGED_OFF)^ || (ff && file_ff_differs(buf, false)) {
		was_changed := (^bool)(uintptr(buf) + B_CHANGED_OFF)^
		(^bool)(uintptr(buf) + B_CHANGED_OFF)^ = false
		ml_setflags(buf)
		if ff {
			save_file_ff(buf)
		}
		redraw_buf_status_later(buf)
		redraw_tabline_opt = true
		need_maketitle_opt = true
		buf_inc_changedtick(buf)
		if was_changed {
			aucmd_defer_modified_e(buf, false)
		}
	} else if always_inc_changedtick {
		buf_inc_changedtick(buf)
	}
}

@(export)
save_file_ff :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	pffslot := (^rawptr)(uintptr(buf) + B_P_FF_OFF)^
	pff := ([^]u8)(transmute(rawptr)(pffslot))
	(^C.int)(uintptr(buf) + B_START_FFC_OFF_O)^ = C.int(pff[0])
	(^C.int)(uintptr(buf) + B_START_EOF_OFF)^ = (^C.int)(uintptr(buf) + B_P_EOF_OFF)^
	(^C.int)(uintptr(buf) + B_START_EOL_OFF)^ = (^C.int)(uintptr(buf) + B_P_EOL_OFF)^
	(^C.int)(uintptr(buf) + B_START_BOMB_OFF)^ = (^C.int)(uintptr(buf) + B_P_BOMB_OFF)^
	old_fenc := (^rawptr)(uintptr(buf) + B_START_FENC_OFF)^
	new_fenc := (^rawptr)(uintptr(buf) + B_P_FENC_OFF)^
	if old_fenc == nil || libc.strcmp(transmute(cstring)(old_fenc), transmute(cstring)(new_fenc)) != 0 {
		xfree(old_fenc)
		(^rawptr)(uintptr(buf) + B_START_FENC_OFF)^ = rawptr(xstrdup(transmute(^u8)(new_fenc)))
	}
}

@(export)
file_ff_differs :: proc "c" (buf: rawptr, ignore_empty: bool) -> bool {
	context = runtime.default_context()
	if ((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & BF_NEVERLOADED_O) != 0 {
		return false
	}
	if ignore_empty && ((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & BF_NEW_O) != 0 && (^C.int)(uintptr(buf) + 8)^ == 1 && ml_get_buf(buf, 1)^ == 0 {
		return false
	}
	pffslot := (^rawptr)(uintptr(buf) + B_P_FF_OFF)^
	pff2 := ([^]u8)(transmute(rawptr)(pffslot))
	if (^C.int)(uintptr(buf) + B_START_FFC_OFF_O)^ != C.int(pff2[0]) {
		return true
	}
	if ((^C.int)(uintptr(buf) + B_P_BIN_OFF)^ != 0 || (^C.int)(uintptr(buf) + B_P_FIXEOL_OFF_O)^ == 0) && ((^C.int)(uintptr(buf) + B_START_EOL_OFF)^ != (^C.int)(uintptr(buf) + B_P_EOL_OFF)^ || (^C.int)(uintptr(buf) + B_START_EOF_OFF)^ != (^C.int)(uintptr(buf) + B_P_EOF_OFF)^) {
		return true
	}
	if (^C.int)(uintptr(buf) + B_P_BIN_OFF)^ == 0 && (^C.int)(uintptr(buf) + B_START_BOMB_OFF)^ != (^C.int)(uintptr(buf) + B_P_BOMB_OFF)^ {
		return true
	}
	if (^rawptr)(uintptr(buf) + B_START_FENC_OFF)^ == nil {
		pfs := (^rawptr)(uintptr(buf) + B_P_FENC_OFF)^
		pf := ([^]u8)(transmute(rawptr)(pfs))
		return pf[0] != 0
	}
	return libc.strcmp(transmute(cstring)((^rawptr)(uintptr(buf) + B_START_FENC_OFF)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_P_FENC_OFF)^)) != 0
}

// RESET_FMARK inline (mark.odin's is file-private).
reset_fmark_o :: proc "c" (fp: ^Fmark_T, mark_: Pos_T, fnum_: C.int, view_: Fmarkv_T) {
	context = runtime.default_context()
	free_fmark(fp^)
	fp.mark = mark_
	fp.fnum = fnum_
	fp.timestamp = os_time()
	fp.view = view_
	fp.additional_data = nil
}

@(export)
changed_common :: proc "c" (buf: rawptr, lnum_in: C.int, col: C.int, lnume_in: C.int, xtra: C.int) {
	context = runtime.default_context()
	lnum := lnum_in
	lnume := lnume_in
	changed(buf)
	wp := firstwin
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ != 0 && diff_internal_e() != 0 {
			(^C.int)(uintptr(curtab) + TP_DIFF_UPDATE_OFF_O)^ = 1
			diff_update_line_e(lnum)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if (cmdmod_cmod_flags & CMOD_KEEPJUMPS) == 0 {
		view := INIT_FMARKV
		if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf {
			topline := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF_O)^
			botline := (^C.int)(uintptr(curwin) + W_BOTLINE_OFF)^
			if lnum >= topline && lnum <= botline {
				view = mark_view_make(curwin, Pos_T{(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^, 0})
			}
		}
		reset_fmark_o((^Fmark_T)(uintptr(buf) + B_LAST_CHANGE), Pos_T{lnum, col, 0}, (^C.int)(uintptr(buf) + 0)^, view)
		if (^bool)(uintptr(buf) + B_NEW_CHANGE)^ || (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ == 0 {
			add := false
			if (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ == 0 {
				add = true
			} else {
				p := (^Pos_T)(uintptr(buf) + B_CHANGELIST + uintptr((^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ - 1) * 40)
				if p.lnum != lnum {
					add = true
				} else {
					cols := comp_textwidth(false)
					if cols == 0 {
						cols = 79
					}
					add = (p.col + cols < col || col + cols < p.col)
				}
			}
			if add {
				(^bool)(uintptr(buf) + B_NEW_CHANGE)^ = false
				if (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ == JUMPLISTSIZE {
					(^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ = JUMPLISTSIZE - 1
					libc.memmove(rawptr(uintptr(buf) + B_CHANGELIST), rawptr(uintptr(buf) + B_CHANGELIST + 40), C.size_t(40 * (JUMPLISTSIZE - 1)))
					tp2 := first_tabpage
					for tp2 != nil {
						wp2 := firstwin
						if tp2 != curtab {
							wp2 = (^rawptr)(uintptr(tp2) + TP_FIRSTWIN_OFF)^
						}
						for wp2 != nil {
							if (^rawptr)(uintptr(wp2) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(wp2) + W_CHANGELISTIDX_OFF_O)^ > 0 {
								(^C.int)(uintptr(wp2) + W_CHANGELISTIDX_OFF_O)^ -= 1
							}
							wp2 = (^rawptr)(uintptr(wp2) + W_NEXT_OFF)^
						}
						tp2 = (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^
					}
				}
				tp2 := first_tabpage
				for tp2 != nil {
					wp2 := firstwin
					if tp2 != curtab {
						wp2 = (^rawptr)(uintptr(tp2) + TP_FIRSTWIN_OFF)^
					}
					for wp2 != nil {
						if (^rawptr)(uintptr(wp2) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(wp2) + W_CHANGELISTIDX_OFF_O)^ == (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ {
							(^C.int)(uintptr(wp2) + W_CHANGELISTIDX_OFF_O)^ += 1
						}
						wp2 = (^rawptr)(uintptr(wp2) + W_NEXT_OFF)^
					}
					tp2 = (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^
				}
			}
			(^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ += 1
		}
		libc.memcpy(rawptr(uintptr(buf) + B_CHANGELIST + uintptr((^C.int)(uintptr(buf) + B_CHANGELISTLEN)^ - 1) * 40), rawptr(uintptr(buf) + B_LAST_CHANGE), 40)
		if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf {
			(^C.int)(uintptr(curwin) + W_CHANGELISTIDX_OFF_O)^ = (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^
		}
	}
	if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf && VIsual_active {
		check_visual_pos()
	}
	tp := first_tabpage
	for tp != nil {
		wp2 := firstwin
		if tp != curtab {
			wp2 = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		}
		for wp2 != nil {
			if (^rawptr)(uintptr(wp2) + W_BUFFER_OFF)^ == buf {
				if !redraw_not_allowed_g && (^C.int)(uintptr(wp2) + W_REDR_TYPE_OFF_O)^ < UPD_VALID_O {
					(^C.int)(uintptr(wp2) + W_REDR_TYPE_OFF_O)^ = UPD_VALID_O
				}
				if xtra != 0 && (^C.int)(uintptr(wp2) + W_REDRAW_TOP_OFF_O)^ != 0 {
					redraw_later(wp2, UPD_NOT_VALID_S)
				}
				last := lnume + xtra - 1
				if (^C.int)(uintptr(wp2) + W_SKIPCOL_OFF_O)^ > 0 && (last < (^C.int)(uintptr(wp2) + W_TOPLINE_OFF_O)^ || ((^C.int)(uintptr(wp2) + W_TOPLINE_OFF_O)^ >= lnum && (^C.int)(uintptr(wp2) + W_TOPLINE_OFF_O)^ < lnume && linetabsize_eol(wp2, (^C.int)(uintptr(wp2) + W_TOPLINE_OFF_O)^) <= (^C.int)(uintptr(wp2) + W_SKIPCOL_OFF_O)^ + sms_marker_overlap(wp2, -1))) {
					(^C.int)(uintptr(wp2) + W_SKIPCOL_OFF_O)^ = 0
				}
				foldUpdate(wp2, lnum, last)
				ln := lnum
				folded := hasFoldingWin(wp2, lnum, &ln, nil, false, nil)
				lnum = ln
				if (^C.int)(uintptr(wp2) + W_CURSOR_OFF)^ == lnum {
					(^bool)(uintptr(wp2) + W_CLINE_FOLDED_OFF_O)^ = folded
				}
				ln2 := last
				folded = hasFoldingWin(wp2, last, nil, &ln2, false, nil)
				last = ln2
				if (^C.int)(uintptr(wp2) + W_CURSOR_OFF)^ == last {
					(^bool)(uintptr(wp2) + W_CLINE_FOLDED_OFF_O)^ = folded
				}
				changed_lines_invalidate_win_o(wp2, lnum, col, lnume, xtra)
				if hasAnyFolding(wp2) != 0 {
					set_topline(wp2, (^C.int)(uintptr(wp2) + W_TOPLINE_OFF_O)^)
				}
				if (^C.int)(uintptr(wp2) + W_P_RNU_OFF_O)^ != 0 && xtra != 0 {
					(^C.int)(uintptr(wp2) + W_LAST_RNU_OFF_O)^ = 0
				}
				if (^C.int)(uintptr(wp2) + W_P_CUL_OFF_O)^ != 0 && (^C.int)(uintptr(wp2) + W_LAST_CUL_OFF_O)^ >= lnum {
					if (^C.int)(uintptr(wp2) + W_LAST_CUL_OFF_O)^ < lnume {
						(^C.int)(uintptr(wp2) + W_LAST_CUL_OFF_O)^ = 0
					} else {
						(^C.int)(uintptr(wp2) + W_LAST_CUL_OFF_O)^ += xtra
					}
				}
			}
			if wp2 == curwin && xtra != 0 && search_hl_has_cursor_lnum_g >= lnum {
				search_hl_has_cursor_lnum_g += xtra
			}
			wp2 = (^rawptr)(uintptr(wp2) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	set_must_redraw(UPD_VALID_O)
	if last_cursormoved_win_g == curwin && (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf && lnum <= (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
		extra := xtra
		if extra < 0 {
			extra = -extra
		}
		if lnume + extra > (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
			last_cursormoved_g.lnum = 0
		}
	}
}

@(export)
ins_bytes :: proc "c" (p: ^u8) {
	context = runtime.default_context()
	ins_bytes_len(p, C.size_t(libc.strlen(transmute(cstring)(p))))
}

@(export)
ins_bytes_len :: proc "c" (p: ^u8, len: C.size_t) {
	context = runtime.default_context()
	pa := ([^]u8)(p)
	i: C.size_t = 0
	for i < len {
		n := C.size_t(utfc_ptr2len_len_r(transmute(cstring)(rawptr(uintptr(pa) + uintptr(i))), C.int(len - i)))
		ins_char_bytes(transmute(^u8)(rawptr(uintptr(pa) + uintptr(i))), n)
		i += n
	}
}

@(export)
ins_char :: proc "c" (c: C.int) {
	context = runtime.default_context()
	buf: [7]u8
	n := C.size_t(utf_char2bytes(c, transmute(^u8)(&buf[0])))
	if buf[0] == 0 {
		buf[0] = '\n'
	}
	ins_char_bytes(transmute(^u8)(&buf[0]), n)
}

@(export)
ins_char_bytes :: proc "c" (buf: ^u8, charlen: C.size_t) {
	context = runtime.default_context()
	if virtual_active(curwin) && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 {
		coladvance_force(getviscol())
	}
	col := C.size_t((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)
	lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	oldp := ml_get(lnum)
	linelen := C.size_t(ml_get_len(lnum)) + 1
	oldlen: C.size_t = 0
	newlen := charlen
	if (State & REPLACE_FLAG) != 0 {
		if (State & VREPLACE_FLAG_O) != 0 {
			old_list := (^C.int)(uintptr(curwin) + W_P_LIST_OFF)^
			if old_list != 0 && vim_strchr(p_cpo, C.int(CPO_LISTWM_O)) == nil {
				(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = 0
			}
			vcol: C.int = 0
			curs := Pos_T{(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^, 0}
			getvcol(curwin, &curs, nil, &vcol, nil, 0)
			new_vcol := vcol + win_chartabsize(curwin, buf, vcol)
			oa := ([^]u8)(oldp)
			for oa[uintptr(col) + uintptr(oldlen)] != 0 && vcol < new_vcol {
				vcol += win_chartabsize(curwin, transmute(^u8)(rawptr(uintptr(oa) + uintptr(col) + uintptr(oldlen))), vcol)
				if vcol > new_vcol && oa[uintptr(col) + uintptr(oldlen)] == TAB_O {
					break
				}
				oldlen += C.size_t(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(oa) + uintptr(col) + uintptr(oldlen)))))
				if vcol > new_vcol {
					newlen += C.size_t(vcol - new_vcol)
				}
			}
			(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = old_list
		} else if (([^]u8)(oldp))[uintptr(col)] != 0 {
			oldlen = C.size_t(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(oldp) + uintptr(col)))))
		}
		replace_push_nul_e()
		replace_push_e(transmute(^u8)(rawptr(uintptr(oldp) + uintptr(col))), oldlen)
	}
	newp := transmute(^u8)(xmalloc(linelen + newlen - oldlen))
	if col > 0 {
		libc.memmove(rawptr(newp), rawptr(oldp), col)
	}
	p := transmute(^u8)(rawptr(uintptr(newp) + uintptr(col)))
	if linelen > col + oldlen {
		libc.memmove(rawptr(uintptr(p) + uintptr(newlen)), rawptr(uintptr(oldp) + uintptr(col) + uintptr(oldlen)), C.size_t(linelen - col - oldlen))
	}
	libc.memmove(rawptr(p), rawptr(buf), charlen)
	i := charlen
	for i < newlen {
		([^]u8)(p)[i] = ' '
		i += 1
	}
	ml_replace(lnum, newp, false)
	inserted_bytes(lnum, C.int(col), C.int(oldlen), C.int(newlen))
	if p_sm_g != 0 && (State & MODE_INSERT) != 0 && msg_silent == 0 && !ins_compl_active_e() {
		showmatch(utf_ptr2char(transmute(cstring)(buf)))
	}
	if p_ri == 0 || (State & REPLACE_FLAG) != 0 {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ += C.int(charlen)
	}
}

@(export)
ins_str :: proc "c" (s: ^u8, slen: C.size_t) {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	if virtual_active(curwin) && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 {
		coladvance_force(getviscol())
	}
	col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	oldp := ml_get(lnum)
	oldlen := ml_get_len(lnum)
	newp := transmute(^u8)(xmalloc(C.size_t(oldlen) + slen + 1))
	if col > 0 {
		libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(col))
	}
	libc.memmove(rawptr(uintptr(newp) + uintptr(col)), rawptr(s), slen)
	bytes := oldlen - col + 1
	if bytes < 0 {
		libc.abort()
	}
	libc.memmove(rawptr(uintptr(newp) + uintptr(col) + uintptr(slen)), rawptr(uintptr(oldp) + uintptr(col)), C.size_t(bytes))
	ml_replace(lnum, newp, false)
	inserted_bytes(lnum, col, 0, C.int(slen))
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ += C.int(slen)
}

@(export)
del_char :: proc "c" (fixpos: bool) -> C.int {
	context = runtime.default_context()
	mb_adjust_cursor_r()
	if get_cursor_pos_ptr()^ == 0 {
		return 0
	}
	fx := C.int(0)
	if fixpos {
		fx = 1
	}
	return del_chars(1, fx)
}

@(export)
del_chars :: proc "c" (count: C.int, fixpos: C.int) -> C.int {
	context = runtime.default_context()
	bytes: C.int = 0
	p := get_cursor_pos_ptr()
	pa := ([^]u8)(p)
	for i: C.int = 0; i < count && pa[uintptr(bytes)] != 0; i += 1 {
		l := utfc_ptr2len(transmute(cstring)(rawptr(uintptr(pa) + uintptr(bytes))))
		bytes += l
	}
	return del_bytes(bytes, fixpos != 0, true)
}

@(export)
del_bytes :: proc "c" (count_in: C.int, fixpos_arg: bool, use_delcombine: bool) -> C.int {
	context = runtime.default_context()
	count := count_in
	lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	fixpos := fixpos_arg
	oldp := ml_get(lnum)
	oldlen := ml_get_len(lnum)
	if col >= oldlen {
		return 0
	}
	if count == 0 {
		return 1
	}
	if count < 1 {
		siemsg(cstring("E292: Invalid count for del_bytes(): %ld"), C.longlong(count))
		return 0
	}
	if p_deco_g != 0 && use_delcombine && utfc_ptr2len(transmute(cstring)(rawptr(uintptr(oldp) + uintptr(col)))) >= count {
		p0 := rawptr(uintptr(oldp) + uintptr(col))
		state: C.int = 0
		if utf_composinglike_e(transmute(cstring)(p0), transmute(cstring)(rawptr(uintptr(p0) + uintptr(utf_ptr2len_o(transmute(cstring)(p0))))), &state) {
			n := col
			for {
				col = n
				count = utf_ptr2len_o(transmute(cstring)(rawptr(uintptr(oldp) + uintptr(n))))
				n += count
				if !utf_composinglike_e(transmute(cstring)(rawptr(uintptr(oldp) + uintptr(col))), transmute(cstring)(rawptr(uintptr(oldp) + uintptr(n))), &state) {
					break
				}
			}
			fixpos = false
		}
	}
	movelen := oldlen - col - count + 1
	if movelen <= 1 {
		if col > 0 && fixpos && restart_edit == 0 && (get_ve_flags(curwin) & KOPT_VE_ONEMORE_O) == 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= 1
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= utf_head_off(transmute(cstring)(oldp), transmute(cstring)(get_cursor_pos_ptr()))
		}
		count = oldlen - col
		movelen = 1
	}
	newlen := oldlen - count
	alloc_newp := ml_line_alloced() == 0
	newp: ^u8
	if !alloc_newp {
		ml_add_deleted_len(transmute(cstring)((^Memline_O)(uintptr(curbuf) + 8).line_ptr), C.ssize_t(oldlen))
		newp = oldp
	} else {
		newp = xmallocz(C.size_t(newlen))
		libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(col))
	}
	libc.memmove(rawptr(uintptr(newp) + uintptr(col)), rawptr(uintptr(oldp) + uintptr(col) + uintptr(count)), C.size_t(movelen))
	if alloc_newp {
		ml_replace(lnum, newp, false)
	} else {
		(^Memline_O)(uintptr(curbuf) + 8).line_textlen = newlen + 1
	}
	inserted_bytes(lnum, col, count, 0)
	return 1
}

@(export)
truncate_line :: proc "c" (fixpos: C.int) {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	old_line := ml_get(lnum)
	newp: ^u8
	if col == 0 {
		newp = xstrdup(transmute(^u8)(cstring("")))
	} else {
		newp = xstrnsave_c(transmute(cstring)(old_line), C.size_t(col))
	}
	deleted := ml_get_len(lnum) - col
	ml_replace(lnum, newp, false)
	inserted_bytes(lnum, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^, deleted, 0)
	if fixpos != 0 && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= 1
	}
}

@(export)
del_lines :: proc "c" (nlines: C.int, undo: bool) {
	context = runtime.default_context()
	n: C.int
	first := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	if nlines <= 0 {
		return
	}
	if undo && u_savedel(first, nlines) == 0 {
		return
	}
	n = 0
	for n < nlines {
		ml := (^Memline_O)(uintptr(curbuf) + 8)
		if (ml.flags & ML_EMPTY_O) != 0 {
			break
		}
		ml_delete_flags(first, ML_DEL_MESSAGE_O)
		n += 1
		if first > (^Memline_O)(uintptr(curbuf) + 8).line_count {
			break
		}
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	check_cursor_lnum(curwin)
	deleted_lines_mark(first, n)
}

@(export)
get_leader_len :: proc "c" (line_in: ^u8, flags: ^^u8, backward: bool, include_space: bool) -> C.int {
	context = runtime.default_context()
	line := ([^]u8)(line_in)
	j: C.int
	got_com := false
	part_buf: [COM_MAX_LEN_O]u8
	string: ^u8
	middle_match_len: C.int = 0
	saved_flags: ^u8 = nil
	result: C.int = 0
	i: C.int = 0
	for ascii_iswhite(line[uintptr(i)]) {
		i += 1
	}
	for line[uintptr(i)] != 0 {
		found_one := false
		list := (^^u8)(uintptr(curbuf) + B_P_COM_OFF)^
		for (([^]u8)(list))[0] != 0 {
			if !got_com && flags != nil {
				flags^ = list
			}
			prev_list := list
			copy_option_part(&list, transmute(^u8)(&part_buf[0]), COM_MAX_LEN_O, cstring(","))
			pb := ([^]u8)(transmute(rawptr)(&part_buf[0]))
			string = vim_strchr(transmute(^u8)(&part_buf[0]), C.int(':'))
			if string == nil {
				continue
			}
			([^]u8)(string)[0] = 0
			string = transmute(^u8)(rawptr(uintptr(string) + 1))
			if middle_match_len != 0 && vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_MIDDLE_O)) == nil && vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_END_O)) == nil {
				break
			}
			if got_com && vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_NEST_O)) == nil {
				continue
			}
			if backward && vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_NOBACK_O)) != nil {
				continue
			}
			sb := ([^]u8)(string)
			if ascii_iswhite(sb[0]) {
				if i == 0 || !ascii_iswhite(line[uintptr(i) - 1]) {
					continue
				}
				for ascii_iswhite(sb[0]) {
					sb = ([^]u8)(rawptr(uintptr(sb) + 1))
				}
				string = transmute(^u8)(rawptr(sb))
			}
			sb = ([^]u8)(string)
			j = 0
			for sb[uintptr(j)] != 0 && sb[uintptr(j)] == line[uintptr(i) + uintptr(j)] {
				j += 1
			}
			if sb[uintptr(j)] != 0 {
				continue
			}
			if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_BLANK_O)) != nil && !ascii_iswhite(line[uintptr(i) + uintptr(j)]) && line[uintptr(i) + uintptr(j)] != 0 {
				continue
			}
			if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_MIDDLE_O)) != nil {
				if middle_match_len == 0 {
					middle_match_len = j
					saved_flags = prev_list
				}
				continue
			}
			if middle_match_len != 0 && j > middle_match_len {
				middle_match_len = 0
			}
			if middle_match_len == 0 {
				i += j
			}
			found_one = true
			break
		}
		if middle_match_len != 0 {
			if !got_com && flags != nil {
				flags^ = saved_flags
			}
			i += middle_match_len
			found_one = true
		}
		if !found_one {
			break
		}
		result = i
		for ascii_iswhite(line[uintptr(i)]) {
			i += 1
		}
		if include_space {
			result = i
		}
		got_com = true
		if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_NEST_O)) == nil {
			break
		}
	}
	return result
}

@(export)
get_last_leader_offset :: proc "c" (line_in: ^u8, flags: ^^u8) -> C.int {
	context = runtime.default_context()
	line := ([^]u8)(line_in)
	result: C.int = -1
	j: C.int
	lower_check_bound: C.int = 0
	com_leader: ^u8
	com_flags: ^u8
	part_buf: [COM_MAX_LEN_O]u8
	i := C.int(libc.strlen(transmute(cstring)(line_in))) - 1
	for i >= lower_check_bound {
		found_one := false
		list := (^^u8)(uintptr(curbuf) + B_P_COM_OFF)^
		for (([^]u8)(list))[0] != 0 {
			flags_save := list
			copy_option_part(&list, transmute(^u8)(&part_buf[0]), COM_MAX_LEN_O, cstring(","))
			string := vim_strchr(transmute(^u8)(&part_buf[0]), C.int(':'))
			if string == nil {
				continue
			}
			([^]u8)(string)[0] = 0
			string = transmute(^u8)(rawptr(uintptr(string) + 1))
			com_leader = string
			sb := ([^]u8)(string)
			if ascii_iswhite(sb[0]) {
				if i == 0 || !ascii_iswhite(line[uintptr(i) - 1]) {
					continue
				}
				for ascii_iswhite(sb[0]) {
					sb = ([^]u8)(rawptr(uintptr(sb) + 1))
				}
				string = transmute(^u8)(rawptr(sb))
				com_leader = string
			}
			sb = ([^]u8)(string)
			j = 0
			for sb[uintptr(j)] != 0 && sb[uintptr(j)] == line[uintptr(i) + uintptr(j)] {
				j += 1
			}
			if sb[uintptr(j)] != 0 {
				continue
			}
			if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_BLANK_O)) != nil && !ascii_iswhite(line[uintptr(i) + uintptr(j)]) && line[uintptr(i) + uintptr(j)] != 0 {
				continue
			}
			if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_MIDDLE_O)) != nil {
				k: C.int = 0
				for k <= i && ascii_iswhite(line[uintptr(k)]) {
					k += 1
				}
				if k < i {
					continue
				}
			}
			found_one = true
			if flags != nil {
				flags^ = flags_save
			}
			com_flags = flags_save
			break
		}
		if found_one {
			part_buf2: [COM_MAX_LEN_O]u8
			result = i
			if vim_strchr(transmute(^u8)(&part_buf[0]), C.int(COM_NEST_O)) != nil {
				i -= 1
				continue
			}
			lower_check_bound = i
			sb := ([^]u8)(com_leader)
			for ascii_iswhite(sb[0]) {
				sb = ([^]u8)(rawptr(uintptr(sb) + 1))
			}
			com_leader = transmute(^u8)(rawptr(sb))
			len1 := C.int(libc.strlen(transmute(cstring)(com_leader)))
			list2 := (^^u8)(uintptr(curbuf) + B_P_COM_OFF)^
			for (([^]u8)(list2))[0] != 0 {
				flags_save := list2
				copy_option_part(&list2, transmute(^u8)(&part_buf2[0]), COM_MAX_LEN_O, cstring(","))
				if flags_save == com_flags {
					continue
				}
				string := vim_strchr(transmute(^u8)(&part_buf2[0]), C.int(':'))
				string = transmute(^u8)(rawptr(uintptr(string) + 1))
				sb = ([^]u8)(string)
				for ascii_iswhite(sb[0]) {
					sb = ([^]u8)(rawptr(uintptr(sb) + 1))
				}
				len2 := C.int(libc.strlen(transmute(cstring)(rawptr(sb))))
				if len2 == 0 {
					continue
				}
				off := len2
				if off > i {
					off = i
				}
				for off > 0 && off + len1 > len2 {
					off -= 1
					if libc.strncmp(transmute(cstring)(rawptr(uintptr(sb) + uintptr(off))), transmute(cstring)(com_leader), C.size_t(len2 - off)) == 0 {
						if i - off < lower_check_bound {
							lower_check_bound = i - off
						}
					}
				}
			}
			i -= 1
		} else {
			i -= 1
		}
	}
	return result
}

@(export)
open_line :: proc "c" (dir: C.int, flags: C.int, second_line_indent: C.int, did_do_comment: ^bool) -> bool {
	context = runtime.default_context()
	next_line: ^u8 = nil
	p_extra: ^u8 = nil
	less_cols: C.int = 0
	less_cols_off: C.int = 0
	old_cursor: Pos_T
	newcol: C.int = 0
	newindent: C.int = 0
	trunc_line := false
	retval := false
	extra_len: C.int = 0
	lead_len: C.int = 0
	comment_start: C.int = 0
	lead_flags: ^u8 = nil
	leader: ^u8 = nil
	allocated: ^u8 = nil
	p: ^u8 = nil
	saved_char: u8 = 0
	pos: ^Pos_T = nil
	do_si := may_do_si()
	no_si := false
	first_char: C.int = 0
	vreplace_mode: C.int = 0
	did_append := false
	old_cmod_flags: C.int = 0
	prompt_moved: ^u8 = nil
	saved_pi := (^C.int)(uintptr(curbuf) + B_P_PI_OFF)^
	lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	mincol := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ + 1
	saved_line := xstrnsave_c(transmute(cstring)(get_cursor_line_ptr()), C.size_t(get_cursor_line_len()))
	if (State & VREPLACE_FLAG_O) != 0 {
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < orig_line_count_g {
			next_line = xstrnsave_c(transmute(cstring)(ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1)), C.size_t(ml_get_len((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1)))
		} else {
			next_line = xstrdup(transmute(^u8)(cstring("")))
		}
		replace_push_nul_e()
		replace_push_nul_e()
		p = transmute(^u8)(rawptr(uintptr(saved_line) + uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)))
		replace_push_e(p, C.size_t(libc.strlen(transmute(cstring)(p))))
		([^]u8)(saved_line)[uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)] = 0
	}
	if (State & MODE_INSERT) != 0 && (State & VREPLACE_FLAG_O) == 0 {
		p_extra = transmute(^u8)(rawptr(uintptr(saved_line) + uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)))
		if do_si {
			p = transmute(^u8)(skipwhite(transmute(cstring)(p_extra)))
			first_char = C.int(([^]u8)(p)[0])
		}
		extra_len = C.int(libc.strlen(transmute(cstring)(p_extra)))
		saved_char = ([^]u8)(p_extra)[0]
		([^]u8)(p_extra)[0] = 0
	}
	u_clearline(curbuf)
	did_si_g = false
	ai_col_g = 0
	if dir == FORWARD_O && did_ai_g {
		trunc_line = true
	}
	if (flags & OPENLINE_FORCE_INDENT_O) != 0 {
		newindent = second_line_indent
	} else if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 || do_si {
		vts := (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
		newindent = indent_size_ts(transmute(cstring)(saved_line), (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, vts)
		if newindent == 0 && (flags & OPENLINE_COM_LIST_O) == 0 {
			newindent = second_line_indent
		}
		if !trunc_line && do_si && ([^]u8)(saved_line)[0] != 0 {
			paren_ok := false
			if p_extra == nil {
				paren_ok = true
			}
			if p_extra != nil && first_char != '{' {
				paren_ok = true
			}
			if paren_ok {
			old_cursor = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			ptr := saved_line
			if (flags & OPENLINE_DO_COM_O) != 0 {
				lead_len = get_leader_len(ptr, nil, false, true)
			} else {
				lead_len = 0
			}
			if dir == FORWARD_O {
				if lead_len == 0 && ([^]u8)(ptr)[0] == '#' {
					for ([^]u8)(ptr)[0] == '#' && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > 1 {
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
						ptr = ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
					}
					newindent = get_indent()
				}
				if (flags & OPENLINE_DO_COM_O) != 0 {
					lead_len = get_leader_len(ptr, nil, false, true)
				} else {
					lead_len = 0
				}
				if lead_len > 0 {
					p = transmute(^u8)(skipwhite(transmute(cstring)(ptr)))
					if ([^]u8)(p)[0] == '/' && ([^]u8)(p)[1] == '*' {
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					}
					if ([^]u8)(p)[0] == '*' {
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
						for ([^]u8)(p)[0] != 0 {
							if ([^]u8)(p)[0] == '/' && ([^]u8)(rawptr(uintptr(p) - 1))[0] == '*' {
								(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = C.int(uintptr(p) - uintptr(ptr))
								pos = findmatch(nil, 0)
								if pos != nil {
									(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = pos.lnum
									newindent = get_indent()
									break
								}
								ptr = ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
								p = transmute(^u8)(rawptr(uintptr(ptr) + uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)))
							}
							p = transmute(^u8)(rawptr(uintptr(p) + 1))
						}
					}
				} else {
					p = transmute(^u8)(rawptr(uintptr(ptr) + uintptr(C.int(libc.strlen(transmute(cstring)(ptr)))) - 1))
					for uintptr(p) > uintptr(ptr) && ascii_iswhite(([^]u8)(p)[0]) {
						p = transmute(^u8)(rawptr(uintptr(p) - 1))
					}
					last_char := ([^]u8)(p)[0]
					if last_char == '{' || last_char == ';' {
						if uintptr(p) > uintptr(ptr) {
							p = transmute(^u8)(rawptr(uintptr(p) - 1))
						}
						for uintptr(p) > uintptr(ptr) && ascii_iswhite(([^]u8)(p)[0]) {
							p = transmute(^u8)(rawptr(uintptr(p) - 1))
						}
					}
					if ([^]u8)(p)[0] == ')' {
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = C.int(uintptr(p) - uintptr(ptr))
						pos = findmatch(nil, C.int('('))
						if pos != nil {
							(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = pos.lnum
							newindent = get_indent()
							ptr = get_cursor_line_ptr()
						}
					}
					if last_char == '{' {
						did_si_g = true
						no_si = true
					} else if last_char != ';' && last_char != '}' && cin_is_cinword(transmute(cstring)(ptr)) {
						did_si_g = true
					}
				}
			} else {
				if lead_len == 0 && ([^]u8)(ptr)[0] == '#' {
					was_backslashed := false
					more_dirs := true
					for more_dirs && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < (^Memline_O)(uintptr(curbuf) + 8).line_count {
						more_dirs = false
						if ([^]u8)(ptr)[0] == '#' {
							more_dirs = true
						}
						if was_backslashed {
							more_dirs = true
						}
						if more_dirs == false {
							break
						}
						if ([^]u8)(ptr)[0] != 0 {
							sllen := C.int(libc.strlen(transmute(cstring)(ptr)))
							if sllen > 0 && ([^]u8)(ptr)[uintptr(sllen) - 1] == '\\' {
								was_backslashed = true
							} else {
								was_backslashed = false
							}
						} else {
							was_backslashed = false
						}
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
						ptr = ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
					}
					if was_backslashed {
						newindent = 0
					} else {
						newindent = get_indent()
					}
				}
				p = transmute(^u8)(skipwhite(transmute(cstring)(ptr)))
				if ([^]u8)(p)[0] == '}' {
					did_si_g = true
				} else {
					can_si_back_g = true
				}
			}
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_cursor
			}
		}
		if do_si {
			can_si_g = true
		}
		did_ai_g = true
	}
	key: C.int = KEY_OPEN_FORW_O
	if dir != FORWARD_O {
		key = KEY_OPEN_BACK_O
	}
	inde_slot := (^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^
	inde_has := false
	inde_byte := ([^]u8)(transmute(rawptr)(inde_slot))[0]
	if inde_byte != 0 {
		inde_has = true
	}
	cin_on := false
	if (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ != 0 {
		cin_on = true
	}
	if inde_has {
		cin_on = true
	}
	do_cindent := p_paste_g == 0 && cin_on && in_cinkeys(key, C.int(' '), linewhite((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)) && (flags & OPENLINE_FORCE_INDENT_O) == 0
	end_comment_pending_g = 0
	if (flags & OPENLINE_DO_COM_O) != 0 {
		lead_len = get_leader_len(saved_line, &lead_flags, dir == BACKWARD_O, true)
		fmt_ok := has_format_option(C.int(FO_NO_OPEN_COMS_O)) == false
		if (flags & OPENLINE_FORMAT_O) != 0 {
			fmt_ok = true
		}
		if lead_len == 0 && (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ != 0 && do_cindent && dir == FORWARD_O && fmt_ok {
			comment_start = check_linecomment(transmute(cstring)(saved_line))
			if comment_start != MAXCOL {
				lead_len = get_leader_len(transmute(^u8)(rawptr(uintptr(saved_line) + uintptr(comment_start))), &lead_flags, false, true)
				if lead_len != 0 {
					lead_len += comment_start
					if did_do_comment != nil {
						did_do_comment^ = true
					}
				}
			}
		}
	} else {
		lead_len = 0
	}
	if lead_len > 0 {
		lead_repl: ^u8 = nil
		lead_repl_len: C.int = 0
		lead_middle: [COM_MAX_LEN_O]u8
		lead_middle_len: C.int = 0
		lead_end: [COM_MAX_LEN_O]u8
		comment_end: ^u8 = nil
		extra_space: C.int = 0
		require_blank := false
		p2: ^u8 = nil
		p = lead_flags
		for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != ':' {
			c0 := ([^]u8)(p)[0]
			if c0 == COM_BLANK_O {
				require_blank = true
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				continue
			}
			if c0 == COM_START_O || c0 == COM_MIDDLE_O {
				current_flag := C.int(c0)
				if c0 == COM_START_O {
					if dir == BACKWARD_O {
						lead_len = 0
						break
					}
					copy_option_part(&p, transmute(^u8)(&lead_middle[0]), COM_MAX_LEN_O, cstring(","))
					require_blank = false
				}
				for ([^]u8)(p)[0] != 0 && ([^]u8)(rawptr(uintptr(p) - 1))[0] != ':' {
					if ([^]u8)(p)[0] == COM_BLANK_O {
						require_blank = true
					}
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
				lead_middle_len = C.int(copy_option_part(&p, transmute(^u8)(&lead_middle[0]), COM_MAX_LEN_O, cstring(",")))
				for ([^]u8)(p)[0] != 0 && ([^]u8)(rawptr(uintptr(p) - 1))[0] != ':' {
					if ([^]u8)(p)[0] == COM_AUTO_END_O {
						end_comment_pending_g = -1
					}
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
				n := C.int(copy_option_part(&p, transmute(^u8)(&lead_end[0]), COM_MAX_LEN_O, cstring(",")))
				if end_comment_pending_g == -1 {
					end_comment_pending_g = C.int(([^]u8)(rawptr(&lead_end[0]))[uintptr(n) - 1])
				}
				if dir == FORWARD_O {
					sp := transmute(^u8)(rawptr(uintptr(saved_line) + uintptr(lead_len)))
					for ([^]u8)(sp)[0] != 0 {
						if libc.strncmp(transmute(cstring)(sp), transmute(cstring)(rawptr(&lead_end[0])), C.size_t(n)) == 0 {
							comment_end = sp
							lead_len = 0
							break
						}
						sp = transmute(^u8)(rawptr(uintptr(sp) + 1))
					}
				}
				if lead_len > 0 {
					if current_flag == C.int(COM_START_O) {
						lead_repl = transmute(^u8)(&lead_middle[0])
						lead_repl_len = lead_middle_len
					}
					sp_cond := false
					if p_extra != nil && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == lead_len {
						sp_cond = true
					}
					if p_extra == nil && ([^]u8)(saved_line)[uintptr(lead_len)] == 0 {
						sp_cond = true
					}
					if require_blank {
						sp_cond = true
					}
					if ascii_iswhite(([^]u8)(saved_line)[uintptr(lead_len) - 1]) == false && sp_cond {
						extra_space = 1
					}
				}
				break
			}
			if c0 == COM_END_O {
				if dir == FORWARD_O {
					comment_end = transmute(^u8)(skipwhite(transmute(cstring)(saved_line)))
					lead_len = 0
					break
				}
				bcom := (^u8)((^rawptr)(uintptr(curbuf) + B_P_COM_OFF)^)
				for uintptr(p) > uintptr(bcom) && ([^]u8)(p)[0] != ',' {
					p = transmute(^u8)(rawptr(uintptr(p) - 1))
				}
				lead_repl = p
				for uintptr(lead_repl) > uintptr(bcom) && ([^]u8)(rawptr(uintptr(lead_repl) - 1))[0] != ':' {
					lead_repl = transmute(^u8)(rawptr(uintptr(lead_repl) - 1))
				}
				lead_repl_len = C.int(uintptr(p) - uintptr(lead_repl))
				extra_space = 1
				p2 = p
				for ([^]u8)(p2)[0] != 0 && ([^]u8)(p2)[0] != ':' {
					if ([^]u8)(p2)[0] == COM_AUTO_END_O {
						end_comment_pending_g = -1
					}
					p2 = transmute(^u8)(rawptr(uintptr(p2) + 1))
				}
				if end_comment_pending_g == -1 {
					for ([^]u8)(p2)[0] != 0 && ([^]u8)(p2)[0] != ',' {
						p2 = transmute(^u8)(rawptr(uintptr(p2) + 1))
					}
					end_comment_pending_g = C.int(([^]u8)(rawptr(uintptr(p2) - 1))[0])
				}
				break
			}
			if c0 == COM_FIRST_O {
				if dir == BACKWARD_O {
					lead_len = 0
				} else {
					lead_repl = transmute(^u8)(cstring(""))
					lead_repl_len = 0
				}
				break
			}
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
		if lead_len > 0 {
			pad := second_line_indent
			if pad <= 0 {
				pad = 0
			}
			bytes := lead_len + lead_repl_len + extra_space + extra_len + pad + 1
			if bytes < 0 {
				libc.abort()
			}
			leader = transmute(^u8)(xmalloc(C.size_t(bytes)))
			allocated = leader
			xmemcpyz(rawptr(leader), rawptr(saved_line), C.size_t(lead_len))
			for li: C.int = 0; li < comment_start; li += 1 {
				if ascii_iswhite(([^]u8)(leader)[uintptr(li)]) == false {
					([^]u8)(leader)[uintptr(li)] = ' '
				}
			}
			if lead_repl != nil {
				cr: C.int = 0
				off: C.int = 0
				p = lead_flags
				for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != ':' {
					pc := ([^]u8)(p)[0]
					if pc == COM_RIGHT_O || pc == COM_LEFT_O {
						cr = C.int(pc)
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					} else if ascii_isdigit(pc) || pc == '-' {
						off = getdigits_int(&p, true, 0)
					} else {
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					}
				}
				if cr == C.int(COM_RIGHT_O) {
					p = transmute(^u8)(rawptr(uintptr(leader) + uintptr(lead_len) - 1))
					for uintptr(p) > uintptr(leader) && ascii_iswhite(([^]u8)(p)[0]) {
						p = transmute(^u8)(rawptr(uintptr(p) - 1))
					}
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
					{
						repl_size := vim_strnsize(transmute(cstring)(lead_repl), lead_repl_len)
						old_size: C.int = 0
						endp := p
						for old_size < repl_size && uintptr(p) > uintptr(leader) {
							p = transmute(^u8)(rawptr(uintptr(p) - uintptr(C.int(utf_head_off(transmute(cstring)(leader), transmute(cstring)(rawptr(uintptr(p) - 1)))) + 1)))
							old_size += ptr2cells(transmute(cstring)(p))
						}
						l := lead_repl_len - C.int(uintptr(endp) - uintptr(p))
						if l != 0 {
							libc.memmove(rawptr(uintptr(endp) + uintptr(l)), rawptr(endp), C.size_t(uintptr(leader) + uintptr(lead_len) - uintptr(endp)))
						}
						lead_len += l
					}
					libc.memmove(rawptr(p), rawptr(lead_repl), C.size_t(lead_repl_len))
					if uintptr(p) + uintptr(lead_repl_len) > uintptr(leader) + uintptr(lead_len) {
						([^]u8)(p)[uintptr(lead_repl_len)] = 0
					}
					for {
						p = transmute(^u8)(rawptr(uintptr(p) - 1))
						if uintptr(p) < uintptr(leader) {
							break
						}
						l := C.int(utf_head_off(transmute(cstring)(leader), transmute(cstring)(p)))
						if l > 1 {
							p = transmute(^u8)(rawptr(uintptr(p) - uintptr(l)))
							if ptr2cells(transmute(cstring)(p)) > 1 {
								([^]u8)(p)[1] = ' '
								l -= 1
							}
							libc.memmove(rawptr(uintptr(p) + 1), rawptr(uintptr(p) + uintptr(l) + 1), C.size_t(uintptr(leader) + uintptr(lead_len) - (uintptr(p) + uintptr(l) + 1)))
							lead_len -= l
							([^]u8)(p)[0] = ' '
						} else if ascii_iswhite(([^]u8)(p)[0]) == false {
							([^]u8)(p)[0] = ' '
						}
					}
				} else {
					p = transmute(^u8)(skipwhite(transmute(cstring)(leader)))
					{
						repl_size := vim_strnsize(transmute(cstring)(lead_repl), lead_repl_len)
						la_i: C.int = 0
						la_l: C.int = 1
						for la_i < lead_len && ([^]u8)(p)[uintptr(la_i)] != 0 {
							la_l = utfc_ptr2len(transmute(cstring)(rawptr(uintptr(p) + uintptr(la_i))))
							if vim_strnsize(transmute(cstring)(p), la_i + la_l) > repl_size {
								break
							}
							la_i += la_l
						}
						if la_i != lead_repl_len {
							libc.memmove(rawptr(uintptr(p) + uintptr(lead_repl_len)), rawptr(uintptr(p) + uintptr(la_i)), C.size_t(lead_len - la_i - C.int(uintptr(p) - uintptr(leader))))
							lead_len += lead_repl_len - la_i
						}
					}
					libc.memmove(rawptr(p), rawptr(lead_repl), C.size_t(lead_repl_len))
					p = transmute(^u8)(rawptr(uintptr(p) + uintptr(lead_repl_len)))
					for uintptr(p) < uintptr(leader) + uintptr(lead_len) {
						if ascii_iswhite(([^]u8)(p)[0]) == false {
							if uintptr(p) + 1 < uintptr(leader) + uintptr(lead_len) && ([^]u8)(p)[1] == TAB_O {
								lead_len -= 1
								libc.memmove(rawptr(p), rawptr(uintptr(p) + 1), C.size_t(uintptr(leader) + uintptr(lead_len) - uintptr(p)))
							} else {
								l := utfc_ptr2len(transmute(cstring)(p))
								if l > 1 {
									if ptr2cells(transmute(cstring)(p)) > 1 {
										l -= 1
										([^]u8)(p)[0] = ' '
										p = transmute(^u8)(rawptr(uintptr(p) + 1))
									}
									libc.memmove(rawptr(uintptr(p) + 1), rawptr(uintptr(p) + uintptr(l)), C.size_t(uintptr(leader) + uintptr(lead_len) - uintptr(p)))
									lead_len -= l - 1
								}
								([^]u8)(p)[0] = ' '
							}
						}
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					}
					([^]u8)(p)[0] = 0
				}
				if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 || do_si {
					vts2 := (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
					newindent = indent_size_ts(transmute(cstring)(leader), (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^, vts2)
				}
				if newindent + off < 0 {
					off = -newindent
					newindent = 0
				} else {
					newindent += off
				}
				for off > 0 && lead_len > 0 && ([^]u8)(leader)[uintptr(lead_len) - 1] == ' ' {
					if vim_strchr(transmute(^u8)(skipwhite(transmute(cstring)(leader))), C.int('\t')) != nil {
						break
					}
					lead_len -= 1
					off -= 1
				}
				if lead_len > 0 && ascii_iswhite(([^]u8)(leader)[uintptr(lead_len) - 1]) {
					extra_space = 0
				}
				([^]u8)(leader)[uintptr(lead_len)] = 0
			}
			if extra_space != 0 {
				([^]u8)(leader)[uintptr(lead_len)] = ' '
				lead_len += 1
				([^]u8)(leader)[uintptr(lead_len)] = 0
			}
			newcol = lead_len
			if newindent != 0 || did_si_g {
				for lead_len != 0 && ascii_iswhite(([^]u8)(leader)[0]) {
					lead_len -= 1
					newcol -= 1
					leader = transmute(^u8)(rawptr(uintptr(leader) + 1))
				}
			}
			did_si_g = false
			can_si_g = false
		} else if comment_end != nil {
			ce_ok := false
			if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 {
				ce_ok = true
			}
			if do_si {
				ce_ok = true
			}
			if ([^]u8)(comment_end)[0] == '*' && ([^]u8)(comment_end)[1] == '/' && ce_ok {
				old_cursor = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = C.int(uintptr(comment_end) - uintptr(saved_line))
				pos = findmatch(nil, 0)
				if pos != nil {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = pos.lnum
					newindent = get_indent()
				}
				(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_cursor
			}
		}
	}
	if p_extra != nil {
		([^]u8)(p_extra)[0] = saved_char
		if (State & REPLACE_FLAG) != 0 && (State & VREPLACE_FLAG_O) == 0 {
			replace_push_nul_e()
		}
		if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 || (flags & OPENLINE_DELSPACES_O) != 0 {
			for {
				c0 := ([^]u8)(p_extra)[0]
				if c0 != ' ' && c0 != '\t' {
					break
				}
				if utf_iscomposing_first(utf_ptr2char(transmute(cstring)(rawptr(uintptr(p_extra) + 1)))) {
					break
				}
				if (State & REPLACE_FLAG) != 0 && (State & VREPLACE_FLAG_O) == 0 {
					replace_push_e(p_extra, C.size_t(1))
				}
				p_extra = transmute(^u8)(rawptr(uintptr(p_extra) + 1))
				less_cols_off += 1
			}
		}
		less_cols = C.int(uintptr(p_extra) - uintptr(saved_line))
	}
	if p_extra == nil {
		p_extra = transmute(^u8)(cstring(""))
	}
	if lead_len > 0 {
		if (flags & OPENLINE_COM_LIST_O) != 0 && second_line_indent > 0 {
			padding := second_line_indent - (newindent + C.int(libc.strlen(transmute(cstring)(leader))))
			for pad_i: C.int = 0; pad_i < padding; pad_i += 1 {
				pl1 := C.int(libc.strlen(transmute(cstring)(leader)))
				([^]u8)(leader)[uintptr(pl1)] = ' '
				([^]u8)(leader)[uintptr(pl1) + 1] = 0
				less_cols -= 1
				newcol += 1
			}
		}
		l1 := C.int(libc.strlen(transmute(cstring)(leader)))
		l2 := C.int(libc.strlen(transmute(cstring)(p_extra)))
		libc.memmove(rawptr(uintptr(leader) + uintptr(l1)), rawptr(p_extra), C.size_t(l2 + 1))
		p_extra = leader
		did_ai_g = true
		less_cols -= lead_len
	} else {
		end_comment_pending_g = 0
	}
	for _ in 0..<1 {
		curbuf_splice_pending_g += 1
		old_cursor = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
		old_cmod_flags = cmdmod_cmod_flags
		prompt_moved = nil
		if dir == BACKWARD_O {
			if bt_prompt(curbuf) && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(curbuf) + B_PROMPT_START)^ {
				prompt_line := ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
				prompt := prompt_text()
				prompt_len := C.int(libc.strlen(transmute(cstring)(prompt)))
				if libc.strncmp(transmute(cstring)(prompt_line), transmute(cstring)(prompt), C.size_t(prompt_len)) == 0 {
					libc.memmove(rawptr(prompt_line), rawptr(uintptr(prompt_line) + uintptr(prompt_len)), C.size_t(C.int(libc.strlen(transmute(cstring)(prompt_line))) - prompt_len + 1))
					cmdmod_cmod_flags = cmdmod_cmod_flags | CMOD_LOCKMARKS_O
					ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, prompt_line, true)
					prompt_moved = concat_str_c(transmute(cstring)(prompt), transmute(cstring)(p_extra))
					p_extra = prompt_moved
				}
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
		}
		if (State & VREPLACE_FLAG_O) == 0 || old_cursor.lnum >= orig_line_count_g {
			if ml_append((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, p_extra, 0, false) == 0 {
				break
			}
			mark_adjust((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1, MAXLNUM, 1, 0, kExtmarkNOOP)
			did_append = true
		} else {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ >= Insstart_g.lnum + vr_lines_changed_g {
				u_save_cursor()
				vr_lines_changed_g += 1
			}
			ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, p_extra, true)
			changed_bytes((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0)
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
			did_append = false
		}
		inhibit_delete_count += 1
		if newindent != 0 || did_si_g {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
			if did_si_g {
				sw := get_sw_value(curbuf)
				if p_sr_g != 0 {
					newindent -= newindent % sw
				}
				newindent += sw
			}
			if (^C.int)(uintptr(curbuf) + B_P_CI_OFF)^ != 0 {
				copy_indent(newindent, saved_line)
				(^C.int)(uintptr(curbuf) + B_P_PI_OFF)^ = 1
			} else {
				set_indent(newindent, SIN_INSERT_O + SIN_NOMARK_O)
			}
			less_cols -= (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
			ai_col_g = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
			if (State & REPLACE_FLAG) != 0 && (State & VREPLACE_FLAG_O) == 0 {
				for rep_n: C.int = 0; rep_n < (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^; rep_n += 1 {
					replace_push_nul_e()
				}
			}
			newcol += (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
			if no_si {
				did_si_g = false
			}
		}
		inhibit_delete_count -= 1
		if (State & REPLACE_FLAG) != 0 && (State & VREPLACE_FLAG_O) == 0 {
			for lead_len > 0 {
				replace_push_nul_e()
				lead_len -= 1
			}
		}
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_cursor
		if dir == FORWARD_O {
			if trunc_line || (State & MODE_INSERT) != 0 {
				([^]u8)(saved_line)[uintptr((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)] = 0
				if trunc_line && (flags & OPENLINE_KEEPTRAIL_O) == 0 {
					truncate_spaces(saved_line, C.size_t((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^))
				}
				ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, saved_line, false)
				new_len := C.int(libc.strlen(transmute(cstring)(saved_line)))
				cols_spliced: C.int = 0
				if new_len < (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ {
					extmark_splice_cols(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, new_len, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ - new_len, 0, kExtmarkUndo)
					cols_spliced = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ - new_len
				}
				saved_line = nil
				if did_append {
					cols_added := mincol - 1 + less_cols_off - less_cols
					extmark_splice(curbuf, lnum - 1, mincol - 1 - cols_spliced, 0, less_cols_off, i64(less_cols_off), 1, cols_added, i64(1 + cols_added), kExtmarkUndo)
					changed_lines(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1, 1, true)
					did_append = false
					if (flags & OPENLINE_MARKFIX_O) != 0 {
						mark_col_adjust((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ + less_cols_off, 1, -less_cols, 0)
					}
				} else {
					changed_bytes((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^)
				}
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = old_cursor.lnum + 1
		}
		if did_append {
			extra := ml_get_len((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
			extmark_splice(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, 0, 0, 0, i64(0), 1, 0, i64(1 + extra), kExtmarkUndo)
			changed_lines(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 1, true)
		}
		curbuf_splice_pending_g -= 1
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = newcol
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
		if (State & VREPLACE_FLAG_O) != 0 {
			vreplace_mode = State
			State = MODE_INSERT
		} else {
			vreplace_mode = 0
		}
		if p_paste_g == 0 {
			b_p_lisp := (^C.int)(uintptr(curbuf) + B_P_LISP_OFF)^
			b_p_ai := (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^
			lisp_ai := b_p_ai != 0 && use_indentexpr_for_lisp()
			if leader == nil && use_indentexpr_for_lisp() == false && b_p_lisp != 0 && b_p_ai != 0 {
				fixthisline(get_lisp_indent)
				ai_col_g = getwhitecols_curline()
			} else if do_cindent || lisp_ai {
				do_c_expr_indent()
				ai_col_g = getwhitecols_curline()
			}
		}
		if vreplace_mode != 0 {
			State = vreplace_mode
		}
		if (State & VREPLACE_FLAG_O) != 0 {
			p_extra = xstrnsave_c(transmute(cstring)(get_cursor_line_ptr()), C.size_t(get_cursor_line_len()))
			ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, next_line, false)
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
			ins_bytes(p_extra)
			xfree(rawptr(p_extra))
			next_line = nil
		}
		retval = true
	}
	(^C.int)(uintptr(curbuf) + B_P_PI_OFF)^ = saved_pi
	xfree(rawptr(saved_line))
	xfree(rawptr(next_line))
	xfree(rawptr(allocated))
	xfree(rawptr(prompt_moved))
	cmdmod_cmod_flags = old_cmod_flags
	return retval
}
