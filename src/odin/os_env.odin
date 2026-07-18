package main

import "core:c"
import "base:runtime"
import "core:os"
import "core:sys/posix"

// C global variables accessed by Odin
foreign _ {
	@(link_name = "nvim_testing")
	nvim_testing: bool
}

// Static buffer for os_getenv_noalloc (replaces C's NameBuff usage)
@(private)
_noalloc_buf: [4096]byte

// Helper: allocate a C string via xmalloc (returns memory C can xfree)
_cstr_alloc :: proc(s: string) -> rawptr {
	if len(s) == 0 {
		return nil
	}
	result := xmalloc(c.size_t(len(s) + 1))
	dp := ([^]byte)(result)
	for i in 0 ..< len(s) {
		dp[i] = s[i]
	}
	dp[len(s)] = 0
	return result
}

// ── Phase A: Simple env wrappers ──

@(export)
os_getenv :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	name_str := string(name)
	if len(name_str) == 0 {
		return nil
	}
	value, found := os.lookup_env_alloc(name_str, context.allocator)
	if !found || len(value) == 0 {
		return nil
	}
	result := _cstr_alloc(value)
	delete(value)
	return cstring(result)
}

@(export)
os_getenv_buf :: proc "c" (name: cstring, buf: cstring, bufsize: c.size_t) -> cstring {
	context = runtime.default_context()
	name_str := string(name)
	if len(name_str) == 0 {
		return nil
	}
	buf_slice := ([^]byte)(buf)[:bufsize]
	value := os.get_env(buf_slice, name_str)
	if len(value) == 0 {
		return nil
	}
	return buf
}

@(export)
os_getenv_noalloc :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()
	return os_getenv_buf(name, cstring(&_noalloc_buf[0]), c.size_t(len(_noalloc_buf)))
}

@(export)
os_env_exists :: proc "c" (name: cstring, nonempty: bool) -> bool {
	context = runtime.default_context()
	name_str := string(name)
	if len(name_str) == 0 {
		return false
	}
	value, found := os.lookup_env_alloc(name_str, context.allocator)
	defer delete(value)
	if !found {
		return false
	}
	if nonempty && len(value) == 0 {
		return false
	}
	return true
}

@(export)
os_setenv :: proc "c" (name: cstring, value: cstring, overwrite: c.int) -> c.int {
	context = runtime.default_context()
	name_str := string(name)
	if len(name_str) == 0 {
		return -1
	}
	if overwrite == 0 && os_getenv(name) != nil {
		return 0
	}
	err := os.set_env(name_str, string(value))
	if err != nil {
		return -1
	}
	return 0
}

@(export)
os_unsetenv :: proc "c" (name: cstring) -> c.int {
	context = runtime.default_context()
	name_str := string(name)
	if len(name_str) == 0 {
		return -1
	}
	if os.unset_env(name_str) {
		return 0
	}
	return -1
}

@(export)
os_get_pid :: proc "c" () -> c.int64_t {
	context = runtime.default_context()
	return c.int64_t(posix.getpid())
}

@(export)
os_get_hostname :: proc "c" (hostname: cstring, size: c.size_t) {
	context = runtime.default_context()
	hn := ([^]c.char)(hostname)
	result := posix.gethostname(hn, size)
	if result != .OK {
		hn[0] = 0
	}
}

@(export)
env_init :: proc "c" () {
	context = runtime.default_context()
	nvim_testing = os_env_exists("NVIM_TEST", false)
}
