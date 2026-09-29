package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// testing.c port: assert_*()/test_*() Vimscript functions for the test suite.
// All 15 publics are @(export); helpers are _o plains (C-statics).

foreign _ {
	@(link_name = "called_vim_beep")
	called_vim_beep_g: bool
	@(link_name = "emsg_on_display")
	emsg_on_display_g: bool
	@(link_name = "emsg_assert_fails_msg")
	emsg_assert_fails_msg_g: cstring
	@(link_name = "emsg_assert_fails_lnum")
	emsg_assert_fails_lnum_g: C.long
	@(link_name = "emsg_assert_fails_context")
	emsg_assert_fails_context_g: cstring
}

VV_ERRMSG_O :: 3 // eval_defs.h (cc-probed)
ESTACK_NONE_O :: 0

BS_O :: 8
FF_O :: 12

ASSERT_EQUAL_O :: 0
ASSERT_NOTEQUAL_O :: 1
ASSERT_MATCH_O :: 2
ASSERT_NOTMATCH_O :: 3
ASSERT_FAILS_O :: 4
ASSERT_OTHER_O :: 5

E856_S :: "E856: \"assert_fails()\" second argument must be a string or a list with one or two strings"
E1115_S :: "E1115: \"assert_fails()\" fourth argument must be a number"
E1116_S :: "E1116: \"assert_fails()\" fifth argument must be a string"
E1142_S :: "E1142: Calling test_garbagecollect_now() while v:testing is not set"

// Prepare gap for an assert error, adding the sourcing position.
prepare_assert_error_o :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	sname := estack_sfile_e(ESTACK_NONE_O)
	ga_init(gap, 1, 100)
	if sname != nil {
		ga_concat(gap, transmute(cstring)(sname))
		if sourcing_lnum_o() > 0 {
			ga_concat(gap, cstring(" "))
		}
	}
	if sourcing_lnum_o() > 0 {
		buf: [NUMBUFLEN]u8
		buflen := C.size_t(vim_snprintf(&buf[0], NUMBUFLEN, cstring("line %ld"), C.longlong(sourcing_lnum_o())))
		ga_concat_len(gap, transmute(cstring)(&buf[0]), buflen)
	}
	if sname != nil || sourcing_lnum_o() > 0 {
		ga_concat(gap, cstring(": "))
	}
	xfree(rawptr(sname))
}

// Append p[clen] to gap, escaping unprintables.
ga_concat_esc_o :: proc "c" (gap: ^Garray, p: cstring, clen: C.int) {
	context = runtime.default_context()
	buf: [NUMBUFLEN]u8
	if clen > 1 {
		libc.memmove(rawptr(&buf[0]), rawptr(p), C.size_t(clen))
		buf[clen] = 0
		ga_concat_len(gap, transmute(cstring)(&buf[0]), C.size_t(clen))
		return
	}
	b := ([^]u8)(rawptr(p))[0]
	switch b {
	case BS_O:
		ga_concat(gap, cstring("\\b"))
	case ESC:
		ga_concat(gap, cstring("\\e"))
	case FF_O:
		ga_concat(gap, cstring("\\f"))
	case NL:
		ga_concat(gap, cstring("\\n"))
	case TAB:
		ga_concat(gap, cstring("\\t"))
	case CAR:
		ga_concat(gap, cstring("\\r"))
	case '\\':
		ga_concat(gap, cstring("\\\\"))
	case:
		if b < ' ' || b == 0x7f {
			buflen := C.size_t(vim_snprintf(&buf[0], NUMBUFLEN, cstring("\\x%02x"), C.int(b)))
			ga_concat_len(gap, transmute(cstring)(&buf[0]), buflen)
		} else {
			ga_append(gap, b)
		}
	}
}

