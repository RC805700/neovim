package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// debugger.c port: :debug REPL, breakpoints (:breakadd/del/list), backtrace.
// Publics are @(export); statics are file-privates / _o plains.

foreign _ {
	@(link_name = "ignore_script")
	ignore_script_g: bool
	@(link_name = "msg_starthere")
	msg_starthere_e :: proc "c" () ---
	@(link_name = "debug_did_msg")
	debug_did_msg_g: bool
}

CMD_PROFILE_O :: 335
CMD_PROFDEL_O :: 336
CMD_BREAKDEL_O :: 36
CMD_BREAKADD_O :: 35

E_NONAME_S :: "E32: No file name"
E161_S :: "E161: Breakpoint not found: %s"

DBG_FUNC_O :: 1
DBG_FILE_O :: 2
DBG_EXPR_O :: 3

// struct debuggy mirror (fields cc-counted; size asserted).
Debuggy_T :: struct {
	dbg_nr:     C.int,
	dbg_type:   C.int,
	dbg_name:   rawptr,
	dbg_prog:   rawptr,
	dbg_lnum:   C.int,
	dbg_forceit: C.int,
	dbg_val:    rawptr,
	dbg_level:  C.int,
}
#assert(size_of(Debuggy_T) == 48)

@(private = "file")
debug_greedy_g: bool
@(private = "file")
debug_oldval_g: rawptr
@(private = "file")
debug_newval_g: rawptr
@(private = "file")
debug_breakpoint_name_g: rawptr
@(private = "file")
debug_breakpoint_lnum_g: C.int
@(private = "file")
debug_skipped_g: bool
@(private = "file")
debug_skipped_name_g: rawptr
@(private = "file")
dbg_breakp_g: Garray = {0, 0, size_of(Debuggy_T), 4, nil}
@(private = "file")
last_breakp_g: C.int
@(private = "file")
has_expr_breakpoint_g: bool
@(private = "file")
prof_ga_g: Garray = {0, 0, size_of(Debuggy_T), 4, nil}

