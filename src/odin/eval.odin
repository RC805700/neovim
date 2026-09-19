// eval.odin — Odin port of src/nvim/eval/ (Vimscript engine).
//
// Batch 1: eval/gc.c — 2 globals (gc_first_dict/gc_first_list).
// Batch 2: eval/executor.c — eexe_mod_op + 6 tv_op_* statics.

package main

import "base:runtime"
import C "core:c"
import "core:c/libc"

// —— VarType extras (digraph.odin owns bare VAR_UNKNOWN..VAR_BOOL) ——
VAR_SPECIAL :: 8
VAR_PARTIAL :: 9
VAR_BLOB    :: 10

// VarLockStatus (typval_defs.h:99).
VAR_UNLOCKED :: 0
VAR_LOCKED :: 1

OK_E :: 1
FAIL_E :: 0

E_LETWRONG_S :: "E734: Wrong variable type for %s="

// —— Batch 1: eval/gc.c ——
// C defines these DLLEXPORT globals; gc.c weak-marks them so these strong
// Odin defs win. dict_T/list_T are opaque here (rawptr, nil-initialized).
@(export)
gc_first_dict: rawptr
@(export)
gc_first_list: rawptr

// —— Batch 2: eval/executor.c ——
foreign _ {
	@(link_name = "tv_get_number")
	tv_get_number_e :: proc "c" (tv: ^Typval_T) -> C.longlong ---
	@(link_name = "tv_get_string")
	tv_get_string_e :: proc "c" (tv: ^Typval_T) -> cstring ---
	@(link_name = "tv_get_string_buf")
	tv_get_string_buf_e :: proc "c" (tv: ^Typval_T, buf: ^u8) -> cstring ---
	@(link_name = "tv_list_extend")
	tv_list_extend_e :: proc "c" (l1: rawptr, l2: rawptr, bef: rawptr) ---
	@(link_name = "grow_string_tv")
	grow_string_tv_e :: proc "c" (tv: ^Typval_T, s2: cstring) -> C.int ---
	@(link_name = "tv_clear")
	tv_clear_e :: proc "c" (tv: ^Typval_T) ---
	@(link_name = "num_divide")
	num_divide_e :: proc "c" (n1: C.longlong, n2: C.longlong) -> C.longlong ---
	@(link_name = "num_modulus")
	num_modulus_e :: proc "c" (n1: C.longlong, n2: C.longlong) -> C.longlong ---
}

// tv_blob_len is a C static inline (typval.h:248): bv_ga.ga_len @ blob+0.
tv_blob_len_o :: proc "c" (b: rawptr) -> C.int {
	context = runtime.default_context()
	if b == nil {
		return 0
	}
	return (^C.int)(b)^
}

// tv_list_ref is a C static inline (typval.h:32): lv_refcount @ list+56.
tv_list_ref_o :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	if l == nil {
		return
	}
	(^C.int)(uintptr(l) + 56)^ += 1
}

// op_first reads *op (cstring is opaque in Odin).
op_first :: proc(op: cstring) -> u8 {
	return (^u8)(rawptr(op))^
}

// Handle "blob1 += blob2".
tv_op_blob_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	if op_first(op) != '+' || tv2.v_type != VAR_BLOB {
		return FAIL_E
	}
	b2 := (rawptr)(tv2.vval)
	if b2 == nil {
		return OK_E
	}
	b1 := (rawptr)(tv1.vval)
	if b1 == nil {
		tv1.vval = b2
		(^C.int)(uintptr(b2) + 24)^ += 1 // bv_refcount
		return OK_E
	}
	blen := tv_blob_len_o(b2)
	if blen > 0 {
		ga_grow_r((^Garray)(b1), blen)
		len1 := (^C.int)(b1)^ // bv_ga.ga_len
		data1 := (^rawptr)(uintptr(b1) + 16)^ // bv_ga.ga_data
		data2 := (^rawptr)(uintptr(b2) + 16)^
		libc.memmove(rawptr(uintptr(data1) + uintptr(len1)), data2, C.size_t(blen))
		(^C.int)(b1)^ = len1 + blen
	}
	return OK_E
}

// Handle "list1 += list2".
tv_op_list_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	if op_first(op) != '+' || tv2.v_type != VAR_LIST {
		return FAIL_E
	}
	l2 := (rawptr)(tv2.vval)
	if l2 == nil {
		return OK_E
	}
	l1 := (rawptr)(tv1.vval)
	if l1 == nil {
		tv1.vval = l2
		tv_list_ref_o(l2)
	} else {
		tv_list_extend_e(l1, l2, nil)
	}
	return OK_E
}

// Handle number operations: nr += nr, nr -= nr, nr *= nr, nr /= nr, nr %= nr.
tv_op_number_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	n := tv_get_number_e(tv1)
	if tv2.v_type == VAR_FLOAT {
		f := f64(n)
		o := op_first(op)
		if o == '%' {
			return FAIL_E
		}
		f2 := transmute(f64)(tv2.vval)
		switch o {
		case '+':
			f += f2
		case '-':
			f -= f2
		case '*':
			f *= f2
		case '/':
			f /= f2
		}
		tv_clear_e(tv1)
		tv1.v_type = VAR_FLOAT
		tv1.vval = transmute(rawptr)(f)
	} else {
		o := op_first(op)
		if o == '+' {
			n += tv_get_number_e(tv2)
		} else if o == '-' {
			n -= tv_get_number_e(tv2)
		} else if o == '*' {
			n *= tv_get_number_e(tv2)
		} else if o == '/' {
			n = num_divide_e(n, tv_get_number_e(tv2))
		} else if o == '%' {
			n = num_modulus_e(n, tv_get_number_e(tv2))
		}
		tv_clear_e(tv1)
		tv1.v_type = VAR_NUMBER
		tv1.vval = transmute(rawptr)(n)
	}
	return OK_E
}

// Handle "str1 .= str2".
tv_op_string_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	if tv2.v_type == VAR_FLOAT {
		return FAIL_E
	}
	numbuf: [65]u8 // NUMBUFLEN (digraph.odin)
	s2 := tv_get_string_buf_e(tv2, &numbuf[0])
	if grow_string_tv_e(tv1, s2) == OK_E {
		return OK_E
	}
	tvs := tv_get_string_e(tv1)
	s := concat_str_c(tvs, s2)
	tv_clear_e(tv1)
	tv1.v_type = VAR_STRING
	tv1.vval = transmute(rawptr)(s)
	return OK_E
}

