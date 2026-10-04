package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// strings.c port: string utilities.
// Publics are @(export); C-statics are _o dormant plains.

// —— Batch S1: pure string leaves ——

@(export)
xstrnsave :: proc "c" (s: cstring, length: C.size_t) -> cstring {
	context = runtime.default_context()
	dst := xmallocz(length)
	n := libc.strlen(s)
	if n > length {
		n = length
	}
	libc.memmove(rawptr(dst), rawptr(transmute(^u8)(s)), n)
	return transmute(cstring)(dst)
}

@(export)
vim_strsave_escaped :: proc "c" (s: cstring, esc_chars: cstring) -> cstring {
	context = runtime.default_context()
	return vim_strsave_escaped_ext(s, esc_chars, '\\', false)
}

@(export)
vim_strsave_escaped_ext :: proc "c" (s: cstring, esc_chars: cstring, cc: u8, bsl: bool) -> cstring {
	context = runtime.default_context()
	length: C.size_t = 1
	p := transmute(^u8)(s)
	for ([^]u8)(p)[0] != 0 {
		l := C.size_t(utfc_ptr2len(transmute(cstring)(p)))
		if l > 1 {
			length += l
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(l)))
		} else {
			if vim_strchr(esc_chars, C.int(([^]u8)(p)[0])) != nil || (bsl && rem_backslash(transmute(cstring)(p))) {
				length += 1
			}
			length += 1
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
	}
	out := transmute(^u8)(xmalloc(length))
	q := out
	p = transmute(^u8)(s)
	for ([^]u8)(p)[0] != 0 {
		l := C.size_t(utfc_ptr2len(transmute(cstring)(p)))
		if l > 1 {
			libc.memmove(rawptr(q), rawptr(p), l)
			q = transmute(^u8)(rawptr(uintptr(q) + uintptr(l)))
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(l)))
		} else {
			if vim_strchr(esc_chars, C.int(([^]u8)(p)[0])) != nil || (bsl && rem_backslash(transmute(cstring)(p))) {
				([^]u8)(q)[0] = cc
				q = transmute(^u8)(rawptr(uintptr(q) + 1))
			}
			([^]u8)(q)[0] = ([^]u8)(p)[0]
			q = transmute(^u8)(rawptr(uintptr(q) + 1))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
	}
	([^]u8)(q)[0] = 0
	return transmute(cstring)(out)
}

@(export)
vim_strnsave_unquoted :: proc "c" (s_in: cstring, length: C.size_t) -> cstring {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	send := transmute(^u8)(rawptr(uintptr(s) + uintptr(length)))
	ret_length: C.size_t = 0
	inquote := false
	p := s
	for uintptr(p) < uintptr(send) {
		if ([^]u8)(p)[0] == '"' {
			inquote = !inquote
		} else if ([^]u8)(p)[0] == '\\' && inquote && uintptr(p) + 1 < uintptr(send) && (([^]u8)(rawptr(uintptr(p) + 1))[0] == '\\' || ([^]u8)(rawptr(uintptr(p) + 1))[0] == '"') {
			ret_length += 1
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		} else {
			ret_length += 1
		}
		p = transmute(^u8)(rawptr(uintptr(p) + 1))
	}
	ret := transmute(^u8)(xmallocz(ret_length))
	rp := ret
	inquote = false
	p = s
	for uintptr(p) < uintptr(send) {
		if ([^]u8)(p)[0] == '"' {
			inquote = !inquote
		} else if ([^]u8)(p)[0] == '\\' && inquote && uintptr(p) + 1 < uintptr(send) && (([^]u8)(rawptr(uintptr(p) + 1))[0] == '\\' || ([^]u8)(rawptr(uintptr(p) + 1))[0] == '"') {
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			([^]u8)(rp)[0] = ([^]u8)(p)[0]
			rp = transmute(^u8)(rawptr(uintptr(rp) + 1))
		} else {
			([^]u8)(rp)[0] = ([^]u8)(p)[0]
			rp = transmute(^u8)(rawptr(uintptr(rp) + 1))
		}
		p = transmute(^u8)(rawptr(uintptr(p) + 1))
	}
	return transmute(cstring)(ret)
}

@(export)
vim_strsave_shellescape :: proc "c" (s: cstring, do_special: bool, do_newline: bool) -> cstring {
	context = runtime.default_context()
	csh_like := csh_like_shell()
	fish_like := fish_like_shell()
	length := libc.strlen(s) + 3
	p := transmute(^u8)(s)
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '\'' {
			length += 3
		}
		if (([^]u8)(p)[0] == '\n' && (csh_like || do_newline)) || (([^]u8)(p)[0] == '!' && (csh_like || do_special)) {
			length += 1
			if csh_like && do_special {
				length += 1
			}
		}
		l: C.size_t = 0
		if do_special && find_cmdline_var(transmute(cstring)(p), &l) >= 0 {
			length += 1
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(l) - 1))
		}
		if ([^]u8)(p)[0] == '\\' && fish_like {
			length += 1
		}
		p = transmute(^u8)(rawptr(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p)))))
	}
	out := transmute(^u8)(xmalloc(length))
	d := out
	([^]u8)(d)[0] = '\''
	d = transmute(^u8)(rawptr(uintptr(d) + 1))
	p = transmute(^u8)(s)
	for ([^]u8)(p)[0] != 0 {
		if ([^]u8)(p)[0] == '\'' {
			([^]u8)(d)[0] = '\''
			([^]u8)(d)[1] = '\\'
			([^]u8)(d)[2] = '\''
			([^]u8)(d)[3] = '\''
			d = transmute(^u8)(rawptr(uintptr(d) + 4))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			continue
		}
		if (([^]u8)(p)[0] == '\n' && (csh_like || do_newline)) || (([^]u8)(p)[0] == '!' && (csh_like || do_special)) {
			([^]u8)(d)[0] = '\\'
			d = transmute(^u8)(rawptr(uintptr(d) + 1))
			if csh_like && do_special {
				([^]u8)(d)[0] = '\\'
				d = transmute(^u8)(rawptr(uintptr(d) + 1))
			}
			([^]u8)(d)[0] = ([^]u8)(p)[0]
			d = transmute(^u8)(rawptr(uintptr(d) + 1))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			continue
		}
		l: C.size_t = 0
		if do_special && find_cmdline_var(transmute(cstring)(p), &l) >= 0 {
			([^]u8)(d)[0] = '\\'
			d = transmute(^u8)(rawptr(uintptr(d) + 1))
			libc.memmove(rawptr(d), rawptr(p), l)
			d = transmute(^u8)(rawptr(uintptr(d) + uintptr(l)))
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(l)))
			continue
		}
		if ([^]u8)(p)[0] == '\\' && fish_like {
			([^]u8)(d)[0] = '\\'
			d = transmute(^u8)(rawptr(uintptr(d) + 1))
			([^]u8)(d)[0] = ([^]u8)(p)[0]
			d = transmute(^u8)(rawptr(uintptr(d) + 1))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			continue
		}
		fp := transmute(cstring)(p)
		tp := transmute(cstring)(d)
		mb_copy_char_e(&fp, &tp)
		p = transmute(^u8)(fp)
		d = transmute(^u8)(tp)
	}
	([^]u8)(d)[0] = '\''
	([^]u8)(d)[1] = 0
	return transmute(cstring)(out)
}

@(export)
vim_strsave_up :: proc "c" (s: cstring) -> cstring {
	context = runtime.default_context()
	out := transmute(^u8)(xmalloc(libc.strlen(s) + 1))
	vim_strcpy_up(out, s)
	return transmute(cstring)(out)
}

@(export)
vim_strnsave_up :: proc "c" (s: cstring, length: C.size_t) -> cstring {
	context = runtime.default_context()
	out := transmute(^u8)(xmalloc(length + 1))
	vim_strncpy_up(out, s, length)
	return transmute(cstring)(out)
}

@(export)
vim_strup :: proc "c" (p_in: ^u8) {
	context = runtime.default_context()
	p := p_in
	for {
		c := ([^]u8)(p)[0]
		if c == 0 {
			break
		}
		if c >= 'a' && c <= 'z' {
			([^]u8)(p)[0] = c - 0x20
		}
		p = transmute(^u8)(rawptr(uintptr(p) + 1))
	}
}

@(export)
vim_strcpy_up :: proc "c" (dst_in: ^u8, src_in: cstring) {
	context = runtime.default_context()
	dst := dst_in
	src := transmute(^u8)(src_in)
	for {
		c := ([^]u8)(src)[0]
		src = transmute(^u8)(rawptr(uintptr(src) + 1))
		if c == 0 {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 0x20
		}
		([^]u8)(dst)[0] = c
		dst = transmute(^u8)(rawptr(uintptr(dst) + 1))
	}
	([^]u8)(dst)[0] = 0
}

@(export)
vim_strncpy_up :: proc "c" (dst_in: ^u8, src_in: cstring, n_in: C.size_t) {
	context = runtime.default_context()
	dst := dst_in
	src := transmute(^u8)(src_in)
	n := n_in
	for n > 0 {
		c := ([^]u8)(src)[0]
		src = transmute(^u8)(rawptr(uintptr(src) + 1))
		n -= 1
		if c == 0 {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 0x20
		}
		([^]u8)(dst)[0] = c
		dst = transmute(^u8)(rawptr(uintptr(dst) + 1))
	}
	([^]u8)(dst)[0] = 0
}

@(export)
vim_memcpy_up :: proc "c" (dst_in: ^u8, src_in: cstring, n_in: C.size_t) {
	context = runtime.default_context()
	dst := dst_in
	src := transmute(^u8)(src_in)
	n := n_in
	for n > 0 {
		n -= 1
		c := ([^]u8)(src)[0]
		src = transmute(^u8)(rawptr(uintptr(src) + 1))
		if c >= 'a' && c <= 'z' {
			c -= 0x20
		}
		([^]u8)(dst)[0] = c
		dst = transmute(^u8)(rawptr(uintptr(dst) + 1))
	}
}

@(export)
mb_strup_buf :: proc "c" (src: cstring, dst_in: ^u8) -> C.size_t {
	context = runtime.default_context()
	i: C.size_t = 0
	p := transmute(^u8)(src)
	for ([^]u8)(p)[0] != 0 {
		ci := utf_ptr2CharInfo_o(p)
		c := C.int(([^]u8)(p)[0])
		if ci.value >= 0 {
			c = ci.value
		}
		i += C.size_t(utf_char2bytes(mb_toupper_r(c), transmute(^u8)(rawptr(uintptr(dst_in) + uintptr(i)))))
		p = transmute(^u8)(rawptr(uintptr(p) + uintptr(ci.len)))
	}
	([^]u8)(dst_in)[i] = 0
	return i
}

@(export)
strcase_save :: proc "c" (orig: cstring, upper: bool) -> cstring {
	context = runtime.default_context()
	orig_len := libc.strlen(orig)
	res := transmute(^u8)(xmalloc(orig_len + 1))
	res_index: C.size_t = 0
	p := transmute(^u8)(orig)
	for ([^]u8)(p)[0] != 0 {
		ci := utf_ptr2CharInfo_o(p)
		c := C.int(([^]u8)(p)[0])
		if ci.value >= 0 {
			c = ci.value
		}
		newc := c
		if upper {
			newc = mb_toupper_r(c)
		} else {
			newc = mb_tolower_e(c)
		}
		newl := C.size_t(utf_char2len_r(newc))
		if res_index + newl > orig_len {
			new_size := res_index + newl + 1
			res = transmute(^u8)(xrealloc(res, C.size_t(new_size)))
			orig_len = new_size - 1
		}
		utf_char2bytes(newc, transmute(^u8)(rawptr(uintptr(res) + uintptr(res_index))))
		res_index += newl
		p = transmute(^u8)(rawptr(uintptr(p) + uintptr(ci.len)))
	}
	([^]u8)(res)[res_index] = 0
	return transmute(cstring)(res)
}

