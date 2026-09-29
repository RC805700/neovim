package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/posix"

// charset.c port (Batch C1): pure string/char leaves, zero Neovim deps.
// ascii_iswhite/isdigit + skipwhite MOVED from os_lang.odin (same names/sigs,
// all callers auto-rebind); C file keeps the g_chartab static + init fns
// (Batch C2). BACKSLASH_IN_FILENAME is win_defs.h-only: Linux takes the
// #else arm everywhere below.

foreign _ {
	@(link_name = "strtoimax")
	strtoimax_c :: proc "c" (s: cstring, endp: ^^u8, base: C.int) -> C.long ---
}

// Moved from os_lang.odin (was package-visible there; single copy here).
ascii_isdigit :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return c >= '0' && c <= '9'
}

// Moved from os_lang.odin (was package-visible there; single copy here).
ascii_iswhite :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	// C ascii_iswhite (ascii_defs.h:84): space/tab ONLY. Do NOT widen:
	// skipwhite must stop at \n (ex_function line_arg detection depends
	// on it; Batch 24ac proved the wide version hangs defines).
	return c == ' ' || c == '\t'
}

ascii_isbdigit :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return c == '0' || c == '1'
}

ascii_isxdigit :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// Moved from os_lang.odin (was package-visible there; single copy here).
// Now @(export): C callers link here once weak-marked.
@(export)
skipwhite :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for cur != nil && ([^]u8)(cur)[0] != 0 && ascii_iswhite(([^]u8)(cur)[0]) {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return cur
}

// Length-bounded skipwhite (charset.c public).
@(export)
skipwhite_len :: proc "c" (p: cstring, len: C.size_t) -> cstring {
	context = runtime.default_context()
	cur := p
	n := len
	for n > 0 && ascii_iswhite(([^]u8)(cur)[0]) {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
		n -= 1
	}
	return cur
}

// Digit skipper (charset.c public).
@(export)
skipdigits :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for ascii_isdigit(([^]u8)(cur)[0]) {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return cur
}

// Binary-digit skipper (charset.c public).
@(export)
skipbin :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for ascii_isbdigit(([^]u8)(cur)[0]) {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return cur
}

// Hex-digit skipper (charset.c public).
@(export)
skiphex :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	for ascii_isxdigit(([^]u8)(cur)[0]) {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
	}
	return cur
}

// Seek to next digit or NUL (charset.c public).
@(export)
skiptodigit :: proc "c" (q: ^u8) -> ^u8 {
	context = runtime.default_context()
	p := q
	for ([^]u8)(p)[0] != 0 && !ascii_isdigit(([^]u8)(p)[0]) {
		p = (^u8)(uintptr(p) + 1)
	}
	return p
}

// Seek to next binary digit or NUL (charset.c public).
@(export)
skiptobin :: proc "c" (q: ^u8) -> ^u8 {
	context = runtime.default_context()
	p := q
	for ([^]u8)(p)[0] != 0 && !ascii_isbdigit(([^]u8)(p)[0]) {
		p = (^u8)(uintptr(p) + 1)
	}
	return p
}

// Seek to next hex digit or NUL (charset.c public).
@(export)
skiptohex :: proc "c" (q: ^u8) -> ^u8 {
	context = runtime.default_context()
	p := q
	for ([^]u8)(p)[0] != 0 && !ascii_isxdigit(([^]u8)(p)[0]) {
		p = (^u8)(uintptr(p) + 1)
	}
	return p
}

// Seek to space/tab/NUL (charset.c public).
@(export)
skiptowhite :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	c := ([^]u8)(cur)[0]
	for c != ' ' && c != '\t' && c != 0 {
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
		c = ([^]u8)(cur)[0]
	}
	return cur
}

// Seek to whitespace, skipping escaped chars (charset.c public).
@(export)
skiptowhite_esc :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	cur := p
	c := ([^]u8)(cur)[0]
	for c != ' ' && c != '\t' && c != 0 {
		if (c == '\\' || c == Ctrl_V) && ([^]u8)(cur)[1] != 0 {
			cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
		}
		cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
		c = ([^]u8)(cur)[0]
	}
	return cur
}

// Seek to newline or NUL (charset.c public).
@(export)
skip_to_newline :: proc "c" (p: cstring) -> cstring {
	context = runtime.default_context()
	return transmute(cstring)(xstrchrnul(transmute(^u8)(p), 10))
}

// Overflow-signalling number parser (charset.c public).
@(export)
try_getdigits :: proc "c" (pp: ^^u8, nr: ^i64) -> bool {
	context = runtime.default_context()
	posix.set_errno(.NONE)
	n := strtoimax_c(transmute(cstring)(pp^), pp, 10)
	if posix.errno() == .ERANGE && (n == min(C.long) || n == max(C.long)) {
		return false
	}
	nr^ = i64(n)
	return true
}

// Number parser with default (charset.c public).
@(export)
getdigits :: proc "c" (pp: ^cstring, strict: bool, def: C.long) -> C.long {
	context = runtime.default_context()
	number: C.long
	// try_getdigits takes ^^u8; ^cstring and ^^u8 are both 8-byte pointers.
	ok := try_getdigits(transmute(^^u8)(pp), transmute(^i64)(&number))
	if strict && !ok {
		libc.abort()
	}
	if ok {
		return number
	}
	return def
}