// Handle "tv1 += tv2", "-=", "*=", "/=", "%=" and ".=".
tv_op_nr_or_string_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	if tv2.v_type == VAR_LIST {
		return FAIL_E
	}
	if vim_strchr_c(transmute(^u8)(cstring("+-*/%")), C.int(op_first(op))) != nil {
		return tv_op_number_o(tv1, tv2, op)
	}
	return tv_op_string_o(tv1, tv2, op)
}

// Handle "f1 += f2", "-=", "*=", "/=".
tv_op_float_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	o := op_first(op)
	if o == '%' || o == '.' ||
		(tv2.v_type != VAR_FLOAT && tv2.v_type != VAR_NUMBER && tv2.v_type != VAR_STRING) {
		return FAIL_E
	}
	f: f64
	if tv2.v_type == VAR_FLOAT {
		f = transmute(f64)(tv2.vval)
	} else {
		f = f64(tv_get_number_e(tv2))
	}
	cur := transmute(f64)(tv1.vval)
	if o == '+' {
		cur += f
	} else if o == '-' {
		cur -= f
	} else if o == '*' {
		cur *= f
	} else if o == '/' {
		cur /= f
	}
	tv1.vval = transmute(rawptr)(cur)
	return OK_E
}

// Handle tv1 += tv2, -=, *=, /=, %=, .=
@(export)
eexe_mod_op :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	if tv2.v_type == VAR_FUNC || tv2.v_type == VAR_DICT ||
		((tv2.v_type == VAR_BOOL || tv2.v_type == VAR_SPECIAL) && op_first(op) == '.') {
		semsg(cstring(E_LETWRONG_S), op)
		return FAIL_E
	}
	retval: C.int = FAIL_E
	switch tv1.v_type {
	case VAR_DICT, VAR_FUNC, VAR_PARTIAL, VAR_BOOL, VAR_SPECIAL:
		// retval stays FAIL
	case VAR_BLOB:
		retval = tv_op_blob_o(tv1, tv2, op)
	case VAR_LIST:
		retval = tv_op_list_o(tv1, tv2, op)
	case VAR_NUMBER, VAR_STRING:
		retval = tv_op_nr_or_string_o(tv1, tv2, op)
	case VAR_FLOAT:
		retval = tv_op_float_o(tv1, tv2, op)
	case VAR_UNKNOWN:
		libc.abort()
	case:
		// Unknown v_type (corrupt typval): same as C falling off the switch
		// with retval == FAIL.
	}
	if retval != OK_E {
		semsg(cstring(E_LETWRONG_S), op)
	}
	return retval
}

// —— Batch 3: eval/deprecated.c ——
foreign _ {
	@(link_name = "tv_dict_alloc")
	tv_dict_alloc_e :: proc "c" () -> rawptr ---
	@(link_name = "tv_dict_add_bool")
	tv_dict_add_bool_e :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: C.int) -> C.int ---
	@(link_name = "tv_dict_free")
	tv_dict_free_e :: proc "c" (d: rawptr) ---
	@(link_name = "tv_list_append_tv")
	tv_list_append_tv_e :: proc "c" (l: rawptr, tv: ^Typval_T) ---
	@(link_name = "tv_copy")
	tv_copy_e :: proc "c" (from: ^Typval_T, to: ^Typval_T) ---
	@(link_name = "tv_get_number_chk")
	tv_get_number_chk_e :: proc "c" (tv: ^Typval_T, ret_error: ^bool) -> C.longlong ---
	@(link_name = "value_check_lock")
	value_check_lock_e :: proc "c" (lock: C.int, name: cstring, name_len: C.size_t) -> bool ---
	@(link_name = "ga_append")
	ga_append_e :: proc "c" (gap: ^Garray, c: u8) ---
	@(link_name = "tv_check_for_string_or_list_or_blob_arg")
	tv_check_for_string_or_list_or_blob_arg_e :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int ---
	@(link_name = "tv_list_reverse")
	tv_list_reverse_e :: proc "c" (l: rawptr) ---
	@(link_name = "reverse_text")
	reverse_text_e :: proc "c" (s: ^u8) -> ^u8 ---
	@(link_name = "channel_job_start")
	channel_job_start_e :: proc "c" (argv: rawptr, exepath: cstring, on_stdout: CallbackReader_E, on_stderr: CallbackReader_E, on_exit: Callback_E, pty: bool, rpc: bool, overlapped: bool, detach: bool, stdin_mode: C.int, cwd: cstring, pty_width: C.uint16_t, pty_height: C.uint16_t, env: rawptr, status_out: rawptr) -> rawptr ---
	@(link_name = "channel_create_event")
	channel_create_event_e :: proc "c" (chan: rawptr, ext_source: cstring) ---
	@(link_name = "channel_close")
	channel_close_e :: proc "c" (id: C.ulonglong, part: C.int, error: ^cstring) -> bool ---
	@(link_name = "find_job")
	find_job_e :: proc "c" (id: C.ulonglong, show_error: bool) -> rawptr ---
	@(link_name = "f_jobstop")
	f_jobstop_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) ---
	@(link_name = "f_jobstart")
	f_jobstart_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) ---
}

// Callback mirror (channel_defs.h): union{ptr}+type = 16B with tail pad.
Callback_E :: struct {
	data: rawptr,
	type: C.int,
}
#assert(size_of(Callback_E) == 16)

// CallbackReader mirror (channel_defs.h): 64B.
CallbackReader_E :: struct {
	cb:         Callback_E, // 0..16
	self:       rawptr,     // 16..24
	ga_len:     C.int,      // 24
	ga_maxlen:  C.int,      // 28
	ga_itemsize: C.int,     // 32
	ga_growsize: C.int,     // 36
	ga_data:    rawptr,     // 40..48
	eof:        bool,       // 48
	buffered:   bool,       // 49
	fwd_err:    bool,       // 50
	_pad1:      [5]u8,
	type:       cstring,    // 56..64
}
#assert(size_of(CallbackReader_E) == 64)

E_API_SPAWN_FAILED_S :: "E903: Could not spawn API job"
E5010_S :: "E5010: List item %d of the second argument is not a string"

// tv_list_len is a C static inline (typval.h:97): lv_len @ list+60.
tv_list_len_o :: proc "c" (l: rawptr) -> C.int {
	context = runtime.default_context()
	if l == nil {
		return 0
	}
	return (^C.int)(uintptr(l) + 60)^
}