@(export)
del_trailing_spaces :: proc "c" (ptr_in: ^u8) {
	context = runtime.default_context()
	q := transmute(^u8)(rawptr(uintptr(ptr_in) + uintptr(libc.strlen(transmute(cstring)(ptr_in)))))
	for {
		q = transmute(^u8)(rawptr(uintptr(q) - 1))
		if !(uintptr(q) > uintptr(ptr_in) && (([^]u8)(q)[0] == ' ' || ([^]u8)(q)[0] == 9) && ([^]u8)(rawptr(uintptr(q) - 1))[0] != '\\' && ([^]u8)(rawptr(uintptr(q) - 1))[0] != Ctrl_V) {
			break
		}
		([^]u8)(q)[0] = 0
	}
}

@(export)
striequal :: proc "c" (a: cstring, b: cstring) -> bool {
	context = runtime.default_context()
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return _strcasecmp(a, b) == 0
}

@(export)
vim_strnicmp_asc :: proc "c" (s1_in: cstring, s2_in: cstring, len_in: C.size_t) -> C.int {
	context = runtime.default_context()
	s1 := transmute(^u8)(s1_in)
	s2 := transmute(^u8)(s2_in)
	length := len_in
	i: C.int = 0
	for length > 0 {
		i = C.int(tolower_asc_o(([^]u8)(s1)[0])) - C.int(tolower_asc_o(([^]u8)(s2)[0]))
		if i != 0 {
			break
		}
		if ([^]u8)(s1)[0] == 0 {
			break
		}
		s1 = transmute(^u8)(rawptr(uintptr(s1) + 1))
		s2 = transmute(^u8)(rawptr(uintptr(s2) + 1))
		length -= 1
	}
	return i
}

@(export)
vim_strchr :: proc "c" (s: cstring, c_in: C.int) -> cstring {
	context = runtime.default_context()
	if c_in <= 0 {
		return nil
	} else if c_in < 0x80 {
		return transmute(cstring)(libc.strchr(s, c_in))
	} else {
		buf: [22]u8
		length := utf_char2bytes(c_in, &buf[0])
		buf[length] = 0
		return strstr_c(s, transmute(cstring)(&buf[0]))
	}
}

sort_compare_str_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	return libc.strcmp(transmute(cstring)(([^]rawptr)(s1)[0]), transmute(cstring)(([^]rawptr)(s2)[0]))
}

@(export)
sort_strings :: proc "c" (files: ^rawptr, count: C.int) {
	context = runtime.default_context()
	qsort_e(rawptr(files), C.size_t(count), size_of(rawptr), sort_compare_str_o)
}

@(export)
has_non_ascii :: proc "c" (s: cstring) -> bool {
	context = runtime.default_context()
	if s != nil {
		p := transmute(^u8)(s)
		for ([^]u8)(p)[0] != 0 {
			if ([^]u8)(p)[0] >= 128 {
				return true
			}
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
		}
	}
	return false
}

@(export)
has_non_ascii_len :: proc "c" (s: cstring, length: C.size_t) -> bool {
	context = runtime.default_context()
	if s != nil {
		for i: C.size_t = 0; i < length; i += 1 {
			if ([^]u8)(transmute(^u8)(s))[i] >= 128 {
				return true
			}
		}
	}
	return false
}

@(export)
concat_str :: proc "c" (str1: cstring, str2: cstring) -> cstring {
	context = runtime.default_context()
	l := libc.strlen(str1)
	dst := transmute(^u8)(xmalloc(l + libc.strlen(str2) + 1))
	libc.memmove(rawptr(dst), rawptr(transmute(^u8)(str1)), l)
	libc.memmove(rawptr(uintptr(dst) + uintptr(l)), rawptr(transmute(^u8)(str2)), libc.strlen(str2) + 1)
	return transmute(cstring)(dst)
}

// —— Batch S2: printf-helpers, replace, byteidx ——

foreign _ {
	@(link_name = "vsnprintf")
	c_vsnprintf :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: ^libc.va_list) -> C.int ---
	@(link_name = "strncasecmp")
	c_strncasecmp :: proc "c" (s1: cstring, s2: cstring, n: C.size_t) -> C.int ---
}

@(export)
kv_do_printf_v :: proc "c" (str: ^StringBuilder, fmt: cstring, ap_start: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	remaining := str.capacity - str.size
	base := rawptr(nil)
	if str.items != nil {
		base = rawptr(uintptr(str.items) + uintptr(str.size))
	}
	ap1: [24]u8
	va_copy_e(rawptr(&ap1[0]), rawptr(ap_start))
	printed := c_vsnprintf(transmute(^u8)(base), remaining, fmt, transmute(^libc.va_list)(&ap1[0]))
	va_end_e(rawptr(&ap1[0]))
	if printed < 0 {
		return -1
	}
	if C.size_t(printed) >= remaining {
		sb_ensure_o(str, C.size_t(printed) + 1)
		if str.items == nil {
			libc.abort()
		}
		ap2: [24]u8
		va_copy_e(rawptr(&ap2[0]), rawptr(ap_start))
		printed = c_vsnprintf(transmute(^u8)(rawptr(uintptr(str.items) + uintptr(str.size))), str.capacity - str.size, fmt, transmute(^libc.va_list)(&ap2[0]))
		va_end_e(rawptr(&ap2[0]))
		if printed < 0 {
			return -1
		}
	}
	str.size += C.size_t(printed)
	return printed
}

@(export)
arena_printf_v :: proc "c" (arena: rawptr, fmt: cstring, ap_start: ^libc.va_list) -> String {
	context = runtime.default_context()
	remaining: C.size_t = 0
	buf: ^u8 = nil
	if arena != nil {
		if (^rawptr)(uintptr(arena) + 0)^ == nil {
			arena_alloc_block(arena)
		}
		remaining = (^C.size_t)(uintptr(arena) + 16)^ - (^C.size_t)(uintptr(arena) + 8)^
		buf = transmute(^u8)(rawptr(uintptr((^rawptr)(uintptr(arena) + 0)^) + uintptr((^C.size_t)(uintptr(arena) + 8)^)))
	}
	ap1: [24]u8
	va_copy_e(rawptr(&ap1[0]), rawptr(ap_start))
	printed := c_vsnprintf(buf, remaining, fmt, transmute(^libc.va_list)(&ap1[0]))
	va_end_e(rawptr(&ap1[0]))
	if printed < 0 {
		return String{}
	}
	if C.size_t(printed) >= remaining {
		buf = transmute(^u8)(arena_alloc(arena, C.size_t(printed) + 1, false))
		ap2: [24]u8
		va_copy_e(rawptr(&ap2[0]), rawptr(ap_start))
		printed = c_vsnprintf(buf, C.size_t(printed) + 1, fmt, transmute(^libc.va_list)(&ap2[0]))
		va_end_e(rawptr(&ap2[0]))
		if printed < 0 {
			return String{}
		}
	} else {
		(^C.size_t)(uintptr(arena) + 8)^ += C.size_t(printed) + 1
	}
	return String{data = transmute(cstring)(buf), size = C.size_t(printed)}
}

@(export)
reverse_text :: proc "c" (s_in: cstring) -> cstring {
	context = runtime.default_context()
	s := transmute(^u8)(s_in)
	length := libc.strlen(s_in)
	rev := transmute(^u8)(xmalloc(length + 1))
	si: C.size_t = 0
	rev_i := length
	for si < length {
		mb_len := C.size_t(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(s) + uintptr(si)))))
		rev_i -= mb_len
		libc.memmove(rawptr(uintptr(rev) + uintptr(rev_i)), rawptr(uintptr(s) + uintptr(si)), mb_len)
		si += mb_len
	}
	([^]u8)(rev)[length] = 0
	return transmute(cstring)(rev)
}

@(export)
strrep :: proc "c" (src_in: cstring, what: cstring, rep: cstring) -> cstring {
	context = runtime.default_context()
	src := transmute(^u8)(src_in)
	whatlen := libc.strlen(what)
	count: C.size_t = 0
	pos := strstr_c(src_in, what)
	for pos != nil {
		count += 1
		pos = strstr_c(transmute(cstring)(rawptr(uintptr(transmute(^u8)(pos)) + uintptr(whatlen))), what)
	}
	if count == 0 {
		return nil
	}
	replen := libc.strlen(rep)
	ret := transmute(^u8)(xmalloc(libc.strlen(src_in) + count * (replen - whatlen) + 1))
	ptr := ret
	src = transmute(^u8)(src_in)
	pos = strstr_c(transmute(cstring)(src), what)
	for pos != nil {
		idx := C.size_t(uintptr(transmute(^u8)(pos)) - uintptr(src))
		libc.memmove(rawptr(ptr), rawptr(src), idx)
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + uintptr(idx)))
		libc.memmove(rawptr(ptr), rawptr(transmute(^u8)(rep)), replen)
		ptr = transmute(^u8)(rawptr(uintptr(ptr) + uintptr(replen)))
		src = transmute(^u8)(rawptr(uintptr(transmute(^u8)(pos)) + uintptr(whatlen)))
		pos = strstr_c(transmute(cstring)(src), what)
	}
	libc.memmove(rawptr(ptr), rawptr(src), libc.strlen(transmute(cstring)(src)) + 1)
	return transmute(cstring)(ret)
}

E_USING_NUMBER_AS_BOOL_NR_S :: "E1023: Using a Number as a Bool: %d"

byteidx_common_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, comp: bool) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	str := tv_get_string_chk(&([^]Typval_T)(argvars)[0])
	idx := tv_get_number_chk(&([^]Typval_T)(argvars)[1], nil)
	if str == nil || idx < 0 {
		return
	}
	utf16idx: C.longlong = 0
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		err := false
		utf16idx = tv_get_bool_chk(&([^]Typval_T)(argvars)[2], &err)
		if err {
			return
		}
		if utf16idx < 0 || utf16idx > 1 {
			semsg(cstring(E_USING_NUMBER_AS_BOOL_NR_S), C.int(utf16idx))
			return
		}
	}
	t := transmute(^u8)(str)
	for idx > 0 {
		if ([^]u8)(t)[0] == 0 {
			return
		}
		if utf16idx != 0 {
			clen := C.int(0)
			if comp {
				clen = utf_ptr2len_o(transmute(cstring)(t))
			} else {
				clen = utfc_ptr2len(transmute(cstring)(t))
			}
			c := C.int(([^]u8)(t)[0])
			if clen > 1 {
				c = utf_ptr2char(transmute(cstring)(t))
			}
			if c > 0xFFFF {
				idx -= 1
			}
			if idx > 0 {
				t = transmute(^u8)(rawptr(uintptr(t) + uintptr(clen)))
			}
		} else if idx > 0 {
			if comp {
				t = transmute(^u8)(rawptr(uintptr(t) + uintptr(utf_ptr2len_o(transmute(cstring)(t)))))
			} else {
				t = transmute(^u8)(rawptr(uintptr(t) + uintptr(utfc_ptr2len(transmute(cstring)(t)))))
			}
		}
		idx -= 1
	}
	(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(uintptr(t) - uintptr(transmute(^u8)(str)))
}

@(export)
f_byteidx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	byteidx_common_o(argvars, rettv, false)
}

@(export)
f_byteidxcomp :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	byteidx_common_o(argvars, rettv, true)
}

@(export)
f_charidx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	if tv_check_for_string_arg(argvars, 0) == 0 || tv_check_for_number_arg(argvars, 1) == 0 || tv_check_for_opt_bool_arg(argvars, 2) == 0 {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && tv_check_for_opt_bool_arg(argvars, 3) == 0 {
		return
	}
	str := tv_get_string_chk(&([^]Typval_T)(argvars)[0])
	idx := tv_get_number_chk(&([^]Typval_T)(argvars)[1], nil)
	if str == nil || idx < 0 {
		return
	}
	countcc: C.longlong = 0
	utf16idx: C.longlong = 0
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		countcc = tv_get_bool(&([^]Typval_T)(argvars)[2])
		if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
			utf16idx = tv_get_bool(&([^]Typval_T)(argvars)[3])
		}
	}
	p := transmute(^u8)(str)
	str0 := p
	length: C.int = 0
	for {
		if utf16idx != 0 {
			if idx < 0 {
				break
			}
		} else if uintptr(p) > uintptr(str0) + uintptr(idx) {
			break
		}
		if ([^]u8)(p)[0] == 0 {
			done := false
			if utf16idx != 0 {
				if idx == 0 {
					done = true
				}
			} else if uintptr(p) == uintptr(str0) + uintptr(idx) {
				done = true
			}
			if done {
				(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(length)
			}
			return
		}
		if utf16idx != 0 {
			idx -= 1
		}
		length += 1
		if countcc != 0 {
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(utf_ptr2len_o(transmute(cstring)(p)))))
		} else {
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p)))))
		}
	}
	if length > 0 {
		(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(length - 1)
	} else {
		(^C.longlong)(uintptr(rettv) + 8)^ = 0
	}
}