// Int number parser (charset.c public; LP64: intmax_t > int, guard live).
@(export)
getdigits_int :: proc "c" (pp: ^^u8, strict: bool, def: C.int) -> C.int {
	context = runtime.default_context()
	p2 := transmute(^cstring)(pp)
	number := getdigits(p2, strict, C.long(def))
	pp^ = transmute(^u8)(p2^)
	when size_of(C.long) > size_of(C.int) {
		if strict {
			if number < C.long(min(C.int)) || number > C.long(max(C.int)) {
				libc.abort()
			}
		} else if number < C.long(min(C.int)) || number > C.long(max(C.int)) {
			return def
		}
	}
	return C.int(number)
}

// Long number parser (charset.c public; LP64: intmax_t == long, guard out).
@(export)
getdigits_long :: proc "c" (pp: ^^u8, strict: bool, def: C.long) -> C.long {
	context = runtime.default_context()
	p2 := transmute(^cstring)(pp)
	number := getdigits(p2, strict, def)
	pp^ = transmute(^u8)(p2^)
	when size_of(C.long) > size_of(C.long) {
		if strict {
			if number < min(C.long) || number > max(C.long) {
				libc.abort()
			}
		} else if number < min(C.long) || number > max(C.long) {
			return def
		}
	}
	return number
}

// Int32 number parser (charset.c public; guard live).
@(export)
getdigits_int32 :: proc "c" (pp: ^^u8, strict: bool, def: C.int) -> C.int {
	context = runtime.default_context()
	p2 := transmute(^cstring)(pp)
	number := getdigits(p2, strict, C.long(def))
	pp^ = transmute(^u8)(p2^)
	when size_of(C.long) > 4 {
		if strict {
			if number < C.long(min(i32)) || number > C.long(max(i32)) {
				libc.abort()
			}
		} else if number < C.long(min(i32)) || number > C.long(max(i32)) {
			return def
		}
	}
	return C.int(number)
}

// Single hex digit value (charset.c public).
@(export)
hex2nr :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	if c >= 'a' && c <= 'f' {
		return c - 'a' + 10
	}
	if c >= 'A' && c <= 'F' {
		return c - 'A' + 10
	}
	return c - '0'
}

// Two hex chars to byte, -1 unless both hex (charset.c public).
@(export)
hexhex2nr :: proc "c" (p: cstring) -> C.int {
	context = runtime.default_context()
	b := ([^]u8)(p)
	if !ascii_isxdigit(b[0]) || !ascii_isxdigit(b[1]) {
		return -1
	}
	return (hex2nr(C.int(b[0])) << 4) + hex2nr(C.int(b[1]))
}

// Low-4-bits to hex char (C-static-inline; plain proc).
nr2hex_o :: proc "c" (n: C.uint) -> C.uint {
	context = runtime.default_context()
	if (n & 0xf) <= 9 {
		return (n & 0xf) + '0'
	}
	return (n & 0xf) - 10 + 'a'
}

// Backslash-removal test, Linux arm (charset.c public).
@(export)
rem_backslash :: proc "c" (str: cstring) -> bool {
	context = runtime.default_context()
	b := ([^]u8)(str)
	return b[0] == '\\' && b[1] != 0
}

// Halve backslashes in place (charset.c public; goto restructured).
@(export)
backslash_halve :: proc "c" (p: ^u8) {
	context = runtime.default_context()
	cur := p
	for ([^]u8)(cur)[0] != 0 && !rem_backslash(transmute(cstring)(cur)) {
		cur = (^u8)(uintptr(rawptr(cur)) + 1)
	}
	if ([^]u8)(cur)[0] != 0 {
		dst := cur
		// First copy unconditional (C jumps into the loop via `start:`).
		([^]u8)(dst)[0] = ([^]u8)(cur)[1]
		cur = (^u8)(uintptr(rawptr(cur)) + 2)
		dst = (^u8)(uintptr(dst) + 1)
		for ([^]u8)(cur)[0] != 0 {
			if rem_backslash(transmute(cstring)(cur)) {
				([^]u8)(dst)[0] = ([^]u8)(cur)[1]
				cur = (^u8)(uintptr(rawptr(cur)) + 2)
				dst = (^u8)(uintptr(dst) + 1)
			} else {
				([^]u8)(dst)[0] = ([^]u8)(cur)[0]
				cur = (^u8)(uintptr(rawptr(cur)) + 1)
				dst = (^u8)(uintptr(dst) + 1)
			}
		}
		([^]u8)(dst)[0] = 0
	}
}

// Halve backslashes into fresh allocation (charset.c public).
@(export)
backslash_halve_save :: proc "c" (p: cstring) -> ^u8 {
	context = runtime.default_context()
	raw := xmalloc(C.size_t(libc.strlen(p)) + 1)
	res := transmute([^]u8)(raw)
	dst := res
	cur := p
	for ([^]u8)(cur)[0] != 0 {
		if rem_backslash(cur) {
			dst[0] = ([^]u8)(cur)[1]
			cur = transmute(cstring)(uintptr(rawptr(cur)) + 2)
			dst = ([^]u8)(uintptr(dst) + 1)
		} else {
			dst[0] = ([^]u8)(cur)[0]
			cur = transmute(cstring)(uintptr(rawptr(cur)) + 1)
			dst = ([^]u8)(uintptr(dst) + 1)
		}
	}
	dst[0] = 0
	return transmute(^u8)(raw)
}

