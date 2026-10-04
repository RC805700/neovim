package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// garray.c port (Batch G1): growing-array primitives, the most-called
// allocation helpers in the tree. All 11 exports; C file moved to bak/.
// Garray layout mirrors garray_T exactly (main.odin; cc-verified).

foreign _ {
	@(link_name = "logmsg")
	logmsg_e :: proc "c" (log_level: C.int, ctx: cstring, func_name: cstring, line_num: C.int, eol: bool, fmt: cstring, #c_vararg args: ..any) -> bool ---
}

// Growing-array clearer (garray.c public).
@(export)
ga_clear :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	xfree(gap.ga_data)
	gap.ga_data = nil
	gap.ga_maxlen = 0
	gap.ga_len = 0
}

// String-array deep clearer (garray.c public).
@(export)
ga_clear_strings :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	if gap.ga_data != nil {
		items := ([^]rawptr)(gap.ga_data)
		for i: C.int = 0; i < gap.ga_len; i += 1 {
			xfree(items[uintptr(i)])
		}
	}
	ga_clear(gap)
}

// Growing-array initializer (garray.c public).
@(export)
ga_init :: proc "c" (gap: ^Garray, itemsize: C.int, growsize: C.int) {
	context = runtime.default_context()
	gap.ga_data = nil
	gap.ga_maxlen = 0
	gap.ga_len = 0
	gap.ga_itemsize = itemsize
	ga_set_growsize(gap, growsize)
}

// Growsize setter, minimum 1 (garray.c public).
@(export)
ga_set_growsize :: proc "c" (gap: ^Garray, growsize: C.int) {
	context = runtime.default_context()
	if growsize < 1 {
		logmsg_e(3, nil, cstring("ga_set_growsize"), 57, true, cstring("trying to set an invalid ga_growsize: %d"), growsize)
		gap.ga_growsize = 1
	} else {
		gap.ga_growsize = growsize
	}
}

// Growing-array grower (garray.c public).
@(export)
ga_grow :: proc "c" (gap: ^Garray, n: C.int) {
	context = runtime.default_context()
	if gap.ga_maxlen - gap.ga_len >= n {
		return
	}
	if gap.ga_growsize < 1 {
		logmsg_e(3, nil, cstring("ga_grow"), 76, true, cstring("ga_growsize(%d) is less than 1"), gap.ga_growsize)
	}
	need := n
	if need < gap.ga_growsize {
		need = gap.ga_growsize
	}
	if need < gap.ga_len / 2 {
		need = gap.ga_len / 2
	}
	new_maxlen := gap.ga_len + need
	new_size := C.size_t(gap.ga_itemsize) * C.size_t(new_maxlen)
	old_size := C.size_t(gap.ga_itemsize) * C.size_t(gap.ga_maxlen)
	pp := xrealloc(gap.ga_data, new_size)
	libc.memset(rawptr(uintptr(pp) + uintptr(old_size)), 0, C.size_t(new_size - old_size))
	gap.ga_maxlen = new_maxlen
	gap.ga_data = pp
}

// String-array sort + dedup (garray.c public).
@(export)
ga_remove_duplicate_strings :: proc "c" (gap: ^Garray) {
	context = runtime.default_context()
	fnames := ([^]cstring)(gap.ga_data)
	sort_strings(transmute(^rawptr)(gap.ga_data), gap.ga_len)
	for i := gap.ga_len - 1; i > 0; i -= 1 {
		if path_fnamecmp_r(fnames[uintptr(i) - 1], fnames[uintptr(i)]) == 0 {
			xfree(rawptr(fnames[uintptr(i)]))
			for j := i + 1; j < gap.ga_len; j += 1 {
				fnames[uintptr(j) - 1] = fnames[uintptr(j)]
			}
			gap.ga_len -= 1
		}
	}
}

// String-array joiner (garray.c public).
@(export)
ga_concat_strings :: proc "c" (gap: ^Garray, sep: cstring) -> ^u8 {
	context = runtime.default_context()
	nelem := C.size_t(gap.ga_len)
	strings := ([^]cstring)(gap.ga_data)
	if nelem == 0 {
		return xstrdup(transmute(^u8)(cstring("")))
	}
	length: C.size_t = 0
	for i: uint = 0; i < uint(nelem); i += 1 {
		length += libc.strlen(strings[i])
	}
	length += (C.size_t(nelem) - 1) * libc.strlen(sep)
	ret := transmute([^]u8)(xmallocz(length))
	s := ret
	for i: uint = 0; i < uint(nelem) - 1; i += 1 {
		s = transmute([^]u8)(xstpcpy(transmute(^u8)(s), transmute(^u8)(strings[i])))
		s = transmute([^]u8)(xstpcpy(transmute(^u8)(s), transmute(^u8)(sep)))
	}
	libc.strcpy(s, strings[uint(nelem) - 1])
	return &ret[0]
}

// String appender, no NUL copy (garray.c public).
@(export)
ga_concat :: proc "c" (gap: ^Garray, s: cstring) {
	context = runtime.default_context()
	if s == nil {
		return
	}
	ga_concat_len(gap, s, libc.strlen(s))
}

// Length-bounded appender (garray.c public).
@(export)
ga_concat_len :: proc "c" (gap: ^Garray, s: cstring, length: C.size_t) {
	context = runtime.default_context()
	if length == 0 {
		return
	}
	ga_grow(gap, C.int(length))
	data := transmute([^]u8)(gap.ga_data)
	libc.memcpy(rawptr(&data[uintptr(gap.ga_len)]), rawptr(s), C.size_t(length))
	gap.ga_len += C.int(length)
}

// Byte appender (garray.c public).
@(export)
ga_append :: proc "c" (gap: ^Garray, c: u8) {
	context = runtime.default_context()
	ga_grow(gap, 1)
	([^]u8)(gap.ga_data)[uintptr(gap.ga_len)] = c
	gap.ga_len += 1
}

// Append-slot allocator (garray.c public).
@(export)
ga_append_via_ptr :: proc "c" (gap: ^Garray, item_size: C.size_t) -> rawptr {
	context = runtime.default_context()
	if C.int(item_size) != gap.ga_itemsize {
		logmsg_e(3, nil, cstring("ga_append_via_ptr"), 209, true, cstring("wrong item size (%zu), should be %d"), item_size, gap.ga_itemsize)
	}
	ga_grow(gap, 1)
	slot := rawptr(uintptr(gap.ga_data) + uintptr(item_size) * uintptr(gap.ga_len))
	gap.ga_len += 1
	return slot
}
