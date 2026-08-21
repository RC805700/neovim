// socket.odin — Odin port of src/nvim/event/socket.c
// Keeps libuv as the engine (FFI via -luv); reimplements nvim SocketWatcher
// logic (TCP/pipe listen+accept, connect, stale-socket recovery). All procs
// are @(export) proc "c" so C consumers (channel.c serverstart, etc.) keep
// linking against the symbols.

package main

import "base:runtime"
import "core:c"
import "core:c/libc"

// UV_* errno values (mirror libuv on Linux; also defined in fileio.odin).
UV_EACCES   :: c.int(-13)
UV_ENOENT   :: c.int(-2)
UV_EADDRINUSE :: c.int(-98)

AF_UNSPEC :: c.int(0)
AF_INET   :: c.int(2)
SOCK_STREAM :: c.int(1)
AI_NUMERICSERV :: c.int(0x0400)
UINT16_MAX :: i64(65535)

foreign _ {
	@(link_name = "try_getdigits")
	_try_getdigits :: proc(pp: ^^u8, nr: ^i64) -> bool ---

	@(link_name = "ntohs")
	_ntohs :: proc(n: u16) -> u16 ---
}

// Return a pointer to the last occurrence of `b` in the NUL-terminated string
// `s`, or nil if not found. Mirrors libc strrchr for cstring inputs.
cstr_rchr :: proc "c" (s: cstring, b: u8) -> cstring {
	if s == nil {
		return nil
	}
	p := transmute(^u8)(s)
	last := uintptr(0)
	for i := 0; ([^]u8)(p)[i] != u8(0); i += 1 {
		if ([^]u8)(p)[i] == b {
			last = uintptr(i)
		}
	}
	if last == 0 {
		return nil
	}
	return transmute(cstring)(transmute(^u8)(uintptr(p) + last))
}

@(export)
socket_address_tcp_host_end :: proc "c" (address: cstring) -> cstring {
	if address == nil {
		return nil
	}
	p := transmute(^u8)(address)
	// Windows drive letter path: "X:\..." or "X:/..." is a local path, not TCP.
	if libc.isalpha(c.int(([^]u8)(p)[0])) != 0 && ([^]u8)(p)[1] == u8(':') &&
		(([^]u8)(p)[2] == u8('\\') || ([^]u8)(p)[2] == u8('/')) {
		return nil
	}
	colon := cstr_rchr(address, u8(':'))
	if colon != nil && colon != address {
		return colon
	}
	return nil
}

@(export)
socket_watcher_init :: proc "c" (loop: ^Loop, watcher: ^SocketWatcher, endpoint: cstring) -> c.int {
	xstrlcpy(cstring(&watcher.addr[0]), endpoint, c.size_t(size_of(watcher.addr)))
	addr := cstring(&watcher.addr[0])
	host_end := socket_address_tcp_host_end(addr)

	if host_end != nil {
		// Split into hostname and port.
		hp := transmute(^u8)(host_end)
		([^]u8)(hp)[0] = u8(0)
		port := transmute(^u8)(uintptr(hp) + 1)
		iport: i64

		tmp := port
		ok := _try_getdigits(&tmp, &iport)
		if !ok || iport < 0 || iport > UINT16_MAX {
			return UV_EINVAL
		}

		request: uv_getaddrinfo_t
		hints: addrinfo
		hints.ai_family = AF_UNSPEC
		hints.ai_socktype = SOCK_STREAM
		hints.ai_flags = AI_NUMERICSERV

		retval := uv_getaddrinfo(&loop.uv, &request, nil, addr, transmute(cstring)(port), &hints)
		if retval != 0 {
			return retval
		}
		// uv_getaddrinfo populates request.addrinfo; store it inside the uv
		// union at offset 248, matching C's uv.tcp.addrinfo layout.
		(transmute(^rawptr)(&watcher.uv[248]))^ = request.addrinfo

		uv_tcp_init(&loop.uv, (^uv_tcp_t)(transmute(^u8)(&watcher.uv)))
		uv_tcp_nodelay((^uv_tcp_t)(transmute(^u8)(&watcher.uv)), c.int(1))
		watcher.stream = transmute(^uv_stream_t)(&watcher.uv)
	} else {
		uv_pipe_init(&loop.uv, (^uv_pipe_t)(transmute(^u8)(&watcher.uv)), 0)
		watcher.stream = transmute(^uv_stream_t)(&watcher.uv)
	}

	watcher.stream.data = watcher
	watcher.cb = nil
	watcher.close_cb = nil
	watcher.events = nil
	watcher.data = nil

	return 0
}

// Callback after closing a Stream initialized by socket_connect().
connect_close_cb :: proc(stream: ^Stream, data: rawptr) {
	closed := (^bool)(data)
	closed^ = true
}