// Debug REPL: repeated Ex commands until cont/next/step/... .
@(export)
do_debug :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	save_msg_scroll := msg_scroll
	save_State := State
	save_did_emsg := did_emsg_g()
	save_cmd_silent := cmd_silent
	save_msg_silent := msg_silent
	save_emsg_silent := emsg_silent
	save_redir_off := redir_off_g
	typeaheadbuf: [192]u8
	typeahead_saved := false
	save_ignore_script: C.int = 0
	cmdline: ^u8 = nil
	p: ^u8 = nil
	tail: ^u8 = nil
	last_cmd: C.int = 0
	RedrawingDisabled += 1
	no_wait_return += 1
	did_emsg_set(false)
	cmd_silent = false
	msg_silent = 0
	emsg_silent = 0
	redir_off_g = true
	State = MODE_NORMAL_O
	debug_mode_g = true
	if !debug_did_msg_g {
		msg_msg(_t(cstring("Entering Debug mode.  Type \"cont\" to continue.")), 0)
	}
	if debug_oldval_g != nil {
		smsg(0, _t(cstring("Oldval = \"%s\"")), transmute(cstring)(debug_oldval_g))
		xfree(debug_oldval_g)
		debug_oldval_g = nil
	}
	if debug_newval_g != nil {
		smsg(0, _t(cstring("Newval = \"%s\"")), transmute(cstring)(debug_newval_g))
		xfree(debug_newval_g)
		debug_newval_g = nil
	}
	sname := estack_sfile_e(ESTACK_NONE_O)
	if sname != nil {
		msg_msg(transmute(cstring)(sname), 0)
	}
	xfree(rawptr(sname))
	if sourcing_lnum_o() != 0 {
		smsg(0, _t(cstring("line %ld: %s")), C.longlong(sourcing_lnum_o()), cmd)
	} else {
		smsg(0, _t(cstring("cmd: %s")), cmd)
	}
	for {
		msg_scroll = 1
		need_wait_return_g = false
		save_ex_normal_busy := ex_normal_busy_g
		ex_normal_busy_g = 0
		if !debug_greedy_g {
			save_typeahead_e(rawptr(&typeaheadbuf[0]))
			typeahead_saved = true
			save_ignore_script = 0
			if ignore_script_g {
				save_ignore_script = 1
			}
			ignore_script_g = true
		}
		n := debug_break_level
		debug_break_level = -1
		xfree(rawptr(cmdline))
		cmdline = getcmdline_prompt_r(C.int('>'), nil, 0, EXPAND_NOTHING_S, nil, Callback_T{}, false, nil)
		debug_break_level = n
		if typeahead_saved {
			restore_typeahead_e(rawptr(&typeaheadbuf[0]))
			ignore_script_g = save_ignore_script != 0
		}
		ex_normal_busy_g = save_ex_normal_busy
		cmdline_row = msg_row
		msg_starthere_e()
		if cmdline != nil {
			p = transmute(^u8)(skipwhite(transmute(cstring)(cmdline)))
			if ([^]u8)(p)[0] != 0 {
				c0 := ([^]u8)(p)[0]
				if c0 == 'c' {
					last_cmd = 1
					tail = transmute(^u8)(cstring("ont"))
				} else if c0 == 'n' {
					last_cmd = 2
					tail = transmute(^u8)(cstring("ext"))
				} else if c0 == 's' {
					last_cmd = 3
					tail = transmute(^u8)(cstring("tep"))
				} else if c0 == 'f' {
					last_cmd = 0
					if ([^]u8)(p)[1] == 'r' {
						last_cmd = 8
						tail = transmute(^u8)(cstring("rame"))
					} else {
						last_cmd = 4
						tail = transmute(^u8)(cstring("inish"))
					}
				} else if c0 == 'q' {
					last_cmd = 5
					tail = transmute(^u8)(cstring("uit"))
				} else if c0 == 'i' {
					last_cmd = 6
					tail = transmute(^u8)(cstring("nterrupt"))
				} else if c0 == 'b' {
					last_cmd = 7
					if ([^]u8)(p)[1] == 't' {
						tail = transmute(^u8)(cstring("t"))
					} else {
						tail = transmute(^u8)(cstring("acktrace"))
					}
				} else if c0 == 'w' {
					last_cmd = 7
					tail = transmute(^u8)(cstring("here"))
				} else if c0 == 'u' {
					last_cmd = 9
					tail = transmute(^u8)(cstring("p"))
				} else if c0 == 'd' {
					last_cmd = 10
					tail = transmute(^u8)(cstring("own"))
				} else {
					last_cmd = 0
				}
				if last_cmd != 0 {
					p = (^u8)(uintptr(p) + 1)
					for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] == ([^]u8)(tail)[0] {
						p = (^u8)(uintptr(p) + 1)
						tail = (^u8)(uintptr(tail) + 1)
					}
					if ascii_isalpha_o(([^]u8)(p)[0]) && last_cmd != 8 {
						last_cmd = 0
					}
				}
			}
			if last_cmd != 0 {
				quit := false
				if last_cmd == 1 {
					debug_break_level = -1
				} else if last_cmd == 2 {
					debug_break_level = ex_nesting_level_g
				} else if last_cmd == 3 {
					debug_break_level = 9999
				} else if last_cmd == 4 {
					debug_break_level = ex_nesting_level_g - 1
				} else if last_cmd == 5 {
					got_int = true
					debug_break_level = -1
				} else if last_cmd == 6 {
					got_int = true
					debug_break_level = 9999
					last_cmd = 3
				} else if last_cmd == 7 {
					do_showbacktrace_o(cmd)
					continue
				} else if last_cmd == 8 {
					if ([^]u8)(p)[0] == 0 {
						do_showbacktrace_o(cmd)
					} else {
						p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
						do_setdebugtracelevel_o(p)
					}
					continue
				} else if last_cmd == 9 {
					debug_backtrace_level_g += 1
					do_checkbacktracelevel_o()
					continue
				} else if last_cmd == 10 {
					debug_backtrace_level_g -= 1
					do_checkbacktracelevel_o()
					continue
				}
				_ = quit
				debug_backtrace_level_g = 0
				break
			}
			n = debug_break_level
			debug_break_level = -1
			do_cmdline(transmute(cstring)(cmdline), getexline_e, nil, DOCMD_VERBOSE_O | DOCMD_EXCRESET_O)
			debug_break_level = n
		}
		lines_left = Rows - 1
	}
	xfree(rawptr(cmdline))
	RedrawingDisabled -= 1
	no_wait_return -= 1
	redraw_all_later(UPD_NOT_VALID)
	need_wait_return_g = false
	msg_scroll = save_msg_scroll
	lines_left = Rows - 1
	State = save_State
	debug_mode_g = false
	did_emsg_set(save_did_emsg != 0)
	cmd_silent = save_cmd_silent
	msg_silent = save_msg_silent
	emsg_silent = save_emsg_silent
	redir_off_g = save_redir_off
	debug_did_msg_g = true
}