// ASCII mirror for right-to-left (charset.c public).
@(export)
rl_mirror_ascii :: proc "c" (str: ^u8, end: ^u8) {
	context = runtime.default_context()
	p1 := str
	p2: ^u8
	if end != nil {
		p2 = (^u8)(uintptr(end) - 1)
	} else {
		p2 = (^u8)(uintptr(str) + uintptr(libc.strlen(transmute(cstring)(str))) - 1)
	}
	for uintptr(p1) < uintptr(p2) {
		t := ([^]u8)(p1)[0]
		([^]u8)(p1)[0] = ([^]u8)(p2)[0]
		([^]u8)(p2)[0] = t
		p1 = (^u8)(uintptr(p1) + 1)
		p2 = (^u8)(uintptr(p2) - 1)
	}
}

// —— Batch C2: g_chartab move + init + classification + cells ——

// File-statics moved from charset.c (extern-pattern: C uses `extern`, single copy here).
@(export)
g_chartab: [256]u8
@(export)
chartab_initialized: bool
@(export)
transchar_charbuf: [11]u8

CT_CELL_MASK_O :: 0x07
CT_PRINT_CHAR_O :: 0x10
CT_ID_CHAR_O :: 0x20
CT_FNAME_CHAR_O :: 0x40

B_CHARTAB_OFF :: 5592

foreign _ {
	@(link_name = "p_isi")
	p_isi_g: ^u8
	@(link_name = "p_isp")
	p_isp_g: ^u8
	@(link_name = "p_isf")
	p_isf_g: ^u8
	@(link_name = "utf_class_tab")
	utf_class_tab_e :: proc "c" (c: C.int, chartab: rawptr) -> C.int ---
	@(link_name = "utf_char2cells")
	utf_char2cells_e :: proc "c" (c: C.int) -> C.int ---
}

// Fill g_chartab + current buffer chartab (charset.c public).
@(export)
init_chartab :: proc "c" () -> C.int {
	context = runtime.default_context()
	if buf_init_chartab(curbuf, true) {
		return OK_E
	}
	return FAIL_E
}

// Fill buffer chartab, globally optionally (charset.c public).
@(export)
buf_init_chartab :: proc "c" (buf: rawptr, global: bool) -> bool {
	context = runtime.default_context()
	if global {
		c: C.int = 0
		for c < ' ' {
			if (dy_flags_g & K_OPT_DY_UHEX_O) != 0 {
				g_chartab[c] = 4
			} else {
				g_chartab[c] = 2
			}
			c += 1
		}
		for c <= '~' {
			g_chartab[c] = 1 + CT_PRINT_CHAR_O
			c += 1
		}
		for c < 256 {
			if c >= 0xa0 {
				g_chartab[c] = (CT_PRINT_CHAR_O | CT_FNAME_CHAR_O) + 1
			} else {
				if (dy_flags_g & K_OPT_DY_UHEX_O) != 0 {
					g_chartab[c] = 4
				} else {
					g_chartab[c] = 2
				}
			}
			c += 1
		}
	}
	libc.memset(rawptr(uintptr(buf) + B_CHARTAB_OFF), 0, 32)
	if (^C.int)(uintptr(buf) + B_P_LISP_OFF)^ != 0 {
		chtab := ([^]u64)(uintptr(buf) + B_CHARTAB_OFF)
		chtab[0] |= u64(1) << u64(45)
	}
	start: C.int = 3
	if global {
		start = 0
	}
	for i := start; i <= 3; i += 1 {
		p: cstring
		if i == 0 {
			p = transmute(cstring)(p_isi_g)
		} else if i == 1 {
			p = transmute(cstring)(p_isp_g)
		} else if i == 2 {
			p = transmute(cstring)(p_isf_g)
		} else {
			p = transmute(cstring)((^rawptr)(uintptr(buf) + B_P_ISK_OFF)^)
		}
		if parse_isopt_o(transmute(^u8)(p), buf, false) == FAIL_E {
			return false
		}
	}
	chartab_initialized = true
	return true
}

// Validate isopt-style option value (charset.c public).
@(export)
check_isopt :: proc "c" (var: ^u8) -> C.int {
	context = runtime.default_context()
	return parse_isopt_o(var, nil, true)
}

