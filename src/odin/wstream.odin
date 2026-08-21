package main

import "base:runtime"
import "core:c"
import "core:c/libc"

DEFAULT_MAXMEM :: c.size_t(1024 * 1024 * 2000)

WRequest :: struct {
	stream: ^Stream,
	buffer: ^WBuffer,
	uv_req: uv_write_t,
}

@(export)
wstream_init_fd :: proc "c" (loop: ^Loop, stream: ^Stream, fd: c.int, maxmem: c.size_t) {
	stream_init(loop, stream, fd, nil)
	wstream_init(stream, maxmem)
}

@(export)
wstream_init_stream :: proc "c" (stream: ^Stream, uvstream: ^uv_stream_t, maxmem: c.size_t) {
	stream_init(nil, stream, c.int(-1), uvstream)
	wstream_init(stream, maxmem)
}

@(export)
wstream_init :: proc "c" (stream: ^Stream, maxmem: c.size_t) {
	context = runtime.default_context()
	stream.maxmem = maxmem != 0 ? maxmem : DEFAULT_MAXMEM
}

@(export)
wstream_set_write_cb :: proc "c" (stream: ^Stream, cb: stream_write_cb, data: rawptr) {
	stream.write_cb = cb
	stream.cb_data = data
}

@(export)
wstream_write :: proc "c" (stream: ^Stream, buffer: ^WBuffer) -> c.int {
	context = runtime.default_context()
	assert(stream.maxmem != 0)
	assert(!stream.closed)

	uvbuf: uv_buf_t
	uvbuf.base = buffer.data
	uvbuf.len = u64(buffer.size)

	if stream.uvstream == nil {
		req := uv_fs_t{}
		idle := (^uv_idle_t)(transmute(^u8)(&stream.uv))
		err := uv_fs_write(idle.loop, &req, stream.fd, &uvbuf, 1, stream.fpos, nil)
		uv_fs_req_cleanup(&req)

		wstream_release_wbuffer(buffer)

		assert(stream.write_cb == nil)

		stream.fpos += i64(req.result)
		if req.result > 0 {
			return 0
		} else if err != 0 {
			return err
		}
		return UV_UNKNOWN
	}

	if stream.curmem > stream.maxmem {
		wstream_release_wbuffer(buffer)
		return UV_ENOMEM
	}

	stream.curmem += buffer.size

	data := (^WRequest)(xmalloc(c.size_t(size_of(WRequest))))
	data.stream = stream
	data.buffer = buffer
	data.uv_req.data = data

	err := uv_write(&data.uv_req, stream.uvstream, &uvbuf, 1, rawptr(write_cb))
	if err != 0 {
		xfree(data)
		wstream_release_wbuffer(buffer)
		assert(err != 0)
		return err
	}

	stream.pending_reqs += 1
	assert(err == 0)
	return 0
}

@(export)
wstream_new_buffer :: proc "c" (data: ^u8, size: c.size_t, refcount: c.size_t, cb: wbuffer_data_finalizer) -> ^WBuffer {
	rv := (^WBuffer)(xmalloc(c.size_t(size_of(WBuffer))))
	rv.size = size
	rv.refcount = refcount
	rv.cb = cb
	rv.data = data
	return rv
}

write_cb :: proc "c" (req: ^uv_write_t, status: c.int) {
	context = runtime.default_context()
	data := (^WRequest)(req.data)

	data.stream.curmem -= data.buffer.size

	wstream_release_wbuffer(data.buffer)

	if data.stream.write_cb != nil {
		data.stream.write_cb(data.stream, data.stream.cb_data, status)
	}

	data.stream.pending_reqs -= 1

	if data.stream.closed && data.stream.pending_reqs == 0 {
		stream_close_handle(data.stream)
	}

	xfree(data)
}

@(export)
wstream_release_wbuffer :: proc "c" (buffer: ^WBuffer) {
	context = runtime.default_context()
	buffer.refcount -= 1
	if buffer.refcount == 0 {
		if buffer.cb != nil {
			buffer.cb(buffer.data)
		}
		xfree(buffer)
	}
}
