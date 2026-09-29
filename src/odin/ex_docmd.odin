// ex_docmd.odin — port of src/nvim/ex_docmd.c (:edit command path: do_exedit)
package main

import C "core:c"
import "core:c/libc"
import "base:runtime"

// ── Batch 25: do_exedit + is_other_file/ex_pressedreturn statics ────────────
// NOTE: ex_edit (static) dispatches via C's command table — porting it alone
// would change nothing (same class as EXITFREE-only free_titles). It ports
// with the dispatch table. do_exedit is exported and called from diff.c,
// runtime.c + ex_docmd.c split handlers, so the weak override is live.
// (CMD_enew/badd/balt/edit/new/tabnew/tabedit/vnew/split/vsplit/sview/view/
// visual values cc-probed, NOT line arithmetic.)

// (CMD_tabnew already in window.odin:180, cc-probed — reused; the rest are
// cc-probed here, NOT line arithmetic per Batch-21 lesson.)
CMD_ENEW_O :: 148
CMD_BADD_O :: 23
CMD_BALT_O :: 24
CMD_EDIT_O :: 133
CMD_VISUAL_O :: 512
CMD_VIEW_O :: 513
CMD_NEW_O :: 292
CMD_TABEDIT_O :: 459
CMD_VNEW_O :: 521
CMD_SPLIT_O :: 423
CMD_VSPLIT_O :: 523
CMD_SVIEW_O :: 445
K_UICMDLINE_O :: C.int(0) // ui_defs.h kUICmdline

foreign _ {
	@(link_name = "pending_exmode_active")
	pending_exmode_active_g: bool
	@(link_name = "ex_no_reprint")
	ex_no_reprint_g: bool
	@(link_name = "ui_ext_cmdline_block_leave")
	ui_ext_cmdline_block_leave_r :: proc "c"() ---
}

