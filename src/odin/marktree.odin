package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// marktree.c port: B-tree over marks with relative positions.
// Publics are @(export); C-statics are _o dormant plains.
// marktree.c + consumers (marktree.h inlines) — engine stays here.

// Branch factor / counts (marktree_defs.h).
MT_BRANCH_FACTOR_O :: 10
MTNODE_KEYS_O :: 19
MTNODE_ILEN_O :: 1392
MTNODE_KEY_OFF :: 72
MTNODE_PTR_OFF :: 832
MTNODE_META_OFF :: 992
MARKTREE_END_FLAG_O :: u64(1)
KMTMETACOUNT_O :: 5
K_MTMETA_LINES_O :: 1
K_MTMETA_SIGNHL_O :: 2
K_MTMETA_CONCEAL_O :: 4

// kvec_withinit(u64,4) mirror (cc-probed, 56B).
Intersection_O :: struct {
	size:       C.size_t,
	capacity:   C.size_t,
	items:      ^u64,
	init_array: [4]u64,
}
#assert(size_of(Intersection_O) == 56)

// MTNode mirror (cc-probed, 832B + flex inner).
MTNode_O :: struct {
	n:         C.int,
	level:     i16,
	p_idx:     i16,
	intersect: Intersection_O,
	parent:    rawptr,
	key:       [19]MTKey_O,
}
#assert(size_of(MTNode_O) == 832)

// MarkTree mirror (cc-probed, 96B).
MarkTree_O :: struct {
	root:      rawptr,
	meta_root: [5]u32,
	_pad:      [4]u8,
	n_keys:    C.size_t,
	n_nodes:   C.size_t,
	id2node:   Map_uint64_t_ptr_t,
}
#assert(size_of(MarkTree_O) == 96)

// Child pointer / meta slots (flex inner after key[19]).
node_ptr_o :: proc "c" (x: ^MTNode_O, i: C.int) -> rawptr {
	context = runtime.default_context()
	return (([^]rawptr)(uintptr(x) + uintptr(MTNODE_PTR_OFF)))[uintptr(i)]
}

node_ptr_set_o :: proc "c" (x: ^MTNode_O, i: C.int, v: rawptr) {
	context = runtime.default_context()
	(([^]rawptr)(uintptr(x) + uintptr(MTNODE_PTR_OFF)))[uintptr(i)] = v
}

node_meta_o :: proc "c" (x: ^MTNode_O, i: C.int, m: C.int) -> u32 {
	context = runtime.default_context()
	return (([^]u32)(uintptr(x) + uintptr(MTNODE_META_OFF)))[uintptr(i * 5 + m)]
}

node_meta_set_o :: proc "c" (x: ^MTNode_O, i: C.int, m: C.int, v: u32) {
	context = runtime.default_context()
	(([^]u32)(uintptr(x) + uintptr(MTNODE_META_OFF)))[uintptr(i * 5 + m)] = v
}

node_meta_row_o :: proc "c" (x: ^MTNode_O, i: C.int) -> [^]u32 {
	context = runtime.default_context()
	return ([^]u32)(uintptr(x) + uintptr(MTNODE_META_OFF) + uintptr(i * 5) * 4)
}

// Unchecked key slot address (for zero-length memmoves C allows at [n]).
key_slot_o :: proc "c" (x: ^MTNode_O, i: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(&x.key[0]) + uintptr(i) * 40)
}

// kvi_* over Intersection_O (exact kvec.h macro mirrors).
kvi_init_o :: proc "c" (v: ^Intersection_O) {
	context = runtime.default_context()
	v.capacity = 4
	v.size = 0
	v.items = &v.init_array[0]
}

kvi_resize_o :: proc "c" (v: ^Intersection_O, s: C.size_t) {
	context = runtime.default_context()
	if s > 4 {
		v.capacity = s
	} else {
		v.capacity = 4
	}
	if v.capacity == 4 {
		if v.items != &v.init_array[0] {
			libc.memcpy(rawptr(&v.init_array[0]), rawptr(v.items), C.size_t(v.size) * 8)
			xfree(rawptr(v.items))
			v.items = &v.init_array[0]
		}
	} else {
		if v.items == &v.init_array[0] {
			nb := xmalloc(C.size_t(v.capacity) * 8)
			libc.memcpy(nb, rawptr(v.items), C.size_t(v.size) * 8)
			v.items = ([^]u64)(nb)
		} else {
			v.items = ([^]u64)(xrealloc(rawptr(v.items), C.size_t(v.capacity) * 8))
		}
	}
}

kvi_push_o :: proc "c" (v: ^Intersection_O, x: u64) {
	context = runtime.default_context()
	if v.size == v.capacity {
		kvi_resize_o(v, v.capacity * 2)
	}
	([^]u64)(v.items)[uintptr(v.size)] = x
	v.size += 1
}

kvi_pushp_o :: proc "c" (v: ^Intersection_O) -> ^u64 {
	context = runtime.default_context()
	if v.size == v.capacity {
		kvi_resize_o(v, v.capacity * 2)
	}
	v.size += 1
	return (^u64)(rawptr(uintptr(v.items) + uintptr(v.size - 1) * 8))
}

kvi_copy_o :: proc "c" (v1: ^Intersection_O, v0: ^Intersection_O) {
	context = runtime.default_context()
	if v1.capacity < v0.size {
		kvi_resize_o(v1, v0.size)
	}
	v1.size = v0.size
	libc.memcpy(rawptr(v1.items), rawptr(v0.items), C.size_t(v0.size) * 8)
}

kvi_destroy_o :: proc "c" (v: ^Intersection_O) {
	context = runtime.default_context()
	if v.items != &v.init_array[0] {
		xfree(rawptr(v.items))
		v.items = nil
	}
}

kvi_ensure_more_space_o :: proc "c" (v: ^Intersection_O, len: C.size_t) {
	context = runtime.default_context()
	if v.capacity < v.size + len {
		need := u32(v.size + len)
		roundup32(&need)
		kvi_resize_o(v, C.size_t(need))
	}
}

kvi_A_o :: proc "c" (v: ^Intersection_O, i: C.size_t) -> u64 {
	context = runtime.default_context()
	return ([^]u64)(v.items)[uintptr(i)]
}

kvi_A_set_o :: proc "c" (v: ^Intersection_O, i: C.size_t, x: u64) {
	context = runtime.default_context()
	([^]u64)(v.items)[uintptr(i)] = x
}

// id2node lookup (pmap_get).
id2node_o :: proc "c" (b: ^MarkTree_O, id: u64) -> rawptr {
	context = runtime.default_context()
	k := mh_get(&b.id2node.set, id, hash_uint64_t, equal_uint64_t)
	if k == MH_TOMBSTONE {
		return nil
	}
	return b.id2node.values[uintptr(k)]
}

id2node_put_o :: proc "c" (b: ^MarkTree_O, id: u64, x: rawptr) {
	context = runtime.default_context()
	map_put_ref_uint64_t_ptr_t(&b.id2node, id, nil, nil)^ = x
}

// mt_lookup_id / mt_start (marktree.h inlines).
mt_lookup_id_o :: proc "c" (ns: u32, id: u32, enda: bool) -> u64 {
	context = runtime.default_context()
	e: u64 = 0
	if enda {
		e = 1
	}
	return (u64(ns) << 33) | (u64(id) << 1) | e
}

mt_lookup_key_side_o :: proc "c" (key: MTKey_O, end: bool) -> u64 {
	context = runtime.default_context()
	return mt_lookup_id_o(key.ns, key.id, end)
}

mt_start_o :: proc "c" (key: MTKey_O) -> bool {
	context = runtime.default_context()
	return mt_paired_o(key) && !mt_end_o(key)
}

pos_leq_o :: proc "c" (a: MTPos_O, b: MTPos_O) -> bool {
	context = runtime.default_context()
	return a.row < b.row || (a.row == b.row && a.col <= b.col)
}

pos_less_o :: proc "c" (a: MTPos_O, b: MTPos_O) -> bool {
	context = runtime.default_context()
	return !pos_leq_o(b, a)
}

relative_o :: proc "c" (base: MTPos_O, val: ^MTPos_O) {
	context = runtime.default_context()
	if val.row < base.row || (val.row == base.row && val.col < base.col) {
		libc.abort()
	}
	if val.row == base.row {
		val.row = 0
		val.col -= base.col
	} else {
		val.row -= base.row
	}
}

unrelative_o :: proc "c" (base: MTPos_O, val: ^MTPos_O) {
	context = runtime.default_context()
	if val.row == 0 {
		val.row = base.row
		val.col += base.col
	} else {
		val.row += base.row
	}
}

compose_o :: proc "c" (base: ^MTPos_O, val: MTPos_O) {
	context = runtime.default_context()
	if val.row == 0 {
		base.col += val.col
	} else {
		base.row += val.row
		base.col = val.col
	}
}

generic_cmp_o :: proc "c" (a: C.int32_t, b: C.int32_t) -> C.int {
	context = runtime.default_context()
	if b < a {
		return 1
	}
	if a < b {
		return -1
	}
	return 0
}

key_cmp_o :: proc "c" (a: MTKey_O, b: MTKey_O) -> C.int {
	context = runtime.default_context()
	cmp := generic_cmp_o(a.pos.row, b.pos.row)
	if cmp != 0 {
		return cmp
	}
	cmp = generic_cmp_o(a.pos.col, b.pos.col)
	if cmp != 0 {
		return cmp
	}
	cmp_mask := u16(0x4000) | u16(0x02) | u16(0x01) | u16(0x8000)
	return generic_cmp_o(C.int32_t(a.flags & cmp_mask), C.int32_t(b.flags & cmp_mask))
}

// Position of k in node, or insertion point (0..n inclusive).
marktree_getp_aux_o :: proc "c" (x: ^MTNode_O, k: MTKey_O, match: ^bool) -> C.int {
	context = runtime.default_context()
	dummy := false
	m := &dummy
	if match != nil {
		m = match
	}
	begin: C.int = 0
	end := x.n
	if x.n == 0 {
		m^ = false
		return -1
	}
	for begin < end {
		mid := (begin + end) >> 1
		if key_cmp_o(x.key[int(mid)], k) < 0 {
			begin = mid + 1
		} else {
			end = mid
		}
	}
	if begin == x.n {
		m^ = false
		return x.n - 1
	}
	m^ = (key_cmp_o(k, x.key[int(begin)]) == 0)
	if !m^ {
		begin -= 1
	}
	return begin
}

refkey_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O, i: C.int) {
	context = runtime.default_context()
	id2node_put_o(b, mt_lookup_key_o(x.key[int(i)]), x)
}

// x must be internal and not full; x->ptr[i] full.
split_node_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O, i: C.int, next: MTKey_O) {
	context = runtime.default_context()
	y := (^MTNode_O)(node_ptr_o(x, i))
	z := (^MTNode_O)(marktree_alloc_node_o(b, true))
	z.level = y.level
	z.n = 10 - 1
	last_start := MARKTREE_END_FLAG_O
	if mt_end_o(next) {
		last_start = mt_lookup_id_o(next.ns, next.id, false)
	}
	kvi_copy_o(&z.intersect, &y.intersect)
	if y.level == 0 {
		pi := pseudo_index_o(y, 0)
		for j: C.int = 0; j < 10; j += 1 {
			k := y.key[int(j)]
			pi_end := pseudo_index_for_id_o(b, mt_lookup_id_o(k.ns, k.id, true), true)
			if mt_start_o(k) && pi_end > pi && mt_lookup_key_o(k) != last_start {
				intersect_node_o(b, z, mt_lookup_id_o(k.ns, k.id, false))
			}
		}
		for j: C.int = 9; j < 19; j += 1 {
			k := y.key[int(j)]
			pi_start := pseudo_index_for_id_o(b, mt_lookup_id_o(k.ns, k.id, false), true)
			if mt_end_o(k) && pi_start > 0 && pi_start < pi {
				intersect_node_o(b, y, mt_lookup_id_o(k.ns, k.id, false))
			}
		}
	}
	libc.memcpy(rawptr(&z.key[0]), rawptr(&y.key[10]), C.size_t(9 * 40))
	for j: C.int = 0; j < 9; j += 1 {
		refkey_o(b, z, j)
	}
	if y.level != 0 {
		pxb := uintptr(x) + uintptr(MTNODE_PTR_OFF)
		pyb := uintptr(y) + uintptr(MTNODE_PTR_OFF)
		pzb := uintptr(z) + uintptr(MTNODE_PTR_OFF)
		libc.memcpy(rawptr(pzb), rawptr(pyb + 10 * 8), C.size_t(10 * 8))
		myb := uintptr(y) + uintptr(MTNODE_META_OFF)
		mzb := uintptr(z) + uintptr(MTNODE_META_OFF)
		libc.memcpy(rawptr(mzb), rawptr(myb + 10 * 20), C.size_t(10 * 20))
		for j: C.int = 0; j < 10; j += 1 {
			ch := (^MTNode_O)(node_ptr_o(z, j))
			ch.parent = rawptr(z)
			ch.p_idx = i16(j)
		}
	}
	y.n = 9
	xpb := uintptr(x) + uintptr(MTNODE_PTR_OFF)
	xmb := uintptr(x) + uintptr(MTNODE_META_OFF)
	libc.memmove(rawptr(xpb + uintptr(i + 2) * 8), rawptr(xpb + uintptr(i + 1) * 8), C.size_t(x.n - i) * 8)
	libc.memmove(rawptr(xmb + uintptr(i + 2) * 20), rawptr(xmb + uintptr(i + 1) * 20), C.size_t(x.n - i) * 20)
	node_ptr_set_o(x, i + 1, rawptr(z))
	meta_describe_node_o(node_meta_row_o(x, i + 1), x)
	z.parent = rawptr(x)
	for j := i + 1; j < x.n + 2; j += 1 {
		ch := (^MTNode_O)(node_ptr_o(x, j))
		ch.p_idx = i16(j)
	}
	libc.memmove(key_slot_o(x, i + 1), key_slot_o(x, i), C.size_t(x.n - i) * 40)
	x.key[int(i)] = y.key[9]
	refkey_o(b, x, i)
	x.n += 1
	meta_inc: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc[0])), x.key[int(i)])
	for m in 0 ..< 5 {
		node_meta_set_o(x, i, C.int(m), node_meta_o(x, i, C.int(m)) - (node_meta_o(x, i + 1, C.int(m)) + meta_inc[m]))
	}
	for j: C.int = 0; j < 9; j += 1 {
		relative_o(x.key[int(i)].pos, &z.key[int(j)].pos)
	}
	if i > 0 {
		unrelative_o(x.key[int(i) - 1].pos, &x.key[int(i)].pos)
	}
	if y.level != 0 {
		bubble_up_o(y)
		bubble_up_o(z)
	}
}