// "rpcstart()" function (DEPRECATED).
@(export)
f_rpcstart :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	a0 := (([^]Typval_T)(argvars))[0]
	a1 := (([^]Typval_T)(argvars))[1]
	if a0.v_type != VAR_STRING || (a1.v_type != VAR_LIST && a1.v_type != VAR_UNKNOWN) {
		emsg(cstring(e_invarg_s))
		return
	}
	args := a1.vval
	argsl: C.int = 0
	if a1.v_type == VAR_LIST {
		argsl = tv_list_len_o(args)
		i: C.int = 0
		it := (^rawptr)(args)^ // lv_first
		for it != nil {
			li := (^ListItem)(it)
			if li.li_tv.v_type != VAR_STRING {
				semsg(cstring(E5010_S), i)
				return
			}
			i += 1
			it = li.li_next
		}
	}
	s0 := (^u8)(a0.vval)
	if s0 == nil || s0^ == 0 {
		emsg(cstring(E_API_SPAWN_FAILED_S))
		return
	}
	argv := ([^]rawptr)(xmalloc(C.size_t(argsl + 2) * 8))
	argv[0] = transmute(rawptr)(xstrdup_o(s0))
	i: C.int = 1
	if argsl > 0 {
		it := (^rawptr)(args)^
		for it != nil {
			li := (^ListItem)(it)
			argv[i] = transmute(rawptr)(xstrdup_o(transmute(^u8)(tv_get_string_e(transmute(^Typval_T)(&li.li_tv)))))
			i += 1
			it = li.li_next
		}
	}
	argv[i] = nil
	cri := CallbackReader_E{}
	cri.ga_growsize = 1 // GA_EMPTY_INIT_VALUE growsize
	chan := channel_job_start_e(transmute(rawptr)(argv), nil, cri, cri, Callback_E{}, false, true, false, false, 0, nil, 0, 0, nil, rawptr(&rettv.vval))
	if chan != nil {
		channel_create_event_e(chan, nil)
	}
}

// "rpcstop()" function.
@(export)
f_rpcstop :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	a0 := (([^]Typval_T)(argvars))[0]
	if a0.v_type != VAR_NUMBER {
		emsg(cstring(e_invarg_s))
		return
	}
	id := C.ulonglong(transmute(C.longlong)(a0.vval))
	if find_job_e(id, false) != nil {
		f_jobstop_e(argvars, rettv, fptr)
	} else {
		err: cstring
		ok := channel_close_e(id, 3, &err) // kChannelPartRpc
		rettv.vval = transmute(rawptr)(C.longlong(ok ? 1 : 0))
		if !ok {
			emsg(err)
		}
	}
}

// "last_buffer_nr()" function.
@(export)
f_last_buffer_nr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n: C.int = 0
	buf := firstbuf
	for buf != nil {
		fnum := (^C.int)(buf)^ // b_fnum@0
		if n < fnum {
			n = fnum
		}
		buf = (^rawptr)(uintptr(buf) + 120)^ // b_next@120
	}
	// NOTE: C never sets rettv->v_type here either — replicate exactly.
	rettv.vval = transmute(rawptr)(C.longlong(n))
}

// "termopen(cmd[, cwd])" function.
@(export)
f_termopen :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	must_free := false
	// NOTE: &argvars[1] via explicit offsets (Odin forbids & on multi-pointer index).
	a1_type := (^C.int)(uintptr(argvars) + 16)
	a1_vval := (^rawptr)(uintptr(argvars) + 24)
	if a1_type^ == VAR_UNKNOWN {
		must_free = true
		a1_type^ = VAR_DICT
		a1_vval^ = tv_dict_alloc_e()
	}
	if a1_type^ != VAR_DICT {
		semsg(e_invarg2, cstring("expected dictionary"))
		return
	}
	tv_dict_add_bool_e(a1_vval^, cstring("term"), 4, 1)
	f_jobstart_e(argvars, rettv, fptr)
	if must_free {
		tv_dict_free_e(a1_vval^)
	}
}

// —— Batch 4: eval/list.c leaves (f_add, f_reverse) ——
E_LISTBLOBREQ_S :: "E897: List or Blob required"

// tv_list_locked is a C static inline (typval.h:58): nil→FIXED(2), else lv_lock@72.
tv_list_locked_o :: proc "c" (l: rawptr) -> C.int {
	context = runtime.default_context()
	if l == nil {
		return 2
	}
	return (^C.int)(uintptr(l) + 72)^
}

// tv_list_set_ret inline (typval.h:45): v_type=LIST, vval=l, ref++.
tv_list_set_ret_o :: proc "c" (tv: ^Typval_T, l: rawptr) {
	context = runtime.default_context()
	tv.v_type = VAR_LIST
	tv.vval = l
	tv_list_ref_o(l)
}

// tv_blob_set_ret inline (typval.h:235): v_type=BLOB, vval=b, ref++ if b.
tv_blob_set_ret_o :: proc "c" (tv: ^Typval_T, b: rawptr) {
	context = runtime.default_context()
	tv.v_type = VAR_BLOB
	tv.vval = b
	if b != nil {
		(^C.int)(uintptr(b) + 24)^ += 1
	}
}

// tv_blob_get inline (typval.h:263): ga_data[idx], ga_data@blob+16.
tv_blob_get_o :: proc "c" (b: rawptr, idx: C.int) -> u8 {
	context = runtime.default_context()
	data := (^rawptr)(uintptr(b) + 16)^
	return ([^]u8)(data)[uintptr(idx)]
}

// tv_blob_set inline (typval.h:274).
tv_blob_set_o :: proc "c" (b: rawptr, idx: C.int, c: u8) {
	context = runtime.default_context()
	data := (^rawptr)(uintptr(b) + 16)^
	([^]u8)(data)[uintptr(idx)] = c
}

// "add(list, item)" function.
@(export)
f_add :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	// NOTE: C writes only vval here (no v_type) — replicate exactly; the
	// caller owns rettv's type on silent-failure paths.
	rettv.vval = transmute(rawptr)(C.longlong(1)) // Default: failed.
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if a0.v_type == VAR_LIST {
		l := (rawptr)(a0.vval)
		if !value_check_lock_e(tv_list_locked_o(l), cstring("add() argument"), max(C.size_t)) {
			tv_list_append_tv_e(l, a1)
			tv_copy_e(a0, rettv)
		}
	} else if a0.v_type == VAR_BLOB {
		b := (rawptr)(a0.vval)
		if b != nil && !value_check_lock_e((^C.int)(uintptr(b) + 28)^, cstring("add() argument"), max(C.size_t)) {
			error := false
			n := tv_get_number_chk_e(a1, &error)
			if !error {
				ga_append_e((^Garray)(b), u8(n))
				tv_copy_e(a0, rettv)
			}
		}
	} else {
		emsg(cstring(E_LISTBLOBREQ_S))
	}
}

