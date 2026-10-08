// decoration.odin — port of src/nvim/decoration.c (extmark decorations,
// virtual text/lines, sign/highlight redraw support for the draw engine).
package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

foreign _ {
	// C-owned EXTERN globals (decoration.h, defined in main.c.o).
	// Single copies — Odin reads/writes these directly (grid_line_buf lesson).
	decor_items: Kvec_DSH
	@(link_name = "hl_add_url")
	hl_add_url_e :: proc "c" (attr: C.int, url: ^u8) -> C.int ---
	@(link_name = "virt_text_to_array")
	virt_text_to_array_e :: proc "c" (vt: Kvec_VT, hl_name: bool, arena: rawptr) -> Api_Array ---
	@(link_name = "describe_sign_text")
	describe_sign_text_e :: proc "c" (buf: ^u8, sign_text: ^u32) -> C.size_t ---
	@(link_name = "virt_text_pos_str")
	virt_text_pos_str_g: [6]cstring
	@(link_name = "hl_mode_str")
	hl_mode_str_g: [4]cstring
}

// kvec_t(DecorSignHighlight): items are 56B.
Kvec_DSH :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: [^]DecorSignHighlight_O,
}

// DecorHighlightInline mirror (cc-probed, 12B).
DecorHighlightInline_O :: struct {
	flags:        u16, // 0
	priority:     u16, // 2 (DecorPriority)
	hl_id:        C.int, // 4
	conceal_char: u32, // 8 (schar_T)
}
#assert(size_of(DecorHighlightInline_O) == 12)

// DecorExt mirror (cc-probed, 16B).
DecorExt_O :: struct {
	sh_idx: u32,   // 0
	_pad:   [4]u8,
	vt:     rawptr, // 8 (^DecorVirtText_O)
}
#assert(size_of(DecorExt_O) == 16)

// DecorSignHighlight mirror (cc-probed, 56B).
DecorSignHighlight_O :: struct {
	flags:            u16,   // 0
	priority:         u16,   // 2 (DecorPriority)
	hl_id:            C.int, // 4
	text:             [2]u32, // 8 (schar_T[SIGN_WIDTH], SIGN_WIDTH=2)
	sign_name:        ^u8,   // 16
	sign_add_id:      C.int, // 24
	number_hl_id:     C.int, // 28
	line_hl_id:       C.int, // 32
	cursorline_hl_id: C.int, // 36
	next:             u32,   // 40
	_pad44:           [4]u8,
	url:              ^u8,   // 48 (const char*)
}
#assert(size_of(DecorSignHighlight_O) == 56)
#assert(offset_of(DecorSignHighlight_O, text) == 8)
#assert(offset_of(DecorSignHighlight_O, next) == 40)
#assert(offset_of(DecorSignHighlight_O, url) == 48)

// SignItem mirror (cc-probed, 16B).
SignItem_O :: struct {
	sh: ^DecorSignHighlight_O, // 0
	id: C.int,                 // 8 (mark id)
}
#assert(size_of(SignItem_O) == 16)

// virt_line mirror lives in drawline.odin (VirtLine_O, 32B) — reuse directly.

// kvec_t(virt_line).
Kvec_VL :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: [^]VirtLine_O,
}

DECOR_ID_INVALID_O :: u32(4294967295)

// kSH* flags (decoration_defs.h).
KSH_IS_SIGN_O :: u16(1)
KSH_HL_EOL_O :: u16(2)
KSH_UI_WATCHED_O :: u16(4)
KSH_UI_WATCHED_OVERLAY_O :: u16(8)
KSH_SPELL_ON_O :: u16(16)
KSH_SPELL_OFF_O :: u16(32)
KSH_CONCEAL_O :: u16(64)
KSH_CONCEAL_LINES_O :: u16(128)
KSH_CONCEAL_OFF_O :: u16(256)

// kVT* flags (decoration_defs.h).
KVT_IS_LINES_O :: u8(1)
KVT_HIDE_O :: u8(2)
KVT_LINES_ABOVE_O :: u8(4)
KVT_REPEAT_LINEBREAK_O :: u8(8)

// kVL* / overflow (decoration_defs.h; K_VL_LEFTCOL_O lives in drawline.odin).
KVL_OVERFLOW_TRUNC_O :: 0
KVL_OVERFLOW_SCROLL_O :: 1
KVL_OVERFLOW_WRAP_O :: 2
KVL_OVERFLOW_AUTO_O :: 3

// kMTMeta* (marktree_defs.h; Inline/Lines/SignHL/SignText exist elsewhere).
KMTMETA_CONCEAL_LINES_O :: 4
KMTMETA_COUNT_O :: 5

// kExtmark* type flags (extmark.h; KEXTMARK_NONE_O lives in extmark.odin).
KEXTMARK_SIGN_O :: 0x2
KEXTMARK_SIGNHL_O :: 0x4
KEXTMARK_VIRTTEXT_O :: 0x8
KEXTMARK_VIRTLINES_O :: 0x10
KEXTMARK_HIGHLIGHT_O :: 0x20

// C file-statics (only decoration.c touches them — single copies here).
@(private = "file")
decor_freelist_g: u32 = DECOR_ID_INVALID_O
@(private = "file")
to_free_virt_g: rawptr = nil
@(private = "file")
to_free_sh_g: u32 = DECOR_ID_INVALID_O
@(private = "file")
sign_add_id_g: C.int = 0
@(private = "file")
signtext_filter_g: [5]u32 = {0, 0, 0, u32(0xFFFFFFFF), 0} // [kMTMetaSignText]=Select
@(private = "file")
lines_filter_g: [5]u32 = {0, u32(0xFFFFFFFF), 0, 0, 0} // [kMTMetaLines]=Select

// kvec push for decor_items (indices are stable decor ids).
kv_push_dsh_o :: proc "c" (item: DecorSignHighlight_O) -> u32 {
	context = runtime.default_context()
	if decor_items.n == decor_items.a {
		new_a: C.size_t = decor_items.a * 2
		if new_a < 8 {
			new_a = 8
		}
		decor_items.items = ([^]DecorSignHighlight_O)(xrealloc(rawptr(decor_items.items), new_a * C.size_t(size_of(DecorSignHighlight_O))))
		decor_items.a = new_a
	}
	([^]DecorSignHighlight_O)(decor_items.items)[decor_items.n] = item
	decor_items.n += 1
	return u32(decor_items.n - 1)
}

@(export)
decor_put_sh :: proc "c" (item: DecorSignHighlight_O) -> u32 {
	context = runtime.default_context()
	if decor_freelist_g != DECOR_ID_INVALID_O {
		pos := decor_freelist_g
		decor_freelist_g = ([^]DecorSignHighlight_O)(decor_items.items)[pos].next
		([^]DecorSignHighlight_O)(decor_items.items)[pos] = item
		return pos
	}
	return kv_push_dsh_o(item)
}

@(export)
decor_put_vt :: proc "c" (vt: DecorVirtText_O, next: rawptr) -> rawptr {
	context = runtime.default_context()
	decor_alloc := (^DecorVirtText_O)(xmalloc(C.size_t(size_of(DecorVirtText_O))))
	decor_alloc^ = vt
	decor_alloc.next = next
	return rawptr(decor_alloc)
}

@(export)
decor_sh_from_inline :: proc "c" (item: DecorHighlightInline_O) -> DecorSignHighlight_O {
	context = runtime.default_context()
	if (item.flags & KSH_IS_SIGN_O) != 0 {
		libc.abort()
	}
	return DecorSignHighlight_O{
		flags = item.flags,
		priority = item.priority,
		hl_id = item.hl_id,
		text = {item.conceal_char, 0},
		number_hl_id = 0,
		line_hl_id = 0,
		cursorline_hl_id = 0,
		next = DECOR_ID_INVALID_O,
	}
}

@(export)
decor_free :: proc "c" (decor: DecorInline_O) {
	context = runtime.default_context()
	if !decor.ext {
		return
	}
	d := decor
	vt := (^rawptr)(uintptr(&d.data[0]) + 8)^
	idx := (^u32)(&d.data[0])^
	if decor_state_g.running_decor_provider {
		for vt != nil {
			nx := (^DecorVirtText_O)(vt).next
			if nx == nil {
				(^DecorVirtText_O)(vt).next = to_free_virt_g
				to_free_virt_g = (^rawptr)(uintptr(&d.data[0]) + 8)^
				break
			}
			vt = nx
		}
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			if sh.next == DECOR_ID_INVALID_O {
				sh.next = to_free_sh_g
				to_free_sh_g = (^u32)(&d.data[0])^
				break
			}
			idx = sh.next
		}
	} else {
		decor_free_inner_o((^rawptr)(uintptr(&d.data[0]) + 8)^, (^u32)(&d.data[0])^)
	}
}