// Check if ffname differs from fnum (ex_docmd.c static, plain).
is_other_file_o :: proc "c"(fnum: C.int, ffname: cstring) -> bool {
	if fnum != 0 {
		if fnum == (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ {
			return false
		}

		return true
	}

	if ffname == nil {
		return true
	}

	if ([^]u8)(transmute(^u8)(ffname))[0] == 0 {
		return false
	}

	if (^bool)(uintptr(curbuf) + B_FILE_ID_VALID_OFF)^ == false &&
		(^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^ != nil &&
		([^]u8)((^u8)((^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^))[0] != 0 {
		// Unsaved buffer: ffname corresponds to curbuf->b_sfname.
		return _path_fnamecmp(ffname,
			cstring((^u8)((^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^))) != 0
	}

	return otherfile(ffname)
}

// ":edit <file>" command and alike.
//
// @param old_curwin  curwin before doing a split or NULL
@(export)
do_exedit :: proc "c"(eap: rawptr, old_curwin: rawptr) {
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	arg := (^cstring)(uintptr(eap))^
	// ":vi" command ends Ex mode.
	if exmode_active && (cmdidx == CMD_VISUAL_O || cmdidx == CMD_VIEW_O) {
		exmode_active = false
		ex_pressedreturn = false
		if ui_has(K_UICMDLINE_O) {
			ui_ext_cmdline_block_leave_r()
		}
		if ([^]u8)(transmute(^u8)(arg))[0] == 0 {
			// Special case: ":global/pat/visual\NLvi-commands".
			if global_busy != 0 {
				nextcmd := (^rawptr)(uintptr(eap) + 32)^
				if nextcmd != nil {
					stuffReadbuff_r(cstring(transmute(^u8)(nextcmd)))
					(^rawptr)(uintptr(eap) + 32)^ = nil
				}

				save_rd := RedrawingDisabled
				RedrawingDisabled = 0
				save_nwr := no_wait_return
				no_wait_return = 0
				need_wait_return_g = false
				save_ms := msg_scroll
				msg_scroll = 0
				redraw_all_later(UPD_NOT_VALID)
				pending_exmode_active_g = true

				normal_enter(true)

				pending_exmode_active_g = false
				RedrawingDisabled = save_rd
				no_wait_return = save_nwr
				msg_scroll = save_ms
			}
			return
		}
	}

	if (cmdidx == CMD_NEW_O || cmdidx == CMD_TABNEW_O ||
		cmdidx == CMD_TABEDIT_O || cmdidx == CMD_VNEW_O) &&
		([^]u8)(transmute(^u8)(arg))[0] == 0 {
		// ":new"/":tabnew" without argument: edit a new empty buffer.
		setpcmark()
		do_ecmd(0, nil, nil, eap, ECMD_ONE_O,
			ECMD_HIDE_O + ((^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 ? ECMD_FORCEIT_O : 0),
			old_curwin == nil ? curwin : nil)
	} else if (cmdidx != CMD_SPLIT_O && cmdidx != CMD_VSPLIT_O) ||
		([^]u8)(transmute(^u8)(arg))[0] != 0 {
		// Can't edit another file when "textlock" or "curbuf->b_ro_locked".
		// Only ":edit"/":script" get here; others stop earlier.
		if ([^]u8)(transmute(^u8)(arg))[0] != 0 && text_or_buf_locked_r() {
			return
		}
		n := readonlymode_g
		if cmdidx == CMD_VIEW_O || cmdidx == CMD_SVIEW_O {
			readonlymode_g = true
		} else if cmdidx == CMD_ENEW_O {
			readonlymode_g = false // 'readonly' is meaningless when empty
		}
		if cmdidx != CMD_BALT_O && cmdidx != CMD_BADD_O {
			setpcmark()
		}
		lnum := (^C.int)(uintptr(eap) + 112)^
		if do_ecmd(0, cmdidx == CMD_ENEW_O ? nil : arg, nil, eap, lnum,
			(buf_hide(curbuf) ? ECMD_HIDE_O : 0) +
			((^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 ? ECMD_FORCEIT_O : 0) +
			// After a split an existing buffer may be used.
			(old_curwin != nil ? ECMD_OLDBUF_O : 0) +
			(cmdidx == CMD_BADD_O ? ECMD_ADDBUF_O : 0) +
			(cmdidx == CMD_BALT_O ? ECMD_ALTBUF_O : 0),
			old_curwin == nil ? curwin : nil) == FAIL {
			// Editing failed. If the window was split, close it.
			if old_curwin != nil {
				need_hide := curbufIsChanged() &&
					(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ <= 1
				if !need_hide || buf_hide(curbuf) {
					cs: [16]u8

					// Reset error state so aborting() is false
					// when closing the window.
					enter_cleanup_r(&cs[0])
					win_close(curwin,
						!need_hide && !buf_hide(curbuf), false)

					// Restore error state unless discarded.
					leave_cleanup_r(&cs[0])
				}
			}
		} else if readonlymode_g &&
			(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ == 1 {
			// Visited buffer keeps old 'readonly'; ":view"/":sview"
			// force it (unless shared with another window).
			(^C.int)(uintptr(curbuf) + B_P_RO_OFF)^ = 1
		}
		readonlymode_g = n
	} else {
		do_ecmd_cmd := (^rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)^
		if do_ecmd_cmd != nil {
			do_cmdline_cmd(cstring(transmute(^u8)(do_ecmd_cmd)))
		}
		n := (^C.int)(uintptr(curwin) + W_ARG_IDX_INVALID_OFF)^
		check_arg_idx_r(curwin)
		if n != (^C.int)(uintptr(curwin) + W_ARG_IDX_INVALID_OFF)^ {
			maketitle()
		}
	}

	// ":split file" worked: alternate file of old window is the new file.
	if old_curwin != nil &&
		([^]u8)(transmute(^u8)(arg))[0] != 0 &&
		curwin != old_curwin &&
		win_valid(old_curwin) &&
		(^rawptr)(uintptr(old_curwin) + W_BUFFER_OFF)^ != curbuf &&
		(cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
		(^C.int)(uintptr(old_curwin) + W_ALT_FNUM)^ =
			(^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	}

	ex_no_reprint_g = true
}

// —— Batch 1: ex_docmd.c separator/name leaves (exports + weak) ——

// Ex-command separator test (ex_docmd.c public).
@(export)
ends_excmd :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	if c == 0 || c == '|' || c == '"' || c == '\n' {
		return 1
	}
	return 0
}

// Text after next '|'/'\\n' (ex_docmd.c public).
@(export)
find_nextcmd :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for ([^]u8)(cur)[0] != '|' && ([^]u8)(cur)[0] != '\n' {
		if ([^]u8)(cur)[0] == 0 {
			return nil
		}
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return transmute(cstring)(uintptr(rawptr(cur)) + 1)
}

// Separator skipper (ex_docmd.c public).
@(export)
check_nextcmd :: proc "c" (p: ^u8) -> ^u8 {
	context = runtime.default_context()
	s := transmute(cstring)(skipwhite(transmute(cstring)(p)))
	if ([^]u8)(s)[0] == '|' || ([^]u8)(s)[0] == '\n' {
		return transmute(^u8)(uintptr(rawptr(s)) + 1)
	}
	return nil
}

// Expression-args command test (ex_docmd.c public).
@(export)
cmd_has_expr_args :: proc "c" (cmdidx: C.int) -> bool {
	context = runtime.default_context()
	return cmdidx == CMD_EXECUTE_O || cmdidx == CMD_ECHO_O || cmdidx == CMD_ECHON_O || cmdidx == CMD_ECHOMSG_O || cmdidx == CMD_ECHOERR_O
}

// Command-word matcher (ex_docmd.c public).
@(export)
checkforcmd :: proc "c" (pp: ^cstring, cmd: cstring, len: C.int) -> bool {
	context = runtime.default_context()
	i: C.int = 0
	for ([^]u8)(cmd)[uintptr(i)] != 0 {
		if ([^]u8)(cmd)[uintptr(i)] != ([^]u8)(pp^)[uintptr(i)] {
			break
		}
		i += 1
	}
	if i >= len && !ascii_isalpha_o(([^]u8)(pp^)[uintptr(i)]) {
		pp^ = skipwhite(transmute(cstring)(uintptr(rawptr(pp^)) + uintptr(i)))
		return true
	}
	return false
}

// Colon/whitespace skipper (ex_docmd.c static).
skip_colon_white_o :: proc "c" (p: cstring, skipleadingwhite: bool) -> cstring {
	context = runtime.default_context()
	cur := p
	if skipleadingwhite {
		cur = skipwhite(cur)
	}
	for ([^]u8)(cur)[0] == ':' {
		cur = skipwhite(transmute(cstring)(uintptr(rawptr(cur)) + 1))
	}
	return cur
}

// Range-specifier skipper (ex_docmd.c public).
@(export)
skip_range :: proc "c" (cmd: cstring, ctx: ^C.int) -> cstring {
	context = runtime.default_context()
	p := cmd
	for _vim_strchr(cstring(" \t0123456789.$%'/?-+,;\\"), C.int(([^]u8)(p)[0])) != nil {
		if ([^]u8)(p)[0] == '\\' {
			if ([^]u8)(p)[1] == '?' || ([^]u8)(p)[1] == '/' || ([^]u8)(p)[1] == '&' {
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			} else {
				break
			}
		} else if ([^]u8)(p)[0] == '\'' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			if ([^]u8)(p)[0] == 0 && ctx != nil {
				ctx^ = EXPAND_NOTHING_S
			}
		} else if ([^]u8)(p)[0] == '/' || ([^]u8)(p)[0] == '?' {
			delim := ([^]u8)(p)[0]
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != delim {
				if ([^]u8)(p)[0] == '\\' && ([^]u8)(p)[1] != 0 {
					p = transmute(cstring)(uintptr(rawptr(p)) + 1)
				}
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
			if ([^]u8)(p)[0] == 0 && ctx != nil {
				ctx^ = EXPAND_NOTHING_S
			}
		}
		if ([^]u8)(p)[0] != 0 {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
	}
	p = skip_colon_white_o(p, false)
	if ([^]u8)(p)[0] == '*' {
		p = skipwhite(transmute(cstring)(uintptr(rawptr(p)) + 1))
	}
	return p
}

// —— Batch 2: ex_docmd.c range cluster (exports + weak) ——
foreign _ {
	@(link_name = "qf_get_valid_size")
	qf_get_valid_size_e :: proc "c" (eap: rawptr) -> C.size_t ---
	@(link_name = "qf_get_cur_idx")
	qf_get_cur_idx_e :: proc "c" (eap: rawptr) -> C.size_t ---
	@(link_name = "qf_get_cur_valid_idx")
	qf_get_cur_valid_idx_e :: proc "c" (eap: rawptr) -> C.int ---
}
EXARG_ADDR_TYPE_OFF :: 92
ADDR_LINES_O :: 0
ADDR_WINDOWS_O :: 1
ADDR_ARGUMENTS_O :: 2
ADDR_LOADED_BUFFERS_O :: 3
ADDR_BUFFERS_O :: 4
ADDR_TABS_O :: 5
ADDR_TABS_RELATIVE_O :: 6
ADDR_QUICKFIX_VALID_O :: 7
ADDR_QUICKFIX_O :: 8
ADDR_UNSIGNED_O :: 9
ADDR_OTHER_O :: 10
ADDR_NONE_O :: 11

// Window-number counter (ex_docmd.c static).
current_win_nr_o :: proc "c" (win: rawptr) -> C.int {
	context = runtime.default_context()
	nr: C.int = 0
	// FOR_ALL_WINDOWS_IN_TAB(wp, curtab): curtab walks firstwin.
	wp := firstwin
	for wp != nil {
		nr += 1
		if wp == win {
			break
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return nr
}

// Tabpage-number counter (ex_docmd.c static).
current_tab_nr_o :: proc "c" (tab: rawptr) -> C.int {
	context = runtime.default_context()
	nr: C.int = 0
	tp := first_tabpage
	for tp != nil {
		nr += 1
		if tp == tab {
			break
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	return nr
}

// Default range number by address type (ex_docmd.c public).
@(export)
get_cmd_default_range :: proc "c" (eap: rawptr) -> C.int {
	context = runtime.default_context()
	addr_type := (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^
	if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
		lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
		if lnum < line_count {
			return lnum
		}
		return line_count
	} else if addr_type == ADDR_WINDOWS_O {
		return current_win_nr_o(curwin)
	} else if addr_type == ADDR_ARGUMENTS_O {
		arg_idx := (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
		arg_count := (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^) + 0)^
		if arg_idx + 1 < arg_count {
			return arg_idx + 1
		}
		return arg_count
	} else if addr_type == ADDR_LOADED_BUFFERS_O || addr_type == ADDR_BUFFERS_O {
		return (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	} else if addr_type == ADDR_TABS_O {
		return current_tab_nr_o(curtab)
	} else if addr_type == ADDR_TABS_RELATIVE_O || addr_type == ADDR_UNSIGNED_O {
		return 1
	} else if addr_type == ADDR_QUICKFIX_O {
		return C.int(qf_get_cur_idx_e(eap))
	} else if addr_type == ADDR_QUICKFIX_VALID_O {
		return qf_get_cur_valid_idx_e(eap)
	}
	return 0
}

// Default % range by address type (ex_docmd.c public).
@(export)
set_cmd_dflall_range :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = 1
	addr_type := (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^
	if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	} else if addr_type == ADDR_LOADED_BUFFERS_O {
		buf := firstbuf
		for (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ != nil && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
		(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
		buf = lastbuf_g
		for (^rawptr)(uintptr(buf) + B_PREV_OFF)^ != nil && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
			buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
		}
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
	} else if addr_type == ADDR_BUFFERS_O {
		(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = (^C.int)(uintptr(firstbuf) + B_FNUM_OFF)^
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = (^C.int)(uintptr(lastbuf_g) + B_FNUM_OFF)^
	} else if addr_type == ADDR_WINDOWS_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = current_win_nr_o(nil)
	} else if addr_type == ADDR_TABS_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = current_tab_nr_o(nil)
	} else if addr_type == ADDR_TABS_RELATIVE_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = 1
	} else if addr_type == ADDR_ARGUMENTS_O {
		arg_count := (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^) + 0)^
		if arg_count == 0 {
			(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = 0
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = 0
		} else {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = arg_count
		}
	} else if addr_type == ADDR_QUICKFIX_VALID_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = C.int(qf_get_valid_size_e(eap))
		if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ == 0 {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = 1
		}
	} else if addr_type == ADDR_NONE_O || addr_type == ADDR_UNSIGNED_O || addr_type == ADDR_QUICKFIX_O {
		iemsg_r(cstring("INTERNAL: Cannot use EX_DFLALL with ADDR_NONE, ADDR_UNSIGNED or ADDR_QUICKFIX"))
	}
}

// Count-to-range applier (ex_docmd.c public).
@(export)
set_cmd_count :: proc "c" (eap: rawptr, count: C.int, validate: bool) {
	context = runtime.default_context()
	if (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ != ADDR_LINES_O {
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = count
		if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ == 0 {
			(^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ = 1
		}
	} else {
		(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
		if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ >= max(i32) - (count - 1) {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = max(i32)
		} else {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ += count - 1
		}
		(^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ += 1
		if validate && (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
		}
	}
}

// —— Batch 6: ex_docmd.c command lookup (exports + weak) ——
foreign _ {
	@(link_name = "find_ucmd")
	find_ucmd_e :: proc "c" (eap: rawptr, p: cstring, full: ^C.int, xp: rawptr, complp: ^C.int) -> cstring ---
	@(link_name = "get_user_command_name")
	get_user_command_name_e :: proc "c" (idx: C.int, cmdidx: C.int) -> cstring ---
}

EXARG_USERIDX_OFF :: 156
CMD_MATCH_O :: 279
CMD_NEXT_O :: 560
CMD_BANG_O :: 552
CMD_HORIZONTAL_O :: 183

@(private = "file")
cmdmods_g: [24]cstring = {"aboveleft", "belowright", "botright", "browse", "confirm", "filter", "hide", "horizontal", "keepalt", "keepjumps", "keepmarks", "keeppatterns", "leftabove", "lockmarks", "noautocmd", "noswapfile", "rightbelow", "sandbox", "silent", "tab", "topleft", "unsilent", "verbose", "vertical"}
@(private = "file")
cmdmods_minlen_g: [24]u8 = {3, 3, 2, 3, 4, 4, 3, 3, 5, 5, 3, 5, 5, 3, 3, 3, 6, 3, 3, 3, 2, 3, 4, 4}

@(private = "file")
cmdidxs1_g: [26]u16 = {0, 20, 43, 109, 133, 154, 170, 176, 184, 203, 205, 210, 273, 291, 308, 319, 360, 363, 385, 450, 495, 508, 526, 541, 550, 551}
@(private = "file")
cmdidxs2_g: [26][26]u8 = {
	{0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 5, 6, 0, 0, 0, 7, 16, 0, 17, 0, 0, 0, 0, 0},
	{2, 0, 0, 5, 6, 7, 0, 0, 0, 0, 0, 8, 9, 10, 11, 12, 0, 13, 0, 0, 0, 0, 22, 0, 0, 0},
	{3, 12, 16, 18, 20, 22, 25, 0, 0, 0, 0, 34, 38, 41, 47, 58, 60, 61, 0, 0, 62, 0, 65, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 8, 17, 0, 18, 0, 0, 19, 0, 0, 21, 22, 0, 0, 0, 0, 0, 0, 0},
	{1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 7, 9, 10, 0, 0, 0, 0, 0, 0, 0, 16, 0, 17, 0, 0},
	{0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 4, 5, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{1, 0, 0, 0, 0, 3, 0, 0, 0, 4, 0, 5, 6, 0, 0, 13, 0, 0, 14, 0, 16, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{3, 11, 15, 18, 19, 23, 26, 31, 0, 0, 0, 33, 36, 39, 43, 50, 0, 52, 61, 53, 54, 58, 60, 0, 0, 0},
	{1, 0, 0, 0, 7, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 5, 7, 0, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4, 0, 7, 0, 0, 0, 0, 8, 0, 10, 0, 0, 0},
	{1, 5, 6, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11, 13, 0, 0, 18, 19, 28, 0, 29, 0, 30, 0},
	{2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15, 0, 16, 21, 0, 0, 0, 0},
	{2, 6, 15, 0, 17, 21, 0, 0, 23, 0, 0, 26, 28, 32, 36, 38, 0, 47, 0, 48, 0, 60, 61, 0, 62, 0},
	{4, 0, 1, 0, 24, 25, 0, 26, 0, 27, 0, 28, 32, 35, 37, 38, 0, 39, 42, 0, 43, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 9, 12, 0, 0, 0, 0, 15, 0, 16, 0, 0, 0, 0, 0},
	{2, 0, 0, 0, 0, 0, 0, 3, 4, 0, 0, 0, 0, 8, 0, 9, 10, 0, 12, 0, 13, 14, 0, 0, 0, 0},
	{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 5, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
}

// Command dispatcher lookup (ex_docmd.c public).
@(export)
find_ex_command :: proc "c" (eap: rawptr, full: ^C.int) -> cstring {
	context = runtime.default_context()
	p := (^cstring)(uintptr(eap) + EXARG_CMD_OFF)^
	cmd := p
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	if one_letter_cmd_o(p, &cmdidx) {
		p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		if full != nil {
			full^ = 1
		}
	} else {
		for (([^]u8)(p)[0] >= 'A' && ([^]u8)(p)[0] <= 'Z') || (([^]u8)(p)[0] >= 'a' && ([^]u8)(p)[0] <= 'z') {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		if ([^]u8)(cmd)[0] == 'p' && ([^]u8)(cmd)[1] == 'y' {
			for (([^]u8)(p)[0] >= '0' && ([^]u8)(p)[0] <= '9') || (([^]u8)(p)[0] >= 'A' && ([^]u8)(p)[0] <= 'Z') || (([^]u8)(p)[0] >= 'a' && ([^]u8)(p)[0] <= 'z') {
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
		}
		if p == cmd && vim_strchr(transmute(^u8)(cstring("@!=><&~#")), C.int(([^]u8)(p)[0])) != nil {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		length := C.int(uintptr(rawptr(p)) - uintptr(rawptr(cmd)))
		if ([^]u8)(cmd)[0] == 'd' && (([^]u8)(uintptr(rawptr(p)) - 1)[0] == 'l' || ([^]u8)(uintptr(rawptr(p)) - 1)[0] == 'p') {
			i: C.int = 0
			delw := transmute(^u8)(cstring("delete"))
			for i < length {
				if ([^]u8)(cmd)[uintptr(i)] != ([^]u8)(delw)[uintptr(i)] {
					break
				}
				i += 1
			}
			if i == length - 1 {
				length -= 1
				if ([^]u8)(uintptr(rawptr(p)) - 1)[0] == 'l' {
					(^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ |= EXFLAG_LIST_O
				} else {
					(^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ |= EXFLAG_PRINT_O
				}
			}
		}
		if ([^]u8)(cmd)[0] >= 'a' && ([^]u8)(cmd)[0] <= 'z' {
			c1 := C.int(([^]u8)(cmd)[0])
			c2: C.int = 0
			if length != 1 {
				c2 = C.int(([^]u8)(cmd)[1])
			}
			cmdidx = C.int(cmdidxs1_g[uintptr(c1 - 'a')])
			if c2 >= 'a' && c2 <= 'z' {
				cmdidx += C.int(cmdidxs2_g[uintptr(c1 - 'a')][uintptr(c2 - 'a')])
			}
		} else if ([^]u8)(cmd)[0] >= 'A' && ([^]u8)(cmd)[0] <= 'Z' {
			cmdidx = CMD_NEXT_O
		} else {
			cmdidx = CMD_BANG_O
		}
		if length == 3 && libc.strncmp(cmd, cstring("def"), 3) == 0 {
			cmdidx = CMD_SIZE_O
		}
		for C.int(cmdidx) < CMD_SIZE_O {
			def := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx))
			if libc.strncmp(def.name, cmd, C.size_t(length)) == 0 {
				if full != nil && ([^]u8)(def.name)[uintptr(length)] == 0 {
					full^ = 1
				}
				break
			}
			cmdidx += 1
		}
		if cmdidx == CMD_SIZE_O && ([^]u8)(cmd)[0] >= 'A' && ([^]u8)(cmd)[0] <= 'Z' {
			for (([^]u8)(p)[0] >= '0' && ([^]u8)(p)[0] <= '9') || (([^]u8)(p)[0] >= 'A' && ([^]u8)(p)[0] <= 'Z') || (([^]u8)(p)[0] >= 'a' && ([^]u8)(p)[0] <= 'z') {
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
			p = transmute(cstring)(find_ucmd_e(eap, p, full, nil, nil))
			cmdidx = (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
		}
		if p == cmd {
			cmdidx = CMD_SIZE_O
		}
	}
	if cmdidx == CMD_HORIZONTAL_O && uintptr(rawptr(p)) - uintptr(rawptr(cmd)) == 2 {
		cmdidx = CMD_SIZE_O
	}
	(^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ = cmdidx
	return p
}

// Full command-name resolver (ex_docmd.c public).
@(export)
cmd_exists :: proc "c" (name: cstring) -> C.int {
	context = runtime.default_context()
	for i := 0; i < 24; i += 1 {
		j: C.int = 0
		for ([^]u8)(name)[uintptr(j)] != 0 {
			if ([^]u8)(name)[uintptr(j)] != ([^]u8)(cmdmods_g[uintptr(i)])[uintptr(j)] {
				break
			}
			j += 1
		}
		if ([^]u8)(name)[uintptr(j)] == 0 && j >= C.int(cmdmods_minlen_g[uintptr(i)]) {
			if ([^]u8)(cmdmods_g[uintptr(i)])[0] == 0 {
				return 2
			}
			return 1
		}
	}
	ea: [192]u8
	libc.memset(rawptr(&ea[0]), 0, 192)
	ea_cmd := name
	if ([^]u8)(name)[0] == '2' || ([^]u8)(name)[0] == '3' {
		ea_cmd = transmute(cstring)(uintptr(rawptr(name)) + 1)
	}
	([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = ea_cmd
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] = 0
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FLAGS_OFF)[0] = 0
	full: C.int = 0
	p := find_ex_command(rawptr(&ea[0]), &full)
	if p == nil {
		return 3
	}
	if ascii_isdigit_o(([^]u8)(name)[0]) && (^C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)^ != CMD_MATCH_O {
		return 0
	}
	if ([^]u8)(skipwhite(p))[0] != 0 {
		return 0
	}
	if (^C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)^ == CMD_SIZE_O {
		return 0
	}
	if full != 0 {
		return 2
	}
	return 1
}

// "fullcommand()" builtin (ex_docmd.c public).
@(export)
f_fullcommand :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	name := transmute(cstring)(([^]Typval_T)(argvars)[0].vval)
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	for ([^]u8)(name)[0] == ':' {
		name = transmute(cstring)(uintptr(rawptr(name)) + 1)
	}
	name = skip_range(name, nil)
	ea: [192]u8
	libc.memset(rawptr(&ea[0]), 0, 192)
	n0 := ([^]u8)(name)[0]
	if n0 == '2' || n0 == '3' {
		([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(name)) + 1)
	} else {
		([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = name
	}
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] = 0
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FLAGS_OFF)[0] = 0
	p := find_ex_command(rawptr(&ea[0]), nil)
	if p == nil || ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] == CMD_SIZE_O {
		return
	}
	idx := ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0]
	if idx < 0 {
		rettv.vval = transmute(rawptr)(xstrdup(transmute(^u8)(get_user_command_name_e(([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USERIDX_OFF)[0], idx))))
	} else {
		rettv.vval = transmute(rawptr)(xstrdup(transmute(^u8)((^CommandDefinition_O)(nvim_odin_cmddef_at_e(idx)).name)))
	}
}

// —— Batch 5: ex_docmd.c validate/separate/lookup leaves (exports + weak) ——
foreign _ {
	@(link_name = "grep_internal")
	grep_internal_e :: proc "c" (cmdidx: C.int) -> C.int ---
	@(link_name = "del_trailing_spaces")
	del_trailing_spaces_e :: proc "c" (ptr: ^u8) ---
}

EX_CTRLV_O :: 8192
EX_XFILE_O :: 8
EX_NOTRLCOM_O :: 2048
EX_RANGE_O :: 1
CPO_BAR_O :: 'b'
CMD_K_O :: 205
CMD_SUBSTITUTE_O :: 385
CMD_VIMGREP_O :: 514
CMD_LVIMGREP_O :: 268
CMD_VIMGREPADD_O :: 515
CMD_LVIMGREPADD_O :: 269
CMD_AT_O :: 558
CMD_REDIR_O :: 366
CMD_INSERT_O :: 184
CMD_DIFFGET_O :: 119
CMD_DIFFPUT_O :: 122
E16_S :: "E16: Invalid range"
E42_S :: "E42: No Errors"

// Range validator (ex_docmd.c public).
@(export)
invalid_range :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	if (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ < 0 || (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ < 0 || (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ > (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ {
		return cstring(E16_S)
	}
	if ((^C.int)(uintptr(eap) + EXARG_ARGT_OFF)^ & EX_RANGE_O) != 0 {
		addr_type := (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^
		if addr_type == ADDR_LINES_O {
			extra: C.int = 0
			cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
			if cmdidx == CMD_DIFFGET_O || cmdidx == CMD_DIFFPUT_O {
				extra = 1
			}
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ + extra {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_ARGUMENTS_O {
			arg_count := (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^) + 0)^
			add := 0
			if arg_count == 0 {
				add = 1
			}
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > arg_count + C.int(add) {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_BUFFERS_O {
			if (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ < 1 || (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > get_highest_fnum() {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_LOADED_BUFFERS_O {
			buf := firstbuf
			for (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
				if (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ == nil {
					return cstring(E16_S)
				}
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
			}
			if (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ < (^C.int)(uintptr(buf) + B_FNUM_OFF)^ {
				return cstring(E16_S)
			}
			buf = lastbuf_g
			for (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
				if (^rawptr)(uintptr(buf) + B_PREV_OFF)^ == nil {
					return cstring(E16_S)
				}
				buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
			}
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > (^C.int)(uintptr(buf) + B_FNUM_OFF)^ {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_WINDOWS_O {
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > current_win_nr_o(nil) {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_TABS_O {
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > current_tab_nr_o(nil) {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_TABS_RELATIVE_O || addr_type == ADDR_OTHER_O {
			// Any range is OK.
		} else if addr_type == ADDR_QUICKFIX_O {
			if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ <= 0 {
				if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ == 0 {
					return cstring(E42_S)
				}
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_QUICKFIX_VALID_O {
			if ((^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ != 1 && C.size_t((^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^) > qf_get_valid_size_e(eap)) || (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ < 0 {
				return cstring(E16_S)
			}
		} else if addr_type == ADDR_UNSIGNED_O || addr_type == ADDR_NONE_O {
			// Will give an error elsewhere.
		}
	}
	return nil
}

// vimgrep-pattern skipper (ex_docmd.c static).
skip_grep_pat_o :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	p := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	if ([^]u8)(p)[0] != 0 && (cmdidx == CMD_VIMGREP_O || cmdidx == CMD_LVIMGREP_O || cmdidx == CMD_VIMGREPADD_O || cmdidx == CMD_LVIMGREPADD_O || grep_internal_e(cmdidx) != 0) {
		p = transmute(cstring)(skip_vimgrep_pat(transmute(^u8)(p), nil, nil))
		if p == nil {
			p = (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
		}
	}
	return p
}

// Next-command separator (ex_docmd.c public).
@(export)
separate_nextcmd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	p := transmute(^u8)(skip_grep_pat_o(eap))
	argt := (^C.int)(uintptr(eap) + EXARG_ARGT_OFF)^
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == Ctrl_V_O {
			if (argt & (EX_CTRLV_O | EX_XFILE_O)) != 0 {
				p = transmute(^u8)(uintptr(rawptr(p)) + 1)
			} else {
				libc.memmove(rawptr(p), rawptr(uintptr(rawptr(p)) + 1), libc.strlen(transmute(cstring)(uintptr(rawptr(p)) + 1)) + 1)
			}
			if ([^]u8)(p)[0] == 0 {
				break
			}
		} else if (([^]u8)(p)[0] == '`' && ([^]u8)(p)[1] == '=' && (argt & EX_XFILE_O) != 0) {
			p = transmute(^u8)(uintptr(rawptr(p)) + 2)
			sp := transmute(cstring)(p)
			skip_expr(&sp, nil)
			p = transmute(^u8)(sp)
			if ([^]u8)(p)[0] == 0 {
				break
			}
		} else if ((([^]u8)(p)[0] == '"' && (argt & EX_NOTRLCOM_O) == 0 && (cmdidx != CMD_AT_O || p != transmute(^u8)(arg)) && (cmdidx != CMD_REDIR_O || p != transmute(^u8)(uintptr(rawptr(arg)) + 1) || ([^]u8)(uintptr(rawptr(p)) - 1)[0] != '@')) || (([^]u8)(p)[0] == '|' && cmdidx != CMD_APPEND_O && cmdidx != CMD_CHANGE_O && cmdidx != CMD_INSERT_O) || ([^]u8)(p)[0] == '\n') {
			if ((vim_strchr(p_cpo, CPO_BAR_O) == nil || (argt & EX_CTRLV_O) == 0) && ([^]u8)(uintptr(rawptr(p)) - 1)[0] == '\\') {
				pp := transmute(^u8)(uintptr(rawptr(p)) - 1)
				libc.memmove(rawptr(pp), rawptr(p), libc.strlen(transmute(cstring)(p)) + 1)
				p = pp
			} else {
				(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^ = transmute(rawptr)(check_nextcmd(p))
				([^]u8)(p)[0] = 0
				break
			}
		}
		// C for-increment (MB_PTR_ADV): every non-break path advances one char.
		p = transmute(^u8)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
	}
	if (argt & EX_NOTRLCOM_O) == 0 {
		del_trailing_spaces_e(transmute(^u8)(arg))
	}
}

// One-letter command test (ex_docmd.c static).
one_letter_cmd_o :: proc "c" (p: cstring, idx: ^C.int) -> bool {
	context = runtime.default_context()
	c0 := ([^]u8)(p)[0]
	c1 := ([^]u8)(p)[1]
	if c0 == 'k' && (c1 != 'e' || (c1 == 'e' && ([^]u8)(p)[2] != 'e')) {
		idx^ = CMD_K_O
		return true
	}
	if c0 != 's' {
		return false
	}
	matched := false
	if c1 == 'c' {
		c2 := ([^]u8)(p)[2]
		if c2 == 0 {
			matched = true
		} else if c2 != 's' && c2 != 'r' {
			c3 := ([^]u8)(p)[3]
			if c3 == 0 {
				matched = true
			} else if c3 != 'i' {
				matched = true
			} else if ([^]u8)(p)[4] != 'p' {
				matched = true
			}
		}
	} else if c1 == 'g' || c1 == 'I' {
		matched = true
	} else if c1 == 'i' {
		c2 := ([^]u8)(p)[2]
		if c2 != 'm' && c2 != 'l' && c2 != 'g' {
			matched = true
		}
	} else if c1 == 'r' {
		if ([^]u8)(p)[2] != 'e' {
			matched = true
		}
	}
	if matched {
		idx^ = CMD_SUBSTITUTE_O
		return true
	}
	return false
}

// Command-index lookup (ex_docmd.c public).
@(export)
excmd_get_cmdidx :: proc "c" (cmd: cstring, len: C.size_t) -> C.int {
	context = runtime.default_context()
	if len == 3 && libc.strncmp(cmd, cstring("def"), 3) == 0 {
		return CMD_SIZE_O
	}
	idx: C.int = 0
	if !one_letter_cmd_o(cmd, &idx) {
		idx = 0
		for C.size_t(idx) < C.size_t(CMD_SIZE_O) {
			def := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(idx))
			if libc.strncmp(def.name, cmd, len) == 0 {
				break
			}
			idx += 1
		}
	}
	return idx
}

// Command-flags lookup (ex_docmd.c public).
@(export)
excmd_get_argt :: proc "c" (idx: C.int) -> u32 {
	context = runtime.default_context()
	return (^CommandDefinition_O)(nvim_odin_cmddef_at_e(idx)).argt
}

// —— Batch 3: ex_docmd.c tiny leaves (exports + weak) ——
foreign _ {
	@(link_name = "expr_map_lock")
	expr_map_lock_g: C.int
}
VV_EXITREASON_O :: 105
EXARG_BAD_CHAR_OFF :: 152

// Lone-$ command holder (moved ex_docmd.c static; C readers use extern).
@(export)
dollar_command: [2]u8 = {'$', 0}

// exiting-state setter (ex_docmd.c public).
@(export)
not_exiting :: proc "c" (save_exiting: bool) {
	exiting = save_exiting
	set_vim_var_string(VV_EXITREASON_O, nil, -1)
}

// Cursor/topline validator (ex_docmd.c public).
@(export)
update_topline_cursor :: proc "c" () {
	check_cursor(curwin)
	update_topline_r(curwin)
	if (^C.int)(uintptr(curwin) + W_P_WRAP_OFF)^ == 0 {
		validate_cursor_r(curwin)
	}
}

// Expr-mapping lock test (ex_docmd.c public).
@(export)
expr_map_locked :: proc "c" () -> bool {
	return expr_map_lock_g > 0 && ((^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ & BF_DUMMY_O) == 0
}

// ++bad= option parser (ex_docmd.c public).
@(export)
get_bad_opt :: proc "c" (p: cstring, eap: rawptr) -> C.int {
	context = runtime.default_context()
	if _strcasecmp(p, cstring("keep")) == 0 {
		(^C.int)(uintptr(eap) + EXARG_BAD_CHAR_OFF)^ = BAD_KEEP_O
	} else if _strcasecmp(p, cstring("drop")) == 0 {
		(^C.int)(uintptr(eap) + EXARG_BAD_CHAR_OFF)^ = BAD_DROP_O
	} else {
		blen: C.int = 1
		if ([^]u8)(p)[0] >= 0x80 {
			blen = utfc_ptr2len(p)
		}
		if blen == 1 && ([^]u8)(p)[1] == 0 {
			(^C.int)(uintptr(eap) + EXARG_BAD_CHAR_OFF)^ = C.int(([^]u8)(p)[0])
		} else {
			return FAIL_E
		}
	}
	return OK_E
}

// +-command extractor (ex_docmd.c public).
@(export)
getargcmd :: proc "c" (argp: ^cstring) -> cstring {
	context = runtime.default_context()
	arg := argp^
	command: cstring = nil
	if ([^]u8)(arg)[0] == '+' {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
		if ascii_isspace_o(C.int(([^]u8)(arg)[0])) || ([^]u8)(arg)[0] == 0 {
			command = transmute(cstring)(&dollar_command[0])
		} else {
			command = arg
			arg = skip_cmd_arg(command, true)
			if ([^]u8)(arg)[0] != 0 {
				([^]u8)(arg)[0] = 0
				arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			}
		}
		arg = skipwhite(arg)
		argp^ = arg
	}
	return command
}

// +-command end finder (ex_docmd.c public).
@(export)
skip_cmd_arg :: proc "c" (p: cstring, rembs: bool) -> cstring {
	context = runtime.default_context()
	cur := p
	for ([^]u8)(cur)[0] != 0 && !ascii_isspace_o(C.int(([^]u8)(cur)[0])) {
		if ([^]u8)(cur)[0] == '\\' && ([^]u8)(cur)[1] != 0 {
			if rembs {
				libc.memmove(rawptr(cur), rawptr(uintptr(rawptr(cur)) + 1), libc.strlen(transmute(cstring)(uintptr(rawptr(cur)) + 1)) + 1)
			} else {
				cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
			}
		}
		cur = transmute(cstring)(uintptr(rawptr(cur)) + uintptr(utfc_ptr2len(cur)))
	}
	return cur
}

// —— Batch 4: ex_docmd.c cmdnames-table cluster (exports + weak) ——
foreign _ {
	@(link_name = "nvim_odin_cmddef_at")
	nvim_odin_cmddef_at_e :: proc "c" (i: C.int) -> rawptr ---
	@(link_name = "expand_user_command_name")
	expand_user_command_name_e :: proc "c" (idx: C.int) -> cstring ---
	@(link_name = "ex_map")
	ex_map_p :: proc "c" (eap: rawptr) ---
	@(link_name = "ex_unmap")
	ex_unmap_p :: proc "c" (eap: rawptr) ---
	@(link_name = "ex_mapclear")
	ex_mapclear_p :: proc "c" (eap: rawptr) ---
	@(link_name = "ex_abbreviate")
	ex_abbreviate_p :: proc "c" (eap: rawptr) ---
	@(link_name = "ex_abclear")
	ex_abclear_p :: proc "c" (eap: rawptr) ---
}

// CommandDefinition mirror (ex_cmds_defs.h): 32B cc-probed.
CommandDefinition_O :: struct {
	name:      cstring, // 0
	func:      rawptr,  // 8
	_argt_pad: [8]u8,   // 16..24
	argt:      u32,     // 24
	addr_type: C.int,   // 28
}
#assert(size_of(CommandDefinition_O) == 32)

CMD_WINCMD_O :: 531
CMD_CC_O :: 59
CMD_LL_O :: 243
Ctrl_C_O :: 3
Ctrl_F_O :: 6
Ctrl_H_O :: 8
Ctrl_L_O :: 12
Ctrl_P_O :: 16
Ctrl_R_O :: 18
Ctrl_U_O :: 21
Ctrl_V_O :: 22
Ctrl_W_O :: 23
Ctrl___O :: 31

// wincmd-letter address arm (ex_docmd.c static).
get_wincmd_addr_type_o :: proc "c" (arg: cstring, eap: rawptr) {
	context = runtime.default_context()
	addr_type := ADDR_OTHER_O
	a := ([^]u8)(arg)[0]
	if a == 'S' || a == 19 || a == 's' || a == 14 || a == 'n' || a == 'j' || a == 10 || a == 'k' || a == 11 || a == 'T' || a == 18 || a == 'r' || a == 'R' || a == 'K' || a == 'J' || a == '+' || a == '-' || a == 31 || a == '_' || a == '|' || a == ']' || a == 29 || a == 'g' || a == 7 || a == 22 || a == 'v' || a == 'h' || a == 8 || a == 'l' || a == 12 || a == 'H' || a == 'L' || a == '>' || a == '<' || a == '}' || a == 'f' || a == 'F' || a == 6 || a == 'i' || a == 9 || a == 'd' || a == 4 {
		addr_type = ADDR_OTHER_O
	} else if a == 30 || a == '^' {
		addr_type = ADDR_BUFFERS_O
	} else if a == 17 || a == 'q' || a == 3 || a == 'c' || a == 15 || a == 'o' || a == 23 || a == 'w' || a == 'W' || a == 'x' || a == 24 {
		addr_type = ADDR_WINDOWS_O
	} else if a == 26 || a == 'z' || a == 'P' || a == 't' || a == 20 || a == 'b' || a == 2 || a == 'p' || a == 16 || a == '=' || a == 13 {
		addr_type = ADDR_NONE_O
	}
	(^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ = C.int(addr_type)
}

// Address-type resolver (ex_docmd.c public).
@(export)
set_cmd_addr_type :: proc "c" (eap: rawptr, p: cstring) {
	context = runtime.default_context()
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ < 0 {
		return
	}
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ != CMD_SIZE_O {
		def := (^CommandDefinition_O)(nvim_odin_cmddef_at_e((^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^))
		(^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ = def.addr_type
	} else {
		(^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ = ADDR_LINES_O
	}
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_WINCMD_O && p != nil {
		get_wincmd_addr_type_o(skipwhite(p), eap)
	}
	if ((^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_CC_O || (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_LL_O) && bt_quickfix(curbuf) {
		(^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ = ADDR_OTHER_O
	}
}

// Not-implemented command test (ex_docmd.c public).
@(export)
is_cmd_ni :: proc "c" (cmdidx: C.int) -> bool {
	context = runtime.default_context()
	if cmdidx < 0 {
		return false
	}
	fn := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx)).func
	return fn == transmute(rawptr)(ex_ni) || fn == transmute(rawptr)(ex_script_ni)
}

// Mapping-command test (ex_docmd.c public).
@(export)
is_map_cmd :: proc "c" (cmdidx: C.int) -> bool {
	context = runtime.default_context()
	if cmdidx < 0 {
		return false
	}
	fn := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx)).func
	return fn == transmute(rawptr)(ex_map_p) || fn == transmute(rawptr)(ex_unmap_p) || fn == transmute(rawptr)(ex_mapclear_p) || fn == transmute(rawptr)(ex_abbreviate_p) || fn == transmute(rawptr)(ex_abclear_p)
}

// Loclist-command test (ex_docmd.c public).
@(export)
is_loclist_cmd :: proc "c" (cmdidx: C.int) -> bool {
	context = runtime.default_context()
	if cmdidx < 0 || cmdidx >= CMD_SIZE_O {
		return false
	}
	return ([^]u8)((^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx)).name)[0] == 'l'
}

// Command-name expand iterator (ex_docmd.c public).
@(export)
get_command_name :: proc "c" (xp: ^expand_T, idx: C.int) -> cstring {
	context = runtime.default_context()
	if idx >= CMD_SIZE_O {
		return expand_user_command_name_e(idx)
	}
	return (^CommandDefinition_O)(nvim_odin_cmddef_at_e(idx)).name
}

// —— Batch 7: ex_docmd.c tiny leaves (exports + weak) ——

// Moved ex_docmd.c static (C readers use extern; unifies do_exedit shadow).
@(export)
ex_pressedreturn: bool = false

// Moved ex_docmd.c static Callback (C readers use extern).
@(export)
ffu_cb: Callback_E

LOOP_COOKIE_LC_GETLINE_OFF :: 16
LOOP_COOKIE_COOKIE_OFF :: 24

@(private = "file")
cmdmods_has_count_g: [24]bool = {
	false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false,
	false, false, false, true, false, false, true, false,
}

// Command-modifier length (ex_docmd.c public).
@(export)
modifier_len :: proc "c" (cmd: cstring) -> C.int {
	context = runtime.default_context()
	p := cmd
	if ascii_isdigit_o(([^]u8)(cmd)[0]) {
		p = skipwhite(skipdigits(transmute(cstring)(uintptr(rawptr(cmd)) + 1)))
	}
	for i := 0; i < 24; i += 1 {
		j: C.int = 0
		for ([^]u8)(p)[uintptr(j)] != 0 {
			if ([^]u8)(p)[uintptr(j)] != ([^]u8)(cmdmods_g[uintptr(i)])[uintptr(j)] {
				break
			}
			j += 1
		}
		cj := ([^]u8)(p)[uintptr(j)]
		is_alpha := (cj >= 'A' && cj <= 'Z') || (cj >= 'a' && cj <= 'z')
		if j >= C.int(cmdmods_minlen_g[uintptr(i)]) && !is_alpha && (p == cmd || cmdmods_has_count_g[uintptr(i)]) {
			return j + C.int(uintptr(rawptr(p)) - uintptr(rawptr(cmd)))
		}
	}
	return 0
}

// Empty-commandline flag accessors (ex_docmd.c publics).
@(export)
get_pressedreturn :: proc "c" () -> bool {
	return ex_pressedreturn
}

// Empty-commandline flag accessors (ex_docmd.c publics).
@(export)
set_pressedreturn :: proc "c" (val: bool) {
	ex_pressedreturn = val
}

// Loop-line getter equality (ex_docmd.c public).
@(export)
getline_equal :: proc "c" (fgetline: LineGetter, cookie: rawptr, func: LineGetter) -> bool {
	context = runtime.default_context()
	gp := fgetline
	cp := cookie
	loop_addr := transmute(rawptr)(get_loop_line_o)
	for transmute(rawptr)(gp) == loop_addr {
		gp = (^LineGetter)(uintptr(cp) + LOOP_COOKIE_LC_GETLINE_OFF)^
		cp = (^rawptr)(uintptr(cp) + LOOP_COOKIE_COOKIE_OFF)^
	}
	return transmute(rawptr)(gp) == transmute(rawptr)(func)
}

// Loop-line getter cookie unwrap (ex_docmd.c public).
@(export)
getline_cookie :: proc "c" (fgetline: LineGetter, cookie: rawptr) -> rawptr {
	context = runtime.default_context()
	gp := fgetline
	cp := cookie
	loop_addr := transmute(rawptr)(get_loop_line_o)
	for transmute(rawptr)(gp) == loop_addr {
		gp = (^LineGetter)(uintptr(cp) + LOOP_COOKIE_LC_GETLINE_OFF)^
		cp = (^rawptr)(uintptr(cp) + LOOP_COOKIE_COOKIE_OFF)^
	}
	return cp
}

// No-highlight-search setter (ex_docmd.c public).
@(export)
set_no_hlsearch :: proc "c" (flag: bool) {
	no_hlsearch = flag
	v: i64 = 0
	if !no_hlsearch && p_hls != 0 {
		v = 1
	}
	set_vim_var_nr(VV_HLSEARCH_O, v)
}

// Print-after-command helper (ex_docmd.c public).
@(export)
ex_may_print :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ != 0 {
		print_line((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, ((^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ & EXFLAG_NR_O) != 0, ((^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ & EXFLAG_LIST_O) != 0, true)
		ex_no_reprint_g = true
	}
}

// findfunc callback free (ex_docmd.c public).
@(export)
free_findfunc_option :: proc "c" () {
	callback_free(&ffu_cb)
}

// findfunc callback GC mark (ex_docmd.c public).
@(export)
set_ref_in_findfunc :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	return set_ref_in_callback(&ffu_cb, copyID, nil, nil)
}

// —— Batch 8: ex_docmd.c argopt cluster (exports + weak) ——

// ++opt name iterator (ex_docmd.c static).
get_argopt_name_o :: proc "c" (xp: rawptr, idx: C.int) -> ^u8 {
	context = runtime.default_context()
	vals := [7]cstring{"fileformat=", "encoding=", "binary", "nobinary", "bad=", "edit", "p"}
	if idx < 7 {
		return transmute(^u8)(vals[idx])
	}
	return nil
}

// bad= value iterator (ex_docmd.c static).
get_bad_name_o :: proc "c" (xp: rawptr, idx: C.int) -> ^u8 {
	context = runtime.default_context()
	vals := [3]cstring{"?", "keep", "drop"}
	if idx < 3 {
		return transmute(^u8)(vals[idx])
	}
	return nil
}

// ++opt argument parser (ex_docmd.c public).
@(export)
getargopt :: proc "c" (eap: rawptr) -> C.int {
	context = runtime.default_context()
	eap_arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	eap_cmd := (^cstring)(uintptr(eap) + EXARG_CMD_OFF)^
	arg := transmute(cstring)(uintptr(rawptr(eap_arg)) + 2)
	pp_raw: rawptr = nil
	bad_char_idx: C.int = 0
	if libc.strncmp(arg, cstring("bin"), 3) == 0 || libc.strncmp(arg, cstring("nobin"), 5) == 0 {
		if ([^]u8)(arg)[0] == 'n' {
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 2)
			(^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ = FORCE_NOBIN_O
		} else {
			(^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ = FORCE_BIN_O
		}
		if !checkforcmd(&arg, cstring("binary"), 3) {
			return FAIL_E
		}
		(^cstring)(uintptr(eap) + EXARG_ARG_OFF)^ = skipwhite(arg)
		return OK_E
	}
	if libc.strncmp(arg, cstring("edit"), 4) == 0 {
		c4 := ([^]u8)(arg)[4]
		if !(c4 >= 'A' && c4 <= 'Z') && !(c4 >= 'a' && c4 <= 'z') {
			(^C.int)(uintptr(eap) + EXARG_READ_EDIT_OFF_O)^ = 1
			(^cstring)(uintptr(eap) + EXARG_ARG_OFF)^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg)) + 4))
			return OK_E
		}
	}
	if ([^]u8)(arg)[0] == 'p' {
		c1 := ([^]u8)(arg)[1]
		if !(c1 >= 'A' && c1 <= 'Z') && !(c1 >= 'a' && c1 <= 'z') {
			(^C.int)(uintptr(eap) + EXARG_MKDIR_P_OFF_O)^ = 1
			(^cstring)(uintptr(eap) + EXARG_ARG_OFF)^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg)) + 1))
			return OK_E
		}
	}
	if libc.strncmp(arg, cstring("ff"), 2) == 0 {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 2)
		pp_raw = rawptr(uintptr(eap) + EXARG_FORCE_FF_OFF_O)
	} else if libc.strncmp(arg, cstring("fileformat"), 10) == 0 {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 10)
		pp_raw = rawptr(uintptr(eap) + EXARG_FORCE_FF_OFF_O)
	} else if libc.strncmp(arg, cstring("enc"), 3) == 0 {
		if libc.strncmp(arg, cstring("encoding"), 8) == 0 {
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 8)
		} else {
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 3)
		}
		pp_raw = rawptr(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)
	} else if libc.strncmp(arg, cstring("bad"), 3) == 0 {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 3)
		pp_raw = rawptr(&bad_char_idx)
	}
	if pp_raw == nil || ([^]u8)(arg)[0] != '=' {
		return FAIL_E
	}
	arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
	(^C.int)(pp_raw)^ = C.int(uintptr(rawptr(arg)) - uintptr(rawptr(eap_cmd)))
	arg = skip_cmd_arg(arg, false)
	(^cstring)(uintptr(eap) + EXARG_ARG_OFF)^ = skipwhite(arg)
	([^]u8)(arg)[0] = 0
	if pp_raw == rawptr(uintptr(eap) + EXARG_FORCE_FF_OFF_O) {
		if check_ff_value(transmute(^u8)(transmute(cstring)(uintptr(rawptr(eap_cmd)) + uintptr((^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^)))) == FAIL_E {
			return FAIL_E
		}
		(^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^ = C.int(([^]u8)(eap_cmd)[uintptr((^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^)])
	} else if pp_raw == rawptr(uintptr(eap) + EXARG_FORCE_ENC_OFF_O) {
		p := transmute(^u8)(transmute(cstring)(uintptr(rawptr(eap_cmd)) + uintptr((^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^)))
		for ([^]u8)(p)[0] != 0 {
			([^]u8)(p)[0] = tolower_asc_o(([^]u8)(p)[0])
			p = transmute(^u8)(uintptr(p) + 1)
		}
	} else {
		if get_bad_opt(transmute(cstring)(uintptr(rawptr(eap_cmd)) + uintptr(bad_char_idx)), eap) == FAIL_E {
			return FAIL_E
		}
	}
	return OK_E
}

// ++opt completion (ex_docmd.c public).
@(export)
expand_argopt :: proc "c" (pat: cstring, xp: ^expand_T, rmp: rawptr, matches: ^rawptr, numMatches: ^C.int) -> C.int {
	context = runtime.default_context()
	pat_end := uintptr(rawptr(xp.xp_pattern))
	line := uintptr(rawptr(xp.xp_line))
	if pat_end > line && ([^]u8)(pat_end - 1)[0] == '=' {
		cb: CompleteListItemGetter_T = nil
		name_end := pat_end - 1
		if name_end - line >= 2 && libc.strncmp(transmute(cstring)(name_end - 2), cstring("ff"), 2) == 0 {
			cb = get_fileformat_name
		} else if name_end - line >= 10 && libc.strncmp(transmute(cstring)(name_end - 10), cstring("fileformat"), 10) == 0 {
			cb = get_fileformat_name
		} else if name_end - line >= 3 && libc.strncmp(transmute(cstring)(name_end - 3), cstring("enc"), 3) == 0 {
			cb = get_encoding_name_r
		} else if name_end - line >= 8 && libc.strncmp(transmute(cstring)(name_end - 8), cstring("encoding"), 8) == 0 {
			cb = get_encoding_name_r
		} else if name_end - line >= 3 && libc.strncmp(transmute(cstring)(name_end - 3), cstring("bad"), 3) == 0 {
			cb = get_bad_name_o
		}
		if cb != nil {
			expand_generic_r(pat, xp, rmp, matches, numMatches, cb, false)
			return OK_E
		}
		return FAIL_E
	}
	if xp.xp_pattern_len == 2 && libc.strncmp(xp.xp_pattern, cstring("ff"), C.size_t(xp.xp_pattern_len)) == 0 {
		matches^ = rawptr(xmalloc(8))
		numMatches^ = 1
		([^]rawptr)(matches^)[0] = rawptr(xstrdup(transmute(^u8)(cstring("fileformat="))))
		return OK_E
	}
	expand_generic_r(pat, xp, rmp, matches, numMatches, get_argopt_name_o, false)
	return OK_E
}

// —— Batch 9a: ex_docmd.c cmdline-var engine (exports + weak) ——
foreign _ {
	@(link_name = "arg_all")
	arg_all_e :: proc "c" () -> ^u8 ---
	@(link_name = "path_try_shorten_fname")
	path_try_shorten_fname_e :: proc "c" (path: ^u8) -> ^u8 ---
	@(link_name = "estack_sfile")
	estack_sfile_e :: proc "c" (which: C.int) -> ^u8 ---
}

SPEC_PERC_O :: 0
SPEC_HASH_O :: 1
SPEC_CWORD_O :: 2
SPEC_CCWORD_O :: 3
SPEC_CEXPR_O :: 4
SPEC_CFILE_O :: 5
SPEC_SFILE_O :: 6
SPEC_SLNUM_O :: 7
SPEC_STACK_O :: 8
SPEC_SCRIPT_O :: 9
SPEC_AFILE_O :: 10
SPEC_ABUF_O :: 11
SPEC_AMATCH_O :: 12
SPEC_SFLNUM_O :: 13
SPEC_SID_O :: 14
FIND_EVAL_O :: 4
ESTACK_SFILE_O :: 1
ESTACK_STACK_O :: 2
ESTACK_SCRIPT_O :: 3
E194_S :: "E194: No alternate file name to substitute for '#'"
E499_S :: "E499: Empty file name for '%' or '#', only works with \":p:h\""
E500_S :: "E500: Evaluates to an empty string"
E489_S :: "E489: No call stack to substitute for \"<stack>\""
E495_S :: "E495: No autocommand file name to substitute for \"<afile>\""
E496_S :: "E496: No autocommand buffer number to substitute for \"<abuf>\""
E497_S :: "E497: No autocommand match name to substitute for \"<amatch>\""
E498_S :: "E498: No :source file name to substitute for \"<sfile>\""
E842_S :: "E842: No line number to use for \"<slnum>\""
E961_S :: "E961: No line number to use for \"<sflnum>\""
E1274_S :: "E1274: No script file name to substitute for \"<script>\""
E81_S :: "E81: Using <SID> not in a script context"

@(private = "file")
spec_str_g: [15]cstring = {"%", "#", "<cword>", "<cWORD>", "<cexpr>", "<cfile>", "<sfile>", "<slnum>", "<stack>", "<script>", "<afile>", "<abuf>", "<amatch>", "<sflnum>", "<SID>"}

// Special cmdline-variable test (ex_docmd.c public).
@(export)
find_cmdline_var :: proc "c" (src: cstring, usedlen: ^C.size_t) -> C.ssize_t {
	context = runtime.default_context()
	for i := 0; i < 15; i += 1 {
		slen := libc.strlen(spec_str_g[i])
		if libc.strncmp(src, spec_str_g[i], slen) == 0 {
			usedlen^ = slen
			return C.ssize_t(i)
		}
	}
	return -1
}

// Cmdline-variable evaluator (ex_docmd.c public).
@(export)
eval_vars :: proc "c" (src: cstring, srcstart: cstring, usedlen: ^C.size_t, lnump: ^C.int, errormsg: ^cstring, escaped: ^C.int, empty_is_error: bool) -> ^u8 {
	context = runtime.default_context()
	result: ^u8 = transmute(^u8)(cstring(""))
	resultbuf: ^u8 = nil
	resultlen: C.size_t = 0
	valid: C.int = VALID_HEAD_O | VALID_PATH_O
	tilde_file := false
	skip_mod := false
	strbuf: [30]u8
	errormsg^ = nil
	if escaped != nil {
		escaped^ = 0
	}
	spec_idx := find_cmdline_var(src, usedlen)
	if spec_idx < 0 {
		usedlen^ = 1
		return nil
	}
	if uintptr(rawptr(src)) > uintptr(rawptr(srcstart)) && ([^]u8)(uintptr(rawptr(src)) - 1)[0] == '\\' {
		usedlen^ = 0
		libc.memmove(rawptr(uintptr(rawptr(src)) - 1), rawptr(src), libc.strlen(src) + 1)
		return nil
	}
	if spec_idx == SPEC_CWORD_O || spec_idx == SPEC_CCWORD_O || spec_idx == SPEC_CEXPR_O {
		ft: C.int = FIND_IDENT | FIND_STRING
		if spec_idx == SPEC_CEXPR_O {
			ft = FIND_IDENT | FIND_STRING | FIND_EVAL_O
		} else if spec_idx == SPEC_CCWORD_O {
			ft = FIND_STRING
		}
		resultlen = C.size_t(find_ident_under_cursor_r(&result, ft, nil))
		if resultlen == 0 {
			errormsg^ = cstring("")
			return nil
		}
	} else {
		switch spec_idx {
		case SPEC_PERC_O:
			bf := (^cstring)(uintptr(curbuf) + B_FNAME)^
			if bf == nil {
				result = transmute(^u8)(cstring(""))
				valid = 0
			} else {
				result = transmute(^u8)(bf)
				tilde_file = libc.strcmp(transmute(cstring)(result), cstring("~")) == 0
			}
		case SPEC_HASH_O:
			if ([^]u8)(src)[1] == '#' {
				result = arg_all_e()
				resultbuf = result
				usedlen^ = 2
				if escaped != nil {
					escaped^ = 1
				}
				skip_mod = true
				break
			}
			s := transmute(^u8)(transmute(cstring)(uintptr(rawptr(src)) + 1))
			if ([^]u8)(s)[0] == '<' {
				s = transmute(^u8)(transmute(cstring)(uintptr(rawptr(s)) + 1))
			}
			i := getdigits_int(&s, false, 0)
			if uintptr(rawptr(s)) == uintptr(rawptr(src)) + 2 && ([^]u8)(src)[1] == '-' {
				s = transmute(^u8)(transmute(cstring)(uintptr(rawptr(s)) - 1))
			}
			usedlen^ = C.size_t(uintptr(rawptr(s)) - uintptr(rawptr(src)))
			if ([^]u8)(src)[1] == '<' && i != 0 {
				if usedlen^ < 2 {
					usedlen^ = 1
					return nil
				}
				result = transmute(^u8)(tv_list_find_str(get_vim_var_list(VV_OLDFILES), i - 1))
				if result == nil {
					errormsg^ = cstring("")
					return nil
				}
			} else {
				if i == 0 && ([^]u8)(src)[1] == '<' && usedlen^ > 1 {
					usedlen^ = 1
				}
				buf := buflist_findnr(i)
				if buf == nil {
					errormsg^ = cstring(E194_S)
					return nil
				}
				if lnump != nil {
					lnump^ = ECMD_LAST_O
				}
				bf := (^cstring)(uintptr(buf) + B_FNAME)^
				if bf == nil {
					result = transmute(^u8)(cstring(""))
					valid = 0
				} else {
					result = transmute(^u8)(bf)
					tilde_file = libc.strcmp(transmute(cstring)(result), cstring("~")) == 0
				}
			}
		case SPEC_CFILE_O:
			result = file_name_at_cursor_r(FNAME_MESS | FNAME_HYP, 1, nil)
			if result == nil {
				errormsg^ = cstring("")
				return nil
			}
			resultbuf = result
		case SPEC_AFILE_O:
			if autocmd_fname_g != nil && !autocmd_fname_full_g {
				autocmd_fname_full_g = true
				full := fullname_save_r(autocmd_fname_g, false)
				xstrlcpy(autocmd_fname_g, full, MAXPATHL_O)
				xfree(rawptr(full))
			}
			result = transmute(^u8)(autocmd_fname_g)
			if result == nil {
				errormsg^ = cstring(E495_S)
				return nil
			}
			result = path_try_shorten_fname_e(result)
		case SPEC_ABUF_O:
			if autocmd_bufnr_g <= 0 {
				errormsg^ = cstring(E496_S)
				return nil
			}
			libc.snprintf(transmute([^]u8)(&strbuf[0]), 30, cstring("%d"), autocmd_bufnr_g)
			result = transmute(^u8)(&strbuf[0])
		case SPEC_AMATCH_O:
			result = transmute(^u8)(autocmd_match_g)
			if result == nil {
				errormsg^ = cstring(E497_S)
				return nil
			}
		case SPEC_SFILE_O:
			result = estack_sfile_e(ESTACK_SFILE_O)
			if result == nil {
				errormsg^ = cstring(E498_S)
				return nil
			}
			resultbuf = result
		case SPEC_STACK_O:
			result = estack_sfile_e(ESTACK_STACK_O)
			if result == nil {
				errormsg^ = cstring(E489_S)
				return nil
			}
			resultbuf = result
		case SPEC_SCRIPT_O:
			result = estack_sfile_e(ESTACK_SCRIPT_O)
			if result == nil {
				errormsg^ = cstring(E1274_S)
				return nil
			}
			resultbuf = result
		case SPEC_SLNUM_O:
			sname: cstring = nil
			slnum: i32 = 0
			if exestack.ga_len > 0 {
				top := ([^]Estack)(exestack.ga_data)[exestack.ga_len - 1]
				sname = top.es_name
				slnum = top.es_lnum
			}
			if sname == nil || slnum == 0 {
				errormsg^ = cstring(E842_S)
				return nil
			}
			libc.snprintf(transmute([^]u8)(&strbuf[0]), 30, cstring("%d"), C.int(slnum))
			result = transmute(^u8)(&strbuf[0])
		case SPEC_SFLNUM_O:
			slnum2: i32 = 0
			if exestack.ga_len > 0 {
				slnum2 = ([^]Estack)(exestack.ga_data)[exestack.ga_len - 1].es_lnum
			}
			total := (^i32)(&current_sctx_buf[8])^ + slnum2
			if total == 0 {
				errormsg^ = cstring(E961_S)
				return nil
			}
			libc.snprintf(transmute([^]u8)(&strbuf[0]), 30, cstring("%d"), C.int(total))
			result = transmute(^u8)(&strbuf[0])
		case SPEC_SID_O:
			if (^C.int)(&current_sctx_buf[0])^ <= 0 {
				errormsg^ = cstring(E81_S)
				return nil
			}
			libc.snprintf(transmute([^]u8)(&strbuf[0]), 30, cstring("<SNR>%d_"), (^C.int)(&current_sctx_buf[0])^)
			result = transmute(^u8)(&strbuf[0])
		case:
			errormsg^ = cstring("")
		}
		resultlen = libc.strlen(transmute(cstring)(result))
		if ([^]u8)(src)[uintptr(usedlen^)] == '<' {
			usedlen^ += 1
			dot := libc.strrchr(transmute([^]u8)(result), '.')
			if dot != nil && uintptr(rawptr(dot)) >= uintptr(rawptr(path_tail_e(transmute(cstring)(result)))) {
				resultlen = C.size_t(uintptr(rawptr(dot)) - uintptr(rawptr(result)))
			}
		} else if !skip_mod {
			valid |= modify_fname(transmute(^u8)(src), tilde_file, usedlen, transmute(^rawptr)(&result), transmute(^rawptr)(&resultbuf), &resultlen)
			if result == nil {
				errormsg^ = cstring("")
				return nil
			}
		}
	}
	if resultlen == 0 || valid != VALID_HEAD_O + VALID_PATH_O {
		if empty_is_error {
			if valid != VALID_HEAD_O + VALID_PATH_O {
				errormsg^ = cstring(E499_S)
			} else {
				errormsg^ = cstring(E500_S)
			}
		}
		result = nil
	} else {
		result = xmemdupz(rawptr(result), resultlen)
	}
	xfree(rawptr(resultbuf))
	return result
}

// —— Batch 9b: ex_docmd.c expand_filename (export + weak) ——
EXARG_DO_ECMD_LNUM_OFF :: 112
EXARG_ARGC_OFF :: 24
EXARG_ARGS_OFF :: 8
WILD_NOERROR_O :: 0x800
CMD_GREP_O :: 172
CMD_GREPADD_O :: 173
CMD_LGREP_O :: 239
CMD_LGREPADD_O :: 240
CMD_LMAKE_O :: 248
CMD_MAKE_O :: 275
CMD_TERMINAL_O :: 474

// Command-line splice helper (ex_docmd.c static).
repl_cmdline_o :: proc "c" (eap: rawptr, src: cstring, srclen: C.size_t, repl: cstring, cmdlinep: ^cstring) -> cstring {
	context = runtime.default_context()
	cmdline := ([^]cstring)(cmdlinep)[0]
	replen := libc.strlen(repl)
	i: C.size_t = C.size_t(uintptr(rawptr(src)) - uintptr(rawptr(cmdline))) + C.size_t(libc.strlen(transmute(cstring)(uintptr(rawptr(src)) + uintptr(srclen)))) + C.size_t(replen) + 3
	nextcmd := (^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^
	if nextcmd != nil {
		i += C.size_t(libc.strlen(transmute(cstring)(nextcmd)))
	}
	new_cmdline := transmute(^u8)(xmalloc(i))
	offset := uintptr(rawptr(src)) - uintptr(rawptr(cmdline))
	libc.memmove(rawptr(new_cmdline), rawptr(cmdline), uint(offset))
	libc.memmove(rawptr(uintptr(new_cmdline) + offset), rawptr(repl), uint(replen))
	i = C.size_t(offset) + C.size_t(replen)
	tail := transmute(cstring)(uintptr(rawptr(src)) + uintptr(srclen))
	libc.memmove(rawptr(uintptr(new_cmdline) + uintptr(i)), rawptr(tail), uint(libc.strlen(tail) + 1))
	ret := transmute(cstring)(uintptr(new_cmdline) + uintptr(i))
	if nextcmd != nil {
		i = C.size_t(libc.strlen(transmute(cstring)(new_cmdline))) + 1
		nt := transmute(cstring)(uintptr(new_cmdline) + uintptr(i))
		libc.memmove(rawptr(nt), nextcmd, uint(libc.strlen(transmute(cstring)(nextcmd)) + 1))
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^ = rawptr(nt)
	}
	eap_cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	eap_arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(new_cmdline) + (uintptr(rawptr(eap_cmd)) - uintptr(rawptr(cmdline))))
	([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(new_cmdline) + (uintptr(rawptr(eap_arg)) - uintptr(rawptr(cmdline))))
	argc := (^C.int)(uintptr(eap) + EXARG_ARGC_OFF)^
	args := (^rawptr)(uintptr(eap) + EXARG_ARGS_OFF)^
	for j: C.int = 0; j < argc; j += 1 {
		aj := ([^]rawptr)(args)[j]
		rel := uintptr(aj) - uintptr(rawptr(cmdline))
		if offset >= rel {
			([^]rawptr)(args)[j] = rawptr(uintptr(new_cmdline) + rel)
		} else {
			([^]rawptr)(args)[j] = rawptr(uintptr(new_cmdline) + uintptr(C.ssize_t(rel) + C.ssize_t(replen) - C.ssize_t(srclen)))
		}
	}
	do_ecmd_cmd := (^rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)^
	if do_ecmd_cmd != nil && do_ecmd_cmd != rawptr(&dollar_command[0]) {
		(^rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)^ = rawptr(uintptr(new_cmdline) + (uintptr(do_ecmd_cmd) - uintptr(rawptr(cmdline))))
	}
	xfree(rawptr(cmdline))
	([^]cstring)(cmdlinep)[0] = transmute(cstring)(new_cmdline)
	return ret
}

// Filename expand driver (ex_docmd.c public).
@(export)
expand_filename :: proc "c" (eap: rawptr, cmdlinep: ^cstring, errormsgp: ^cstring) -> C.int {
	context = runtime.default_context()
	p := skip_grep_pat_o(eap)
	eap_arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	has_wildcards := path_has_wildcard(p)
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '`' && ([^]u8)(p)[1] == '=' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 2)
			sp := p
			skip_expr(&sp, nil)
			p = sp
			if ([^]u8)(p)[0] == '`' {
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
			continue
		}
		if vim_strchr(transmute(^u8)(cstring("%#<")), C.int(([^]u8)(p)[0])) == nil {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			continue
		}
		srclen: C.size_t = 0
		escaped: C.int = 0
		repl := eval_vars(p, eap_arg, &srclen, transmute(^C.int)(uintptr(eap) + EXARG_DO_ECMD_LNUM_OFF), errormsgp, &escaped, true)
		if ([^]cstring)(errormsgp)[0] != nil {
			return FAIL_E
		}
		if repl == nil {
			p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(srclen))
			continue
		}
		if vim_strchr(repl, '$') != nil || vim_strchr(repl, '~') != nil {
			l := repl
			repl = transmute(^u8)(expand_env_save(transmute(cstring)(l)))
			xfree(rawptr(l))
		}
		cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
		argt := (^C.int)(uintptr(eap) + EXARG_ARGT_OFF)^
		usefilter := (^C.int)(uintptr(eap) + EXARG_USEFILTER_OFF)^
		if usefilter == 0 && escaped == 0 && cmdidx != CMD_BANG_O && cmdidx != CMD_GREP_O && cmdidx != CMD_GREPADD_O && cmdidx != CMD_LGREP_O && cmdidx != CMD_LGREPADD_O && cmdidx != CMD_LMAKE_O && cmdidx != CMD_MAKE_O && cmdidx != CMD_TERMINAL_O && (argt & EX_NOSPC_O) == 0 {
			l := repl
			for ([^]u8)(l)[0] != 0 {
				if vim_strchr(escape_chars_g, C.int(([^]u8)(l)[0])) != nil {
					nl := vim_strsave_escaped_c(repl, escape_chars_g)
					xfree(rawptr(repl))
					repl = nl
					break
				}
				l = transmute(^u8)(uintptr(l) + 1)
			}
		}
		if (usefilter != 0 || cmdidx == CMD_BANG_O || cmdidx == CMD_TERMINAL_O) && libc.strpbrk(transmute(cstring)(repl), cstring("!")) != nil {
			nl := vim_strsave_escaped_c(repl, transmute(^u8)(cstring("!")))
			xfree(rawptr(repl))
			repl = nl
		}
		p = repl_cmdline_o(eap, p, srclen, transmute(cstring)(repl), cmdlinep)
		xfree(rawptr(repl))
		eap_arg = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	}
	argt := (^C.int)(uintptr(eap) + EXARG_ARGT_OFF)^
	usefilter := (^C.int)(uintptr(eap) + EXARG_USEFILTER_OFF)^
	if (argt & EX_NOSPC_O) != 0 && usefilter == 0 {
		if has_wildcards {
			if vim_strchr(transmute(^u8)(eap_arg), '$') != nil || vim_strchr(transmute(^u8)(eap_arg), '~') != nil {
				expand_env_esc(eap_arg, transmute(cstring)(&name_buff[0]), MAXPATHL_O, cstring(" \t*?[{"), true, nil)
				has_wildcards = path_has_wildcard(transmute(cstring)(&name_buff[0]))
				p = transmute(cstring)(&name_buff[0])
			} else {
				p = nil
			}
			if p != nil {
				repl_cmdline_o(eap, eap_arg, libc.strlen(eap_arg), p, cmdlinep)
				eap_arg = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
			}
		}
		if !has_wildcards {
			backslash_halve(transmute(^u8)(eap_arg))
		}
		if has_wildcards {
			xpc: expand_T
			libc.memset(rawptr(&xpc), 0, size_of(expand_T))
			_ExpandInit(transmute(rawptr)(&xpc))
			xpc.xp_context = EXPAND_FILES
			options: C.int = WILD_LIST_NOTFOUND_O | WILD_NOERROR_O | C.int(WILD_ADD_SLASH)
			if p_wic_g != 0 {
				options += WILD_ICASE_O
			}
			p = _ExpandOne(transmute(rawptr)(&xpc), eap_arg, nil, options, WILD_EXPAND_FREE)
			if p == nil {
				return FAIL_E
			}
			repl_cmdline_o(eap, eap_arg, libc.strlen(eap_arg), p, cmdlinep)
			xfree(rawptr(p))
		}
	}
	return OK_E
}

// <sfile> expander (ex_docmd.c public).
@(export)
expand_sfile :: proc "c" (arg: cstring) -> ^u8 {
	context = runtime.default_context()
	result := xstrdup(transmute(^u8)(arg))
	p := result
	for ([^]u8)(p)[0] != 0 {
		if libc.strncmp(transmute(cstring)(p), cstring("<sfile>"), 7) != 0 {
			p = transmute(^u8)(uintptr(p) + 1)
		} else {
			srclen: C.size_t = 0
			errormsg: cstring = nil
			repl := eval_vars(transmute(cstring)(p), transmute(cstring)(result), &srclen, nil, &errormsg, nil, true)
			if errormsg != nil {
				if ([^]u8)(errormsg)[0] != 0 {
					emsg(errormsg)
				}
				xfree(rawptr(result))
				return nil
			}
			if repl == nil {
				p = transmute(^u8)(uintptr(p) + uintptr(srclen))
				continue
			}
			oldlen := libc.strlen(transmute(cstring)(result))
			replen := libc.strlen(transmute(cstring)(repl))
			nlen := oldlen - srclen + replen + 1
			newres := transmute(^u8)(xmalloc(nlen))
			off := uintptr(p) - uintptr(result)
			libc.memmove(rawptr(newres), rawptr(result), uint(off))
			libc.memcpy(rawptr(uintptr(newres) + off), rawptr(repl), replen + 1)
			nlen2 := libc.strlen(transmute(cstring)(newres))
			libc.strcat(transmute([^]u8)(newres), transmute(cstring)(transmute(^u8)(uintptr(p) + uintptr(srclen))))
			xfree(rawptr(repl))
			xfree(rawptr(result))
			result = newres
			p = transmute(^u8)(uintptr(newres) + uintptr(nlen2))
		}
	}
	return result
}

// —— Batch 10: ex_docmd.c findfunc cluster (exports + weak) ——
foreign _ {
	@(link_name = "expand_process_user_list")
	expand_process_user_list_e :: proc "c" (retlist: rawptr, matches: ^rawptr, numMatches: ^C.int, xp: ^expand_T) ---
}

OPTSET_VARP_OFF :: 0
OPTSET_FLAGS_OFF :: 12
OPTSET_BUF_OFF :: 80
KOPT_FINDFUNC_O :: 99
E1514_S :: "E1514: 'findfunc' did not return a List type"

// findfunc callback selector (ex_docmd.c static).
get_findfunc_callback_o :: proc "c" () -> ^Callback_E {
	context = runtime.default_context()
	if ([^]u8)((^rawptr)(uintptr(curbuf) + B_P_FFU_OFF)^)[0] != 0 {
		return (^Callback_E)(uintptr(curbuf) + B_FFU_CB_OFF)
	}
	return &ffu_cb
}

// findfunc invoker (ex_docmd.c static).
call_findfunc_o :: proc "c" (pat: cstring, cmdcomplete: C.int) -> rawptr {
	context = runtime.default_context()
	saved_sctx := transmute(sctx_T)(current_sctx_buf)
	args: [3]Typval_T
	args[0].v_type = VAR_STRING
	args[0].v_lock = VAR_UNLOCKED
	args[0].vval = transmute(rawptr)(pat)
	args[1].v_type = VAR_BOOL
	args[1].v_lock = VAR_UNLOCKED
	args[1].vval = transmute(rawptr)(C.longlong(cmdcomplete))
	args[2].v_type = VAR_UNKNOWN
	args[2].v_lock = VAR_UNLOCKED
	args[2].vval = nil
	textlock += 1
	ctx := get_option_sctx(KOPT_FINDFUNC_O)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, 24)
	}
	cb := get_findfunc_callback_o()
	rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED, vval = nil}
	retval := callback_call(cb, 2, &args[0], &rettv)
	current_sctx_buf = transmute([24]u8)(saved_sctx)
	textlock -= 1
	retlist: rawptr = nil
	if retval {
		if rettv.v_type == VAR_LIST {
			retlist = tv_list_copy(nil, transmute(rawptr)(rettv.vval), false, get_copyID())
		} else {
			emsg(cstring(E1514_S))
		}
		tv_clear(&rettv)
	}
	return retlist
}

// findfunc completion driver (ex_docmd.c public).
@(export)
expand_findfunc :: proc "c" (xp: ^expand_T, pat: cstring, files: ^rawptr, numMatches: ^C.int) -> C.int {
	context = runtime.default_context()
	numMatches^ = 0
	files^ = nil
	l := call_findfunc_o(pat, kBoolVarTrue)
	if l == nil {
		return FAIL_E
	}
	if tv_list_len_o(l) == 0 {
		tv_list_free(l)
		return FAIL_E
	}
	expand_process_user_list_e(l, files, numMatches, xp)
	tv_list_free(l)
	return OK_E
}

// —— Batch 11: ex_docmd.c smile + address-error leaves ——
E481_S :: "E481: No range allowed"
EX_ZEROR_O :: 4096

// Address error selector (ex_docmd.c static).
addr_error_o :: proc "c" (addr_type: C.int) -> cstring {
	context = runtime.default_context()
	if addr_type == ADDR_NONE_O {
		return cstring(E481_S)
	}
	return cstring(E16_S)
}

// Zero-range corrector (ex_docmd.c static).
correct_range_o :: proc "c" (eap: rawptr) {
	if ((^C.int)(uintptr(eap) + EXARG_ARGT_OFF)^ & EX_ZEROR_O) == 0 {
		if (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ == 0 {
			(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = 1
		}
		if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ == 0 {
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = 1
		}
	}
}

// Buffer-local count computer (ex_docmd.c static).
compute_buffer_local_count_o :: proc "c" (addr_type: C.int, lnum: C.int, offset: C.int) -> C.int {
	context = runtime.default_context()
	count := offset
	buf := firstbuf
	for (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ != nil && (^C.int)(uintptr(buf) + B_FNUM_OFF)^ < lnum {
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}
	for count != 0 {
		if count < 0 {
			count += 1
		} else {
			count -= 1
		}
		nextbuf: rawptr = nil
		if offset < 0 {
			nextbuf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
		} else {
			nextbuf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
		if nextbuf == nil {
			break
		}
		buf = nextbuf
		if addr_type == ADDR_LOADED_BUFFERS_O {
			for (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
				if offset < 0 {
					nextbuf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
				} else {
					nextbuf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				}
				if nextbuf == nil {
					break
				}
				buf = nextbuf
			}
		}
	}
	if addr_type == ADDR_LOADED_BUFFERS_O {
		for (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
			nextbuf: rawptr = nil
			if offset >= 0 {
				nextbuf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
			} else {
				nextbuf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
			}
			if nextbuf == nil {
				break
			}
			buf = nextbuf
		}
	}
	return (^C.int)(uintptr(buf) + B_FNUM_OFF)^
}

@(private = "file")
smile_art_g: [142]cstring = {
	" #xxn`          #xnxx`        ,+x@##@Mz;`        .xxxxxxxxxnz+,      znnnnnnnnnnnnnnnn.",
	" n###z          x####`      :x##########W+`      ,#############M;    W################.",
	" n####;         x####`    `z##############W:     ,################   W################.",
	" n####W.        x####`   ,W#################+    ,#################  W################.",
	" n#####n        x####`   @###################    ,#################i W################.",
	" n######i       x####`  .#########@W@########*   ,#################W`W################.",
	" n######@.      x####`  x######W*.  `;n#######:  ,####x,,,,:*M######iW###@:,,,,,,,,,,,`",
	" n#######n      x####` *######+`       :M#####M  ,####n      `x#####xW###@`",
	" n########*     x####``@####@;          `x#####i ,####n       ,#####@W###@`",
	" n########@     x####`*#####i            `M####M ,####n        x#########@`",
	" n#########     x####`M####z              :#####:,####n        z#########@`",
	" n#########*    x####,#####.               n####+,####n        n#########@`",
	" n####@####@,   x####i####x                ;####x,####n       `W#####@####+++++++++++i",
	" n####*#####M`  x#########*                `####@,####n       i#####MW###############W",
	" n####.######+  x####z####;                 W####,####n      i@######W###############W",
	" n####.`W#####: x####n####:                 M####:####@nnnnnW#######,W###############W",
	" n####. :#####M`x####z####;                 W####,#################z W###############W",
	" n####.  #######x#########*                `####W,################W` W###############W",
	" n####.  `M#####W####i####x                ;####x,###############W,  W####+**********i",
	" n####.   ,##########,#####.               n####+,##############n.   W###@`",
	" n####.    ##########`M####z              :#####:,###########Wz:     W###@`",
	" n####.    x#########`*#####i            `M####M ,####x.....`        W###@`",
	" n####.    ,@########``@####@;          `x#####i ,####n              W###@`",
	" n####.     *########` *#####@+`       ,M#####M  ,####n              W###@`",
	" n####.      x#######`  x######W*.  `;n######@:  ,####n              W###@,,,,,,,,,,,,`",
	" n####.      .@######`  .#########@W@########*   ,####n              W################,",
	" n####.       i######`   @###################    ,####n              W################,",
	" n####.        n#####`   ,W#################+    ,####n              W################,",
	" n####.        .@####`    .n##############W;     ,####n              W################,",
	" n####.         i####`      :x##########W+`      ,####n              W################,",
	" +nnnn`          +nnn`        ,+x@##@Mz;`        .nnnn+              zxxxxxxxxxxxxxxxx.",
	" ",
	"                                                                                   ,+M@#Mi",
	"                                                                                 .z########",
	"                                                                                i@#########i",
	"                                                                              `############W`",
	"                                                                             `n#############i",
	"                                                                            `n##############n",
	"     ``                                                                     z###############@`",
	"    `W@z,                                                                  ##################,",
	"    *#####`                                                               i############@x@###i",
	"    ######M.                                                             :#############n`,W##+",
	"    +######@:                                                           .W#########M@##+  *##z",
	"    :#######@:                                                         `x########@#x###*  ,##n",
	"    `@#######@;                                                        z#########M*@nW#i  .##x",
	"     z########@i                                                      *###########WM#@#,  `##x",
	"     i##########+                                                    ;###########*n###@   `##x",
	"     `@#MM#######x,                                                 ,@#########zM,`z##M   `@#x",
	"      n##M#W#######n.               `.:i*+#zzzz##+i:.`             ,W#########Wii,`n@#@` n@##n",
	"      ;###@#x#######n         `,i#nW@#####@@WWW@@####@Mzi.        ,W##########@z.. ;zM#+i####z",
	"       x####nz########    .;#x@##@Wn#*;,.`      ``,:*#x@##M+,    ;@########xz@WM+#` `n@#######",
	"       ,@####M########xi#@##@Mzi,`                     .+x###Mi:n##########Mz```.:i  *@######*",
	"        *#####W#########ix+:`                             :n#############z:       `*.`M######i",
	"        i#W##nW@+@##@#M@;                                   ;W@@##########W,        i`x@#####,",
	"        `@@n@Wn#@iMW*#*:                                     `iz#z@######x.           M######`",
	"         z##zM###x`*, .`                                          `iW#####W;:`        +#####M",
	"         ,###nn##n`                                                ,#####x;`        ,;@######",
	"          x###xz#.                                                   in###+        `:######@.",
	"          ;####n+                                                    `Mnx##xi`   , zM#######",
	"          `W####+                i.                                   `.+x###@#. :n,z######:",
	"           z####@`              ;#:                                     .ii@###@;.*M*z####@`",
	"           i####M         `   `i@#,           ::                           +#n##@+@##W####n",
	"           :####x    ,i. ##xzM###@`     i.   .@@,                           .z####x#######*",
	"           ,###W;   i##Wz#########     :##   z##n                           ,@########x###:",
	"            n##n   `W###########M`;n,  i#x  ,###@i                           *W########W#@`",
	"           .@##+  `x###########@. z#+ .M#W``x#####n`                         `;#######@z#x",
	"           n###z :W############@  z#*  @##xM#######@n;                        `########nW+",
	"          ;####nW##############W :@#* `@#############*                        :########z@i`",
	"          M##################### M##:  @#############@:                       *W########M#",
	"         ;#####################i.##x`  W#############W,                       :n########zx",
	"         x####################@.`x;    @#############z.                       .@########W#",
	"        ,######################`       W###############x*,`                    W######zM#i",
	"        #######################:       z##################@x+*#zzi            `@#########.",
	"        W########W#z#M#########;       *##########################z            :@#######@`",
	"       `@#######x`;#z ,x#######;       z###########M###xnM@########*            :M######@",
	"       i########, x#@`  z######;       *##########i *#@`  `+########+`            n######.",
	"       n#######@` M##,  `W#####.       *#########z  ###;    z########M:           :W####n",
	"       M#######M  n##.   x####x        `x########:  z##+    M#########@;           .n###+",
	"       W#######@` :#W   `@####:         `@######W   i###   ;###########@.            n##n",
	"       W########z` ,,  .x####z           @######@`  `W#;  `W############*            *###;",
	"      `@#########Mi,:*n@####W`           W#######*   ..  `n#############i            i###x",
	"      .#####################z           `@#######@*`    .x############n:`            ;####.",
	"      :####################x`,,`        `W#########@x#+#@#############i              ,####:",
	"      ;###################x#@###xi`      *############################:              `####i",
	"      i##################+########M,      x##########################@`               W###i",
	"      *################@; @########@,     .W#########################@                x###:",
	"      .+M#############z.  M#########x      ,W########################@`               ####.",
	"      *M*;z@########x:    :W#######i        .M########################i               i###:",
	"      *##@z;#@####x:        :z###@i          `########################x               .###;",
	"      *#####n;#@##            ;##*             ,x#####################@`               W##*",
	"      *#######n;*            :M##W*,             *W####################`               n##z",
	"      i########@.         ,*n#######M*`           `###################M                *##M",
	"      i########n        `z#####@@#####Wi            ,M################;                ,##@`",
	"      ;WMWW@###*       .x##@ni.``.:+zW##z`           `n##############z                  @##,",
	"      .*++*i;;;.      .M#@+`          .##n            `x############x`                  n##i",
	"      :########*      x#W,              *#+            *###########M`                   +##+",
	"      ,#########     :#@:                ##:           #nzzzzzzzzzz.                    :##x",
	"      .#####Wz+`     ##+                 `MM`          .znnnnnnnnn.                     `@#@`",
	"      `@@ni;*nMz`    @W`                  :#+           .x#######n                       x##,",
	"       i;z@#####,   .#*                    z#:           ;;;*zW##;                       ###i",
	"       z########:   :#;                    `Wx          +###Wni;n.                       ;##z",
	"       n########W:  .#*                     ,#,        ;#######@+                        `@#M",
	"      .###########n;.MM                      n*        ;iM#######*                        x#@`",
	"      :#############@;;                      .n`      ,#W*iW#####W`                       +##,",
	"      ,##############.                        ix.    `x###M;#######                       ,##i",
	"      .#############@`                         x@n**#W######z;M###@.                       W##",
	"      .##############W:                        .x############@*;zW#;                       z#x",
	"      ,###############@;                        `##############@n*;.                       i#@",
	"      ,#################i                         :n##############W`                       .##,",
	"      ,###################`                         .+W##########W,                        `##i",
	"      :###################@zi,`                        ;zM@@@WMn*`                          @#z",
	"      :#######################@x+*i;;:i#M,                 ``                               M#W",
	"      ;################################@x.                                                  n##,",
	"      i#####################@W@@@@Wxz*:`                                                    *##+",
	"      *######################+```                                                           :##M",
	"      ########################M;                                                            `@##,",
	"      z#########################x,                                                           z###",
	"      n###########################n:                                                         ;##W`",
	"      x#############################Mz#++##*                                                 `W##i",
	"      M####################################@`                                                 ###x",
	"      W#####################################`                                                 .###,",
	"      @####################################M                                                   n##z",
	"      @##################z*i@WMMMx#x@#####,.                                                   :##@.",
	"     `#####################@xi`     `::,*                                                       x##+",
	"     .#####################@#M.                                                                 ;##@`",
	"     ,#####################:.                                                                    M##i",
	"     ;###################ni`                                                                     i##M",
	"     *#################W#`                                                                       `W##,",
	"     z#################@Wx+.                                                                      +###",
	"     x######################z.                                                                    .@#@`",
	"    `@#######################@;                                                                    z##;",
	"    :##########################:                                                                   :##z",
	"    +#########################W#                                                                    M#W",
	"    W################@n+*i;:,`                                                                      +##,",
	"   :##################WMxz+,                                                                        ,##i",
	"   n#######################W..,                                                                      W##",
	"  +#########################WW@+. .:.                                                                z#x",
	" `@#############################@@###:                                                               *#W",
	" #################################Wz:                                                                :#@",
	",@###############################i                                                                   .##",
	"n@@@@@@@#########################+                                                                   `##",
	"`      `.:.`.,:iii;;;;;;;;iii;;;:`       `.``                                                        `nW",
}

// :smile easter egg (ex_docmd.c public).
@(export)
verify_command :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	if libc.strcmp(cstring("smile"), cmd) != 0 {
		return
	}
	a: C.int = HLF_E_O
	for s in smile_art_g {
		msg_msg(s, a)
	}
}

// —— Batch 12: ex_docmd.c address engine (exports + weak) ——
foreign _ {
	@(link_name = "skip_regexp")
	skip_regexp_e :: proc "c" (startp: ^u8, delim: C.int, magic: C.int) -> ^u8 ---
	@(link_name = "qf_get_size")
	qf_get_size_e :: proc "c" (eap: rawptr) -> C.size_t ---
}

EXARG_ERRMSG_OFF :: 160
W_CURSOR_COL_OFF :: 140
E1247_S :: "E1247: Line number out of range"
E319_NI_S :: "E319: The command is not available in this version"

// Single-address parser (ex_docmd.c public).
@(export)
get_address :: proc "c" (eap: rawptr, ptr: ^cstring, addr_type: C.int, skip: bool, silent: bool, to_other_file: C.int, address_count: C.int, errormsg: ^cstring) -> C.int {
	context = runtime.default_context()
	cmd := skipwhite(([^]cstring)(ptr)[0])
	lnum: C.int = MAXLNUM
	c: C.int
	i: C.int
	n: C.int
	pos: Pos_T
	for {
		c0 := ([^]u8)(cmd)[0]
		if c0 == '.' {
			cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
				lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
			} else if addr_type == ADDR_WINDOWS_O {
				lnum = current_win_nr_o(curwin)
			} else if addr_type == ADDR_ARGUMENTS_O {
				lnum = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
			} else if addr_type == ADDR_LOADED_BUFFERS_O || addr_type == ADDR_BUFFERS_O {
				lnum = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
			} else if addr_type == ADDR_TABS_O {
				lnum = current_tab_nr_o(curtab)
			} else if addr_type == ADDR_NONE_O || addr_type == ADDR_TABS_RELATIVE_O || addr_type == ADDR_UNSIGNED_O {
				errormsg^ = addr_error_o(addr_type)
				cmd = nil
			} else if addr_type == ADDR_QUICKFIX_O {
				lnum = C.int(qf_get_cur_idx_e(eap))
			} else if addr_type == ADDR_QUICKFIX_VALID_O {
				lnum = qf_get_cur_valid_idx_e(eap)
			}
		} else if c0 == '$' {
			cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
				lnum = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
			} else if addr_type == ADDR_WINDOWS_O {
				lnum = current_win_nr_o(nil)
			} else if addr_type == ADDR_ARGUMENTS_O {
				lnum = (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^))^
			} else if addr_type == ADDR_LOADED_BUFFERS_O {
				buf := lastbuf_g
				for (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
					if (^rawptr)(uintptr(buf) + B_PREV_OFF)^ == nil {
						break
					}
					buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
				}
				lnum = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
			} else if addr_type == ADDR_BUFFERS_O {
				lnum = (^C.int)(uintptr(lastbuf_g) + B_FNUM_OFF)^
			} else if addr_type == ADDR_TABS_O {
				lnum = current_tab_nr_o(nil)
			} else if addr_type == ADDR_NONE_O || addr_type == ADDR_TABS_RELATIVE_O || addr_type == ADDR_UNSIGNED_O {
				errormsg^ = addr_error_o(addr_type)
				cmd = nil
			} else if addr_type == ADDR_QUICKFIX_O {
				lnum = C.int(qf_get_size_e(eap))
				if lnum == 0 {
					lnum = 1
				}
			} else if addr_type == ADDR_QUICKFIX_VALID_O {
				lnum = C.int(qf_get_valid_size_e(eap))
				if lnum == 0 {
					lnum = 1
				}
			}
		} else if c0 == '\'' {
			cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			if ([^]u8)(cmd)[0] == 0 {
				cmd = nil
			} else if addr_type != ADDR_LINES_O {
				errormsg^ = addr_error_o(addr_type)
				cmd = nil
			} else if skip {
				cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			} else {
				mflag: C.int = kMarkBufLocal
				if to_other_file != 0 && ([^]u8)(cmd)[1] == 0 {
					mflag = kMarkAll
				}
				fm := mark_get(curbuf, curwin, nil, mflag, C.int(([^]u8)(cmd)[0]))
				cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
				if fm != nil && fm.fnum != (^C.int)(uintptr(curbuf))^ {
					mark_move_to(fm, 0)
					lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				} else {
					if !mark_check(fm, errormsg) {
						cmd = nil
					} else {
						if fm == nil {
							libc.abort()
						}
						lnum = fm.mark.lnum
					}
				}
			}
		} else if c0 == '/' || c0 == '?' {
			c = C.int(c0)
			cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			if addr_type != ADDR_LINES_O {
				errormsg^ = addr_error_o(addr_type)
				cmd = nil
			} else if skip {
				mg: C.int = 0
				if magic_isset() {
					mg = 1
				}
				cmd = transmute(cstring)(skip_regexp_e(transmute(^u8)(cmd), c, mg))
				if ([^]u8)(cmd)[0] == u8(c) {
					cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
				}
			} else {
				pos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				if lnum > 0 && lnum != MAXLNUM {
					lc := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
					if lnum > lc {
						lc = lnum
					}
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lc
				}
				if c == '/' && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > 0 {
					(^C.int)(uintptr(curwin) + W_CURSOR_COL_OFF)^ = MAXCOL
				} else {
					(^C.int)(uintptr(curwin) + W_CURSOR_COL_OFF)^ = 0
				}
				searchcmdlen = 0
				flags: C.int = SEARCH_HIS | SEARCH_MSG
				if silent {
					flags = SEARCH_KEEP_O
				}
				if do_search(nil, c, c, transmute(^u8)(cmd), libc.strlen(cmd), 1, flags, nil) == 0 {
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
					cmd = nil
				} else {
					lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
					cmd = transmute(cstring)(uintptr(rawptr(cmd)) + uintptr(searchcmdlen))
				}
			}
		} else if c0 == '\\' {
			cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
			if addr_type != ADDR_LINES_O {
				errormsg^ = addr_error_o(addr_type)
				cmd = nil
			} else {
				if ([^]u8)(cmd)[0] == '&' {
					i = RE_SUBST_O
				} else if ([^]u8)(cmd)[0] == '?' || ([^]u8)(cmd)[0] == '/' {
					i = RE_SEARCH_O
				} else {
					errormsg^ = cstring(E10_S)
					cmd = nil
					i = 0
				}
				if cmd != nil && !skip {
					if lnum != MAXLNUM {
						pos.lnum = lnum
					} else {
						pos.lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					}
					if ([^]u8)(cmd)[0] != '?' {
						pos.col = MAXCOL
					} else {
						pos.col = 0
					}
					pos.coladd = 0
					sdir := Direction.FORWARD
					if ([^]u8)(cmd)[0] == '?' {
						sdir = Direction.BACKWARD
					}
					if searchit(curwin, curbuf, &pos, nil, sdir, transmute(^u8)(cstring("")), 0, 1, SEARCH_MSG, i, nil) != FAIL_E {
						lnum = pos.lnum
					} else {
						cmd = nil
					}
				}
				if cmd != nil {
					cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
				}
			}
		} else if ascii_isdigit_o(c0) {
			lnum = C.int(getdigits(&cmd, false, 0))
		}
		if cmd != nil {
			for {
				cmd = skipwhite(cmd)
				cc := ([^]u8)(cmd)[0]
				if cc != '-' && cc != '+' && !ascii_isdigit_o(cc) {
					break
				}
				if lnum == MAXLNUM {
					if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
						lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					} else if addr_type == ADDR_WINDOWS_O {
						lnum = current_win_nr_o(curwin)
					} else if addr_type == ADDR_ARGUMENTS_O {
						lnum = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
					} else if addr_type == ADDR_LOADED_BUFFERS_O || addr_type == ADDR_BUFFERS_O {
						lnum = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
					} else if addr_type == ADDR_TABS_O {
						lnum = current_tab_nr_o(curtab)
					} else if addr_type == ADDR_TABS_RELATIVE_O {
						lnum = 1
					} else if addr_type == ADDR_QUICKFIX_O {
						lnum = C.int(qf_get_cur_idx_e(eap))
					} else if addr_type == ADDR_QUICKFIX_VALID_O {
						lnum = qf_get_cur_valid_idx_e(eap)
					} else if addr_type == ADDR_NONE_O || addr_type == ADDR_UNSIGNED_O {
						lnum = 0
					}
				}
				if ascii_isdigit_o(([^]u8)(cmd)[0]) {
					i = '+'
				} else {
					i = C.int(([^]u8)(cmd)[0])
					cmd = transmute(cstring)(uintptr(rawptr(cmd)) + 1)
				}
				if !ascii_isdigit_o(([^]u8)(cmd)[0]) {
					n = 1
				} else {
					cs2 := transmute(^u8)(cmd)
					n = getdigits_int32(&cs2, false, MAXLNUM)
					cmd = transmute(cstring)(cs2)
					if n == MAXLNUM {
						errormsg^ = cstring(E1247_S)
						cmd = nil
						break
					}
				}
				if cmd == nil {
					break
				}
				if addr_type == ADDR_TABS_RELATIVE_O {
					errormsg^ = cstring(E16_S)
					cmd = nil
					break
				} else if addr_type == ADDR_LOADED_BUFFERS_O || addr_type == ADDR_BUFFERS_O {
					nn := n
					if i == '-' {
						nn = -1 * n
					}
					lnum = compute_buffer_local_count_o(addr_type, lnum, nn)
				} else {
					if addr_type == ADDR_LINES_O && (i == '-' || i == '+') && address_count >= 2 {
						ln2 := lnum
						hasFolding(curwin, lnum, nil, &ln2)
						lnum = ln2
					}
					if i == '-' {
						lnum -= n
					} else {
						if lnum >= 0 && n >= max(C.int) - lnum {
							errormsg^ = cstring(E1247_S)
							cmd = nil
							break
						}
						lnum += n
					}
				}
			}
		}
		if cmd == nil {
			break
		}
		if ([^]u8)(cmd)[0] != '/' && ([^]u8)(cmd)[0] != '?' {
			break
		}
	}
	([^]cstring)(ptr)[0] = cmd
	return lnum
}

// Flag-letter parser (ex_docmd.c static).
get_flags_o :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	for {
		arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
		if vim_strchr(transmute(^u8)(cstring("lp#")), C.int(([^]u8)(arg)[0])) == nil {
			break
		}
		b := ([^]u8)(arg)[0]
		if b == 'l' {
			([^]C.int)(uintptr(eap) + EXARG_FLAGS_OFF)[0] |= EXFLAG_LIST_O
		} else if b == 'p' {
			([^]C.int)(uintptr(eap) + EXARG_FLAGS_OFF)[0] |= EXFLAG_PRINT_O
		} else {
			([^]C.int)(uintptr(eap) + EXARG_FLAGS_OFF)[0] |= EXFLAG_NR_O
		}
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = skipwhite(transmute(cstring)(uintptr(rawptr(arg)) + 1))
	}
}

// Not-implemented stub (ex_docmd.c public).
@(export)
ex_ni :: proc "c" (eap: rawptr) {
	if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
		([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E319_NI_S)
	}
}

// —— Batch 13: ex_docmd.c range-list parser (export + weak) ——

// Range-list parser (ex_docmd.c public).
@(export)
parse_cmd_address :: proc "c" (eap: rawptr, errormsg: ^cstring, silent: bool) -> C.int {
	context = runtime.default_context()
	address_count: C.int = 1
	lnum: C.int
	need_check_cursor := false
	ret: C.int = FAIL_E
	done := false
	failed := false
	for !done {
		([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = get_cmd_default_range(eap)
		([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = skipwhite(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])
		skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^
		addr_count := (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^
		first := C.int(0)
		if addr_count == 0 {
			first = 1
		}
		lnum = get_address(eap, transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^, skip, silent, first, address_count, errormsg)
		address_count += 1
		if ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] == nil {
			failed = true
			break
		}
		if lnum == MAXLNUM {
			cmdch := ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0]
			if cmdch == '%' {
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 1)
				addr_type := (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^
				if addr_type == ADDR_LINES_O || addr_type == ADDR_OTHER_O {
					([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 1
					([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
				} else if addr_type == ADDR_LOADED_BUFFERS_O {
					buf := firstbuf
					for (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ != nil && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
						buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
					}
					([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
					buf = lastbuf_g
					for (^rawptr)(uintptr(buf) + B_PREV_OFF)^ != nil && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
						buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
					}
					([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
				} else if addr_type == ADDR_BUFFERS_O {
					([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = (^C.int)(uintptr(firstbuf) + B_FNUM_OFF)^
					([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = (^C.int)(uintptr(lastbuf_g) + B_FNUM_OFF)^
				} else if addr_type == ADDR_WINDOWS_O || addr_type == ADDR_TABS_O {
					if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ < 0 {
						([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 1
						if addr_type == ADDR_WINDOWS_O {
							([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = current_win_nr_o(nil)
						} else {
							([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = current_tab_nr_o(nil)
						}
					} else {
						errormsg^ = cstring(E16_S)
						failed = true
						break
					}
				} else if addr_type == ADDR_TABS_RELATIVE_O || addr_type == ADDR_UNSIGNED_O || addr_type == ADDR_QUICKFIX_O {
					errormsg^ = cstring(E16_S)
					failed = true
					break
				} else if addr_type == ADDR_ARGUMENTS_O {
					argc := (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^))^
					if argc == 0 {
						([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 0
						([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = 0
					} else {
						([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 1
						([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = argc
					}
				} else if addr_type == ADDR_QUICKFIX_VALID_O {
					([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 1
					([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = C.int(qf_get_valid_size_e(eap))
					if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == 0 {
						([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = 1
					}
				} else if addr_type == ADDR_NONE_O {
					// Will give an error later if a range is found.
				}
				([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] += 1
			} else if cmdch == '*' {
				if (^C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)^ != ADDR_LINES_O {
					errormsg^ = cstring(E16_S)
					failed = true
					break
				}
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 1)
				if !skip {
					fm := mark_get_visual(curbuf, '<')
					if !mark_check(fm, errormsg) {
						failed = true
						break
					}
					if fm == nil {
						libc.abort()
					}
					([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = fm.mark.lnum
					fm = mark_get_visual(curbuf, '>')
					if !mark_check(fm, errormsg) {
						failed = true
						break
					}
					if fm == nil {
						libc.abort()
					}
					([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = fm.mark.lnum
					([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] += 1
				}
			}
		} else {
			([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = lnum
		}
		([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] += 1
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == ';' {
			if !skip {
				([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
				if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] > 0 {
					check_cursor(curwin)
				} else {
					check_cursor_col(curwin)
				}
				need_check_cursor = true
			}
		} else if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] != ',' {
			done = true
			continue
		}
		([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 1)
	}
	if !failed {
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 1 {
			([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
			if lnum == MAXLNUM {
				([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] = 0
			}
		}
		ret = OK_E
	}
	if need_check_cursor {
		check_cursor(curwin)
	}
	return ret
}

// —— Batch 14: ex_docmd.c modifier parser (export + weak) ——
foreign _ {
	@(link_name = "getexline")
	getexline_e :: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> ^u8 ---
	@(link_name = "nvim_odin_exmode_plus_addr")
	nvim_odin_exmode_plus_addr_e :: proc "c" () -> rawptr ---
}

CMOD_FLAGS_OFF :: 0
CMOD_FILTER_PAT_OFF :: 16
CMOD_REGPROG_OFF :: 24
CMOD_FILTER_FORCE_OFF :: 200
CMOD_VERBOSE_OFF :: 204
CMOD_SANDBOX_O :: 0x0001
CMOD_SILENT_O :: 0x0002
CMOD_ERRSILENT_O :: 0x0004
CMOD_UNSILENT_O :: 0x0008
CMOD_NOAUTOCMD_O :: 0x0010
CMOD_BROWSE_O :: 0x0040

// Command-modifier parser (ex_docmd.c public).
@(export)
parse_command_modifiers :: proc "c" (eap: rawptr, errormsg: ^cstring, cmod: rawptr, skip_only: bool) -> C.int {
	context = runtime.default_context()
	orig_cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	cmd_start: cstring = nil
	use_plus_cmd := false
	has_visual_range := false
	libc.memset(cmod, 0, 248)
	if libc.strncmp(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0], cstring("'<,'>"), 5) == 0 {
		p := skipwhite(transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 5))
		if ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '|' {
			([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 5)
			cmd_start = ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
			has_visual_range = true
		}
	}
	outer_done := false
	for !outer_done {
		for {
			cb := ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0]
			if cb != ' ' && cb != '\t' && cb != ':' {
				break
			}
			([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 1)
		}
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 0 && exmode_active && getline_equal((^LineGetter)(uintptr(eap) + EXARG_GETLINE_OFF)^, (^rawptr)(uintptr(eap) + EXARG_COOKIE_OFF)^, transmute(LineGetter)(getexline_e)) && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
			([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(nvim_odin_exmode_plus_addr_e())
			use_plus_cmd = true
			if !skip_only {
				ex_pressedreturn = true
			}
		}
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == '"' {
			nx := vim_strchr(transmute(^u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]), '\n')
			if nx != nil {
				([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(uintptr(nx) + 1)
			}
			return FAIL_E
		}
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == '\n' {
			([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) + 1)
			return FAIL_E
		}
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 0 {
			if !skip_only {
				ex_pressedreturn = true
			}
			return FAIL_E
		}
		p := skip_range(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0], nil)
		matched := true
		pc := ([^]u8)(p)[0]
		if pc == 'a' {
			if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("aboveleft"), 3) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_ABOVE_O
			}
		} else if pc == 'b' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("belowright"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_BELOW_O
			} else if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("browse"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_BROWSE_O
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("botright"), 2) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_BOT_O
			}
		} else if pc == 'c' {
			if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("confirm"), 4) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_CONFIRM_O
			}
		} else if pc == 'k' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("keepmarks"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_KEEPMARKS_O
			} else if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("keepalt"), 5) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_KEEPALT_O
			} else if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("keeppatterns"), 5) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_KEEPPATTERNS_O
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("keepjumps"), 5) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_KEEPJUMPS
			}
		} else if pc == 'f' {
			matched = false
			fp := p
			if checkforcmd(&fp, cstring("filter"), 4) && ([^]u8)(fp)[0] != 0 && ends_excmd(C.int(([^]u8)(fp)[0])) == 0 {
				if ([^]u8)(fp)[0] == '!' {
					([^]bool)(uintptr(cmod) + CMOD_FILTER_FORCE_OFF)[0] = true
					fp = skipwhite(transmute(cstring)(uintptr(rawptr(fp)) + 1))
					if ([^]u8)(fp)[0] == 0 || ends_excmd(C.int(([^]u8)(fp)[0])) != 0 {
						fp = nil
					}
				}
				if fp != nil {
					reg_pat: ^u8 = nil
					if skip_only {
						fp = transmute(cstring)(skip_vimgrep_pat(transmute(^u8)(fp), nil, nil))
					} else {
						fp = transmute(cstring)(skip_vimgrep_pat(transmute(^u8)(fp), &reg_pat, nil))
					}
					if fp != nil && ([^]u8)(fp)[0] != 0 {
						if !skip_only {
							rp := reg_pat
							([^]rawptr)(uintptr(cmod) + CMOD_FILTER_PAT_OFF)[0] = rawptr(xstrdup(rp))
							([^]rawptr)(uintptr(cmod) + CMOD_REGPROG_OFF)[0] = vim_regcomp(transmute(cstring)(rp), RE_MAGIC)
							if ([^]rawptr)(uintptr(cmod) + CMOD_REGPROG_OFF)[0] == nil {
								fp = nil
							}
						}
						if fp != nil {
							([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = fp
							matched = true
						}
					}
				}
			}
		} else if pc == 'h' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("horizontal"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_HOR_O
			} else {
				hp := p
				if p == ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] && checkforcmd(&hp, cstring("hide"), 3) && ([^]u8)(hp)[0] != 0 && ends_excmd(C.int(([^]u8)(hp)[0])) == 0 {
					([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = hp
					([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_HIDE_O
				} else {
					matched = false
				}
			}
		} else if pc == 'l' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("lockmarks"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_LOCKMARKS_O
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("leftabove"), 5) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_ABOVE_O
			}
		} else if pc == 'n' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("noautocmd"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_NOAUTOCMD_O
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("noswapfile"), 3) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_NOSWAPFILE_S
			}
		} else if pc == 'r' {
			if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("rightbelow"), 6) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_BELOW_O
			}
		} else if pc == 's' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("sandbox"), 3) {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_SANDBOX_O
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("silent"), 3) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_SILENT_O
				ea_cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
				if ([^]u8)(ea_cmd)[0] == '!' {
					prev := ([^]u8)(uintptr(rawptr(ea_cmd)) - 1)[0]
					if prev != ' ' && prev != '\t' {
						([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = skipwhite(transmute(cstring)(uintptr(rawptr(ea_cmd)) + 1))
						([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_ERRSILENT_O
					}
				}
			}
		} else if pc == 't' {
			tp := p
			if checkforcmd(&tp, cstring("tab"), 3) {
				if !skip_only {
					tabnr := get_address(eap, transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), ADDR_TABS_O, (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^, skip_only, 0, 1, errormsg)
					if ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] == nil {
						return 0
					}
					if tabnr == MAXLNUM {
						([^]C.int)(uintptr(cmod) + CMOD_TAB_OFF)[0] = tabpage_index(curtab) + 1
					} else {
						if tabnr < 0 || tabnr > current_tab_nr_o(nil) {
							errormsg^ = cstring(E16_S)
							return 0
						}
						([^]C.int)(uintptr(cmod) + CMOD_TAB_OFF)[0] = tabnr + 1
					}
				}
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = tp
			} else if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("topleft"), 2) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_TOP_O
			}
		} else if pc == 'u' {
			if !checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("unsilent"), 3) {
				matched = false
			} else {
				([^]C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)[0] |= CMOD_UNSILENT_O
			}
		} else if pc == 'v' {
			if checkforcmd(transmute(^cstring)(uintptr(eap) + EXARG_CMD_OFF), cstring("vertical"), 4) {
				([^]C.int)(uintptr(cmod) + CMOD_SPLIT_OFF)[0] |= WSP_VERT_O
			} else {
				vp := p
				if !checkforcmd(&vp, cstring("verbose"), 4) {
					matched = false
				} else {
					if ascii_isdigit_o(([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0]) {
						([^]C.int)(uintptr(cmod) + CMOD_VERBOSE_OFF)[0] = libc.atoi(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]) + 1
					} else {
						([^]C.int)(uintptr(cmod) + CMOD_VERBOSE_OFF)[0] = 2
					}
					([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = vp
				}
			}
		} else {
			matched = false
		}
		if !matched {
			outer_done = true
		}
	}
	if has_visual_range {
		if ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] > cmd_start {
			if use_plus_cmd {
				ln := libc.strlen(cmd_start)
				libc.memmove(rawptr(orig_cmd), rawptr(cmd_start), uint(ln))
				xmemcpyz(rawptr(uintptr(rawptr(orig_cmd)) + uintptr(ln)), rawptr(transmute(^u8)(cstring(" *+"))), 3)
			} else {
				mvlen := uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) - uintptr(rawptr(cmd_start))
				libc.memmove(rawptr(uintptr(rawptr(cmd_start)) - 5), rawptr(cmd_start), uint(mvlen))
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) - 5)
				dst := transmute(^u8)(transmute(cstring)(uintptr(rawptr(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])) - 1))
				src6 := transmute(^u8)(cstring(":'<,'>"))
				for k: uint = 0; k < 6; k += 1 {
					([^]u8)(dst)[k] = ([^]u8)(src6)[k]
				}
			}
		} else {
			if use_plus_cmd {
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = cstring("'<,'>+")
			} else {
				([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = orig_cmd
			}
		}
	} else if use_plus_cmd {
		([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = transmute(cstring)(nvim_odin_exmode_plus_addr_e())
	}
	return OK_E
}

// —— Batch 15: ex_docmd.c cmdmod apply/state (exports + weak) ——
foreign _ {
	@(link_name = "finish_op")
	finish_op_g: bool
	@(link_name = "opcount")
	opcount_g: C.int
	@(link_name = "force_restart_edit")
	force_restart_edit_g: bool
	@(link_name = "redirecting")
	redirecting_e :: proc "c" () -> C.int ---
}

SST_MSGSCROLL_OFF :: 0
SST_RESTARTEDIT_OFF :: 4
SST_MSGDIDOUT_OFF :: 8
SST_STATE_OFF :: 12
SST_FINISHOP_OFF :: 16
SST_OPCOUNT_OFF :: 20
SST_REGEXEC_OFF :: 24
SST_PENDING_OFF :: 28
SST_TABUF_OFF :: 32
SST_VALID_OFF :: 80
CMOD_SAVE_EI_OFF :: 208
CMOD_DID_SANDBOX_OFF :: 216
CMOD_VERBOSE_SAVE_OFF :: 224
CMOD_SAVE_MSG_SILENT_OFF :: 232
CMOD_SAVE_MSG_SCROLL_OFF :: 236
CMOD_DID_ESILENT_OFF :: 240

// Command-modifier applier (ex_docmd.c public).
@(export)
apply_cmdmod :: proc "c" (cmod: rawptr) {
	context = runtime.default_context()
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & CMOD_SANDBOX_O) != 0 && !(^bool)(uintptr(cmod) + CMOD_DID_SANDBOX_OFF)^ {
		sandbox += 1
		(^bool)(uintptr(cmod) + CMOD_DID_SANDBOX_OFF)^ = true
	}
	if (^C.int)(uintptr(cmod) + CMOD_VERBOSE_OFF)^ > 0 {
		if (^C.int)(uintptr(cmod) + CMOD_VERBOSE_SAVE_OFF)^ == 0 {
			(^C.int)(uintptr(cmod) + CMOD_VERBOSE_SAVE_OFF)^ = p_verbose + 1
		}
		p_verbose = (^C.int)(uintptr(cmod) + CMOD_VERBOSE_OFF)^ - 1
	}
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & (CMOD_SILENT_O | CMOD_UNSILENT_O)) != 0 && (^C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)^ == 0 {
		([^]C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)[0] = msg_silent + 1
		([^]C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SCROLL_OFF)[0] = msg_scroll
	}
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & CMOD_SILENT_O) != 0 {
		msg_silent += 1
	}
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & CMOD_UNSILENT_O) != 0 {
		msg_silent = 0
	}
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & CMOD_ERRSILENT_O) != 0 {
		emsg_silent += 1
		([^]C.int)(uintptr(cmod) + CMOD_DID_ESILENT_OFF)[0] += 1
	}
	if ((^C.int)(uintptr(cmod) + CMOD_FLAGS_OFF)^ & CMOD_NOAUTOCMD_O) != 0 && (^rawptr)(uintptr(cmod) + CMOD_SAVE_EI_OFF)^ == nil {
		([^]rawptr)(uintptr(cmod) + CMOD_SAVE_EI_OFF)[0] = rawptr(xstrdup(p_ei_g))
		set_option_direct(kOptEventignore_E, str_optval(transmute(^u8)(cstring("all")), 3), 0, SID_NONE_O)
	}
}

// Command-modifier undo (ex_docmd.c public).
@(export)
undo_cmdmod :: proc "c" (cmod: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(cmod) + CMOD_VERBOSE_SAVE_OFF)^ > 0 {
		p_verbose = (^C.int)(uintptr(cmod) + CMOD_VERBOSE_SAVE_OFF)^ - 1
		(^C.int)(uintptr(cmod) + CMOD_VERBOSE_SAVE_OFF)^ = 0
	}
	if (^bool)(uintptr(cmod) + CMOD_DID_SANDBOX_OFF)^ {
		sandbox -= 1
		(^bool)(uintptr(cmod) + CMOD_DID_SANDBOX_OFF)^ = false
	}
	if (^rawptr)(uintptr(cmod) + CMOD_SAVE_EI_OFF)^ != nil {
		ei := (^rawptr)(uintptr(cmod) + CMOD_SAVE_EI_OFF)^
		set_option_direct(kOptEventignore_E, str_optval(transmute(^u8)(ei), C.size_t(libc.strlen(transmute(cstring)(ei)))), 0, SID_NONE_O)
		free_string_option(transmute(^u8)(ei))
		(^rawptr)(uintptr(cmod) + CMOD_SAVE_EI_OFF)^ = nil
	}
	xfree((^rawptr)(uintptr(cmod) + CMOD_FILTER_PAT_OFF)^)
	vim_regfree((^rawptr)(uintptr(cmod) + CMOD_REGPROG_OFF)^)
	if (^C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)^ > 0 {
		if did_emsg_flag == 0 || msg_silent > (^C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)^ - 1 {
			msg_silent = (^C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)^ - 1
		}
		emsg_silent -= ([^]C.int)(uintptr(cmod) + CMOD_DID_ESILENT_OFF)[0]
		if emsg_silent < 0 {
			emsg_silent = 0
		}
		msg_scroll = ([^]C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SCROLL_OFF)[0]
		if redirecting_e() != 0 {
			msg_col = 0
		}
		(^C.int)(uintptr(cmod) + CMOD_SAVE_MSG_SILENT_OFF)^ = 0
		([^]C.int)(uintptr(cmod) + CMOD_DID_ESILENT_OFF)[0] = 0
	}
}

// Editor-state saver (ex_docmd.c public).
@(export)
save_current_state :: proc "c" (sst: rawptr) -> bool {
	context = runtime.default_context()
	([^]C.int)(uintptr(sst) + SST_MSGSCROLL_OFF)[0] = msg_scroll
	([^]C.int)(uintptr(sst) + SST_RESTARTEDIT_OFF)[0] = restart_edit
	([^]bool)(uintptr(sst) + SST_MSGDIDOUT_OFF)[0] = msg_didout_g
	([^]C.int)(uintptr(sst) + SST_STATE_OFF)[0] = State
	([^]bool)(uintptr(sst) + SST_FINISHOP_OFF)[0] = finish_op_g
	([^]C.int)(uintptr(sst) + SST_OPCOUNT_OFF)[0] = opcount_g
	([^]C.int)(uintptr(sst) + SST_REGEXEC_OFF)[0] = reg_executing
	([^]bool)(uintptr(sst) + SST_PENDING_OFF)[0] = pending_end_reg_executing
	msg_scroll = 0
	restart_edit = 0
	save_typeahead_e(rawptr(uintptr(sst) + SST_TABUF_OFF))
	return (^bool)(uintptr(sst) + SST_VALID_OFF)^
}

// Editor-state restorer (ex_docmd.c public).
@(export)
restore_current_state :: proc "c" (sst: rawptr) {
	context = runtime.default_context()
	restore_typeahead_e(rawptr(uintptr(sst) + SST_TABUF_OFF))
	msg_scroll = ([^]C.int)(uintptr(sst) + SST_MSGSCROLL_OFF)[0]
	if force_restart_edit_g {
		force_restart_edit_g = false
	} else {
		restart_edit = ([^]C.int)(uintptr(sst) + SST_RESTARTEDIT_OFF)[0]
	}
	finish_op_g = ([^]bool)(uintptr(sst) + SST_FINISHOP_OFF)[0]
	opcount_g = ([^]C.int)(uintptr(sst) + SST_OPCOUNT_OFF)[0]
	reg_executing = ([^]C.int)(uintptr(sst) + SST_REGEXEC_OFF)[0]
	pending_end_reg_executing = ([^]bool)(uintptr(sst) + SST_PENDING_OFF)[0]
	msg_didout_g = msg_didout_g || ([^]bool)(uintptr(sst) + SST_MSGDIDOUT_OFF)[0]
	State = ([^]C.int)(uintptr(sst) + SST_STATE_OFF)[0]
	ui_cursor_shape_r()
}

// —— Batch 23c: ex_docmd.c skip/profile helpers (plains, C-statics) ——
// (func_line_exec/script_line_exec — PORTED (profile.odin); block removed.)

CMD_WHILE_O :: 529
CMD_ENDWHILE_O :: 147
CMD_FOR_O :: 167
CMD_ENDFOR_O :: 145
CMD_IF_O :: 187
CMD_ELSEIF_O :: 141
CMD_ELSE_O :: 140
CMD_ENDIF_O :: 143
CMD_CATCH_O :: 54
CMD_FINALLY_O :: 159
CMD_ENDTRY_O :: 146
CMD_FUNCTION_O :: 168
CMD_ABOVELEFT_O :: 3
CMD_AND_O :: 554
CMD_BELOWRIGHT_O :: 26
CMD_BOTRIGHT_O :: 31
CMD_BROWSE_O :: 38
CMD_CONFIRM_O :: 97
CMD_DELFUNCTION_O :: 115
CMD_DJUMP_O :: 126
CMD_DLIST_O :: 127
CMD_DSEARCH_O :: 131
CMD_DSPLIT_O :: 132
CMD_EVAL_O :: 149
CMD_FILTER_O :: 157
CMD_HELP_O :: 176
CMD_HIDE_O :: 181
CMD_IJUMP_O :: 188
CMD_ILIST_O :: 189
CMD_ISEARCH_O :: 198
CMD_ISPLIT_O :: 199
CMD_KEEPALT_O :: 209
CMD_KEEPJUMPS_O :: 207
CMD_KEEPMARKS_O :: 206
CMD_KEEPPATTERNS_O :: 208
CMD_LEFTABOVE_O :: 230
CMD_LOCKMARKS_O :: 255
CMD_LUA_O :: 265
CMD_MZSCHEME_O :: 289
CMD_NOAUTOCMD_O :: 299
CMD_NOSWAPFILE_O :: 303
CMD_PERL_O :: 326
CMD_PSEARCH_O :: 337
CMD_PYTHON_O :: 349
CMD_PY3_O :: 352
CMD_PYTHON3_O :: 354
CMD_PYTHONX_O :: 358
CMD_PYX_O :: 356
CMD_RETURN_O :: 374
CMD_RIGHTBELOW_O :: 377
CMD_RUBY_O :: 381
CMD_SILENT_O :: 410
CMD_SYNTAX_O :: 447
CMD_TAB_O :: 456
CMD_TCL_O :: 471
CMD_THROW_O :: 476
CMD_TOPLEFT_O :: 487
CMD_UNLET_O :: 501
CMD_UNLOCKVAR_O :: 502
CMD_VERBOSE_O :: 510
CMD_VERTICAL_O :: 511
CMD_WRITE_O :: 526
CMD_UPDATE_O :: 506
CMD_LSHIFT_O :: 555
CMD_RSHIFT_O :: 557
CMD_GLOBAL_O :: 170
CMD_VGLOBAL_O :: 508
CSF_TRUE_O :: 0x0001
CSF_ACTIVE_O :: 0x0002
CSF_ELSE_O :: 0x0004
CSF_WHILE_O :: 0x0008
CSF_FOR_O :: 0x0010
CSF_TRY_O :: 0x0100
CSF_FINALLY_O :: 0x0200
CSF_THROWN_O :: 0x0800
CSF_CAUGHT_O :: 0x1000
CSF_FINISHED_O :: 0x2000
CSF_SILENT_O :: 0x4000
CSTP_ERROR_O :: 1
CSTP_INTERRUPT_O :: 2
CSTP_THROW_O :: 4
CSTACK_FLAGS_OFF :: 0
CSTACK_LINE_OFF :: 1056
CSTACK_LOOPLEVEL_OFF :: 1260
CSTACK_TRYLEVEL_OFF :: 1264
CSTACK_PENDING_OFF :: 200
CSTACK_LFLAGS_OFF :: 1280
CSTACK_EMSGLIST_OFF :: 1272
CSL_HAD_LOOP_O :: 1
CSL_HAD_ENDLOOP_O :: 2
CSL_HAD_CONT_O :: 4
CSL_HAD_FINA_O :: 8
EX_SBOXOK_O :: 0x40000
EX_EXTRA_O :: 0x004
EX_FLAGS_O :: 0x200000
EX_CMDARG_O :: 0x4000
EXARG_AMOUNT_OFF :: 124
EXARG_CMDLINETOFREE_OFF :: 56

// Command skip test (ex_docmd.c static).
skip_cmd_o :: proc "c" (eap: rawptr) -> bool {
	context = runtime.default_context()
	if !([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] {
		return false
	}
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx == CMD_WHILE_O || cmdidx == CMD_ENDWHILE_O || cmdidx == CMD_FOR_O || cmdidx == CMD_ENDFOR_O || cmdidx == CMD_IF_O || cmdidx == CMD_ELSEIF_O || cmdidx == CMD_ELSE_O || cmdidx == CMD_ENDIF_O || cmdidx == CMD_TRY_O || cmdidx == CMD_CATCH_O || cmdidx == CMD_FINALLY_O || cmdidx == CMD_ENDTRY_O || cmdidx == CMD_FUNCTION_O {
		return false
	}
	if cmdidx == CMD_ABOVELEFT_O || cmdidx == CMD_AND_O || cmdidx == CMD_BELOWRIGHT_O || cmdidx == CMD_BOTRIGHT_O || cmdidx == CMD_BROWSE_O || cmdidx == CMD_CALL_O || cmdidx == CMD_CONFIRM_O || cmdidx == CMD_CONST_O || cmdidx == CMD_DELFUNCTION_O || cmdidx == CMD_DJUMP_O || cmdidx == CMD_DLIST_O || cmdidx == CMD_DSEARCH_O || cmdidx == CMD_DSPLIT_O || cmdidx == CMD_ECHO_O || cmdidx == CMD_ECHOERR_O || cmdidx == CMD_ECHOMSG_O || cmdidx == CMD_ECHON_O || cmdidx == CMD_EVAL_O || cmdidx == CMD_EXECUTE_O || cmdidx == CMD_FILTER_O || cmdidx == CMD_HELP_O || cmdidx == CMD_HIDE_O || cmdidx == CMD_HORIZONTAL_O || cmdidx == CMD_IJUMP_O || cmdidx == CMD_ILIST_O || cmdidx == CMD_ISEARCH_O || cmdidx == CMD_ISPLIT_O || cmdidx == CMD_KEEPALT_O || cmdidx == CMD_KEEPJUMPS_O || cmdidx == CMD_KEEPMARKS_O || cmdidx == CMD_KEEPPATTERNS_O || cmdidx == CMD_LEFTABOVE_O || cmdidx == CMD_LET_O || cmdidx == CMD_LOCKMARKS_O || cmdidx == CMD_LOCKVAR_O || cmdidx == CMD_LUA_O || cmdidx == CMD_MATCH_O || cmdidx == CMD_MZSCHEME_O || cmdidx == CMD_NOAUTOCMD_O || cmdidx == CMD_NOSWAPFILE_O || cmdidx == CMD_PERL_O || cmdidx == CMD_PSEARCH_O || cmdidx == CMD_PYTHON_O || cmdidx == CMD_PY3_O || cmdidx == CMD_PYTHON3_O || cmdidx == CMD_PYTHONX_O || cmdidx == CMD_PYX_O || cmdidx == CMD_RETURN_O || cmdidx == CMD_RIGHTBELOW_O || cmdidx == CMD_RUBY_O || cmdidx == CMD_SILENT_O || cmdidx == CMD_SMAGIC_O || cmdidx == CMD_SNOMAGIC_O || cmdidx == CMD_SUBSTITUTE_O || cmdidx == CMD_SYNTAX_O || cmdidx == CMD_TAB_O || cmdidx == CMD_TCL_O || cmdidx == CMD_THROW_O || cmdidx == CMD_TILDE_O || cmdidx == CMD_TOPLEFT_O || cmdidx == CMD_UNLET_O || cmdidx == CMD_UNLOCKVAR_O || cmdidx == CMD_VERBOSE_O || cmdidx == CMD_VERTICAL_O || cmdidx == CMD_WINCMD_O {
		return false
	}
	return true
}

// Profiling line counter (ex_docmd.c static).
profile_cmd_o :: proc "c" (eap: rawptr, cstack: rawptr, fgetline: LineGetter, cookie: rawptr) {
	context = runtime.default_context()
	if do_profiling != PROF_YES {
		return
	}
	skip := ([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0]
	cs_idx := ([^]C.int)(uintptr(cstack) + CSTACK_IDX_OFF)[0]
	cs_flags := ([^]C.int)(uintptr(cstack) + CSTACK_FLAGS_OFF)
	if !skip || cs_idx == 0 || (cs_idx > 0 && (cs_flags[uintptr(cs_idx) - 1] & CSF_ACTIVE_O) != 0) {
		sk := did_emsg_flag != 0 || got_int || did_throw_g
		cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
		if cmdidx == CMD_CATCH_O {
			sk = !sk && !(cs_idx >= 0 && (cs_flags[uintptr(cs_idx)] & CSF_THROWN_O) != 0 && (cs_flags[uintptr(cs_idx)] & CSF_CAUGHT_O) == 0)
		} else if cmdidx == CMD_ELSE_O || cmdidx == CMD_ELSEIF_O {
			sk = sk || !(cs_idx >= 0 && (cs_flags[uintptr(cs_idx)] & (CSF_ACTIVE_O | CSF_TRUE_O)) == 0)
		} else if cmdidx == CMD_FINALLY_O {
			sk = false
		} else if cmdidx != CMD_ENDIF_O && cmdidx != CMD_ENDFOR_O && cmdidx != CMD_ENDTRY_O && cmdidx != CMD_ENDWHILE_O {
			sk = ([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0]
		}
		if !sk {
			if getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) {
				func_line_exec(getline_cookie(fgetline, cookie))
			} else if getline_equal(fgetline, cookie, getsourceline) {
				script_line_exec()
			}
		}
	}
}

// —— Batch 23b: ex_docmd.c execute engine (export + plains) ——
foreign _ {
	// start/end_batch_changes — PORTED (clipboard.odin).
	@(link_name = "get_text_locked_msg")
	get_text_locked_msg_e :: proc "c" () -> cstring ---
}

@(export)
cmdline_call_depth: C.int = 0

EXARG_CSTACK_OFF :: 184
CSTACK_SIZE_O :: 1288
CSTACK_IDX_OFF :: 1256
EX_WHOLEFOLD_O :: 0x040
EX_MODIFY_O :: 0x100000
EX_LOCK_OK_O :: 0x1000000
EX_BUFLOCK_OK_O :: 0x80000
EX_NEEDARG_O :: 0x080
CMD_CHECKTIME_O :: 75
CMD_FILE_O :: 154

// Cmdline depth guard (ex_docmd.c static).
do_cmdline_start_o :: proc "c" () -> C.int {
	context = runtime.default_context()
	if cmdline_call_depth < 0 {
		libc.abort()
	}
	if cmdline_call_depth >= 200 && C.longlong(cmdline_call_depth) >= p_mfd_g {
		return FAIL_E
	}
	cmdline_call_depth += 1
	start_batch_changes()
	return OK_E
}

// Cmdline depth release (ex_docmd.c static).
do_cmdline_end_o :: proc "c" () {
	context = runtime.default_context()
	cmdline_call_depth -= 1
	if cmdline_call_depth < 0 {
		libc.abort()
	}
	end_batch_changes()
}

// Parsed-command executor (ex_docmd.c public).
@(export)
execute_cmd :: proc "c" (eap: rawptr, cmdinfo: rawptr, preview: bool) -> C.int {
	context = runtime.default_context()
	retv: C.int = 0
	if do_cmdline_start_o() == FAIL_E {
		emsg(cstring(E169_S))
		return retv
	}
	errormsg: cstring = nil
	failed := false
	save_cmdmod: [248]u8
	libc.memcpy(rawptr(&save_cmdmod[0]), rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), 248)
	libc.memcpy(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), cmdinfo, 248)
	apply_cmdmod(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)))
	argt := ([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0]
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if ([^]C.int)(uintptr(curbuf) + B_P_MA_OFF)[0] == 0 && (argt & EX_MODIFY_O) != 0 && !(([^]rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)[0] != nil && (cmdidx == CMD_PUT_O || cmdidx == CMD_IPUT_O)) {
		errormsg = cstring(E21_S)
		failed = true
	}
	if !failed && cmdidx >= 0 {
		if text_locked_r() && (argt & EX_LOCK_OK_O) == 0 {
			errormsg = get_text_locked_msg_e()
			failed = true
		}
	}
	if !failed && (argt & EX_BUFLOCK_OK_O) == 0 && cmdidx != CMD_CHECKTIME_O && cmdidx != CMD_EDIT_O && !(cmdidx == CMD_FILE_O && ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] == 0) && cmdidx >= 0 && curbuf_locked_r() {
		failed = true
	}
	if !failed {
		correct_range_o(eap)
		if cmdidx == CMD_SIZE_O && ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
			errormsg = ex_range_without_command_o(eap)
			failed = true
		}
	}
	if !failed {
		if (((argt & EX_WHOLEFOLD_O) != 0 || ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] >= 2) && global_busy == 0 && ([^]C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)[0] == ADDR_LINES_O) {
			hasFolding(curwin, ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], transmute(^C.int)(uintptr(eap) + EXARG_LINE1_OFF), nil)
			hasFolding(curwin, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], transmute(^C.int)(uintptr(eap) + EXARG_LINE2_OFF), nil)
		}
		if parse_count_o(eap, &errormsg, true) == FAIL_E {
			failed = true
		}
	}
	if !failed {
		cs: [1288]u8
		libc.memset(rawptr(&cs[0]), 0, 1288)
		([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0] = -1
		([^]rawptr)(uintptr(eap) + EXARG_CSTACK_OFF)[0] = rawptr(&cs[0])
		execute_cmd0_o(&retv, eap, &errormsg, preview)
	}
	if errormsg != nil && ([^]u8)(errormsg)[0] != 0 {
		emsg(errormsg)
	}
	undo_cmdmod(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)))
	libc.memcpy(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), rawptr(&save_cmdmod[0]), 248)
	do_cmdline_end_o()
	return retv
}

// —— Batch 21: ex_docmd.c normal-exec pair (exports + weak) ——
foreign _ {
	@(link_name = "typebuf_typed")
	typebuf_typed_e :: proc "c" () -> C.int ---
	@(link_name = "clear_oparg")
	clear_oparg_e :: proc "c" (oap: rawptr) ---
	@(link_name = "normal_cmd")
	normal_cmd_e :: proc "c" (oap: rawptr, toplevel: bool) ---
}

// Normal-command stuffer (ex_docmd.c public).
@(export)
exec_normal_cmd :: proc "c" (cmd: cstring, remap: C.int, silent: bool) {
	context = runtime.default_context()
	ins_typebuf_r(transmute(^u8)(cmd), remap, 0, true, silent)
	exec_normal(false, false)
}

// Typeahead drainer (ex_docmd.c public).
@(export)
exec_normal :: proc "c" (was_typed: bool, use_vpeekc: bool) {
	context = runtime.default_context()
	oa: [88]u8
	c: C.int = 0
	clear_oparg_e(rawptr(&oa[0]))
	finish_op_g = false
	for {
		if stuff_empty_e() {
			if !((was_typed || typebuf_typed_e() == 0) && typebuf.tb_len > 0) {
				if !use_vpeekc {
					break
				}
				c = vpeekc_e()
				if c == 0 || c == Ctrl_C {
					break
				}
			}
		}
		if got_int {
			break
		}
		update_topline_cursor()
		normal_cmd_e(rawptr(&oa[0]), true)
	}
}

// —— Batch 23e: ex_docmd.c cmdline engine (export + plains) ——
foreign _ {
	@(link_name = "msg_list")
	msg_list_g: rawptr
	@(link_name = "did_endif")
	did_endif_g: bool
	@(link_name = "repeat_cmdline")
	repeat_cmdline_g: cstring
	@(link_name = "caught_stack")
	caught_stack_g: rawptr
	@(link_name = "source_level")
	source_level_e :: proc "c" (cookie: rawptr) -> C.int ---
	@(link_name = "has_loop_cmd")
	has_loop_cmd_e :: proc "c" (p: cstring) -> bool ---
	// (script_line_end/start — PORTED (profile.odin).)
	// do_debug — PORTED (debugger.odin).
	@(link_name = "rewind_conditionals")
	rewind_conditionals_e :: proc "c" (cstack: rawptr, idx: C.int, cond_type: C.int, cond_level: ^C.int) ---
	@(link_name = "source_breakpoint")
	source_breakpoint_e :: proc "c" (cookie: rawptr) -> rawptr ---
	@(link_name = "source_dbg_tick")
	source_dbg_tick_e :: proc "c" (cookie: rawptr) -> rawptr ---
}

DOCMD_EXCRESET_O :: 0x10
DOCMD_KEEPLINE_O :: 0x20
E600_S :: "E600: Missing :endtry"
E170_WHILE_S :: "E170: Missing :endwhile"
E170_FOR_S :: "E170: Missing :endfor"
E171_S :: "E171: Missing :endif"
E492_NOCMD_S :: "E492: Not an editor command"

@(private = "file")
do_cmdline_recursive_f: C.int = 0

Wcmd_T :: struct {
	line: cstring,
	lnum: C.int,
}
#assert(size_of(Wcmd_T) == 16)

// Loop-line getter (ex_docmd.c static).
get_loop_line_o :: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> ^u8 {
	context = runtime.default_context()
	base := uintptr(cookie)
	gap := transmute(^Garray)(([^]rawptr)(base)[0])
	cur := ([^]C.int)(base + 8)[0]
	rep := ([^]C.int)(base + 12)[0]
	lc := transmute(LineGetter)(([^]rawptr)(base + 16)[0])
	ck := ([^]rawptr)(base + 24)[0]
	if cur + 1 >= gap.ga_len {
		if rep != 0 {
			return nil
		}
		line: ^u8 = nil
		if lc == nil {
			line = getcmdline(c, 0, indent, do_concat)
		} else {
			line = lc(c, ck, indent, do_concat)
		}
		if line != nil {
			store_loop_line_o(gap, line)
			([^]C.int)(base + 8)[0] = cur + 1
		}
		return line
	}
	KeyTyped = false
	([^]C.int)(base + 8)[0] = cur + 1
	wp_line := ([^]rawptr)(uintptr(gap.ga_data) + uintptr(cur + 1) * 16)[0]
	wp_lnum := ([^]C.int)(uintptr(gap.ga_data) + uintptr(cur + 1) * 16 + 8)[0]
	if exestack.ga_len > 0 {
		([^]C.int)(uintptr(exestack.ga_data) + uintptr(exestack.ga_len - 1) * size_of(Estack))[0] = wp_lnum
	}
	return xstrdup(transmute(^u8)(wp_line))
}

// Loop-line storer (ex_docmd.c static).
store_loop_line_o :: proc "c" (gap: ^Garray, line: ^u8) {
	context = runtime.default_context()
	ga_grow(gap, 1)
	slot := uintptr(gap.ga_data) + uintptr(gap.ga_len) * 16
	([^]rawptr)(slot)[0] = rawptr(xstrdup(line))
	slnum: C.int = 0
	if exestack.ga_len > 0 {
		slnum = ([^]C.int)(uintptr(exestack.ga_data) + uintptr(exestack.ga_len - 1) * size_of(Estack))[0]
	}
	([^]C.int)(slot + 8)[0] = slnum
	gap.ga_len += 1
}

// Verbose command printer (ex_docmd.c static).
msg_verbose_cmd_o :: proc "c" (lnum: C.int, cmd: ^u8) {
	context = runtime.default_context()
	no_wait_return += 1
	verbose_enter_scroll_e()
	if lnum == 0 {
		smsg(0, cstring("Executing: %s"), transmute(cstring)(cmd))
	} else {
		smsg(0, cstring("line %d: %s"), lnum, transmute(cstring)(cmd))
	}
	if msg_silent == 0 {
		msg_puts(cstring("\n"))
	}
	verbose_leave_scroll_e()
	no_wait_return -= 1
}

// Debug-state saver (ex_docmd.c static).
save_dbg_stuff_o :: proc "c" (dsp: rawptr) {
	([^]C.int)(uintptr(dsp))[0] = trylevel_g
	trylevel_g = 0
	if force_abort_g {
		([^]C.int)(uintptr(dsp) + 4)[0] = 1
	} else {
		([^]C.int)(uintptr(dsp) + 4)[0] = 0
	}
	force_abort_g = false
	([^]rawptr)(uintptr(dsp) + 8)[0] = caught_stack_g
	caught_stack_g = nil
	([^]cstring)(uintptr(dsp) + 16)[0] = v_exception(nil)
	([^]cstring)(uintptr(dsp) + 24)[0] = v_throwpoint(nil)
	([^]C.int)(uintptr(dsp) + 32)[0] = did_emsg_flag
	did_emsg_flag = 0
	if got_int {
		([^]C.int)(uintptr(dsp) + 36)[0] = 1
	} else {
		([^]C.int)(uintptr(dsp) + 36)[0] = 0
	}
	got_int = false
	([^]bool)(uintptr(dsp) + 40)[0] = did_throw_g
	did_throw_g = false
	if need_rethrow_g {
		([^]C.int)(uintptr(dsp) + 44)[0] = 1
	} else {
		([^]C.int)(uintptr(dsp) + 44)[0] = 0
	}
	need_rethrow_g = false
	if check_cstack_g {
		([^]C.int)(uintptr(dsp) + 48)[0] = 1
	} else {
		([^]C.int)(uintptr(dsp) + 48)[0] = 0
	}
	check_cstack_g = false
	([^]rawptr)(uintptr(dsp) + 56)[0] = current_exception_g
	current_exception_g = nil
}

// Debug-state restorer (ex_docmd.c static).
restore_dbg_stuff_o :: proc "c" (dsp: rawptr) {
	suppress_errthrow_g = false
	trylevel_g = ([^]C.int)(uintptr(dsp))[0]
	force_abort_g = ([^]C.int)(uintptr(dsp) + 4)[0] != 0
	caught_stack_g = ([^]rawptr)(uintptr(dsp) + 8)[0]
	v_exception(([^]cstring)(uintptr(dsp) + 16)[0])
	v_throwpoint(([^]cstring)(uintptr(dsp) + 24)[0])
	did_emsg_flag = ([^]C.int)(uintptr(dsp) + 32)[0]
	got_int = ([^]C.int)(uintptr(dsp) + 36)[0] != 0
	did_throw_g = ([^]bool)(uintptr(dsp) + 40)[0]
	need_rethrow_g = ([^]C.int)(uintptr(dsp) + 44)[0] != 0
	check_cstack_g = ([^]C.int)(uintptr(dsp) + 48)[0] != 0
	current_exception_g = ([^]rawptr)(uintptr(dsp) + 56)[0]
}

// Ex command-line executor (ex_docmd.c public).
@(export)
do_cmdline :: proc "c" (cmdline: cstring, fgetline: LineGetter, cookie: rawptr, flags: C.int) -> C.int {
	context = runtime.default_context()
	context = runtime.default_context()
	next_cmdline: cstring = nil
	cmdline_copy: ^u8 = nil
	used_getline := false
	msg_didout_before_start := false
	count: C.int = 0
	did_inc := false
	did_block := false
	retval: C.int = OK_E
	cs: [1288]u8
	libc.memset(rawptr(&cs[0]), 0, 1288)
	([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0] = -1
	lines_ga: Garray
	ga_init(&lines_ga, 16, 10)
	current_line: C.int = 0
	fname: cstring = nil
	breakpoint: ^C.int = nil
	dbg_tick: ^C.int = nil
	debug_saved: [64]u8
	private_msg_list: rawptr = nil
	cmd_getline: LineGetter = nil
	cmd_cookie: rawptr = nil
	cmd_loop_cookie: [32]u8
	libc.memset(rawptr(&cmd_loop_cookie[0]), 0, 32)
	saved_msg_list := msg_list_g
	msg_list_g = rawptr(&private_msg_list)
	private_msg_list = nil
	if do_cmdline_start_o() == FAIL_E {
		emsg(cstring(E169_S))
		do_errthrow_e(nil, nil)
		msg_list_g = saved_msg_list
		return FAIL_E
	}
	real_cookie := getline_cookie(fgetline, cookie)
	getline_is_func := getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line))
	if getline_is_func && ex_nesting_level_g == func_level(real_cookie) {
		ex_nesting_level_g += 1
	}
	if getline_is_func {
		fname = func_name(real_cookie)
		breakpoint = transmute(^C.int)(func_breakpoint(real_cookie))
		dbg_tick = transmute(^C.int)(func_dbg_tick(real_cookie))
	} else if getline_equal(fgetline, cookie, getsourceline) {
		if exestack.ga_len > 0 {
			fname = ([^]Estack)(exestack.ga_data)[exestack.ga_len - 1].es_name
		}
		breakpoint = transmute(^C.int)(source_breakpoint_e(real_cookie))
		dbg_tick = transmute(^C.int)(source_dbg_tick_e(real_cookie))
	}
	if do_cmdline_recursive_f == 0 {
		force_abort_g = false
		suppress_errthrow_g = false
	}
	if (flags & DOCMD_EXCRESET_O) != 0 {
		save_dbg_stuff_o(rawptr(&debug_saved[0]))
	} else {
		libc.memset(rawptr(&debug_saved[0]), 0, 64)
	}
	initial_trylevel := trylevel_g
	did_throw_g = false
	did_emsg_flag = 0
	if (flags & DOCMD_KEYTYPED_O) == 0 && !getline_equal(fgetline, cookie, transmute(LineGetter)(getexline_e)) {
		KeyTyped = false
	}
	next_cmdline = cmdline
	for {
		getline_is_func = getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line))
		cs_idx := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
		if next_cmdline == nil && !force_abort_g && cs_idx < 0 && !(getline_is_func && func_has_abort(real_cookie) != 0) {
			did_emsg_flag = 0
		}
		cs_looplevel := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF)[0]
		if cs_looplevel > 0 && current_line < lines_ga.ga_len {
			xfree(rawptr(cmdline_copy))
			cmdline_copy = nil
			if getline_is_func {
				if do_profiling == PROF_YES {
					func_line_end(real_cookie)
				}
				if func_has_ended(real_cookie) != 0 {
					retval = FAIL_E
					break
				}
			} else if do_profiling == PROF_YES && getline_equal(fgetline, cookie, getsourceline) {
				script_line_end()
			}
			if source_finished_e(fgetline, cookie) {
				retval = FAIL_E
				break
			}
			if breakpoint != nil && dbg_tick != nil && dbg_tick^ != debug_tick_g {
				breakpoint^ = dbg_find_breakpoint(getline_equal(fgetline, cookie, getsourceline), fname, sourcing_lnum_o())
				dbg_tick^ = debug_tick_g
			}
			next_cmdline = transmute(cstring)(([^]rawptr)(uintptr(lines_ga.ga_data) + uintptr(current_line) * 16)[0])
			set_sourcing_lnum_o(([^]C.int)(uintptr(lines_ga.ga_data) + uintptr(current_line) * 16 + 8)[0])
			if breakpoint != nil && breakpoint^ != 0 && breakpoint^ <= sourcing_lnum_o() {
				dbg_breakpoint(fname, sourcing_lnum_o())
				breakpoint^ = dbg_find_breakpoint(getline_equal(fgetline, cookie, getsourceline), fname, sourcing_lnum_o())
				dbg_tick^ = debug_tick_g
			}
			if do_profiling == PROF_YES {
				if getline_is_func {
					func_line_start(real_cookie)
				} else if getline_equal(fgetline, cookie, getsourceline) {
					script_line_start()
				}
			}
		}
		if next_cmdline == nil {
			indent := 0
			cs_idx2 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
			if cs_idx2 >= 0 {
				indent = int(cs_idx2 + 1) * 2
			}
			if count == 1 && getline_equal(fgetline, cookie, transmute(LineGetter)(getexline_e)) {
				if ui_has_r(K_UICMDLINE_O) {
					ui_ext_cmdline_block_append_e(0, transmute(cstring)(last_cmdline))
					did_block = true
				}
				msg_didout_g = true
			}
			if transmute(rawptr)(fgetline) == nil {
				next_cmdline = nil
			} else {
				next_cmdline = transmute(cstring)(fgetline(C.int(':'), cookie, C.int(indent), true))
			}
			if next_cmdline == nil {
				if KeyTyped && (flags & DOCMD_REPEAT_O) == 0 {
					need_wait_return_g = false
				}
				retval = FAIL_E
				break
			}
			used_getline = true
			if ui_has_r(K_UICMDLINE_O) && count > 0 && getline_equal(fgetline, cookie, transmute(LineGetter)(getexline_e)) {
				ui_ext_cmdline_block_append_e(C.size_t(indent), next_cmdline)
			}
			if (flags & DOCMD_KEEPLINE_O) != 0 {
				xfree(rawptr(repeat_cmdline_g))
				if count == 0 {
					repeat_cmdline_g = transmute(cstring)(xstrdup(transmute(^u8)(next_cmdline)))
				} else {
					repeat_cmdline_g = nil
				}
			}
		} else if cmdline_copy == nil {
			next_cmdline = transmute(cstring)(xstrdup(transmute(^u8)(next_cmdline)))
		}
		cmdline_copy = transmute(^u8)(next_cmdline)
		current_line_before: C.int = 0
		cs_looplevel2 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF)[0]
		if cs_looplevel2 > 0 || has_loop_cmd_e(next_cmdline) {
			cmd_getline = transmute(LineGetter)(get_loop_line_o)
			cmd_cookie = rawptr(&cmd_loop_cookie[0])
			([^]rawptr)(uintptr(rawptr(&cmd_loop_cookie[0])))[0] = rawptr(&lines_ga)
			([^]C.int)(uintptr(rawptr(&cmd_loop_cookie[0])) + 8)[0] = current_line
			([^]rawptr)(uintptr(rawptr(&cmd_loop_cookie[0])) + 16)[0] = transmute(rawptr)(fgetline)
			([^]rawptr)(uintptr(rawptr(&cmd_loop_cookie[0])) + 24)[0] = cookie
			rep: C.int = 0
			if current_line < lines_ga.ga_len {
				rep = 1
			}
			([^]C.int)(uintptr(rawptr(&cmd_loop_cookie[0])) + 12)[0] = rep
			if current_line == lines_ga.ga_len {
				store_loop_line_o(&lines_ga, cmdline_copy)
			}
			current_line_before = current_line
		} else {
			cmd_getline = fgetline
			cmd_cookie = cookie
		}
		did_endif_g = false
		if count == 0 {
			count += 1
			if (flags & DOCMD_NOWAIT_O) == 0 && do_cmdline_recursive_f == 0 {
				msg_didout_before_start = msg_didout_g
				msg_didany_g = false
				msg_start()
				msg_scroll = 1
				no_wait_return += 1
				RedrawingDisabled += 1
				did_inc = true
			}
		} else {
			count += 1
		}
		if (p_verbose >= 15 && sourcing_name_o() != nil) || p_verbose >= 16 {
			msg_verbose_cmd_o(sourcing_lnum_o(), cmdline_copy)
		}
		do_cmdline_recursive_f += 1
		next_cmdline = transmute(cstring)(do_one_cmd_o(transmute(^cstring)(&cmdline_copy), flags, rawptr(&cs[0]), cmd_getline, cmd_cookie))
		do_cmdline_recursive_f -= 1
		if cmd_cookie == rawptr(&cmd_loop_cookie[0]) {
			current_line = ([^]C.int)(uintptr(rawptr(&cmd_loop_cookie[0])) + 8)[0]
		}
		if next_cmdline == nil {
			xfree(rawptr(cmdline_copy))
			cmdline_copy = nil
			if getline_equal(fgetline, cookie, transmute(LineGetter)(getexline_e)) && new_last_cmdline != nil {
				xfree(rawptr(last_cmdline))
				last_cmdline = new_last_cmdline
				new_last_cmdline = nil
			}
		} else {
			libc.memmove(rawptr(cmdline_copy), rawptr(next_cmdline), libc.strlen(next_cmdline) + 1)
			next_cmdline = transmute(cstring)(cmdline_copy)
		}
		if did_emsg_flag != 0 && !force_abort_g && getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) && func_has_abort(real_cookie) == 0 {
			did_emsg_flag = 0
		}
		cs_looplevel3 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF)[0]
		if cs_looplevel3 > 0 {
			current_line += 1
			cs_lflags := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0]
			if (cs_lflags & (CSL_HAD_CONT_O | CSL_HAD_ENDLOOP_O)) != 0 {
				([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0] = cs_lflags & ~C.int(CSL_HAD_CONT_O | CSL_HAD_ENDLOOP_O)
				cs_idx3 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
				cs_flags3 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_FLAGS_OFF)
				cs_line3 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LINE_OFF)
				if did_emsg_flag == 0 && !got_int && !did_throw_g && cs_idx3 >= 0 && (cs_flags3[uintptr(cs_idx3)] & (CSF_WHILE_O | CSF_FOR_O)) != 0 && cs_line3[uintptr(cs_idx3)] >= 0 && (cs_flags3[uintptr(cs_idx3)] & CSF_ACTIVE_O) != 0 {
					current_line = cs_line3[uintptr(cs_idx3)]
					([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0] |= CSL_HAD_LOOP_O
					line_breakcheck()
					if breakpoint != nil && lines_ga.ga_len > current_line {
						breakpoint^ = dbg_find_breakpoint(getline_equal(fgetline, cookie, getsourceline), fname, ([^]C.int)(uintptr(lines_ga.ga_data) + uintptr(current_line) * 16 + 8)[0] - 1)
						dbg_tick^ = debug_tick_g
					}
				} else {
					if cs_idx3 >= 0 {
						rewind_conditionals_e(rawptr(&cs[0]), cs_idx3 - 1, CSF_WHILE_O | CSF_FOR_O, transmute(^C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF))
					}
				}
			} else if (cs_lflags & CSL_HAD_LOOP_O) != 0 {
				([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0] = cs_lflags & ~C.int(CSL_HAD_LOOP_O)
				cs_line3b := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LINE_OFF)
				cs_idx3b := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
				cs_line3b[uintptr(cs_idx3b)] = current_line_before
			}
		}
		if ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF)[0] == 0 {
			if lines_ga.ga_len != 0 {
				set_sourcing_lnum_o(([^]C.int)(uintptr(lines_ga.ga_data) + uintptr(lines_ga.ga_len - 1) * 16 + 8)[0])
				deep_clear_lines_ga_o(&lines_ga)
				current_line = 0
			} else {
				current_line = 0
			}
		}
		cs_lflags4 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0]
		if (cs_lflags4 & CSL_HAD_FINA_O) != 0 {
			([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LFLAGS_OFF)[0] = cs_lflags4 & ~C.int(CSL_HAD_FINA_O)
			cs_idx4 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
			cs_pending := ([^]u8)(uintptr(rawptr(&cs[0])) + CSTACK_PENDING_OFF)
			pending_mask := cs_pending[uintptr(cs_idx4)] & (CSTP_ERROR_O | CSTP_INTERRUPT_O | CSTP_THROW_O)
			thrown: rawptr = nil
			if did_throw_g {
				thrown = current_exception_g
			}
			report_make_pending_e(C.int(pending_mask), thrown)
			did_emsg_flag = 0
			got_int = false
			did_throw_g = false
			cs_flags4 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_FLAGS_OFF)
			cs_flags4[uintptr(cs_idx4)] |= CSF_ACTIVE_O | CSF_FINALLY_O
		}
		trylevel_g = initial_trylevel + ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_TRYLEVEL_OFF)[0]
		if trylevel_g == 0 && did_emsg_flag == 0 && !got_int && !did_throw_g {
			force_abort_g = false
		}
		do_intthrow_e(rawptr(&cs[0]))
		stop1 := (got_int || (did_emsg_flag != 0 && force_abort_g) || did_throw_g) && ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_TRYLEVEL_OFF)[0] == 0
		stop2 := did_emsg_flag != 0 && (([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_TRYLEVEL_OFF)[0] == 0 || did_emsg_syntax_g) && used_getline && getline_equal(fgetline, cookie, transmute(LineGetter)(getexline_e))
		cs_idx5 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
		stop3 := next_cmdline == nil && cs_idx5 < 0 && (flags & DOCMD_REPEAT_O) == 0
		if stop1 || stop2 || stop3 {
			break
		}
	}
	xfree(rawptr(cmdline_copy))
	did_emsg_syntax_g = false
	deep_clear_lines_ga_o(&lines_ga)
	cs_idx6 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0]
	if cs_idx6 >= 0 {
		if !got_int && !did_throw_g && !aborting_r() && ((getline_equal(fgetline, cookie, getsourceline) && !source_finished_e(fgetline, cookie)) || (getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) && func_has_ended(real_cookie) == 0)) {
			cs_flags6 := ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_FLAGS_OFF)
			if (cs_flags6[uintptr(cs_idx6)] & CSF_TRY_O) != 0 {
				emsg(cstring(E600_S))
			} else if (cs_flags6[uintptr(cs_idx6)] & CSF_WHILE_O) != 0 {
				emsg(cstring(E170_WHILE_S))
			} else if (cs_flags6[uintptr(cs_idx6)] & CSF_FOR_O) != 0 {
				emsg(cstring(E170_FOR_S))
			} else {
				emsg(cstring(E171_S))
			}
		}
		for ([^]C.int)(uintptr(rawptr(&cs[0])) + CSTACK_IDX_OFF)[0] >= 0 {
			idx := cleanup_conditionals_e(rawptr(&cs[0]), 0, 1)
			if idx >= 0 {
				idx -= 1
			}
			rewind_conditionals_e(rawptr(&cs[0]), idx, CSF_WHILE_O | CSF_FOR_O, transmute(^C.int)(uintptr(rawptr(&cs[0])) + CSTACK_LOOPLEVEL_OFF))
		}
		trylevel_g = initial_trylevel
	}
	eh_name: cstring = nil
	if getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) {
		eh_name = cstring("endfunction")
	}
	do_errthrow_e(rawptr(&cs[0]), eh_name)
	if trylevel_g == 0 {
		if did_throw_g {
			handle_did_throw()
		} else if got_int || (did_emsg_flag != 0 && force_abort_g) {
			suppress_errthrow_g = true
		}
	}
	if did_throw_g {
		need_rethrow_g = true
	}
	nest_src := getline_equal(fgetline, cookie, getsourceline)
	nest_func := getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line))
	if (nest_src && ex_nesting_level_g > source_level_e(real_cookie)) || (nest_func && ex_nesting_level_g > func_level(real_cookie) + 1) {
		if !did_throw_g {
			check_cstack_g = true
		}
	} else {
		if nest_func {
			ex_nesting_level_g -= 1
		}
		if (nest_src || nest_func) && ex_nesting_level_g + 1 <= debug_break_level {
			if nest_src {
				do_debug(cstring("End of sourced file"))
			} else {
				do_debug(cstring("End of function"))
			}
		}
	}
	if (flags & DOCMD_EXCRESET_O) != 0 {
		restore_dbg_stuff_o(rawptr(&debug_saved[0]))
	}
	msg_list_g = saved_msg_list
	eslist := ([^]rawptr)(uintptr(rawptr(&cs[0])) + CSTACK_EMSGLIST_OFF)[0]
	for eslist != nil {
		temp := ([^]rawptr)(eslist)[0]
		xfree(eslist)
		eslist = temp
	}
	if did_inc {
		RedrawingDisabled -= 1
		no_wait_return -= 1
		msg_scroll = 0
		if retval == FAIL_E || (did_endif_g && KeyTyped && did_emsg_flag == 0) {
			need_wait_return_g = false
			msg_didany_g = false
		} else if need_wait_return_g {
			msg_didout_g = msg_didout_g || msg_didout_before_start
			wait_return_r(0)
		}
	}
	if did_block {
		ui_ext_cmdline_block_leave_r()
	}
	did_endif_g = false
	do_cmdline_end_o()
	return retval
}

// SOURCING_NAME reader (shared helper).
sourcing_name_o :: proc "c" () -> cstring {
	context = runtime.default_context()
	if exestack.ga_len > 0 {
		return ([^]Estack)(exestack.ga_data)[exestack.ga_len - 1].es_name
	}
	return nil
}

// Deep-clear helper for the loop-lines growarray.
deep_clear_lines_ga_o :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		xfree(([^]rawptr)(uintptr(gap.ga_data) + uintptr(i) * 16)[0])
	}
	ga_clear(gap)
}

// —— Batch 23d: ex_docmd.c one-command engine (plain, C-static) ——
foreign _ {
	@(link_name = "did_emsg_syntax")
	did_emsg_syntax_g: bool
	@(link_name = "need_rethrow")
	need_rethrow_g: bool
	@(link_name = "check_cstack")
	check_cstack_g: bool
	@(link_name = "getnextac")
	getnextac_e :: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> ^u8 ---
	@(link_name = "do_throw")
	do_throw_e :: proc "c" (cstack: rawptr) ---
	@(link_name = "source_finished")
	source_finished_e :: proc "c" (fgetline: LineGetter, cookie: rawptr) -> bool ---
	@(link_name = "do_finish")
	do_finish_e :: proc "c" (eap: rawptr, reanimate: bool) ---
	@(link_name = "do_errthrow")
	do_errthrow_e :: proc "c" (cstack: rawptr, cmdname: cstring) ---
	@(link_name = "do_intthrow")
	do_intthrow_e :: proc "c" (cstack: rawptr) -> bool ---
	// dbg_check_breakpoint — PORTED (debugger.odin).
	@(link_name = "ask_yesno")
	ask_yesno_e :: proc "c" (str: cstring) -> C.int ---
}

EVENT_CMDUNDEFINED_O :: 29
E493_S :: "E493: Backwards range given"
E494_S :: "E494: Use w or w>>"
E48_S :: "E48: Not allowed in sandbox"
E488_TRAIL_S :: "E488: Trailing characters: %s"
EX_ARGOPT_O :: 0x20000

// Single-command executor (ex_docmd.c static).
do_one_cmd_o :: proc "c" (cmdlinep: ^cstring, flags: C.int, cstack: rawptr, fgetline: LineGetter, cookie: rawptr) -> cstring {
	context = runtime.default_context()
	errormsg: cstring = nil
	save_reg_executing := reg_executing
	save_pending := pending_end_reg_executing
	ea: [192]u8
	libc.memset(rawptr(&ea[0]), 0, 192)
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0] = 1
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0] = 1
	ex_nesting_level_g += 1
	if quitmore != 0 && !getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) && !getline_equal(fgetline, cookie, transmute(LineGetter)(getnextac_e)) {
		quitmore -= 1
	}
	save_cmdmod: [248]u8
	libc.memcpy(rawptr(&save_cmdmod[0]), rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), 248)
	ret_next: cstring = nil
	finished := false
	for !finished {
		finished = true
		cmdline := ([^]cstring)(cmdlinep)[0]
		if ([^]u8)(cmdline)[0] == '#' && ([^]u8)(cmdline)[1] == '!' {
			break
		}
		([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = cmdline
		([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_CMDLINEP_OFF)[0] = rawptr(cmdlinep)
		([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_GETLINE_OFF)[0] = transmute(rawptr)(fgetline)
		([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_COOKIE_OFF)[0] = cookie
		([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_CSTACK_OFF)[0] = cstack
		if parse_command_modifiers(rawptr(&ea[0]), &errormsg, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), false) == FAIL_E {
			break
		}
		apply_cmdmod(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)))
		after_modifier := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0]
		cs_idx := ([^]C.int)(uintptr(cstack) + CSTACK_IDX_OFF)[0]
		cs_flags := ([^]C.int)(uintptr(cstack) + CSTACK_FLAGS_OFF)
		sk := did_emsg_flag != 0 || got_int || did_throw_g || (cs_idx >= 0 && (cs_flags[uintptr(cs_idx)] & CSF_ACTIVE_O) == 0)
		([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] = sk
		p := find_excmd_after_range_o(rawptr(&ea[0]))
		profile_cmd_o(rawptr(&ea[0]), cstack, fgetline, cookie)
		if !exiting {
			dbg_check_breakpoint(rawptr(&ea[0]))
		}
		if !([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] && got_int {
			([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] = true
			do_intthrow_e(cstack)
		}
		set_cmd_addr_type(rawptr(&ea[0]), p)
		if parse_cmd_address(rawptr(&ea[0]), &errormsg, false) == FAIL_E {
			break
		}
		([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = skip_colon_white_o(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0], true)
		ea_cmd := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0]
		ea_next: rawptr = nil
		nc0 := ([^]u8)(ea_cmd)[0]
		if nc0 != 0 && nc0 != '"' {
			ea_next = rawptr(check_nextcmd(transmute(^u8)(ea_cmd)))
		}
		if nc0 == 0 || nc0 == '"' || ea_next != nil {
			([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0] = ea_next
			if ([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] {
				break
			}
			errormsg = ex_range_without_command_o(rawptr(&ea[0]))
			break
		}
		if p != nil && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] == CMD_SIZE_O && !([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] {
			c0 := ([^]u8)(ea_cmd)[0]
			if (c0 >= 'A' && c0 <= 'Z') && has_event(EVENT_CMDUNDEFINED_O) {
				cmdname := ea_cmd
				for {
					cc := ([^]u8)(cmdname)[0]
					if !((cc >= 'A' && cc <= 'Z') || (cc >= 'a' && cc <= 'z') || (cc >= '0' && cc <= '9')) {
						break
					}
					cmdname = transmute(cstring)(uintptr(rawptr(cmdname)) + 1)
				}
				cmdname = transmute(cstring)(xmemdupz(rawptr(ea_cmd), C.size_t(uintptr(rawptr(cmdname)) - uintptr(rawptr(ea_cmd)))))
				ret := apply_autocmds(EVENT_CMDUNDEFINED_O, cmdname, cmdname, true, nil)
				xfree(rawptr(cmdname))
				if ret && !aborting_r() {
					p = find_ex_command(rawptr(&ea[0]), nil)
				} else {
					p = ea_cmd
				}
			}
		}
		if p == nil {
			if !([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] {
				errormsg = cstring(E464_S)
			}
			break
		}
		if ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] == CMD_SIZE_O {
			if !([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0] {
				xstrlcpy(transmute(cstring)(&IObuff[0]), cstring(E492_S), C.size_t(IOSIZE_O))
				cmdname := after_modifier
				if cmdname == nil {
					cmdname = ([^]cstring)(cmdlinep)[0]
				}
				if (flags & DOCMD_VERBOSE_O) == 0 {
					append_command_o(cmdname)
				}
				errormsg = transmute(cstring)(&IObuff[0])
				did_emsg_syntax_g = true
				verify_command(cmdname)
			}
			break
		}
		ni := is_cmd_ni(([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0])
		if parse_bang_o(rawptr(&ea[0]), &p) {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] = 1
		} else {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] = 0
		}
		cmdidx := ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0]
		if cmdidx >= 0 {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] = C.int((^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx)).argt)
		}
		argt := ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0]
		skip := ([^]bool)(uintptr(rawptr(&ea[0])) + EXARG_SKIP_OFF)[0]
		if !skip {
			if sandbox != 0 && (argt & EX_SBOXOK_O) == 0 {
				errormsg = cstring(E48_S)
				break
			}
			if ([^]C.int)(uintptr(curbuf) + B_P_MA_OFF)[0] == 0 && (argt & EX_MODIFY_O) != 0 && !(([^]rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)[0] != nil && (cmdidx == CMD_PUT_O || cmdidx == CMD_IPUT_O)) {
				errormsg = cstring(E21_S)
				break
			}
			if cmdidx >= 0 {
				if text_locked_r() && (argt & EX_LOCK_OK_O) == 0 {
					errormsg = get_text_locked_msg_e()
					break
				}
			}
			if (argt & EX_BUFLOCK_OK_O) == 0 && cmdidx != CMD_CHECKTIME_O && cmdidx != CMD_EDIT_O && cmdidx != CMD_FILE_O && cmdidx >= 0 && curbuf_locked_r() {
				break
			}
			if !ni && (argt & EX_RANGE_O) == 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
				errormsg = cstring(E481_S)
				break
			}
		}
		if !ni && (argt & EX_BANG_O) == 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] != 0 {
			errormsg = cstring(E477_S)
			break
		}
		if !skip && !ni && (argt & EX_RANGE_O) != 0 {
			if global_busy == 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0] > ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0] {
				if msg_silent == 0 {
					if (flags & DOCMD_VERBOSE_O) != 0 || exmode_active {
						errormsg = cstring(E493_S)
						break
					}
					if ask_yesno_e(cstring("Backwards range given, OK to swap")) != 'y' {
						break
					}
				}
				ln := ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0]
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0] = ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0]
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0] = ln
			}
			if invalid_range(rawptr(&ea[0])) != nil {
				errormsg = invalid_range(rawptr(&ea[0]))
				break
			}
		}
		/* DUP-SPAN (Batch 23d draft + insertion duplicated this section; kept inert until removed)
		if ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_TYPE_OFF)[0] == ADDR_OTHER_O && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0] = 1
		}
		correct_range_o(rawptr(&ea[0]))
		if true {
			libc.fprintf(libc.stderr, cstring("DBGL2\n"))
		}
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_WHOLEFOLD_O) != 0 || ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] >= 2) && global_busy == 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_TYPE_OFF)[0] == ADDR_LINES_O {
			hasFolding(curwin, ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0], transmute(^C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF), nil)
			hasFolding(curwin, ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0], transmute(^C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF), nil)
		}
		p = replace_makeprg(rawptr(&ea[0]), p, cmdlinep)
		if p == nil {
			break
		}
		if cmdidx == CMD_BANG_O {
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = p
		} else {
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(p)
		}
		if true {
			libc.fprintf(libc.stderr, cstring("DBGARG [%s] from p=[%s]\n"), ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0], p)
		}
		if cmdidx == CMD_FILE_O && ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0] != 0 && curbuf_locked_r() {
			break
		}
		if (argt & EX_ARGOPT_O) != 0 {
			for {
				ao0 := ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0]
				ao1 := ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[1]
				if ao0 != '+' || ao1 != '+' {
					break
				}
				if getargopt(rawptr(&ea[0])) == FAIL_E && !ni {
					errormsg = cstring(e_invarg_s)
					finished = true
					break
				}
			}
			if finished {
				break
			}
		}
		if cmdidx == CMD_WRITE_O || cmdidx == CMD_UPDATE_O {
			warg2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			if ([^]u8)(warg2)[0] == '>' {
				warg2 = transmute(cstring)(uintptr(rawptr(warg2)) + 1)
				if ([^]u8)(warg2)[0] != '>' {
					errormsg = cstring(E494_S)
					break
				}
				([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(transmute(cstring)(uintptr(rawptr(warg2)) + 1))
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_APPEND_OFF)[0] = 1
			} else if ([^]u8)(warg2)[0] == '!' && cmdidx == CMD_WRITE_O {
				([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(rawptr(warg2)) + 1)
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
			}
		} else if cmdidx == CMD_READ_O {
			if ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] != 0 {
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] = 0
			} else {
				rarg2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
				if ([^]u8)(rarg2)[0] == '!' {
					([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(rawptr(rarg2)) + 1)
					([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
				}
			}
		} else if cmdidx == CMD_LSHIFT_O || cmdidx == CMD_RSHIFT_O {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_AMOUNT_OFF)[0] = 1
			sharg2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			shcmd2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0]
			for ([^]u8)(sharg2)[0] == ([^]u8)(shcmd2)[0] {
				sharg2 = transmute(cstring)(uintptr(rawptr(sharg2)) + 1)
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_AMOUNT_OFF)[0] += 1
			}
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(sharg2)
		}
		if (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_CMDARG_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] == 0 {
			([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_DO_ECMD_CMD_OFF)[0] = rawptr(getargcmd(transmute(^cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)))
		}
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] == 0) {
			separate_nextcmd(rawptr(&ea[0]))
		} else if cmdidx == CMD_BANG_O || cmdidx == CMD_TERMINAL_O || cmdidx == CMD_GLOBAL_O || cmdidx == CMD_VGLOBAL_O || ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] != 0 {
			s2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			for ([^]u8)(s2)[0] != 0 {
				if ([^]u8)(s2)[0] == '\\' && ([^]u8)(s2)[1] == '\n' {
					libc.memmove(rawptr(s2), rawptr(uintptr(rawptr(s2)) + 1), libc.strlen(transmute(cstring)(uintptr(rawptr(s2)) + 1)) + 1)
				} else if ([^]u8)(s2)[0] == '\n' {
					([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0] = rawptr(uintptr(rawptr(s2)) + 1)
					([^]u8)(s2)[0] = 0
					break
				} else {
					s2 = transmute(cstring)(uintptr(rawptr(s2)) + 1)
				}
			}
		}
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_DFLALL_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] == 0) {
			set_cmd_dflall_range(rawptr(&ea[0]))
		}
		parse_register_o(rawptr(&ea[0]))
		if parse_count_o(rawptr(&ea[0]), &errormsg, true) == FAIL_E {
			break
		}
		if (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_FLAGS_O) != 0 {
			get_flags_o(rawptr(&ea[0]))
		}
		if !ni && (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_EXTRA_O) == 0 {
			xarg2 := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			if ([^]u8)(xarg2)[0] != 0 && ([^]u8)(xarg2)[0] != '"' {
				xc2 := ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0])[0]
				if xc2 != '|' || ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) == 0) {
					errormsg = ex_errmsg(cstring(E488_TRAIL_S), xarg2)
					break
				}
			}
		}
		if !ni && (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_NEEDARG_O) != 0 && ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0] == 0 {
			errormsg = cstring(E471_S)
			break
		}
		if skip_cmd_o(rawptr(&ea[0])) {
			break
		}
		DUP-SPAN end */
		if (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_TYPE_OFF)[0] == ADDR_OTHER_O) && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0] = 1
		}
		correct_range_o(rawptr(&ea[0]))
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_WHOLEFOLD_O) != 0 || ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] >= 2) && global_busy == 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_TYPE_OFF)[0] == ADDR_LINES_O {
			hasFolding(curwin, ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF)[0], transmute(^C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE1_OFF), nil)
			hasFolding(curwin, ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF)[0], transmute(^C.int)(uintptr(rawptr(&ea[0])) + EXARG_LINE2_OFF), nil)
		}
		p = replace_makeprg(rawptr(&ea[0]), p, cmdlinep)
		if p == nil {
			break
		}
		if cmdidx == CMD_BANG_O {
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = p
		} else {
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(p)
		}
		if cmdidx == CMD_FILE_O && ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0] != 0 && curbuf_locked_r() {
			break
		}
		if (argt & EX_ARGOPT_O) != 0 {
			argloop_done := false
			argopt_failed := false
			for !argloop_done {
				a0 := ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0]
				a1 := ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[1]
				if a0 != '+' || a1 != '+' {
					argloop_done = true
					continue
				}
				if getargopt(rawptr(&ea[0])) == FAIL_E && !ni {
					errormsg = cstring(e_invarg_s)
					argopt_failed = true
				}
				if argopt_failed {
					break
				}
			}
			if argopt_failed {
				break
			}
		}
		if cmdidx == CMD_WRITE_O || cmdidx == CMD_UPDATE_O {
			warg := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			if ([^]u8)(warg)[0] == '>' {
				warg = transmute(cstring)(uintptr(rawptr(warg)) + 1)
				if ([^]u8)(warg)[0] != '>' {
					errormsg = cstring(E494_S)
					break
				}
				([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(transmute(cstring)(uintptr(rawptr(warg)) + 1))
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_APPEND_OFF)[0] = 1
			} else if ([^]u8)(warg)[0] == '!' && cmdidx == CMD_WRITE_O {
				([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(rawptr(warg)) + 1)
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
			}
		} else if cmdidx == CMD_READ_O {
			if ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] != 0 {
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_FORCEIT_OFF)[0] = 0
			} else {
				rarg := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
				if ([^]u8)(rarg)[0] == '!' {
					([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(rawptr(rarg)) + 1)
					([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] = 1
				}
			}
		} else if cmdidx == CMD_LSHIFT_O || cmdidx == CMD_RSHIFT_O {
			([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_AMOUNT_OFF)[0] = 1
			sharg := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			shcmd := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0]
			for ([^]u8)(sharg)[0] == ([^]u8)(shcmd)[0] {
				sharg = transmute(cstring)(uintptr(rawptr(sharg)) + 1)
				([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_AMOUNT_OFF)[0] += 1
			}
			([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = skipwhite(sharg)
		}
		if (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_CMDARG_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] == 0 {
			([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_DO_ECMD_CMD_OFF)[0] = rawptr(getargcmd(transmute(^cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)))
		}
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] == 0) {
			separate_nextcmd(rawptr(&ea[0]))
		} else if cmdidx == CMD_BANG_O || cmdidx == CMD_TERMINAL_O || cmdidx == CMD_GLOBAL_O || cmdidx == CMD_VGLOBAL_O || ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_USEFILTER_OFF)[0] != 0 {
			s := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			for ([^]u8)(s)[0] != 0 {
				if ([^]u8)(s)[0] == '\\' && ([^]u8)(s)[1] == '\n' {
					libc.memmove(rawptr(s), rawptr(uintptr(rawptr(s)) + 1), libc.strlen(transmute(cstring)(uintptr(rawptr(s)) + 1)) + 1)
				} else if ([^]u8)(s)[0] == '\n' {
					([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0] = rawptr(uintptr(rawptr(s)) + 1)
					([^]u8)(s)[0] = 0
					break
				} else {
					s = transmute(cstring)(uintptr(rawptr(s)) + 1)
				}
			}
		}
		if ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_DFLALL_O) != 0 && ([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ADDR_COUNT_OFF)[0] == 0) {
			set_cmd_dflall_range(rawptr(&ea[0]))
		}
		parse_register_o(rawptr(&ea[0]))
		if parse_count_o(rawptr(&ea[0]), &errormsg, true) == FAIL_E {
			break
		}
		if (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_FLAGS_O) != 0 {
			get_flags_o(rawptr(&ea[0]))
		}
		if !ni && (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_EXTRA_O) == 0 {
			xarg := ([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0]
			xb := ([^]u8)(xarg)[0]
			xc := byte(0)
			if xb != 0 && xb != '"' {
				xc = ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0])[0]
				if xc != '|' || ((([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) == 0) {
					errormsg = ex_errmsg(cstring(E488_TRAIL_S), xarg)
					break
				}
			}
		}
		if !ni && (([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_ARGT_OFF)[0] & EX_NEEDARG_O) != 0 && ([^]u8)(([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0])[0] == 0 {
			errormsg = cstring(E471_S)
			break
		}
		if skip_cmd_o(rawptr(&ea[0])) {
			break
		}
		retv: C.int = 0
		if execute_cmd0_o(&retv, rawptr(&ea[0]), &errormsg, false) == FAIL_E {
			break
		}
		if need_rethrow_g {
			do_throw_e(cstack)
		} else if check_cstack_g {
			if source_finished_e(fgetline, cookie) {
				do_finish_e(rawptr(&ea[0]), true)
			} else if getline_equal(fgetline, cookie, transmute(LineGetter)(get_func_line)) && current_func_returned() != 0 {
				do_return(rawptr(&ea[0]), true, false, nil)
			}
		}
		need_rethrow_g = false
		check_cstack_g = false
	}
	if ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] == 0 {
		([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = 1
		([^]C.int)(uintptr(curwin) + W_CURSOR_COL_OFF)[0] = 0
	}
	if errormsg != nil && ([^]u8)(errormsg)[0] != 0 && did_emsg_flag == 0 {
		if (flags & DOCMD_VERBOSE_O) != 0 {
			if transmute(rawptr)(errormsg) != rawptr(&IObuff[0]) {
				xstrlcpy(transmute(cstring)(&IObuff[0]), errormsg, C.size_t(IOSIZE_O))
				errormsg = transmute(cstring)(&IObuff[0])
			}
			append_command_o(([^]cstring)(cmdlinep)[0])
		}
		emsg(errormsg)
	}
	do_errthrow_e(cstack, do_one_cmd_name_o(rawptr(&ea[0])))
	undo_cmdmod(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)))
	libc.memcpy(rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), rawptr(&save_cmdmod[0]), 248)
	reg_executing = save_reg_executing
	pending_end_reg_executing = save_pending
	nx := ([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0]
	if nx != nil && ([^]u8)(nx)[0] == 0 {
		([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0] = nil
	}
	ex_nesting_level_g -= 1
	xfree(([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_CMDLINETOFREE_OFF)[0])
	ret_next = transmute(cstring)(([^]rawptr)(uintptr(rawptr(&ea[0])) + EXARG_NEXTCMD_OFF)[0])
	return ret_next
}

// do_errthrow command-name selector (shared helper).
do_one_cmd_name_o :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx != CMD_SIZE_O && cmdidx >= 0 {
		return (^CommandDefinition_O)(nvim_odin_cmddef_at_e(cmdidx)).name
	}
	return nil
}

// —— Batch 23a: ex_docmd.c dispatch leaves (export + plains) ——
foreign _ {
	@(link_name = "do_ucmd")
	do_ucmd_e :: proc "c" (eap: rawptr, preview: bool) -> C.int ---
	@(link_name = "cmdpreview_get_ns")
	cmdpreview_get_ns_e :: proc "c" () -> C.int ---
	@(link_name = "cmdpreview_get_bufnr")
	cmdpreview_get_bufnr_e :: proc "c" () -> C.int ---
}

EX_BUFUNL_O :: 0x10000
CMD_BDELETE_O :: 25
CMD_BWIPEOUT_O :: 42
CMD_BUNLOAD_O :: 41
CMD_TRY_O :: 491
CMD_NUMBER_O :: 305
CMD_POUND_O :: 553
CMD_LIST_O :: 210
CMD_PRINT_O :: 319
CMDDEF_PREVIEW_OFF :: 16
E749_S :: "E749: Empty buffer"

ExFunc_T :: proc "c" (eap: rawptr)
ExPreview_T :: proc "c" (eap: rawptr, ns: C.int, bufnr: C.int) -> C.int

// Simple command-line runner (ex_docmd.c public).
@(export)
do_cmdline_cmd :: proc "c" (cmd: cstring) -> C.int {
	context = runtime.default_context()
	return do_cmdline(cmd, nil, nil, DOCMD_VERBOSE_O | DOCMD_NOWAIT_O | DOCMD_KEYTYPED_O)
}

// :print engine (ex_docmd.c static → export; table-bound for :print/:list/:number).
@(export)
ex_print :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O != 0 {
		emsg(cstring(E749_S))
	} else {
		line := ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]
		for line <= ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] && !got_int {
			os_breakcheck()
			cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
			flags := ([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0]
			print_line(line, cmdidx == CMD_NUMBER_O || cmdidx == CMD_POUND_O || (flags & EXFLAG_NR_O) != 0, cmdidx == CMD_LIST_O || (flags & EXFLAG_LIST_O) != 0, line == ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0])
			line += 1
		}
		setpcmark()
		([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		beginline(0x01 | 0x02)
	}
	ex_no_reprint_g = true
}

// Bare-range handler (ex_docmd.c static).
ex_range_without_command_o :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	errormsg: cstring = nil
	cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	if ([^]u8)(cmd)[0] == '|' || (exmode_active && cmd != transmute(cstring)(transmute(^u8)(uintptr(nvim_odin_exmode_plus_addr_e()) + 1))) {
		([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] = CMD_PRINT_O
		([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] = EX_RANGE_O | EX_COUNT_O | EX_TRLBAR_O
		ir := invalid_range(eap)
		if ir == nil {
			correct_range_o(eap)
			ex_print(eap)
		} else {
			errormsg = ir
		}
	} else if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] != 0 {
		line2 := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		if line2 > ([^]C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)[0] {
			line2 = ([^]C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)[0]
		}
		if line2 < 0 {
			errormsg = cstring(E16_S)
		} else {
			if line2 == 0 {
				([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = 1
			} else {
				([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = line2
			}
			beginline(BL_SOL_FIX)
		}
	}
	return errormsg
}

// Command executor core (ex_docmd.c static).
execute_cmd0_o :: proc "c" (retv: ^C.int, eap: rawptr, errormsg: ^cstring, preview: bool) -> C.int {
	context = runtime.default_context()
	argt := ([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0]
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if (argt & EX_XFILE_O) != 0 {
		if expand_filename(eap, ([^]^cstring)(uintptr(eap) + EXARG_CMDLINEP_OFF)[0], errormsg) == FAIL_E {
			return FAIL_E
		}
	}
	if (argt & EX_BUFNAME_O) != 0 && ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] != 0 && ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 && cmdidx >= 0 {
		if ([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0] == nil {
			p: cstring
			arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
			if cmdidx == CMD_BDELETE_O || cmdidx == CMD_BWIPEOUT_O || cmdidx == CMD_BUNLOAD_O {
				p = skiptowhite_esc(arg)
			} else {
				p = transmute(cstring)(uintptr(rawptr(arg)) + uintptr(libc.strlen(arg)))
				for uintptr(rawptr(p)) > uintptr(rawptr(arg)) && (([^]u8)(uintptr(rawptr(p)) - 1)[0] == ' ' || ([^]u8)(uintptr(rawptr(p)) - 1)[0] == '\t') {
					p = transmute(cstring)(uintptr(rawptr(p)) - 1)
				}
			}
			([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = buflist_findpat(arg, p, (argt & EX_BUFUNL_O) != 0, false, false)
			([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] = 1
			([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = skipwhite(p)
		} else {
			a0 := ([^]rawptr)(([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0])[0]
			al0 := ([^]C.size_t)(([^]rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)[0])[0]
			([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = buflist_findpat(transmute(cstring)(a0), transmute(cstring)(uintptr(a0) + uintptr(al0)), (argt & EX_BUFUNL_O) != 0, false, false)
			([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] = 1
			shift_cmd_args_o(eap)
		}
		if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] < 0 {
			return FAIL_E
		}
	}
	if cmdidx == CMD_TRY_O && cmdmod_cmod_flags & CMOD_ERRSILENT_O != 0 && ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_DID_ESILENT_OFF)[0] > 0 {
		emsg_silent -= ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_DID_ESILENT_OFF)[0]
		if emsg_silent < 0 {
			emsg_silent = 0
		}
		([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_DID_ESILENT_OFF)[0] = 0
	}
	if cmdidx < 0 {
		retv^ = do_ucmd_e(eap, preview)
	} else {
		([^]rawptr)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = nil
		if preview {
			pfn := transmute(ExPreview_T)((^rawptr)(uintptr(nvim_odin_cmddef_at_e(cmdidx)) + CMDDEF_PREVIEW_OFF)^)
			retv^ = pfn(eap, cmdpreview_get_ns_e(), cmdpreview_get_bufnr_e())
		} else {
			fn := transmute(ExFunc_T)((^rawptr)(uintptr(nvim_odin_cmddef_at_e(cmdidx)) + 8)^)
			fn(eap)
		}
		if ([^]rawptr)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] != nil {
			errormsg^ = transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_ERRMSG_OFF)[0])
		}
	}
	return OK_E
}

// —— Batch 22: ex_docmd.c cmdline parser (export + weak) ——
EX_REGSTR_O :: 0x200
EX_COUNT_O :: 0x400
EX_BUFNAME_O :: 0x8000
EX_BANG_O :: 0x002
EX_DFLALL_O :: 0x020
EX_TRLBAR_O :: 0x100
EXARG_REGNAME_OFF :: 128
EXARG_ARGLENS_OFF :: 16
CMD_READ_O :: 363
CMD_PUT_O :: 347
CMD_IPUT_O :: 197
CMD_SMAGIC_O :: 413
CMD_SNOMAGIC_O :: 418
E464_S :: "E464: Ambiguous use of user-defined command"
E477_S :: "E477: No ! allowed"
E492_S :: "E492: Not an editor command"

// Post-range command finder (ex_docmd.c static).
find_excmd_after_range_o :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = skip_range(cmd, nil)
	p := find_ex_command(eap, nil)
	([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = cmd
	return p
}

// Bang-flag parser (ex_docmd.c static).
parse_bang_o :: proc "c" (eap: rawptr, p: ^cstring) -> bool {
	context = runtime.default_context()
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if ([^]u8)(p^)[0] == '!' && cmdidx != CMD_SUBSTITUTE_O && cmdidx != CMD_SMAGIC_O && cmdidx != CMD_SNOMAGIC_O {
		p^ = transmute(cstring)(uintptr(rawptr(p^)) + 1)
		return true
	}
	return false
}

// Register-arg parser (ex_docmd.c static).
parse_register_o :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	argt := ([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0]
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if (argt & EX_REGSTR_O) != 0 && ([^]u8)(arg)[0] != 0 && (cmdidx >= 0 || ([^]u8)(arg)[0] != '=') && !((argt & EX_COUNT_O) != 0 && ascii_isdigit_o(([^]u8)(arg)[0])) {
		if valid_yank_reg(C.int(([^]u8)(arg)[0]), !(cmdidx < 0) && cmdidx != CMD_PUT_O && cmdidx != CMD_IPUT_O) {
			([^]C.int)(uintptr(eap) + EXARG_REGNAME_OFF)[0] = C.int(([^]u8)(arg)[0])
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			if ([^]u8)(uintptr(rawptr(arg)) - 1)[0] == '=' && ([^]u8)(arg)[0] != 0 {
				if ([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] == false {
					set_expr_line(xstrdup(transmute(^u8)(arg)))
				}
				arg = transmute(cstring)(uintptr(rawptr(arg)) + uintptr(libc.strlen(arg)))
			}
			([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = skipwhite(arg)
		}
	}
}

// Arg shifter (ex_docmd.c static).
shift_cmd_args_o :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	oldargs := (^rawptr)(uintptr(eap) + EXARG_ARGS_OFF)^
	oldarglens := (^rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)^
	([^]C.int)(uintptr(eap) + EXARG_ARGC_OFF)[0] -= 1
	argc := ([^]C.int)(uintptr(eap) + EXARG_ARGC_OFF)[0]
	if argc > 0 {
		([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0] = rawptr(xcalloc(C.size_t(argc), 8))
		([^]rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)[0] = rawptr(xcalloc(C.size_t(argc), 8))
	} else {
		([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0] = nil
		([^]rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)[0] = nil
	}
	for i: C.int = 0; i < argc; i += 1 {
		([^]rawptr)(([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0])[uintptr(i)] = ([^]rawptr)(oldargs)[uintptr(i) + 1]
		([^]C.size_t)(([^]rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)[0])[uintptr(i)] = ([^]C.size_t)(oldarglens)[uintptr(i) + 1]
	}
	if argc > 0 {
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = transmute(cstring)(([^]rawptr)(([^]rawptr)(uintptr(eap) + EXARG_ARGS_OFF)[0])[0])
	} else {
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = transmute(cstring)(uintptr(([^]rawptr)(oldargs)[0]) + uintptr(([^]C.size_t)(oldarglens)[0]))
	}
	xfree(oldargs)
	xfree(oldarglens)
}

// Count-arg parser (ex_docmd.c static).
parse_count_o :: proc "c" (eap: rawptr, errormsg: ^cstring, validate: bool) -> C.int {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	argt := ([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0]
	if (argt & EX_COUNT_O) != 0 && ascii_isdigit_o(([^]u8)(arg)[0]) {
		take := true
		if (argt & EX_BUFNAME_O) != 0 {
			sk := skipdigits(transmute(cstring)(uintptr(rawptr(arg)) + 1))
			if ([^]u8)(sk)[0] != 0 && ([^]u8)(sk)[0] != ' ' && ([^]u8)(sk)[0] != '\t' {
				take = false
			}
		}
		if take {
			cs := transmute(^u8)(arg)
			n := getdigits_int32(&cs, false, MAXLNUM)
			arg = transmute(cstring)(cs)
			([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = skipwhite(arg)
			args := (^rawptr)(uintptr(eap) + EXARG_ARGS_OFF)^
			if args != nil {
				argc := ([^]C.int)(uintptr(eap) + EXARG_ARGC_OFF)[0]
				arglens := (^rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)^
				a0 := ([^]rawptr)(args)[0]
				if uintptr(rawptr(arg)) < uintptr(a0) + uintptr(([^]C.size_t)(arglens)[0]) {
					([^]C.size_t)(arglens)[0] -= C.size_t(uintptr(rawptr(arg)) - uintptr(a0))
					([^]rawptr)(args)[0] = rawptr(arg)
				} else {
					shift_cmd_args_o(eap)
				}
			}
			if n <= 0 && (argt & EX_ZEROR_O) == 0 {
				if errormsg != nil {
					errormsg^ = cstring(E939_S)
				}
				return FAIL_E
			}
			set_cmd_count(eap, n, validate)
		}
	}
	return OK_E
}

// Error-message appender (ex_docmd.c static).
append_command_o :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	base := transmute(^u8)(&IObuff[0])
	ln := libc.strlen(transmute(cstring)(base))
	d: ^u8 = nil
	if ln > C.size_t(IOSIZE_O) - 100 {
		d = transmute(^u8)(uintptr(base) + uintptr(C.size_t(IOSIZE_O) - 100))
		d = transmute(^u8)(uintptr(d) - uintptr(utf_head_off_r(base, d)))
		([^]u8)(d)[0] = '.'
		([^]u8)(d)[1] = '.'
		([^]u8)(d)[2] = '.'
		([^]u8)(d)[3] = 0
	}
	_xstrlcat(transmute(cstring)(base), cstring(": "), C.size_t(IOSIZE_O))
	d = transmute(^u8)(uintptr(base) + uintptr(libc.strlen(transmute(cstring)(base))))
	s := cmd
	for ([^]u8)(s)[0] != 0 && C.size_t(uintptr(d) - uintptr(base)) + 5 < C.size_t(IOSIZE_O) {
		if ([^]u8)(s)[0] == 0xc2 && ([^]u8)(s)[1] == 0xa0 {
			s = transmute(cstring)(uintptr(rawptr(s)) + 2)
			([^]u8)(d)[0] = '<'
			([^]u8)(d)[1] = 'a'
			([^]u8)(d)[2] = '0'
			([^]u8)(d)[3] = '>'
			d = transmute(^u8)(uintptr(d) + 4)
		} else if C.size_t(uintptr(d) - uintptr(base)) + C.size_t(utfc_ptr2len(transmute(cstring)(s))) + 1 >= C.size_t(IOSIZE_O) {
			break
		} else {
			mb_copy_char_e(transmute(^cstring)(&s), transmute(^cstring)(&d))
		}
	}
	([^]u8)(d)[0] = 0
}

// parse_cmdline epilogue (shared fail/success exit).
parse_cmdline_end_o :: proc "c" (cmdinfo: rawptr, retval: bool, save_ex_pressedreturn: bool, save_cursor: Pos_T) -> bool {
	context = runtime.default_context()
	if !retval {
		undo_cmdmod(cmdinfo)
	}
	ex_pressedreturn = save_ex_pressedreturn
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
	restore_last_search_pattern()
	return retval
}

// Full cmdline parser (ex_docmd.c public).
@(export)
parse_cmdline :: proc "c" (cmdline: ^cstring, eap: rawptr, cmdinfo: rawptr, errormsg: ^cstring) -> bool {
	context = runtime.default_context()
	after_modifier: cstring = nil
	retval := false
	save_ex_pressedreturn := ex_pressedreturn
	save_cursor := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	save_last_search_pattern()
	libc.memset(cmdinfo, 0, 256)
	libc.memset(eap, 0, 192)
	([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] = 1
	([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = 1
	([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = ([^]cstring)(cmdline)[0]
	([^]rawptr)(uintptr(eap) + EXARG_CMDLINEP_OFF)[0] = rawptr(cmdline)
	orig_cmd := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	result := parse_command_modifiers(eap, errormsg, rawptr(uintptr(cmdinfo)), false)
	after_modifier = ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
	if result == FAIL_E && after_modifier == orig_cmd {
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	p := find_excmd_after_range_o(eap)
	if p == nil {
		errormsg^ = cstring(E464_S)
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	set_cmd_addr_type(eap, p)
	if parse_cmd_address(eap, errormsg, true) == FAIL_E {
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0] = skip_colon_white_o(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0], true)
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == '"' {
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 0 && ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 && after_modifier == ([^]cstring)(cmdline)[0] {
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 0 && ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_SIZE_O {
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
			([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] = EX_RANGE_O
		} else {
			([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] = 0
			([^]C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)[0] = ADDR_NONE_O
		}
		retval = true
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_SIZE_O {
		xstrlcpy(transmute(cstring)(&IObuff[0]), cstring(E492_S), C.size_t(IOSIZE_O))
		cmdname := after_modifier
		if cmdname == nil {
			cmdname = ([^]cstring)(cmdline)[0]
		}
		append_command_o(cmdname)
		errormsg^ = transmute(cstring)(&IObuff[0])
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if parse_bang_o(eap, &p) {
		([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] = 1
	} else {
		([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] = 0
	}
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] >= 0 {
		([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] = C.int((^CommandDefinition_O)(nvim_odin_cmddef_at_e(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0])).argt)
	}
	([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = skipwhite(p)
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_BANG_O {
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = p
	}
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_READ_O && ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] = 0
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) != 0 {
		separate_nextcmd(eap)
	} else if cmd_has_expr_args(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]) {
		arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
		for ([^]u8)(arg)[0] != 0 && ([^]u8)(arg)[0] != '|' && ([^]u8)(arg)[0] != '\n' {
			start := arg
			emsg_skip += 1
			skip_expr(&arg, nil)
			emsg_skip -= 1
			if arg == start {
				arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			}
		}
		if ([^]u8)(arg)[0] == '|' || ([^]u8)(arg)[0] == '\n' {
			([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(check_nextcmd(transmute(^u8)(arg)))
			([^]u8)(arg)[0] = 0
		}
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_BANG_O) == 0 && ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		errormsg^ = cstring(E477_S)
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_RANGE_O) == 0 && ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		errormsg^ = cstring(E481_S)
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_DFLALL_O) != 0 && ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
		set_cmd_dflall_range(eap)
	}
	parse_register_o(eap)
	if parse_count_o(eap, errormsg, false) == FAIL_E {
		return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
	}
	if ([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] != nil {
		([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(skip_colon_white_o(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0]), true))
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_XFILE_O) != 0 {
		([^]bool)(uintptr(cmdinfo) + 248)[0] = true
	}
	if (([^]C.int)(uintptr(eap) + EXARG_ARGT_OFF)[0] & EX_TRLBAR_O) != 0 {
		([^]bool)(uintptr(cmdinfo) + 249)[0] = true
	}
	retval = true
	return parse_cmdline_end_o(cmdinfo, retval, save_ex_pressedreturn, save_cursor)
}

// —— Batch 20: ex_docmd.c splitview (export + weak) ——
foreign _ {
	@(link_name = "get_findfunc")
	get_findfunc_e :: proc "c" () -> cstring ---
	@(link_name = "find_file_in_path")
	find_file_in_path_e :: proc "c" (ptr: cstring, len: C.size_t, options: C.int, first: C.int, rel_fname: cstring, file_to_find: ^rawptr, search_ctx: ^rawptr) -> ^u8 ---
}

CMD_TABFIND_O :: 460
CMD_SFIND_O :: 406
E345_S :: "E345: Can't find file \"%s\" in path"
E347_S :: "E347: No more file \"%s\" found in path"

// findfunc file finder (ex_docmd.c static).
findfunc_find_file_o :: proc "c" (findarg: cstring, findarg_len: C.size_t, count: C.int) -> ^u8 {
	context = runtime.default_context()
	ret_fname: ^u8 = nil
	cc := ([^]u8)(findarg)[uintptr(findarg_len)]
	([^]u8)(findarg)[uintptr(findarg_len)] = 0
	fname_list := call_findfunc_o(findarg, 0)
	fname_count := tv_list_len_o(fname_list)
	if fname_count == 0 {
		semsg(cstring(E345_S), findarg)
	} else {
		if count > fname_count {
			semsg(cstring(E347_S), findarg)
		} else {
			li := tv_list_find(fname_list, count - 1)
			if li != nil {
				tv := (^Typval)(uintptr(li) + 16)^
				if tv.v_type == VAR_STRING && transmute(rawptr)(tv.vval) != nil {
					ret_fname = xstrdup(transmute(^u8)(tv.vval))
				} else if tv.v_type == VAR_DICT && transmute(rawptr)(tv.vval) != nil {
					ret_fname = transmute(^u8)(tv_dict_get_string(transmute(rawptr)(tv.vval), cstring("word"), true))
				}
			}
		}
	}
	if fname_list != nil {
		tv_list_free(fname_list)
	}
	([^]u8)(findarg)[uintptr(findarg_len)] = cc
	return ret_fname
}

// :split/:vsplit/:tabedit engine (ex_docmd.c public).
@(export)
ex_splitview :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	old_curwin := curwin
	fname: ^u8 = nil
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	use_tab := cmdidx == CMD_TABEDIT_O || cmdidx == CMD_TABFIND_O || cmdidx == CMD_TABNEW_O
	if bt_quickfix(curbuf) && (^C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + 8)^ == 0 {
		if cmdidx == CMD_SPLIT_O {
			([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] = CMD_NEW_O
			cmdidx = CMD_NEW_O
		}
		if cmdidx == CMD_VSPLIT_O {
			([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] = CMD_VNEW_O
			cmdidx = CMD_VNEW_O
		}
	}
	if cmdidx == CMD_SFIND_O || cmdidx == CMD_TABFIND_O {
		eap_arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
		if ([^]u8)(get_findfunc_e())[0] != 0 {
			cnt := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
			if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] <= 0 {
				cnt = 1
			}
			fname = findfunc_find_file_o(eap_arg, libc.strlen(eap_arg), cnt)
		} else {
			file_to_find: rawptr = nil
			search_ctx: rawptr = nil
			bff := (^cstring)(uintptr(curbuf) + B_FFNAME)^
			fname = find_file_in_path_e(eap_arg, libc.strlen(eap_arg), FNAME_MESS, 1, transmute(cstring)(bff), &file_to_find, &search_ctx)
			xfree(file_to_find)
			vim_findfile_cleanup_e(search_ctx)
		}
		if fname == nil {
			return
		}
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = transmute(cstring)(fname)
	}
	if use_tab {
		after: C.int = 0
		if ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + 8)[0] != 0 {
			after = ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + 8)[0]
		} else if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] != 0 {
			after = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] + 1
		}
		if win_new_tabpage(after, ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], true, nil) != nil {
			do_exedit(eap, old_curwin)
			apply_autocmds(EVENT_TABNEWENTERED_O, nil, nil, false, curbuf)
			if curwin != old_curwin && win_valid(old_curwin) && (^rawptr)(uintptr(old_curwin) + W_BUFFER_OFF)^ != curbuf && (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
				([^]C.int)(uintptr(old_curwin) + W_ALT_FNUM)[0] = ([^]C.int)(uintptr(curbuf) + B_FNUM_OFF)[0]
			}
		}
	} else {
		sz: C.int = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] <= 0 {
			sz = 0
		}
		fl := 0
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 'v' {
			fl = WSP_VERT_O
		}
		if win_split(sz, C.int(fl)) != FAIL_E {
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] != 0 {
			([^]bool)(uintptr(curwin) + W_P_SCB_OFF)[0] = false
			([^]bool)(uintptr(curwin) + W_P_CRB_OFF)[0] = false
		} else {
			do_check_scrollbind_r(false)
		}
		do_exedit(eap, old_curwin)
		}
	}
	xfree(rawptr(fname))
}

// —— Batch 16: ex_docmd.c tabpage close (exports + weak) ——
CMD_TABCLOSE_O :: 457
CMD_TABONLY_O :: 466
E784_S :: "E784: Cannot close last tab page"
E813_S :: "E813: Cannot close autocmd window"

// Window closer with hidden-modified handling (ex_docmd.c public).
@(export)
ex_win_close :: proc "c" (forceit: C.int, win: rawptr, tp: rawptr) {
	context = runtime.default_context()
	if is_aucmd_win_r(win) {
		emsg(cstring(E813_S))
		return
	}
	if !(^bool)(uintptr(win) + W_FLOATING_OFF)^ && window_layout_locked(CMD_CLOSE_O) {
		return
	}
	buf := (^rawptr)(uintptr(win) + W_BUFFER_OFF)^
	need_hide := bufIsChanged(buf) && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 1
	if need_hide && !buf_hide(buf) && forceit == 0 {
		if (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && p_write_g != 0 {
			br: Bufref_T
			set_bufref(&br, buf)
			dialog_changed_r(buf, false)
			if bufref_valid(&br) && bufIsChanged(buf) {
				return
			}
			need_hide = false
		} else {
			no_write_message()
			return
		}
	}
	if tp == nil {
		win_close(win, !need_hide && !buf_hide(buf), forceit != 0)
	} else {
		fb: C.int = 0
		if !need_hide && !buf_hide(buf) {
			fb = 1
		}
		win_close_othertab(win, fb, tp, forceit != 0)
	}
}

// Current tabpage closer (ex_docmd.c public).
@(export)
tabpage_close :: proc "c" (forceit: C.int) {
	context = runtime.default_context()
	if window_layout_locked(CMD_TABCLOSE_O) {
		return
	}
	trigger_tabclosedpre(curtab)
	(^bool)(uintptr(curtab) + TP_DID_TABCLOSEDPRE_OFF)^ = true
	save_curtab := curtab
	for (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
		ex_win_close(forceit, curwin, nil)
	}
	if firstwin != lastwin_g {
		close_others(1, forceit, true)
	}
	if firstwin == lastwin_g {
		ex_win_close(forceit, curwin, nil)
	}
	if curtab == save_curtab {
		(^bool)(uintptr(curtab) + TP_DID_TABCLOSEDPRE_OFF)^ = false
	}
}

// Other tabpage closer (ex_docmd.c public).
@(export)
tabpage_close_other :: proc "c" (tp: rawptr, forceit: C.int) {
	context = runtime.default_context()
	done: C.int = 0
	prev_idx: [65]u8
	if window_layout_locked(CMD_SIZE_O) {
		return
	}
	trigger_tabclosedpre(tp)
	(^bool)(uintptr(tp) + TP_DID_TABCLOSEDPRE_OFF)^ = true
	for {
		done += 1
		if done >= 1000 {
			break
		}
		libc.snprintf(transmute([^]u8)(&prev_idx[0]), 65, cstring("%i"), tabpage_index(tp))
		wp := (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^
		ex_win_close(forceit, wp, tp)
		if !valid_tabpage(tp) {
			break
		}
		if (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^ == wp {
			done = 1000
			break
		}
	}
	if done >= 1000 {
		(^bool)(uintptr(tp) + TP_DID_TABCLOSEDPRE_OFF)^ = false
		return
	}
}

// New tabpage opener (ex_docmd.c public).
@(export)
tabpage_new :: proc "c" () {
	context = runtime.default_context()
	ea: [192]u8
	libc.memset(rawptr(&ea[0]), 0, 192)
	([^]C.int)(uintptr(rawptr(&ea[0])) + EXARG_CMDIDX_OFF)[0] = CMD_TABNEW_O
	([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_CMD_OFF)[0] = cstring("tabn")
	([^]cstring)(uintptr(rawptr(&ea[0])) + EXARG_ARG_OFF)[0] = cstring("")
	ex_splitview(rawptr(&ea[0]))
}

// —— Batch 17: ex_docmd.c chdir cluster (exports + weak) ——
foreign _ {
	@(link_name = "allbuf_locked")
	allbuf_locked_e :: proc "c" () -> bool ---
	@(link_name = "vim_chdir")
	vim_chdir_e :: proc "c" (new_dir: ^u8) -> C.int ---
	@(link_name = "p_cdh")
	p_cdh_g: C.int
}

@(export)
prev_dir: cstring = nil

CDSCOPE_WINDOW_O :: 0
CDSCOPE_TABPAGE_O :: 1
CDSCOPE_GLOBAL_O :: 2
CDSCOPE_INVALID_O :: -1
CDCAUSE_MANUAL_O :: 0
CMD_TCD_O :: 451
CMD_TCHDIR_O :: 452
CMD_LCD_O :: 225
CMD_LCHDIR_O :: 226
E186_S :: "E186: No previous directory"
E187_S :: "E187: Unknown"
E472_S :: "E472: Command failed"

// Previous-directory selector (ex_docmd.c static).
get_prevdir_o :: proc "c" (scope: C.int) -> cstring {
	context = runtime.default_context()
	if scope == CDSCOPE_TABPAGE_O {
		return (^cstring)(uintptr(curtab) + TP_PREVDIR_OFF)^
	} else if scope == CDSCOPE_WINDOW_O {
		return (^cstring)(uintptr(curwin) + W_PREVDIR_OFF)^
	}
	return prev_dir
}

// Chdir side-effect handler (ex_docmd.c static).
post_chdir_o :: proc "c" (scope: C.int, trigger_dirchanged: bool) {
	context = runtime.default_context()
	wld := (^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^
	if wld != nil {
		xfree(wld)
		(^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^ = nil
	}
	if scope >= CDSCOPE_TABPAGE_O {
		tld := (^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^
		if tld != nil {
			xfree(tld)
			(^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^ = nil
		}
	}
	if scope < CDSCOPE_GLOBAL_O {
		pdir := get_prevdir_o(scope)
		if globaldir_g == nil && pdir != nil {
			globaldir_g = rawptr(xstrdup(transmute(^u8)(pdir)))
		}
	}
	cwd: [4096]u8
	if os_dirname(transmute(cstring)(&cwd[0]), 4096) != OK_E {
		return
	}
	if scope == CDSCOPE_GLOBAL_O {
		if globaldir_g != nil {
			xfree(globaldir_g)
			globaldir_g = nil
		}
	} else if scope == CDSCOPE_TABPAGE_O {
		(^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^ = rawptr(xstrdup(transmute(^u8)(&cwd[0])))
	} else if scope == CDSCOPE_WINDOW_O {
		(^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^ = rawptr(xstrdup(transmute(^u8)(&cwd[0])))
	} else {
		libc.abort()
	}
	last_chdir_reason_g = nil
	shorten_fnames(vim_strchr(p_cpo, '~') == nil)
	if trigger_dirchanged {
		do_autocmd_dirchanged_r(transmute(cstring)(&cwd[0]), scope, CDCAUSE_MANUAL_O, false)
	}
}

// Directory changer (ex_docmd.c public).
@(export)
changedir_func :: proc "c" (new_dir_in: cstring, scope: C.int) -> bool {
	context = runtime.default_context()
	nd := new_dir_in
	if nd == nil || allbuf_locked_e() {
		return false
	}
	pdir: cstring = nil
	if libc.strcmp(nd, cstring("-")) == 0 {
		pdir = get_prevdir_o(scope)
		if pdir == nil {
			emsg(cstring(E186_S))
			return false
		}
		nd = pdir
	}
	if os_dirname(transmute(cstring)(&name_buff[0]), MAXPATHL_O) == OK_E {
		pdir = transmute(cstring)(xstrdup(transmute(^u8)(&name_buff[0])))
	} else {
		pdir = nil
	}
	if ([^]u8)(nd)[0] == 0 && p_cdh_g != 0 {
		expand_env(cstring("$HOME"), transmute(cstring)(&name_buff[0]), MAXPATHL_O)
		nd = transmute(cstring)(&name_buff[0])
	}
	dir_differs := pdir == nil || pathcmp_r(pdir, nd, -1) != 0
	if dir_differs {
		do_autocmd_dirchanged_r(nd, scope, CDCAUSE_MANUAL_O, true)
		if vim_chdir_e(transmute(^u8)(nd)) != 0 {
			emsg(cstring(E472_S))
			xfree(rawptr(pdir))
			return false
		}
	}
	slot: ^rawptr = nil
	if scope == CDSCOPE_TABPAGE_O {
		slot = transmute(^rawptr)(uintptr(curtab) + TP_PREVDIR_OFF)
	} else if scope == CDSCOPE_WINDOW_O {
		slot = transmute(^rawptr)(uintptr(curwin) + W_PREVDIR_OFF)
	} else {
		slot = transmute(^rawptr)(&prev_dir)
	}
	xfree(slot^)
	slot^ = rawptr(pdir)
	post_chdir_o(scope, dir_differs)
	return true
}

// :cd/:tcd/:lcd handler (ex_docmd.c public).
@(export)
ex_cd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	new_dir := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(new_dir)[0] == 0 && p_cdh_g == 0 {
		ex_pwd(nil)
		return
	}
	scope: C.int = CDSCOPE_GLOBAL_O
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx == CMD_TCD_O || cmdidx == CMD_TCHDIR_O {
		scope = CDSCOPE_TABPAGE_O
	} else if cmdidx == CMD_LCD_O || cmdidx == CMD_LCHDIR_O {
		scope = CDSCOPE_WINDOW_O
	}
	if changedir_func(new_dir, scope) {
		if KeyTyped || p_verbose >= 5 {
			ex_pwd(eap)
		}
	}
}

// —— Batch 18: ex_docmd.c quit/sleep/open/filetype leaves (exports + weak) ——
foreign _ {
	@(link_name = "arg_had_last")
	arg_had_last_g: bool
	@(link_name = "vpeekc")
	vpeekc_e :: proc "c" () -> C.int ---
}

@(export)
quitmore: C.int = 0

@(export)
filetype_detect: C.int = -1

@(export)
filetype_plugin: C.int = -1

@(export)
filetype_indent: C.int = -1

EVENT_QUITPRE_O :: 91
EVENT_EXITPRE_O :: 47
E173_ONE_S :: "E173: %d more file to edit"
E173_MANY_S :: "E173: %d more files to edit"
E189_S :: "E189: \"%s\" exists (add ! to override)"
E190_S :: "E190: Cannot open \"%s\" for writing"

// More-files-to-edit guard (ex_docmd.c static).
check_more_o :: proc "c" (message: bool, forceit: bool) -> C.int {
	context = runtime.default_context()
	argc := (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^))^
	n := argc - (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ - 1
	if !forceit && only_one_window() && argc > 1 && !arg_had_last_g && n > 0 && quitmore == 0 {
		if message {
			if (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && (^rawptr)(uintptr(curbuf) + B_FNAME)^ != nil {
				buff: [DIALOG_MSG_SIZE_O]u8
				fmt := cstring(E173_MANY_S)
				if n == 1 {
					fmt = cstring(E173_ONE_S)
				}
				libc.snprintf(transmute([^]u8)(&buff[0]), 1000, fmt, n)
				if vim_dialog_yesno_r(VIM_QUESTION_O, nil, transmute(cstring)(&buff[0]), 1) == VIM_YES_O {
					return OK_E
				}
				return FAIL_E
			}
			fmt := cstring(E173_MANY_S)
			if n == 1 {
				fmt = cstring(E173_ONE_S)
			}
			semsg(fmt, n)
			quitmore = 2
		}
		return FAIL_E
	}
	return OK_E
}

// QuitPre/ExitPre trigger (ex_docmd.c public).
@(export)
before_quit_autocmds :: proc "c" (wp: rawptr, quit_all: bool, forceit: bool) -> bool {
	context = runtime.default_context()
	if ([^]u8)(get_vim_var_str(VV_EXITREASON_O))[0] == 0 {
		set_vim_var_string(VV_EXITREASON_O, cstring("quit"), 4)
	}
	apply_autocmds(EVENT_QUITPRE_O, nil, nil, false, (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^)
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if !win_valid(wp) || curbuf_locked_r() || ((^C.int)(uintptr(wbuf) + B_NWINDOWS_OFF)^ == 1 && (^C.int)(uintptr(wbuf) + B_LOCKED_OFF)^ > 0) {
		set_vim_var_string(VV_EXITREASON_O, nil, -1)
		return true
	}
	if quit_all || (check_more_o(false, forceit) == OK_E && only_one_window()) {
		apply_autocmds(EVENT_EXITPRE_O, nil, nil, false, curbuf)
		if !win_valid(wp) || curbuf_locked_r() || ((^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ == 1 && (^C.int)(uintptr(curbuf) + B_LOCKED_OFF)^ > 0) {
			set_vim_var_string(VV_EXITREASON_O, nil, -1)
			return true
		}
	}
	return false
}

// Quit-all guard (ex_docmd.c public).
@(export)
before_quit_all :: proc "c" (eap: rawptr) -> C.int {
	context = runtime.default_context()
	if text_locked_r() {
		text_locked_msg_r()
		return FAIL_E
	}
	if before_quit_autocmds(curwin, true, (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0) {
		return FAIL_E
	}
	return OK_E
}

// —— Batch 19: ex_docmd.c throw + makeprg (exports + weak) ——
foreign _ {
	@(link_name = "current_exception")
	current_exception_g: rawptr
	@(link_name = "suppress_errthrow")
	suppress_errthrow_g: bool
	@(link_name = "estack_push")
	estack_push_e :: proc "c" (etype: Etype, name: cstring, lnum: C.int) -> rawptr ---
	@(link_name = "estack_pop")
	estack_pop_e :: proc "c" () ---
	@(link_name = "strrep")
	strrep_e :: proc "c" (src: cstring, what: cstring, rep: cstring) -> ^u8 ---
	@(link_name = "msg_make")
	msg_make_e :: proc "c" (arg: cstring) ---
	@(link_name = "p_gp")
	p_gp_g: ^u8
	@(link_name = "p_mp")
	p_mp_g: ^u8
}

EXCEPT_TYPE_OFF :: 0
EXCEPT_VALUE_OFF :: 8
EXCEPT_MESSAGES_OFF :: 16
EXCEPT_THROWNAME_OFF :: 24
EXCEPT_THROWLNUM_OFF :: 32
MSGLIST_NEXT_OFF :: 0
MSGLIST_MSG_OFF :: 8
MSGLIST_SFILE_OFF :: 24
MSGLIST_MULTILINE_OFF :: 36
E605_S :: "E605: Exception not caught: %s"

// Uncaught-exception reporter (ex_docmd.c public).
@(export)
handle_did_throw :: proc "c" () {
	context = runtime.default_context()
	ex := current_exception_g
	if ex == nil {
		libc.abort()
	}
	p: ^u8 = nil
	messages: rawptr = nil
	etype := (^C.int)(uintptr(ex) + EXCEPT_TYPE_OFF)^
	if etype == 0 {
		libc.snprintf(&IObuff[0], IOSIZE_O, cstring(E605_S), transmute(cstring)((^rawptr)(uintptr(ex) + EXCEPT_VALUE_OFF)^))
		p = xstrdup(transmute(^u8)(&IObuff[0]))
	} else if etype == 1 {
		messages = (^rawptr)(uintptr(ex) + EXCEPT_MESSAGES_OFF)^
		(^rawptr)(uintptr(ex) + EXCEPT_MESSAGES_OFF)^ = nil
	}
	estack_push_e(Etype.ETYPE_EXCEPT, transmute(cstring)((^rawptr)(uintptr(ex) + EXCEPT_THROWNAME_OFF)^), (^C.int)(uintptr(ex) + EXCEPT_THROWLNUM_OFF)^)
	(^rawptr)(uintptr(ex) + EXCEPT_THROWNAME_OFF)^ = nil
	discard_current_exception_e()
	if emsg_silent == 0 {
		suppress_errthrow_g = true
		force_abort_g = true
	}
	for messages != nil {
		next := (^rawptr)(uintptr(messages) + MSGLIST_NEXT_OFF)^
		emsg_multiline_e(transmute(cstring)((^rawptr)(uintptr(messages) + MSGLIST_MSG_OFF)^), cstring("emsg"), HLF_E_O, (^bool)(uintptr(messages) + MSGLIST_MULTILINE_OFF)^)
		xfree((^rawptr)(uintptr(messages) + MSGLIST_MSG_OFF)^)
		xfree((^rawptr)(uintptr(messages) + MSGLIST_SFILE_OFF)^)
		xfree(messages)
		messages = next
	}
	if messages == nil && p != nil {
		emsg(transmute(cstring)(p))
		xfree(rawptr(p))
	}
	if exestack.ga_len > 0 {
		nm_slot := transmute(^cstring)(uintptr(exestack.ga_data) + uintptr(exestack.ga_len - 1) * size_of(Estack) + 8)
		if nm_slot^ != nil {
			xfree(rawptr(nm_slot^))
			nm_slot^ = nil
		}
	}
	estack_pop_e()
}

// makeprg/grepprg command-line splicer (ex_docmd.c public).
@(export)
replace_makeprg :: proc "c" (eap: rawptr, arg_in: cstring, cmdlinep: ^cstring) -> cstring {
	context = runtime.default_context()
	arg := arg_in
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	isgrep := cmdidx == CMD_GREP_O || cmdidx == CMD_LGREP_O || cmdidx == CMD_GREPADD_O || cmdidx == CMD_LGREPADD_O
	if (cmdidx == CMD_MAKE_O || cmdidx == CMD_LMAKE_O || isgrep) && grep_internal_e(cmdidx) == 0 {
		program: ^u8 = nil
		if isgrep {
			bgp := (^cstring)(uintptr(curbuf) + B_P_GP_OFF)^
			if bgp == nil || ([^]u8)(bgp)[0] == 0 {
				program = p_gp_g
			} else {
				program = transmute(^u8)(bgp)
			}
		} else {
			bmp := (^cstring)(uintptr(curbuf) + B_P_MP_OFF)^
			if bmp == nil || ([^]u8)(bmp)[0] == 0 {
				program = p_mp_g
			} else {
				program = transmute(^u8)(bmp)
			}
		}
		arg = skipwhite(arg)
		new_cmdline := strrep_e(transmute(cstring)(program), cstring("$*"), arg)
		if new_cmdline == nil {
			plen := libc.strlen(transmute(cstring)(program))
			alen := libc.strlen(arg)
			new_cmdline = transmute(^u8)(xmalloc(plen + alen + 2))
			libc.memmove(rawptr(new_cmdline), rawptr(program), uint(plen + 1))
			sp := transmute([^]u8)(uintptr(new_cmdline) + uintptr(plen))
			sp[0] = ' '
			libc.memmove(rawptr(uintptr(sp) + 1), rawptr(arg), uint(alen + 1))
		}
		msg_make_e(arg)
		xfree(rawptr(([^]cstring)(cmdlinep)[0]))
		([^]cstring)(cmdlinep)[0] = transmute(cstring)(new_cmdline)
		arg = transmute(cstring)(new_cmdline)
	}
	return arg
}

// Millisecond sleeper with CTRL-C break (ex_docmd.c public).
@(export)
do_sleep :: proc "c" (msec: C.longlong, hide_cursor: bool) {
	context = runtime.default_context()
	if hide_cursor {
		ui_busy_start()
	}
	ui_flush()
	remaining := i64(msec)
	before: u64 = 0
	if remaining > 0 {
		before = os_hrtime()
	}
	for !got_int {
		loop_process_events_q(&main_loop, main_loop.events, remaining)
		if remaining == 0 {
			break
		} else if remaining > 0 {
			now := os_hrtime()
			remaining -= i64((now - before) / 1000000)
			before = now
			if remaining <= 0 {
				break
			}
		}
	}
	if got_int {
		vpeekc_e()
	}
	if hide_cursor {
		ui_busy_stop()
	}
}

// Redirection target opener (ex_docmd.c public).
@(export)
open_exfile :: proc "c" (fname: cstring, forceit: C.int, mode: cstring) -> rawptr {
	context = runtime.default_context()
	if os_isdir(fname) {
		semsg(cstring(E17_S), fname)
		return nil
	}
	if forceit == 0 && ([^]u8)(mode)[0] != 'a' && os_path_exists(fname) {
		semsg(cstring(E189_S), fname)
		return nil
	}
	fd := os_fopen(fname, mode)
	if fd == nil {
		semsg(cstring(E190_S), fname)
	}
	return fd
}

// Filetype plugin/indent enabler (ex_docmd.c public).
@(export)
filetype_plugin_enable :: proc "c" () {
	context = runtime.default_context()
	if filetype_plugin == -1 {
		source_runtime(transmute(^u8)(cstring("ftplugin.vim")), DIP_ALL)
		filetype_plugin = 1
	}
	if filetype_indent == -1 {
		source_runtime(transmute(^u8)(cstring("indent.vim")), DIP_ALL)
		filetype_indent = 1
	}
}

// Filetype detection enabler (ex_docmd.c public).
@(export)
filetype_maybe_enable :: proc "c" () {
	context = runtime.default_context()
	if filetype_detect == -1 {
		source_runtime(transmute(^u8)(cstring("filetype.lua filetype.vim")), DIP_ALL)
		filetype_detect = 1
	}
}

// findfunc option validator (ex_docmd.c public).
@(export)
did_set_findfunc :: proc "c" (args: rawptr) -> cstring {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(args) + OPTSET_BUF_OFF)^
	retval: C.int
	if ((^C.int)(uintptr(args) + OPTSET_FLAGS_OFF)^ & OPT_LOCAL_S) != 0 {
		retval = option_set_callback_func(transmute(^u8)((^rawptr)(uintptr(buf) + B_P_FFU_OFF)^), rawptr(uintptr(buf) + B_FFU_CB_OFF))
	} else {
		retval = option_set_callback_func(p_ffu_g, rawptr(&ffu_cb))
		if ((^C.int)(uintptr(args) + OPTSET_FLAGS_OFF)^ & OPT_GLOBAL_S) == 0 {
			callback_free((^Callback_E)(uintptr(buf) + B_FFU_CB_OFF))
		}
	}
	if retval == FAIL_E {
		return cstring(e_invarg_s)
	}
	slot := ([^]cstring)((^rawptr)(uintptr(args) + OPTSET_VARP_OFF)^)
	name := get_scriptlocal_funcname(slot[0])
	if name != nil {
		free_string_option(transmute(^u8)(slot[0]))
		slot[0] = name
	}
	return nil
}

// —— Batch 26: ex_docmd.c small handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "ex_lua")
	ex_lua_e :: proc "c" (eap: rawptr) ---
	@(link_name = "goto_byte")
	goto_byte_e :: proc "c" (cnt: C.int) ---
	@(link_name = "ml_preserve")
	ml_preserve_e :: proc "c" (buf: rawptr, message: bool, do_fsync: bool) ---
}

E191_S :: "E191: Argument must be a letter or forward/backward quote"

// :pwd (ex_docmd.c static → export; promotes Batch-17 ex_pwd_o).
@(export)
ex_pwd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if os_dirname(transmute(cstring)(&name_buff[0]), MAXPATHL_O) == OK_E {
		if p_verbose != 0 {
			context_s: cstring = cstring("global")
			if last_chdir_reason_g != nil {
				context_s = transmute(cstring)(last_chdir_reason_g)
			} else if (^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^ != nil {
				context_s = cstring("window")
			} else if (^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^ != nil {
				context_s = cstring("tabpage")
			}
			smsg(0, cstring("[%s] %s"), context_s, transmute(cstring)(&name_buff[0]))
		} else {
			msg_msg(transmute(cstring)(&name_buff[0]), 0)
		}
	} else {
		emsg(cstring(E187_S))
	}
}

// := (ex_docmd.c static → export).
@(export)
ex_equal :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] != 0 && ([^]u8)(arg)[0] != '|' {
		ex_lua_e(eap)
	} else {
		([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(find_nextcmd(arg))
		smsg(0, cstring("%ld"), C.longlong(([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]))
	}
}

// :goto (ex_docmd.c static → export).
@(export)
ex_goto :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_byte_e(([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
}

// :preserve (ex_docmd.c static → export).
@(export)
ex_preserve :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	ml_preserve_e(curbuf, true, true)
}

// :mark/:k (ex_docmd.c static → export).
@(export)
ex_mark :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] == 0 {
		emsg(cstring(E471_S))
		return
	}
	if ([^]u8)(arg)[1] != 0 {
		semsg(cstring(E488_TRAIL_S), arg)
		return
	}
	pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	beginline(BL_WHITE | BL_FIX)
	if setmark(C.int(([^]u8)(arg)[0])) == FAIL_E {
		emsg(cstring(E191_S))
	}
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
}

// —— Batch 24: ex_docmd.c exmode + mkdir (exports + weak) ——
// (may_trigger_modechanged is an Odin export in state.odin.)

E501_S :: "E501: At end-of-file"

// Ex-mode loop (ex_docmd.c public).
@(export)
do_exmode :: proc "c" () {
	context = runtime.default_context()
	exmode_active = true
	State = MODE_NORMAL_O
	may_trigger_modechanged()
	if global_busy != 0 {
		return
	}
	save_msg_scroll := msg_scroll
	RedrawingDisabled += 1
	no_wait_return += 1
	msg_msg(cstring("Entering Ex mode.  Type \"visual\" to go to Normal mode."), 0)
	for exmode_active {
		if ex_normal_busy_g > 0 && typebuf.tb_len == 0 {
			exmode_active = false
			break
		}
		msg_scroll = 1
		need_wait_return_g = false
		ex_pressedreturn = false
		ex_no_reprint_g = false
		changedtick := buf_changedtick_inline(curbuf)
		prev_msg_row := msg_row
		prev_line := ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0]
		cmdline_row = msg_row
		do_cmdline(nil, transmute(LineGetter)(getexline_e), nil, 0)
		lines_left = Rows - 1
		if (prev_line != ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] || changedtick != buf_changedtick_inline(curbuf)) && !ex_no_reprint_g {
			if ([^]C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)[0] & ML_EMPTY_O != 0 {
				emsg(cstring(E749_S))
			} else {
				if ex_pressedreturn {
					msg_scroll_flush_e()
					msg_row = prev_msg_row
					if prev_msg_row == Rows - 1 {
						msg_row -= 1
					}
				}
				msg_col = 0
				print_line_no_prefix(([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0], false, false)
				msg_clr_eos_r()
			}
		} else if ex_pressedreturn && !ex_no_reprint_g {
			if ([^]C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)[0] & ML_EMPTY_O != 0 {
				emsg(cstring(E749_S))
			} else {
				emsg(cstring(E501_S))
			}
		}
	}
	RedrawingDisabled -= 1
	no_wait_return -= 1
	redraw_all_later(UPD_NOT_VALID)
	update_screen()
	need_wait_return_g = false
	msg_scroll = save_msg_scroll
}

// mkdir with error message (ex_docmd.c public).
@(export)
vim_mkdir_emsg :: proc "c" (name: cstring, prot: C.int) -> C.int {
	context = runtime.default_context()
	ret := os_mkdir(name, C.int32_t(prot))
	if ret != 0 {
		semsg(cstring(E_MKDIR_S), name, os_strerror(ret))
		return FAIL_E
	}
	return OK_E
}

// Error-message buffer (moved ex_docmd.c static; single live copy).
@(export)
ex_error_buf: [480]u8

// Formatted error message (ex_docmd.c public).
// NOTE: fixed 2-arg form. All 10 live callers (8 C + 2 Odin) pass exactly
// (single-%s format, one string arg), so this is ABI-identical to the C
// variadic for every real call. A 3-arg or non-%s caller would need this
// widened back to variadic.
@(export)
ex_errmsg :: proc "c" (msg: cstring, arg: cstring) -> cstring {
	context = runtime.default_context()
	dst := transmute([^]u8)(&ex_error_buf[0])
	di: uint = 0
	mi: uint = 0
	mlen := uint(libc.strlen(msg))
	subbed := false
	for mi < mlen && di < 479 {
		if !subbed && ([^]u8)(msg)[mi] == '%' && mi + 1 < mlen && ([^]u8)(msg)[mi + 1] == 's' {
			alen := uint(libc.strlen(arg))
			ai: uint = 0
			for ai < alen && di < 479 {
				dst[di] = ([^]u8)(arg)[ai]
				di += 1
				ai += 1
			}
			mi += 2
			subbed = true
		} else {
			dst[di] = ([^]u8)(msg)[mi]
			di += 1
			mi += 1
		}
	}
	dst[di] = 0
	return transmute(cstring)(&ex_error_buf[0])
}

// —— Batch 27: ex_docmd.c buffer-nav handlers (exports + unstatic) ——

// :bdelete/:bwipeout/:bunload (ex_docmd.c static → export).
@(export)
ex_bunload :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	action := DOBUF_UNLOAD_O
	if cmdidx == CMD_BDELETE_O {
		action = DOBUF_DEL_O
	} else if cmdidx == CMD_BWIPEOUT_O {
		action = DOBUF_WIPE_O
	}
	([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = do_bufdel(C.int(action), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
}

// :buffer (ex_docmd.c static → export).
@(export)
ex_buffer :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	do_exbuffer(eap)
}

// :buffer engine (ex_docmd.c static → export).
@(export)
do_exbuffer :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] != 0 {
		([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E488_TRAIL_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
	} else {
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
			goto_buffer(eap, DOBUF_CURRENT_O, FORWARD_DIR, 0)
		} else {
			goto_buffer(eap, DOBUF_FIRST_O, FORWARD_DIR, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
		}
		if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
			do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
		}
	}
}

// :bmodified (ex_docmd.c static → export).
@(export)
ex_bmodified :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_buffer(eap, DOBUF_MOD_O, FORWARD_DIR, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
	}
}

// :bnext (ex_docmd.c static → export).
@(export)
ex_bnext :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_buffer(eap, DOBUF_CURRENT_O, FORWARD_DIR, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
	}
}

// :bprevious (ex_docmd.c static → export).
@(export)
ex_bprevious :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_buffer(eap, DOBUF_CURRENT_O, BACKWARD_DIR, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
	}
}

// :brewind (ex_docmd.c static → export).
@(export)
ex_brewind :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_buffer(eap, DOBUF_FIRST_O, FORWARD_DIR, 0)
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
	}
}

// :blast (ex_docmd.c static → export).
@(export)
ex_blast :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	goto_buffer(eap, DOBUF_LAST_O, BACKWARD_DIR, 0)
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		do_cmdline_cmd(transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0]))
	}
}

// —— Batch 28: ex_docmd.c quit handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "check_changed_any")
	check_changed_any_e :: proc "c" (hidden: bool, unload: bool) -> bool ---
	@(link_name = "ui_call_error_exit")
	ui_call_error_exit_e :: proc "c" (status: C.longlong) ---
}

// :quit (ex_docmd.c static → export).
@(export)
ex_quit :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if text_locked_r() {
		text_locked_msg_r()
		return
	}
	wp := curwin
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		wnr := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		wp = firstwin
		for (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ != nil {
			wnr -= 1
			if wnr <= 0 {
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	if curbuf_locked_r() {
		return
	}
	force := ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0
	if before_quit_autocmds(wp, false, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0) {
		return
	}
	save_exiting := exiting
	if check_more_o(false, force) == OK_E && only_one_window() {
		exiting = true
	}
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	ccgd: C.int = CCGD_EXCMD_O
	if p_awa != 0 {
		ccgd |= CCGD_AW_O
	}
	if force {
		ccgd |= CCGD_FORCEIT_O
	}
	if (!buf_hide(wbuf) && check_changed_r(wbuf, ccgd)) || check_more_o(true, force) == FAIL_E || (only_one_window() && check_changed_any_e(force, true)) {
		not_exiting(save_exiting)
	} else {
		if only_one_window() && (firstwin == lastwin_g || ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0) {
			getout(0)
		}
		not_exiting(save_exiting)
		fb := !buf_hide((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) || force
		win_close(wp, fb, force)
	}
}

// :cquit (ex_docmd.c static → export; C NORETURN — getout exits).
@(export)
ex_cquit :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	status: C.int = 1
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		status = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	}
	ui_call_error_exit_e(C.longlong(status))
	getout(C.int(status))
}

// :qall (ex_docmd.c static → export).
@(export)
ex_quitall :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if before_quit_all(eap) == FAIL_E {
		return
	}
	save_exiting := exiting
	exiting = true
	force := ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0
	if force || !check_changed_any_e(false, false) {
		getout(0)
	}
	not_exiting(save_exiting)
}

// —— Batch 29: ex_docmd.c window-close handlers (exports + unstatic) ——
CMD_ONLY_O :: 312
CMD_PCLOSE_O :: 325

// :close (ex_docmd.c static → export).
@(export)
ex_close :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if !text_locked_r() && !curbuf_locked_r() {
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
			ex_win_close(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0], curwin, nil)
		} else {
			winnr: C.int = 0
			win: rawptr = nil
			wp := firstwin
			for wp != nil {
				winnr += 1
				if winnr == ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] {
					win = wp
					break
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			if win == nil {
				win = lastwin_g
			}
			ex_win_close(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0], win, nil)
		}
	}
}

// :pclose (ex_docmd.c static → export).
@(export)
ex_pclose :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	wp := firstwin
	for wp != nil {
		if ([^]C.int)(uintptr(wp) + W_P_PVW_OFF)[0] != 0 {
			ex_win_close(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0], wp, nil)
			break
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// :only (ex_docmd.c static → export).
@(export)
ex_only :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if window_layout_locked(CMD_ONLY_O) {
		return
	}
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		wnr := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		wp := firstwin
		for {
			wnr -= 1
			if wnr <= 0 {
				break
			}
			if (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ == nil {
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if wp != curwin {
			win_goto(wp)
		}
	}
	close_others(1, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0], false)
}

// :hide (ex_docmd.c static → export).
@(export)
ex_hide :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] {
		return
	}
	win: rawptr = nil
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] == 0 {
		win = curwin
	} else {
		winnr: C.int = 0
		wp := firstwin
		for wp != nil {
			winnr += 1
			if winnr == ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] {
				win = wp
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if win == nil {
			win = lastwin_g
		}
	}
	if !(^bool)(uintptr(win) + W_FLOATING_OFF)^ && window_layout_locked(CMD_HIDE_O) {
		return
	}
	win_close(win, false, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0)
}

// —— Batch 30: ex_docmd.c put/copy/join handlers (exports + unstatic) ——
CMD_MOVE_O :: 273

// :put (ex_docmd.c static → export).
@(export)
ex_put :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == 0 {
		([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = 1
		([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] = 1
	}
	([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	check_cursor_col(curwin)
	dir := FORWARD_DIR
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		dir = BACKWARD_DIR
	}
	do_put(([^]C.int)(uintptr(eap) + EXARG_REGNAME_OFF)[0], nil, C.int(dir), 1, PUT_LINE | PUT_CURSLINE)
}

// :iput (ex_docmd.c static → export).
@(export)
ex_iput :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == 0 {
		([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] = 1
		([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] = 1
	}
	([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	check_cursor_col(curwin)
	dir := FORWARD_DIR
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		dir = BACKWARD_DIR
	}
	do_put(([^]C.int)(uintptr(eap) + EXARG_REGNAME_OFF)[0], nil, C.int(dir), 1, PUT_LINE | PUT_CURSLINE | PUT_FIXINDENT)
}

// :copy/:move (ex_docmd.c static → export).
@(export)
ex_copymove :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	errormsg: cstring = nil
	n := get_address(eap, transmute(^cstring)(uintptr(eap) + EXARG_ARG_OFF), ([^]C.int)(uintptr(eap) + EXARG_ADDR_TYPE_OFF)[0], false, false, 0, 1, &errormsg)
	if ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] == nil {
		if errormsg != nil {
			emsg(errormsg)
		}
		([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = nil
		return
	}
	get_flags_o(eap)
	if n == MAXLNUM || n < 0 || n > ([^]C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)[0] {
		emsg(cstring(E16_S))
		return
	}
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_MOVE_O {
		if do_move(([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], n) == FAIL_E {
			return
		}
	} else {
		ex_copy(([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], n)
	}
	u_clearline(curbuf)
	beginline(BL_SOL_FIX)
	ex_may_print(eap)
}

// :join (ex_docmd.c static → export).
@(export)
ex_join :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]
	if ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] == ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] {
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] >= 2 {
			return
		}
		if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == ([^]C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)[0] {
			beep_flush_r()
			return
		}
		([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] += 1
	}
	do_join_r(C.size_t(([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] - ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] + 1), ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] == 0, true, true, true)
	beginline(BL_WHITE | BL_FIX)
	ex_may_print(eap)
}

// —— Batch 31: ex_docmd.c :read handler (export + unstatic) ——
CPO_ALTREAD_O :: 'a'

// :read (ex_docmd.c static → export).
@(export)
ex_read :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	empty := ([^]C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)[0] & ML_EMPTY_O
	if ([^]C.int)(uintptr(eap) + EXARG_USEFILTER_OFF)[0] != 0 {
		do_bang(1, eap, false, false, true)
		return
	}
	if u_save(([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] + 1) == FAIL_E {
		return
	}
	i: C.int
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] == 0 {
		if check_fname_r() == FAIL_E {
			return
		}
		i = readfile_r(transmute(cstring)((^rawptr)(uintptr(curbuf) + B_FFNAME)^), transmute(cstring)((^rawptr)(uintptr(curbuf) + B_FNAME)^), ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], 0, MAXLNUM, eap, 0, false)
	} else {
		if vim_strchr_c(p_cpo, C.int(CPO_ALTREAD_O)) != nil {
			setaltfname(arg, arg, 1)
		}
		i = readfile_r(arg, nil, ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], 0, MAXLNUM, eap, 0, false)
	}
	if i != OK_E {
		if !aborting_r() {
			semsg(cstring(E_NOTOPEN_S), arg)
		}
	} else {
		if empty != 0 && exmode_active {
			lnum: C.int
			if ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == 0 {
				lnum = ([^]C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)[0]
			} else {
				lnum = 1
			}
			if ([^]u8)(ml_get(lnum))[0] == 0 && u_savedel(lnum, 1) == OK_E {
				ml_delete_r(lnum)
				if ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] > 1 && ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] >= lnum {
					([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] -= 1
				}
				deleted_lines_mark_r(lnum, 1)
			}
		}
		redraw_curbuf_later(UPD_VALID_O)
	}
}

// —— Batch 32: ex_docmd.c register-exec + bang + filetype (exports + unstatic) ——
foreign _ {
	@(link_name = "exec_from_reg")
	exec_from_reg_g: bool
}

CPO_EXECBUF_O :: 'e'
E475_S :: "E475: Invalid argument: %s"

// :@r (ex_docmd.c static → export).
@(export)
ex_at :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	prev_len := typebuf.tb_len
	([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	check_cursor_col(curwin)
	c := C.int(([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0])
	if c == 0 {
		c = '@'
	}
	addcr: C.int = 0
	if vim_strchr_c(p_cpo, C.int(CPO_EXECBUF_O)) != nil {
		addcr = 1
	}
	if do_execreg(c, 1, addcr, true) == FAIL_E {
		beep_flush_r()
		return
	}
	save_efr := exec_from_reg_g
	exec_from_reg_g = true
	for !stuff_empty_e() || typebuf.tb_len > prev_len {
		do_cmdline(nil, transmute(LineGetter)(getexline_e), nil, DOCMD_NOWAIT_O | DOCMD_VERBOSE_O)
	}
	exec_from_reg_g = save_efr
}

// :! (ex_docmd.c static → export).
@(export)
ex_bang :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	do_bang(([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0], eap, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, true, true)
}

// :filetype (ex_docmd.c static → export).
@(export)
ex_filetype :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] == 0 {
		on_s := cstring("ON")
		if filetype_detect != 1 {
			on_s = cstring("OFF")
		}
		plug_s := cstring("OFF")
		if filetype_plugin == 1 {
			if filetype_detect == 1 {
				plug_s = cstring("ON")
			} else {
				plug_s = cstring("(on)")
			}
		}
		indent_s := cstring("OFF")
		if filetype_indent == 1 {
			if filetype_detect == 1 {
				indent_s = cstring("ON")
			} else {
				indent_s = cstring("(on)")
			}
		}
		smsg(0, cstring("filetype detection:%s  plugin:%s  indent:%s"), on_s, plug_s, indent_s)
		return
	}
	plugin := false
	indent := false
	for {
		if libc.strncmp(arg, cstring("plugin"), 6) == 0 {
			plugin = true
			arg = skipwhite(transmute(cstring)(uintptr(rawptr(arg)) + 6))
		} else if libc.strncmp(arg, cstring("indent"), 6) == 0 {
			indent = true
			arg = skipwhite(transmute(cstring)(uintptr(rawptr(arg)) + 6))
		} else {
			break
		}
	}
	if libc.strcmp(arg, cstring("on")) == 0 || libc.strcmp(arg, cstring("detect")) == 0 {
		if ([^]u8)(arg)[0] == 'o' || filetype_detect != 1 {
			source_runtime(transmute(^u8)(cstring("filetype.lua filetype.vim")), DIP_ALL)
			filetype_detect = 1
			if plugin {
				source_runtime(transmute(^u8)(cstring("ftplugin.vim")), DIP_ALL)
				filetype_plugin = 1
			}
			if indent {
				source_runtime(transmute(^u8)(cstring("indent.vim")), DIP_ALL)
				filetype_indent = 1
			}
		}
		if ([^]u8)(arg)[0] == 'd' {
			do_doautocmd_r(cstring("filetypedetect BufRead"), true, nil)
			do_modelines(0)
		}
	} else if libc.strcmp(arg, cstring("off")) == 0 {
		if plugin || indent {
			if plugin {
				source_runtime(transmute(^u8)(cstring("ftplugof.vim")), DIP_ALL)
				filetype_plugin = 0
			}
			if indent {
				source_runtime(transmute(^u8)(cstring("indoff.vim")), DIP_ALL)
				filetype_indent = 0
			}
		} else {
			source_runtime(transmute(^u8)(cstring("ftoff.vim")), DIP_ALL)
			filetype_detect = 0
		}
	} else {
		semsg(cstring(E475_S), arg)
	}
}

// —— Batch 33: ex_docmd.c redraw handlers (exports + unstatic) ——

// :nohlsearch (ex_docmd.c static → export).
@(export)
ex_nohlsearch :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	set_no_hlsearch(true)
	redraw_all_later(UPD_SOME_VALID_O)
}

// :redraw (ex_docmd.c static → export).
@(export)
ex_redraw :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if cmdpreview_g {
		return
	}
	r := RedrawingDisabled
	p := p_lz_g
	RedrawingDisabled = 0
	p_lz_g = 0
	validate_cursor_r(curwin)
	update_topline_r(curwin)
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		redraw_all_later(UPD_NOT_VALID)
		redraw_cmdline_g = true
	} else if VIsual_active {
		redraw_curbuf_later(UPD_INVERTED_S)
	}
	update_screen()
	if need_maketitle_opt {
		maketitle()
	}
	RedrawingDisabled = r
	p_lz_g = p
	msg_didout_g = false
	msg_col = 0
	need_wait_return_g = false
	ui_flush()
}

// :redrawstatus (ex_docmd.c static → export).
@(export)
ex_redrawstatus :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if cmdpreview_g {
		return
	}
	r := RedrawingDisabled
	p := p_lz_g
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		status_redraw_all()
	} else {
		status_redraw_curbuf()
	}
	RedrawingDisabled = 0
	p_lz_g = 0
	if (State & MODE_CMDLINE_O) != 0 {
		redraw_statuslines()
	} else {
		if VIsual_active {
			redraw_curbuf_later(UPD_INVERTED_S)
		}
		update_screen()
	}
	RedrawingDisabled = r
	p_lz_g = p
	ui_flush()
}

// :redrawtabline (ex_docmd.c static → export).
@(export)
ex_redrawtabline :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	r := RedrawingDisabled
	p := p_lz_g
	RedrawingDisabled = 0
	p_lz_g = 0
	draw_tabline_r()
	RedrawingDisabled = r
	p_lz_g = p
	ui_flush()
}

// —— Batch 34: ex_docmd.c fold handlers (exports + unstatic) ——
CMD_FOLDOPEN_O :: 166
CMD_FOLDDOCLOSED_O :: 165

// :fold (ex_docmd.c static → export).
@(export)
ex_fold :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if foldManualAllowed(true) != 0 {
		start := Pos_T{([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], 1, 0}
		end := Pos_T{([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], 1, 0}
		foldCreate(curwin, start, end)
	}
}

// :foldopen/:foldclose (ex_docmd.c static → export).
@(export)
ex_foldopen :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	start := Pos_T{([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], 1, 0}
	end := Pos_T{([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], 1, 0}
	opening: C.int = 0
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_FOLDOPEN_O {
		opening = 1
	}
	force: C.int = 0
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		force = 1
	}
	opFoldRange(start, end, opening, force, false)
}

// :folddo/:folddoclosed (ex_docmd.c static → export).
@(export)
ex_folddo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	closed := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_FOLDDOCLOSED_O
	for lnum := ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]; lnum <= ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]; lnum += 1 {
		if hasFolding(curwin, lnum, nil, nil) == closed {
			ml_setmarked_r(lnum)
		}
	}
	global_exe(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
	ml_clearmarked_r()
}

// —— Batch 48: ex_docmd.c autocmd handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "do_autocmd")
	do_autocmd_e :: proc "c" (eap: rawptr, arg_in: cstring, forceit: C.int) ---
	@(link_name = "do_augroup")
	do_augroup_e :: proc "c" (arg: cstring, del_group: bool) ---
	@(link_name = "check_nomodeline")
	check_nomodeline_e :: proc "c" (argp: ^cstring) -> bool ---
}

CMD_AUTOCMD_O :: 17

// :autocmd/:augroup (ex_docmd.c static → export).
@(export)
ex_autocmd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if secure != 0 {
		secure = 2
		([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E12_S)
	} else if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_AUTOCMD_O {
		do_autocmd_e(eap, ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
	} else {
		do_augroup_e(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0)
	}
}

// :doautocmd (ex_docmd.c static → export).
@(export)
ex_doautocmd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	call_do_modelines := check_nomodeline_e(&arg)
	did_aucmd: bool = false
	do_doautocmd_r(arg, false, rawptr(&did_aucmd))
	if call_do_modelines && did_aucmd {
		do_modelines(0)
	}
}

// —— Batch 47: ex_docmd.c detach/connect (exports + unstatic) ——
foreign _ {
	@(link_name = "nvim__chan_set_detach")
	nvim__chan_set_detach_e :: proc "c" (channel_id: u64, detach: bool, err: ^Api_Error) ---
	@(link_name = "remote_ui_disconnect")
	remote_ui_disconnect_e :: proc "c" (channel_id: u64, err: ^Api_Error, send_error_exit: bool) ---
	@(link_name = "remote_ui_connect")
	remote_ui_connect_e :: proc "c" (channel_id: u64, server_addr: cstring, err: ^Api_Error) ---
	@(link_name = "ui_active")
	ui_active_e :: proc "c" () -> C.size_t ---
}

// :detach (ex_docmd.c static → export; MSWIN branch dropped).
@(export)
ex_detach :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if eap != nil && ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		emsg(cstring("bang (!) not supported yet"))
		return
	}
	if current_ui == 0 {
		emsg(cstring("UI not attached"))
		return
	}
	chan := find_channel_o(current_ui)
	if chan == nil {
		emsg(cstring(E900_CHAN_S))
		return
	}
	detach_err: Api_Error = {typ = -1}
	nvim__chan_set_detach_e((^u64)(uintptr(chan) + CHAN_ID_OFF)^, true, &detach_err)
	api_clear_error_r(&detach_err)
	err2: Api_Error = {typ = -1}
	remote_ui_disconnect_e((^u64)(uintptr(chan) + CHAN_ID_OFF)^, &err2, true)
	if err2.typ != -1 {
		emsg(transmute(cstring)(err2.msg))
		api_clear_error_r(&err2)
		return
	}
	err: cstring = nil
	rv := channel_close_e(C.ulonglong((^u64)(uintptr(chan) + CHAN_ID_OFF)^), KCHPART_ALL_O, &err)
	if !rv && err != nil {
		emsg(err)
		return
	}
}

// :connect (ex_docmd.c static → export).
@(export)
ex_connect :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	stop_server := false
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		stop_server = ui_active_e() == 1
	}
	err: Api_Error = {typ = -1}
	remote_ui_connect_e(current_ui, ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], &err)
	if err.typ != -1 {
		emsg(transmute(cstring)(err.msg))
		api_clear_error_r(&err)
		return
	}
	ex_detach(nil)
	if stop_server {
		exiting = true
		getout(0)
	}
}

// —— Batch 49: ex_docmd.c script-NI + shim drops (export + unstatic) ——
foreign _ {
	@(link_name = "script_get")
	script_get_e :: proc "c" (eap: rawptr, lenp: ^C.size_t) -> ^u8 ---
}

// :script not-implemented stub (ex_docmd.c static → export).
@(export)
ex_script_ni :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if !([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] {
		ex_ni(eap)
	} else {
		ln: C.size_t = 0
		xfree(rawptr(script_get_e(eap, &ln)))
	}
}

// —— Batch 43: ex_docmd.c find + operators (exports + unstatic) ——
foreign _ {
	@(link_name = "op_delete")
	op_delete_e :: proc "c" (oap: rawptr) -> C.int ---
	@(link_name = "op_shift")
	op_shift_e :: proc "c" (oap: rawptr, curs_top: bool, amount: C.int) ---
}

CMD_YANK_O :: 550
CMD_DELETE_O :: 109
OP_DELETE_O :: 1
OP_YANK_O :: 2
OP_LSHIFT_O :: 4
OP_RSHIFT_O :: 5
OA_OP_TYPE_OFF :: 0
OA_REGNAME_OFF :: 4
OA_MOTION_TYPE_OFF :: 8
OA_START_OFF :: 20
OA_END_OFF :: 32
OA_LINE_COUNT_OFF :: 60

// :find (ex_docmd.c static → export).
@(export)
ex_find :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if !check_can_set_curbuf_forceit(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0]) {
		return
	}
	fname: ^u8 = nil
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(get_findfunc_e())[0] != 0 {
		cnt := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] <= 0 {
			cnt = 1
		}
		fname = findfunc_find_file_o(arg, libc.strlen(arg), cnt)
	} else {
		file_to_find: rawptr = nil
		search_ctx: rawptr = nil
		bff := (^cstring)(uintptr(curbuf) + B_FFNAME)^
		fname = find_file_in_path_e(arg, libc.strlen(arg), FNAME_MESS, 1, transmute(cstring)(bff), &file_to_find, &search_ctx)
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
			count := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
			for fname != nil {
				count -= 1
				if count <= 0 {
					break
				}
				xfree(rawptr(fname))
				fname = find_file_in_path_e(nil, 0, FNAME_MESS, 0, transmute(cstring)(bff), &file_to_find, &search_ctx)
			}
		}
		xfree(file_to_find)
		vim_findfile_cleanup_e(search_ctx)
	}
	if fname == nil {
		return
	}
	([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = transmute(cstring)(fname)
	do_exedit(eap, nil)
	xfree(rawptr(fname))
}

// :delete/:yank/:shift (ex_docmd.c static → export).
@(export)
ex_operators :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	oa: [88]u8
	clear_oparg_e(rawptr(&oa[0]))
	([^]C.int)(uintptr(rawptr(&oa[0])) + OA_REGNAME_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_REGNAME_OFF)[0]
	([^]C.int)(uintptr(rawptr(&oa[0])) + OA_START_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]
	([^]C.int)(uintptr(rawptr(&oa[0])) + OA_END_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	([^]C.int)(uintptr(rawptr(&oa[0])) + OA_LINE_COUNT_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] - ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] + 1
	([^]C.int)(uintptr(rawptr(&oa[0])) + OA_MOTION_TYPE_OFF)[0] = kMTLineWise
	virtual_op_g = TriState.kFalse
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx != CMD_YANK_O {
		setpcmark()
		([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]
		beginline(BL_SOL_FIX)
	}
	if VIsual_active {
		end_visual_mode_r()
	}
	if cmdidx == CMD_DELETE_O {
		([^]C.int)(uintptr(rawptr(&oa[0])) + OA_OP_TYPE_OFF)[0] = OP_DELETE_O
		op_delete_e(rawptr(&oa[0]))
	} else if cmdidx == CMD_YANK_O {
		([^]C.int)(uintptr(rawptr(&oa[0])) + OA_OP_TYPE_OFF)[0] = OP_YANK_O
		op_yank(rawptr(&oa[0]), true)
	} else {
		rshift := cmdidx == CMD_RSHIFT_O
		if rshift != (([^]C.int)(uintptr(curwin) + W_P_RL_OFF)[0] != 0) {
			([^]C.int)(uintptr(rawptr(&oa[0])) + OA_OP_TYPE_OFF)[0] = OP_RSHIFT_O
		} else {
			([^]C.int)(uintptr(rawptr(&oa[0])) + OA_OP_TYPE_OFF)[0] = OP_LSHIFT_O
		}
		op_shift_e(rawptr(&oa[0]), false, ([^]C.int)(uintptr(eap) + EXARG_AMOUNT_OFF)[0])
	}
}

// —— Batch 41: ex_docmd.c tab-nav handlers (exports + unstatic) ——
CMD_TABFIRST_O :: 461
CMD_TABREWIND_O :: 469
CMD_TABLAST_O :: 463
CMD_TABPREVIOUS_O :: 467
CMD_TABNEXT2_O :: 468
CMD_TABNEXT_O :: 464
CMD_TABMOVE_O :: 462

// Tab-number argument parser (ex_docmd.c static).
get_tabpage_arg_o :: proc "c" (eap: rawptr) -> C.int {
	context = runtime.default_context()
	tab_number: C.int = 0
	unaccept_arg0: C.int = 1
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_TABMOVE_O {
		unaccept_arg0 = 0
	}
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if arg != nil && ([^]u8)(arg)[0] != 0 {
		p := arg
		relative: C.int = 0
		if ([^]u8)(p)[0] == '-' {
			relative = -1
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		} else if ([^]u8)(p)[0] == '+' {
			relative = 1
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		p_save := p
		tab_number = C.int(getdigits(&p, false, C.long(tab_number)))
		if relative == 0 {
			if libc.strcmp(p, cstring("$")) == 0 {
				tab_number = current_tab_nr_o(nil)
			} else if libc.strcmp(p, cstring("#")) == 0 {
				if valid_tabpage(lastused_tabpage_g) {
					tab_number = tabpage_index(lastused_tabpage_g)
				} else {
					([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E475_VAL_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
					tab_number = 0
					return tab_number
				}
			} else if p == p_save || ([^]u8)(p_save)[0] == '-' || ([^]u8)(p)[0] != 0 || tab_number > current_tab_nr_o(nil) {
				([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E475_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
				return tab_number
			}
		} else {
			if ([^]u8)(p_save)[0] == 0 {
				tab_number = 1
			} else if p == p_save || ([^]u8)(p_save)[0] == '-' || ([^]u8)(p)[0] != 0 || tab_number == 0 {
				([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E475_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
				return tab_number
			}
			tab_number = tab_number * relative + tabpage_index(curtab)
			if unaccept_arg0 == 0 && relative == -1 {
				tab_number -= 1
			}
		}
		if tab_number < unaccept_arg0 || tab_number > current_tab_nr_o(nil) {
			([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E475_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
		}
	} else if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		if unaccept_arg0 != 0 && ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] == 0 {
			([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E16_S)
			tab_number = 0
		} else {
			tab_number = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
			if unaccept_arg0 == 0 {
				cmdp := ([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0]
				base := transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_CMDLINEP_OFF)[0])
				for {
					cmdp = transmute(cstring)(uintptr(rawptr(cmdp)) - 1)
					if uintptr(rawptr(cmdp)) <= uintptr(rawptr(base)) {
						break
					}
					cc := ([^]u8)(cmdp)[0]
					if cc != ' ' && cc != '\t' && !ascii_isdigit_o(cc) {
						break
					}
				}
				if ([^]u8)(cmdp)[0] == '-' {
					tab_number -= 1
					if tab_number < unaccept_arg0 {
						([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E16_S)
					}
				}
			}
		}
	} else {
		cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
		if cmdidx == CMD_TABNEXT_O {
			tab_number = tabpage_index(curtab) + 1
			if tab_number > current_tab_nr_o(nil) {
				tab_number = 1
			}
		} else if cmdidx == CMD_TABMOVE_O {
			tab_number = current_tab_nr_o(nil)
		} else {
			tab_number = tabpage_index(curtab)
		}
	}
	return tab_number
}

// :tabnext family (ex_docmd.c static → export).
@(export)
ex_tabnext :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx == CMD_TABFIRST_O || cmdidx == CMD_TABREWIND_O {
		goto_tabpage(1)
	} else if cmdidx == CMD_TABLAST_O {
		goto_tabpage(9999)
	} else if cmdidx == CMD_TABPREVIOUS_O || cmdidx == CMD_TABNEXT2_O {
		arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
		if arg != nil && ([^]u8)(arg)[0] != 0 {
			p := arg
			p_save := p
			tab_number := C.int(getdigits(&p, false, 0))
			if p == p_save || ([^]u8)(p_save)[0] == '-' || ([^]u8)(p_save)[0] == '+' || ([^]u8)(p)[0] != 0 || tab_number == 0 {
				([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E475_S), arg)
				return
			}
			goto_tabpage(-tab_number)
		} else {
			tab_number: C.int = 1
			if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] != 0 {
				tab_number = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
				if tab_number < 1 {
					([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E16_S)
					return
				}
			}
			goto_tabpage(-tab_number)
		}
	} else {
		tab_number := get_tabpage_arg_o(eap)
		if ([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] == nil {
			goto_tabpage(tab_number)
		}
	}
}

// :tabmove (ex_docmd.c static → export).
@(export)
ex_tabmove :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	tab_number := get_tabpage_arg_o(eap)
	if ([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] == nil {
		tabpage_move(tab_number)
	}
}

// —— Batch 39: ex_docmd.c mode/misc handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "set_cursor_for_append_to_line")
	set_cursor_for_append_to_line_e :: proc "c" () ---
	@(link_name = "may_trigger_vim_suspend_resume")
	may_trigger_vim_suspend_resume_e :: proc "c" (suspend: bool) ---
	@(link_name = "ui_call_suspend")
	ui_call_suspend_e :: proc "c" () ---
}

CMD_STARTINSERT_O :: 435
CMD_STARTREPLACE_O :: 437
E359_S :: "E359: Screen mode setting not supported"
E25_S :: "E25: Nvim does not have a built-in GUI"

// :mode (ex_docmd.c static → export).
@(export)
ex_mode :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] == 0 {
		must_redraw = UPD_CLEAR_O
		ex_redraw(eap)
	} else {
		emsg(cstring(E359_S))
	}
}

// Bad-modifier stub (ex_docmd.c static → export).
@(export)
ex_wrongmodifier :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E476_S)
}

// :nogui (ex_docmd.c static → export).
@(export)
ex_nogui :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = cstring(E25_S)
}

// :startinsert (ex_docmd.c static → export).
@(export)
ex_startinsert :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		if ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] == 0 {
			([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = 1
		}
		set_cursor_for_append_to_line_e()
	}
	if (State & MODE_INSERT) != 0 {
		return
	}
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx == CMD_STARTINSERT_O {
		restart_edit = 'a'
	} else if cmdidx == CMD_STARTREPLACE_O {
		restart_edit = 'R'
	} else {
		restart_edit = 'V'
	}
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] == 0 {
		if cmdidx == CMD_STARTINSERT_O {
			restart_edit = 'i'
		}
		([^]C.int)(uintptr(curwin) + W_CURSWANT_OFF)[0] = 0
	}
	if VIsual_active {
		showmode()
	}
}

// :stopinsert (ex_docmd.c static → export).
@(export)
ex_stopinsert :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	restart_edit = 0
	stop_insert_mode_g = true
	clearmode()
}

// :stop (ex_docmd.c static → export; suspend path unprobed headless by design).
@(export)
ex_stop :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] == 0 {
		autowrite_all()
	}
	may_trigger_vim_suspend_resume_e(true)
	ui_call_suspend_e()
	ui_flush()
}

// —— Batch 35: ex_docmd.c undo handlers (exports + unstatic) ——
CMD_EARLIER_O :: 134
E5767_S :: "E5767: Cannot use :undo! to redo or move to a different undo branch"

// :undo (ex_docmd.c static → export).
@(export)
ex_undo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] != 1 {
		if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
			u_undo_and_forget(1, true)
		} else {
			u_undo(1)
		}
		return
	}
	step := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		if step >= ([^]C.int)(uintptr(curbuf) + B_U_SEQ_CUR)[0] {
			emsg(cstring(E5767_S))
			return
		}
		uhp := (^rawptr)(uintptr(curbuf) + B_U_CURHEAD)^
		if uhp == nil {
			uhp = (^rawptr)(uintptr(curbuf) + B_U_NEWHEAD)^
		}
		count: C.int = 0
		for uhp != nil && (^U_Header_T)(uhp).uh_seq > step {
			uhp = (^U_Header_T)(uhp).uh_next
			count += 1
		}
		if step != 0 && (uhp == nil || (^U_Header_T)(uhp).uh_seq < step) {
			emsg(cstring(E5767_S))
			return
		}
		u_undo_and_forget(count, true)
	} else {
		undo_time(step, false, false, true)
	}
}

// :wundo (ex_docmd.c static → export).
@(export)
ex_wundo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	hash: [UNDO_HASH_SIZE]u8
	u_compute_hash(curbuf, &hash[0])
	u_write_undo(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, curbuf, &hash[0])
}

// :rundo (ex_docmd.c static → export).
@(export)
ex_rundo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	hash: [UNDO_HASH_SIZE]u8
	u_compute_hash(curbuf, &hash[0])
	u_read_undo(transmute(^u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]), &hash[0], nil)
}

// :redo (ex_docmd.c static → export).
@(export)
ex_redo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	u_redo(1)
}

// :earlier/:later (ex_docmd.c static → export).
@(export)
ex_later :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	count: C.int = 0
	sec := false
	file := false
	p := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(p)[0] == 0 {
		count = 1
	} else if ascii_isdigit_o(([^]u8)(p)[0]) {
		count = C.int(getdigits(&p, false, 0))
		cc := ([^]u8)(p)[0]
		if cc == 's' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			sec = true
		} else if cc == 'm' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			sec = true
			count *= 60
		} else if cc == 'h' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			sec = true
			count *= 60 * 60
		} else if cc == 'd' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			sec = true
			count *= 24 * 60 * 60
		} else if cc == 'f' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			file = true
		}
	}
	if ([^]u8)(p)[0] != 0 {
		semsg(cstring(E475_S), ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])
	} else {
		n := count
		if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_EARLIER_O {
			n = -count
		}
		undo_time(n, sec, file, false)
	}
}