// "reverse({list})" function.
@(export)
f_reverse :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_string_or_list_or_blob_arg_e(argvars, 0) == FAIL_E {
		return
	}
	a0 := (^Typval_T)(uintptr(argvars))
	if a0.v_type == VAR_BLOB {
		b := (rawptr)(a0.vval)
		blen := tv_blob_len_o(b)
		i: C.int = 0
		for i < blen / 2 {
			tmp := tv_blob_get_o(b, i)
			tv_blob_set_o(b, i, tv_blob_get_o(b, blen - i - 1))
			tv_blob_set_o(b, blen - i - 1, tmp)
			i += 1
		}
		tv_blob_set_ret_o(rettv, b)
	} else if a0.v_type == VAR_STRING {
		rettv.v_type = VAR_STRING
		s := (^u8)(a0.vval)
		if s != nil {
			rettv.vval = transmute(rawptr)(reverse_text_e(s))
		} else {
			rettv.vval = nil
		}
	} else if a0.v_type == VAR_LIST {
		l := (rawptr)(a0.vval)
		if !value_check_lock_e(tv_list_locked_o(l), cstring("reverse() argument"), max(C.size_t)) {
			tv_list_reverse_e(l)
			tv_list_set_ret_o(rettv, l)
		}
	}
}

// —— Batch 5: eval/list.c f_count + count_* ——
foreign _ {
	@(link_name = "tv_equal")
	tv_equal_e :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, ic: bool) -> bool ---
	@(link_name = "tv_list_find")
	tv_list_find_e :: proc "c" (l: rawptr, n: C.int) -> rawptr ---
	@(link_name = "tv_get_string_chk")
	tv_get_string_chk_e :: proc "c" (tv: ^Typval_T) -> cstring ---
	@(link_name = "mb_strnicmp")
	mb_strnicmp_e :: proc "c" (s1: cstring, s2: cstring, nn: C.size_t) -> C.int ---
}

E684_S :: "E684: List index out of range: %ld"
E706_S :: "E706: Argument of %s must be a List, String or Dictionary"

// Count "needle" in string "haystack".
count_string_o :: proc "c" (haystack: cstring, needle: cstring, ic: bool) -> C.longlong {
	context = runtime.default_context()
	n: C.longlong = 0
	p := uintptr(rawptr(haystack))
	if haystack == nil || needle == nil || (^u8)(rawptr(needle))^ == 0 {
		return 0
	}
	needlelen := C.size_t(libc.strlen(needle))
	if ic {
		for ([^]u8)(p)[0] != 0 {
			if mb_strnicmp_e(transmute(cstring)(rawptr(p)), needle, needlelen) == 0 {
				n += 1
				p += uintptr(needlelen)
			} else {
				// MB_PTR_ADV === utfc_ptr2len in this tree.
				p += uintptr(utfc_ptr2len(transmute(cstring)(rawptr(p))))
			}
		}
	} else {
		next := strstr_c(transmute(cstring)(rawptr(p)), needle)
		for next != nil {
			n += 1
			p = uintptr(rawptr(next)) + uintptr(needlelen)
			next = strstr_c(transmute(cstring)(rawptr(p)), needle)
		}
	}
	return n
}

// Count item "needle" in List "l" from index "idx".
count_list_o :: proc "c" (l: rawptr, needle: ^Typval_T, idx: C.longlong, ic: bool) -> C.longlong {
	context = runtime.default_context()
	if tv_list_len_o(l) == 0 {
		return 0
	}
	li := tv_list_find_e(l, C.int(idx))
	if li == nil {
		semsg(cstring(E684_S), idx)
		return 0
	}
	n: C.longlong = 0
	for li != nil {
		if tv_equal_e((^Typval_T)(uintptr(li) + 16), needle, ic) {
			n += 1
		}
		li = (^rawptr)(li)^ // li_next@0
	}
	return n
}

// Count item "needle" in Dict "d" (TV_DICT_ITER walk over dv_hashtab@16:
// ht_used@24, ht_array@48; hashitem 16B {hi_hash@0, hi_key@8}; di = key-17).
count_dict_o :: proc "c" (d: rawptr, needle: ^Typval_T, ic: bool) -> C.longlong {
	context = runtime.default_context()
	if d == nil {
		return 0
	}
	n: C.longlong = 0
	todo := (^C.size_t)(uintptr(d) + 24)^
	hi := uintptr((^rawptr)(uintptr(d) + 48)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1] // hi_key@hi+8
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		if tv_equal_e((^Typval_T)(uintptr(key) - 17), needle, ic) {
			n += 1
		}
	}
	return n
}

// "count()" function.
@(export)
f_count :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n: C.longlong = 0
	ic: C.int = 0
	error := false
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	a3 := (^Typval_T)(uintptr(argvars) + 48)
	if a2.v_type != VAR_UNKNOWN {
		ic = C.int(tv_get_number_chk_e(a2, &error))
	}
	if !error && a0.v_type == VAR_STRING {
		n = count_string_o(transmute(cstring)((rawptr)(a0.vval)), tv_get_string_chk_e(a1), ic != 0)
	} else if !error && a0.v_type == VAR_LIST {
		idx: C.longlong = 0
		if a2.v_type != VAR_UNKNOWN && a3.v_type != VAR_UNKNOWN {
			idx = tv_get_number_chk_e(a3, &error)
		}
		if !error {
			n = count_list_o((rawptr)(a0.vval), a1, idx, ic != 0)
		}
	} else if !error && a0.v_type == VAR_DICT {
		d := (rawptr)(a0.vval)
		if d != nil {
			if a2.v_type != VAR_UNKNOWN && a3.v_type != VAR_UNKNOWN {
				emsg(cstring(e_invarg_s))
			} else {
				n = count_dict_o(d, a1, ic != 0)
			}
		}
	} else if !error {
		semsg(cstring(E706_S), cstring("count()"))
	}
	// NOTE: C writes only vval here — replicate exactly.
	rettv.vval = transmute(rawptr)(n)
}

