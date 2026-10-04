package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// keycodes.c port: <key> notation tables + translation.
// All 14 publics are @(export); extract_modifiers is a dormant _o plain.
// The GENERATED key_names_table + gperf hash stay in C (keycodes_shim.c,
// funcs_shim.c precedent); all LOGIC is Odin.

foreign _ {
	@(link_name = "nvim_odin_key_names_count")
	key_names_count_e :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_key_at")
	key_at_e :: proc "c" (idx: C.int, is_alt: ^bool, name_data: ^cstring, name_size: ^C.size_t) -> C.int ---
	@(link_name = "nvim_odin_key_code_hash")
	key_code_hash_e :: proc "c" (name: cstring, len: C.size_t) -> C.int ---
	@(link_name = "utfc_ptr2len_len")
	utfc_ptr2len_len_e :: proc "c" (p: cstring, size: C.int) -> C.int ---
}

MOD_MASK_SHIFT :: 0x02
MOD_MASK_ALT :: 0x08
MOD_MASK_META :: 0x10
MOD_MASK_CMD :: 0x80
MOD_MASK_MULTI_CLICK :: 0x60
KS_ZERO :: 255
FSK_KEEP_X_KEY :: 0x02
FSK_IN_STRING :: 0x04
FSK_SIMPLIFY :: 0x08
REPTERM_FROM_PART :: 1
REPTERM_DO_LT :: 2
REPTERM_NO_SPECIAL :: 4
REPTERM_NO_SIMPLIFY :: 8
MAX_KEY_NAME_LEN :: 32
CPO_BSLASH :: 'B'
DEL :: 0x7f
BS :: 8
MOUSE_LEFT :: 0x00
MOUSE_MIDDLE :: 0x01
MOUSE_RIGHT :: 0x02
MOUSE_RELEASE :: 0x03
MOUSE_X1 :: 0x300
MOUSE_X2 :: 0x400

// K_* codes via TERMCAP2KEY(a,b) = -((a) + ((b) << 8)).
K_UP :: -(C.int('k') + (C.int('u') << 8))
K_DOWN :: -(C.int('k') + (C.int('d') << 8))
K_LEFT :: -(C.int('k') + (C.int('l') << 8))
K_RIGHT :: -(C.int('k') + (C.int('r') << 8))
K_HOME :: -(C.int('k') + (C.int('h') << 8))
K_END :: -(C.int('@') + (C.int('7') << 8))
K_XUP :: -(C.int(KS_EXTRA) + (C.int(65) << 8))
K_XDOWN :: -(C.int(KS_EXTRA) + (C.int(66) << 8))
K_XLEFT :: -(C.int(KS_EXTRA) + (C.int(67) << 8))
K_XRIGHT :: -(C.int(KS_EXTRA) + (C.int(68) << 8))
K_XHOME :: -(C.int(KS_EXTRA) + (C.int(63) << 8))
K_XEND :: -(C.int(KS_EXTRA) + (C.int(61) << 8))
K_ZHOME :: -(C.int(KS_EXTRA) + (C.int(64) << 8))
K_ZEND :: -(C.int(KS_EXTRA) + (C.int(62) << 8))
K_XF1 :: -(C.int(KS_EXTRA) + (C.int(57) << 8))
K_XF2 :: -(C.int(KS_EXTRA) + (C.int(58) << 8))
K_XF3 :: -(C.int(KS_EXTRA) + (C.int(59) << 8))
K_XF4 :: -(C.int(KS_EXTRA) + (C.int(60) << 8))
K_S_XF1 :: -(C.int(KS_EXTRA) + (C.int(71) << 8))
K_S_XF2 :: -(C.int(KS_EXTRA) + (C.int(72) << 8))
K_S_XF3 :: -(C.int(KS_EXTRA) + (C.int(73) << 8))
K_S_XF4 :: -(C.int(KS_EXTRA) + (C.int(74) << 8))
K_S_TAB :: -(C.int('k') + (C.int('B') << 8))
K_ZERO :: -(C.int(KS_ZERO) + (C.int(88) << 8))
K_DEL :: -(C.int('k') + (C.int('D') << 8))
K_KDEL :: -(C.int(KS_EXTRA) + (C.int(80) << 8))

Modmask_Entry :: struct {
	mod_mask: u16,
	mod_flag: u16,
	name:     u8,
}

