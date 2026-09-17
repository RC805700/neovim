// grid.odin — port of src/nvim/grid.c (schar family) + map_glyph_cache.c
package main

import C "core:c"
import "core:c/libc"

// ── Batch 1: glyph cache + schar family ─────────────────────────────────────
// (line_do_arabic_shape deferred — needs arabic.c tables. grid_adjust +
// grid_line_*/grid_alloc cluster deferred — need GridView/ScreenGrid mirrors.)

MAX_SCHAR_SIZE_O :: 32

// Set(glyph) mirror: MapHash + flat NUL-separated char keys
// (map_glyph_cache.c header comment). NOT klib Set_String ([^]String).
Set_glyph :: struct {
	h:    MapHash,
	keys: [^]u8,
}

// Glyph cache (was `static Set(glyph) glyph_cache` in grid.c).
@(private="file")
glyph_cache_f: Set_glyph

foreign _ {
	@(link_name = "utf_ptr2cells")
	utf_ptr2cells_r :: proc "c"(p: cstring) -> C.int ---
	@(link_name = "decor_check_invalid_glyphs")
	decor_check_invalid_glyphs_r :: proc "c"() ---
}

// String{ptr}+strlen (cstr_as_string logic, B22 class).
cstr_string_o :: proc "c"(s: ^u8) -> String {
	return String{data = cstring(s), size = libc.strlen(cstring(s))}
}

// Find-bucket for the flat-keys glyph set (map_glyph_cache.c).
@(export)
mh_find_bucket_glyph :: proc "c"(set: ^Set_glyph, key: String, put: bool) -> u32 {
	h := &set.h
	step: u32 = 0
	mask := h.n_buckets - 1
	k := hash_String(key)
	i := k & mask
	last := i
	site := put ? last : MH_TOMBSTONE
	for !mh_is_empty(h, i) {
		if mh_is_del(h, i) {
			if site == last {
				site = i
			}
		} else if equal_String(cstr_string_o(&set.keys[h.hash[i] - 1]), key) {
			return i
		}
		step += 1
		i = (i + step) & mask
		if i == last {
			libc.abort()
		}
	}
	if site == last {
		site = i
	}
	return site
}

// Byte offset into set->keys, or MH_TOMBSTONE (map_glyph_cache.c).
@(export)
mh_get_glyph :: proc "c"(set: ^Set_glyph, key: String) -> u32 {
	if set.h.n_buckets == 0 {
		return MH_TOMBSTONE
	}
	idx := mh_find_bucket_glyph(set, key, false)
	if idx != MH_TOMBSTONE {
		return set.h.hash[idx] - 1
	}
	return MH_TOMBSTONE
}

// Rehash over NUL-terminated flat keys (map_glyph_cache.c).
@(export)
mh_rehash_glyph :: proc "c"(set: ^Set_glyph) {
	// Flat-keys format: advance past each NUL-terminated string.
	k: u32 = 0
	for k < set.h.n_keys {
		idx := mh_find_bucket_glyph(set,
			cstr_string_o(&set.keys[k]), true)
		// Tombstones must exist when rehashing.
		if !mh_is_empty(&set.h, idx) {
			libc.abort()
		}
		set.h.hash[idx] = k + 1
		k += u32(libc.strlen(cstring(&set.keys[k]))) + 1
	}
	set.h.n_occupied = set.h.size
	set.h.size = set.h.n_keys
}

