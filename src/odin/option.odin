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
OPT_GLOBAL_S :: 1
OPT_LOCAL_S :: 2
OPT_MODELINE_S :: 4

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
	@(link_name = "need_maketitle")
	need_maketitle_opt: bool
	@(link_name = "redraw_buf_status_later")
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
		if ov_str_data(&o) != empty_string_option_c && s.size > 0 {
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
		sd := (^^u8)(varp)^
		if sd == nil {
			return str_optval(empty_string_option_c, 0)
		}
		return str_optval(sd, libc.strlen(transmute(cstring)(sd)))
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
e_invarg_s :: "E474: Invalid argument" // generic; C uses e_invarg which is parameterized — callers pass through untranslated
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

Rows_opt :: proc "c"() -> C.int {
	return Rows
}

@(export)
validate_num_option :: proc "c"(opt_idx: C.int, newval: ^C.longlong, errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	value := newval^

	// Many number options assume their value is in the signed int range.
	if value < C.longlong(-0x80000000) || value > C.longlong(0x7FFFFFFF) {
		return cstring("E474: Invalid argument") // e_invarg
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
			return cstring("E474: Invalid argument")
		}
	case kOptPyxversion_E:
		if value == 0 {
			newval^ = 3
		} else if value != 3 {
			return cstring("E474: Invalid argument")
		}
	case kOptRegexpengine_E:
		if value < 0 || value > 2 {
			return cstring("E474: Invalid argument")
		}
	case kOptScrolloff_E:
		if value < 0 && full_screen {
			return e_positive_s
		}
	case kOptScrolloffpad_E:
		if value < 0 {
			return cstring("E474: Invalid argument")
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
			return cstring("E474: Invalid argument")
		}
	case kOptNumberwidth_E:
		if value < 1 {
			return e_positive_s
		} else if value > MAX_NUMBERWIDTH_S {
			return cstring("E474: Invalid argument")
		}
	case kOptIminsert_E:
		if value < 0 || value > B_IMODE_LAST_S {
			return cstring("E474: Invalid argument")
		}
	case kOptImsearch_E:
		if value < -1 || value > B_IMODE_LAST_S {
			return cstring("E474: Invalid argument")
		}
	case kOptChannel_E:
		return cstring("E474: Invalid argument")
	case kOptScrollback_E:
		if value < -1 || value > SB_MAX_S {
			return cstring("E474: Invalid argument")
		}
	case kOptTabstop_E:
		if value < 1 {
			return e_positive_s
		} else if value > TABSTOP_MAX_S {
			return cstring("E474: Invalid argument")
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
			return cstring("E474: Invalid argument")
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
	set_option_sctx_r :: proc "c" (opt_idx: C.int, opt_flags: C.int, sctx: sctx_T) ---
	@(link_name = "nvim_odin_apply_optionset_autocmd")
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
		errmsg = cstring("E474: Invalid argument") // e_invarg
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
		sc_val := (^sctx_T)(uintptr(&sc[0]))^
		set_option_sctx_r(opt_idx, opt_flags, sc_val)
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
	ret := set_option_value(opt_idx, value, opt_flags)
	if ret != nil {
		// Copy errmsg into a stable static buffer: set_option_value returns a
		// pointer into its own proc-static errbuf which the NEXT call overwrites.
		stable_len := libc.strlen(transmute(cstring)(ret))
		if stable_len < IOSIZE_OPT {
			libc.memcpy(&stable_errbuf_arr[0], transmute(rawptr)(ret), stable_len + 1)
			ret = transmute(cstring)(&stable_errbuf_arr[0])
		}
	}
	return ret
}

stable_errbuf_arr: [IOSIZE_OPT]u8

foreign _ {
	@(link_name = "is_tty_option")
	is_tty_option_r :: proc "c" (name: cstring) -> bool ---
	@(link_name = "nvim_odin_didset_options_sctx")
	didset_options_sctx_c :: proc "c" (opt_flags: C.int, opts: ^C.int) ---
	@(link_name = "nvim_odin_get_p_bin_dep_opts")
	nvim_odin_get_p_bin_dep_opts :: proc "c" () -> ^C.int ---
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

// find_option_len / find_option: C implementations kept (weak in option.c,
// strong there when Odin doesn't define them). Odin code calls the
// nvim_odin_find_option_len shim directly.

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

// ── do_set cluster (option.c 850-1960) ──────────────────────────────────────

foreign _ {
	@(link_name = "p_tags")
	p_tags_g: ^u8
	@(link_name = "p_path")
	p_path_g: ^u8
	@(link_name = "p_sps")
	p_sps_g: ^u8
	@(link_name = "vim_str2nr")
	vim_str2nr_r :: proc "c" (start: cstring, prep: ^cstring, len: ^C.int, what: C.int, nptr: ^C.longlong, sptr: ^u64, maxlen: C.size_t, strict: bool, overflow: ^bool) ---
	@(link_name = "skiptowhite_esc")
	skiptowhite_esc_r :: proc "c" (p: cstring) -> cstring ---
	@(link_name = "last_set_msg")
	last_set_msg_r :: proc "c" (sctx: sctx_T) ---
	@(link_name = "msg_advance")
	msg_advance_r :: proc "c" (col: C.int) ---
	@(link_name = "message_filtered")
	message_filtered_r :: proc "c" (msg: cstring) -> bool ---
	@(link_name = "init_chartab")
	init_chartab_r :: proc "c" () -> C.int ---
	@(link_name = "spell_check_msm")
	spell_check_msm_r :: proc "c" () ---
	@(link_name = "spell_check_sps")
	spell_check_sps_r :: proc "c" () ---
	@(link_name = "did_set_cedit")
	did_set_cedit_r :: proc "c" (eap: rawptr) -> cstring ---
	@(link_name = "did_set_breakat")
	did_set_breakat_r :: proc "c" (eap: rawptr) -> cstring ---
	@(link_name = "didset_window_options")
	didset_window_options_r :: proc "c" (wp: rawptr, all_buf_win_opts: bool) ---
	@(link_name = "highlight_changed")
	highlight_changed_r :: proc "c" () ---
	@(link_name = "set_chars_option")
	set_chars_option_o :: proc "c" (wp: rawptr, val: ^u8, opt: C.int, add: bool, errbuf: ^u8, errbuflen: C.size_t) -> C.int ---
	@(link_name = "check_opt_wim")
	check_opt_wim_r :: proc "c" () -> cstring ---
	@(link_name = "tabstop_set")
	tabstop_set_o :: proc "c" (val: ^u8, ret_list: ^^u8) -> bool ---
	@(link_name = "get_special_key_name")
	get_special_key_name_r :: proc "c" (c: C.int, modifiers: C.int) -> ^u8 ---
	@(link_name = "transchar")
	transchar_o :: proc "c" (c: C.int) -> ^u8 ---
	@(link_name = "find_special_key_in_table")
	find_special_key_in_table_r :: proc "c" (c: C.int) -> C.int ---
	// home_replace is an Odin proc in os_env.odin — reuse directly.
	@(link_name = "option_expand")
	option_expand_o :: proc "c" (opt_idx: C.int, val: cstring) -> ^u8 ---
	// silent_mode/no_wait_return already in main.odin — reuse directly.
	// info_message declared in the later foreign block.
	@(link_name = "p_mle")
	p_mle_opt: C.int
	@(link_name = "trans_characters")
	trans_characters_o :: proc "c" (s: ^u8, len: C.int) ---
}

STR2NR_ALL_S :: 0x0f // BIN|OCT|HEX|OOCT (STR2NR_ALL)

// option_expand is static — reimplement via shim FFI option_expand_o? No — it needs NameBuff.
// Reimplement faithfully here using expand_env_esc_o:
option_expand_odin :: proc "c"(opt_idx: C.int, val_in: cstring) -> ^u8 {
	o := opt_at(opt_idx)
	if (o.flags & kOptFlagExpand) == 0 || is_option_hidden(opt_idx) {
		return nil
	}
	val := val_in
	if val == nil {
		val = transmute(cstring)((^^u8)(o.varp)^)
	}
	if val == nil || libc.strlen(val) > 4096 {
		return nil
	}
	var := (^^u8)(o.varp)^
	esc := var == p_tags_g || var == p_path_g
	startesc := var == p_sps_g ? cstring("file:") : nil
	expand_env_esc(val, transmute(cstring)(&name_buff[0]), 4096,
		esc ? cstring(" \t") : nil, false, startesc)
	if libc.strcmp(transmute(cstring)(&name_buff[0]), val) == 0 {
		return nil
	}
	return &name_buff[0]
}

foreign _ {
	@(link_name = "nvim_odin_option_expand")
	option_expand_c :: proc "c" (opt_idx: C.int, val: cstring) -> ^u8 ---
}

// option_expand (static) — uses C-side option_expand via shim? No: it's fully static.
// Use my Odin version but with FFI for expand_env. Done above as option_expand_odin.

stropt_copy_value :: proc "c"(origval: cstring, argp: ^^u8, op: C.int, flags: C.uint32_t) -> ^u8 {
	arg := argp^
	newlen := libc.strlen(transmute(cstring)(arg)) + 1
	if op != OP_NONE_S {
		newlen += libc.strlen(origval) + 1
	}
	newval := (^u8)(xmalloc_sp(newlen))
	s := uintptr(newval)

	for b_at(arg, 0) != 0 && !ascii_iswhite_sp(b_at(arg, 0)) {
		if b_at(arg, 0) == '\\' && b_at(arg, 1) != 0 {
			arg = (^u8)(uintptr(arg) + 1)
		}
		i := utfc_ptr2len(transmute(cstring)(arg))
		if i > 1 {
			libc.memmove((^u8)(s), arg, C.size_t(i))
			arg = (^u8)(uintptr(arg) + uintptr(i))
			s += uintptr(i)
		} else {
			([^]u8)(transmute(^u8)(s))[0] = b_at(arg, 0)
			s += 1
			arg = (^u8)(uintptr(arg) + 1)
		}
	}
	b_set(transmute(^u8)(s), 0, 0)

	argp^ = arg
	return newval
}

ascii_iswhite_sp :: proc "c"(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

foreign _ {
	@(link_name = "option_expand4")
	option_expand_shim :: proc "c" (opt_idx: C.int, val: ^u8) -> ^u8 ---
}

stropt_expand_envvar :: proc "c"(opt_idx: C.int, origval: cstring, newval_in: ^u8, op: C.int) -> ^u8 {
	newval := newval_in
	s := option_expand_odin(opt_idx, transmute(cstring)(newval))
	if s == nil {
		return newval
	}
	xfree(newval)
	newlen := C.uint(libc.strlen(transmute(cstring)(s))) + 1
	if op != OP_NONE_S {
		newlen += C.uint(libc.strlen(origval)) + 1
	}
	newval = (^u8)(xmalloc_sp(C.size_t(newlen)))
	libc.strcpy(newval, transmute(cstring)(s))
	return newval
}

stropt_concat_with_comma :: proc "c"(origval_c: cstring, newval: ^u8, op: C.int, flags: C.uint32_t) {
	origval := transmute(^u8)(origval_c)
	comma := (flags & kOptFlagComma) != 0 && b_at(origval, 0) != 0 && b_at(newval, 0) != 0
	len := C.int(0)
	if op == OP_ADDING_S {
		len = C.int(libc.strlen(origval_c))
		if comma && len > 1 &&
		(flags & kOptFlagOneComma) == kOptFlagOneComma &&
		b_at(origval, len - 1) == ',' && b_at(origval, len - 2) != 0x5C {
			len -= 1
		}
		libc.memmove((^u8)(uintptr(newval) + uintptr(len) + uintptr(comma)), newval,
			libc.strlen(transmute(cstring)(newval)) + 1)
		libc.memmove(newval, origval, C.size_t(len))
	} else {
		len = C.int(libc.strlen(transmute(cstring)(newval)))
		libc.memmove((^u8)(uintptr(newval) + uintptr(len) + uintptr(comma)), origval,
			libc.strlen(origval_c) + 1)
	}
	if comma {
		b_set(newval, len, ',')
	}
}

stropt_remove_val :: proc "c"(origval_c: cstring, newval: ^u8, flags: C.uint32_t, strval_c: cstring, len_in: C.int) {
	origval := transmute(^u8)(origval_c)
	strv := transmute(^u8)(strval_c)
	len := len_in
	libc.strcpy(newval, origval_c)
	if b_at(strv, 0) != 0 {
		if (flags & kOptFlagComma) != 0 {
			if uintptr(strv) == uintptr(origval) {
				if b_at(strv, len) == ',' {
					len += 1
				}
			} else {
				strv = (^u8)(uintptr(strv) - 1)
				len += 1
			}
		}
		// STRMOVE(newval + (strval-origval), strval + len)
		offset := uintptr(strv) - uintptr(origval)
		libc.memmove((^u8)(uintptr(newval) + offset), (^u8)(uintptr(strv) + uintptr(len)),
			libc.strlen(transmute(cstring)((^u8)(uintptr(strv) + uintptr(len)))) + 1)
	}
}

find_dup_item_o :: proc "c"(origval_c: cstring, newval_c: cstring, newvallen: C.size_t, flags: C.uint32_t) -> cstring {
	if origval_c == nil {
		return nil
	}
	origval := transmute(^u8)(origval_c)
	newval := transmute(^u8)(newval_c)
	bs := C.int(0)

	s := uintptr(origval)
	for b_at(transmute(^u8)(s), 0) != 0 {
		ok_prefix := (flags & kOptFlagComma) == 0 || s == uintptr(origval) ||
		(b_at(transmute(^u8)(s-1), 0) == ',' && (bs & 1) == 0)
		if ok_prefix &&
		libc.strncmp(transmute(cstring)(s), newval_c, newvallen) == 0 &&
		((flags & kOptFlagComma) == 0 || b_at(transmute(^u8)(s), C.int(newvallen)) == ',' ||
		b_at(transmute(^u8)(s), C.int(newvallen)) == 0) {
			return transmute(cstring)(s)
		}
		if (s > uintptr(origval)+1 && b_at(transmute(^u8)(s-1), 0) == '\\' &&
		b_at(transmute(^u8)(s-2), 0) != ',') ||
		(s == uintptr(origval)+1 && b_at(transmute(^u8)(s-1), 0) == '\\') {
			bs += 1
		} else {
			bs = 0
		}
		s += 1
	}
	return nil
}

find_key_item :: proc "c"(src: ^u8, key: ^u8, keylen: C.ssize_t, itemlenp: ^C.ssize_t) -> ^u8 {
	p := src
	for b_at(p, 0) != 0 {
		if (p == src || b_at(p, -1) == ',') &&
		libc.memcmp(p, key, C.size_t(keylen)) == 0 {
			end := _vim_strchr(transmute(cstring)(p), ',')
			endp: ^u8
			if end == nil { endp = (^u8)(uintptr(p) + uintptr(libc.strlen(transmute(cstring)(p)))) } else { endp = transmute(^u8)(end) }
			itemlenp^ = C.ssize_t(uintptr(endp) - uintptr(p))
			return p
		}
		p = (^u8)(uintptr(p) + 1)
	}
	return nil
}

remove_comma_item :: proc "c"(str: ^u8, item: ^u8, itemlen: C.ssize_t) {
	if b_at(item, C.int(itemlen)) == ',' {
		libc.memmove(item, (^u8)(uintptr(item) + uintptr(itemlen) + 1),
			libc.strlen(transmute(cstring)((^u8)(uintptr(item) + uintptr(itemlen) + 1))) + 1)
	} else if uintptr(item) > uintptr(str) && b_at(item, -1) == ',' {
		libc.memmove((^u8)(uintptr(item) - 1), (^u8)(uintptr(item) + uintptr(itemlen)),
			libc.strlen(transmute(cstring)((^u8)(uintptr(item) + uintptr(itemlen)))) + 1)
	} else {
		b_set(item, 0, 0)
	}
}

remove_key_item :: proc "c"(str: ^u8, key: ^u8, keylen: C.ssize_t, skip: ^u8) {
	itemlen: C.ssize_t
	for true {
		found := find_key_item(str, key, keylen, &itemlen)
		if found == nil {
			break
		}
		if found == skip {
			next := (^u8)(uintptr(found) + uintptr(itemlen))
			if b_at(next, 0) == ',' {
				next = (^u8)(uintptr(next) + 1)
			}
			found = find_key_item(next, key, keylen, &itemlen)
			if found == nil {
				break
			}
		}
		remove_comma_item(str, found, itemlen)
	}
}

append_item :: proc "c"(str: ^u8, item: ^u8, item_len: C.ssize_t) {
	l := libc.strlen(transmute(cstring)(str))
	if l > 0 {
		b_set(str, C.int(l), ',')
		l += 1
	}
	libc.memmove((^u8)(uintptr(str) + uintptr(l)), item, C.size_t(item_len))
	b_set(str, C.int(l) + C.int(item_len), 0)
}

prepend_item :: proc "c"(str: ^u8, item: ^u8, item_len: C.ssize_t) {
	l := libc.strlen(transmute(cstring)(str))
	comma := l > 0 ? 1 : 0
	libc.memmove((^u8)(uintptr(str) + uintptr(item_len) + uintptr(comma)), str, l + 1)
	libc.memmove(str, item, C.size_t(item_len))
	if comma != 0 {
		b_set(str, C.int(item_len), ',')
	}
}

stropt_handle_keymatch :: proc "c"(origval: cstring, newval: ^u8, op: C.int, flags: C.uint32_t) -> bool {
	if _vim_strchr(transmute(cstring)(newval), ':') == nil &&
	_vim_strchr(transmute(cstring)(newval), ',') == nil {
		return false
	}

	newval_copy := xstrdup_r2(transmute(cstring)(newval))

	libc.strcpy(newval, origval)

	item_start := newval_copy
	for true {
		p := _vim_strchr(transmute(cstring)(item_start), ',')
		item_len: C.ssize_t = p == nil ? C.ssize_t(libc.strlen(transmute(cstring)(item_start))) :
		C.ssize_t(uintptr(transmute(^u8)(p)) - uintptr(item_start))

		if item_len > 0 {
			colon := _vim_strchr(transmute(cstring)(item_start), ':')
			if colon != nil && uintptr(transmute(^u8)(colon)) < uintptr(item_start) + uintptr(item_len) {
				keylen := C.ssize_t(uintptr(transmute(^u8)(colon)) - uintptr(item_start)) + 1

				if op == OP_ADDING_S || op == OP_PREPENDING_S {
					old_itemlen: C.ssize_t
					found := find_key_item(newval, item_start, keylen, &old_itemlen)
					if found != nil {
						if old_itemlen == item_len &&
						libc.memcmp(found, item_start, C.size_t(item_len)) == 0 {
							remove_key_item(newval, item_start, keylen, found)
						} else {
							remove_key_item(newval, item_start, keylen, nil)
							if op == OP_PREPENDING_S {
								prepend_item(newval, item_start, item_len)
							} else {
								append_item(newval, item_start, item_len)
							}
						}
					} else {
						if op == OP_PREPENDING_S {
							prepend_item(newval, item_start, item_len)
						} else {
							append_item(newval, item_start, item_len)
						}
					}
				} else if op == OP_REMOVING_S {
					remove_key_item(newval, item_start, keylen, nil)
				}
			} else {
				if op == OP_ADDING_S || op == OP_PREPENDING_S {
					found := find_dup_item_o(transmute(cstring)(newval),
						transmute(cstring)(item_start), C.size_t(item_len), kOptFlagComma)
					if found == nil {
						if op == OP_PREPENDING_S {
							prepend_item(newval, item_start, item_len)
						} else {
							append_item(newval, item_start, item_len)
						}
					}
				} else if op == OP_REMOVING_S {
					found := find_dup_item_o(transmute(cstring)(newval),
						transmute(cstring)(item_start), C.size_t(item_len), kOptFlagComma)
					if found != nil {
						remove_comma_item(newval, transmute(^u8)(found), item_len)
					}
				}
			}
		}

		if p == nil {
			break
		}
		item_start = (^u8)(uintptr(transmute(^u8)(p)) + 1)
	}

	xfree(newval_copy)

	return true
}

stropt_remove_dupflags :: proc "c"(newval: ^u8, flags: C.uint32_t) {
	s := uintptr(newval)
	for b_at(transmute(^u8)(s), 0) != 0 {
		if (flags & kOptFlagOneComma) != 0 {
			if b_at(transmute(^u8)(s), 0) != ',' && b_at(transmute(^u8)(s), 1) == ',' &&
			_vim_strchr(transmute(cstring)(^u8)(s+2), C.int(b_at(transmute(^u8)(s), 0))) != nil {
				libc.memmove(transmute(rawptr)(s), (^u8)(s+2),
					libc.strlen(transmute(cstring)(^u8)(s+2)) + 1)
				continue
			}
		} else {
			if ((flags & kOptFlagComma) == 0 || b_at(transmute(^u8)(s), 0) != ',') &&
			_vim_strchr(transmute(cstring)(^u8)(s+1), C.int(b_at(transmute(^u8)(s), 0))) != nil {
				libc.memmove(transmute(rawptr)(s), transmute(rawptr)(s+1),
					libc.strlen(transmute(cstring)(^u8)(s+1)) + 1)
				continue
			}
		}
		s += 1
	}
}

stropt_get_newval :: proc "c"(opt_idx: C.int, argp: ^^u8, varp: rawptr, origval_c: cstring,
                              op_arg: ^C.int) -> ^u8 {
	arg := argp^
	op := op_arg^
	save_arg: ^u8 = nil
	flags := opt_at(opt_idx).flags
	origval := transmute(^u8)(origval_c)

	arg = (^u8)(uintptr(arg) + 1) // jump past '=' or ':'

	// 'keywordprg': empty value → ":help"
	p_kp_addr := transmute(rawptr)(&p_kp_g)
	if varp == p_kp_addr && (b_at(arg, 0) == 0 || b_at(arg, 0) == ' ') {
		save_arg = arg
		arg = transmute(^u8)(cstring(":help"))
	}

	newval := stropt_copy_value(origval_c, &arg, op, flags)

	if op == OP_NONE_S || (flags & kOptFlagComma) != 0 {
		newval = stropt_expand_envvar(opt_idx, origval_c, newval, op)
	}

	if (flags & kOptFlagComma) != 0 && (flags & kOptFlagColon_Flag) != 0 && op != OP_NONE_S &&
	stropt_handle_keymatch(origval_c, newval, op, flags) {
		// fully handled
	} else {
		l := C.int(0)
		s: cstring = nil
		if op == OP_REMOVING_S || (flags & kOptFlagNoDup) != 0 {
			l = C.int(libc.strlen(transmute(cstring)(newval)))
			s = find_dup_item_o(origval_c, transmute(cstring)(newval), C.size_t(l), flags)

			if (op == OP_ADDING_S || op == OP_PREPENDING_S) && s != nil {
				op = OP_NONE_S
				libc.strcpy(newval, origval_c)
			}
			if s == nil {
				s = transmute(cstring)(^u8)(uintptr(origval) + uintptr(libc.strlen(origval_c)))
			}
		}

		if op == OP_ADDING_S || op == OP_PREPENDING_S {
			stropt_concat_with_comma(origval_c, newval, op, flags)
		} else if op == OP_REMOVING_S {
			stropt_remove_val(origval_c, newval, flags, s, l)
		}
	}

	if (flags & kOptFlagFlagList) != 0 {
		stropt_remove_dupflags(newval, flags)
	}

	if save_arg != nil {
		arg = save_arg
	}
	argp^ = arg
	op_arg^ = op

	return newval
}

foreign _ {
	@(link_name = "p_kp")
	p_kp_g: ^u8
}

kOptFlagColon_Flag :: 1 << 25

get_op_o :: proc "c"(arg: ^u8) -> C.int {
	op: C.int = OP_NONE_S
	if b_at(arg, 0) != 0 && b_at(arg, 1) == '=' {
		if b_at(arg, 0) == '+' {
			op = OP_ADDING_S
		} else if b_at(arg, 0) == '^' {
			op = OP_PREPENDING_S
		} else if b_at(arg, 0) == '-' {
			op = OP_REMOVING_S
		}
	}
	return op
}

get_option_prefix_o :: proc "c"(argp: ^^u8) -> C.int {
	argp_val := argp^
	if libc.strncmp(transmute(cstring)(argp_val), "no", 2) == 0 {
		argp^ = (^u8)(uintptr(argp_val) + 2)
		return 0 // PREFIX_NO
	} else if libc.strncmp(transmute(cstring)(argp_val), "inv", 3) == 0 {
		argp^ = (^u8)(uintptr(argp_val) + 3)
		return 2 // PREFIX_INV
	}
	return 1 // PREFIX_NONE
}

OPT_ONECOLUMN_S :: 0x20
OPT_WINONLY_S :: 0x08
OPT_NOWIN_S :: 0x10

find_tty_option_end_o :: proc "c"(arg: ^u8) -> ^u8 {
	if libc.strcmp(transmute(cstring)(arg), "term") == 0 {
		return (^u8)(uintptr(arg) + 4)
	} else if libc.strcmp(transmute(cstring)(arg), "ttytype") == 0 {
		return (^u8)(uintptr(arg) + 7)
	}
	p := arg
	delimit := false
	if b_at(arg, 0) == '<' {
		delimit = true
		p = (^u8)(uintptr(p) + 1)
	}
	if b_at(p, 0) == 't' && b_at(p, 1) == '_' && b_at(p, 2) != 0 && b_at(p, 3) != 0 {
		p = (^u8)(uintptr(p) + 4)
	} else if delimit {
		for b_at(p, 0) != 0 && b_at(p, 0) != '>' {
			p = (^u8)(uintptr(p) + 1)
		}
	}
	if delimit {
		if b_at(p, 0) != '>' {
			return nil
		}
		p = (^u8)(uintptr(p) + 1)
	}
	return uintptr(p) == uintptr(arg) ? nil : p
}

@(export)
find_option_end :: proc "c"(arg: ^u8, opt_idxp: ^C.int) -> ^u8 {
	p := find_tty_option_end_o(arg)
	if p != nil {
		opt_idxp^ = kOptInvalid_OPT
		return p
	}
	p = arg

	c := b_at(p, 0)
	if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
		opt_idxp^ = kOptInvalid_OPT
		return nil
	}
	for {
		c = b_at(p, 0)
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			break
		}
		p = (^u8)(uintptr(p) + 1)
	}

	opt_idxp^ = nvim_odin_find_option_len(transmute(cstring)(arg), C.size_t(uintptr(p) - uintptr(arg)))
	return p
}

validate_opt_idx_o :: proc "c"(win: rawptr, opt_idx: C.int, opt_flags: C.int, flags: C.uint32_t,
                               prefix: C.int, errmsg: ^cstring) -> bool {
	if !option_has_type(opt_idx, kOptValTypeBoolean) && prefix != 1 { // PREFIX_NONE
		errmsg^ = cstring("E474: Invalid argument") // e_invarg
		return false
	}
	if (opt_flags & OPT_WINONLY_S) != 0 && !option_is_window_local(opt_idx) {
		return false
	}
	if (opt_flags & OPT_NOWIN_S) != 0 && option_is_window_local(opt_idx) {
		return false
	}
	if (opt_flags & OPT_MODELINE_S) != 0 {
		if (flags & kOptFlagSecure) != 0 {
			errmsg^ = cstring("E520: Not allowed to set this option in a modeline")
			return false
		}
		if (flags & kOptFlagMLE) != 0 && p_mle_opt == 0 {
			errmsg^ = cstring("E1251: Not allowed to set this option in a modeline when 'modelineexpr' is off")
			return false
		}
		w_p_diff := (^C.int)(uintptr(win) + W_P_DIFF_OFF)^
		if w_p_diff != 0 && (opt_idx == 109 || opt_idx == 370) { // kOptFoldmethod=107, kOptWrap=375?
			return false
		}
	}
	if sandbox != 0 && (flags & kOptFlagSecure) != 0 {
		errmsg^ = e_sandbox_s
		return false
	}
	return true
}

W_P_DIFF_OFF :: 832

get_option_newval_o :: proc "c"(
	opt_idx: C.int,
	opt_flags: C.int,
	prefix: C.int,
	argp: ^^u8,
	nextchar: C.int,
	op_in: C.int,
	flags: C.uint32_t,
	varp: rawptr,
	oldval_override: ^OptVal,
	errbuf: ^u8,
	errbuflen: C.size_t,
	errmsg: ^cstring,
) -> OptVal {
	op := op_in
	opt := opt_at(opt_idx)
	arg := argp^

	oldval: OptVal
	if oldval_override != nil {
		oldval = oldval_override^
	} else {
		oldval_is_global := option_is_global_local_i(opt_idx) && (opt_flags & OPT_LOCAL_S) != 0
		oldval = optval_from_varp(opt_idx,
			oldval_is_global ? nvim_odin_get_varp_from(opt_idx, curbuf, curwin) : varp)
	}

	newval := nil_optval()

	if nextchar == '&' {
		return optval_copy(get_option_default_o(opt_idx, OPT_GLOBAL_S))
	} else if nextchar == '<' {
		if option_is_global_local_i(opt_idx) && (opt_flags & OPT_LOCAL_S) == 0 {
			unset_option_local_value_o(opt_idx)
		}
		return get_option_value(opt_idx, OPT_GLOBAL_S)
	}

	switch oldval.typ {
	case kOptValTypeBoolean:
		newval_bool: C.int
		if nextchar == '!' {
			ob := ov_boolean(&oldval)^
			if ob == -1 {
				newval_bool = -1
			} else if ob == 1 {
				newval_bool = 0
			} else {
				newval_bool = 1
			}
		} else {
			if prefix == 2 { // PREFIX_INV
				// ":set invopt": invert — *(int*)varp ^ 1
				cur_val := (^C.int)(varp)^
				newval_bool = C.int(C.uint(cur_val) ~ C.uint(1))
			} else {
				newval_bool = prefix == 0 ? 0 : 1
			}
		}
		newval = bool_optval(newval_bool)
	case kOptValTypeNumber:
		oldval_num := ov_number(&oldval)^
		newval_num: C.longlong

		arg = (^u8)(uintptr(arg) + 1)
		p_wc_addr := transmute(rawptr)(&p_wc_g)
		p_wcm_addr := transmute(rawptr)(&p_wcm_g)
		is_wc := varp == p_wc_addr || varp == p_wcm_addr
		c0 := b_at(arg, 0)
		if is_wc && (c0 == '<' || c0 == '^' ||
		(c0 != 0 && (b_at(arg, 1) == 0 || ascii_iswhite_sp(b_at(arg, 1))) && !ascii_isdigit_sp(c0))) {
			newval_num = C.longlong(string_to_key(arg))
			if newval_num == 0 {
				errmsg^ = cstring("E474: Invalid argument")
				return newval
			}
		} else if c0 == '-' || ascii_isdigit_sp(c0) {
			i := C.int(0)
			vim_str2nr_r(transmute(cstring)(arg), nil, &i, STR2NR_ALL_S, &newval_num, nil, 0, true, nil)
			if i == 0 || (b_at(arg, i) != 0 && !ascii_iswhite_sp(b_at(arg, i))) {
				errmsg^ = cstring("E521: Number required after =")
				return newval
			}
		} else {
			errmsg^ = cstring("E521: Number required after =")
			return newval
		}

		if op == OP_ADDING_S {
			newval_num = oldval_num + newval_num
		}
		if op == OP_PREPENDING_S {
			newval_num = oldval_num * newval_num
		}
		if op == OP_REMOVING_S {
			newval_num = oldval_num - newval_num
		}

		newval = num_optval(newval_num)
	case kOptValTypeString:
		oldval_str := ov_str_data(&oldval)
		newval_str := stropt_get_newval(opt_idx, argp, varp, transmute(cstring)(oldval_str), &op)
		newval = str_optval(newval_str, libc.strlen(transmute(cstring)(newval_str)))
	case:
	}

	return newval
}

foreign _ {
	@(link_name = "p_wc")
	p_wc_g: C.longlong
	@(link_name = "p_wcm")
	p_wcm_g: C.longlong
}

ascii_isdigit_sp :: proc "c"(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

ROOT_UID :: 0

get_option_default_o :: proc "c"(opt_idx: C.int, opt_flags: C.int) -> OptVal {
	opt := opt_at(opt_idx)
	is_global_local := option_is_global_local_i(opt_idx)

	if opt_idx == 191 { // kOptModeline
		// verify below; use 216 for now
		if getuid_r() == ROOT_UID {
			return bool_optval(0)
		}
	}

	if (opt_flags & OPT_LOCAL_S) != 0 && is_global_local {
		return get_option_unset_value_o(opt_idx)
	} else if opt.typ == kOptValTypeString && (opt.flags & kOptFlagNoDefExp) == 0 {
		def_str := (^^u8)(&opt.def_val.data)^
		s := option_expand_odin(opt_idx, transmute(cstring)(def_str))
		if s == nil {
			return opt.def_val
		}
		return str_optval(s, libc.strlen(transmute(cstring)(s)))
	}
	return opt.def_val
}

unset_option_local_value_o :: proc "c"(opt_idx: C.int) -> cstring {
	return set_option_value(opt_idx, get_option_unset_value_o(opt_idx), OPT_LOCAL_S)
}

foreign _ {
	// msg_advance reuse digraph.odin; message_filtered reuse mark.odin;
	// p_verbose reuse shell.odin; info_message declared above.
	@(link_name = "info_message")
	info_message_g2: bool
}


// option_value2string (static, option.c 6398-6425)
option_value2string_o :: proc "c"(opt: ^vimoption_T, opt_flags: C.int) {
	varp := nvim_odin_get_varp_scope(get_opt_idx_o(opt), opt_flags)

	if option_has_type(get_opt_idx_o(opt), kOptValTypeNumber) {
		wc: C.longlong = 0
		if wc_use_keyname_o(varp, &wc) {
			libc.strcpy(&name_buff[0],
				transmute(cstring)(get_special_key_name_r(C.int(wc), 0)))
		} else if wc != 0 {
			libc.strcpy(&name_buff[0],
				transmute(cstring)(transchar_o(C.int(wc))))
		} else {
			libc.snprintf(&name_buff[0], 4096, "%lld", ov_number_from_varp(varp))
		}
	} else {
		strv := (^^u8)(varp)^
		if (opt.flags & kOptFlagExpand) != 0 {
			if strv != nil {
				home_replace(nil, transmute(cstring)(strv), transmute(cstring)(&name_buff[0]), 4096, false)
			}
		} else if strv != nil {
			xstrlcpy_o(transmute(cstring)(&name_buff[0]), transmute(cstring)(strv), 4096)
		} else {
			b_set(&name_buff[0], 0, 0)
		}
	}
}

ov_number_from_varp :: proc "c"(varp: rawptr) -> C.longlong {
	return (^C.longlong)(varp)^
}

wc_use_keyname_o :: proc "c"(varp: rawptr, wcp: ^C.longlong) -> bool {
	p_wc_addr := transmute(rawptr)(&p_wc_g)
	p_wcm_addr := transmute(rawptr)(&p_wcm_g)
	if varp == p_wc_addr || varp == p_wcm_addr {
		wcp^ = (^C.longlong)(varp)^
		if IS_SPECIAL_S(wcp^) || find_special_key_in_table_r(C.int(wcp^)) >= 0 {
			return true
		}
	}
	return false
}

IS_SPECIAL_S :: proc "c"(c: C.longlong) -> bool {
	return c < 0 // IS_SPECIAL: special keys are negative (K_ macros)
}

@(export)
get_tty_option :: proc "c"(name: cstring) -> OptVal {
	value: ^u8 = nil

	if libc.strcmp(name, "t_Co") == 0 {
		if t_colors_g <= 1 {
			value = xstrdup_r2(cstring(""))
		} else {
			value = (^u8)(xmalloc_sp(32))
			libc.snprintf(value, 32, "%d", t_colors_g)
		}
	} else if libc.strcmp(name, "term") == 0 {
		value = p_term_g != nil ? xstrdup_r2(transmute(cstring)(p_term_g)) : xstrdup_r2(cstring("nvim"))
	} else if libc.strcmp(name, "ttytype") == 0 {
		value = p_ttytype_g != nil ? xstrdup_r2(transmute(cstring)(p_ttytype_g)) : xstrdup_r2(cstring("nvim"))
	} else if is_tty_option_r(name) {
		value = xstrdup_r2(cstring(""))
	}

	if value == nil {
		return nil_optval()
	}
	return str_optval(value, libc.strlen(transmute(cstring)(value)))
}

foreign _ {
	@(link_name = "t_colors")
	t_colors_g: C.int
	@(link_name = "nvim_odin_get_p_term")
	p_term_g: ^u8
	@(link_name = "nvim_odin_get_p_ttytype")
	p_ttytype_g: ^u8
}

@(export)
set_tty_option :: proc "c"(name: cstring, value: ^u8) -> bool {
	if libc.strcmp(name, "term") == 0 {
		if p_term_g != nil {
			xfree(p_term_g)
		}
		p_term_g = value
		return true
	}
	if libc.strcmp(name, "ttytype") == 0 {
		if p_ttytype_g != nil {
			xfree(p_ttytype_g)
		}
		p_ttytype_g = value
		return true
	}
	return false
}

@(export)
is_tty_option :: proc "c"(name: cstring) -> bool {
	return find_tty_option_end_o(transmute(^u8)(name)) != nil
}

optval_default_o :: proc "c"(opt_idx: C.int, varp: rawptr) -> bool {
	if is_option_hidden(opt_idx) {
		return true
	}
	current_val := optval_from_varp(opt_idx, varp)
	default_val := opt_at(opt_idx).def_val
	return optval_equal(current_val, default_val)
}

@(export)
ui_refresh_options :: proc "c"() {
	for opt_idx := C.int(0); opt_idx < nvim_odin_opt_count(); opt_idx += 1 {
		flags := opt_at(opt_idx).flags
		if (flags & kOptFlagUIOption) == 0 {
			continue
		}
		name := transmute(cstring)(opt_at(opt_idx).fullname)
		value := optval_as_object_o(optval_from_varp(opt_idx, opt_at(opt_idx).varp))
		ui_call_option_set_r(name, transmute(rawptr)(&value))
	}
	if p_mouse_g != nil {
		setmouse()
	}
}

showoneopt_o :: proc "c"(opt: ^vimoption_T, opt_flags: C.int) {
	save_silent := silent_mode

	silent_mode = false
	info_message_g2 = true

	opt_idx := get_opt_idx_o(opt)
	varp := nvim_odin_get_varp_scope(opt_idx, opt_flags)

	if option_has_type(opt_idx, kOptValTypeBoolean) {
		is_b_changed := varp == transmute(rawptr)(uintptr(curbuf) + BUF_CHANGED_OFF)
		not_set := is_b_changed ? !curbufIsChanged() : (^C.int)(varp)^ == 0
		if not_set {
			msg_puts_s(cstring("no"))
		} else if (^C.int)(varp)^ < 0 {
			msg_puts_s(cstring("--"))
		} else {
			msg_puts_s(cstring("  "))
		}
	} else {
		msg_puts_s(cstring("  "))
	}
	msg_puts_s(transmute(cstring)(opt.fullname))
	if !option_has_type(opt_idx, kOptValTypeBoolean) {
		msg_putchar('=')
		option_value2string_o(opt, opt_flags)
		if b_at(&name_buff[0], 0) != 0 {
			_ = msg_outtrans_s(transmute(cstring)(&name_buff[0]), 0, false)
		}
	}

	silent_mode = save_silent
	info_message_g2 = false
}

showoptions_o :: proc "c"(all: bool, opt_flags: C.int) {
	INC :: 20
	GAP :: 3

	items := (^rawptr)(xmalloc_sp(size_of(rawptr) * C.size_t(nvim_odin_opt_count())))

	msg_ext_set_kind(cstring("list_cmd"))
	if (opt_flags & OPT_GLOBAL_S) != 0 {
		msg_puts_title_s("--- Global option values ---")
	} else if (opt_flags & OPT_LOCAL_S) != 0 {
		msg_puts_title_s("--- Local option values ---")
	} else {
		msg_puts_title_s("--- Options ---")
	}

	for run := C.int(1); run <= 2 && !got_int; run += 1 {
		item_count := C.int(0)
		for opt_idx := C.int(0); opt_idx < nvim_odin_opt_count(); opt_idx += 1 {
			opt := opt_at(opt_idx)
			if message_filtered(transmute(cstring)(opt.fullname)) {
				continue
			}
			varp: rawptr = nil
			if (opt_flags & (OPT_LOCAL_S | OPT_GLOBAL_S)) != 0 {
				if !option_is_global_only(opt_idx) {
					varp = nvim_odin_get_varp_scope(opt_idx, opt_flags)
				}
			} else {
				varp = nvim_odin_get_varp_from(opt_idx, curbuf, curwin)
			}
			if varp != nil && (all || !optval_default_o(opt_idx, varp)) {
				l := C.int(0)
				if (opt_flags & OPT_ONECOLUMN_S) != 0 {
					l = Columns_opt()
				} else if option_has_type(opt_idx, kOptValTypeBoolean) {
					l = 1
				} else {
					option_value2string_o(opt, opt_flags)
					l = C.int(libc.strlen(transmute(cstring)(opt.fullname))) +
					vim_strsize_r(transmute(cstring)(&name_buff[0])) + 1
				}
				if (l <= INC - GAP && run == 1) || (l > INC - GAP && run == 2) {
					(^rawptr)(uintptr(items) + uintptr(item_count) * size_of(rawptr))^ = opt
					item_count += 1
				}
			}
		}

		rows := C.int(0)
		if run == 1 {
			cols := (Columns_opt() + GAP - 3) / INC
			if cols == 0 {
				cols = 1
			}
			rows = (item_count + cols - 1) / cols
		} else {
			rows = item_count
		}
		for row := C.int(0); row < rows && !got_int; row += 1 {
			msg_putchar('\n')
			if got_int {
				break
			}
			col := C.int(0)
			for i := row; i < item_count; i += rows {
				msg_advance(col)
				itm := (^rawptr)(uintptr(items) + uintptr(i) * size_of(rawptr))^
				showoneopt_o((^vimoption_T)(itm), opt_flags)
				col += INC
			}
			os_breakcheck()
		}
	}
	xfree(items)
}

foreign _ {
	@(link_name = "vim_strsize")
	vim_strsize_r :: proc "c" (s: cstring) -> C.int ---
}

Columns_opt :: proc "c"() -> C.int {
	return Columns
}

foreign _ {
	@(link_name = "showoneopt3")
	_showoneopt_unused: u8 // removed below; showoneopt_o covers it
	@(link_name = "msg_ext_set_kind2")
	_msgkind_unused: u8
}

// do_one_set_option (static, option.c 1451-1560)
do_one_set_option_o :: proc "c"(
	opt_flags: C.int,
	argp: ^^u8,
	did_show: ^bool,
	errbuf: ^u8,
	errbuflen: C.size_t,
	errmsg: ^cstring,
) {
	// 1: nothing, 0: "no", 2: "inv"
	prefix := get_option_prefix_o(argp)

	arg := argp^

	opt_idx: C.int
	option_end := find_option_end(arg, &opt_idx)

	if opt_idx != kOptInvalid_OPT {
		// ok
	} else if find_tty_option_end_o(arg) != nil {
		return
	} else {
		errmsg^ = cstring("E518: Unknown option")
		return
	}

	afterchar := b_at(option_end, 0)
	p := option_end

	for ascii_iswhite_sp(b_at(p, 0)) {
		p = (^u8)(uintptr(p) + 1)
	}

	op := get_op_o(p)
	if op != OP_NONE_S {
		p = (^u8)(uintptr(p) + 1)
	}

	nextchar := b_at(p, 0)
	flags := opt_at(opt_idx).flags
	varp := nvim_odin_get_varp_scope(opt_idx, opt_flags)

	if !validate_opt_idx_o(curwin, opt_idx, opt_flags, flags, prefix, errmsg) {
		return
	}

	if _vim_strchr(cstring("?=:!&<"), C.int(nextchar)) != nil {
		argp^ = p
		if nextchar == '&' && b_at(argp^, 1) == 'v' && b_at(argp^, 2) == 'i' {
			if b_at(argp^, 3) == 'm' { // "opt&vim"
				argp^ = (^u8)(uintptr(argp^) + 3)
			} else { // "opt&vi"
				argp^ = (^u8)(uintptr(argp^) + 2)
			}
		}
		if _vim_strchr(cstring("?!&<"), C.int(nextchar)) != nil &&
		b_at(argp^, 1) != 0 && !ascii_iswhite_sp(b_at(argp^, 1)) {
			errmsg^ = cstring("E488: Trailing characters")
			return
		}
	}

	if nextchar == '?' ||
	(prefix == 1 && _vim_strchr(cstring("=:&<"), C.int(nextchar)) == nil &&
	!option_has_type(opt_idx, kOptValTypeBoolean)) {
		// print value
		if did_show^ {
			msg_putchar('\n')
		} else {
			msg_ext_set_kind(cstring("list_cmd"))
			gotocmdline_r(true)
			did_show^ = true
		}
		showoneopt_o(opt_at(opt_idx), opt_flags)

		if p_verbose > 0 {
			if varp == opt_at(opt_idx).varp {
				sctx_tmp := (^sctx_T)(&opt_at(opt_idx).script_ctx_buf[0])^; last_set_msg_r(sctx_tmp)
			} else if option_has_scope(opt_idx, kOptScopeWin_S) {
				addr := uintptr(curwin) + W_P_SCRIPT_CTX_OFF +
				uintptr(option_scope_idx(opt_idx, kOptScopeWin_S)) * SCCTX_STRIDE
				sctx_win := (^sctx_T)(addr)^
				last_set_msg_r(sctx_win)
			} else if option_has_scope(opt_idx, kOptScopeBuf_S) {
				addr := uintptr(curbuf) + B_P_SCRIPT_CTX_OFF +
				uintptr(option_scope_idx(opt_idx, kOptScopeBuf_S)) * SCCTX_STRIDE
				sctx_buf2 := (^sctx_T)(addr)^
				last_set_msg_r(sctx_buf2)
			}
		}

		if nextchar != '?' && nextchar != 0 && !ascii_iswhite_sp(afterchar) {
			errmsg^ = cstring("E488: Trailing characters")
		}
		return
	}

	if option_has_type(opt_idx, kOptValTypeBoolean) {
		if _vim_strchr(cstring("=:"), C.int(nextchar)) != nil {
			errmsg^ = cstring("E474: Invalid argument")
			return
		}
		if _vim_strchr(cstring("?!&<"), C.int(nextchar)) == nil && nextchar != 0 &&
		!ascii_iswhite_sp(afterchar) {
			errmsg^ = cstring("E488: Trailing characters")
			return
		}
	} else {
		if _vim_strchr(cstring("=:&<"), C.int(nextchar)) == nil {
			errmsg^ = cstring("E474: Invalid argument")
			return
		}
	}

	newval := get_option_newval_o(opt_idx, opt_flags, prefix, argp, C.int(nextchar), op, flags,
		varp, nil, errbuf, errbuflen, errmsg)

	if newval.typ == kOptValTypeNil || errmsg^ != nil {
		return
	}

	errmsg^ = set_option_o(opt_idx, newval, opt_flags, 0, false, op == OP_NONE_S, errbuf, errbuflen)
}

foreign _ {
	@(link_name = "win_comp_scroll")
	win_comp_scroll_r :: proc "c" (wp: rawptr) ---
	@(link_name = "parse_cino")
	parse_cino_r :: proc "c" (buf: rawptr) ---
	@(link_name = "didset_string_options")
	didset_string_options_r :: proc "c" () ---
	@(link_name = "parse_shape_opt")
	parse_shape_opt_r :: proc "c" (shape: C.int) -> cstring ---
	@(link_name = "last_status")
	last_status_r :: proc "c" (more: bool) ---
	@(link_name = "win_float_update_statusline")
	win_float_update_statusline_r :: proc "c" (wp: rawptr) ---
	@(link_name = "win_new_screen_rows")
	win_new_screen_rows_r :: proc "c" () ---
	@(link_name = "check_string_option")
	check_string_option_r :: proc "c" (varp: ^u8) ---
}

SHAPE_CURSOR_S :: 0

set_option_default_o :: proc "c"(opt_idx: C.int, opt_flags: C.int) {
	both := (opt_flags & (OPT_LOCAL_S | OPT_GLOBAL_S)) == 0
	def_val := get_option_default_o(opt_idx, opt_flags)
	set_option_direct(opt_idx, def_val, opt_flags, current_sctx_sc_sid())

	if opt_idx == kOptScroll_E {
		win_comp_scroll_r(curwin)
	}

	flagsp := insecure_flag_c(curwin, opt_idx, opt_flags)
	flagsp^ = flagsp^ & ~C.uint32_t(kOptFlagInsecure)
	if both {
		flagsp2 := insecure_flag_c(curwin, opt_idx, OPT_LOCAL_S)
		flagsp2^ = flagsp2^ & ~C.uint32_t(kOptFlagInsecure)
	}
}

current_sctx_sc_sid :: proc "c"() -> C.int {
	return (^C.int)(uintptr(&current_sctx_buf[0]))^ // sc_sid@0
}

@(export)
check_options :: proc "c"() {
	for opt_idx := C.int(0); opt_idx < nvim_odin_opt_count(); opt_idx += 1 {
		if option_has_type(opt_idx, kOptValTypeString) && opt_at(opt_idx).varp != nil {
			check_string_option_r(transmute(^u8)(opt_at(opt_idx).varp))
		}
	}
}

set_options_default_o :: proc "c"(opt_flags: C.int) {
	for opt_idx := C.int(0); opt_idx < nvim_odin_opt_count(); opt_idx += 1 {
		if (opt_at(opt_idx).flags & kOptFlagNoDefault) == 0 {
			set_option_default_o(opt_idx, opt_flags)
		}
	}
	// FOR_ALL_TAB_WINDOWS: win_comp_scroll for every window
	tp := curtab
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^
		for wp != nil {
			win_comp_scroll_r(wp)
			wp = (^rawptr)(uintptr(wp) + 112)^
		}
		tp = (^rawptr)(uintptr(tp) + 8)^ // tp_next @8
	}
	parse_cino_r(curbuf)
}

didset_options_o :: proc "c"() {
	init_chartab_r()
	didset_string_options_r()
	spell_check_msm_r()
	spell_check_sps_r()
	compile_cap_prog(win_s_r(curwin))
	_ = did_set_spell_option()
	_ = did_set_cedit_r(nil)
	_ = did_set_breakat_r(nil)
	didset_window_options_r(curwin, true)
}

didset_options2_o :: proc "c"() {
	highlight_changed_r()
	set_chars_option_o(curwin, (^u8)(uintptr(curwin) + 1208), 0, true, nil, 0) // w_p_fcs
	set_chars_option_o(curwin, (^u8)(uintptr(curwin) + 1200), 1, true, nil, 0) // w_p_lcs
	_ = check_opt_wim_r()
	vsts_arr := transmute(^^u8)(uintptr(curbuf) + 10760)
	xfree(vsts_arr^)
	tabstop_set_o((^^u8)(uintptr(curbuf) + 10752)^, vsts_arr)
	vts_arr := transmute(^^u8)(uintptr(curbuf) + 10784)
	xfree(vts_arr^)
	tabstop_set_o((^^u8)(uintptr(curbuf) + 10776)^, vts_arr)
}

didset_options_all_o :: proc "c"() {
	_ = parse_shape_opt_r(SHAPE_CURSOR_S)
	last_status_r(false)
	win_float_update_statusline_r(nil)
	win_new_screen_rows_r()
}

@(export)
do_set :: proc "c"(arg_in: ^u8, opt_flags: C.int) -> C.int {
	arg := arg_in
	did_show := false

	if b_at(arg, 0) == 0 {
		showoptions_o(false, opt_flags)
		did_show = true
	} else {
		for b_at(arg, 0) != 0 {
			if libc.strncmp(transmute(cstring)(arg), "all", 3) == 0 &&
			!ascii_isalpha_sp(b_at(arg, 3)) && (opt_flags & OPT_MODELINE_S) == 0 {
				arg = (^u8)(uintptr(arg) + 3)
				if b_at(arg, 0) == '&' {
					arg = (^u8)(uintptr(arg) + 1)
					set_options_default_o(opt_flags)
					didset_options_all_o()
					didset_options_o()
					didset_options2_o()
					ui_refresh_options()
					redraw_all_later_o(40) // UPD_CLEAR=40? verify: UPD_NOT_VALID=40; UPD_CLEAR separate
				} else {
					showoptions_o(true, opt_flags)
					did_show = true
				}
			} else {
				startarg := arg
				errmsg: cstring = nil
				errbuf: [1025]u8

				do_one_set_option_o(opt_flags, &arg, &did_show, &errbuf[0], 1025, &errmsg)

				for i := C.int(0); i < 2; i += 1 {
					a := skiptowhite_esc_r(transmute(cstring)(arg))
					arg = transmute(^u8)(a)
					arg = transmute(^u8)(skipwhite(transmute(cstring)(arg)))
					if b_at(arg, 0) != '=' {
						break
					}
				}

				if errmsg != nil {
					i := C.int(libc.snprintf(&IObuff[0], 1025, "%s", errmsg)) + 2
					if uintptr(i) + (uintptr(arg) - uintptr(startarg)) < 1025 {
						libc.strncpy((^u8)(uintptr(&IObuff[0]) + uintptr(i-2)), ": ",
							C.size_t(1025) - C.size_t(i) + 2)
						movelen := C.size_t(uintptr(arg) - uintptr(startarg))
						libc.memmove((^u8)(uintptr(&IObuff[0]) + uintptr(i)), startarg,
							movelen)
						b_set(&IObuff[0], i + C.int(movelen), 0)
					}
					trans_characters_o(&IObuff[0], 1025)

					no_wait_return = true
					emsg(transmute(cstring)(&IObuff[0]))
					no_wait_return = false

					return 0 // FAIL
				}
			}

			arg = transmute(^u8)(skipwhite(transmute(cstring)(arg)))
		}
	}

	if silent_mode && did_show {
		silent_mode = false
		info_message_g2 = true
		msg_putchar('\n')
		silent_mode = true
		info_message_g2 = false
	}

	return 1 // OK
}

// IObuff reuse os_signal.odin's [1025]u8 foreign var.

@(export)
ex_set :: proc "c"(eap: rawptr) {
	flags := C.int(0)
	cmdidx := (^C.int)(uintptr(eap) + 64)^ // exarg_T.cmdidx @64

	if cmdidx == 405 { // CMD_setlocal
		flags = OPT_LOCAL_S
	} else if cmdidx == 404 { // CMD_setglobal
		flags = OPT_GLOBAL_S
	}
	forceit := (^C.int)(uintptr(eap) + 76)^ != 0
	if forceit {
		flags |= OPT_ONECOLUMN_S
	}
	arg := (^^u8)(uintptr(eap) + 0)^ // eap.arg @0
	do_set(arg, flags)
}

foreign _ {
	@(link_name = "nvim_odin_set_init_1")
	nvim_odin_set_init_1 :: proc "c" (clean_arg: bool) ---
	@(link_name = "nvim_odin_set_init_2")
	nvim_odin_set_init_2 :: proc "c" (headless: bool) ---
	@(link_name = "nvim_odin_set_init_3")
	nvim_odin_set_init_3 :: proc "c" () ---
}

foreign _ {
	@(link_name = "callback_free")
	callback_free_r :: proc "c" (cb: rawptr) ---
	@(link_name = "callback_from_typval")
	callback_from_typval_r :: proc "c" (cb: rawptr, tv: rawptr) -> bool ---
	@(link_name = "tv_free")
	tv_free_r :: proc "c" (tv: rawptr) ---
	@(link_name = "eval_expr")
	eval_expr_r :: proc "c" (arg: cstring, arg2: rawptr) -> rawptr ---
	@(link_name = "xcalloc")
	xcalloc_o :: proc "c" (n: C.size_t, sz: C.size_t) -> rawptr ---
}

// Callback mirror: {type int, data union} — typval_T is 24B (v_type@0,v_lock@4,vval@8)
VAR_STRING_S :: 2
kCallbackNone_S :: -1

@(export)
option_set_callback_func :: proc "c"(optval: ^u8, optcb: rawptr) -> C.int {
	if optval == nil || b_at(optval, 0) == 0 {
		callback_free_r(optcb)
		return 1 // OK
	}

	tv_ptr: rawptr
	c0 := b_at(optval, 0)
	if c0 == '{' ||
	libc.strncmp(transmute(cstring)(optval), "function(", 9) == 0 ||
	libc.strncmp(transmute(cstring)(optval), "funcref(", 8) == 0 {
		tv_ptr = eval_expr_r(transmute(cstring)(optval), nil)
		if tv_ptr == nil {
			return 0 // FAIL
		}
	} else {
		tv_ptr = xcalloc_o(1, 24) // sizeof(typval_T)=24
		(^C.int)(tv_ptr)^ = VAR_STRING_S
		(^^u8)(uintptr(tv_ptr) + 8)^ = xstrdup_r2(transmute(cstring)(optval))
	}

	cb_buf: [24]u8
	if !callback_from_typval_r(&cb_buf[0], tv_ptr) ||
	(^C.int)(&cb_buf[0])^ == kCallbackNone_S {
		tv_free_r(tv_ptr)
		return 0 // FAIL
	}

	callback_free_r(optcb)
	libc.memcpy(optcb, &cb_buf[0], size_of(cb_buf))
	tv_free_r(tv_ptr)
	return 1 // OK
}

foreign _ {
}

foreign _ {
	@(link_name = "put_escstr")
	put_escstr_r :: proc "c" (fd: ^libc.FILE, s: cstring, nul_from: C.int) -> C.int ---
}

OPT_SKIPRTP_S :: 0x80

kOptSyntax_IDX :: 254 // probe below
kOptFiletype_IDX :: 103
kOptRtp_IDX :: 236
kOptPp_IDX :: 222

// put_set (static, option.c 4795-4870)
put_set_o :: proc "c"(fd: ^libc.FILE, cmd: cstring, opt_idx: C.int, varp: rawptr) -> C.int {
	value := optval_from_varp(opt_idx, varp)
	opt := opt_at(opt_idx)
	name := transmute(cstring)(opt.fullname)
	flags := opt.flags

	if option_is_global_local_i(opt_idx) && varp != opt.varp &&
	optval_equal(value, get_option_unset_value_o(opt_idx)) {
		return 1 // OK
	}

	switch value.typ {
	case kOptValTypeBoolean:
		vb := ov_boolean(&value)^
		value_bool := vb != 0 // TRISTATE_TO_BOOL(v,false): true if v!=0? actually kTrue=1→true; kFalse=0→false
		if libc.fprintf(transmute(^libc.FILE)(fd), "%s %s%s\n", cmd,
			value_bool ? "" : "no", name) < 0 {
			return 0
		}
	case kOptValTypeNumber:
		if libc.fprintf(transmute(^libc.FILE)(fd), "%s %s=", cmd, name) < 0 {
			return 0
		}
		value_num := ov_number(&value)^
		if wc_use_keyname_o(varp, &value_num) {
			keyname := get_special_key_name_r(C.int(value_num), 0)
			fputs_o(transmute(cstring)(keyname), transmute(^libc.FILE)(fd))
		} else {
			libc.fprintf(transmute(^libc.FILE)(fd), "%lld", value_num)
		}
	case kOptValTypeString:
		if libc.fprintf(transmute(^libc.FILE)(fd), "%s %s=", cmd, name) < 0 {
			return 0
		}
		value_str := ov_str_data(&value)
		buf: ^u8 = nil
		part: ^u8 = nil
		if value_str != nil {
			if (flags & kOptFlagExpand) != 0 {
				size := libc.strlen(transmute(cstring)(value_str)) + 1
				buf = (^u8)(xmalloc_sp(size))
				home_replace(nil, transmute(cstring)(value_str), transmute(cstring)(buf), size, false)
				if size >= 4096 && (flags & kOptFlagComma) != 0 &&
				_vim_strchr(transmute(cstring)(value_str), ',') != nil {
					part = (^u8)(xmalloc_sp(size))
					if put_eol_r(transmute(^libc.FILE)(fd)) == 0 {
						xfree(buf); xfree(part); return 0
					}
					p := buf
					for b_at(p, 0) != 0 {
						if libc.fprintf(transmute(^libc.FILE)(fd), "%s %s+=", cmd, name) < 0 {
							xfree(buf); xfree(part); return 0
						}
						p2 := skip_to_option_part(p)
						part_len := uintptr(p2) - uintptr(p)
						part_len_bytes := C.size_t(uintptr(p2) - uintptr(p))
						libc.memcpy(part, p, min(part_len_bytes, size))
						b_set(part, C.int(part_len), 0)
						if put_escstr_r(transmute(^libc.FILE)(fd), transmute(cstring)(part), 2) == 0 || put_eol_r(transmute(^libc.FILE)(fd)) == 0 {
							xfree(buf); xfree(part); return 0
						}
						p = p2
					}
					xfree(buf); xfree(part)
					return 1
				}
				if put_escstr_r(transmute(^libc.FILE)(fd), transmute(cstring)(buf), 2) == 0 {
					xfree(buf)
					return 0
				}
				xfree(buf)
			} else {
				if put_escstr_r(transmute(^libc.FILE)(fd), transmute(cstring)(value_str), 2) == 0 {
					return 0
				}
			}
		}
	case:
		libc.abort()
	}
	return put_eol_r(transmute(^libc.FILE)(fd))
}

@(export)
makefoldset :: proc "c"(fd: ^libc.FILE) -> C.int {
	if put_set_o(fd, "setlocal", 109, (^rawptr)(uintptr(curwin) + 896)) == 0 { return 0 } // foldmethod
	if put_set_o(fd, "setlocal", 104, (^rawptr)(uintptr(curwin) + 928)) == 0 { return 0 } // foldexpr
	if put_set_o(fd, "setlocal", 108, (^rawptr)(uintptr(curwin) + 944)) == 0 { return 0 } // foldmarker
	if put_set_o(fd, "setlocal", 105, (^rawptr)(uintptr(curwin) + 872)) == 0 { return 0 } // foldignore
	if put_set_o(fd, "setlocal", 106, (^rawptr)(uintptr(curwin) + 880)) == 0 { return 0 } // foldlevel
	if put_set_o(fd, "setlocal", 110, (^rawptr)(uintptr(curwin) + 912)) == 0 { return 0 } // foldminlines
	if put_set_o(fd, "setlocal", 111, (^rawptr)(uintptr(curwin) + 920)) == 0 { return 0 } // foldnestmax
	if put_set_o(fd, "setlocal", 103, (^rawptr)(uintptr(curwin) + 864)) == 0 { return 0 } // foldenable
	return 1
}

@(export)
makeset :: proc "c"(fd: ^libc.FILE, opt_flags: C.int, local_only: bool) -> C.int {
	for pri := C.int(1); pri >= 0; pri -= 1 {
		for opt_idx := C.int(0); opt_idx < nvim_odin_opt_count(); opt_idx += 1 {
			opt := opt_at(opt_idx)

			if (opt.flags & kOptFlagNoMkrc) == 0 &&
			((pri == 1) == ((opt.flags & kOptFlagPriMkrc) != 0)) {
				if option_is_global_only(opt_idx) && (opt_flags & OPT_GLOBAL_S) == 0 {
					continue
				}
				if (opt_flags & OPT_GLOBAL_S) != 0 && (opt.flags & kOptFlagNoGlob) != 0 {
					continue
				}

				varp := nvim_odin_get_varp_scope(opt_idx, opt_flags)
				if varp == nil {
					continue
				}
				if (opt_flags & OPT_GLOBAL_S) != 0 && optval_default_o(opt_idx, varp) {
					continue
				}
				if (opt_flags & OPT_SKIPRTP_S) != 0 &&
				(opt.varp == transmute(rawptr)(&p_rtp_g) || opt.varp == transmute(rawptr)(&p_pp_g)) {
					continue
				}

				round := C.int(2)
				varp_local: rawptr = nil
				if option_is_window_local(opt_idx) {
					if (opt_flags & OPT_LOCAL_S) == 0 {
						continue
					}
					if (opt_flags & OPT_GLOBAL_S) == 0 && !local_only {
						varp_fresh := nvim_odin_get_varp_scope(opt_idx, OPT_GLOBAL_S)
						if !optval_default_o(opt_idx, varp_fresh) {
							round = 1
							varp_local = varp
							varp = varp_fresh
						}
					}
				}

				for ; round <= 2; round += 1 {
					if round == 2 { varp = varp_local }
					cmd: cstring = "set"
					if round == 1 || (opt_flags & OPT_GLOBAL_S) != 0 {
						cmd = "setlocal"
					}
					// Round 1 = fresh value → use "setlocal"? No — C uses:
					// round==1 || OPT_GLOBAL → "set"; else "setlocal". Fix below.
					if round == 1 || (opt_flags & OPT_GLOBAL_S) != 0 {
						cmd = "set"
					} else {
						cmd = "setlocal"
					}

					do_endif := false
					if opt_idx == 302 || opt_idx == 97 { // syntax / filetype
						vs := (^^u8)(varp)^
						if libc.fprintf(transmute(^libc.FILE)(fd), "if &%s != '%s'\n",
							transmute(cstring)(opt.fullname),
							transmute(cstring)(vs)) < 0 {
							return 0
						}
						do_endif = true
					}
					if put_set_o(fd, cmd, opt_idx, varp) == 0 {
						return 0
					}
					if do_endif {
						if put_line_r(transmute(^libc.FILE)(fd), "endif") == 0 {
							return 0
						}
					}
				}
			}
		}
	}
	return 1
}

foreign _ {
	@(link_name = "p_rtp")
	p_rtp_g: ^u8
	@(link_name = "p_pp")
	p_pp_g: ^u8
}

foreign _ {
	@(link_name = "p_ma")
	p_ma_g: C.int
	@(link_name = "p_iminsert")
	p_iminsert_g: C.longlong
	@(link_name = "p_imsearch")
	p_imsearch_g: C.longlong
	@(link_name = "nvim_odin_change_option_default")
	change_option_default_r :: proc "c" (opt_idx: C.int, val: OptVal) ---
}

W_GRID_ALLOC_OFF :: 10456
W_GRID_BLENDING_OFF :: 58 // within ScreenGrid
W_P_WINBL_OFF :: 1216
W_FLOATING_OFF :: 10553
W_CONFIG_OFF :: 10560
W_CONFIG_SHADOW_OFF :: 65 // within WinConfig

@(export)
check_blending :: proc "c"(wp: rawptr) {
	grid := uintptr(wp) + W_GRID_ALLOC_OFF
	winbl := (^C.longlong)(uintptr(wp) + W_P_WINBL_OFF)^
	floating := (^bool)(uintptr(wp) + W_FLOATING_OFF)^
	shadow := (^bool)(uintptr(wp) + W_CONFIG_OFF + W_CONFIG_SHADOW_OFF)^
	(^bool)(grid + W_GRID_BLENDING_OFF)^ = winbl > 0 || (floating && shadow)
}

// reset_modifiable / set_iminsert_global / set_imsearch_global:
@(export)
reset_modifiable :: proc "c"() {
	(^C.int)(uintptr(curbuf) + 10584)^ = 0 // b_p_ma @10584
	p_ma_g = 0
	change_option_default_r(194, bool_optval(0)) // kOptModifiable
}

@(export)
set_iminsert_global :: proc "c"(buf: rawptr) {
	p_iminsert_g = (^C.longlong)(uintptr(buf) + 7840)^ // b_p_iminsert
}

@(export)
set_imsearch_global :: proc "c"(buf: rawptr) {
	p_imsearch_g = (^C.longlong)(uintptr(buf) + 7848)^ // b_p_imsearch
}

MODE_TERMINAL_S :: 0x80

foreign _ {
	@(link_name = "p_so")
	p_so_g: C.longlong
	@(link_name = "p_sop")
	p_sop_g: C.longlong
	@(link_name = "p_siso")
	p_siso_g: C.longlong
	// vim_getenv/FullName_save/os_setenv already declared in other files — reuse directly.
}

W_P_SO_ABS :: 1176 // w_onebuf_opt(816) + wo_so(360)
W_P_SISO_ABS :: 1168
W_P_SOP_ABS :: 1184

@(export)
get_scrolloff_value :: proc "c"(wp: rawptr) -> C.longlong {
	// Disallow scrolloff in terminal-mode.
	if (State & MODE_TERMINAL_S) != 0 &&
	(^bool)(uintptr(buf_of_win(wp)) + 12488)^ { // buf_T.terminal @12488
		return 0
	}
	so := (^C.longlong)(uintptr(wp) + W_P_SO_ABS)^
	return so < 0 ? p_so_g : so
}

@(export)
get_scrolloffpad_value :: proc "c"(wp: rawptr) -> C.longlong {
	sop := (^C.longlong)(uintptr(wp) + W_P_SOP_ABS)^
	return sop == -1 ? p_sop_g : (^C.longlong)(uintptr(curwin) + W_P_SOP_ABS)^
}

@(export)
get_sidescrolloff_value :: proc "c"(wp: rawptr) -> C.longlong {
	siso := (^C.longlong)(uintptr(wp) + W_P_SISO_ABS)^
	return siso < 0 ? p_siso_g : siso
}

@(export)
vimrc_found :: proc "c"(fname: ^u8, envname: ^u8) {
	if fname != nil && envname != nil {
		p := vim_getenv(transmute(cstring)(envname))
		if p == nil {
			// Set $MYVIMRC to the first vimrc file found.
			p2 := FullName_save_r(transmute(cstring)(fname), false)
			if p2 != nil {
				os_setenv(transmute(cstring)(envname), transmute(cstring)(p2), 1)
				xfree(p2)
			}
		} else {
			xfree(transmute(rawptr)(p))
		}
	}
}

foreign _ {
	@(link_name = "fputs")
	fputs_o :: proc "c" (s: cstring, fd: ^libc.FILE) -> C.int ---
}

foreign _ {
	@(link_name = "bt_prompt")
	bt_prompt_r :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "p_bs")
	p_bs_g: ^u8
	@(link_name = "bkc_flags")
	bkc_flags_g: C.uint
	@(link_name = "ve_flags")
	ve_flags_g: C.uint
	@(link_name = "p_sbr")
	p_sbr_g: ^u8
	@(link_name = "p_ffs")
	p_ffs_g: ^u8
}

BS_START_S :: 1
BS_NOSTOP_S :: 3

kOptCuloptFlagLine_S :: 0x01
kOptCuloptFlagScreenline_S :: 0x02
kOptCuloptFlagNumber_S :: 0x04

W_P_CULOPT_OFF :: 1064
W_P_CULOPT_FLAGS_OFF :: 4232

@(export)
fill_culopt_flags :: proc "c"(val: ^u8, wp: rawptr) -> C.int {
	p: ^u8
	if val == nil {
		p = (^^u8)(uintptr(wp) + W_P_CULOPT_OFF)^
	} else {
		p = val
	}
	culopt_flags_new: u8 = 0

	for b_at(p, 0) != 0 {
		if libc.strncmp(transmute(cstring)(p), "line", 4) == 0 {
			p = (^u8)(uintptr(p) + 4)
			culopt_flags_new |= kOptCuloptFlagLine_S
		} else if libc.strncmp(transmute(cstring)(p), "both", 4) == 0 {
			p = (^u8)(uintptr(p) + 4)
			culopt_flags_new |= kOptCuloptFlagLine_S | kOptCuloptFlagNumber_S
		} else if libc.strncmp(transmute(cstring)(p), "number", 6) == 0 {
			p = (^u8)(uintptr(p) + 6)
			culopt_flags_new |= kOptCuloptFlagNumber_S
		} else if libc.strncmp(transmute(cstring)(p), "screenline", 10) == 0 {
			p = (^u8)(uintptr(p) + 10)
			culopt_flags_new |= kOptCuloptFlagScreenline_S
		}
		c0 := b_at(p, 0)
		if c0 != ',' && c0 != 0 {
			return 0 // FAIL
		}
		if c0 == ',' {
			p = (^u8)(uintptr(p) + 1)
		}
	}

	// Can't have both "line" and "screenline".
	if (culopt_flags_new & kOptCuloptFlagLine_S) != 0 &&
	(culopt_flags_new & kOptCuloptFlagScreenline_S) != 0 {
		return 0
	}
	(^u8)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ = culopt_flags_new

	return 1 // OK
}

@(export)
can_bs :: proc "c"(what: C.int) -> bool {
	if what == BS_START_S && bt_prompt_r(curbuf) {
		return false
	}
	if b_at(p_bs_g, 0) == '2' {
		return what != BS_NOSTOP_S
	}
	return _vim_strchr(transmute(cstring)(p_bs_g), what) != nil
}

B_BKC_FLAGS_OFF :: 10128
W_VE_FLAGS_OFF :: 976
B_P_FLP_OFF2 :: 10432
W_P_SBR_OFF :: 1080
B_P_FF_OFF :: 10408
B_P_BIN_OFF :: 10136

@(export)
get_bkc_flags :: proc "c"(buf: rawptr) -> C.uint {
	v := (^C.uint)(uintptr(buf) + B_BKC_FLAGS_OFF)^
	return v != 0 ? v : bkc_flags_g
}

@(export)
get_flp_value :: proc "c"(buf: rawptr) -> ^u8 {
	flp := (^^u8)(uintptr(buf) + B_P_FLP_OFF2)^
	if flp == nil || b_at(flp, 0) == 0 {
		return p_flp_g
	}
	return flp
}

@(export)
get_ve_flags :: proc "c"(wp: rawptr) -> C.uint {
	wv := (^C.uint)(uintptr(wp) + W_VE_FLAGS_OFF)^
	v := wv != 0 ? wv : ve_flags_g
	return v & ~C.uint(0x10 | 0x20) // kOptVeFlagNone|kOptVeFlagNoneU
}

@(export)
get_showbreak_value :: proc "c"(win: rawptr) -> ^u8 {
	sbr := (^^u8)(uintptr(win) + W_P_SBR_OFF)^
	if sbr == nil || b_at(sbr, 0) == 0 {
		return p_sbr_g
	}
	if libc.strcmp(transmute(cstring)(sbr), "NONE") == 0 {
		return empty_string_option_c
	}
	return sbr
}

B_P_EP_OFF :: 10832
B_P_FFU_OFF :: 10352

foreign _ {
	@(link_name = "p_ep")
	p_ep_g: ^u8
	@(link_name = "p_ffu")
	p_ffu_g: ^u8
}

@(export)
get_equalprg :: proc "c"() -> ^u8 {
	ep := (^^u8)(uintptr(curbuf) + B_P_EP_OFF)^
	if b_at(ep, 0) == 0 {
		return p_ep_g
	}
	return ep
}

@(export)
get_findfunc :: proc "c"() -> ^u8 {
	ffu := (^^u8)(uintptr(curbuf) + B_P_FFU_OFF)^
	if b_at(ffu, 0) == 0 {
		return p_ffu_g
	}
	return ffu
}

@(export)
win_copy_options :: proc "c"(wp_from: rawptr, wp_to: rawptr) {
	copy_winopt((^rawptr)(uintptr(wp_from) + 816), (^rawptr)(uintptr(wp_to) + 816)) // w_onebuf_opt
	copy_winopt((^rawptr)(uintptr(wp_from) + 2520), (^rawptr)(uintptr(wp_to) + 2520)) // w_allbuf_opt
	didset_window_options_r(wp_to, true)
}

@(export)
get_fileformat :: proc "c"(buf: rawptr) -> C.int {
	c := b_at((^^u8)(uintptr(buf) + B_P_FF_OFF)^, 0)
	bin := (^C.int)(uintptr(buf) + B_P_BIN_OFF)^

	if bin != 0 || c == 'u' {
		return EOL_UNIX_S
	}
	if c == 'm' {
		return EOL_MAC_S
	}
	return EOL_DOS_S
}

foreign _ {
}

EOL_UNKNOWN_S :: 0
EOL_UNIX_S :: 1
EOL_DOS_S :: 2
EOL_MAC_S :: 3

FORCE_BIN_S :: 1

@(export)
get_fileformat_force :: proc "c"(buf: rawptr, eap: rawptr) -> C.int {
	c: u8 = 0
	if eap != nil {
		force_ff := (^C.int)(uintptr(eap) + 144)^ // eap.force_ff @144
		if force_ff != 0 {
			c = u8(force_ff)
		} else {
			force_bin := (^C.int)(uintptr(eap) + 132)^ // force_bin @132
			bin := (^C.int)(uintptr(buf) + B_P_BIN_OFF)^
			if (force_bin != 0 ? force_bin == FORCE_BIN_S : bin != 0) {
				return EOL_UNIX_S
			}
			c = b_at((^^u8)(uintptr(buf) + B_P_FF_OFF)^, 0)
		}
	} else {
		bin := (^C.int)(uintptr(buf) + B_P_BIN_OFF)^
		if bin != 0 {
			return EOL_UNIX_S
		}
		c = b_at((^^u8)(uintptr(buf) + B_P_FF_OFF)^, 0)
	}
	if c == 'u' {
		return EOL_UNIX_S
	}
	if c == 'm' {
		return EOL_MAC_S
	}
	return EOL_DOS_S
}

@(export)
default_fileformat :: proc "c"() -> C.int {
	switch b_at(p_ffs_g, 0) {
	case 'm':
		return EOL_MAC_S
	case 'd':
		return EOL_DOS_S
	case:
	}
	return EOL_UNIX_S
}

@(export)
set_fileformat :: proc "c"(eol_style: C.int, opt_flags: C.int) {
	p: cstring = nil

	switch eol_style {
	case EOL_UNIX_S:
		p = cstring("unix")
	case EOL_MAC_S:
		p = cstring("mac")
	case EOL_DOS_S:
		p = cstring("dos")
	case:
	}

	if p != nil {
		set_option_direct(94, str_optval(transmute(^u8)(p), libc.strlen(p)), opt_flags, 0) // kOptFileformat=94
	}

	redraw_buf_status_later_opt(curbuf)
	redraw_tabline_opt = true
	need_maketitle_opt = true
}

// ── winopt_T copy/clear/didset ───────────────────────────────────────────────

foreign _ {
	@(link_name = "check_colorcolumn")
	check_colorcolumn_r :: proc "c" (cc: ^u8, wp: rawptr) -> cstring ---
	@(link_name = "briopt_check")
	briopt_check_r :: proc "c" (briopt: ^u8, wp: rawptr) -> bool ---
	@(link_name = "parse_winhl_opt")
	parse_winhl_opt_r :: proc "c" (winhl: ^u8, wp: rawptr) -> bool ---
	@(link_name = "set_winbar_win")
	set_winbar_win_r :: proc "c" (wp: rawptr, make_room: bool, valid_cursor: bool) -> cstring ---
	@(link_name = "check_signcolumn")
	check_signcolumn_r :: proc "c" (scl: ^u8, wp: rawptr) -> C.int ---
	@(link_name = "clear_string_option")
	clear_string_option_r :: proc "c" (pp: ^u8) ---
	@(link_name = "free_operatorfunc_option")
	free_operatorfunc_option :: proc "c" () ---
	@(link_name = "free_tagfunc_option")
	free_tagfunc_option :: proc "c" () ---
	@(link_name = "free_findfunc_option")
	free_findfunc_option :: proc "c" () ---
	@(link_name = "nvim_odin_clear_p_term_ttytype")
	nvim_odin_clear_p_term_ttytype :: proc "c" () ---
	@(link_name = "fenc_default")
	fenc_default_g: ^u8
}

kFillchars_S :: 0
kListchars_S :: 1

W_P_WRAP_OFF :: 1124
W_LEFTCOL_OFF :: 384
W_SKIPCOL_OFF :: 388

wo_copy_str :: proc "c"(to: rawptr, from: rawptr, off: uintptr, dup: bool) {
	src := (^^u8)(uintptr(from) + off)^
	if dup {
		(^^u8)(uintptr(to) + off)^ = xstrdup_r2(transmute(cstring)(src))
	} else {
		if src == empty_string_option_c {
			(^^u8)(uintptr(to) + off)^ = empty_string_option_c
		} else {
			(^^u8)(uintptr(to) + off)^ = xstrdup_r2(transmute(cstring)(src))
		}
	}
}

@(export)
copy_winopt :: proc "c"(from: rawptr, to: rawptr) {
	// int/bool scalars (wo_* 32-bit int/bool/flag fields):
	scalar_offs := [26]uintptr{
		0, 140, 144, 148, 160, 208, 308, 312, 136, 4, 296, 304, 232,
		336, 340, 236, 240, 244, 16, 300, 400, 408, 412, 416, 420, 424,
	}
	for off in scalar_offs {
		(^C.int)(uintptr(to) + off)^ = (^C.int)(uintptr(from) + off)^
	}
	// OptInt (64-bit) fields: wo_scr@224, wo_nuw@168, wo_lhi@200, wo_cole@328,
	// wo_siso@352, wo_so@360, wo_sop@368, wo_fdl@64, wo_fdl_save@72, wo_fml@96, wo_fdn@104
	int64_offs := [11]uintptr{224, 168, 200, 328, 352, 360, 368, 64, 72, 96, 104}
	for off in int64_offs {
		(^C.longlong)(uintptr(to) + off)^ = (^C.longlong)(uintptr(from) + off)^
	}
	// strings:
	str_offs := [22]uintptr{384, 392, 152, 216, 264, 280, 288, 8, 248, 256,
		32, 320, 24, 56, 80, 88, 112, 120, 128, 344, 376, 272}
	for off in str_offs {
		wo_copy_str(to, from, off, false)
	}

	// fdc_save/fdm_save are dup'd ONLY when diff_saved (@300):
	diff_saved := (^C.int)(uintptr(from) + 300)^ != 0
	if diff_saved {
		(^^u8)(uintptr(to) + 40)^ = xstrdup_r2(transmute(cstring)((^^u8)(uintptr(from) + 40)^))
		(^^u8)(uintptr(to) + 88)^ = xstrdup_r2(transmute(cstring)((^^u8)(uintptr(from) + 88)^))
	} else {
		(^^u8)(uintptr(to) + 40)^ = empty_string_option_c
		(^^u8)(uintptr(to) + 88)^ = empty_string_option_c
	}
	libc.memmove(
		transmute(rawptr)(uintptr(to) + 432), transmute(rawptr)(uintptr(from) + 432),
		24 * 53) // wo_script_ctx[kWinOptCount=53]
	// check_winopt: replace any NULL with empty_string_option
	for off in str_offs {
		check_string_option_r(transmute(^u8)((^^u8)(uintptr(to) + off)))
	}
	check_string_option_r(transmute(^u8)((^^u8)(uintptr(to) + 40)))
	check_string_option_r(transmute(^u8)((^^u8)(uintptr(to) + 88)))
}

@(export)
clear_winopt :: proc "c"(wop: rawptr) {
	str_offs := [23]uintptr{24, 40, 56, 80, 88, 112, 120, 128, 32, 344, 216,
		264, 280, 248, 256, 320, 8, 376, 384, 392, 152, 288, 272}
	for off in str_offs {
		clear_string_option_r(transmute(^u8)((^^u8)(uintptr(wop) + off)))
	}
}

@(export)
didset_window_options :: proc "c"(wp: rawptr, valid_cursor: bool) {
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
		(^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^ = 0
	} else {
		(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ = 0
	}
	check_colorcolumn_r(nil, wp)
	briopt_check_r(nil, wp)
	fill_culopt_flags(nil, wp)
	set_chars_option_o(wp, (^^u8)(uintptr(wp) + 1208)^, kFillchars_S, true, nil, 0)
	set_chars_option_o(wp, (^^u8)(uintptr(wp) + 1200)^, kListchars_S, true, nil, 0)
	parse_winhl_opt_r(nil, wp)
	check_blending(wp)
	set_winbar_win_r(wp, false, valid_cursor)
	check_signcolumn_r(nil, wp)
	(^C.int)(uintptr(wp) + 10514)^ =
		(^C.longlong)(uintptr(wp) + W_P_WINBL_OFF)^ > 0 ? 1 : 0
}

@(export)
free_all_options :: proc "c"() {
	opt_idx: C.int = 0
	for opt_idx < 377 {
		hidden := is_option_hidden(opt_idx)

		if option_is_global_only(opt_idx) || hidden {
			if !hidden {
				optval_free(optval_from_varp(opt_idx, opt_at(opt_idx).varp))
			}
		} else if !option_is_window_local(opt_idx) {
			optval_free(optval_from_varp(opt_idx, opt_at(opt_idx).varp))
		}
		optval_free(opt_at(opt_idx).def_val)
		opt_idx += 1
	}
	// NOTE: C gates these 3 callback frees + fenc_default/p_term/p_ttytype frees
	// behind #ifdef EXITFREE. This build does NOT define EXITFREE (CMakeCache
	// CMAKE_C_FLAGS is empty), so free_all_mem() never runs and never calls us.
	// Mirror the C config: skip the EXITFREE-only callback frees.
	if false {
		free_operatorfunc_option()
		free_tagfunc_option()
		free_findfunc_option()
	}
	nvim_odin_clear_p_term_ttytype()
}

// ── misc exports: set_init_tablocal, get_option_default, helplang/title defaults ──

foreign _ {
	@(link_name = "p_hlg")
	p_hlg_g: ^u8
	@(link_name = "p_title")
	p_title_g: C.int
	@(link_name = "p_icon")
	p_icon_g: C.int
	@(link_name = "getuid")
	getuid_c :: proc "c" () -> C.int ---
	@(link_name = "xmemdupz")
	xmemdupz_o2 :: proc "c" (s: ^u8, len: C.size_t) -> ^u8 ---
	@(link_name = "free_string_option")
	free_string_option_o :: proc "c" (p: ^u8) ---
	@(link_name = "nvim_odin_switch_option_context")
	nvim_odin_switch_option_context :: proc "c" (ctx: rawptr, scope: C.int, from: rawptr, err: rawptr) -> bool ---
	@(link_name = "nvim_odin_restore_option_context")
	nvim_odin_restore_option_context :: proc "c" (ctx: rawptr, scope: C.int) ---
	@(link_name = "api_set_error")
	api_set_error_r :: proc "c" (err: rawptr, typ: C.int, fmt: cstring, arg: rawptr) ---
	@(link_name = "redraw_later")
	redraw_later_o :: proc "c" (wp: rawptr, typ: C.int) ---
	@(link_name = "set_option_value_handle_tty")
	set_option_value_handle_tty_c :: proc "c" (name: ^u8, opt_idx: C.int, value: OptVal, opt_flags: C.int) -> cstring ---
	@(link_name = "p_tw")
	p_tw_g: C.longlong
	@(link_name = "p_wm")
	p_wm_g: C.longlong
	@(link_name = "p_ml")
	p_ml_g: C.int
	@(link_name = "p_et")
	p_et_g: C.int
	@(link_name = "nvim_odin_get_p_tw_nobin")
	get_p_tw_nobin_c :: proc "c" () -> C.longlong ---
	@(link_name = "nvim_odin_get_p_wm_nobin")
	get_p_wm_nobin_c :: proc "c" () -> C.longlong ---
	@(link_name = "nvim_odin_get_p_ml_nobin")
	get_p_ml_nobin_c :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_get_p_et_nobin")
	get_p_et_nobin_c :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_set_p_tw_nobin")
	set_p_tw_nobin_c :: proc "c" (v: C.longlong) ---
	@(link_name = "nvim_odin_set_p_wm_nobin")
	set_p_wm_nobin_c :: proc "c" (v: C.longlong) ---
	@(link_name = "nvim_odin_set_p_ml_nobin")
	set_p_ml_nobin_c :: proc "c" (v: C.int) ---
	@(link_name = "nvim_odin_set_p_et_nobin")
	set_p_et_nobin_c :: proc "c" (v: C.int) ---
	@(link_name = "p_bin")
	p_bin_g: C.int
	@(link_name = "strncasecmp")
	strncasecmp_o :: proc "c" (s1: cstring, s2: cstring, n: C.size_t) -> C.int ---
	@(link_name = "p_magic")
	p_magic_g: C.int
}

kOptFlagWasSet_S :: 1 << 3
kOptFlagNoDefExp_S :: 1 << 1
kOptFlagInsecure_S :: 1 << 18

UPD_NOT_VALID_S :: 40

ROOT_UID_S :: 0

@(export)
set_init_tablocal :: proc "c"() {
	// susy baka: cmdheight calls itself OPT_GLOBAL but is really tablocal!
	p_ch = ov_number(&opt_at(44).def_val)^ // kOptCmdheight=44
}

@(export)
get_option_default :: proc "c"(opt_idx: C.int, opt_flags: C.int) -> OptVal {
	opt := opt_at(opt_idx)
	is_gl := option_is_global_local_shim(opt_idx)

	if opt_idx == 191 && getuid_c() == ROOT_UID_S { // kOptModeline=191
		return bool_optval(0)
	}

	if (opt_flags & OPT_LOCAL_S) != 0 && is_gl {
		return get_option_unset_value_c(opt_idx)
	} else if option_has_type(opt_idx, 2) &&
	(opt.flags & kOptFlagNoDefExp_S) == 0 {
		s := option_expand_c(opt_idx, transmute(cstring)(ov_str_data(&opt.def_val)))
		if s == nil {
			return opt.def_val
		}
		sv := (^u8)(s)
		return str_optval(sv, libc.strlen(transmute(cstring)(sv)))
	}
	return opt.def_val
}

@(export)
set_helplang_default :: proc "c"(lang: ^u8) {
	if lang == nil {
		return
	}
	lang_len := libc.strlen(transmute(cstring)(lang))
	if lang_len < 2 {
		return
	}
	if (opt_at(130).flags & kOptFlagWasSet_S) != 0 { // kOptHelplang=130
		return
	}
	free_string_option_o(p_hlg_g)
	p_hlg_g = xmemdupz_o2(lang, lang_len)
	// zh_CN becomes "cn", zh_TW becomes "tw".
	if strncasecmp_o(transmute(cstring)(p_hlg_g), cstring("zh_"), 3) == 0 && lang_len >= 5 {
		b_set(p_hlg_g, 0, byte(libc.tolower(C.int(b_at(p_hlg_g, 3)))))
		b_set(p_hlg_g, 1, byte(libc.tolower(C.int(b_at(p_hlg_g, 4)))))
	} else if lang_len != 0 && b_at(p_hlg_g, 0) == 'C' {
		b_set(p_hlg_g, 0, 'e')
		b_set(p_hlg_g, 1, 'n')
	}
	b_set(p_hlg_g, 2, 0)
}

@(export)
set_title_defaults :: proc "c"() {
	if (opt_at(326).flags & kOptFlagWasSet_S) == 0 { // kOptTitle=326
		change_option_default_r(326, bool_optval(0))
		p_title_g = 0
	}
	if (opt_at(137).flags & kOptFlagWasSet_S) == 0 { // kOptIcon=137
		change_option_default_r(137, bool_optval(0))
		p_icon_g = 0
	}
}

foreign _ {
	@(link_name = "optval_as_tv")
	optval_as_tv_c :: proc "c" (value: OptVal, numbool: bool) -> Typval_T ---
	@(link_name = "set_vim_var_tv")
	set_vim_var_tv_c :: proc "c" (idx: C.int, tv: ^Typval_T) ---
	@(link_name = "reset_v_option_vars")
	reset_v_option_vars_c :: proc "c" () ---
}

Typval_T :: struct { // 16 bytes
	v_type: C.int,
	v_lock: C.int,
	vval:   rawptr,
}
#assert(size_of(Typval_T) == 16)

VV_OPTION_NEW_S :: 62
VV_OPTION_OLD_S :: 63
VV_OPTION_OLDLOCAL_S :: 64
VV_OPTION_OLDGLOBAL_S :: 65
VV_OPTION_COMMAND_S :: 66
VV_OPTION_TYPE_S :: 67

EVENT_OPTIONSET_S :: 38

kOptFlagRedrTabl_S :: 1 << 6
kOptFlagRedrStat_S :: 1 << 7
kOptFlagRedrWin_S :: 1 << 8
kOptFlagRedrBuf_S :: 1 << 9
kOptFlagRedrAll_S :: kOptFlagRedrBuf_S | kOptFlagRedrWin_S
kOptFlagHLOnly_S :: 1 << 22

OPTION_MAGIC_NOT_SET_S :: 0
OPTION_MAGIC_ON_S :: 1
OPTION_MAGIC_OFF_S :: 2

W_P_WRAP_FLAGS_OFF :: 1224
W_P_STL_FLAGS_OFF :: 1228
W_P_WBR_FLAGS_OFF :: 1232
W_P_FDE_FLAGS_OFF :: 1236
W_P_FDT_FLAGS_OFF :: 1240
B_P_INDE_FLAGS_OFF :: 10496
B_P_FEX_FLAGS_OFF :: 10528
B_P_INEX_FLAGS_OFF :: 10480
W_ONEBUF_OPT_OFF2 :: 816
W_ALLBUF_OPT_OFF2 :: 2520
WO_WRAP_FLAGS_OFF2 :: 408
WO_FDE_FLAGS_OFF2 :: 420
WO_FDT_FLAGS_OFF2 :: 424

B_P_TW_NOBIN_OFF :: 10712
B_P_WM_NOBIN_OFF :: 10736
B_P_ML_NOBIN_OFF :: 10580
B_P_ET_NOBIN_OFF :: 10392
B_P_TW_OFF2 :: 10704
B_P_WM_OFF2 :: 10728
B_P_ML_OFF2 :: 10576
B_P_ET_OFF2 :: 10388

@(export)
insecure_flag :: proc "c"(wp: rawptr, opt_idx: C.int, opt_flags: C.int) -> ^C.uint32_t {
	if (opt_flags & OPT_LOCAL_S) != 0 {
		switch opt_idx {
		case 370: // kOptWrap
			return (^C.uint32_t)(uintptr(wp) + W_P_WRAP_FLAGS_OFF)
		case 296: // kOptStatusline
			return (^C.uint32_t)(uintptr(wp) + W_P_STL_FLAGS_OFF)
		case 357: // kOptWinbar
			return (^C.uint32_t)(uintptr(wp) + W_P_WBR_FLAGS_OFF)
		case 104: // kOptFoldexpr
			return (^C.uint32_t)(uintptr(wp) + W_P_FDE_FLAGS_OFF)
		case 113: // kOptFoldtext
			return (^C.uint32_t)(uintptr(wp) + W_P_FDT_FLAGS_OFF)
		case 148: // kOptIndentexpr
			return (^C.uint32_t)(uintptr((^^rawptr)(uintptr(wp) + 8)^) + B_P_INDE_FLAGS_OFF)
		case 114: // kOptFormatexpr
			return (^C.uint32_t)(uintptr((^^rawptr)(uintptr(wp) + 8)^) + B_P_FEX_FLAGS_OFF)
		case 146: // kOptIncludeexpr
			return (^C.uint32_t)(uintptr((^^rawptr)(uintptr(wp) + 8)^) + B_P_INEX_FLAGS_OFF)
		case:
		}
	} else {
		// global value of window-local options → w_allbuf_opt flags
		switch opt_idx {
		case 370:
			return (^C.uint32_t)(uintptr(wp) + W_ALLBUF_OPT_OFF2 + WO_WRAP_FLAGS_OFF2)
		case 104:
			return (^C.uint32_t)(uintptr(wp) + W_ALLBUF_OPT_OFF2 + WO_FDE_FLAGS_OFF2)
		case 113:
			return (^C.uint32_t)(uintptr(wp) + W_ALLBUF_OPT_OFF2 + WO_FDT_FLAGS_OFF2)
		case:
		}
	}
	return &opt_at(opt_idx).flags
}

@(export)
was_set_insecurely :: proc "c"(wp: rawptr, opt_idx: C.int, opt_flags: C.int) -> C.int {
	flagp := insecure_flag(wp, opt_idx, opt_flags)
	return (flagp^ & kOptFlagInsecure_S) != 0 ? 1 : 0
}

@(export)
redraw_titles :: proc "c"() {
	need_maketitle_opt = true
	redraw_tabline_opt = true
}

@(export)
check_redraw_for :: proc "c"(buf: rawptr, win: rawptr, flags: C.uint32_t) {
	all := (flags & kOptFlagRedrAll_S) == kOptFlagRedrAll_S

	if (flags & kOptFlagRedrStat_S) != 0 || all {
		status_redraw_all_r()
	}
	if (flags & kOptFlagRedrTabl_S) != 0 || all {
		redraw_tabline_opt = true
	}
	if (flags & kOptFlagRedrBuf_S) != 0 || (flags & kOptFlagRedrWin_S) != 0 || all {
		if (flags & kOptFlagHLOnly_S) != 0 {
			redraw_later_o(win, UPD_NOT_VALID_S)
		} else {
			changed_window_setting_opt(win)
		}
	}
	if (flags & kOptFlagRedrBuf_S) != 0 {
		redraw_buf_later_o(buf, UPD_NOT_VALID_S)
	}
	if all {
		redraw_all_later_o(UPD_NOT_VALID_S)
	}
}

@(export)
check_redraw :: proc "c"(flags: C.uint32_t) {
	check_redraw_for(curbuf, curwin, flags)
}

@(export)
magic_isset :: proc "c"() -> bool {
	switch magic_overruled_g {
	case OPTION_MAGIC_ON_S:
		return true
	case OPTION_MAGIC_OFF_S:
		return false
	case:
	}
	return p_magic_g != 0
}

@(export)
set_options_bin :: proc "c"(oldval: C.int, newval: C.int, opt_flags: C.int) {
	if newval != 0 {
		if oldval == 0 {
			if (opt_flags & OPT_GLOBAL_S) == 0 {
				(^C.longlong)(uintptr(curbuf) + B_P_TW_NOBIN_OFF)^ =
					(^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^
				(^C.longlong)(uintptr(curbuf) + B_P_WM_NOBIN_OFF)^ =
					(^C.longlong)(uintptr(curbuf) + B_P_WM_OFF2)^
				(^C.int)(uintptr(curbuf) + B_P_ML_NOBIN_OFF)^ =
					(^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^
				(^C.int)(uintptr(curbuf) + B_P_ET_NOBIN_OFF)^ =
					(^C.int)(uintptr(curbuf) + B_P_ET_OFF2)^
			}
			if (opt_flags & OPT_LOCAL_S) == 0 {
				set_p_tw_nobin_c(p_tw_g)
				set_p_wm_nobin_c(p_wm_g)
				set_p_ml_nobin_c(p_ml_g)
				set_p_et_nobin_c(p_et_g)
			}
		}
		if (opt_flags & OPT_GLOBAL_S) == 0 {
			(^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^ = 0
			(^C.longlong)(uintptr(curbuf) + B_P_WM_OFF2)^ = 0
			(^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^ = 0
			(^C.int)(uintptr(curbuf) + B_P_ET_OFF2)^ = 0
		}
		if (opt_flags & OPT_LOCAL_S) == 0 {
			p_tw_g = 0
			p_wm_g = 0
			p_ml_g = 0
			p_et_g = 0
			p_bin_g = 1
		}
	} else if oldval != 0 {
		if (opt_flags & OPT_GLOBAL_S) == 0 {
			(^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^ =
				(^C.longlong)(uintptr(curbuf) + B_P_TW_NOBIN_OFF)^
			(^C.longlong)(uintptr(curbuf) + B_P_WM_OFF2)^ =
				(^C.longlong)(uintptr(curbuf) + B_P_WM_NOBIN_OFF)^
			(^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^ =
				(^C.int)(uintptr(curbuf) + B_P_ML_NOBIN_OFF)^
			(^C.int)(uintptr(curbuf) + B_P_ET_OFF2)^ =
				(^C.int)(uintptr(curbuf) + B_P_ET_NOBIN_OFF)^
		}
		if (opt_flags & OPT_LOCAL_S) == 0 {
			p_tw_g = get_p_tw_nobin_c()
			p_wm_g = get_p_wm_nobin_c()
			p_ml_g = C.int(get_p_ml_nobin_c())
			p_et_g = C.int(get_p_et_nobin_c())
		}
	}
	didset_options_sctx_c(opt_flags, nvim_odin_get_p_bin_dep_opts())
}

@(export)
apply_optionset_autocmd_now :: proc "c"(opt_idx: C.int, opt_flags: C.int, oldval: OptVal,
	oldval_g: OptVal, oldval_l: OptVal, newval: OptVal, errmsg: cstring) {
	// Don't do this while starting up, failure or recursively.
	if starting != 0 || errmsg != nil || b_at((^u8)(get_vim_var_str_f(VV_OPTION_TYPE_S)), 0) != 0 {
		return
	}

	buf_type: [7]u8
	oldval_tv := optval_as_tv_c(oldval, false)
	oldval_g_tv := optval_as_tv_c(oldval_g, false)
	oldval_l_tv := optval_as_tv_c(oldval_l, false)
	newval_tv := optval_as_tv_c(newval, false)

	set_vim_var_tv_c(VV_OPTION_OLD_S, &oldval_tv)
	set_vim_var_tv_c(VV_OPTION_NEW_S, &newval_tv)
	typelen := C.size_t(libc.snprintf(&buf_type[0], 7, "%s",
		(opt_flags & OPT_LOCAL_S) != 0 ? cstring("local") : cstring("global")))
	set_vim_var_string(VV_OPTION_TYPE_S, transmute(cstring)(&buf_type[0]), C.ssize_t(typelen))
	if (opt_flags & OPT_LOCAL_S) != 0 {
		set_vim_var_string(VV_OPTION_COMMAND_S, cstring("setlocal"), 8)
		set_vim_var_tv_c(VV_OPTION_OLDLOCAL_S, &oldval_tv)
	}
	if (opt_flags & OPT_GLOBAL_S) != 0 {
		set_vim_var_string(VV_OPTION_COMMAND_S, cstring("setglobal"), 9)
		set_vim_var_tv_c(VV_OPTION_OLDGLOBAL_S, &oldval_tv)
	}
	if (opt_flags & (OPT_LOCAL_S | OPT_GLOBAL_S)) == 0 {
		set_vim_var_string(VV_OPTION_COMMAND_S, cstring("set"), 3)
		set_vim_var_tv_c(VV_OPTION_OLDLOCAL_S, &oldval_l_tv)
		set_vim_var_tv_c(VV_OPTION_OLDGLOBAL_S, &oldval_g_tv)
	}
	if (opt_flags & OPT_MODELINE_S) != 0 {
		set_vim_var_string(VV_OPTION_COMMAND_S, cstring("modeline"), 8)
		set_vim_var_tv_c(VV_OPTION_OLDLOCAL_S, &oldval_tv)
	}
	apply_autocmds(EVENT_OPTIONSET_S, transmute(cstring)(opt_at(opt_idx).fullname), nil, false, nil)
	reset_v_option_vars_c()
}

// ── get/set_option_value_for (switch context) ────────────────────────────────


ERROR_SET :: proc "c"(err: rawptr) -> bool {
	e := (^Api_Error)(err)
	return e.msg != nil
}

SWITCHWIN_SIZE :: 24
ACO_SAVE_SIZE :: 56

@(export)
get_option_value_for :: proc "c"(opt_idx: C.int, opt_flags: C.int, scope: C.int, from: rawptr,
	err: rawptr) -> OptVal {
	switchwin: [SWITCHWIN_SIZE]u8
	aco: [ACO_SAVE_SIZE]u8
	swtab: rawptr = nil
	ctx: rawptr = nil
	if scope == kOptScopeWin_S {
		ctx = &switchwin[0]
	} else if scope == kOptScopeBuf_S {
		ctx = &aco[0]
	} else if scope == kOptScopeTab_S {
		ctx = &swtab
	}

	switched := nvim_odin_switch_option_context(ctx, scope, from, err)
	if ERROR_SET(err) {
		return nil_optval()
	}

	retv := get_option_value(opt_idx, opt_flags)

	if switched {
		nvim_odin_restore_option_context(ctx, scope)
	}

	return retv
}

@(export)
set_option_value_for :: proc "c"(name: ^u8, opt_idx: C.int, value: OptVal, opt_flags: C.int,
	scope: C.int, from: rawptr, err: rawptr) {
	// Special case: Tab scope for NON-CURRENT tab: set tp_ch_used directly.
	if scope == kOptScopeTab_S && from != curtab {
		if value.typ != 2 { // kOptValTypeNumber == 2
			api_set_error_r(err, 1, "'cmdheight' requires a Number", nil)
			return
		}
		v := value
		(^C.longlong)(uintptr(from) + 72)^ = ov_number(&v)^ // tp_ch_used @72
		return
	}

	switchwin: [SWITCHWIN_SIZE]u8
	aco: [ACO_SAVE_SIZE]u8
	swtab: rawptr = nil
	ctx: rawptr = nil
	if scope == kOptScopeWin_S {
		ctx = &switchwin[0]
	} else if scope == kOptScopeBuf_S {
		ctx = &aco[0]
	} else if scope == kOptScopeTab_S {
		ctx = &swtab
	}

	switched := nvim_odin_switch_option_context(ctx, scope, from, err)
	if ERROR_SET(err) {
		return
	}

	errmsg := set_option_value_handle_tty_c(name, opt_idx, value, opt_flags)
	if errmsg != nil {
		api_set_error_r(err, 2 /* kErrorTypeException */, "%s", transmute(rawptr)(errmsg))
	}

	if switched {
		nvim_odin_restore_option_context(ctx, scope)
	}
}

// ── cmdline completion family ────────────────────────────────────────────────

foreign _ {
	@(link_name = "get_special_key_code")
	get_special_key_code_c :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "escape_chars")
	escape_chars_g: ^u8
	@(link_name = "p_syn")
	p_syn_opt: ^u8
	@(link_name = "p_ft")
	p_ft_opt: ^u8
	@(link_name = "p_keymap")
	p_keymap_opt: ^u8
	@(link_name = "p_bdir")
	p_bdir_opt: ^u8
	@(link_name = "p_dir")
	p_dir_opt: ^u8
	@(link_name = "p_cdpath")
	p_cdpath_opt: ^u8
	@(link_name = "p_vdir")
	p_vdir_opt: ^u8
	@(link_name = "vim_strsave_escaped")
	vim_strsave_escaped_c :: proc "c" (s: ^u8, esc: ^u8) -> ^u8 ---
	@(link_name = "vim_regexec")
	vim_regexec_o2 :: proc "c" (rmp: rawptr, line: ^u8, col: C.int) -> C.int ---
	@(link_name = "cmdline_fuzzy_complete")
	cmdline_fuzzy_complete_c :: proc "c" (fuzzystr: ^u8) -> bool ---
	@(link_name = "fuzzy_match_str")
	fuzzy_match_str_c :: proc "c" (str: ^u8, pat: ^u8) -> C.int ---
	@(link_name = "fuzzymatches_to_strmatches")
	fuzzymatches_to_strmatches_c :: proc "c" (fuzmatch: rawptr, matches: rawptr, numMatches: C.int, ignorecase: bool) ---
}

XP_BS_NONE_S :: 0
XP_BS_ONE_S :: 1
XP_BS_THREE_S :: 2
XP_BS_COMMA_S :: 4

XP_PREFIX_NONE_S :: 0
XP_PREFIX_NO_S :: 1
XP_PREFIX_INV_S :: 2

EXPAND_UNSUCCESSFUL_S :: -2
EXPAND_NOTHING_S :: 0
EXPAND_FILES_S :: 2
EXPAND_DIRECTORIES_S :: 3
EXPAND_SETTINGS_S :: 4
EXPAND_BOOL_SETTINGS_S :: 5
EXPAND_OLD_SETTING_S :: 7
EXPAND_OWNSYNTAX_S :: 38
EXPAND_FILETYPE_S :: 36
EXPAND_STRING_SETTING_S :: 52
EXPAND_SETTING_SUBTRACT_S :: 53
EXPAND_KEYMAP_S :: 55

XPP_OFF :: 0 // expand_T offsets
XPP_PATTERN :: 0
XPP_CONTEXT :: 8
XPP_PREFIX :: 24
XPP_BACKSLASH :: 72
XPP_LINE :: 144

kOptFlagExpand_S :: 1 << 0
kOptFlagComma_S :: 1 << 10
kOptFlagColon_S :: 1 << 25
kOptFlagFlagList_S :: 1 << 13

// statics from option.c
expand_option_idx_g: C.int = -1 // kOptInvalid == -1
expand_option_start_col_g: C.int = 0
expand_option_name_g: [5]u8 = {'t', '_', 0, 0, 0}
expand_option_flags_g: C.int = 0
expand_option_append_g: bool = false
expand_option_subtract_g: bool = false

ascii_isalnum :: #force_inline proc "c"(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

p_minus_1 :: #force_inline proc "c"(p: ^u8) -> ^u8 {
	return (^u8)(uintptr(p) - 1)
}

@(export)
set_context_in_set_cmd :: proc "c"(xp: rawptr, arg_in: ^u8, opt_flags: C.int) {
	arg := arg_in
	expand_option_flags_g = opt_flags

	(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_SETTINGS_S
	if b_at(arg, 0) == 0 {
		(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = arg
		return
	}
	argend := (^u8)(uintptr(arg) + uintptr(libc.strlen(transmute(cstring)(arg))))
	p := p_minus_1(argend)
	if b_at(p, 0) == ' ' && b_at(p_minus_1(p), 0) != '\\' {
		(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = (^u8)(uintptr(p) + 1)
		return
	}
	for uintptr(p) > uintptr(arg) {
		s := p
		if b_at(p, 0) == ' ' || b_at(p, 0) == ',' {
			for uintptr(s) > uintptr(arg) && b_at(p_minus_1(s), 0) == '\\' {
				s = p_minus_1(s)
			}
		}
		if b_at(p, 0) == ' ' && ((uintptr(p) - uintptr(s)) & 1) == 0 {
			p = (^u8)(uintptr(p) + 1)
			break
		}
		p = p_minus_1(p)
	}
	if libc.strncmp(transmute(cstring)(p), "no", 2) == 0 {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_BOOL_SETTINGS_S
		(^C.int)(uintptr(xp) + XPP_PREFIX)^ = XP_PREFIX_NO_S
		p = (^u8)(uintptr(p) + 2)
	} else if libc.strncmp(transmute(cstring)(p), "inv", 3) == 0 {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_BOOL_SETTINGS_S
		(^C.int)(uintptr(xp) + XPP_PREFIX)^ = XP_PREFIX_INV_S
		p = (^u8)(uintptr(p) + 3)
	}
	(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = p
	arg = p // C: `arg = p` — find_option_len must search the post-prefix name

	nextchar: u8
	flags: C.uint32_t = 0
	opt_idx: C.int = 0
	is_term_option := false

	if b_at(arg, 0) == '<' {
		for b_at(p, 0) != '>' {
			c0 := b_at(p, 0)
			p = (^u8)(uintptr(p) + 1)
			if c0 == 0 { // expand terminal option name
				return
			}
		}
		key := get_special_key_code_c(transmute(cstring)((^u8)(uintptr(arg) + 1)))
		if key == 0 {
			(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_NOTHING_S
			return
		}
		nextchar = b_at(p, 1)
		is_term_option = true
		b_set(&expand_option_name_g[0], 2, u8(KEY2TERMCAP0(key)))
		b_set(&expand_option_name_g[0], 3, u8(KEY2TERMCAP1(key)))
	} else {
		if b_at(p, 0) == 't' && b_at(p, 1) == '_' {
			p = (^u8)(uintptr(p) + 2)
			if b_at(p, 0) != 0 {
				p = (^u8)(uintptr(p) + 1)
			}
			if b_at(p, 0) == 0 {
				return // expand option name
			}
			nextchar = b_at(p, 1)
			is_term_option = true
			b_set(&expand_option_name_g[0], 2, b_at(p_minus_1(p_minus_1(p)), 0))
			b_set(&expand_option_name_g[0], 3, b_at(p_minus_1(p), 0))
		} else {
			// Allow * wildcard.
			for ascii_isalnum(b_at(p, 0)) || b_at(p, 0) == '_' || b_at(p, 0) == '*' {
				p = (^u8)(uintptr(p) + 1)
			}
			if b_at(p, 0) == 0 {
				return
			}
			nextchar = b_at(p, 0)
			opt_idx = nvim_odin_find_option_len(transmute(cstring)(arg), C.size_t(uintptr(p) - uintptr(arg)))
			if opt_idx == -1 /* kOptInvalid */ || is_option_hidden(opt_idx) {
				(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_NOTHING_S
				return
			}
			flags = opt_at(opt_idx).flags
			if option_has_type(opt_idx, kOptValTypeBoolean) {
				(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_NOTHING_S
				return
			}
		}
	}
	// handle "-=" and "+="
	expand_option_append_g = false
	expand_option_subtract_g = false
	if (nextchar == '-' || nextchar == '+' || nextchar == '^') && b_at(p, 1) == '=' {
		if nextchar == '-' {
			expand_option_subtract_g = true
		}
		if nextchar == '+' || nextchar == '^' {
			expand_option_append_g = true
		}
		p = (^u8)(uintptr(p) + 1)
		nextchar = '='
	}
	if (nextchar != '=' && nextchar != ':') ||
	(^C.int)(uintptr(xp) + XPP_CONTEXT)^ == EXPAND_BOOL_SETTINGS_S {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_UNSUCCESSFUL_S
		return
	}

	// Below are for handling expanding a specific option's value after the '=' or ':'
	if is_term_option {
		expand_option_idx_g = -1
	} else {
		expand_option_idx_g = opt_idx
	}

	(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = (^u8)(uintptr(p) + 1)
	expand_option_start_col_g = C.int(uintptr(p) + 1 - uintptr((^rawptr)(uintptr(xp) + XPP_LINE)^))

	// Certain options have special case handling to reuse the expansion logic.
	if opt_at(opt_idx).varp == transmute(rawptr)(&p_syn_opt) {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_OWNSYNTAX_S
		return
	}
	if opt_at(opt_idx).varp == transmute(rawptr)(&p_ft_opt) {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_FILETYPE_S
		return
	}
	if opt_at(opt_idx).varp == transmute(rawptr)(&p_keymap_opt) {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_KEYMAP_S
		return
	}

	// If the option has a custom expander, use that. Otherwise fill with existing value.
	if expand_option_subtract_g {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_SETTING_SUBTRACT_S
		return
	} else if expand_option_idx_g != -1 && opt_at(expand_option_idx_g).opt_expand_cb != nil {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_STRING_SETTING_S
	} else if b_at((^u8)((^rawptr)(uintptr(xp) + XPP_PATTERN)^), 0) == 0 {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_OLD_SETTING_S
		return
	} else {
		(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_NOTHING_S
	}

	if is_term_option || option_has_type(opt_idx, 1) { // Number
		return
	}

	// Only string options below
	if (flags & kOptFlagExpand_S) != 0 {
		p = (^u8)(opt_at(opt_idx).varp)
		if p == (^u8)(&p_bdir_opt) || p == (^u8)(&p_dir_opt) || p == (^u8)(&p_path_g) ||
		p == (^u8)(&p_pp_g) || p == (^u8)(&p_rtp_g) || p == (^u8)(&p_cdpath_opt) ||
		p == (^u8)(&p_vdir_opt) {
			(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_DIRECTORIES_S
			if p == (^u8)(&p_path_g) || p == (^u8)(&p_cdpath_opt) {
				(^C.int)(uintptr(xp) + XPP_BACKSLASH)^ = XP_BS_THREE_S
			} else {
				(^C.int)(uintptr(xp) + XPP_BACKSLASH)^ = XP_BS_ONE_S
			}
		} else {
			(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_FILES_S
			if p == (^u8)(&p_tags_g) {
				(^C.int)(uintptr(xp) + XPP_BACKSLASH)^ = XP_BS_THREE_S
			} else {
				(^C.int)(uintptr(xp) + XPP_BACKSLASH)^ = XP_BS_ONE_S
			}
		}
		if (flags & kOptFlagComma_S) != 0 {
			(^C.int)(uintptr(xp) + XPP_BACKSLASH)^ |= XP_BS_COMMA_S
		}
	}

	if (flags & kOptFlagExpand_S) != 0 || (flags & kOptFlagComma_S) != 0 || (flags & kOptFlagColon_S) != 0 {
		xp_pattern := (^rawptr)(uintptr(xp) + XPP_PATTERN)^
		q := p_minus_1(argend)
		for uintptr(q) > uintptr(xp_pattern) {
			if b_at(q, 0) == ' ' || b_at(q, 0) == ',' || (b_at(q, 0) == ':' && (flags & kOptFlagColon_S) != 0) {
				s := q
				for uintptr(s) > uintptr(xp_pattern) && b_at(p_minus_1(s), 0) == '\\' {
					s = p_minus_1(s)
				}
				if (b_at(q, 0) == ' ' && ((^C.int)(uintptr(xp) + XPP_BACKSLASH)^ & XP_BS_THREE_S) != 0 &&
				(uintptr(q) - uintptr(s)) < 3) ||
				(b_at(q, 0) == ',' && (flags & kOptFlagComma_S) != 0 && (uintptr(q) - uintptr(s)) < 2) ||
				(b_at(q, 0) == ':' && (flags & kOptFlagColon_S) != 0) {
					(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = (^u8)(uintptr(q) + 1)
					break
				}
			}
			q = p_minus_1(q)
		}
	}

	if (flags & kOptFlagFlagList_S) != 0 {
		(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = argend
	}

	// 'spellsuggest': custom or file:
	if opt_at(opt_idx).varp == transmute(rawptr)(&p_sps_g) {
		pat := (^rawptr)(uintptr(xp) + XPP_PATTERN)^
		if libc.strncmp(transmute(cstring)(pat), "file:", 5) == 0 {
			(^rawptr)(uintptr(xp) + XPP_PATTERN)^ = (^u8)(uintptr(pat) + 5)
			return
		} else if expand_option_idx_g != -1 && opt_at(expand_option_idx_g).opt_expand_cb != nil {
			(^C.int)(uintptr(xp) + XPP_CONTEXT)^ = EXPAND_STRING_SETTING_S
		}
	}
}

KEY2TERMCAP0 :: #force_inline proc "c"(x: C.int) -> C.int {
	return (-x) & 0xff
}
KEY2TERMCAP1 :: #force_inline proc "c"(x: C.int) -> C.int {
	return C.int((C.uint32_t(-x) >> 8) & 0xff)
}

@(export)
escape_option_str_cmdline :: proc "c"(var_str: ^u8) -> ^u8 {
	// A backslash is required before some characters; reverse of do_set().
	return vim_strsave_escaped_c(var_str, escape_chars_g)
}

match_str_c :: #force_inline proc "c"(str: ^u8, regmatch: rawptr, matches: rawptr,
	idx: C.int, test_only: bool, fuzzy: bool, fuzzystr: ^u8, fuzmatch: rawptr) -> bool {
	if !fuzzy {
		if vim_regexec_o2(regmatch, str, 0) != 0 {
			if !test_only {
				(^rawptr)(uintptr(matches) + uintptr(idx) * 8)^ = xstrdup_r2(transmute(cstring)(str))
			}
			return true
		}
	} else {
		score := fuzzy_match_str_c(str, fuzzystr)
		if score != C.int(-2147483648) { // FUZZY_SCORE_NONE == INT_MIN
			if !test_only {
				fm := (^Fuzmatch_Str)(uintptr(fuzmatch) + uintptr(idx) * 24)
				fm.idx = idx
				fm.str = xstrdup_r2(transmute(cstring)(str))
				fm.score = score
			}
			return true
		}
	}
	return false
}

Fuzmatch_Str :: struct {
	idx:   C.int,
	str:   ^u8,
	score: C.int,
}
#assert(size_of(Fuzmatch_Str) == 24)

@(export)
ExpandSettings :: proc "c"(xp: rawptr, regmatch: rawptr, fuzzystr: ^u8, numMatches: ^C.int,
	matches: ^[^]^u8, can_fuzzy: bool) -> C.int {
	num_normal: C.int = 0
	count: C.int = 0
	names := [1]^u8{(^u8)(&all_name_g[0])}
	rm_ic_off :: 172

	ic_val := (^C.int)(uintptr(regmatch) + rm_ic_off)^
	fuzmatch: rawptr = nil
	fuzzy := can_fuzzy && cmdline_fuzzy_complete_c(fuzzystr)

	loop: C.int = 0
	for loop <= 1 {
		(^C.int)(uintptr(regmatch) + rm_ic_off)^ = ic_val
		if (^C.int)(uintptr(xp) + XPP_CONTEXT)^ != EXPAND_BOOL_SETTINGS_S {
			for match: C.int = 0; match < 1; match += 1 {
				if match_str_c(names[match], regmatch, transmute(rawptr)(matches^), count, loop == 0, fuzzy, fuzzystr, fuzmatch) {
					if loop == 0 {
						num_normal += 1
					} else {
						count += 1
					}
				}
			}
		}
		opt_idx: C.int = 0
		for opt_idx < 377 {
			str := opt_at(opt_idx).fullname
			if is_option_hidden(opt_idx) {
				opt_idx += 1
				continue
			}
			if (^C.int)(uintptr(xp) + XPP_CONTEXT)^ == EXPAND_BOOL_SETTINGS_S &&
			!option_has_type(opt_idx, 0) { // Boolean
				opt_idx += 1
				continue
			}
			if match_str_c(str, regmatch, transmute(rawptr)(matches^), count, loop == 0, fuzzy, fuzzystr, fuzmatch) {
				if loop == 0 {
					num_normal += 1
				} else {
					count += 1
				}
			} else if !fuzzy && opt_at(opt_idx).shortname != nil &&
			vim_regexec_o2(regmatch, opt_at(opt_idx).shortname, 0) != 0 {
				if loop == 0 {
					num_normal += 1
				} else {
					(matches^)[count] = xstrdup_r2(transmute(cstring)(str))
					count += 1
				}
			}
			opt_idx += 1
		}

		if loop == 0 {
			if num_normal > 0 {
				numMatches^ = num_normal
			} else {
				return 1 // OK
			}
			if !fuzzy {
				matches^ = ([^]^u8)(xmalloc_o(C.size_t(numMatches^) * 8))
			} else {
				fuzmatch = xmalloc_o(C.size_t(numMatches^) * 24)
			}
		}
		loop += 1
	}

	if fuzzy {
		fuzzymatches_to_strmatches_c(fuzmatch, transmute(rawptr)(matches), count, false)
	}

	return 1 // OK
}

all_name_g: [4]u8 = {'a', 'l', 'l', 0}

@(export)
ExpandOldSetting :: proc "c"(numMatches: ^C.int, matches: ^[^]^u8) -> C.int {
	var_str: ^u8 = nil

	numMatches^ = 0
	matches^ = ([^]^u8)(xmalloc_o(8))

	// For a terminal key code expand_option_idx is kOptInvalid.
	if expand_option_idx_g == -1 {
		expand_option_idx_g = nvim_odin_find_option_len(transmute(cstring)(&expand_option_name_g[0]), libc.strlen(transmute(cstring)(&expand_option_name_g[0])))
	}

	if expand_option_idx_g != -1 {
		// Put string of option value in NameBuff.
		option_value2string_o(opt_at(expand_option_idx_g), expand_option_flags_g)
		var_str = (^u8)(&name_buff[0])
	} else {
		var_str = (^u8)(&empty_name_g[0])
	}

	buf := escape_option_str_cmdline(var_str)

	(matches^)[0] = buf
	numMatches^ = 1
	return 1 // OK
}

empty_name_g: [1]u8 = {0}

OE_VARP :: 0
OE_OPT_VALUE :: 16
OE_IDX :: 8
OE_APPEND :: 24
OE_INCLUDE_ORIG_VAL :: 25
OE_REGMATCH :: 32
OE_XP :: 40
OE_SET_ARG :: 48
OPTEXPAND_SIZE :: 56

@(export)
ExpandStringSetting :: proc "c"(xp: rawptr, regmatch: rawptr, numMatches: ^C.int,
	matches: ^[^]^u8) -> C.int {
	if expand_option_idx_g == -1 || opt_at(expand_option_idx_g).opt_expand_cb == nil {
		// Not supposed to reach this; only for options with custom expansion callbacks.
		return 0 // FAIL
	}

	args: [OPTEXPAND_SIZE]u8
	libc.memset(&args[0], 0, OPTEXPAND_SIZE)
	(^rawptr)(uintptr(&args[0]) + OE_VARP)^ =
		nvim_odin_get_varp_scope(expand_option_idx_g, expand_option_flags_g)
	(^C.int)(uintptr(&args[0]) + OE_IDX)^ = expand_option_idx_g
	(^bool)(uintptr(&args[0]) + OE_APPEND)^ = expand_option_append_g
	(^rawptr)(uintptr(&args[0]) + OE_REGMATCH)^ = regmatch
	(^rawptr)(uintptr(&args[0]) + OE_XP)^ = xp
	(^rawptr)(uintptr(&args[0]) + OE_SET_ARG)^ =
		(^u8)(uintptr((^rawptr)(uintptr(xp) + XPP_LINE)^) + uintptr(expand_option_start_col_g))
	set_arg := (^u8)(uintptr(&args[0]) + OE_SET_ARG)
	(^bool)(uintptr(&args[0]) + OE_INCLUDE_ORIG_VAL)^ =
		!expand_option_append_g && b_at((^^u8)(set_arg)^, 0) == 0

	// Retrieve the existing value, but escape it as a reverse of setting it.
	option_value2string_o(opt_at(expand_option_idx_g), expand_option_flags_g)
	var_str := (^u8)(&name_buff[0])
	buf := escape_option_str_cmdline(var_str)
	(^rawptr)(uintptr(&args[0]) + OE_OPT_VALUE)^ = buf

	cb := cast_opt_expand_cb(opt_at(expand_option_idx_g).opt_expand_cb)
	num_ret := cb(&args[0], numMatches, matches)

	xfree(buf)
	return num_ret
}

opt_expand_cb_T :: #type proc "c"(rawptr, ^C.int, ^[^]^u8) -> C.int

cast_opt_expand_cb :: #force_inline proc "c"(p: rawptr) -> opt_expand_cb_T {
	return transmute(opt_expand_cb_T)(p)
}

@(export)
ExpandSettingSubtract :: proc "c"(xp: rawptr, regmatch: rawptr, numMatches: ^C.int,
	matches: ^[^]^u8) -> C.int {
	if expand_option_idx_g == -1 {
		// term option
		return ExpandOldSetting(numMatches, matches)
	}

	option_val := (^^u8)(nvim_odin_get_varp_scope_from(expand_option_idx_g,
		expand_option_flags_g, curbuf, curwin))^

	option_flags := opt_at(expand_option_idx_g).flags

	if option_has_type(expand_option_idx_g, 1) { // Number
		return ExpandOldSetting(numMatches, matches)
	} else if (option_flags & kOptFlagComma_S) != 0 {
		// Split by comma, present each item to the user.
		if b_at(option_val, 0) == 0 {
			return 0 // FAIL
		}

		option_copy := xstrdup_r2(transmute(cstring)(option_val))
		next_val := option_copy
		ga: Garray
		ga_init_o(&ga, 8, 10)

		for {
			item := next_val
			comma_c := _vim_strchr(transmute(cstring)(next_val), ',')
			comma: ^u8 = nil
			if comma_c != nil {
				comma = transmute(^u8)(comma_c)
			}
			for comma != nil && comma != next_val && b_at(p_minus_1(comma), 0) == '\\' {
				next_c := _vim_strchr(transmute(cstring)((^u8)(uintptr(comma) + 1)), ',')
				if next_c == nil {
					comma = nil
				} else {
					comma = transmute(^u8)(next_c)
				}
			}
			if comma != nil {
				b_set(comma, 0, 0) // null-terminate this value
				next_val = (^u8)(uintptr(comma) + 1)
			} else {
				next_val = nil
			}
			if b_at(item, 0) == 0 {
				if next_val == nil {
					break
				}
				continue
			}
			if vim_regexec_o2(regmatch, item, 0) == 0 {
				if next_val == nil {
					break
				}
				continue
			}
			buf := escape_option_str_cmdline(item)
			ga_append_ptr(&ga, buf)
			if next_val == nil {
				break
			}
		}

		xfree(option_copy)

		matches^ = ([^]^u8)(ga.ga_data)
		numMatches^ = ga.ga_len
		return 1 // OK
	} else if (option_flags & kOptFlagFlagList_S) != 0 {
		// Only present flags that are set on the option.
		pat := (^rawptr)(uintptr(xp) + XPP_PATTERN)^
		if b_at((^u8)(pat), 0) != 0 {
			return 0 // FAIL
		}

		num_flags := libc.strlen(transmute(cstring)(option_val))
		if num_flags == 0 {
			return 0 // FAIL
		}

		matches^ = ([^]^u8)(xmalloc_o((num_flags + 1) * 8))

		count: C.int = 0
		(matches^)[count] = xmemdupz_o2(option_val, C.size_t(num_flags))
		count += 1

		if num_flags > 1 {
			// Split into individual chars.
			i: uintptr = 0
			for i < uintptr(num_flags) {
				flag := (^u8)(uintptr(option_val) + i)
				(matches^)[count] = xmemdupz_o2(flag, 1)
				count += 1
				i += 1
			}
		}

		numMatches^ = count
		return 1 // OK
	}

	// Otherwise just offer the existing value.
	return ExpandOldSetting(numMatches, matches)
}

foreign _ {
	@(link_name = "ga_init")
	ga_init_o :: proc "c" (gap: ^Garray, itemsize: C.int, growsize: C.int) ---
	@(link_name = "ga_grow")
	ga_grow_o :: proc "c" (gap: ^Garray, n: C.int) ---
}

ga_append_ptr :: proc "c"(gap: ^Garray, item: rawptr) {
	ga_grow_o(gap, 1)
	if gap.ga_data == nil {
		return
	}
	(^rawptr)(uintptr(gap.ga_data) + uintptr(gap.ga_len) * 8)^ = item
	gap.ga_len += 1
}

foreign _ {
	@(link_name = "tv_dict_add_tv")
	tv_dict_add_tv_c :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, tv: ^Typval_T) -> C.int ---
}

@(export)
did_set_global_undolevels :: proc "c"(value: C.longlong, old_value: C.longlong) -> cstring {
	// sync undo before 'undolevels' changes
	// use the old value, otherwise u_sync() may not work properly
	p_ul = old_value
	u_sync(true)
	p_ul = value
	return nil
}

@(export)
did_set_buflocal_undolevels :: proc "c"(buf: rawptr, value: C.longlong, old_value: C.longlong) -> cstring {
	// use the old value, otherwise u_sync() may not work properly
	(^C.longlong)(uintptr(buf) + B_P_UL_OFF2)^ = old_value
	u_sync(true)
	(^C.longlong)(uintptr(buf) + B_P_UL_OFF2)^ = value
	return nil
}

B_P_UL_OFF2 :: 10928

@(export)
get_winbuf_options :: proc "c"(bufopt: C.int) -> rawptr {
	d := tv_dict_alloc_m()

	opt_idx: C.int = 0
	for opt_idx < 377 {
		opt := opt_at(opt_idx)

		if (bufopt != 0 && option_has_scope_o(opt_idx, 2)) ||
		(bufopt == 0 && option_has_scope_o(opt_idx, 1)) {
			varp := nvim_odin_get_varp_from(opt_idx, curbuf, curwin)

			if varp != nil {
				opt_tv := optval_as_tv_c(optval_from_varp(opt_idx, varp), true)
				tv_dict_add_tv_c(d, transmute(cstring)(opt.fullname),
					C.size_t(libc.strlen(transmute(cstring)(opt.fullname))), &opt_tv)
			}
		}
		opt_idx += 1
	}

	return d
}

// option_has_scope helper (kOptScopeBuf=2, kOptScopeWin=1)
option_has_scope_o :: #force_inline proc "c"(opt_idx: C.int, scope: C.int) -> bool {
	return (opt_at(opt_idx).scope_flags & u8(1 << u32(scope))) != 0
}


E_NUMBER_REQUIRED :: cstring("E521: Number required after =")
E_INVARG_474 :: cstring("E474: Invalid argument")

@(export)
get_option_newval :: proc "c"(opt_idx: C.int, opt_flags: C.int, prefix: C.int, argp: ^^u8,
	nextchar: C.int, op: C.int, flags: C.uint32_t, varp: rawptr,
	oldval_override: rawptr, errbuf: ^u8, errbuflen: C.size_t,
	errmsg: ^cstring) -> OptVal {
	_ = flags
	_ = errbuf
	_ = errbuflen

	assert_ok := varp != nil
	if !assert_ok {
		return nil_optval()
	}

	newval := nil_optval()

	if nextchar == '&' {
		// ":set opt&": Reset to default value.
		return optval_copy(get_option_default(opt_idx, OPT_GLOBAL_S))
	} else if nextchar == '<' {
		// ":set opt<": Reset to global value.
		if option_is_global_local_shim(opt_idx) && (opt_flags & OPT_LOCAL_S) == 0 {
			unset_option_local_value_o(opt_idx)
		}
		return get_option_value(opt_idx, OPT_GLOBAL_S)
	}

	oldval: OptVal
	if oldval_override != nil {
		oldval = (^OptVal)(oldval_override)^
	} else {
		oldval_is_global := option_is_global_local_shim(opt_idx) && (opt_flags & OPT_LOCAL_S) != 0
		if oldval_is_global {
			oldval = optval_from_varp(opt_idx, nvim_odin_opt_varp(opt_idx))
		} else {
			oldval = optval_from_varp(opt_idx, varp)
		}
	}

	switch oldval.typ {
	case kOptValTypeNil:
		libc.abort()
	case kOptValTypeBoolean:
		newval_bool: C.int

		if nextchar == '!' { // ":set opt!": invert
			cur := ov_boolean(&oldval)^
			switch cur {
			case -1: // kNone
				newval_bool = -1
			case 1: // kTrue
				newval_bool = 0
			case 0: // kFalse
				newval_bool = 1
			case:
				newval_bool = -1
			}
		} else {
			// ":set invopt" / ":set opt" / ":set noopt"
			if prefix == 2 { // PREFIX_INV
				cur_b := (^C.int)(varp)^
				xor_val := xor_cint(cur_b, 1)
				newval_bool = xor_val != 0 ? 1 : 0
			} else {
				newval_bool = prefix == 0 ? 0 : 1
			}
		}
		newval = bool_optval(newval_bool)
	case kOptValTypeNumber:
		oldval_num := ov_number(&oldval)^
		newval_num: C.longlong

		arg := argp^
		arg = (^u8)(uintptr(arg) + 1)
		argp^ = arg
		arg = p_minus_1(arg)
		// NOTE: C does arg++ then reads *arg. We advanced argp by 1 already.

		if (^C.longlong)(varp) == &p_wc_g || (^C.longlong)(varp) == &p_wcm_g {
			a0 := b_at(argp^, 0)
			a1 := b_at(argp^, 1)
			if a0 == '<' || a0 == '^' ||
			(a0 != 0 && (a1 == 0 || is_ascii_white(a1)) && !is_ascii_digit(a0)) {
				newval_num = C.longlong(string_to_key(argp^))
				if newval_num == 0 {
					errmsg^ = E_INVARG_474
					return newval
				}
			} else if a0 == '-' || is_ascii_digit(a0) {
				i: C.int = 0
				vim_str2nr_r(transmute(cstring)(argp^), nil, &i, STR2NR_ALL_S, &newval_num, nil, 0, true, nil)
				if i == 0 || (b_at(argp^, i) != 0 && !is_ascii_white(b_at(argp^, i))) {
					errmsg^ = E_NUMBER_REQUIRED
					return newval
				}
			} else {
				errmsg^ = E_NUMBER_REQUIRED
				return newval
			}
		} else {
			a0 := b_at(argp^, 0)
			if a0 == '-' || is_ascii_digit(a0) {
				i: C.int = 0
				vim_str2nr_r(transmute(cstring)(argp^), nil, &i, STR2NR_ALL_S, &newval_num, nil, 0, true, nil)
				if i == 0 || (b_at(argp^, i) != 0 && !is_ascii_white(b_at(argp^, i))) {
					errmsg^ = E_NUMBER_REQUIRED
					return newval
				}
			} else {
				errmsg^ = E_NUMBER_REQUIRED
				return newval
			}
		}

		if op == OP_ADDING_S {
			newval_num = oldval_num + newval_num
		}
		if op == OP_PREPENDING_S {
			newval_num = oldval_num * newval_num
		}
		if op == OP_REMOVING_S {
			newval_num = oldval_num - newval_num
		}

		newval = num_optval(newval_num)
	case kOptValTypeString:
		oldval_str := ov_str_data(&oldval)
		op_local := op
		newval_str := stropt_get_newval(opt_idx, argp, varp, transmute(cstring)(oldval_str), &op_local)
		newval = str_optval(newval_str, libc.strlen(transmute(cstring)(newval_str)))
	case:
	}

	return newval
}

xor_cint :: #force_inline proc "c"(a: C.int, b: C.int) -> C.int {
	return a ~ b
}

is_ascii_white :: #force_inline proc "c"(b: u8) -> bool {
	return b == ' ' || b == '\t'
}
is_ascii_digit :: #force_inline proc "c"(b: u8) -> bool {
	return b >= '0' && b <= '9'
}

foreign _ {
	@(link_name = "ga_concat_strings")
	ga_concat_strings_c :: proc "c" (gap: ^Garray, sep: cstring) -> ^u8 ---
	@(link_name = "sort_strings")
	sort_strings_c :: proc "c" (files: rawptr, count: C.int) ---
	@(link_name = "concat_str")
	concat_str_c :: proc "c" (str1: cstring, str2: cstring) -> ^u8 ---
}

kObjectTypeNil_S :: 0
kObjectTypeBoolean_S :: 1
kObjectTypeInteger_S :: 2
kObjectTypeString_S :: 4
kObjectTypeArray_S :: 5
kObjectTypeDict_S :: 6

OBJ_DATA_OFF :: 8

@(export)
optval_as_object :: proc "c"(o_in: OptVal) -> Api_Object {
	o := o_in
	switch o.typ {
	case kOptValTypeNil:
		return Api_Object{t = kObjectTypeNil_S}
	case kOptValTypeBoolean:
		b := ov_boolean(&o)^
		if b == 0 || b == 1 {
			obj := Api_Object{t = kObjectTypeBoolean_S}
			(^C.int)(uintptr(&obj) + OBJ_DATA_OFF)^ = b
			return obj
		}
		return Api_Object{t = kObjectTypeNil_S}
	case kOptValTypeNumber:
		obj := Api_Object{t = kObjectTypeInteger_S}
		(^C.longlong)(uintptr(&obj) + OBJ_DATA_OFF)^ = ov_number(&o)^
		return obj
	case kOptValTypeString:
		obj := Api_Object{t = kObjectTypeString_S}
		(^NvimString)(uintptr(&obj) + OBJ_DATA_OFF)^ = (^NvimString)(uintptr(&o) + 8)^
		return obj
	case:
	}
	return Api_Object{t = kObjectTypeNil_S}
}

@(export)
object_as_optval :: proc "c"(o: Api_Object, error: ^bool) -> OptVal {
	oc := o
	switch oc.t {
	case kObjectTypeNil_S:
		return nil_optval()
	case kObjectTypeBoolean_S:
		return bool_optval((^C.int)(uintptr(&oc) + OBJ_DATA_OFF)^)
	case kObjectTypeInteger_S:
		return num_optval((^C.longlong)(uintptr(&oc) + OBJ_DATA_OFF)^)
	case kObjectTypeString_S:
		s := (^NvimString)(uintptr(&oc) + OBJ_DATA_OFF)^
		return str_optval((^u8)(s.data), s.size)
	case:
		error^ = true
	}
	return nil_optval()
}

foreign _ {
	@(link_name = "nvim_create_namespace")
	nvim_create_namespace_c :: proc "c" (name: NvimString) -> C.int ---
	@(link_name = "get_decor_provider")
	get_decor_provider_c :: proc "c" (ns: C.int, force: bool) -> rawptr ---
	@(link_name = "ns_hl_def")
	ns_hl_def_c :: proc "c" (ns: C.int, hl_id: C.int, attrs: HlAttrs, attr_id: C.int, info: rawptr) ---
	@(link_name = "syn_check_group")
	syn_check_group_c :: proc "c" (name: ^u8, len: C.size_t) -> C.int ---
	@(link_name = "xstrchrnul")
	xstrchrnul_c :: proc "c" (str: ^u8, c: C.int) -> ^u8 ---
}


HL_GLOBAL_S :: 0x4000

W_NS_HL_OFF :: 24
W_NS_HL_WINHL_OFF :: 28
W_P_WINHL_OFF :: 1192
W_HL_NEEDS_UPDATE_OFF :: 100

@(export)
parse_winhl_opt :: proc "c"(winhl: ^u8, wp: rawptr) -> bool {
	p: ^u8 = empty_string_option_c
	if winhl != nil {
		p = winhl
	} else if wp != nil {
		p2 := (^^u8)(uintptr(wp) + W_P_WINHL_OFF)^ // w_p_winhl
		if p2 == nil {
			p2 = empty_string_option_c
		}
		p = p2
	}

	if b_at(p, 0) == 0 {
		if wp != nil && (^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^ > 0 &&
		(^C.int)(uintptr(wp) + W_NS_HL_OFF)^ == (^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^ {
			(^C.int)(uintptr(wp) + W_NS_HL_OFF)^ = 0
			(^C.int)(uintptr(wp) + W_HL_NEEDS_UPDATE_OFF)^ = 1
		}
		return true
	}

	ns_hl: C.int = 0
	if wp != nil {
		if (^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^ == 0 {
			(^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^ =
				nvim_create_namespace_c(NvimString{data = nil, size = 0})
		} else {
			// Namespace already exists. Invalidate existing items.
			dp := get_decor_provider_c((^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^, true)
			(^C.int)(uintptr(dp) + 52)^ += 1 // DecorProvider.hl_valid @52
		}
		ns_hl = (^C.int)(uintptr(wp) + W_NS_HL_WINHL_OFF)^
		if (^C.int)(uintptr(wp) + W_NS_HL_OFF)^ <= 0 {
			(^C.int)(uintptr(wp) + W_NS_HL_OFF)^ = ns_hl
		}
	}

	for b_at(p, 0) != 0 {
		colon := libc.strchr(transmute(cstring)(p), ':')
		if colon == nil {
			return false
		}
		nlen := uintptr(transmute(rawptr)(colon)) - uintptr(p)
		hi := (^u8)(uintptr(colon) + 1)
		commap := xstrchrnul_c(hi, ',')
		len := uintptr(commap) - uintptr(hi)
		hl_id: C.int = -1
		if len != 0 {
			hl_id = syn_check_group_c(hi, C.size_t(len))
		}
		if hl_id == 0 {
			return false
		}
		hl_id_link: C.int = 0
		if nlen != 0 {
			hl_id_link = syn_check_group_c(p, C.size_t(nlen))
		}
		if hl_id_link == 0 {
			return false
		}

		if wp != nil {
			attrs: HlAttrs
			attrs.rgb_ae_attr |= HL_GLOBAL_S
			ns_hl_def_c(ns_hl, hl_id_link, attrs, hl_id, nil)
		}

		if b_at(commap, 0) != 0 {
			p = (^u8)(uintptr(commap) + 1)
		} else {
			p = empty_string_option_c
		}
	}

	if wp != nil {
		(^C.int)(uintptr(wp) + W_HL_NEEDS_UPDATE_OFF)^ = 1
	}
	return true
}

Api_Array :: struct {
	size:     C.size_t,
	capacity: C.size_t,
	items:    ^Api_Object,
}
#assert(size_of(Api_Array) == 24)

kOptFlagNoDup_S :: 1 << 12
kOptWildchar_S :: 349
kOptWildcharm_S :: 350

OP_REMOVING_FOR :: 3 // OP_REMOVING
OP_NONE_FOR :: 0

ga_append_str :: proc "c"(gap: ^Garray, item: ^u8) {
	ga_grow_o(gap, 1)
	if gap.ga_data == nil {
		return
	}
	(^rawptr)(uintptr(gap.ga_data) + uintptr(gap.ga_len) * 8)^ = item
	gap.ga_len += 1
}

@(export)
object_as_optval_for :: proc "c"(opt_idx: C.int, o: Api_Object, op: C.int, error: ^bool) -> OptVal {
	oc := o
	if oc.t == kObjectTypeNil_S {
		return nil_optval()
	}

	flags := opt_at(opt_idx).flags
	is_list := (flags & (kOptFlagComma_S | kOptFlagFlagList_S)) != 0
	is_map := (flags & kOptFlagColon_S) != 0
	is_flaglist := (flags & kOptFlagFlagList_S) != 0
	is_comma := (flags & kOptFlagComma_S) != 0
	allow_dup := (flags & kOptFlagNoDup_S) == 0

	type_ok := false
	switch oc.t {
	case kObjectTypeBoolean_S:
		type_ok = option_has_type(opt_idx, kOptValTypeBoolean)
	case kObjectTypeInteger_S:
		type_ok = option_has_type(opt_idx, kOptValTypeNumber)
	case kObjectTypeString_S:
		type_ok = option_has_type(opt_idx, kOptValTypeString) ||
		opt_idx == kOptWildchar_S || opt_idx == kOptWildcharm_S
	case kObjectTypeArray_S:
		type_ok = is_list
	case kObjectTypeDict_S:
		type_ok = is_map || is_flaglist
	case:
	}
	if !type_ok {
		error^ = true
		return nil_optval()
	}

	switch oc.t {
	case kObjectTypeBoolean_S, kObjectTypeInteger_S:
		return object_as_optval(oc, error)
	case:
	}

	str: ^u8 = nil
	if oc.t == kObjectTypeString_S {
		s := (^NvimString)(uintptr(&oc) + OBJ_DATA_OFF)^
		str = xstrdup_r2(transmute(cstring)(s.data))
	} else if oc.t == kObjectTypeArray_S {
		arr := (^Api_Array)(uintptr(&oc) + OBJ_DATA_OFF)^
		ga: Garray
		ga_init_o(&ga, 8, 4)
		ai: C.size_t = 0
		for ai < arr.size {
			item_ptr := (^Api_Object)(uintptr(arr.items) + uintptr(ai) * size_of(Api_Object))
			item := item_ptr^
			if item.t != kObjectTypeString_S {
				error^ = true
				ga_deep_clear_ptr(&ga)
				return nil_optval()
			}
			dup := false
			j: C.int = 0
			for !allow_dup && j < ga.ga_len {
				ga_item := (^rawptr)(uintptr(ga.ga_data) + uintptr(j) * 8)^
				if libc.strcmp(transmute(cstring)(ga_item), transmute(cstring)(item_string_data(item_ptr))) == 0 {
					dup = true
					break
				}
				j += 1
			}
			if !dup {
				ga_append_str(&ga, xstrdup_r2(transmute(cstring)(item_string_data(item_ptr))))
			}
			ai += 1
		}
		str = ga_concat_strings_c(&ga, ",")
		ga_deep_clear_ptr(&ga)
	} else {
		// kObjectTypeDict
		dict := (^Api_Dict)(uintptr(&oc) + OBJ_DATA_OFF)^
		ga: Garray
		ga_init_o(&ga, 8, 4)
		di: C.size_t = 0
		for di < dict.size {
			kv_ptr := (^Key_Value_Pair)(uintptr(dict.items) + uintptr(di) * size_of(Key_Value_Pair))
			kv := kv_ptr^
			v := kv.value
			if is_flaglist {
				truthy := true
				if v.t == kObjectTypeNil_S {
					truthy = false
				} else if v.t == kObjectTypeBoolean_S && (^C.int)(uintptr(&kv.value) + OBJ_DATA_OFF)^ == 0 {
					truthy = false
				}
				if truthy {
					ga_append_str(&ga, xstrdup_r2(transmute(cstring)(kv.key.data)))
				}
			} else if v.t == kObjectTypeString_S {
				vs := (^NvimString)(uintptr(&kv.value) + OBJ_DATA_OFF)^
				kv_str := concat_str_c(transmute(cstring)(kv.key.data), ":")
				ga_append_str(&ga, concat_str_c(transmute(cstring)(kv_str), transmute(cstring)(vs.data)))
				xfree(kv_str)
			} else {
				error^ = true
				ga_deep_clear_ptr(&ga)
				return nil_optval()
			}
			di += 1
		}
		if ga.ga_len > 0 && (is_map || is_comma) {
			sort_strings_c(ga.ga_data, ga.ga_len)
		}
		{
		sep := cstring(",")
		if is_flaglist && !is_comma {
			sep = cstring("")
		}
		str = ga_concat_strings_c(&ga, sep)
	}
		ga_deep_clear_ptr(&ga)
	}

	// `:set-=` on a "key:value" list matches by "key:".
	if op == OP_REMOVING_FOR && is_map && libc.strchr(transmute(cstring)(str), ':') == nil {
		with_colon := concat_str_c(transmute(cstring)(str), ":")
		xfree(str)
		str = with_colon
	}

	return str_optval(str, libc.strlen(transmute(cstring)(str)))
}

item_string_data :: #force_inline proc "c"(item: rawptr) -> ^u8 {
	s := (^NvimString)(uintptr(item) + OBJ_DATA_OFF)^
	return (^u8)(s.data)
}

ga_deep_clear_ptr :: proc "c"(gap: ^Garray) {
	if gap.ga_data != nil {
		i: C.int = 0
		for i < gap.ga_len {
			p := (^rawptr)(uintptr(gap.ga_data) + uintptr(i) * 8)^
			if p != nil {
				xfree(p)
			}
			i += 1
		}
		xfree(gap.ga_data)
		gap.ga_data = nil
	}
	gap.ga_len = 0
	gap.ga_maxlen = 0
}

foreign _ {
	@(link_name = "nvim_odin_vimoption2dict")
	vimoption2dict_c :: proc "c" (opt: ^vimoption_T, opt_flags: C.int, buf: rawptr, win: rawptr, arena: rawptr) -> Api_Dict ---
	@(link_name = "arena_dict")
	arena_dict_c :: proc "c" (arena: rawptr, size: C.size_t) -> Api_Dict ---
	@(link_name = "nvim_odin_put_c")
	put_c_dict_c :: proc "c" (d: rawptr, key: cstring, value: Api_Object) ---
	@(link_name = "xstrlcpy")
	xstrlcpy_o :: proc "c" (dst: cstring, src: cstring, dsize: C.size_t) -> C.size_t ---
}

CSTR_AS_OBJ :: #force_inline proc "c"(s: ^u8) -> Api_Object {
	obj := Api_Object{t = kObjectTypeString_S}
	ns := NvimString{data = transmute(cstring)(s), size = libc.strlen(transmute(cstring)(s))}
	(^NvimString)(uintptr(&obj) + OBJ_DATA_OFF)^ = ns
	return obj
}

DICT_OBJ :: #force_inline proc "c"(d: Api_Dict) -> Api_Object {
	obj := Api_Object{t = kObjectTypeDict_S}
	(^Api_Dict)(uintptr(&obj) + OBJ_DATA_OFF)^ = d
	return obj
}

BOOL_OBJ :: #force_inline proc "c"(b: C.int) -> Api_Object {
	obj := Api_Object{t = kObjectTypeBoolean_S}
	(^C.int)(uintptr(&obj) + OBJ_DATA_OFF)^ = b
	return obj
}

INT_OBJ :: #force_inline proc "c"(n: i64) -> Api_Object {
	obj := Api_Object{t = kObjectTypeInteger_S}
	(^i64)(uintptr(&obj) + OBJ_DATA_OFF)^ = n
	return obj
}

@(export)
get_vimoption :: proc "c"(name: NvimString, opt_flags: C.int, buf: rawptr, win: rawptr,
	arena: rawptr, err: rawptr) -> Api_Dict {
	opt_idx := nvim_odin_find_option_len(transmute(cstring)(name.data), name.size)
	if opt_idx == -1 {
		api_set_error_r(err, 1, "option (not found): %s", transmute(rawptr)(name.data))
		return Api_Dict{}
	}
	return vimoption2dict_c(opt_at_ptr(opt_idx), opt_flags, buf, win, arena)
}

@(export)
get_all_vimoptions :: proc "c"(arena: rawptr) -> Api_Dict {
	retval := arena_dict_c(arena, 377)
	opt_idx: C.int = 0
	for opt_idx < 377 {
		opt_dict := vimoption2dict_c(opt_at_ptr(opt_idx), OPT_GLOBAL_S, curbuf, curwin, arena)
		put_c_dict_c(&retval, transmute(cstring)(opt_at_ptr(opt_idx).fullname), DICT_OBJ(opt_dict))
		opt_idx += 1
	}
	return retval
}

opt_at_ptr :: #force_inline proc "c"(opt_idx: C.int) -> ^vimoption_T {
	table := ([^]vimoption_T)(nvim_odin_opt_table())
	return (^vimoption_T)(uintptr(table) + uintptr(opt_idx) * size_of(vimoption_T))
}

foreign _ {
	@(link_name = "free_buf_options")
	free_buf_options_c :: proc "c" (buf: rawptr, free_p_ff: bool) ---
	@(link_name = "check_buf_options")
	check_buf_options_c :: proc "c" (buf: rawptr) ---
	@(link_name = "set_buflocal_cpt_callbacks")
	set_buflocal_cpt_callbacks_c :: proc "c" (buf: rawptr) ---
	@(link_name = "set_buflocal_cfu_callback")
	set_buflocal_cfu_callback_c :: proc "c" (buf: rawptr) ---
	@(link_name = "set_buflocal_ofu_callback")
	set_buflocal_ofu_callback_c :: proc "c" (buf: rawptr) ---
	@(link_name = "set_buflocal_tfu_callback")
	set_buflocal_tfu_callback_c :: proc "c" (buf: rawptr) ---
}

CPO_BUFOPT_S :: 's'
CPO_BUFOPTGLOB_S :: 'S'
BCO_ENTER_S :: 1
BCO_ALWAYS_S :: 2
BCO_NOHELP_S :: 4
KEYMAP_INIT_S :: 1
CMOD_NOSWAPFILE_S :: 0x2000

B_P_INITIALIZED_OFF :: 7888
B_HELP_OFF :: 11170
B_KMAP_STATE_OFF :: 7856
B_P_CHANNEL_OFF :: 10176

// synblock fields: buf_T.b_s @11264, synblock_T offsets probed:
B_S_OFF :: 11264
SB_SYN_ISK :: B_S_OFF + 1168 // b_syn_isk within synblock
SB_P_SPC :: B_S_OFF + 1088
SB_P_SPF :: B_S_OFF + 1104
SB_P_SPL :: B_S_OFF + 1112
SB_P_SPO :: B_S_OFF + 1120
SB_P_SPO_FLAGS :: B_S_OFF + 1128

foreign _ {
	@(link_name = "p_ai")
	p_ai_g: C.int
	@(link_name = "nvim_odin_get_p_ai_nopaste")
	get_p_ai_nopaste_c :: proc "c" () -> C.int ---
	@(link_name = "p_sw")
	p_sw_g: C.longlong
	@(link_name = "p_scbk")
	p_scbk_g: C.longlong
	@(link_name = "nvim_odin_get_p_tw_nopaste")
	get_p_tw_nopaste_c :: proc "c" () -> C.longlong ---
	@(link_name = "nvim_odin_get_p_wm_nopaste")
	get_p_wm_nopaste_c :: proc "c" () -> C.longlong ---
	@(link_name = "p_bomb")
	p_bomb_g: C.int
	@(link_name = "p_fixeol")
	p_fixeol_g: C.int
	@(link_name = "nvim_odin_get_p_et_nopaste")
	get_p_et_nopaste_c :: proc "c" () -> C.int ---
	@(link_name = "p_inf")
	p_inf_g: C.int
	@(link_name = "p_swf")
	p_swf_g: C.int
	@(link_name = "p_cpt")
	p_cpt_g: ^u8
	@(link_name = "p_cfu")
	p_cfu_g: ^u8
	@(link_name = "p_ofu")
	p_ofu_g: ^u8
	@(link_name = "p_tfu")
	p_tfu_g: ^u8
	@(link_name = "p_sts")
	p_sts_g: C.longlong
	@(link_name = "nvim_odin_get_p_sts_nopaste")
	get_p_sts_nopaste_c :: proc "c" () -> C.longlong ---
	@(link_name = "p_vsts")
	p_vsts_g: ^u8
	@(link_name = "nvim_odin_get_p_vsts_nopaste")
	get_p_vsts_nopaste_c :: proc "c" () -> ^u8 ---
	@(link_name = "p_com")
	p_com_g: ^u8
	@(link_name = "p_cms")
	p_cms_g: ^u8
	@(link_name = "p_fo")
	p_fo_g: ^u8
	@(link_name = "p_nf")
	p_nf_g: ^u8
	@(link_name = "p_mps")
	p_mps_g: ^u8
	@(link_name = "p_si")
	p_si_g: C.int
	@(link_name = "p_ci")
	p_ci_g: C.int
	@(link_name = "p_cin")
	p_cin_g: C.int
	@(link_name = "p_cink")
	p_cink_g: ^u8
	@(link_name = "p_cino")
	p_cino_g: ^u8
	@(link_name = "p_cinsd")
	p_cinsd_g: ^u8
	@(link_name = "p_lop")
	p_lop_g: ^u8
	@(link_name = "p_pi")
	p_pi_g: C.int
	@(link_name = "p_cinw")
	p_cinw_g: ^u8
	@(link_name = "p_lisp")
	p_lisp_g: C.int
	@(link_name = "p_smc")
	p_smc_g: C.longlong
	@(link_name = "p_spc")
	p_spc_g: ^u8
	@(link_name = "p_spf")
	p_spf_g: ^u8
	@(link_name = "p_spl")
	p_spl_g: ^u8
	@(link_name = "p_spo")
	p_spo_g: ^u8
	@(link_name = "spo_flags")
	spo_flags_g: C.uint32_t
	@(link_name = "p_inde")
	p_inde_g: ^u8
	@(link_name = "p_indk")
	p_indk_g: ^u8
	@(link_name = "p_fex")
	p_fex_g: ^u8
	@(link_name = "p_sua")
	p_sua_g: ^u8
	@(link_name = "p_qe")
	p_qe_g: ^u8
	@(link_name = "p_udf")
	p_udf_g: C.int
	@(link_name = "p_inex")
	p_inex_g: ^u8
	@(link_name = "p_isk")
	p_isk_g: ^u8
	@(link_name = "p_ts")
	p_ts_g: C.longlong
	@(link_name = "p_vts")
	p_vts_g: ^u8
	@(link_name = "p_fenc")
	p_fenc_g: ^u8
	@(link_name = "p_ff")
	p_ff_g: ^u8
}

// COPY_OPT_SCTX(buf, bv): buf->b_p_script_ctx[bv] = options[buf_opt_idx[bv]].script_ctx
// Table generated from build/src/nvim/auto/options_enum.generated.h (kBufOpt* → kOpt*).
buf_opt_idx_tbl := [92]C.int{6,9,10,16,21,22,27,28,29,30,35,38,39,40,41,42,48,49,51,52,54,55,60,67,69,71,81,82,84,87,90,92,94,97,99,100,114,115,116,117,118,120,121,142,143,145,146,148,149,150,154,158,160,171,172,173,179,180,181,191,194,195,205,208,218,219,230,231,245,268,281,284,286,287,288,289,298,299,301,302,306,308,309,312,320,321,322,334,335,339,340,371}

copy_opt_sctx :: #force_inline proc "c"(buf: rawptr, bv: C.int) {
	dst := (^sctx_T)(uintptr(buf) + B_P_SCRIPT_CTX_OFF + uintptr(bv) * 24)
	src := (^sctx_T)(uintptr(opt_at_ptr(buf_opt_idx_tbl[bv])) + 144) // script_ctx @144
	dst^ = src^
}

@(export)
buf_copy_options :: proc "c"(buf: rawptr, flags: C.int) {
	should_copy := true
	save_p_isk: ^u8 = nil
	did_isk := false

	if p_cpo != nil {
		if (_vim_strchr(transmute(cstring)(p_cpo), CPO_BUFOPTGLOB_S) == nil ||
		(flags & BCO_ENTER_S) == 0) &&
		((^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^ ||
		((flags & BCO_ENTER_S) == 0 &&
		_vim_strchr(transmute(cstring)(p_cpo), CPO_BUFOPT_S) != nil)) {
			should_copy = false
		}

		if should_copy || (flags & BCO_ALWAYS_S) != 0 {
			// CLEAR_FIELD(buf->b_p_script_ctx)
			libc.memset(transmute(rawptr)(uintptr(buf) + B_P_SCRIPT_CTX_OFF), 0, 24 * 92)

			dont_do_help := ((flags & BCO_NOHELP_S) != 0 &&
			(^bool)(uintptr(buf) + B_HELP_OFF)^) ||
			(^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^
			if dont_do_help {
				save_p_isk = (^^u8)(uintptr(buf) + B_P_ISK_OFF)^
				(^^u8)(uintptr(buf) + B_P_ISK_OFF)^ = nil
			}
			if !(^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^ {
				free_buf_options_c(buf, true)
				(^C.int)(uintptr(buf) + B_P_RO_OFF)^ = 0
				(^^u8)(uintptr(buf) + B_P_FENC_OFF)^ = xstrdup_r2(transmute(cstring)(p_fenc_g))
				ffs0 := b_at(p_ffs_g, 0)
				if ffs0 == 'm' {
					(^^u8)(uintptr(buf) + B_P_FF_OFF)^ = xstrdup_r2(cstring("mac"))
				} else if ffs0 == 'd' {
					(^^u8)(uintptr(buf) + B_P_FF_OFF)^ = xstrdup_r2(cstring("dos"))
				} else if ffs0 == 'u' {
					(^^u8)(uintptr(buf) + B_P_FF_OFF)^ = xstrdup_r2(cstring("unix"))
				} else {
					(^^u8)(uintptr(buf) + B_P_FF_OFF)^ = xstrdup_r2(transmute(cstring)(p_ff_g))
				}
				(^^u8)(uintptr(buf) + B_P_BH_OFF)^ = empty_string_option_c
				(^^u8)(uintptr(buf) + B_P_BT_OFF)^ = empty_string_option_c
			} else {
				free_buf_options_c(buf, false)
			}

			bp := buf
			(^C.int)(uintptr(bp) + B_P_AI_OFF)^ = p_ai_g
			copy_opt_sctx(bp, 1) // kBufOptAutoindent=1
			(^C.int)(uintptr(bp) + B_P_AI_NOPASTE_OFF)^ = get_p_ai_nopaste_c()
			(^C.longlong)(uintptr(bp) + B_P_SW_OFF)^ = p_sw_g
			copy_opt_sctx(bp, 69)
			(^C.longlong)(uintptr(bp) + B_P_SCBK_OFF)^ = p_scbk_g
			copy_opt_sctx(bp, 68)
			(^C.longlong)(uintptr(bp) + B_P_TW_OFF2)^ = p_tw_g
			copy_opt_sctx(bp, 84)
			(^C.longlong)(uintptr(bp) + B_P_TW_NOPASTE_OFF)^ = get_p_tw_nopaste_c()
			(^C.longlong)(uintptr(bp) + B_P_TW_NOBIN_OFF)^ = get_p_tw_nobin_c()
			(^C.longlong)(uintptr(bp) + B_P_WM_OFF2)^ = p_wm_g
			copy_opt_sctx(bp, 91)
			(^C.longlong)(uintptr(bp) + B_P_WM_NOPASTE_OFF)^ = get_p_wm_nopaste_c()
			(^C.longlong)(uintptr(bp) + B_P_WM_NOBIN_OFF)^ = get_p_wm_nobin_c()
			(^C.int)(uintptr(bp) + B_P_BIN_OFF)^ = p_bin_g
			copy_opt_sctx(bp, 4)
			(^C.int)(uintptr(bp) + B_P_BOMB_OFF)^ = p_bomb_g
			copy_opt_sctx(bp, 5)
			(^C.int)(uintptr(bp) + B_P_ET_OFF2)^ = p_et_g
			copy_opt_sctx(bp, 30)
			(^C.int)(uintptr(bp) + B_P_FIXEOL_OFF)^ = p_fixeol_g
			copy_opt_sctx(bp, 35)
			(^C.int)(uintptr(bp) + B_P_ET_NOBIN_OFF)^ = get_p_et_nobin_c()
			(^C.int)(uintptr(bp) + B_P_ET_NOPASTE_OFF)^ = get_p_et_nopaste_c()
			(^C.int)(uintptr(bp) + B_P_ML_OFF2)^ = p_ml_g
			copy_opt_sctx(bp, 59)
			(^C.int)(uintptr(bp) + B_P_ML_NOBIN_OFF)^ = get_p_ml_nobin_c()
			(^C.int)(uintptr(bp) + B_P_INF_OFF)^ = p_inf_g
			copy_opt_sctx(bp, 49)
			if (cmdmod_cmod_flags & CMOD_NOSWAPFILE_S) != 0 {
				(^C.int)(uintptr(bp) + B_P_SWF_OFF)^ = 0
			} else {
				(^C.int)(uintptr(bp) + B_P_SWF_OFF)^ = p_swf_g
				copy_opt_sctx(bp, 77)
			}
			(^^u8)(uintptr(bp) + B_P_CPT_OFF)^ = xstrdup_r2(transmute(cstring)(p_cpt_g))
			copy_opt_sctx(bp, 18)
			set_buflocal_cpt_callbacks_c(bp)
			(^^u8)(uintptr(bp) + B_P_CFU_OFF)^ = xstrdup_r2(transmute(cstring)(p_cfu_g))
			copy_opt_sctx(bp, 19)
			set_buflocal_cfu_callback_c(bp)
			(^^u8)(uintptr(bp) + B_P_OFU_OFF)^ = xstrdup_r2(transmute(cstring)(p_ofu_g))
			copy_opt_sctx(bp, 63)
			set_buflocal_ofu_callback_c(bp)
			(^^u8)(uintptr(bp) + B_P_TFU_OFF)^ = xstrdup_r2(transmute(cstring)(p_tfu_g))
			copy_opt_sctx(bp, 82)
			set_buflocal_tfu_callback_c(bp)
			(^C.longlong)(uintptr(bp) + B_P_STS_OFF)^ = p_sts_g
			copy_opt_sctx(bp, 71)
			(^C.longlong)(uintptr(bp) + B_P_STS_NOPASTE_OFF)^ = get_p_sts_nopaste_c()
			(^^u8)(uintptr(bp) + B_P_VSTS_OFF)^ = xstrdup_r2(transmute(cstring)(p_vsts_g))
			copy_opt_sctx(bp, 89)
			if p_vsts_g != nil && p_vsts_g != empty_string_option_c {
				vsts_arr: ^rawptr = (^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)
				tabstop_set_o(p_vsts_g, (^^u8)(vsts_arr))
			} else {
				(^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)^ = nil
			}
			(^^u8)(uintptr(bp) + B_P_VSTS_NOPASTE_OFF)^ =
				get_p_vsts_nopaste_c() != nil ? xstrdup_r2(transmute(cstring)(get_p_vsts_nopaste_c())) : nil
			(^^u8)(uintptr(bp) + B_P_COM_OFF)^ = xstrdup_r2(transmute(cstring)(p_com_g))
			copy_opt_sctx(bp, 16)
			(^^u8)(uintptr(bp) + B_P_CMS_OFF)^ = xstrdup_r2(transmute(cstring)(p_cms_g))
			copy_opt_sctx(bp, 17)
			(^^u8)(uintptr(bp) + B_P_FO_OFF)^ = xstrdup_r2(transmute(cstring)(p_fo_g))
			copy_opt_sctx(bp, 38)
			(^^u8)(uintptr(bp) + B_P_FLP_OFF2)^ = xstrdup_r2(transmute(cstring)(p_flp_g))
			copy_opt_sctx(bp, 37)
			(^^u8)(uintptr(bp) + B_P_NF_OFF)^ = xstrdup_r2(transmute(cstring)(p_nf_g))
			copy_opt_sctx(bp, 62)
			(^^u8)(uintptr(bp) + B_P_MPS_OFF)^ = xstrdup_r2(transmute(cstring)(p_mps_g))
			copy_opt_sctx(bp, 58)
			(^C.int)(uintptr(bp) + B_P_SI_OFF)^ = p_si_g
			copy_opt_sctx(bp, 70)
			(^C.longlong)(uintptr(bp) + B_P_CHANNEL_OFF)^ = 0
			(^C.int)(uintptr(bp) + B_P_CI_OFF)^ = p_ci_g
			copy_opt_sctx(bp, 22)
			(^C.int)(uintptr(bp) + B_P_CIN_OFF)^ = p_cin_g
			copy_opt_sctx(bp, 11)
			(^^u8)(uintptr(bp) + B_P_CINK_OFF)^ = xstrdup_r2(transmute(cstring)(p_cink_g))
			copy_opt_sctx(bp, 12)
			(^^u8)(uintptr(bp) + B_P_CINO_OFF)^ = xstrdup_r2(transmute(cstring)(p_cino_g))
			copy_opt_sctx(bp, 13)
			(^^u8)(uintptr(bp) + B_P_CINSD_OFF)^ = xstrdup_r2(transmute(cstring)(p_cinsd_g))
			copy_opt_sctx(bp, 14)
			(^^u8)(uintptr(bp) + B_P_LOP_OFF)^ = xstrdup_r2(transmute(cstring)(p_lop_g))
			copy_opt_sctx(bp, 54)
			(^^u8)(uintptr(bp) + B_P_FT_OFF)^ = empty_string_option_c
			(^C.int)(uintptr(bp) + B_P_PI_OFF)^ = p_pi_g
			copy_opt_sctx(bp, 65)
			(^^u8)(uintptr(bp) + B_P_CINW_OFF)^ = xstrdup_r2(transmute(cstring)(p_cinw_g))
			copy_opt_sctx(bp, 15)
			(^C.int)(uintptr(bp) + B_P_LISP_OFF)^ = p_lisp_g
			copy_opt_sctx(bp, 53)
			(^^u8)(uintptr(bp) + B_P_SYN_OFF)^ = empty_string_option_c
			(^C.longlong)(uintptr(bp) + B_P_SMC_OFF)^ = p_smc_g
			copy_opt_sctx(bp, 78)
			(^^u8)(uintptr(bp) + SB_SYN_ISK)^ = transmute(^u8)(empty_string_option_c)
			(^^u8)(uintptr(bp) + SB_P_SPC)^ = transmute(^u8)(xstrdup_r2(transmute(cstring)(p_spc_g)))
			copy_opt_sctx(bp, 72)
			compile_cap_prog(transmute(rawptr)(uintptr(bp) + B_S_OFF))
			(^^u8)(uintptr(bp) + SB_P_SPF)^ = transmute(^u8)(xstrdup_r2(transmute(cstring)(p_spf_g)))
			copy_opt_sctx(bp, 73)
			(^^u8)(uintptr(bp) + SB_P_SPL)^ = transmute(^u8)(xstrdup_r2(transmute(cstring)(p_spl_g)))
			copy_opt_sctx(bp, 74)
			(^^u8)(uintptr(bp) + SB_P_SPO)^ = transmute(^u8)(xstrdup_r2(transmute(cstring)(p_spo_g)))
			copy_opt_sctx(bp, 75)
			(^C.uint32_t)(uintptr(bp) + SB_P_SPO_FLAGS)^ = spo_flags_g
			(^^u8)(uintptr(bp) + B_P_INDE_OFF)^ = xstrdup_r2(transmute(cstring)(p_inde_g))
			copy_opt_sctx(bp, 47)
			(^^u8)(uintptr(bp) + B_P_INDK_OFF)^ = xstrdup_r2(transmute(cstring)(p_indk_g))
			copy_opt_sctx(bp, 48)
			(^^u8)(uintptr(bp) + B_P_FP_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_FEX_OFF)^ = xstrdup_r2(transmute(cstring)(p_fex_g))
			copy_opt_sctx(bp, 36)
			(^^u8)(uintptr(bp) + B_P_SUA_OFF)^ = xstrdup_r2(transmute(cstring)(p_sua_g))
			copy_opt_sctx(bp, 76)
			(^^u8)(uintptr(bp) + B_P_KEYMAP_OFF)^ = xstrdup_r2(transmute(cstring)(p_keymap_opt))
			copy_opt_sctx(bp, 51)
			(^C.int)(uintptr(bp) + B_KMAP_STATE_OFF)^ |= KEYMAP_INIT_S
			(^C.longlong)(uintptr(bp) + B_P_IMINSERT_OFF)^ = C.longlong(p_iminsert_g)
			copy_opt_sctx(bp, 43)
			(^C.longlong)(uintptr(bp) + B_P_IMSEARCH_OFF)^ = C.longlong(p_imsearch_g)
			copy_opt_sctx(bp, 44)

			// global-local: don't copy, use global value
			(^C.int)(uintptr(bp) + B_P_AC_OFF)^ = -1
			(^C.int)(uintptr(bp) + B_P_AR_OFF)^ = -1
			(^C.longlong)(uintptr(bp) + B_P_FS_OFF)^ = -1
			(^C.longlong)(uintptr(bp) + B_P_UL_OFF2)^ = NO_LOCAL_UNDOLEVEL_S
			(^^u8)(uintptr(bp) + B_P_BKC_OFF)^ = empty_string_option_c
			(^C.uint)(uintptr(bp) + B_BKC_FLAGS_OFF)^ = 0
			(^^u8)(uintptr(bp) + B_P_GEFM_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_GP_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_MP_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_EFM_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_EP_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_FFU_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_KP_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_PATH_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_TAGS_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_TC_OFF)^ = empty_string_option_c
			(^C.uint)(uintptr(bp) + B_TC_FLAGS_OFF)^ = 0
			(^^u8)(uintptr(bp) + B_P_DEF_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_INC_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_INEX_OFF)^ = xstrdup_r2(transmute(cstring)(p_inex_g))
			copy_opt_sctx(bp, 46)
			(^^u8)(uintptr(bp) + B_P_COT_OFF)^ = empty_string_option_c
			(^C.uint)(uintptr(bp) + B_COT_FLAGS_OFF)^ = 0
			(^^u8)(uintptr(bp) + B_P_DICT_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_DIA_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_TSR_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_TSRFU_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_QE_OFF)^ = xstrdup_r2(transmute(cstring)(p_qe_g))
			(^C.int)(uintptr(bp) + B_P_UDF_OFF)^ = p_udf_g
			copy_opt_sctx(bp, 87)
			(^^u8)(uintptr(bp) + B_P_LW_OFF)^ = empty_string_option_c
			(^^u8)(uintptr(bp) + B_P_MENC_OFF)^ = empty_string_option_c

			if dont_do_help {
				(^^u8)(uintptr(bp) + B_P_ISK_OFF)^ = save_p_isk
				if p_vts_g != nil && b_at(p_vts_g, 0) != 0 &&
				(^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)^ == nil {
					vsts_arr2: ^rawptr = (^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)
					tabstop_set_o(p_vts_g, (^^u8)(vsts_arr2))
				} else {
					(^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)^ = nil
				}
			} else {
				(^^u8)(uintptr(bp) + B_P_ISK_OFF)^ = xstrdup_r2(transmute(cstring)(p_isk_g))
				copy_opt_sctx(bp, 50)
				did_isk = true
				(^C.longlong)(uintptr(bp) + B_P_TS_OFF)^ = p_ts_g
				copy_opt_sctx(bp, 80)
				(^^u8)(uintptr(bp) + B_P_VTS_OFF)^ = xstrdup_r2(transmute(cstring)(p_vts_g))
				copy_opt_sctx(bp, 90)
				if p_vts_g != nil && b_at(p_vts_g, 0) != 0 &&
				(^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)^ == nil {
					vsts_arr3: ^rawptr = (^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)
					tabstop_set_o(p_vts_g, (^^u8)(vsts_arr3))
				} else {
					(^rawptr)(uintptr(bp) + B_P_VSTS_ARRAY_OFF)^ = nil
				}
				(^bool)(uintptr(bp) + B_HELP_OFF)^ = false
				bt := (^^u8)(uintptr(bp) + B_P_BT_OFF)^
				if bt != nil && b_at(bt, 0) == 'h' {
					clear_string_option_r(transmute(^u8)((^^u8)(uintptr(bp) + B_P_BT_OFF)))
				}
				(^C.int)(uintptr(bp) + B_P_MA_OFF)^ = p_ma_g
				copy_opt_sctx(bp, 60)
			}
		}

		if should_copy {
			(^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^ = true
		}
	}

	check_buf_options_c(buf)
	if did_isk {
		buf_init_chartab_r(buf, false)
	}
}

// ── buf_T offsets for buf_copy_options (probe-verified) ──────────────────────
B_P_ISK_OFF :: 10448
B_P_RO_OFF :: 10616
B_P_FENC_OFF :: 10400
B_P_BH_OFF :: 10144
B_P_BT_OFF :: 10152
B_P_AI_OFF :: 10108
B_P_AI_NOPASTE_OFF :: 10112
B_P_SW_OFF :: 10624
B_P_SCBK_OFF :: 10632
B_P_TW_NOPASTE_OFF :: 10720
B_P_WM_NOPASTE_OFF :: 10744
B_P_BOMB_OFF :: 10140
B_P_FIXEOL_OFF :: 10384
B_P_ET_NOPASTE_OFF :: 10396
B_P_ML_NOPASTE_OFF :: 10580
B_P_INF_OFF :: 10440
B_P_SWF_OFF :: 10672
B_P_CPT_OFF :: 10256
B_P_CFU_OFF :: 10280
B_P_OFU_OFF :: 10304
B_P_TFU_OFF :: 10328
B_P_STS_OFF :: 10648
B_P_STS_NOPASTE_OFF :: 10656
B_P_VSTS_OFF :: 10752
B_P_VSTS_ARRAY_OFF :: 10760
B_P_VSTS_NOPASTE_OFF :: 10768
B_P_COM_OFF :: 10224
B_P_CMS_OFF :: 10232
B_P_FO_OFF :: 10424
B_P_NF_OFF :: 10592
B_P_MPS_OFF :: 10568
B_P_SI_OFF :: 10640
B_P_CI_OFF :: 10132
B_P_CIN_OFF :: 10184
B_P_CINK_OFF :: 10200
B_P_CINO_OFF :: 10192
B_P_CINSD_OFF :: 10216
B_P_LOP_OFF :: 10552
B_P_PI_OFF :: 10600
B_P_CINW_OFF :: 10208
B_P_LISP_OFF :: 10544
B_P_SMC_OFF :: 10680
B_P_INDE_OFF :: 10488
B_P_INDK_OFF :: 10504
B_P_FP_OFF :: 10512
B_P_FEX_OFF :: 10520
B_P_SUA_OFF :: 10664
B_P_KEYMAP_OFF :: 10792
B_P_IMINSERT_OFF :: 7840
B_P_IMSEARCH_OFF :: 7848
B_P_AC_OFF :: 10104
B_P_AR_OFF :: 10848
B_P_FS_OFF :: 10532
B_P_BKC_OFF :: 10120
B_TC_FLAGS_OFF :: 10872
B_P_GEFM_OFF :: 10800
B_P_GP_OFF :: 10808
B_P_MP_OFF :: 10816
B_P_EFM_OFF :: 10824
B_P_KP_OFF :: 10536
B_P_PATH_OFF :: 10840
B_P_TAGS_OFF :: 10856
B_P_TC_OFF :: 10864
B_P_DEF_OFF :: 10456
B_P_INC_OFF :: 10464
B_P_INEX_OFF :: 10472
B_P_COT_OFF :: 10240
B_COT_FLAGS_OFF :: 10248
B_P_DICT_OFF :: 10880
B_P_DIA_OFF :: 10888
B_P_TSR_OFF :: 10896
B_P_TSRFU_OFF :: 10904
B_P_QE_OFF :: 10608
B_P_UDF_OFF :: 10936
B_P_LW_OFF :: 10944
B_P_MENC_OFF :: 10560
B_P_TS_OFF :: 10696
B_P_MA_OFF :: 10584
B_P_VTS_OFF :: 10776

foreign _ {
}