@(private = "file")
mod_mask_table_g: [10]Modmask_Entry = {
	{0x08, 0x08, 'M'},
	{0x10, 0x10, 'T'},
	{0x04, 0x04, 'C'},
	{0x02, 0x02, 'S'},
	{0x60, 0x20, '2'},
	{0x60, 0x40, '3'},
	{0x60, 0x60, '4'},
	{0x80, 0x80, 'D'},
	{0x08, 0x08, 'A'},
	{0, 0, 0},
}

// Shifted-key terminal codes (verified byte-extract from keycodes.c).
@(private = "file")
modifier_keys_table_g: [376]u8 = {
	2, 38, 57, 64, 49, // begin
	2, 38, 48, 64, 50, // cancel
	2, 42, 49, 64, 52, // command
	2, 42, 50, 64, 53, // copy
	2, 42, 51, 64, 54, // create
	2, 42, 52, 107, 68, // delete char
	2, 42, 53, 107, 76, // delete line
	2, 42, 55, 64, 55, // end
	4, 253, 88, 64, 55, // end
	2, 42, 57, 64, 57, // exit
	2, 42, 48, 64, 48, // find
	2, 35, 49, 37, 49, // help
	2, 35, 50, 107, 104, // home
	4, 253, 87, 107, 104, // home
	2, 35, 51, 107, 73, // insert
	2, 35, 52, 107, 108, // left arrow
	4, 253, 85, 107, 108, // left arrow
	2, 37, 97, 37, 51, // message
	2, 37, 98, 37, 52, // move
	2, 37, 99, 37, 53, // next
	2, 37, 100, 37, 55, // options
	2, 37, 101, 37, 56, // previous
	2, 37, 102, 37, 57, // print
	2, 37, 103, 37, 48, // redo
	2, 37, 104, 38, 51, // replace
	2, 37, 105, 107, 114, // right arr.
	4, 253, 86, 107, 114, // right arr.
	2, 37, 106, 38, 53, // resume
	2, 33, 49, 38, 54, // save
	2, 33, 50, 38, 55, // suspend
	2, 33, 51, 38, 56, // undo
	2, 253, 4, 107, 117, // up arrow
	2, 253, 5, 107, 100, // down arrow
	2, 253, 71, 253, 57,
	2, 253, 72, 253, 58,
	2, 253, 73, 253, 59,
	2, 253, 74, 253, 60,
	2, 253, 6, 107, 49, // F1
	2, 253, 7, 107, 50,
	2, 253, 8, 107, 51,
	2, 253, 9, 107, 52,
	2, 253, 10, 107, 53,
	2, 253, 11, 107, 54,
	2, 253, 12, 107, 55,
	2, 253, 13, 107, 56,
	2, 253, 14, 107, 57,
	2, 253, 15, 107, 59, // F10
	2, 253, 16, 70, 49,
	2, 253, 17, 70, 50,
	2, 253, 18, 70, 51,
	2, 253, 19, 70, 52,
	2, 253, 20, 70, 53,
	2, 253, 21, 70, 54,
	2, 253, 22, 70, 55,
	2, 253, 23, 70, 56,
	2, 253, 24, 70, 57,
	2, 253, 25, 70, 65,
	2, 253, 26, 70, 66,
	2, 253, 27, 70, 67,
	2, 253, 28, 70, 68,
	2, 253, 29, 70, 69,
	2, 253, 30, 70, 70,
	2, 253, 31, 70, 71,
	2, 253, 32, 70, 72,
	2, 253, 33, 70, 73,
	2, 253, 34, 70, 74,
	2, 253, 35, 70, 75,
	2, 253, 36, 70, 76,
	2, 253, 37, 70, 77,
	2, 253, 38, 70, 78,
	2, 253, 39, 70, 79,
	2, 253, 40, 70, 80,
	2, 253, 41, 70, 81,
	2, 253, 42, 70, 82,
	2, 107, 66, 253, 54,
	0, // NUL terminator
}

Mouse_Entry :: struct {
	pseudo_code: C.int,
	button:      C.int,
	is_click:    bool,
	is_drag:     bool,
}