// Intern a key; returns its byte offset (map_glyph_cache.c).
@(export)
mh_put_glyph :: proc "c"(set: ^Set_glyph, key: String, new: ^MHPutStatus) -> u32 {
	h := &set.h
	// Rehash ahead of time if the key existed (happens soon anyway).
	if h.n_occupied >= h.upper_bound {
		mh_realloc(h, h.n_buckets + 1)
		mh_rehash_glyph(set)
	}

	idx := mh_find_bucket_glyph(set, key, true)

	if mh_is_either(h, idx) {
		h.size += 1
		h.n_occupied += 1

		size := u32(key.size) + 1 // NUL takes space
		pos := h.n_keys
		h.n_keys += size
		if h.n_keys > h.keys_capacity {
			h.keys_capacity = max(h.keys_capacity * 2, u32(64))
			set.keys = ([^]u8)(xrealloc(set.keys,
				C.size_t(h.keys_capacity)))
			new^ = .kMHNewKeyRealloc
		} else {
			new^ = .kMHNewKeyDidFit
		}
		libc.memcpy(transmute(rawptr)(&set.keys[pos]),
			transmute(rawptr)(key.data), key.size)
		set.keys[pos + u32(key.size)] = NUL
		h.hash[idx] = pos + 1
		return pos
	} else {
		new^ = .kMHExisting
		pos := h.hash[idx] - 1
		if !equal_String(cstr_string_o(&set.keys[pos]), key) {
			libc.abort()
		}
		return pos
	}
}

// Byte index inside an interned glyph (schar_idx macro; plain, C-static-like).
schar_idx_o :: proc "c"(sc: u32) -> u32 {
	when ODIN_ENDIAN == .Big {
		return sc & 0x00FFFFFF
	} else {
		return sc >> 8
	}
}

// Length of an inline (<=4B, non-interned) schar.
schar_inline_len_o :: proc "c"(sc: u32) -> u32 {
	s := sc
	p := transmute([^]u8)(&s)
	len: u32 = 0
	for len < 4 && p[len] != 0 {
		len += 1
	}
	return len
}

// Intern a NUL-terminated string as a screen cell.
@(export)
schar_from_str :: proc "c"(str: cstring) -> u32 {
	if str == nil {
		return 0
	}
	return schar_from_buf(transmute(^u8)(str), libc.strlen(str))
}

// Intern a (not necessarily NUL-terminated, no embedded NULs) buffer.
// Caller ensures len < MAX_SCHAR_SIZE (NUL needs a byte).
@(export)
schar_from_buf :: proc "c"(buf: ^u8, len: C.size_t) -> u32 {
	if len <= 4 {
		sc: u32 = 0
		libc.memcpy(transmute(rawptr)(&sc), transmute(rawptr)(buf), len)
		return sc
	} else {
		str := String{data = cstring(buf), size = len}

		status: MHPutStatus
		idx := mh_put_glyph(&glyph_cache_f, str, &status)
		if idx >= 0xFFFFFF {
			libc.abort()
		}
		when ODIN_ENDIAN == .Big {
			return idx + (u32(0xFF) << 24)
		} else {
			return 0xFF + (idx << 8)
		}
	}
}

// Put a unicode character in a screen cell.
@(export)
schar_from_char :: proc "c"(c: C.int) -> u32 {
	sc: u32 = 0
	cc := c
	if cc >= 0x200000 {
		// TODO(bfredl): must NEVER happen, even with overlong sequences.
		cc = 0xFFFD
	}
	utf_char2bytes(cc, transmute(^u8)(&sc))
	return sc
}

// Clear the cache when full (call in update_screen()). True when cleared —
// all screen buffers are hosed then, use UPD_CLEAR.
@(export)
schar_cache_clear_if_full :: proc "c"() -> bool {
	// Critical max is really (1<<24)-1; margin until next update_screen().
	if glyph_cache_f.h.n_keys > (1 << 21) {
		schar_cache_clear()
		return true
	}
	return false
}

// Empty the glyph cache (cell widths unchanged: no error possible).
@(export)
schar_cache_clear :: proc "c"() {
	decor_check_invalid_glyphs_r()
	mh_clear(&glyph_cache_f.h)

	// Stored option strings are regenerated with clean-cache schar values.
	if check_chars_options() != nil {
		libc.abort()
	}
}

// True for interned (cache-index) glyphs.
@(export)
schar_high :: proc "c"(sc: u32) -> bool {
	when ODIN_ENDIAN == .Big {
		return (sc & 0xFF000000) == 0xFF000000
	} else {
		return (sc & 0xFF) == 0xFF
	}
}

// Decode a cell into buf_out + final NUL; returns length.
@(export)
schar_get :: proc "c"(buf_out: ^u8, sc: u32) -> C.size_t {
	p := buf_out
	len := schar_get_adv(&p, sc)
	p^ = 0
	return len
}

