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
	@(link_name = "utf_char2len")
	utf_char2len_r :: proc "c"(c: C.int) -> C.int ---
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

// ── Batch 2g: float border cluster (draw_bordertext/get_bordertext_col/draw_border)

WCFG_BORDER_CHARS_OFF :: 66 // char[8][32]
WCFG_BORDER_ATTR_OFF  :: 356 // int[8]
WCFG_TITLE_OFF        :: 388 // bool
WCFG_TITLE_POS_OFF    :: 392 // AlignTextPos
WCFG_TITLE_CHUNKS_OFF :: 400 // VirtText (24B kvec)
WCFG_TITLE_WIDTH_OFF  :: 424
WCFG_FOOTER_OFF       :: 428 // bool
WCFG_FOOTER_POS_OFF   :: 432
WCFG_FOOTER_CHUNKS_OFF :: 440 // VirtText
WCFG_FOOTER_WIDTH_OFF :: 464

HLF_BTITLE_O :: 68
HLF_BFOOTER_O :: 69
K_ALIGN_LEFT_O :: 0
K_ALIGN_CENTER_O :: 1
K_ALIGN_RIGHT_O :: 2
K_BORDER_TITLE_O :: 0
K_BORDER_FOOTER_O :: 1

foreign _ {
	@(link_name = "hl_apply_winblend")
	hl_apply_winblend_r :: proc "c"(winbl: C.int, attr: C.int) -> C.int ---
	@(link_name = "hl_attr_active")
	hl_attr_active_g: [^]C.int
}

// Draw a border title/footer chunk run (plain, C-static).
grid_draw_bordertext_o :: proc "c"(vt: Kvec_VT, col: C.int, winbl: C.int, hl_attr: [^]C.int, bt: C.int, overflow: C.int) {
	c := col
	ov := overflow
	default_attr := hl_attr[bt == K_BORDER_TITLE_O ? HLF_BTITLE_O : HLF_BFOOTER_O]
	if ov > 0 {
		c += grid_line_puts(1, "<", -1, hl_apply_winblend_r(winbl, default_attr))
		ov += 1
	}

	i: C.size_t = 0
	for i < vt.n {
		attr: C.int = -1
		text := next_virt_text_chunk_r(vt, &i, &attr)
		if text == nil {
			break
		}
		if attr == -1 { // No highlight specified.
			attr = default_attr
		}
		// Skip chars from the start when title overflows available width.
		if ov > 0 {
			cells := C.int(mb_string2cells_s(cstring(text)))
			// Skip whole chunk if overflow exceeds chunk width.
			if ov >= cells {
				ov -= cells
				continue
			}
			// Skip partial characters within the chunk.
			p := text
			for p^ != 0 && ov > 0 {
				ov -= utf_ptr2cells_r(cstring(p))
				p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(cstring(p))))
			}
			text = p
		}
		attr = hl_apply_winblend_r(winbl, attr)
		c += grid_line_puts(c, cstring(text), -1, attr)
	}
}

// Column for border text given alignment (plain, C-static).
get_bordertext_col_o :: proc "c"(total_col: C.int, text_width: C.int, align: C.int) -> C.int {
	if align == K_ALIGN_LEFT_O {
		return 1
	} else if align == K_ALIGN_CENTER_O {
		return max((total_col - text_width) / 2 + 1, 1)
	} else if align == K_ALIGN_RIGHT_O {
		return max(total_col - text_width + 1, 1)
	} else {
		libc.abort()
	}
}

// Draw the border of a floating window grid.
@(export)
grid_draw_border :: proc "c"(grid: ^ScreenGrid, config: rawptr, adj: ^C.int, winbl: C.int, hl_attr: [^]C.int) {
	ad: [^]C.int = ([^]C.int)(adj)
	default_adj: [4]C.int = { 1, 1, 1, 1 }
	if adj == nil {
		ad = ([^]C.int)(&default_adj[0])
	}
	attrs := ([^]C.int)(uintptr(config) + WCFG_BORDER_ATTR_OFF)
	hl := hl_attr
	if hl == nil {
		hl = hl_attr_active_g
	}

	chars: [8]u32
	for i: C.int = 0; i < 8; i += 1 {
		chars[i] = schar_from_str(cstring(rawptr(
			uintptr(config) + WCFG_BORDER_CHARS_OFF + uintptr(i) * 32)))
	}

	irow := grid.rows - ad[0] - ad[2]
	icol := grid.cols - ad[1] - ad[3]

	if ad[0] != 0 {
		screengrid_line_start(grid, 0, 0)
		if ad[3] != 0 {
			grid_line_put_schar(0, chars[0], attrs[0])
		}

		for i: C.int = 0; i < icol; i += 1 {
			grid_line_put_schar(i + ad[3], chars[1], attrs[1])
		}

		if (^bool)(uintptr(config) + WCFG_TITLE_OFF)^ {
			title_col := get_bordertext_col_o(icol,
				(^C.int)(uintptr(config) + WCFG_TITLE_WIDTH_OFF)^,
				(^C.int)(uintptr(config) + WCFG_TITLE_POS_OFF)^)
			grid_draw_bordertext_o(
				(^Kvec_VT)(uintptr(config) + WCFG_TITLE_CHUNKS_OFF)^,
				title_col, winbl, hl, K_BORDER_TITLE_O,
				(^C.int)(uintptr(config) + WCFG_TITLE_WIDTH_OFF)^ - icol)
		}
		if ad[1] != 0 {
			grid_line_put_schar(icol + ad[3], chars[2], attrs[2])
		}
		grid_line_flush()
	}

	for i: C.int = 0; i < irow; i += 1 {
		if ad[3] != 0 {
			screengrid_line_start(grid, i + ad[0], 0)
			grid_line_put_schar(0, chars[7], attrs[7])
			grid_line_flush()
		}
		if ad[1] != 0 {
			ic: C.int = 3
			if i == 0 && ad[0] == 0 && chars[2] != 0 {
				ic = 2
			}
			screengrid_line_start(grid, i + ad[0], 0)
			grid_line_put_schar(icol + ad[3], chars[ic], attrs[ic])
			grid_line_flush()
		}
	}

	if ad[2] != 0 {
		screengrid_line_start(grid, irow + ad[0], 0)
		if ad[3] != 0 {
			grid_line_put_schar(0, chars[6], attrs[6])
		}

		for i: C.int = 0; i < icol; i += 1 {
			ic: C.int = 5
			if i == 0 && ad[3] == 0 && chars[6] != 0 {
				ic = 6
			}
			grid_line_put_schar(i + ad[3], chars[ic], attrs[ic])
		}

		if (^bool)(uintptr(config) + WCFG_FOOTER_OFF)^ {
			footer_col := get_bordertext_col_o(icol,
				(^C.int)(uintptr(config) + WCFG_FOOTER_WIDTH_OFF)^,
				(^C.int)(uintptr(config) + WCFG_FOOTER_POS_OFF)^)
			grid_draw_bordertext_o(
				(^Kvec_VT)(uintptr(config) + WCFG_FOOTER_CHUNKS_OFF)^,
				footer_col, winbl, hl, K_BORDER_FOOTER_O,
				(^C.int)(uintptr(config) + WCFG_FOOTER_WIDTH_OFF)^ - icol)
		}
		if ad[1] != 0 {
			grid_line_put_schar(icol + ad[3], chars[4], attrs[4])
		}
		grid_line_flush()
	}
}