@(private = "file")
mouse_table_g: [18]Mouse_Entry = {
	{-(C.int(KS_EXTRA) + (C.int(44) << 8)), MOUSE_LEFT, true, false},
	{-(C.int(KS_EXTRA) + (C.int(45) << 8)), MOUSE_LEFT, false, true},
	{-(C.int(KS_EXTRA) + (C.int(46) << 8)), MOUSE_LEFT, false, false},
	{-(C.int(KS_EXTRA) + (C.int(47) << 8)), MOUSE_MIDDLE, true, false},
	{-(C.int(KS_EXTRA) + (C.int(48) << 8)), MOUSE_MIDDLE, false, true},
	{-(C.int(KS_EXTRA) + (C.int(49) << 8)), MOUSE_MIDDLE, false, false},
	{-(C.int(KS_EXTRA) + (C.int(50) << 8)), MOUSE_RIGHT, true, false},
	{-(C.int(KS_EXTRA) + (C.int(51) << 8)), MOUSE_RIGHT, false, true},
	{-(C.int(KS_EXTRA) + (C.int(52) << 8)), MOUSE_RIGHT, false, false},
	{-(C.int(KS_EXTRA) + (C.int(89) << 8)), MOUSE_X1, true, false},
	{-(C.int(KS_EXTRA) + (C.int(90) << 8)), MOUSE_X1, false, true},
	{-(C.int(KS_EXTRA) + (C.int(91) << 8)), MOUSE_X1, false, false},
	{-(C.int(KS_EXTRA) + (C.int(92) << 8)), MOUSE_X2, true, false},
	{-(C.int(KS_EXTRA) + (C.int(93) << 8)), MOUSE_X2, false, true},
	{-(C.int(KS_EXTRA) + (C.int(94) << 8)), MOUSE_X2, false, false},
	{-(C.int(KS_EXTRA) + (C.int(100) << 8)), MOUSE_RELEASE, false, true},
	{-(C.int(KS_EXTRA) + (C.int(53) << 8)), MOUSE_RELEASE, false, false},
	{0, 0, false, false},
}

@(private = "file")
special_key_string_g: [MAX_KEY_NAME_LEN + 1]u8

// Modifier mask bit for a modifier letter ('S', 'C', ...).
@(export)
name_to_mod_mask :: proc "c" (c_in: C.int) -> C.int {
	context = runtime.default_context()
	c := c_in
	if c >= 'a' && c <= 'z' {
		c -= 32
	}
	for i := 0; mod_mask_table_g[i].mod_mask != 0; i += 1 {
		if c == C.int(mod_mask_table_g[i].name) {
			return C.int(mod_mask_table_g[i].mod_flag)
		}
	}
	return 0
}

// Simplified key code for key + modifiers.
@(export)
simplify_key :: proc "c" (key: C.int, modifiers: ^C.int) -> C.int {
	context = runtime.default_context()
	if (modifiers^ & (MOD_MASK_SHIFT | MOD_MASK_CTRL)) == 0 {
		return key
	}
	if key == C.int(TAB) && (modifiers^ & MOD_MASK_SHIFT) != 0 {
		modifiers^ &= ~C.int(MOD_MASK_SHIFT)
		return K_S_TAB
	}
	key0 := C.int(transmute(u32)(-key) & 0xff)
	key1 := C.int((transmute(u32)(-key) >> 8) & 0xff)
	for i: C.int = 0; modifier_keys_table_g[i] != 0; i += 5 {
		if key0 == C.int(modifier_keys_table_g[i + 3]) && key1 == C.int(modifier_keys_table_g[i + 4]) && (modifiers^ & C.int(modifier_keys_table_g[i])) != 0 {
			modifiers^ &= ~C.int(modifier_keys_table_g[i])
			return -(C.int(modifier_keys_table_g[i + 1]) + (C.int(modifier_keys_table_g[i + 2]) << 8))
		}
	}
	return key
}

// Change <xKey> to <Key>.
@(export)
handle_x_keys :: proc "c" (key: C.int) -> C.int {
	context = runtime.default_context()
	switch key {
	case K_XUP:
		return K_UP
	case K_XDOWN:
		return K_DOWN
	case K_XLEFT:
		return K_LEFT
	case K_XRIGHT:
		return K_RIGHT
	case K_XHOME:
		return K_HOME
	case K_ZHOME:
		return K_HOME
	case K_XEND:
		return K_END
	case K_ZEND:
		return K_END
	case K_XF1:
		return -(C.int('k') + (C.int('1') << 8))
	case K_XF2:
		return -(C.int('k') + (C.int('2') << 8))
	case K_XF3:
		return -(C.int('k') + (C.int('3') << 8))
	case K_XF4:
		return -(C.int('k') + (C.int('4') << 8))
	case K_S_XF1:
		return -(C.int(KS_EXTRA) + (C.int(6) << 8))
	case K_S_XF2:
		return -(C.int(KS_EXTRA) + (C.int(7) << 8))
	case K_S_XF3:
		return -(C.int(KS_EXTRA) + (C.int(8) << 8))
	case K_S_XF4:
		return -(C.int(KS_EXTRA) + (C.int(9) << 8))
	}
	return key
}