// Decode a cell, advancing *buf_out past it (no final NUL).
@(export)
schar_get_adv :: proc "c"(buf_out: ^^u8, sc: u32) -> C.size_t {
	len: C.size_t = 0
	if schar_high(sc) {
		idx := schar_idx_o(sc)
		if idx >= glyph_cache_f.h.n_keys {
			libc.abort()
		}
		len = libc.strlen(cstring(&glyph_cache_f.keys[idx]))
		libc.memcpy(transmute(rawptr)(buf_out^),
			transmute(rawptr)(&glyph_cache_f.keys[idx]), len)
	} else {
		len = C.size_t(schar_inline_len_o(sc))
		s := sc
		libc.memcpy(transmute(rawptr)(buf_out^), transmute(rawptr)(&s),
			len)
	}
	buf_out^ = (^u8)(uintptr(buf_out^) + uintptr(len))
	return len
}

// Encoded length of a cell (no decode).
@(export)
schar_len :: proc "c"(sc: u32) -> C.size_t {
	if schar_high(sc) {
		idx := schar_idx_o(sc)
		if idx >= glyph_cache_f.h.n_keys {
			libc.abort()
		}
		return libc.strlen(cstring(&glyph_cache_f.keys[idx]))
	}
	return C.size_t(schar_inline_len_o(sc))
}

// Screen-cell width of a cell (hot path).
@(export)
schar_cells :: proc "c"(sc: u32) -> C.int {
	when ODIN_ENDIAN == .Big {
		if (sc & 0x80FFFFFF) == 0 {
			return 1
		}
	} else {
		if sc < 0x80 {
			return 1
		}
	}

	sc_buf: [MAX_SCHAR_SIZE_O]u8
	schar_get(&sc_buf[0], sc)
	return utf_ptr2cells_r(cstring(&sc_buf[0]))
}

// First raw UTF-8 byte of a cell (plain, C-static).
schar_get_first_byte_o :: proc "c"(sc: u32) -> u8 {
	if schar_high(sc) && schar_idx_o(sc) >= glyph_cache_f.h.n_keys {
		libc.abort()
	}
	if schar_high(sc) {
		return glyph_cache_f.keys[schar_idx_o(sc)]
	}
	s := sc
	return (transmute([^]u8)(&s))[0]
}

// First codepoint of a cell.
@(export)
schar_get_first_codepoint :: proc "c"(sc: u32) -> C.int {
	sc_buf: [MAX_SCHAR_SIZE_O]u8
	schar_get(&sc_buf[0], sc)
	return utf_ptr2char(cstring(&sc_buf[0]))
}

// ASCII char of a cell, or NUL when not ascii.
@(export)
schar_get_ascii :: proc "c"(sc: u32) -> u8 {
	when ODIN_ENDIAN == .Big {
		if (sc & 0x80FFFFFF) == 0 {
			s := sc
			return (transmute([^]u8)(&s))[0]
		}
		return 0
	} else {
		if sc < 0x80 {
			return u8(sc)
		}
		return 0
	}
}

// True when a cell starts in the arabic block (plain, C-static).
schar_in_arabic_block_o :: proc "c"(sc: u32) -> bool {
	first_byte := schar_get_first_byte_o(sc)
	return (u8(first_byte) & 0xFE) == 0xD8
}

// First two codepoints of a cell, NUL when missing (plain, C-static).
schar_get_first_two_codepoints_o :: proc "c"(sc: u32, c0: ^C.int, c1: ^C.int) {
	sc_buf: [MAX_SCHAR_SIZE_O]u8
	schar_get(&sc_buf[0], sc)

	c0^ = utf_ptr2char(cstring(&sc_buf[0]))
	len := utf_ptr2len_o(cstring(&sc_buf[0]))
	if c0^ == 0 {
		c1^ = 0
	} else {
		c1^ = utf_ptr2char(cstring(
			(^u8)(uintptr(&sc_buf[0]) + uintptr(len))))
	}
}
