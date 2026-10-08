package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// extmark.c port: extended marks over the (C-resident) MarkTree.
// Publics are @(export); setraw/push_mark are _o dormant plains.
// marktree.c + decoration.c + api/extmark.c stay C (FFI below).

foreign _ {
	// marktree_* now defined in marktree.odin — call directly.
	// buf_decor_remove/buf_put_decor/decor_redraw now defined in
	// decoration.odin — call directly.
	@(link_name = "decor_state_invalidate")
	decor_state_invalidate_e :: proc "c" (buf: rawptr) ---
	@(link_name = "decor_type_flags")
	decor_type_flags_e :: proc "c" (decor: DecorInline_O) -> u16 ---
	@(link_name = "curbuf_splice_pending")
	curbuf_splice_pending_g: C.int
}

MT_FLAG_REAL_O :: u16(0x01)
MT_FLAG_PAIRED_O :: u16(0x04)
MT_FLAG_ORPHANED_O :: u16(0x08)
MT_FLAG_NO_UNDO_O :: u16(0x10)
MT_FLAG_INVALIDATE_O :: u16(0x20)
MT_FLAG_DECOR_HL_O :: u16(0x100)
MT_FLAG_DECOR_SIGNTEXT_O :: u16(0x200)
MT_FLAG_DECOR_SIGNHL_O :: u16(0x400)
MT_FLAG_DECOR_VIRT_LINES_O :: u16(0x800)
MT_FLAG_DECOR_VIRT_TEXT_INLINE_O :: u16(0x1000)
MT_FLAG_DECOR_CONCEAL_LINES_O :: u16(0x2000)
MT_FLAG_LAST_O :: u16(0x8000)
MT_FLAG_DECOR_MASK_O :: u16(0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x1000)
MT_FLAG_EXTERNAL_MASK_O :: u16(u16(0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x1000) | 0x10 | 0x20 | 0x40 | 0x2000)

KEXTMARK_SAVE_POS_O :: 3
KEXTMARK_NONE_O :: 1

B_EXTMARK_NS_OFF :: 12608
B_PREV_LINE_COUNT_OFF :: 12656
B_ML_CHUNKSIZE_OFF :: 104
B_SIGNCOLS_COUNT_SIZE :: 36

MARKTREE_NODE_KEY_OFF :: 72

// DecorInline mirror (cc-probed, 24B: ext@0, data@8).
DecorInline_O :: struct {
	ext:  bool,
	_pad: [7]u8,
	data: [16]u8,
}
#assert(size_of(DecorInline_O) == 24)

// MTPair mirror (cc-probed, 56B: start@0, end_pos@40, erg@48).
MTPair_O :: struct {
	start:              MTKey_O,
	end_pos:            MTPos_O,
	end_right_gravity:  bool,
	_pad:               [7]u8,
}
#assert(size_of(MTPair_O) == 56)

// MarkTreeIter mirror (cc-probed, 216B: lvl@8, x@16, i@24, s@28, iidx@192).
MarkTreeIter_Step_O :: struct {
	oldcol: C.int,
	i:      C.int,
}
MarkTreeIter_O :: struct {
	pos:           MTPos_O,
	lvl:           C.int,
	x:             rawptr,
	i:             C.int,
	s:             [20]MarkTreeIter_Step_O,
	_pad:          [4]u8,
	intersect_idx: C.size_t,
	intersect_pos: MTPos_O,
	intersect_pos_x: MTPos_O,
}
#assert(size_of(MarkTreeIter_O) == 216)

// ExtmarkSavePos mirror (cc-probed, 24B).
ExtmarkSavePos_O :: struct {
	mark:        u64,
	old_row:     C.int,
	old_col:     C.int,
	invalidated: bool,
	_pad:        [7]u8,
}
#assert(size_of(ExtmarkSavePos_O) == 24)

// ExtmarkInfoArray: kvec of MTPair.
ExtmarkInfoArray_O :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: ^MTPair_O,
}