// —— Batch S3: f_ string builtins ——

@(export)
f_str2list :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	l := tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	p := transmute(^u8)(tv_get_string(&([^]Typval_T)(argvars)[0]))
	for ([^]u8)(p)[0] != 0 {
		l2 := utf_ptr2len_o(transmute(cstring)(p))
		tv_list_append_number(l, C.longlong(utf_ptr2char(transmute(cstring)(p))))
		p = transmute(^u8)(rawptr(uintptr(p) + uintptr(l2)))
	}
}

@(export)
f_str2nr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	base: C.int = 10
	what: C.int = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		base = C.int(tv_get_number(&([^]Typval_T)(argvars)[1]))
		if base != 2 && base != 8 && base != 10 && base != 16 {
			emsg(cstring(e_invarg_s))
			return
		}
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && tv_get_bool(&([^]Typval_T)(argvars)[2]) != 0 {
			what |= STR2NR_QUOTE_O
		}
	}
	p := skipwhite(tv_get_string(&([^]Typval_T)(argvars)[0]))
	isneg := ([^]u8)(transmute(^u8)(p))[0] == '-'
	if ([^]u8)(transmute(^u8)(p))[0] == '+' || ([^]u8)(transmute(^u8)(p))[0] == '-' {
		p = skipwhite(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + 1)))
	}
	if base == 2 {
		what |= STR2NR_BIN_O | STR2NR_FORCE_O
	} else if base == 8 {
		what |= STR2NR_OCT_O | STR2NR_OOCT_O | STR2NR_FORCE_O
	} else if base == 16 {
		what |= STR2NR_HEX_O | STR2NR_FORCE_O
	}
	n: C.longlong = 0
	vim_str2nr(p, nil, nil, what, &n, nil, 0, false, nil)
	if isneg {
		(^C.longlong)(uintptr(rettv) + 8)^ = -n
	} else {
		(^C.longlong)(uintptr(rettv) + 8)^ = n
	}
}

@(export)
f_strgetchar :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	str := tv_get_string_chk(&([^]Typval_T)(argvars)[0])
	if str == nil {
		return
	}
	err := false
	charidx := tv_get_number_chk(&([^]Typval_T)(argvars)[1], &err)
	if err {
		return
	}
	length := libc.strlen(str)
	byteidx: C.size_t = 0
	for charidx >= 0 && byteidx < length {
		if charidx == 0 {
			(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(utf_ptr2char(transmute(cstring)(rawptr(uintptr(transmute(^u8)(str)) + uintptr(byteidx)))))
			break
		}
		charidx -= 1
		byteidx += C.size_t(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(transmute(^u8)(str)) + uintptr(byteidx)))))
	}
}

@(export)
f_stridx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	buf: [65]u8
	needle := tv_get_string_chk(&([^]Typval_T)(argvars)[1])
	haystack := tv_get_string_buf_chk(&([^]Typval_T)(argvars)[0], &buf[0])
	haystack_start := haystack
	if needle == nil || haystack == nil {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		err := false
		start_idx := C.ptrdiff_t(tv_get_number_chk(&([^]Typval_T)(argvars)[2], &err))
		if err || start_idx >= C.ptrdiff_t(libc.strlen(haystack)) {
			return
		}
		if start_idx >= 0 {
			haystack = transmute(cstring)(rawptr(uintptr(transmute(^u8)(haystack)) + uintptr(start_idx)))
		}
	}
	pos := strstr_c(haystack, needle)
	if pos != nil {
		(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(uintptr(transmute(^u8)(pos)) - uintptr(transmute(^u8)(haystack_start)))
	}
}

@(export)
f_string :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(transmute(^u8)(encode_tv2string(&([^]Typval_T)(argvars)[0], nil)))
}

@(export)
f_strlen :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(libc.strlen(tv_get_string(&([^]Typval_T)(argvars)[0])))
}

strchar_common_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, skipcc: bool) {
	context = runtime.default_context()
	s := transmute(^u8)(tv_get_string(&([^]Typval_T)(argvars)[0]))
	length: C.longlong = 0
	for ([^]u8)(s)[0] != 0 {
		pp := s
		if skipcc {
			mb_cptr2char_adv(&pp)
		} else {
			mb_ptr2char_adv(&pp)
		}
		s = pp
		length += 1
	}
	(^C.longlong)(uintptr(rettv) + 8)^ = length
}

@(export)
f_strcharlen :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	strchar_common_o(argvars, rettv, true)
}

@(export)
f_strchars :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	skipcc: C.longlong = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		err := false
		skipcc = tv_get_bool_chk(&([^]Typval_T)(argvars)[1], &err)
		if err {
			return
		}
		if skipcc < 0 || skipcc > 1 {
			semsg(cstring(E_USING_NUMBER_AS_BOOL_NR_S), C.int(skipcc))
			return
		}
	}
	strchar_common_o(argvars, rettv, skipcc != 0)
}

@(export)
f_strutf16len :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	if tv_check_for_string_arg(argvars, 0) == 0 || tv_check_for_opt_bool_arg(argvars, 1) == 0 {
		return
	}
	countcc: C.longlong = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		countcc = tv_get_bool(&([^]Typval_T)(argvars)[1])
	}
	s := transmute(^u8)(tv_get_string(&([^]Typval_T)(argvars)[0]))
	length: C.longlong = 0
	for ([^]u8)(s)[0] != 0 {
		ch := C.int(0)
		if countcc != 0 {
			ch = mb_cptr2char_adv(&s)
		} else {
			ch = mb_ptr2char_adv(&s)
		}
		if ch > 0xFFFF {
			length += 1
		}
		length += 1
	}
	(^C.longlong)(uintptr(rettv) + 8)^ = length
}

@(export)
f_strdisplaywidth :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	s := tv_get_string(&([^]Typval_T)(argvars)[0])
	col: C.int = 0
	if ([^]Typval_T)(argvars)[1].v_type != VAR_UNKNOWN {
		col = C.int(tv_get_number(&([^]Typval_T)(argvars)[1]))
	}
	(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(linetabsize_col(col, transmute(^u8)(s)) - col)
}

@(export)
f_strwidth :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	s := tv_get_string(&([^]Typval_T)(argvars)[0])
	(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(mb_string2cells_s(s))
}

@(export)
f_strcharpart :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	p := tv_get_string(&([^]Typval_T)(argvars)[0])
	slen := libc.strlen(p)
	nbyte: C.int = 0
	skipcc: C.longlong = 0
	err := false
	nchar := tv_get_number_chk(&([^]Typval_T)(argvars)[1], &err)
	if !err {
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
			skipcc = tv_get_bool_chk(&([^]Typval_T)(argvars)[3], &err)
			if err {
				return
			}
			if skipcc < 0 || skipcc > 1 {
				semsg(cstring(E_USING_NUMBER_AS_BOOL_NR_S), C.int(skipcc))
				return
			}
		}
		if nchar > 0 {
			for nchar > 0 && C.size_t(nbyte) < slen {
				if skipcc != 0 {
					nbyte += utfc_ptr2len(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + uintptr(nbyte))))
				} else {
					nbyte += utf_ptr2len_o(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + uintptr(nbyte))))
				}
				nchar -= 1
			}
		} else {
			nbyte = C.int(nchar)
		}
	}
	length: C.int = 0
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		charlen := C.int(tv_get_number(&([^]Typval_T)(argvars)[2]))
		for charlen > 0 && nbyte + length < C.int(slen) {
			off := nbyte + length
			if off < 0 {
				length += 1
			} else {
				if skipcc != 0 {
					length += utfc_ptr2len(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + uintptr(off))))
				} else {
					length += utf_ptr2len_o(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + uintptr(off))))
				}
			}
			charlen -= 1
		}
	} else {
		length = C.int(slen) - nbyte
	}
	if nbyte < 0 {
		length += nbyte
		nbyte = 0
	} else if C.size_t(nbyte) > slen {
		nbyte = C.int(slen)
	}
	if length < 0 {
		length = 0
	} else if nbyte + length > C.int(slen) {
		length = C.int(slen) - nbyte
	}
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(xmemdupz(rawptr(uintptr(transmute(^u8)(p)) + uintptr(nbyte)), C.size_t(length)))
}

@(export)
f_strpart :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	err := false
	p := tv_get_string(&([^]Typval_T)(argvars)[0])
	slen := libc.strlen(p)
	n := tv_get_number_chk(&([^]Typval_T)(argvars)[1], &err)
	length: C.longlong = 0
	if err {
		length = 0
	} else if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		length = tv_get_number(&([^]Typval_T)(argvars)[2])
	} else {
		length = C.longlong(slen) - n
	}
	if n < 0 {
		length += n
		n = 0
	} else if n > C.longlong(slen) {
		n = C.longlong(slen)
	}
	if length < 0 {
		length = 0
	} else if n + length > C.longlong(slen) {
		length = C.longlong(slen) - n
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
		off: i64 = i64(n)
		for off < i64(slen) && length > 0 {
			length -= 1
			off += i64(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(transmute(^u8)(p)) + uintptr(off)))))
		}
		length = C.longlong(off) - n
	}
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(xmemdupz(rawptr(uintptr(transmute(^u8)(p)) + uintptr(n)), C.size_t(length)))
}

@(export)
f_strridx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [65]u8
	needle := tv_get_string_chk(&([^]Typval_T)(argvars)[1])
	haystack := tv_get_string_buf_chk(&([^]Typval_T)(argvars)[0], &buf[0])
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	if needle == nil || haystack == nil {
		return
	}
	haystack_len := libc.strlen(haystack)
	end_idx := C.ptrdiff_t(haystack_len)
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		end_idx = C.ptrdiff_t(tv_get_number_chk(&([^]Typval_T)(argvars)[2], nil))
		if end_idx < 0 {
			return
		}
	}
	if ([^]u8)(transmute(^u8)(needle))[0] == 0 {
		(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(end_idx)
		return
	}
	lastmatch: cstring = nil
	rest := haystack
	for ([^]u8)(transmute(^u8)(rest))[0] != 0 {
		rest = strstr_c(rest, needle)
		if rest == nil || uintptr(transmute(^u8)(rest)) > uintptr(transmute(^u8)(haystack)) + uintptr(end_idx) {
			break
		}
		lastmatch = rest
		rest = transmute(cstring)(rawptr(uintptr(transmute(^u8)(rest)) + 1))
	}
	if lastmatch != nil {
		(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(uintptr(transmute(^u8)(lastmatch)) - uintptr(transmute(^u8)(haystack)))
	}
}

@(export)
f_strtrans :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(transmute(^u8)(transstr(tv_get_string(&([^]Typval_T)(argvars)[0]), true)))
}