// —— Batch 36: ex_docmd.c redir handler (export + unstatic) ——
foreign _ {
	@(link_name = "redir_fd")
	redir_fd_g: rawptr
	@(link_name = "redir_vname")
	redir_vname_g: bool
}

// Redirection closer (ex_docmd.c static).
close_redir_o :: proc "c" () {
	context = runtime.default_context()
	if redir_fd_g != nil {
		libc.fclose(transmute(^libc.FILE)(redir_fd_g))
		redir_fd_g = nil
	}
	redir_reg = 0
	if redir_vname_g {
		var_redir_stop()
		redir_vname_g = false
	}
}

// :redir (ex_docmd.c static → export).
@(export)
ex_redir :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	eap_arg := arg
	if _strcasecmp(arg, cstring("END")) == 0 {
		close_redir_o()
	} else if ([^]u8)(arg)[0] == '>' {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
		mode := cstring("w")
		if ([^]u8)(arg)[0] == '>' {
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			mode = cstring("a")
		}
		arg = skipwhite(arg)
		close_redir_o()
		fname := expand_env_save(arg)
		if fname == nil {
			return
		}
		redir_fd_g = open_exfile(transmute(cstring)(fname), ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0], mode)
		xfree(rawptr(fname))
	} else if ([^]u8)(arg)[0] == '@' {
		close_redir_o()
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
		if valid_yank_reg(C.int(([^]u8)(arg)[0]), true) && ([^]u8)(arg)[0] != '_' {
			redir_reg = C.int(([^]u8)(arg)[0])
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			if ([^]u8)(arg)[0] == '>' && ([^]u8)(arg)[1] == '>' {
				arg = transmute(cstring)(uintptr(rawptr(arg)) + 2)
			} else {
				if ([^]u8)(arg)[0] == '>' {
					arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
				}
				if ([^]u8)(arg)[0] == 0 {
					rr := redir_reg
					if !(rr >= 'A' && rr <= 'Z') {
						write_reg_contents(rr, cstring(""), 0, 0)
					}
				}
			}
		}
		if ([^]u8)(arg)[0] != 0 {
			redir_reg = 0
			semsg(cstring(E475_S), eap_arg)
		}
	} else if ([^]u8)(arg)[0] == '=' && ([^]u8)(arg)[1] == '>' {
		close_redir_o()
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 2)
		append := false
		if ([^]u8)(arg)[0] == '>' {
			arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
			append = true
		}
		if var_redir_start(skipwhite(arg), append) == OK_E {
			redir_vname_g = true
		}
	} else {
		semsg(cstring(E475_S), eap_arg)
	}
	if redir_fd_g != nil || redir_reg != 0 || redir_vname_g {
		redir_off_g = false
	}
}

