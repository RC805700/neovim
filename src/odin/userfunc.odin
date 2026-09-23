// userfunc.odin — Odin port of src/nvim/eval/userfunc.c (user functions).
//
// Batch 24a: deref_func_name + emsg_funcname.

package main

import "base:runtime"
import C "core:c"
import "core:c/libc"

// Dereference funcref name (follows VAR_FUNC/PARTIAL vars).
@(export)
deref_func_name :: proc "c" (name: cstring, lenp: ^C.int, partialp: ^rawptr, no_autoload: bool, found_var: ^bool) -> cstring {
	context = runtime.default_context()
	if partialp != nil {
		partialp^ = nil
	}
	na: C.int = 0
	if no_autoload {
		na = 1
	}
	v := find_var_e(name, C.size_t(lenp^), nil, na)
	if v == nil {
		return name
	}
	tv := (^Typval_T)(v)
	if found_var != nil {
		found_var^ = true
	}
	if tv.v_type == VAR_FUNC {
		s := (rawptr)(tv.vval)
		if s == nil {
			lenp^ = 0
			return cstring("")
		}
		lenp^ = C.int(libc.strlen(transmute(cstring)(s)))
		return transmute(cstring)(s)
	}
	if tv.v_type == VAR_PARTIAL {
		pt := (rawptr)(tv.vval)
		if pt == nil {
			lenp^ = 0
			return cstring("")
		}
		if partialp != nil {
			partialp^ = pt
		}
		s := partial_name_e(pt)
		lenp^ = C.int(libc.strlen(s))
		return s
	}
	return name
}

// Error message with function name (<SNR> expanded).
@(export)
emsg_funcname :: proc "c" (errmsg: cstring, name: cstring) {
	context = runtime.default_context()
	p := name
	nb := ([^]u8)(name)
	if nb[0] == 0x80 && nb[1] != 0 && nb[2] != 0 {
		p = transmute(cstring)(concat_str_c(cstring("<SNR>"), transmute(cstring)(uintptr(nb) + 3)))
	}
	semsg(errmsg, p)
	if rawptr(p) != rawptr(name) {
		xfree(rawptr(p))
	}
}

// —— Batch 24b: func refcount quartet ——
// (func_clear_free_e shim removed in 24ad: calls func_clear_free_o now.)

// ufunc_T offsets (cc-probed): uf_calls@8, uf_refcount@208 (both int).
UF_CALLS_OFF_O :: 8
UF_REFCOUNT_OFF_O :: 208

// Numbered (<lambda>) names carry a refcount; others are hashtab-owned.
func_name_refcount_o :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	nb := ([^]u8)(name)
	if nb[0] >= '0' && nb[0] <= '9' {
		return true
	}
	if nb[0] == '<' && nb[1] == 'l' {
		return true
	}
	return false
}

// Unreference function by name.
@(export)
func_unref :: proc "c" (name: cstring) {
	context = runtime.default_context()
	if name == nil || !func_name_refcount_o(name) {
		return
	}
	fp := find_func(name)
	if fp == nil {
		nb := ([^]u8)(name)
		if nb[0] >= '0' && nb[0] <= '9' {
			_internal_error(cstring("func_unref()"))
			libc.abort()
		}
	}
	func_ptr_unref(fp)
}

// Unreference user function, freeing when count reaches zero.
@(export)
func_ptr_unref :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	if fp != nil {
		rc := (^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)
		rc^ -= 1
		if rc^ <= 0 {
			if (^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ == 0 {
				func_clear_free_o(fp, false)
			}
		}
	}
}

// Count a reference to a function by name.
@(export)
func_ref :: proc "c" (name: cstring) {
	context = runtime.default_context()
	if name == nil || !func_name_refcount_o(name) {
		return
	}
	fp := find_func(name)
	if fp != nil {
		(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ += 1
	} else {
		nb := ([^]u8)(name)
		if nb[0] >= '0' && nb[0] <= '9' {
			_internal_error(cstring("func_ref()"))
		}
	}
}

// Count a reference to a function.
@(export)
func_ptr_ref :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	if fp != nil {
		(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ += 1
	}
}

// —— Batch 24c: fname_trans_sid + get_func_arity ——
foreign _ {
	@(link_name = "find_internal_func")
	find_internal_func_e :: proc "c" (name: cstring) -> rawptr ---
}

// ufunc_T garray offsets (cc-probed): uf_varargs@0 (bool), uf_args@16, uf_def_args@40.
UF_VARARGS_OFF_O :: 0
UF_ARGS_OFF_O :: 16
UF_DEF_ARGS_OFF_O :: 40
UF_FLAGS_OFF_O :: 4
UF_NAMELEN_OFF_O :: 232
XP_CONTEXT_OFF_O :: 8
// EvalFuncDef (funcs.h): name@0, min_argc@8 (u8), max_argc@9 (u8).
EVALFUNC_MIN_ARGC_OFF_O :: 8
EVALFUNC_MAX_ARGC_OFF_O :: 9
FLEN_FIXED_O :: 40
FCERR_NONE_O :: 5
FCERR_SCRIPT_O :: 3
KE_SNR_O :: 82

// True for script-local names (<SID>/s:); names pre-checked by eval_fname_script.
eval_fname_sid_o :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	nb := ([^]u8)(name)
	if nb[0] == 's' {
		return true
	}
	c := nb[2]
	if c >= 'a' && c <= 'z' {
		c -= 'a' - 'A'
	}
	return c == 'I'
}

// Translate <SID>/s: prefix to K_SNR form (static in C).
fname_trans_sid_o :: proc "c" (name: cstring, fname_buf: [^]u8, tofree: ^rawptr, error: ^C.int) -> cstring {
	context = runtime.default_context()
	script_name := cstring(rawptr(uintptr(rawptr(name)) + uintptr(eval_fname_script(name))))
	if rawptr(script_name) == rawptr(name) {
		return cstring(rawptr(name))
	}
	fname_buf[0] = 0x80
	fname_buf[1] = KS_EXTRA
	fname_buf[2] = KE_SNR_O
	fname_buflen: C.size_t = 3
	if !eval_fname_sid_o(name) {
		fname_buf[3] = 0
	} else {
		sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
		if sid <= 0 {
			error^ = FCERR_SCRIPT_O
		} else {
			fname_buflen += C.size_t(libc.snprintf(([^]u8)(uintptr(fname_buf) + uintptr(3)), FLEN_FIXED_O + 1 - 3, cstring("%d_"), sid))
		}
	}
	fnamelen := C.size_t(fname_buflen) + libc.strlen(script_name)
	fname: cstring
	if fnamelen < FLEN_FIXED_O {
		libc.memcpy(rawptr(uintptr(fname_buf) + uintptr(fname_buflen)), rawptr(script_name), fnamelen - C.size_t(fname_buflen) + 1)
		fname = cstring(rawptr(fname_buf))
	} else {
		fname = transmute(cstring)(xmalloc(fnamelen + 1))
		tofree^ = rawptr(fname)
		libc.snprintf(([^]u8)(fname), fnamelen + 1, cstring("%s%s"), cstring(rawptr(fname_buf)), script_name)
	}
	return fname
}

// Arity of builtin or user function (OK/FAIL).
@(export)
get_func_arity :: proc "c" (name: cstring, required: ^C.int, optional: ^C.int, varargs: ^bool) -> C.int {
	context = runtime.default_context()
	argcount: C.int = 0
	min_argcount: C.int = 0
	fdef := find_internal_func_e(name)
	if fdef != nil {
		argcount = C.int(([^]u8)(fdef)[EVALFUNC_MAX_ARGC_OFF_O])
		min_argcount = C.int(([^]u8)(fdef)[EVALFUNC_MIN_ARGC_OFF_O])
		varargs^ = false
	} else {
		fname_buf: [FLEN_FIXED_O + 1]u8
		tofree: rawptr = nil
		error: C.int = FCERR_NONE_O
		fname := fname_trans_sid_o(name, ([^]u8)(&fname_buf[0]), &tofree, &error)
		ufunc: rawptr = nil
		if error == FCERR_NONE_O {
			ufunc = find_func(fname)
		}
		xfree(tofree)
		if ufunc == nil {
			return FAIL_E
		}
		argcount = (^C.int)(uintptr(ufunc) + UF_ARGS_OFF_O)^
		min_argcount = argcount - (^C.int)(uintptr(ufunc) + UF_DEF_ARGS_OFF_O)^
		varargs^ = (^bool)(uintptr(ufunc) + UF_VARARGS_OFF_O)^
	}
	required^ = min_argcount
	optional^ = argcount - min_argcount
	return OK_E
}

// —— Batch 24d: name-classification leaves ——

// ufunc_T name offsets (cc-probed): uf_name_exp@224 (char* slot), uf_name@240 (inline char[]).
UF_NAME_EXP_OFF_O :: 224
UF_NAME_OFF_O :: 240

// Length of <SID>/<SNR>/s: prefix (0 when none).
@(export)
eval_fname_script :: proc "c" (p: cstring) -> C.int {
	context = runtime.default_context()
	nb := ([^]u8)(p)
	if nb[0] == '<' {
		plus1 := transmute(cstring)(rawptr(uintptr(rawptr(p)) + uintptr(1)))
		if mb_strnicmp_e(plus1, cstring("SID>"), 4) == 0 || mb_strnicmp_e(plus1, cstring("SNR>"), 4) == 0 {
			return 5
		}
	}
	if nb[0] == 's' && nb[1] == ':' {
		return 2
	}
	return 0
}

// True for lowercase builtin-style names without '#' or ':' (static in C).
builtin_function_o :: proc "c" (name: cstring, len: C.int) -> bool {
	context = runtime.default_context()
	nb := ([^]u8)(name)
	if !(nb[0] >= 'a' && nb[0] <= 'z') || nb[1] == ':' {
		return false
	}
	if len == -1 {
		return libc.strchr(name, '#') == nil
	}
	return libc.memchr(rawptr(name), '#', C.size_t(len)) == nil
}

// True when a function with this (translated) name exists.
@(export)
translated_function_exists :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	if builtin_function_o(name, -1) {
		return find_internal_func_e(name) != nil
	}
	return find_func(name) != nil
}

// Display name (<SNR> expansion when present).
@(export)
printable_func_name :: proc "c" (fp: rawptr) -> cstring {
	context = runtime.default_context()
	exp := (^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^
	if exp != nil {
		return transmute(cstring)(exp)
	}
	return transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))
}

// —— Batch 24e: trans_function_name ——
foreign _ {
}

// —— Batch 24e: trans_function_name ——
foreign _ {
	@(link_name = "get_lval")
	get_lval_e :: proc "c" (name: cstring, rettv: rawptr, lp: rawptr, unlet: bool, skip: bool, flags: C.int, fne_flags: C.int) -> cstring ---
	@(link_name = "clear_lval")
	clear_lval_e :: proc "c" (lp: rawptr) ---
	@(link_name = "get_id_len")
	get_id_len_e :: proc "c" (arg: ^cstring) -> C.int ---
	@(link_name = "is_luafunc")
	is_luafunc_e :: proc "c" (pt: rawptr) -> bool ---
	@(link_name = "check_luafunc_name")
	check_luafunc_name_e :: proc "c" (s: cstring, paren: bool) -> C.int ---
}

// lval_T offsets (cc-probed, sizeof 96).
LL_NAME_OFF_O :: 0
LL_NAME_LEN_OFF_O :: 8
LL_EXP_NAME_OFF_O :: 16
LL_TV_OFF_O :: 24
LL_RANGE_OFF_O :: 48
LL_DICT_OFF_O :: 64
LL_DI_OFF_O :: 72
LL_NEWKEY_OFF_O :: 80
// funcdict_T offsets.
FD_DICT_OFF_O :: 0
FD_NEWKEY_OFF_O :: 8
FD_DI_OFF_O :: 16
// TFN_/GLV_ flags (eval.h).
TFN_INT_O :: 1
TFN_QUIET_O :: 2
TFN_NO_AUTOLOAD_O :: 4
TFN_NO_DEREF_O :: 8
GLV_READ_ONLY_O :: 16
E129_S :: "E129: Function name required"
E_FUNCREL_S :: "E718: Funcref required"
E_USINGSID_S :: "E81: Using <SID> not in a script context"
E128_S :: "E128: Function name must start with a capital or \"s:\": %s"
E884_S :: "E884: Function name cannot contain a colon: %s"
E_INVEXPR2_S :: "E15: Invalid expression: \"%s\""

// Translate function name (deref funcrefs, expand s:/<SID>); allocated or NULL.
@(export)
trans_function_name :: proc "c" (pp: ^cstring, skip: bool, flags: C.int, fdp: rawptr, partial: ^rawptr) -> cstring {
	context = runtime.default_context()
	name: cstring = nil
	length: C.int = 0
	lv: [96]u8
	if fdp != nil {
		libc.memset(fdp, 0, 24)
	}
	start := pp^
	pnb := ([^]u8)(start)
	if pnb[0] == 0x80 && pnb[1] == KS_EXTRA && pnb[2] == KE_SNR_O {
		pp^ = transmute(cstring)(rawptr(uintptr(rawptr(pp^)) + uintptr(3)))
		length = get_id_len_e(pp) + 3
		return transmute(cstring)(xmemdupz_o2(transmute(^u8)(rawptr(start)), C.size_t(length)))
	}
	lead := int(eval_fname_script(start))
	if lead > 2 {
		start = transmute(cstring)(rawptr(uintptr(rawptr(start)) + uintptr(lead)))
	}
	fne: C.int = FNE_CHECK_START_O
	if lead > 2 {
		fne = 0
	}
	end := get_lval_e(start, nil, rawptr(&lv[0]), false, skip, flags | GLV_READ_ONLY_O, fne)
	lvp := uintptr(rawptr(&lv[0]))
	for _ in 0..<1 {
		if rawptr(end) == rawptr(start) {
			if !skip {
				emsg(cstring(E129_S))
			}
			break
		}
		ll_tv := (^rawptr)(lvp + LL_TV_OFF_O)^
		ll_range := (^bool)(lvp + LL_RANGE_OFF_O)^
		if end == nil || (ll_tv != nil && (lead > 2 || ll_range)) {
			if !aborting_r() {
				if end != nil {
					semsg(e_invarg2, start)
				}
			} else {
				pp^ = find_name_end_e(start, nil, nil, FNE_INCL_BR_O)
			}
			break
		}
		if ll_tv != nil {
			if fdp != nil {
				(^rawptr)(uintptr(fdp) + FD_DICT_OFF_O)^ = (^rawptr)(lvp + LL_DICT_OFF_O)^
				(^rawptr)(uintptr(fdp) + FD_NEWKEY_OFF_O)^ = (^rawptr)(lvp + LL_NEWKEY_OFF_O)^
				(^rawptr)(lvp + LL_NEWKEY_OFF_O)^ = nil
				(^rawptr)(uintptr(fdp) + FD_DI_OFF_O)^ = (^rawptr)(lvp + LL_DI_OFF_O)^
			}
			tv := (^Typval_T)(ll_tv)
			if tv.v_type == VAR_FUNC && rawptr(tv.vval) != nil {
				name = transmute(cstring)(xstrdup_o(transmute(^u8)(rawptr(tv.vval))))
				pp^ = end
			} else if tv.v_type == VAR_PARTIAL && rawptr(tv.vval) != nil {
				pt := rawptr(tv.vval)
				if is_luafunc_e(pt) && ([^]u8)(end)[0] == '.' {
					after := transmute(cstring)(rawptr(uintptr(rawptr(end)) + uintptr(1)))
					length = check_luafunc_name_e(after, true)
					if length == 0 {
						semsg(cstring(E_INVEXPR2_S), cstring("v:lua"))
						break
					}
					nb := ([^]u8)(xmallocz_r(C.size_t(length)))
					libc.memcpy(rawptr(nb), rawptr(after), C.size_t(length))
					name = transmute(cstring)(nb)
					pp^ = transmute(cstring)(rawptr(uintptr(rawptr(end)) + uintptr(1) + uintptr(length)))
				} else {
					name = transmute(cstring)(xstrdup_o(transmute(^u8)(partial_name_e(pt))))
					pp^ = end
				}
				if partial != nil {
					partial^ = pt
				}
			} else {
				if !skip && (flags & TFN_QUIET_O) == 0 && (fdp == nil || (^rawptr)(lvp + LL_DICT_OFF_O)^ == nil || (^rawptr)(uintptr(fdp) + FD_NEWKEY_OFF_O)^ == nil) {
					emsg(cstring(E_FUNCREL_S))
				} else {
					pp^ = end
				}
				name = nil
			}
			break
		}
		ll_name := (^rawptr)(lvp + LL_NAME_OFF_O)^
		if ll_name == nil {
			pp^ = end
			break
		}
		ll_exp_name := (^rawptr)(lvp + LL_EXP_NAME_OFF_O)^
		if ll_exp_name != nil {
			length = C.int(libc.strlen(transmute(cstring)(ll_exp_name)))
			name = deref_func_name(transmute(cstring)(ll_exp_name), &length, partial, (flags & TFN_NO_AUTOLOAD_O) != 0, nil)
			if rawptr(name) == ll_exp_name {
				name = nil
			}
		} else if (flags & TFN_NO_DEREF_O) == 0 {
			length = C.int(uintptr(rawptr(end)) - uintptr(rawptr(pp^)))
			name = deref_func_name(pp^, &length, partial, (flags & TFN_NO_AUTOLOAD_O) != 0, nil)
			if rawptr(name) == rawptr(pp^) {
				name = nil
			}
		}
		if name != nil {
			name = transmute(cstring)(xstrdup_o(transmute(^u8)(name)))
			pp^ = end
			if libc.strncmp(name, cstring("<SNR>"), 5) == 0 {
				nb := ([^]u8)(rawptr(name))
				nb[0] = 0x80
				nb[1] = KS_EXTRA
				nb[2] = KE_SNR_O
				tail := libc.strlen(transmute(cstring)(rawptr(uintptr(nb) + uintptr(5)))) + 1
				libc.memmove(rawptr(uintptr(nb) + uintptr(3)), rawptr(uintptr(nb) + uintptr(5)), tail)
			}
			break
		}
		ll_name_len := (^C.size_t)(lvp + LL_NAME_LEN_OFF_O)^
		if ll_exp_name != nil {
			length = C.int(libc.strlen(transmute(cstring)(ll_exp_name)))
			if lead <= 2 && ll_name == ll_exp_name && ll_name_len >= 2 && ([^]u8)(ll_name)[0] == 's' && ([^]u8)(ll_name)[1] == ':' {
				ll_name = rawptr(uintptr(ll_name) + uintptr(2))
				ll_name_len -= 2
				length -= 2
				lead = 2
			}
		} else {
			lnb := ([^]u8)(ll_name)
			if lead == 2 || (lnb[0] == 'g' && lnb[1] == ':') {
				ll_name = rawptr(uintptr(ll_name) + uintptr(2))
				ll_name_len -= 2
			}
			length = C.int(uintptr(rawptr(end)) - uintptr(ll_name))
		}
		sid_buflen: C.size_t = 0
		sid_buf: [20]u8
		if skip {
			lead = 0
		} else if lead > 0 {
			lead = 3
			need_sid := false
			if ll_exp_name != nil && eval_fname_sid_o(transmute(cstring)(ll_exp_name)) {
				need_sid = true
			}
			if !need_sid && eval_fname_sid_o(pp^) {
				need_sid = true
			}
			if need_sid {
				sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
				if sid <= 0 {
					emsg(cstring(E_USINGSID_S))
					break
				}
				sid_buflen = C.size_t(libc.snprintf(([^]u8)(&sid_buf[0]), 20, cstring("%d_"), sid))
				lead += int(sid_buflen)
			}
		} else if (flags & TFN_INT_O) == 0 && builtin_function_o(transmute(cstring)(ll_name), C.int(ll_name_len)) {
			semsg(cstring(E128_S), start)
			break
		}
		if !skip && (flags & TFN_QUIET_O) == 0 && (flags & TFN_NO_DEREF_O) == 0 {
			cp := _xmemrchr(transmute(cstring)(ll_name), ':', C.size_t(ll_name_len))
			if cp != nil && uintptr(rawptr(cp)) < uintptr(rawptr(end)) {
				semsg(cstring(E884_S), start)
				break
			}
		}
		nbuf := ([^]u8)(xmalloc(C.size_t(length) + C.size_t(lead) + 1))
		if !skip && lead > 0 {
			nbuf[0] = 0x80
			nbuf[1] = KS_EXTRA
			nbuf[2] = KE_SNR_O
			if sid_buflen > 0 {
				libc.memcpy(rawptr(uintptr(nbuf) + uintptr(3)), rawptr(&sid_buf[0]), sid_buflen)
			}
		}
		off := int(lead) + int(length)
		libc.memmove(rawptr(uintptr(nbuf) + uintptr(off) - uintptr(length)), ll_name, C.size_t(length))
		nbuf[off] = 0
		name = transmute(cstring)(nbuf)
		pp^ = end
	}
	clear_lval_e(rawptr(&lv[0]))
	return name
}

