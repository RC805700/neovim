package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// hashtab.c port (Batch H1): Vim hashtable with perturb-walk lookup.
// Hashtab_T mirror lives in userfunc.odin (cc-probed, #assert 296) — reused.
// All exports take rawptr (ABI-identical to C's hashtab_T*/hashitem_T*),
// so existing rawptr-based callers rewire by rename only.

Hashitem_T :: struct {
	hi_hash: C.size_t,  // @0 (hash_T = size_t)
	hi_key:  ^u8,       // @8
}
#assert(size_of(Hashitem_T) == 16)

HT_INIT_SIZE_O :: 16
PERTURB_SHIFT_O :: 5

// `char hash_removed` global (was C definition; single copy here).
// Only its ADDRESS is ever used (HI_KEY_REMOVED); value stays 0.
@(export)
hash_removed: u8

foreign _ {
	@(link_name = "siemsg")
	siemsg :: proc "c" (s: cstring, #c_vararg args: ..any) ---
}

hashitem_at_o :: proc "c" (arr: rawptr, idx: C.size_t) -> ^Hashitem_T {
	context = runtime.default_context()
	return (^Hashitem_T)(uintptr(arr) + uintptr(idx)*size_of(Hashitem_T))
}

// Empty test: key NULL or removed marker (HASHITEM_EMPTY).
hashitem_empty_o :: proc "c" (hi: ^Hashitem_T) -> bool {
	context = runtime.default_context()
	return hi.hi_key == nil || hi.hi_key == &hash_removed
}

// Initialize an empty hash table (hashtab.c public).
@(export)
hash_init :: proc "c" (ht: rawptr) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	libc.memset(ht, 0, 296)
	h.ht_array = rawptr(uintptr(ht) + 40)
	h.ht_mask = HT_INIT_SIZE_O - 1
}

// Free the array without freeing values (hashtab.c public).
@(export)
hash_clear :: proc "c" (ht: rawptr) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	if h.ht_array != rawptr(uintptr(ht) + 40) {
		xfree(h.ht_array)
	}
}

// Free the array and all contained values (hashtab.c public).
@(export)
hash_clear_all :: proc "c" (ht: rawptr, off: C.uint) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	todo := h.ht_used
	hi := (^Hashitem_T)(h.ht_array)
	for todo > 0 {
		if !hashitem_empty_o(hi) {
			xfree(rawptr(uintptr(hi.hi_key) - uintptr(off)))
			todo -= 1
		}
		hi = (^Hashitem_T)(uintptr(hi) + size_of(Hashitem_T))
	}
	hash_clear(ht)
}

// Lookup with precomputed hash (hashtab.c public).
@(export)
hash_lookup :: proc "c" (ht: rawptr, key: cstring, key_len: C.size_t, hash: C.size_t) -> rawptr {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	idx := hash & h.ht_mask
	hi := hashitem_at_o(h.ht_array, idx)
	if hi.hi_key == nil {
		return rawptr(hi)
	}
	freeitem: ^Hashitem_T = nil
	removed := rawptr(&hash_removed)
	if hi.hi_key == (^u8)(removed) {
		freeitem = hi
	} else if hi.hi_hash == hash && libc.strncmp(transmute(cstring)(hi.hi_key), key, key_len) == 0 && ([^]u8)(hi.hi_key)[uintptr(key_len)] == 0 {
		return rawptr(hi)
	}
	perturb := hash
	for {
		idx = 5*idx + perturb + 1
		hi = hashitem_at_o(h.ht_array, idx & h.ht_mask)
		if hi.hi_key == nil {
			if freeitem == nil {
				return rawptr(hi)
			}
			return rawptr(freeitem)
		}
		if hi.hi_hash == hash && hi.hi_key != (^u8)(removed) && libc.strncmp(transmute(cstring)(hi.hi_key), key, key_len) == 0 && ([^]u8)(hi.hi_key)[uintptr(key_len)] == 0 {
			return rawptr(hi)
		}
		if hi.hi_key == (^u8)(removed) && freeitem == nil {
			freeitem = hi
		}
		perturb >>= PERTURB_SHIFT_O
	}
}

// Find item for NUL-terminated key (hashtab.c public).
@(export)
hash_find :: proc "c" (ht: rawptr, key: cstring) -> rawptr {
	context = runtime.default_context()
	return hash_lookup(ht, key, libc.strlen(key), hash_hash(key))
}

// Find item for length-bounded key (hashtab.c public).
@(export)
hash_find_len :: proc "c" (ht: rawptr, key: cstring, len: C.size_t) -> rawptr {
	context = runtime.default_context()
	return hash_lookup(ht, key, len, hash_hash_len(key, len))
}

// Lookup statistics (hashtab.c public; empty — HT_DEBUG off in this build).
@(export)
hash_debug_results :: proc "c" () {
	context = runtime.default_context()
}

// Add empty item for key (hashtab.c public).
@(export)
hash_add :: proc "c" (ht: rawptr, key: ^u8) -> C.int {
	context = runtime.default_context()
	k := transmute(cstring)(key)
	hi := (^Hashitem_T)(hash_lookup(ht, k, libc.strlen(k), hash_hash(k)))
	if !hashitem_empty_o(hi) {
		siemsg(cstring("E685: Internal error: hash_add(): duplicate key \"%s\""), k)
		return FAIL_E
	}
	hash_add_item(ht, hi, key, hash_hash(k))
	return OK_E
}

