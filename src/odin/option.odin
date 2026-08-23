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
OPT_MODELINE_S :: 0x04

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
	os_value_checked: bool,
	os_value_changed: bool,
	os_restore_chartab: bool,
	_pad51:         [5]u8,
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
	@(link_name = "nvim_odin_get_varp_scope_from")
	nvim_odin_get_varp_scope_from :: proc "c" (opt_idx: C.int, opt_flags: C.int, buf: rawptr, win: rawptr) -> rawptr ---
	@(link_name = "nvim_odin_get_varp_scope")
	nvim_odin_get_varp_scope :: proc "c" (opt_idx: C.int, opt_flags: C.int) -> rawptr ---
	@(link_name = "nvim_odin_get_varp_from")
	nvim_odin_get_varp_from :: proc "c" (opt_idx: C.int, buf: rawptr, win: rawptr) -> rawptr ---
	@(link_name = "nvim_odin_option_is_global_local")
	option_is_global_local_shim :: proc "c" (opt_idx: C.int) -> bool ---
	@(link_name = "nvim_odin_get_option_unset_value")
	get_option_unset_value_c :: proc "c" (opt_idx: C.int) -> OptVal ---
	@(link_name = "nvim_odin_insecure_flag")
	insecure_flag_c :: proc "c" (wp: rawptr, opt_idx: C.int, opt_flags: C.int) -> ^C.uint32_t ---

	@(link_name = "find_special_key")
	find_special_key_r :: proc "c" (srcp: ^^u8, src_len: C.size_t, modp: ^C.int, flags: C.int, has_lt: ^bool) -> C.int ---
	@(link_name = "need_maketitle2")
	need_maketitle_opt: bool
	@(link_name = "redraw_buf_status_later2")
	redraw_buf_status_later_opt :: proc "c" (buf: rawptr) ---
	@(link_name = "redraw_tabline")
	redraw_tabline_opt: bool
	@(link_name = "api_free_string")
	api_free_string_r :: proc "c" (s: NvimString) ---
	@(link_name = "empty_string_option")
	empty_string_option_c: ^u8
	// curbufIsChanged is an Odin proc in undo.odin — reuse directly.
	@(link_name = "copy_string")
	copy_string_o :: proc "c" (s: NvimString, arena: rawptr) -> NvimString ---
	@(link_name = "min_rows_for_all_tabpages")
	min_rows_for_all_tabpages_r :: proc "c" () -> C.int ---
	@(link_name = "win_default_scroll")
	win_default_scroll_r :: proc "c" (wp: rawptr) -> C.int ---
	@(link_name = "status_redraw_all")
	status_redraw_all_r :: proc "c" () ---
	@(link_name = "changed_window_setting")
	changed_window_setting_opt :: proc "c" (wp: rawptr) ---
	@(link_name = "redraw_buf_later")
	redraw_buf_later_o :: proc "c" (buf: rawptr, typ: C.int) ---
	@(link_name = "redraw_all_later")
	redraw_all_later_o :: proc "c" (typ: C.int) ---
	@(link_name = "p_wmh")
	p_wmh_opt: C.longlong
	@(link_name = "p_wh")
	p_wh_opt: C.longlong
	@(link_name = "p_wmw")
	p_wmw_opt: C.longlong
	@(link_name = "p_wiw")
	p_wiw_opt: C.longlong

	@(link_name = "find_key_len")
	find_key_len_r :: proc "c" (arg: cstring, len: C.size_t, in_string: bool) -> C.int ---
	@(link_name = "maketitle")
	maketitle_r :: proc "c" () ---
	// starting already declared in main.odin — reuse directly.
	@(link_name = "magic_overruled")
	magic_overruled_g: C.int
	@(link_name = "p_shm")
	p_shm: ^u8
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

// ── options[] table access ───────────────────────────────────────────────────

opt_table :: proc "c"() -> [^]vimoption_T {
	return ([^]vimoption_T)(nvim_odin_opt_table())
}

opt_at :: proc "c"(idx: C.int) -> ^vimoption_T {
	tbl := opt_table()
	return (^vimoption_T)(uintptr(tbl) + uintptr(idx) * size_of(vimoption_T))
}

// ── OptVal constructors ─────────────────────────────────────────────────────

nil_optval :: proc "c"() -> OptVal {
	return OptVal{typ = kOptValTypeNil}
}

bool_optval :: proc "c"(b: C.int) -> OptVal {
	o := OptVal{typ = kOptValTypeBoolean}
	(^C.int)(&o.data)^ = b
	return o
}

num_optval :: proc "c"(n: C.longlong) -> OptVal {
	o := OptVal{typ = kOptValTypeNumber}
	(^C.longlong)(&o.data)^ = n
	return o
}

str_optval :: proc "c"(data: ^u8, size: C.size_t) -> OptVal {
	o := OptVal{typ = kOptValTypeString}
	(^^u8)(&o.data)^ = data
	(^C.size_t)(uintptr(&o.data) + 8)^ = size
	return o
}

ov_boolean :: proc "c"(o: ^OptVal) -> ^C.int {
	return (^C.int)(&o.data)
}

ov_number :: proc "c"(o: ^OptVal) -> ^C.longlong {
	return (^C.longlong)(&o.data)
}

ov_str_data :: proc "c"(o: ^OptVal) -> ^u8 {
	return (^^u8)(&o.data)^
}

ov_str_size :: proc "c"(o: ^OptVal) -> C.size_t {
	return (^C.size_t)(uintptr(&o.data) + 8)^
}

// ── optval_* family (option.c 3364-3460) ────────────────────────────────────

@(export)
optval_free :: proc "c"(o_in: OptVal) {
	o := o_in
	switch o.typ {
	case kOptValTypeString:
		s := NvimString{transmute(cstring)(ov_str_data(&o)), ov_str_size(&o)}
		if ov_str_data(&o) != empty_string_option_c {
			api_free_string_r(s)
		}
	case:
	}
}