mt_flags_o :: proc "c" (right_gravity: bool, no_undo: bool, invalidate: bool, decor_ext: bool) -> u16 {
	context = runtime.default_context()
	r: u16 = 0
	if right_gravity {
		r |= u16(0x4000)
	}
	if no_undo {
		r |= MT_FLAG_NO_UNDO_O
	}
	if invalidate {
		r |= MT_FLAG_INVALIDATE_O
	}
	if decor_ext {
		r |= u16(0x80)
	}
	return r
}

mt_paired_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & MT_FLAG_PAIRED_O) != 0
}

mt_end_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & u16(0x02)) != 0
}

mt_right_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & u16(0x4000)) != 0
}

mt_no_undo_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & MT_FLAG_NO_UNDO_O) != 0
}

mt_invalidate_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & MT_FLAG_INVALIDATE_O) != 0
}

mt_invalid_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & MT_FLAG_INVALID_O) != 0
}

mt_decor_any_o :: proc "c" (key: MTKey_O) -> bool {
	return (key.flags & MT_FLAG_DECOR_MASK_O) != 0
}

mt_lookup_key_o :: proc "c" (key: MTKey_O) -> u64 {
	endbit: u64 = 0
	if mt_end_o(key) {
		endbit = 1
	}
	return (u64(key.ns) << 33) | (u64(key.id) << 1) | endbit
}

mt_decor_o :: proc "c" (key: MTKey_O) -> DecorInline_O {
	d := DecorInline_O{}
	if (key.flags & u16(0x80)) != 0 {
		d.ext = true
	}
	d.data = key.decor
	return d
}

mtpair_from_o :: proc "c" (start: MTKey_O, end: MTKey_O) -> MTPair_O {
	p := MTPair_O{}
	p.start = start
	p.end_pos = end.pos
	p.end_right_gravity = mt_right_o(end)
	return p
}

marktree_itr_valid_o :: proc "c" (itr: ^MarkTreeIter_O) -> bool {
	context = runtime.default_context()
	return itr.x != nil
}

// Raw key slot for in-place flag/decor revision (mt_itr_rawkey).
mt_itr_rawkey_o :: proc "c" (itr: ^MarkTreeIter_O) -> ^MTKey_O {
	context = runtime.default_context()
	return (^MTKey_O)(uintptr(itr.x) + uintptr(MARKTREE_NODE_KEY_OFF) + uintptr(itr.i) * 40)
}

kv_push_mtpair_o :: proc "c" (kv: ^ExtmarkInfoArray_O, v: MTPair_O) {
	context = runtime.default_context()
	if kv.n == kv.a {
		newa: C.size_t = kv.a == 0 ? C.size_t(4) : kv.a * 2
		items := transmute(^MTPair_O)(xrealloc(kv.items, newa * size_of(MTPair_O)))
		kv.items = items
		kv.a = newa
	}
	(^MTPair_O)(uintptr(kv.items) + uintptr(kv.n) * size_of(MTPair_O))^ = v
	kv.n += 1
}