// isopt parser/filler (C-static; plain proc).
parse_isopt_o :: proc "c" (var: ^u8, buf: rawptr, only_check: bool) -> C.int {
	context = runtime.default_context()
	p := transmute(cstring)(var)
	for ([^]u8)(p)[0] != 0 {
		tilde := false
		do_isalpha := false
		if ([^]u8)(p)[0] == '^' && ([^]u8)(p)[1] != 0 {
			tilde = true
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		}
		c: C.int
		if ascii_isdigit(([^]u8)(p)[0]) {
			c = getdigits_int(transmute(^^u8)(&p), true, 0)
		} else {
			c = mb_ptr2char_adv(transmute(^^u8)(&p))
		}
		c2: C.int = -1
		if ([^]u8)(p)[0] == '-' && ([^]u8)(p)[1] != 0 {
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			if ascii_isdigit(([^]u8)(p)[0]) {
				c2 = getdigits_int(transmute(^^u8)(&p), true, 0)
			} else {
				c2 = mb_ptr2char_adv(transmute(^^u8)(&p))
			}
		}
		if c <= 0 || c >= 256 || (c2 < c && c2 != -1) || c2 >= 256 || (!(([^]u8)(p)[0] == 0 || ([^]u8)(p)[0] == ',')) {
			return FAIL_E
		}
		trail_comma := ([^]u8)(p)[0] == ','
		p = transmute(cstring)(skip_to_option_part(transmute(^u8)(p)))
		if trail_comma && ([^]u8)(p)[0] == 0 {
			return FAIL_E
		}
		if only_check {
			continue
		}
		if c2 == -1 {
			if c == '@' {
				do_isalpha = true
				c = 1
				c2 = 255
			} else {
				c2 = c
			}
		}
		for c <= c2 {
			if !do_isalpha || mb_islower_r2(c) || mb_isupper_r(c) {
				if var == p_isi_g {
					if tilde {
						g_chartab[c] = g_chartab[c] & ~u8(CT_ID_CHAR_O)
					} else {
						g_chartab[c] = g_chartab[c] | u8(CT_ID_CHAR_O)
					}
				} else if var == p_isp_g {
					if c < ' ' || c > '~' {
						if tilde {
							add := u32(2)
							if (dy_flags_g & K_OPT_DY_UHEX_O) != 0 {
								add = 4
							}
							g_chartab[c] = u8((u32(g_chartab[c]) & ~u32(CT_CELL_MASK_O)) + add)
							g_chartab[c] = g_chartab[c] & ~u8(CT_PRINT_CHAR_O)
						} else {
							g_chartab[c] = u8((u32(g_chartab[c]) & ~u32(CT_CELL_MASK_O)) + 1)
							g_chartab[c] = g_chartab[c] | u8(CT_PRINT_CHAR_O)
						}
					}
				} else if var == p_isf_g {
					if tilde {
						g_chartab[c] = g_chartab[c] & ~u8(CT_FNAME_CHAR_O)
					} else {
						g_chartab[c] = g_chartab[c] | u8(CT_FNAME_CHAR_O)
					}
				} else {
					chtab := ([^]u64)(uintptr(buf) + B_CHARTAB_OFF)
					bit := u64(1) << u64(u32(c) & 0x3f)
					slot := uintptr(u32(c) >> 6)
					if tilde {
						chtab[slot] &= ~bit
					} else {
						chtab[slot] |= bit
					}
				}
			}
			c += 1
		}
	}
	return OK_E
}

// K_SECOND macro port (keycodes.h; reachable domain is c < 0).
k_second_o :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	if c == 0x80 {
		return 254
	}
	if c == 0 {
		return 255
	}
	return (-c) & 0xff
}

// Cells for byte b (charset.c public; caller keeps b in 0..255).
@(export)
byte2cells :: proc "c" (b: C.int) -> C.int {
	context = runtime.default_context()
	if b >= 0x80 {
		return 0
	}
	return C.int(g_chartab[b] & CT_CELL_MASK_O)
}

// Cells for character c (charset.c public).
@(export)
char2cells :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	if IS_SPECIAL(c) {
		return char2cells(k_second_o(c)) + 2
	}
	if c >= 0x80 {
		return utf_char2cells_e(c)
	}
	return C.int(g_chartab[c & 0xff] & CT_CELL_MASK_O)
}

// Cells for char at p (charset.c public).
@(export)
ptr2cells :: proc "c" (p_in: cstring) -> C.int {
	context = runtime.default_context()
	if ([^]u8)(p_in)[0] >= 0x80 {
		return utf_ptr2cells_r(p_in)
	}
	return C.int(g_chartab[([^]u8)(p_in)[0]] & CT_CELL_MASK_O)
}

// Screen cells for string (charset.c public).
@(export)
vim_strsize :: proc "c" (s: cstring) -> C.int {
	context = runtime.default_context()
	return vim_strnsize(s, MAXCOL)
}

// Screen cells for first len bytes (charset.c public).
@(export)
vim_strnsize :: proc "c" (s: cstring, len: C.int) -> C.int {
	context = runtime.default_context()
	if s == nil {
		libc.abort()
	}
	size: C.int = 0
	cur := s
	n := len
	for ([^]u8)(cur)[0] != 0 {
		n -= 1
		if n < 0 {
			break
		}
		l := utfc_ptr2len(cur)
		size += ptr2cells(cur)
		cur = transmute(cstring)(uintptr(rawptr(cur)) + uintptr(l))
		n -= l - 1
	}
	return size
}

// ID-char test (charset.c public).
@(export)
vim_isIDc :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return c > 0 && c < 0x100 && (g_chartab[c] & CT_ID_CHAR_O) != 0
}

// Keyword-char test, current buffer (charset.c public).
@(export)
vim_iswordc :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return vim_iswordc_buf(c, curbuf)
}

// Keyword-char test over explicit chartab (charset.c public).
@(export)
vim_iswordc_tab :: proc "c" (c: C.int, chartab: rawptr) -> bool {
	context = runtime.default_context()
	if c >= 0x100 {
		return utf_class_tab_e(c, chartab) >= 2
	}
	return c > 0 && ((([^]u64)(chartab)[uintptr(u32(c) >> 6)] & (u64(1) << u64(u32(c) & 0x3f))) != 0)
}

// Keyword-char test for buffer (charset.c public).
@(export)
vim_iswordc_buf :: proc "c" (c: C.int, buf: rawptr) -> bool {
	context = runtime.default_context()
	return vim_iswordc_tab(c, rawptr(uintptr(buf) + B_CHARTAB_OFF))
}