// —— Batch 24f: function_exists + save_function_name ——
foreign _ {
	@(link_name = "getdigits")
	getdigits_e :: proc "c" (pp: ^cstring, strict: bool, def: C.long) -> C.long ---
}

// True when a function with the given name exists.
@(export)
function_exists :: proc "c" (name: cstring, no_deref: bool) -> bool {
	context = runtime.default_context()
	nm := name
	flag: C.int = TFN_INT_O | TFN_QUIET_O | TFN_NO_AUTOLOAD_O
	if no_deref {
		flag |= TFN_NO_DEREF_O
	}
	p := trans_function_name(&nm, false, flag, nil, nil)
	nm = skipwhite(nm)
	n := false
	if p != nil {
		nb := ([^]u8)(nm)
		if nb[0] == 0 || nb[0] == '(' {
			n = translated_function_exists(p)
		}
	}
	xfree(rawptr(p))
	return n
}

// trans_function_name() except lambdas pass through; allocated result.
@(export)
save_function_name :: proc "c" (name: ^cstring, skip: bool, flags: C.int, fudi: rawptr) -> cstring {
	context = runtime.default_context()
	p := name^
	saved: cstring
	if libc.strncmp(p, cstring("<lambda>"), 8) == 0 {
		p = transmute(cstring)(rawptr(uintptr(rawptr(p)) + uintptr(8)))
		getdigits_e(&p, false, 0)
		saved = transmute(cstring)(xmemdupz_o2(transmute(^u8)(rawptr(name^)), C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(name^)))))
		if fudi != nil {
			libc.memset(fudi, 0, 24)
		}
	} else {
		saved = trans_function_name(&p, skip, flags, fudi, nil)
	}
	name^ = p
	return saved
}

// —— Batch 24g: get_scriptlocal_funcname ——
// (script_items_len_e shim removed in 24ad: reads script_items_g directly.)
foreign _ {
	@(link_name = "script_items")
	script_items_g: Garray
}

// Expand s:/<SID> prefix to <SNR>nr_ form; NULL when not applicable.
@(export)
get_scriptlocal_funcname :: proc "c" (funcname: cstring) -> cstring {
	context = runtime.default_context()
	if funcname == nil {
		return nil
	}
	fnb := ([^]u8)(funcname)
	if (fnb[0] != 's' || fnb[1] != ':') && (fnb[0] != '<' || fnb[1] != 'S' || fnb[2] != 'I' || fnb[3] != 'D' || fnb[4] != '>') {
		return nil
	}
	sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
	if !(sid > 0 && sid <= script_items_g.ga_len) {
		emsg(cstring(E_USINGSID_S))
		return nil
	}
	sid_buf: [25]u8
	sid_buflen := C.size_t(libc.snprintf(([^]u8)(&sid_buf[0]), 25, cstring("<SNR>%d_"), sid))
	off: uintptr = 2
	if fnb[0] != 's' {
		off = 5
	}
	rest := libc.strlen(transmute(cstring)(rawptr(uintptr(rawptr(funcname)) + off)))
	newname := ([^]u8)(xmalloc(sid_buflen + rest + 1))
	libc.memcpy(rawptr(newname), rawptr(&sid_buf[0]), sid_buflen)
	libc.memcpy(rawptr(uintptr(newname) + uintptr(sid_buflen)), rawptr(uintptr(rawptr(funcname)) + off), rest + 1)
	return transmute(cstring)(newname)
}

// —— Batch 24i: func_call ——
MAX_FUNC_ARGS_O :: 20
PT_ARGC_OFF_O :: 28
E699_S :: "E699: Too many arguments"

// Call function with list args (copies args, VAR_FIXED-safe).
@(export)
func_call :: proc "c" (name: cstring, args: rawptr, partial: rawptr, selfdict: rawptr, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	argv: [MAX_FUNC_ARGS_O + 1]Typval_T
	argc: C.int = 0
	r: C.int = 0
	pt_argc: C.int = 0
	if partial != nil {
		pt_argc = (^C.int)(uintptr(partial) + PT_ARGC_OFF_O)^
	}
	ok := true
	li := tv_list_first_o((^Typval_T)(args).vval)
	for li != nil {
		if argc == MAX_FUNC_ARGS_O - pt_argc {
			emsg(cstring(E699_S))
			ok = false
			break
		}
		tv_copy((^Typval_T)(uintptr(li) + 16), &argv[argc])
		argc += 1
		li = (^rawptr)(li)^
	}
	if ok {
		funcexe := Funcexe_T{}
		lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		funcexe.firstline = lnum
		funcexe.lastline = lnum
		funcexe.evaluate = true
		funcexe.partial = partial
		funcexe.selfdict = selfdict
		r = call_func(name, -1, rettv, argc, &argv[0], &funcexe)
	}
	for argc > 0 {
		argc -= 1
		tv_clear_e(&argv[argc])
	}
	return r
}

// —— Batch 24j: error + argv + retnr ——
FCERR_UNKNOWN_O :: 0
FCERR_TOOMANY_O :: 1
FCERR_TOOFEW_O :: 2
FCERR_DICT_O :: 4
FCERR_OTHER_O :: 6
FCERR_DELETED_O :: 7
FCERR_NOTMETHOD_O :: 8
foreign _ {
	@(link_name = "callback_call")
	callback_call_e :: proc "c" (callback: rawptr, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T) -> bool ---
}

// Report a user-function call error (static in C).
user_func_error_o :: proc "c" (error: C.int, name: cstring, found_var: bool) {
	context = runtime.default_context()
	switch error {
	case FCERR_UNKNOWN_O:
		if found_var {
			semsg(cstring("E1085: Not a callable type: %s"), name)
		} else {
			emsg_funcname(cstring("E117: Unknown function: %s"), name)
		}
	case FCERR_NOTMETHOD_O:
		emsg_funcname(cstring("E276: Cannot use function as a method: %s"), name)
	case FCERR_DELETED_O:
		emsg_funcname(cstring("E933: Function was deleted: %s"), name)
	case FCERR_TOOMANY_O:
		emsg_funcname(cstring("E118: Too many arguments for function: %s"), name)
	case FCERR_TOOFEW_O:
		emsg_funcname(cstring("E119: Not enough arguments for function: %s"), name)
	case FCERR_SCRIPT_O:
		emsg_funcname(cstring("E120: Using <SID> not in a script context: %s"), name)
	case FCERR_DICT_O:
		emsg_funcname(cstring("E725: Calling dict function without Dictionary: %s"), name)
	}
}

// Prepend method base to argv (static in C).
argv_add_base_o :: proc "c" (basetv: rawptr, argvars: ^rawptr, argcount: ^C.int, new_argvars: rawptr, argv_base: ^C.int) {
	context = runtime.default_context()
	if basetv != nil {
		libc.memmove(rawptr(uintptr(new_argvars) + 16), argvars^, C.size_t(argcount^) * 16)
		(^Typval_T)(new_argvars)^ = (^Typval_T)(basetv)^
		argcount^ += 1
		argvars^ = new_argvars
		argv_base^ = 1
	}
}

// Call a callback, return number (-2 on failure).
@(export)
callback_call_retnr :: proc "c" (callback: rawptr, argcount: C.int, argvars: ^Typval_T) -> C.longlong {
	context = runtime.default_context()
	rettv: Typval_T
	if !callback_call_e(callback, argcount, argvars, &rettv) {
		return -2
	}
	retval := tv_get_number_chk(&rettv, nil)
	tv_clear_e(&rettv)
	return retval
}

// —— Batch 24k: call_func dispatcher ——
foreign _ {
	@(link_name = "script_autoload")
	script_autoload_e :: proc "c" (name: cstring, name_len: C.size_t, reload: bool) -> bool ---
	@(link_name = "update_force_abort")
	update_force_abort_e :: proc "c" () ---
	@(link_name = "nlua_call_vlua")
	nlua_call_vlua_e :: proc "c" (s: cstring, len: C.size_t, args: ^Typval_T, argcount: C.int, ret_tv: ^Typval_T) ---
	@(link_name = "nlua_exec_typval_callable")
	nlua_exec_typval_callable_e :: proc "c" (lua_cb: C.int, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T) -> C.int ---
	@(link_name = "call_internal_func")
	call_internal_func_e :: proc "c" (fname: cstring, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T) -> C.int ---
	@(link_name = "call_internal_method")
	call_internal_method_e :: proc "c" (fname: cstring, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T, basetv: rawptr) -> C.int ---
}

FC_RANGE_O :: 0x02
FC_DELETED_O :: 0x10
FC_LUAREF_O :: 0x800
EVENT_FUNCUNDEFINED_O :: 68
PT_FUNC_OFF_O :: 16
PT_ARGV_OFF_O :: 32
PT_DICT_OFF_O :: 40
PT_AUTO_OFF_O :: 24
UF_LUAREF_OFF_O :: 96
E132_S :: "E132: Function call depth is higher than 'maxfuncdepth'"

// Postponed-argv filler signature (userfunc.h ArgvFunc).
ArgvFunc_T :: proc "c" (C.int, ^Typval_T, C.int, rawptr) -> C.int

// Argcount check for user functions (static in C).
check_user_func_argcount_o :: proc "c" (fp: rawptr, argcount: C.int) -> C.int {
	context = runtime.default_context()
	regular_args := (^C.int)(uintptr(fp) + UF_ARGS_OFF_O)^
	if argcount < regular_args - (^C.int)(uintptr(fp) + UF_DEF_ARGS_OFF_O)^ {
		return FCERR_TOOFEW_O
	} else if !(^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ && argcount > regular_args {
		return FCERR_TOOMANY_O
	}
	return FCERR_UNKNOWN_O
}

// User-function call with argcount check (static in C).
call_user_func_check_o :: proc "c" (fp: rawptr, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T, fe: ^Funcexe_T, selfdict: rawptr) -> C.int {
	context = runtime.default_context()
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_LUAREF_O) != 0 {
		return nlua_exec_typval_callable_e((^C.int)(uintptr(fp) + UF_LUAREF_OFF_O)^, argcount, argvars, rettv)
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_RANGE_O) != 0 && fe.doesrange != nil {
		(^bool)(fe.doesrange)^ = true
	}
	error := check_user_func_argcount_o(fp, argcount)
	if error != FCERR_UNKNOWN_O {
		return error
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DICT_O) != 0 && selfdict == nil {
		error = FCERR_DICT_O
	} else {
		sd: rawptr = nil
		if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DICT_O) != 0 {
			sd = selfdict
		}
		call_user_func(fp, argcount, argvars, rettv, fe.firstline, fe.lastline, sd)
		error = FCERR_NONE_O
	}
	return error
}

// Main function-call dispatcher.
@(export)
call_func :: proc "c" (funcname: cstring, len: C.int, rettv: ^Typval_T, argcount_in: C.int, argvars_in: ^Typval_T, fe: ^Funcexe_T) -> C.int {
	context = runtime.default_context()
	ret: C.int = FAIL_E
	error: C.int = FCERR_NONE_O
	fp: rawptr = nil
	fname_buf: [FLEN_FIXED_O + 1]u8
	tofree: rawptr = nil
	fname: cstring = nil
	name: cstring = nil
	argcount := argcount_in
	av := argvars_in
	selfdict := fe.selfdict
	argv: [MAX_FUNC_ARGS_O + 1]Typval_T
	argv_clear: C.int = 0
	argv_base: C.int = 0
	partial := fe.partial
	fname_in := funcname
	nlen := len
	rettv.v_type = VAR_UNKNOWN
	if nlen <= 0 {
		nlen = C.int(libc.strlen(funcname))
	}
	if partial != nil {
		fp = (^rawptr)(uintptr(partial) + PT_FUNC_OFF_O)^
	}
	if fp == nil {
		name = transmute(cstring)(xmemdupz_o2(transmute(^u8)(rawptr(funcname)), C.size_t(nlen)))
		fname = fname_trans_sid_o(name, ([^]u8)(&fname_buf[0]), &tofree, &error)
	}
	if fe.doesrange != nil {
		(^bool)(fe.doesrange)^ = false
	}
	if partial != nil {
		pt_dict := (^rawptr)(uintptr(partial) + PT_DICT_OFF_O)^
		pt_auto := (^bool)(uintptr(partial) + PT_AUTO_OFF_O)^
		if pt_dict != nil && (selfdict == nil || !pt_auto) {
			selfdict = pt_dict
		}
		if error == FCERR_NONE_O {
			pt_argc := (^C.int)(uintptr(partial) + PT_ARGC_OFF_O)^
			if pt_argc > 0 {
				pt_argv := ([^]Typval_T)((^rawptr)(uintptr(partial) + PT_ARGV_OFF_O)^)
				ain := ([^]Typval_T)(argvars_in)
				argv_clear = 0
				for argv_clear < pt_argc {
					if argv_clear + argcount_in >= MAX_FUNC_ARGS_O {
						error = FCERR_TOOMANY_O
						break
					}
					tv_copy(&pt_argv[argv_clear], &argv[argv_clear])
					argv_clear += 1
				}
				if error == FCERR_NONE_O {
					for i: C.int = 0; i < argcount_in; i += 1 {
						argv[i + argv_clear] = ain[i]
					}
					av = &argv[0]
					argcount = pt_argc + argcount_in
				}
			}
		}
	}
	if error == FCERR_NONE_O && fe.evaluate {
		is_global := fp == nil && ([^]u8)(fname)[0] == 'g' && ([^]u8)(fname)[1] == ':'
		rfname := fname
		if is_global {
			rfname = transmute(cstring)(rawptr(uintptr(rawptr(fname)) + uintptr(2)))
		}
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(0))
		error = FCERR_UNKNOWN_O
		if is_luafunc_e(partial) {
			if nlen > 0 {
				error = FCERR_NONE_O
				argv_add_base_o(fe.basetv, transmute(^rawptr)(&av), &argcount, rawptr(&argv[0]), &argv_base)
				nlua_call_vlua_e(funcname, C.size_t(nlen), av, argcount, rettv)
			} else {
				xfree(rawptr(name))
				name = nil
				fname_in = cstring("v:lua")
			}
		} else if fp != nil || !builtin_function_o(rfname, -1) {
			if fp == nil {
				fp = find_func(rfname)
			}
			if fp == nil && apply_autocmds(EVENT_FUNCUNDEFINED_O, rfname, rfname, true, nil) && !aborting_r() {
				fp = find_func(rfname)
			}
			if fp == nil && script_autoload_e(rfname, libc.strlen(rfname), true) && !aborting_r() {
				fp = find_func(rfname)
			}
			if fp != nil && ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DELETED_O) != 0 {
				error = FCERR_DELETED_O
			} else if fp != nil {
				if fe.argv_func != nil {
					argcount = (cast(ArgvFunc_T)(fe.argv_func))(argcount, av, argv_clear, fp)
				}
				argv_add_base_o(fe.basetv, transmute(^rawptr)(&av), &argcount, rawptr(&argv[0]), &argv_base)
				error = call_user_func_check_o(fp, argcount, av, rettv, fe, selfdict)
			}
		} else if fe.basetv != nil {
			error = call_internal_method_e(fname, argcount, av, rettv, fe.basetv)
		} else {
			error = call_internal_func_e(fname, argcount, av, rettv)
		}
		update_force_abort_e()
	}
	if error == FCERR_NONE_O {
		ret = OK_E
	}
	if !aborting_r() {
		dispname := fname_in
		if name != nil {
			dispname = name
		}
		user_func_error_o(error, dispname, fe.found_var)
	}
	for argv_clear > 0 {
		argv_clear -= 1
		tv_clear_e(&argv[argv_clear + argv_base])
	}
	xfree(tofree)
	xfree(rawptr(name))
	return ret
}

// —— Batch 24h: get_user_func_name ——
// (func_hashtab_state_e shim removed in 24ad: reads Odin func_hashtab directly.)

// hashtab walk offsets (cc-probed): hashitem 16B (hash@0, key@8), HI2UF = key - UF_NAME_OFF_O.
HASHITEM_SIZE_O :: 16
HI_KEY_OFF_O :: 8
FC_DICT_O :: 0x04
EXPAND_USER_FUNC_O :: 19

// File-statics for the ExpandGeneric iteration.
gufn_done_o:    C.size_t
gufn_changed_o: C.int
gufn_hi_o:      rawptr

// True for global (non-<SNR>) functions (static in C).
func_is_global_o :: proc "c" (fp: rawptr) -> bool {
	context = runtime.default_context()
	return ([^]u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O))[0] != 0x80
}

// Copy fp name to buf with <SNR> handling; returns print length (static in C).
cat_func_name_o :: proc "c" (buf: [^]u8, bufsize: C.size_t, fp: rawptr) -> C.int {
	context = runtime.default_context()
	uflen := (^C.size_t)(uintptr(fp) + UF_NAMELEN_OFF_O)^
	if uflen == 0 {
		libc.abort()
	}
	name := rawptr(uintptr(fp) + UF_NAME_OFF_O)
	pre: C.size_t = 0
	src := name
	if !func_is_global_o(fp) && uflen > 3 {
		buf[0] = '<'
		buf[1] = 'S'
		buf[2] = 'N'
		buf[3] = 'R'
		buf[4] = '>'
		pre = 5
		src = rawptr(uintptr(name) + uintptr(3))
	}
	srclen := libc.strlen(transmute(cstring)(src))
	total := pre + srclen
	n := total
	if n >= bufsize {
		n = bufsize - 1
	}
	if pre > 0 {
		libc.memcpy(rawptr(uintptr(buf) + uintptr(pre)), src, n - pre)
	} else {
		libc.memcpy(rawptr(buf), src, n)
	}
	buf[uintptr(n)] = 0
	length: C.int = 0
	if total >= bufsize {
		length = C.int(bufsize) - 1
	} else {
		length = C.int(total)
	}
	if length <= 0 {
		libc.abort()
	}
	return length
}

// Next user function name for cmdline completion (static state).
@(export)
get_user_func_name :: proc "c" (xp: rawptr, idx: C.int) -> cstring {
	context = runtime.default_context()
	arr := func_hashtab.ht_array
	used := func_hashtab.ht_used
	changed_now := func_hashtab.ht_changed
	if idx == 0 {
		gufn_done_o = 0
		gufn_hi_o = arr
		gufn_changed_o = changed_now
	}
	if gufn_hi_o == nil {
		return nil
	}
	if gufn_changed_o == changed_now && gufn_done_o < used {
		if gufn_done_o > 0 {
			gufn_hi_o = rawptr(uintptr(gufn_hi_o) + uintptr(HASHITEM_SIZE_O))
		}
		gufn_done_o += 1
		for {
			key := (^rawptr)(uintptr(gufn_hi_o) + HI_KEY_OFF_O)^
			if key != nil && key != transmute(rawptr)(&hash_removed_c) {
				break
			}
			gufn_hi_o = rawptr(uintptr(gufn_hi_o) + uintptr(HASHITEM_SIZE_O))
		}
		fp := rawptr(uintptr((^rawptr)(uintptr(gufn_hi_o) + HI_KEY_OFF_O)^) - uintptr(UF_NAME_OFF_O))
		fpname := rawptr(uintptr(fp) + UF_NAME_OFF_O)
		if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DICT_O) != 0 || libc.strncmp(transmute(cstring)(fpname), cstring("<lambda>"), 8) == 0 {
			return cstring("")
		}
		if (^C.size_t)(uintptr(fp) + UF_NAMELEN_OFF_O)^ + 4 >= IOSIZE_O {
			return transmute(cstring)(fpname)
		}
		length := cat_func_name_o(([^]u8)(&IObuff[0]), IOSIZE_O, fp)
		if (^C.int)(uintptr(xp) + XP_CONTEXT_OFF_O)^ != EXPAND_USER_FUNC_O {
			xstrlcpy_o(transmute(cstring)(rawptr(uintptr(rawptr(cstring(&IObuff[0]))) + uintptr(length))), cstring("("), IOSIZE_O - C.size_t(length))
			if !(^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ && (^C.int)(uintptr(fp) + UF_ARGS_OFF_O)^ == 0 {
				length += 1
				xstrlcpy_o(transmute(cstring)(rawptr(uintptr(rawptr(cstring(&IObuff[0]))) + uintptr(length))), cstring(")"), IOSIZE_O - C.size_t(length))
			}
		}
		return cstring(&IObuff[0])
	}
	return nil
}

// —— Batch 24l: call_simple_func ——

