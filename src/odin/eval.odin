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
		tv_list_extend(l1, l2, nil)
	}
	return OK_E
}

// Handle number operations: nr += nr, nr -= nr, nr *= nr, nr /= nr, nr %= nr.
tv_op_number_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: cstring) -> C.int {
	context = runtime.default_context()
	n := tv_get_number(tv1)
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
			n += tv_get_number(tv2)
		} else if o == '-' {
			n -= tv_get_number(tv2)
		} else if o == '*' {
			n *= tv_get_number(tv2)
		} else if o == '/' {
			n = num_divide_e(n, tv_get_number(tv2))
		} else if o == '%' {
			n = num_modulus_e(n, tv_get_number(tv2))
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
	s2 := tv_get_string_buf(tv2, &numbuf[0])
	if grow_string_tv_e(tv1, s2) == OK_E {
		return OK_E
	}
	tvs := tv_get_string(tv1)
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
		f = f64(tv_get_number(tv2))
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
	@(link_name = "ga_append")
	ga_append_e :: proc "c" (gap: ^Garray, c: u8) ---
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
			argv[i] = transmute(rawptr)(xstrdup_o(transmute(^u8)(tv_get_string(transmute(^Typval_T)(&li.li_tv)))))
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
		a1_vval^ = tv_dict_alloc()
	}
	if a1_type^ != VAR_DICT {
		semsg(e_invarg2, cstring("expected dictionary"))
		return
	}
	tv_dict_add_bool(a1_vval^, cstring("term"), 4, 1)
	f_jobstart_e(argvars, rettv, fptr)
	if must_free {
		tv_dict_free(a1_vval^)
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
		if !value_check_lock(tv_list_locked_o(l), cstring("add() argument"), max(C.size_t)) {
			tv_list_append_tv(l, a1)
			tv_copy(a0, rettv)
		}
	} else if a0.v_type == VAR_BLOB {
		b := (rawptr)(a0.vval)
		if b != nil && !value_check_lock((^C.int)(uintptr(b) + 28)^, cstring("add() argument"), max(C.size_t)) {
			error := false
			n := tv_get_number_chk(a1, &error)
			if !error {
				ga_append_e((^Garray)(b), u8(n))
				tv_copy(a0, rettv)
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
	if tv_check_for_string_or_list_or_blob_arg(argvars, 0) == FAIL_E {
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
		if !value_check_lock(tv_list_locked_o(l), cstring("reverse() argument"), max(C.size_t)) {
			tv_list_reverse(l)
			tv_list_set_ret_o(rettv, l)
		}
	}
}

// —— Batch 5: eval/list.c f_count + count_* ——
foreign _ {
	@(link_name = "tv_list_find")
	tv_list_find_e :: proc "c" (l: rawptr, n: C.int) -> rawptr ---
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
		if tv_equal((^Typval_T)(uintptr(li) + 16), needle, ic) {
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
		if tv_equal((^Typval_T)(uintptr(key) - 17), needle, ic) {
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
		ic = C.int(tv_get_number_chk(a2, &error))
	}
	if !error && a0.v_type == VAR_STRING {
		n = count_string_o(transmute(cstring)((rawptr)(a0.vval)), tv_get_string_chk(a1), ic != 0)
	} else if !error && a0.v_type == VAR_LIST {
		idx: C.longlong = 0
		if a2.v_type != VAR_UNKNOWN && a3.v_type != VAR_UNKNOWN {
			idx = tv_get_number_chk(a3, &error)
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
	@(link_name = "tv_blob_copy")
	tv_blob_copy_e :: proc "c" (from: rawptr, to: ^Typval_T) ---
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
	tv_copy(tv, get_vim_var_tv_e(VV_VAL_O))
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
				remp^ = tv_get_number_chk(newtv, &err) == 0
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
		if value_check_lock(di_tv.v_lock, s.arg_errmsg, max(C.size_t)) ||
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
		r2 := tv_dict_add_tv(s.d_ret, key, C.size_t(libc.strlen(key)), &newtv)
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
		tv_dict_item_remove(s.d, di)
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
			value_check_lock((^C.int)(d)^, arg_errmsg, max(C.size_t))) {
		return
	}
	d_ret: rawptr = nil
	if filtermap == FILTERMAP_MAPNEW_O {
		tv_dict_alloc_ret(transmute(^Typval_T)(rettv))
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
			value_check_lock((^C.int)(uintptr(b) + 28)^, arg_errmsg, max(C.size_t))) {
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
			value_check_lock(tv_list_locked_o(l), arg_errmsg, max(C.size_t))) {
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
		if filtermap == FILTERMAP_MAP_O && value_check_lock(item.v_lock, arg_errmsg, max(C.size_t)) {
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
			tv_list_append_owned_tv(l_ret, newtv)
		}
		if filtermap == FILTERMAP_FILTER_O && rem {
			li = tv_list_item_remove(l, li)
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
		tv_copy(a0, rettv)
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
		filter_map_string_o(tv_get_string(a0), filtermap, expr, rettv)
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
	@(link_name = "get_copyID")
	get_copyID_e :: proc "c" () -> C.int ---
	@(link_name = "tv_blob_remove")
	tv_blob_remove_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) ---
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
		locked := value_check_lock(VAR_FIXED_O, arg_errmsg, max(C.size_t))
		if !locked {
			libc.abort()
		}
		return
	}
	d2 := (rawptr)(a1.vval)
	if d2 == nil {
		tv_copy(a0, rettv)
		return
	}
	if !is_new && value_check_lock((^C.int)(d1)^, arg_errmsg, max(C.size_t)) {
		return
	}
	if is_new {
		d1 = tv_dict_copy(nil, d1, false, get_copyID_e())
		if d1 == nil {
			return
		}
	}
	action := cstring("force")
	if a2.v_type != VAR_UNKNOWN {
		action = tv_get_string_chk(a2)
		if action == nil {
			if is_new {
				tv_dict_unref(d1)
			}
			return
		}
		if libc.strcmp(action, cstring("keep")) != 0 && libc.strcmp(action, cstring("force")) != 0 && libc.strcmp(action, cstring("error")) != 0 {
			if is_new {
				tv_dict_unref(d1)
			}
			semsg(e_invarg2, action)
			return
		}
	}
	tv_dict_extend(d1, d2, action)
	if is_new {
		rettv^ = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = d1}
	} else {
		tv_copy(a0, rettv)
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
	if !is_new && value_check_lock(tv_list_locked_o(l1), arg_errmsg, max(C.size_t)) {
		return
	}
	if is_new {
		l1 = tv_list_copy(nil, l1, false, get_copyID_e())
		if l1 == nil {
			return
		}
	}
	item: rawptr = nil
	cleanup_needed := false
	if a2.v_type != VAR_UNKNOWN {
		before := C.int(tv_get_number_chk(a2, &error))
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
		tv_list_extend(l1, l2, item)
		if is_new {
			rettv^ = Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = l1}
		} else {
			tv_copy(a0, rettv)
		}
		return
	}
	if is_new {
		tv_list_unref(l1)
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
			value_check_lock((^C.int)(uintptr(b) + 28)^, cstring("insert() argument"), max(C.size_t)) {
			return
		}
		before: C.int = 0
		blen := tv_blob_len_o(b)
		if a2.v_type != VAR_UNKNOWN {
			before = C.int(tv_get_number_chk(a2, &error))
			if error {
				return
			}
			if before < 0 || before > blen {
				semsg(e_invarg2, tv_get_string(a2))
				return
			}
		}
		val := C.int(tv_get_number_chk(a1, &error))
		if error {
			return
		}
		if val < 0 || val > 255 {
			semsg(e_invarg2, tv_get_string(a1))
			return
		}
		ga_grow_r((^Garray)(b), 1)
		p := (^rawptr)(uintptr(b) + 16)^
		libc.memmove(rawptr(uintptr(p) + uintptr(before) + 1), rawptr(uintptr(p) + uintptr(before)), C.size_t(blen - before))
		([^]u8)(p)[uintptr(before)] = u8(val)
		(^C.int)(b)^ = blen + 1
		tv_copy(a0, rettv)
	} else if a0.v_type != VAR_LIST {
		semsg(cstring(E_LISTBLOBARG_S), cstring("insert()"))
	} else {
		l := (rawptr)(a0.vval)
		if value_check_lock(tv_list_locked_o(l), cstring("insert() argument"), max(C.size_t)) {
			return
		}
		before: C.longlong = 0
		if a2.v_type != VAR_UNKNOWN {
			before = tv_get_number_chk(a2, &error)
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
			tv_list_insert_tv(l, a1, item)
			tv_copy(a0, rettv)
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
		tv_dict_remove(argvars, rettv, arg_errmsg)
	} else if a0.v_type == VAR_BLOB {
		tv_blob_remove_e(argvars, rettv, arg_errmsg)
	} else if a0.v_type == VAR_LIST {
		tv_list_remove(argvars, rettv, arg_errmsg)
	} else {
		semsg(cstring(E_LISTDICTBLOBARG_S), cstring("remove()"))
	}
}

// —— Batch 8: eval/buffer.c find leaves ——
foreign _ {
	@(link_name = "tv_get_buf")
	tv_get_buf_e :: proc "c" (tv: ^Typval_T, curtab_only: C.int) -> rawptr ---
	@(link_name = "tv_get_buf_from_arg")
	tv_get_buf_from_arg_e :: proc "c" (tv: ^Typval_T) -> rawptr ---
	@(link_name = "get_buf_arg")
	get_buf_arg_e :: proc "c" (arg: ^Typval_T) -> rawptr ---
	@(link_name = "buf_ensure_loaded")
	buf_ensure_loaded_e :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "tv_check_str_or_nr")
	tv_check_str_or_nr_e :: proc "c" (tv: ^Typval_T) -> bool ---
	@(link_name = "path_with_url")
	path_with_url_e :: proc "c" (fname: cstring) -> C.int ---
}

SEA_READONLY_O :: 4

// Find a buffer by number or exact name.
@(export)
find_buffer :: proc "c" (avar: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	if avar.v_type == VAR_NUMBER {
		return buflist_findnr(C.int(transmute(C.longlong)(avar.vval)))
	} else if avar.v_type == VAR_STRING && (^rawptr)(avar.vval) != nil {
		s := transmute(cstring)((rawptr)(avar.vval))
		buf := buflist_findname_exp(s)
		if buf == nil {
			bp := firstbuf
			for bp != nil {
				fname := (^rawptr)(uintptr(bp) + B_FNAME)^
				if fname != nil &&
					(path_with_url_e(transmute(cstring)(fname)) != 0 || bt_nofilename(bp)) &&
					libc.strcmp(transmute(cstring)(fname), s) == 0 {
					buf = bp
					break
				}
				bp = (^rawptr)(uintptr(bp) + B_NEXT)^
			}
		}
		return buf
	}
	return nil
}

// "bufadd(expr)" function.
@(export)
f_bufadd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	name := tv_get_string(a0)
	empty := (^u8)(rawptr(name))^ == 0
	rettv.vval = transmute(rawptr)(C.longlong(buflist_add(empty ? nil : name, 0)))
}

// "bufexists(expr)" function.
@(export)
f_bufexists :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.vval = transmute(rawptr)(C.longlong(find_buffer(a0) != nil ? 1 : 0))
}

// "buflisted(expr)" function.
@(export)
f_buflisted :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	buf := find_buffer(a0)
	rettv.vval = transmute(rawptr)(C.longlong(buf != nil && (^bool)(uintptr(buf) + B_P_BL_OFF)^ ? 1 : 0))
}

// "bufload(expr)" function.
@(export)
f_bufload :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	buf := get_buf_arg_e(a0)
	if buf != nil {
		if swap_exists_action_g != SEA_READONLY_O {
			swap_exists_action_g = SEA_NONE_O
		}
		buf_ensure_loaded_e(buf)
	}
}

// "bufloaded(expr)" function.
@(export)
f_bufloaded :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	buf := find_buffer(a0)
	rettv.vval = transmute(rawptr)(C.longlong(buf != nil && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil ? 1 : 0))
}

// "bufname(expr)" function.
@(export)
f_bufname :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	buf: rawptr
	if a0.v_type == VAR_UNKNOWN {
		buf = curbuf
	} else {
		buf = tv_get_buf_from_arg_e(a0)
	}
	if buf != nil {
		fname := (^rawptr)(uintptr(buf) + B_FNAME)^
		if fname != nil {
			rettv.vval = transmute(rawptr)(xstrdup_o((^u8)(fname)))
		}
	}
}

// "bufnr(expr)" function.
@(export)
f_bufnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	error := false
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	buf: rawptr
	if a0.v_type == VAR_UNKNOWN {
		buf = curbuf
	} else {
		if !tv_check_str_or_nr_e(a0) {
			return
		}
		emsg_off += 1
		buf = tv_get_buf_e(a0, 0)
		emsg_off -= 1
	}
	name: cstring = nil
	if buf == nil && a1.v_type != VAR_UNKNOWN && tv_get_number_chk(a1, &error) != 0 && !error {
		name = tv_get_string_chk(a0)
	}
	if name != nil {
		buf = buflist_new(name, nil, 1, 0)
	}
	if buf != nil {
		rettv.vval = transmute(rawptr)(C.longlong((^C.int)(buf)^))
	}
}

// —— Batch 9: eval/buffer.c window lookup + line getters ——
// (win_has_winnr_e FFI removed: win_has_winnr is now an Odin export in Batch 12.)

KLISTLEN_MAYKNOW_O :: -3

// Shared body of bufwinid()/bufwinnr().
buf_win_common_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, get_nr: bool) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	buf := tv_get_buf_from_arg_e(a0)
	if buf == nil {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
		return
	}
	winnr: C.int = 0
	winid: C.int = 0
	found_buf := false
	// FOR_ALL_WINDOWS_IN_TAB with tp=curtab (always firstwin here).
	wp := firstwin
	for wp != nil {
		if win_has_winnr(wp, curtab) {
			winnr += 1
		}
		if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
			(!get_nr || win_has_winnr(wp, curtab)) {
			found_buf = true
			winid = (^C.int)(uintptr(wp) + W_HANDLE_OFF)^
			break
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	v: C.longlong = -1
	if found_buf {
		if get_nr {
			v = C.longlong(winnr)
		} else {
			v = C.longlong(winid)
		}
	}
	rettv.vval = transmute(rawptr)(v)
}

// "bufwinid(nr)" function.
@(export)
f_bufwinid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf_win_common_o(argvars, rettv, false)
}

// "bufwinnr(nr)" function.
@(export)
f_bufwinnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf_win_common_o(argvars, rettv, true)
}

// Get line or list of lines from buffer "buf" into "rettv".
get_buffer_lines_o :: proc "c" (buf: rawptr, start: C.int, end: C.int, retlist: bool, rettv: ^Typval_T) {
	context = runtime.default_context()
	rettv.v_type = retlist ? VAR_LIST : VAR_STRING
	rettv.vval = nil
	if buf == nil || (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil || start < 0 || end < start {
		if retlist {
			tv_list_alloc_ret(transmute(^Typval)(rettv), 0)
		}
		return
	}
	if retlist {
		s := start < 1 ? 1 : start
		e := end
		count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		if e > count {
			e = count
		}
		tv_list_alloc_ret(transmute(^Typval)(rettv), e - s + 1)
		for s <= e {
			tv_list_append_string((rawptr)(rettv.vval), ml_get_buf(buf, s), C.ssize_t(ml_get_buf_len(buf, s)))
			s += 1
		}
	} else {
		rettv.v_type = VAR_STRING
		count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		if start >= 1 && start <= count {
			rettv.vval = transmute(rawptr)(xstrnsave_c(transmute(cstring)(ml_get_buf(buf, start)), C.size_t(ml_get_buf_len(buf, start))))
		} else {
			rettv.vval = nil
		}
	}
}

// Shared body of getbufline()/getbufoneline().
getbufline_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, retlist: bool) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	lnum: C.int = 1
	end: C.int = 1
	did_emsg_before := did_emsg_flag
	buf := tv_get_buf_from_arg_e(a0)
	if buf != nil {
		lnum = tv_get_lnum_buf(a1, buf)
		if did_emsg_flag > did_emsg_before {
			return
		}
		if a2.v_type == VAR_UNKNOWN {
			end = lnum
		} else {
			end = tv_get_lnum_buf(a2, buf)
		}
	}
	get_buffer_lines_o(buf, lnum, end, retlist, rettv)
}

// "getbufline()" function.
@(export)
f_getbufline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getbufline_o(argvars, rettv, true)
}

// "getbufoneline()" function.
@(export)
f_getbufoneline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getbufline_o(argvars, rettv, false)
}

// "getline(lnum, [end])" function.
@(export)
f_getline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	lnum := tv_get_lnum(a0)
	end := lnum
	retlist := false
	if a1.v_type != VAR_UNKNOWN {
		end = tv_get_lnum(a1)
		retlist = true
	}
	get_buffer_lines_o(curbuf, lnum, end, retlist, rettv)
}

// —— Batch 10: eval/buffer.c set-lines engine ——
foreign _ {
	@(link_name = "typval_tostring")
	typval_tostring_e :: proc "c" (arg: ^Typval_T, quotes: bool) -> ^u8 ---
	@(link_name = "u_sync_once")
	u_sync_once_g: C.int
}

// change_other_buffer_prepare/restore context (cob_T): ptr + aco[56] + int + bool.
Cob_T :: struct {
	cob_curwin_save:      rawptr,
	cob_aco:              [56]u8,
	cob_using_aco:        C.int,
	cob_save_VIsual_active: bool,
}
#assert(size_of(Cob_T) == 72)

// Find a window for curbuf via its b_wininfo list.
find_win_for_curbuf_o :: proc "c" () {
	context = runtime.default_context()
	n := (^C.size_t)(uintptr(curbuf) + B_WINFOFF_SIZE)^
	items := (^rawptr)(uintptr(curbuf) + B_WINFOFF_ITEMS)^
	i: C.size_t = 0
	for i < n {
		wip := ([^]rawptr)(items)[i]
		wi_win := (^rawptr)(wip)^ // wi_win@0
		if wi_win != nil && (^rawptr)(uintptr(wi_win) + W_BUFFER_OFF)^ == curbuf {
			curwin = wi_win
			break
		}
		i += 1
	}
}

// Prepare to change "buf" (makes it current); MUST pair with restore below.
change_other_buffer_prepare_o :: proc "c" (cob: ^Cob_T, buf: rawptr) {
	context = runtime.default_context()
	cob^ = Cob_T{}
	cob.cob_save_VIsual_active = VIsual_active
	VIsual_active = false
	cob.cob_curwin_save = curwin
	curbuf = buf
	find_win_for_curbuf_o()
	if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ != buf {
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
		aucmd_prepbuf_r(transmute(rawptr)(&cob.cob_aco), buf)
		cob.cob_using_aco = 1
	}
}

change_other_buffer_restore_o :: proc "c" (cob: ^Cob_T) {
	context = runtime.default_context()
	if cob.cob_using_aco != 0 {
		aucmd_restbuf_r(transmute(rawptr)(&cob.cob_aco))
	} else {
		curwin = cob.cob_curwin_save
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	}
	VIsual_active = cob.cob_save_VIsual_active
}

// Set line or list of lines in buffer "buf" to "lines".
set_buffer_lines_o :: proc "c" (buf: rawptr, lnum_arg: C.int, append: bool, lines: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	lnum := lnum_arg + (append ? 1 : 0)
	added: C.int = 0
	is_curbuf := buf == curbuf
	if buf == nil || (!is_curbuf && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil) || lnum < 1 {
		rettv.vval = transmute(rawptr)(C.longlong(1)) // FAIL
		return
	}
	cob := Cob_T{}
	if !is_curbuf {
		change_other_buffer_prepare_o(&cob, buf)
	}
	append_lnum: C.int
	if append {
		append_lnum = lnum - 1
	} else {
		append_lnum = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	}
	l: rawptr = nil
	li: rawptr = nil
	line: ^u8 = nil
	if lines.v_type == VAR_LIST {
		l = (rawptr)(lines.vval)
		if l == nil || tv_list_len_o(l) == 0 {
			// not appending anything always succeeds
			if !is_curbuf {
				change_other_buffer_restore_o(&cob)
			}
			return
		}
		li = (^rawptr)(l)^ // lv_first@0
	} else {
		line = typval_tostring_e(lines, false)
	}
	// Default result is zero == OK (vval only, like C).
	for {
		if lines.v_type == VAR_LIST {
			if li == nil {
				break
			}
			xfree(transmute(rawptr)(line))
			line = typval_tostring_e(transmute(^Typval_T)(uintptr(li) + 16), false)
			li = (^rawptr)(li)^ // li_next@0
		}
		rettv.vval = transmute(rawptr)(C.longlong(1)) // FAIL
		count_now := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		if line == nil || lnum > count_now + 1 {
			break
		}
		if u_sync_once_g == 2 {
			u_sync_once_g = 1
			u_sync(true)
		}
		if !append && lnum <= count_now {
			old_len := C.int(libc.strlen(transmute(cstring)(ml_get(lnum))))
			if u_savesub(lnum) == OK_R && ml_replace_c(lnum, line, true) == OK_R {
				inserted_bytes_r(lnum, 0, old_len, C.int(libc.strlen(transmute(cstring)(line))))
				cur_lnum := (^C.int)(uintptr(curwin) + W_CURSOR)^
				if is_curbuf && lnum == cur_lnum {
					check_cursor_col_r(curwin)
				}
				rettv.vval = transmute(rawptr)(C.longlong(0)) // OK
			}
		} else if added > 0 || u_save(lnum - 1, lnum) == OK_R {
			added += 1
			if ml_append_c(lnum - 1, line, 0, false) {
				rettv.vval = transmute(rawptr)(C.longlong(0)) // OK
			}
		}
		if l == nil {
			break
		}
		lnum += 1
	}
	xfree(transmute(rawptr)(line))
	if added > 0 {
		appended_lines_mark_r(append_lnum, added)
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf &&
					((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf || wp == curwin) {
					wc_lnum := (^C.int)(uintptr(wp) + W_CURSOR)^
					if wc_lnum > append_lnum {
						(^C.int)(uintptr(wp) + W_CURSOR)^ = wc_lnum + added
					}
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		check_cursor_col_r(curwin)
		update_topline_r(curwin)
	}
	if !is_curbuf {
		change_other_buffer_restore_o(&cob)
	}
}

// "append(lnum, string/list)" function.
@(export)
f_append :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	did_emsg_before := did_emsg_flag
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	if did_emsg_flag == did_emsg_before {
		set_buffer_lines_o(curbuf, lnum, true, (^Typval_T)(uintptr(argvars) + 16), rettv)
	}
}

// Set or append lines to a buffer.
buf_set_append_line_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, append: bool) {
	context = runtime.default_context()
	did_emsg_before := did_emsg_flag
	buf := tv_get_buf_e((^Typval_T)(uintptr(argvars)), 0)
	if buf == nil {
		rettv.vval = transmute(rawptr)(C.longlong(1)) // FAIL
	} else {
		lnum := tv_get_lnum_buf((^Typval_T)(uintptr(argvars) + 16), buf)
		if did_emsg_flag == did_emsg_before {
			set_buffer_lines_o(buf, lnum, append, (^Typval_T)(uintptr(argvars) + 32), rettv)
		}
	}
}

// "appendbufline(buf, lnum, string/list)" function.
@(export)
f_appendbufline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf_set_append_line_o(argvars, rettv, true)
}

// "setbufline()" function.
@(export)
f_setbufline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf_set_append_line_o(argvars, rettv, false)
}

// "setline()" function.
@(export)
f_setline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	did_emsg_before := did_emsg_flag
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	if did_emsg_flag == did_emsg_before {
		set_buffer_lines_o(curbuf, lnum, false, (^Typval_T)(uintptr(argvars) + 16), rettv)
	}
}

// "deletebufline()" function.
@(export)
f_deletebufline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	did_emsg_before := did_emsg_flag
	rettv.vval = transmute(rawptr)(C.longlong(1)) // FAIL by default
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	buf := tv_get_buf_e(a0, 0)
	if buf == nil {
		return
	}
	last: C.int
	first := tv_get_lnum_buf(a1, buf)
	if did_emsg_flag > did_emsg_before {
		return
	}
	if a2.v_type != VAR_UNKNOWN {
		last = tv_get_lnum_buf(a2, buf)
	} else {
		last = first
	}
	count_now := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil || first < 1 || first > count_now || last < first {
		return
	}
	is_curbuf := buf == curbuf
	cob := Cob_T{}
	if !is_curbuf {
		change_other_buffer_prepare_o(&cob, buf)
	}
	last2 := last
	count2 := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	if last2 > count2 {
		last2 = count2
	}
	count := last2 - first + 1
	if u_sync_once_g == 2 {
		u_sync_once_g = 1
		u_sync(true)
	}
	ok := true
	if u_save(first - 1, last2 + 1) == FAIL_R {
		ok = false
	} else {
		ln := first
		for ln <= last2 {
			ml_delete_flags_r(first, ML_DEL_MESSAGE_O)
			ln += 1
		}
	}
	if ok {
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
					wc := (^C.int)(uintptr(wp) + W_CURSOR)^
					if wc > last2 {
						(^C.int)(uintptr(wp) + W_CURSOR)^ = wc - count
					} else if wc > first {
						(^C.int)(uintptr(wp) + W_CURSOR)^ = first
					}
					wc_now := (^C.int)(uintptr(wp) + W_CURSOR)^
					maxln := (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^
					if wc_now > maxln {
						(^C.int)(uintptr(wp) + W_CURSOR)^ = maxln
					}
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		check_cursor_col_r(curwin)
		deleted_lines_mark_r(first, count)
		rettv.vval = transmute(rawptr)(C.longlong(0)) // OK
	}
	if !is_curbuf {
		change_other_buffer_restore_o(&cob)
	}
}

// —— Batch 11: eval/buffer.c info/switch/prompt (closes buffer.c) ——
foreign _ {
	@(link_name = "tv_dict_find")
	tv_dict_find_e :: proc "c" (d: rawptr, key: cstring, key_len: C.ssize_t) -> rawptr ---
	@(link_name = "buf_has_signs")
	buf_has_signs_e :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "get_buffer_signs")
	get_buffer_signs_e :: proc "c" (buf: rawptr) -> rawptr ---
	@(link_name = "callback_from_typval")
	callback_from_typval_e :: proc "c" (callback: ^Callback_E, arg: ^Typval_T) -> bool ---
	@(link_name = "ml_replace_buf")
	ml_replace_buf_e :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, copy: bool, noalloc: bool) -> C.int ---
	@(link_name = "prompt_trim_scrollback")
	prompt_trim_scrollback_e :: proc "c" (buf: rawptr) ---
	@(link_name = "buf_prompt_text")
	buf_prompt_text_e :: proc "c" (buf: rawptr) -> ^u8 ---
	@(link_name = "strnequal")
	strnequal_e :: proc "c" (a: cstring, b: cstring, n: C.size_t) -> bool ---
}