// —— Batch 6: eval/list.c filter/map engine ——
foreign _ {
	@(link_name = "get_vim_var_tv")
	get_vim_var_tv_e :: proc "c" (idx: C.int) -> ^Typval_T ---
	@(link_name = "set_vim_var_string")
	set_vim_var_string_e :: proc "c" (idx: C.int, val: cstring, len: C.ssize_t) ---
	@(link_name = "set_vim_var_type")
	set_vim_var_type_e :: proc "c" (idx: C.int, type: C.int) ---
	@(link_name = "eval_expr_typval")
	eval_expr_typval_e :: proc "c" (expr: ^Typval_T, want_func: bool, argv: ^Typval_T, argc: C.int, rettv: ^Typval_T) -> C.int ---
	@(link_name = "prepare_vimvar")
	prepare_vimvar_e :: proc "c" (idx: C.int, save_tv: ^Typval_T) ---
	@(link_name = "restore_vimvar")
	restore_vimvar_e :: proc "c" (idx: C.int, save_tv: ^Typval_T) ---
	@(link_name = "hash_lock")
	hash_lock_e :: proc "c" (ht: rawptr) ---
	@(link_name = "hash_unlock")
	hash_unlock_e :: proc "c" (ht: rawptr) ---
	@(link_name = "var_check_ro")
	var_check_ro_e :: proc "c" (flags: C.int, name: cstring, name_len: C.size_t) -> bool ---
	@(link_name = "var_check_fixed")
	var_check_fixed_e :: proc "c" (flags: C.int, name: cstring, name_len: C.size_t) -> bool ---
	@(link_name = "tv_dict_item_remove")
	tv_dict_item_remove_e :: proc "c" (dict: rawptr, item: rawptr) ---
	@(link_name = "tv_blob_copy")
	tv_blob_copy_e :: proc "c" (from: rawptr, to: ^Typval_T) ---
	@(link_name = "tv_list_item_remove")
	tv_list_item_remove_e :: proc "c" (l: rawptr, item: rawptr) -> rawptr ---
	@(link_name = "ga_concat")
	ga_concat_e :: proc "c" (gap: ^Garray, s: cstring) ---
}

FILTERMAP_FILTER_O :: 0
FILTERMAP_MAP_O :: 1
FILTERMAP_MAPNEW_O :: 2
FILTERMAP_FOREACH_O :: 3

VV_VAL_O :: 35
VV_KEY_O :: 36

E1250_S :: "E1250: Argument of %s must be a List, String, Dictionary or Blob"
E_INVALBLOB_S :: "E978: Invalid operation for Blob"
E_STRING_REQUIRED_S :: "E928: String required"

// tv_list_first inline (typval.h:169): nil→nil else lv_first@0.
tv_list_first_o :: proc "c" (l: rawptr) -> rawptr {
	context = runtime.default_context()
	if l == nil {
		return nil
	}
	return (^rawptr)(l)^
}

// Handle one item for map()/filter()/foreach(). Sets v:val; caller sets v:key.
filter_map_one_o :: proc "c" (tv: ^Typval_T, expr: ^Typval_T, filtermap: C.int, newtv: ^Typval_T, remp: ^bool) -> C.int {
	context = runtime.default_context()
	retval: C.int = FAIL_E
	tv_copy_e(tv, get_vim_var_tv_e(VV_VAL_O))
	newtv.v_type = VAR_UNKNOWN
	if filtermap == FILTERMAP_FOREACH_O && expr.v_type == VAR_STRING {
		// foreach() is not limited to an expression.
		do_cmdline_cmd_r(transmute(cstring)((rawptr)(expr.vval)))
		if did_emsg_flag == 0 {
			retval = OK_E
		}
	} else {
		argv: [3]Typval_T
		argv[0] = get_vim_var_tv_e(VV_KEY_O)^
		argv[1] = get_vim_var_tv_e(VV_VAL_O)^
		if eval_expr_typval_e(expr, false, &argv[0], 2, newtv) != FAIL_E {
			if filtermap == FILTERMAP_FILTER_O {
				err := false
				remp^ = tv_get_number_chk_e(newtv, &err) == 0
				tv_clear_e(newtv)
				if !err {
					retval = OK_E
				}
			} else {
				if filtermap == FILTERMAP_FOREACH_O {
					tv_clear_e(newtv)
				}
				retval = OK_E
			}
		}
	}
	tv_clear_e(get_vim_var_tv_e(VV_VAL_O))
	return retval
}

// Dict walk helper: TV_DICT_ITER body over dv_hashtab (same layout as count_dict_o).
// Visits di (rawptr to dictitem); stop when visit returns false.
dict_walk_o :: proc "c" (d: rawptr, visit: proc "c" (di: rawptr) -> bool) {
	context = runtime.default_context()
	todo := (^C.size_t)(uintptr(d) + 24)^
	hi := uintptr((^rawptr)(uintptr(d) + 48)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		if !visit(rawptr(uintptr(key) - 17)) {
			return
		}
	}
}

// filter_map_dict state threaded through the walk callback.
filter_map_dict_state: struct {
	d:          rawptr,
	d_ret:      rawptr,
	filtermap:  C.int,
	func_name:  cstring,
	arg_errmsg: cstring,
	expr:       ^Typval_T,
	rettv:      ^Typval_T,
	failed:     bool,
}

filter_map_dict_visit :: proc "c" (di: rawptr) -> bool {
	context = runtime.default_context()
	s := &filter_map_dict_state
	fm := s.filtermap
	if fm == FILTERMAP_MAP_O {
		di_tv := (^Typval_T)(di)
		if value_check_lock_e(di_tv.v_lock, s.arg_errmsg, max(C.size_t)) ||
			var_check_ro_e(C.int(([^]u8)(di)[16]), s.arg_errmsg, max(C.size_t)) {
			s.failed = true
			return false
		}
	}
	set_vim_var_string_e(VV_KEY_O, transmute(cstring)(rawptr(uintptr(di) + 17)), -1)
	newtv := Typval_T{}
	rem := false
	r := filter_map_one_o((^Typval_T)(di), s.expr, fm, &newtv, &rem)
	tv_clear_e(get_vim_var_tv_e(VV_KEY_O))
	if r == FAIL_E || did_emsg_flag != 0 {
		tv_clear_e(&newtv)
		s.failed = true
		return false
	}
	if fm == FILTERMAP_MAP_O {
		di_tv := (^Typval_T)(di)
		tv_clear_e(di_tv)
		newtv.v_lock = VAR_UNLOCKED
		di_tv^ = newtv
	} else if fm == FILTERMAP_MAPNEW_O {
		key := transmute(cstring)(rawptr(uintptr(di) + 17))
		r2 := tv_dict_add_tv_c(s.d_ret, key, C.size_t(libc.strlen(key)), &newtv)
		tv_clear_e(&newtv)
		if r2 == FAIL_E {
			s.failed = true
			return false
		}
	} else if fm == FILTERMAP_FILTER_O && rem {
		di_flags := C.int(([^]u8)(di)[16])
		if var_check_fixed_e(di_flags, s.arg_errmsg, max(C.size_t)) ||
			var_check_ro_e(di_flags, s.arg_errmsg, max(C.size_t)) {
			s.failed = true
			return false
		}
		tv_dict_item_remove_e(s.d, di)
	}
	return true
}

