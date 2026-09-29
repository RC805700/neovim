package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// ex_session.c port: :mksession/:mkview/:mkexrc/:mkvimrc/:loadview.
// Publics are @(export); frame/win walkers are _o plains.

foreign _ {
	@(link_name = "vop_flags")
	vop_flags_g: C.uint
	@(link_name = "makemap")
	makemap_e :: proc "c" (fd: ^libc.FILE, buf: rawptr) -> C.int ---
	@(link_name = "do_source")
	do_source_e :: proc "c" (fname: cstring, check_other: bool, is_vimrc: C.int, ret_sid: ^C.int) -> C.int ---
}

kOptSsopFlagBuffers_O :: 0x01
kOptSsopFlagWinpos_O :: 0x02
kOptSsopFlagResize_O :: 0x04
kOptSsopFlagWinsize_O :: 0x08
kOptSsopFlagLocaloptions_O :: 0x10
kOptSsopFlagOptions_O :: 0x20
kOptSsopFlagHelp_O :: 0x40
kOptSsopFlagBlank_O :: 0x80
kOptSsopFlagGlobals_O :: 0x100
kOptSsopFlagSlash_O :: 0x200
kOptSsopFlagUnix_O :: 0x400
kOptSsopFlagSesdir_O :: 0x800
kOptSsopFlagCurdir_O :: 0x1000
kOptSsopFlagFolds_O :: 0x2000
kOptSsopFlagCursor_O :: 0x4000
kOptSsopFlagTabpages_O :: 0x8000
kOptSsopFlagTerminal_O :: 0x10000
kOptSsopFlagSkiprtp_O :: 0x20000

VIMRC_FILE_S :: ".nvimrc"
SESSION_FILE_S :: "Session.vim"
EXRC_FILE_S :: ".exrc"

E_WRITE_S :: "E80: Error while writing"
E_PREVDIR_S :: "E459: Cannot go back to previous directory"

CMD_mksession_O :: 284
CMD_mkview_O :: 287
CMD_mkvimrc_O :: 286
CMD_loadview_O :: 253

VV_THIS_SESSION_O :: 7
EVENT_SESSIONWRITEPOST_O :: 99
EVENT_SESSIONWRITEPRE_O :: 100
VSE_NONE_O :: 0
DOSO_NONE_O :: 0
kCdCauseOther_O :: -1

@(private = "file")
did_lcd_g: bool

// Write a newline to fd.
@(export)
put_eol :: proc "c" (fd: ^libc.FILE) -> C.int {
	context = runtime.default_context()
	if libc.fputc(10, fd) < 0 {
		return FAIL
	}
	return OK
}

// Write a line + newline to fd.
@(export)
put_line :: proc "c" (fd: ^libc.FILE, s: cstring) -> C.int {
	context = runtime.default_context()
	if libc.fprintf(fd, cstring("%s\n"), s) < 0 {
		return FAIL
	}
	return OK
}

// Restore cursor column for a view.
put_view_curpos_o :: proc "c" (fd: ^libc.FILE, wp: rawptr, spaces: cstring) -> C.int {
	context = runtime.default_context()
	r: C.int
	if (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^ == MAXCOL {
		r = libc.fprintf(fd, cstring("%snormal! $\n"), spaces)
	} else {
		r = libc.fprintf(fd, cstring("%snormal! 0%d|\n"), spaces, (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ + 1)
	}
	if r >= 0 {
		return 1
	}
	return 0
}

// Non-zero if window wp goes into the session.
ses_do_win_o :: proc "c" (wp: rawptr) -> C.int {
	context = runtime.default_context()
	if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		return 0
	}
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if (^rawptr)(uintptr(buf) + B_FNAME)^ == nil || (!(^bool)(uintptr(buf) + B_TERMINAL_OFF)^ && bt_nofilename(buf)) {
		return C.int(ssop_flags_g & kOptSsopFlagBlank_O)
	}
	if bt_help(buf) {
		return C.int(ssop_flags_g & kOptSsopFlagHelp_O)
	}
	if bt_terminal(buf) {
		return C.int(ssop_flags_g & kOptSsopFlagTerminal_O)
	}
	return 1
}

// True if frame fr holds a window going into the session.
ses_do_frame_o :: proc "c" (fr: rawptr) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(fr) + FR_LAYOUT_OFF)^ == FR_LEAF_O {
		return ses_do_win_o((^rawptr)(uintptr(fr) + FR_WIN_OFF)^) != 0
	}
	frc := (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
	for frc != nil {
		if ses_do_frame_o(frc) {
			return true
		}
		frc = (^rawptr)(uintptr(frc) + FR_NEXT_OFF)^
	}
	return false
}

// First frame at/under fr with a session window, or nil.
ses_skipframe_o :: proc "c" (fr: rawptr) -> rawptr {
	context = runtime.default_context()
	frc := fr
	for frc != nil {
		if ses_do_frame_o(frc) {
			break
		}
		frc = (^rawptr)(uintptr(frc) + FR_NEXT_OFF)^
	}
	return frc
}