// C-static (dormant until decor_free ports — now live).
decor_free_inner_o :: proc "c" (vt_in: rawptr, first_idx: u32) {
	context = runtime.default_context()
	vt := vt_in
	for vt != nil {
		v := (^DecorVirtText_O)(vt)
		if (v.flags & KVT_IS_LINES_O) != 0 {
			clear_virtlines((^Kvec_VL)(uintptr(v) + 16))
		} else {
			clear_virttext((^Kvec_VT)(uintptr(v) + 16))
		}
		tofree := vt
		vt = v.next
		xfree(tofree)
	}
	idx := first_idx
	for idx != DECOR_ID_INVALID_O {
		sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
		if (sh.flags & KSH_IS_SIGN_O) != 0 {
			xfree(rawptr(sh.sign_name))
			sh.sign_name = nil
		}
		sh.flags = 0
		if sh.url != nil {
			xfree(rawptr(sh.url))
			sh.url = nil
		}
		if sh.next == DECOR_ID_INVALID_O {
			sh.next = decor_freelist_g
			decor_freelist_g = first_idx
			break
		}
		idx = sh.next
	}
}

@(export)
clear_virttext :: proc "c" (text: ^Kvec_VT) {
	context = runtime.default_context()
	for i: C.size_t = 0; i < text.n; i += 1 {
		xfree(rawptr(([^]VirtTextChunk)(text.items)[i].text))
	}
	xfree(rawptr(text.items))
	text.n = 0
	text.a = 0
	text.items = nil
}

@(export)
clear_virtlines :: proc "c" (lines: ^Kvec_VL) {
	context = runtime.default_context()
	for i: C.size_t = 0; i < lines.n; i += 1 {
		clear_virttext((^Kvec_VT)(uintptr(lines.items) + uintptr(i) * uintptr(size_of(VirtLine_O))))
	}
	xfree(rawptr(lines.items))
	lines.n = 0
	lines.a = 0
	lines.items = nil
}

// ── Batch D2: buf put/remove/redraw ──────────────────────────────────────────

@(export)
bufhl_add_hl_pos_offset :: proc "c" (buf: rawptr, src_id: C.int, hl_id: C.int, pos_start: Lpos_T, pos_end: Lpos_T, offset: C.int) {
	context = runtime.default_context()
	hl_start: C.int = 0
	hl_end: C.int = 0
	decor := DecorInline_O{}
	(^C.int)(uintptr(&decor.data[0]) + 4)^ = hl_id
	for lnum := pos_start.lnum; lnum <= pos_end.lnum; lnum += 1 {
		end_off: C.int = 0
		if pos_start.lnum < lnum && lnum < pos_end.lnum {
			hl_start = max(offset - 1, 0)
			end_off = 1
			hl_end = 0
		} else if lnum == pos_start.lnum && lnum < pos_end.lnum {
			hl_start = pos_start.col + offset
			end_off = 1
			hl_end = 0
		} else if pos_start.lnum < lnum && lnum == pos_end.lnum {
			hl_start = max(offset - 1, 0)
			hl_end = pos_end.col + offset
		} else if pos_start.lnum == lnum && pos_end.lnum == lnum {
			hl_start = pos_start.col + offset
			hl_end = pos_end.col + offset
		}
		extmark_set(buf, u32(src_id), nil, lnum - 1, hl_start, lnum - 1 + end_off, hl_end, decor, MT_FLAG_DECOR_HL_O, true, false, true, false, nil)
	}
}

@(export)
decor_redraw :: proc "c" (buf: rawptr, row1: C.int, row2: C.int, col1: C.int, decor: DecorInline_O) {
	context = runtime.default_context()
	d := decor
	if d.ext {
		vt := (^rawptr)(uintptr(&d.data[0]) + 8)^
		for vt != nil {
			v := (^DecorVirtText_O)(vt)
			below := (v.flags & KVT_IS_LINES_O) != 0 && (v.flags & KVT_LINES_ABOVE_O) == 0
			vt_lnum := row1 + 1 + C.int(below)
			redraw_buf_line_later(buf, vt_lnum, true)
			if (v.flags & KVT_IS_LINES_O) != 0 || v.pos == K_VPOS_INLINE_O {
				vt_col: C.int = 0
				if (v.flags & KVT_IS_LINES_O) == 0 {
					vt_col = col1
				}
				changed_lines_invalidate_buf(buf, vt_lnum, vt_col, vt_lnum + 1, 0)
			}
			vt = v.next
		}
		idx := (^u32)(&d.data[0])^
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			decor_redraw_sh(buf, row1, row2, sh^)
			idx = sh.next
		}
	} else {
		hl := DecorHighlightInline_O{
			flags = (^u16)(&d.data[0])^,
			priority = (^u16)(uintptr(&d.data[0]) + 2)^,
			hl_id = (^C.int)(uintptr(&d.data[0]) + 4)^,
			conceal_char = (^u32)(uintptr(&d.data[0]) + 8)^,
		}
		decor_redraw_sh(buf, row1, row2, decor_sh_from_inline(hl))
	}
}

@(export)
decor_redraw_sh :: proc "c" (buf: rawptr, row1: C.int, row2: C.int, sh: DecorSignHighlight_O) {
	context = runtime.default_context()
	if sh.hl_id != 0 || sh.url != nil || (sh.flags & (KSH_IS_SIGN_O | KSH_SPELL_ON_O | KSH_SPELL_OFF_O | KSH_CONCEAL_O | KSH_CONCEAL_OFF_O)) != 0 {
		if row2 >= row1 {
			redraw_buf_range_later(buf, row1 + 1, row2 + 1)
		}
	}
	if (sh.flags & KSH_CONCEAL_LINES_O) != 0 {
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
					changed_window_setting(wp)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
	}
	if (sh.flags & KSH_UI_WATCHED_O) != 0 {
		redraw_buf_line_later(buf, row1 + 1, false)
	}
}