// Create or update an extmark (must not be used during iteration!).
@(export)
extmark_set :: proc "c" (buf: rawptr, ns_id: u32, idp: ^u32, row: C.int, col: C.int, end_row: C.int, end_col: C.int, decor: DecorInline_O, decor_flags: u16, right_gravity: bool, end_right_gravity: bool, no_undo: bool, invalidate: bool, err: rawptr) {
	context = runtime.default_context()
	nsmap := (^Map_uint32_t_uint32_t)(uintptr(buf) + uintptr(B_EXTMARK_NS_OFF))
	ns := map_put_ref_uint32_t_uint32_t(nsmap, ns_id, nil, nil)
	id: u32 = 0
	if idp != nil {
		id = idp^
	}
	flags := mt_flags_o(right_gravity, no_undo, invalidate, decor.ext) | decor_flags
	revised := false
	if id == 0 {
		ns^ += 1
		id = ns^
	} else {
		itr := MarkTreeIter_O{}
		old_mark := marktree_lookup_ns(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), ns_id, id, false, rawptr(&itr))
		if old_mark.id != 0 {
			if mt_paired_o(old_mark) || end_row > -1 {
				extmark_del_id(buf, ns_id, id)
			} else {
				if itr.x == nil {
					libc.abort()
				}
				if C.int(old_mark.pos.row) == row && C.int(old_mark.pos.col) == col {
					if !mt_invalid_o(old_mark) && mt_decor_any_o(old_mark) {
						rk := mt_itr_rawkey_o(&itr)
						rk.flags &= ~MT_FLAG_EXTERNAL_MASK_O
						buf_decor_remove(buf, row, row, col, mt_decor_o(old_mark), true)
					}
					rk := mt_itr_rawkey_o(&itr)
					rk.flags |= flags
					rk.decor = decor.data
					marktree_revise_meta(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), old_mark)
					revised = true
				} else {
					marktree_del_itr(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), false)
					if !mt_invalid_o(old_mark) {
						buf_decor_remove(buf, C.int(old_mark.pos.row), C.int(old_mark.pos.row), C.int(old_mark.pos.col), mt_decor_o(old_mark), true)
					}
				}
			}
		} else {
			if id > ns^ {
				ns^ = id
			}
		}
	}
	if !revised {
		mark := MTKey_O{}
		mark.pos = MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}
		mark.ns = ns_id
		mark.id = id
		mark.flags = flags
		mark.decor = decor.data
		marktree_put(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), mark, end_row, end_col, end_right_gravity)
		decor_state_invalidate_e(buf)
	}
	if decor_flags != 0 || decor.ext {
		erow := row
		if end_row > -1 {
			erow = end_row
		}
		buf_put_decor(buf, decor, row, erow)
		decor_redraw(buf, row, erow, col, decor)
	}
	if idp != nil {
		idp^ = id
	}
}

extmark_setraw_o :: proc "c" (buf: rawptr, mark_id: u64, row: C.int, col: C.int, invalid: bool) {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	key := marktree_lookup(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), mark_id, rawptr(&itr))
	move := C.int(key.pos.row) != row || C.int(key.pos.col) != col
	if C.int(key.pos.row) < 0 || (!move && !invalid) {
		return
	}
	if !invalid && mt_decor_any_o(key) && C.int(key.pos.row) != row {
		decor_redraw(buf, C.int(key.pos.row), C.int(key.pos.row), C.int(key.pos.col), mt_decor_o(key))
	}
	row1: C.int = 0
	row2: C.int = 0
	altitr := itr
	alt := marktree_get_alt(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), key, rawptr(&altitr))
	if invalid {
		rk := mt_itr_rawkey_o(&itr)
		rk.flags &= ~u16(MT_FLAG_INVALID_O)
		arka := mt_itr_rawkey_o(&altitr)
		arka.flags &= ~u16(MT_FLAG_INVALID_O)
		if mt_end_o(key) {
			marktree_revise_meta(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&altitr), alt)
		} else {
			marktree_revise_meta(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), key)
		}
	} else if !mt_invalid_o(key) && (key.flags & MT_FLAG_DECOR_SIGNTEXT_O) != 0 && (^bool)(uintptr(buf) + uintptr(B_SIGNCOLS_AUTOM_OFF))^ {
		row1 = min(C.int(alt.pos.row), min(C.int(key.pos.row), row))
		row2 = max(C.int(alt.pos.row), max(C.int(key.pos.row), row))
		buf_signcols_count_range(buf, row1, min((^C.int)(uintptr(curbuf) + uintptr(B_ML_LINE_COUNT_OFF))^ - 1, row2), 0, C.int(TriState.kTrue))
	}
	if move {
		marktree_move(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), row, col)
	}
	if invalid {
		lo := min(row, C.int(alt.pos.row))
		hi := max(row, C.int(alt.pos.row))
		buf_put_decor(buf, mt_decor_o(key), lo, hi)
	} else if !mt_invalid_o(key) && (key.flags & MT_FLAG_DECOR_SIGNTEXT_O) != 0 && (^bool)(uintptr(buf) + uintptr(B_SIGNCOLS_AUTOM_OFF))^ {
		buf_signcols_count_range(buf, row1, min((^C.int)(uintptr(curbuf) + uintptr(B_ML_LINE_COUNT_OFF))^ - 1, row2), 0, C.int(TriState.kNone))
	}
}