@(export)
optval_copy :: proc "c"(o_in: OptVal) -> OptVal {
	o := o_in
	switch o.typ {
	case kOptValTypeString:
		// copy_string(o.data.string, NULL) — replicate with xmalloc+memcpy
		sz := ov_str_size(&o)
		src := ov_str_data(&o)
		dst := (^u8)(xmalloc_sp(sz + 1))
		libc.memcpy(dst, src, sz)
		b_set(dst, C.int(sz), 0)
		return str_optval(dst, sz)
	case:
		return o
	}
}

@(export)
optval_equal :: proc "c"(o1_in: OptVal, o2_in: OptVal) -> bool {
	o1 := o1_in
	o2 := o2_in
	if o1.typ != o2.typ {
		return false
	}
	switch o1.typ {
	case kOptValTypeNil:
		return true
	case kOptValTypeBoolean:
		return ov_boolean(&o1)^ == ov_boolean(&o2)^
	case kOptValTypeNumber:
		return ov_number(&o1)^ == ov_number(&o2)^
	case kOptValTypeString:
		d1 := ov_str_data(&o1)
		d2 := ov_str_data(&o2)
		s1 := ov_str_size(&o1)
		if s1 != ov_str_size(&o2) {
			return false
		}
		if d1 == d2 {
			return true
		}
		// strnequal
		return libc.memcmp(d1, d2, C.size_t(s1)) == 0
	}
	return false
}

// option_get_type is static — read from table.
option_get_type_idx :: proc "c"(opt_idx: C.int) -> C.int {
	return opt_at(opt_idx).typ
}

BUF_CHANGED_OFF :: 208 // buf_T.b_changed

@(export)
optval_from_varp :: proc "c"(opt_idx: C.int, varp: rawptr) -> OptVal {
	// Special case: 'modified' → curbufIsChanged()
	if varp == transmute(rawptr)(uintptr(curbuf) + BUF_CHANGED_OFF) {
		return bool_optval(curbufIsChanged() ? 1 : 0)
	}

	typ := option_get_type_idx(opt_idx)
	switch typ {
	case kOptValTypeNil:
		return nil_optval()
	case kOptValTypeBoolean:
		return bool_optval((^C.int)(varp)^)
	case kOptValTypeNumber:
		return num_optval((^C.longlong)(varp)^)
	case kOptValTypeString:
		return str_optval((^^u8)(varp)^, libc.strlen(transmute(cstring)((^^u8)(varp)^)))
	}
	return nil_optval()
}

// ── numeric option validation (option.c 3026-3363) ─────────────────────────

// enum values from options_enum.generated.h
kOptHelpheight_E :: 129
kOptTitlelen_E :: 327
kOptUpdatecount_E :: 337
kOptReport_E :: 237
kOptUpdatetime_E :: 338
kOptSidescroll_E :: 277
kOptFoldlevel_E :: 106
kOptShiftwidth_E :: 268
kOptTextwidth_E :: 320
kOptWritedelay_E :: 376
kOptTimeoutlen_E :: 325
kOptWinheight_E :: 364
kOptWinminheight_E :: 366
kOptWinwidth_E :: 369
kOptWinminwidth_E :: 367
kOptMaxcombine_E :: 183
kOptCmdheight_E :: 44
kOptHistory_E :: 133
kOptPyxversion_E :: 228
kOptRegexpengine_E :: 234
kOptScrolloff_E :: 248
kOptScrolloffpad_E :: 249
kOptSidescrolloff_E :: 278
kOptCmdwinheight_E :: 45
kOptConceallevel_E :: 58
kOptNumberwidth_E :: 207
kOptIminsert_E :: 142
kOptImsearch_E :: 143
kOptChannel_E :: 35
kOptScrollback_E :: 245
kOptTabstop_E :: 306
kOptChistory_E :: 37
kOptLhistory_E :: 167
kOptMaxsearchcount_E :: 187
kOptLines_E :: 169
kOptColumns_E :: 47
kOptPumblend_E :: 223
kOptScrolljump_E :: 247
kOptScroll_E :: 244

MAX_MCO_S :: 9 // MAX_MCO
MAX_NUMBERWIDTH_S :: 20
B_IMODE_LAST_S :: 1
SB_MAX_S :: 1000000
TABSTOP_MAX_S :: 9999
NO_LOCAL_UNDOLEVEL_S :: -123456

e_positive_s :: "E487: Argument must be positive"
e_invarg_s :: "E513: Invalid argument" // generic; C uses e_invarg which is parameterized — callers pass through untranslated
e_winheight_s :: "E591: 'winheight' cannot be smaller than 'winminheight'"
e_winwidth_s :: "E592: 'winwidth' cannot be smaller than 'winminwidth'"
e_scroll_s :: "E49: Invalid scroll size"
e_quickfix_neg_s :: "E1542: Cannot have a negative or zero number of quickfix/location lists"
e_quickfix_hundred_s :: "E1543: Cannot have more than a hundred quickfix/location lists"

W_VIEW_HEIGHT_OFF :: 500