@(export)
buf_put_decor :: proc "c" (buf: rawptr, decor: DecorInline_O, row: C.int, row2_in: C.int) {
	context = runtime.default_context()
	d := decor
	if d.ext && row < (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ {
		idx := (^u32)(&d.data[0])^
		row2 := min((^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ - 1, row2_in)
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			buf_put_decor_sh(buf, sh, row, row2)
			idx = sh.next
		}
	}
}

// C-static (dormant until buf_put_decor_sh ports — now live).
may_force_numberwidth_recompute_o :: proc "c" (buf: rawptr, unplace: bool) {
	context = runtime.default_context()
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf && (^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ == SCL_NUM_O && ((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 || (^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0) && (unplace || (^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^ < 2) {
				(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ = 0
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
}

@(export)
buf_put_decor_sh :: proc "c" (buf: rawptr, sh: ^DecorSignHighlight_O, row1: C.int, row2: C.int) {
	context = runtime.default_context()
	if (sh.flags & KSH_IS_SIGN_O) != 0 {
		sh.sign_add_id = sign_add_id_g
		sign_add_id_g += 1
		if sh.text[0] != 0 {
			buf_signcols_count_range(buf, row1, row2, 1, C.int(TriState.kFalse))
			may_force_numberwidth_recompute_o(buf, false)
		}
	}
}

@(export)
buf_decor_remove :: proc "c" (buf: rawptr, row1: C.int, row2_in: C.int, col1: C.int, decor: DecorInline_O, do_free: bool) {
	context = runtime.default_context()
	d := decor
	decor_redraw(buf, row1, row2_in, col1, d)
	if d.ext && row1 < (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ {
		idx := (^u32)(&d.data[0])^
		row2 := min((^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ - 1, row2_in)
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			buf_remove_decor_sh(buf, row1, row2, sh)
			idx = sh.next
		}
	}
	if do_free {
		decor_free(d)
	}
}

@(export)
buf_remove_decor_sh :: proc "c" (buf: rawptr, row1: C.int, row2: C.int, sh: ^DecorSignHighlight_O) {
	context = runtime.default_context()
	if (sh.flags & KSH_IS_SIGN_O) != 0 {
		if sh.text[0] != 0 {
			if buf_meta_total_o(buf, K_MTMETA_SIGNTEXT_O) != 0 {
				buf_signcols_count_range(buf, row1, row2, -1, C.int(TriState.kFalse))
			} else {
				may_force_numberwidth_recompute_o(buf, true)
				(^C.int)(uintptr(buf) + B_SIGNCOLS_COUNT_OFF)^ = 0
				(^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ = 0
			}
		}
	}
}

@(export)
buf_signcols_count_range :: proc "c" (buf: rawptr, row1: C.int, row2: C.int, add: C.int, clear: C.int) {
	context = runtime.default_context()
	if !(^bool)(uintptr(buf) + B_SIGNCOLS_AUTOM_OFF)^ || row2 < row1 || buf_meta_total_o(buf, K_MTMETA_SIGNTEXT_O) == 0 {
		return
	}
	count := ([^]C.int)(xcalloc(C.size_t(row2 + 1 - row1), C.size_t(size_of(C.int))))
	itr: MarkTreeIter_O
	pair: MTPair_O
	marktree_itr_get_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), row1, 0, rawptr(&itr))
	for marktree_itr_step_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), &pair) {
		if (pair.start.flags & MT_FLAG_DECOR_SIGNTEXT_O) != 0 && !mt_invalid_o(pair.start) {
			for i := row1; i <= min(row2, C.int(pair.end_pos.row)); i += 1 {
				count[uintptr(i - row1)] += 1
			}
		}
	}
	marktree_itr_step_out_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), ([^]u32)(&signtext_filter_g[0]))
	for (^rawptr)(uintptr(&itr) + 16) != nil {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) > row2 {
			break
		}
		if (mark.flags & MT_FLAG_DECOR_SIGNTEXT_O) != 0 && !mt_invalid_o(mark) && !mt_end_o(mark) {
			endpos := marktree_get_altpos(rawptr(uintptr(buf) + B_MARKTREE_OFF), mark, nil)
			for i := C.int(mark.pos.row); i <= min(row2, C.int(endpos.row)); i += 1 {
				count[uintptr(i - row1)] += 1
			}
		}
		marktree_itr_next_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), row2 + 1, 0, ([^]u32)(&signtext_filter_g[0]))
	}
	for i: C.int = 0; i < row2 + 1 - row1; i += 1 {
		prevwidth := min(C.int(9), count[uintptr(i)] - add)
		if clear != C.int(TriState.kNone) && prevwidth > 0 {
			([^]C.int)(uintptr(buf) + B_SIGNCOLS_COUNT_OFF)[uintptr(prevwidth - 1)] -= 1
		}
		width := min(C.int(9), count[uintptr(i)])
		if clear != C.int(TriState.kTrue) && width > 0 {
			([^]C.int)(uintptr(buf) + B_SIGNCOLS_COUNT_OFF)[uintptr(width - 1)] += 1
			if width > (^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ {
				(^C.int)(uintptr(buf) + B_SIGNCOLS_MAX_OFF)^ = width
			}
		}
	}
	xfree(rawptr(count))
}

// ── Batch D3: state leaves ───────────────────────────────────────────────────
// MT_FLAG_DECOR_EXT_O lives in plines.odin — reuse directly.

@(export)
decor_state_invalidate :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	win := (^rawptr)(uintptr(&decor_state_g) + 280)^
	if win != nil && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf {
		([^]u8)(uintptr(&decor_state_g))[325] = 0
	}
}

@(export)
decor_check_to_be_deleted :: proc "c" () {
	context = runtime.default_context()
	if decor_state_g.running_decor_provider {
		libc.abort()
	}
	decor_free_inner_o(to_free_virt_g, to_free_sh_g)
	to_free_virt_g = nil
	to_free_sh_g = DECOR_ID_INVALID_O
	(^rawptr)(uintptr(&decor_state_g) + 280)^ = nil
}

@(export)
decor_state_free :: proc "c" (state: ^DecorState_O) {
	context = runtime.default_context()
	xfree(rawptr(state.slots.items))
	state.slots.n = 0
	state.slots.a = 0
	state.slots.items = nil
	xfree(rawptr(state.ranges_i.items))
	state.ranges_i.n = 0
	state.ranges_i.a = 0
	state.ranges_i.items = nil
}

@(export)
decor_check_invalid_glyphs :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < decor_items.n; i += 1 {
		it := &([^]DecorSignHighlight_O)(decor_items.items)[i]
		width := 0
		if (it.flags & KSH_IS_SIGN_O) != 0 {
			width = SIGN_WIDTH_O
		} else if (it.flags & KSH_CONCEAL_O) != 0 {
			width = 1
		}
		for j := 0; j < width; j += 1 {
			if schar_high(it.text[uintptr(j)]) {
				it.text[uintptr(j)] = schar_from_char(schar_get_first_codepoint(it.text[uintptr(j)]))
			}
		}
	}
}

@(export)
next_virt_text_chunk :: proc "c" (vt: Kvec_VT, pos: ^C.size_t, attr: ^C.int) -> ^u8 {
	context = runtime.default_context()
	text: ^u8 = nil
	for text == nil && pos^ < vt.n {
		text = ([^]VirtTextChunk)(vt.items)[pos^].text
		hl_id := ([^]VirtTextChunk)(vt.items)[pos^].hl_id
		if hl_id >= 0 {
			attr^ = max(attr^, 0)
			if hl_id > 0 {
				attr^ = hl_combine_attr_r(attr^, syn_id2attr_r(hl_id))
			}
		}
		pos^ += 1
	}
	return text
}

@(export)
decor_find_virttext :: proc "c" (buf: rawptr, row: C.int, ns_id: u64) -> rawptr {
	context = runtime.default_context()
	itr: MarkTreeIter_O
	marktree_itr_get(rawptr(uintptr(buf) + B_MARKTREE_OFF), C.int32_t(row), 0, rawptr(&itr))
	for {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 || C.int(mark.pos.row) > row {
			break
		} else if mt_invalid_o(mark) {
			marktree_itr_next(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr))
			continue
		}
		decor: rawptr = nil
		if (mark.flags & MT_FLAG_DECOR_EXT_O) != 0 {
			decor = (^rawptr)(uintptr(&mark.decor[0]) + 8)^
		}
		for decor != nil && ((^DecorVirtText_O)(decor).flags & KVT_IS_LINES_O) != 0 {
			decor = (^DecorVirtText_O)(decor).next
		}
		if (ns_id == 0 || ns_id == u64(mark.ns)) && decor != nil {
			return decor
		}
		marktree_itr_next(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr))
	}
	return nil
}

// ── Batch D4: redraw engine ──────────────────────────────────────────────────

// kvec push for DecorState.slots (96B DecorRangeSlot items).
dp_slots_push_o :: proc "c" (state: ^DecorState_O, range: DecorRange_O) -> C.int {
	context = runtime.default_context()
	if state.slots.n == state.slots.a {
		new_a: C.size_t = state.slots.a * 2
		if new_a < 8 {
			new_a = 8
		}
		state.slots.items = (rawptr)(xrealloc(rawptr(state.slots.items), new_a * C.size_t(size_of(DecorRange_O))))
		state.slots.a = new_a
	}
	([^]DecorRange_O)(state.slots.items)[uintptr(state.slots.n)] = range
	state.slots.n += 1
	return C.int(state.slots.n - 1)
}

// kvec push for DecorState.ranges_i (C.int items).
dp_ranges_push_o :: proc "c" (state: ^DecorState_O) -> ^C.int {
	context = runtime.default_context()
	if state.ranges_i.n == state.ranges_i.a {
		new_a: C.size_t = state.ranges_i.a * 2
		if new_a < 8 {
			new_a = 8
		}
		state.ranges_i.items = ([^]C.int)(xrealloc(rawptr(state.ranges_i.items), new_a * C.size_t(size_of(C.int))))
		state.ranges_i.a = new_a
	}
	slot := (^C.int)(uintptr(state.ranges_i.items) + uintptr(state.ranges_i.n) * uintptr(size_of(C.int)))
	state.ranges_i.n += 1
	return slot
}

