// os_proc.odin — port of src/nvim/os/proc.c (Linux path)
//
// Process-tree helpers: kill a process group, enumerate immediate children
// (via /proc/<pid>/task/<pid>/children), and test whether a pid is running.

package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:sys/posix"

when ODIN_OS == .Linux {
	UV_ESRCH :: c.int(-c.int(posix.ESRCH))
} else {
	UV_ESRCH :: c.int(-4040)
}

foreign _ {
	@(link_name = "uv_kill")
	uv_kill :: proc(pid: c.int, signum: c.int) -> c.int ---
}

@(export)
os_proc_tree_kill :: proc "c" (pid: c.int, sig: c.int) -> bool {
	context = runtime.default_context()
	assert(sig == posix.SIGTERM || sig == posix.SIGKILL)
	if pid == 0 {
		return false
	}
	return uv_kill(-pid, sig) == 0
}

@(export)
os_proc_children :: proc "c" (ppid: c.int, proc_list: ^^c.int, proc_count: ^c.size_t) -> c.int {
	context = runtime.default_context()
	if ppid < 0 {
		return 2
	}

	temp: [dynamic]c.int = {}

	pathbuf: [256]u8 = {}
	libc.snprintf(&pathbuf[0], 256, cstring("/proc/%d/task/%d/children"), c.int(ppid), c.int(ppid))

	fp := libc.fopen(cstring(&pathbuf[0]), cstring("r"))
	if fp == nil {
		return 2
	}
	match_pid: c.int = 0
	for libc.fscanf(fp, cstring("%d"), &match_pid) > 0 {
		append(&temp, match_pid)
	}
	libc.fclose(fp)

	if len(temp) > 0 {
		// Hand ownership of the backing array to the caller (xmalloc'd).
		out := xmalloc(c.size_t(len(temp) * size_of(c.int)))
		if out == nil {
			return 2
		}
		p := ([^]c.int)(out)
		for i, v in temp {
			p[i] = c.int(v)
		}
		proc_list^ = p
	}
	proc_count^ = c.size_t(len(temp))
	return 0
}

@(export)
os_proc_running :: proc "c" (pid: c.int) -> bool {
	context = runtime.default_context()
	err := uv_kill(pid, 0)
	if err == 0 {
		return true
	}
	if err == UV_ESRCH {
		return false
	}
	return true
}