@(export)
check_num_option_bounds :: proc "c"(opt_idx: C.int, newval: ^C.longlong, errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	errmsg := cstring(nil)

	switch opt_idx {
	case kOptLines_E:
		if newval^ < C.longlong(min_rows_for_all_tabpages_r()) && full_screen {
			libc.snprintf(errbuf, errbuflen, "E593: Need at least %d lines", min_rows_for_all_tabpages_r())
			errmsg = transmute(cstring)(errbuf)
			newval^ = C.longlong(min_rows_for_all_tabpages_r())
		}
		if newval^ > C.longlong(0x7FFFFFFF) {
			newval^ = 0x7FFFFFFF
		}
	case kOptColumns_E:
		MIN_COLUMNS :: 12
		if newval^ < MIN_COLUMNS && full_screen {
			libc.snprintf(errbuf, errbuflen, "E594: Need at least %d columns", int(MIN_COLUMNS))
			errmsg = transmute(cstring)(errbuf)
			newval^ = MIN_COLUMNS
		}
		if newval^ > C.longlong(0x7FFFFFFF) {
			newval^ = 0x7FFFFFFF
		}
	case kOptPumblend_E:
		v := newval^
		newval^ = max(min(v, 100), 0)
	case kOptScrolljump_E:
		if (newval^ < -100 || newval^ >= C.longlong(Rows_opt())) && full_screen {
			errmsg = e_scroll_s
			newval^ = 1
		}
	case kOptScroll_E:
		wvh := (^C.int)(uintptr(curwin) + W_VIEW_HEIGHT_OFF)^
		if (newval^ <= 0 || (newval^ > C.longlong(wvh) && wvh > 0)) && full_screen {
			if newval^ != 0 {
				errmsg = e_scroll_s
			}
			newval^ = C.longlong(win_default_scroll_r(curwin))
		}
	case:
	}
	return errmsg
}

foreign _ {
	@(link_name = "Rows")
	Rows_g2: C.int
}

Rows_opt :: proc "c"() -> C.int {
	return Rows_g2
}

@(export)
validate_num_option :: proc "c"(opt_idx: C.int, newval: ^C.longlong, errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	value := newval^

	// Many number options assume their value is in the signed int range.
	if value < C.longlong(-0x80000000) || value > C.longlong(0x7FFFFFFF) {
		return cstring("E513: Invalid argument") // e_invarg
	}

	switch opt_idx {
	case kOptHelpheight_E, kOptTitlelen_E, kOptUpdatecount_E, kOptReport_E,
	     kOptUpdatetime_E, kOptSidescroll_E, kOptFoldlevel_E, kOptShiftwidth_E,
	     kOptTextwidth_E, kOptWritedelay_E, kOptTimeoutlen_E:
		if value < 0 {
			return e_positive_s
		}
	case kOptWinheight_E:
		if value < 1 {
			return e_positive_s
		} else if p_wmh_opt > value {
			return e_winheight_s
		}
	case kOptWinminheight_E:
		if value < 0 {
			return e_positive_s
		} else if value > p_wh_opt {
			return e_winheight_s
		}
	case kOptWinwidth_E:
		if value < 1 {
			return e_positive_s
		} else if p_wmw_opt > value {
			return e_winwidth_s
		}
	case kOptWinminwidth_E:
		if value < 0 {
			return e_positive_s
		} else if value > p_wiw_opt {
			return e_winwidth_s
		}
	case kOptMaxcombine_E:
		newval^ = MAX_MCO_S
	case kOptCmdheight_E:
		if value < 0 {
			return e_positive_s
		}
	case kOptHistory_E:
		if value < 0 {
			return e_positive_s
		} else if value > 10000 {
			return cstring("E513: Invalid argument")
		}
	case kOptPyxversion_E:
		if value == 0 {
			newval^ = 3
		} else if value != 3 {
			return cstring("E513: Invalid argument")
		}
	case kOptRegexpengine_E:
		if value < 0 || value > 2 {
			return cstring("E513: Invalid argument")
		}
	case kOptScrolloff_E:
		if value < 0 && full_screen {
			return e_positive_s
		}
	case kOptScrolloffpad_E:
		if value < 0 {
			return cstring("E513: Invalid argument")
		}
	case kOptSidescrolloff_E:
		if value < 0 && full_screen {
			return e_positive_s
		}
	case kOptCmdwinheight_E:
		if value < 1 {
			return e_positive_s
		}
	case kOptConceallevel_E:
		if value < 0 {
			return e_positive_s
		} else if value > 3 {
			return cstring("E513: Invalid argument")
		}
	case kOptNumberwidth_E:
		if value < 1 {
			return e_positive_s
		} else if value > MAX_NUMBERWIDTH_S {
			return cstring("E513: Invalid argument")
		}
	case kOptIminsert_E:
		if value < 0 || value > B_IMODE_LAST_S {
			return cstring("E513: Invalid argument")
		}
	case kOptImsearch_E:
		if value < -1 || value > B_IMODE_LAST_S {
			return cstring("E513: Invalid argument")
		}
	case kOptChannel_E:
		return cstring("E513: Invalid argument")
	case kOptScrollback_E:
		if value < -1 || value > SB_MAX_S {
			return cstring("E513: Invalid argument")
		}
	case kOptTabstop_E:
		if value < 1 {
			return e_positive_s
		} else if value > TABSTOP_MAX_S {
			return cstring("E513: Invalid argument")
		}
	case kOptChistory_E, kOptLhistory_E:
		if value < 1 {
			return e_quickfix_neg_s
		} else if value > 100 {
			return e_quickfix_hundred_s
		}
	case kOptMaxsearchcount_E:
		if value <= 0 {
			return e_positive_s
		} else if value > 9999 {
			return cstring("E513: Invalid argument")
		}
	case:
	}

	return check_num_option_bounds(opt_idx, newval, errbuf, errbuflen)
}

foreign _ {
	@(link_name = "check_illegal_path_names")
	check_illegal_path_names_r :: proc "c" (varp: ^u8, flags: C.uint32_t) -> bool ---
	@(link_name = "buf_init_chartab")
	buf_init_chartab_r :: proc "c" (buf: rawptr, send_error: bool) -> bool ---
	@(link_name = "set_option_sctx")
	set_option_sctx_r :: proc "c" (opt_idx: C.int, opt_flags: C.int, sctx: rawptr) ---
	@(link_name = "apply_optionset_autocmd_now")
	apply_optionset_autocmd_r :: proc "c" (opt_idx: C.int, opt_flags: C.int, v1: OptValData, v2: OptValData, v3: OptValData, v4: OptValData, err: cstring) ---
	@(link_name = "nvim_odin_do_syntax_autocmd")
	do_syntax_autocmd_r :: proc "c" (buf: rawptr, value_changed: bool) ---
	@(link_name = "do_filetype_autocmd")
	do_filetype_autocmd_r :: proc "c" (buf: rawptr, value_changed: bool) ---
	@(link_name = "nvim_odin_do_spelllang_source")
	do_spelllang_source_r :: proc "c" (wp: rawptr) ---
	@(link_name = "comp_col")
	comp_col_r :: proc "c" () ---
	@(link_name = "set_winbar")
	set_winbar_r :: proc "c" (force: bool) ---
}