// Append str to gap, escaping unprintables (long runs shortened).
ga_concat_shorten_esc_o :: proc "c" (gap: ^Garray, str: cstring) {
	context = runtime.default_context()
	buf: [NUMBUFLEN]u8
	if str == nil {
		ga_concat(gap, cstring("NULL"))
		return
	}
	p := transmute(^u8)(str)
	for ([^]u8)(p)[0] != 0 {
		same_len: C.int = 1
		s := p
		c := mb_cptr2char_adv(&s)
		clen := C.int(uintptr(s) - uintptr(p))
		for ([^]u8)(s)[0] != 0 && c == utf_ptr2char(transmute(cstring)(s)) {
			same_len += 1
			s = (^u8)(uintptr(s) + uintptr(clen))
		}
		if same_len > 20 {
			ga_concat(gap, cstring("\\["))
			ga_concat_esc_o(gap, transmute(cstring)(p), clen)
			ga_concat(gap, cstring(" occurs "))
			buflen := C.size_t(vim_snprintf(&buf[0], NUMBUFLEN, cstring("%d"), same_len))
			ga_concat_len(gap, transmute(cstring)(&buf[0]), buflen)
			ga_concat(gap, cstring(" times]"))
			p = s
		} else {
			ga_concat_esc_o(gap, transmute(cstring)(p), clen)
			p = (^u8)(uintptr(p) + uintptr(clen))
		}
	}
}

// Fill gap with information about an assert error.
fill_assert_error_o :: proc "c" (gap: ^Garray, opt_msg_tv: ^Typval_T, exp_str: cstring, exp_tv_arg: ^Typval_T, got_tv_arg: ^Typval_T, atype: C.int) {
	context = runtime.default_context()
	exp_tv := exp_tv_arg
	got_tv := got_tv_arg
	did_copy := false
	omitted: C.int = 0
	if opt_msg_tv.v_type != VAR_UNKNOWN && !(opt_msg_tv.v_type == VAR_STRING && (rawptr(opt_msg_tv.vval) == nil || ([^]u8)(rawptr(opt_msg_tv.vval))[0] == 0)) {
		tofree := encode_tv2echo(opt_msg_tv, nil)
		ga_concat(gap, transmute(cstring)(tofree))
		xfree(rawptr(tofree))
		ga_concat(gap, cstring(": "))
	}
	if atype == ASSERT_MATCH_O || atype == ASSERT_NOTMATCH_O {
		ga_concat(gap, cstring("Pattern "))
	} else if atype == ASSERT_NOTEQUAL_O {
		ga_concat(gap, cstring("Expected not equal to "))
	} else {
		ga_concat(gap, cstring("Expected "))
	}
	if exp_str == nil {
		if atype != ASSERT_NOTEQUAL_O && exp_tv.v_type == VAR_DICT && got_tv.v_type == VAR_DICT && rawptr(exp_tv.vval) != nil && rawptr(got_tv.vval) != nil {
			exp_d := rawptr(exp_tv.vval)
			got_d := rawptr(got_tv.vval)
			did_copy = true
			exp_tv.vval = transmute(rawptr)(tv_dict_alloc())
			got_tv.vval = transmute(rawptr)(tv_dict_alloc())
			todo := (^C.size_t)(uintptr(exp_d) + 24)^
			hi := (^rawptr)(uintptr(exp_d) + 48)^
			for ; todo > 0; hi = rawptr(uintptr(hi) + 16) {
				key := (^rawptr)(uintptr(hi) + 8)^
				if key == nil || key == rawptr(&hash_removed) {
					continue
				}
				todo -= 1
				item2 := tv_dict_find(got_d, transmute(cstring)(key), -1)
				if item2 == nil || !tv_equal((^Typval_T)(uintptr(key) - 17), (^Typval_T)(uintptr(item2)), false) {
					key_len := libc.strlen(transmute(cstring)(key))
					tv_dict_add_tv(rawptr(exp_tv.vval), transmute(cstring)(key), key_len, (^Typval_T)(uintptr(key) - 17))
					if item2 != nil {
						tv_dict_add_tv(rawptr(got_tv.vval), transmute(cstring)(key), key_len, (^Typval_T)(uintptr(item2)))
					}
				} else {
					omitted += 1
				}
			}
			todo = (^C.size_t)(uintptr(got_d) + 24)^
			hi = (^rawptr)(uintptr(got_d) + 48)^
			for ; todo > 0; hi = rawptr(uintptr(hi) + 16) {
				key := (^rawptr)(uintptr(hi) + 8)^
				if key == nil || key == rawptr(&hash_removed) {
					continue
				}
				todo -= 1
				item2 := tv_dict_find(exp_d, transmute(cstring)(key), -1)
				if item2 == nil {
					key_len := libc.strlen(transmute(cstring)(key))
					tv_dict_add_tv(rawptr(got_tv.vval), transmute(cstring)(key), key_len, (^Typval_T)(uintptr(key) - 17))
				}
			}
		}
		tofree := encode_tv2string(exp_tv, nil)
		ga_concat_shorten_esc_o(gap, tofree)
		xfree(rawptr(tofree))
	} else {
		if atype == ASSERT_FAILS_O {
			ga_concat(gap, cstring("'"))
		}
		ga_concat_shorten_esc_o(gap, exp_str)
		if atype == ASSERT_FAILS_O {
			ga_concat(gap, cstring("'"))
		}
	}
	if atype != ASSERT_NOTEQUAL_O {
		if atype == ASSERT_MATCH_O {
			ga_concat(gap, cstring(" does not match "))
		} else if atype == ASSERT_NOTMATCH_O {
			ga_concat(gap, cstring(" does match "))
		} else {
			ga_concat(gap, cstring(" but got "))
		}
		tofree := encode_tv2string(got_tv, nil)
		ga_concat_shorten_esc_o(gap, tofree)
		xfree(rawptr(tofree))
		if omitted != 0 {
			buf: [100]u8
			es := cstring("s")
			if omitted == 1 {
				es = cstring("")
			}
			buflen := C.size_t(vim_snprintf(&buf[0], 100, cstring(" - %d equal item%s omitted"), omitted, es))
			ga_concat_len(gap, transmute(cstring)(&buf[0]), buflen)
		}
	}
	if did_copy {
		tv_clear(exp_tv)
		tv_clear(got_tv)
	}
}

