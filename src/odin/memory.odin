package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"

AllocInfo :: struct {
  size: int,
  caller: rawptr,
}

WrappedCaller :: struct {
  pc:    rawptr,
  name:  cstring,
}

@(private)
alloc_sizes: map[rawptr]AllocInfo

// When false (default), the x* allocation procs are thin wrappers with zero
// tracking overhead — identical speed to the original libc malloc. Tracking
// (and the leak dump) is enabled only when NVIM_ODIN_LEAK_DEBUG=1 is set.
// This avoids a backtrace()/dladdr() syscall on every single allocation,
// which made the editor unusably sluggish.
track_allocations := false

init_memory :: proc() {
	context = runtime.default_context()
	alloc_sizes.allocator = runtime.heap_allocator()
	_, track_allocations = os.lookup_env_alloc("NVIM_ODIN_LEAK_DEBUG", context.allocator)
}

backing_allocator :: proc() -> mem.Allocator {
  return runtime.heap_allocator()
}

foreign _ {
  @(link_name = "preserve_exit")
  preserve_exit :: proc "c" (errmsg: cstring) ---
  backtrace :: proc "c" (buffer: [^]rawptr, size: c.int) -> c.int ---
  // Defined by main.c.o (EXTERN in memory.h); C copy is authoritative
  // (new compiler emits @(export) globals strong — would clash).
  arena_alloc_count: c.size_t
}

known_wrappers: []cstring = {
  "alloc_block",
  "ga_grow",
  "xrealloc",
  "xmallocz",
  "xstrdup",
  "xmemdupz",
  "xstrnsave",
}

is_known_wrapper :: proc(pc: rawptr) -> bool {
  dlinfo: Dl_info
  if dladdr(pc, &dlinfo) == 0 || dlinfo.dli_sname == nil {
    return false
  }
  for w in known_wrappers {
    if dlinfo.dli_sname == w {
      return true
    }
  }
  return false
}

capture_caller :: proc() -> rawptr {
  bt: [8]rawptr
  n := backtrace(raw_data(bt[:]), 8)
  // bt[0] = return inside capture_caller
  // bt[1] = return inside the x* function (xmalloc/xfree/xcalloc/xrealloc/...)
  // Walk up to skip known wrapper functions (alloc_block, ga_grow, xmallocz, etc.)
  idx := 2
  for idx < int(n) && is_known_wrapper(bt[idx]) {
    idx += 1
  }
  if idx < int(n) { return bt[idx] }
  return bt[2]
}

@(export)
xmalloc :: proc "c" (size: c.size_t) -> rawptr {
  context = runtime.default_context()
  context.allocator = backing_allocator()
  actual := int(size if size > 0 else 1)
  data_bytes, err := mem.alloc_bytes_non_zeroed(actual)
  if err != nil {
    preserve_exit("E41: Out of memory!")
  }
	data := raw_data(data_bytes)
	alloc_sizes[data] = AllocInfo{actual, caller_if_tracked()}
	return data
}

@(export)
xfree :: proc "c" (ptr: rawptr) {
	if ptr == nil { return }
	context = runtime.default_context()
	context.allocator = backing_allocator()
	delete_key(&alloc_sizes, ptr)
	mem.free(ptr)
}

@(export)
xcalloc :: proc "c" (count: c.size_t, size: c.size_t) -> rawptr {
	context = runtime.default_context()
	context.allocator = backing_allocator()
	actual_count := int(count if count > 0 else 1)
	actual_size  := int(size  if size  > 0 else 1)
	total := actual_count * actual_size
	data, err := mem.alloc(total)
	if err != nil {
		preserve_exit("E41: Out of memory!")
	}
	alloc_sizes[data] = AllocInfo{total, caller_if_tracked()}
	return data
}