// x must not be full.
marktree_putp_aux_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O, k: MTKey_O, meta_inc: [^]u32) {
	context = runtime.default_context()
	i := marktree_getp_aux_o(x, k, nil) + 1
	if x.level == 0 {
		if i != x.n {
			libc.memmove(key_slot_o(x, i + 1), key_slot_o(x, i), C.size_t(x.n - i) * 40)
		}
		x.key[int(i)] = k
		refkey_o(b, x, i)
		x.n += 1
	} else {
		if (^MTNode_O)(node_ptr_o(x, i)).n == 19 {
			split_node_o(b, x, i, k)
			if key_cmp_o(k, x.key[int(i)]) > 0 {
				i += 1
			}
		}
		kk := k
		if i > 0 {
			relative_o(x.key[int(i) - 1].pos, &kk.pos)
		}
		marktree_putp_aux_o(b, (^MTNode_O)(node_ptr_o(x, i)), kk, meta_inc)
		for m in 0 ..< 5 {
			node_meta_set_o(x, i, C.int(m), node_meta_o(x, i, C.int(m)) + meta_inc[uintptr(m)])
		}
	}
}

@(export)
marktree_put :: proc "c" (b_raw: rawptr, key_in: MTKey_O, end_row: C.int, end_col: C.int, end_right: bool) {
	context = runtime.default_context()
	key := key_in
	if key.flags & ~(MT_FLAG_EXTERNAL_MASK_O | u16(0x4000)) != 0 {
		libc.abort()
	}
	if end_row >= 0 {
		key.flags |= MT_FLAG_PAIRED_O
	}
	marktree_put_key(b_raw, key)
	if end_row >= 0 {
		end_key := key
		ef: u16 = 0
		if end_right {
			ef = u16(0x4000)
		}
		end_key.flags = (key.flags & ~u16(0x4000)) | u16(0x02) | ef
		end_key.pos = MTPos_O{row = C.int32_t(end_row), col = C.int32_t(end_col)}
		marktree_put_key(b_raw, end_key)
		itr := MarkTreeIter_O{}
		end_itr := MarkTreeIter_O{}
		marktree_lookup(b_raw, mt_lookup_key_o(key), rawptr(&itr))
		marktree_lookup(b_raw, mt_lookup_key_o(end_key), rawptr(&end_itr))
		marktree_intersect_pair(b_raw, mt_lookup_key_o(key), rawptr(&itr), rawptr(&end_itr), false)
	}
}

intersection_has_o :: proc "c" (x: ^Intersection_O, id: u64) -> bool {
	context = runtime.default_context()
	i: C.size_t = 0
	for i < x.size {
		if kvi_A_o(x, i) == id {
			return true
		} else if kvi_A_o(x, i) >= id {
			return false
		}
		i += 1
	}
	return false
}

intersect_node_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O, id: u64) {
	context = runtime.default_context()
	if id & MARKTREE_END_FLAG_O != 0 {
		libc.abort()
	}
	kvi_push_o(&x.intersect, 0)
	i := i64(x.intersect.size) - 1
	for i >= 0 {
		if i > 0 && kvi_A_o(&x.intersect, C.size_t(i - 1)) > id {
			kvi_A_set_o(&x.intersect, C.size_t(i), kvi_A_o(&x.intersect, C.size_t(i - 1)))
		} else {
			kvi_A_set_o(&x.intersect, C.size_t(i), id)
			break
		}
		i -= 1
	}
	_ = b
}

unintersect_node_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O, id: u64, strict: bool) {
	context = runtime.default_context()
	if id & MARKTREE_END_FLAG_O != 0 {
		libc.abort()
	}
	seen := false
	i: C.size_t = 0
	for i < x.intersect.size {
		if kvi_A_o(&x.intersect, i) < id {
			i += 1
			continue
		} else if kvi_A_o(&x.intersect, i) == id {
			seen = true
			break
		} else {
			break
		}
	}
	if strict && !seen {
		libc.abort()
	}
	if seen {
		if i < x.intersect.size - 1 {
			libc.memmove(rawptr(uintptr(x.intersect.items) + uintptr(i) * 8), rawptr(uintptr(x.intersect.items) + uintptr(i + 1) * 8), C.size_t(x.intersect.size - i - 1) * 8)
		}
		x.intersect.size -= 1
	}
	_ = b
}

@(export)
marktree_intersect_pair :: proc "c" (b_raw: rawptr, id: u64, itr_raw: rawptr, end_itr_raw: rawptr, delete: bool) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	end_itr := (^MarkTreeIter_O)(end_itr_raw)
	lvl: C.int = 0
	maxlvl := itr.lvl
	if end_itr.lvl < maxlvl {
		maxlvl = end_itr.lvl
	}
	for ; lvl < maxlvl; lvl += 1 {
		if itr.s[int(lvl)].i > end_itr.s[int(lvl)].i {
			return
		} else if itr.s[int(lvl)].i < end_itr.s[int(lvl)].i {
			break
		}
	}
	if lvl == maxlvl {
		il := itr.s[int(lvl)].i
		if lvl == itr.lvl {
			il = itr.i + 1
		}
		el := end_itr.s[int(lvl)].i
		if lvl == end_itr.lvl {
			el = end_itr.i
		}
		if il > el {
			return
		}
	}
	for itr.x != nil {
		skip := false
		xn := (^MTNode_O)(itr.x)
		if itr.x == end_itr.x {
			if xn.level == 0 || itr.i >= end_itr.i {
				break
			} else {
				skip = true
			}
		} else if itr.lvl > lvl {
			skip = true
		} else {
			il := itr.s[int(lvl)].i
			if lvl == itr.lvl {
				il = itr.i + 1
			}
			el := end_itr.s[int(lvl)].i
			if lvl == end_itr.lvl {
				el = end_itr.i + 1
			}
			if il < el {
				skip = true
			} else {
				lvl += 1
			}
		}
		if skip {
			if xn.level != 0 {
				xc := (^MTNode_O)(node_ptr_o(xn, itr.i + 1))
				if delete {
					unintersect_node_o(b, xc, id, true)
				} else {
					intersect_node_o(b, xc, id)
				}
			}
		}
		marktree_itr_next_skip_o(b_raw, itr_raw, skip, true, nil, nil)
	}
	_ = b
}

marktree_alloc_node_o :: proc "c" (b: ^MarkTree_O, internal: bool) -> ^MTNode_O {
	context = runtime.default_context()
	sz := C.size_t(832)
	if internal {
		sz = C.size_t(MTNODE_ILEN_O)
	}
	x := (^MTNode_O)(xcalloc(1, sz))
	kvi_init_o(&x.intersect)
	b.n_nodes += 1
	return x
}

meta_describe_key_inc_o :: proc "c" (meta_inc: [^]u32, k: ^MTKey_O) {
	context = runtime.default_context()
	if !mt_end_o(k^) && !mt_invalid_o(k^) {
		if k.flags & u16(0x1000) != 0 {
			meta_inc[0] += 1
		}
		if k.flags & u16(0x800) != 0 {
			meta_inc[1] += 1
		}
		if k.flags & u16(0x400) != 0 {
			meta_inc[2] += 1
		}
		if k.flags & u16(0x200) != 0 {
			meta_inc[3] += 1
		}
		if k.flags & u16(0x2000) != 0 {
			meta_inc[4] += 1
		}
	}
}

meta_describe_key_o :: proc "c" (meta_inc: [^]u32, k: MTKey_O) {
	context = runtime.default_context()
	libc.memset(rawptr(meta_inc), 0, 20)
	kc := k
	meta_describe_key_inc_o(meta_inc, &kc)
}

meta_describe_node_o :: proc "c" (meta_node: [^]u32, x: ^MTNode_O) {
	context = runtime.default_context()
	libc.memset(rawptr(meta_node), 0, 20)
	for i: C.int = 0; i < x.n; i += 1 {
		kc := x.key[int(i)]
		meta_describe_key_inc_o(meta_node, &kc)
	}
	if x.level != 0 {
		for i: C.int = 0; i < x.n + 1; i += 1 {
			for m in 0 ..< 5 {
				meta_node[uintptr(i * 5 + C.int(m))] += node_meta_o(x, i, C.int(m))
			}
		}
	}
}

meta_has_o :: proc "c" (meta_count: [^]u32, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	count: u32 = 0
	for m in 0 ..< 5 {
		count += meta_count[uintptr(m)] & meta_filter[uintptr(m)]
	}
	return count > 0
}

@(export)
marktree_put_key :: proc "c" (b_raw: rawptr, k: MTKey_O) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	kk := k
	kk.flags |= u16(0x01)
	if b.root == nil {
		b.root = rawptr(marktree_alloc_node_o(b, true))
	}
	r := (^MTNode_O)(b.root)
	if r.n == 19 {
		s := marktree_alloc_node_o(b, true)
		b.root = rawptr(s)
		s.level = r.level + 1
		s.n = 0
		node_ptr_set_o(s, 0, rawptr(r))
		for m in 0 ..< 5 {
			node_meta_set_o(s, 0, C.int(m), b.meta_root[m])
		}
		r.parent = rawptr(s)
		r.p_idx = 0
		split_node_o(b, s, 0, kk)
		r = s
	}
	meta_inc: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc[0])), kk)
	marktree_putp_aux_o(b, r, kk, ([^]u32)(rawptr(&meta_inc[0])))
	for m in 0 ..< 5 {
		b.meta_root[m] += meta_inc[m]
	}
	b.n_keys += 1
}

// Retain only items NOT in common (in place).
intersect_merge_o :: proc "c" (m: ^Intersection_O, x: ^Intersection_O, y: ^Intersection_O) {
	context = runtime.default_context()
	xi: C.size_t = 0
	yi: C.size_t = 0
	xn: C.size_t = 0
	yn: C.size_t = 0
	for xi < x.size && yi < y.size {
		if kvi_A_o(x, xi) == kvi_A_o(y, yi) {
			kvi_push_o(m, kvi_A_o(x, xi))
			xi += 1
			yi += 1
		} else if kvi_A_o(x, xi) < kvi_A_o(y, yi) {
			kvi_A_set_o(x, xn, kvi_A_o(x, xi))
			xn += 1
			xi += 1
		} else {
			kvi_A_set_o(y, yn, kvi_A_o(y, yi))
			yn += 1
			yi += 1
		}
	}
	if xi < x.size {
		libc.memmove(rawptr(uintptr(x.items) + uintptr(xn) * 8), rawptr(uintptr(x.items) + uintptr(xi) * 8), C.size_t(x.size - xi) * 8)
		xn += x.size - xi
	}
	if yi < y.size {
		libc.memmove(rawptr(uintptr(y.items) + uintptr(yn) * 8), rawptr(uintptr(y.items) + uintptr(yi) * 8), C.size_t(y.size - yi) * 8)
		yn += y.size - yi
	}
	x.size = xn
	y.size = yn
}