// Write commands to recreate frame splits.
ses_win_rec_o :: proc "c" (fd: ^libc.FILE, fr: rawptr) -> C.int {
	context = runtime.default_context()
	count: C.int = 0
	if (^C.int)(uintptr(fr) + FR_LAYOUT_OFF)^ == FR_LEAF_O {
		return OK
	}
	frc := ses_skipframe_o((^rawptr)(uintptr(fr) + FR_CHILD_OFF)^)
	if frc != nil {
		for {
			frc = ses_skipframe_o((^rawptr)(uintptr(frc) + FR_NEXT_OFF)^)
			if frc == nil {
				break
			}
			split := cstring("vsplit\n")
			if (^C.int)(uintptr(fr) + FR_LAYOUT_OFF)^ == FR_COL_O {
				split = cstring("split\n")
			}
			if libc.fprintf(fd, cstring("%s%s"), cstring("wincmd _ | wincmd |\n"), split) < 0 {
				return FAIL
			}
			count += 1
		}
	}
	if count > 0 {
		back := cstring("%dwincmd h\n")
		if (^C.int)(uintptr(fr) + FR_LAYOUT_OFF)^ == FR_COL_O {
			back = cstring("%dwincmd k\n")
		}
		if libc.fprintf(fd, back, count) < 0 {
			return FAIL
		}
	}
	frc = ses_skipframe_o((^rawptr)(uintptr(fr) + FR_CHILD_OFF)^)
	for frc != nil {
		if ses_win_rec_o(fd, frc) != OK {
			return FAIL
		}
		frc = ses_skipframe_o((^rawptr)(uintptr(frc) + FR_NEXT_OFF)^)
		if frc != nil && put_line(fd, cstring("wincmd w")) == FAIL {
			return FAIL
		}
	}
	return OK
}