// No-arg function call for "expr" options (NOTDONE when missing).
@(export)
call_simple_func :: proc "c" (funcname: cstring, len: C.size_t, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	ret: C.int = FAIL_E
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	name := xstrnsave_c(funcname, len)
	error: C.int = FCERR_NONE_O
	tofree: rawptr = nil
	fname_buf: [FLEN_FIXED_O + 1]u8
	fname := fname_trans_sid_o(transmute(cstring)(name), ([^]u8)(&fname_buf[0]), &tofree, &error)
	fnb := ([^]u8)(fname)
	rfname := fname
	if fnb[0] == 'g' && fnb[1] == ':' {
		rfname = transmute(cstring)(rawptr(uintptr(rawptr(fname)) + uintptr(2)))
	}
	fp := find_func(rfname)
	if fp == nil {
		ret = NOTDONE_O
	} else if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DELETED_O) != 0 {
		error = FCERR_DELETED_O
	} else {
		argvars: [1]Typval_T
		argvars[0].v_type = VAR_UNKNOWN
		fe := Funcexe_T{}
		fe.evaluate = true
		error = call_user_func_check_o(fp, 0, &argvars[0], rettv, &fe, nil)
		if error == FCERR_NONE_O {
			ret = OK_E
		}
	}
	user_func_error_o(error, transmute(cstring)(name), false)
	xfree(tofree)
	xfree(rawptr(name))
	return ret
}

// —— Batch 24m: call_simple_luafunc ——

// Zero-arg v:lua call for bare expressions.
@(export)
call_simple_luafunc :: proc "c" (funcname: cstring, len: C.size_t, rettv: ^Typval_T) -> C.int {
	context = runtime.default_context()
	rettv.v_type = VAR_NUMBER
	rettv.vval = transmute(rawptr)(C.longlong(0))
	argvars: [1]Typval_T
	argvars[0].v_type = VAR_UNKNOWN
	nlua_call_vlua_e(funcname, len, &argvars[0], 0, rettv)
	return OK_E
}

// —— Batch 24p: funccall globals + lifecycle ——

// funccall_T offsets (cc-probed, sizeof 2080).
FC_FUNC_OFF_O :: 0
FC_RETTV_OFF_O :: 1984
FC_CALLER_OFF_O :: 2040
// funccal_entry_T: top@0, next@8.

// Current function call chain (was C statics).
@(export)
current_funccal: rawptr
@(export)
funccal_stack: rawptr

// Allocate funccall, link into chain.
@(export)
create_funccal :: proc "c" (fp: rawptr, rettv: ^Typval_T) -> rawptr {
	context = runtime.default_context()
	fc := xcalloc(1, 2080)
	(^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^ = current_funccal
	current_funccal = fc
	(^rawptr)(uintptr(fc) + FC_FUNC_OFF_O)^ = fp
	func_ptr_ref(fp)
	(^rawptr)(uintptr(fc) + FC_RETTV_OFF_O)^ = rettv
	return fc
}

// Pop current funccal.
@(export)
remove_funccal :: proc "c" () {
	context = runtime.default_context()
	fc := current_funccal
	current_funccal = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
	free_funccal_o(fc)
}

// Save chain for autocmds/:source.
@(export)
save_funccal :: proc "c" (entry: rawptr) {
	context = runtime.default_context()
	(^rawptr)(uintptr(entry) + 0)^ = current_funccal
	(^rawptr)(uintptr(entry) + 8)^ = funccal_stack
	funccal_stack = entry
	current_funccal = nil
}

@(export)
restore_funccal :: proc "c" () {
	context = runtime.default_context()
	if funccal_stack == nil {
		iemsg_r(cstring("INTERNAL: restore_funccal()"))
	} else {
		current_funccal = (^rawptr)(uintptr(funccal_stack) + 0)^
		funccal_stack = (^rawptr)(uintptr(funccal_stack) + 8)^
	}
}

@(export)
get_current_funccal :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return current_funccal
}

@(export)
set_current_funccal :: proc "c" (fc: rawptr) {
	context = runtime.default_context()
	current_funccal = fc
}

// —— Batch 24s: call_user_func engine ——
foreign _ {
	@(link_name = "p_mfd")
	p_mfd_g: C.longlong
	@(link_name = "trylevel")
	trylevel_g: C.int
	@(link_name = "eval_lavars_used")
	eval_lavars_used_g: ^bool
	@(link_name = "verbose_enter_scroll")
	verbose_enter_scroll_e :: proc "c" () ---
	@(link_name = "verbose_leave_scroll")
	verbose_leave_scroll_e :: proc "c" () ---
	@(link_name = "trunc_string")
	trunc_string_e :: proc "c" (s: cstring, buf: ^u8, room: C.int, buflen: C.int) ---
	@(link_name = "has_profiling")
	has_profiling_e :: proc "c" (file: bool, fname: cstring, fp: rawptr) -> bool ---
	@(link_name = "func_do_profile")
	func_do_profile_e :: proc "c" (fp: rawptr) ---
	@(link_name = "profile_start")
	profile_start_e :: proc "c" () -> u64 ---
	@(link_name = "profile_zero")
	profile_zero_e :: proc "c" () -> u64 ---
	@(link_name = "profile_end")
	profile_end_e :: proc "c" (tm: u64) -> u64 ---
	@(link_name = "profile_sub_wait")
	profile_sub_wait_e :: proc "c" (tm: u64, tma: u64) -> u64 ---
	@(link_name = "profile_add")
	profile_add_e :: proc "c" (tm1: u64, tm2: u64) -> u64 ---
	@(link_name = "profile_self")
	profile_self_e :: proc "c" (self: u64, total: u64, children: u64) -> u64 ---
	@(link_name = "script_prof_save")
	script_prof_save_e :: proc "c" (tm: ^u64) ---
	@(link_name = "script_prof_restore")
	script_prof_restore_e :: proc "c" (tm: ^u64) ---
	@(link_name = "estack_push_ufunc")
	estack_push_ufunc_e :: proc "c" (fp: rawptr, lnum: C.int) ---
	@(link_name = "saveRedobuff")
	saveRedobuff_e :: proc "c" (save: rawptr) ---
	@(link_name = "restoreRedobuff")
	restoreRedobuff_e :: proc "c" (save: rawptr) ---
	@(link_name = "do_cmdline")
	do_cmdline_e :: proc "c" (cmdline: cstring, fgetline: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> cstring, cookie: rawptr, flags: C.int) -> C.int ---
}

FC_SANDBOX_O :: 0x40
FC_NOARGS_O :: 0x200
DOCMD_REPEAT_O :: 0x04
MSG_BUF_CLEN_O :: 80
SELF_KEY_O : [5]u8 = {'s', 'e', 'l', 'f', 0}
ZERO3_KEY_O : [4]u8 = {'0', '0', '0', 0}
UF_PROFILING_OFF_O :: 88
UF_TM_COUNT_OFF_O :: 100
UF_TM_CHILDREN_OFF_O :: 120
UF_TM_TOTAL_OFF_O :: 104
UF_TM_SELF_OFF_O :: 112
UF_TML_CHILDREN_OFF_O :: 160
UF_SCRIPT_CTX_OFF_O :: 184

// SOURCING_NAME (script name or nil).
sourcing_name_str_o :: proc "c" () -> cstring {
	context = runtime.default_context()
	if exestack.ga_len <= 0 {
		return nil
	}
	idx := int(exestack.ga_len - 1)
	return ([^]Estack)(exestack.ga_data)[idx].es_name
}

@(private = "file")
depth_g: C.int