// Implementation of map()/filter()/foreach() for a Dict.
filter_map_dict_o :: proc "c" (d: rawptr, filtermap: C.int, func_name: cstring, arg_errmsg: cstring, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	if filtermap == FILTERMAP_MAPNEW_O {
		rettv.v_type = VAR_DICT
		rettv.vval = nil
	}
	if d == nil ||
		(filtermap == FILTERMAP_FILTER_O &&
			value_check_lock_e((^C.int)(d)^, arg_errmsg, max(C.size_t))) {
		return
	}
	d_ret: rawptr = nil
	if filtermap == FILTERMAP_MAPNEW_O {
		tv_dict_alloc_ret_r(transmute(^Typval)(rettv))
		d_ret = (rawptr)(rettv.vval)
	}
	prev_lock := (^C.int)(d)^
	if prev_lock == VAR_UNLOCKED {
		(^C.int)(d)^ = VAR_LOCKED
	}
	hash_lock_e(rawptr(uintptr(d) + 16))
	filter_map_dict_state = {
		d = d,
		d_ret = d_ret,
		filtermap = filtermap,
		func_name = func_name,
		arg_errmsg = arg_errmsg,
		expr = expr,
		rettv = rettv,
		failed = false,
	}
	dict_walk_o(d, filter_map_dict_visit)
	hash_unlock_e(rawptr(uintptr(d) + 16))
	(^C.int)(d)^ = prev_lock
}

// Implementation of map()/filter()/foreach() for a Blob.
filter_map_blob_o :: proc "c" (blob_arg: rawptr, filtermap: C.int, expr: ^Typval_T, arg_errmsg: cstring, rettv: ^Typval_T) {
	context = runtime.default_context()
	if filtermap == FILTERMAP_MAPNEW_O {
		rettv.v_type = VAR_BLOB
		rettv.vval = nil
	}
	b := blob_arg
	if b == nil ||
		(filtermap == FILTERMAP_FILTER_O &&
			value_check_lock_e((^C.int)(uintptr(b) + 28)^, arg_errmsg, max(C.size_t))) {
		return
	}
	b_ret := b
	if filtermap == FILTERMAP_MAPNEW_O {
		tv_blob_copy_e(b, rettv)
		b_ret = (rawptr)(rettv.vval)
	}
	// set_vim_var_nr() doesn't set the type.
	set_vim_var_type_e(VV_KEY_O, VAR_NUMBER)
	prev_lock := (^C.int)(uintptr(b) + 28)^
	if prev_lock == 0 {
		(^C.int)(uintptr(b) + 28)^ = VAR_LOCKED
	}
	i: C.int = 0
	idx: C.int = 0
	// NOTE: ga_len re-read every iteration (rem arm shrinks it) — no snapshot.
	for i < (^C.int)(b)^ {
		val := C.longlong(tv_blob_get_o(b, i))
		tv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(val)}
		set_vim_var_nr_c(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{}
		rem := false
		if filter_map_one_o(&tv, expr, filtermap, &newtv, &rem) == FAIL_E || did_emsg_flag != 0 {
			break
		}
		if filtermap != FILTERMAP_FOREACH_O {
			if newtv.v_type != VAR_NUMBER && newtv.v_type != VAR_BOOL {
				tv_clear_e(&newtv)
				emsg(cstring(E_INVALBLOB_S))
				break
			}
			if filtermap != FILTERMAP_FILTER_O {
				if transmute(C.longlong)(newtv.vval) != val {
					tv_blob_set_o(b_ret, i, u8(transmute(C.longlong)(newtv.vval)))
				}
			} else if rem {
				p := (^rawptr)(uintptr(blob_arg) + 16)^
				n := (^C.int)(b)^
				libc.memmove(rawptr(uintptr(p) + uintptr(i)), rawptr(uintptr(p) + uintptr(i) + 1), C.size_t(n - i - 1))
				(^C.int)(b)^ = n - 1
				i -= 1
			}
		}
		idx += 1
		i += 1
	}
	(^C.int)(uintptr(b) + 28)^ = prev_lock
}

// Implementation of map()/filter()/foreach() for a String.
filter_map_string_o :: proc "c" (str: cstring, filtermap: C.int, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	// set_vim_var_nr() doesn't set the type.
	set_vim_var_type_e(VV_KEY_O, VAR_NUMBER)
	ga: Garray
	ga_init_r2(&ga, 1, 80)
	idx: C.int = 0
	p := uintptr(rawptr(str))
	for ([^]u8)(p)[0] != 0 {
		ln := utfc_ptr2len(transmute(cstring)(rawptr(p)))
		tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2((^u8)(p), C.size_t(ln)))}
		set_vim_var_nr_c(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{v_lock = VAR_UNLOCKED}
		rem := false
		if filter_map_one_o(&tv, expr, filtermap, &newtv, &rem) == FAIL_E || did_emsg_flag != 0 {
			tv_clear_e(&newtv)
			tv_clear_e(&tv)
			break
		}
		if filtermap == FILTERMAP_MAP_O || filtermap == FILTERMAP_MAPNEW_O {
			if newtv.v_type != VAR_STRING {
				tv_clear_e(&newtv)
				tv_clear_e(&tv)
				emsg(cstring(E_STRING_REQUIRED_S))
				break
			} else {
				ga_concat_e(&ga, transmute(cstring)((rawptr)(newtv.vval)))
			}
		} else if filtermap == FILTERMAP_FOREACH_O || !rem {
			ga_concat_e(&ga, transmute(cstring)((rawptr)(tv.vval)))
		}
		tv_clear_e(&newtv)
		tv_clear_e(&tv)
		idx += 1
		p += uintptr(ln)
	}
	ga_append_e(&ga, 0)
	rettv.vval = ga.ga_data
}