// Remove an extmark in "ns_id" by "id". Returns false on missing id.
@(export)
extmark_del_id :: proc "c" (buf: rawptr, ns_id: u32, id: u32) -> bool {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	key := marktree_lookup_ns(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), ns_id, id, false, rawptr(&itr))
	if key.id != 0 {
		extmark_del(buf, rawptr(&itr), key, false)
	}
	return key.id > 0
}

// Remove a (paired) extmark "key" pointed to by "itr".
@(export)
extmark_del :: proc "c" (buf: rawptr, itr_raw: rawptr, key: MTKey_O, restore: bool) {
	context = runtime.default_context()
	if C.int(key.pos.row) < 0 {
		libc.abort()
	}
	key2 := key
	other := marktree_del_itr(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), itr_raw, false)
	if other != 0 {
		key2 = marktree_lookup(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), other, itr_raw)
		if C.int(key2.pos.row) < 0 {
			libc.abort()
		}
		marktree_del_itr(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), itr_raw, false)
		if restore {
			marktree_itr_get(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), key.pos.row, C.int(key.pos.col), itr_raw)
		}
	}
	if mt_decor_any_o(key) {
		if mt_invalid_o(key) {
			decor_free(mt_decor_o(key))
		} else {
			k1 := key
			k2 := key2
			// C swaps key/key2 first, so mt_decor reads the swapped key.
			dd := mt_decor_o(key)
			if mt_end_o(key) {
				k1 = key2
				k2 = key
				dd = mt_decor_o(key2)
			}
			buf_decor_remove(buf, C.int(k1.pos.row), C.int(k2.pos.row), C.int(k1.pos.col), dd, true)
		}
	}
	decor_state_invalidate_e(buf)
}

// Free extmarks in a ns between lines (ns = 0 clears all namespaces).
@(export)
extmark_clear :: proc "c" (buf: rawptr, ns_id: u32, l_row: C.int, l_col: C.int, u_row: C.int, u_col: C.int) -> bool {
	context = runtime.default_context()
	nsmap := (^Map_uint32_t_uint32_t)(uintptr(buf) + uintptr(B_EXTMARK_NS_OFF))
	if nsmap.set.h.n_keys == 0 {
		return false
	}
	all_ns := ns_id == 0
	if !all_ns {
		ns := map_ref_uint32_t_uint32_t(nsmap, ns_id, nil)
		if ns == nil {
			return false
		}
	}
	marks_cleared_any := false
	marks_cleared_all := l_row == 0 && l_col == 0
	itr := MarkTreeIter_O{}
	marktree_itr_get(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), C.int32_t(l_row), l_col, rawptr(&itr))
	for {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 || C.int(mark.pos.row) > u_row || (C.int(mark.pos.row) == u_row && C.int(mark.pos.col) > u_col) {
			if C.int(mark.pos.row) >= 0 {
				marks_cleared_all = false
			}
			break
		}
		if mark.ns == ns_id || all_ns {
			marks_cleared_any = true
			extmark_del(buf, rawptr(&itr), mark, true)
		} else {
			marktree_itr_next(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr))
		}
	}
	if marks_cleared_all {
		if all_ns {
			xfree(rawptr(nsmap.set.h.hash))
			xfree(rawptr(nsmap.set.keys))
			nsmap.set = Set_uint32_t{}
			xfree(rawptr(nsmap.values))
			nsmap.values = nil
		} else {
			map_del_uint32_t_uint32_t(nsmap, ns_id, nil)
		}
	}
	if marks_cleared_any {
		decor_state_invalidate_e(buf)
	}
	return marks_cleared_any
}