@(export)
decor_redraw_reset :: proc "c" (wp: rawptr, state_in: rawptr) -> bool {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	state.row = -1
	(^rawptr)(uintptr(state) + 280)^ = wp
	indices := ([^]C.int)(state.ranges_i.items)
	slots := ([^]DecorRange_O)(rawptr(state.slots.items))
	beg := [2]C.int{0, state.future_begin}
	end := [2]C.int{state.current_end, C.int(state.ranges_i.n)}
	for pos_i := 0; pos_i < 2; pos_i += 1 {
		for i := beg[uintptr(pos_i)]; i < end[uintptr(pos_i)]; i += 1 {
			r := (^DecorRange_O)(uintptr(slots) + uintptr(indices[uintptr(i)]) * uintptr(size_of(DecorRange_O)))
			if r.owned && r.kind == u8(K_DECOR_VIRTTEXT_O) {
				vt := (^DecorVirtText_O)(r.vt)
				clear_virttext((^Kvec_VT)(uintptr(vt) + 16))
				xfree(rawptr(vt))
			}
		}
	}
	state.slots.n = 0
	state.ranges_i.n = 0
	(^C.int)(uintptr(state) + 272)^ = -1
	state.current_end = 0
	state.future_begin = 0
	(^C.int)(uintptr(state) + 276)^ = 0
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	return (^MarkTree_O)(uintptr(buf) + B_MARKTREE_OFF).n_keys != 0
}

@(export)
decor_virt_pos :: proc "c" (decor: ^DecorRange_O) -> bool {
	context = runtime.default_context()
	return decor.kind == u8(K_DECOR_VIRTTEXT_O) || decor.kind == u8(K_DECOR_UIWATCHED_O)
}

@(export)
decor_virt_pos_kind :: proc "c" (decor: ^DecorRange_O) -> C.int {
	context = runtime.default_context()
	if decor.kind == u8(K_DECOR_VIRTTEXT_O) {
		return (^DecorVirtText_O)(decor.vt).pos
	}
	if decor.kind == u8(K_DECOR_UIWATCHED_O) {
		return (^C.int)(uintptr(decor) + 32 + 8)^
	}
	return C.int(K_VPOS_EOL_O)
}

@(export)
decor_redraw_start :: proc "c" (wp: rawptr, top_row: C.int, state_in: rawptr) -> bool {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	(^C.int)(uintptr(state) + 288)^ = top_row
	([^]u8)(uintptr(state))[325] = 1
	ok := marktree_itr_get_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), top_row, 0, rawptr(uintptr(state)))
	if !ok {
		return false
	}
	pair: MTPair_O
	for marktree_itr_step_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(uintptr(state)), &pair) {
		m := pair.start
		if mt_invalid_o(m) || !mt_decor_any_o(m) {
			continue
		}
		decor_range_add_from_inline_o(state, C.int(m.pos.row), C.int(m.pos.col), C.int(pair.end_pos.row), C.int(pair.end_pos.col), mt_decor_o(m), false, u32(m.ns), u32(m.id))
	}
	return true
}

// C-static (dormant until decor_redraw_line ports — now live).
decor_state_pack_o :: proc "c" (state: ^DecorState_O) {
	context = runtime.default_context()
	count := C.int(state.ranges_i.n)
	cur_end := state.current_end
	fut_beg := state.future_begin
	if fut_beg == count {
		fut_beg = cur_end
		count = cur_end
	} else if fut_beg != cur_end {
		indices := ([^]C.int)(state.ranges_i.items)
		libc.memmove(rawptr(uintptr(indices) + uintptr(cur_end) * uintptr(size_of(C.int))), rawptr(uintptr(indices) + uintptr(fut_beg) * uintptr(size_of(C.int))), C.size_t(count - fut_beg) * C.size_t(size_of(C.int)))
		count = cur_end + (count - fut_beg)
		fut_beg = cur_end
	}
	state.ranges_i.n = C.size_t(count)
	state.future_begin = fut_beg
}

@(export)
decor_redraw_line :: proc "c" (wp: rawptr, row: C.int, state_in: rawptr) {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	decor_state_pack_o(state)
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if state.row == -1 {
		decor_redraw_start(wp, row, state)
	} else if ([^]u8)(uintptr(state))[325] == 0 {
		marktree_itr_get(rawptr(uintptr(buf) + B_MARKTREE_OFF), C.int32_t(row), 0, rawptr(uintptr(state)))
		([^]u8)(uintptr(state))[325] = 1
	}
	state.row = row
	state.col_last = -1
	state.eol_col = -1
}

@(export)
decor_has_more_decorations :: proc "c" (state_in: rawptr, row: C.int) -> bool {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	if state.current_end != 0 || state.future_begin != C.int(state.ranges_i.n) {
		return true
	}
	k := marktree_itr_current(rawptr(uintptr(state)))
	return C.int(k.pos.row) >= 0 && C.int(k.pos.row) <= row
}

// C-static (dormant until decor_redraw_start/col_impl port — now live).
decor_range_add_from_inline_o :: proc "c" (state: ^DecorState_O, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int, decor: DecorInline_O, owned: bool, ns: u32, mark_id: u32) {
	context = runtime.default_context()
	d := decor
	if d.ext {
		vt := (^rawptr)(uintptr(&d.data[0]) + 8)^
		for vt != nil {
			decor_range_add_virt(state, start_row, start_col, end_row, end_col, vt, owned)
			vt = (^DecorVirtText_O)(vt).next
		}
		idx := (^u32)(&d.data[0])^
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			decor_range_add_sh(state, start_row, start_col, end_row, end_col, sh, owned, ns, mark_id, 0)
			idx = sh.next
		}
	} else {
		hl := DecorHighlightInline_O{
			flags = (^u16)(&d.data[0])^,
			priority = (^u16)(uintptr(&d.data[0]) + 2)^,
			hl_id = (^C.int)(uintptr(&d.data[0]) + 4)^,
			conceal_char = (^u32)(uintptr(&d.data[0]) + 8)^,
		}
		sh := decor_sh_from_inline(hl)
		decor_range_add_sh(state, start_row, start_col, end_row, end_col, &sh, owned, ns, mark_id, 0)
	}
}

// C-static (dormant until range_add ports — now live).
decor_range_insert_o :: proc "c" (state: ^DecorState_O, range_in: DecorRange_O) {
	context = runtime.default_context()
	rg := range_in
	ord := (^C.int)(uintptr(state) + 276)^
	rg.ordering = ord
	(^C.int)(uintptr(state) + 276)^ = ord + 1
	index: C.int
	free_i := (^C.int)(uintptr(state) + 272)^
	if free_i >= 0 {
		index = free_i
		slot := (^DecorRange_O)(uintptr(state.slots.items) + uintptr(index) * uintptr(size_of(DecorRange_O)))
		(^C.int)(uintptr(state) + 272)^ = (^C.int)(uintptr(slot))^
		slot^ = rg
	} else {
		index = dp_slots_push_o(state, rg)
	}
	row := rg.start_row
	col := rg.start_col
	count := C.int(state.ranges_i.n)
	indices := ([^]C.int)(state.ranges_i.items)
	slots := ([^]DecorRange_O)(rawptr(state.slots.items))
	begin := state.future_begin
	end := count
	for begin < end {
		mid := begin + ((end - begin) >> 1)
		mr := (^DecorRange_O)(uintptr(slots) + uintptr(indices[uintptr(mid)]) * uintptr(size_of(DecorRange_O)))
		mrow := mr.start_row
		mcol := mr.start_col
		if mrow < row || (mrow == row && mcol <= col) {
			begin = mid + 1
			if mrow == row && mcol == col {
				break
			}
		} else {
			end = mid
		}
	}
	_ = dp_ranges_push_o(state)
	indices2 := ([^]C.int)(state.ranges_i.items)
	libc.memmove(rawptr(uintptr(indices2) + uintptr(begin + 1) * uintptr(size_of(C.int))), rawptr(uintptr(indices2) + uintptr(begin) * uintptr(size_of(C.int))), C.size_t(count - begin) * C.size_t(size_of(C.int)))
	indices2[uintptr(begin)] = index
}

@(export)
decor_range_add_virt :: proc "c" (state_in: rawptr, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int, vt_in: rawptr, owned: bool) {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	vt := (^DecorVirtText_O)(vt_in)
	is_lines := (vt.flags & KVT_IS_LINES_O) != 0
	kind := u8(K_DECOR_VIRTTEXT_O)
	if is_lines {
		kind = u8(K_DECOR_VIRTLINES_O)
	}
	prio: u32 = u32(vt.prio) << 16
	range := DecorRange_O{
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
		prio_in = prio,
		owned = owned,
		kind = kind,
		vt = vt_in,
		attr_id = 0,
		draw_col = -10,
	}
	decor_range_insert_o(state, range)
}

