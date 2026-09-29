package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// arglist.c port: :args/:next/:prev/:argdo family + argv()/argc() builtins.
// Publics are @(export); list-walk/statics are _o plains.

foreign _ {
	@(link_name = "max_alist_id")
	max_alist_id_g: C.int
}

// aentry_T mirror (16B: fname@0, fnum@8).
Aentry_T :: struct {
	ae_fname: ^u8,
	ae_fnum:  C.int,
}
#assert(size_of(Aentry_T) == 16)

// alist_T mirror (24B: ga@0, refcount@16, id@20).
Alist_T :: struct {
	al_ga:        Garray,
	al_refcount:  C.int,
	id:           C.int,
}
#assert(size_of(Alist_T) == 32)

E_CANNOT_ARG_S :: "E1156: Cannot change the argument list recursively"
E_NOMATCH_S :: "E479: No match"
E_NOMATCH2_S :: "E480: No match: %s"
E610_S :: "E610: No argument to delete"
E163_S :: "E163: There is only one file to edit"
E164_S :: "E164: Cannot go before first file"
E165_S :: "E165: Cannot go beyond last file"

// Set while the argument list is being changed across autocommands.
@(private = "file")
arglist_locked_g: bool

// Global argument list struct (C-owned storage, address-of only).
global_alist_o :: proc "c" () -> ^Alist_T {
	context = runtime.default_context()
	return (^Alist_T)(&global_alist_u8)
}

// Argument list of a window.
win_alist_o :: proc "c" (wp: rawptr) -> ^Alist_T {
	context = runtime.default_context()
	return (^Alist_T)((^rawptr)(uintptr(wp) + W_ALIST_OFF)^)
}

// Entry array of an argument list.
alist_entries_o :: proc "c" (al: ^Alist_T) -> [^]Aentry_T {
	context = runtime.default_context()
	return ([^]Aentry_T)(al.al_ga.ga_data)
}

// Guard against recursive arglist changes.
check_arglist_locked_o :: proc "c" () -> C.int {
	context = runtime.default_context()
	if arglist_locked_g {
		emsg(cstring(E_CANNOT_ARG_S))
		return FAIL
	}
	return OK
}

// Clear an argument list: free all file names, reset to zero entries.
@(export)
alist_clear :: proc "c" (al_raw: rawptr) {
	context = runtime.default_context()
	al := (^Alist_T)(al_raw)
	if check_arglist_locked_o() == FAIL {
		return
	}
	entries := alist_entries_o(al)
	for i := C.int(0); i < al.al_ga.ga_len; i += 1 {
		xfree(rawptr(entries[i].ae_fname))
	}
	ga_clear((^Garray)(al_raw))
}

// Init an argument list.
@(export)
alist_init :: proc "c" (al_raw: rawptr) {
	context = runtime.default_context()
	ga_init((^Garray)(al_raw), C.int(size_of(Aentry_T)), 5)
}

// Drop a reference; free when no longer used by any window.
@(export)
alist_unlink :: proc "c" (al_raw: rawptr) {
	context = runtime.default_context()
	al := (^Alist_T)(al_raw)
	if al_raw != rawptr(&global_alist_u8) {
		al.al_refcount -= 1
		if al.al_refcount <= 0 {
			alist_clear(al_raw)
			xfree(al_raw)
		}
	}
}

// Create a new argument list for the current window.
@(export)
alist_new :: proc "c" () {
	context = runtime.default_context()
	al := (^Alist_T)(xmalloc(C.size_t(size_of(Alist_T))))
	al.al_refcount = 1
	max_alist_id_g += 1
	al.id = max_alist_id_g
	alist_init(rawptr(al))
	(^rawptr)(uintptr(curwin) + W_ALIST_OFF)^ = rawptr(al)
}

EW_ADDSLASH_O :: 0x08
EW_NOERROR_O :: 0x200
EW_NOTWILD_O :: 0x400

AL_SET_O :: 1
AL_ADD_O :: 2
AL_DEL_O :: 3

// Entry pointer by index (no & on multi-pointer index).
arg_entry_o :: proc "c" (al: ^Alist_T, idx: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(rawptr(alist_entries_o(al))) + uintptr(idx) * size_of(Aentry_T))
}

// Get the file name for an argument list entry.
@(export)
alist_name :: proc "c" (aep_raw: rawptr) -> ^u8 {
	context = runtime.default_context()
	aep := (^Aentry_T)(aep_raw)
	bp := buflist_findnr(aep.ae_fnum)
	if bp == nil {
		return aep.ae_fname
	}
	bfname := (^rawptr)(uintptr(bp) + B_FNAME)^
	if bfname == nil {
		return aep.ae_fname
	}
	return (^u8)(bfname)
}

// Isolate one argument, taking backticks. Returns start of next argument.
do_one_arg_o :: proc "c" (str_in: ^u8) -> ^u8 {
	context = runtime.default_context()
	str := str_in
	p := str
	inbacktick := false
	for ([^]u8)(str)[0] != 0 {
		if rem_backslash(transmute(cstring)(str)) {
			([^]u8)(p)[0] = ([^]u8)(str)[0]
			p = (^u8)(uintptr(p) + 1)
			str = (^u8)(uintptr(str) + 1)
			([^]u8)(p)[0] = ([^]u8)(str)[0]
			p = (^u8)(uintptr(p) + 1)
			str = (^u8)(uintptr(str) + 1)
		} else {
			if !inbacktick && ascii_isspace_o(C.int(([^]u8)(str)[0])) {
				break
			}
			if ([^]u8)(str)[0] == '`' {
				inbacktick = !inbacktick
			}
			([^]u8)(p)[0] = ([^]u8)(str)[0]
			p = (^u8)(uintptr(p) + 1)
			str = (^u8)(uintptr(str) + 1)
		}
	}
	str = transmute(^u8)(skipwhite(transmute(cstring)(str)))
	([^]u8)(p)[0] = 0
	return str
}