// Buffer info dict for getbufinfo().
get_buffer_info_o :: proc "c" (buf: rawptr) -> rawptr {
	context = runtime.default_context()
	dict := tv_dict_alloc()
	tv_dict_add_nr(dict, cstring("bufnr"), 5, C.longlong((^C.int)(buf)^))
	ffname := (^rawptr)(uintptr(buf) + B_FFNAME)^
	if ffname != nil {
		tv_dict_add_str(dict, cstring("name"), 4, transmute(cstring)(ffname))
	} else {
		tv_dict_add_str(dict, cstring("name"), 4, cstring(""))
	}
	lnum: C.longlong
	if buf == curbuf {
		lnum = C.longlong((^C.int)(uintptr(curwin) + W_CURSOR)^)
	} else {
		lnum = C.longlong(buflist_findlnum(buf))
	}
	tv_dict_add_nr(dict, cstring("lnum"), 4, lnum)
	tv_dict_add_nr(dict, cstring("linecount"), 9, C.longlong((^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^))
	loaded := (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil
	tv_dict_add_nr(dict, cstring("loaded"), 6, loaded ? 1 : 0)
	tv_dict_add_nr(dict, cstring("listed"), 6, (^bool)(uintptr(buf) + B_P_BL_OFF)^ ? 1 : 0)
	tv_dict_add_nr(dict, cstring("changed"), 7, bufIsChanged(buf) ? 1 : 0)
	tv_dict_add_nr(dict, cstring("changedtick"), 11, buf_changedtick_inline(buf))
	hidden := loaded && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0
	tv_dict_add_nr(dict, cstring("hidden"), 6, hidden ? 1 : 0)
	tv_dict_add_nr(dict, cstring("command"), 7, bt_cmdwin(buf) ? 1 : 0)
	tv_dict_add_dict(dict, cstring("variables"), 9, (^rawptr)(uintptr(buf) + B_VARS_OFF)^)
	windows := tv_list_alloc(-3)
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				tv_list_append_number(windows, C.longlong((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	tv_dict_add_list(dict, cstring("windows"), 7, windows)
	if buf_has_signs_e(buf) {
		tv_dict_add_list(dict, cstring("signs"), 5, get_buffer_signs_e(buf))
	}
	tv_dict_add_nr(dict, cstring("lastused"), 8, C.longlong((^C.int)(uintptr(buf) + B_LAST_USED_OFF)^))
	return dict
}

// "getbufinfo()" function.
@(export)
f_getbufinfo :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	filtered := false
	sel_buflisted := false
	sel_bufloaded := false
	sel_bufmodified := false
	argbuf: rawptr = nil
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if a0.v_type == VAR_DICT {
		sel_d := (rawptr)(a0.vval)
		if sel_d != nil {
			filtered = true
			di := tv_dict_find_e(sel_d, cstring("buflisted"), 9)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_buflisted = true
			}
			di = tv_dict_find_e(sel_d, cstring("bufloaded"), 9)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_bufloaded = true
			}
			di = tv_dict_find_e(sel_d, cstring("bufmodified"), 11)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_bufmodified = true
			}
		}
	} else if a0.v_type != VAR_UNKNOWN {
		argbuf = tv_get_buf_from_arg_e(a0)
		if argbuf == nil {
			return
		}
	}
	buf := firstbuf
	for buf != nil {
		if argbuf != nil && argbuf != buf {
			buf = (^rawptr)(uintptr(buf) + B_NEXT)^
			continue
		}
		if filtered && ((sel_bufloaded && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil) ||
			(sel_buflisted && !(^bool)(uintptr(buf) + B_P_BL_OFF)^) ||
			(sel_bufmodified && !bufIsChanged(buf))) {
			buf = (^rawptr)(uintptr(buf) + B_NEXT)^
			continue
		}
		d := get_buffer_info_o(buf)
		tv_list_append_dict((rawptr)(rettv.vval), d)
		if argbuf != nil {
			return
		}
		buf = (^rawptr)(uintptr(buf) + B_NEXT)^
	}
}

// Make "buf" the current buffer (restore_buffer MUST undo; no autocommands).
@(export)
switch_buffer :: proc "c" (save_curbuf: ^Bufref_T, buf: rawptr) {
	context = runtime.default_context()
	block_autocmds_r()
	set_bufref(save_curbuf, curbuf)
	(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ -= 1
	curbuf = buf
	(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = buf
	(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ += 1
}

// Restore the current buffer after switch_buffer().
@(export)
restore_buffer :: proc "c" (save_curbuf: ^Bufref_T) {
	context = runtime.default_context()
	unblock_autocmds_r()
	if bufref_valid(save_curbuf) {
		(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ -= 1
		(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = save_curbuf.br_buf
		curbuf = save_curbuf.br_buf
		(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ += 1
	}
}

// "prompt_setcallback({buffer}, {callback})" function.
@(export)
f_prompt_setcallback :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	prompt_callback := Callback_E{}
	if check_secure() {
		return
	}
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	buf := tv_get_buf_e(a0, 0)
	if buf == nil {
		return
	}
	if !callback_from_typval_e(&prompt_callback, a1) {
		return
	}
	callback_free((^Callback_E)(rawptr(uintptr(buf) + B_PROMPT_CB_OFF)))
	(^Callback_E)(uintptr(buf) + B_PROMPT_CB_OFF)^ = prompt_callback
}

// "prompt_setinterrupt({buffer}, {callback})" function.
@(export)
f_prompt_setinterrupt :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	interrupt_callback := Callback_E{}
	if check_secure() {
		return
	}
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	buf := tv_get_buf_e(a0, 0)
	if buf == nil {
		return
	}
	if !callback_from_typval_e(&interrupt_callback, a1) {
		return
	}
	callback_free((^Callback_E)(rawptr(uintptr(buf) + B_PROMPT_INT_OFF)))
	(^Callback_E)(uintptr(buf) + B_PROMPT_INT_OFF)^ = interrupt_callback
}

// "prompt_setprompt({buffer}, {text})" function.
@(export)
f_prompt_setprompt :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	buf := tv_get_buf_e(a0, 0)
	if buf == nil {
		return
	}
	new_prompt := tv_get_string(a1)
	new_prompt_len := C.int(libc.strlen(new_prompt))
	if bt_prompt(buf) && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil {
		prompt_lno := (^C.int)(uintptr(buf) + B_PROMPT_START)^
		count_now := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		fixed := prompt_lno
		if fixed < 1 {
			fixed = 1
		}
		if fixed > count_now {
			fixed = count_now
		}
		if prompt_lno < 1 || prompt_lno > count_now {
			(^C.int)(uintptr(buf) + B_PROMPT_START)^ = fixed
			(^bool)(uintptr(curbuf) + B_PROMPT_APPEND_OFF)^ = true
			prompt_lno = fixed
		}
		old_prompt := buf_prompt_text_e(buf)
		old_line := ml_get_buf(buf, prompt_lno)
		old_line_len := ml_get_buf_len(buf, prompt_lno)
		old_prompt_len := C.int(libc.strlen(transmute(cstring)(old_prompt)))
		cursor_col := (^C.int)(uintptr(curwin) + W_CURSOR + 4)^
		prompt_col := (^C.int)(uintptr(buf) + B_PROMPT_START + 4)^
		if prompt_col < old_prompt_len || prompt_col > old_line_len ||
			!strnequal_e(transmute(cstring)(old_prompt), transmute(cstring)(rawptr(uintptr(old_line) + uintptr(prompt_col) - uintptr(old_prompt_len))), C.size_t(old_prompt_len)) {
			ml_replace_buf_e(buf, prompt_lno, transmute(^u8)(new_prompt), true, false)
			extmark_splice_cols_r(buf, prompt_lno - 1, 0, old_line_len, new_prompt_len, KEXTMARK_NO_UNDO_O)
			cursor_col = new_prompt_len
		} else {
			new_line := concat_str_c(transmute(cstring)(new_prompt), transmute(cstring)(rawptr(uintptr(old_line) + uintptr(prompt_col))))
			if ml_replace_buf_e(buf, prompt_lno, new_line, false, false) != OK_R {
				xfree(transmute(rawptr)(new_line))
			}
			extmark_splice_cols_r(buf, prompt_lno - 1, 0, prompt_col, new_prompt_len, KEXTMARK_NO_UNDO_O)
			cursor_col += new_prompt_len - prompt_col
		}
		if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(curwin) + W_CURSOR)^ == prompt_lno {
			(^C.int)(uintptr(curwin) + W_CURSOR + 4)^ = cursor_col
			check_cursor_col_r(curwin)
		}
		changed_lines_r(buf, prompt_lno, 0, prompt_lno + 1, 0, true)
		u_clearallandblockfree(buf)
	}
	xfree((^rawptr)(uintptr(buf) + B_PROMPT_TEXT_OFF)^)
	(^rawptr)(uintptr(buf) + B_PROMPT_TEXT_OFF)^ = transmute(rawptr)(xstrdup_o(transmute(^u8)(new_prompt)))
	(^C.int)(uintptr(buf) + B_PROMPT_START + 4)^ = new_prompt_len
}

// "prompt_appendbuf({buffer}, string/list)" function.
@(export)
f_prompt_appendbuf :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	did_emsg_before := did_emsg_flag
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(1))
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	buf := tv_get_buf_from_arg_e(a0)
	if buf == nil || !bt_prompt(buf) {
		return
	}
	lnum := (^C.int)(uintptr(buf) + B_PROMPT_START)^
	if lnum < 0 {
		lnum = 0
	}
	lines := a1
	did_concat := false
	if !(^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^ {
		text := lnum > 0 ? transmute(cstring)(ml_get_buf(buf, lnum)) : cstring("")
		if lines.v_type == VAR_LIST {
			l := (rawptr)(lines.vval)
			if l != nil && tv_list_len_o(l) > 0 {
				li := (^rawptr)(l)^
				str := tv_get_string(transmute(^Typval_T)(uintptr(li) + 16))
				new_str := concat_str_c(text, str)
				item := transmute(^Typval_T)(uintptr(li) + 16)
				tv_clear_e(item)
				item.v_type = VAR_STRING
				item.vval = transmute(rawptr)(new_str)
				did_concat = true
			}
		} else if lines.v_type == VAR_STRING {
			str := tv_get_string(lines)
			new_str := concat_str_c(text, str)
			tv_clear_e(lines)
			lines.v_type = VAR_STRING
			lines.vval = transmute(rawptr)(new_str)
		}
	}
	if did_emsg_flag == did_emsg_before {
		if did_concat && tv_list_len_o((rawptr)(lines.vval)) > 1 {
			l := (rawptr)(lines.vval)
			li := (^rawptr)(l)^
			set_buffer_lines_o(buf, lnum, false, transmute(^Typval_T)(uintptr(li) + 16), rettv)
			if transmute(C.longlong)(rettv.vval) == 0 {
				tv_list_item_remove(l, li)
				set_buffer_lines_o(buf, lnum, true, lines, rettv)
			}
		} else {
			set_buffer_lines_o(buf, lnum, (^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^, lines, rettv)
		}
	}
	if transmute(C.longlong)(rettv.vval) == 0 {
		(^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^ = false
		if lines.v_type == VAR_LIST {
			l := (rawptr)(lines.vval)
			if l != nil && tv_list_len_o(l) > 0 {
				li: rawptr = nil
				it := (^rawptr)(l)^
				for it != nil {
					li = it
					it = (^rawptr)(it)^
				}
				str := tv_get_string(transmute(^Typval_T)(uintptr(li) + 16))
				ln := libc.strlen(str)
				if ln > 0 && ([^]u8)(rawptr(str))[uintptr(ln) - 1] == '\n' {
					(^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^ = true
				}
			}
		} else if lines.v_type == VAR_STRING {
			str := tv_get_string(lines)
			ln := libc.strlen(str)
			if ln > 0 && ([^]u8)(rawptr(str))[uintptr(ln) - 1] == '\n' {
				(^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^ = true
			}
		}
		prompt_trim_scrollback_e(buf)
	}
}

// —— Batch 12: eval/window.c id/find leaves ——
LOWEST_WIN_ID_O :: 1000

// Whether window has a winnr (not a floating/unfocusable helper).
@(export)
win_has_winnr :: proc "c" (wp: rawptr, tp: rawptr) -> bool {
	context = runtime.default_context()
	cur: rawptr
	if tp == curtab {
		cur = curwin
	} else {
		cur = (^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^
	}
	if wp == cur {
		return true
	}
	wcfg := uintptr(wp) + W_CONFIG_OFF
	return !(^bool)(wcfg + WCFG_REL_HIDE)^ && (^bool)(wcfg + WCFG_REL_FOCUSABLE)^
}

// Get window id from winnr/tabnr args.
win_getid_o :: proc "c" (argvars: ^Typval_T) -> C.int {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if a0.v_type == VAR_UNKNOWN {
		return (^C.int)(curwin)^ // handle@0
	}
	winnr := C.int(tv_get_number(a0))
	if winnr <= 0 {
		return 0
	}
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	tp: rawptr
	wp: rawptr
	if a1.v_type == VAR_UNKNOWN {
		tp = curtab
		wp = firstwin
	} else {
		tabnr := C.int(tv_get_number(a1))
		tp = nil
		tp2 := first_tabpage
		for tp2 != nil {
			tabnr -= 1
			if tabnr == 0 {
				tp = tp2
				break
			}
			tp2 = (^rawptr)(uintptr(tp2) + TP_NEXT_OFF)^
		}
		if tp == nil {
			return -1
		}
		if tp == curtab {
			wp = firstwin
		} else {
			wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		}
	}
	for wp != nil {
		if win_has_winnr(wp, tp) {
			winnr -= 1
		}
		if winnr == 0 {
			return (^C.int)(wp)^ // handle@0
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return 0
}

// Convert window id to [tabnr, winnr] in rettv.
win_id2tabwin_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	id := C.int(tv_get_number(a0))
	tabnr: C.int = 1
	winnr: C.int = 1
	win_get_tabwin(id, &tabnr, &winnr)
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	tv_list_append_number((rawptr)(rettv.vval), C.longlong(tabnr))
	tv_list_append_number((rawptr)(rettv.vval), C.longlong(winnr))
}

// Find window by id across all tabs (sets tpp).
@(export)
win_id2wp_tp :: proc "c" (id: C.int, tpp: ^rawptr) -> rawptr {
	context = runtime.default_context()
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^C.int)(wp)^ == id {
				if tpp != nil {
					tpp^ = tp
				}
				return wp
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	return nil
}

// Find window by id across all tabs.
@(export)
win_id2wp :: proc "c" (id: C.int) -> rawptr {
	context = runtime.default_context()
	return win_id2wp_tp(id, nil)
}

// Get winnr of window id in current tab.
win_id2win_o :: proc "c" (argvars: ^Typval_T) -> C.int {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	nr: C.int = 1
	id := C.int(tv_get_number(a0))
	wp := firstwin
	for wp != nil {
		if (^C.int)(wp)^ == id {
			if win_has_winnr(wp, curtab) {
				return nr
			}
			return 0
		}
		if win_has_winnr(wp, curtab) {
			nr += 1
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return 0
}

// Find window by number (or id if >= LOWEST_WIN_ID) in tabpage tp.
@(export)
find_win_by_nr :: proc "c" (vp: ^Typval_T, tp: rawptr) -> rawptr {
	context = runtime.default_context()
	nr := C.int(tv_get_number_chk(vp, nil))
	if nr < 0 {
		return nil
	}
	if nr == 0 {
		return curwin
	}
	tpl := tp
	if tpl == nil {
		tpl = curtab
	}
	// FOR_ALL_WINDOWS_IN_TAB with tpl.
	wp := tpl == curtab ? firstwin : (^rawptr)(uintptr(tpl) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if nr >= LOWEST_WIN_ID_O {
			if (^C.int)(wp)^ == nr {
				return wp
			}
		} else if nr - 1 <= 0 {
			nr -= 1
			return wp
		} else {
			nr -= 1
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return nil
}

// Find window by number, or by id if >= LOWEST_WIN_ID.
@(export)
find_win_by_nr_or_id :: proc "c" (vp: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	nr := C.int(tv_get_number_chk(vp, nil))
	if nr >= LOWEST_WIN_ID_O {
		return win_id2wp(C.int(tv_get_number(vp)))
	}
	return find_win_by_nr(vp, nil)
}

// Find window specified by wvp/tvp args.
@(export)
find_tabwin :: proc "c" (wvp: ^Typval_T, tvp: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	if wvp.v_type != VAR_UNKNOWN {
		tp: rawptr = nil
		if tvp.v_type != VAR_UNKNOWN {
			n := C.int(tv_get_number(tvp))
			if n >= 0 {
				tp = find_tabpage(n)
			}
		} else {
			tp = curtab
		}
		if tp != nil {
			return find_win_by_nr(wvp, tp)
		}
		return nil
	}
	return curwin
}

// Collect window handles showing bufnr into list.
@(export)
win_findbuf :: proc "c" (argvars: ^Typval_T, list: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	bufnr := C.int(tv_get_number(a0))
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNUM_OFF)^ == bufnr {
				tv_list_append_number(list, C.longlong((^C.int)(wp)^))
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// "win_getid()" function.
@(export)
f_win_getid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(win_getid_o(argvars)))
}

// "win_gotoid()" function.
@(export)
f_win_gotoid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	id := C.int(tv_get_number(a0))
	if (^C.int)(curwin)^ == id {
		rettv.vval = transmute(rawptr)(C.longlong(1))
		return
	}
	if text_or_buf_locked_r() {
		return
	}
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^C.int)(wp)^ == id {
				if VIsual_active && (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
					end_visual_mode_r()
				}
				goto_tabpage_win(tp, wp)
				rettv.vval = transmute(rawptr)(C.longlong(1))
				return
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// "win_id2tabwin()" function.
@(export)
f_win_id2tabwin :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	win_id2tabwin_o(argvars, rettv)
}

// "win_id2win()" function.
@(export)
f_win_id2win :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(win_id2win_o(argvars)))
}

// "winbufnr(nr)" function.
@(export)
f_winbufnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	wp := find_win_by_nr_or_id(a0)
	if wp == nil {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNUM_OFF)^))
	}
}

// —— Batch 13: eval/window.c winnr/view/layout/dimensions ——
foreign _ {
	@(link_name = "tabpage_index")
	tabpage_index_e :: proc "c" (ftp: rawptr) -> C.int ---
	@(link_name = "set_topline")
	set_topline_e :: proc "c" (wp: rawptr, lnum: C.int) ---
	@(link_name = "check_topfill")
	check_topfill_e :: proc "c" (wp: rawptr, down: bool) ---
}

E15_S :: "E15: Invalid expression: \"%s\""

// Common code for tabpagewinnr() and winnr().
get_winnr_o :: proc "c" (tp: rawptr, argvar: ^Typval_T) -> C.int {
	context = runtime.default_context()
	nr: C.int = 1
	twin := tp == curtab ? curwin : (^rawptr)(uintptr(tp) + TP_CURWIN_OFF)^
	if argvar.v_type != VAR_UNKNOWN {
		invalid_arg := false
		arg := tv_get_string_chk(argvar)
		if arg == nil {
			nr = 0
		} else if libc.strcmp(arg, cstring("$")) == 0 {
			if tp == curtab {
				twin = lastwin_g
			} else {
				twin = (^rawptr)(uintptr(tp) + TP_LASTWIN_OFF)^
			}
		} else if libc.strcmp(arg, cstring("#")) == 0 {
			if tp == curtab {
				twin = prevwin_g
			} else {
				twin = (^rawptr)(uintptr(tp) + TP_PREVWIN_OFF)^
			}
			if twin == nil {
				nr = 0
			}
		} else {
			endp := (^u8)(rawptr(arg))
			count := getdigits_int(&endp, false, 0)
			if count <= 0 {
				count = 1
			}
			if endp != nil && endp^ != 0 {
				if libc.strcmp(transmute(cstring)(endp), cstring("j")) == 0 {
					twin = win_vert_neighbor(tp, twin, false, count)
				} else if libc.strcmp(transmute(cstring)(endp), cstring("k")) == 0 {
					twin = win_vert_neighbor(tp, twin, true, count)
				} else if libc.strcmp(transmute(cstring)(endp), cstring("h")) == 0 {
					twin = win_horz_neighbor(tp, twin, true, count)
				} else if libc.strcmp(transmute(cstring)(endp), cstring("l")) == 0 {
					twin = win_horz_neighbor(tp, twin, false, count)
				} else {
					invalid_arg = true
				}
			} else {
				invalid_arg = true
			}
		}
		if invalid_arg {
			semsg(cstring(E15_S), arg)
			nr = 0
		}
	} else if !win_has_winnr(twin, tp) {
		nr = 0
	}
	if nr <= 0 {
		return 0
	}
	nr = 0
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		if win_has_winnr(wp, tp) {
			nr += 1
		}
		if wp == twin {
			break
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	if wp == nil {
		nr = 0
	}
	return nr
}

// "tabpagenr()" function.
@(export)
f_tabpagenr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	nr: C.int = 1
	if a0.v_type != VAR_UNKNOWN {
		arg := tv_get_string_chk(a0)
		nr = 0
		if arg != nil {
			if libc.strcmp(arg, cstring("$")) == 0 {
				nr = tabpage_index_e(nil) - 1
			} else if libc.strcmp(arg, cstring("#")) == 0 {
				if valid_tabpage(lastused_tabpage_g) {
					nr = tabpage_index_e(lastused_tabpage_g)
				} else {
					nr = 0
				}
			} else {
				semsg(cstring(E15_S), arg)
			}
		}
	} else {
		nr = tabpage_index_e(curtab)
	}
	rettv.vval = transmute(rawptr)(C.longlong(nr))
}

// "tabpagewinnr()" function.
@(export)
f_tabpagewinnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	nr: C.int = 1
	tp := find_tabpage(C.int(tv_get_number(a0)))
	if tp == nil {
		nr = 0
	} else {
		nr = get_winnr_o(tp, a1)
	}
	rettv.vval = transmute(rawptr)(C.longlong(nr))
}

// "winnr()" function.
@(export)
f_winnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.vval = transmute(rawptr)(C.longlong(get_winnr_o(curtab, a0)))
}

// "winrestcmd()" function.
@(export)
f_winrestcmd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [50]u8
	ga: Garray
	ga_init_r2(&ga, 1, 70)
	for i := 0; i < 2; i += 1 {
		winnr: C.int = 1
		wp := firstwin
		for wp != nil {
			if !win_has_winnr(wp, curtab) {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			libc.snprintf(&buf[0], C.size_t(size_of(buf)), cstring(":%dresize %d|"), winnr, (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^)
			ga_concat_len_r(&ga, transmute(cstring)(&buf[0]), C.size_t(libc.strlen(transmute(cstring)(&buf[0]))))
			libc.snprintf(&buf[0], C.size_t(size_of(buf)), cstring("vert :%dresize %d|"), winnr, (^C.int)(uintptr(wp) + W_WIDTH_OFF)^)
			ga_concat_len_r(&ga, transmute(cstring)(&buf[0]), C.size_t(libc.strlen(transmute(cstring)(&buf[0]))))
			winnr += 1
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	ga_append_e(&ga, 0)
	rettv.v_type = VAR_STRING
	rettv.vval = ga.ga_data
}

// "winrestview()" function.
@(export)
f_winrestview :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if tv_check_for_nonnull_dict_arg(transmute(^Typval_T)(a0), 0) == FAIL_E {
		return
	}
	dict := (rawptr)(a0.vval)
	di := tv_dict_find_e(dict, cstring("lnum"), 4)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = tv_dict_find_e(dict, cstring("col"), 3)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR + 4)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = tv_dict_find_e(dict, cstring("coladd"), 6)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR + 8)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = tv_dict_find_e(dict, cstring("curswant"), 8)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = false
	}
	di = tv_dict_find_e(dict, cstring("topline"), 7)
	if di != nil {
		set_topline_e(curwin, C.int(tv_get_number(transmute(^Typval_T)(di))))
	}
	di = tv_dict_find_e(dict, cstring("topfill"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = tv_dict_find_e(dict, cstring("leftcol"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = tv_dict_find_e(dict, cstring("skipcol"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	check_cursor_r(curwin)
	win_new_height(curwin, (^C.int)(uintptr(curwin) + W_HEIGHT_OFF)^)
	win_new_width(curwin, (^C.int)(uintptr(curwin) + W_WIDTH_OFF)^)
	changed_window_setting_r(curwin)
	topline := (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^
	if topline <= 0 {
		(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = 1
	} else {
		maxln := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		if topline > maxln {
			(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = maxln
		}
	}
	check_topfill_e(curwin, true)
}

// "winsaveview()" function.
@(export)
f_winsaveview :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(transmute(^Typval_T)(rettv))
	dict := (rawptr)(rettv.vval)
	tv_dict_add_nr(dict, cstring("lnum"), 4, C.longlong((^C.int)(uintptr(curwin) + W_CURSOR)^))
	tv_dict_add_nr(dict, cstring("col"), 3, C.longlong((^C.int)(uintptr(curwin) + W_CURSOR + 4)^))
	tv_dict_add_nr(dict, cstring("coladd"), 6, C.longlong((^C.int)(uintptr(curwin) + W_CURSOR + 8)^))
	update_curswant_r()
	tv_dict_add_nr(dict, cstring("curswant"), 8, C.longlong((^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^))
	tv_dict_add_nr(dict, cstring("topline"), 7, C.longlong((^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^))
	tv_dict_add_nr(dict, cstring("topfill"), 7, C.longlong((^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^))
	tv_dict_add_nr(dict, cstring("leftcol"), 7, C.longlong((^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^))
	tv_dict_add_nr(dict, cstring("skipcol"), 7, C.longlong((^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^))
}

// Get the layout of the given tab page for winlayout().
get_framelayout_o :: proc "c" (fr: rawptr, l: rawptr, outer: bool) {
	context = runtime.default_context()
	if fr == nil {
		return
	}
	fr_list := l
	if !outer {
		fr_list = tv_list_alloc(-3)
		tv_list_append_list(l, fr_list)
	}
	if (^C.int)(fr)^ == FR_LEAF_O {
		fr_win := (^rawptr)(uintptr(fr) + FR_WIN_OFF)^
		if fr_win != nil {
			tv_list_append_string(fr_list, transmute(^u8)(cstring("leaf")), 4)
			tv_list_append_number(fr_list, C.longlong((^C.int)(fr_win)^))
		}
	} else {
		if (^C.int)(fr)^ == FR_ROW_O {
			tv_list_append_string(fr_list, transmute(^u8)(cstring("row")), 3)
		} else {
			tv_list_append_string(fr_list, transmute(^u8)(cstring("col")), 3)
		}
		win_list := tv_list_alloc(-1)
		tv_list_append_list(fr_list, win_list)
		child := (^rawptr)(uintptr(fr) + FR_CHILD_OFF)^
		for child != nil {
			get_framelayout_o(child, win_list, false)
			child = (^rawptr)(uintptr(child) + FR_NEXT_OFF)^
		}
	}
}

// "winlayout()" function.
@(export)
f_winlayout :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	tp: rawptr
	if a0.v_type == VAR_UNKNOWN {
		tp = curtab
	} else {
		tp = find_tabpage(C.int(tv_get_number(a0)))
		if tp == nil {
			return
		}
	}
	get_framelayout_o((^rawptr)(uintptr(tp) + TP_TOPFRAME_OFF)^, (rawptr)(rettv.vval), true)
}

// "wincol()" function.
@(export)
f_wincol :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	validate_cursor_r(curwin)
	rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(curwin) + W_WCOL_OFF)^ + 1))
}

// "winline()" function.
@(export)
f_winline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	validate_cursor_r(curwin)
	rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(curwin) + W_WROW_OFF)^ + 1))
}

// "winheight(nr)" function.
@(export)
f_winheight :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	wp := find_win_by_nr_or_id(a0)
	if wp == nil {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^))
	}
}

// "winwidth(nr)" function.
@(export)
f_winwidth :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	wp := find_win_by_nr_or_id(a0)
	if wp == nil {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^))
	}
}

// —— Batch 14: eval/window.c info/move/splitmove ——
foreign _ {
	@(link_name = "cmdwin_type")
	cmdwin_type_g: C.int
}

E1308_S :: "E1308: Cannot resize a window in another tab page"
E_INVALWINDOW_S :: "E957: Invalid window number"
E_AUABORT_S :: "E855: Autocommands caused command to abort"

// Window info dict for getwininfo().
get_win_info_o :: proc "c" (wp: rawptr, tpnr: C.int, winnr: C.int) -> rawptr {
	context = runtime.default_context()
	dict := tv_dict_alloc()
	validate_botline_win_r(wp)
	tv_dict_add_nr(dict, cstring("tabnr"), 5, C.longlong(tpnr))
	tv_dict_add_nr(dict, cstring("winnr"), 5, C.longlong(winnr))
	tv_dict_add_nr(dict, cstring("winid"), 5, C.longlong((^C.int)(wp)^))
	tv_dict_add_nr(dict, cstring("height"), 6, C.longlong((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^))
	tv_dict_add_nr(dict, cstring("status_height"), 13, C.longlong((^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^))
	tv_dict_add_nr(dict, cstring("winrow"), 6, C.longlong((^C.int)(uintptr(wp) + W_WINROW_OFF)^ + 1))
	tv_dict_add_nr(dict, cstring("topline"), 7, C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^))
	tv_dict_add_nr(dict, cstring("botline"), 7, C.longlong((^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ - 1))
	tv_dict_add_nr(dict, cstring("leftcol"), 7, C.longlong((^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^))
	tv_dict_add_nr(dict, cstring("winbar"), 6, C.longlong((^C.int)(uintptr(wp) + W_WINBAR_HEIGHT_OFF)^))
	tv_dict_add_nr(dict, cstring("width"), 5, C.longlong((^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^))
	tv_dict_add_nr(dict, cstring("bufnr"), 5, C.longlong((^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_FNUM_OFF)^))
	tv_dict_add_nr(dict, cstring("wincol"), 6, C.longlong((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + 1))
	tv_dict_add_nr(dict, cstring("textoff"), 7, C.longlong(win_col_off_r(wp)))
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if bt_terminal(wbuf) {
		tv_dict_add_nr(dict, cstring("terminal"), 8, 1)
	} else {
		tv_dict_add_nr(dict, cstring("terminal"), 8, 0)
	}
	if bt_quickfix(wbuf) {
		tv_dict_add_nr(dict, cstring("quickfix"), 8, 1)
	} else {
		tv_dict_add_nr(dict, cstring("quickfix"), 8, 0)
	}
	if bt_quickfix(wbuf) && (^rawptr)(uintptr(wp) + W_LLIST_REF_OFF)^ != nil {
		tv_dict_add_nr(dict, cstring("loclist"), 7, 1)
	} else {
		tv_dict_add_nr(dict, cstring("loclist"), 7, 0)
	}
	tv_dict_add_dict(dict, cstring("variables"), 9, (^rawptr)(uintptr(wp) + W_VARS_OFF)^)
	return dict
}

// Tabpage info dict for gettabinfo().
get_tabpage_info_o :: proc "c" (tp: rawptr, tp_idx: C.int) -> rawptr {
	context = runtime.default_context()
	dict := tv_dict_alloc()
	tv_dict_add_nr(dict, cstring("tabnr"), 5, C.longlong(tp_idx))
	l := tv_list_alloc(-3)
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		tv_list_append_number(l, C.longlong((^C.int)(wp)^))
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	tv_dict_add_list(dict, cstring("windows"), 7, l)
	tv_dict_add_dict(dict, cstring("variables"), 9, (^rawptr)(uintptr(tp) + TP_VARS_OFF)^)
	return dict
}

// "gettabinfo()" function.
@(export)
f_gettabinfo :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	tparg: rawptr = nil
	if a0.v_type == VAR_UNKNOWN {
		tv_list_alloc_ret(transmute(^Typval)(rettv), 1)
	} else {
		tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	}
	if a0.v_type != VAR_UNKNOWN {
		tparg = find_tabpage(C.int(tv_get_number(a0)))
		if tparg == nil {
			return
		}
	}
	tpnr: C.int = 0
	tp := first_tabpage
	for tp != nil {
		tpnr += 1
		if tparg != nil && tp != tparg {
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			continue
		}
		d := get_tabpage_info_o(tp, tpnr)
		tv_list_append_dict((rawptr)(rettv.vval), d)
		if tparg != nil {
			return
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// "getwininfo()" function.
@(export)
f_getwininfo :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	wparg: rawptr = nil
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if a0.v_type != VAR_UNKNOWN {
		wparg = win_id2wp(C.int(tv_get_number(a0)))
		if wparg == nil {
			return
		}
	}
	tabnr: C.int = 0
	tp := first_tabpage
	for tp != nil {
		tabnr += 1
		winnr: C.int = 0
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			has := false
			if win_has_winnr(wp, tp) {
				winnr += 1
				has = true
			}
			if wparg != nil && wp != wparg {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			wn: C.int = 0
			if has {
				wn = winnr
			}
			d := get_win_info_o(wp, tabnr, wn)
			tv_list_append_dict((rawptr)(rettv.vval), d)
			if wparg != nil {
				return
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

// "win_findbuf()" function.
@(export)
f_win_findbuf :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	win_findbuf(argvars, (rawptr)(rettv.vval))
}

// "win_screenpos()" function.
@(export)
f_win_screenpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	wp := find_win_by_nr_or_id(a0)
	if wp == nil {
		tv_list_append_number((rawptr)(rettv.vval), 0)
		tv_list_append_number((rawptr)(rettv.vval), 0)
	} else {
		tv_list_append_number((rawptr)(rettv.vval), C.longlong((^C.int)(uintptr(wp) + W_WINROW_OFF)^ + 1))
		tv_list_append_number((rawptr)(rettv.vval), C.longlong((^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + 1))
	}
}

// "win_move_separator()" function.
@(export)
f_win_move_separator :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	rettv.vval = transmute(rawptr)(C.longlong(0))
	wp := find_win_by_nr_or_id(a0)
	if wp == nil || (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		return
	}
	if !win_valid(wp) {
		emsg(cstring(E1308_S))
		return
	}
	win_drag_vsep_line(wp, C.int(tv_get_number(a1)))
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// "win_move_statusline()" function.
@(export)
f_win_move_statusline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	rettv.vval = transmute(rawptr)(C.longlong(0))
	wp := find_win_by_nr_or_id(a0)
	if wp == nil || (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		return
	}
	if !win_valid(wp) {
		emsg(cstring(E1308_S))
		return
	}
	win_drag_status_line(wp, C.int(tv_get_number(a1)))
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// "win_gettype(nr)" function.
@(export)
f_win_gettype :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	wp := curwin
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	if a0.v_type != VAR_UNKNOWN {
		wp = find_win_by_nr_or_id(a0)
		if wp == nil {
			rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring("unknown"))))
			return
		}
	}
	s: cstring = nil
	if is_aucmd_win_r(wp) {
		s = cstring("autocmd")
	} else if (^C.int)(uintptr(wp) + W_P_PVW_OFF)^ != 0 {
		s = cstring("preview")
	} else if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
		s = cstring("popup")
	} else if bt_cmdwin((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
		s = cstring("command")
	} else if bt_quickfix((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) {
		if (^rawptr)(uintptr(wp) + W_LLIST_REF_OFF)^ != nil {
			s = cstring("loclist")
		} else {
			s = cstring("quickfix")
		}
	}
	if s != nil {
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(s)))
	}
}

// "getcmdwintype()" function.
@(export)
f_getcmdwintype :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	s := xmallocz_r(1)
	s^ = u8(cmdwin_type_g)
	rettv.vval = transmute(rawptr)(s)
}

// "win_splitmove()" function.
@(export)
f_win_splitmove :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	wp := find_win_by_nr_or_id(a0)
	targetwin := find_win_by_nr_or_id(a1)
	oldwin := curwin
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if wp == nil || targetwin == nil || wp == targetwin || !win_valid(wp) || !win_valid(targetwin) || (^bool)(uintptr(targetwin) + W_FLOATING_OFF)^ {
		emsg(cstring(E_INVALWINDOW_S))
		return
	}
	flags: C.int = 0
	size: C.int = 0
	if a2.v_type != VAR_UNKNOWN {
		if tv_check_for_nonnull_dict_arg(transmute(^Typval_T)(argvars), 2) == FAIL_E {
			return
		}
		d := (rawptr)(a2.vval)
		if tv_dict_get_number(d, cstring("vertical")) != 0 {
			flags |= WSP_VERT_O
		}
		di := tv_dict_find_e(d, cstring("rightbelow"), -1)
		if di != nil {
			if tv_get_number(transmute(^Typval_T)(di)) != 0 {
				flags |= WSP_BELOW_O
			} else {
				flags |= WSP_ABOVE_O
			}
		}
		size = C.int(tv_dict_get_number(d, cstring("size")))
	}
	if is_aucmd_win_r(wp) || text_or_buf_locked_r() || check_split_disallowed(wp) == FAIL_E {
		return
	}
	if curwin != targetwin {
		win_goto(targetwin)
	}
	if curwin == targetwin && win_valid(wp) {
		if win_splitmove(wp, size, flags) == OK_R {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		}
	} else {
		emsg(cstring(E_AUABORT_S))
	}
	if oldwin != curwin && win_valid(oldwin) {
		win_goto(oldwin)
	}
}

// "getwinpos({timeout})" function.
@(export)
f_getwinpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	tv_list_append_number((rawptr)(rettv.vval), -1)
	tv_list_append_number((rawptr)(rettv.vval), -1)
}

// "getwinposx()" function.
@(export)
f_getwinposx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
}

// "getwinposy()" function.
@(export)
f_getwinposy :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
}

// —— Batch 15: eval/window.c win_execute engine (closes window.c) ——
foreign _ {
	@(link_name = "execute_common")
	execute_common_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_off: C.int) ---
}

// win_execute_T mirror (eval/window.h): 4160B.
// pos_T equality (mark.odin's equalpos is file-private).
pos_equal_o :: proc "c" (a: Pos_T, b: Pos_T) -> bool {
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}
WinExecute_T :: struct {
	wp:         rawptr,     // 0
	curpos:     Pos_T,      // 8 (12B)
	cwd:        [4096]u8,   // 20
	cwd_status: C.int,      // 4116
	apply_acd:  bool,       // 4120
	_pad:       [7]u8,
	save_sfname: rawptr,    // 4128
	switchwin:  Switchwin_T, // 4136 (24B)
}
#assert(size_of(WinExecute_T) == 4160)