@(export)
f_utf16idx :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	(^C.longlong)(uintptr(rettv) + 8)^ = -1
	if tv_check_for_string_arg(argvars, 0) == 0 || tv_check_for_opt_number_arg(argvars, 1) == 0 || tv_check_for_opt_bool_arg(argvars, 2) == 0 {
		return
	}
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN && tv_check_for_opt_bool_arg(argvars, 3) == 0 {
		return
	}
	str := tv_get_string_chk(&([^]Typval_T)(argvars)[0])
	idx := tv_get_number_chk(&([^]Typval_T)(argvars)[1], nil)
	if str == nil || idx < 0 {
		return
	}
	countcc: C.longlong = 0
	charidx: C.longlong = 0
	if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
		countcc = tv_get_bool(&([^]Typval_T)(argvars)[2])
		if ([^]Typval_T)(argvars)[3].v_type != VAR_UNKNOWN {
			charidx = tv_get_bool(&([^]Typval_T)(argvars)[3])
		}
	}
	p := transmute(^u8)(str)
	length: C.int = 0
	utf16idx: C.int = 0
	for {
		cont := false
		if charidx != 0 {
			if idx >= 0 {
				cont = true
			}
		} else if uintptr(p) <= uintptr(transmute(^u8)(str)) + uintptr(idx) {
			cont = true
		}
		if !cont {
			break
		}
		if ([^]u8)(p)[0] == 0 {
			done := false
			if charidx != 0 {
				if idx == 0 {
					done = true
				}
			} else if uintptr(p) == uintptr(transmute(^u8)(str)) + uintptr(idx) {
				done = true
			}
			if done {
				(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(length)
			}
			return
		}
		utf16idx = length
		clen := C.int(0)
		if countcc != 0 {
			clen = utf_ptr2len_o(transmute(cstring)(p))
		} else {
			clen = utfc_ptr2len(transmute(cstring)(p))
		}
		c := C.int(([^]u8)(p)[0])
		if clen > 1 {
			c = utf_ptr2char(transmute(cstring)(p))
		}
		if c > 0xFFFF {
			length += 1
		}
		p = transmute(^u8)(rawptr(uintptr(p) + uintptr(clen)))
		if charidx != 0 {
			idx -= 1
		}
		length += 1
	}
	(^C.longlong)(uintptr(rettv) + 8)^ = C.longlong(utf16idx)
}

@(export)
f_tolower :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(transmute(^u8)(strcase_save(tv_get_string(&([^]Typval_T)(argvars)[0]), false)))
}

@(export)
f_toupper :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = rawptr(transmute(^u8)(strcase_save(tv_get_string(&([^]Typval_T)(argvars)[0]), true)))
}

@(export)
f_tr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf: [65]u8
	buf2: [65]u8
	in_str := tv_get_string(&([^]Typval_T)(argvars)[0])
	fromstr := tv_get_string_buf_chk(&([^]Typval_T)(argvars)[1], &buf[0])
	tostr := tv_get_string_buf_chk(&([^]Typval_T)(argvars)[2], &buf2[0])
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = nil
	if fromstr == nil || tostr == nil {
		return
	}
	ga := Garray{}
	ga_init(&ga, 1, 80)
	first := true
	failed := false
	ip := transmute(^u8)(in_str)
	for ([^]u8)(ip)[0] != 0 {
		cpstr := ip
		inlen := utfc_ptr2len(transmute(cstring)(ip))
		cplen := inlen
		idx: C.int = 0
		fromlen: C.int = 0
		fp := transmute(^u8)(fromstr)
		for ([^]u8)(fp)[0] != 0 {
			fromlen = utfc_ptr2len(transmute(cstring)(fp))
			if fromlen == inlen && libc.strncmp(transmute(cstring)(ip), transmute(cstring)(fp), C.size_t(inlen)) == 0 {
				tolen: C.int = 0
				tp := transmute(^u8)(tostr)
				for ([^]u8)(tp)[0] != 0 {
					tolen = utfc_ptr2len(transmute(cstring)(tp))
					if idx == 0 {
						idx -= 1
						cplen = tolen
						cpstr = tp
						break
					}
					idx -= 1
					tp = transmute(^u8)(rawptr(uintptr(tp) + uintptr(tolen)))
				}
				if ([^]u8)(tp)[0] == 0 {
					failed = true
				}
				break
			}
			idx += 1
			fp = transmute(^u8)(rawptr(uintptr(fp) + uintptr(fromlen)))
		}
		if first && cpstr == ip {
			first = false
			tp := transmute(^u8)(tostr)
			for ([^]u8)(tp)[0] != 0 {
				tolen := utfc_ptr2len(transmute(cstring)(tp))
				idx -= 1
				tp = transmute(^u8)(rawptr(uintptr(tp) + uintptr(tolen)))
			}
			if idx != 0 {
				failed = true
			}
		}
		if failed {
			break
		}
		ga_grow(&ga, cplen)
		libc.memmove(rawptr(uintptr(ga.ga_data) + uintptr((^C.int)(&ga.ga_len)^)), rawptr(cpstr), C.size_t(cplen))
		(^C.int)(&ga.ga_len)^ += cplen
		ip = transmute(^u8)(rawptr(uintptr(ip) + uintptr(inlen)))
	}
	if failed {
		semsg(e_invarg2, fromstr)
		ga_clear(&ga)
		return
	}
	ga_append(&ga, 0)
	([^]Typval_T)(rettv)[0].vval = ga.ga_data
}

@(export)
f_trim :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	buf1: [65]u8
	buf2: [65]u8
	head := tv_get_string_buf_chk(&([^]Typval_T)(argvars)[0], &buf1[0])
	mask: cstring = nil
	prev: cstring = nil
	dir: C.int = 0
	([^]Typval_T)(rettv)[0].v_type = VAR_STRING
	([^]Typval_T)(rettv)[0].vval = nil
	if head == nil {
		return
	}
	if tv_check_for_opt_string_arg(argvars, 1) == 0 {
		return
	}
	if ([^]Typval_T)(argvars)[1].v_type == VAR_STRING {
		mask = tv_get_string_buf_chk(&([^]Typval_T)(argvars)[1], &buf2[0])
		if ([^]u8)(transmute(^u8)(mask))[0] == 0 {
			mask = nil
		}
		if ([^]Typval_T)(argvars)[2].v_type != VAR_UNKNOWN {
			err := false
			dir = C.int(tv_get_number_chk(&([^]Typval_T)(argvars)[2], &err))
			if err {
				return
			}
			if dir < 0 || dir > 2 {
				semsg(e_invarg2, tv_get_string(&([^]Typval_T)(argvars)[2]))
				return
			}
		}
	}
	if dir == 0 || dir == 1 {
		for ([^]u8)(transmute(^u8)(head))[0] != 0 {
			c1 := utf_ptr2char(head)
			trimmed := false
			if mask == nil {
				if !(c1 > 32 && c1 != 0xa0) {
					trimmed = true
				}
			} else {
				mp := mask
				for ([^]u8)(transmute(^u8)(mp))[0] != 0 {
					if c1 == utf_ptr2char(mp) {
						trimmed = true
						break
					}
					mp = transmute(cstring)(rawptr(uintptr(transmute(^u8)(mp)) + uintptr(utfc_ptr2len(mp))))
				}
				if !trimmed {
					break
				}
			}
			if mask == nil && !trimmed {
				break
			}
			head = transmute(cstring)(rawptr(uintptr(transmute(^u8)(head)) + uintptr(utfc_ptr2len(head))))
		}
	}
	tail := transmute(cstring)(rawptr(uintptr(transmute(^u8)(head)) + uintptr(libc.strlen(head))))
	if dir == 0 || dir == 2 {
		for uintptr(transmute(^u8)(tail)) > uintptr(transmute(^u8)(head)) {
			prev = tail
			prev = transmute(cstring)(rawptr(uintptr(transmute(^u8)(prev)) - uintptr(utf_head_off(head, transmute(cstring)(rawptr(uintptr(transmute(^u8)(prev)) - 1)))) - 1))
			c1 := utf_ptr2char(prev)
			trimmed := false
			if mask == nil {
				if !(c1 > 32 && c1 != 0xa0) {
					trimmed = true
				}
			} else {
				mp := mask
				for ([^]u8)(transmute(^u8)(mp))[0] != 0 {
					if c1 == utf_ptr2char(mp) {
						trimmed = true
						break
					}
					mp = transmute(cstring)(rawptr(uintptr(transmute(^u8)(mp)) + uintptr(utfc_ptr2len(mp))))
				}
				if !trimmed {
					break
				}
			}
			if mask == nil && !trimmed {
				break
			}
			tail = prev
		}
	}
	([^]Typval_T)(rettv)[0].vval = rawptr(transmute(^u8)(xstrnsave(head, C.size_t(uintptr(transmute(^u8)(tail)) - uintptr(transmute(^u8)(head))))))
}

@(export)
cmp_keyvalue_value :: proc "c" (a: rawptr, b: rawptr) -> C.int {
	context = runtime.default_context()
	return libc.strcmp(transmute(cstring)(([^]rawptr)(a)[1]), transmute(cstring)(([^]rawptr)(b)[1]))
}

@(export)
cmp_keyvalue_value_n :: proc "c" (a: rawptr, b: rawptr) -> C.int {
	context = runtime.default_context()
	la := (^C.size_t)(uintptr(a) + 16)^
	lb := (^C.size_t)(uintptr(b) + 16)^
	m := la
	if lb > m {
		m = lb
	}
	return libc.strncmp(transmute(cstring)(([^]rawptr)(a)[1]), transmute(cstring)(([^]rawptr)(b)[1]), m)
}

@(export)
cmp_keyvalue_value_i :: proc "c" (a: rawptr, b: rawptr) -> C.int {
	context = runtime.default_context()
	return _strcasecmp(transmute(cstring)(([^]rawptr)(a)[1]), transmute(cstring)(([^]rawptr)(b)[1]))
}

@(export)
cmp_keyvalue_value_ni :: proc "c" (a: rawptr, b: rawptr) -> C.int {
	context = runtime.default_context()
	la := (^C.size_t)(uintptr(a) + 16)^
	lb := (^C.size_t)(uintptr(b) + 16)^
	m := la
	if lb > m {
		m = lb
	}
	return c_strncasecmp(transmute(cstring)(([^]rawptr)(a)[1]), transmute(cstring)(([^]rawptr)(b)[1]), m)
}

// —— Batch S4: printf format machinery ——

foreign _ {
	@(link_name = "nvim_odin_va_copy")
	va_copy_e :: proc "c" (dst: rawptr, src: rawptr) ---
	@(link_name = "nvim_odin_va_end")
	va_end_e :: proc "c" (ap: rawptr) ---
	@(link_name = "nvim_odin_va_arg_i64")
	va_arg_i64_e :: proc "c" (ap: rawptr, type: C.int) -> i64 ---
	@(link_name = "nvim_odin_va_arg_u64")
	va_arg_u64_e :: proc "c" (ap: rawptr, type: C.int) -> u64 ---
	@(link_name = "nvim_odin_va_arg_f64")
	va_arg_f64_e :: proc "c" (ap: rawptr) -> f64 ---
	@(link_name = "nvim_odin_va_arg_ptr")
	va_arg_ptr_e :: proc "c" (ap: rawptr, type: C.int) -> rawptr ---
}

E_PRINTF_S :: "E766: Insufficient arguments for printf()"
E_VAL_TOO_LARGE_LEN_S :: "E1510: Value too large: %.*s"
E_MIX_POSITIONAL_S :: "E1500: Cannot mix positional and non-positional arguments: %s"
E_FMT_UNUSED_S :: "E1501: format argument %d unused in $-style format: %s"
E_FIELD_REUSED_S :: "E1502: Positional argument %d used as field width reused as different type: %s/%s"
E_OUT_OF_BOUNDS_S :: "E1503: Positional argument %d out of bounds: %s"
E_TYPE_INCONSISTENT_S :: "E1504: Positional argument %d type used inconsistently: %s/%s"
E_INVALID_FORMAT_S :: "E1505: Invalid format specifier: %s"
E_APTYPES_NULL_S :: "E1507: Internal error: ap_types or ap_types[idx] is NULL: %d: %s"
E807_S :: "E807: Expected Float argument for printf()"

TYPE_UNKNOWN_O :: -1
TYPE_INT_O :: 0
TYPE_LONGINT_O :: 1
TYPE_LONGLONGINT_O :: 2
TYPE_SIGNEDSIZET_O :: 3
TYPE_UNSIGNEDINT_O :: 4
TYPE_UNSIGNEDLONGINT_O :: 5
TYPE_UNSIGNEDLONGLONGINT_O :: 6
TYPE_SIZET_O :: 7
TYPE_POINTER_O :: 8
TYPE_PERCENT_O :: 9
TYPE_CHAR_O :: 10
TYPE_STRING_O :: 11
TYPE_FLOAT_O :: 12
MAX_ALLOWED_STRING_WIDTH_O :: 1048576