// —— Batch 37: ex_docmd.c :edit handler (export + unstatic) ——

// :edit/:enew/:badd/:balt (ex_docmd.c static → export).
@(export)
ex_edit :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	ffname: cstring = nil
	if cmdidx != CMD_ENEW_O {
		ffname = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	}
	if cmdidx != CMD_BADD_O && cmdidx != CMD_BALT_O && (is_other_file_o(0, ffname) && !check_can_set_curbuf_forceit(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])) {
		return
	}
	if bt_prompt(curbuf) && cmdidx == CMD_EDIT_O && ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] == 0 {
		emsg(cstring("cannot :edit a prompt buffer"))
		return
	}
	do_exedit(eap, nil)
}

// —— Batch 38: ex_docmd.c tag/include handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "do_tag")
	do_tag_e :: proc "c" (eap: rawptr, tag: cstring, type: C.int, count: C.int, forceit: bool, verbose: bool) ---
	@(link_name = "postponed_split_flags")
	postponed_split_flags_g: C.int
}

DT_TAG_O :: 1
DT_POP_O :: 2
DT_NEXT_O :: 3
DT_PREV_O :: 4
DT_FIRST_O :: 5
DT_LAST_O :: 6
DT_SELECT_O :: 7
DT_JUMP_O :: 9
DT_LTAG_O :: 11