get_maxbacktrace_level_o :: proc "c" (sname: ^u8) -> C.int {
	context = runtime.default_context()
	maxbacktrace: C.int = 0
	if sname == nil {
		return 0
	}
	p := sname
	for {
		q := strstr_c(transmute(cstring)(p), cstring(".."))
		if q == nil {
			break
		}
		p = (^u8)(uintptr(rawptr(q)) + 2)
		maxbacktrace += 1
	}
	return maxbacktrace
}

do_setdebugtracelevel_o :: proc "c" (arg: ^u8) {
	context = runtime.default_context()
	level := C.int(libc.atoi(transmute(cstring)(arg)))
	if ([^]u8)(arg)[0] == '+' || level < 0 {
		debug_backtrace_level_g += level
	} else {
		debug_backtrace_level_g = level
	}
	do_checkbacktracelevel_o()
}

do_checkbacktracelevel_o :: proc "c" () {
	context = runtime.default_context()
	if debug_backtrace_level_g < 0 {
		debug_backtrace_level_g = 0
		msg_msg(_t(cstring("frame is zero")), 0)
	} else {
		sname := estack_sfile_e(ESTACK_NONE_O)
		max := get_maxbacktrace_level_o(sname)
		if debug_backtrace_level_g > max {
			debug_backtrace_level_g = max
			smsg(0, _t(cstring("frame at highest level: %d")), max)
		}
		xfree(rawptr(sname))
	}
}

do_showbacktrace_o :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	sname := estack_sfile_e(ESTACK_NONE_O)
	max := get_maxbacktrace_level_o(sname)
	if sname != nil {
		i: C.int = 0
		cur := sname
		for !got_int {
			next := strstr_c(transmute(cstring)(cur), cstring(".."))
			if next != nil {
				([^]u8)(rawptr(next))[0] = 0
			}
			if i == max - debug_backtrace_level_g {
				smsg(0, cstring("->%d %s"), max - i, transmute(cstring)(cur))
			} else {
				smsg(0, cstring("  %d %s"), max - i, transmute(cstring)(cur))
			}
			i += 1
			if next == nil {
				break
			}
			([^]u8)(rawptr(next))[0] = '.'
			cur = (^u8)(uintptr(rawptr(next)) + 2)
		}
		xfree(rawptr(sname))
	}
	if sourcing_lnum_o() != 0 {
		smsg(0, _t(cstring("line %ld: %s")), C.longlong(sourcing_lnum_o()), cmd)
	} else {
		smsg(0, _t(cstring("cmd: %s")), cmd)
	}
}