assert_equal_common_o :: proc "c" (argvars: ^Typval_T, atype: C.int) -> C.int {
	context = runtime.default_context()
	ga := Garray{}
	if tv_equal(argvars, (^Typval_T)(uintptr(argvars) + 16), false) != (atype == ASSERT_EQUAL_O) {
		prepare_assert_error_o(&ga)
		fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 32), nil, argvars, (^Typval_T)(uintptr(argvars) + 16), atype)
		assert_error(&ga)
		ga_clear(&ga)
		return 1
	}
	return 0
}

assert_match_common_o :: proc "c" (argvars: ^Typval_T, atype: C.int) -> C.int {
	context = runtime.default_context()
	buf1: [NUMBUFLEN]u8
	buf2: [NUMBUFLEN]u8
	pat := tv_get_string_buf_chk(argvars, &buf1[0])
	text := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &buf2[0])
	if pat != nil && text != nil {
		matched := pattern_match(pat, text, false) != 0
		want := atype == ASSERT_MATCH_O
		if matched != want {
			ga := Garray{}
			prepare_assert_error_o(&ga)
			fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 32), nil, argvars, (^Typval_T)(uintptr(argvars) + 16), atype)
			assert_error(&ga)
			ga_clear(&ga)
			return 1
		}
	}
	return 0
}

// Common for assert_true() and assert_false().
assert_bool_o :: proc "c" (argvars: ^Typval_T, is_true: bool) -> C.int {
	context = runtime.default_context()
	error := false
	ga := Garray{}
	a0 := argvars^
	num_ok := true
	if a0.v_type != VAR_NUMBER || (tv_get_number_chk(argvars, &error) == 0) == is_true || error {
		num_ok = false
	}
	bool_ok := true
	if a0.v_type != VAR_BOOL {
		bool_ok = false
	} else {
		want: C.int = kBoolVarFalse
		if is_true {
			want = kBoolVarTrue
		}
		if (^C.int)(uintptr(argvars) + 8)^ != want {
			bool_ok = false
		}
	}
	if !num_ok && !bool_ok {
		prepare_assert_error_o(&ga)
		exp := cstring("False")
		if is_true {
			exp = cstring("True")
		}
		fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 16), exp, nil, argvars, ASSERT_OTHER_O)
		assert_error(&ga)
		ga_clear(&ga)
		return 1
	}
	return 0
}