tv_nr_o :: proc "c" (tvs: ^Typval_T, idxp: ^C.int) -> C.longlong {
	context = runtime.default_context()
	idx := idxp^ - 1
	n: C.longlong = 0
	if ([^]Typval_T)(tvs)[idx].v_type == VAR_UNKNOWN {
		emsg(cstring(E_PRINTF_S))
	} else {
		idxp^ += 1
		err := false
		n = tv_get_number_chk(&([^]Typval_T)(tvs)[idx], &err)
		if err {
			n = 0
		}
	}
	return n
}

tv_str_o :: proc "c" (tvs: ^Typval_T, idxp: ^C.int, tofree: ^rawptr) -> cstring {
	context = runtime.default_context()
	idx := idxp^ - 1
	s: cstring = nil
	if ([^]Typval_T)(tvs)[idx].v_type == VAR_UNKNOWN {
		emsg(cstring(E_PRINTF_S))
	} else {
		idxp^ += 1
		t := (^Typval_T)(uintptr(tvs) + uintptr(idx) * 16)
		if t.v_type == VAR_STRING || t.v_type == VAR_NUMBER {
			s = tv_get_string_chk(t)
			tofree^ = nil
		} else {
			s = transmute(cstring)(encode_tv2echo(t, nil))
			tofree^ = rawptr(transmute(^u8)(s))
		}
	}
	return s
}

tv_ptr_o :: proc "c" (tvs: ^Typval_T, idxp: ^C.int) -> rawptr {
	context = runtime.default_context()
	idx := idxp^ - 1
	if ([^]Typval_T)(tvs)[idx].v_type == VAR_UNKNOWN {
		emsg(cstring(E_PRINTF_S))
		return nil
	}
	idxp^ += 1
	return ([^]Typval_T)(tvs)[idx].vval
}

tv_float_o :: proc "c" (tvs: ^Typval_T, idxp: ^C.int) -> f64 {
	context = runtime.default_context()
	idx := idxp^ - 1
	f: f64 = 0
	if ([^]Typval_T)(tvs)[idx].v_type == VAR_UNKNOWN {
		emsg(cstring(E_PRINTF_S))
	} else {
		idxp^ += 1
		t := ([^]Typval_T)(tvs)[idx].v_type
		if t == VAR_FLOAT {
			f = transmute(f64)(([^]Typval_T)(tvs)[idx].vval)
		} else if t == VAR_NUMBER {
			f = f64(transmute(C.longlong)(([^]Typval_T)(tvs)[idx].vval))
		} else {
			emsg(cstring(E807_S))
		}
	}
	return f
}

TYPENAME_INT_S :: "int"
TYPENAME_LONGINT_S :: "long int"
TYPENAME_LONGLONGINT_S :: "long long int"
TYPENAME_SIGNEDSIZET_S :: "signed size_t"
TYPENAME_UINT_S :: "unsigned int"
TYPENAME_ULONGINT_S :: "unsigned long int"
TYPENAME_ULONGLONGINT_S :: "unsigned long long int"
TYPENAME_SIZET_S :: "size_t"
TYPENAME_POINTER_S :: "pointer"
TYPENAME_PERCENT_S :: "percent"
TYPENAME_CHAR_S :: "char"
TYPENAME_STRING_S :: "string"
TYPENAME_FLOAT_S :: "float"
TYPENAME_UNKNOWN_S :: "unknown"

infinity_str_o :: proc "c" (positive: bool, fmt_spec: u8, force_sign: C.int, space_for_positive: C.int) -> cstring {
	context = runtime.default_context()
	table: [8]cstring = {"-inf", "inf", "+inf", " inf", "-INF", "INF", "+INF", " INF"}
	idx := 0
	if positive {
		idx = 1 + int(force_sign) + int(force_sign) * int(space_for_positive)
	}
	if fmt_spec >= 'A' && fmt_spec <= 'Z' {
		idx += 4
	}
	return table[idx]
}

format_typeof_o :: proc "c" (type_in: cstring) -> C.int {
	context = runtime.default_context()
	t := transmute(^u8)(type_in)
	length_modifier: u8 = 0
	if ([^]u8)(t)[0] == 'h' || ([^]u8)(t)[0] == 'l' || ([^]u8)(t)[0] == 'z' {
		length_modifier = ([^]u8)(t)[0]
		t = transmute(^u8)(rawptr(uintptr(t) + 1))
		if length_modifier == 'l' && ([^]u8)(t)[0] == 'l' {
			length_modifier = 'L'
			t = transmute(^u8)(rawptr(uintptr(t) + 1))
		}
	}
	fmt_spec := ([^]u8)(t)[0]
	if fmt_spec == 'i' {
		fmt_spec = 'd'
	} else if fmt_spec == '*' {
		fmt_spec = 'd'
		length_modifier = 'h'
	} else if fmt_spec == 'D' {
		fmt_spec = 'd'
		length_modifier = 'l'
	} else if fmt_spec == 'U' {
		fmt_spec = 'u'
		length_modifier = 'l'
	} else if fmt_spec == 'O' {
		fmt_spec = 'o'
		length_modifier = 'l'
	}
	if fmt_spec == '%' {
		return TYPE_PERCENT_O
	} else if fmt_spec == 'c' {
		return TYPE_CHAR_O
	} else if fmt_spec == 's' || fmt_spec == 'S' {
		return TYPE_STRING_O
	} else if fmt_spec == 'd' || fmt_spec == 'u' || fmt_spec == 'b' || fmt_spec == 'B' || fmt_spec == 'o' || fmt_spec == 'x' || fmt_spec == 'X' || fmt_spec == 'p' {
		if fmt_spec == 'p' {
			return TYPE_POINTER_O
		} else if fmt_spec == 'b' || fmt_spec == 'B' {
			return TYPE_UNSIGNEDLONGLONGINT_O
		} else if fmt_spec == 'd' {
			if length_modifier == 0 || length_modifier == 'h' {
				return TYPE_INT_O
			} else if length_modifier == 'l' {
				return TYPE_LONGINT_O
			} else if length_modifier == 'L' {
				return TYPE_LONGLONGINT_O
			} else if length_modifier == 'z' {
				return TYPE_SIGNEDSIZET_O
			}
		} else {
			if length_modifier == 0 || length_modifier == 'h' {
				return TYPE_UNSIGNEDINT_O
			} else if length_modifier == 'l' {
				return TYPE_UNSIGNEDLONGINT_O
			} else if length_modifier == 'L' {
				return TYPE_UNSIGNEDLONGLONGINT_O
			} else if length_modifier == 'z' {
				return TYPE_SIZET_O
			}
		}
	} else if fmt_spec == 'f' || fmt_spec == 'F' || fmt_spec == 'e' || fmt_spec == 'E' || fmt_spec == 'g' || fmt_spec == 'G' {
		return TYPE_FLOAT_O
	}
	return TYPE_UNKNOWN_O
}

format_typename_o :: proc "c" (type_in: cstring) -> cstring {
	context = runtime.default_context()
	t := format_typeof_o(type_in)
	if t == TYPE_INT_O {
		return cstring(TYPENAME_INT_S)
	} else if t == TYPE_LONGINT_O {
		return cstring(TYPENAME_LONGINT_S)
	} else if t == TYPE_LONGLONGINT_O {
		return cstring(TYPENAME_LONGLONGINT_S)
	} else if t == TYPE_UNSIGNEDINT_O {
		return cstring(TYPENAME_UINT_S)
	} else if t == TYPE_SIGNEDSIZET_O {
		return cstring(TYPENAME_SIGNEDSIZET_S)
	} else if t == TYPE_UNSIGNEDLONGINT_O {
		return cstring(TYPENAME_ULONGINT_S)
	} else if t == TYPE_UNSIGNEDLONGLONGINT_O {
		return cstring(TYPENAME_ULONGLONGINT_S)
	} else if t == TYPE_SIZET_O {
		return cstring(TYPENAME_SIZET_S)
	} else if t == TYPE_POINTER_O {
		return cstring(TYPENAME_POINTER_S)
	} else if t == TYPE_PERCENT_O {
		return cstring(TYPENAME_PERCENT_S)
	} else if t == TYPE_CHAR_O {
		return cstring(TYPENAME_CHAR_S)
	} else if t == TYPE_STRING_O {
		return cstring(TYPENAME_STRING_S)
	} else if t == TYPE_FLOAT_O {
		return cstring(TYPENAME_FLOAT_S)
	}
	return cstring(TYPENAME_UNKNOWN_S)
}

adjust_types_o :: proc "c" (ap_types: ^[^]cstring, arg: C.int, num_posarg: ^C.int, type_in: cstring) -> C.int {
	context = runtime.default_context()
	if arg <= 0 {
		semsg(cstring(E_INVALID_FORMAT_S), type_in)
		return 0
	}
	if ap_types^ == nil || num_posarg^ < arg {
		count := num_posarg^
		if ap_types^ == nil {
			ap_types^ = transmute([^]cstring)(xcalloc(C.size_t(arg), size_of(cstring)))
		} else {
			ap_types^ = transmute([^]cstring)(xrealloc(rawptr(ap_types^), C.size_t(arg) * size_of(cstring)))
		}
		for count < arg {
			(ap_types^)[count] = nil
			count += 1
		}
		num_posarg^ = arg
	}
	prev := (ap_types^)[arg - 1]
	if prev != nil {
		t := type_in
		prev0 := ([^]u8)(transmute(^u8)(prev))[0]
		t0 := ([^]u8)(transmute(^u8)(t))[0]
		if prev0 == '*' || t0 == '*' {
			pt := t
			pt0 := t0
			if pt0 == '*' {
				pt = prev
				pt0 = prev0
			}
			if pt0 != '*' {
				if pt0 != 'd' && pt0 != 'i' {
					semsg(cstring(E_FIELD_REUSED_S), arg, format_typename_o(prev), format_typename_o(t))
					return 0
				}
			}
		} else {
			if format_typeof_o(t) != format_typeof_o(prev) {
				semsg(cstring(E_TYPE_INCONSISTENT_S), arg, format_typename_o(t), format_typename_o(prev))
				return 0
			}
		}
	}
	(ap_types^)[arg - 1] = type_in
	return 1
}

format_overflow_error_o :: proc "c" (pstart: cstring) {
	context = runtime.default_context()
	p := transmute(^u8)(pstart)
	for ascii_isdigit(([^]u8)(p)[0]) {
		p = transmute(^u8)(rawptr(uintptr(p) + 1))
	}
	semsg(cstring(E_VAL_TOO_LARGE_LEN_S), C.int(uintptr(p) - uintptr(transmute(^u8)(pstart))), pstart)
}

get_unsigned_int_o :: proc "c" (pstart: cstring, p: ^cstring, uj: ^u32, overflow_err: bool) -> C.int {
	context = runtime.default_context()
	pp := transmute(^u8)(p^)
	uj^ = u32(([^]u8)(pp)[0]) - u32('0')
	pp = transmute(^u8)(rawptr(uintptr(pp) + 1))
	for ascii_isdigit(([^]u8)(pp)[0]) && uj^ < MAX_ALLOWED_STRING_WIDTH_O {
		uj^ = 10 * uj^ + (u32(([^]u8)(pp)[0]) - u32('0'))
		pp = transmute(^u8)(rawptr(uintptr(pp) + 1))
	}
	p^ = transmute(cstring)(pp)
	if uj^ > MAX_ALLOWED_STRING_WIDTH_O {
		if overflow_err {
			format_overflow_error_o(pstart)
			return 0
		}
		uj^ = MAX_ALLOWED_STRING_WIDTH_O
	}
	return 1
}

