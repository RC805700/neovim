// uv_defs.odin — Odin mirrors of the libuv handle types used by the
// event subsystem, plus the libuv FFI declarations.
//
// ABI note: libuv handle structs are mirrored as a leading `data: rawptr`
// (every handle's first field is `void *data`) followed by padding sized to
// the exact `sizeof` on this platform (see sizes printed from <uv.h>):
//
//   uv_loop_t 848  uv_async_t 128  uv_signal_t 152  uv_timer_t 152
//   uv_mutex_t 40   uv_handle_t 96
//
// `uv_handle_t` (the base) has `data` then `uv_loop_t *loop` as its
// second field, so `uv_async_t`/`uv_timer_t`/`uv_signal_t` expose
// `.data` and `.loop` directly. These are only ever passed by pointer
// to libuv FFI, which reads/writes the real C layout.

package main

import "core:c"

uv_loop_t :: struct {
	data: rawptr,
	_pad: [840]u8,
}

uv_handle_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	type: c.int,    // uv_handle_type, at offset 16
	_pad: [76]u8,
}

uv_async_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [112]u8,
}

uv_signal_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad0: [80]u8,
	self: rawptr,
	signum: c.int,
	_pad1: [44]u8,
}

uv_timer_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [136]u8,
}

uv_mutex_t :: struct {
	_pad: [40]u8,
}

// uv_stream_t (248): base handle (data@0, loop@8) + stream-specific.
uv_stream_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	type: c.int,    // uv_handle_type, at offset 16
	_pad: [228]u8,
}

// uv_idle_t (120): base handle (data@0, loop@8) + idle-specific.
uv_idle_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [104]u8,
}

// uv_pipe_t (264): base handle (data@0, loop@8) + pipe-specific.
uv_pipe_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [248]u8,
}

// uv_tcp_t (248): base handle (data@0, loop@8) + tcp-specific.
uv_tcp_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [232]u8,
}

// uv_buf_t (16): { char *base; size_t len } on 64-bit.
uv_buf_t :: struct {
	base: ^u8,
	len: u64,
}

// uv_write_t (192): a uv_req_t subclass. Only the `data` field (first,
// set by libuv to our WRequest*) is read by our write_cb wrapper.
uv_write_t :: struct {
	data: rawptr,
	_pad: [184]u8,
}

// uv_fs_t (440): a uv_req_t subclass. `data` (first field, our WRequest*)
// and `result` (ssize_t at offset 88) matter; we read req.result.
uv_fs_t :: struct {
	data: rawptr,
	_pad0: [80]u8,
	result: c.ssize_t,
	_pad1: [344]u8,
}

// uv_connect_t (96): uv_req_t base (64: data, type, reserved[6]) + cb(8) +
// handle(8) + private padding to 96.
uv_connect_t :: struct {
	data: rawptr,
	_pad0: [56]u8,
	cb: rawptr,
	handle: ^uv_stream_t,
	_pad1: [16]u8,
}

// uv_getaddrinfo_t (160): uv_req_t base (64: data, type, reserved[6]) + loop(8)
// + private(88), where the first private field is `addrinfo*` at offset 72.
// NOTE: real layout is uv_req_t(64) + loop(8) + getaddrinfo_cb(8) + 64
// pad + addrinfo(8) => addrinfo is at offset 144, NOT 72/80. Verified
// with __builtin_offsetof on this platform's libuv.
uv_getaddrinfo_t :: struct {
	data: rawptr,
	_pad0: [56]u8,
	loop: ^uv_loop_t,
	getaddrinfo_cb: rawptr,
	_pad1: [64]u8,
	addrinfo: ^addrinfo,
	_pad2: [8]u8,
}

// uv_shutdown_t (min size for FFI, used as opaque request).
uv_shutdown_t :: struct {
	_pad: [96]u8,
}

// uv_getnameinfo_t (opaque request placeholder).
uv_getnameinfo_t :: struct {
	_pad: [160]u8,
}