// Switch to a window for executing user code; win_execute_after MUST follow.
@(export)
win_execute_before :: proc "c" (args: ^WinExecute_T, wp: rawptr, tp: rawptr) -> bool {
	context = runtime.default_context()
	args.wp = wp
	args.curpos = (^Pos_T)(uintptr(wp) + W_CURSOR)^
	args.cwd_status = FAIL
	args.apply_acd = false
	args.save_sfname = nil
	if curwin != wp &&
		((^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^ != nil ||
			(^rawptr)(uintptr(wp) + W_LOCALDIR_OFF)^ != nil ||
			(curtab != tp &&
				((^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^ != nil ||
					(^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^ != nil)) ||
			p_acd_g != 0) {
		args.cwd_status = os_dirname(transmute(cstring)(&args.cwd[0]), MAXPATHL_O)
	}
	if args.cwd_status == OK && p_acd_g != 0 {
		sfname := (^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^
		fname := (^rawptr)(uintptr(curbuf) + B_FNAME)^
		if sfname != nil && fname == sfname {
			args.save_sfname = transmute(rawptr)(xstrdup_o((^u8)(sfname)))
		}
		do_autochdir()
		autocwd: [MAXPATHL_O]u8
		if os_dirname(transmute(cstring)(&autocwd[0]), MAXPATHL_O) == OK {
			args.apply_acd = libc.strcmp(transmute(cstring)(&args.cwd[0]), transmute(cstring)(&autocwd[0])) == 0
		}
	}
	if switch_win_noblock_r(transmute(rawptr)(&args.switchwin), wp, tp, true) == OK_R {
		check_cursor_r(curwin)
		return true
	}
	return false
}

// Restore the previous window after executing user code.
@(export)
win_execute_after :: proc "c" (args: ^WinExecute_T) {
	context = runtime.default_context()
	restore_win_noblock_r(transmute(rawptr)(&args.switchwin), true)
	if args.apply_acd {
		xfree(args.save_sfname)
		do_autochdir()
	} else if args.cwd_status == OK {
		os_chdir(transmute(cstring)(&args.cwd[0]))
		if args.save_sfname != nil {
			xfree((^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^)
			(^rawptr)(uintptr(curbuf) + B_SFNAME_OFF)^ = args.save_sfname
			(^rawptr)(uintptr(curbuf) + B_FNAME)^ = args.save_sfname
		}
	}
	if win_valid(args.wp) && !pos_equal_o(args.curpos, (^Pos_T)(uintptr(args.wp) + W_CURSOR)^) {
		(^bool)(uintptr(args.wp) + W_REDR_STATUS_OFF)^ = true
	}
	check_cursor_r(curwin)
	if VIsual_active {
		check_pos_r(curbuf, &VIsual_g)
	}
}

// "win_execute(win_id, command)" function.
@(export)
f_win_execute :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	a0 := (^Typval_T)(uintptr(argvars))
	id := C.int(tv_get_number(a0))
	tp: rawptr = nil
	wp := win_id2wp_tp(id, &tp)
	if wp == nil || tp == nil {
		return
	}
	args := WinExecute_T{}
	if win_execute_before(&args, wp, tp) {
		execute_common_e(argvars, rettv, 1)
	}
	win_execute_after(&args)
}

// Set "win" to be curwin and "tp" current tabpage (restore_win MUST undo).
@(export)
switch_win :: proc "c" (switchwin: ^Switchwin_T, win: rawptr, tp: rawptr, no_display: bool) -> C.int {
	context = runtime.default_context()
	block_autocmds_r()
	return switch_win_noblock_r(transmute(rawptr)(switchwin), win, tp, no_display)
}

// Restore current tabpage and window saved by switch_win().
@(export)
restore_win :: proc "c" (switchwin: ^Switchwin_T, no_display: bool) {
	context = runtime.default_context()
	restore_win_noblock_r(transmute(rawptr)(switchwin), no_display)
	unblock_autocmds_r()
}

// —— Batch 16: eval/fs.c simple leaves ——
foreign _ {
	@(link_name = "changedir_func")
	changedir_func_e :: proc "c" (new_dir: cstring, scope: C.int) -> bool ---
	@(link_name = "delete_recursive")
	delete_recursive_e :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "vim_copyfile")
	vim_copyfile_e :: proc "c" (from: cstring, to: cstring) -> C.int ---
}

KCDSCOPE_WINDOW_O :: 0
KCDSCOPE_TABPAGE_O :: 1
KCDSCOPE_GLOBAL_O :: 2

E_INVARGNVAL_S :: "E475: Invalid value for argument %s: %s"

// "chdir(dir)" function.
@(export)
f_chdir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	if check_secure() {
		return
	}
	if a0.v_type != VAR_STRING {
		return
	}
	cwd_buf := xmalloc(MAXPATHL_O)
	cwd := (^u8)(cwd_buf)
	if os_dirname(transmute(cstring)(cwd), MAXPATHL_O) != FAIL_E {
		rettv.vval = transmute(rawptr)(xstrdup_o(cwd))
	}
	xfree(cwd_buf)
	scope: C.int = KCDSCOPE_GLOBAL_O
	if a1.v_type != VAR_UNKNOWN {
		s := tv_get_string(a1)
		if libc.strcmp(s, cstring("global")) == 0 {
			scope = KCDSCOPE_GLOBAL_O
		} else if libc.strcmp(s, cstring("tabpage")) == 0 {
			scope = KCDSCOPE_TABPAGE_O
		} else if libc.strcmp(s, cstring("window")) == 0 {
			scope = KCDSCOPE_WINDOW_O
		} else {
			semsg(cstring(E_INVARGNVAL_S), cstring("scope"), s)
			return
		}
	} else if (^rawptr)(uintptr(curwin) + W_LOCALDIR_OFF)^ != nil {
		scope = KCDSCOPE_WINDOW_O
	} else if (^rawptr)(uintptr(curtab) + TP_LOCALDIR_OFF)^ != nil {
		scope = KCDSCOPE_TABPAGE_O
	}
	if !changedir_func_e(transmute(cstring)((rawptr)(a0.vval)), scope) {
		if (^rawptr)(rettv.vval) != nil {
			xfree((rawptr)(rettv.vval))
			rettv.vval = nil
		}
	}
}

// "delete()" function.
@(export)
f_delete :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if check_secure() {
		return
	}
	name := tv_get_string(a0)
	if (^u8)(rawptr(name))^ == 0 {
		emsg(cstring(e_invarg_s))
		return
	}
	nbuf: [65]u8
	flags: cstring
	if a1.v_type != VAR_UNKNOWN {
		flags = tv_get_string_buf(a1, &nbuf[0])
	} else {
		flags = cstring("")
	}
	if (^u8)(rawptr(flags))^ == 0 {
		if os_remove(name) == 0 {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		}
	} else if libc.strcmp(flags, cstring("d")) == 0 {
		if os_rmdir(name) == 0 {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		}
	} else if libc.strcmp(flags, cstring("rf")) == 0 {
		rettv.vval = transmute(rawptr)(C.longlong(delete_recursive_e(name)))
	} else {
		semsg(cstring(E15_S), flags)
	}
}

// "executable()" function.
@(export)
f_executable :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if tv_check_for_string_arg(argvars, 0) == FAIL_E {
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(os_can_exe(tv_get_string(a0), nil, true) ? 1 : 0))
}

// "exepath()" function.
@(export)
f_exepath :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if tv_check_for_nonempty_string_arg(argvars, 0) == FAIL_E {
		return
	}
	path: cstring = nil
	os_can_exe(tv_get_string(a0), &path, true)
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(path)
}

// "filecopy()" function.
@(export)
f_filecopy :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() || tv_check_for_string_arg(argvars, 0) == FAIL_E ||
		tv_check_for_string_arg(argvars, 1) == FAIL_E {
		return
	}
	from := tv_get_string(a0)
	fi: FileInfo
	if os_fileinfo_link(from, &fi) {
		mode := fi.stat.st_mode
		if (mode & 0o170000) == 0o100000 || (mode & 0o170000) == 0o120000 {
			if vim_copyfile_e(tv_get_string(a0), tv_get_string(a1)) == OK_R {
				rettv.vval = transmute(rawptr)(C.longlong(1))
			}
		}
	}
}

// "filereadable()" function.
@(export)
f_filereadable :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	p := tv_get_string(a0)
	ok := (^u8)(rawptr(p))^ != 0 && !os_isdir(p) && os_file_is_readable(p)
	rettv.vval = transmute(rawptr)(C.longlong(ok ? 1 : 0))
}

// "filewritable()" function.
@(export)
f_filewritable :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.vval = transmute(rawptr)(C.longlong(os_file_is_writable(tv_get_string(a0))))
}

// —— Batch 18: eval/fs.c glob/mkdir/path ——
foreign _ {
	@(link_name = "ExpandCleanup")
	ExpandCleanup_e :: proc "c" (xp: rawptr) ---
	@(link_name = "globpath")
	globpath_e :: proc "c" (path: cstring, file: cstring, ga: ^Garray, expand_options: C.int, dirs: bool) ---
	@(link_name = "ga_clear_strings")
	ga_clear_strings_e :: proc "c" (gap: ^Garray) ---
	@(link_name = "path_is_absolute")
	path_is_absolute_e :: proc "c" (fname: cstring) -> bool ---
	@(link_name = "path_tail")
	path_tail_e :: proc "c" (fname: cstring) -> ^u8 ---
	@(link_name = "path_tail_with_sep")
	path_tail_with_sep_e :: proc "c" (fname: ^u8) -> ^u8 ---
	@(link_name = "can_add_defer")
	can_add_defer_e :: proc "c" () -> bool ---
	@(link_name = "vim_mkdir_emsg")
	vim_mkdir_emsg_e :: proc "c" (name: cstring, prot: C.int) -> C.int ---
	@(link_name = "FullName_save")
	FullName_save_e :: proc "c" (fname: cstring, force: bool) -> ^u8 ---
	@(link_name = "add_defer")
	add_defer_e :: proc "c" (name: cstring, argcount_arg: C.int, argvars: ^Typval_T) ---
	@(link_name = "shorten_dir_len")
	shorten_dir_len_e :: proc "c" (str: ^u8, trim_len: C.int) ---
}

WILD_USE_NL_O :: 0x04
WILD_KEEP_ALL_O :: 0x20
WILD_ALLLINKS_O :: 0x200
WILD_ICASE_O :: 0x100
WILD_ALL_O :: 6
WILD_ALL_KEEP_O :: 8

E_MKDIR_S :: "E739: Cannot create directory %s: %s"

// "glob()" function.
@(export)
f_glob :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	a3 := (^Typval_T)(uintptr(argvars) + 48)
	options: C.int = 0x40 | WILD_USE_NL_O
	error := false
	rettv.v_type = VAR_STRING
	if a1.v_type != VAR_UNKNOWN {
		if tv_get_number_chk(a1, &error) != 0 {
			options |= WILD_KEEP_ALL_O
		}
		if a2.v_type != VAR_UNKNOWN {
			if tv_get_number_chk(a2, &error) != 0 {
				tv_list_set_ret_o(rettv, nil)
			}
			if a3.v_type != VAR_UNKNOWN && tv_get_number_chk(a3, &error) != 0 {
				options |= WILD_ALLLINKS_O
			}
		}
	}
	if !error {
		xpc: expand_T
		_ExpandInit(transmute(rawptr)(&xpc))
		xpc.xp_context = 2
		if p_wic_g != 0 {
			options += WILD_ICASE_O
		}
		if rettv.v_type == VAR_STRING {
			rettv.vval = transmute(rawptr)(_ExpandOne(transmute(rawptr)(&xpc), tv_get_string(a0), nil, options, WILD_ALL_O))
		} else {
			_ExpandOne(transmute(rawptr)(&xpc), tv_get_string(a0), nil, options, WILD_ALL_KEEP_O)
			tv_list_alloc_ret(transmute(^Typval)(rettv), xpc.xp_numfiles)
			i: C.int = 0
			for i < xpc.xp_numfiles {
				tv_list_append_string((rawptr)(rettv.vval), transmute(^u8)(([^]cstring)(xpc.xp_files)[uintptr(i)]), -1)
				i += 1
			}
			ExpandCleanup_e(transmute(rawptr)(&xpc))
		}
	} else {
		rettv.vval = nil
	}
}

// "globpath()" function.
@(export)
f_globpath :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	a3 := (^Typval_T)(uintptr(argvars) + 48)
	a4 := (^Typval_T)(uintptr(argvars) + 64)
	flags: C.int = 0
	error := false
	rettv.v_type = VAR_STRING
	if a2.v_type != VAR_UNKNOWN {
		if tv_get_number_chk(a2, &error) != 0 {
			flags |= WILD_KEEP_ALL_O
		}
		if a3.v_type != VAR_UNKNOWN {
			if tv_get_number_chk(a3, &error) != 0 {
				tv_list_set_ret_o(rettv, nil)
			}
			if a4.v_type != VAR_UNKNOWN && tv_get_number_chk(a4, &error) != 0 {
				flags |= WILD_ALLLINKS_O
			}
		}
	}
	buf1: [65]u8
	file := tv_get_string_buf_chk(a1, &buf1[0])
	if file != nil && !error {
		ga: Garray
		ga_init_r2(&ga, 8, 10)
		globpath_e(tv_get_string(a0), file, &ga, flags, false)
		if rettv.v_type == VAR_STRING {
			rettv.vval = transmute(rawptr)(ga_concat_strings_c(&ga, cstring("\n")))
		} else {
			tv_list_alloc_ret(transmute(^Typval)(rettv), ga.ga_len)
			i: C.int = 0
			for i < ga.ga_len {
				tv_list_append_string((rawptr)(rettv.vval), ([^]^u8)(ga.ga_data)[uintptr(i)], -1)
				i += 1
			}
		}
		ga_clear_strings_e(&ga)
	} else {
		rettv.vval = nil
	}
}

// "glob2regpat()" function.
@(export)
f_glob2regpat :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	pat := tv_get_string_chk(a0)
	rettv.v_type = VAR_STRING
	if pat == nil {
		rettv.vval = nil
	} else {
		rettv.vval = transmute(rawptr)(file_pat_to_reg_pat_r(pat, nil, nil, false))
	}
}

// "haslocaldir()" function.
@(export)
f_haslocaldir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	scope: C.int = -1
	scope_number0: C.int = 0
	scope_number1: C.int = 0
	tp := curtab
	win := curwin
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	i: C.int = 0
	aborted := false
	for i < 2 && !aborted {
		av := (^Typval_T)(uintptr(argvars) + uintptr(i) * 16)
		if av.v_type == VAR_UNKNOWN {
			aborted = true
		} else if av.v_type != VAR_NUMBER {
			emsg(cstring(e_invarg_s))
			return
		} else {
			n := C.int(transmute(C.longlong)(av.vval))
			if i == 0 {
				scope_number0 = n
			} else {
				scope_number1 = n
			}
			if n < -1 {
				emsg(cstring(e_invarg_s))
				return
			}
			if n >= 0 && scope == -1 {
				scope = i
			} else if n < 0 {
				scope = i + 1
			}
		}
		i += 1
	}
	if scope == -1 {
		scope = 0
	}
	if scope_number1 > 0 {
		tp = find_tabpage(scope_number1)
		if tp == nil {
			emsg(cstring(E5000_S))
			return
		}
	}
	if scope_number0 >= 0 {
		if scope_number1 < 0 {
			emsg(cstring(E5001_S))
			return
		}
		if scope_number0 > 0 {
			win = find_win_by_nr(a0, tp)
			if win == nil {
				emsg(cstring(E5002_S))
				return
			}
		}
	}
	if scope == KCDSCOPE_WINDOW_O {
		if (^rawptr)(uintptr(win) + W_LOCALDIR_OFF)^ != nil {
			rettv.vval = transmute(rawptr)(C.longlong(1))
		}
	} else if scope == KCDSCOPE_TABPAGE_O {
		if (^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^ != nil {
			rettv.vval = transmute(rawptr)(C.longlong(1))
		}
	} else if scope == KCDSCOPE_GLOBAL_O {
	} else {
		libc.abort()
	}
}

// "isabsolutepath()" function.
@(export)
f_isabsolutepath :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.vval = transmute(rawptr)(C.longlong(path_is_absolute_e(tv_get_string(a0)) ? 1 : 0))
}

// "isdirectory()" function.
@(export)
f_isdirectory :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.vval = transmute(rawptr)(C.longlong(os_isdir(tv_get_string(a0)) ? 1 : 0))
}

// "mkdir()" function.
@(export)
f_mkdir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	prot: C.int = 0o755
	rettv.vval = transmute(rawptr)(C.longlong(FAIL_E))
	if check_secure() {
		return
	}
	buf: [65]u8
	dir := tv_get_string_buf(a0, &buf[0])
	if (^u8)(rawptr(dir))^ == 0 {
		return
	}
	pt := path_tail_e(dir)
	if pt^ == 0 {
		tail := path_tail_with_sep_e(transmute(^u8)(dir))
		tail^ = 0
	}
	defer_del := false
	defer_rec := false
	created: cstring = nil
	if a1.v_type != VAR_UNKNOWN {
		if a2.v_type != VAR_UNKNOWN {
			prot = C.int(tv_get_number_chk(a2, nil))
			if prot == -1 {
				return
			}
		}
		arg2 := tv_get_string(a1)
		defer_del = vim_strchr_c(transmute(^u8)(arg2), C.int('D')) != nil
		defer_rec = vim_strchr_c(transmute(^u8)(arg2), C.int('R')) != nil
		if (defer_del || defer_rec) && !can_add_defer_e() {
			return
		}
		if vim_strchr_c(transmute(^u8)(arg2), C.int('p')) != nil {
			failed_dir: cstring = nil
			cr: cstring = nil
			created_out: ^cstring = nil
			if defer_del || defer_rec {
				created_out = &cr
			}
			ret := os_mkdir_recurse(dir, prot, &failed_dir, created_out)
			if ret != 0 {
				semsg(cstring(E_MKDIR_S), failed_dir, os_strerror(ret))
				xfree(transmute(rawptr)(failed_dir))
				rettv.vval = transmute(rawptr)(C.longlong(FAIL_E))
				return
			}
			rettv.vval = transmute(rawptr)(C.longlong(OK_E))
			created = cr
		}
	}
	if transmute(C.longlong)(rettv.vval) == FAIL_E {
		rettv.vval = transmute(rawptr)(C.longlong(vim_mkdir_emsg_e(dir, prot)))
	}
	if transmute(C.longlong)(rettv.vval) == OK_E && created == nil && (defer_del || defer_rec) {
		created = transmute(cstring)(FullName_save_e(dir, false))
	}
	if created != nil {
		tv: [2]Typval_T
		tv[0] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(created)}
		tv[1] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring("d"))))}
		if defer_rec {
			tv_clear_e(&tv[1])
			tv[1].vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring("rf"))))
		}
		add_defer_e(cstring("delete"), 2, &tv[0])
	}
}

// "pathshorten()" function.
@(export)
f_pathshorten :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	trim_len: C.int = 1
	if a1.v_type != VAR_UNKNOWN {
		trim_len = C.int(tv_get_number(a1))
		if trim_len < 1 {
			trim_len = 1
		}
	}
	rettv.v_type = VAR_STRING
	p := tv_get_string_chk(a0)
	if p == nil {
		rettv.vval = nil
	} else {
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(p)))
		shorten_dir_len_e(transmute(^u8)(rettv.vval), trim_len)
	}
}

// —— Batch 17: eval/fs.c find/dirname/stat ——
foreign _ {
	@(link_name = "find_file_in_path_option")
	find_file_in_path_option_e :: proc "c" (ptr: cstring, len: C.size_t, options: C.int, first: C.int, path_option: cstring, find_what: C.int, rel_fname: cstring, suffixes: cstring, file_to_find: ^rawptr, search_ctx: ^rawptr) -> ^u8 ---
	@(link_name = "vim_findfile_cleanup")
	vim_findfile_cleanup_e :: proc "c" (ctx: rawptr) ---
	@(link_name = "modify_fname")
	modify_fname_e :: proc "c" (src: ^u8, tilde_file: bool, usedlen: ^C.size_t, fnamep: ^rawptr, bufp: ^rawptr, fnamelen: ^C.size_t) -> C.int ---
}

FINDFILE_FILE_O :: 0
FINDFILE_DIR_O :: 1

E5000_S :: "E5000: Cannot find tab number."
E5001_S :: "E5001: Higher scope cannot be -1 if lower scope is >= 0."
E5002_S :: "E5002: Cannot find window number."

// Shared body of finddir()/findfile().
findfilendir_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, find_what: C.int) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	fresult: ^u8 = nil
	bpp := (^rawptr)(uintptr(curbuf) + B_P_PATH_OFF)^
	path := (^u8)(bpp)^ == 0 ? p_path_g : (^u8)(bpp)
	count: C.int = 1
	first := true
	error := false
	rettv.vval = nil
	rettv.v_type = VAR_STRING
	fname := tv_get_string(a0)
	pathbuf: [65]u8
	if a1.v_type != VAR_UNKNOWN {
		p := tv_get_string_buf_chk(a1, &pathbuf[0])
		if p == nil {
			error = true
		} else {
			if (^u8)(rawptr(p))^ != 0 {
				path = transmute(^u8)(p)
			}
			if a2.v_type != VAR_UNKNOWN {
				count = C.int(tv_get_number_chk(a2, &error))
			}
		}
	}
	if count < 0 {
		tv_list_alloc_ret(transmute(^Typval)(rettv), -1)
	}
	if (^u8)(rawptr(fname))^ != 0 && !error {
		file_to_find: rawptr = nil
		search_ctx: rawptr = nil
		more := true
		for more {
			if rettv.v_type == VAR_STRING || rettv.v_type == VAR_LIST {
				xfree(transmute(rawptr)(fresult))
			}
			fname_arg: cstring = nil
			fname_len: C.size_t = 0
			if first {
				fname_arg = fname
				fname_len = C.size_t(libc.strlen(fname))
			}
			ffname := (^rawptr)(uintptr(curbuf) + B_FFNAME)^
			sua := (^rawptr)(uintptr(curbuf) + B_P_SUA_OFF)^
			fresult = find_file_in_path_option_e(fname_arg, fname_len, 0, first ? 1 : 0, transmute(cstring)(path), find_what, transmute(cstring)(ffname), find_what == FINDFILE_DIR_O ? cstring("") : transmute(cstring)(sua), &file_to_find, &search_ctx)
			first = false
			if fresult != nil && rettv.v_type == VAR_LIST {
				tv_list_append_string((rawptr)(rettv.vval), fresult, -1)
			}
			more = (rettv.v_type == VAR_LIST || count - 1 > 0) && fresult != nil
			if rettv.v_type != VAR_LIST {
				count -= 1
			}
		}
		xfree(file_to_find)
		vim_findfile_cleanup_e(search_ctx)
	}
	if rettv.v_type == VAR_STRING {
		rettv.vval = transmute(rawptr)(fresult)
	}
}

// "finddir({fname}[, {path}[, {count}]])" function.
@(export)
f_finddir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	findfilendir_o(argvars, rettv, FINDFILE_DIR_O)
}

// "findfile({fname}[, {path}[, {count}]])" function.
@(export)
f_findfile :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	findfilendir_o(argvars, rettv, FINDFILE_FILE_O)
}

// "fnamemodify({fname}, {mods})" function.
@(export)
f_fnamemodify :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	fbuf: rawptr = nil
	ln: C.size_t = 0
	buf: [65]u8
	fname := tv_get_string_chk(a0)
	mods := tv_get_string_buf_chk(a1, &buf[0])
	if mods == nil || fname == nil {
		fname = nil
	} else {
		ln = C.size_t(libc.strlen(fname))
		if (^u8)(rawptr(mods))^ != 0 {
			usedlen: C.size_t = 0
			fnamep: rawptr = transmute(rawptr)(fname)
			modify_fname_e(transmute(^u8)(mods), false, &usedlen, &fnamep, &fbuf, &ln)
			fname = transmute(cstring)(fnamep)
		}
	}
	rettv.v_type = VAR_STRING
	if fname == nil {
		rettv.vval = nil
	} else {
		rettv.vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(fname), ln))
	}
	xfree(fbuf)
}

// "getcwd([{win}[, {tab}]])" function.
@(export)
f_getcwd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	scope: C.int = -1
	scope_number0: C.int = 0
	scope_number1: C.int = 0
	tp := curtab
	win := curwin
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	i: C.int = 0
	done := false
	for i < 2 && !done {
		av := (^Typval_T)(uintptr(argvars) + uintptr(i) * 16)
		if av.v_type == VAR_UNKNOWN {
			done = true
		} else if av.v_type != VAR_NUMBER {
			emsg(cstring(e_invarg_s))
			return
		} else {
			n := C.int(transmute(C.longlong)(av.vval))
			if i == 0 {
				scope_number0 = n
			} else {
				scope_number1 = n
			}
			if n < -1 {
				emsg(cstring(e_invarg_s))
				return
			}
			if n >= 0 && scope == -1 {
				scope = i
			} else if n < 0 {
				scope = i + 1
			}
		}
		i += 1
	}
	if scope_number1 > 0 {
		tp = find_tabpage(scope_number1)
		if tp == nil {
			emsg(cstring(E5000_S))
			return
		}
	}
	if scope_number0 >= 0 {
		if scope_number1 < 0 {
			emsg(cstring(E5001_S))
			return
		}
		if scope_number0 > 0 {
			win = find_win_by_nr((^Typval_T)(uintptr(argvars)), tp)
			if win == nil {
				emsg(cstring(E5002_S))
				return
			}
		}
	}
	cwd := (^u8)(xmalloc(MAXPATHL_O))
	from: ^u8 = nil
	if scope == KCDSCOPE_WINDOW_O {
		from = (^u8)((^rawptr)(uintptr(win) + W_LOCALDIR_OFF)^)
		if from == nil {
			scope = KCDSCOPE_TABPAGE_O
		}
	}
	if scope == KCDSCOPE_TABPAGE_O {
		from = (^u8)((^rawptr)(uintptr(tp) + TP_LOCALDIR_OFF)^)
		if from == nil {
			scope = KCDSCOPE_GLOBAL_O
		}
	}
	if scope == KCDSCOPE_GLOBAL_O {
		if globaldir_g != nil {
			from = (^u8)(globaldir_g)
		} else {
			scope = -1
		}
	}
	if scope == -1 {
		if os_dirname(transmute(cstring)(cwd), MAXPATHL_O) != FAIL_E {
			from = cwd
		} else {
			from = nil
		}
	}
	if from == nil {
		from = transmute(^u8)(cstring(""))
	}
	rettv.vval = transmute(rawptr)(xstrdup_o(from))
	xfree(rawptr(cwd))
}

// "getfperm({fname})" function.
@(export)
f_getfperm :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	perm: ^u8 = nil
	flags := cstring("rwx")
	file_perm := os_getperm(tv_get_string(a0))
	if file_perm >= 0 {
		perm = xstrdup_o(transmute(^u8)(cstring("---------")))
		for i: C.int = 0; i < 9; i += 1 {
			if (file_perm & C.int32_t(1 << u32(8 - i))) != 0 {
				([^]u8)(perm)[uintptr(i)] = ([^]u8)(rawptr(flags))[uintptr(i % 3)]
			}
		}
	}
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(perm)
}

// "getfsize({fname})" function.
@(export)
f_getfsize :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	fname := tv_get_string(a0)
	fi: FileInfo
	n: C.longlong = -1
	if os_fileinfo(fname, &fi) {
		filesize := os_fileinfo_size(&fi)
		if os_isdir(fname) {
			n = 0
		} else {
			n = C.longlong(filesize)
			if u64(n) != filesize {
				n = -2
			}
		}
	}
	rettv.vval = transmute(rawptr)(n)
}

// "getftime({fname})" function.
@(export)
f_getftime :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	fname := tv_get_string(a0)
	fi: FileInfo
	n: C.longlong = -1
	if os_fileinfo(fname, &fi) {
		n = C.longlong(fi.stat.st_mtim.tv_sec)
	}
	rettv.vval = transmute(rawptr)(n)
}

// "getftype({fname})" function.
@(export)
f_getftype :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	fname := tv_get_string(a0)
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	fi: FileInfo
	if os_fileinfo_link(fname, &fi) {
		mode := fi.stat.st_mode
		t: cstring = cstring("other")
		if (mode & 0o170000) == 0o100000 {
			t = cstring("file")
		} else if (mode & 0o170000) == 0o040000 {
			t = cstring("dir")
		} else if (mode & 0o170000) == 0o120000 {
			t = cstring("link")
		} else if (mode & 0o170000) == 0o060000 {
			t = cstring("bdev")
		} else if (mode & 0o170000) == 0o020000 {
			t = cstring("cdev")
		} else if (mode & 0o170000) == 0o010000 {
			t = cstring("fifo")
		} else if (mode & 0o170000) == 0o140000 {
			t = cstring("socket")
		}
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(t)))
	}
}

// —— Batch 19a: eval/fs.c easy leaves ——
foreign _ {
	@(link_name = "readdir_core")
	readdir_core_e :: proc "c" (gap: ^Garray, path: cstring, ctx: rawptr, checkitem: proc "c" (ctx: rawptr, name: cstring) -> C.longlong) -> C.int ---
	@(link_name = "vim_rename")
	vim_rename_e :: proc "c" (from: cstring, to: cstring) -> C.int ---
	@(link_name = "simplify_filename")
	simplify_filename_e :: proc "c" (filename: ^u8) -> C.size_t ---
}

// Evaluate "expr" (= "context") for readdir().
readdir_checkitem_o :: proc "c" (ctx: rawptr, name: cstring) -> C.longlong {
	context = runtime.default_context()
	expr := (^Typval_T)(ctx)
	retval: C.longlong = 0
	error := false
	if expr.v_type == VAR_UNKNOWN {
		return 1
	}
	save_val: Typval_T
	prepare_vimvar_e(VV_VAL_O, &save_val)
	set_vim_var_string_e(VV_VAL_O, name, -1)
	argv: [2]Typval_T
	argv[0].v_type = VAR_STRING
	argv[0].vval = transmute(rawptr)(name)
	rettv: Typval_T
	done := false
	if eval_expr_typval_e(expr, false, &argv[0], 1, &rettv) == FAIL_E {
		done = true
	}
	if !done {
		retval = tv_get_number_chk(&rettv, &error)
		if error {
			retval = -1
		}
		tv_clear_e(&rettv)
	}
	set_vim_var_string_e(VV_VAL_O, nil, 0)
	restore_vimvar_e(VV_VAL_O, &save_val)
	return retval
}

// "readdir()" function.
@(export)
f_readdir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), -1)
	if check_secure() {
		return
	}
	path := tv_get_string((^Typval_T)(uintptr(argvars)))
	expr := (^Typval_T)(uintptr(argvars) + 16)
	ga: Garray
	ret := readdir_core_e(&ga, path, transmute(rawptr)(expr), readdir_checkitem_o)
	if ret == OK_E && ga.ga_len > 0 {
		i: C.int = 0
		for i < ga.ga_len {
			p := ([^]^u8)(ga.ga_data)[uintptr(i)]
			tv_list_append_string((rawptr)(rettv.vval), p, -1)
			i += 1
		}
	}
	ga_clear_strings_e(&ga)
}

// "rename({from}, {to})" function.
@(export)
f_rename :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if check_secure() {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		buf: [65]u8
		rettv.vval = transmute(rawptr)(C.longlong(vim_rename_e(tv_get_string(a0), tv_get_string_buf(a1, &buf[0]))))
	}
}

// "simplify()" function.
@(export)
f_simplify :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	p := tv_get_string(a0)
	rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(p)))
	simplify_filename_e(transmute(^u8)(rettv.vval))
	rettv.v_type = VAR_STRING
}

// "tempname()" function.
@(export)
f_tempname :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(vim_tempname())
}

// "browse(save, title, initdir, default)" function.
@(export)
f_browse :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = nil
	rettv.v_type = VAR_STRING
}

// "browsedir(title, initdir)" function.
@(export)
f_browsedir :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	f_browse(argvars, rettv, fptr)
}

// —— Batch 19b: eval/fs.c read engine ——
foreign _ {
	@(link_name = "fileno")
	fileno_e :: proc "c" (fp: ^libc.FILE) -> C.int ---
}

E_ISADIR2_S :: "E17: \"%s\" is a directory"
E_NOTOPEN_S :: "E484: Can't open file %s"
E_CANT_READ_S :: "E485: Can't read file %s"
EMPTY_NAME_S :: "<empty>"

// Read blob from file "fd". Caller has allocated a blob in "rettv".
read_blob_o :: proc "c" (fd: ^libc.FILE, rettv: ^Typval_T, offset: i64, size_arg: i64) -> C.int {
	context = runtime.default_context()
	blob := rettv.vval
	file_info: FileInfo
	if !os_fileinfo_fd(fileno_e(fd), &file_info) {
		return FAIL_E
	}
	size := size_arg
	file_size := i64(os_fileinfo_size(&file_info))
	is_chr := (file_info.stat.st_mode & u64(0o170000)) == u64(0o020000)
	off := offset
	whence := libc.Whence.SET
	if off >= 0 {
		if size == -1 || (size > file_size - off && !is_chr) {
			size = file_size - off
		}
	} else {
		if -off > file_size && !is_chr {
			off = -file_size
		}
		if size == -1 || size > -off {
			size = -off
		}
		whence = libc.Whence.END
	}
	if size <= 0 {
		return OK_E
	}
	if off != 0 && libc.fseek(fd, libc.long(off), whence) != 0 {
		return OK_E
	}
	ga_grow_r((^Garray)(blob), C.int(size))
	(^Garray)(blob).ga_len = C.int(size)
	ga := (^Garray)(blob)
	n := libc.fread(ga.ga_data, C.size_t(1), C.size_t(size), fd)
	if n < C.size_t(size) {
		tv_blob_free(blob)
		rettv.vval = nil
		return FAIL_E
	}
	return OK_E
}