// Separate arguments in str into the growarray.
get_arglist_o :: proc "c" (gap: ^Garray, str_in: ^u8, escaped: bool) {
	context = runtime.default_context()
	ga_init(gap, C.int(size_of(rawptr)), 20)
	str := str_in
	for ([^]u8)(str)[0] != 0 {
		ga_grow(gap, 1)
		([^]rawptr)(gap.ga_data)[gap.ga_len] = rawptr(str)
		gap.ga_len += 1
		if !escaped {
			return
		}
		str = do_one_arg_o(str)
	}
}

// Parse file names, expand them into fnames[fcountp].
@(export)
get_arglist_exp :: proc "c" (str: ^u8, fcountp: ^C.int, fnamesp: ^rawptr, wig: bool) -> C.int {
	context = runtime.default_context()
	ga: Garray
	get_arglist_o(&ga, str, true)
	i: C.int
	if wig {
		i = os_expand_wildcards(ga.ga_len, transmute(^^u8)(ga.ga_data), fcountp, transmute(^^^u8)(fnamesp), EW_FILE | EW_NOTFOUND | EW_NOTWILD_O)
	} else {
		i = gen_expand_wildcards_e(ga.ga_len, ga.ga_data, fcountp, fnamesp, EW_FILE | EW_NOTFOUND | EW_NOTWILD_O)
	}
	ga_clear(&ga)
	return i
}

// Set the argument list; takes over files[] and the names in it.
@(export)
alist_set :: proc "c" (al_raw: rawptr, count: C.int, files: [^]^u8, use_curbuf: C.int, fnum_list: [^]C.int, fnum_len: C.int) {
	context = runtime.default_context()
	al := (^Alist_T)(al_raw)
	if check_arglist_locked_o() == FAIL {
		return
	}
	alist_clear(al_raw)
	ga_grow((^Garray)(al_raw), count)
	i: C.int = 0
	for i < count {
		if got_int {
			for i < count {
				xfree(rawptr(files[i]))
				i += 1
			}
			break
		}
		if fnum_list != nil && i < fnum_len {
			arglist_locked_g = true
			buf_set_name(fnum_list[i], transmute(cstring)(files[i]))
			arglist_locked_g = false
		}
		sf: C.int = 1
		if use_curbuf != 0 {
			sf = 2
		}
		alist_add(al_raw, files[i], sf)
		os_breakcheck()
		i += 1
	}
	xfree(rawptr(files))
	if al_raw == rawptr(&global_alist_u8) {
		arg_had_last_g = false
	}
}

// Add file fname to argument list (room must be checked by caller).
@(export)
alist_add :: proc "c" (al_raw: rawptr, fname: ^u8, set_fnum: C.int) {
	context = runtime.default_context()
	al := (^Alist_T)(al_raw)
	if fname == nil {
		return
	}
	if check_arglist_locked_o() == FAIL {
		return
	}
	arglist_locked_g = true
	(^C.int)(uintptr(curwin) + W_LOCKED_OFF)^ += 1
	entries := alist_entries_o(al)
	entries[al.al_ga.ga_len].ae_fname = fname
	if set_fnum > 0 {
		flags: C.int = BLN_LISTED_O
		if set_fnum == 2 {
			flags |= BLN_CURBUF_O
		}
		entries[al.al_ga.ga_len].ae_fnum = buflist_add(transmute(cstring)(fname), flags)
	}
	al.al_ga.ga_len += 1
	arglist_locked_g = false
	(^C.int)(uintptr(curwin) + W_LOCKED_OFF)^ -= 1
}