// Name of key with modifiers ("<C-Up>"); static buffer.
@(export)
get_special_key_name :: proc "c" (c_in: C.int, modifiers_in: C.int) -> cstring {
	context = runtime.default_context()
	c := c_in
	modifiers := modifiers_in
	special_key_string_g[0] = '<'
	idx: C.int = 1
	if c < 0 && C.int(transmute(u32)(-c) & 0xff) == 75 {
		c = C.int((transmute(u32)(-c) >> 8) & 0xff)
	}
	if c < 0 {
		for i: C.int = 0; modifier_keys_table_g[i] != 0; i += 5 {
			if C.int(transmute(u32)(-c) & 0xff) == C.int(modifier_keys_table_g[i + 1]) && C.int((transmute(u32)(-c) >> 8) & 0xff) == C.int(modifier_keys_table_g[i + 2]) {
				modifiers |= C.int(modifier_keys_table_g[i])
				c = -(C.int(modifier_keys_table_g[i + 3]) + (C.int(modifier_keys_table_g[i + 4]) << 8))
				break
			}
		}
	}
	table_idx := find_special_key_in_table(c)
	if c > 0 && utf_char2len_r(c) == 1 {
		if table_idx < 0 && (!vim_isprintc(c) || (c & 0x7f) == ' ') && (c & 0x80) != 0 {
			c &= 0x7f
			modifiers |= MOD_MASK_ALT
			table_idx = find_special_key_in_table(c)
		}
		if table_idx < 0 && !vim_isprintc(c) && c < ' ' {
			c += '@'
			modifiers |= MOD_MASK_CTRL
		}
	}
	for i := 0; mod_mask_table_g[i].name != 'A'; i += 1 {
		if (modifiers & C.int(mod_mask_table_g[i].mod_mask)) == C.int(mod_mask_table_g[i].mod_flag) {
			special_key_string_g[idx] = mod_mask_table_g[i].name
			idx += 1
			special_key_string_g[idx] = '-'
			idx += 1
		}
	}
	if table_idx < 0 {
		if c < 0 {
			special_key_string_g[idx] = 't'
			idx += 1
			special_key_string_g[idx] = '_'
			idx += 1
			special_key_string_g[idx] = u8(transmute(u32)(-c) & 0xff)
			idx += 1
			special_key_string_g[idx] = u8((transmute(u32)(-c) >> 8) & 0xff)
			idx += 1
		} else {
			len := utf_char2len_r(c)
			if len == 1 && vim_isprintc(c) {
				special_key_string_g[idx] = u8(c)
				idx += 1
			} else if len > 1 {
				idx += utf_char2bytes(c, &special_key_string_g[idx])
			} else {
				s := transchar(c)
				for ([^]u8)(s)[0] != 0 {
					special_key_string_g[idx] = ([^]u8)(s)[0]
					idx += 1
					s = (^u8)(uintptr(s) + 1)
				}
			}
		}
	} else {
		is_alt := false
		data: cstring = nil
		size: C.size_t = 0
		key_at_e(table_idx, &is_alt, &data, &size)
		if C.int(size) + idx + 2 <= MAX_KEY_NAME_LEN {
			libc.memcpy(rawptr(&special_key_string_g[idx]), rawptr(data), size)
			idx += C.int(size)
		}
	}
	special_key_string_g[idx] = '>'
	idx += 1
	special_key_string_g[idx] = 0
	return transmute(cstring)(&special_key_string_g[0])
}

// Translate a <> name; bytes added to dst (0 for no match).
@(export)
trans_special :: proc "c" (srcp: ^^u8, src_len: C.size_t, dst: ^u8, flags: C.int, escape_ks: bool, did_simplify: ^bool) -> C.uint {
	context = runtime.default_context()
	modifiers: C.int = 0
	key := find_special_key(srcp, src_len, &modifiers, flags, did_simplify)
	if key == 0 {
		return 0
	}
	return special_to_buf(key, modifiers, escape_ks, dst)
}