// "readfile()" or "readblob()" function.
read_file_or_blob_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, always_blob: bool) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	binary := false
	blob := always_blob
	buf: [1024]u8
	io_size := 1024
	prev: [^]u8 = nil
	prevlen: i64 = 0
	prevsize: i64 = 0
	maxline: i64 = i64(MAXLNUM)
	off: i64 = 0
	size: i64 = -1
	if a1.v_type != VAR_UNKNOWN {
		if always_blob {
			off = i64(tv_get_number(a1))
			if a2.v_type != VAR_UNKNOWN {
				size = i64(tv_get_number(a2))
			}
		} else {
			s1 := tv_get_string(a1)
			if libc.strcmp(s1, cstring("b")) == 0 {
				binary = true
			} else if libc.strcmp(s1, cstring("B")) == 0 {
				blob = true
			}
			if a2.v_type != VAR_UNKNOWN {
				maxline = i64(tv_get_number(a2))
			}
		}
	}
	if blob {
		tv_blob_alloc_ret(rettv)
	} else {
		tv_list_alloc_ret(transmute(^Typval)(rettv), -1)
	}
	fname := tv_get_string(a0)
	if os_isdir(fname) {
		semsg(cstring(E_ISADIR2_S), fname)
		return
	}
	if (^u8)(rawptr(fname))^ == 0 {
		semsg(cstring(E_NOTOPEN_S), cstring(EMPTY_NAME_S))
		return
	}
	fd := (^libc.FILE)(os_fopen(fname, READBIN))
	if fd == nil {
		semsg(cstring(E_NOTOPEN_S), fname)
		return
	}
	if blob {
		if read_blob_o(fd, rettv, off, size) == FAIL_E {
			semsg(cstring(E_CANT_READ_S), fname)
		}
		libc.fclose(fd)
		return
	}
	l := rettv.vval
	for maxline < 0 || i64(tv_list_len_o(l)) < maxline {
		readlen := i64(libc.fread(rawptr(&buf[0]), C.size_t(1), C.size_t(io_size), fd))
		p_off: i64 = 0
		start_off: i64 = 0
		for p_off < readlen || (readlen <= 0 && (prevlen > 0 || binary)) {
			at_end := readlen <= 0
			ch: u8 = 0
			if !at_end {
				ch = buf[p_off]
			}
			if at_end || ch == '\n' {
				ln := p_off - start_off
				if readlen > 0 && !binary {
					for ln > 0 && buf[start_off + ln - 1] == '\r' {
						ln -= 1
					}
					if ln == 0 {
						for prevlen > 0 && prev[prevlen - 1] == '\r' {
							prevlen -= 1
						}
					}
				}
				s: [^]u8 = nil
				if prevlen == 0 {
					s = ([^]u8)(xmemdupz_o2(&buf[start_off], C.size_t(ln)))
				} else {
					s = ([^]u8)(xrealloc(rawptr(prev), C.size_t(prevlen + ln + 1)))
					libc.memcpy(rawptr(&s[prevlen]), rawptr(&buf[start_off]), C.size_t(ln))
					s[prevlen + ln] = 0
					prev = nil
					prevlen = 0
					prevsize = 0
				}
				newtv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = rawptr(s)}
				tv_list_append_owned_tv(l, newtv)
				start_off = p_off + 1
				if maxline < 0 {
					if i64(tv_list_len_o(l)) > -maxline {
						tv_list_item_remove(l, tv_list_first_o(l))
					}
				} else if i64(tv_list_len_o(l)) >= maxline {
					break
				}
				if readlen <= 0 {
					break
				}
			} else if ch == 0 {
				buf[p_off] = '\n'
			} else if ch == 0xbf && !binary {
				back1: u8 = 0
				if p_off >= 1 {
					back1 = buf[p_off - 1]
				} else if prevlen >= 1 {
					back1 = prev[prevlen - 1]
				}
				back2: u8 = 0
				if p_off >= 2 {
					back2 = buf[p_off - 2]
				} else if p_off == 1 && prevlen >= 1 {
					back2 = prev[prevlen - 1]
				} else if prevlen >= 2 {
					back2 = prev[prevlen - 2]
				}
				if back2 == 0xef && back1 == 0xbb {
					dest := p_off - 2
					if start_off == dest {
						start_off = p_off + 1
					} else {
						adjust: i64 = 0
						d := dest
						if d < 0 {
							adjust = -d
							d = 0
						}
						if readlen > p_off + 1 {
							libc.memmove(rawptr(&buf[d]), rawptr(&buf[p_off + 1]), C.size_t(readlen - p_off - 1))
						}
						readlen -= 3 - adjust
						prevlen -= adjust
						p_off = d - 1
					}
				}
			}
			p_off += 1
		}
		if (maxline >= 0 && i64(tv_list_len_o(l)) >= maxline) || readlen <= 0 {
			break
		}
		if start_off < p_off {
			if p_off - start_off + prevlen >= prevsize {
				if prevsize == 0 {
					prevsize = p_off - start_off
				} else {
					grow50 := (prevsize * 3) / 2
					growmin := (p_off - start_off) * 2 + prevlen
					if grow50 > growmin {
						prevsize = grow50
					} else {
						prevsize = growmin
					}
				}
				prev = ([^]u8)(xrealloc(rawptr(prev), C.size_t(prevsize)))
			}
			libc.memmove(rawptr(&prev[prevlen]), rawptr(&buf[start_off]), C.size_t(p_off - start_off))
			prevlen += p_off - start_off
		}
	}
	xfree(rawptr(prev))
	libc.fclose(fd)
}

// "readblob()" function.
@(export)
f_readblob :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	read_file_or_blob_o(argvars, rettv, true)
}

// "readfile()" function.
@(export)
f_readfile :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	read_file_or_blob_o(argvars, rettv, false)
}

// —— Batch 19c: eval/fs.c resolve + writefile ——
foreign _ {
	@(link_name = "path_next_component")
	path_next_component_e :: proc "c" (fname: cstring) -> ^u8 ---
	@(link_name = "readlink")
	readlink_e :: proc "c" (path: cstring, buf: ^u8, bufsiz: C.size_t) -> C.ssize_t ---
	@(link_name = "script_is_lua")
	script_is_lua_e :: proc "c" (sid: C.int) -> bool ---
}

E_CYCLE_S :: "E655: Too many symbolic links (cycle?)"
E_WRITE_ERR_S :: "E80: Error while writing: %s"
E_UNKNOWN_FLAG_S :: "E5060: Unknown flag: %s"
E_CANT_OPEN_EMPTY_S :: "E482: Can't open file with an empty name"
E_CANT_OPEN_WRITE_S :: "E482: Can't open file %s for writing: %s"
E_CLOSE_ERR_S :: "E80: Error when closing file %s: %s"

// "resolve()" function.
@(export)
f_resolve :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.v_type = VAR_STRING
	fname := tv_get_string(a0)
	is_relative_to_current := false
	has_trailing_pathsep := false
	limit: C.int = 100
	p := ([^]u8)(xstrdup_o(transmute(^u8)(fname)))
	if p[0] == '.' && (_vim_ispathsep(C.int(p[1])) || (p[1] == '.' && _vim_ispathsep(C.int(p[2])))) {
		is_relative_to_current = true
	}
	ln := i64(libc.strlen(cstring(rawptr(p))))
	if ln > 1 && _after_pathsep(cstring(rawptr(p)), cstring(rawptr(uintptr(p) + uintptr(ln)))) != 0 {
		has_trailing_pathsep = true
		p[ln - 1] = 0
	}
	q := ([^]u8)(path_next_component_e(cstring(rawptr(p))))
	remain: [^]u8 = nil
	if q[0] != 0 {
		qm1 := ([^]u8)(uintptr(q) - 1)
		remain = ([^]u8)(xstrdup_o(&qm1[0]))
		qm1[0] = 0
	}
	buf := ([^]u8)(xmallocz_r(C.size_t(MAXPATHL_O)))
	cpy: [^]u8 = nil
	outer_done := false
	for !outer_done {
		for {
			rlen := readlink_e(cstring(rawptr(p)), &buf[0], C.size_t(MAXPATHL_O))
			if rlen <= 0 {
				break
			}
			buf[rlen] = 0
			lim := limit
			limit -= 1
			if lim == 0 {
				xfree(rawptr(p))
				xfree(rawptr(remain))
				emsg(cstring(E_CYCLE_S))
				rettv.vval = nil
				xfree(rawptr(buf))
				return
			}
			if remain == nil && has_trailing_pathsep {
				add_pathsep(&buf[0])
			}
			start: [^]u8 = buf
			if _vim_ispathsep(C.int(buf[0])) {
				start = ([^]u8)(uintptr(buf) + 1)
			}
			q = ([^]u8)(path_next_component_e(cstring(rawptr(start))))
			if q[0] != 0 {
				cpy = remain
				qm := ([^]u8)(uintptr(q) - 1)
				if remain != nil {
					remain = ([^]u8)(concat_str_c(cstring(rawptr(uintptr(q) - 1)), cstring(rawptr(remain))))
				} else {
					remain = ([^]u8)(xstrdup_o(&qm[0]))
				}
				xfree(rawptr(cpy))
				qm[0] = 0
			}
			pt := ([^]u8)(path_tail_e(cstring(rawptr(p))))
			if uintptr(pt) > uintptr(p) && pt[0] == 0 {
				off := i64(uintptr(pt) - uintptr(p)) - 1
				p[off] = 0
				pt = ([^]u8)(path_tail_e(cstring(rawptr(p))))
			}
			q = pt
			if uintptr(q) > uintptr(p) && !path_is_absolute_e(cstring(rawptr(buf))) {
				p_len := i64(libc.strlen(cstring(rawptr(p))))
				buf_len := i64(libc.strlen(cstring(rawptr(buf))))
				p = ([^]u8)(xrealloc(rawptr(p), C.size_t(p_len + buf_len + 1)))
				dst := ([^]u8)(path_tail_e(cstring(rawptr(p))))
				libc.memcpy(rawptr(dst), rawptr(buf), C.size_t(buf_len + 1))
			} else {
				xfree(rawptr(p))
				p = ([^]u8)(xstrdup_o(&buf[0]))
			}
		}
		if remain == nil {
			break
		}
		r1 := ([^]u8)(uintptr(remain) + 1)
		q = ([^]u8)(path_next_component_e(cstring(rawptr(r1))))
		ln = i64(uintptr(q) - uintptr(remain))
		if q[0] != 0 {
			ln -= 1
		}
		p_len := i64(libc.strlen(cstring(rawptr(p))))
		cpy = ([^]u8)(xmallocz_r(C.size_t(p_len + ln)))
		libc.memcpy(rawptr(cpy), rawptr(p), C.size_t(p_len + 1))
		xstrlcat((^u8)(uintptr(cpy) + uintptr(p_len)), &remain[0], C.size_t(ln + 1))
		xfree(rawptr(p))
		p = cpy
		if q[0] != 0 {
			src := ([^]u8)(uintptr(q) - 1)
			n := i64(libc.strlen(cstring(rawptr(src)))) + 1
			libc.memmove(rawptr(remain), rawptr(src), C.size_t(n))
		} else {
			xfree(rawptr(remain))
			remain = nil
		}
	}
	if !_vim_ispathsep(C.int(p[0])) {
		if is_relative_to_current && p[0] != 0 && !(p[0] == '.' && (p[1] == 0 || _vim_ispathsep(C.int(p[1])) || (p[1] == '.' && (p[2] == 0 || _vim_ispathsep(C.int(p[2])))))) {
			cpy = ([^]u8)(concat_str_c(cstring("./"), cstring(rawptr(p))))
			xfree(rawptr(p))
			p = cpy
		} else if !is_relative_to_current {
			q = p
			for q[0] == '.' && _vim_ispathsep(C.int(q[1])) {
				q = ([^]u8)(uintptr(q) + 2)
			}
			if uintptr(q) > uintptr(p) {
				src2 := ([^]u8)(uintptr(p) + 2)
				n2 := i64(libc.strlen(cstring(rawptr(src2)))) + 1
				libc.memmove(rawptr(p), rawptr(src2), C.size_t(n2))
			}
		}
	}
	if !has_trailing_pathsep {
		q = ([^]u8)(uintptr(p) + uintptr(i64(libc.strlen(cstring(rawptr(p))))))
		if _after_pathsep(cstring(rawptr(p)), cstring(rawptr(q))) != 0 {
			wt := ([^]u8)(path_tail_with_sep_e(&p[0]))
			wt[0] = 0
		}
	}
	rettv.vval = rawptr(p)
	xfree(rawptr(buf))
	simplify_filename_e(&p[0])
}

// Write "list" of strings to file "fp".
write_list_o :: proc "c" (fp: ^FileDescriptor, list: rawptr, binary: bool) -> bool {
	context = runtime.default_context()
	errcode: C.int = 0
	aborted := false
	li := tv_list_first_o(list)
	for li != nil && !aborted {
		item := (^ListItem)(li)
		li = item.li_next
		s := tv_get_string_chk((^Typval_T)(&item.li_tv))
		if s == nil {
			return false
		}
		hunk := ([^]u8)(s)
		pp := hunk
		inner_done := false
		for !inner_done && !aborted {
			advance := true
			ch := pp[0]
			if ch == 0 || ch == '\n' {
				if uintptr(pp) != uintptr(hunk) {
					w := file_write(fp, transmute(cstring)(hunk), C.size_t(uintptr(pp) - uintptr(hunk)))
					if w < 0 {
						errcode = C.int(w)
						aborted = true
						advance = false
					}
				}
				if !aborted {
					if ch == 0 {
						inner_done = true
						advance = false
					} else {
						hunk = ([^]u8)(uintptr(pp) + 1)
						w := file_write(fp, cstring(""), C.size_t(1))
						if w < 0 {
							errcode = C.int(w)
							inner_done = true
							advance = false
						}
					}
				}
			}
			if advance {
				pp = ([^]u8)(uintptr(pp) + 1)
			}
		}
		if !aborted && (!binary || li != nil) {
			w := file_write(fp, cstring("\n"), C.size_t(1))
			if w < 0 {
				errcode = C.int(w)
				aborted = true
			}
		}
	}
	if aborted {
		semsg(cstring(E_WRITE_ERR_S), os_strerror(errcode))
		return false
	}
	errcode = file_flush(fp)
	if errcode != 0 {
		semsg(cstring(E_WRITE_ERR_S), os_strerror(errcode))
		return false
	}
	return true
}

// Write data with length "len" to file "fp".
write_data_o :: proc "c" (fp: ^FileDescriptor, data: cstring, len: C.size_t) -> bool {
	context = runtime.default_context()
	if len > 0 {
		written := file_write(fp, data, len)
		if written < C.ptrdiff_t(len) {
			semsg(cstring(E_WRITE_ERR_S), os_strerror(C.int(written)))
			return false
		}
	}
	ferr := file_flush(fp)
	if ferr != 0 {
		semsg(cstring(E_WRITE_ERR_S), os_strerror(ferr))
		return false
	}
	return true
}

// Write a blob to file "fp".
write_blob_o :: proc "c" (fp: ^FileDescriptor, blob: rawptr) -> bool {
	context = runtime.default_context()
	ga := (^Garray)(blob)
	return write_data_o(fp, transmute(cstring)(ga.ga_data), C.size_t(tv_blob_len_o(blob)))
}

// Write a string to file "fp".
write_string_o :: proc "c" (fp: ^FileDescriptor, data: cstring) -> bool {
	context = runtime.default_context()
	return write_data_o(fp, data, C.size_t(libc.strlen(data)))
}

// "writefile()" function.
@(export)
f_writefile :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if check_secure() {
		return
	}
	if a0.v_type == VAR_LIST {
		li := tv_list_first_o((rawptr)(a0.vval))
		for li != nil {
			item := (^ListItem)(li)
			li = item.li_next
			if !tv_check_str_or_nr_e((^Typval_T)(&item.li_tv)) {
				return
			}
		}
	} else if a0.v_type != VAR_BLOB && !(a0.v_type == VAR_STRING && script_is_lua_e(current_sctx_sc_sid())) {
		semsg(e_invarg2, cstring("writefile() first argument must be a List or a Blob"))
		return
	}
	binary := false
	append := false
	defer_flag := false
	do_fsync := p_fs != 0
	mkdir_p := false
	if a2.v_type != VAR_UNKNOWN {
		flags := tv_get_string_chk(a2)
		if flags == nil {
			return
		}
		fp_ := ([^]u8)(flags)
		for fp_[0] != 0 {
			ch := fp_[0]
			if ch == 'b' {
				binary = true
			} else if ch == 'a' {
				append = true
			} else if ch == 'D' {
				defer_flag = true
			} else if ch == 's' {
				do_fsync = true
			} else if ch == 'S' {
				do_fsync = false
			} else if ch == 'p' {
				mkdir_p = true
			} else {
				semsg(cstring(E_UNKNOWN_FLAG_S), transmute(cstring)(fp_))
				return
			}
			fp_ = ([^]u8)(uintptr(fp_) + 1)
		}
	}
	buf: [65]u8
	fname := tv_get_string_buf_chk(a1, &buf[0])
	if fname == nil {
		return
	}
	if defer_flag && !can_add_defer_e() {
		return
	}
	fp: FileDescriptor
	if (^u8)(rawptr(fname))^ == 0 {
		emsg(cstring(E_CANT_OPEN_EMPTY_S))
	} else {
		open_flags: C.int = 2
		if append {
			open_flags |= 64
		} else {
			open_flags |= 32
		}
		if mkdir_p {
			open_flags |= 256
		}
		werr := file_open(&fp, fname, open_flags, C.int(0o666))
		if werr != 0 {
			semsg(cstring(E_CANT_OPEN_WRITE_S), fname, os_strerror(werr))
		} else {
			if defer_flag {
				tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(FullName_save_e(fname, false))}
				add_defer_e(cstring("delete"), 1, &tv)
			}
			write_ok := false
			if a0.v_type == VAR_BLOB {
				if a0.vval == nil {
					write_ok = true
				} else {
					write_ok = write_blob_o(&fp, (rawptr)(a0.vval))
				}
			} else if a0.v_type == VAR_STRING {
				write_ok = write_string_o(&fp, transmute(cstring)((rawptr)(a0.vval)))
			} else {
				write_ok = write_list_o(&fp, (rawptr)(a0.vval), binary)
			}
			if write_ok {
				rettv.vval = transmute(rawptr)(C.longlong(0))
			}
			cerr := file_close(&fp, do_fsync)
			if cerr != 0 {
				semsg(cstring(E_CLOSE_ERR_S), fname, os_strerror(cerr))
			}
		}
	}
}

// —— Batch 20a: eval/vars.c parsing leaves ——
foreign _ {
	@(link_name = "find_name_end")
	find_name_end_e :: proc "c" (arg: cstring, expr_start: ^cstring, expr_end: ^cstring, flags: C.int) -> cstring ---
	@(link_name = "skip_expr")
	skip_expr_e :: proc "c" (pp: ^cstring, evalarg: rawptr) -> C.int ---
	@(link_name = "eval_to_string")
	eval_to_string_e :: proc "c" (arg: cstring, join_list: bool, use_simple_function: bool) -> ^u8 ---
}

FNE_INCL_BR_O :: 1
FNE_CHECK_START_O :: 2

E_DBL_SEMI_S :: "E452: Double ; in list of variables"
E_STRAY_CURLY_S :: "E1278: Stray '}' without a matching '{': %s"
E_MISSING_CURLY_S :: "E1279: Missing '}': %s"

// Skip one (assignable) variable name, including @r, $VAR, &option, d.key, l[idx].
skip_var_one_o :: proc "c" (arg: cstring) -> cstring {
	context = runtime.default_context()
	a := ([^]u8)(arg)
	if a[0] == '@' && a[1] != 0 {
		return transmute(cstring)(uintptr(a) + 2)
	}
	start := arg
	if a[0] == '$' || a[0] == '&' {
		start = transmute(cstring)(uintptr(a) + 1)
	}
	return find_name_end_e(start, nil, nil, FNE_INCL_BR_O | FNE_CHECK_START_O)
}

// Skip "[var, var]" list or a single variable name.
@(export)
skip_var_list :: proc "c" (arg: cstring, var_count: ^C.int, semicolon: ^C.int, silent: bool) -> cstring {
	context = runtime.default_context()
	if ([^]u8)(arg)[0] == '[' {
		p := ([^]u8)(arg)
		for {
			p = ([^]u8)(skipwhite(transmute(cstring)(uintptr(p) + 1)))
			s := skip_var_one_o(transmute(cstring)(p))
			if uintptr(rawptr(s)) == uintptr(p) {
				if !silent {
					semsg(e_invarg2, s)
				}
				return nil
			}
			var_count^ += 1
			p = ([^]u8)(skipwhite(s))
			if p[0] == ']' {
				break
			} else if p[0] == ';' {
				if semicolon^ == 1 {
					if !silent {
						emsg(cstring(E_DBL_SEMI_S))
					}
					return nil
				}
				semicolon^ = 1
			} else if p[0] != ',' {
				if !silent {
					semsg(e_invarg2, transmute(cstring)(p))
				}
				return nil
			}
		}
		return transmute(cstring)(uintptr(p) + 1)
	}
	return skip_var_one_o(arg)
}

// Evaluate one {expr} block in a string, append result to "gap".
@(export)
eval_one_expr_in_str :: proc "c" (p: ^u8, gap: ^Garray, evaluate: bool) -> ^u8 {
	context = runtime.default_context()
	block_start := ([^]u8)(skipwhite(transmute(cstring)(uintptr(p) + 1)))
	block_end := block_start
	if block_end[0] == 0 {
		semsg(cstring(E_MISSING_CURLY_S), transmute(cstring)(p))
		return nil
	}
	be := transmute(cstring)(block_end)
	if skip_expr_e(&be, nil) == FAIL_E {
		return nil
	}
	block_end = ([^]u8)(be)
	block_end = ([^]u8)(skipwhite(transmute(cstring)(block_end)))
	if block_end[0] != '}' {
		semsg(cstring(E_MISSING_CURLY_S), transmute(cstring)(p))
		return nil
	}
	if evaluate {
		block_end[0] = 0
		expr_val := eval_to_string_e(transmute(cstring)(block_start), false, false)
		block_end[0] = '}'
		if expr_val == nil {
			return nil
		}
		ga_concat_e(gap, transmute(cstring)(expr_val))
		xfree(rawptr(expr_val))
	}
	return &block_end[1]
}

// Evaluate all {expr} blocks in "str", "{{" collapses to "{".
eval_all_expr_in_str_o :: proc "c" (str: ^u8) -> ^u8 {
	context = runtime.default_context()
	ga: Garray
	ga_init_r2(&ga, 1, 80)
	p := ([^]u8)(str)
	for p[0] != 0 {
		escaped_brace := false
		lit_start := p
		for p[0] != '{' && p[0] != '}' && p[0] != 0 {
			p = ([^]u8)(uintptr(p) + 1)
		}
		if p[0] != 0 && p[0] == p[1] {
			p = ([^]u8)(uintptr(p) + 1)
			escaped_brace = true
		} else if p[0] == '}' {
			semsg(cstring(E_STRAY_CURLY_S), transmute(cstring)(str))
			ga_clear_r(&ga)
			return nil
		}
		ga_concat_len_r(&ga, transmute(cstring)(lit_start), C.size_t(uintptr(p) - uintptr(lit_start)))
		if p[0] == 0 {
			break
		}
		if escaped_brace {
			p = ([^]u8)(uintptr(p) + 1)
			continue
		}
		p = ([^]u8)(eval_one_expr_in_str(&p[0], &ga, true))
		if p == nil {
			ga_clear_r(&ga)
			return nil
		}
	}
	ga_append_r(&ga, 0)
	return (^u8)(ga.ga_data)
}

// —— Batch 20b: eval/vars.c list-one-var cluster ——
foreign _ {
	@(link_name = "msg_puts_len")
	msg_puts_len_e :: proc "c" (str: cstring, len: C.ptrdiff_t, hl_id: C.int, hist: bool) ---
}

// List one variable value with name/type prefix formatting.
list_one_var_a_o :: proc "c" (prefix: cstring, name: cstring, name_len: C.ptrdiff_t, typ: C.int, str: cstring, first: ^C.int) {
	context = runtime.default_context()
	if first^ != 0 {
		msg_ext_set_kind(cstring("list_cmd"))
		msg_start()
	} else {
		msg_putchar(C.int('\n'))
	}
	if (^u8)(rawptr(prefix))^ != 0 {
		msg_puts(prefix)
	}
	if name != nil {
		msg_puts_len_e(name, name_len, 0, false)
	}
	msg_putchar(C.int(' '))
	msg_advance(22)
	s := str
	if typ == VAR_NUMBER {
		msg_putchar(C.int('#'))
	} else if typ == VAR_FUNC || typ == VAR_PARTIAL {
		msg_putchar(C.int('*'))
	} else if typ == VAR_LIST {
		msg_putchar(C.int('['))
		if ([^]u8)(s)[0] == '[' {
			s = transmute(cstring)(uintptr(rawptr(s)) + 1)
		}
	} else if typ == VAR_DICT {
		msg_putchar(C.int('{'))
		if ([^]u8)(s)[0] == '{' {
			s = transmute(cstring)(uintptr(rawptr(s)) + 1)
		}
	} else {
		msg_putchar(C.int(' '))
	}
	msg_outtrans(s, 0, false)
	if typ == VAR_FUNC || typ == VAR_PARTIAL {
		msg_puts(cstring("()"))
	}
	if first^ != 0 {
		msg_clr_eos_r()
		first^ = 0
	}
}

// List the value of one internal variable.
list_one_var_o :: proc "c" (v: rawptr, prefix: cstring, first: ^C.int) {
	context = runtime.default_context()
	tv := (^Typval_T)(v)
	ev := encode_tv2echo(tv, nil)
	s := cstring("")
	if ev != nil {
		s = transmute(cstring)(ev)
	}
	list_one_var_a_o(prefix, transmute(cstring)(uintptr(v) + 17), C.ptrdiff_t(libc.strlen(transmute(cstring)(uintptr(v) + 17))), tv.v_type, s, first)
	xfree(rawptr(ev))
}

// List variables for hashtab "ht" with prefix "prefix".
@(export)
list_hashtable_vars :: proc "c" (ht: rawptr, prefix: cstring, empty: C.int, first: ^C.int) {
	context = runtime.default_context()
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 && !got_int {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		buf: [1025]u8
		xstrlcpy_o(transmute(cstring)(&buf[0]), prefix, C.size_t(1025))
		dik := ([^]u8)(di + 17)
		xstrlcat(&buf[0], &dik[0], C.size_t(1025))
		if message_filtered(transmute(cstring)(&buf[0])) {
			continue
		}
		vtype := (^C.int)(di)^
		vstr := (^rawptr)(di + 8)^
		if empty != 0 || vtype != VAR_STRING || vstr != nil {
			list_one_var_o(rawptr(di), prefix, first)
		}
	}
}

// —— Batch 20c: eval/vars.c spell-expr leaves ——
foreign _ {
	@(link_name = "may_call_simple_func")
	may_call_simple_func_e :: proc "c" (arg: cstring, rettv: ^Typval_T) -> C.int ---
	@(link_name = "eval1")
	eval1_e :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int ---
}

// evalarg_T mirror (eval_defs.h:20): {flags i32, getline/cookie/tofree ptr}.
Evalarg_T :: struct {
	eval_flags:    C.int,
	eval_getline:  rawptr,
	eval_cookie:   rawptr,
	eval_tofree:   rawptr,
}
#assert(size_of(Evalarg_T) == 32)

E_SPELLWORD_S :: "E5700: Expression from 'spellsuggest' must yield lists with exactly two values"

// Evaluate a 'spellsuggest' expr to a suggestion list (NULL on error).
@(export)
eval_spell_expr :: proc "c" (badword: cstring, expr: cstring) -> rawptr {
	context = runtime.default_context()
	save_val: Typval_T
	rettv: Typval_T
	list: rawptr = nil
	p := ([^]u8)(skipwhite(expr))
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
	prepare_vimvar_e(VV_VAL_O, &save_val)
	set_vim_var_string_e(VV_VAL_O, badword, -1)
	if p_verbose == 0 {
		emsg_off += 1
	}
	ctx := get_option_sctx(kOptSpellsuggest_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	evalarg := Evalarg_T{eval_flags = 1}
	r := may_call_simple_func_e(transmute(cstring)(p), &rettv)
	if r == NOTDONE_O {
		pc := transmute(cstring)(p)
		r = eval1_e(&pc, &rettv, rawptr(&evalarg))
		p = ([^]u8)(pc)
	}
	if r == OK_E {
		if rettv.v_type != VAR_LIST {
			tv_clear_e(&rettv)
		} else {
			list = (rawptr)(rettv.vval)
		}
	}
	if p_verbose == 0 {
		emsg_off -= 1
	}
	tv_clear_e(get_vim_var_tv_e(VV_VAL_O))
	restore_vimvar_e(VV_VAL_O, &save_val)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
	return list
}

// Get word + score from a spellsuggest=expr entry (score or -1 on error).
@(export)
get_spellword :: proc "c" (list: rawptr, ret_word: ^cstring) -> C.int {
	context = runtime.default_context()
	if tv_list_len_o(list) != 2 {
		emsg(cstring(E_SPELLWORD_S))
		return -1
	}
	w := tv_list_find_str(list, 0)
	if w == nil {
		return -1
	}
	ret_word^ = w
	return C.int(tv_list_find_nr(list, -1, nil))
}

// —— Batch 20d: eval/vars.c dict-lifecycle leaves ——
foreign _ {
	@(link_name = "hash_clear")
	hash_clear_e :: proc "c" (ht: rawptr) ---
}

DI_FLAGS_ALLOC_O :: 16
DV_LOCK_OFF :: 0
DV_SCOPE_OFF :: 4
DV_COPYID_OFF :: 12
DV_WATCHERS_OFF :: 336

// Initialize dictionary "dict" as a scope.
@(export)
init_var_dict :: proc "c" (dict: rawptr, dict_var: rawptr, scope: C.int) {
	context = runtime.default_context()
	d := uintptr(dict)
	hash_init_r(rawptr(d + 16))
	(^C.int)(d + DV_LOCK_OFF)^ = VAR_UNLOCKED
	(^C.int)(d + DV_SCOPE_OFF)^ = scope
	(^C.int)(d + 8)^ = DO_NOT_FREE_CNT_O
	(^C.int)(d + DV_COPYID_OFF)^ = 0
	v := uintptr(dict_var)
	(^rawptr)(v + 8)^ = dict
	(^C.int)(v)^ = VAR_DICT
	(^C.int)(v + 4)^ = VAR_FIXED_O
	(^u8)(v + 16)^ = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
	(^u8)(v + 17)^ = 0
	w := d + DV_WATCHERS_OFF
	(^rawptr)(w)^ = rawptr(w)
	(^rawptr)(w + 8)^ = rawptr(w)
}

// Like vars_clear(), but only free the value if "free_val" is true.
@(export)
vars_clear_ext :: proc "c" (ht: rawptr, free_val: bool) {
	context = runtime.default_context()
	hash_lock_e(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		if free_val {
			tv_clear_e((^Typval_T)(di))
		}
		if (^u8)(di + 16)^ & DI_FLAGS_ALLOC_O != 0 {
			xfree(rawptr(di))
		}
	}
	hash_clear_e(ht)
	hash_init_r(ht)
}

// Clean up a list of internal variables.
@(export)
vars_clear :: proc "c" (ht: rawptr) {
	context = runtime.default_context()
	vars_clear_ext(ht, true)
}

// Delete a variable from hashtab "ht" at item "hi".
delete_var_o :: proc "c" (ht: rawptr, hi: rawptr) {
	context = runtime.default_context()
	key := ([^]rawptr)(uintptr(hi))[1]
	di := uintptr(key) - 17
	hash_remove_r(ht, hi)
	tv_clear_e((^Typval_T)(di))
	xfree(rawptr(di))
}

// —— Batch 20e: eval/vars.c environ + lookup leaves ——
foreign _ {
	@(link_name = "set_var")
	set_var_e :: proc "c" (name: cstring, name_len: C.size_t, tv: ^Typval_T, copy: bool) ---
	@(link_name = "eval_to_bool")
	eval_to_bool_e :: proc "c" (arg: cstring, error: ^bool, eap: rawptr, skip: bool, use_simple_function: bool) -> bool ---
	@(link_name = "eval_expr_ext")
	eval_expr_ext_e :: proc "c" (arg: cstring, eap: rawptr, use_simple_function: bool) -> ^Typval_T ---
	@(link_name = "find_var")
	find_var_e :: proc "c" (name: cstring, name_len: C.size_t, htp: rawptr, no_autoload: C.int) -> rawptr ---
	@(link_name = "p_ccv")
	p_ccv_e: cstring
	@(link_name = "p_dex")
	p_dex_e: cstring
	@(link_name = "p_pex")
	p_pex_e: cstring
}

VV_CC_FROM_O :: 16
VV_CC_TO_O :: 17
VV_FNAME_IN_O :: 18
VV_FNAME_OUT_O :: 19
VV_FNAME_NEW_O :: 20
VV_FNAME_DIFF_O :: 21

// Set an internal variable to a string value (creates it if missing).
@(export)
set_internal_string_var :: proc "c" (name: cstring, value: cstring) {
	context = runtime.default_context()
	tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(value)}
	set_var_e(name, C.size_t(libc.strlen(name)), &tv, true)
}

