package main

import "base:runtime"
import "core:c"
import "core:c/libc"

RSTREAM_BLOCK_SIZE :: 4096

@(export)
rstream_init_fd :: proc "c" (loop: ^Loop, stream: ^RStream, fd: c.int) {
	stream_init(loop, &stream.s, fd, nil)
	rstream_init(stream)
}

@(export)
rstream_init_stream :: proc "c" (stream: ^RStream, uvstream: ^uv_stream_t) {
	stream_init(nil, &stream.s, c.int(-1), uvstream)
	rstream_init(stream)
}

@(export)
rstream_init :: proc "c" (stream: ^RStream) {
	stream.read_cb = nil
	stream.num_bytes = 0
	stream.buffer = uintptr(xmalloc(c.size_t(RSTREAM_BLOCK_SIZE)))
	stream.read_pos = stream.buffer
	stream.write_pos = stream.buffer
	stream.s.close_cb = rstream_close_cb
	stream.s.close_cb_data = stream
}

@(export)
rstream_start_inner :: proc "c" (stream: ^RStream) {
	if stream.s.uvstream != nil {
		uv_read_start(stream.s.uvstream, rawptr(alloc_cb), rawptr(read_cb))
	} else {
		idle := (^uv_idle_t)(transmute(^u8)(&stream.s.uv))
		uv_idle_start(idle, rawptr(fread_idle_cb))
	}
}

@(export)
rstream_start :: proc "c" (stream: ^RStream, cb: stream_read_cb, data: rawptr) {
	stream.read_cb = cb
	stream.s.cb_data = data
	stream.want_read = true
	if !stream.paused_full {
		rstream_start_inner(stream)
	}
}

@(export)
rstream_stop_inner :: proc "c" (stream: ^RStream) {
	if stream.s.uvstream != nil {
		uv_read_stop(stream.s.uvstream)
	} else {
		idle := (^uv_idle_t)(transmute(^u8)(&stream.s.uv))
		uv_idle_stop(idle)
	}
}

@(export)
rstream_stop :: proc "c" (stream: ^RStream) {
	rstream_stop_inner(stream)
	stream.want_read = false
}

// Callbacks used by libuv.

alloc_cb :: proc "c" (handle: ^uv_handle_t, suggested: c.size_t, buf: ^uv_buf_t) {
	stream := (^RStream)(handle.data)
	buf.base = (^u8)(stream.write_pos)
	buf.len = u64(rstream_space(stream))
}

read_cb :: proc "c" (uvstream: ^uv_stream_t, cnt: c.ssize_t, buf: ^uv_buf_t) {
	stream := (^RStream)(uvstream.data)

	if cnt <= 0 {
		if cnt == c.ssize_t(UV_ENOBUFS) || cnt == 0 {
			return
		} else if cnt == c.ssize_t(UV_EOF) && uvstream.type == UV_TTY {
			rstream_invoke_read_cb(stream, true)
		} else {
			uv_read_stop(uvstream)
			rstream_invoke_read_cb(stream, true)
		}
		return
	}

	nread := c.size_t(cnt)
	stream.num_bytes += nread
	stream.write_pos = stream.write_pos + uintptr(cnt)
	rstream_invoke_read_cb(stream, false)
}

rstream_space :: proc "c" (stream: ^RStream) -> c.size_t {
	return c.size_t((stream.buffer + uintptr(RSTREAM_BLOCK_SIZE)) - stream.write_pos)
}

fread_idle_cb :: proc "c" (handle: ^uv_idle_t) {
	req: uv_fs_t
	stream := (^RStream)(handle.data)

	stream.uvbuf.base = (^u8)(stream.write_pos)
	stream.uvbuf.len = u64(rstream_space(stream))

	uv_fs_read(handle.loop, &req, stream.s.fd, &stream.uvbuf, 1, stream.s.fpos, nil)
	uv_fs_req_cleanup(&req)

	if req.result <= 0 {
		uv_idle_stop(handle)
		rstream_invoke_read_cb(stream, true)
		return
	}

	stream.write_pos = stream.write_pos + uintptr(req.result)
	stream.s.fpos += i64(req.result)
	rstream_invoke_read_cb(stream, false)
}

read_event :: proc(argv: ^rawptr) {
	context = runtime.default_context()
	stream := (^RStream)(argv^)
	stream.pending_read = false
	if stream.read_cb != nil {
		available := rstream_available(stream)
		consumed := stream.read_cb(stream, (^u8)(stream.read_pos), available, stream.s.cb_data, stream.did_eof)
		assert(consumed <= available)
		rstream_consume(stream, consumed)
	}
	// Release the reference taken when the event was queued (rstream_invoke_read_cb),
	// keeping the owning channel alive until this event is fully processed.
	if stream.s.data_decref != nil {
		stream.s.data_decref(stream.s.cb_data)
	}
	stream.s.pending_reqs -= 1
	if stream.s.closed && stream.s.pending_reqs == 0 {
		stream_close_handle(&stream.s)
	}
}

@(export)
rstream_available :: proc "c" (stream: ^RStream) -> c.size_t {
	return c.size_t(stream.write_pos - stream.read_pos)
}

@(export)
rstream_consume :: proc "c" (stream: ^RStream, consumed: c.size_t) {
	context = runtime.default_context()
	stream.read_pos = stream.read_pos + uintptr(consumed)
	remaining := c.size_t(stream.write_pos - stream.read_pos)
	if remaining > 0 && stream.read_pos > stream.buffer {
		libc.memmove((rawptr)(stream.buffer), (rawptr)(stream.read_pos), remaining)
		stream.read_pos = stream.buffer
		stream.write_pos = stream.buffer + uintptr(remaining)
	} else if remaining == 0 {
		stream.read_pos = stream.buffer
		stream.write_pos = stream.buffer
	}

	if stream.want_read && stream.paused_full && rstream_space(stream) > 0 {
		assert(stream.read_cb != nil)
		stream.paused_full = false
		rstream_start_inner(stream)
	}
}

rstream_invoke_read_cb :: proc "c" (stream: ^RStream, eof: bool) {
	context = runtime.default_context()
	stream.did_eof = stream.did_eof || eof

	if rstream_space(stream) == 0 {
		rstream_stop_inner(stream)
		stream.paused_full = true
	}

	if stream.pending_read {
		return
	}

	// Keep the owning channel (cb_data) alive until read_event is processed,
	// so a teardown that frees the channel between queue and run is safe.
	if stream.s.data_incref != nil {
		stream.s.data_incref(stream.s.cb_data)
	}
	stream.s.pending_reqs += 1
	stream.pending_read = true
	create_event(stream.s.events, event_create(read_event, stream))
}

rstream_close_cb :: proc (s: ^Stream, data: rawptr) {
	stream := (^RStream)(data)
	assert(stream != nil && s == &stream.s)
	if stream.buffer != 0 {
		xfree((rawptr)(stream.buffer))
		stream.buffer = 0
	}
}

@(export)
rstream_may_close :: proc "c" (stream: ^RStream) {
	stream_may_close(&stream.s)
}