// Encode key+modifiers into dst; returns length (not NUL-terminated).
@(export)
special_to_buf :: proc "c" (key: C.int, modifiers: C.int, escape_ks: bool, dst: ^u8) -> C.uint {
	context = runtime.default_context()
	dlen: C.uint = 0
	if modifiers != 0 {
		([^]u8)(dst)[dlen] = u8(K_SPECIAL_INPUT)
		dlen += 1
		([^]u8)(dst)[dlen] = u8(KS_MODIFIER)
		dlen += 1
		([^]u8)(dst)[dlen] = u8(modifiers)
		dlen += 1
	}
	if key < 0 {
		([^]u8)(dst)[dlen] = u8(K_SPECIAL_INPUT)
		dlen += 1
		([^]u8)(dst)[dlen] = u8(transmute(u32)(-key) & 0xff)
		dlen += 1
		([^]u8)(dst)[dlen] = u8((transmute(u32)(-key) >> 8) & 0xff)
		dlen += 1
	} else if escape_ks {
		after := add_char2buf(key, (^u8)(uintptr(dst) + uintptr(dlen)))
		dlen = C.uint(uintptr(after) - uintptr(dst))
	} else {
		dlen += C.uint(utf_char2bytes(key, (^u8)(uintptr(dst) + uintptr(dlen))))
	}
	return dlen
}

// Translate a <> name; advances *srcp past it (0 = no match).
@(export)
find_special_key :: proc "c" (srcp: ^^u8, src_len: C.size_t, modp: ^C.int, flags: C.int, did_simplify: ^bool) -> C.int {
	context = runtime.default_context()
	in_string := (flags & FSK_IN_STRING) != 0
	if src_len == 0 {
		return 0
	}
	src := srcp^
	if ([^]u8)(src)[0] != '<' {
		return 0
	}
	if ([^]u8)(src)[1] == '*' {
		src = (^u8)(uintptr(src) + 1)
	}
	end := (^u8)(uintptr(src) + uintptr(src_len) - 1)
	last_dash := src
	bp := (^u8)(uintptr(src) + 1)
	for uintptr(bp) <= uintptr(end) && (([^]u8)(bp)[0] == '-' || ascii_isident_o(([^]u8)(bp)[0])) {
		if ([^]u8)(bp)[0] == '-' {
			last_dash = bp
			if uintptr(bp) + 1 <= uintptr(end) {
				l := utfc_ptr2len_len_e(transmute(cstring)((^u8)(uintptr(bp) + 1)), C.int(uintptr(end) - uintptr(bp)) + 1)
				if uintptr(end) - uintptr(bp) > uintptr(l) && !(in_string && ([^]u8)(bp)[1] == '"') && ([^]u8)((^u8)(uintptr(bp) + uintptr(l) + 1))[0] == '>' {
					bp = (^u8)(uintptr(bp) + uintptr(l))
				} else if uintptr(end) - uintptr(bp) > 2 && in_string && ([^]u8)(bp)[1] == '\\' && ([^]u8)(bp)[2] == '"' && ([^]u8)(bp)[3] == '>' {
					bp = (^u8)(uintptr(bp) + 2)
				}
			}
		}
		if uintptr(end) - uintptr(bp) > 3 && ([^]u8)(bp)[0] == 't' && ([^]u8)(bp)[1] == '_' {
			bp = (^u8)(uintptr(bp) + 3)
		} else if uintptr(end) - uintptr(bp) > 4 && strncasecmp(transmute(cstring)(bp), cstring("char-"), 5) == 0 {
			l: C.int = 0
			vim_str2nr(transmute(cstring)((^u8)(uintptr(bp) + 5)), nil, &l, STR2NR_ALL_O, nil, nil, 0, true, nil)
			if l == 0 {
				emsg(cstring(e_invarg_s))
				return 0
			}
			bp = (^u8)(uintptr(bp) + uintptr(l) + 5)
			break
		}
		bp = (^u8)(uintptr(bp) + 1)
	}
	if uintptr(bp) <= uintptr(end) && ([^]u8)(bp)[0] == '>' {
		end_of_name := (^u8)(uintptr(bp) + 1)
		modifiers: C.int = 0
		bp = (^u8)(uintptr(src) + 1)
		for uintptr(bp) < uintptr(last_dash) {
			if ([^]u8)(bp)[0] != '-' {
				bit := name_to_mod_mask(C.int(([^]u8)(bp)[0]))
				if bit == 0 {
					break
				}
				modifiers |= bit
			}
			bp = (^u8)(uintptr(bp) + 1)
		}
		if uintptr(bp) >= uintptr(last_dash) {
			key: C.int
			if strncasecmp(transmute(cstring)((^u8)(uintptr(last_dash) + 1)), cstring("char-"), 5) == 0 && ascii_isdigit_o(([^]u8)((^u8)(uintptr(last_dash) + 6))[0]) {
				l: C.int = 0
				n: C.longlong = 0
				vim_str2nr(transmute(cstring)((^u8)(uintptr(last_dash) + 6)), nil, &l, STR2NR_ALL_O, &n, nil, 0, true, nil)
				if l == 0 {
					emsg(cstring(e_invarg_s))
					return 0
				}
				key = C.int(n)
			} else {
				off: C.int = 1
				l: C.int
				if in_string && ([^]u8)((^u8)(uintptr(last_dash) + 1))[0] == '\\' && ([^]u8)((^u8)(uintptr(last_dash) + 2))[0] == '"' {
					off = 2
					l = 2
				} else {
					l = utfc_ptr2len(transmute(cstring)((^u8)(uintptr(last_dash) + 1)))
				}
				if modifiers != 0 && ([^]u8)((^u8)(uintptr(last_dash) + uintptr(l) + 1))[0] == '>' {
					key = utf_ptr2char(transmute(cstring)((^u8)(uintptr(last_dash) + uintptr(off))))
				} else {
					key = get_special_key_code(transmute(cstring)((^u8)(uintptr(last_dash) + uintptr(off))))
					if (flags & FSK_KEEP_X_KEY) == 0 {
						key = handle_x_keys(key)
					}
				}
			}
			if key != 0 {
				key = simplify_key(key, &modifiers)
				if (flags & FSK_KEYCODE) == 0 {
					if key == K_BS {
						key = BS
					} else if key == K_DEL || key == K_KDEL {
						key = DEL
					}
				}
				if key >= 0 {
					key = extract_modifiers_o(key, &modifiers, (flags & FSK_SIMPLIFY) != 0, did_simplify)
				}
				modp^ = modifiers
				srcp^ = end_of_name
				return key
			}
		}
	}
	return 0
}

