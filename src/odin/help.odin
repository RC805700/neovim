package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// help.c port: :help windowing, tag lookup, :helptags generation.
// All 11 publics are @(export); compare/callbacks are plains (C-statics).

foreign _ {
	@(link_name = "p_hh")
	p_hh_g: C.longlong
	@(link_name = "find_tags")
	find_tags_e :: proc "c" (pat: cstring, num_matches: ^C.int, matchesp: ^rawptr, flags: C.int, mincount: C.int, buf_ffname: cstring) -> C.int ---
	@(link_name = "FreeWild")
	freewild_e :: proc "c" (count: C.int, files: rawptr) ---
	@(link_name = "gen_expand_wildcards")
	gen_expand_wildcards_e :: proc "c" (num_pat: C.int, pat: rawptr, num_file: ^C.int, file: ^rawptr, flags: C.int) -> C.int ---
	@(link_name = "do_in_path")
	do_in_path_e :: proc "c" (path: cstring, prefix: cstring, name: cstring, flags: C.int, cb: rawptr, cookie: rawptr) -> C.int ---
}

TAG_HELP_O :: 1
TAG_NAMES_O :: 2
TAG_REGEXP_O :: 4
TAG_VERBOSE_O :: 32
TAG_KEEP_LANG_O :: 128
TAG_NO_TAGFUNC_O :: 256
TAG_MANY_O :: 300
DT_HELP_O :: 8
DIP_ALL_O :: 0x01
DIP_DIR_O :: 0x02

// Whitespace set for vim_strchr (stable address).
@(private = "file")
SPC_TAB_NL_CR_O: [5]u8 = {' ', '\t', '\n', '\r', 0}

E149_S :: "E149: No help for %s"
E150_S :: "E150: Not a directory: %s"
E151_S :: "E151: No match: %s"
E152_S :: "E152: Cannot open %s for writing"
E153_S :: "E153: Unable to open %s for reading"
E154_S :: "E154: Duplicate tag \"%s\" in file %s/%s"
E661_S :: "E661: No '%s' help for %s"
E_NOIDENT_S :: "E349: No identifier under cursor"
E_FNAMETOOLONG_S :: "E856: Filename too long"