@(export)
decor_range_add_sh :: proc "c" (state_in: rawptr, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int, sh_in: ^DecorSignHighlight_O, owned: bool, ns: u32, mark_id: u32, subpriority: u16) {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	if (sh_in.flags & KSH_IS_SIGN_O) != 0 {
		return
	}
	range := DecorRange_O{
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
		prio_in = (u32(sh_in.priority) << 16) + u32(subpriority),
		owned = owned,
		kind = u8(K_DECOR_HIGHLIGHT_O),
		attr_id = 0,
		draw_col = -10,
	}
	(^DecorSignHighlight_O)(uintptr(&range) + 32)^ = sh_in^
	if sh_in.hl_id != 0 || sh_in.url != nil || (sh_in.flags & (KSH_CONCEAL_OFF_O | KSH_CONCEAL_O | KSH_SPELL_ON_O | KSH_SPELL_OFF_O)) != 0 {
		if sh_in.hl_id != 0 {
			(^C.int)(uintptr(&range) + 88)^ = syn_id2attr_r(sh_in.hl_id)
		}
		decor_range_insert_o(state, range)
	}
	if (sh_in.flags & KSH_UI_WATCHED_O) != 0 {
		range.kind = u8(K_DECOR_UIWATCHED_O)
		(^u32)(uintptr(&range) + 32)^ = ns
		(^u32)(uintptr(&range) + 36)^ = mark_id
		(^C.int)(uintptr(&range) + 40)^ = C.int(K_VPOS_EOL_O) if (sh_in.flags & KSH_UI_WATCHED_OVERLAY_O) == 0 else C.int(K_VPOS_OVERLAY_O)
		decor_range_insert_o(state, range)
	}
}

// ── Batch D5: draw-column engine ─────────────────────────────────────────────

@(export)
decor_init_draw_col :: proc "c" (win_col: C.int, hidden: bool, item: ^DecorRange_O) {
	context = runtime.default_context()
	vt: ^DecorVirtText_O = nil
	if item.kind == u8(K_DECOR_VIRTTEXT_O) {
		vt = (^DecorVirtText_O)(item.vt)
	}
	pos := decor_virt_pos_kind(item)
	if win_col < 0 && pos != C.int(K_VPOS_INLINE_O) {
		item.draw_col = win_col
	} else if pos == C.int(K_VPOS_OVERLAY_O) {
		hide := vt != nil && (vt.flags & KVT_HIDE_O) != 0 && hidden
		item.draw_col = win_col if !hide else INT_MIN_O
	} else {
		item.draw_col = -1
	}
}

@(export)
decor_recheck_draw_col :: proc "c" (win_col: C.int, hidden: bool, state_in: rawptr) {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	end := state.current_end
	indices := ([^]C.int)(state.ranges_i.items)
	slots := ([^]DecorRange_O)(rawptr(state.slots.items))
	for i: C.int = 0; i < end; i += 1 {
		r := (^DecorRange_O)(uintptr(slots) + uintptr(indices[uintptr(i)]) * uintptr(size_of(DecorRange_O)))
		if r.draw_col == -3 {
			decor_init_draw_col(win_col, hidden, r)
		}
	}
}

@(export)
decor_redraw_col_impl :: proc "c" (wp: rawptr, col: C.int, win_col: C.int, hidden: bool, state_in: rawptr, max_col_last: C.int) -> C.int {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	row := state.row
	col_last := max_col_last
	for {
		mark := marktree_itr_current(rawptr(uintptr(state)))
		if C.int(mark.pos.row) < 0 || C.int(mark.pos.row) > row {
			break
		} else if C.int(mark.pos.row) == row && C.int(mark.pos.col) > col {
			col_last = min(col_last, C.int(mark.pos.col) - 1)
			break
		}
		if mt_invalid_o(mark) || mt_end_o(mark) || !mt_decor_any_o(mark) || !ns_in_win_e(mark.ns, wp) {
			marktree_itr_next(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(uintptr(state)))
			continue
		}
		endpos := marktree_get_altpos(rawptr(uintptr(buf) + B_MARKTREE_OFF), mark, nil)
		decor_range_add_from_inline_o(state, C.int(mark.pos.row), C.int(mark.pos.col), C.int(endpos.row), C.int(endpos.col), mt_decor_o(mark), false, u32(mark.ns), u32(mark.id))
		marktree_itr_next(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(uintptr(state)))
	}
	indices := ([^]C.int)(state.ranges_i.items)
	slots := ([^]DecorRange_O)(rawptr(state.slots.items))
	count := C.int(state.ranges_i.n)
	cur_end := state.current_end
	fut_beg := state.future_begin
	for fut_beg < count {
		index := indices[uintptr(fut_beg)]
		r := (^DecorRange_O)(uintptr(slots) + uintptr(index) * uintptr(size_of(DecorRange_O)))
		if r.start_row > row || (r.start_row == row && r.start_col > col) {
			break
		}
		ordering := r.ordering
		priority := r.prio_in
		begin := C.int(0)
		end := cur_end
		for begin < end {
			mid := begin + ((end - begin) >> 1)
			mi := indices[uintptr(mid)]
			mr := (^DecorRange_O)(uintptr(slots) + uintptr(mi) * uintptr(size_of(DecorRange_O)))
			if mr.prio_in < priority || (mr.prio_in == priority && mr.ordering < ordering) {
				begin = mid + 1
			} else {
				end = mid
			}
		}
		dst := ([^]C.int)(uintptr(indices) + uintptr(begin) * uintptr(size_of(C.int)))
		libc.memmove(rawptr(uintptr(dst) + uintptr(size_of(C.int))), rawptr(dst), C.size_t(cur_end - begin) * C.size_t(size_of(C.int)))
		dst[0] = index
		cur_end += 1
		fut_beg += 1
	}
	if fut_beg < count {
		r := (^DecorRange_O)(uintptr(slots) + uintptr(indices[uintptr(fut_beg)]) * uintptr(size_of(DecorRange_O)))
		if r.start_row == row {
			col_last = min(col_last, r.start_col - 1)
		}
	}
	new_cur_end: C.int = 0
	attr: C.int = 0
	conceal: C.int = 0
	conceal_char: u32 = 0
	conceal_attr: C.int = 0
	spell: C.int = C.int(TriState.kNone)
	for i: C.int = 0; i < cur_end; i += 1 {
		index := indices[uintptr(i)]
		slot := (^DecorRange_O)(uintptr(slots) + uintptr(index) * uintptr(size_of(DecorRange_O)))
		r := slot
		keep: bool
		if r.end_row < row || (r.end_row == row && r.end_col <= col) {
			keep = r.start_row >= row && decor_virt_pos(r)
		} else {
			keep = true
			if r.end_row == row && r.end_col > col {
				col_last = min(col_last, r.end_col - 1)
			}
			if r.attr_id > 0 {
				attr = hl_combine_attr_r(attr, r.attr_id)
			}
			if r.kind == u8(K_DECOR_HIGHLIGHT_O) && ((^DecorSignHighlight_O)(uintptr(r) + 32).flags & KSH_CONCEAL_O) != 0 {
				conceal = 1
				if r.start_row == row && r.start_col == col {
					sh := (^DecorSignHighlight_O)(uintptr(r) + 32)
					conceal = 2
					conceal_char = sh.text[0]
					col_last = min(col_last, r.start_col)
					conceal_attr = r.attr_id
				}
			}
			if r.kind == u8(K_DECOR_HIGHLIGHT_O) && ((^DecorSignHighlight_O)(uintptr(r) + 32).flags & KSH_CONCEAL_OFF_O) != 0 {
				conceal = 0
			}
			if r.kind == u8(K_DECOR_HIGHLIGHT_O) {
				shf := (^DecorSignHighlight_O)(uintptr(r) + 32).flags
				if (shf & KSH_SPELL_ON_O) != 0 {
					spell = C.int(TriState.kTrue)
				} else if (shf & KSH_SPELL_OFF_O) != 0 {
					spell = C.int(TriState.kFalse)
				}
				if (^DecorSignHighlight_O)(uintptr(r) + 32).url != nil {
					attr = hl_add_url_e(attr, (^DecorSignHighlight_O)(uintptr(r) + 32).url)
				}
			}
		}
		if r.start_row == row && r.start_col <= col && decor_virt_pos(r) && r.draw_col == -10 {
			decor_init_draw_col(win_col, hidden, r)
		}
		if keep {
			indices[uintptr(new_cur_end)] = index
			new_cur_end += 1
		} else {
			if r.owned {
				if r.kind == u8(K_DECOR_VIRTTEXT_O) {
					vt := (^DecorVirtText_O)(r.vt)
					clear_virttext((^Kvec_VT)(uintptr(vt) + 16))
					xfree(rawptr(vt))
				} else if r.kind == u8(K_DECOR_HIGHLIGHT_O) {
					xfree(rawptr((^DecorSignHighlight_O)(uintptr(r) + 32).url))
				}
			}
			fi := (^C.int)(uintptr(state) + 272)^
			(^C.int)(uintptr(slot))^ = fi
			(^C.int)(uintptr(state) + 272)^ = index
		}
	}
	cur_end = new_cur_end
	if fut_beg == count {
		fut_beg = cur_end
		count = cur_end
	}
	state.ranges_i.n = C.size_t(count)
	state.future_begin = fut_beg
	state.current_end = cur_end
	state.col_last = col_last
	state.current = attr
	state.conceal = conceal
	state.conceal_char = conceal_char
	state.conceal_attr = conceal_attr
	state.spell = spell
	return attr
}