intersect_mov_o :: proc "c" (x: ^Intersection_O, y: ^Intersection_O, w: ^Intersection_O, d: ^Intersection_O) {
	context = runtime.default_context()
	wi: C.size_t = 0
	yi: C.size_t = 0
	wn: C.size_t = 0
	yn: C.size_t = 0
	xi: C.size_t = 0
	for wi < w.size || xi < x.size {
		if wi < w.size && (xi >= x.size || kvi_A_o(x, xi) >= kvi_A_o(w, wi)) {
			if xi < x.size && kvi_A_o(x, xi) == kvi_A_o(w, wi) {
				xi += 1
			}
			for yi < y.size && kvi_A_o(y, yi) < kvi_A_o(w, wi) {
				kvi_push_o(d, kvi_A_o(y, yi))
				yi += 1
			}
			if yi < y.size && kvi_A_o(y, yi) == kvi_A_o(w, wi) {
				kvi_A_set_o(y, yn, kvi_A_o(y, yi))
				yn += 1
				yi += 1
				wi += 1
			} else {
				kvi_A_set_o(w, wn, kvi_A_o(w, wi))
				wn += 1
				wi += 1
			}
		} else {
			for yi < y.size && kvi_A_o(y, yi) < kvi_A_o(x, xi) {
				kvi_push_o(d, kvi_A_o(y, yi))
				yi += 1
			}
			if yi < y.size && kvi_A_o(y, yi) == kvi_A_o(x, xi) {
				kvi_A_set_o(y, yn, kvi_A_o(y, yi))
				yn += 1
				yi += 1
				xi += 1
			} else {
				if wi == wn {
					n := w.size - wn
					kvi_pushp_o(w)
					if n > 0 {
						libc.memmove(rawptr(uintptr(w.items) + uintptr(wn + 1) * 8), rawptr(uintptr(w.items) + uintptr(wn) * 8), C.size_t(n) * 8)
					}
					kvi_A_set_o(w, wi, kvi_A_o(x, xi))
					wn += 1
					wi += 1
				} else {
					if !(wn < wi) {
						libc.abort()
					}
					kvi_A_set_o(w, wn, kvi_A_o(x, xi))
					wn += 1
				}
				xi += 1
			}
		}
	}
	if yi < y.size {
		n := y.size - yi
		kvi_ensure_more_space_o(d, n)
		libc.memcpy(rawptr(uintptr(d.items) + uintptr(d.size) * 8), rawptr(uintptr(y.items) + uintptr(yi) * 8), C.size_t(n) * 8)
		d.size += n
	}
	w.size = wn
	y.size = yn
}

@(export)
intersect_mov_test :: proc "c" (x: [^]u64, nx: C.size_t, y: [^]u64, ny: C.size_t, win: [^]u64, nwin: C.size_t, wout: [^]u64, nwout: ^C.size_t, dout: [^]u64, ndout: ^C.size_t) -> bool {
	context = runtime.default_context()
	xi := Intersection_O{size = nx, items = x}
	yi := Intersection_O{size = ny, items = y}
	w := Intersection_O{}
	kvi_init_o(&w)
	i: C.size_t = 0
	for i < nwin {
		kvi_push_o(&w, win[uintptr(i)])
		i += 1
	}
	d := Intersection_O{}
	kvi_init_o(&d)
	intersect_mov_o(&xi, &yi, &w, &d)
	if w.size > nwout^ || d.size > ndout^ {
		return false
	}
	libc.memcpy(rawptr(wout), rawptr(w.items), C.size_t(w.size) * 8)
	nwout^ = w.size
	libc.memcpy(rawptr(dout), rawptr(d.items), C.size_t(d.size) * 8)
	ndout^ = d.size
	return true
}

// Intersection i = x & y.
intersect_common_o :: proc "c" (i: ^Intersection_O, x: ^Intersection_O, y: ^Intersection_O) {
	context = runtime.default_context()
	xi: C.size_t = 0
	yi: C.size_t = 0
	for xi < x.size && yi < y.size {
		if kvi_A_o(x, xi) == kvi_A_o(y, yi) {
			kvi_push_o(i, kvi_A_o(x, xi))
			xi += 1
			yi += 1
		} else if kvi_A_o(x, xi) < kvi_A_o(y, yi) {
			xi += 1
		} else {
			yi += 1
		}
	}
}

// Inplace union x |= y.
intersect_add_o :: proc "c" (x: ^Intersection_O, y: ^Intersection_O) {
	context = runtime.default_context()
	xi: C.size_t = 0
	yi: C.size_t = 0
	for xi < x.size && yi < y.size {
		if kvi_A_o(x, xi) == kvi_A_o(y, yi) {
			xi += 1
			yi += 1
		} else if kvi_A_o(y, yi) < kvi_A_o(x, xi) {
			n := x.size - xi
			kvi_pushp_o(x)
			libc.memmove(rawptr(uintptr(x.items) + uintptr(xi + 1) * 8), rawptr(uintptr(x.items) + uintptr(xi) * 8), C.size_t(n) * 8)
			kvi_A_set_o(x, xi, kvi_A_o(y, yi))
			xi += 1
			yi += 1
		} else {
			xi += 1
		}
	}
	if yi < y.size {
		n := y.size - yi
		kvi_ensure_more_space_o(x, n)
		libc.memcpy(rawptr(uintptr(x.items) + uintptr(x.size) * 8), rawptr(uintptr(y.items) + uintptr(yi) * 8), C.size_t(n) * 8)
		x.size += n
	}
}

// Inplace asymmetric difference x &= ~y.
intersect_sub_o :: proc "c" (x: ^Intersection_O, y: ^Intersection_O) {
	context = runtime.default_context()
	xi: C.size_t = 0
	yi: C.size_t = 0
	xn: C.size_t = 0
	for xi < x.size && yi < y.size {
		if kvi_A_o(x, xi) == kvi_A_o(y, yi) {
			xi += 1
			yi += 1
		} else if kvi_A_o(x, xi) < kvi_A_o(y, yi) {
			kvi_A_set_o(x, xn, kvi_A_o(x, xi))
			xn += 1
			xi += 1
		} else {
			yi += 1
		}
	}
	if xi < x.size {
		n := x.size - xi
		if xn < xi {
			libc.memmove(rawptr(uintptr(x.items) + uintptr(xn) * 8), rawptr(uintptr(x.items) + uintptr(xi) * 8), C.size_t(n) * 8)
		}
		xn += n
	}
	x.size = xn
}

// A node shrunk (or is a split half): intervals covering all children move up.
bubble_up_o :: proc "c" (x: ^MTNode_O) {
	context = runtime.default_context()
	xi := Intersection_O{}
	kvi_init_o(&xi)
	x0 := (^MTNode_O)(node_ptr_o(x, 0))
	xn := (^MTNode_O)(node_ptr_o(x, x.n))
	intersect_common_o(&xi, &x0.intersect, &xn.intersect)
	if xi.size != 0 {
		for i: C.int = 0; i < x.n + 1; i += 1 {
			ch := (^MTNode_O)(node_ptr_o(x, i))
			intersect_sub_o(&ch.intersect, &xi)
		}
		for i: C.size_t = 0; i < xi.size; i += 1 {
			kvi_push_o(&x.intersect, kvi_A_o(&xi, i))
		}
	}
	kvi_destroy_o(&xi)
}

merge_node_o :: proc "c" (b: ^MarkTree_O, p: ^MTNode_O, i: C.int) -> ^MTNode_O {
	context = runtime.default_context()
	x := (^MTNode_O)(node_ptr_o(p, i))
	y := (^MTNode_O)(node_ptr_o(p, i + 1))
	mi := Intersection_O{}
	kvi_init_o(&mi)
	intersect_merge_o(&mi, &x.intersect, &y.intersect)
	x.key[int(x.n)] = p.key[int(i)]
	refkey_o(b, x, x.n)
	if i > 0 {
		relative_o(p.key[int(i) - 1].pos, &x.key[int(x.n)].pos)
	}
	meta_inc: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc[0])), x.key[int(x.n)])
	libc.memmove(key_slot_o(x, x.n + 1), rawptr(&y.key[0]), C.size_t(y.n) * 40)
	for k: C.int = 0; k < y.n; k += 1 {
		refkey_o(b, x, x.n + 1 + k)
		unrelative_o(x.key[int(x.n)].pos, &x.key[int(x.n) + 1 + int(k)].pos)
	}
	if x.level != 0 {
		libc.memmove(rawptr(uintptr(x) + uintptr(MTNODE_PTR_OFF) + uintptr(x.n + 1) * 8), rawptr(uintptr(y) + uintptr(MTNODE_PTR_OFF)), C.size_t(y.n + 1) * 8)
		libc.memmove(rawptr(uintptr(x) + uintptr(MTNODE_META_OFF) + uintptr(x.n + 1) * 20), rawptr(uintptr(y) + uintptr(MTNODE_META_OFF)), C.size_t(y.n + 1) * 20)
		for k: C.int = 0; k < x.n + 1; k += 1 {
			for idx: C.size_t = 0; idx < x.intersect.size; idx += 1 {
				intersect_node_o(b, (^MTNode_O)(node_ptr_o(x, k)), kvi_A_o(&x.intersect, idx))
			}
		}
		for ky: C.int = 0; ky < y.n + 1; ky += 1 {
			k := x.n + ky + 1
			ch := (^MTNode_O)(node_ptr_o(x, k))
			ch.parent = rawptr(x)
			ch.p_idx = i16(k)
			for idx: C.size_t = 0; idx < y.intersect.size; idx += 1 {
				intersect_node_o(b, ch, kvi_A_o(&y.intersect, idx))
			}
		}
	}
	x.n += y.n + 1
	for m in 0 ..< 5 {
		node_meta_set_o(p, i, C.int(m), node_meta_o(p, i, C.int(m)) + node_meta_o(p, i + 1, C.int(m)) + meta_inc[m])
	}
	libc.memmove(key_slot_o(p, i), key_slot_o(p, i + 1), C.size_t(p.n - i - 1) * 40)
	libc.memmove(rawptr(uintptr(p) + uintptr(MTNODE_PTR_OFF) + uintptr(i + 1) * 8), rawptr(uintptr(p) + uintptr(MTNODE_PTR_OFF) + uintptr(i + 2) * 8), C.size_t(p.n - i - 1) * 8)
	libc.memmove(rawptr(uintptr(p) + uintptr(MTNODE_META_OFF) + uintptr(i + 1) * 20), rawptr(uintptr(p) + uintptr(MTNODE_META_OFF) + uintptr(i + 2) * 20), C.size_t(p.n - i - 1) * 20)
	for j := i + 1; j < p.n; j += 1 {
		(^MTNode_O)(node_ptr_o(p, j)).p_idx = i16(j)
	}
	p.n -= 1
	marktree_free_node_o(b, y)
	kvi_destroy_o(&x.intersect)
	kvi_move(&x.intersect, &mi)
	return x
}

pivot_right_o :: proc "c" (b: ^MarkTree_O, p_pos: MTPos_O, p: ^MTNode_O, i: C.int) {
	context = runtime.default_context()
	x := (^MTNode_O)(node_ptr_o(p, i))
	y := (^MTNode_O)(node_ptr_o(p, i + 1))
	libc.memmove(rawptr(&y.key[1]), rawptr(&y.key[0]), C.size_t(y.n) * 40)
	if y.level != 0 {
		ypb := uintptr(y) + uintptr(MTNODE_PTR_OFF)
		ymb := uintptr(y) + uintptr(MTNODE_META_OFF)
		libc.memmove(rawptr(ypb + 8), rawptr(ypb), C.size_t(y.n + 1) * 8)
		libc.memmove(rawptr(ymb + 20), rawptr(ymb), C.size_t(y.n + 1) * 20)
		for j: C.int = 1; j < y.n + 2; j += 1 {
			(^MTNode_O)(node_ptr_o(y, j)).p_idx = i16(j)
		}
	}
	y.key[0] = p.key[int(i)]
	refkey_o(b, y, 0)
	p.key[int(i)] = x.key[int(x.n) - 1]
	refkey_o(b, p, i)
	meta_inc_y: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc_y[0])), y.key[0])
	meta_inc_x: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc_x[0])), p.key[int(i)])
	for m in 0 ..< 5 {
		node_meta_set_o(p, i + 1, C.int(m), node_meta_o(p, i + 1, C.int(m)) + meta_inc_y[m])
		node_meta_set_o(p, i, C.int(m), node_meta_o(p, i, C.int(m)) - meta_inc_x[m])
	}
	if x.level != 0 {
		node_ptr_set_o(y, 0, node_ptr_o(x, x.n))
		libc.memcpy(rawptr(node_meta_row_o(y, 0)), rawptr(node_meta_row_o(x, x.n)), 20)
		for m in 0 ..< 5 {
			node_meta_set_o(p, i + 1, C.int(m), node_meta_o(p, i + 1, C.int(m)) + node_meta_o(y, 0, C.int(m)))
			node_meta_set_o(p, i, C.int(m), node_meta_o(p, i, C.int(m)) - node_meta_o(y, 0, C.int(m)))
		}
		y0 := (^MTNode_O)(node_ptr_o(y, 0))
		y0.parent = rawptr(y)
		y0.p_idx = 0
	}
	x.n -= 1
	y.n += 1
	if i > 0 {
		unrelative_o(p.key[int(i) - 1].pos, &p.key[int(i)].pos)
	}
	relative_o(p.key[int(i)].pos, &y.key[0].pos)
	for k: C.int = 1; k < y.n; k += 1 {
		unrelative_o(y.key[0].pos, &y.key[int(k)].pos)
	}
	if x.level != 0 {
		d := Intersection_O{}
		kvi_init_o(&d)
		y0 := (^MTNode_O)(node_ptr_o(y, 0))
		intersect_mov_o(&x.intersect, &y.intersect, &y0.intersect, &d)
		if d.size != 0 {
			for yi: C.int = 1; yi < y.n + 1; yi += 1 {
				intersect_add_o(&((^MTNode_O)(node_ptr_o(y, yi))).intersect, &d)
			}
		}
		kvi_destroy_o(&d)
		bubble_up_o(x)
	} else {
		if mt_end_o(p.key[int(i)]) {
			pi := pseudo_index_o(x, 0)
			start_id := mt_lookup_key_side_o(p.key[int(i)], false)
			pi_start := pseudo_index_for_id_o(b, start_id, true)
			if pi_start > 0 && pi_start < pi {
				intersect_node_o(b, x, start_id)
			}
		}
		if mt_start_o(y.key[0]) {
			unintersect_node_o(b, y, mt_lookup_key_o(y.key[0]), false)
		}
	}
	_ = p_pos
}