// ":debug".
@(export)
ex_debug :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	save := debug_break_level
	debug_break_level = 9999
	do_cmdline_cmd((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
	debug_break_level = save
}

// Breakpoint hit or nesting level reached; sets зависание state for skips.
@(export)
dbg_check_breakpoint :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	debug_skipped_g = false
	if debug_breakpoint_name_g != nil {
		if (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
			debug_skipped_g = true
			debug_skipped_name_g = debug_breakpoint_name_g
			debug_breakpoint_name_g = nil
		} else {
			p: cstring = cstring("")
			if ([^]u8)(rawptr(debug_breakpoint_name_g))[0] == u8(K_SPECIAL_INPUT) && ([^]u8)(rawptr(debug_breakpoint_name_g))[1] == u8(KS_EXTRA) && ([^]u8)(rawptr(debug_breakpoint_name_g))[2] == KE_SNR_O {
				p = cstring("<SNR>")
			}
			skip := 0
			if ([^]u8)(rawptr(p))[0] != 0 {
				skip = 3
			}
			smsg(0, _t(cstring("Breakpoint in \"%s%s\" line %ld")), p, transmute(cstring)((^u8)(uintptr(rawptr(debug_breakpoint_name_g)) + uintptr(skip))), C.longlong(debug_breakpoint_lnum_g))
			debug_breakpoint_name_g = nil
			do_debug((^cstring)(uintptr(eap) + EXARG_CMD_OFF)^)
		}
	} else if ex_nesting_level_g <= debug_break_level {
		if (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
			debug_skipped_g = true
			debug_skipped_name_g = nil
		} else {
			do_debug((^cstring)(uintptr(eap) + EXARG_CMD_OFF)^)
		}
	}
}

