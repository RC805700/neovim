package main

import "base:runtime"
import "core:c"
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