// Call user function body with prepared arguments.
@(export)
call_user_func :: proc "c" (fp: rawptr, argcount: C.int, argvars: ^Typval_T, rettv: ^Typval_T, firstline: C.int, lastline: C.int, selfdict: rawptr) {
	context = runtime.default_context()
	using_sandbox := false
	v: rawptr = nil
	fixvar_idx: C.int = 0
	islambda := false
	numbuf: [NUMBUFLEN]u8
	name: rawptr = nil
	namelen: C.size_t = 0
	tv_to_free: [MAX_FUNC_ARGS_O + 1]rawptr
	tv_to_free_len: C.int = 0
	wait_start: u64 = 0
	call_start: u64 = 0
	started_profiling := false
	did_save_redo := false
	save_redo: [112]u8
	// ESTACK_CHECK_* are no-ops (no ABORT_ON_INTERNAL_ERROR in this build).
	if C.longlong(depth_g) >= p_mfd_g {
		emsg(cstring(E132_S))
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(-1))
		return
	}
	depth_g += 1
	save_search_patterns()
	if !ins_compl_active() {
		saveRedobuff_e(rawptr(&save_redo[0]))
		did_save_redo = true
	}
	(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ += 1
	line_breakcheck()
	fc := create_funccal(fp, rettv)
	(^C.int)(uintptr(fc) + FC_LEVEL_OFF_O)^ = ex_nesting_level_g
	(^C.int)(uintptr(fc) + FC_BREAKPOINT_OFF_O)^ = dbg_find_breakpoint_e(false, transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), 0)
	(^C.int)(uintptr(fc) + FC_DBG_TICK_OFF_O)^ = debug_tick_g
	ga_init_r2((^Garray)(uintptr(fc) + FC_UFUNCS_OFF_O), 8, 1)
	if libc.strncmp(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), cstring("<lambda>"), 8) == 0 {
		islambda = true
	}
	init_var_dict(rawptr(uintptr(fc) + FC_L_VARS_OFF_O), rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 360), VAR_DEF_SCOPE_O)
	if selfdict != nil {
		v = rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40)
		fixvar_idx += 1
		name = rawptr(uintptr(v) + 17)
		libc.memcpy(name, rawptr(&SELF_KEY_O[0]), 5)
		([^]u8)(uintptr(v) + 16)[0] = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
		hash_add_e(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16), transmute(^u8)(rawptr(uintptr(v) + 17)))
		(^Typval_T)(v).v_type = VAR_DICT
		(^Typval_T)(v).v_lock = VAR_UNLOCKED_O
		(^Typval_T)(v).vval = transmute(rawptr)(selfdict)
		(^C.int)(uintptr(selfdict) + 8)^ += 1
	}
	init_var_dict(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O), rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 360), VAR_SCOPE_O)
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_NOARGS_O) == 0 {
		ga_args := (^C.int)(uintptr(fp) + UF_ARGS_OFF_O)^
		extra: C.int = 0
		if argcount >= ga_args {
			extra = argcount - ga_args
		}
		add_nr_var_o(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O), rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40), cstring("0"), C.longlong(extra))
		fixvar_idx += 1
	}
	lst := rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O)
	if lst != nil {
		(^C.int)(uintptr(lst) + 72)^ = VAR_FIXED_O
	}
	_ = lst
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_NOARGS_O) == 0 {
		v = rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40)
		fixvar_idx += 1
		name = rawptr(uintptr(v) + 17)
		libc.memcpy(name, rawptr(&ZERO3_KEY_O[0]), 4)
		([^]u8)(uintptr(v) + 16)[0] = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
		hash_add_e(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16), transmute(^u8)(rawptr(uintptr(v) + 17)))
		(^Typval_T)(v).v_type = VAR_LIST
		(^Typval_T)(v).v_lock = VAR_FIXED_O
		(^Typval_T)(v).vval = transmute(rawptr)(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O))
	}
	tv_list_init_static(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O))
	vl := rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O)
	if vl != nil {
		(^C.int)(uintptr(vl) + 72)^ = VAR_FIXED_O
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_NOARGS_O) == 0 {
		add_nr_var_o(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O), rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40), cstring("firstline"), C.longlong(firstline))
		fixvar_idx += 1
		add_nr_var_o(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O), rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40), cstring("lastline"), C.longlong(lastline))
		fixvar_idx += 1
	}
	default_arg_err := false
	ain := ([^]Typval_T)(argvars)
	i: C.int = 0
	ga_args_len := (^C.int)(uintptr(fp) + UF_ARGS_OFF_O)^
	for i < argcount || i < ga_args_len {
		addlocal := false
		isdefault := false
		def_rettv := Typval_T{v_type = VAR_NUMBER}
		def_rettv.vval = transmute(rawptr)(C.longlong(-1))
		ai := i - ga_args_len
		if ai < 0 {
			name = rawptr(([^]cstring)((^rawptr)(uintptr(fp) + UF_ARGS_OFF_O + 16)^)[uintptr(i)])
			if islambda {
				addlocal = true
			}
			if ai + (^C.int)(uintptr(fp) + UF_DEF_ARGS_OFF_O)^ >= 0 && i >= argcount {
				isdefault = true
			}
			if isdefault {
				de := transmute(cstring)(([^]cstring)((^rawptr)(uintptr(fp) + UF_DEF_ARGS_OFF_O + 16)^)[uintptr(ai + (^C.int)(uintptr(fp) + UF_DEF_ARGS_OFF_O)^)])
				ea := Evalarg_T{eval_flags = 1}
				if eval1_e(&de, &def_rettv, rawptr(&ea)) == FAIL_E {
					default_arg_err = true
					break
				}
			}
			namelen = libc.strlen(transmute(cstring)(name))
		} else {
			if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_NOARGS_O) != 0 {
				break
			}
			namelen = C.size_t(libc.snprintf(([^]u8)(&numbuf[0]), NUMBUFLEN, cstring("%d"), ai + 1))
			name = rawptr(&numbuf[0])
		}
		if fixvar_idx < FIXVAR_CNT_O && C.longlong(namelen) <= C.longlong(VAR_SHORT_LEN_O) {
			v = rawptr(uintptr(fc) + FC_FIXVAR_OFF_O + uintptr(fixvar_idx) * 40)
			fixvar_idx += 1
			([^]u8)(uintptr(v) + 16)[0] = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
			libc.memcpy(rawptr(uintptr(v) + 17), name, namelen + 1)
		} else {
			v = rawptr(tv_dict_item_alloc_len(transmute(cstring)(name), namelen))
			([^]u8)(uintptr(v) + 16)[0] |= DI_FLAGS_RO_O | DI_FLAGS_FIX_O
		}
		if isdefault {
			(^Typval_T)(v)^ = def_rettv
		} else {
			(^Typval_T)(v)^ = ain[i]
		}
		(^C.int)(uintptr(v) + 4)^ = VAR_FIXED_O
		if isdefault {
			tv_to_free[tv_to_free_len] = v
			tv_to_free_len += 1
		}
		if addlocal {
			tv_copy((^Typval_T)(v), (^Typval_T)(v))
			hash_add_e(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16), transmute(^u8)(rawptr(uintptr(v) + 17)))
		} else {
			hash_add_e(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16), transmute(^u8)(rawptr(uintptr(v) + 17)))
		}
		if ai >= 0 && ai < MAX_FUNC_ARGS_O {
			li := rawptr(uintptr(fc) + FC_L_LISTITEMS_OFF_O + uintptr(ai) * 32)
			(^Typval_T)(uintptr(li) + 16)^ = ain[i]
			(^C.int)(uintptr(li) + 20)^ = VAR_FIXED_O
			tv_list_append(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O), li)
		}
		i += 1
	}
	RedrawingDisabled += 1
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_SANDBOX_O) != 0 {
		using_sandbox = true
		sandbox += 1
	}
	estack_push_ufunc_e(fp, 1)
	if p_verbose >= 12 {
		no_wait_return += 1
		verbose_enter_scroll_e()
		smsg(0, cstring("calling %s"), sourcing_name_str_o())
		if p_verbose >= 14 {
			msg_puts(cstring("("))
			for j: C.int = 0; j < argcount; j += 1 {
				if j > 0 {
					msg_puts(cstring(", "))
				}
				if ain[j].v_type == VAR_NUMBER {
					msg_outnum(C.int(transmute(C.longlong)(ain[j].vval)))
				} else {
					emsg_off += 1
					tofree := encode_tv2string_e((^Typval_T)(uintptr(argvars) + uintptr(j) * 16), nil)
					emsg_off -= 1
					if tofree != nil {
						s := transmute(cstring)(tofree)
						buf: [MSG_BUF_LEN_O]u8
						if vim_strsize_r(s) > MSG_BUF_CLEN_O {
							trunc_string_e(s, &buf[0], MSG_BUF_CLEN_O, MSG_BUF_LEN_O)
							s = transmute(cstring)(&buf[0])
						}
						msg_puts(s)
						xfree(rawptr(tofree))
					}
				}
			}
			msg_puts(cstring(")"))
		}
		msg_puts(cstring("\n"))
		verbose_leave_scroll_e()
		no_wait_return -= 1
	}
	do_profiling_yes := do_profiling == PROF_YES
	func_not_yet_profiling_but_should := do_profiling_yes && !(^bool)(uintptr(fp) + UF_PROFILING_OFF_O)^ && has_profiling_e(false, transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), nil)
	if func_not_yet_profiling_but_should {
		started_profiling = true
		func_do_profile_e(fp)
	}
	caller_fp: rawptr = nil
	caller_profiling := false
	if (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^ != nil {
		caller_fp = (^rawptr)(uintptr((^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^) + FC_FUNC_OFF_O)^
		caller_profiling = (^bool)(uintptr(caller_fp) + UF_PROFILING_OFF_O)^
	}
	func_or_caller_profiling := do_profiling_yes && ((^bool)(uintptr(fp) + UF_PROFILING_OFF_O)^ || caller_profiling)
	if func_or_caller_profiling {
		(^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^ += 1
		call_start = profile_start_e()
		(^u64)(uintptr(fp) + UF_TM_CHILDREN_OFF_O)^ = profile_zero_e()
	}
	if do_profiling_yes {
		script_prof_save_e(&wait_start)
	}
	saved_sctx: [24]u8
	libc.memcpy(rawptr(&saved_sctx[0]), rawptr(&current_sctx_buf[0]), 24)
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(uintptr(fp) + UF_SCRIPT_CTX_OFF_O), 24)
	save_did_emsg := did_emsg_g()
	did_emsg_set(false)
	if default_arg_err && (((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0 || trylevel_g > 0) {
		did_emsg_set(true)
	} else if islambda {
		line0 := ([^]rawptr)((^rawptr)(uintptr(fp) + UF_LINES_OFF_O + 16)^)[0]
		p := transmute(cstring)(rawptr(uintptr(line0) + 7))
		ex_nesting_level_g += 1
		ea2 := Evalarg_T{eval_flags = 1}
		eval1_e(&p, rettv, rawptr(&ea2))
		ex_nesting_level_g -= 1
	} else {
		do_cmdline_e(nil, get_func_line, rawptr(fc), DOCMD_VERBOSE_O | DOCMD_NOWAIT_O | DOCMD_REPEAT_O)
	}
	handle_defer_one_o(current_funccal)
	RedrawingDisabled -= 1
	if (did_emsg_g() != 0 && ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0) || rettv.v_type == VAR_UNKNOWN {
		tv_clear_e(rettv)
		rettv.v_type = VAR_NUMBER
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	}
	if func_or_caller_profiling {
		call_start = profile_end_e(call_start)
		call_start = profile_sub_wait_e(wait_start, call_start)
		(^u64)(uintptr(fp) + UF_TM_TOTAL_OFF_O)^ = profile_add_e((^u64)(uintptr(fp) + UF_TM_TOTAL_OFF_O)^, call_start)
		(^u64)(uintptr(fp) + UF_TM_SELF_OFF_O)^ = profile_self_e((^u64)(uintptr(fp) + UF_TM_SELF_OFF_O)^, call_start, (^u64)(uintptr(fp) + UF_TM_CHILDREN_OFF_O)^)
		if caller_profiling {
			(^u64)(uintptr(caller_fp) + UF_TM_CHILDREN_OFF_O)^ = profile_add_e((^u64)(uintptr(caller_fp) + UF_TM_CHILDREN_OFF_O)^, call_start)
			(^u64)(uintptr(caller_fp) + UF_TML_CHILDREN_OFF_O)^ = profile_add_e((^u64)(uintptr(caller_fp) + UF_TML_CHILDREN_OFF_O)^, call_start)
		}
		if started_profiling {
			(^bool)(uintptr(fp) + UF_PROFILING_OFF_O)^ = false
		}
	}
	if p_verbose >= 12 {
		no_wait_return += 1
		verbose_enter_scroll_e()
		if aborting_r() {
			smsg(0, cstring("%s aborted"), sourcing_name_str_o())
		} else if (^C.int)(uintptr((^rawptr)(uintptr(fc) + FC_RETTV_OFF_O)^) + 0)^ == VAR_NUMBER {
			fc_rettv := (^rawptr)(uintptr(fc) + FC_RETTV_OFF_O)^
			smsg(0, cstring("%s returning #%ld"), sourcing_name_str_o(), C.long(transmute(C.longlong)((^rawptr)(uintptr(fc_rettv) + 8)^)))
		} else {
			emsg_off += 1
			s := encode_tv2string_e((^Typval_T)((^rawptr)(uintptr(fc) + FC_RETTV_OFF_O)^), nil)
			tofree2 := s
			emsg_off -= 1
			if s != nil {
				ss := transmute(cstring)(s)
				buf2: [MSG_BUF_LEN_O]u8
				if vim_strsize_r(ss) > MSG_BUF_CLEN_O {
					trunc_string_e(ss, &buf2[0], MSG_BUF_CLEN_O, MSG_BUF_LEN_O)
					ss = transmute(cstring)(&buf2[0])
				}
				smsg(0, cstring("%s returning %s"), sourcing_name_str_o(), ss)
				xfree(rawptr(tofree2))
			}
		}
		msg_puts(cstring("\n"))
		verbose_leave_scroll_e()
		no_wait_return -= 1
	}
	libc.memcpy(rawptr(&current_sctx_buf[0]), rawptr(&saved_sctx[0]), 24)
	if do_profiling_yes {
		script_prof_restore_e(&wait_start)
	}
	if using_sandbox {
		sandbox -= 1
	}
	if p_verbose >= 12 && sourcing_name_str_o() != nil {
		no_wait_return += 1
		verbose_enter_scroll_e()
		smsg(0, cstring("continuing in %s"), sourcing_name_str_o())
		msg_puts(cstring("\n"))
		verbose_leave_scroll_e()
		no_wait_return -= 1
	}
	did_emsg_set(did_emsg_g() != 0 || save_did_emsg != 0)
	depth_g -= 1
	for k: C.int = 0; k < tv_to_free_len; k += 1 {
		tv_clear_e((^Typval_T)(tv_to_free[k]))
	}
	cleanup_function_call_o(fc)
	if (^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ - 1 <= 0 && (^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ <= 0 {
		(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ -= 1
		func_clear_free_o(fp, false)
	} else {
		(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ -= 1
	}
	if did_save_redo {
		restoreRedobuff_e(rawptr(&save_redo[0]))
	}
	restore_search_patterns()
}

// —— Batch 24r: get_func_line trio + handle_defer_one ——
foreign _ {
	@(link_name = "debug_tick")
	debug_tick_g: C.int
	@(link_name = "ex_nesting_level")
	ex_nesting_level_g: C.int
	@(link_name = "dbg_find_breakpoint")
	dbg_find_breakpoint_e :: proc "c" (file: bool, fname: cstring, after: C.int) -> C.int ---
	@(link_name = "aborted_in_try")
	aborted_in_try_e :: proc "c" () -> bool ---
	@(link_name = "func_line_start")
	func_line_start_e :: proc "c" (cookie: rawptr) ---
	@(link_name = "func_line_end")
	func_line_end_e :: proc "c" (cookie: rawptr) ---
	@(link_name = "dbg_breakpoint")
	dbg_breakpoint_e :: proc "c" (name: cstring, lnum: C.int) ---
	@(link_name = "exception_state_save")
	exception_state_save_e :: proc "c" (estate: rawptr) ---
	@(link_name = "exception_state_restore")
	exception_state_restore_e :: proc "c" (estate: rawptr) ---
	@(link_name = "exception_state_clear")
	exception_state_clear_e :: proc "c" () ---
}

FC_ABORT_O :: 0x01
UF_LINES_OFF_O :: 64
DEFER_STRIDE_O :: 352
DR_NAME_OFF_O :: 0
DR_ARGV_OFF_O :: 8
DR_ARGCOUNT_OFF_O :: 344

// SOURCING_LNUM setter (getter is sourcing_lnum_o in option.odin).
set_sourcing_lnum_o :: proc "c" (v: C.int) {
	context = runtime.default_context()
	idx := int(exestack.ga_len - 1)
	([^]Estack)(exestack.ga_data)[idx].es_lnum = i32(v)
}

// Next function line for do_cmdline (public).
@(export)
get_func_line :: proc "c" (c: C.int, cookie: rawptr, indent: C.int, do_concat: bool) -> cstring {
	context = runtime.default_context()
	fcp := cookie
	fp := (^rawptr)(uintptr(fcp) + FC_FUNC_OFF_O)^
	retval: cstring = nil
	if (^C.int)(uintptr(fcp) + FC_DBG_TICK_OFF_O)^ != debug_tick_g {
		(^C.int)(uintptr(fcp) + FC_BREAKPOINT_OFF_O)^ = dbg_find_breakpoint_e(false, transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), sourcing_lnum_o())
		(^C.int)(uintptr(fcp) + FC_DBG_TICK_OFF_O)^ = debug_tick_g
	}
	if do_profiling == PROF_YES {
		func_line_end_e(cookie)
	}
	ln := (^C.int)(uintptr(fcp) + FC_LINENR_OFF_O)^
	gl := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
	gd := (^rawptr)(uintptr(fp) + UF_LINES_OFF_O + 16)^
	abort_now := ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0 && did_emsg_g() != 0 && !aborted_in_try_e()
	if !abort_now && !(^bool)(uintptr(fcp) + FC_RETURNED_OFF_O)^ {
		for ln < gl && ([^]rawptr)(gd)[uintptr(ln)] == nil {
			ln += 1
		}
		(^C.int)(uintptr(fcp) + FC_LINENR_OFF_O)^ = ln
		if ln < gl {
			retval = transmute(cstring)(xstrdup_o(transmute(^u8)(([^]rawptr)(gd)[uintptr(ln)])))
			(^C.int)(uintptr(fcp) + FC_LINENR_OFF_O)^ = ln + 1
			set_sourcing_lnum_o(ln + 1)
			if do_profiling == PROF_YES {
				func_line_start_e(cookie)
			}
		}
	}
	if (^C.int)(uintptr(fcp) + FC_BREAKPOINT_OFF_O)^ != 0 && (^C.int)(uintptr(fcp) + FC_BREAKPOINT_OFF_O)^ <= sourcing_lnum_o() {
		dbg_breakpoint_e(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), sourcing_lnum_o())
		(^C.int)(uintptr(fcp) + FC_BREAKPOINT_OFF_O)^ = dbg_find_breakpoint_e(false, transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), sourcing_lnum_o())
		(^C.int)(uintptr(fcp) + FC_DBG_TICK_OFF_O)^ = debug_tick_g
	}
	return retval
}

// True when function ended (return/error).
@(export)
func_has_ended :: proc "c" (cookie: rawptr) -> C.int {
	context = runtime.default_context()
	fp := (^rawptr)(uintptr(cookie) + FC_FUNC_OFF_O)^
	if (((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0 && did_emsg_g() != 0 && !aborted_in_try_e()) || (^bool)(uintptr(cookie) + FC_RETURNED_OFF_O)^ {
		return 1
	}
	return 0
}

// True when function aborts on errors.
@(export)
func_has_abort :: proc "c" (cookie: rawptr) -> C.int {
	context = runtime.default_context()
	fp := (^rawptr)(uintptr(cookie) + FC_FUNC_OFF_O)^
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0 {
		return 1
	}
	return 0
}

// Call deferred functions at return (static in C).
handle_defer_one_o :: proc "c" (funccal: rawptr) {
	context = runtime.default_context()
	ga := (^Garray)(uintptr(funccal) + FC_DEFER_OFF_O)
	idx := ga.ga_len - 1
	for idx >= 0 {
		dr := rawptr(uintptr(ga.ga_data) + uintptr(idx) * DEFER_STRIDE_O)
		idx -= 1
		if (^rawptr)(uintptr(dr) + DR_NAME_OFF_O)^ == nil {
			continue
		}
		fe := Funcexe_T{}
		fe.evaluate = true
		rettv := Typval_T{v_type = VAR_UNKNOWN}
		name := transmute(cstring)((^rawptr)(uintptr(dr) + DR_NAME_OFF_O)^)
		(^rawptr)(uintptr(dr) + DR_NAME_OFF_O)^ = nil
		estate: [24]u8
		exception_state_save_e(rawptr(&estate[0]))
		exception_state_clear_e()
		ac := (^C.int)(uintptr(dr) + DR_ARGCOUNT_OFF_O)^
		av := (^Typval_T)(uintptr(dr) + DR_ARGV_OFF_O)
		call_func(name, -1, &rettv, ac, av, &fe)
		exception_state_restore_e(rawptr(&estate[0]))
		tv_clear_e(&rettv)
		xfree(rawptr(name))
		for i := ac - 1; i >= 0; i -= 1 {
			tv_clear_e((^Typval_T)(uintptr(dr) + DR_ARGV_OFF_O + uintptr(i) * 16))
		}
	}
	ga_clear_r((^Garray)(uintptr(funccal) + FC_DEFER_OFF_O))
}

// —— Batch 24q: funccall cleanup cluster ——
foreign _ {
	@(link_name = "want_garbage_collect")
	want_garbage_collect_g: bool
}

// funccall_T field offsets (cc-probed, sizeof 2080).
FC_REFCOUNT_OFF_O :: 2048
FC_L_VARS_OFF_O :: 496
FC_L_AVARS_OFF_O :: 880
FC_L_VARLIST_OFF_O :: 1264
FC_FIXVAR_OFF_O :: 16
FC_L_LISTITEMS_OFF_O :: 1344
FC_DEFER_OFF_O :: 2008
FC_UFUNCS_OFF_O :: 2056
FC_LEVEL_OFF_O :: 2000
FC_BREAKPOINT_OFF_O :: 1992
FC_DBG_TICK_OFF_O :: 1996
FC_RETURNED_OFF_O :: 12
FC_LINENR_OFF_O :: 8
FC_COPYID_OFF_O :: 2052
FIXVAR_CNT_O :: 12
VAR_SHORT_LEN_O :: 20
VAR_DEF_SCOPE_O :: 2
UF_SCOPED_OFF_O :: 216
LV_REFCOUNT_OFF_O :: 56

// Previously-freed funccall chain (was C static).
@(export)
previous_funccal: rawptr

// GC-made-copy counter (was C static in cleanup_function_call).
@(private = "file")
made_copy_g: C.int

// Add number var to dict (static in C).
add_nr_var_o :: proc "c" (dp: rawptr, v: rawptr, name: cstring, nr: C.longlong) {
	context = runtime.default_context()
	ln := libc.strlen(name)
	libc.memcpy(rawptr(uintptr(v) + 17), rawptr(name), ln + 1)
	([^]u8)(uintptr(v) + 16)[0] = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
	hash_add_e(rawptr(uintptr(dp) + 16), transmute(^u8)(rawptr(uintptr(v) + 17)))
	(^Typval_T)(v).v_type = VAR_NUMBER
	(^Typval_T)(v).v_lock = VAR_UNLOCKED_O
	(^Typval_T)(v).vval = transmute(rawptr)(nr)
}

// Register fp as closure of current funccall (static in C).
register_closure_o :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	if (^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^ == current_funccal {
		return
	}
	funccal_unref_o((^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^, fp, false)
	(^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^ = current_funccal
	(^C.int)(uintptr(current_funccal) + FC_REFCOUNT_OFF_O)^ += 1
	ga_grow_r((^Garray)(uintptr(current_funccal) + FC_UFUNCS_OFF_O), 1)
	ufgap := (^Garray)(uintptr(current_funccal) + FC_UFUNCS_OFF_O)
	([^]rawptr)(ufgap.ga_data)[uintptr(ufgap.ga_len)] = fp
	ufgap.ga_len += 1
}

// Free funccall struct itself (static in C; replaces nvim_odin_free_funccal shim).
free_funccal_o :: proc "c" (fc: rawptr) {
	context = runtime.default_context()
	ufgap := (^Garray)(uintptr(fc) + FC_UFUNCS_OFF_O)
	for i: C.int = 0; i < ufgap.ga_len; i += 1 {
		fp := ([^]rawptr)(ufgap.ga_data)[uintptr(i)]
		if fp != nil && (^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^ == fc {
			([^]rawptr)(ufgap.ga_data)[uintptr(i)] = nil
		}
	}
	ga_clear_r((^Garray)(uintptr(fc) + FC_UFUNCS_OFF_O))
	func_ptr_unref((^rawptr)(uintptr(fc) + FC_FUNC_OFF_O)^)
	xfree(fc)
}

// Free funccall contents (static in C).
free_funccal_contents_o :: proc "c" (fc: rawptr) {
	context = runtime.default_context()
	vars_clear(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16))
	vars_clear(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16))
	li := tv_list_first_o(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O))
	for li != nil {
		tv_clear_e((^Typval_T)(uintptr(li) + 16))
		li = (^rawptr)(li)^
	}
	free_funccal_o(fc)
}

// True when funccall still referenced outside (static inline in C).
fc_referenced_o :: proc "c" (fc: rawptr) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(fc) + FC_L_VARLIST_OFF_O + LV_REFCOUNT_OFF_O)^ != DO_NOT_FREE_CNT_O {
		return true
	}
	if (^C.int)(uintptr(fc) + FC_L_VARS_OFF_O + 8)^ != DO_NOT_FREE_CNT_O {
		return true
	}
	if (^C.int)(uintptr(fc) + FC_L_AVARS_OFF_O + 8)^ != DO_NOT_FREE_CNT_O {
		return true
	}
	return (^C.int)(uintptr(fc) + FC_REFCOUNT_OFF_O)^ > 0
}

// Unreference funccall (static in C).
funccal_unref_o :: proc "c" (fc: rawptr, fp: rawptr, force: bool) {
	context = runtime.default_context()
	if fc == nil {
		return
	}
	(^C.int)(uintptr(fc) + FC_REFCOUNT_OFF_O)^ -= 1
	cond := (^C.int)(uintptr(fc) + FC_REFCOUNT_OFF_O)^ <= 0
	if !force {
		cond = !fc_referenced_o(fc)
	}
	if cond {
		pfc := (^rawptr)(&previous_funccal)
		for pfc^ != nil {
			if pfc^ == fc {
				pfc^ = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
				free_funccal_contents_o(fc)
				return
			}
			pfc = (^rawptr)(uintptr(pfc^) + FC_CALLER_OFF_O)
		}
	}
	ufgap := (^Garray)(uintptr(fc) + FC_UFUNCS_OFF_O)
	for i: C.int = 0; i < ufgap.ga_len; i += 1 {
		if ([^]rawptr)(ufgap.ga_data)[uintptr(i)] == fp {
			([^]rawptr)(ufgap.ga_data)[uintptr(i)] = nil
		}
	}
}

// Return-path cleanup (static in C).
cleanup_function_call_o :: proc "c" (fc: rawptr) {
	context = runtime.default_context()
	may_free_fc := (^C.int)(uintptr(fc) + FC_REFCOUNT_OFF_O)^ <= 0
	free_fc := true
	current_funccal = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
	if may_free_fc && (^C.int)(uintptr(fc) + FC_L_VARS_OFF_O + 8)^ == DO_NOT_FREE_CNT_O {
		vars_clear(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16))
	} else {
		free_fc = false
	}
	if may_free_fc && (^C.int)(uintptr(fc) + FC_L_AVARS_OFF_O + 8)^ == DO_NOT_FREE_CNT_O {
		vars_clear_ext(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16), false)
	} else {
		free_fc = false
		avars := rawptr(uintptr(fc) + FC_L_AVARS_OFF_O)
		ht := rawptr(uintptr(avars) + 16)
		todo := (^C.size_t)(uintptr(ht) + 8)^
		hi := ([^]rawptr)(uintptr((^rawptr)(uintptr(ht) + 32)^))
		for todo > 0 {
			key := ([^]rawptr)(hi)[1]
			hi = ([^]rawptr)(uintptr(hi) + 16)
			if key == nil || key == transmute(rawptr)(&hash_removed_c) {
				continue
			}
			todo -= 1
			tv := (^Typval_T)(uintptr(key) - 17)
			tv_copy(tv, tv)
		}
	}
	if may_free_fc && (^C.int)(uintptr(fc) + FC_L_VARLIST_OFF_O + LV_REFCOUNT_OFF_O)^ == DO_NOT_FREE_CNT_O {
		(^rawptr)(uintptr(fc) + FC_L_VARLIST_OFF_O)^ = nil
	} else {
		free_fc = false
		li := tv_list_first_o(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O))
		for li != nil {
			tv := (^Typval_T)(uintptr(li) + 16)
			tv_copy(tv, tv)
			li = (^rawptr)(li)^
		}
	}
	if free_fc {
		free_funccal_o(fc)
	} else {
		(^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^ = previous_funccal
		previous_funccal = fc
		if want_garbage_collect_g {
			made_copy_g = 0
		} else {
			made_copy_g += 1
			if made_copy_g >= C.int(4096 * 1024 / 2080) {
				made_copy_g = 0
				want_garbage_collect_g = true
			}
		}
	}
}

// —— Batch 24o: get_func_tv + funcargs move ——
foreign _ {
	@(link_name = "set_ref_in_item")
	set_ref_in_item_e :: proc "c" (tv: ^Typval_T, copyID: C.int, ht_stack: rawptr, list_stack: rawptr) -> bool ---
}

VV_TESTING_O :: 76
EVAL_EVALUATE_O :: 1
E740_S :: "E740: Too many arguments for function %s"
E116_S :: "E116: Invalid arguments for function %s"

// Function argument pointers for test_garbagecollect_now (was C static).
@(export)
funcargs: Garray

// Parse "(args)" into argvars (static in C).
get_func_arguments_o :: proc "c" (arg: ^cstring, evalarg: rawptr, partial_argc: C.int, argvars: rawptr, argcount: ^C.int) -> C.int {
	context = runtime.default_context()
	argp := arg^
	ret: C.int = OK_E
	for argcount^ < MAX_FUNC_ARGS_O - partial_argc {
		argp = skipwhite(transmute(cstring)(rawptr(uintptr(rawptr(argp)) + uintptr(1))))
		if ([^]u8)(argp)[0] == ')' || ([^]u8)(argp)[0] == ',' || ([^]u8)(argp)[0] == 0 {
			break
		}
		tvp := (^Typval_T)(uintptr(argvars) + uintptr(argcount^) * 16)
		if eval1_e(&argp, tvp, evalarg) == FAIL_E {
			ret = FAIL_E
			break
		}
		argcount^ += 1
		if ([^]u8)(argp)[0] != ',' {
			break
		}
	}
	argp = skipwhite(argp)
	if ([^]u8)(argp)[0] == ')' {
		argp = transmute(cstring)(rawptr(uintptr(rawptr(argp)) + uintptr(1)))
	} else {
		ret = FAIL_E
	}
	arg^ = argp
	return ret
}

// Call function with "(args)" text; result in rettv.
@(export)
get_func_tv :: proc "c" (name: cstring, len: C.int, rettv: ^Typval_T, arg: ^cstring, evalarg: rawptr, fe: ^Funcexe_T) -> C.int {
	context = runtime.default_context()
	argvars: [MAX_FUNC_ARGS_O + 1]Typval_T
	argcount: C.int = 0
	evaluate := false
	if evalarg != nil && ((^C.int)(evalarg)^ & EVAL_EVALUATE_O) != 0 {
		evaluate = true
	}
	argp := arg^
	pta: C.int = 0
	if fe.partial != nil {
		pta = (^C.int)(uintptr(fe.partial) + PT_ARGC_OFF_O)^
	}
	ret := get_func_arguments_o(&argp, evalarg, pta, rawptr(&argvars[0]), &argcount)
	if ret == OK_E {
		i: C.int = 0
		if get_vim_var_nr_f(VV_TESTING_O) != 0 {
			if funcargs.ga_itemsize == 0 {
				ga_init_r2(&funcargs, 8, 50)
			}
			for i < argcount {
				ga_grow_r(&funcargs, 1)
				([^]rawptr)(funcargs.ga_data)[uintptr(funcargs.ga_len)] = rawptr(&argvars[i])
				funcargs.ga_len += 1
				i += 1
			}
		}
		ret = call_func(name, len, rettv, argcount, &argvars[0], fe)
		funcargs.ga_len -= i
	} else if !aborting_r() && evaluate {
		if argcount == MAX_FUNC_ARGS_O {
			emsg_funcname(cstring(E740_S), name)
		} else {
			emsg_funcname(cstring(E116_S), name)
		}
	}
	for argcount > 0 {
		argcount -= 1
		tv_clear_e(&argvars[argcount])
	}
	arg^ = skipwhite(argp)
	return ret
}

// Mark copyID in all in-flight function arguments (for GC).
@(export)
set_ref_in_func_args :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	for i: C.int = 0; i < funcargs.ga_len; i += 1 {
		tv := (^Typval_T)(([^]rawptr)(funcargs.ga_data)[uintptr(i)])
		if set_ref_in_item_e(tv, copyID, nil, nil) {
			return true
		}
	}
	return false
}

// —— Batch 24n: ex_delfunction ——
// (func_remove_e shim removed in 24ad: calls func_remove_o now.)
foreign _ {
	@(link_name = "ends_excmd")
	ends_excmd_e :: proc "c" (c: C.int) -> C.int ---
}

EXARG_ARG_OFF_O :: 0
EXARG_NEXTCMD_OFF_O :: 32
EXARG_SKIP_OFF2_O :: 72
EXARG_FORCEIT_OFF_O :: 76
E130_S :: "E130: Unknown function: %s"
E131_S :: "E131: Cannot delete function %s: It is in use"
E_CANTDEL_S :: "Cannot delete function %s: It is being used internally"

// Delete a user function (:delfunction).
@(export)
ex_delfunction :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	fp: rawptr = nil
	fudi: [24]u8
	fudip := rawptr(&fudi[0])
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF_O)^
	skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^
	p := arg
	name := trans_function_name(&p, skip, 0, fudip, nil)
	xfree((^rawptr)(uintptr(fudip) + FD_NEWKEY_OFF_O)^)
	if name == nil {
		if (^rawptr)(uintptr(fudip) + FD_DICT_OFF_O)^ != nil && !skip {
			emsg(cstring(E_FUNCREL_S))
		}
		return
	}
	if ends_excmd_e(C.int(([^]u8)(skipwhite(p))[0])) == 0 {
		xfree(rawptr(name))
		semsg(cstring(E488_S), p)
		return
	}
	(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(p)))
	if (^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ != nil {
		([^]u8)(p)[0] = 0
	}
	nb := ([^]u8)(name)
	if nb[0] >= '0' && nb[0] <= '9' && (^rawptr)(uintptr(fudip) + FD_DICT_OFF_O)^ == nil {
		if !skip {
			semsg(e_invarg2, arg)
		}
		xfree(rawptr(name))
		return
	}
	if !skip {
		fp = find_func(name)
	}
	xfree(rawptr(name))
	if !skip {
		if fp == nil {
			if (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF_O)^ == 0 {
				semsg(cstring(E130_S), arg)
			}
			return
		}
		if (^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ > 0 {
			semsg(cstring(E131_S), arg)
			return
		}
		if (^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ > 2 {
			semsg(cstring(E_CANTDEL_S), arg)
			return
		}
		fd_dict := (^rawptr)(uintptr(fudip) + FD_DICT_OFF_O)^
		if fd_dict != nil {
			tv_dict_item_remove(fd_dict, (^rawptr)(uintptr(fudip) + FD_DI_OFF_O)^)
		} else {
			limit: C.int = 1
			if func_name_refcount_o(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))) {
				limit = 0
			}
			if (^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ > limit {
				if func_remove_o(fp) {
					(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ -= 1
				}
				(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ |= FC_DELETED_O
			} else {
				func_clear_free_o(fp, false)
			}
		}
	}
}

// —— Batch 24t: defer + funccal accessors ——
foreign _ {
	@(link_name = "debug_backtrace_level")
	debug_backtrace_level_g: C.int
}

E193_S :: "E193: %s not inside a function"
FC_L_VARS_VAR_OFF_O :: 856
FC_L_AVARS_VAR_OFF_O :: 1240

// True when inside a function (for :defer).
@(export)
can_add_defer :: proc "c" () -> bool {
	context = runtime.default_context()
	if get_current_funccal() == nil {
		semsg(cstring(E193_S), cstring("defer"))
		return false
	}
	return true
}

// Queue a deferred call on the current funccal (consumes argvars).
@(export)
add_defer :: proc "c" (name: cstring, argcount_arg: C.int, argvars: ^Typval_T) {
	context = runtime.default_context()
	saved_name := transmute(cstring)(xstrdup_o(transmute(^u8)(name)))
	argcount := argcount_arg
	fc := current_funccal
	defer_ga := (^Garray)(uintptr(fc) + FC_DEFER_OFF_O)
	if (^C.int)(uintptr(defer_ga) + 12)^ == 0 {
		ga_init_r2(defer_ga, DEFER_STRIDE_O, 10)
	}
	ga_grow_r(defer_ga, 1)
	dr := rawptr(uintptr(defer_ga.ga_data) + uintptr(defer_ga.ga_len) * DEFER_STRIDE_O)
	defer_ga.ga_len += 1
	(^rawptr)(uintptr(dr) + DR_NAME_OFF_O)^ = rawptr(saved_name)
	(^C.int)(uintptr(dr) + DR_ARGCOUNT_OFF_O)^ = argcount
	ac := argcount
	for ac > 0 {
		ac -= 1
		([^]Typval_T)(uintptr(dr) + DR_ARGV_OFF_O)[ac] = ([^]Typval_T)(argvars)[ac]
	}
}

// Run deferred calls for a funccal and all saved stacks.
@(export)
invoke_all_defer :: proc "c" () {
	context = runtime.default_context()
	fc := current_funccal
	for fc != nil {
		handle_defer_one_o(fc)
		fc = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
	}
	fce := funccal_stack
	for fce != nil {
		fc2 := (^rawptr)(uintptr(fce) + 0)^
		for fc2 != nil {
			handle_defer_one_o(fc2)
			fc2 = (^rawptr)(uintptr(fc2) + FC_CALLER_OFF_O)^
		}
		fce = (^rawptr)(uintptr(fce) + 8)^
	}
}

// Current funccal honoring the debugger backtrace level.
@(export)
get_funccal :: proc "c" () -> rawptr {
	context = runtime.default_context()
	funccal := current_funccal
	if debug_backtrace_level_g > 0 {
		i: C.int = 0
		for i < debug_backtrace_level_g {
			temp := (^rawptr)(uintptr(funccal) + FC_CALLER_OFF_O)^
			if temp != nil {
				funccal = temp
			} else {
				debug_backtrace_level_g = i
				break
			}
			i += 1
		}
	}
	return funccal
}

// l: dict of the current funccal (nil when none/unreferenced).
@(export)
get_funccal_local_dict :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^C.int)(uintptr(current_funccal) + FC_L_VARS_OFF_O + 8)^ == 0 {
		return nil
	}
	return rawptr(uintptr(get_funccal()) + FC_L_VARS_OFF_O)
}

// Hashtab of the l: dict (nil when none).
@(export)
get_funccal_local_ht :: proc "c" () -> rawptr {
	context = runtime.default_context()
	d := get_funccal_local_dict()
	if d == nil {
		return nil
	}
	return rawptr(uintptr(d) + 16)
}

// The l: scope variable item (nil when none).
@(export)
get_funccal_local_var :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^C.int)(uintptr(current_funccal) + FC_L_VARS_OFF_O + 8)^ == 0 {
		return nil
	}
	return rawptr(uintptr(get_funccal()) + FC_L_VARS_VAR_OFF_O)
}