// ── Batch D6: conceal + signs ────────────────────────────────────────────────
// MT_FLAG_DECOR_SIGNHL/CONCEAL_LINES_O live in extmark.odin — reuse directly.

@(private = "file")
conceal_filter_g: [5]u32 = {0, 0, 0, 0, u32(0xFFFFFFFF)} // [kMTMetaConcealLines]=Select
@(private = "file")
sign_filter_g: [5]u32 = {0, 0, u32(0xFFFFFFFF), u32(0xFFFFFFFF), 0} // SignHL+SignText

@(export)
decor_conceal_line :: proc "c" (wp: rawptr, row: C.int, check_cursor: bool) -> bool {
	context = runtime.default_context()
	if row < 0 || (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ < 2 || (!check_cursor && wp == curwin && row + 1 == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ && !conceal_cursor_line(wp)) {
		return false
	}
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if buf_meta_total_o(buf, KMTMETA_CONCEAL_LINES_O) == 0 {
		return decor_providers_invoke_conceal_line(wp, row)
	}
	itr: MarkTreeIter_O
	pair: MTPair_O
	marktree_itr_get_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), row, 0, rawptr(&itr))
	for marktree_itr_step_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), &pair) {
		if mt_conceal_lines_o(pair.start) && ns_in_win_e(pair.start.ns, wp) {
			return true
		}
	}
	marktree_itr_step_out_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), ([^]u32)(&conceal_filter_g[0]))
	for (^rawptr)(uintptr(&itr) + 16) != nil {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) > row {
			break
		}
		if mt_conceal_lines_o(mark) && ns_in_win_e(mark.ns, wp) {
			return true
		}
		marktree_itr_next_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), row + 1, 0, ([^]u32)(&conceal_filter_g[0]))
	}
	return decor_providers_invoke_conceal_line(wp, row)
}

// mt_conceal_lines inline (marktree.h:111).
mt_conceal_lines_o :: proc "c" (key: MTKey_O) -> bool {
	context = runtime.default_context()
	return (key.flags & MT_FLAG_DECOR_CONCEAL_LINES_O) != 0
}

// mt_decor_sign inline (marktree.h:106).
mt_decor_sign_o :: proc "c" (key: MTKey_O) -> bool {
	context = runtime.default_context()
	return (key.flags & (MT_FLAG_DECOR_SIGNTEXT_O | MT_FLAG_DECOR_SIGNHL_O)) != 0
}

@(export)
win_lines_concealed :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	return hasAnyFolding(wp) != 0 || (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ >= 2
}

@(export)
sign_item_cmp :: proc "c" (p1: rawptr, p2: rawptr) -> C.int {
	context = runtime.default_context()
	s1 := (^SignItem_O)(p1)
	s2 := (^SignItem_O)(p2)
	if s1.sh.priority != s2.sh.priority {
		return 1 if s1.sh.priority < s2.sh.priority else -1
	}
	if s1.id != s2.id {
		return 1 if s1.id < s2.id else -1
	}
	if s1.sh.sign_add_id != s2.sh.sign_add_id {
		return 1 if s1.sh.sign_add_id < s2.sh.sign_add_id else -1
	}
	return 0
}

@(export)
decor_redraw_signs :: proc "c" (wp: rawptr, buf: rawptr, row: C.int, sattrs_in: rawptr, line_id: ^C.int, cul_id: ^C.int, num_id: ^C.int) {
	context = runtime.default_context()
	if !buf_has_signs_e(buf) {
		return
	}
	sattrs := ([^]Wlv_SignTextAttrs)(sattrs_in)
	pair: MTPair_O
	num_text: C.int = 0
	itr: MarkTreeIter_O
	signs_n: C.size_t = 0
	signs_a: C.size_t = 0
	signs_items: [^]SignItem_O = nil
	marktree_itr_get_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), row, 0, rawptr(&itr))
	for marktree_itr_step_overlap(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), &pair) {
		if !mt_invalid_o(pair.start) && mt_decor_sign_o(pair.start) && ns_in_win_e(pair.start.ns, wp) {
			sh := decor_find_sign(mt_decor_o(pair.start))
			num_text += C.int(sh.text[0] != 0)
			if signs_n == signs_a {
				new_a: C.size_t = signs_a * 2
				if new_a < 8 {
					new_a = 8
				}
				signs_items = ([^]SignItem_O)(xrealloc(rawptr(signs_items), new_a * C.size_t(size_of(SignItem_O))))
				signs_a = new_a
			}
			signs_items[uintptr(signs_n)] = SignItem_O{sh = sh, id = C.int(pair.start.id)}
			signs_n += 1
		}
	}
	marktree_itr_step_out_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), ([^]u32)(&sign_filter_g[0]))
	for (^rawptr)(uintptr(&itr) + 16) != nil {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) != row {
			break
		}
		if !mt_invalid_o(mark) && !mt_end_o(mark) && mt_decor_sign_o(mark) && ns_in_win_e(mark.ns, wp) {
			sh := decor_find_sign(mt_decor_o(mark))
			num_text += C.int(sh.text[0] != 0)
			if signs_n == signs_a {
				new_a: C.size_t = signs_a * 2
				if new_a < 8 {
					new_a = 8
				}
				signs_items = ([^]SignItem_O)(xrealloc(rawptr(signs_items), new_a * C.size_t(size_of(SignItem_O))))
				signs_a = new_a
			}
			signs_items[uintptr(signs_n)] = SignItem_O{sh = sh, id = C.int(mark.id)}
			signs_n += 1
		}
		marktree_itr_next_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), row + 1, 0, ([^]u32)(&sign_filter_g[0]))
	}
	if signs_n > 0 {
		width := (^C.int)(uintptr(wp) + W_SCWIDTH_OFF_O)^
		if (^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ == SCL_NUM_O {
			width = 1
		}
		length := min(width, num_text)
		idx: C.int = 0
		qsort_e(rawptr(signs_items), signs_n, C.size_t(size_of(SignItem_O)), sign_item_cmp)
		for i: C.size_t = 0; i < signs_n; i += 1 {
			sh := signs_items[uintptr(i)].sh
			if sattrs != nil && idx < length && sh.text[0] != 0 {
				sattrs[uintptr(idx)].text[0] = sh.text[0]
				sattrs[uintptr(idx)].text[1] = sh.text[1]
				sattrs[uintptr(idx)].hl_id = sh.hl_id
				idx += 1
			}
			if num_id != nil && num_id^ <= 0 {
				num_id^ = sh.number_hl_id
			}
			if line_id != nil && line_id^ <= 0 {
				line_id^ = sh.line_hl_id
			}
			if cul_id != nil && cul_id^ <= 0 {
				cul_id^ = sh.cursorline_hl_id
			}
		}
		xfree(rawptr(signs_items))
	}
}

@(export)
decor_find_sign :: proc "c" (decor: DecorInline_O) -> ^DecorSignHighlight_O {
	context = runtime.default_context()
	d := decor
	if !d.ext {
		return nil
	}
	decor_id := (^u32)(&d.data[0])^
	for {
		if decor_id == DECOR_ID_INVALID_O {
			return nil
		}
		sh := &([^]DecorSignHighlight_O)(decor_items.items)[decor_id]
		if (sh.flags & KSH_IS_SIGN_O) != 0 {
			return sh
		}
		decor_id = sh.next
	}
}

// ── Batch D7: eol/virt/dict (last) ───────────────────────────────────────────

@(export)
decor_redraw_end :: proc "c" (state_in: rawptr) {
	context = runtime.default_context()
	(^rawptr)(uintptr(state_in) + 280)^ = nil
}