@(export)
xrealloc :: proc "c" (ptr: rawptr, size: c.size_t) -> rawptr {
	context = runtime.default_context()
	context.allocator = backing_allocator()
	actual := int(size if size > 0 else 1)
	if ptr == nil {
		data_bytes, err := mem.alloc_bytes_non_zeroed(actual)
		if err != nil {
			preserve_exit("E41: Out of memory!")
		}
		data := raw_data(data_bytes)
		alloc_sizes[data] = AllocInfo{actual, caller_if_tracked()}
		return data
	}

	old_info, have_old := alloc_sizes[ptr]
	if !have_old {
		new_data_bytes, err := mem.alloc_bytes_non_zeroed(actual)
		if err != nil {
			preserve_exit("E41: Out of memory!")
		}
		new_data := raw_data(new_data_bytes)
		mem.copy(new_data, ptr, actual)
		mem.free(ptr)
		alloc_sizes[new_data] = AllocInfo{actual, caller_if_tracked()}
		return new_data
	}

	new_data, err := mem.resize(ptr, old_info.size, actual)
	if err != nil {
		preserve_exit("E41: Out of memory!")
	}
	delete_key(&alloc_sizes, ptr)
	alloc_sizes[new_data] = AllocInfo{actual, caller_if_tracked()}
	return new_data
}

@(export)
try_malloc :: proc "c" (size: c.size_t) -> rawptr {
	context = runtime.default_context()
	context.allocator = backing_allocator()
	actual := int(size if size > 0 else 1)
	data_bytes, err := mem.alloc_bytes_non_zeroed(actual)
	if err != nil { return nil }
	data := raw_data(data_bytes)
	alloc_sizes[data] = AllocInfo{actual, caller_if_tracked()}
	return data
}

@(export)
verbose_try_malloc :: proc "c" (size: c.size_t) -> rawptr {
	context = runtime.default_context()
	context.allocator = backing_allocator()
	actual := int(size if size > 0 else 1)
	data_bytes, err := mem.alloc_bytes_non_zeroed(actual)
	if err != nil {
		fmt.eprintf("E342: Out of memory! (allocating %v bytes)\n", size)
		return nil
	}
	data := raw_data(data_bytes)
	alloc_sizes[data] = AllocInfo{actual, caller_if_tracked()}
	return data
}

// caller_if_tracked returns the allocation's caller (via backtrace/dwarf) only
// when leak debugging is enabled. The backtrace() syscall on every allocation
// is extremely expensive and made the editor unusably slow, so it is opt-in.
caller_if_tracked :: proc() -> rawptr {
	if !track_allocations {
		return nil
	}
	return capture_caller()
}

// —— Batch M1a: C string/memory utilities (exports + weak) ——

// strdup wrapper (memory.c public).
@(export)
xstrdup :: proc "c" (s: ^u8) -> ^u8 {
	n := libc.strlen(transmute(cstring)(s))
	dup := (^u8)(xmalloc(n + 1))
	libc.memcpy(dup, s, n + 1)
	return dup
}

// cstring-typed alias wrappers (zero caller churn for migrated call sites).
xstrdup_r2 :: proc "c" (s: cstring) -> ^u8 {
	return xstrdup(transmute(^u8)(s))
}
xstrdup_r :: proc "c" (s: cstring) -> ^u8 {
	return xstrdup(transmute(^u8)(s))
}
_xstrdup :: proc "c" (s: cstring) -> cstring {
	return transmute(cstring)(xstrdup(transmute(^u8)(s)))
}

// memdupz: duplicate len bytes + NUL (memory.c public).
@(export)
xmemdupz :: proc "c" (data: rawptr, len: c.size_t) -> ^u8 {
	dup := (^u8)(xmalloc(len + 1))
	libc.memcpy(dup, transmute(^u8)(data), len)
	([^]u8)(dup)[uintptr(len)] = 0
	return dup
}

// Alias wrappers (zero caller churn for migrated call sites).
xmemdupz_o2 :: proc "c" (s: ^u8, len: c.size_t) -> ^u8 {
	return xmemdupz(s, len)
}
xmemdupz_c :: proc "c" (s: ^u8, len: c.size_t) -> ^u8 {
	return xmemdupz(s, len)
}
xmemdupz_sp :: proc "c" (s: ^u8, len: c.size_t) -> ^u8 {
	return xmemdupz(s, len)
}
_xmemdupz :: proc "c" (data: rawptr, len: c.size_t) -> cstring {
	return transmute(cstring)(xmemdupz(data, len))
}