// Check if a socket is alive by attempting to connect to it.
socket_alive :: proc "c" (loop: ^Loop, addr: cstring) -> bool {
	stream: RStream
	err: cstring = nil

	connected := socket_connect(loop, &stream, false, addr, 500, &err)
	if !connected {
		return false
	}

	closed := false
	stream.s.internal_close_cb = connect_close_cb
	stream.s.internal_data = &closed
	stream_may_close(&stream.s)
	loop_run_until(&main_loop, -1, &closed)

	return true
}

early_server_close_cb :: proc "c" (handle: ^uv_handle_t) {
	closed := (^bool)(handle.data)
	closed^ = true
}

@(export)
socket_watcher_start :: proc "c" (watcher: ^SocketWatcher, backlog: c.int, cb: socket_cb) -> c.int {
	watcher.cb = cb
	result: c.int = UV_EINVAL

		if watcher.stream.type == UV_TCP {
		ai: ^addrinfo = transmute(^addrinfo)((transmute(^rawptr)(&watcher.uv[248]))^)
		for ai != nil {
			result = uv_tcp_bind((^uv_tcp_t)(transmute(^u8)(&watcher.uv)), ai.ai_addr, 0)
			if result != 0 {
				ai = ai.ai_next
				continue
			}
			result = uv_listen(watcher.stream, backlog, rawptr(connection_cb))
			if result == 0 {
				sas: sockaddr_storage
				namelen := c.int(c.size_t(size_of(sockaddr_storage)))
				uv_tcp_getsockname((^uv_tcp_t)(transmute(^u8)(&watcher.uv)),
					(^sockaddr)(&sas), &namelen)
				family := (^u16)(&sas._ss_pad1[0])^
				sin_port: u16
				if family == u16(AF_INET) {
					sin_port = (^sockaddr_in)(&sas._ss_pad1[0]).sin_port
				} else {
					sin_port = (^sockaddr_in6)(&sas._ss_pad1[0]).sin6_port
				}
				len := libc.strlen(cstring(&watcher.addr[0]))
				basep := transmute(^u8)(cstring(&watcher.addr[0]))
				libc.snprintf(transmute(^u8)(uintptr(basep) + uintptr(len)),
					c.size_t(size_of(watcher.addr)) - c.size_t(len),
					":%hu", _ntohs(sin_port))
				break
			}
			ai = ai.ai_next
		}
		uv_freeaddrinfo(transmute(^addrinfo)((transmute(^rawptr)(&watcher.uv[248]))^))
	} else {
		result = uv_pipe_bind((^uv_pipe_t)(transmute(^u8)(&watcher.uv)), cstring(&watcher.addr[0]))

		if result == UV_EACCES || result == UV_EADDRINUSE {
			loop := (^Loop)(watcher.stream.loop.data)

			if !socket_alive(loop, cstring(&watcher.addr[0])) {
				rm_result := os_remove(cstring(&watcher.addr[0]))
				if rm_result != 0 {
					// Failed to remove stale socket.
				} else {
					uv_loop := watcher.stream.loop
					closed := false
					watcher.stream.data = &closed
					uv_close(transmute(^uv_handle_t)(&watcher.uv), rawptr(early_server_close_cb))
					loop_run_until(&main_loop, -1, &closed)

					uv_pipe_init(uv_loop, (^uv_pipe_t)(transmute(^u8)(&watcher.uv)), 0)
					watcher.stream = transmute(^uv_stream_t)(&watcher.uv)
					watcher.stream.data = watcher

					result = uv_pipe_bind((^uv_pipe_t)(transmute(^u8)(&watcher.uv)), cstring(&watcher.addr[0]))
				}
			}
		}

		if result == 0 {
			result = uv_listen(watcher.stream, backlog, rawptr(connection_cb))
		}
	}

	// libuv should return negative error code or zero.
	if result < 0 {
		if result == UV_EACCES {
			pt := path_tail(cstring(&watcher.addr[0]))
			([^]u8)(pt)[0] = u8(0)
			if !os_path_exists(cstring(&watcher.addr[0])) {
				result = UV_ENOENT
			}
		}
		return result
	}

	return 0
}

@(export)
socket_watcher_accept :: proc "c" (watcher: ^SocketWatcher, stream: ^RStream) -> c.int {
	client: ^uv_stream_t

	if watcher.stream.type == UV_TCP {
		client = transmute(^uv_stream_t)(&stream.s.uv)
		uv_tcp_init(watcher.stream.loop, (^uv_tcp_t)(transmute(^u8)(&stream.s.uv)))
		uv_tcp_nodelay((^uv_tcp_t)(transmute(^u8)(&stream.s.uv)), c.int(1))
	} else {
		client = transmute(^uv_stream_t)(&stream.s.uv)
		uv_pipe_init(watcher.stream.loop, (^uv_pipe_t)(transmute(^u8)(&stream.s.uv)), 0)
	}

	result := uv_accept(watcher.stream, client)
	if result != 0 {
		uv_close(transmute(^uv_handle_t)(client), nil)
		return result
	}

	stream_init(nil, &stream.s, -1, client)
	return 0
}