assert_append_cmd_or_arg_o :: proc "c" (gap: ^Garray, argvars: ^Typval_T, cmd: cstring) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		tofree := encode_tv2echo((^Typval_T)(uintptr(argvars) + 32), nil)
		ga_concat(gap, transmute(cstring)(tofree))
		xfree(rawptr(tofree))
	} else {
		ga_concat(gap, cmd)
	}
}

assert_beeps_o :: proc "c" (argvars: ^Typval_T, no_beep: bool) -> C.int {
	context = runtime.default_context()
	cmd := tv_get_string_chk(argvars)
	ret: C.int = 0
	called_vim_beep_g = false
	suppress_errthrow_g = true
	emsg_silent = 0
	do_cmdline_cmd(cmd)
	beeped := called_vim_beep_g
	if !no_beep {
		beeped = !beeped
	}
	if beeped {
		ga := Garray{}
		prepare_assert_error_o(&ga)
		if no_beep {
			ga_concat(&ga, cstring("command did beep: "))
		} else {
			ga_concat(&ga, cstring("command did not beep: "))
		}
		ga_concat(&ga, cmd)
		assert_error(&ga)
		ga_clear(&ga)
		ret = 1
	}
	suppress_errthrow_g = false
	emsg_on_display_g = false
	return ret
}

// "assert_beeps(cmd [, error])" function.
@(export)
f_assert_beeps :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_beeps_o(argvars, false)))
}

// "assert_nobeep(cmd [, error])" function.
@(export)
f_assert_nobeep :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_beeps_o(argvars, true)))
}

// "assert_equal(expected, actual[, msg])" function.
@(export)
f_assert_equal :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_equal_common_o(argvars, ASSERT_EQUAL_O)))
}

assert_equalfile_o :: proc "c" (argvars: ^Typval_T) -> C.int {
	context = runtime.default_context()
	buf1: [NUMBUFLEN]u8
	buf2: [NUMBUFLEN]u8
	fname1 := tv_get_string_buf_chk(argvars, &buf1[0])
	fname2 := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &buf2[0])
	if fname1 == nil || fname2 == nil {
		return 0
	}
	([^]u8)(&IObuff[0])[0] = 0
	IObufflen: C.size_t = 0
	fd1 := os_fopen(fname1, READBIN)
	line1: [200]u8
	line2: [200]u8
	lineidx: C.longlong = 0
	if fd1 == nil {
		IObufflen = C.size_t(vim_snprintf(&IObuff[0], IOSIZE_O, cstring(E_CANT_READ_S), fname1))
	} else {
		fd2 := os_fopen(fname2, READBIN)
		if fd2 == nil {
			libc.fclose((^libc.FILE)(fd1))
			IObufflen = C.size_t(vim_snprintf(&IObuff[0], IOSIZE_O, cstring(E_CANT_READ_S), fname2))
		} else {
			linecount: C.longlong = 1
			done := false
			for count: C.longlong = 0; !done; count += 1 {
				c1 := libc.fgetc((^libc.FILE)(fd1))
				c2 := libc.fgetc((^libc.FILE)(fd2))
				if c1 == -1 {
					if c2 != -1 {
						IObufflen = xstrlcpy(transmute(cstring)(&IObuff[0]), cstring("first file is shorter"), IOSIZE_O)
					}
					done = true
				} else if c2 == -1 {
					IObufflen = xstrlcpy(transmute(cstring)(&IObuff[0]), cstring("second file is shorter"), IOSIZE_O)
					done = true
				} else {
					line1[lineidx] = u8(c1)
					line2[lineidx] = u8(c2)
					lineidx += 1
					if c1 != c2 {
						IObufflen = C.size_t(vim_snprintf(&IObuff[0], IOSIZE_O, cstring("difference at byte %ld, line %ld"), count, linecount))
						done = true
					}
				}
				if !done {
					if c1 == 10 {
						linecount += 1
						lineidx = 0
					} else if lineidx + 2 == 200 {
						libc.memmove(rawptr(&line1[0]), rawptr(&line1[100]), C.size_t(lineidx - 100))
						libc.memmove(rawptr(&line2[0]), rawptr(&line2[100]), C.size_t(lineidx - 100))
						lineidx -= 100
					}
				}
			}
			libc.fclose((^libc.FILE)(fd1))
			libc.fclose((^libc.FILE)(fd2))
		}
	}
	if IObufflen > 0 {
		ga := Garray{}
		prepare_assert_error_o(&ga)
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			tofree := encode_tv2echo((^Typval_T)(uintptr(argvars) + 32), nil)
			ga_concat(&ga, transmute(cstring)(tofree))
			xfree(rawptr(tofree))
			ga_concat(&ga, cstring(": "))
		}
		ga_concat_len(&ga, transmute(cstring)(&IObuff[0]), IObufflen)
		if lineidx > 0 {
			line1[lineidx] = 0
			line2[lineidx] = 0
			ga_concat(&ga, cstring(" after \""))
			ga_concat_len(&ga, transmute(cstring)(&line1[0]), C.size_t(lineidx))
			if libc.strcmp(transmute(cstring)(&line1[0]), transmute(cstring)(&line2[0])) != 0 {
				ga_concat(&ga, cstring("\" vs \""))
				ga_concat_len(&ga, transmute(cstring)(&line2[0]), C.size_t(lineidx))
			}
			ga_concat(&ga, cstring("\""))
		}
		assert_error(&ga)
		ga_clear(&ga)
		return 1
	}
	return 0
}