// Enter debug mode for a command skipped earlier.
@(export)
dbg_check_skipped :: proc "c" (eap: rawptr) -> bool {
	context = runtime.default_context()
	if !debug_skipped_g {
		return false
	}
	prev_got_int := got_int
	got_int = false
	debug_breakpoint_name_g = debug_skipped_name_g
	(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ = false
	dbg_check_breakpoint(eap)
	(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ = true
	got_int = prev_got_int || got_int
	return true
}

// Evaluate bp->dbg_name with errors suppressed.
eval_expr_no_emsg_o :: proc "c" (bp: ^Debuggy_T) -> ^Typval_T {
	context = runtime.default_context()
	emsg_off += 1
	tv := eval_expr(transmute(cstring)((^rawptr)(uintptr(bp) + 8)^), nil)
	emsg_off -= 1
	return tv
}

// Parse :breakadd/:breakdel/:profile args into a new gap slot.
dbg_parsearg_o :: proc "c" (arg: ^u8, gap: ^Garray) -> C.int {
	context = runtime.default_context()
	p := arg
	here := false
	ga_grow(gap, 1)
	bp := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(gap.ga_len) * size_of(Debuggy_T))
	if libc.strncmp(transmute(cstring)(p), cstring("func"), 4) == 0 {
		bp.dbg_type = DBG_FUNC_O
	} else if libc.strncmp(transmute(cstring)(p), cstring("file"), 4) == 0 {
		bp.dbg_type = DBG_FILE_O
	} else if rawptr(gap) != rawptr(&dbg_breakp_g) && libc.strncmp(transmute(cstring)(p), cstring("here"), 4) == 0 {
		ffname := (^rawptr)(uintptr(curbuf) + B_FFNAME)^
		if ffname == nil {
			emsg(_t(cstring(E_NONAME_S)))
			return FAIL_E
		}
		bp.dbg_type = DBG_FILE_O
		here = true
	} else if rawptr(gap) != rawptr(&prof_ga_g) && libc.strncmp(transmute(cstring)(p), cstring("expr"), 4) == 0 {
		bp.dbg_type = DBG_EXPR_O
	} else {
		semsg(e_invarg2, transmute(cstring)(p))
		return FAIL_E
	}
	p = transmute(^u8)(skipwhite(transmute(cstring)((^u8)(uintptr(p) + 4))))
	if here {
		bp.dbg_lnum = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum
	} else if rawptr(gap) != rawptr(&prof_ga_g) && ascii_isdigit(([^]u8)(p)[0]) {
		pp := p
		bp.dbg_lnum = getdigits_int32(&pp, true, 0)
		p = pp
		p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
	} else {
		bp.dbg_lnum = 0
	}
	if ((!here && ([^]u8)(p)[0] == 0) || (here && ([^]u8)(p)[0] != 0) || (bp.dbg_type == DBG_FUNC_O && strstr_c(transmute(cstring)(p), cstring("()")) != nil)) {
		semsg(e_invarg2, transmute(cstring)(arg))
		return FAIL_E
	}
	if bp.dbg_type == DBG_FUNC_O {
		np := p
		if ([^]u8)(p)[0] == 'g' && ([^]u8)(p)[1] == ':' {
			np = (^u8)(uintptr(p) + 2)
		}
		bp.dbg_name = rawptr(xstrdup(np))
	} else if here {
		bp.dbg_name = rawptr(xstrdup(transmute(^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^)))
	} else if bp.dbg_type == DBG_EXPR_O {
		bp.dbg_name = rawptr(xstrdup(p))
		bp.dbg_val = rawptr(eval_expr_no_emsg_o(bp))
	} else {
		q := expand_env_save(transmute(cstring)(p))
		if q == nil {
			return FAIL_E
		}
		p = transmute(^u8)(expand_env_save(q))
		xfree(rawptr(q))
		if p == nil {
			return FAIL_E
		}
		if ([^]u8)(p)[0] != '*' {
			bp.dbg_name = rawptr(fix_fname_r(transmute(cstring)(p)))
			xfree(rawptr(p))
		} else {
			bp.dbg_name = rawptr(p)
		}
	}
	if bp.dbg_name == nil {
		return FAIL_E
	}
	return OK_E
}

// ":breakadd" (also used for ":profile").
@(export)
ex_breakadd :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	gap := &dbg_breakp_g
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_PROFILE_O {
		gap = &prof_ga_g
	}
	if dbg_parsearg_o(transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^), gap) != OK_E {
		return
	}
	bp := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(gap.ga_len) * size_of(Debuggy_T))
	bp.dbg_forceit = (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^
	if bp.dbg_type != DBG_EXPR_O {
		pat := file_pat_to_reg_pat_r(transmute(cstring)(bp.dbg_name), nil, nil, false)
		if pat != nil {
			bp.dbg_prog = rawptr(vim_regcomp(transmute(cstring)(pat), RE_MAGIC + RE_STRING_O))
			xfree(rawptr(pat))
		}
		if pat == nil || bp.dbg_prog == nil {
			xfree(bp.dbg_name)
		} else {
			if bp.dbg_lnum == 0 {
				bp.dbg_lnum = 1
			}
			if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ != CMD_PROFILE_O {
				([^]Debuggy_T)(gap.ga_data)[uintptr(gap.ga_len)].dbg_nr = last_breakp_g + 1
				last_breakp_g += 1
				debug_tick_g += 1
			}
			gap.ga_len += 1
		}
	} else {
		([^]Debuggy_T)(gap.ga_data)[uintptr(gap.ga_len)].dbg_nr = last_breakp_g + 1
		last_breakp_g += 1
		gap.ga_len += 1
		debug_tick_g += 1
		if rawptr(gap) == rawptr(&dbg_breakp_g) {
			has_expr_breakpoint_g = true
		}
	}
}

// ":debuggreedy".
@(export)
ex_debuggreedy :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ == 0 || (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^ != 0 {
		debug_greedy_g = true
	} else {
		debug_greedy_g = false
	}
}

update_has_expr_breakpoint_o :: proc "c" () {
	context = runtime.default_context()
	has_expr_breakpoint_g = false
	for i: C.int = 0; i < dbg_breakp_g.ga_len; i += 1 {
		if (([^]Debuggy_T)(dbg_breakp_g.ga_data))[uintptr(i)].dbg_type == DBG_EXPR_O {
			has_expr_breakpoint_g = true
			break
		}
	}
}

