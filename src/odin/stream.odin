package main

import "base:runtime"
import "core:c"
import "core:c/libc"

// libuv handle-type constants (uv.h).
UV_FILE       :: c.int(17)
UV_NAMED_PIPE :: c.int(7)
UV_TTY        :: c.int(14)
UV_TCP        :: c.int(12)

@(export)
stream_set_blocking :: proc "c" (fd: c.int, blocking: bool) -> c.int {
	loop: uv_loop_t
	stream: uv_pipe_t
	uv_loop_init(&loop)
	uv_pipe_init(&loop, &stream, 0)
	uv_pipe_open(&stream, uv_file(fd))
	retval := uv_stream_set_blocking((^uv_stream_t)(&stream), c.int(blocking))
	uv_close((^uv_handle_t)(&stream), nil)
	uv_run(&loop, uv_run_mode.UV_RUN_NOWAIT)
	uv_loop_close(&loop)
	return retval
}

@(export)
stream_init :: proc "c" (loop: ^Loop, stream: ^Stream, fd: c.int, uvstream: ^uv_stream_t) {
	context = runtime.default_context()
	assert(uvstream == nil ? (fd >= 0 && loop != nil) : (fd < 0 && loop == nil))
	stream.uvstream = uvstream

	if fd >= 0 {
		typ := uv_guess_handle(fd)
		stream.fd = uv_file(fd)

		if typ == UV_FILE {
			uv_idle_init(&loop.uv, (^uv_idle_t)(transmute(^u8)(&stream.uv)))
			idle := (^uv_idle_t)(transmute(^u8)(&stream.uv))
			idle.data = stream
		} else {
			assert(typ == UV_NAMED_PIPE || typ == UV_TTY)
			r := uv_pipe_init(&loop.uv, (^uv_pipe_t)(transmute(^u8)(&stream.uv)), 0)
			ro := uv_pipe_open((^uv_pipe_t)(transmute(^u8)(&stream.uv)), uv_file(fd))
			stream.uvstream = (^uv_stream_t)(transmute(^u8)(&stream.uv))
		}
	}

	if stream.uvstream != nil {
		stream.uvstream.data = stream
	}

	stream.fpos = 0
	stream.internal_data = nil
	stream.curmem = 0
	stream.maxmem = 0
	stream.pending_reqs = 0
	stream.write_cb = nil
	stream.close_cb = nil
	stream.internal_close_cb = nil
	stream.closed = false
	// When created with a loop, read events are delivered to the loop's
	// main event queue. Job/pipe streams are created with loop==NULL and
	// their `events` is wired later (libuv_proc_spawn -> proc->events).
	stream.events = nil
	if loop != nil {
		stream.events = loop.events
	}
}

@(export)
stream_may_close :: proc "c" (stream: ^Stream) {
	if stream.closed {
		return
	}
	stream.closed = true

	if stream.pending_reqs == 0 {
		stream_close_handle(stream)
	}
}

@(export)
stream_close_handle :: proc "c" (stream: ^Stream) {
	context = runtime.default_context()
	handle := (^uv_handle_t)(nil)
	if stream.uvstream != nil {
		if uv_stream_get_write_queue_size(stream.uvstream) > 0 {
			libc.fprintf(libc.stderr, cstring("closed Stream (%p) with unwritten bytes\n"), stream)
		}
		handle = (^uv_handle_t)(stream.uvstream)
	} else {
		handle = (^uv_handle_t)(transmute(^u8)(&stream.uv))
	}

	assert(handle != nil)

	if stream.before_close_cb != nil {
		stream.pending_reqs += 1
		stream.before_close_cb(stream, stream.close_cb_data)
		stream.pending_reqs -= 1
	}
	if uv_is_closing(handle) == 0 {
		uv_close(handle, rawptr(stream_uv_close_cb))
	}
}

stream_uv_close_cb :: proc(handle: ^uv_handle_t) {
	stream := (^Stream)(handle.data)
	if stream != nil && stream.close_cb != nil {
		stream.close_cb(stream, stream.close_cb_data)
	}
	if stream != nil && stream.internal_close_cb != nil {
		stream.internal_close_cb(stream, stream.internal_data)
	}
}