// Implementation of map()/filter()/foreach() for a List.
filter_map_list_o :: proc "c" (l: rawptr, filtermap: C.int, func_name: cstring, arg_errmsg: cstring, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	if filtermap == FILTERMAP_MAPNEW_O {
		rettv.v_type = VAR_LIST
		rettv.vval = nil
	}
	if l == nil ||
		(filtermap == FILTERMAP_FILTER_O &&
			value_check_lock_e(tv_list_locked_o(l), arg_errmsg, max(C.size_t))) {
		return
	}
	l_ret: rawptr = nil
	if filtermap == FILTERMAP_MAPNEW_O {
		tv_list_alloc_ret(transmute(^Typval)(rettv), -1)
		l_ret = (rawptr)(rettv.vval)
	}
	// set_vim_var_nr() doesn't set the type.
	set_vim_var_type_e(VV_KEY_O, VAR_NUMBER)
	prev_lock := tv_list_locked_o(l)
	if prev_lock == VAR_UNLOCKED {
		(^C.int)(uintptr(l) + 72)^ = VAR_LOCKED
	}
	idx: C.int = 0
	li := tv_list_first_o(l)
	for li != nil {
		item := (^Typval_T)(uintptr(li) + 16)
		if filtermap == FILTERMAP_MAP_O && value_check_lock_e(item.v_lock, arg_errmsg, max(C.size_t)) {
			break
		}
		set_vim_var_nr_c(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{}
		rem := false
		if filter_map_one_o(item, expr, filtermap, &newtv, &rem) == FAIL_E {
			break
		}
		if did_emsg_flag != 0 {
			tv_clear_e(&newtv)
			break
		}
		if filtermap == FILTERMAP_MAP_O {
			tv_clear_e(item)
			newtv.v_lock = VAR_UNLOCKED
			item^ = newtv
		}
		if filtermap == FILTERMAP_MAPNEW_O {
			tv_list_append_owned_tv_r(l_ret, newtv)
		}
		if filtermap == FILTERMAP_FILTER_O && rem {
			li = tv_list_item_remove_e(l, li)
		} else {
			li = (^rawptr)(li)^
		}
		idx += 1
	}
	(^C.int)(uintptr(l) + 72)^ = prev_lock
}

// Implementation of map()/filter()/foreach().
filter_map_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, filtermap: C.int) {
	context = runtime.default_context()
	func_name: cstring = cstring("foreach()")
	arg_errmsg: cstring = cstring("foreach() argument")
	if filtermap == FILTERMAP_MAP_O {
		func_name = cstring("map()")
		arg_errmsg = cstring("map() argument")
	} else if filtermap == FILTERMAP_MAPNEW_O {
		func_name = cstring("mapnew()")
		arg_errmsg = cstring("mapnew() argument")
	} else if filtermap == FILTERMAP_FILTER_O {
		func_name = cstring("filter()")
		arg_errmsg = cstring("filter() argument")
	}
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	// map()/filter()/foreach() return the first argument, also on failure.
	if filtermap != FILTERMAP_MAPNEW_O && a0.v_type != VAR_STRING {
		tv_copy_e(a0, rettv)
	}
	if a0.v_type != VAR_BLOB && a0.v_type != VAR_LIST && a0.v_type != VAR_DICT && a0.v_type != VAR_STRING {
		semsg(cstring(E1250_S), func_name)
		return
	}
	expr := a1
	if expr.v_type == VAR_UNKNOWN {
		return
	}
	save_val := Typval_T{}
	save_key := Typval_T{}
	prepare_vimvar_e(VV_VAL_O, &save_val)
	prepare_vimvar_e(VV_KEY_O, &save_key)
	save_did_emsg := did_emsg_flag
	did_emsg_flag = 0
	if a0.v_type == VAR_DICT {
		filter_map_dict_o((rawptr)(a0.vval), filtermap, func_name, arg_errmsg, expr, rettv)
	} else if a0.v_type == VAR_BLOB {
		filter_map_blob_o((rawptr)(a0.vval), filtermap, expr, arg_errmsg, rettv)
	} else if a0.v_type == VAR_STRING {
		filter_map_string_o(tv_get_string_e(a0), filtermap, expr, rettv)
	} else {
		filter_map_list_o((rawptr)(a0.vval), filtermap, func_name, arg_errmsg, expr, rettv)
	}
	restore_vimvar_e(VV_KEY_O, &save_key)
	restore_vimvar_e(VV_VAL_O, &save_val)
	did_emsg_flag |= save_did_emsg
}

// "filter()" function.
@(export)
f_filter :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	filter_map_o(argvars, rettv, FILTERMAP_FILTER_O)
}

// "map()" function.
@(export)
f_map :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	filter_map_o(argvars, rettv, FILTERMAP_MAP_O)
}

// "mapnew()" function.
@(export)
f_mapnew :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	filter_map_o(argvars, rettv, FILTERMAP_MAPNEW_O)
}

// "foreach()" function.
@(export)
f_foreach :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	filter_map_o(argvars, rettv, FILTERMAP_FOREACH_O)
}

// —— Batch 7: eval/list.c extend/insert/remove ——
foreign _ {
	@(link_name = "tv_dict_copy")
	tv_dict_copy_e :: proc "c" (conv: rawptr, orig: rawptr, deep: bool, copyID: C.int) -> rawptr ---
	@(link_name = "get_copyID")
	get_copyID_e :: proc "c" () -> C.int ---
	@(link_name = "tv_dict_unref")
	tv_dict_unref_e :: proc "c" (d: rawptr) ---
	@(link_name = "tv_dict_extend")
	tv_dict_extend_e :: proc "c" (d1: rawptr, d2: rawptr, action: cstring) ---
	@(link_name = "tv_list_copy")
	tv_list_copy_e :: proc "c" (conv: rawptr, orig: rawptr, deep: bool, copyID: C.int) -> rawptr ---
	@(link_name = "tv_list_unref")
	tv_list_unref_e :: proc "c" (l: rawptr) ---
	@(link_name = "tv_list_insert_tv")
	tv_list_insert_tv_e :: proc "c" (l: rawptr, tv: ^Typval_T, item: rawptr) ---
	@(link_name = "tv_dict_remove")
	tv_dict_remove_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) ---
	@(link_name = "tv_blob_remove")
	tv_blob_remove_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) ---
	@(link_name = "tv_list_remove")
	tv_list_remove_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) ---
}

E_LISTDICTARG_S :: "E712: Argument of %s must be a List or Dictionary"
E_LISTBLOBARG_S :: "E899: Argument of %s must be a List or Blob"
E_LISTDICTBLOBARG_S :: "E896: Argument of %s must be a List, Dictionary or Blob"