// Write window-size restore commands for one tab page.
ses_winsizes_o :: proc "c" (fd: ^libc.FILE, restore_size: bool, tab_firstwin: rawptr) -> C.int {
	context = runtime.default_context()
	if restore_size && (ssop_flags_g & kOptSsopFlagWinsize_O) != 0 {
		n: C.int = 0
		wp := tab_firstwin
		for wp != nil {
			if ses_do_win_o(wp) == 0 {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			n += 1
			h := (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ + (^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ + (^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^
			if h < (^C.int)(uintptr(topframe_g) + FR_HEIGHT_OFF)^ {
				if libc.fprintf(fd, cstring("exe '%dresize ' . ((&lines * %lld + %lld) / %lld)\n"), n, C.longlong((^C.int)(uintptr(wp) + W_HEIGHT_OFF)^), C.longlong(Rows) / 2, C.longlong(Rows)) < 0 {
					return FAIL
				}
			}
			if (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ < Columns {
				if libc.fprintf(fd, cstring("exe 'vert %dresize ' . ((&columns * %lld + %lld) / %lld)\n"), n, C.longlong((^C.int)(uintptr(wp) + W_WIDTH_OFF)^), C.longlong(Columns) / 2, C.longlong(Columns)) < 0 {
					return FAIL
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	} else {
		if put_line(fd, cstring("wincmd =")) == FAIL {
			return FAIL
		}
	}
	return OK
}

// Write an :argument list to the session file.
ses_arglist_o :: proc "c" (fd: ^libc.FILE, cmd: cstring, gap: ^Garray, fullname: bool, flagp: rawptr) -> C.int {
	context = runtime.default_context()
	if libc.fprintf(fd, cstring("%s\n%s\n"), cmd, cstring("%argdel")) < 0 {
		return FAIL
	}
	entries := ([^]Aentry_T)(gap.ga_data)
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		s := alist_name(rawptr(uintptr(entries) + uintptr(i) * size_of(Aentry_T)))
		if s != nil {
			use := s
			buf: ^u8 = nil
			if fullname {
				buf = (^u8)(xmalloc(C.size_t(MAXPATHL_O)))
				vim_FullName_e(transmute(cstring)(s), transmute(cstring)(buf), C.size_t(MAXPATHL_O), false)
				use = buf
			}
			fname_esc := ses_escape_fname_o(transmute(cstring)(use))
			if libc.fprintf(fd, cstring("$argadd %s\n"), transmute(cstring)(fname_esc)) < 0 {
				xfree(rawptr(fname_esc))
				xfree(rawptr(buf))
				return FAIL
			}
			xfree(rawptr(fname_esc))
			xfree(rawptr(buf))
		}
	}
	return OK
}

// Buffer name for the session file (short when cd is known).
ses_get_fname_o :: proc "c" (buf: rawptr, flagp: rawptr) -> ^u8 {
	context = runtime.default_context()
	sfname := (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^
	if sfname != nil && flagp == rawptr(&ssop_flags_g) && (ssop_flags_g & (kOptSsopFlagCurdir_O | kOptSsopFlagSesdir_O)) != 0 && p_acd_g == 0 && !did_lcd_g {
		return (^u8)(sfname)
	}
	return (^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^)
}

// Write a buffer name (+ newline) to the session file.
ses_fname_o :: proc "c" (fd: ^libc.FILE, buf: rawptr, flagp: rawptr, add_eol: bool) -> C.int {
	context = runtime.default_context()
	if ses_put_fname_o(fd, ses_get_fname_o(buf, flagp)) == FAIL {
		return FAIL
	}
	if add_eol && libc.fprintf(fd, cstring("\n")) < 0 {
		return FAIL
	}
	return OK
}

// Escape a file name for session writing (slash-fix + fnameescape).
ses_escape_fname_o :: proc "c" (name: cstring) -> ^u8 {
	context = runtime.default_context()
	sname := home_replace_save(nil, name)
	p := transmute(^u8)(sname)
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '\\' {
			([^]u8)(p)[0] = '/'
		}
		p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
	}
	esc := vim_strsave_fnameescape_e(sname, VSE_NONE_O)
	xfree(rawptr(sname))
	return esc
}

// Write an escaped file name (no newline).
ses_put_fname_o :: proc "c" (fd: ^libc.FILE, name: ^u8) -> C.int {
	context = runtime.default_context()
	p := ses_escape_fname_o(transmute(cstring)(name))
	retval: C.int = OK
	if fputs_o(transmute(cstring)(p), fd) < 0 {
		retval = FAIL
	}
	xfree(rawptr(p))
	return retval
}

// Write commands to restore the view of a window.
put_view_o :: proc "c" (fd: ^libc.FILE, wp: rawptr, tp: rawptr, add_edit: bool, flagp: rawptr, current_arg_idx: C.int) -> C.int {
	context = runtime.default_context()
	flags := (^C.uint)(flagp)^
	is_ssop := flagp == rawptr(&ssop_flags_g)
	is_vop := flagp == rawptr(&vop_flags_g)
	f: C.int
	did_next := false
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	do_cursor := is_ssop || (flags & kOptSsopFlagCursor_O) != 0
	if (^rawptr)(uintptr(wp) + W_ALIST_OFF)^ == rawptr(&global_alist_u8) {
		if put_line(fd, cstring("argglobal")) == FAIL {
			return FAIL
		}
	} else {
		fullname := is_vop || (flags & kOptSsopFlagCurdir_O) == 0 || (^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^ != nil || (^rawptr)(uintptr(wp) + W_LOCALDIR_OFF)^ != nil
		if ses_arglist_o(fd, cstring("arglocal"), (^Garray)(rawptr(win_alist_o(wp))), fullname, flagp) == FAIL {
			return FAIL
		}
	}
	idx := (^C.int)(uintptr(wp) + W_ARG_IDX_OFF)^
	if idx != current_arg_idx && idx < win_alist_o(wp).al_ga.ga_len && is_ssop {
		if libc.fprintf(fd, cstring("%lldargu\n"), C.longlong(idx) + 1) < 0 {
			return FAIL
		}
		did_next = true
	}
	if add_edit && (!did_next || (^bool)(uintptr(wp) + W_ARG_IDX_INVALID_OFF)^) {
		fname_esc := ses_escape_fname_o(transmute(cstring)(ses_get_fname_o(buf, flagp)))
		if bt_help(buf) {
			curtag: cstring = cstring("")
			ti := (^C.int)(uintptr(wp) + W_TAGSTACKIDX)^
			tl := (^C.int)(uintptr(wp) + W_TAGSTACKLEN_OFF)^
			if ti > 0 && ti <= tl {
				curtag = transmute(cstring)(rawptr(uintptr((^rawptr)(uintptr(wp) + W_TAGSTACK)^) + uintptr(ti - 1) * 64))
			}
			if put_line(fd, cstring("enew | setl bt=help")) == FAIL || libc.fprintf(fd, cstring("help %s"), curtag) < 0 || put_eol(fd) == FAIL {
				xfree(rawptr(fname_esc))
				return FAIL
			}
		} else if (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil && (!bt_nofilename(buf) || (^bool)(uintptr(buf) + B_TERMINAL_OFF)^) {
			if libc.fprintf(fd, cstring("if bufexists(fnamemodify(\"%s\", \":p\")) | buffer %s | else | edit %s | endif\nif &buftype ==# 'terminal'\n  silent file %s\nendif\n"), fname_esc, fname_esc, fname_esc, fname_esc) < 0 {
				xfree(rawptr(fname_esc))
				return FAIL
			}
		} else {
			if put_line(fd, cstring("enew")) == FAIL {
				xfree(rawptr(fname_esc))
				return FAIL
			}
			if (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil {
				if libc.fprintf(fd, cstring("file %s\n"), fname_esc) < 0 {
					xfree(rawptr(fname_esc))
					return FAIL
				}
			}
			do_cursor = false
		}
		xfree(rawptr(fname_esc))
	}
	if (^C.int)(uintptr(wp) + W_ALT_FNUM)^ != 0 {
		alt := buflist_findnr((^C.int)(uintptr(wp) + W_ALT_FNUM)^)
		if is_ssop && alt != nil && (^rawptr)(uintptr(alt) + B_FNAME)^ != nil && ([^]u8)((^rawptr)(uintptr(alt) + B_FNAME)^)[0] != 0 && (^C.int)(uintptr(alt) + B_P_BL_OFF)^ != 0 && !(bt_terminal(alt) && (ssop_flags_g & kOptSsopFlagTerminal_O) == 0) {
			if fputs_o(cstring("balt "), fd) < 0 || ses_fname_o(fd, alt, flagp, true) == FAIL {
				return FAIL
			}
		}
	}
	if (flags & (kOptSsopFlagOptions_O | kOptSsopFlagLocaloptions_O)) != 0 && makemap_e(fd, buf) == FAIL {
		return FAIL
	}
	save_curwin := curwin
	curwin = wp
	curbuf = (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if (flags & (kOptSsopFlagOptions_O | kOptSsopFlagLocaloptions_O)) != 0 {
		local_only := is_vop || (flags & kOptSsopFlagOptions_O) == 0
		f = makeset(fd, OPT_LOCAL_S, local_only)
	} else if (flags & kOptSsopFlagFolds_O) != 0 {
		f = makefoldset(fd)
	} else {
		f = OK
	}
	curwin = save_curwin
	curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	if f == FAIL {
		return FAIL
	}
	if (flags & kOptSsopFlagFolds_O) != 0 && (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil && (bt_normal(buf) || bt_help(buf)) {
		if put_folds(fd, wp) == FAIL {
			return FAIL
		}
	}
	if do_cursor {
		lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
		if (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ <= 0 {
			if libc.fprintf(fd, cstring("let s:l = %d\n"), lnum) < 0 {
				return FAIL
			}
		} else {
			if libc.fprintf(fd, cstring("let s:l = %d - ((%d * winheight(0) + %d) / %d)\n"), lnum, lnum - (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^, (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ / 2, (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) < 0 {
				return FAIL
			}
		}
		if libc.fprintf(fd, cstring("if s:l < 1 | let s:l = 1 | endif\nkeepjumps exe s:l\nnormal! zt\nkeepjumps %d\n"), lnum) < 0 {
			return FAIL
		}
		if (^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ == 0 {
			if put_line(fd, cstring("normal! 0")) == FAIL {
				return FAIL
			}
		} else {
			if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 && (^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^ > 0 && (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ > 0 {
				if libc.fprintf(fd, cstring("let s:c = %lld - ((%lld * winwidth(0) + %lld) / %lld)\nif s:c > 0\n  exe 'normal! ' . s:c . '|zs' . %lld . '|'\nelse\n"), C.longlong((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^) + 1, C.longlong((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ - (^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^), C.longlong((^C.int)(uintptr(wp) + W_WIDTH_OFF)^ / 2), C.longlong((^C.int)(uintptr(wp) + W_WIDTH_OFF)^), C.longlong((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^) + 1) < 0 || put_view_curpos_o(fd, wp, cstring("  ")) == FAIL || put_line(fd, cstring("endif")) == FAIL {
					return FAIL
				}
			} else if put_view_curpos_o(fd, wp, cstring("")) == FAIL {
				return FAIL
			}
		}
	}
	localdir := (^rawptr)(uintptr(wp) + W_LOCALDIR_OFF)^
	if localdir != nil && (flagp != rawptr(&vop_flags_g) || (flags & kOptSsopFlagCurdir_O) != 0) {
		if fputs_o(cstring("lcd "), fd) < 0 || ses_put_fname_o(fd, (^u8)(localdir)) < 0 || libc.fprintf(fd, cstring("\n")) < 0 {
			return FAIL
		}
		did_lcd_g = true
	}
	return OK
}

// Write session globals.
store_session_globals_o :: proc "c" (fd: ^libc.FILE) -> C.int {
	context = runtime.default_context()
	d := get_globvar_dict()
	ht := uintptr(d) + 16
	todo := (^C.size_t)(ht + 8)^
	hi := uintptr((^rawptr)(ht + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		vtype := (^C.int)(di)^
		dikey := transmute(cstring)(rawptr(uintptr(di) + 17))
		if (vtype == VAR_NUMBER || vtype == VAR_STRING) && var_flavour(dikey) == VAR_FLAVOUR_SESSION_O {
			p := vim_strsave_escaped_c(transmute(^u8)(tv_get_string((^Typval_T)(di))), transmute(^u8)(cstring("\\\"\n\r")))
			t := p
			for ([^]u8)(t)[0] != 0 {
				if ([^]u8)(t)[0] == '\n' {
					([^]u8)(t)[0] = 'n'
				} else if ([^]u8)(t)[0] == '\r' {
					([^]u8)(t)[0] = 'r'
				}
				t = (^u8)(uintptr(t) + 1)
			}
			q: C.int = ' '
			if vtype == VAR_STRING {
				q = '"'
			}
			if libc.fprintf(fd, cstring("let %s = %c%s%c"), dikey, q, transmute(cstring)(p), q) < 0 || put_eol(fd) == FAIL {
				xfree(rawptr(p))
				return FAIL
			}
			xfree(rawptr(p))
		} else if vtype == VAR_FLOAT && var_flavour(dikey) == VAR_FLAVOUR_SESSION_O {
			f := transmute(f64)((^Typval_T)(di).vval)
			sign: C.int = ' '
			if f < 0 {
				f = -f
				sign = '-'
			}
			if libc.fprintf(fd, cstring("let %s = %c%f"), dikey, sign, f) < 0 || put_eol(fd) == FAIL {
				return FAIL
			}
		}
	}
	return OK
}

// Write commands for restoring buffers, for :mksession.
makeopens_o :: proc "c" (fd: ^libc.FILE, dirnow: ^u8) -> C.int {
	context = runtime.default_context()
	only_save_windows := true
	restore_size := true
	edited_win: rawptr = nil
	tab_firstwin: rawptr = nil
	tab_topframe: rawptr = nil
	cur_arg_idx: C.int = 0
	next_arg_idx: C.int = 0
	if (ssop_flags_g & kOptSsopFlagBuffers_O) != 0 {
		only_save_windows = false
	}
	if put_line(fd, cstring("let v:this_session=expand(\"<sfile>:p\")")) == FAIL {
		return FAIL
	}
	if put_line(fd, cstring("doautoall SessionLoadPre")) == FAIL {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagGlobals_O) != 0 {
		if store_session_globals_o(fd) == FAIL {
			return FAIL
		}
	}
	if put_line(fd, cstring("silent only")) == FAIL {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagTabpages_O) != 0 && put_line(fd, cstring("silent tabonly")) == FAIL {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagSesdir_O) != 0 {
		if put_line(fd, cstring("exe \"cd \" . escape(expand(\"<sfile>:p:h\"), ' ')")) == FAIL {
			return FAIL
		}
	} else if (ssop_flags_g & kOptSsopFlagCurdir_O) != 0 {
		gd := globaldir_g
		if gd == nil {
			gd = rawptr(dirnow)
		}
		sname := home_replace_save(nil, transmute(cstring)(gd))
		fname_esc := ses_escape_fname_o(sname)
		if libc.fprintf(fd, cstring("cd %s\n"), transmute(cstring)(fname_esc)) < 0 {
			xfree(rawptr(fname_esc))
			xfree(rawptr(sname))
			return FAIL
		}
		xfree(rawptr(fname_esc))
		xfree(rawptr(sname))
	}
	if libc.fprintf(fd, cstring("%s"), cstring("if expand('%') == '' && !&modified && line('$') <= 1 && getline(1) == ''\n  let s:wipebuf = bufnr('%')\nendif\n")) < 0 {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagOptions_O) == 0 {
		if put_line(fd, cstring("let s:shortmess_save = &shortmess")) == FAIL {
			return FAIL
		}
	}
	if put_line(fd, cstring("set shortmess+=aoO")) == FAIL {
		return FAIL
	}
	buf := firstbuf
	for buf != nil {
		next := (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		if !(only_save_windows && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0) && !((^bool)(uintptr(buf) + B_HELP_OFF)^ && (ssop_flags_g & kOptSsopFlagHelp_O) == 0) && !(bt_terminal(buf) && (ssop_flags_g & kOptSsopFlagTerminal_O) == 0) && (^rawptr)(uintptr(buf) + B_FNAME)^ != nil && (^C.int)(uintptr(buf) + B_P_BL_OFF)^ != 0 {
			lnum: C.longlong = 1
			if (^C.int)(uintptr(buf) + 288)^ != 0 {
				slots := ([^]rawptr)((^rawptr)(uintptr(buf) + 288 + 16)^)
				wip := slots[0]
				lnum = C.longlong((^C.int)(uintptr(wip) + 8)^)
			}
			if libc.fprintf(fd, cstring("badd +%lld "), lnum) < 0 || ses_fname_o(fd, buf, rawptr(&ssop_flags_g), true) == FAIL {
				return FAIL
			}
		}
		buf = next
	}
	if ses_arglist_o(fd, cstring("argglobal"), (^Garray)(rawptr(&global_alist_u8)), (ssop_flags_g & kOptSsopFlagCurdir_O) == 0, rawptr(&ssop_flags_g)) == FAIL {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagResize_O) != 0 {
		if libc.fprintf(fd, cstring("set lines=%lld columns=%lld\n"), C.longlong(Rows), C.longlong(Columns)) < 0 {
			return FAIL
		}
	}
	restore_stal := false
	if p_stal_g == 1 && (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ != nil {
		if put_line(fd, cstring("set stal=2")) == FAIL {
			return FAIL
		}
		restore_stal = true
	}
	if (ssop_flags_g & kOptSsopFlagTabpages_O) != 0 {
		tp := first_tabpage
		for tp != nil {
			if (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^ != nil && put_line(fd, cstring("tabnew +setlocal\\ bufhidden=wipe")) == FAIL {
				return FAIL
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		if (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^ != nil && put_line(fd, cstring("tabrewind")) == FAIL {
			return FAIL
		}
	}
	restore_height_width := false
	tp := first_tabpage
	for tp != nil {
		need_tabnext := false
		cnr: C.int = 1
		if (ssop_flags_g & kOptSsopFlagTabpages_O) != 0 {
			if tp == curtab {
				tab_firstwin = firstwin
				tab_topframe = topframe_g
			} else {
				tab_firstwin = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
				tab_topframe = (^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^
			}
			if tp != first_tabpage {
				need_tabnext = true
			}
		} else {
			tp = curtab
			tab_firstwin = firstwin
			tab_topframe = topframe_g
		}
		wp := tab_firstwin
		for wp != nil {
			wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
			if ses_do_win_o(wp) != 0 && (^rawptr)(uintptr(wbuf) + B_FFNAME)^ != nil && !bt_help(wbuf) && !bt_nofilename(wbuf) {
				if need_tabnext && put_line(fd, cstring("tabnext")) == FAIL {
					return FAIL
				}
				need_tabnext = false
				if fputs_o(cstring("edit "), fd) < 0 || ses_fname_o(fd, wbuf, rawptr(&ssop_flags_g), true) == FAIL {
					return FAIL
				}
				if !(^bool)(uintptr(wp) + W_ARG_IDX_INVALID_OFF)^ {
					edited_win = wp
				}
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if need_tabnext && put_line(fd, cstring("tabnext")) == FAIL {
			return FAIL
		}
		if (^C.int)(uintptr(tab_topframe) + FR_LAYOUT_OFF)^ != FR_LEAF_O {
			if put_line(fd, cstring("let s:save_splitbelow = &splitbelow")) == FAIL {
				return FAIL
			}
			if put_line(fd, cstring("let s:save_splitright = &splitright")) == FAIL {
				return FAIL
			}
			if put_line(fd, cstring("set splitbelow splitright")) == FAIL {
				return FAIL
			}
			if ses_win_rec_o(fd, tab_topframe) == FAIL {
				return FAIL
			}
			if put_line(fd, cstring("let &splitbelow = s:save_splitbelow")) == FAIL {
				return FAIL
			}
			if put_line(fd, cstring("let &splitright = s:save_splitright")) == FAIL {
				return FAIL
			}
		}
		nr: C.int = 0
		wp = tab_firstwin
		for wp != nil {
			if ses_do_win_o(wp) != 0 {
				nr += 1
			} else if !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
				restore_size = false
			}
			if curwin == wp {
				cnr = nr
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		if tab_firstwin != nil && (^rawptr)(uintptr(tab_firstwin) + W_NEXT_OFF)^ != nil {
			if put_line(fd, cstring("wincmd t")) == FAIL {
				return FAIL
			}
			if !restore_height_width {
				if put_line(fd, cstring("let s:save_winminheight = &winminheight")) == FAIL {
					return FAIL
				}
				if put_line(fd, cstring("let s:save_winminwidth = &winminwidth")) == FAIL {
					return FAIL
				}
			}
			if libc.fprintf(fd, cstring("set winminheight=0\nset winheight=1\nset winminwidth=0\nset winwidth=1\n")) < 0 {
				return FAIL
			}
			restore_height_width = true
		}
		if nr > 1 && ses_winsizes_o(fd, restore_size, tab_firstwin) == FAIL {
			return FAIL
		}
		if (ssop_flags_g & kOptSsopFlagCurdir_O) != 0 && (^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^ != nil {
			if fputs_o(cstring("tcd "), fd) < 0 || ses_put_fname_o(fd, (^u8)((^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^)) < 0 || put_eol(fd) == FAIL {
				return FAIL
			}
			did_lcd_g = true
		}
		wp = tab_firstwin
		for wp != nil {
			if ses_do_win_o(wp) == 0 {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			if put_view_o(fd, wp, tp, wp != edited_win, rawptr(&ssop_flags_g), cur_arg_idx) == FAIL {
				return FAIL
			}
			if nr > 1 && put_line(fd, cstring("wincmd w")) == FAIL {
				return FAIL
			}
			next_arg_idx = (^C.int)(uintptr(wp) + W_ARG_IDX_OFF)^
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		cur_arg_idx = next_arg_idx
		if cnr > 1 && libc.fprintf(fd, cstring("%dwincmd w\n"), cnr) < 0 {
			return FAIL
		}
		if nr > 1 && ses_winsizes_o(fd, restore_size, tab_firstwin) == FAIL {
			return FAIL
		}
		if (ssop_flags_g & kOptSsopFlagTabpages_O) == 0 {
			break
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	if (ssop_flags_g & kOptSsopFlagTabpages_O) != 0 {
		if libc.fprintf(fd, cstring("tabnext %d\n"), tabpage_index(curtab)) < 0 {
			return FAIL
		}
	}
	if restore_stal && put_line(fd, cstring("set stal=1")) == FAIL {
		return FAIL
	}
	if libc.fprintf(fd, cstring("%s"), cstring("if exists('s:wipebuf') && len(win_findbuf(s:wipebuf)) == 0 && getbufvar(s:wipebuf, '&buftype') isnot# 'terminal'\n  silent exe 'bwipe ' . s:wipebuf\nendif\nunlet! s:wipebuf\n")) < 0 {
		return FAIL
	}
	if libc.fprintf(fd, cstring("set winheight=%lld winwidth=%lld\n"), p_wh_opt, p_wiw_opt) < 0 {
		return FAIL
	}
	if (ssop_flags_g & kOptSsopFlagOptions_O) != 0 {
		if libc.fprintf(fd, cstring("set shortmess=%s\n"), transmute(cstring)(p_shm)) < 0 {
			return FAIL
		}
	} else {
		if put_line(fd, cstring("let &shortmess = s:shortmess_save")) == FAIL {
			return FAIL
		}
	}
	if restore_height_width {
		if put_line(fd, cstring("let &winminheight = s:save_winminheight")) == FAIL {
			return FAIL
		}
		if put_line(fd, cstring("let &winminwidth = s:save_winminwidth")) == FAIL {
			return FAIL
		}
	}
	if libc.fprintf(fd, cstring("%s"), cstring("let s:sx = expand(\"<sfile>:p:r\").\"x.vim\"\nif filereadable(s:sx)\n  exe \"source \" . fnameescape(s:sx)\nendif\n")) < 0 {
		return FAIL
	}
	return OK
}

// View file name for the current buffer, or nil.
get_view_file_o :: proc "c" (c: u8) -> ^u8 {
	context = runtime.default_context()
	if (^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil {
		emsg(cstring(E_NONAME_S))
		return nil
	}
	sname := home_replace_save(nil, transmute(cstring)((^rawptr)(uintptr(curbuf) + B_FFNAME)^))
	len: uintptr = 0
	p := transmute(^u8)(sname)
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '=' || _vim_ispathsep(C.int(([^]u8)(p)[0])) {
			len += 1
		}
		p = (^u8)(uintptr(p) + 1)
	}
	retval := ([^]u8)(xmalloc(C.size_t(len) + C.size_t(libc.strlen(sname)) + C.size_t(libc.strlen(transmute(cstring)(p_vdir_opt))) + 9))
	libc.strcpy(retval, transmute(cstring)(p_vdir_opt))
	add_pathsep(transmute(^u8)(retval))
	off := uintptr(libc.strlen(transmute(cstring)(retval)))
	p = transmute(^u8)(sname)
	for ([^]u8)(p)[0] != 0 {
		ch := ([^]u8)(p)[0]
		if ch == '=' {
			retval[off] = '='
			off += 1
			retval[off] = '='
			off += 1
		} else if _vim_ispathsep(C.int(ch)) {
			retval[off] = '='
			off += 1
			retval[off] = '+'
			off += 1
		} else {
			retval[off] = ch
			off += 1
		}
		p = (^u8)(uintptr(p) + 1)
	}
	retval[off] = '='
	off += 1
	retval[off] = c
	off += 1
	xmemcpyz(rawptr(uintptr(rawptr(retval)) + off), transmute(rawptr)(cstring(".vim")), 4)
	xfree(rawptr(sname))
	return transmute(^u8)(retval)
}

// ":loadview [nr]".
@(export)
ex_loadview :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	fname := get_view_file_o(([^]u8)(rawptr(arg))[0])
	if fname == nil {
		return
	}
	if do_source_e(transmute(cstring)(fname), false, DOSO_NONE_O, nil) == FAIL {
		semsg(cstring(E_NOTOPEN_S), transmute(cstring)(fname))
	}
	xfree(rawptr(fname))
}

// ":mkexrc", ":mkvimrc", ":mkview", ":mksession".
@(export)
ex_mkrc :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	cmdidx := (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	view_session := cmdidx == CMD_mksession_O || cmdidx == CMD_mkview_O
	using_vdir := false
	viewFile: ^u8 = nil
	did_lcd_g = false
	fname: ^u8
	if cmdidx == CMD_mkview_O && (([^]u8)(rawptr(arg))[0] == 0 || (ascii_isdigit(([^]u8)(rawptr(arg))[0]) && ([^]u8)(rawptr(arg))[1] == 0)) {
		(^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^ = 1
		fname = get_view_file_o(([^]u8)(rawptr(arg))[0])
		if fname == nil {
			return
		}
		viewFile = fname
		using_vdir = true
	} else if ([^]u8)(rawptr(arg))[0] != 0 {
		fname = transmute(^u8)(arg)
	} else if cmdidx == CMD_mkvimrc_O {
		fname = transmute(^u8)(cstring(VIMRC_FILE_S))
	} else if cmdidx == CMD_mksession_O {
		fname = transmute(^u8)(cstring(SESSION_FILE_S))
	} else {
		fname = transmute(^u8)(cstring(EXRC_FILE_S))
	}
	if using_vdir && !os_isdir(transmute(cstring)(p_vdir_opt)) {
		vim_mkdir_emsg(transmute(cstring)(p_vdir_opt), 0o755)
	}
	fd_raw := open_exfile(transmute(cstring)(fname), (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^, cstring("wb"))
	if fd_raw != nil {
		fd := transmute(^libc.FILE)(fd_raw)
		failed := false
		flagp := rawptr(&ssop_flags_g)
		if cmdidx == CMD_mkview_O {
			flagp = rawptr(&vop_flags_g)
		}
		apply_autocmds(EVENT_SESSIONWRITEPRE_O, nil, nil, false, curbuf)
		if cmdidx == CMD_mkvimrc_O {
			put_line(fd, cstring("version 6.0"))
		}
		if cmdidx == CMD_mksession_O {
			if put_line(fd, cstring("let SessionLoad = 1")) == FAIL {
				failed = true
			}
		}
		if !view_session || (cmdidx == CMD_mksession_O && ((^C.uint)(flagp)^ & kOptSsopFlagOptions_O) != 0) {
			flags: C.int = OPT_GLOBAL_S
			if cmdidx == CMD_mksession_O && ((^C.uint)(flagp)^ & kOptSsopFlagSkiprtp_O) != 0 {
				flags |= OPT_SKIPRTP_S
			}
			failed = failed || makemap_e(fd, nil) == FAIL || makeset(fd, flags, false) == FAIL
		}
		if !failed && view_session {
			if put_line(fd, cstring("let s:so_save = &g:so | let s:siso_save = &g:siso | setg so=0 siso=0 | setl so=-1 siso=-1")) == FAIL {
				failed = true
			}
			if cmdidx == CMD_mksession_O {
				dirnow := (^u8)(xmalloc(C.size_t(MAXPATHL_O)))
				if os_dirname(transmute(cstring)(dirnow), C.size_t(MAXPATHL_O)) == FAIL || os_chdir(transmute(cstring)(dirnow)) != 0 {
					([^]u8)(dirnow)[0] = 0
				}
				if ([^]u8)(dirnow)[0] != 0 && (ssop_flags_g & kOptSsopFlagSesdir_O) != 0 {
					if vim_chdirfile_r(transmute(cstring)(fname), kCdCauseOther_O) == OK {
						shorten_fnames(true)
					}
				} else if ([^]u8)(dirnow)[0] != 0 && (ssop_flags_g & kOptSsopFlagCurdir_O) != 0 && globaldir_g != nil {
					if os_chdir(transmute(cstring)(globaldir_g)) == 0 {
						shorten_fnames(true)
					}
				}
				failed = failed || makeopens_o(fd, dirnow) == FAIL
				if ([^]u8)(dirnow)[0] != 0 && ((ssop_flags_g & kOptSsopFlagSesdir_O) != 0 || ((ssop_flags_g & kOptSsopFlagCurdir_O) != 0 && globaldir_g != nil)) {
					if os_chdir(transmute(cstring)(dirnow)) != 0 {
						emsg(cstring(E_PREVDIR_S))
					}
					shorten_fnames(true)
				}
				xfree(rawptr(dirnow))
			} else {
				failed = failed || put_view_o(fd, curwin, curtab, !using_vdir, flagp, -1) == FAIL
			}
			if libc.fprintf(fd, cstring("%s"), cstring("let &g:so = s:so_save | let &g:siso = s:siso_save\n")) < 0 {
				failed = true
			}
			if p_hls != 0 && libc.fprintf(fd, cstring("%s"), cstring("set hlsearch\n")) < 0 {
				failed = true
			}
			if no_hlsearch && libc.fprintf(fd, cstring("%s"), cstring("nohlsearch\n")) < 0 {
				failed = true
			}
			if libc.fprintf(fd, cstring("%s"), cstring("doautoall SessionLoadPost\n")) < 0 {
				failed = true
			}
			if cmdidx == CMD_mksession_O {
				if libc.fprintf(fd, cstring("unlet SessionLoad\n")) < 0 {
					failed = true
				}
			}
		}
		if put_line(fd, cstring("\" vim: set ft=vim :")) == FAIL {
			failed = true
		}
		if libc.fclose(fd) != 0 {
			failed = true
		}
		if failed {
			emsg(cstring(E_WRITE_S))
		} else if cmdidx == CMD_mksession_O {
			tbuf := (^u8)(xmalloc(C.size_t(MAXPATHL_O)))
			if vim_FullName_e(transmute(cstring)(fname), transmute(cstring)(tbuf), C.size_t(MAXPATHL_O), false) == OK {
				set_vim_var_string(VV_THIS_SESSION_O, transmute(cstring)(tbuf), -1)
			}
			xfree(rawptr(tbuf))
		}
	}
	xfree(rawptr(viewFile))
	apply_autocmds(EVENT_SESSIONWRITEPOST_O, nil, nil, false, curbuf)
}
