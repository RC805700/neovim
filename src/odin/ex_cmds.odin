// ex_cmds.odin — port of src/nvim/ex_cmds.c (edit-command engine: do_ecmd)
package main

import C "core:c"
import "core:c/libc"

// ── Batch 24: do_ecmd + set_swapcommand/delbuf_msg ──────────────────────────
// (ECMD_LASTL/HIDE/ONE/FORCEIT live in window.odin/buffer.odin — reused.)

ECMD_SET_HELP_O :: 0x02
ECMD_OLDBUF_O :: 0x04
ECMD_ADDBUF_O :: 0x10
ECMD_ALTBUF_O :: 0x20
ECMD_NOWINENTER_O :: 0x40
ECMD_LAST_O :: -1
CCGD_AW_O :: 1
CCGD_MULTWIN_O :: 2
CCGD_FORCEIT_O :: 4
CCGD_EXCMD_O :: 16
EXARG_DO_ECMD_CMD_OFF :: 104
W_SCBIND_POS_OFF :: 4256
READ_KEEP_UNDO_O :: 0x20
DOCMD_VERBOSE_O :: 0x01
SHM_OVERALL_O :: C.int('O')
// E1546_S already in buffer.odin — reuse.
E143_S :: "E143: Autocommands unexpectedly deleted new buffer %s"

foreign _ {
	@(link_name = "check_changed")
	check_changed_r :: proc "c"(buf: rawptr, flags: C.int) -> bool ---
	@(link_name = "reset_VIsual")
	reset_VIsual_r :: proc "c"() ---
	@(link_name = "set_file_options")
	set_file_options_r :: proc "c"(set_options: bool, eap: rawptr) ---
	@(link_name = "set_forced_fenc")
	set_forced_fenc_r :: proc "c"(eap: rawptr) ---
	@(link_name = "prepare_help_buffer")
	prepare_help_buffer_r :: proc "c"() ---
	@(link_name = "should_abort")
	should_abort_r :: proc "c"(retcode: C.int) -> bool ---
	@(link_name = "plines_m_win_fill")
	plines_m_win_fill_r :: proc "c"(wp: rawptr, first: C.int, last: C.int) -> C.int ---
	@(link_name = "msg_check_for_delay")
	msg_check_for_delay_r :: proc "c"(canwait: bool) ---
	@(link_name = "diff_invalidate")
	diff_invalidate_r :: proc "c"(buf: rawptr) ---
	@(link_name = "do_cmdline")
	do_cmdline_r :: proc "c"(cmdline: cstring, fgetline: rawptr, cookie: rawptr, flags: C.int) -> C.int ---
	@(link_name = "p_ur")
	p_ur_g: C.longlong
	@(link_name = "keep_help_flag")
	keep_help_flag_g: bool
	@(link_name = "skip_redraw")
	skip_redraw_g: bool
	@(link_name = "msg_listdo_overwrite")
	msg_listdo_overwrite_g: C.int
	@(link_name = "msg_scrolled_ign")
	msg_scrolled_ign_g: bool
}

// Set v:swapcommand for SwapExists autocommands ([+cmd] / newlnum "G").
@(export)
set_swapcommand :: proc "c"(command: ^u8, newlnum: C.int) -> bool {
	if (command == nil && newlnum <= 0) ||
		(^u8)(get_vim_var_str(VV_SWAPCOMMAND))^ != 0 {
		return false
	}
	valsize := C.size_t(30)
	if command != nil {
		valsize = C.size_t(libc.strlen(cstring(command))) + 3
	}
	data := (^u8)(xmalloc(valsize))
	size: C.size_t
	if command != nil {
		size = C.size_t(libc.snprintf(data, valsize, cstring(":%s\r"),
			cstring(command)))
	} else {
		size = C.size_t(libc.snprintf(data, valsize, cstring("%ldG"),
			C.longlong(newlnum)))
	}
	set_vim_var_string(VV_SWAPCOMMAND, cstring(data), C.ssize_t(size))
	xfree(data)
	return true
}