// a: dict of the current funccal (nil when none/unreferenced).
@(export)
get_funccal_args_dict :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^C.int)(uintptr(current_funccal) + FC_L_VARS_OFF_O + 8)^ == 0 {
		return nil
	}
	return rawptr(uintptr(get_funccal()) + FC_L_AVARS_OFF_O)
}

// Hashtab of the a: dict (nil when none).
@(export)
get_funccal_args_ht :: proc "c" () -> rawptr {
	context = runtime.default_context()
	d := get_funccal_args_dict()
	if d == nil {
		return nil
	}
	return rawptr(uintptr(d) + 16)
}

// The a: scope variable item (nil when none).
@(export)
get_funccal_args_var :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^C.int)(uintptr(current_funccal) + FC_L_VARS_OFF_O + 8)^ == 0 {
		return nil
	}
	return rawptr(uintptr(get_funccal()) + FC_L_AVARS_VAR_OFF_O)
}

// List l: variables for completion (no-op when no funccal).
@(export)
list_func_vars :: proc "c" (first: ^C.int) {
	context = runtime.default_context()
	if current_funccal != nil && (^C.int)(uintptr(current_funccal) + FC_L_VARS_OFF_O + 8)^ > 0 {
		list_hashtable_vars(rawptr(uintptr(current_funccal) + FC_L_VARS_OFF_O + 16), cstring("l:"), 0, first)
	}
}

// Owning dict when ht is the current funccal's l: hashtab.
@(export)
get_current_funccal_dict :: proc "c" (ht: rawptr) -> rawptr {
	context = runtime.default_context()
	if current_funccal != nil && ht == rawptr(uintptr(current_funccal) + FC_L_VARS_OFF_O + 16) {
		return rawptr(uintptr(current_funccal) + FC_L_VARS_OFF_O)
	}
	return nil
}

// —— Batch 24w: lambda parser + luafunc registration ——
E125_S :: "E125: Illegal argument: %s"
E853_S :: "E853: Duplicate argument name: %s"
E989_S :: "E989: Non-default argument follows default argument"
E451_S :: "E451: Expected }: %s"
E1068_S :: "E1068: No white space allowed before '%s': %s"
FC_CLOSURE_O :: 0x08
PT_REFCOUNT_OFF_O :: 0
RETURN_LIT_O : [8]u8 = {'r', 'e', 't', 'u', 'r', 'n', ' ', 0}
LAMBDA_NAME_FMT_S :: "<lambda>%d"
SNR_FMT_S :: "<SNR>%s"

// Static lambda-name buffer (was C statics).
@(private = "file")
lambda_name_g: [8 + NUMBUFLEN]u8
@(private = "file")
lambda_no_g: C.int

// Next "<lambda>N" name (static storage, was C static).
get_lambda_name_o :: proc "c" () -> (cstring, C.size_t) {
	context = runtime.default_context()
	lambda_no_g += 1
	n := libc.snprintf(([^]u8)(&lambda_name_g[0]), 8 + NUMBUFLEN, cstring(LAMBDA_NAME_FMT_S), lambda_no_g)
	if n < 1 {
		return transmute(cstring)(&lambda_name_g[0]), 0
	}
	if n > C.int(8 + NUMBUFLEN) - 1 {
		n = C.int(8 + NUMBUFLEN) - 1
	}
	return transmute(cstring)(&lambda_name_g[0]), C.size_t(n)
}

// Allocate a ufunc_T for "name" (static in C).
alloc_ufunc_o :: proc "c" (name: cstring, namelen: C.size_t) -> rawptr {
	context = runtime.default_context()
	length := C.size_t(240) + namelen + 1
	fp := xcalloc(1, length)
	_xmemcpyz(rawptr(uintptr(fp) + UF_NAME_OFF_O), transmute(rawptr)(name), C.size_t(namelen))
	(^C.size_t)(uintptr(fp) + 232)^ = namelen
	if ([^]u8)(name)[0] == 0x80 {
		exp_len := namelen + 3
		exp := xmalloc(exp_len)
		libc.snprintf(([^]u8)(exp), exp_len, cstring(SNR_FMT_S), transmute(cstring)(rawptr(uintptr(transmute(rawptr)(name)) + 3)))
		(^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ = exp
	}
	return fp
}

// Parse one argument name (static in C).
one_function_arg_o :: proc "c" (arg: cstring, newargs: ^Garray, skip: bool) -> cstring {
	context = runtime.default_context()
	p := arg
	for {
		c := ([^]u8)(p)[0]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
			break
		}
		p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
	}
	diff := uintptr(transmute(rawptr)(p)) - uintptr(transmute(rawptr)(arg))
	dup := false
	if diff == 9 && libc.strncmp(arg, cstring("firstline"), 9) == 0 {
		dup = true
	}
	if diff == 8 && libc.strncmp(arg, cstring("lastline"), 8) == 0 {
		dup = true
	}
	if uintptr(transmute(rawptr)(arg)) == uintptr(transmute(rawptr)(p)) || ascii_isdigit_o(([^]u8)(arg)[0]) || dup {
		if !skip {
			semsg(cstring(E125_S), arg)
		}
		return arg
	}
	if newargs != nil {
		ga_grow_r(newargs, 1)
		c := ([^]u8)(p)[0]
		([^]u8)(p)[0] = 0
		arg_copy := transmute(cstring)(xstrdup_o(transmute(^u8)(arg)))
		hit := false
		i: C.int = 0
		for i < newargs.ga_len {
			if libc.strcmp(([^]cstring)(newargs.ga_data)[uintptr(i)], arg_copy) == 0 {
				hit = true
				break
			}
			i += 1
		}
		if hit {
			semsg(cstring(E853_S), arg_copy)
			xfree(transmute(rawptr)(arg_copy))
			return arg
		}
		([^]cstring)(newargs.ga_data)[uintptr(newargs.ga_len)] = arg_copy
		newargs.ga_len += 1
		([^]u8)(p)[0] = c
	}
	return p
}

// Parse "arg1, arg2, ..." up to endchar (static in C).
get_function_args_o :: proc "c" (argp: ^cstring, endchar: u8, newargs: ^Garray, varargs: ^bool, default_args: ^Garray, skip: bool) -> C.int {
	context = runtime.default_context()
	mustend := false
	arg := argp^
	p := arg
	if newargs != nil {
		ga_init_r2(newargs, 8, 3)
	}
	if default_args != nil {
		ga_init_r2(default_args, 8, 3)
	}
	if varargs != nil {
		varargs^ = false
	}
	any_default := false
	for ([^]u8)(p)[0] != endchar {
		if ([^]u8)(p)[0] == '.' && ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 1))[0] == '.' && ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 2))[0] == '.' {
			if varargs != nil {
				varargs^ = true
			}
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 3))
			mustend = true
		} else {
			arg = p
			p = one_function_arg_o(p, newargs, skip)
			if uintptr(transmute(rawptr)(p)) == uintptr(transmute(rawptr)(arg)) {
				break
			}
			sp := skipwhite(p)
			if ([^]u8)(sp)[0] == '=' && default_args != nil {
				any_default = true
				p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(sp)) + 1))
				p = skipwhite(p)
				expr := p
				rettv := Typval_T{v_type = VAR_NUMBER}
				if eval1_e(&p, &rettv, nil) != FAIL_E {
					ga_grow_r(default_args, 1)
					for uintptr(transmute(rawptr)(p)) > uintptr(transmute(rawptr)(expr)) && ascii_iswhite(([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) - 1))[0]) {
						p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) - 1))
					}
					c := ([^]u8)(p)[0]
					([^]u8)(p)[0] = 0
					expr = transmute(cstring)(xstrdup_o(transmute(^u8)(expr)))
					([^]cstring)(default_args.ga_data)[uintptr(default_args.ga_len)] = expr
					default_args.ga_len += 1
					([^]u8)(p)[0] = c
				} else {
					mustend = true
				}
			} else if any_default {
				emsg(cstring(E989_S))
				mustend = true
			}
			if ascii_iswhite(([^]u8)(p)[0]) && ([^]u8)(skipwhite(p))[0] == ',' {
				if !skip {
					semsg(cstring(E1068_S), cstring(","), p)
					if newargs != nil {
						ga_clear_strings_e(newargs)
					}
					if default_args != nil {
						ga_clear_strings_e(default_args)
					}
					return FAIL_E
				}
				p = skipwhite(p)
			}
			if ([^]u8)(p)[0] == ',' {
				p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
			} else {
				mustend = true
			}
		}
		p = skipwhite(p)
		if mustend && ([^]u8)(p)[0] != endchar {
			if !skip {
				semsg(e_invarg2, argp^)
			}
			break
		}
	}
	if ([^]u8)(p)[0] != endchar {
		if newargs != nil {
			ga_clear_strings_e(newargs)
		}
		if default_args != nil {
			ga_clear_strings_e(default_args)
		}
		return FAIL_E
	}
	p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
	argp^ = p
	return OK_E
}

