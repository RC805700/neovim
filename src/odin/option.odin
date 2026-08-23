// option.odin — port of src/nvim/option.c (options handling)
package main

import C "core:c"
import "core:c/libc"

// ── Constants (option_defs.h) ────────────────────────────────────────────────

kOptFlagExpand :: 1 << 0
kOptFlagNoDefExp :: 1 << 1
kOptFlagNoDefault :: 1 << 2
kOptFlagWasSet :: 1 << 3
kOptFlagNoMkrc :: 1 << 4
kOptFlagUIOption :: 1 << 5
kOptFlagRedrTabl :: 1 << 6
kOptFlagRedrStat :: 1 << 7
kOptFlagRedrWin :: 1 << 8
kOptFlagRedrBuf :: 1 << 9
kOptFlagRedrAll :: kOptFlagRedrBuf | kOptFlagRedrWin
kOptFlagRedrClear :: kOptFlagRedrAll | kOptFlagRedrStat
kOptFlagComma :: 1 << 10
kOptFlagOneComma :: (1 << 11) | kOptFlagComma
kOptFlagNoDup :: 1 << 12
kOptFlagFlagList :: 1 << 13
kOptFlagSecure :: 1 << 14
kOptFlagGettext :: 1 << 15
kOptFlagNoGlob :: 1 << 16
kOptFlagNFname :: 1 << 17
kOptFlagInsecure :: 1 << 18
kOptFlagPriMkrc :: 1 << 19
kOptFlagCurswant :: 1 << 20
kOptFlagNDname :: 1 << 21
kOptFlagHLOnly :: 1 << 22
kOptFlagMLE :: 1 << 23
kOptFlagFunc :: 1 << 24
kOptFlagColon :: 1 << 25

kOptValTypeNil :: -1
kOptValTypeBoolean :: 0
kOptValTypeNumber :: 1
kOptValTypeString :: 2

kOptScopeGlobal_S :: 0
kOptScopeWin_S :: 1
kOptScopeBuf_S :: 2
kOptScopeTab_S :: 3

OP_NONE_S :: 0
OP_ADDING_S :: 1
OP_PREPENDING_S :: 2
OP_REMOVING_S :: 3

// OPT_* flags for get/set (option.h)
OPT_GLOBAL_S :: 4
OPT_LOCAL_S :: 2

// ── Struct mirrors (offset-verified) ────────────────────────────────────────

OptValData :: struct #align(8) {
	buf: [16]u8, // union { TriState bool; OptInt number; String string } — access via helpers
}

// OptValData accessors (union is {int} / {i64} / String{ptr,size})
optdata_bool :: proc "c"(d: ^OptValData) -> ^C.int {
	return (^C.int)(d)
}
optdata_number :: proc "c"(d: ^OptValData) -> ^C.longlong {
	return (^C.longlong)(d)
}
optdata_str :: proc "c"(d: ^OptValData) -> (^^u8, ^C.size_t) {
	return (^^u8)(d), (^C.size_t)(uintptr(d) + 8)
}

OptVal :: struct #align(8) {
	typ:  C.int,
	_pad: [4]u8,
	data: OptValData,
}

vimoption_T :: struct #align(8) { // 168
	fullname:      ^u8,
	shortname:     ^u8,
	flags:         C.uint32_t,
	typ:           C.int,
	scope_flags:   u8,
	_pad28:        [4]u8,
	varp:          rawptr,
	flags_var:     ^C.uint32_t,
	scope_idx:     [4]C.ssize_t,
	immutable:     bool,
	_pad81:        [7]u8,
	values:        ^^u8,
	_pad96:        [8]u8,
	opt_did_set_cb: rawptr,
	opt_expand_cb: rawptr,
	def_val:       OptVal,
	script_ctx_buf: [24]u8, // sctx_T
}

#assert(size_of(OptVal) == 24)
#assert(size_of(vimoption_T) == 168)
#assert(offset_of(vimoption_T, varp) == 32)
#assert(offset_of(vimoption_T, scope_idx) == 48)
#assert(offset_of(vimoption_T, def_val) == 120)
#assert(offset_of(vimoption_T, script_ctx_buf) == 144)

optset_T :: struct #align(8) { // 88
	os_varp:        rawptr,
	os_idx:         C.int,
	os_flags:       C.int,
	os_oldval:      OptValData,
	os_newval:      OptValData,
	os_restore_chartab: bool,
	_pad57:         [7]u8,
	os_errbuf:      ^u8,
	os_errbuflen:   C.size_t,
	os_win:         rawptr,
	os_buf:         rawptr,
}

#assert(size_of(optset_T) == 88)

foreign _ {
	// C shim accessors into static options[] table (option.c tail)
	@(link_name = "nvim_odin_opt_table")
	nvim_odin_opt_table :: proc "c" () -> rawptr ---
	@(link_name = "nvim_odin_opt_count")
	nvim_odin_opt_count :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_opt_varp")
	nvim_odin_opt_varp :: proc "c" (opt_idx: C.int) -> rawptr ---

	@(link_name = "find_key_len")
	find_key_len_r :: proc "c" (arg: cstring, len: C.size_t, in_string: bool) -> C.int ---
	@(link_name = "maketitle")
	maketitle_r :: proc "c" () ---
	// starting already declared in main.odin — reuse directly.
	@(link_name = "magic_overruled")
	magic_overruled_g: C.int
	@(link_name = "p_shm")
	p_shm: ^u8
	// p_sh already declared in shell.odin (cstring) — reuse directly.
	@(link_name = "path_tail")
	path_tail_opt :: proc "c" (fname: cstring) -> cstring ---
	@(link_name = "find_special_key")
	find_special_key_r :: proc "c" (srcp: ^^u8, src_len: C.size_t, modp: ^C.int, flags: C.int, has_lt: ^bool) -> C.int ---
	@(link_name = "need_maketitle2")
	need_maketitle_opt: bool
	@(link_name = "redraw_buf_status_later2")
	redraw_buf_status_later_opt :: proc "c" (buf: rawptr) ---
	@(link_name = "redraw_tabline2")
	redraw_tabline_opt: bool
}