// extend() a Dict.
extend_dict_o :: proc "c" (argvars: ^Typval_T, arg_errmsg: cstring, is_new: bool, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	d1 := (rawptr)(a0.vval)
	if d1 == nil {
		locked := value_check_lock_e(VAR_FIXED_O, arg_errmsg, max(C.size_t))
		if !locked {
			libc.abort()
		}
		return
	}
	d2 := (rawptr)(a1.vval)
	if d2 == nil {
		tv_copy_e(a0, rettv)
		return
	}
	if !is_new && value_check_lock_e((^C.int)(d1)^, arg_errmsg, max(C.size_t)) {
		return
	}
	if is_new {
		d1 = tv_dict_copy_e(nil, d1, false, get_copyID_e())
		if d1 == nil {
			return
		}
	}
	action := cstring("force")
	if a2.v_type != VAR_UNKNOWN {
		action = tv_get_string_chk_e(a2)
		if action == nil {
			if is_new {
				tv_dict_unref_e(d1)
			}
			return
		}
		if libc.strcmp(action, cstring("keep")) != 0 && libc.strcmp(action, cstring("force")) != 0 && libc.strcmp(action, cstring("error")) != 0 {
			if is_new {
				tv_dict_unref_e(d1)
			}
			semsg(e_invarg2, action)
			return
		}
	}
	tv_dict_extend_e(d1, d2, action)
	if is_new {
		rettv^ = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = d1}
	} else {
		tv_copy_e(a0, rettv)
	}
}

// extend() a List.
extend_list_o :: proc "c" (argvars: ^Typval_T, arg_errmsg: cstring, is_new: bool, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	error := false
	l1 := (rawptr)(a0.vval)
	l2 := (rawptr)(a1.vval)
	if !is_new && value_check_lock_e(tv_list_locked_o(l1), arg_errmsg, max(C.size_t)) {
		return
	}
	if is_new {
		l1 = tv_list_copy_e(nil, l1, false, get_copyID_e())
		if l1 == nil {
			return
		}
	}
	item: rawptr = nil
	cleanup_needed := false
	if a2.v_type != VAR_UNKNOWN {
		before := C.int(tv_get_number_chk_e(a2, &error))
		if error {
			cleanup_needed = true
		} else if before == tv_list_len_o(l1) {
			item = nil
		} else {
			item = tv_list_find_e(l1, before)
			if item == nil {
				semsg(cstring(E684_S), C.longlong(before))
				cleanup_needed = true
			}
		}
	}
	if !cleanup_needed {
		tv_list_extend_e(l1, l2, item)
		if is_new {
			rettv^ = Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = l1}
		} else {
			tv_copy_e(a0, rettv)
		}
		return
	}
	if is_new {
		tv_list_unref_e(l1)
	}
}

// "extend()" or "extendnew()" function.
extend_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring, is_new: bool) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if a0.v_type == VAR_LIST && a1.v_type == VAR_LIST {
		extend_list_o(argvars, arg_errmsg, is_new, rettv)
	} else if a0.v_type == VAR_DICT && a1.v_type == VAR_DICT {
		extend_dict_o(argvars, arg_errmsg, is_new, rettv)
	} else {
		if is_new {
			semsg(cstring(E_LISTDICTARG_S), cstring("extendnew()"))
		} else {
			semsg(cstring(E_LISTDICTARG_S), cstring("extend()"))
		}
	}
}

// "extend(list, list [, idx])" / "extend(dict, dict [, action])" function.
@(export)
f_extend :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	extend_o(argvars, rettv, cstring("extend() argument"), false)
}

// "extendnew(list, list [, idx])" / "extendnew(dict, dict [, action])" function.
@(export)
f_extendnew :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	extend_o(argvars, rettv, cstring("extendnew() argument"), true)
}

// "insert()" function.
@(export)
f_insert :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	error := false
	if a0.v_type == VAR_BLOB {
		b := (rawptr)(a0.vval)
		if b == nil ||
			value_check_lock_e((^C.int)(uintptr(b) + 28)^, cstring("insert() argument"), max(C.size_t)) {
			return
		}
		before: C.int = 0
		blen := tv_blob_len_o(b)
		if a2.v_type != VAR_UNKNOWN {
			before = C.int(tv_get_number_chk_e(a2, &error))
			if error {
				return
			}
			if before < 0 || before > blen {
				semsg(e_invarg2, tv_get_string_e(a2))
				return
			}
		}
		val := C.int(tv_get_number_chk_e(a1, &error))
		if error {
			return
		}
		if val < 0 || val > 255 {
			semsg(e_invarg2, tv_get_string_e(a1))
			return
		}
		ga_grow_r((^Garray)(b), 1)
		p := (^rawptr)(uintptr(b) + 16)^
		libc.memmove(rawptr(uintptr(p) + uintptr(before) + 1), rawptr(uintptr(p) + uintptr(before)), C.size_t(blen - before))
		([^]u8)(p)[uintptr(before)] = u8(val)
		(^C.int)(b)^ = blen + 1
		tv_copy_e(a0, rettv)
	} else if a0.v_type != VAR_LIST {
		semsg(cstring(E_LISTBLOBARG_S), cstring("insert()"))
	} else {
		l := (rawptr)(a0.vval)
		if value_check_lock_e(tv_list_locked_o(l), cstring("insert() argument"), max(C.size_t)) {
			return
		}
		before: C.longlong = 0
		if a2.v_type != VAR_UNKNOWN {
			before = tv_get_number_chk_e(a2, &error)
		}
		if error {
			return
		}
		item: rawptr = nil
		if before != C.longlong(tv_list_len_o(l)) {
			item = tv_list_find_e(l, C.int(before))
			if item == nil {
				semsg(cstring(E684_S), before)
				l = nil
			}
		}
		if l != nil {
			tv_list_insert_tv_e(l, a1, item)
			tv_copy_e(a0, rettv)
		}
	}
}

// "remove()" function.
@(export)
f_remove :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	arg_errmsg := cstring("remove() argument")
	if a0.v_type == VAR_DICT {
		tv_dict_remove_e(argvars, rettv, arg_errmsg)
	} else if a0.v_type == VAR_BLOB {
		tv_blob_remove_e(argvars, rettv, arg_errmsg)
	} else if a0.v_type == VAR_LIST {
		tv_list_remove_e(argvars, rettv, arg_errmsg)
	} else {
		semsg(cstring(E_LISTDICTBLOBARG_S), cstring("remove()"))
	}
}
