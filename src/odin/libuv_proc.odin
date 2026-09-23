// libuv_proc.odin — Odin port of src/nvim/event/libuv_proc.c
// Spawns child processes via libuv's uv_spawn and wires up stdio pipes.
// Kept as FFI to libuv (-luv); no fork/exec in this file.

package main

import "core:c"
import "base:runtime"

foreign _ {
	close :: proc(fd: c.int) -> c.int ---
}

// libuv stdio / process flags (from <uv.h>).
UV_IGNORE :: c.int(0x00)
UV_CREATE_PIPE :: c.int(0x01)
UV_INHERIT_FD :: c.int(0x02)
UV_READABLE_PIPE :: c.int(0x10)
UV_WRITABLE_PIPE :: c.int(0x20)
UV_NONBLOCK_PIPE :: c.int(0x40)
UV_PROCESS_WINDOWS_HIDE :: c.int(1 << 4)
UV_PROCESS_DETACHED :: c.int(1 << 3)

UI_CLIENT_STDIN_FD :: c.int(3)

// proc_get_exepath: inline from proc.h — exepath if set, else argv[0].
proc_get_exepath :: proc(pr: ^Proc) -> ^u8 {
	if pr.exepath != nil {
		return pr.exepath
	}
	return pr.argv^
}

// Configures a stdio slot (idx) before spawn: connects the parent end to
// parent_pipe and sets up the fd/pipe the child inherits. child_readable is
// true for the child's stdin (child reads), false for stdout/stderr.
// Records any fd the parent must close after spawn in to_close[idx].
libuv_proc_stdio :: proc(uvproc: ^LibuvProc, idx: c.int, parent_pipe: ^uv_pipe_t,
                         child_readable: bool, overlapped: bool, win_create_pipe: bool,
                         to_close: ^[3]c.int) {
	// Unix-only: create a uv_pipe() pair, hand one end to child via
	// UV_INHERIT_FD and keep the other for the parent.
	child_flags := c.int(0)
	if child_readable && overlapped {
		child_flags = UV_NONBLOCK_PIPE
	}
	pipe_pair := [2]c.int{0, 0}
	uv_pipe(&pipe_pair[0],
	        child_flags_if(child_readable, UV_NONBLOCK_PIPE),
	        child_flags_if_not(child_readable, UV_NONBLOCK_PIPE))

	// child_readable: child reads pipe_pair[0], parent writes pipe_pair[1].
	child_fd, parent_fd := c.int(0), c.int(0)
	if child_readable {
		child_fd = pipe_pair[0]
		parent_fd = pipe_pair[1]
	} else {
		child_fd = pipe_pair[1]
		parent_fd = pipe_pair[0]
	}
	uvproc.uvstdio[idx].flags = UV_INHERIT_FD
	uvproc.uvstdio[idx].data = u64(child_fd)
	to_close[idx] = child_fd
	uv_pipe_open(parent_pipe, uv_file(parent_fd))
}

// Helper: pick UV_NONBLOCK_PIPE when the predicate is true, else 0.
child_flags_if :: proc(cond: bool, val: c.int) -> c.int {
	if cond {
		return val
	}
	return 0
}
child_flags_if_not :: proc(cond: bool, val: c.int) -> c.int {
	if !cond {
		return val
	}
	return 0
}

@(export)
libuv_proc_spawn :: proc "c" (uvproc: ^LibuvProc) -> c.int {
	context = runtime.default_context()
	pr := (^Proc)(uvproc)
	uvproc.uvopts.file = proc_get_exepath(pr)
	uvproc.uvopts.args = pr.argv
	// Always setsid() on unix-likes.
	uvproc.uvopts.flags = c.uint(UV_PROCESS_WINDOWS_HIDE | UV_PROCESS_DETACHED)
	uvproc.uvopts.exit_cb = rawptr(exit_cb)
	uvproc.uvopts.cwd = pr.cwd

	uvproc.uvopts.stdio = &uvproc.uvstdio[0]
	uvproc.uvopts.stdio_count = 3
	uvproc.uvstdio[0].flags = UV_IGNORE
	uvproc.uvstdio[1].flags = UV_IGNORE
	uvproc.uvstdio[2].flags = UV_IGNORE

	if ui_client_forward_stdin {
		uvproc.uvopts.stdio_count = 4
		uvproc.uvstdio[3].data = u64(0)
		uvproc.uvstdio[3].flags = UV_INHERIT_FD
	}
	uvproc.uv.data = pr

	if pr.env != nil {
		uvproc.uvopts.env = (^cstring)(tv_dict_to_env(pr.env))
	} else {
		uvproc.uvopts.env = nil
	}

	to_close := [3]c.int{-1, -1, -1}
	to_close[0] = -1
	to_close[1] = -1
	to_close[2] = -1

	if !pr.in_s.closed {
		libuv_proc_stdio(uvproc, 0, (^uv_pipe_t)(&pr.in_s.uv), true, pr.overlapped, pr.stdio_noinherit, &to_close)
	}

	if !pr.out_s.s.closed {
		libuv_proc_stdio(uvproc, 1, (^uv_pipe_t)(&pr.out_s.s.uv), false, pr.overlapped, true, &to_close)
	}

	if !pr.err_s.s.closed {
		libuv_proc_stdio(uvproc, 2, (^uv_pipe_t)(&pr.err_s.s.uv), false, pr.overlapped, pr.stdio_noinherit, &to_close)
	} else if pr.fwd_err {
		uvproc.uvstdio[2].flags = UV_INHERIT_FD
		uvproc.uvstdio[2].data = u64(2)  // STDERR_FILENO
	}

	status := uv_spawn(&pr.loop.uv, &uvproc.uv, &uvproc.uvopts)
	if status != 0 {
		if uvproc.uvopts.env != nil {
			os_free_fullenv((^cstring)(uvproc.uvopts.env))
		}
		for i in 0..<3 {
			if to_close[i] > -1 {
				close(to_close[i])
			}
		}
		return status
	}

	pr.pid = uvproc.uv.pid
	for i in 0..<3 {
		if to_close[i] > -1 {
			close(to_close[i])
		}
	}
	return status
}

@(export)
libuv_proc_close :: proc "c" (uvproc: ^LibuvProc) {
	context = runtime.default_context()
	uv_close((^uv_handle_t)(&uvproc.uv), rawptr(libuv_proc_close_cb))
}

libuv_proc_close_cb :: proc "c" (handle: ^uv_handle_t) {
	pr := (^Proc)(handle.data)
	if pr.internal_close_cb != nil {
		pr.internal_close_cb(pr)
	}
	uvproc := (^LibuvProc)(pr)
	if uvproc.uvopts.env != nil {
		os_free_fullenv((^cstring)(uvproc.uvopts.env))
	}
}

exit_cb :: proc "c" (handle: ^uv_process_t, status: i64, term_signal: c.int) {
	pr := (^Proc)(handle.data)
	pr.status = term_signal != 0 ? 128 + term_signal : c.int(status)
	pr.internal_exit_cb(pr)
}

@(export)
libuv_proc_init :: proc "c" (loop: ^Loop, data: rawptr) -> LibuvProc {
	context = runtime.default_context()
	rv := LibuvProc{}
	rv.base = proc_init(loop, ProcType.Uv, data)
	return rv
}