// Evaluate 'charconvert' for file conversion (OK/FAIL).
@(export)
eval_charconvert :: proc "c" (enc_from: cstring, enc_to: cstring, fname_from: cstring, fname_to: cstring) -> C.int {
	context = runtime.default_context()
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
	set_vim_var_string_e(VV_CC_FROM_O, enc_from, -1)
	set_vim_var_string_e(VV_CC_TO_O, enc_to, -1)
	set_vim_var_string_e(VV_FNAME_IN_O, fname_from, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, fname_to, -1)
	ctx := get_option_sctx(kOptCharconvert_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	err := false
	if eval_to_bool_e(p_ccv_e, &err, nil, false, true) {
		err = true
	}
	set_vim_var_string_e(VV_CC_FROM_O, nil, -1)
	set_vim_var_string_e(VV_CC_TO_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_IN_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, nil, -1)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
	if err {
		return FAIL_E
	}
	return OK_E
}

// Evaluate 'diffexpr' to compute a diff (errors ignored).
@(export)
eval_diff :: proc "c" (origfile: cstring, newfile: cstring, outfile: cstring) {
	context = runtime.default_context()
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
	set_vim_var_string_e(VV_FNAME_IN_O, origfile, -1)
	set_vim_var_string_e(VV_FNAME_NEW_O, newfile, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, outfile, -1)
	ctx := get_option_sctx(kOptDiffexpr_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	tv := eval_expr_ext_e(p_dex_e, nil, true)
	tv_free(tv)
	set_vim_var_string_e(VV_FNAME_IN_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_NEW_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, nil, -1)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
}

// Evaluate 'patchexpr' to apply a patch (errors ignored).
@(export)
eval_patch :: proc "c" (origfile: cstring, difffile: cstring, outfile: cstring) {
	context = runtime.default_context()
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
	set_vim_var_string_e(VV_FNAME_IN_O, origfile, -1)
	set_vim_var_string_e(VV_FNAME_DIFF_O, difffile, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, outfile, -1)
	ctx := get_option_sctx(kOptPatchexpr_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	tv := eval_expr_ext_e(p_pex_e, nil, true)
	tv_free(tv)
	set_vim_var_string_e(VV_FNAME_IN_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_DIFF_O, nil, -1)
	set_vim_var_string_e(VV_FNAME_OUT_O, nil, -1)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
}

// The string value of a (global/local) variable, NULL when missing.
@(export)
get_var_value :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	v := find_var_e(name, C.size_t(libc.strlen(name)), nil, 0)
	if v == nil {
		return nil
	}
	return tv_get_string((^Typval_T)(v))
}

// Unreference a dictionary initialized by init_var_dict().
@(export)
unref_var_dict :: proc "c" (dict: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(dict) + 8)^ -= DO_NOT_FREE_CNT_O - 1
	tv_dict_unref(dict)
}

// —— Batch 20f: eval/vars.c menutrans cleanup ——
foreign _ {
	@(link_name = "get_globvar_ht")
	get_globvar_ht_e :: proc "c" () -> rawptr ---
}

// Delete all "menutrans_" global variables (after ":menutrans clear").
@(export)
del_menutrans_vars :: proc "c" () {
	context = runtime.default_context()
	ht := get_globvar_ht_e()
	hash_lock_e(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		if libc.strncmp(transmute(cstring)(key), cstring("menutrans_"), 10) == 0 {
			delete_var_o(ht, rawptr(cur))
		}
	}
	hash_unlock_e(ht)
}

// —— Batch 21a: eval/typval.c dict getters + list finders ——
E_LIST_OOR_S :: "E684: List index out of range: %ld"

// Check if a key is present in a dictionary.
@(export)
tv_dict_has_key :: proc "c" (d: rawptr, key: cstring) -> bool {
	context = runtime.default_context()
	return tv_dict_find_r(d, key, -C.ssize_t(1)) != nil
}

// Get a typval item from a dictionary and copy it into "rettv" (OK/FAIL).
@(export)
tv_dict_get_tv :: proc "c" (d: rawptr, key: cstring, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	di := tv_dict_find_r(d, key, -C.ssize_t(1))
	if di == nil {
		return FAIL_E
	}
	tv_copy((^Typval_T)(di), rettv)
	return OK_E
}

// Gets a number item from a dictionary (0 when missing).
@(export)
tv_dict_get_number :: proc "c" (d: rawptr, key: cstring) -> C.longlong {
	context = runtime.default_context()
	return tv_dict_get_number_def(d, key, 0)
}

// Gets a number item from a dictionary ("def" when missing).
@(export)
tv_dict_get_number_def :: proc "c" (d: rawptr, key: cstring, def: C.int) -> C.longlong {
	context = runtime.default_context()
	di := tv_dict_find_r(d, key, -C.ssize_t(1))
	if di == nil {
		return C.longlong(def)
	}
	return tv_get_number((^Typval_T)(di))
}

// Gets a bool item from a dictionary ("def" when missing).
@(export)
tv_dict_get_bool :: proc "c" (d: rawptr, key: cstring, def: C.int) -> C.longlong {
	context = runtime.default_context()
	di := tv_dict_find_r(d, key, -C.ssize_t(1))
	if di == nil {
		return C.longlong(def)
	}
	return tv_get_bool(transmute(^Typval_T)(di))
}

// Get list item l[n] as a number (-1 with error flag when missing).
@(export)
tv_list_find_nr :: proc "c" (l: rawptr, n: C.int, ret_error: ^bool) -> C.longlong {
	context = runtime.default_context()
	li := tv_list_find_e(l, n)
	if li == nil {
		if ret_error != nil {
			ret_error^ = true
		}
		return -1
	}
	return tv_get_number_chk((^Typval_T)(uintptr(li) + 16), ret_error)
}

// Get list item l[n] as a string (NULL with E684 when missing).
@(export)
tv_list_find_str :: proc "c" (l: rawptr, n: C.int) -> cstring {
	context = runtime.default_context()
	li := tv_list_find_e(l, n)
	if li == nil {
		semsg(cstring(E_LIST_OOR_S), C.longlong(n))
		return nil
	}
	return tv_get_string((^Typval_T)(uintptr(li) + 16))
}

// —— Batch 21p: eval/typval.c remove + assign-range ——
E_INVRANGE_S :: "E16: Invalid range"
E_LIST_MORE_S :: "E710: List value has more items than target"
E_LIST_FEW_S :: "E711: List value has not enough items"

// Last item of list (NULL for empty/NULL list).
tv_list_last_o :: proc "c" (l: rawptr) -> rawptr {
	context = runtime.default_context()
	if l == nil {
		return nil
	}
	return (^rawptr)(uintptr(l) + 8)^
}

// —— Batch 23a: eval/encode.c writer + reader leaves ——
foreign _ {
	@(link_name = "xmemscan")
	xmemscan_e :: proc "c" (addr: rawptr, c: u8, size: C.size_t) -> rawptr ---
	@(link_name = "eval_msgpack_type_lists")
	eval_msgpack_type_lists_e: [8]rawptr
}

// ListReaderState mirror (encode.h:28): {list, li, offset, li_length} = 32B.
ListReaderState :: struct {
	list:      rawptr,
	li:        rawptr,
	offset:    C.size_t,
	li_length: C.size_t,
}
#assert(size_of(ListReaderState) == 32)

KMPSTRING_O :: 4
KMPMAP_O :: 6
NL_O :: 10

// Msgpack callback for writing to a blob's growarray.
@(export)
encode_blob_write :: proc "c" (data: rawptr, buf: cstring, len: C.size_t) -> C.int {
	context = runtime.default_context()
	ga_concat_len_r((^Garray)(data), buf, len)
	return C.int(len)
}

// Msgpack callback for writing to readfile()-style list.
@(export)
encode_list_write :: proc "c" (data: rawptr, buf: cstring, len: C.size_t) {
	context = runtime.default_context()
	if len == 0 {
		return
	}
	list := data
	bb := rawptr(buf)
	end := uintptr(bb) + uintptr(len)
	line_end := uintptr(bb)
	li := tv_list_last_o(list)
	if li != nil {
		le := uintptr(xmemscan_e(bb, NL_O, len))
		if le != uintptr(bb) {
			line_length := C.size_t(le - uintptr(bb))
			str := (^rawptr)(uintptr(li) + 24)^
			li_len: C.size_t = 0
			if str != nil {
				li_len = C.size_t(libc.strlen(transmute(cstring)(str)))
			}
			str = xrealloc(str, li_len + line_length + 1)
			(^rawptr)(uintptr(li) + 24)^ = str
			str = rawptr(uintptr(str) + uintptr(li_len))
			libc.memcpy(str, bb, line_length)
			([^]u8)(str)[line_length] = 0
			_memchrsub(str, C.int(NUL), C.int(NL_O), line_length)
		}
		line_end = le + 1
	}
	for line_end < end {
		line_start := line_end
		le := uintptr(xmemscan_e(rawptr(line_start), NL_O, C.size_t(end - line_start)))
		str: rawptr = nil
		if le != line_start {
			line_length := C.size_t(le - line_start)
			str = rawptr(xmemdupz_o2(transmute(^u8)(line_start), line_length))
			_memchrsub(str, C.int(NUL), C.int(NL_O), line_length)
		}
		tv_list_append_allocated_string(list, transmute(^u8)(str))
		line_end = le + 1
	}
	if line_end == end {
		tv_list_append_allocated_string(list, nil)
	}
}

// Convert readfile()-style list to a flat buffer (true on success).
@(export)
encode_vim_list_to_buf :: proc "c" (list: rawptr, ret_len: ^C.size_t, ret_buf: ^rawptr) -> bool {
	context = runtime.default_context()
	ln: C.size_t = 0
	li := tv_list_first_o(list)
	for li != nil {
		tv := (^Typval_T)(uintptr(li) + 16)
		if tv.v_type != VAR_STRING {
			return false
		}
		ln += 1
		s := (rawptr)(tv.vval)
		if s != nil {
			ln += C.size_t(libc.strlen(transmute(cstring)(s)))
		}
		li = (^rawptr)(li)^
	}
	if ln > 0 {
		ln -= 1
	}
	ret_len^ = ln
	if ln == 0 {
		ret_buf^ = nil
		return true
	}
	lrstate := encode_init_lrstate(list)
	buf := ([^]u8)(xmalloc(ln))
	read_bytes: C.size_t = 0
	if encode_read_from_list(&lrstate, &buf[0], ln, &read_bytes) != OK_E {
		libc.abort()
	}
	ret_buf^ = rawptr(buf)
	return true
}

// Read bytes from list (OK done, FAIL on non-string, NOTDONE more left).
@(export)
encode_read_from_list :: proc "c" (state: ^ListReaderState, buf: ^u8, nbuf: C.size_t, read_bytes: ^C.size_t) -> C.int {
	context = runtime.default_context()
	buf_end := uintptr(buf) + uintptr(nbuf)
	p := uintptr(buf)
	for p < buf_end {
		li := state.li
		tv := (^Typval_T)(uintptr(li) + 16)
		base := ([^]u8)((rawptr)(tv.vval))
		i := state.offset
		for i < state.li_length && p < buf_end {
			ch := base[uintptr(i)]
			if ch == NL_O {
				([^]u8)(p)[0] = NUL
			} else {
				([^]u8)(p)[0] = ch
			}
			p += 1
			i += 1
			state.offset += 1
		}
		if p < buf_end {
			state.li = (^rawptr)(li)^
			if state.li == nil {
				read_bytes^ = C.size_t(p - uintptr(buf))
				return OK_E
			}
			p += 1
			([^]u8)(p - 1)[0] = NL_O
			ntv := (^Typval_T)(uintptr(state.li) + 16)
			if ntv.v_type != VAR_STRING {
				read_bytes^ = C.size_t(p - uintptr(buf))
				return FAIL_E
			}
			state.offset = 0
			ns := (rawptr)(ntv.vval)
			if ns == nil {
				state.li_length = 0
			} else {
				state.li_length = C.size_t(libc.strlen(transmute(cstring)(ns)))
			}
		}
	}
	read_bytes^ = nbuf
	more := state.offset < state.li_length
	next := (^rawptr)(state.li)^
	if more || next != nil {
		return NOTDONE_O
	}
	return OK_E
}

// Initial read state for a list.
@(export)
encode_init_lrstate :: proc "c" (list: rawptr) -> ListReaderState {
	context = runtime.default_context()
	st: ListReaderState
	st.list = list
	st.li = tv_list_first_o(list)
	st.offset = 0
	s := (^rawptr)(uintptr(st.li) + 24)^
	if s == nil {
		st.li_length = 0
	} else {
		st.li_length = C.size_t(libc.strlen(transmute(cstring)(s)))
	}
	return st
}

// True when tv is a valid json_encode() dict key.
@(export)
encode_check_json_key :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_STRING {
		return true
	}
	if tv.v_type != VAR_DICT {
		return false
	}
	spdict := (rawptr)(tv.vval)
	if (^C.size_t)(uintptr(spdict) + 24)^ != 2 {
		return false
	}
	type_di := tv_dict_find_r(spdict, cstring("_TYPE"), -C.ssize_t(1))
	if type_di == nil {
		return false
	}
	if (^C.int)(type_di)^ != VAR_LIST {
		return false
	}
	if (^rawptr)(uintptr(type_di) + 8)^ != eval_msgpack_type_lists_e[KMPSTRING_O] {
		return false
	}
	val_di := tv_dict_find_r(spdict, cstring("_VAL"), -C.ssize_t(1))
	if val_di == nil {
		return false
	}
	if (^C.int)(val_di)^ != VAR_LIST {
		return false
	}
	vl := (^rawptr)(uintptr(val_di) + 8)^
	if vl == nil {
		return true
	}
	li := tv_list_first_o(vl)
	for li != nil {
		if (^C.int)(uintptr(li) + 16)^ != VAR_STRING {
			return false
		}
		li = (^rawptr)(li)^
	}
	return true
}

// —— Batch 22f: eval/typval.c string getters + tv2bool ——
KSPECIALVARNULL_O :: 0

// Static scratch for tv_get_string_chk (mirrors C's function-static).
@(private = "file")
get_string_mybuf: [65]u8

// Static scratch for tv_get_string (separate buffer, mirrors C).
@(private = "file")
get_string_buf: [65]u8

// —— Batch 22g: eval/typval.c lock checks + num/float ——
E_LOCKED_S :: "E741: Value is locked"
E_LOCKED_STR_S :: "E741: Value is locked: %.*s"
E_CANTCHANGE_S :: "E742: Cannot change value"
E_CANTCHANGE_STR_S :: "E742: Cannot change value of %.*s"

// True + error when lock forbids change (TV_TRANSLATE/CSTRING lengths).
@(export)
value_check_lock :: proc "c" (lock: C.int, name: cstring, name_len: C.size_t) -> bool {
	context = runtime.default_context()
	if lock == VAR_UNLOCKED {
		return false
	}
	msg: cstring
	if lock == VAR_LOCKED_O {
		if name == nil {
			msg = cstring(E_LOCKED_S)
		} else {
			msg = cstring(E_LOCKED_STR_S)
		}
	} else {
		if name == nil {
			msg = cstring(E_CANTCHANGE_S)
		} else {
			msg = cstring(E_CANTCHANGE_STR_S)
		}
	}
	if name == nil {
		emsg(msg)
	} else {
		nm := name
		nl := name_len
		if nl == max(C.size_t) {
			nm = _t(name)
			nl = C.size_t(libc.strlen(nm))
		} else if nl == max(C.size_t) - 1 {
			nl = C.size_t(libc.strlen(nm))
		}
		semsg(msg, C.int(nl), nm)
	}
	return true
}

// True + error when tv or its container is locked.
@(export)
tv_check_lock :: proc "c" (tv: ^Typval_T, name: cstring, name_len: C.size_t) -> bool {
	context = runtime.default_context()
	lock := C.int(VAR_UNLOCKED)
	if tv.v_type == VAR_BLOB {
		b := (rawptr)(tv.vval)
		if b != nil {
			lock = (^C.int)(uintptr(b) + 28)^
		}
	} else if tv.v_type == VAR_LIST {
		l := (rawptr)(tv.vval)
		if l != nil {
			lock = (^C.int)(uintptr(l) + 72)^
		}
	} else if tv.v_type == VAR_DICT {
		d := (rawptr)(tv.vval)
		if d != nil {
			lock = (^C.int)(uintptr(d))^
		}
	}
	return value_check_lock(lock, name, name_len) || (lock != VAR_UNLOCKED && value_check_lock(lock, name, name_len))
}

// True for number/bool/special/string (else number-coercion error).
@(export)
tv_check_num :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER || tv.v_type == VAR_BOOL || tv.v_type == VAR_SPECIAL || tv.v_type == VAR_STRING {
		return true
	}
	emsg(num_err_o(tv.v_type))
	return false
}

// Float value (0 + error for other types).
@(export)
tv_get_float :: proc "c" (tv: ^Typval_T) -> f64 {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER {
		return f64(transmute(C.longlong)(tv.vval))
	} else if tv.v_type == VAR_FLOAT {
		return transmute(f64)(tv.vval)
	} else if tv.v_type == VAR_PARTIAL || tv.v_type == VAR_FUNC {
		emsg(cstring("E891: Using a Funcref as a Float"))
	} else if tv.v_type == VAR_STRING {
		emsg(cstring("E892: Using a String as a Float"))
	} else if tv.v_type == VAR_LIST {
		emsg(cstring("E893: Using a List as a Float"))
	} else if tv.v_type == VAR_DICT {
		emsg(cstring("E894: Using a Dictionary as a Float"))
	} else if tv.v_type == VAR_BOOL {
		emsg(cstring("E362: Using a boolean value as a Float"))
	} else if tv.v_type == VAR_SPECIAL {
		emsg(cstring("E907: Using a special value as a Float"))
	} else if tv.v_type == VAR_BLOB {
		emsg(cstring("E975: Using a Blob as a Float"))
	} else if tv.v_type == VAR_UNKNOWN {
		semsg(cstring(E_INTERN2_S), cstring("tv_get_float(UNKNOWN)"))
	} else {
		libc.abort()
	}
	return 0
}

// String value or NULL on error (numbers via scratch buf).
@(export)
tv_get_string_chk :: proc "c" (tv: ^Typval_T) -> cstring {
	context = runtime.default_context()
	return tv_get_string_buf_chk(tv, &get_string_mybuf[0])
}

// String value, empty string on error (numbers via scratch buf).
@(export)
tv_get_string :: proc "c" (tv: ^Typval_T) -> cstring {
	context = runtime.default_context()
	s := tv_get_string_buf_chk(tv, &get_string_buf[0])
	if s != nil {
		return s
	}
	return cstring("")
}

// String value with caller buffer (numbers via buf, "" when NULL).
@(export)
tv_get_string_buf :: proc "c" (tv: ^Typval_T, buf: ^u8) -> cstring {
	context = runtime.default_context()
	s := tv_get_string_buf_chk(tv, buf)
	if s != nil {
		return s
	}
	return cstring("")
}

// True when tv is not falsy (JS-like, empty list/dict are false).
@(export)
tv2bool :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER {
		return transmute(C.longlong)(tv.vval) != 0
	} else if tv.v_type == VAR_FLOAT {
		return transmute(f64)(tv.vval) != 0.0
	} else if tv.v_type == VAR_PARTIAL {
		return (rawptr)(tv.vval) != nil
	} else if tv.v_type == VAR_FUNC || tv.v_type == VAR_STRING {
		s := (rawptr)(tv.vval)
		return s != nil && (^u8)(s)^ != 0
	} else if tv.v_type == VAR_LIST {
		l := (rawptr)(tv.vval)
		return l != nil && (^C.int)(uintptr(l) + 60)^ > 0
	} else if tv.v_type == VAR_DICT {
		d := (rawptr)(tv.vval)
		return d != nil && (^C.size_t)(uintptr(d) + 24)^ > 0
	} else if tv.v_type == VAR_BOOL {
		return C.int(transmute(C.longlong)(tv.vval)) == kBoolVarTrue
	} else if tv.v_type == VAR_SPECIAL {
		return C.int(transmute(C.longlong)(tv.vval)) != KSPECIALVARNULL_O
	} else if tv.v_type == VAR_BLOB {
		b := (rawptr)(tv.vval)
		return b != nil && (^C.int)(b)^ > 0
	}
	return false
}

// —— Batch 22e: eval/typval.c scalar getters + str check ——
STR2NR_ALL_O :: 0x0f

E729_S :: "E729: Using a Funcref as a String"

// Number-coercion error for v_type (E703/E745/E728/E805/E974/E685).
num_err_o :: proc "c" (v_type: C.int) -> cstring {
	context = runtime.default_context()
	if v_type == VAR_PARTIAL || v_type == VAR_FUNC {
		return cstring("E703: Using a Funcref as a Number")
	} else if v_type == VAR_LIST {
		return cstring("E745: Using a List as a Number")
	} else if v_type == VAR_DICT {
		return cstring("E728: Using a Dictionary as a Number")
	} else if v_type == VAR_FLOAT {
		return cstring("E805: Using a Float as a Number")
	} else if v_type == VAR_BLOB {
		return cstring("E974: Using a Blob as a Number")
	}
	return cstring("E685: using an invalid value as a Number")
}

// String-coercion error for v_type (E729/E730/E731/E976/E908).
str_err_o :: proc "c" (v_type: C.int) -> cstring {
	context = runtime.default_context()
	if v_type == VAR_PARTIAL || v_type == VAR_FUNC {
		return cstring(E729_S)
	} else if v_type == VAR_LIST {
		return cstring(E_LISTASSTR_S)
	} else if v_type == VAR_DICT {
		return cstring(E_DICTASSTR_S)
	} else if v_type == VAR_BLOB {
		return cstring(E_BLOBASSTR_S)
	}
	return cstring(E_BADSTRING_S)
}

// True when tv is a String or casts to one (else emsg).
@(export)
tv_check_str :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER || tv.v_type == VAR_BOOL || tv.v_type == VAR_SPECIAL || tv.v_type == VAR_STRING || tv.v_type == VAR_FLOAT {
		return true
	}
	emsg(str_err_o(tv.v_type))
	return false
}

// Number value (-1 on type error).
@(export)
tv_get_number :: proc "c" (tv: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	error := false
	return tv_get_number_chk(tv, &error)
}

// Number value with error flag (strings parsed via vim_str2nr).
@(export)
tv_get_number_chk :: proc "c" (tv: ^Typval_T, ret_error: ^bool) -> C.longlong {
	context = runtime.default_context()
	if tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL || tv.v_type == VAR_LIST || tv.v_type == VAR_DICT || tv.v_type == VAR_BLOB || tv.v_type == VAR_FLOAT {
		emsg(num_err_o(tv.v_type))
	} else if tv.v_type == VAR_NUMBER {
		return transmute(C.longlong)(tv.vval)
	} else if tv.v_type == VAR_STRING {
		n: C.longlong = 0
		s := (rawptr)(tv.vval)
		if s != nil {
			vim_str2nr_r(transmute(cstring)(s), nil, nil, STR2NR_ALL_O, &n, nil, 0, false, nil)
		}
		return n
	} else if tv.v_type == VAR_BOOL {
		if C.int(transmute(C.longlong)(tv.vval)) == kBoolVarTrue {
			return 1
		}
		return 0
	} else if tv.v_type == VAR_SPECIAL {
		return 0
	} else if tv.v_type == VAR_UNKNOWN {
		semsg(cstring(E_INTERN2_S), cstring("tv_get_number(UNKNOWN)"))
	} else {
		libc.abort()
	}
	if ret_error != nil {
		ret_error^ = true
	}
	if ret_error == nil {
		return -1
	}
	return 0
}

// Bool as number (same coercion as tv_get_number).
@(export)
tv_get_bool :: proc "c" (tv: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	return tv_get_number_chk(tv, nil)
}

// Bool as number with error flag.
@(export)
tv_get_bool_chk :: proc "c" (tv: ^Typval_T, ret_error: ^bool) -> C.longlong {
	context = runtime.default_context()
	return tv_get_number_chk(tv, ret_error)
}

// Line number from object ("$"/marks resolved via var2fpos).
@(export)
tv_get_lnum :: proc "c" (tv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	before := did_emsg_flag
	lnum := C.int(tv_get_number_chk(tv, nil))
	if lnum <= 0 && before == did_emsg_flag && tv.v_type != VAR_NUMBER {
		fnum: C.int = 0
		fp := var2fpos_e(tv, true, &fnum, false, curwin)
		if fp != nil {
			lnum = (^C.int)(fp)^
		}
	}
	return lnum
}

// Line number with "$" resolved against "buf" (0 on error).
@(export)
tv_get_lnum_buf :: proc "c" (tv: ^Typval_T, buf: rawptr) -> C.int {
	context = runtime.default_context()
	if tv.v_type == VAR_STRING {
		s := ([^]u8)((rawptr)(tv.vval))
		if s != nil && s[0] == '$' && s[1] == 0 && buf != nil {
			return (^C.int)(uintptr(buf) + 8)^
		}
	}
	return C.int(tv_get_number_chk(tv, nil))
}

// —— Batch 22d: eval/typval.c locks ——
VAR_LOCKED_O :: 1

E_NESTEDLOCK_S :: "E743: Variable nested too deep for (un)lock"

// Recursion depth guard (C's function-static `recurse`).
@(private = "file")
item_lock_recurse: C.int

// Apply lock transition: FIXED sticks, else lock?LOCKED:UNLOCKED.
change_lock_o :: proc "c" (slot: ^C.int, lock: bool) {
	context = runtime.default_context()
	if slot^ != VAR_FIXED_O {
		if lock {
			slot^ = VAR_LOCKED_O
		} else {
			slot^ = VAR_UNLOCKED
		}
	}
}

// Lock or unlock an item (deep <0 means infinite depth).
@(export)
tv_item_lock :: proc "c" (tv: ^Typval_T, deep: C.int, lock: bool, check_refcount: bool) {
	context = runtime.default_context()
	if item_lock_recurse >= 100 {
		emsg(cstring(E_NESTEDLOCK_S))
		return
	}
	if deep == 0 {
		return
	}
	item_lock_recurse += 1
	change_lock_o(&tv.v_lock, lock)
	if tv.v_type == VAR_BLOB {
		b := (rawptr)(tv.vval)
		if b != nil && !(check_refcount && (^C.int)(uintptr(b) + 24)^ > 1) {
			change_lock_o((^C.int)(uintptr(b) + 28), lock)
		}
	} else if tv.v_type == VAR_LIST {
		l := (rawptr)(tv.vval)
		if l != nil && !(check_refcount && (^C.int)(uintptr(l) + 56)^ > 1) {
			change_lock_o((^C.int)(uintptr(l) + 72), lock)
			if deep < 0 || deep > 1 {
				li := tv_list_first_o(l)
				for li != nil {
					tv_item_lock((^Typval_T)(uintptr(li) + 16), deep - 1, lock, check_refcount)
					li = (^rawptr)(li)^
				}
			}
		}
	} else if tv.v_type == VAR_DICT {
		d := (rawptr)(tv.vval)
		if d != nil && !(check_refcount && (^C.int)(uintptr(d) + 8)^ > 1) {
			change_lock_o((^C.int)(uintptr(d)), lock)
			if deep < 0 || deep > 1 {
				ht := rawptr(uintptr(d) + 16)
				todo := (^C.size_t)(uintptr(ht) + 8)^
				hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
				for todo > 0 {
					key := ([^]rawptr)(hi)[1]
					hi += 16
					if key == nil || key == rawptr(&hash_removed_c) {
						continue
					}
					todo -= 1
					tv_item_lock((^Typval_T)(uintptr(key) - 17), deep - 1, lock, check_refcount)
				}
			}
		}
	} else if tv.v_type == VAR_UNKNOWN {
		libc.abort()
	}
	item_lock_recurse -= 1
}

// True when the value itself or its container is locked (not fixed).
@(export)
tv_islocked :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	if tv.v_lock == VAR_LOCKED_O {
		return true
	}
	if tv.v_type == VAR_LIST && tv_list_locked_o((rawptr)(tv.vval)) == VAR_LOCKED_O {
		return true
	}
	if tv.v_type == VAR_DICT && (rawptr)(tv.vval) != nil && (^C.int)(uintptr(tv.vval) + 0)^ == VAR_LOCKED_O {
		return true
	}
	return false
}

// —— Batch 21w: eval/typval.c sort engine ——
foreign _ {
	@(link_name = "encode_tv2string")
	encode_tv2string_e :: proc "c" (tv: ^Typval_T, len: ^C.size_t) -> ^u8 ---
	@(link_name = "partial_name")
	partial_name_e :: proc "c" (pt: rawptr) -> cstring ---
	@(link_name = "strtod")
	strtod_e :: proc "c" (nptr: cstring, endptr: ^cstring) -> f64 ---
	@(link_name = "qsort")
	qsort_e :: proc "c" (base: rawptr, nmemb: C.size_t, size: C.size_t, compar: proc "c" (s1: rawptr, s2: rawptr) -> C.int) ---
}

// sortinfo_T mirror (typval.c:44, file-static in C): flags + func state.
Sortinfo_T :: struct {
	ic:       C.int,
	lc:       bool,
	numeric:  bool,
	numbers:  bool,
	float:    bool,
	func:     cstring,
	partial:  rawptr,
	selfdict: rawptr,
	func_err: bool,
}
#assert(size_of(Sortinfo_T) == 40)

// ListSortItem mirror (typval.c:60): {item ptr, idx} = 16B.
ListSortItem :: struct {
	item: rawptr,
	idx:  C.int,
}
#assert(size_of(ListSortItem) == 16)

// funcexe_T mirror (userfunc.h:64, cc-probed 64B).
Funcexe_T :: struct #align(8) {
	argv_func:  rawptr,
	firstline:  C.int,
	lastline:   C.int,
	doesrange:  rawptr,
	evaluate:   bool,
	_pad1:      [7]u8,
	partial:    rawptr,
	selfdict:   rawptr,
	basetv:     rawptr,
	found_var:  bool,
}
#assert(size_of(Funcexe_T) == 64)

ITEM_CMP_FAIL_O :: 999

E_SORTFAIL_S :: "E702: Sort compare function failed"
E_UNIQFAIL_S :: "E882: Uniq compare function failed"
E_LISTARG_S :: "E686: Argument of %s must be a List"

// File-static sort state (C's `static sortinfo_T *sortinfo`).
@(private = "file")
sortinfo_g: ^Sortinfo_T

// Compare function for f_sort()/f_uniq().
item_compare_o :: proc "c" (s1: rawptr, s2: rawptr, keep_zero: bool) -> C.int {
	context = runtime.default_context()
	info := sortinfo_g
	si1 := (^ListSortItem)(s1)
	si2 := (^ListSortItem)(s2)
	tv1 := (^Typval_T)(uintptr(si1.item) + 16)
	tv2 := (^Typval_T)(uintptr(si2.item) + 16)
	res: C.int = 0
	strpath := true
	if info.numbers {
		v1 := tv_get_number(tv1)
		v2 := tv_get_number(tv2)
		if v1 == v2 {
			res = 0
		} else if v1 > v2 {
			res = 1
		} else {
			res = -1
		}
		strpath = false
	} else if info.float {
		f1 := tv_get_float(tv1)
		f2 := tv_get_float(tv2)
		if f1 == f2 {
			res = 0
		} else if f1 > f2 {
			res = 1
		} else {
			res = -1
		}
		strpath = false
	}
	if strpath {
		tofree1: ^u8 = nil
		tofree2: ^u8 = nil
		p1: cstring
		p2: cstring
		if tv1.v_type == VAR_STRING {
			if tv2.v_type != VAR_STRING || info.numeric {
				p1 = cstring("'")
			} else {
				p1 = transmute(cstring)((rawptr)(tv1.vval))
			}
		} else {
			p1 = transmute(cstring)(encode_tv2string_e(tv1, nil))
			tofree1 = transmute(^u8)(p1)
		}
		if tv2.v_type == VAR_STRING {
			if tv1.v_type != VAR_STRING || info.numeric {
				p2 = cstring("'")
			} else {
				p2 = transmute(cstring)((rawptr)(tv2.vval))
			}
		} else {
			p2 = transmute(cstring)(encode_tv2string_e(tv2, nil))
			tofree2 = transmute(^u8)(p2)
		}
		if p1 == nil {
			p1 = cstring("")
		}
		if p2 == nil {
			p2 = cstring("")
		}
		if !info.numeric {
			if info.lc {
				res = C.int(libc.strcoll(p1, p2))
			} else if info.ic != 0 {
				res = C.int(_strcasecmp(p1, p2))
			} else {
				res = C.int(libc.strcmp(p1, p2))
			}
		} else {
			e1: cstring = nil
			e2: cstring = nil
			n1 := strtod_e(p1, &e1)
			n2 := strtod_e(p2, &e2)
			if n1 == n2 {
				res = 0
			} else if n1 > n2 {
				res = 1
			} else {
				res = -1
			}
		}
		xfree(rawptr(tofree1))
		xfree(rawptr(tofree2))
	}
	if res == 0 && !keep_zero {
		if si1.idx > si2.idx {
			res = 1
		} else {
			res = -1
		}
	}
	return res
}