// Keyword-char test at pointer, current buffer (charset.c public).
@(export)
vim_iswordp :: proc "c" (p: ^u8) -> bool {
	context = runtime.default_context()
	return vim_iswordp_buf(p, curbuf)
}

// Keyword-char test at pointer for buffer (charset.c public).
@(export)
vim_iswordp_buf :: proc "c" (p: ^u8, buf: rawptr) -> bool {
	context = runtime.default_context()
	c := C.int(([^]u8)(p)[0])
	if C.int(utf8len_tab_g[([^]u8)(p)[0]]) > 1 {
		c = utf_ptr2char(transmute(cstring)(p))
	}
	return vim_iswordc_buf(c, buf)
}

// File-name char test (charset.c public).
@(export)
vim_isfilec :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return c >= 0x100 || (c > 0 && (g_chartab[c] & CT_FNAME_CHAR_O) != 0)
}

// File-name char test with gf extras (charset.c public).
@(export)
vim_is_fname_char :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return vim_isfilec(c) || c == ',' || c == ' ' || c == '@' || c == ':'
}

// File-name or wildcard char test (charset.c public).
@(export)
vim_isfilec_or_wc :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	buf := [2]u8{u8(c), 0}
	return vim_isfilec(c) || c == ']' || path_has_wildcard(transmute(cstring)(&buf[0]))
}

// Printable-char test (charset.c public).
@(export)
vim_isprintc :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	if c >= 0x100 {
		return utf_printable_e(c)
	}
	return c > 0 && (g_chartab[c] & CT_PRINT_CHAR_O) != 0
}

// Blank whitespace columns of cursor line (charset.c public).
@(export)
getwhitecols_curline :: proc "c" () -> C.int {
	context = runtime.default_context()
	return getwhitecols(transmute(cstring)(get_cursor_line_ptr()))
}

// Blank whitespace columns at p (charset.c public).
@(export)
getwhitecols :: proc "c" (p: cstring) -> C.int {
	context = runtime.default_context()
	return C.int(uintptr(rawptr(skipwhite(p))) - uintptr(rawptr(p)))
}

// Blank-line test (charset.c public).
@(export)
vim_isblankline :: proc "c" (lbuf: ^u8) -> bool {
	context = runtime.default_context()
	p := skipwhite(transmute(cstring)(lbuf))
	c := ([^]u8)(p)[0]
	return c == 0 || c == '\r' || c == '\n'
}

// —— Batch C3: trans family + str_foldcase ——

// StringBuilder space guarantee (klib kv_ensure_space mirror).
sb_ensure_o :: proc "c" (str: ^StringBuilder, extra: C.size_t) {
	context = runtime.default_context()
	need := str.size + extra
	if str.capacity < need {
		cap := need
		cap -= 1
		cap |= cap >> 1
		cap |= cap >> 2
		cap |= cap >> 4
		cap |= cap >> 8
		cap |= cap >> 16
		cap += 1
		str.capacity = cap
		str.items = (^u8)(xrealloc(str.items, C.size_t(cap)))
	}
}

// In-place special-char translation (charset.c public).
@(export)
trans_characters :: proc "c" (buf: ^u8, bufsize: C.int) {
	context = runtime.default_context()
	len := C.int(libc.strlen(transmute(cstring)(buf)))
	room := bufsize - len
	cur := uintptr(buf)
	for ([^]u8)(cur)[0] != 0 {
		trs_len := utfc_ptr2len(transmute(cstring)(cur))
		if trs_len > 1 {
			len -= trs_len
		} else {
			trs := transchar_byte(C.int(([^]u8)(cur)[0]))
			trs_len = C.int(libc.strlen(transmute(cstring)(trs)))
			if trs_len > 1 {
				room -= trs_len - 1
				if room <= 0 {
					return
				}
				libc.memmove(rawptr(cur + uintptr(trs_len)), rawptr(cur + 1), C.size_t(len))
			}
			libc.memmove(rawptr(cur), rawptr(trs), C.size_t(trs_len))
			len -= 1
		}
		cur += uintptr(trs_len)
	}
}

// Translated length estimator (charset.c public).
@(export)
transstr_len :: proc "c" (s: cstring, untab: bool) -> C.size_t {
	context = runtime.default_context()
	p := s
	length: C.size_t = 0
	for ([^]u8)(p)[0] != 0 {
		l := C.size_t(utfc_ptr2len(p))
		if l > 1 {
			if vim_isprintc(utf_ptr2char(p)) {
				length += l
			} else {
				off: C.size_t = 0
				for off < l {
					c := utf_ptr2char(transmute(cstring)(uintptr(rawptr(p)) + uintptr(off)))
					hexbuf: [9]u8
					off += C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(p)) + uintptr(off))))
					length += transchar_hex(&hexbuf[0], c)
				}
			}
			p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(l))
		} else if ([^]u8)(p)[0] == '\t' && !untab {
			length += 1
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		} else {
			b2c := byte2cells(C.int(([^]u8)(p)[0]))
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			if b2c > 0 {
				length += C.size_t(b2c)
			} else {
				length += 4
			}
		}
	}
	return length
}