pivot_left_o :: proc "c" (b: ^MarkTree_O, p_pos: MTPos_O, p: ^MTNode_O, i: C.int) {
	context = runtime.default_context()
	x := (^MTNode_O)(node_ptr_o(p, i))
	y := (^MTNode_O)(node_ptr_o(p, i + 1))
	for k: C.int = 1; k < y.n; k += 1 {
		relative_o(y.key[0].pos, &y.key[int(k)].pos)
	}
	unrelative_o(p.key[int(i)].pos, &y.key[0].pos)
	if i > 0 {
		relative_o(p.key[int(i) - 1].pos, &p.key[int(i)].pos)
	}
	x.key[int(x.n)] = p.key[int(i)]
	refkey_o(b, x, x.n)
	p.key[int(i)] = y.key[0]
	refkey_o(b, p, i)
	meta_inc_x: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc_x[0])), x.key[int(x.n)])
	meta_inc_y: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc_y[0])), p.key[int(i)])
	for m in 0 ..< 5 {
		node_meta_set_o(p, i, C.int(m), node_meta_o(p, i, C.int(m)) + meta_inc_x[m])
		node_meta_set_o(p, i + 1, C.int(m), node_meta_o(p, i + 1, C.int(m)) - meta_inc_y[m])
	}
	if x.level != 0 {
		node_ptr_set_o(x, x.n + 1, node_ptr_o(y, 0))
		libc.memcpy(rawptr(node_meta_row_o(x, x.n + 1)), rawptr(node_meta_row_o(y, 0)), 20)
		for m in 0 ..< 5 {
			node_meta_set_o(p, i + 1, C.int(m), node_meta_o(p, i + 1, C.int(m)) - node_meta_o(y, 0, C.int(m)))
			node_meta_set_o(p, i, C.int(m), node_meta_o(p, i, C.int(m)) + node_meta_o(y, 0, C.int(m)))
		}
		xn1 := (^MTNode_O)(node_ptr_o(x, x.n + 1))
		xn1.parent = rawptr(x)
		xn1.p_idx = i16(x.n + 1)
	}
	libc.memmove(rawptr(&y.key[0]), rawptr(&y.key[1]), C.size_t(y.n - 1) * 40)
	if y.level != 0 {
		ypb := uintptr(y) + uintptr(MTNODE_PTR_OFF)
		ymb := uintptr(y) + uintptr(MTNODE_META_OFF)
		libc.memmove(rawptr(ypb), rawptr(ypb + 8), C.size_t(y.n) * 8)
		libc.memmove(rawptr(ymb), rawptr(ymb + 20), C.size_t(y.n) * 20)
		for j: C.int = 0; j < y.n; j += 1 {
			(^MTNode_O)(node_ptr_o(y, j)).p_idx = i16(j)
		}
	}
	x.n += 1
	y.n -= 1
	if x.level != 0 {
		d := Intersection_O{}
		kvi_init_o(&d)
		xn := (^MTNode_O)(node_ptr_o(x, x.n))
		intersect_mov_o(&y.intersect, &x.intersect, &xn.intersect, &d)
		if d.size != 0 {
			for xi: C.int = 0; xi < x.n; xi += 1 {
				intersect_add_o(&((^MTNode_O)(node_ptr_o(x, xi))).intersect, &d)
			}
		}
		kvi_destroy_o(&d)
		bubble_up_o(y)
	} else {
		if mt_start_o(p.key[int(i)]) {
			pi := pseudo_index_o(y, 0)
			end_id := mt_lookup_key_side_o(p.key[int(i)], true)
			pi_end := pseudo_index_for_id_o(b, end_id, true)
			if pi_end > pi {
				intersect_node_o(b, y, mt_lookup_key_o(p.key[int(i)]))
			}
		}
		if mt_end_o(x.key[int(x.n) - 1]) {
			unintersect_node_o(b, x, mt_lookup_key_side_o(x.key[int(x.n) - 1], false), false)
		}
	}
	_ = p_pos
}

// dest overwritten (assumed freed/moved); src consumed.
@(export)
kvi_move :: proc "c" (dest: ^Intersection_O, src: ^Intersection_O) {
	context = runtime.default_context()
	dest.size = src.size
	dest.capacity = src.capacity
	if src.items == &src.init_array[0] {
		libc.memcpy(rawptr(&dest.init_array[0]), rawptr(src.items), C.size_t(src.size) * 8)
		dest.items = &dest.init_array[0]
	} else {
		dest.items = src.items
	}
}

@(export)
marktree_del_itr :: proc "c" (b_raw: rawptr, itr_raw: rawptr, rev: bool) -> u64 {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	adjustment: C.int = 0
	cur := (^MTNode_O)(itr.x)
	curi := itr.i
	id := mt_lookup_key_o(cur.key[int(curi)])
	raw := mt_itr_rawkey_o(itr)^
	other: u64 = 0
	if mt_paired_o(raw) && (raw.flags & u16(0x08)) == 0 {
		other = mt_lookup_key_side_o(raw, !mt_end_o(raw))
		other_itr := MarkTreeIter_O{}
		marktree_lookup(b_raw, other, rawptr(&other_itr))
		mt_itr_rawkey_o(&other_itr).flags |= u16(0x08)
		if mt_start_o(raw) {
			this_itr := itr^
			marktree_intersect_pair(b_raw, id, rawptr(&this_itr), rawptr(&other_itr), true)
		} else {
			marktree_intersect_pair(b_raw, other, rawptr(&other_itr), itr_raw, true)
		}
	}
	if (^MTNode_O)(itr.x).level != 0 {
		if rev {
			libc.abort()
		} else {
			marktree_itr_prev(b_raw, itr_raw)
			adjustment = -1
		}
	}
	x := (^MTNode_O)(itr.x)
	if x.level != 0 {
		libc.abort()
	}
	intkey := x.key[int(itr.i)]
	meta_inc: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_inc[0])), intkey)
	if x.n > itr.i + 1 {
		libc.memmove(key_slot_o(x, itr.i), key_slot_o(x, itr.i + 1), C.size_t(x.n - itr.i - 1) * 40)
	}
	x.n -= 1
	b.n_keys -= 1
	map_del_uint64_t_ptr_t(&b.id2node, id, nil)
	if adjustment == -1 {
		ilvl := itr.lvl - 1
		lnode := x
		start_id: u64 = 0
		did_bubble := false
		if mt_end_o(intkey) {
			start_id = mt_lookup_key_side_o(intkey, false)
		}
		for {
			p := (^MTNode_O)(lnode.parent)
			if ilvl < 0 {
				libc.abort()
			}
			ii := itr.s[int(ilvl)].i
			if node_ptr_o(p, ii) != rawptr(lnode) {
				libc.abort()
			}
			if ii > 0 {
				unrelative_o(p.key[int(ii) - 1].pos, &intkey.pos)
			}
			if p != cur && start_id != 0 {
				if intersection_has_o(&((^MTNode_O)(node_ptr_o(p, 0))).intersect, start_id) {
					last := 0
					if lnode != x {
						last = 1
					}
					for k: C.int = 0; k < p.n + C.int(last); k += 1 {
						unintersect_node_o(b, (^MTNode_O)(node_ptr_o(p, k)), start_id, true)
					}
					intersect_node_o(b, p, start_id)
					did_bubble = true
				}
			}
			for m in 0 ..< 5 {
				node_meta_set_o(p, C.int(lnode.p_idx), C.int(m), node_meta_o(p, C.int(lnode.p_idx), C.int(m)) - meta_inc[m])
			}
			lnode = p
			ilvl -= 1
			if lnode == cur {
				break
			}
		}
		deleted := cur.key[int(curi)]
		meta_describe_key_o(([^]u32)(rawptr(&meta_inc[0])), deleted)
		cur.key[int(curi)] = intkey
		refkey_o(b, cur, curi)
		if mt_end_o(cur.key[int(curi)]) && !did_bubble {
			pi := pseudo_index_o(x, 0)
			pi_start := pseudo_index_for_id_o(b, start_id, true)
			if pi_start > 0 && pi_start < pi {
				intersect_node_o(b, x, start_id)
			}
		}
		relative_o(intkey.pos, &deleted.pos)
		y := (^MTNode_O)(node_ptr_o(cur, curi + 1))
		if deleted.pos.row != 0 || deleted.pos.col != 0 {
			for y != nil {
				for k: C.int = 0; k < y.n; k += 1 {
					unrelative_o(deleted.pos, &y.key[int(k)].pos)
				}
				if y.level != 0 {
					y = (^MTNode_O)(node_ptr_o(y, 0))
				} else {
					y = nil
				}
			}
		}
		itr.i -= 1
	}
	lnode := cur
	for lnode.parent != nil {
		meta_p := node_meta_row_o((^MTNode_O)(lnode.parent), C.int(lnode.p_idx))
		for m in 0 ..< 5 {
			meta_p[uintptr(m)] -= meta_inc[m]
		}
		lnode = (^MTNode_O)(lnode.parent)
	}
	for m in 0 ..< 5 {
		if b.meta_root[m] < meta_inc[m] {
			libc.abort()
		}
		b.meta_root[m] -= meta_inc[m]
	}
	itr_dirty := false
	rlvl := itr.lvl - 1
	lasti := &itr.i
	ppos := itr.pos
	for x != (^MTNode_O)(b.root) {
		if rlvl < 0 {
			libc.abort()
		}
		p := (^MTNode_O)(x.parent)
		if x.n >= 9 {
			break
		}
		pi := itr.s[int(rlvl)].i
		if node_ptr_o(p, pi) != rawptr(x) {
			libc.abort()
		}
		if pi > 0 {
			ppos.row -= p.key[int(pi) - 1].pos.row
			ppos.col = C.int32_t(itr.s[int(rlvl)].oldcol)
		}
		if pi > 0 && (^MTNode_O)(node_ptr_o(p, pi - 1)).n > 9 {
			lasti^ += 1
			itr_dirty = true
			pivot_right_o(b, ppos, p, pi - 1)
			break
		} else if pi < p.n && (^MTNode_O)(node_ptr_o(p, pi + 1)).n > 9 {
			pivot_left_o(b, ppos, p, pi)
			break
		} else if pi > 0 {
			if (^MTNode_O)(node_ptr_o(p, pi - 1)).n != 9 {
				libc.abort()
			}
			lasti^ += 10
			x = merge_node_o(b, p, pi - 1)
			if lasti == &itr.i {
				itr.x = rawptr(x)
			}
			itr.s[int(rlvl)].i -= 1
			itr_dirty = true
		} else {
			if !(pi < p.n && (^MTNode_O)(node_ptr_o(p, pi + 1)).n == 9) {
				libc.abort()
			}
			merge_node_o(b, p, pi)
		}
		lasti = &itr.s[int(rlvl)].i
		rlvl -= 1
		x = p
	}
	if (^MTNode_O)(b.root).n == 0 {
		if itr.lvl > 0 {
			libc.memmove(rawptr(&itr.s[0]), rawptr(&itr.s[1]), C.size_t(itr.lvl - 1) * 8)
			itr.lvl -= 1
		}
		if (^MTNode_O)(b.root).level != 0 {
			oldroot := (^MTNode_O)(b.root)
			b.root = node_ptr_o(oldroot, 0)
			for m in 0 ..< 5 {
				if b.meta_root[m] != node_meta_o(oldroot, 0, C.int(m)) {
					libc.abort()
				}
			}
			(^MTNode_O)(b.root).parent = nil
			marktree_free_node_o(b, oldroot)
		} else {
			itr.x = nil
		}
	}
	if itr.x != nil && itr_dirty {
		marktree_itr_fix_pos_o(b_raw, itr_raw)
	}
	if adjustment == -1 {
		marktree_itr_next(b_raw, itr_raw)
		marktree_itr_next(b_raw, itr_raw)
	} else {
		if itr.x != nil && itr.i >= (^MTNode_O)(itr.x).n {
			if (^MTNode_O)(itr.x).level != 0 {
				libc.abort()
			}
			marktree_itr_next(b_raw, itr_raw)
		}
	}
	return other
}