// Fold modifiers into plain keys (<C-H> to 0x08, etc.).
extract_modifiers_o :: proc "c" (key_in: C.int, modp: ^C.int, simplify: bool, did_simplify: ^bool) -> C.int {
	context = runtime.default_context()
	key := key_in
	modifiers := modp^
	if (modifiers & MOD_MASK_SHIFT) != 0 && ascii_isalpha_o(u8(key)) {
		if key >= 'a' && key <= 'z' {
			key -= 32
		}
		if (modifiers & MOD_MASK_CTRL) == 0 {
			modifiers &= ~C.int(MOD_MASK_SHIFT)
		}
	}
	if (modifiers & MOD_MASK_CTRL) != 0 && ascii_isalpha_o(u8(key)) {
		if key >= 'a' && key <= 'z' {
			key -= 32
		}
	}
	if simplify && (modifiers & MOD_MASK_CTRL) != 0 && ((key >= '?' && key <= '_') || ascii_isalpha_o(u8(key))) {
		key &= 0x1f
		modifiers &= ~C.int(MOD_MASK_CTRL)
		if key == 0 {
			key = K_ZERO
		}
		if did_simplify != nil {
			did_simplify^ = true
		}
	}
	modp^ = modifiers
	return key
}

// Index of key c in the generated table (-1 when absent).
@(export)
find_special_key_in_table :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	n := key_names_count_e()
	for i: C.int = 0; i < n; i += 1 {
		is_alt := false
		data: cstring = nil
		size: C.size_t = 0
		key := key_at_e(i, &is_alt, &data, &size)
		if c == key && !is_alt {
			return i
		}
	}
	return -1
}

// Key code for a name ("CR", "t_xx"); 0 when unknown.
@(export)
get_special_key_code :: proc "c" (name: cstring) -> C.int {
	context = runtime.default_context()
	p := transmute(^u8)(name)
	if ([^]u8)(p)[0] == 't' && ([^]u8)(p)[1] == '_' && ([^]u8)(p)[2] != 0 && ([^]u8)(p)[3] != 0 {
		return -(C.int(([^]u8)(p)[2]) + (C.int(([^]u8)(p)[3]) << 8))
	}
	name_end := p
	for ascii_isident_o(([^]u8)(name_end)[0]) {
		name_end = (^u8)(uintptr(name_end) + 1)
	}
	idx := key_code_hash_e(name, C.size_t(uintptr(name_end) - uintptr(p)))
	if idx < 0 {
		return 0
	}
	is_alt := false
	data: cstring = nil
	size: C.size_t = 0
	return key_at_e(idx, &is_alt, &data, &size)
}