// Parse a lambda expression into a Funcref.
@(export)
get_lambda_tv :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	evaluate := evalarg != nil && ((^C.int)(evalarg)^ & EVAL_EVALUATE_O) != 0
	newargs := Garray{}
	pnewargs: ^Garray = nil
	fp: rawptr = nil
	pt: rawptr = nil
	varargs := false
	old_eval_lavars := eval_lavars_used_g
	eval_lavars := false
	tofree: rawptr = nil
	s := skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg^)) + 1)))
	ret := get_function_args_o(&s, '-', nil, nil, nil, true)
	if ret == FAIL_E || ([^]u8)(s)[0] != '>' {
		return NOTDONE_O
	}
	if evaluate {
		pnewargs = &newargs
	}
	arg^ = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg^)) + 1)))
	ret = get_function_args_o(arg, '-', pnewargs, &varargs, nil, false)
	if ret == FAIL_E || ([^]u8)(arg^)[0] != '>' {
		if pnewargs != nil {
			ga_clear_strings_e(pnewargs)
		}
		eval_lavars_used_g = old_eval_lavars
		return FAIL_E
	}
	if evaluate {
		eval_lavars_used_g = &eval_lavars
	}
	arg^ = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg^)) + 1)))
	start := arg^
	ret = skip_expr_e(arg, evalarg)
	end := arg^
	if ret == FAIL_E {
		if pnewargs != nil {
			ga_clear_strings_e(pnewargs)
		}
		eval_lavars_used_g = old_eval_lavars
		return FAIL_E
	}
	if evalarg != nil {
		tofree = (^rawptr)(uintptr(evalarg) + 24)^
		(^rawptr)(uintptr(evalarg) + 24)^ = nil
	}
	arg^ = skipwhite(arg^)
	if ([^]u8)(arg^)[0] != '}' {
		semsg(cstring(E451_S), arg^)
		if pnewargs != nil {
			ga_clear_strings_e(pnewargs)
		}
		eval_lavars_used_g = old_eval_lavars
		return FAIL_E
	}
	arg^ = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg^)) + 1))
	if evaluate {
		newlines := Garray{}
		lname, lsize := get_lambda_name_o()
		fp = alloc_ufunc_o(lname, lsize)
		pt = xcalloc(1, 48)
		ga_init_r2(&newlines, 8, 1)
		ga_grow_r(&newlines, 1)
		length := C.size_t(7) + C.size_t(uintptr(transmute(rawptr)(end)) - uintptr(transmute(rawptr)(start))) + 1
		np := transmute([^]u8)(xmalloc(length))
		([^]cstring)(newlines.ga_data)[uintptr(newlines.ga_len)] = transmute(cstring)(np)
		newlines.ga_len += 1
		libc.memcpy(np, rawptr(&RETURN_LIT_O[0]), 7)
		_xmemcpyz(rawptr(uintptr(np) + 7), transmute(rawptr)(start), C.size_t(uintptr(transmute(rawptr)(end)) - uintptr(transmute(rawptr)(start))))
		if strstr_c(transmute(cstring)(rawptr(uintptr(np) + 7)), cstring("a:")) == nil {
			(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ |= FC_NOARGS_O
		}
		(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ = 1
		hash_add_e(rawptr(&func_hashtab), transmute(^u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
		([^]Garray)(uintptr(fp) + UF_ARGS_OFF_O)[0] = newargs
		ga_init_r2((^Garray)(uintptr(fp) + UF_DEF_ARGS_OFF_O), 8, 1)
		(^rawptr)(uintptr(fp) + UF_LINES_OFF_O + 16)^ = newlines.ga_data
		(^C.int)(uintptr(fp) + UF_LINES_OFF_O)^ = newlines.ga_len
		if current_funccal != nil && eval_lavars {
			(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ |= FC_CLOSURE_O
			register_closure_o(fp)
		} else {
			(^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^ = nil
		}
		if do_profiling == PROF_YES {
			func_do_profile_e(fp)
		}
		if sandbox != 0 {
			(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ |= FC_SANDBOX_O
		}
		(^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ = true
		(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ = 0
		libc.memcpy(rawptr(uintptr(fp) + UF_SCRIPT_CTX_OFF_O), rawptr(&current_sctx_buf[0]), 24)
		(^C.int)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O + 8)^ = sourcing_lnum_o() - (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
		(^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ = fp
		(^C.int)(uintptr(pt) + PT_REFCOUNT_OFF_O)^ = 1
		rettv.vval = transmute(rawptr)(pt)
		rettv.v_type = VAR_PARTIAL
	}
	eval_lavars_used_g = old_eval_lavars
	if tofree != nil {
		xfree(tofree)
	}
	return OK_E
}

// Register a Lua callback as a lambda Funcref.
@(export)
register_luafunc :: proc "c" (ref_: C.int) -> cstring {
	context = runtime.default_context()
	lname, lsize := get_lambda_name_o()
	fp := alloc_ufunc_o(lname, lsize)
	(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ = 1
	(^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ = true
	(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ = FC_LUAREF_O
	(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ = 0
	libc.memcpy(rawptr(uintptr(fp) + UF_SCRIPT_CTX_OFF_O), rawptr(&current_sctx_buf[0]), 24)
	(^C.int)(uintptr(fp) + UF_LUAREF_OFF_O)^ = ref_
	hash_add_e(rawptr(&func_hashtab), transmute(^u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
	return transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))
}

// —— Batch 24v: func_hashtab move + init/lookup ——

// hashtab_T mirror (cc-probed, sizeof 296).
Hashtab_T :: struct {
	ht_mask:       C.size_t,  // @0
	ht_used:       C.size_t,  // @8
	ht_filled:     C.size_t,  // @16
	ht_changed:    C.int,     // @24
	ht_locked:     C.int,     // @28
	ht_array:      rawptr,    // @32
	ht_smallarray: [256]u8,   // @40 (16 items x 16B)
}
#assert(size_of(Hashtab_T) == 296)

// Function name hashtable (was C static; C uses `extern`, single copy here).
@(export)
func_hashtab: Hashtab_T

// Initialize the function hashtable.
@(export)
func_init :: proc "c" () {
	context = runtime.default_context()
	hash_init_r(&func_hashtab)
}

// Return the function hash table.
@(export)
func_tbl_get :: proc "c" () -> rawptr {
	context = runtime.default_context()
	return &func_hashtab
}

// Find a user function by name (nil when missing).
@(export)
find_func :: proc "c" (name: cstring) -> rawptr {
	context = runtime.default_context()
	hi := hash_find_r(&func_hashtab, name)
	if hi != nil {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed_c) {
			return rawptr(uintptr(hi_key) - uintptr(UF_NAME_OFF_O))
		}
	}
	return nil
}

// —— Batch 24u: scoped lookup + GC marking ——
foreign _ {
	@(link_name = "set_ref_in_ht")
	set_ref_in_ht_e :: proc "c" (ht: rawptr, copyID: C.int, list_stack: rawptr) -> bool ---
	@(link_name = "set_ref_in_list_items")
	set_ref_in_list_items_e :: proc "c" (l: rawptr, copyID: C.int, ht_stack: rawptr) -> bool ---
	@(link_name = "find_var_ht")
	find_var_ht_e :: proc "c" (name: cstring, name_len: C.size_t, varname: ^cstring) -> rawptr ---
	@(link_name = "find_var_in_ht")
	find_var_in_ht_e :: proc "c" (ht: rawptr, htname: C.int, varname: cstring, varname_len: C.size_t, no_autoload: C.int) -> rawptr ---
	@(link_name = "hash_find_len")
	hash_find_len_e :: proc "c" (ht: rawptr, key: cstring, len: C.size_t) -> rawptr ---
}

// Search parent scopes (closure chain) for a hashitem.
@(export)
find_hi_in_scoped_ht :: proc "c" (name: cstring, pht: ^rawptr) -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^ == nil {
		return nil
	}
	old := current_funccal
	hi: rawptr = nil
	namelen := C.size_t(libc.strlen(name))
	varname: cstring = nil
	current_funccal = (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^
	for current_funccal != nil {
		ht := find_var_ht_e(name, namelen, &varname)
		if ht != nil && ([^]u8)(varname)[0] != 0 {
			hi = hash_find_len_e(ht, varname, namelen - C.size_t(uintptr(transmute(rawptr)(varname)) - uintptr(transmute(rawptr)(name))))
			if hi != nil {
				hi_key := (^rawptr)(uintptr(hi) + 8)^
				if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed_c) {
					pht^ = ht
					break
				}
			}
			hi = nil
		}
		scoped := (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^
		if current_funccal == scoped {
			break
		}
		current_funccal = scoped
	}
	current_funccal = old
	return hi
}

// Search parent scopes (closure chain) for a variable.
@(export)
find_var_in_scoped_ht :: proc "c" (name: cstring, namelen: C.size_t, no_autoload: C.int) -> rawptr {
	context = runtime.default_context()
	if current_funccal == nil || (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^ == nil {
		return nil
	}
	v: rawptr = nil
	old := current_funccal
	varname: cstring = nil
	current_funccal = (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^
	for current_funccal != nil {
		ht := find_var_ht_e(name, namelen, &varname)
		if ht != nil && ([^]u8)(varname)[0] != 0 {
			v = find_var_in_ht_e(ht, C.int(([^]u8)(name)[0]), varname, namelen - C.size_t(uintptr(transmute(rawptr)(varname)) - uintptr(transmute(rawptr)(name))), no_autoload)
			if v != nil {
				break
			}
		}
		scoped := (^rawptr)(uintptr((^rawptr)(uintptr(current_funccal) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^
		if current_funccal == scoped {
			break
		}
		current_funccal = scoped
	}
	current_funccal = old
	return v
}

// Mark one funccal's vars (static in C).
set_ref_in_funccal_o :: proc "c" (fc: rawptr, copyID: C.int) -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(fc) + FC_COPYID_OFF_O)^ != copyID {
		(^C.int)(uintptr(fc) + FC_COPYID_OFF_O)^ = copyID
		if set_ref_in_ht_e(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16), copyID, nil) ||
		   set_ref_in_ht_e(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16), copyID, nil) ||
		   set_ref_in_list_items_e(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O), copyID, nil) ||
		   set_ref_in_func(nil, (^rawptr)(uintptr(fc) + FC_FUNC_OFF_O)^, copyID) {
			return true
		}
	}
	return false
}

// Mark freed-chain funccalls with copyID+1.
@(export)
set_ref_in_previous_funccal :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	fc := previous_funccal
	for fc != nil {
		(^C.int)(uintptr(fc) + FC_COPYID_OFF_O)^ = copyID + 1
		if set_ref_in_ht_e(rawptr(uintptr(fc) + FC_L_VARS_OFF_O + 16), copyID + 1, nil) ||
		   set_ref_in_ht_e(rawptr(uintptr(fc) + FC_L_AVARS_OFF_O + 16), copyID + 1, nil) ||
		   set_ref_in_list_items_e(rawptr(uintptr(fc) + FC_L_VARLIST_OFF_O), copyID + 1, nil) {
			return true
		}
		fc = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
	}
	return false
}

// Mark all funccalls on the current + saved stacks.
@(export)
set_ref_in_call_stack :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	fc := current_funccal
	for fc != nil {
		if set_ref_in_funccal_o(fc, copyID) {
			return true
		}
		fc = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
	}
	entry := funccal_stack
	for entry != nil {
		fc2 := (^rawptr)(uintptr(entry) + 0)^
		for fc2 != nil {
			if set_ref_in_funccal_o(fc2, copyID) {
				return true
			}
			fc2 = (^rawptr)(uintptr(fc2) + FC_CALLER_OFF_O)^
		}
		entry = (^rawptr)(uintptr(entry) + 8)^
	}
	return false
}

// Mark all named functions' scoped chains.
@(export)
set_ref_in_functions :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	arr := func_hashtab.ht_array
	used := func_hashtab.ht_used
	todo := C.int(used)
	hi := rawptr(uintptr(arr))
	item_size: uintptr = 16
	for todo > 0 && !got_int {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed_c) {
			todo -= 1
			fp := rawptr(uintptr(hi_key) - uintptr(UF_NAME_OFF_O))
			if !func_name_refcount_o(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))) &&
			   set_ref_in_func(nil, fp, copyID) {
				return true
			}
		}
		hi = rawptr(uintptr(hi) + item_size)
	}
	return false
}

// Mark lists/dicts reachable through a function name or pointer.
@(export)
set_ref_in_func :: proc "c" (name: cstring, fp_in: rawptr, copyID: C.int) -> bool {
	context = runtime.default_context()
	fp := fp_in
	error: C.int = FCERR_NONE_O
	fname_buf: [FLEN_FIXED_O + 1]u8
	tofree: rawptr = nil
	abort := false
	if name == nil && fp_in == nil {
		return false
	}
	if fp_in == nil {
		fname := fname_trans_sid_o(name, ([^]u8)(&fname_buf[0]), &tofree, &error)
		fp = find_func(fname)
	}
	if fp != nil {
		fc := (^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^
		for fc != nil {
			abort = abort || set_ref_in_funccal_o(fc, copyID)
			fc = (^rawptr)(uintptr((^rawptr)(uintptr(fc) + FC_FUNC_OFF_O)^) + UF_SCOPED_OFF_O)^
		}
	}
	xfree(tofree)
	return abort
}

// —— Batch 24x: :call/:defer command ——
foreign _ {
	@(link_name = "fill_evalarg_from_eap")
	fill_evalarg_from_eap_e :: proc "c" (evalarg: rawptr, eap: rawptr, skip: bool) ---
	@(link_name = "clear_evalarg")
	clear_evalarg_e :: proc "c" (evalarg: rawptr, eap: rawptr) ---
	@(link_name = "eval0")
	eval0_e :: proc "c" (arg: cstring, rettv: ^Typval_T, eap: rawptr, evalarg: rawptr) -> C.int ---
	@(link_name = "handle_subscript")
	handle_subscript_e :: proc "c" (arg: ^cstring, rettv: ^Typval_T, evalarg: rawptr, verbose: bool) -> C.int ---
	@(link_name = "check_internal_func")
	check_internal_func_e :: proc "c" (fdef: rawptr, argcount: C.int) -> C.int ---
	@(link_name = "did_throw")
	did_throw_g: bool
	@(link_name = "emsg_severe")
	emsg_severe_g: bool
}

E107_S :: "E107: Missing parentheses: %s"
E1300_S :: "E1300: Cannot use a partial with dictionary for :defer"
CMD_DEFER_O :: 113
EXARG_LINE1_OFF_O :: 84
EXARG_CSTACK_OFF_O :: 184
CS_TRYLEVEL_OFF_O :: 1264

// ":call" range loop + subscript handling (static in C).
ex_call_inner_o :: proc "c" (eap: rawptr, name: cstring, arg: ^cstring, startarg: cstring, funcexe_init: ^Funcexe_T, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	failed := false
	line1 := (^C.int)(uintptr(eap) + EXARG_LINE1_OFF_O)^
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	lnum := line1
	for lnum <= line2 {
		if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ != 0 {
			if lnum > C.int((^i32)(uintptr(curbuf) + B_ML_LINE_COUNT)^) {
				emsg(cstring(E_INVRANGE_S))
				break
			}
			(^i32)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
			(^i32)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
			(^i32)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
		}
		arg^ = startarg
		doesrange_dummy := false
		funcexe := funcexe_init^
		funcexe.doesrange = rawptr(&doesrange_dummy)
		rettv := Typval_T{v_type = VAR_UNKNOWN}
		if get_func_tv(name, -1, &rettv, arg, evalarg, &funcexe) == FAIL_E {
			failed = true
			break
		}
		ea := Evalarg_T{eval_flags = 1}
		if handle_subscript_e(arg, &rettv, rawptr(&ea), true) == FAIL_E {
			failed = true
			break
		}
		tv_clear_e(&rettv)
		if doesrange_dummy {
			break
		}
		if aborting_r() {
			break
		}
		lnum += 1
	}
	if failed {
		return 1
	}
	return 0
}

// ":defer" argument evaluation + queueing (static in C).
ex_defer_inner_o :: proc "c" (name: cstring, arg: ^cstring, partial: rawptr, evalarg: rawptr) -> C.int {
	context = runtime.default_context()
	argvars: [MAX_FUNC_ARGS_O + 1]Typval_T
	partial_argc: C.int = 0
	argcount: C.int = 0
	if current_funccal == nil {
		semsg(cstring(E193_S), cstring("defer"))
		return FAIL_E
	}
	if partial != nil {
		if (^rawptr)(uintptr(partial) + PT_DICT_OFF_O)^ != nil {
			emsg(cstring(E1300_S))
			return FAIL_E
		}
		if (^C.int)(uintptr(partial) + PT_ARGC_OFF_O)^ > 0 {
			partial_argc = (^C.int)(uintptr(partial) + PT_ARGC_OFF_O)^
			i: C.int = 0
			for i < partial_argc {
				tv_copy((^Typval_T)(uintptr((^rawptr)(uintptr(partial) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), &argvars[i])
				i += 1
			}
		}
	}
	r := get_func_arguments_o(arg, evalarg, partial_argc, rawptr(&argvars[int(partial_argc)]), &argcount)
	argcount += partial_argc
	if r == OK_E {
		if builtin_function_o(name, -1) {
			fdef := find_internal_func_e(name)
			if fdef == nil {
				emsg_funcname(cstring("E117: Unknown function: %s"), name)
				r = FAIL_E
			} else if check_internal_func_e(fdef, argcount) == -1 {
				r = FAIL_E
			}
		} else {
			ufunc := find_func(name)
			if ufunc != nil {
				error := check_user_func_argcount_o(ufunc, argcount)
				if error != FCERR_UNKNOWN_O {
					user_func_error_o(error, name, false)
					r = FAIL_E
				}
			}
		}
	}
	if r == FAIL_E {
		for argcount > 0 {
			argcount -= 1
			tv_clear_e(&argvars[int(argcount)])
		}
		return FAIL_E
	}
	add_defer(name, argcount, &argvars[0])
	return OK_E
}

// ":call func(args)" / ":defer func(args)".
@(export)
ex_call :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + 0)^
	failed := false
	fudi: [24]u8
	partial: rawptr = nil
	ea := Evalarg_T{}
	skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^
	fill_evalarg_from_eap_e(rawptr(&ea), eap, skip)
	if skip {
		rettv := Typval_T{v_type = VAR_UNKNOWN}
		emsg_skip += 1
		if eval0_e(arg, &rettv, eap, rawptr(&ea)) != FAIL_E {
			tv_clear_e(&rettv)
		}
		emsg_skip -= 1
		clear_evalarg_e(rawptr(&ea), eap)
		return
	}
	tofree := trans_function_name(&arg, false, TFN_INT_O, rawptr(&fudi[0]), &partial)
	if (^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^ != nil {
		semsg(cstring(E_DICTKEY_S), transmute(cstring)((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^))
		xfree((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^)
	}
	if tofree == nil {
		return
	}
	if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ != nil {
		(^C.int)(uintptr((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^) + 8)^ += 1
	}
	length := C.int(libc.strlen(tofree))
	found_var := false
	name: cstring
	if partial != nil {
		name = deref_func_name(tofree, &length, nil, false, &found_var)
	} else {
		name = deref_func_name(tofree, &length, &partial, false, &found_var)
	}
	startarg := skipwhite(arg)
	if ([^]u8)(startarg)[0] != '(' {
		semsg(cstring(E107_S), (^cstring)(uintptr(eap) + 0)^)
	} else if (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^ == CMD_DEFER_O {
		arg = startarg
		failed = ex_defer_inner_o(name, &arg, partial, rawptr(&ea)) == FAIL_E
	} else {
		funcexe := Funcexe_T{}
		funcexe.partial = partial
		funcexe.selfdict = (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^
		funcexe.firstline = (^C.int)(uintptr(eap) + EXARG_LINE1_OFF_O)^
		funcexe.lastline = (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
		funcexe.found_var = found_var
		funcexe.evaluate = true
		failed = ex_call_inner_o(eap, name, &arg, startarg, &funcexe, rawptr(&ea)) != 0
	}
	if (!aborting_r() || did_throw_g) && (!failed || (^C.int)(uintptr((^rawptr)(uintptr(eap) + EXARG_CSTACK_OFF_O)^) + CS_TRYLEVEL_OFF_O)^ > 0) {
		if ends_excmd_e(C.int(([^]u8)(arg)[0])) == 0 {
			if !failed && !aborting_r() {
				emsg_severe_g = true
				semsg(cstring(E488_S), arg)
			}
		} else {
			(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(arg)))
		}
	}
	clear_evalarg_e(rawptr(&ea), eap)
	tv_dict_unref((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^)
	xfree(rawptr(tofree))
}

// —— Batch 24y: :return machinery ——
foreign _ {
	@(link_name = "cleanup_conditionals")
	cleanup_conditionals_e :: proc "c" (cstack: rawptr, searched_cond: C.int, inclusive: C.int) -> C.int ---
	@(link_name = "report_make_pending")
	report_make_pending_e :: proc "c" (pending: C.int, value: rawptr) ---
}

E133_S :: "E133: :return not inside a function"
CSTP_RETURN_O :: 24
CS_PENDING_OFF_O :: 200
CS_RETTV_OFF_O :: 256
DOT3_O : [4]u8 = {'.', '.', '.', 0}

// Carry out (or pend) a function return.
@(export)
do_return :: proc "c" (eap: rawptr, reanimate: bool, is_cmd: bool, rettv: rawptr) -> bool {
	context = runtime.default_context()
	cstack := (^rawptr)(uintptr(eap) + EXARG_CSTACK_OFF_O)^
	if reanimate {
		(^bool)(uintptr(current_funccal) + FC_RETURNED_OFF_O)^ = false
	}
	idx := cleanup_conditionals_e(cstack, 0, 1)
	if idx >= 0 {
		([^]u8)(uintptr(cstack) + CS_PENDING_OFF_O)[idx] = CSTP_RETURN_O
		if !is_cmd && !reanimate {
			([^]rawptr)(uintptr(cstack) + CS_RETTV_OFF_O)[idx] = rettv
		} else {
			rv := rettv
			if reanimate {
				fc_rettv := (^rawptr)(uintptr(current_funccal) + FC_RETTV_OFF_O)^
				if fc_rettv == nil {
					libc.abort()
				}
				rv = fc_rettv
			}
			if rv != nil {
				stored := xcalloc(1, 16)
				(^Typval_T)(stored)^ = (^Typval_T)(rv)^
				([^]rawptr)(uintptr(cstack) + CS_RETTV_OFF_O)[idx] = stored
			} else {
				([^]rawptr)(uintptr(cstack) + CS_RETTV_OFF_O)[idx] = nil
			}
			if reanimate {
				fr := (^rawptr)(uintptr(current_funccal) + FC_RETTV_OFF_O)^
				(^C.int)(fr)^ = VAR_NUMBER
				(^rawptr)(uintptr(fr) + 8)^ = nil
			}
		}
		report_make_pending_e(CSTP_RETURN_O, rettv)
	} else {
		(^bool)(uintptr(current_funccal) + FC_RETURNED_OFF_O)^ = true
		if !reanimate && rettv != nil {
			tv_clear_e((^Typval_T)((^rawptr)(uintptr(current_funccal) + FC_RETTV_OFF_O)^))
			(^Typval_T)((^rawptr)(uintptr(current_funccal) + FC_RETTV_OFF_O)^)^ = (^Typval_T)(rettv)^
			if !is_cmd {
				xfree(rettv)
			}
		}
	}
	return idx < 0
}

// Build ":return <val>" text for verbose pending reports.
@(export)
get_return_cmd :: proc "c" (rettv: rawptr) -> cstring {
	context = runtime.default_context()
	s: cstring = nil
	tofree: rawptr = nil
	slen: C.size_t = 0
	if rettv != nil {
		tofree = rawptr(encode_tv2echo((^Typval_T)(rettv), nil))
		s = transmute(cstring)(tofree)
	}
	if s == nil {
		s = cstring("")
	} else {
		slen = C.size_t(libc.strlen(s))
	}
	xstrlcpy_o(transmute(cstring)(&IObuff[0]), cstring(":return "), C.size_t(IOSIZE_O))
	xstrlcpy_o(transmute(cstring)(&IObuff[8]), s, C.size_t(IOSIZE_O - 8))
	IObufflen := 8 + slen
	if IObufflen >= C.size_t(IOSIZE_O) {
		libc.memcpy(rawptr(&IObuff[IOSIZE_O - 4]), rawptr(&DOT3_O[0]), 4)
		IObufflen = C.size_t(IOSIZE_O) - 1
	}
	xfree(tofree)
	return transmute(cstring)(xstrnsave_c(transmute(cstring)(&IObuff[0]), IObufflen))
}

// ":return [expr]".
@(export)
ex_return :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + 0)^
	rettv := Typval_T{v_type = VAR_UNKNOWN}
	returning := false
	if current_funccal == nil {
		emsg(cstring(E133_S))
		return
	}
	ea := Evalarg_T{}
	if (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
		ea.eval_flags = 0
	} else {
		ea.eval_flags = 1
	}
	if (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
		emsg_skip += 1
	}
	(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = nil
	if (([^]u8)(arg)[0] != 0 && ([^]u8)(arg)[0] != '|' && ([^]u8)(arg)[0] != '\n') && eval0_e(arg, &rettv, eap, rawptr(&ea)) != FAIL_E {
		if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
			returning = do_return(eap, false, true, rawptr(&rettv))
		} else {
			tv_clear_e(&rettv)
		}
	} else if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
		update_force_abort_e()
		if !aborting_r() {
			returning = do_return(eap, false, true, nil)
		}
	}
	if returning {
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = nil
	} else if (^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ == nil {
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(arg)))
	}
	if (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
		emsg_skip -= 1
	}
	clear_evalarg_e(rawptr(&ea), eap)
}

// —— Batch 24ab: function body reader (dormant) ——
foreign _ {
	@(link_name = "getcmdline")
	getcmdline_e :: proc "c" (firstc: C.int, count: C.int, indent: C.int, do_concat: bool) -> cstring ---
	@(link_name = "get_sourced_lnum")
	get_sourced_lnum_e :: proc "c" (fgetline: LineGetter, cookie: rawptr) -> C.int ---
	@(link_name = "checkforcmd")
	checkforcmd_e :: proc "c" (pp: ^cstring, cmd: cstring, len: C.int) -> bool ---
	@(link_name = "skip_range")
	skip_range_e :: proc "c" (cmd: cstring, ctx: ^C.int) -> cstring ---
	@(link_name = "swmsg")
	swmsg_e :: proc "c" (hl: bool, fmt: cstring, #c_vararg args: ..any) ---
	@(link_name = "ui_ext_cmdline_block_append")
	ui_ext_cmdline_block_append_e :: proc "c" (indent: C.size_t, line: cstring) ---
}

E126_S :: "E126: Missing :endfunction"
E1058_S :: "E1058: Function nesting too deep"
E1145_S :: "E1145: Missing heredoc end marker: %s"
W22_S :: "W22: Text found after :endfunction: %s"
MAX_FUNC_NESTING_O :: 50
DOT1_O : [2]u8 = {'.', 0}

// Read ":function" body lines until ":endfunction" (static in C).
get_function_body_o :: proc "c" (eap: rawptr, newlines: ^Garray, line_arg_in: cstring, line_to_free: ^cstring, show_block: bool) -> C.int {
	context = runtime.default_context()
	saved_wait_return := need_wait_return_g
	line_arg := line_arg_in
	indent: C.int = 2
	nesting: C.int = 0
	skip_until: cstring = nil
	ret: C.int = FAIL_E
	is_heredoc := false
	heredoc_trimmed: cstring = nil
	heredoc_trimmedlen: C.size_t = 0
	do_concat := true
	for {
		if KeyTyped {
			msg_scroll = true
			saved_wait_return = false
		}
		need_wait_return_g = false
		theline: cstring
		p: cstring
		arg: cstring
		if line_arg != nil {
			theline = line_arg
			np := vim_strchr_c(transmute(^u8)(theline), '\n')
			if np == nil {
				line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(line_arg)) + uintptr(libc.strlen(line_arg))))
			} else {
				([^]u8)(np)[0] = 0
				line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(np)) + 1))
			}
		} else {
			xfree(rawptr(line_to_free^))
			gl := (^LineGetter)(uintptr(eap) + 168)^
			cookie := (^rawptr)(uintptr(eap) + 176)^
			if gl == nil {
				theline = getcmdline_e(':', 0, indent, do_concat)
			} else {
				theline = transmute(cstring)(gl(':', cookie, indent, do_concat))
			}
			line_to_free^ = theline
		}
		if KeyTyped {
			lines_left = Rows - 1
		}
		if theline == nil {
			if skip_until != nil {
				semsg(cstring(E1145_S), skip_until)
			} else {
				emsg(cstring(E126_S))
			}
			break
		}
		if show_block {
			if !(indent >= 0) {
				libc.abort()
			}
			ui_ext_cmdline_block_append_e(C.size_t(indent), theline)
		}
		gl2 := (^LineGetter)(uintptr(eap) + 168)^
		cookie2 := (^rawptr)(uintptr(eap) + 176)^
		sourcing_lnum_off := get_sourced_lnum_e(gl2, cookie2)
		if sourcing_lnum_o() < sourcing_lnum_off {
			sourcing_lnum_off -= sourcing_lnum_o()
		} else {
			sourcing_lnum_off = 0
		}
		if skip_until != nil {
			trim_eq := heredoc_trimmed == nil || (is_heredoc && skipwhite(theline) == theline) || libc.strncmp(theline, heredoc_trimmed, heredoc_trimmedlen) == 0
			if trim_eq {
				if heredoc_trimmed == nil {
					p = theline
				} else if is_heredoc {
					if skipwhite(theline) == theline {
						p = theline
					} else {
						p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(theline)) + uintptr(heredoc_trimmedlen)))
					}
				} else {
					p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(theline)) + uintptr(heredoc_trimmedlen)))
				}
				if libc.strcmp(p, skip_until) == 0 {
					if skip_until != nil {
						xfree(rawptr(skip_until))
						skip_until = nil
					}
					if heredoc_trimmed != nil {
						xfree(rawptr(heredoc_trimmed))
						heredoc_trimmed = nil
					}
					heredoc_trimmedlen = 0
					do_concat = true
					is_heredoc = false
				}
			}
		} else {
			p = theline
			for ascii_iswhite(([^]u8)(p)[0]) || ([^]u8)(p)[0] == ':' {
				p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
			}
			nest_end := checkforcmd_e(&p, cstring("endfunction"), 4)
			nest_cur: C.int = 0
			if nest_end {
				nest_cur = nesting
				nesting -= 1
			}
			if nest_end && nest_cur == 0 {
				if ([^]u8)(p)[0] == '!' {
					p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
				}
				nextcmd: cstring = nil
				if ([^]u8)(p)[0] == '|' {
					nextcmd = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
				} else if line_arg != nil && ([^]u8)(skipwhite(line_arg))[0] != 0 {
					nextcmd = line_arg
				} else if ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' && p_verbose > 0 {
					swmsg_e(true, cstring(W22_S), p)
				}
				if nextcmd != nil {
					(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = rawptr(nextcmd)
					if line_to_free^ != nil {
						xfree(rawptr((^cstring)(uintptr(eap) + 48)^))
						(^cstring)(uintptr(eap) + 48)^ = line_to_free^
						line_to_free^ = nil
					}
				}
				break
			}
			if indent > 2 && libc.strncmp(p, cstring("end"), 3) == 0 {
				indent -= 2
			} else if libc.strncmp(p, cstring("if"), 2) == 0 || libc.strncmp(p, cstring("wh"), 2) == 0 || libc.strncmp(p, cstring("for"), 3) == 0 || libc.strncmp(p, cstring("try"), 3) == 0 {
				indent += 2
			}
			if checkforcmd_e(&p, cstring("function"), 2) {
				if ([^]u8)(p)[0] == '!' {
					p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1)))
				}
				p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + uintptr(eval_fname_script(p))))
				trash := trans_function_name(&p, true, 0, nil, nil)
				xfree(rawptr(trash))
				if ([^]u8)(skipwhite(p))[0] == '(' {
					if nesting == MAX_FUNC_NESTING_O - 1 {
						emsg(cstring(E1058_S))
					} else {
						nesting += 1
						indent += 2
					}
				}
			}
			tp := p
			p = skip_range_e(p, nil)
			c0 := ([^]u8)(p)[0]
			if (checkforcmd_e(&p, cstring("append"), 1) || checkforcmd_e(&p, cstring("change"), 1) || checkforcmd_e(&p, cstring("insert"), 1)) && (c0 == '!' || c0 == '|' || ascii_iswhite(c0) || c0 == '\n' || c0 == 0) {
				skip_until = transmute(cstring)(xmemdupz_o2(&DOT1_O[0], 1))
			} else {
				p = tp
			}
			arg = skipwhite(skiptowhite(p))
			b0 := ([^]u8)(p)[0]
			b1 := ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 1))[0]
			b2 := ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 2))[0]
			b3 := ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 3))[0]
			is_py := b0 == 'p' && b1 == 'y' && (!(b2 >= '0' && b2 <= '9') && !(b2 >= 'a' && b2 <= 'z') && !(b2 >= 'A' && b2 <= 'Z') || b2 == 't' || ((b2 == '3' || b2 == 'x') && !((b3 >= 'a' && b3 <= 'z') || (b3 >= 'A' && b3 <= 'Z'))))
			is_pe := b0 == 'p' && b1 == 'e' && (!((b2 >= 'a' && b2 <= 'z') || (b2 >= 'A' && b2 <= 'Z')) || b2 == 'r')
			is_tc := b0 == 't' && b1 == 'c' && (!((b2 >= 'a' && b2 <= 'z') || (b2 >= 'A' && b2 <= 'Z')) || b2 == 'l')
			is_lua := b0 == 'l' && b1 == 'u' && b2 == 'a' && !((b3 >= 'a' && b3 <= 'z') || (b3 >= 'A' && b3 <= 'Z'))
			is_rb := b0 == 'r' && b1 == 'u' && b2 == 'b' && (!((b3 >= 'a' && b3 <= 'z') || (b3 >= 'A' && b3 <= 'Z')) || b3 == 'y')
			is_mz := b0 == 'm' && b1 == 'z' && (!((b2 >= 'a' && b2 <= 'z') || (b2 >= 'A' && b2 <= 'Z')) || b2 == 's')
			if ([^]u8)(arg)[0] == '<' && ([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(arg)) + 1))[0] == '<' && (is_py || is_pe || is_tc || is_lua || is_rb || is_mz) {
				p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 2)))
				if libc.strncmp(p, cstring("trim"), 4) == 0 && (([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0] == 0 || ascii_iswhite(([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0])) {
					p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 4)))
					heredoc_trimmedlen = C.size_t(uintptr(transmute(rawptr)(skipwhite(theline))) - uintptr(transmute(rawptr)(theline)))
					heredoc_trimmed = transmute(cstring)(xmemdupz_o2(transmute(^u8)(theline), heredoc_trimmedlen))
				}
				if ([^]u8)(p)[0] == 0 {
					skip_until = transmute(cstring)(xmemdupz_o2(&DOT1_O[0], 1))
				} else {
					ep := skiptowhite(p)
					skip_until = transmute(cstring)(xmemdupz_o2(transmute(^u8)(p), C.size_t(uintptr(transmute(rawptr)(ep)) - uintptr(transmute(rawptr)(p)))))
				}
				do_concat = false
				is_heredoc = true
			}
			if !is_heredoc {
				arg = p
				did_let := checkforcmd_e(&arg, cstring("let"), 2)
				if !did_let {
					did_let = checkforcmd_e(&p, cstring("const"), 5)
					if did_let {
						arg = p
					}
				}
				if did_let {
					var_count: C.int = 0
					semicolon: C.int = 0
					sv := skip_var_list(arg, &var_count, &semicolon, true)
					if sv != nil {
						arg = skipwhite(sv)
					} else {
						arg = nil
					}
					if arg != nil && libc.strncmp(arg, cstring("=<<"), 3) == 0 {
						p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 3)))
						has_trim := false
						for {
							if libc.strncmp(p, cstring("trim"), 4) == 0 && (([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0] == 0 || ascii_iswhite(([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0])) {
								p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 4)))
								has_trim = true
								continue
							}
							if libc.strncmp(p, cstring("eval"), 4) == 0 && (([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0] == 0 || ascii_iswhite(([^]u8)(transmute(rawptr)(uintptr(transmute(rawptr)(p)) + 4))[0])) {
								p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 4)))
								continue
							}
							break
						}
						if has_trim {
							heredoc_trimmedlen = C.size_t(uintptr(transmute(rawptr)(skipwhite(theline))) - uintptr(transmute(rawptr)(theline)))
							heredoc_trimmed = transmute(cstring)(xmemdupz_o2(transmute(^u8)(theline), heredoc_trimmedlen))
						}
						if skip_until != nil {
							xfree(rawptr(skip_until))
							skip_until = nil
						}
						ep2 := skiptowhite(p)
						skip_until = transmute(cstring)(xmemdupz_o2(transmute(^u8)(p), C.size_t(uintptr(transmute(rawptr)(ep2)) - uintptr(transmute(rawptr)(p)))))
						do_concat = false
						is_heredoc = true
					}
				}
			}
		}
		ga_grow_r(newlines, 1 + sourcing_lnum_off)
		lp := transmute(cstring)(xstrdup_o(transmute(^u8)(theline)))
		([^]cstring)(newlines.ga_data)[uintptr(newlines.ga_len)] = lp
		newlines.ga_len += 1
		for sourcing_lnum_off > 0 {
			sourcing_lnum_off -= 1
			([^]cstring)(newlines.ga_data)[uintptr(newlines.ga_len)] = nil
			newlines.ga_len += 1
		}
		if line_arg != nil && ([^]u8)(line_arg)[0] == 0 {
			line_arg = nil
		}
	}
	if did_emsg_g() == 0 {
		ret = OK_E
	}
	xfree(rawptr(skip_until))
	xfree(rawptr(heredoc_trimmed))
	need_wait_return_g = saved_wait_return
	return ret
}