// :checkpath (ex_docmd.c static → export).
@(export)
ex_checkpath :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	force := ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0
	action: C.int = ACTION_SHOW_S
	if force {
		action = ACTION_SHOW_ALL_S
	}
	find_pattern_in_path(nil, transmute(Direction)(C.int(0)), 0, false, false, CHECK_PATH_S, 1, action, 1, MAXLNUM, force, false)
}

// :psearch (ex_docmd.c static → export).
@(export)
ex_psearch :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	g_do_tagpreview = C.int(p_pvh_g)
	ex_findpat(eap)
	g_do_tagpreview = 0
}

// :find-like commands (ex_docmd.c static → export).
@(export)
ex_findpat :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	whole := true
	action: C.int
	cmdname := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0])).name
	c2 := ([^]u8)(cmdname)[2]
	if c2 == 'e' {
		if ([^]u8)(cmdname)[0] == 'p' {
			action = ACTION_GOTO_S
		} else {
			action = ACTION_SHOW_S
		}
	} else if c2 == 'i' {
		action = ACTION_SHOW_ALL_S
	} else if c2 == 'u' {
		action = ACTION_GOTO_S
	} else {
		action = ACTION_SPLIT_S
	}
	n: C.int = 1
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ascii_isdigit_o(([^]u8)(arg)[0]) {
		s := arg
		n = C.int(getdigits(&s, false, 0))
		arg = skipwhite(s)
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = arg
	}
	if ([^]u8)(arg)[0] == '/' {
		whole = false
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 1)
		([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] = arg
		mg: C.int = 0
		if magic_isset() {
			mg = 1
		}
		p := skip_regexp_e(transmute(^u8)(arg), '/', mg)
		if ([^]u8)(p)[0] != 0 {
			([^]u8)(p)[0] = 0
			p = transmute(^u8)(uintptr(p) + 1)
			p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
			if ends_excmd(C.int(([^]u8)(p)[0])) == 0 {
				([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = ex_errmsg(cstring(E488_TRAIL_S), transmute(cstring)(p))
			} else {
				([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(check_nextcmd(p))
			}
		}
		arg = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	}
	if !([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] {
		ftype: C.int = FIND_ANY_S
		if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[0] == 'd' {
			ftype = FIND_DEFINE_S
		}
		force := ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0
		find_pattern_in_path(transmute(^u8)(arg), transmute(Direction)(C.int(0)), C.size_t(libc.strlen(arg)), whole, !force, ftype, n, action, ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0], force, false)
	}
}

// :ptag family (ex_docmd.c static → export).
@(export)
ex_ptag :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	g_do_tagpreview = C.int(p_pvh_g)
	cmdname := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0])).name
	ex_tag_cmd_o(eap, transmute(cstring)(uintptr(rawptr(cmdname)) + 1))
}

