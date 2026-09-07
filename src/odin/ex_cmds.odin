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
	// do_bang now defined below (Batch 31b) — call directly.
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
		do_bang(1, eap, false, true, false) // input lines to shell cmd
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

// ── Batch 29: :sort/:uniq + sort statics ────────────────────────────────────
// (linelen() belongs to ex_align, not sort — skipped.)

STR2NR_BIN_O :: 1
STR2NR_OCT_O :: 2
STR2NR_HEX_O :: 4
STR2NR_FORCE_O :: 128
E_INTERR_S :: "Interrupted"

// sorti_T mirrors C (ex_cmds.c:362): lnum@0 + 16-byte union @8 = 24 bytes.
// Odin has no union: byte overlay with typed accessors (Batch-16 class).
Sorti_T :: struct {
	lnum: C.int,
	_pad: C.int,
	u:    [16]u8,
}
#assert(size_of(Sorti_T) == 24)

foreign _ {
	@(link_name = "check_nextcmd")
	check_nextcmd_r :: proc "c"(p: ^u8) -> ^u8 ---
	@(link_name = "skip_regexp_err")
	skip_regexp_err_r :: proc "c"(startp: ^u8, delim: C.int, magic: C.int) -> ^u8 ---
	@(link_name = "skiptohex")
	skiptohex_r :: proc "c"(q: ^u8) -> ^u8 ---
	@(link_name = "skiptobin")
	skiptobin_r :: proc "c"(q: ^u8) -> ^u8 ---
	@(link_name = "skiptodigit")
	skiptodigit_r :: proc "c"(q: ^u8) -> ^u8 ---
	@(link_name = "strcoll")
	strcoll_r :: proc "c"(s1: cstring, s2: cstring) -> C.int ---
	// p_ic already in search.odin — reuse.
}

@(private="file")
sort_lc_f, sort_ic_f, sort_rx_f, sort_nr_f, sort_flt_f, sort_abort_f: bool
@(private="file")
sortbuf1_f, sortbuf2_f: ^u8