// Mouse button info for a pseudo code.
@(export)
get_mouse_button :: proc "c" (code: C.int, is_click: ^bool, is_drag: ^bool) -> C.int {
	context = runtime.default_context()
	for i := 0; mouse_table_g[i].pseudo_code != 0; i += 1 {
		if code == mouse_table_g[i].pseudo_code {
			is_click^ = mouse_table_g[i].is_click
			is_drag^ = mouse_table_g[i].is_drag
			return mouse_table_g[i].button
		}
	}
	return 0
}

// Encode <> notation; result in *bufp (allocated or 128B reuse).
@(export)
replace_termcodes :: proc "c" (from: cstring, from_len: C.size_t, bufp: ^cstring, sid_arg: C.int, flags: C.int, did_simplify: ^bool, cpo_val: cstring) -> cstring {
	context = runtime.default_context()
	dlen: C.size_t = 0
	end := (^u8)(uintptr(rawptr(from)) + uintptr(from_len) - 1)
	do_backslash := vim_strchr(transmute(cstring)(cpo_val), C.int(CPO_BSLASH)) == nil
	do_special := (flags & REPTERM_NO_SPECIAL) == 0
	allocated := bufp^ == nil
	buf_len := from_len * 6 + 1
	if !allocated {
		buf_len = 128
	}
	result := bufp^
	if allocated {
		result = transmute(cstring)(xmalloc(buf_len))
	}
	src := transmute(^u8)(from)
	for uintptr(src) <= uintptr(end) {
		if !allocated && dlen + 64 > buf_len {
			return nil
		}
		if do_special && ((flags & REPTERM_DO_LT) != 0 || (uintptr(end) - uintptr(src) >= 3 && libc.strncmp(transmute(cstring)(src), cstring("<lt>"), 4) != 0)) {
			if uintptr(end) - uintptr(src) >= 4 && strncasecmp(transmute(cstring)(src), cstring("<SID>"), 5) == 0 {
				if sid_arg < 0 || (sid_arg == 0 && current_sctx_sc_sid() <= 0) {
					emsg(_t(cstring(E81_S)))
				} else {
					sid := sid_arg
					if sid == 0 {
						sid = current_sctx_sc_sid()
					}
					src = (^u8)(uintptr(src) + 5)
					([^]u8)(rawptr(result))[dlen] = u8(K_SPECIAL_INPUT)
					dlen += 1
					([^]u8)(rawptr(result))[dlen] = u8(KS_EXTRA)
					dlen += 1
					([^]u8)(rawptr(result))[dlen] = u8(KE_SNR_O)
					dlen += 1
					n := libc.snprintf((^u8)(uintptr(rawptr(result)) + uintptr(dlen)), buf_len - dlen, cstring("%d"), sid)
					dlen += C.size_t(n)
					([^]u8)(rawptr(result))[dlen] = '_'
					dlen += 1
					continue
				}
			}
			sflags: C.int = FSK_KEYCODE
			if (flags & REPTERM_NO_SIMPLIFY) == 0 {
				sflags |= FSK_SIMPLIFY
			}
			slen := trans_special(&src, C.size_t(uintptr(end) - uintptr(src)) + 1, (^u8)(uintptr(rawptr(result)) + uintptr(dlen)), sflags, true, did_simplify)
			if slen != 0 {
				dlen += C.size_t(slen)
				continue
			}
		}
		if do_special {
			len: C.int = 0
			p: cstring = nil
			if uintptr(end) - uintptr(src) >= 7 && strncasecmp(transmute(cstring)(src), cstring("<Leader>"), 8) == 0 {
				len = 8
				p = get_var_value(cstring("g:mapleader"))
			} else if uintptr(end) - uintptr(src) >= 12 && strncasecmp(transmute(cstring)(src), cstring("<LocalLeader>"), 13) == 0 {
				len = 13
				p = get_var_value(cstring("g:maplocalleader"))
			}
			if len != 0 {
				s: cstring = cstring("\\")
				if p != nil && ([^]u8)(rawptr(p))[0] != 0 && libc.strlen(p) <= 8 * 6 {
					s = p
				}
				for ([^]u8)(rawptr(s))[0] != 0 {
					([^]u8)(rawptr(result))[dlen] = ([^]u8)(rawptr(s))[0]
					dlen += 1
					s = transmute(cstring)((^u8)(uintptr(rawptr(s)) + 1))
				}
				src = (^u8)(uintptr(src) + uintptr(len))
				continue
			}
		}
		key := ([^]u8)(src)[0]
		if key == u8(Ctrl_V) || (do_backslash && key == '\\') {
			src = (^u8)(uintptr(src) + 1)
			if uintptr(src) > uintptr(end) {
				if (flags & REPTERM_FROM_PART) != 0 {
					([^]u8)(rawptr(result))[dlen] = key
					dlen += 1
				}
				break
			}
		}
		n := utfc_ptr2len_len_e(transmute(cstring)(src), C.int(uintptr(end) - uintptr(src)) + 1)
		for i: C.int = 0; i < n; i += 1 {
			if ([^]u8)(src)[0] == u8(K_SPECIAL_INPUT) {
				([^]u8)(rawptr(result))[dlen] = u8(K_SPECIAL_INPUT)
				dlen += 1
				([^]u8)(rawptr(result))[dlen] = u8(KS_SPECIAL)
				dlen += 1
				([^]u8)(rawptr(result))[dlen] = u8(KE_FILLER)
				dlen += 1
			} else {
				([^]u8)(rawptr(result))[dlen] = ([^]u8)(src)[0]
				dlen += 1
			}
			src = (^u8)(uintptr(src) + 1)
		}
	}
	([^]u8)(rawptr(result))[dlen] = 0
	if allocated {
		nr := xrealloc(rawptr(result), dlen + 1)
		bufp^ = transmute(cstring)(nr)
	}
	return bufp^
}