// Check validity of arg_idx for windows sharing curwin's list.
alist_check_arg_idx_o :: proc "c" () {
	context = runtime.default_context()
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if win_alist_o(wp) == win_alist_o(curwin) {
				check_arg_idx(wp)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// Add files[count] to curwin's arglist after `after`.
alist_add_list_o :: proc "c" (count: C.int, files: [^]^u8, after: C.int, will_edit: bool) {
	context = runtime.default_context()
	al := win_alist_o(curwin)
	old_argcount := al.al_ga.ga_len
	if check_arglist_locked_o() != FAIL {
		ga_grow((^Garray)(rawptr(al)), count)
		a := after
		if a < 0 {
			a = 0
		}
		if a > al.al_ga.ga_len {
			a = al.al_ga.ga_len
		}
		entries := alist_entries_o(al)
		if a < al.al_ga.ga_len {
			libc.memmove(rawptr(uintptr(rawptr(entries)) + uintptr(a + count) * size_of(Aentry_T)), rawptr(uintptr(rawptr(entries)) + uintptr(a) * size_of(Aentry_T)), C.size_t((al.al_ga.ga_len - a) * C.int(size_of(Aentry_T))))
		}
		arglist_locked_g = true
		(^C.int)(uintptr(curwin) + W_LOCKED_OFF)^ += 1
		for i: C.int = 0; i < count; i += 1 {
			flags: C.int = BLN_LISTED_O
			if will_edit {
				flags |= BLN_CURBUF_O
			}
			entries[a + i].ae_fname = files[i]
			entries[a + i].ae_fnum = buflist_add(transmute(cstring)(files[i]), flags)
		}
		arglist_locked_g = false
		(^C.int)(uintptr(curwin) + W_LOCKED_OFF)^ -= 1
		al.al_ga.ga_len += count
		if old_argcount > 0 && (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ >= a {
			(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ += count
		}
	}
}

// Delete the file names in alist_ga from the argument list.
arglist_del_files_o :: proc "c" (alist_ga: ^Garray) {
	context = runtime.default_context()
	regmatch: Regmatch_T
	regmatch.rm_ic = p_fic_g
	al := win_alist_o(curwin)
	i: C.int = 0
	for i < alist_ga.ga_len && !got_int {
		p := ([^]^u8)(alist_ga.ga_data)[i]
		p = file_pat_to_reg_pat_r(transmute(cstring)(p), nil, nil, false)
		if p == nil {
			break
		}
		mg: C.int = 0
		if magic_isset() {
			mg = RE_MAGIC
		}
		regmatch.regprog = vim_regcomp(transmute(cstring)(p), mg)
		if regmatch.regprog == nil {
			xfree(rawptr(p))
			break
		}
		didone := false
		match: C.int = 0
		for match < al.al_ga.ga_len {
			entries := alist_entries_o(al)
			if vim_regexec_r(&regmatch, transmute(^u8)(alist_name(arg_entry_o(al, match))), 0) != 0 {
				didone = true
				xfree(rawptr(entries[match].ae_fname))
				libc.memmove(rawptr(uintptr(rawptr(entries)) + uintptr(match) * size_of(Aentry_T)), rawptr(uintptr(rawptr(entries)) + uintptr(match + 1) * size_of(Aentry_T)), C.size_t((al.al_ga.ga_len - match - 1) * C.int(size_of(Aentry_T))))
				al.al_ga.ga_len -= 1
				if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ > match {
					(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ -= 1
				}
				match -= 1
			}
			match += 1
		}
		vim_regfree(regmatch.regprog)
		xfree(rawptr(p))
		if !didone {
			semsg(cstring(E_NOMATCH2_S), transmute(cstring)(([^]^u8)(alist_ga.ga_data)[i]))
		}
		i += 1
	}
	ga_clear(alist_ga)
}

// Redefine/add/delete argument list entries from str.
do_arglist_o :: proc "c" (str_in: ^u8, what: C.int, after: C.int, will_edit: bool) -> C.int {
	context = runtime.default_context()
	if check_arglist_locked_o() == FAIL {
		return FAIL
	}
	str := str_in
	arg_escaped := true
	if what == AL_ADD_O && ([^]u8)(str)[0] == 0 {
		ffname := (^rawptr)(uintptr(curbuf) + B_FFNAME)^
		if ffname == nil {
			return FAIL
		}
		str = (^u8)(ffname)
		arg_escaped = false
	}
	new_ga: Garray
	get_arglist_o(&new_ga, str, arg_escaped)
	if what == AL_DEL_O {
		arglist_del_files_o(&new_ga)
	} else {
		exp_count: C.int = 0
		exp_files: [^]^u8 = nil
		i := os_expand_wildcards(new_ga.ga_len, transmute(^^u8)(new_ga.ga_data), &exp_count, transmute(^^^u8)(&exp_files), EW_DIR | EW_FILE | EW_ADDSLASH_O | EW_NOTFOUND)
		ga_clear(&new_ga)
		if i == FAIL || exp_count == 0 {
			emsg(cstring(E_NOMATCH_S))
			return FAIL
		}
		if what == AL_ADD_O {
			alist_add_list_o(exp_count, exp_files, after, will_edit)
			xfree(rawptr(exp_files))
		} else {
			uc: C.int = 0
			if will_edit {
				uc = 1
			}
			alist_set(rawptr(win_alist_o(curwin)), exp_count, exp_files, uc, nil, 0)
		}
	}
	alist_check_arg_idx_o()
	return OK
}

// Redefine the argument list.
@(export)
set_arglist :: proc "c" (str: ^u8) {
	context = runtime.default_context()
	do_arglist_o(str, AL_SET_O, 0, true)
}

// True if window win edits the file at its current argument index.
@(export)
editing_arg_idx :: proc "c" (win_raw: rawptr) -> bool {
	context = runtime.default_context()
	al := win_alist_o(win_raw)
	idx := (^C.int)(uintptr(win_raw) + W_ARG_IDX_OFF)^
	if idx >= al.al_ga.ga_len {
		return false
	}
	buf := (^rawptr)(uintptr(win_raw) + W_BUFFER_OFF)^
	if (^C.int)(uintptr(buf) + B_FNUM_OFF)^ == alist_entries_o(al)[idx].ae_fnum {
		return true
	}
	if (^rawptr)(uintptr(buf) + B_FFNAME)^ == nil {
		return false
	}
	cmp := path_full_compare_r(transmute(cstring)(alist_name(arg_entry_o(al, idx))), transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^), true, true)
	return (cmp & kEqualFiles_S) != 0
}

// Check if window win edits the w_arg_idx file in its argument list.
@(export)
check_arg_idx :: proc "c" (win_raw: rawptr) {
	context = runtime.default_context()
	al := win_alist_o(win_raw)
	buf := (^rawptr)(uintptr(win_raw) + W_BUFFER_OFF)^
	idx := (^C.int)(uintptr(win_raw) + W_ARG_IDX_OFF)^
	if al.al_ga.ga_len > 1 && !editing_arg_idx(win_raw) {
		(^bool)(uintptr(win_raw) + W_ARG_IDX_INVALID_OFF)^ = true
		g := global_alist_o()
		gl := g.al_ga.ga_len
		if idx != al.al_ga.ga_len - 1 && !arg_had_last_g && rawptr(al) == rawptr(&global_alist_u8) && gl > 0 && idx < gl {
			last := alist_entries_o(g)[gl - 1]
			if (^C.int)(uintptr(buf) + B_FNUM_OFF)^ == last.ae_fnum {
				arg_had_last_g = true
			} else if (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil {
				cmp := path_full_compare_r(transmute(cstring)(alist_name(arg_entry_o(g, gl - 1))), transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^), true, true)
				if (cmp & kEqualFiles_S) != 0 {
					arg_had_last_g = true
				}
			}
		}
	} else {
		(^bool)(uintptr(win_raw) + W_ARG_IDX_INVALID_OFF)^ = false
		if idx == al.al_ga.ga_len - 1 && rawptr(al) == rawptr(&global_alist_u8) {
			arg_had_last_g = true
		}
	}
}

CMD_args_O :: 7
CMD_argglobal_O :: 13
CMD_arglocal_O :: 14
CMD_snext_O :: 417
CMD_argdo_O :: 10

foreign _ {
	@(link_name = "list_in_columns")
	list_in_columns_e :: proc "c" (items: rawptr, size: C.int, current: C.int) ---
}

// ":args", ":arglocal" and ":argglobal".
@(export)
ex_args :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	cmdidx := (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^
	if cmdidx != CMD_args_O {
		if check_arglist_locked_o() == FAIL {
			return
		}
		alist_unlink(rawptr(win_alist_o(curwin)))
		if cmdidx == CMD_argglobal_O {
			(^rawptr)(uintptr(curwin) + W_ALIST_OFF)^ = rawptr(&global_alist_u8)
		} else {
			alist_new()
		}
	}
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	if ([^]u8)(rawptr(arg))[0] != 0 {
		if check_arglist_locked_o() == FAIL {
			return
		}
		ex_next(eap_raw)
		return
	}
	if cmdidx == CMD_args_O {
		al := win_alist_o(curwin)
		if al.al_ga.ga_len <= 0 {
			return
		}
		items := ([^]^u8)(xmalloc(C.size_t(al.al_ga.ga_len) * 8))
		gotocmdline_r(true)
		for i: C.int = 0; i < al.al_ga.ga_len; i += 1 {
			items[i] = alist_name(arg_entry_o(al, i))
		}
		list_in_columns_e(rawptr(items), al.al_ga.ga_len, (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^)
		xfree(rawptr(items))
		return
	}
	if cmdidx == CMD_arglocal_O {
		al := win_alist_o(curwin)
		g := global_alist_o()
		ga_grow((^Garray)(rawptr(al)), g.al_ga.ga_len)
		ga := (^Garray)(rawptr(al))
		src := alist_entries_o(g)
		for i: C.int = 0; i < g.al_ga.ga_len; i += 1 {
			if src[i].ae_fname != nil {
				dst := alist_entries_o(al)
				dst[ga.ga_len].ae_fname = xstrdup(src[i].ae_fname)
				dst[ga.ga_len].ae_fnum = src[i].ae_fnum
				ga.ga_len += 1
			}
		}
	}
}

// ":previous", ":sprevious", ":Next" and ":sNext".
@(export)
ex_previous :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	line2 := (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
	idx := (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
	count := win_alist_o(curwin).al_ga.ga_len
	if idx - line2 >= count {
		do_argfile(eap_raw, count - 1)
	} else {
		do_argfile(eap_raw, idx - line2)
	}
}

// ":rewind", ":first", ":sfirst" and ":srewind".
@(export)
ex_rewind :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	do_argfile(eap_raw, 0)
}

// ":last" and ":slast".
@(export)
ex_last :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	do_argfile(eap_raw, win_alist_o(curwin).al_ga.ga_len - 1)
}

// ":argument" and ":sargument".
@(export)
ex_argument :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	i: C.int
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ > 0 {
		i = (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ - 1
	} else {
		i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
	}
	do_argfile(eap_raw, i)
}

// Edit file argn of the argument lists.
@(export)
do_argfile :: proc "c" (eap_raw: rawptr, argn: C.int) {
	context = runtime.default_context()
	cmd := (^cstring)(uintptr(eap_raw) + EXARG_CMD_OFF)^
	is_split_cmd := ([^]u8)(rawptr(cmd))[0] == 's'
	old_arg_idx := (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
	al := win_alist_o(curwin)
	count := al.al_ga.ga_len
	if argn < 0 || argn >= count {
		if count <= 1 {
			emsg(cstring(E163_S))
		} else if argn < 0 {
			emsg(cstring(E164_S))
		} else {
			emsg(cstring(E165_S))
		}
		return
	}
	forceit := (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^
	entries := alist_entries_o(al)
	if !is_split_cmd && entries[argn].ae_fnum != (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ && !check_can_set_curbuf_forceit(forceit) {
		return
	}
	setpcmark()
	if is_split_cmd || cmdmod_tab_o() != 0 {
		if win_split(0, 0) == FAIL {
			return
		}
		(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false
		(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
	} else {
		other := true
		if buf_hide(curbuf) {
			p := fix_fname_r(transmute(cstring)(alist_name(arg_entry_o(win_alist_o(curwin), argn))))
			other = otherfile(transmute(cstring)(p))
			xfree(rawptr(p))
		}
		ccgd: C.int = CCGD_AW_O
		if !other {
			ccgd |= CCGD_MULTWIN_O
		}
		if forceit != 0 {
			ccgd |= CCGD_FORCEIT_O
		}
		ccgd |= CCGD_EXCMD_O
		if (!buf_hide(curbuf) || !other) && check_changed(curbuf, ccgd) {
			return
		}
	}
	(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = argn
	if argn == win_alist_o(curwin).al_ga.ga_len - 1 && rawptr(win_alist_o(curwin)) == rawptr(&global_alist_u8) {
		arg_had_last_g = true
	}
	flags: C.int = 0
	if buf_hide(curbuf) {
		flags |= ECMD_HIDE_O
	}
	if forceit != 0 {
		flags |= ECMD_FORCEIT_O
	}
	name := alist_name(arg_entry_o(win_alist_o(curwin), (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^))
	if do_ecmd(0, transmute(cstring)(name), nil, eap_raw, ECMD_LAST_O, flags, curwin) == FAIL {
		(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = old_arg_idx
	} else if (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^ != CMD_argdo_O {
		setmark(39)
	}
}

// ":next", and commands that behave like it.
@(export)
ex_next :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	forceit := (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^
	ccgd: C.int = CCGD_AW_O
	if forceit != 0 {
		ccgd |= CCGD_FORCEIT_O
	}
	ccgd |= CCGD_EXCMD_O
	if buf_hide(curbuf) || (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^ == CMD_snext_O || !check_changed(curbuf, ccgd) {
		arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
		i: C.int
		if ([^]u8)(rawptr(arg))[0] != 0 {
			if do_arglist_o(transmute(^u8)(arg), AL_SET_O, 0, true) == FAIL {
				return
			}
			i = 0
		} else {
			i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
		}
		do_argfile(eap_raw, i)
	}
}

// ":argdedupe".
@(export)
ex_argdedupe :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	al := win_alist_o(curwin)
	for i: C.int = 0; i < al.al_ga.ga_len; i += 1 {
		entries := alist_entries_o(al)
		first := FullName_save_e(transmute(cstring)(entries[i].ae_fname), false)
		j := i + 1
		for j < al.al_ga.ga_len {
			entries = alist_entries_o(al)
			second := FullName_save_e(transmute(cstring)(entries[j].ae_fname), false)
			dup := path_fnamecmp_r(transmute(cstring)(first), transmute(cstring)(second)) == 0
			xfree(rawptr(second))
			if dup {
				xfree(rawptr(entries[j].ae_fname))
				entries = alist_entries_o(al)
				libc.memmove(rawptr(uintptr(rawptr(entries)) + uintptr(j) * size_of(Aentry_T)), rawptr(uintptr(rawptr(entries)) + uintptr(j + 1) * size_of(Aentry_T)), C.size_t((al.al_ga.ga_len - j - 1) * C.int(size_of(Aentry_T))))
				al.al_ga.ga_len -= 1
				idx := (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
				if idx == j {
					(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = i
				} else if idx > j {
					(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ -= 1
				}
				j -= 1
			}
			j += 1
		}
		xfree(rawptr(first))
	}
}

// ":argedit".
@(export)
ex_argedit :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	i: C.int
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ != 0 {
		i = (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
	} else {
		i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
	}
	curbuf_is_reusable := curbuf_reusable()
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	if do_arglist_o(transmute(^u8)(arg), AL_ADD_O, i, true) == FAIL {
		return
	}
	maketitle()
	al := win_alist_o(curwin)
	if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ == 0 && ((^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O) != 0 && ((^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil || curbuf_is_reusable) {
		i = 0
	}
	if i < al.al_ga.ga_len {
		do_argfile(eap_raw, i)
	}
}

// ":argadd".
@(export)
ex_argadd :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	i: C.int
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ > 0 {
		i = (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
	} else {
		i = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
	}
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	do_arglist_o(transmute(^u8)(arg), AL_ADD_O, i, false)
	maketitle()
}

// ":argdelete".
@(export)
ex_argdelete :: proc "c" (eap_raw: rawptr) {
	context = runtime.default_context()
	if check_arglist_locked_o() == FAIL {
		return
	}
	arg := (^cstring)(uintptr(eap_raw) + EXARG_ARG_OFF)^
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ > 0 || ([^]u8)(rawptr(arg))[0] == 0 {
		if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ == 0 {
			al := win_alist_o(curwin)
			if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ >= al.al_ga.ga_len {
				emsg(cstring(E610_S))
				return
			}
			(^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^ = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
			(^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ = (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ + 1
		} else if (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ > win_alist_o(curwin).al_ga.ga_len {
			(^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ = win_alist_o(curwin).al_ga.ga_len
		}
		line1 := (^C.int)(uintptr(eap_raw) + EXARG_LINE1_OFF)^
		line2 := (^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^
		n := line2 - line1 + 1
		if ([^]u8)(rawptr(arg))[0] != 0 {
			emsg(cstring(e_invarg_s))
		} else if n <= 0 {
			if line1 != 1 || line2 != 0 {
				emsg(cstring(E_INVRANGE_S))
			}
		} else {
			al := win_alist_o(curwin)
			entries := alist_entries_o(al)
			for k := line1; k <= line2; k += 1 {
				xfree(rawptr(entries[k - 1].ae_fname))
			}
			libc.memmove(rawptr(uintptr(rawptr(entries)) + uintptr(line1 - 1) * size_of(Aentry_T)), rawptr(uintptr(rawptr(entries)) + uintptr(line2) * size_of(Aentry_T)), C.size_t((al.al_ga.ga_len - line2) * C.int(size_of(Aentry_T))))
			al.al_ga.ga_len -= C.int(n)
			idx := (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^
			if idx >= line2 {
				(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ -= C.int(n)
			} else if idx > line1 {
				(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = C.int(line1)
			}
			if al.al_ga.ga_len == 0 {
				(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = 0
			} else if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ >= al.al_ga.ga_len {
				(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = al.al_ga.ga_len - 1
			}
		}
	} else {
		do_arglist_o(transmute(^u8)(arg), AL_DEL_O, 0, false)
	}
	maketitle()
}

// Expand function for :argedit and :argdelete file names.
@(export)
get_arglist_name :: proc "c" (xp_raw: rawptr, idx: C.int) -> ^u8 {
	context = runtime.default_context()
	al := win_alist_o(curwin)
	if idx >= al.al_ga.ga_len {
		return nil
	}
	return alist_name(arg_entry_o(al, idx))
}

E249_S :: "E249: Window layout changed unexpectedly"
CMD_drop_O :: 130

// State for :all (cc-probed layout, 48B).
Arg_All_State_T :: struct {
	alist:       rawptr,
	had_tab:     C.int,
	keep_tabs:   bool,
	forceit:     bool,
	use_firstwin: bool,
	_pad:        u8,
	opened:      ^u8,
	opened_len:  C.int,
	_pad2:       C.int,
	new_curwin:  rawptr,
	new_curtab:  rawptr,
}
#assert(size_of(Arg_All_State_T) == 48)

win_is_floating_o :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	return (^bool)(uintptr(wp) + W_FLOATING_OFF)^
}

win_frame_parent_o :: proc "c" (wp: rawptr) -> rawptr {
	context = runtime.default_context()
	return (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_FRAME_OFF)^) + uintptr(FR_PARENT_OFF))^
}

// Close windows with files not in the argument list.
arg_all_close_unused_windows_o :: proc "c" (aall: ^Arg_All_State_T) {
	context = runtime.default_context()
	old_curwin := curwin
	old_curtab := curtab
	if aall.had_tab > 0 {
		goto_tabpage_tp(first_tabpage, true, true)
	}
	tabpage_move_disallowed_g += 1
	for {
		wpnext: rawptr = nil
		tpnext := (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
		wp := lastwin_g
		if !win_is_floating_o(wp) {
			wp = firstwin
		}
		for wp != nil {
			if win_is_floating_o(wp) {
				prev := (^rawptr)(uintptr(wp) + W_PREV_OFF)^
				if win_is_floating_o(prev) {
					wpnext = prev
				} else {
					wpnext = firstwin
				}
			} else {
				next := (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				if next == nil || win_is_floating_o(next) {
					wpnext = nil
				} else {
					wpnext = next
				}
			}
			buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
			ffname := (^rawptr)(uintptr(buf) + B_FFNAME)^
			i := aall.opened_len
			if ffname != nil && (aall.keep_tabs || !((^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ > 1 || (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ != Columns || (win_is_floating_o(wp) && !is_aucmd_win_r(wp)))) {
				al := (^Alist_T)(aall.alist)
				for k: C.int = 0; k < aall.opened_len; k += 1 {
					if k < al.al_ga.ga_len {
						entries := alist_entries_o(al)
						bfnum := (^C.int)(uintptr(buf) + B_FNUM_OFF)^
						hit := entries[k].ae_fnum == bfnum
						if !hit {
							cmp := path_full_compare_r(transmute(cstring)(alist_name(arg_entry_o(al, k))), transmute(cstring)(ffname), true, true)
							hit = (cmp & kEqualFiles_S) != 0
						}
						if hit {
							weight: C.int = 1
							if old_curtab == curtab {
								weight += 1
								if old_curwin == wp {
									weight += 1
								}
							}
							if weight > C.int(([^]u8)(aall.opened)[k]) {
								([^]u8)(aall.opened)[k] = u8(weight)
								if k == 0 {
									if aall.new_curwin != nil {
										(^C.int)(uintptr(aall.new_curwin) + W_ARG_IDX_OFF)^ = aall.opened_len
									}
									aall.new_curwin = wp
									aall.new_curtab = curtab
								}
								i = k
							} else if aall.keep_tabs {
								i = aall.opened_len
							} else {
								i = k
							}
							if (^rawptr)(uintptr(wp) + W_ALIST_OFF)^ != aall.alist {
								alist_unlink((^rawptr)(uintptr(wp) + W_ALIST_OFF)^)
								(^rawptr)(uintptr(wp) + W_ALIST_OFF)^ = aall.alist
								(^Alist_T)(aall.alist).al_refcount += 1
							}
							break
						}
					}
				}
			}
			(^C.int)(uintptr(wp) + W_ARG_IDX_OFF)^ = i
			if i == aall.opened_len && !aall.keep_tabs {
				if buf_hide(buf) || aall.forceit || (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ > 1 || !bufIsChanged(buf) {
					if !buf_hide(buf) && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 1 && bufIsChanged(buf) {
						bufref: Bufref_T
						set_bufref(&bufref, buf)
						autowrite(buf, false)
						if !win_valid(wp) || !bufref_valid(&bufref) {
							wpnext = lastwin_g
							if !win_is_floating_o(wpnext) {
								wpnext = firstwin
							}
							wp = wpnext
							continue
						}
					}
					first_tp_next := (^rawptr)(uintptr(first_tabpage) + TP_NEXT_OFF)^
					if only_one_window() && (first_tp_next == nil || aall.had_tab == 0) {
						aall.use_firstwin = true
					} else {
						win_close(wp, !buf_hide(buf) && !bufIsChanged(buf), false)
						if !win_valid(wpnext) {
							wpnext = lastwin_g
							if !win_is_floating_o(wpnext) {
								wpnext = firstwin
							}
						}
					}
				}
			}
			wp = wpnext
		}
		if aall.had_tab == 0 || tpnext == nil {
			break
		}
		if !valid_tabpage(tpnext) {
			tpnext = first_tabpage
		}
		goto_tabpage_tp(tpnext, true, true)
	}
	tabpage_move_disallowed_g -= 1
}

// Open up to count windows for files in the argument list.
arg_all_open_windows_o :: proc "c" (aall: ^Arg_All_State_T, count_in: C.int) {
	context = runtime.default_context()
	count := count_in
	tab_drop_empty_window := false
	if aall.keep_tabs && buf_is_empty(curbuf) && (^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ == 1 && (^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil && !(^bool)(uintptr(curbuf) + B_CHANGED)^ {
		aall.use_firstwin = true
		tab_drop_empty_window = true
	}
	split_ret: C.int = OK
	al := (^Alist_T)(aall.alist)
	i: C.int = 0
	for i < count && !got_int {
		if aall.alist == rawptr(&global_alist_u8) && i == al.al_ga.ga_len - 1 {
			arg_had_last_g = true
		}
		if ([^]u8)(aall.opened)[i] > 0 {
			if (^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ != i {
				wp := firstwin
				for wp != nil {
					if (^C.int)(uintptr(wp) + W_ARG_IDX_OFF)^ == i {
						if aall.keep_tabs {
							aall.new_curwin = wp
							aall.new_curtab = curtab
						} else if win_is_floating_o(wp) {
							break
						} else if win_frame_parent_o(wp) != win_frame_parent_o(curwin) {
							emsg(cstring(E249_S))
							i = count
							break
						} else {
							win_move_after(wp, curwin)
						}
						break
					}
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				}
			}
		} else if split_ret == OK {
			if tab_drop_empty_window && i == count - 1 {
				autocmd_no_enter_g -= 1
			}
			if !aall.use_firstwin {
				p_ea_save := p_ea_g
				p_ea_g = 1
				split_ret = win_split(0, WSP_ROOM_O | WSP_BELOW_O)
				p_ea_g = p_ea_save
				if split_ret == FAIL {
					i += 1
					continue
				}
			} else {
				autocmd_no_leave_g -= 1
			}
			(^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^ = i
			if i == 0 {
				aall.new_curwin = curwin
				aall.new_curtab = curtab
			}
			flags: C.int = ECMD_OLDBUF_O
			buf := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
			if buf_hide(buf) || bufIsChanged(buf) {
				flags |= ECMD_HIDE_O
			}
			do_ecmd(0, transmute(cstring)(alist_name(arg_entry_o(al, i))), nil, nil, ECMD_ONE_O, flags, curwin)
			if tab_drop_empty_window && i == count - 1 {
				autocmd_no_enter_g += 1
			}
			if aall.use_firstwin {
				autocmd_no_leave_g += 1
			}
			aall.use_firstwin = false
		}
		os_breakcheck()
		if aall.had_tab > 0 && tabpage_index(nil) <= C.int(p_tpm_g) {
			set_cmdmod_tab_o(9999)
		}
		i += 1
	}
}

// Open up to count windows, one for each argument.
do_arg_all_o :: proc "c" (count_in: C.int, forceit: bool, keep_tabs: bool) {
	context = runtime.default_context()
	if firstwin == nil {
		libc.abort()
	}
	al := win_alist_o(curwin)
	if al.al_ga.ga_len <= 0 {
		return
	}
	setpcmark()
	aall: Arg_All_State_T
	aall.use_firstwin = false
	aall.had_tab = cmdmod_tab_o()
	aall.new_curwin = nil
	aall.new_curtab = nil
	aall.forceit = forceit
	aall.keep_tabs = keep_tabs
	aall.opened_len = al.al_ga.ga_len
	aall.opened = (^u8)(xcalloc(C.size_t(al.al_ga.ga_len), 1))
	aall.alist = rawptr(al)
	al.al_refcount += 1
	prev_arglist_locked := arglist_locked_g
	arglist_locked_g = true
	new_lu_tp := curtab
	reset_VIsual_and_resel_r()
	arg_all_close_unused_windows_o(&aall)
	count := count_in
	if count > aall.opened_len || count <= 0 {
		count = aall.opened_len
	}
	autocmd_no_enter_g += 1
	autocmd_no_leave_g += 1
	last_curwin := curwin
	last_curtab := curtab
	win_enter(lastwin_nofloating(nil), false)
	arg_all_open_windows_o(&aall, count)
	alist_unlink(aall.alist)
	arglist_locked_g = prev_arglist_locked
	autocmd_no_enter_g -= 1
	if last_curtab != aall.new_curtab {
		if valid_tabpage(last_curtab) {
			goto_tabpage_tp(last_curtab, true, true)
		}
		if win_valid(last_curwin) {
			win_enter(last_curwin, false)
		}
	}
	if valid_tabpage(aall.new_curtab) {
		goto_tabpage_tp(aall.new_curtab, true, true)
	}
	if valid_tabpage(new_lu_tp) {
		lastused_tabpage_g = new_lu_tp
	}
	if win_valid(aall.new_curwin) {
		win_enter(aall.new_curwin, false)
	}
	autocmd_no_leave_g -= 1
	xfree(rawptr(aall.opened))
}

// ":all" and ":sall".
@(export)
ex_all :: proc "c" (eap_raw: rawptr) {	context = runtime.default_context()
	if (^C.int)(uintptr(eap_raw) + EXARG_ADDR_COUNT_OFF)^ == 0 {
		(^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^ = 9999
	}
	do_arg_all_o((^C.int)(uintptr(eap_raw) + EXARG_LINE2_OFF)^, (^C.int)(uintptr(eap_raw) + EXARG_FORCEIT_OFF)^ != 0, (^C.int)(uintptr(eap_raw) + EXARG_CMDIDX_OFF)^ == CMD_drop_O)
}

// Concatenate all arglist files, space-separated, backslash-escaped.
@(export)
arg_all :: proc "c" () -> ^u8 {
	context = runtime.default_context()
	retval: [^]u8 = nil
	for {
		len: C.int = 0
		al := win_alist_o(curwin)
		for idx: C.int = 0; idx < al.al_ga.ga_len; idx += 1 {
			p := alist_name(arg_entry_o(al, idx))
			if p == nil {
				continue
			}
			if len > 0 {
				if retval != nil {
					retval[len] = ' '
				}
				len += 1
			}
			for ([^]u8)(p)[0] != 0 {
				c := ([^]u8)(p)[0]
				if c == ' ' || c == '\\' || c == '`' {
					if retval != nil {
						retval[len] = '\\'
					}
					len += 1
				}
				if retval != nil {
					retval[len] = c
				}
				len += 1
				p = (^u8)(uintptr(p) + 1)
			}
		}
		if retval != nil {
			retval[len] = 0
			break
		}
		retval = ([^]u8)(xmalloc(C.size_t(len) + 1))
	}
	return transmute(^u8)(retval)
}

// "argc([window id])" function.
@(export)
f_argc :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if argvars.v_type == VAR_UNKNOWN {
		rettv.vval = transmute(rawptr)(C.longlong(win_alist_o(curwin).al_ga.ga_len))
	} else if argvars.v_type == VAR_NUMBER && tv_get_number((^Typval_T)(uintptr(argvars))) == -1 {
		rettv.vval = transmute(rawptr)(C.longlong(global_alist_o().al_ga.ga_len))
	} else {
		wp := find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
		if wp != nil {
			rettv.vval = transmute(rawptr)(C.longlong(win_alist_o(wp).al_ga.ga_len))
		} else {
			rettv.vval = transmute(rawptr)(C.longlong(-1))
		}
	}
}

// "argidx()" function.
@(export)
f_argidx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(curwin) + W_ARG_IDX_OFF)^))
}

// "arglistid()" function.
@(export)
f_arglistid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	wp := find_tabwin((^Typval_T)(uintptr(argvars)), (^Typval_T)(uintptr(argvars) + 16))
	if wp != nil {
		rettv.vval = transmute(rawptr)(C.longlong(win_alist_o(wp).id))
	}
}

// Build a list rettv from an argument array.
get_arglist_as_rettv_o :: proc "c" (arglist_raw: rawptr, argcount: C.int, rettv: ^Typval_T) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), argcount)
	if arglist_raw != nil {
		entries := ([^]Aentry_T)(arglist_raw)
		for idx: C.int = 0; idx < argcount; idx += 1 {
			tv_list_append_string(rawptr(rettv.vval), alist_name(rawptr(uintptr(arglist_raw) + uintptr(idx) * size_of(Aentry_T))), -1)
		}
		_ = entries
	}
}

// "argv(nr)" function.
@(export)
f_argv :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	arglist_raw: rawptr = nil
	argcount: C.int = -1
	if argvars.v_type == VAR_UNKNOWN {
		get_arglist_as_rettv_o(rawptr(alist_entries_o(win_alist_o(curwin))), win_alist_o(curwin).al_ga.ga_len, rettv)
		return
	}
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if a1.v_type == VAR_UNKNOWN {
		arglist_raw = rawptr(alist_entries_o(win_alist_o(curwin)))
		argcount = win_alist_o(curwin).al_ga.ga_len
	} else if a1.v_type == VAR_NUMBER && tv_get_number(a1) == -1 {
		arglist_raw = rawptr(alist_entries_o(global_alist_o()))
		argcount = global_alist_o().al_ga.ga_len
	} else {
		wp := find_win_by_nr_or_id(a1)
		if wp != nil {
			arglist_raw = rawptr(alist_entries_o(win_alist_o(wp)))
			argcount = win_alist_o(wp).al_ga.ga_len
		}
	}
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	idx := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil))
	if arglist_raw != nil && idx >= 0 && idx < argcount {
		rettv.vval = rawptr(xstrdup(alist_name(rawptr(uintptr(arglist_raw) + uintptr(idx) * size_of(Aentry_T)))))
	} else if idx == -1 {
		get_arglist_as_rettv_o(arglist_raw, argcount, rettv)
	}
}