// Positions of marks between a range (start/end inclusive).
@(export)
extmark_get :: proc "c" (buf: rawptr, ns_id: u32, l_row: C.int, l_col: C.int, u_row: C.int, u_col: C.int, amount: i64, type_filter: C.int, overlap: bool) -> ExtmarkInfoArray_O {
	context = runtime.default_context()
	array := ExtmarkInfoArray_O{}
	itr := MarkTreeIter_O{}
	if overlap {
		if !marktree_itr_get_overlap(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), l_row, l_col, rawptr(&itr)) {
			return array
		}
		for i64(array.n) < amount {
			pair := MTPair_O{}
			if !marktree_itr_step_overlap(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), &pair) {
				break
			}
			push_mark_o(&array, ns_id, type_filter, pair)
		}
	} else {
		marktree_itr_get_ext(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), MTPos_O{row = C.int32_t(l_row), col = C.int32_t(l_col)}, rawptr(&itr), false, false, nil, nil)
	}
	for i64(array.n) < amount {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 || C.int(mark.pos.row) > u_row || (C.int(mark.pos.row) == u_row && C.int(mark.pos.col) > u_col) {
			break
		}
		if !mt_end_o(mark) {
			end := marktree_get_alt(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), mark, nil)
			push_mark_o(&array, ns_id, type_filter, mtpair_from_o(mark, end))
		}
		marktree_itr_next(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr))
	}
	return array
}

push_mark_o :: proc "c" (array: ^ExtmarkInfoArray_O, ns_id: u32, type_filter: C.int, mark: MTPair_O) {
	context = runtime.default_context()
	if !(ns_id == max(u32) || mark.start.ns == ns_id) {
		return
	}
	if type_filter != KEXTMARK_NONE_O {
		if !mt_decor_any_o(mark.start) {
			return
		}
		type_flags := decor_type_flags_e(mt_decor_o(mark.start))
		if (C.int(type_flags) & type_filter) == 0 {
			return
		}
	}
	kv_push_mtpair_o(array, mark)
}

// Lookup an extmark by id.
@(export)
extmark_from_id :: proc "c" (buf: rawptr, ns_id: u32, id: u32) -> MTPair_O {
	context = runtime.default_context()
	mark := marktree_lookup_ns(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), ns_id, id, false, nil)
	if mark.id == 0 {
		return mtpair_from_o(mark, mark)
	}
	if C.int(mark.pos.row) < 0 {
		libc.abort()
	}
	end := marktree_get_alt(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), mark, nil)
	return mtpair_from_o(mark, end)
}

// Free extmarks from the buffer.
@(export)
extmark_free_all :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	marktree_itr_get(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), 0, 0, rawptr(&itr))
	for {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 {
			break
		}
		if !(mt_paired_o(mark) && mt_end_o(mark)) {
			decor_free(mt_decor_o(mark))
		}
		marktree_itr_next(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr))
	}
	marktree_clear(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)))
	(^C.int)(uintptr(buf) + uintptr(B_SIGNCOLS_MAX_OFF))^ = 0
	libc.memset(rawptr(uintptr(buf) + uintptr(B_SIGNCOLS_COUNT_OFF)), 0, B_SIGNCOLS_COUNT_SIZE)
	nsmap := (^Map_uint32_t_uint32_t)(uintptr(buf) + uintptr(B_EXTMARK_NS_OFF))
	xfree(rawptr(nsmap.set.h.hash))
	xfree(rawptr(nsmap.set.keys))
	nsmap.set = Set_uint32_t{}
	xfree(rawptr(nsmap.values))
	nsmap.values = nil
}