// Translating copy into bounded buffer (charset.c public).
@(export)
transstr_buf :: proc "c" (s: ^u8, slen: C.ssize_t, buf: ^u8, buflen: C.size_t, untab: bool) -> C.size_t {
	context = runtime.default_context()
	p := transmute(cstring)(s)
	buf_p := buf
	buf_e := (^u8)(uintptr(buf) + uintptr(buflen) - 1)
	for (slen < 0 || uintptr(rawptr(p)) - uintptr(rawptr(s)) < uintptr(slen)) && ([^]u8)(p)[0] != 0 && uintptr(buf_p) < uintptr(buf_e) {
		l := C.size_t(utfc_ptr2len(p))
		if l > 1 {
			if uintptr(buf_p) + uintptr(l) > uintptr(buf_e) {
				break
			}
			if vim_isprintc(utf_ptr2char(p)) {
				libc.memmove(rawptr(buf_p), rawptr(p), C.size_t(l))
				buf_p = (^u8)(uintptr(buf_p) + uintptr(l))
			} else {
				off: C.size_t = 0
				for off < l {
					c := utf_ptr2char(transmute(cstring)(uintptr(rawptr(p)) + uintptr(off)))
					hexbuf: [9]u8
					hexlen := transchar_hex(&hexbuf[0], c)
					if uintptr(buf_p) + uintptr(hexlen) > uintptr(buf_e) {
						break
					}
					libc.memmove(rawptr(buf_p), rawptr(&hexbuf[0]), C.size_t(hexlen))
					buf_p = (^u8)(uintptr(buf_p) + uintptr(hexlen))
					off += C.size_t(utfc_ptr2len(transmute(cstring)(uintptr(rawptr(p)) + uintptr(off))))
				}
			}
			p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(l))
		} else if ([^]u8)(p)[0] == '\t' && !untab {
			([^]u8)(buf_p)[0] = ([^]u8)(p)[0]
			buf_p = (^u8)(uintptr(buf_p) + 1)
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
		} else {
			tb := transchar_byte(C.int(([^]u8)(p)[0]))
			p = transmute(cstring)(uintptr(rawptr(p)) + 1)
			tb_len := libc.strlen(transmute(cstring)(tb))
			if uintptr(buf_p) + uintptr(tb_len) > uintptr(buf_e) {
				break
			}
			libc.memmove(rawptr(buf_p), rawptr(tb), C.size_t(tb_len))
			buf_p = (^u8)(uintptr(buf_p) + uintptr(tb_len))
		}
	}
	([^]u8)(buf_p)[0] = 0
	if uintptr(buf_p) > uintptr(buf_e) {
		libc.abort()
	}
	return C.size_t(uintptr(buf_p) - uintptr(buf))
}

// Translating copy into fresh allocation (charset.c public).
@(export)
transstr :: proc "c" (s: cstring, untab: bool) -> ^u8 {
	context = runtime.default_context()
	length := transstr_len(s, untab) + 1
	raw := xmalloc(C.size_t(length))
	transstr_buf(transmute(^u8)(s), -1, transmute(^u8)(raw), C.size_t(length), untab)
	return transmute(^u8)(raw)
}

// Translating append into StringBuilder (charset.c public).
@(export)
kv_transstr :: proc "c" (str: ^StringBuilder, s: cstring, untab: bool) -> C.size_t {
	context = runtime.default_context()
	if s == nil {
		return 0
	}
	length := transstr_len(s, untab)
	sb_ensure_o(str, length + 1)
	transstr_buf(transmute(^u8)(s), -1, &([^]u8)(str.items)[uintptr(str.size)], length + 1, untab)
	str.size += length
	return length
}

// Case-fold copy (charset.c public; cstring sig matches old klib decl).
@(export)
str_foldcase :: proc "c" (str: cstring, orglen: C.int, buf: cstring, buflen: C.int) -> cstring {
	context = runtime.default_context()
	src := ([^]u8)(str)
	length := orglen
	ga: Garray
	if buf == nil {
		ga_init(&ga, 1, 10)
		ga_grow(&ga, length + 1)
		libc.memmove(ga.ga_data, rawptr(src), C.size_t(length))
		ga.ga_len = length
	} else {
		dst := ([^]u8)(buf)
		if length >= buflen {
			length = buflen - 1
		}
		libc.memmove(rawptr(dst), rawptr(src), C.size_t(length))
	}
	i: C.int = 0
	for {
		base: [^]u8
		if buf == nil {
			base = ([^]u8)(ga.ga_data)
		} else {
			base = ([^]u8)(buf)
		}
		if base[i] == 0 {
			break
		}
		at := rawptr(uintptr(base) + uintptr(i))
		c := utf_ptr2char(transmute(cstring)(at))
		olen := utfc_ptr2len(transmute(cstring)(at))
		lc := mb_tolower_r(c)
		if ((c < 0x80) || (olen > 1)) && (c != lc) {
			nlen := utf_char2len_r(lc)
			if olen != nlen {
				if nlen > olen {
					if buf == nil {
						ga_grow(&ga, nlen - olen + 1)
					} else {
						if length + nlen - olen >= buflen {
							lc = c
							nlen = olen
						}
					}
				}
				if olen != nlen {
					if buf == nil {
						base2 := ([^]u8)(ga.ga_data)
						libc.memmove(rawptr(uintptr(base2) + uintptr(i + nlen)), rawptr(uintptr(base2) + uintptr(i + olen)), C.size_t(ga.ga_len - (i + olen) + 1))
						ga.ga_len += nlen - olen
					} else {
						b2 := ([^]u8)(buf)
						libc.memmove(rawptr(uintptr(b2) + uintptr(i + nlen)), rawptr(uintptr(b2) + uintptr(i + olen)), C.size_t(length - (i + olen) + 1))
						length += nlen - olen
					}
				}
			}
			if buf == nil {
				utf_char2bytes(lc, &([^]u8)(ga.ga_data)[i])
			} else {
				utf_char2bytes(lc, &([^]u8)(buf)[i])
			}
		}
		if buf == nil {
			i += utfc_ptr2len(transmute(cstring)(&([^]u8)(ga.ga_data)[i]))
		} else {
			i += utfc_ptr2len(transmute(cstring)(&([^]u8)(buf)[i]))
		}
	}
	if buf == nil {
		return transmute(cstring)(ga.ga_data)
	}
	return buf
}

