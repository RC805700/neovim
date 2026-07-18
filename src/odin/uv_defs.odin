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
	_pad: [80]u8,
}

uv_async_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [112]u8,
}

uv_signal_t :: struct {
	data: rawptr,
	loop: ^uv_loop_t,
	_pad: [136]u8,
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
	_pad: [232]u8,
}

// uv_buf_t (16): { char *base; size_t len } on 64-bit.
uv_buf_t :: struct {
	base: ^u8,
	len: u64,
}

uv_file :: distinct c.int

// Stream's `uv` union: max of uv_pipe_t(264)/uv_tcp_t(248)/
// uv_idle_t(120) on Linux (uv_tty_t is MSWin-only in the union).
uv_stream_union :: [264]u8

uv_run_mode :: enum {
	UV_RUN_DEFAULT = 0,
	UV_RUN_ONCE,
	UV_RUN_NOWAIT,
}

UV_EBUSY :: c.int(-16)  // from uv.h errno mapping

foreign _ {
	@(link_name = "uv_loop_init")
	uv_loop_init :: proc(loop: ^uv_loop_t) -> c.int ---

	@(link_name = "uv_run")
	uv_run :: proc(loop: ^uv_loop_t, mode: uv_run_mode) -> c.int ---

	@(link_name = "uv_stop")
	uv_stop :: proc(loop: ^uv_loop_t) ---

	@(link_name = "uv_async_init")
	uv_async_init :: proc(loop: ^uv_loop_t, handle: ^uv_async_t, cb: rawptr) -> c.int ---

	@(link_name = "uv_async_send")
	uv_async_send :: proc(handle: ^uv_async_t) -> c.int ---

	@(link_name = "uv_signal_init")
	uv_signal_init :: proc(loop: ^uv_loop_t, handle: ^uv_signal_t) -> c.int ---

	@(link_name = "uv_timer_init")
	uv_timer_init :: proc(loop: ^uv_loop_t, handle: ^uv_timer_t) -> c.int ---

	@(link_name = "uv_mutex_init")
	uv_mutex_init :: proc(handle: ^uv_mutex_t) -> c.int ---

	@(link_name = "uv_mutex_destroy")
	uv_mutex_destroy :: proc(handle: ^uv_mutex_t) ---

	@(link_name = "uv_mutex_lock")
	uv_mutex_lock :: proc(handle: ^uv_mutex_t) ---

	@(link_name = "uv_mutex_unlock")
	uv_mutex_unlock :: proc(handle: ^uv_mutex_t) ---

	@(link_name = "uv_close")
	uv_close :: proc(handle: ^uv_handle_t, close_cb: rawptr) ---

	@(link_name = "uv_is_closing")
	uv_is_closing :: proc(handle: ^uv_handle_t) -> c.int ---

	@(link_name = "uv_walk")
	uv_walk :: proc(loop: ^uv_loop_t, walk_cb: rawptr, arg: rawptr) ---

	@(link_name = "uv_loop_close")
	uv_loop_close :: proc(loop: ^uv_loop_t) -> c.int ---

	@(link_name = "uv_timer_start")
	uv_timer_start :: proc(handle: ^uv_timer_t, cb: rawptr, timeout: u64, repeat: u64) -> c.int ---

	@(link_name = "uv_timer_stop")
	uv_timer_stop :: proc(handle: ^uv_timer_t) -> c.int ---
}
