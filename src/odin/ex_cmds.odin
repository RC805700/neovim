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
// Batch 26: :file/:write/:update (ex_cmds.c dispatch statics stay C).
CMD_SAVEAS_O :: 390
EXARG_LINE1_OFF :: 84
EXARG_USEFILTER_OFF :: 120
EVENT_BUFFILEPRE_O :: 5
EVENT_BUFFILEPOST_O :: 4

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
	@(link_name = "do_write")
	do_write_r :: proc "c"(eap: rawptr) -> C.int ---
	@(link_name = "do_bang")
	do_bang_r :: proc "c"(addr_count: C.int, eap: rawptr, forceit: bool, do_in: bool, do_out: bool) ---
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

// ── Batch 26: :file/:update/:write + rename_buffer ──────────────────────────

// Rename the current buffer's file (BUFFILEPRE/POST autocmds, alt-file save).
@(export)
rename_buffer :: proc "c"(new_fname: cstring) -> C.int {
	buf := curbuf
	apply_autocmds(EVENT_BUFFILEPRE_O, nil, nil, false, curbuf)
	// Buffer changed, don't change name now.
	if buf != curbuf {
		return FAIL
	}
	if aborting_r() { // autocmds may abort script processing
		return FAIL
	}
	// The current buffer keeps its name in a new (unlisted) entry that
	// becomes the alternate file — unless it never had a name.
	fname := (^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^)
	sfname := (^u8)((^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^)
	xfname := (^u8)((^rawptr)(uintptr(curbuf) + B_FNAME)^)
	(^rawptr)(uintptr(curbuf) + B_FFNAME)^ = nil
	(^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^ = nil
	if setfname(curbuf, new_fname, nil, true) == FAIL {
		(^rawptr)(uintptr(curbuf) + B_FFNAME)^ = transmute(rawptr)(fname)
		(^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^ = transmute(rawptr)(sfname)
		return FAIL
	}
	(^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ |= BF_NOTEDITED_O
	if xfname != nil && ([^]u8)(xfname)[0] != 0 {
		buf = buflist_new(cstring(fname), cstring(xfname),
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0)
		if buf != nil && (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
			(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ =
				(^C.int)(uintptr(buf) + B_FNUM_OFF)^
		}
	}
	xfree(transmute(rawptr)(fname))
	xfree(transmute(rawptr)(sfname))
	apply_autocmds(EVENT_BUFFILEPOST_O, nil, nil, false, curbuf)
	// Change directories when the 'acd' option is set.
	do_autochdir()
	return OK
}

// ":file" — rename buffer and/or show file info.
@(export)
ex_file :: proc "c"(eap: rawptr) {
	arg := (^cstring)(uintptr(eap))^
	// ":0file" removes the name; reject ":3file", "0file name", etc.
	if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ > 0 &&
		(([^]u8)(transmute(^u8)(arg))[0] != 0 ||
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ > 0 ||
			(^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ > 1) {
		emsg(cstring(e_invarg_s))
		return
	}

	if ([^]u8)(transmute(^u8)(arg))[0] != 0 ||
		(^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ == 1 {
		if rename_buffer(arg) == FAIL {
			return
		}
		redraw_tabline_opt = true
	}

	// Print file name if no argument or 'F' not in 'shortmess'.
	if ([^]u8)(transmute(^u8)(arg))[0] == 0 || !shortmess(SHM_FILEINFO_O) {
		fileinfo(0, 0, (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0)
	}
}

// ":update" — write only when changed (or file vanished).
@(export)
ex_update :: proc "c"(eap: rawptr) {
	if curbufIsChanged() ||
		(!bt_nofilename(curbuf) &&
			(^rawptr)(uintptr(curbuf) + B_FFNAME)^ != nil &&
			!os_path_exists(cstring((^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^)))) {
		do_write_r(eap)
	}
}

// ":write" and ":saveas".
@(export)
ex_write :: proc "c"(eap: rawptr) {
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_SAVEAS_O {
		// :saveas takes no range, uses all lines.
		(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = 1
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ =
			(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	}

	if (^bool)(uintptr(eap) + EXARG_USEFILTER_OFF)^ {
		do_bang_r(1, eap, false, true, false) // input lines to shell cmd
	} else {
		do_write_r(eap)
	}
}

// ── Batch 27: :wnext/:wNext + :wall/:wqall/:xall ────────────────────────────

CMD_WALL_O :: 528
CMD_WQALL_O :: 537
CMD_XALL_O :: 542
// EXARG_CMD_OFF already in buffer.odin — reuse.
GETFILE_ERROR_O :: 1
GETFILE_NOT_WRITTEN_O :: 2
GETFILE_SAME_FILE_O :: 0
GETFILE_OPEN_OTHER_O :: -1
EXARG_MKDIR_P_OFF :: 140
VIM_QUESTION_O :: 4
VIM_YES_O :: 2
DIALOG_MSG_SIZE_O :: 1000
E141_S :: "E141: No file name for buffer %ld"
E142_S :: "E142: File not written: Writing is disabled by 'write' option"
E45_S :: "E45: 'readonly' option is set (add ! to override)"
E505_S :: "E505: \"%s\" is read-only (add ! to override)"

foreign _ {
	@(link_name = "do_argfile")
	do_argfile_r :: proc "c"(eap: rawptr, argn: C.int) ---
	@(link_name = "before_quit_all")
	before_quit_all_r :: proc "c"(eap: rawptr) -> C.int ---
	@(link_name = "check_overwrite")
	check_overwrite_r :: proc "c"(eap: rawptr, buf: rawptr, fname: cstring, ffname: cstring, other: bool) -> C.int ---
	@(link_name = "buf_write_all")
	buf_write_all_r :: proc "c"(buf: rawptr, forceit: bool) -> C.int ---
	@(link_name = "not_exiting")
	not_exiting_r :: proc "c"(save_exiting: bool) ---
	@(link_name = "vim_dialog_yesno")
	vim_dialog_yesno_r :: proc "c"(typ: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int ---
	// p_confirm_g/p_write_g already in buffer.odin — reuse.
}

// Check the 'write' option (C static).
not_writing_o :: proc "c"() -> bool {
	if p_write_g != 0 {
		return false
	}
	emsg(cstring(E142_S))
	return true
}

// Read-only buffer check with confirm-dialog support (C static).
// Returns true (and errors) when the buffer is readonly.
check_readonly_o :: proc "c"(forceit: ^C.int, buf: rawptr) -> bool {
	// 'readonly' set, or file exists and is not writable.
	if forceit^ == 0 &&
		((^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0 ||
			(os_path_exists(cstring((^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^))) &&
				os_file_is_writable(cstring((^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^))) == 0)) {
		fname := (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
		if (p_confirm_g != 0 ||
			(cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && fname != nil {
			buff: [DIALOG_MSG_SIZE_O]u8
			if (^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0 {
				libc.snprintf(&buff[0], C.size_t(DIALOG_MSG_SIZE_O),
					cstring("'readonly' option is set for \"%s\".\nDo you wish to write anyway?"),
					cstring(fname))
			} else {
				libc.snprintf(&buff[0], C.size_t(DIALOG_MSG_SIZE_O),
					cstring("File permissions of \"%s\" are read-only.\nIt may still be possible to write it.\nDo you wish to try?"),
					cstring(fname))
			}

			if vim_dialog_yesno_r(VIM_QUESTION_O, nil, cstring(&buff[0]), 2) ==
				VIM_YES_O {
				forceit^ = 1 // force writing of a readonly file
				return false
			}
			return true
		} else if (^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0 {
			emsg(cstring(E45_S))
		} else {
			emsg_ro_file(cstring(fname))
		}
		return true
	}

	return false
}

// E505 with a possibly-NULL file name (split for single-line snprintf).
emsg_ro_file :: proc "c"(fname: cstring) {
	msg: [256]u8
	if fname == nil {
		libc.snprintf(&msg[0], C.size_t(256), cstring(E505_S), cstring(""))
	} else {
		libc.snprintf(&msg[0], C.size_t(256), cstring(E505_S), fname)
	}
	emsg(cstring(&msg[0]))
}

// ":wall", ":wqall", ":xall": write all changed files (and exit).
@(export)
do_wqall :: proc "c"(eap: rawptr) {
	error := 0
	save_forceit := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^
	save_exiting := exiting

	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	if cmdidx == CMD_XALL_O || cmdidx == CMD_WQALL_O {
		if before_quit_all_r(eap) == FAIL {
			return
		}
		exiting = true
	}

	buf := firstbuf
	for buf != nil {
		if exiting && (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ == 0 &&
			(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
			// TODO(zeertzjq): always false for nvim_open_term() terminals;
			// use terminal_running() instead?
			channel_job_running_r((^u64)(uintptr(buf) + B_P_CHANNEL_OFF)^) {
			no_write_message_buf(buf)
			error += 1
		} else if !bufIsChanged(buf) || bt_dontwrite(buf) {
			// Skip unchanged/unwritable buffers (no continue: if/else).
		} else if not_writing_o() {
			// 'write' option reason (breaks the loop in C).
			error += 1
			break
		} else {
			// Check writability: 'write' option(above), file name,
			// readonly, overwrite permission.
			fname := (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
			ffname := (^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^)
			if ffname == nil {
				msg: [128]u8
				libc.snprintf(&msg[0], C.size_t(128), cstring(E141_S),
					C.longlong((^C.int)(uintptr(buf) + B_FNUM_OFF)^))
				emsg(cstring(&msg[0]))
				error += 1
			} else {
				forceit := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^
				ro_failed := check_readonly_o(&forceit, buf)
				(^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ = forceit
				if ro_failed ||
					check_overwrite_r(eap, buf, cstring(fname), cstring(ffname),
						false) == FAIL {
					error += 1
				} else {
					bufref: Bufref_T
					set_bufref(&bufref, buf)
					mkdir_p := (^C.int)(uintptr(eap) + EXARG_MKDIR_P_OFF)^ != 0
					w_ok := true
					if mkdir_p {
						mk_fname := fname
						if mk_fname == nil {
							mk_fname = transmute(^u8)(cstring(""))
						}
						if handle_mkdir_p_arg_o(eap, cstring(mk_fname)) == FAIL {
							w_ok = false
						}
					}
					if w_ok &&
						buf_write_all_r(buf,
							(^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0) == FAIL {
						error += 1
					}
					// An autocommand may have deleted the buffer.
					if !bufref_valid(&bufref) {
						buf = firstbuf
					}
				}
			}
			(^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ = save_forceit
		}
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}
	if exiting {
		if error == 0 {
			getout(0) // exit Vim
		}
		not_exiting_r(save_exiting)
	}
}

// "++p" argument: create directories for "fname" (C static).
handle_mkdir_p_arg_o :: proc "c"(eap: rawptr, fname: cstring) -> C.int {
	if (^C.int)(uintptr(eap) + EXARG_MKDIR_P_OFF)^ != 0 &&
		os_file_mkdir(fname, 0o755) < 0 {
		return FAIL
	}

	return OK
}

// Handle ":wnext", ":wNext" and ":wprevious" commands.
@(export)
ex_wnext :: proc "c"(eap: rawptr) {
	i: C.int
	cmd := (^cstring)(uintptr(eap) + EXARG_CMD_OFF)^
	if ([^]u8)(transmute(^u8)(cmd))[1] == 'n' {
		i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ +
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	} else {
		i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ -
			(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	}
	(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ = 1
	(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ =
		(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	if do_write_r(eap) != FAIL {
		do_argfile_r(eap, i)
	}
}

// ── Batch 28: getfile (try to abandon current file, edit new/existing) ─────

// Try to abandon the current file and edit a new or existing file.
//
// @return GETFILE_ERROR/NOT_WRITTEN/SAME_FILE/OPEN_OTHER.
@(export)
getfile :: proc "c"(fnum: C.int, ffname_arg: cstring, sfname_arg: cstring, setpm: bool, lnum: C.int, forceit: bool) -> C.int {
	if !check_can_set_curbuf_forceit(forceit ? 1 : 0) {
		return GETFILE_ERROR_O
	}

	ffname := ffname_arg
	sfname := sfname_arg
	other := false
	retval: C.int = GETFILE_ERROR_O
	free_me: ^u8 = nil

	if text_locked_r() {
		return GETFILE_ERROR_O
	}
	if curbuf_locked_r() {
		return GETFILE_ERROR_O
	}

	if fnum == 0 {
		// Make ffname full path, set sfname.
		fname_expand(curbuf, &ffname, &sfname)
		other = otherfile(ffname)
		free_me = transmute(^u8)(ffname) // allocated, free() later
	} else {
		other = fnum != (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	}

	if other {
		no_wait_return += 1 // don't wait for autowrite message
	}
	if other && !forceit &&
		(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ == 1 &&
		!buf_hide(curbuf) && curbufIsChanged() &&
		autowrite_r(curbuf, forceit) == FAIL {
		if p_confirm_g != 0 && p_write_g != 0 {
			dialog_changed_r(curbuf, false)
		}
		if curbufIsChanged() {
			no_wait_return -= 1
			no_write_message()
			xfree(free_me)
			return GETFILE_NOT_WRITTEN_O // file has been changed
		}
	}
	if other {
		no_wait_return -= 1
	}
	if setpm {
		setpcmark()
	}
	if !other {
		if lnum != 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
		}
		check_cursor_lnum_r(curwin)
		beginline(BL_SOL | BL_FIX)
		retval = GETFILE_SAME_FILE_O // it's in the same file
	} else if do_ecmd(fnum, ffname, sfname, nil, lnum,
		(buf_hide(curbuf) ? ECMD_HIDE_O : 0) +
		(forceit ? ECMD_FORCEIT_O : 0), curwin) == OK {
		retval = GETFILE_OPEN_OTHER_O // opened another file
	} else {
		retval = GETFILE_ERROR_O // error encountered
	}

	xfree(free_me)
	return retval
}