@(export)
decor_redraw_eol :: proc "c" (wp: rawptr, state_in: rawptr, eol_attr: ^C.int, eol_col: C.int) -> bool {
	context = runtime.default_context()
	state := (^DecorState_O)(state_in)
	decor_redraw_col_impl(wp, MAXCOL, MAXCOL, false, state_in, MAXCOL)
	state.eol_col = eol_col
	count := state.current_end
	indices := ([^]C.int)(state.ranges_i.items)
	slots := ([^]DecorRange_O)(rawptr(state.slots.items))
	has_virt_pos := false
	for i: C.int = 0; i < count; i += 1 {
		r := (^DecorRange_O)(uintptr(slots) + uintptr(indices[uintptr(i)]) * uintptr(size_of(DecorRange_O)))
		has_virt_pos = has_virt_pos || (r.start_row == state.row && decor_virt_pos(r))
		if r.kind == u8(K_DECOR_HIGHLIGHT_O) && ((^DecorSignHighlight_O)(uintptr(r) + 32).flags & KSH_HL_EOL_O) != 0 {
			eol_attr^ = hl_combine_attr_r(eol_attr^, r.attr_id)
		}
	}
	return has_virt_pos
}

// decor_virt_line_wrap inline (decoration.c:1127).
decor_virt_line_wrap_o :: proc "c" (wp: rawptr, overflow: C.int) -> bool {
	context = runtime.default_context()
	return overflow == C.int(KVL_OVERFLOW_WRAP_O) || (overflow == C.int(KVL_OVERFLOW_AUTO_O) && (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0)
}

@(export)
decor_virt_line_rows :: proc "c" (wp: rawptr, vl_in: rawptr, target_row: C.int, skip_cells: ^C.int) -> C.int {
	context = runtime.default_context()
	vl := (^VirtLine_O)(vl_in)
	if skip_cells != nil {
		skip_cells^ = 0
	}
	if !decor_virt_line_wrap_o(wp, vl.overflow) {
		return 1
	}
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	row_width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - (0 if (vl.flags & C.int(K_VL_LEFTCOL_O)) != 0 else win_col_off(wp))
	if row_width <= 0 {
		return 1
	}
	vt := vl.line
	vcol: C.int = 0
	row_cells: C.int = 0
	row: C.int = 0
	for i: C.size_t = 0; i < vt.n; i += 1 {
		virt_str := ([^]VirtTextChunk)(vt.items)[i].text
		if virt_str == nil {
			continue
		}
		p := ([^]u8)(virt_str)
		for p[0] != 0 {
			bytes_to_next := utfc_ptr2len(transmute(cstring)(virt_str))
			cells: C.int
			if p[0] == 9 {
				cells = tabstop_padding(vcol, (^i64)(uintptr(buf) + B_P_TS_OFF)^, transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
			} else {
				cells = utf_ptr2cells_r(transmute(cstring)(virt_str))
			}
			virt_str = (^u8)(uintptr(virt_str) + uintptr(bytes_to_next))
			p = ([^]u8)(virt_str)
			if row_cells + cells > row_width {
				row += 1
				if skip_cells != nil && row == target_row {
					skip_cells^ = vcol
				}
				row_cells = 0
			}
			row_cells += cells
			vcol += cells
		}
	}
	return row + 1
}

@(export)
decor_virt_lines :: proc "c" (wp: rawptr, start_row: C.int, end_row: C.int, num_below: ^C.int, lines_in: rawptr, apply_folds: bool) -> C.int {
	context = runtime.default_context()
	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	if buf_meta_total_o(buf, K_MTMETA_LINES_O) == 0 {
		return 0
	}
	itr: MarkTreeIter_O
	if !marktree_itr_get_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), max(start_row - 1, 0), 0, end_row, 0, ([^]u32)(&lines_filter_g[0]), rawptr(&itr)) {
		return 0
	}
	if start_row < 0 {
		libc.abort()
	}
	n_virt_lines: C.int = 0
	for {
		mark := marktree_itr_current(rawptr(&itr))
		vt: rawptr = nil
		if (mark.flags & MT_FLAG_DECOR_EXT_O) != 0 {
			vt = (^rawptr)(uintptr(&mark.decor[0]) + 8)^
		}
		if !mt_invalid_o(mark) && ns_in_win_e(mark.ns, wp) {
			for vt != nil {
				v := (^DecorVirtText_O)(vt)
				virt_lines := (^Kvec_VL)(uintptr(v) + 16)
				if (v.flags & KVT_IS_LINES_O) != 0 && virt_lines.n > 0 {
					above := (v.flags & KVT_LINES_ABOVE_O) != 0
					mrow := C.int(mark.pos.row)
					draw_row := mrow + (0 if above else 1)
					if draw_row >= start_row && draw_row < end_row && (!apply_folds || !(hasFolding(wp, mrow + 1, nil, nil) || decor_conceal_line(wp, mrow, false))) {
						if decor_virt_line_wrap_o(wp, ([^]VirtLine_O)(virt_lines.items)[0].overflow) {
							for i: C.size_t = 0; i < virt_lines.n; i += 1 {
								rows := decor_virt_line_rows(wp, rawptr(uintptr(virt_lines.items) + uintptr(i) * uintptr(size_of(VirtLine_O))), 0, nil)
								n_virt_lines += rows
								if num_below != nil && !above {
									num_below^ += rows
								}
							}
						} else {
							n_virt_lines += C.int(virt_lines.n)
							if num_below != nil && !above {
								num_below^ += C.int(virt_lines.n)
							}
						}
						if lines_in != nil {
							kv_splice_vl_o((^Kvec_VL)(lines_in), virt_lines)
						}
					}
				}
				vt = v.next
			}
		}
		if !marktree_itr_next_filter(rawptr(uintptr(buf) + B_MARKTREE_OFF), rawptr(&itr), end_row, 0, ([^]u32)(&lines_filter_g[0])) {
			break
		}
	}
	return n_virt_lines
}

// kv_splice append for VirtLines kvecs.
kv_splice_vl_o :: proc "c" (dst: ^Kvec_VL, src: ^Kvec_VL) {
	context = runtime.default_context()
	if src.n == 0 {
		return
	}
	need := dst.n + src.n
	if need > dst.a {
		new_a := dst.a * 2
		if new_a < need {
			new_a = need
		}
		dst.items = ([^]VirtLine_O)(xrealloc(rawptr(dst.items), new_a * C.size_t(size_of(VirtLine_O))))
		dst.a = new_a
	}
	libc.memcpy(rawptr(uintptr(dst.items) + uintptr(dst.n) * uintptr(size_of(VirtLine_O))), rawptr(src.items), src.n * C.size_t(size_of(VirtLine_O)))
	dst.n = need
}
// CSTR_TO_ARENA_OBJ helper (api/private/helpers.h macro).
cstr_to_arena_obj_o :: proc "c" (arena: rawptr, s: ^u8) -> Api_Object {
	context = runtime.default_context()
	n := C.size_t(libc.strlen(transmute(cstring)(s)))
	mem := ([^]u8)(arena_alloc(arena, n + 1, false))
	libc.memcpy(rawptr(mem), s, n)
	mem[n] = 0
	obj := Api_Object{t = kObjectTypeString_S}
	ns := NvimString{data = transmute(cstring)(mem), size = C.size_t(n)}
	(^NvimString)(uintptr(&obj) + OBJ_DATA_OFF)^ = ns
	return obj
}