@(export)
socket_watcher_close :: proc "c" (watcher: ^SocketWatcher, cb: socket_close_cb) {
	watcher.close_cb = cb
	uv_close(transmute(^uv_handle_t)(watcher.stream), rawptr(socket_watcher_close_cb))
}

connection_event :: proc (argv: ^rawptr) {
	watcher := (^SocketWatcher)(argv^)
	status := c.int(uintptr((^rawptr)(uintptr(argv) + size_of(rawptr))^))
	watcher.cb(watcher, status, watcher.data)
}

connection_cb :: proc "c" (handle: ^uv_stream_t, status: c.int) {
	context = runtime.default_context()
	watcher := (^SocketWatcher)(handle.data)
	e: Event
	e.handler = connection_event
	e.argv[0] = watcher
	e.argv[1] = rawptr(uintptr(status))
	create_event(watcher.events, e)
}

socket_watcher_close_cb :: proc "c" (handle: ^uv_handle_t) {
	context = runtime.default_context()
	watcher := (^SocketWatcher)(handle.data)
	if watcher.close_cb != nil {
		watcher.close_cb(watcher, watcher.data)
	}
}

connect_cb :: proc "c" (req: ^uv_connect_t, status: c.int) {
	ret_status := (^c.int)(req.data)
	ret_status^ = status
	handle := transmute(^uv_handle_t)(req.handle)
	if status != 0 {
		stream_may_close(transmute(^Stream)(handle.data))
	}
}

@(export)
socket_connect :: proc "c" (loop: ^Loop, stream: ^RStream, is_tcp: bool, address: cstring,
	timeout: c.int, err: ^cstring) -> bool {
	success := false
	closed := false
	status := 0
	req: uv_connect_t
	req.data = &status
	uv_stream: ^uv_stream_t

	addr: cstring = nil
	if is_tcp {
		addr = _xstrdup(address)
		host_end := cstr_rchr(addr, u8(':'))
		if host_end == nil {
			err^ = cstring("tcp address must be host:port")
			xfree(rawptr(addr))
			return false
		}
		([^]u8)(host_end)[0] = u8(0)

		addr_req: uv_getaddrinfo_t
		hints: addrinfo
		hints.ai_family = AF_UNSPEC
		hints.ai_socktype = SOCK_STREAM
		hints.ai_flags = AI_NUMERICSERV
		retval := uv_getaddrinfo(&loop.uv, &addr_req, nil, addr, transmute(cstring)(uintptr(transmute(^u8)(host_end)) + 1), &hints)
		if retval != 0 {
			err^ = cstring("failed to lookup host or port")
			xfree(rawptr(addr))
			return false
		}
		cur := addr_req.addrinfo

		for cur != nil {
			uv_tcp_init(&loop.uv, (^uv_tcp_t)(transmute(^u8)(&stream.s.uv)))
		uv_tcp_nodelay((^uv_tcp_t)(transmute(^u8)(&stream.s.uv)), c.int(1))
			uv_tcp_connect(&req, (^uv_tcp_t)(transmute(^u8)(&stream.s.uv)),
				cur.ai_addr, rawptr(connect_cb))
			uv_stream = transmute(^uv_stream_t)(&stream.s.uv)
			break
		}
	} else {
		uv_pipe_init(&loop.uv, (^uv_pipe_t)(transmute(^u8)(&stream.s.uv)), 0)
		uv_pipe_connect(&req, (^uv_pipe_t)(transmute(^u8)(&stream.s.uv)), address, rawptr(connect_cb))
		uv_stream = transmute(^uv_stream_t)(&stream.s.uv)
	}
	stream_init(nil, &stream.s, -1, uv_stream)
	stream.s.internal_close_cb = connect_close_cb
	stream.s.internal_data = &closed
	closed = false
	status = 1
	loop_run_until(&main_loop, timeout, &closed)

	if status == 0 {
		success = true
	} else {
		stream_may_close(&stream.s)
		loop_run_until(&main_loop, -1, &closed)
		err^ = cstring("connection refused")
	}

	stream.s.internal_close_cb = nil
	stream.s.internal_data = nil
	xfree(rawptr(addr))
	return success
}

// Poll the main loop's events until `cond` (dereferenced bool) becomes true,
// honoring `timeout` (ms) like LOOP_PROCESS_EVENTS_UNTIL in C. A positive
// timeout decrements remaining time using os_hrtime.
loop_run_until :: proc "c" (loop: ^Loop, timeout: c.int, cond: ^bool) {
	remaining := i64(timeout)
	before: u64 = 0
	if remaining > 0 {
		before = os_hrtime()
	}
	for !cond^ {
		loop_poll_events(loop, remaining)
		if remaining == 0 {
			break
		} else if remaining > 0 {
			now := os_hrtime()
			remaining -= i64((now - before) / 1000000)
			before = now
			if remaining <= 0 {
				break
			}
		}
	}
}