// Report a new buffer deleted by autocommands (C static in ex_cmds.c).
delbuf_msg_o :: proc "c"(name: ^u8) {
	if name == nil {
		semsg_safe(cstring(E143_S), transmute(rawptr)(cstring("")))
	} else {
		semsg_safe(cstring(E143_S), transmute(rawptr)(name))
	}
	xfree(transmute(rawptr)(name))
	au_new_curbuf_g.br_buf = nil
	au_new_curbuf_g.br_buf_free_count = 0
}

// Start editing a new file (fnum / ffname+sfname / eap command / newlnum).
// Returns FAIL for failure, OK otherwise.
@(export)
do_ecmd :: proc "c"(fnum: C.int, ffname_in: cstring, sfname_in: cstring, eap: rawptr, newlnum_in: C.int, flags: C.int, oldwin_in: rawptr) -> C.int {
	// No goto in Odin: "done" flag + guarded sections, single epilogue.
	done := false
	// Odin params are immutable: locals for reassigned ones.
	ffname := ffname_in
	sfname := sfname_in
	newlnum := newlnum_in
	oldwin := oldwin_in

	other_file := false
	oldbuf := false
	auto_buf := false
	new_name: ^u8 = nil
	did_set_swapcommand := false
	buf: rawptr = nil
	bufref: Bufref_T
	old_curbuf: Bufref_T
	free_fname: ^u8 = nil
	retval: C.int = FAIL
	topline: C.int = 0
	newcol: C.int = -1
	solcol: C.int = -1
	command: ^u8 = nil
	did_get_winopts := false
	readfile_flags: C.int = 0
	did_inc_redrawing_disabled := false
	so_ptr: rawptr = nil
	if (^C.longlong)(uintptr(curwin) + W_P_SO_ABS)^ >= 0 {
		so_ptr = rawptr(uintptr(curwin) + W_P_SO_ABS)
	} else {
		so_ptr = rawptr(&p_so_g)
	}

	if eap != nil {
		command = (^u8)((^rawptr)(uintptr(eap) + EXARG_DO_ECMD_CMD_OFF)^)
	}

	set_bufref(&old_curbuf, curbuf)

	if fnum != 0 {
		if fnum == (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ {
			return OK // file already being edited, nothing to do
		}
		other_file = true
	} else {
		// No short name given: use ffname for short name.
		if sfname == nil {
			sfname = ffname
		}
		// CASE_INSENSITIVE_FILENAME path_fix_case is macOS/Win-only: dropped.

		if (flags & (ECMD_ADDBUF_O | ECMD_ALTBUF_O)) != 0 &&
			(ffname == nil || ([^]u8)(transmute(^u8)(ffname))[0] == 0) {
			done = true
		}

		if !done {
			if ffname == nil {
				other_file = true
			} else if ([^]u8)(transmute(^u8)(ffname))[0] == 0 &&
				(^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil {
				other_file = false // there is no file name
			} else {
				if ([^]u8)(transmute(^u8)(ffname))[0] == 0 {
					// Re-edit with same file name.
					ffname = cstring((^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^))
					sfname = cstring((^u8)((^rawptr)(uintptr(curbuf) + B_FNAME)^))
				}
				free_fname = fix_fname_r(ffname) // may expand to full path
				if free_fname != nil {
					ffname = cstring(free_fname)
				}
				other_file = otherfile(ffname)
			}
		}
	}

	if !done {
		// Re-editing a terminal buffer: skip re-initialization.
		if !other_file && (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
			check_arg_idx_r(curwin) // needed when called from do_argfile()
			maketitle() // title may show the arg index, e.g. "(2 of 5)"
			retval = OK
			done = true
		}
	}

	if !done {
		// May not abandon a changed file: same-file re-edit, or the only
		// window on this file without ECMD_HIDE.
		abandon_ok := ((!other_file && (flags & ECMD_OLDBUF_O) == 0) ||
			((^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ == 1 &&
				(flags & (ECMD_HIDE_O | ECMD_ADDBUF_O | ECMD_ALTBUF_O)) == 0))
		ccgd: C.int = 0
		if p_awa != 0 {
			ccgd |= CCGD_AW_O
		}
		if !other_file {
			ccgd |= CCGD_MULTWIN_O
		}
		if (flags & ECMD_FORCEIT_O) != 0 {
			ccgd |= CCGD_FORCEIT_O
		}
		if eap != nil {
			ccgd |= CCGD_EXCMD_O
		}
		if abandon_ok && check_changed_r(curbuf, ccgd) {
			if fnum == 0 && other_file && ffname != nil {
				setaltfname(ffname, sfname,
					newlnum < 0 ? 0 : newlnum)
			}
			done = true
		}
	}

	if !done {
		// End Visual mode before switching (text to GUI selection buffer;
		// careful: may trigger ModeChanged autocommand).
		reset_VIsual_r()

		// Autocommands freed window :(
		if oldwin != nil && !win_valid(oldwin) {
			oldwin = nil
		}

		did_set_swapcommand = set_swapcommand(command, newlnum)

		// Another file: open a (new) buffer, else re-use current buffer.
		if other_file {
			prev_alt_fnum := (^C.int)(uintptr(curwin) + W_ALT_FNUM)^

			if (flags & (ECMD_ADDBUF_O | ECMD_ALTBUF_O)) == 0 {
				if (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
					(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ =
						(^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
				}
				if oldwin != nil {
					buflist_altfpos(oldwin)
				}
			}

			if fnum != 0 {
				buf = buflist_findnr(fnum)
			} else {
				if (flags & (ECMD_ADDBUF_O | ECMD_ALTBUF_O)) != 0 {
					// Line number zero: no wininfo for the current window.
					tlnum: C.int = 0

					if command != nil {
						tlnum = C.int(libc.atol(cstring(command)))
						if tlnum <= 0 {
							tlnum = 1
						}
					}
					// BLN_NOCURWIN: no wininfo for the current window.
					newbuf := buflist_new(ffname, sfname, tlnum,
						BLN_LISTED_O | BLN_NOCURWIN_O)
					if newbuf != nil && (flags & ECMD_ALTBUF_O) != 0 {
						(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ =
							(^C.int)(uintptr(newbuf) + B_FNUM_OFF)^
					}
					done = true
				} else {
					buf = buflist_new(ffname, sfname, 0,
						BLN_CURBUF_O | ((flags & ECMD_SET_HELP_O) != 0 ?
							0 : BLN_LISTED_O))
					// Autocmds may change curwin and curbuf.
					if oldwin != nil {
						oldwin = curwin
					}
					set_bufref(&old_curbuf, curbuf)
				}
			}
			if !done {
				if buf == nil {
					done = true
				} else {
					// A closing buffer can't be edited (split-like abort).
					if (^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ != 0 {
						emsg(cstring(E1546_S))
						done = true
					}
				}
			}
			if !done {
				if (^C.int)(uintptr(curwin) + W_ALT_FNUM)^ ==
					(^C.int)(uintptr(buf) + B_FNUM_OFF)^ && prev_alt_fnum != 0 {
					// Reusing the buffer, keep the old alternate file.
					(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ = prev_alt_fnum
				}
				if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
					oldbuf = false // no memfile yet
				} else {
					oldbuf = true // existing memfile
					set_bufref(&bufref, buf)
					buf_check_timestamp_r(buf)
					// Autocmds made buffer invalid or changed curbuf.
					if !bufref_valid(&bufref) ||
						curbuf != old_curbuf.br_buf {
						done = true
					} else if aborting_r() {
						done = true
					}
				}
			}
			if !done {
				// Jump to last-used line for a loaded buffer when asked.
				if (oldbuf && newlnum == ECMD_LASTL_O) ||
					newlnum == ECMD_LAST_O {
					fm := transmute(^Fmark_T)(buflist_findfmark(buf))
					newlnum = fm.mark.lnum
					solcol = fm.mark.col
				}

				// Make the (new) buffer the window's buffer, freeing the
				// old one unless ECMD_HIDE. Empty-no-name curbuf may be
				// returned by buflist_new(): then nothing to do here.
				if buf != curbuf {
					if (^rawptr)(uintptr(buf) + B_FNAME)^ != nil {
						new_name = xstrdup_o((^u8)((^rawptr)(uintptr(buf) + B_FNAME)^))
					}
					save_au_new_curbuf := au_new_curbuf_g
					set_bufref(&au_new_curbuf_g, buf)
					apply_autocmds(EVENT_BUFLEAVE_O, nil, nil, false, curbuf)

					if !bufref_valid(&au_new_curbuf_g) {
						// New buffer has been deleted.
						delbuf_msg_o(new_name) // frees new_name
						au_new_curbuf_g = save_au_new_curbuf
						done = true
					} else if aborting_r() {
						xfree(new_name)
						au_new_curbuf_g = save_au_new_curbuf
						done = true
					}
					if !done {
						if buf == curbuf { // already in new buffer
							auto_buf = true
						} else {
							the_curwin := curwin

							// Lock window+buffer against autocmd closes.
							(^C.int)(uintptr(the_curwin) + W_LOCKED_OFF)^ += 1
							(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1

							if curbuf == old_curbuf.br_buf {
								buf_copy_options(buf, BCO_ENTER_O)
							}

							// Close the link to the current buffer (may
							// set curwin->w_buffer to NULL).
							u_sync(false)
							hide_arg: C.int = DOBUF_UNLOAD_O
							term := (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^
							if (flags & ECMD_HIDE_O) != 0 ||
								(term != nil && terminal_running_r(term)) {
								hide_arg = 0
							}
							close_buffer(curwin, curbuf, hide_arg, false,
								false, oldwin != nil)

							// Autocommands may have closed the window.
							if win_valid(the_curwin) {
								(^C.int)(uintptr(the_curwin) + W_LOCKED_OFF)^ -= 1
							}
							(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1

							if aborting_r() &&
								(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ != nil {
								xfree(new_name)
								au_new_curbuf_g = save_au_new_curbuf
								done = true
							} else if !bufref_valid(&au_new_curbuf_g) {
								// New buffer deleted. Enter last one if
								// curwin->w_buffer is NULL.
								if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == nil {
									buf = lastbuf_g
								} else {
									delbuf_msg_o(new_name) // frees new_name
									au_new_curbuf_g = save_au_new_curbuf
									done = true
								}
							}
						}
					}
					if !done {
						if buf == curbuf { // already in new buffer
							auto_buf = true
						} else {
							// <VN> Could free synblock and re-attach instead.
							wb := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
							if wb == nil ||
								(^rawptr)(uintptr(curwin) + W_S_OFF)^ ==
								rawptr(uintptr(wb) + B_S_OFF) {
								(^rawptr)(uintptr(curwin) + W_S_OFF)^ =
									rawptr(uintptr(buf) + B_S_OFF)
							}

							if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ != nil {
								wb2 := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
								(^C.int)(uintptr(wb2) + B_NWINDOWS_OFF)^ -= 1
							}

							(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = buf
							curbuf = buf
							(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ += 1

							// Set 'fileformat'/'binary'/'fenc' when forced.
							if !oldbuf && eap != nil {
								set_file_options_r(true, eap)
								set_forced_fenc_r(eap)
							}
						}

						// Window options from last time (or global reset);
						// restores old folding stuff too.
						get_winopts(curbuf)
						did_get_winopts = true
					}
					if !done {
						xfree(new_name)
						au_new_curbuf_g = save_au_new_curbuf
					}
				}

				(^C.int)(uintptr(curwin) + W_PCMARK)^ = 1
				(^C.int)(uintptr(curwin) + W_PCMARK + 4)^ = 0
			}
		} else { // !other_file
			if (flags & (ECMD_ADDBUF_O | ECMD_ALTBUF_O)) != 0 ||
				check_fname_r() == FAIL {
				done = true
			} else {
				oldbuf = (flags & ECMD_OLDBUF_O) != 0
			}
		}
	}

	if !done {
		// Don't redraw until the cursor is right (autocmd ml_get errors).
		RedrawingDisabled += 1
		did_inc_redrawing_disabled = true

		buf = curbuf
		if (flags & ECMD_SET_HELP_O) != 0 || keep_help_flag_g {
			prepare_help_buffer_r()
		} else if !(^bool)(uintptr(curbuf) + B_HELP_OFF)^ {
			// Listed, unless a help buffer (CTRL-O back to help).
			set_buflisted(1)
		}

		// Autocommands changed buffers under our fingers: forget it.
		if buf != curbuf {
			done = true
		} else if aborting_r() {
			done = true
		}
	}

	if !done {
		// Filetype is unset from here on (an autocmd may expect syntax
		// highlighting to work in the other file).
		(^bool)(uintptr(curbuf) + B_DID_FILETYPE_OFF)^ = false

		// other_file oldbuf
		//  false     false       re-edit same file, buffer is re-used
		//  false     true        re-edit same file, nothing changes
		//  true      false       start editing new file, new buffer
		//  true      true        start editing existing buffer (noop)
		if !other_file && !oldbuf { // re-use the buffer
			set_last_cursor(curwin) // may set b_last_cursor
			if newlnum == ECMD_LAST_O || newlnum == ECMD_LASTL_O {
				newlnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				solcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
			}
			buf = curbuf
			if (^rawptr)(uintptr(buf) + B_FNAME)^ != nil {
				new_name = xstrdup_o((^u8)((^rawptr)(uintptr(buf) + B_FNAME)^))
			} else {
				new_name = nil
			}
			set_bufref(&bufref, buf)

			// Store current contents for undoable reload, unless the
			// (empty) buffer is re-used for another file.
			if ((^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ & BF_NEVERLOADED_O) == 0 &&
				(C.longlong(p_ur_g) < 0 || C.longlong((^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^) <= p_ur_g) {
				// Sync first: separate undo-able action.
				u_sync(false)
				if u_savecommon(curbuf, 0,
					(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ + 1, 0,
					true) == FAIL {
					xfree(new_name)
					done = true
				} else {
					u_unchanged(curbuf)
					buf_freeall(curbuf, BFA_KEEP_UNDO_O)

					// Tell readfile() to keep undo info.
					readfile_flags = READ_KEEP_UNDO_O
				}
			} else {
				buf_freeall(curbuf, 0) // free all things for buffer
			}
			if !done {
				// Autocommands deleted the re-edit buffer: give up.
				if !bufref_valid(&bufref) {
					delbuf_msg_o(new_name) // frees new_name
					done = true
				} else {
					xfree(new_name)

					// Autocommands changed buffers: forget re-editing
					// (should do buf_clear_file(), but buffers changed...).
					if buf != curbuf {
						done = true
					} else if aborting_r() {
						done = true
					} else {
						buf_clear_file(curbuf)
						// Clear '[ and '] marks.
						(^C.int)(uintptr(curbuf) + B_OP_START)^ = 0
						(^C.int)(uintptr(curbuf) + B_OP_END)^ = 0
					}
				}
			}
		}
	}

	if !done {
		// Sure to start editing now. Assume success.
		retval = OK

		// File name changed: reset not-edit flag so ":write" works.
		if !other_file {
			(^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ &= ~C.int(BF_NOTEDITED_O)
		}

		// Check for the w_arg_idx file in the argument list.
		check_arg_idx_r(curwin)

		if !auto_buf {
			// Cursor/window first (autocmds may position the cursor).
			curwin_init()

			// All lines may have changed: update automatic folding
			// everywhere this buffer is used.
			tp := first_tabpage
			for tp != nil {
				wp := tp == curtab ? firstwin :
					(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
				for wp != nil {
					if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
						foldUpdateAll(wp)
					}
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				}
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}

			// Change directories when 'acd' is set.
			do_autochdir()

			// Careful: open_buffer()/apply_autocmds() may change curbuf.
			orig_pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			topline = (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
			if !oldbuf { // need to read the file
				swap_exists_action_g = SEA_DIALOG_O
				(^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ |= BF_CHECK_RO_O

				// Open the buffer and read the file.
				if (flags & ECMD_NOWINENTER_O) != 0 {
					readfile_flags |= READ_NOWINENTER_O
				}
				if should_abort_r(open_buffer(false, eap, readfile_flags)) {
					retval = FAIL
				}

				if swap_exists_action_g == SEA_QUIT_O {
					retval = FAIL
				}
				handle_swap_exists(&old_curbuf)
			} else {
				// Modelines: window-local options only (buffer-local
				// ones are set and may have been user-changed).
				do_modelines(OPT_WINONLY_S)

				apply_autocmds_retval_r(EVENT_BUFENTER_O, nil, nil, false,
					curbuf, &retval)
				if (flags & ECMD_NOWINENTER_O) == 0 {
					apply_autocmds_retval_r(EVENT_BUFWINENTER_O, nil, nil,
						false, curbuf, &retval)
				}
			}
			check_arg_idx_r(curwin)

			// Keep an autocmd-moved cursor (but not first-non-blank).
			if !equalpos_o((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^,
				orig_pos) {
				text := get_cursor_line_ptr_r()

				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != orig_pos.lnum ||
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ !=
					C.int(uintptr(transmute(rawptr)(skipwhite(cstring(text)))) - uintptr(text)) {
					newlnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					newcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				}
			}
			if (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ == topline {
				topline = 0
			}

			// Recompute topline even when the cursor didn't move.
			changed_line_abv_curs_r()

			maketitle()
		}

		// Diff Signal: new/updated buffer (also after same-buffer re-edit,
		// whose unload removed it as a diff buffer).
		if (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0 {
			diff_buf_add_r(curbuf)
			diff_invalidate_r(curbuf)
		}

		// Window options may need a spell language (buffer fully set up).
		if did_get_winopts && (^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ != 0 {
			ws := (^rawptr)(uintptr(curwin) + W_S_OFF)^
			spl := (^u8)((^rawptr)(uintptr(ws) + SB_P_SPL_OFF)^)
			if spl != nil && spl^ != 0 {
				parse_spelllang(curwin)
			}
		}

		if command == nil {
			if newcol >= 0 { // position set by autocommands
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = newlnum
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = newcol
				check_cursor(curwin)
			} else if newlnum > 0 { // line number from caller/old position
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = newlnum
				check_cursor_lnum_r(curwin)
				if solcol >= 0 && p_sol_g == 0 {
					// 'sol' off: use last known column.
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = solcol
					check_cursor_col_r(curwin)
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
					(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
				} else {
					beginline(BL_SOL | BL_FIX)
				}
			} else { // no line number, last line in Ex mode
				if exmode_active {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ =
						(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
				}
				beginline(BL_WHITE | BL_FIX)
			}
		}

		// Other windows on this buffer: cursors still valid?
		check_lnums(false)

		// File not read: show some file info (after setting cursor).
		if oldbuf && !auto_buf {
			msg_scroll_save := msg_scroll

			// 'O' flag in 'cpoptions': overwrite any previous message.
			if shortmess(SHM_OVERALL_O) && msg_listdo_overwrite_g == 0 &&
				!exiting && p_verbose == 0 {
				msg_scroll = false
			}
			if !msg_scroll { // wait a bit when overwriting an error msg
				msg_check_for_delay_r(false)
			}
			msg_start()
			msg_scroll = msg_scroll_save
			msg_scrolled_ign_g = true

			if !shortmess(SHM_FILEINFO_O) {
				fileinfo(0, 1, false)
			}

			msg_scrolled_ign_g = false
		}

		(^C.longlong)(uintptr(curbuf) + B_LAST_USED_OFF)^ =
			C.longlong(libc.time(nil))

		if command != nil {
			do_cmdline_r(cstring(command), nil, nil, DOCMD_VERBOSE_O)
		}

		if (^i16)(uintptr(curbuf) + B_KMAP_STATE_OFF)^ & i16(KEYMAP_INIT) != 0 {
			keymap_init()
		}

		RedrawingDisabled -= 1
		did_inc_redrawing_disabled = false
		if !skip_redraw_g {
			n := (^C.longlong)(so_ptr)^
			if topline == 0 && command == nil {
				(^C.longlong)(so_ptr)^ = 999 // vertically center cursor
			}
			update_topline_r(curwin)
			(^C.int)(uintptr(curwin) + W_SCBIND_POS_OFF)^ =
				plines_m_win_fill_r(curwin, 1,
					(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^)
			(^C.longlong)(so_ptr)^ = n
			redraw_curbuf_later_r(UPD_NOT_VALID)
		}

		// Change directories when 'acd' is set.
		do_autochdir()
	}

	// theend:
	if bufref_valid(&old_curbuf) &&
		(^rawptr)(uintptr(old_curbuf.br_buf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r(
			(^rawptr)(uintptr(old_curbuf.br_buf) + B_TERMINAL_OFF)^)
	}
	if (!bufref_valid(&old_curbuf) || curbuf != old_curbuf.br_buf) &&
		(^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^)
	}

	if did_inc_redrawing_disabled {
		RedrawingDisabled -= 1
	}
	if did_set_swapcommand {
		set_vim_var_string(VV_SWAPCOMMAND, nil, -1)
	}
	xfree(free_fname)
	return retval
}