item_compare_keeping_zero_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	return item_compare_o(s1, s2, true)
}

item_compare_not_keeping_zero_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	return item_compare_o(s1, s2, false)
}

// Compare function using a Vimscript callback.
item_compare2_o :: proc "c" (s1: rawptr, s2: rawptr, keep_zero: bool) -> C.int {
	context = runtime.default_context()
	info := sortinfo_g
	if info.func_err {
		return 0
	}
	si1 := (^ListSortItem)(s1)
	si2 := (^ListSortItem)(s2)
	func_name := info.func
	if info.partial != nil {
		func_name = partial_name_e(info.partial)
	}
	argv: [3]Typval_T
	tv_copy((^Typval_T)(uintptr(si1.item) + 16), &argv[0])
	tv_copy((^Typval_T)(uintptr(si2.item) + 16), &argv[1])
	rettv: Typval_T
	rettv.v_type = VAR_UNKNOWN
	funcexe := Funcexe_T{}
	funcexe.evaluate = true
	funcexe.partial = info.partial
	funcexe.selfdict = info.selfdict
	res := call_func(func_name, -1, &rettv, 2, &argv[0], &funcexe)
	tv_clear_e(&argv[0])
	tv_clear_e(&argv[1])
	if res == FAIL_E {
		res = ITEM_CMP_FAIL_O
		info.func_err = true
	} else {
		n := tv_get_number_chk(&rettv, &info.func_err)
		if n > 0 {
			res = 1
		} else if n < 0 {
			res = -1
		} else {
			res = 0
		}
	}
	if info.func_err {
		res = ITEM_CMP_FAIL_O
	}
	tv_clear_e(&rettv)
	if res == 0 && !keep_zero {
		if si1.idx > si2.idx {
			res = 1
		} else {
			res = -1
		}
	}
	return res
}

item_compare2_keeping_zero_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	return item_compare2_o(s1, s2, true)
}

item_compare2_not_keeping_zero_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	return item_compare2_o(s1, s2, false)
}

// sort() List "l".
do_sort_o :: proc "c" (l: rawptr, info: ^Sortinfo_T) {
	context = runtime.default_context()
	len := tv_list_len_o(l)
	ptrs := ([^]ListSortItem)(xmalloc(C.size_t(len) * 16))
	i: C.int = 0
	li := tv_list_first_o(l)
	for li != nil {
		ptrs[uintptr(i)].item = li
		ptrs[uintptr(i)].idx = i
		i += 1
		li = (^rawptr)(li)^
	}
	info.func_err = false
	cmp: proc "c" (s1: rawptr, s2: rawptr) -> C.int = item_compare_not_keeping_zero_o
	if info.func != nil || info.partial != nil {
		cmp = item_compare2_not_keeping_zero_o
	}
	qsort_e(rawptr(ptrs), C.size_t(len), 16, cmp)
	if !info.func_err {
		(^rawptr)(l)^ = nil
		(^rawptr)(uintptr(l) + 8)^ = nil
		(^rawptr)(uintptr(l) + 24)^ = nil
		(^C.int)(uintptr(l) + 60)^ = 0
		i = 0
		for i < len {
			tv_list_append(l, ptrs[uintptr(i)].item)
			i += 1
		}
	}
	if info.func_err {
		emsg(cstring(E_SORTFAIL_S))
	}
	xfree(rawptr(ptrs))
}

// uniq() List "l".
do_uniq_o :: proc "c" (l: rawptr, info: ^Sortinfo_T) {
	context = runtime.default_context()
	len := tv_list_len_o(l)
	ptrs := ([^]ListSortItem)(xmalloc(C.size_t(len) * 16))
	info.func_err = false
	li := (^rawptr)(tv_list_first_o(l))^
	for li != nil {
		prev := (^rawptr)(uintptr(li) + 8)^
		if item_compare_keeping_zero_o(rawptr(&prev), rawptr(&li)) == 0 {
			li = tv_list_item_remove(l, li)
		} else {
			li = (^rawptr)(li)^
		}
		if info.func_err {
			emsg(cstring(E_UNIQFAIL_S))
			break
		}
	}
	xfree(rawptr(ptrs))
}

// Parse sort()/uniq() optional args into "info" (OK/FAIL).
parse_sort_uniq_args_o :: proc "c" (argvars: ^Typval_T, info: ^Sortinfo_T) -> C.int {
	context = runtime.default_context()
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	info.ic = 0
	info.lc = false
	info.numeric = false
	info.numbers = false
	info.float = false
	info.func = nil
	info.partial = nil
	info.selfdict = nil
	if a1.v_type == VAR_UNKNOWN {
		return OK_E
	}
	if a1.v_type == VAR_FUNC {
		info.func = transmute(cstring)((rawptr)(a1.vval))
	} else if a1.v_type == VAR_PARTIAL {
		info.partial = (rawptr)(a1.vval)
	} else {
		error := false
		nr := C.int(tv_get_number_chk(a1, &error))
		if error {
			return FAIL_E
		}
		if nr == 1 {
			info.ic = 1
		} else if a1.v_type != VAR_NUMBER {
			info.func = tv_get_string(a1)
		} else if nr != 0 {
			emsg(e_invarg_s)
			return FAIL_E
		}
		if info.func != nil {
			f := ([^]u8)(info.func)
			if f[0] == 0 {
				info.func = nil
			} else if libc.strcmp(info.func, cstring("n")) == 0 {
				info.func = nil
				info.numeric = true
			} else if libc.strcmp(info.func, cstring("N")) == 0 {
				info.func = nil
				info.numbers = true
			} else if libc.strcmp(info.func, cstring("f")) == 0 {
				info.func = nil
				info.float = true
			} else if libc.strcmp(info.func, cstring("i")) == 0 {
				info.func = nil
				info.ic = 1
			} else if libc.strcmp(info.func, cstring("l")) == 0 {
				info.func = nil
				info.lc = true
			}
		}
	}
	if a2.v_type != VAR_UNKNOWN {
		if tv_check_for_dict_arg(argvars, 2) == FAIL_E {
			return FAIL_E
		}
		info.selfdict = (rawptr)(a2.vval)
	}
	return OK_E
}

// "sort()" or "uniq()" function.
do_sort_uniq_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, sort: bool) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if a0.v_type != VAR_LIST {
		if sort {
			semsg(cstring(E_LISTARG_S), cstring("sort()"))
		} else {
			semsg(cstring(E_LISTARG_S), cstring("uniq()"))
		}
		return
	}
	old := sortinfo_g
	info: Sortinfo_T
	sortinfo_g = &info
	done := false
	msg: cstring = cstring("sort() argument")
	if !sort {
		msg = cstring("uniq() argument")
	}
	l := (rawptr)(a0.vval)
	if value_check_lock(tv_list_locked_o(l), msg, max(C.size_t)) {
		done = true
	}
	if !done {
		tv_list_set_ret_o(rettv, l)
		if tv_list_len_o(l) > 1 && parse_sort_uniq_args_o(argvars, &info) == OK_E {
			if sort {
				do_sort_o(l, &info)
			} else {
				do_uniq_o(l, &info)
			}
		}
	}
	sortinfo_g = old
}

// "sort({list})" function.
@(export)
f_sort :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	do_sort_uniq_o(argvars, rettv, true)
}

// "uniq({list})" function.
@(export)
f_uniq :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	do_sort_uniq_o(argvars, rettv, false)
}

// Remove a list item and free it (returns following item).
@(export)
tv_list_item_remove :: proc "c" (l: rawptr, item: rawptr) -> rawptr {
	context = runtime.default_context()
	next_item := (^rawptr)(item)^
	tv_list_drop_items(l, item, item)
	tv_clear_e((^Typval_T)(uintptr(item) + 16))
	xfree(item)
	return next_item
}

// —— Batch 21t: eval/typval.c items/keys/values + dict remove ——
KDICT2LISTKEYS_O :: 0
KDICT2LISTVALUES_O :: 1
KDICT2LISTITEMS_O :: 2

E_LISTDICTBLOBSTR_S :: "E1225: List, Dictionary, Blob or String required for argument %d"
E_TOOMANYARG_S :: "E118: Too many arguments for function: %s"
E_DICTKEY_S :: "E716: Key not present in Dictionary: \"%s\""

// "items(blob)": list of [index, byte] pairs (null blob is empty).
tv_blob2items_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	blob := (rawptr)(a0.vval)
	tv_list_alloc_ret(transmute(^Typval)(rettv), tv_blob_len_o(blob))
	i: C.int = 0
	for i < tv_blob_len_o(blob) {
		l2 := tv_list_alloc(2)
		tv_list_append_list((rawptr)(rettv.vval), l2)
		tv_list_append_number(l2, C.longlong(i))
		tv_list_append_number(l2, C.longlong(tv_blob_get_o(blob, i)))
		i += 1
	}
}

// "items(dict)".
tv_dict2items_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	tv_dict2list_o(argvars, rettv, KDICT2LISTITEMS_O)
}

// "items(list)": list of [index, value] pairs (null list is empty).
tv_list2items_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	l := (rawptr)(a0.vval)
	tv_list_alloc_ret(transmute(^Typval)(rettv), tv_list_len_o(l))
	if l == nil {
		return
	}
	idx: C.longlong = 0
	li := tv_list_first_o(l)
	for li != nil {
		l2 := tv_list_alloc(2)
		tv_list_append_list((rawptr)(rettv.vval), l2)
		tv_list_append_number(l2, idx)
		tv_list_append_tv(l2, (^Typval_T)(uintptr(li) + 16))
		idx += 1
		li = (^rawptr)(li)^
	}
}

// "items(string)": list of [index, char] pairs (null string is empty).
tv_string2items_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	p := ([^]u8)(a0.vval)
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if p == nil {
		return
	}
	idx: C.longlong = 0
	for p[0] != 0 {
		ln := utfc_ptr2len(transmute(cstring)(p))
		if ln == 0 {
			break
		}
		l2 := tv_list_alloc(2)
		tv_list_append_list((rawptr)(rettv.vval), l2)
		tv_list_append_number(l2, idx)
		tv_list_append_string(l2, &p[0], C.ssize_t(ln))
		p = ([^]u8)(uintptr(p) + uintptr(ln))
		idx += 1
	}
}

// Turn a dictionary into a list (keys, values or [key, value] items).
tv_dict2list_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, what: C.int) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if tv_check_for_dict_arg(argvars, 0) == FAIL_E {
		tv_list_alloc_ret(transmute(^Typval)(rettv), 0)
		return
	}
	d := (rawptr)(a0.vval)
	tv_list_alloc_ret(transmute(^Typval)(rettv), C.int(tv_dict_len_o(d)))
	if d == nil {
		return
	}
	ht := rawptr(uintptr(d) + 16)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		tv_item := Typval_T{v_lock = VAR_UNLOCKED}
		if what == KDICT2LISTKEYS_O {
			tv_item.v_type = VAR_STRING
			tv_item.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(di + 17)))
		} else if what == KDICT2LISTVALUES_O {
			tv_copy((^Typval_T)(di), &tv_item)
		} else {
			sub_l := tv_list_alloc(2)
			tv_item.v_type = VAR_LIST
			tv_item.vval = transmute(rawptr)(sub_l)
			tv_list_ref_o(sub_l)
			tv_list_append_string(sub_l, transmute(^u8)(di + 17), -1)
			tv_list_append_tv(sub_l, (^Typval_T)(di))
		}
		tv_list_append_owned_tv((rawptr)(rettv.vval), tv_item)
	}
}

// "items()" function.
@(export)
f_items :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	if a0.v_type == VAR_STRING {
		tv_string2items_o(argvars, rettv)
	} else if a0.v_type == VAR_LIST {
		tv_list2items_o(argvars, rettv)
	} else if a0.v_type == VAR_BLOB {
		tv_blob2items_o(argvars, rettv)
	} else if a0.v_type == VAR_DICT {
		tv_dict2items_o(argvars, rettv)
	} else {
		semsg(cstring(E_LISTDICTBLOBSTR_S), 1)
	}
}

// "keys()" function.
@(export)
f_keys :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict2list_o(argvars, rettv, KDICT2LISTKEYS_O)
}

// "values(dict)" function.
@(export)
f_values :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict2list_o(argvars, rettv, KDICT2LISTVALUES_O)
}

// "has_key()" function.
@(export)
f_has_key :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if tv_check_for_dict_arg(argvars, 0) == FAIL_E {
		return
	}
	if a0.vval == nil {
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(tv_dict_find_r((rawptr)(a0.vval), tv_get_string(a1), -C.ssize_t(1)) != nil ? 1 : 0))
}

// "remove({dict})" function.
@(export)
tv_dict_remove :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	if a2.v_type != VAR_UNKNOWN {
		semsg(cstring(E_TOOMANYARG_S), cstring("remove()"))
		return
	}
	d := (rawptr)(a0.vval)
	if d == nil {
		return
	}
	if value_check_lock((^C.int)(uintptr(d))^, arg_errmsg, max(C.size_t)) {
		return
	}
	key := tv_get_string_chk(a1)
	if key == nil {
		return
	}
	di := tv_dict_find_r(d, key, -C.ssize_t(1))
	if di == nil {
		semsg(cstring(E_DICTKEY_S), key)
		return
	}
	if var_check_fixed_e(C.int((^u8)(uintptr(di) + 16)^), arg_errmsg, max(C.size_t)) || var_check_ro_e(C.int((^u8)(uintptr(di) + 16)^), arg_errmsg, max(C.size_t)) {
		return
	}
	rettv^ = ((^Typval_T)(di))^
	(^Typval_T)(di)^ = Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED, vval = nil}
	tv_dict_item_remove(d, di)
	if tv_dict_is_watched_o(d) {
		tv_dict_watcher_notify_r(d, key, nil, rettv)
	}
}

// —— Batch 21s: eval/typval.c blob2list/list2blob + alloc_ret ——
E_BLOBVAL_S :: "E1239: Invalid value for blob: 0x%lX"

// Set dict as rettv's value (refcount increased when non-NULL).
tv_dict_set_ret_o :: proc "c" (tv: ^Typval_T, d: rawptr) {
	context = runtime.default_context()
	tv.v_type = VAR_DICT
	tv.vval = transmute(rawptr)(d)
	if d != nil {
		(^C.int)(uintptr(d) + 8)^ += 1
	}
}

// "blob2list()" function.
@(export)
f_blob2list :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if tv_check_for_blob_arg(argvars, 0) == FAIL_E {
		return
	}
	blob := (rawptr)(a0.vval)
	l := (rawptr)(rettv.vval)
	i: C.int = 0
	for i < tv_blob_len_o(blob) {
		tv_list_append_number(l, C.longlong(tv_blob_get_o(blob, i)))
		i += 1
	}
}

// "list2blob()" function.
@(export)
f_list2blob :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	blob := tv_blob_alloc_ret(rettv)
	if tv_check_for_list_arg(argvars, 0) == FAIL_E {
		return
	}
	l := (rawptr)(a0.vval)
	if l == nil {
		return
	}
	li := tv_list_first_o(l)
	for li != nil {
		error := false
		n := tv_get_number_chk((^Typval_T)(uintptr(li) + 16), &error)
		if error || n < 0 || n > 255 {
			if !error {
				semsg(cstring(E_BLOBVAL_S), C.int(n))
			}
			ga_clear_r((^Garray)(blob))
			return
		}
		ga_append_r((^Garray)(blob), u8(n))
		li = (^rawptr)(li)^
	}
}

// Allocate an empty list for a return value (refcount set).
@(export)
tv_list_alloc_ret :: proc "c" (ret_tv: ^Typval, len: C.int) -> rawptr {
	context = runtime.default_context()
	l := tv_list_alloc(C.ssize_t(len))
	tv_list_set_ret_o(transmute(^Typval_T)(ret_tv), l)
	(^Typval_T)(ret_tv).v_lock = VAR_UNLOCKED
	return l
}

// Allocate an empty dictionary with given lock status.
@(export)
tv_dict_alloc_lock :: proc "c" (lock: C.int) -> rawptr {
	context = runtime.default_context()
	d := tv_dict_alloc()
	(^C.int)(d)^ = lock
	return d
}

// Allocate an empty dictionary for a return value.
@(export)
tv_dict_alloc_ret :: proc "c" (ret_tv: ^Typval_T) {
	context = runtime.default_context()
	d := tv_dict_alloc_lock(VAR_UNLOCKED)
	tv_dict_set_ret_o(ret_tv, d)
}

// "remove({list})" function (single item or range).
@(export)
tv_list_remove :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	l := (rawptr)(a0.vval)
	error := false
	if value_check_lock(tv_list_locked_o(l), arg_errmsg, max(C.size_t)) {
		return
	}
	idx := tv_get_number_chk(a1, &error)
	if error {
		return
	}
	item := tv_list_find_e(l, C.int(idx))
	if item == nil {
		semsg(cstring(E_LIST_OOR_S), C.longlong(idx))
		return
	}
	if a2.v_type == VAR_UNKNOWN {
		tv_list_drop_items(l, item, item)
		rettv^ = ((^Typval_T)(uintptr(item) + 16))^
		xfree(item)
	} else {
		end := tv_get_number_chk(a2, &error)
		if error {
			return
		}
		item2 := tv_list_find_e(l, C.int(end))
		if item2 == nil {
			semsg(cstring(E_LIST_OOR_S), C.longlong(end))
			return
		}
		cnt: C.int = 0
		li := item
		found := false
		for li != nil {
			cnt += 1
			if li == item2 {
				found = true
				break
			}
			li = (^rawptr)(li)^
		}
		if !found {
			emsg(cstring(E_INVRANGE_S))
			return
		}
		tv_list_move_items(l, item, item2, tv_list_alloc_ret(transmute(^Typval)(rettv), cnt), cnt)
	}
}

// Assign values from list "src" into a range of "dest" (OK/FAIL).
@(export)
tv_list_assign_range :: proc "c" (dest: rawptr, src: rawptr, idx1_arg: C.int, idx2: C.int, empty_idx2: bool, op: cstring, varname: cstring) -> C.int {
	context = runtime.default_context()
	idx1 := idx1_arg
	first_li := tv_list_find_index_o(dest, &idx1)
	idx := idx1
	dest_li := first_li
	src_li := tv_list_first_o(src)
	for src_li != nil && dest_li != nil {
		if value_check_lock((^C.int)(uintptr(dest_li) + 20)^, varname, max(C.size_t) - 1) {
			return FAIL_E
		}
		src_li = (^rawptr)(src_li)^
		if src_li == nil || (!empty_idx2 && idx2 == idx) {
			break
		}
		dest_li = (^rawptr)(dest_li)^
		idx += 1
	}
	idx = idx1
	dest_li = first_li
	src_li = tv_list_first_o(src)
	for src_li != nil {
		if op != nil && (^u8)(rawptr(op))^ != '=' {
			eexe_mod_op((^Typval_T)(uintptr(dest_li) + 16), (^Typval_T)(uintptr(src_li) + 16), op)
		} else {
			tv_clear_e((^Typval_T)(uintptr(dest_li) + 16))
			tv_copy((^Typval_T)(uintptr(src_li) + 16), (^Typval_T)(uintptr(dest_li) + 16))
		}
		src_li = (^rawptr)(src_li)^
		if src_li == nil || (!empty_idx2 && idx2 == idx) {
			break
		}
		if (^rawptr)(dest_li)^ == nil {
			tv_list_append_number(dest, 0)
			dest_li = tv_list_last_o(dest)
		} else {
			dest_li = (^rawptr)(dest_li)^
		}
		idx += 1
	}
	if src_li != nil {
		emsg(cstring(E_LIST_MORE_S))
		return FAIL_E
	}
	if empty_idx2 {
		if dest_li != nil && (^rawptr)(dest_li)^ != nil {
			emsg(cstring(E_LIST_FEW_S))
			return FAIL_E
		}
	} else if idx != idx2 {
		emsg(cstring(E_LIST_FEW_S))
		return FAIL_E
	}
	return OK_E
}

// —— Batch 21b: eval/typval.c list-walk leaves ——

// Locate item in a list and return its index (-1 when absent).
@(export)
tv_list_idx_of_item :: proc "c" (l: rawptr, item: rawptr) -> C.int {
	context = runtime.default_context()
	if l == nil {
		return -1
	}
	idx: C.int = 0
	li := tv_list_first_o(l)
	for li != nil {
		if li == item {
			return idx
		}
		idx += 1
		li = (^rawptr)(li)^
	}
	return -1
}

// Check whether two lists are equal.
@(export)
tv_list_equal :: proc "c" (l1: rawptr, l2: rawptr, ic: bool) -> bool {
	context = runtime.default_context()
	if l1 == l2 {
		return true
	}
	if tv_list_len_o(l1) != tv_list_len_o(l2) {
		return false
	}
	if tv_list_len_o(l1) == 0 {
		return true
	}
	if l1 == nil || l2 == nil {
		return false
	}
	item1 := tv_list_first_o(l1)
	item2 := tv_list_first_o(l2)
	for item1 != nil && item2 != nil {
		if !tv_equal((^Typval_T)(uintptr(item1) + 16), (^Typval_T)(uintptr(item2) + 16), ic) {
			return false
		}
		item1 = (^rawptr)(item1)^
		item2 = (^rawptr)(item2)^
	}
	return true
}

// Reverse list in-place.
@(export)
tv_list_reverse :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	if tv_list_len_o(l) <= 1 {
		return
	}
	first := (^rawptr)(l)^
	last := (^rawptr)(uintptr(l) + 8)^
	(^rawptr)(l)^ = last
	(^rawptr)(uintptr(l) + 8)^ = first
	li := last
	for li != nil {
		nx := (^rawptr)(li)^
		pv := (^rawptr)(uintptr(li) + 8)^
		(^rawptr)(li)^ = pv
		(^rawptr)(uintptr(li) + 8)^ = nx
		li = pv
	}
	(^C.int)(uintptr(l) + 64)^ = tv_list_len_o(l) - (^C.int)(uintptr(l) + 64)^ - 1
}

// Like tv_list_find() but a missing negative index falls back to zero.
tv_list_find_index_o :: proc "c" (l: rawptr, idx: ^C.int) -> rawptr {
	context = runtime.default_context()
	li := tv_list_find_e(l, idx^)
	if li != nil {
		return li
	}
	if idx^ < 0 {
		idx^ = 0
		li = tv_list_find_e(l, idx^)
	}
	return li
}

// —— Batch 21c: eval/typval.c join leaves ——
// Join mirror (typval.c:990): {String s (16B: data+size), tofree} = 24B.
Join_T :: struct {
	s_data: cstring,
	s_size: C.size_t,
	tofree: rawptr,
}
#assert(size_of(Join_T) == 24)

E_LISTREQ_S :: "E714: List required"

list_join_inner_o :: proc "c" (gap: ^Garray, l: rawptr, sep: cstring, join_gap: ^Garray) -> C.int {
	context = runtime.default_context()
	sumlen: C.size_t = 0
	first := true
	li := tv_list_first_o(l)
	for li != nil {
		if got_int {
			break
		}
		size: C.size_t = 0
		data := encode_tv2echo((^Typval_T)(uintptr(li) + 16), &size)
		if data == nil {
			return FAIL_E
		}
		sumlen += size
		ga_grow_r(join_gap, 1)
		p := &([^]Join_T)(join_gap.ga_data)[join_gap.ga_len]
		p.s_data = transmute(cstring)(data)
		p.s_size = size
		p.tofree = rawptr(data)
		join_gap.ga_len += 1
		line_breakcheck()
		li = (^rawptr)(li)^
	}
	seplen := C.size_t(libc.strlen(sep))
	if join_gap.ga_len >= 2 {
		sumlen += seplen * C.size_t(join_gap.ga_len - 1)
	}
	ga_grow_r(gap, C.int(sumlen) + 2)
	i: C.int = 0
	for i < join_gap.ga_len && !got_int {
		if first {
			first = false
		} else {
			ga_concat_len_r(gap, sep, seplen)
		}
		p := &([^]Join_T)(join_gap.ga_data)[i]
		if p.s_data != nil {
			ga_concat_len_r(gap, p.s_data, p.s_size)
		}
		line_breakcheck()
		i += 1
	}
	return OK_E
}

// —— Batch 21d: eval/typval.c list2str + concat ——

// "list2str()" function.
@(export)
f_list2str :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	if a0.v_type != VAR_LIST {
		emsg(e_invarg_s)
		return
	}
	l := (rawptr)(a0.vval)
	if l == nil {
		return
	}
	ga: Garray
	ga_init_r2(&ga, 1, 80)
	buf: [22]u8
	li := tv_list_first_o(l)
	for li != nil {
		n := tv_get_number((^Typval_T)(uintptr(li) + 16))
		buflen := utf_char2bytes(C.int(n), &buf[0])
		buf[buflen] = 0
		ga_concat_len_r(&ga, transmute(cstring)(&buf[0]), C.size_t(buflen))
		li = (^rawptr)(li)^
	}
	ga_append_r(&ga, 0)
	rettv.vval = ga.ga_data
}

// Concatenate lists into a new list (OK/FAIL).
@(export)
tv_list_concat :: proc "c" (l1: rawptr, l2: rawptr, tv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	l: rawptr = nil
	tv.v_type = VAR_LIST
	tv.v_lock = VAR_UNLOCKED
	if l1 == nil && l2 == nil {
		l = nil
	} else if l1 == nil {
		l = tv_list_copy(nil, l2, false, 0)
	} else {
		l = tv_list_copy(nil, l1, false, 0)
		if l != nil && l2 != nil {
			tv_list_extend(l, l2, nil)
		}
	}
	if l == nil && !(l1 == nil && l2 == nil) {
		return FAIL_E
	}
	tv.vval = l
	return OK_E
}

// —— Batch 21e: eval/typval.c callback family ——
foreign _ {
	@(link_name = "partial_unref")
	partial_unref_e :: proc "c" (pt: rawptr) ---
	@(link_name = "api_free_luaref")
	api_free_luaref_e :: proc "c" (ref: C.int) ---
	@(link_name = "api_new_luaref")
	api_new_luaref_e :: proc "c" (ref: C.int) -> C.int ---
	@(link_name = "nlua_funcref_str")
	nlua_funcref_str_e :: proc "c" (ref: C.int, arena: rawptr) -> ^u8 ---
}

KCB_NONE_O :: 0
KCB_FUNCREF_O :: 1
KCB_PARTIAL_O :: 2
KCB_LUA_O :: 3
LUA_NOREF_O :: -2

// Check whether two callbacks are equal.
@(export)
tv_callback_equal :: proc "c" (cb1: ^Callback_E, cb2: ^Callback_E) -> bool {
	context = runtime.default_context()
	if cb1.type != cb2.type {
		return false
	}
	if cb1.type == KCB_FUNCREF_O {
		return libc.strcmp(transmute(cstring)(cb1.data), transmute(cstring)(cb2.data)) == 0
	} else if cb1.type == KCB_PARTIAL_O {
		return cb1.data == cb2.data
	} else if cb1.type == KCB_LUA_O {
		return (^C.int)(&cb1.data)^ == (^C.int)(&cb2.data)^
	} else if cb1.type == KCB_NONE_O {
		return true
	}
	libc.abort()
}

// Unref/free callback.
@(export)
callback_free :: proc "c" (callback: ^Callback_E) {
	context = runtime.default_context()
	if callback.type == KCB_FUNCREF_O {
		func_unref(transmute(cstring)(callback.data))
		xfree(callback.data)
	} else if callback.type == KCB_PARTIAL_O {
		partial_unref_e(callback.data)
	} else if callback.type == KCB_LUA_O {
		ref := (^C.int)(&callback.data)^
		if ref != LUA_NOREF_O {
			api_free_luaref_e(ref)
			(^C.int)(&callback.data)^ = LUA_NOREF_O
		}
	}
	callback.type = KCB_NONE_O
	callback.data = nil
}