// "assert_equalfile(fname-one, fname-two[, msg])" function.
@(export)
f_assert_equalfile :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_equalfile_o(argvars)))
}

// "assert_notequal(expected, actual[, msg])" function.
@(export)
f_assert_notequal :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_equal_common_o(argvars, ASSERT_NOTEQUAL_O)))
}

// "assert_exception(string[, msg])" function.
@(export)
f_assert_exception :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	error := tv_get_string_chk(argvars)
	exc := get_vim_var_str(VV_EXCEPTION_O)
	if ([^]u8)(rawptr(exc))[0] == 0 {
		ga := Garray{}
		prepare_assert_error_o(&ga)
		ga_concat(&ga, cstring("v:exception is not set"))
		assert_error(&ga)
		ga_clear(&ga)
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else if error != nil && strstr_c(get_vim_var_str(VV_EXCEPTION_O), error) == nil {
		ga := Garray{}
		prepare_assert_error_o(&ga)
		fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 16), nil, argvars, get_vim_var_tv(VV_EXCEPTION_O), ASSERT_OTHER_O)
		assert_error(&ga)
		ga_clear(&ga)
		rettv.vval = transmute(rawptr)(C.longlong(1))
	}
}

// "assert_fails(cmd [, error [, msg]])" function.
@(export)
f_assert_fails :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	save_trylevel := trylevel_g
	called_emsg_before := called_emsg
	wrong_arg_msg: cstring = nil
	tofree: ^u8 = nil
	if tv_check_for_string_or_number_arg(argvars, 0) == FAIL_E || tv_check_for_opt_string_or_list_arg(argvars, 1) == FAIL_E || (([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && (([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && (tv_check_for_opt_number_arg(argvars, 3) == FAIL_E || (([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN && tv_check_for_opt_string_arg(argvars, 4) == FAIL_E)))) {
		return
	}
	for _ in 0..<1 {
		trylevel_g = 0
		suppress_errthrow_g = true
		in_assert_fails_g = true
		no_wait_return += 1
		cmd := tv_get_string_chk(argvars)
		do_cmdline_cmd(cmd)
		trylevel_g = save_trylevel
		suppress_errthrow_g = false
		if called_emsg == called_emsg_before {
			ga := Garray{}
			prepare_assert_error_o(&ga)
			ga_concat(&ga, cstring("command did not fail: "))
			assert_append_cmd_or_arg_o(&ga, argvars, cmd)
			assert_error(&ga)
			ga_clear(&ga)
			rettv.vval = transmute(rawptr)(C.longlong(1))
		} else if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
			buf: [NUMBUFLEN]u8
			expected: cstring = nil
			expected_str: cstring = nil
			error_found := false
			error_found_index: C.int = 1
			actual: cstring = cstring("[unknown]")
			if emsg_assert_fails_msg_g != nil {
				actual = emsg_assert_fails_msg_g
			}
			if ([^]Typval_T)(argvars)[1].v_type == VAR_STRING {
				expected = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &buf[0])
				error_found = expected == nil || strstr_c(actual, expected) == nil
			} else if ([^]Typval_T)(argvars)[1].v_type == VAR_LIST {
				list := rawptr(([^]Typval_T)(argvars)[1].vval)
				if list == nil || tv_list_len_o(list) < 1 || tv_list_len_o(list) > 2 {
					wrong_arg_msg = cstring(E856_S)
					break
				}
				tv := (^Typval_T)(uintptr(tv_list_first_o(list)) + 16)
				expected = tv_get_string_buf_chk(tv, &buf[0])
				if expected == nil {
					break
				}
				if pattern_match(expected, actual, false) == 0 {
					error_found = true
					expected_str = expected
				} else if tv_list_len_o(list) == 2 {
					tofree = xstrdup(transmute(^u8)(get_vim_var_str(VV_ERRMSG_O)))
					actual = transmute(cstring)(tofree)
					tv = (^Typval_T)(uintptr(tv_list_last_o(list)) + 16)
					expected = tv_get_string_buf_chk(tv, &buf[0])
					if expected == nil {
						break
					}
					if pattern_match(expected, actual, false) == 0 {
						error_found = true
						expected_str = expected
					}
				}
			} else {
				wrong_arg_msg = cstring(E856_S)
				break
			}
			if !error_found && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
				if ([^]Typval_T)(argvars)[3].v_type != VAR_NUMBER {
					wrong_arg_msg = cstring(E1115_S)
					break
				} else if transmute(C.longlong)(([^]Typval_T)(argvars)[3].vval) >= 0 && transmute(C.longlong)(([^]Typval_T)(argvars)[3].vval) != C.longlong(emsg_assert_fails_lnum_g) {
					error_found = true
					error_found_index = 3
				}
				if !error_found && ([^]Typval_T)(argvars)[4].v_type != VAR_UNKNOWN {
					if ([^]Typval_T)(argvars)[4].v_type != VAR_STRING {
						wrong_arg_msg = cstring(E1116_S)
						break
					} else if rawptr(([^]Typval_T)(argvars)[4].vval) != nil && pattern_match(transmute(cstring)(([^]Typval_T)(argvars)[4].vval), emsg_assert_fails_context_g, false) == 0 {
						error_found = true
						error_found_index = 4
					}
				}
			}
			if error_found {
				actual_tv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED}
				if error_found_index == 3 {
					actual_tv.vval = transmute(rawptr)(C.longlong(emsg_assert_fails_lnum_g))
				} else if error_found_index == 4 {
					actual_tv.v_type = VAR_STRING
					actual_tv.vval = transmute(rawptr)(emsg_assert_fails_context_g)
				} else {
					actual_tv.v_type = VAR_STRING
					actual_tv.vval = transmute(rawptr)(actual)
				}
				ga := Garray{}
				prepare_assert_error_o(&ga)
				fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 32), expected_str, (^Typval_T)(uintptr(argvars) + 16 * uintptr(error_found_index)), &actual_tv, ASSERT_FAILS_O)
				ga_concat(&ga, cstring(": "))
				assert_append_cmd_or_arg_o(&ga, argvars, cmd)
				assert_error(&ga)
				ga_clear(&ga)
				rettv.vval = transmute(rawptr)(C.longlong(1))
			}
		}
		break
	}
	trylevel_g = save_trylevel
	suppress_errthrow_g = false
	in_assert_fails_g = false
	did_emsg_set(false)
	got_int = false
	msg_col = 0
	no_wait_return -= 1
	need_wait_return_g = false
	emsg_on_display_g = false
	msg_reset_scroll_r()
	lines_left = Rows
	xfree(rawptr(emsg_assert_fails_msg_g))
	emsg_assert_fails_msg_g = nil
	xfree(rawptr(tofree))
	set_vim_var_string(VV_ERRMSG_O, nil, 0)
	if wrong_arg_msg != nil {
		emsg(wrong_arg_msg)
	}
}

