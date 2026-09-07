// ex_docmd.odin — port of src/nvim/ex_docmd.c (:edit command path: do_exedit)
package main

import C "core:c"
import "core:c/libc"

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

// ex_docmd.c static: set for an empty command line (no FFI possible).
@(private="file")
ex_pressedreturn_f: bool

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
		ex_pressedreturn_f = false
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
				msg_scroll = false
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
			do_cmdline_cmd_r(cstring(transmute(^u8)(do_ecmd_cmd)))
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