// ":breakdel" and ":profdel".
@(export)
ex_breakdel :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	todel: C.int = -1
	del_all := false
	best_lnum: C.int = 0
	gap := &dbg_breakp_g
	if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_PROFDEL_O {
		gap = &prof_ga_g
	}
	arg := transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
	if ascii_isdigit(([^]u8)(arg)[0]) {
		nr := C.int(libc.atoi(transmute(cstring)(arg)))
		for i: C.int = 0; i < gap.ga_len; i += 1 {
			if (([^]Debuggy_T)(gap.ga_data))[uintptr(i)].dbg_nr == nr {
				todel = i
				break
			}
		}
	} else if ([^]u8)(arg)[0] == '*' {
		todel = 0
		del_all = true
	} else {
		if dbg_parsearg_o(arg, gap) == FAIL_E {
			return
		}
		bp := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(gap.ga_len) * size_of(Debuggy_T))
		for i: C.int = 0; i < gap.ga_len; i += 1 {
			bpi := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(i) * size_of(Debuggy_T))
			if bp.dbg_type == bpi.dbg_type && libc.strcmp(transmute(cstring)(bp.dbg_name), transmute(cstring)(bpi.dbg_name)) == 0 && (bp.dbg_lnum == bpi.dbg_lnum || (bp.dbg_lnum == 0 && (best_lnum == 0 || bpi.dbg_lnum < best_lnum))) {
				todel = i
				best_lnum = bpi.dbg_lnum
			}
		}
		xfree(bp.dbg_name)
	}
	if todel < 0 {
		semsg(cstring(E161_S), transmute(cstring)(arg))
		return
	}
	for gap.ga_len > 0 {
		todel_bp := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(todel) * size_of(Debuggy_T))
		xfree(todel_bp.dbg_name)
		if todel_bp.dbg_type == DBG_EXPR_O && todel_bp.dbg_val != nil {
			tv_free((^Typval_T)(todel_bp.dbg_val))
		}
		vim_regfree(todel_bp.dbg_prog)
		gap.ga_len -= 1
		if todel < gap.ga_len {
			libc.memmove(rawptr(todel_bp), rawptr(uintptr(gap.ga_data) + uintptr(todel + 1) * size_of(Debuggy_T)), C.size_t(gap.ga_len - todel) * C.size_t(size_of(Debuggy_T)))
		}
		if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_BREAKDEL_O {
			debug_tick_g += 1
		}
		if !del_all {
			break
		}
	}
	if gap.ga_len <= 0 {
		ga_clear(gap)
	}
	if rawptr(gap) == rawptr(&dbg_breakp_g) {
		update_has_expr_breakpoint_o()
	}
}

// ":breaklist".
@(export)
ex_breaklist :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	if dbg_breakp_g.ga_len <= 0 {
		msg_msg(_t(cstring("No breakpoints defined")), 0)
		return
	}
	for i: C.int = 0; i < dbg_breakp_g.ga_len; i += 1 {
		bp := (^Debuggy_T)(uintptr(dbg_breakp_g.ga_data) + uintptr(i) * size_of(Debuggy_T))
		if bp.dbg_type == DBG_FILE_O {
			home_replace(rawptr(&name_buff[0]), transmute(cstring)(bp.dbg_name), transmute(cstring)(&name_buff[0]), MAXPATHL_O, true)
		}
		if bp.dbg_type != DBG_EXPR_O {
			kind := cstring("file")
			nm := transmute(cstring)(&name_buff[0])
			if bp.dbg_type == DBG_FUNC_O {
				kind = cstring("func")
				nm = transmute(cstring)(bp.dbg_name)
			}
			smsg(0, _t(cstring("%3d  %s %s  line %ld")), bp.dbg_nr, kind, nm, C.longlong(bp.dbg_lnum))
		} else {
			smsg(0, _t(cstring("%3d  expr %s")), bp.dbg_nr, transmute(cstring)(bp.dbg_name))
		}
	}
}

// Line number of a function/file breakpoint past `after` (0 = none).
@(export)
dbg_find_breakpoint :: proc "c" (file: bool, fname: cstring, after: C.int) -> C.int {
	context = runtime.default_context()
	return debuggy_find_o(file, fname, after, &dbg_breakp_g, nil)
}