// Printable translation via static buffer (charset.c public).
@(export)
transchar :: proc "c" (c: C.int) -> ^u8 {
	context = runtime.default_context()
	return transchar_buf(curbuf, c)
}

// Printable translation for buffer (charset.c public).
@(export)
transchar_buf :: proc "c" (buf: rawptr, c_in: C.int) -> ^u8 {
	context = runtime.default_context()
	c := c_in
	i: C.int = 0
	if IS_SPECIAL(c) {
		transchar_charbuf[0] = '~'
		transchar_charbuf[1] = '@'
		i = 2
		c = k_second_o(c)
	}
	if (!chartab_initialized && (c >= ' ' && c <= '~')) || ((c <= 0xFF) && vim_isprintc(c)) {
		transchar_charbuf[i] = u8(c)
		transchar_charbuf[i + 1] = 0
	} else if c <= 0xFF {
		transchar_nonprint(buf, &transchar_charbuf[i], c)
	} else {
		transchar_hex(&transchar_charbuf[i], c)
	}
	return &transchar_charbuf[0]
}

// Byte translation via static buffer (charset.c public).
@(export)
transchar_byte :: proc "c" (c: C.int) -> ^u8 {
	context = runtime.default_context()
	return transchar_byte_buf(curbuf, c)
}

// Byte translation for buffer (charset.c public).
@(export)
transchar_byte_buf :: proc "c" (buf: rawptr, c: C.int) -> ^u8 {
	context = runtime.default_context()
	if c >= 0x80 {
		transchar_nonprint(buf, &transchar_charbuf[0], c)
		return &transchar_charbuf[0]
	}
	return transchar_buf(buf, c)
}

// Non-printable to caret/uhex form (charset.c public).
@(export)
transchar_nonprint :: proc "c" (buf: rawptr, charbuf: ^u8, c_in: C.int) {
	context = runtime.default_context()
	c := c_in
	if c == 10 {
		c = 0
	} else if buf != nil && c == 13 && get_fileformat(buf) == 2 {
		c = 10
	}
	if c > 0xff {
		libc.abort()
	}
	if (dy_flags_g & K_OPT_DY_UHEX_O) != 0 || c > 0x7f {
		transchar_hex(charbuf, c)
	} else {
		cb := ([^]u8)(charbuf)
		cb[0] = '^'
		cb[1] = u8(u32(c) ~ u32(0x40))
		cb[2] = 0
	}
}

// Non-printable to <XXXX> hex form (charset.c public).
@(export)
transchar_hex :: proc "c" (buf: ^u8, c: C.int) -> C.size_t {
	context = runtime.default_context()
	b := ([^]u8)(buf)
	i: C.size_t = 0
	b[i] = '<'
	i += 1
	if c > 0xFF {
		if c > 0xFFFF {
			b[i] = u8(nr2hex_o(C.uint(c) >> 20))
			i += 1
			b[i] = u8(nr2hex_o(C.uint(c) >> 16))
			i += 1
		}
		b[i] = u8(nr2hex_o(C.uint(c) >> 12))
		i += 1
		b[i] = u8(nr2hex_o(C.uint(c) >> 8))
		i += 1
	}
	b[i] = u8(nr2hex_o(C.uint(c) >> 4))
	i += 1
	b[i] = u8(nr2hex_o(C.uint(c)))
	i += 1
	b[i] = '>'
	i += 1
	b[i] = 0
	return i
}

// —— Batch C4: vim_str2nr (last charset.c function) ——

// STR2NR_BIN/OCT/HEX/FORCE_O live in ex_cmds.odin (Batch 29, values match).
STR2NR_OOCT_O :: 8
STR2NR_QUOTE_O :: 16

ascii_isodigit :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return c >= '0' && c <= '7'
}

