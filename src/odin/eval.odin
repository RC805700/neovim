// eval.odin — Odin port of src/nvim/eval/ (Vimscript engine).
//
// Batch 1: eval/gc.c — 2 globals (gc_first_dict/gc_first_list).
// Batch 2: eval/executor.c — eexe_mod_op + 6 tv_op_* statics.

package main

import "base:runtime"
import C "core:c"
import "core:c/libc"
import "core:sys/posix"

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
		ga_grow((^Garray)(b1), blen)
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
		tv_clear(tv1)
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
			n = num_divide(n, tv_get_number(tv2))
		} else if o == '%' {
			n = num_modulus(n, tv_get_number(tv2))
		}
		tv_clear(tv1)
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
	if grow_string_tv(tv1, s2) == OK_E {
		return OK_E
	}
	tvs := tv_get_string(tv1)
	s := concat_str_c(tvs, s2)
	tv_clear(tv1)
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
	@(link_name = "reverse_text")
	reverse_text_e :: proc "c" (s: ^u8) -> ^u8 ---
	// channel_job_start/create_event/close now defined in channel.odin — call directly.
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
	chan := channel_job_start(transmute(rawptr)(argv), nil, cri, cri, Callback_E{}, false, true, false, false, 0, nil, 0, 0, nil, rawptr(&rettv.vval))
	if chan != nil {
		channel_create_event(chan, nil)
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
	id := u64(transmute(C.longlong)(a0.vval))
	if find_job(id, false) != nil {
		f_jobstop(argvars, rettv, fptr)
	} else {
		err: cstring
		ok := channel_close(id, 3, &err) // kChannelPartRpc
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
	f_jobstart(argvars, rettv, fptr)
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
				ga_append((^Garray)(b), u8(n))
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
	li := tv_list_find(l, C.int(idx))
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
		if key == nil || key == rawptr(&hash_removed) {
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
	tv_copy(tv, 	get_vim_var_tv(VV_VAL_O))
	newtv.v_type = VAR_UNKNOWN
	if filtermap == FILTERMAP_FOREACH_O && expr.v_type == VAR_STRING {
		// foreach() is not limited to an expression.
		do_cmdline_cmd(transmute(cstring)((rawptr)(expr.vval)))
		if did_emsg_flag == 0 {
			retval = OK_E
		}
	} else {
		argv: [3]Typval_T
		argv[0] = 	get_vim_var_tv(VV_KEY_O)^
		argv[1] = 	get_vim_var_tv(VV_VAL_O)^
		if eval_expr_typval(expr, false, &argv[0], 2, newtv) != FAIL_E {
			if filtermap == FILTERMAP_FILTER_O {
				err := false
				remp^ = tv_get_number_chk(newtv, &err) == 0
				tv_clear(newtv)
				if !err {
					retval = OK_E
				}
			} else {
				if filtermap == FILTERMAP_FOREACH_O {
					tv_clear(newtv)
				}
				retval = OK_E
			}
		}
	}
	tv_clear(	get_vim_var_tv(VV_VAL_O))
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
		if key == nil || key == rawptr(&hash_removed) {
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
				var_check_ro(C.int(([^]u8)(di)[16]), s.arg_errmsg, max(C.size_t)) {
			s.failed = true
			return false
		}
	}
		set_vim_var_string(VV_KEY_O, transmute(cstring)(rawptr(uintptr(di) + 17)), -1)
	newtv := Typval_T{}
	rem := false
	r := filter_map_one_o((^Typval_T)(di), s.expr, fm, &newtv, &rem)
	tv_clear(	get_vim_var_tv(VV_KEY_O))
	if r == FAIL_E || did_emsg_flag != 0 {
		tv_clear(&newtv)
		s.failed = true
		return false
	}
	if fm == FILTERMAP_MAP_O {
		di_tv := (^Typval_T)(di)
		tv_clear(di_tv)
		newtv.v_lock = VAR_UNLOCKED
		di_tv^ = newtv
	} else if fm == FILTERMAP_MAPNEW_O {
		key := transmute(cstring)(rawptr(uintptr(di) + 17))
		r2 := tv_dict_add_tv(s.d_ret, key, C.size_t(libc.strlen(key)), &newtv)
		tv_clear(&newtv)
		if r2 == FAIL_E {
			s.failed = true
			return false
		}
	} else if fm == FILTERMAP_FILTER_O && rem {
		di_flags := C.int(([^]u8)(di)[16])
		if 	var_check_fixed(di_flags, s.arg_errmsg, max(C.size_t)) ||
				var_check_ro(di_flags, s.arg_errmsg, max(C.size_t)) {
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
	hash_lock(rawptr(uintptr(d) + 16))
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
	hash_unlock(rawptr(uintptr(d) + 16))
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
		tv_blob_copy(b, rettv)
		b_ret = (rawptr)(rettv.vval)
	}
	// set_vim_var_nr() doesn't set the type.
		set_vim_var_type(VV_KEY_O, VAR_NUMBER)
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
			set_vim_var_nr(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{}
		rem := false
		if filter_map_one_o(&tv, expr, filtermap, &newtv, &rem) == FAIL_E || did_emsg_flag != 0 {
			break
		}
		if filtermap != FILTERMAP_FOREACH_O {
			if newtv.v_type != VAR_NUMBER && newtv.v_type != VAR_BOOL {
				tv_clear(&newtv)
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
				libc.memmove(rawptr(uintptr(rawptr(p)) + uintptr(i)), rawptr(uintptr(rawptr(p)) + uintptr(i) + 1), C.size_t(n - i - 1))
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
		set_vim_var_type(VV_KEY_O, VAR_NUMBER)
	ga: Garray
	ga_init(&ga, 1, 80)
	idx: C.int = 0
	p := uintptr(rawptr(str))
	for ([^]u8)(p)[0] != 0 {
		ln := utfc_ptr2len(transmute(cstring)(rawptr(p)))
		tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2((^u8)(p), C.size_t(ln)))}
			set_vim_var_nr(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{v_lock = VAR_UNLOCKED}
		rem := false
		if filter_map_one_o(&tv, expr, filtermap, &newtv, &rem) == FAIL_E || did_emsg_flag != 0 {
			tv_clear(&newtv)
			tv_clear(&tv)
			break
		}
		if filtermap == FILTERMAP_MAP_O || filtermap == FILTERMAP_MAPNEW_O {
			if newtv.v_type != VAR_STRING {
				tv_clear(&newtv)
				tv_clear(&tv)
				emsg(cstring(E_STRING_REQUIRED_S))
				break
			} else {
				ga_concat(&ga, transmute(cstring)((rawptr)(newtv.vval)))
			}
		} else if filtermap == FILTERMAP_FOREACH_O || !rem {
			ga_concat(&ga, transmute(cstring)((rawptr)(tv.vval)))
		}
		tv_clear(&newtv)
		tv_clear(&tv)
		idx += 1
		p += uintptr(ln)
	}
	ga_append(&ga, 0)
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
		set_vim_var_type(VV_KEY_O, VAR_NUMBER)
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
			set_vim_var_nr(VV_KEY_O, C.longlong(idx))
		newtv := Typval_T{}
		rem := false
		if filter_map_one_o(item, expr, filtermap, &newtv, &rem) == FAIL_E {
			break
		}
		if did_emsg_flag != 0 {
			tv_clear(&newtv)
			break
		}
		if filtermap == FILTERMAP_MAP_O {
			tv_clear(item)
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
		prepare_vimvar(VV_VAL_O, &save_val)
		prepare_vimvar(VV_KEY_O, &save_key)
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
		restore_vimvar(VV_KEY_O, &save_key)
		restore_vimvar(VV_VAL_O, &save_val)
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
		d1 = tv_dict_copy(nil, d1, false, get_copyID())
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
		l1 = tv_list_copy(nil, l1, false, get_copyID())
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
			item = tv_list_find(l1, before)
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
		ga_grow((^Garray)(b), 1)
		p := (^rawptr)(uintptr(b) + 16)^
		libc.memmove(rawptr(uintptr(rawptr(p)) + uintptr(before) + 1), rawptr(uintptr(rawptr(p)) + uintptr(before)), C.size_t(blen - before))
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
			item = tv_list_find(l, C.int(before))
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
		tv_blob_remove(argvars, rettv, arg_errmsg)
	} else if a0.v_type == VAR_LIST {
		tv_list_remove(argvars, rettv, arg_errmsg)
	} else {
		semsg(cstring(E_LISTDICTBLOBARG_S), cstring("remove()"))
	}
}

// —— Batch 8: eval/buffer.c find leaves (FFI fully rewired) ——
foreign _ {
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
	buf := 	get_buf_arg(a0)
	if buf != nil {
		if swap_exists_action_g != SEA_READONLY_O {
			swap_exists_action_g = SEA_NONE_O
		}
		buf_ensure_loaded(buf)
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
		buf = 	tv_get_buf_from_arg(a0)
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
		if !tv_check_str_or_nr(a0) {
			return
		}
		emsg_off += 1
		buf = 	tv_get_buf(a0, 0)
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
	buf := 	tv_get_buf_from_arg(a0)
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
	buf := 	tv_get_buf_from_arg(a0)
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
		line = typval_tostring(lines, false)
	}
	// Default result is zero == OK (vval only, like C).
	for {
		if lines.v_type == VAR_LIST {
			if li == nil {
				break
			}
			xfree(transmute(rawptr)(line))
			line = typval_tostring(transmute(^Typval_T)(uintptr(li) + 16), false)
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
					check_cursor_col(curwin)
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
		check_cursor_col(curwin)
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
	buf := 	tv_get_buf((^Typval_T)(uintptr(argvars)), 0)
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
	buf := 	tv_get_buf(a0, 0)
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
		check_cursor_col(curwin)
		deleted_lines_mark_r(first, count)
		rettv.vval = transmute(rawptr)(C.longlong(0)) // OK
	}
	if !is_curbuf {
		change_other_buffer_restore_o(&cob)
	}
}

// —— Batch 11: eval/buffer.c info/switch/prompt (closes buffer.c) ——
foreign _ {
	// (tv_dict_find_e removed in 25a: calls tv_dict_find directly.)
	@(link_name = "buf_has_signs")
	buf_has_signs_e :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "get_buffer_signs")
	get_buffer_signs_e :: proc "c" (buf: rawptr) -> rawptr ---
	@(link_name = "ml_replace_buf")
	ml_replace_buf_e :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, copy: bool, noalloc: bool) -> C.int ---
	@(link_name = "buf_prompt_text")
	buf_prompt_text_e :: proc "c" (buf: rawptr) -> ^u8 ---
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
			di := 	tv_dict_find(sel_d, cstring("buflisted"), 9)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_buflisted = true
			}
			di = 	tv_dict_find(sel_d, cstring("bufloaded"), 9)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_bufloaded = true
			}
			di = 	tv_dict_find(sel_d, cstring("bufmodified"), 11)
			if di != nil && tv_get_number(transmute(^Typval_T)(di)) != 0 {
				sel_bufmodified = true
			}
		}
	} else if a0.v_type != VAR_UNKNOWN {
		argbuf = 	tv_get_buf_from_arg(a0)
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
	buf := 	tv_get_buf(a0, 0)
	if buf == nil {
		return
	}
	if !callback_from_typval(&prompt_callback, a1) {
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
	buf := 	tv_get_buf(a0, 0)
	if buf == nil {
		return
	}
	if !callback_from_typval(&interrupt_callback, a1) {
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
	buf := 	tv_get_buf(a0, 0)
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
			!strnequal(transmute(cstring)(old_prompt), transmute(cstring)(rawptr(uintptr(old_line) + uintptr(prompt_col) - uintptr(old_prompt_len))), C.size_t(old_prompt_len)) {
			ml_replace_buf_e(buf, prompt_lno, transmute(^u8)(new_prompt), true, false)
			extmark_splice_cols(buf, prompt_lno - 1, 0, old_line_len, new_prompt_len, KEXTMARK_NO_UNDO_O)
			cursor_col = new_prompt_len
		} else {
			new_line := concat_str_c(transmute(cstring)(new_prompt), transmute(cstring)(rawptr(uintptr(old_line) + uintptr(prompt_col))))
			if ml_replace_buf_e(buf, prompt_lno, new_line, false, false) != OK_R {
				xfree(transmute(rawptr)(new_line))
			}
			extmark_splice_cols(buf, prompt_lno - 1, 0, prompt_col, new_prompt_len, KEXTMARK_NO_UNDO_O)
			cursor_col += new_prompt_len - prompt_col
		}
		if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(curwin) + W_CURSOR)^ == prompt_lno {
			(^C.int)(uintptr(curwin) + W_CURSOR + 4)^ = cursor_col
			check_cursor_col(curwin)
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
	buf := 	tv_get_buf_from_arg(a0)
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
				tv_clear(item)
				item.v_type = VAR_STRING
				item.vval = transmute(rawptr)(new_str)
				did_concat = true
			}
		} else if lines.v_type == VAR_STRING {
			str := tv_get_string(lines)
			new_str := concat_str_c(text, str)
			tv_clear(lines)
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
		prompt_trim_scrollback(buf)
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

// —— Batch 13: eval/window.c winnr/view/layout/dimensions (FFI fully rewired) ——
foreign _ {
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
				nr = tabpage_index(nil) - 1
			} else if libc.strcmp(arg, cstring("#")) == 0 {
				if valid_tabpage(lastused_tabpage_g) {
					nr = tabpage_index(lastused_tabpage_g)
				} else {
					nr = 0
				}
			} else {
				semsg(cstring(E15_S), arg)
			}
		}
	} else {
		nr = tabpage_index(curtab)
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
	ga_init(&ga, 1, 70)
	for i := 0; i < 2; i += 1 {
		winnr: C.int = 1
		wp := firstwin
		for wp != nil {
			if !win_has_winnr(wp, curtab) {
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				continue
			}
			libc.snprintf(&buf[0], C.size_t(size_of(buf)), cstring(":%dresize %d|"), winnr, (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^)
			ga_concat_len(&ga, transmute(cstring)(&buf[0]), C.size_t(libc.strlen(transmute(cstring)(&buf[0]))))
			libc.snprintf(&buf[0], C.size_t(size_of(buf)), cstring("vert :%dresize %d|"), winnr, (^C.int)(uintptr(wp) + W_WIDTH_OFF)^)
			ga_concat_len(&ga, transmute(cstring)(&buf[0]), C.size_t(libc.strlen(transmute(cstring)(&buf[0]))))
			winnr += 1
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	ga_append(&ga, 0)
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
	di := 	tv_dict_find(dict, cstring("lnum"), 4)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = 	tv_dict_find(dict, cstring("col"), 3)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR + 4)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = 	tv_dict_find(dict, cstring("coladd"), 6)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSOR + 8)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = 	tv_dict_find(dict, cstring("curswant"), 8)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = false
	}
	di = 	tv_dict_find(dict, cstring("topline"), 7)
	if di != nil {
		set_topline_e(curwin, C.int(tv_get_number(transmute(^Typval_T)(di))))
	}
	di = 	tv_dict_find(dict, cstring("topfill"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = 	tv_dict_find(dict, cstring("leftcol"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_LEFTCOL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	di = 	tv_dict_find(dict, cstring("skipcol"), 7)
	if di != nil {
		(^C.int)(uintptr(curwin) + W_SKIPCOL_OFF)^ = C.int(tv_get_number(transmute(^Typval_T)(di)))
	}
	check_cursor(curwin)
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
		di := 	tv_dict_find(d, cstring("rightbelow"), -1)
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
// (execute_common_e removed in 27b: calls execute_common directly.)

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
	if switch_win_noblock(transmute(rawptr)(&args.switchwin), wp, tp, true) == OK_R {
		check_cursor(curwin)
		return true
	}
	return false
}

// Restore the previous window after executing user code.
@(export)
win_execute_after :: proc "c" (args: ^WinExecute_T) {
	context = runtime.default_context()
	restore_win_noblock(transmute(rawptr)(&args.switchwin), true)
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
	check_cursor(curwin)
	if VIsual_active {
		check_pos(curbuf, &VIsual_g)
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
		execute_common(argvars, rettv, 1)
	}
	win_execute_after(&args)
}

// Set "win" to be curwin and "tp" current tabpage (restore_win MUST undo).
@(export)
switch_win :: proc "c" (switchwin: ^Switchwin_T, win: rawptr, tp: rawptr, no_display: bool) -> C.int {
	context = runtime.default_context()
	block_autocmds_r()
	return switch_win_noblock(transmute(rawptr)(switchwin), win, tp, no_display)
}

// Restore current tabpage and window saved by switch_win().
@(export)
restore_win :: proc "c" (switchwin: ^Switchwin_T, no_display: bool) {
	context = runtime.default_context()
	restore_win_noblock(transmute(rawptr)(switchwin), no_display)
	unblock_autocmds_r()
}

// —— Batch 16: eval/fs.c simple leaves ——
foreign _ {
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
	if !changedir_func(transmute(cstring)((rawptr)(a0.vval)), scope) {
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
	@(link_name = "path_is_absolute")
	path_is_absolute_e :: proc "c" (fname: cstring) -> bool ---
	@(link_name = "path_tail")
	path_tail_e :: proc "c" (fname: cstring) -> ^u8 ---
	@(link_name = "path_tail_with_sep")
	path_tail_with_sep_e :: proc "c" (fname: ^u8) -> ^u8 ---
	@(link_name = "can_add_defer")
	can_add_defer_e :: proc "c" () -> bool ---
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
		ga_init(&ga, 8, 10)
		globpath_e(tv_get_string(a0), file, &ga, flags, false)
		if rettv.v_type == VAR_STRING {
			rettv.vval = transmute(rawptr)(ga_concat_strings(&ga, cstring("\n")))
		} else {
			tv_list_alloc_ret(transmute(^Typval)(rettv), ga.ga_len)
			i: C.int = 0
			for i < ga.ga_len {
				tv_list_append_string((rawptr)(rettv.vval), ([^]^u8)(ga.ga_data)[uintptr(i)], -1)
				i += 1
			}
		}
		ga_clear_strings(&ga)
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
		rettv.vval = transmute(rawptr)(C.longlong(vim_mkdir_emsg(dir, prot)))
	}
	if transmute(C.longlong)(rettv.vval) == OK_E && created == nil && (defer_del || defer_rec) {
		created = transmute(cstring)(FullName_save_e(dir, false))
	}
	if created != nil {
		tv: [2]Typval_T
		tv[0] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(created)}
		tv[1] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring("d"))))}
		if defer_rec {
			tv_clear(&tv[1])
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

// —— Batch 17: eval/fs.c find/dirname/stat (FFI fully rewired) ——
foreign _ {
	@(link_name = "find_file_in_path_option")
	find_file_in_path_option_e :: proc "c" (ptr: cstring, len: C.size_t, options: C.int, first: C.int, path_option: cstring, find_what: C.int, rel_fname: cstring, suffixes: cstring, file_to_find: ^rawptr, search_ctx: ^rawptr) -> ^u8 ---
	@(link_name = "vim_findfile_cleanup")
	vim_findfile_cleanup_e :: proc "c" (ctx: rawptr) ---
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
			modify_fname(transmute(^u8)(mods), false, &usedlen, &fnamep, &fbuf, &ln)
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
		prepare_vimvar(VV_VAL_O, &save_val)
		set_vim_var_string(VV_VAL_O, name, -1)
	argv: [2]Typval_T
	argv[0].v_type = VAR_STRING
	argv[0].vval = transmute(rawptr)(name)
	rettv: Typval_T
	done := false
	if eval_expr_typval(expr, false, &argv[0], 1, &rettv) == FAIL_E {
		done = true
	}
	if !done {
		retval = tv_get_number_chk(&rettv, &error)
		if error {
			retval = -1
		}
		tv_clear(&rettv)
	}
		set_vim_var_string(VV_VAL_O, nil, 0)
		restore_vimvar(VV_VAL_O, &save_val)
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
	ga_clear_strings(&ga)
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
	ga_grow((^Garray)(blob), C.int(size))
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
	if ln > 1 && _after_pathsep(cstring(rawptr(p)), cstring(rawptr(uintptr(rawptr(p)) + uintptr(ln)))) != 0 {
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
				src2 := ([^]u8)(uintptr(rawptr(p)) + 2)
				n2 := i64(libc.strlen(cstring(rawptr(src2)))) + 1
				libc.memmove(rawptr(p), rawptr(src2), C.size_t(n2))
			}
		}
	}
	if !has_trailing_pathsep {
		q = ([^]u8)(uintptr(rawptr(p)) + uintptr(i64(libc.strlen(cstring(rawptr(p))))))
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
			if !tv_check_str_or_nr((^Typval_T)(&item.li_tv)) {
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

// —— Batch 20a: eval/vars.c parsing leaves (FFI fully rewired) ——

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
	return find_name_end(start, nil, nil, FNE_INCL_BR_O | FNE_CHECK_START_O)
}

// Skip "[var, var]" list or a single variable name.
@(export)
skip_var_list :: proc "c" (arg: cstring, var_count: ^C.int, semicolon: ^C.int, silent: bool) -> cstring {
	context = runtime.default_context()
	if ([^]u8)(arg)[0] == '[' {
		p := ([^]u8)(arg)
		for {
			p = ([^]u8)(skipwhite(transmute(cstring)(uintptr(rawptr(p)) + 1)))
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
		return transmute(cstring)(uintptr(rawptr(p)) + 1)
	}
	return skip_var_one_o(arg)
}

// Evaluate one {expr} block in a string, append result to "gap".
@(export)
eval_one_expr_in_str :: proc "c" (p: ^u8, gap: ^Garray, evaluate: bool) -> ^u8 {
	context = runtime.default_context()
	block_start := ([^]u8)(skipwhite(transmute(cstring)(uintptr(rawptr(p)) + 1)))
	block_end := block_start
	if block_end[0] == 0 {
		semsg(cstring(E_MISSING_CURLY_S), transmute(cstring)(p))
		return nil
	}
	be := transmute(cstring)(block_end)
	if skip_expr(&be, nil) == FAIL_E {
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
		expr_val := transmute(^u8)(eval_to_string(transmute(cstring)(block_start), false, false))
		block_end[0] = '}'
		if expr_val == nil {
			return nil
		}
		ga_concat(gap, transmute(cstring)(expr_val))
		xfree(rawptr(expr_val))
	}
	return &block_end[1]
}

// Evaluate all {expr} blocks in "str", "{{" collapses to "{".
eval_all_expr_in_str_o :: proc "c" (str: ^u8) -> ^u8 {
	context = runtime.default_context()
	ga: Garray
	ga_init(&ga, 1, 80)
	p := ([^]u8)(str)
	for p[0] != 0 {
		escaped_brace := false
		lit_start := p
		for p[0] != '{' && p[0] != '}' && p[0] != 0 {
			p = ([^]u8)(uintptr(rawptr(p)) + 1)
		}
		if p[0] != 0 && p[0] == p[1] {
			p = ([^]u8)(uintptr(rawptr(p)) + 1)
			escaped_brace = true
		} else if p[0] == '}' {
			semsg(cstring(E_STRAY_CURLY_S), transmute(cstring)(str))
			ga_clear(&ga)
			return nil
		}
		ga_concat_len(&ga, transmute(cstring)(lit_start), C.size_t(uintptr(p) - uintptr(lit_start)))
		if p[0] == 0 {
			break
		}
		if escaped_brace {
			p = ([^]u8)(uintptr(rawptr(p)) + 1)
			continue
		}
		p = ([^]u8)(eval_one_expr_in_str(&p[0], &ga, true))
		if p == nil {
			ga_clear(&ga)
			return nil
		}
	}
	ga_append(&ga, 0)
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
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		buf: [1025]u8
		xstrlcpy(transmute(cstring)(&buf[0]), prefix, C.size_t(1025))
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
		prepare_vimvar(VV_VAL_O, &save_val)
		set_vim_var_string(VV_VAL_O, badword, -1)
	if p_verbose == 0 {
		emsg_off += 1
	}
	ctx := get_option_sctx(kOptSpellsuggest_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	evalarg := Evalarg_T{eval_flags = 1}
	r := may_call_simple_func(transmute(cstring)(p), &rettv)
	if r == NOTDONE_O {
		pc := transmute(cstring)(p)
		r = eval1(&pc, &rettv, rawptr(&evalarg))
		p = ([^]u8)(pc)
	}
	if r == OK_E {
		if rettv.v_type != VAR_LIST {
			tv_clear(&rettv)
		} else {
			list = (rawptr)(rettv.vval)
		}
	}
	if p_verbose == 0 {
		emsg_off -= 1
	}
	tv_clear(	get_vim_var_tv(VV_VAL_O))
		restore_vimvar(VV_VAL_O, &save_val)
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
	hash_init(rawptr(d + 16))
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
	hash_lock(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		if free_val {
			tv_clear((^Typval_T)(di))
		}
		if (^u8)(di + 16)^ & DI_FLAGS_ALLOC_O != 0 {
			xfree(rawptr(di))
		}
	}
	hash_clear(ht)
	hash_init(ht)
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
	hash_remove(ht, hi)
	tv_clear((^Typval_T)(di))
	xfree(rawptr(di))
}

// Top-level typval allocator + evaluator (eval.c public).
@(export)
eval_expr :: proc "c" (arg: cstring, eap: rawptr) -> ^Typval_T {
	context = runtime.default_context()
	return eval_expr_ext(arg, eap, false)
}

// Top-level typval allocator + evaluator with simple-funccal flag.
@(export)
eval_expr_ext :: proc "c" (arg: cstring, eap: rawptr, use_simple_function: bool) -> ^Typval_T {
	context = runtime.default_context()
	tv := (^Typval_T)(xmalloc(C.size_t(size_of(Typval_T))))
	evalarg := Evalarg_T{}
	skip := false
	if eap != nil {
		skip = (^bool)(uintptr(eap) + 72)^
	}
	fill_evalarg_from_eap(&evalarg, eap, skip)
	r: C.int = NOTDONE_O
	if use_simple_function {
		r = eval0_simple_funccal_o(arg, tv, eap, rawptr(&evalarg))
	}
	if r == NOTDONE_O {
		r = eval0(arg, tv, eap, rawptr(&evalarg))
	}
	if r == FAIL_E {
		xfree(tv)
		tv = nil
	}
	clear_evalarg(&evalarg, eap)
	return tv
}

// —— Batch 20e: eval/vars.c environ + lookup leaves ——
foreign _ {
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
		set_var(name, C.size_t(libc.strlen(name)), &tv, true)
}

// Evaluate 'charconvert' for file conversion (OK/FAIL).
@(export)
eval_charconvert :: proc "c" (enc_from: cstring, enc_to: cstring, fname_from: cstring, fname_to: cstring) -> C.int {
	context = runtime.default_context()
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
		set_vim_var_string(VV_CC_FROM_O, enc_from, -1)
		set_vim_var_string(VV_CC_TO_O, enc_to, -1)
		set_vim_var_string(VV_FNAME_IN_O, fname_from, -1)
		set_vim_var_string(VV_FNAME_OUT_O, fname_to, -1)
	ctx := get_option_sctx(kOptCharconvert_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	err := false
	if eval_to_bool(p_ccv_e, &err, nil, false, true) {
		err = true
	}
		set_vim_var_string(VV_CC_FROM_O, nil, -1)
		set_vim_var_string(VV_CC_TO_O, nil, -1)
		set_vim_var_string(VV_FNAME_IN_O, nil, -1)
		set_vim_var_string(VV_FNAME_OUT_O, nil, -1)
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
		set_vim_var_string(VV_FNAME_IN_O, origfile, -1)
		set_vim_var_string(VV_FNAME_NEW_O, newfile, -1)
		set_vim_var_string(VV_FNAME_OUT_O, outfile, -1)
	ctx := get_option_sctx(kOptDiffexpr_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	tv := eval_expr_ext(p_dex_e, nil, true)
	tv_free(tv)
		set_vim_var_string(VV_FNAME_IN_O, nil, -1)
		set_vim_var_string(VV_FNAME_NEW_O, nil, -1)
		set_vim_var_string(VV_FNAME_OUT_O, nil, -1)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
}

// Evaluate 'patchexpr' to apply a patch (errors ignored).
@(export)
eval_patch :: proc "c" (origfile: cstring, difffile: cstring, outfile: cstring) {
	context = runtime.default_context()
	saved: sctx_T
	libc.memcpy(rawptr(&saved), rawptr(&current_sctx_buf[0]), C.size_t(size_of(sctx_T)))
		set_vim_var_string(VV_FNAME_IN_O, origfile, -1)
		set_vim_var_string(VV_FNAME_DIFF_O, difffile, -1)
		set_vim_var_string(VV_FNAME_OUT_O, outfile, -1)
	ctx := get_option_sctx(kOptPatchexpr_E)
	if ctx != nil {
		libc.memcpy(rawptr(&current_sctx_buf[0]), ctx, C.size_t(size_of(sctx_T)))
	}
	tv := eval_expr_ext(p_pex_e, nil, true)
	tv_free(tv)
		set_vim_var_string(VV_FNAME_IN_O, nil, -1)
		set_vim_var_string(VV_FNAME_DIFF_O, nil, -1)
		set_vim_var_string(VV_FNAME_OUT_O, nil, -1)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved), C.size_t(size_of(sctx_T)))
}

// The string value of a (global/local) variable, NULL when missing.
@(export)
get_var_value :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	v := 	find_var(name, C.size_t(libc.strlen(name)), nil, 0)
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

// Delete all "menutrans_" global variables (after ":menutrans clear").
@(export)
del_menutrans_vars :: proc "c" () {
	context = runtime.default_context()
	ht := 	get_globvar_ht()
	hash_lock(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		if libc.strncmp(transmute(cstring)(key), cstring("menutrans_"), 10) == 0 {
			delete_var_o(ht, rawptr(cur))
		}
	}
	hash_unlock(ht)
}

// —— Batch 21a: eval/typval.c dict getters + list finders ——
E_LIST_OOR_S :: "E684: List index out of range: %ld"

// Check if a key is present in a dictionary.
@(export)
tv_dict_has_key :: proc "c" (d: rawptr, key: cstring) -> bool {
	context = runtime.default_context()
	return 	tv_dict_find(d, key, 	C.ptrdiff_t(-1)) != nil
}

// Get a typval item from a dictionary and copy it into "rettv" (OK/FAIL).
@(export)
tv_dict_get_tv :: proc "c" (d: rawptr, key: cstring, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(-1))
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
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(-1))
	if di == nil {
		return C.longlong(def)
	}
	return tv_get_number((^Typval_T)(di))
}

// Gets a bool item from a dictionary ("def" when missing).
@(export)
tv_dict_get_bool :: proc "c" (d: rawptr, key: cstring, def: C.int) -> C.longlong {
	context = runtime.default_context()
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(-1))
	if di == nil {
		return C.longlong(def)
	}
	return tv_get_bool(transmute(^Typval_T)(di))
}

// Get list item l[n] as a number (-1 with error flag when missing).
@(export)
tv_list_find_nr :: proc "c" (l: rawptr, n: C.int, ret_error: ^bool) -> C.longlong {
	context = runtime.default_context()
	li := tv_list_find(l, n)
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
	li := tv_list_find(l, n)
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

// —— Batch 23a: eval/encode.c writer + reader leaves (FFI fully rewired) ——
foreign _ {
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
	ga_concat_len((^Garray)(data), buf, len)
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
		le := uintptr(xmemscan(bb, NL_O, len))
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
			memchrsub(str, C.int(NUL), C.int(NL_O), line_length)
		}
		line_end = le + 1
	}
	for line_end < end {
		line_start := line_end
		le := uintptr(xmemscan(rawptr(line_start), NL_O, C.size_t(end - line_start)))
		str: rawptr = nil
		if le != line_start {
			line_length := C.size_t(le - line_start)
			str = rawptr(xmemdupz_o2(transmute(^u8)(line_start), line_length))
			memchrsub(str, C.int(NUL), C.int(NL_O), line_length)
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
	type_di := 	tv_dict_find(spdict, cstring("_TYPE"), 	C.ptrdiff_t(-1))
	if type_di == nil {
		return false
	}
	if (^C.int)(type_di)^ != VAR_LIST {
		return false
	}
	if (^rawptr)(uintptr(type_di) + 8)^ != eval_msgpack_type_lists_e[KMPSTRING_O] {
		return false
	}
	val_di := 	tv_dict_find(spdict, cstring("_VAL"), 	C.ptrdiff_t(-1))
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
			vim_str2nr(transmute(cstring)(s), nil, nil, STR2NR_ALL_O, &n, nil, 0, false, nil)
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
		fp := var2fpos(tv, true, &fnum, false, curwin)
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
					if key == nil || key == rawptr(&hash_removed) {
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
			p1 = encode_tv2string(tv1, nil)
			tofree1 = transmute(^u8)(p1)
		}
		if tv2.v_type == VAR_STRING {
			if tv1.v_type != VAR_STRING || info.numeric {
				p2 = cstring("'")
			} else {
				p2 = transmute(cstring)((rawptr)(tv2.vval))
			}
		} else {
			p2 = encode_tv2string(tv2, nil)
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
		func_name = partial_name(info.partial)
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
	tv_clear(&argv[0])
	tv_clear(&argv[1])
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
	tv_clear(&rettv)
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
	tv_clear((^Typval_T)(uintptr(item) + 16))
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
		p = ([^]u8)(uintptr(rawptr(p)) + uintptr(ln))
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
		if key == nil || key == rawptr(&hash_removed) {
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
	rettv.vval = transmute(rawptr)(C.longlong(	tv_dict_find((rawptr)(a0.vval), tv_get_string(a1), 	C.ptrdiff_t(-1)) != nil ? 1 : 0))
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
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(-1))
	if di == nil {
		semsg(cstring(E_DICTKEY_S), key)
		return
	}
	if 	var_check_fixed(C.int((^u8)(uintptr(di) + 16)^), arg_errmsg, max(C.size_t)) || 	var_check_ro(C.int((^u8)(uintptr(di) + 16)^), arg_errmsg, max(C.size_t)) {
		return
	}
	rettv^ = ((^Typval_T)(di))^
	(^Typval_T)(di)^ = Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED, vval = nil}
	tv_dict_item_remove(d, di)
	if tv_dict_is_watched_o(d) {
			tv_dict_watcher_notify(d, key, nil, rettv)
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
			ga_clear((^Garray)(blob))
			return
		}
		ga_append((^Garray)(blob), u8(n))
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
	item := tv_list_find(l, C.int(idx))
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
		item2 := tv_list_find(l, C.int(end))
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
			tv_clear((^Typval_T)(uintptr(dest_li) + 16))
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
	li := tv_list_find(l, idx^)
	if li != nil {
		return li
	}
	if idx^ < 0 {
		idx^ = 0
		li = tv_list_find(l, idx^)
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
		ga_grow(join_gap, 1)
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
	ga_grow(gap, C.int(sumlen) + 2)
	i: C.int = 0
	for i < join_gap.ga_len && !got_int {
		if first {
			first = false
		} else {
			ga_concat_len(gap, sep, seplen)
		}
		p := &([^]Join_T)(join_gap.ga_data)[i]
		if p.s_data != nil {
			ga_concat_len(gap, p.s_data, p.s_size)
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
	ga_init(&ga, 1, 80)
	buf: [22]u8
	li := tv_list_first_o(l)
	for li != nil {
		n := tv_get_number((^Typval_T)(uintptr(li) + 16))
		buflen := utf_char2bytes(C.int(n), &buf[0])
		buf[buflen] = 0
		ga_concat_len(&ga, transmute(cstring)(&buf[0]), C.size_t(buflen))
		li = (^rawptr)(li)^
	}
	ga_append(&ga, 0)
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
		partial_unref(callback.data)
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
	tv_clear((^Typval_T)(item))
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
	hi := hash_find(ht, transmute(cstring)(uintptr(item) + 17))
	empty := hi == nil
	key: rawptr = nil
	if !empty {
		key = ([^]rawptr)(uintptr(hi))[1]
		empty = key == nil || key == rawptr(&hash_removed)
	}
	if empty {
		semsg(cstring(E_INTERN2_S), cstring("tv_dict_item_remove()"))
	} else {
		hash_remove(ht, hi)
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
	hash_init(rawptr(uintptr(d) + 16))
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
	hash_lock(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di := uintptr(key) - 17
		hash_remove(ht, rawptr(cur))
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
	hash_clear(ht)
	(^C.int)(uintptr(ht) + 28)^ -= 1
	hash_init(ht)
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
		tv_clear((^Typval_T)(uintptr(item) + 16))
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
	@(link_name = "get_funccal_local_ht")
	get_funccal_local_ht_e :: proc "c" () -> rawptr ---
}

// Check for adding a function to g: or l: (true + error on bad name).
@(export)
tv_dict_wrong_func_name :: proc "c" (d: rawptr, tv: ^Typval_T, name: cstring) -> C.int {
	context = runtime.default_context()
	is_glob := d == 	get_globvar_dict()
	is_local := rawptr(uintptr(d) + 16) == get_funccal_local_ht_e()
	if (is_glob || is_local) && (tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL) && 	var_wrong_func_name(name, true) {
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
	return hash_add(rawptr(uintptr(d) + 16), &([^]u8)(uintptr(item) + 17)[0])
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
	hash_lock(ht)
	todo := (^C.size_t)(uintptr(ht) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht) + 32)^)
	for todo > 0 {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		tv_dict_item_free(rawptr(uintptr(key) - 17))
		hash_remove(ht, rawptr(cur))
	}
	hash_unlock(ht)
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
	item := tv_list_find(ol, C.int(n1))
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
		tv_clear(rettv)
		tv_list_set_ret_o(rettv, l)
	} else {
		var1: Typval_T
		tv_copy((^Typval_T)(uintptr(tv_list_find((rawptr)(rettv.vval), C.int(n1))) + 16), &var1)
		tv_clear(rettv)
		rettv^ = var1
	}
	return OK_E
}

// —— Batch 21m: eval/typval.c dict extend + equal ——

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
		hash_lock(rawptr(uintptr(d2) + 16))
	}
	ht2 := rawptr(uintptr(d2) + 16)
	todo := (^C.size_t)(uintptr(ht2) + 8)^
	hi := uintptr((^rawptr)(uintptr(ht2) + 32)^)
	done := false
	for todo > 0 && !done {
		key := ([^]rawptr)(hi)[1]
		cur := hi
		hi += 16
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di2 := uintptr(key) - 17
		di1 := uintptr(	tv_dict_find(d1, transmute(cstring)(di2 + 17), 	C.ptrdiff_t(-1)))
		if (^C.int)(uintptr(d1) + 4)^ != 0 && !	valid_varname(transmute(cstring)(di2 + 17)) {
			done = true
		} else if di1 == 0 {
			if act == 'm' {
				new_di := rawptr(di2)
				if tv_dict_add(d1, new_di) == OK_E {
					hash_remove(ht2, rawptr(cur))
						tv_dict_watcher_notify(d1, transmute(cstring)(di2 + 17), (^Typval_T)(di2), nil)
				}
			} else {
				new_di := tv_dict_item_copy(rawptr(di2))
				if tv_dict_add(d1, new_di) == FAIL_E {
					tv_dict_item_free(new_di)
				} else if watched {
						tv_dict_watcher_notify(d1, transmute(cstring)(di2 + 17), (^Typval_T)(uintptr(new_di)), nil)
				}
			}
		} else if act == 'e' {
			semsg(cstring(E_KEY_EXISTS_S), transmute(cstring)(di2 + 17))
			done = true
		} else if act == 'f' && di2 != di1 {
			oldtv: Typval_T
			if value_check_lock((^C.int)(di1 + 4)^, cstring(EXTEND_ARG_S), arg_len) || 	var_check_ro(C.int((^u8)(di1 + 16)^), cstring(EXTEND_ARG_S), arg_len) {
				done = true
			} else {
				if tv_dict_wrong_func_name(d1, (^Typval_T)(di2), transmute(cstring)(di2 + 17)) != 0 {
					done = true
				} else {
					if watched {
						tv_copy((^Typval_T)(di1), &oldtv)
					}
					tv_clear((^Typval_T)(di1))
					tv_copy((^Typval_T)(di2), (^Typval_T)(di1))
					if watched {
							tv_dict_watcher_notify(d1, transmute(cstring)(di1 + 17), (^Typval_T)(di1), &oldtv)
						tv_clear(&oldtv)
					}
				}
			}
		}
	}
	if act == 'm' {
		hash_unlock(ht2)
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
		if key == nil || key == rawptr(&hash_removed) {
			continue
		}
		todo -= 1
		di1 := uintptr(key) - 17
		di2 := 	tv_dict_find(d2, transmute(cstring)(di1 + 17), 	C.ptrdiff_t(-1))
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
			if var_item_copy(conv, (^Typval_T)(uintptr(li) + 16), (^Typval_T)(uintptr(ni) + 16), deep, copyID) == FAIL_E {
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
		ni := tv_list_find(l, n2^)
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
		if key == nil || key == rawptr(&hash_removed) {
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
			if var_item_copy(conv, (^Typval_T)(di), (^Typval_T)(uintptr(new_di)), deep, copyID) == FAIL_E {
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
		if key == nil || key == rawptr(&hash_removed) {
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
	ga_init((^Garray)(blob), 1, 100)
	return blob
}

// Free a blob (ignores reference count).
@(export)
tv_blob_free :: proc "c" (b: rawptr) {
	context = runtime.default_context()
	ga_clear((^Garray)(b))
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
		tv_clear(rettv)
		rettv.v_type = VAR_BLOB
		rettv.vval = nil
	} else {
		new_blob := tv_blob_alloc()
		sz := C.int(b - a + 1)
		ga_grow((^Garray)(new_blob), sz)
		(^Garray)(new_blob).ga_len = sz
		i := C.int(a)
		for i <= C.int(b) {
			tv_blob_set_o(new_blob, i - C.int(a), tv_blob_get_o((rawptr)(rettv.vval), i))
			i += 1
		}
		tv_clear(rettv)
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
		tv_clear(rettv)
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
			ga_grow(gap, 1)
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
		r := func_equal(tv1, tv2, ic)
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
		partial_unref((rawptr)(tv.vval))
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
			tv_clear((^Typval_T)(uintptr(item) + 16))
			xfree(item)
		}
		done += 1
		item = next
	}
}

// —— Batch 21o: eval/typval.c dict-string getters + to_env ——
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
		if key == nil || key == rawptr(&hash_removed) {
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
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(-1))
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
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(key_len))
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
	di := 	tv_dict_find(d, key, 	C.ptrdiff_t(key_len))
	if di == nil {
		return true
	}
	tv := (^Typval_T)(di)
	if !tv_is_func_o(tv^) && tv.v_type != VAR_STRING {
		emsg(cstring(E_FUNCNAME_S))
		return false
	}
	newtv: Typval_T
	tv_copy(tv, &newtv)
	set_selfdict(&newtv, d)
	res := callback_from_typval(result, &newtv)
	tv_clear(&newtv)
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
		tv_clear((^Typval_T)(uintptr(li) + 16))
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
	ga_init(&join_ga, C.int(size_of(Join_T)), tv_list_len_o(l))
	retval := list_join_inner_o(gap, l, sep, &join_ga)
	i: C.int = 0
	for i < join_ga.ga_len {
		xfree(([^]Join_T)(join_ga.ga_data)[i].tofree)
		i += 1
	}
	ga_clear(&join_ga)
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
		ga_init(&ga, 1, 80)
		tv_list_join(&ga, (rawptr)(a0.vval), sep)
		ga_append(&ga, 0)
		rettv.vval = ga.ga_data
	} else {
		rettv.vval = nil
	}
}

// —— Batch 23b: eval/encode.c tv2 wrappers ——
foreign _ {
	@(link_name = "nvim_odin_reset_echo_emsg")
	reset_echo_emsg_e :: proc "c" () ---
}

// String representation without quotes (echo display).
@(export)
encode_tv2echo :: proc "c" (tv: ^Typval_T, len: ^C.size_t) -> ^u8 {
	context = runtime.default_context()
	ga: Garray
	ga_init(&ga, 1, 80)
	if tv.v_type == VAR_STRING || tv.v_type == VAR_FUNC {
		s := (rawptr)(tv.vval)
		if s != nil {
			ga_concat(&ga, transmute(cstring)(s))
		}
	} else {
		encode_vim_to_echo_o(&ga, tv, cstring(":echo argument"))
	}
	if len != nil {
		len^ = C.size_t(ga.ga_len)
	}
	ga_append(&ga, 0)
	return ([^]u8)(ga.ga_data)
}

// —— Batch 23g: echo-mode driver (shares string walker via flag) ——

// Echo-mode driver (encode_vim_to_echo; echo == string except RECURSE).
encode_vim_to_echo_o :: proc "c" (gap: ^Garray, tv: ^Typval_T, objname: cstring) -> C.int {
	context = runtime.default_context()
	save_flag := encode_recurse_echo_g
	encode_recurse_echo_g = true
	copyID := get_copyID()
	mpstack := MPConvStack_O{}
	mpconv_stack_init_o(&mpstack)
	if convert_one_value_string_o(gap, &mpstack, nil, tv, copyID, objname) == FAIL_E {
		mpconv_stack_destroy_o(&mpstack)
		encode_recurse_echo_g = save_flag
		return FAIL_E
	}
	ret := encode_str_walker_o(gap, &mpstack, tv, copyID, objname)
	encode_recurse_echo_g = save_flag
	return ret
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
			ga_concat_len((^Garray)(b), s, len)
		}
		return tv
	}
	if sp == nil || s_allocated {
		return Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(sp)}
	}
	return Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(sp), len))}
}

// —— Batch 25a: typval core (clear/find/blob) ——
// Empty-string sentinel (was C global in typval.c; C eval.c still assigns
// it — single Odin-owned copy, typval.h extern resolves here).
@(export)
tv_empty_string: cstring = ""

E805_S :: "E805: Expected a Number or a String, Float found"
E703_S :: "E703: Expected a Number or a String, Funcref found"
E745_S :: "E745: Expected a Number or a String, List found"
E728_S :: "E728: Expected a Number or a String, Dictionary found"
E974_S :: "E974: Expected a Number or a String, Blob found"
E5299_S :: "E5299: Expected a Number or a String, Boolean found"
E5300_S :: "E5300: Expected a Number or a String"
E979_S :: "E979: Blob index out of range: %ld"

// Free a value's contents (encode-to-nothing engine semantics).
@(export)
tv_clear :: proc "c" (tv: ^Typval_T) {
	context = runtime.default_context()
	if tv == nil || tv.v_type == VAR_UNKNOWN {
		return
	}
	switch tv.v_type {
	case VAR_PARTIAL:
		pt := rawptr(tv.vval)
		if pt != nil && (^C.int)(uintptr(pt))^ > 1 {
			(^C.int)(uintptr(pt))^ -= 1
		} else {
			partial_unref(pt)
		}
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_FUNC:
		func_unref(transmute(cstring)(rawptr(tv.vval)))
		if tv.vval != transmute(rawptr)(tv_empty_string) {
			xfree(rawptr(tv.vval))
		}
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_STRING:
		xfree(rawptr(tv.vval))
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_BLOB:
		tv_blob_unref(rawptr(tv.vval))
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_LIST:
		tv_list_unref(rawptr(tv.vval))
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_DICT:
		tv_dict_unref(rawptr(tv.vval))
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_NUMBER, VAR_FLOAT:
		tv.vval = nil
		tv.v_lock = VAR_UNLOCKED
	case VAR_BOOL, VAR_SPECIAL:
		(^C.int)(&tv.vval)^ = 0
		tv.v_lock = VAR_UNLOCKED
	}
}

// Find a dict item by key (nil on missing).
@(export)
tv_dict_find :: proc "c" (d: rawptr, key: cstring, length: C.ptrdiff_t) -> rawptr {
	context = runtime.default_context()
	if d == nil {
		return nil
	}
	hi: rawptr
	if length < 0 {
		hi = hash_find(rawptr(uintptr(d) + 16), key)
	} else {
		hi = hash_find_len(rawptr(uintptr(d) + 16), key, C.size_t(length))
	}
	if hi != nil {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
			return nil
		}
	} else {
		return nil
	}
	return rawptr(uintptr((^rawptr)(uintptr(hi) + 8)^) - 17)
}

// Find the nth list item (cached-index walk).
@(export)
tv_list_find :: proc "c" (l: rawptr, n_in: C.int) -> rawptr {
	context = runtime.default_context()
	if l == nil {
		return nil
	}
	n := n_in
	if n < 0 {
		n += (^C.int)(uintptr(l) + 60)^
	}
	if n < 0 || n >= (^C.int)(uintptr(l) + 60)^ {
		return nil
	}
	item: rawptr
	idx: C.int
	if (^rawptr)(uintptr(l) + 24)^ != nil {
		cached := (^C.int)(uintptr(l) + 64)^
		total := (^C.int)(uintptr(l) + 60)^
		if n < cached / 2 {
			item = (^rawptr)(uintptr(l) + 0)^
			idx = 0
		} else if n > (cached + total) / 2 {
			item = (^rawptr)(uintptr(l) + 8)^
			idx = total - 1
		} else {
			item = (^rawptr)(uintptr(l) + 24)^
			idx = cached
		}
	} else {
		item = (^rawptr)(uintptr(l) + 0)^
		idx = 0
	}
	for idx < n {
		item = (^rawptr)(uintptr(item) + 0)^
		idx += 1
	}
	for idx > n {
		item = (^rawptr)(uintptr(item) + 8)^
		idx -= 1
	}
	return item
}

// Copy a blob into a typval.
@(export)
tv_blob_copy :: proc "c" (from: rawptr, to: ^Typval_T) {
	context = runtime.default_context()
	to.v_type = VAR_BLOB
	to.v_lock = VAR_UNLOCKED
	if from == nil {
		to.vval = nil
	} else {
		tv_blob_alloc_ret(to)
		b := rawptr(to.vval)
		length := (^C.int)(uintptr(from) + 0)^
		if length > 0 {
			src := (^rawptr)(uintptr(from) + 16)^
			dst := xmalloc(C.size_t(length))
			libc.memcpy(dst, src, C.size_t(length))
			(^rawptr)(uintptr(b) + 16)^ = dst
		}
		(^C.int)(uintptr(b) + 0)^ = length
		(^C.int)(uintptr(b) + 4)^ = length
	}
}

// True for Number/String values (error otherwise).
@(export)
tv_check_str_or_nr :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	switch tv.v_type {
	case VAR_NUMBER, VAR_STRING:
		return true
	case VAR_FLOAT:
		emsg(cstring(E805_S))
		return false
	case VAR_PARTIAL, VAR_FUNC:
		emsg(cstring(E703_S))
		return false
	case VAR_LIST:
		emsg(cstring(E745_S))
		return false
	case VAR_DICT:
		emsg(cstring(E728_S))
		return false
	case VAR_BLOB:
		emsg(cstring(E974_S))
		return false
	case VAR_BOOL:
		emsg(cstring(E5299_S))
		return false
	case VAR_SPECIAL:
		emsg(cstring(E5300_S))
		return false
	case VAR_UNKNOWN:
		semsg(cstring(E_INTERN2_S), cstring("tv_check_str_or_nr(UNKNOWN)"))
		return false
	}
	libc.abort()
}

// Remove blob item(s) for remove().
@(export)
tv_blob_remove :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_errmsg: cstring) {
	context = runtime.default_context()
	avs := ([^]Typval_T)(argvars)
	b := rawptr(avs[0].vval)
	if b != nil && value_check_lock((^C.int)(uintptr(b) + 28)^, arg_errmsg, max(C.size_t)) {
		return
	}
	error := false
	idx := C.longlong(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error))
	if !error {
		length := C.longlong(tv_blob_len_o(b))
		if idx < 0 {
			idx = length + idx
		}
		if idx < 0 || idx >= length {
			semsg(cstring(E979_S), idx)
			return
		}
		if avs[2].v_type == VAR_UNKNOWN {
			p := rawptr((^rawptr)(uintptr(b) + 16)^)
			rettv.vval = transmute(rawptr)(C.longlong(([^]u8)(p)[uintptr(idx)]))
			libc.memmove(rawptr(uintptr(rawptr(p)) + uintptr(idx)), rawptr(uintptr(rawptr(p)) + uintptr(idx) + 1), C.size_t(length - idx - 1))
			(^C.int)(uintptr(b) + 0)^ -= 1
		} else {
			end := C.longlong(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error))
			if error {
				return
			}
			if end < 0 {
				end = length + end
			}
			if end >= length || idx > end {
				semsg(cstring(E979_S), end)
				return
			}
			blob := tv_blob_alloc()
			(^C.int)(uintptr(blob) + 0)^ = C.int(end - idx + 1)
			ga_grow((^Garray)(blob), C.int(end - idx + 1))
			p := rawptr((^rawptr)(uintptr(b) + 16)^)
			libc.memmove((^rawptr)(uintptr(blob) + 16)^, rawptr(uintptr(rawptr(p)) + uintptr(idx)), C.size_t(end - idx + 1))
			tv_blob_set_ret_o(rettv, blob)
			if length - end - 1 > 0 {
				libc.memmove(rawptr(uintptr(rawptr(p)) + uintptr(idx)), rawptr(uintptr(rawptr(p)) + uintptr(end) + 1), C.size_t(length - end - 1))
			}
			(^C.int)(uintptr(b) + 0)^ -= C.int(end - idx + 1)
		}
	}
}

// —— Batch 25b: dict watchers ——
// DictWatcher layout (cc-probed, sizeof 56): callback@0 (16B) / key_pattern@16
// / key_pattern_len@24 / node QUEUE@32 (next@0/prev@8) / busy@48 / needs_free@49.
DW_CALLBACK_OFF_O :: 0
DW_KEY_OFF_O :: 16
DW_KEYLEN_OFF_O :: 24
DW_NODE_OFF_O :: 32
DW_BUSY_OFF_O :: 48
DW_NEEDFREE_OFF_O :: 49
NEW_KEY_O : [4]u8 = {'n', 'e', 'w', 0}
OLD_KEY_O : [4]u8 = {'o', 'l', 'd', 0}

// True when key matches a watcher's *-suffix pattern (static in C).
tv_dict_watcher_matches_o :: proc "c" (watcher: rawptr, key: cstring) -> bool {
	context = runtime.default_context()
	length := (^C.size_t)(uintptr(watcher) + DW_KEYLEN_OFF_O)^
	pat := (^rawptr)(uintptr(watcher) + DW_KEY_OFF_O)^
	if length > 0 && ([^]u8)(pat)[uintptr(length) - 1] == '*' {
		return libc.strncmp(key, transmute(cstring)(pat), length - 1) == 0
	}
	return libc.strcmp(key, transmute(cstring)(pat)) == 0
}

// Add a change watcher to a dict.
@(export)
tv_dict_watcher_add :: proc "c" (dict: rawptr, key_pattern: cstring, key_pattern_len: C.size_t, callback: Callback_E) {
	context = runtime.default_context()
	if dict == nil {
		return
	}
	watcher := xmalloc(56)
	(^rawptr)(uintptr(watcher) + DW_KEY_OFF_O)^ = xmemdupz_o2(transmute(^u8)(key_pattern), key_pattern_len)
	(^C.size_t)(uintptr(watcher) + DW_KEYLEN_OFF_O)^ = key_pattern_len
	cb := callback
	libc.memcpy(rawptr(uintptr(watcher) + DW_CALLBACK_OFF_O), rawptr(&cb), 16)
	([^]u8)(uintptr(watcher) + DW_BUSY_OFF_O)[0] = 0
	([^]u8)(uintptr(watcher) + DW_NEEDFREE_OFF_O)[0] = 0
	head := rawptr(uintptr(dict) + 336)
	prev := (^rawptr)(uintptr(head) + 8)^
	(^rawptr)(uintptr(watcher) + DW_NODE_OFF_O + 8)^ = prev
	(^rawptr)(uintptr(watcher) + DW_NODE_OFF_O + 0)^ = head
	(^rawptr)(uintptr(prev) + 0)^ = rawptr(uintptr(watcher) + DW_NODE_OFF_O)
	(^rawptr)(uintptr(head) + 8)^ = rawptr(uintptr(watcher) + DW_NODE_OFF_O)
}

// Remove a matching watcher (deferred when busy).
@(export)
tv_dict_watcher_remove :: proc "c" (dict: rawptr, key_pattern: cstring, key_pattern_len: C.size_t, callback: Callback_E) -> bool {
	context = runtime.default_context()
	if dict == nil {
		return false
	}
	head := rawptr(uintptr(dict) + 336)
	w := (^rawptr)(uintptr(head) + 0)^
	matched: rawptr = nil
	matched_w: rawptr = nil
	queue_is_busy := false
	for w != head {
		watcher := rawptr(uintptr(w) - DW_NODE_OFF_O)
		if ([^]u8)(uintptr(watcher) + DW_BUSY_OFF_O)[0] != 0 {
			queue_is_busy = true
		}
		cb := callback
		if tv_callback_equal((^Callback_E)(uintptr(watcher) + DW_CALLBACK_OFF_O), &cb) && (^C.size_t)(uintptr(watcher) + DW_KEYLEN_OFF_O)^ == key_pattern_len && libcmemcmp((^rawptr)(uintptr(watcher) + DW_KEY_OFF_O)^, transmute(rawptr)(key_pattern), key_pattern_len) == 0 {
			matched = watcher
			matched_w = w
			break
		}
		w = (^rawptr)(uintptr(w) + 0)^
	}
	if matched == nil {
		return false
	}
	if queue_is_busy {
		([^]u8)(uintptr(matched) + DW_NEEDFREE_OFF_O)[0] = 1
	} else {
		nx := (^rawptr)(uintptr(matched_w) + 0)^
		pv := (^rawptr)(uintptr(matched_w) + 8)^
		(^rawptr)(uintptr(pv) + 0)^ = nx
		(^rawptr)(uintptr(nx) + 8)^ = pv
		tv_dict_watcher_free_o(matched)
	}
	return true
}

// Notify watchers of a dict change.
@(export)
tv_dict_watcher_notify :: proc "c" (dict: rawptr, key: cstring, newtv: ^Typval_T, oldtv: ^Typval_T) {
	context = runtime.default_context()
	argv: [3]Typval_T
	argv[0] = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(dict)}
	argv[1] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(key)))}
	argv[2] = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(tv_dict_alloc())}
	(^C.int)(uintptr(rawptr(argv[2].vval)) + 8)^ += 1
	if newtv != nil {
		v := tv_dict_item_alloc_len(transmute(cstring)(&NEW_KEY_O[0]), 3)
		tv_copy(newtv, (^Typval_T)(v))
		tv_dict_add(rawptr(argv[2].vval), v)
	}
	if oldtv != nil && oldtv.v_type != VAR_UNKNOWN {
		v := tv_dict_item_alloc_len(transmute(cstring)(&OLD_KEY_O[0]), 3)
		tv_copy(oldtv, (^Typval_T)(v))
		tv_dict_add(rawptr(argv[2].vval), v)
	}
	any_needs_free := false
	(^C.int)(uintptr(dict) + 8)^ += 1
	head := rawptr(uintptr(dict) + 336)
	w := (^rawptr)(uintptr(head) + 0)^
	for w != head {
		next := (^rawptr)(uintptr(w) + 0)^
		watcher := rawptr(uintptr(w) - DW_NODE_OFF_O)
		if ([^]u8)(uintptr(watcher) + DW_BUSY_OFF_O)[0] == 0 && tv_dict_watcher_matches_o(watcher, key) {
			rettv := Typval_T{}
			([^]u8)(uintptr(watcher) + DW_BUSY_OFF_O)[0] = 1
			callback_call(rawptr(uintptr(watcher) + DW_CALLBACK_OFF_O), 3, &argv[0], &rettv)
			([^]u8)(uintptr(watcher) + DW_BUSY_OFF_O)[0] = 0
			tv_clear(&rettv)
			if ([^]u8)(uintptr(watcher) + DW_NEEDFREE_OFF_O)[0] != 0 {
				any_needs_free = true
			}
		}
		w = next
	}
	if any_needs_free {
		w = (^rawptr)(uintptr(head) + 0)^
		for w != head {
			next := (^rawptr)(uintptr(w) + 0)^
			watcher := rawptr(uintptr(w) - DW_NODE_OFF_O)
			if ([^]u8)(uintptr(watcher) + DW_NEEDFREE_OFF_O)[0] != 0 {
				nx := (^rawptr)(uintptr(w) + 0)^
				pv := (^rawptr)(uintptr(w) + 8)^
				(^rawptr)(uintptr(pv) + 0)^ = nx
				(^rawptr)(uintptr(nx) + 8)^ = pv
				tv_dict_watcher_free_o(watcher)
			}
			w = next
		}
	}
	tv_dict_unref(dict)
	tv_clear(&argv[1])
	tv_clear(&argv[2])
}

// —— Batch 26o: vars.c heredoc reader ——
E221_S :: "E221: Marker cannot start with lower case letter"
E172_S :: "E172: Missing marker"
E990_S :: "E990: Missing end marker '%s'"
E991_S :: "E991: Cannot use =<< here"
DOT1S_O : [2]u8 = {'.', 0}

// Read a heredoc body into a list of lines.
@(export)
heredoc_get :: proc "c" (eap: rawptr, cmd: cstring, script_get: bool) -> rawptr {
	context = runtime.default_context()
	marker: cstring = nil
	marker_indent_len: C.int = 0
	text_indent_len: C.int = 0
	text_indent: cstring = nil
	dot := transmute(cstring)(&DOT1S_O[0])
	heredoc_in_string := false
	line_arg: cstring = nil
	c := cmd
	nl_ptr := vim_strchr_c(transmute(^u8)(c), '\n')
	if nl_ptr != nil {
		heredoc_in_string = true
		line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(nl_ptr)) + 1))
		([^]u8)(nl_ptr)[0] = 0
	} else if (^rawptr)(uintptr(eap) + 168)^ == nil {
		emsg(cstring(E991_S))
		return nil
	}
	c = skipwhite(c)
	evalstr := false
	eval_failed := false
	for {
		if libc.strncmp(c, cstring("trim"), 4) == 0 && (([^]u8)(c)[4] == 0 || ascii_iswhite(([^]u8)(c)[4])) {
			c = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(c)) + 4)))
			cp := (^cstring)(uintptr(eap) + 48)^
			for ascii_iswhite(([^]u8)(cp)[0]) {
				cp = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(cp)) + 1))
				marker_indent_len += 1
			}
			text_indent_len = -1
			continue
		}
		if libc.strncmp(c, cstring("eval"), 4) == 0 && (([^]u8)(c)[4] == 0 || ascii_iswhite(([^]u8)(c)[4])) {
			c = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(c)) + 4)))
			evalstr = true
			continue
		}
		break
	}
	if ([^]u8)(c)[0] != 0 && ([^]u8)(c)[0] != '"' {
		marker = skipwhite(c)
		p := skiptowhite(marker)
		if ([^]u8)(skipwhite(p))[0] != 0 && ([^]u8)(skipwhite(p))[0] != '"' {
			semsg(cstring(E488_S), p)
			return nil
		}
		([^]u8)(p)[0] = 0
		if !script_get && ([^]u8)(marker)[0] >= 'a' && ([^]u8)(marker)[0] <= 'z' {
			emsg(cstring(E221_S))
			return nil
		}
	} else {
		if script_get {
			marker = dot
		} else {
			emsg(cstring(E172_S))
			return nil
		}
	}
	theline: cstring = nil
	l := tv_list_alloc(0)
	for {
		mi: C.int = 0
		ti: C.int = 0
		if heredoc_in_string {
			if ([^]u8)(line_arg)[0] == 0 {
				if !script_get {
					semsg(cstring(E990_S), marker)
				}
				break
			}
			theline = line_arg
			next_line := vim_strchr_c(transmute(^u8)(theline), '\n')
			if next_line == nil {
				line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(line_arg)) + uintptr(libc.strlen(line_arg))))
			} else {
				([^]u8)(next_line)[0] = 0
				line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(next_line)) + 1))
			}
		} else {
			xfree(rawptr(theline))
			gl := (^LineGetter)(uintptr(eap) + 168)^
			theline = transmute(cstring)(gl(0, (^rawptr)(uintptr(eap) + 176)^, 0, false))
			if theline == nil {
				if !script_get {
					semsg(cstring(E990_S), marker)
				}
				break
			}
		}
		if marker_indent_len > 0 && libc.strncmp(theline, (^cstring)(uintptr(eap) + 48)^, C.size_t(marker_indent_len)) == 0 {
			mi = marker_indent_len
		}
		if libc.strcmp(marker, transmute(cstring)(rawptr(uintptr(transmute(rawptr)(theline)) + uintptr(mi)))) == 0 {
			break
		}
		if eval_failed {
			continue
		}
		if text_indent_len == -1 && ([^]u8)(theline)[0] != 0 {
			p := theline
			text_indent_len = 0
			for ascii_iswhite(([^]u8)(p)[0]) {
				p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
				text_indent_len += 1
			}
			text_indent = transmute(cstring)(xmemdupz_o2(transmute(^u8)(theline), C.size_t(text_indent_len)))
		}
		if text_indent != nil {
			for ti = 0; ti < text_indent_len; ti += 1 {
				if ([^]u8)(theline)[uintptr(ti)] != ([^]u8)(text_indent)[uintptr(ti)] {
					break
				}
			}
		}
		str := transmute(cstring)(rawptr(uintptr(transmute(rawptr)(theline)) + uintptr(ti)))
		if evalstr && !(^bool)(uintptr(eap) + 72)^ {
			ev := eval_all_expr_in_str_o(transmute(^u8)(str))
			if ev == nil {
				eval_failed = true
				continue
			}
			tv_list_append_allocated_string(l, ev)
		} else {
			tv_list_append_string(l, transmute(^u8)(str), -1)
		}
	}
	if heredoc_in_string {
		(^rawptr)(uintptr(eap) + 32)^ = rawptr(line_arg)
	} else {
		xfree(rawptr(theline))
	}
	xfree(rawptr(text_indent))
	if eval_failed {
		tv_list_free(l)
		return nil
	}
	return l
}

// —— Batch 26n: vars.c init + GC markers ——
foreign _ {
	@(link_name = "highest_patch")
	highest_patch_e :: proc "c" () -> C.int ---
}

VV_SEARCHFORWARD_O :: 56
VV_HLSEARCH_O :: 57
VV_FALSE_O :: 69
VV_TRUE_O :: 70
VV_NULL_O :: 71
VV_NUMBERMAX_O :: 72
VV_NUMBERMIN_O :: 73
VV_NUMBERSIZE_O :: 74
VV_TYPE_NUMBER_O :: 77
VV_TYPE_STRING_O :: 78
VV_TYPE_FUNC_O :: 79
VV_TYPE_LIST_O :: 80
VV_TYPE_DICT_O :: 81
VV_TYPE_FLOAT_O :: 82
VV_TYPE_BOOL_O :: 83
VV_TYPE_BLOB_O :: 84
VV_EVENT_O :: 85
VV_VERSIONLONG_O :: 86
VV_EXITING_O :: 91
VV_MAXCOL_O :: 92
VV_MSGPACK_TYPES_O :: 96
VV_LUA_O :: 101
VV_STARTREASON_O :: 107
VV_COMPLETED_ITEM_O :: 61
VV_VERSION_O :: 8
VV_COMPAT_O :: 1
VV_RO_O :: 2
VV_RO_SBX_O :: 4
VAR_TYPE_NUMBER_O :: 0
VAR_TYPE_STRING_O :: 1
VAR_TYPE_FUNC_O :: 2
VAR_TYPE_LIST_O :: 3
VAR_TYPE_DICT_O :: 4
VAR_TYPE_FLOAT_O :: 5
VAR_TYPE_BOOL_O :: 6
VAR_TYPE_BLOB_O :: 10
ENV_STARTREASON_O :: "__NVIM_STARTREASON"
MSGPACK_NAMES_O : [8]cstring = {"nil", "boolean", "integer", "float", "string", "array", "map", "ext"}

// Initialize all v:/g: scope tables (runs once at startup).
@(export)
evalvars_init :: proc "c" () {
	context = runtime.default_context()
	init_var_dict(get_globvar_dict(), globvars_var_e(), VAR_DEF_SCOPE_O)
	init_var_dict(get_vimvar_dict(), vimvars_var_e(), VAR_SCOPE_O)
	(^C.int)(uintptr(get_vimvar_dict()) + 0)^ = VAR_FIXED_O
	hash_init(compat_hashtab_e())
	i := 0
	for i < 108 {
		tv := vimvar_tv_e(C.int(i))
		fl := ([^]u8)(rawptr(uintptr(transmute(rawptr)(tv)) - 8 + 48))[0]
		di_flags := (^u8)(uintptr(transmute(rawptr)(tv)) + 16)
		if (fl & VV_RO_O) != 0 {
			di_flags^ = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
		} else if (fl & VV_RO_SBX_O) != 0 {
			di_flags^ = DI_FLAGS_RO_SBX_O | DI_FLAGS_FIX_O
		} else {
			di_flags^ = DI_FLAGS_FIX_O
		}
		if (^C.int)(uintptr(transmute(rawptr)(tv)))^ != VAR_UNKNOWN {
			hash_add(rawptr(uintptr(get_vimvar_dict()) + 16), transmute(^u8)(rawptr(uintptr(transmute(rawptr)(tv)) + 17)))
		}
		if (fl & VV_COMPAT_O) != 0 {
			hash_add(compat_hashtab_e(), transmute(^u8)(rawptr(uintptr(transmute(rawptr)(tv)) + 17)))
		}
		i += 1
	}
	vim_version := min_vim_version_r()
	set_vim_var_nr(VV_VERSION_O, i64(vim_version))
	set_vim_var_nr(VV_VERSIONLONG_O, i64(vim_version) * 10000 + i64(highest_patch_e()))
	mtd := tv_dict_alloc()
	for k := 0; k < 8; k += 1 {
		tl := tv_list_alloc(0)
		(^C.int)(uintptr(tl) + 72)^ = VAR_FIXED_O
		tv_list_ref_o(tl)
		di := tv_dict_item_alloc(MSGPACK_NAMES_O[k])
		([^]u8)(uintptr(di) + 16)[0] |= DI_FLAGS_RO_O | DI_FLAGS_FIX_O
		(^Typval_T)(di)^ = Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(tl)}
		eval_msgpack_type_lists_e[k] = tl
		if tv_dict_add(mtd, di) == FAIL_E {
			libc.abort()
		}
	}
	(^C.int)(uintptr(mtd) + 0)^ = VAR_FIXED_O
	set_vim_var_dict(VV_MSGPACK_TYPES_O, mtd)
	set_vim_var_dict(VV_COMPLETED_ITEM_O, tv_dict_alloc_lock(2))
	set_vim_var_dict(VV_EVENT_O, tv_dict_alloc_lock(2))
	set_vim_var_nr(VV_SEARCHFORWARD_O, 1)
	set_vim_var_nr(VV_HLSEARCH_O, 1)
	set_vim_var_nr(VV_COUNT1_O, 1)
	set_vim_var_string(VV_STARTREASON_O, cstring("normal"), 6)
	set_vim_var_special(VV_EXITING_O, 0)
	set_vim_var_nr(VV_TYPE_NUMBER_O, VAR_TYPE_NUMBER_O)
	set_vim_var_nr(VV_TYPE_STRING_O, VAR_TYPE_STRING_O)
	set_vim_var_nr(VV_TYPE_FUNC_O, VAR_TYPE_FUNC_O)
	set_vim_var_nr(VV_TYPE_LIST_O, VAR_TYPE_LIST_O)
	set_vim_var_nr(VV_TYPE_DICT_O, VAR_TYPE_DICT_O)
	set_vim_var_nr(VV_TYPE_FLOAT_O, VAR_TYPE_FLOAT_O)
	set_vim_var_nr(VV_TYPE_BOOL_O, VAR_TYPE_BOOL_O)
	set_vim_var_nr(VV_TYPE_BLOB_O, VAR_TYPE_BLOB_O)
	set_vim_var_bool(VV_FALSE_O, 0)
	set_vim_var_bool(VV_TRUE_O, 1)
	set_vim_var_special(VV_NULL_O, 0)
	set_vim_var_nr(VV_NUMBERMAX_O, max(i64))
	set_vim_var_nr(VV_NUMBERMIN_O, min(i64))
	set_vim_var_nr(VV_NUMBERSIZE_O, 64)
	set_vim_var_nr(VV_MAXCOL_O, i64(MAXCOL))
	set_vim_var_nr(VV_ECHOSPACE_O, i64(sc_col) - 1)
	vvlua := xcalloc(1, 48)
	vvname := xmalloc(1)
	([^]u8)(vvname)[0] = 0
	([^]rawptr)(vvlua)[1] = vvname
	(^C.int)(vvlua)^ = 1
	set_vim_var_partial(VV_LUA_O, vvlua)
	set_reg_var(0)
	sr := os_getenv_noalloc(cstring(ENV_STARTREASON_O))
	if (sr != nil && libc.strcmp(sr, cstring("restart!")) == 0) || (sr != nil && libc.strcmp(sr, cstring("restart")) == 0) {
		set_vim_var_string(VV_STARTREASON_O, sr, -1)
	}
	if os_env_exists(cstring(ENV_STARTREASON_O), false) {
		os_unsetenv(cstring(ENV_STARTREASON_O))
	}
}

// Mark g: variables for garbage collection.
@(export)
garbage_collect_globvars :: proc "c" (copyID: C.int) -> C.int {
	context = runtime.default_context()
	if set_ref_in_ht(rawptr(uintptr(get_globvar_dict()) + 16), copyID, nil) {
		return 1
	}
	return 0
}

// Mark v: variables for garbage collection.
@(export)
garbage_collect_vimvars :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	return set_ref_in_ht(rawptr(uintptr(get_vimvar_dict()) + 16), copyID, nil)
}

// Mark s: variables for garbage collection.
@(export)
garbage_collect_scriptvars :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	abort := false
	i: C.int = 1
	for i <= script_items_g.ga_len {
		item := ([^]rawptr)(script_items_g.ga_data)[uintptr(i) - 1]
		sv := (^rawptr)(uintptr(item) + 0)^
		if set_ref_in_ht(rawptr(uintptr(sv) + 24 + 16), copyID, nil) {
			abort = true
		}
		i += 1
	}
	return abort
}

// —— Batch 26m: vars.c vimvar save/restore + completion ——
VIMVARS_LEN_O :: 108

@(private = "file")
guvn_gdone: C.size_t
@(private = "file")
guvn_bdone: C.size_t
@(private = "file")
guvn_wdone: C.size_t
@(private = "file")
guvn_tdone: C.size_t
@(private = "file")
guvn_vidx: C.size_t
@(private = "file")
guvn_hi: rawptr

// Save a v: variable for temporary reuse.
@(export)
prepare_vimvar :: proc "c" (idx: C.int, save_tv: ^Typval_T) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	save_tv^ = tv^
	tv.vval = nil
	if tv.v_type == VAR_UNKNOWN {
		hash_add(rawptr(uintptr(get_vimvar_dict()) + 16), transmute(^u8)(rawptr(uintptr(transmute(rawptr)(tv)) + 17)))
	}
}

// Restore a saved v: variable.
@(export)
restore_vimvar :: proc "c" (idx: C.int, save_tv: ^Typval_T) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv^ = save_tv^
	if tv.v_type != VAR_UNKNOWN {
		return
	}
	ht := rawptr(uintptr(get_vimvar_dict()) + 16)
	hi := hash_find(ht, transmute(cstring)(rawptr(uintptr(transmute(rawptr)(tv)) + 17)))
	if hi != nil {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
			hi = nil
		}
	}
	if hi == nil {
		iemsg_r(cstring("restore_vimvar()"))
	} else {
		hash_remove(ht, hi)
	}
}

// Iterated variable-name completion across scopes.
@(export)
get_user_var_name :: proc "c" (xp: rawptr, idx: C.int) -> cstring {
	context = runtime.default_context()
	if idx == 0 {
		guvn_gdone = 0
		guvn_bdone = 0
		guvn_wdone = 0
		guvn_vidx = 0
		guvn_tdone = 0
	}
	ght := globvarht_e()
	if guvn_gdone < (^C.size_t)(uintptr(ght) + 8)^ {
		if guvn_gdone == 0 {
			guvn_hi = (^rawptr)(uintptr(ght) + 32)^
		} else {
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		guvn_gdone += 1
		for {
			hi_key := (^rawptr)(uintptr(guvn_hi) + 8)^
			if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed) {
				break
			}
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		pat := (^cstring)(xp)^
		if ([^]u8)(pat)[0] == 'g' && ([^]u8)(pat)[1] == ':' {
			return cat_prefix_varname('g', transmute(cstring)((^rawptr)(uintptr(guvn_hi) + 8)^))
		}
		return transmute(cstring)((^rawptr)(uintptr(guvn_hi) + 8)^)
	}
	ht := rawptr(uintptr((^rawptr)(uintptr(prevwin_curwin()) + W_BUFFER_OFF)^) + B_VARS_OFF)
	ht = rawptr(uintptr((^rawptr)(ht)^) + 16)
	if guvn_bdone < (^C.size_t)(uintptr(ht) + 8)^ {
		if guvn_bdone == 0 {
			guvn_hi = (^rawptr)(uintptr(ht) + 32)^
		} else {
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		guvn_bdone += 1
		for {
			hi_key := (^rawptr)(uintptr(guvn_hi) + 8)^
			if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed) {
				break
			}
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		return cat_prefix_varname('b', transmute(cstring)((^rawptr)(uintptr(guvn_hi) + 8)^))
	}
	ht = rawptr(uintptr((^rawptr)(uintptr(prevwin_curwin()) + W_VARS_OFF)^) + 16)
	if guvn_wdone < (^C.size_t)(uintptr(ht) + 8)^ {
		if guvn_wdone == 0 {
			guvn_hi = (^rawptr)(uintptr(ht) + 32)^
		} else {
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		guvn_wdone += 1
		for {
			hi_key := (^rawptr)(uintptr(guvn_hi) + 8)^
			if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed) {
				break
			}
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		return cat_prefix_varname('w', transmute(cstring)((^rawptr)(uintptr(guvn_hi) + 8)^))
	}
	ht = rawptr(uintptr((^rawptr)(uintptr(curtab) + TP_VARS_OFF)^) + 16)
	if guvn_tdone < (^C.size_t)(uintptr(ht) + 8)^ {
		if guvn_tdone == 0 {
			guvn_hi = (^rawptr)(uintptr(ht) + 32)^
		} else {
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		guvn_tdone += 1
		for {
			hi_key := (^rawptr)(uintptr(guvn_hi) + 8)^
			if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed) {
				break
			}
			guvn_hi = rawptr(uintptr(guvn_hi) + 16)
		}
		return cat_prefix_varname('t', transmute(cstring)((^rawptr)(uintptr(guvn_hi) + 8)^))
	}
	if guvn_vidx < VIMVARS_LEN_O {
		vidx := guvn_vidx
		guvn_vidx += 1
		return cat_prefix_varname('v', get_vim_var_name(C.int(vidx)))
	}
	if varnamebuf_g != nil {
		xfree(varnamebuf_g)
		varnamebuf_g = nil
	}
	varnamebuflen_g = 0
	return nil
}

// —— Batch 26l: vars.c init/error leaves ——
VV_OPTION_NEW_O :: 62
VV_OPTION_OLD_O :: 63
VV_OPTION_OLDLOCAL_O :: 64
VV_OPTION_OLDGLOBAL_O :: 65
VV_OPTION_COMMAND_O :: 66
VV_OPTION_TYPE_O :: 67
VV_ERRORS_O :: 68

@(private = "file")
varnamebuf_g: rawptr
@(private = "file")
varnamebuflen_g: C.size_t

// Make a new script-local scope for a sourced script.
@(export)
new_script_vars :: proc "c" (id: C.int) {
	context = runtime.default_context()
	sv := xcalloc(1, 384)
	init_var_dict(rawptr(uintptr(sv) + 24), rawptr(uintptr(sv) + 0), VAR_SCOPE_O)
	item := ([^]rawptr)(script_items_g.ga_data)[uintptr(int(id) - 1)]
	(^rawptr)(uintptr(item) + 0)^ = sv
}

// Reset v:option_* after option handling.
@(export)
reset_v_option_vars :: proc "c" () {
	context = runtime.default_context()
	set_vim_var_string(VV_OPTION_NEW_O, nil, -1)
	set_vim_var_string(VV_OPTION_OLD_O, nil, -1)
	set_vim_var_string(VV_OPTION_OLDLOCAL_O, nil, -1)
	set_vim_var_string(VV_OPTION_OLDGLOBAL_O, nil, -1)
	set_vim_var_string(VV_OPTION_COMMAND_O, nil, -1)
	set_vim_var_string(VV_OPTION_TYPE_O, nil, -1)
}

// Append an assert failure to v:errors.
@(export)
assert_error :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	tv := get_vim_var_tv(VV_ERRORS_O)
	if tv.v_type != VAR_LIST || rawptr(tv.vval) == nil {
		set_vim_var_list(VV_ERRORS_O, tv_list_alloc(1))
	}
	tv_list_append_string(get_vim_var_list(VV_ERRORS_O), transmute(^u8)(gap.ga_data), C.ssize_t(gap.ga_len))
}

// Build "p:name" in a reusable buffer (freed by get_user_var_name).
@(export)
cat_prefix_varname :: proc "c" (prefix: C.int, name: cstring) -> cstring {
	context = runtime.default_context()
	length := C.size_t(libc.strlen(name)) + 3
	if length > varnamebuflen_g {
		xfree(varnamebuf_g)
		length += 10
		varnamebuf_g = xmalloc(length)
		varnamebuflen_g = length
	}
	buf := ([^]u8)(varnamebuf_g)
	buf[0] = u8(prefix)
	buf[1] = ':'
	libc.memcpy(rawptr(&buf[2]), transmute(rawptr)(name), C.size_t(libc.strlen(name)) + 1)
	return transmute(cstring)(varnamebuf_g)
}

// —— Batch 26k: vars.c v: enforcement ——
// Extra handling when assigning a v: variable (type-locked slots).
@(export)
before_set_vvar :: proc "c" (varname: cstring, di: rawptr, tv: ^Typval_T, copy: bool, watched: bool, type_error: ^bool) -> bool {
	context = runtime.default_context()
	ditv := (^Typval_T)(di)
	if ditv.v_type == VAR_STRING {
		oldtv := Typval_T{}
		if watched {
			tv_copy(ditv, &oldtv)
		}
		if rawptr(ditv.vval) != nil {
			xfree(rawptr(ditv.vval))
			ditv.vval = nil
		}
		if copy || tv.v_type != VAR_STRING {
			val := tv_get_string(tv)
			if rawptr(ditv.vval) == nil {
				ditv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(val)))
			}
		} else {
			ditv.vval = tv.vval
			tv.vval = nil
		}
		if watched {
			tv_dict_watcher_notify(get_vimvar_dict(), varname, ditv, &oldtv)
			tv_clear(&oldtv)
		}
		return false
	} else if ditv.v_type == VAR_NUMBER {
		oldtv := Typval_T{}
		if watched {
			tv_copy(ditv, &oldtv)
		}
		n := transmute(C.longlong)(tv_get_number(tv))
		ditv.vval = transmute(rawptr)(n)
		if libc.strcmp(varname, cstring("searchforward")) == 0 {
			if n != 0 {
				set_search_direction('/')
			} else {
				set_search_direction('?')
			}
		} else if libc.strcmp(varname, cstring("hlsearch")) == 0 {
			no_hlsearch = n == 0
			redraw_all_later(UPD_SOME_VALID_O)
		}
		if watched {
			tv_dict_watcher_notify(get_vimvar_dict(), varname, ditv, &oldtv)
			tv_clear(&oldtv)
		}
		return false
	} else if ditv.v_type != tv.v_type {
		type_error^ = true
		return false
	}
	return true
}

// —— Batch 26j: vars.c redir cluster ——
// Redirection state (were C file-statics; no C readers outside vars.c).
@(private = "file")
redir_lval_g: rawptr
@(private = "file")
redir_ga_g: Garray
@(private = "file")
redir_endp_g: cstring
@(private = "file")
redir_varname_g: cstring

// Start recording :redir output into a variable.
@(export)
var_redir_start :: proc "c" (name: cstring, append: bool) -> C.int {
	context = runtime.default_context()
	if !eval_isnamec1(C.int(([^]u8)(name)[0])) {
		emsg(e_invarg_s)
		return FAIL_E
	}
	redir_varname_g = transmute(cstring)(xstrdup_o(transmute(^u8)(name)))
	redir_lval_g = xcalloc(1, 96)
	ga_init(&redir_ga_g, 1, 500)
	redir_endp_g = get_lval(redir_varname_g, nil, redir_lval_g, false, false, 0, FNE_CHECK_START_O)
	if redir_endp_g == nil || (^rawptr)(uintptr(redir_lval_g) + LL_NAME_OFF_O)^ == nil || ([^]u8)(redir_endp_g)[0] != 0 {
		clear_lval(redir_lval_g)
		if redir_endp_g != nil && ([^]u8)(redir_endp_g)[0] != 0 {
			semsg(cstring(E488_S), redir_endp_g)
		} else {
			semsg(e_invarg2, name)
		}
		redir_endp_g = nil
		var_redir_stop()
		return FAIL_E
	}
	called_before := called_emsg
	did_emsg_set(false)
	tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(cstring(""))}
	if append {
		set_var_lval(redir_lval_g, redir_endp_g, &tv, true, false, cstring("."))
	} else {
		set_var_lval(redir_lval_g, redir_endp_g, &tv, true, false, cstring("="))
	}
	clear_lval(redir_lval_g)
	if called_emsg > called_before {
		redir_endp_g = nil
		var_redir_stop()
		return FAIL_E
	}
	return OK_E
}

// Append output text to the redir buffer.
@(export)
var_redir_str :: proc "c" (value: cstring, value_len: C.int) {
	context = runtime.default_context()
	if redir_lval_g == nil {
		return
	}
	length := value_len
	if length == -1 {
		length = C.int(libc.strlen(value))
	}
	ga_grow(&redir_ga_g, length)
	libc.memmove(rawptr(uintptr(redir_ga_g.ga_data) + uintptr(redir_ga_g.ga_len)), transmute(rawptr)(value), C.size_t(length))
	redir_ga_g.ga_len += length
}

// Stop redirection, assigning the collected text.
@(export)
var_redir_stop :: proc "c" () {
	context = runtime.default_context()
	if redir_lval_g != nil {
		if redir_endp_g != nil {
			ga_append(&redir_ga_g, 0)
			tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(redir_ga_g.ga_data)}
			redir_endp_g = get_lval(redir_varname_g, nil, redir_lval_g, false, false, 0, FNE_CHECK_START_O)
			if redir_endp_g != nil && (^rawptr)(uintptr(redir_lval_g) + LL_NAME_OFF_O)^ != nil {
				set_var_lval(redir_lval_g, redir_endp_g, &tv, false, false, cstring("."))
			}
			clear_lval(redir_lval_g)
		}
		if redir_ga_g.ga_data != nil {
			xfree(redir_ga_g.ga_data)
			redir_ga_g.ga_data = nil
		}
		if redir_lval_g != nil {
			xfree(redir_lval_g)
			redir_lval_g = nil
		}
	}
	if redir_varname_g != nil {
		xfree(rawptr(redir_varname_g))
		redir_varname_g = nil
	}
}

// —— Batch 26i: vars.c small leaves ——
foreign _ {
	@(link_name = "nvim_odin_globvardict")
	globvardict_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_globvarht")
	globvarht_e :: proc "c" () -> rawptr ---
}

FORCE_BIN_O :: 1
FORCE_NOBIN_O :: 2
BAD_KEEP_O :: -1
BAD_DROP_O :: -2
VV_COUNT_O :: 0
VV_COUNT1_O :: 1
VV_PREVCOUNT_O :: 2
VV_CMDARG_O :: 22
VV_EXCEPTION_O :: 30
VV_THROWPOINT_O :: 31
VV_REG_O :: 32
EXARG_FORCE_BIN_OFF_O :: 132
EXARG_READ_EDIT_OFF_O :: 136
EXARG_MKDIR_P_OFF_O :: 140
EXARG_FORCE_FF_OFF_O :: 144
EXARG_FORCE_ENC_OFF_O :: 148
EXARG_BAD_CHAR_OFF_O :: 152

// Get the g: scope dict.
@(export)
get_globvar_dict :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return globvardict_e()
}

// Get the g: scope hashtable.
@(export)
get_globvar_ht :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return globvarht_e()
}

// Get/set v:exception (borrowed pointers, paired calls).
@(export)
v_exception :: proc "c" (oldval: cstring) -> cstring {
	context = runtime.default_context()
	tv := get_vim_var_tv(VV_EXCEPTION_O)
	if oldval == nil {
		return transmute(cstring)(rawptr(tv.vval))
	}
	tv.vval = transmute(rawptr)(oldval)
	return nil
}

// Get/set v:throwpoint (borrowed pointers, paired calls).
@(export)
v_throwpoint :: proc "c" (oldval: cstring) -> cstring {
	context = runtime.default_context()
	tv := get_vim_var_tv(VV_THROWPOINT_O)
	if oldval == nil {
		return transmute(cstring)(rawptr(tv.vval))
	}
	tv.vval = transmute(rawptr)(oldval)
	return nil
}

// Set v:register from a character.
@(export)
set_reg_var :: proc "c" (c: C.int) {
	context = runtime.default_context()
	buf: [2]u8
	if c == 0 || c == ' ' {
		buf[0] = '"'
	} else {
		buf[0] = u8(c)
	}
	buf[1] = 0
	tv := get_vim_var_tv(VV_REG_O)
	if rawptr(tv.vval) == nil || ([^]u8)(rawptr(tv.vval))[0] != u8(c) {
		set_vim_var_string(VV_REG_O, transmute(cstring)(&buf[0]), 1)
	}
}

// Set v:count/v:count1 (and v:prevcount).
@(export)
set_vcount :: proc "c" (count: i64, count1: i64, set_prevcount: bool) {
	context = runtime.default_context()
	if set_prevcount {
		get_vim_var_tv(VV_PREVCOUNT_O).vval = transmute(rawptr)(C.longlong(get_vim_var_nr(VV_COUNT_O)))
	}
	get_vim_var_tv(VV_COUNT_O).vval = transmute(rawptr)(C.longlong(count))
	get_vim_var_tv(VV_COUNT1_O).vval = transmute(rawptr)(C.longlong(count1))
}

// Build/restore v:cmdarg from :edit ++opt flags.
@(export)
set_cmdarg :: proc "c" (eap: rawptr, oldarg: cstring) -> cstring {
	context = runtime.default_context()
	tv := get_vim_var_tv(VV_CMDARG_O)
	oldval := transmute(cstring)(rawptr(tv.vval))
	if eap == nil {
		xfree(rawptr(oldval))
		tv.vval = transmute(rawptr)(oldarg)
		return nil
	}
	length: C.size_t = 0
	if (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ == FORCE_BIN_O {
		length += 6
	} else if (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ == FORCE_NOBIN_O {
		length += 8
	}
	if (^bool)(uintptr(eap) + EXARG_READ_EDIT_OFF_O)^ {
		length += 7
	}
	if (^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^ != 0 {
		length += 10
	}
	if (^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^ != 0 {
		length += C.size_t(libc.strlen(transmute(cstring)(rawptr(uintptr((^rawptr)(uintptr(eap) + 40)^) + uintptr((^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^))))) + 7
	}
	if (^C.int)(uintptr(eap) + EXARG_BAD_CHAR_OFF_O)^ != 0 {
		length += 11
	}
	if (^C.int)(uintptr(eap) + EXARG_MKDIR_P_OFF_O)^ != 0 {
		length += 4
	}
	newval_len := length + 1
	newval := transmute([^]u8)(xmalloc(newval_len))
	xlen: C.size_t = 0
	rc: C.int = 0
	if (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ == FORCE_BIN_O {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++bin"))
	} else if (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ == FORCE_NOBIN_O {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++nobin"))
	} else {
		newval[0] = 0
	}
	if rc < 0 {
		xfree(rawptr(oldval))
		tv.vval = transmute(rawptr)(oldarg)
		return nil
	}
	xlen += C.size_t(rc)
	if (^bool)(uintptr(eap) + EXARG_READ_EDIT_OFF_O)^ {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++edit"))
		if rc < 0 {
			xfree(rawptr(oldval))
			tv.vval = transmute(rawptr)(oldarg)
			return nil
		}
		xlen += C.size_t(rc)
	}
	if (^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^ != 0 {
		ff: cstring = "mac"
		if (^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^ == 'u' {
			ff = "unix"
		} else if (^C.int)(uintptr(eap) + EXARG_FORCE_FF_OFF_O)^ == 'd' {
			ff = "dos"
		}
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++ff=%s"), cstring(ff))
		if rc < 0 {
			xfree(rawptr(oldval))
			tv.vval = transmute(rawptr)(oldarg)
			return nil
		}
		xlen += C.size_t(rc)
	}
	if (^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^ != 0 {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++enc=%s"), transmute(cstring)(rawptr(uintptr((^rawptr)(uintptr(eap) + 40)^) + uintptr((^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^))))
		if rc < 0 {
			xfree(rawptr(oldval))
			tv.vval = transmute(rawptr)(oldarg)
			return nil
		}
		xlen += C.size_t(rc)
	}
	bc := (^C.int)(uintptr(eap) + EXARG_BAD_CHAR_OFF_O)^
	if bc == BAD_KEEP_O {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++bad=keep"))
	} else if bc == BAD_DROP_O {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++bad=drop"))
	} else if bc != 0 {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++bad=%c"), bc)
	}
	if bc != 0 && rc < 0 {
		xfree(rawptr(oldval))
		tv.vval = transmute(rawptr)(oldarg)
		return nil
	}
	if bc != 0 {
		xlen += C.size_t(rc)
	}
	if (^C.int)(uintptr(eap) + EXARG_MKDIR_P_OFF_O)^ != 0 {
		rc = libc.snprintf(([^]u8)(rawptr(uintptr(newval) + uintptr(xlen))), newval_len - xlen, cstring(" ++p"))
		if rc < 0 {
			xfree(rawptr(oldval))
			tv.vval = transmute(rawptr)(oldarg)
			return nil
		}
		xlen += C.size_t(rc)
	}
	tv.vval = transmute(rawptr)(newval)
	return oldval
}

// True when a variable (with subscripts) exists.
@(export)
var_exists :: proc "c" (var: cstring) -> bool {
	context = runtime.default_context()
	tofree: cstring = nil
	n := false
	v := var
	name := var
	length := get_name_len(&v, &tofree, true, false)
	if length > 0 {
		tv := Typval_T{}
		if tofree != nil {
			name = tofree
		}
		n = eval_variable(name, length, &tv, nil, false, true) == OK_E
		if n {
			ea := Evalarg_T{eval_flags = 1}
			n = handle_subscript(&v, &tv, rawptr(&ea), false) == OK_E
			if n {
				tv_clear(&tv)
			}
		}
	}
	if ([^]u8)(v)[0] != 0 {
		n = false
	}
	xfree(rawptr(tofree))
	return n
}

// —— Batch 26h: :let engine ——

E687_S :: "E687: Less targets than List items"
E688_S :: "E688: More targets than List items"
E738_S :: "E738: Can't list variables for %s"
E121_S :: "E121: Undefined variable: %.*s"
CMD_CONST_O :: 99

// Evaluate a variable into rettv (for :let lval listing).
@(export)
eval_variable :: proc "c" (name: cstring, length: C.int, rettv: ^Typval_T, dip: rawptr, verbose: bool, no_autoload: bool) -> C.int {
	context = runtime.default_context()
	ret: C.int = OK_E
	tv: ^Typval_T = nil
	na: C.int = 0
	if no_autoload {
		na = 1
	}
	v := find_var(name, C.size_t(length), nil, na)
	if v != nil {
		tv = (^Typval_T)(v)
		if dip != nil {
			(^rawptr)(dip)^ = v
		}
	}
	if tv == nil {
		if rettv != nil && verbose {
			semsg(cstring(E121_S), length, name)
		}
		ret = FAIL_E
	} else if rettv != nil {
		tv_copy(tv, rettv)
	}
	return ret
}

// Flag l:/a: usage for lambda analysis.
@(export)
check_vars :: proc "c" (name: cstring, length: C.size_t) {
	context = runtime.default_context()
	if eval_lavars_used == nil {
		return
	}
	varname: cstring = nil
	ht := find_var_ht(name, length, &varname)
	if ht == get_funccal_local_ht() || ht == get_funccal_args_ht() {
		if find_var(name, length, nil, 1) != nil {
			eval_lavars_used^ = true
		}
	}
}

// List one scope's variables (statics in C).
list_glob_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	list_hashtable_vars(rawptr(uintptr(	get_globvar_dict()) + 16), cstring(""), 1, first)
}
list_buf_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	list_hashtable_vars(rawptr(uintptr((^rawptr)(uintptr(curbuf) + B_VARS_OFF)^) + 16), cstring("b:"), 1, first)
}
list_win_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	list_hashtable_vars(rawptr(uintptr((^rawptr)(uintptr(curwin) + W_VARS_OFF)^) + 16), cstring("w:"), 1, first)
}
list_tab_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	list_hashtable_vars(rawptr(uintptr((^rawptr)(uintptr(curtab) + TP_VARS_OFF)^) + 16), cstring("t:"), 1, first)
}
list_script_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
	if sid > 0 && sid <= script_items_g.ga_len {
		item := ([^]rawptr)(script_items_g.ga_data)[uintptr(int(sid) - 1)]
		sv := (^rawptr)(uintptr(item) + 0)^
		list_hashtable_vars(rawptr(uintptr(sv) + 24 + 16), cstring("s:"), 0, first)
	}
}
list_vim_vars_o :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	list_hashtable_vars(rawptr(uintptr(get_vimvar_dict()) + 16), cstring("v:"), 0, first)
}

// List ":let var1 var2" variables (static in C).
list_arg_vars_o :: proc "c" (eap: rawptr, arg: cstring, first: ^C.int) -> cstring {
	context = runtime.default_context()
	a := arg
	error := false
	for ends_excmd(C.int(([^]u8)(a)[0])) == 0 && !got_int {
		if error || (^bool)(uintptr(eap) + 72)^ {
			a = transmute(cstring)(find_name_end(a, nil, nil, 3))
			if !ascii_iswhite(([^]u8)(a)[0]) && ends_excmd(C.int(([^]u8)(a)[0])) == 0 {
				emsg_severe_g = true
				semsg(cstring(E488_S), a)
				break
			}
		} else {
			name_start := a
			name := a
			tofree: cstring = nil
			length := get_name_len(&a, &tofree, true, true)
			if length <= 0 {
				if length < 0 && !aborting_r() {
					emsg_severe_g = true
					semsg(e_invarg2, a)
					break
				}
				error = true
			} else {
				if tofree != nil {
					name = tofree
				}
				tv := Typval_T{}
				if eval_variable(name, length, &tv, nil, true, false) == FAIL_E {
					error = true
				} else {
					arg_subsc := a
					ea := Evalarg_T{eval_flags = 1}
					if handle_subscript(&a, &tv, rawptr(&ea), true) == FAIL_E {
						error = true
					} else {
						if a == arg_subsc && length == 2 && ([^]u8)(name)[1] == ':' {
							if ([^]u8)(name)[0] == 'g' {
								list_glob_vars_o(first)
							} else if ([^]u8)(name)[0] == 'b' {
								list_buf_vars_o(first)
							} else if ([^]u8)(name)[0] == 'w' {
								list_win_vars_o(first)
							} else if ([^]u8)(name)[0] == 't' {
								list_tab_vars_o(first)
							} else if ([^]u8)(name)[0] == 'v' {
								list_vim_vars_o(first)
							} else if ([^]u8)(name)[0] == 's' {
								list_script_vars_o(first)
							} else if ([^]u8)(name)[0] == 'l' {
								list_func_vars(first)
							} else {
								semsg(cstring(E738_S), name)
							}
						} else {
							s := encode_tv2echo(&tv, nil)
							used_name := name
							if a != arg_subsc {
								used_name = name_start
							}
							name_size := C.ptrdiff_t(uintptr(transmute(rawptr)(a)) - uintptr(transmute(rawptr)(used_name)))
							if used_name == tofree {
								name_size = C.ptrdiff_t(libc.strlen(used_name))
							}
							disp := cstring("")
							if s != nil {
								disp = transmute(cstring)(s)
							}
							list_one_var_a_o(cstring(""), used_name, name_size, tv.v_type, disp, first)
							xfree(rawptr(s))
						}
					}
					tv_clear(&tv)
				}
			}
			xfree(rawptr(tofree))
		}
		a = skipwhite(a)
	}
	return a
}

// Assign one :let target (static in C).
ex_let_one_o :: proc "c" (arg: cstring, tv: ^Typval_T, copy: bool, is_const: bool, endchars: cstring, op: cstring) -> cstring {
	context = runtime.default_context()
	arg_end: cstring = nil
	if ([^]u8)(arg)[0] == '$' {
		return ex_let_env_o(arg, tv, is_const, endchars, op)
	} else if ([^]u8)(arg)[0] == '&' {
		return ex_let_option_o(arg, tv, is_const, endchars, op)
	} else if ([^]u8)(arg)[0] == '@' {
		return ex_let_register_o(arg, tv, is_const, endchars, op)
	} else if eval_isnamec1(C.int(([^]u8)(arg)[0])) || ([^]u8)(arg)[0] == '{' {
		lv: [96]u8
		p := get_lval(arg, rawptr(tv), rawptr(&lv[0]), false, false, 0, FNE_CHECK_START_O)
		if p != nil && (^rawptr)(uintptr(&lv[0]) + LL_NAME_OFF_O)^ != nil {
			if endchars != nil && vim_strchr_c(transmute(^u8)(endchars), C.int(([^]u8)(skipwhite(p))[0])) == nil {
				emsg(cstring(E18_S))
			} else {
				set_var_lval(rawptr(&lv[0]), p, tv, copy, is_const, op)
				arg_end = p
			}
		}
		clear_lval(rawptr(&lv[0]))
	} else {
		semsg(e_invarg2, arg)
	}
	return arg_end
}

// Assign ":let [v1, v2] = list" targets.
@(export)
ex_let_vars :: proc "c" (arg_start: cstring, tv: ^Typval_T, copy: C.int, semicolon: C.int, var_count: C.int, is_const: bool, op: cstring) -> C.int {
	context = runtime.default_context()
	arg := arg_start
	if ([^]u8)(arg)[0] != '[' {
		if ex_let_one_o(arg, tv, copy != 0, is_const, op, op) == nil {
			return FAIL_E
		}
		return OK_E
	}
	if tv.v_type != VAR_LIST {
		emsg(cstring(E_LISTREQ_S))
		return FAIL_E
	}
	l := rawptr(tv.vval)
	length := (^C.int)(uintptr(l) + 60)^
	if semicolon == 0 && var_count < length {
		emsg(cstring(E687_S))
		return FAIL_E
	}
	if var_count - semicolon > length {
		emsg(cstring(E688_S))
		return FAIL_E
	}
	if l == nil {
		libc.abort()
	}
	item := (^rawptr)(uintptr(l) + 0)^
	rest_len := C.size_t(length)
	for ([^]u8)(arg)[0] != ']' {
		arg = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 1)))
		arg = ex_let_one_o(arg, (^Typval_T)(uintptr(item) + 16), true, is_const, cstring(",;]"), op)
		if arg == nil {
			return FAIL_E
		}
		rest_len -= 1
		item = (^rawptr)(uintptr(item) + 0)^
		arg = skipwhite(arg)
		if ([^]u8)(arg)[0] == ';' {
			rest_list := tv_list_alloc(C.ssize_t(rest_len))
			for item != nil {
				tv_list_append_tv(rest_list, (^Typval_T)(uintptr(item) + 16))
				item = (^rawptr)(uintptr(item) + 0)^
			}
			ltv := Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(rest_list)}
			tv_list_ref_o(rest_list)
			arg = ex_let_one_o(skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 1))), &ltv, false, is_const, cstring("]"), op)
			tv_clear(&ltv)
			if arg == nil {
				return FAIL_E
			}
			break
		} else if ([^]u8)(arg)[0] != ',' && ([^]u8)(arg)[0] != ']' {
			iemsg_r(cstring("ex_let_vars()"))
			return FAIL_E
		}
	}
	return OK_E
}

// ":let {const} ... = expr" command.
@(export)
ex_let :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	is_const := (^C.int)(uintptr(eap) + 64)^ == CMD_CONST_O
	arg := (^cstring)(uintptr(eap) + 0)^
	expr: cstring = nil
	rettv := Typval_T{}
	var_count: C.int = 0
	semicolon: C.int = 0
	op: [2]u8
	argend := skip_var_list(arg, &var_count, &semicolon, false)
	if argend == nil {
		return
	}
	expr = skipwhite(argend)
	concat := libc.strncmp(expr, cstring("..="), 3) == 0
	op0 := ([^]u8)(expr)[0]
	in_opset := op0 == '+' || op0 == '-' || op0 == '*' || op0 == '/' || op0 == '%' || op0 == '.'
	has_assign := op0 == '=' || (in_opset && ([^]u8)(expr)[1] == '=')
	if !has_assign && !concat {
		first_list := C.int(1)
		if ([^]u8)(arg)[0] == '[' {
			emsg(e_invarg_s)
		} else if ends_excmd(C.int(([^]u8)(arg)[0])) == 0 {
			arg = transmute(cstring)(list_arg_vars_o(eap, arg, &first_list))
		} else if !(^bool)(uintptr(eap) + 72)^ {
			first := C.int(1)
			list_glob_vars_o(&first)
			list_buf_vars_o(&first)
			list_win_vars_o(&first)
			list_tab_vars_o(&first)
			list_script_vars_o(&first)
			list_func_vars(&first)
			list_vim_vars_o(&first)
		}
		(^rawptr)(uintptr(eap) + 32)^ = transmute(rawptr)(check_nextcmd(transmute(^u8)(arg)))
		return
	}
	if ([^]u8)(expr)[0] == '=' && ([^]u8)(expr)[1] == '<' && ([^]u8)(expr)[2] == '<' {
		l := heredoc_get(eap, transmute(cstring)(rawptr(uintptr(transmute(rawptr)(expr)) + 3)), false)
		if l != nil {
			tv_list_set_ret_o(&rettv, l)
			if !(^bool)(uintptr(eap) + 72)^ {
				op[0] = '='
				op[1] = 0
				ex_let_vars((^cstring)(uintptr(eap) + 0)^, &rettv, 0, semicolon, var_count, is_const, transmute(cstring)(&op[0]))
			}
			tv_clear(&rettv)
		}
		return
	}
	rettv.v_type = VAR_UNKNOWN
	op[0] = '='
	op[1] = 0
	if ([^]u8)(expr)[0] != '=' {
		op[0] = ([^]u8)(expr)[0]
		if ([^]u8)(expr)[0] == '.' && ([^]u8)(expr)[1] == '.' {
			expr = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(expr)) + 1))
		}
		expr = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(expr)) + 2))
	} else {
		expr = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(expr)) + 1))
	}
	expr = skipwhite(expr)
	skip := (^bool)(uintptr(eap) + 72)^
	if skip {
		emsg_skip += 1
	}
	ea := Evalarg_T{}
	fill_evalarg_from_eap(&ea, eap, skip)
	eval_res := eval0(expr, &rettv, eap, rawptr(&ea))
	if skip {
		emsg_skip -= 1
	}
	clear_evalarg(&ea, eap)
	if !skip && eval_res != FAIL_E {
		ex_let_vars((^cstring)(uintptr(eap) + 0)^, &rettv, 0, semicolon, var_count, is_const, transmute(cstring)(&op[0]))
	}
	if eval_res != FAIL_E {
		tv_clear(&rettv)
	}
}

// —— Batch 26f: vars.c unlet/lockvar commands (FFI fully rewired) ——
LL_LI_OFF_O :: 32
LL_LIST_OFF_O :: 40
LL_EMPTY2_OFF_O :: 49
LL_N1_OFF_O :: 52
LL_N2_OFF_O :: 56
LL_BLOB_OFF_O :: 88
GLV_NO_AUTOLOAD_O :: 4
CMD_LOCKVAR_O :: 256
E940_S :: "E940: Cannot lock or unlock variable %s"

// Unlet one list range (static in C).
tv_list_unlet_range_o :: proc "c" (l: rawptr, li_first: rawptr, n1_arg: C.int, has_n2: bool, n2: C.int) {
	context = runtime.default_context()
	li_last := li_first
	n1 := n1_arg
	for {
		li := (^rawptr)(uintptr(li_last) + 0)^
		n1 += 1
		if li == nil || (has_n2 && n2 < n1) {
			break
		}
		li_last = li
	}
	tv_list_remove_items(l, li_first, li_last)
}

// Unlet the variable in an lval (static in C).
do_unlet_var_o :: proc "c" (lp: rawptr, name_end: cstring, eap: rawptr, deep: C.int) -> C.int {
	context = runtime.default_context()
	forceit := (^bool)(uintptr(eap) + 76)^
	ret: C.int = OK_E
	if (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ == nil {
		cc := ([^]u8)(name_end)[0]
		([^]u8)(name_end)[0] = 0
		if ([^]u8)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^)[0] == '$' {
			vim_unsetenv_ext(transmute(cstring)(rawptr(uintptr(transmute(rawptr)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^)) + 1)))
		} else if do_unlet(transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^), (^C.size_t)(uintptr(lp) + LL_NAME_LEN_OFF_O)^, forceit) == FAIL_E {
			ret = FAIL_E
		}
		([^]u8)(name_end)[0] = cc
	} else if ((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^ != nil && value_check_lock(tv_list_locked_o((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^), transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^), (^C.size_t)(uintptr(lp) + LL_NAME_LEN_OFF_O)^)) || ((^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^ != nil && value_check_lock((^C.int)(uintptr((^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^) + 0)^, transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^), (^C.size_t)(uintptr(lp) + LL_NAME_LEN_OFF_O)^)) {
		return FAIL_E
	} else if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ {
		tv_list_unlet_range_o((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^, (^rawptr)(uintptr(lp) + LL_LI_OFF_O)^, (^C.int)(uintptr(lp) + LL_N1_OFF_O)^, (^bool)(uintptr(lp) + LL_EMPTY2_OFF_O)^ == false, (^C.int)(uintptr(lp) + LL_N2_OFF_O)^)
	} else if (^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^ != nil {
		tv_list_item_remove((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^, (^rawptr)(uintptr(lp) + LL_LI_OFF_O)^)
	} else {
		d := (^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^
		if d == nil {
			libc.abort()
		}
		di := (^rawptr)(uintptr(lp) + LL_DI_OFF_O)^
		watched := tv_dict_is_watched_o(d)
		key: cstring = nil
		oldtv := Typval_T{}
		if watched {
			tv_copy((^Typval_T)(di), &oldtv)
			key = transmute(cstring)(xstrdup_o(transmute(^u8)(rawptr(uintptr(di) + 17))))
		}
		tv_dict_item_remove(d, di)
		if watched {
			tv_dict_watcher_notify(d, key, nil, &oldtv)
			tv_clear(&oldtv)
			xfree(rawptr(key))
		}
	}
	return ret
}

// (Un)lock the variable in an lval (static in C).
do_lock_var_o :: proc "c" (lp: rawptr, name_end: cstring, eap: rawptr, deep: C.int) -> C.int {
	context = runtime.default_context()
	lock := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_LOCKVAR_O
	ret: C.int = OK_E
	if (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ == nil {
		if ([^]u8)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^)[0] == '$' {
			semsg(cstring(E940_S), transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^))
			ret = FAIL_E
		} else {
			di := find_var(transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^), (^C.size_t)(uintptr(lp) + LL_NAME_LEN_OFF_O)^, nil, 1)
			if di == nil {
				ret = FAIL_E
			} else if (((^u8)(uintptr(di) + 16)^ & DI_FLAGS_FIX_O) != 0) && (^C.int)(uintptr(di))^ != VAR_DICT && (^C.int)(uintptr(di))^ != VAR_LIST {
				semsg(cstring(E940_S), transmute(cstring)((^rawptr)(uintptr(lp) + LL_NAME_OFF_O)^))
				ret = FAIL_E
			} else {
				if lock {
					([^]u8)(uintptr(di) + 16)[0] |= DI_FLAGS_LOCK_O
				} else {
					([^]u8)(uintptr(di) + 16)[0] &= ~u8(8)
				}
				if deep != 0 {
					tv_item_lock((^Typval_T)(di), deep, lock, false)
				}
			}
		}
	} else if deep == 0 {
	} else if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ {
		li := (^rawptr)(uintptr(lp) + LL_LI_OFF_O)^
		for li != nil && ((^bool)(uintptr(lp) + LL_EMPTY2_OFF_O)^ || (^C.int)(uintptr(lp) + LL_N2_OFF_O)^ >= (^C.int)(uintptr(lp) + LL_N1_OFF_O)^) {
			tv_item_lock((^Typval_T)(uintptr(li) + 16), deep, lock, false)
			li = (^rawptr)(uintptr(li) + 0)^
			(^C.int)(uintptr(lp) + LL_N1_OFF_O)^ += 1
		}
	} else if (^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^ != nil {
		tv_item_lock((^Typval_T)(uintptr((^rawptr)(uintptr(lp) + LL_LI_OFF_O)^) + 16), deep, lock, false)
	} else {
		tv_item_lock((^Typval_T)((^rawptr)(uintptr(lp) + LL_DI_OFF_O)^), deep, lock, false)
	}
	return ret
}

// Shared :unlet/:lockvar/:unlockvar parsing (static in C).
ex_unletlock_o :: proc "c" (eap: rawptr, argstart: cstring, deep: C.int, glv_flags: C.int, callback_is_unlet: bool) {
	context = runtime.default_context()
	arg := argstart
	name_end: cstring = nil
	error := false
	lv: [96]u8
	for {
		if ([^]u8)(arg)[0] == '$' {
			([^]rawptr)(uintptr(&lv[0]) + LL_NAME_OFF_O)[0] = rawptr(arg)
			([^]rawptr)(uintptr(&lv[0]) + LL_TV_OFF_O)[0] = nil
			arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 1))
			if get_env_len(&arg) == 0 {
				semsg(e_invarg2, transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) - 1)))
				return
			}
			if !error && !(^bool)(uintptr(eap) + 72)^ {
				failed := false
				if callback_is_unlet {
					failed = do_unlet_var_o(rawptr(&lv[0]), arg, eap, deep) == FAIL_E
				} else {
					failed = do_lock_var_o(rawptr(&lv[0]), arg, eap, deep) == FAIL_E
				}
				if failed {
					error = true
				}
			}
			name_end = arg
		} else {
			name_end = get_lval(arg, nil, rawptr(&lv[0]), true, (^bool)(uintptr(eap) + 72)^ || error, glv_flags, FNE_CHECK_START_O)
			if (^rawptr)(uintptr(&lv[0]) + LL_NAME_OFF_O)^ == nil {
				error = true
			}
			if name_end == nil || (!ascii_iswhite(([^]u8)(name_end)[0]) && ends_excmd(C.int(([^]u8)(name_end)[0])) == 0) {
				if name_end != nil {
					emsg_severe_g = true
					semsg(cstring(E488_S), name_end)
				}
				if !((^bool)(uintptr(eap) + 72)^ || error) {
					clear_lval(rawptr(&lv[0]))
				}
				break
			}
			if !error && !(^bool)(uintptr(eap) + 72)^ {
				failed := false
				if callback_is_unlet {
					failed = do_unlet_var_o(rawptr(&lv[0]), name_end, eap, deep) == FAIL_E
				} else {
					failed = do_lock_var_o(rawptr(&lv[0]), name_end, eap, deep) == FAIL_E
				}
				if failed {
					error = true
				}
			}
			if !(^bool)(uintptr(eap) + 72)^ {
				clear_lval(rawptr(&lv[0]))
			}
		}
		arg = skipwhite(name_end)
		if ends_excmd(C.int(([^]u8)(arg)[0])) != 0 {
			break
		}
	}
	(^rawptr)(uintptr(eap) + 32)^ = transmute(rawptr)(check_nextcmd(transmute(^u8)(arg)))
}

// ":unlet[!] var ..." command.
@(export)
ex_unlet :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	force_glv: C.int = 0
	if (^bool)(uintptr(eap) + 76)^ {
		force_glv = TFN_QUIET_O
	}
	ex_unletlock_o(eap, (^cstring)(uintptr(eap) + 0)^, 0, force_glv, true)
}

// ":lockvar"/":unlockvar" commands.
@(export)
ex_lockvar :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + 0)^
	deep: C.int = 2
	if (^bool)(uintptr(eap) + 76)^ {
		deep = -1
	} else if ascii_isdigit_o(([^]u8)(arg)[0]) {
		pp := transmute(^u8)(arg)
		deep = getdigits_int(&pp, false, -1)
		arg = transmute(cstring)(pp)
		arg = skipwhite(arg)
	}
	ex_unletlock_o(eap, arg, deep, 0, false)
}

// —— Batch 26e: vars.c set/unlet core ——

E108_S :: "E108: No such variable: \"%s\""
E995_S :: "E995: Cannot modify existing variable"
E963_S :: "E963: Setting v:%s to value with wrong type"

// Delete a variable by name.
@(export)
do_unlet :: proc "c" (name: cstring, name_len: C.size_t, forceit: bool) -> C.int {
	context = runtime.default_context()
	varname: cstring = nil
	dict: rawptr = nil
	ht := find_var_ht_dict_o(name, name_len, &varname, &dict)
	if ht != nil && ([^]u8)(varname)[0] != 0 {
		d := get_current_funccal_dict(ht)
		if d == nil {
			if ht == 	get_globvar_ht() {
				d = 	get_globvar_dict()
			} else if ht == compat_hashtab_e() {
				d = get_vimvar_dict()
			} else {
				di := find_var_in_ht(ht, C.int(([^]u8)(name)[0]), cstring(""), 0, 0)
				d = rawptr((^rawptr)(uintptr(rawptr(di)) + 8)^)
			}
			if d == nil {
				iemsg_r(cstring("do_unlet()"))
				return FAIL_E
			}
		}
		hi := hash_find(ht, varname)
		if hi != nil {
			hi_key := (^rawptr)(uintptr(hi) + 8)^
			if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
				hi = nil
			}
		}
		if hi == nil {
			hi = find_hi_in_scoped_ht(name, &ht)
		}
		if hi != nil {
			hk := (^rawptr)(uintptr(hi) + 8)^
			if hk != nil && hk != transmute(rawptr)(&hash_removed) {
				di := rawptr(uintptr(hk) - 17)
				if var_check_fixed((^C.int)(uintptr(di) + 16)^, name, max(C.size_t) - 1) || var_check_ro((^C.int)(uintptr(di) + 16)^, name, max(C.size_t) - 1) || value_check_lock((^C.int)(uintptr(d) + 0)^, name, max(C.size_t) - 1) {
					return FAIL_E
				}
				if value_check_lock((^C.int)(uintptr(d) + 0)^, name, max(C.size_t) - 1) {
					return FAIL_E
				}
				oldtv := Typval_T{}
				watched := tv_dict_is_watched_o(dict)
				if watched {
					tv_copy((^Typval_T)(di), &oldtv)
				}
				delete_var_o(ht, hi)
				if watched {
					tv_dict_watcher_notify(dict, varname, nil, &oldtv)
					tv_clear(&oldtv)
				}
				return OK_E
			}
		}
	}
	if forceit {
		return OK_E
	}
	semsg(cstring(E108_S), name)
	return FAIL_E
}

// Assign a variable (copying).
@(export)
set_var :: proc "c" (name: cstring, name_len: C.size_t, tv: ^Typval_T, copy: bool) {
	context = runtime.default_context()
	set_var_const(name, name_len, tv, copy, false)
}

// Assign a variable, optionally locking it as a constant.
@(export)
set_var_const :: proc "c" (name: cstring, name_len: C.size_t, tv: ^Typval_T, copy: bool, is_const: bool) {
	context = runtime.default_context()
	varname: cstring = nil
	dict: rawptr = nil
	ht := find_var_ht_dict_o(name, name_len, &varname, &dict)
	watched := tv_dict_is_watched_o(dict)
	if ht == nil || ([^]u8)(varname)[0] == 0 {
		semsg(cstring(E461_S), name)
		return
	}
	varname_len := name_len - C.size_t(uintptr(transmute(rawptr)(varname)) - uintptr(transmute(rawptr)(name)))
	di := find_var_in_ht(ht, 0, varname, varname_len, 1)
	if di == nil {
		di = find_var_in_scoped_ht(name, name_len, 1)
	}
	if (tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL) && var_wrong_func_name(name, di == nil) {
		return
	}
	oldtv := Typval_T{}
	if di != nil {
		if is_const {
			emsg(cstring(E995_S))
			return
		}
		if var_check_ro((^C.int)(uintptr(di) + 16)^, name, name_len) || value_check_lock((^C.int)(uintptr(di) + 4)^, name, name_len) || var_check_lock((^C.int)(uintptr(di) + 16)^, name, name_len) {
			return
		}
		type_error := false
		vim_ht := rawptr(uintptr(get_vimvar_dict()) + 16)
		if ht == vim_ht && !before_set_vvar(varname, di, tv, copy, watched, &type_error) {
			if type_error {
				semsg(cstring(E963_S), varname)
			}
			return
		}
		if watched {
			tv_copy((^Typval_T)(di), &oldtv)
		}
		tv_clear((^Typval_T)(di))
	} else {
		vim_ht2 := rawptr(uintptr(get_vimvar_dict()) + 16)
		args_ht := get_funccal_args_ht()
		if ht == vim_ht2 || ht == args_ht {
			semsg(cstring(E461_S), name)
			return
		}
		if !valid_varname(varname) {
			return
		}
		if dict == nil {
			libc.abort()
		}
		di = rawptr(xmalloc(17 + varname_len + 1))
		libc.memcpy(rawptr(uintptr(di) + 17), transmute(rawptr)(varname), varname_len + 1)
		if hash_add(ht, transmute(^u8)(rawptr(uintptr(di) + 17))) == FAIL_E {
			xfree(di)
			return
		}
		(^u8)(uintptr(di) + 16)^ = DI_FLAGS_ALLOC_O
		if is_const {
			([^]u8)(uintptr(di) + 16)[0] |= DI_FLAGS_LOCK_O
		}
	}
	if copy || tv.v_type == VAR_NUMBER || tv.v_type == VAR_FLOAT {
		tv_copy(tv, (^Typval_T)(di))
	} else {
		(^Typval_T)(di)^ = tv^
		(^C.int)(uintptr(di) + 4)^ = VAR_UNLOCKED
		tv_init_o(tv)
	}
	if watched {
		tv_dict_watcher_notify(dict, ([^]cstring)(rawptr(uintptr(di) + 17))[0], (^Typval_T)(di), &oldtv)
		tv_clear(&oldtv)
	}
	if is_const {
		tv_item_lock((^Typval_T)(di), 100, true, true)
	}
}

// Zero a typval shell (tv_init inline).
tv_init_o :: proc "c" (tv: ^Typval_T) {
	context = runtime.default_context()
	if tv != nil {
		libc.memset(tv, 0, 16)
	}
}

// —— Batch 26d: vars.c vimvar accessors ——
foreign _ {
	@(link_name = "nvim_odin_vimvardict")
	vimvardict_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_vimvar_tv")
	vimvar_tv_e :: proc "c" (idx: C.int) -> ^Typval_T ---
}

// Struct-returning getters read through the single-tv shim (C retains table).
// Get v: typval (all other getters derive from it).
@(export)
get_vim_var_tv :: proc "c" (idx: C.int) -> ^Typval_T {
	context = runtime.default_context()
	return vimvar_tv_e(idx)
}

// Get v: number.
@(export)
get_vim_var_nr :: proc "c" (idx: C.int) -> i64 {
	context = runtime.default_context()
	return i64(transmute(C.longlong)(vimvar_tv_e(idx).vval))
}

// Get v: list (borrowed).
@(export)
get_vim_var_list :: proc "c" (idx: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(vimvar_tv_e(idx).vval)
}

// Get v: dict (borrowed).
@(export)
get_vim_var_dict :: proc "c" (idx: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(vimvar_tv_e(idx).vval)
}

// Get v: string (static buffer semantics live in tv_get_string).
@(export)
get_vim_var_str :: proc "c" (idx: C.int) -> cstring {
	context = runtime.default_context()
	return tv_get_string(vimvar_tv_e(idx))
}

// Get v: partial (borrowed).
@(export)
get_vim_var_partial :: proc "c" (idx: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(vimvar_tv_e(idx).vval)
}

// Get v: variable name (di_key doubling as the table name).
@(export)
get_vim_var_name :: proc "c" (idx: C.int) -> cstring {
	context = runtime.default_context()
	return transmute(cstring)(rawptr(uintptr(transmute(rawptr)(vimvar_tv_e(idx))) + 17))
}

// Get the v: scope dict itself.
@(export)
get_vimvar_dict :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return vimvardict_e()
}

// Set v: number (type untouched, use set_vim_var_type for that).
@(export)
set_vim_var_nr :: proc "c" (idx: C.int, val: i64) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.vval = transmute(rawptr)(C.longlong(val))
}

// Set v: boolean.
@(export)
set_vim_var_bool :: proc "c" (idx: C.int, val: C.int) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.v_type = VAR_BOOL
	(^C.int)(&tv.vval)^ = val
}

// Set v: special.
@(export)
set_vim_var_special :: proc "c" (idx: C.int, val: C.int) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.v_type = VAR_SPECIAL
	(^C.int)(&tv.vval)^ = val
}

// Set v:char from a character.
@(export)
set_vim_var_char :: proc "c" (c: C.int) {
	context = runtime.default_context()
	buf: [MB_MAXCHAR + 1]u8
	buflen := utf_char2bytes(c, &buf[0])
	buf[buflen] = 0
	set_vim_var_string(VV_CHAR_O, transmute(cstring)(&buf[0]), C.ptrdiff_t(buflen))
}

// Set v: string (copied; NULL clears).
@(export)
set_vim_var_string :: proc "c" (idx: C.int, val: cstring, length: C.ptrdiff_t) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.v_type = VAR_STRING
	if val == nil {
		tv.vval = nil
	} else if length == -1 {
		tv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(val)))
	} else {
		tv.vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(val), C.size_t(length)))
	}
}

// Set v: list (refcounted).
@(export)
set_vim_var_list :: proc "c" (idx: C.int, val: rawptr) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.v_type = VAR_LIST
	tv.vval = transmute(rawptr)(val)
	if val != nil {
		tv_list_ref_o(val)
	}
}

// Set v: dict (refcounted + readonly keys).
@(export)
set_vim_var_dict :: proc "c" (idx: C.int, val: rawptr) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv_clear(tv)
	tv.v_type = VAR_DICT
	tv.vval = transmute(rawptr)(val)
	if val == nil {
		return
	}
	(^C.int)(uintptr(val) + 8)^ += 1
	tv_dict_set_keys_readonly(val)
}

// Set v: partial (type untouched).
@(export)
set_vim_var_partial :: proc "c" (idx: C.int, val: rawptr) {
	context = runtime.default_context()
	tv := vimvar_tv_e(idx)
	tv.vval = transmute(rawptr)(val)
}

// Copy a typval into a v: variable.
@(export)
set_vim_var_tv :: proc "c" (idx: C.int, tv: ^Typval_T) {
	context = runtime.default_context()
	out := vimvar_tv_e(idx)
	tv_clear(out)
	tv_copy(tv, out)
}

// Set a v: variable's type tag.
@(export)
set_vim_var_type :: proc "c" (idx: C.int, type: C.int) {
	context = runtime.default_context()
	vimvar_tv_e(idx).v_type = type
}

// —— Batch 26b: vars.c scope resolution ——
foreign _ {
	@(link_name = "nvim_odin_compat_hashtab")
	compat_hashtab_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_globvars_var")
	globvars_var_e :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_vimvars_var")
	vimvars_var_e :: proc "c" () -> rawptr ---
	@(link_name = "new_script_item")
	new_script_item_e :: proc "c" (name: cstring, sid_out: ^C.int) -> rawptr ---
}

SID_LUA_O :: -8
SID_STR_O :: -10
VV_CHAR_O :: 23

// Scope-dict lookup for a variable name (static in C).
find_var_ht_dict_o :: proc "c" (name: cstring, name_len: C.size_t, varname: ^cstring, d: ^rawptr) -> rawptr {
	context = runtime.default_context()
	d^ = nil
	if name_len == 0 {
		return nil
	}
	nb := ([^]u8)(name)
	if name_len == 1 || nb[1] != ':' {
		if nb[0] == ':' || nb[0] == '#' {
			return nil
		}
		varname^ = name
		hi := hash_find_len(compat_hashtab_e(), name, name_len)
		if hi != nil {
			hi_key := (^rawptr)(uintptr(hi) + 8)^
			if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed) {
				return compat_hashtab_e()
			}
		}
		d^ = get_funccal_local_dict()
		if d^ == nil {
			d^ = 	get_globvar_dict()
		}
		return rawptr(uintptr(d^) + 16)
	}
	varname^ = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(name)) + 2))
	if nb[0] == 'g' {
		d^ = 	get_globvar_dict()
	} else if name_len > 2 {
		bad := false
		i := uintptr(2)
		for i < uintptr(name_len) {
			c := ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(name)) + i))[0]
			if c == ':' || c == '#' {
				bad = true
				break
			}
			i += 1
		}
		if bad {
			return nil
		}
	}
	if nb[0] == 'b' {
		d^ = (^rawptr)(uintptr(curbuf) + B_VARS_OFF)^
	} else if nb[0] == 'w' {
		d^ = (^rawptr)(uintptr(curwin) + W_VARS_OFF)^
	} else if nb[0] == 't' {
		d^ = (^rawptr)(uintptr(curtab) + TP_VARS_OFF)^
	} else if nb[0] == 'v' {
		d^ = get_vimvar_dict()
	} else if nb[0] == 'a' {
		d^ = get_funccal_args_dict()
	} else if nb[0] == 'l' {
		d^ = get_funccal_local_dict()
	} else if nb[0] == 's' {
		sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
		if (sid > 0 || sid == SID_STR_O || sid == SID_LUA_O) && sid <= script_items_g.ga_len {
			nlua_set_sctx_r(rawptr(&current_sctx_buf[0]))
			sid = (^C.int)(uintptr(&current_sctx_buf[0]))^
			if sid == SID_STR_O || sid == SID_LUA_O {
				new_script_item_e(nil, (^C.int)(uintptr(&current_sctx_buf[0])))
				sid = (^C.int)(uintptr(&current_sctx_buf[0]))^
			}
			item := ([^]rawptr)(script_items_g.ga_data)[uintptr(int(sid) - 1)]
			d^ = rawptr(uintptr((^rawptr)(uintptr(item) + 0)^) + 24)
		}
	}
	if d^ == nil {
		return nil
	}
	return rawptr(uintptr(d^) + 16)
}

// Find a variable's hashtable by name.
@(export)
find_var_ht :: proc "c" (name: cstring, name_len: C.size_t, varname: ^cstring) -> rawptr {
	context = runtime.default_context()
	d: rawptr = nil
	return find_var_ht_dict_o(name, name_len, varname, &d)
}

// Find a variable in a hashtable (scope-dict fast path included).
@(export)
find_var_in_ht :: proc "c" (ht: rawptr, htname: C.int, varname: cstring, varname_len: C.size_t, no_autoload: C.int) -> rawptr {
	context = runtime.default_context()
	if varname_len == 0 {
		if htname == 's' {
			sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
			item := ([^]rawptr)(script_items_g.ga_data)[uintptr(int(sid) - 1)]
			return rawptr(uintptr((^rawptr)(uintptr(item) + 0)^) + 0)
		} else if htname == 'g' {
			return globvars_var_e()
		} else if htname == 'v' {
			return vimvars_var_e()
		} else if htname == 'b' {
			return rawptr(uintptr(curbuf) + B_BUFVAR_OFF)
		} else if htname == 'w' {
			return rawptr(uintptr(curwin) + W_WINVAR_OFF)
		} else if htname == 't' {
			return rawptr(uintptr(curtab) + TP_WINVAR_OFF)
		} else if htname == 'l' {
			return get_funccal_local_var()
		} else if htname == 'a' {
			return get_funccal_args_var()
		}
		return nil
	}
	hi := hash_find_len(ht, varname, varname_len)
	if hi != nil {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
			hi = nil
		}
	}
	if hi == nil {
		if ht == 	get_globvar_ht() && no_autoload == 0 {
			if !script_autoload_e(varname, varname_len, false) || aborting_r() {
				return nil
			}
			hi = hash_find_len(ht, varname, varname_len)
		}
		if hi != nil {
			hi_key := (^rawptr)(uintptr(hi) + 8)^
			if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
				return nil
			}
		} else {
			return nil
		}
	}
	return rawptr(uintptr((^rawptr)(uintptr(hi) + 8)^) - 17)
}

// Find a variable by name across scopes (with closure fallback).
@(export)
find_var :: proc "c" (name: cstring, name_len: C.size_t, htp: rawptr, no_autoload: C.int) -> rawptr {
	context = runtime.default_context()
	varname: cstring = nil
	ht := find_var_ht(name, name_len, &varname)
	if htp != nil {
		(^rawptr)(htp)^ = ht
	}
	if ht == nil {
		return nil
	}
	na: C.int = 0
	if no_autoload != 0 || htp != nil {
		na = 1
	}
	ret := find_var_in_ht(ht, C.int(([^]u8)(name)[0]), varname, name_len - C.size_t(uintptr(transmute(rawptr)(varname)) - uintptr(transmute(rawptr)(name))), na)
	if ret != nil {
		return ret
	}
	return find_var_in_scoped_ht(name, name_len, na)
}

// —— Batch 26a: vars.c validators ——
DI_FLAGS_RO_SBX_O :: 2
DI_FLAGS_LOCK_O :: 8
E46_S :: "E46: Cannot change read-only variable \"%.*s\""
E794_S :: "E794: Cannot set variable in the sandbox: \"%.*s\""
E1122_S :: "E1122: Variable is locked: %.*s"
E795_S :: "E795: Cannot delete variable %.*s"
E704_S :: "E704: Funcref variable name must start with a capital: %s"
E705_S :: "E705: Variable name conflicts with existing function: %s"
E461_S :: "E461: Illegal variable name: %s"

// True when a variable is read-only (error included).
@(export)
var_check_ro :: proc "c" (flags: C.int, name: cstring, name_len: C.size_t) -> bool {
	context = runtime.default_context()
	errmsg: cstring = nil
	if (flags & DI_FLAGS_RO_O) != 0 {
		errmsg = cstring(E46_S)
	} else if ((flags & DI_FLAGS_RO_SBX_O) != 0 && sandbox != 0) {
		errmsg = cstring(E794_S)
	}
	if errmsg == nil {
		return false
	}
	nm := name
	length := name_len
	if length == max(C.size_t) {
		length = C.size_t(libc.strlen(nm))
	} else if length == max(C.size_t) - 1 {
		length = C.size_t(libc.strlen(nm))
	}
	semsg(errmsg, C.int(length), nm)
	return true
}

// True when a variable is locked (error included).
@(export)
var_check_lock :: proc "c" (flags: C.int, name: cstring, name_len: C.size_t) -> bool {
	context = runtime.default_context()
	if (flags & DI_FLAGS_LOCK_O) == 0 {
		return false
	}
	nm := name
	length := name_len
	if length == max(C.size_t) {
		length = C.size_t(libc.strlen(nm))
	} else if length == max(C.size_t) - 1 {
		length = C.size_t(libc.strlen(nm))
	}
	semsg(cstring(E1122_S), C.int(length), nm)
	return true
}

// True when a variable is fixed (error included).
@(export)
var_check_fixed :: proc "c" (flags: C.int, name: cstring, name_len: C.size_t) -> bool {
	context = runtime.default_context()
	if (flags & DI_FLAGS_FIX_O) == 0 {
		return false
	}
	nm := name
	length := name_len
	if length == max(C.size_t) {
		length = C.size_t(libc.strlen(nm))
	} else if length == max(C.size_t) - 1 {
		length = C.size_t(libc.strlen(nm))
	}
	semsg(cstring(E795_S), C.int(length), nm)
	return true
}

// True when a name cannot hold a funcref (error included).
@(export)
var_wrong_func_name :: proc "c" (name: cstring, new_var: bool) -> bool {
	context = runtime.default_context()
	nb := ([^]u8)(name)
	allow_scope := (nb[0] == 'w' || nb[0] == 'b' || nb[0] == 's' || nb[0] == 't') && nb[1] == ':'
	first := nb[0]
	if nb[0] != 0 && nb[1] == ':' {
		first = ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(name)) + 2))[0]
	}
	upper := first >= 'A' && first <= 'Z'
	if !allow_scope && !upper && vim_strchr_c(transmute(^u8)(name), '#') == nil {
		semsg(cstring(E704_S), name)
		return true
	}
	if new_var && function_exists(name, false) {
		semsg(cstring(E705_S), name)
		return true
	}
	return false
}

// True when a variable name is legal (error included).
@(export)
valid_varname :: proc "c" (varname: cstring) -> bool {
	context = runtime.default_context()
	p := varname
	for ([^]u8)(p)[0] != 0 {
		c := ([^]u8)(p)[0]
		first := uintptr(transmute(rawptr)(p)) == uintptr(transmute(rawptr)(varname))
		if !eval_isnamec1(C.int(c)) && (first || !ascii_isdigit_o(c)) && c != '#' {
			semsg(cstring(E461_S), varname)
			return false
		}
		p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
	}
	return true
}

// —— Batch 26c: vars.c buf/win/tab var accessors ——
foreign _ {
	@(link_name = "find_option")
	find_option_e :: proc "c" (name: cstring) -> C.int ---
}

E521_S :: "E521: Number required: &%s = '%s'"
E928_S :: "E928: String required"
E355_S :: "E355: Unknown option: %s"

// Convert typval to OptVal for setbufvar-style option sets (static in C).
tv_to_optval_o :: proc "c" (tv: ^Typval_T, opt_idx: C.int, option: cstring, error: ^bool) -> OptVal {
	context = runtime.default_context()
	value := nil_optval()
	nbuf: [65]u8
	err := false
	is_tty := is_tty_option(option)
	has_bool := !is_tty && option_has_type(opt_idx, kOptValTypeBoolean)
	has_num := !is_tty && option_has_type(opt_idx, kOptValTypeNumber)
	has_str := is_tty || option_has_type(opt_idx, kOptValTypeString)
	if !is_tty && (((^C.uint32_t)(uintptr(get_option(opt_idx)) + 16))^ & C.uint32_t(kOptFlagFunc)) != 0 && (tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL) {
		strval := encode_tv2string(tv, nil)
		err = strval == nil
		if strval != nil {
			value = str_optval(transmute(^u8)(strval), C.size_t(libc.strlen(transmute(cstring)(strval))))
		} else {
			value = str_optval(nil, 0)
		}
	} else if has_bool || has_num {
		n: C.longlong = 0
		if has_num {
			n = tv_get_number_chk(tv, &err)
		} else {
			n = tv_get_bool_chk(tv, &err)
		}
		if !err && tv.v_type == VAR_STRING && n == 0 {
			s := transmute(cstring)(rawptr(tv.vval))
			idx := 0
			if s != nil {
				for ([^]u8)(s)[uintptr(idx)] == '0' {
					idx += 1
				}
			}
			if idx == 0 || (s != nil && ([^]u8)(s)[uintptr(idx)] != 0) {
				err = true
				disp := cstring("")
				if s != nil {
					disp = s
				}
				semsg(cstring(E521_S), option, disp)
			}
		}
		if has_num {
			value = num_optval(n)
		} else {
			tri: C.int = 0
			if n != 0 {
				tri = 1
			}
			value = bool_optval(tri)
		}
	} else if has_str {
		if tv.v_type != VAR_BOOL && tv.v_type != VAR_SPECIAL {
			strval := tv_get_string_buf_chk(tv, &nbuf[0])
			err = strval == nil
			if strval != nil {
				// CSTR_TO_OPTVAL copies (unlike CSTR_AS_OPTVAL).
				dup := xmemdupz_o2(transmute(^u8)(strval), C.size_t(libc.strlen(strval)))
				value = str_optval(dup, C.size_t(libc.strlen(strval)))
			}
		} else if !is_tty {
			err = true
			emsg(cstring(E928_S))
		}
	} else {
		libc.abort()
	}
	if error != nil {
		error^ = err
	}
	return value
}

// Convert OptVal back to typval.
@(export)
optval_as_tv :: proc "c" (value_in: OptVal, numbool: bool) -> Typval_T {
	context = runtime.default_context()
	value := value_in
	rettv := Typval_T{v_type = VAR_SPECIAL}
	if value.typ == kOptValTypeNil {
	} else if value.typ == kOptValTypeBoolean {
		if numbool {
			rettv.v_type = VAR_NUMBER
			rettv.vval = transmute(rawptr)(C.longlong((^C.int)(&value.data)^))
		} else if (^C.int)(&value.data)^ != -1 {
			rettv.v_type = VAR_BOOL
			if (^C.int)(&value.data)^ == 1 {
				rettv.vval = transmute(rawptr)(C.longlong(1))
			} else {
				rettv.vval = transmute(rawptr)(C.longlong(0))
			}
		}
	} else if value.typ == kOptValTypeNumber {
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)((^C.longlong)(&value.data)^)
	} else if value.typ == kOptValTypeString {
		rettv.v_type = VAR_STRING
		rettv.vval = transmute(rawptr)((^rawptr)(&value.data)^)
	}
	return rettv
}

// Set buffer/window option from typval (static in C).
set_option_from_tv_o :: proc "c" (varname: cstring, varp: ^Typval_T) {
	context = runtime.default_context()
	opt_idx := find_option_e(varname)
	if opt_idx == kOptInvalid_S {
		semsg(cstring(E355_S), varname)
		return
	}
	error := false
	value := tv_to_optval_o(varp, opt_idx, varname, &error)
	if !error {
		errmsg := set_option_value_handle_tty(varname, opt_idx, value, 2)
		if errmsg != nil {
			emsg(errmsg)
		}
	}
	optval_free(value)
}

// Shared getbufvar/getwinvar/gettabvar engine (static in C).
get_var_from_o :: proc "c" (varname: cstring, rettv: ^Typval_T, deftv: ^Typval_T, htname: C.int, tp: rawptr, win: rawptr, buf: rawptr) {
	context = runtime.default_context()
	done := false
	do_change := buf != nil && htname == 'b'
	emsg_off += 1
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	if varname != nil && tp != nil && win != nil && (htname != 'b' || buf != nil) {
		need_switch := !(tp == curtab && win == curwin) && !do_change
		sw := Switchwin_T{}
		sw_ok := true
		if need_switch {
			sw_ok = switch_win(&sw, win, tp, true) == OK_E
		}
		if sw_ok {
			if ([^]u8)(varname)[0] == '&' && htname != 't' {
				save_curbuf := curbuf
				if do_change {
					curbuf = buf
				}
				if ([^]u8)(varname)[1] == 0 {
					bufopt: C.int = 0
					if htname == 'b' {
						bufopt = 1
					}
					opts := get_winbuf_options(bufopt)
					if opts != nil {
						tv_dict_set_ret_o(rettv, opts)
						done = true
					}
				} else {
					vn := varname
					if eval_option(&vn, rettv, true) == OK_E {
						done = true
					}
				}
				curbuf = save_curbuf
			} else if ([^]u8)(varname)[0] == 0 {
				v: rawptr = nil
				if htname == 'b' {
					v = rawptr(uintptr(buf) + B_BUFVAR_OFF)
				} else if htname == 'w' {
					v = rawptr(uintptr(win) + W_WINVAR_OFF)
				} else {
					v = rawptr(uintptr(tp) + TP_WINVAR_OFF)
				}
				tv_copy((^Typval_T)(v), rettv)
				done = true
			} else {
				ht: rawptr = nil
				if htname == 'b' {
					ht = rawptr(uintptr((^rawptr)(uintptr(buf) + B_VARS_OFF)^) + 16)
				} else if htname == 'w' {
					ht = rawptr(uintptr((^rawptr)(uintptr(win) + W_VARS_OFF)^) + 16)
				} else {
					ht = rawptr(uintptr((^rawptr)(uintptr(tp) + TP_VARS_OFF)^) + 16)
				}
				v := find_var_in_ht(ht, htname, varname, C.size_t(libc.strlen(varname)), 0)
				if v != nil {
					tv_copy((^Typval_T)(v), rettv)
					done = true
				}
			}
		}
		if need_switch {
			restore_win(&sw, true)
		}
	}
	if !done && deftv.v_type != VAR_UNKNOWN {
		tv_copy(deftv, rettv)
	}
	emsg_off -= 1
}

// getwinvar/gettabwinvar dispatcher (static in C).
getwinvar_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, off: C.int) {
	context = runtime.default_context()
	tp: rawptr = nil
	if off == 1 {
		tp = find_tabpage(C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)))
	} else {
		tp = curtab
	}
	win := find_win_by_nr((^Typval_T)(uintptr(argvars) + uintptr(off) * 16), tp)
	varname := tv_get_string_chk((^Typval_T)(uintptr(argvars) + uintptr(off + 1) * 16))
	get_var_from_o(varname, rettv, (^Typval_T)(uintptr(argvars) + uintptr(off + 2) * 16), 'w', tp, win, nil)
}

// setwinvar/settabwinvar dispatcher (static in C).
setwinvar_o :: proc "c" (argvars: ^Typval_T, off: C.int) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	tp: rawptr = nil
	if off == 1 {
		tp = find_tabpage(C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)))
	} else {
		tp = curtab
	}
	win := find_win_by_nr((^Typval_T)(uintptr(argvars) + uintptr(off) * 16), tp)
	varname := tv_get_string_chk((^Typval_T)(uintptr(argvars) + uintptr(off + 1) * 16))
	varp := (^Typval_T)(uintptr(argvars) + uintptr(off + 2) * 16)
	if win == nil || varname == nil {
		return
	}
	need_switch := !(tp == curtab && win == curwin)
	sw := Switchwin_T{}
	sw_ok := true
	if need_switch {
		sw_ok = switch_win(&sw, win, tp, true) == OK_E
	}
	if sw_ok {
		if ([^]u8)(varname)[0] == '&' {
			set_option_from_tv_o(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(varname)) + 1)), varp)
		} else {
			varname_len := C.size_t(libc.strlen(varname))
			winvarname := transmute([^]u8)(xmalloc(varname_len + 3))
			winvarname[0] = 'w'
			winvarname[1] = ':'
			libc.memcpy(rawptr(&winvarname[2]), transmute(rawptr)(varname), varname_len + 1)
				set_var(transmute(cstring)(&winvarname[0]), varname_len + 2, varp, true)
			xfree(rawptr(&winvarname[0]))
		}
	}
	if need_switch {
		restore_win(&sw, true)
	}
}

// "gettabvar()" function.
@(export)
f_gettabvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	avs := ([^]Typval_T)(argvars)
	varname := tv_get_string_chk(&avs[1])
	tp := find_tabpage(C.int(tv_get_number_chk(&avs[0], nil)))
	win: rawptr = nil
	if tp != nil {
		first := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		if tp == curtab || first == nil {
			win = firstwin
		} else {
			win = first
		}
	}
	get_var_from_o(varname, rettv, &avs[2], 't', tp, win, nil)
}

// "gettabwinvar()" function.
@(export)
f_gettabwinvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getwinvar_o(argvars, rettv, 1)
}

// "getwinvar()" function.
@(export)
f_getwinvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getwinvar_o(argvars, rettv, 0)
}

// "getbufvar()" function.
@(export)
f_getbufvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	avs := ([^]Typval_T)(argvars)
	varname := tv_get_string_chk(&avs[1])
	buf := 	tv_get_buf_from_arg(&avs[0])
	get_var_from_o(varname, rettv, &avs[2], 'b', curtab, curwin, buf)
}

// "settabvar()" function.
@(export)
f_settabvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	avs := ([^]Typval_T)(argvars)
	tp := find_tabpage(C.int(tv_get_number_chk(&avs[0], nil)))
	varname := tv_get_string_chk(&avs[1])
	varp := &avs[2]
	if varname == nil || tp == nil {
		return
	}
	save_curtab := curtab
	save_lu := lastused_tabpage_g
	goto_tabpage_tp(tp, false, false)
	varname_len := C.size_t(libc.strlen(varname))
	tabvarname := transmute([^]u8)(xmalloc(varname_len + 3))
	tabvarname[0] = 't'
	tabvarname[1] = ':'
	libc.memcpy(rawptr(&tabvarname[2]), transmute(rawptr)(varname), varname_len + 1)
		set_var(transmute(cstring)(&tabvarname[0]), varname_len + 2, varp, true)
	xfree(rawptr(&tabvarname[0]))
	if valid_tabpage(save_curtab) {
		goto_tabpage_tp(save_curtab, false, false)
		if valid_tabpage(save_lu) {
			lastused_tabpage_g = save_lu
		}
	}
}

// "settabwinvar()" function.
@(export)
f_settabwinvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	setwinvar_o(argvars, 1)
}

// "setwinvar()" function.
@(export)
f_setwinvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	setwinvar_o(argvars, 0)
}

// "setbufvar()" function.
@(export)
f_setbufvar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	avs := ([^]Typval_T)(argvars)
	if check_secure() || !tv_check_str_or_nr((^Typval_T)(uintptr(argvars))) {
		return
	}
	varname := tv_get_string_chk(&avs[1])
	buf := 	tv_get_buf(&avs[0], 0)
	varp := &avs[2]
	if buf == nil || varname == nil {
		return
	}
	if ([^]u8)(varname)[0] == '&' {
		aco: [56]u8
		aucmd_prepbuf_r(rawptr(&aco[0]), buf)
		set_option_from_tv_o(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(varname)) + 1)), varp)
		aucmd_restbuf_r(rawptr(&aco[0]))
	} else {
		varname_len := C.size_t(libc.strlen(varname))
		bufvarname := transmute([^]u8)(xmalloc(varname_len + 3))
		save_curbuf := curbuf
		curbuf = buf
		bufvarname[0] = 'b'
		bufvarname[1] = ':'
		libc.memcpy(rawptr(&bufvarname[2]), transmute(rawptr)(varname), varname_len + 1)
			set_var(transmute(cstring)(&bufvarname[0]), varname_len + 2, varp, true)
		xfree(rawptr(&bufvarname[0]))
		curbuf = save_curbuf
	}
}

// —— Batch 26g: :let sub-engines (dormant) ——
foreign _ {
	@(link_name = "get_tty_option")
	get_tty_option_e :: proc "c" (name: cstring) -> OptVal ---
}

E996_ENV_S :: "E996: Cannot lock an environment variable"
E996_OPT_S :: "E996: Cannot lock an option"
E996_REG_S :: "E996: Cannot lock a register"
E18_S :: "E18: Unexpected characters in :let"

// ":let $VAR = expr" (static in C).
ex_let_env_o :: proc "c" (arg: cstring, tv: ^Typval_T, is_const: bool, endchars: cstring, op: cstring) -> cstring {
	context = runtime.default_context()
	if is_const {
		emsg(cstring(E996_ENV_S))
		return nil
	}
	arg_end: cstring = nil
	arg1 := transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 1))
	name := arg1
	length := get_env_len(&arg1)
	if length == 0 {
		semsg(e_invarg2, transmute(cstring)(rawptr(uintptr(transmute(rawptr)(name)) - 1)))
	} else {
		opch := ([^]u8)(op)[0]
		is_arith := opch == '+' || opch == '-' || opch == '*' || opch == '/' || opch == '%'
		if op != nil && is_arith {
			semsg(cstring(E_LETWRONG_S), op)
		} else if endchars != nil && vim_strchr_c(transmute(^u8)(endchars), C.int(([^]u8)(skipwhite(arg1))[0])) == nil {
			emsg(cstring(E18_S))
		} else if !check_secure() {
			tofree: rawptr = nil
			c1 := ([^]u8)(rawptr(uintptr(transmute(rawptr)(name)) + uintptr(length)))[0]
			([^]u8)(rawptr(uintptr(transmute(rawptr)(name)) + uintptr(length)))[0] = 0
			p := tv_get_string_chk(tv)
			if p != nil && op != nil && ([^]u8)(op)[0] == '.' {
				s := vim_getenv(name)
				if s != nil {
					tofree = rawptr(concat_str_c(s, p))
					p = transmute(cstring)(tofree)
					xfree(rawptr(s))
				}
			}
			if p != nil {
				vim_setenv_ext(name, p)
				arg_end = arg1
			}
			([^]u8)(rawptr(uintptr(transmute(rawptr)(name)) + uintptr(length)))[0] = c1
			xfree(tofree)
		}
	}
	return arg_end
}

// ":let &option = expr" (static in C).
ex_let_option_o :: proc "c" (arg: cstring, tv: ^Typval_T, is_const: bool, endchars: cstring, op: cstring) -> cstring {
	context = runtime.default_context()
	if is_const {
		emsg(cstring(E996_OPT_S))
		return nil
	}
	arg_end: cstring = nil
	opt_idx: C.int = 0
	opt_flags: C.int = 0
	arg1 := arg
	p := find_option_var_end(&arg1, &opt_idx, &opt_flags)
	if p == nil || (endchars != nil && vim_strchr_c(transmute(^u8)(endchars), C.int(([^]u8)(skipwhite(p))[0])) == nil) {
		emsg(cstring(E18_S))
		return nil
	}
	c1 := ([^]u8)(p)[0]
	([^]u8)(p)[0] = 0
	is_tty := is_tty_option(arg)
	hidden := is_option_hidden(opt_idx)
	curval := OptVal{}
	if is_tty {
		curval = get_tty_option_e(arg)
	} else {
		curval = get_option_value(opt_idx, opt_flags)
	}
	newval := nil_optval()
	if curval.typ == kOptValTypeNil {
		semsg(cstring(E355_S), arg)
	} else if op != nil && ([^]u8)(op)[0] != '=' && ((curval.typ != kOptValTypeString && ([^]u8)(op)[0] == '.') || (curval.typ == kOptValTypeString && ([^]u8)(op)[0] != '.')) {
		semsg(cstring(E_LETWRONG_S), op)
	} else {
		error := false
		newval = tv_to_optval_o(tv, opt_idx, arg, &error)
		if !error {
			if curval.typ != newval.typ {
				libc.abort()
			}
			is_num := curval.typ == kOptValTypeNumber || curval.typ == kOptValTypeBoolean
			is_string := curval.typ == kOptValTypeString
			if op != nil && ([^]u8)(op)[0] != '=' {
				if !hidden && is_num {
					cur_n := (^C.longlong)(&curval.data)^
					new_n := (^C.longlong)(&newval.data)^
					opch := ([^]u8)(op)[0]
					if opch == '+' {
						new_n = cur_n + new_n
					} else if opch == '-' {
						new_n = cur_n - new_n
					} else if opch == '*' {
						new_n = cur_n * new_n
					} else if opch == '/' {
						new_n = num_divide(cur_n, new_n)
					} else if opch == '%' {
						new_n = num_modulus(cur_n, new_n)
					}
					if curval.typ == kOptValTypeNumber {
						newval = num_optval(new_n)
					} else {
						tri: C.int = 0
						if new_n != 0 {
							tri = 1
						}
						newval = bool_optval(tri)
					}
				} else if !hidden && is_string {
					cur_data := (^rawptr)(&curval.data)^
					new_data := (^rawptr)(&newval.data)^
					if cur_data != nil && new_data != nil {
						old := newval
						cc := concat_str_c(transmute(cstring)(cur_data), transmute(cstring)(new_data))
						newval = str_optval(cc, C.size_t(libc.strlen(transmute(cstring)(cc))))
						optval_free(old)
					}
				}
			}
			err := set_option_value_handle_tty(arg, opt_idx, newval, opt_flags)
			arg_end = p
			if err != nil {
				emsg(err)
			}
		}
	}
	([^]u8)(p)[0] = c1
	optval_free(curval)
	optval_free(newval)
	return arg_end
}

// ":let @r = expr" (static in C).
ex_let_register_o :: proc "c" (arg: cstring, tv: ^Typval_T, is_const: bool, endchars: cstring, op: cstring) -> cstring {
	context = runtime.default_context()
	if is_const {
		emsg(cstring(E996_REG_S))
		return nil
	}
	arg_end: cstring = nil
	arg1 := transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 1))
	opch := u8(0)
	if op != nil {
		opch = ([^]u8)(op)[0]
	}
	is_arith := opch == '+' || opch == '-' || opch == '*' || opch == '/' || opch == '%'
	if op != nil && is_arith {
		semsg(cstring(E_LETWRONG_S), op)
	} else if endchars != nil && vim_strchr_c(transmute(^u8)(endchars), C.int(([^]u8)(skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg1)) + 1))))[0])) == nil {
		emsg(cstring(E18_S))
	} else {
		ptofree: rawptr = nil
		p := tv_get_string_chk(tv)
		if p != nil && op != nil && ([^]u8)(op)[0] == '.' {
			regch: C.int = C.int(([^]u8)(arg1)[0])
			if ([^]u8)(arg1)[0] == '@' {
				regch = C.int('"')
			}
			s := transmute(cstring)(get_reg_contents(regch, kGRegExprSrc))
			if s != nil {
				ptofree = rawptr(concat_str_c(s, p))
				p = transmute(cstring)(ptofree)
				xfree(rawptr(s))
			}
		}
		if p != nil {
			regch2: C.int = C.int(([^]u8)(arg1)[0])
			if ([^]u8)(arg1)[0] == '@' {
				regch2 = C.int('"')
			}
			write_reg_contents(regch2, p, i64(C.size_t(libc.strlen(p))), 0)
			arg_end = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg1)) + 1))
		}
		xfree(ptofree)
	}
	return arg_end
}

// —— Batch 27a: funcs.c buf lookups ——
E158_S :: "E158: Invalid buffer name: %s"

// Find a buffer by number, name, or pattern.
@(export)
tv_get_buf :: proc "c" (tv: ^Typval_T, curtab_only: C.int) -> rawptr {
	context = runtime.default_context()
	if tv.v_type == VAR_NUMBER {
		return buflist_findnr(C.int(transmute(C.longlong)(tv.vval)))
	}
	if tv.v_type != VAR_STRING {
		return nil
	}
	name := transmute(cstring)(rawptr(tv.vval))
	if name == nil || ([^]u8)(name)[0] == 0 {
		return curbuf
	}
	if ([^]u8)(name)[0] == '$' && ([^]u8)(name)[1] == 0 {
		return lastbuf_g
	}
	save_magic := p_magic_g
	p_magic_g = 1
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	end := transmute(cstring)(rawptr(uintptr(transmute(rawptr)(name)) + uintptr(libc.strlen(name))))
	buf := buflist_findnr(buflist_findpat(name, end, true, false, curtab_only != 0))
	p_magic_g = save_magic
	p_cpo = save_cpo
	if buf == nil {
		buf = find_buffer(tv)
	}
	return buf
}

// —— Batch 27c: funcs.c math/bitwise leaves ——
E808_S :: "E808: Number or Float required"

// Float absolute value helper.
fabs_o :: proc "c" (x: f64) -> f64 {
	context = runtime.default_context()
	if x < 0 {
		return -x
	}
	return x
}

// Number-or-float coercion (typval.h static inline).
tv_get_float_chk_o :: proc "c" (tv: ^Typval_T, ret_f: ^f64) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_FLOAT {
		ret_f^ = transmute(f64)(tv.vval)
		return true
	}
	if tv.v_type == VAR_NUMBER {
		ret_f^ = f64(transmute(C.longlong)(tv.vval))
		return true
	}
	semsg(cstring("%s"), cstring(E808_S))
	return false
}

// Apply a float function with type checking (static in C).
float_op_wrapper_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fn: proc "c" (f64) -> f64) {
	context = runtime.default_context()
	f: f64 = 0
	rettv.v_type = VAR_FLOAT
	if tv_get_float_chk_o((^Typval_T)(uintptr(argvars)), &f) {
		rettv.vval = transmute(rawptr)(fn(f))
	} else {
		rettv.vval = transmute(rawptr)(f64(0))
	}
}

// "abs(expr)" function.
@(export)
f_abs :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	if av0.v_type == VAR_FLOAT {
		float_op_wrapper_o(argvars, rettv, fabs_o)
	} else {
		error := false
		n := tv_get_number_chk((^Typval_T)(uintptr(argvars)), &error)
		if error {
			rettv.vval = transmute(rawptr)(C.longlong(-1))
		} else if n > 0 {
			rettv.vval = transmute(rawptr)(n)
		} else {
			rettv.vval = transmute(rawptr)(-n)
		}
	}
}

// "and(expr, expr)" function.
@(export)
f_and :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil) & tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil))
}

// "or(expr, expr)" function.
@(export)
f_or :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil) | tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil))
}

// "xor(expr, expr)" function.
@(export)
f_xor :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil) ~ tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil))
}

// "byte2line(byte)" function.
@(export)
f_byte2line :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	boff := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)) - 1
	if boff < 0 {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(ml_find_line_or_offset_r(curbuf, 0, rawptr(&boff), false)))
	}
}

// "changenr()" function.
@(export)
f_changenr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(buf_i32_at(curbuf, B_U_SEQ_CUR)))
}

// —— Batch 27d: funcs.c float leaves ——
foreign _ {
	@(link_name = "atan2")
	c_atan2 :: proc "c" (x, y: f64) -> f64 ---
	@(link_name = "fmod")
	c_fmod :: proc "c" (x, y: f64) -> f64 ---
	@(link_name = "pow")
	c_pow :: proc "c" (x, y: f64) -> f64 ---
}

VARNUMBER_MAX_O :: 9223372036854775807
DBL_EPSILON_O :: 2.220446049250313e-16

// "atan2()" function.
@(export)
f_atan2 :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	fx, fy: f64 = 0, 0
	rettv.v_type = VAR_FLOAT
	if tv_get_float_chk_o((^Typval_T)(uintptr(argvars)), &fx) && tv_get_float_chk_o((^Typval_T)(uintptr(argvars) + 16), &fy) {
		rettv.vval = transmute(rawptr)(c_atan2(fx, fy))
	} else {
		rettv.vval = transmute(rawptr)(f64(0))
	}
}

// "float2nr()" function.
@(export)
f_float2nr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	f: f64 = 0
	if !tv_get_float_chk_o((^Typval_T)(uintptr(argvars)), &f) {
		return
	}
	if f <= f64(-C.longlong(VARNUMBER_MAX_O)) + DBL_EPSILON_O {
		rettv.vval = transmute(rawptr)(-C.longlong(VARNUMBER_MAX_O))
	} else if f >= f64(C.longlong(VARNUMBER_MAX_O)) - DBL_EPSILON_O {
		rettv.vval = transmute(rawptr)(C.longlong(VARNUMBER_MAX_O))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(f))
	}
}

// "fmod()" function.
@(export)
f_fmod :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	fx, fy: f64 = 0, 0
	rettv.v_type = VAR_FLOAT
	if tv_get_float_chk_o((^Typval_T)(uintptr(argvars)), &fx) && tv_get_float_chk_o((^Typval_T)(uintptr(argvars) + 16), &fy) {
		rettv.vval = transmute(rawptr)(c_fmod(fx, fy))
	} else {
		rettv.vval = transmute(rawptr)(f64(0))
	}
}

// "pow()" function.
@(export)
f_pow :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	fx, fy: f64 = 0, 0
	rettv.v_type = VAR_FLOAT
	if tv_get_float_chk_o((^Typval_T)(uintptr(argvars)), &fx) && tv_get_float_chk_o((^Typval_T)(uintptr(argvars) + 16), &fy) {
		rettv.vval = transmute(rawptr)(c_pow(fx, fy))
	} else {
		rettv.vval = transmute(rawptr)(f64(0))
	}
}

// "isinf()" function.
@(export)
f_isinf :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	if av0.v_type == VAR_FLOAT && xisinf(transmute(f64)(av0.vval)) != 0 {
		if transmute(f64)(av0.vval) > 0.0 {
			rettv.vval = transmute(rawptr)(C.longlong(1))
		} else {
			rettv.vval = transmute(rawptr)(C.longlong(-1))
		}
	}
}

// "isnan()" function.
@(export)
f_isnan :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	if av0.v_type == VAR_FLOAT && xisnan(transmute(f64)(av0.vval)) != 0 {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// —— Batch 27e: funcs.c introspection + trivial leaves ——

// "did_filetype()" function.
@(export)
f_did_filetype :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if (^bool)(uintptr(curbuf) + B_DID_FILETYPE_OFF)^ {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// "empty({expr})" function.
@(export)
f_empty :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	n := true
	switch av0.v_type {
	case VAR_STRING, VAR_FUNC:
		s := transmute(^u8)(av0.vval)
		n = s == nil || s^ == 0
	case VAR_PARTIAL:
		n = rawptr(av0.vval) == nil
	case VAR_NUMBER:
		n = transmute(C.longlong)(av0.vval) == 0
	case VAR_FLOAT:
		n = transmute(f64)(av0.vval) == 0.0
	case VAR_LIST:
		n = tv_list_len_o(rawptr(av0.vval)) == 0
	case VAR_DICT:
		n = tv_dict_len_o(rawptr(av0.vval)) == 0
	case VAR_BOOL:
		b := C.int(transmute(C.longlong)(av0.vval))
		if b == kBoolVarTrue {
			n = false
		} else {
			n = true
		}
	case VAR_SPECIAL:
		n = C.int(transmute(C.longlong)(av0.vval)) == KSPECIALVARNULL_O
	case VAR_BLOB:
		n = tv_blob_len_o(rawptr(av0.vval)) == 0
	case VAR_UNKNOWN:
		_internal_error(cstring("f_empty(UNKNOWN)"))
	}
	if n {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// "invert(expr)" function.
@(export)
f_invert :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(~tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil))
}

// "copy()" function.
@(export)
f_copy :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	var_item_copy(nil, (^Typval_T)(uintptr(argvars)), rettv, false, 0)
}

// "escape({string}, {chars})" function.
@(export)
f_escape :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [65]u8
	rettv.vval = transmute(rawptr)(vim_strsave_escaped_c(transmute(^u8)(tv_get_string((^Typval_T)(uintptr(argvars)))), transmute(^u8)(tv_get_string_buf((^Typval_T)(uintptr(argvars) + 16), &buf[0]))))
	rettv.v_type = VAR_STRING
}

// "getenv()" function.
@(export)
f_getenv :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	p := vim_getenv(tv_get_string((^Typval_T)(uintptr(argvars))))
	if p == nil {
		rettv.v_type = VAR_SPECIAL
		rettv.vval = transmute(rawptr)(C.longlong(KSPECIALVARNULL_O))
		return
	}
	rettv.vval = transmute(rawptr)(p)
	rettv.v_type = VAR_STRING
}

// —— Batch 27f: funcs.c type/lock/copy/pid/fname leaves ——
foreign _ {
	@(link_name = "vim_strsave_fnameescape")
	vim_strsave_fnameescape_e :: proc "c" (fname: cstring, what: C.int) -> ^u8 ---
}

VAR_TYPE_SPECIAL_O :: 7
E786_S :: "E786: Range not allowed"

// "type()" function.
@(export)
f_type :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	n: C.longlong = -1
	switch av0.v_type {
	case VAR_NUMBER:
		n = VAR_TYPE_NUMBER_O
	case VAR_STRING:
		n = VAR_TYPE_STRING_O
	case VAR_PARTIAL, VAR_FUNC:
		n = VAR_TYPE_FUNC_O
	case VAR_LIST:
		n = VAR_TYPE_LIST_O
	case VAR_DICT:
		n = VAR_TYPE_DICT_O
	case VAR_FLOAT:
		n = VAR_TYPE_FLOAT_O
	case VAR_BOOL:
		n = VAR_TYPE_BOOL_O
	case VAR_SPECIAL:
		n = VAR_TYPE_SPECIAL_O
	case VAR_BLOB:
		n = VAR_TYPE_BLOB_O
	case VAR_UNKNOWN:
		_internal_error(cstring("f_type(UNKNOWN)"))
	}
	rettv.vval = transmute(rawptr)(n)
}

// "islocked()" function.
@(export)
f_islocked :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	lv: [96]u8
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	end := get_lval(transmute(cstring)(tv_get_string((^Typval_T)(uintptr(argvars)))), nil, rawptr(&lv[0]), false, false, TFN_NO_AUTOLOAD_O | GLV_READ_ONLY_O, FNE_CHECK_START_O)
	ll_name := (^cstring)(rawptr(&lv[0]))^
	if end != nil && ll_name != nil {
		if ([^]u8)(end)[0] != 0 {
			ll_name_len := (^C.size_t)(rawptr(&lv[8]))^
			if ll_name_len == 0 {
				semsg(e_invarg2, end)
			} else {
				semsg(cstring(E488_S), end)
			}
		} else {
			ll_tv := (^rawptr)(rawptr(&lv[24]))^
			if ll_tv == nil {
				di := find_var(ll_name, (^C.size_t)(rawptr(&lv[8]))^, nil, 1)
				if di != nil {
					locked := (([^]u8)(uintptr(di) + 16)[0] & DI_FLAGS_LOCK_O) != 0 || tv_islocked((^Typval_T)(uintptr(di)))
					if locked {
						rettv.vval = transmute(rawptr)(C.longlong(1))
					} else {
						rettv.vval = transmute(rawptr)(C.longlong(0))
					}
				}
			} else if (^bool)(rawptr(&lv[48]))^ {
				emsg(cstring(E786_S))
			} else if (^cstring)(rawptr(&lv[80]))^ != nil {
				semsg(cstring(E_DICTKEY_S), (^cstring)(rawptr(&lv[80]))^)
			} else if (^rawptr)(rawptr(&lv[40]))^ != nil {
				li := (^rawptr)(rawptr(&lv[32]))^
				if tv_islocked((^Typval_T)(uintptr(li) + 16)) {
					rettv.vval = transmute(rawptr)(C.longlong(1))
				} else {
					rettv.vval = transmute(rawptr)(C.longlong(0))
				}
			} else {
				di := (^rawptr)(rawptr(&lv[72]))^
				if tv_islocked((^Typval_T)(uintptr(di))) {
					rettv.vval = transmute(rawptr)(C.longlong(1))
				} else {
					rettv.vval = transmute(rawptr)(C.longlong(0))
				}
			}
		}
	}
	clear_lval(rawptr(&lv[0]))
}

// "deepcopy()" function.
@(export)
f_deepcopy :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_opt_bool_arg(argvars, 1) == FAIL_E {
		return
	}
	noref: C.longlong = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		noref = tv_get_bool_chk((^Typval_T)(uintptr(argvars) + 16), nil)
	}
	copyID: C.int = 0
	if noref == 0 {
		copyID = get_copyID()
	}
	var_item_copy(nil, (^Typval_T)(uintptr(argvars)), rettv, true, copyID)
}

// "getpid()" function.
@(export)
f_getpid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(os_get_pid()))
}

// "fnameescape({string})" function.
@(export)
f_fnameescape :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(vim_strsave_fnameescape_e(tv_get_string((^Typval_T)(uintptr(argvars))), 0))
	rettv.v_type = VAR_STRING
}

// —— Batch 27g: funcs.c len/line/line2byte/localtime leaves ——
E701_S :: "E701: Invalid type for len()"

// "len()" function.
@(export)
f_len :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	switch av0.v_type {
	case VAR_STRING, VAR_NUMBER:
		rettv.vval = transmute(rawptr)(C.longlong(libc.strlen(tv_get_string((^Typval_T)(uintptr(argvars))))))
	case VAR_BLOB:
		rettv.vval = transmute(rawptr)(C.longlong(tv_blob_len_o(rawptr(av0.vval))))
	case VAR_LIST:
		rettv.vval = transmute(rawptr)(C.longlong(tv_list_len_o(rawptr(av0.vval))))
	case VAR_DICT:
		rettv.vval = transmute(rawptr)(C.longlong(tv_dict_len_o(rawptr(av0.vval))))
	case VAR_UNKNOWN, VAR_BOOL, VAR_SPECIAL, VAR_FLOAT, VAR_PARTIAL, VAR_FUNC:
		emsg(cstring(E701_S))
	}
}

// "line(string, [winid])" function.
@(export)
f_line :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	lnum: C.longlong = 0
	fp: rawptr = nil
	fnum: C.int = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		id := C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16)))
		tp: rawptr = nil
		wp := win_id2wp_tp(id, &tp)
		if wp != nil && tp != nil {
			if p_spk_g^ != 'c' || ((^C.int)(uintptr(wp) + W_P_DIFF_OFF)^ != 0 && (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0) {
				skip_update_topline_g = true
			}
			check_cursor(wp)
			fp = var2fpos((^Typval_T)(uintptr(argvars)), true, &fnum, false, wp)
			skip_update_topline_g = false
		}
	} else {
		fp = var2fpos((^Typval_T)(uintptr(argvars)), true, &fnum, false, curwin)
	}
	if fp != nil {
		lnum = C.longlong((^C.int)(uintptr(fp))^)
	}
	rettv.vval = transmute(rawptr)(lnum)
}

// "line2byte(lnum)" function.
@(export)
f_line2byte :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	n: C.longlong = -1
	if lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ + 1 {
		n = C.longlong(ml_find_line_or_offset_r(curbuf, lnum, nil, false))
	}
	if n >= 0 {
		n += 1
	}
	rettv.vval = transmute(rawptr)(n)
}

// "localtime()" function.
@(export)
f_localtime :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(libc.time(nil)))
}

// —— Batch 27h: funcs.c col + char leaves ——
E5070_S :: "E5070: Character number must not be less than zero"
E5071_S :: "E5071: Character number must not be greater than INT_MAX (%i)"

// Shared col()/charcol() implementation (C-static).
get_col_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, charcol: bool) {
	context = runtime.default_context()
	if tv_check_for_string_or_list_arg(argvars, 0) == FAIL_E || tv_check_for_opt_number_arg(argvars, 1) == FAIL_E {
		return
	}
	wp := curwin
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		tp: rawptr = nil
		wp = win_id2wp_tp(C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16))), &tp)
		if wp == nil || tp == nil {
			return
		}
		check_cursor(wp)
	}
	bp := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	col: C.int = 0
	fnum := (^C.int)(uintptr(bp) + B_FNUM_OFF)^
	fp := var2fpos((^Typval_T)(uintptr(argvars)), false, &fnum, charcol, wp)
	if fp != nil && fnum == (^C.int)(uintptr(bp) + B_FNUM_OFF)^ {
		fp_col := (^C.int)(uintptr(fp) + 4)^
		fp_lnum := (^C.int)(uintptr(fp))^
		if fp_col == MAXCOL {
			if fp_lnum <= (^C.int)(uintptr(bp) + B_ML_LINE_COUNT)^ {
				col = ml_get_buf_len(bp, fp_lnum) + 1
			} else {
				col = MAXCOL
			}
		} else {
			col = fp_col + 1
			if virtual_active(wp) && uintptr(fp) == uintptr(wp) + W_CURSOR_OFF {
				w_lnum := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
				w_col := (^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^
				w_coladd := (^C.int)(uintptr(wp) + W_CURSOR_OFF + 8)^
				w_virtcol := (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
				p := rawptr(uintptr(ml_get_buf(bp, w_lnum)) + uintptr(w_col))
				if w_coladd >= win_chartabsize_r(wp, transmute(^u8)(p), w_virtcol - w_coladd) {
					if ([^]u8)(p)[0] != 0 {
						l := utfc_ptr2len(transmute(cstring)(p))
						if ([^]u8)(p)[uintptr(l)] == 0 {
							col += l
						}
					}
				}
			}
		}
	}
	rettv.vval = transmute(rawptr)(C.longlong(col))
}

// "charcol()" function.
@(export)
f_charcol :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_col_o(argvars, rettv, true)
}

// "col(string)" function.
@(export)
f_col :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_col_o(argvars, rettv, false)
}

// "char2nr(string)" function.
@(export)
f_char2nr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		if !tv_check_num((^Typval_T)(uintptr(argvars) + 16)) {
			return
		}
	}
	rettv.vval = transmute(rawptr)(C.longlong(utf_ptr2char(tv_get_string((^Typval_T)(uintptr(argvars))))))
}

// "nr2char()" function.
@(export)
f_nr2char :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		if !tv_check_num((^Typval_T)(uintptr(argvars) + 16)) {
			return
		}
	}
	error := false
	num := tv_get_number_chk((^Typval_T)(uintptr(argvars)), &error)
	if error {
		return
	}
	if num < 0 {
		emsg(cstring(E5070_S))
		return
	}
	if num > C.longlong(max(C.int)) {
		semsg(cstring(E5071_S), max(C.int))
		return
	}
	buf: [6]u8
	length := utf_char2bytes(C.int(num), &buf[0])
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(xmemdupz_o2(&buf[0], C.size_t(length)))
}

// —— Batch 27i: funcs.c getpos cluster (FFI fully rewired) ——

// Shared getpos()/getcurpos()/getcharpos()/getcursorcharpos() engine (C-static).
getpos_both_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, getcurpos: bool, charcol: bool) {
	context = runtime.default_context()
	fp: rawptr = nil
	pos: Pos_T
	wp := curwin
	fnum: C.int = -1
	if getcurpos {
		if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
			wp = find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
			if wp != nil {
				fp = rawptr(uintptr(wp) + W_CURSOR_OFF)
			}
		} else {
			fp = rawptr(uintptr(curwin) + W_CURSOR_OFF)
		}
		if fp != nil && charcol {
			pos = (cast(^Pos_T)(fp))^
			pos.col = buf_byteidx_to_charidx((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, pos.lnum, pos.col)
			fp = rawptr(&pos)
		}
	} else {
		fp = var2fpos((^Typval_T)(uintptr(argvars)), true, &fnum, charcol, curwin)
	}
	l_size: C.int = 4
	if getcurpos {
		l_size = 5
	}
	l := tv_list_alloc_ret(transmute(^Typval)(rettv), l_size)
	if fnum != -1 {
		tv_list_append_number(l, C.longlong(fnum))
	} else {
		tv_list_append_number(l, C.longlong(0))
	}
	if fp != nil {
		tv_list_append_number(l, C.longlong((^C.int)(uintptr(fp))^))
	} else {
		tv_list_append_number(l, C.longlong(0))
	}
	if fp != nil {
		fp_col := (^C.int)(uintptr(fp) + 4)^
		if fp_col == MAXCOL {
			tv_list_append_number(l, C.longlong(MAXCOL))
		} else {
			tv_list_append_number(l, C.longlong(fp_col + 1))
		}
	} else {
		tv_list_append_number(l, C.longlong(0))
	}
	if fp != nil {
		tv_list_append_number(l, C.longlong((^C.int)(uintptr(fp) + 8)^))
	} else {
		tv_list_append_number(l, C.longlong(0))
	}
	if getcurpos {
		save_set_curswant := (^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^
		save_curswant := (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
		save_virtcol := (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^
		if wp == curwin {
			update_curswant_r()
		}
		if wp == nil {
			tv_list_append_number(l, C.longlong(0))
		} else {
			w_curswant := (^C.int)(uintptr(wp) + W_CURSWANT_OFF)^
			if w_curswant == MAXCOL {
				tv_list_append_number(l, C.longlong(MAXCOL))
			} else {
				tv_list_append_number(l, C.longlong(w_curswant + 1))
			}
		}
		if wp == curwin && save_set_curswant {
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = save_set_curswant
			(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = save_curswant
			(^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ = save_virtcol
			(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_VIRTCOL_O)
		}
	}
}

// "getcurpos(string)" function.
@(export)
f_getcurpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getpos_both_o(argvars, rettv, true, false)
}

// "getcursorcharpos()" function.
@(export)
f_getcursorcharpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getpos_both_o(argvars, rettv, true, true)
}

// "getpos(string)" function.
@(export)
f_getpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getpos_both_o(argvars, rettv, false, false)
}

// "getcharpos()" function.
@(export)
f_getcharpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	getpos_both_o(argvars, rettv, false, true)
}

// —— Batch 27j: funcs.c cursor/position setters (FFI fully rewired) ——

// Shared cursor()/setcursorcharpos() engine (C-static).
set_cursorpos_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, charcol: bool) {
	context = runtime.default_context()
	lnum: C.int = 0
	col: C.int = 0
	coladd: C.int = 0
	set_curswant := true
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		pos: Pos_T
		curswant: C.int = -1
		if list2fpos((^Typval_T)(uintptr(argvars)), &pos, nil, &curswant, charcol) == FAIL_E {
			emsg(e_invarg)
			return
		}
		lnum = pos.lnum
		col = pos.col
		coladd = pos.coladd
		if curswant >= 0 {
			(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = curswant - 1
			set_curswant = false
		}
	} else if (([^]Typval_T)(argvars)[0].v_type == VAR_NUMBER || ([^]Typval_T)(argvars)[0].v_type == VAR_STRING) && (([^]Typval_T)(argvars)[1].v_type == VAR_NUMBER || ([^]Typval_T)(argvars)[1].v_type == VAR_STRING) {
		lnum = tv_get_lnum((^Typval_T)(uintptr(argvars)))
		if lnum < 0 {
			semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars))))
		} else if lnum == 0 {
			lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		}
		col = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil))
		if charcol {
			col = buf_charidx_to_byteidx(curbuf, lnum, C.int(col)) + 1
		}
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			coladd = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), nil))
		}
	} else {
		emsg(e_invarg)
		return
	}
	if lnum < 0 || col < 0 || coladd < 0 {
		return
	}
	if lnum > 0 {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
	}
	if col != MAXCOL {
		col -= 1
		if col < 0 {
			col = 0
		}
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = coladd
	check_cursor(curwin)
	mb_adjust_cursor_r()
	(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = set_curswant
	rettv.vval = transmute(rawptr)(C.longlong(0))
}

// Shared setpos()/setcharpos() engine (C-static).
set_position_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, charpos: bool) {
	context = runtime.default_context()
	curswant: C.int = -1
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	name := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if name == nil {
		return
	}
	pos: Pos_T
	fnum: C.int = 0
	if list2fpos((^Typval_T)(uintptr(argvars) + 16), &pos, &fnum, &curswant, charpos) != OK_E {
		return
	}
	if pos.col != MAXCOL {
		pos.col -= 1
		if pos.col < 0 {
			pos.col = 0
		}
	}
	nm := ([^]u8)(name)
	if nm[0] == '.' && nm[1] == 0 {
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
		if curswant >= 0 {
			(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = curswant - 1
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = false
		}
		check_cursor(curwin)
		rettv.vval = transmute(rawptr)(C.longlong(0))
	} else if nm[0] == '\'' && nm[1] != 0 && nm[2] == 0 {
		if setmark_pos(C.int(nm[1]), &pos, fnum, nil) == OK_E {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		}
	} else {
		emsg(e_invarg)
	}
}

// "cursor(lnum, col)" function.
@(export)
f_cursor :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	set_cursorpos_o(argvars, rettv, false)
}

// "setcursorcharpos" function.
@(export)
f_setcursorcharpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	set_cursorpos_o(argvars, rettv, true)
}

// "setcharpos()" function.
@(export)
f_setcharpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	set_position_o(argvars, rettv, true)
}

// "setpos()" function.
@(export)
f_setpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	set_position_o(argvars, rettv, false)
}

// —— Batch 27k: funcs.c flatten + index ——
E900_S :: "E900: maxdepth must be non-negative number"

// Normalize index (typval.h static inline).
tv_list_uidx_o :: proc "c" (l: rawptr, n_in: C.int) -> C.int {
	context = runtime.default_context()
	n := n_in
	if n < 0 {
		n += tv_list_len_o(l)
	}
	if n < 0 || n >= tv_list_len_o(l) {
		return -1
	}
	return n
}

// Shared flatten()/flattennew() engine (C-static).
flatten_common_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, make_copy: bool) {
	context = runtime.default_context()
	error := false
	if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST {
		semsg(cstring(E_LISTARG_S), cstring("flatten()"))
		return
	}
	maxdepth: C.int = 999999
	if ([^]Typval_T)(argvars)[1].v_type == VAR_UNKNOWN {
	} else {
		maxdepth = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error))
		if error {
			return
		}
		if maxdepth < 0 {
			emsg(cstring(E900_S))
			return
		}
	}
	list := rawptr(([^]Typval_T)(argvars)[0].vval)
	rettv.v_type = VAR_LIST
	rettv.vval = transmute(rawptr)(list)
	if list == nil {
		return
	}
	if make_copy {
		list = tv_list_copy(nil, list, false, get_copyID())
		rettv.vval = transmute(rawptr)(list)
		if list == nil {
			return
		}
	} else {
		if value_check_lock(tv_list_locked_o(list), cstring("flatten() argument"), max(C.size_t)) {
			return
		}
		tv_list_ref_o(list)
	}
	tv_list_flatten(list, nil, C.longlong(tv_list_len_o(list)), C.longlong(maxdepth))
}

// "flatten(list[, {maxdepth}])" function.
@(export)
f_flatten :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	flatten_common_o(argvars, rettv, false)
}

// "flattennew(list[, {maxdepth}])" function.
@(export)
f_flattennew :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	flatten_common_o(argvars, rettv, true)
}

// "index()" function.
@(export)
f_index :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	idx: C.int = 0
	ic := false
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if ([^]Typval_T)(argvars)[0].v_type == VAR_BLOB {
		error := false
		start: C.int = 0
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			start = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error))
			if error {
				return
			}
		}
		b := rawptr(([^]Typval_T)(argvars)[0].vval)
		if b == nil {
			return
		}
		if start < 0 {
			start = tv_blob_len_o(b) + start
			if start < 0 {
				start = 0
			}
		}
		for idx = start; idx < tv_blob_len_o(b); idx += 1 {
			tv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(tv_blob_get_o(b, idx)))}
			if tv_equal(&tv, (^Typval_T)(uintptr(argvars) + 16), ic) {
				rettv.vval = transmute(rawptr)(C.longlong(idx))
				return
			}
		}
		return
	} else if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST {
		emsg(cstring(E_LISTBLOBREQ_S))
		return
	}
	l := rawptr(([^]Typval_T)(argvars)[0].vval)
	if l == nil {
		return
	}
	item := tv_list_first_o(l)
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		error := false
		idx = tv_list_uidx_o(l, C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error)))
		if error || idx == -1 {
			item = nil
		} else {
			item = tv_list_find(l, idx)
			if item == nil {
				libc.abort()
			}
		}
		if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
			ic = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 48), &error) != 0
			if error {
				item = nil
			}
		}
	}
	for item != nil {
		if tv_equal((^Typval_T)(uintptr(item) + 16), (^Typval_T)(uintptr(argvars) + 16), ic) {
			rettv.vval = transmute(rawptr)(C.longlong(idx))
			break
		}
		item = (^rawptr)(uintptr(item))^
		idx += 1
	}
}

// —— Batch 27b: funcs.c window/line/execute leaves ——
foreign _ {
	@(link_name = "emsg_noredir")
	emsg_noredir_g: bool
	@(link_name = "redir_off")
	redir_off_g: bool
	@(link_name = "capture_ga")
	capture_ga_g: rawptr
}

E957_S :: "E957: Invalid window number"
DOCMD_KEYTYPED_O :: 0x08

// LineGetter cookie for execute() over a list.
GetListLineCookie :: struct {
	l:  rawptr,
	li: rawptr,
}
#assert(size_of(GetListLineCookie) == 16)

// Find an optional window argument (curwin when missing).
@(export)
get_optional_window :: proc "c" (argvars: ^Typval_T, idx: C.int) -> rawptr {
	context = runtime.default_context()
	av := ([^]Typval_T)(argvars)[idx]
	if av.v_type == VAR_UNKNOWN {
		return curwin
	}
	win := find_win_by_nr_or_id((^Typval_T)(uintptr(argvars) + uintptr(idx) * 16))
	if win == nil {
		emsg(cstring(E957_S))
		return nil
	}
	return win
}

// Next list line for execute() (LineGetter).
@(export)
get_list_line :: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> cstring {
	context = runtime.default_context()
	p := (^GetListLineCookie)(cookie)
	item := p.li
	if item == nil {
		return nil
	}
	buf: [65]u8
	s := tv_get_string_buf_chk((^Typval_T)(uintptr(item) + 16), &buf[0])
	p.li = (^rawptr)(uintptr(item) + 0)^
	if s == nil {
		return nil
	}
	return transmute(cstring)(xstrdup_o(transmute(^u8)(s)))
}

// Shared execute()/execute-command implementation.
@(export)
execute_common :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, arg_off: C.int) {
	context = runtime.default_context()
	save_msg_silent := msg_silent
	save_emsg_silent := emsg_silent
	save_emsg_noredir := emsg_noredir_g
	save_redir_off := redir_off_g
	save_capture := capture_ga_g
	save_msg_col := msg_col
	echo_output := false
	if check_secure() {
		return
	}
	av1 := ([^]Typval_T)(argvars)[arg_off + 1]
	if av1.v_type != VAR_UNKNOWN {
		buf: [65]u8
		s := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + uintptr(arg_off + 1) * 16), &buf[0])
		if s == nil {
			return
		}
		if ([^]u8)(s)[0] == 0 {
			echo_output = true
		}
		if libc.strncmp(s, cstring("silent"), 6) == 0 {
			msg_silent += 1
		}
		if libc.strcmp(s, cstring("silent!")) == 0 {
			emsg_silent = 1
			emsg_noredir_g = true
		}
	} else {
		msg_silent += 1
	}
	capture_local := Garray{}
	ga_init(&capture_local, 1, 80)
	capture_ga_g = rawptr(&capture_local)
	redir_off_g = false
	if !echo_output {
		msg_col = 0
	}
	av0 := ([^]Typval_T)(argvars)[arg_off]
	if av0.v_type != VAR_LIST {
		do_cmdline_cmd(tv_get_string((^Typval_T)(uintptr(argvars) + uintptr(arg_off) * 16)))
	} else if rawptr(av0.vval) != nil {
		list := rawptr(av0.vval)
		tv_list_ref_o(list)
		cookie := GetListLineCookie{l = list, li = tv_list_first_o(list)}
		do_cmdline(nil, transmute(LineGetter)(get_list_line), rawptr(&cookie), DOCMD_NOWAIT_O | DOCMD_VERBOSE_O | DOCMD_REPEAT_O | DOCMD_KEYTYPED_O)
		tv_list_unref(list)
	}
	msg_silent = save_msg_silent
	emsg_silent = save_emsg_silent
	emsg_noredir_g = save_emsg_noredir
	redir_off_g = save_redir_off
	if echo_output {
		msg_col = 0
	} else {
		msg_col = save_msg_col
	}
	ga_append(&capture_local, 0)
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(capture_local.ga_data)
	capture_ga_g = save_capture
}

// Like tv_get_buf with a type error on misuse.
@(export)
tv_get_buf_from_arg :: proc "c" (tv: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	if !tv_check_str_or_nr(tv) {
		return nil
	}
	emsg_off += 1
	buf := tv_get_buf(tv, 0)
	emsg_off -= 1
	return buf
}

// Get a buffer or error when the name is invalid.
@(export)
get_buf_arg :: proc "c" (arg: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	emsg_off += 1
	buf := tv_get_buf(arg, 0)
	emsg_off -= 1
	if buf == nil {
		semsg(cstring(E158_S), tv_get_string(arg))
	}
	return buf
}

// —— Batch 27l: funcs.c env/perm/csearch leaves ——

// "setenv()" function.
@(export)
f_setenv :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	namebuf: [65]u8
	valbuf: [65]u8
	name := tv_get_string_buf((^Typval_T)(uintptr(argvars)), &namebuf[0])
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type == VAR_SPECIAL && C.int(transmute(C.longlong)(([^]Typval_T)(argvars)[1].vval)) == KSPECIALVARNULL_O {
		vim_unsetenv_ext(name)
	} else {
		vim_setenv_ext(name, tv_get_string_buf((^Typval_T)(uintptr(argvars) + 16), &valbuf[0]))
	}
}

// "setfperm({fname}, {mode})" function.
@(export)
f_setfperm :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(0))
	fname := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if fname == nil {
		return
	}
	modebuf: [65]u8
	mode_str := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &modebuf[0])
	if mode_str == nil {
		return
	}
	if libc.strlen(mode_str) != 9 {
		semsg(e_invarg2, mode_str)
		return
	}
	mask: C.int = 1
	mode: C.int = 0
	i := 8
	for i >= 0 {
		if ([^]u8)(mode_str)[uintptr(i)] != '-' {
			mode |= mask
		}
		mask <<= 1
		i -= 1
	}
	if os_setperm(fname, mode) == OK {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// "getcharsearch()" function.
@(export)
f_getcharsearch :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(rettv)
	dict := rawptr(rettv.vval)
	tv_dict_add_str(dict, cstring("char"), 4, transmute(cstring)(last_csearch()))
	tv_dict_add_nr(dict, cstring("forward"), 7, C.longlong(last_csearch_forward()))
	tv_dict_add_nr(dict, cstring("until"), 5, C.longlong(last_csearch_until()))
}

// "setcharsearch()" function.
@(export)
f_setcharsearch :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_dict_arg(argvars, 0) == FAIL_E {
		return
	}
	d := rawptr(([^]Typval_T)(argvars)[0].vval)
	if d == nil {
		return
	}
	csearch := tv_dict_get_string(d, cstring("char"), false)
	if csearch != nil {
		c := utf_ptr2char(csearch)
		set_last_csearch(c, transmute(^u8)(csearch), utfc_ptr2len(csearch))
	}
	di := tv_dict_find(d, cstring("forward"), 7)
	if di != nil {
		if tv_get_number((^Typval_T)(uintptr(di))) != 0 {
			set_csearch_direction(.FORWARD)
		} else {
			set_csearch_direction(.BACKWARD)
		}
	}
	di = tv_dict_find(d, cstring("until"), 5)
	if di != nil {
		if tv_get_number((^Typval_T)(uintptr(di))) != 0 {
			set_csearch_until(true)
		} else {
			set_csearch_until(false)
		}
	}
}

// —— Batch 27m: funcs.c highlight + fontname + interrupt leaves ——
foreign _ {
	@(link_name = "syn_name2id")
	syn_name2id_e :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "highlight_exists")
	highlight_exists_e :: proc "c" (name: cstring) -> C.int ---
}

// "hlID()" function.
@(export)
f_hlID :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(syn_name2id_e(tv_get_string((^Typval_T)(uintptr(argvars))))))
}

// "highlight_exists()" function.
@(export)
f_hlexists :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(highlight_exists_e(tv_get_string((^Typval_T)(uintptr(argvars))))))
}

// "getfontname()" function.
@(export)
f_getfontname :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
}

// "interrupt()" function.
@(export)
f_interrupt :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	got_int = true
}

// —— Batch 27r: funcs.c gettext/keytrans/libcall ——
foreign _ {
	@(link_name = "str2special_save")
	str2special_save_e :: proc "c" (str: cstring, replace_spaces: bool, replace_others: TriState) -> cstring ---
}

E364_S :: "E364: Library call failed for \"%s()\""

// "gettext()" function.
@(export)
f_gettext :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_nonempty_string_arg(argvars, 0) == FAIL_E {
		return
	}
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(([^]Typval_T)(argvars)[0].vval)))
}

// "keytrans()" function.
@(export)
f_keytrans :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	if tv_check_for_string_arg(argvars, 0) == FAIL_E || rawptr(([^]Typval_T)(argvars)[0].vval) == nil {
		return
	}
	escaped := vim_strsave_escape_ks(transmute(^u8)(([^]Typval_T)(argvars)[0].vval))
	rettv.vval = transmute(rawptr)(str2special_save_e(transmute(cstring)(escaped), true, TriState.kTrue))
	xfree(rawptr(escaped))
}

// Shared libcall()/libcallnr() engine (C-static).
libcall_common_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, out_type: C.int) {
	context = runtime.default_context()
	rettv.v_type = out_type
	if out_type != VAR_NUMBER {
		rettv.vval = transmute(rawptr)(cstring(nil))
	}
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING || ([^]Typval_T)(argvars)[1].v_type != VAR_STRING {
		return
	}
	libname := transmute(cstring)(([^]Typval_T)(argvars)[0].vval)
	funcname := transmute(cstring)(([^]Typval_T)(argvars)[1].vval)
	in_type := ([^]Typval_T)(argvars)[2].v_type
	str_in: cstring = nil
	if in_type == VAR_STRING {
		str_in = transmute(cstring)(([^]Typval_T)(argvars)[2].vval)
	}
	int_in := C.int(transmute(C.longlong)(([^]Typval_T)(argvars)[2].vval))
	str_out: cstring = nil
	outp: ^cstring = nil
	if out_type == VAR_STRING {
		outp = &str_out
	}
	int_out: C.int = 0
	if !os_libcall(libname, funcname, str_in, int_in, outp, &int_out) {
		semsg(cstring(E364_S), funcname)
		return
	}
	if out_type == VAR_NUMBER {
		rettv.vval = transmute(rawptr)(C.longlong(int_out))
	} else {
		rettv.vval = transmute(rawptr)(str_out)
	}
}

// "libcall()" function.
@(export)
f_libcall :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	libcall_common_o(argvars, rettv, VAR_STRING)
}

// "libcallnr()" function.
@(export)
f_libcallnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	libcall_common_o(argvars, rettv, VAR_NUMBER)
}

// —— Batch 27s: funcs.c getreg pair ——

// Register-name resolver (C-static in funcs.c).
getreg_get_regname_o :: proc "c" (argvars: ^Typval_T) -> C.int {
	context = runtime.default_context()
	strregname: cstring = nil
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		strregname = tv_get_string_chk((^Typval_T)(uintptr(argvars)))
		if strregname == nil {
			return 0
		}
	} else {
		strregname = get_vim_var_str(VV_REG_O)
	}
	if ([^]u8)(strregname)[0] == 0 {
		return '"'
	}
	return C.int(([^]u8)(strregname)[0])
}

// "getreg()" function.
@(export)
f_getreg :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	arg2 := false
	return_list := false
	regname := getreg_get_regname_o(argvars)
	if regname == 0 {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		error := false
		arg2 = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error) != 0
		if !error && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			return_list = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error) != 0
		}
		if error {
			return
		}
	}
	flags: C.int = 0
	if arg2 {
		flags = kGRegExprSrc
	}
	if return_list {
		rettv.v_type = VAR_LIST
		rettv.vval = get_reg_contents(regname, flags | kGRegList)
		if rawptr(rettv.vval) == nil {
			rettv.vval = tv_list_alloc(0)
		}
		tv_list_ref_o(rawptr(rettv.vval))
	} else {
		rettv.v_type = VAR_STRING
		rettv.vval = get_reg_contents(regname, flags)
	}
}

// "getregtype()" function.
@(export)
f_getregtype :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	regname := getreg_get_regname_o(argvars)
	if regname == 0 {
		return
	}
	reglen: C.int = 0
	buf: [67]u8
	reg_type := get_reg_type(regname, &reglen)
	format_reg_type(reg_type, reglen, &buf[0], 67)
	rettv.vval = transmute(rawptr)(xstrdup_o(&buf[0]))
}

// —— Batch 27t: funcs.c expand + expandcmd ——
foreign _ {
	@(link_name = "eval_vars")
	eval_vars_e :: proc "c" (src: cstring, srcstart: cstring, usedlen: ^C.size_t, lnump: ^C.int, errormsg: ^cstring, escaped: ^C.int, empty_is_error: bool) -> cstring ---
	@(link_name = "expand_filename")
	expand_filename_e :: proc "c" (eap: rawptr, cmdlinep: ^cstring, errormsgp: ^cstring) -> C.int ---
}

WILD_LIST_NOTFOUND_O :: 0x01
EXARG_ARGT_OFF :: 68
CMD_USER_O :: -1
EX_NOSPC_O :: 0x010

// "expand()" function.
@(export)
f_expand :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	options: C.int = 0x40 | WILD_USE_NL_O | WILD_LIST_NOTFOUND_O
	error := false
	rettv.v_type = VAR_STRING
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error) != 0 && !error {
		tv_list_set_ret_o(rettv, nil)
	}
	s := tv_get_string((^Typval_T)(uintptr(argvars)))
	if ([^]u8)(s)[0] == '%' || ([^]u8)(s)[0] == '#' || ([^]u8)(s)[0] == '<' {
		if p_verbose == 0 {
			emsg_off += 1
		}
		usedlen: C.size_t = 0
		errormsg: cstring = nil
		result := eval_vars_e(transmute(cstring)(s), s, &usedlen, nil, &errormsg, nil, false)
		if p_verbose == 0 {
			emsg_off -= 1
		} else if errormsg != nil {
			emsg(errormsg)
		}
		if rettv.v_type == VAR_LIST {
			n: C.int = 0
			if result != nil {
				n = 1
			}
			tv_list_alloc_ret(transmute(^Typval)(rettv), n)
			if result != nil {
				tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(result), -1)
			}
			xfree(rawptr(result))
		} else {
			rettv.vval = transmute(rawptr)(result)
		}
	} else {
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error) != 0 {
			options |= WILD_KEEP_ALL_O
		}
		if !error {
			xpc: expand_T
			_ExpandInit(transmute(rawptr)(&xpc))
			xpc.xp_context = 2
			if p_wic_g != 0 {
				options += WILD_ICASE_O
			}
			if rettv.v_type == VAR_STRING {
				rettv.vval = transmute(rawptr)(_ExpandOne(transmute(rawptr)(&xpc), transmute(cstring)(s), nil, options, WILD_ALL_O))
			} else {
				_ExpandOne(transmute(rawptr)(&xpc), transmute(cstring)(s), nil, options, WILD_ALL_KEEP_O)
				tv_list_alloc_ret(transmute(^Typval)(rettv), xpc.xp_numfiles)
				i: C.int = 0
				for i < xpc.xp_numfiles {
					tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(([^]cstring)(xpc.xp_files)[uintptr(i)]), -1)
					i += 1
				}
				ExpandCleanup_e(transmute(rawptr)(&xpc))
			}
		} else {
			rettv.vval = nil
		}
	}
}

// "expandcmd()" function.
@(export)
f_expandcmd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	errormsg: cstring = nil
	emsgoff := true
	if ([^]Typval_T)(argvars)[1].v_type == VAR_DICT && tv_dict_get_bool(rawptr(([^]Typval_T)(argvars)[1].vval), cstring("errmsg"), kBoolVarFalse) != 0 {
		emsgoff = false
	}
	rettv.v_type = VAR_STRING
	cmdstr := xstrdup_o(transmute(^u8)(tv_get_string((^Typval_T)(uintptr(argvars)))))
	eap: [192]u8
	libc.memset(&eap[0], 0, 192)
	(^cstring)(rawptr(&eap[EXARG_CMD_OFF]))^ = transmute(cstring)(cmdstr)
	(^cstring)(rawptr(&eap[EXARG_ARG_OFF_O]))^ = transmute(cstring)(cmdstr)
	(^C.int)(rawptr(&eap[EXARG_CMDIDX_OFF]))^ = CMD_USER_O
	(^u32)(rawptr(&eap[EXARG_ARGT_OFF]))^ |= EX_NOSPC_O
	if emsgoff {
		emsg_off += 1
	}
	cmdline := transmute(cstring)(cmdstr)
	if expand_filename_e(rawptr(&eap[0]), &cmdline, &errormsg) == FAIL_E {
		if !emsgoff && errormsg != nil && ([^]u8)(errormsg)[0] != 0 {
			emsg(errormsg)
		}
	}
	if emsgoff {
		emsg_off -= 1
	}
	rettv.vval = transmute(rawptr)(cmdline)
}

// —— Batch 27u: funcs.c changelist/jumplist/marklist getters ——
foreign _ {
	@(link_name = "vim_ignored")
	vim_ignored_g: C.int
}

// "getchangelist()" function.
@(export)
f_getchangelist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	buf := curbuf
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
	} else {
		vim_ignored_g = C.int(tv_get_number((^Typval_T)(uintptr(argvars))))
		emsg_off += 1
		buf = tv_get_buf((^Typval_T)(uintptr(argvars)), 0)
		emsg_off -= 1
	}
	if buf == nil {
		return
	}
	clen := (^C.int)(uintptr(buf) + B_CHANGELISTLEN)^
	l := tv_list_alloc(C.ssize_t(clen))
	tv_list_append_list(rawptr(rettv.vval), l)
	changelistindex := clen
	if buf == (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ {
		changelistindex = (^C.int)(uintptr(curwin) + W_CHANGELISTIDX_OFF)^
	} else {
		n := (^C.size_t)(uintptr(buf) + B_WINFOFF_SIZE)^
		items := ([^]rawptr)((^rawptr)(rawptr(uintptr(buf) + B_WINFOFF_ITEMS))^)
		for i: C.size_t = 0; i < n; i += 1 {
			wip := items[i]
			if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == curwin {
				changelistindex = (^C.int)(uintptr(wip) + WI_CHANGELISTIDX_OFF)^
				break
			}
		}
	}
	tv_list_append_number(rawptr(rettv.vval), C.longlong(changelistindex))
	i: C.int = 0
	for i < clen {
		e := uintptr(buf) + B_CHANGELIST + uintptr(i) * 40
		if (^C.int)(e)^ != 0 {
			d := tv_dict_alloc()
			tv_list_append_dict(l, d)
			tv_dict_add_nr(d, cstring("lnum"), 4, C.longlong((^C.int)(e)^))
			tv_dict_add_nr(d, cstring("col"), 3, C.longlong((^C.int)(e + 4)^))
			tv_dict_add_nr(d, cstring("coladd"), 6, C.longlong((^C.int)(e + 8)^))
		}
		i += 1
	}
}

// "getjumplist()" function.
@(export)
f_getjumplist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	wp := find_tabwin((^Typval_T)(uintptr(argvars)), (^Typval_T)(uintptr(argvars) + 16))
	if wp == nil {
		return
	}
	cleanup_jumplist(wp, true)
	jlen := (^C.int)(uintptr(wp) + W_JUMPLISTLEN)^
	l := tv_list_alloc(C.ssize_t(jlen))
	tv_list_append_list(rawptr(rettv.vval), l)
	tv_list_append_number(rawptr(rettv.vval), C.longlong((^C.int)(uintptr(wp) + W_JUMPLISTIDX)^))
	i: C.int = 0
	for i < jlen {
		e := uintptr(wp) + W_JUMPLIST + uintptr(i) * 48
		if (^C.int)(e)^ != 0 {
			d := tv_dict_alloc()
			tv_list_append_dict(l, d)
			tv_dict_add_nr(d, cstring("lnum"), 4, C.longlong((^C.int)(e)^))
			tv_dict_add_nr(d, cstring("col"), 3, C.longlong((^C.int)(e + 4)^))
			tv_dict_add_nr(d, cstring("coladd"), 6, C.longlong((^C.int)(e + 8)^))
			tv_dict_add_nr(d, cstring("bufnr"), 5, C.longlong((^C.int)(e + 12)^))
			fn := (^cstring)(e + 40)^
			if fn != nil {
				tv_dict_add_str(d, cstring("filename"), 8, fn)
			}
		}
		i += 1
	}
}

// "getmarklist()" function.
@(export)
f_getmarklist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		get_global_marks(rawptr(rettv.vval))
		return
	}
	buf := tv_get_buf((^Typval_T)(uintptr(argvars)), 0)
	if buf == nil {
		return
	}
	get_buf_local_marks(buf, rawptr(rettv.vval))
}

// —— Batch 27q: funcs.c has() + has_wsl ——
foreign _ {
	@(link_name = "has_nvim_version")
	has_nvim_version_e :: proc "c" (version_str: cstring) -> bool ---
	@(link_name = "has_vim_patch")
	has_vim_patch_e :: proc "c" (n: C.int, major_minor_version: C.int) -> bool ---
	// ui_gui_attached now defined in ui.odin — call directly.
	@(link_name = "nlua_exec")
	nlua_exec_e :: proc "c" (str: NvimString, chunkname: cstring, args: Api_Array, mode: C.int, arena: rawptr, err: rawptr) -> Api_Object ---
	@(link_name = "strtoul")
	c_strtoul :: proc "c" (s: cstring, end: ^cstring, base: C.int) -> C.ulong ---
}

has_wsl_state_g: TriState = TriState.kNone

// WSL detection via lua uv (C-static in funcs.c).
has_wsl_o :: proc "c" () -> bool {
	context = runtime.default_context()
	if has_wsl_state_g == TriState.kNone {
		err := Api_Error{typ = -1, msg = nil}
		args := Api_Array{}
		code := cstring("return vim.uv.os_uname()['release']:lower():match('microsoft')")
		s := NvimString{data = code, size = C.size_t(libc.strlen(code))}
		o := nlua_exec_e(s, nil, args, 1, nil, rawptr(&err))
		if err.typ != -1 {
			libc.abort()
		}
		if o.t == 1 && o.data[0] != 0 {
			has_wsl_state_g = TriState.kTrue
		} else {
			has_wsl_state_g = TriState.kFalse
		}
	}
	return has_wsl_state_g == TriState.kTrue
}

// "has()" function.
@(export)
f_has :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	has_list := []cstring{
		cstring("linux"), cstring("unix"), cstring("fname_case"), cstring("acl"), cstring("autochdir"),
		cstring("arabic"), cstring("autocmd"), cstring("browsefilter"), cstring("byte_offset"),
		cstring("cindent"), cstring("cmdline_compl"), cstring("cmdline_hist"), cstring("cmdwin"),
		cstring("comments"), cstring("conceal"), cstring("cursorbind"), cstring("cursorshape"),
		cstring("dialog_con"), cstring("diff"), cstring("digraphs"), cstring("eval"),
		cstring("ex_extra"), cstring("extra_search"), cstring("file_in_path"), cstring("filterpipe"),
		cstring("find_in_path"), cstring("float"), cstring("folding"), cstring("fork"),
		cstring("gettext"), cstring("iconv"), cstring("insert_expand"), cstring("jumplist"),
		cstring("keymap"), cstring("lambda"), cstring("langmap"), cstring("libcall"),
		cstring("linebreak"), cstring("lispindent"), cstring("listcmds"), cstring("localmap"),
		cstring("menu"), cstring("mksession"), cstring("modify_fname"), cstring("mouse"),
		cstring("multi_byte"), cstring("multi_lang"), cstring("nanotime"), cstring("num64"),
		cstring("packages"), cstring("path_extra"), cstring("persistent_undo"), cstring("profile"),
		cstring("reltime"), cstring("quickfix"), cstring("rightleft"), cstring("scrollbind"),
		cstring("showcmd"), cstring("cmdline_info"), cstring("shada"), cstring("signs"),
		cstring("smartindent"), cstring("startuptime"), cstring("statusline"), cstring("spell"),
		cstring("syntax"), cstring("tablineat"), cstring("tag_binary"), cstring("termguicolors"),
		cstring("terminfo"), cstring("termresponse"), cstring("textobjects"), cstring("timers"),
		cstring("title"), cstring("user-commands"), cstring("user_commands"), cstring("vartabs"),
		cstring("vertsplit"), cstring("vimscript-1"), cstring("virtualedit"), cstring("visual"),
		cstring("visualextra"), cstring("vreplace"), cstring("wildignore"), cstring("wildmenu"),
		cstring("windows"), cstring("winaltkeys"), cstring("writebackup"), cstring("xattr"), cstring("nvim"),
	}
	x := false
	n := false
	name := tv_get_string((^Typval_T)(uintptr(argvars)))
	nm := ([^]u8)(name)
	if strncasecmp_o(name, cstring("patch"), 5) == 0 {
		x = true
		if nm[5] == '-' && libc.strlen(name) >= 11 && nm[6] >= '1' && nm[6] <= '9' {
			end: cstring = nil
			major := C.int(c_strtoul(transmute(cstring)(rawptr(uintptr(rawptr(name)) + 6)), &end, 10))
			en := ([^]u8)(end)
			if en[0] == '.' && en[1] >= '0' && en[1] <= '9' && en[2] == '.' && en[3] >= '0' && en[3] <= '9' {
				minor := C.int(libc.atoi(transmute(cstring)(rawptr(uintptr(rawptr(end)) + 1))))
				n = has_vim_patch_e(C.int(libc.atoi(transmute(cstring)(rawptr(uintptr(rawptr(end)) + 3)))), major * 100 + minor)
			}
		} else if nm[5] >= '0' && nm[5] <= '9' {
			n = has_vim_patch_e(C.int(libc.atoi(transmute(cstring)(rawptr(uintptr(rawptr(name)) + 5)))), 0)
		}
	} else if strncasecmp_o(name, cstring("nvim-"), 5) == 0 {
		x = true
		n = has_nvim_version_e(transmute(cstring)(rawptr(uintptr(rawptr(name)) + 5)))
	} else if _strcasecmp(name, cstring("vim_starting")) == 0 {
		x = true
		n = starting != 0
	} else if _strcasecmp(name, cstring("ttyin")) == 0 {
		x = true
		n = stdin_isatty
	} else if _strcasecmp(name, cstring("ttyout")) == 0 {
		x = true
		n = stdout_isatty
	} else if _strcasecmp(name, cstring("multi_byte_encoding")) == 0 {
		x = true
		n = true
	} else if _strcasecmp(name, cstring("gui_running")) == 0 {
		x = true
		n = ui_gui_attached()
	} else if _strcasecmp(name, cstring("syntax_items")) == 0 {
		x = true
		n = syntax_present_r(curwin)
	} else if _strcasecmp(name, cstring("wsl")) == 0 {
		x = true
		n = has_wsl_o()
	}
	if !x {
		for h in has_list {
			if _strcasecmp(name, h) == 0 {
				x = true
				n = true
				break
			}
		}
	}
	if !x {
		save_shell_error := get_vim_var_nr(VV_SHELL_ERROR)
		if _strcasecmp(name, cstring("clipboard_working")) == 0 {
			n = eval_has_provider(cstring("clipboard"), true)
		} else if _strcasecmp(name, cstring("unnamedplus")) == 0 {
			n = eval_has_provider(cstring("clipboard"), true)
		} else if _strcasecmp(name, cstring("pythonx")) == 0 {
			n = eval_has_provider(cstring("python3"), true)
		} else if eval_has_provider(name, true) {
			n = true
		}
		set_vim_var_nr(VV_SHELL_ERROR, save_shell_error)
	}
	if n {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// —— Batch 27n: funcs.c execute/garbagecollect/eval/debugbreak ——
foreign _ {
	@(link_name = "garbage_collect_at_exit")
	garbage_collect_at_exit_g: bool
	@(link_name = "need_clr_eos")
	need_clr_eos_g: bool
}

EINVEXPR2_S :: "E15: Invalid expression: \"%s\""

// "execute(command)" function.
@(export)
f_execute :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	execute_common(argvars, rettv, 0)
}

// "garbagecollect()" function.
@(export)
f_garbagecollect :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	want_garbage_collect_g = true
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN && tv_get_number((^Typval_T)(uintptr(argvars))) == 1 {
		garbage_collect_at_exit_g = true
	}
}

// "eval()" function.
@(export)
f_eval :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	s := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if s != nil {
		s = skipwhite(s)
	}
	expr_start := s
	evarg := Evalarg_T{eval_flags = 1}
	if s == nil || eval1(&s, rettv, rawptr(&evarg)) == FAIL_E {
		if expr_start != nil && !aborting_r() {
			semsg(cstring(EINVEXPR2_S), expr_start)
		}
		need_clr_eos_g = false
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(0))
	} else if ([^]u8)(s)[0] != 0 {
		semsg(cstring(E488_S), s)
	}
}

// "debugbreak()" function.
@(export)
f_debugbreak :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(FAIL_E))
	pid := C.int(tv_get_number((^Typval_T)(uintptr(argvars))))
	if pid == 0 {
		emsg(e_invarg)
		return
	}
	uv_kill(pid, SIGINT)
}

// —— Batch 27o: funcs.c dictwatcher pair ——
E46_READONLY_S :: "E46: Cannot change read-only variable \"%.*s\""
E_NOWATCHER_S :: "Couldn't find a watcher matching key and callback"

// "dictwatcheradd(dict, key, funcref)" function.
@(export)
f_dictwatcheradd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_DICT {
		semsg(e_invarg2, cstring("dict"))
		return
	} else if rawptr(([^]Typval_T)(argvars)[0].vval) == nil {
		arg_errmsg := cstring("dictwatcheradd() argument")
		semsg(cstring(E46_READONLY_S), C.int(libc.strlen(arg_errmsg)), arg_errmsg)
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type != VAR_STRING && ([^]Typval_T)(argvars)[1].v_type != VAR_NUMBER {
		semsg(e_invarg2, cstring("key"))
		return
	}
	key_pattern := tv_get_string_chk((^Typval_T)(uintptr(argvars) + 16))
	if key_pattern == nil {
		return
	}
	callback: Callback_E
	if !callback_from_typval(&callback, (^Typval_T)(uintptr(argvars) + 32)) {
		semsg(e_invarg2, cstring("funcref"))
		return
	}
	tv_dict_watcher_add(rawptr(([^]Typval_T)(argvars)[0].vval), key_pattern, C.size_t(libc.strlen(key_pattern)), callback)
}

// "dictwatcherdel(dict, key, funcref)" function.
@(export)
f_dictwatcherdel :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_DICT {
		semsg(e_invarg2, cstring("dict"))
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_FUNC && ([^]Typval_T)(argvars)[2].v_type != VAR_STRING {
		semsg(e_invarg2, cstring("funcref"))
		return
	}
	key_pattern := tv_get_string_chk((^Typval_T)(uintptr(argvars) + 16))
	if key_pattern == nil {
		return
	}
	callback: Callback_E
	if !callback_from_typval(&callback, (^Typval_T)(uintptr(argvars) + 32)) {
		return
	}
	if !tv_dict_watcher_remove(rawptr(([^]Typval_T)(argvars)[0].vval), key_pattern, C.size_t(libc.strlen(key_pattern)), callback) {
		emsg(cstring(E_NOWATCHER_S))
	}
	callback_free(&callback)
}

// —— Batch 27p: funcs.c exists() ——
foreign _ {
	@(link_name = "nlua_func_exists")
	nlua_func_exists_e :: proc "c" (lua_funcname: cstring) -> bool ---
	@(link_name = "cmd_exists")
	cmd_exists_e :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "autocmd_supported")
	autocmd_supported_e :: proc "c" (event: cstring) -> bool ---
	@(link_name = "au_exists")
	au_exists_e :: proc "c" (arg: cstring) -> bool ---
}

// "exists()" function.
@(export)
f_exists :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n: C.longlong = 0
	p := tv_get_string((^Typval_T)(uintptr(argvars)))
	if ([^]u8)(p)[0] == '$' {
		if os_env_exists(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1)), false) {
			n = 1
		} else {
			exp := expand_env_save(transmute(cstring)(p))
			if exp != nil && ([^]u8)(exp)[0] != '$' {
				n = 1
			}
			xfree(rawptr(exp))
		}
	} else if ([^]u8)(p)[0] == '&' || ([^]u8)(p)[0] == '+' {
		pc := p
		if eval_option(&pc, nil, true) == OK_E {
			n = 1
		}
		if ([^]u8)(skipwhite(pc))[0] != 0 {
			n = 0
		}
	} else if ([^]u8)(p)[0] == '*' {
		if strnequal(p, cstring("*v:lua."), 7) {
			if nlua_func_exists_e(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 7))) {
				n = 1
			}
		} else if function_exists(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1)), false) {
			n = 1
		}
	} else if ([^]u8)(p)[0] == ':' {
		n = C.longlong(cmd_exists_e(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1))))
	} else if ([^]u8)(p)[0] == '#' {
		if ([^]u8)(p)[1] == '#' {
			if autocmd_supported_e(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 2))) {
				n = 1
			}
		} else if au_exists_e(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1))) {
			n = 1
		}
	} else if var_exists(p) {
		n = 1
	}
	rettv.vval = transmute(rawptr)(n)
}

// —— Batch 27v: funcs.c foreground/tagstack/menu_get ——
foreign _ {
	@(link_name = "get_tagstack")
	get_tagstack_e :: proc "c" (wp: rawptr, retdict: rawptr) ---
	@(link_name = "menu_get")
	menu_get_e :: proc "c" (path_name: cstring, modes: C.int, list: rawptr) -> bool ---
	@(link_name = "get_menu_cmd_modes")
	get_menu_cmd_modes_e :: proc "c" (cmd: cstring, forceit: bool, noremap: ^C.int, unmenu: ^bool) -> C.int ---
}

MENU_ALL_MODES_O :: 127

// "foreground()" function (empty on Unix).
@(export)
f_foreground :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
}

// "gettagstack()" function.
@(export)
f_gettagstack :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	wp := curwin
	tv_dict_alloc_ret(rettv)
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		wp = find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
		if wp == nil {
			return
		}
	}
	get_tagstack_e(wp, rawptr(rettv.vval))
}

// "menu_get(path [, modes])" function.
@(export)
f_menu_get :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	modes: C.int = MENU_ALL_MODES_O
	if ([^]Typval_T)(argvars)[1].v_type == VAR_STRING {
		modes = get_menu_cmd_modes_e(tv_get_string((^Typval_T)(uintptr(argvars) + 16)), false, nil, nil)
	}
	menu_get_e(transmute(cstring)(tv_get_string((^Typval_T)(uintptr(argvars)))), modes, rawptr(rettv.vval))
}

// —— Batch 27w: funcs.c feedkeys + eventhandler ——
foreign _ {
	@(link_name = "nvim_feedkeys")
	nvim_feedkeys_e :: proc "c" (keys: NvimString, mode: NvimString, escape_ks: bool) ---
}

// "feedkeys()" function.
@(export)
f_feedkeys :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	keys := tv_get_string((^Typval_T)(uintptr(argvars)))
	nbuf: [65]u8
	flags: cstring = nil
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		flags = tv_get_string_buf((^Typval_T)(uintptr(argvars) + 16), &nbuf[0])
	}
	ks := NvimString{data = keys, size = 0}
	if keys != nil {
		ks.size = C.size_t(libc.strlen(keys))
	}
	md := NvimString{data = flags, size = 0}
	if flags != nil {
		md.size = C.size_t(libc.strlen(flags))
	}
	nvim_feedkeys_e(ks, md, true)
}

// "eventhandler()" function.
@(export)
f_eventhandler :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(vgetc_busy_g))
}

// —— Batch 27x: funcs.c confirm() ——
foreign _ {
	@(link_name = "do_dialog")
	do_dialog_e :: proc "c" (type: C.int, title: cstring, message: cstring, buttons: cstring, dfltbutton: C.int, textfield: cstring, ex_cmd: C.int) -> C.int ---
}

VIM_GENERIC_O :: 0
VIM_ERROR_O :: 1
VIM_WARNING_O :: 2
VIM_INFO_O :: 3

// "confirm(message, buttons[, default [, type]])" function.
@(export)
f_confirm :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [65]u8
	buf2: [65]u8
	buttons: cstring = nil
	def: C.int = 1
	type: C.int = VIM_GENERIC_O
	error := false
	message := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if message == nil {
		error = true
	}
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		buttons = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &buf[0])
		if buttons == nil {
			error = true
		}
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			def = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error))
			if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
				typestr := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 48), &buf2[0])
				if typestr == nil {
					error = true
				} else {
					ch := ([^]u8)(typestr)[0]
					if ch >= 'a' && ch <= 'z' {
						ch -= ('a' - 'A')
					}
					switch ch {
					case 'E':
						type = VIM_ERROR_O
					case 'Q':
						type = VIM_QUESTION_O
					case 'I':
						type = VIM_INFO_O
					case 'W':
						type = VIM_WARNING_O
					case 'G':
						type = VIM_GENERIC_O
					}
				}
			}
		}
	}
	if buttons == nil || ([^]u8)(buttons)[0] == 0 {
		buttons = cstring("&Ok")
	}
	if !error {
		rettv.vval = transmute(rawptr)(C.longlong(do_dialog_e(type, nil, message, buttons, def, nil, 0)))
	}
}

// —— Batch 27y: funcs.c indexof cluster ——

// Evaluate expr with v:key/v:val (C-static).
indexof_eval_expr_o :: proc "c" (expr: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	argv: [3]Typval_T
	argv[0] = (get_vim_var_tv(VV_KEY_O))^
	argv[1] = (get_vim_var_tv(VV_VAL_O))^
	newtv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	if eval_expr_typval(expr, false, &argv[0], 2, &newtv) == FAIL_E {
		return 0
	}
	error := false
	found := tv_get_bool_chk(&newtv, &error)
	tv_clear(&newtv)
	if error {
		return 0
	}
	return found
}

// indexof() over a Blob (C-static).
indexof_blob_o :: proc "c" (b: rawptr, startidx_in: C.longlong, expr: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	startidx := startidx_in
	if b == nil {
		return -1
	}
	if startidx < 0 {
		startidx = C.longlong(tv_blob_len_o(b)) + startidx
		if startidx < 0 {
			startidx = 0
		}
	}
	set_vim_var_type(VV_KEY_O, VAR_NUMBER)
	set_vim_var_type(VV_VAL_O, VAR_NUMBER)
	called_start := called_emsg
	idx := startidx
	for idx < C.longlong(tv_blob_len_o(b)) {
		set_vim_var_nr(VV_KEY_O, i64(idx))
		set_vim_var_nr(VV_VAL_O, i64(tv_blob_get_o(b, C.int(idx))))
		if indexof_eval_expr_o(expr) != 0 {
			return idx
		}
		if called_emsg != called_start {
			return -1
		}
		idx += 1
	}
	return -1
}

// indexof() over a List (C-static).
indexof_list_o :: proc "c" (l: rawptr, startidx: C.longlong, expr: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	if l == nil {
		return -1
	}
	item: rawptr = nil
	idx: C.longlong = 0
	if startidx == 0 {
		item = tv_list_first_o(l)
	} else {
		idx = C.longlong(tv_list_uidx_o(l, C.int(startidx)))
		if idx == -1 {
			item = nil
		} else {
			item = tv_list_find(l, C.int(idx))
			if item == nil {
				libc.abort()
			}
		}
	}
	set_vim_var_type(VV_KEY_O, VAR_NUMBER)
	called_start := called_emsg
	for item != nil {
		set_vim_var_nr(VV_KEY_O, i64(idx))
		tv_copy((^Typval_T)(uintptr(item) + 16), get_vim_var_tv(VV_VAL_O))
		found := indexof_eval_expr_o(expr)
		tv_clear(get_vim_var_tv(VV_VAL_O))
		if found != 0 {
			return idx
		}
		if called_emsg != called_start {
			return -1
		}
		item = (^rawptr)(uintptr(item))^
		idx += 1
	}
	return -1
}

// "indexof()" function.
@(export)
f_indexof :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if tv_check_for_list_or_blob_arg(argvars, 0) == FAIL_E || tv_check_for_string_or_func_arg(argvars, 1) == FAIL_E || tv_check_for_opt_dict_arg(argvars, 2) == FAIL_E {
		return
	}
	if (([^]Typval_T)(argvars)[1].v_type == VAR_STRING && (rawptr(([^]Typval_T)(argvars)[1].vval) == nil || ([^]u8)(([^]Typval_T)(argvars)[1].vval)[0] == 0)) || (([^]Typval_T)(argvars)[1].v_type == VAR_FUNC && rawptr(([^]Typval_T)(argvars)[1].vval) == nil) {
		return
	}
	startidx: C.longlong = 0
	if ([^]Typval_T)(argvars)[2].v_type == VAR_DICT {
		startidx = tv_dict_get_number_def(rawptr(([^]Typval_T)(argvars)[2].vval), cstring("startidx"), 0)
	}
	save_val := Typval_T{}
	save_key := Typval_T{}
	prepare_vimvar(VV_VAL_O, &save_val)
	prepare_vimvar(VV_KEY_O, &save_key)
	save_did_emsg := did_emsg_flag
	did_emsg_flag = 0
	if ([^]Typval_T)(argvars)[0].v_type == VAR_BLOB {
		rettv.vval = transmute(rawptr)(indexof_blob_o(rawptr(([^]Typval_T)(argvars)[0].vval), startidx, (^Typval_T)(uintptr(argvars) + 16)))
	} else {
		rettv.vval = transmute(rawptr)(indexof_list_o(rawptr(([^]Typval_T)(argvars)[0].vval), startidx, (^Typval_T)(uintptr(argvars) + 16)))
	}
	restore_vimvar(VV_KEY_O, &save_key)
	restore_vimvar(VV_VAL_O, &save_val)
	did_emsg_flag |= save_did_emsg
}

// —— Batch 27z: funcs.c call() ——
foreign _ {
	@(link_name = "nlua_is_table_from_lua")
	nlua_is_table_from_lua_e :: proc "c" (arg: ^Typval_T) -> bool ---
	@(link_name = "nlua_register_table_as_callable")
	nlua_register_table_as_callable_e :: proc "c" (arg: ^Typval_T) -> cstring ---
}

E117_S :: "E117: Unknown function: %s"

// "call()" function.
@(export)
f_call :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_list_arg(argvars, 1) == FAIL_E {
		return
	}
	if rawptr(([^]Typval_T)(argvars)[1].vval) == nil {
		return
	}
	owned := false
	func: cstring = nil
	partial: rawptr = nil
	if ([^]Typval_T)(argvars)[0].v_type == VAR_FUNC {
		func = transmute(cstring)(([^]Typval_T)(argvars)[0].vval)
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_PARTIAL {
		partial = rawptr(([^]Typval_T)(argvars)[0].vval)
		func = partial_name(partial)
	} else if nlua_is_table_from_lua_e((^Typval_T)(uintptr(argvars))) {
		func = nlua_register_table_as_callable_e((^Typval_T)(uintptr(argvars)))
		owned = true
	} else {
		func = tv_get_string((^Typval_T)(uintptr(argvars)))
	}
	if func == nil || ([^]u8)(func)[0] == 0 {
		return
	}
	tofree: cstring = nil
	if ([^]Typval_T)(argvars)[0].v_type == VAR_STRING {
		p := func
		tofree = trans_function_name(&p, false, TFN_INT_O | TFN_QUIET_O, nil, nil)
		if tofree == nil {
			emsg_funcname(cstring(E117_S), func)
			return
		}
		func = tofree
	}
	selfdict: rawptr = nil
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		if tv_check_for_dict_arg(argvars, 2) == FAIL_E {
			if owned {
				func_unref(func)
			}
			xfree(rawptr(tofree))
			return
		}
		selfdict = rawptr(([^]Typval_T)(argvars)[2].vval)
	}
	func_call(func, rawptr((^Typval_T)(uintptr(argvars) + 16)), partial, selfdict, rettv)
	if owned {
		func_unref(func)
	}
	xfree(rawptr(tofree))
}

// —— Batch 27aa: funcs.c mode/pumvisible/nonblank ——
foreign _ {
	@(link_name = "pum_visible")
	pum_visible_e :: proc "c" () -> bool ---
}

// Number-or-nonempty-string test (C-static in funcs.c).
non_zero_arg_o :: proc "c" (argvars: ^Typval_T) -> bool {
	context = runtime.default_context()
	av0 := ([^]Typval_T)(argvars)[0]
	if av0.v_type == VAR_NUMBER && transmute(C.longlong)(av0.vval) != 0 {
		return true
	}
	if av0.v_type == VAR_BOOL && C.int(transmute(C.longlong)(av0.vval)) == kBoolVarTrue {
		return true
	}
	if av0.v_type == VAR_STRING && rawptr(av0.vval) != nil && ([^]u8)(av0.vval)[0] != 0 {
		return true
	}
	return false
}

// "mode()" function.
@(export)
f_mode :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [4]u8
	get_mode(&buf[0])
	if !non_zero_arg_o(argvars) {
		buf[1] = 0
	}
	rettv.vval = transmute(rawptr)(xstrdup_o(&buf[0]))
	rettv.v_type = VAR_STRING
}

// "pumvisible()" function.
@(export)
f_pumvisible :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if pum_visible_e() {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	}
}

// "nextnonblank()" function.
@(export)
f_nextnonblank :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	linecount := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	for {
		if lnum < 0 || lnum > linecount {
			lnum = 0
			break
		}
		if ([^]u8)(skipwhite(transmute(cstring)(ml_get(lnum))))[0] != 0 {
			break
		}
		lnum += 1
	}
	rettv.vval = transmute(rawptr)(C.longlong(lnum))
}

// "prevnonblank()" function.
@(export)
f_prevnonblank :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	linecount := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	if lnum < 1 || lnum > linecount {
		lnum = 0
	} else {
		for lnum >= 1 && ([^]u8)(skipwhite(transmute(cstring)(ml_get(lnum))))[0] == 0 {
			lnum -= 1
		}
	}
	rettv.vval = transmute(rawptr)(C.longlong(lnum))
}

// —— Batch 27ab: funcs.c max/min ——
VARNUMBER_MIN_O :: -9223372036854775808

// Shared max()/min() engine (C-static in funcs.c).
max_min_o :: proc "c" (tv: ^Typval_T, rettv: ^Typval_T, domax: bool) {
	context = runtime.default_context()
	error := false
	rettv.vval = transmute(rawptr)(C.longlong(0))
	n: C.longlong = 0
	if domax {
		n = VARNUMBER_MIN_O
	} else {
		n = VARNUMBER_MAX_O
	}
	if tv.v_type == VAR_LIST {
		l := rawptr(tv.vval)
		if tv_list_len_o(l) == 0 {
			return
		}
		item := tv_list_first_o(l)
		for item != nil {
			i := tv_get_number_chk((^Typval_T)(uintptr(item) + 16), &error)
			if error {
				return
			}
			if (domax && i > n) || (!domax && i < n) {
				n = i
			}
			item = (^rawptr)(uintptr(item))^
		}
	} else if tv.v_type == VAR_DICT {
		d := rawptr(tv.vval)
		if tv_dict_len_o(d) == 0 {
			return
		}
		todo := (^C.size_t)(uintptr(d) + 24)^
		hi := uintptr((^rawptr)(rawptr(uintptr(d) + 48))^)
		for todo > 0 {
			key := ([^]rawptr)(hi)[1]
			hi += 16
			if key == nil || key == rawptr(&hash_removed) {
				continue
			}
			todo -= 1
			i := tv_get_number_chk((^Typval_T)(uintptr(key) - 17), &error)
			if error {
				return
			}
			if (domax && i > n) || (!domax && i < n) {
				n = i
			}
		}
	} else {
		if domax {
			semsg(cstring(E_LISTDICTARG_S), cstring("max()"))
		} else {
			semsg(cstring(E_LISTDICTARG_S), cstring("min()"))
		}
		return
	}
	rettv.vval = transmute(rawptr)(n)
}

// "max()" function.
@(export)
f_max :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	max_min_o((^Typval_T)(uintptr(argvars)), rettv, true)
}

// "min()" function.
@(export)
f_min :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	max_min_o((^Typval_T)(uintptr(argvars)), rettv, false)
}

// —— Batch 27ac: funcs.c state() ——
foreign _ {
	@(link_name = "stuff_empty")
	stuff_empty_e :: proc "c" () -> bool ---
	@(link_name = "using_script")
	using_script_e :: proc "c" () -> C.int ---
	@(link_name = "op_pending")
	op_pending_e :: proc "c" () -> bool ---
}

// Conditionally append a state char (C-static in funcs.c).
may_add_state_char_o :: proc "c" (gap: ^Garray, include: cstring, ch: u8) {
	context = runtime.default_context()
	if include == nil || _vim_strchr(include, C.int(ch)) != nil {
		ga_append(gap, ch)
	}
}

// "state()" function.
@(export)
f_state :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	ga := Garray{}
	ga_init(&ga, 1, 20)
	include: cstring = nil
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		include = tv_get_string((^Typval_T)(uintptr(argvars)))
	}
	if !(stuff_empty_e() && typebuf.tb_len == 0 && using_script_e() == 0) {
		may_add_state_char_o(&ga, include, 'm')
	}
	if op_pending_e() {
		may_add_state_char_o(&ga, include, 'o')
	}
	if autocmd_busy_g {
		may_add_state_char_o(&ga, include, 'x')
	}
	if ins_compl_active() {
		may_add_state_char_o(&ga, include, 'a')
	}
	if !get_was_safe_state() {
		may_add_state_char_o(&ga, include, 'S')
	}
	i: C.int = 0
	for i < get_callback_depth() && i < 3 {
		may_add_state_char_o(&ga, include, 'c')
		i += 1
	}
	if msg_scrolled > 0 {
		may_add_state_char_o(&ga, include, 's')
	}
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(ga.ga_data)
}

// —— Batch 27ad: funcs.c rand/srand ——
foreign _ {
	@(link_name = "uv_random")
	uv_random_e :: proc "c" (loop: rawptr, req: rawptr, buf: rawptr, buflen: C.size_t, flags: C.uint, cb: rawptr) -> C.int ---
}

rand_gx_g: u32 = 0
rand_gy_g: u32 = 0
rand_gz_g: u32 = 0
rand_gw_g: u32 = 0
rand_initialized_g: bool = false

// splitmix32 (static inline in funcs.c).
splitmix32_o :: proc "c" (x: ^u32) -> u32 {
	context = runtime.default_context()
	x^ += 0x9e3779b9
	z := x^
	z = (z ~ (z >> 16)) * 0x85ebca6b
	z = (z ~ (z >> 13)) * 0xc2b2ae35
	return z ~ (z >> 16)
}

// xoshiro128** (static inline in funcs.c).
shuffle_xoshiro128starstar_o :: proc "c" (x, y, z, w: ^u32) -> u32 {
	context = runtime.default_context()
	rotl := #force_inline proc "c" (v: u32, k: u32) -> u32 {
		return (v << k) | (v >> (32 - k))
	}
	result := rotl(y^ * 5, 7) * 9
	t := y^ << 9
	z^ ~= x^
	w^ ~= y^
	y^ ~= z^
	x^ ~= w^
	z^ ~= t
	w^ = rotl(w^, 11)
	return result
}

// Seed init with fallback (static in funcs.c).
init_srand_o :: proc "c" (x: ^u32) {
	context = runtime.default_context()
	buf: [4]u8
	if uv_random_e(nil, nil, rawptr(&buf[0]), 4, 0, nil) == 0 {
		x^ = (^u32)(rawptr(&buf[0]))^
		return
	}
	x^ = u32(os_hrtime()) ~ u32(os_get_pid())
}

// "rand()" function.
@(export)
f_rand :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	result: u32 = 0
	ok := false
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		if !rand_initialized_g {
			x: u32 = 0
			init_srand_o(&x)
			rand_gx_g = splitmix32_o(&x)
			rand_gy_g = splitmix32_o(&x)
			rand_gz_g = splitmix32_o(&x)
			rand_gw_g = splitmix32_o(&x)
			rand_initialized_g = true
		}
		result = shuffle_xoshiro128starstar_o(&rand_gx_g, &rand_gy_g, &rand_gz_g, &rand_gw_g)
		ok = true
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		l := rawptr(([^]Typval_T)(argvars)[0].vval)
		if tv_list_len_o(l) == 4 {
			tvx := (^Typval_T)(uintptr(tv_list_find(l, 0)) + 16)
			tvy := (^Typval_T)(uintptr(tv_list_find(l, 1)) + 16)
			tvz := (^Typval_T)(uintptr(tv_list_find(l, 2)) + 16)
			tvw := (^Typval_T)(uintptr(tv_list_find(l, 3)) + 16)
			if tvx.v_type == VAR_NUMBER && tvy.v_type == VAR_NUMBER && tvz.v_type == VAR_NUMBER && tvw.v_type == VAR_NUMBER {
				x := u32(transmute(C.longlong)(tvx.vval))
				y := u32(transmute(C.longlong)(tvy.vval))
				z := u32(transmute(C.longlong)(tvz.vval))
				w := u32(transmute(C.longlong)(tvw.vval))
				result = shuffle_xoshiro128starstar_o(&x, &y, &z, &w)
				tvx.vval = transmute(rawptr)(C.longlong(x))
				tvy.vval = transmute(rawptr)(C.longlong(y))
				tvz.vval = transmute(rawptr)(C.longlong(z))
				tvw.vval = transmute(rawptr)(C.longlong(w))
				ok = true
			}
		}
	}
	if ok {
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(result))
	} else {
		semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars))))
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	}
}

// "srand()" function.
@(export)
f_srand :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	x: u32 = 0
	tv_list_alloc_ret(transmute(^Typval)(rettv), 4)
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		init_srand_o(&x)
	} else {
		error := false
		x = u32(tv_get_number_chk((^Typval_T)(uintptr(argvars)), &error))
		if error {
			return
		}
	}
	tv_list_append_number(rawptr(rettv.vval), C.longlong(splitmix32_o(&x)))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(splitmix32_o(&x)))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(splitmix32_o(&x)))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(splitmix32_o(&x)))
}

// —— Batch 27am: funcs.c api_info + chanclose ——
foreign _ {
	@(link_name = "api_metadata")
	api_metadata_e :: proc "c" () -> Api_Object ---
	@(link_name = "object_to_vim")
	object_to_vim_e :: proc "c" (obj: Api_Object, tv: ^Typval_T, err: rawptr) ---
}

KCHPART_STDIN_O :: 0
KCHPART_STDOUT_O :: 1
KCHPART_STDERR_O :: 2
KCHPART_RPC_O :: 3
KCHPART_ALL_O :: 4
E_BADSTREAM_S :: "Invalid channel stream \"%s\""

// "api_info()" function.
@(export)
f_api_info :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	object_to_vim_e(api_metadata_e(), rettv, nil)
}

// "chanclose(id[, stream])" function.
@(export)
f_chanclose :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER || (([^]Typval_T)(argvars)[1].v_type != VAR_STRING && ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN) {
		emsg(e_invarg)
		return
	}
	part: C.int = KCHPART_ALL_O
	if ([^]Typval_T)(argvars)[1].v_type == VAR_STRING {
		stream := tv_get_string((^Typval_T)(uintptr(argvars) + 16))
		if libc.strcmp(stream, cstring("stdin")) == 0 {
			part = KCHPART_STDIN_O
		} else if libc.strcmp(stream, cstring("stdout")) == 0 {
			part = KCHPART_STDOUT_O
		} else if libc.strcmp(stream, cstring("stderr")) == 0 {
			part = KCHPART_STDERR_O
		} else if libc.strcmp(stream, cstring("rpc")) == 0 {
			part = KCHPART_RPC_O
		} else {
			semsg(cstring("Invalid channel stream \"%s\""), stream)
			return
		}
	}
	err: cstring = nil
	if channel_close(u64(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval)), part, &err) {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	} else {
		emsg(err)
	}
}

// —— Batch 27al: funcs.c match engine ——
foreign _ {
	@(link_name = "vim_regexec_nl")
	vim_regexec_nl_e :: proc "c" (rmp: ^Regmatch_T, line: cstring, col: C.int) -> bool ---
}

SOMEMATCH_O :: 0
RE_STRING_O :: 2
SOMEMATCHEND_O :: 1
SOMEMATCHLIST_O :: 2
SOMEMATCHSTR_O :: 3
SOMEMATCHSTRPOS_O :: 4

// Shared match()/matchend()/matchlist()/matchstr()/matchstrpos() engine (C-static).
find_some_match_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, type: C.int) {
	context = runtime.default_context()
	str: [^]u8 = nil
	length: i64 = 0
	expr: [^]u8 = nil
	regmatch := Regmatch_T{}
	start: i64 = 0
	nth: i64 = 1
	startcol: C.int = 0
	match := false
	l: rawptr = nil
	idx: C.int = 0
	tofree: ^u8 = nil
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	done := false
	if type == SOMEMATCHLIST_O {
		tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	} else if type == SOMEMATCHSTRPOS_O {
		tv_list_alloc_ret(transmute(^Typval)(rettv), 4)
		tv_list_append_string(rawptr(rettv.vval), nil, 0)
		tv_list_append_number(rawptr(rettv.vval), C.longlong(-1))
		tv_list_append_number(rawptr(rettv.vval), C.longlong(-1))
		tv_list_append_number(rawptr(rettv.vval), C.longlong(-1))
	} else if type == SOMEMATCHSTR_O {
		rettv.v_type = VAR_STRING
		rettv.vval = transmute(rawptr)(cstring(nil))
	}
	li: rawptr = nil
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		l = rawptr(([^]Typval_T)(argvars)[0].vval)
		if l == nil {
			done = true
		} else {
			li = tv_list_first_o(l)
		}
	} else {
		expr = transmute([^]u8)(tv_get_string((^Typval_T)(uintptr(argvars))))
		str = expr
		length = i64(libc.strlen(transmute(cstring)(str)))
	}
	patbuf: [65]u8
	pat: cstring = nil
	if !done {
		pat = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
		if pat == nil {
			done = true
		}
	}
	if !done && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		error := false
		start = i64(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error))
		if error {
			done = true
		} else {
			if l != nil {
				idx = tv_list_uidx_o(l, C.int(start))
				if idx == -1 {
					done = true
				} else {
					li = tv_list_find(l, idx)
				}
			} else {
				if start < 0 {
					start = 0
				}
				if start > length {
					done = true
				} else {
					if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
						startcol = C.int(start)
					} else {
						str = ([^]u8)(uintptr(str) + uintptr(start))
						length -= start
					}
				}
			}
			if !done && ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
				nth = i64(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 48), &error))
			}
			if error {
				done = true
			}
		}
	}
	if !done {
		regmatch.regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O)
		if regmatch.regprog != nil {
			regmatch.rm_ic = p_ic
			for {
				if l != nil {
					if li == nil {
						match = false
						break
					}
					xfree(rawptr(tofree))
					tofree = encode_tv2echo((^Typval_T)(uintptr(li) + 16), nil)
					expr = transmute([^]u8)(tofree)
					str = expr
					if str == nil {
						break
					}
				}
				match = vim_regexec_nl_e(&regmatch, transmute(cstring)(str), startcol)
				if match {
					nth -= 1
					if nth <= 0 {
						break
					}
				}
				if l == nil && !match {
					break
				}
				if l != nil {
					li = (^rawptr)(uintptr(li))^
					idx += 1
				} else {
					startcol = C.int(uintptr(regmatch.startp[0]) + uintptr(utfc_ptr2len(transmute(cstring)(regmatch.startp[0]))) - uintptr(str))
					if C.longlong(startcol) > length || uintptr(str) + uintptr(startcol) <= uintptr(regmatch.startp[0]) {
						match = false
						break
					}
				}
			}
		}
		if match {
			if type == SOMEMATCHSTRPOS_O {
				ret_l := rawptr(rettv.vval)
				li1 := tv_list_first_o(ret_l)
				li2 := (^rawptr)(uintptr(li1))^
				li3 := (^rawptr)(uintptr(li2))^
				li4 := (^rawptr)(uintptr(li3))^
				tv1 := (^Typval_T)(uintptr(li1) + 16)
				xfree(rawptr(tv1.vval))
				rd := uintptr(regmatch.endp[0]) - uintptr(regmatch.startp[0])
				tv1.vval = transmute(rawptr)(xmemdupz_o2(regmatch.startp[0], C.size_t(rd)))
				(^Typval_T)(uintptr(li3) + 16).vval = transmute(rawptr)(C.longlong(C.longlong(uintptr(regmatch.startp[0]) - uintptr(expr))))
				(^Typval_T)(uintptr(li4) + 16).vval = transmute(rawptr)(C.longlong(C.longlong(uintptr(regmatch.endp[0]) - uintptr(expr))))
				if l != nil {
					(^Typval_T)(uintptr(li2) + 16).vval = transmute(rawptr)(C.longlong(idx))
				}
			} else if type == SOMEMATCHLIST_O {
				i: C.int = 0
				for i < NSUBEXP {
					if regmatch.endp[i] == nil {
						tv_list_append_string(rawptr(rettv.vval), nil, 0)
					} else {
						tv_list_append_string(rawptr(rettv.vval), regmatch.startp[i], C.ssize_t(uintptr(regmatch.endp[i]) - uintptr(regmatch.startp[i])))
					}
					i += 1
				}
			} else if type == SOMEMATCHSTR_O {
				if l != nil {
					tv_copy((^Typval_T)(uintptr(li) + 16), rettv)
				} else {
					rettv.vval = transmute(rawptr)(xmemdupz_o2(regmatch.startp[0], C.size_t(uintptr(regmatch.endp[0]) - uintptr(regmatch.startp[0]))))
				}
			} else {
				if l != nil {
					rettv.vval = transmute(rawptr)(C.longlong(idx))
				} else {
					if type == SOMEMATCH_O {
						rettv.vval = transmute(rawptr)(C.longlong(C.longlong(uintptr(regmatch.startp[0]) - uintptr(str))))
					} else {
						rettv.vval = transmute(rawptr)(C.longlong(C.longlong(uintptr(regmatch.endp[0]) - uintptr(str))))
					}
					rettv.vval = transmute(rawptr)(C.longlong(transmute(C.longlong)(rettv.vval) + C.longlong(uintptr(str) - uintptr(expr))))
				}
			}
		}
		vim_regfree(regmatch.regprog)
	}
	if type == SOMEMATCHSTRPOS_O && l == nil && rawptr(rettv.vval) != nil {
		ret_l := rawptr(rettv.vval)
		tv_list_item_remove(ret_l, (^rawptr)(uintptr(tv_list_first_o(ret_l)))^)
	}
	xfree(rawptr(tofree))
	p_cpo = save_cpo
}

// "match()" function.
@(export)
f_match :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	find_some_match_o(argvars, rettv, SOMEMATCH_O)
}

// "matchend()" function.
@(export)
f_matchend :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	find_some_match_o(argvars, rettv, SOMEMATCHEND_O)
}

// "matchlist()" function.
@(export)
f_matchlist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	find_some_match_o(argvars, rettv, SOMEMATCHLIST_O)
}

// "matchstr()" function.
@(export)
f_matchstr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	find_some_match_o(argvars, rettv, SOMEMATCHSTR_O)
}

// "matchstrpos()" function.
@(export)
f_matchstrpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	find_some_match_o(argvars, rettv, SOMEMATCHSTRPOS_O)
}

// —— Batch 27ak: funcs.c range + getreginfo ——
foreign _ {
	@(link_name = "get_unname_register")
	get_unname_register_e :: proc "c" () -> C.int ---
}

E726_S :: "E726: Stride is zero"
E727_S :: "E727: Start past end"
DELETION_REGISTER_O :: 36
STAR_REGISTER_O :: 37
PLUS_REGISTER_O :: 38

// Register index to name (register.h static inline).
get_register_name_o :: proc "c" (num: C.int) -> C.int {
	context = runtime.default_context()
	if num == -1 {
		return '"'
	} else if num < 10 {
		return num + '0'
	} else if num == DELETION_REGISTER_O {
		return '-'
	} else if num == STAR_REGISTER_O {
		return '*'
	} else if num == PLUS_REGISTER_O {
		return '+'
	}
	return num + 'a' - 10
}

// "range()" function.
@(export)
f_range :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	end: C.longlong = 0
	stride: C.longlong = 1
	error := false
	start := tv_get_number_chk((^Typval_T)(uintptr(argvars)), &error)
	if ([^]Typval_T)(argvars)[1].v_type == VAR_UNKNOWN {
		end = start - 1
		start = 0
	} else {
		end = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error)
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			stride = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error)
		}
	}
	if error {
		return
	}
	if stride == 0 {
		emsg(cstring(E726_S))
		return
	}
	if (stride > 0 && end + 1 < start) || (stride < 0 && end - 1 > start) {
		emsg(cstring(E727_S))
		return
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), C.int((end - start) / stride))
	i := start
	for (stride > 0 && i <= end) || (stride < 0 && i >= end) {
		tv_list_append_number(rawptr(rettv.vval), i)
		i += stride
	}
}

// "getreginfo()" function.
@(export)
f_getreginfo :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	regname := getreg_get_regname_o(argvars)
	if regname == 0 {
		return
	}
	if regname == '@' {
		regname = '"'
	}
	tv_dict_alloc_ret(rettv)
	dict := rawptr(rettv.vval)
	list := get_reg_contents(regname, kGRegExprSrc | kGRegList)
	if list == nil {
		return
	}
	tv_dict_add_list(dict, cstring("regcontents"), 11, list)
	buf: [67]u8
	buflen: C.size_t = 0
	reglen: C.int = 0
	rt := get_reg_type(regname, &reglen)
	if rt == kMTLineWise {
		buf[0] = 'V'
		buf[1] = 0
		buflen = 1
	} else if rt == kMTCharWise {
		buf[0] = 'v'
		buf[1] = 0
		buflen = 1
	} else if rt == kMTBlockWise {
		n := libc.snprintf(&buf[0], 67, cstring("%c%d"), C.int(Ctrl_V), reglen + 1)
		buflen = C.size_t(n)
		if buflen > 66 {
			buflen = 66
		}
	} else {
		libc.abort()
	}
	tv_dict_add_str_len(dict, cstring("regtype"), 7, transmute(cstring)(&buf[0]), C.int(buflen))
	buf[0] = u8(get_register_name_o(get_unname_register_e()))
	buf[1] = 0
	if buf[0] == 0 {
		buflen = 0
	} else {
		buflen = 1
	}
	if regname == '"' {
		tv_dict_add_str_len(dict, cstring("points_to"), 9, transmute(cstring)(&buf[0]), C.int(buflen))
	} else {
		v: C.int = kBoolVarFalse
		if regname == C.int(buf[0]) {
			v = kBoolVarTrue
		}
		tv_dict_add_bool(dict, cstring("isunnamed"), 9, v)
	}
}

// —— Batch 27ae: funcs.c luaeval + id ——
foreign _ {
	@(link_name = "nlua_call_luaeval")
	nlua_call_luaeval_e :: proc "c" (str: NvimString, arg: ^Typval_T, ret_tv: ^Typval_T) ---
}

// "luaeval()" function.
@(export)
f_luaeval :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	str := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if str == nil {
		return
	}
	s := NvimString{data = str, size = C.size_t(libc.strlen(str))}
	nlua_call_luaeval_e(s, (^Typval_T)(uintptr(argvars) + 16), rettv)
}

// "id()" function (address identity via %p; va_list bypassed with snprintf).
@(export)
f_id :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	length := libc.snprintf(nil, 0, cstring("%p"), rawptr(argvars))
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(xmalloc(C.size_t(length) + 1))
	libc.snprintf(transmute([^]u8)(rettv.vval), C.size_t(length) + 1, cstring("%p"), rawptr(argvars))
}

// —— Batch 27af: funcs.c prompt/pum/py3eval (FFI fully rewired) ——
foreign _ {
	@(link_name = "pum_set_event_info")
	pum_set_event_info_e :: proc "c" (dict: rawptr) ---
}

// "prompt_getprompt({buffer})" function.
@(export)
f_prompt_getprompt :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	buf := tv_get_buf_from_arg((^Typval_T)(uintptr(argvars)))
	if buf == nil {
		return
	}
	if !bt_prompt(buf) {
		return
	}
	rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(buf_prompt_text_e(buf))))
}

// "prompt_getinput({buffer})" function.
@(export)
f_prompt_getinput :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	buf := tv_get_buf_from_arg((^Typval_T)(uintptr(argvars)))
	if buf == nil {
		return
	}
	if !bt_prompt(buf) {
		return
	}
	rettv.vval = transmute(rawptr)(prompt_get_input(buf))
}

// "pum_getpos()" function.
@(export)
f_pum_getpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(rettv)
	pum_set_event_info_e(rawptr(rettv.vval))
}

// "py3eval()" function.
@(export)
f_py3eval :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	script_host_eval(cstring("python3"), argvars, rettv)
}

// —— Batch 27ag: funcs.c reg_* readers ——

// Shared reg_executing/recording/recorded engine (C-static in funcs.c).
return_register_o :: proc "c" (regname: C.int, rettv: ^Typval_T) {
	context = runtime.default_context()
	buf: [2]u8
	buf[0] = u8(regname)
	buf[1] = 0
	rettv.v_type = VAR_STRING
	n: C.size_t = 0
	if buf[0] != 0 {
		n = 1
	}
	rettv.vval = transmute(rawptr)(xmemdupz_o2(&buf[0], n))
}

// "reg_executing()" function.
@(export)
f_reg_executing :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	return_register_o(reg_executing, rettv)
}

// "reg_recording()" function.
@(export)
f_reg_recording :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	return_register_o(reg_recording, rettv)
}

// "reg_recorded()" function.
@(export)
f_reg_recorded :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	return_register_o(reg_recorded, rettv)
}

// —— Batch 27ah: funcs.c reltime trio + shellescape ——
foreign _ {
	// profile_sub/msg/signed — PORTED (profile.odin).
	@(link_name = "vim_strsave_shellescape")
	vim_strsave_shellescape_e :: proc "c" (str: cstring, do_special: bool, do_newline: bool) -> ^u8 ---
}

// List-to-proftime conversion (C-static in funcs.c).
list2proftime_o :: proc "c" (arg: ^Typval_T, tm: ^proftime_T) -> C.int {
	context = runtime.default_context()
	if arg.v_type != VAR_LIST || tv_list_len_o(rawptr(arg.vval)) != 2 {
		return FAIL_E
	}
	error := false
	n1 := tv_list_find_nr(rawptr(arg.vval), 0, &error)
	n2 := tv_list_find_nr(rawptr(arg.vval), 1, &error)
	if error {
		return FAIL_E
	}
	tm^ = proftime_T((i64(i32(n1)) << 32) | i64(u32(n2)))
	return OK_E
}

// "reltime()" function.
@(export)
f_reltime :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	res: proftime_T = 0
	start: proftime_T = 0
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		res = profile_start()
	} else if ([^]Typval_T)(argvars)[1].v_type == VAR_UNKNOWN {
		if list2proftime_o((^Typval_T)(uintptr(argvars)), &res) == FAIL_E {
			return
		}
		res = profile_end(res)
	} else {
		if list2proftime_o((^Typval_T)(uintptr(argvars)), &start) == FAIL_E || list2proftime_o((^Typval_T)(uintptr(argvars) + 16), &res) == FAIL_E {
			return
		}
		res = profile_sub(res, start)
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	tv_list_append_number(rawptr(rettv.vval), C.longlong(i32(u64(res) >> 32)))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(i32(u64(res) & 0xffffffff)))
}

// "reltimestr()" function.
@(export)
f_reltimestr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tm: proftime_T = 0
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	if list2proftime_o((^Typval_T)(uintptr(argvars)), &tm) == OK_E {
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(profile_msg(tm))))
	}
}

// "reltimefloat()" function.
@(export)
f_reltimefloat :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tm: proftime_T = 0
	rettv.v_type = VAR_FLOAT
	rettv.vval = transmute(rawptr)(f64(0))
	if list2proftime_o((^Typval_T)(uintptr(argvars)), &tm) == OK_E {
		rettv.vval = transmute(rawptr)(f64(profile_signed(tm)) / 1000000000.0)
	}
}

// "shellescape()" function.
@(export)
f_shellescape :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	do_special := non_zero_arg_o((^Typval_T)(uintptr(argvars) + 16))
	rettv.vval = transmute(rawptr)(vim_strsave_shellescape_e(tv_get_string((^Typval_T)(uintptr(argvars))), do_special, do_special))
	rettv.v_type = VAR_STRING
}

// —— Batch 27ai: funcs.c sha256 + shiftwidth ——
foreign _ {
	@(link_name = "get_sw_value_col")
	get_sw_value_col_e :: proc "c" (buf: rawptr, col: C.int, left: bool) -> C.int ---
}

// "sha256()" function.
@(export)
f_sha256 :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	if ([^]Typval_T)(argvars)[0].v_type == VAR_BLOB {
		blob := rawptr(([^]Typval_T)(argvars)[0].vval)
		p := transmute(^u8)(cstring(""))
		length: C.size_t = 0
		if blob != nil {
			p = (^u8)((^rawptr)(uintptr(blob) + 16)^)
			length = C.size_t((^C.int)(uintptr(blob) + 0)^)
		}
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(sha256_bytes(p, length, nil, 0))))
	} else {
		p := tv_get_string((^Typval_T)(uintptr(argvars)))
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(sha256_bytes(transmute(^u8)(p), C.size_t(libc.strlen(p)), nil, 0))))
	}
}

// "shiftwidth()" function.
@(export)
f_shiftwidth :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		col := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil))
		if col < 0 {
			return
		}
		rettv.vval = transmute(rawptr)(C.longlong(get_sw_value_col_e(curbuf, col, false)))
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(get_sw_value_r(curbuf)))
}

// —— Batch 27aj: funcs.c repeat ——

// repeat_list (C-static in funcs.c).
repeat_list_o :: proc "c" (l: rawptr, n_in: C.longlong, rettv: ^Typval_T) {
	context = runtime.default_context()
	n := n_in
	size: C.longlong = 0
	if n > 0 {
		size = n * C.longlong(tv_list_len_o(l))
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), C.int(size))
	for n > 0 {
		tv_list_extend(rawptr(rettv.vval), l, nil)
		n -= 1
	}
}

// repeat_blob (C-static in funcs.c).
repeat_blob_o :: proc "c" (blob_tv: ^Typval_T, n: C.longlong, rettv: ^Typval_T) {
	context = runtime.default_context()
	blob := rawptr(blob_tv.vval)
	tv_blob_alloc_ret(rettv)
	if blob == nil || n <= 0 {
		return
	}
	slen := C.longlong((^C.int)(uintptr(blob) + 0)^)
	length := slen * n
	if length <= 0 {
		return
	}
	newblob := rawptr(rettv.vval)
	ga_grow((^Garray)(uintptr(newblob)), C.int(length))
	(^C.int)(uintptr(newblob))^ = C.int(length)
	i: C.longlong = 0
	for i < slen {
		if tv_blob_get_o(blob, C.int(i)) != 0 {
			break
		}
		i += 1
	}
	if i == slen {
		return
	}
	i = 0
	for i < n {
		tv_blob_set_range(newblob, i * slen, (i + 1) * slen - 1, blob_tv)
		i += 1
	}
}

// repeat_string (C-static in funcs.c).
repeat_string_o :: proc "c" (str_tv: ^Typval_T, n_in: C.longlong, rettv: ^Typval_T) {
	context = runtime.default_context()
	n := n_in
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	if n <= 0 {
		return
	}
	p := tv_get_string(str_tv)
	slen := C.size_t(libc.strlen(p))
	if slen == 0 {
		return
	}
	length := slen * C.size_t(n)
	if length / C.size_t(n) != slen {
		return
	}
	r := xmallocz_r(length)
	libc.memmove(rawptr(r), rawptr(transmute(^u8)(p)), slen)
	done := slen
	for done < length {
		copy_len := done
		if copy_len > length - done {
			copy_len = length - done
		}
		libc.memmove(rawptr(uintptr(r) + uintptr(done)), rawptr(r), copy_len)
		done += copy_len
	}
	rettv.vval = transmute(rawptr)(r)
}

// "repeat()" function.
@(export)
f_repeat :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n := tv_get_number((^Typval_T)(uintptr(argvars) + 16))
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		repeat_list_o(rawptr(([^]Typval_T)(argvars)[0].vval), n, rettv)
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_BLOB {
		repeat_blob_o((^Typval_T)(uintptr(argvars)), n, rettv)
	} else {
		repeat_string_o((^Typval_T)(uintptr(argvars)), n, rettv)
	}
}

// —— Batch 27an: funcs.c chansend (FFI fully rewired) ——
foreign _ {
	// channel_send now defined in channel.odin — call directly.
}

// "chansend(id, data)" function.
@(export)
f_chansend :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER || ([^]Typval_T)(argvars)[1].v_type == VAR_UNKNOWN {
		emsg(e_invarg)
		return
	}
	input_len: C.ptrdiff_t = 0
	input: ^u8 = nil
	id := u64(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval))
	if ([^]Typval_T)(argvars)[1].v_type == VAR_BLOB {
		b := rawptr(([^]Typval_T)(argvars)[1].vval)
		input_len = C.ptrdiff_t(tv_blob_len_o(b))
		if input_len > 0 {
			input = xmemdupz_o2((^u8)((^rawptr)(uintptr(b) + 16)^), C.size_t(input_len))
		}
	} else {
		input = save_tv_as_string((^Typval_T)(uintptr(argvars) + 16), &input_len, false, false)
	}
	if input == nil {
		return
	}
	err: cstring = nil
	rettv.vval = transmute(rawptr)(C.longlong(channel_send(id, input, C.size_t(input_len), true, &err)))
	if err != nil {
		emsg(err)
	}
}

// —— Batch 27ao: funcs.c ctx cluster ——
foreign _ {
	@(link_name = "vim_to_object")
	vim_to_object_e :: proc "c" (obj: ^Typval_T, arena: rawptr, reuse_strdata: bool) -> Api_Object ---
	// kCtxAll is an Odin export (context.odin) — single copy.
}

KCTXREGS_O :: 1
KCTXJUMPS_O :: 2
KCTXBUFS_O :: 4
KCTXGVARS_O :: 8
KCTXSFUNCS_O :: 16
KCTXFUNCS_O :: 32
E_INVARG_NVAL_S :: "E475: Invalid value for argument %s: %s"
E_CTXEMPTY_S :: "Context stack is empty"

// Context mirror (context.h): 4×String + Array = 88B.
Context_O :: struct {
	regs:   NvimString,
	jumps:  NvimString,
	bufs:   NvimString,
	gvars:  NvimString,
	funcs:  Api_Array,
}
#assert(size_of(Context_O) == 88)

// Arena mirror (memory_defs.h): 24B, empty = zeros.
Arena_O :: struct {
	cur_blk: rawptr,
	pos:     C.size_t,
	size:    C.size_t,
}
#assert(size_of(Arena_O) == 24)

// "ctxget([{index}])" function.
@(export)
f_ctxget :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	index: C.size_t = 0
	if ([^]Typval_T)(argvars)[0].v_type == VAR_NUMBER {
		index = C.size_t(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval))
	} else if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		semsg(e_invarg2, cstring("expected nothing or a Number as an argument"))
		return
	}
	ctx := ctx_get(index)
	if ctx == nil {
		semsg(cstring(E_INVARG_NVAL_S), cstring("index"), cstring("out of bounds"))
		return
	}
	arena := Arena_O{}
	d := ctx_to_dict(ctx, rawptr(&arena))
	obj := Api_Object{}
	obj.t = 6
	(^Api_Dict)(&obj.data[0])^ = d
	err := Api_Error{typ = -1, msg = nil}
	object_to_vim_e(obj, rettv, rawptr(&err))
	arena_mem_free(arena_finish(rawptr(&arena)))
	api_clear_error_r(&err)
}

// "ctxpop()" function.
@(export)
f_ctxpop :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if !ctx_restore(nil, kCtxAll) {
		emsg(cstring(E_CTXEMPTY_S))
	}
}

// "ctxpush([{types}])" function.
@(export)
f_ctxpush :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	types := kCtxAll
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		types = 0
		l := rawptr(([^]Typval_T)(argvars)[0].vval)
		li := tv_list_first_o(l)
		for li != nil {
			tv := (^Typval_T)(uintptr(li) + 16)
			if tv.v_type == VAR_STRING {
				s := transmute(cstring)(tv.vval)
				if libc.strcmp(s, cstring("regs")) == 0 {
					types |= KCTXREGS_O
				} else if libc.strcmp(s, cstring("jumps")) == 0 {
					types |= KCTXJUMPS_O
				} else if libc.strcmp(s, cstring("bufs")) == 0 {
					types |= KCTXBUFS_O
				} else if libc.strcmp(s, cstring("gvars")) == 0 {
					types |= KCTXGVARS_O
				} else if libc.strcmp(s, cstring("sfuncs")) == 0 {
					types |= KCTXSFUNCS_O
				} else if libc.strcmp(s, cstring("funcs")) == 0 {
					types |= KCTXFUNCS_O
				}
			}
			li = (^rawptr)(uintptr(li))^
		}
	} else if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		semsg(e_invarg2, cstring("expected nothing or a List as an argument"))
		return
	}
	ctx_save(nil, types)
}

// "ctxset({context}[, {index}])" function.
@(export)
f_ctxset :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_DICT {
		semsg(e_invarg2, cstring("expected dictionary as first argument"))
		return
	}
	index: C.size_t = 0
	if ([^]Typval_T)(argvars)[1].v_type == VAR_NUMBER {
		index = C.size_t(transmute(C.longlong)(([^]Typval_T)(argvars)[1].vval))
	} else if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		semsg(e_invarg2, cstring("expected nothing or a Number as second argument"))
		return
	}
	ctx := ctx_get(index)
	if ctx == nil {
		semsg(cstring(E_INVARG_NVAL_S), cstring("index"), cstring("out of bounds"))
		return
	}
	save_did_emsg := did_emsg_flag
	did_emsg_flag = 0
	arena := Arena_O{}
	obj := vim_to_object_e((^Typval_T)(uintptr(argvars)), rawptr(&arena), true)
	tmp := Context_O{}
	err := Api_Error{typ = -1, msg = nil}
	ctx_from_dict((^Api_Dict)(&obj.data[0])^, rawptr(&tmp), rawptr(&err))
	if err.typ != -1 {
		semsg(cstring("%s"), transmute(cstring)(err.msg))
		ctx_free(rawptr(&tmp))
	} else {
		ctx_free(ctx)
		(^Context_O)(ctx)^ = tmp
	}
	arena_mem_free(arena_finish(rawptr(&arena)))
	api_clear_error_r(&err)
	did_emsg_flag = save_did_emsg
}

// "ctxsize()" function.
@(export)
f_ctxsize :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(ctx_size()))
}

// —— Batch 27ar: funcs.c screen cluster ——
foreign _ {
	@(link_name = "msg_scroll_flush")
	msg_scroll_flush_e :: proc "c" () ---
	@(link_name = "ui_comp_get_grid_at_coord")
	ui_comp_get_grid_at_coord_e :: proc "c" (row: C.int, col: C.int) -> ^ScreenGrid ---
	// ui_current_row/col now defined in ui.odin — call directly.
}

// Grid adjust for screen*() (C-static in funcs.c).
screenchar_adjust_o :: proc "c" (grid: ^rawptr, row: ^C.int, col: ^C.int) {
	context = runtime.default_context()
	msg_scroll_flush_e()
	g := ui_comp_get_grid_at_coord_e(row^, col^)
	grid^ = rawptr(g)
	row^ -= g.comp_row
	col^ -= g.comp_col
}

// "screenattr()" function.
@(export)
f_screenattr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	row := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)) - 1
	col := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil)) - 1
	grid: rawptr = nil
	screenchar_adjust_o(&grid, &row, &col)
	g := (^ScreenGrid)(grid)
	c: C.int = -1
	if row >= 0 && row < g.rows && col >= 0 && col < g.cols {
		c = g.attrs[g.line_offset[row] + C.size_t(col)]
	}
	rettv.vval = transmute(rawptr)(C.longlong(c))
}

// "screenchar()" function.
@(export)
f_screenchar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	row := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)) - 1
	col := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil)) - 1
	grid: rawptr = nil
	screenchar_adjust_o(&grid, &row, &col)
	g := (^ScreenGrid)(grid)
	n: C.longlong = -1
	if row >= 0 && row < g.rows && col >= 0 && col < g.cols {
		n = C.longlong(schar_get_first_codepoint(grid_getchar(g, row, col, nil)))
	}
	rettv.vval = transmute(rawptr)(n)
}

// "screenstring()" function.
@(export)
f_screenstring :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(cstring(nil))
	rettv.v_type = VAR_STRING
	row := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)) - 1
	col := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil)) - 1
	grid: rawptr = nil
	screenchar_adjust_o(&grid, &row, &col)
	g := (^ScreenGrid)(grid)
	if row < 0 || row >= g.rows || col < 0 || col >= g.cols {
		return
	}
	buf: [33]u8
	schar_get(&buf[0], grid_getchar(g, row, col, nil))
	rettv.vval = transmute(rawptr)(xstrdup_o(&buf[0]))
}

// "screenchars()" function.
@(export)
f_screenchars :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	row := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), nil)) - 1
	col := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), nil)) - 1
	grid: rawptr = nil
	screenchar_adjust_o(&grid, &row, &col)
	g := (^ScreenGrid)(grid)
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if row < 0 || row >= g.rows || col < 0 || col >= g.cols {
		return
	}
	buf: [33]u8
	schar_get(&buf[0], grid_getchar(g, row, col, nil))
	i: C.size_t = 0
	for {
		tv_list_append_number(rawptr(rettv.vval), C.longlong(utf_ptr2char(transmute(cstring)(&buf[i]))))
		i += C.size_t(utf_ptr2len_o(transmute(cstring)(&buf[i])))
		if buf[i] == 0 {
			break
		}
	}
}

// "screencol()" function.
@(export)
f_screencol :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(ui_current_col() + 1))
}

// "screenrow()" function.
@(export)
f_screenrow :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(ui_current_row() + 1))
}

// —— Batch 27ba: funcs.c tagfiles + taglist ——
foreign _ {
	@(link_name = "get_tagfname")
	get_tagfname_e :: proc "c" (tnp: rawptr, first: C.int, buf: cstring) -> C.int ---
	@(link_name = "tagname_free")
	tagname_free_e :: proc "c" (tnp: rawptr) ---
	@(link_name = "get_tags")
	get_tags_e :: proc "c" (list: rawptr, pat: cstring, buf_fname: cstring) -> C.int ---
}

KLISTLEN_UNKNOWN_O :: -1

// tagname_T mirror (tag.h): 32B.
Tagname_O :: struct {
	tn_tags:            ^u8,   // 0
	tn_np:              ^u8,   // 8
	tn_did_filefind_init: C.int, // 16
	tn_hf_idx:          C.int, // 20
	tn_search_ctx:      rawptr, // 24
}
#assert(size_of(Tagname_O) == 32)

// "tagfiles()" function.
@(export)
f_tagfiles :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	fname := (^u8)(xmalloc(MAXPATHL_O))
	first := true
	tn := Tagname_O{}
	for get_tagfname_e(rawptr(&tn), C.int(first), transmute(cstring)(fname)) == OK_E {
		tv_list_append_string(rawptr(rettv.vval), fname, -1)
		first = false
	}
	tagname_free_e(rawptr(&tn))
	xfree(rawptr(fname))
}

// "taglist()" function.
@(export)
f_taglist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tag_pattern := tv_get_string((^Typval_T)(uintptr(argvars)))
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if ([^]u8)(tag_pattern)[0] == 0 {
		return
	}
	fname: cstring = nil
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		fname = tv_get_string((^Typval_T)(uintptr(argvars) + 16))
	}
	l := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	get_tags_e(l, transmute(cstring)(tag_pattern), fname)
}

// —— Batch 27bv: funcs.c rpcrequest ——
foreign _ {
	@(link_name = "rpc_send_call")
	rpc_send_call_e :: proc "c" (id: C.ulonglong, method_name: cstring, args: Api_Array, result_mem: ^rawptr, err: rawptr) -> Api_Object ---
	@(link_name = "get_client_info")
	get_client_info_e :: proc "c" (chan: rawptr, key: cstring) -> cstring ---
	@(link_name = "provider_call_nesting")
	provider_call_nesting_g: C.int
	@(link_name = "provider_caller_scope")
	provider_caller_scope_g: CallerScope_O
	@(link_name = "autocmd_fname")
	autocmd_fname_g: cstring
	@(link_name = "autocmd_match")
	autocmd_match_g: cstring
	@(link_name = "autocmd_fname_full")
	autocmd_fname_full_g: bool
	@(link_name = "autocmd_bufnr")
	autocmd_bufnr_g: C.int
	@(link_name = "semsg_multiline")
	semsg_multiline_e :: proc "c" (kind: cstring, fmt: cstring, #c_vararg args: ..any) ---
}

// caller_scope mirror (globals.h): 88B.
CallerScope_O :: struct {
	script_ctx:        sctx_T,   // 0..24
	es_entry:          Estack,   // 24..56
	autocmd_fname:     cstring,  // 56
	autocmd_match:     cstring,  // 64
	autocmd_fname_full: bool,    // 72
	_pad:              [3]u8,
	autocmd_bufnr:     C.int,    // 76
	funccalp:          rawptr,   // 80..88
}
#assert(size_of(CallerScope_O) == 88)

// "rpcrequest()" function.
@(export)
f_rpcrequest :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	l_nesting := provider_call_nesting_g
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER || transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval) <= 0 {
		semsg(e_invarg2, cstring("Channel id must be a positive integer"))
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type != VAR_STRING {
		semsg(e_invarg2, cstring("Method name must be a string"))
		return
	}
	items: [MAX_FUNC_ARGS_O]Api_Object
	args := Api_Array{size = 0, capacity = MAX_FUNC_ARGS_O, items = (^Api_Object)(&items[0])}
	arena := Arena_O{}
	tv := (^Typval_T)(uintptr(argvars) + 32)
	for tv.v_type != VAR_UNKNOWN {
		([^]Api_Object)(args.items)[args.size] = vim_to_object_e(tv, rawptr(&arena), true)
		args.size += 1
		tv = (^Typval_T)(uintptr(tv) + 16)
	}
	funccal_entry: [16]u8
	saved_sctx: [24]u8
	saved_fname: cstring = nil
	saved_match: cstring = nil
	saved_full := false
	saved_bufnr: C.int = 0
	if l_nesting != 0 {
		libc.memcpy(rawptr(&saved_sctx[0]), rawptr(&current_sctx_buf[0]), 24)
		saved_fname = autocmd_fname_g
		saved_match = autocmd_match_g
		saved_full = autocmd_fname_full_g
		saved_bufnr = autocmd_bufnr_g
		save_funccal(rawptr(&funccal_entry[0]))
		libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&provider_caller_scope_g.script_ctx), 24)
		ga_grow(&exestack, 1)
		(^Estack)(rawptr(uintptr(exestack.ga_data) + uintptr(exestack.ga_len) * 32))^ = provider_caller_scope_g.es_entry
		exestack.ga_len += 1
		autocmd_fname_g = provider_caller_scope_g.autocmd_fname
		autocmd_match_g = provider_caller_scope_g.autocmd_match
		autocmd_fname_full_g = provider_caller_scope_g.autocmd_fname_full
		autocmd_bufnr_g = provider_caller_scope_g.autocmd_bufnr
		set_current_funccal(provider_caller_scope_g.funccalp)
	}
	err := Api_Error{typ = -1, msg = nil}
	chan_id := C.ulonglong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval))
	method := tv_get_string((^Typval_T)(uintptr(argvars) + 16))
	res_mem: rawptr = nil
	result := rpc_send_call_e(chan_id, method, args, &res_mem, rawptr(&err))
	arena_mem_free(arena_finish(rawptr(&arena)))
	if l_nesting != 0 {
		libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved_sctx[0]), 24)
		exestack.ga_len -= 1
		autocmd_fname_g = saved_fname
		autocmd_match_g = saved_match
		autocmd_fname_full_g = saved_full
		autocmd_bufnr_g = saved_bufnr
		restore_funccal()
	}
	if err.typ != -1 {
		name: cstring = nil
		chan := find_channel_o(u64(chan_id))
		if chan != nil {
			name = get_client_info_e(chan, cstring("name"))
		}
		if name != nil {
			semsg_multiline_e(cstring("rpc_error"), cstring("Invoking '%s' on channel %llu (%s):\n%s"), method, chan_id, name, transmute(cstring)(err.msg))
		} else {
			semsg_multiline_e(cstring("rpc_error"), cstring("Invoking '%s' on channel %llu:\n%s"), method, chan_id, transmute(cstring)(err.msg))
		}
	} else {
		object_to_vim_e(result, rettv, rawptr(&err))
	}
	arena_mem_free(res_mem)
	api_clear_error_r(&err)
}

// —— Batch 27bu: funcs.c jobwait ——
foreign _ {
	@(link_name = "channels")
	channels_g: PMap_uint64_t
	// channel_incref/decref now defined in channel.odin — call directly.
}

PROC_STATUS_OFF :: 28
PROC_STOPTIME_OFF :: 40
CHAN_STREAMTYPE_OFF :: 24
CHAN_EVENTS_OFF :: 16
KCHSTREAM_PROC_O :: 0

// pmap lookup (channel.h static inline).
find_channel_o :: proc "c" (id: u64) -> rawptr {
	context = runtime.default_context()
	k := mh_get(&channels_g.set, id, hash_uint64_t, equal_uint64_t)
	if k == MH_TOMBSTONE {
		return nil
	}
	return channels_g.values[uintptr(k)]
}

// proc_is_stopped (proc.h static inline).
proc_is_stopped_o :: proc "c" (pr: rawptr) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(pr) + PROC_STATUS_OFF)^ >= 0 {
		return true
	}
	return (^u64)(uintptr(pr) + PROC_STOPTIME_OFF)^ != 0
}

// "jobwait()" function.
@(export)
f_jobwait :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST || (([^]Typval_T)(argvars)[1].v_type != VAR_NUMBER && ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN) {
		emsg(e_invarg)
		return
	}
	args := rawptr(([^]Typval_T)(argvars)[0].vval)
	n := tv_list_len_o(args)
	jobs := ([^]rawptr)(xcalloc(C.size_t(n), 8))
	waiting_jobs := multiqueue_new(loop_on_put, rawptr(&main_loop))
	i: C.int = 0
	li := tv_list_first_o(args)
	for li != nil {
		chan: rawptr = nil
		itv := (^Typval_T)(uintptr(li) + 16)
		if itv.v_type == VAR_NUMBER {
			chan = find_channel_o(u64(transmute(C.longlong)(itv.vval)))
			if chan != nil && (^C.int)(uintptr(chan) + CHAN_STREAMTYPE_OFF)^ != KCHSTREAM_PROC_O {
				chan = nil
			} else if chan != nil && proc_is_stopped_o(rawptr(uintptr(chan) + CHAN_STREAM_OFF)) {
				proc_wait((^Proc)(rawptr(uintptr(chan) + CHAN_STREAM_OFF)), -1, nil)
				chan = nil
			}
		}
		if chan == nil {
			jobs[i] = nil
		} else {
			jobs[i] = chan
			channel_incref(chan)
			if (^C.int)(uintptr(chan) + CHAN_STREAM_OFF + PROC_STATUS_OFF)^ < 0 {
				multiqueue_process_events((^MultiQueue)((^rawptr)(uintptr(chan) + CHAN_EVENTS_OFF)^))
				multiqueue_replace_parent((^MultiQueue)((^rawptr)(uintptr(chan) + CHAN_EVENTS_OFF)^), waiting_jobs)
			}
		}
		i += 1
		li = (^rawptr)(uintptr(li))^
	}
	remaining: C.int = -1
	before: u64 = 0
	if ([^]Typval_T)(argvars)[1].v_type == VAR_NUMBER && transmute(C.longlong)(([^]Typval_T)(argvars)[1].vval) >= 0 {
		remaining = C.int(transmute(C.longlong)(([^]Typval_T)(argvars)[1].vval))
		before = os_hrtime()
	}
	busy := remaining != 0
	if busy {
		ui_busy_start()
		ui_flush()
	}
	i = 0
	for i < n {
		if remaining == 0 {
			break
		}
		if jobs[i] == nil {
			i += 1
			continue
		}
		status := proc_wait((^Proc)(rawptr(uintptr(jobs[i]) + CHAN_STREAM_OFF)), remaining, waiting_jobs)
		if status < 0 {
			break
		}
		if remaining > 0 {
			now := os_hrtime()
			remaining = min(C.int(0), remaining - C.int((now - before) / 1000000))
			before = now
		}
		i += 1
	}
	rv := tv_list_alloc(C.ssize_t(n))
	i = 0
	for i < n {
		if jobs[i] == nil {
			tv_list_append_number(rv, C.longlong(-3))
		} else {
			multiqueue_process_events((^MultiQueue)((^rawptr)(uintptr(jobs[i]) + CHAN_EVENTS_OFF)^))
			multiqueue_replace_parent((^MultiQueue)((^rawptr)(uintptr(jobs[i]) + CHAN_EVENTS_OFF)^), main_loop.events)
			tv_list_append_number(rv, C.longlong((^C.int)(uintptr(jobs[i]) + CHAN_STREAM_OFF + PROC_STATUS_OFF)^))
			channel_decref(jobs[i])
		}
		i += 1
	}
	multiqueue_free(waiting_jobs)
	xfree(rawptr(jobs))
	if busy {
		ui_busy_stop()
	}
	tv_list_ref_o(rv)
	rettv.v_type = VAR_LIST
	rettv.vval = transmute(rawptr)(rv)
}

// —— Batch 27bt: funcs.c input family ——
foreign _ {
	@(link_name = "get_user_input")
	get_user_input_e :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, inputdialog: bool, secret: bool) ---
	@(link_name = "prompt_for_input")
	prompt_for_input_e :: proc "c" (prompt: cstring, hl_id: C.int, one_key: bool, mouse_used: ^bool) -> C.int ---
	@(link_name = "verb_msg")
	verb_msg_e :: proc "c" (s: cstring) -> C.int ---
	@(link_name = "save_typeahead")
	save_typeahead_e :: proc "c" (tp: rawptr) ---
	@(link_name = "restore_typeahead")
	restore_typeahead_e :: proc "c" (tp: rawptr) ---
}

TASAVE_SIZE :: 192
E_INRESTORE_S :: "called inputrestore() more often than inputsave()"

ga_userinput_g := Garray{ga_itemsize = TASAVE_SIZE, ga_growsize = 4}
inputsecret_flag_g := false

// "input()" function.
@(export)
f_input :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_user_input_e(argvars, rettv, false, inputsecret_flag_g)
}

// "inputdialog()" function.
@(export)
f_inputdialog :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_user_input_e(argvars, rettv, true, inputsecret_flag_g)
}

// "inputlist()" function.
@(export)
f_inputlist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST {
		semsg(cstring(E_LISTARG_S), cstring("inputlist()"))
		return
	}
	msg_ext_set_kind(cstring("confirm"))
	msg_start()
	msg_row = Rows - 1
	lines_left = Rows
	msg_scroll = 1
	msg_clr_eos_r()
	l := rawptr(([^]Typval_T)(argvars)[0].vval)
	li := tv_list_first_o(l)
	for li != nil {
		msg_puts(tv_get_string((^Typval_T)(uintptr(li) + 16)))
		if !ui_has(K_UIMESSAGES_O) || (^rawptr)(uintptr(li))^ != nil {
			msg_putchar('\n')
		}
		li = (^rawptr)(uintptr(li))^
	}
	mouse_used := false
	selected := prompt_for_input_e(nil, 0, false, &mouse_used)
	if mouse_used {
		selected = tv_list_len_o(l) - (cmdline_row - mouse_row)
	}
	rettv.vval = transmute(rawptr)(C.longlong(selected))
}

// "inputrestore()" function.
@(export)
f_inputrestore :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ga_userinput_g.ga_len > 0 {
		ga_userinput_g.ga_len -= 1
		restore_typeahead_e(rawptr(uintptr(ga_userinput_g.ga_data) + uintptr(ga_userinput_g.ga_len) * TASAVE_SIZE))
	} else if p_verbose > 1 {
		verb_msg_e(cstring(E_INRESTORE_S))
		rettv.vval = transmute(rawptr)(C.longlong(1))
	}
}

// "inputsave()" function.
@(export)
f_inputsave :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	ga_grow(&ga_userinput_g, 1)
	p := rawptr(uintptr(ga_userinput_g.ga_data) + uintptr(ga_userinput_g.ga_len) * TASAVE_SIZE)
	ga_userinput_g.ga_len += 1
	save_typeahead_e(p)
}

// "inputsecret()" function.
@(export)
f_inputsecret :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	cmdline_star += 1
	inputsecret_flag_g = true
	f_input(argvars, rettv, fptr)
	cmdline_star -= 1
	inputsecret_flag_g = false
}

// —— Batch 27bs: funcs.c get() ——

// "get()" function.
@(export)
f_get :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv: ^Typval_T = nil
	what_is_dict := false
	if ([^]Typval_T)(argvars)[0].v_type == VAR_BLOB {
		error := false
		idx := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error))
		if !error {
			rettv.v_type = VAR_NUMBER
			b := rawptr(([^]Typval_T)(argvars)[0].vval)
			if idx < 0 {
				idx = tv_blob_len_o(b) + idx
			}
			if idx < 0 || idx >= tv_blob_len_o(b) {
				rettv.vval = transmute(rawptr)(C.longlong(-1))
			} else {
				rettv.vval = transmute(rawptr)(C.longlong(tv_blob_get_o(b, idx)))
				tv = rettv
			}
		}
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		l := rawptr(([^]Typval_T)(argvars)[0].vval)
		if l != nil {
			error := false
			li := tv_list_find(l, C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error)))
			if !error && li != nil {
				tv = (^Typval_T)(uintptr(li) + 16)
			}
		}
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_DICT {
		d := rawptr(([^]Typval_T)(argvars)[0].vval)
		if d != nil {
			di := tv_dict_find(d, tv_get_string((^Typval_T)(uintptr(argvars) + 16)), -1)
			if di != nil {
				tv = (^Typval_T)(uintptr(di))
			}
		}
	} else if tv_is_func_o(([^]Typval_T)(argvars)[0]) {
		pt: rawptr = nil
		fref_buf: [48]u8
		if ([^]Typval_T)(argvars)[0].v_type == VAR_PARTIAL {
			pt = rawptr(([^]Typval_T)(argvars)[0].vval)
		} else {
			libc.memset(&fref_buf[0], 0, 48)
			(^rawptr)(rawptr(&fref_buf[PT_NAME_OFF_O]))^ = rawptr(([^]Typval_T)(argvars)[0].vval)
			pt = rawptr(&fref_buf[0])
		}
		if pt != nil {
			what := tv_get_string((^Typval_T)(uintptr(argvars) + 16))
			if libc.strcmp(what, cstring("func")) == 0 || libc.strcmp(what, cstring("name")) == 0 {
				pname := partial_name(pt)
				if ([^]u8)(what)[0] == 'f' {
					rettv.v_type = VAR_FUNC
				} else {
					rettv.v_type = VAR_STRING
				}
				if rettv.v_type == VAR_FUNC {
					func_ref(transmute(cstring)(pname))
				}
				if ([^]u8)(what)[0] == 'n' && (^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ == nil && (^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ != nil {
					pname = printable_func_name((^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^)
				}
				rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(pname)))
			} else if libc.strcmp(what, cstring("dict")) == 0 {
				what_is_dict = true
				if (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ != nil {
					tv_dict_set_ret_o(rettv, (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^)
				}
			} else if libc.strcmp(what, cstring("args")) == 0 {
				rettv.v_type = VAR_LIST
				pargc := (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^
				l := tv_list_alloc_ret(transmute(^Typval)(rettv), pargc)
				argv := ([^]Typval_T)((^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^)
				i: C.int = 0
				for i < pargc {
					tv_list_append_tv(l, &argv[i])
					i += 1
				}
			} else if libc.strcmp(what, cstring("arity")) == 0 {
				required: C.int = 0
				optional: C.int = 0
				varargs := false
				pname := partial_name(pt)
				get_func_arity(pname, &required, &optional, &varargs)
				rettv.v_type = VAR_DICT
				tv_dict_alloc_ret(rettv)
				dict := rawptr(rettv.vval)
				pargc := (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^
				if pargc >= required + optional {
					required = 0
					optional = 0
				} else if pargc > required {
					optional -= pargc - required
					required = 0
				} else {
					required -= pargc
				}
				tv_dict_add_nr(dict, cstring("required"), 8, C.longlong(required))
				tv_dict_add_nr(dict, cstring("optional"), 8, C.longlong(optional))
				vb: C.int = 0
				if varargs {
					vb = 1
				}
				tv_dict_add_bool(dict, cstring("varargs"), 7, vb)
			} else {
				semsg(e_invarg2, what)
			}
			if !what_is_dict {
				return
			}
		}
	} else {
		semsg(cstring(E_LISTDICTBLOBARG_S), cstring("get()"))
	}
	if tv == nil {
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			tv_copy((^Typval_T)(uintptr(argvars) + 32), rettv)
		}
	} else {
		tv_copy(tv, rettv)
	}
}

// —— Batch 27br: funcs.c getregion engine ——
foreign _ {
	@(link_name = "block_prep")
	block_prep_e :: proc "c" (oap: rawptr, bdp: rawptr, lnum: C.int, is_del: bool) ---
	@(link_name = "charwise_block_prep")
	charwise_block_prep_e :: proc "c" (start: Pos_T, end: Pos_T, bdp: rawptr, lnum: C.int, inclusive: bool) ---
	@(link_name = "mb_prevptr")
	mb_prevptr_e :: proc "c" (line: ^u8, p: ^u8) -> ^u8 ---
	@(link_name = "ml_get_pos")
	ml_get_pos_e :: proc "c" (pos: ^Pos_T) -> ^u8 ---
	@(link_name = "unadjust_for_sel_inner")
	unadjust_for_sel_inner_e :: proc "c" (pp: ^Pos_T) -> bool ---
	@(link_name = "reset_lbr")
	reset_lbr_e :: proc "c" () -> bool ---
	@(link_name = "restore_lbr")
	restore_lbr_e :: proc "c" (lbr_saved: bool) ---
	@(link_name = "virtual_op")
	virtual_op_g: TriState
}

E966_S :: "E966: Invalid line number: %ld"
E964_S :: "E964: Invalid column number: %ld"
OP_NOP_O :: 0

// block_def mirror (register_defs.h): 64B.
Block_Def_O :: struct {
	startspaces:    C.int, // 0
	endspaces:      C.int, // 4
	textlen:        C.int, // 8
	_pad8:          [4]u8,
	textstart:      ^u8,   // 16
	textcol:        C.int, // 24
	start_vcol:     C.int, // 28
	end_vcol:       C.int, // 32
	is_short:       C.int, // 36
	is_MAX:         C.int, // 40
	is_oneChar:     C.int, // 44
	pre_whitesp:    C.int, // 48
	pre_whitesp_c:  C.int, // 52
	end_char_vcols: C.int, // 56
	start_char_vcols: C.int, // 60
}
#assert(size_of(Block_Def_O) == 64)

// block_def to String (C-static in funcs.c).
block_def2str_o :: proc "c" (bd: ^Block_Def_O) -> NvimString {
	context = runtime.default_context()
	size := C.size_t(bd.startspaces) + C.size_t(bd.endspaces) + C.size_t(bd.textlen)
	ret_data := (^u8)(xmalloc(size + 1))
	libc.memset(rawptr(ret_data), ' ', C.size_t(bd.startspaces))
	sz: C.size_t = C.size_t(bd.startspaces)
	libc.memmove(rawptr(uintptr(ret_data) + uintptr(sz)), rawptr(bd.textstart), C.size_t(bd.textlen))
	sz += C.size_t(bd.textlen)
	libc.memset(rawptr(uintptr(ret_data) + uintptr(sz)), ' ', C.size_t(bd.endspaces))
	sz += C.size_t(bd.endspaces)
	([^]u8)(ret_data)[sz] = 0
	return NvimString{data = transmute(cstring)(ret_data), size = sz}
}

// pos_T less-than (mark_defs.h static inline).
lt_pos_o :: proc "c" (a: Pos_T, b: Pos_T) -> bool {
	context = runtime.default_context()
	if a.lnum != b.lnum {
		return a.lnum < b.lnum
	} else if a.col != b.col {
		return a.col < b.col
	}
	return a.coladd < b.coladd
}

// Shared getregion()/getregionpos() position engine (C-static in funcs.c).
getregionpos_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, p1: ^Pos_T, p2: ^Pos_T, inclusive: ^bool, region_type: ^C.int, oap: rawptr) -> C.int {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if tv_check_for_list_arg(argvars, 0) == FAIL_E || tv_check_for_list_arg(argvars, 1) == FAIL_E || tv_check_for_opt_dict_arg(argvars, 2) == FAIL_E {
		return FAIL_E
	}
	fnum1: C.int = -1
	fnum2: C.int = -1
	if list2fpos((^Typval_T)(uintptr(argvars)), p1, &fnum1, nil, false) != OK_E || list2fpos((^Typval_T)(uintptr(argvars) + 16), p2, &fnum2, nil, false) != OK_E || fnum1 != fnum2 {
		return FAIL_E
	}
	is_select_exclusive := false
	type: cstring = nil
	default_type := cstring("v")
	if ([^]Typval_T)(argvars)[2].v_type == VAR_DICT {
		d := rawptr(([^]Typval_T)(argvars)[2].vval)
		def_excl: C.int = 0
		if ([^]u8)(p_sel)[0] == 'e' {
			def_excl = 1
		}
		if tv_dict_get_bool(d, cstring("exclusive"), def_excl) != 0 {
			is_select_exclusive = true
		}
		type = tv_dict_get_string(d, cstring("type"), false)
		if type == nil {
			type = default_type
		}
	} else {
		is_select_exclusive = ([^]u8)(p_sel)[0] == 'e'
		type = default_type
	}
	block_width: C.int = 0
	t := ([^]u8)(type)
	if t[0] == 'v' && t[1] == 0 {
		region_type^ = kMTCharWise
	} else if t[0] == 'V' && t[1] == 0 {
		region_type^ = kMTLineWise
	} else if t[0] == 22 {
		pp := transmute(cstring)(rawptr(uintptr(rawptr(type)) + 1))
		if ([^]u8)(pp)[0] != 0 {
			ppu := transmute(^u8)(pp)
			block_width = getdigits_int(&ppu, false, 0)
			pp = transmute(cstring)(ppu)
			if block_width <= 0 || ([^]u8)(pp)[0] != 0 {
				semsg(cstring(E_INVARG_NVAL_S), cstring("type"), type)
				return FAIL_E
			}
		}
		region_type^ = kMTBlockWise
	} else {
		semsg(cstring(E_INVARG_NVAL_S), cstring("type"), type)
		return FAIL_E
	}
	findbuf := curbuf
	if fnum1 != 0 {
		findbuf = buflist_findnr(fnum1)
	}
	if findbuf == nil || (^rawptr)(uintptr(findbuf) + B_ML_MFP_OFF)^ == nil {
		emsg(cstring(E681_S))
		return FAIL_E
	}
	linecount := (^C.int)(uintptr(findbuf) + B_ML_LINE_COUNT)^
	if p1.lnum < 1 || p1.lnum > linecount {
		semsg(cstring(E966_S), C.longlong(p1.lnum))
		return FAIL_E
	}
	if p1.col == MAXCOL {
		p1.col = ml_get_buf_len(findbuf, p1.lnum) + 1
	} else if p1.col < 1 || p1.col > ml_get_buf_len(findbuf, p1.lnum) + 1 {
		semsg(cstring(E964_S), C.longlong(p1.col))
		return FAIL_E
	}
	if p2.lnum < 1 || p2.lnum > linecount {
		semsg(cstring(E966_S), C.longlong(p2.lnum))
		return FAIL_E
	}
	if p2.col == MAXCOL {
		p2.col = ml_get_buf_len(findbuf, p2.lnum) + 1
	} else if p2.col < 1 || p2.col > ml_get_buf_len(findbuf, p2.lnum) + 1 {
		semsg(cstring(E964_S), C.longlong(p2.col))
		return FAIL_E
	}
	curbuf = findbuf
	(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = curbuf
	if virtual_active(curwin) {
		virtual_op_g = TriState.kTrue
	} else {
		virtual_op_g = TriState.kFalse
	}
	p1.col -= 1
	p2.col -= 1
	if !lt_pos_o(p1^, p2^) {
		tmp := p1^
		p1^ = p2^
		p2^ = tmp
	}
	if region_type^ == kMTCharWise {
		if is_select_exclusive && !pos_equal_o(p1^, p2^) {
			inclusive^ = !unadjust_for_sel_inner_e(p2)
		}
		if inclusive^ && virtual_op_g != TriState.kTrue && ([^]u8)(ml_get_pos_e(p2))[0] == 0 {
			inclusive^ = false
		}
	} else if region_type^ == kMTBlockWise {
		sc1, ec1, sc2, ec2: C.int = 0, 0, 0, 0
		lbr_saved := reset_lbr_e()
		getvvcol(curwin, (^Pos_T)(rawptr(p1)), &sc1, nil, &ec1, 0)
		getvvcol(curwin, (^Pos_T)(rawptr(p2)), &sc2, nil, &ec2, 0)
		restore_lbr_e(lbr_saved)
		(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTBlockWise
		(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = true
		(^C.int)(uintptr(oap) + OAP_OP_TYPE)^ = OP_NOP_O
		(^Pos_T)(uintptr(oap) + OAP_START)^ = p1^
		(^Pos_T)(uintptr(oap) + OAP_END)^ = p2^
		(^C.int)(uintptr(oap) + OAP_START_VCOL)^ = sc1 if sc1 < sc2 else sc2
		if block_width > 0 {
			(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = (^C.int)(uintptr(oap) + OAP_START_VCOL)^ + block_width - 1
		} else if is_select_exclusive && ec1 < sc2 && 0 < sc2 && ec2 > ec1 {
			(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = sc2 - 1
		} else {
			(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = ec1 if ec1 > ec2 else ec2
		}
	}
	l := C.int(utfc_ptr2len(transmute(cstring)(ml_get_pos_e(p2))))
	if l > 1 {
		p2.col += l - 1
	}
	return OK_E
}

// Range-list builder (C-static in funcs.c).
add_regionpos_range_o :: proc "c" (rettv: ^Typval_T, p1: Pos_T, p2: Pos_T) {
	context = runtime.default_context()
	l1 := tv_list_alloc(2)
	tv_list_append_list(rawptr(rettv.vval), l1)
	l2 := tv_list_alloc(4)
	tv_list_append_list(l1, l2)
	l3 := tv_list_alloc(4)
	tv_list_append_list(l1, l3)
	bf := (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	tv_list_append_number(l2, C.longlong(bf))
	tv_list_append_number(l2, C.longlong(p1.lnum))
	tv_list_append_number(l2, C.longlong(p1.col))
	tv_list_append_number(l2, C.longlong(p1.coladd))
	tv_list_append_number(l3, C.longlong(bf))
	tv_list_append_number(l3, C.longlong(p2.lnum))
	tv_list_append_number(l3, C.longlong(p2.col))
	tv_list_append_number(l3, C.longlong(p2.coladd))
}

// "getregion()" function.
@(export)
f_getregion :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	save_curbuf := curbuf
	save_virtual := virtual_op_g
	p1 := Pos_T{}
	p2 := Pos_T{}
	inclusive := true
	region_type: C.int = kMTUnknown
	oa: [88]u8
	libc.memset(&oa[0], 0, 88)
	if getregionpos_o(argvars, rettv, &p1, &p2, &inclusive, &region_type, rawptr(&oa[0])) == FAIL_E {
		return
	}
	lnum := p1.lnum
	for lnum <= p2.lnum {
		akt := NvimString{}
		if region_type == kMTBlockWise {
			bd := Block_Def_O{}
			block_prep_e(rawptr(&oa[0]), rawptr(&bd), lnum, false)
			akt = block_def2str_o(&bd)
		} else if region_type == kMTLineWise || (p1.lnum < lnum && lnum < p2.lnum) {
			akt = transmute(NvimString)(cbuf_to_string_r(transmute(cstring)(ml_get(lnum)), C.size_t(ml_get_len_r2(lnum))))
		} else {
			bd := Block_Def_O{}
			charwise_block_prep_e(p1, p2, rawptr(&bd), lnum, inclusive)
			akt = block_def2str_o(&bd)
		}
		tv_list_append_allocated_string(rawptr(rettv.vval), transmute(^u8)(akt.data))
		lnum += 1
	}
	curbuf = save_curbuf
	(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = curbuf
	virtual_op_g = save_virtual
}

// "getregionpos()" function.
@(export)
f_getregionpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	save_curbuf := curbuf
	save_virtual := virtual_op_g
	p1 := Pos_T{}
	p2 := Pos_T{}
	inclusive := true
	region_type: C.int = kMTUnknown
	allow_eol := false
	oa: [88]u8
	libc.memset(&oa[0], 0, 88)
	if getregionpos_o(argvars, rettv, &p1, &p2, &inclusive, &region_type, rawptr(&oa[0])) == FAIL_E {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type == VAR_DICT {
		if tv_dict_get_bool(rawptr(([^]Typval_T)(argvars)[2].vval), cstring("eol"), 0) != 0 {
			allow_eol = true
		}
	}
	lnum := p1.lnum
	for lnum <= p2.lnum {
		ret_p1 := Pos_T{}
		ret_p2 := Pos_T{}
		line := ml_get(lnum)
		line_len := ml_get_len_r2(lnum)
		if region_type == kMTLineWise {
			ret_p1.col = 1
			ret_p1.coladd = 0
			ret_p2.col = MAXCOL
			ret_p2.coladd = 0
		} else {
			bd := Block_Def_O{}
			if region_type == kMTBlockWise {
				block_prep_e(rawptr(&oa[0]), rawptr(&bd), lnum, false)
			} else {
				charwise_block_prep_e(p1, p2, rawptr(&bd), lnum, inclusive)
			}
			if bd.is_oneChar != 0 {
				if region_type == kMTBlockWise {
					ret_p1.col = C.int(uintptr(mb_prevptr_e(line, bd.textstart)) - uintptr(line)) + 1
					ret_p1.coladd = bd.start_char_vcols - (bd.start_vcol - (^C.int)(uintptr(&oa[0]) + OAP_START_VCOL)^)
				} else {
					ret_p1.col = p1.col + 1
					ret_p1.coladd = p1.coladd
				}
			} else if region_type == kMTBlockWise && (^C.int)(uintptr(&oa[0]) + OAP_START_VCOL)^ > bd.start_vcol {
				ret_p1.col = MAXCOL
				ret_p1.coladd = (^C.int)(uintptr(&oa[0]) + OAP_START_VCOL)^ - bd.start_vcol
				bd.is_oneChar = 1
			} else if bd.startspaces > 0 {
				ret_p1.col = C.int(uintptr(mb_prevptr_e(line, bd.textstart)) - uintptr(line)) + 1
				ret_p1.coladd = bd.start_char_vcols - bd.startspaces
			} else {
				ret_p1.col = bd.textcol + 1
				ret_p1.coladd = 0
			}
			if bd.is_oneChar != 0 {
				ret_p2.col = ret_p1.col
				ret_p2.coladd = ret_p1.coladd + bd.startspaces + bd.endspaces
			} else if bd.endspaces > 0 {
				ret_p2.col = bd.textcol + bd.textlen + 1
				ret_p2.coladd = bd.endspaces
			} else {
				ret_p2.col = bd.textcol + bd.textlen
				ret_p2.coladd = 0
			}
		}
		if !allow_eol && ret_p1.col > line_len {
			ret_p1.col = 0
			ret_p1.coladd = 0
		} else if ret_p1.col > line_len + 1 {
			ret_p1.col = line_len + 1
		}
		if !allow_eol && ret_p2.col > line_len {
			if ret_p1.col == 0 {
				ret_p2.col = 0
			} else {
				ret_p2.col = line_len
			}
			ret_p2.coladd = 0
		} else if ret_p2.col > line_len + 1 {
			ret_p2.col = line_len + 1
		}
		ret_p1.lnum = lnum
		ret_p2.lnum = lnum
		add_regionpos_range_o(rettv, ret_p1, ret_p2)
		lnum += 1
	}
	curbuf = save_curbuf
	(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = curbuf
	virtual_op_g = save_virtual
}

// —— Batch 27bq: funcs.c searchpair (FFI fully rewired) ——

// Shared searchpair()/searchpairpos() engine (C-static in funcs.c).
searchpair_cmn_o :: proc "c" (argvars: ^Typval_T, match_pos: ^Pos_T) -> C.int {
	context = runtime.default_context()
	save_p_ws := p_ws_g
	flags: C.int = 0
	retval: C.int = 0
	lnum_stop: C.int = 0
	time_limit: i64 = 0
	nbuf1: [65]u8
	nbuf2: [65]u8
	spat := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	mpat := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &nbuf1[0])
	epat := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 32), &nbuf2[0])
	done := false
	if spat == nil || mpat == nil || epat == nil {
		done = true
	}
	dir: C.int = 0
	if !done {
		dir = get_search_arg_o((^Typval_T)(uintptr(argvars) + 48), &flags)
		if dir == 0 {
			done = true
		} else if ((flags & (SP_END_O | SP_SUBPAT_O)) != 0) || (((flags & SP_NOMOVE_O) != 0) && ((flags & SP_SETPCMARK_O) != 0)) {
			semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars) + 48)))
			done = true
		} else {
			if (flags & SP_REPEAT_O) != 0 {
				p_ws_g = 0
			}
			skip: ^Typval_T = nil
			if ([^]Typval_T)(argvars)[3].v_type == VAR_UNKNOWN || ([^]Typval_T)(argvars)[4].v_type == VAR_UNKNOWN {
				skip = nil
			} else {
				skip = (^Typval_T)(uintptr(argvars) + 64)
				if ([^]Typval_T)(argvars)[5].v_type != VAR_UNKNOWN {
					lnum_stop = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 80), nil))
					if lnum_stop < 0 {
						semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars) + 80)))
						done = true
					} else if ([^]Typval_T)(argvars)[6].v_type != VAR_UNKNOWN {
						time_limit = i64(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 96), nil))
						if time_limit < 0 {
							semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars) + 96)))
							done = true
						}
					}
				}
			}
			if !done {
				retval = do_searchpair(transmute(cstring)(spat), transmute(cstring)(mpat), transmute(cstring)(epat), dir, skip, flags, match_pos, lnum_stop, time_limit)
			}
		}
	}
	p_ws_g = save_p_ws
	return retval
}

// "searchpair()" function.
@(export)
f_searchpair :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(searchpair_cmn_o(argvars, nil)))
}

// "searchpairpos()" function.
@(export)
f_searchpairpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	match_pos := Pos_T{}
	lnum: C.int = 0
	col: C.int = 0
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	if searchpair_cmn_o(argvars, &match_pos) > 0 {
		lnum = match_pos.lnum
		col = match_pos.col
	}
	tv_list_append_number(rawptr(rettv.vval), C.longlong(lnum))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(col))
}

// —— Batch 27bo: funcs.c search engine ——
// (profile_setlimit — PORTED (profile.odin); block removed.)

SP_NOMOVE_O :: 0x01
SP_REPEAT_O :: 0x02
SP_RETCOUNT_O :: 0x04
SP_SETPCMARK_O :: 0x08
SP_START_O :: 0x10
SP_SUBPAT_O :: 0x20
SP_END_O :: 0x40
SP_COLUMN_O :: 0x80
SEARCH_START_O :: 0x100
SEARCH_END_O :: 0x40
SEARCH_COL_O :: 0x1000

// Search flags parser (C-static in funcs.c).
get_search_arg_o :: proc "c" (varp: ^Typval_T, flagsp: ^C.int) -> C.int {
	context = runtime.default_context()
	dir: C.int = 1
	if varp.v_type == VAR_UNKNOWN {
		return 1
	}
	nbuf: [65]u8
	flags := tv_get_string_buf_chk(varp, &nbuf[0])
	if flags == nil {
		return 0
	}
	f := transmute([^]u8)(flags)
	for f[0] != 0 {
		if f[0] == 'b' {
			dir = -1
		} else if f[0] == 'w' {
			p_ws_g = 1
		} else if f[0] == 'W' {
			p_ws_g = 0
		} else {
			mask: C.int = 0
			if flagsp != nil {
				if f[0] == 'c' {
					mask = SP_START_O
				} else if f[0] == 'e' {
					mask = SP_END_O
				} else if f[0] == 'm' {
					mask = SP_RETCOUNT_O
				} else if f[0] == 'n' {
					mask = SP_NOMOVE_O
				} else if f[0] == 'p' {
					mask = SP_SUBPAT_O
				} else if f[0] == 'r' {
					mask = SP_REPEAT_O
				} else if f[0] == 's' {
					mask = SP_SETPCMARK_O
				} else if f[0] == 'z' {
					mask = SP_COLUMN_O
				}
			}
			if mask == 0 {
				semsg(e_invarg2, flags)
				dir = 0
			} else {
				flagsp^ |= mask
			}
		}
		if dir == 0 {
			break
		}
		f = ([^]u8)(uintptr(f) + 1)
	}
	return dir
}

// Shared search()/searchpos() engine (C-static in funcs.c).
search_cmn_o :: proc "c" (argvars: ^Typval_T, match_pos: ^Pos_T, flagsp: ^C.int) -> C.int {
	context = runtime.default_context()
	save_p_ws := p_ws_g
	retval: C.int = 0
	lnum_stop: C.int = 0
	time_limit: i64 = 0
	options: C.int = SEARCH_KEEP_O
	use_skip := false
	pat := tv_get_string((^Typval_T)(uintptr(argvars)))
	dir := get_search_arg_o((^Typval_T)(uintptr(argvars) + 16), flagsp)
	done := false
	if dir == 0 {
		done = true
	}
	flags: C.int = 0
	tm: proftime_T = 0
	sia := searchit_arg_T{}
	pos := Pos_T{}
	save_cursor := Pos_T{}
	firstpos := Pos_T{}
	if !done {
		flags = flagsp^
		if (flags & SP_START_O) != 0 {
			options |= SEARCH_START_O
		}
		if (flags & SP_END_O) != 0 {
			options |= SEARCH_END_O
		}
		if (flags & SP_COLUMN_O) != 0 {
			options |= SEARCH_COL_O
		}
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			lnum_stop = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), nil))
			if lnum_stop < 0 {
				done = true
			} else if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
				time_limit = i64(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 48), nil))
				if time_limit < 0 {
					done = true
				} else {
					use_skip = eval_expr_valid_arg((^Typval_T)(uintptr(argvars) + 64))
				}
			}
		}
	}
	if !done {
		tm = profile_setlimit(C.longlong(time_limit))
		if ((flags & (SP_REPEAT_O | SP_RETCOUNT_O)) != 0) || (((flags & SP_NOMOVE_O) != 0) && ((flags & SP_SETPCMARK_O) != 0)) {
			semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars) + 16)))
			done = true
		}
	}
	if !done {
		save_cursor = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
		pos = save_cursor
		sia.sa_stop_lnum = lnum_stop
		sia.sa_tm = &tm
		patlen := C.size_t(libc.strlen(pat))
		subpatnum: C.int = 0
		for {
			subpatnum = searchit(curwin, curbuf, &pos, nil, Direction(dir), transmute(^u8)(pat), patlen, 1, options, 0, &sia)
			if firstpos.lnum != 0 && pos_equal_o(pos, firstpos) {
				subpatnum = 0
			}
			if subpatnum == 0 || !use_skip {
				break
			}
			if firstpos.lnum == 0 {
				firstpos = pos
			}
			save_wcur := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			err := false
			do_skip := eval_expr_to_bool((^Typval_T)(uintptr(argvars) + 64), &err)
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_wcur
			if err {
				subpatnum = 0
				break
			}
			if !do_skip {
				break
			}
			options &= ~C.int(SEARCH_START_O)
		}
		if subpatnum != 0 {
			if (flags & SP_SUBPAT_O) != 0 {
				retval = subpatnum
			} else {
				retval = pos.lnum
			}
			if (flags & SP_SETPCMARK_O) != 0 {
				setpcmark()
			}
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			if match_pos != nil {
				match_pos.lnum = pos.lnum
				match_pos.col = pos.col + 1
			}
			check_cursor(curwin)
		}
		if (flags & SP_NOMOVE_O) != 0 {
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
		} else {
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
		}
	}
	p_ws_g = save_p_ws
	return retval
}

// "search()" function.
@(export)
f_search :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	flags: C.int = 0
	rettv.vval = transmute(rawptr)(C.longlong(search_cmn_o(argvars, nil, &flags)))
}

// "searchpos()" function.
@(export)
f_searchpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	match_pos := Pos_T{}
	flags: C.int = 0
	n := search_cmn_o(argvars, &match_pos, &flags)
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2 + (1 if (flags & SP_SUBPAT_O) != 0 else 0))
	lnum: C.int = 0
	col: C.int = 0
	if n > 0 {
		lnum = match_pos.lnum
		col = match_pos.col
	}
	tv_list_append_number(rawptr(rettv.vval), C.longlong(lnum))
	tv_list_append_number(rawptr(rettv.vval), C.longlong(col))
	if (flags & SP_SUBPAT_O) != 0 {
		tv_list_append_number(rawptr(rettv.vval), C.longlong(n))
	}
}

// —— Batch 27bl: funcs.c wait() ——
foreign _ {
	@(link_name = "vgetc")
	vgetc_e :: proc "c" () -> C.int ---
	// ui_flush now defined in ui.odin — call directly.
}

// Dummy timer due callback (C-static in funcs.c).
dummy_timer_due_cb_o :: proc "c" (tw: ^TimeWatcher, data: rawptr) {
	context = runtime.default_context()
	if main_loop.closing {
		time_watcher_stop(tw)
		time_watcher_close(tw, dummy_timer_close_cb_o)
	}
}

// Dummy timer close callback (C-static in funcs.c).
dummy_timer_close_cb_o :: proc "c" (tw: ^TimeWatcher, data: rawptr) {
	context = runtime.default_context()
	xfree(rawptr(tw))
}

// "wait(timeout, condition[, interval])" function.
@(export)
f_wait :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER {
		semsg(cstring(E475_VAL_S), cstring("1"))
		return
	}
	if (([^]Typval_T)(argvars)[2].v_type != VAR_NUMBER && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN) || (([^]Typval_T)(argvars)[2].v_type == VAR_NUMBER && transmute(C.longlong)(([^]Typval_T)(argvars)[2].vval) <= 0) {
		semsg(cstring(E475_VAL_S), cstring("3"))
		return
	}
	timeout := C.longlong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval))
	expr := ([^]Typval_T)(argvars)[1]
	interval: C.longlong = 200
	if ([^]Typval_T)(argvars)[2].v_type == VAR_NUMBER {
		interval = transmute(C.longlong)(([^]Typval_T)(argvars)[2].vval)
	}
	tw := (^TimeWatcher)(xmalloc(C.size_t(size_of(TimeWatcher))))
	time_watcher_init(&main_loop, tw, nil)
	tw.events = nil
	time_watcher_start(tw, dummy_timer_due_cb_o, u64(interval), u64(interval))
	argv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	exprval := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	error := false
	called_before := called_emsg
	ui_flush()
	remaining := timeout
	before: u64 = 0
	if remaining > 0 {
		before = os_hrtime()
	}
	for {
		cond := eval_expr_typval(&expr, false, &argv, 0, &exprval) != OK_E || tv_get_number_chk(&exprval, &error) != 0 || called_emsg > called_before || error || got_int
		if cond {
			break
		}
		loop_process_events_q(&main_loop, main_loop.events, i64(remaining))
		if remaining == 0 {
			break
		} else if remaining > 0 {
			now := os_hrtime()
			remaining -= C.longlong((now - before) / 1000000)
			before = now
			if remaining <= 0 {
				break
			}
		}
	}
	if called_emsg > called_before || error {
		rettv.vval = transmute(rawptr)(C.longlong(-3))
	} else if got_int {
		got_int = false
		vgetc_e()
		rettv.vval = transmute(rawptr)(C.longlong(-2))
	} else if tv_get_number_chk(&exprval, &error) != 0 {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
	time_watcher_stop(tw)
	time_watcher_close(tw, dummy_timer_close_cb_o)
}

// —— Batch 27bk: funcs.c sockconnect + stdioopen ——
foreign _ {
	// channel_connect/from_stdio now defined in channel.odin — call directly.
	@(link_name = "on_print")
	on_print_g: Callback_E
}

E905_S :: "E905: Couldn't open stdio channel: %s"
E_CONNFAIL_S :: "connection failed: %s"

// "sockconnect()" function.
@(export)
f_sockconnect :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING || ([^]Typval_T)(argvars)[1].v_type != VAR_STRING {
		emsg(e_invarg)
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_DICT && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		semsg(e_invarg2, cstring("expected dictionary"))
		return
	}
	mode := tv_get_string((^Typval_T)(uintptr(argvars)))
	address := tv_get_string((^Typval_T)(uintptr(argvars) + 16))
	tcp := false
	if libc.strcmp(mode, cstring("tcp")) == 0 {
		tcp = true
	} else if libc.strcmp(mode, cstring("pipe")) == 0 {
		tcp = false
	} else {
		semsg(e_invarg2, cstring("invalid mode"))
		return
	}
	rpc := false
	on_data := CallbackReader_E{}
	if ([^]Typval_T)(argvars)[2].v_type == VAR_DICT {
		opts := rawptr(([^]Typval_T)(argvars)[2].vval)
		if tv_dict_get_number(opts, cstring("rpc")) != 0 {
			rpc = true
		}
		if !tv_dict_get_callback(opts, cstring("on_data"), 7, &on_data.cb) {
			return
		}
		on_data.buffered = tv_dict_get_number(opts, cstring("data_buffered")) != 0
		if on_data.buffered && on_data.cb.type == KCB_NONE_O {
			on_data.self = opts
		}
	}
	err: cstring = nil
	id := channel_connect(tcp, address, rpc, on_data, 50, &err)
	if err != nil {
		semsg(cstring(E_CONNFAIL_S), err)
	}
	rettv.vval = transmute(rawptr)(C.longlong(id))
	rettv.v_type = VAR_NUMBER
}

// "stdioopen()" function.
@(export)
f_stdioopen :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_DICT {
		emsg(e_invarg)
		return
	}
	on_stdin := CallbackReader_E{}
	opts := rawptr(([^]Typval_T)(argvars)[0].vval)
	rpc := tv_dict_get_number(opts, cstring("rpc")) != 0
	if !tv_dict_get_callback(opts, cstring("on_stdin"), 8, &on_stdin.cb) {
		return
	}
	if !tv_dict_get_callback(opts, cstring("on_print"), 8, &on_print_g) {
		return
	}
	on_stdin.buffered = tv_dict_get_number(opts, cstring("stdin_buffered")) != 0
	if on_stdin.buffered && on_stdin.cb.type == KCB_NONE_O {
		on_stdin.self = opts
	}
	err: cstring = nil
	id := channel_from_stdio(rpc, on_stdin, &err)
	if id == 0 {
		semsg(cstring(E905_S), err)
	}
	rettv.vval = transmute(rawptr)(C.longlong(id))
	rettv.v_type = VAR_NUMBER
}

// —— Batch 27bj: funcs.c settagstack ——
foreign _ {
	@(link_name = "set_tagstack")
	set_tagstack_e :: proc "c" (wp: rawptr, d: rawptr, action: C.int) -> C.int ---
}

E962_S :: "E962: Invalid action: '%s'"

// "settagstack()" function.
@(export)
f_settagstack :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	action: u8 = 'r'
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	wp := find_win_by_nr_or_id((^Typval_T)(uintptr(argvars)))
	if wp == nil {
		return
	}
	if tv_check_for_dict_arg(argvars, 1) == FAIL_E {
		return
	}
	d := rawptr(([^]Typval_T)(argvars)[1].vval)
	if d == nil {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type == VAR_UNKNOWN {
	} else if tv_check_for_string_arg(argvars, 2) == FAIL_E {
		return
	} else {
		actstr := tv_get_string_chk((^Typval_T)(uintptr(argvars) + 32))
		if actstr == nil {
			return
		}
		if (([^]u8)(actstr)[0] == 'r' || ([^]u8)(actstr)[0] == 'a' || ([^]u8)(actstr)[0] == 't') && ([^]u8)(actstr)[1] == 0 {
			action = ([^]u8)(actstr)[0]
		} else {
			semsg(cstring(E962_S), actstr)
			return
		}
	}
	if set_tagstack_e(wp, d, C.int(action)) == OK_E {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// —— Batch 27bi: funcs.c spellsuggest ——
foreign _ {
	@(link_name = "spell_suggest_list")
	spell_suggest_list_e :: proc "c" (gap: ^Garray, word: cstring, maxcount: C.int, need_cap: bool, interactive: bool) ---
}

// "spellsuggest()" function.
@(export)
f_spellsuggest :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	ga := Garray{}
	wo_spell_save := w_p_spell_r(curwin)
	if wo_spell_save == 0 {
		parse_spelllang(curwin)
		(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = 1
	}
	done := false
	if ([^]u8)((^rawptr)(uintptr(win_s_r(curwin)) + SB_P_SPL_OFF)^)[0] == 0 {
		emsg(cstring(e_no_spell_txt))
		(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = wo_spell_save
		done = true
	}
	maxcount: C.int = 0
	need_capital := false
	str: cstring = nil
	if !done {
		str = tv_get_string((^Typval_T)(uintptr(argvars)))
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
			typeerr := false
			maxcount = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &typeerr))
			if maxcount <= 0 {
				done = true
			} else if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
				need_capital = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &typeerr) != 0
				if typeerr {
					done = true
				}
			}
		} else {
			maxcount = 25
		}
	}
	if !done {
		spell_suggest_list_e(&ga, transmute(cstring)(str), maxcount, need_capital, false)
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), C.int(ga.ga_len))
	i: C.int = 0
	for i < ga.ga_len {
		p := ([^]rawptr)(ga.ga_data)[i]
		tv_list_append_allocated_string(rawptr(rettv.vval), transmute(^u8)(p))
		i += 1
	}
	ga_clear(&ga)
	(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = wo_spell_save
}

// —— Batch 27bh: funcs.c matchstrlist + matchbufline ——
E681_S :: "E681: Buffer is not loaded"
E475_VAL_S :: "E475: Invalid value for argument %s"

// Match collector shared by matchstrlist()/matchbufline() (C-static).
get_matches_in_str_o :: proc "c" (str: cstring, rmp: ^Regmatch_T, mlist: rawptr, idx: C.int, submatches: bool, matchbuf: bool) {
	context = runtime.default_context()
	length := C.size_t(libc.strlen(str))
	match := false
	startidx: C.int = 0
	for {
		match = vim_regexec_nl_e(rmp, str, startidx)
		if !match {
			break
		}
		d := tv_dict_alloc()
		tv_list_append_dict(mlist, d)
		if matchbuf {
			tv_dict_add_nr(d, cstring("lnum"), 4, C.longlong(idx))
		} else {
			tv_dict_add_nr(d, cstring("idx"), 3, C.longlong(idx))
		}
		tv_dict_add_nr(d, cstring("byteidx"), 7, C.longlong(C.longlong(uintptr(rmp.startp[0]) - uintptr(rawptr(transmute(^u8)(str))))))
		tv_dict_add_str_len(d, cstring("text"), 4, transmute(cstring)(rmp.startp[0]), C.int(uintptr(rmp.endp[0]) - uintptr(rmp.startp[0])))
		if submatches {
			sml := tv_list_alloc(NSUBEXP - 1)
			tv_dict_add_list(d, cstring("submatches"), 10, sml)
			i: C.int = 1
			for i < NSUBEXP {
				if rmp.endp[i] == nil {
					tv_list_append_string(sml, transmute(^u8)(cstring("")), 0)
				} else {
					tv_list_append_string(sml, rmp.startp[i], C.ssize_t(uintptr(rmp.endp[i]) - uintptr(rmp.startp[i])))
				}
				i += 1
			}
		}
		startidx = C.int(uintptr(rmp.endp[0]) - uintptr(rawptr(transmute(^u8)(str))))
		if C.size_t(startidx) >= length || uintptr(rawptr(transmute(^u8)(str))) + uintptr(startidx) <= uintptr(rmp.startp[0]) {
			break
		}
	}
}

// "matchstrlist()" function.
@(export)
f_matchstrlist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	retlist := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	if tv_check_for_list_arg(argvars, 0) == FAIL_E || tv_check_for_string_arg(argvars, 1) == FAIL_E || tv_check_for_opt_dict_arg(argvars, 2) == FAIL_E {
		return
	}
	l: rawptr = nil
	if rawptr(([^]Typval_T)(argvars)[0].vval) == nil {
		return
	}
	l = rawptr(([^]Typval_T)(argvars)[0].vval)
	patbuf: [65]u8
	pat := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
	if pat == nil {
		return
	}
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	regmatch := Regmatch_T{regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O), rm_ic = 0}
	done := false
	if regmatch.regprog == nil {
		done = true
	} else {
		regmatch.rm_ic = p_ic
		submatches := false
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			d := rawptr(([^]Typval_T)(argvars)[2].vval)
			if d != nil {
				di := tv_dict_find(d, cstring("submatches"), 10)
				if di != nil {
					if (^C.int)(uintptr(di))^ != VAR_BOOL {
						semsg(cstring(E475_VAL_S), cstring("submatches"))
						done = true
					} else {
						submatches = tv_get_bool((^Typval_T)(uintptr(di))) != 0
					}
				}
			}
		}
		if !done {
			idx: C.int = 0
			li := tv_list_first_o(l)
			for li != nil {
				li_tv := (^Typval_T)(uintptr(li) + 16)
				if li_tv.v_type == VAR_STRING && rawptr(li_tv.vval) != nil {
					get_matches_in_str_o(transmute(cstring)(li_tv.vval), &regmatch, retlist, idx, submatches, false)
				}
				idx += 1
				li = (^rawptr)(uintptr(li))^
			}
		}
		vim_regfree(regmatch.regprog)
	}
	p_cpo = save_cpo
}

// "matchbufline()" function.
@(export)
f_matchbufline :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	retlist := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	if tv_check_for_buffer_arg(argvars, 0) == FAIL_E || tv_check_for_string_arg(argvars, 1) == FAIL_E || tv_check_for_lnum_arg(argvars, 2) == FAIL_E || tv_check_for_lnum_arg(argvars, 3) == FAIL_E || tv_check_for_opt_dict_arg(argvars, 4) == FAIL_E {
		return
	}
	prev_did_emsg := did_emsg_flag
	buf := tv_get_buf((^Typval_T)(uintptr(argvars)), 0)
	done := false
	if buf == nil {
		if did_emsg_flag == prev_did_emsg {
			semsg(cstring(E158_S), tv_get_string((^Typval_T)(uintptr(argvars))))
		}
		done = true
	} else if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
		emsg(cstring(E681_S))
		done = true
	}
	patbuf: [65]u8
	pat := tv_get_string_buf((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
	did_before := did_emsg_flag
	slnum := tv_get_lnum_buf((^Typval_T)(uintptr(argvars) + 32), buf)
	if !done && did_emsg_flag > did_before {
		done = true
	}
	if !done && slnum < 1 {
		semsg(cstring(E475_VAL_S), cstring("lnum"))
		done = true
	}
	elnum := tv_get_lnum_buf((^Typval_T)(uintptr(argvars) + 48), buf)
	if !done && did_emsg_flag > did_before {
		done = true
	}
	if !done && (elnum < 1 || elnum < slnum) {
		semsg(cstring(E475_VAL_S), cstring("end_lnum"))
		done = true
	}
	if !done {
		linecount := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
		if elnum > linecount {
			elnum = linecount
		}
		submatches := false
		if ([^]Typval_T)(argvars)[4].v_type != VAR_UNKNOWN {
			d := rawptr(([^]Typval_T)(argvars)[4].vval)
			if d != nil {
				di := tv_dict_find(d, cstring("submatches"), 10)
				if di != nil {
					if (^C.int)(uintptr(di))^ != VAR_BOOL {
						semsg(cstring(E475_VAL_S), cstring("submatches"))
						done = true
					} else {
						submatches = tv_get_bool((^Typval_T)(uintptr(di))) != 0
					}
				}
			}
		}
		if !done {
			save_cpo := p_cpo
			p_cpo = empty_string_opt()
			regmatch := Regmatch_T{regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O), rm_ic = 0}
			if regmatch.regprog == nil {
				p_cpo = save_cpo
				return
			}
			regmatch.rm_ic = p_ic
			for slnum <= elnum {
				str := ml_get_buf(buf, slnum)
				get_matches_in_str_o(transmute(cstring)(str), &regmatch, retlist, slnum, submatches, true)
				slnum += 1
			}
			vim_regfree(regmatch.regprog)
			p_cpo = save_cpo
		}
	}
}

// —— Batch 27bg: funcs.c synconcealed + virtcol ——
foreign _ {
	@(link_name = "get_syntax_info")
	get_syntax_info_e :: proc "c" (seqnrp: ^C.int) -> C.int ---
	@(link_name = "syn_get_sub_char")
	syn_get_sub_char_e :: proc "c" () -> C.int ---
	// getvvcol — PORTED (cursor.odin).
}

// "synconcealed(lnum, col)" function.
@(export)
f_synconcealed :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	syntax_flags: C.int = 0
	matchid: C.int = 0
	str: [65]u8
	libc.memset(&str[0], 0, 65)
	tv_list_set_ret_o(rettv, nil)
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	col := C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16))) - 1
	if lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ && col >= 0 && col <= ml_get_len_r2(lnum) && (^C.int)(uintptr(curwin) + W_P_COLE_OFF)^ > 0 {
		syn_get_id_r(curwin, lnum, col, false, nil, false)
		syntax_flags = get_syntax_info_e(&matchid)
		if (syntax_flags & HL_CONCEAL_O) != 0 && (^C.int)(uintptr(curwin) + W_P_COLE_OFF)^ < 3 {
			cchar := schar_from_char(syn_get_sub_char_e())
			if cchar == 0 && (^C.int)(uintptr(curwin) + W_P_COLE_OFF)^ == 1 {
				conceal := (^u32)(uintptr(curwin) + W_P_LCS_CHARS_OFF + LCS_CONCEAL_OFF)^
				if conceal == 0 {
					cchar = 32
				} else {
					cchar = conceal
				}
			}
			if cchar != 0 {
				schar_get(&str[0], cchar)
			}
		}
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), 3)
	if (syntax_flags & HL_CONCEAL_O) != 0 {
		tv_list_append_number(rawptr(rettv.vval), C.longlong(1))
	} else {
		tv_list_append_number(rawptr(rettv.vval), C.longlong(0))
	}
	tv_list_append_string(rawptr(rettv.vval), &str[0], -1)
	tv_list_append_number(rawptr(rettv.vval), C.longlong(matchid))
}

// "virtcol({expr}, [, {list} [, {winid}]])" function.
@(export)
f_virtcol :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	vcol_start: C.int = 0
	vcol_end: C.int = 0
	wp := curwin
	theend := false
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		tp: rawptr = nil
		wp = win_id2wp_tp(C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 32))), &tp)
		if wp == nil || tp == nil {
			theend = true
		} else {
			check_cursor(wp)
		}
	}
	if !theend {
		bp := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		fnum := (^C.int)(uintptr(bp) + B_FNUM_OFF)^
		fp := var2fpos((^Typval_T)(uintptr(argvars)), false, &fnum, false, wp)
		if fp != nil && (^C.int)(uintptr(fp))^ <= (^C.int)(uintptr(bp) + B_ML_LINE_COUNT)^ && fnum == (^C.int)(uintptr(bp) + B_FNUM_OFF)^ {
			if (^C.int)(uintptr(fp) + 4)^ < 0 {
				(^C.int)(uintptr(fp) + 4)^ = 0
			} else {
				length := ml_get_buf_len(bp, (^C.int)(uintptr(fp))^)
				if (^C.int)(uintptr(fp) + 4)^ > length {
					(^C.int)(uintptr(fp) + 4)^ = length
				}
			}
			getvvcol(wp, (^Pos_T)(fp), &vcol_start, nil, &vcol_end, 0)
			vcol_start += 1
			vcol_end += 1
		}
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && tv_get_bool((^Typval_T)(uintptr(argvars) + 16)) != 0 {
			tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
			tv_list_append_number(rawptr(rettv.vval), C.longlong(vcol_start))
			tv_list_append_number(rawptr(rettv.vval), C.longlong(vcol_end))
		} else {
			rettv.vval = transmute(rawptr)(C.longlong(vcol_end))
		}
	}
}

// —— Batch 27bc: funcs.c timer cluster (FFI removed, exports below) ——

TIMER_TW_OFF :: 0
TIMER_REFCOUNT_OFF :: 200
TIMER_TIMEOUT_OFF :: 208
TIMER_STOPPED_OFF :: 216
TIMER_PAUSED_OFF :: 217
E39_S :: "E39: Number expected"

// "timer_start()" function.
@(export)
f_timer_start :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	repeat: C.int = 1
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		if tv_check_for_nonnull_dict_arg(argvars, 2) == FAIL_E {
			return
		}
		d := rawptr(([^]Typval_T)(argvars)[2].vval)
		di := tv_dict_find(d, cstring("repeat"), 6)
		if di != nil {
			repeat = C.int(tv_get_number((^Typval_T)(uintptr(di))))
			if repeat == 0 {
				repeat = 1
			}
		}
	}
	callback := Callback_E{}
	if !callback_from_typval(&callback, (^Typval_T)(uintptr(argvars) + 16)) {
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(timer_start(tv_get_number((^Typval_T)(uintptr(argvars))), repeat, &callback)))
}

// "timer_stop(timerid)" function.
@(export)
f_timer_stop :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if tv_check_for_number_arg(argvars, 0) == FAIL_E {
		return
	}
	timer := find_timer_by_nr(tv_get_number((^Typval_T)(uintptr(argvars))))
	if timer == nil {
		return
	}
	timer_stop(timer)
}

// "timer_stopall()" function.
@(export)
f_timer_stopall :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	timer_stop_all()
}

// "timer_pause(timer, paused)" function.
@(export)
f_timer_pause :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER {
		emsg(cstring(E39_S))
		return
	}
	paused := tv_get_number((^Typval_T)(uintptr(argvars) + 16)) != 0
	timer := find_timer_by_nr(tv_get_number((^Typval_T)(uintptr(argvars))))
	if timer != nil {
		if !(^bool)(uintptr(timer) + TIMER_PAUSED_OFF)^ && paused {
			time_watcher_stop((^TimeWatcher)(uintptr(timer) + TIMER_TW_OFF))
		} else if (^bool)(uintptr(timer) + TIMER_PAUSED_OFF)^ && !paused {
			timeout := (^i64)(uintptr(timer) + TIMER_TIMEOUT_OFF)^
			time_watcher_start((^TimeWatcher)(uintptr(timer) + TIMER_TW_OFF), timer_due_cb, u64(timeout), u64(timeout))
		}
		(^bool)(uintptr(timer) + TIMER_PAUSED_OFF)^ = paused
	}
}

// "timer_info([timer])" function.
@(export)
f_timer_info :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	if tv_check_for_opt_number_arg(argvars, 0) == FAIL_E {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		timer := find_timer_by_nr(tv_get_number((^Typval_T)(uintptr(argvars))))
		if timer != nil && (!(^bool)(uintptr(timer) + TIMER_STOPPED_OFF)^ || (^C.int)(uintptr(timer) + TIMER_REFCOUNT_OFF)^ > 1) {
			add_timer_info(rettv, timer)
		}
	} else {
		add_timer_info_all(rettv)
	}
}

// —— Batch 27bb: funcs.c swapinfo cluster ——
foreign _ {
	@(link_name = "recover_names")
	recover_names_e :: proc "c" (fname: cstring, skip_curbuf: bool, ret_list: rawptr) ---
	@(link_name = "swapfile_dict")
	swapfile_dict_e :: proc "c" (fname: cstring, d: rawptr) ---
}

// "swapfilelist()" function.
@(export)
f_swapfilelist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	l := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	recover_names_e(nil, false, l)
}

// "swapinfo(swap_filename)" function.
@(export)
f_swapinfo :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(rettv)
	swapfile_dict_e(tv_get_string((^Typval_T)(uintptr(argvars))), rawptr(rettv.vval))
}

// "swapname(expr)" function.
@(export)
f_swapname :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	buf := tv_get_buf((^Typval_T)(uintptr(argvars)), 0)
	if buf == nil {
		rettv.vval = transmute(rawptr)(cstring(nil))
		return
	}
	mfp := (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^
	if mfp == nil {
		rettv.vval = transmute(rawptr)(cstring(nil))
		return
	}
	fname := (^cstring)(uintptr(mfp))^
	if fname == nil {
		rettv.vval = transmute(rawptr)(cstring(nil))
		return
	}
	rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(fname)))
}

// —— Batch 27as: funcs.c serverlist + serverstop ——
foreign _ {
	@(link_name = "server_address_list")
	server_address_list_e :: proc "c" (size: ^C.size_t) -> [^]cstring ---
	@(link_name = "server_stop")
	server_stop_e :: proc "c" (endpoint: cstring, keep_vservername: bool) -> bool ---
	@(link_name = "nlua_call_typval")
	nlua_call_typval_e :: proc "c" (module: cstring, func: cstring, argvars: ^Typval_T, rettv: ^Typval_T) ---
}

// "serverlist()" function.
@(export)
f_serverlist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n: C.size_t = 0
	addrs := server_address_list_e(&n)
	addrs_tv := Typval_T{}
	tv_list_alloc_ret(transmute(^Typval)(&addrs_tv), C.int(n))
	i: C.size_t = 0
	for i < n {
		tv_list_append_allocated_string(rawptr(addrs_tv.vval), transmute(^u8)(addrs[i]))
		i += 1
	}
	xfree(rawptr(addrs))
	opts := ([^]Typval_T)(argvars)[0]
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		opts = Typval_T{v_type = VAR_SPECIAL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(KSPECIALVARNULL_O))}
	}
	lua_args: [3]Typval_T
	lua_args[0] = opts
	lua_args[1] = addrs_tv
	lua_args[2] = Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	nlua_call_typval_e(cstring("vim._core.server"), cstring("serverlist"), &lua_args[0], rettv)
	tv_clear(&addrs_tv)
}

// "serverstop()" function.
@(export)
f_serverstop :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING {
		emsg(e_invarg)
		return
	}
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if rawptr(([^]Typval_T)(argvars)[0].vval) != nil {
		if server_stop_e(transmute(cstring)(([^]Typval_T)(argvars)[0].vval), false) {
			rettv.vval = transmute(rawptr)(C.longlong(1))
		}
	}
}

// —— Batch 27bn: funcs.c searchdecl ——
foreign _ {
	@(link_name = "find_decl")
	find_decl_e :: proc "c" (ptr: cstring, len: C.size_t, locally: bool, thisblock: bool, flags_arg: C.int) -> bool ---
}

SEARCH_KEEP_O :: 0x400

// "searchdecl()" function.
@(export)
f_searchdecl :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	locally := true
	thisblock := false
	error := false
	rettv.vval = transmute(rawptr)(C.longlong(1))
	name := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		locally = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error) == 0
		if !error && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			thisblock = tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &error) != 0
		}
	}
	if !error && name != nil {
		if find_decl_e(transmute(cstring)(name), C.size_t(libc.strlen(name)), locally, thisblock, SEARCH_KEEP_O) {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		}
	}
}

// —— Batch 27bm: funcs.c serverstart ——
foreign _ {
	@(link_name = "server_address_new")
	server_address_new_e :: proc "c" (name: cstring) -> cstring ---
	@(link_name = "server_start")
	server_start_e :: proc "c" (addr: cstring) -> C.int ---
}

E_SRVFAIL_S :: "Failed to start server: %s"
E_UNKERR_S :: "Unknown system error"

// "serverstart()" function.
@(export)
f_serverstart :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	if check_secure() {
		return
	}
	address: cstring = nil
	if ([^]Typval_T)(argvars)[0].v_type != VAR_UNKNOWN {
		if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING {
			emsg(e_invarg)
			return
		}
		address = transmute(cstring)(xstrdup_o(transmute(^u8)(tv_get_string((^Typval_T)(uintptr(argvars))))))
	} else {
		address = server_address_new_e(nil)
	}
	result := server_start_e(address)
	xfree(rawptr(transmute(^u8)(address)))
	if result != 0 {
		if result > 0 {
			semsg(cstring(E_SRVFAIL_S), cstring(E_UNKERR_S))
		} else {
			semsg(cstring(E_SRVFAIL_S), os_strerror(result))
		}
		return
	}
	n: C.size_t = 0
	addrs := server_address_list_e(&n)
	rettv.vval = transmute(rawptr)(addrs[n - 1])
	i: C.size_t = 0
	for i < n - 1 {
		xfree(rawptr(transmute(^u8)(addrs[i])))
		i += 1
	}
	xfree(rawptr(addrs))
}

// —— Batch 27bf: funcs.c synIDattr ——
foreign _ {
	@(link_name = "highlight_has_attr")
	highlight_has_attr_e :: proc "c" (id: C.int, flag: C.int, modec: C.int) -> cstring ---
	@(link_name = "highlight_color")
	highlight_color_e :: proc "c" (id: C.int, what: cstring, modec: C.int) -> cstring ---
	@(link_name = "get_highlight_name_ext")
	get_highlight_name_ext_e :: proc "c" (xp: rawptr, idx: C.int, skip_cleared: bool) -> cstring ---
}

HL_INVERSE_O :: 0x01
HL_BOLD_O :: 0x02
HL_ITALIC_O :: 0x04
HL_UNDERLINE_O :: 0x08
HL_UNDERCURL_O :: 0x10
HL_UNDERDOUBLE_O :: 0x18
HL_UNDERDOTTED_O :: 0x20
HL_UNDERDASHED_O :: 0x28
HL_STANDOUT_O :: 0x40
HL_STRIKETHROUGH_O :: 0x80
HL_DIM_O :: 0x200
HL_NOCOMBINE_O :: 0x400
HL_BLINK_O :: 0x8000
HL_CONCEALED_O :: 0x10000
HL_OVERLINE_O :: 0x20000

// TOLOWER_ASC mirror (ascii_defs.h).
tolower_asc_o :: #force_inline proc "c" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

// "synIDattr(id, what [, mode])" function.
@(export)
f_synIDattr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	id := C.int(tv_get_number((^Typval_T)(uintptr(argvars))))
	what := tv_get_string((^Typval_T)(uintptr(argvars) + 16))
	modec: C.int = 0
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		modebuf: [65]u8
		mode := tv_get_string_buf((^Typval_T)(uintptr(argvars) + 32), &modebuf[0])
		modec = C.int(tolower_asc_o(([^]u8)(mode)[0]))
		if modec != 'c' && modec != 'g' {
			modec = 0
		}
	} else if ui_rgb_attached() {
		modec = 'g'
	} else {
		modec = 'c'
	}
	w := ([^]u8)(what)
	p: cstring = nil
	if tolower_asc_o(w[0]) == 'b' {
		if tolower_asc_o(w[1]) == 'g' {
			p = highlight_color_e(id, what, modec)
		} else if tolower_asc_o(w[1]) == 'l' {
			p = highlight_has_attr_e(id, HL_BLINK_O, modec)
		} else {
			p = highlight_has_attr_e(id, HL_BOLD_O, modec)
		}
	} else if tolower_asc_o(w[0]) == 'c' {
		p = highlight_has_attr_e(id, HL_CONCEALED_O, modec)
	} else if tolower_asc_o(w[0]) == 'd' {
		p = highlight_has_attr_e(id, HL_DIM_O, modec)
	} else if tolower_asc_o(w[0]) == 'o' {
		p = highlight_has_attr_e(id, HL_OVERLINE_O, modec)
	} else if tolower_asc_o(w[0]) == 'f' {
		p = highlight_color_e(id, what, modec)
	} else if tolower_asc_o(w[0]) == 'i' {
		if tolower_asc_o(w[1]) == 'n' {
			p = highlight_has_attr_e(id, HL_INVERSE_O, modec)
		} else {
			p = highlight_has_attr_e(id, HL_ITALIC_O, modec)
		}
	} else if tolower_asc_o(w[0]) == 'n' {
		if tolower_asc_o(w[1]) == 'o' {
			p = highlight_has_attr_e(id, HL_NOCOMBINE_O, modec)
		} else {
			p = get_highlight_name_ext_e(nil, id - 1, false)
		}
	} else if tolower_asc_o(w[0]) == 'r' {
		p = highlight_has_attr_e(id, HL_INVERSE_O, modec)
	} else if tolower_asc_o(w[0]) == 's' {
		if tolower_asc_o(w[1]) == 'p' {
			p = highlight_color_e(id, what, modec)
		} else if tolower_asc_o(w[1]) == 't' && tolower_asc_o(w[2]) == 'r' {
			p = highlight_has_attr_e(id, HL_STRIKETHROUGH_O, modec)
		} else {
			p = highlight_has_attr_e(id, HL_STANDOUT_O, modec)
		}
	} else if tolower_asc_o(w[0]) == 'u' {
		if C.size_t(libc.strlen(what)) >= 9 {
			if tolower_asc_o(w[5]) == 'l' {
				p = highlight_has_attr_e(id, HL_UNDERLINE_O, modec)
			} else if tolower_asc_o(w[5]) != 'd' {
				p = highlight_has_attr_e(id, HL_UNDERCURL_O, modec)
			} else if tolower_asc_o(w[6]) != 'o' {
				p = highlight_has_attr_e(id, HL_UNDERDASHED_O, modec)
			} else if tolower_asc_o(w[7]) == 'u' {
				p = highlight_has_attr_e(id, HL_UNDERDOUBLE_O, modec)
			} else {
				p = highlight_has_attr_e(id, HL_UNDERDOTTED_O, modec)
			}
		} else {
			p = highlight_color_e(id, what, modec)
		}
	}
	rettv.v_type = VAR_STRING
	if p == nil {
		rettv.vval = transmute(rawptr)(cstring(nil))
	} else {
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(p)))
	}
}

// —— Batch 27be: funcs.c jobpid + jobresize ——
CHAN_STREAM_OFF :: 32
PROC_PID_OFF :: 24
PROC_TYPE_OFF :: 0
KPROCTYPE_PTY_O :: 1
E904_S :: "E904: channel is not a pty"

// "jobpid(id)" function.
@(export)
f_jobpid :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER {
		emsg(e_invarg)
		return
	}
	data := find_job(C.ulonglong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval)), true)
	if data == nil {
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong((^C.int)(uintptr(data) + CHAN_STREAM_OFF + PROC_PID_OFF)^))
}

// "jobresize(job, width, height)" function.
@(export)
f_jobresize :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER || ([^]Typval_T)(argvars)[1].v_type != VAR_NUMBER || ([^]Typval_T)(argvars)[2].v_type != VAR_NUMBER {
		emsg(e_invarg)
		return
	}
	data := find_job(C.ulonglong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval)), true)
	if data == nil {
		return
	}
	if (^C.int)(uintptr(data) + CHAN_STREAM_OFF + PROC_TYPE_OFF)^ != KPROCTYPE_PTY_O {
		emsg(cstring(E904_S))
		return
	}
	av1 := ([^]Typval_T)(argvars)[1]
	av2 := ([^]Typval_T)(argvars)[2]
	w := C.ushort(C.int(transmute(C.longlong)(av1.vval)))
	h := C.ushort(C.int(transmute(C.longlong)(av2.vval)))
	pty_proc_resize((^PtyProc)(rawptr(uintptr(data) + CHAN_STREAM_OFF)), w, h)
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// —— Batch 27bd: funcs.c rpcnotify ——
foreign _ {
	@(link_name = "rpc_send_event")
	rpc_send_event_e :: proc "c" (id: C.ulonglong, name: cstring, args: Api_Array) -> bool ---
}

// "rpcnotify()" function.
@(export)
f_rpcnotify :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER || transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval) < 0 {
		semsg(e_invarg2, cstring("Channel id must be a positive integer"))
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type != VAR_STRING {
		semsg(e_invarg2, cstring("Event type must be a string"))
		return
	}
	items: [MAX_FUNC_ARGS_O]Api_Object
	args := Api_Array{size = 0, capacity = MAX_FUNC_ARGS_O, items = (^Api_Object)(&items[0])}
	arena := Arena_O{}
	tv := (^Typval_T)(uintptr(argvars) + 32)
	for tv.v_type != VAR_UNKNOWN {
		([^]Api_Object)(args.items)[args.size] = vim_to_object_e(tv, rawptr(&arena), true)
		args.size += 1
		tv = (^Typval_T)(uintptr(tv) + 16)
	}
	ok := rpc_send_event_e(C.ulonglong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval)), tv_get_string((^Typval_T)(uintptr(argvars) + 16)), args)
	arena_mem_free(arena_finish(rawptr(&arena)))
	if !ok {
		semsg(e_invarg2, cstring("Channel doesn't exist"))
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// —— Batch 27av: funcs.c strftime + strptime ——
foreign _ {
	@(link_name = "enc_locale")
	enc_locale_e :: proc "c" () -> cstring ---
	@(link_name = "convert_setup")
	convert_setup_e :: proc "c" (vcp: rawptr, from: cstring, to: cstring) -> C.int ---
	@(link_name = "mktime")
	mktime_e :: proc "c" (tm: ^posix.tm) -> posix.time_t ---
}

CONV_NONE_O :: 0

// vimconv_T mirror (mbyte_defs.h): 24B.
Vimconv_T :: struct {
	vc_type:   C.int,  // 0
	vc_factor: C.int,  // 4
	vc_fd:     rawptr, // 8
	vc_fail:   bool,   // 16
	_pad:      [7]u8,
}
#assert(size_of(Vimconv_T) == 24)

// "strftime({format}[, {time}])" function.
@(export)
f_strftime :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	p := tv_get_string((^Typval_T)(uintptr(argvars)))
	seconds: posix.time_t = 0
	if ([^]Typval_T)(argvars)[1].v_type == VAR_UNKNOWN {
		seconds = posix.time_t(libc.time(nil))
	} else {
		seconds = posix.time_t(tv_get_number((^Typval_T)(uintptr(argvars) + 16)))
	}
	curtime: posix.tm
	curtime_ptr := os_localtime_r(&seconds, &curtime)
	if curtime_ptr == nil {
		rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring("(Invalid)"))))
		return
	}
	conv := Vimconv_T{vc_type = CONV_NONE_O}
	enc := enc_locale_e()
	convert_setup_e(rawptr(&conv), transmute(cstring)(p_enc), enc)
	if conv.vc_type != CONV_NONE_O {
		p = transmute(cstring)(string_convert_e(rawptr(&conv), p, nil))
	}
	result_buf: [256]u8
	if p == nil || libc.strftime(transmute([^]u8)(&result_buf[0]), 256, p, transmute(^libc.tm)(curtime_ptr)) == 0 {
		result_buf[0] = 0
	}
	if conv.vc_type != CONV_NONE_O {
		xfree(rawptr(transmute(^u8)(p)))
	}
	convert_setup_e(rawptr(&conv), enc, transmute(cstring)(p_enc))
	if conv.vc_type != CONV_NONE_O {
		rettv.vval = transmute(rawptr)(string_convert_e(rawptr(&conv), transmute(cstring)(&result_buf[0]), nil))
	} else {
		rettv.vval = transmute(rawptr)(xstrdup_o(&result_buf[0]))
	}
	convert_setup_e(rawptr(&conv), nil, nil)
	xfree(rawptr(enc))
}

// "strptime({format}, {timestring})" function.
@(export)
f_strptime :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	fmtbuf: [65]u8
	strbuf: [65]u8
	tmval: posix.tm
	libc.memset(&tmval, 0, size_of(posix.tm))
	tmval.tm_isdst = -1
	fmt := tv_get_string_buf((^Typval_T)(uintptr(argvars)), &fmtbuf[0])
	str := tv_get_string_buf((^Typval_T)(uintptr(argvars) + 16), &strbuf[0])
	conv := Vimconv_T{vc_type = CONV_NONE_O}
	enc := enc_locale_e()
	convert_setup_e(rawptr(&conv), transmute(cstring)(p_enc), enc)
	if conv.vc_type != CONV_NONE_O {
		fmt = transmute(cstring)(string_convert_e(rawptr(&conv), fmt, nil))
	}
	if fmt == nil || os_strptime(str, fmt, &tmval) == nil {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	} else {
		t := C.longlong(mktime_e(&tmval))
		if t == -1 {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		} else {
			rettv.vval = transmute(rawptr)(t)
		}
	}
	if conv.vc_type != CONV_NONE_O {
		xfree(rawptr(transmute(^u8)(fmt)))
	}
	convert_setup_e(rawptr(&conv), nil, nil)
	xfree(rawptr(enc))
}

// —— Batch 27az: funcs.c synID + tabpagebuflist ——
foreign _ {
	@(link_name = "syn_get_final_id")
	syn_get_final_id_e :: proc "c" (hl_id: C.int) -> C.int ---
	@(link_name = "syn_get_stack_item")
	syn_get_stack_item_e :: proc "c" (i: C.int) -> C.int ---
}

// "synID()" function.
@(export)
f_synID :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	col := C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16))) - 1
	transerr := false
	trans := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 32), &transerr))
	id: C.int = 0
	if !transerr && lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ && col >= 0 && col < ml_get_len_r2(lnum) {
		id = syn_get_id_r(curwin, lnum, col, trans != 0, nil, false)
	}
	rettv.vval = transmute(rawptr)(C.longlong(id))
}

// "synIDtrans()" function.
@(export)
f_synIDtrans :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	id := C.int(tv_get_number((^Typval_T)(uintptr(argvars))))
	if id > 0 {
		id = syn_get_final_id_e(id)
	} else {
		id = 0
	}
	rettv.vval = transmute(rawptr)(C.longlong(id))
}

// "synstack()" function.
@(export)
f_synstack :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_list_set_ret_o(rettv, nil)
	lnum := tv_get_lnum((^Typval_T)(uintptr(argvars)))
	col := C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 16))) - 1
	if lnum >= 1 && lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ && col >= 0 && col <= ml_get_len_r2(lnum) {
		tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
		syn_get_id_r(curwin, lnum, col, false, nil, true)
		id: C.int = 0
		i: C.int = 0
		for {
			id = syn_get_stack_item_e(i)
			i += 1
			if id < 0 {
				break
			}
			tv_list_append_number(rawptr(rettv.vval), C.longlong(id))
		}
	}
}

// "tabpagebuflist()" function.
@(export)
f_tabpagebuflist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	wp: rawptr = nil
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		wp = firstwin
	} else {
		tp := find_tabpage(C.int(tv_get_number((^Typval_T)(uintptr(argvars)))))
		if tp != nil {
			if tp == curtab {
				wp = firstwin
			} else {
				wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			}
		}
	}
	if wp != nil {
		tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
		for wp != nil {
			buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
			tv_list_append_number(rawptr(rettv.vval), C.longlong((^C.int)(uintptr(buf) + B_FNUM_OFF)^))
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
}

// —— Batch 27aw: funcs.c submatch + substitute ——
foreign _ {
	@(link_name = "reg_submatch")
	reg_submatch_e :: proc "c" (no: C.int) -> cstring ---
	@(link_name = "reg_submatch_list")
	reg_submatch_list_e :: proc "c" (no: C.int) -> rawptr ---
}

E935_S :: "E935: Invalid submatch number: %d"

// typval.h static inline.
tv_is_func_o :: proc "c" (tv: Typval_T) -> bool {
	context = runtime.default_context()
	return tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL
}

// "submatch()" function.
@(export)
f_submatch :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	error := false
	no := C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars)), &error))
	if error {
		return
	}
	if no < 0 || no >= NSUBEXP {
		semsg(cstring(E935_S), no)
		return
	}
	retList: C.int = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		retList = C.int(tv_get_number_chk((^Typval_T)(uintptr(argvars) + 16), &error))
		if error {
			return
		}
	}
	if retList == 0 {
		rettv.v_type = VAR_STRING
		rettv.vval = transmute(rawptr)(reg_submatch_e(no))
	} else {
		rettv.v_type = VAR_LIST
		rettv.vval = transmute(rawptr)(reg_submatch_list_e(no))
	}
}

// "substitute()" function.
@(export)
f_substitute :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	patbuf: [65]u8
	subbuf: [65]u8
	flagsbuf: [65]u8
	str := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	pat := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
	sub: cstring = nil
	flg := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 48), &flagsbuf[0])
	expr: ^Typval_T = nil
	if tv_is_func_o(([^]Typval_T)(argvars)[2]) {
		expr = (^Typval_T)(uintptr(argvars) + 32)
	} else {
		sub = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 32), &subbuf[0])
	}
	rettv.v_type = VAR_STRING
	if str == nil || pat == nil || (sub == nil && expr == nil) || flg == nil {
		rettv.vval = transmute(rawptr)(cstring(nil))
	} else {
		rettv.vval = transmute(rawptr)(do_string_sub(transmute(cstring)(str), C.size_t(libc.strlen(str)), transmute(cstring)(pat), transmute(cstring)(sub), expr, flg, nil))
	}
}

// —— Batch 27ax: funcs.c split() ——

// "split()" function.
@(export)
f_split :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	col: C.int = 0
	keepempty := false
	typeerr := false
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	str := transmute([^]u8)(tv_get_string((^Typval_T)(uintptr(argvars))))
	pat: cstring = nil
	patbuf: [65]u8
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		pat = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
		if pat == nil {
			typeerr = true
		}
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			keepempty = tv_get_bool_chk((^Typval_T)(uintptr(argvars) + 32), &typeerr) != 0
		}
	}
	if pat == nil || ([^]u8)(pat)[0] == 0 {
		pat = cstring("[\\x01- ]\\+")
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	done := typeerr
	if !done {
		regmatch := Regmatch_T{regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O), rm_ic = 0}
		if regmatch.regprog != nil {
			for str[0] != 0 || keepempty {
				match := false
				if str[0] == 0 {
					match = false
				} else {
					match = vim_regexec_nl_e(&regmatch, transmute(cstring)(str), col)
				}
				end := str
				if match {
					end = transmute([^]u8)(regmatch.startp[0])
				} else {
					end = ([^]u8)(uintptr(str) + uintptr(libc.strlen(transmute(cstring)(str))))
				}
				if keepempty || uintptr(end) > uintptr(str) || (tv_list_len_o(rawptr(rettv.vval)) > 0 && str[0] != 0 && match && uintptr(end) < uintptr(regmatch.endp[0])) {
					tv_list_append_string(rawptr(rettv.vval), str, C.ssize_t(uintptr(end) - uintptr(str)))
				}
				if !match {
					break
				}
				if uintptr(regmatch.endp[0]) > uintptr(str) {
					col = 0
				} else {
					col = utfc_ptr2len(transmute(cstring)(regmatch.endp[0]))
				}
				str = transmute([^]u8)(regmatch.endp[0])
			}
			vim_regfree(regmatch.regprog)
		}
	}
	p_cpo = save_cpo
}

// —— Batch 27au: funcs.c stdpath + str2float (FFI fully rewired) ——

E6100_S :: "E6100: \"%s\" is not a valid stdpath"

// XDG dir-list builder (C-static in funcs.c).
get_xdg_var_list_o :: proc "c" (xdg: C.int, rettv: ^Typval_T) {
	context = runtime.default_context()
	list := tv_list_alloc(-2)
	rettv.v_type = VAR_LIST
	rettv.vval = transmute(rawptr)(list)
	tv_list_ref_o(list)
	dirs := stdpaths_get_xdg_var(xdg)
	if dirs == nil {
		return
	}
	iter: rawptr = nil
	appname := get_appname(false)
	for {
		dir_len: C.size_t = 0
		dir: cstring = nil
		iter = vim_env_iter(':', dirs, iter, &dir, &dir_len)
		if dir != nil && dir_len > 0 {
			dir_with_nvim := concat_paths(transmute(cstring)(xmemdupz_o2(transmute(^u8)(dir), dir_len)), appname, true)
			tv_list_append_allocated_string(list, transmute(^u8)(dir_with_nvim))
		}
		if iter == nil {
			break
		}
	}
	xfree(rawptr(dirs))
}

// "stdpath(type)" function.
@(export)
f_stdpath :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	p := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
	if p == nil {
		return
	}
	if strequal(p, cstring("config")) {
		rettv.vval = transmute(rawptr)(get_xdg_home(C.int(XDGVarType.kXDGConfigHome)))
	} else if strequal(p, cstring("data")) {
		rettv.vval = transmute(rawptr)(get_xdg_home(C.int(XDGVarType.kXDGDataHome)))
	} else if strequal(p, cstring("cache")) {
		rettv.vval = transmute(rawptr)(get_xdg_home(C.int(XDGVarType.kXDGCacheHome)))
	} else if strequal(p, cstring("state")) {
		rettv.vval = transmute(rawptr)(get_xdg_home(C.int(XDGVarType.kXDGStateHome)))
	} else if strequal(p, cstring("log")) {
		rettv.vval = transmute(rawptr)(concat_paths(get_xdg_home(C.int(XDGVarType.kXDGStateHome)), cstring("logs"), true))
	} else if strequal(p, cstring("run")) {
		rettv.vval = transmute(rawptr)(stdpaths_get_xdg_var(C.int(XDGVarType.kXDGRuntimeDir)))
	} else if strequal(p, cstring("config_dirs")) {
		get_xdg_var_list_o(C.int(XDGVarType.kXDGConfigDirs), rettv)
	} else if strequal(p, cstring("data_dirs")) {
		get_xdg_var_list_o(C.int(XDGVarType.kXDGDataDirs), rettv)
	} else {
		semsg(cstring(E6100_S), p)
	}
}

// "str2float()" function.
@(export)
f_str2float :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	p := skipwhite(tv_get_string((^Typval_T)(uintptr(argvars))))
	isneg := ([^]u8)(p)[0] == '-'
	if ([^]u8)(p)[0] == '+' || ([^]u8)(p)[0] == '-' {
		p = skipwhite(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1)))
	}
	f: f64 = 0
	string2float(p, &f)
	rettv.vval = transmute(rawptr)(f)
	if isneg {
		rettv.vval = transmute(rawptr)(-f)
	}
	rettv.v_type = VAR_FLOAT
}

// —— Batch 27at: funcs.c visualmode/wildmenumode/windowsversion/wordcount/perleval/rubyeval ——
foreign _ {
	@(link_name = "wild_menu_showing")
	wild_menu_showing_g: C.int
	@(link_name = "cmdline_pum_active")
	cmdline_pum_active_e :: proc "c" () -> bool ---
	@(link_name = "windowsVersion")
	windowsVersion_g: [20]u8
	@(link_name = "cursor_pos_info")
	cursor_pos_info_e :: proc "c" (dict: rawptr) ---
}

B_VISUAL_MODE_EVAL :: 1456

// "visualmode()" function.
@(export)
f_visualmode :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	mode := u8((^C.int)(uintptr(curbuf) + B_VISUAL_MODE_EVAL)^)
	buf: [2]u8
	buf[0] = mode
	buf[1] = 0
	rettv.vval = transmute(rawptr)(xstrdup_o(&buf[0]))
	if non_zero_arg_o(argvars) {
		(^C.int)(uintptr(curbuf) + B_VISUAL_MODE_EVAL)^ = 0
	}
}

// "wildmenumode()" function.
@(export)
f_wildmenumode :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if wild_menu_showing_g != 0 || ((State & MODE_CMDLINE_O) != 0 && cmdline_pum_active_e()) {
		rettv.vval = transmute(rawptr)(C.longlong(1))
	}
}

// "windowsversion()" function.
@(export)
f_windowsversion :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(xstrdup_o(&windowsVersion_g[0]))
}

// "wordcount()" function.
@(export)
f_wordcount :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	tv_dict_alloc_ret(rettv)
	cursor_pos_info_e(rawptr(rettv.vval))
}

// "perleval()" function.
@(export)
f_perleval :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	script_host_eval(cstring("perl"), argvars, rettv)
}

// "rubyeval()" function.
@(export)
f_rubyeval :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	script_host_eval(cstring("ruby"), argvars, rettv)
}

// —— Batch 27ap: funcs.c function/funcref ——
E700_S :: "E700: Unknown function: %s"
E923_S :: "E923: Second argument of function() must be a list or a dict"

// Shared function()/funcref() engine (C-static in funcs.c).
common_function_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, is_funcref: bool) {
	context = runtime.default_context()
	s: cstring = nil
	name: cstring = nil
	use_string := false
	arg_pt: rawptr = nil
	trans_name: cstring = nil
	if ([^]Typval_T)(argvars)[0].v_type == VAR_FUNC {
		s = transmute(cstring)(([^]Typval_T)(argvars)[0].vval)
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_PARTIAL && rawptr(([^]Typval_T)(argvars)[0].vval) != nil {
		arg_pt = rawptr(([^]Typval_T)(argvars)[0].vval)
		s = partial_name(arg_pt)
	} else {
		s = tv_get_string((^Typval_T)(uintptr(argvars)))
		use_string = true
	}
	if ((use_string && _vim_strchr(s, C.int(u8('#'))) == nil) || is_funcref) {
		name = s
		trans_name = save_function_name(&name, false, TFN_INT_O | TFN_QUIET_O | TFN_NO_AUTOLOAD_O | TFN_NO_DEREF_O, nil)
		if name != nil && ([^]u8)(name)[0] != 0 {
			s = nil
		}
	}
	if s == nil || ([^]u8)(s)[0] == 0 || (use_string && ascii_isdigit_o(([^]u8)(s)[0])) || (is_funcref && trans_name == nil) {
		if use_string {
			semsg(e_invarg2, tv_get_string((^Typval_T)(uintptr(argvars))))
		} else {
			semsg(e_invarg2, s)
		}
	} else if trans_name != nil && ((is_funcref && find_func(trans_name) == nil) || (!is_funcref && !translated_function_exists(trans_name))) {
		semsg(cstring(E700_S), s)
	} else {
		dict_idx: C.int = 0
		arg_idx: C.int = 0
		list: rawptr = nil
		if libc.strncmp(s, cstring("s:"), 2) == 0 || libc.strncmp(s, cstring("<SID>"), 5) == 0 {
			name = get_scriptlocal_funcname(s)
		} else {
			name = transmute(cstring)(xstrdup_o(transmute(^u8)(s)))
		}
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
			if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
				arg_idx = 1
				dict_idx = 2
			} else if ([^]Typval_T)(argvars)[1].v_type == VAR_DICT {
				dict_idx = 1
			} else {
				arg_idx = 1
			}
			if dict_idx > 0 {
				if tv_check_for_dict_arg(argvars, dict_idx) == FAIL_E {
					xfree(rawptr(name))
					xfree(rawptr(trans_name))
					return
				}
				if rawptr(([^]Typval_T)(argvars)[dict_idx].vval) == nil {
					dict_idx = 0
				}
			}
			if arg_idx > 0 {
				if ([^]Typval_T)(argvars)[arg_idx].v_type != VAR_LIST {
					emsg(cstring(E923_S))
					xfree(rawptr(name))
					xfree(rawptr(trans_name))
					return
				}
				list = rawptr(([^]Typval_T)(argvars)[arg_idx].vval)
				if tv_list_len_o(list) == 0 {
					arg_idx = 0
				} else if tv_list_len_o(list) > MAX_FUNC_ARGS_O {
					emsg_funcname(cstring(E_TOOMANYARG_S), s)
					xfree(rawptr(name))
					xfree(rawptr(trans_name))
					return
				}
			}
		}
		if dict_idx > 0 || arg_idx > 0 || arg_pt != nil || is_funcref {
			pt := rawptr(xcalloc(1, 48))
			if arg_idx > 0 || (arg_pt != nil && (^C.int)(uintptr(arg_pt) + PT_ARGC_OFF_O)^ > 0) {
				arg_len: C.int = 0
				if arg_pt != nil {
					arg_len = (^C.int)(uintptr(arg_pt) + PT_ARGC_OFF_O)^
				}
				lv_len := tv_list_len_o(list)
				pt_argc := arg_len + lv_len
				(^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ = pt_argc
				pt_argv := rawptr(xmalloc(C.size_t(16 * pt_argc)))
				(^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^ = pt_argv
				i: C.int = 0
				for i < arg_len {
					tv_copy((^Typval_T)(uintptr((^rawptr)(uintptr(arg_pt) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), (^Typval_T)(uintptr(pt_argv) + uintptr(i) * 16))
					i += 1
				}
				if lv_len > 0 {
					li := tv_list_first_o(list)
					for li != nil {
						tv_copy((^Typval_T)(uintptr(li) + 16), (^Typval_T)(uintptr(pt_argv) + uintptr(i) * 16))
						i += 1
						li = (^rawptr)(uintptr(li))^
					}
				}
			}
			if dict_idx > 0 {
				d := rawptr(([^]Typval_T)(argvars)[dict_idx].vval)
				(^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ = d
				(^C.int)(uintptr(d) + 8)^ += 1
			} else if arg_pt != nil {
				ad := (^rawptr)(uintptr(arg_pt) + PT_DICT_OFF_O)^
				(^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ = ad
				(^bool)(uintptr(pt) + PT_AUTO_OFF_O)^ = (^bool)(uintptr(arg_pt) + PT_AUTO_OFF_O)^
				if ad != nil {
					(^C.int)(uintptr(ad) + 8)^ += 1
				}
			}
			(^C.int)(uintptr(pt) + 0)^ = 1
			if arg_pt != nil && (^rawptr)(uintptr(arg_pt) + PT_FUNC_OFF_O)^ != nil {
				(^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ = (^rawptr)(uintptr(arg_pt) + PT_FUNC_OFF_O)^
				func_ptr_ref((^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^)
				xfree(rawptr(name))
			} else if is_funcref {
				(^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ = find_func(trans_name)
				func_ptr_ref((^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^)
				xfree(rawptr(name))
			} else {
				(^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ = rawptr(name)
				func_ref(name)
			}
			rettv.v_type = VAR_PARTIAL
			rettv.vval = transmute(rawptr)(pt)
		} else {
			rettv.v_type = VAR_FUNC
			rettv.vval = transmute(rawptr)(name)
			func_ref(name)
		}
	}
	xfree(rawptr(trans_name))
}

// "funcref()" function.
@(export)
f_funcref :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	common_function_o(argvars, rettv, true)
}

// "function()" function.
@(export)
f_function :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	common_function_o(argvars, rettv, false)
}

// —— Batch 27aq: funcs.c reduce ——
E998_S :: "E998: Reduce of an empty %s with no initial value"
E1098_S :: "E1098: String, List or Blob required"
E1132_S :: "E1132: Missing function argument"

// reduce() over a List (C-static in funcs.c).
reduce_list_o :: proc "c" (argvars: ^Typval_T, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	l := rawptr(([^]Typval_T)(argvars)[0].vval)
	called_start := called_emsg
	initial := Typval_T{}
	li: rawptr = nil
	if ([^]Typval_T)(argvars)[2].v_type == VAR_UNKNOWN {
		if tv_list_len_o(l) == 0 {
			semsg(cstring(E998_S), cstring("List"))
			return
		}
		first := tv_list_first_o(l)
		initial = (^Typval_T)(uintptr(first) + 16)^
		li = (^rawptr)(uintptr(first))^
	} else {
		initial = ([^]Typval_T)(argvars)[2]
		li = tv_list_first_o(l)
	}
	tv_copy(&initial, rettv)
	if l == nil {
		return
	}
	prev_locked := tv_list_locked_o(l)
	(^C.int)(uintptr(l) + 72)^ = VAR_FIXED_O
	for li != nil {
		argv: [3]Typval_T
		argv[0] = rettv^
		argv[1] = (^Typval_T)(uintptr(li) + 16)^
		rettv.v_type = VAR_UNKNOWN
		r := eval_expr_typval(expr, true, &argv[0], 2, rettv)
		tv_clear(&argv[0])
		if r == FAIL_E || called_emsg != called_start {
			break
		}
		li = (^rawptr)(uintptr(li))^
	}
	(^C.int)(uintptr(l) + 72)^ = prev_locked
}

// reduce() over a String (C-static in funcs.c).
reduce_string_o :: proc "c" (argvars: ^Typval_T, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	p := transmute([^]u8)(tv_get_string((^Typval_T)(uintptr(argvars))))
	length: C.int = 0
	called_start := called_emsg
	if ([^]Typval_T)(argvars)[2].v_type == VAR_UNKNOWN {
		if p[0] == 0 {
			semsg(cstring(E998_S), cstring("String"))
			return
		}
		length = utfc_ptr2len(transmute(cstring)(p))
		rettv^ = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2(p, C.size_t(length)))}
		p = ([^]u8)(uintptr(p) + uintptr(length))
	} else if tv_check_for_string_arg(argvars, 2) == FAIL_E {
		return
	} else {
		tv_copy((^Typval_T)(uintptr(argvars) + 32), rettv)
	}
	for p[0] != 0 {
		argv: [3]Typval_T
		argv[0] = rettv^
		length = utfc_ptr2len(transmute(cstring)(p))
		argv[1] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(xmemdupz_o2(p, C.size_t(length)))}
		r := eval_expr_typval(expr, true, &argv[0], 2, rettv)
		tv_clear(&argv[0])
		tv_clear(&argv[1])
		if r == FAIL_E || called_emsg != called_start {
			break
		}
		p = ([^]u8)(uintptr(p) + uintptr(length))
	}
}

// reduce() over a Blob (C-static in funcs.c).
reduce_blob_o :: proc "c" (argvars: ^Typval_T, expr: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	b := rawptr(([^]Typval_T)(argvars)[0].vval)
	called_start := called_emsg
	initial := Typval_T{}
	i: C.int = 0
	if ([^]Typval_T)(argvars)[2].v_type == VAR_UNKNOWN {
		if tv_blob_len_o(b) == 0 {
			semsg(cstring(E998_S), cstring("Blob"))
			return
		}
		initial = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(tv_blob_get_o(b, 0)))}
		i = 1
	} else if tv_check_for_number_arg(argvars, 2) == FAIL_E {
		return
	} else {
		initial = ([^]Typval_T)(argvars)[2]
		i = 0
	}
	tv_copy(&initial, rettv)
	for i < tv_blob_len_o(b) {
		argv: [3]Typval_T
		argv[0] = rettv^
		argv[1] = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(tv_blob_get_o(b, i)))}
		r := eval_expr_typval(expr, true, &argv[0], 2, rettv)
		if r == FAIL_E || called_emsg != called_start {
			return
		}
		i += 1
	}
}

// "reduce()" function.
@(export)
f_reduce :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING && ([^]Typval_T)(argvars)[0].v_type != VAR_LIST && ([^]Typval_T)(argvars)[0].v_type != VAR_BLOB {
		emsg(cstring(E1098_S))
		return
	}
	func_name: cstring = nil
	if ([^]Typval_T)(argvars)[1].v_type == VAR_FUNC {
		func_name = transmute(cstring)(([^]Typval_T)(argvars)[1].vval)
	} else if ([^]Typval_T)(argvars)[1].v_type == VAR_PARTIAL {
		func_name = partial_name(rawptr(([^]Typval_T)(argvars)[1].vval))
	} else {
		func_name = tv_get_string((^Typval_T)(uintptr(argvars) + 16))
	}
	if func_name == nil || ([^]u8)(func_name)[0] == 0 {
		emsg(cstring(E1132_S))
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		reduce_list_o(argvars, (^Typval_T)(uintptr(argvars) + 16), rettv)
	} else if ([^]Typval_T)(argvars)[0].v_type == VAR_STRING {
		reduce_string_o(argvars, (^Typval_T)(uintptr(argvars) + 16), rettv)
	} else {
		reduce_blob_o(argvars, (^Typval_T)(uintptr(argvars) + 16), rettv)
	}
}

// —— Batch 27ay: funcs.c soundfold + spellbadword ——

// "soundfold({word})" function.
@(export)
f_soundfold :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(eval_soundfold(tv_get_string((^Typval_T)(uintptr(argvars)))))
}

// "spellbadword()" function.
@(export)
f_spellbadword :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	wo_spell_save := w_p_spell_r(curwin)
	if wo_spell_save == 0 {
		parse_spelllang(curwin)
		(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = 1
	}
	ws := win_s_r(curwin)
	if ([^]u8)((^rawptr)(uintptr(ws) + SB_P_SPL_OFF)^)[0] == 0 {
		emsg(cstring(e_no_spell_txt))
		(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = wo_spell_save
		return
	}
	word: cstring = ""
	attr: C.int = HLF_COUNT_O
	length: C.size_t = 0
	if ([^]Typval_T)(argvars)[0].v_type == VAR_UNKNOWN {
		length = spell_move_to(curwin, FORWARD_O, SMT_ALL_O, true, &attr)
		if length != 0 {
			word = transmute(cstring)(get_cursor_pos_ptr())
			(^bool)(uintptr(curwin) + W_SET_CURSWANT)^ = true
		}
	} else if ([^]u8)((^rawptr)(uintptr(curbuf) + SB_P_SPL)^)[0] != 0 {
		str := tv_get_string_chk((^Typval_T)(uintptr(argvars)))
		capcol: C.int = -1
		if str != nil {
			s := transmute([^]u8)(str)
			for s[0] != 0 {
				length = spell_check(curwin, &s[0], &attr, &capcol, false)
				if attr != HLF_COUNT_O {
					word = transmute(cstring)(s)
					break
				}
				s = ([^]u8)(uintptr(s) + uintptr(length))
				capcol -= C.int(length)
				length = 0
			}
		}
	}
	(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ = wo_spell_save
	tv_list_alloc_ret(transmute(^Typval)(rettv), 2)
	tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(word), C.ssize_t(length))
	if attr == HLF_SPB {
		tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(cstring("bad")), 3)
	} else if attr == HLF_SPR {
		tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(cstring("rare")), 4)
	} else if attr == HLF_SPL {
		tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(cstring("local")), 5)
	} else if attr == HLF_SPC {
		tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(cstring("caps")), 4)
	} else {
		tv_list_append_string(rawptr(rettv.vval), nil, -1)
	}
}

// —— Batch 27bp: funcs.c setreg ——

// Yank-type parser (C-static in funcs.c).
get_yank_type_o :: proc "c" (pp: ^cstring, yank_type: ^C.int, block_len: ^C.int) -> C.int {
	context = runtime.default_context()
	stropt := ([^]u8)(pp^)
	if stropt[0] == 'v' || stropt[0] == 'c' {
		yank_type^ = kMTCharWise
	} else if stropt[0] == 'V' || stropt[0] == 'l' {
		yank_type^ = kMTLineWise
	} else if stropt[0] == 'b' || stropt[0] == Ctrl_V {
		yank_type^ = kMTBlockWise
		if ascii_isdigit_o(stropt[1]) {
			stropt = ([^]u8)(uintptr(stropt) + 1)
			block_len^ = getdigits_int(transmute(^^u8)(&stropt), false, 0) - 1
			stropt = ([^]u8)(uintptr(stropt) - 1)
		}
	} else {
		return FAIL_E
	}
	pp^ = transmute(cstring)(stropt)
	return OK_E
}

// "setreg()" function.
@(export)
f_setreg :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	append := false
	block_len: C.int = -1
	yank_type: C.int = kMTUnknown
	rettv.vval = transmute(rawptr)(C.longlong(1))
	strregname := tv_get_string_chk(argvars)
	if strregname == nil {
		return
	}
	regname := ([^]u8)(strregname)[0]
	if regname == 0 || regname == '@' {
		regname = '"'
	}
	regcontents: ^Typval_T = nil
	pointreg: u8 = 0
	if ([^]Typval_T)(argvars)[1].v_type == VAR_DICT {
		d := rawptr(([^]Typval_T)(argvars)[1].vval)
		if tv_dict_len_o(d) == 0 {
			lstval := ([^]cstring)(xmalloc(8 * 2))
			lstval[0] = nil
			lstval[1] = nil
			write_reg_contents_lst(C.int(regname), transmute(^rawptr)(lstval), false, kMTUnknown, -1)
			return
		}
		di := tv_dict_find(d, cstring("regcontents"), 11)
		if di != nil {
			regcontents = (^Typval_T)(uintptr(di))
		}
		stropt := tv_dict_get_string(d, cstring("regtype"), false)
		if stropt != nil {
			sp := stropt
			if get_yank_type_o(&sp, &yank_type, &block_len) == FAIL_E || ([^]u8)(sp)[1] != 0 {
				semsg(cstring(E475_VAL_S), cstring("value"))
				return
			}
		}
		if regname == '"' {
			stropt = tv_dict_get_string(d, cstring("points_to"), false)
			if stropt != nil {
				pointreg = ([^]u8)(stropt)[0]
				regname = pointreg
			}
		} else if tv_dict_get_number(d, cstring("isunnamed")) != 0 {
			pointreg = regname
		}
	} else {
		regcontents = (^Typval_T)(uintptr(argvars) + 16)
	}
	set_unnamed := false
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		if yank_type != kMTUnknown {
			semsg(cstring(E_TOOMANYARG_S), cstring("setreg"))
			return
		}
		stropt := tv_get_string_chk((^Typval_T)(uintptr(argvars) + 32))
		if stropt == nil {
			return
		}
		sp := transmute([^]u8)(stropt)
		for sp[0] != 0 {
			if sp[0] == 'a' || sp[0] == 'A' {
				append = true
			} else if sp[0] == 'u' || sp[0] == '"' {
				set_unnamed = true
			} else {
				spc := transmute(cstring)(sp)
				get_yank_type_o(&spc, &yank_type, &block_len)
				sp = transmute([^]u8)(spc)
			}
			sp = ([^]u8)(uintptr(sp) + 1)
		}
	}
	if regcontents != nil && regcontents.v_type == VAR_LIST {
		ll := rawptr(regcontents.vval)
		length := tv_list_len_o(ll)
		nslots := (length + 1) * 2
		lstval := ([^]cstring)(xmalloc(8 * C.size_t(nslots)))
		curval: C.int = 0
		nalloc := length + 2
		nac: C.int = 0
		li := tv_list_first_o(ll)
		ok := true
		for li != nil {
			buf: [65]u8
			s := tv_get_string_buf_chk((^Typval_T)(uintptr(li) + 16), &buf[0])
			if s == nil {
				ok = false
				break
			}
			if s == transmute(cstring)(&buf[0]) {
				s = transmute(cstring)(xstrdup_o(transmute(^u8)(s)))
				lstval[nalloc + nac] = s
				nac += 1
			}
			lstval[curval] = s
			curval += 1
			li = (^rawptr)(uintptr(li))^
		}
		lstval[curval] = nil
		curval += 1
		if ok {
			write_reg_contents_lst(C.int(regname), transmute(^rawptr)(lstval), append, yank_type, block_len)
		}
		i: C.int = 0
		for i < nac {
			xfree(rawptr(transmute(^u8)(lstval[nalloc + i])))
			i += 1
		}
		xfree(rawptr(lstval))
	} else if regcontents != nil {
		strval := tv_get_string_chk(regcontents)
		if strval == nil {
			return
		}
		write_reg_contents_ex(C.int(regname), strval, i64(libc.strlen(strval)), append, yank_type, block_len)
	}
	if pointreg != 0 {
		get_yank_register(C.int(pointreg), YREG_YANK)
	}
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if set_unnamed {
		op_reg_set_previous(regname)
	}
}

// —— Batch 27bw: funcs.c json pair ——

// "json_decode()" function.
@(export)
f_json_decode :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	numbuf: [65]u8
	s: cstring = nil
	tofree: cstring = nil
	length: C.size_t = 0
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		l := rawptr(([^]Typval_T)(argvars)[0].vval)
		tofree_raw: rawptr = nil
		if !encode_vim_list_to_buf(l, &length, &tofree_raw) {
			emsg(cstring("E474: Failed to convert list to string"))
			return
		}
		tofree = transmute(cstring)(tofree_raw)
		s = tofree
		if s == nil {
			s = cstring("")
		}
	} else {
		s = tv_get_string_buf_chk((^Typval_T)(uintptr(argvars)), &numbuf[0])
		if s != nil {
			length = C.size_t(libc.strlen(s))
		} else {
			return
		}
	}
	if json_decode_string(s, length, rettv) == FAIL_E {
		semsg(cstring("E474: Failed to parse %.*s"), C.int(length), s)
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
	xfree(rawptr(tofree))
}

// "json_encode()" function.
@(export)
f_json_encode :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(encode_tv2json((^Typval_T)(uintptr(argvars)), nil))
}

// —— Batch 27bx: funcs.c printf ——
foreign _ {
	@(link_name = "vim_vsnprintf_typval")
	vim_vsnprintf_typval_e :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: rawptr, tvs: ^Typval_T) -> C.int ---
}

// "printf()" function (va_list bypassed with zeroed dummy, same as C static).
@(export)
f_printf :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(cstring(nil))
	saved_did_emsg := did_emsg_flag
	did_emsg_flag = 0
	buf: [65]u8
	fmt := tv_get_string_buf((^Typval_T)(uintptr(argvars)), &buf[0])
	dummy: [24]u8
	length := vim_vsnprintf_typval_e(nil, 0, fmt, rawptr(&dummy[0]), (^Typval_T)(uintptr(argvars) + 16))
	if did_emsg_flag == 0 {
		s := (^u8)(xmalloc(C.size_t(length) + 1))
		rettv.vval = transmute(rawptr)(s)
		vim_vsnprintf_typval_e(s, C.size_t(length) + 1, fmt, rawptr(&dummy[0]), (^Typval_T)(uintptr(argvars) + 16))
	}
	did_emsg_flag |= saved_did_emsg
}

// —— Batch 27by: funcs.c msgpackdump ——
foreign _ {
	@(link_name = "packer_string_buffer")
	packer_string_buffer_e :: proc "c" () -> PackerBuffer_O ---
	@(link_name = "packer_take_string")
	packer_take_string_e :: proc "c" (buffer: ^PackerBuffer_O) -> NvimString ---
}

// PackerBuffer mirror (packer_defs.h): 48B cc-probed.
PackerBuffer_O :: struct {
	startptr:    ^u8,   // 0
	ptr:         ^u8,   // 8
	endptr:      ^u8,   // 16
	anydata:     rawptr, // 24
	anyint:      i64,    // 32
	packer_flush: rawptr, // 40
}
#assert(size_of(PackerBuffer_O) == 48)

// "msgpackdump()" function.
@(export)
f_msgpackdump :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST {
		semsg(cstring(E_LISTARG_S), cstring("msgpackdump()"))
		return
	}
	list := rawptr(([^]Typval_T)(argvars)[0].vval)
	packer := packer_string_buffer_e()
	idx: C.int = 0
	li := tv_list_first_o(list)
	for li != nil {
		msgbuf: [256]u8
		libc.snprintf(&msgbuf[0], 256, cstring("msgpackdump() argument, index %i"), idx)
		idx += 1
		if encode_vim_to_msgpack_o(&packer, (^Typval_T)(uintptr(li) + 16), transmute(cstring)(&msgbuf[0])) == FAIL_E {
			break
		}
		li = (^rawptr)(uintptr(li))^
	}
	data := packer_take_string_e(&packer)
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && strequal(tv_get_string((^Typval_T)(uintptr(argvars) + 16)), cstring("B")) {
		b := tv_blob_alloc_ret(rettv)
		(^rawptr)(uintptr(b) + 16)^ = rawptr(data.data)
		(^C.int)(uintptr(b) + 0)^ = C.int(data.size)
		(^C.int)(uintptr(b) + 4)^ = C.int(uintptr(packer.endptr) - uintptr(packer.startptr))
	} else {
		encode_list_write(tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O), transmute(cstring)(data.data), C.size_t(data.size))
		api_free_string_r(data)
	}
}

// —— Batch 27bz: funcs.c msgpackparse ——
foreign _ {
	@(link_name = "mpack_parser_init")
	mpack_parser_init_e :: proc "c" (p: rawptr, c: u32) ---
}

MPACK_OK_O :: 0
MPACK_EOF_O :: 1
MPACK_ERROR_O :: 2
MPACK_NOMEM_O :: 3
ARENA_BLOCK_SIZE_O :: 4096
MPARSER_SIZE_O :: 1664

// mpack error reporter (C-static in funcs.c).
emsg_mpack_error_o :: proc "c" (status: C.int) {
	context = runtime.default_context()
	if status == MPACK_ERROR_O {
		semsg(e_invarg2, cstring("Failed to parse msgpack string"))
	} else if status == MPACK_EOF_O {
		semsg(e_invarg2, cstring("Incomplete msgpack string"))
	} else if status == MPACK_NOMEM_O {
		semsg(e_invarg2, cstring("object was too deep to unpack"))
	}
}

// List-based msgpack unpacker (C-static in funcs.c).
msgpackparse_unpack_list_o :: proc "c" (list: rawptr, ret_list: rawptr) {
	context = runtime.default_context()
	if tv_list_len_o(list) == 0 {
		return
	}
	first := tv_list_first_o(list)
	if (^C.int)(uintptr((^Typval_T)(uintptr(first) + 16))) ^ != VAR_STRING {
		semsg(e_invarg2, cstring("List item is not a string"))
		return
	}
	lrstate := encode_init_lrstate(list)
	buf := (^u8)(alloc_block())
	buf_size: C.size_t = 0
	cur_item := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	parser: [MPARSER_SIZE_O]u8
	mpack_parser_init_e(rawptr(&parser[0]), 0)
	(^rawptr)(rawptr(&parser[0]))^ = rawptr(&cur_item)
	status: C.int = MPACK_OK_O
	for {
		read_bytes: C.size_t = 0
		rlret := encode_read_from_list(&lrstate, buf, ARENA_BLOCK_SIZE_O - buf_size, &read_bytes)
		if rlret == FAIL_E {
			semsg(e_invarg2, cstring("List item is not a string"))
			break
		}
		buf_size += read_bytes
		ptr := transmute(cstring)(rawptr(uintptr(buf)))
		for buf_size > 0 {
			status = mpack_parse_typval(rawptr(&parser[0]), &ptr, &buf_size)
			if status == MPACK_OK_O {
				tv_list_append_owned_tv(ret_list, cur_item)
				cur_item.v_type = VAR_UNKNOWN
			} else {
				break
			}
		}
		if rlret == OK_E {
			break
		}
		if status == MPACK_EOF_O {
			if buf_size > 0 && uintptr(rawptr(ptr)) > uintptr(buf) {
				libc.memmove(rawptr(buf), rawptr(ptr), buf_size)
			}
		} else if status != MPACK_OK_O {
			break
		}
	}
	if status != MPACK_OK_O {
		typval_parser_error_free(rawptr(&parser[0]))
		emsg_mpack_error_o(status)
	}
	free_block(rawptr(buf))
}

// Blob-based msgpack unpacker (C-static in funcs.c).
msgpackparse_unpack_blob_o :: proc "c" (blob: rawptr, ret_list: rawptr) {
	context = runtime.default_context()
	length := tv_blob_len_o(blob)
	if length == 0 {
		return
	}
	data := transmute(cstring)((^rawptr)(uintptr(blob) + 16)^)
	remaining: C.size_t = C.size_t(length)
	for remaining > 0 {
		tv := Typval_T{}
		status := unpack_typval(&data, &remaining, &tv)
		if status != MPACK_OK_O {
			emsg_mpack_error_o(status)
			return
		}
		tv_list_append_owned_tv(ret_list, tv)
	}
}

// "msgpackparse()" function.
@(export)
f_msgpackparse :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if ([^]Typval_T)(argvars)[0].v_type != VAR_LIST && ([^]Typval_T)(argvars)[0].v_type != VAR_BLOB {
		semsg(cstring(E_LISTBLOBARG_S), cstring("msgpackparse()"))
		return
	}
	ret_list := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if ([^]Typval_T)(argvars)[0].v_type == VAR_LIST {
		msgpackparse_unpack_list_o(rawptr(([^]Typval_T)(argvars)[0].vval), ret_list)
	} else {
		msgpackparse_unpack_blob_o(rawptr(([^]Typval_T)(argvars)[0].vval), ret_list)
	}
}

// —— Batch 23d: eval/typval_encode walker foundation (dormant) ——

// Stack entry types (typval_encode.h).
MPConvStackValType_O :: enum C.int {
	kMPConvDict        = 0,
	kMPConvList        = 1,
	kMPConvPairs       = 2,
	kMPConvPartial     = 3,
	kMPConvPartialList = 4,
}

// Partial conversion stages.
MPConvPartialStage_O :: enum C.int {
	kMPConvPartialArgs = 0,
	kMPConvPartialSelf = 1,
	kMPConvPartialEnd  = 2,
}

// MPConvStackVal mirror (typval_encode.h): 56B cc-probed.
MPConvStackVal_O :: struct {
	type:         C.int,  // 0
	_pad4:        [4]u8,
	tv:           rawptr, // 8
	saved_copyID: C.int,  // 16
	_pad20:       [4]u8,
	data:         [32]u8, // 24..56
}
#assert(size_of(MPConvStackVal_O) == 56)

// MPConvStack mirror (kvec_withinit 8 inline): 472B cc-probed.
MPConvStack_O :: struct {
	size:       C.size_t, // 0
	capacity:   C.size_t, // 8
	items:      ^MPConvStackVal_O, // 16
	init_items: [8]MPConvStackVal_O, // 24..472
}
#assert(size_of(MPConvStack_O) == 472)

// Stack data accessors (union fields inside data[32]).
mpconv_d_dict_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> rawptr {
	return (^rawptr)(&v.data[0])^
}
mpconv_d_dictp_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> rawptr {
	return (^rawptr)(&v.data[8])^
}
mpconv_d_hi_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> rawptr {
	return (^rawptr)(&v.data[16])^
}
mpconv_d_todo_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> C.size_t {
	return (^C.size_t)(&v.data[24])^
}
mpconv_l_list_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> rawptr {
	return (^rawptr)(&v.data[0])^
}
mpconv_l_li_o :: #force_inline proc "c" (v: ^MPConvStackVal_O) -> rawptr {
	return (^rawptr)(&v.data[8])^
}

// kvec stack ops over the mirror (kvec.h semantics).
mpconv_stack_init_o :: proc "c" (st: ^MPConvStack_O) {
	context = runtime.default_context()
	st.size = 0
	st.capacity = 8
	st.items = &st.init_items[0]
}
mpconv_stack_push_o :: proc "c" (st: ^MPConvStack_O, v: MPConvStackVal_O) {
	context = runtime.default_context()
	if st.size >= st.capacity {
		newcap := st.capacity * 2
		nbytes := C.size_t(newcap) * 56
		if st.items == &st.init_items[0] {
			nb := (^u8)(xmalloc(nbytes))
			libc.memcpy(rawptr(nb), rawptr(st.items), C.size_t(st.size) * 56)
			st.items = (^MPConvStackVal_O)(nb)
		} else {
			st.items = (^MPConvStackVal_O)(xrealloc(rawptr(st.items), nbytes))
		}
		st.capacity = newcap
	}
	([^]MPConvStackVal_O)(st.items)[st.size] = v
	st.size += 1
}
mpconv_stack_pop_o :: proc "c" (st: ^MPConvStack_O) {
	context = runtime.default_context()
	st.size -= 1
}
mpconv_stack_last_o :: proc "c" (st: ^MPConvStack_O) -> ^MPConvStackVal_O {
	context = runtime.default_context()
	return &([^]MPConvStackVal_O)(st.items)[st.size - 1]
}
mpconv_stack_destroy_o :: proc "c" (st: ^MPConvStack_O) {
	context = runtime.default_context()
	if st.items != &st.init_items[0] {
		xfree(rawptr(st.items))
	}
}

// Self-reference check (TYPVAL_ENCODE_CHECK_SELF_REFERENCE without the
// mode-specific RECURSE emit: true = already seen, caller emits + returns OK).
typval_encode_check_self_reference_o :: proc "c" (val_copyID: ^C.int, copyID: C.int) -> bool {
	context = runtime.default_context()
	if val_copyID^ == copyID {
		return true
	}
	val_copyID^ = copyID
	return false
}

// list_T copyID inline accessors (typval.h:88/111, lv_copyID@68).
tv_list_copyid_o :: proc "c" (l: rawptr) -> C.int {
	context = runtime.default_context()
	return (^C.int)(uintptr(l) + 68)^
}
tv_list_set_copyid_o :: proc "c" (l: rawptr, copyid: C.int) {
	context = runtime.default_context()
	(^C.int)(uintptr(l) + 68)^ = copyid
}

// —— Batch 23e: string-mode scalar emits + CONVERT_ONE_VALUE (dormant) ——
foreign _ {
	@(link_name = "vim_snprintf_safelen")
	vim_snprintf_safelen_e :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, #c_vararg args: ..any) -> C.size_t ---
	@(link_name = "nvim_odin_get_echo_emsg")
	nvim_odin_get_echo_emsg_e :: proc "c" () -> bool ---
	@(link_name = "nvim_odin_set_echo_emsg")
	nvim_odin_set_echo_emsg_e :: proc "c" (v: bool) ---
	@(link_name = "utf_printable")
	utf_printable_e :: proc "c" (c: C.int) -> bool ---
}

// —— Batch 23h: json-mode engine ——

KMPNIL_O :: 0
KMPBOOLEAN_O :: 1
KMPINTEGER_O :: 2
KMPFLOAT_O :: 3
KMPARRAY_O :: 5
KMPEXT_O :: 7

// Hex digits for \u escapes (string literals can't take variable index).
xdigits_o := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'}

// JSON string escaper (convert_to_json_string, two-pass).
convert_to_json_string_o :: proc "c" (gap: ^Garray, buf: cstring, length: C.size_t) -> C.int {
	context = runtime.default_context()
	if buf == nil {
		ga_concat_len(gap, cstring("\"\""), 2)
		return OK_E
	}
	utf_len := C.size_t(length)
	str_len: C.size_t = 0
	i: C.size_t = 0
	for i < utf_len {
		ch := utf_ptr2char(transmute(cstring)(rawptr(uintptr(rawptr(buf)) + uintptr(i))))
		shift := C.size_t(utf_ptr2len_o(transmute(cstring)(rawptr(uintptr(rawptr(buf)) + uintptr(i)))))
		if ch == 0 {
			shift = 1
		}
		i += shift
		if ch == 8 || ch == 9 || ch == 10 || ch == 12 || ch == 13 || ch == '"' || ch == '\\' {
			str_len += 2
		} else if ch > 0x7F && shift == 1 {
			semsg(cstring("E474: String \"%.*s\" contains byte that does not start any UTF-8 character"), C.int(utf_len - (i - shift)), rawptr(uintptr(rawptr(buf)) + uintptr(i - shift)))
			return FAIL_E
		} else if (ch >= 0xD800 && ch <= 0xDBFF) || (ch >= 0xDC00 && ch <= 0xDFFF) {
			semsg(cstring("E474: UTF-8 string contains code point which belongs to a surrogate pair: %.*s"), C.int(utf_len - (i - shift)), rawptr(uintptr(rawptr(buf)) + uintptr(i - shift)))
			return FAIL_E
		} else if ch >= 0x20 && utf_printable_e(C.int(ch)) {
			str_len += shift
		} else {
			str_len += 6
			if ch >= 0x10000 {
				str_len += 6
			}
		}
	}
	ga_append(gap, '"')
	ga_grow(gap, C.int(str_len))
	i = 0
	for i < utf_len {
		ch := utf_ptr2char(transmute(cstring)(rawptr(uintptr(rawptr(buf)) + uintptr(i))))
		shift := C.size_t(utf_char2len_r(ch))
		if ch == 0 {
			shift = 1
		}
		if ch == 8 {
			ga_concat_len(gap, cstring("\\b"), 2)
		} else if ch == 9 {
			ga_concat_len(gap, cstring("\\t"), 2)
		} else if ch == 10 {
			ga_concat_len(gap, cstring("\\n"), 2)
		} else if ch == 12 {
			ga_concat_len(gap, cstring("\\f"), 2)
		} else if ch == 13 {
			ga_concat_len(gap, cstring("\\r"), 2)
		} else if ch == '"' {
			ga_concat_len(gap, cstring("\\\""), 2)
		} else if ch == '\\' {
			ga_concat_len(gap, cstring("\\\\"), 2)
		} else if ch >= 0x20 && utf_printable_e(C.int(ch)) {
			ga_concat_len(gap, transmute(cstring)(rawptr(uintptr(rawptr(buf)) + uintptr(i))), shift)
		} else if ch < 0x10000 {
			eb: [6]u8
			eb[0] = '\\'; eb[1] = 'u'
			eb[2] = u8(xdigits_o[(ch >> 12) & 0xF])
			eb[3] = u8(xdigits_o[(ch >> 8) & 0xF])
			eb[4] = u8(xdigits_o[(ch >> 4) & 0xF])
			eb[5] = u8(xdigits_o[ch & 0xF])
			ga_concat_len(gap, transmute(cstring)(&eb[0]), 6)
		} else {
			tmp := ch - 0x10000
			hi := 0xD800 + ((tmp >> 10) & 0x3FF)
			lo := 0xDC00 + (tmp & 0x3FF)
			eb: [12]u8
			eb[0] = '\\'; eb[1] = 'u'
			eb[2] = u8(xdigits_o[(hi >> 12) & 0xF])
			eb[3] = u8(xdigits_o[(hi >> 8) & 0xF])
			eb[4] = u8(xdigits_o[(hi >> 4) & 0xF])
			eb[5] = u8(xdigits_o[hi & 0xF])
			eb[6] = '\\'; eb[7] = 'u'
			eb[8] = u8(xdigits_o[(lo >> 12) & 0xF])
			eb[9] = u8(xdigits_o[(lo >> 8) & 0xF])
			eb[10] = u8(xdigits_o[(lo >> 4) & 0xF])
			eb[11] = u8(xdigits_o[lo & 0xF])
			ga_concat_len(gap, transmute(cstring)(&eb[0]), 12)
		}
		i += shift
	}
	ga_append(gap, '"')
	return OK_E
}

// Location-reporting error (conv_error, shared by json/msgpack modes).
conv_error_o :: proc "c" (msg: cstring, mpstack: ^MPConvStack_O, objname: cstring) -> C.int {
	context = runtime.default_context()
	msg_ga := Garray{}
	ga_init(&msg_ga, 1, 80)
	i: C.size_t = 0
	for i < mpstack.size {
		if i != 0 {
			ga_concat_len(&msg_ga, cstring(", "), 2)
		}
		v := ([^]MPConvStackVal_O)(mpstack.items)[i]
		if v.type == C.int(MPConvStackValType_O.kMPConvDict) {
			hi := (^rawptr)(&v.data[16])^
			key: cstring = nil
			if hi == nil {
				d := (^rawptr)(&v.data[0])^
				arra := (^rawptr)(rawptr(uintptr(d) + 48))^
				key = transmute(cstring)((^rawptr)(uintptr(arra) + 8)^)
			} else {
				key = transmute(cstring)((^rawptr)(uintptr(hi) - 16 + 8)^)
			}
			ktv := Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(key)}
			kstr := encode_tv2string(&ktv, nil)
			libc.snprintf(transmute([^]u8)(&IObuff[0]), 1025, cstring("key %s"), kstr)
			xfree(rawptr(transmute(^u8)(kstr)))
			ga_concat(&msg_ga, transmute(cstring)(&IObuff[0]))
		} else if v.type == C.int(MPConvStackValType_O.kMPConvPairs) || v.type == C.int(MPConvStackValType_O.kMPConvList) {
			l := (^rawptr)(&v.data[0])^
			cursor := (^rawptr)(&v.data[8])^
			idx: C.int = 0
			if cursor == tv_list_first_o(l) {
				idx = 0
			} else if cursor == nil {
				idx = tv_list_len_o(l) - 1
			} else {
				idx = tv_list_idx_of_item(l, (^rawptr)(uintptr(cursor) + 8)^)
			}
			tgt: rawptr = nil
			if cursor == nil {
				tgt = tv_list_last_o(l)
			} else {
				tgt = (^rawptr)(uintptr(cursor) + 8)^
			}
			ttv: ^Typval_T = nil
			if tgt != nil {
				ttv = (^Typval_T)(uintptr(tgt) + 16)
			}
			if v.type == C.int(MPConvStackValType_O.kMPConvList) || tgt == nil || (ttv.v_type != VAR_LIST && tv_list_len_o(rawptr(ttv.vval)) <= 0) {
				libc.snprintf(transmute([^]u8)(&IObuff[0]), 1025, cstring("index %i"), idx)
				ga_concat(&msg_ga, transmute(cstring)(&IObuff[0]))
			} else {
				first := tv_list_first_o(rawptr(ttv.vval))
				ktv := (^Typval_T)(uintptr(first) + 16)^
				key := encode_tv2echo(&ktv, nil)
				libc.snprintf(transmute([^]u8)(&IObuff[0]), 1025, cstring("key %s at index %i from special map"), key, idx)
				xfree(rawptr(transmute(^u8)(key)))
				ga_concat(&msg_ga, transmute(cstring)(&IObuff[0]))
			}
		} else if v.type == C.int(MPConvStackValType_O.kMPConvPartial) {
			if (^C.int)(&v.data[0])^ == C.int(MPConvPartialStage_O.kMPConvPartialSelf) {
				ga_concat_len(&msg_ga, cstring("partial"), 7)
			} else if (^C.int)(&v.data[0])^ == C.int(MPConvPartialStage_O.kMPConvPartialEnd) {
				ga_concat_len(&msg_ga, cstring("partial self dictionary"), 23)
			}
		} else {
			arg := (^rawptr)(&v.data[0])^
			argv := (^rawptr)(&v.data[8])^
			idx := C.int(uintptr(arg) - uintptr(argv)) / 16 - 1
			libc.snprintf(transmute([^]u8)(&IObuff[0]), 1025, cstring("argument %i"), idx)
			ga_concat(&msg_ga, transmute(cstring)(&IObuff[0]))
		}
		i += 1
	}
	if mpstack.size == 0 {
		semsg(msg, objname, cstring("itself"))
	} else {
		semsg(msg, objname, transmute(cstring)(msg_ga.ga_data))
	}
	ga_clear(&msg_ga)
	return FAIL_E
}

FP_NAN_O :: 0
FP_INFINITE_O :: 1

// String-mode CONV_STRING (quote + ''-escape).
encode_str_string_o :: proc "c" (gap: ^Garray, buf: cstring, length: C.size_t) {
	context = runtime.default_context()
	if buf == nil {
		ga_concat_len(gap, cstring("''"), 2)
		return
	}
	ga_grow(gap, C.int(2 + length + memcnt(rawptr(transmute(^u8)(buf)), C.int('\''), length)))
	ga_append(gap, '\'')
	i: C.size_t = 0
	for i < length {
		if ([^]u8)(buf)[i] == '\'' {
			ga_append(gap, '\'')
		}
		ga_append(gap, ([^]u8)(buf)[i])
		i += 1
	}
	ga_append(gap, '\'')
}

// String-mode CONV_BLOB (0z hex with dots).
encode_str_blob_o :: proc "c" (gap: ^Garray, blob: rawptr, length: C.int) {
	context = runtime.default_context()
	if length == 0 {
		ga_concat_len(gap, cstring("0z"), 2)
		return
	}
	ga_grow(gap, 2 + 2 * length + (length - 1) / 4)
	ga_concat_len(gap, cstring("0z"), 2)
	numbuf: [65]u8
	i: C.int = 0
	for i < length {
		if i > 0 && (i & 3) == 0 {
			ga_append(gap, '.')
		}
		n := libc.snprintf(&numbuf[0], 65, cstring("%02X"), C.int(tv_blob_get_o(blob, i)))
		ga_concat_len(gap, transmute(cstring)(&numbuf[0]), C.size_t(n))
		i += 1
	}
}

// String-mode CONV_NUMBER (%PRId64).
encode_str_number_o :: proc "c" (gap: ^Garray, num: C.longlong) {
	context = runtime.default_context()
	numbuf: [65]u8
	n := libc.snprintf(&numbuf[0], 65, cstring("%ld"), num)
	ga_concat_len(gap, transmute(cstring)(&numbuf[0]), C.size_t(n))
}

// String-mode CONV_FLOAT (nan/inf/%g).
encode_str_float_o :: proc "c" (gap: ^Garray, flt: f64) {
	context = runtime.default_context()
	if xfpclassify(flt) == FP_NAN_O {
		ga_concat_len(gap, cstring("str2float('nan')"), 16)
	} else if xfpclassify(flt) == FP_INFINITE_O {
		if flt < 0 {
			ga_append(gap, '-')
		}
		ga_concat_len(gap, cstring("str2float('inf')"), 16)
	} else {
		numbuf: [65]u8
		n := vim_snprintf_safelen_e(&numbuf[0], 65, cstring("%g"), flt)
		ga_concat_len(gap, transmute(cstring)(&numbuf[0]), n)
	}
}

// String-mode CONVERT_ONE_VALUE (scalars immediate, containers pushed).
// Returns OK_E/FAIL_E; mode RECURSE never triggers (ALLOW_SPECIALS=false,
// string self-ref handled by walker via check helper).
convert_one_value_string_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, cur_mpsv: ^MPConvStackVal_O, tv: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	if tv.v_type == VAR_STRING {
		s := transmute(cstring)(tv.vval)
		if s == nil {
			encode_str_string_o(gap, nil, 0)
		} else {
			encode_str_string_o(gap, s, C.size_t(libc.strlen(s)))
		}
	} else if tv.v_type == VAR_NUMBER {
		encode_str_number_o(gap, transmute(C.longlong)(tv.vval))
	} else if tv.v_type == VAR_FLOAT {
		encode_str_float_o(gap, transmute(f64)(tv.vval))
	} else if tv.v_type == VAR_BLOB {
		b := rawptr(tv.vval)
		encode_str_blob_o(gap, b, tv_blob_len_o(b))
	} else if tv.v_type == VAR_FUNC {
		s := transmute(cstring)(tv.vval)
		if s == nil {
			_internal_error(cstring("string(): NULL function name"))
			ga_concat_len(gap, cstring("function(NULL"), 13)
		} else {
			ga_concat_len(gap, cstring("function("), 9)
			encode_str_string_o(gap, s, C.size_t(libc.strlen(s)))
		}
		ga_append(gap, ')')
	} else if tv.v_type == VAR_PARTIAL {
		pt := rawptr(tv.vval)
		fun: cstring = nil
		if pt != nil {
			fun = partial_name(pt)
		}
		prefix := cstring("")
		if fun != nil && pt != nil && (^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ == nil && ([^]u8)(fun)[0] >= 'A' && ([^]u8)(fun)[0] <= 'Z' {
			prefix = cstring("g:")
		}
		if fun == nil {
			_internal_error(cstring("string(): NULL function name"))
			ga_concat_len(gap, cstring("function(NULL"), 13)
		} else {
			ga_concat_len(gap, cstring("function("), 9)
			name_off := gap.ga_len
			ga_concat(gap, prefix)
			encode_str_string_o(gap, fun, C.size_t(libc.strlen(fun)))
			([^]u8)(gap.ga_data)[uintptr(name_off)] = '\''
			plen := C.size_t(libc.strlen(prefix))
			if plen > 0 {
				libc.memcpy(rawptr(uintptr(gap.ga_data) + uintptr(name_off) + 1), rawptr(transmute(^u8)(prefix)), plen)
			}
		}
		v := MPConvStackVal_O{}
		v.type = C.int(MPConvStackValType_O.kMPConvPartial)
		v.tv = tv
		v.saved_copyID = copyID - 1
		(^C.int)(&v.data[0])^ = C.int(MPConvPartialStage_O.kMPConvPartialArgs)
		(^rawptr)(&v.data[8])^ = pt
		mpconv_stack_push_o(mpstack, v)
	} else if tv.v_type == VAR_LIST {
		l := rawptr(tv.vval)
		if l == nil || tv_list_len_o(l) == 0 {
			ga_concat_len(gap, cstring("[]"), 2)
		} else {
			saved := tv_list_copyid_o(l)
			if (^C.int)(uintptr(l) + 68)^ == copyID {
				encode_recurse_o(gap, mpstack, l, C.int(MPConvStackValType_O.kMPConvList))
			} else {
				(^C.int)(uintptr(l) + 68)^ = copyID
				ga_append(gap, '[')
				v := MPConvStackVal_O{}
				v.type = C.int(MPConvStackValType_O.kMPConvList)
				v.tv = tv
				v.saved_copyID = saved
				(^rawptr)(&v.data[0])^ = l
				(^rawptr)(&v.data[8])^ = tv_list_first_o(l)
				mpconv_stack_push_o(mpstack, v)
			}
		}
	} else if tv.v_type == VAR_BOOL {
		if C.int(transmute(C.longlong)(tv.vval)) != 0 {
			ga_concat_len(gap, cstring("v:true"), 6)
		} else {
			ga_concat_len(gap, cstring("v:false"), 7)
		}
	} else if tv.v_type == VAR_SPECIAL {
		ga_concat_len(gap, cstring("v:null"), 6)
	} else if tv.v_type == VAR_DICT {
		d := rawptr(tv.vval)
		if d == nil || (^C.size_t)(uintptr(d) + 24)^ == 0 {
			ga_concat_len(gap, cstring("{}"), 2)
		} else {
			saved := (^C.int)(uintptr(d) + 12)^
			if (^C.int)(uintptr(d) + 12)^ == copyID {
				encode_recurse_o(gap, mpstack, d, C.int(MPConvStackValType_O.kMPConvDict))
			} else {
				(^C.int)(uintptr(d) + 12)^ = copyID
				ga_append(gap, '{')
				v := MPConvStackVal_O{}
				v.type = C.int(MPConvStackValType_O.kMPConvDict)
				v.tv = tv
				v.saved_copyID = saved
				(^rawptr)(&v.data[0])^ = d
				(^rawptr)(&v.data[8])^ = rawptr(uintptr(tv) + 8)
				(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(d) + 48))^
				(^C.size_t)(&v.data[24])^ = (^C.size_t)(uintptr(d) + 24)^
				mpconv_stack_push_o(mpstack, v)
			}
		}
	}
	return OK_E
}

// Echo-mode shares the string walker; only RECURSE differs
// (backref {...@N}/[...@N}, no E724). Selected by flag.
encode_recurse_echo_g := false

// Echo-mode CONV_RECURSE (backref emit, no error).
encode_echo_recurse_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, val: rawptr, conv_type: C.int) {
	context = runtime.default_context()
	backref: C.size_t = 0
	for backref < mpstack.size {
		mpval := ([^]MPConvStackVal_O)(mpstack.items)[backref]
		if mpval.type == conv_type {
			hit := false
			if conv_type == C.int(MPConvStackValType_O.kMPConvDict) {
				hit = (^rawptr)(&mpval.data[0])^ == val
			} else if conv_type == C.int(MPConvStackValType_O.kMPConvList) {
				hit = (^rawptr)(&mpval.data[0])^ == val
			}
			if hit {
				break
			}
		}
		backref += 1
	}
	ebuf: [72]u8
	if conv_type == C.int(MPConvStackValType_O.kMPConvDict) {
		libc.snprintf(&ebuf[0], 72, cstring("{...@%zu}"), backref)
	} else {
		libc.snprintf(&ebuf[0], 72, cstring("[...@%zu]"), backref)
	}
	ga_concat(gap, transmute(cstring)(&ebuf[0]))
}

// Mode-dispatched RECURSE (string default, echo when flagged).
encode_recurse_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, val: rawptr, conv_type: C.int) {
	context = runtime.default_context()
	if encode_recurse_echo_g {
		encode_echo_recurse_o(gap, mpstack, val, conv_type)
	} else {
		encode_str_recurse_o(gap, mpstack, val, conv_type)
	}
}

// String-mode CONV_RECURSE (E724 once + {E724@backref}).
encode_str_recurse_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, val: rawptr, conv_type: C.int) {
	context = runtime.default_context()
	if !nvim_odin_get_echo_emsg_e() {
		nvim_odin_set_echo_emsg_e(true)
		emsg(cstring("E724: unable to correctly dump variable with self-referencing container"))
	}
	backref: C.size_t = 0
	for backref < mpstack.size {
		mpval := ([^]MPConvStackVal_O)(mpstack.items)[backref]
		if mpval.type == conv_type {
			hit := false
			if conv_type == C.int(MPConvStackValType_O.kMPConvDict) {
				hit = (^rawptr)(&mpval.data[0])^ == val
			} else if conv_type == C.int(MPConvStackValType_O.kMPConvList) {
				hit = (^rawptr)(&mpval.data[0])^ == val
			}
			if hit {
				break
			}
		}
		backref += 1
	}
	ebuf: [72]u8
	libc.snprintf(&ebuf[0], 72, cstring("{E724@%zu}"), backref)
	ga_concat(gap, transmute(cstring)(&ebuf[0]))
}

// —— Batch 23f: string-mode walker loop + driver + encode_tv2string ——

// String-mode walker continuation (TYPVAL_ENCODE_ENCODE loop body).
encode_str_walker_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, tv_top: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	for mpstack.size > 0 {
		cur := mpconv_stack_last_o(mpstack)
		tv: ^Typval_T = nil
		if cur.type == C.int(MPConvStackValType_O.kMPConvDict) {
			todo := (^C.size_t)(&cur.data[24])^
			if todo == 0 {
				d := (^rawptr)(&cur.data[0])^
				(^C.int)(uintptr(d) + 12)^ = cur.saved_copyID
				ga_append(gap, '}')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			d := (^rawptr)(&cur.data[0])^
			if todo != (^C.size_t)(uintptr(d) + 24)^ {
				ga_concat_len(gap, cstring(", "), 2)
			}
			hi := (^rawptr)(&cur.data[16])^
			for (^rawptr)(uintptr(hi) + 8)^ == nil || (^rawptr)(uintptr(hi) + 8)^ == rawptr(&hash_removed) {
				hi = rawptr(uintptr(hi) + 16)
			}
			(^rawptr)(&cur.data[16])^ = hi
			di := rawptr(uintptr((^rawptr)(uintptr(hi) + 8)^) - 17)
			(^C.size_t)(&cur.data[24])^ = todo - 1
			(^rawptr)(&cur.data[16])^ = rawptr(uintptr(hi) + 16)
			key := transmute(cstring)((^rawptr)(uintptr(hi) + 8)^)
			encode_str_string_o(gap, key, C.size_t(libc.strlen(key)))
			ga_concat_len(gap, cstring(": "), 2)
			tv = (^Typval_T)(uintptr(di))
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvList) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				ga_append(gap, ']')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			l := (^rawptr)(&cur.data[0])^
			if li != tv_list_first_o(l) {
				ga_concat_len(gap, cstring(", "), 2)
			}
			tv = (^Typval_T)(uintptr(li) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvPairs) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				ga_append(gap, '}')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			l := (^rawptr)(&cur.data[0])^
			if li != tv_list_first_o(l) {
				ga_concat_len(gap, cstring(", "), 2)
			}
			pair := rawptr((^Typval_T)(uintptr(li) + 16).vval)
			if convert_one_value_string_o(gap, mpstack, cur, (^Typval_T)(uintptr(tv_list_first_o(pair)) + 16), copyID, objname) == FAIL_E {
				mpconv_stack_destroy_o(mpstack)
				return FAIL_E
			}
			ga_concat_len(gap, cstring(": "), 2)
			tv = (^Typval_T)(uintptr(tv_list_last_o(pair)) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvPartial) {
			pt := (^rawptr)(&cur.data[8])^
			stage := (^C.int)(&cur.data[0])^
			if stage == C.int(MPConvPartialStage_O.kMPConvPartialArgs) {
				argc: C.int = 0
				if pt != nil {
					argc = (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^
				}
				if argc != 0 {
					ga_concat_len(gap, cstring(", "), 2)
				}
				(^C.int)(&cur.data[0])^ = C.int(MPConvPartialStage_O.kMPConvPartialSelf)
				if pt != nil && argc > 0 {
					ga_append(gap, '[')
					v := MPConvStackVal_O{}
					v.type = C.int(MPConvStackValType_O.kMPConvPartialList)
					v.saved_copyID = copyID - 1
					argv := (^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^
					(^rawptr)(&v.data[0])^ = argv
					(^rawptr)(&v.data[8])^ = argv
					(^C.size_t)(&v.data[16])^ = C.size_t(argc)
					mpconv_stack_push_o(mpstack, v)
				}
			} else if stage == C.int(MPConvPartialStage_O.kMPConvPartialSelf) {
				(^C.int)(&cur.data[0])^ = C.int(MPConvPartialStage_O.kMPConvPartialEnd)
				dict: rawptr = nil
				if pt != nil {
					dict = (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^
				}
				if dict != nil {
					used := C.int((^C.size_t)(uintptr(dict) + 24)^)
					ga_concat_len(gap, cstring(", "), 2)
					if used == 0 {
						ga_concat_len(gap, cstring("{}"), 2)
						continue
					}
					saved := (^C.int)(uintptr(dict) + 12)^
					if (^C.int)(uintptr(dict) + 12)^ == copyID {
						encode_recurse_o(gap, mpstack, dict, C.int(MPConvStackValType_O.kMPConvDict))
						continue
					}
					(^C.int)(uintptr(dict) + 12)^ = copyID
					ga_append(gap, '{')
					v := MPConvStackVal_O{}
					v.type = C.int(MPConvStackValType_O.kMPConvDict)
					v.saved_copyID = saved
					(^rawptr)(&v.data[0])^ = dict
					(^rawptr)(&v.data[8])^ = rawptr(uintptr(pt) + PT_DICT_OFF_O)
					(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(dict) + 48))^
					(^C.size_t)(&v.data[24])^ = C.size_t(used)
					mpconv_stack_push_o(mpstack, v)
				}
			} else {
				ga_append(gap, ')')
				mpconv_stack_pop_o(mpstack)
			}
			continue
		} else {
			arg := (^rawptr)(&cur.data[0])^
			todo := (^C.size_t)(&cur.data[16])^
			if todo == 0 {
				ga_append(gap, ']')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			if arg != (^rawptr)(&cur.data[8])^ {
				ga_concat_len(gap, cstring(", "), 2)
			}
			tv = (^Typval_T)(uintptr(arg))
			(^rawptr)(&cur.data[0])^ = rawptr(uintptr(arg) + 16)
			(^C.size_t)(&cur.data[16])^ = todo - 1
		}
		if convert_one_value_string_o(gap, mpstack, cur, tv, copyID, objname) == FAIL_E {
			mpconv_stack_destroy_o(mpstack)
			return FAIL_E
		}
	}
	mpconv_stack_destroy_o(mpstack)
	return OK_E
}

// String-mode driver (encode_vim_to_string).
encode_vim_to_string_o :: proc "c" (gap: ^Garray, tv: ^Typval_T, objname: cstring) -> C.int {
	context = runtime.default_context()
	save_flag := encode_recurse_echo_g
	encode_recurse_echo_g = false
	copyID := get_copyID()
	mpstack := MPConvStack_O{}
	mpconv_stack_init_o(&mpstack)
	if convert_one_value_string_o(gap, &mpstack, nil, tv, copyID, objname) == FAIL_E {
		mpconv_stack_destroy_o(&mpstack)
		encode_recurse_echo_g = save_flag
		return FAIL_E
	}
	ret := encode_str_walker_o(gap, &mpstack, tv, copyID, objname)
	encode_recurse_echo_g = save_flag
	return ret
}

// String representation with quotes (encode_tv2string).
@(export)
encode_tv2string :: proc "c" (tv: ^Typval_T, length: ^C.size_t) -> cstring {
	context = runtime.default_context()
	ga := Garray{}
	ga_init(&ga, 1, 80)
	evs_ret := encode_vim_to_string_o(&ga, tv, cstring("encode_tv2string() argument"))
	_ = evs_ret
	nvim_odin_set_echo_emsg_e(false)
	if length != nil {
		length^ = C.size_t(ga.ga_len)
	}
	ga_append(&ga, 0)
	return transmute(cstring)(ga.ga_data)
}

// —— Batch 23h: json-mode engine ——

// JSON float (E474-FAIL on nan/inf, else %g).
encode_json_float_o :: proc "c" (gap: ^Garray, flt: f64) -> C.int {
	context = runtime.default_context()
	if xfpclassify(flt) == FP_NAN_O {
		emsg(cstring("E474: Unable to represent NaN value in JSON"))
		return FAIL_E
	}
	if xfpclassify(flt) == FP_INFINITE_O {
		emsg(cstring("E474: Unable to represent infinity in JSON"))
		return FAIL_E
	}
	numbuf: [65]u8
	n := vim_snprintf_safelen_e(&numbuf[0], 65, cstring("%g"), flt)
	ga_concat_len(gap, transmute(cstring)(&numbuf[0]), n)
	return OK_E
}

// JSON-mode RECURSE (E724 once, no emit).
encode_json_recurse_o :: proc "c" (mpstack: ^MPConvStack_O, val: rawptr, conv_type: C.int) {
	context = runtime.default_context()
	if !nvim_odin_get_echo_emsg_e() {
		nvim_odin_set_echo_emsg_e(true)
		emsg(cstring("E724: unable to correctly dump variable with self-referencing container"))
	}
}

// JSON-mode CONVERT_ONE_VALUE (ALLOW_SPECIALS=true: full special dispatch).
convert_one_value_json_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, cur_mpsv: ^MPConvStackVal_O, tv: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	if tv.v_type == VAR_STRING {
		s := transmute(cstring)(tv.vval)
		if s == nil {
			return convert_to_json_string_o(gap, nil, 0)
		}
		return convert_to_json_string_o(gap, s, C.size_t(libc.strlen(s)))
	} else if tv.v_type == VAR_NUMBER {
		encode_str_number_o(gap, transmute(C.longlong)(tv.vval))
	} else if tv.v_type == VAR_FLOAT {
		return encode_json_float_o(gap, transmute(f64)(tv.vval))
	} else if tv.v_type == VAR_BLOB {
		b := rawptr(tv.vval)
		length := tv_blob_len_o(b)
		if length == 0 {
			ga_concat_len(gap, cstring("[]"), 2)
		} else {
			ga_append(gap, '[')
			numbuf: [65]u8
			i: C.int = 0
			for i < length {
				if i > 0 {
					ga_concat_len(gap, cstring(", "), 2)
				}
				n := libc.snprintf(&numbuf[0], 65, cstring("%d"), C.int(tv_blob_get_o(b, i)))
				ga_concat_len(gap, transmute(cstring)(&numbuf[0]), C.size_t(n))
				i += 1
			}
			ga_append(gap, ']')
		}
	} else if tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL {
		return conv_error_o(cstring("E474: Error while dumping %s, %s: attempt to dump function reference"), mpstack, objname)
	} else if tv.v_type == VAR_LIST {
		l := rawptr(tv.vval)
		if l == nil || tv_list_len_o(l) == 0 {
			ga_concat_len(gap, cstring("[]"), 2)
		} else {
			saved := tv_list_copyid_o(l)
			if (^C.int)(uintptr(l) + 68)^ == copyID {
				encode_json_recurse_o(mpstack, l, C.int(MPConvStackValType_O.kMPConvList))
			} else {
				(^C.int)(uintptr(l) + 68)^ = copyID
				ga_append(gap, '[')
				v := MPConvStackVal_O{}
				v.type = C.int(MPConvStackValType_O.kMPConvList)
				v.tv = tv
				v.saved_copyID = saved
				(^rawptr)(&v.data[0])^ = l
				(^rawptr)(&v.data[8])^ = tv_list_first_o(l)
				mpconv_stack_push_o(mpstack, v)
			}
		}
	} else if tv.v_type == VAR_BOOL {
		if C.int(transmute(C.longlong)(tv.vval)) != 0 {
			ga_concat_len(gap, cstring("true"), 4)
		} else {
			ga_concat_len(gap, cstring("false"), 5)
		}
	} else if tv.v_type == VAR_SPECIAL {
		ga_concat_len(gap, cstring("null"), 4)
	} else if tv.v_type == VAR_DICT {
		d := rawptr(tv.vval)
		if d == nil || (^C.size_t)(uintptr(d) + 24)^ == 0 {
			ga_concat_len(gap, cstring("{}"), 2)
		} else if (^C.size_t)(uintptr(d) + 24)^ == 2 {
			type_di := tv_dict_find(d, cstring("_TYPE"), 5)
			val_di := tv_dict_find(d, cstring("_VAL"), 4)
			special_done := false
			special_fail := false
			if type_di != nil && (^C.int)(uintptr(type_di))^ == VAR_LIST && val_di != nil {
				ttv := (^Typval_T)(uintptr(type_di))
				tl := rawptr(ttv.vval)
				i: C.int = 0
				for i < 8 {
					if tl == eval_msgpack_type_lists_e[i] {
						break
					}
					i += 1
				}
				if i < 8 {
					vv := (^Typval_T)(uintptr(val_di))
					if i == KMPNIL_O {
						ga_concat_len(gap, cstring("null"), 4)
						special_done = true
					} else if i == KMPBOOLEAN_O {
						if vv.v_type != VAR_NUMBER {
							special_fail = true
						} else {
							if transmute(C.longlong)(vv.vval) != 0 {
								ga_concat_len(gap, cstring("true"), 4)
							} else {
								ga_concat_len(gap, cstring("false"), 5)
							}
							special_done = true
						}
					} else if i == KMPINTEGER_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							if tv_list_len_o(vl) != 4 {
								special_fail = true
							} else {
								sli := tv_list_first_o(vl)
								stv := (^Typval_T)(uintptr(sli) + 16)
								hli := (^rawptr)(uintptr(sli))^
								htv := (^Typval_T)(uintptr(hli) + 16)
								bli := (^rawptr)(uintptr(hli))^
								btv := (^Typval_T)(uintptr(bli) + 16)
								lli := tv_list_last_o(vl)
								ltv := (^Typval_T)(uintptr(lli) + 16)
								if stv.v_type != VAR_NUMBER || transmute(C.longlong)(stv.vval) == 0 || htv.v_type != VAR_NUMBER || transmute(C.longlong)(htv.vval) < 0 || btv.v_type != VAR_NUMBER || transmute(C.longlong)(btv.vval) < 0 || ltv.v_type != VAR_NUMBER || transmute(C.longlong)(ltv.vval) < 0 {
									special_fail = true
								} else {
									number := u64(transmute(C.longlong)(htv.vval)) << 62 | u64(transmute(C.longlong)(btv.vval)) << 31 | u64(transmute(C.longlong)(ltv.vval))
									if transmute(C.longlong)(stv.vval) > 0 {
										numbuf: [65]u8
										n := libc.snprintf(&numbuf[0], 65, cstring("%llu"), number)
										ga_concat_len(gap, transmute(cstring)(&numbuf[0]), C.size_t(n))
									} else {
										encode_str_number_o(gap, -i64(number))
									}
									special_done = true
								}
							}
						}
					} else if i == KMPFLOAT_O {
						if vv.v_type != VAR_FLOAT {
							special_fail = true
						} else {
							if encode_json_float_o(gap, transmute(f64)(vv.vval)) == FAIL_E {
								return FAIL_E
							}
							special_done = true
						}
					} else if i == KMPSTRING_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							blen: C.size_t = 0
							bbuf: rawptr = nil
							if !encode_vim_list_to_buf(rawptr(vv.vval), &blen, &bbuf) {
								special_fail = true
							} else {
								if convert_to_json_string_o(gap, transmute(cstring)(bbuf), blen) == FAIL_E {
									xfree(bbuf)
									return FAIL_E
								}
								xfree(bbuf)
								special_done = true
							}
						}
					} else if i == KMPARRAY_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							al := rawptr(vv.vval)
							saved := tv_list_copyid_o(al)
							if (^C.int)(uintptr(al) + 68)^ == copyID {
								encode_json_recurse_o(mpstack, al, C.int(MPConvStackValType_O.kMPConvList))
								special_done = true
							} else {
								(^C.int)(uintptr(al) + 68)^ = copyID
								ga_append(gap, '[')
								v := MPConvStackVal_O{}
								v.type = C.int(MPConvStackValType_O.kMPConvList)
								v.tv = tv
								v.saved_copyID = saved
								(^rawptr)(&v.data[0])^ = al
								(^rawptr)(&v.data[8])^ = tv_list_first_o(al)
								mpconv_stack_push_o(mpstack, v)
								special_done = true
							}
						}
					} else if i == KMPMAP_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							if vl == nil || tv_list_len_o(vl) == 0 {
								ga_concat_len(gap, cstring("{}"), 2)
								special_done = true
							} else {
								ok := true
								li := tv_list_first_o(vl)
								for li != nil {
									itv := (^Typval_T)(uintptr(li) + 16)
									if itv.v_type != VAR_LIST || tv_list_len_o(rawptr(itv.vval)) != 2 {
										ok = false
										break
									}
									li = (^rawptr)(uintptr(li))^
								}
								if !ok {
									special_fail = true
								} else {
									saved := tv_list_copyid_o(vl)
									if (^C.int)(uintptr(vl) + 68)^ == copyID {
										encode_json_recurse_o(mpstack, vl, C.int(MPConvStackValType_O.kMPConvPairs))
										special_done = true
									} else {
										(^C.int)(uintptr(vl) + 68)^ = copyID
										ga_append(gap, '{')
										v := MPConvStackVal_O{}
										v.type = C.int(MPConvStackValType_O.kMPConvPairs)
										v.tv = tv
										v.saved_copyID = saved
										(^rawptr)(&v.data[0])^ = vl
										(^rawptr)(&v.data[8])^ = tv_list_first_o(vl)
										mpconv_stack_push_o(mpstack, v)
										special_done = true
									}
								}
							}
						}
					} else {
						bad := false
						if vv.v_type != VAR_LIST {
							bad = true
						} else {
							vl := rawptr(vv.vval)
							if tv_list_len_o(vl) != 2 {
								bad = true
							} else {
								ftv := (^Typval_T)(uintptr(tv_list_first_o(vl)) + 16)
								ltv := (^Typval_T)(uintptr(tv_list_last_o(vl)) + 16)
								if ftv.v_type != VAR_NUMBER {
									bad = true
								} else {
									etype := transmute(C.longlong)(ftv.vval)
									if etype > 127 || etype < -128 || ltv.v_type != VAR_LIST {
										bad = true
									}
								}
							}
						}
						if bad {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							ltv := (^Typval_T)(uintptr(tv_list_last_o(vl)) + 16)
							blen: C.size_t = 0
							bbuf: rawptr = nil
							if !encode_vim_list_to_buf(rawptr(ltv.vval), &blen, &bbuf) {
								special_fail = true
							} else {
								xfree(bbuf)
								emsg(cstring("E474: Unable to convert EXT string to JSON"))
								return FAIL_E
							}
						}
					}
				}
			}
			if !special_done && !special_fail {
				saved := (^C.int)(uintptr(d) + 12)^
				if (^C.int)(uintptr(d) + 12)^ == copyID {
					encode_json_recurse_o(mpstack, d, C.int(MPConvStackValType_O.kMPConvDict))
				} else {
					(^C.int)(uintptr(d) + 12)^ = copyID
					ga_append(gap, '{')
					v := MPConvStackVal_O{}
					v.type = C.int(MPConvStackValType_O.kMPConvDict)
					v.tv = tv
					v.saved_copyID = saved
					(^rawptr)(&v.data[0])^ = d
					(^rawptr)(&v.data[8])^ = rawptr(uintptr(tv) + 8)
					(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(d) + 48))^
					(^C.size_t)(&v.data[24])^ = (^C.size_t)(uintptr(d) + 24)^
					mpconv_stack_push_o(mpstack, v)
				}
			}
		} else {
			saved := (^C.int)(uintptr(d) + 12)^
			if (^C.int)(uintptr(d) + 12)^ == copyID {
				encode_json_recurse_o(mpstack, d, C.int(MPConvStackValType_O.kMPConvDict))
			} else {
				(^C.int)(uintptr(d) + 12)^ = copyID
				ga_append(gap, '{')
				v := MPConvStackVal_O{}
				v.type = C.int(MPConvStackValType_O.kMPConvDict)
				v.tv = tv
				v.saved_copyID = saved
				(^rawptr)(&v.data[0])^ = d
				(^rawptr)(&v.data[8])^ = rawptr(uintptr(tv) + 8)
				(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(d) + 48))^
				(^C.size_t)(&v.data[24])^ = (^C.size_t)(uintptr(d) + 24)^
				mpconv_stack_push_o(mpstack, v)
			}
		}
	}
	return OK_E
}

// JSON-mode walker continuation (same shape; json key quoting,
// pairs key-check, partial conv_error).
encode_json_walker_o :: proc "c" (gap: ^Garray, mpstack: ^MPConvStack_O, tv_top: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	for mpstack.size > 0 {
		cur := mpconv_stack_last_o(mpstack)
		tv: ^Typval_T = nil
		if cur.type == C.int(MPConvStackValType_O.kMPConvDict) {
			todo := (^C.size_t)(&cur.data[24])^
			if todo == 0 {
				d := (^rawptr)(&cur.data[0])^
				(^C.int)(uintptr(d) + 12)^ = cur.saved_copyID
				ga_append(gap, '}')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			d := (^rawptr)(&cur.data[0])^
			if todo != (^C.size_t)(uintptr(d) + 24)^ {
				ga_concat_len(gap, cstring(", "), 2)
			}
			hi := (^rawptr)(&cur.data[16])^
			for (^rawptr)(uintptr(hi) + 8)^ == nil || (^rawptr)(uintptr(hi) + 8)^ == rawptr(&hash_removed) {
				hi = rawptr(uintptr(hi) + 16)
			}
			(^rawptr)(&cur.data[16])^ = hi
			di := rawptr(uintptr((^rawptr)(uintptr(hi) + 8)^) - 17)
			(^C.size_t)(&cur.data[24])^ = todo - 1
			(^rawptr)(&cur.data[16])^ = rawptr(uintptr(hi) + 16)
			key := transmute(cstring)((^rawptr)(uintptr(hi) + 8)^)
			if convert_to_json_string_o(gap, key, C.size_t(libc.strlen(key))) == FAIL_E {
				mpconv_stack_destroy_o(mpstack)
				return FAIL_E
			}
			ga_concat_len(gap, cstring(": "), 2)
			tv = (^Typval_T)(uintptr(di))
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvList) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				ga_append(gap, ']')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			l := (^rawptr)(&cur.data[0])^
			if li != tv_list_first_o(l) {
				ga_concat_len(gap, cstring(", "), 2)
			}
			tv = (^Typval_T)(uintptr(li) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvPairs) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				ga_append(gap, '}')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			l := (^rawptr)(&cur.data[0])^
			if li != tv_list_first_o(l) {
				ga_concat_len(gap, cstring(", "), 2)
			}
			pair := rawptr((^Typval_T)(uintptr(li) + 16).vval)
			ktv := (^Typval_T)(uintptr(tv_list_first_o(pair)) + 16)
			if !encode_check_json_key(ktv) {
				emsg(cstring("E474: Invalid key in special dictionary"))
				mpconv_stack_destroy_o(mpstack)
				return FAIL_E
			}
			if convert_one_value_json_o(gap, mpstack, cur, ktv, copyID, objname) == FAIL_E {
				mpconv_stack_destroy_o(mpstack)
				return FAIL_E
			}
			ga_concat_len(gap, cstring(": "), 2)
			tv = (^Typval_T)(uintptr(tv_list_last_o(pair)) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvPartial) || cur.type == C.int(MPConvStackValType_O.kMPConvPartialList) {
			mpconv_stack_destroy_o(mpstack)
			return FAIL_E
		} else {
			arg := (^rawptr)(&cur.data[0])^
			todo := (^C.size_t)(&cur.data[16])^
			if todo == 0 {
				ga_append(gap, ']')
				mpconv_stack_pop_o(mpstack)
				continue
			}
			if arg != (^rawptr)(&cur.data[8])^ {
				ga_concat_len(gap, cstring(", "), 2)
			}
			tv = (^Typval_T)(uintptr(arg))
			(^rawptr)(&cur.data[0])^ = rawptr(uintptr(arg) + 16)
			(^C.size_t)(&cur.data[16])^ = todo - 1
		}
		if convert_one_value_json_o(gap, mpstack, cur, tv, copyID, objname) == FAIL_E {
			mpconv_stack_destroy_o(mpstack)
			return FAIL_E
		}
	}
	mpconv_stack_destroy_o(mpstack)
	return OK_E
}

// JSON-mode driver (encode_vim_to_json).
encode_vim_to_json_o :: proc "c" (gap: ^Garray, tv: ^Typval_T, objname: cstring) -> C.int {
	context = runtime.default_context()
	copyID := get_copyID()
	mpstack := MPConvStack_O{}
	mpconv_stack_init_o(&mpstack)
	if convert_one_value_json_o(gap, &mpstack, nil, tv, copyID, objname) == FAIL_E {
		mpconv_stack_destroy_o(&mpstack)
		return FAIL_E
	}
	return encode_json_walker_o(gap, &mpstack, tv, copyID, objname)
}

// JSON string representation (encode_tv2json).
@(export)
encode_tv2json :: proc "c" (tv: ^Typval_T, length: ^C.size_t) -> cstring {
	context = runtime.default_context()
	ga := Garray{}
	ga_init(&ga, 1, 80)
	evj_ret := encode_vim_to_json_o(&ga, tv, cstring("encode_tv2json() argument"))
	if evj_ret == FAIL_E {
		ga_clear(&ga)
	}
	nvim_odin_set_echo_emsg_e(false)
	if length != nil {
		length^ = C.size_t(ga.ga_len)
	}
	ga_append(&ga, 0)
	return transmute(cstring)(ga.ga_data)
}

// —— Batch 23i: msgpack-mode engine ——
foreign _ {
	@(link_name = "mpack_check_buffer")
	mpack_check_buffer_e :: proc "c" (packer: ^PackerBuffer_O) ---
	@(link_name = "mpack_uint64")
	mpack_uint64_e :: proc "c" (ptr: rawptr, i: u64) ---
	@(link_name = "mpack_integer")
	mpack_integer_e :: proc "c" (ptr: rawptr, i: i64) ---
	@(link_name = "mpack_float8")
	mpack_float8_e :: proc "c" (ptr: rawptr, d: f64) ---
	@(link_name = "mpack_str")
	mpack_str_e :: proc "c" (str: NvimString, packer: ^PackerBuffer_O) ---
	@(link_name = "mpack_bin")
	mpack_bin_e :: proc "c" (str: NvimString, packer: ^PackerBuffer_O) ---
	@(link_name = "mpack_ext")
	mpack_ext_e :: proc "c" (buf: ^u8, length: C.size_t, type: i8, packer: ^PackerBuffer_O) ---
}

// packer.h static-inline writers over the mirror.
mpack_w_o :: #force_inline proc "c" (packer: ^PackerBuffer_O, byte: u8) {
	packer.ptr^ = byte
	packer.ptr = (^u8)(uintptr(packer.ptr) + 1)
}
mpack_w2_o :: proc "c" (packer: ^PackerBuffer_O, v: u32) {
	context = runtime.default_context()
	mpack_w_o(packer, u8((v >> 8) & 0xFF))
	mpack_w_o(packer, u8(v & 0xFF))
}
mpack_w4_o :: proc "c" (packer: ^PackerBuffer_O, v: u32) {
	context = runtime.default_context()
	mpack_w_o(packer, u8((v >> 24) & 0xFF))
	mpack_w_o(packer, u8((v >> 16) & 0xFF))
	mpack_w_o(packer, u8((v >> 8) & 0xFF))
	mpack_w_o(packer, u8(v & 0xFF))
}
mpack_uint_o :: proc "c" (packer: ^PackerBuffer_O, val: u32) {
	context = runtime.default_context()
	if val > 0xFFFF {
		mpack_w_o(packer, 0xCE)
		mpack_w4_o(packer, val)
	} else if val > 0xFF {
		mpack_w_o(packer, 0xCD)
		mpack_w2_o(packer, val)
	} else if val > 0x7F {
		mpack_w_o(packer, 0xCC)
		mpack_w_o(packer, u8(val))
	} else {
		mpack_w_o(packer, u8(val))
	}
}
mpack_nil_o :: #force_inline proc "c" (packer: ^PackerBuffer_O) {
	mpack_w_o(packer, 0xC0)
}
mpack_bool_o :: proc "c" (packer: ^PackerBuffer_O, val: bool) {
	context = runtime.default_context()
	if val {
		mpack_w_o(packer, 0xC3)
	} else {
		mpack_w_o(packer, 0xC2)
	}
}
mpack_array_o :: proc "c" (packer: ^PackerBuffer_O, length: u32) {
	context = runtime.default_context()
	if length < 0x10 {
		mpack_w_o(packer, 0x90 | u8(length))
	} else if length < 0x10000 {
		mpack_w_o(packer, 0xDC)
		mpack_w2_o(packer, length)
	} else {
		mpack_w_o(packer, 0xDD)
		mpack_w4_o(packer, length)
	}
}
mpack_map_o :: proc "c" (packer: ^PackerBuffer_O, length: u32) {
	context = runtime.default_context()
	if length < 0x10 {
		mpack_w_o(packer, 0x80 | u8(length))
	} else if length < 0x10000 {
		mpack_w_o(packer, 0xDE)
		mpack_w2_o(packer, length)
	} else {
		mpack_w_o(packer, 0xDF)
		mpack_w4_o(packer, length)
	}
}

// Msgpack-mode RECURSE (conv_error E5005 FAIL).
encode_msgpack_recurse_o :: proc "c" (packer: ^PackerBuffer_O, mpstack: ^MPConvStack_O, val: rawptr, conv_type: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	return conv_error_o(cstring("E5005: Unable to dump %s: container references itself in %s"), mpstack, objname)
}

// Msgpack-mode CONVERT_ONE_VALUE (ALLOW_SPECIALS=true).
convert_one_value_msgpack_o :: proc "c" (packer: ^PackerBuffer_O, mpstack: ^MPConvStack_O, cur_mpsv: ^MPConvStackVal_O, tv: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	mpack_check_buffer_e(packer)
	if tv.v_type == VAR_STRING {
		s := transmute(^u8)(tv.vval)
		n: C.size_t = 0
		if s != nil {
			n = C.size_t(libc.strlen(transmute(cstring)(s)))
		}
		mpack_bin_e(NvimString{data = transmute(cstring)(s), size = n}, packer)
	} else if tv.v_type == VAR_NUMBER {
		mpack_integer_e(rawptr(&packer.ptr), transmute(i64)(tv.vval))
	} else if tv.v_type == VAR_FLOAT {
		mpack_float8_e(rawptr(&packer.ptr), transmute(f64)(tv.vval))
	} else if tv.v_type == VAR_BLOB {
		b := rawptr(tv.vval)
		length := tv_blob_len_o(b)
		data: ^u8 = nil
		if b != nil {
			data = (^u8)((^rawptr)(uintptr(b) + 16)^)
		}
		mpack_bin_e(NvimString{data = transmute(cstring)(data), size = C.size_t(length)}, packer)
	} else if tv.v_type == VAR_FUNC || tv.v_type == VAR_PARTIAL {
		return conv_error_o(cstring("E5004: Error while dumping %s, %s: attempt to dump function reference"), mpstack, objname)
	} else if tv.v_type == VAR_LIST {
		l := rawptr(tv.vval)
		if l == nil || tv_list_len_o(l) == 0 {
			mpack_array_o(packer, 0)
		} else {
			saved := tv_list_copyid_o(l)
			if (^C.int)(uintptr(l) + 68)^ == copyID {
				return encode_msgpack_recurse_o(packer, mpstack, l, C.int(MPConvStackValType_O.kMPConvList), objname)
			}
			(^C.int)(uintptr(l) + 68)^ = copyID
			mpack_array_o(packer, u32(tv_list_len_o(l)))
			v := MPConvStackVal_O{}
			v.type = C.int(MPConvStackValType_O.kMPConvList)
			v.tv = tv
			v.saved_copyID = saved
			(^rawptr)(&v.data[0])^ = l
			(^rawptr)(&v.data[8])^ = tv_list_first_o(l)
			mpconv_stack_push_o(mpstack, v)
		}
	} else if tv.v_type == VAR_BOOL {
		mpack_bool_o(packer, transmute(C.longlong)(tv.vval) != 0)
	} else if tv.v_type == VAR_SPECIAL {
		mpack_nil_o(packer)
	} else if tv.v_type == VAR_DICT {
		d := rawptr(tv.vval)
		if d == nil || (^C.size_t)(uintptr(d) + 24)^ == 0 {
			mpack_map_o(packer, 0)
		} else if (^C.size_t)(uintptr(d) + 24)^ == 2 {
			type_di := tv_dict_find(d, cstring("_TYPE"), 5)
			val_di := tv_dict_find(d, cstring("_VAL"), 4)
			special_done := false
			special_fail := false
			if type_di != nil && (^C.int)(uintptr(type_di))^ == VAR_LIST && val_di != nil {
				ttv := (^Typval_T)(uintptr(type_di))
				tl := rawptr(ttv.vval)
				i: C.int = 0
				for i < 8 {
					if tl == eval_msgpack_type_lists_e[i] {
						break
					}
					i += 1
				}
				if i < 8 {
					vv := (^Typval_T)(uintptr(val_di))
					if i == KMPNIL_O {
						mpack_nil_o(packer)
						special_done = true
					} else if i == KMPBOOLEAN_O {
						if vv.v_type != VAR_NUMBER {
							special_fail = true
						} else {
							mpack_bool_o(packer, transmute(C.longlong)(vv.vval) != 0)
							special_done = true
						}
					} else if i == KMPINTEGER_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							if tv_list_len_o(vl) != 4 {
								special_fail = true
							} else {
								sli := tv_list_first_o(vl)
								stv := (^Typval_T)(uintptr(sli) + 16)
								hli := (^rawptr)(uintptr(sli))^
								htv := (^Typval_T)(uintptr(hli) + 16)
								bli := (^rawptr)(uintptr(hli))^
								btv := (^Typval_T)(uintptr(bli) + 16)
								lli := tv_list_last_o(vl)
								ltv := (^Typval_T)(uintptr(lli) + 16)
								if stv.v_type != VAR_NUMBER || transmute(C.longlong)(stv.vval) == 0 || htv.v_type != VAR_NUMBER || transmute(C.longlong)(htv.vval) < 0 || btv.v_type != VAR_NUMBER || transmute(C.longlong)(btv.vval) < 0 || ltv.v_type != VAR_NUMBER || transmute(C.longlong)(ltv.vval) < 0 {
									special_fail = true
								} else {
									number := u64(transmute(C.longlong)(htv.vval)) << 62 | u64(transmute(C.longlong)(btv.vval)) << 31 | u64(transmute(C.longlong)(ltv.vval))
									if transmute(C.longlong)(stv.vval) > 0 {
										mpack_uint64_e(rawptr(&packer.ptr), number)
									} else {
										mpack_integer_e(rawptr(&packer.ptr), -i64(number))
									}
									special_done = true
								}
							}
						}
					} else if i == KMPFLOAT_O {
						if vv.v_type != VAR_FLOAT {
							special_fail = true
						} else {
							mpack_float8_e(rawptr(&packer.ptr), transmute(f64)(vv.vval))
							special_done = true
						}
					} else if i == KMPSTRING_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							blen: C.size_t = 0
							bbuf: rawptr = nil
							if !encode_vim_list_to_buf(rawptr(vv.vval), &blen, &bbuf) {
								special_fail = true
							} else {
								mpack_str_e(NvimString{data = transmute(cstring)(bbuf), size = blen}, packer)
								xfree(bbuf)
								special_done = true
							}
						}
					} else if i == KMPARRAY_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							al := rawptr(vv.vval)
							saved := tv_list_copyid_o(al)
							if (^C.int)(uintptr(al) + 68)^ == copyID {
								return encode_msgpack_recurse_o(packer, mpstack, al, C.int(MPConvStackValType_O.kMPConvList), objname)
							}
							(^C.int)(uintptr(al) + 68)^ = copyID
							mpack_array_o(packer, u32(tv_list_len_o(al)))
							v := MPConvStackVal_O{}
							v.type = C.int(MPConvStackValType_O.kMPConvList)
							v.tv = tv
							v.saved_copyID = saved
							(^rawptr)(&v.data[0])^ = al
							(^rawptr)(&v.data[8])^ = tv_list_first_o(al)
							mpconv_stack_push_o(mpstack, v)
							special_done = true
						}
					} else if i == KMPMAP_O {
						if vv.v_type != VAR_LIST {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							if vl == nil || tv_list_len_o(vl) == 0 {
								mpack_map_o(packer, 0)
								special_done = true
							} else {
								ok := true
								li := tv_list_first_o(vl)
								for li != nil {
									itv := (^Typval_T)(uintptr(li) + 16)
									if itv.v_type != VAR_LIST || tv_list_len_o(rawptr(itv.vval)) != 2 {
										ok = false
										break
									}
									li = (^rawptr)(uintptr(li))^
								}
								if !ok {
									special_fail = true
								} else {
									saved := tv_list_copyid_o(vl)
									if (^C.int)(uintptr(vl) + 68)^ == copyID {
										return encode_msgpack_recurse_o(packer, mpstack, vl, C.int(MPConvStackValType_O.kMPConvPairs), objname)
									}
									(^C.int)(uintptr(vl) + 68)^ = copyID
									mpack_map_o(packer, u32(tv_list_len_o(vl)))
									v := MPConvStackVal_O{}
									v.type = C.int(MPConvStackValType_O.kMPConvPairs)
									v.tv = tv
									v.saved_copyID = saved
									(^rawptr)(&v.data[0])^ = vl
									(^rawptr)(&v.data[8])^ = tv_list_first_o(vl)
									mpconv_stack_push_o(mpstack, v)
									special_done = true
								}
							}
						}
					} else {
						bad := false
						if vv.v_type != VAR_LIST {
							bad = true
						} else {
							vl := rawptr(vv.vval)
							if tv_list_len_o(vl) != 2 {
								bad = true
							} else {
								ftv := (^Typval_T)(uintptr(tv_list_first_o(vl)) + 16)
								ltv := (^Typval_T)(uintptr(tv_list_last_o(vl)) + 16)
								if ftv.v_type != VAR_NUMBER {
									bad = true
								} else {
									etype := transmute(C.longlong)(ftv.vval)
									if etype > 127 || etype < -128 || ltv.v_type != VAR_LIST {
										bad = true
									}
								}
							}
						}
						if bad {
							special_fail = true
						} else {
							vl := rawptr(vv.vval)
							ltv := (^Typval_T)(uintptr(tv_list_last_o(vl)) + 16)
							ftv := (^Typval_T)(uintptr(tv_list_first_o(vl)) + 16)
							blen: C.size_t = 0
							bbuf: rawptr = nil
							if !encode_vim_list_to_buf(rawptr(ltv.vval), &blen, &bbuf) {
								special_fail = true
							} else {
								mpack_ext_e(transmute(^u8)(bbuf), blen, i8(transmute(C.longlong)(ftv.vval)), packer)
								xfree(bbuf)
								special_done = true
							}
						}
					}
				}
			}
			if !special_done && !special_fail {
				saved := (^C.int)(uintptr(d) + 12)^
				if (^C.int)(uintptr(d) + 12)^ == copyID {
					return encode_msgpack_recurse_o(packer, mpstack, d, C.int(MPConvStackValType_O.kMPConvDict), objname)
				}
				(^C.int)(uintptr(d) + 12)^ = copyID
				mpack_map_o(packer, u32((^C.size_t)(uintptr(d) + 24)^))
				v := MPConvStackVal_O{}
				v.type = C.int(MPConvStackValType_O.kMPConvDict)
				v.tv = tv
				v.saved_copyID = saved
				(^rawptr)(&v.data[0])^ = d
				(^rawptr)(&v.data[8])^ = rawptr(uintptr(tv) + 8)
				(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(d) + 48))^
				(^C.size_t)(&v.data[24])^ = (^C.size_t)(uintptr(d) + 24)^
				mpconv_stack_push_o(mpstack, v)
			}
		} else {
			saved := (^C.int)(uintptr(d) + 12)^
			if (^C.int)(uintptr(d) + 12)^ == copyID {
				return encode_msgpack_recurse_o(packer, mpstack, d, C.int(MPConvStackValType_O.kMPConvDict), objname)
			}
			(^C.int)(uintptr(d) + 12)^ = copyID
			mpack_map_o(packer, u32((^C.size_t)(uintptr(d) + 24)^))
			v := MPConvStackVal_O{}
			v.type = C.int(MPConvStackValType_O.kMPConvDict)
			v.tv = tv
			v.saved_copyID = saved
			(^rawptr)(&v.data[0])^ = d
			(^rawptr)(&v.data[8])^ = rawptr(uintptr(tv) + 8)
			(^rawptr)(&v.data[16])^ = (^rawptr)(rawptr(uintptr(d) + 48))^
			(^C.size_t)(&v.data[24])^ = (^C.size_t)(uintptr(d) + 24)^
			mpconv_stack_push_o(mpstack, v)
		}
	}
	return OK_E
}

// Msgpack-mode walker continuation (no separators; str keys).
encode_msgpack_walker_o :: proc "c" (packer: ^PackerBuffer_O, mpstack: ^MPConvStack_O, tv_top: ^Typval_T, copyID: C.int, objname: cstring) -> C.int {
	context = runtime.default_context()
	for mpstack.size > 0 {
		cur := mpconv_stack_last_o(mpstack)
		tv: ^Typval_T = nil
		if cur.type == C.int(MPConvStackValType_O.kMPConvDict) {
			todo := (^C.size_t)(&cur.data[24])^
			if todo == 0 {
				d := (^rawptr)(&cur.data[0])^
				(^C.int)(uintptr(d) + 12)^ = cur.saved_copyID
				mpconv_stack_pop_o(mpstack)
				continue
			}
			hi := (^rawptr)(&cur.data[16])^
			for (^rawptr)(uintptr(hi) + 8)^ == nil || (^rawptr)(uintptr(hi) + 8)^ == rawptr(&hash_removed) {
				hi = rawptr(uintptr(hi) + 16)
			}
			(^rawptr)(&cur.data[16])^ = hi
			di := rawptr(uintptr((^rawptr)(uintptr(hi) + 8)^) - 17)
			(^C.size_t)(&cur.data[24])^ = todo - 1
			(^rawptr)(&cur.data[16])^ = rawptr(uintptr(hi) + 16)
			key := transmute(cstring)((^rawptr)(uintptr(hi) + 8)^)
			mpack_str_e(NvimString{data = key, size = C.size_t(libc.strlen(key))}, packer)
			tv = (^Typval_T)(uintptr(di))
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvList) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				mpconv_stack_pop_o(mpstack)
				continue
			}
			l := (^rawptr)(&cur.data[0])^
			tv = (^Typval_T)(uintptr(li) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else if cur.type == C.int(MPConvStackValType_O.kMPConvPairs) {
			li := (^rawptr)(&cur.data[8])^
			if li == nil {
				l := (^rawptr)(&cur.data[0])^
				tv_list_set_copyid_o(l, cur.saved_copyID)
				mpconv_stack_pop_o(mpstack)
				continue
			}
			pair := rawptr((^Typval_T)(uintptr(li) + 16).vval)
			if convert_one_value_msgpack_o(packer, mpstack, cur, (^Typval_T)(uintptr(tv_list_first_o(pair)) + 16), copyID, objname) == FAIL_E {
				mpconv_stack_destroy_o(mpstack)
				return FAIL_E
			}
			tv = (^Typval_T)(uintptr(tv_list_last_o(pair)) + 16)
			(^rawptr)(&cur.data[8])^ = (^rawptr)(uintptr(li))^
		} else {
			mpconv_stack_destroy_o(mpstack)
			return FAIL_E
		}
		if convert_one_value_msgpack_o(packer, mpstack, cur, tv, copyID, objname) == FAIL_E {
			mpconv_stack_destroy_o(mpstack)
			return FAIL_E
		}
	}
	mpconv_stack_destroy_o(mpstack)
	return OK_E
}

// Msgpack-mode driver (encode_vim_to_msgpack).
encode_vim_to_msgpack_o :: proc "c" (packer: ^PackerBuffer_O, tv: ^Typval_T, objname: cstring) -> C.int {
	context = runtime.default_context()
	copyID := get_copyID()
	mpstack := MPConvStack_O{}
	mpconv_stack_init_o(&mpstack)
	if convert_one_value_msgpack_o(packer, &mpstack, nil, tv, copyID, objname) == FAIL_E {
		mpconv_stack_destroy_o(&mpstack)
		return FAIL_E
	}
	return encode_msgpack_walker_o(packer, &mpstack, tv, copyID, objname)
}

// Exact-name alias for live C callers (shada.c) after cutover.
@(export)
encode_vim_to_msgpack :: proc "c" (packer: ^PackerBuffer_O, tv: ^Typval_T, objname: cstring) -> C.int {
	context = runtime.default_context()
	return encode_vim_to_msgpack_o(packer, tv, objname)
}

// —— Batch 23j: decode.c json stacks + decoder_pop (dormant) ——

// ValuesStackItem mirror (decode.c): 24B cc-probed.
ValuesStackItem_O :: struct {
	is_special_string: bool, // 0
	didcomma:          bool, // 1
	didcolon:          bool, // 2
	_pad:              [5]u8,
	val:               Typval_T, // 8..24
}
#assert(size_of(ValuesStackItem_O) == 24)

// ContainerStackItem mirror (decode.c): 40B cc-probed.
ContainerStackItem_O :: struct {
	stack_index: C.size_t, // 0
	special_val: rawptr,   // 8
	s:           cstring,  // 16
	container:   Typval_T, // 24..40
}
#assert(size_of(ContainerStackItem_O) == 40)

// kvec mirrors for the two stacks.
ValuesStack_O :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: ^ValuesStackItem_O,
}
ContainersStack_O :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: ^ContainerStackItem_O,
}

// Values-stack ops (kvec semantics).
vstack_push_o :: proc "c" (st: ^ValuesStack_O, v: ValuesStackItem_O) {
	context = runtime.default_context()
	if st.n >= st.a {
		newcap: C.size_t = 8
		if st.a > 0 {
			newcap = st.a * 2
		}
		nbytes := newcap * 24
		if st.items == nil {
			st.items = (^ValuesStackItem_O)(xmalloc(nbytes))
		} else {
			st.items = (^ValuesStackItem_O)(xrealloc(rawptr(st.items), nbytes))
		}
		st.a = newcap
	}
	([^]ValuesStackItem_O)(st.items)[st.n] = v
	st.n += 1
}
vstack_pop_o :: proc "c" (st: ^ValuesStack_O) -> ValuesStackItem_O {
	context = runtime.default_context()
	st.n -= 1
	return ([^]ValuesStackItem_O)(st.items)[st.n]
}
vstack_item_o :: proc "c" (st: ^ValuesStack_O, i: C.size_t) -> ^ValuesStackItem_O {
	context = runtime.default_context()
	return &([^]ValuesStackItem_O)(st.items)[i]
}

// Container-stack ops (kvec semantics).
cstack_push_o :: proc "c" (st: ^ContainersStack_O, v: ContainerStackItem_O) {
	context = runtime.default_context()
	if st.n >= st.a {
		newcap: C.size_t = 8
		if st.a > 0 {
			newcap = st.a * 2
		}
		nbytes := newcap * 40
		if st.items == nil {
			st.items = (^ContainerStackItem_O)(xmalloc(nbytes))
		} else {
			st.items = (^ContainerStackItem_O)(xrealloc(rawptr(st.items), nbytes))
		}
		st.a = newcap
	}
	([^]ContainerStackItem_O)(st.items)[st.n] = v
	st.n += 1
}
cstack_pop_o :: proc "c" (st: ^ContainersStack_O) -> ContainerStackItem_O {
	context = runtime.default_context()
	st.n -= 1
	return ([^]ContainerStackItem_O)(st.items)[st.n]
}
cstack_last_o :: proc "c" (st: ^ContainersStack_O) -> ^ContainerStackItem_O {
	context = runtime.default_context()
	return &([^]ContainerStackItem_O)(st.items)[st.n - 1]
}

// JSON decoder pop (decode.c json_decoder_pop, dormant).
json_decoder_pop_o :: proc "c" (obj: ValuesStackItem_O, stack: ^ValuesStack_O, container_stack: ^ContainersStack_O, pp: ^cstring, next_map_special: ^bool, didcomma: ^bool, didcolon: ^bool) -> C.int {
	context = runtime.default_context()
	mut_obj := obj
	if container_stack.n == 0 {
		vstack_push_o(stack, mut_obj)
		return OK_E
	}
	last_container := cstack_last_o(container_stack)^
	val_location := pp^
	if mut_obj.val.v_type == last_container.container.v_type && rawptr(mut_obj.val.vval) == rawptr(last_container.container.vval) {
		cstack_pop_o(container_stack)
		val_location = last_container.s
		last_container = cstack_last_o(container_stack)^
	}
	if last_container.container.v_type == VAR_LIST {
		l := rawptr(last_container.container.vval)
		if tv_list_len_o(l) != 0 && !mut_obj.didcomma {
			semsg(cstring("E474: Expected comma before list item: %s"), val_location)
			tv_clear(&mut_obj.val)
			return FAIL_E
		}
		tv_list_append_owned_tv(l, mut_obj.val)
	} else if last_container.stack_index == stack.n - 2 {
		if !mut_obj.didcolon {
			semsg(cstring("E474: Expected colon before dictionary value: %s"), val_location)
			tv_clear(&mut_obj.val)
			return FAIL_E
		}
		key := vstack_pop_o(stack)
		if last_container.special_val == nil {
			di := tv_dict_item_alloc(transmute(cstring)(key.val.vval))
			tv_clear(&key.val)
			if tv_dict_add(rawptr(last_container.container.vval), di) == FAIL_E {
				libc.abort()
			}
			(^Typval_T)(uintptr(di))^ = mut_obj.val
		} else {
			kv_pair := tv_list_alloc(2)
			tv_list_append_list(last_container.special_val, kv_pair)
			tv_list_append_owned_tv(kv_pair, key.val)
			tv_list_append_owned_tv(kv_pair, mut_obj.val)
		}
	} else {
		if !mut_obj.is_special_string && mut_obj.val.v_type != VAR_STRING {
			semsg(cstring("E474: Expected string key: %s"), pp^)
			tv_clear(&mut_obj.val)
			return FAIL_E
		} else if !mut_obj.didcomma && last_container.special_val == nil && (^C.size_t)(uintptr(rawptr(last_container.container.vval)) + 24)^ != 0 {
			semsg(cstring("E474: Expected comma before dictionary key: %s"), val_location)
			tv_clear(&mut_obj.val)
			return FAIL_E
		}
		if last_container.special_val == nil && (mut_obj.is_special_string || rawptr(mut_obj.val.vval) == nil || tv_dict_find(rawptr(last_container.container.vval), transmute(cstring)(mut_obj.val.vval), -1) != nil) {
			tv_clear(&mut_obj.val)
			cstack_pop_o(container_stack)
			last_val := vstack_item_o(stack, last_container.stack_index)^
			for stack.n > last_container.stack_index {
				popped := vstack_pop_o(stack)
				tv_clear(&popped.val)
			}
			pp^ = last_container.s
			didcomma^ = last_val.didcomma
			didcolon^ = last_val.didcolon
			next_map_special^ = true
			return OK_E
		}
		vstack_push_o(stack, mut_obj)
	}
	return OK_E
}

// —— Batch 23k: decode.c json string/number parsers + driver ——

// JSON double-quoted string parser (dormant plain until driver below).
parse_json_string_o :: proc "c" (buf: cstring, buf_len: C.size_t, pp: ^cstring, stack: ^ValuesStack_O, container_stack: ^ContainersStack_O, next_map_special: ^bool, didcomma: ^bool, didcolon: ^bool) -> C.int {
	context = runtime.default_context()
	e := uintptr(rawptr(buf)) + uintptr(buf_len)
	p := uintptr(rawptr(pp^))
	length: C.size_t = 0
	s := p + 1
	p = s
	ret: C.int = OK_E
	done := false
	for uintptr(p) < e && ([^]u8)(p)[0] != '"' && !done {
		if ([^]u8)(p)[0] == '\\' {
			p += 1
			if uintptr(p) >= e {
				semsg(cstring("E474: Unfinished escape sequence: %.*s"), C.int(buf_len), buf)
				ret = FAIL_E
				done = true
			} else if ([^]u8)(p)[0] == 'u' {
				if uintptr(p) + 4 >= e {
					semsg(cstring("E474: Unfinished unicode escape sequence: %.*s"), C.int(buf_len), buf)
					ret = FAIL_E
					done = true
				} else if !ascii_isxdigit_o(([^]u8)(p)[1]) || !ascii_isxdigit_o(([^]u8)(p)[2]) || !ascii_isxdigit_o(([^]u8)(p)[3]) || !ascii_isxdigit_o(([^]u8)(p)[4]) {
					semsg(cstring("E474: Expected four hex digits after \\u: %.*s"), C.int(uintptr(rawptr(buf)) + uintptr(buf_len) - (uintptr(p) - 1)), transmute(cstring)(p - 1))
					ret = FAIL_E
					done = true
				} else {
					length += 3
					p += 5
				}
			} else if ([^]u8)(p)[0] == '\\' || ([^]u8)(p)[0] == '/' || ([^]u8)(p)[0] == '"' || ([^]u8)(p)[0] == 't' || ([^]u8)(p)[0] == 'b' || ([^]u8)(p)[0] == 'n' || ([^]u8)(p)[0] == 'r' || ([^]u8)(p)[0] == 'f' {
				length += 1
				p += 1
			} else {
				semsg(cstring("E474: Unknown escape sequence: %.*s"), C.int(uintptr(rawptr(buf)) + uintptr(buf_len) - (uintptr(p) - 1)), transmute(cstring)(p - 1))
				ret = FAIL_E
				done = true
			}
		} else {
			p_byte := ([^]u8)(p)[0]
			if p_byte < 0x20 {
				semsg(cstring("E474: ASCII control characters cannot be present inside string: %.*s"), C.int(uintptr(rawptr(buf)) + uintptr(buf_len) - uintptr(p)), transmute(cstring)(p))
				ret = FAIL_E
				done = true
			} else {
				ch := utf_ptr2char(transmute(cstring)(p))
				if ch >= 0x80 && C.int(p_byte) == ch && !(ch == 0xC3 && uintptr(p) + 1 < e && ([^]u8)(p + 1)[0] == 0x83) {
					semsg(cstring("E474: Only UTF-8 strings allowed: %.*s"), C.int(uintptr(rawptr(buf)) + uintptr(buf_len) - uintptr(p)), transmute(cstring)(p))
					ret = FAIL_E
					done = true
				} else if ch > 0x10FFFF {
					semsg(cstring("E474: Only UTF-8 code points up to U+10FFFF are allowed to appear unescaped: %.*s"), C.int(uintptr(rawptr(buf)) + uintptr(buf_len) - uintptr(p)), transmute(cstring)(p))
					ret = FAIL_E
					done = true
				} else {
					ch_len := C.size_t(utf_char2len_r(ch))
					length += ch_len
					p += uintptr(ch_len)
				}
			}
		}
	}
	if ret == OK_E && (uintptr(p) >= e || ([^]u8)(p)[0] != '"') {
		semsg(cstring("E474: Expected string end: %.*s"), C.int(buf_len), buf)
		ret = FAIL_E
	}
	if ret == OK_E {
		str := (^u8)(xmalloc(length + 1))
		str_end := uintptr(str)
		fst_in_pair: C.int = 0
		t := s
		for uintptr(t) < uintptr(p) {
			if ([^]u8)(t)[0] != '\\' || ([^]u8)(t + 1)[0] != 'u' {
				if fst_in_pair != 0 {
					str_end = uintptr(str_end) + uintptr(utf_char2bytes(fst_in_pair, transmute(^u8)(str_end)))
					fst_in_pair = 0
				}
			}
			if ([^]u8)(t)[0] == '\\' {
				t += 1
				if ([^]u8)(t)[0] == 'u' {
					ubuf: [4]u8
					ubuf[0] = ([^]u8)(t + 1)[0]; ubuf[1] = ([^]u8)(t + 2)[0]; ubuf[2] = ([^]u8)(t + 3)[0]; ubuf[3] = ([^]u8)(t + 4)[0]
					t += 4
					ch: u64 = 0
					for k: C.int = 0; k < 4; k += 1 {
						ch = ch * 16 + u64(hexval_o(ubuf[k]))
					}
					if ch >= 0xD800 && ch <= 0xDBFF {
						if fst_in_pair != 0 {
							str_end = uintptr(str_end) + uintptr(utf_char2bytes(fst_in_pair, transmute(^u8)(str_end)))
						}
						fst_in_pair = C.int(ch)
					} else if ch >= 0xDC00 && ch <= 0xDFFF && fst_in_pair != 0 {
						full := C.int(ch - 0xDC00) + ((fst_in_pair - 0xD800) << 10) + 0x10000
						str_end = uintptr(str_end) + uintptr(utf_char2bytes(full, transmute(^u8)(str_end)))
						fst_in_pair = 0
					} else {
						if fst_in_pair != 0 {
							str_end = uintptr(str_end) + uintptr(utf_char2bytes(fst_in_pair, transmute(^u8)(str_end)))
							fst_in_pair = 0
						}
						str_end = uintptr(str_end) + uintptr(utf_char2bytes(C.int(ch), transmute(^u8)(str_end)))
					}
				} else {
					c := ([^]u8)(t)[0]
					if c == '\\' || c == '/' || c == '"' {
						([^]u8)(str_end)[0] = c
					} else if c == 't' {
						([^]u8)(str_end)[0] = 9
					} else if c == 'b' {
						([^]u8)(str_end)[0] = 8
					} else if c == 'n' {
						([^]u8)(str_end)[0] = 10
					} else if c == 'r' {
						([^]u8)(str_end)[0] = 13
					} else if c == 'f' {
						([^]u8)(str_end)[0] = 12
					}
					str_end += 1
				}
			} else {
				([^]u8)(str_end)[0] = ([^]u8)(t)[0]
				str_end += 1
			}
			t += 1
		}
		if fst_in_pair != 0 {
			str_end = uintptr(str_end) + uintptr(utf_char2bytes(fst_in_pair, transmute(^u8)(str_end)))
		}
		([^]u8)(str_end)[0] = 0
		obj := decode_string(transmute(cstring)(str), C.size_t(str_end - uintptr(str)), false, true)
		is_sp := obj.v_type != VAR_STRING
		if json_decoder_pop_o(ValuesStackItem_O{is_special_string = is_sp, didcomma = didcomma^, didcolon = didcolon^, val = obj}, stack, container_stack, pp, next_map_special, didcomma, didcolon) == FAIL_E {
			ret = FAIL_E
		}
	}
	pp^ = transmute(cstring)(p)
	return ret
}

// Hex digit value helper.
hexval_o :: proc "c" (c: u8) -> u8 {
	context = runtime.default_context()
	if c >= '0' && c <= '9' {
		return c - '0'
	}
	if c >= 'a' && c <= 'f' {
		return c - 'a' + 10
	}
	return c - 'A' + 10
}

// ascii_isxdigit (ascii_defs.h inline).
ascii_isxdigit_o :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// Values/container stack destroyers (kvi_destroy: free items).
vstack_destroy_o :: proc "c" (st: ^ValuesStack_O) {
	context = runtime.default_context()
	if st.items != nil {
		xfree(rawptr(st.items))
		st.items = nil
	}
}
cstack_destroy_o :: proc "c" (st: ^ContainersStack_O) {
	context = runtime.default_context()
	if st.items != nil {
		xfree(rawptr(st.items))
		st.items = nil
	}
}

// JSON number parser (decode.c parse_json_number).
parse_json_number_o :: proc "c" (buf: cstring, buf_len: C.size_t, pp: ^cstring, stack: ^ValuesStack_O, container_stack: ^ContainersStack_O, next_map_special: ^bool, didcomma: ^bool, didcolon: ^bool) -> C.int {
	context = runtime.default_context()
	e := uintptr(rawptr(buf)) + uintptr(buf_len)
	p := uintptr(rawptr(pp^))
	ret: C.int = OK_E
	s := p
	ints := p
	fracs: uintptr = 0
	exps: uintptr = 0
	exps_s: uintptr = 0
	failed := false
	if ([^]u8)(p)[0] == '-' {
		p += 1
	}
	ints = p
	if uintptr(p) < e {
		for uintptr(p) < e && ascii_isdigit_o(([^]u8)(p)[0]) {
			p += 1
		}
		if p != ints + 1 && ([^]u8)(ints)[0] == '0' {
			semsg(cstring("E474: Leading zeroes are not allowed: %.*s"), C.int(e - s), transmute(cstring)(s))
			ret = FAIL_E
			failed = true
		} else if uintptr(p) < e && p != ints {
			if ([^]u8)(p)[0] == '.' {
				p += 1
				fracs = p
				for uintptr(p) < e && ascii_isdigit_o(([^]u8)(p)[0]) {
					p += 1
				}
				if uintptr(p) >= e || p == fracs {
					// fall to check
				}
			}
			if !failed && uintptr(p) < e && (([^]u8)(p)[0] == 'e' || ([^]u8)(p)[0] == 'E') {
				p += 1
				exps_s = p
				if uintptr(p) < e && (([^]u8)(p)[0] == '-' || ([^]u8)(p)[0] == '+') {
					p += 1
				}
				exps = p
				for uintptr(p) < e && ascii_isdigit_o(([^]u8)(p)[0]) {
					p += 1
				}
			}
		}
	}
	if ret == OK_E {
		if p == ints {
			semsg(cstring("E474: Missing number after minus sign: %.*s"), C.int(e - s), transmute(cstring)(s))
			ret = FAIL_E
		} else if p == fracs || (fracs != 0 && exps_s == fracs + 1) {
			semsg(cstring("E474: Missing number after decimal dot: %.*s"), C.int(e - s), transmute(cstring)(s))
			ret = FAIL_E
		} else if exps != 0 && p == exps {
			semsg(cstring("E474: Missing exponent: %.*s"), C.int(e - s), transmute(cstring)(s))
			ret = FAIL_E
		}
	}
	if ret == OK_E {
		tv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED}
		exp_num_len := C.size_t(p - s)
		if fracs != 0 || exps != 0 {
			f: f64 = 0
			num_len := string2float(transmute(cstring)(s), &f)
			if exp_num_len != num_len {
				semsg(cstring("E685: internal error: while converting number \"%.*s\" to float string2float consumed %zu bytes in place of %zu"), C.int(exp_num_len), transmute(cstring)(s), num_len, exp_num_len)
			}
			tv.v_type = VAR_FLOAT
			tv.vval = transmute(rawptr)(f)
		} else {
			nr: C.longlong = 0
			num_len: C.int = 0
			vim_str2nr(transmute(cstring)(s), nil, &num_len, 0, &nr, nil, C.size_t(p - s), true, nil)
			if C.int(exp_num_len) != num_len {
				semsg(cstring("E685: internal error: while converting number \"%.*s\" to integer vim_str2nr consumed %i bytes in place of %zu"), C.int(exp_num_len), transmute(cstring)(s), num_len, exp_num_len)
			}
			tv.vval = transmute(rawptr)(nr)
		}
		pc := transmute(cstring)(p)
		if json_decoder_pop_o(ValuesStackItem_O{is_special_string = false, didcomma = didcomma^, didcolon = didcolon^, val = tv}, stack, container_stack, &pc, next_map_special, didcomma, didcolon) == FAIL_E {
			ret = FAIL_E
		} else {
			p = uintptr(rawptr(pc))
		}
		if ret == OK_E && next_map_special^ {
			pp^ = transmute(cstring)(p)
			return ret
		}
		p -= 1
	}
	pp^ = transmute(cstring)(p)
	return ret
}

// JSON decoder driver (decode.c json_decode_string).
@(export)
json_decode_string :: proc "c" (buf: cstring, buf_len: C.size_t, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	e := uintptr(rawptr(buf)) + uintptr(buf_len)
	p := uintptr(rawptr(buf))
	for uintptr(p) < e && (([^]u8)(p)[0] == ' ' || ([^]u8)(p)[0] == 9 || ([^]u8)(p)[0] == 10 || ([^]u8)(p)[0] == 13) {
		p += 1
	}
	if uintptr(p) >= e {
		emsg(cstring("E474: Attempt to decode a blank string"))
		return FAIL_E
	}
	ret: C.int = OK_E
	stack := ValuesStack_O{}
	container_stack := ContainersStack_O{}
	rettv.v_type = VAR_UNKNOWN
	didcomma := false
	didcolon := false
	next_map_special := false
	failed := false
	after_cycle := false
	for uintptr(p) < e && !failed && !after_cycle {
		restart := false
		brk := false
		c := ([^]u8)(p)[0]
		if c == '}' || c == ']' {
			if container_stack.n == 0 {
				semsg(cstring("E474: No container to close: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				lc := cstack_last_o(&container_stack)^
				if c == '}' && lc.container.v_type != VAR_DICT {
					semsg(cstring("E474: Closing list with curly bracket: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if c == ']' && lc.container.v_type != VAR_LIST {
					semsg(cstring("E474: Closing dictionary with square bracket: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if didcomma {
					semsg(cstring("E474: Trailing comma: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if didcolon {
					semsg(cstring("E474: Expected value after colon: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if lc.stack_index != stack.n - 1 {
					semsg(cstring("E474: Expected value: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if stack.n == 1 {
					p += 1
					cstack_pop_o(&container_stack)
					after_cycle = true
				} else {
					top := vstack_pop_o(&stack)
					pc := transmute(cstring)(p)
					if json_decoder_pop_o(top, &stack, &container_stack, &pc, &next_map_special, &didcomma, &didcolon) == FAIL_E {
						failed = true
					} else {
						p = uintptr(rawptr(pc))
					}
					brk = true
				}
			}
		} else if c == ',' {
			if container_stack.n == 0 {
				semsg(cstring("E474: Comma not inside container: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				lc := cstack_last_o(&container_stack)^
				empty := false
				if lc.special_val == nil {
					if lc.container.v_type == VAR_DICT {
						empty = (^C.size_t)(uintptr(rawptr(lc.container.vval)) + 24)^ == 0
					} else {
						empty = tv_list_len_o(rawptr(lc.container.vval)) == 0
					}
				} else {
					empty = tv_list_len_o(lc.special_val) == 0
				}
				if didcomma {
					semsg(cstring("E474: Duplicate comma: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if didcolon {
					semsg(cstring("E474: Comma after colon: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if lc.container.v_type == VAR_DICT && lc.stack_index != stack.n - 1 {
					semsg(cstring("E474: Using comma in place of colon: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if empty {
					semsg(cstring("E474: Leading comma: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else {
					didcomma = true
					brk = true
				}
			}
		} else if c == ':' {
			if container_stack.n == 0 {
				semsg(cstring("E474: Colon not inside container: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				lc := cstack_last_o(&container_stack)^
				if lc.container.v_type != VAR_DICT {
					semsg(cstring("E474: Using colon not in dictionary: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if lc.stack_index != stack.n - 2 {
					semsg(cstring("E474: Unexpected colon: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if didcomma {
					semsg(cstring("E474: Colon after comma: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else if didcolon {
					semsg(cstring("E474: Duplicate colon: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
					failed = true
				} else {
					didcolon = true
					brk = true
				}
			}
		} else if c == ' ' || c == 9 || c == 10 || c == 13 {
			brk = true
		} else if c == 'n' {
			if uintptr(p) + 3 >= e || libc.strncmp(transmute(cstring)(p + 1), cstring("ull"), 3) != 0 {
				semsg(cstring("E474: Expected null: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				p += 3
				pc := transmute(cstring)(p)
				if json_decoder_pop_o(ValuesStackItem_O{val = Typval_T{v_type = VAR_SPECIAL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(KSPECIALVARNULL_O))}, didcomma = didcomma, didcolon = didcolon}, &stack, &container_stack, &pc, &next_map_special, &didcomma, &didcolon) == FAIL_E {
					failed = true
				} else {
					p = uintptr(rawptr(pc))
				}
				if !failed && next_map_special {
					restart = true
				}
			}
		} else if c == 't' {
			if uintptr(p) + 3 >= e || libc.strncmp(transmute(cstring)(p + 1), cstring("rue"), 3) != 0 {
				semsg(cstring("E474: Expected true: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				p += 3
				pc := transmute(cstring)(p)
				if json_decoder_pop_o(ValuesStackItem_O{val = Typval_T{v_type = VAR_BOOL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(kBoolVarTrue))}, didcomma = didcomma, didcolon = didcolon}, &stack, &container_stack, &pc, &next_map_special, &didcomma, &didcolon) == FAIL_E {
					failed = true
				} else {
					p = uintptr(rawptr(pc))
				}
				if !failed && next_map_special {
					restart = true
				}
			}
		} else if c == 'f' {
			if uintptr(p) + 4 >= e || libc.strncmp(transmute(cstring)(p + 1), cstring("alse"), 4) != 0 {
				semsg(cstring("E474: Expected false: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
			} else {
				p += 4
				pc := transmute(cstring)(p)
				if json_decoder_pop_o(ValuesStackItem_O{val = Typval_T{v_type = VAR_BOOL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(kBoolVarFalse))}, didcomma = didcomma, didcolon = didcolon}, &stack, &container_stack, &pc, &next_map_special, &didcomma, &didcolon) == FAIL_E {
					failed = true
				} else {
					p = uintptr(rawptr(pc))
				}
				if !failed && next_map_special {
					restart = true
				}
			}
		} else if c == '"' {
			pc := transmute(cstring)(p)
			if parse_json_string_o(buf, buf_len, &pc, &stack, &container_stack, &next_map_special, &didcomma, &didcolon) == FAIL_E {
				failed = true
			} else {
				p = uintptr(rawptr(pc))
			}
			if !failed && next_map_special {
				restart = true
			}
		} else if c == '-' || (c >= '0' && c <= '9') {
			pc := transmute(cstring)(p)
			if parse_json_number_o(buf, buf_len, &pc, &stack, &container_stack, &next_map_special, &didcomma, &didcolon) == FAIL_E {
				failed = true
			} else {
				p = uintptr(rawptr(pc))
			}
			if !failed && next_map_special {
				restart = true
			}
		} else if c == '[' {
			l := tv_list_alloc(KLISTLEN_MAYKNOW_O)
			tv_list_ref_o(l)
			tv := Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(l)}
			cstack_push_o(&container_stack, ContainerStackItem_O{stack_index = stack.n, s = transmute(cstring)(p), container = tv})
			vstack_push_o(&stack, ValuesStackItem_O{val = tv, didcomma = didcomma, didcolon = didcolon})
		} else if c == '{' {
			tv := Typval_T{}
			val_list: rawptr = nil
			if next_map_special {
				next_map_special = false
				val_list = decode_create_map_special_dict(&tv, KLISTLEN_MAYKNOW_O)
			} else {
				dd := tv_dict_alloc()
				(^C.int)(uintptr(dd) + 8)^ += 1
				tv = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(dd)}
			}
			cstack_push_o(&container_stack, ContainerStackItem_O{stack_index = stack.n, special_val = val_list, s = transmute(cstring)(p), container = tv})
			vstack_push_o(&stack, ValuesStackItem_O{val = tv, didcomma = didcomma, didcolon = didcolon})
		} else {
			semsg(cstring("E474: Unidentified byte: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
			failed = true
		}
		if restart || failed || after_cycle {
			continue
		}
		if brk {
			p += 1
			continue
		}
		didcomma = false
		didcolon = false
		if container_stack.n == 0 {
			p += 1
			break
		}
		p += 1
	}
	if !failed {
		for uintptr(p) < e {
			cc := ([^]u8)(p)[0]
			if cc == 10 || cc == ' ' || cc == 9 || cc == 13 {
				p += 1
			} else {
				semsg(cstring("E474: Trailing characters: %.*s"), C.int(e - uintptr(p)), transmute(cstring)(p))
				failed = true
				break
			}
		}
	}
	if !failed {
		if stack.n == 1 && container_stack.n == 0 {
			top := vstack_pop_o(&stack)
			rettv^ = top.val
		} else {
			semsg(cstring("E474: Unexpected end of input: %.*s"), C.int(buf_len), buf)
			failed = true
		}
	}
	if failed {
		ret = FAIL_E
		for stack.n > 0 {
			popped := vstack_pop_o(&stack)
			tv_clear(&popped.val)
		}
	} else {
		ret = OK_E
	}
	vstack_destroy_o(&stack)
	cstack_destroy_o(&container_stack)
	return ret
}

// —— Batch 23l: decode.c mpack callbacks (mpack_node/token mirrors) ——
foreign _ {
	@(link_name = "mpack_parse")
	mpack_parse_e :: proc "c" (parser: rawptr, b: ^cstring, bl: ^C.size_t, enter_cb: Mpack_Walk_Cb, exit_cb: Mpack_Walk_Cb) -> C.int ---
	@(link_name = "mpack_unpack_boolean")
	mpack_unpack_boolean_e :: proc "c" (t: Mpack_Token_O) -> bool ---
	@(link_name = "mpack_unpack_uint")
	mpack_unpack_uint_e :: proc "c" (t: Mpack_Token_O) -> u64 ---
	@(link_name = "mpack_unpack_sint")
	mpack_unpack_sint_e :: proc "c" (t: Mpack_Token_O) -> i64 ---
	@(link_name = "mpack_unpack_float_fast")
	mpack_unpack_float_e :: proc "c" (t: Mpack_Token_O) -> f64 ---
}

// mpack walk callback type (mpack/object.h).
Mpack_Walk_Cb :: proc "c" (w: rawptr, n: rawptr)

// mpack_token_t mirror (mpack_core.h): 16B cc-probed.
Mpack_Token_O :: struct {
	type:   C.int, // 0
	length: u32,   // 4
	data:   [8]u8, // 8: value/chunk_ptr/ext_type
}
#assert(size_of(Mpack_Token_O) == 16)

MPACK_TOK_NIL_O :: 1
MPACK_TOK_BOOLEAN_O :: 2
MPACK_TOK_UINT_O :: 3
MPACK_TOK_SINT_O :: 4
MPACK_TOK_FLOAT_O :: 5
MPACK_TOK_CHUNK_O :: 6
MPACK_TOK_ARRAY_O :: 7
MPACK_TOK_MAP_O :: 8
MPACK_TOK_BIN_O :: 9
MPACK_TOK_STR_O :: 10
MPACK_TOK_EXT_O :: 11

// mpack_node_t mirror (mpack/object.h): 48B cc-probed.
Mpack_Node_O :: struct {
	tok:         Mpack_Token_O, // 0..16
	pos:         C.size_t,      // 16
	key_visited: C.int,         // 24
	_pad:        [4]u8,
	data:        [16]u8,        // 32..48
}
#assert(size_of(Mpack_Node_O) == 48)

// Big-integer to special typval (decode.c static).
positive_integer_to_special_typval_o :: proc "c" (rettv: ^Typval_T, val: u64) {
	context = runtime.default_context()
	if val <= u64(VARNUMBER_MAX_O) {
		rettv^ = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(val))}
	} else {
		list := tv_list_alloc(4)
		tv_list_ref_o(list)
		create_special_dict_o(rettv, KMPINTEGER_O, Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(list)})
		tv_list_append_number(list, C.longlong(1))
		tv_list_append_number(list, C.longlong((val >> 62) & 0x3))
		tv_list_append_number(list, C.longlong((val >> 31) & 0x7FFFFFFF))
		tv_list_append_number(list, C.longlong(val & 0x7FFFFFFF))
	}
}

// mpack enter callback (decode.c static): allocate result slots.
typval_parse_enter_o :: proc "c" (w: rawptr, n: rawptr) {
	context = runtime.default_context()
	parser := w
	node := n
	result: rawptr = nil
	parent: rawptr = nil
	if (^C.size_t)(uintptr(node) - 48 + 16)^ != max(C.size_t) {
		parent = rawptr(uintptr(node) - 48)
	}
	if parent != nil {
		ptype := (^C.int)(uintptr(parent))^
		if ptype == MPACK_TOK_ARRAY_O {
			list := (^rawptr)(uintptr(parent) + 40)^
			result = tv_list_append_owned_tv(list, Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED})
		} else if ptype == MPACK_TOK_MAP_O {
			items := (^rawptr)(uintptr(parent) + 40)^
			pos := (^C.size_t)(uintptr(parent) + 16)^
			kv := (^C.int)(uintptr(parent) + 24)^
			result = rawptr(uintptr(items) + uintptr((pos * 2 + C.size_t(kv)) * 16))
		} else if ptype == MPACK_TOK_STR_O || ptype == MPACK_TOK_BIN_O || ptype == MPACK_TOK_EXT_O {
		} else {
			libc.abort()
		}
	} else {
		result = (^rawptr)(uintptr(parser))^
	}
	(^rawptr)(uintptr(node) + 32)^ = result
	(^rawptr)(uintptr(node) + 40)^ = nil
	ntype := (^C.int)(uintptr(node))^
	if ntype == MPACK_TOK_NIL_O {
		(^Typval_T)(result)^ = Typval_T{v_type = VAR_SPECIAL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(KSPECIALVARNULL_O))}
	} else if ntype == MPACK_TOK_BOOLEAN_O {
		v: C.int = kBoolVarFalse
		if mpack_unpack_boolean_e((^Mpack_Token_O)(uintptr(node))^) {
			v = kBoolVarTrue
		}
		(^Typval_T)(result)^ = Typval_T{v_type = VAR_BOOL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(v))}
	} else if ntype == MPACK_TOK_SINT_O {
		(^Typval_T)(result)^ = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(mpack_unpack_sint_e((^Mpack_Token_O)(uintptr(node))^)))}
	} else if ntype == MPACK_TOK_UINT_O {
		positive_integer_to_special_typval_o((^Typval_T)(result), mpack_unpack_uint_e((^Mpack_Token_O)(uintptr(node))^))
	} else if ntype == MPACK_TOK_FLOAT_O {
		(^Typval_T)(result)^ = Typval_T{v_type = VAR_FLOAT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(mpack_unpack_float_e((^Mpack_Token_O)(uintptr(node))^))}
	} else if ntype == MPACK_TOK_BIN_O || ntype == MPACK_TOK_STR_O || ntype == MPACK_TOK_EXT_O {
		(^rawptr)(uintptr(node) + 40)^ = rawptr(xmallocz_r(C.size_t((^u32)(uintptr(node) + 4)^)))
	} else if ntype == MPACK_TOK_CHUNK_O {
		data := (^rawptr)(uintptr(parent) + 40)^
		libc.memcpy(rawptr(uintptr(data) + uintptr((^C.size_t)(uintptr(parent) + 16)^)), rawptr((^rawptr)(uintptr(node) + 8)^), C.size_t((^u32)(uintptr(node) + 4)^))
	} else if ntype == MPACK_TOK_ARRAY_O {
		list := tv_list_alloc(C.ssize_t((^u32)(uintptr(node) + 4)^))
		tv_list_ref_o(list)
		(^Typval_T)(result)^ = Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(list)}
		(^rawptr)(uintptr(node) + 40)^ = list
	} else if ntype == MPACK_TOK_MAP_O {
		(^rawptr)(uintptr(node) + 40)^ = rawptr(xmallocz_r(C.size_t((^u32)(uintptr(node) + 4)^) * 2 * 16))
	}
}

// mpack exit callback (decode.c static): finalize containers.
typval_parse_exit_o :: proc "c" (w: rawptr, n: rawptr) {
	context = runtime.default_context()
	node := n
	result := (^rawptr)(uintptr(node) + 32)^
	ntype := (^C.int)(uintptr(node))^
	length := C.size_t((^u32)(uintptr(node) + 4)^)
	if ntype == MPACK_TOK_BIN_O || ntype == MPACK_TOK_STR_O {
		(^Typval_T)(result)^ = decode_string(transmute(cstring)((^rawptr)(uintptr(node) + 40)^), length, false, true)
		(^rawptr)(uintptr(node) + 40)^ = nil
	} else if ntype == MPACK_TOK_EXT_O {
		list := tv_list_alloc(2)
		tv_list_ref_o(list)
		tv_list_append_number(list, C.longlong((^C.int)(uintptr(node) + 8)^))
		ext_val_list := tv_list_alloc(KLISTLEN_MAYKNOW_O)
		tv_list_append_list(list, ext_val_list)
		create_special_dict_o((^Typval_T)(result), KMPEXT_O, Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(list)})
		encode_list_write(ext_val_list, transmute(cstring)((^rawptr)(uintptr(node) + 40)^), length)
		xfree((^rawptr)(uintptr(node) + 40)^)
		(^rawptr)(uintptr(node) + 40)^ = nil
	} else if ntype == MPACK_TOK_MAP_O {
		items := ([^]Typval_T)((^rawptr)(uintptr(node) + 40)^)
		all_str := true
		i: C.size_t = 0
		for i < length {
			ktv := items[i * 2 + 0]
			if ktv.v_type != VAR_STRING || rawptr(ktv.vval) == nil || ([^]u8)(ktv.vval)[0] == 0 {
				all_str = false
				break
			}
			i += 1
		}
		if all_str {
			d := tv_dict_alloc()
			(^C.int)(uintptr(d) + 8)^ += 1
			(^Typval_T)(result)^ = Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(d)}
			dup := false
			i = 0
			for i < length {
				key := transmute(cstring)(items[i * 2 + 0].vval)
				keylen := C.size_t(libc.strlen(key))
				di := rawptr(xmallocz_r(17 + keylen))
				libc.memcpy(rawptr(uintptr(di) + 17), rawptr(transmute(^u8)(key)), keylen)
				(^C.int)(uintptr(di))^ = VAR_UNKNOWN
				if tv_dict_add(d, di) == FAIL_E {
					todo := (^C.size_t)(uintptr(d) + 24)^
					hi := uintptr((^rawptr)(rawptr(uintptr(d) + 48))^)
					for todo > 0 {
						k := ([^]rawptr)(hi)[1]
						hi += 16
						if k == nil || k == rawptr(&hash_removed) {
							continue
						}
						todo -= 1
						ddi := rawptr(uintptr(k) - 17)
						(^Typval_T)(uintptr(ddi))^ = Typval_T{v_type = VAR_SPECIAL, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(KSPECIALVARNULL_O))}
					}
					tv_clear((^Typval_T)(result))
					xfree(di)
					dup = true
					break
				}
				(^Typval_T)(uintptr(di))^ = items[i * 2 + 1]
				i += 1
			}
			if !dup {
				i = 0
				for i < length {
					xfree(rawptr(transmute(^u8)(items[i * 2 + 0].vval)))
					i += 1
				}
				xfree((^rawptr)(uintptr(node) + 40)^)
				(^rawptr)(uintptr(node) + 40)^ = nil
				return
			}
		}
		list := decode_create_map_special_dict((^Typval_T)(result), C.ptrdiff_t(length))
		j: C.size_t = 0
		for j < length {
			kv_pair := tv_list_alloc(2)
			tv_list_append_list(list, kv_pair)
			tv_list_append_owned_tv(kv_pair, items[j * 2 + 0])
			tv_list_append_owned_tv(kv_pair, items[j * 2 + 1])
			j += 1
		}
		xfree((^rawptr)(uintptr(node) + 40)^)
		(^rawptr)(uintptr(node) + 40)^ = nil
	}
}

// Free entered-but-unexited nodes (decode.c public).
@(export)
typval_parser_error_free :: proc "c" (parser: rawptr) {
	context = runtime.default_context()
	n := C.size_t((^u32)(uintptr(parser) + 8)^)
	i: C.size_t = 0
	for i < n {
		node := rawptr(uintptr(parser) + uintptr(80 + i * 48))
		t := (^C.int)(uintptr(node))^
		if t == MPACK_TOK_BIN_O || t == MPACK_TOK_STR_O || t == MPACK_TOK_EXT_O || t == MPACK_TOK_MAP_O {
			p := (^rawptr)(uintptr(node) + 40)^
			if p != nil {
				xfree(p)
			}
			(^rawptr)(uintptr(node) + 40)^ = nil
		}
		i += 1
	}
}

// Streaming msgpack-to-typval (decode.c public).
@(export)
mpack_parse_typval :: proc "c" (parser: rawptr, data: ^cstring, size: ^C.size_t) -> C.int {
	context = runtime.default_context()
	return mpack_parse_e(parser, data, size, typval_parse_enter_o, typval_parse_exit_o)
}

// One-shot msgpack-to-typval (decode.c public).
@(export)
unpack_typval :: proc "c" (data: ^cstring, size: ^C.size_t, ret: ^Typval_T) -> C.int {
	context = runtime.default_context()
	ret.v_type = VAR_UNKNOWN
	parser: [1664]u8
	mpack_parser_init_e(rawptr(&parser[0]), 0)
	(^rawptr)(rawptr(&parser[0]))^ = rawptr(ret)
	status := mpack_parse_typval(rawptr(&parser[0]), data, size)
	if status != MPACK_OK_O {
		typval_parser_error_free(rawptr(&parser[0]))
		tv_clear(ret)
	}
	return status
}

// —— Batch 28a: eval.c tiny leaves (num_divide/modulus/get_copyID) ——

// Integer division with div-by-zero guards (eval.c public).
@(export)
num_divide :: proc "c" (n1: C.longlong, n2: C.longlong) -> C.longlong {
	context = runtime.default_context()
	result: C.longlong = 0
	if n2 == 0 {
		if n1 == 0 {
			result = VARNUMBER_MIN_O
		} else if n1 < 0 {
			result = -VARNUMBER_MAX_O
		} else {
			result = VARNUMBER_MAX_O
		}
	} else if n1 == VARNUMBER_MIN_O && n2 == -1 {
		result = VARNUMBER_MAX_O
	} else {
		result = n1 / n2
	}
	return result
}

// Integer modulus with div-by-zero guard (eval.c public).
@(export)
num_modulus :: proc "c" (n1: C.longlong, n2: C.longlong) -> C.longlong {
	context = runtime.default_context()
	if n2 == 0 {
		return 0
	}
	return n1 % n2
}

// CopyID generator (eval.c public; static counter, +2 per call).
copyID_current_g: C.int = 0

@(export)
get_copyID :: proc "c" () -> C.int {
	context = runtime.default_context()
	copyID_current_g += 2
	return copyID_current_g
}

// —— Batch 28b: eval.c expr predicates ——

// Non-empty evaluatable check (eval.c public, CONST).
@(export)
eval_expr_valid_arg :: proc "c" (tv: ^Typval_T) -> bool {
	context = runtime.default_context()
	return tv.v_type != VAR_UNKNOWN && (tv.v_type != VAR_STRING || (rawptr(tv.vval) != nil && ([^]u8)(tv.vval)[0] != 0))
}

// Typval-to-bool via expression eval (eval.c public).
@(export)
eval_expr_to_bool :: proc "c" (expr: ^Typval_T, error: ^bool) -> bool {
	context = runtime.default_context()
	argv := Typval_T{}
	rettv := Typval_T{}
	if eval_expr_typval(expr, false, &argv, 0, &rettv) == FAIL_E {
		error^ = true
		return false
	}
	res := tv_get_number_chk(&rettv, error) != 0
	tv_clear(&rettv)
	return res
}

// Regex match helper (eval.c public).
@(export)
pattern_match :: proc "c" (pat: cstring, text: cstring, ic: bool) -> C.int {
	context = runtime.default_context()
	matches: C.int = 0
	regmatch := Regmatch_T{}
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	regmatch.regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O)
	if regmatch.regprog != nil {
		regmatch.rm_ic = p_ic
		if vim_regexec_nl_e(&regmatch, text, 0) {
			matches = 1
		}
		vim_regfree(regmatch.regprog)
	}
	p_cpo = save_cpo
	return matches
}

// —— Batch 28d: eval.c evalarg + eval_to_bool ——
foreign _ {
	@(link_name = "sourcing_a_script")
	sourcing_a_script_e :: proc "c" (eap: rawptr) -> C.int ---
}

// Simple-funccal fast path with eval0 fallback (eval.c static).
eval0_simple_funccal_o :: proc "c" (arg: cstring, rettv: ^Typval_T, eap: rawptr, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	r := may_call_simple_func(arg, rettv)
	if r == NOTDONE_O {
		r = eval0(arg, rettv, eap, evalarg)
	}
	return r
}

// Top-level expression evaluator with trailing-text check (eval.c public).
@(export)
eval0 :: proc "c" (arg: cstring, rettv: ^Typval_T, eap: rawptr, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	did_emsg_before := did_emsg_g()
	called_emsg_before := called_emsg
	end_error := false
	p := skipwhite(arg)
	ret := eval1(&p, rettv, evalarg)
	if ret != FAIL_E {
		end_error = ends_excmd(C.int(([^]u8)(p)[0])) == 0
	}
	if ret == FAIL_E || end_error {
		if ret != FAIL_E {
			tv_clear(rettv)
		}
		if !aborting_r() && did_emsg_g() == did_emsg_before && called_emsg == called_emsg_before {
			if end_error {
				semsg(cstring(E488_S), p)
			} else {
				semsg(cstring(E15_S), arg)
			}
		}
		if eap != nil && p != nil {
			nextcmd := transmute(rawptr)(check_nextcmd(transmute(^u8)(p)))
			if nextcmd != nil && ([^]u8)(nextcmd)[0] != '|' {
				(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = nextcmd
			}
		}
		return FAIL_E
	}
	if eap != nil {
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd(transmute(^u8)(p)))
	}
	return ret
}

EXARG_CMDLINEP_OFF :: 48
EXARG_CMDLINE_TOFREE_OFF :: 56

// Fill evalarg from exarg (eval.c public; reuses Batch-20c Evalarg_T).
@(export)
fill_evalarg_from_eap :: proc "c" (evalarg: ^Evalarg_T, eap: rawptr, skip: bool) {
	context = runtime.default_context()
	evalarg.eval_flags = 0
	if !skip {
		evalarg.eval_flags = EVAL_EVALUATE_O
	}
	// NOTE: C leaves eval_tofree uninitialized here (latent UB — ex_while
	// declares a bare struct and nothing in the tree ever stores non-NULL).
	// Zero it so clear_evalarg below is deterministic instead of gambling
	// on stack residue (which crashed lazy startup: free(stack)).
	evalarg.eval_tofree = nil
	if eap == nil {
		return
	}
	if sourcing_a_script_e(eap) != 0 || (^rawptr)(uintptr(eap) + 168)^ == transmute(rawptr)(get_list_line) {
		evalarg.eval_getline = (^rawptr)(uintptr(eap) + 168)^
		evalarg.eval_cookie = (^rawptr)(uintptr(eap) + 176)^
	}
}

// Clear evalarg (eval.c public).
@(export)
clear_evalarg :: proc "c" (evalarg: ^Evalarg_T, eap: rawptr) {
	context = runtime.default_context()
	if evalarg == nil {
		return
	}
	if evalarg.eval_tofree != nil {
		if eap != nil {
			xfree(rawptr(transmute(^u8)((^cstring)(uintptr(eap) + EXARG_CMDLINE_TOFREE_OFF)^)))
			(^cstring)(uintptr(eap) + EXARG_CMDLINE_TOFREE_OFF)^ = (^cstring)(uintptr(eap) + EXARG_CMDLINEP_OFF)^
			(^cstring)(uintptr(eap) + EXARG_CMDLINEP_OFF)^ = transmute(cstring)(evalarg.eval_tofree)
		} else {
			xfree(rawptr(transmute(^u8)(evalarg.eval_tofree)))
		}
		evalarg.eval_tofree = nil
	}
}

// —— Batch 28al: eval.c clear_lval (export + weak, completes lval trio) ——

// Lvalue cleanup: free exp_name + newkey (eval.c public).
@(export)
clear_lval :: proc "c" (lp: rawptr) {
	context = runtime.default_context()
	xfree((^rawptr)(uintptr(lp) + 16)^)
	xfree((^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^)
}

// Top-level string-to-bool eval (eval.c public).
@(export)
eval_to_bool :: proc "c" (arg: cstring, error: ^bool, eap: rawptr, skip: bool, use_simple_function: bool) -> bool {
	context = runtime.default_context()
	tv := Typval_T{}
	retval := false
	evalarg := Evalarg_T{}
	fill_evalarg_from_eap(&evalarg, eap, skip)
	if skip {
		emsg_skip += 1
	}
	r: C.int = 0
	if use_simple_function {
		r = eval0_simple_funccal_o(arg, &tv, eap, rawptr(&evalarg))
	} else {
		r = eval0(arg, &tv, eap, rawptr(&evalarg))
	}
	if r == FAIL_E {
		error^ = true
	} else {
		error^ = false
		if !skip {
			err := false
			retval = tv_get_number_chk(&tv, &err) != 0
			if err {
				error^ = true
			}
			tv_clear(&tv)
		}
	}
	if skip {
		emsg_skip -= 1
	}
	clear_evalarg(&evalarg, eap)
	return retval
}

// —— Batch 28e: eval.c to_string family ——
foreign _ {
	@(link_name = "EVALARG_EVALUATE")
	EVALARG_EVALUATE_g: Evalarg_T
}

// String eval with skip support (eval.c public).
@(export)
eval_to_string_skip :: proc "c" (arg: cstring, eap: rawptr, skip: bool) -> cstring {
	context = runtime.default_context()
	tv := Typval_T{}
	retval: cstring = nil
	evalarg := Evalarg_T{}
	fill_evalarg_from_eap(&evalarg, eap, skip)
	if skip {
		emsg_skip += 1
	}
	if eval0(arg, &tv, eap, rawptr(&evalarg)) == FAIL_E || skip {
		retval = nil
	} else {
		retval = transmute(cstring)(xstrdup_o(transmute(^u8)(tv_get_string(&tv))))
		tv_clear(&tv)
	}
	if skip {
		emsg_skip -= 1
	}
	clear_evalarg(&evalarg, eap)
	return retval
}

// Skip over an expression (eval.c public).
@(export)
skip_expr :: proc "c" (pp: ^cstring, evalarg: ^Evalarg_T) -> C.int {
	context = runtime.default_context()
	save_flags: C.int = 0
	if evalarg != nil {
		save_flags = evalarg.eval_flags
		evalarg.eval_flags &= ~C.int(1)
	}
	pp^ = skipwhite(pp^)
	rettv := Typval_T{}
	res := eval1(pp, &rettv, nil)
	if evalarg != nil {
		evalarg.eval_flags = save_flags
	}
	return res
}

// List/dict-aware tv-to-string (eval.c static).
typval2string_o :: proc "c" (tv: ^Typval_T, join_list: bool) -> cstring {
	context = runtime.default_context()
	if join_list && tv.v_type == VAR_LIST {
		ga := Garray{}
		ga_init(&ga, 1, 80)
		l := rawptr(tv.vval)
		if l != nil {
			tv_list_join(&ga, l, cstring("\n"))
			if tv_list_len_o(l) > 0 {
				ga_append(&ga, NL_O)
			}
		}
		ga_append(&ga, 0)
		return transmute(cstring)(ga.ga_data)
	} else if tv.v_type == VAR_LIST || tv.v_type == VAR_DICT {
		return encode_tv2string(tv, nil)
	}
	return transmute(cstring)(xstrdup_o(transmute(^u8)(tv_get_string(tv))))
}

// Top-level string eval with exarg (eval.c public).
@(export)
eval_to_string_eap :: proc "c" (arg: cstring, join_list: bool, eap: rawptr, use_simple_function: bool) -> cstring {
	context = runtime.default_context()
	tv := Typval_T{}
	retval: cstring = nil
	evalarg := Evalarg_T{}
	skip := false
	if eap != nil {
		skip = (^bool)(uintptr(eap) + 72)^
	}
	fill_evalarg_from_eap(&evalarg, eap, skip)
	r: C.int = 0
	if use_simple_function {
		r = eval0_simple_funccal_o(arg, &tv, nil, rawptr(&evalarg))
	} else {
		r = eval0(arg, &tv, nil, rawptr(&evalarg))
	}
	if r == FAIL_E {
		retval = nil
	} else {
		retval = typval2string_o(&tv, join_list)
		tv_clear(&tv)
	}
	clear_evalarg(&evalarg, nil)
	return retval
}

// Top-level string eval (eval.c public).
@(export)
eval_to_string :: proc "c" (arg: cstring, join_list: bool, use_simple_function: bool) -> cstring {
	context = runtime.default_context()
	return eval_to_string_eap(arg, join_list, nil, use_simple_function)
}

// Sandboxed string eval (eval.c public).
@(export)
eval_to_string_safe :: proc "c" (arg: cstring, use_sandbox: bool, use_simple_function: bool) -> cstring {
	context = runtime.default_context()
	retval: cstring = nil
	funccal_entry: [16]u8
	save_funccal(rawptr(&funccal_entry[0]))
	if use_sandbox {
		sandbox += 1
	}
	textlock += 1
	retval = eval_to_string(arg, false, use_simple_function)
	if use_sandbox {
		sandbox -= 1
	}
	textlock -= 1
	restore_funccal()
	return retval
}

// Top-level number eval, silent (eval.c public).
@(export)
eval_to_number :: proc "c" (expr: cstring, use_simple_function: bool) -> C.longlong {
	context = runtime.default_context()
	rettv := Typval_T{}
	retval: C.longlong = 0
	p := skipwhite(expr)
	r: C.int = NOTDONE_O
	emsg_off += 1
	if use_simple_function {
		r = may_call_simple_func(p, &rettv)
	}
	if r == NOTDONE_O {
		r = eval1(&p, &rettv, rawptr(&EVALARG_EVALUATE_g))
	}
	if r == FAIL_E {
		retval = -1
	} else {
		retval = tv_get_number_chk(&rettv, nil)
		tv_clear(&rettv)
	}
	emsg_off -= 1
	return retval
}

// —— Batch 28i: eval.c eval7_leader (dormant plain, C-static) ——

// Apply unary '!'/'-' leader run to a value (eval.c static,
// activates with eval7 port).
eval7_leader_o :: proc "c" (rettv: ^Typval_T, numeric_only: bool, start_leader: cstring, end_leaderp: ^cstring) -> C.int {
	context = runtime.default_context()
	end_leader := uintptr(rawptr(end_leaderp^))
	ret: C.int = OK_E
	error := false
	val: C.longlong = 0
	f: f64 = 0
	if rettv.v_type == VAR_FLOAT {
		f = transmute(f64)(rettv.vval)
	} else {
		val = tv_get_number_chk(rettv, &error)
	}
	if error {
		tv_clear(rettv)
		ret = FAIL_E
	} else {
		for end_leader > uintptr(rawptr(start_leader)) {
			end_leader -= 1
			if ([^]u8)(end_leader)[0] == '!' {
				if numeric_only {
					end_leader += 1
					break
				}
				if rettv.v_type == VAR_FLOAT {
					rettv.v_type = VAR_BOOL
					if f == 0 {
						val = kBoolVarTrue
					} else {
						val = kBoolVarFalse
					}
				} else {
					if val != 0 {
						val = 0
					} else {
						val = 1
					}
				}
			} else if ([^]u8)(end_leader)[0] == '-' {
				if rettv.v_type == VAR_FLOAT {
					f = -f
				} else {
					val = -val
				}
			}
		}
		if rettv.v_type == VAR_FLOAT {
			tv_clear(rettv)
			rettv.vval = transmute(rawptr)(f)
		} else {
			tv_clear(rettv)
			rettv.v_type = VAR_NUMBER
			rettv.vval = transmute(rawptr)(val)
		}
	}
	end_leaderp^ = transmute(cstring)(end_leader)
	return ret
}

// —— Batch 28j: eval.c call_func_rettv (dormant plain, C-static) ——
E1192_S :: "E1192: Empty function name"

// Invoke funcref in rettv with parsed args (eval.c static,
// activates with eval_lambda/eval_method ports).
call_func_rettv_o :: proc "c" (arg: ^cstring, evalarg: rawptr, rettv: ^Typval_T, evaluate: bool, selfdict: rawptr, basetv: rawptr, lua_funcname: cstring) -> C.int {
	context = runtime.default_context()
	pt: rawptr = nil
	functv := Typval_T{}
	funcname: cstring = nil
	is_lua := false
	fail := false
	if evaluate {
		functv = rettv^
		rettv.v_type = VAR_UNKNOWN
		if functv.v_type == VAR_PARTIAL {
			pt = rawptr(functv.vval)
			is_lua = is_luafunc(pt)
			if is_lua {
				funcname = lua_funcname
			} else {
				funcname = partial_name(pt)
			}
		} else {
			funcname = transmute(cstring)(functv.vval)
			if funcname == nil || ([^]u8)(funcname)[0] == 0 {
				emsg(cstring(E1192_S))
				fail = true
			}
		}
	} else {
		funcname = cstring("")
	}
	ret: C.int = 0
	if !fail {
		fe := Funcexe_T{}
		fe.firstline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		fe.lastline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		fe.evaluate = evaluate
		fe.partial = pt
		fe.selfdict = selfdict
		fe.basetv = basetv
		namelen: C.int = -1
		if is_lua {
			namelen = C.int(uintptr(rawptr(arg^)) - uintptr(rawptr(funcname)))
		}
		ret = get_func_tv(funcname, namelen, rettv, arg, evalarg, &fe)
	}
	if evaluate {
		tv_clear(&functv)
	}
	return ret
}

// —— Batch 28k: eval.c eval_lambda (dormant plain, C-static) ——
E274_S :: "E274: No white space allowed before parenthesis"

// Evaluate "->method()" on a lambda base (eval.c static,
// activates with eval_method/eval7 ports).
eval_lambda_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, verbose: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 2)
	base := rettv^
	rettv.v_type = VAR_UNKNOWN
	ret := get_lambda_tv(arg, rettv, evalarg)
	if ret != OK_E {
		return FAIL_E
	} else if ([^]u8)(arg^)[0] != '(' {
		if verbose {
			if ([^]u8)(skipwhite(arg^))[0] == '(' {
				emsg(cstring(E274_S))
			} else {
				semsg(cstring(E107_S), cstring("lambda"))
			}
		}
		tv_clear(rettv)
		ret = FAIL_E
	} else {
		ret = call_func_rettv_o(arg, evalarg, rettv, evaluate, nil, rawptr(&base), nil)
	}
	if evaluate {
		tv_clear(&base)
	}
	return ret
}

// —— Batch 28l: eval.c eval1_emsg (dormant plain, C-static) ——

// Call eval1 with invalid-expression error reporting (eval.c static,
// activates with eval_expr_string/f-4989 callers).
eval1_emsg_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, eap: rawptr) -> C.int {
	context = runtime.default_context()
	start := arg^
	did_emsg_before := did_emsg_g()
	called_emsg_before := called_emsg
	evalarg := Evalarg_T{}
	skip := false
	if eap != nil {
		skip = (^bool)(uintptr(eap) + 72)^
	}
	fill_evalarg_from_eap(&evalarg, eap, skip)
	ret := eval1(arg, rettv, rawptr(&evalarg))
	if ret == FAIL_E {
		if !aborting_r() && did_emsg_g() == did_emsg_before && called_emsg == called_emsg_before {
			semsg(cstring(E15_S), start)
		}
	}
	clear_evalarg(&evalarg, eap)
	return ret
}

// —— Batch 28m: eval.c expr-typval cluster ——

// Evaluate a partial value (eval.c static, dormant until eval_expr_typval).
eval_expr_partial_o :: proc "c" (expr: ^Typval_T, argv: ^Typval_T, argc: C.int, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	partial := rawptr(expr.vval)
	if partial == nil {
		return FAIL_E
	}
	s := partial_name(partial)
	if s == nil || ([^]u8)(s)[0] == 0 {
		return FAIL_E
	}
	fe := Funcexe_T{}
	fe.evaluate = true
	fe.partial = partial
	if call_func(s, -1, rettv, argc, argv, &fe) == FAIL_E {
		return FAIL_E
	}
	return OK_E
}

// Evaluate a funcref/string value (eval.c static, dormant until eval_expr_typval).
eval_expr_func_o :: proc "c" (expr: ^Typval_T, argv: ^Typval_T, argc: C.int, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	buf: [65]u8
	s: cstring = nil
	if expr.v_type == VAR_FUNC {
		s = transmute(cstring)(expr.vval)
	} else {
		s = tv_get_string_buf_chk(expr, &buf[0])
	}
	if s == nil || ([^]u8)(s)[0] == 0 {
		return FAIL_E
	}
	fe := Funcexe_T{}
	fe.evaluate = true
	if call_func(s, -1, rettv, argc, argv, &fe) == FAIL_E {
		return FAIL_E
	}
	return OK_E
}

// Evaluate a string value (eval.c static, dormant until eval_expr_typval).
eval_expr_string_o :: proc "c" (expr: ^Typval_T, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	buf: [65]u8
	s := tv_get_string_buf_chk(expr, &buf[0])
	if s == nil {
		return FAIL_E
	}
	s = skipwhite(s)
	sc := s
	if eval1_emsg_o(&sc, rettv, nil) == FAIL_E {
		return FAIL_E
	}
	if ([^]u8)(skipwhite(sc))[0] != 0 {
		tv_clear(rettv)
		semsg(cstring(E15_S), sc)
		return FAIL_E
	}
	return OK_E
}

// Evaluate partial/func/string typval (eval.c public).
@(export)
eval_expr_typval :: proc "c" (expr: ^Typval_T, want_func: bool, argv: ^Typval_T, argc: C.int, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	if expr.v_type == VAR_PARTIAL {
		return eval_expr_partial_o(expr, argv, argc, rettv)
	}
	if expr.v_type == VAR_FUNC || want_func {
		return eval_expr_func_o(expr, argv, argc, rettv)
	}
	return eval_expr_string_o(expr, rettv)
}

// —— Batch 28n: eval.c index cluster (FFI fully rewired) ——

E719_S :: "E719: Cannot slice a Dictionary"
E111_S :: "E111: Missing ']'"
E695_S :: "E695: Cannot index a Funcref"
E909_S :: "E909: Cannot index a special variable"
E806_S :: "E806: Using a Float as a String"
E716_S :: "E716: Key not present in Dictionary: \"%s\""
E716_LEN_S :: "E716: Key not present in Dictionary: \"%.*s\""

// Indexability check (eval.c static, dormant until eval_index_o/f_slice).
check_can_index_o :: proc "c" (rettv: ^Typval_T, evaluate: bool, verbose: bool) -> C.int {
	context = runtime.default_context()
	if rettv.v_type == VAR_FUNC || rettv.v_type == VAR_PARTIAL {
		if verbose {
			emsg(cstring(E695_S))
		}
		return FAIL_E
	} else if rettv.v_type == VAR_FLOAT {
		if verbose {
			emsg(cstring(E806_S))
		}
		return FAIL_E
	} else if rettv.v_type == VAR_BOOL || rettv.v_type == VAR_SPECIAL {
		if verbose {
			emsg(cstring(E909_S))
		}
		return FAIL_E
	} else if rettv.v_type == VAR_UNKNOWN {
		if evaluate {
			emsg(cstring(E909_S))
			return FAIL_E
		}
	}
	return OK_E
}

// Apply index/range to a value (eval.c static; f_slice + eval_index_o callers).
eval_index_inner_o :: proc "c" (rettv: ^Typval_T, is_range: bool, var1: ^Typval_T, var2: ^Typval_T, exclusive: bool, key: cstring, keylen: C.ptrdiff_t, verbose: bool) -> C.int {
	context = runtime.default_context()
	n1: C.longlong = 0
	n2: C.longlong = 0
	if var1 != nil && rettv.v_type != VAR_DICT {
		n1 = tv_get_number(var1)
	}
	if is_range {
		if rettv.v_type == VAR_DICT {
			if verbose {
				emsg(cstring(E719_S))
			}
			return FAIL_E
		}
		if var2 != nil {
			n2 = tv_get_number(var2)
		} else {
			n2 = VARNUMBER_MAX_O
		}
	}
	if rettv.v_type == VAR_NUMBER || rettv.v_type == VAR_STRING {
		s := tv_get_string(rettv)
		v: cstring = nil
		length := C.int(libc.strlen(s))
		if exclusive {
			if is_range {
				v = string_slice(s, n1, n2, exclusive)
			} else {
				v = char_from_string(s, n1)
			}
		} else if is_range {
			if n1 < 0 {
				n1 = C.longlong(length) + n1
				if n1 < 0 {
					n1 = 0
				}
			}
			if n2 < 0 {
				n2 = C.longlong(length) + n2
			} else if n2 >= C.longlong(length) {
				n2 = C.longlong(length)
			}
			if n1 >= C.longlong(length) || n2 < 0 || n1 > n2 {
				v = nil
			} else {
				v = transmute(cstring)(xmemdupz_o2(transmute(^u8)(rawptr(uintptr(rawptr(s)) + uintptr(n1))), C.size_t(n2 - n1 + 1)))
			}
		} else {
			if n1 >= C.longlong(length) || n1 < 0 {
				v = nil
			} else {
				v = transmute(cstring)(xmemdupz_o2(transmute(^u8)(rawptr(uintptr(rawptr(s)) + uintptr(n1))), 1))
			}
		}
		tv_clear(rettv)
		rettv.v_type = VAR_STRING
		rettv.vval = transmute(rawptr)(v)
	} else if rettv.v_type == VAR_BLOB {
		tv_blob_slice_or_index(rawptr(rettv.vval), is_range, n1, n2, exclusive, rettv)
	} else if rettv.v_type == VAR_LIST {
		if var1 == nil {
			n1 = 0
		}
		if var2 == nil {
			n2 = VARNUMBER_MAX_O
		}
		if tv_list_slice_or_index(rawptr(rettv.vval), is_range, n1, n2, exclusive, rettv, verbose) == FAIL_E {
			return FAIL_E
		}
	} else if rettv.v_type == VAR_DICT {
		k := key
		if k == nil {
			k = tv_get_string_chk(var1)
			if k == nil {
				return FAIL_E
			}
		}
		item := tv_dict_find(rawptr(rettv.vval), k, keylen)
		if item == nil && verbose {
			if keylen > 0 {
				semsg(cstring(E716_LEN_S), C.int(keylen), k)
			} else {
				semsg(cstring(E716_S), k)
			}
		}
		if item == nil || ((^Typval_T)(uintptr(item))).v_type == VAR_PARTIAL && is_luafunc(rawptr((^Typval_T)(uintptr(item)).vval)) {
			return FAIL_E
		}
		tmp := Typval_T{}
		tv_copy((^Typval_T)(uintptr(item)), &tmp)
		tv_clear(rettv)
		rettv^ = tmp
	}
	return OK_E
}

// Evaluate "[expr]"/"[a:b]"/".key" subscript (eval.c static, dormant until eval7).
eval_index_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, verbose: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	empty1 := false
	empty2 := false
	is_range := false
	key: cstring = nil
	keylen: C.ptrdiff_t = -1
	if check_can_index_o(rettv, evaluate, verbose) == FAIL_E {
		return FAIL_E
	}
	var1 := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	var2 := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	if ([^]u8)(arg^)[0] == '.' {
		key = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		keylen = 0
		for eval_isdictc(C.int(([^]u8)(rawptr(uintptr(rawptr(key)) + uintptr(keylen)))[0])) {
			keylen += 1
		}
		if keylen == 0 {
			return FAIL_E
		}
		arg^ = skipwhite(transmute(cstring)(rawptr(uintptr(rawptr(key)) + uintptr(keylen))))
	} else {
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		if ([^]u8)(arg^)[0] == ':' {
			empty1 = true
		} else if eval1(arg, &var1, evalarg) == FAIL_E {
			return FAIL_E
		} else if evaluate && !tv_check_str(&var1) {
			tv_clear(&var1)
			return FAIL_E
		}
		if ([^]u8)(arg^)[0] == ':' {
			is_range = true
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
			if ([^]u8)(arg^)[0] == ']' {
				empty2 = true
			} else if eval1(arg, &var2, evalarg) == FAIL_E {
				if !empty1 {
					tv_clear(&var1)
				}
				return FAIL_E
			} else if evaluate && !tv_check_str(&var2) {
				if !empty1 {
					tv_clear(&var1)
				}
				tv_clear(&var2)
				return FAIL_E
			}
		}
		if ([^]u8)(arg^)[0] != ']' {
			if verbose {
				emsg(cstring(E111_S))
			}
			tv_clear(&var1)
			if is_range {
				tv_clear(&var2)
			}
			return FAIL_E
		}
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	}
	if evaluate {
		v1: ^Typval_T = nil
		if !empty1 {
			v1 = &var1
		}
		v2: ^Typval_T = nil
		if !empty2 {
			v2 = &var2
		}
		res := eval_index_inner_o(rettv, is_range, v1, v2, false, key, keylen, verbose)
		if !empty1 {
			tv_clear(&var1)
		}
		if is_range {
			tv_clear(&var2)
		}
		return res
	}
	return OK_E
}

// "slice()" function (eval.c public).
@(export)
f_slice :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	if check_can_index_o((^Typval_T)(uintptr(argvars)), true, false) != OK_E {
		return
	}
	tv_copy((^Typval_T)(uintptr(argvars)), rettv)
	v2: ^Typval_T = nil
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		v2 = (^Typval_T)(uintptr(argvars) + 32)
	}
	eval_index_inner_o(rettv, true, (^Typval_T)(uintptr(argvars) + 16), v2, true, nil, 0, false)
}

// —— Batch 28o: eval.c eval_func (dormant plain, C-static) ——

// Resolve name + invoke function with parsed args (eval.c static,
// activates with eval_method/eval7 ports).
eval_func_o :: proc "c" (arg: ^cstring, evalarg: rawptr, name: cstring, name_len: C.int, rettv: ^Typval_T, flags: C.int, basetv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	evaluate := (flags & EVAL_EVALUATE_O) != 0
	s := name
	length := name_len
	found_var := false
	if !evaluate {
		check_vars(s, C.size_t(length))
	}
	partial: rawptr = nil
	s = deref_func_name(s, &length, &partial, !evaluate, &found_var)
	s = transmute(cstring)(xmemdupz_o2(transmute(^u8)(s), C.size_t(length)))
	fe := Funcexe_T{}
	fe.firstline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.lastline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.evaluate = evaluate
	fe.partial = partial
	fe.basetv = rawptr(basetv)
	fe.found_var = found_var
	ret := get_func_tv(s, length, rettv, arg, evalarg, &fe)
	xfree(rawptr(transmute(^u8)(s)))
	if rettv.v_type == VAR_UNKNOWN && !evaluate && ([^]u8)(arg^)[0] == '(' {
		rettv.vval = transmute(rawptr)(tv_empty_string)
		rettv.v_type = VAR_FUNC
	}
	if evaluate && aborting_r() {
		if ret == OK_E {
			tv_clear(rettv)
		}
		ret = FAIL_E
	}
	return ret
}

// —— Batch 28p: eval.c eval_number (dormant plain, C-static) ——
foreign _ {
	// trans_special — PORTED (keycodes.odin).
	@(link_name = "mb_copy_char")
	mb_copy_char_e :: proc "c" (fp: ^cstring, tp: ^cstring) ---
}

E1278_S :: "E1278: Stray '}' without a matching '{': %s"
E114_S :: "E114: Missing quote: %s"
E115_S :: "E115: Missing quote: %s"
E110_S :: "E110: Missing ')'"
E1169_S :: "E1169: Expression too recursive: %s"
E109_S :: "E109: Missing ':' after '?'"
FSK_IN_STRING_O :: 0x04
FSK_SIMPLIFY_O :: 0x08

E973_S :: "E973: Blob literal should have an even number of hex characters"

// Number/blob-literal parser (eval.c static, activates with eval7).
eval_number_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: bool, want_string: bool) -> C.int {
	context = runtime.default_context()
	p := skipdigits(transmute(cstring)(rawptr(uintptr(rawptr(arg^)) + 1)))
	get_float := false
	if !want_string && ([^]u8)(p)[0] == '.' && ascii_isdigit_o(([^]u8)(p)[1]) {
		get_float = true
		p = skipdigits(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 2)))
		if ([^]u8)(p)[0] == 'e' || ([^]u8)(p)[0] == 'E' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			if ([^]u8)(p)[0] == '-' || ([^]u8)(p)[0] == '+' {
				p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			}
			if !ascii_isdigit_o(([^]u8)(p)[0]) {
				get_float = false
			} else {
				p = skipdigits(transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1)))
			}
		}
		if (([^]u8)(p)[0] >= 'A' && ([^]u8)(p)[0] <= 'Z') || (([^]u8)(p)[0] >= 'a' && ([^]u8)(p)[0] <= 'z') || ([^]u8)(p)[0] == '.' {
			get_float = false
		}
	}
	if get_float {
		f: f64 = 0
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + uintptr(string2float(arg^, &f)))
		if evaluate {
			rettv.v_type = VAR_FLOAT
			rettv.vval = transmute(rawptr)(f)
		}
	} else if ([^]u8)(arg^)[0] == '0' && (([^]u8)(arg^)[1] == 'z' || ([^]u8)(arg^)[1] == 'Z') {
		blob: rawptr = nil
		if evaluate {
			blob = tv_blob_alloc()
		}
		bp := uintptr(rawptr(arg^)) + 2
		for ascii_isxdigit_o(([^]u8)(bp)[0]) {
			if !ascii_isxdigit_o(([^]u8)(bp + 1)[0]) {
				if blob != nil {
					emsg(cstring(E973_S))
					ga_clear((^Garray)(blob))
					xfree(blob)
				}
				return FAIL_E
			}
			if blob != nil {
				ga_append((^Garray)(blob), u8((hex2nr(C.int(([^]u8)(bp)[0])) << 4) + hex2nr(C.int(([^]u8)(bp + 1)[0]))))
			}
			if ([^]u8)(bp + 2)[0] == '.' && ascii_isxdigit_o(([^]u8)(bp + 3)[0]) {
				bp += 1
			}
			bp += 2
		}
		if blob != nil {
			tv_blob_set_ret_o(rettv, blob)
		}
		arg^ = transmute(cstring)(bp)
	} else {
		length: C.int = 0
		n: C.longlong = 0
		vim_str2nr(arg^, nil, &length, 0x0f, &n, nil, 0, true, nil)
		if length == 0 {
			if evaluate {
				semsg(cstring(E15_S), arg^)
			}
			return FAIL_E
		}
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + uintptr(length))
		if evaluate {
			rettv.v_type = VAR_NUMBER
			rettv.vval = transmute(rawptr)(n)
		}
	}
	return OK_E
}

// —— Batch 28q: eval.c eval_string (dormant plain, C-static) ——

// Double-quoted string parser with escapes + interpolation scan
// (eval.c static, activates with eval7).
eval_string_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: bool, interpolate: bool) -> C.int {
	context = runtime.default_context()
	arg_end := uintptr(rawptr(arg^)) + uintptr(libc.strlen(arg^))
	extra: C.uint = 0
	off: uintptr = 1
	if interpolate {
		extra = 1
		off = 0
	}
	p := uintptr(rawptr(arg^)) + off
	for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' {
		if ([^]u8)(p)[0] == '\\' && ([^]u8)(p + 1)[0] != 0 {
			p += 1
			if ([^]u8)(p)[0] == '<' {
				modifiers: C.int = 0
				flags: C.int = FSK_KEYCODE + FSK_IN_STRING_O
				extra += 5
				if ([^]u8)(p + 1)[0] != '*' {
					flags += FSK_SIMPLIFY_O
				}
				pc := transmute(cstring)(p)
				if find_special_key(transmute(^^u8)(&pc), C.size_t(arg_end - uintptr(rawptr(pc))), &modifiers, flags, nil) != 0 {
					p = uintptr(rawptr(pc)) - 1
				} else {
					p = uintptr(rawptr(pc))
				}
			}
		} else if interpolate && (([^]u8)(p)[0] == '{' || ([^]u8)(p)[0] == '}') {
			if ([^]u8)(p)[0] == '{' && ([^]u8)(p + 1)[0] != '{' {
				break
			}
			p += 1
			if ([^]u8)(p - 1)[0] == '}' && ([^]u8)(p)[0] != '}' {
				semsg(cstring(E1278_S), arg^)
				return FAIL_E
			}
			extra -= 1
		}
		// MB_PTR_ADV: advance past one (possibly multibyte) char
		p = uintptr(rawptr(p)) + uintptr(utfc_ptr2len(transmute(cstring)(p)))
	}
	if ([^]u8)(p)[0] != '"' && !(interpolate && ([^]u8)(p)[0] == '{') {
		semsg(cstring(E114_S), arg^)
		return FAIL_E
	}
	if !evaluate {
		arg^ = transmute(cstring)(p + off)
		return OK_E
	}
	rettv.v_type = VAR_STRING
	length := C.int(p - uintptr(rawptr(arg^)) + uintptr(extra))
	rettv.vval = transmute(rawptr)(xmalloc(C.size_t(length)))
	e := uintptr(rawptr(transmute(^u8)(rettv.vval)))
	p = uintptr(rawptr(arg^)) + off
	for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' {
		if ([^]u8)(p)[0] == '\\' {
			p += 1
			c := ([^]u8)(p)[0]
			if c == 'b' {
				([^]u8)(e)[0] = 8; e += 1; p += 1
			} else if c == 'e' {
				([^]u8)(e)[0] = 27; e += 1; p += 1
			} else if c == 'f' {
				([^]u8)(e)[0] = 12; e += 1; p += 1
			} else if c == 'n' {
				([^]u8)(e)[0] = 10; e += 1; p += 1
			} else if c == 'r' {
				([^]u8)(e)[0] = 13; e += 1; p += 1
			} else if c == 't' {
				([^]u8)(e)[0] = 9; e += 1; p += 1
			} else if c == 'X' || c == 'x' || c == 'u' || c == 'U' {
				if ascii_isxdigit_o(([^]u8)(p + 1)[0]) {
					n: C.int = 0
					up := c
					if up >= 'a' && up <= 'z' {
						up -= 32
					}
					if up == 'X' {
						n = 2
					} else if c == 'u' {
						n = 4
					} else {
						n = 8
					}
					nr: C.int = 0
					n -= 1
					for n >= 0 && ascii_isxdigit_o(([^]u8)(p + 1)[0]) {
						p += 1
						nr = (nr << 4) + C.int(hex2nr(C.int(([^]u8)(p)[0])))
						n -= 1
					}
					p += 1
					if up != 'X' {
						e = uintptr(rawptr(transmute(cstring)(e))) + uintptr(utf_char2bytes(nr, transmute(^u8)(e)))
					} else {
						([^]u8)(e)[0] = u8(nr); e += 1
					}
				}
			} else if c >= '0' && c <= '7' {
				v := c - '0'
				p += 1
				if ([^]u8)(p)[0] >= '0' && ([^]u8)(p)[0] <= '7' {
					v = (v << 3) + (([^]u8)(p)[0] - '0'); p += 1
					if ([^]u8)(p)[0] >= '0' && ([^]u8)(p)[0] <= '7' {
						v = (v << 3) + (([^]u8)(p)[0] - '0'); p += 1
					}
				}
				([^]u8)(e)[0] = v; e += 1
			} else if c == '<' {
				flags: C.int = FSK_KEYCODE + FSK_IN_STRING_O
				if ([^]u8)(p + 1)[0] != '*' {
					flags += FSK_SIMPLIFY_O
				}
				pc := transmute(cstring)(p)
				pcr := transmute(^u8)(pc)
				added := trans_special(&pcr, C.size_t(arg_end - uintptr(rawptr(pc))), transmute(^u8)(e), flags, false, nil)
				pc = transmute(cstring)(pcr)
				p = uintptr(rawptr(pc))
				if added != 0 {
					e += uintptr(added)
					if e >= uintptr(rawptr(transmute(^u8)(rettv.vval))) + uintptr(length) {
						iemsg_r(cstring("eval_string() used more space than allocated"))
					}
				} else {
					pc2 := transmute(cstring)(p)
					ec2 := transmute(cstring)(e)
					mb_copy_char_e(&pc2, &ec2)
					p = uintptr(rawptr(pc2)); e = uintptr(rawptr(ec2))
				}
			} else {
				pc2 := transmute(cstring)(p)
				ec2 := transmute(cstring)(e)
				mb_copy_char_e(&pc2, &ec2)
				p = uintptr(rawptr(pc2)); e = uintptr(rawptr(ec2))
			}
		} else {
			if interpolate && (([^]u8)(p)[0] == '{' || ([^]u8)(p)[0] == '}') {
				if ([^]u8)(p)[0] == '{' && ([^]u8)(p + 1)[0] != '{' {
					break
				}
				p += 1
			}
			pc2 := transmute(cstring)(p)
			ec2 := transmute(cstring)(e)
			mb_copy_char_e(&pc2, &ec2)
			p = uintptr(rawptr(pc2)); e = uintptr(rawptr(ec2))
		}
	}
	([^]u8)(e)[0] = 0
	if ([^]u8)(p)[0] == '"' && !interpolate {
		p += 1
	}
	arg^ = transmute(cstring)(p)
	return OK_E
}

// —— Batch 28r: eval.c eval_lit_string (dormant plain, C-static) ——

// Single-quoted literal parser with '' reduce + interpolation scan
// (eval.c static, activates with eval7).
eval_lit_string_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: bool, interpolate: bool) -> C.int {
	context = runtime.default_context()
	reduce: C.int = 0
	off: uintptr = 1
	if interpolate {
		reduce = -1
		off = 0
	}
	p := uintptr(rawptr(arg^)) + off
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '\'' {
			if ([^]u8)(p + 1)[0] != '\'' {
				break
			}
			reduce += 1
			p += 1
		} else if interpolate {
			if ([^]u8)(p)[0] == '{' {
				if ([^]u8)(p + 1)[0] != '{' {
					break
				}
				p += 1
				reduce += 1
			} else if ([^]u8)(p)[0] == '}' {
				p += 1
				if ([^]u8)(p)[0] != '}' {
					semsg(cstring(E1278_S), arg^)
					return FAIL_E
				}
				reduce += 1
			}
		}
		p = uintptr(rawptr(p)) + uintptr(utfc_ptr2len(transmute(cstring)(p)))
	}
	if ([^]u8)(p)[0] != '\'' && !(interpolate && ([^]u8)(p)[0] == '{') {
		semsg(cstring(E115_S), arg^)
		return FAIL_E
	}
	if !evaluate {
		arg^ = transmute(cstring)(p + off)
		return OK_E
	}
	str := (^u8)(xmalloc(C.size_t(C.int(p - uintptr(rawptr(arg^))) - reduce)))
	rettv.v_type = VAR_STRING
	rettv.vval = transmute(rawptr)(str)
	p = uintptr(rawptr(arg^)) + off
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '\'' {
			if ([^]u8)(p + 1)[0] != '\'' {
				break
			}
			p += 1
		} else if interpolate && (([^]u8)(p)[0] == '{' || ([^]u8)(p)[0] == '}') {
			if ([^]u8)(p)[0] == '{' && ([^]u8)(p + 1)[0] != '{' {
				break
			}
			p += 1
		}
		pc := transmute(cstring)(p)
		sc := transmute(cstring)(str)
		mb_copy_char_e(&pc, &sc)
		p = uintptr(rawptr(pc)); str = transmute(^u8)(sc)
	}
	str^ = 0
	arg^ = transmute(cstring)(p + off)
	return OK_E
}

// —— Batch 28s: eval.c eval_list (dormant plain, C-static) ——
E696_S :: "E696: Missing comma in List: %s"
E697_S :: "E697: Missing end of List ']': %s"

// List literal parser (eval.c static, activates with eval7).
eval_list_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	l: rawptr = nil
	if evaluate {
		l = tv_list_alloc(KLISTLEN_MAYKNOW_O)
	}
	arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	for ([^]u8)(arg^)[0] != ']' && ([^]u8)(arg^)[0] != 0 {
		tv := Typval_T{}
		if eval1(arg, &tv, evalarg) == FAIL_E {
			if evaluate {
				tv_list_free(l)
			}
			return FAIL_E
		}
		if evaluate {
			tv.v_lock = VAR_UNLOCKED
			tv_list_append_owned_tv(l, tv)
		}
		had_comma := ([^]u8)(arg^)[0] == ','
		if had_comma {
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		}
		if ([^]u8)(arg^)[0] == ']' {
			break
		}
		if !had_comma {
			semsg(cstring(E696_S), arg^)
			if evaluate {
				tv_list_free(l)
			}
			return FAIL_E
		}
	}
	if ([^]u8)(arg^)[0] != ']' {
		semsg(cstring(E697_S), arg^)
		if evaluate {
			tv_list_free(l)
		}
		return FAIL_E
	}
	arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	if evaluate {
		tv_list_set_ret_o(rettv, l)
	}
	return OK_E
}

// —— Batch 28t: eval.c dict cluster (dormant plains, C-statics) ——
E720_S :: "E720: Missing colon in Dictionary: %s"
E721_S :: "E721: Duplicate key in Dictionary: \"%s\""
E722_S :: "E722: Missing comma in Dictionary: %s"
E723_S :: "E723: Missing end of Dictionary '}': %s"

// Blob index/range lval resolver (eval.c static, dormant until get_lval port).
get_lval_blob_o :: proc "c" (lp: rawptr, var1: ^Typval_T, var2: ^Typval_T, empty1: bool, quiet: bool) -> C.int {
	context = runtime.default_context()
	ll_tv := (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
	bloblen := tv_blob_len_o((^rawptr)(uintptr(ll_tv) + 8)^)
	if empty1 {
		(^C.int)(uintptr(lp) + LL_N1_OFF_O)^ = 0
	} else {
		(^C.int)(uintptr(lp) + LL_N1_OFF_O)^ = C.int(tv_get_number(var1))
	}
	if tv_blob_check_index(bloblen, C.longlong((^C.int)(uintptr(lp) + LL_N1_OFF_O)^), quiet) == FAIL_E {
		return FAIL_E
	}
	if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ && !(^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^ {
		(^C.int)(uintptr(lp) + LL_N2_OFF_O)^ = C.int(tv_get_number(var2))
		if tv_blob_check_range(bloblen, C.longlong((^C.int)(uintptr(lp) + LL_N1_OFF_O)^), C.longlong((^C.int)(uintptr(lp) + LL_N2_OFF_O)^), quiet) == FAIL_E {
			return FAIL_E
		}
	}
	(^rawptr)(uintptr(lp) + LL_BLOB_OFF_O)^ = (^rawptr)(uintptr(ll_tv) + 8)^
	(^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ = nil
	return OK_E
}

// List index/range lval resolver (eval.c static, dormant until get_lval port).
get_lval_list_o :: proc "c" (lp: rawptr, var1: ^Typval_T, var2: ^Typval_T, empty1: bool, flags: C.int, quiet: bool) -> C.int {
	context = runtime.default_context()
	if empty1 {
		(^C.int)(uintptr(lp) + LL_N1_OFF_O)^ = 0
	} else {
		(^C.int)(uintptr(lp) + LL_N1_OFF_O)^ = C.int(tv_get_number(var1))
	}
	(^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^ = nil
	ll_tv := (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
	(^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^ = (^rawptr)(uintptr(ll_tv) + 8)^
	li := tv_list_check_range_index_one((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^, (^C.int)(uintptr(lp) + LL_N1_OFF_O), quiet)
	(^rawptr)(uintptr(lp) + LL_LI_OFF_O)^ = li
	if li == nil {
		return FAIL_E
	}
	if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ && !(^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^ {
		(^C.int)(uintptr(lp) + LL_N2_OFF_O)^ = C.int(tv_get_number(var2))
		if tv_list_check_range_index_two((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^, (^C.int)(uintptr(lp) + LL_N1_OFF_O), li, (^C.int)(uintptr(lp) + LL_N2_OFF_O), quiet) == FAIL_E {
			return FAIL_E
		}
	}
	(^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ = rawptr(uintptr(li) + 16)
	return OK_E
}

// —— Batch 28ai: eval.c get_lval_subscript (dormant plain, C-static) ——
E689_S :: "E689: Can only index a List, Dictionary or Blob"
E708_S :: "E708: [:] must come last"
E713_S :: "E713: Cannot use empty key after ."
E709_S :: "E709: [:] requires a List or Blob value"
E1203_S :: "E1203: Dot can only be used on a dictionary: %s"

// Subscript-chain walker for lvalues (eval.c static, dormant until get_lval).
get_lval_subscript_o :: proc "c" (lp: rawptr, p_in: cstring, name: cstring, rettv: ^Typval_T, ht: rawptr, v: rawptr, unlet: bool, flags: C.int) -> cstring {
	context = runtime.default_context()
	quiet := (flags & GLV_QUIET_O) != 0
	var1 := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	var2 := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	empty1 := false
	p := p_in
	done := false
	failed := false
	for !done && !failed && (([^]u8)(p)[0] == '[' || (([^]u8)(p)[0] == '.' && ([^]u8)(p)[1] != '=' && ([^]u8)(p)[1] != '.')) {
		ll_tv := (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
		ll_type := (^C.int)(uintptr(ll_tv))^
		if ([^]u8)(p)[0] == '.' && ll_type != VAR_DICT {
			if !quiet {
				semsg(cstring(E1203_S), name)
			}
			return nil
		}
		if ll_type != VAR_LIST && ll_type != VAR_DICT && ll_type != VAR_BLOB {
			if !quiet {
				emsg(cstring(E689_S))
			}
			return nil
		}
		if ll_type == VAR_LIST && (^rawptr)(uintptr(ll_tv) + 8)^ == nil {
			tv_list_alloc_ret(transmute(^Typval)(ll_tv), KLISTLEN_UNKNOWN_O)
		} else if ll_type == VAR_BLOB && (^rawptr)(uintptr(ll_tv) + 8)^ == nil {
			tv_blob_alloc_ret((^Typval_T)(ll_tv))
		}
		if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ {
			if !quiet {
				emsg(cstring(E708_S))
			}
			failed = true
			break
		}
		length: C.int = -1
		key: cstring = nil
		if ([^]u8)(p)[0] == '.' {
			key = transmute(cstring)(uintptr(rawptr(p)) + 1)
			length = 0
			for {
				cc := ([^]u8)(rawptr(uintptr(rawptr(key)) + uintptr(length)))[0]
				if !((cc >= 'A' && cc <= 'Z') || (cc >= 'a' && cc <= 'z') || (cc >= '0' && cc <= '9') || cc == '_') {
					break
				}
				length += 1
			}
			if length == 0 {
				if !quiet {
					emsg(cstring(E713_S))
				}
				return nil
			}
			p = transmute(cstring)(rawptr(uintptr(rawptr(key)) + uintptr(length)))
		} else {
			p = skipwhite(transmute(cstring)(uintptr(rawptr(p)) + 1))
			if ([^]u8)(p)[0] == ':' {
				empty1 = true
			} else {
				empty1 = false
				pc := p
				if eval1(&pc, &var1, rawptr(&EVALARG_EVALUATE_g)) == FAIL_E {
					failed = true
					break
				}
				p = pc
				if !tv_check_str(&var1) {
					failed = true
					break
				}
				p = skipwhite(p)
			}
			if ([^]u8)(p)[0] == ':' {
				if ll_type == VAR_DICT {
					if !quiet {
						emsg(cstring(E719_S))
					}
					failed = true
					break
				}
				if rettv != nil && !((^C.int)(uintptr(rettv))^ == VAR_LIST && rawptr((^Typval_T)(uintptr(rettv)).vval) != nil) && !((^C.int)(uintptr(rettv))^ == VAR_BLOB && rawptr((^Typval_T)(uintptr(rettv)).vval) != nil) {
					if !quiet {
						emsg(cstring(E709_S))
					}
					failed = true
					break
				}
				p = skipwhite(transmute(cstring)(uintptr(rawptr(p)) + 1))
				if ([^]u8)(p)[0] == ']' {
					(^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^ = true
				} else {
					(^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^ = false
					pc := p
					if eval1(&pc, &var2, rawptr(&EVALARG_EVALUATE_g)) == FAIL_E {
						failed = true
						break
					}
					p = pc
					if !tv_check_str(&var2) {
						failed = true
						break
					}
				}
				(^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ = true
			} else {
				(^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ = false
			}
			if ([^]u8)(p)[0] != ']' {
				if !quiet {
					emsg(cstring(E111_S))
				}
				failed = true
				break
			}
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		ll_tv = (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
		ll_type = (^C.int)(uintptr(ll_tv))^
		if ll_type == VAR_DICT {
			status := get_lval_dict_item_o(lp, name, key, length, &p, &var1, flags, unlet, rettv)
			if status == GLV_FAIL_O {
				failed = true
				break
			}
			if status == GLV_STOP_O {
				done = true
				break
			}
		} else if ll_type == VAR_BLOB {
			if get_lval_blob_o(lp, &var1, &var2, empty1, quiet) == FAIL_E {
				failed = true
				break
			}
			done = true
			break
		} else {
			if get_lval_list_o(lp, &var1, &var2, empty1, flags, quiet) == FAIL_E {
				failed = true
				break
			}
		}
		tv_clear(&var1)
		tv_clear(&var2)
		var1.v_type = VAR_UNKNOWN
		var2.v_type = VAR_UNKNOWN
	}
	tv_clear(&var1)
	tv_clear(&var2)
	if failed {
		return nil
	}
	return p
}

// —— Batch 28aj: eval.c make_expanded_name + get_lval ——
E121B_S :: "E121: Undefined variable"

// Brace-expanded name builder (eval.c static, dormant until get_lval).
make_expanded_name_o :: proc "c" (in_start: cstring, expr_start: cstring, expr_end: cstring, in_end: cstring) -> cstring {
	context = runtime.default_context()
	if expr_end == nil || in_end == nil {
		return nil
	}
	retval: cstring = nil
	es := expr_start
	ee := expr_end
	ie := in_end
	([^]u8)(es)[0] = 0
	([^]u8)(ee)[0] = 0
	c1 := ([^]u8)(ie)[0]
	([^]u8)(ie)[0] = 0
	temp_result := eval_to_string(transmute(cstring)(uintptr(rawptr(es)) + 1), false, false)
	if temp_result != nil {
		retvalsize := C.size_t(uintptr(rawptr(es)) - uintptr(rawptr(in_start)) + uintptr(libc.strlen(temp_result)) + uintptr(uintptr(rawptr(ie)) - uintptr(rawptr(ee))) + 1)
		retval = transmute(cstring)(xmalloc(retvalsize))
		libc.snprintf(transmute([^]u8)(retval), retvalsize, cstring("%s%s%s"), in_start, temp_result, transmute(cstring)(uintptr(rawptr(ee)) + 1))
	}
	xfree(rawptr(transmute(^u8)(temp_result)))
	([^]u8)(ie)[0] = c1
	([^]u8)(es)[0] = '{'
	([^]u8)(ee)[0] = '}'
	if retval != nil {
		es2: cstring = nil
		ee2: cstring = nil
		temp_result = transmute(cstring)(find_name_end(retval, &es2, &ee2, 0))
		if es2 != nil {
			temp_result = transmute(cstring)(make_expanded_name_o(retval, es2, ee2, temp_result))
			xfree(rawptr(transmute(^u8)(retval)))
			retval = transmute(cstring)(temp_result)
		}
	}
	return retval
}

// Lvalue name parser (eval.c public).
@(export)
get_lval :: proc "c" (name: cstring, rettv: rawptr, lp: rawptr, unlet: bool, skip: bool, flags: C.int, fne_flags: C.int) -> cstring {
	context = runtime.default_context()
	quiet := (flags & GLV_QUIET_O) != 0
	libc.memset(lp, 0, 96)
	if skip {
		(^rawptr)(uintptr(lp) + 0)^ = rawptr(name)
		return transmute(cstring)(find_name_end(name, nil, nil, FNE_INCL_BR_O | fne_flags))
	}
	expr_start: cstring = nil
	expr_end: cstring = nil
	p := find_name_end(name, &expr_start, &expr_end, fne_flags)
	if expr_start != nil {
		if unlet && !ascii_iswhite(([^]u8)(p)[0]) && ends_excmd(C.int(([^]u8)(p)[0])) == 0 && ([^]u8)(p)[0] != '[' && ([^]u8)(p)[0] != '.' {
			semsg(cstring(E488_S), p)
			return nil
		}
		exp := make_expanded_name_o(name, expr_start, expr_end, p)
		(^rawptr)(uintptr(lp) + 16)^ = rawptr(transmute(^u8)(exp))
		(^rawptr)(uintptr(lp) + 0)^ = rawptr(transmute(^u8)(exp))
		if exp == nil {
			if !aborting_r() && !quiet {
				emsg_severe_g = true
				semsg(cstring(E15_S), name)
				return nil
			}
			(^C.size_t)(uintptr(lp) + 8)^ = 0
		} else {
			(^C.size_t)(uintptr(lp) + 8)^ = C.size_t(libc.strlen(transmute(cstring)((^rawptr)(uintptr(lp) + 0)^)))
		}
	} else {
		(^rawptr)(uintptr(lp) + 0)^ = rawptr(name)
		(^C.size_t)(uintptr(lp) + 8)^ = C.size_t(uintptr(rawptr(p)) - uintptr(rawptr((^rawptr)(uintptr(lp) + 0)^)))
	}
	if ([^]u8)(p)[0] != '[' && ([^]u8)(p)[0] != '.' || (^rawptr)(uintptr(lp) + 0)^ == nil {
		return p
	}
	ht_buf: [296]u8
	htp: rawptr = nil
	if (flags & GLV_READ_ONLY_O) == 0 {
		htp = rawptr(&ht_buf[0])
	}
	no_autoload: C.int = 0
	if (flags & GLV_NO_AUTOLOAD_O) != 0 {
		no_autoload = 1
	}
	v := find_var(transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), (^C.size_t)(uintptr(lp) + 8)^, htp, no_autoload)
	if v == nil && !quiet {
		semsg(cstring(E121B_S), C.int((^C.size_t)(uintptr(lp) + 8)^), transmute(cstring)((^rawptr)(uintptr(lp) + 0)^))
	}
	if v == nil {
		return nil
	}
	(^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ = rawptr(uintptr(v))
	if ((^Typval_T)(uintptr(v))).v_type == VAR_PARTIAL && is_luafunc(rawptr((^Typval_T)(uintptr(v)).vval)) {
		return p
	}
	p = get_lval_subscript_o(lp, p, name, transmute(^Typval_T)(rettv), htp, v, unlet, flags)
	if p == nil {
		return nil
	}
	(^C.size_t)(uintptr(lp) + 8)^ = C.size_t(uintptr(rawptr(p)) - uintptr(rawptr((^rawptr)(uintptr(lp) + 0)^)))
	return p
}
GLV_QUIET_O :: 2
GLV_FAIL_O :: 0
GLV_OK_O :: 1
GLV_STOP_O :: 2
DV_SCOPE_OFF_O :: 4

// Dict-item lval resolver (eval.c static, dormant until get_lval port).
get_lval_dict_item_o :: proc "c" (lp: rawptr, name: cstring, key: cstring, length: C.int, key_end: ^cstring, var1: ^Typval_T, flags: C.int, unlet: bool, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	quiet := (flags & GLV_QUIET_O) != 0
	p := key_end^
	k := key
	if length == -1 {
		k = tv_get_string(var1)
	}
	(^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^ = nil
	tv_ptr := (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
	if (^rawptr)(uintptr(tv_ptr) + 8)^ == nil {
		nd := tv_dict_alloc()
		(^rawptr)(uintptr(tv_ptr) + 8)^ = rawptr(nd)
		(^C.int)(uintptr(rawptr(nd)) + 8)^ += 1
	}
	d := (^rawptr)(uintptr(tv_ptr) + 8)^
	(^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^ = d
	di := tv_dict_find(d, k, C.ptrdiff_t(length))
	(^rawptr)(uintptr(lp) + LL_DI_OFF_O)^ = di
	if rettv != nil && (^C.int)(uintptr(d) + DV_SCOPE_OFF_O)^ != 0 {
		wrong := false
		if length != -1 {
			// NUL-terminate a copy for validation (key points into cmdline)
			kc := (^u8)(xmemdupz_o2(transmute(^u8)(k), C.size_t(length) + 1))
			([^]u8)(kc)[length] = 0
			wrong = ((^C.int)(uintptr(d) + DV_SCOPE_OFF_O)^ == VAR_DEF_SCOPE_O && tv_is_func_o(rettv^) && var_wrong_func_name(transmute(cstring)(kc), di == nil)) || !valid_varname(transmute(cstring)(kc))
			xfree(rawptr(kc))
		} else {
			wrong = ((^C.int)(uintptr(d) + DV_SCOPE_OFF_O)^ == VAR_DEF_SCOPE_O && tv_is_func_o(rettv^) && var_wrong_func_name(k, di == nil)) || !valid_varname(k)
		}
		if wrong {
			return GLV_FAIL_O
		}
	}
	if di != nil && ((^Typval_T)(uintptr(di))).v_type == VAR_PARTIAL && is_luafunc(rawptr((^Typval_T)(uintptr(di)).vval)) && length == -1 && rettv == nil {
		semsg(cstring(E461_S), cstring("v:['lua']"))
		return GLV_FAIL_O
	}
	if di == nil {
		if d == get_vimvar_dict() || rawptr(uintptr(d) + 16) == get_funccal_args_ht() {
			semsg(cstring(E461_S), name)
			return GLV_FAIL_O
		}
		if ([^]u8)(p)[0] == '[' || ([^]u8)(p)[0] == '.' || unlet {
			if !quiet {
				semsg(cstring(E716_S), k)
			}
			return GLV_FAIL_O
		}
		if length == -1 {
			(^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^ = rawptr(xstrdup_o(transmute(^u8)(k)))
		} else {
			(^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^ = rawptr(xmemdupz_o2(transmute(^u8)(k), C.size_t(length)))
		}
		key_end^ = p
		return GLV_STOP_O
	} else if (flags & GLV_READ_ONLY_O) == 0 && (var_check_ro(C.int((^u8)(uintptr(di) + 16)^), name, C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(name)))) || var_check_lock(C.int((^u8)(uintptr(di) + 16)^), name, C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(name))))) {
		return GLV_FAIL_O
	}
	(^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ = rawptr(uintptr(di))
	return GLV_OK_O
}
E112_S :: "E112: Option name missing: %s"
E113_S :: "E113: Unknown option: %s"
E1265_S :: "E1265: Cannot use a partial here"
E1085_S :: "E1085: Not a callable type: %s"
E260_S :: "E260: Missing name after ->"

// Option-name value reader (eval.c public).
@(export)
eval_option :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: bool) -> C.int {
	context = runtime.default_context()
	working := ([^]u8)(arg^)[0] == '+'
	opt_idx: C.int = 0
	opt_flags: C.int = 0
	option_end := find_option_var_end(arg, &opt_idx, &opt_flags)
	if option_end == nil {
		if rettv != nil {
			semsg(cstring(E112_S), arg^)
		}
		return FAIL_E
	}
	if !evaluate {
		arg^ = option_end
		return OK_E
	}
	c := ([^]u8)(option_end)[0]
	([^]u8)(option_end)[0] = 0
	ret: C.int = OK_E
	is_tty_opt := is_tty_option(arg^)
	if opt_idx == kOptInvalid_S && !is_tty_opt {
		if rettv != nil {
			semsg(cstring(E113_S), arg^)
		}
		ret = FAIL_E
	} else if rettv != nil {
		value := get_tty_option(arg^) if is_tty_opt else get_option_value(opt_idx, opt_flags)
		rettv^ = optval_as_tv(value, true)
	} else if working && !is_tty_opt && is_option_hidden(opt_idx) {
		ret = FAIL_E
	}
	([^]u8)(option_end)[0] = c
	arg^ = option_end
	return ret
}

// Environment variable reader (eval.c static, dormant until eval7).
eval_env_var_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: C.int) -> C.int {
	context = runtime.default_context()
	arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
	name := arg^
	length := get_env_len(arg)
	if evaluate != 0 {
		if length == 0 {
			return FAIL_E
		}
		cc := ([^]u8)(rawptr(uintptr(rawptr(name)) + uintptr(length)))[0]
		([^]u8)(rawptr(uintptr(rawptr(name)) + uintptr(length)))[0] = 0
		string := vim_getenv(name)
		if string == nil || ([^]u8)(string)[0] == 0 {
			xfree(rawptr(transmute(^u8)(string)))
			string = expand_env_save(transmute(cstring)(uintptr(rawptr(name)) - 1))
			if string != nil && ([^]u8)(string)[0] == '$' {
				xfree(rawptr(transmute(^u8)(string)))
				string = nil
			}
		}
		([^]u8)(rawptr(uintptr(rawptr(name)) + uintptr(length)))[0] = cc
		rettv.v_type = VAR_STRING
		rettv.vval = transmute(rawptr)(string)
		rettv.v_lock = VAR_UNLOCKED
	}
	return OK_E
}

// —— Batch 28v: eval.c eval_interp_string (export + weak) ——

// Interpolated $".."/$'..' string evaluator (eval.c public).
@(export)
eval_interp_string :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evaluate: bool) -> C.int {
	context = runtime.default_context()
	ret: C.int = OK_E
	ga := Garray{}
	ga_init(&ga, 1, 80)
	arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
	quote := ([^]u8)(arg^)[0]
	arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
	for {
		tv := Typval_T{}
		if quote == '"' {
			ret = eval_string_o(arg, &tv, evaluate, true)
		} else {
			ret = eval_lit_string_o(arg, &tv, evaluate, true)
		}
		if ret == FAIL_E {
			break
		}
		if evaluate {
			ga_concat(&ga, transmute(cstring)(tv.vval))
			tv_clear(&tv)
		}
		if ([^]u8)(arg^)[0] != '{' {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
			break
		}
		p := eval_one_expr_in_str(transmute(^u8)(arg^), &ga, evaluate)
		if p == nil {
			ret = FAIL_E
			break
		}
		arg^ = transmute(cstring)(p)
	}
	rettv.v_type = VAR_STRING
	if ret != FAIL_E && evaluate {
		ga_append(&ga, 0)
	}
	rettv.vval = ga.ga_data
	return OK_E
}

// —— Batch 28w: eval.c eval7 (dormant plain, C-static) ——

@(private = "file")
eval7_recurse_g: C.int

// Primary expression parser (eval.c static, activates eval6/eval_method).
eval7_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, want_string: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	ret: C.int = OK_E
	rettv.v_type = VAR_UNKNOWN
	start_leader := arg^
	for ([^]u8)(arg^)[0] == '!' || ([^]u8)(arg^)[0] == '-' || ([^]u8)(arg^)[0] == '+' {
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	}
	end_leader := arg^
	if eval7_recurse_g == 1000 {
		semsg(cstring(E1169_S), arg^)
		return FAIL_E
	}
	eval7_recurse_g += 1
	c := ([^]u8)(arg^)[0]
	done := true
	if c >= '0' && c <= '9' {
		ret = eval_number_o(arg, rettv, evaluate, want_string)
		if ret == OK_E && evaluate && uintptr(rawptr(end_leader)) > uintptr(rawptr(start_leader)) {
			ret = eval7_leader_o(rettv, true, start_leader, &end_leader)
		}
	} else if c == '"' {
		ret = eval_string_o(arg, rettv, evaluate, false)
	} else if c == '\'' {
		ret = eval_lit_string_o(arg, rettv, evaluate, false)
	} else if c == '[' {
		ret = eval_list_o(arg, rettv, evalarg)
	} else if c == '#' {
		ret = eval_lit_dict_o(arg, rettv, evalarg)
	} else if c == '{' {
		ret = get_lambda_tv(arg, rettv, evalarg)
		if ret == NOTDONE_O {
			ret = eval_dict_o(arg, rettv, evalarg, false)
		}
	} else if c == '&' {
		ret = eval_option(arg, rettv, evaluate)
	} else if c == '$' {
		if ([^]u8)(arg^)[1] == '"' || ([^]u8)(arg^)[1] == '\'' {
			ret = eval_interp_string(arg, rettv, evaluate)
		} else {
			ret = eval_env_var_o(arg, rettv, C.int(evaluate))
		}
	} else if c == '@' {
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		if evaluate {
			rettv.v_type = VAR_STRING
			rettv.vval = transmute(rawptr)(get_reg_contents(C.int(([^]u8)(arg^)[0]), kGRegExprSrc))
		}
		if ([^]u8)(arg^)[0] != 0 {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		}
	} else if c == '(' {
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		ret = eval1(arg, rettv, evalarg)
		if ([^]u8)(arg^)[0] == ')' {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		} else if ret == OK_E {
			emsg(cstring(E110_S))
			tv_clear(rettv)
			ret = FAIL_E
		}
	} else {
		done = false
	}
	if !done {
		s := arg^
		alias: cstring = nil
		length := get_name_len(arg, &alias, evaluate, true)
		if alias != nil {
			s = alias
		}
		if length <= 0 {
			ret = FAIL_E
		} else {
			flags: C.int = 0
			if evalarg != nil {
				flags = (^Evalarg_T)(evalarg).eval_flags
			}
			if ([^]u8)(skipwhite(arg^))[0] == '(' {
				arg^ = skipwhite(arg^)
				ret = eval_func_o(arg, evalarg, s, length, rettv, flags, nil)
			} else if evaluate {
				ret = eval_variable(s, length, rettv, nil, true, false)
			} else {
				check_vars(s, C.size_t(length))
				if rettv.v_type == VAR_UNKNOWN && strnequal(s, cstring("v:lua."), 6) {
					rettv.v_type = VAR_PARTIAL
					rettv.vval = transmute(rawptr)(get_vim_var_partial(VV_LUA_O))
					(^C.int)(uintptr(rawptr(rettv.vval)))^ += 1
				}
				ret = OK_E
			}
		}
		xfree(rawptr(transmute(^u8)(alias)))
	}
	arg^ = skipwhite(arg^)
	if ret == OK_E {
		ret = handle_subscript(arg, rettv, evalarg, true)
	}
	if ret == OK_E && evaluate && uintptr(rawptr(end_leader)) > uintptr(rawptr(start_leader)) {
		ret = eval7_leader_o(rettv, false, start_leader, &end_leader)
	}
	eval7_recurse_g -= 1
	return ret
}

// —— Batch 28ad: eval.c eval_method + handle_subscript ——

// Evaluate "->method()"/"->v:lua.method()" (eval.c static,
// dormant until eval7_o activation wires it).
eval_method_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, verbose: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 2)
	base := rettv^
	rettv.v_type = VAR_UNKNOWN
	length: C.int = 0
	name := arg^
	lua_funcname: cstring = nil
	alias: cstring = nil
	if libc.strncmp(name, cstring("v:lua."), 6) == 0 {
		lua_funcname = transmute(cstring)(uintptr(rawptr(name)) + 6)
		arg^ = skip_luafunc_name(lua_funcname)
		arg^ = skipwhite(arg^)
		length = C.int(uintptr(rawptr(arg^)) - uintptr(rawptr(lua_funcname)))
	} else {
		length = get_name_len(arg, &alias, evaluate, true)
		if alias != nil {
			name = alias
		}
	}
	tofree: cstring = nil
	ret: C.int = OK_E
	if length <= 0 {
		if verbose {
			if lua_funcname == nil {
				emsg(cstring(E260_S))
			} else {
				semsg(cstring(E15_S), name)
			}
		}
		ret = FAIL_E
	} else {
		arg^ = skipwhite(arg^)
		paren := vim_strchr_c(transmute(^u8)(arg^), C.int('('))
		if ([^]u8)(arg^)[0] != '(' && lua_funcname == nil && alias == nil && paren != nil {
			arg^ = name
			([^]u8)(paren)[0] = 0
			ref := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
			if eval7_o(arg, &ref, evalarg, false) == FAIL_E {
				arg^ = transmute(cstring)(uintptr(rawptr(name)) + uintptr(length))
				ret = FAIL_E
			} else if ([^]u8)(skipwhite(arg^))[0] != 0 {
				if verbose {
					semsg(cstring(E488_S), arg^)
				}
				ret = FAIL_E
			} else if ref.v_type == VAR_FUNC && rawptr(ref.vval) != nil {
				name = transmute(cstring)(ref.vval)
				ref.vval = nil
				tofree = name
				length = C.int(libc.strlen(name))
			} else if ref.v_type == VAR_PARTIAL && rawptr(ref.vval) != nil {
				pt := rawptr(ref.vval)
				if (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ > 0 || (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ != nil {
					if verbose {
						emsg(cstring(E1265_S))
					}
					ret = FAIL_E
				} else {
					name = transmute(cstring)(xstrdup_o(transmute(^u8)(partial_name(pt))))
					tofree = name
					if name == nil {
						ret = FAIL_E
						name = arg^
					} else {
						length = C.int(libc.strlen(name))
					}
				}
			} else {
				if verbose {
					semsg(cstring(E1085_S), name)
				}
				ret = FAIL_E
			}
			tv_clear(&ref)
			([^]u8)(paren)[0] = '('
		}
		if ret == OK_E {
			if ([^]u8)(arg^)[0] != '(' {
				if verbose {
					semsg(cstring(E107_S), name)
				}
				ret = FAIL_E
			} else if ascii_iswhite(([^]u8)(arg^)[-1]) {
				if verbose {
					emsg(cstring(E274_S))
				}
				ret = FAIL_E
			} else if lua_funcname != nil {
				if evaluate {
					rettv.v_type = VAR_PARTIAL
					rettv.vval = transmute(rawptr)(get_vim_var_partial(VV_LUA_O))
					(^C.int)(uintptr(rawptr(rettv.vval)))^ += 1
				}
				ret = call_func_rettv_o(arg, evalarg, rettv, evaluate, nil, rawptr(&base), lua_funcname)
			} else {
				ret = eval_func_o(arg, evalarg, name, length, rettv, C.int(evaluate), &base)
			}
		}
	}
	if evaluate {
		tv_clear(&base)
	}
	xfree(rawptr(transmute(^u8)(tofree)))
	if alias != nil {
		xfree(rawptr(transmute(^u8)(alias)))
	}
	return ret
}

// Subscript/method/call chain after a primary (eval.c public).
@(export)
handle_subscript :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, verbose: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	ret: C.int = OK_E
	selfdict: rawptr = nil
	lua_funcname: cstring = nil
	if rettv.v_type == VAR_PARTIAL && is_luafunc(rawptr(rettv.vval)) {
		if !evaluate {
			tv_clear(rettv)
		}
		if ([^]u8)(arg^)[0] != '.' {
			tv_clear(rettv)
			ret = FAIL_E
		} else {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
			lua_funcname = arg^
			length := check_luafunc_name(arg^, true)
			if length == 0 {
				tv_clear(rettv)
				ret = FAIL_E
			}
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + uintptr(length))
		}
	}
	for {
		if ret != OK_E {
			break
		}
		c0 := ([^]u8)(arg^)[0]
		is_sub := false
		if c0 == '[' {
			is_sub = true
		} else if c0 == '.' && rettv.v_type == VAR_DICT {
			is_sub = true
		} else if c0 == '(' {
			if !evaluate {
				is_sub = true
			} else if tv_is_func_o(rettv^) {
				is_sub = true
			}
		}
		if is_sub && ascii_iswhite(([^]u8)(rawptr(uintptr(rawptr(arg^)) - 1))[0]) {
			is_sub = false
		}
		is_arrow := c0 == '-' && ([^]u8)(arg^)[1] == '>'
		if !is_sub && !is_arrow {
			break
		}
		if ([^]u8)(arg^)[0] == '(' {
			ret = call_func_rettv_o(arg, evalarg, rettv, evaluate, selfdict, nil, lua_funcname)
			if aborting_r() {
				if ret == OK_E {
					tv_clear(rettv)
				}
				ret = FAIL_E
			}
			tv_dict_unref(selfdict)
			selfdict = nil
		} else if ([^]u8)(arg^)[0] == '-' {
			if ([^]u8)(arg^)[2] == '{' {
				ret = eval_lambda_o(arg, rettv, evalarg, verbose)
			} else {
				ret = eval_method_o(arg, rettv, evalarg, verbose)
			}
		} else {
			tv_dict_unref(selfdict)
			if rettv.v_type == VAR_DICT {
				selfdict = rawptr(rettv.vval)
				if selfdict != nil {
					(^C.int)(uintptr(selfdict) + 8)^ += 1
				}
			} else {
				selfdict = nil
			}
			if eval_index_o(arg, rettv, evalarg, verbose) == FAIL_E {
				tv_clear(rettv)
				ret = FAIL_E
			}
		}
	}
	if selfdict != nil && tv_is_func_o(rettv^) {
		set_selfdict(rettv, selfdict)
	}
	tv_dict_unref(selfdict)
	return ret
}

// —— Batch 28ba: eval.c partial lifecycle (exports + weak) ——

// Partial display name (eval.c public).
@(export)
partial_name :: proc "c" (pt: rawptr) -> cstring {
	context = runtime.default_context()
	if pt != nil {
		if (^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ != nil {
			return transmute(cstring)((^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^)
		}
		if (^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ != nil {
			return transmute(cstring)(uintptr((^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^) + UF_NAME_OFF_O)
		}
	}
	return cstring("")
}

// Partial storage release (eval.c static).
partial_free_o :: proc "c" (pt: rawptr) {
	context = runtime.default_context()
	i: C.int = 0
	for i < (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ {
		tv_clear((^Typval_T)(uintptr((^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^) + uintptr(i) * 16))
		i += 1
	}
	xfree((^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^)
	tv_dict_unref((^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^)
	if (^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ != nil {
		func_unref(transmute(cstring)((^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^))
		xfree((^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^)
	} else {
		func_ptr_unref((^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^)
	}
	xfree(pt)
}

// Closure unreference (eval.c public).
@(export)
partial_unref :: proc "c" (pt: rawptr) {
	context = runtime.default_context()
	if pt == nil {
		return
	}
	(^C.int)(uintptr(pt) + PT_REFCOUNT_OFF_O)^ -= 1
	if (^C.int)(uintptr(pt) + PT_REFCOUNT_OFF_O)^ <= 0 {
		partial_free_o(pt)
	}
}

// —— Batch 28az: eval.c funcref compare + simple-call + grow (exports + weak) ——

// Funcref equality (eval.c public).
@(export)
func_equal :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, ic: bool) -> bool {
	context = runtime.default_context()
	s1: cstring = nil
	if tv1.v_type == VAR_FUNC {
		s1 = transmute(cstring)(tv1.vval)
	} else {
		s1 = partial_name(rawptr(tv1.vval))
	}
	if s1 != nil && ([^]u8)(s1)[0] == 0 {
		s1 = nil
	}
	s2: cstring = nil
	if tv2.v_type == VAR_FUNC {
		s2 = transmute(cstring)(tv2.vval)
	} else {
		s2 = partial_name(rawptr(tv2.vval))
	}
	if s2 != nil && ([^]u8)(s2)[0] == 0 {
		s2 = nil
	}
	if s1 == nil || s2 == nil {
		if s1 != s2 {
			return false
		}
	} else if libc.strcmp(s1, s2) != 0 {
		return false
	}
	d1: rawptr = nil
	d2: rawptr = nil
	if tv1.v_type != VAR_FUNC {
		d1 = (^rawptr)(uintptr(rawptr(tv1.vval)) + PT_DICT_OFF_O)^
	}
	if tv2.v_type != VAR_FUNC {
		d2 = (^rawptr)(uintptr(rawptr(tv2.vval)) + PT_DICT_OFF_O)^
	}
	if d1 == nil || d2 == nil {
		if d1 != d2 {
			return false
		}
	} else if !tv_dict_equal(d1, d2, ic) {
		return false
	}
	a1: C.int = 0
	a2: C.int = 0
	if tv1.v_type != VAR_FUNC {
		a1 = (^C.int)(uintptr(rawptr(tv1.vval)) + PT_ARGC_OFF_O)^
	}
	if tv2.v_type != VAR_FUNC {
		a2 = (^C.int)(uintptr(rawptr(tv2.vval)) + PT_ARGC_OFF_O)^
	}
	if a1 != a2 {
		return false
	}
	i: C.int = 0
	for i < a1 {
		if !tv_equal((^Typval_T)(uintptr((^rawptr)(uintptr(rawptr(tv1.vval)) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), (^Typval_T)(uintptr((^rawptr)(uintptr(rawptr(tv2.vval)) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), ic) {
			return false
		}
		i += 1
	}
	return true
}

// Name-end scanner with namespace rule (eval.c static, dormant until simple-func).
to_name_end_o :: proc "c" (arg: cstring, use_namespace: bool) -> cstring {
	context = runtime.default_context()
	if !eval_isnamec1(C.int(([^]u8)(arg)[0])) {
		return arg
	}
	p := transmute(cstring)(uintptr(rawptr(arg)) + 1)
	for ([^]u8)(p)[0] != 0 && eval_isnamec(C.int(([^]u8)(p)[0])) {
		if ([^]u8)(p)[0] == ':' && (p != transmute(cstring)(uintptr(rawptr(arg)) + 1) || !use_namespace || !vim_strchr_bgstvw_o(([^]u8)(arg)[0])) {
			break
		}
		p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
	}
	return p
}

// Namespace-set membership ("abglstvw" + namespaces incl. a/l).
vim_strchr_bgstvw_o :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return c == 'a' || c == 'b' || c == 'g' || c == 'l' || c == 's' || c == 't' || c == 'v' || c == 'w'
}

// Zero-arg `Name()` fast path (eval.c public).
@(export)
may_call_simple_func :: proc "c" (arg: cstring, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	parens := strstr_c(arg, cstring("()"))
	r: C.int = NOTDONE_O
	if parens != nil && ([^]u8)(skipwhite(transmute(cstring)(uintptr(rawptr(parens)) + 2)))[0] == 0 {
		if strnequal(arg, cstring("v:lua."), 6) {
			p := transmute(cstring)(uintptr(rawptr(arg)) + 6)
			if p != transmute(cstring)(parens) && skip_luafunc_name(p) == transmute(cstring)(parens) {
				r = call_simple_luafunc(p, C.size_t(uintptr(rawptr(parens)) - uintptr(rawptr(p))), rettv)
			}
		} else {
			p := arg
			if libc.strncmp(arg, cstring("<SNR>"), 5) == 0 {
				p = skipdigits(transmute(cstring)(uintptr(rawptr(arg)) + 5))
			}
			if to_name_end_o(p, true) == transmute(cstring)(parens) {
				r = call_simple_func(arg, C.size_t(uintptr(rawptr(parens)) - uintptr(rawptr(arg))), rettv)
			}
		}
	}
	return r
}

// In-place string append (eval.c public).
@(export)
grow_string_tv :: proc "c" (tv1: ^Typval_T, s2: cstring) -> C.int {
	context = runtime.default_context()
	if tv1.v_type != VAR_STRING || rawptr(tv1.vval) == nil {
		return FAIL_E
	}
	len1 := libc.strlen(transmute(cstring)(tv1.vval))
	len2 := libc.strlen(s2)
	p := (^u8)(xrealloc(rawptr(tv1.vval), len1 + len2 + 1))
	libc.memmove(rawptr(uintptr(p) + uintptr(len1)), rawptr(transmute(^u8)(s2)), len2 + 1)
	tv1.vval = transmute(rawptr)(p)
	return OK_E
}

// —— Batch 28ay: eval.c set_context_for_expression (FFI fully rewired) ——

EXPAND_COMMANDS_O :: 1
EXPAND_USER_VARS_O :: 15
EXPAND_FUNCTIONS_O :: 18
EXPAND_EXPRESSION_O :: 20
EXPAND_ENV_VARS_O :: 26
CMD_LET_O :: 231
CMD_CALL_O :: 53

// Completion context for :let/:const/:call/expression args (eval.c public).
@(export)
set_context_for_expression :: proc "c" (xp: ^expand_T, arg: cstring, cmdidx: C.int) {
	context = runtime.default_context()
	got_eq := false
	cur := arg
	if cmdidx == CMD_LET_O || cmdidx == CMD_CONST_O {
		xp.xp_context = EXPAND_USER_VARS_O
		if libc.strpbrk(cur, cstring("\"'+-*/%.=!?~|&$([<>,#")) == nil {
			p := transmute(cstring)(uintptr(rawptr(cur)) + uintptr(libc.strlen(cur)))
			for uintptr(rawptr(p)) >= uintptr(rawptr(cur)) {
				xp.xp_pattern = p
				p = transmute(cstring)(mb_ptr_back(transmute(^u8)(cur), transmute(^u8)(p)))
				if ascii_iswhite(([^]u8)(p)[0]) {
					break
				}
			}
			return
		}
	} else {
		if cmdidx == CMD_CALL_O {
			xp.xp_context = EXPAND_FUNCTIONS_O
		} else {
			xp.xp_context = EXPAND_EXPRESSION_O
		}
	}
	for {
		xp.xp_pattern = transmute(cstring)(libc.strpbrk(cur, cstring("\"'+-*/%.=!?~|&$([<>,#")))
		if xp.xp_pattern == nil {
			break
		}
		c := C.int(([^]u8)(xp.xp_pattern)[0])
		if c == '&' {
			c = C.int(([^]u8)(xp.xp_pattern)[1])
			if c == '&' {
				xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 1)
				if cmdidx != CMD_LET_O || got_eq {
					xp.xp_context = EXPAND_EXPRESSION_O
				} else {
					xp.xp_context = EXPAND_NOTHING_S
				}
			} else if c != ' ' {
				xp.xp_context = EXPAND_SETTINGS_S
				if (c == 'l' || c == 'g') && ([^]u8)(xp.xp_pattern)[2] == ':' {
					xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 2)
				}
			}
		} else if c == '$' {
			xp.xp_context = EXPAND_ENV_VARS_O
		} else if c == '=' {
			got_eq = true
			xp.xp_context = EXPAND_EXPRESSION_O
		} else if c == '#' && xp.xp_context == EXPAND_EXPRESSION_O {
			break
		} else if (c == '<' || c == '#') && xp.xp_context == EXPAND_FUNCTIONS_O && vim_strchr_c(transmute(^u8)(xp.xp_pattern), C.int('(')) == nil {
			break
		} else if cmdidx != CMD_LET_O || got_eq {
			if c == '"' {
				for {
					c = C.int(([^]u8)(xp.xp_pattern)[0] + 0)
					xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 1)
					c = C.int(([^]u8)(xp.xp_pattern)[0])
					if c == 0 || c == '"' {
						break
					}
					if c == '\\' && ([^]u8)(xp.xp_pattern)[1] != 0 {
						xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 1)
					}
				}
				xp.xp_context = EXPAND_NOTHING_S
			} else if c == '\'' {
				for ([^]u8)(xp.xp_pattern)[0] != 0 && ([^]u8)(xp.xp_pattern)[0] != '\'' {
					xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 1)
				}
				xp.xp_context = EXPAND_NOTHING_S
			} else if c == '|' {
				if ([^]u8)(xp.xp_pattern)[1] == '|' {
					xp.xp_pattern = transmute(cstring)(uintptr(rawptr(xp.xp_pattern)) + 1)
					xp.xp_context = EXPAND_EXPRESSION_O
				} else {
					xp.xp_context = EXPAND_COMMANDS_O
				}
			} else {
				xp.xp_context = EXPAND_EXPRESSION_O
			}
		} else {
			xp.xp_context = EXPAND_EXPRESSION_O
		}
		cur = xp.xp_pattern
		if ([^]u8)(cur)[0] != 0 {
			cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
			for ([^]u8)(cur)[0] == ' ' || ([^]u8)(cur)[0] == 9 {
				cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
			}
		}
	}
	if cmd_has_expr_args(cmdidx) && xp.xp_context == EXPAND_EXPRESSION_O {
		for {
			n := skiptowhite(cur)
			if n == cur {
				break
			}
			nc := ([^]u8)(skipwhite(n))[0]
			if nc == 0 || nc == ' ' || nc == 9 {
				break
			}
			cur = skipwhite(n)
		}
	}
	xp.xp_pattern = cur
}

// —— Batch 28ax: eval.c var2fpos (export + weak) ——
foreign _ {
	@(link_name = "check_cursor_moved")
	check_cursor_moved_e :: proc "c" (wp: rawptr) ---
}

@(private = "file")
var2fpos_pos_g: Pos_T

// Position value reader (eval.c public).
@(export)
var2fpos :: proc "c" (tv: ^Typval_T, dollar_lnum: bool, ret_fnum: ^C.int, charcol: bool, wp: rawptr) -> rawptr {
	context = runtime.default_context()
	pos := &var2fpos_pos_g
	bp := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if tv.v_type == VAR_LIST {
		error := false
		l := rawptr(tv.vval)
		if l == nil {
			return nil
		}
		pos.lnum = C.int(tv_list_find_nr(l, 0, &error))
		if error || pos.lnum <= 0 || pos.lnum > (^C.int)(uintptr(bp) + B_ML_LINE_COUNT)^ {
			return nil
		}
		pos.col = C.int(tv_list_find_nr(l, 1, &error))
		if error {
			return nil
		}
		length: C.int = 0
		if charcol {
			length = mb_charlen_r(transmute(cstring)(ml_get_buf(bp, pos.lnum)))
		} else {
			length = ml_get_buf_len(bp, pos.lnum)
		}
		li := tv_list_find(l, 1)
		if li != nil && (^C.int)(uintptr((^Typval_T)(uintptr(li) + 16)))^ == VAR_STRING && rawptr((^Typval_T)(uintptr(li) + 16).vval) != nil && libc.strcmp(transmute(cstring)((^Typval_T)(uintptr(li) + 16).vval), cstring("$")) == 0 {
			pos.col = length + 1
		}
		if pos.col == 0 || C.int(pos.col) > length + 1 {
			return nil
		}
		pos.col -= 1
		pos.coladd = C.int(tv_list_find_nr(l, 2, &error))
		if error {
			pos.coladd = 0
		}
		return pos
	}
	name := tv_get_string_chk(tv)
	if name == nil {
		return nil
	}
	pos.lnum = 0
	if ([^]u8)(name)[0] == '.' {
		pos^ = (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
	} else if ([^]u8)(name)[0] == 'v' && ([^]u8)(name)[1] == 0 {
		if VIsual_active && wp == curwin {
			pos^ = VIsual_g
		} else {
			pos^ = (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
		}
	} else if ([^]u8)(name)[0] == '\'' {
		mname := C.int(([^]u8)(name)[1])
		fm := mark_get(bp, wp, nil, kMarkAll, mname)
		if fm == nil || (^C.int)(uintptr(fm) + 0)^ <= 0 {
			return nil
		}
		pos^ = (^Pos_T)(uintptr(fm) + 0)^
		if (mname >= 'A' && mname <= 'Z') || ascii_isdigit_o(u8(mname)) {
			ret_fnum^ = (^C.int)(uintptr(fm) + 12)^
		}
	}
	if pos.lnum != 0 {
		if charcol {
			pos.col = buf_byteidx_to_charidx(bp, pos.lnum, pos.col)
		}
		return pos
	}
	pos.coladd = 0
	if ([^]u8)(name)[0] == 'w' && dollar_lnum {
		check_cursor_moved_e(wp)
		pos.col = 0
		if ([^]u8)(name)[1] == '0' {
			update_topline_r(wp)
			top := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^
			if top > 0 {
				pos.lnum = top
			} else {
				pos.lnum = 1
			}
			return pos
		} else if ([^]u8)(name)[1] == '$' {
			validate_botline_win_r(wp)
			bot := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
			if bot > 0 {
				pos.lnum = bot - 1
			} else {
				pos.lnum = 0
			}
			return pos
		}
	} else if ([^]u8)(name)[0] == '$' {
		if dollar_lnum {
			pos.lnum = (^C.int)(uintptr(bp) + B_ML_LINE_COUNT)^
			pos.col = 0
		} else {
			pos.lnum = (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
			if charcol {
				pos.col = mb_charlen_r(transmute(cstring)(ml_get_buf(bp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)))
			} else {
				pos.col = ml_get_buf_len(bp, (^C.int)(uintptr(wp) + W_CURSOR_OFF)^)
			}
		}
		return pos
	}
	return nil
}

// —— Batch 28aw: eval.c list2fpos + set_selfdict ——

// List-to-position converter (eval.c public).
@(export)
list2fpos :: proc "c" (arg: ^Typval_T, posp: ^Pos_T, fnump: ^C.int, curswantp: ^C.int, charcol: bool) -> C.int {
	context = runtime.default_context()
	minlen: C.int = 3
	maxlen: C.int = 5
	if fnump == nil {
		minlen = 2
		maxlen = 4
	}
	llen := tv_list_len_o(rawptr(arg.vval))
	if arg.v_type != VAR_LIST || rawptr(arg.vval) == nil || llen < minlen || llen > maxlen {
		return FAIL_E
	}
	l := rawptr(arg.vval)
	i: C.int = 0
	n: C.int = 0
	if fnump != nil {
		n = C.int(tv_list_find_nr(l, i, nil))
		i += 1
		if n < 0 {
			return FAIL_E
		}
		if n == 0 {
			n = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
		}
		fnump^ = n
	}
	n = C.int(tv_list_find_nr(l, i, nil))
	i += 1
	if n < 0 {
		return FAIL_E
	}
	(^C.int)(uintptr(posp) + 0)^ = n
	n = C.int(tv_list_find_nr(l, i, nil))
	i += 1
	if n < 0 {
		return FAIL_E
	}
	if charcol {
		fnum := (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
		if fnump != nil {
			fnum = fnump^
		}
		buf := buflist_findnr(fnum)
		if buf == nil || (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
			return FAIL_E
		}
		lnum := (^C.int)(uintptr(posp) + 0)^
		if lnum == 0 {
			lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		}
		n = buf_charidx_to_byteidx(buf, lnum, n) + 1
	}
	(^C.int)(uintptr(posp) + 4)^ = n
	n = C.int(tv_list_find_nr(l, i, nil))
	if n < 0 {
		(^C.int)(uintptr(posp) + 8)^ = 0
	} else {
		(^C.int)(uintptr(posp) + 8)^ = n
	}
	if curswantp != nil {
		(^C.int)(uintptr(curswantp))^ = C.int(tv_list_find_nr(l, i + 1, nil))
	}
	return OK_E
}

// Bind dict as partial-self (eval.c public).
@(export)
set_selfdict :: proc "c" (rettv: ^Typval_T, selfdict: rawptr) {
	context = runtime.default_context()
	if rettv.v_type == VAR_PARTIAL && !(^bool)(uintptr(rawptr(rettv.vval)) + PT_AUTO_OFF_O)^ && (^rawptr)(uintptr(rawptr(rettv.vval)) + PT_DICT_OFF_O)^ != nil {
		return
	}
	make_partial(selfdict, rettv)
}

// —— Batch 28av: eval.c get_name_len + find_option_var_end ——

// Variable/function name length with brace expansion (eval.c public).
@(export)
get_name_len :: proc "c" (arg: ^cstring, alias: ^cstring, evaluate: bool, verbose: bool) -> C.int {
	context = runtime.default_context()
	alias^ = nil
	if ([^]u8)(arg^)[0] == u8(K_SPECIAL_INPUT) && ([^]u8)(arg^)[1] == u8(KS_EXTRA) && ([^]u8)(arg^)[2] == u8(KE_SNR_O) {
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 3)
		return get_id_len(arg) + 3
	}
	length := eval_fname_script(arg^)
	if length > 0 {
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + uintptr(length))
	}
	expr_start: cstring = nil
	expr_end: cstring = nil
	fne: C.int = FNE_CHECK_START_O
	if length > 0 {
		fne = 0
	}
	p := find_name_end(arg^, &expr_start, &expr_end, fne)
	if expr_start != nil {
		if !evaluate {
			length += C.int(uintptr(rawptr(p)) - uintptr(rawptr(arg^)))
			arg^ = skipwhite(p)
			return length
		}
		temp_string := make_expanded_name_o(transmute(cstring)(uintptr(rawptr(arg^)) - uintptr(length)), expr_start, expr_end, transmute(cstring)(p))
		if temp_string == nil {
			return -1
		}
		alias^ = temp_string
		arg^ = skipwhite(p)
		return C.int(libc.strlen(temp_string))
	}
	length += get_id_len(arg)
	if length == 0 && verbose && ([^]u8)(arg^)[0] != 0 {
		semsg(cstring(E15_S), arg^)
	}
	return length
}

// Option-variable name end scanner (eval.c public).
@(export)
find_option_var_end :: proc "c" (arg: ^cstring, opt_idxp: ^C.int, opt_flagsp: ^C.int) -> cstring {
	context = runtime.default_context()
	p := transmute(^u8)(arg^)
	p = transmute(^u8)(uintptr(rawptr(p)) + 1)
	if ([^]u8)(p)[0] == 'g' && ([^]u8)(p)[1] == ':' {
		opt_flagsp^ = OPT_GLOBAL_S
		p = transmute(^u8)(uintptr(rawptr(p)) + 2)
	} else if ([^]u8)(p)[0] == 'l' && ([^]u8)(p)[1] == ':' {
		opt_flagsp^ = OPT_LOCAL_S
		p = transmute(^u8)(uintptr(rawptr(p)) + 2)
	} else {
		opt_flagsp^ = 0
	}
	end := find_option_end(p, opt_idxp)
	if end == nil {
		return nil
	}
	arg^ = transmute(cstring)(p)
	return transmute(cstring)(end)
}

// —— Batch 28au: eval.c do_string_sub (export + weak) ——
foreign _ {
	@(link_name = "vim_regsub")
	vim_regsub_e :: proc "c" (rmp: ^Regmatch_T, source: cstring, expr: ^Typval_T, dest: ^u8, destlen: C.int, flags: C.int) -> C.int ---
}

// Regex substitution driver (eval.c public).
@(export)
do_string_sub :: proc "c" (str: cstring, length: C.size_t, pat: cstring, sub: cstring, expr: ^Typval_T, flags: cstring, ret_len: ^C.size_t) -> cstring {
	context = runtime.default_context()
	regmatch := Regmatch_T{}
	ga := Garray{}
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	ga_init(&ga, 1, 200)
	regmatch.rm_ic = p_ic
	regmatch.regprog = vim_regcomp(pat, RE_MAGIC + RE_STRING_O)
	if regmatch.regprog != nil {
		tail := transmute(cstring)(str)
		end := transmute(cstring)(uintptr(rawptr(str)) + uintptr(length))
		do_all := ([^]u8)(flags)[0] == 'g'
		sublen: C.int = 0
		zero_width: ^u8 = nil
		for vim_regexec_nl_e(&regmatch, str, C.int(uintptr(rawptr(tail)) - uintptr(rawptr(str)))) {
			if regmatch.startp[0] == regmatch.endp[0] {
				if zero_width == regmatch.startp[0] {
					i := C.int(utfc_ptr2len(transmute(cstring)(tail)))
					libc.memmove(rawptr(uintptr(ga.ga_data) + uintptr(ga.ga_len)), rawptr(transmute(^u8)(tail)), C.size_t(i))
					ga.ga_len += i
					tail = transmute(cstring)(uintptr(rawptr(tail)) + uintptr(i))
					continue
				}
				zero_width = regmatch.startp[0]
			}
			sublen = vim_regsub_e(&regmatch, sub, expr, transmute(^u8)(tail), 0, REGSUB_MAGIC_O)
			if sublen <= 0 {
				ga_clear(&ga)
				break
			}
			ga_grow(&ga, C.int(uintptr(rawptr(end)) - uintptr(rawptr(tail))) + sublen - C.int(uintptr(rawptr(regmatch.endp[0])) - uintptr(rawptr(regmatch.startp[0]))))
			i := C.int(uintptr(rawptr(regmatch.startp[0])) - uintptr(rawptr(tail)))
			libc.memmove(rawptr(uintptr(ga.ga_data) + uintptr(ga.ga_len)), rawptr(transmute(^u8)(tail)), C.size_t(i))
			vim_regsub_e(&regmatch, sub, expr, transmute(^u8)(uintptr(ga.ga_data) + uintptr(ga.ga_len) + uintptr(i)), sublen, REGSUB_COPY_O + REGSUB_MAGIC_O)
			ga.ga_len += i + sublen - 1
			tail = transmute(cstring)(regmatch.endp[0])
			if ([^]u8)(tail)[0] == 0 {
				break
			}
			if !do_all {
				break
			}
		}
		if ga.ga_data != nil {
			libc.strcpy(transmute([^]u8)(uintptr(ga.ga_data) + uintptr(ga.ga_len)), transmute(cstring)(tail))
			ga.ga_len += C.int(uintptr(rawptr(end)) - uintptr(rawptr(tail)))
		}
		vim_regfree(regmatch.regprog)
	}
	str_out: cstring = nil
	length_out: C.size_t = 0
	if ga.ga_data != nil {
		str_out = transmute(cstring)(ga.ga_data)
		length_out = C.size_t(ga.ga_len)
	} else {
		str_out = str
		length_out = length
	}
	ret := transmute(cstring)(xstrnsave_c(str_out, length_out))
	ga_clear(&ga)
	if p_cpo == empty_string_opt() {
		p_cpo = save_cpo
	} else {
		if ([^]u8)(p_cpo)[0] == 0 {
			set_option_value_give_err(kOptCpoptions_E, str_optval(save_cpo, libc.strlen(transmute(cstring)(save_cpo))), 0)
		}
		free_string_option(p_cpo)
	}
	if ret_len != nil {
		ret_len^ = length_out
	}
	return ret
}

// —— Batch 28at: eval.c trivial leaves (exports + weak) ——

// Name-character classifiers (eval.c public).
@(export)
eval_isnamec :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == ':' || c == '#'
}

// Name-start classifier (eval.c public).
@(export)
eval_isnamec1 :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

// Dict-key-start classifier (eval.c public).
@(export)
eval_isdictc :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

// Environment-name length scanner (eval.c public).
@(export)
get_env_len :: proc "c" (arg: ^cstring) -> C.int {
	context = runtime.default_context()
	p := arg^
	for vim_isIDc(C.int(([^]u8)(p)[0])) {
		p = transmute(cstring)(uintptr(rawptr(p)) + 1)
	}
	if p == arg^ {
		return 0
	}
	length := C.int(uintptr(rawptr(p)) - uintptr(rawptr(arg^)))
	arg^ = p
	return length
}

// Function/var-name length scanner (eval.c public).
@(export)
get_id_len :: proc "c" (arg: ^cstring) -> C.int {
	context = runtime.default_context()
	length: C.int = 0
	p := arg^
	for eval_isnamec(C.int(([^]u8)(p)[0])) {
		if ([^]u8)(p)[0] == ':' {
			length = C.int(uintptr(rawptr(p)) - uintptr(rawptr(arg^)))
			c0 := ([^]u8)(arg^)[0]
			if length > 1 || (length == 1 && c0 != 'a' && c0 != 'b' && c0 != 'g' && c0 != 'l' && c0 != 's' && c0 != 't' && c0 != 'v' && c0 != 'w') {
				break
			}
		}
		p = transmute(cstring)(uintptr(rawptr(p)) + 1)
	}
	if p == arg^ {
		return 0
	}
	length = C.int(uintptr(rawptr(p)) - uintptr(rawptr(arg^)))
	arg^ = skipwhite(p)
	return length
}

VAR_FLAVOUR_DEFAULT_O :: 1
VAR_FLAVOUR_SESSION_O :: 2
VAR_FLAVOUR_SHADA_O :: 4

// Session/shada/default flavour by case pattern (eval.c public).
@(export)
var_flavour :: proc "c" (varname: cstring) -> C.int {
	context = runtime.default_context()
	p := varname
	if ([^]u8)(p)[0] >= 'A' && ([^]u8)(p)[0] <= 'Z' {
		for {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			if ([^]u8)(p)[0] == 0 {
				break
			}
			if ([^]u8)(p)[0] >= 'a' && ([^]u8)(p)[0] <= 'z' {
				return VAR_FLAVOUR_SESSION_O
			}
		}
		return VAR_FLAVOUR_SHADA_O
	}
	return VAR_FLAVOUR_DEFAULT_O
}

// Unconditional tv-to-string (eval.c public).
@(export)
typval_tostring :: proc "c" (arg: ^Typval_T, quotes: bool) -> ^u8 {
	context = runtime.default_context()
	if arg == nil {
		return xstrdup_o(transmute(^u8)(cstring("(does not exist)")))
	}
	if !quotes && arg.v_type == VAR_STRING {
		s := transmute(cstring)(arg.vval)
		if s == nil {
			s = cstring("")
		}
		return xstrdup_o(transmute(^u8)(s))
	}
	return transmute(^u8)(encode_tv2string(arg, nil))
}

// —— Batch 28as: eval.c var_item_copy (export + weak) ——
E698_S :: "E698: Variable nested too deep for making a copy"
DICT_MAXNEST_O :: 100

@(private = "file")
var_item_copy_recurse_g: C.int

// Deep/shallow copy one typval with conversion (eval.c public).
@(export)
var_item_copy :: proc "c" (conv: rawptr, from: ^Typval_T, to: ^Typval_T, deep: bool, copyID: C.int) -> C.int {
	context = runtime.default_context()
	ret: C.int = OK_E
	if var_item_copy_recurse_g >= DICT_MAXNEST_O {
		emsg(cstring(E698_S))
		return FAIL_E
	}
	var_item_copy_recurse_g += 1
	if from.v_type == VAR_NUMBER || from.v_type == VAR_FLOAT || from.v_type == VAR_FUNC || from.v_type == VAR_PARTIAL || from.v_type == VAR_BOOL || from.v_type == VAR_SPECIAL {
		tv_copy(from, to)
	} else if from.v_type == VAR_STRING {
		if conv == nil || (^C.int)(uintptr(conv))^ == CONV_NONE_O || rawptr(from.vval) == nil {
			tv_copy(from, to)
		} else {
			to.v_type = VAR_STRING
			to.v_lock = VAR_UNLOCKED
			to.vval = transmute(rawptr)(string_convert_e(conv, transmute(cstring)(from.vval), nil))
			if rawptr(to.vval) == nil {
				to.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(from.vval)))
			}
		}
	} else if from.v_type == VAR_LIST {
		to.v_type = VAR_LIST
		to.v_lock = VAR_UNLOCKED
		if rawptr(from.vval) == nil {
			to.vval = nil
		} else if copyID != 0 && tv_list_copyid_o(rawptr(from.vval)) == copyID {
			to.vval = (^rawptr)(uintptr(rawptr(from.vval)) + 32)^
			tv_list_ref_o(rawptr(to.vval))
		} else {
			to.vval = tv_list_copy(conv, rawptr(from.vval), deep, copyID)
		}
		if rawptr(to.vval) == nil && rawptr(from.vval) != nil {
			ret = FAIL_E
		}
	} else if from.v_type == VAR_BLOB {
		tv_blob_copy(rawptr(from.vval), to)
	} else if from.v_type == VAR_DICT {
		to.v_type = VAR_DICT
		to.v_lock = VAR_UNLOCKED
		if rawptr(from.vval) == nil {
			to.vval = nil
		} else if copyID != 0 && (^C.int)(uintptr(rawptr(from.vval)) + 12)^ == copyID {
			to.vval = (^rawptr)(uintptr(rawptr(from.vval)) + 312)^
			(^C.int)(uintptr(rawptr(to.vval)) + 8)^ += 1
		} else {
			to.vval = tv_dict_copy(conv, rawptr(from.vval), deep, copyID)
		}
		if rawptr(to.vval) == nil && rawptr(from.vval) != nil {
			ret = FAIL_E
		}
	} else {
		_internal_error(cstring("var_item_copy(UNKNOWN)"))
		ret = FAIL_E
	}
	var_item_copy_recurse_g -= 1
	return ret
}

// —— Batch 28ar: eval.c fold evaluators (exports + weak) ——
KOBJTYPE_STRING_O :: 4

// Evaluate 'foldexpr' for a window (eval.c public).
@(export)
eval_foldexpr :: proc "c" (wp: rawptr, cp: ^C.int) -> C.int {
	context = runtime.default_context()
	saved_sctx := current_sctx_buf
	use_sandbox := was_set_insecurely(wp, kOptFoldexpr_E, OPT_LOCAL_S) != 0
	arg := skipwhite(transmute(cstring)((^rawptr)(uintptr(wp) + W_P_FDE)^))
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(uintptr(wp) + W_P_SCRIPT_CTX + uintptr(kWinOptFoldtext) * SCCTX_STRIDE), SCCTX_STRIDE)
	emsg_off += 1
	if use_sandbox {
		sandbox += 1
	}
	textlock += 1
	cp^ = 0
	tv := Typval_T{}
	retval: C.longlong = 0
	if eval0_simple_funccal_o(arg, &tv, nil, &EVALARG_EVALUATE_g) == FAIL_E {
		retval = 0
	} else {
		if tv.v_type == VAR_NUMBER {
			retval = transmute(C.longlong)(tv.vval)
		} else if tv.v_type != VAR_STRING || rawptr(tv.vval) == nil {
			retval = 0
		} else {
			s := transmute(cstring)(tv.vval)
			if ([^]u8)(s)[0] != 0 && !ascii_isdigit_o(([^]u8)(s)[0]) && ([^]u8)(s)[0] != '-' {
				cp^ = C.int(([^]u8)(s)[0])
				s = transmute(cstring)(uintptr(rawptr(s)) + 1)
			}
			retval = C.longlong(libc.atol(s))
		}
		tv_clear(&tv)
	}
	emsg_off -= 1
	if use_sandbox {
		sandbox -= 1
	}
	textlock -= 1
	clear_evalarg(&EVALARG_EVALUATE_g, nil)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved_sctx[0]), SCCTX_STRIDE)
	return C.int(retval)
}

// Evaluate 'foldtext' for a window (eval.c public).
@(export)
eval_foldtext :: proc "c" (wp: rawptr) -> Api_Object {
	context = runtime.default_context()
	use_sandbox := was_set_insecurely(wp, kOptFoldtext_E, OPT_LOCAL_S) != 0
	arg := (^cstring)(uintptr(wp) + W_P_FDT)^
	funccal_entry: [16]u8
	save_funccal(rawptr(&funccal_entry[0]))
	if use_sandbox {
		sandbox += 1
	}
	textlock += 1
	tv := Typval_T{}
	retval := Api_Object{}
	if eval0_simple_funccal_o(arg, &tv, nil, &EVALARG_EVALUATE_g) == FAIL_E {
		retval.t = KOBJTYPE_STRING_O
	} else {
		if tv.v_type == VAR_LIST {
			retval = vim_to_object_e(&tv, nil, false)
		} else {
			s := tv_get_string(&tv)
			cp := (^u8)(xmemdupz_o2(transmute(^u8)(s), C.size_t(libc.strlen(s))))
			retval.t = KOBJTYPE_STRING_O
			(^rawptr)(&retval.data[0])^ = rawptr(cp)
			(^C.size_t)(&retval.data[8])^ = C.size_t(libc.strlen(s))
		}
		tv_clear(&tv)
	}
	clear_evalarg(&EVALARG_EVALUATE_g, nil)
	if use_sandbox {
		sandbox -= 1
	}
	textlock -= 1
	restore_funccal()
	return retval
}

// —— Batch 28aq: eval.c system() engine ——

// Output splitter (eval.c static, dormant until engine below).
string_to_list_o :: proc "c" (str: cstring, length: C.size_t, keepempty: bool) -> rawptr {
	context = runtime.default_context()
	length := length
	if !keepempty && ([^]u8)(str)[length - 1] == NL_O {
		length -= 1
	}
	list := tv_list_alloc(KLISTLEN_MAYKNOW_O)
	encode_list_write(list, str, length)
	return list
}

// os_system wrapper with verbose/profile/shell_error handling (eval.c static).
get_system_output_as_rettv_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, retlist: bool) {
	context = runtime.default_context()
	profiling := do_profiling == PROF_YES
	rettv.v_type = VAR_STRING
	rettv.vval = nil
	if check_secure() {
		return
	}
	input_len: C.ptrdiff_t = 0
	input := save_tv_as_string((^Typval_T)(uintptr(argvars) + 16), &input_len, false, false)
	if input_len < 0 {
		return
	}
	executable := true
	argv := tv_to_argv((^Typval_T)(uintptr(argvars)), nil, &executable)
	if argv == nil {
		if !executable {
			set_vim_var_nr(VV_SHELL_ERROR, -1)
		}
		xfree(rawptr(input))
		return
	}
	if p_verbose > 3 {
		cmdstr := shell_argv_to_str(argv)
		verbose_enter_scroll_e()
		smsg(0, cstring("Executing command: \"%s\""), cmdstr)
		msg_puts(cstring("\n\n"))
		verbose_leave_scroll_e()
		xfree(rawptr(transmute(^u8)(cmdstr)))
	}
	wait_time: proftime_T = 0
	if profiling {
		prof_child_enter(&wait_time)
	}
	nread: C.size_t = 0
	res: ^u8 = nil
	status := os_system(argv, input, C.size_t(input_len), &res, &nread)
	if profiling {
		prof_child_exit(&wait_time)
	}
	xfree(rawptr(input))
	set_vim_var_nr(VV_SHELL_ERROR, C.longlong(status))
	if res == nil {
		if retlist {
			tv_list_alloc_ret(transmute(^Typval)(rettv), 0)
		} else {
			rettv.vval = transmute(rawptr)(xstrdup_o(transmute(^u8)(cstring(""))))
		}
		return
	}
	if retlist {
		keepempty: C.int = 0
		if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			keepempty = C.int(tv_get_number((^Typval_T)(uintptr(argvars) + 32)))
		}
		rettv.vval = transmute(rawptr)(string_to_list_o(transmute(cstring)(res), nread, keepempty != 0))
		tv_list_ref_o(rawptr(rettv.vval))
		rettv.v_type = VAR_LIST
		xfree(rawptr(res))
	} else {
		memchrsub(rawptr(res), C.int(0), C.int(1), nread)
		rettv.vval = transmute(rawptr)(res)
	}
}

// "system()" function (eval.c public).
@(export)
f_system :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_system_output_as_rettv_o(argvars, rettv, false)
}

// "systemlist()" function (eval.c public).
@(export)
f_systemlist :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	get_system_output_as_rettv_o(argvars, rettv, true)
}

// —— Batch 28ap: eval.c ex_echo cluster (exports + weak) ——
foreign _ {
	@(link_name = "msg_clr_eos")
	msg_clr_eos_e :: proc "c" () ---
	@(link_name = "emsg_multiline")
	emsg_multiline_e :: proc "c" (str: cstring, kind: cstring, hl_id: C.int, hist: bool) ---
	@(link_name = "force_abort")
	force_abort_g: bool
}

CMD_ECHO_O :: 135
CMD_ECHON_O :: 139
CMD_ECHOMSG_O :: 138
CMD_ECHOERR_O :: 136
CMD_EXECUTE_O :: 151
HLF_E_O :: 6
EXARG_ARG_OFF :: 0
EXARG_NEXTCMD_OFF :: 32
EXARG_GETLINE_OFF :: 168
EXARG_COOKIE_OFF :: 176

// Moved C static (single live copy; readers all ported here).
echo_hl_id_g: C.int = 0

// Moved C global (single live copy; set by get_lambda_tv analysis).
@(export)
eval_lavars_used: ^bool = nil

// ":echo[!] expr..." (eval.c public).
@(export)
ex_echo :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	rettv := Typval_T{}
	atstart := true
	need_clear := true
	did_emsg_before := did_emsg_g()
	called_emsg_before := called_emsg
	evalarg := Evalarg_T{}
	skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^
	fill_evalarg_from_eap(&evalarg, eap, skip)
	if skip {
		emsg_skip += 1
	}
	for ([^]u8)(arg)[0] != 0 && ([^]u8)(arg)[0] != '|' && ([^]u8)(arg)[0] != '\n' && !got_int {
		need_clr_eos_g = true
		p := arg
		ap := arg
		if eval1(&ap, &rettv, rawptr(&evalarg)) == FAIL_E {
			if !aborting_r() && did_emsg_g() == did_emsg_before && called_emsg == called_emsg_before {
				semsg(cstring(E15_S), p)
			}
			need_clr_eos_g = false
			break
		}
		arg = ap
		need_clr_eos_g = false
		if !skip {
			cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
			if atstart {
				atstart = false
				msg_ext_set_append(cmdidx == CMD_ECHON_O)
				msg_ext_no_fast()
				msg_ext_set_kind(cstring("echo"))
				if cmdidx == CMD_ECHO_O {
					if !msg_didout_g {
						msg_sb_eol()
					}
					msg_start()
				}
			} else if cmdidx == CMD_ECHO_O {
				msg_puts_hl_r(cstring(" "), echo_hl_id_g, false)
			}
			tofree := encode_tv2echo(&rettv, nil)
			msg_multiline(String{data = transmute(cstring)(tofree), size = libc.strlen(transmute(cstring)(tofree))}, echo_hl_id_g, true, false, &need_clear)
			xfree(rawptr(tofree))
		}
		tv_clear(&rettv)
		arg = skipwhite(arg)
	}
	(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^ = transmute(rawptr)(check_nextcmd(transmute(^u8)(arg)))
	clear_evalarg(&evalarg, eap)
	msg_ext_set_append(false)
	if skip {
		emsg_skip -= 1
	} else {
		cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
		eap_arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
		if ui_has(K_UIMESSAGES_O) && (([^]u8)(eap_arg)[0] == 0 || ([^]u8)(eap_arg)[0] == '|' || ([^]u8)(eap_arg)[0] == '\n') {
			msg_puts_len_e(cstring(""), 0, 0, false)
		} else if need_clear {
			msg_clr_eos_e()
		}
		if cmdidx == CMD_ECHO_O {
			msg_end()
		}
	}
}

// ":echohl {name}" (eval.c public).
@(export)
ex_echohl :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	echo_hl_id_g = syn_name2id_e((^cstring)(uintptr(eap) + EXARG_ARG_OFF)^)
}

// Echo highlight id accessor (eval.c public).
@(export)
get_echo_hl_id :: proc "c" () -> C.int {
	context = runtime.default_context()
	return echo_hl_id_g
}

// ":execute/echomsg/echoerr expr..." (eval.c public).
@(export)
ex_execute :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	rettv := Typval_T{}
	ret: C.int = OK_E
	ga := Garray{}
	ga_init(&ga, 1, 80)
	skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF)^
	if skip {
		emsg_skip += 1
	}
	for ([^]u8)(arg)[0] != 0 && ([^]u8)(arg)[0] != '|' && ([^]u8)(arg)[0] != '\n' {
		ap := arg
		ret = eval1_emsg_o(&ap, &rettv, eap)
		arg = ap
		if ret == FAIL_E {
			break
		}
		if !skip {
			cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
			argstr: cstring = nil
			need_free := false
			if cmdidx == CMD_EXECUTE_O {
				argstr = tv_get_string(&rettv)
			} else if rettv.v_type == VAR_STRING {
				argstr = transmute(cstring)(encode_tv2echo(&rettv, nil))
				need_free = true
			} else {
				argstr = transmute(cstring)(encode_tv2string(&rettv, nil))
				need_free = true
			}
			length := C.size_t(libc.strlen(argstr))
			ga_grow(&ga, C.int(length) + 2)
			if ga.ga_len > 0 {
				([^]u8)(ga.ga_data)[ga.ga_len] = ' '
				ga.ga_len += 1
			}
			libc.memcpy(rawptr(uintptr(ga.ga_data) + uintptr(ga.ga_len)), rawptr(transmute(^u8)(argstr)), length + 1)
			if cmdidx != CMD_EXECUTE_O {
				xfree(rawptr(transmute(^u8)(argstr)))
			}
			_ = need_free
			ga.ga_len += C.int(length)
		}
		tv_clear(&rettv)
		arg = skipwhite(arg)
	}
	if ret != FAIL_E && ga.ga_data != nil {
		cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
		if cmdidx == CMD_ECHOMSG_O {
			msg_ext_no_fast()
			msg_ext_set_kind(cstring("echomsg"))
			msg_msg(transmute(cstring)(ga.ga_data), echo_hl_id_g)
		} else if cmdidx == CMD_ECHOERR_O {
			save_did_emsg := did_emsg_g()
			msg_ext_no_fast()
			emsg_multiline_e(transmute(cstring)(ga.ga_data), cstring("echoerr"), HLF_E_O, true)
			if !force_abort_g {
				did_emsg_set(save_did_emsg != 0)
			}
		} else if cmdidx == CMD_EXECUTE_O {
			do_cmdline(transmute(cstring)(ga.ga_data), transmute(LineGetter)((^rawptr)(uintptr(eap) + EXARG_GETLINE_OFF)^), (^rawptr)(uintptr(eap) + EXARG_COOKIE_OFF)^, DOCMD_NOWAIT_O | DOCMD_VERBOSE_O)
		}
	}
	ga_clear(&ga)
	if skip {
		emsg_skip -= 1
	}
	(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF)^ = transmute(rawptr)(check_nextcmd(transmute(^u8)(arg)))
}

// —— Batch 28an: eval.c GC-marking cluster ——

// Explicit GC stacks (typval_defs.h:374): 16B each.
PT_COPYID_OFF_O :: 4
Ht_Stack_O :: struct {
	ht:   rawptr, // hashtab_T*
	prev: rawptr, // ^Ht_Stack_O
}
List_Stack_O :: struct {
	list: rawptr, // list_T*
	prev: rawptr, // ^List_Stack_O
}

// Mark hashtab contents (eval.c public).
@(export)
set_ref_in_ht :: proc "c" (ht: rawptr, copyID: C.int, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	abort := false
	ht_stack: rawptr = nil
	cur_ht := ht
	for {
		if !abort {
			todo := (^C.size_t)(uintptr(cur_ht) + 8)^
			hi := uintptr((^rawptr)(uintptr(cur_ht) + 32)^)
			for todo > 0 {
				k := ([^]rawptr)(hi)[1]
				hi += 16
				if k == nil || k == rawptr(&hash_removed) {
					continue
				}
				todo -= 1
				if set_ref_in_item((^Typval_T)(uintptr(k) - 17), copyID, rawptr(&ht_stack), list_stack) {
					abort = true
				}
			}
		}
		if ht_stack == nil {
			break
		}
		cur_ht = (^Ht_Stack_O)(ht_stack).ht
		temp := ht_stack
		ht_stack = (^Ht_Stack_O)(ht_stack).prev
		xfree(temp)
	}
	return abort
}

// Mark list contents (eval.c public).
@(export)
set_ref_in_list_items :: proc "c" (l: rawptr, copyID: C.int, ht_stack: rawptr) -> bool {
	context = runtime.default_context()
	abort := false
	list_stack: rawptr = nil
	cur_l := l
	for {
		li := tv_list_first_o(cur_l)
		for li != nil {
			if abort {
				break
			}
			if set_ref_in_item((^Typval_T)(uintptr(li) + 16), copyID, ht_stack, rawptr(&list_stack)) {
				abort = true
			}
			li = (^rawptr)(uintptr(li))^
		}
		if list_stack == nil {
			break
		}
		cur_l = (^List_Stack_O)(list_stack).list
		temp := list_stack
		list_stack = (^List_Stack_O)(list_stack).prev
		xfree(temp)
	}
	return abort
}

// Mark one dict (eval.c static, dormant until set_ref_in_item).
set_ref_in_item_dict_o :: proc "c" (dd: rawptr, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if dd == nil || (^C.int)(uintptr(dd) + DV_COPYID_OFF)^ == copyID {
		return false
	}
	(^C.int)(uintptr(dd) + DV_COPYID_OFF)^ = copyID
	if ht_stack == nil {
		return set_ref_in_ht(rawptr(uintptr(dd) + 16), copyID, list_stack)
	}
	newitem := (^Ht_Stack_O)(xmalloc(C.size_t(size_of(Ht_Stack_O))))
	newitem.ht = rawptr(uintptr(dd) + 16)
	newitem.prev = (^rawptr)(ht_stack)^
	(^rawptr)(ht_stack)^ = newitem
	head := uintptr(dd) + DV_WATCHERS_OFF
	w := (^rawptr)(head)^
	for w != rawptr(head) {
		next := (^rawptr)(uintptr(w))^
		watcher := rawptr(uintptr(w) - 32)
		set_ref_in_callback((^Callback_E)(watcher), copyID, ht_stack, list_stack)
		w = next
	}
	return false
}

// Mark one list (eval.c static, dormant until set_ref_in_item).
set_ref_in_item_list_o :: proc "c" (ll: rawptr, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if ll == nil || (^C.int)(uintptr(ll) + 68)^ == copyID {
		return false
	}
	(^C.int)(uintptr(ll) + 68)^ = copyID
	if list_stack == nil {
		return set_ref_in_list_items(ll, copyID, ht_stack)
	}
	newitem := (^List_Stack_O)(xmalloc(C.size_t(size_of(List_Stack_O))))
	newitem.list = ll
	newitem.prev = (^rawptr)(list_stack)^
	(^rawptr)(list_stack)^ = newitem
	return false
}

// Mark one partial (eval.c static, dormant until set_ref_in_item).
set_ref_in_item_partial_o :: proc "c" (pt: rawptr, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if pt == nil || (^C.int)(uintptr(pt) + PT_COPYID_OFF_O)^ == copyID {
		return false
	}
	(^C.int)(uintptr(pt) + PT_COPYID_OFF_O)^ = copyID
	abort := set_ref_in_func(transmute(cstring)((^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^), (^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^, copyID)
	if (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ != nil {
		dtv := Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = (^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^}
		if set_ref_in_item(&dtv, copyID, ht_stack, list_stack) {
			abort = true
		}
	}
	i: C.int = 0
	for i < (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ {
		if set_ref_in_item((^Typval_T)(uintptr((^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), copyID, ht_stack, list_stack) {
			abort = true
		}
		i += 1
	}
	return abort
}

// Mark one typval's references (eval.c public).
@(export)
set_ref_in_item :: proc "c" (tv: ^Typval_T, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if tv.v_type == VAR_DICT {
		return set_ref_in_item_dict_o(rawptr(tv.vval), copyID, ht_stack, list_stack)
	} else if tv.v_type == VAR_LIST {
		return set_ref_in_item_list_o(rawptr(tv.vval), copyID, ht_stack, list_stack)
	} else if tv.v_type == VAR_FUNC {
		return set_ref_in_func(transmute(cstring)(tv.vval), nil, copyID)
	} else if tv.v_type == VAR_PARTIAL {
		return set_ref_in_item_partial_o(rawptr(tv.vval), copyID, ht_stack, list_stack)
	}
	return false
}

// Mark one callback's references (eval.c public).
@(export)
set_ref_in_callback :: proc "c" (callback: ^Callback_E, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if callback.type == KCB_PARTIAL_O {
		tv := Typval_T{v_type = VAR_PARTIAL, v_lock = VAR_UNLOCKED, vval = (^rawptr)(uintptr(callback))^}
		return set_ref_in_item(&tv, copyID, ht_stack, list_stack)
	} else if callback.type == KCB_LUA_O {
		libc.abort()
	}
	return false
}

// Reader-callback variant (eval.c static, dormant until channel GC ports).
set_ref_in_callback_reader_o :: proc "c" (reader: rawptr, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool {
	context = runtime.default_context()
	if set_ref_in_callback((^Callback_E)(reader), copyID, ht_stack, list_stack) {
		return true
	}
	if (^rawptr)(uintptr(reader) + 16)^ != nil {
		tv := Typval_T{v_type = VAR_DICT, v_lock = VAR_UNLOCKED, vval = (^rawptr)(uintptr(reader) + 16)^}
		return set_ref_in_item(&tv, copyID, ht_stack, list_stack)
	}
	return false
}

// —— Batch 28ao: eval.c callback_call + depth (exports + weak) ——
foreign _ {
	@(link_name = "nlua_call_ref")
	nlua_call_ref_e :: proc "c" (ref: C.int, name: cstring, args: Api_Array, mode: C.int, arena: rawptr, err: rawptr) -> Api_Object ---
}

E169_S :: "E169: Command too recursive"
KRETNILBOOL_O :: 1
KOBJTYPE_BOOL_O :: 1

// Moved C static (single live copy; C twin dies with the weak).
callback_depth_g: C.int = 0

// Callback-nesting depth (eval.c public).
@(export)
get_callback_depth :: proc "c" () -> C.int {
	context = runtime.default_context()
	return callback_depth_g
}

// Invoke a Callback value (eval.c public).
@(export)
callback_call :: proc "c" (callback: rawptr, argcount_in: C.int, argvars_in: ^Typval_T, rettv: ^Typval_T) -> bool {
	context = runtime.default_context()
	cb := (^Callback_E)(callback)
	if C.longlong(callback_depth_g) > p_mfd_g {
		emsg(cstring(E169_S))
		return false
	}
	partial: rawptr = nil
	name: cstring = nil
	args := Api_Array{}
	if cb.type == KCB_FUNCREF_O {
		name = transmute(cstring)((^rawptr)(uintptr(callback))^)
		length := C.int(libc.strlen(name))
		if length >= 6 && libc.memcmp(rawptr(transmute(^u8)(name)), rawptr(transmute(^u8)(cstring("v:lua."))), 6) == 0 {
			name = transmute(cstring)(uintptr(rawptr(name)) + 6)
			length = check_luafunc_name(name, false)
			if length == 0 {
				return false
			}
			partial = get_vim_var_partial(VV_LUA_O)
		}
	} else if cb.type == KCB_PARTIAL_O {
		partial = (^rawptr)(uintptr(callback))^
		name = partial_name(partial)
	} else if cb.type == KCB_LUA_O {
		rv := nlua_call_ref_e(C.int((^i64)(uintptr(callback))^), nil, args, KRETNILBOOL_O, nil, nil)
		return rv.t == KOBJTYPE_BOOL_O && (^bool)(&rv.data[0])^
	} else {
		return false
	}
	fe := Funcexe_T{}
	fe.firstline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.lastline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.evaluate = true
	fe.partial = partial
	callback_depth_g += 1
	ret := call_func(name, -1, rettv, argcount_in, argvars_in, &fe)
	callback_depth_g -= 1
	return ret != 0
}

// —— Batch 28ak: eval.c set_var_lval (export + weak) ——
E996_RANGE_S :: "E996: Cannot lock a range"
E996_LISTDICT_S :: "E996: Cannot lock a list or dict"
TV_CSTRING_O :: max(C.size_t) - 1

// Assign through a parsed lval (eval.c public).
@(export)
set_var_lval :: proc "c" (lp: rawptr, endp: cstring, rettv: ^Typval_T, copy: bool, is_const: bool, op: cstring) {
	context = runtime.default_context()
	di: rawptr = nil
	ll_tv := (^rawptr)(uintptr(lp) + LL_TV_OFF_O)^
	if ll_tv == nil {
		cc := ([^]u8)(endp)[0]
		([^]u8)(endp)[0] = 0
		ll_blob := (^rawptr)(uintptr(lp) + LL_BLOB_OFF_O)^
		if ll_blob != nil {
			if op != nil && ([^]u8)(op)[0] != '=' {
				semsg(cstring(E_LETWRONG_S), op)
				return
			}
			if value_check_lock((^C.int)(uintptr(ll_blob) + 28)^, transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), TV_CSTRING_O) {
				return
			}
			if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ && rettv.v_type == VAR_BLOB {
				if (^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^ {
					(^C.int)(uintptr(lp) + LL_N2_OFF_O)^ = tv_blob_len_o(ll_blob) - 1
				}
				if tv_blob_set_range(ll_blob, C.longlong((^C.int)(uintptr(lp) + LL_N1_OFF_O)^), C.longlong((^C.int)(uintptr(lp) + LL_N2_OFF_O)^), rettv) == FAIL_E {
					return
				}
			} else {
				error := false
				val := tv_get_number_chk(rettv, &error)
				if !error {
					if val < 0 || val > 255 {
						semsg(cstring(E_BLOBVAL_S), val)
					} else {
						tv_blob_set_append(ll_blob, (^C.int)(uintptr(lp) + LL_N1_OFF_O)^, u8(val))
					}
				}
			}
		} else if op != nil && ([^]u8)(op)[0] != '=' {
			tv := Typval_T{}
			if is_const {
				emsg(cstring(E995_S))
				([^]u8)(endp)[0] = cc
				return
			}
			di = nil
			if eval_variable(transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), C.int((^C.size_t)(uintptr(lp) + 8)^), &tv, rawptr(&di), true, false) == OK_E {
				di_ok := di == nil
				ro_ok := true
				lock_ok := true
				if di != nil {
					ro_ok = !var_check_ro(C.int((^u8)(uintptr(di) + 16)^), transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), TV_CSTRING_O)
					lock_ok = !tv_check_lock((^Typval_T)(uintptr(di)), transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), TV_CSTRING_O)
				}
				if (di_ok || (ro_ok && lock_ok)) && eexe_mod_op(&tv, rettv, op) == OK_E {
					set_var(transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), (^C.size_t)(uintptr(lp) + 8)^, &tv, false)
				}
				tv_clear(&tv)
			}
		} else {
			set_var_const(transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), (^C.size_t)(uintptr(lp) + 8)^, rettv, copy, is_const)
		}
		([^]u8)(endp)[0] = cc
		return
	}
	lock_v: C.int = 0
	if (^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^ == nil {
		lock_v = (^C.int)(uintptr(ll_tv) + 4)^
	} else {
		lock_v = (^C.int)(uintptr((^rawptr)(uintptr(ll_tv) + 8)^))^
	}
	if value_check_lock(lock_v, transmute(cstring)((^rawptr)(uintptr(lp) + 0)^), TV_CSTRING_O) {
		return
	}
	if (^bool)(uintptr(lp) + LL_RANGE_OFF_O)^ {
		if is_const {
			emsg(cstring(E996_RANGE_S))
			return
		}
		tv_list_assign_range((^rawptr)(uintptr(lp) + LL_LIST_OFF_O)^, rawptr(rettv.vval), (^C.int)(uintptr(lp) + LL_N1_OFF_O)^, (^C.int)(uintptr(lp) + LL_N2_OFF_O)^, (^bool)(uintptr(lp) + LL_RANGE_OFF_O + 1)^, op, transmute(cstring)((^rawptr)(uintptr(lp) + 0)^))
		return
	}
	oldtv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	dict := (^rawptr)(uintptr(lp) + LL_DICT_OFF_O)^
	watched := tv_dict_is_watched_o(dict)
	if is_const {
		emsg(cstring(E996_LISTDICT_S))
		return
	}
	if (^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^ != nil {
		if op != nil && ([^]u8)(op)[0] != '=' {
			semsg(cstring(E716_S), transmute(cstring)((^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^))
			return
		}
		if tv_dict_wrong_func_name((^rawptr)(uintptr(ll_tv) + 8)^, rettv, transmute(cstring)((^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^)) != 0 {
			return
		}
		di = tv_dict_item_alloc(transmute(cstring)((^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^))
		if tv_dict_add((^rawptr)(uintptr(ll_tv) + 8)^, di) == FAIL_E {
			xfree(di)
			return
		}
		(^rawptr)(uintptr(lp) + LL_TV_OFF_O)^ = rawptr(uintptr(di))
		ll_tv = rawptr(uintptr(di))
		if copy {
			tv_copy(rettv, (^Typval_T)(ll_tv))
		} else {
			(^Typval_T)(ll_tv)^ = rettv^
			(^Typval_T)(ll_tv).v_lock = VAR_UNLOCKED
			tv_init_o(rettv)
		}
	} else {
		if watched {
			tv_copy((^Typval_T)(ll_tv), &oldtv)
		}
		if op != nil && ([^]u8)(op)[0] != '=' {
			eexe_mod_op((^Typval_T)(ll_tv), rettv, op)
		} else {
			tv_clear((^Typval_T)(ll_tv))
			if copy {
				tv_copy(rettv, (^Typval_T)(ll_tv))
			} else {
				(^Typval_T)(ll_tv)^ = rettv^
				(^Typval_T)(ll_tv).v_lock = VAR_UNLOCKED
				tv_init_o(rettv)
			}
		}
	}
	if watched {
		if oldtv.v_type == VAR_UNKNOWN {
			tv_dict_watcher_notify(dict, transmute(cstring)((^rawptr)(uintptr(lp) + LL_NEWKEY_OFF_O)^), (^Typval_T)(ll_tv), nil)
		} else {
			di_ := (^rawptr)(uintptr(lp) + LL_DI_OFF_O)^
			tv_dict_watcher_notify(dict, transmute(cstring)(rawptr(uintptr(di_) + 17)), (^Typval_T)(ll_tv), &oldtv)
			tv_clear(&oldtv)
		}
	}
}

// —— Batch 28am: eval.c timer core (exports + weak) ——
foreign _ {
	@(link_name = "discard_current_exception")
	discard_current_exception_e :: proc "c" () ---
}

// Timer_T mirror (eval.h:106): 240B cc-probed.
Timer_T :: struct {
	tw:           TimeWatcher, // 0..192
	timer_id:     C.int,       // 192
	repeat_count: C.int,       // 196
	refcount:     C.int,       // 200
	emsg_count:   C.int,       // 204
	timeout:      i64,         // 208
	stopped:      bool,        // 216
	paused:       bool,        // 217
	_pad:         [6]u8,
	callback:     Callback_E,  // 224..240
}
#assert(size_of(Timer_T) == 240)

// Moved C statics (single live copies; C twins go dead with the weaks).
timers_g: PMap_uint64_t
last_timer_id_g: u64 = 1

// Timer lookup by id (eval.c public).
@(export)
find_timer_by_nr :: proc "c" (xx: C.longlong) -> rawptr {
	context = runtime.default_context()
	k := mh_get_uint64_t(&timers_g.set, u64(xx))
	if k == MH_TOMBSTONE {
		return nil
	}
	return timers_g.values[k]
}

// Single-timer info dict (eval.c public).
@(export)
add_timer_info :: proc "c" (rettv: ^Typval_T, timer: rawptr) {
	context = runtime.default_context()
	t := (^Timer_T)(timer)
	l := rawptr((^Typval_T)(rettv).vval)
	d := tv_dict_alloc()
	tv_list_append_dict(l, d)
	tv_dict_add_nr(d, cstring("id"), 2, C.longlong(t.timer_id))
	tv_dict_add_nr(d, cstring("time"), 4, C.longlong(t.timeout))
	paused: C.longlong = 0
	if t.paused {
		paused = 1
	}
	tv_dict_add_nr(d, cstring("paused"), 6, paused)
	rep: C.longlong = C.longlong(t.repeat_count)
	if t.repeat_count < 0 {
		rep = -1
	}
	tv_dict_add_nr(d, cstring("repeat"), 6, rep)
	di := tv_dict_item_alloc(cstring("callback"))
	if tv_dict_add(d, di) == FAIL_E {
		xfree(di)
		return
	}
	callback_put(&t.callback, (^Typval_T)(uintptr(di)))
}

// All-timer info list (eval.c public).
@(export)
add_timer_info_all :: proc "c" (rettv: ^Typval_T) {
	context = runtime.default_context()
	tv_list_alloc_ret(transmute(^Typval)(rettv), C.int(timers_g.set.h.size))
	i: u32 = 0
	for i < timers_g.set.h.n_buckets {
		if !mh_is_empty(&timers_g.set.h, i) && !mh_is_del(&timers_g.set.h, i) {
			timer := timers_g.values[timers_g.set.h.hash[i] - 1]
			t := (^Timer_T)(timer)
			if !t.stopped || t.refcount > 1 {
				add_timer_info(rettv, timer)
			}
		}
		i += 1
	}
}

// Timer fire handler, runs on the main loop (eval.c public).
@(export)
timer_due_cb :: proc "c" (tw: ^TimeWatcher, data: rawptr) {
	context = runtime.default_context()
	timer := (^Timer_T)(data)
	save_did_emsg := did_emsg_g()
	called_emsg_before := called_emsg
	save_ex_pressedreturn := get_pressedreturn()
	if timer.stopped || timer.paused {
		return
	}
	timer.refcount += 1
	if timer.repeat_count >= 0 {
		timer.repeat_count -= 1
		if timer.repeat_count == 0 {
			timer_stop(timer)
		}
	}
	argv := [2]Typval_T{Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}, Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}}
	argv[0].v_type = VAR_NUMBER
	argv[0].vval = transmute(rawptr)(C.longlong(timer.timer_id))
	rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	callback_call(rawptr(&timer.callback), 1, &argv[0], &rettv)
	if called_emsg > called_emsg_before && did_emsg_g() != 0 {
		timer.emsg_count += 1
		if did_throw_g {
			discard_current_exception_e()
		}
	}
	did_emsg_set(save_did_emsg != 0)
	set_pressedreturn(save_ex_pressedreturn)
	if timer.emsg_count >= 3 {
		timer_stop(timer)
	}
	tv_clear(&rettv)
	if !timer.stopped && timer.timeout == 0 {
		time_watcher_start(&timer.tw, timer_due_cb, 0, 0)
	}
	timer_decref_o(timer)
}

// Timer close handler: free queue + callback + map slot (eval.c static).
timer_close_cb_o :: proc "c" (tw: ^TimeWatcher, data: rawptr) {
	context = runtime.default_context()
	timer := (^Timer_T)(data)
	multiqueue_free(timer.tw.events)
	callback_free(&timer.callback)
	map_del_uint64_t_ptr_t(&timers_g, u64(timer.timer_id), nil)
	timer_decref_o(timer)
}

// Timer refcount release (eval.c static).
timer_decref_o :: proc "c" (timer: ^Timer_T) {
	context = runtime.default_context()
	timer.refcount -= 1
	if timer.refcount == 0 {
		xfree(timer)
	}
}

// Create + start a timer (eval.c public).
@(export)
timer_start :: proc "c" (timeout: i64, repeat_count: C.int, callback: ^Callback_E) -> u64 {
	context = runtime.default_context()
	timer := (^Timer_T)(xmalloc(C.size_t(size_of(Timer_T))))
	timer.refcount = 1
	timer.stopped = false
	timer.paused = false
	timer.emsg_count = 0
	timer.repeat_count = repeat_count
	timer.timeout = timeout
	timer.timer_id = C.int(last_timer_id_g)
	last_timer_id_g += 1
	timer.callback = callback^
	time_watcher_init(&main_loop, &timer.tw, timer)
	timer.tw.events = multiqueue_new_child(main_loop.events)
	timer.tw.blockable = true
	time_watcher_start(&timer.tw, timer_due_cb, u64(timeout), u64(timeout))
	new_item := false
	slot := map_put_ref_uint64_t_ptr_t(&timers_g, u64(timer.timer_id), nil, &new_item)
	slot^ = timer
	return u64(timer.timer_id)
}

// Stop a timer (eval.c public).
@(export)
timer_stop :: proc "c" (timer: rawptr) {
	context = runtime.default_context()
	t := (^Timer_T)(timer)
	if t.stopped {
		return
	}
	t.stopped = true
	time_watcher_stop(&t.tw)
	time_watcher_close(&t.tw, timer_close_cb_o)
}

// Stop every timer (eval.c public).
@(export)
timer_stop_all :: proc "c" () {
	context = runtime.default_context()
	i: u32 = 0
	for i < timers_g.set.h.n_buckets {
		if !mh_is_empty(&timers_g.set.h, i) && !mh_is_del(&timers_g.set.h, i) {
			timer_stop(timers_g.values[timers_g.set.h.hash[i] - 1])
		}
		i += 1
	}
}

// Teardown all timers at exit (eval.c public).
@(export)
timer_teardown :: proc "c" () {
	context = runtime.default_context()
	timer_stop_all()
}

// —— Batch 28af: eval.c for-loop cluster (exports + weak) ——
E690_S :: "E690: Missing \"in\" after :for"

// Forinfo_T mirror (eval.c:122): 64B cc-probed.
Forinfo_T :: struct {
	fi_semicolon: C.int,    // 0
	fi_varcount:  C.int,    // 4
	fi_lw_item:   rawptr,   // 8 (listwatch_T: item@0)
	fi_lw_next:   rawptr,   // 16 (listwatch_T: next@8)
	fi_list:      rawptr,   // 24
	fi_bi:        C.int,    // 32
	_pad36:       [4]u8,
	fi_blob:      rawptr,   // 40
	fi_string:    cstring,  // 48
	fi_byte_idx:  C.int,    // 56
	_pad60:       [4]u8,
}
#assert(size_of(Forinfo_T) == 64)

// Parse ":for vars in expr" header (eval.c public).
@(export)
eval_for_line :: proc "c" (arg: cstring, errp: ^bool, eap: rawptr, evalarg: rawptr) -> rawptr {
	context = runtime.default_context()
	fi := (^Forinfo_T)(xcalloc(1, C.size_t(size_of(Forinfo_T))))
	tv := Typval_T{}
	l: rawptr = nil
	skip := ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) == 0
	errp^ = true
	expr := skip_var_list(arg, &fi.fi_varcount, &fi.fi_semicolon, false)
	if expr == nil {
		return fi
	}
	expr = skipwhite(expr)
	if ([^]u8)(expr)[0] != 'i' || ([^]u8)(expr)[1] != 'n' || (([^]u8)(expr)[2] != 0 && !ascii_iswhite(([^]u8)(expr)[2])) {
		emsg(cstring(E690_S))
		return fi
	}
	if skip {
		emsg_skip += 1
	}
	expr = skipwhite(transmute(cstring)(uintptr(rawptr(expr)) + 2))
	if eval0(transmute(cstring)(expr), &tv, eap, evalarg) == OK_E {
		errp^ = false
		if !skip {
			if tv.v_type == VAR_LIST {
				l = rawptr(tv.vval)
				if l == nil {
					tv_clear(&tv)
				} else {
					fi.fi_list = l
					tv_list_watch_add(l, rawptr(uintptr(fi) + 8))
					(^rawptr)(uintptr(fi) + 8)^ = tv_list_first_o(l)
				}
			} else if tv.v_type == VAR_BLOB {
				fi.fi_bi = 0
				if rawptr(tv.vval) != nil {
					btv := Typval_T{}
					tv_blob_copy(rawptr(tv.vval), &btv)
					fi.fi_blob = rawptr(btv.vval)
				}
				tv_clear(&tv)
			} else if tv.v_type == VAR_STRING {
				fi.fi_byte_idx = 0
				fi.fi_string = transmute(cstring)(tv.vval)
				tv.vval = nil
				if fi.fi_string == nil {
					fi.fi_string = transmute(cstring)(xstrdup_o(transmute(^u8)(cstring(""))))
				}
			} else {
				emsg(cstring(E1098_S))
				tv_clear(&tv)
			}
		}
	}
	if skip {
		emsg_skip -= 1
	}
	return fi
}

// Advance a ":for" iteration (eval.c public).
@(export)
next_for_item :: proc "c" (fi_void: rawptr, arg: cstring) -> bool {
	context = runtime.default_context()
	fi := (^Forinfo_T)(fi_void)
	if fi.fi_blob != nil {
		if fi.fi_bi >= tv_blob_len_o(fi.fi_blob) {
			return false
		}
		tv := Typval_T{v_type = VAR_NUMBER, v_lock = VAR_FIXED_O}
		tv.vval = transmute(rawptr)(C.longlong(tv_blob_get_o(fi.fi_blob, fi.fi_bi)))
		fi.fi_bi += 1
		return ex_let_vars(arg, &tv, 1, fi.fi_semicolon, fi.fi_varcount, false, nil) == OK_E
	}
	if fi.fi_string != nil {
		length := utfc_ptr2len(transmute(cstring)(rawptr(uintptr(rawptr(fi.fi_string)) + uintptr(fi.fi_byte_idx))))
		if length == 0 {
			return false
		}
		tv := Typval_T{v_type = VAR_STRING, v_lock = VAR_FIXED_O}
		tv.vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(rawptr(uintptr(rawptr(fi.fi_string)) + uintptr(fi.fi_byte_idx))), C.size_t(length)))
		fi.fi_byte_idx += length
		result := ex_let_vars(arg, &tv, 1, fi.fi_semicolon, fi.fi_varcount, false, nil) == OK_E
		xfree(rawptr(transmute(^u8)(tv.vval)))
		return result
	}
	item := fi.fi_lw_item
	if item == nil {
		return false
	}
	fi.fi_lw_item = (^rawptr)(uintptr(item))^
	return ex_let_vars(arg, (^Typval_T)(uintptr(item) + 16), 1, fi.fi_semicolon, fi.fi_varcount, false, nil) == OK_E
}

// Free ":for" iteration state (eval.c public).
@(export)
free_for_info :: proc "c" (fi_void: rawptr) {
	context = runtime.default_context()
	fi := (^Forinfo_T)(fi_void)
	if fi == nil {
		return
	}
	if fi.fi_list != nil {
		tv_list_watch_remove(fi.fi_list, rawptr(uintptr(fi) + 8))
		tv_list_unref(fi.fi_list)
	} else if fi.fi_blob != nil {
		tv_blob_unref(fi.fi_blob)
	} else {
		xfree(rawptr(transmute(^u8)(fi.fi_string)))
	}
	xfree(fi)
}

// —— Batch 28aa: eval.c eval3 (dormant plain, C-static) ——

// Logical-AND chain (eval.c static, activates eval2).
eval3_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	if eval4_o(arg, rettv, evalarg) == FAIL_E {
		return FAIL_E
	}
	p := arg^
	if ([^]u8)(p)[0] == '&' && ([^]u8)(p)[1] == '&' {
		evalarg_used: ^Evalarg_T = nil
		local_evalarg := Evalarg_T{}
		if evalarg == nil {
			evalarg_used = &local_evalarg
		} else {
			evalarg_used = (^Evalarg_T)(evalarg)
		}
		orig_flags := evalarg_used.eval_flags
		evaluate := (evalarg_used.eval_flags & EVAL_EVALUATE_O) != 0
		result := true
		if evaluate {
			error := false
			if tv_get_number_chk(rettv, &error) == 0 {
				result = false
			}
			tv_clear(rettv)
			if error {
				return FAIL_E
			}
		}
		for ([^]u8)(p)[0] == '&' && ([^]u8)(p)[1] == '&' {
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 2))
			if result {
				evalarg_used.eval_flags = orig_flags
			} else {
				evalarg_used.eval_flags = orig_flags & ~C.int(1)
			}
			var2 := Typval_T{}
			if eval4_o(arg, &var2, rawptr(evalarg_used)) == FAIL_E {
				return FAIL_E
			}
			if evaluate && result {
				error := false
				if tv_get_number_chk(&var2, &error) == 0 {
					result = false
				}
				tv_clear(&var2)
				if error {
					return FAIL_E
				}
			}
			if evaluate {
				rettv.v_type = VAR_NUMBER
				if result {
					rettv.vval = transmute(rawptr)(C.longlong(1))
				} else {
					rettv.vval = transmute(rawptr)(C.longlong(0))
				}
			}
			p = arg^
		}
		if evalarg == nil {
			clear_evalarg(&local_evalarg, nil)
		} else {
			(^Evalarg_T)(evalarg).eval_flags = orig_flags
		}
	}
	return OK_E
}

// —— Batch 28ab: eval.c eval2 (dormant plain, C-static) ——

// Logical-OR chain (eval.c static, activates eval1).
eval2_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	if eval3_o(arg, rettv, evalarg) == FAIL_E {
		return FAIL_E
	}
	p := arg^
	if ([^]u8)(p)[0] == '|' && ([^]u8)(p)[1] == '|' {
		evalarg_used: ^Evalarg_T = nil
		local_evalarg := Evalarg_T{}
		if evalarg == nil {
			evalarg_used = &local_evalarg
		} else {
			evalarg_used = (^Evalarg_T)(evalarg)
		}
		orig_flags := evalarg_used.eval_flags
		evaluate := (evalarg_used.eval_flags & EVAL_EVALUATE_O) != 0
		result := false
		if evaluate {
			error := false
			if tv_get_number_chk(rettv, &error) != 0 {
				result = true
			}
			tv_clear(rettv)
			if error {
				return FAIL_E
			}
		}
		for ([^]u8)(p)[0] == '|' && ([^]u8)(p)[1] == '|' {
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 2))
			if !result {
				evalarg_used.eval_flags = orig_flags
			} else {
				evalarg_used.eval_flags = orig_flags & ~C.int(1)
			}
			var2 := Typval_T{}
			if eval3_o(arg, &var2, rawptr(evalarg_used)) == FAIL_E {
				return FAIL_E
			}
			if evaluate && !result {
				error := false
				if tv_get_number_chk(&var2, &error) != 0 {
					result = true
				}
				tv_clear(&var2)
				if error {
					return FAIL_E
				}
			}
			if evaluate {
				rettv.v_type = VAR_NUMBER
				if result {
					rettv.vval = transmute(rawptr)(C.longlong(1))
				} else {
					rettv.vval = transmute(rawptr)(C.longlong(0))
				}
			}
			p = arg^
		}
		if evalarg == nil {
			clear_evalarg(&local_evalarg, nil)
		} else {
			(^Evalarg_T)(evalarg).eval_flags = orig_flags
		}
	}
	return OK_E
}

// —— Batch 28ac: eval.c eval1 (export + weak, full chain Odin) ——

// Ternary/?? top-level expression (eval.c public).
@(export)
eval1 :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	rettv^ = Typval_T{}
	if eval2_o(arg, rettv, evalarg) == FAIL_E {
		return FAIL_E
	}
	p := arg^
	if ([^]u8)(p)[0] == '?' {
		op_falsy := ([^]u8)(p)[1] == '?'
		evalarg_used: ^Evalarg_T = nil
		local_evalarg := Evalarg_T{}
		if evalarg == nil {
			evalarg_used = &local_evalarg
		} else {
			evalarg_used = (^Evalarg_T)(evalarg)
		}
		orig_flags := evalarg_used.eval_flags
		evaluate := (evalarg_used.eval_flags & EVAL_EVALUATE_O) != 0
		result := false
		if evaluate {
			error := false
			if op_falsy {
				result = tv2bool(rettv)
			} else if tv_get_number_chk(rettv, &error) != 0 {
				result = true
			}
			if error || !op_falsy || !result {
				tv_clear(rettv)
			}
			if error {
				return FAIL_E
			}
		}
		if op_falsy {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		}
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		take_branch := false
		if op_falsy {
			take_branch = !result
		} else {
			take_branch = result
		}
		if take_branch {
			evalarg_used.eval_flags = orig_flags
		} else {
			evalarg_used.eval_flags = orig_flags & ~C.int(1)
		}
		var2 := Typval_T{}
		if eval1(arg, &var2, rawptr(evalarg_used)) == FAIL_E {
			evalarg_used.eval_flags = orig_flags
			return FAIL_E
		}
		if !op_falsy || !result {
			rettv^ = var2
		}
		if !op_falsy {
			p = arg^
			if ([^]u8)(p)[0] != ':' {
				emsg(cstring(E109_S))
				if evaluate && result {
					tv_clear(rettv)
				}
				evalarg_used.eval_flags = orig_flags
				return FAIL_E
			}
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
			if !result {
				evalarg_used.eval_flags = orig_flags
			} else {
				evalarg_used.eval_flags = orig_flags & ~C.int(1)
			}
			if eval1(arg, &var2, rawptr(evalarg_used)) == FAIL_E {
				if evaluate && result {
					tv_clear(rettv)
				}
				evalarg_used.eval_flags = orig_flags
				return FAIL_E
			}
			if evaluate && !result {
				rettv^ = var2
			}
		}
		if evalarg == nil {
			clear_evalarg(&local_evalarg, nil)
		} else {
			(^Evalarg_T)(evalarg).eval_flags = orig_flags
		}
	}
	return OK_E
}

// —— Batch 28x: eval.c multdiv + eval6 (dormant plains, C-statics) ——
E804_S :: "E804: Cannot use '%' with Float"

// Scatter-free helpers for the arithmetic chain.
eval_multdiv_number_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: C.int) -> C.int {
	context = runtime.default_context()
	n1: C.longlong = 0
	n2: C.longlong = 0
	use_float := false
	f1: f64 = 0
	f2: f64 = 0
	error := false
	if tv1.v_type == VAR_FLOAT {
		f1 = transmute(f64)(tv1.vval)
		use_float = true
	} else {
		n1 = tv_get_number_chk(tv1, &error)
	}
	tv_clear(tv1)
	if error {
		tv_clear(tv2)
		return FAIL_E
	}
	if tv2.v_type == VAR_FLOAT {
		if !use_float {
			f1 = f64(n1)
			use_float = true
		}
		f2 = transmute(f64)(tv2.vval)
	} else {
		n2 = tv_get_number_chk(tv2, &error)
		tv_clear(tv2)
		if error {
			return FAIL_E
		}
		if use_float {
			f2 = f64(n2)
		}
	}
	if use_float {
		if op == '*' {
			f1 = f1 * f2
		} else if op == '/' {
			if f2 == 0 {
				if f1 == 0 {
					f1 = libc.NAN
				} else if f1 > 0 {
					f1 = libc.HUGE_VAL
				} else {
					f1 = -libc.HUGE_VAL
				}
			} else {
				f1 = f1 / f2
			}
		} else {
			emsg(cstring(E804_S))
			return FAIL_E
		}
		tv1.v_type = VAR_FLOAT
		tv1.vval = transmute(rawptr)(f1)
	} else {
		if op == '*' {
			n1 = n1 * n2
		} else if op == '/' {
			n1 = num_divide(n1, n2)
		} else {
			n1 = num_modulus(n1, n2)
		}
		tv1.v_type = VAR_NUMBER
		tv1.vval = transmute(rawptr)(n1)
	}
	return OK_E
}

// Fifth-level *, /, % operators (eval.c static, activates eval5).
eval6_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, want_string: bool) -> C.int {
	context = runtime.default_context()
	if eval7_o(arg, rettv, evalarg, want_string) == FAIL_E {
		return FAIL_E
	}
	for {
		op := C.int(([^]u8)(arg^)[0])
		if op != '*' && op != '/' && op != '%' {
			break
		}
		evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		var2 := Typval_T{}
		if eval7_o(arg, &var2, evalarg, false) == FAIL_E {
			return FAIL_E
		}
		if evaluate {
			if eval_multdiv_number_o(rettv, &var2, op) == FAIL_E {
				return FAIL_E
			}
		}
	}
	return OK_E
}

// —— Batch 28z: eval.c typval_compare + eval4 ——
EXPR_UNKNOWN_O :: 0
EXPR_EQUAL_O :: 1
EXPR_NEQUAL_O :: 2
EXPR_GREATER_O :: 3
EXPR_GEQUAL_O :: 4
EXPR_SMALLER_O :: 5
EXPR_SEQUAL_O :: 6
EXPR_MATCH_O :: 7
EXPR_NOMATCH_O :: 8
EXPR_IS_O :: 9
EXPR_ISNOT_O :: 10

E977_S :: "E977: Can only compare Blob with Blob"
E978_S :: "E978: Invalid operation for Blob"
E691_S :: "E691: Can only compare List with List"
E692_S :: "E692: Invalid operation for List"
E735_S :: "E735: Can only compare Dictionary with Dictionary"
E736_S :: "E736: Invalid operation for Dictionary"
E694_S :: "E694: Invalid operation for Funcrefs"

// Compare two typvals (eval.c public).
@(export)
typval_compare :: proc "c" (typ1: ^Typval_T, typ2: ^Typval_T, type: C.int, ic: bool) -> C.int {
	context = runtime.default_context()
	n1: C.longlong = 0
	n2: C.longlong = 0
	type_is := type == EXPR_IS_O || type == EXPR_ISNOT_O
	if type_is && typ1.v_type != typ2.v_type {
		if type == EXPR_ISNOT_O {
			n1 = 1
		}
	} else if typ1.v_type == VAR_BLOB || typ2.v_type == VAR_BLOB {
		if type_is {
			if typ1.v_type == typ2.v_type && rawptr(typ1.vval) == rawptr(typ2.vval) {
				n1 = 1
			}
			if type == EXPR_ISNOT_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		} else if typ1.v_type != typ2.v_type || (type != EXPR_EQUAL_O && type != EXPR_NEQUAL_O) {
			if typ1.v_type != typ2.v_type {
				emsg(cstring(E977_S))
			} else {
				emsg(cstring(E978_S))
			}
			tv_clear(typ1)
			return FAIL_E
		} else {
			if tv_blob_equal(rawptr(typ1.vval), rawptr(typ2.vval)) {
				n1 = 1
			}
			if type == EXPR_NEQUAL_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		}
	} else if typ1.v_type == VAR_LIST || typ2.v_type == VAR_LIST {
		if type_is {
			if typ1.v_type == typ2.v_type && rawptr(typ1.vval) == rawptr(typ2.vval) {
				n1 = 1
			}
			if type == EXPR_ISNOT_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		} else if typ1.v_type != typ2.v_type || (type != EXPR_EQUAL_O && type != EXPR_NEQUAL_O) {
			if typ1.v_type != typ2.v_type {
				emsg(cstring(E691_S))
			} else {
				emsg(cstring(E692_S))
			}
			tv_clear(typ1)
			return FAIL_E
		} else {
			if tv_list_equal(rawptr(typ1.vval), rawptr(typ2.vval), ic) {
				n1 = 1
			}
			if type == EXPR_NEQUAL_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		}
	} else if typ1.v_type == VAR_DICT || typ2.v_type == VAR_DICT {
		if type_is {
			if typ1.v_type == typ2.v_type && rawptr(typ1.vval) == rawptr(typ2.vval) {
				n1 = 1
			}
			if type == EXPR_ISNOT_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		} else if typ1.v_type != typ2.v_type || (type != EXPR_EQUAL_O && type != EXPR_NEQUAL_O) {
			if typ1.v_type != typ2.v_type {
				emsg(cstring(E735_S))
			} else {
				emsg(cstring(E736_S))
			}
			tv_clear(typ1)
			return FAIL_E
		} else {
			if tv_dict_equal(rawptr(typ1.vval), rawptr(typ2.vval), ic) {
				n1 = 1
			}
			if type == EXPR_NEQUAL_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		}
	} else if tv_is_func_o(typ1^) || tv_is_func_o(typ2^) {
		if type != EXPR_EQUAL_O && type != EXPR_NEQUAL_O && type != EXPR_IS_O && type != EXPR_ISNOT_O {
			emsg(cstring(E694_S))
			tv_clear(typ1)
			return FAIL_E
		}
		if (typ1.v_type == VAR_PARTIAL && rawptr(typ1.vval) == nil) || (typ2.v_type == VAR_PARTIAL && rawptr(typ2.vval) == nil) {
			if rawptr(typ1.vval) == rawptr(typ2.vval) {
				n1 = 1
			}
		} else if type_is {
			if typ1.v_type == VAR_FUNC && typ2.v_type == VAR_FUNC {
				if tv_equal(typ1, typ2, ic) {
					n1 = 1
				}
			} else if typ1.v_type == VAR_PARTIAL && typ2.v_type == VAR_PARTIAL {
				if rawptr(typ1.vval) == rawptr(typ2.vval) {
					n1 = 1
				}
			}
		} else {
			if tv_equal(typ1, typ2, ic) {
				n1 = 1
			}
		}
		if type == EXPR_NEQUAL_O || type == EXPR_ISNOT_O {
			if n1 != 0 {
				n1 = 0
			} else {
				n1 = 1
			}
		}
	} else if (typ1.v_type == VAR_FLOAT || typ2.v_type == VAR_FLOAT) && type != EXPR_MATCH_O && type != EXPR_NOMATCH_O {
		f1 := tv_get_float(typ1)
		f2 := tv_get_float(typ2)
		if type == EXPR_IS_O || type == EXPR_EQUAL_O {
			if f1 == f2 {
				n1 = 1
			}
		} else if type == EXPR_ISNOT_O || type == EXPR_NEQUAL_O {
			if f1 != f2 {
				n1 = 1
			}
		} else if type == EXPR_GREATER_O {
			if f1 > f2 {
				n1 = 1
			}
		} else if type == EXPR_GEQUAL_O {
			if f1 >= f2 {
				n1 = 1
			}
		} else if type == EXPR_SMALLER_O {
			if f1 < f2 {
				n1 = 1
			}
		} else if type == EXPR_SEQUAL_O {
			if f1 <= f2 {
				n1 = 1
			}
		}
	} else if (typ1.v_type == VAR_NUMBER || typ2.v_type == VAR_NUMBER) && type != EXPR_MATCH_O && type != EXPR_NOMATCH_O {
		n1 = tv_get_number(typ1)
		n2 = tv_get_number(typ2)
		if type == EXPR_IS_O || type == EXPR_EQUAL_O {
			if n1 == n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		} else if type == EXPR_ISNOT_O || type == EXPR_NEQUAL_O {
			if n1 != n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		} else if type == EXPR_GREATER_O {
			if n1 > n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		} else if type == EXPR_GEQUAL_O {
			if n1 >= n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		} else if type == EXPR_SMALLER_O {
			if n1 < n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		} else if type == EXPR_SEQUAL_O {
			if n1 <= n2 {
				n1 = 1
			} else {
				n1 = 0
			}
		}
	} else {
		buf1: [65]u8
		buf2: [65]u8
		s1 := tv_get_string_buf(typ1, &buf1[0])
		s2 := tv_get_string_buf(typ2, &buf2[0])
		i: C.int = 0
		if type != EXPR_MATCH_O && type != EXPR_NOMATCH_O {
			i = mb_strcmp_ic_r(ic, s1, s2)
		}
		if type == EXPR_IS_O || type == EXPR_EQUAL_O {
			if i == 0 {
				n1 = 1
			}
		} else if type == EXPR_ISNOT_O || type == EXPR_NEQUAL_O {
			if i != 0 {
				n1 = 1
			}
		} else if type == EXPR_GREATER_O {
			if i > 0 {
				n1 = 1
			}
		} else if type == EXPR_GEQUAL_O {
			if i >= 0 {
				n1 = 1
			}
		} else if type == EXPR_SMALLER_O {
			if i < 0 {
				n1 = 1
			}
		} else if type == EXPR_SEQUAL_O {
			if i <= 0 {
				n1 = 1
			}
		} else if type == EXPR_MATCH_O || type == EXPR_NOMATCH_O {
			if pattern_match(s2, s1, ic) != 0 {
				n1 = 1
			}
			if type == EXPR_NOMATCH_O {
				if n1 != 0 {
					n1 = 0
				} else {
					n1 = 1
				}
			}
		}
	}
	tv_clear(typ1)
	typ1.v_type = VAR_NUMBER
	typ1.vval = transmute(rawptr)(n1)
	return OK_E
}

// Comparison operator chain (eval.c static, activates eval3).
eval4_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	var2 := Typval_T{}
	type: C.int = EXPR_UNKNOWN_O
	length: C.int = 2
	if eval5_o(arg, rettv, evalarg) == FAIL_E {
		return FAIL_E
	}
	p := arg^
	c0 := ([^]u8)(p)[0]
	c1 := ([^]u8)(p)[1]
	if c0 == '=' {
		if c1 == '=' {
			type = EXPR_EQUAL_O
		} else if c1 == '~' {
			type = EXPR_MATCH_O
		}
	} else if c0 == '!' {
		if c1 == '=' {
			type = EXPR_NEQUAL_O
		} else if c1 == '~' {
			type = EXPR_NOMATCH_O
		}
	} else if c0 == '>' {
		if c1 != '=' {
			type = EXPR_GREATER_O
			length = 1
		} else {
			type = EXPR_GEQUAL_O
		}
	} else if c0 == '<' {
		if c1 != '=' {
			type = EXPR_SMALLER_O
			length = 1
		} else {
			type = EXPR_SEQUAL_O
		}
	} else if c0 == 'i' {
		if c1 == 's' {
			if ([^]u8)(p)[2] == 'n' && ([^]u8)(p)[3] == 'o' && ([^]u8)(p)[4] == 't' {
				length = 5
			}
			c := ([^]u8)(rawptr(uintptr(rawptr(p)) + uintptr(length)))[0]
			if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
				if length == 2 {
					type = EXPR_IS_O
				} else {
					type = EXPR_ISNOT_O
				}
			}
		}
	}
	if type != EXPR_UNKNOWN_O {
		ic := false
		if ([^]u8)(rawptr(uintptr(rawptr(p)) + uintptr(length)))[0] == '?' {
			ic = true
			length += 1
		} else if ([^]u8)(rawptr(uintptr(rawptr(p)) + uintptr(length)))[0] == '#' {
			length += 1
		} else {
			ic = (p_ic != 0)
		}
		arg^ = skipwhite(transmute(cstring)(rawptr(uintptr(rawptr(p)) + uintptr(length))))
		if eval5_o(arg, &var2, evalarg) == FAIL_E {
			tv_clear(rettv)
			return FAIL_E
		}
		if evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0 {
			ret := typval_compare(rettv, &var2, type, ic)
			tv_clear(&var2)
			return ret
		}
	}
	return OK_E
}

// —— Batch 28y: eval.c add/concat helpers + eval5 (dormant plains) ——

// Blob concatenation (eval.c static, dormant until eval5_o).
eval_addblob_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T) {
	context = runtime.default_context()
	b1 := rawptr(tv1.vval)
	b2 := rawptr(tv2.vval)
	b := tv_blob_alloc()
	len1 := i64(tv_blob_len_o(b1))
	len2 := i64(tv_blob_len_o(b2))
	totallen := len1 + len2
	if totallen >= 0 && totallen <= i64(max(C.int)) {
		ga_grow((^Garray)(b), C.int(totallen))
		if len1 > 0 {
			libc.memmove(rawptr((^rawptr)(uintptr(b) + 16)^), (^rawptr)(uintptr(b1) + 16)^, C.size_t(len1))
		}
		if len2 > 0 {
			libc.memmove(rawptr(uintptr((^rawptr)(uintptr(b) + 16)^) + uintptr(len1)), (^rawptr)(uintptr(b2) + 16)^, C.size_t(len2))
		}
		(^C.int)(uintptr(b) + 0)^ = C.int(totallen)
	}
	tv_clear(tv1)
	tv_blob_set_ret_o(tv1, b)
}

// List concatenation (eval.c static, dormant until eval5_o).
eval_addlist_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T) -> C.int {
	context = runtime.default_context()
	var3 := Typval_T{}
	if tv_list_concat(rawptr(tv1.vval), rawptr(tv2.vval), &var3) == FAIL_E {
		tv_clear(tv1)
		tv_clear(tv2)
		return FAIL_E
	}
	tv_clear(tv1)
	tv1^ = var3
	return OK_E
}

// String concatenation (eval.c static, dormant until eval5_o).
eval_concat_str_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T) -> C.int {
	context = runtime.default_context()
	buf1: [65]u8
	buf2: [65]u8
	s1 := tv_get_string_buf(tv1, &buf1[0])
	s2 := tv_get_string_buf_chk(tv2, &buf2[0])
	if s2 == nil {
		tv_clear(tv1)
		tv_clear(tv2)
		return FAIL_E
	}
	if grow_string_tv(tv1, s2) == OK_E {
		return OK_E
	}
	p := concat_str_c(s1, s2)
	tv_clear(tv1)
	tv1.v_type = VAR_STRING
	tv1.vval = transmute(rawptr)(p)
	return OK_E
}

// Number add/subtract (eval.c static, dormant until eval5_o).
eval_addsub_number_o :: proc "c" (tv1: ^Typval_T, tv2: ^Typval_T, op: C.int) -> C.int {
	context = runtime.default_context()
	error := false
	n1: C.longlong = 0
	n2: C.longlong = 0
	f1: f64 = 0
	f2: f64 = 0
	if tv1.v_type == VAR_FLOAT {
		f1 = transmute(f64)(tv1.vval)
	} else {
		n1 = tv_get_number_chk(tv1, &error)
		if error {
			tv_clear(tv1)
			tv_clear(tv2)
			return FAIL_E
		}
		if tv2.v_type == VAR_FLOAT {
			f1 = f64(n1)
		}
	}
	if tv2.v_type == VAR_FLOAT {
		f2 = transmute(f64)(tv2.vval)
	} else {
		n2 = tv_get_number_chk(tv2, &error)
		if error {
			tv_clear(tv1)
			tv_clear(tv2)
			return FAIL_E
		}
		if tv1.v_type == VAR_FLOAT {
			f2 = f64(n2)
		}
	}
	tv_clear(tv1)
	if tv1.v_type == VAR_FLOAT || tv2.v_type == VAR_FLOAT {
		if op == '+' {
			f1 = f1 + f2
		} else {
			f1 = f1 - f2
		}
		tv1.v_type = VAR_FLOAT
		tv1.vval = transmute(rawptr)(f1)
	} else {
		if op == '+' {
			n1 = n1 + n2
		} else {
			n1 = n1 - n2
		}
		tv1.v_type = VAR_NUMBER
		tv1.vval = transmute(rawptr)(n1)
	}
	return OK_E
}

// Fourth-level +, -, .. operators (eval.c static, activates eval4).
eval5_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	if eval6_o(arg, rettv, evalarg, false) == FAIL_E {
		return FAIL_E
	}
	for {
		op := C.int(([^]u8)(arg^)[0])
		concat := op == '.'
		if op != '+' && op != '-' && !concat {
			break
		}
		evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
		if ((op != '+' || (rettv.v_type != VAR_LIST && rettv.v_type != VAR_BLOB)) && (op == '.' || rettv.v_type != VAR_FLOAT) && evaluate) {
			if (op == '.' && !tv_check_str(rettv)) || (op != '.' && !tv_check_num(rettv)) {
				tv_clear(rettv)
				return FAIL_E
			}
		}
		if op == '.' && ([^]u8)(arg^)[1] == '.' {
			arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		}
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		var2 := Typval_T{}
		if eval6_o(arg, &var2, evalarg, op == '.') == FAIL_E {
			tv_clear(rettv)
			return FAIL_E
		}
		if evaluate {
			if op == '.' {
				if eval_concat_str_o(rettv, &var2) == FAIL_E {
					return FAIL_E
				}
			} else if op == '+' && rettv.v_type == VAR_BLOB && var2.v_type == VAR_BLOB {
				eval_addblob_o(rettv, &var2)
			} else if op == '+' && rettv.v_type == VAR_LIST && var2.v_type == VAR_LIST {
				if eval_addlist_o(rettv, &var2) == FAIL_E {
					return FAIL_E
				}
			} else {
				if eval_addsub_number_o(rettv, &var2, op) == FAIL_E {
					return FAIL_E
				}
			}
			tv_clear(&var2)
		}
	}
	return OK_E
}

// Bare-word dict key scanner (eval.c static, dormant until eval_dict_o).
get_literal_key_o :: proc "c" (arg: ^cstring, tv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	c := ([^]u8)(arg^)[0]
	if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
		return FAIL_E
	}
	p := uintptr(rawptr(arg^))
	for {
		cc := ([^]u8)(p)[0]
		if !((cc >= 'A' && cc <= 'Z') || (cc >= 'a' && cc <= 'z') || (cc >= '0' && cc <= '9') || cc == '_' || cc == '-') {
			break
		}
		p += 1
	}
	tv.v_type = VAR_STRING
	tv.vval = transmute(rawptr)(xmemdupz_o2(transmute(^u8)(arg^), C.size_t(p - uintptr(rawptr(arg^)))))
	arg^ = skipwhite(transmute(cstring)(p))
	return OK_E
}

// Dictionary literal parser (eval.c static, activates with eval7).
eval_dict_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, literal: bool) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^Evalarg_T)(evalarg).eval_flags & EVAL_EVALUATE_O) != 0
	tv := Typval_T{}
	key: cstring = nil
	curly_expr := skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	buf: [65]u8
	if ([^]u8)(curly_expr)[0] != '}' && !literal {
		ce := curly_expr
		if eval1(&ce, &tv, nil) == OK_E && ([^]u8)(skipwhite(ce))[0] == '}' {
			return NOTDONE_O
		}
	}
	d: rawptr = nil
	if evaluate {
		d = tv_dict_alloc()
	}
	tvkey := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	tv.v_type = VAR_UNKNOWN
	arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	for ([^]u8)(arg^)[0] != '}' && ([^]u8)(arg^)[0] != 0 {
		r: C.int = 0
		if literal {
			r = get_literal_key_o(arg, &tvkey)
		} else {
			r = eval1(arg, &tvkey, evalarg)
		}
		if r == FAIL_E {
			if d != nil {
				tv_dict_free(d)
			}
			return FAIL_E
		}
		if ([^]u8)(arg^)[0] != ':' {
			semsg(cstring(E720_S), arg^)
			tv_clear(&tvkey)
			if d != nil {
				tv_dict_free(d)
			}
			return FAIL_E
		}
		if evaluate {
			key = tv_get_string_buf_chk(&tvkey, &buf[0])
			if key == nil {
				tv_clear(&tvkey)
				if d != nil {
					tv_dict_free(d)
				}
				return FAIL_E
			}
		}
		arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		if eval1(arg, &tv, evalarg) == FAIL_E {
			tv_clear(&tvkey)
			if d != nil {
				tv_dict_free(d)
			}
			return FAIL_E
		}
		if evaluate {
			item := tv_dict_find(d, key, -1)
			if item != nil {
				semsg(cstring(E721_S), key)
				tv_clear(&tvkey)
				tv_clear(&tv)
				if d != nil {
					tv_dict_free(d)
				}
				return FAIL_E
			}
			item = tv_dict_item_alloc(key)
			(^Typval_T)(uintptr(item))^ = tv
			(^Typval_T)(uintptr(item)).v_lock = VAR_UNLOCKED
			if tv_dict_add(d, item) == FAIL_E {
				tv_dict_item_free(item)
			}
		}
		tv_clear(&tvkey)
		had_comma := ([^]u8)(arg^)[0] == ','
		if had_comma {
			arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
		}
		if ([^]u8)(arg^)[0] == '}' {
			break
		}
		if !had_comma {
			semsg(cstring(E722_S), arg^)
			if d != nil {
				tv_dict_free(d)
			}
			return FAIL_E
		}
	}
	if ([^]u8)(arg^)[0] != '}' {
		semsg(cstring(E723_S), arg^)
		if d != nil {
			tv_dict_free(d)
		}
		return FAIL_E
	}
	arg^ = skipwhite(transmute(cstring)(uintptr(rawptr(arg^)) + 1))
	if evaluate {
		tv_dict_set_ret_o(rettv, d)
	}
	return OK_E
}

// Literal-dict #{...} entry (eval.c static, dormant until eval7).
eval_lit_dict_o :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	if ([^]u8)(arg^)[1] == '{' {
		arg^ = transmute(cstring)(uintptr(rawptr(arg^)) + 1)
		return eval_dict_o(arg, rettv, evalarg, true)
	}
	return NOTDONE_O
}

// —— Batch 28f: eval.c vim_function call cluster ——

// Call a Vimscript function by name (eval.c public).
@(export)
call_vim_function :: proc "c" (func: cstring, argc: C.int, argv: ^Typval_T, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	fail := false
	length := C.int(libc.strlen(func))
	pt: rawptr = nil
	f := func
	if length >= 6 && libc.memcmp(rawptr(transmute(^u8)(func)), rawptr(transmute(^u8)(cstring("v:lua."))), 6) == 0 {
		f = transmute(cstring)(uintptr(rawptr(func)) + 6)
		length = check_luafunc_name(f, false)
		if length == 0 {
			fail = true
		} else {
			pt = get_vim_var_partial(VV_LUA_O)
		}
	}
	ret: C.int = 0
	if !fail {
		rettv.v_type = VAR_UNKNOWN
		fe := Funcexe_T{}
		fe.firstline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		fe.lastline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		fe.evaluate = true
		fe.partial = pt
		ret = call_func(f, length, rettv, argc, argv, &fe)
	} else {
		ret = FAIL_E
	}
	if ret == FAIL_E {
		tv_clear(rettv)
	}
	return ret
}

// Call function, return string result (eval.c public).
@(export)
call_func_retstr :: proc "c" (func: cstring, argc: C.int, argv: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	rettv := Typval_T{}
	if call_vim_function(func, argc, argv, &rettv) == FAIL_E {
		return nil
	}
	retval := rawptr(xstrdup_o(transmute(^u8)(tv_get_string(&rettv))))
	tv_clear(&rettv)
	return retval
}

// Call function, return list result (eval.c public).
@(export)
call_func_retlist :: proc "c" (func: cstring, argc: C.int, argv: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	rettv := Typval_T{}
	if call_vim_function(func, argc, argv, &rettv) == FAIL_E {
		return nil
	}
	if rettv.v_type != VAR_LIST {
		tv_clear(&rettv)
		return nil
	}
	return rawptr(rettv.vval)
}

// —— Batch 27ca: funcs.c jobstop ——
CHAN_ID_OFF :: 0
CHAN_IS_RPC_OFF :: 1752

// "jobstop()" function.
@(export)
f_jobstop :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_NUMBER {
		emsg(e_invarg)
		return
	}
	data := find_job(C.ulonglong(transmute(C.longlong)(([^]Typval_T)(argvars)[0].vval)), false)
	if data == nil {
		return
	}
	err: cstring = nil
	if (^bool)(uintptr(data) + CHAN_IS_RPC_OFF)^ {
		channel_close(u64((^C.ulonglong)(uintptr(data) + CHAN_ID_OFF)^), KCHPART_RPC_O, &err)
	}
	proc_stop((^Proc)(rawptr(uintptr(data) + CHAN_STREAM_OFF)))
	rettv.vval = transmute(rawptr)(C.longlong(1))
	if err != nil {
		emsg(err)
	}
}

// —— Batch 27cb: funcs.c jobstart engine (FFI fully rewired) ——
foreign _ {
	// channel_terminal_alloc now defined in channel.odin — call directly.
	@(link_name = "terminal_open")
	terminal_open_e :: proc "c" (termpp: ^rawptr, buf: rawptr) ---
	@(link_name = "terminal_buf")
	terminal_buf_e :: proc "c" (term: rawptr) -> C.int ---
	@(link_name = "vim_FullName")
	vim_FullName_e :: proc "c" (fname: cstring, buf: cstring, len: C.size_t, force: bool) -> C.int ---
	@(link_name = "dict_set_var")
	dict_set_var_e :: proc "c" (dict: rawptr, key: NvimString, value: Api_Object, del: bool, retval: bool, arena: rawptr, err: rawptr) -> Api_Object ---
}

KCHSTDIN_PIPE_O :: 0
KCHSTDIN_NULL_O :: 1
CHAN_TERM_OFF :: 1848
B_CHANGED_OFF :: 208
B_TERMINAL_OFF2 :: 12488
B_HANDLE_OFF :: 0
E_CMDWIN_S :: "E11: Invalid in command-line window; <CR> executes, CTRL-C quits"
E_TERM_MODIFIED_S :: "jobstart(...,{term=true}) requires unmodified buffer"
E_TERM_CONNECTED_S :: "Terminal already connected to buffer %d"

// "jobstart()" function.
@(export)
f_jobstart :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	cmd: cstring = nil
	executable := true
	argv := tv_to_argv((^Typval_T)(uintptr(argvars)), &cmd, &executable)
	if argv == nil {
		if executable {
			rettv.vval = transmute(rawptr)(C.longlong(0))
		} else {
			rettv.vval = transmute(rawptr)(C.longlong(-1))
		}
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type != VAR_DICT && ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		semsg(e_invarg2, cstring("expected dictionary"))
		shell_free_argv(argv)
		return
	}
	job_opts: rawptr = nil
	detach := false
	rpc := false
	pty := false
	term := false
	clear_env := false
	overlapped := false
	stdin_mode: C.int = KCHSTDIN_PIPE_O
	on_stdout := CallbackReader_E{}
	on_stderr := CallbackReader_E{}
	on_exit := Callback_E{}
	cwd: cstring = nil
	job_env: rawptr = nil
	if ([^]Typval_T)(argvars)[1].v_type == VAR_DICT {
		job_opts = rawptr(([^]Typval_T)(argvars)[1].vval)
		if tv_dict_get_number(job_opts, cstring("detach")) != 0 {
			detach = true
		}
		if tv_dict_get_number(job_opts, cstring("rpc")) != 0 {
			rpc = true
		}
		if tv_dict_get_number(job_opts, cstring("term")) != 0 {
			term = true
		}
		if term || tv_dict_get_number(job_opts, cstring("pty")) != 0 {
			pty = true
		}
		if tv_dict_get_number(job_opts, cstring("clear_env")) != 0 {
			clear_env = true
		}
		if tv_dict_get_number(job_opts, cstring("overlapped")) != 0 {
			overlapped = true
		}
		s := tv_dict_get_string(job_opts, cstring("stdin"), false)
		if s != nil {
			if libc.strncmp(s, cstring("null"), 65) == 0 {
				stdin_mode = KCHSTDIN_NULL_O
			} else if libc.strncmp(s, cstring("pipe"), 65) != 0 {
				semsg(cstring(E_INVARG_NVAL_S), cstring("stdin"), s)
			}
		}
		job_term := tv_dict_find(job_opts, cstring("term"), 4)
		if job_term != nil && (^C.int)(uintptr(job_term))^ != VAR_BOOL {
			semsg(e_invarg2, cstring("'term' must be Boolean"))
			shell_free_argv(argv)
			return
		}
		if pty && rpc {
			semsg(e_invarg2, cstring("job cannot have both 'pty' and 'rpc' options set"))
			shell_free_argv(argv)
			return
		}
		new_cwd := tv_dict_get_string(job_opts, cstring("cwd"), false)
		if new_cwd != nil && ([^]u8)(new_cwd)[0] != 0 {
			cwd = new_cwd
			if !os_isdir(cwd) {
				semsg(e_invarg2, cstring("expected valid directory"))
				shell_free_argv(argv)
				return
			}
		}
		job_env = tv_dict_find(job_opts, cstring("env"), 3)
		if job_env != nil && (^C.int)(uintptr((^Typval_T)(uintptr(job_env))))^ != VAR_DICT {
			semsg(e_invarg2, cstring("env"))
			shell_free_argv(argv)
			return
		}
		if !common_job_callbacks(job_opts, &on_stdout, &on_stderr, &on_exit) {
			shell_free_argv(argv)
			return
		}
	}
	width: C.uint16_t = C.uint16_t(tv_dict_get_number(job_opts, cstring("width")))
	height: C.uint16_t = C.uint16_t(tv_dict_get_number(job_opts, cstring("height")))
	term_name: cstring = nil
	if term {
		if text_locked_r() {
			text_locked_msg_r()
			shell_free_argv(argv)
			return
		}
		if bt_cmdwin(curbuf) {
			emsg(cstring(E_CMDWIN_S))
			shell_free_argv(argv)
			return
		}
		if (^C.int)(uintptr(curbuf) + B_CHANGED_OFF)^ != 0 {
			emsg(cstring(E_TERM_MODIFIED_S))
			shell_free_argv(argv)
			return
		}
		term_ptr := (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF2)^
		if term_ptr != nil && terminal_running_r(term_ptr) {
			semsg(cstring(E_TERM_CONNECTED_S), (^C.int)(uintptr(curbuf) + B_HANDLE_OFF)^)
			shell_free_argv(argv)
			return
		}
		if term_ptr != nil {
			buf_close_terminal(curbuf)
		}
		term_name = cstring("xterm-256color")
		if cwd == nil {
			cwd = cstring(".")
		}
		overlapped = false
		detach = false
		stdin_mode = KCHSTDIN_PIPE_O
		if width == 0 {
			ww := (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(curwin)
			if ww < 0 {
				ww = 0
			}
			width = C.uint16_t(ww)
		}
		if height == 0 {
			height = C.uint16_t((^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^)
		}
	}
	if pty {
		if term_name == nil {
			term_name = tv_dict_get_string(job_opts, cstring("TERM"), false)
		}
		if term_name == nil {
			term_name = cstring("ansi")
		}
	}
	env := create_environment(job_env, clear_env, pty, true, term_name)
	status: C.longlong = 0
	chan := channel_job_start(transmute(rawptr)(argv), nil, on_stdout, on_stderr, on_exit, pty, rpc, overlapped, detach, stdin_mode, cwd, width, height, env, rawptr(&status))
	rettv.vval = transmute(rawptr)(status)
	if chan == nil {
		return
	}
	if !term {
		channel_create_event(chan, nil)
		return
	}
	if status <= 0 {
		return
	}
	pid := (^C.int)(uintptr(chan) + CHAN_STREAM_OFF + PROC_PID_OFF)^
	buf := curbuf
	(^C.int)(uintptr(buf) + B_P_SWF_OFF)^ = 0
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil && ml_open_r(buf) == FAIL_E {
		proc_stop((^Proc)(rawptr(uintptr(chan) + CHAN_STREAM_OFF)))
		channel_decref(chan)
		return
	}
	channel_incref(chan)
	channel_terminal_alloc(buf, chan)
	apply_autocmds(EVENT_BUFFILEPRE_O, nil, nil, false, buf)
	term_alive := true
	if (^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^ == nil || terminal_buf_e((^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^) == 0 {
		term_alive = false
	}
	if term_alive {
		vim_FullName_e(cwd, transmute(cstring)(&name_buff[0]), 4096, false)
		length := home_replace(nil, transmute(cstring)(&name_buff[0]), transmute(cstring)(&IObuff[0]), 1025, true)
		if length != 1 && (([^]u8)(&IObuff[0])[length - 1] == '\\' || ([^]u8)(&IObuff[0])[length - 1] == '/') {
			([^]u8)(&IObuff[0])[length - 1] = 0
		}
		if length == 1 && ([^]u8)(&IObuff[0])[0] == '/' {
			([^]u8)(&IObuff[0])[1] = '.'
			([^]u8)(&IObuff[0])[2] = 0
		}
		libc.snprintf(transmute([^]u8)(&name_buff[0]), 4096, cstring("term://%s//%d:%s"), transmute(cstring)(&IObuff[0]), pid, cmd)
		setfname(buf, transmute(cstring)(&name_buff[0]), nil, true)
		apply_autocmds(EVENT_BUFFILEPOST_O, nil, nil, false, buf)
		if (^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^ == nil || terminal_buf_e((^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^) == 0 {
			term_alive = false
		}
	}
	if term_alive {
		err := Api_Error{typ = -1, msg = nil}
		locked := (^C.int)(uintptr(buf) + B_LOCKED_OFF)^
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ = locked + 1
		id_key := NvimString{data = cstring("terminal_job_id"), size = 15}
		id_val := Api_Object{t = 2}
		(^i64)(&id_val.data[0])^ = i64((^u64)(uintptr(chan) + CHAN_ID_OFF)^)
		dict_set_var_e((^rawptr)(uintptr(buf) + B_VARS_OFF)^, id_key, id_val, false, false, nil, rawptr(&err))
		api_clear_error_r(&err)
		pid_key := NvimString{data = cstring("terminal_job_pid"), size = 16}
		pid_val := Api_Object{t = 2}
		(^i64)(&pid_val.data[0])^ = i64(pid)
		dict_set_var_e((^rawptr)(uintptr(buf) + B_VARS_OFF)^, pid_key, pid_val, false, false, nil, rawptr(&err))
		api_clear_error_r(&err)
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ = locked
		if (^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^ == nil || terminal_buf_e((^rawptr)(uintptr(chan) + CHAN_TERM_OFF)^) == 0 {
			term_alive = false
		}
	}
	if term_alive {
		terminal_open_e((^rawptr)(uintptr(chan) + CHAN_TERM_OFF), buf)
	}
	channel_create_event(chan, nil)
	channel_decref(chan)
}

// —— Batch 28bb: eval.c callback/lua-name + string leaves (exports + weak) ——
E921_S :: "E921: Invalid callback argument"

// Callback value constructor (eval.c public).
@(export)
callback_from_typval :: proc "c" (callback: ^Callback_E, arg: ^Typval_T) -> bool {
	context = runtime.default_context()
	r: C.int = OK_E
	if arg.v_type == VAR_PARTIAL && rawptr(arg.vval) != nil {
		callback.data = rawptr(arg.vval)
		(^C.int)(uintptr(rawptr(arg.vval)) + PT_REFCOUNT_OFF_O)^ += 1
		callback.type = KCB_PARTIAL_O
	} else if arg.v_type == VAR_STRING && rawptr(arg.vval) != nil && ascii_isdigit_o(([^]u8)(arg.vval)[0]) {
		r = FAIL_E
	} else if arg.v_type == VAR_FUNC || arg.v_type == VAR_STRING {
		name := transmute(cstring)(arg.vval)
		if name == nil {
			r = FAIL_E
		} else if ([^]u8)(name)[0] == 0 {
			callback.type = KCB_NONE_O
			callback.data = nil
		} else {
			callback.data = nil
			if arg.v_type == VAR_STRING {
				callback.data = rawptr(get_scriptlocal_funcname(name))
			}
			if callback.data == nil {
				callback.data = rawptr(xstrdup_o(transmute(^u8)(name)))
			}
			func_ref(transmute(cstring)(callback.data))
			callback.type = KCB_FUNCREF_O
		}
	} else if nlua_is_table_from_lua_e(arg) {
		name := nlua_register_table_as_callable_e(arg)
		if name != nil {
			callback.data = rawptr(xstrdup_o(transmute(^u8)(name)))
			callback.type = KCB_FUNCREF_O
		} else {
			r = FAIL_E
		}
	} else if arg.v_type == VAR_SPECIAL || (arg.v_type == VAR_NUMBER && transmute(C.longlong)(arg.vval) == 0) {
		callback.type = KCB_NONE_O
		callback.data = nil
	} else {
		r = FAIL_E
	}
	if r == FAIL_E {
		emsg(cstring(E921_S))
		return false
	}
	return true
}

// v:lua partial check (eval.c public).
@(export)
is_luafunc :: proc "c" (partial: rawptr) -> bool {
	context = runtime.default_context()
	return partial == get_vim_var_partial(VV_LUA_O)
}

// Skip one v:lua name (eval.c public).
@(export)
skip_luafunc_name :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for {
		c := ([^]u8)(cur)[0]
		if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '\'') {
			break
		}
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return cur
}

// Validate v:lua name + terminator (eval.c public).
@(export)
check_luafunc_name :: proc "c" (str: cstring, paren: bool) -> C.int {
	context = runtime.default_context()
	p := skip_luafunc_name(str)
	want: u8 = 0
	if paren {
		want = '('
	}
	if ([^]u8)(p)[0] != want {
		return 0
	}
	return C.int(uintptr(rawptr(p)) - uintptr(rawptr(str)))
}

// Byte index for char index (eval.c static).
char_idx2byte_o :: proc "c" (str: cstring, str_len: C.size_t, idx: C.longlong) -> C.longlong {
	context = runtime.default_context()
	nchar := idx
	nbyte: C.size_t = 0
	if nchar >= 0 {
		for nchar > 0 && nbyte < str_len {
			nbyte += C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(str)) + uintptr(nbyte))))
			nchar -= 1
		}
	} else {
		nbyte = str_len
		for nchar < 0 && nbyte > 0 {
			nbyte -= 1
			nbyte -= C.size_t(utf_head_off_r(transmute(^u8)(str), transmute(^u8)(uintptr(rawptr(str)) + uintptr(nbyte))))
			nchar += 1
		}
		if nchar < 0 {
			return -1
		}
	}
	return C.longlong(nbyte)
}

// Char-at-index (eval.c public).
@(export)
char_from_string :: proc "c" (str: cstring, index: C.longlong) -> cstring {
	context = runtime.default_context()
	if str == nil {
		return nil
	}
	nchar := index
	slen := libc.strlen(str)
	if index < 0 {
		clen: C.int = 0
		nbyte: C.size_t = 0
		for nbyte < slen {
			nbyte += C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(str)) + uintptr(nbyte))))
			clen += 1
		}
		nchar = C.longlong(clen) + index
		if nchar < 0 {
			return nil
		}
	}
	nbyte: C.size_t = 0
	for nchar > 0 && nbyte < slen {
		nbyte += C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(str)) + uintptr(nbyte))))
		nchar -= 1
	}
	if nbyte >= slen {
		return nil
	}
	return transmute(cstring)(xmemdupz_o2(transmute(^u8)(uintptr(rawptr(str)) + uintptr(nbyte)), C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(str)) + uintptr(nbyte))))))
}

// String slice by char index (eval.c public).
@(export)
string_slice :: proc "c" (str: cstring, first: C.longlong, last: C.longlong, exclusive: bool) -> cstring {
	context = runtime.default_context()
	if str == nil {
		return nil
	}
	slen := libc.strlen(str)
	start_byte := char_idx2byte_o(str, slen, first)
	if start_byte < 0 {
		start_byte = 0
	}
	end_byte: C.longlong = 0
	if (last == -1 && !exclusive) || last == VARNUMBER_MAX_O {
		end_byte = C.longlong(slen)
	} else {
		end_byte = char_idx2byte_o(str, slen, last)
		if !exclusive && end_byte >= 0 && end_byte < C.longlong(slen) {
			end_byte += C.longlong(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(str)) + uintptr(end_byte))))
		}
	}
	if start_byte >= C.longlong(slen) || end_byte <= start_byte {
		return nil
	}
	return transmute(cstring)(xmemdupz_o2(transmute(^u8)(uintptr(rawptr(str)) + uintptr(start_byte)), C.size_t(end_byte - start_byte)))
}

// Float prefix parser (eval.c public).
@(export)
string2float :: proc "c" (text: cstring, ret_value: ^f64) -> C.size_t {
	context = runtime.default_context()
	c0 := ([^]u8)(text)[0]
	c1 := ([^]u8)(text)[1]
	c2 := ([^]u8)(text)[2]
	c3 := ([^]u8)(text)[3]
	is_inf := (c0 == 'i' || c0 == 'I') && (c1 == 'n' || c1 == 'N') && (c2 == 'f' || c2 == 'F')
	is_ninf := c0 == '-' && (c1 == 'i' || c1 == 'I') && (c2 == 'n' || c2 == 'N') && (c3 == 'f' || c3 == 'F')
	is_nan := (c0 == 'n' || c0 == 'N') && (c1 == 'a' || c1 == 'A') && (c2 == 'n' || c2 == 'N')
	if is_inf {
		ret_value^ = libc.INFINITY
		return 3
	}
	if is_ninf {
		ret_value^ = -libc.INFINITY
		return 4
	}
	if is_nan {
		ret_value^ = libc.NAN
		return 3
	}
	endp: cstring = nil
	ret_value^ = strtod_e(text, &endp)
	return C.size_t(uintptr(rawptr(endp)) - uintptr(rawptr(text)))
}

// —— Batch 28bn: eval/funcs.c dispatch table logic (exports + weak) ——
foreign _ {
	@(link_name = "nvim_odin_funcdef_at")
	nvim_odin_funcdef_at_e :: proc "c" (i: C.int) -> rawptr ---
	@(link_name = "nvim_odin_lua_wrapper_addr")
	nvim_odin_lua_wrapper_addr_e :: proc "c" () -> rawptr ---
}

// EvalFuncDef mirror (funcs.h:21): 32B cc-probed.
EvalFuncDef_O :: struct {
	name:     cstring, // 0
	min_argc: u8,      // 8
	max_argc: u8,      // 9
	base_arg: u8,      // 10
	fast:     bool,    // 11
	func:     rawptr,  // 16
	data:     rawptr,  // 24 (EvalFuncData union, opaque)
}
#assert(size_of(EvalFuncDef_O) == 32)

// VimLFunc signature (funcs.h:12).
VimLFunc_O :: proc "c" (args: ^Typval_T, rvar: ^Typval_T, data: rawptr)

BASE_NONE_O :: 0
BASE_LAST_O :: 255
E119_S :: "E119: Not enough arguments for function: %s"
E_TOOFEWARG_S :: "E119: Not enough arguments for function: %s"

@(private = "file")
get_function_name_intidx_g: C.int = -1
@(private = "file")
get_expr_name_intidx_g: C.int = -1

// Generated perfect-hash transcription (funcs.generated.h:689).
@(export)
find_internal_func_hash :: proc "c" (str: cstring, len: C.size_t) -> C.int {
	context = runtime.default_context()
	low: C.int = 0
	high: C.int = 0
	s := ([^]u8)(str)
	n := int(len)
	switch n {
	case 2:
		switch s[0] {
		case 'i': low = 0; high = 1
		case 'o': low = 1; high = 2
		case 't': low = 2; high = 3
		case:
		}
	case 3:
		switch s[0] {
		case 'a': low = 3; high = 6
		case 'c': low = 6; high = 8
		case 'e': low = 8; high = 9
		case 'g': low = 9; high = 10
		case 'h': low = 10; high = 11
		case 'l': low = 11; high = 13
		case 'm': low = 13; high = 16
		case 'p': low = 16; high = 17
		case 's': low = 17; high = 18
		case 't': low = 18; high = 19
		case 'x': low = 19; high = 20
		case:
		}
	case 4:
		switch s[3] {
		case 'D': low = 20; high = 21
		case 'b': low = 21; high = 22
		case 'c': low = 22; high = 23
		case 'd': low = 23; high = 25
		case 'e': low = 25; high = 28
		case 'h': low = 28; high = 31
		case 'l': low = 31; high = 34
		case 'm': low = 34; high = 35
		case 'n': low = 35; high = 38
		case 'q': low = 38; high = 39
		case 's': low = 39; high = 41
		case 't': low = 41; high = 44
		case 'v': low = 44; high = 45
		case 'y': low = 45; high = 46
		case:
		}
	case 5:
		switch s[1] {
		case 'a': low = 46; high = 48
		case 'c': low = 48; high = 49
		case 'h': low = 49; high = 50
		case 'i': low = 50; high = 51
		case 'k': low = 51; high = 52
		case 'l': low = 52; high = 54
		case 'm': low = 54; high = 55
		case 'n': low = 55; high = 57
		case 'o': low = 57; high = 60
		case 'p': low = 60; high = 61
		case 'r': low = 61; high = 63
		case 's': low = 63; high = 65
		case 't': low = 65; high = 68
		case 'u': low = 68; high = 69
		case 'y': low = 69; high = 70
		case:
		}
	case 6:
		switch s[5] {
		case '6': low = 70; high = 71
		case 'd': low = 71; high = 78
		case 'e': low = 78; high = 84
		case 'f': low = 84; high = 85
		case 'g': low = 85; high = 89
		case 'h': low = 89; high = 90
		case 'l': low = 90; high = 92
		case 'm': low = 92; high = 93
		case 'n': low = 93; high = 94
		case 'p': low = 94; high = 95
		case 'r': low = 95; high = 99
		case 's': low = 99; high = 103
		case 't': low = 103; high = 110
		case 'v': low = 110; high = 112
		case 'w': low = 112; high = 113
		case 'x': low = 113; high = 115
		case:
		}
	case 7:
		switch s[2] {
		case '2': low = 115; high = 116
		case '3': low = 116; high = 117
		case 'a': low = 117; high = 123
		case 'b': low = 123; high = 127
		case 'c': low = 127; high = 128
		case 'd': low = 128; high = 130
		case 'e': low = 130; high = 132
		case 'f': low = 132; high = 134
		case 'g': low = 134; high = 135
		case 'l': low = 135; high = 137
		case 'n': low = 137; high = 142
		case 'p': low = 142; high = 143
		case 'r': low = 143; high = 147
		case 's': low = 147; high = 152
		case 't': low = 152; high = 157
		case 'u': low = 157; high = 158
		case 'v': low = 158; high = 160
		case 'x': low = 160; high = 163
		case:
		}
	case 8:
		switch s[3] {
		case '1': low = 163; high = 164
		case '2': low = 164; high = 165
		case '_': low = 165; high = 166
		case 'a': low = 166; high = 167
		case 'b': low = 167; high = 169
		case 'c': low = 169; high = 177
		case 'd': low = 177; high = 182
		case 'e': low = 182; high = 183
		case 'f': low = 183; high = 190
		case 'l': low = 190; high = 191
		case 'm': low = 191; high = 197
		case 'n': low = 197; high = 199
		case 'o': low = 199; high = 202
		case 'p': low = 202; high = 209
		case 's': low = 209; high = 212
		case 't': low = 212; high = 216
		case 'u': low = 216; high = 217
		case 'w': low = 217; high = 221
		case 'x': low = 221; high = 222
		case 'y': low = 222; high = 223
		case:
		}
	case 9:
		switch s[4] {
		case '2': low = 223; high = 227
		case 'D': low = 227; high = 228
		case '_': low = 228; high = 234
		case 'a': low = 234; high = 239
		case 'c': low = 239; high = 243
		case 'd': low = 243; high = 244
		case 'e': low = 244; high = 251
		case 'f': low = 251; high = 254
		case 'g': low = 254; high = 255
		case 'h': low = 255; high = 256
		case 'i': low = 256; high = 261
		case 'l': low = 261; high = 263
		case 'm': low = 263; high = 265
		case 'n': low = 265; high = 267
		case 'o': low = 267; high = 270
		case 'r': low = 270; high = 271
		case 's': low = 271; high = 272
		case 't': low = 272; high = 274
		case 'u': low = 274; high = 277
		case 'x': low = 277; high = 278
		case:
		}
	case 10:
		switch s[5] {
		case '_': low = 278; high = 280
		case 'a': low = 280; high = 285
		case 'b': low = 285; high = 287
		case 'c': low = 287; high = 289
		case 'd': low = 289; high = 293
		case 'e': low = 293; high = 296
		case 'f': low = 296; high = 300
		case 'g': low = 300; high = 302
		case 'h': low = 302; high = 304
		case 'i': low = 304; high = 306
		case 'l': low = 306; high = 308
		case 'm': low = 308; high = 310
		case 'n': low = 310; high = 316
		case 'o': low = 316; high = 317
		case 'p': low = 317; high = 319
		case 'q': low = 319; high = 320
		case 'r': low = 320; high = 323
		case 's': low = 323; high = 325
		case 't': low = 325; high = 330
		case 'w': low = 330; high = 331
		case:
		}
	case 11:
		switch s[5] {
		case '_': low = 331; high = 334
		case 'a': low = 334; high = 336
		case 'c': low = 336; high = 338
		case 'd': low = 338; high = 343
		case 'e': low = 343; high = 348
		case 'f': low = 348; high = 350
		case 'g': low = 350; high = 353
		case 'h': low = 353; high = 355
		case 'i': low = 355; high = 357
		case 'm': low = 357; high = 359
		case 'n': low = 359; high = 362
		case 'o': low = 362; high = 365
		case 'p': low = 365; high = 367
		case 'r': low = 367; high = 372
		case 's': low = 372; high = 377
		case 't': low = 377; high = 378
		case 'u': low = 378; high = 379
		case 'v': low = 379; high = 380
		case 'x': low = 380; high = 381
		case:
		}
	case 12:
		switch s[5] {
		case '_': low = 381; high = 385
		case 'b': low = 385; high = 389
		case 'c': low = 389; high = 391
		case 'd': low = 391; high = 393
		case 'e': low = 393; high = 397
		case 'g': low = 397; high = 400
		case 'h': low = 400; high = 401
		case 'i': low = 401; high = 403
		case 'm': low = 403; high = 405
		case 'n': low = 405; high = 407
		case 'o': low = 407; high = 409
		case 'r': low = 409; high = 411
		case 's': low = 411; high = 414
		case 't': low = 414; high = 419
		case 'u': low = 419; high = 421
		case:
		}
	case 13:
		switch s[5] {
		case '_': low = 421; high = 423
		case 'a': low = 423; high = 427
		case 'c': low = 427; high = 428
		case 'd': low = 428; high = 432
		case 'e': low = 432; high = 435
		case 'f': low = 435; high = 438
		case 'g': low = 438; high = 442
		case 'h': low = 442; high = 443
		case 'l': low = 443; high = 447
		case 'm': low = 447; high = 448
		case 'o': low = 448; high = 449
		case 'p': low = 449; high = 450
		case 'r': low = 450; high = 454
		case 's': low = 454; high = 456
		case 't': low = 456; high = 458
		case 'u': low = 458; high = 459
		case 'w': low = 459; high = 460
		case 'x': low = 460; high = 461
		case:
		}
	case 14:
		switch s[5] {
		case '_': low = 461; high = 463
		case 'a': low = 463; high = 465
		case 'b': low = 465; high = 466
		case 'd': low = 466; high = 467
		case 'e': low = 467; high = 470
		case 'g': low = 470; high = 474
		case 'l': low = 474; high = 476
		case 'o': low = 476; high = 479
		case 'p': low = 479; high = 481
		case 's': low = 481; high = 482
		case 't': low = 482; high = 483
		case 'w': low = 483; high = 485
		case:
		}
	case 15:
		switch s[5] {
		case '_': low = 485; high = 486
		case 'b': low = 486; high = 488
		case 'c': low = 488; high = 489
		case 'd': low = 489; high = 492
		case 'g': low = 492; high = 495
		case 'l': low = 495; high = 496
		case 'p': low = 496; high = 498
		case 's': low = 498; high = 501
		case 't': low = 501; high = 504
		case 'w': low = 504; high = 505
		case:
		}
	case 16:
		switch s[9] {
		case '_': low = 505; high = 506
		case 'a': low = 506; high = 508
		case 'c': low = 508; high = 512
		case 'd': low = 512; high = 514
		case 'e': low = 514; high = 515
		case 'g': low = 515; high = 518
		case 'p': low = 518; high = 519
		case 's': low = 519; high = 522
		case 't': low = 522; high = 526
		case 'u': low = 526; high = 527
		case 'w': low = 527; high = 529
		case:
		}
	case 17:
		switch s[9] {
		case '_': low = 529; high = 533
		case 'a': low = 533; high = 534
		case 'c': low = 534; high = 535
		case 'd': low = 535; high = 536
		case 'g': low = 536; high = 539
		case 'h': low = 539; high = 540
		case 'i': low = 540; high = 542
		case 's': low = 542; high = 545
		case 't': low = 545; high = 546
		case:
		}
	case 18:
		switch s[5] {
		case '_': low = 546; high = 548
		case 'b': low = 548; high = 551
		case 'c': low = 551; high = 552
		case 'e': low = 552; high = 553
		case 'g': low = 553; high = 555
		case 'l': low = 555; high = 556
		case 'o': low = 556; high = 557
		case 't': low = 557; high = 558
		case 'w': low = 558; high = 561
		case:
		}
	case 19:
		switch s[14] {
		case '_': low = 561; high = 563
		case 'c': low = 563; high = 564
		case 'e': low = 564; high = 569
		case 'f': low = 569; high = 570
		case 'g': low = 570; high = 571
		case 'o': low = 571; high = 574
		case 'p': low = 574; high = 579
		case 'r': low = 579; high = 580
		case 's': low = 580; high = 581
		case 't': low = 581; high = 583
		case 'u': low = 583; high = 588
		case:
		}
	case 20:
		switch s[17] {
		case 'a': low = 588; high = 591
		case 'b': low = 591; high = 593
		case 'd': low = 593; high = 594
		case 'g': low = 594; high = 595
		case 'i': low = 595; high = 596
		case 'n': low = 596; high = 597
		case 'v': low = 597; high = 600
		case 'w': low = 600; high = 604
		case:
		}
	case 21:
		switch s[9] {
		case 'a': low = 604; high = 605
		case 'c': low = 605; high = 608
		case 'e': low = 608; high = 609
		case 'g': low = 609; high = 612
		case 'o': low = 612; high = 615
		case 'r': low = 615; high = 616
		case 't': low = 616; high = 618
		case 'u': low = 618; high = 619
		case:
		}
	case 22:
		switch s[10] {
		case 'c': low = 619; high = 620
		case 'd': low = 620; high = 621
		case 'g': low = 621; high = 622
		case 'l': low = 622; high = 623
		case 'o': low = 623; high = 624
		case 'r': low = 624; high = 625
		case 'u': low = 625; high = 626
		case:
		}
	case 23:
		switch s[5] {
		case 'c': low = 626; high = 627
		case 'g': low = 627; high = 628
		case 'l': low = 628; high = 629
		case 't': low = 629; high = 630
		case:
		}
	case 24:
		switch s[13] {
		case 'c': low = 630; high = 631
		case 'e': low = 631; high = 633
		case 'o': low = 633; high = 634
		case 'r': low = 634; high = 636
		case 's': low = 636; high = 637
		case 'u': low = 637; high = 638
		case:
		}
	case 25:
		switch s[9] {
		case 'a': low = 638; high = 639
		case 'd': low = 639; high = 640
		case 's': low = 640; high = 641
		case:
		}
	case 26:
		switch s[5] {
		case '_': low = 641; high = 642
		case 'b': low = 642; high = 643
		case 's': low = 643; high = 644
		case:
		}
	case 28:
		switch s[5] {
		case '_': low = 644; high = 645
		case 'b': low = 645; high = 646
		case:
		}
	case:
	}
	i := low
	for i < high {
		nm := (^EvalFuncDef_O)(nvim_odin_funcdef_at_e(i)).name
		if libc.memcmp(rawptr(transmute(^u8)(str)), rawptr(transmute(^u8)(nm)), len) == 0 {
			return i
		}
		i += 1
	}
	return -1
}

// Builtin lookup (eval/funcs.c public).
@(export)
find_internal_func :: proc "c" (name: cstring) -> ^EvalFuncDef_O {
	context = runtime.default_context()
	length := libc.strlen(name)
	index := find_internal_func_hash(name, length)
	if index >= 0 {
		return (^EvalFuncDef_O)(nvim_odin_funcdef_at_e(index))
	}
	return nil
}

// Lua-implemented builtin name (eval/funcs.c public).
@(export)
find_internal_func_lua :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	fdef := find_internal_func(name)
	if fdef != nil && fdef.func == nvim_odin_lua_wrapper_addr_e() {
		return transmute(cstring)(fdef.data)
	}
	return nil
}

// Builtin arity checker (eval/funcs.c public).
@(export)
check_internal_func :: proc "c" (fdef: ^EvalFuncDef_O, argcount: C.int) -> C.int {
	context = runtime.default_context()
	if argcount < C.int(fdef.min_argc) {
		semsg(cstring(E_TOOFEWARG_S), fdef.name)
		return -1
	} else if argcount > C.int(fdef.max_argc) {
		semsg(cstring(E_TOOMANYARG_S), fdef.name)
		return -1
	}
	return C.int(fdef.base_arg)
}

// Builtin direct caller (eval/funcs.c public).
@(export)
call_internal_func :: proc "c" (fname: cstring, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	fdef := find_internal_func(fname)
	if fdef == nil {
		return FCERR_UNKNOWN_O
	} else if argcount < C.int(fdef.min_argc) {
		return FCERR_TOOFEW_O
	} else if argcount > C.int(fdef.max_argc) {
		return FCERR_TOOMANY_O
	}
	([^]Typval_T)(argvars)[argcount].v_type = VAR_UNKNOWN
	fn := transmute(VimLFunc_O)(fdef.func)
	fn(argvars, rettv, fdef.data)
	return FCERR_NONE_O
}

// Builtin method caller (eval/funcs.c public).
@(export)
call_internal_method :: proc "c" (fname: cstring, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T, basetv: rawptr) -> C.int {
	context = runtime.default_context()
	fdef := find_internal_func(fname)
	if fdef == nil {
		return FCERR_UNKNOWN_O
	} else if fdef.base_arg == BASE_NONE_O {
		return FCERR_NOTMETHOD_O
	} else if argcount + 1 < C.int(fdef.min_argc) {
		return FCERR_TOOFEW_O
	} else if argcount + 1 > C.int(fdef.max_argc) {
		return FCERR_TOOMANY_O
	}
	argv: [21]Typval_T
	base_index := argcount
	if fdef.base_arg != BASE_LAST_O {
		base_index = C.int(fdef.base_arg) - 1
	}
	if argcount < base_index {
		return FCERR_TOOFEW_O
	}
	libc.memcpy(rawptr(&argv[0]), rawptr(argvars), C.size_t(base_index) * 16)
	argv[base_index] = (^Typval_T)(basetv)^
	libc.memcpy(rawptr(uintptr(&argv[0]) + uintptr(base_index + 1) * 16), rawptr(uintptr(argvars) + uintptr(base_index) * 16), C.size_t(argcount - base_index) * 16)
	argv[argcount + 1].v_type = VAR_UNKNOWN
	fn := transmute(VimLFunc_O)(fdef.func)
	fn(&argv[0], rettv, fdef.data)
	return FCERR_NONE_O
}

// Expand-iterator over internal + user functions (eval/funcs.c public).
@(export)
get_function_name :: proc "c" (xp: ^expand_T, idx: C.int) -> cstring {
	context = runtime.default_context()
	if idx == 0 {
		get_function_name_intidx_g = -1
	}
	if get_function_name_intidx_g < 0 {
		name := get_user_func_name(xp, idx)
		if name != nil {
			if ([^]u8)(name)[0] != 0 && ([^]u8)(name)[0] != '<' && libc.strncmp(xp.xp_pattern, cstring("g:"), 2) == 0 {
				return cat_prefix_varname('g', name)
			}
			return name
		}
	}
	key := (^EvalFuncDef_O)(nvim_odin_funcdef_at_e(get_function_name_intidx_g + 1)).name
	if key == nil {
		return nil
	}
	get_function_name_intidx_g += 1
	key_len := libc.strlen(key)
	libc.memcpy(rawptr(&IObuff[0]), rawptr(transmute(^u8)(key)), key_len)
	([^]u8)(&IObuff[0])[key_len] = '('
	if (^EvalFuncDef_O)(nvim_odin_funcdef_at_e(get_function_name_intidx_g)).max_argc == 0 {
		([^]u8)(&IObuff[0])[key_len + 1] = ')'
		([^]u8)(&IObuff[0])[key_len + 2] = 0
	} else {
		([^]u8)(&IObuff[0])[key_len + 1] = 0
	}
	return transmute(cstring)(&IObuff[0])
}

// Expand-iterator over functions + variables (eval/funcs.c public).
@(export)
get_expr_name :: proc "c" (xp: ^expand_T, idx: C.int) -> cstring {
	context = runtime.default_context()
	if idx == 0 {
		get_expr_name_intidx_g = -1
	}
	if get_expr_name_intidx_g < 0 {
		name := get_function_name(xp, idx)
		if name != nil {
			return name
		}
	}
	return get_user_var_name(xp, get_expr_name_intidx_g + 1)
}

// —— Batch 28bm: eval/funcs.c do_searchpair (export + weak) ——
foreign _ {
	@(link_name = "decl")
	decl_pos_e :: proc "c" (p: ^Pos_T) -> C.int ---
	@(link_name = "incl")
	incl_pos_e :: proc "c" (p: ^Pos_T) -> C.int ---
}

// Nested-pair search driver (eval/funcs.c public).
@(export)
do_searchpair :: proc "c" (spat: cstring, mpat: cstring, epat: cstring, dir: C.int, skip: ^Typval_T, flags: C.int, match_pos: ^Pos_T, lnum_stop: C.int, time_limit: i64) -> C.int {
	context = runtime.default_context()
	retval: C.int = 0
	nest: C.int = 1
	use_skip := false
	options: C.int = SEARCH_KEEP_O
	save_cpo := p_cpo
	p_cpo = empty_string_opt()
	tm := profile_setlimit(C.longlong(time_limit))
	spatlen := libc.strlen(spat)
	epatlen := libc.strlen(epat)
	pat2size := C.size_t(spatlen + epatlen + 17)
	pat2 := (^u8)(xmalloc(pat2size))
	pat3size := C.size_t(spatlen + libc.strlen(mpat) + epatlen + 25)
	pat3 := (^u8)(xmalloc(pat3size))
	pat2len := C.int(libc.snprintf(pat2, pat2size, cstring("\\m\\(%s\\m\\)\\|\\(%s\\m\\)"), spat, epat))
	pat3len: C.int = 0
	if ([^]u8)(mpat)[0] == 0 {
		libc.strcpy(transmute([^]u8)(pat3), transmute(cstring)(pat2))
		pat3len = pat2len
	} else {
		pat3len = C.int(libc.snprintf(pat3, pat3size, cstring("\\m\\(%s\\m\\)\\|\\(%s\\m\\)\\|\\(%s\\m\\)"), spat, epat, mpat))
	}
	if (flags & SP_START_O) != 0 {
		options |= SEARCH_START_O
	}
	if skip != nil {
		use_skip = eval_expr_valid_arg(skip)
	}
	save_cursor := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	firstpos := Pos_T{}
	foundpos := Pos_T{}
	pat := pat3
	patlen := C.size_t(pat3len)
	for {
		sia := searchit_arg_T{}
		sia.sa_stop_lnum = lnum_stop
		sia.sa_tm = &tm
		n := searchit(curwin, curbuf, &pos, nil, Direction(dir), pat, patlen, 1, options, RE_SEARCH_O, &sia)
		if n == FAIL_E || (firstpos.lnum != 0 && pos_equal_o(pos, firstpos)) {
			break
		}
		if firstpos.lnum == 0 {
			firstpos = pos
		}
		if pos_equal_o(pos, foundpos) {
			if dir == C.int(Direction.BACKWARD) {
				decl_pos_e(&pos)
			} else {
				incl_pos_e(&pos)
			}
		}
		foundpos = pos
		options &= ~C.int(SEARCH_START_O)
		if use_skip {
			save_pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			err := false
			r := eval_expr_to_bool(skip, &err)
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_pos
			if err {
				(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
				retval = -1
				break
			}
			if r {
				continue
			}
		}
		if (dir == C.int(Direction.BACKWARD) && n == 3) || (dir == C.int(Direction.FORWARD) && n == 2) {
			nest += 1
			pat = pat2
		} else {
			nest -= 1
			if nest == 1 {
				pat = pat3
			}
		}
		if nest == 0 {
			if (flags & SP_RETCOUNT_O) != 0 {
				retval += 1
			} else {
				retval = pos.lnum
			}
			if (flags & SP_SETPCMARK_O) != 0 {
				setpcmark()
			}
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			if (flags & SP_REPEAT_O) == 0 {
				break
			}
			nest = 1
		}
	}
	if match_pos != nil {
		match_pos.lnum = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).lnum
		match_pos.col = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF).col + 1
	}
	if ((flags & SP_NOMOVE_O) != 0) || retval == 0 {
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
	}
	xfree(pat2)
	xfree(pat3)
	if p_cpo == empty_string_opt() {
		p_cpo = save_cpo
	} else {
		if ([^]u8)(p_cpo)[0] == 0 {
			set_option_value_give_err(kOptCpoptions_E, str_optval(save_cpo, libc.strlen(transmute(cstring)(save_cpo))), 0)
		}
		free_string_option(p_cpo)
	}
	return retval
}

// —— Batch 28bl: eval/funcs.c create_environment (export + weak) ——
foreign _ {
	@(link_name = "uv_os_environ")
	uv_os_environ_e :: proc "c" (envitems: ^rawptr, count: ^C.int) -> C.int ---
	@(link_name = "uv_os_free_environ")
	uv_os_free_environ_e :: proc "c" (envitems: rawptr, count: C.int) ---
	@(link_name = "p_tgc")
	p_tgc_g: C.int
}

// uv_env_item_T mirror (uv.h): {name@0, value@8}, 16B.
Uv_Env_Item_O :: struct {
	name:  cstring,
	value: cstring,
}

VV_SEND_SERVER_O :: 28

@(private = "file")
pty_ignored_env_g: [7]cstring = {"COLUMNS", "LINES", "TERMCAP", "COLORFGBG", "COLORTERM", "VIM", "VIMRUNTIME"}

// Child-process environment dict builder (eval/funcs.c public).
@(export)
create_environment :: proc "c" (job_env: rawptr, clear_env: bool, pty: bool, set_nvim_addr: bool, pty_term_name: cstring) -> rawptr {
	context = runtime.default_context()
	env := tv_dict_alloc()
	if !clear_env {
		envitems: rawptr = nil
		envcount: C.int = 0
		if uv_os_environ_e(&envitems, &envcount) == 0 {
			i: C.int = 0
			for i < envcount {
				item := (^Uv_Env_Item_O)(uintptr(envitems) + uintptr(i) * 16)
				tv_dict_add_str(env, item.name, libc.strlen(item.name), item.value)
				i += 1
			}
			uv_os_free_environ_e(envitems, envcount)
		}
		if pty {
			for j := 0; j < 7; j += 1 {
				dv := tv_dict_find(env, pty_ignored_env_g[j], -1)
				if dv != nil {
					tv_dict_item_remove(env, dv)
				}
			}
			if p_tgc_g != 0 {
				tv_dict_add_str(env, cstring("COLORTERM"), 9, cstring("truecolor"))
			}
		}
	}
	if pty {
		dv := tv_dict_find(env, cstring("TERM"), 4)
		if dv != nil {
			tv_dict_item_remove(env, dv)
		}
		tv_dict_add_str(env, cstring("TERM"), 4, pty_term_name)
	}
	if set_nvim_addr {
		nvim_addr := get_vim_var_str(VV_SEND_SERVER_O)
		if nvim_addr != nil && ([^]u8)(nvim_addr)[0] != 0 {
			dv := tv_dict_find(env, cstring("NVIM"), 4)
			if dv != nil {
				tv_dict_item_remove(env, dv)
			}
			tv_dict_add_str(env, cstring("NVIM"), 4, nvim_addr)
		}
	}
	if job_env != nil {
		tv_dict_extend(env, rawptr((^Typval_T)(job_env).vval), cstring("force"))
	}
	return env
}

foreign _ {
	@(link_name = "vim_isAbsName")
	vim_isAbsName_e :: proc "c" (name: cstring) -> bool ---
}

// —— Batch 28bk: eval/fs.c modify_fname (export + weak, closes fs.c) ——
VALID_PATH_O :: 1
VALID_HEAD_O :: 2

// Filename-modifier engine (:p:.:~:h:t:e:r:s:S) (eval/fs.c public).
@(export)
modify_fname :: proc "c" (src: ^u8, tilde_file: bool, usedlen: ^C.size_t, fnamep: ^rawptr, bufp: ^rawptr, fnamelen: ^C.size_t) -> C.int {
	context = runtime.default_context()
	valid: C.int = 0
	dirname: [4096]u8
	has_fullname := false
	has_homerelative := false
	c: C.int = 0
	for {
		didit := false
		s_raw := transmute(cstring)(src)
		if ([^]u8)(s_raw)[usedlen^] == ':' && ([^]u8)(s_raw)[usedlen^ + 1] == 'p' {
			has_fullname = true
			valid |= VALID_PATH_O
			usedlen^ += 2
			fp := transmute(cstring)(fnamep^)
			if ([^]u8)(fp)[0] == '~' && !(tilde_file && ([^]u8)(fp)[1] == 0) {
				fp = expand_env_save(fp)
				xfree(bufp^)
				bufp^ = rawptr(transmute(^u8)(fp))
				fnamep^ = rawptr(transmute(^u8)(fp))
				if fp == nil {
					return -1
				}
			}
			p := transmute(cstring)(fnamep^)
			for ([^]u8)(p)[0] != 0 {
				if _vim_ispathsep(C.int(([^]u8)(p)[0])) && ([^]u8)(p)[1] == '.' && (([^]u8)(p)[2] == 0 || _vim_ispathsep(C.int(([^]u8)(p)[2])) || (([^]u8)(p)[2] == '.' && (([^]u8)(p)[3] == 0 || _vim_ispathsep(C.int(([^]u8)(p)[3]))))) {
					break
				}
				p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
			}
			if ([^]u8)(p)[0] != 0 || !vim_isAbsName_e(transmute(cstring)(fnamep^)) {
				fp2 := FullName_save_e(transmute(cstring)(fnamep^), ([^]u8)(p)[0] != 0)
				xfree(bufp^)
				bufp^ = rawptr(fp2)
				fnamep^ = rawptr(fp2)
				if fp2 == nil {
					return -1
				}
			}
			if os_isdir(transmute(cstring)(fnamep^)) {
				fp3 := xstrnsave_c(transmute(cstring)(fnamep^), libc.strlen(transmute(cstring)(fnamep^)) + 2)
				xfree(bufp^)
				bufp^ = rawptr(fp3)
				fnamep^ = rawptr(fp3)
				add_pathsep(transmute(^u8)(fnamep^))
			}
		}
		for {
			if ([^]u8)(s_raw)[usedlen^] != ':' {
				break
			}
			c = C.int(([^]u8)(s_raw)[usedlen^ + 1])
			if c != '.' && c != '~' && c != '8' {
				break
			}
			usedlen^ += 2
			if c == '8' {
				continue
			}
			pbuf: rawptr = nil
			p: cstring = nil
			if !has_fullname && !has_homerelative {
				if ([^]u8)(transmute(cstring)(fnamep^))[0] == '~' {
					p = transmute(cstring)(expand_env_save(transmute(cstring)(fnamep^)))
					pbuf = rawptr(transmute(^u8)(p))
				} else {
					p = transmute(cstring)(FullName_save_e(transmute(cstring)(fnamep^), false))
					pbuf = rawptr(transmute(^u8)(p))
				}
			} else {
				p = transmute(cstring)(fnamep^)
			}
			has_fullname = false
			if p != nil {
				dirnamelen: C.size_t = 0
				if c == '.' {
					os_dirname(transmute(cstring)(&dirname[0]), 4096)
					if has_homerelative {
						s := xstrdup_o(transmute(^u8)(&dirname[0]))
						dirnamelen = home_replace(nil, transmute(cstring)(s), transmute(cstring)(&dirname[0]), 4096, true)
						xfree(rawptr(s))
					}
					if dirnamelen == 0 {
						dirnamelen = libc.strlen(transmute(cstring)(&dirname[0]))
					}
					if _path_fnamencmp(p, transmute(cstring)(&dirname[0]), C.int(dirnamelen)) == 0 {
						p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(dirnamelen))
						if _vim_ispathsep(C.int(([^]u8)(p)[0])) {
							for ([^]u8)(p)[0] != 0 && _vim_ispathsep(C.int(([^]u8)(p)[0])) {
								p = transmute(cstring)(uintptr(rawptr(p)) + 1)
							}
							fnamep^ = rawptr(transmute(^u8)(p))
							if pbuf != nil {
								xfree(bufp^)
								bufp^ = pbuf
								pbuf = nil
							}
						}
					}
				} else {
					dirnamelen = home_replace(nil, p, transmute(cstring)(&dirname[0]), 4096, true)
					if ([^]u8)(&dirname[0])[0] == '~' {
						s := xmemdupz_o2(transmute(^u8)(&dirname[0]), dirnamelen)
						fnamep^ = rawptr(s)
						xfree(bufp^)
						bufp^ = rawptr(s)
						has_homerelative = true
					}
				}
				xfree(pbuf)
			}
		}
		fi := FileInfo{}
		os_fileinfo2(transmute(cstring)(fnamep^), &fi)
		s: cstring = nil
		if ([^]u8)(s_raw)[usedlen^] == ':' && ([^]u8)(s_raw)[usedlen^ + 1] == 'h' {
			s = transmute(cstring)(uintptr(rawptr(fnamep^)) + uintptr(fi.rest_off))
			fnamep^ = rawptr(uintptr(rawptr(fnamep^)) + uintptr(fi.prefix_off))
		}
		tail := transmute(cstring)(path_tail_e(transmute(cstring)(fnamep^)))
		fnamelen^ = libc.strlen(transmute(cstring)(fnamep^))
		for ([^]u8)(s_raw)[usedlen^] == ':' && ([^]u8)(s_raw)[usedlen^ + 1] == 'h' {
			valid |= VALID_HEAD_O
			usedlen^ += 2
			for uintptr(rawptr(tail)) > uintptr(rawptr(s)) && _after_pathsep(s, tail) != 0 {
				tail = transmute(cstring)(mb_ptr_back(transmute(^u8)(fnamep^), transmute(^u8)(tail)))
			}
			if uintptr(rawptr(tail)) <= uintptr(rawptr(s)) {
				fnamelen^ = C.size_t(uintptr(rawptr(s)) - uintptr(rawptr(fnamep^)))
			} else {
				fnamelen^ = C.size_t(uintptr(rawptr(tail)) - uintptr(rawptr(fnamep^)))
			}
			if fnamelen^ == 0 {
				xfree(bufp^)
				dot := xstrdup_o(transmute(^u8)(cstring(".")))
				bufp^ = rawptr(dot)
				fnamep^ = rawptr(dot)
				tail = transmute(cstring)(dot)
				fnamelen^ = 1
			} else {
				for uintptr(rawptr(tail)) > uintptr(rawptr(s)) && _after_pathsep(s, tail) == 0 {
					tail = transmute(cstring)(mb_ptr_back(transmute(^u8)(fnamep^), transmute(^u8)(tail)))
				}
			}
		}
		if ([^]u8)(s_raw)[usedlen^] == ':' && ([^]u8)(s_raw)[usedlen^ + 1] == '8' {
			usedlen^ += 2
		}
		if ([^]u8)(s_raw)[usedlen^] == ':' && ([^]u8)(s_raw)[usedlen^ + 1] == 't' {
			usedlen^ += 2
			fnamelen^ -= C.size_t(uintptr(rawptr(tail)) - uintptr(rawptr(fnamep^)))
			fnamep^ = rawptr(transmute(^u8)(tail))
		}
		for ([^]u8)(s_raw)[usedlen^] == ':' && (([^]u8)(s_raw)[usedlen^ + 1] == 'e' || ([^]u8)(s_raw)[usedlen^ + 1] == 'r') {
			is_second_e := uintptr(rawptr(fnamep^)) > uintptr(rawptr(tail))
			if ([^]u8)(s_raw)[usedlen^ + 1] == 'e' && is_second_e {
				s = transmute(cstring)(uintptr(rawptr(fnamep^)) - 2)
			} else {
				s = transmute(cstring)(uintptr(rawptr(fnamep^)) + uintptr(fnamelen^) - 1)
			}
			for uintptr(rawptr(s)) > uintptr(rawptr(tail)) {
				if ([^]u8)(s)[0] == '.' {
					break
				}
				s = transmute(cstring)(uintptr(rawptr(s)) - 1)
			}
			if ([^]u8)(s_raw)[usedlen^ + 1] == 'e' {
				if uintptr(rawptr(s)) > uintptr(rawptr(tail)) {
					newstart := transmute(cstring)(uintptr(rawptr(s)) + 1)
					fnamelen^ += C.size_t(uintptr(rawptr(fnamep^)) - uintptr(rawptr(newstart)))
					fnamep^ = rawptr(transmute(^u8)(newstart))
				} else if uintptr(rawptr(fnamep^)) <= uintptr(rawptr(tail)) {
					fnamelen^ = 0
				}
			} else {
				t1 := tail
				f1 := transmute(cstring)(fnamep^)
				maxs := t1
				if uintptr(rawptr(f1)) > uintptr(rawptr(t1)) {
					maxs = f1
				}
				if uintptr(rawptr(s)) > uintptr(rawptr(maxs)) {
					fnamelen^ = C.size_t(uintptr(rawptr(s)) - uintptr(rawptr(fnamep^)))
				}
			}
			usedlen^ += 2
		}
		if ([^]u8)(s_raw)[usedlen^] == ':' && (([^]u8)(s_raw)[usedlen^ + 1] == 's' || (([^]u8)(s_raw)[usedlen^ + 1] == 'g' && ([^]u8)(s_raw)[usedlen^ + 2] == 's')) {
			s = transmute(cstring)(uintptr(rawptr(s_raw)) + uintptr(usedlen^) + 2)
			flags := cstring("")
			if ([^]u8)(s_raw)[usedlen^ + 1] == 'g' {
				flags = cstring("g")
				s = transmute(cstring)(uintptr(rawptr(s)) + 1)
			}
			sep := C.int(([^]u8)(s)[0])
			s = transmute(cstring)(uintptr(rawptr(s)) + 1)
			if sep != 0 {
				p := _vim_strchr(s, sep)
				if p != nil {
					pat := xmemdupz_o2(transmute(^u8)(s), C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(s))))
					s = transmute(cstring)(uintptr(rawptr(p)) + 1)
					p = _vim_strchr(s, sep)
					if p != nil {
						sub := xmemdupz_o2(transmute(^u8)(s), C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(s))))
						str := xmemdupz_o2(transmute(^u8)(fnamep^), fnamelen^)
						usedlen^ = C.size_t(uintptr(rawptr(p)) + 1 - uintptr(rawptr(s_raw)))
						slen: C.size_t = 0
						s = do_string_sub(transmute(cstring)(str), fnamelen^, transmute(cstring)(pat), transmute(cstring)(sub), nil, flags, &slen)
						fnamep^ = rawptr(transmute(^u8)(s))
						fnamelen^ = slen
						xfree(bufp^)
						bufp^ = rawptr(transmute(^u8)(s))
						didit = true
						xfree(rawptr(sub))
						xfree(rawptr(str))
					}
					xfree(rawptr(pat))
				}
				if didit {
					continue
				}
			}
		}
		break
	}
	if ([^]u8)(transmute(cstring)(src))[usedlen^] == ':' && ([^]u8)(transmute(cstring)(src))[usedlen^ + 1] == 'S' {
		c2 := ([^]u8)(transmute(cstring)(fnamep^))[fnamelen^]
		if c2 != 0 {
			([^]u8)(transmute(cstring)(fnamep^))[fnamelen^] = 0
		}
		p2 := vim_strsave_shellescape_e(transmute(cstring)(fnamep^), false, false)
		if c2 != 0 {
			([^]u8)(transmute(cstring)(fnamep^))[fnamelen^] = c2
		}
		xfree(bufp^)
		bufp^ = rawptr(p2)
		fnamep^ = rawptr(p2)
		fnamelen^ = libc.strlen(transmute(cstring)(p2))
		usedlen^ += 2
	}
	return valid
}

// —— Batch 28be: eval.c name-end + source/verbose message leaves ——
foreign _ {
	@(link_name = "get_scriptname")
	get_scriptname_e :: proc "c" (ctx: sctx_T, should_free: ^bool) -> cstring ---
	@(link_name = "line_msg")
	line_msg_e: cstring
	@(link_name = "msg_ext_skip_verbose")
	msg_ext_skip_verbose_e: bool
}

// Variable/function name end scanner (eval.c public).
@(export)
find_name_end :: proc "c" (arg: cstring, expr_start: ^cstring, expr_end: ^cstring, flags: C.int) -> cstring {
	context = runtime.default_context()
	if expr_start != nil {
		expr_start^ = nil
		expr_end^ = nil
	}
	if (flags & FNE_CHECK_START_O) != 0 && !eval_isnamec1(C.int(([^]u8)(arg)[0])) && ([^]u8)(arg)[0] != '{' {
		return arg
	}
	mb_nest: C.int = 0
	br_nest: C.int = 0
	length: C.int = 0
	p := arg
	for ([^]u8)(p)[0] != 0 && (eval_isnamec(C.int(([^]u8)(p)[0])) || ([^]u8)(p)[0] == '{' || ((flags & FNE_INCL_BR_O) != 0 && (([^]u8)(p)[0] == '[' || (([^]u8)(p)[0] == '.' && eval_isdictc(C.int(([^]u8)(p)[1]))))) || mb_nest != 0 || br_nest != 0) {
		if ([^]u8)(p)[0] == '\'' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '\'' {
				p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
			}
			if ([^]u8)(p)[0] == 0 {
				break
			}
		} else if ([^]u8)(p)[0] == '"' {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' {
				if ([^]u8)(p)[0] == '\\' && ([^]u8)(p)[1] != 0 {
					p = transmute(cstring)(uintptr(rawptr(p)) + 1)
				}
				p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
			}
			if ([^]u8)(p)[0] == 0 {
				break
			}
		} else if br_nest == 0 && mb_nest == 0 && ([^]u8)(p)[0] == ':' {
			length = C.int(uintptr(rawptr(p)) - uintptr(rawptr(arg)))
			prev_close := ([^]u8)(uintptr(rawptr(p)) - 1)[0] == '}'
			c0 := ([^]u8)(arg)[0]
			in_ns := c0 == 'a' || c0 == 'b' || c0 == 'g' || c0 == 'l' || c0 == 's' || c0 == 't' || c0 == 'v' || c0 == 'w'
			if ((length > 1 && !prev_close) || (length == 1 && !in_ns)) {
				break
			}
		}
		if mb_nest == 0 {
			if ([^]u8)(p)[0] == '[' {
				br_nest += 1
			} else if ([^]u8)(p)[0] == ']' {
				br_nest -= 1
			}
		}
		if br_nest == 0 {
			if ([^]u8)(p)[0] == '{' {
				mb_nest += 1
				if expr_start != nil && expr_start^ == nil {
					expr_start^ = p
				}
			} else if ([^]u8)(p)[0] == '}' {
				mb_nest -= 1
				if expr_start != nil && mb_nest == 0 && expr_end^ == nil {
					expr_end^ = p
				}
			}
		}
		p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
	}
	return p
}

// "file:lnum" source string (eval.c public).
@(export)
eval_fmt_source_name_line :: proc "c" (buf: cstring, bufsize: C.size_t) {
	context = runtime.default_context()
	if exestack.ga_len > 0 {
		idx := int(exestack.ga_len - 1)
		name := ([^]Estack)(exestack.ga_data)[idx].es_name
		if name != nil {
			libc.snprintf(transmute([^]u8)(buf), bufsize, cstring("%s:%d"), name, ([^]Estack)(exestack.ga_data)[idx].es_lnum)
			return
		}
	}
	libc.snprintf(transmute([^]u8)(buf), bufsize, cstring("?"))
}

// Verbose "Last set from" message (eval.c public).
@(export)
last_set_msg :: proc "c" (script_ctx: sctx_T) {
	context = runtime.default_context()
	if script_ctx.sc_sid == 0 {
		return
	}
	should_free := false
	p := get_scriptname_e(script_ctx, &should_free)
	msg_ext_skip_verbose_e = true
	verbose_enter()
	msg_puts(cstring("\n\tLast set from "))
	msg_puts(p)
	if script_ctx.sc_lnum > 0 {
		msg_puts(line_msg_e)
		msg_outnum(C.int(script_ctx.sc_lnum))
	} else if script_is_lua_e(script_ctx.sc_sid) {
		msg_puts(cstring(" (run Nvim with -V1 for more details)"))
	}
	if should_free {
		xfree(rawptr(transmute(^u8)(p)))
	}
	verbose_leave()
}

// —— Batch 28bj: eval/window.c noblock pair (exports + weak, closes window.c) ——

// Window/tab switch without autocmd blocking (eval/window.c public).
@(export)
switch_win_noblock :: proc "c" (switchwin: rawptr, win: rawptr, tp: rawptr, no_display: bool) -> C.int {
	context = runtime.default_context()
	sw := (^Switchwin_T)(switchwin)
	libc.memset(switchwin, 0, size_of(Switchwin_T))
	sw.sw_curwin = curwin
	if win == curwin {
		sw.sw_same_win = true
	} else {
		sw.sw_visual_active = VIsual_active
		VIsual_active = false
	}
	if tp != nil {
		sw.sw_curtab = curtab
		if no_display {
			unuse_tabpage(curtab)
			use_tabpage(tp)
		} else {
			goto_tabpage_tp(tp, false, false)
		}
	}
	if !win_valid(win) {
		return FAIL_E
	}
	curwin = win
	curbuf = (^rawptr)(uintptr(win) + W_BUFFER_OFF)^
	return OK_E
}

// Restore tabpage/window saved by switch_win (eval/window.c public).
@(export)
restore_win_noblock :: proc "c" (switchwin: rawptr, no_display: bool) {
	context = runtime.default_context()
	sw := (^Switchwin_T)(switchwin)
	if sw.sw_curtab != nil && valid_tabpage(sw.sw_curtab) {
		if no_display {
			old_tp_curwin := (^rawptr)(uintptr(curtab) + TP_CURWIN_OFF)^
			unuse_tabpage(curtab)
			(^rawptr)(uintptr(curtab) + TP_CURWIN_OFF)^ = old_tp_curwin
			use_tabpage(sw.sw_curtab)
		} else {
			goto_tabpage_tp(sw.sw_curtab, false, false)
		}
	}
	if !sw.sw_same_win {
		VIsual_active = sw.sw_visual_active
	}
	if win_valid(sw.sw_curwin) {
		curwin = sw.sw_curwin
		curbuf = (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	}
}

// —— Batch 28bi: eval.c garbage_collect (export + weak, last big one) ——
foreign _ {
	@(link_name = "may_garbage_collect")
	may_garbage_collect_g: bool
	@(link_name = "set_ref_in_insexpand_funcs")
	set_ref_in_insexpand_funcs_e :: proc "c" (copyID: C.int) -> bool ---
	@(link_name = "set_ref_in_opfunc")
	set_ref_in_opfunc_e :: proc "c" (copyID: C.int) -> bool ---
	@(link_name = "set_ref_in_tagfunc")
	set_ref_in_tagfunc_e :: proc "c" (copyID: C.int) -> bool ---
	@(link_name = "set_ref_in_findfunc")
	set_ref_in_findfunc_e :: proc "c" (copyID: C.int) -> bool ---
	@(link_name = "set_ref_in_quickfix")
	set_ref_in_quickfix_e :: proc "c" (copyID: C.int) -> bool ---
	@(link_name = "set_ref_in_cpt_callbacks")
	set_ref_in_cpt_callbacks_e :: proc "c" (callbacks: rawptr, count: C.int, copyID: C.int) -> bool ---
}

COPYID_MASK_O :: ~C.int(1)
CHAN_ON_DATA_OFF_O :: 1856
CHAN_ON_STDERR_OFF_O :: 1920
CHAN_ON_EXIT_OFF_O :: 1984

// Free unreferenced lists/dicts (eval.c static).
free_unref_items_o :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	did_free := false
	tv_in_free_unref_items = true
	dd := gc_first_dict
	for dd != nil {
		if ((^C.int)(uintptr(dd) + 12)^ & COPYID_MASK_O) != (copyID & COPYID_MASK_O) {
			tv_dict_free_contents(dd)
			did_free = true
		}
		dd = (^rawptr)(uintptr(dd) + 320)^
	}
	ll := gc_first_list
	for ll != nil {
		if ((^C.int)(uintptr(ll) + 68)^ & COPYID_MASK_O) != (copyID & COPYID_MASK_O) && (^rawptr)(uintptr(ll) + 16)^ == nil {
			tv_list_free_contents(ll)
			did_free = true
		}
		ll = (^rawptr)(uintptr(ll) + 40)^
	}
	dd_next: rawptr = nil
	dd = gc_first_dict
	for dd != nil {
		dd_next = (^rawptr)(uintptr(dd) + 320)^
		if ((^C.int)(uintptr(dd) + 12)^ & COPYID_MASK_O) != (copyID & COPYID_MASK_O) {
			tv_dict_free_dict(dd)
		}
		dd = dd_next
	}
	ll_next: rawptr = nil
	ll = gc_first_list
	for ll != nil {
		ll_next = (^rawptr)(uintptr(ll) + 40)^
		if ((^C.int)(uintptr(ll) + 68)^ & COPYID_MASK_O) != (copyID & COPYID_MASK_O) && (^rawptr)(uintptr(ll) + 16)^ == nil {
			tv_list_free_list(ll)
		}
		ll = ll_next
	}
	tv_in_free_unref_items = false
	return did_free
}

// Full garbage-collection pass (eval.c public).
@(export)
garbage_collect :: proc "c" (testing: bool) -> bool {
	context = runtime.default_context()
	abort := false
	if !testing {
		want_garbage_collect_g = false
		may_garbage_collect_g = false
		garbage_collect_at_exit_g = false
	}
	if exestack.ga_maxlen - exestack.ga_len > 500 {
		n := exestack.ga_len / 2
		if n < exestack.ga_growsize {
			n = exestack.ga_growsize
		}
		if exestack.ga_len + n < exestack.ga_maxlen {
			new_len := C.size_t(exestack.ga_itemsize) * C.size_t(exestack.ga_len + n)
			exestack.ga_data = rawptr(xrealloc(exestack.ga_data, new_len))
			exestack.ga_maxlen = exestack.ga_len + n
		}
	}
	copyID := get_copyID()
	if !abort {
		abort = set_ref_in_previous_funccal(copyID)
	}
	if !abort {
		abort = garbage_collect_scriptvars(copyID)
	}
	buf := firstbuf
	for buf != nil {
		if !abort {
			abort = set_ref_in_item((^Typval_T)(uintptr(buf) + B_BUFVAR_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_PROMPT_CB_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_PROMPT_INT_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_CFU_CB_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_OFU_CB_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_TSRFU_CB_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_TFU_CB_OFF), copyID, nil, nil)
		}
		if !abort {
			abort = set_ref_in_callback((^Callback_E)(uintptr(buf) + B_FFU_CB_OFF), copyID, nil, nil)
		}
		if !abort && (^rawptr)(uintptr(buf) + B_P_CPT_CB_OFF)^ != nil {
			abort = set_ref_in_cpt_callbacks_e((^rawptr)(uintptr(buf) + B_P_CPT_CB_OFF)^, (^C.int)(uintptr(buf) + B_P_CPT_COUNT_OFF)^, copyID)
		}
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}
	if !abort {
		abort = set_ref_in_insexpand_funcs_e(copyID)
	}
	if !abort {
		abort = set_ref_in_opfunc_e(copyID)
	}
	if !abort {
		abort = set_ref_in_tagfunc_e(copyID)
	}
	if !abort {
		abort = set_ref_in_findfunc_e(copyID)
	}
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if !abort {
				abort = set_ref_in_item((^Typval_T)(uintptr(wp) + W_WINVAR_OFF), copyID, nil, nil)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	i: u32 = 0
	for i < u32(aucmd_win_vec_g.size) {
		auw := rawptr(uintptr(aucmd_win_vec_g.items) + uintptr(i) * 16)
		if (^rawptr)(uintptr(auw))^ != nil {
			if !abort {
				abort = set_ref_in_item((^Typval_T)(uintptr((^rawptr)(uintptr(auw))^) + W_WINVAR_OFF), copyID, nil, nil)
			}
		}
		i += 1
	}
	tp = first_tabpage
	for tp != nil {
		if !abort {
			abort = set_ref_in_item((^Typval_T)(uintptr(tp) + TP_WINVAR_OFF), copyID, nil, nil)
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	if !abort {
		abort = garbage_collect_globvars(copyID) != 0
	}
	if !abort {
		abort = set_ref_in_call_stack(copyID)
	}
	if !abort {
		abort = set_ref_in_functions(copyID)
	}
	i = 0
	for i < channels_g.set.h.n_buckets {
		if !mh_is_empty(&channels_g.set.h, i) && !mh_is_del(&channels_g.set.h, i) {
			data := channels_g.values[channels_g.set.h.hash[i] - 1]
			set_ref_in_callback_reader_o(rawptr(uintptr(data) + CHAN_ON_DATA_OFF_O), copyID, nil, nil)
			set_ref_in_callback_reader_o(rawptr(uintptr(data) + CHAN_ON_STDERR_OFF_O), copyID, nil, nil)
			set_ref_in_callback(transmute(^Callback_E)(uintptr(data) + CHAN_ON_EXIT_OFF_O), copyID, nil, nil)
		}
		i += 1
	}
	i = 0
	for i < timers_g.set.h.n_buckets {
		if !mh_is_empty(&timers_g.set.h, i) && !mh_is_del(&timers_g.set.h, i) {
			timer := timers_g.values[timers_g.set.h.hash[i] - 1]
			set_ref_in_callback(transmute(^Callback_E)(uintptr(timer) + 224), copyID, nil, nil)
		}
		i += 1
	}
	if !abort {
		abort = set_ref_in_func_args(copyID)
	}
	if !abort {
		abort = garbage_collect_vimvars(copyID)
	}
	if !abort {
		abort = set_ref_in_quickfix_e(copyID)
	}
	did_free := false
	if !abort {
		did_free = free_unref_items_o(copyID)
		did_free = free_unref_funccal(copyID, testing) || did_free
	} else if p_verbose > 0 {
		verb_msg_r(cstring("Not enough memory to set references, garbage collection aborted!"))
	}
	return did_free
}

// —— Batch 28bh: eval.c prompt cluster (exports + weak) ——
foreign _ {
	@(link_name = "ml_delete_buf")
	ml_delete_buf_e :: proc "c" (buf: rawptr, lnum: C.int, message: bool) -> C.int ---
	@(link_name = "deleted_lines_buf")
	deleted_lines_buf_e :: proc "c" (buf: rawptr, lnum: C.int, count: C.int) ---
}

// v:event dict accessor with recursive-save (eval.c public).
@(export)
get_v_event :: proc "c" (sve: rawptr) -> rawptr {
	context = runtime.default_context()
	v_event := get_vim_var_dict(VV_EVENT_O)
	if (^C.size_t)(uintptr(v_event) + 16 + 8)^ > 0 {
		([^]u8)(sve)[0] = 1
		libc.memcpy(rawptr(uintptr(sve) + 8), rawptr(uintptr(v_event) + 16), 296)
		hash_init(rawptr(uintptr(v_event) + 16))
	} else {
		([^]u8)(sve)[0] = 0
	}
	return v_event
}

// v:event dict restorer (eval.c public).
@(export)
restore_v_event :: proc "c" (v_event: rawptr, sve: rawptr) {
	context = runtime.default_context()
	tv_dict_free_contents(v_event)
	if ([^]u8)(sve)[0] != 0 {
		libc.memcpy(rawptr(uintptr(v_event) + 16), rawptr(uintptr(sve) + 8), 296)
	} else {
		hash_init(rawptr(uintptr(v_event) + 16))
	}
}

// Prompt-buffer input reader (eval.c public).
@(export)
prompt_get_input :: proc "c" (buf: rawptr) -> cstring {
	context = runtime.default_context()
	if !bt_prompt(buf) {
		return nil
	}
	lnum_start := (^C.int)(uintptr(buf) + B_PROMPT_START)^
	lnum_last := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
	text := ml_get_buf(buf, lnum_start)
	if C.int(libc.strlen(transmute(cstring)(text))) >= (^C.int)(uintptr(buf) + B_PROMPT_START + 4)^ {
		text = transmute(^u8)(uintptr(rawptr(text)) + uintptr((^C.int)(uintptr(buf) + B_PROMPT_START + 4)^))
	}
	full_text := xstrdup_o(text)
	i := lnum_start + 1
	for i <= lnum_last {
		half_text := concat_str_c(transmute(cstring)(full_text), cstring("\n"))
		xfree(rawptr(full_text))
		full_text = transmute(^u8)(concat_str_c(transmute(cstring)(half_text), transmute(cstring)(ml_get_buf(buf, i))))
		xfree(rawptr(half_text))
		i += 1
	}
	return transmute(cstring)(full_text)
}

// Prompt scrollback trimmer (eval.c public).
@(export)
prompt_trim_scrollback :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	if (^C.longlong)(uintptr(buf) + B_P_SCBK_OFF)^ <= 0 {
		return
	}
	prompt_line := (^C.int)(uintptr(buf) + B_PROMPT_START)^
	above_prompt := prompt_line - 1
	if above_prompt <= C.int((^C.longlong)(uintptr(buf) + B_P_SCBK_OFF)^) {
		return
	}
	to_delete := above_prompt - C.int((^C.longlong)(uintptr(buf) + B_P_SCBK_OFF)^)
	i: C.int = 0
	for i < to_delete {
		ml_delete_buf_e(buf, 1, false)
		i += 1
	}
	mark_adjust_buf(buf, 1, to_delete, MAXLNUM, -to_delete, true, kMarkAdjustNormal, kExtmarkUndo)
	deleted_lines_buf_e(buf, 1, to_delete)
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				ln := (^C.int)(uintptr(wp) + W_CURSOR_OFF)^
				if ln <= to_delete {
					ln = 1
				} else {
					ln -= to_delete
				}
				(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = ln
				if (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ > (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT)^ {
					(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT)^
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	check_cursor_col(curwin)
}

// Prompt submit handler (eval.c public).
@(export)
prompt_invoke_callback :: proc "c" () {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	user_input := prompt_get_input(curbuf)
	if user_input == nil {
		return
	}
	ml_append(lnum, transmute(^u8)(cstring("")), 0, false)
	appended_lines_mark_r(lnum, 1)
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum + 1
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	(^C.int)(uintptr(curbuf) + B_PROMPT_START)^ = lnum + 1
	if (^C.int)(uintptr(curbuf) + B_PROMPT_CB_OFF + 8)^ == KCB_NONE_O {
		xfree(rawptr(transmute(^u8)(user_input)))
	} else {
		argv := [2]Typval_T{Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}, Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}}
		argv[0].v_type = VAR_STRING
		argv[0].vval = transmute(rawptr)(user_input)
		rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
		callback_call(rawptr(uintptr(curbuf) + B_PROMPT_CB_OFF), 1, &argv[0], &rettv)
		tv_clear(&argv[0])
		tv_clear(&rettv)
	}
	u_clearallandblockfree(curbuf)
	(^C.int)(uintptr(curbuf) + B_PROMPT_START)^ = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	([^]u8)(uintptr(curbuf) + B_PROMPT_APPEND_OFF)[0] = 1
	prompt_trim_scrollback(curbuf)
}

// Prompt interrupt handler (eval.c public).
@(export)
invoke_prompt_interrupt :: proc "c" () -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(curbuf) + B_PROMPT_INT_OFF + 8)^ == KCB_NONE_O {
		return false
	}
	argv := [1]Typval_T{Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}}
	rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	got_int = false
	ret := callback_call(rawptr(uintptr(curbuf) + B_PROMPT_INT_OFF), 0, &argv[0], &rettv)
	tv_clear(&rettv)
	return ret
}

// —— Batch 28bg: eval.c provider trio (exports + weak) ——
foreign _ {
	@(link_name = "nlua_is_deferred_safe")
	nlua_is_deferred_safe_e :: proc "c" () -> bool ---
}

E5560_S :: "E5560: %s must not be called in a fast event context"
E319_S :: "E319: No \"%s\" provider found. Run \":checkhealth vim.provider\""

// Provider-feature check (eval.c public).
@(export)
eval_has_provider :: proc "c" (feat: cstring, throw_if_fast: bool) -> bool {
	context = runtime.default_context()
	if libc.strcmp(feat, cstring("clipboard")) != 0 && libc.strcmp(feat, cstring("python3")) != 0 && libc.strcmp(feat, cstring("python3_compiled")) != 0 && libc.strcmp(feat, cstring("python3_dynamic")) != 0 && libc.strcmp(feat, cstring("perl")) != 0 && libc.strcmp(feat, cstring("ruby")) != 0 && libc.strcmp(feat, cstring("node")) != 0 {
		return false
	}
	if throw_if_fast && !nlua_is_deferred_safe_e() {
		semsg(cstring(E5560_S), cstring("Vimscript function"))
		return false
	}
	name: [32]u8
	libc.snprintf(([^]u8)(&name[0]), 32, cstring("%s"), feat)
	for i := 0; i < 32; i += 1 {
		if ([^]u8)(&name[0])[i] == '_' {
			([^]u8)(&name[0])[i] = 0
			break
		}
		if ([^]u8)(&name[0])[i] == 0 {
			break
		}
	}
	buf: [256]u8
	tv := Typval_T{}
	length := C.int(libc.snprintf(([^]u8)(&buf[0]), 256, cstring("g:loaded_%s_provider"), transmute(cstring)(&name[0])))
	if eval_variable(transmute(cstring)(&buf[0]), length, &tv, nil, false, true) == FAIL_E {
		length = C.int(libc.snprintf(([^]u8)(&buf[0]), 256, cstring("provider#%s#bogus"), transmute(cstring)(&name[0])))
		script_autoload_e(transmute(cstring)(&buf[0]), C.size_t(length), false)
		length = C.int(libc.snprintf(([^]u8)(&buf[0]), 256, cstring("g:loaded_%s_provider"), transmute(cstring)(&name[0])))
		if eval_variable(transmute(cstring)(&buf[0]), length, &tv, nil, false, true) == FAIL_E {
			length = C.int(libc.snprintf(([^]u8)(&buf[0]), 256, cstring("provider#%s#Call"), transmute(cstring)(&name[0])))
			if find_func(transmute(cstring)(&buf[0])) != nil && p_lpl != 0 {
				semsg(cstring("provider: %s: missing required variable g:loaded_%s_provider"), transmute(cstring)(&name[0]), transmute(cstring)(&name[0]))
			}
			return false
		}
	}
	ok := false
	if tv.v_type == VAR_NUMBER && transmute(C.longlong)(tv.vval) == 2 {
		ok = true
	}
	if ok {
		libc.snprintf(([^]u8)(&buf[0]), 256, cstring("provider#%s#Call"), transmute(cstring)(&name[0]))
		if find_func(transmute(cstring)(&buf[0])) == nil {
			semsg(cstring("provider: %s: g:loaded_%s_provider=2 but %s is not defined"), transmute(cstring)(&name[0]), transmute(cstring)(&name[0]), transmute(cstring)(&buf[0]))
			ok = false
		}
	}
	return ok
}

// Provider-method dispatcher (eval.c public).
@(export)
eval_call_provider :: proc "c" (provider: cstring, method: cstring, arguments: rawptr, discard: bool) -> Typval_T {
	context = runtime.default_context()
	if !eval_has_provider(provider, false) {
		semsg(cstring(E319_S), provider)
		return Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(0))}
	}
	func: [256]u8
	name_len := C.int(libc.snprintf(([^]u8)(&func[0]), 256, cstring("provider#%s#Call"), provider))
	saved_scope := provider_caller_scope_g
	provider_caller_scope_g.script_ctx = transmute(sctx_T)(current_sctx_buf)
	provider_caller_scope_g.es_entry = ([^]Estack)(exestack.ga_data)[int(exestack.ga_len) - 1]
	provider_caller_scope_g.autocmd_fname = autocmd_fname_g
	provider_caller_scope_g.autocmd_match = autocmd_match_g
	provider_caller_scope_g.autocmd_fname_full = autocmd_fname_full_g
	provider_caller_scope_g.autocmd_bufnr = autocmd_bufnr_g
	provider_caller_scope_g.funccalp = rawptr(get_current_funccal())
	entry: [16]u8
	save_funccal(rawptr(&entry[0]))
	provider_call_nesting_g += 1
	argvars := [3]Typval_T{Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(method)}, Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = arguments}, Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}}
	rettv := Typval_T{v_type = VAR_UNKNOWN, v_lock = VAR_UNLOCKED}
	tv_list_ref_o(arguments)
	fe := Funcexe_T{}
	fe.firstline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.lastline = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	fe.evaluate = true
	call_func(transmute(cstring)(&func[0]), name_len, &rettv, 2, &argvars[0], &fe)
	tv_list_unref(arguments)
	restore_funccal()
	provider_caller_scope_g = saved_scope
	provider_call_nesting_g -= 1
	if discard {
		tv_clear(&rettv)
	}
	return rettv
}

// Host-program eval entry (eval.c public).
@(export)
script_host_eval :: proc "c" (name: cstring, argvars: ^Typval_T, rettv: ^Typval_T) {
	context = runtime.default_context()
	if check_secure() {
		return
	}
	if ([^]Typval_T)(argvars)[0].v_type != VAR_STRING {
		emsg(e_invarg)
		return
	}
	args := tv_list_alloc(1)
	tv_list_append_string(args, transmute(^u8)(([^]Typval_T)(argvars)[0].vval), -1)
	rettv^ = eval_call_provider(name, cstring("eval"), args, false)
}

// —— Batch 28bf: eval.c init + global-set leaves (exports + weak) ——

// Top-level eval init (eval.c public; single implementation, main.odin binds here).
@(export)
eval_init :: proc "c" () {
	context = runtime.default_context()
	evalvars_init()
	func_init()
}

// Set a global var with funccal save (eval.c public).
@(export)
var_set_global :: proc "c" (name: cstring, vartv: Typval_T) {
	context = runtime.default_context()
	entry: [16]u8
	save_funccal(rawptr(&entry[0]))
	v := vartv
	set_var(name, C.size_t(libc.strlen(name)), &v, false)
	restore_funccal()
}

// —— Batch 28bd: eval.c job argv cluster (exports + weak) ——
E900_JOB_S :: "E900: Invalid channel id: not a job"
E900_CHAN_S :: "E900: Invalid channel id"
VV_ARGV_O :: 89

// Command-to-argv builder (eval.c public).
@(export)
tv_to_argv :: proc "c" (cmd_tv: ^Typval_T, cmd: ^cstring, executable: ^bool) -> ^^u8 {
	context = runtime.default_context()
	if cmd_tv.v_type == VAR_STRING {
		cmd_str := tv_get_string(cmd_tv)
		if cmd != nil {
			cmd^ = cmd_str
		}
		return shell_build_argv(cmd_str, nil)
	}
	if cmd_tv.v_type != VAR_LIST {
		semsg(e_invarg2, cstring("expected String or List"))
		return nil
	}
	argl := rawptr(cmd_tv.vval)
	argc := tv_list_len_o(argl)
	if argc == 0 {
		emsg(e_invarg)
		return nil
	}
	arg0 := tv_get_string_chk((^Typval_T)(uintptr(tv_list_first_o(argl)) + 16))
	exe_resolved: cstring = nil
	if arg0 == nil || !os_can_exe(arg0, &exe_resolved, true) {
		if arg0 != nil && executable != nil {
			buf: [1025]u8
			libc.snprintf(([^]u8)(&buf[0]), 1025, cstring("'%s' is not executable"), arg0)
			semsg(cstring(E_INVARGNVAL_S), cstring("cmd"), transmute(cstring)(&buf[0]))
			executable^ = false
		}
		return nil
	}
	if cmd != nil {
		cmd^ = exe_resolved
	}
	argv := (^rawptr)(xcalloc(C.size_t(argc + 1), C.size_t(size_of(rawptr))))
	i: C.int = 0
	li := tv_list_first_o(argl)
	for li != nil {
		a := tv_get_string_chk((^Typval_T)(uintptr(li) + 16))
		if a == nil {
			shell_free_argv(transmute(^^u8)(argv))
			xfree(rawptr(exe_resolved))
			return nil
		}
		([^]rawptr)(argv)[i] = rawptr(xstrdup_o(transmute(^u8)(a)))
		i += 1
		li = (^rawptr)(uintptr(li))^
	}
	xfree(([^]rawptr)(argv)[0])
	([^]rawptr)(argv)[0] = rawptr(exe_resolved)
	return transmute(^^u8)(argv)
}

// Typval-to-string saver (eval.c public).
@(export)
save_tv_as_string :: proc "c" (tv: ^Typval_T, len: ^C.ptrdiff_t, endnl: bool, crlf: bool) -> ^u8 {
	context = runtime.default_context()
	len^ = 0
	if tv.v_type == VAR_UNKNOWN {
		return nil
	}
	if tv.v_type != VAR_LIST && tv.v_type != VAR_NUMBER {
		ret := tv_get_string_chk(tv)
		if ret != nil {
			len^ = C.ptrdiff_t(libc.strlen(ret))
			return xmemdupz_o2(transmute(^u8)(ret), C.size_t(len^))
		}
		len^ = -1
		return nil
	}
	if tv.v_type == VAR_NUMBER {
		buf := buflist_findnr(C.int(transmute(C.longlong)(tv.vval)))
		if buf != nil {
			lnum: C.int = 1
			for lnum <= (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
				p := ml_get_buf(buf, lnum)
				for ([^]u8)(p)[0] != 0 {
					len^ += 1
					p = transmute(^u8)(uintptr(rawptr(p)) + 1)
				}
				len^ += 1
				lnum += 1
			}
		} else {
			semsg(cstring(E86_S), transmute(C.longlong)(tv.vval))
			len^ = -1
			return nil
		}
		if len^ == 0 {
			return nil
		}
		ret := (^u8)(xmalloc(C.size_t(len^) + 1))
		end := ret
		lnum: C.int = 1
		for lnum <= (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
			p := ml_get_buf(buf, lnum)
			for ([^]u8)(p)[0] != 0 {
				c := ([^]u8)(p)[0]
				if c == '\n' {
					c = 0
				}
				([^]u8)(end)[0] = c
				end = transmute(^u8)(uintptr(rawptr(end)) + 1)
				p = transmute(^u8)(uintptr(rawptr(p)) + 1)
			}
			([^]u8)(end)[0] = '\n'
			end = transmute(^u8)(uintptr(rawptr(end)) + 1)
			lnum += 1
		}
		([^]u8)(end)[0] = 0
		len^ = C.ptrdiff_t(uintptr(rawptr(end)) - uintptr(rawptr(ret)))
		return ret
	}
	list := rawptr(tv.vval)
	li := tv_list_first_o(list)
	for li != nil {
		len^ += C.ptrdiff_t(libc.strlen(tv_get_string((^Typval_T)(uintptr(li) + 16)))) + (crlf ? 2 : 1)
		li = (^rawptr)(uintptr(li))^
	}
	if len^ == 0 {
		return nil
	}
	ret := (^u8)(xmalloc(C.size_t(len^) + (endnl ? (crlf ? 2 : 1) : 0)))
	end := ret
	li = tv_list_first_o(list)
	for li != nil {
		s := tv_get_string((^Typval_T)(uintptr(li) + 16))
		for ([^]u8)(s)[0] != 0 {
			c := ([^]u8)(s)[0]
			if c == '\n' {
				c = 0
			}
			([^]u8)(end)[0] = c
			end = transmute(^u8)(uintptr(rawptr(end)) + 1)
			s = transmute(cstring)(uintptr(rawptr(s)) + 1)
		}
		next := (^rawptr)(uintptr(li))^
		if endnl || next != nil {
			if crlf {
				([^]u8)(end)[0] = '\r'
				end = transmute(^u8)(uintptr(rawptr(end)) + 1)
			}
			([^]u8)(end)[0] = '\n'
			end = transmute(^u8)(uintptr(rawptr(end)) + 1)
		}
		li = next
	}
	([^]u8)(end)[0] = 0
	len^ = C.ptrdiff_t(uintptr(rawptr(end)) - uintptr(rawptr(ret)))
	return ret
}

// v:argv setter (eval.c public).
@(export)
set_argv_var :: proc "c" (argv: ^^u8, argc: C.int) {
	context = runtime.default_context()
	l := tv_list_alloc(C.ssize_t(argc))
	(^C.int)(uintptr(l) + 72)^ = VAR_FIXED_O
	i: C.int = 0
	for i < argc {
		tv_list_append_string(l, transmute(^u8)(([^]cstring)(argv)[i]), -1)
		(^C.int)(uintptr(tv_list_last_o(l)) + 20)^ = VAR_FIXED_O
		i += 1
	}
	set_vim_var_list(VV_ARGV_O, l)
}

// CallbackReader storage release (channel.c public, inlined here).
callback_reader_free_o :: proc "c" (reader: ^CallbackReader_E) {
	context = runtime.default_context()
	callback_free(&reader.cb)
	ga_clear(transmute(^Garray)(uintptr(reader) + 24))
}

// Job-callback options reader (eval.c public).
@(export)
common_job_callbacks :: proc "c" (vopts: rawptr, on_stdout: ^CallbackReader_E, on_stderr: ^CallbackReader_E, on_exit: ^Callback_E) -> bool {
	context = runtime.default_context()
	if tv_dict_get_callback(vopts, cstring("on_stdout"), 9, &on_stdout.cb) && tv_dict_get_callback(vopts, cstring("on_stderr"), 9, &on_stderr.cb) && tv_dict_get_callback(vopts, cstring("on_exit"), 7, on_exit) {
		on_stdout.buffered = tv_dict_get_number(vopts, cstring("stdout_buffered")) != 0
		on_stderr.buffered = tv_dict_get_number(vopts, cstring("stderr_buffered")) != 0
		if on_stdout.buffered && on_stdout.cb.type == KCB_NONE_O {
			on_stdout.self = vopts
		}
		if on_stderr.buffered && on_stderr.cb.type == KCB_NONE_O {
			on_stderr.self = vopts
		}
		(^C.int)(uintptr(vopts) + 8)^ += 1
		return true
	}
	callback_reader_free_o(on_stdout)
	callback_reader_free_o(on_stderr)
	callback_free(on_exit)
	return false
}

// Job-channel lookup (eval.c public).
@(export)
find_job :: proc "c" (id: u64, show_error: bool) -> rawptr {
	context = runtime.default_context()
	data := find_channel_o(id)
	if data == nil || (^C.int)(uintptr(data) + CHAN_STREAMTYPE_OFF)^ != KCHSTREAM_PROC_O || proc_is_stopped_o(rawptr(uintptr(data) + CHAN_STREAM_OFF)) {
		if show_error {
			if data != nil && (^C.int)(uintptr(data) + CHAN_STREAMTYPE_OFF)^ != KCHSTREAM_PROC_O {
				emsg(cstring(E900_JOB_S))
			} else {
				emsg(cstring(E900_CHAN_S))
			}
		}
		return nil
	}
	return data
}

// —— Batch 28bc: eval.c buf byte/char index pair (exports + weak) ——

// Byte-to-char index for a buffer line (eval.c public).
@(export)
buf_byteidx_to_charidx :: proc "c" (buf: rawptr, lnum: C.int, byteidx: C.int) -> C.int {
	context = runtime.default_context()
	if buf == nil || (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
		return -1
	}
	ln := lnum
	if ln > (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
		ln = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
	}
	str := ml_get_buf(buf, ln)
	if ([^]u8)(str)[0] == 0 {
		return 0
	}
	t := str
	count: C.int = 0
	for ([^]u8)(t)[0] != 0 && uintptr(rawptr(t)) <= uintptr(rawptr(str)) + uintptr(byteidx) {
		t = transmute(^u8)(uintptr(rawptr(t)) + uintptr(utfc_ptr2len(transmute(cstring)(t))))
		count += 1
	}
	if ([^]u8)(t)[0] == 0 && byteidx != 0 && t == transmute(^u8)(uintptr(rawptr(str)) + uintptr(byteidx)) {
		count += 1
	}
	return count - 1
}

// Char-to-byte index for a buffer line (eval.c public).
@(export)
buf_charidx_to_byteidx :: proc "c" (buf: rawptr, lnum: C.int, charidx: C.int) -> C.int {
	context = runtime.default_context()
	if buf == nil || (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
		return -1
	}
	ln := lnum
	if ln > (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
		ln = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
	}
	str := ml_get_buf(buf, ln)
	t := str
	ci := charidx
	for ([^]u8)(t)[0] != 0 && (ci - 1) > 0 {
		t = transmute(^u8)(uintptr(rawptr(t)) + uintptr(utfc_ptr2len(transmute(cstring)(t))))
		ci -= 1
	}
	return C.int(uintptr(rawptr(t)) - uintptr(rawptr(str)))
}