// strlcpy: sized copy, returns strlen(src) (memory.c public).
@(export)
xstrlcpy :: proc "c" (dst: cstring, src: cstring, dsize: c.size_t) -> c.size_t {
	slen := libc.strlen(src)
	if dsize != 0 {
		length := slen
		if length > dsize - 1 {
			length = dsize - 1
		}
		libc.memcpy(transmute(^u8)(dst), transmute(^u8)(src), length)
		([^]u8)(dst)[uintptr(length)] = 0
	}
	return slen
}

// strlcat: sized append, returns strlen(dst)+strlen(src) (memory.c public).
@(export)
xstrlcat :: proc "c" (dst: ^u8, src: ^u8, dsize: c.size_t) -> c.size_t {
	dlen := libc.strlen(transmute(cstring)(dst))
	slen := libc.strlen(transmute(cstring)(src))
	if slen > dsize - dlen - 1 {
		libc.memmove(rawptr(uintptr(dst) + uintptr(dlen)), src, dsize - dlen - 1)
		([^]u8)(dst)[uintptr(dsize) - 1] = 0
	} else {
		libc.memmove(rawptr(uintptr(dst) + uintptr(dlen)), src, slen + 1)
	}
	return slen + dlen
}

// cstring-typed strlcat wrapper (zero caller churn).
_xstrlcat :: proc "c" (dst: cstring, src: cstring, dsize: c.size_t) -> c.size_t {
	return xstrlcat(transmute(^u8)(dst), transmute(^u8)(src), dsize)
}

// mallocz: size+1 zeroed bytes (memory.c public).
@(export)
xmallocz :: proc "c" (size: c.size_t) -> ^u8 {
	p := (^u8)(xmalloc(size + 1))
	libc.memset(p, 0, size + 1)
	return p
}

// memcpyz: copy + NUL-terminate (memory.c public).
@(export)
xmemcpyz :: proc "c" (dst: rawptr, src: rawptr, len: c.size_t) -> rawptr {
	libc.memcpy(transmute(^u8)(dst), transmute(^u8)(src), len)
	([^]u8)(dst)[uintptr(len)] = 0
	return dst
}

// memchrsub: replace byte in buffer (memory.c public).
@(export)
memchrsub :: proc "c" (data: rawptr, ch: c.int, x: c.int, len: c.size_t) {
	p := transmute(^u8)(data)
	end := transmute(^u8)(uintptr(data) + uintptr(len))
	for uintptr(p) < uintptr(end) {
		found := libc.memchr(p, ch, c.size_t(uintptr(end) - uintptr(p)))
		if found == nil {
			break
		}
		([^]u8)(found)[0] = u8(x)
		p = transmute(^u8)(uintptr(found) + 1)
	}
}

// memcnt: count byte in buffer (memory.c public).
@(export)
memcnt :: proc "c" (data: rawptr, ch: c.int, len: c.size_t) -> c.size_t {
	cnt: c.size_t = 0
	p := transmute(^u8)(data)
	end := transmute(^u8)(uintptr(data) + uintptr(len))
	for uintptr(p) < uintptr(end) {
		found := libc.memchr(p, ch, c.size_t(uintptr(end) - uintptr(p)))
		if found == nil {
			break
		}
		cnt += 1
		p = transmute(^u8)(uintptr(found) + 1)
	}
	return cnt
}

// strequal: NULL-tolerant strcmp (memory.c public).
@(export)
strequal :: proc "c" (a: cstring, b: cstring) -> bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return libc.strcmp(a, b) == 0
}

// strnequal: NULL-tolerant strncmp (memory.c public).
@(export)
strnequal :: proc "c" (a: cstring, b: cstring, n: c.size_t) -> bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return libc.strncmp(a, b, n) == 0
}

// strdupnul: NULL-safe strdup (memory.c public).
@(export)
xstrdupnul :: proc "c" (str: cstring) -> ^u8 {
	if str == nil {
		return xmallocz(0)
	}
	return xstrdup(transmute(^u8)(str))
}

// strndup wrapper (memory.c public).
@(export)
xstrndup :: proc "c" (str: cstring, len: c.size_t) -> ^u8 {
	n := len
	p := libc.memchr(transmute(^u8)(str), 0, n)
	if p != nil {
		n = c.size_t(uintptr(p) - uintptr(rawptr(str)))
	}
	return xmemdupz(rawptr(transmute(^u8)(str)), n)
}