// True when profiling is on for a function or sourced file.
@(export)
has_profiling :: proc "c" (file: bool, fname: cstring, fp: rawptr) -> bool {
	context = runtime.default_context()
	return debuggy_find_o(file, fname, 0, &prof_ga_g, transmute(^bool)(fp)) != 0
}

// Shared breakpoint/profiling lookup.
debuggy_find_o :: proc "c" (file: bool, fname: cstring, after: C.int, gap: ^Garray, fp: ^bool) -> C.int {
	context = runtime.default_context()
	lnum: C.int = 0
	name := transmute(^u8)(fname)
	allocated := false
	if gap.ga_len <= 0 {
		return 0
	}
	if !file && ([^]u8)(transmute(^u8)(fname))[0] == u8(K_SPECIAL_INPUT) {
		fn := transmute(^u8)(fname)
		name = (^u8)(xmalloc(C.size_t(libc.strlen(fname)) + 3))
		allocated = true
		libc.strcpy(name, cstring("<SNR>"))
		libc.strcpy((^u8)(uintptr(name) + 5), transmute(cstring)((^u8)(uintptr(fn) + 3)))
	}
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		bp := (^Debuggy_T)(uintptr(gap.ga_data) + uintptr(i) * size_of(Debuggy_T))
		if ((bp.dbg_type == DBG_FILE_O) == file) && bp.dbg_type != DBG_EXPR_O && (rawptr(gap) == rawptr(&prof_ga_g) || (bp.dbg_lnum > after && (lnum == 0 || bp.dbg_lnum < lnum))) {
			prev_got_int := got_int
			got_int = false
			if vim_regexec_prog_r((^rawptr)(&bp.dbg_prog), false, transmute(cstring)(name), 0) != 0 {
				lnum = bp.dbg_lnum
				if fp != nil {
					fp^ = bp.dbg_forceit != 0
				}
			}
			got_int = prev_got_int || got_int
		} else if bp.dbg_type == DBG_EXPR_O {
			line := false
			tv := eval_expr_no_emsg_o(bp)
			if tv != nil {
				if bp.dbg_val == nil {
					xfree(debug_oldval_g)
					debug_oldval_g = rawptr(typval_tostring(nil, true))
					bp.dbg_val = rawptr(tv)
					xfree(debug_newval_g)
					debug_newval_g = rawptr(typval_tostring((^Typval_T)(bp.dbg_val), true))
					line = true
				} else {
					if typval_compare(tv, (^Typval_T)(bp.dbg_val), EXPR_IS_O, false) == OK_E && transmute(C.longlong)(tv.vval) == 0 {
						line = true
						xfree(debug_oldval_g)
						debug_oldval_g = rawptr(typval_tostring((^Typval_T)(bp.dbg_val), true))
						v := eval_expr_no_emsg_o(bp)
						xfree(debug_newval_g)
						debug_newval_g = rawptr(typval_tostring(v, true))
						tv_free((^Typval_T)(bp.dbg_val))
						bp.dbg_val = rawptr(v)
					}
					tv_free(tv)
				}
			} else if bp.dbg_val != nil {
				xfree(debug_oldval_g)
				debug_oldval_g = rawptr(typval_tostring((^Typval_T)(bp.dbg_val), true))
				xfree(debug_newval_g)
				debug_newval_g = rawptr(typval_tostring(nil, true))
				tv_free((^Typval_T)(bp.dbg_val))
				bp.dbg_val = nil
				line = true
			}
			if line {
				if after > 0 {
					lnum = after
				} else {
					lnum = 1
				}
				break
			}
		}
	}
	if allocated {
		xfree(rawptr(name))
	}
	return lnum
}

// Record a breakpoint hit for this line.
@(export)
dbg_breakpoint :: proc "c" (name: cstring, lnum: C.int) {
	context = runtime.default_context()
	debug_breakpoint_name_g = rawptr(transmute(^u8)(name))
	debug_breakpoint_lnum_g = lnum
}