parse_fmt_types_o :: proc "c" (ap_types: ^[^]cstring, num_posarg: ^C.int, fmt_in: cstring, tvs: ^Typval_T) -> C.int {
	context = runtime.default_context()
	p := transmute(^u8)(fmt_in)
	arg: cstring = nil
	any_pos := false
	any_arg := false
	failed := false
	if p == nil {
		return OK_E
	}
	for ([^]u8)(p)[0] != 0 && !failed {
		if ([^]u8)(p)[0] != '%' {
			n := C.size_t(uintptr(xstrchrnul(transmute(^u8)(rawptr(uintptr(p) + 1)), '%')) - uintptr(p))
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(n)))
		} else {
			length_modifier: u8 = 0
			pos_arg: C.int = -1
			pstart := transmute(cstring)(rawptr(uintptr(p) + 1))
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			ptype := transmute(cstring)(p)
			for ascii_isdigit(([^]u8)(transmute(^u8)(ptype))[0]) {
				ptype = transmute(cstring)(rawptr(uintptr(transmute(^u8)(ptype)) + 1))
			}
			if ([^]u8)(transmute(^u8)(ptype))[0] == '$' {
				if ([^]u8)(p)[0] == '0' {
					semsg(cstring(E_INVALID_FORMAT_S), fmt_in)
					failed = true
					break
				}
				uj: u32 = 0
				pcursor := transmute(cstring)(p)
				if get_unsigned_int_o(pstart, &pcursor, &uj, tvs != nil) == 0 {
					failed = true
					break
				}
				p = transmute(^u8)(pcursor)
				pos_arg = C.int(uj)
				any_pos = true
				if any_pos && any_arg {
					semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
					failed = true
					break
				}
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			if failed {
				break
			}
			// parse flags
			for ([^]u8)(p)[0] == '0' || ([^]u8)(p)[0] == '-' || ([^]u8)(p)[0] == '+' || ([^]u8)(p)[0] == ' ' || ([^]u8)(p)[0] == '#' || ([^]u8)(p)[0] == '\'' {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			// parse field width
			if ([^]u8)(p)[0] == '*' {
				arg = transmute(cstring)(p)
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				if ascii_isdigit(([^]u8)(p)[0]) {
					uj: u32 = 0
					acursor := transmute(cstring)(rawptr(uintptr(transmute(^u8)(arg)) + 1))
					pcursor := transmute(cstring)(p)
					_ = acursor
					if get_unsigned_int_o(transmute(cstring)(rawptr(uintptr(transmute(^u8)(arg)) + 1)), &pcursor, &uj, tvs != nil) == 0 {
						failed = true
						break
					}
					p = transmute(^u8)(pcursor)
					if ([^]u8)(p)[0] != '$' {
						semsg(cstring(E_INVALID_FORMAT_S), fmt_in)
						failed = true
						break
					} else {
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
						any_pos = true
						if any_pos && any_arg {
							semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
							failed = true
							break
						}
						if adjust_types_o(ap_types, C.int(uj), num_posarg, arg) == 0 {
							failed = true
							break
						}
					}
				} else {
					any_arg = true
					if any_pos && any_arg {
						semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
						failed = true
						break
					}
				}
			} else if ascii_isdigit(([^]u8)(p)[0]) {
				digstart := transmute(cstring)(p)
				uj: u32 = 0
				pcursor := transmute(cstring)(p)
				if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
					failed = true
					break
				}
				p = transmute(^u8)(pcursor)
				if ([^]u8)(p)[0] == '$' {
					semsg(cstring(E_INVALID_FORMAT_S), fmt_in)
					failed = true
					break
				}
			}
			if failed {
				break
			}
			// parse precision
			if ([^]u8)(p)[0] == '.' {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				if ([^]u8)(p)[0] == '*' {
					arg = transmute(cstring)(p)
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
					if ascii_isdigit(([^]u8)(p)[0]) {
						uj: u32 = 0
						pcursor := transmute(cstring)(p)
						if get_unsigned_int_o(transmute(cstring)(arg), &pcursor, &uj, tvs != nil) == 0 {
							failed = true
							break
						}
						p = transmute(^u8)(pcursor)
						if ([^]u8)(p)[0] == '$' {
							any_pos = true
							if any_pos && any_arg {
								semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
								failed = true
								break
							}
							p = transmute(^u8)(rawptr(uintptr(p) + 1))
							if adjust_types_o(ap_types, C.int(uj), num_posarg, arg) == 0 {
								failed = true
								break
							}
						} else {
							semsg(cstring(E_INVALID_FORMAT_S), fmt_in)
							failed = true
							break
						}
					} else {
						any_arg = true
						if any_pos && any_arg {
							semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
							failed = true
							break
						}
					}
				} else if ascii_isdigit(([^]u8)(p)[0]) {
					digstart := transmute(cstring)(p)
					uj: u32 = 0
					pcursor := transmute(cstring)(p)
					if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
						failed = true
						break
					}
					p = transmute(^u8)(pcursor)
					if ([^]u8)(p)[0] == '$' {
						semsg(cstring(E_INVALID_FORMAT_S), fmt_in)
						failed = true
						break
					}
				}
			}
			if failed {
				break
			}
			if pos_arg != -1 {
				any_pos = true
				if any_pos && any_arg {
					semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
					failed = true
					break
				}
				ptype = transmute(cstring)(p)
			}
			if ([^]u8)(p)[0] == 'h' || ([^]u8)(p)[0] == 'l' || ([^]u8)(p)[0] == 'z' {
				length_modifier = ([^]u8)(p)[0]
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				if length_modifier == 'l' && ([^]u8)(p)[0] == 'l' {
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
			}
			c := ([^]u8)(p)[0]
			known := c == 'i' || c == '*' || c == 'd' || c == 'u' || c == 'o' || c == 'D' || c == 'U' || c == 'O' || c == 'x' || c == 'X' || c == 'b' || c == 'B' || c == 'c' || c == 's' || c == 'S' || c == 'p' || c == 'f' || c == 'F' || c == 'e' || c == 'E' || c == 'g' || c == 'G'
			if known {
				if pos_arg != -1 {
					if adjust_types_o(ap_types, pos_arg, num_posarg, ptype) == 0 {
						failed = true
						break
					}
				} else {
					any_arg = true
					if any_pos && any_arg {
						semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
						failed = true
						break
					}
				}
			} else {
				if pos_arg != -1 {
					semsg(cstring(E_MIX_POSITIONAL_S), fmt_in)
					failed = true
					break
				}
			}
			if ([^]u8)(p)[0] != 0 {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
		}
	}
	if !failed {
		arg_idx: C.int = 0
		for arg_idx < num_posarg^ {
			if (ap_types^)[arg_idx] == nil {
				semsg(cstring(E_FMT_UNUSED_S), arg_idx + 1, fmt_in)
				failed = true
				break
			}
			if tvs != nil && ([^]Typval_T)(tvs)[arg_idx].v_type == VAR_UNKNOWN {
				semsg(cstring(E_OUT_OF_BOUNDS_S), arg_idx + 1, fmt_in)
				failed = true
				break
			}
			arg_idx += 1
		}
	}
	if failed {
		xfree(rawptr(ap_types^))
		ap_types^ = nil
		num_posarg^ = 0
		return FAIL_E
	}
	return OK_E
}

skip_to_arg_o :: proc "c" (ap_types: [^]cstring, ap_start: ^libc.va_list, ap: rawptr, arg_idx: ^C.int, arg_cur: ^C.int, fmt: cstring) {
	context = runtime.default_context()
	arg_min: C.int = 0
	if arg_cur^ + 1 == arg_idx^ {
		arg_cur^ += 1
		arg_idx^ += 1
		return
	}
	if arg_cur^ >= arg_idx^ {
		va_end_e(ap)
		va_copy_e(ap, rawptr(ap_start))
	} else {
		arg_min = arg_cur^
	}
	arg_cur^ = arg_min
	for arg_cur^ < arg_idx^ - 1 {
		if ap_types == nil || ap_types[arg_cur^] == nil {
			siemsg(cstring(E_APTYPES_NULL_S), fmt, arg_cur^)
			return
		}
		p := ap_types[arg_cur^]
		fmt_type := format_typeof_o(p)
		if fmt_type == TYPE_CHAR_O {
			_ = va_arg_ptr_e(ap, TYPE_CHAR_O)
		} else if fmt_type == TYPE_STRING_O {
			_ = va_arg_ptr_e(ap, TYPE_STRING_O)
		} else if fmt_type == TYPE_POINTER_O {
			_ = va_arg_ptr_e(ap, TYPE_POINTER_O)
		} else if fmt_type == TYPE_INT_O || fmt_type == TYPE_LONGINT_O || fmt_type == TYPE_LONGLONGINT_O || fmt_type == TYPE_SIGNEDSIZET_O {
			_ = va_arg_i64_e(ap, fmt_type)
		} else if fmt_type == TYPE_UNSIGNEDINT_O || fmt_type == TYPE_UNSIGNEDLONGINT_O || fmt_type == TYPE_UNSIGNEDLONGLONGINT_O || fmt_type == TYPE_SIZET_O {
			_ = va_arg_u64_e(ap, fmt_type)
		} else if fmt_type == TYPE_FLOAT_O {
			_ = va_arg_f64_e(ap)
		}
		arg_cur^ += 1
	}
	arg_cur^ += 1
	arg_idx^ += 1
}

E_TOOMANY_S :: "E767: Too many arguments to printf()"

foreign _ {
	@(link_name = "log10")
	log10_e :: proc "c" (x: f64) -> f64 ---
}