// :pedit (ex_docmd.c static → export).
@(export)
ex_pedit :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	curwin_save := curwin
	prepare_preview_window_o()
	do_exedit(eap, nil)
	back_to_current_window_o(curwin_save)
}

// :pbuffer (ex_docmd.c static → export).
@(export)
ex_pbuffer :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	curwin_save := curwin
	prepare_preview_window_o()
	do_exbuffer(eap)
	back_to_current_window_o(curwin_save)
}

// Preview-window opener (ex_docmd.c static).
prepare_preview_window_o :: proc "c" () {
	context = runtime.default_context()
	g_do_tagpreview = C.int(p_pvh_g)
	prepare_tagpreview(true)
}

// Preview-window returner (ex_docmd.c static).
back_to_current_window_o :: proc "c" (curwin_save: rawptr) {
	context = runtime.default_context()
	if curwin != curwin_save && win_valid(curwin_save) {
		validate_cursor_r(curwin)
		redraw_later(curwin, UPD_VALID_O)
		win_enter(curwin_save, true)
	}
	g_do_tagpreview = 0
}

// :stag family (ex_docmd.c static → export).
@(export)
ex_stag :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	postponed_split_g = -1
	postponed_split_flags_g = ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_SPLIT_OFF)[0]
	postponed_split_tab_g = ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_TAB_OFF)[0]
	cmdname := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0])).name
	ex_tag_cmd_o(eap, transmute(cstring)(uintptr(rawptr(cmdname)) + 1))
	postponed_split_flags_g = 0
	postponed_split_tab_g = 0
}