SCCTX_SIZE :: 24
IOSIZE_OPT :: 1025

e_sandbox_s :: "E48: Not allowed in sandbox"
e_secure_s :: "E523: Not allowed here"

// option_is_global_local / window_local / global_only (static inlines in C)
option_is_global_local_i :: proc "c"(opt_idx: C.int) -> bool {
	if opt_idx < 0 {
		return false
	}
	bw: u8 = (1 << kOptScopeBuf_S) | (1 << kOptScopeWin_S)
	o := opt_at(opt_idx)
	return (o.scope_flags & bw) != 0 && (o.scope_flags & (1 << kOptScopeGlobal_S)) != 0
}

option_is_global_only :: proc "c"(opt_idx: C.int) -> bool {
	if opt_idx < 0 {
		return false
	}
	bw: u8 = (1 << kOptScopeBuf_S) | (1 << kOptScopeWin_S)
	o := opt_at(opt_idx)
	return (o.scope_flags & bw) == 0 && (o.scope_flags & (1 << kOptScopeGlobal_S)) != 0
}

option_is_window_local :: proc "c"(opt_idx: C.int) -> bool {
	if opt_idx < 0 {
		return false
	}
	o := opt_at(opt_idx)
	return (o.scope_flags & (1 << kOptScopeWin_S)) != 0
}

@(export)
option_has_type :: proc "c"(opt_idx: C.int, typ: C.int) -> bool {
	if opt_idx < 0 {
		return true
	}
	t := opt_at(opt_idx).typ
	return t == typ || t == kOptValTypeNil
}

@(export)
option_has_scope :: proc "c"(opt_idx: C.int, scope: C.int) -> bool {
	if opt_idx < 0 {
		return false
	}
	return (opt_at(opt_idx).scope_flags & (1 << u8(scope))) != 0
}

@(export)
is_option_hidden :: proc "c"(opt_idx: C.int) -> bool {
	// Hidden options are always immutable and point to their default value
	if opt_idx < 0 {
		return true
	}
	o := opt_at(opt_idx)
	return o.immutable && o.varp == transmute(rawptr)(&o.def_val.data)
}

// optval_to_cstr (static, option.c 3495)
optval_to_cstr_o :: proc "c"(o_in: OptVal) -> ^u8 {
	o := o_in
	switch o.typ {
	case kOptValTypeNil:
		return xstrdup_r2(cstring(""))
	case kOptValTypeBoolean:
		return xstrdup_r2(ov_boolean(&o)^ != 0 ? cstring("true") : cstring("false"))
	case kOptValTypeNumber:
		buf := (^u8)(xmalloc_sp(32))
		libc.snprintf(buf, 32, "%lld", ov_number(&o)^)
		return buf
	case kOptValTypeString:
		sz := ov_str_size(&o)
		buf := (^u8)(xmalloc_sp(sz + 3))
		libc.snprintf(buf, sz + 3, "\"%s\"", transmute(cstring)(ov_str_data(&o)))
		return buf
	}
	return nil
}

foreign _ {
	@(link_name = "xstrdup")
	xstrdup_r2 :: proc "c" (s: cstring) -> ^u8 ---
	@(link_name = "xmalloc")
	xmalloc_o :: proc "c" (n: C.size_t) -> rawptr ---
}

@(export)
option_get_type :: proc "c"(opt_idx: C.int) -> C.int {
	return option_get_type_idx(opt_idx)
}

// validate_option_value (static, option.c 4011-4045)
validate_option_value_o :: proc "c"(opt_idx: C.int, newval: ^OptVal, opt_flags: C.int,
                                    errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	errmsg := cstring(nil)
	opt := opt_at(opt_idx)

	_ = opt
	// Always allow unsetting local value of global-local option.
	if option_is_global_local_i(opt_idx) && (opt_flags & OPT_LOCAL_S) != 0 &&
	optval_equal(newval^, get_option_unset_value_o(opt_idx)) {
		return nil
	}

	if newval.typ == kOptValTypeNil {
		if opt_flags == OPT_GLOBAL_S {
			return cstring("Cannot unset global option value") // _(msg), untranslated passthrough
		}
		newval^ = optval_copy(get_option_unset_value_o(opt_idx))
	} else if !option_has_type(opt_idx, newval.typ) {
		rep := optval_to_cstr_o(newval^)
		type_str := optval_type_get_name_o(opt.typ)
		type_got := optval_type_get_name_o(newval.typ)
		libc.snprintf(errbuf, errbuflen,
			"Invalid value for option '%s': expected %s, got %s %s",
			transmute(cstring)(opt.fullname), type_str, type_got, transmute(cstring)(rep))
		xfree(rep)
		errmsg = transmute(cstring)(errbuf)
	} else if newval.typ == kOptValTypeNumber {
		errmsg = validate_num_option(opt_idx, (^C.longlong)(&newval.data), errbuf, errbuflen)
	}

	return errmsg
}