@(export)
marktree_revise_meta :: proc "c" (b_raw: rawptr, itr_raw: rawptr, old_key: MTKey_O) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	meta_old: [5]u32
	meta_new: [5]u32
	meta_describe_key_o(([^]u32)(rawptr(&meta_old[0])), old_key)
	meta_describe_key_o(([^]u32)(rawptr(&meta_new[0])), mt_itr_rawkey_o(itr)^)
	if libc.memcmp(rawptr(&meta_old[0]), rawptr(&meta_new[0]), 20) != 0 {
		lnode := (^MTNode_O)(itr.x)
		for lnode.parent != nil {
			meta_p := node_meta_row_o((^MTNode_O)(lnode.parent), C.int(lnode.p_idx))
			for m in 0 ..< 5 {
				meta_p[uintptr(m)] += meta_new[m] - meta_old[m]
			}
			lnode = (^MTNode_O)(lnode.parent)
		}
		for m in 0 ..< 5 {
			b.meta_root[m] += meta_new[m] - meta_old[m]
		}
	}
}

marktree_free_node_o :: proc "c" (b: ^MarkTree_O, x: ^MTNode_O) {
	context = runtime.default_context()
	kvi_destroy_o(&x.intersect)
	xfree(rawptr(x))
	b.n_nodes -= 1
}

// Frees all memory, resets tree to valid empty state.
@(export)
marktree_clear :: proc "c" (b_raw: rawptr) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	if b.root != nil {
		marktree_free_subtree(b_raw, b.root)
		b.root = nil
	}
	xfree(rawptr(b.id2node.set.h.hash))
	xfree(rawptr(b.id2node.set.keys))
	b.id2node.set = Set_uint64_t{}
	xfree(rawptr(b.id2node.values))
	b.id2node.values = nil
	b.n_keys = 0
	libc.memset(rawptr(&b.meta_root[0]), 0, 20)
	if b.n_nodes != 0 {
		libc.abort()
	}
}

@(export)
marktree_free_subtree :: proc "c" (b_raw: rawptr, x_raw: rawptr) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	x := (^MTNode_O)(x_raw)
	if x.level != 0 {
		for i: C.int = 0; i < x.n + 1; i += 1 {
			marktree_free_subtree(b_raw, node_ptr_o(x, i))
		}
	}
	marktree_free_node_o(b, x)
}

// Iterator is invalid after call.
@(export)
marktree_move :: proc "c" (b_raw: rawptr, itr_raw: rawptr, row: C.int, col: C.int) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	key := mt_itr_rawkey_o(itr)^
	x := (^MTNode_O)(itr.x)
	if x.level == 0 {
		internal := false
		newpos := MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}
		if x.parent != nil {
			if pos_less_o(itr.pos, newpos) {
				relative_o(itr.pos, &newpos)
				if pos_less_o(newpos, x.key[int(x.n) - 1].pos) {
					internal = true
				}
			}
		} else {
			internal = true
		}
		if internal {
			if key.pos.row == newpos.row && key.pos.col == newpos.col {
				return
			}
			key.pos = newpos
			match := false
			new_i := marktree_getp_aux_o(x, key, &match)
			if !match {
				new_i += 1
			}
			if new_i == itr.i {
				x.key[int(itr.i)].pos = newpos
			} else if new_i < itr.i {
				libc.memmove(key_slot_o(x, new_i + 1), key_slot_o(x, new_i), C.size_t(itr.i - new_i) * 40)
				x.key[int(new_i)] = key
			} else if new_i > itr.i {
				libc.memmove(key_slot_o(x, itr.i), key_slot_o(x, itr.i + 1), C.size_t(new_i - itr.i - 1) * 40)
				x.key[int(new_i) - 1] = key
			}
			return
		}
	}
	other := marktree_del_itr(b_raw, itr_raw, false)
	key.pos = MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}
	marktree_put_key(b_raw, key)
	if other != 0 {
		marktree_restore_pair(b_raw, key)
	}
	itr.x = nil
	_ = b
}

@(export)
marktree_restore_pair :: proc "c" (b_raw: rawptr, key: MTKey_O) {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	end_itr := MarkTreeIter_O{}
	marktree_lookup(b_raw, mt_lookup_key_side_o(key, false), rawptr(&itr))
	marktree_lookup(b_raw, mt_lookup_key_side_o(key, true), rawptr(&end_itr))
	if itr.x == nil || end_itr.x == nil {
		return
	}
	mt_itr_rawkey_o(&itr).flags &= ~u16(0x08)
	mt_itr_rawkey_o(&end_itr).flags &= ~u16(0x08)
	marktree_intersect_pair(b_raw, mt_lookup_key_side_o(key, false), rawptr(&itr), rawptr(&end_itr), false)
}

@(export)
marktree_itr_get :: proc "c" (b_raw: rawptr, row: C.int32_t, col: C.int, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	return marktree_itr_get_ext(b_raw, MTPos_O{row = row, col = C.int32_t(col)}, itr_raw, false, false, nil, nil)
}

@(export)
marktree_itr_get_ext :: proc "c" (b_raw: rawptr, p: MTPos_O, itr_raw: rawptr, last: bool, gravity: bool, oldbase_raw: rawptr, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	if b.n_keys == 0 {
		itr.x = nil
		return false
	}
	kk := MTKey_O{pos = p}
	if gravity {
		kk.flags = u16(0x4000)
	}
	if last && !gravity {
		kk.flags = u16(0x8000)
	}
	itr.pos = MTPos_O{}
	itr.x = b.root
	itr.lvl = 0
	if oldbase_raw != nil {
		([^]MTPos_O)(oldbase_raw)[uintptr(itr.lvl)] = itr.pos
	}
	for {
		itr.i = marktree_getp_aux_o((^MTNode_O)(itr.x), kk, nil) + 1
		if (^MTNode_O)(itr.x).level == 0 {
			break
		}
		if meta_filter != nil {
			if !meta_has_o(node_meta_row_o((^MTNode_O)(itr.x), itr.i), meta_filter) {
				break
			}
		}
		itr.s[int(itr.lvl)].i = itr.i
		itr.s[int(itr.lvl)].oldcol = C.int(itr.pos.col)
		if itr.i > 0 {
			kp := (^MTNode_O)(itr.x).key[int(itr.i) - 1].pos
			compose_o(&itr.pos, kp)
			relative_o(kp, &kk.pos)
		}
		itr.x = node_ptr_o((^MTNode_O)(itr.x), itr.i)
		itr.lvl += 1
		if oldbase_raw != nil {
			([^]MTPos_O)(oldbase_raw)[uintptr(itr.lvl)] = itr.pos
		}
	}
	if last {
		return marktree_itr_prev(b_raw, itr_raw)
	} else if itr.i >= (^MTNode_O)(itr.x).n {
		return marktree_itr_next_skip_o(b_raw, itr_raw, true, false, nil, nil)
	}
	return true
}

@(export)
marktree_itr_first :: proc "c" (b_raw: rawptr, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	if b.n_keys == 0 {
		itr.x = nil
		return false
	}
	itr.x = b.root
	itr.i = 0
	itr.lvl = 0
	itr.pos = MTPos_O{}
	for (^MTNode_O)(itr.x).level > 0 {
		itr.s[int(itr.lvl)].i = 0
		itr.s[int(itr.lvl)].oldcol = 0
		itr.lvl += 1
		itr.x = node_ptr_o((^MTNode_O)(itr.x), 0)
	}
	return true
}

@(export)
marktree_itr_last :: proc "c" (b_raw: rawptr, itr_raw: rawptr) -> C.int {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	if b.n_keys == 0 {
		itr.x = nil
		return 0
	}
	itr.pos = MTPos_O{}
	itr.x = b.root
	itr.lvl = 0
	for {
		itr.i = (^MTNode_O)(itr.x).n
		if (^MTNode_O)(itr.x).level == 0 {
			break
		}
		itr.s[int(itr.lvl)].i = itr.i
		itr.s[int(itr.lvl)].oldcol = C.int(itr.pos.col)
		if itr.i <= 0 {
			libc.abort()
		}
		kp := (^MTNode_O)(itr.x).key[int(itr.i) - 1].pos
		compose_o(&itr.pos, kp)
		itr.x = node_ptr_o((^MTNode_O)(itr.x), itr.i)
		itr.lvl += 1
	}
	itr.i -= 1
	return 1
}

@(export)
marktree_itr_next :: proc "c" (b_raw: rawptr, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	return marktree_itr_next_skip_o(b_raw, itr_raw, false, false, nil, nil)
}

marktree_itr_next_skip_o :: proc "c" (b_raw: rawptr, itr_raw: rawptr, skip: bool, preload: bool, oldbase_raw: rawptr, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	if itr.x == nil {
		return false
	}
	sk := skip
	itr.i += 1
	if meta_filter != nil && (^MTNode_O)(itr.x).level > 0 {
		if !meta_has_o(node_meta_row_o((^MTNode_O)(itr.x), itr.i), meta_filter) {
			sk = true
		}
	}
	if (^MTNode_O)(itr.x).level == 0 || sk {
		if preload && (^MTNode_O)(itr.x).level == 0 && sk {
			itr.i = (^MTNode_O)(itr.x).n
		} else if itr.i < (^MTNode_O)(itr.x).n {
			return true
		}
		for itr.i >= (^MTNode_O)(itr.x).n {
			itr.x = (^MTNode_O)(itr.x).parent
			if itr.x == nil {
				return false
			}
			itr.lvl -= 1
			itr.i = itr.s[int(itr.lvl)].i
			if itr.i > 0 {
				itr.pos.row -= (^MTNode_O)(itr.x).key[int(itr.i) - 1].pos.row
				itr.pos.col = C.int32_t(itr.s[int(itr.lvl)].oldcol)
			}
		}
	} else {
		for (^MTNode_O)(itr.x).level > 0 {
			if itr.i > 0 {
				itr.s[int(itr.lvl)].oldcol = C.int(itr.pos.col)
				kp := (^MTNode_O)(itr.x).key[int(itr.i) - 1].pos
				compose_o(&itr.pos, kp)
			}
			if oldbase_raw != nil && itr.i == 0 {
				([^]MTPos_O)(oldbase_raw)[uintptr(itr.lvl + 1)] = ([^]MTPos_O)(oldbase_raw)[uintptr(itr.lvl)]
			}
			itr.s[int(itr.lvl)].i = itr.i
			if (^MTNode_O)(node_ptr_o((^MTNode_O)(itr.x), itr.i)).parent != itr.x {
				libc.abort()
			}
			itr.lvl += 1
			itr.x = node_ptr_o((^MTNode_O)(itr.x), itr.i)
			if preload && (^MTNode_O)(itr.x).level != 0 {
				itr.i = -1
				break
			}
			itr.i = 0
			if meta_filter != nil && (^MTNode_O)(itr.x).level != 0 {
				if !meta_has_o(node_meta_row_o((^MTNode_O)(itr.x), 0), meta_filter) {
					break
				}
			}
		}
	}
	return true
}

@(export)
marktree_itr_get_filter :: proc "c" (b_raw: rawptr, row: C.int, col: C.int, stop_row: C.int, stop_col: C.int, meta_filter: [^]u32, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	if !meta_has_o(([^]u32)(rawptr(&b.meta_root[0])), meta_filter) {
		return false
	}
	if !marktree_itr_get_ext(b_raw, MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}, itr_raw, false, false, nil, meta_filter) {
		return false
	}
	return marktree_itr_check_filter_o(b_raw, itr_raw, stop_row, stop_col, meta_filter)
}

@(export)
marktree_itr_step_out_filter :: proc "c" (b_raw: rawptr, itr_raw: rawptr, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	if !meta_has_o(([^]u32)(rawptr(&b.meta_root[0])), meta_filter) {
		itr.x = nil
		return false
	}
	for itr.x != nil && (^MTNode_O)(itr.x).parent != nil {
		xn := (^MTNode_O)(itr.x)
		if meta_has_o(node_meta_row_o((^MTNode_O)(xn.parent), C.int(xn.p_idx)), meta_filter) {
			return true
		}
		itr.i = xn.n
		marktree_itr_next_skip_o(b_raw, itr_raw, true, false, nil, nil)
	}
	return itr.x != nil
}

@(export)
marktree_itr_next_filter :: proc "c" (b_raw: rawptr, itr_raw: rawptr, stop_row: C.int, stop_col: C.int, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	if !marktree_itr_next_skip_o(b_raw, itr_raw, false, false, nil, meta_filter) {
		return false
	}
	return marktree_itr_check_filter_o(b_raw, itr_raw, stop_row, stop_col, meta_filter)
}