// :tag family (ex_docmd.c static → export).
@(export)
ex_tag :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	cmdname := (^CommandDefinition_O)(nvim_odin_cmddef_at_e(([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0])).name
	ex_tag_cmd_o(eap, cmdname)
}

// Tag-command dispatcher (ex_docmd.c static).
ex_tag_cmd_o :: proc "c" (eap: rawptr, name: cstring) {
	context = runtime.default_context()
	cmd: C.int
	c1 := ([^]u8)(name)[1]
	if c1 == 'j' {
		cmd = DT_JUMP_O
	} else if c1 == 's' {
		cmd = DT_SELECT_O
	} else if c1 == 'p' || c1 == 'N' {
		cmd = DT_PREV_O
	} else if c1 == 'n' {
		cmd = DT_NEXT_O
	} else if c1 == 'o' {
		cmd = DT_POP_O
	} else if c1 == 'f' || c1 == 'r' {
		cmd = DT_FIRST_O
	} else if c1 == 'l' {
		cmd = DT_LAST_O
	} else {
		cmd = DT_TAG_O
	}
	if ([^]u8)(name)[0] == 'l' {
		cmd = DT_LTAG_O
	}
	cnt := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] <= 0 {
		cnt = 1
	}
	do_tag_e(eap, ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], cmd, cnt, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, true)
}

