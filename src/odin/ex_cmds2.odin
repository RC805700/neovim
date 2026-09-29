package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// ex_cmds2.c port: :ruby/:python3/:perl shims, write/quit guards,
// :argdo/:windo/:bufdo/:tabdo/:cdo family, :compiler/:checktime/:drop.
// Publics are @(export); script-host/add-bufnum helpers are _o plains.

foreign _ {
	@(link_name = "p_aw")
	p_aw_g: C.int
	@(link_name = "vim_dialog_yesnocancel")
	vim_dialog_yesnocancel_e :: proc "c" (typ: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int ---
	@(link_name = "vim_dialog_yesnoallcancel")
	vim_dialog_yesnoallcancel_e :: proc "c" (typ: C.int, title: cstring, message: cstring, dflt: C.int) -> C.int ---
	@(link_name = "au_event_disable")
	au_event_disable_e :: proc "c" (what: cstring) -> cstring ---
	@(link_name = "au_event_restore")
	au_event_restore_e :: proc "c" (old_ei: cstring) ---
	@(link_name = "source_runtime_vim_lua")
	source_runtime_vim_lua_e :: proc "c" (name: cstring, flags: C.int) -> C.int ---
	@(link_name = "check_timestamps")
	check_timestamps_e :: proc "c" (focus: bool) -> C.int ---
	@(link_name = "ex_cc")
	ex_cc_e :: proc "c" (eap: rawptr) ---
	@(link_name = "ex_cnext")
	ex_cnext_e :: proc "c" (eap: rawptr) ---
	@(link_name = "msg_source")
	msg_source_e :: proc "c" (hl_id: C.int) ---
}

VIM_NO_O :: 3
VIM_ALL_O :: 5
VIM_DISCARDALL_O :: 6
CCGD_ALLBUF_O :: 8
HLF_W_O :: 26
EVENT_SYNTAX_O :: 111

CMD_windo_O :: 532
CMD_tabdo_O :: 458
CMD_bufdo_O :: 40
CMD_cdo_O :: 62
CMD_ldo_O :: 228
CMD_cfdo_O :: 66
CMD_lfdo_O :: 234
CMD_sfirst_O :: 407
CMD_first_O :: 161

E666_S :: "E666: Compiler not supported: %s"
E162_S :: "E162: No write since last change for buffer \"%s\""
E947_S :: "E947: Job still running in buffer \"%s\""

// Provider dispatch for :ruby/:python3/:perl.
script_host_execute_o :: proc "c" (name: cstring, eap_raw: rawptr) {
	context = runtime.default_context()
	script: ^u8
	slen: C.size_t
	script = script_get_e(eap_raw, &slen)
	if script != nil {
		args := tv_list_alloc(3)
		tv_list_append_allocated_string(args, script)
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^))
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^))
		eval_call_provider(name, cstring("execute"), args, true)
	}
}

// Provider dispatch for :rubyfile/:py3file/:perlfile.
script_host_execute_file_o :: proc "c" (name: cstring, eap_raw: rawptr) {
	context = runtime.default_context()
	if !(^bool)(uintptr(eap_raw) + EXARG_SKIP_OFF)^ {
		buffer: [MAXPATHL_O]u8
		vim_FullName_e((^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^, transmute(cstring)(&buffer[0]), C.size_t(MAXPATHL_O), false)
		args := tv_list_alloc(3)
		tv_list_append_string(args, &buffer[0], -1)
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^))
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^))
		eval_call_provider(name, cstring("execute_file"), args, true)
	}
}

// Provider dispatch for :rubydo/:pydo3/:perldo.
script_host_do_range_o :: proc "c" (name: cstring, eap_raw: rawptr) {
	context = runtime.default_context()
	if !(^bool)(uintptr(eap_raw) + EXARG_SKIP_OFF)^ {
		args := tv_list_alloc(3)
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^))
		tv_list_append_number(args, C.longlong((^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^))
		tv_list_append_string(args, transmute(^u8)((^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^), -1)
		eval_call_provider(name, cstring("do_range"), args, true)
	}
}

@(export)
ex_ruby :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_o(cstring("ruby"), eap_raw)
}

@(export)
ex_rubyfile :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_file_o(cstring("ruby"), eap_raw)
}

@(export)
ex_rubydo :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_do_range_o(cstring("ruby"), eap_raw)
}