// memdup: non-terminated duplicate (memory.c public).
@(export)
xmemdup :: proc "c" (data: rawptr, len: c.size_t) -> rawptr {
	return libc.memcpy(xmalloc(len), transmute(^u8)(data), len)
}

// stpcpy: copy + return end (memory.c public).
@(export)
xstpcpy :: proc "c" (dst: ^u8, src: ^u8) -> ^u8 {
	length := libc.strlen(transmute(cstring)(src))
	libc.memcpy(dst, src, length + 1)
	return transmute(^u8)(uintptr(dst) + uintptr(length))
}

// stpncpy: fixed-width copy + return end/NUL (memory.c public).
@(export)
xstpncpy :: proc "c" (dst: ^u8, src: ^u8, maxlen: c.size_t) -> ^u8 {
	p := libc.memchr(src, 0, maxlen)
	if p != nil {
		srclen := c.size_t(uintptr(p) - uintptr(src))
		libc.memcpy(dst, src, srclen)
		libc.memset(rawptr(uintptr(dst) + uintptr(srclen)), 0, maxlen - srclen)
		return transmute(^u8)(uintptr(dst) + uintptr(srclen))
	}
	libc.memcpy(dst, src, maxlen)
	return transmute(^u8)(uintptr(dst) + uintptr(maxlen))
}

// strchrnul: strchr or end (memory.c public).
@(export)
xstrchrnul :: proc "c" (str: ^u8, ch: c.int) -> ^u8 {
	p := libc.strchr(transmute(cstring)(str), ch)
	if p != nil {
		return transmute(^u8)(p)
	}
	return transmute(^u8)(uintptr(str) + uintptr(libc.strlen(transmute(cstring)(str))))
}

// memrchr: reverse byte search (memory.c public).
@(export)
xmemrchr :: proc "c" (src: cstring, ch: u8, len: c.size_t) -> cstring {
	l := len
	for l > 0 {
		l -= 1
		if ([^]u8)(src)[uintptr(l)] == ch {
			return transmute(cstring)(uintptr(rawptr(src)) + uintptr(l))
		}
	}
	return nil
}

// memscan: memchr or end (memory.c public).
@(export)
xmemscan :: proc "c" (addr: rawptr, ch: u8, size: c.size_t) -> rawptr {
	p := libc.memchr(transmute(^u8)(addr), c.int(ch), size)
	if p != nil {
		return p
	}
	return rawptr(uintptr(addr) + uintptr(size))
}

// strchrsub: in-place byte replace (memory.c public).
@(export)
strchrsub :: proc "c" (str: ^u8, ch: u8, x: u8) {
	p := str
	for {
		found := libc.strchr(transmute(cstring)(p), c.int(ch))
		if found == nil {
			break
		}
		([^]u8)(found)[0] = x
		p = transmute(^u8)(uintptr(found) + 1)
	}
}

// strcnt: count byte in string (memory.c public).
@(export)
strcnt :: proc "c" (str: cstring, ch: u8) -> c.size_t {
	cnt: c.size_t = 0
	p := transmute(^u8)(str)
	for {
		found := libc.strchr(transmute(cstring)(p), c.int(ch))
		if found == nil {
			break
		}
		cnt += 1
		p = transmute(^u8)(uintptr(found) + 1)
	}
	return cnt
}

// —— Batch M1b: arena allocator (exports + weak) ——
REUSE_MAX_O :: 4

// Moved memory.c state (single live copies).
arena_reuse_blk_g: rawptr = nil
arena_reuse_blk_count_g: c.size_t = 0

// Arena block header (memory_defs.h): single prev link.
Consumed_Blk_O :: struct {
	prev: rawptr,
}

// Free cached reuse blocks (memory.c static).
arena_free_reuse_blks_o :: proc "c" () {
	context = runtime.default_context()
	for arena_reuse_blk_count_g > 0 {
		blk := arena_reuse_blk_g
		arena_reuse_blk_g = (^Consumed_Blk_O)(blk).prev
		xfree(blk)
		arena_reuse_blk_count_g -= 1
	}
}