// —— Batch 40: ex_docmd.c exit + resize (exports + unstatic) ——
CMD_WQ_O :: 536

// :exit/:xit/:wq (ex_docmd.c static → export).
@(export)
ex_exit :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if text_locked_r() {
		text_locked_msg_r()
		return
	}
	save_exiting := exiting
	force := ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0
	if check_more_o(false, force) == OK_E && only_one_window() {
		exiting = true
	}
	if ((([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_WQ_O || curbufIsChanged()) && do_write(eap) == FAIL_E) || before_quit_autocmds(curwin, false, force) || check_more_o(true, force) == FAIL_E || (only_one_window() && check_changed_any_e(force, false)) {
		not_exiting(save_exiting)
	} else {
		if only_one_window() {
			getout(0)
		}
		not_exiting(save_exiting)
		fb := !buf_hide((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^)
		win_close(curwin, fb, force)
	}
}

// :resize (ex_docmd.c static → export).
@(export)
ex_resize :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	wp := curwin
	if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
		n := ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		wp = firstwin
		for (^rawptr)(uintptr(wp) + W_NEXT_OFF)^ != nil {
			n -= 1
			if n <= 0 {
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	n := C.int(libc.atol(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]))
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if (([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_SPLIT_OFF)[0] & WSP_VERT_O) != 0 {
		if ([^]u8)(arg)[0] == '-' || ([^]u8)(arg)[0] == '+' {
			n += ([^]C.int)(uintptr(wp) + W_WIDTH_OFF)[0]
		} else if n == 0 && ([^]u8)(arg)[0] == 0 {
			n = Columns
		}
		win_setwidth_win(n, wp, true)
	} else {
		if ([^]u8)(arg)[0] == '-' || ([^]u8)(arg)[0] == '+' {
			n += ([^]C.int)(uintptr(wp) + W_HEIGHT_OFF)[0]
		} else if n == 0 && ([^]u8)(arg)[0] == 0 {
			n = Rows - 1
		}
		win_setheight_win(n, wp, true)
	}
}

// —— Batch 42: ex_docmd.c tabs/swapname/popup (exports + unstatic) ——
foreign _ {
	@(link_name = "pum_make_popup")
	pum_make_popup_e :: proc "c" (path_name: cstring, use_mouse_pos: C.int) ---
}

// :tabs (ex_docmd.c static → export).
@(export)
ex_tabs :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	tabcount: C.int = 1
	msg_ext_set_kind(cstring("list_cmd"))
	msg_start()
	msg_scroll = 1
	lastused_win: rawptr = nil
	if valid_tabpage(lastused_tabpage_g) {
		lastused_win = (^rawptr)(uintptr(lastused_tabpage_g) + TP_CURWIN_OFF)^
	}
	tp := first_tabpage
	for tp != nil {
		if got_int {
			break
		}
		if msg_col > 0 {
			msg_putchar('\n')
		}
		libc.snprintf(transmute([^]u8)(&IObuff[0]), C.size_t(IOSIZE_O), cstring("Tab page %d"), tabcount)
		tabcount += 1
		msg_outtrans(transmute(cstring)(&IObuff[0]), HLF_T_U, false)
		os_breakcheck()
		wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if got_int {
				break
			} else if !(^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^ || (^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			msg_putchar('\n')
			mark: u8 = ' '
			if wp == curwin {
				mark = '>'
			} else if wp == lastused_win {
				mark = '#'
			}
			msg_putchar(C.int(mark))
			msg_putchar(' ')
			ch: u8 = ' '
			if bufIsChanged((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
				ch = '+'
			}
			msg_putchar(C.int(ch))
			msg_putchar(' ')
			sp := buf_spname((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^)
			if sp != nil {
				xstrlcpy(transmute(cstring)(&IObuff[0]), transmute(cstring)(sp), C.size_t(IOSIZE_O))
			} else {
				home_replace((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, transmute(cstring)((^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNAME)^), transmute(cstring)(&IObuff[0]), C.size_t(IOSIZE_O), true)
			}
			msg_outtrans(transmute(cstring)(&IObuff[0]), 0, false)
			os_breakcheck()
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// :swapname (ex_docmd.c static → export).
@(export)
ex_swapname :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	mfp := (^rawptr)(uintptr(curbuf) + B_ML_MFP_OFF)^
	if mfp == nil || (^rawptr)(uintptr(mfp))^ == nil {
		msg_msg(cstring("No swap file"), 0)
	} else {
		msg_msg(transmute(cstring)((^rawptr)(uintptr(mfp))^), 0)
	}
}

// :popup (ex_docmd.c static → export).
@(export)
ex_popup :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	pum_make_popup_e(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
}

// —— Batch 44: ex_docmd.c syncbind/colorscheme/highlight (exports + unstatic) ——
foreign _ {
	@(link_name = "get_vtopline")
	get_vtopline_e :: proc "c" (wp: rawptr) -> C.int ---
	@(link_name = "scrollup")
	scrollup_e :: proc "c" (wp: rawptr, line_count: C.int, byfold: bool) -> bool ---
	@(link_name = "scrolldown")
	scrolldown_e :: proc "c" (wp: rawptr, line_count: C.int, byfold: C.int) -> bool ---
	@(link_name = "cursor_correct")
	cursor_correct_e :: proc "c" (wp: rawptr) ---
	@(link_name = "did_syncbind")
	did_syncbind_g: bool
	@(link_name = "load_colors")
	load_colors_e :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "do_highlight")
	do_highlight_e :: proc "c" (line: cstring, forceit: bool, init: bool) ---
}

CTRL_O_O :: 15
E185_S :: "E185: Cannot find color scheme '%s'"

// :syncbind (ex_docmd.c static → export).
@(export)
ex_syncbind :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	old_linenr := ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0]
	setpcmark()
	vtopline: C.int
	if (^bool)(uintptr(curwin) + W_P_SCB_OFF)^ {
		vtopline = get_vtopline_e(curwin)
		wp := firstwin
		for wp != nil {
			if (^bool)(uintptr(wp) + W_P_SCB_OFF)^ && (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != nil {
				y := plines_m_win_fill_r(wp, 1, ([^]C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)[0]) - C.int(get_scrolloff_value(curwin))
				if y < vtopline {
					vtopline = y
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if vtopline < 1 {
			vtopline = 1
		}
	} else {
		vtopline = 1
	}
	wp := firstwin
	for wp != nil {
		if (^bool)(uintptr(wp) + W_P_SCB_OFF)^ {
			y := vtopline - get_vtopline_e(wp)
			if y > 0 {
				scrollup_e(wp, y, true)
			} else {
				scrolldown_e(wp, -y, 1)
			}
			([^]C.int)(uintptr(wp) + W_SCBIND_POS_OFF)[0] = vtopline
			redraw_later(wp, UPD_VALID_O)
			cursor_correct_e(wp)
			([^]bool)(uintptr(wp) + W_REDR_STATUS_OFF)[0] = true
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if (^bool)(uintptr(curwin) + W_P_SCB_OFF)^ {
		did_syncbind_g = true
		checkpcmark()
		if old_linenr != ([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] {
			ctrl_o: [2]u8
			ctrl_o[0] = CTRL_O_O
			ctrl_o[1] = 0
			ins_typebuf_r(&ctrl_o[0], REMAP_NONE, 0, true, false)
		}
	}
}

// :colorscheme (ex_docmd.c static → export).
@(export)
ex_colorscheme :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] == 0 {
		expr := xstrdup(transmute(^u8)(cstring("g:colors_name")))
		emsg_off += 1
		p := eval_to_string(transmute(cstring)(expr), false, false)
		emsg_off -= 1
		xfree(rawptr(expr))
		msg_ext_set_kind(cstring("list_cmd"))
		if p != nil {
			msg_msg(p, 0)
			xfree(rawptr(p))
		} else {
			msg_msg(cstring("default"), 0)
		}
	} else if load_colors_e(arg) == FAIL_E {
		semsg(cstring(E185_S), arg)
	}
}

// :highlight (ex_docmd.c static → export).
@(export)
ex_highlight :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] == 0 && ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_CMD_OFF)[0])[2] == '!' {
		msg_msg(cstring("Greetings, Vim user!"), 0)
	}
	do_highlight_e(arg, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, false)
}

// —— Batch 45: ex_docmd.c :normal handler (export + unstatic) ——
foreign _ {
	@(link_name = "p_mmd")
	p_mmd_g: C.longlong
}

E523_S :: "E523: Not allowed here"
E192_S :: "E192: Recursive use of :normal too deep"

// :normal (ex_docmd.c static → export).
@(export)
ex_normal :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil && (State & MODE_TERMINAL_O) != 0 {
		emsg(cstring("Can't re-enter normal mode from terminal mode"))
		return
	}
	arg: ^u8 = nil
	if expr_map_locked() {
		emsg(cstring(E523_S))
		return
	}
	if C.longlong(ex_normal_busy_g) >= p_mmd_g {
		emsg(cstring(E192_S))
		return
	}
	{
		length: C.int = 0
		p := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
		for ([^]u8)(p)[0] != 0 {
			l := C.int(utfc_ptr2len(transmute(cstring)(p))) - 1
			for l > 0 {
				l -= 1
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
				if ([^]u8)(p)[0] == K_SPECIAL_INPUT {
					length += 2
				}
			}
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		if length > 0 {
			arg = transmute(^u8)(xmalloc(C.size_t(libc.strlen(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])) + C.size_t(length) + 1))
			length = 0
			p = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
			for ([^]u8)(p)[0] != 0 {
				([^]u8)(arg)[uintptr(length)] = ([^]u8)(p)[0]
				length += 1
				l := C.int(utfc_ptr2len(transmute(cstring)(p))) - 1
				for l > 0 {
					l -= 1
					p = transmute(cstring)(uintptr(rawptr(p)) + 1)
					([^]u8)(arg)[uintptr(length)] = ([^]u8)(p)[0]
					length += 1
					if ([^]u8)(p)[0] == K_SPECIAL_INPUT {
						([^]u8)(arg)[uintptr(length)] = KS_SPECIAL
						length += 1
						([^]u8)(arg)[uintptr(length)] = KE_FILLER
						length += 1
					}
				}
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
			([^]u8)(arg)[uintptr(length)] = 0
		}
	}
	ex_normal_busy_g += 1
	save_state: [224]u8
	if save_current_state(rawptr(&save_state[0])) {
		for {
			if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] != 0 {
				([^]C.int)(uintptr(curwin) + W_CURSOR_OFF)[0] = ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0]
				([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] += 1
				([^]C.int)(uintptr(curwin) + W_CURSOR_COL_OFF)[0] = 0
				check_cursor_moved_e(curwin)
			}
			cmd_arg: cstring = ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
			if arg != nil {
				cmd_arg = transmute(cstring)(arg)
			}
			remap: C.int = REMAP_YES
			if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
				remap = REMAP_NONE
			}
			exec_normal_cmd(cmd_arg, remap, false)
			if !(([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 && ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0] <= ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0] && !got_int) {
				break
			}
		}
	}
	update_topline_cursor()
	restore_current_state(rawptr(&save_state[0]))
	ex_normal_busy_g -= 1
	setmouse()
	ui_cursor_shape_r()
	xfree(rawptr(arg))
}

// —— Batch 46: ex_docmd.c digraph/shada/lua-shim handlers (exports + unstatic) ——
foreign _ {
	@(link_name = "shada_write_file")
	shada_write_file_e :: proc "c" (file: cstring, nomerge: bool) -> C.int ---
}

CMD_RVIMINFO_O :: 384
CMD_RSHADA_O :: 378
E91_S :: "E91: 'shell' option is empty"

// :digraphs (ex_docmd.c static → export).
@(export)
ex_digraphs :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if ([^]u8)(arg)[0] != 0 {
		putdigraph(transmute(^u8)(arg))
	} else {
		listdigraphs(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0)
	}
}

// :shada/:rshada (ex_docmd.c static → export).
@(export)
ex_shada :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	save_shada := p_shada_g
	if ([^]u8)(p_shada_g)[0] == 0 {
		p_shada_g = transmute(^u8)(cstring("'100"))
	}
	cmdidx := ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0]
	if cmdidx == CMD_RVIMINFO_O || cmdidx == CMD_RSHADA_O {
		shada_read_everything(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, false)
	} else {
		shada_write_file_e(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0], ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0)
	}
	p_shada_g = save_shada
}

// :terminal (ex_docmd.c static → export).
@(export)
ex_terminal :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	save_scroll := msg_scroll
	msg_scroll = 0
	autowrite_all()
	msg_scroll = save_scroll
	if ([^]u8)(([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0])[0] != 0 {
		nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_terminal"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
	} else {
		if ([^]u8)(p_sh)[0] == 0 {
			emsg(cstring(E91_S))
			return
		}
		argv := shell_build_argv(nil, nil)
		shell_tv: Typval
		tv_list_alloc_ret(&shell_tv, 0)
		lst := transmute(rawptr)(shell_tv.vval)
		i := 0
		for ([^]^u8)(argv)[i] != nil {
			tv_list_append_allocated_string(lst, ([^]^u8)(argv)[i])
			i += 1
		}
		xfree(rawptr(argv))
		nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_terminal"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), rawptr(&shell_tv))
		tv_clear(transmute(^Typval_T)(&shell_tv))
	}
}

// :log (ex_docmd.c static → export).
@(export)
ex_log :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_log"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
}

// :lsp (ex_docmd.c static → export).
@(export)
ex_lsp :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_lsp"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
}

// :packdel (ex_docmd.c static → export).
@(export)
ex_packdel :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_packdel"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
}

// :packupdate (ex_docmd.c static → export).
@(export)
ex_packupdate :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_packupdate"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
}

// —— Batch 50: ex_docmd.c fclose + setfiletype (exports + unstatic) ——
// (win_float_remove — PORTED (winfloat.odin).)

// :fclose (ex_docmd.c static → export).
@(export)
ex_fclose :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	win_float_remove(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0, ([^]C.int)(uintptr(eap) + EXARG_LINE1_OFF)[0])
}

// :setfiletype (ex_docmd.c static → export).
@(export)
ex_setfiletype :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^bool)(uintptr(curbuf) + B_DID_FILETYPE_OFF)^ {
		return
	}
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if libc.strncmp(arg, cstring("FALLBACK "), 9) == 0 {
		arg = transmute(cstring)(uintptr(rawptr(arg)) + 9)
	}
	set_option_value_give_err(kOptFiletype_E, str_optval(transmute(^u8)(arg), libc.strlen(arg)), OPT_LOCAL_S)
	if arg != ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0] {
		(^bool)(uintptr(curbuf) + B_DID_FILETYPE_OFF)^ = false
	}
}

// —— Batch 51: ex_docmd.c sleep/recover/uptime (exports + unstatic) ——
foreign _ {
	@(link_name = "cursor_valid")
	cursor_valid_e :: proc "c" (wp: rawptr) -> C.int ---
}

// :sleep (ex_docmd.c static → export).
@(export)
ex_sleep :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if cursor_valid_e(curwin) != 0 {
		setcursor_mayforce(curwin, true)
	}
	length := C.longlong(([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0])
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	c0 := ([^]u8)(arg)[0]
	if c0 == 'm' {
	} else if c0 == 0 {
		length *= 1000
	} else {
		semsg(cstring(E475_S), arg)
		return
	}
	do_sleep(length, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0)
}

// :recover (ex_docmd.c static → export).
@(export)
ex_recover :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	recoverymode = true
	ccgd: C.int = CCGD_MULTWIN_O | CCGD_EXCMD_O
	if p_awa != 0 {
		ccgd |= CCGD_AW_O
	}
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] != 0 {
		ccgd |= CCGD_FORCEIT_O
	}
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if !check_changed_r(curbuf, ccgd) && (([^]u8)(arg)[0] == 0 || setfname(curbuf, arg, nil, true) == OK_E) {
		ml_recover_r(true)
	}
	recoverymode = false
}

// :uptime (ex_docmd.c static → export).
@(export)
ex_uptime :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	nlua_call_excmd_r(cstring("vim._core.ex_cmd"), cstring("ex_uptime"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
}

// —— Batch 55: ex_docmd.c restart engine (export + unstatic, Linux-only) ——
foreign _ {
	@(link_name = "ui_call_restart")
	ui_call_restart_e :: proc "c" (addr: NvimString) ---
	@(link_name = "nvim_command")
	nvim_command_e :: proc "c" (cmd: NvimString, err: ^Api_Error) ---
}

// :restart (ex_docmd.c static → export).
@(export)
ex_restart :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0] == 0 {
		d := tv_dict_alloc()
		qc := cstring("")
		if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
			qc = transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0])
		}
		tv_dict_add_str(d, cstring("quit_cmd"), 8, qc)
		extra_tv := Typval_T{v_type = VAR_DICT, v_lock = 0, vval = rawptr(d)}
		nlua_call_excmd_r(cstring("vim._core.server"), cstring("ex_session_restart"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), rawptr(&extra_tv))
		tv_clear(&extra_tv)
		return
	}
	startreason := cstring("restart!")
	qc2: cstring = cstring("qall")
	if ([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0] != nil {
		qc2 = transmute(cstring)(([^]rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)[0])
	}
	after_cmd := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if strequal(qc2, cstring(":::")) {
		startreason = cstring("restart")
		argc := ([^]C.int)(uintptr(eap) + EXARG_ARGC_OFF)[0]
		args := (^rawptr)(uintptr(eap) + EXARG_ARGS_OFF)^
		arglens := (^rawptr)(uintptr(eap) + EXARG_ARGLENS_OFF)^
		if argc > 1 {
			([^]u8)(([^]cstring)(args)[1])[([^]C.size_t)(arglens)[1]] = 0
			qc2 = ([^]cstring)(args)[1]
			if argc > 2 {
				after_cmd = ([^]cstring)(args)[2]
			} else {
				after_cmd = cstring("")
			}
		} else {
			emsg(cstring("restart failed: +cmd did not quit the server"))
			return
		}
	}
	err: Api_Error = {typ = -1}
	no_ui := ui_active_e() == 0
	exepath := get_vim_var_str(VV_PROGPATH)
	l := get_vim_var_list(VV_ARGV_O)
	argc := tv_list_len_o(l)
	argv := xcalloc(C.size_t(argc) + 3, 8)
	i: C.size_t = 0
	listen_arg: cstring = nil
	li := (^rawptr)(uintptr(l))^
	for li != nil {
		next_li := (^rawptr)(uintptr(li))^
		arg := tv_get_string((^Typval_T)(uintptr(li) + 16))
		if i > 0 && strequal(arg, cstring("--")) {
			break
		}
		if i > 0 && strequal(arg, cstring("-S")) {
			if next_li != nil {
				next_arg := tv_get_string((^Typval_T)(uintptr(next_li) + 16))
				if ([^]u8)(next_arg)[0] != '-' {
					next_li = (^rawptr)(uintptr(next_li))^
				}
			}
			li = next_li
			continue
		}
		if i > 0 && strequal(arg, cstring("-s")) {
			li = next_li
			continue
		}
		if i > 0 && strequal(arg, cstring("--listen")) {
			if next_li != nil {
				addr := tv_get_string((^Typval_T)(uintptr(next_li) + 16))
				if strstr_c(addr, cstring(":")) != nil || strstr_c(addr, cstring("/")) != nil || strstr_c(addr, cstring("\\")) != nil {
					listen_arg = addr
				}
			}
		}
		if i == 0 || (!strequal(arg, cstring("--embed")) && !strequal(arg, cstring("--headless")) && !strequal(arg, cstring("-"))) {
			([^]cstring)(argv)[i] = transmute(cstring)(xstrdup(transmute(^u8)(arg)))
			i += 1
			if i == 1 {
				([^]cstring)(argv)[i] = cstring("--embed")
				i += 1
				if no_ui {
					([^]cstring)(argv)[i] = cstring("--headless")
					i += 1
				}
			}
		}
		li = next_li
	}
	server_stopped := false
	if listen_arg != nil {
		server_stopped = server_stop_e(listen_arg, true)
	}
	env := create_environment(nil, false, false, false, nil)
	tv_dict_add_str(env, cstring(ENV_STARTREASON_O), libc.strlen(cstring(ENV_STARTREASON_O)), startreason)
	on_err := CallbackReader_E{}
	on_err.fwd_err = true
	exit_status: C.longlong = 0
	channel := channel_job_start_e(argv, exepath, CallbackReader_E{}, on_err, Callback_E{}, false, true, true, true, KCHSTDIN_PIPE_O, nil, 0, 0, env, rawptr(&exit_status))
	failed := false
	if channel == nil {
		emsg(cstring("cannot create a channel job"))
		failed = true
	}
	result_mem: rawptr = nil
	if !failed {
		detach_items: [1]Api_Object
		detach_items[0].t = 1
		detach_items[0].data[0] = 1
		detach_args := Api_Array{size = 1, capacity = 1, items = &detach_items[0]}
		rpc_send_call_e(C.ulonglong((^u64)(uintptr(channel) + CHAN_ID_OFF)^), cstring("nvim__chan_set_detach"), detach_args, &result_mem, rawptr(&err))
		if err.typ != -1 {
			failed = true
		} else {
			arena_mem_free(result_mem)
			result_mem = nil
		}
	}
	if !failed && ([^]u8)(after_cmd)[0] != 0 {
		pairs: [3]Key_Value_Pair
		pairs[0].key = Api_String{data = transmute(^u8)(cstring("once")), size = 4}
		pairs[0].value.t = 1
		pairs[0].value.data[0] = 1
		pairs[1].key = Api_String{data = transmute(^u8)(cstring("nested")), size = 6}
		pairs[1].value.t = 1
		pairs[1].value.data[0] = 1
		pairs[2].key = Api_String{data = transmute(^u8)(cstring("command")), size = 7}
		pairs[2].value.t = 4
		(^Api_String)(&pairs[2].value.data[0])^ = Api_String{data = transmute(^u8)(after_cmd), size = C.size_t(libc.strlen(after_cmd))}
		opts_dict := Api_Dict{size = 3, capacity = 3, items = &pairs[0]}
		ac_items: [2]Api_Object
		ac_items[0].t = 4
		(^Api_String)(&ac_items[0].data[0])^ = Api_String{data = transmute(^u8)(cstring("UIEnter")), size = 7}
		ac_items[1].t = 6
		(^Api_Dict)(&ac_items[1].data[0])^ = opts_dict
		ac_args := Api_Array{size = 2, capacity = 2, items = &ac_items[0]}
		rpc_send_call_e(C.ulonglong((^u64)(uintptr(channel) + CHAN_ID_OFF)^), cstring("nvim_create_autocmd"), ac_args, &result_mem, rawptr(&err))
		if err.typ != -1 {
			failed = true
		} else {
			arena_mem_free(result_mem)
			result_mem = nil
		}
	}
	if !failed {
		sn_items: [1]Api_Object
		sn_items[0].t = 4
		(^Api_String)(&sn_items[0].data[0])^ = Api_String{data = transmute(^u8)(cstring("servername")), size = 10}
		sn_args := Api_Array{size = 1, capacity = 1, items = &sn_items[0]}
		result := rpc_send_call_e(C.ulonglong((^u64)(uintptr(channel) + CHAN_ID_OFF)^), cstring("nvim_get_vvar"), sn_args, &result_mem, rawptr(&err))
		if err.typ != -1 {
			failed = true
		} else {
			rs := (^Api_String)(&result.data[0])^
			if result.t != 4 || rs.size == 0 {
				emsg(cstring("restart failed: could not get listen address from new server"))
				failed = true
			} else {
				listen_addr := xmemdupz(rawptr(rs.data), C.size_t(rs.size))
				arena_mem_free(result_mem)
				result_mem = nil
				ui_call_restart_e(NvimString{data = transmute(cstring)(listen_addr), size = C.size_t(rs.size)})
				ui_flush()
				xfree(rawptr(listen_addr))
				set_vim_var_string(VV_EXITREASON_O, cstring("restart"), 7)
				quit_cmd_copy: ^u8 = nil
				qc_final := qc2
				if (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0 {
					quit_cmd_copy = concat_str_c(cstring("confirm "), qc2)
					qc_final = transmute(cstring)(quit_cmd_copy)
				}
				nvim_command_e(NvimString{data = qc_final, size = C.size_t(libc.strlen(qc_final))}, &err)
				xfree(rawptr(quit_cmd_copy))
				if err.typ != -1 {
					emsg(transmute(cstring)(err.msg))
					api_clear_error_r(&err)
				} else if !exiting {
					emsg(cstring("restart failed: +cmd did not quit the server"))
				}
			}
		}
	}
	if failed {
		set_vim_var_string(VV_EXITREASON_O, nil, -1)
		if err.typ != -1 {
			emsg(transmute(cstring)(err.msg))
			api_clear_error_r(&err)
		}
	}
	arena_mem_free(result_mem)
	result_mem = nil
	cc_items: [1]Api_Object
	cc_items[0].t = 4
	(^Api_String)(&cc_items[0].data[0])^ = Api_String{data = transmute(^u8)(cstring("chanclose(v:stderr)")), size = 19}
	cc_args := Api_Array{size = 1, capacity = 1, items = &cc_items[0]}
	rpc_send_call_e(C.ulonglong((^u64)(uintptr(channel) + CHAN_ID_OFF)^), cstring("nvim_eval"), cc_args, &result_mem, rawptr(&err))
	api_clear_error_r(&err)
	arena_mem_free(result_mem)
	pr := transmute(^Proc)(uintptr(channel) + 32)
	proc_stop(pr)
	if proc_wait(pr, -1, nil) < 0 {
		emsg(cstring("killing new nvim server failed"))
	}
	if server_stopped && server_start_e(listen_arg) != 0 {
		semsg(cstring("couldn't resume listening on %s"), listen_arg)
	}
}

// —— Batch 52: ex_docmd.c wincmd + checkhealth (exports + unstatic) ——
CTRL_G_O :: 7
E5009_EMPTY_S :: "E5009: $VIMRUNTIME is empty or unset"
E5009_INVALID_S :: "E5009: Invalid $VIMRUNTIME: %s"
E5009_RTP_S :: "E5009: Invalid 'runtimepath'"

// :wincmd (ex_docmd.c static → export).
@(export)
ex_wincmd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	xchar: C.int = 0
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	p: cstring
	if ([^]u8)(arg)[0] == 'g' || ([^]u8)(arg)[0] == CTRL_G_O {
		if ([^]u8)(arg)[1] == 0 {
			emsg(cstring(e_invarg_s))
			return
		}
		xchar = C.int(([^]u8)(arg)[1])
		p = transmute(cstring)(uintptr(rawptr(arg)) + 2)
	} else {
		p = transmute(cstring)(uintptr(rawptr(arg)) + 1)
	}
	([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = rawptr(check_nextcmd(transmute(^u8)(p)))
	p = skipwhite(p)
	if ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' && ([^]rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] == nil {
		emsg(cstring(e_invarg_s))
	} else if !([^]bool)(uintptr(eap) + EXARG_SKIP_OFF)[0] {
		postponed_split_flags_g = ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_SPLIT_OFF)[0]
		postponed_split_tab_g = ([^]C.int)(uintptr(transmute(rawptr)(&cmdmod_cmod_flags)) + CMOD_TAB_OFF)[0]
		prenum: C.int = 0
		if ([^]C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)[0] > 0 {
			prenum = ([^]C.int)(uintptr(eap) + EXARG_LINE2_OFF)[0]
		}
		do_window(C.int(([^]u8)(arg)[0]), prenum, xchar)
		postponed_split_flags_g = 0
		postponed_split_tab_g = 0
	}
}

// :checkhealth (ex_docmd.c static → export).
@(export)
ex_checkhealth :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	emsg_off += 1
	ok := nlua_call_excmd_r(cstring("vim.health"), cstring("_check"), eap, rawptr(transmute(^C.int)(&cmdmod_cmod_flags)), nil)
	emsg_off -= 1
	if ok {
		return
	}
	vimruntime_env := os_getenv_noalloc(cstring("VIMRUNTIME"))
	if vimruntime_env == nil {
		emsg(cstring(E5009_EMPTY_S))
	} else {
		if strstr_c(transmute(cstring)(p_rtp_g), vimruntime_env) != nil {
			semsg(cstring(E5009_INVALID_S), vimruntime_env)
		} else {
			emsg(cstring(E5009_RTP_S))
		}
	}
}

// —— Batch 53: ex_docmd.c tabclose/tabonly (exports + unstatic) ——

// :tabclose (ex_docmd.c static → export).
@(export)
ex_tabclose :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil {
		emsg(cstring(E784_S))
		return
	}
	if window_layout_locked(CMD_TABCLOSE_O) {
		return
	}
	tab_number := get_tabpage_arg_o(eap)
	if ([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] != nil {
		return
	}
	tp := find_tabpage(tab_number)
	if tp == nil {
		beep_flush_r()
		return
	}
	if tp != curtab {
		tabpage_close_other(tp, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
	} else if !text_locked_r() && !curbuf_locked_r() {
		tabpage_close(([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
	}
}

// :tabonly (ex_docmd.c static → export).
@(export)
ex_tabonly :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil {
		msg_msg(cstring("Already only one tab page"), 0)
		return
	}
	if window_layout_locked(CMD_TABONLY_O) {
		return
	}
	tab_number := get_tabpage_arg_o(eap)
	if ([^]cstring)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] != nil {
		return
	}
	goto_tabpage(tab_number)
	done: C.int = 0
	for done < 1000 {
		tp := first_tabpage
		for tp != nil {
			if (^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^ != topframe_g {
				tabpage_close_other(tp, ([^]C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)[0])
				if valid_tabpage(tp) {
					done = 1000
				}
				break
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		if first_tabpage == nil {
			libc.abort()
		}
		if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ == nil {
			break
		}
		done += 1
	}
}

// —— Batch 54: ex_docmd.c submagic pair (exports + unstatic) ——
OPTION_MAGIC_ON_O :: 1
OPTION_MAGIC_OFF_O :: 2

// :smagic/:snomagic (ex_docmd.c static → export).
@(export)
ex_submagic :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	saved := magic_overruled_g
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_SMAGIC_O {
		magic_overruled_g = OPTION_MAGIC_ON_O
	} else {
		magic_overruled_g = OPTION_MAGIC_OFF_O
	}
	ex_substitute(eap)
	magic_overruled_g = saved
}

// :smagic/:snomagic preview (ex_docmd.c static → export).
@(export)
ex_submagic_preview :: proc "c" (eap: rawptr, cmdpreview_ns: C.int, cmdpreview_bufnr: C.int) -> C.int {
	context = runtime.default_context()
	saved := magic_overruled_g
	if ([^]C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)[0] == CMD_SMAGIC_O {
		magic_overruled_g = OPTION_MAGIC_ON_O
	} else {
		magic_overruled_g = OPTION_MAGIC_OFF_O
	}
	retv := ex_substitute_preview(eap, cmdpreview_ns, cmdpreview_bufnr)
	magic_overruled_g = saved
	return retv
}

// —— Batch 56: ex_docmd.c winsize (export + unstatic; LAST handler) ——
E465_S :: "E465: :winsize requires two number arguments"

// :winsize (obsolete; ex_docmd.c static → export).
@(export)
ex_winsize :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := ([^]cstring)(uintptr(eap) + EXARG_ARG_OFF)[0]
	if !ascii_isdigit_o(([^]u8)(arg)[0]) {
		semsg(cstring(E475_S), arg)
		return
	}
	s := arg
	w := C.int(getdigits(&s, false, 10))
	arg = skipwhite(s)
	p := arg
	s = arg
	h := C.int(getdigits(&s, false, 10))
	arg = s
	if ([^]u8)(p)[0] != 0 && ([^]u8)(arg)[0] == 0 {
		screen_resize(w, h)
	} else {
		emsg(cstring(E465_S))
	}
}