@(export)
ex_python3 :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_o(cstring("python3"), eap_raw)
}

@(export)
ex_py3file :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_file_o(cstring("python3"), eap_raw)
}

@(export)
ex_pydo3 :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_do_range_o(cstring("python3"), eap_raw)
}

@(export)
ex_perl :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_o(cstring("perl"), eap_raw)
}

@(export)
ex_perlfile :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_execute_file_o(cstring("perl"), eap_raw)
}

@(export)
ex_perldo :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	script_host_do_range_o(cstring("perl"), eap_raw)
}

// Write the buffer if 'autowrite' is set.
@(export)
autowrite :: proc "c" (buf: rawptr, forceit: bool) -> C.int {
	context = runtime.default_context()
	if (p_aw_g == 0 && p_awa == 0) || p_write_g == 0 || bt_dontwrite(buf) || (!forceit && (^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0) || (^rawptr)(uintptr(buf) + B_FFNAME)^ == nil {
		return FAIL
	}
	bufref: Bufref_T
	set_bufref(&bufref, buf)
	r := buf_write_all(buf, forceit)
	if bufref_valid(&bufref) && bufIsChanged(buf) {
		r = FAIL
	}
	return r
}

// Flush all changed buffers (unless readonly/never-written).
@(export)
autowrite_all :: proc "c" () {
	context = runtime.default_context()
	if (p_aw_g == 0 && p_awa == 0) || p_write_g == 0 {
		return
	}
	buf := firstbuf
	for buf != nil {
		next := (^rawptr)(uintptr(buf) + B_NEXT)^
		if bufIsChanged(buf) && (^C.int)(uintptr(buf) + B_P_RO_OFF)^ == 0 && !bt_dontwrite(buf) {
			bufref: Bufref_T
			set_bufref(&bufref, buf)
			buf_write_all(buf, false)
			if !bufref_valid(&bufref) {
				buf = firstbuf
				if buf != nil {
					next = (^rawptr)(uintptr(buf) + B_NEXT)^
				} else {
					next = nil
				}
			}
		}
		buf = next
	}
}

// True if buffer changed and cannot be abandoned.
@(export)
check_changed :: proc "c" (buf: rawptr, flags: C.int) -> bool {
	context = runtime.default_context()
	forceit := (flags & CCGD_FORCEIT_O) != 0
	bufref: Bufref_T
	set_bufref(&bufref, buf)
	if !forceit && bufIsChanged(buf) && ((flags & CCGD_MULTWIN_O) != 0 || (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 1) && ((flags & CCGD_AW_O) == 0 || autowrite(buf, forceit) == FAIL) {
		if (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && p_write_g != 0 {
			count: C.int = 0
			if (flags & CCGD_ALLBUF_O) != 0 {
				buf2 := firstbuf
				for buf2 != nil {
					if bufIsChanged(buf2) && (^rawptr)(uintptr(buf2) + B_FFNAME)^ != nil {
						count += 1
					}
					buf2 = (^rawptr)(uintptr(buf2) + B_NEXT)^
				}
			}
			if !bufref_valid(&bufref) {
				return false
			}
			dialog_changed(buf, count > 1)
			if !bufref_valid(&bufref) {
				return false
			}
			return bufIsChanged(buf)
		}
		if (flags & CCGD_EXCMD_O) != 0 {
			no_write_message()
		} else {
			no_write_message_nobang(curbuf)
		}
		return true
	}
	return false
}

// Ask what to do with a changed buffer (must check 'write' first).
@(export)
dialog_changed :: proc "c" (buf: rawptr, checkall: bool) {
	context = runtime.default_context()
	buff: [DIALOG_MSG_SIZE_O]u8
	fname := (^rawptr)(uintptr(buf) + B_FNAME)^
	if fname == nil {
		fname = transmute(rawptr)(cstring("Untitled"))
	}
	libc.snprintf(&buff[0], C.size_t(DIALOG_MSG_SIZE_O), cstring("Save changes to \"%s\"?"), transmute(cstring)(fname))
	if checkall {
		ret := vim_dialog_yesnoallcancel_e(VIM_QUESTION_O, nil, transmute(cstring)(&buff[0]), 1)
		if ret == VIM_YES_O {
			handle_dialog_write_o(buf)
		} else if ret == VIM_NO_O {
			unchanged_r(buf, true, false)
		} else if ret == VIM_ALL_O {
			dialog_write_all_o()
		} else if ret == VIM_DISCARDALL_O {
			dialog_discard_all_o()
		}
	} else {
		ret := vim_dialog_yesnocancel_e(VIM_QUESTION_O, nil, transmute(cstring)(&buff[0]), 1)
		if ret == VIM_YES_O {
			handle_dialog_write_o(buf)
		} else if ret == VIM_NO_O {
			unchanged_r(buf, true, false)
		}
	}
}

// Shared YES-arm: name untitled buffers, write if confirmed.
handle_dialog_write_o :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	ea: [192]u8
	empty_bufname := (^rawptr)(uintptr(buf) + B_FNAME)^ == nil
	if empty_bufname {
		buf_set_name((^C.int)(uintptr(buf) + B_FNUM_OFF)^, cstring("Untitled"))
	}
	if check_overwrite(rawptr(&ea[0]), buf, transmute(cstring)((^rawptr)(uintptr(buf) + B_FNAME)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^), false) == OK {
		if buf_write_all(buf, false) == OK {
			return
		}
	}
	if empty_bufname {
		(^rawptr)(uintptr(buf) + B_FNAME)^ = nil
		xfree((^rawptr)(uintptr(buf) + B_FFNAME)^)
		(^rawptr)(uintptr(buf) + B_FFNAME)^ = nil
		xfree((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
		(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = nil
	}
}

// Shared ALL-arm: write all writable changed buffers.
dialog_write_all_o :: proc "c" () {
	context = runtime.default_context()
	ea: [192]u8
	buf := firstbuf
	for buf != nil {
		next := (^rawptr)(uintptr(buf) + B_NEXT)^
		if bufIsChanged(buf) && (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil && (^C.int)(uintptr(buf) + B_P_RO_OFF)^ == 0 {
			bufref: Bufref_T
			set_bufref(&bufref, buf)
			if (^rawptr)(uintptr(buf) + B_FNAME)^ != nil && check_overwrite(rawptr(&ea[0]), buf, transmute(cstring)((^rawptr)(uintptr(buf) + B_FNAME)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^), false) == OK {
				buf_write_all(buf, false)
			}
			if !bufref_valid(&bufref) {
				buf = firstbuf
				if buf != nil {
					next = (^rawptr)(uintptr(buf) + B_NEXT)^
				} else {
					next = nil
				}
				continue
			}
		}
		buf = next
	}
}

// Shared DISCARDALL-arm: mark all buffers unchanged.
dialog_discard_all_o :: proc "c" () {
	context = runtime.default_context()
	buf := firstbuf
	for buf != nil {
		next := (^rawptr)(uintptr(buf) + B_NEXT)^
		unchanged_r(buf, true, false)
		buf = next
	}
}

// Ask whether to close a terminal buffer.
@(export)
dialog_close_terminal :: proc "c" (buf: rawptr) -> bool {
	context = runtime.default_context()
	buff: [DIALOG_MSG_SIZE_O]u8
	fname := (^rawptr)(uintptr(buf) + B_FNAME)^
	if fname == nil {
		fname = transmute(rawptr)(cstring("?"))
	}
	libc.snprintf(&buff[0], C.size_t(DIALOG_MSG_SIZE_O), cstring("Close \"%s\"?"), transmute(cstring)(fname))
	return vim_dialog_yesnocancel_e(VIM_QUESTION_O, nil, transmute(cstring)(&buff[0]), 1) == VIM_YES_O
}

// True if buffer can be abandoned (hidden/unloadable/autowritten).
@(export)
can_abandon :: proc "c" (buf: rawptr, forceit: bool) -> bool {
	context = runtime.default_context()
	if buf_hide(buf) {
		return true
	}
	if !bufIsChanged(buf) {
		return true
	}
	if (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ > 1 {
		return true
	}
	if autowrite(buf, forceit) == OK {
		return true
	}
	return forceit
}

// Add a buffer number unless already present.
add_bufnum_o :: proc "c" (bufnrs: [^]C.int, bufnump: ^C.int, nr: C.int) {
	context = runtime.default_context()
	for i: C.int = 0; i < bufnump^; i += 1 {
		if bufnrs[i] == nr {
			return
		}
	}
	bufnrs[bufnump^] = nr
	bufnump^ += 1
}

// True if any buffer changed and cannot be abandoned.
@(export)
check_changed_any :: proc "c" (hidden: bool, unload: bool) -> bool {
	context = runtime.default_context()
	ret := false
	i: C.int
	bufnum: C.int = 0
	bufcount: C.size_t = 0
	buf := firstbuf
	for buf != nil {
		bufcount += 1
		buf = (^rawptr)(uintptr(buf) + B_NEXT)^
	}
	if bufcount == 0 {
		return false
	}
	bufnrs := ([^]C.int)(xmalloc(C.size_t(4) * bufcount))
	bufnrs[bufnum] = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	bufnum += 1
	wp := firstwin
	for wp != nil {
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
			add_bufnum_o(bufnrs, &bufnum, (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNUM_OFF)^)
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	tp := first_tabpage
	for tp != nil {
		if tp != curtab {
			wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				add_bufnum_o(bufnrs, &bufnum, (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNUM_OFF)^)
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	buf = firstbuf
	for buf != nil {
		add_bufnum_o(bufnrs, &bufnum, (^C.int)(uintptr(buf) + B_FNUM_OFF)^)
		buf = (^rawptr)(uintptr(buf) + B_NEXT)^
	}
	buf = nil
	failed := false
	for i = 0; i < bufnum; i += 1 {
		buf = buflist_findnr(bufnrs[i])
		if buf == nil {
			continue
		}
		if (!hidden || (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0) && bufIsChanged(buf) {
			bufref: Bufref_T
			set_bufref(&bufref, buf)
			aw: C.int = 0
			if p_awa != 0 {
				aw = CCGD_AW_O
			}
			if check_changed(buf, aw | CCGD_MULTWIN_O | CCGD_ALLBUF_O) && bufref_valid(&bufref) {
				failed = true
				break
			}
		}
	}
	if !failed {
		xfree(rawptr(bufnrs))
		return false
	}
	ret = true
	exiting = false
	if (p_confirm_g == 0 && (cmdmod_cmod_flags & CMOD_CONFIRM_O) == 0) {
		if vgetc_busy_g > 0 {
			msg_row = cmdline_row
			msg_col = 0
			msg_didout_g = false
		}
		term_running := (^bool)(uintptr(buf) + B_TERMINAL_OFF)^ && channel_job_running_r(u64((^C.longlong)(uintptr(buf) + B_P_CHANNEL_OFF)^))
		shown := false
		if term_running {
			sp := buf_spname(buf)
			if sp == nil {
				sp = (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
			}
			shown = semsg(cstring(E947_S), transmute(cstring)(sp))
		} else {
			sp := buf_spname(buf)
			if sp == nil {
				sp = (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
			}
			shown = semsg(cstring(E162_S), transmute(cstring)(sp))
		}
		if shown && msg_didany_g {
			save := no_wait_return
			no_wait_return = 0
			wait_return(0)
			no_wait_return = save
		}
	}
	if buf != curbuf {
		tp = first_tabpage
		for tp != nil {
			wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			if tp == curtab {
				wp = firstwin
			}
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
					bufref: Bufref_T
					set_bufref(&bufref, buf)
					goto_tabpage_win(tp, wp)
					if !bufref_valid(&bufref) {
						xfree(rawptr(bufnrs))
						return ret
					}
					tp = nil
					break
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			if tp == nil {
				break
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
	}
	if buf != curbuf {
		act: C.int = DOBUF_GOTO_O
		if unload {
			act = DOBUF_UNLOAD_O
		}
		set_curbuf(buf, act, true)
	}
	xfree(rawptr(bufnrs))
	return ret
}

// FAIL without a file name (with error message).
@(export)
check_fname :: proc "c" () -> C.int {
	context = runtime.default_context()
	if (^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil {
		emsg(cstring(E_NONAME_S))
		return FAIL
	}
	return OK
}

// Write buffer contents (unless no file name).
@(export)
buf_write_all :: proc "c" (buf: rawptr, forceit: bool) -> C.int {
	context = runtime.default_context()
	old_curbuf := curbuf
	retval := buf_write_r(buf, transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_FNAME)^), 1, (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^, nil, false, forceit, true, false)
	if curbuf != old_curbuf {
		msg_source_e(HLF_W_O)
		msg_msg(cstring("Warning: Entered other buffer unexpectedly (check autocommands)"), 0)
	}
	return retval
}

// ":argdo", ":windo", ":bufdo", ":tabdo", ":cdo", ":ldo", ":cfdo", ":lfdo".
@(export)
ex_listdo :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	cmdidx := (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	forceit := (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^
	if (^C.int)(uintptr(curwin) + W_P_WFB_OFF)^ != 0 && cmdidx != CMD_windo_O && cmdidx != CMD_tabdo_O {
		if (cmdidx == CMD_ldo_O || cmdidx == CMD_lfdo_O) && forceit == 0 {
			emsg(cstring(E1513_S))
			return
		}
		if win_valid(prevwin_g) && (^C.int)(uintptr(prevwin_g) + W_P_WFB_OFF)^ == 0 {
			win_goto(prevwin_g)
		}
		if (^C.int)(uintptr(curwin) + W_P_WFB_OFF)^ != 0 {
			win_split(0, 0)
			if (^C.int)(uintptr(curwin) + W_P_WFB_OFF)^ != 0 {
				emsg(cstring(E1513_S))
				return
			}
		}
	}
	save_ei: cstring = nil
	msg_listdo_overwrite_g += 1
	if cmdidx != CMD_windo_O && cmdidx != CMD_tabdo_O {
		save_ei = au_event_disable_e(cstring(",Syntax"))
		buf := firstbuf
		for buf != nil {
			(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(0x200)
			buf = (^rawptr)(uintptr(buf) + B_NEXT)^
		}
	}
	ccgd: C.int = CCGD_AW_O
	if forceit != 0 {
		ccgd |= CCGD_FORCEIT_O
	}
	ccgd |= CCGD_EXCMD_O
	if cmdidx == CMD_windo_O || cmdidx == CMD_tabdo_O || buf_hide(curbuf) || !check_changed(curbuf, ccgd) {
		next_fnum: C.int = 0
		i: C.int = 0
		wp := firstwin
		tp := first_tabpage
		line1 := (^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^
		line2 := (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
		addr_count := (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^
		if cmdidx == CMD_windo_O {
			for wp != nil && i + 1 < line1 {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				i += 1
			}
		} else if cmdidx == CMD_tabdo_O {
			for tp != nil && i + 1 < line1 {
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
				i += 1
			}
		} else if cmdidx == CMD_argdo_O {
			i = line1 - 1
		}
		buf := curbuf
		qf_size: C.size_t = 0
		if cmdidx == CMD_bufdo_O {
			for buf = firstbuf; buf != nil && ((^C.int)(uintptr(buf) + B_FNUM_OFF)^ < line1 || (^C.int)(uintptr(buf) + B_P_BL_OFF)^ == 0); buf = (^rawptr)(uintptr(buf) + B_NEXT)^ {
				if (^C.int)(uintptr(buf) + B_FNUM_OFF)^ > line2 {
					buf = nil
					break
				}
			}
			if buf != nil {
				goto_buffer(eap_raw, DOBUF_FIRST_O, FORWARD_DIR, (^C.int)(uintptr(buf) + B_FNUM_OFF)^)
			}
		} else if cmdidx == CMD_cdo_O || cmdidx == CMD_ldo_O || cmdidx == CMD_cfdo_O || cmdidx == CMD_lfdo_O {
			qf_size = qf_get_valid_size_e(eap_raw)
			if line1 < 0 {
				libc.abort()
			}
			if qf_size == 0 || C.size_t(line1) > qf_size {
				buf = nil
			} else {
				ex_cc_e(eap_raw)
				buf = curbuf
				i = line1 - 1
				if addr_count <= 0 {
					if qf_size >= C.size_t(MAXCOL) {
						libc.abort()
					}
					(^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ = C.int(qf_size)
					line2 = C.int(qf_size)
				}
			}
		} else {
			setpcmark()
		}
		listcmd_busy = true
		for !got_int && buf != nil {
			execute := true
			if cmdidx == CMD_argdo_O {
				if i == win_alist_o(curwin).al_ga.ga_len {
					break
				}
				if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ != i || !editing_arg_idx(curwin) {
					do_argfile(eap_raw, i)
				}
				if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ != i {
					break
				}
			} else if cmdidx == CMD_windo_O {
				if !win_valid(wp) {
					break
				}
				if wp == nil {
					libc.abort()
				}
				execute = !((^bool)(uintptr(wp) + W_FLOATING_OFF)^) || (!((^bool)(uintptr(wp) + WCFG_HIDE_OFF)^) && (^bool)(uintptr(wp) + WCFG_FOCUSABLE_OFF)^)
				if execute {
					win_goto(wp)
					if curwin != wp {
						break
					}
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			} else if cmdidx == CMD_tabdo_O {
				if !valid_tabpage(tp) {
					break
				}
				if tp == nil {
					libc.abort()
				}
				goto_tabpage_tp(tp, true, true)
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			} else if cmdidx == CMD_bufdo_O {
				next_fnum = -1
				bp := (^rawptr)(uintptr(curbuf) + B_NEXT)^
				for bp != nil {
					if (^C.int)(uintptr(bp) + B_P_BL_OFF)^ != 0 {
						next_fnum = (^C.int)(uintptr(bp) + B_FNUM_OFF)^
						break
					}
					bp = (^rawptr)(uintptr(bp) + B_NEXT)^
				}
			}
			i += 1
			if execute {
				do_cmdline(arg, transmute(LineGetter)((^rawptr)(uintptr(eap_raw) + EXARG_GETLINE_OFF)^), (^rawptr)(uintptr(eap_raw) + EXARG_COOKIE_OFF)^, DOCMD_VERBOSE_O + DOCMD_NOWAIT_O)
			}
			if cmdidx == CMD_bufdo_O {
				if next_fnum < 0 || next_fnum > line2 {
					break
				}
				still_exists := false
				bp := firstbuf
				for bp != nil {
					if (^C.int)(uintptr(bp) + B_FNUM_OFF)^ == next_fnum {
						still_exists = true
						break
					}
					bp = (^rawptr)(uintptr(bp) + B_NEXT)^
				}
				if !still_exists {
					break
				}
				goto_buffer(eap_raw, DOBUF_FIRST_O, FORWARD_DIR, next_fnum)
				if (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ != next_fnum {
					break
				}
			}
			if cmdidx == CMD_cdo_O || cmdidx == CMD_ldo_O || cmdidx == CMD_cfdo_O || cmdidx == CMD_lfdo_O {
				if i < 0 {
					libc.abort()
				}
				if C.size_t(i) >= qf_size || i >= line2 {
					break
				}
				qf_idx := qf_get_cur_idx_e(eap_raw)
				ex_cnext_e(eap_raw)
				if qf_get_cur_idx_e(eap_raw) == qf_idx {
					break
				}
			}
			if cmdidx == CMD_windo_O && execute {
				validate_cursor_r(curwin)
				if (^bool)(uintptr(curwin) + W_P_SCB_OFF)^ {
					do_check_scrollbind_r(true)
				}
			}
			if cmdidx == CMD_windo_O || cmdidx == CMD_tabdo_O {
				if i + 1 > line2 {
					break
				}
			}
			if cmdidx == CMD_argdo_O && i >= line2 {
				break
			}
		}
		listcmd_busy = false
	}
	msg_listdo_overwrite_g -= 1
	if save_ei != nil {
		aco: [56]u8
		au_event_restore_e(save_ei)
		buf := firstbuf
		for buf != nil {
			bnext := (^rawptr)(uintptr(buf) + B_NEXT)^
			if (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ > 0 && ((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & 0x200) != 0 {
				(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(0x200)
				if buf == curbuf {
					apply_autocmds(EVENT_SYNTAX_O, transmute(cstring)((^rawptr)(uintptr(buf) + B_P_SYN_OFF)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_FNAME)^), true, buf)
				} else {
					aucmd_prepbuf_r(rawptr(&aco[0]), buf)
					apply_autocmds(EVENT_SYNTAX_O, transmute(cstring)((^rawptr)(uintptr(buf) + B_P_SYN_OFF)^), transmute(cstring)((^rawptr)(uintptr(buf) + B_FNAME)^), true, buf)
					aucmd_restbuf_r(rawptr(&aco[0]))
				}
				bnext = firstbuf
			}
			buf = bnext
		}
	}
}

// ":compiler[!] {name}".
@(export)
ex_compiler :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	forceit := (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^
	cmdidx := (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^
	if ([^]u8)(rawptr(arg))[0] == 0 {
		do_cmdline_cmd(cstring("echo globpath(&rtp, 'compiler/*.vim')"))
		do_cmdline_cmd(cstring("echo globpath(&rtp, 'compiler/*.lua')"))
		return
	}
	bufsize := libc.strlen(arg) + 14
	buf := ([^]u8)(xmalloc(bufsize))
	old_cur_comp: ^u8 = nil
	if forceit != 0 {
		do_cmdline_cmd(cstring("command -nargs=* -keepscript CompilerSet set <args>"))
	} else {
		do_cmdline_cmd(cstring("command -nargs=* -keepscript CompilerSet setlocal <args>"))
		old_p := get_var_value(cstring("g:current_compiler"))
		if old_p != nil {
			old_cur_comp = xstrdup(transmute(^u8)(old_p))
		}
	}
	do_unlet(cstring("g:current_compiler"), 18, true)
	do_unlet(cstring("b:current_compiler"), 18, true)
	libc.snprintf(buf, bufsize, cstring("compiler/%s.*"), arg)
	if source_runtime_vim_lua_e(transmute(cstring)(buf), DIP_ALL_O) == FAIL {
		semsg(cstring(E666_S), arg)
	}
	xfree(rawptr(buf))
	do_cmdline_cmd(cstring(":delcommand CompilerSet"))
	p := get_var_value(cstring("g:current_compiler"))
	if p != nil {
		set_internal_string_var(cstring("b:current_compiler"), p)
	}
	if forceit == 0 {
		if old_cur_comp != nil {
			set_internal_string_var(cstring("g:current_compiler"), transmute(cstring)(old_cur_comp))
			xfree(rawptr(old_cur_comp))
		} else {
			do_unlet(cstring("g:current_compiler"), 18, true)
		}
	}
}

// ":checktime [buffer]".
@(export)
ex_checktime :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	save := no_check_timestamps
	no_check_timestamps = 0
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ == 0 {
		check_timestamps_e(false)
	} else {
		buf := buflist_findnr((^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^)
		if buf != nil {
			buf_check_timestamp_r(buf)
		}
	}
	no_check_timestamps = save
}

// ":drop" — edit first argument, reusing windows when possible.
@(export)
ex_drop :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	split := false
	set_arglist(transmute(^u8)((^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^))
	if win_alist_o(curwin).al_ga.ga_len == 0 {
		return
	}
	if cmdmod_tab_o() != 0 {
		ex_all(eap_raw)
		set_cmdmod_tab_o(0)
		ex_rewind(eap_raw)
		return
	}
	buf := buflist_findnr(alist_entries_o(win_alist_o(curwin))[0].ae_fnum)
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		if tp == curtab {
			wp = firstwin
		}
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				goto_tabpage_win(tp, wp)
				(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = 0
				if !bufIsChanged(curbuf) {
					save_ar := (^C.int)(uintptr(curbuf) + B_P_AR_OFF)^
					(^C.int)(uintptr(curbuf) + B_P_AR_OFF)^ = 1
					buf_check_timestamp_r(curbuf)
					(^C.int)(uintptr(curbuf) + B_P_AR_OFF)^ = save_ar
				}
				if ((^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O) != 0 {
					ex_rewind(eap_raw)
				}
				do_ecmd_cmd := (^rawptr)(uintptr(eap_raw) + EXARG_DO_ECMD_CMD_OFF)^
				if do_ecmd_cmd != nil {
					did_set := set_swapcommand(transmute(^u8)(do_ecmd_cmd), 0)
					do_cmdline(transmute(cstring)(do_ecmd_cmd), nil, nil, DOCMD_VERBOSE_O)
					if did_set {
						set_vim_var_string(VV_SWAPCOMMAND, nil, -1)
					}
				}
				return
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	if !buf_hide(curbuf) {
		emsg_off += 1
		split = check_changed(curbuf, CCGD_AW_O | CCGD_EXCMD_O)
		emsg_off -= 1
	}
	if split {
		(^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^ = CMD_sfirst_O
		([^]u8)((^rawptr)(uintptr(eap_raw) + EXARG_CMD_OFF)^)[0] = 's'
	} else {
		(^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^ = CMD_first_O
	}
	ex_rewind(eap_raw)
}