// Append c to s, escaping K_SPECIAL; returns end pointer.
@(export)
add_char2buf :: proc "c" (c_in: C.int, s: ^u8) -> ^u8 {
	context = runtime.default_context()
	c := c_in
	temp: [22]u8
	length := utf_char2bytes(c, &temp[0])
	d := s
	for i: C.int = 0; i < length; i += 1 {
		c = C.int(temp[i])
		if c == K_SPECIAL_INPUT {
			([^]u8)(d)[0] = u8(K_SPECIAL_INPUT)
			([^]u8)(d)[1] = u8(KS_SPECIAL)
			([^]u8)(d)[2] = u8(KE_FILLER)
			d = (^u8)(uintptr(d) + 3)
		} else {
			([^]u8)(d)[0] = u8(c)
			d = (^u8)(uintptr(d) + 1)
		}
	}
	return d
}

// Copy p with K_SPECIAL escaped for typeahead.
@(export)
vim_strsave_escape_ks :: proc "c" (p: ^u8) -> ^u8 {
	context = runtime.default_context()
	res := (^u8)(xmalloc(C.size_t(libc.strlen(transmute(cstring)(p))) * 4 + 1))
	d := res
	s := p
	for ([^]u8)(s)[0] != 0 {
		if ([^]u8)(s)[0] == u8(K_SPECIAL_INPUT) && ([^]u8)(s)[1] != 0 && ([^]u8)(s)[2] != 0 {
			([^]u8)(d)[0] = ([^]u8)(s)[0]
			([^]u8)(d)[1] = ([^]u8)(s)[1]
			([^]u8)(d)[2] = ([^]u8)(s)[2]
			d = (^u8)(uintptr(d) + 3)
			s = (^u8)(uintptr(s) + 3)
		} else {
			d = add_char2buf(utf_ptr2char(transmute(cstring)(s)), d)
			s = (^u8)(uintptr(s) + uintptr(utfc_ptr2len(transmute(cstring)(s))))
		}
	}
	([^]u8)(d)[0] = 0
	return res
}

// Unescape K_SPECIAL in place; returns byte length.
@(export)
vim_unescape_ks :: proc "c" (p: ^u8) -> C.size_t {
	context = runtime.default_context()
	s := p
	d := p
	for ([^]u8)(s)[0] != 0 {
		if ([^]u8)(s)[0] == u8(K_SPECIAL_INPUT) && ([^]u8)(s)[1] == u8(KS_SPECIAL) && ([^]u8)(s)[2] == u8(KE_FILLER) {
			([^]u8)(d)[0] = u8(K_SPECIAL_INPUT)
			d = (^u8)(uintptr(d) + 1)
			s = (^u8)(uintptr(s) + 3)
		} else {
			([^]u8)(d)[0] = ([^]u8)(s)[0]
			d = (^u8)(uintptr(d) + 1)
			s = (^u8)(uintptr(s) + 1)
		}
	}
	([^]u8)(d)[0] = 0
	return C.size_t(uintptr(d) - uintptr(p))
}

// ascii_isalpha_o lives in ex_cmds.odin — reuse directly.
ascii_isident_o :: proc "c" (c: u8) -> bool {
	context = runtime.default_context()
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}