// struct addrinfo (48) — only `ai_addr`/`ai_next`/`ai_addrlen` read here.
addrinfo :: struct {
	ai_flags: c.int,
	ai_family: c.int,
	ai_socktype: c.int,
	ai_protocol: c.int,
	ai_addrlen: c.int,
	ai_addr: ^sockaddr,
	ai_canonname: cstring,
	ai_next: ^addrinfo,
}

sockaddr :: struct {
	sa_family: u16,
	sa_data: [14]u8,
}

sockaddr_in :: struct {
	sin_family: i16,
	sin_port: u16,
	sin_addr: [4]u8,
	sin_zero: [8]u8,
}

sockaddr_in6 :: struct {
	sin6_family: i16,
	sin6_port: u16,
	sin6_flowinfo: u32,
	sin6_addr: [16]u8,
	sin6_scope_id: u32,
}

// sockaddr_storage (128): opaque large address struct. `_ss_pad1` is the
// first padding region, used by socket.odin to reinterpret the address.
sockaddr_storage :: struct {
	_ss_pad1: [128]u8,
}

// uv_stdio_container_t (16): { uv_stdio_flags flags; union { int fd;
// uv_stream_t *stream; } data; } flags@0 (c.int), data@8 (8-byte union).
// NOTE: Odin's nested `struct` would be 16 bytes here; we model the C
// union with a single 8-byte `data` field (fd in low 4 bytes, stream
// pointer as the full 8 bytes). Setting `.data = u64(fd)` for
// UV_INHERIT_FD, or `.data = u64(uintptr(stream))` for UV_CREATE_PIPE.
uv_stdio_container_t :: struct {
	flags: c.int,
	_pad:  [4]u8,
	data:  u64,
}

// uv_process_options_t (64): exit_cb@0, file@8, args@16, env@24, cwd@32,
// flags@40, stdio_count@44, stdio@48.
uv_process_options_t :: struct {
	exit_cb: rawptr,
	file: ^u8,
	args: ^^u8,
	env: ^cstring,
	cwd: ^u8,
	flags: c.uint,
	stdio_count: c.int,
	stdio: ^uv_stdio_container_t,
}

// uv_process_t (136): data@0, loop@8, exit_cb@96, pid@104, status@128.
uv_process_t :: struct {
	data:   rawptr,
	loop:   ^uv_loop_t,
	_pad0:  [88]u8,   // 8..96 padding
	exit_cb: rawptr,   // @96
	pid:    c.int,     // @104
	_pad1:  [24]u8,   // 108..132 (status @128 + padding to 136)
}

// uv_file is an int on POSIX (libuv typedef).
uv_file :: c.int

// UV_* error constants defined elsewhere (fileio.odin / socket.odin /
// os_proc.odin / libuv_proc.odin). Only the ones NOT defined elsewhere
// live here.
UV_UNKNOWN    :: c.int(-4094)
UV_EAGAIN     :: c.int(-11)
UV_EBUSY      :: c.int(-16)
UV_ENOMEM     :: c.int(-12)
UV_ENOBUFS    :: c.int(-105)
UV_EOF        :: c.int(-4095)

// uv_run_mode (libuv enum).
uv_run_mode :: enum {
	UV_RUN_DEFAULT,
	UV_RUN_ONCE,
	UV_RUN_NOWAIT,
	UV_RUN_DEFAULT_2,
}

// uv_stream_union: a flat 264-byte buffer that overlays uv_pipe_t /
// uv_tcp_t / uv_tty_t. SocketWatcher stores its handle here.
uv_stream_union :: struct {
	_pad: [264]u8,
}

// uv_connection_cb / uv_connect_cb typedefs (passed as rawptr to FFI).
uv_connection_cb :: proc(server: ^uv_stream_t, status: c.int)
uv_connect_cb :: proc(req: ^uv_connect_t, status: c.int)