// —— Batch 24aa: :function listing helpers (dormant) ——
E123_S :: "E123: Undefined function: %s"
E454_S :: "E454: Function list was modified"
UF_TML_COUNT_OFF_O :: 128
UF_TML_TOTAL_OFF_O :: 136
UF_TML_SELF_OFF_O :: 144
UF_PROF_INIT_OFF_O :: 92

// True when the function list changed under our feet (static in C).
function_list_modified_o :: proc "c" (prev_ht_changed: C.int) -> bool {
	context = runtime.default_context()
	if prev_ht_changed != C.int(func_hashtab.ht_changed) {
		emsg(cstring(E454_S))
		return true
	}
	return false
}

// "name(args) abort/range/..." head line (static in C).
list_func_head_o :: proc "c" (fp: rawptr, indent: bool, force: bool) -> C.int {
	context = runtime.default_context()
	prev_ht_changed := C.int(func_hashtab.ht_changed)
	msg_start()
	if function_list_modified_o(prev_ht_changed) {
		return FAIL_E
	}
	if indent {
		msg_puts(cstring("   "))
	}
	if force {
		msg_puts(cstring("function! "))
	} else {
		msg_puts(cstring("function "))
	}
	if (^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ != nil {
		msg_puts(transmute(cstring)((^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^))
	} else {
		msg_puts(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
	}
	msg_putchar('(')
	ga_len := (^C.int)(uintptr(fp) + UF_ARGS_OFF_O)^
	def_len := (^C.int)(uintptr(fp) + UF_DEF_ARGS_OFF_O)^
	j: C.int = 0
	for j < ga_len {
		if j != 0 {
			msg_puts(cstring(", "))
		}
		msg_puts(([^]cstring)((^rawptr)(uintptr(fp) + UF_ARGS_OFF_O + 16)^)[uintptr(j)])
		if j >= ga_len - def_len {
			msg_puts(cstring(" = "))
			msg_puts(([^]cstring)((^rawptr)(uintptr(fp) + UF_DEF_ARGS_OFF_O + 16)^)[uintptr(j - ga_len + def_len)])
		}
		j += 1
	}
	if (^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ {
		if j != 0 {
			msg_puts(cstring(", "))
		}
		msg_puts(cstring("..."))
	}
	msg_putchar(')')
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_ABORT_O) != 0 {
		msg_puts(cstring(" abort"))
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_RANGE_O) != 0 {
		msg_puts(cstring(" range"))
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DICT_O) != 0 {
		msg_puts(cstring(" dict"))
	}
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_CLOSURE_O) != 0 {
		msg_puts(cstring(" closure"))
	}
	msg_clr_eos_r()
	if p_verbose > 0 {
		last_set_msg_r((^sctx_T)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O)^)
	}
	return OK_E
}

// List all (or matching) functions (static in C).
list_functions_o :: proc "c" (regmatch: rawptr) {
	context = runtime.default_context()
	prev_ht_changed := C.int(func_hashtab.ht_changed)
	todo := C.int(func_hashtab.ht_used)
	hi := rawptr(uintptr(func_hashtab.ht_array))
	msg_ext_set_kind(cstring("list_cmd"))
	for todo > 0 && !got_int {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key != nil && hi_key != transmute(rawptr)(&hash_removed_c) {
			fp := rawptr(uintptr(hi_key) - uintptr(UF_NAME_OFF_O))
			todo -= 1
			matched := false
			if regmatch == nil {
				if !message_filtered(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))) && !func_name_refcount_o(transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O))) {
					matched = true
				}
			} else {
				rm := (^Regmatch_T)(regmatch)
				if !ascii_isdigit_o(([^]u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O))[0]) && vim_regexec_r(rm, transmute(^u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O)), 0) != 0 {
					matched = true
				}
			}
			if matched {
				if list_func_head_o(fp, false, false) == FAIL_E {
					return
				}
				if function_list_modified_o(prev_ht_changed) {
					return
				}
			}
		}
		hi = rawptr(uintptr(hi) + 16)
	}
}

// ":function /pat" pattern wrapper (static in C).
list_functions_matching_pat_o :: proc "c" (eap: rawptr) -> cstring {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + 0)^
	arg1 := transmute(^u8)(rawptr(uintptr(transmute(rawptr)(arg)) + 1))
	p := skip_regexp_r(arg1, '/', 1)
	if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ {
		rm := Regmatch_T{}
		c := ([^]u8)(p)[0]
		([^]u8)(p)[0] = 0
		rm.regprog = vim_regcomp(transmute(cstring)(arg1), RE_MAGIC)
		([^]u8)(p)[0] = c
		if rm.regprog != nil {
			rm.rm_ic = p_ic
			list_functions_o(rawptr(&rm))
			vim_regfree(rm.regprog)
		}
	}
	if ([^]u8)(p)[0] == '/' {
		return transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
	}
	return transmute(cstring)(p)
}