// "assert_false(actual[, msg])" function.
@(export)
f_assert_false :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_bool_o(argvars, false)))
}

assert_inrange_o :: proc "c" (argvars: ^Typval_T) -> C.int {
	context = runtime.default_context()
	error := false
	if ([^]Typval_T)(argvars)[0].v_type == VAR_FLOAT || ([^]Typval_T)(argvars)[1].v_type == VAR_FLOAT || ([^]Typval_T)(argvars)[2].v_type == VAR_FLOAT {
		flower := tv_get_float(argvars)
		fupper := tv_get_float((^Typval_T)(uintptr(argvars) + 16))
		factual := tv_get_float((^Typval_T)(uintptr(argvars) + 32))
		if factual < flower || factual > fupper {
			ga := Garray{}
			prepare_assert_error_o(&ga)
			expected_str: [200]u8
			vim_snprintf(&expected_str[0], 200, cstring("range %g - %g,"), flower, fupper)
			fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 48), transmute(cstring)(&expected_str[0]), nil, (^Typval_T)(uintptr(argvars) + 32), ASSERT_OTHER_O)
			assert_error(&ga)
			ga_clear(&ga)
			return 1
		}
	} else {
		lower := tv_get_number_chk(argvars, &error)
		upper := tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error)
		actual := tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error)
		if error {
			return 0
		}
		if actual < lower || actual > upper {
			ga := Garray{}
			prepare_assert_error_o(&ga)
			expected_str: [200]u8
			vim_snprintf(&expected_str[0], 200, cstring("range %ld - %ld,"), C.longlong(lower), C.longlong(upper))
			fill_assert_error_o(&ga, (^Typval_T)(uintptr(argvars) + 48), transmute(cstring)(&expected_str[0]), nil, (^Typval_T)(uintptr(argvars) + 32), ASSERT_OTHER_O)
			assert_error(&ga)
			ga_clear(&ga)
			return 1
		}
	}
	return 0
}