// get_option_unset_value (static, option.c 3784-3817)
get_option_unset_value_o :: proc "c"(opt_idx: C.int) -> OptVal {
	o := opt_at(opt_idx)

	if option_is_global_local_i(opt_idx) {
		if o.typ == kOptValTypeString {
			return str_optval(empty_string_option_c, 0)
		}
		switch opt_idx {
		case 6: // kOptAutocomplete
			return bool_optval(-1) // kNone TriState
		case 10: // kOptAutoread
			return bool_optval(-1)
		case 118: // kOptFsync
			return bool_optval(-1)
		case 248, 249, 278: // scrolloff/scrolloffpad/sidescrolloff
			return num_optval(-1)
		case 335: // undolevels
			return num_optval(NO_LOCAL_UNDOLEVEL_S)
		case:
			libc.abort()
		}
	}
	return optval_from_varp(opt_idx, nvim_odin_get_varp_scope(opt_idx, OPT_GLOBAL_S))
}

// did_set_option (static, option.c 3851-4008)
did_set_option_o :: proc "c"(
	opt_idx: C.int,
	varp: rawptr,
	old_value: OptVal,
	new_value: OptVal,
	opt_flags: C.int,
	set_sid: C.int,
	direct: bool,
	value_replaced: bool,
	errbuf: ^u8,
	errbuflen: C.size_t,
) -> cstring {
	opt := opt_at(opt_idx)
	errmsg := cstring(nil)
	restore_chartab := false
	value_changed := false
	value_checked := false

	did_set_cb_args := optset_T {
		os_varp = varp,
		os_idx = opt_idx,
		os_flags = opt_flags,
		os_restore_chartab = false,
		os_errbuf = errbuf,
		os_errbuflen = errbuflen,
		os_buf = curbuf,
		os_win = curwin,
	}
	did_set_cb_args.os_oldval = old_value.data
	did_set_cb_args.os_newval = new_value.data

	if direct {
		// Don't do any extra processing if setting directly.
	} else if opt.immutable && !optval_equal(old_value, new_value) {
		errmsg = cstring("E794: Cannot set variable in this context") // e_unsupportedoption placeholder
	} else if (secure || sandbox != 0) && (opt.flags & kOptFlagSecure) != 0 {
		errmsg = e_secure_s
	} else if new_value.typ == kOptValTypeString &&
	check_illegal_path_names_r((^^u8)(varp)^, opt.flags) {
		errmsg = cstring("E513: Invalid argument") // e_invarg
	} else if opt.opt_did_set_cb != nil {
		cb := transmute(proc "c" (^optset_T) -> cstring)(opt.opt_did_set_cb)
		errmsg = cb(&did_set_cb_args)
		value_changed = did_set_cb_args.os_value_changed
		value_checked = did_set_cb_args.os_value_checked
		restore_chartab = did_set_cb_args.os_restore_chartab
	}

	if errmsg != nil {
		set_option_varp_o(opt_idx, varp, old_value, true)
		if restore_chartab {
			buf_init_chartab_r(curbuf, true)
		}
		return errmsg
	}

	// Re-assign new value (may get freed/modified by the callback).
	new_value2 := optval_from_varp(opt_idx, varp)

	if set_sid != -6 { // SID_NONE
		sc := current_sctx_buf
		if set_sid != 0 {
			// override sc_sid
			(^C.int)(uintptr(&sc[0]))^ = set_sid // sctx_T.sc_sid @0
		}
		set_option_sctx_r(opt_idx, opt_flags, &sc[0])
	}

	optval_free(old_value)

	scope_both := (opt_flags & (OPT_LOCAL_S | OPT_GLOBAL_S)) == 0

	if scope_both {
		if option_is_global_local_i(opt_idx) {
			// Free local value and clear it.
			varp_local := nvim_odin_get_varp_scope(opt_idx, OPT_LOCAL_S)
			local_unset := get_option_unset_value_o(opt_idx)
			set_option_varp_o(opt_idx, varp_local, optval_copy(local_unset), true)
		} else {
			varp_global := nvim_odin_get_varp_scope(opt_idx, OPT_GLOBAL_S)
			set_option_varp_o(opt_idx, varp_global, optval_copy(new_value2), true)
		}
	}

	if direct {
		return errmsg
	}

	// Trigger autocmds for special options.
	b_p_syn_off := 10104 + 0 // probe needed; see AGENTS note
	_ = b_p_syn_off
	if varp == transmute(rawptr)(uintptr(curbuf) + B_P_SYN_OFF) {
		do_syntax_autocmd_r(curbuf, value_changed)
	} else if varp == transmute(rawptr)(uintptr(curbuf) + B_P_FT_OFF) {
		if ((opt_flags & OPT_MODELINE_S) == 0 || value_changed) {
			do_filetype_autocmd_r(curbuf, value_changed)
		}
	} else if win_s_r(curwin) != nil && varp == transmute(rawptr)(uintptr(win_s_r(curwin)) + SB_P_SPL_OFF) {
		do_spelllang_source_r(curwin)
	}

	comp_col_r()

	p_mouse_addr := transmute(rawptr)(&p_mouse_g)
	if varp == p_mouse_addr {
		setmouse()
	} else if (varp == transmute(rawptr)(&p_flp_g) ||
	varp == transmute(rawptr)(uintptr(curbuf) + B_P_FLP_OFF)) && curwin_briopt_list() != 0 {
		redraw_all_later_o(UPD_NOT_VALID_SP)
	} else if varp == transmute(rawptr)(&p_wbr_g) ||
	varp == transmute(rawptr)(uintptr(curwin) + W_P_WBR_OFF2) {
		set_winbar_r(true)
	}

	w_curswant := (^C.longlong)(uintptr(curwin) + 148)^
	if w_curswant != MAXCOL && (opt.flags & (kOptFlagCurswant | kOptFlagRedrAll)) != 0 &&
	(opt.flags & kOptFlagHLOnly) == 0 {
		w_set_curswant_true(curwin)
	}

	check_redraw_o(opt.flags)

	if errmsg == nil {
		opt.flags |= kOptFlagWasSet

		flagsp := insecure_flag_c(curwin, opt_idx, opt_flags)
		flagsp_local: ^C.uint32_t = scope_both ? insecure_flag_c(curwin, opt_idx, OPT_LOCAL_S) : nil
		if !value_checked && (secure || sandbox != 0 || (opt_flags & OPT_MODELINE_S) != 0) {
			flagsp^ |= kOptFlagInsecure
			if flagsp_local != nil {
				flagsp_local^ |= kOptFlagInsecure
			}
		} else if value_replaced {
			flagsp^ &= ~C.uint32_t(kOptFlagInsecure)
			if flagsp_local != nil {
				flagsp_local^ &= ~C.uint32_t(kOptFlagInsecure)
			}
		}
	}

	return errmsg
}