// ":function Name" single listing (static in C).
list_one_function_o :: proc "c" (eap: rawptr, name: cstring, p: cstring) -> rawptr {
	context = runtime.default_context()
	if ends_excmd_e(C.int(([^]u8)(skipwhite(p))[0])) == 0 {
		semsg(cstring(E488_S), p)
		return nil
	}
	(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(p)))
	if (^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ != nil {
		([^]u8)(p)[0] = 0
	}
	if (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ || got_int {
		return nil
	}
	fp := find_func(name)
	if fp == nil {
		emsg_funcname(cstring(E123_S), name)
		return nil
	}
	prev_ht_changed := C.int(func_hashtab.ht_changed)
	msg_ext_set_kind(cstring("list_cmd"))
	forceit := (^bool)(uintptr(eap) + 76)^
	if list_func_head_o(fp, !forceit, forceit) != OK_E {
		return fp
	}
	gl := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
	gd := (^rawptr)(uintptr(fp) + UF_LINES_OFF_O + 16)^
	j: C.int = 0
	for j < gl && !got_int {
		line := ([^]cstring)(gd)[uintptr(j)]
		if line == nil {
			j += 1
			continue
		}
		msg_putchar('\n')
		if !forceit {
			msg_outnum(j + 1)
			if j < 9 {
				msg_putchar(' ')
			}
			if j < 99 {
				msg_putchar(' ')
			}
			if function_list_modified_o(prev_ht_changed) {
				break
			}
		}
		msg_prt_line_r(transmute(^u8)(line), false)
		line_breakcheck()
		j += 1
	}
	if !got_int {
		msg_putchar('\n')
		if !function_list_modified_o(prev_ht_changed) {
			if forceit {
				msg_puts(cstring("endfunction"))
			} else {
				msg_puts(cstring("   endfunction"))
			}
		}
	}
	return fp
}

// Clear a ufunc's arg/def/line arrays (static in C).
func_clear_items_o :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	ga_clear_strings_e((^Garray)(uintptr(fp) + UF_ARGS_OFF_O))
	ga_clear_strings_e((^Garray)(uintptr(fp) + UF_DEF_ARGS_OFF_O))
	ga_clear_strings_e((^Garray)(uintptr(fp) + UF_LINES_OFF_O))
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_LUAREF_O) != 0 {
		api_free_luaref_e((^C.int)(uintptr(fp) + UF_LUAREF_OFF_O)^)
		(^C.int)(uintptr(fp) + UF_LUAREF_OFF_O)^ = LUA_NOREF_O
	}
	if (^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^ != nil {
		xfree((^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^)
		(^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^ = nil
	}
	if (^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^ != nil {
		xfree((^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^)
		(^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^ = nil
	}
	if (^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^ != nil {
		xfree((^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^)
		(^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^ = nil
	}
}

// —— Batch 24z: partial binding + debug cookies + funccal GC ——
foreign _ {
	@(link_name = "garbage_collect")
	garbage_collect_e :: proc "c" (testing: bool) -> bool ---
}

PT_NAME_OFF_O :: 8
LV_COPYID_OFF_O :: 68
DV_COPYID_OFF_O :: 12

// Bind a dict to a funcref (dict.Func partial creation).
@(export)
make_partial :: proc "c" (selfdict: rawptr, rettv: ^Typval_T) {
	context = runtime.default_context()
	fp: rawptr = nil
	fname_buf: [FLEN_FIXED_O + 1]u8
	error: C.int = 0
	if rettv.v_type == VAR_PARTIAL && rawptr(rettv.vval) != nil && (^rawptr)(uintptr(rawptr(rettv.vval)) + PT_FUNC_OFF_O)^ != nil {
		fp = (^rawptr)(uintptr(rawptr(rettv.vval)) + PT_FUNC_OFF_O)^
	} else {
		fname: cstring = nil
		if rettv.v_type == VAR_FUNC || rettv.v_type == VAR_STRING {
			fname = transmute(cstring)(rawptr(rettv.vval))
		} else if rawptr(rettv.vval) == nil || (^rawptr)(uintptr(rawptr(rettv.vval)) + PT_NAME_OFF_O)^ == nil {
			fname = nil
		} else {
			fname = transmute(cstring)((^rawptr)(uintptr(rawptr(rettv.vval)) + PT_NAME_OFF_O)^)
		}
		if fname == nil {
			rettv.v_type = VAR_FUNC
			rettv.vval = nil
		} else {
			tofree: rawptr = nil
			fname = fname_trans_sid_o(fname, ([^]u8)(&fname_buf[0]), &tofree, &error)
			fp = find_func(fname)
			xfree(tofree)
		}
	}
	if fp != nil && ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & FC_DICT_O) != 0 {
		pt := xcalloc(1, 48)
		(^C.int)(uintptr(pt) + PT_REFCOUNT_OFF_O)^ = 1
		(^rawptr)(uintptr(pt) + PT_DICT_OFF_O)^ = selfdict
		(^C.int)(uintptr(selfdict) + 8)^ += 1
		(^bool)(uintptr(pt) + PT_AUTO_OFF_O)^ = true
		if rettv.v_type == VAR_FUNC || rettv.v_type == VAR_STRING {
			(^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ = rawptr(rettv.vval)
		} else {
			ret_pt := rawptr(rettv.vval)
			if (^rawptr)(uintptr(ret_pt) + PT_NAME_OFF_O)^ != nil {
				nm := transmute(cstring)(xstrdup_o(transmute(^u8)((^rawptr)(uintptr(ret_pt) + PT_NAME_OFF_O)^)))
				(^rawptr)(uintptr(pt) + PT_NAME_OFF_O)^ = rawptr(nm)
				func_ref(nm)
			} else {
				(^rawptr)(uintptr(pt) + PT_FUNC_OFF_O)^ = (^rawptr)(uintptr(ret_pt) + PT_FUNC_OFF_O)^
				func_ptr_ref((^rawptr)(uintptr(ret_pt) + PT_FUNC_OFF_O)^)
			}
			if (^C.int)(uintptr(ret_pt) + PT_ARGC_OFF_O)^ > 0 {
				arg_size := C.size_t(16) * C.size_t((^C.int)(uintptr(ret_pt) + PT_ARGC_OFF_O)^)
				(^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^ = xmalloc(arg_size)
				(^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ = (^C.int)(uintptr(ret_pt) + PT_ARGC_OFF_O)^
				i: C.int = 0
				for i < (^C.int)(uintptr(pt) + PT_ARGC_OFF_O)^ {
					tv_copy((^Typval_T)(uintptr((^rawptr)(uintptr(ret_pt) + PT_ARGV_OFF_O)^) + uintptr(i) * 16), (^Typval_T)(uintptr((^rawptr)(uintptr(pt) + PT_ARGV_OFF_O)^) + uintptr(i) * 16))
					i += 1
				}
			}
			partial_unref_e(ret_pt)
		}
		rettv.v_type = VAR_PARTIAL
		rettv.vval = transmute(rawptr)(pt)
	}
}

// Name of the function running in a funccal cookie.
@(export)
func_name :: proc "c" (cookie: rawptr) -> cstring {
	context = runtime.default_context()
	return transmute(cstring)(rawptr(uintptr((^rawptr)(uintptr(cookie) + FC_FUNC_OFF_O)^) + UF_NAME_OFF_O))
}

// Breakpoint-line slot for a funccal cookie.
@(export)
func_breakpoint :: proc "c" (cookie: rawptr) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(cookie) + FC_BREAKPOINT_OFF_O)
}

// Debug-tick slot for a funccal cookie.
@(export)
func_dbg_tick :: proc "c" (cookie: rawptr) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(cookie) + FC_DBG_TICK_OFF_O)
}

// Nesting level of a funccal cookie.
@(export)
func_level :: proc "c" (cookie: rawptr) -> C.int {
	context = runtime.default_context()
	return (^C.int)(uintptr(cookie) + FC_LEVEL_OFF_O)^
}

// True when the current function ended via ":return".
@(export)
current_func_returned :: proc "c" () -> C.int {
	context = runtime.default_context()
	if (^bool)(uintptr(current_funccal) + FC_RETURNED_OFF_O)^ {
		return 1
	}
	return 0
}

// True when a funccal is unreferenced (static in C).
can_free_funccal_o :: proc "c" (fc: rawptr, copyID: C.int) -> bool {
	context = runtime.default_context()
	return (^C.int)(uintptr(fc) + FC_L_VARLIST_OFF_O + LV_COPYID_OFF_O)^ != copyID &&
		(^C.int)(uintptr(fc) + FC_L_VARS_OFF_O + DV_COPYID_OFF_O)^ != copyID &&
		(^C.int)(uintptr(fc) + FC_L_AVARS_OFF_O + DV_COPYID_OFF_O)^ != copyID &&
		(^C.int)(uintptr(fc) + FC_COPYID_OFF_O)^ != copyID
}

// Free unreferenced funccalls on the freed chain.
@(export)
free_unref_funccal :: proc "c" (copyID: C.int, testing: bool) -> bool {
	context = runtime.default_context()
	did_free := false
	did_free_funccal := false
	pfc := rawptr(&previous_funccal)
	for (^rawptr)(pfc)^ != nil {
		fc := (^rawptr)(pfc)^
		if can_free_funccal_o(fc, copyID) {
			(^rawptr)(pfc)^ = (^rawptr)(uintptr(fc) + FC_CALLER_OFF_O)^
			free_funccal_contents_o(fc)
			did_free = true
			did_free_funccal = true
		} else {
			pfc = rawptr(uintptr(fc) + FC_CALLER_OFF_O)
		}
	}
	if did_free_funccal {
		garbage_collect_e(testing)
	}
	return did_free
}

// —— Batch 24ad: removal cluster + shim rewires (cutover prep) ——
UF_CLEARED_OFF_O :: 12

// Remove a function from the hashtable (static in C).
func_remove_o :: proc "c" (fp: rawptr) -> bool {
	context = runtime.default_context()
	hi := hash_find_r(rawptr(&func_hashtab), transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
	if hi != nil {
		hi_key := (^rawptr)(uintptr(hi) + 8)^
		if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed_c) {
			return false
		}
	} else {
		return false
	}
	hash_remove_r(rawptr(&func_hashtab), hi)
	return true
}

// Clear a function's contents (static in C).
func_clear_o :: proc "c" (fp: rawptr, force: bool) {
	context = runtime.default_context()
	if (^bool)(uintptr(fp) + UF_CLEARED_OFF_O)^ {
		return
	}
	(^bool)(uintptr(fp) + UF_CLEARED_OFF_O)^ = true
	func_clear_items_o(fp)
	funccal_unref_o((^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^, fp, force)
}

// Free a function struct (static in C).
func_free_o :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	if ((^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ & (FC_DELETED_O | FC_REMOVED_O)) == 0 {
		func_remove_o(fp)
	}
	if (^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ != nil {
		xfree((^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^)
		(^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ = nil
	}
	xfree(fp)
}

// Clear + free a function (static in C).
func_clear_free_o :: proc "c" (fp: rawptr, force: bool) {
	context = runtime.default_context()
	func_clear_o(fp, force)
	func_free_o(fp)
}

// —— Batch 24ac: :function definition engine ——
foreign _ {
	@(link_name = "eval_isnamec")
	eval_isnamec_e :: proc "c" (c: C.int) -> bool ---
	@(link_name = "eval_isnamec1")
	eval_isnamec1_e :: proc "c" (c: C.int) -> bool ---
	@(link_name = "autoload_name")
	autoload_name_e :: proc "c" (name: cstring, name_len: C.size_t) -> cstring ---
	@(link_name = "prof_def_func")
	prof_def_func_e :: proc "c" () -> bool ---
}

E124_S :: "E124: Missing '(': %s"
E862_S :: "E862: Cannot use g: here"
E932_S :: "E932: Closure function should not be at top level: %s"
E707_S :: "E707: Function name conflicts with variable: %s"
E127_S :: "E127: Cannot redefine function %s: It is in use"
E746_S :: "E746: Function name does not match script file name: %s"
E717_S :: "E717: Dictionary entry already exists"
E122_S :: "E122: Function %s already exists, add ! to replace it"
FC_REMOVED_O :: 0x20

@(private = "file")
func_nr_g: C.int

// ":function" definition, listing entry point.
@(export)
ex_function :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	line_to_free: cstring = nil
	arg: cstring = nil
	line_arg: cstring = nil
	newargs := Garray{}
	default_args := Garray{}
	newlines := Garray{}
	varargs := false
	flags: C.int = 0
	fp: rawptr = nil
	free_fp := false
	overwrite := false
	fudi: [24]u8
	show_block := false
	eap_arg := (^cstring)(uintptr(eap) + 0)^
	skip := (^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^
	forceit := (^bool)(uintptr(eap) + 76)^
	stage: C.int = 0
	if ends_excmd_e(C.int(([^]u8)(eap_arg)[0])) != 0 {
		if !skip {
			list_functions_o(nil)
		}
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(eap_arg)))
		return
	}
	if ([^]u8)(eap_arg)[0] == '/' {
		p := list_functions_matching_pat_o(eap)
		(^rawptr)(uintptr(eap) + EXARG_NEXTCMD_OFF_O)^ = transmute(rawptr)(check_nextcmd_r(transmute(^u8)(p)))
		return
	}
	p := eap_arg
	name := save_function_name(&p, skip, TFN_NO_AUTOLOAD_O, rawptr(&fudi[0]))
	paren := vim_strchr_c(transmute(^u8)(p), '(') != nil
	if name == nil && ((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ == nil || !paren) && !skip {
		if !aborting_r() {
			if (^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^ != nil {
				semsg(cstring(E_DICTKEY_S), transmute(cstring)((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^))
			}
			xfree((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^)
			return
		}
		skip = true
		(^bool)(uintptr(eap) + EXARG_SKIP_OFF2_O)^ = true
	}
	saved_did_emsg := did_emsg_g()
	did_emsg_set(false)
	if !paren {
		fp = list_one_function_o(eap, name, p)
		goto_ret_free(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
		return
	}
	p = skipwhite(p)
	if ([^]u8)(p)[0] != '(' {
		if !skip {
			semsg(cstring(E124_S), eap_arg)
			goto_ret_free(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		if vim_strchr_c(transmute(^u8)(p), '(') != nil {
			p = transmute(cstring)(vim_strchr_c(transmute(^u8)(p), '('))
		}
	}
	p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1)))
	ga_init_r2(&newargs, 8, 3)
	ga_init_r2(&newlines, 8, 3)
	if !skip {
		if name != nil {
			arg = name
		} else {
			arg = transmute(cstring)((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^)
		}
		if arg != nil {
			fd_di := (^rawptr)(uintptr(&fudi[0]) + 16)^
			check_name := fd_di == nil
			if !check_name {
				dt := (^C.int)(uintptr(fd_di))^
				check_name = dt != VAR_FUNC && dt != VAR_PARTIAL
			}
			if check_name {
				name_base := arg
			if arg != transmute(cstring)((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^) {
				if ([^]u8)(arg)[0] == 0x80 {
					nb := vim_strchr_c(transmute(^u8)(arg), '_')
					if nb == nil {
						name_base = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(arg)) + 3))
					} else {
						name_base = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(nb)) + 1))
					}
				}
				i := 0
				nbp := name_base
				ok := true
				for ([^]u8)(nbp)[0] != 0 {
					if i == 0 {
						ok = eval_isnamec1_e(C.int(([^]u8)(nbp)[0]))
					} else {
						ok = eval_isnamec_e(C.int(([^]u8)(nbp)[0]))
					}
					if !ok {
						break
					}
					i += 1
					nbp = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(nbp)) + 1))
				}
				if ([^]u8)(nbp)[0] != 0 {
					emsg_funcname(e_invarg2, arg)
					goto_ret_free(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
					return
				}
			}
		}
		if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ != nil && (^C.int)(uintptr((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^) + 4)^ == VAR_DEF_SCOPE_O {
			emsg(cstring(E862_S))
			goto_ret_free(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
	}
	}
	if get_function_args_o(&p, ')', &newargs, &varargs, &default_args, skip) == FAIL_E {
		stage = 2
		goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
		return
	}
	if KeyTyped && ui_has(K_UICMDLINE_O) {
		show_block = true
		ui_ext_cmdline_block_append_e(0, (^cstring)(uintptr(eap) + 40)^)
	}
	for {
		p = skipwhite(p)
		if libc.strncmp(p, cstring("range"), 5) == 0 {
			flags |= FC_RANGE_O
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 5))
		} else if libc.strncmp(p, cstring("dict"), 4) == 0 {
			flags |= FC_DICT_O
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 4))
		} else if libc.strncmp(p, cstring("abort"), 5) == 0 {
			flags |= FC_ABORT_O
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 5))
		} else if libc.strncmp(p, cstring("closure"), 7) == 0 {
			flags |= FC_CLOSURE_O
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 7))
			if current_funccal == nil {
				if name == nil {
					emsg_funcname(cstring(E932_S), cstring(""))
				} else {
					emsg_funcname(cstring(E932_S), name)
				}
				stage = 1
				goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
				return
			}
		} else {
			break
		}
	}
	if ([^]u8)(p)[0] == '\n' {
		line_arg = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + 1))
	} else if ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != '"' && !skip && did_emsg_g() == 0 {
		semsg(cstring(E488_S), p)
	}
	if KeyTyped {
		if !skip && !forceit {
			if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ != nil && (^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^ == nil {
				emsg(cstring(E717_S))
			} else if name != nil && find_func(name) != nil {
				emsg_funcname(cstring(E122_S), name)
			}
		}
		if !skip && did_emsg_g() != 0 {
			stage = 1
			goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		if !ui_has(K_UICMDLINE_O) {
			msg_putchar('\n')
		}
		cmdline_row = msg_row
	}
	sourcing_lnum_top := sourcing_lnum_o()
	if get_function_body_o(eap, &newlines, line_arg, &line_to_free, show_block) == FAIL_E || skip {
		stage = 1
		goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
		return
	}
	namelen: C.size_t = 0
	if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ == nil {
		ht: rawptr = nil
		v := find_var_e(name, C.size_t(libc.strlen(name)), rawptr(&ht), 0)
		if v != nil && (^C.int)(uintptr(v))^ == VAR_FUNC {
			emsg_funcname(cstring(E707_S), name)
			stage = 1
			goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		fp = find_func(name)
		if fp != nil {
			if !forceit && ((^u32)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O)^ != (^u32)(&current_sctx_buf[0])^ || (^i32)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O + 4)^ == (^i32)(uintptr(&current_sctx_buf[0]) + 4)^) {
				emsg_funcname(cstring(E122_S), name)
				stage = 3
				goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
				return
			}
			if (^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ > 0 {
				emsg_funcname(cstring(E127_S), name)
				stage = 3
				goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
				return
			}
			if (^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ > 1 {
				(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ -= 1
				(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ |= FC_REMOVED_O
				fp = nil
				overwrite = true
			} else {
				exp_name := (^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^
				if name != nil {
					xfree(rawptr(name))
					name = nil
				}
				(^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ = nil
				func_clear_items_o(fp)
				(^rawptr)(uintptr(fp) + UF_NAME_EXP_OFF_O)^ = exp_name
				(^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ = 0
				(^C.int)(uintptr(fp) + UF_PROF_INIT_OFF_O)^ = 0
			}
		}
	} else {
		numbuf: [NUMBUFLEN]u8
		fp = nil
		if (^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^ == nil && !forceit {
			emsg(cstring(E717_S))
			stage = 1
			goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		fd_di := (^rawptr)(uintptr(&fudi[0]) + 16)^
		if fd_di == nil {
			if value_check_lock((^C.int)(uintptr((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^) + 0)^, eap_arg, max(C.size_t) - 1) {
				stage = 1
				goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
				return
			}
		} else if value_check_lock((^C.int)(uintptr(fd_di) + 4)^, eap_arg, max(C.size_t) - 1) {
			stage = 1
			goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		xfree(rawptr(name))
		name = nil
		func_nr_g += 1
		n := libc.snprintf(([^]u8)(&numbuf[0]), NUMBUFLEN, cstring("%d"), func_nr_g)
		if n < 0 {
			n = 0
		}
		namelen = C.size_t(n)
		name = transmute(cstring)(xmemdupz_o2(&numbuf[0], namelen))
	}
	if fp == nil {
		if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ == nil && vim_strchr_c(transmute(^u8)(name), '#') != nil {
			j := FAIL_E
			if sourcing_name_str_o() != nil {
				scriptname := autoload_name_e(name, C.size_t(libc.strlen(name)))
				sl := vim_strchr_c(transmute(^u8)(scriptname), '/')
				if sl != nil {
					plen := C.int(libc.strlen(transmute(cstring)(sl)))
					snm := sourcing_name_str_o()
					slen := C.int(libc.strlen(snm))
					if slen > plen && path_fnamecmp_r(transmute(cstring)(sl), transmute(cstring)(rawptr(uintptr(transmute(rawptr)(snm)) + uintptr(slen - plen)))) == 0 {
						j = OK_E
					}
				}
				xfree(rawptr(scriptname))
			}
			if j == FAIL_E {
				semsg(cstring(E746_S), name)
				stage = 1
				goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
				return
			}
		}
		if namelen == 0 {
			namelen = C.size_t(libc.strlen(name))
		}
		fp = alloc_ufunc_o(name, namelen)
		if (^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^ != nil {
			func_name_dup := transmute(cstring)(xmemdupz_o2(transmute(^u8)(name), namelen))
			fd_di2 := (^rawptr)(uintptr(&fudi[0]) + 16)^
			if fd_di2 == nil {
				fd_di2 = tv_dict_item_alloc(transmute(cstring)((^rawptr)(uintptr(&fudi[0]) + FD_NEWKEY_OFF_O)^))
				if tv_dict_add((^rawptr)(uintptr(&fudi[0]) + FD_DICT_OFF_O)^, fd_di2) == FAIL_E {
					xfree(fd_di2)
					xfree(rawptr(func_name_dup))
					if fp != nil {
						xfree(fp)
						fp = nil
					}
					stage = 1
					goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
					return
				}
				(^rawptr)(uintptr(&fudi[0]) + 16)^ = fd_di2
			} else {
				tv_clear_e((^Typval_T)(fd_di2))
			}
			(^C.int)(uintptr(fd_di2))^ = VAR_FUNC
			(^rawptr)(uintptr(fd_di2) + 8)^ = rawptr(func_name_dup)
			flags |= FC_DICT_O
		}
		if overwrite {
			hi := hash_find_r(rawptr(&func_hashtab), name)
			(^rawptr)(uintptr(hi) + 8)^ = rawptr(uintptr(fp) + UF_NAME_OFF_O)
		} else if hash_add_e(rawptr(&func_hashtab), transmute(^u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O))) == FAIL_E {
			free_fp = true
			stage = 1
			goto_epilogue(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
			return
		}
		(^C.int)(uintptr(fp) + UF_REFCOUNT_OFF_O)^ = 1
	}
	([^]Garray)(uintptr(fp) + UF_ARGS_OFF_O)[0] = newargs
	([^]Garray)(uintptr(fp) + UF_DEF_ARGS_OFF_O)[0] = default_args
	([^]Garray)(uintptr(fp) + UF_LINES_OFF_O)[0] = newlines
	if (flags & FC_CLOSURE_O) != 0 {
		register_closure_o(fp)
	} else {
		(^rawptr)(uintptr(fp) + UF_SCOPED_OFF_O)^ = nil
	}
	if prof_def_func_e() {
		func_do_profile_e(fp)
	}
	(^bool)(uintptr(fp) + UF_VARARGS_OFF_O)^ = varargs
	if sandbox != 0 {
		flags |= FC_SANDBOX_O
	}
	(^C.int)(uintptr(fp) + UF_FLAGS_OFF_O)^ = flags
	(^C.int)(uintptr(fp) + UF_CALLS_OFF_O)^ = 0
	libc.memcpy(rawptr(uintptr(fp) + UF_SCRIPT_CTX_OFF_O), rawptr(&current_sctx_buf[0]), 24)
	(^i32)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O + 8)^ += sourcing_lnum_top
	nlua_set_sctx_r(rawptr(uintptr(fp) + UF_SCRIPT_CTX_OFF_O))
	goto_ret_free(stage, &fp, free_fp, &newargs, &default_args, &newlines, &line_to_free, rawptr(&fudi[0]), &name, saved_did_emsg, show_block, eap)
}

// Shared epilogue for ex_function exits.
goto_epilogue :: proc "c" (stage: C.int, fp: ^rawptr, free_fp: bool, newargs: ^Garray, default_args: ^Garray, newlines: ^Garray, line_to_free: ^cstring, fdp: rawptr, name: ^cstring, saved_did_emsg: C.int, show_block: bool, eap: rawptr) {
	context = runtime.default_context()
	if stage == 1 {
		if fp^ != nil {
			ga_init_r2((^Garray)(uintptr(fp^) + UF_ARGS_OFF_O), 8, 1)
			ga_init_r2((^Garray)(uintptr(fp^) + UF_DEF_ARGS_OFF_O), 8, 1)
		}
		if fp^ != nil {
			nx := (^rawptr)(uintptr(fp^) + UF_NAME_EXP_OFF_O)^
			if nx != nil {
				xfree(nx)
				(^rawptr)(uintptr(fp^) + UF_NAME_EXP_OFF_O)^ = nil
			}
		}
		if free_fp {
			xfree(fp^)
			fp^ = nil
		}
	} else if stage == 2 {
		if fp^ != nil {
			nx := (^rawptr)(uintptr(fp^) + UF_NAME_EXP_OFF_O)^
			if nx != nil {
				xfree(nx)
				(^rawptr)(uintptr(fp^) + UF_NAME_EXP_OFF_O)^ = nil
			}
		}
		if free_fp {
			xfree(fp^)
			fp^ = nil
		}
	}
	if stage >= 1 {
		ga_clear_strings_e(newargs)
		ga_clear_strings_e(default_args)
		ga_clear_strings_e(newlines)
	}
	goto_ret_free(stage, fp, free_fp, newargs, default_args, newlines, line_to_free, fdp, name, saved_did_emsg, show_block, eap)
}

// Final cleanup shared by all ex_function exits.
goto_ret_free :: proc "c" (stage: C.int, fp: ^rawptr, free_fp: bool, newargs: ^Garray, default_args: ^Garray, newlines: ^Garray, line_to_free: ^cstring, fdp: rawptr, name: ^cstring, saved_did_emsg: C.int, show_block: bool, eap: rawptr) {
	context = runtime.default_context()
	xfree(rawptr(line_to_free^))
	xfree((^rawptr)(uintptr(fdp) + FD_NEWKEY_OFF_O)^)
	xfree(rawptr(name^))
	did_emsg_set(did_emsg_g() != 0 || saved_did_emsg != 0)
	if show_block {
		ui_ext_cmdline_block_leave_r()
	}
}