// ── Batch 2f: win_grid_alloc + get_win_by_grid_handle ───────────────────────

// win_grid_alloc reuse: W_HEIGHT_OUTER_OFF/W_WIDTH_OUTER_OFF (window.odin),
// W_FLOATING_OFF (option.odin), W_VIEW_HEIGHT_OFF (option.odin).
W_LINES_SIZE_OFF   :: 640
W_REDR_BORDER_OFF  :: 709 // bool
W_CONFIG_BORDER_OFF :: 10624 // w_config.border (WinConfig+64, bool)
WLINE_SIZE_O :: 16

foreign _ {
	@(link_name = "ui_call_grid_resize")
	ui_call_grid_resize_r :: proc "c"(grid: C.longlong, width: C.longlong, height: C.longlong) ---
	@(link_name = "resizing_screen")
	resizing_screen_g: bool
}

// (Re)allocate a window grid on size change (ext_multigrid mode).
// Updates size, offsets and handle regardless. doclear skips the copy.
@(export)
win_grid_alloc :: proc "c"(wp: rawptr) {
	grid := (^GridView)(uintptr(wp) + W_GRID_OFF)
	grid_allocated := (^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF)

	total_rows := (^C.int)(uintptr(wp) + W_HEIGHT_OUTER_OFF)^
	total_cols := (^C.int)(uintptr(wp) + W_WIDTH_OUTER_OFF)^

	want_allocation := ui_has(K_UIMULTIGRID_O) ||
		(^bool)(uintptr(wp) + W_FLOATING_OFF)^
	has_allocation := grid_allocated.chars != nil

	if (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^ >
		(^C.int)(uintptr(wp) + W_LINES_SIZE_OFF)^ {
		(^C.int)(uintptr(wp) + W_LINES_VALID)^ = 0
		xfree((^rawptr)(uintptr(wp) + W_LINES_OFF)^)
		(^rawptr)(uintptr(wp) + W_LINES_OFF)^ =
			xcalloc(C.size_t((^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^) + 1,
				WLINE_SIZE_O)
		(^C.int)(uintptr(wp) + W_LINES_SIZE_OFF)^ =
			(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^
	}

	was_resized := false
	if want_allocation && (!has_allocation ||
		grid_allocated.rows != total_rows ||
		grid_allocated.cols != total_cols) {
		grid_alloc(grid_allocated, total_rows, total_cols,
			grid_allocated.valid, false)
		grid_allocated.valid = true
		if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ &&
			(^bool)(uintptr(wp) + W_CONFIG_BORDER_OFF)^ {
			(^bool)(uintptr(wp) + W_REDR_BORDER_OFF)^ = true
		}
		was_resized = true
	} else if !want_allocation && has_allocation {
		// Single-grid mode: render to default_grid, track size/offset only.
		grid_free(grid_allocated)
		grid_allocated.valid = false
		was_resized = true
	} else if want_allocation && has_allocation && !grid_allocated.valid {
		grid_invalidate(grid_allocated)
		grid_allocated.valid = true
	}

	if want_allocation {
		grid.target = grid_allocated
		grid.row_offset = (^C.int)(uintptr(wp) + W_WINROW_OFF2_OFF)^
		grid.col_offset = (^C.int)(uintptr(wp) + W_WINCOL_OFF2_OFF)^
	} else {
		grid.target = (^ScreenGrid)(&default_grid_u8)
		grid.row_offset = (^C.int)(uintptr(wp) + W_WINROW_OFF)^ +
			(^C.int)(uintptr(wp) + W_WINROW_OFF2_OFF)^
		grid.col_offset = (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ +
			(^C.int)(uintptr(wp) + W_WINCOL_OFF2_OFF)^
	}

	// Send grid resize event when resized, on screen_resize, or multigrid.
	if (resizing_screen_g || was_resized) && want_allocation {
		ui_call_grid_resize_r(C.longlong(grid_allocated.handle),
			C.longlong(grid_allocated.cols), C.longlong(grid_allocated.rows))
		ui_check_cursor_grid_r(grid_allocated.handle)
	}
}

// Find the window owning a grid handle (screens grid_alloc.handle).
@(export)
get_win_by_grid_handle :: proc "c"(handle: C.int) -> rawptr {
	// FOR_ALL_WINDOWS_IN_TAB(wp, curtab) = firstwin walk (B1 nuance).
	wp := firstwin
	for wp != nil {
		if (^C.int)(uintptr(wp) + W_GRID_HANDLE_OFF)^ == handle {
			return wp
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return nil
}

// ── Batch 2e: scroll cluster (assign_handle/ins/del_lines/linecopy) ─────────

foreign _ {
	@(link_name = "ui_call_grid_scroll")
	ui_call_grid_scroll_r :: proc "c"(grid_handle: C.int, top: C.int, bot: C.int, left: C.int, right: C.int, rows: C.int, cols: C.int) ---
}

// Last assigned grid handle (was C static in grid_assign_handle).
@(private="file")
last_grid_handle_f: C.int = 1 // DEFAULT_GRID_HANDLE

// Assign a handle to the grid (no-op if already assigned).
@(export)
grid_assign_handle :: proc "c"(grid: ^ScreenGrid) {
	if grid.handle == 0 {
		last_grid_handle_f += 1
		grid.handle = last_grid_handle_f
	}
}

// Copy a partial line within a grid (plain, C-static).
linecopy_o :: proc "c"(grid: ^ScreenGrid, to: C.int, from: C.int, col: C.int, width: C.int) {
	off_to := C.uint(grid.line_offset[to] + C.size_t(col))
	off_from := C.uint(grid.line_offset[from] + C.size_t(col))

	libc.memmove(transmute(rawptr)(&grid.chars[off_to]),
		transmute(rawptr)(&grid.chars[off_from]), C.size_t(width) * size_of(u32))
	libc.memmove(transmute(rawptr)(&grid.attrs[off_to]),
		transmute(rawptr)(&grid.attrs[off_from]), C.size_t(width) * size_of(C.int))
	libc.memmove(transmute(rawptr)(&grid.vcols[off_to]),
		transmute(rawptr)(&grid.vcols[off_from]), C.size_t(width) * size_of(C.int))
}

// Insert lines: move existing lines down, clear the inserted ones.
// row/col/end are relative to the region start; end is past the scrolled part.
@(export)
grid_ins_lines :: proc "c"(grid: ^ScreenGrid, row: C.int, line_count: C.int, end: C.int, col: C.int, width: C.int) {
	if line_count <= 0 {
		return
	}

	// Shift line_offset[] down, clear the inserted lines.
	for i: C.int = 0; i < line_count; i += 1 {
		j: C.int
		if width != grid.cols {
			// Partial line: copy cell by cell.
			j = end - 1 - i
			for {
				j -= line_count
				if j < row {
					break
				}
				linecopy_o(grid, j + line_count, j, col, width)
			}
			j += line_count
			grid_clear_line(grid, grid.line_offset[j] + C.size_t(col), width, false)
		} else {
			j = end - 1 - i
			temp := C.uint(grid.line_offset[j])
			for {
				j -= line_count
				if j < row {
					break
				}
				grid.line_offset[j + line_count] = grid.line_offset[j]
			}
			grid.line_offset[j + line_count] = C.size_t(temp)
			grid_clear_line(grid, C.size_t(temp), grid.cols, false)
		}
	}

	if !grid.throttled {
		ui_call_grid_scroll_r(grid.handle, row, end, col, col + width, -line_count, 0)
	}
}

// Delete lines: move lines up, clear the freed ones at the end.
@(export)
grid_del_lines :: proc "c"(grid: ^ScreenGrid, row: C.int, line_count: C.int, end: C.int, col: C.int, width: C.int) {
	if line_count <= 0 {
		return
	}

	// Shift line_offset[] up, clear the freed lines.
	for i: C.int = 0; i < line_count; i += 1 {
		j: C.int
		if width != grid.cols {
			// Partial line: copy cell by cell.
			j = row + i
			for {
				j += line_count
				if j > end - 1 {
					break
				}
				linecopy_o(grid, j - line_count, j, col, width)
			}
			j -= line_count
			grid_clear_line(grid, grid.line_offset[j] + C.size_t(col), width, false)
		} else {
			// Whole width: moving line pointers is faster.
			j = row + i
			temp := C.uint(grid.line_offset[j])
			for {
				j += line_count
				if j > end - 1 {
					break
				}
				grid.line_offset[j - line_count] = grid.line_offset[j]
			}
			grid.line_offset[j - line_count] = C.size_t(temp)
			grid_clear_line(grid, C.size_t(temp), grid.cols, false)
		}
	}

	if !grid.throttled {
		ui_call_grid_scroll_r(grid.handle, row, end, col, col + width, line_count, 0)
	}
}

// ── Batch 2d: commit half (flush/clear/put_linebuf) ──────────────────────────
// Completes the grid_line_* static migration: after this, NO C code reads or
// writes grid_line_* statics (C's copies go dead). This batch was forced
// early by a split-brain SIGSEGV: C grid_clear read C's grid_line_grid (NULL)
// while my grid_line_start wrote grid_line_grid_f.

foreign _ {
	@(link_name = "hl_combine_attr")
	hl_combine_attr_r :: proc "c"(char_attr: C.int, prim_attr: C.int) -> C.int ---
	@(link_name = "ui_line")
	ui_line_r :: proc "c"(grid: ^ScreenGrid, row: C.int, invalid_row: bool, startcol: C.int, endcol: C.int, clearcol: C.int, clearattr: C.int, wrap: bool) ---
	// default_grid: reuse window.odin's default_grid_u8 (address-of only).
}

// End a group of grid_line_puts calls: send the buffer to the UI layer.
@(export)
grid_line_flush :: proc "c"() {
	grid := grid_line_grid_f
	grid_line_grid_f = nil
	grid_line_clear_to_f = max(grid_line_last_f, grid_line_clear_to_f)
	if grid_line_clear_to_f > grid_line_maxcol_f {
		libc.abort()
	}
	if grid_line_first_f >= grid_line_clear_to_f {
		return
	}

	grid_put_linebuf(grid, grid_line_row_f, grid_line_coloff_f,
		grid_line_first_f, grid_line_last_f, grid_line_clear_to_f,
		grid_line_bg_attr_f, grid_line_clear_attr_f, -1, grid_line_flags_f)
}

// Flush but only on a valid row (stopgap until message.c is refactored).
@(export)
grid_line_flush_if_valid_row :: proc "c"() {
	if grid_line_row_f < 0 || grid_line_row_f >= grid_line_grid_f.rows {
		if (rdb_flags_g & KOPT_RDB_INVALID_O) != 0 {
			libc.abort()
		} else {
			grid_line_grid_f = nil
			return
		}
	}
	grid_line_flush()
}

@(export)
grid_clear :: proc "c"(grid: ^GridView, start_row: C.int, end_row: C.int, start_col: C.int, end_col: C.int, attr: C.int) {
	end := end_col
	for row := start_row; row < end_row; row += 1 {
		grid_line_start(grid, row)
		end = min(end, grid_line_maxcol_f)
		if grid_line_row_f >= grid_line_grid_f.rows || start_col >= end {
			grid_line_grid_f = nil // TODO(bfredl): make callers behave instead
			return
		}
		grid_line_clear_end(start_col, end, attr, 0)
		grid_line_flush()
	}
}

// Whether a char needs redraw: bytes/attrs differ, multibyte tail differs,
// or doublewidth second cell differs. (Plain, C-static.)
grid_char_needs_redraw_o :: proc "c"(grid: ^ScreenGrid, col: C.int, off_to: C.size_t, cols: C.int) -> C.int {
	if cols > 0 &&
		((linebuf_char_g[col] != grid.chars[off_to] ||
			linebuf_attr_g[col] != grid.attrs[off_to] ||
			(cols > 1 && linebuf_char_g[col + 1] == 0 &&
				linebuf_char_g[col + 1] != grid.chars[off_to + 1])) ||
			exmode_active || // TODO(bfredl): what in the actual fuck
			(rdb_flags_g & KOPT_RDB_NODELTA_O) != 0) {
		return 1
	}
	return 0
}

// Move one buffered line to the window grid (delta only). Handles
// insert/delete char, rightleft clearing, arabic shaping, bg combine.
@(export)
grid_put_linebuf :: proc "c"(grid: ^ScreenGrid, row: C.int, coloff: C.int, col: C.int, endcol: C.int, clear_width: C.int, bg_attr: C.int, clear_attr: C.int, last_vcol: C.int, flags: C.int) {
	redraw_next: bool // redraw_this for next character
	clear_next := false
	if !(0 <= row && row < grid.rows) {
		libc.abort()
	}
	// TODO(bfredl): check all callsites and eliminate.
	end := endcol
	if end > grid.cols {
		end = grid.cols
	}

	// Safety check. Avoids clang warnings down the call stack.
	if grid.chars == nil || row >= grid.rows || coloff >= grid.cols {
		return // DLOG("invalid state, skipped")
	}

	c := col
	cw := clear_width
	ca := clear_attr
	lv := last_vcol
	invalid_row := rawptr(grid) != rawptr(&default_grid_u8) &&
		grid_invalid_row_o(grid, row) && c == 0
	off_to := grid.line_offset[row] + C.size_t(coloff)
	max_off_to := grid.line_offset[row] + C.size_t(grid.cols)

	// Overwriting the right half of a two-cell char in the same grid:
	// truncate into '>'.
	if c > 0 && grid.chars[off_to + C.size_t(c)] == 0 {
		linebuf_char_g[c - 1] = 62 // '>'
		linebuf_attr_g[c - 1] = grid.attrs[off_to + C.size_t(c) - 1]
		c -= 1
	}

	clear_start := end
	if (flags & SLF_RIGHTLEFT_O) != 0 {
		clear_start = c
		c = end
		end = cw
		cw = c
	}

	if p_arshape_g != 0 && p_tbidi_g == 0 && end > c {
		shape_buf := ([^]u32)(uintptr(linebuf_char_g) + uintptr(c) * size_of(u32))
		line_do_arabic_shape(shape_buf, end - c)
	}

	if bg_attr != 0 {
		for i := c; i < end; i += 1 {
			linebuf_attr_g[i] = hl_combine_attr_r(bg_attr, linebuf_attr_g[i])
		}
	}

	redraw_next = grid_char_needs_redraw_o(grid, c, off_to + C.size_t(c),
		end - c) != 0

	start_dirty: C.int = -1
	end_dirty: C.int = 0

	for c < end {
		char_cells: C.int = 1
		if c + 1 < end && linebuf_char_g[c + 1] == 0 {
			char_cells = 2
		}

		redraw_this := redraw_next
		off := off_to + C.size_t(c)
		redraw_next = grid_char_needs_redraw_o(grid, c + char_cells,
			off + C.size_t(char_cells), end - c - char_cells) != 0

		if redraw_this {
			if start_dirty == -1 {
				start_dirty = c
			}
			end_dirty = c + char_cells
			// Single-width over double-width at redraw end: clear the
			// right half of the old char (or right-half over left-half).
			if c + char_cells == end && off + C.size_t(char_cells) < max_off_to &&
				grid.chars[off + C.size_t(char_cells)] == 0 {
				clear_next = true
			}

			grid.chars[off] = linebuf_char_g[c]
			if char_cells == 2 {
				grid.chars[off + 1] = linebuf_char_g[c + 1]
			}

			grid.attrs[off] = linebuf_attr_g[c]
			// Second half of double-wide gets first half's attrs.
			if char_cells == 2 {
				grid.attrs[off + 1] = linebuf_attr_g[c]
			}
		}

		grid.vcols[off] = linebuf_vcol_g[c]
		if char_cells == 2 {
			grid.vcols[off + 1] = linebuf_vcol_g[c + 1]
		}

		c += char_cells
	}

	if clear_next {
		// Clear second half of a double-wide whose left half was
		// overwritten with a single-wide char.
		grid.chars[off_to + C.size_t(c)] = 32 // ' '
		end_dirty += 1
	}

	// Clearing the left half of a double-wide: clear right half too.
	if off_to + C.size_t(cw) < max_off_to &&
		grid.chars[off_to + C.size_t(cw)] == 0 {
		cw += 1
	}

	clear_dirty_start: C.int = -1
	clear_end: C.int = -1
	if (flags & SLF_RIGHTLEFT_O) != 0 {
		i := cw - 1
		for i >= clear_start {
			off := off_to + C.size_t(i)
			if (flags & SLF_INC_VCOL_O) != 0 {
				lv += 1
			}
			grid.vcols[off] = lv
			i -= 1
		}
	}
	ca = hl_combine_attr_r(bg_attr, ca)
	// Blank out the rest of the line.
	// TODO(bfredl): we could cache winline widths.
	i := clear_start
	for i < cw {
		off := off_to + C.size_t(i)
		if grid.chars[off] != 32 || // ' '
			grid.attrs[off] != ca ||
			(rdb_flags_g & KOPT_RDB_NODELTA_O) != 0 {
			grid.chars[off] = 32
			grid.attrs[off] = ca
			if clear_dirty_start == -1 {
				clear_dirty_start = i
			}
			clear_end = i + 1
		}
		if (flags & SLF_RIGHTLEFT_O) == 0 {
			if (flags & SLF_INC_VCOL_O) != 0 {
				lv += 1
			}
			grid.vcols[off] = lv
		}
		i += 1
	}

	if (flags & SLF_RIGHTLEFT_O) != 0 && start_dirty != -1 && clear_dirty_start != -1 {
		if grid.throttled || clear_dirty_start >= start_dirty - 5 {
			// Cannot draw now or too small for a separate clear event.
			start_dirty = clear_dirty_start
		} else {
			ui_line_r(grid, row, invalid_row, coloff + clear_dirty_start,
				coloff + clear_dirty_start, coloff + clear_end, ca,
				(flags & SLF_WRAP_O) != 0)
		}
		clear_end = end_dirty
	} else {
		if start_dirty == -1 { // clear only
			start_dirty = clear_dirty_start
			end_dirty = clear_dirty_start
		} else if clear_end < end_dirty { // put only
			clear_end = end_dirty
		} else {
			end_dirty = end
		}
	}

	if clear_end > start_dirty {
		if !grid.throttled {
			ui_line_r(grid, row, invalid_row, coloff + start_dirty,
				coloff + end_dirty, coloff + clear_end, ca,
				(flags & SLF_WRAP_O) != 0)
		} else if grid.dirty_col != nil {
			// TODO(bfredl): kill the extra pseudo terminal in message.c
			// with a linebuf_char copy for "throttled message line".
			if clear_end > grid.dirty_col[row] {
				grid.dirty_col[row] = clear_end
			}
		}
	}
}

// ── Batch 2c: grid_adjust + line-build cluster + grid_alloc/free ─────────────
// grid_alloc is included (not deferred) because it OWNS linebuf_size writes —
// leaving it in C while screengrid_line_start reads an Odin copy would be a
// Batch-37a-class split-brain on the C static.

foreign _ {
	@(link_name = "linebuf_char")
	linebuf_char_g: [^]u32
	@(link_name = "linebuf_attr")
	linebuf_attr_g: [^]C.int
	@(link_name = "linebuf_vcol")
	linebuf_vcol_g: [^]C.int
	@(link_name = "linebuf_scratch")
	linebuf_scratch_g: ^u8
	@(link_name = "rdb_flags")
	rdb_flags_g: C.uint
	@(link_name = "utfc_ptr2len_len")
	utfc_ptr2len_len_r :: proc "c"(p: cstring, size: C.int) -> C.int ---
	@(link_name = "utfc_ptrlen2schar")
	utfc_ptrlen2schar_r :: proc "c"(p: cstring, len: C.int, firstc: ^C.int) -> u32 ---
	@(link_name = "ui_grid_cursor_goto")
	ui_grid_cursor_goto_r :: proc "c"(grid_handle: C.int, new_row: C.int, new_col: C.int) ---
}

// C static: shared scratch width of all grids (written by grid_alloc,
// read by screengrid_line_start — both Odin now, no split-brain).
@(private="file")
linebuf_size_f: C.size_t = 0

// grid_line_* statics (grid.c:360-369).
@(private="file")
grid_line_grid_f:       ^ScreenGrid
@(private="file")
grid_line_row_f:        C.int = -1
@(private="file")
grid_line_coloff_f:     C.int = 0
@(private="file")
grid_line_maxcol_f:     C.int = 0
@(private="file")
grid_line_first_f:      C.int = 2147483647 // INT_MAX
@(private="file")
grid_line_last_f:       C.int = 0
@(private="file")
grid_line_clear_to_f:   C.int = 0
@(private="file")
grid_line_bg_attr_f:    C.int = 0
@(private="file")
grid_line_clear_attr_f: C.int = 0
@(private="file")
grid_line_flags_f:      C.int = 0

KOPT_RDB_INVALID_O :: 0x04
KOPT_RDB_NODELTA_O :: 0x08

// grid_put_linebuf flags (grid.h:32-36).
SLF_RIGHTLEFT_O :: 1
SLF_WRAP_O      :: 2
SLF_INC_VCOL_O  :: 4

// Adjust window-relative positions to global screen positions.
// (Trivial: only usable where win_grid_alloc already ran.)
@(export)
grid_adjust :: proc "c"(grid: ^GridView, row_off: ^C.int, col_off: ^C.int) -> ^ScreenGrid {
	row_off^ += grid.row_offset
	col_off^ += grid.col_offset
	return grid.target
}

// Start a group of grid_line_puts calls building a single grid line.
// Must be matched with grid_line_flush before moving to another line.
@(export)
grid_line_start :: proc "c"(view: ^GridView, row: C.int) {
	col: C.int = 0
	r := row
	grid := grid_adjust(view, &r, &col)
	screengrid_line_start(grid, r, col)
}

@(export)
screengrid_line_start :: proc "c"(grid: ^ScreenGrid, row: C.int, col: C.int) {
	grid_line_maxcol_f = grid.cols
	if grid_line_grid_f != nil {
		libc.abort()
	}
	grid_line_row_f = row
	grid_line_grid_f = grid
	grid_line_coloff_f = col
	grid_line_first_f = C.int(linebuf_size_f)
	grid_line_maxcol_f = min(grid_line_maxcol_f, grid.cols - grid_line_coloff_f)
	grid_line_last_f = 0
	grid_line_clear_to_f = 0
	grid_line_bg_attr_f = 0
	grid_line_clear_attr_f = 0
	grid_line_flags_f = 0

	if C.size_t(grid_line_maxcol_f) > linebuf_size_f {
		libc.abort()
	}

	if full_screen && (rdb_flags_g & KOPT_RDB_INVALID_O) != 0 {
		if linebuf_char_g == nil {
			libc.abort()
		}
		// Current batch must not depend on previous linebuf contents.
		// Invalid values trip assertions later if they are used.
		libc.memset(transmute(rawptr)(linebuf_char_g), 0xFF,
			C.size_t(size_of(u32)) * linebuf_size_f)
		libc.memset(transmute(rawptr)(linebuf_attr_g), 0xFF,
			C.size_t(size_of(C.int)) * linebuf_size_f)
	}
}

// Present char from the current rendered screen line (not the pending buffer).
// Space when out of bounds (NUL = right-half of double width is special).
@(export)
grid_line_getchar :: proc "c"(col: C.int, attr: ^C.int) -> u32 {
	if col < grid_line_maxcol_f {
		c := col + grid_line_coloff_f
		off := grid_line_grid_f.line_offset[grid_line_row_f] + C.size_t(c)
		if attr != nil {
			attr^ = grid_line_grid_f.attrs[off]
		}
		return grid_line_grid_f.chars[off]
	}
	return 32 // schar_from_ascii(' ')
}

@(export)
grid_line_put_schar :: proc "c"(col: C.int, schar: u32, attr: C.int) {
	if grid_line_grid_f == nil {
		libc.abort()
	}
	if col >= grid_line_maxcol_f {
		return
	}

	linebuf_char_g[col] = schar
	linebuf_attr_g[col] = attr

	grid_line_first_f = min(grid_line_first_f, col)
	// TODO(bfredl): Y U NO DOUBLEWIDTH?
	grid_line_last_f = max(grid_line_last_f, col + 1)
	linebuf_vcol_g[col] = -1
}

// Put string text at col relative to the grid line from grid_line_start.
// textlen = length or -1 for strlen. Only outputs within one row.
// Returns number of grid cells used.
@(export)
grid_line_puts :: proc "c"(col: C.int, text: cstring, textlen: C.int, attr: C.int) -> C.int {
	ptr := uintptr(rawptr(text))
	len := textlen

	if grid_line_grid_f == nil {
		libc.abort()
	}

	start_col := col
	c := col

	max_col := grid_line_maxcol_f
	tbase := uintptr(rawptr(text))
	for c < max_col && (len < 0 || C.int(uintptr(ptr) - tbase) < len) &&
		([^]u8)(ptr)[0] != 0 {
		// First byte of a multibyte char?
		mbyte_blen: C.int
		if len >= 0 {
			maxlen := C.int((tbase + uintptr(len)) - ptr)
			mbyte_blen = utfc_ptr2len_len_r(cstring(rawptr(ptr)), maxlen)
			if mbyte_blen > maxlen {
				mbyte_blen = 1
			}
		} else {
			mbyte_blen = utfc_ptr2len(cstring(rawptr(ptr)))
		}
		firstc: C.int
		schar := utfc_ptrlen2schar_r(cstring(rawptr(ptr)), mbyte_blen, &firstc)
		mbyte_cells := utf_ptr2cells_len_r(cstring(rawptr(ptr)), mbyte_blen)
		if mbyte_cells > 2 || schar == 0 {
			mbyte_cells = 1
			schar = schar_from_char(0xFFFD)
		}

		if c + mbyte_cells > max_col {
			// Only 1 cell left but char needs 2: '>' avoids wrapping.
			schar = 62 // schar_from_ascii('>')
			mbyte_cells = 1
		}

		// Overwriting the right half of a two-cell char in the same grid:
		// truncate into '>'.
		if ptr == tbase && c > grid_line_first_f && c < grid_line_last_f &&
			linebuf_char_g[c] == 0 {
			linebuf_char_g[c - 1] = 62 // '>'
		}

		linebuf_char_g[c] = schar
		linebuf_attr_g[c] = attr
		linebuf_vcol_g[c] = -1
		if mbyte_cells == 2 {
			linebuf_char_g[c + 1] = 0
			linebuf_attr_g[c + 1] = attr
			linebuf_vcol_g[c + 1] = -1
		}

		c += mbyte_cells
		ptr += uintptr(mbyte_blen)
	}

	if c > start_col {
		grid_line_first_f = min(grid_line_first_f, start_col)
		grid_line_last_f = max(grid_line_last_f, c)
	}

	return c - start_col
}

@(export)
grid_line_fill :: proc "c"(start_col: C.int, end_col: C.int, sc: u32, attr: C.int) -> C.int {
	end := min(end_col, grid_line_maxcol_f)
	if start_col >= end {
		return end
	}

	for col := start_col; col < end; col += 1 {
		linebuf_char_g[col] = sc
		linebuf_attr_g[col] = attr
		linebuf_vcol_g[col] = -1
	}

	grid_line_first_f = min(grid_line_first_f, start_col)
	grid_line_last_f = max(grid_line_last_f, end)
	return end
}

// bg_attr applies to buffered line + columns to clear;
// clear_attr only to the columns to clear.
@(export)
grid_line_clear_end :: proc "c"(start_col: C.int, end_col: C.int, bg_attr: C.int, clear_attr: C.int) {
	if grid_line_first_f > start_col {
		grid_line_first_f = start_col
		grid_line_last_f = start_col
	}
	grid_line_clear_to_f = end_col
	grid_line_bg_attr_f = bg_attr
	grid_line_clear_attr_f = clear_attr
}

// Move the cursor to a position in the currently rendered line.
@(export)
grid_line_cursor_goto :: proc "c"(col: C.int) {
	ui_grid_cursor_goto_r(grid_line_grid_f.handle, grid_line_row_f, col)
}

@(export)
grid_line_mirror :: proc "c"(width: C.int) {
	grid_line_clear_to_f = max(grid_line_last_f, grid_line_clear_to_f)
	if grid_line_first_f >= grid_line_clear_to_f {
		return
	}
	linebuf_mirror(&grid_line_first_f, &grid_line_last_f,
		&grid_line_clear_to_f, width)
	grid_line_flags_f |= SLF_RIGHTLEFT_O
}

@(export)
linebuf_mirror :: proc "c"(firstp: ^C.int, lastp: ^C.int, clearp: ^C.int, width: C.int) {
	first := firstp^
	last := lastp^

	n := C.size_t(last - first)
	mirror := width - 1 // Mirrors are more fun than television.
	scratch_char := ([^]u32)(uintptr(linebuf_scratch_g))
	libc.memcpy(transmute(rawptr)(&scratch_char[first]),
		transmute(rawptr)(&linebuf_char_g[first]), n * size_of(u32))
	for col := first; col < last; col += 1 {
		rev := mirror - col
		if col + 1 < last && scratch_char[col + 1] == 0 {
			linebuf_char_g[rev - 1] = scratch_char[col]
			linebuf_char_g[rev] = 0
			col += 1
		} else {
			linebuf_char_g[rev] = scratch_char[col]
		}
	}

	// Attr and vcol: doublewidth chars are self-consistent.
	scratch_attr := ([^]C.int)(uintptr(linebuf_scratch_g))
	libc.memcpy(transmute(rawptr)(&scratch_attr[first]),
		transmute(rawptr)(&linebuf_attr_g[first]), n * size_of(C.int))
	for col := first; col < last; col += 1 {
		linebuf_attr_g[mirror - col] = scratch_attr[col]
	}

	scratch_vcol := ([^]C.int)(uintptr(linebuf_scratch_g))
	libc.memcpy(transmute(rawptr)(&scratch_vcol[first]),
		transmute(rawptr)(&linebuf_vcol_g[first]), n * size_of(C.int))
	for col := first; col < last; col += 1 {
		linebuf_vcol_g[mirror - col] = scratch_vcol[col]
	}

	firstp^ = width - clearp^
	clearp^ = width - first
	lastp^ = width - last
}

// (Re)allocate a window grid on size change (ext_multigrid mode).
// Updates size, offsets and handle regardless. doclear skips copy.
// Owns linebuf_size: grows the shared scratch to the widest grid.
@(export)
grid_alloc :: proc "c"(grid: ^ScreenGrid, rows: C.int, columns: C.int, copy: bool, valid: bool) {
	ngrid := grid^
	if rows < 0 || columns < 0 {
		libc.abort()
	}
	ncells := C.size_t(rows) * C.size_t(columns)
	ngrid.chars = ([^]u32)(xmalloc(ncells * size_of(u32)))
	ngrid.attrs = ([^]C.int)(xmalloc(ncells * size_of(C.int)))
	ngrid.vcols = ([^]C.int)(xmalloc(ncells * size_of(C.int)))
	libc.memset(transmute(rawptr)(ngrid.vcols), -1, ncells * size_of(C.int))
	ngrid.line_offset = ([^]C.size_t)(xmalloc(C.size_t(rows) * size_of(C.size_t)))

	ngrid.rows = rows
	ngrid.cols = columns

	for new_row: C.int = 0; new_row < ngrid.rows; new_row += 1 {
		ngrid.line_offset[new_row] = C.size_t(new_row) * C.size_t(ngrid.cols)

		grid_clear_line(&ngrid, ngrid.line_offset[new_row], columns, valid)

		if copy {
			// Copy as much as possible from the old screen, clear the
			// rest (resize at "--more--" prompt or external command, GUI).
			if new_row < grid.rows && grid.chars != nil {
				slen := min(grid.cols, ngrid.cols)
				libc.memmove(transmute(rawptr)(&ngrid.chars[ngrid.line_offset[new_row]]),
					transmute(rawptr)(&grid.chars[grid.line_offset[new_row]]),
					C.size_t(slen) * size_of(u32))
				libc.memmove(transmute(rawptr)(&ngrid.attrs[ngrid.line_offset[new_row]]),
					transmute(rawptr)(&grid.attrs[grid.line_offset[new_row]]),
					C.size_t(slen) * size_of(C.int))
				libc.memmove(transmute(rawptr)(&ngrid.vcols[ngrid.line_offset[new_row]]),
					transmute(rawptr)(&grid.vcols[grid.line_offset[new_row]]),
					C.size_t(slen) * size_of(C.int))
			}
		}
	}
	grid_free(grid)
	grid^ = ngrid

	// Share one scratch buffer for all grids: widest grid wins.
	if linebuf_size_f < C.size_t(columns) {
		xfree(linebuf_char_g)
		xfree(linebuf_attr_g)
		xfree(linebuf_vcol_g)
		xfree(linebuf_scratch_g)
		linebuf_char_g = ([^]u32)(xmalloc(C.size_t(columns) * size_of(u32)))
		linebuf_attr_g = ([^]C.int)(xmalloc(C.size_t(columns) * size_of(C.int)))
		linebuf_vcol_g = ([^]C.int)(xmalloc(C.size_t(columns) * size_of(C.int)))
		linebuf_scratch_g = (^u8)(xmalloc(C.size_t(columns) * size_of(C.int)))
		linebuf_size_f = C.size_t(columns)
	}
}

@(export)
grid_free :: proc "c"(grid: ^ScreenGrid) {
	xfree(grid.chars)
	xfree(grid.attrs)
	xfree(grid.vcols)
	xfree(grid.line_offset)

	grid.chars = nil
	grid.attrs = nil
	grid.vcols = nil
	grid.line_offset = nil
}

// ── Batch 2b: ScreenGrid/GridView mirrors + grid leaves ──────────────────────
// (grid_line_* cluster needs linebuf_*/grid_adjust/full_screen — deferred.)

ScreenGrid :: struct {
	handle:                     C.int,    // 0
	chars:                      [^]u32,  // 8
	attrs:                      [^]C.int,// 16
	vcols:                      [^]C.int,// 24
	line_offset:                [^]C.size_t, // 32
	dirty_col:                  [^]C.int,// 40
	rows:                       C.int,   // 48
	cols:                       C.int,   // 52
	valid:                      bool,    // 56
	throttled:                  bool,    // 57
	blending:                   bool,    // 58
	mouse_enabled:              bool,    // 59
	zindex:                     C.int,   // 60
	comp_row:                   C.int,   // 64
	comp_col:                   C.int,   // 68
	comp_width:                 C.int,   // 72
	comp_height:                C.int,   // 76
	comp_index:                 C.size_t,// 80
	comp_disabled:              bool,    // 88
	pending_comp_index_update:  bool,    // 89
}
#assert(size_of(ScreenGrid) == 96)

GridView :: struct {
	target:     ^ScreenGrid, // 0
	row_offset: C.int,       // 8
	col_offset: C.int,       // 12
}
#assert(size_of(GridView) == 16)

// Clear a line in the grid starting at off until width chars are cleared.
@(export)
grid_clear_line :: proc "c"(grid: ^ScreenGrid, off: C.size_t, width: C.int, valid: bool) {
	for col: C.int = 0; col < width; col += 1 {
		grid.chars[uintptr(off) + uintptr(col)] = 32 // schar_from_ascii(' ')
	}
	fill: C.int = 0
	if !valid {
		fill = -1
	}
	// fill is 0 or -1: byte-fill equals the i32 fill (0x00000000/0xFFFFFFFF).
	libc.memset(transmute(rawptr)(&grid.attrs[off]), fill,
		C.size_t(width) * C.size_t(size_of(C.int)))
	libc.memset(transmute(rawptr)(&grid.vcols[off]), -1,
		C.size_t(width) * C.size_t(size_of(C.int)))
}

// Mark every cell attr invalid (forces full redraw).
@(export)
grid_invalidate :: proc "c"(grid: ^ScreenGrid) {
	libc.memset(transmute(rawptr)(grid.attrs), -1,
		C.size_t(size_of(C.int)) * C.size_t(grid.rows) * C.size_t(grid.cols))
}

// True when a row's first cell attr is invalid (plain, C-static).
grid_invalid_row_o :: proc "c"(grid: ^ScreenGrid, row: C.int) -> bool {
	return grid.attrs[grid.line_offset[row]] < 0
}

// Get a single char directly from grid.chars (attrp optional).
@(export)
grid_getchar :: proc "c"(grid: ^ScreenGrid, row: C.int, col: C.int, attrp: ^C.int) -> u32 {
	// Safety check.
	if grid.chars == nil || row >= grid.rows || col >= grid.cols {
		return 0 // NUL
	}

	off := grid.line_offset[row] + C.size_t(col)
	if attrp != nil {
		attrp^ = grid.attrs[off]
	}
	return grid.chars[off]
}

// ── Batch 2a: arabic shaping over a screen line ─────────────────────────────
// (arabic_shape/combine/maycombine now Odin exports in arabic.odin.)

ARABIC_CHAR_O :: proc "c"(ch: C.int) -> bool {
	return (ch & 0xFF00) == 0x0600
}

// Shape the arabic text in buf[0..cols] in place.
@(export)
line_do_arabic_shape :: proc "c"(buf: [^]u32, cols: C.int) {
	i: C.int = 0
	for i < cols {
		// Quickly skip over non-arabic text.
		if schar_in_arabic_block_o(buf[i]) {
			break
		}
		i += 1
	}

	if i == cols {
		return
	}

	c0prev: C.int = 0
	c0, c1: C.int
	schar_get_first_two_codepoints_o(buf[i], &c0, &c1)

	for ; i < cols; {
		c0next, c1next: C.int
		if i + 1 < cols {
			schar_get_first_two_codepoints_o(buf[i + 1], &c0next, &c1next)
		} else {
			schar_get_first_two_codepoints_o(0, &c0next, &c1next)
		}

		if ARABIC_CHAR_O(c0) {
			c1new := c1
			c0new := arabic_shape(c0, &c1new, c0next, c1next, c0prev)

			if c0new != c0 || c1new != c1 {
				scbuf: [MAX_SCHAR_SIZE_O]u8
				schar_get(&scbuf[0], buf[i])

				scbuf_new: [MAX_SCHAR_SIZE_O]u8
				slen := C.size_t(utf_char2bytes(c0new,
					&scbuf_new[0]))
				if c1new != 0 {
					slen += C.size_t(utf_char2bytes(c1new,
						(^u8)(uintptr(&scbuf_new[0]) + uintptr(slen))))
				}

				off := C.int(utf_char2len_r(c0)) +
					(C.int(utf_char2len_r(c1)) if c1 != 0 else C.int(0))
				rest := libc.strlen(cstring(
					(^u8)(uintptr(&scbuf[0]) + uintptr(off))))
				if rest + slen + 1 > MAX_SCHAR_SIZE_O {
					// Too bigly, discard one code-point.
					// Enough as c0 grows at most 2→4 bytes
					// (base arabic to extended arabic).
					bounds := utf_cp_bounds_r(
						(^u8)(uintptr(&scbuf[0]) + uintptr(off)),
						(^u8)(uintptr(&scbuf[0]) + uintptr(off) +
							uintptr(rest) - 1))
					rest -= C.size_t(bounds.begin_off) + 1
				}
				libc.memcpy(
					transmute(rawptr)((^u8)(uintptr(&scbuf_new[0]) +
						uintptr(slen))),
					transmute(rawptr)((^u8)(uintptr(&scbuf[0]) +
						uintptr(off))), rest)
				buf[i] = schar_from_buf(&scbuf_new[0], slen + rest)
			}
		}

		c0prev = c0
		c0 = c0next
		c1 = c1next
		i += 1
	}
}