// Copy a callback into a typval_T.
@(export)
callback_put :: proc "c" (cb: ^Callback_E, tv: ^Typval_T) {
	context = runtime.default_context()
	if cb.type == KCB_PARTIAL_O {
		tv.v_type = VAR_PARTIAL
		tv.vval = transmute(rawptr)(cb.data)
		(^C.int)(cb.data)^ += 1
	} else if cb.type == KCB_FUNCREF_O {
		tv.v_type = VAR_FUNC
		tv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cb.data)))
		func_ref(transmute(cstring)(cb.data))
	} else {
		tv.v_type = VAR_SPECIAL
		tv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// Copy callback from "src" to "dest", incrementing the refcounts.
@(export)
callback_copy :: proc "c" (dest: ^Callback_E, src: ^Callback_E) {
	context = runtime.default_context()
	dest.type = src.type
	if src.type == KCB_PARTIAL_O {
		dest.data = src.data
		(^C.int)(dest.data)^ += 1
	} else if src.type == KCB_FUNCREF_O {
		dest.data = transmute(rawptr)(xstrdup_o(transmute(^u8)(src.data)))
		func_ref(transmute(cstring)(src.data))
	} else if src.type == KCB_LUA_O {
		(^C.int)(&dest.data)^ = api_new_luaref_e((^C.int)(&src.data)^)
	} else {
		dest.data = nil
	}
}

// Generate a string description of a callback.
@(export)
callback_to_string :: proc "c" (cb: ^Callback_E, arena: rawptr) -> ^u8 {
	context = runtime.default_context()
	if cb.type == KCB_LUA_O {
		return nlua_funcref_str_e((^C.int)(&cb.data)^, arena)
	}
	msg := ([^]u8)(xmallocz_r(100))
	if cb.type == KCB_FUNCREF_O {
		libc.snprintf(msg, 100, cstring("<vim function: %s>"), transmute(cstring)(cb.data))
	} else if cb.type == KCB_PARTIAL_O {
		pt_name := transmute(cstring)((^rawptr)(uintptr(cb.data) + 8)^)
		libc.snprintf(msg, 100, cstring("<vim partial: %s>"), pt_name)
	} else {
		msg[0] = 0
	}
	return &msg[0]
}

// —— Batch 21f: eval/typval.c dict-item + dict alloc ——
// dictitem_T: di_tv@0 (16B), di_flags@16, di_key@17; sizeof=24 (cc-probed).
E_INTERN2_S :: "E685: Internal error: %s"

// Allocate a dictionary item with key of given length.
@(export)
tv_dict_item_alloc_len :: proc "c" (key: cstring, key_len: C.size_t) -> rawptr {
	context = runtime.default_context()
	size := C.size_t(24)
	need := C.size_t(17) + key_len + 1
	if need > size {
		size = need
	}
	di := xmalloc(size)
	kb := ([^]u8)(di)
	libc.memcpy(rawptr(&kb[17]), rawptr(key), key_len)
	kb[C.size_t(17) + key_len] = 0
	kb[16] = DI_FLAGS_ALLOC_O
	(^C.int)(di)^ = VAR_UNKNOWN
	(^C.int)(uintptr(di) + 4)^ = VAR_UNLOCKED
	return di
}

// Allocate a dictionary item.
@(export)
tv_dict_item_alloc :: proc "c" (key: cstring) -> rawptr {
	context = runtime.default_context()
	return tv_dict_item_alloc_len(key, C.size_t(libc.strlen(key)))
}

// Free a dictionary item, also clearing the value.
@(export)
tv_dict_item_free :: proc "c" (item: rawptr) {
	context = runtime.default_context()
	tv_clear_e((^Typval_T)(item))
	if (^u8)(uintptr(item) + 16)^ & DI_FLAGS_ALLOC_O != 0 {
		xfree(item)
	}
}

// Make a copy of a dictionary item.
@(export)
tv_dict_item_copy :: proc "c" (di: rawptr) -> rawptr {
	context = runtime.default_context()
	new_di := tv_dict_item_alloc(transmute(cstring)(uintptr(di) + 17))
	tv_copy((^Typval_T)(di), (^Typval_T)(new_di))
	return new_di
}

// Remove item from dictionary and free it.
@(export)
tv_dict_item_remove :: proc "c" (dict: rawptr, item: rawptr) {
	context = runtime.default_context()
	ht := rawptr(uintptr(dict) + 16)
	hi := hash_find_r(ht, transmute(cstring)(uintptr(item) + 17))
	empty := hi == nil
	key: rawptr = nil
	if !empty {
		key = ([^]rawptr)(uintptr(hi))[1]
		empty = key == nil || key == rawptr(&hash_removed_c)
	}
	if empty {
		semsg(cstring(E_INTERN2_S), cstring("tv_dict_item_remove()"))
	} else {
		hash_remove_r(ht, hi)
	}
	tv_dict_item_free(item)
}

// Allocate an empty dictionary (caller owns the reference count).
@(export)
tv_dict_alloc :: proc "c" () -> rawptr {
	context = runtime.default_context()
	d := xcalloc(1, 360)
	if gc_first_dict != nil {
		(^rawptr)(uintptr(gc_first_dict) + 328)^ = d
	}
	(^rawptr)(uintptr(d) + 320)^ = gc_first_dict
	(^rawptr)(uintptr(d) + 328)^ = nil
	gc_first_dict = d
	hash_init_r(rawptr(uintptr(d) + 16))
	(^C.int)(d)^ = VAR_UNLOCKED
	(^C.int)(uintptr(d) + 4)^ = 0
	(^C.int)(uintptr(d) + 8)^ = 0
	(^C.int)(uintptr(d) + 12)^ = 0
	w := uintptr(d) + 336
	(^rawptr)(w)^ = rawptr(w)
	(^rawptr)(w + 8)^ = rawptr(w)
	(^C.int)(uintptr(d) + 352)^ = LUA_NOREF_O
	return d
}

// Free a dictionary itself, ignoring items it contains.
@(export)
tv_dict_free_dict :: proc "c" (d: rawptr) {
	context = runtime.default_context()
	prev := (^rawptr)(uintptr(d) + 328)^
	next := (^rawptr)(uintptr(d) + 320)^
	if prev == nil {
		gc_first_dict = next
	} else {
		(^rawptr)(uintptr(prev) + 320)^ = next
	}
	if next != nil {
		(^rawptr)(uintptr(next) + 328)^ = prev
	}
	api_free_luaref_e((^C.int)(uintptr(d) + 352)^)
	xfree(d)
}

// —— Batch 21g: eval/typval.c dict-free trio ——

// GC-guard flag (typval.c:136): while set, tv_dict_free() is a no-op.
@(export)
tv_in_free_unref_items: bool

// Cleanup for a DictWatcher instance.
tv_dict_watcher_free_o :: proc "c" (watcher: rawptr) {
	context = runtime.default_context()
	callback_free((^Callback_E)(watcher))
	xfree((^rawptr)(uintptr(watcher) + 16)^)
	xfree(watcher)
}

// Free items contained in a dictionary.
@(export)
tv_dict_free_contents :: proc "c" (d: rawptr) {
	context = runtime.default_context()
	ht := rawptr(uintptr(d) + 16)
	hash_lock_e(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		hash_remove_r(ht, rawptr(cur))
		tv_dict_item_free(rawptr(di))
	}
	wq := uintptr(d) + 336
	for (^rawptr)(wq)^ != rawptr(wq) {
		w := uintptr((^rawptr)(wq)^)
		wn := (^rawptr)(w)^
		wp := (^rawptr)(w + 8)^
		(^rawptr)(uintptr(wp))^ = wn
		(^rawptr)(uintptr(wn) + 8)^ = wp
		tv_dict_watcher_free_o(rawptr(w - 32))
	}
	hash_clear_e(ht)
	(^C.int)(uintptr(ht) + 28)^ -= 1
	hash_init_r(ht)
}

// Free a dictionary, including all items it contains.
@(export)
tv_dict_free :: proc "c" (d: rawptr) {
	context = runtime.default_context()
	if tv_in_free_unref_items {
		return
	}
	tv_dict_free_contents(d)
	tv_dict_free_dict(d)
}

// —— Batch 21h: eval/typval.c list-alloc side ——
// list_T 80B (cc-probed): first@0/last@8/watch@16/idx_item@24/copylist@32/
// used_next@40/used_prev@48/refcount@56/len@60/idx@64/copyID@68/lock@72/lua@76.
// listitem_T 32B: next@0/prev@8/tv@16.

// Allocate a list item (uninitialized).
tv_list_item_alloc_o :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return xmalloc(32)
}

// Allocate an empty list (caller owns the reference count).
@(export)
tv_list_alloc :: proc "c" (len: C.ssize_t) -> rawptr {
	context = runtime.default_context()
	list := xcalloc(1, 80)
	if gc_first_list != nil {
		(^rawptr)(uintptr(gc_first_list) + 48)^ = list
	}
	(^rawptr)(uintptr(list) + 48)^ = nil
	(^rawptr)(uintptr(list) + 40)^ = gc_first_list
	gc_first_list = list
	(^C.int)(uintptr(list) + 76)^ = LUA_NOREF_O
	return list
}

// Initialize a static list with 10 items.
@(export)
tv_list_init_static10 :: proc "c" (sl: rawptr) {
	context = runtime.default_context()
	l := uintptr(sl)
	libc.memset(sl, 0, 400)
	first := l + 80
	last := l + 80 + 32 * 9
	(^rawptr)(l)^ = rawptr(first)
	(^rawptr)(l + 8)^ = rawptr(last)
	(^C.int)(l + 56)^ = DO_NOT_FREE_CNT_O
	(^C.int)(l + 72)^ = VAR_FIXED_O
	(^C.int)(l + 60)^ = 10
	(^rawptr)(first + 8)^ = nil
	(^rawptr)(first)^ = rawptr(first + 32)
	(^rawptr)(last + 8)^ = rawptr(last - 32)
	(^rawptr)(last)^ = nil
	i := 1
	for i < 9 {
		li := first + uintptr(i) * 32
		(^rawptr)(li + 8)^ = rawptr(li - 32)
		(^rawptr)(li)^ = rawptr(li + 32)
		i += 1
	}
}

// Initialize static list with undefined number of elements.
@(export)
tv_list_init_static :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	libc.memset(l, 0, 80)
	(^C.int)(uintptr(l) + 56)^ = DO_NOT_FREE_CNT_O
}

// —— Batch 21i: eval/typval.c list-free side ——

// Free items contained in a list.
@(export)
tv_list_free_contents :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	for (^rawptr)(l)^ != nil {
		item := (^rawptr)(l)^
		(^rawptr)(l)^ = (^rawptr)(item)^
		tv_clear_e((^Typval_T)(uintptr(item) + 16))
		xfree(item)
	}
	(^C.int)(uintptr(l) + 60)^ = 0
	(^rawptr)(uintptr(l) + 24)^ = nil
	(^rawptr)(uintptr(l) + 8)^ = nil
}

// Free a list itself, ignoring items it contains.
@(export)
tv_list_free_list :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	prev := (^rawptr)(uintptr(l) + 48)^
	next := (^rawptr)(uintptr(l) + 40)^
	if prev == nil {
		gc_first_list = next
	} else {
		(^rawptr)(uintptr(prev) + 40)^ = next
	}
	if next != nil {
		(^rawptr)(uintptr(next) + 48)^ = prev
	}
	api_free_luaref_e((^C.int)(uintptr(l) + 76)^)
	xfree(l)
}

// —— Batch 21k: eval/typval.c dict-add scalar cluster ——
foreign _ {
	@(link_name = "hash_add")
	hash_add_e :: proc "c" (ht: rawptr, key: ^u8) -> C.int ---
	@(link_name = "get_globvar_dict")
	get_globvar_dict_e :: proc "c" () -> rawptr ---
	@(link_name = "get_funccal_local_ht")
	get_funccal_local_ht_e :: proc "c" () -> rawptr ---
	@(link_name = "var_wrong_func_name")
	var_wrong_func_name_e :: proc "c" (name: cstring, new_var: bool) -> bool ---
}

// Check for adding a function to g: or l: (true + error on bad name).
@(export)
tv_dict_wrong_func_name :: proc "c" (d: rawptr, tv: ^Typval_T, name: cstring) -> C.int {
	context = runtime.default_context()
	is_glob := d == get_globvar_dict_e()
	is_local := rawptr(uintptr(d) + 16) == get_funccal_local_ht_e()
	if (is_glob || is_local) && (tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL) && var_wrong_func_name_e(name, true) {
		return 1
	}
	return 0
}

// Add item to dictionary (FAIL if key exists or bad func name).
@(export)
tv_dict_add :: proc "c" (d: rawptr, item: rawptr) -> C.int {
	context = runtime.default_context()
	if tv_dict_wrong_func_name(d, (^Typval_T)(item), transmute(cstring)(uintptr(item) + 17)) != 0 {
		return FAIL_E
	}
	return hash_add_e(rawptr(uintptr(d) + 16), &([^]u8)(uintptr(item) + 17)[0])
}

// Add a number entry to dictionary.
@(export)
tv_dict_add_nr :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, nr: C.longlong) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_NUMBER
	(^C.longlong)(uintptr(item) + 8)^ = nr
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	return OK_E
}

// Add a floating point number entry to dictionary.
@(export)
tv_dict_add_float :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, nr: f64) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_FLOAT
	(^f64)(uintptr(item) + 8)^ = nr
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	return OK_E
}

// Add a boolean entry to dictionary.
@(export)
tv_dict_add_bool :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: C.int) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_BOOL
	(^C.int)(uintptr(item) + 8)^ = val
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	return OK_E
}

// Add a string entry to dictionary.
@(export)
tv_dict_add_str :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: cstring) -> C.int {
	context = runtime.default_context()
	return tv_dict_add_str_len(d, key, key_len, val, -1)
}

// Add a string entry to dictionary (len bytes, -1 for whole string).
@(export)
tv_dict_add_str_len :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: cstring, len: C.int) -> C.int {
	context = runtime.default_context()
	s: ^u8 = nil
	if val != nil {
		if len < 0 {
			s = xstrdup_o(transmute(^u8)(val))
		} else {
			s = xmemdupz_o2(transmute(^u8)(val), C.size_t(len))
		}
	}
	return tv_dict_add_allocated_str(d, key, key_len, s)
}

// Add a string entry to dictionary, taking over "val" (freed on failure).
@(export)
tv_dict_add_allocated_str :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: ^u8) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_STRING
	(^rawptr)(uintptr(item) + 8)^ = rawptr(val)
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	return OK_E
}

// —— Batch 21l: eval/typval.c dict-add balance ——

// Add a list entry to dictionary (refcount increased).
@(export)
tv_dict_add_list :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, list: rawptr) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_LIST
	(^rawptr)(uintptr(item) + 8)^ = list
	if tv_dict_add(d, item) == FAIL_E {
		(^rawptr)(uintptr(item) + 8)^ = nil
		tv_dict_item_free(item)
		return FAIL_E
	}
	tv_list_ref_o(list)
	return OK_E
}

// Add a dictionary entry to dictionary (refcount increased).
@(export)
tv_dict_add_dict :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, dict: rawptr) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_DICT
	(^rawptr)(uintptr(item) + 8)^ = dict
	if tv_dict_add(d, item) == FAIL_E {
		(^rawptr)(uintptr(item) + 8)^ = nil
		tv_dict_item_free(item)
		return FAIL_E
	}
	(^C.int)(uintptr(dict) + 8)^ += 1
	return OK_E
}

// Add a typval entry to dictionary (copied).
@(export)
tv_dict_add_tv :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, tv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	tv_copy(tv, (^Typval_T)(item))
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	return OK_E
}

// Clear all the keys of a Dictionary (remains valid and empty).
@(export)
tv_dict_clear :: proc "c" (d: rawptr) {
	context = runtime.default_context()
	ht := rawptr(uintptr(d) + 16)
	hash_lock_e(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		tv_dict_item_free(rawptr(uintptr(key) - 17))
		hash_remove_r(ht, rawptr(cur))
	}
	hash_unlock_e(ht)
}

// —— Batch 21u: eval/typval.c list extend ——

// Extend first list with the second (before "bef", NULL appends).
@(export)
tv_list_extend :: proc "c" (l1: rawptr, l2: rawptr, bef: rawptr) {
	context = runtime.default_context()
	todo := tv_list_len_o(l2)
	if todo == 0 {
		return
	}
	befbef: rawptr = nil
	if bef != nil {
		befbef = (^rawptr)(uintptr(bef) + 8)^
	}
	saved_next: rawptr = nil
	if befbef != nil {
		saved_next = (^rawptr)(befbef)^
	}
	item := tv_list_first_o(l2)
	for item != nil && todo > 0 {
		todo -= 1
		tv_list_insert_tv(l1, (^Typval_T)(uintptr(item) + 16), bef)
		if item == befbef {
			item = saved_next
		} else {
			item = (^rawptr)(item)^
		}
	}
}

// —— Batch 21v: eval/typval.c list slice ——

// Slice [n1..n2] of "ol" into a new list.
tv_list_slice_o :: proc "c" (ol: rawptr, n1: C.longlong, n2: C.longlong) -> rawptr {
	context = runtime.default_context()
	l := tv_list_alloc(C.ssize_t(n2 - n1 + 1))
	item := tv_list_find_e(ol, C.int(n1))
	n := n1
	for n <= n2 {
		tv_list_append_tv(l, (^Typval_T)(uintptr(item) + 16))
		item = (^rawptr)(item)^
		n += 1
	}
	return l
}

// Subscript a list: index or [n1..n2] range into rettv (OK/FAIL).
@(export)
tv_list_slice_or_index :: proc "c" (list: rawptr, is_range: bool, n1_arg: C.longlong, n2_arg: C.longlong, exclusive: bool, rettv: ^Typval_T, verbose: bool) -> C.int {
	context = runtime.default_context()
	len := C.longlong(tv_list_len_o((rawptr)(rettv.vval)))
	n1 := n1_arg
	n2 := n2_arg
	if n1 < 0 {
		n1 = len + n1
	}
	if n1 < 0 || n1 >= len {
		if !is_range {
			if verbose {
				semsg(cstring(E_LIST_OOR_S), n1_arg)
			}
			return FAIL_E
		}
		n1 = len
	}
	if is_range {
		if n2 < 0 {
			n2 = len + n2
		} else if n2 >= len {
			if exclusive {
				n2 = len
			} else {
				n2 = len - 1
			}
		}
		if exclusive {
			n2 -= 1
		}
		if n2 < 0 || n2 + 1 < n1 {
			n2 = -1
		}
		l := tv_list_slice_o((rawptr)(rettv.vval), n1, n2)
		tv_clear_e(rettv)
		tv_list_set_ret_o(rettv, l)
	} else {
		var1: Typval_T
		tv_copy((^Typval_T)(uintptr(tv_list_find_e((rawptr)(rettv.vval), C.int(n1))) + 16), &var1)
		tv_clear_e(rettv)
		rettv^ = var1
	}
	return OK_E
}

// —— Batch 21m: eval/typval.c dict extend + equal ——
foreign _ {
	@(link_name = "var2fpos")
	var2fpos_e :: proc "c" (tv: ^Typval_T, dollar_lnum: bool, ret_fnum: ^C.int, charcol: bool, wp: rawptr) -> rawptr ---
	@(link_name = "valid_varname")
	valid_varname_e :: proc "c" (varname: cstring) -> bool ---
}

E_KEY_EXISTS_S :: "E737: Key already exists: %s"
EXTEND_ARG_S :: "extend() argument"

// Number of items in a dictionary (0 for NULL).
tv_dict_len_o :: proc "c" (d: rawptr) -> C.size_t {
	context = runtime.default_context()
	if d == nil {
		return 0
	}
	return (^C.size_t)(uintptr(d) + 24)^
}

// Extend dictionary with items from another dictionary.
@(export)
tv_dict_extend :: proc "c" (d1: rawptr, d2: rawptr, action: cstring) {
	context = runtime.default_context()
	watched := tv_dict_is_watched_o(d1)
	arg_len := C.size_t(libc.strlen(cstring(EXTEND_ARG_S)))
	act := ([^]u8)(action)[0]
	if act == 'm' {
		hash_lock_e(rawptr(uintptr(d2) + 16))
	}
	ht2 := rawptr(uintptr(d2) + 16)
	todo := (^C.size_t)(uintptr(ht2) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht2) + 32)^)
	done := false
	for todo > 0 && !done {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di2 := uintptr(key) - 17
		di1 := uintptr(tv_dict_find_r(d1, transmute(cstring)(di2 + 17), -C.ssize_t(1)))
		if (^C.int)(uintptr(d1) + 4)^ != 0 && !valid_varname_e(transmute(cstring)(di2 + 17)) {
			done = true
		} else if di1 == 0 {
			if act == 'm' {
				new_di := rawptr(di2)
				if tv_dict_add(d1, new_di) == OK_E {
					hash_remove_r(ht2, rawptr(cur))
					tv_dict_watcher_notify_r(d1, transmute(cstring)(di2 + 17), (^Typval_T)(di2), nil)
				}
			} else {
				new_di := tv_dict_item_copy(rawptr(di2))
				if tv_dict_add(d1, new_di) == FAIL_E {
					tv_dict_item_free(new_di)
				} else if watched {
					tv_dict_watcher_notify_r(d1, transmute(cstring)(di2 + 17), (^Typval_T)(uintptr(new_di)), nil)
				}
			}
		} else if act == 'e' {
			semsg(cstring(E_KEY_EXISTS_S), transmute(cstring)(di2 + 17))
			done = true
		} else if act == 'f' && di2 != di1 {
			oldtv: Typval_T
			if value_check_lock((^C.int)(di1 + 4)^, cstring(EXTEND_ARG_S), arg_len) || var_check_ro_e(C.int((^u8)(di1 + 16)^), cstring(EXTEND_ARG_S), arg_len) {
				done = true
			} else {
				if tv_dict_wrong_func_name(d1, (^Typval_T)(di2), transmute(cstring)(di2 + 17)) != 0 {
					done = true
				} else {
					if watched {
						tv_copy((^Typval_T)(di1), &oldtv)
					}
					tv_clear_e((^Typval_T)(di1))
					tv_copy((^Typval_T)(di2), (^Typval_T)(di1))
					if watched {
						tv_dict_watcher_notify_r(d1, transmute(cstring)(di1 + 17), (^Typval_T)(di1), &oldtv)
						tv_clear_e(&oldtv)
					}
				}
			}
		}
	}
	if act == 'm' {
		hash_unlock_e(ht2)
	}
}

// Compare two dictionaries.
@(export)
tv_dict_equal :: proc "c" (d1: rawptr, d2: rawptr, ic: bool) -> bool {
	context = runtime.default_context()
	if d1 == d2 {
		return true
	}
	if tv_dict_len_o(d1) != tv_dict_len_o(d2) {
		return false
	}
	if tv_dict_len_o(d1) == 0 {
		return true
	}
	if d1 == nil || d2 == nil {
		return false
	}
	ht1 := rawptr(uintptr(d1) + 16)
	todo := (^C.size_t)(uintptr(ht1) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht1) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di1 := uintptr(key) - 17
		di2 := tv_dict_find_r(d2, transmute(cstring)(di1 + 17), -C.ssize_t(1))
		if di2 == nil {
			return false
		}
		if !tv_equal((^Typval_T)(di1), (^Typval_T)(di2), ic) {
			return false
		}
	}
	return true
}

// —— Batch 21n: eval/typval.c list copy + range checks ——
foreign _ {
	@(link_name = "var_item_copy")
	var_item_copy_e :: proc "c" (conv: rawptr, from: ^Typval_T, to: ^Typval_T, deep: bool, copyID: C.int) -> C.int ---
}

// Make a copy of list (deep via var_item_copy when "deep").
@(export)
tv_list_copy :: proc "c" (conv: rawptr, orig: rawptr, deep: bool, copyID: C.int) -> rawptr {
	context = runtime.default_context()
	if orig == nil {
		return nil
	}
	copy := tv_list_alloc(C.ssize_t(tv_list_len_o(orig)))
	tv_list_ref_o(copy)
	if copyID != 0 {
		(^C.int)(uintptr(orig) + 68)^ = copyID
		(^rawptr)(uintptr(orig) + 32)^ = copy
	}
	li := tv_list_first_o(orig)
	for li != nil {
		if got_int {
			break
		}
		ni := tv_list_item_alloc_o()
		if deep {
			if var_item_copy_e(conv, (^Typval_T)(uintptr(li) + 16), (^Typval_T)(uintptr(ni) + 16), deep, copyID) == FAIL_E {
				xfree(ni)
				tv_list_unref(copy)
				return nil
			}
		} else {
			tv_copy((^Typval_T)(uintptr(li) + 16), (^Typval_T)(uintptr(ni) + 16))
		}
		tv_list_append(copy, ni)
		li = (^rawptr)(li)^
	}
	return copy
}

// Get list item with adjusted index "n1" (NULL when missing).
@(export)
tv_list_check_range_index_one :: proc "c" (l: rawptr, n1: ^C.int, quiet: bool) -> rawptr {
	context = runtime.default_context()
	li := tv_list_find_index_o(l, n1)
	if li != nil {
		return li
	}
	if !quiet {
		semsg(cstring(E_LIST_OOR_S), C.longlong(n1^))
	}
	return nil
}

// Validate "n2" as second range index (normalizes negatives, OK/FAIL).
@(export)
tv_list_check_range_index_two :: proc "c" (l: rawptr, n1: ^C.int, li1: rawptr, n2: ^C.int, quiet: bool) -> C.int {
	context = runtime.default_context()
	if n2^ < 0 {
		ni := tv_list_find_e(l, n2^)
		if ni == nil {
			if !quiet {
				semsg(cstring(E_LIST_OOR_S), C.longlong(n2^))
			}
			return FAIL_E
		}
		n2^ = tv_list_idx_of_item(l, ni)
	}
	if n1^ < 0 {
		n1^ = tv_list_idx_of_item(l, li1)
	}
	if n2^ < n1^ {
		if !quiet {
			semsg(cstring(E_LIST_OOR_S), C.longlong(n2^))
		}
		return FAIL_E
	}
	return OK_E
}

// —— Batch 21x: eval/typval.c watchers + dict copy + readonly ——
foreign _ {
	@(link_name = "string_convert")
	string_convert_e :: proc "c" (conv: rawptr, ptr: cstring, lenp: ^C.size_t) -> ^u8 ---
}

// Add a watcher to a list.
@(export)
tv_list_watch_add :: proc "c" (l: rawptr, lw: rawptr) {
	context = runtime.default_context()
	(^rawptr)(lw)^ = (^rawptr)(uintptr(l) + 16)^
	(^rawptr)(uintptr(l) + 16)^ = lw
}

// Remove a watcher from a list (silent when absent).
@(export)
tv_list_watch_remove :: proc "c" (l: rawptr, lwrem: rawptr) {
	context = runtime.default_context()
	lwp := uintptr(l) + 16
	lw := (^rawptr)(uintptr(l) + 16)^
	for lw != nil {
		if lw == lwrem {
			(^rawptr)(lwp)^ = (^rawptr)(uintptr(lw) + 8)^
			break
		}
		lwp = uintptr(lw) + 8
		lw = (^rawptr)(uintptr(lw) + 8)^
	}
}

// Make a copy of dictionary (deep via var_item_copy when "deep").
@(export)
tv_dict_copy :: proc "c" (conv: rawptr, orig: rawptr, deep: bool, copyID: C.int) -> rawptr {
	context = runtime.default_context()
	if orig == nil {
		return nil
	}
	copy := tv_dict_alloc()
	if copyID != 0 {
		(^C.int)(uintptr(orig) + 12)^ = copyID
		(^rawptr)(uintptr(orig) + 312)^ = copy
	}
	ht := rawptr(uintptr(orig) + 16)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		if got_int {
			break
		}
		di := uintptr(key) - 17
		new_di: rawptr
		if conv == nil || (^C.int)(conv)^ == 0 {
			new_di = tv_dict_item_alloc(transmute(cstring)(di + 17))
		} else {
			ln := C.size_t(libc.strlen(transmute(cstring)(di + 17)))
			k := string_convert_e(conv, transmute(cstring)(di + 17), &ln)
			if k == nil {
				new_di = tv_dict_item_alloc_len(transmute(cstring)(di + 17), ln)
			} else {
				new_di = tv_dict_item_alloc_len(transmute(cstring)(k), ln)
				xfree(rawptr(k))
			}
		}
		if deep {
			if var_item_copy_e(conv, (^Typval_T)(di), (^Typval_T)(uintptr(new_di)), deep, copyID) == FAIL_E {
				xfree(new_di)
				break
			}
		} else {
			tv_copy((^Typval_T)(di), (^Typval_T)(uintptr(new_di)))
		}
		if tv_dict_add(copy, new_di) == FAIL_E {
			tv_dict_item_free(new_di)
			break
		}
	}
	(^C.int)(uintptr(copy) + 8)^ += 1
	if got_int {
		tv_dict_unref(copy)
		return nil
	}
	return copy
}

// Set all existing keys in "dict" as read-only.
@(export)
tv_dict_set_keys_readonly :: proc "c" (dict: rawptr) {
	context = runtime.default_context()
	ht := rawptr(uintptr(dict) + 16)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		(^u8)(uintptr(key) - 1)^ |= DI_FLAGS_RO_O | DI_FLAGS_FIX_O
	}
}

// —— Batch 21r: eval/typval.c blob lifecycle + checks ——
// blob_T 32B (cc-probed): bv_ga@0 (24B), bv_refcount@24, bv_lock@28.
E_BLOBIDX_S :: "E979: Blob index out of range: %ld"
E_BLOBLEN_S :: "E972: Blob value does not have the right number of bytes"

// Allocate an empty blob.
@(export)
tv_blob_alloc :: proc "c" () -> rawptr {
	context = runtime.default_context()
	blob := xcalloc(1, 32)
	ga_init_r2((^Garray)(blob), 1, 100)
	return blob
}

// Free a blob (ignores reference count).
@(export)
tv_blob_free :: proc "c" (b: rawptr) {
	context = runtime.default_context()
	ga_clear_r((^Garray)(b))
	xfree(b)
}

// Unreference a blob (frees at zero references).
@(export)
tv_blob_unref :: proc "c" (b: rawptr) {
	context = runtime.default_context()
	if b == nil {
		return
	}
	ref := (^C.int)(uintptr(b) + 24)^ - 1
	(^C.int)(uintptr(b) + 24)^ = ref
	if ref <= 0 {
		tv_blob_free(b)
	}
}

// Check whether two blobs are equal (empty and NULL are equal).
@(export)
tv_blob_equal :: proc "c" (b1: rawptr, b2: rawptr) -> bool {
	context = runtime.default_context()
	len1 := tv_blob_len_o(b1)
	len2 := tv_blob_len_o(b2)
	if len1 == 0 && len2 == 0 {
		return true
	}
	if b1 == b2 {
		return true
	}
	if len1 != len2 {
		return false
	}
	i: C.int = 0
	for i < (^Garray)(b1).ga_len {
		if tv_blob_get_o(b1, i) != tv_blob_get_o(b2, i) {
			return false
		}
		i += 1
	}
	return true
}

// Slice blob [n1..n2] into rettv (empty blob when out of range).
tv_blob_slice_o :: proc "c" (blob: rawptr, len: C.int, n1: C.longlong, n2: C.longlong, exclusive: bool, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	a := n1
	b := n2
	if a < 0 {
		a = C.longlong(len) + a
		if a < 0 {
			a = 0
		}
	}
	if b < 0 {
		b = C.longlong(len) + b
	} else if b >= C.longlong(len) {
		if exclusive {
			b = C.longlong(len)
		} else {
			b = C.longlong(len) - 1
		}
	}
	if exclusive {
		b -= 1
	}
	if a >= C.longlong(len) || b < 0 || a > b {
		tv_clear_e(rettv)
		rettv.v_type = VAR_BLOB
		rettv.vval = nil
	} else {
		new_blob := tv_blob_alloc()
		sz := C.int(b - a + 1)
		ga_grow_r((^Garray)(new_blob), sz)
		(^Garray)(new_blob).ga_len = sz
		i := C.int(a)
		for i <= C.int(b) {
			tv_blob_set_o(new_blob, i - C.int(a), tv_blob_get_o((rawptr)(rettv.vval), i))
			i += 1
		}
		tv_clear_e(rettv)
		tv_blob_set_ret_o(rettv, new_blob)
	}
	return OK_E
}

// Single blob index into rettv (FAIL + E979 when out of range).
tv_blob_index_o :: proc "c" (blob: rawptr, len: C.int, idx: C.longlong, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	i := idx
	if i < 0 {
		i = C.longlong(len) + i
	}
	if i < C.longlong(len) && i >= 0 {
		v := C.int(tv_blob_get_o((rawptr)(rettv.vval), C.int(i)))
		tv_clear_e(rettv)
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(v))
	} else {
		semsg(cstring(E_BLOBIDX_S), C.longlong(idx))
		return FAIL_E
	}
	return OK_E
}

// Blob slice (range) or index into rettv.
@(export)
tv_blob_slice_or_index :: proc "c" (blob: rawptr, is_range: bool, n1: C.longlong, n2: C.longlong, exclusive: bool, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	len := tv_blob_len_o((rawptr)(rettv.vval))
	if is_range {
		return tv_blob_slice_o(blob, len, n1, n2, exclusive, rettv)
	}
	return tv_blob_index_o(blob, len, n1, rettv)
}

// Check "n1" is a valid index for blob length "bloblen".
@(export)
tv_blob_check_index :: proc "c" (bloblen: C.int, n1: C.longlong, quiet: bool) -> C.int {
	context = runtime.default_context()
	if n1 < 0 || n1 > C.longlong(bloblen) {
		if !quiet {
			semsg(cstring(E_BLOBIDX_S), n1)
		}
		return FAIL_E
	}
	return OK_E
}

// Check "n1"-"n2" is a valid range for blob length "bloblen".
@(export)
tv_blob_check_range :: proc "c" (bloblen: C.int, n1: C.longlong, n2: C.longlong, quiet: bool) -> C.int {
	context = runtime.default_context()
	if n2 < 0 || n2 >= C.longlong(bloblen) || n2 < n1 {
		if !quiet {
			semsg(cstring(E_BLOBIDX_S), n2)
		}
		return FAIL_E
	}
	return OK_E
}

// Set bytes n1..n2 in "dest" from blob "src" (FAIL on length mismatch).
@(export)
tv_blob_set_range :: proc "c" (dest: rawptr, n1: C.longlong, n2: C.longlong, src: ^Typval_T) -> C.int {
	context = runtime.default_context()
	if n2 - n1 + 1 != C.longlong(tv_blob_len_o((rawptr)(src.vval))) {
		emsg(cstring(E_BLOBLEN_S))
		return FAIL_E
	}
	il := C.int(n1)
	ir: C.int = 0
	for il <= C.int(n2) {
		tv_blob_set_o(dest, il, tv_blob_get_o((rawptr)(src.vval), ir))
		il += 1
		ir += 1
	}
	return OK_E
}

// Store one byte at "idx" (appends when idx == length).
@(export)
tv_blob_set_append :: proc "c" (blob: rawptr, idx: C.int, byte: u8) {
	context = runtime.default_context()
	gap := (^Garray)(blob)
	if idx <= gap.ga_len {
		if idx == gap.ga_len {
			ga_grow_r(gap, 1)
			gap.ga_len += 1
		}
		tv_blob_set_o(blob, idx, byte)
	}
}

// —— Batch 22c: eval/typval.c arg validators ——
E_STRARG_S :: "E1174: String required for argument %d"
E_NONEMPTYSTRARG_S :: "E1175: Non-empty string required for argument %d"
E_DICTARG_S :: "E1206: Dictionary required for argument %d"
E_NUMARG_S :: "E1210: Number required for argument %d"
E_LISTARG2_S :: "E1211: List required for argument %d"
E_BOOLARG_S :: "E1212: Bool required for argument %d"
E_FLOATNRARG_S :: "E1219: Float or Number required for argument %d"
E_STRNRARG_S :: "E1220: String or Number required for argument %d"
E_STRLISTARG_S :: "E1222: String or List required for argument %d"
E_LISTBLOBARG2_S :: "E1226: List or Blob required for argument %d"
E_BLOBARG_S :: "E1238: Blob required for argument %d"
E_STRLISTBLOBARG_S :: "E1252: String, List or Blob required for argument %d"
E_STRFUNCARG_S :: "E1256: String or function required for argument %d"
E_NONNULLDICTARG_S :: "E1297: Non-NULL Dictionary required for argument %d"
E_LISTASSTR_S :: "E730: Using a List as a String"
E_DICTASSTR_S :: "E731: Using a Dictionary as a String"
E_BLOBASSTR_S :: "E976: Using a Blob as a String"
E_FUNCASNUM_S :: "E703: Using a Funcref as a Number"
E_BADSTRING_S :: "E908: Using an invalid value as a String"