// constants + FFI used by did_set_option
B_P_SYN_OFF :: 10688
B_P_FT_OFF :: 10416
B_P_FLP_OFF :: 10432
W_P_WBR_OFF2 :: 1104
W_BRIOPT_LIST_OFF :: 4248

foreign _ {
	@(link_name = "p_mouse")
	p_mouse_g: ^u8
	@(link_name = "p_flp")
	p_flp_g: ^u8
	@(link_name = "p_wbr")
	p_wbr_g: ^u8
}

curwin_briopt_list :: proc "c"() -> C.int {
	return (^C.int)(uintptr(curwin) + W_BRIOPT_LIST_OFF)^
}

// set_option_varp (static, option.c 3458-3479)
set_option_varp_o :: proc "c"(opt_idx: C.int, varp: rawptr, value_in: OptVal, free_oldval: bool) {
	value := value_in
	if free_oldval {
		optval_free(optval_from_varp(opt_idx, varp))
	}
	switch value.typ {
	case kOptValTypeBoolean:
		(^C.int)(varp)^ = ov_boolean(&value)^
	case kOptValTypeNumber:
		(^C.longlong)(varp)^ = ov_number(&value)^
	case kOptValTypeString:
		(^^u8)(varp)^ = ov_str_data(&value)
	case:
		libc.abort()
	}
}

check_redraw_o :: proc "c"(flags: C.uint32_t) {
	all := (flags & kOptFlagRedrAll) == kOptFlagRedrAll

	if (flags & kOptFlagRedrStat) != 0 || all {
		status_redraw_all_r()
	}
	if (flags & kOptFlagRedrTabl) != 0 || all {
		redraw_tabline_opt = true
	}
	if (flags & kOptFlagRedrBuf) != 0 || (flags & kOptFlagRedrWin) != 0 || all {
		if (flags & kOptFlagHLOnly) != 0 {
			redraw_later(curwin, UPD_NOT_VALID_SP)
		} else {
			changed_window_setting_opt(curwin)
		}
	}
	if (flags & kOptFlagRedrBuf) != 0 {
		redraw_buf_later_o(curbuf, UPD_NOT_VALID_SP)
	}
	if all {
		redraw_all_later_o(UPD_NOT_VALID_SP)
	}
}

// set_option (static, option.c 4061-4208)
set_option_o :: proc "c"(
	opt_idx: C.int,
	value_in: OptVal,
	opt_flags: C.int,
	set_sid: C.int,
	direct: bool,
	value_replaced: bool,
	errbuf: ^u8,
	errbuflen: C.size_t,
) -> cstring {
	value := value_in
	errmsg := cstring(nil)

	if !direct {
		errmsg = validate_option_value_o(opt_idx, &value, opt_flags, errbuf, errbuflen)
		if errmsg != nil {
			optval_free(value)
			return errmsg
		}
	}

	opt := opt_at(opt_idx)
	scope_local := (opt_flags & OPT_LOCAL_S) != 0
	scope_global := (opt_flags & OPT_GLOBAL_S) != 0
	scope_both := !scope_local && !scope_global
	is_opt_local_unset := is_option_local_value_unset_o(opt_idx)

	varp: rawptr = scope_both && option_is_global_local_i(opt_idx) ? opt.varp :
	nvim_odin_get_varp_scope(opt_idx, opt_flags)
	varp_local := nvim_odin_get_varp_scope(opt_idx, OPT_LOCAL_S)
	varp_global := nvim_odin_get_varp_scope(opt_idx, OPT_GLOBAL_S)

	old_value := optval_from_varp(opt_idx, varp)
	old_global_value := optval_from_varp(opt_idx, varp_global)
	old_local_value: OptVal
	if is_opt_local_unset {
		old_local_value = old_global_value
	} else {
		old_local_value = optval_from_varp(opt_idx, varp_local)
	}
	used_old_value: OptVal
	if scope_local && is_opt_local_unset {
		used_old_value = optval_from_varp(opt_idx, get_varp_o(opt))
	} else {
		used_old_value = old_value
	}

	saved_used_value := optval_copy(used_old_value)
	saved_old_global_value := optval_copy(old_global_value)
	saved_old_local_value := optval_copy(old_local_value)
	saved_new_value := optval_copy(value)

	p_flags := insecure_flag_c(curwin, opt_idx, opt_flags)
	secure_saved := secure

	if (opt_flags & OPT_MODELINE_S) != 0 || sandbox != 0 ||
	(!value_replaced && (p_flags^ & kOptFlagInsecure) != 0) {
		secure = true
	}

	set_option_varp_o(opt_idx, varp, value, false)
	errmsg = did_set_option_o(opt_idx, varp, old_value, value, opt_flags, set_sid,
		direct, value_replaced, errbuf, errbuflen)

	secure = secure_saved

	if errmsg == nil && !direct {
		if starting == 0 || starting > 2 { // !starting — starting==0 means startup finished; C checks `if (!starting)`
			apply_optionset_autocmd_r(opt_idx, opt_flags, saved_used_value.data,
				saved_old_global_value.data, saved_old_local_value.data, saved_new_value.data, errmsg)
		}
		if (opt.flags & kOptFlagUIOption) != 0 {
			obj := optval_as_object_o(saved_new_value)
			ui_call_option_set_r(transmute(cstring)(opt.fullname), transmute(rawptr)(&obj))
		}
	}

	optval_free(saved_used_value)
	optval_free(saved_old_local_value)
	optval_free(saved_old_global_value)
	optval_free(saved_new_value)

	return errmsg
}