// Invalidate extmarks between range and copy to undo header.
@(export)
extmark_splice_delete :: proc "c" (buf: rawptr, l_row: C.int, l_col: C.int, u_row: C.int, u_col: C.int, uvp: ^Kvec_XUndo, only_copy: bool, op: C.int) {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	marktree_itr_get(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), C.int32_t(l_row), l_col, rawptr(&itr))
	for {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 || C.int(mark.pos.row) > u_row {
			break
		}
		copy := true
		if C.int(mark.pos.row) == l_row && C.int(mark.pos.col) - (mt_right_o(mark) ? 0 : 1) < l_col {
			copy = false
		} else if C.int(mark.pos.row) == u_row {
			if C.int(mark.pos.col) > u_col + 1 {
				break
			} else if C.int(mark.pos.col) + (mt_right_o(mark) ? 1 : 0) > u_col {
				copy = false
			}
		}
		invalidated := false
		if !only_copy && !mt_invalid_o(mark) && mt_invalidate_o(mark) && !mt_end_o(mark) {
			enditr := itr
			endpos := marktree_get_altpos(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), mark, rawptr(&enditr))
			start_in := C.int(mark.pos.row) > l_row || (C.int(mark.pos.row) == l_row && C.int(mark.pos.col) >= l_col)
			end_in := C.int(endpos.row) < u_row || (C.int(endpos.row) == u_row && C.int(endpos.col) <= u_col)
			if (!mt_paired_o(mark) && C.int(mark.pos.row) < u_row) || (mt_paired_o(mark) && start_in && end_in) {
				if mt_no_undo_o(mark) {
					extmark_del(buf, rawptr(&itr), mark, true)
					continue
				} else {
					copy = true
					invalidated = true
					rk := mt_itr_rawkey_o(&itr)
					rk.flags |= MT_FLAG_INVALID_O
					erk := mt_itr_rawkey_o(&enditr)
					erk.flags |= MT_FLAG_INVALID_O
					marktree_revise_meta(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr), mark)
					buf_decor_remove(buf, C.int(mark.pos.row), C.int(endpos.row), C.int(mark.pos.col), mt_decor_o(mark), false)
				}
			}
		}
		if copy && (only_copy || (uvp != nil && op == kExtmarkUndo && !mt_no_undo_o(mark))) {
			pos := ExtmarkSavePos_O{}
			pos.mark = mt_lookup_key_o(mark)
			pos.invalidated = invalidated
			pos.old_row = C.int(mark.pos.row)
			pos.old_col = C.int(mark.pos.col)
			undo := ExtmarkUndoObject{}
			undo.type = KEXTMARK_SAVE_POS_O
			(^ExtmarkSavePos_O)(&undo.data[0])^ = pos
			kv_push_xundo(uvp, undo)
		}
		marktree_itr_next(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), rawptr(&itr))
	}
}

// Undo or redo an extmark operation.
@(export)
extmark_apply_undo :: proc "c" (undo_info: ExtmarkUndoObject, undo: bool) {
	context = runtime.default_context()
	u := undo_info
	if u.type == kExtmarkSplice_U {
		splice := (^Extmark_Splice)(&u.data[0])^
		if undo {
			extmark_splice_impl(curbuf, splice.start_row, splice.start_col, splice.start_byte, splice.new_row, splice.new_col, splice.new_byte, splice.old_row, splice.old_col, splice.old_byte, KEXTMARK_NO_UNDO_O)
		} else {
			extmark_splice_impl(curbuf, splice.start_row, splice.start_col, splice.start_byte, splice.old_row, splice.old_col, splice.old_byte, splice.new_row, splice.new_col, splice.new_byte, KEXTMARK_NO_UNDO_O)
		}
	} else if u.type == KEXTMARK_SAVE_POS_O {
		pos := (^ExtmarkSavePos_O)(&u.data[0])^
		if undo && pos.old_row >= 0 {
			extmark_setraw_o(curbuf, pos.mark, pos.old_row, pos.old_col, pos.invalidated)
		}
	} else if u.type == kExtmarkMove_U {
		move := (^Extmark_Move)(&u.data[0])^
		if undo {
			extmark_move_region(curbuf, move.new_row, move.new_col, move.new_byte, move.extent_row, move.extent_col, move.extent_byte, move.start_row, move.start_col, move.start_byte, KEXTMARK_NO_UNDO_O)
		} else {
			extmark_move_region(curbuf, move.start_row, move.start_col, move.start_byte, move.extent_row, move.extent_col, move.extent_byte, move.new_row, move.new_col, move.new_byte, KEXTMARK_NO_UNDO_O)
		}
	}
}