// uv_read_cb / uv_write_cb / uv_alloc_cb typedefs (passed as rawptr to FFI).
uv_alloc_cb :: proc(handle: ^uv_handle_t, suggested_size: c.size_t, buf: ^uv_buf_t)
uv_read_cb :: proc(handle: ^uv_stream_t, nread: c.ssize_t, buf: ^uv_buf_t)
uv_write_cb :: proc(req: ^uv_write_t, status: c.int)

// uv_idle_t callbacks.
uv_idle_cb :: proc(handle: ^uv_idle_t)

// uv_timer_t callback.
uv_timer_cb :: proc(handle: ^uv_timer_t)

// uv_async_t callback.
uv_async_cb :: proc(handle: ^uv_async_t)

// uv_signal_t callback.
uv_signal_cb :: proc(handle: ^uv_signal_t, signum: c.int)

// uv_fs_t callback.
uv_fs_cb :: proc(req: ^uv_fs_t)

// uv_exit_cb typedef.
uv_exit_cb :: proc(handle: ^uv_process_t, exit_status: i64, term_signal: c.int)

// uv_walk_cb typedef.
uv_walk_cb :: proc(handle: ^uv_handle_t, arg: rawptr)

foreign _ {
	// uv.h core
	uv_loop_init :: proc(loop: ^uv_loop_t) -> c.int ---
	uv_loop_close :: proc(loop: ^uv_loop_t) -> c.int ---
	uv_run :: proc(loop: ^uv_loop_t, mode: uv_run_mode) ---
	uv_stop :: proc(loop: ^uv_loop_t) ---
	uv_update_time :: proc(loop: ^uv_loop_t) ---
	uv_backend_fd :: proc(loop: ^uv_loop_t) -> c.int ---
	uv_backend_timeout :: proc(loop: ^uv_loop_t) -> c.int ---
	uv_now :: proc(loop: ^uv_loop_t) -> u64 ---
	uv_walk :: proc(loop: ^uv_loop_t, walk_cb: rawptr, arg: rawptr) ---

	uv_close :: proc(handle: ^uv_handle_t, close_cb: rawptr) ---
	uv_is_closing :: proc(handle: ^uv_handle_t) -> c.int ---
	uv_ref :: proc(handle: ^uv_handle_t) ---
	uv_unref :: proc(handle: ^uv_handle_t) ---
	uv_has_ref :: proc(handle: ^uv_handle_t) -> c.int ---
	uv_send_buffer_size :: proc(handle: ^uv_handle_t, value: ^c.int) -> c.int ---
	uv_recv_buffer_size :: proc(handle: ^uv_handle_t, value: ^c.int) -> c.int ---
	uv_fileno :: proc(handle: ^uv_handle_t, fd: ^uv_file) -> c.int ---
	uv_stream_get_write_queue_size :: proc(stream: ^uv_stream_t) -> c.size_t ---

	uv_mutex_init :: proc(handle: ^uv_mutex_t) -> c.int ---
	uv_mutex_destroy :: proc(handle: ^uv_mutex_t) ---
	uv_mutex_lock :: proc(handle: ^uv_mutex_t) ---
	uv_mutex_unlock :: proc(handle: ^uv_mutex_t) ---
	uv_mutex_trylock :: proc(handle: ^uv_mutex_t) -> c.int ---

	uv_async_init :: proc(loop: ^uv_loop_t, handle: ^uv_async_t, cb: rawptr) -> c.int ---
	uv_async_send :: proc(handle: ^uv_async_t) -> c.int ---

	uv_idle_init :: proc(loop: ^uv_loop_t, handle: ^uv_idle_t) -> c.int ---
	uv_idle_start :: proc(handle: ^uv_idle_t, cb: rawptr) -> c.int ---
	uv_idle_stop :: proc(handle: ^uv_idle_t) -> c.int ---

	uv_timer_init :: proc(loop: ^uv_loop_t, handle: ^uv_timer_t) -> c.int ---
	uv_timer_start :: proc(handle: ^uv_timer_t, cb: rawptr, timeout: u64, repeat: u64) -> c.int ---
	uv_timer_stop :: proc(handle: ^uv_timer_t) -> c.int ---
	uv_timer_again :: proc(handle: ^uv_timer_t) -> c.int ---
	uv_timer_set_repeat :: proc(handle: ^uv_timer_t, repeat: u64) ---
	uv_timer_get_repeat :: proc(handle: ^uv_timer_t) -> u64 ---

	uv_signal_init :: proc(loop: ^uv_loop_t, handle: ^uv_signal_t) -> c.int ---
	uv_signal_start :: proc(handle: ^uv_signal_t, cb: rawptr, signum: c.int) -> c.int ---
	uv_signal_stop :: proc(handle: ^uv_signal_t) -> c.int ---

	uv_pipe_init :: proc(loop: ^uv_loop_t, handle: ^uv_pipe_t, ipc: c.int) -> c.int ---
	uv_pipe_open :: proc(handle: ^uv_pipe_t, fd: uv_file) -> c.int ---
	uv_pipe_bind :: proc(handle: ^uv_pipe_t, name: cstring) -> c.int ---
	uv_pipe_connect :: proc(req: ^uv_connect_t, handle: ^uv_pipe_t, name: cstring, cb: rawptr) ---
	uv_pipe_getsockname :: proc(handle: ^uv_pipe_t, buffer: ^u8, size: ^c.int) -> c.int ---
	uv_pipe_pending_count :: proc(handle: ^uv_pipe_t) -> c.int ---
	uv_pipe_pending_type :: proc(handle: ^uv_pipe_t) -> c.int ---
	uv_pipe_chmod :: proc(handle: ^uv_pipe_t, mode: c.int) -> c.int ---

	uv_tcp_init :: proc(loop: ^uv_loop_t, handle: ^uv_tcp_t) -> c.int ---
	uv_tcp_nodelay :: proc(handle: ^uv_tcp_t, enable: c.int) -> c.int ---
	uv_tcp_keepalive :: proc(handle: ^uv_tcp_t, enable: c.int, delay: c.uint) -> c.int ---
	uv_tcp_simultaneous_accepts :: proc(handle: ^uv_tcp_t, enable: c.int) -> c.int ---
	uv_tcp_bind :: proc(handle: ^uv_tcp_t, addr: ^sockaddr, flags: c.uint) -> c.int ---
	uv_tcp_connect :: proc(req: ^uv_connect_t, handle: ^uv_tcp_t, addr: ^sockaddr, cb: rawptr) -> c.int ---
	uv_tcp_getsockname :: proc(handle: ^uv_tcp_t, name: ^sockaddr, namelen: ^c.int) -> c.int ---
	uv_tcp_getpeername :: proc(handle: ^uv_tcp_t, name: ^sockaddr, namelen: ^c.int) -> c.int ---
	uv_tcp_close_reset :: proc(handle: ^uv_tcp_t, cb: rawptr) -> c.int ---

	uv_stream_set_blocking :: proc(handle: ^uv_stream_t, blocking: c.int) -> c.int ---
	uv_listen :: proc(stream: ^uv_stream_t, backlog: c.int, cb: rawptr) -> c.int ---
	uv_accept :: proc(server: ^uv_stream_t, client: ^uv_stream_t) -> c.int ---
	uv_read_start :: proc(stream: ^uv_stream_t, alloc_cb: rawptr, read_cb: rawptr) -> c.int ---
	uv_read_stop :: proc(stream: ^uv_stream_t) -> c.int ---
	uv_write :: proc(req: ^uv_write_t, handle: ^uv_stream_t, bufs: ^uv_buf_t, nbufs: c.uint, cb: rawptr) -> c.int ---
	uv_write2 :: proc(req: ^uv_write_t, handle: ^uv_stream_t, bufs: ^uv_buf_t, nbufs: c.uint, send_handle: ^uv_stream_t, cb: rawptr) -> c.int ---
	uv_try_write :: proc(stream: ^uv_stream_t, bufs: ^uv_buf_t, nbufs: c.uint) -> c.int ---
	uv_try_write2 :: proc(stream: ^uv_stream_t, bufs: ^uv_buf_t, nbufs: c.uint, send_handle: ^uv_stream_t) -> c.int ---
	uv_shutdown :: proc(req: ^uv_shutdown_t, handle: ^uv_stream_t, cb: rawptr) -> c.int ---

	uv_fs_write :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, file: uv_file, bufs: ^uv_buf_t, nbufs: c.uint, offset: i64, cb: rawptr) -> c.int ---
	uv_fs_read :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, file: uv_file, bufs: ^uv_buf_t, nbufs: c.uint, offset: i64, cb: rawptr) -> c.int ---
	uv_fs_open :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, flags: c.int, mode: c.int, cb: rawptr) -> c.int ---
	uv_fs_close :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, file: uv_file, cb: rawptr) -> c.int ---
	uv_fs_stat :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, cb: rawptr) -> c.int ---
	uv_fs_fstat :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, file: uv_file, cb: rawptr) -> c.int ---
	uv_fs_lstat :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, cb: rawptr) -> c.int ---
	uv_fs_unlink :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, cb: rawptr) -> c.int ---
	uv_fs_mkdir :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, mode: c.int, cb: rawptr) -> c.int ---
	uv_fs_rmdir :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, cb: rawptr) -> c.int ---
	uv_fs_rename :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, new_path: cstring, cb: rawptr) -> c.int ---
	uv_fs_req_cleanup :: proc(req: ^uv_fs_t) ---
	uv_fs_copyfile :: proc(loop: ^uv_loop_t, req: ^uv_fs_t, path: cstring, new_path: cstring, flags: c.int, cb: rawptr) -> c.int ---

	uv_buf_init :: proc(base: ^u8, len: c.uint) -> uv_buf_t ---
	uv_strerror :: proc(err: c.int) -> cstring ---
	uv_strerror_r :: proc(err: c.int, buf: ^u8, buflen: c.size_t) -> cstring ---
	uv_err_name :: proc(err: c.int) -> cstring ---

	uv_getaddrinfo :: proc(loop: ^uv_loop_t, req: ^uv_getaddrinfo_t, getaddrinfo_cb: rawptr, node: cstring, service: cstring, hints: ^addrinfo) -> c.int ---
	uv_freeaddrinfo :: proc(ai: ^addrinfo) ---
	uv_getnameinfo :: proc(loop: ^uv_loop_t, req: ^uv_getnameinfo_t, getnameinfo_cb: rawptr, addr: ^sockaddr, addrlen: c.int, flags: c.int) -> c.int ---

	uv_spawn :: proc(loop: ^uv_loop_t, handle: ^uv_process_t, options: ^uv_process_options_t) -> c.int ---
	uv_process_kill :: proc(handle: ^uv_process_t, signum: c.int) -> c.int ---
	uv_guess_handle :: proc(fd: c.int) -> c.int ---
	uv_get_total_memory :: proc() -> u64 ---
	uv_os_homedir :: proc(buffer: ^u8, size: ^c.size_t) -> c.int ---
	uv_cwd :: proc(buffer: ^u8, size: ^c.size_t) -> c.int ---
	uv_chdir :: proc(dir: cstring) -> c.int ---
	uv_exepath :: proc(buffer: ^u8, size: ^c.size_t) -> c.int ---
	uv_getpid :: proc() -> c.int ---

	// Process spawn FFI (added this session).
	uv_pipe :: proc(fds: ^c.int, read_flags: c.int, write_flags: c.int) -> c.int ---
}