// ASCII_ISALPHA is a plain (context) proc in os_lang.odin — uncallable from
// proc "c". Trivial local copy (same body).
ascii_isalpha_o :: proc "c"(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

// Compare two NUL-terminated strings (locale/case/byte per flags).
string_compare_o :: proc "c"(s1: rawptr, s2: rawptr) -> C.int {
	c1 := cstring(transmute(^u8)(s1))
	c2 := cstring(transmute(^u8)(s2))
	if sort_lc_f {
		return strcoll_r(c1, c2)
	}
	if sort_ic_f {
		return _mb_stricmp(c1, c2)
	}
	return libc.strcmp(c1, c2)
}

// qsort comparator over Sorti_T (stable via lnum tiebreak; abort-safe).
sort_compare_o :: proc "c"(s1: rawptr, s2: rawptr) -> C.int {
	l1 := (^Sorti_T)(s1)^
	l2 := (^Sorti_T)(s2)^
	result: C.int = 0

	// No way to stop qsort(); returning 0 ends it quickly.
	if sort_abort_f {
		return 0
	}
	fast_breakcheck()
	if got_int {
		sort_abort_f = true
	}

	// Number-sort reads the number, not the column.
	if sort_nr_f {
		n1 := (^bool)(&l1.u[8])^
		n2 := (^bool)(&l2.u[8])^
		if n1 != n2 {
			result = n1 ? 1 : -1
		} else {
			v1 := (^C.longlong)(&l1.u[0])^
			v2 := (^C.longlong)(&l2.u[0])^
			if v1 != v2 {
				result = v1 > v2 ? 1 : -1
			}
		}
	} else if sort_flt_f {
		f1 := (^f64)(&l1.u[0])^
		f2 := (^f64)(&l2.u[0])^
		if f1 != f2 {
			result = f1 > f2 ? 1 : -1
		}
	} else {
		// Copy via sortbuf (ml_get pointers may invalidate each other).
		l1s := (^C.longlong)(&l1.u[0])^
		l1e := (^C.longlong)(&l1.u[8])^
		libc.memcpy(transmute(rawptr)(sortbuf1_f),
			transmute(rawptr)((^u8)(uintptr(ml_get(l1.lnum)) + uintptr(l1s))),
			C.size_t(l1e - l1s + 1))
		([^]u8)(sortbuf1_f)[l1e - l1s] = 0
		l2s := (^C.longlong)(&l2.u[0])^
		l2e := (^C.longlong)(&l2.u[8])^
		libc.memcpy(transmute(rawptr)(sortbuf2_f),
			transmute(rawptr)((^u8)(uintptr(ml_get(l2.lnum)) + uintptr(l2s))),
			C.size_t(l2e - l2s + 1))
		([^]u8)(sortbuf2_f)[l2e - l2s] = 0

		result = string_compare_o(transmute(rawptr)(sortbuf1_f),
			transmute(rawptr)(sortbuf2_f))
	}

	// Same value: preserve original line order.
	if result == 0 {
		return l1.lnum - l2.lnum
	}
	return result
}

// ":sort" — sort lines (string/number/float/regex, unique, reverse).
@(export)
ex_sort :: proc "c"(eap: rawptr) {
	regmatch: Regmatch_T
	maxlen: C.int = 0
	count := C.size_t((^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ -
		(^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^) + 1
	unique := false
	sort_what: C.int = 0

	// Sorting one line is really quick!
	if count <= 1 {
		return
	}

	if u_save((^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^ - 1,
		(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ + 1) == FAIL {
		return
	}
	sortbuf1_f = nil
	sortbuf2_f = nil
	regmatch.regprog = nil
	nrs := ([^]Sorti_T)(xmalloc(C.size_t(count) * 24))

	sort_abort_f = false
	sort_ic_f = false
	sort_lc_f = false
	sort_rx_f = false
	sort_nr_f = false
	sort_flt_f = false
	format_found: C.int = 0
	change_occurred := false // buffer contents changed
	done := false

	arg := (^cstring)(uintptr(eap))^
	p := transmute(^u8)(arg)
	for ([^]u8)(p)[0] != 0 {
		c := ([^]u8)(p)[0]
		if ascii_iswhite(c) {
			// Skip
		} else if c == 'i' {
			sort_ic_f = true
		} else if c == 'l' {
			sort_lc_f = true
		} else if c == 'r' {
			sort_rx_f = true
		} else if c == 'n' {
			sort_nr_f = true
			format_found += 1
		} else if c == 'f' {
			sort_flt_f = true
			format_found += 1
		} else if c == 'b' {
			sort_what = STR2NR_BIN_O + STR2NR_FORCE_O
			format_found += 1
		} else if c == 'o' {
			sort_what = STR2NR_OCT_O + STR2NR_FORCE_O
			format_found += 1
		} else if c == 'x' {
			sort_what = STR2NR_HEX_O + STR2NR_FORCE_O
			format_found += 1
		} else if c == 'u' {
			unique = true
		} else if c == '"' { // comment start
			break
		} else {
			nc := check_nextcmd_r(p)
			if nc != nil {
				(^rawptr)(uintptr(eap) + 32)^ = transmute(rawptr)(nc)
				break
			} else if !ascii_isalpha_o(c) && regmatch.regprog == nil {
				s := skip_regexp_err_r((^u8)(uintptr(p) + 1), C.int(c), 1)
				if s == nil {
					done = true
					break
				}
				([^]u8)(s)[0] = 0
				// Empty pattern: use last search pattern.
				if uintptr(s) == uintptr(p) + 1 {
					if last_search_pat() == nil {
						emsg(e_noprevre)
						done = true
						break
					}
					regmatch.regprog = vim_regcomp(
						cstring(last_search_pat()), RE_MAGIC)
				} else {
					regmatch.regprog = vim_regcomp(
						cstring((^u8)(uintptr(p) + 1)), RE_MAGIC)
				}
				if regmatch.regprog == nil {
					done = true
					break
				}
				p = s // continue after the regexp
				regmatch.rm_ic = p_ic
			} else {
				semsg_safe(cstring(e_invarg2), transmute(rawptr)(p))
				done = true
				break
			}
		}
		p = (^u8)(uintptr(p) + 1)
	}

	// Can only have one of 'n', 'b', 'o' and 'x'.
	if !done && format_found > 1 {
		emsg(cstring(e_invarg_s))
		done = true
	}

	// From here on sort_nr flags any integer-number sorting
	// (C: sort_nr |= sort_what — bool conversion).
	if !done && sort_what != 0 {
		sort_nr_f = true
	}

	// One pass per line: match pattern, convert numbers, track maxlen.
	// (Pattern/number work happens once per line, not per comparison.)
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	if !done {
		lnum := line1
		for lnum <= line2 {
			s := ml_get(lnum)
			len := ml_get_len_r2(lnum)
			if len > maxlen {
				maxlen = len
			}

			start_col: C.int = 0
			end_col: C.int = len
			if regmatch.regprog != nil &&
				vim_regexec_r(&regmatch, s, 0) != 0 {
				if sort_rx_f {
					start_col = C.int(uintptr(regmatch.startp[0]) - uintptr(s))
					end_col = C.int(uintptr(regmatch.endp[0]) - uintptr(s))
				} else {
					start_col = C.int(uintptr(regmatch.endp[0]) - uintptr(s))
				}
			} else if regmatch.regprog != nil {
				end_col = 0
			}

			nr := &nrs[lnum - line1]
			if sort_nr_f || sort_flt_f {
				// NUL-terminate at the match end for vim_str2nr().
				s2 := (^u8)(uintptr(s) + uintptr(end_col))
				savec := ([^]u8)(s2)[0]
				([^]u8)(s2)[0] = 0
				pp := (^u8)(uintptr(s) + uintptr(start_col))
				if sort_nr_f {
					if (sort_what & STR2NR_HEX_O) != 0 {
						s = skiptohex_r(pp)
					} else if (sort_what & STR2NR_BIN_O) != 0 {
						s = skiptobin_r(pp)
					} else {
						s = skiptodigit_r(pp)
					}
					if uintptr(s) > uintptr(pp) &&
						([^]u8)((^u8)(uintptr(s) - 1))[0] == '-' {
						s = (^u8)(uintptr(s) - 1) // preceding minus
					}
					if ([^]u8)(s)[0] == 0 {
						// No number: sorts before any number.
						(^bool)(&nr.u[8])^ = false
						(^C.longlong)(&nr.u[0])^ = 0
					} else {
						(^bool)(&nr.u[8])^ = true
						vim_str2nr_r(cstring(s), nil, nil, sort_what,
							(^C.longlong)(&nr.u[0]), nil, 0, false, nil)
					}
				} else {
					s = transmute(^u8)(skipwhite(cstring(pp)))
					if ([^]u8)(s)[0] == '+' {
						s = transmute(^u8)(skipwhite(cstring(
							(^u8)(uintptr(s) + 1))))
					}

					if ([^]u8)(s)[0] == 0 {
						// Empty: sorts before any number.
						(^f64)(&nr.u[0])^ = -1.7976931348623157e308
					} else {
						(^f64)(&nr.u[0])^ = libc.strtod(cstring(s), nil)
					}
				}
				([^]u8)(s2)[0] = savec
			} else {
				// Store the column to sort at.
				(^C.longlong)(&nr.u[0])^ = C.longlong(start_col)
				(^C.longlong)(&nr.u[8])^ = C.longlong(end_col)
			}

			nr.lnum = lnum

			if regmatch.regprog != nil {
				fast_breakcheck()
			}
			if got_int {
				done = true
				break
			}
			lnum += 1
		}
	}

	if !done {
		// Longest-line buffers for the comparator.
		sortbuf1_f = (^u8)(xmalloc(C.size_t(maxlen) + 1))
		sortbuf2_f = (^u8)(xmalloc(C.size_t(maxlen) + 1))

		// Sort the line-number array (can't be interrupted).
		qsort_r(nrs, count, 24, sort_compare_o)

		if sort_abort_f {
			done = true
		}
	}

	old_count: C.longlong = 0
	new_count: C.longlong = 0
	if !done {
		// Insert lines in sorted order below the last one.
		lnum := line2
		i: C.size_t = 0
		for i < count {
			forceit := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0
			get_lnum := nrs[forceit ? count - i - 1 : i].lnum

			// Placed line differs (with offset): buffer changed.
			if get_lnum + C.int(count) - 1 != lnum {
				change_occurred = true
			}

			s := ml_get(get_lnum)
			bytelen := ml_get_len_r2(get_lnum) + 1 // include EOL
			old_count += C.longlong(bytelen)
			if !unique || i == 0 ||
				string_compare_o(transmute(rawptr)(s),
					transmute(rawptr)(sortbuf1_f)) != 0 {
				// Copy: may invalidate in ml_append(); needed for unique.
				xstrlcpy_o(cstring(sortbuf1_f), cstring(s),
					C.size_t(maxlen) + 1)
				if !ml_append_c(lnum, sortbuf1_f, 0, false) {
					break
				}
				lnum += 1
				new_count += C.longlong(bytelen)
			}
			fast_breakcheck()
			if got_int {
				done = true
				break
			}
			i += 1
		}

		if !done {
			// Delete the original lines if appending worked.
			if i == count {
				j: C.size_t = 0
				for j < count {
					ml_delete_r(line1)
					j += 1
				}
			} else {
				count = 0
			}

			// Adjust marks, prepare for display.
			deleted := C.int(count) - (lnum - line2)
			if deleted > 0 {
				mark_adjust(line2 - deleted, line2, MAXLNUM, -deleted,
					kExtmarkNOOP)
				msgmore_r(-deleted)
			} else if deleted < 0 {
				mark_adjust(line2, MAXLNUM, -deleted, 0, kExtmarkNOOP)
			}

			if change_occurred || deleted != 0 {
				extmark_splice_r(curbuf, line1 - 1, 0, C.int(count), 0,
					i64(old_count), lnum - line2, 0, i64(new_count),
					kExtmarkUndo)
				changed_lines_r(curbuf, line1, 0, line2 + 1, -deleted, true)
			}

			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line1
			beginline(BL_WHITE | BL_FIX)
		}
	}

	// sortend: always free, report interrupts.
	xfree(nrs)
	xfree(transmute(rawptr)(sortbuf1_f))
	xfree(transmute(rawptr)(sortbuf2_f))
	vim_regfree(regmatch.regprog)
	if got_int {
		emsg(cstring(E_INTERR_S))
	}
}

// ":uniq" — delete duplicate (adjacent, post-match) lines.
@(export)
ex_uniq :: proc "c"(eap: rawptr) {
	regmatch: Regmatch_T
	maxlen: C.int = 0
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	count: C.int = line2 - line1 + 1
	keep_only_unique := false
	keep_only_not_unique := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0
	deleted: C.int = 0

	// Uniq one line is really quick!
	if count <= 1 {
		return
	}

	if u_save(line1 - 1, line2 + 1) == FAIL {
		return
	}
	sortbuf1_f = nil
	regmatch.regprog = nil

	sort_abort_f = false
	sort_ic_f = false
	sort_lc_f = false
	sort_rx_f = false
	sort_nr_f = false
	sort_flt_f = false
	change_occurred := false // buffer contents changed
	done := false

	arg := (^cstring)(uintptr(eap))^
	p := transmute(^u8)(arg)
	for ([^]u8)(p)[0] != 0 {
		c := ([^]u8)(p)[0]
		if ascii_iswhite(c) {
			// Skip
		} else if c == 'i' {
			sort_ic_f = true
		} else if c == 'l' {
			sort_lc_f = true
		} else if c == 'r' {
			sort_rx_f = true
		} else if c == 'u' {
			// 'u' is only valid when '!' is not given.
			if !keep_only_not_unique {
				keep_only_unique = true
			}
		} else if c == '"' { // comment start
			break
		} else {
			nc := check_nextcmd_r(p)
			if (^rawptr)(uintptr(eap) + 32)^ == nil && nc != nil {
				(^rawptr)(uintptr(eap) + 32)^ = transmute(rawptr)(nc)
				break
			} else if !ascii_isalpha_o(c) && regmatch.regprog == nil {
				s := skip_regexp_err_r((^u8)(uintptr(p) + 1), C.int(c), 1)
				if s == nil {
					done = true
					break
				}
				([^]u8)(s)[0] = 0
				// Empty pattern: use last search pattern.
				if uintptr(s) == uintptr(p) + 1 {
					if last_search_pat() == nil {
						emsg(e_noprevre)
						done = true
						break
					}
					regmatch.regprog = vim_regcomp(
						cstring(last_search_pat()), RE_MAGIC)
				} else {
					regmatch.regprog = vim_regcomp(
						cstring((^u8)(uintptr(p) + 1)), RE_MAGIC)
				}
				if regmatch.regprog == nil {
					done = true
					break
				}
				p = s // continue after the regexp
				regmatch.rm_ic = p_ic
			} else {
				semsg_safe(cstring(e_invarg2), transmute(rawptr)(p))
				done = true
				break
			}
		}
		p = (^u8)(uintptr(p) + 1)
	}

	// Find the length of the longest line.
	if !done {
		lnum := line1
		for lnum <= line2 {
			len := ml_get_len_r2(lnum)
			if maxlen < len {
				maxlen = len
			}

			if got_int {
				done = true
				break
			}
			lnum += 1
		}
	}

	if !done {
		// Buffer that can hold the longest line.
		sortbuf1_f = (^u8)(xmalloc(C.size_t(maxlen) + 1))

		// Delete lines according to options.
		match_continue := false
		next_is_unmatch := false
		done_lnum := line1 - 1
		delete_lnum: C.int = 0
		i: C.int = 0
		for i < count {
			get_lnum := line1 + i

			s := ml_get(get_lnum)
			len := ml_get_len_r2(get_lnum)

			start_col: C.int = 0
			end_col: C.int = len
			if regmatch.regprog != nil &&
				vim_regexec_r(&regmatch, s, 0) != 0 {
				if sort_rx_f {
					start_col = C.int(uintptr(regmatch.startp[0]) - uintptr(s))
					end_col = C.int(uintptr(regmatch.endp[0]) - uintptr(s))
				} else {
					start_col = C.int(uintptr(regmatch.endp[0]) - uintptr(s))
				}
			} else if regmatch.regprog != nil {
				end_col = 0
			}
			save_c: u8 = 0 // temporary character storage
			if end_col > 0 {
				save_c = ([^]u8)(s)[end_col]
				([^]u8)(s)[end_col] = 0
			}

			is_match := false
			if i > 0 {
				is_match = string_compare_o(
					transmute(rawptr)((^u8)(uintptr(s) + uintptr(start_col))),
					transmute(rawptr)(sortbuf1_f)) == 0
			}
			delete_lnum = 0
			if next_is_unmatch {
				is_match = false
				next_is_unmatch = false
			}

			if !keep_only_unique && !keep_only_not_unique {
				if is_match {
					delete_lnum = get_lnum
				} else {
					xstrlcpy_o(cstring(sortbuf1_f),
						cstring((^u8)(uintptr(s) + uintptr(start_col))),
						C.size_t(maxlen) + 1)
				}
			} else if keep_only_not_unique {
				if is_match {
					done_lnum = get_lnum - 1
					delete_lnum = get_lnum
					match_continue = true
				} else {
					if i > 0 && !match_continue &&
						get_lnum - 1 > done_lnum {
						delete_lnum = get_lnum - 1
						next_is_unmatch = true
					} else if i >= count - 1 {
						delete_lnum = get_lnum
					}
					match_continue = false
					xstrlcpy_o(cstring(sortbuf1_f),
						cstring((^u8)(uintptr(s) + uintptr(start_col))),
						C.size_t(maxlen) + 1)
				}
			} else { // keep_only_unique
				if is_match {
					if !match_continue {
						delete_lnum = get_lnum - 1
					} else {
						delete_lnum = get_lnum
					}
					match_continue = true
				} else {
					if i == 0 && match_continue {
						delete_lnum = get_lnum
					}
					match_continue = false
					xstrlcpy_o(cstring(sortbuf1_f),
						cstring((^u8)(uintptr(s) + uintptr(start_col))),
						C.size_t(maxlen) + 1)
				}
			}

			if end_col > 0 {
				([^]u8)(s)[end_col] = save_c
			}

			if delete_lnum > 0 {
				ml_delete_r(delete_lnum)
				i -= get_lnum - delete_lnum + 1
				count -= 1
				deleted += 1
				change_occurred = true
			}

			fast_breakcheck()
			if got_int {
				done = true
				break
			}
			i += 1
		}

		if !done {
			// Adjust marks, prepare for display.
			mark_adjust(line2 - deleted, line2, MAXLNUM, -deleted,
				change_occurred ? kExtmarkUndo : kExtmarkNOOP)
			msgmore_r(-deleted)

			if change_occurred {
				changed_lines_r(curbuf, line1, 0, line2 + 1, -deleted, true)
			}

			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line1
			beginline(BL_WHITE | BL_FIX)
		}
	}

	// uniqend: always free, report interrupts.
	xfree(transmute(rawptr)(sortbuf1_f))
	vim_regfree(regmatch.regprog)
	if got_int {
		emsg(cstring(E_INTERR_S))
	}
}

// ── Batch 30: do_move/ex_copy (:move/:copy line mover) ──────────────────────

ML_DEL_MESSAGE_O :: 1
CMOD_LOCKMARKS_O :: 0x0800
E134_S :: "E134: Cannot move a range of lines into itself"

foreign _ {
	@(link_name = "ml_find_line_or_offset")
	ml_find_line_or_offset_r :: proc "c"(buf: rawptr, lnum: C.int, offp: rawptr, no_ff: bool) -> C.longlong ---
	@(link_name = "appended_lines_mark")
	appended_lines_mark_r :: proc "c"(lnum: C.int, count: C.int) ---
	@(link_name = "extmark_move_region")
	extmark_move_region_r :: proc "c"(buf: rawptr, start_row: C.int, start_col: C.int, start_byte: C.longlong, extent_row: C.int, extent_col: C.int, extent_byte: C.longlong, new_row: C.int, new_col: C.int, new_byte: C.longlong, undo: C.int) ---
	@(link_name = "ml_delete_flags")
	ml_delete_flags_r :: proc "c"(lnum: C.int, flags: C.int) -> C.int ---
	// disable_fold_update (fold.odin), p_report (register.odin) — reuse.
}

// :move command — move lines line1-line2 to after line dest.
@(export)
do_move :: proc "c"(line1: C.int, line2: C.int, dest: C.int) -> C.int {
	if dest >= line1 && dest < line2 {
		emsg(cstring(E134_S))
		return FAIL
	}

	// No-op move: no 'modified' flag, but move cursor compatibly.
	if dest == line1 - 1 || dest == line2 {
		if dest >= line1 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = dest
		} else {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = dest + (line2 - line1) + 1
		}
		return OK
	}

	start_byte := ml_find_line_or_offset_r(curbuf, line1, nil, true)
	end_byte := ml_find_line_or_offset_r(curbuf, line2 + 1, nil, true)
	extent_byte := end_byte - start_byte
	dest_byte := ml_find_line_or_offset_r(curbuf, dest + 1, nil, true)

	num_lines := line2 - line1 + 1 // lines moved

	// Copy old text to its new location (plus :global flag).
	if u_save(dest, dest + 1) == FAIL {
		return FAIL
	}

	extra: C.int = 0 // lines added before line1
	l := line1
	for l <= line2 {
		str := xstrnsave_c(cstring(ml_get(l + extra)),
			C.size_t(ml_get_len_r2(l + extra)))
		ml_append_c(dest + l - line1, str, 0, false)
		xfree(transmute(rawptr)(str))
		if dest < line1 {
			extra += 1
		}
		l += 1
	}

	// Adjust marks in stages (old text to end-of-file, middle range,
	// then back to destination) to avoid overlapping adjustments.
	last_line := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	mark_adjust_nofold(line1, line2, last_line - line2, 0, kExtmarkNOOP)

	disable_fold_update += 1
	changed_lines_r(curbuf, last_line - num_lines + 1, 0, last_line + 1,
		num_lines, false)
	disable_fold_update -= 1

	line_off: C.int = 0
	byte_off: C.longlong = 0
	if dest >= line2 {
		mark_adjust_nofold(line2 + 1, dest, -num_lines, 0, kExtmarkNOOP)
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin :
				(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
					foldMoveRange(wp, (^Garray)(uintptr(wp) + W_FOLDS_OFF),
						line1, line2, dest)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
			(^C.int)(uintptr(curbuf) + B_OP_START)^ = dest - num_lines + 1
			(^C.int)(uintptr(curbuf) + B_OP_END)^ = dest
		}
		line_off = -num_lines
		byte_off = -extent_byte
	} else {
		mark_adjust_nofold(dest + 1, line1 - 1, num_lines, 0, kExtmarkNOOP)
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin :
				(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == curbuf {
					foldMoveRange(wp, (^Garray)(uintptr(wp) + W_FOLDS_OFF),
						dest + 1, line1 - 1, line2)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
			(^C.int)(uintptr(curbuf) + B_OP_START)^ = dest + 1
			(^C.int)(uintptr(curbuf) + B_OP_END)^ = dest + num_lines
		}
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
		(^C.int)(uintptr(curbuf) + B_OP_START + 4)^ = 0
		(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = 0
	}
	mark_adjust_nofold(last_line - num_lines + 1, last_line,
		-(last_line - dest - extra), 0, kExtmarkNOOP)

	disable_fold_update += 1
	changed_lines_r(curbuf, last_line - num_lines + 1, 0, last_line + 1,
		-extra, false)
	disable_fold_update -= 1

	// New-lines update event.
	buf_updates_send_changes_r(curbuf, dest + 1, i64(num_lines), 0)

	// Now delete the original text.
	if u_save(line1 + extra - 1, line2 + extra + 1) == FAIL {
		return FAIL
	}

	l = line1
	for l <= line2 {
		ml_delete_flags_r(line1 + extra, ML_DEL_MESSAGE_O)
		l += 1
	}
	if global_busy == 0 && i64(num_lines) > p_report {
		smsg(0, cstring(num_lines == 1 ? "%ld line moved" : "%ld lines moved"),
			C.longlong(num_lines))
	}

	extmark_move_region_r(curbuf, line1 - 1, 0, start_byte,
		line2 - line1 + 1, 0, extent_byte,
		dest + line_off, 0, dest_byte + byte_off,
		kExtmarkUndo)

	// Cursor on the last of the moved lines.
	if dest >= line1 {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = dest
	} else {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = dest + (line2 - line1) + 1
	}

	if line1 < dest {
		dest_v := dest + num_lines + 1
		last_line_v := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		if dest_v > last_line_v + 1 {
			dest_v = last_line_v + 1
		}
		changed_lines_r(curbuf, line1, 0, dest_v, 0, false)
	} else {
		changed_lines_r(curbuf, dest + 1, 0, line1 + num_lines, 0, false)
	}

	// Deleted-lines event.
	buf_updates_send_changes_r(curbuf, line1 + extra, 0,
		i64(num_lines))

	return OK
}

// ":copy" — copy lines line1-line2 to after line n.
@(export)
ex_copy :: proc "c"(line1_in: C.int, line2_in: C.int, n: C.int) {
	line1 := line1_in
	line2 := line2_in
	count := line2 - line1 + 1
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
		(^C.int)(uintptr(curbuf) + B_OP_START)^ = n + 1
		(^C.int)(uintptr(curbuf) + B_OP_END)^ = n + count
		(^C.int)(uintptr(curbuf) + B_OP_START + 4)^ = 0
		(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = 0
	}

	// n = destination (start); w_cursor.lnum = destination (copying);
	// line1/line2 = source range (shifting as lines are added).
	if u_save(n, n + 1) == FAIL {
		return
	}

	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = n
	for line1 <= line2 {
		// Copy: the line is unlocked within ml_append().
		p := xstrnsave_c(cstring(ml_get(line1)),
			C.size_t(ml_get_len_r2(line1)))
		ml_append_c((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, p, 0, false)
		xfree(transmute(rawptr)(p))

		// Situation 2: skip already copied lines.
		if line1 == n {
			line1 = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		}
		line1 += 1
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < line1 {
			line1 += 1
		}
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < line2 {
			line2 += 1
		}
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
	}

	appended_lines_mark_r(n, count)
	if VIsual_active {
		check_pos_r(curbuf, &VIsual_g)
	}

	msgmore_r(count)
}

// ── Batch 31a: shell-filter builders (make_filter_cmd/append_redir) ────────
// (find_pipe is #ifndef UNIX — skipped on Linux like completeslash.)

EVENT_SHELLFILTERPOST_O :: 102
CPO_REMMARK_O :: C.int('R')
KSHELLOPT_FILTER_O :: 1
KSHELLOPT_DOOUT_O :: 4
KSHELLOPT_READ_O :: 16
KSHELLOPT_WRITE_O :: 32
READ_FILTER_O :: 0x02
CMOD_KEEPMARKS_O :: 0x0200
MSG_BUF_LEN_O :: 480
E482_S :: "E482: Can't create file %s"
E135_S :: "E135: *Filter* Autocommands must not change current buffer"
E483_S :: "E483: Can't get temp file name"
E485_S :: "E485: Can't read file %s"

foreign _ {
	// p_sh already in shell.odin — reuse.
	@(link_name = "p_shq")
	p_shq_g: ^u8
	@(link_name = "p_srr")
	p_srr_g: ^u8
	@(link_name = "p_stmp")
	p_stmp_g: C.int
	@(link_name = "msg_buf")
	msg_buf_g: [480]u8
	@(link_name = "ui_cursor_goto")
	ui_cursor_goto_r :: proc "c"(row: C.int, col: C.int) ---
	@(link_name = "did_check_timestamps")
	did_check_timestamps_g: bool
	@(link_name = "need_check_timestamps")
	need_check_timestamps_g: bool
	@(link_name = "buf_write")
	buf_write_r :: proc "c"(buf: rawptr, fname: cstring, sfname: cstring, start: C.int, end: C.int, eap: rawptr, append: bool, forceit: bool, reset_changed: bool, filtering: bool) -> C.int ---
	@(link_name = "del_lines")
	del_lines_r :: proc "c"(nlines: C.int, undo: bool) ---
	@(link_name = "write_lnum_adjust")
	write_lnum_adjust_r :: proc "c"(offset: C.int) ---
	@(link_name = "foldUpdate")
	foldUpdate_r :: proc "c"(wp: rawptr, top: C.int, bot: C.int) ---
	@(link_name = "wait_return")
	wait_return_r :: proc "c"(redraw: C.int) ---
}

// Append output redirection for "fname" to "buf" (" %s %s" or opt-as-format).
@(export)
append_redir :: proc "c"(buf: ^u8, buflen: C.size_t, opt: cstring, fname: cstring) {
	end := (^u8)(uintptr(buf) + uintptr(libc.strlen(cstring(buf))))
	// Find "%s" (skipping "%%"). core strchr returns [^]u8.
	found: rawptr = nil
	cur := opt
	for {
		q := libc.strchr(cur, '%')
		if q == nil {
			break
		}
		if q[1] == 's' {
			found = rawptr(&q[0])
			break
		}
		np := (^u8)(uintptr(&q[0]) + 1)
		if q[1] == '%' {
			np = (^u8)(uintptr(&q[0]) + 2)
		}
		cur = cstring(np)
	}
	if found != nil {
		([^]u8)(end)[0] = ' ' // not really needed? not with sh/ksh/bash
		// The user option IS the format string here (validity is checked
		// in did_set_shellpipe_redir, same fire profile as C).
		libc.snprintf((^u8)(uintptr(end) + 1),
			C.size_t(buflen) - C.size_t(uintptr(end) + 1 - uintptr(buf)),
			opt, fname)
	} else {
		libc.snprintf(end,
			C.size_t(buflen) - C.size_t(uintptr(end) - uintptr(buf)),
			cstring(" %s %s"), opt, fname)
	}
}

// Build a shell command from cmd + input/output redirections (allocated).
// Build a shell command from cmd + input/output redirections (allocated).
@(export)
make_filter_cmd :: proc "c"(cmd: cstring, itmp: cstring, otmp: cstring, do_in: bool) -> cstring {
	sh_tail := invocation_path_tail(p_sh, nil)
	is_fish_shell := libc.strncmp(sh_tail, cstring("fish"), 4) == 0
	is_pwsh := libc.strncmp(sh_tail, cstring("pwsh"), 4) == 0 ||
		libc.strncmp(sh_tail, cstring("powershell"), 10) == 0

	total := C.size_t(libc.strlen(cmd)) + 1 // cmd + NUL

	if is_fish_shell {
		total += 12 // "begin; ; end"
	} else if !is_pwsh {
		total += 2 // "()"
	}

	if itmp != nil {
		if is_pwsh {
			// "& { Get-Content  | &   }" (24) + #20530's 6.
			total += C.size_t(libc.strlen(itmp)) + 24 + 6
		} else {
			// " {  <   } " (9).
			total += C.size_t(libc.strlen(itmp)) + 9
		}
	}

	if do_in && is_pwsh {
		total += 11 // sizeof(" $input | ") keeps the NUL
	}

	if otmp != nil {
		total += C.size_t(libc.strlen(otmp)) +
			C.size_t(libc.strlen(cstring(p_srr_g))) + 2 // two spaces
	}

	buf := (^u8)(xmalloc(total))

	if is_pwsh {
		if itmp != nil {
			xstrlcpy_o(cstring(buf), cstring("& { Get-Content "), total - 1)
			_xstrlcat(cstring(buf), itmp, total - 1)
			_xstrlcat(cstring(buf), cstring(" | & "), total - 1)
			_xstrlcat(cstring(buf), cmd, total - 1)
			_xstrlcat(cstring(buf), cstring(" }"), total - 1)
		} else if do_in {
			xstrlcpy_o(cstring(buf), cstring(" $input | "), total - 1)
			_xstrlcat(cstring(buf), cmd, total)
		} else {
			xstrlcpy_o(cstring(buf), cmd, total)
		}
	} else {
		// Delimiters for concatenated commands with redirections.
		if itmp != nil || otmp != nil {
			if is_fish_shell {
				libc.snprintf(buf, total, cstring("begin; %s; end"), cmd)
			} else {
				libc.snprintf(buf, total, cstring("(%s)"), cmd)
			}
		} else {
			xstrlcpy_o(cstring(buf), cmd, total)
		}

		if itmp != nil {
			_xstrlcat(cstring(buf), cstring(" < "), total - 1)
			_xstrlcat(cstring(buf), itmp, total - 1)
		}
		// MSWIN pipe branch dropped (Linux-only port).
	}
	if otmp != nil {
		append_redir(buf, total, cstring(p_srr_g), otmp)
	}
	return transmute(cstring)(buf)
}

// ":w !cmd" error helper: restore cursor, no wait-return (C "error:" block).
do_filter_error_o :: proc "c"(cursor_save: Pos_T) {
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = cursor_save
	no_wait_return -= 1
	if !ui_has(K_UIMESSAGES_O) {
		wait_return(0)
	}
}

// Filter lines [line1, line2] through shell command "cmd" (C static).
// do_in: write lines to stdin; do_out: replace lines with stdout.
do_filter_o :: proc "c"(line1: C.int, line2: C.int, eap: rawptr, cmd: ^u8, do_in: bool, do_out: bool) {
	itmp: ^u8 = nil
	otmp: ^u8 = nil
	old_curbuf := curbuf
	shell_flags: C.int = 0
	orig_start := (^Pos_T)(uintptr(curbuf) + B_OP_START)^
	orig_end := (^Pos_T)(uintptr(curbuf) + B_OP_END)^
	stmp := p_stmp_g

	if ([^]u8)(cmd)[0] == 0 { // no filter command
		return
	}

	save_cmod_flags := cmdmod_cmod_flags
	// Disable lockmarks: needed to propagate changed regions for
	// foldUpdate(), linecount, etc.
	cmdmod_cmod_flags &= ~C.int(CMOD_KEEPMARKS_O)

	cursor_save := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	linecount := line2 - line1 + 1
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line1
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	changed_line_abv_curs_r()
	invalidate_botline_win_r(curwin)

	// Temp files: 1. names 2. write lines 3. run filter 4. read output
	// 5. delete originals 6. remove temps. Pipes skip the temp steps.
	// (Steps 1-2 write input; steps 4-5 replace with output.)

	if do_out {
		shell_flags |= KSHELLOPT_DOOUT_O
	}

	fend := false // jump to filterend tail
	if !do_in && do_out && stmp == 0 {
		// Pipe for stdout, no temp file.
		shell_flags |= KSHELLOPT_READ_O
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line2
	} else if do_in && !do_out && stmp == 0 {
		// Pipe for stdin, no temp file.
		shell_flags |= KSHELLOPT_WRITE_O
		(^C.int)(uintptr(curbuf) + B_OP_START)^ = line1
		(^C.int)(uintptr(curbuf) + B_OP_END)^ = line2
	} else if do_in && do_out && stmp == 0 {
		// Pipes both ways, no temp files.
		shell_flags |= KSHELLOPT_READ_O | KSHELLOPT_WRITE_O
		(^C.int)(uintptr(curbuf) + B_OP_START)^ = line1
		(^C.int)(uintptr(curbuf) + B_OP_END)^ = line2
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line2
	} else {
		if do_in {
			itmp = transmute(^u8)(vim_tempname())
			if itmp == nil {
				emsg(cstring(E483_S))
				fend = true
			}
		}
		if !fend && do_out {
			otmp = transmute(^u8)(vim_tempname())
			if otmp == nil {
				emsg(cstring(E483_S))
				fend = true
			}
		}
	}

	// Temp-file messages are not shown (uninformative, unlike Vi).
	no_wait_return += 1 // don't call wait_return() while busy
	if !fend && itmp != nil &&
		buf_write_r(curbuf, cstring(itmp), nil, line1, line2, eap, false,
			false, false, true) == FAIL {
		if !ui_has(K_UIMESSAGES_O) {
			msg_putchar('\n') // keep message from buf_write()
		}
		no_wait_return -= 1
		if !aborting_r() {
			// Will call wait_return().
			semsg_safe(cstring(E482_S), transmute(rawptr)(itmp))
		}
		fend = true
	}
	if !fend && curbuf != old_curbuf {
		fend = true
	}

	if !fend {
		if !do_out && !ui_has(K_UIMESSAGES_O) {
			msg_putchar('\n')
		}

		// Shell command in allocated memory.
		cmd_buf := make_filter_cmd(cstring(cmd), cstring(itmp), cstring(otmp),
			do_in)
		ui_cursor_goto_r(Rows - 1, 0)

		if do_out {
			if u_save(line2, line2 + 1) == FAIL {
				xfree(transmute(rawptr)(cmd_buf))
				fend = true
			} else {
				redraw_curbuf_later_r(UPD_VALID_O)
			}
		}
		if !fend {
			read_linecount := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^

			// kShellOptDoOut flag: output is being redirected.
			call_shell(transmute(^u8)(cmd_buf), KSHELLOPT_FILTER_O | shell_flags, nil)
			xfree(transmute(rawptr)(cmd_buf))

			did_check_timestamps_g = false
			need_check_timestamps_g = true

			// Useful output may exist despite interrupt: reset got_int
			// so readfile() won't cancel reading.
			os_breakcheck()
			got_int = false

			if do_out {
				if otmp != nil {
					if readfile_r(cstring(otmp), nil, line2, 0, MAXLNUM,
						eap, READ_FILTER_O, false) != OK {
						if !aborting_r() {
							msg_putchar('\n')
							semsg_safe(cstring(E485_S),
								transmute(rawptr)(otmp))
						}
						do_filter_error_o(cursor_save)
						fend = true
					} else if curbuf != old_curbuf {
						fend = true
					}
				}
				if !fend {
					read_linecount = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ -
						read_linecount

					if (shell_flags & KSHELLOPT_READ_O) != 0 {
						(^C.int)(uintptr(curbuf) + B_OP_START)^ = line2 + 1
						(^C.int)(uintptr(curbuf) + B_OP_END)^ =
							(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
						appended_lines_mark_r(line2, read_linecount)
					}

					if do_in {
						if (cmdmod_cmod_flags & CMOD_KEEPMARKS_O) != 0 ||
							vim_strchr_c(p_cpo, C.int('R')) == nil {
							// TODO(bfredl): extmarks inactive here. Columns
							// mismatch: assume end-of-line changes.
							if read_linecount >= linecount {
								// Marks from old lines to new lines.
								mark_adjust(line1, line2, linecount, 0,
									kExtmarkNOOP)
							} else {
								// Marks to new lines; deleted-line marks
								// are deleted.
								mark_adjust(line1, line1 + read_linecount - 1,
									linecount, 0, kExtmarkNOOP)
								mark_adjust(line1 + read_linecount, line2,
									MAXLNUM, 0, kExtmarkNOOP)
							}
						}

						// Cursor on first filtered line (":range!cmd").
						// Adjust '[ and '] (set by buf_write()).
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = line1
						del_lines_r(linecount, true)
						if read_linecount == 0 {
							// No output: clamp '[ and '] to a valid line.
							op_lnum := min(line1,
								(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^)
							(^C.int)(uintptr(curbuf) + B_OP_START)^ = op_lnum
							(^C.int)(uintptr(curbuf) + B_OP_END)^ = op_lnum
							(^C.int)(uintptr(curbuf) + B_OP_START + 4)^ = 0
							(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = 0
						} else {
							(^C.int)(uintptr(curbuf) + B_OP_START)^ -= linecount
							(^C.int)(uintptr(curbuf) + B_OP_END)^ -= linecount
						}
						write_lnum_adjust_r(-linecount)
						foldUpdate_r(curwin,
							(^C.int)(uintptr(curbuf) + B_OP_START)^,
							(^C.int)(uintptr(curbuf) + B_OP_END)^)
					} else {
						// Cursor on last new line (":r !cmd").
						linecount = (^C.int)(uintptr(curbuf) + B_OP_END)^ -
							(^C.int)(uintptr(curbuf) + B_OP_START)^ + 1
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ =
							(^C.int)(uintptr(curbuf) + B_OP_END)^
					}

					beginline(BL_WHITE | BL_FIX) // first non-blank
					no_wait_return -= 1

					if i64(linecount) > p_report {
						if do_in {
							filt_fmt := cstring("%ld lines filtered")
							if linecount == 1 {
								filt_fmt = cstring("%ld line filtered")
							}
							libc.snprintf(&msg_buf_g[0],
								C.size_t(MSG_BUF_LEN_O), filt_fmt,
								C.longlong(linecount))
							if msg_msg(cstring(&msg_buf_g[0]), 0) &&
								!msg_scroll {
								// Save message for after redraw.
								set_keep_msg_r(cstring(&msg_buf_g[0]), 0)
							}
						} else {
							msgmore_r(linecount)
						}
					}
				}
			} else {
				do_filter_error_o(cursor_save)
			}
		}
	}

	// filterend: always runs.
	cmdmod_cmod_flags = save_cmod_flags
	if curbuf != old_curbuf {
		no_wait_return -= 1
		emsg(cstring(E135_S))
	} else if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) != 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = orig_start
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = orig_end
	}

	if itmp != nil {
		os_remove(cstring(itmp))
	}
	if otmp != nil {
		os_remove(cstring(otmp))
	}
	xfree(transmute(rawptr)(itmp))
	xfree(transmute(rawptr)(otmp))
}

// ── Batch 31b: do_bang/do_shell + prevcmd (activates do_filter_o) ───────────
// (free_prev_shellcmd is #ifdef EXITFREE — skipped like free_titles.)

EVENT_SHELLCMDPOST_O :: 101
E34_S :: "E34: No previous command"

foreign _ {
	@(link_name = "AppendToRedobuff")
	AppendToRedobuff_r :: proc "c"(s: cstring) ---
	@(link_name = "AppendToRedobuffLit")
	AppendToRedobuffLit_r :: proc "c"(str: cstring, len: C.int) ---
	@(link_name = "p_warn")
	p_warn_g: C.int
	@(link_name = "msg_didout")
	msg_didout_g: bool
	@(link_name = "bangredo")
	bangredo_g: bool
}

@(private="file")
prevcmd_f: ^u8

// Bangs in the argument are replaced with the previous command (C static).
prevcmd_is_set_o :: proc "c"() -> bool {	if prevcmd_f == nil {
		emsg(cstring(E34_S))
		return false
	}
	return true
}

// Remember the argument with ! replaced (:!/:range!).
@(export)
do_bang :: proc "c"(addr_count: C.int, eap: rawptr, forceit: bool, do_in: bool, do_out: bool) {
	arg := (^cstring)(uintptr(eap))^ // command
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	newcmd: ^u8 = nil
	free_newcmd := false
	scroll_save := msg_scroll

	// Disallow shell commands in secure mode.
	if check_secure() {
		return
	}

	if addr_count == 0 { // :!
		msg_scroll = false // don't scroll here
		autowrite_all()
		msg_scroll = scroll_save
	}

	// Embedded bang (":!<cmd> ! [args]"); ":!!" via forceit.
	ins_prevcmd := forceit

	// Skip leading white space (strange errors with some shells).
	trailarg := skipwhite(arg)
	for trailarg != nil {
		l := C.size_t(libc.strlen(trailarg)) + 1
		if newcmd != nil {
			l += C.size_t(libc.strlen(cstring(newcmd)))
		}
		if ins_prevcmd {
			if !prevcmd_is_set_o() {
				xfree(transmute(rawptr)(newcmd))
				return
			}
			l += C.size_t(libc.strlen(cstring(prevcmd_f)))
		}
		t := (^u8)(xmalloc(l))
		([^]u8)(t)[0] = 0
		if newcmd != nil {
			libc.strcat(([^]u8)(t), cstring(newcmd))
		}
		if ins_prevcmd {
			libc.strcat(([^]u8)(t), cstring(prevcmd_f))
		}
		p := (^u8)(uintptr(t) + uintptr(libc.strlen(cstring(t))))
		libc.strcat(([^]u8)(t), trailarg)
		xfree(transmute(rawptr)(newcmd))
		newcmd = t

		// Scan for '!' (previous command); "\!" becomes "!".
		trailarg = nil
		for ([^]u8)(p)[0] != 0 {
			if ([^]u8)(p)[0] == '!' {
				if uintptr(p) > uintptr(newcmd) &&
					([^]u8)((^u8)(uintptr(p) - 1))[0] == '\\' {
					libc.memmove(transmute(rawptr)((^u8)(uintptr(p) - 1)),
						transmute(rawptr)(p),
						C.size_t(libc.strlen(cstring(p))) + 1)
				} else {
					trailarg = cstring((^u8)(uintptr(p) + 1))
					([^]u8)(p)[0] = 0
					ins_prevcmd = true
					break
				}
			}
			p = (^u8)(uintptr(p) + 1)
		}
	}

	// Only set prevcmd with a command to run, otherwise keep it.
	if libc.strlen(cstring(newcmd)) > 0 {
		xfree(transmute(rawptr)(prevcmd_f))
		prevcmd_f = newcmd
	} else {
		free_newcmd = true
	}

	done := false
	if bangredo_g { // put cmd in redo buffer for ! command
		if !prevcmd_is_set_o() {
			done = true
		} else {
			// Reescape %/# so redo doesn't substitute the buffer name.
			cmd_esc := vim_strsave_escaped_c(prevcmd_f,
				transmute(^u8)(cstring("%#")))
			AppendToRedobuffLit_r(cstring(cmd_esc), -1)
			xfree(transmute(rawptr)(cmd_esc))
			AppendToRedobuff_r(cstring("\n"))
			bangredo_g = false
		}
	}
	if !done {
		// Quotes around the command, for shells that need them.
		if ([^]u8)(p_shq_g)[0] != 0 {
			if free_newcmd {
				xfree(transmute(rawptr)(newcmd))
			}
			newcmd = (^u8)(xmalloc(C.size_t(libc.strlen(cstring(prevcmd_f))) +
				2 * C.size_t(libc.strlen(cstring(p_shq_g))) + 1))
			xstrlcpy_o(cstring(newcmd), cstring(p_shq_g),
				C.size_t(libc.strlen(cstring(prevcmd_f))) +
				2 * C.size_t(libc.strlen(cstring(p_shq_g))) + 1)
			_xstrlcat(cstring(newcmd), cstring(prevcmd_f),
				C.size_t(libc.strlen(cstring(prevcmd_f))) +
				2 * C.size_t(libc.strlen(cstring(p_shq_g))) + 1)
			_xstrlcat(cstring(newcmd), cstring(p_shq_g),
				C.size_t(libc.strlen(cstring(prevcmd_f))) +
				2 * C.size_t(libc.strlen(cstring(p_shq_g))) + 1)
			free_newcmd = true
		}
		if addr_count == 0 { // :!
			// Echo the command.
			msg_start()
			msg_ext_no_fast()
			msg_ext_set_kind(cstring("shell_cmd"))
			msg_putchar(':')
			msg_putchar('!')
			msg_outtrans(cstring(newcmd), 0, false)
			msg_clr_eos_r()
			ui_cursor_goto_r(msg_row, msg_col)

			do_shell(newcmd, 0)
		} else { // :range!
			// May recurse into do_bang() via autocommands.
			do_filter_o(line1, line2, eap, newcmd, do_in, do_out)
			apply_autocmds(EVENT_SHELLFILTERPOST_O, nil, nil, false, curbuf)
		}
	}

	// theend:
	if free_newcmd {
		xfree(transmute(rawptr)(newcmd))
	}
}

// Call a shell to execute a command (NULL: interactive shell).
@(export)
do_shell :: proc "c"(cmd: ^u8, flags: C.int) {
	// Disallow shell commands in secure mode.
	if check_secure() {
		msg_end()
		return
	}

	// Autocommand output on the current screen (no type-return below).
	msg_putchar('\r') // start of line
	msg_putchar('\n') // may shift screen one line up

	// Warning before calling the shell.
	if p_warn_g != 0 && !autocmd_busy_g && msg_silent == 0 {
		buf := firstbuf
		for buf != nil {
			if bufIsChanged(buf) {
				msg_puts(cstring("[No write since last change]\n"))
				break
			}
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
	}

	// Required when '\n' issued a terminal "delete line 1".
	ui_cursor_goto_r(msg_row, msg_col)
	call_shell(cmd, flags, nil)
	if msg_silent == 0 {
		msg_didout_g = true
	}
	did_check_timestamps_g = false
	need_check_timestamps_g = true

	// End of screen: avoids wait_return() overwriting command output.
	msg_row = Rows - 1
	msg_col = 0

	apply_autocmds(EVENT_SHELLCMDPOST_O, nil, nil, false, curbuf)
}

// ── Batch 32: :print/:list/:number (print_line/print_line_no_prefix) ────────

foreign _ {
	@(link_name = "number_width")
	number_width_r :: proc "c"(wp: rawptr) -> C.int ---
	// silent_mode already in main.odin; info_message in option.odin — reuse.
}

// Start a new message only once during :global (C static).
@(private="file")
global_need_msg_kind_f: bool

// Print line "lnum" with optional number prefix.
@(export)
print_line_no_prefix :: proc "c"(lnum: C.int, use_number: bool, list: bool) {
	numbuf: [30]u8

	if (^C.int)(uintptr(curwin) + W_P_NU_OFF)^ != 0 || use_number {
		libc.snprintf(&numbuf[0], C.size_t(30), cstring("%*d "),
			number_width_r(curwin), lnum)
		msg_puts_hl_r(cstring(&numbuf[0]), HLF_N_S + 1, false)
	}
	msg_prt_line_r(ml_get(lnum), list)
}

// Print a text line (also in silent/batch mode).
@(export)
print_line :: proc "c"(lnum: C.int, use_number: bool, list: bool, first: bool) {
	save_silent := silent_mode

	// Apply :filter /pat/.
	if message_filtered(cstring(ml_get(lnum))) {
		return
	}

	silent_mode = false
	info_message_g2 = true // use stdout, not stderr
	if ((global_busy == 0 || global_need_msg_kind_f) && first) {
		msg_start()
		msg_ext_set_kind(cstring("list_cmd"))
		global_need_msg_kind_f = false
	} else if !save_silent {
		msg_putchar('\n') // no trailing newline with regular messaging
	}
	print_line_no_prefix(lnum, use_number, list)
	if save_silent {
		msg_putchar('\n') // batch message always ends in newline
		silent_mode = save_silent
	}
	info_message_g2 = false
}

// ── Batch 33: :append/:insert/:change/:z ────────────────────────────────────

EXARG_FLAGS_OFF :: 96
EXFLAG_LIST_O :: 0x01
EXFLAG_NR_O :: 0x02
W_P_SCR_ABS :: 1040 // win_T.w_p_scr (cc-probed)
CMD_CHANGE_O :: 43
CMD_APPEND_O :: 0
E144_S :: "E144: Non-numeric argument to :z"

foreign _ {
	@(link_name = "get_indent_lnum")
	get_indent_lnum_r :: proc "c"(lnum: C.int) -> C.int ---
	@(link_name = "appended_lines")
	appended_lines_r :: proc "c"(lnum: C.int, count: C.int) ---
	// p_window_g already in window.odin — reuse.
}

@(private="file")
append_indent_f: C.int

// ":insert" and ":append", also used by ":change".
@(export)
ex_append :: proc "c"(eap: rawptr) {
	theline: ^u8 = nil
	did_undo := false
	lnum := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	indent: C.int = 0
	p: ^u8 = nil
	empty := ((^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O) != 0
	arg := (^cstring)(uintptr(eap))^

	// The ! flag toggles autoindent.
	if (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 {
		ai := (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^
		(^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ = ai == 0 ? 1 : 0
	}

	// First autoindent comes from the line we start on.
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ != CMD_CHANGE_O &&
		(^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 && lnum > 0 {
		append_indent_f = get_indent_lnum_r(lnum)
	}

	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ != CMD_APPEND_O {
		lnum -= 1
	}

	// Empty buffer: delete the dummy line.
	if empty && lnum == 1 {
		lnum = 0
	}

	State = MODE_INSERT // behave like in Insert mode
	if (^C.longlong)(uintptr(curbuf) + B_P_IMINSERT_OFF)^ == B_IMODE_LMAP {
		State |= MODE_LANGMAP
	}

	for {
		msg_scroll = true
		need_wait_return_g = false
		if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 {
			if append_indent_f >= 0 {
				indent = append_indent_f
				append_indent_f = -1
			} else if lnum > 0 {
				indent = get_indent_lnum_r(lnum)
			}
		}
		if ([^]u8)(transmute(^u8)(arg))[0] == '|' {
			// Text after the trailing bar.
			theline = xstrdup_o((^u8)(uintptr(transmute(^u8)(arg)) + 1))
			([^]u8)(transmute(^u8)(arg))[0] = 0
		} else {
			getline_fn_raw := (^rawptr)(uintptr(eap) + 168)^
			if getline_fn_raw == nil {
				// No getline(): use the following lines (ends at end).
				nextcmd := (^rawptr)(uintptr(eap) + 32)^
				if nextcmd == nil {
					break
				}
				nc := (^u8)(nextcmd)
				p = vim_strchr(nc, C.int('\n'))
				if p == nil {
					p = (^u8)(uintptr(nc) + uintptr(libc.strlen(cstring(nc))))
				}
				theline = xmemdupz_o2(nc, C.size_t(uintptr(p) - uintptr(nc)))
				if ([^]u8)(p)[0] != 0 {
					p = (^u8)(uintptr(p) + 1)
				} else {
					p = nil
				}
				(^rawptr)(uintptr(eap) + 32)^ = rawptr(p)
			} else {
				save_State := State
				// Avoid MODE_INSERT cursor shape from getline().
				State = MODE_CMDLINE_O
				cstack := (^rawptr)(uintptr(eap) + 184)^
				llevel: C.int = 0
				if cstack != nil {
					llevel = (^C.int)(uintptr(cstack) + 1260)^
				}
				getline_fn := transmute(proc "c"(c: C.int, cookie: rawptr,
					ind: C.int, b: bool) -> ^u8)(getline_fn_raw)
				theline = getline_fn(llevel > 0 ? -1 : 0,
					(^rawptr)(uintptr(eap) + 176)^, indent, true)
				State = save_State
			}
		}
		lines_left = Rows - 1
		if theline == nil {
			break
		}

		// Look for "." after automatic indent.
		vcol: C.int = 0
		p = theline
		for vcol < indent {
			if ([^]u8)(p)[0] == ' ' {
				vcol += 1
			} else if ([^]u8)(p)[0] == '\t' {
				vcol += 8 - vcol % 8
			} else {
				break
			}
			p = (^u8)(uintptr(p) + 1)
		}
		if (([^]u8)(p)[0] == '.' && ([^]u8)(p)[1] == 0) ||
			(!did_undo && u_save(lnum, lnum + 1 + (empty ? 1 : 0)) == FAIL) {
			xfree(transmute(rawptr)(theline))
			break
		}

		// No autoindent when nothing was typed.
		if ([^]u8)(p)[0] == 0 {
			([^]u8)(theline)[0] = 0
		}

		did_undo = true
		ml_append_c(lnum, theline, 0, false)
		if empty {
			// No marks below the inserted lines.
			appended_lines_r(lnum, 1)
		} else {
			appended_lines_mark_r(lnum, 1)
		}

		xfree(transmute(rawptr)(theline))
		lnum += 1

		if empty {
			ml_delete_r(2)
			empty = false
		}
	}
	State = MODE_NORMAL_O
	ui_cursor_shape_r()

	if (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 {
		ai := (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^
		(^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ = ai == 0 ? 1 : 0
	}

	// "start" is eap->line2+1 unless invalid (line2 at end, nothing
	// appended); "end" is lnum when appended, else same as "start".
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
		if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ <
			(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
			(^C.int)(uintptr(curbuf) + B_OP_START)^ =
				(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ + 1
		} else {
			(^C.int)(uintptr(curbuf) + B_OP_START)^ =
				(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		}
		if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ != CMD_APPEND_O {
			(^C.int)(uintptr(curbuf) + B_OP_START)^ -= 1
		}
		if (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ < lnum {
			(^C.int)(uintptr(curbuf) + B_OP_END)^ = lnum
		} else {
			(^C.int)(uintptr(curbuf) + B_OP_END)^ =
				(^C.int)(uintptr(curbuf) + B_OP_START)^
		}
		(^C.int)(uintptr(curbuf) + B_OP_START + 4)^ = 0
		(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = 0
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
	check_cursor_lnum_r(curwin)
	beginline(BL_SOL | BL_FIX)
}

// ":change" — delete lines, then append.
@(export)
ex_change :: proc "c"(eap: rawptr) {
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^

	if line2 >= line1 && u_save(line1 - 1, line2 + 1) == FAIL {
		return
	}

	// The ! flag toggles autoindent.
	fi := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0
	ai := (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0
	if (fi && !ai) || (!fi && ai) {
		append_indent_f = get_indent_lnum_r(line1)
	}

	lnum := line2
	for lnum >= line1 {
		if ((^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O) != 0 {
			break // nothing to delete
		}
		ml_delete_r(line1)
		lnum -= 1
	}

	// Cursor must not be beyond end of file now.
	check_cursor_lnum_r(curwin)
	deleted_lines_mark_r(line1, line2 - lnum)

	// ":append" on the line above the deleted lines.
	(^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ = line1
	ex_append(eap)
}

// ":z" — print a window of lines around line2.
@(export)
ex_z :: proc "c"(eap: rawptr) {
	bigness: C.longlong = 0
	minus := 0
	start, end, curs: C.int = 0, 0, 0
	lnum := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^

	// Vi compatible: ":z!" uses display height, no count uses 'scroll'.
	if (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 {
		bigness = C.longlong(Rows) - 1
	} else if firstwin == lastwin_g {
		bigness = C.longlong((^C.longlong)(uintptr(curwin) + W_P_SCR_ABS)^) * 2
	} else {
		bigness = C.longlong((^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^) - 3
	}
	if bigness < 1 {
		bigness = 1
	}

	arg := (^cstring)(uintptr(eap))^
	x := transmute(^u8)(arg)
	kind := x
	if ([^]u8)(x)[0] == '-' || ([^]u8)(x)[0] == '+' ||
		([^]u8)(x)[0] == '=' || ([^]u8)(x)[0] == '^' ||
		([^]u8)(x)[0] == '.' {
		x = (^u8)(uintptr(x) + 1)
	}
	for ([^]u8)(x)[0] == '-' || ([^]u8)(x)[0] == '+' {
		x = (^u8)(uintptr(x) + 1)
	}

	if ([^]u8)(x)[0] != 0 {
		if !ascii_isdigit_o(([^]u8)(x)[0]) {
			emsg(cstring(E144_S))
			return
		}
		bigness = C.longlong(libc.atol(cstring(x)))

		// bigness could be < 0 on atol() overflow.
		if bigness > 2 * C.longlong((^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^) ||
			bigness < 0 {
			bigness = 2 * C.longlong((^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^)
		}

		p_window_g = bigness
		if ([^]u8)(kind)[0] == '=' {
			bigness += 2
		}
	}

	// '-'/' '+' count multiplies the distance.
	if ([^]u8)(kind)[0] == '-' || ([^]u8)(kind)[0] == '+' {
		for x = (^u8)(uintptr(kind) + 1); ([^]u8)(x)[0] == ([^]u8)(kind)[0]; {
			x = (^u8)(uintptr(x) + 1)
		}
	}

	k := ([^]u8)(kind)[0]
	if k == '-' {
		start = lnum - C.int(bigness) * C.int(uintptr(x) - uintptr(kind)) + 1
		end = start + C.int(bigness) - 1
		curs = end
	} else if k == '=' {
		start = lnum - (C.int(bigness) + 1) / 2 + 1
		end = lnum + (C.int(bigness) + 1) / 2 - 1
		curs = lnum
		minus = 1
	} else if k == '^' {
		start = lnum - C.int(bigness) * 2
		end = lnum - C.int(bigness)
		curs = lnum - C.int(bigness)
	} else if k == '.' {
		start = lnum - (C.int(bigness) + 1) / 2 + 1
		end = lnum + (C.int(bigness) + 1) / 2 - 1
		curs = end
	} else { // '+'
		start = lnum
		if k == '+' {
			start += C.int(bigness) * C.int(uintptr(x) - uintptr(kind) - 1) + 1
		} else if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ == 0 {
			start += 1
		}
		end = start + C.int(bigness) - 1
		curs = end
	}

	start = max(start, 1)
	end = min(end, (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^)
	curs = min(max(curs, 1), (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^)

	i := start
	for i <= end {
		if minus != 0 && i == lnum {
			msg_putchar('\n')

			j: C.int = 1
			for j < Columns {
				msg_putchar('-')
				j += 1
			}
		}

		print_line(i, ((^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ & EXFLAG_NR_O) != 0,
			((^C.int)(uintptr(eap) + EXARG_FLAGS_OFF)^ & EXFLAG_LIST_O) != 0, i == start)

		if minus != 0 && i == lnum {
			msg_putchar('\n')

			j: C.int = 1
			for j < Columns {
				msg_putchar('-')
				j += 1
			}
		}
		i += 1
	}

	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != curs {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = curs
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	}
	ex_no_reprint_g = true
}