// Adjust extmark row for inserted/deleted rows (columns stay fixed).
@(export)
extmark_adjust :: proc "c" (buf: rawptr, line1: C.int, line2: C.int, amount: C.int, amount_after: C.int, op: C.int) {
	context = runtime.default_context()
	if curbuf_splice_pending_g != 0 {
		return
	}
	start_byte := ml_find_line_or_offset(buf, line1, nil, true)
	old_byte: i64 = 0
	new_byte: i64 = 0
	old_row: C.int
	new_row: C.int
	if amount == MAXLNUM {
		old_row = line2 - line1 + 1
		old_byte = i64((^C.size_t)(uintptr(buf) + uintptr(B_DELETED_BYTES2_OFF))^)
		new_row = amount_after + old_row
	} else {
		if line2 != MAXLNUM {
			libc.abort()
		}
		old_row = 0
		new_row = amount
	}
	if new_row > 0 {
		new_byte = i64(ml_find_line_or_offset(buf, line1 + new_row, nil, true) - start_byte)
	}
	extmark_splice_impl(buf, line1 - 1, 0, i64(start_byte), old_row, 0, old_byte, new_row, 0, new_byte, op)
}

// Adjust extmarks after a text edit (plus on_bytes event).
@(export)
extmark_splice :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, old_row: C.int, old_col: C.int, old_byte: i64, new_row: C.int, new_col: C.int, new_byte: i64, undo: C.int) {
	context = runtime.default_context()
	offset := ml_find_line_or_offset(buf, start_row + 1, nil, true)
	if offset < 0 && (^rawptr)(uintptr(buf) + uintptr(B_ML_CHUNKSIZE_OFF))^ == nil {
		offset = 0
	}
	extmark_splice_impl(buf, start_row, start_col, i64(offset) + i64(start_col), old_row, old_col, old_byte, new_row, new_col, new_byte, undo)
}

@(export)
extmark_splice_impl :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, start_byte: i64, old_row: C.int, old_col: C.int, old_byte: i64, new_row: C.int, new_col: C.int, new_byte: i64, undo: C.int) {
	context = runtime.default_context()
	(^C.size_t)(uintptr(buf) + uintptr(B_DELETED_BYTES2_OFF))^ = 0
	buf_updates_send_splice(buf, start_row, start_col, C.longlong(start_byte), old_row, old_col, C.longlong(old_byte), new_row, new_col, C.longlong(new_byte))
	if old_row > 0 || old_col > 0 {
		end_row := start_row + old_row
		end_col := old_col
		if old_row != 0 {
			end_col = 0
		} else {
			end_col = start_col + old_col
		}
		uhp := u_force_get_undo_header(buf)
		uvp: ^Kvec_XUndo = nil
		if uhp != nil {
			uvp = &uhp.uh_extmark
		}
		extmark_splice_delete(buf, start_row, start_col, end_row, end_col, uvp, false, undo)
	}
	if old_row > 0 || new_row > 0 {
		count := (^C.int)(uintptr(buf) + uintptr(B_PREV_LINE_COUNT_OFF))^
		if count <= 0 {
			count = (^C.int)(uintptr(buf) + uintptr(B_ML_LINE_COUNT_OFF))^
		}
		hi := count - 1
		if start_row + old_row < hi {
			hi = start_row + old_row
		}
		buf_signcols_count_range(buf, start_row, hi, 0, C.int(TriState.kTrue))
		(^C.int)(uintptr(buf) + uintptr(B_PREV_LINE_COUNT_OFF))^ = 0
	}
	marktree_splice(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), C.int32_t(start_row), start_col, old_row, old_col, new_row, new_col)
	if old_row > 0 || new_row > 0 {
		row2 := (^C.int)(uintptr(buf) + uintptr(B_ML_LINE_COUNT_OFF))^ - 1
		if start_row + new_row < row2 {
			row2 = start_row + new_row
		}
		buf_signcols_count_range(buf, start_row, row2, 0, C.int(TriState.kNone))
	}
	if undo == kExtmarkUndo {
		uhp := u_force_get_undo_header(buf)
		if uhp == nil {
			return
		}
		merged := false
		if old_row == 0 && new_row == 0 && uh_extmark_size(uhp) > 0 {
			item := uh_extmark_at(uhp, C.int(uh_extmark_size(uhp) - 1))
			if item.type == kExtmarkSplice_U {
				splice := (^Extmark_Splice)(&item.data[0])
				if splice.start_row == start_row && splice.old_row == 0 && splice.new_row == 0 {
					if old_col == 0 && start_col >= splice.start_col && start_col <= splice.start_col + splice.new_col {
						splice.new_col += new_col
						splice.new_byte += new_byte
						merged = true
					} else if new_col == 0 && start_col == splice.start_col + splice.new_col {
						splice.old_col += old_col
						splice.old_byte += old_byte
						merged = true
					} else if new_col == 0 && start_col + old_col == splice.start_col {
						splice.start_col = start_col
						splice.start_byte = start_byte
						splice.old_col += old_col
						splice.old_byte += old_byte
						merged = true
					}
				}
			}
		}
		if !merged {
			splice := Extmark_Splice{}
			splice.start_row = start_row
			splice.start_col = start_col
			splice.start_byte = start_byte
			splice.old_row = old_row
			splice.old_col = old_col
			splice.old_byte = old_byte
			splice.new_row = new_row
			splice.new_col = new_col
			splice.new_byte = new_byte
			undo_obj := ExtmarkUndoObject{}
			undo_obj.type = kExtmarkSplice_U
			(^Extmark_Splice)(&undo_obj.data[0])^ = splice
			kv_push_xundo(&uhp.uh_extmark, undo_obj)
		}
	}
}