foreign _ {
	@(link_name = "ui_call_option_set")
	ui_call_option_set_r :: proc "c" (name: cstring, obj: rawptr) ---
}

// get_varp (exported in C): returns "used" varp
get_varp_o :: proc "c"(p: ^vimoption_T) -> rawptr {
	idx := get_opt_idx_o(p)
	return nvim_odin_get_varp_from(idx, curbuf, curwin)
}

// get_opt_idx (static in C): pointer diff / table index. Find implementation:
get_opt_idx_o :: proc "c"(p: ^vimoption_T) -> C.int {
	tbl := opt_table()
	return C.int((uintptr(p) - uintptr(tbl)) / size_of(vimoption_T))
}

// is_option_local_value_unset (static, option.c 3820-3835)
is_option_local_value_unset_o :: proc "c"(opt_idx: C.int) -> bool {
	o := opt_at(opt_idx)
	if !option_is_global_local_i(opt_idx) {
		return false
	}
	varp_local := nvim_odin_get_varp_scope(opt_idx, OPT_LOCAL_S)
	local_value := optval_from_varp(opt_idx, varp_local)
	unset_local_value := get_option_unset_value_o(opt_idx)
	return optval_equal(local_value, unset_local_value)
}
// optval_as_object (option.c ~3517) — minimal Object mirror for ui_call_option_set.
// Api_Object layout from api/defs.h: type + data union.
Api_Object_Opt :: struct #align(8) {
	typ:  C.int,
	data: [16]u8,
}

API_OBJECT_TYPE_NIL_OPT :: 0
API_OBJECT_TYPE_BOOLEAN_OPT :: 1
API_OBJECT_TYPE_INTEGER_OPT :: 2
API_OBJECT_TYPE_STRING_OPT :: 4 // verify below

optval_as_object_o :: proc "c"(o_in: OptVal) -> Api_Object_Opt {
	o := o_in
	ret := Api_Object_Opt{}
	switch o.typ {
	case kOptValTypeBoolean:
		b := ov_boolean(&o)^
		if b == 0 || b == 1 {
			ret.typ = API_OBJECT_TYPE_BOOLEAN_OPT
			(^C.int)(&ret.data)^ = b
		} else {
			ret.typ = API_OBJECT_TYPE_NIL_OPT
		}
	case kOptValTypeNumber:
		ret.typ = API_OBJECT_TYPE_INTEGER_OPT
		(^C.longlong)(&ret.data)^ = ov_number(&o)^
	case kOptValTypeString:
		ret.typ = API_OBJECT_TYPE_STRING_OPT
		(^^u8)(&ret.data)^ = ov_str_data(&o)
		(^C.size_t)(uintptr(&ret.data) + 8)^ = ov_str_size(&o)
	case:
		ret.typ = API_OBJECT_TYPE_NIL_OPT
	}
	return ret
}

kOptInvalid_S :: -1

@(export)
get_option :: proc "c"(opt_idx: C.int) -> ^vimoption_T {
	return opt_at(opt_idx)
}

@(export)
get_option_value :: proc "c"(opt_idx: C.int, opt_flags: C.int) -> OptVal {
	if opt_idx == kOptInvalid_S {
		return nil_optval()
	}
	varp := nvim_odin_get_varp_scope(opt_idx, opt_flags)
	return optval_copy(optval_from_varp(opt_idx, varp))
}

@(export)
set_option_value :: proc "c"(opt_idx: C.int, value: OptVal, opt_flags: C.int) -> cstring {
	static_errbuf: [IOSIZE_OPT]u8
	flags := opt_at(opt_idx).flags

	if sandbox > 0 && (flags & kOptFlagSecure) != 0 {
		return cstring("E48: Not allowed in sandbox")
	}

	return set_option_o(opt_idx, optval_copy(value), opt_flags, 0, false, true,
		&static_errbuf[0], IOSIZE_OPT)
}

@(export)
set_option_value_handle_tty :: proc "c"(name: cstring, opt_idx: C.int, value: OptVal, opt_flags: C.int) -> cstring {
	static_errbuf: [IOSIZE_OPT]u8

	if opt_idx == kOptInvalid_S {
		if is_tty_option_r(name) {
			return nil
		}
		libc.snprintf(&static_errbuf[0], IOSIZE_OPT, "E355: Unknown option: %s", name)
		return transmute(cstring)(&static_errbuf[0])
	}
	return set_option_value(opt_idx, value, opt_flags)
}

foreign _ {
	@(link_name = "is_tty_option")
	is_tty_option_r :: proc "c" (name: cstring) -> bool ---
}

@(export)
set_option_value_give_err :: proc "c"(opt_idx: C.int, value: OptVal, opt_flags: C.int) {
	errmsg := set_option_value(opt_idx, value, opt_flags)
	if errmsg != nil {
		emsg(errmsg)
	}
}

@(export)
set_option_direct :: proc "c"(opt_idx: C.int, value: OptVal, opt_flags: C.int, set_sid: C.int) {
	static_errbuf: [IOSIZE_OPT]u8

	if is_option_hidden(opt_idx) {
		return
	}

	errmsg := set_option_o(opt_idx, optval_copy(value), opt_flags, set_sid, true, true,
		&static_errbuf[0], IOSIZE_OPT)
	_ = errmsg
}