// ":help": open a read-only window on a help file.
@(export)
ex_help :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg: ^u8 = nil
	lang: ^u8 = nil
	tag: ^u8 = nil
	allocated_arg: ^u8 = nil
	empty_fnum: C.int = 0
	alt_fnum: C.int = 0
	old_KeyTyped := KeyTyped
	if eap != nil {
		arg = transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
		for ([^]u8)(arg)[0] != 0 {
			b := ([^]u8)(arg)[0]
			if b == '\n' || b == '\r' || (b == '|' && ([^]u8)(arg)[1] != 0 && ([^]u8)(arg)[1] != '|') {
				([^]u8)(arg)[0] = 0
				arg = (^u8)(uintptr(arg) + 1)
				(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^ = rawptr(arg)
				break
			}
			arg = (^u8)(uintptr(arg) + 1)
		}
		arg = transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
		if (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
			return
		}
	} else {
		arg = transmute(^u8)(cstring(""))
	}
	p := (^u8)(uintptr(arg) + uintptr(libc.strlen(transmute(cstring)(arg))) - 1)
	for uintptr(p) > uintptr(arg) && ascii_iswhite(([^]u8)(p)[0]) && ([^]u8)((^u8)(uintptr(p) - 1))[0] != '\\' {
		([^]u8)(p)[0] = 0
		p = (^u8)(uintptr(p) - 1)
	}
	lang = transmute(^u8)(check_help_lang(arg))
	helpbang := eap != nil && (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0 && ([^]u8)(arg)[0] == 0
	if ([^]u8)(arg)[0] == 0 && !helpbang {
		arg = transmute(^u8)(cstring("help.txt"))
	}
	if helpbang {
		no_args := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
		rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
		nlua_call_typval_e(cstring("vim._core.help"), cstring("resolve_tag"), &no_args, &rettv)
		if rettv.v_type == VAR_STRING && rawptr(rettv.vval) != nil && ([^]u8)(rawptr(rettv.vval))[0] != 0 {
			allocated_arg = transmute(^u8)(rettv.vval)
			arg = allocated_arg
		} else {
			tv_clear(&rettv)
			emsg(cstring(E_NOIDENT_S))
			return
		}
	}
	num_matches: C.int = 0
	matches: rawptr = nil
	n := find_help_tags(transmute(cstring)(arg), &num_matches, &matches, eap != nil && (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0)
	i: C.int = 0
	if n != FAIL_E && lang != nil {
		for i = 0; i < num_matches; i += 1 {
			m := transmute(^u8)(([^]rawptr)(matches)[uintptr(i)])
			l := C.int(libc.strlen(transmute(cstring)(m)))
			if l > 3 && ([^]u8)(m)[uintptr(l) - 3] == '@' && libc.strncmp(transmute(cstring)((^u8)(uintptr(m) + uintptr(l) - 2)), transmute(cstring)(lang), 2) == 0 {
				break
			}
		}
	}
	if i >= num_matches || n == FAIL_E {
		if lang != nil {
			semsg(cstring(E661_S), transmute(cstring)(lang), transmute(cstring)(arg))
		} else {
			semsg(cstring(E149_S), transmute(cstring)(arg))
		}
		if n != FAIL_E {
			freewild_e(num_matches, matches)
		}
		xfree(rawptr(allocated_arg))
		return
	}
	for _ in 0..<1 {
		tag = xstrdup(transmute(^u8)(([^]rawptr)(matches)[uintptr(i)]))
		freewild_e(num_matches, matches)
		wp: rawptr = nil
		if !bt_help((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) || cmdmod_tab_o() != 0 {
			if cmdmod_tab_o() == 0 {
				wp2 := firstwin
				for wp2 != nil {
					if bt_help((^rawptr)(uintptr(wp2) + W_BUFFER_OFF)^) && ([^]u8)(rawptr(uintptr(wp2) + W_CONFIG_OFF + 470))[0] == 0 && ([^]u8)(rawptr(uintptr(wp2) + W_CONFIG_OFF + 49))[0] != 0 {
						wp = wp2
						break
					}
					wp2 = (^rawptr)(uintptr(wp2) + W_NEXT_OFF)^
				}
			}
			if wp != nil && (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ > 0 {
				win_enter(wp, true)
			} else {
				helpfd := os_fopen(transmute(cstring)(p_hf), READBIN)
				if helpfd == nil {
					smsg(0, _t(cstring("Help file \"%s\" not found")), p_hf)
					break
				}
				libc.fclose((^libc.FILE)(helpfd))
				n: C.int = WSP_HELP_O
				if cmdmod_split_o() == 0 && (^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ != Columns && (^C.int)(uintptr(curwin) + W_WIDTH_OFF)^ < 80 {
					n |= WSP_BOT_O if p_sb_g != 0 else WSP_TOP_O
				}
				if win_split(0, n) == FAIL_E {
					break
				}
				if (^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^ < C.int(p_hh_g) {
					win_setheight(C.int(p_hh_g))
				}
				alt_fnum = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
				do_ecmd(0, nil, nil, nil, ECMD_LASTL_O, ECMD_HIDE_O + ECMD_SET_HELP_O, nil)
				if (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
					(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ = alt_fnum
				}
				empty_fnum = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
			}
		}
		restart_edit = 0
		KeyTyped = old_KeyTyped
		do_tag_e(nil, transmute(cstring)(tag), DT_HELP_O, 1, false, true)
		if empty_fnum != 0 && (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ != empty_fnum {
			buf := buflist_findnr(empty_fnum)
			if buf != nil && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0 {
				wipe_buffer(buf, true)
			}
		}
		if alt_fnum != 0 && (^C.int)(uintptr(curwin) + W_ALT_FNUM)^ == empty_fnum && (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
			(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ = alt_fnum
		}
		break
	}
	xfree(rawptr(tag))
	xfree(rawptr(allocated_arg))
}

// ":helpclose": close one help window.
@(export)
ex_helpclose :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	wp := firstwin
	for wp != nil {
		if bt_help((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
			win_close(wp, false, (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^ != 0)
			return
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
}

// Find "@xx" language specifier (writes NUL over @).
@(export)
check_help_lang :: proc "c" (arg: ^u8) -> ^u8 {
	context = runtime.default_context()
	l := C.int(libc.strlen(transmute(cstring)(arg)))
	if l >= 3 && ([^]u8)(arg)[uintptr(l) - 3] == '@' && ascii_isalpha_o(([^]u8)(arg)[uintptr(l) - 2]) && ascii_isalpha_o(([^]u8)(arg)[uintptr(l) - 1]) {
		([^]u8)(arg)[uintptr(l) - 3] = 0
		return (^u8)(uintptr(arg) + uintptr(l) - 2)
	}
	return nil
}

// Alnum test (ASCII_ISALNUM equivalent).
is_alnum_o :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	if c >= 'a' && c <= 'z' {
		return true
	}
	if c >= 'A' && c <= 'Z' {
		return true
	}
	if c >= '0' && c <= '9' {
		return true
	}
	return false
}

// Heuristic match quality (smaller is better).
@(export)
help_heuristic :: proc "c" (matched_string: ^u8, offset_in: C.int, wrong_case: bool) -> C.int {
	context = runtime.default_context()
	offset := offset_in
	num_letters: C.int = 0
	for p := matched_string; ([^]u8)(p)[0] != 0; p = (^u8)(uintptr(p) + 1) {
		if is_alnum_o(([^]u8)(p)[0]) {
			num_letters += 1
		}
	}
	if offset > 0 && is_alnum_o(([^]u8)(matched_string)[uintptr(offset)]) && is_alnum_o(([^]u8)(matched_string)[uintptr(offset) - 1]) {
		offset += 10000
	} else if offset > 2 {
		offset *= 200
	}
	if wrong_case {
		offset += 5000
	}
	if ([^]u8)(matched_string)[0] == '+' && ([^]u8)(matched_string)[1] != 0 {
		offset += 100
	}
	return 100 * num_letters + C.int(libc.strlen(transmute(cstring)(matched_string))) + offset
}

help_compare_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	a := transmute(^u8)((^rawptr)(s1)^)
	b := transmute(^u8)((^rawptr)(s2)^)
	p1 := (^u8)(uintptr(a) + uintptr(libc.strlen(transmute(cstring)(a))) + 1)
	p2 := (^u8)(uintptr(b) + uintptr(libc.strlen(transmute(cstring)(b))) + 1)
	cmp := libc.strcmp(transmute(cstring)(p1), transmute(cstring)(p2))
	if cmp != 0 {
		return cmp
	}
	return libc.strcmp(transmute(cstring)(a), transmute(cstring)(b))
}

// Find help tags matching arg (sorted, best first).
@(export)
find_help_tags :: proc "c" (arg: cstring, num_matches: ^C.int, matches: ^rawptr, keep_lang: bool) -> C.int {
	context = runtime.default_context()
	tv_args := [2]Typval_T{Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(arg)}, Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}}
	rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	nlua_call_typval_e(cstring("vim._core.help"), cstring("escape_subject"), &tv_args[0], &rettv)
	if rettv.v_type != VAR_STRING || rawptr(rettv.vval) == nil {
		tv_clear(&rettv)
		return FAIL_E
	}
	xstrlcpy(transmute(cstring)(&IObuff[0]), transmute(cstring)(rettv.vval), IOSIZE_O)
	tv_clear(&rettv)
	matches^ = nil
	num_matches^ = 0
	flags: C.int = TAG_HELP_O | TAG_REGEXP_O | TAG_NAMES_O | TAG_VERBOSE_O | TAG_NO_TAGFUNC_O
	if keep_lang {
		flags |= TAG_KEEP_LANG_O
	}
	if find_tags_e(transmute(cstring)(&IObuff[0]), num_matches, matches, flags, MAXCOL, nil) == OK_E && num_matches^ > 0 {
		qsort_e(matches^, C.size_t(num_matches^), C.size_t(size_of(rawptr)), help_compare_o)
		for num_matches^ > TAG_MANY_O {
			num_matches^ -= 1
			xfree(([^]rawptr)(matches^)[uintptr(num_matches^)])
		}
	}
	return OK_E
}

// Drop redundant "@xx" language suffixes from tag files.
@(export)
cleanup_help_tags :: proc "c" (num_file: C.int, file: [^]cstring) {
	context = runtime.default_context()
	buf: [4]u8
	p := &buf[0]
	hl := p_hlg_g
	if ([^]u8)(hl)[0] != 0 && (([^]u8)(hl)[0] != 'e' || ([^]u8)(hl)[1] != 'n') {
		([^]u8)(p)[0] = '@'
		([^]u8)(p)[1] = ([^]u8)(hl)[0]
		([^]u8)(p)[2] = ([^]u8)(hl)[1]
		p = (^u8)(uintptr(p) + 3)
	}
	([^]u8)(p)[0] = 0
	for i: C.int = 0; i < num_file; i += 1 {
		l := C.int(libc.strlen(file[i])) - 3
		if l <= 0 {
			continue
		}
		if libc.strcmp(transmute(cstring)((^u8)(uintptr(rawptr(file[i])) + uintptr(l))), cstring("@en")) == 0 {
			j: C.int = 0
			for j = 0; j < num_file; j += 1 {
				if j != i && C.int(libc.strlen(file[j])) == l + 3 && libc.strncmp(file[i], file[j], C.size_t(l) + 1) == 0 {
					break
				}
			}
			if j == num_file {
				([^]u8)(rawptr(file[i]))[uintptr(l)] = 0
			}
		}
	}
	if ([^]u8)(&buf[0])[0] != 0 {
		for i: C.int = 0; i < num_file; i += 1 {
			l := C.int(libc.strlen(file[i])) - 3
			if l <= 0 {
				continue
			}
			if libc.strcmp(transmute(cstring)((^u8)(uintptr(rawptr(file[i])) + uintptr(l))), transmute(cstring)(&buf[0])) == 0 {
				([^]u8)(rawptr(file[i]))[uintptr(l)] = 0
			}
		}
	}
}

// Set help-buffer options after jumping to a tag.
@(export)
prepare_help_buffer :: proc "c" () {
	context = runtime.default_context()
	(^bool)(uintptr(curbuf) + B_HELP_OFF)^ = true
	set_option_direct(kOptBuftype_E, str_optval(transmute(^u8)(cstring("help")), 4), OPT_LOCAL_S, 0)
	p := cstring("!-~,^*,^|,^\",192-255")
	if libc.strcmp(transmute(cstring)((^rawptr)(uintptr(curbuf) + B_P_ISK_OFF)^), p) != 0 {
		set_option_direct(kOptIskeyword_E, str_optval(transmute(^u8)(p), libc.strlen(p)), OPT_LOCAL_S, 0)
		check_buf_options(curbuf)
		buf_init_chartab(curbuf, false)
	}
	set_option_direct(kOptFoldmethod_E, str_optval(transmute(^u8)(cstring("manual")), 6), OPT_LOCAL_S, 0)
	(^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^ = 8
	(^C.int)(uintptr(curwin) + W_P_LIST_OFF)^ = 0
	(^C.int)(uintptr(curbuf) + B_P_MA_OFF)^ = 0
	(^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_P_NU_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_P_RNU_OFF)^ = 0
	(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false
	(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
	(^C.int)(uintptr(curwin) + W_P_ARAB_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_P_RL_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_P_FEN)^ = 0
	(^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = 0
	set_buflisted(0)
}

// Populate *local-additions* via Lua.
@(export)
get_local_additions :: proc "c" () {
	context = runtime.default_context()
	no_args := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	nlua_call_typval_e(cstring("vim._core.help"), cstring("local_additions"), &no_args, nil)
}

// ":exusage".
@(export)
ex_exusage :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	do_cmdline_cmd(cstring("help ex-cmd-index"))
}

// ":viusage".
@(export)
ex_viusage :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	do_cmdline_cmd(cstring("help normal-index"))
}

// Generate tags for one help directory.
helptags_one_o :: proc "c" (dir: ^u8, ext: cstring, tagfname: cstring, add_help_tags: bool, ignore_writeerr: bool) {
	context = runtime.default_context()
	ga := Garray{}
	filecount: C.int = 0
	files: rawptr = nil
	s: ^u8 = nil
	dirlen := xstrlcpy(transmute(cstring)(&name_buff[0]), transmute(cstring)(dir), MAXPATHL_O)
	if dirlen >= MAXPATHL_O || xstrlcat(&name_buff[0], transmute(^u8)(cstring("/**/*")), MAXPATHL_O) >= MAXPATHL_O || xstrlcat(&name_buff[0], transmute(^u8)(ext), MAXPATHL_O) >= MAXPATHL_O {
		emsg(cstring(E_FNAMETOOLONG_S))
		return
	}
	buff_list: [1]^u8 = {&name_buff[0]}
	res := gen_expand_wildcards_e(1, rawptr(&buff_list[0]), &filecount, &files, EW_FILE | EW_SILENT)
	if res == FAIL_E || filecount == 0 {
		if !got_int {
			semsg(cstring(E151_S), transmute(cstring)(&name_buff[0]))
		}
		if res != FAIL_E {
			freewild_e(filecount, files)
		}
		return
	}
	libc.memcpy(rawptr(&name_buff[0]), rawptr(dir), dirlen + 1)
	if !add_pathsep(&name_buff[0]) || xstrlcat(&name_buff[0], transmute(^u8)(tagfname), MAXPATHL_O) >= MAXPATHL_O {
		emsg(cstring(E_FNAMETOOLONG_S))
		return
	}
	fd_tags := os_fopen(transmute(cstring)(&name_buff[0]), cstring("w"))
	if fd_tags == nil {
		if !ignore_writeerr {
			semsg(cstring(E152_S), transmute(cstring)(&name_buff[0]))
		}
		freewild_e(filecount, files)
		return
	}
	ga_init(&ga, size_of(rawptr), 100)
	if add_help_tags || path_full_compare_r(cstring("$VIMRUNTIME/doc"), transmute(cstring)(dir), false, true) == kEqualFiles_S {
		s_len := C.size_t(18) + libc.strlen(tagfname)
		s = (^u8)(xmalloc(s_len))
		libc.snprintf(s, s_len, cstring("help-tags\t%s\t1\n"), tagfname)
		ga_grow(&ga, 1)
		([^]rawptr)(ga.ga_data)[uintptr(ga.ga_len)] = rawptr(s)
		ga.ga_len += 1
	}
	for fi: C.int = 0; fi < filecount && !got_int; fi += 1 {
		fname := ([^]rawptr)(files)[uintptr(fi)]
		fd := os_fopen(transmute(cstring)(fname), cstring("r"))
		if fd == nil {
			semsg(cstring(E153_S), transmute(cstring)(fname))
			continue
		}
		short := (^u8)(uintptr(fname) + uintptr(dirlen) + 1)
		in_example := false
		for vim_fgets(&IObuff[0], IOSIZE_O, fd) == 0 && !got_int {
			if in_example {
				if vim_strchr(transmute(cstring)(&SPC_TAB_NL_CR_O[0]), C.int(([^]u8)(&IObuff[0])[0])) != nil {
					continue
				}
				in_example = false
			}
			p1 := transmute(^u8)(vim_strchr(transmute(cstring)(&IObuff[0]), '*'))
			for p1 != nil {
				p2 := transmute(^u8)(vim_strchr(transmute(cstring)((^u8)(uintptr(p1) + 1)), '*'))
				if p2 != nil && uintptr(p2) > uintptr(p1) + 1 {
					s = (^u8)(uintptr(p1) + 1)
					for uintptr(s) < uintptr(p2) {
						b := ([^]u8)(s)[0]
						if b == ' ' || b == '\t' || b == '|' {
							break
						}
						s = (^u8)(uintptr(s) + 1)
					}
					if s == p2 && (p1 == &IObuff[0] || ([^]u8)((^u8)(uintptr(p1) - 1))[0] == ' ' || ([^]u8)((^u8)(uintptr(p1) - 1))[0] == '\t') && (vim_strchr(transmute(cstring)(&SPC_TAB_NL_CR_O[0]), C.int(([^]u8)((^u8)(uintptr(s) + 1))[0])) != nil || ([^]u8)((^u8)(uintptr(s) + 1))[0] == 0) {
						([^]u8)(p2)[0] = 0
						p1 = (^u8)(uintptr(p1) + 1)
						s_len := C.size_t(uintptr(p2) - uintptr(p1)) + libc.strlen(transmute(cstring)(short)) + 2
						s = (^u8)(xmalloc(s_len))
						ga_grow(&ga, 1)
						([^]rawptr)(ga.ga_data)[uintptr(ga.ga_len)] = rawptr(s)
						ga.ga_len += 1
						libc.snprintf(s, s_len, cstring("%s\t%s"), transmute(cstring)(p1), transmute(cstring)(short))
						p2 = transmute(^u8)(vim_strchr(transmute(cstring)((^u8)(uintptr(p2) + 1)), '*'))
					}
				}
				p1 = p2
			}
			off := libc.strlen(transmute(cstring)(&IObuff[0]))
			if off >= 2 && ([^]u8)(&IObuff[0])[off - 1] == '\n' {
				off -= 2
				for off > 0 && ((([^]u8)(&IObuff[0])[off] >= 'a' && ([^]u8)(&IObuff[0])[off] <= 'z') || ascii_isdigit(([^]u8)(&IObuff[0])[off])) {
					off -= 1
				}
				if ([^]u8)(&IObuff[0])[off] == '>' && (off == 0 || ([^]u8)(&IObuff[0])[off - 1] == ' ') {
					in_example = true
				}
			}
			line_breakcheck()
		}
		libc.fclose((^libc.FILE)(fd))
	}
	freewild_e(filecount, files)
	if !got_int && ga.ga_data != nil {
		sort_strings(transmute(^rawptr)(ga.ga_data), ga.ga_len)
		for i: C.int = 1; i < ga.ga_len; i += 1 {
			p1 := transmute(^u8)(([^]rawptr)(ga.ga_data)[uintptr(i) - 1])
			p2 := transmute(^u8)(([^]rawptr)(ga.ga_data)[uintptr(i)])
			for ([^]u8)(p1)[0] == ([^]u8)(p2)[0] {
				if ([^]u8)(p2)[0] == '\t' {
					([^]u8)(p2)[0] = 0
					libc.snprintf(&name_buff[0], MAXPATHL_O, _t(cstring(E154_S)), transmute(cstring)(([^]rawptr)(ga.ga_data)[uintptr(i)]), transmute(cstring)(dir), transmute(cstring)((^u8)(uintptr(p2) + 1)))
					emsg(transmute(cstring)(&name_buff[0]))
					([^]u8)(p2)[0] = '\t'
					break
				}
				p1 = (^u8)(uintptr(p1) + 1)
				p2 = (^u8)(uintptr(p2) + 1)
			}
		}
		for i: C.int = 0; i < ga.ga_len; i += 1 {
			s = transmute(^u8)(([^]rawptr)(ga.ga_data)[uintptr(i)])
			if libc.strncmp(transmute(cstring)(s), cstring("help-tags\t"), 10) == 0 {
				libc.fprintf((^libc.FILE)(fd_tags), cstring("%s"), transmute(cstring)(s))
			} else {
				libc.fprintf((^libc.FILE)(fd_tags), cstring("%s\t/*"), transmute(cstring)(s))
				for p1 := s; ([^]u8)(p1)[0] != '\t'; p1 = (^u8)(uintptr(p1) + 1) {
					if ([^]u8)(p1)[0] == '\\' || ([^]u8)(p1)[0] == '/' {
						libc.putc('\\', (^libc.FILE)(fd_tags))
					}
					libc.putc(C.int(([^]u8)(p1)[0]), (^libc.FILE)(fd_tags))
				}
				libc.fprintf((^libc.FILE)(fd_tags), cstring("*\n"))
			}
		}
	}
	for i: C.int = 0; i < ga.ga_len; i += 1 {
		xfree(([^]rawptr)(ga.ga_data)[uintptr(i)])
	}
	ga_clear(&ga)
	libc.fclose((^libc.FILE)(fd_tags))
}

// Generate tags for one help directory with translations.
do_helptags_o :: proc "c" (dirname: ^u8, add_help_tags: bool, ignore_writeerr: bool) {
	context = runtime.default_context()
	ga := Garray{}
	lang: [2]u8
	ext: [5]u8
	fname: [8]u8
	filecount: C.int = 0
	files: rawptr = nil
	xstrlcpy(transmute(cstring)(&name_buff[0]), transmute(cstring)(dirname), MAXPATHL_O)
	if !add_pathsep(&name_buff[0]) || xstrlcat(&name_buff[0], transmute(^u8)(cstring("**")), MAXPATHL_O) >= MAXPATHL_O {
		emsg(cstring(E_FNAMETOOLONG_S))
		return
	}
	buff_list: [1]^u8 = {&name_buff[0]}
	if gen_expand_wildcards_e(1, rawptr(&buff_list[0]), &filecount, &files, EW_FILE | EW_SILENT) == FAIL_E || filecount == 0 {
		if !got_int {
			semsg(cstring(E151_S), transmute(cstring)(&name_buff[0]))
		}
		return
	}
	j: C.int = 0
	ga_init(&ga, 1, 10)
	for i: C.int = 0; i < filecount; i += 1 {
		f := transmute(^u8)(([^]rawptr)(files)[uintptr(i)])
		l := C.int(libc.strlen(transmute(cstring)(f)))
		if l <= 4 {
			continue
		}
		if libc.strncmp(transmute(cstring)((^u8)(uintptr(f) + uintptr(l) - 4)), cstring(".txt"), 4) == 0 {
			lang[0] = 'e'
			lang[1] = 'n'
		} else if ([^]u8)(f)[uintptr(l) - 4] == '.' && ascii_isalpha_o(([^]u8)(f)[uintptr(l) - 3]) && ascii_isalpha_o(([^]u8)(f)[uintptr(l) - 2]) && tolower_asc_o(([^]u8)(f)[uintptr(l) - 1]) == 'x' {
			lang[0] = u8(tolower_asc_o(([^]u8)(f)[uintptr(l) - 3]))
			lang[1] = u8(tolower_asc_o(([^]u8)(f)[uintptr(l) - 2]))
		} else {
			continue
		}
		j = 0
		for j < ga.ga_len {
			if libc.strncmp(transmute(cstring)(&lang[0]), transmute(cstring)((^u8)(uintptr(ga.ga_data) + uintptr(j))), 2) == 0 {
				break
			}
			j += 2
		}
		if j == ga.ga_len {
			ga_grow(&ga, 2)
			([^]u8)(ga.ga_data)[uintptr(ga.ga_len)] = lang[0]
			ga.ga_len += 1
			([^]u8)(ga.ga_data)[uintptr(ga.ga_len)] = lang[1]
			ga.ga_len += 1
		}
	}
	for j = 0; j < ga.ga_len; j += 2 {
		libc.strcpy(&fname[0], cstring("tags-xx"))
		fname[5] = ([^]u8)(ga.ga_data)[uintptr(j)]
		fname[6] = ([^]u8)(ga.ga_data)[uintptr(j) + 1]
		if fname[5] == 'e' && fname[6] == 'n' {
			fname[4] = 0
			libc.strcpy(&ext[0], cstring(".txt"))
		} else {
			libc.strcpy(&ext[0], cstring(".xxx"))
			ext[1] = fname[5]
			ext[2] = fname[6]
		}
		helptags_one_o(dirname, transmute(cstring)(&ext[0]), transmute(cstring)(&fname[0]), add_help_tags, ignore_writeerr)
	}
	ga_clear(&ga)
	freewild_e(filecount, files)
}

helptags_cb_o :: proc "c" (num_fnames: C.int, fnames: [^]cstring, all: bool, cookie: rawptr) -> bool {
	context = runtime.default_context()
	for i: C.int = 0; i < num_fnames; i += 1 {
		do_helptags_o(transmute(^u8)(fnames[i]), (^bool)(cookie)^, true)
		if !all {
			return true
		}
	}
	return num_fnames > 0
}

// ":helptags".
@(export)
ex_helptags :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	xpc := expand_T{}
	add_help_tags := false
	arg := transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
	if libc.strncmp(transmute(cstring)(arg), cstring("++t"), 3) == 0 && ascii_iswhite(([^]u8)(arg)[3]) {
		add_help_tags = true
		(^cstring)(uintptr(eap) + EXARG_ARG_OFF)^ = skipwhite(transmute(cstring)((^u8)(uintptr(arg) + 3)))
		arg = transmute(^u8)((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
	}
	if libc.strcmp(transmute(cstring)(arg), cstring("ALL")) == 0 {
		do_in_path_e(transmute(cstring)(p_rtp_g), cstring(""), cstring("doc"), DIP_ALL_O + DIP_DIR_O, transmute(rawptr)(helptags_cb_o), rawptr(&add_help_tags))
	} else {
		_ExpandInit(rawptr(&xpc))
		xpc.xp_context = EXPAND_DIRECTORIES_S
		dirname := _ExpandOne(rawptr(&xpc), transmute(cstring)(arg), nil, WILD_LIST_NOTFOUND_O | WILD_SILENT, WILD_EXPAND_FREE)
		if dirname == nil || !os_isdir(dirname) {
			semsg(cstring(E150_S), transmute(cstring)(arg))
		} else {
			do_helptags_o(transmute(^u8)(dirname), add_help_tags, false)
		}
		xfree(rawptr(dirname))
	}
}