marktree_itr_check_filter_o :: proc "c" (b_raw: rawptr, itr_raw: rawptr, stop_row: C.int, stop_col: C.int, meta_filter: [^]u32) -> bool {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	stop_pos := MTPos_O{row = C.int32_t(stop_row), col = C.int32_t(stop_col)}
	meta_map := [5]u32{u32(0x1000), u32(0x800), u32(0x400), u32(0x200), u32(0x2000)}
	key_filter: u16 = 0
	for m in 0 ..< 5 {
		key_filter |= u16(meta_map[m] & meta_filter[uintptr(m)])
	}
	for {
		if pos_leq_o(stop_pos, marktree_itr_pos(itr_raw)) {
			itr.x = nil
			return false
		}
		k := mt_itr_rawkey_o(itr)^
		if !mt_end_o(k) && (k.flags & key_filter) != 0 {
			return true
		}
		if !marktree_itr_next_skip_o(b_raw, itr_raw, false, false, nil, meta_filter) {
			return false
		}
	}
}

@(export)
marktree_itr_prev :: proc "c" (b_raw: rawptr, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	if itr.x == nil {
		return false
	}
	if (^MTNode_O)(itr.x).level == 0 {
		itr.i -= 1
		if itr.i >= 0 {
			return true
		}
		for itr.i < 0 {
			itr.x = (^MTNode_O)(itr.x).parent
			if itr.x == nil {
				return false
			}
			itr.lvl -= 1
			itr.i = itr.s[int(itr.lvl)].i - 1
			if itr.i >= 0 {
				itr.pos.row -= (^MTNode_O)(itr.x).key[int(itr.i)].pos.row
				itr.pos.col = C.int32_t(itr.s[int(itr.lvl)].oldcol)
			}
		}
	} else {
		for (^MTNode_O)(itr.x).level > 0 {
			if itr.i > 0 {
				itr.s[int(itr.lvl)].oldcol = C.int(itr.pos.col)
				kp := (^MTNode_O)(itr.x).key[int(itr.i) - 1].pos
				compose_o(&itr.pos, kp)
			}
			itr.s[int(itr.lvl)].i = itr.i
			if (^MTNode_O)(node_ptr_o((^MTNode_O)(itr.x), itr.i)).parent != itr.x {
				libc.abort()
			}
			itr.x = node_ptr_o((^MTNode_O)(itr.x), itr.i)
			itr.i = (^MTNode_O)(itr.x).n
			itr.lvl += 1
		}
		itr.i -= 1
	}
	_ = b_raw
	return true
}

@(export)
marktree_itr_node_done :: proc "c" (itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	return itr.x == nil || itr.i == (^MTNode_O)(itr.x).n - 1
}

@(export)
marktree_itr_pos :: proc "c" (itr_raw: rawptr) -> MTPos_O {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	pos := mt_itr_rawkey_o(itr).pos
	unrelative_o(itr.pos, &pos)
	return pos
}

@(export)
marktree_itr_current :: proc "c" (itr_raw: rawptr) -> MTKey_O {
	context = runtime.default_context()
	itr := (^MarkTreeIter_O)(itr_raw)
	if itr.x != nil {
		key := mt_itr_rawkey_o(itr)^
		key.pos = marktree_itr_pos(itr_raw)
		return key
	}
	return MTKey_O{pos = MTPos_O{row = -1, col = -1}}
}

itr_eq_o :: proc "c" (itr1: ^MarkTreeIter_O, itr2: ^MarkTreeIter_O) -> bool {
	context = runtime.default_context()
	return mt_itr_rawkey_o(itr1) == mt_itr_rawkey_o(itr2)
}

@(export)
marktree_itr_get_overlap :: proc "c" (b_raw: rawptr, row: C.int, col: C.int, itr_raw: rawptr) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	if b.n_keys == 0 {
		itr.x = nil
		return false
	}
	itr.x = b.root
	itr.i = -1
	itr.lvl = 0
	itr.pos = MTPos_O{}
	itr.intersect_pos = MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}
	itr.intersect_pos_x = MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}
	itr.intersect_idx = 0
	return true
}

@(export)
marktree_itr_step_overlap :: proc "c" (b_raw: rawptr, itr_raw: rawptr, pair: ^MTPair_O) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	for itr.i == -1 {
		xn := (^MTNode_O)(itr.x)
		if itr.intersect_idx < xn.intersect.size {
			id := kvi_A_o(&xn.intersect, itr.intersect_idx)
			itr.intersect_idx += 1
			pair^ = mtpair_from_o(marktree_lookup(b_raw, id, nil), marktree_lookup(b_raw, id | MARKTREE_END_FLAG_O, nil))
			return true
		}
		if xn.level == 0 {
			itr.s[int(itr.lvl)].i = 0
			itr.i = 0
			break
		}
		k := MTKey_O{pos = itr.intersect_pos_x}
		itr.i = marktree_getp_aux_o(xn, k, nil) + 1
		itr.s[int(itr.lvl)].i = itr.i
		itr.s[int(itr.lvl)].oldcol = C.int(itr.pos.col)
		if itr.i > 0 {
			kp := xn.key[int(itr.i) - 1].pos
			compose_o(&itr.pos, kp)
			relative_o(kp, &itr.intersect_pos_x)
		}
		itr.x = node_ptr_o(xn, itr.i)
		itr.lvl += 1
		itr.i = -1
		itr.intersect_idx = 0
	}
	for {
		xn := (^MTNode_O)(itr.x)
		if !(itr.i < xn.n && pos_less_o(mt_itr_rawkey_o(itr).pos, itr.intersect_pos_x)) {
			break
		}
		k := xn.key[int(itr.i)]
		itr.i += 1
		itr.s[int(itr.lvl)].i = itr.i
		if mt_start_o(k) {
			end := marktree_lookup(b_raw, mt_lookup_id_o(k.ns, k.id, true), nil)
			if pos_less_o(end.pos, itr.intersect_pos) {
				continue
			}
			kp := k.pos
			unrelative_o(itr.pos, &kp)
			k.pos = kp
			pair^ = mtpair_from_o(k, end)
			return true
		}
	}
	for {
		xn := (^MTNode_O)(itr.x)
		if !(itr.i < xn.n) {
			break
		}
		k := xn.key[int(itr.i)]
		itr.i += 1
		if mt_end_o(k) {
			id := mt_lookup_id_o(k.ns, k.id, false)
			if id2node_o(b, id) == itr.x {
				continue
			}
			kp := k.pos
			unrelative_o(itr.pos, &kp)
			k.pos = kp
			start := marktree_lookup(b_raw, id, nil)
			if pos_leq_o(itr.intersect_pos, start.pos) {
				continue
			}
			pair^ = mtpair_from_o(start, k)
			return true
		}
	}
	itr.i = itr.s[int(itr.lvl)].i
	if itr.i < 0 {
		libc.abort()
	}
	if itr.i >= (^MTNode_O)(itr.x).n {
		marktree_itr_next(b_raw, itr_raw)
	}
	return false
}

check_damage_o :: proc "c" (b: ^MarkTree_O, damage: ^Map_uint64_t_MTDamagePair, itr1: ^MarkTreeIter_O, itr2: ^MarkTreeIter_O) {
	context = runtime.default_context()
	start_id := mt_lookup_key_side_o(mt_itr_rawkey_o(itr1)^, false)
	p := map_put_ref_uint64_t_MTDamagePair(damage, start_id, nil, nil)
	me := &p.start
	if mt_end_o(mt_itr_rawkey_o(itr1)^) {
		me = &p.end
	}
	if me.new != nil {
		libc.abort()
	}
	me^ = MTDamage{old = itr1.x, new = itr2.x, old_i = itr1.i, new_i = itr2.i}
}

swap_keys_o :: proc "c" (b: ^MarkTree_O, itr1: ^MarkTreeIter_O, itr2: ^MarkTreeIter_O, damage: ^Map_uint64_t_MTDamagePair) {
	context = runtime.default_context()
	if itr1.x != itr2.x || (^MTNode_O)(itr1.x).level != 0 {
		if mt_paired_o(mt_itr_rawkey_o(itr1)^) {
			check_damage_o(b, damage, itr1, itr2)
		}
		if mt_paired_o(mt_itr_rawkey_o(itr2)^) {
			check_damage_o(b, damage, itr2, itr1)
		}
	}
	if itr1.x != itr2.x {
		meta_inc_1: [5]u32
		meta_describe_key_o(([^]u32)(rawptr(&meta_inc_1[0])), mt_itr_rawkey_o(itr1)^)
		meta_inc_2: [5]u32
		meta_describe_key_o(([^]u32)(rawptr(&meta_inc_2[0])), mt_itr_rawkey_o(itr2)^)
		if libc.memcmp(rawptr(&meta_inc_1[0]), rawptr(&meta_inc_2[0]), 20) != 0 {
			x1 := (^MTNode_O)(itr1.x)
			x2 := (^MTNode_O)(itr2.x)
			for x1 != x2 {
				if x1.level <= x2.level {
					meta_node := node_meta_row_o((^MTNode_O)(x1.parent), C.int(x1.p_idx))
					for m in 0 ..< 5 {
						meta_node[uintptr(m)] += meta_inc_2[m] - meta_inc_1[m]
					}
					x1 = (^MTNode_O)(x1.parent)
				}
				if x2.level < x1.level {
					meta_node := node_meta_row_o((^MTNode_O)(x2.parent), C.int(x2.p_idx))
					for m in 0 ..< 5 {
						meta_node[uintptr(m)] += meta_inc_1[m] - meta_inc_2[m]
					}
					x2 = (^MTNode_O)(x2.parent)
				}
			}
		}
	}
	key1 := mt_itr_rawkey_o(itr1)^
	key2 := mt_itr_rawkey_o(itr2)^
	mt_itr_rawkey_o(itr1)^ = key2
	mt_itr_rawkey_o(itr1).pos = key1.pos
	mt_itr_rawkey_o(itr2)^ = key1
	mt_itr_rawkey_o(itr2).pos = key2.pos
	refkey_o(b, (^MTNode_O)(itr1.x), itr1.i)
	refkey_o(b, (^MTNode_O)(itr2.x), itr2.i)
}