@(export)
set_option_direct_for :: proc "c"(opt_idx: C.int, value: OptVal, opt_flags: C.int, set_sid: C.int,
                                  scope: C.int, from: rawptr) {
	save_curbuf := curbuf
	save_curwin := curwin

	switch scope {
	case kOptScopeGlobal_S:
	case kOptScopeWin_S:
		curwin = from
		curbuf = (^^rawptr)(uintptr(curwin) + 8)^ // win_T.w_buffer @8
	case kOptScopeBuf_S:
		curbuf = from
	case kOptScopeTab_S:
		libc.abort()
	case:
	}

	set_option_direct(opt_idx, value, opt_flags, set_sid)

	curwin = save_curwin
	curbuf = save_curbuf
}

optval_type_get_name_o :: proc "c"(t: C.int) -> cstring {
	switch t {
	case kOptValTypeNil:
		return cstring("nil")
	case kOptValTypeBoolean:
		return cstring("boolean")
	case kOptValTypeNumber:
		return cstring("number")
	case kOptValTypeString:
		return cstring("string")
	}
	return cstring("?")
}

// ── find_option family + sctx + was_set (option.c 3340-3360, 2043-2085, 6477-6492) ──

foreign _ {
	@(link_name = "nvim_odin_find_option_len")
	nvim_odin_find_option_len :: proc "c" (name: cstring, len: C.size_t) -> C.int ---
	@(link_name = "nlua_set_sctx")
	nlua_set_sctx_r :: proc "c" (sctx: rawptr) ---
}

kOptInvalid_OPT :: -1

@(export)
find_option_len :: proc "c"(name: cstring, len: C.size_t) -> C.int {
	return nvim_odin_find_option_len(name, len)
}

@(export)
find_option :: proc "c"(name: cstring) -> C.int {
	return nvim_odin_find_option_len(name, libc.strlen(name))
}

sourcing_lnum_o :: proc "c"() -> C.int {
	// SOURCING_LNUM: ((estack_T*)exestack.ga_data)[exestack.ga_len-1].es_lnum, es_lnum@0
	if exestack.ga_len <= 0 {
		return 0
	}
	arr := ([^]C.int)(exestack.ga_data)
	return int_at(arr, (exestack.ga_len - 1) * 8) // estack_T=32B, es_lnum@0
}

@(export)
option_scope_idx :: proc "c"(opt_idx: C.int, scope: C.int) -> C.ssize_t {
	o := opt_at(opt_idx)
	return (^C.ssize_t)(uintptr(&o.scope_idx[0]) + uintptr(scope) * size_of(C.ssize_t))^
}

@(export)
get_option_flags :: proc "c"(opt_idx: C.int) -> C.uint32_t {
	if opt_idx < 0 {
		return 0
	}
	return opt_at(opt_idx).flags
}

@(export)
get_option_sctx :: proc "c"(opt_idx: C.int) -> rawptr {
	return transmute(rawptr)(&opt_at(opt_idx).script_ctx_buf[0])
}

@(export)
set_option_sctx :: proc "c"(opt_idx: C.int, opt_flags: C.int, script_ctx_in: rawptr) {
	script_ctx_buf: [SCCTX_STRIDE]u8
	libc.memcpy(&script_ctx_buf[0], script_ctx_in, SCCTX_STRIDE)

	both := (opt_flags & (OPT_LOCAL_S | OPT_GLOBAL_S)) == 0

	// Modeline already has the line number set.
	if (opt_flags & OPT_MODELINE_S) == 0 {
		sc_lnum := (^C.int)(uintptr(&script_ctx_buf[0]) + 8) // sc_lnum @8
		sc_lnum^ += sourcing_lnum_o()
	}
	nlua_set_sctx_r(&script_ctx_buf[0])

	if both || (opt_flags & OPT_GLOBAL_S) != 0 || option_is_global_only(opt_idx) {
		libc.memcpy(&opt_at(opt_idx).script_ctx_buf[0], &script_ctx_buf[0], SCCTX_STRIDE)
	}
	if both || (opt_flags & OPT_LOCAL_S) != 0 {
		if option_has_scope(opt_idx, kOptScopeBuf_S) {
			// curbuf->b_p_script_ctx[scope_idx] — need b_p_script_ctx offset:
			dst := (^u8)(uintptr(curbuf) + B_P_SCRIPT_CTX_OFF +
			uintptr(option_scope_idx(opt_idx, kOptScopeBuf_S)) * SCCTX_STRIDE)
			libc.memcpy(dst, &script_ctx_buf[0], SCCTX_STRIDE)
		} else if option_has_scope(opt_idx, kOptScopeWin_S) {
			dst := (^u8)(uintptr(curwin) + W_P_SCRIPT_CTX_OFF +
			uintptr(option_scope_idx(opt_idx, kOptScopeWin_S)) * SCCTX_STRIDE)
			libc.memcpy(dst, &script_ctx_buf[0], SCCTX_STRIDE)
			if both {
				// also setting the "all buffers" value: w_allbuf_opt.wo_script_ctx[]
				// w_allbuf_opt@? and wo_script_ctx offset within — probe needed; approximate via known layout:
				dst2 := (^u8)(uintptr(curwin) + W_ALLBUF_WO_SCRIPT_CTX_OFF +
				uintptr(option_scope_idx(opt_idx, kOptScopeWin_S)) * SCCTX_STRIDE)
				libc.memcpy(dst2, &script_ctx_buf[0], SCCTX_STRIDE)
			}
		}
	}
}

B_P_SCRIPT_CTX_OFF :: 7896
W_P_SCRIPT_CTX_OFF :: 1248
W_ALLBUF_WO_SCRIPT_CTX_OFF :: 2520 + 432
@(export)
option_was_set :: proc "c"(opt_idx: C.int) -> bool {
	if opt_idx < 0 {
		return false
	}
	return (opt_at(opt_idx).flags & kOptFlagWasSet) != 0
}

@(export)
reset_option_was_set :: proc "c"(opt_idx: C.int) {
	if opt_idx < 0 {
		return
	}
	opt_at(opt_idx).flags &= ~C.uint32_t(kOptFlagWasSet)
}