ascii_isalnum_o :: proc "c" (c: C.int) -> bool {
	context = runtime.default_context()
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// Multi-base number parser (charset.c public; goto network restructured
// into a base-decision tree + single parameterized parse loop).
@(export)
vim_str2nr :: proc "c" (start: cstring, prep: ^cstring, len: ^C.int, what: C.int, nptr: ^C.longlong, unptr: ^u64, maxlen: C.size_t, strict: bool, overflow: ^bool) {
	context = runtime.default_context()
	at := ([^]u8)(start)
	ended :: proc(at: [^]u8, start: cstring, maxlen: C.size_t) -> bool {
		return !(maxlen == 0 || C.int(uintptr(at) - uintptr(rawptr(start))) < C.int(maxlen))
	}
	pre: C.int = 0
	negative := at[0] == '-'
	un: u64 = 0
	if len != nil {
		len^ = 0
	}
	if negative {
		at = ([^]u8)(uintptr(at) + 1)
	}
	// kind: 0 = binary, 1 = octal, 2 = decimal, 3 = hex.
	kind: C.int = 2
	if (what & STR2NR_FORCE_O) != 0 {
		switch what & ~C.int(STR2NR_FORCE_O | STR2NR_QUOTE_O) {
		case STR2NR_HEX_O:
			if !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && at[0] == '0' && (at[1] == 'x' || at[1] == 'X') && ascii_isxdigit(at[2]) {
				at = ([^]u8)(uintptr(at) + 2)
			}
			kind = 3
		case STR2NR_BIN_O:
			if !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && at[0] == '0' && (at[1] == 'b' || at[1] == 'B') && ascii_isbdigit(at[2]) {
				at = ([^]u8)(uintptr(at) + 2)
			}
			kind = 0
		case STR2NR_OCT_O, STR2NR_OOCT_O, STR2NR_OCT_O | STR2NR_OOCT_O:
			if !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && at[0] == '0' && (at[1] == 'o' || at[1] == 'O') && ascii_isodigit(at[2]) {
				at = ([^]u8)(uintptr(at) + 2)
			}
			kind = 1
		case 0:
			kind = 2
		case:
			libc.abort()
		}
	} else if (what & (STR2NR_HEX_O | STR2NR_OCT_O | STR2NR_OOCT_O | STR2NR_BIN_O)) != 0 && !ended(([^]u8)(uintptr(at) + 1), start, maxlen) && at[0] == '0' && at[1] != '8' && at[1] != '9' {
		pre = C.int(at[1])
		if (what & STR2NR_HEX_O) != 0 && !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && (pre == 'X' || pre == 'x') && ascii_isxdigit(at[2]) {
			at = ([^]u8)(uintptr(at) + 2)
			kind = 3
		} else if (what & STR2NR_BIN_O) != 0 && !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && (pre == 'B' || pre == 'b') && ascii_isbdigit(at[2]) {
			at = ([^]u8)(uintptr(at) + 2)
			kind = 0
		} else if (what & STR2NR_OOCT_O) != 0 && !ended(([^]u8)(uintptr(at) + 2), start, maxlen) && (pre == 'O' || pre == 'o') && ascii_isodigit(at[2]) {
			at = ([^]u8)(uintptr(at) + 2)
			kind = 1
		} else {
			pre = 0
			if (what & STR2NR_OCT_O) == 0 || !ascii_isodigit(at[1]) {
				kind = 2
			} else {
				old_oct := true
				i := 2
				for !ended(([^]u8)(uintptr(at) + uintptr(i)), start, maxlen) && ascii_isdigit(at[i]) {
					if at[i] > '7' {
						old_oct = false
						break
					}
					i += 1
				}
				if old_oct {
					pre = '0'
					kind = 1
				} else {
					kind = 2
				}
			}
		}
	} else {
		kind = 2
	}
	base: u64 = 10
	if kind == 0 {
		base = 2
	} else if kind == 1 {
		base = 8
	} else if kind == 3 {
		base = 16
	}
	after_prefix := at
	for !ended(at, start, maxlen) {
		if (what & STR2NR_QUOTE_O) != 0 && uintptr(at) > uintptr(after_prefix) && at[0] == '\'' {
			at = ([^]u8)(uintptr(at) + 1)
			ok := false
			if kind == 0 {
				ok = at[0] == '0' || at[0] == '1'
			} else if kind == 1 {
				ok = ascii_isodigit(at[0])
			} else if kind == 2 {
				ok = ascii_isdigit(at[0])
			} else {
				ok = ascii_isxdigit(at[0])
			}
			if !ended(at, start, maxlen) && ok {
				continue
			}
			at = ([^]u8)(uintptr(at) - 1)
		}
		cond := false
		digit: u64 = 0
		if kind == 0 {
			cond = at[0] == '0' || at[0] == '1'
			digit = u64(at[0] - '0')
		} else if kind == 1 {
			cond = ascii_isodigit(at[0])
			digit = u64(at[0] - '0')
		} else if kind == 2 {
			cond = ascii_isdigit(at[0])
			digit = u64(at[0] - '0')
		} else {
			cond = ascii_isxdigit(at[0])
			digit = u64(hex2nr(C.int(at[0])))
		}
		if !cond {
			break
		}
		if un < max(u64)/base || (un == max(u64)/base && (base != 10 || digit <= max(u64)%10)) {
			un = base*un + digit
		} else {
			un = max(u64)
			if overflow != nil {
				overflow^ = true
			}
		}
		at = ([^]u8)(uintptr(at) + 1)
	}
	if strict && uintptr(at) - uintptr(rawptr(start)) != uintptr(maxlen) && ascii_isalnum_o(C.int(at[0])) {
		return
	}
	if prep != nil {
		(^C.int)(prep)^ = pre
	}
	if len != nil {
		len^ = C.int(uintptr(at) - uintptr(rawptr(start)))
	}
	if nptr != nil {
		if negative {
			if un > u64(max(C.longlong)) {
				nptr^ = min(C.longlong)
				if overflow != nil {
					overflow^ = true
				}
			} else {
				nptr^ = -C.longlong(un)
			}
		} else {
			if un > u64(max(C.longlong)) {
				un = u64(max(C.longlong))
				if overflow != nil {
					overflow^ = true
				}
			}
			nptr^ = C.longlong(un)
		}
	}
	if unptr != nil {
		unptr^ = un
	}
}