@(export)
marktree_splice :: proc "c" (b_raw: rawptr, start_line: C.int32_t, start_col: C.int, old_extent_line: C.int, old_extent_col: C.int, new_extent_line: C.int, new_extent_col: C.int) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	start := MTPos_O{row = start_line, col = C.int32_t(start_col)}
	old_extent := MTPos_O{row = C.int32_t(old_extent_line), col = C.int32_t(old_extent_col)}
	new_extent := MTPos_O{row = C.int32_t(new_extent_line), col = C.int32_t(new_extent_col)}
	may_delete := old_extent.row != 0 || old_extent.col != 0
	same_line := old_extent.row == 0 && new_extent.row == 0
	unrelative_o(start, &old_extent)
	unrelative_o(start, &new_extent)
	itr := MarkTreeIter_O{}
	enditr := MarkTreeIter_O{}
	oldbase: [20]MTPos_O
	marktree_itr_get_ext(b_raw, start, rawptr(&itr), false, true, rawptr(&oldbase[0]), nil)
	if itr.x == nil {
		return false
	}
	delta := MTPos_O{row = new_extent.row - old_extent.row, col = new_extent.col - old_extent.col}
	if may_delete {
		ipos := marktree_itr_pos(rawptr(&itr))
		if !pos_leq_o(old_extent, ipos) || (old_extent.row == ipos.row && old_extent.col == ipos.col && !mt_right_o(mt_itr_rawkey_o(&itr)^)) {
			marktree_itr_get_ext(b_raw, old_extent, rawptr(&enditr), true, true, nil, nil)
			if enditr.x == nil {
				libc.abort()
			}
		} else {
			may_delete = false
		}
	}
	past_right := false
	moved := false
	damage := Map_uint64_t_MTDamagePair{}
	if may_delete {
		outer_done1 := false
		for (^MTNode_O)(itr.x) != nil && !past_right && !outer_done1 {
			loc_start := start
			loc_old := old_extent
			it := (^MarkTreeIter_O)(rawptr(&itr))
			relative_o(it.pos, &loc_start)
			relative_o(oldbase[int(it.lvl)], &loc_old)
			for {
				if !pos_leq_o(mt_itr_rawkey_o(it).pos, loc_old) {
					outer_done1 = true
					break
				}
				if mt_right_o(mt_itr_rawkey_o(it)^) {
					for !itr_eq_o(it, &enditr) && mt_right_o(mt_itr_rawkey_o(&enditr)^) {
						marktree_itr_prev(b_raw, rawptr(&enditr))
					}
					if !mt_right_o(mt_itr_rawkey_o(&enditr)^) {
						swap_keys_o(b, it, &enditr, &damage)
					} else {
						past_right = true
						break
					}
				}
				if itr_eq_o(it, &enditr) {
					past_right = true
				}
				moved = true
				if (^MTNode_O)(it.x).level != 0 {
					oldbase[int(it.lvl) + 1] = mt_itr_rawkey_o(it).pos
					unrelative_o(oldbase[int(it.lvl)], &oldbase[int(it.lvl) + 1])
					mt_itr_rawkey_o(it).pos = loc_start
					marktree_itr_next_skip_o(b_raw, rawptr(it), false, false, rawptr(&oldbase[0]), nil)
					break
				} else {
					mt_itr_rawkey_o(it).pos = loc_start
					if it.i < (^MTNode_O)(it.x).n - 1 {
						it.i += 1
						if !past_right {
							continue
						}
					} else {
						marktree_itr_next(b_raw, rawptr(it))
					}
					break
				}
			}
		}
		outer_done := false
		for (^MTNode_O)(itr.x) != nil && !outer_done {
			it := (^MarkTreeIter_O)(rawptr(&itr))
			loc_new := new_extent
			relative_o(it.pos, &loc_new)
			limit := old_extent
			relative_o(oldbase[int(it.lvl)], &limit)
			for {
				if pos_leq_o(limit, mt_itr_rawkey_o(it).pos) {
					outer_done = true
					break
				}
				oldpos := mt_itr_rawkey_o(it).pos
				mt_itr_rawkey_o(it).pos = loc_new
				moved = true
				if (^MTNode_O)(it.x).level != 0 {
					oldbase[int(it.lvl) + 1] = oldpos
					unrelative_o(oldbase[int(it.lvl)], &oldbase[int(it.lvl) + 1])
					marktree_itr_next_skip_o(b_raw, rawptr(it), false, false, rawptr(&oldbase[0]), nil)
					break
				} else {
					if it.i < (^MTNode_O)(it.x).n - 1 {
						it.i += 1
						continue
					} else {
						marktree_itr_next(b_raw, rawptr(it))
						break
					}
				}
			}
		}
	}
	for (^MTNode_O)(itr.x) != nil {
		it := (^MarkTreeIter_O)(rawptr(&itr))
		unrelative_o(oldbase[int(it.lvl)], &mt_itr_rawkey_o(it).pos)
		realrow := mt_itr_rawkey_o(it).pos.row
		if realrow < old_extent.row {
			libc.abort()
		}
		done := false
		if realrow == old_extent.row {
			if delta.col != 0 {
				mt_itr_rawkey_o(it).pos.col += delta.col
			}
		} else {
			if same_line {
				done = true
			}
		}
		if delta.row != 0 {
			mt_itr_rawkey_o(it).pos.row += delta.row
			moved = true
		}
		relative_o(it.pos, &mt_itr_rawkey_o(it).pos)
		if done {
			break
		}
		marktree_itr_next_skip_o(b_raw, rawptr(it), true, false, nil, nil)
	}
	dm := &damage
	for di: u32 = 0; di < dm.set.h.n_keys; di += 1 {
		start_id := dm.set.keys[uintptr(di)]
		d := dm.values[uintptr(di)]
		if d.start.old != nil && d.end.old != nil {
			marktree_itr_set_node(b_raw, rawptr(&itr), d.start.old, d.start.old_i)
			marktree_itr_set_node(b_raw, rawptr(&enditr), d.end.old, d.end.old_i)
			marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), true)
			marktree_itr_set_node(b_raw, rawptr(&itr), d.start.new, d.start.new_i)
			marktree_itr_set_node(b_raw, rawptr(&enditr), d.end.new, d.end.new_i)
			marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), false)
		} else if d.start.old != nil {
			endpos := MarkTreeIter_O{}
			marktree_lookup(b_raw, start_id | MARKTREE_END_FLAG_O, rawptr(&endpos))
			if endpos.x != nil {
				marktree_itr_set_node(b_raw, rawptr(&itr), d.start.old, d.start.old_i)
				enditr = endpos
				marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), true)
				marktree_itr_set_node(b_raw, rawptr(&itr), d.start.new, d.start.new_i)
				enditr = endpos
				marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), false)
			}
		} else if d.end.old != nil {
			startpos := MarkTreeIter_O{}
			marktree_lookup(b_raw, start_id, rawptr(&startpos))
			if startpos.x != nil {
				itr = startpos
				marktree_itr_set_node(b_raw, rawptr(&enditr), d.end.old, d.end.old_i)
				marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), true)
				itr = startpos
				marktree_itr_set_node(b_raw, rawptr(&enditr), d.end.new, d.end.new_i)
				marktree_intersect_pair(b_raw, start_id, rawptr(&itr), rawptr(&enditr), false)
			}
		}
	}
	xfree(rawptr(dm.set.h.hash))
	xfree(rawptr(dm.set.keys))
	dm.set = Set_uint64_t{}
	xfree(rawptr(dm.values))
	dm.values = nil
	return moved
}

@(export)
marktree_move_region :: proc "c" (b_raw: rawptr, start_row: C.int, start_col: C.int, extent_row: C.int, extent_col: C.int, new_row: C.int, new_col: C.int) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	start := MTPos_O{row = C.int32_t(start_row), col = C.int32_t(start_col)}
	size := MTPos_O{row = C.int32_t(extent_row), col = C.int32_t(extent_col)}
	end := size
	unrelative_o(start, &end)
	itr := MarkTreeIter_O{}
	marktree_itr_get_ext(b_raw, start, rawptr(&itr), false, true, nil, nil)
	saved_items: [^]MTKey_O = nil
	saved_n: C.size_t = 0
	saved_a: C.size_t = 0
	for (^MTNode_O)(itr.x) != nil {
		k := marktree_itr_current(rawptr(&itr))
		if !pos_leq_o(k.pos, end) || (k.pos.row == end.row && k.pos.col == end.col && mt_right_o(k)) {
			break
		}
		relative_o(start, &k.pos)
		if saved_n == saved_a {
			if saved_a == 0 {
				saved_a = 4
			} else {
				saved_a *= 2
			}
			saved_items = ([^]MTKey_O)(xrealloc(rawptr(saved_items), C.size_t(saved_a) * 40))
		}
		saved_items[uintptr(saved_n)] = k
		saved_n += 1
		marktree_del_itr(b_raw, rawptr(&itr), false)
	}
	marktree_splice(b_raw, start.row, C.int(start.col), size.row, C.int(size.col), 0, 0)
	new := MTPos_O{row = C.int32_t(new_row), col = C.int32_t(new_col)}
	marktree_splice(b_raw, new.row, C.int(new.col), 0, 0, size.row, C.int(size.col))
	i: C.size_t = 0
	for i < saved_n {
		item := saved_items[uintptr(i)]
		unrelative_o(new, &item.pos)
		marktree_put_key(b_raw, item)
		if mt_paired_o(item) {
			marktree_restore_pair(b_raw, item)
		}
		i += 1
	}
	xfree(rawptr(saved_items))
	_ = b
}

// for unit test
@(export)
marktree_put_test :: proc "c" (b_raw: rawptr, ns: u32, id: u32, row: C.int, col: C.int, right_gravity: bool, end_row: C.int, end_col: C.int, end_right: bool, meta_inline: bool) {
	context = runtime.default_context()
	flags := mt_flags_o(right_gravity, false, false, false)
	if meta_inline {
		flags |= u16(0x1000)
	}
	key := MTKey_O{pos = MTPos_O{row = C.int32_t(row), col = C.int32_t(col)}, ns = ns, id = id, flags = flags}
	marktree_put(b_raw, key, end_row, end_col, end_right)
}

// for unit test
@(export)
mt_right_test :: proc "c" (key: MTKey_O) -> bool {
	context = runtime.default_context()
	return mt_right_o(key)
}

// for unit test
@(export)
marktree_del_pair_test :: proc "c" (b_raw: rawptr, ns: u32, id: u32) {
	context = runtime.default_context()
	itr := MarkTreeIter_O{}
	marktree_lookup_ns(b_raw, ns, id, false, rawptr(&itr))
	other := marktree_del_itr(b_raw, rawptr(&itr), false)
	if other == 0 {
		libc.abort()
	}
	marktree_lookup(b_raw, other, rawptr(&itr))
	marktree_del_itr(b_raw, rawptr(&itr), false)
}

@(export)
marktree_check :: proc "c" (b_raw: rawptr) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	if b.root == nil {
		if b.n_keys != 0 {
			libc.abort()
		}
		if b.n_nodes != 0 {
			libc.abort()
		}
		if b.id2node.set.h.n_keys != 0 {
			libc.abort()
		}
		return
	}
	dummy := MTPos_O{}
	last_right := false
	nkeys := marktree_check_node_o(b_raw, b.root, &dummy, &last_right, ([^]u32)(rawptr(&b.meta_root[0])))
	if b.n_keys != nkeys {
		libc.abort()
	}
	if b.n_keys != C.size_t(b.id2node.set.h.n_keys) {
		libc.abort()
	}
}

marktree_check_node_o :: proc "c" (b_raw: rawptr, x_raw: rawptr, last: ^MTPos_O, last_right: ^bool, meta_node_ref: [^]u32) -> C.size_t {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	x := (^MTNode_O)(x_raw)
	if x.n > 19 {
		libc.abort()
	}
	min_n: C.int = 0
	if x != (^MTNode_O)(b.root) {
		min_n = 9
	}
	if x.n < min_n {
		libc.abort()
	}
	n_keys: C.size_t = C.size_t(x.n)
	for i: C.int = 0; i < x.n; i += 1 {
		if x.level != 0 {
			n_keys += marktree_check_node_o(b_raw, node_ptr_o(x, i), last, last_right, node_meta_row_o(x, i))
		} else {
			last^ = MTPos_O{}
		}
		if i > 0 {
			unrelative_o(x.key[int(i) - 1].pos, last)
		}
		if !pos_leq_o(last^, x.key[int(i)].pos) {
			libc.abort()
		}
		if last.row == x.key[int(i)].pos.row && last.col == x.key[int(i)].pos.col {
			if last_right^ && !mt_right_o(x.key[int(i)]) {
				libc.abort()
			}
		}
		last_right^ = mt_right_o(x.key[int(i)])
		if x.key[int(i)].pos.col < 0 {
			libc.abort()
		}
		if id2node_o(b, mt_lookup_key_o(x.key[int(i)])) != rawptr(x) {
			libc.abort()
		}
	}
	if x.level != 0 {
		n_keys += marktree_check_node_o(b_raw, node_ptr_o(x, x.n), last, last_right, node_meta_row_o(x, x.n))
		unrelative_o(x.key[int(x.n) - 1].pos, last)
		for i: C.int = 0; i < x.n + 1; i += 1 {
			ch := (^MTNode_O)(node_ptr_o(x, i))
			if ch.parent != rawptr(x) {
				libc.abort()
			}
			if ch.p_idx != i16(i) {
				libc.abort()
			}
			if ch.level != x.level - 1 {
				libc.abort()
			}
			for j: C.int = 0; j < i; j += 1 {
				if node_ptr_o(x, i) == node_ptr_o(x, j) {
					libc.abort()
				}
			}
		}
	} else if x.n > 0 {
		last^ = x.key[int(x.n) - 1].pos
	}
	meta_node: [5]u32
	meta_describe_node_o(([^]u32)(rawptr(&meta_node[0])), x)
	for m in 0 ..< 5 {
		if meta_node_ref[uintptr(m)] != meta_node[m] {
			libc.abort()
		}
	}
	return n_keys
}

@(export)
marktree_check_intersections :: proc "c" (b_raw: rawptr) -> bool {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	if b.root == nil {
		return true
	}
	checked := Map_ptr_t_ptr_t{}
	mt_recurse_nodes(b.root, rawptr(&checked))
	itr := MarkTreeIter_O{}
	marktree_itr_first(b_raw, rawptr(&itr))
	for {
		mark := marktree_itr_current(rawptr(&itr))
		if C.int(mark.pos.row) < 0 {
			break
		}
		if mt_start_o(mark) {
			start_itr := MarkTreeIter_O{}
			end_itr := MarkTreeIter_O{}
			end_id := mt_lookup_id_o(mark.ns, mark.id, true)
			k := marktree_lookup(b_raw, end_id, rawptr(&end_itr))
			if C.int(k.pos.row) >= 0 {
				start_itr = itr
				marktree_intersect_pair(b_raw, mt_lookup_key_o(mark), rawptr(&start_itr), rawptr(&end_itr), false)
			}
		}
		marktree_itr_next(b_raw, rawptr(&itr))
	}
	status := mt_recurse_nodes_compare(b.root, rawptr(&checked))
	cm := &checked
	for di: u32 = 0; di < cm.set.h.n_keys; di += 1 {
		xfree(cm.values[uintptr(di)])
	}
	xfree(rawptr(cm.set.h.hash))
	xfree(rawptr(cm.set.keys))
	cm.set = Set_ptr_t{}
	xfree(rawptr(cm.values))
	cm.values = nil
	return status
}

checked_get_o :: proc "c" (mp: ^Map_ptr_t_ptr_t, key: rawptr) -> rawptr {
	context = runtime.default_context()
	k := mh_get(&mp.set, key, hash_ptr_t, equal_ptr_t)
	if k == MH_TOMBSTONE {
		return nil
	}
	return mp.values[uintptr(k)]
}