@(export)
decor_to_dict_legacy :: proc "c" (dict: ^Api_Dict, decor_in: DecorInline_O, hl_name: bool, arena: rawptr) {
	context = runtime.default_context()
	d := decor_in
	sh_hl := DecorSignHighlight_O{priority = DECOR_PRIORITY_BASE_O}
	sh_sign := DecorSignHighlight_O{priority = DECOR_PRIORITY_BASE_O}
	virt_text: rawptr = nil
	virt_lines: rawptr = nil
	priority: C.int = -1
	if d.ext {
		vt := (^rawptr)(uintptr(&d.data[0]) + 8)^
		for vt != nil {
			v := (^DecorVirtText_O)(vt)
			if (v.flags & KVT_IS_LINES_O) != 0 {
				virt_lines = vt
			} else {
				virt_text = vt
			}
			vt = v.next
		}
		idx := (^u32)(&d.data[0])^
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			if (sh.flags & KSH_IS_SIGN_O) != 0 {
				sh_sign = sh^
			} else {
				sh_hl = sh^
			}
			idx = sh.next
		}
	} else {
		hl := DecorHighlightInline_O{
			flags = (^u16)(&d.data[0])^,
			priority = (^u16)(uintptr(&d.data[0]) + 2)^,
			hl_id = (^C.int)(uintptr(&d.data[0]) + 4)^,
			conceal_char = (^u32)(uintptr(&d.data[0]) + 8)^,
		}
		sh_hl = decor_sh_from_inline(hl)
	}
	if sh_hl.hl_id != 0 {
		dict_put_obj_o(dict, cstring("hl_group"), hl_group_name(sh_hl.hl_id, hl_name))
		dict_put_obj_o(dict, cstring("hl_eol"), bool_obj_bu_o((sh_hl.flags & KSH_HL_EOL_O) != 0))
		priority = C.int(sh_hl.priority)
	}
	if (sh_hl.flags & KSH_CONCEAL_OFF_O) != 0 {
		dict_put_obj_o(dict, cstring("conceal"), bool_obj_bu_o(false))
	} else if (sh_hl.flags & KSH_CONCEAL_O) != 0 {
		buf: [32]u8
		schar_get(&buf[0], sh_hl.text[0])
		dict_put_obj_o(dict, cstring("conceal"), cstr_to_arena_obj_o(arena, &buf[0]))
	}
	if (sh_hl.flags & KSH_CONCEAL_LINES_O) != 0 {
		dict_put_obj_o(dict, cstring("conceal_lines"), CSTR_AS_OBJ(transmute(^u8)(cstring(""))))
	}
	if (sh_hl.flags & KSH_SPELL_ON_O) != 0 {
		dict_put_obj_o(dict, cstring("spell"), bool_obj_bu_o(true))
	} else if (sh_hl.flags & KSH_SPELL_OFF_O) != 0 {
		dict_put_obj_o(dict, cstring("spell"), bool_obj_bu_o(false))
	}
	if (sh_hl.flags & KSH_UI_WATCHED_O) != 0 {
		dict_put_obj_o(dict, cstring("ui_watched"), bool_obj_bu_o(true))
	}
	if sh_hl.url != nil {
		dict_put_obj_o(dict, cstring("url"), CSTR_AS_OBJ(transmute(^u8)(sh_hl.url)))
	}
	if virt_text != nil {
		vt := (^DecorVirtText_O)(virt_text)
		if vt.hl_mode != 0 {
			dict_put_obj_o(dict, cstring("hl_mode"), CSTR_AS_OBJ(transmute(^u8)(hl_mode_str_g[vt.hl_mode])))
		}
		chunks := virt_text_to_array_e((^Kvec_VT)(uintptr(vt) + 16)^, hl_name, arena)
		dict_put_obj_o(dict, cstring("virt_text"), array_obj_o(chunks))
		dict_put_obj_o(dict, cstring("virt_text_hide"), bool_obj_bu_o((vt.flags & KVT_HIDE_O) != 0))
		dict_put_obj_o(dict, cstring("virt_text_repeat_linebreak"), bool_obj_bu_o((vt.flags & KVT_REPEAT_LINEBREAK_O) != 0))
		if vt.pos == C.int(K_VPOS_WINCOL_O) {
			dict_put_obj_o(dict, cstring("virt_text_win_col"), int_obj_o(vt.col))
		}
		dict_put_obj_o(dict, cstring("virt_text_pos"), CSTR_AS_OBJ(transmute(^u8)(virt_text_pos_str_g[vt.pos])))
		priority = C.int(vt.prio)
	}
	if virt_lines != nil {
		vl := (^DecorVirtText_O)(virt_lines)
		vl_data := (^Kvec_VL)(uintptr(vl) + 16)
		all_chunks := arena_array_e(arena, C.size_t(vl_data.n))
		vl_flags: C.int = 0
		vl_overflow: C.int = C.int(KVL_OVERFLOW_TRUNC_O)
		for i: C.size_t = 0; i < vl_data.n; i += 1 {
			vl_flags = ([^]VirtLine_O)(vl_data.items)[i].flags
			vl_overflow = ([^]VirtLine_O)(vl_data.items)[i].overflow
			chunks := virt_text_to_array_e(([^]VirtLine_O)(vl_data.items)[i].line, hl_name, arena)
			([^]Api_Object)(all_chunks.items)[uintptr(all_chunks.size)] = array_obj_o(chunks)
			all_chunks.size += 1
		}
		dict_put_obj_o(dict, cstring("virt_lines"), array_obj_o(all_chunks))
		dict_put_obj_o(dict, cstring("virt_lines_above"), bool_obj_bu_o((vl.flags & KVT_LINES_ABOVE_O) != 0))
		dict_put_obj_o(dict, cstring("virt_lines_leftcol"), bool_obj_bu_o((vl_flags & C.int(K_VL_LEFTCOL_O)) != 0))
		overflow := cstring("trunc")
		if vl_overflow == C.int(KVL_OVERFLOW_SCROLL_O) {
			overflow = cstring("scroll")
		} else if vl_overflow == C.int(KVL_OVERFLOW_WRAP_O) {
			overflow = cstring("wrap")
		} else if vl_overflow == C.int(KVL_OVERFLOW_AUTO_O) {
			overflow = cstring("auto")
		}
		dict_put_obj_o(dict, cstring("virt_lines_overflow"), CSTR_AS_OBJ(transmute(^u8)(overflow)))
		priority = C.int(vl.prio)
	}
	if (sh_sign.flags & KSH_IS_SIGN_O) != 0 {
		if sh_sign.text[0] != 0 {
			buf: [64]u8
			describe_sign_text_e(&buf[0], &sh_sign.text[0])
			dict_put_obj_o(dict, cstring("sign_text"), cstr_to_arena_obj_o(arena, &buf[0]))
		}
		if sh_sign.sign_name != nil {
			dict_put_obj_o(dict, cstring("sign_name"), CSTR_AS_OBJ(sh_sign.sign_name))
		}
		if sh_sign.hl_id != 0 {
			dict_put_obj_o(dict, cstring("sign_hl_group"), hl_group_name(sh_sign.hl_id, hl_name))
		}
		if sh_sign.number_hl_id != 0 {
			dict_put_obj_o(dict, cstring("number_hl_group"), hl_group_name(sh_sign.number_hl_id, hl_name))
		}
		if sh_sign.line_hl_id != 0 {
			dict_put_obj_o(dict, cstring("line_hl_group"), hl_group_name(sh_sign.line_hl_id, hl_name))
		}
		if sh_sign.cursorline_hl_id != 0 {
			dict_put_obj_o(dict, cstring("cursorline_hl_group"), hl_group_name(sh_sign.cursorline_hl_id, hl_name))
		}
		priority = C.int(sh_sign.priority)
	}
	if priority != -1 {
		dict_put_obj_o(dict, cstring("priority"), int_obj_o(priority))
	}
}

@(export)
decor_type_flags :: proc "c" (decor_in: DecorInline_O) -> u16 {
	context = runtime.default_context()
	d := decor_in
	if d.ext {
		type_flags: u16 = u16(KEXTMARK_NONE_O)
		vt := (^rawptr)(uintptr(&d.data[0]) + 8)^
		for vt != nil {
			v := (^DecorVirtText_O)(vt)
			if (v.flags & KVT_IS_LINES_O) != 0 {
				type_flags |= u16(KEXTMARK_VIRTLINES_O)
			} else {
				type_flags |= u16(KEXTMARK_VIRTTEXT_O)
			}
			vt = v.next
		}
		idx := (^u32)(&d.data[0])^
		for idx != DECOR_ID_INVALID_O {
			sh := &([^]DecorSignHighlight_O)(decor_items.items)[idx]
			if (sh.flags & KSH_IS_SIGN_O) != 0 {
				type_flags |= u16(KEXTMARK_SIGN_O)
			} else {
				type_flags |= u16(KEXTMARK_HIGHLIGHT_O)
			}
			idx = sh.next
		}
		return type_flags
	}
	hl_flags := (^u16)(&d.data[0])^
	if (hl_flags & KSH_IS_SIGN_O) != 0 {
		return u16(KEXTMARK_SIGN_O)
	}
	return u16(KEXTMARK_HIGHLIGHT_O)
}

@(export)
hl_group_name :: proc "c" (hl_id: C.int, hl_name: bool) -> Api_Object {
	context = runtime.default_context()
	if hl_name {
		return CSTR_AS_OBJ(transmute(^u8)(syn_id2name_e(hl_id)))
	}
	return int_obj_o(hl_id)
}