@(export)
extmark_splice_cols :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, old_col: C.int, new_col: C.int, undo: C.int) {
	context = runtime.default_context()
	extmark_splice(buf, start_row, start_col, 0, old_col, i64(old_col), 0, new_col, i64(new_col), undo)
}

@(export)
extmark_move_region :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, start_byte: C.longlong, extent_row: C.int, extent_col: C.int, extent_byte: C.longlong, new_row: C.int, new_col: C.int, new_byte: C.longlong, undo: C.int) {
	context = runtime.default_context()
	(^C.size_t)(uintptr(buf) + uintptr(B_DELETED_BYTES2_OFF))^ = 0
	buf_updates_send_splice(buf, start_row, start_col, start_byte, extent_row, extent_col, extent_byte, 0, 0, 0)
	row1 := min(start_row, new_row)
	row2 := max(start_row, new_row) + extent_row
	buf_signcols_count_range(buf, row1, row2, 0, C.int(TriState.kTrue))
	marktree_move_region(rawptr(uintptr(buf) + uintptr(B_MARKTREE_OFF)), start_row, start_col, extent_row, extent_col, new_row, new_col)
	buf_signcols_count_range(buf, row1, row2, 0, C.int(TriState.kNone))
	buf_updates_send_splice(buf, new_row, new_col, new_byte, extent_row, extent_col, extent_byte, 0, 0, 0)
	if undo == kExtmarkUndo {
		uhp := u_force_get_undo_header(buf)
		if uhp == nil {
			return
		}
		move := Extmark_Move{}
		move.start_row = start_row
		move.start_col = start_col
		move.start_byte = i64(start_byte)
		move.extent_row = extent_row
		move.extent_col = extent_col
		move.extent_byte = i64(extent_byte)
		move.new_row = new_row
		move.new_col = new_col
		move.new_byte = i64(new_byte)
		undo_obj := ExtmarkUndoObject{}
		undo_obj.type = kExtmarkMove_U
		(^Extmark_Move)(&undo_obj.data[0])^ = move
		kv_push_xundo(&uhp.uh_extmark, undo_obj)
	}
}