@(export)
vim_vsnprintf_typval :: proc "c" (str: ^u8, str_m: C.size_t, fmt_arg: cstring, ap_start: ^libc.va_list, tvs: ^Typval_T) -> C.int {
	context = runtime.default_context()
	str_l: C.size_t = 0
	str_avail := str_l < str_m
	p := transmute(^u8)(fmt_arg)
	arg_cur: C.int = 0
	num_posarg: C.int = 0
	arg_idx: C.int = 1
	ap_buf: [24]u8
	ap := rawptr(&ap_buf[0])
	ap_types: [^]cstring = nil
	if parse_fmt_types_o(&ap_types, &num_posarg, fmt_arg, tvs) == FAIL_E {
		return 0
	}
	va_copy_e(ap, rawptr(ap_start))
	if p == nil {
		p = transmute(^u8)(cstring(""))
	}
	failed := false
	for ([^]u8)(p)[0] != 0 && !failed {
		if ([^]u8)(p)[0] != '%' {
			n := C.size_t(uintptr(xstrchrnul(transmute(^u8)(rawptr(uintptr(p) + 1)), '%')) - uintptr(p))
			if str_avail {
				avail := str_m - str_l
				m := n
				if avail < m {
					m = avail
				}
				libc.memmove(rawptr(uintptr(str) + uintptr(str_l)), rawptr(p), m)
				str_avail = n < avail
			}
			p = transmute(^u8)(rawptr(uintptr(p) + uintptr(n)))
			str_l += n
		} else {
			min_field_width: C.size_t = 0
			precision: C.size_t = 0
			zero_padding := false
			precision_specified := false
			justify_left := false
			alternate_form := false
			force_sign := false
			space_for_positive: C.int = 1
			length_modifier: u8 = 0
			tmp: [350]u8
			str_arg: cstring = nil
			str_arg_l: C.size_t = 0
			uchar_arg: u8 = 0
			number_of_zeros_to_pad: C.size_t = 0
			zero_padding_insertion_ind: C.size_t = 0
			fmt_spec: u8 = 0
			tofree: ^u8 = nil
			pos_arg: C.int = -1
			p = transmute(^u8)(rawptr(uintptr(p) + 1))
			ptype := transmute(cstring)(p)
			for ascii_isdigit(([^]u8)(transmute(^u8)(ptype))[0]) {
				ptype = transmute(cstring)(rawptr(uintptr(transmute(^u8)(ptype)) + 1))
			}
			if ([^]u8)(transmute(^u8)(ptype))[0] == '$' {
				digstart := transmute(cstring)(p)
				uj: u32 = 0
				pcursor := transmute(cstring)(p)
				if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
					failed = true
				} else {
					p = transmute(^u8)(pcursor)
					pos_arg = C.int(uj)
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
			}
			if failed {
				break
			}
			for {
				c := ([^]u8)(p)[0]
				if c == '0' {
					zero_padding = true
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else if c == '-' {
					justify_left = true
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else if c == '+' {
					force_sign = true
					space_for_positive = 0
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else if c == ' ' {
					force_sign = true
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else if c == '#' {
					alternate_form = true
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else if c == '\'' {
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				} else {
					break
				}
			}
			if ([^]u8)(p)[0] == '*' {
				digstart := transmute(cstring)(rawptr(uintptr(p) + 1))
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				if ascii_isdigit(([^]u8)(p)[0]) {
					uj: u32 = 0
					pcursor := transmute(cstring)(p)
					if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
						failed = true
					} else {
						p = transmute(^u8)(pcursor)
						arg_idx = C.int(uj)
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					}
				}
				if failed {
					break
				}
				j: C.int = 0
				if tvs != nil {
					j = C.int(tv_nr_o(tvs, &arg_idx))
				} else {
					skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
					j = C.int(va_arg_i64_e(ap, TYPE_INT_O))
				}
				if j > MAX_ALLOWED_STRING_WIDTH_O {
					if tvs != nil {
						format_overflow_error_o(digstart)
						failed = true
						break
					} else {
						j = MAX_ALLOWED_STRING_WIDTH_O
					}
				}
				if j >= 0 {
					min_field_width = C.size_t(j)
				} else {
					min_field_width = C.size_t(-j)
					justify_left = true
				}
			} else if ascii_isdigit(([^]u8)(p)[0]) {
				digstart := transmute(cstring)(p)
				uj: u32 = 0
				pcursor := transmute(cstring)(p)
				if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
					failed = true
					break
				}
				p = transmute(^u8)(pcursor)
				min_field_width = C.size_t(uj)
			}
			if failed {
				break
			}
			if ([^]u8)(p)[0] == '.' {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				precision_specified = true
				if ascii_isdigit(([^]u8)(p)[0]) {
					digstart := transmute(cstring)(p)
					uj: u32 = 0
					pcursor := transmute(cstring)(p)
					if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
						failed = true
						break
					}
					p = transmute(^u8)(pcursor)
					precision = C.size_t(uj)
				} else if ([^]u8)(p)[0] == '*' {
					digstart := transmute(cstring)(p)
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
					if ascii_isdigit(([^]u8)(p)[0]) {
						uj: u32 = 0
						pcursor := transmute(cstring)(p)
						if get_unsigned_int_o(digstart, &pcursor, &uj, tvs != nil) == 0 {
							failed = true
							break
						}
						p = transmute(^u8)(pcursor)
						arg_idx = C.int(uj)
						p = transmute(^u8)(rawptr(uintptr(p) + 1))
					}
					j: C.int = 0
					if tvs != nil {
						j = C.int(tv_nr_o(tvs, &arg_idx))
					} else {
						skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
						j = C.int(va_arg_i64_e(ap, TYPE_INT_O))
					}
					if j > MAX_ALLOWED_STRING_WIDTH_O {
						if tvs != nil {
							format_overflow_error_o(digstart)
							failed = true
							break
						} else {
							j = MAX_ALLOWED_STRING_WIDTH_O
						}
					}
					if j >= 0 {
						precision = C.size_t(j)
					} else {
						precision_specified = false
						precision = 0
					}
				}
			}
			if failed {
				break
			}
			if ([^]u8)(p)[0] == 'h' || ([^]u8)(p)[0] == 'l' || ([^]u8)(p)[0] == 'z' {
				length_modifier = ([^]u8)(p)[0]
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
				if length_modifier == 'l' && ([^]u8)(p)[0] == 'l' {
					length_modifier = 'L'
					p = transmute(^u8)(rawptr(uintptr(p) + 1))
				}
			}
			fmt_spec = ([^]u8)(p)[0]
			if fmt_spec == 'i' {
				fmt_spec = 'd'
			} else if fmt_spec == 'D' {
				fmt_spec = 'd'
				length_modifier = 'l'
			} else if fmt_spec == 'U' {
				fmt_spec = 'u'
				length_modifier = 'l'
			} else if fmt_spec == 'O' {
				fmt_spec = 'o'
				length_modifier = 'l'
			}
			if fmt_spec == 'd' || fmt_spec == 'u' || fmt_spec == 'o' || fmt_spec == 'x' || fmt_spec == 'X' {
				if tvs != nil && length_modifier == 0 {
					length_modifier = 'L'
				}
			}
			if pos_arg != -1 {
				arg_idx = pos_arg
			}
			if fmt_spec == '%' || fmt_spec == 'c' || fmt_spec == 's' || fmt_spec == 'S' {
				str_arg_l = 1
				if fmt_spec == '%' {
					str_arg = transmute(cstring)(p)
				} else if fmt_spec == 'c' {
					j := C.int(0)
					if tvs != nil {
						j = C.int(tv_nr_o(tvs, &arg_idx))
					} else {
						skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
						j = C.int(va_arg_i64_e(ap, TYPE_INT_O))
					}
					uchar_arg = u8(j)
					str_arg = transmute(cstring)(&uchar_arg)
				} else {
					tofree_ptr: rawptr = nil
					if tvs != nil {
						str_arg = tv_str_o(tvs, &arg_idx, &tofree_ptr)
					} else {
						skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
						str_arg = transmute(cstring)(va_arg_ptr_e(ap, TYPE_STRING_O))
					}
					tofree = transmute(^u8)(tofree_ptr)
					if str_arg == nil {
						str_arg = cstring("[NULL]")
						str_arg_l = 6
					} else if !precision_specified {
						str_arg_l = libc.strlen(str_arg)
					} else if precision == 0 {
						str_arg_l = 0
					} else {
						m := precision
						if m > 0x7fffffff {
							m = 0x7fffffff
						}
						str_arg_l = C.size_t(uintptr(xmemscan(rawptr(transmute(^u8)(str_arg)), 0, m)) - uintptr(transmute(^u8)(str_arg)))
					}
					if fmt_spec == 'S' {
						i: C.size_t = 0
						p1 := transmute(^u8)(str_arg)
						for ([^]u8)(p1)[0] != 0 {
							cell := C.size_t(utf_ptr2cells_r(transmute(cstring)(p1)))
							if precision_specified && i + cell > precision {
								break
							}
							i += cell
							p1 = transmute(^u8)(rawptr(uintptr(p1) + uintptr(utfc_ptr2len(transmute(cstring)(p1)))))
						}
						str_arg_l = C.size_t(uintptr(p1) - uintptr(transmute(^u8)(str_arg)))
						if min_field_width != 0 {
							min_field_width += str_arg_l - i
						}
					}
				}
			} else if fmt_spec == 'd' || fmt_spec == 'u' || fmt_spec == 'b' || fmt_spec == 'B' || fmt_spec == 'o' || fmt_spec == 'x' || fmt_spec == 'X' || fmt_spec == 'p' {
				arg_sign: C.int = 0
				arg: i64 = 0
				uarg: u64 = 0
				ptr_arg: rawptr = nil
				if fmt_spec == 'p' {
					if tvs != nil {
						ptr_arg = tv_ptr_o(tvs, &arg_idx)
					} else {
						skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
						ptr_arg = va_arg_ptr_e(ap, TYPE_POINTER_O)
					}
					if ptr_arg != nil {
						arg_sign = 1
					}
				} else if fmt_spec == 'b' || fmt_spec == 'B' {
					if tvs != nil {
						uarg = u64(tv_nr_o(tvs, &arg_idx))
					} else {
						skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
						uarg = va_arg_u64_e(ap, TYPE_UNSIGNEDLONGLONGINT_O)
					}
					if uarg != 0 {
						arg_sign = 1
					}
				} else if fmt_spec == 'd' {
					if length_modifier == 0 {
						if tvs != nil {
							arg = i64(C.int(tv_nr_o(tvs, &arg_idx)))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							arg = i64(C.int(va_arg_i64_e(ap, TYPE_INT_O)))
						}
					} else if length_modifier == 'h' {
						if tvs != nil {
							arg = i64(i16(C.int(tv_nr_o(tvs, &arg_idx))))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							arg = i64(i16(C.int(va_arg_i64_e(ap, TYPE_INT_O))))
						}
					} else {
						t: C.int = TYPE_LONGINT_O
						if length_modifier == 'L' {
							t = TYPE_LONGLONGINT_O
						} else if length_modifier == 'z' {
							t = TYPE_SIGNEDSIZET_O
						}
						if tvs != nil {
							arg = i64(tv_nr_o(tvs, &arg_idx))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							arg = i64(va_arg_i64_e(ap, t))
						}
					}
					if arg > 0 {
						arg_sign = 1
					} else if arg < 0 {
						arg_sign = -1
					}
				} else {
					if length_modifier == 0 {
						if tvs != nil {
							uarg = u64(u32(tv_nr_o(tvs, &arg_idx)))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							uarg = u64(u32(va_arg_u64_e(ap, TYPE_UNSIGNEDINT_O)))
						}
					} else if length_modifier == 'h' {
						if tvs != nil {
							uarg = u64(u16(u32(tv_nr_o(tvs, &arg_idx))))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							uarg = u64(u16(u32(va_arg_u64_e(ap, TYPE_UNSIGNEDINT_O))))
						}
					} else {
						t: C.int = TYPE_UNSIGNEDLONGINT_O
						if length_modifier == 'L' {
							t = TYPE_UNSIGNEDLONGLONGINT_O
						} else if length_modifier == 'z' {
							t = TYPE_SIZET_O
						}
						if tvs != nil {
							uarg = u64(tv_nr_o(tvs, &arg_idx))
						} else {
							skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
							uarg = va_arg_u64_e(ap, t)
						}
					}
					if uarg != 0 {
						arg_sign = 1
					}
				}
				str_arg = transmute(cstring)(&tmp[0])
				str_arg_l = 0
				if precision_specified {
					zero_padding = false
				}
				if fmt_spec == 'd' {
					if force_sign && arg_sign >= 0 {
						if space_for_positive != 0 {
							([^]u8)(&tmp[0])[str_arg_l] = ' '
						} else {
							([^]u8)(&tmp[0])[str_arg_l] = '+'
						}
						str_arg_l += 1
					}
				} else if alternate_form {
					if arg_sign != 0 && (fmt_spec == 'x' || fmt_spec == 'X' || fmt_spec == 'b' || fmt_spec == 'B') {
						([^]u8)(&tmp[0])[str_arg_l] = '0'
						([^]u8)(&tmp[0])[str_arg_l + 1] = fmt_spec
						str_arg_l += 2
					}
				}
				zero_padding_insertion_ind = str_arg_l
				if !precision_specified {
					precision = 1
				}
				if precision != 0 || arg_sign != 0 {
					if fmt_spec == 'p' {
						added := libc.snprintf(transmute(^u8)(rawptr(uintptr(&tmp[0]) + uintptr(str_arg_l))), C.size_t(350) - str_arg_l, cstring("%p"), ptr_arg)
						if added > 0 {
							str_arg_l += C.size_t(added)
						}
					} else if fmt_spec == 'd' {
						added := libc.snprintf(transmute(^u8)(rawptr(uintptr(&tmp[0]) + uintptr(str_arg_l))), C.size_t(350) - str_arg_l, cstring("%lld"), C.longlong(arg))
						if added > 0 {
							str_arg_l += C.size_t(added)
						}
					} else if fmt_spec == 'b' || fmt_spec == 'B' {
						bits: C.size_t = 64
						for bits > 0 {
							if (uarg >> (bits - 1)) & 1 != 0 {
								break
							}
							bits -= 1
						}
						for bits > 0 {
							bits -= 1
							if (uarg >> bits) & 1 != 0 {
								([^]u8)(&tmp[0])[str_arg_l] = '1'
							} else {
								([^]u8)(&tmp[0])[str_arg_l] = '0'
							}
							str_arg_l += 1
						}
					} else {
						f: [4]u8
						f[0] = '%'
						f[1] = 'l'
						f[2] = fmt_spec
						f[3] = 0
						added := libc.snprintf(transmute(^u8)(rawptr(uintptr(&tmp[0]) + uintptr(str_arg_l))), C.size_t(350) - str_arg_l, transmute(cstring)(&f[0]), C.ulonglong(uarg))
						if added > 0 {
							str_arg_l += C.size_t(added)
						}
					}
					if zero_padding_insertion_ind < str_arg_l && ([^]u8)(&tmp[0])[zero_padding_insertion_ind] == '-' {
						zero_padding_insertion_ind += 1
					}
					if zero_padding_insertion_ind + 1 < str_arg_l && ([^]u8)(&tmp[0])[zero_padding_insertion_ind] == '0' {
						nc := ([^]u8)(&tmp[0])[zero_padding_insertion_ind + 1]
						if nc == 'x' || nc == 'X' || nc == 'b' || nc == 'B' {
							zero_padding_insertion_ind += 2
						}
					}
				}
				num_of_digits := str_arg_l - zero_padding_insertion_ind
				if alternate_form && fmt_spec == 'o' && !(zero_padding_insertion_ind < str_arg_l && ([^]u8)(&tmp[0])[zero_padding_insertion_ind] == '0') {
					if !precision_specified || precision < num_of_digits + 1 {
						precision = num_of_digits + 1
					}
				}
				if num_of_digits < precision {
					number_of_zeros_to_pad = precision - num_of_digits
				}
				if !justify_left && zero_padding {
					if min_field_width > str_arg_l + number_of_zeros_to_pad {
						number_of_zeros_to_pad += min_field_width - (str_arg_l + number_of_zeros_to_pad)
					}
				}
			} else if fmt_spec == 'f' || fmt_spec == 'F' || fmt_spec == 'e' || fmt_spec == 'E' || fmt_spec == 'g' || fmt_spec == 'G' {
				format: [40]u8
				remove_trailing_zeroes := false
				f: f64 = 0
				if tvs != nil {
					f = tv_float_o(tvs, &arg_idx)
				} else {
					skip_to_arg_o(ap_types, ap_start, ap, &arg_idx, &arg_cur, fmt_arg)
					f = va_arg_f64_e(ap)
				}
				abs_f := f
				if abs_f < 0 {
					abs_f = -abs_f
				}
				if fmt_spec == 'g' || fmt_spec == 'G' {
					if (abs_f >= 0.001 && abs_f < 10000000.0) || abs_f == 0.0 {
						if fmt_spec == 'g' {
							fmt_spec = 'f'
						} else {
							fmt_spec = 'F'
						}
					} else {
						if fmt_spec == 'g' {
							fmt_spec = 'e'
						} else {
							fmt_spec = 'E'
						}
					}
					remove_trailing_zeroes = true
				}
				if xisinf(f) != 0 || ((fmt_spec == 'f' || fmt_spec == 'F') && abs_f > 1.0e307) {
					fs: C.int = 0
					if force_sign {
						fs = 1
					}
					xstrlcpy(transmute(cstring)(&tmp[0]), infinity_str_o(f > 0.0, fmt_spec, fs, space_for_positive), 350)
					str_arg_l = libc.strlen(transmute(cstring)(&tmp[0]))
					zero_padding = false
				} else if xisnan(f) != 0 {
					if fmt_spec >= 'A' && fmt_spec <= 'Z' {
						([^]u8)(&tmp[0])[0] = 'N'
						([^]u8)(&tmp[0])[1] = 'A'
						([^]u8)(&tmp[0])[2] = 'N'
					} else {
						([^]u8)(&tmp[0])[0] = 'n'
						([^]u8)(&tmp[0])[1] = 'a'
						([^]u8)(&tmp[0])[2] = 'n'
					}
					([^]u8)(&tmp[0])[3] = 0
					str_arg_l = 3
					zero_padding = false
				} else {
					format[0] = '%'
					l: C.size_t = 1
					if force_sign {
						if space_for_positive != 0 {
							format[l] = ' '
						} else {
							format[l] = '+'
						}
						l += 1
					}
					if precision_specified {
						max_prec: C.size_t = 340
						if (fmt_spec == 'f' || fmt_spec == 'F') && abs_f > 1.0 {
							max_prec -= C.size_t(log10_e(abs_f))
						}
						if precision > max_prec {
							precision = max_prec
						}
						l += C.size_t(libc.snprintf(transmute(^u8)(rawptr(uintptr(&format[0]) + uintptr(l))), C.size_t(40) - l, cstring(".%d"), C.int(precision)))
					}
					if fmt_spec == 'F' {
						format[l] = 'f'
					} else {
						format[l] = fmt_spec
					}
					format[l + 1] = 0
					added := libc.snprintf(transmute(^u8)(&tmp[0]), 350, transmute(cstring)(&format[0]), f)
					if added > 0 {
						str_arg_l = C.size_t(added)
					}
					if remove_trailing_zeroes {
						tp: ^u8 = nil
						if fmt_spec == 'f' || fmt_spec == 'F' {
							tp = transmute(^u8)(rawptr(uintptr(&tmp[0]) + uintptr(str_arg_l) - 1))
						} else {
							ec: u8 = 'e'
							if fmt_spec == 'E' {
								ec = 'E'
							}
							tp = transmute(^u8)(vim_strchr(transmute(cstring)(&tmp[0]), C.int(ec)))
							if tp != nil {
								if ([^]u8)(tp)[1] == '+' {
									tplen := libc.strlen(transmute(cstring)(rawptr(uintptr(tp) + 1)))
									libc.memmove(rawptr(uintptr(tp) + 1), rawptr(uintptr(tp) + 2), tplen)
									str_arg_l -= 1
								}
								i := 1
								if ([^]u8)(tp)[1] == '-' {
									i = 2
								}
								for ([^]u8)(tp)[i] == '0' {
									tplen := libc.strlen(transmute(cstring)(rawptr(uintptr(tp) + uintptr(i) + 1)))
									libc.memmove(rawptr(uintptr(tp) + uintptr(i)), rawptr(uintptr(tp) + uintptr(i) + 1), tplen + 1)
									str_arg_l -= 1
								}
								tp = transmute(^u8)(rawptr(uintptr(tp) - 1))
							}
						}
						if tp != nil && !precision_specified {
							for tp > transmute(^u8)(rawptr(uintptr(&tmp[0]) + 2)) && ([^]u8)(tp)[0] == '0' && ([^]u8)(rawptr(uintptr(tp) - 1))[0] != '.' {
								tplen := libc.strlen(transmute(cstring)(rawptr(uintptr(tp) + 1)))
								libc.memmove(rawptr(tp), rawptr(uintptr(tp) + 1), tplen + 1)
								tp = transmute(^u8)(rawptr(uintptr(tp) - 1))
								str_arg_l -= 1
							}
						}
					} else {
						ec: u8 = 'e'
						if fmt_spec == 'E' {
							ec = 'E'
						}
						tp := transmute(^u8)(vim_strchr(transmute(cstring)(&tmp[0]), C.int(ec)))
						if tp != nil && (([^]u8)(tp)[1] == '+' || ([^]u8)(tp)[1] == '-') && ([^]u8)(tp)[2] == '0' && ascii_isdigit(([^]u8)(tp)[3]) && ascii_isdigit(([^]u8)(tp)[4]) {
							tplen := libc.strlen(transmute(cstring)(rawptr(uintptr(tp) + 3)))
							libc.memmove(rawptr(uintptr(tp) + 2), rawptr(uintptr(tp) + 3), tplen + 1)
							str_arg_l -= 1
						}
					}
				}
				if zero_padding && min_field_width > str_arg_l && (([^]u8)(&tmp[0])[0] == '-' || force_sign) {
					number_of_zeros_to_pad = min_field_width - str_arg_l
					zero_padding_insertion_ind = 1
				}
				str_arg = transmute(cstring)(&tmp[0])
			} else {
				zero_padding = false
				justify_left = true
				min_field_width = 0
				str_arg = transmute(cstring)(p)
				str_arg_l = 0
				if ([^]u8)(p)[0] != 0 {
					str_arg_l = 1
				}
			}
			if ([^]u8)(p)[0] != 0 {
				p = transmute(^u8)(rawptr(uintptr(p) + 1))
			}
			if !justify_left {
				if min_field_width > str_arg_l + number_of_zeros_to_pad {
					pn := min_field_width - (str_arg_l + number_of_zeros_to_pad)
					if str_avail {
						avail := str_m - str_l
						m := pn
						if avail < m {
							m = avail
						}
						for i: C.size_t = 0; i < m; i += 1 {
							if zero_padding {
								([^]u8)(str)[str_l + i] = '0'
							} else {
								([^]u8)(str)[str_l + i] = ' '
							}
						}
						str_avail = pn < avail
					}
					str_l += pn
				}
			}
			if number_of_zeros_to_pad == 0 {
				zero_padding_insertion_ind = 0
			} else {
				if zero_padding_insertion_ind > 0 {
					zn := zero_padding_insertion_ind
					if str_avail {
						avail := str_m - str_l
						m := zn
						if avail < m {
							m = avail
						}
						libc.memmove(rawptr(uintptr(str) + uintptr(str_l)), rawptr(transmute(^u8)(str_arg)), m)
						str_avail = zn < avail
					}
					str_l += zn
				}
				zn := number_of_zeros_to_pad
				if str_avail {
					avail := str_m - str_l
					m := zn
					if avail < m {
						m = avail
					}
					for i: C.size_t = 0; i < m; i += 1 {
						([^]u8)(str)[str_l + i] = '0'
					}
					str_avail = zn < avail
				}
				str_l += zn
			}
			if str_arg_l > zero_padding_insertion_ind {
				sn := str_arg_l - zero_padding_insertion_ind
				if str_avail {
					avail := str_m - str_l
					m := sn
					if avail < m {
						m = avail
					}
					libc.memmove(rawptr(uintptr(str) + uintptr(str_l)), rawptr(uintptr(transmute(^u8)(str_arg)) + uintptr(zero_padding_insertion_ind)), m)
					str_avail = sn < avail
				}
				str_l += sn
			}
			if justify_left {
				if min_field_width > str_arg_l + number_of_zeros_to_pad {
					pn := min_field_width - (str_arg_l + number_of_zeros_to_pad)
					if str_avail {
						avail := str_m - str_l
						m := pn
						if avail < m {
							m = avail
						}
						for i: C.size_t = 0; i < m; i += 1 {
							([^]u8)(str)[str_l + i] = ' '
						}
						str_avail = pn < avail
					}
					str_l += pn
				}
			}
			xfree(rawptr(tofree))
		}
	}
	if !failed {
		if str_m > 0 {
			idx := str_l
			if str_l > str_m - 1 {
				idx = str_m - 1
			}
			([^]u8)(str)[idx] = 0
		}
		if tvs != nil {
			check_idx := arg_idx - 1
			if num_posarg != 0 {
				check_idx = num_posarg
			}
			if ([^]Typval_T)(tvs)[check_idx].v_type != VAR_UNKNOWN {
				emsg(cstring(E_TOOMANY_S))
			}
		}
	}
	xfree(rawptr(ap_types))
	va_end_e(ap)
	return C.int(str_l)
}

@(export)
vim_vsnprintf :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	return vim_vsnprintf_typval(str, str_m, fmt, ap, nil)
}

@(export)
vim_snprintf_safelen_v :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: ^libc.va_list) -> C.size_t {
	context = runtime.default_context()
	if str_m == 0 {
		return 0
	}
	str_l := vim_vsnprintf_typval(str, str_m, fmt, ap, nil)
	if str_l < 0 {
		([^]u8)(str)[0] = 0
		return 0
	}
	if C.size_t(str_l) >= str_m {
		return str_m - 1
	}
	return C.size_t(str_l)
}

@(export)
vim_snprintf_v :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	return vim_vsnprintf(str, str_m, fmt, ap)
}

@(export)
vim_snprintf_add_v :: proc "c" (str: ^u8, str_m: C.size_t, fmt: cstring, ap: ^libc.va_list) -> C.int {
	context = runtime.default_context()
	length := libc.strlen(transmute(cstring)(str))
	space: C.size_t = 0
	if str_m > length {
		space = str_m - length
	}
	return vim_vsnprintf(transmute(^u8)(rawptr(uintptr(str) + uintptr(length))), space, fmt, ap)
}