// Fill a looked-up slot (hashtab.c public).
@(export)
hash_add_item :: proc "c" (ht: rawptr, hi: rawptr, key: ^u8, hash: C.size_t) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	item := (^Hashitem_T)(hi)
	h.ht_used += 1
	h.ht_changed += 1
	if item.hi_key == nil {
		h.ht_filled += 1
	}
	item.hi_key = key
	item.hi_hash = hash
	hash_may_resize_o(ht, 0)
}

// Remove item (hashtab.c public; caller frees the value).
@(export)
hash_remove :: proc "c" (ht: rawptr, hi: rawptr) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	item := (^Hashitem_T)(hi)
	h.ht_used -= 1
	h.ht_changed += 1
	item.hi_key = &hash_removed
	hash_may_resize_o(ht, 0)
}

// Lock table against resizes (hashtab.c public).
@(export)
hash_lock :: proc "c" (ht: rawptr) {
	context = runtime.default_context()
	(^Hashtab_T)(ht).ht_locked += 1
}

// Unlock table, resize if needed (hashtab.c public).
@(export)
hash_unlock :: proc "c" (ht: rawptr) {
	context = runtime.default_context()
	(^Hashtab_T)(ht).ht_locked -= 1
	hash_may_resize_o(ht, 0)
}

// Resize engine (C-static; plain proc).
hash_may_resize_o :: proc "c" (ht: rawptr, minitems_in: C.size_t) {
	context = runtime.default_context()
	h := (^Hashtab_T)(ht)
	if h.ht_locked > 0 {
		return
	}
	oldsize := h.ht_mask + 1
	minsize: C.size_t
	if minitems_in == 0 {
		if h.ht_filled < HT_INIT_SIZE_O - 1 && h.ht_array == rawptr(uintptr(ht) + 40) {
			return
		}
		if h.ht_filled*3 < oldsize*2 && h.ht_used > oldsize/5 {
			return
		}
		if h.ht_used > 1000 {
			minsize = h.ht_used * 2
		} else {
			minsize = h.ht_used * 4
		}
	} else {
		minitems := minitems_in
		if minitems < h.ht_used {
			minitems = h.ht_used
		}
		minsize = (minitems*3 + 1)/2
	}
	newsize := C.size_t(HT_INIT_SIZE_O)
	for newsize < minsize {
		newsize <<= 1
		if newsize == 0 {
			libc.abort()
		}
	}
	newarray_is_small := newsize == HT_INIT_SIZE_O
	if !newarray_is_small && newsize == oldsize && h.ht_filled*3 < oldsize*2 {
		return
	}
	keep_smallarray := newarray_is_small && h.ht_array == rawptr(uintptr(ht) + 40)
	temparray: [HT_INIT_SIZE_O]Hashitem_T
	oldarray: rawptr
	if keep_smallarray {
		libc.memcpy(rawptr(&temparray[0]), h.ht_array, size_of(temparray))
		oldarray = rawptr(&temparray[0])
	} else {
		oldarray = h.ht_array
	}
	newarray: rawptr
	if newarray_is_small {
		libc.memset(rawptr(uintptr(ht) + 40), 0, 256)
		newarray = rawptr(uintptr(ht) + 40)
	} else {
		newarray = xcalloc(newsize, C.size_t(size_of(Hashitem_T)))
	}
	newmask := newsize - 1
	todo := h.ht_used
	olditem := (^Hashitem_T)(oldarray)
	for todo > 0 {
		if !hashitem_empty_o(olditem) {
			newi := olditem.hi_hash & newmask
			newitem := hashitem_at_o(newarray, newi)
			if newitem.hi_key != nil {
				perturb := olditem.hi_hash
				for {
					newi = 5*newi + perturb + 1
					newitem = hashitem_at_o(newarray, newi & newmask)
					if newitem.hi_key == nil {
						break
					}
					perturb >>= PERTURB_SHIFT_O
				}
			}
			newitem^ = olditem^
			todo -= 1
		}
		olditem = (^Hashitem_T)(uintptr(olditem) + size_of(Hashitem_T))
	}
	if h.ht_array != rawptr(uintptr(ht) + 40) {
		xfree(h.ht_array)
	}
	h.ht_array = newarray
	h.ht_mask = newmask
	h.ht_filled = h.ht_used
	h.ht_changed += 1
}

// Hash a NUL-terminated key (hashtab.c public).
@(export)
hash_hash :: proc "c" (key: cstring) -> C.size_t {
	context = runtime.default_context()
	k := ([^]u8)(key)
	hash := C.size_t(k[0])
	if hash == 0 {
		return 0
	}
	p: uintptr = 1
	for k[p] != 0 {
		hash = hash*101 + C.size_t(k[p])
		p += 1
	}
	return hash
}

// Hash a length-bounded key (hashtab.c public).
@(export)
hash_hash_len :: proc "c" (key: cstring, len: C.size_t) -> C.size_t {
	context = runtime.default_context()
	if len == 0 {
		return 0
	}
	k := ([^]u8)(key)
	hash := C.size_t(k[0])
	p: uintptr = 1
	end := uintptr(len)
	for p < end {
		hash = hash*101 + C.size_t(k[p])
		p += 1
	}
	return hash
}

// HI_KEY_REMOVED accessor for Lua FFI (hashtab.c public).
@(export)
_hash_key_removed :: proc "c" () -> cstring {
	context = runtime.default_context()
	return transmute(cstring)(&hash_removed)
}