// "assert_inrange(lower, upper[, msg])" function.
@(export)
f_assert_inrange :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_float_or_nr_arg(argvars, 0) == FAIL_E || tv_check_for_float_or_nr_arg(argvars, 1) == FAIL_E || tv_check_for_float_or_nr_arg(argvars, 2) == FAIL_E || tv_check_for_opt_string_arg(argvars, 3) == FAIL_E {
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(assert_inrange_o(argvars)))
}

// "assert_match(pattern, actual[, msg])" function.
@(export)
f_assert_match :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_match_common_o(argvars, ASSERT_MATCH_O)))
}

// "assert_notmatch(pattern, actual[, msg])" function.
@(export)
f_assert_notmatch :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_match_common_o(argvars, ASSERT_NOTMATCH_O)))
}

// "assert_report(msg)" function.
@(export)
f_assert_report :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	ga := Garray{}
	prepare_assert_error_o(&ga)
	ga_concat(&ga, tv_get_string(argvars))
	assert_error(&ga)
	ga_clear(&ga)
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// "assert_true(actual[, msg])" function.
@(export)
f_assert_true :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(assert_bool_o(argvars, true)))
}

// "test_garbagecollect_now()" function.
@(export)
f_test_garbagecollect_now :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if get_vim_var_nr(VV_TESTING_O) == 0 {
		emsg(_t(cstring(E1142_S)))
	} else {
		garbage_collect(true)
	}
}

// "test_write_list_log()" function.
@(export)
f_test_write_list_log :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	fname := tv_get_string_chk(argvars)
	if fname == nil {
		return
	}
}