// Finish arena allocations, return free handle (memory.c public).
@(export)
arena_finish :: proc "c" (arena: rawptr) -> rawptr {
	res := (^rawptr)(uintptr(arena) + 0)^
	(^rawptr)(uintptr(arena) + 0)^ = nil
	(^c.size_t)(uintptr(arena) + 8)^ = 0
	(^c.size_t)(uintptr(arena) + 16)^ = 0
	return res
}

// Allocate one block, via reuse cache (memory.c public).
@(export)
alloc_block :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if arena_reuse_blk_count_g > 0 {
		retval := arena_reuse_blk_g
		arena_reuse_blk_g = (^Consumed_Blk_O)(arena_reuse_blk_g).prev
		arena_reuse_blk_count_g -= 1
		return retval
	}
	arena_alloc_count += 1
	return xmalloc(c.size_t(ARENA_BLOCK_SIZE))
}

// Open a fresh block on an arena (memory.c public).
@(export)
arena_alloc_block :: proc "c" (arena: rawptr) {
	prev_blk := (^rawptr)(uintptr(arena) + 0)^
	(^rawptr)(uintptr(arena) + 0)^ = alloc_block()
	(^c.size_t)(uintptr(arena) + 8)^ = 0
	(^c.size_t)(uintptr(arena) + 16)^ = c.size_t(ARENA_BLOCK_SIZE)
	blk := (^Consumed_Blk_O)(arena_alloc(arena, size_of(Consumed_Blk_O), true))
	blk.prev = prev_blk
}

// 8-byte alignment helper (memory.c static).
arena_align_offset_o :: proc "c" (off: u64) -> c.size_t {
	return c.size_t((off + 7) & ~u64(7))
}

// Arena allocator (memory.c public).
@(export)
arena_alloc :: proc "c" (arena: rawptr, size: c.size_t, align: bool) -> rawptr {
	if arena == nil {
		return xmalloc(size)
	}
	if (^rawptr)(uintptr(arena) + 0)^ == nil {
		arena_alloc_block(arena)
	}
	pos := (^c.size_t)(uintptr(arena) + 8)^
	alloc_pos := pos
	if align {
		alloc_pos = arena_align_offset_o(u64(pos))
	}
	arena_size := (^c.size_t)(uintptr(arena) + 16)^
	if u64(alloc_pos) + u64(size) > u64(arena_size) {
		if u64(size) > (u64(ARENA_BLOCK_SIZE) - size_of(Consumed_Blk_O)) >> 1 {
			arena_alloc_count += 1
			hdr_size := c.size_t(size_of(Consumed_Blk_O))
			aligned_hdr_size := hdr_size
			if align {
				aligned_hdr_size = arena_align_offset_o(u64(hdr_size))
			}
			alloc := transmute(^u8)(xmalloc(size + aligned_hdr_size))
			cur_blk := (^Consumed_Blk_O)((^rawptr)(uintptr(arena) + 0)^)
			fix_blk := (^Consumed_Blk_O)(alloc)
			fix_blk.prev = cur_blk.prev
			cur_blk.prev = fix_blk
			return rawptr(uintptr(alloc) + uintptr(aligned_hdr_size))
		}
		arena_alloc_block(arena)
		pos = (^c.size_t)(uintptr(arena) + 8)^
		alloc_pos = pos
		if align {
			alloc_pos = arena_align_offset_o(u64(pos))
		}
	}
	mem := rawptr(uintptr((^rawptr)(uintptr(arena) + 0)^) + uintptr(alloc_pos))
	(^c.size_t)(uintptr(arena) + 8)^ = alloc_pos + size
	return mem
}

// Return a block to the reuse cache (memory.c public).
@(export)
free_block :: proc "c" (block: rawptr) {
	context = runtime.default_context()
	if arena_reuse_blk_count_g < REUSE_MAX_O {
		(^Consumed_Blk_O)(block).prev = arena_reuse_blk_g
		arena_reuse_blk_g = block
		arena_reuse_blk_count_g += 1
	} else {
		xfree(block)
	}
}