@(export)
mt_recurse_nodes :: proc "c" (x_raw: rawptr, checked_raw: rawptr) {
	context = runtime.default_context()
	x := (^MTNode_O)(x_raw)
	checked := (^Map_ptr_t_ptr_t)(checked_raw)
	if x.intersect.size != 0 {
		kvi_push_o(&x.intersect, max(u64))
		val: ^u64 = nil
		if x.intersect.items == &x.intersect.init_array[0] {
			val = ([^]u64)(xmemdup(rawptr(x.intersect.items), C.size_t(x.intersect.size) * 8))
		} else {
			val = x.intersect.items
		}
		map_put_ref_ptr_t_ptr_t(checked, rawptr(x), nil, nil)^ = rawptr(val)
		kvi_init_o(&x.intersect)
	}
	if x.level != 0 {
		for i: C.int = 0; i < x.n + 1; i += 1 {
			mt_recurse_nodes(node_ptr_o(x, i), checked_raw)
		}
	}
}

@(export)
mt_recurse_nodes_compare :: proc "c" (x_raw: rawptr, checked_raw: rawptr) -> bool {
	context = runtime.default_context()
	x := (^MTNode_O)(x_raw)
	checked := (^Map_ptr_t_ptr_t)(checked_raw)
	ref := ([^]u64)(checked_get_o(checked, rawptr(x)))
	if ref != nil {
		i: C.size_t = 0
		for {
			if ref[uintptr(i)] == max(u64) {
				if i != x.intersect.size {
					return false
				}
				break
			} else {
				if x.intersect.size <= i || ref[uintptr(i)] != kvi_A_o(&x.intersect, i) {
					return false
				}
			}
			i += 1
		}
	} else {
		if x.intersect.size != 0 {
			return false
		}
	}
	if x.level != 0 {
		for i: C.int = 0; i < x.n + 1; i += 1 {
			if !mt_recurse_nodes_compare(node_ptr_o(x, i), checked_raw) {
				return false
			}
		}
	}
	return true
}

mt_inspect_buf_g: [1024]u8

mt_ga_str_o :: proc "c" (gap: ^Garray, s: cstring) {
	context = runtime.default_context()
	n := C.int(libc.strlen(s))
	ga_grow(gap, n)
	libc.memcpy(rawptr(uintptr(gap.ga_data) + uintptr(gap.ga_len)), rawptr(s), C.size_t(n))
	gap.ga_len += n
}

mt_ga_print_o :: proc "c" (gap: ^Garray, fmt: cstring, a: u64, b: u64, c: u64) {
	context = runtime.default_context()
	libc.snprintf(&mt_inspect_buf_g[0], 1024, fmt, a, b, c)
	mt_ga_str_o(gap, transmute(cstring)(&mt_inspect_buf_g[0]))
}

@(export)
mt_inspect :: proc "c" (b_raw: rawptr, keys: bool, dot: bool) -> Api_String {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	ga := Garray{}
	ga_init(&ga, 1, 80)
	p := MTPos_O{}
	if b.root != nil {
		if dot {
			mt_ga_str_o(&ga, cstring("digraph D {\n\n"))
			mt_inspect_dotfile_node_o(b_raw, &ga, b.root, p, nil)
			mt_ga_str_o(&ga, cstring("\n}"))
		} else {
			mt_inspect_node_o(b_raw, &ga, keys, b.root, p)
		}
	}
	s := Api_String{data = (^u8)(ga.ga_data), size = C.size_t(ga.ga_len)}
	ga.ga_data = nil
	ga.ga_len = 0
	ga.ga_maxlen = 0
	return s
}

mt_dbg_id_o :: proc "c" (id: u64) -> u64 {
	context = runtime.default_context()
	return (id >> 1) & 0xffffffff
}

mt_inspect_node_o :: proc "c" (b_raw: rawptr, ga: ^Garray, keys: bool, n_raw: rawptr, off: MTPos_O) {
	context = runtime.default_context()
	n := (^MTNode_O)(n_raw)
	mt_ga_str_o(ga, cstring("["))
	if keys && n.intersect.size != 0 {
		i: C.size_t = 0
		for i < n.intersect.size {
			if i == 0 {
				mt_ga_str_o(ga, cstring("{"))
			} else {
				mt_ga_str_o(ga, cstring(";"))
			}
			mt_ga_print_o(ga, cstring("%llu"), mt_dbg_id_o(kvi_A_o(&n.intersect, i)), 0, 0)
			i += 1
		}
		mt_ga_str_o(ga, cstring("},"))
	}
	if n.level != 0 {
		mt_inspect_node_o(b_raw, ga, keys, node_ptr_o(n, 0), off)
	}
	for i: C.int = 0; i < n.n; i += 1 {
		p := n.key[int(i)].pos
		unrelative_o(off, &p)
		mt_ga_print_o(ga, cstring("%d/%d"), u64(C.int(p.row)), u64(C.int(p.col)), 0)
		if keys {
			key := n.key[int(i)]
			mt_ga_str_o(ga, cstring(":"))
			if mt_start_o(key) {
				mt_ga_str_o(ga, cstring("<"))
			}
			mt_ga_print_o(ga, cstring("%u"), u64(key.id), 0, 0)
			if mt_end_o(key) {
				mt_ga_str_o(ga, cstring(">"))
			}
		}
		if n.level != 0 {
			mt_inspect_node_o(b_raw, ga, keys, node_ptr_o(n, i + 1), p)
		} else {
			mt_ga_str_o(ga, cstring(","))
		}
	}
	mt_ga_str_o(ga, cstring("]"))
	_ = b_raw
}

mt_inspect_dotfile_node_o :: proc "c" (b_raw: rawptr, ga: ^Garray, n_raw: rawptr, off: MTPos_O, parent: cstring) {
	context = runtime.default_context()
	n := (^MTNode_O)(n_raw)
	namebuf: [64]u8
	if parent != nil {
		libc.snprintf(&namebuf[0], 64, cstring("%s_%c%d"), parent, C.int('a') + C.int(n.level), C.int(n.p_idx))
	} else {
		libc.snprintf(&namebuf[0], 64, cstring("MTNode"))
	}
	nm := transmute(cstring)(&namebuf[0])
	libc.snprintf(&mt_inspect_buf_g[0], 1024, cstring("  %s[shape=plaintext, label=<\n"), nm, 0, 0)
	mt_ga_str_o(ga, transmute(cstring)(&mt_inspect_buf_g[0]))
	mt_ga_str_o(ga, cstring("    <table border='0' cellborder='1' cellspacing='0'>\n"))
	if n.intersect.size != 0 {
		mt_ga_str_o(ga, cstring("    <tr><td>"))
		i: C.size_t = 0
		for i < n.intersect.size {
			if i > 0 {
				mt_ga_str_o(ga, cstring(", "))
			}
			mt_ga_print_o(ga, cstring("%llu"), mt_dbg_id_o(kvi_A_o(&n.intersect, i)), 0, 0)
			i += 1
		}
		mt_ga_str_o(ga, cstring("</td></tr>\n"))
	}
	mt_ga_str_o(ga, cstring("    <tr><td>"))
	for i: C.int = 0; i < n.n; i += 1 {
		k := n.key[int(i)]
		if i > 0 {
			mt_ga_str_o(ga, cstring(", "))
		}
		mt_ga_print_o(ga, cstring("%d"), u64(k.id), 0, 0)
		if mt_paired_o(k) {
			if mt_end_o(k) {
				mt_ga_str_o(ga, cstring("e"))
			} else {
				mt_ga_str_o(ga, cstring("s"))
			}
		}
	}
	mt_ga_str_o(ga, cstring("</td></tr>\n"))
	mt_ga_str_o(ga, cstring("    </table>\n"))
	mt_ga_str_o(ga, cstring(">];\n"))
	if parent != nil {
		libc.snprintf(&mt_inspect_buf_g[0], 1024, cstring("  %s -> %s\n"), parent, nm, 0)
		mt_ga_str_o(ga, transmute(cstring)(&mt_inspect_buf_g[0]))
	}
	if n.level != 0 {
		mt_inspect_dotfile_node_o(b_raw, ga, node_ptr_o(n, 0), off, nm)
	}
	for i: C.int = 0; i < n.n; i += 1 {
		p := n.key[int(i)].pos
		unrelative_o(off, &p)
		if n.level != 0 {
			mt_inspect_dotfile_node_o(b_raw, ga, node_ptr_o(n, i + 1), p, nm)
		}
	}
	_ = b_raw
}

@(export)
marktree_lookup_ns :: proc "c" (b_raw: rawptr, ns: u32, id: u32, end: bool, itr_raw: rawptr) -> MTKey_O {
	context = runtime.default_context()
	return marktree_lookup(b_raw, mt_lookup_id_o(ns, id, end), itr_raw)
}

pseudo_index_o :: proc "c" (x: ^MTNode_O, i: C.int) -> u64 {
	context = runtime.default_context()
	off := 5 * C.int(x.level)
	index: u64 = 0
	xx := x
	ii := i
	for xx != nil {
		index |= u64(ii + 1) << u64(off)
		off += 5
		ii = C.int(xx.p_idx)
		xx = (^MTNode_O)(xx.parent)
	}
	return index
}

pseudo_index_for_id_o :: proc "c" (b: ^MarkTree_O, id: u64, sloppy: bool) -> u64 {
	context = runtime.default_context()
	n := (^MTNode_O)(id2node_o(b, id))
	if n == nil {
		return 0
	}
	i: C.int = 0
	if n.level != 0 || !sloppy {
		for i = 0; i < n.n; i += 1 {
			if mt_lookup_key_o(n.key[int(i)]) == id {
				break
			}
		}
		if i >= n.n {
			libc.abort()
		}
		if n.level != 0 {
			i += 1
		}
	}
	return pseudo_index_o(n, i)
}

@(export)
marktree_lookup :: proc "c" (b_raw: rawptr, id: u64, itr_raw: rawptr) -> MTKey_O {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	n := (^MTNode_O)(id2node_o(b, id))
	if n == nil {
		if itr_raw != nil {
			(^MarkTreeIter_O)(itr_raw).x = nil
		}
		return MTKey_O{pos = MTPos_O{row = -1, col = -1}}
	}
	for i: C.int = 0; i < n.n; i += 1 {
		if mt_lookup_key_o(n.key[int(i)]) == id {
			return marktree_itr_set_node(b_raw, itr_raw, rawptr(n), i)
		}
	}
	libc.abort()
}

@(export)
marktree_itr_set_node :: proc "c" (b_raw: rawptr, itr_raw: rawptr, n_raw: rawptr, i: C.int) -> MTKey_O {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	n := (^MTNode_O)(n_raw)
	key := n.key[int(i)]
	if itr_raw != nil {
		itr := (^MarkTreeIter_O)(itr_raw)
		itr.i = i
		itr.x = n_raw
		itr.lvl = C.int((^MTNode_O)(b.root).level - n.level)
	}
	for n.parent != nil {
		p := (^MTNode_O)(n.parent)
		i2 := n.p_idx
		if node_ptr_o(p, C.int(i2)) != rawptr(n) {
			libc.abort()
		}
		if itr_raw != nil {
			(^MarkTreeIter_O)(itr_raw).s[int((^MTNode_O)(b.root).level - p.level)].i = C.int(i2)
		}
		if i2 > 0 {
			unrelative_o(p.key[int(i2) - 1].pos, &key.pos)
		}
		n = p
	}
	if itr_raw != nil {
		marktree_itr_fix_pos_o(b_raw, itr_raw)
	}
	return key
}

@(export)
marktree_get_altpos :: proc "c" (b_raw: rawptr, mark: MTKey_O, itr_raw: rawptr) -> MTPos_O {
	context = runtime.default_context()
	return marktree_get_alt(b_raw, mark, itr_raw).pos
}

@(export)
marktree_get_alt :: proc "c" (b_raw: rawptr, mark: MTKey_O, itr_raw: rawptr) -> MTKey_O {
	context = runtime.default_context()
	if mt_paired_o(mark) {
		end := true
		if mt_end_o(mark) {
			end = false
		}
		return marktree_lookup_ns(b_raw, mark.ns, mark.id, end, itr_raw)
	}
	return mark
}

marktree_itr_fix_pos_o :: proc "c" (b_raw: rawptr, itr_raw: rawptr) {
	context = runtime.default_context()
	b := (^MarkTree_O)(b_raw)
	itr := (^MarkTreeIter_O)(itr_raw)
	itr.pos = MTPos_O{}
	x := (^MTNode_O)(b.root)
	for lvl: C.int = 0; lvl < itr.lvl; lvl += 1 {
		itr.s[int(lvl)].oldcol = C.int(itr.pos.col)
		i := itr.s[int(lvl)].i
		if i > 0 {
			kp := x.key[int(i) - 1].pos
			compose_o(&itr.pos, kp)
		}
		if x.level == 0 {
			libc.abort()
		}
		x = (^MTNode_O)(node_ptr_o(x, i))
	}
	if x != (^MTNode_O)(itr.x) {
		libc.abort()
	}
}