// Arg at "idx" (Typval_T is 16B).
arg_at_o :: proc "c" (args: ^Typval_T, idx: C.int) -> ^Typval_T {
	context = runtime.default_context()
	return (^Typval_T)(uintptr(args) + uintptr(idx) * 16)
}

// FAIL unless args[idx] is a string.
@(export)
tv_check_for_string_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type != VAR_STRING {
		semsg(cstring(E_STRARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a non-empty string.
@(export)
tv_check_for_nonempty_string_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if tv_check_for_string_arg(args, idx) == FAIL_E {
		return FAIL_E
	}
	s := (rawptr)(arg_at_o(args, idx).vval)
	if s == nil || (^u8)(s)^ == 0 {
		semsg(cstring(E_NONEMPTYSTRARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// OK for missing (UNKNOWN) or string arg.
@(export)
tv_check_for_opt_string_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type == VAR_UNKNOWN || tv_check_for_string_arg(args, idx) != FAIL_E {
		return OK_E
	}
	return FAIL_E
}

// FAIL unless args[idx] is a number.
@(export)
tv_check_for_number_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type != VAR_NUMBER {
		semsg(cstring(E_NUMARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// OK for missing (UNKNOWN) or number arg.
@(export)
tv_check_for_opt_number_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type == VAR_UNKNOWN || tv_check_for_number_arg(args, idx) != FAIL_E {
		return OK_E
	}
	return FAIL_E
}

// FAIL unless args[idx] is a float or a number.
@(export)
tv_check_for_float_or_nr_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_FLOAT && t != VAR_NUMBER {
		semsg(cstring(E_FLOATNRARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a bool (or 0/1 number).
@(export)
tv_check_for_bool_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	tv := arg_at_o(args, idx)
	n := transmute(C.longlong)(tv.vval)
	if tv.v_type != VAR_BOOL && !(tv.v_type == VAR_NUMBER && (n == 0 || n == 1)) {
		semsg(cstring(E_BOOLARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// OK for missing (UNKNOWN) arg, else bool check.
@(export)
tv_check_for_opt_bool_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type == VAR_UNKNOWN {
		return OK_E
	}
	return tv_check_for_bool_arg(args, idx)
}

// FAIL unless args[idx] is a blob.
@(export)
tv_check_for_blob_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type != VAR_BLOB {
		semsg(cstring(E_BLOBARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a list.
@(export)
tv_check_for_list_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type != VAR_LIST {
		semsg(cstring(E_LISTARG2_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a dict.
@(export)
tv_check_for_dict_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type != VAR_DICT {
		semsg(cstring(E_DICTARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a non-NULL dict.
@(export)
tv_check_for_nonnull_dict_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if tv_check_for_dict_arg(args, idx) == FAIL_E {
		return FAIL_E
	}
	if (rawptr)(arg_at_o(args, idx).vval) == nil {
		semsg(cstring(E_NONNULLDICTARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// OK for missing (UNKNOWN) or dict arg.
@(export)
tv_check_for_opt_dict_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type == VAR_UNKNOWN || tv_check_for_dict_arg(args, idx) != FAIL_E {
		return OK_E
	}
	return FAIL_E
}

// FAIL unless args[idx] is a string or a number.
@(export)
tv_check_for_string_or_number_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_STRING && t != VAR_NUMBER {
		semsg(cstring(E_STRNRARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// Buffer number: number or string.
@(export)
tv_check_for_buffer_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	return tv_check_for_string_or_number_arg(args, idx)
}

// Line number: number or string.
@(export)
tv_check_for_lnum_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	return tv_check_for_string_or_number_arg(args, idx)
}

// FAIL unless args[idx] is a string or a list.
@(export)
tv_check_for_string_or_list_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_STRING && t != VAR_LIST {
		semsg(cstring(E_STRLISTARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a string, a list or a blob.
@(export)
tv_check_for_string_or_list_or_blob_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_STRING && t != VAR_LIST && t != VAR_BLOB {
		semsg(cstring(E_STRLISTBLOBARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// OK for missing (UNKNOWN) or string-or-list arg.
@(export)
tv_check_for_opt_string_or_list_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	if arg_at_o(args, idx).v_type == VAR_UNKNOWN || tv_check_for_string_or_list_arg(args, idx) != FAIL_E {
		return OK_E
	}
	return FAIL_E
}

// FAIL unless args[idx] is a string or a function reference.
@(export)
tv_check_for_string_or_func_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_PARTIAL && t != VAR_FUNC && t != VAR_STRING {
		semsg(cstring(E_STRFUNCARG_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// FAIL unless args[idx] is a list or a blob.
@(export)
tv_check_for_list_or_blob_arg :: proc "c" (args: ^Typval_T, idx: C.int) -> C.int {
	context = runtime.default_context()
	t := arg_at_o(args, idx).v_type
	if t != VAR_LIST && t != VAR_BLOB {
		semsg(cstring(E_LISTBLOBARG2_S), idx + 1)
		return FAIL_E
	}
	return OK_E
}

// String value of a "stringish" object (numbers via scratch buf).
@(export)
tv_get_string_buf_chk :: proc "c" (tv: ^Typval_T, buf: ^u8) -> cstring {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER {
		libc.snprintf(([^]u8)(buf), 65, cstring("%ld"), transmute(C.longlong)(tv.vval))
		return transmute(cstring)(buf)
	} else if tv.v_type == VAR_FLOAT {
		f := transmute(f64)(tv.vval)
		abs_f := f
		if abs_f < 0 {
			abs_f = -abs_f
		}
		bb := ([^]u8)(buf)
		if (abs_f >= 0.001 && abs_f < 10000000.0) || abs_f == 0.0 {
			n := int(libc.snprintf(bb, 65, cstring("%f"), f))
			tp := n - 1
			for tp > 2 && bb[tp] == '0' && bb[tp - 1] != '.' {
				libc.memmove(rawptr(&bb[tp]), rawptr(&bb[tp + 1]), C.size_t(n - tp))
				n -= 1
				tp -= 1
			}
		} else {
			n := int(libc.snprintf(bb, 65, cstring("%e"), f))
			tp := -1
			i := 0
			for i < n {
				if bb[i] == 'e' {
					tp = i
					break
				}
				i += 1
			}
			if tp >= 0 {
				if bb[tp + 1] == '+' {
					libc.memmove(rawptr(&bb[tp + 1]), rawptr(&bb[tp + 2]), C.size_t(n - tp - 1))
					n -= 1
				}
				j := 1
				if bb[tp + 1] == '-' {
					j = 2
				}
				for bb[tp + j] == '0' {
					libc.memmove(rawptr(&bb[tp + j]), rawptr(&bb[tp + j + 1]), C.size_t(n - tp - j))
					n -= 1
				}
				tp -= 1
			}
			if tp >= 0 {
				for tp > 2 && bb[tp] == '0' && bb[tp - 1] != '.' {
					libc.memmove(rawptr(&bb[tp]), rawptr(&bb[tp + 1]), C.size_t(n - tp))
					n -= 1
					tp -= 1
				}
			}
		}
		return transmute(cstring)(buf)
	} else if tv.v_type == VAR_STRING {
		s := (rawptr)(tv.vval)
		if s != nil {
			return transmute(cstring)(s)
		}
		return cstring("")
	} else if tv.v_type == VAR_BOOL {
		if transmute(C.longlong)(tv.vval) != 0 {
			libc.memcpy(rawptr(buf), rawptr(&v_true_str[0]), 7)
		} else {
			libc.memcpy(rawptr(buf), rawptr(&v_false_str[0]), 8)
		}
		return transmute(cstring)(buf)
	} else if tv.v_type == VAR_SPECIAL {
		libc.memcpy(rawptr(buf), rawptr(&v_null_str[0]), 7)
		return transmute(cstring)(buf)
	} else if tv.v_type == VAR_PARTIAL || tv.v_type == VAR_FUNC {
		emsg(cstring(E_FUNCASNUM_S))
		return nil
	} else if tv.v_type == VAR_LIST {
		emsg(cstring(E_LISTASSTR_S))
		return nil
	} else if tv.v_type == VAR_DICT {
		emsg(cstring(E_DICTASSTR_S))
		return nil
	} else if tv.v_type == VAR_BLOB {
		emsg(cstring(E_BLOBASSTR_S))
		return nil
	} else if tv.v_type == VAR_UNKNOWN {
		emsg(cstring(E_BADSTRING_S))
		return nil
	}
	libc.abort()
}

// —— Batch 22b: eval/typval.c tv_equal ——
foreign _ {
	@(link_name = "func_equal")
	func_equal_e :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, ic: bool) -> bool ---
}

@(private = "file")
tv_equal_recurse_cnt: C.int
@(private = "file")
tv_equal_recurse_limit: C.int

// Deep equality with recursion guard (recursive structures compare equal).
@(export)
tv_equal :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, ic: bool) -> bool {
	context = runtime.default_context()
	isf1 := tv1.v_type == VAR_FUNC || tv1.v_type == VAR_PARTIAL
	isf2 := tv2.v_type == VAR_FUNC || tv2.v_type == VAR_PARTIAL
	if !(isf1 && isf2) && tv1.v_type != tv2.v_type {
		return false
	}
	if tv_equal_recurse_cnt == 0 {
		tv_equal_recurse_limit = 1000
	}
	if tv_equal_recurse_cnt >= tv_equal_recurse_limit {
		tv_equal_recurse_limit -= 1
		return true
	}
	if tv1.v_type == VAR_LIST {
		tv_equal_recurse_cnt += 1
		r := tv_list_equal((rawptr)(tv1.vval), (rawptr)(tv2.vval), ic)
		tv_equal_recurse_cnt -= 1
		return r
	} else if tv1.v_type == VAR_DICT {
		tv_equal_recurse_cnt += 1
		r := tv_dict_equal((rawptr)(tv1.vval), (rawptr)(tv2.vval), ic)
		tv_equal_recurse_cnt -= 1
		return r
	} else if tv1.v_type == VAR_PARTIAL || tv1.v_type == VAR_FUNC {
		if (tv1.v_type == VAR_PARTIAL && (rawptr)(tv1.vval) == nil) || (tv2.v_type == VAR_PARTIAL && (rawptr)(tv2.vval) == nil) {
			return false
		}
		tv_equal_recurse_cnt += 1
		r := func_equal_e(tv1, tv2, ic)
		tv_equal_recurse_cnt -= 1
		return r
	} else if tv1.v_type == VAR_BLOB {
		return tv_blob_equal((rawptr)(tv1.vval), (rawptr)(tv2.vval))
	} else if tv1.v_type == VAR_NUMBER {
		return transmute(C.longlong)(tv1.vval) == transmute(C.longlong)(tv2.vval)
	} else if tv1.v_type == VAR_FLOAT {
		return transmute(f64)(tv1.vval) == transmute(f64)(tv2.vval)
	} else if tv1.v_type == VAR_STRING {
		buf1: [65]u8
		buf2: [65]u8
		s1 := tv_get_string_buf(tv1, &buf1[0])
		s2 := tv_get_string_buf(tv2, &buf2[0])
		return mb_strcmp_ic_r(ic, s1, s2) == 0
	} else if tv1.v_type == VAR_BOOL {
		return C.int(transmute(C.longlong)(tv1.vval)) == C.int(transmute(C.longlong)(tv2.vval))
	} else if tv1.v_type == VAR_SPECIAL {
		return C.int(transmute(C.longlong)(tv1.vval)) == C.int(transmute(C.longlong)(tv2.vval))
	} else if tv1.v_type == VAR_UNKNOWN {
		return false
	}
	libc.abort()
}

// —— Batch 22a: eval/typval.c free + copy ——

// Free allocated Vimscript object and value inside (then the typval).
@(export)
tv_free :: proc "c" (tv: ^Typval_T) {
	context = runtime.default_context()
	if tv == nil {
		return
	}
	if tv.v_type == VAR_PARTIAL {
		partial_unref_e((rawptr)(tv.vval))
	} else if tv.v_type == VAR_FUNC {
		func_unref(transmute(cstring)((rawptr)(tv.vval)))
		xfree((rawptr)(tv.vval))
	} else if tv.v_type == VAR_STRING {
		xfree((rawptr)(tv.vval))
	} else if tv.v_type == VAR_BLOB {
		tv_blob_unref((rawptr)(tv.vval))
	} else if tv.v_type == VAR_LIST {
		tv_list_unref((rawptr)(tv.vval))
	} else if tv.v_type == VAR_DICT {
		tv_dict_unref((rawptr)(tv.vval))
	}
	xfree(rawptr(tv))
}

// Copy typval (strings duplicated, containers refcounted, not deep).
@(export)
tv_copy :: proc "c" (from: ^Typval_T, to: ^Typval_T) {
	context = runtime.default_context()
	to.v_type = from.v_type
	to.v_lock = VAR_UNLOCKED
	to.vval = from.vval
	if from.v_type == VAR_STRING || from.v_type == VAR_FUNC {
		if (rawptr)(from.vval) != nil {
			to.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)((rawptr)(from.vval))))
			if from.v_type == VAR_FUNC {
				func_ref(transmute(cstring)((rawptr)(to.vval)))
			}
		}
	} else if from.v_type == VAR_PARTIAL {
		if (rawptr)(to.vval) != nil {
			(^C.int)(to.vval)^ += 1
		}
	} else if from.v_type == VAR_BLOB {
		if (rawptr)(from.vval) != nil {
			(^C.int)(uintptr(from.vval) + 24)^ += 1
		}
	} else if from.v_type == VAR_LIST {
		tv_list_ref_o((rawptr)(to.vval))
	} else if from.v_type == VAR_DICT {
		if (rawptr)(from.vval) != nil {
			(^C.int)(uintptr(from.vval) + 8)^ += 1
		}
	} else if from.v_type == VAR_UNKNOWN {
		semsg(cstring(E_INTERN2_S), cstring("tv_copy(UNKNOWN)"))
	}
}

// Allocate a blob and set it as rettv's value (returns the blob).
@(export)
tv_blob_alloc_ret :: proc "c" (rettv: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	blob := tv_blob_alloc()
	tv_blob_set_ret_o(rettv, blob)
	return blob
}

// —— Batch 21q: eval/typval.c add_func + flatten ——
// ufunc_T (cc-probed): uf_namelen@232 (size_t), uf_name@240 (flex).

// Add a function entry to dictionary.
@(export)
tv_dict_add_func :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, fp: rawptr) -> C.int {
	context = runtime.default_context()
	item := tv_dict_item_alloc_len(key, key_len)
	(^Typval_T)(item).v_type = VAR_FUNC
	namelen := (^C.size_t)(uintptr(fp) + 232)^
	name := rawptr(uintptr(fp) + 240)
	s := xmemdupz_o2(transmute(^u8)(name), namelen)
	(^rawptr)(uintptr(item) + 8)^ = rawptr(s)
	if tv_dict_add(d, item) == FAIL_E {
		tv_dict_item_free(item)
		return FAIL_E
	}
	func_ref(transmute(cstring)(s))
	return OK_E
}

// Flatten nested lists up to maxdepth (void: nothing when maxdepth == 0).
@(export)
tv_list_flatten :: proc "c" (list: rawptr, first: rawptr, maxitems: C.longlong, maxdepth: C.longlong) {
	context = runtime.default_context()
	done: C.longlong = 0
	if maxdepth == 0 {
		return
	}
	item := first
	if item == nil {
		item = (^rawptr)(list)^
	}
	for item != nil && done < maxitems {
		next := (^rawptr)(item)^
		fast_breakcheck()
		if got_int {
			return
		}
		if (^C.int)(uintptr(item) + 16)^ == VAR_LIST {
			itemlist := (^rawptr)(uintptr(item) + 24)^
			tv_list_drop_items(list, item, item)
			tv_list_extend(list, itemlist, next)
			if maxdepth > 0 {
				prev := (^rawptr)(uintptr(item) + 8)^
				sub := (^rawptr)(list)^
				if prev != nil {
					sub = (^rawptr)(prev)^
				}
				tv_list_flatten(list, sub, C.longlong((^C.int)(uintptr(itemlist) + 60)^), maxdepth - 1)
			}
			tv_clear_e((^Typval_T)(uintptr(item) + 16))
			xfree(item)
		}
		done += 1
		item = next
	}
}

// —— Batch 21o: eval/typval.c dict-string getters + to_env ——
foreign _ {
	@(link_name = "set_selfdict")
	set_selfdict_e :: proc "c" (rettv: ^Typval_T, selfdict: rawptr) ---
}

E_FUNCNAME_S :: "E6000: Argument is not a function or function name"

// Static scratch for tv_dict_get_string (mirrors C's function-static).
@(private = "file")
get_string_numbuf: [65]u8

// Literal bytes for bool/special names (STRCPY semantics, NUL included).
@(private = "file")
v_true_str: [7]u8 = {'v', ':', 't', 'r', 'u', 'e', 0}
@(private = "file")
v_false_str: [8]u8 = {'v', ':', 'f', 'a', 'l', 's', 'e', 0}
@(private = "file")
v_null_str: [7]u8 = {'v', ':', 'n', 'u', 'l', 'l', 0}

// Convert a dict to a "key=value" environment array (NULL-terminated).
@(export)
tv_dict_to_env :: proc "c" (denv: rawptr) -> ^^u8 {
	context = runtime.default_context()
	env_size := tv_dict_len_o(denv)
	env := ([^]cstring)(xmalloc(C.size_t(env_size + 1) * 8))
	i: C.size_t = 0
	ht := rawptr(uintptr(denv) + 16)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed_c) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		str := tv_get_string((^Typval_T)(di))
		klen := C.size_t(libc.strlen(transmute(cstring)(di + 17)))
		slen := C.size_t(libc.strlen(str))
		e := ([^]u8)(xmalloc(klen + slen + 2))
		libc.memcpy(rawptr(e), rawptr(di + 17), klen)
		e[klen] = '='
		libc.memcpy(rawptr(uintptr(e) + uintptr(klen) + 1), rawptr(str), slen + 1)
		env[i] = transmute(cstring)(e)
		i += 1
	}
	env[env_size] = nil
	return transmute(^^u8)(env)
}

// Get a string item from a dictionary (buf scratch for non-strings).
@(export)
tv_dict_get_string_buf :: proc "c" (d: rawptr, key: cstring, numbuf: ^u8) -> cstring {
	context = runtime.default_context()
	di := tv_dict_find_r(d, key, -C.ssize_t(1))
	if di == nil {
		return nil
	}
	return tv_get_string_buf((^Typval_T)(di), numbuf)
}

// Get a string item (saved copy when "save", static scratch otherwise).
@(export)
tv_dict_get_string :: proc "c" (d: rawptr, key: cstring, save: bool) -> cstring {
	context = runtime.default_context()
	s := tv_dict_get_string_buf(d, key, &get_string_numbuf[0])
	if save && s != nil {
		return transmute(cstring)(xstrdup_o(transmute(^u8)(s)))
	}
	return s
}

// Get a string item with key length and default.
@(export)
tv_dict_get_string_buf_chk :: proc "c" (d: rawptr, key: cstring, key_len: C.ptrdiff_t, numbuf: ^u8, def: cstring) -> cstring {
	context = runtime.default_context()
	di := tv_dict_find_r(d, key, C.ssize_t(key_len))
	if di == nil {
		return def
	}
	return tv_get_string_buf_chk((^Typval_T)(di), numbuf)
}

// Get a callback from a dictionary (true on success/missing).
@(export)
tv_dict_get_callback :: proc "c" (d: rawptr, key: cstring, key_len: C.ptrdiff_t, result: ^Callback_E) -> bool {
	context = runtime.default_context()
	result.type = KCB_NONE_O
	di := tv_dict_find_r(d, key, C.ssize_t(key_len))
	if di == nil {
		return true
	}
	tv := (^Typval_T)(di)
	if tv.v_type != VAR_FUNC && tv.v_type != VAR_STRING {
		emsg(cstring(E_FUNCNAME_S))
		return false
	}
	newtv: Typval_T
	tv_copy(tv, &newtv)
	set_selfdict_e(&newtv, d)
	res := callback_from_typval_e(result, &newtv)
	tv_clear_e(&newtv)
	return res
}

// Free a list, including all items it contains.
@(export)
tv_list_free :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	if tv_in_free_unref_items {
		return
	}
	tv_list_free_contents(l)
	tv_list_free_list(l)
}

// Unreference a list (frees at zero references).
@(export)
tv_list_unref :: proc "c" (l: rawptr) {
	context = runtime.default_context()
	if l == nil {
		return
	}
	ref := (^C.int)(uintptr(l) + 56)^ - 1
	(^C.int)(uintptr(l) + 56)^ = ref
	if ref <= 0 {
		tv_list_free(l)
	}
}

// —— Batch 21j: eval/typval.c list add/remove ——

// Advance watchers to the next item (before removing an item).
tv_list_watch_fix_o :: proc "c" (l: rawptr, item: rawptr) {
	context = runtime.default_context()
	lw := (^rawptr)(uintptr(l) + 16)^
	for lw != nil {
		if (^rawptr)(lw)^ == item {
			(^rawptr)(lw)^ = (^rawptr)(item)^
		}
		lw = (^rawptr)(uintptr(lw) + 8)^
	}
}

// Remove items "item" to "item2" from list "l" (does not free).
@(export)
tv_list_drop_items :: proc "c" (l: rawptr, item: rawptr, item2: rawptr) {
	context = runtime.default_context()
	end := (^rawptr)(uintptr(item2))^
	ip := item
	for ip != end {
		(^C.int)(uintptr(l) + 60)^ -= 1
		tv_list_watch_fix_o(l, ip)
		ip = (^rawptr)(ip)^
	}
	i2next := (^rawptr)(uintptr(item2))^
	if i2next == nil {
		(^rawptr)(uintptr(l) + 8)^ = (^rawptr)(uintptr(item) + 8)^
	} else {
		(^rawptr)(uintptr(i2next) + 8)^ = (^rawptr)(uintptr(item) + 8)^
	}
	if (^rawptr)(uintptr(item) + 8)^ == nil {
		(^rawptr)(l)^ = i2next
	} else {
		(^rawptr)(uintptr((^rawptr)(uintptr(item) + 8)^))^ = i2next
	}
	(^rawptr)(uintptr(l) + 24)^ = nil
}

// Like tv_list_drop_items, but also frees all removed items.
@(export)
tv_list_remove_items :: proc "c" (l: rawptr, item: rawptr, item2: rawptr) {
	context = runtime.default_context()
	tv_list_drop_items(l, item, item2)
	li := item
	for {
		tv_clear_e((^Typval_T)(uintptr(li) + 16))
		nli := (^rawptr)(li)^
		xfree(li)
		if li == item2 {
			break
		}
		li = nli
	}
}

// Move items "item" to "item2" from list "l" to the end of "tgt_l".
@(export)
tv_list_move_items :: proc "c" (l: rawptr, item: rawptr, item2: rawptr, tgt_l: rawptr, cnt: C.int) {
	context = runtime.default_context()
	tv_list_drop_items(l, item, item2)
	(^rawptr)(uintptr(item) + 8)^ = (^rawptr)(uintptr(tgt_l) + 8)^
	(^rawptr)(uintptr(item2))^ = nil
	if (^rawptr)(uintptr(tgt_l) + 8)^ == nil {
		(^rawptr)(tgt_l)^ = item
	} else {
		(^rawptr)((^rawptr)(uintptr(tgt_l) + 8)^)^ = item
	}
	(^rawptr)(uintptr(tgt_l) + 8)^ = item2
	(^C.int)(uintptr(tgt_l) + 60)^ += cnt
}

// Insert list item "ni" before "item" (NULL appends at end).
@(export)
tv_list_insert :: proc "c" (l: rawptr, ni: rawptr, item: rawptr) {
	context = runtime.default_context()
	if item == nil {
		tv_list_append(l, ni)
	} else {
		(^rawptr)(uintptr(ni) + 8)^ = (^rawptr)(uintptr(item) + 8)^
		(^rawptr)(ni)^ = item
		if (^rawptr)(uintptr(item) + 8)^ == nil {
			(^rawptr)(l)^ = ni
			(^C.int)(uintptr(l) + 64)^ += 1
		} else {
			(^rawptr)((^rawptr)(uintptr(item) + 8)^)^ = ni
			(^rawptr)(uintptr(l) + 24)^ = nil
		}
		(^rawptr)(uintptr(item) + 8)^ = ni
		(^C.int)(uintptr(l) + 60)^ += 1
	}
}

// Insert Vimscript value into a list (copied).
@(export)
tv_list_insert_tv :: proc "c" (l: rawptr, tv: ^Typval_T, item: rawptr) {
	context = runtime.default_context()
	ni := tv_list_item_alloc_o()
	tv_copy(tv, (^Typval_T)(uintptr(ni) + 16))
	tv_list_insert(l, ni, item)
}

// Append item to the end of list.
@(export)
tv_list_append :: proc "c" (l: rawptr, item: rawptr) {
	context = runtime.default_context()
	if (^rawptr)(uintptr(l) + 8)^ == nil {
		(^rawptr)(l)^ = item
		(^rawptr)(uintptr(l) + 8)^ = item
		(^rawptr)(uintptr(item) + 8)^ = nil
	} else {
		last := (^rawptr)(uintptr(l) + 8)^
		(^rawptr)(uintptr(last))^ = item
		(^rawptr)(uintptr(item) + 8)^ = last
		(^rawptr)(uintptr(l) + 8)^ = item
	}
	(^C.int)(uintptr(l) + 60)^ += 1
	(^rawptr)(item)^ = nil
}

// Append Vimscript value to the end of list (copied).
@(export)
tv_list_append_tv :: proc "c" (l: rawptr, tv: ^Typval_T) {
	context = runtime.default_context()
	li := tv_list_item_alloc_o()
	tv_copy(tv, (^Typval_T)(uintptr(li) + 16))
	tv_list_append(l, li)
}

// Like tv_list_append_tv(), but tv is moved into the list.
@(export)
tv_list_append_owned_tv :: proc "c" (l: rawptr, tv: Typval_T) -> rawptr {
	context = runtime.default_context()
	li := tv_list_item_alloc_o()
	(^Typval_T)(uintptr(li) + 16)^ = tv
	tv_list_append(l, li)
	return (^Typval_T)(uintptr(li) + 16)
}

// Append a list to a list as one item (refcount increased).
@(export)
tv_list_append_list :: proc "c" (l: rawptr, l2: rawptr) {
	context = runtime.default_context()
	newtv := Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = l2}
	tv_list_append_owned_tv(l, newtv)
	tv_list_ref_o(l2)
}

// Append a dictionary to a list (refcount increased).
@(export)
tv_list_append_dict :: proc "c" (l: rawptr, dict: rawptr) {
	context = runtime.default_context()
	newtv := Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = dict}
	tv_list_append_owned_tv(l, newtv)
	if dict != nil {
		(^C.int)(uintptr(dict) + 8)^ += 1
	}
}

// Make a copy of "str" and append it as an item to list "l".
@(export)
tv_list_append_string :: proc "c" (l: rawptr, str: ^u8, len: C.ssize_t) {
	context = runtime.default_context()
	s: ^u8 = nil
	if str != nil {
		if len >= 0 {
			s = xmemdupz_o2(str, C.size_t(len))
		} else {
			s = xstrdup_o(str)
		}
	}
	newtv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(s)}
	tv_list_append_owned_tv(l, newtv)
}

// Append given string to the list (not copied).
@(export)
tv_list_append_allocated_string :: proc "c" (l: rawptr, str: ^u8) {
	context = runtime.default_context()
	newtv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(str)}
	tv_list_append_owned_tv(l, newtv)
}

// Append number to the list.
@(export)
tv_list_append_number :: proc "c" (l: rawptr, n: C.longlong) {
	context = runtime.default_context()
	newtv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(n)}
	tv_list_append_owned_tv(l, newtv)
}

// Unreference a dictionary (frees at zero references).
@(export)
tv_dict_unref :: proc "c" (d: rawptr) {
	context = runtime.default_context()
	if d == nil {
		return
	}
	ref := (^C.int)(uintptr(d) + 8)^ - 1
	(^C.int)(uintptr(d) + 8)^ = ref
	if ref <= 0 {
		tv_dict_free(d)
	}
}

// Join list into a string using given separator (OK/FAIL).
@(export)
tv_list_join :: proc "c" (gap: ^Garray, l: rawptr, sep: cstring) -> C.int {
	context = runtime.default_context()
	if tv_list_len_o(l) == 0 {
		return OK_E
	}
	join_ga: Garray
	ga_init_r2(&join_ga, C.int(size_of(Join_T)), tv_list_len_o(l))
	retval := list_join_inner_o(gap, l, sep, &join_ga)
	i: C.int = 0
	for i < join_ga.ga_len {
		xfree(([^]Join_T)(join_ga.ga_data)[i].tofree)
		i += 1
	}
	ga_clear_r(&join_ga)
	return retval
}

// "join()" function.
@(export)
f_join :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (^Typval_T)(uintptr(argvars))
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if a0.v_type != VAR_LIST {
		emsg(cstring(E_LISTREQ_S))
		return
	}
	sep := cstring(" ")
	if a1.v_type != VAR_UNKNOWN {
		sep = tv_get_string_chk(a1)
	}
	rettv.v_type = VAR_STRING
	if sep != nil {
		ga: Garray
		ga_init_r2(&ga, 1, 80)
		tv_list_join(&ga, (rawptr)(a0.vval), sep)
		ga_append_r(&ga, 0)
		rettv.vval = ga.ga_data
	} else {
		rettv.vval = nil
	}
}

// —— Batch 23b: eval/encode.c tv2 wrappers ——
foreign _ {
	@(link_name = "encode_vim_to_echo")
	encode_vim_to_echo_e :: proc "c" (gap: ^Garray, tv: ^Typval_T, objname: cstring) -> C.int ---
	@(link_name = "nvim_odin_reset_echo_emsg")
	reset_echo_emsg_e :: proc "c" () ---
}

// String representation without quotes (echo display).
@(export)
encode_tv2echo :: proc "c" (tv: ^Typval_T, len: ^C.size_t) -> ^u8 {
	context = runtime.default_context()
	ga: Garray
	ga_init_r2(&ga, 1, 80)
	if tv.v_type == VAR_STRING || tv.v_type == VAR_FUNC {
		s := (rawptr)(tv.vval)
		if s != nil {
			ga_concat_e(&ga, transmute(cstring)(s))
		}
	} else {
		encode_vim_to_echo_e(&ga, tv, cstring(":echo argument"))
	}
	if len != nil {
		len^ = C.size_t(ga.ga_len)
	}
	ga_append_r(&ga, 0)
	return ([^]u8)(ga.ga_data)
}

// —— Batch 23c: eval/decode.c string + special-dict ——

// Build {"_TYPE": <typelist>, "_VAL": val} special dict.
create_special_dict_o :: proc "c" (rettv: ^Typval_T, type: C.int, val: Typval_T) {
	context = runtime.default_context()
	dict := tv_dict_alloc()
	type_di := tv_dict_item_alloc_len(cstring("_TYPE"), 5)
	(^Typval_T)(type_di).v_type = VAR_LIST
	(^Typval_T)(type_di).v_lock = VAR_UNLOCKED
	(^rawptr)(uintptr(type_di) + 8)^ = eval_msgpack_type_lists_e[type]
	tv_list_ref_o((^rawptr)(uintptr(type_di) + 8)^)
	tv_dict_add(dict, type_di)
	val_di := tv_dict_item_alloc_len(cstring("_VAL"), 4)
	(^Typval_T)(val_di)^ = val
	tv_dict_add(dict, val_di)
	(^C.int)(uintptr(dict) + 8)^ += 1
	rettv^ = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(dict)}
}

// Create map special dict holding an empty list of length "len".
@(export)
decode_create_map_special_dict :: proc "c" (ret_tv: ^Typval_T, len: C.ptrdiff_t) -> rawptr {
	context = runtime.default_context()
	list := tv_list_alloc(C.ssize_t(len))
	tv_list_ref_o(list)
	val := Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(list)}
	create_special_dict_o(ret_tv, KMPMAP_O, val)
	return list
}

// Decode char string to typval (NUL bytes force blob).
@(export)
decode_string :: proc "c" (s: cstring, len: C.size_t, force_blob: bool, s_allocated: bool) -> Typval_T {
	context = runtime.default_context()
	sp := rawptr(s)
	use_blob := force_blob || (sp != nil && libc.memchr(sp, 0, len) != nil)
	if use_blob {
		tv := Typval_T{v_lock = VAR_UNLOCKED}
		b := tv_blob_alloc_ret(&tv)
		if s_allocated {
			(^rawptr)(uintptr(b) + 16)^ = sp
			(^C.int)(uintptr(b))^ = C.int(len)
			(^C.int)(uintptr(b) + 4)^ = C.int(len)
		} else {
			ga_concat_len_r((^Garray)(b), s, len)
		}
		return tv
	}
	if sp == nil || s_allocated {
		return Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(sp)}
	}
	return Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(sp), len))}
}