// Free a finished arena handle (memory.c public).
@(export)
arena_mem_free :: proc "c" (mem: rawptr) {
	b := transmute(^Consumed_Blk_O)(mem)
	if b != nil {
		reuse_blk := rawptr(b)
		b = transmute(^Consumed_Blk_O)((^Consumed_Blk_O)(b).prev)
		free_block(reuse_blk)
	}
	for b != nil {
		prev := transmute(^Consumed_Blk_O)((^Consumed_Blk_O)(b).prev)
		xfree(b)
		b = prev
	}
}

// Arena NUL-terminated alloc (memory.c public).
@(export)
arena_allocz :: proc "c" (arena: rawptr, size: c.size_t) -> ^u8 {
	mem := transmute(^u8)(arena_alloc(arena, size + 1, false))
	([^]u8)(mem)[uintptr(size)] = 0
	return mem
}

// Arena dup + NUL (memory.c public).
@(export)
arena_memdupz :: proc "c" (arena: rawptr, buf: cstring, size: c.size_t) -> ^u8 {
	mem := arena_allocz(arena, size)
	libc.memcpy(mem, transmute(^u8)(buf), size)
	return mem
}

// Arena strdup (memory.c public).
@(export)
arena_strdup :: proc "c" (arena: rawptr, str: cstring) -> ^u8 {
	return arena_memdupz(arena, str, libc.strlen(str))
}

// time_to_bytes: big-endian time_t (memory.c public).
@(export)
time_to_bytes :: proc "c" (time_: c.long, buf: ^u8) {
	i: u64 = 7
	bufi: u64 = 0
	for bufi < 8 {
		([^]u8)(buf)[uintptr(bufi)] = u8((u64(time_) >> (i * 8)) & 0xff)
		i -= 1
		bufi += 1
	}
}

// mergesort callback types (memory.h).
MergeSortGet_O :: proc "c" (node: rawptr) -> rawptr
MergeSortSet_O :: proc "c" (node: rawptr, val: rawptr)
MergeSortCmp_O :: proc "c" (a: rawptr, b: rawptr) -> c.int

// Stable iterative mergesort for doubly-linked lists (memory.c public).
@(export)
mergesort_list :: proc "c" (head: rawptr, get_next: MergeSortGet_O, set_next: MergeSortSet_O, get_prev: MergeSortGet_O, set_prev: MergeSortSet_O, compare: MergeSortCmp_O) -> rawptr {
	context = runtime.default_context()
	h := head
	if h == nil || get_next(h) == nil {
		return h
	}
	n: c.int = 0
	curr := h
	for curr != nil {
		n += 1
		curr = get_next(curr)
	}
	size: c.int = 1
	for size < n {
		new_head: rawptr = nil
		tail: rawptr = nil
		curr = h
		for curr != nil {
			left := curr
			right := left
			i: c.int = 0
			for i < size && right != nil {
				right = get_next(right)
				i += 1
			}
			next := right
			i = 0
			for i < size && next != nil {
				next = get_next(next)
				i += 1
			}
			l_end: rawptr = nil
			if right != nil {
				l_end = get_prev(right)
			}
			if l_end != nil {
				set_next(l_end, nil)
			}
			if right != nil {
				set_prev(right, nil)
			}
			r_end: rawptr = nil
			if next != nil {
				r_end = get_prev(next)
			}
			if r_end != nil {
				set_next(r_end, nil)
			}
			if next != nil {
				set_prev(next, nil)
			}
			merged: rawptr = nil
			merged_tail: rawptr = nil
			for left != nil || right != nil {
				chosen: rawptr = nil
				if left == nil {
					chosen = right
					right = get_next(right)
				} else if right == nil {
					chosen = left
					left = get_next(left)
				} else if compare(left, right) <= 0 {
					chosen = left
					left = get_next(left)
				} else {
					chosen = right
					right = get_next(right)
				}
				if merged_tail != nil {
					set_next(merged_tail, chosen)
					set_prev(chosen, merged_tail)
					merged_tail = chosen
				} else {
					merged = chosen
					merged_tail = chosen
					set_prev(chosen, nil)
				}
			}
			if new_head == nil {
				new_head = merged
			} else {
				set_next(tail, merged)
				set_prev(merged, tail)
			}
			for get_next(merged_tail) != nil {
				merged_tail = get_next(merged_tail)
			}
			tail = merged_tail
			curr = next
		}
		h = new_head
		size *= 2
	}
	return h
}