// find_key_len is static in option.c — reimplemented here via find_special_key.
find_key_len_odin :: proc "c"(arg_in: ^u8, len: C.size_t, has_lt: bool) -> C.int {
	key := C.int(0)
	arg := arg_in

	if len >= 4 && b_at(arg, 0) == 't' && b_at(arg, 1) == '_' {
		if !has_lt || b_at(arg, 4) == '>' {
			// TERMCAP2KEY(a,b) = -((a) + (b)<<8)
			key = -(C.int(b_at(arg, 2)) + (C.int(b_at(arg, 3)) << 8))
		}
	} else if has_lt {
		arg = (^u8)(uintptr(arg) - 1) // put arg at the '<'
		modifiers := C.int(0)
		// FSK_KEYCODE|FSK_KEEP_X_KEY|FSK_SIMPLIFY = 1|2|8
		key = find_special_key_r(&arg, len + 1, &modifiers, 0x01 | 0x02 | 0x08, nil)
		if modifiers != 0 { // can't handle modifiers here
			key = 0
		}
	}
	return key
}

// p_sh already declared in shell.odin (cstring) — reuse directly.

OPTION_MAGIC_NOT_SET :: 0
OPTION_MAGIC_ON :: 1
OPTION_MAGIC_OFF :: 2

K_ZERO_S :: 0x100 // K_ZERO

ctrl_chr :: proc "c"(c: C.int) -> C.int {
	return c & 0x1f
}

@(export)
string_to_key :: proc "c"(arg: ^u8) -> C.int {
	if b_at(arg, 0) == '<' && b_at(arg, 1) != 0 {
		return find_key_len_odin((^u8)(uintptr(arg) + 1), libc.strlen(transmute(cstring)(arg)), true)
	}
	if b_at(arg, 0) == '^' && b_at(arg, 1) != 0 {
		key := ctrl_chr(C.int(b_at(arg, 1)))
		if key == 0 { // ^@ is <Nul>
			key = K_ZERO_S
		}
		return key
	}
	return C.int(b_at(arg, 0))
}

// When changing 'title', 'titlestring', 'icon' or 'iconstring'.
@(export)
did_set_title :: proc "c"() {
	if starting != 2 { // starting != NO_SCREEN // NO_SCREEN is 2? starting!=NO_SCREEN — check below
		maketitle_r()
	}
}

@(export)
valid_name :: proc "c"(val: cstring, allowed: cstring) -> bool {
	s := transmute(^u8)(val)
	for b_at(s, 0) != 0 {
		c := C.int(b_at(s, 0))
		isalnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !isalnum && _vim_strchr(allowed, c) == nil {
			return false
		}
		s = (^u8)(uintptr(s) + 1)
	}
	return true
}

SHM_ALL_ABBREVIATIONS :: "rmlw"

@(export)
shortmess :: proc "c"(x: C.int) -> bool {
	if p_shm == nil {
		return false
	}
	if _vim_strchr(transmute(cstring)(p_shm), x) != nil {
		return true
	}
	if _vim_strchr(transmute(cstring)(p_shm), 'a') != nil &&
	_vim_strchr(cstring(SHM_ALL_ABBREVIATIONS), x) != nil {
		return true
	}
	return false
}

@(export)
skip_to_option_part :: proc "c"(p_in: ^u8) -> ^u8 {
	p := p_in
	if b_at(p, 0) == ',' {
		p = (^u8)(uintptr(p) + 1)
	}
	for b_at(p, 0) == ' ' {
		p = (^u8)(uintptr(p) + 1)
	}
	return p
}

@(export)
copy_option_part :: proc "c"(option: ^^u8, buf: ^u8, maxlen: C.size_t, sep_chars: cstring) -> C.size_t {
	len := C.size_t(0)
	p := option^

	// skip '.' at start of option part, for 'suffixes'
	if b_at(p, 0) == '.' {
		b_set(buf, C.int(len), b_at(p, 0))
		len += 1
		p = (^u8)(uintptr(p) + 1)
	}
	for b_at(p, 0) != 0 && _vim_strchr(sep_chars, C.int(b_at(p, 0))) == nil {
		// Skip backslash before a separator character and space.
		if b_at(p, 0) == '\\' && _vim_strchr(sep_chars, C.int(b_at(p, 1))) != nil {
			p = (^u8)(uintptr(p) + 1)
		}
		if len < maxlen - 1 {
			b_set(buf, C.int(len), b_at(p, 0))
			len += 1
		}
		p = (^u8)(uintptr(p) + 1)
	}
	b_set(buf, C.int(len), 0)

	if b_at(p, 0) != 0 && b_at(p, 0) != ',' { // skip non-standard separator
		p = (^u8)(uintptr(p) + 1)
	}
	p = skip_to_option_part(p) // p points to next file name

	option^ = p
	return len
}

@(export)
csh_like_shell :: proc "c"() -> bool {
	return strstr_c(path_tail(p_sh), "csh") != nil
}

@(export)
fish_like_shell :: proc "c"() -> bool {
	return strstr_c(path_tail(p_sh), "fish") != nil
}
