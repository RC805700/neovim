// event_defs.odin — Odin mirrors of src/nvim/event/defs.h (foundation types)
// + lib/queue_defs.h (QUEUE circular list).
//
// Only the event/multiqueue foundation lives here for now. libuv-backed
// watcher structs (SignalWatcher, TimeWatcher, Stream, RStream, SocketWatcher,
// Proc, Loop) are defined in their own odin files as the port progresses.

package main

import "core:c"

// Circular doubly-linked list (lib/queue_defs.h).
Queue :: struct {
	next: ^Queue,
	prev: ^Queue,
}

queue_init :: proc(q: ^Queue) {
	q.next = q
	q.prev = q
}

queue_empty :: proc(q: ^Queue) -> bool {
	return q == q.next
}

queue_head :: proc(q: ^Queue) -> ^Queue {
	return q.next
}

queue_insert_tail :: proc(h, q: ^Queue) {
	q.next = h
	q.prev = h.prev
	q.prev.next = q
	h.prev = q
}

queue_insert_head :: proc(h, q: ^Queue) {
	q.next = h.next
	q.prev = h
	q.next.prev = q
	h.next = q
}

queue_remove :: proc(q: ^Queue) {
	q.prev.next = q.next
	q.next.prev = q.prev
}

queue_data :: proc(q: ^Queue, $T: typeid, field_offset: uintptr) -> ^T {
	base := uintptr(rawptr(q))
	return (^T)(rawptr(base - field_offset))
}

// Event: a handler + up to 10 void* args (defs.h).
EVENT_HANDLER_MAX_ARGC :: 10

// Watcher / buffer structs (defs.h) with ABI-sized libuv buffers.
SignalWatcher :: struct {
	uv: uv_signal_t,
	data: rawptr,
	cb: signal_cb,
	close_cb: signal_close_cb,
	events: ^MultiQueue,
}

TimeWatcher :: struct {
	uv: uv_timer_t,
	data: rawptr,
	cb: time_cb,
	close_cb: time_cb,
	events: ^MultiQueue,
	blockable: bool,
}

WBuffer :: struct {
	size: c.size_t,
	refcount: c.size_t,
	data: ^u8,
	cb: wbuffer_data_finalizer,
}

SocketWatcher :: struct {
	addr: [256]u8,
	uv: [264]u8,        // max(uv_tcp_t 248 + addrinfo*, uv_pipe_t 264)
	stream: ^uv_stream_t,
	data: rawptr,
	cb: socket_cb,
	close_cb: socket_close_cb,
	events: ^MultiQueue,
}

// Callback typedefs (defs.h). These are type aliases, NOT foreign
// procedure declarations.
signal_cb :: proc(watcher: ^SignalWatcher, signum: c.int, data: rawptr)
signal_close_cb :: proc(watcher: ^SignalWatcher, data: rawptr)

time_cb :: proc(watcher: ^TimeWatcher, data: rawptr)

wbuffer_data_finalizer :: proc(data: rawptr)

stream_read_cb :: proc(stream: ^RStream, read_data: ^u8, count: c.size_t, data: rawptr, eof: bool) -> c.size_t

stream_write_cb :: proc(stream: ^Stream, data: rawptr, status: c.int)

stream_close_cb :: proc(stream: ^Stream, data: rawptr)

socket_cb :: proc(watcher: ^SocketWatcher, result: c.int, data: rawptr)

socket_close_cb :: proc(watcher: ^SocketWatcher, data: rawptr)

proc_exit_cb :: proc(p: ^Proc, status: c.int, data: rawptr)

proc_state_cb :: proc(p: ^Proc, suspended: bool, data: rawptr)

internal_proc_cb :: proc(p: ^Proc)

argv_callback :: proc(argv: ^rawptr)

Event :: struct {
	handler: argv_callback,
	argv: [EVENT_HANDLER_MAX_ARGC]rawptr,
}

event_create :: proc(cb: argv_callback, args: ..rawptr) -> Event {
	e: Event
	e.handler = cb
	for i in 0..<len(args) {
		e.argv[i] = args[i]
	}
	return e
}

// MultiQueue (multiqueue.c).
MultiQueue :: struct {
	parent: ^MultiQueue,
	headtail: Queue,
	on_put: PutCallback,
	data: rawptr,
	size: c.size_t,
}

PutCallback :: proc(mq: ^MultiQueue, data: rawptr)

// Loop (mirrors event/loop.h struct loop). Layout is ABI-compatible
// with C `struct loop` so the remaining C callers (main.c's
// event_init/event_teardown, proc.c, shell.c, etc.) keep working:
//   uv_loop_t 848, 3 ptrs (24), kvec_t(Proc*) (24, == [dynamic]^Proc),
//   uv_signal_t 152, uv_timer_t 152 x2, uv_timer_t 152, uv_async_t 128,
//   uv_mutex_t 40, int 4, bool 1.
Loop :: struct {
	uv: uv_loop_t,
	events: ^MultiQueue,
	thread_events: ^MultiQueue,
	fast_events: ^MultiQueue,
  // ABI-compatible mirror of C `kvec_t(Proc *)` = { size_t n; size_t a;
  // Proc **items; } (24 bytes). Odin's `[dynamic]^Proc` is 40 bytes and
  // would clobber following fields, so we mirror the C struct exactly.
  children: Kvec_Proc_ptr,
	children_watcher: uv_signal_t,
	children_kill_timer: uv_timer_t,
	poll_timer: uv_timer_t,
	exit_delay_timer: uv_timer_t,
	async: uv_async_t,
	mutex: uv_mutex_t,
	recursive: c.int,
	closing: bool,
}

ProcType :: enum {
	Uv,
	Pty,
}

// Field order MUST match C's `struct stream` in src/nvim/event/defs.h exactly,
// because C code (channel.c term_delayed_free, msgpack_rpc, etc.) reads these
// fields through the shared Channel union. data_incref/data_decref are at the
// END (after maxmem), NOT after cb_data — mismatch shifts pending_reqs and
// causes term_delayed_free to spin on garbage. #OdinPort ABI
Stream :: struct {
	closed: bool,
	uv: uv_stream_union,
	uvstream: ^uv_stream_t,
	fd: uv_file,
	fpos: i64,
	cb_data: rawptr,
	before_close_cb: stream_close_cb,
	close_cb: stream_close_cb,
	internal_close_cb: stream_close_cb,
	close_cb_data: rawptr,
	internal_data: rawptr,
	pending_reqs: c.size_t,
	events: ^MultiQueue,
	write_cb: stream_write_cb,
	curmem: c.size_t,
	maxmem: c.size_t,
	data_incref: proc(data: rawptr),
	data_decref: proc(data: rawptr),
}

RStream :: struct {
	s: Stream,
	did_eof: bool,
	want_read: bool,
	pending_read: bool,
	paused_full: bool,
	buffer: uintptr,
	read_pos: uintptr,
	write_pos: uintptr,
	uvbuf: uv_buf_t,
	read_cb: stream_read_cb,
	num_bytes: c.size_t,
}

Proc :: struct {
	kind: ProcType,
	loop: ^Loop,
	data: rawptr,
	pid: c.int,
	status: c.int,
	refcount: c.int,
	exit_signal: u8,
	stopped_time: u64,
	cwd: ^u8,
	argv: ^^u8,
	exepath: ^u8,
	env: rawptr,
	in_s: Stream,
	out_s: RStream,
	err_s: RStream,
	cb: proc_exit_cb,
	state_cb: proc_state_cb,
	internal_exit_cb: internal_proc_cb,
	internal_close_cb: internal_proc_cb,
	closed: bool,
	detach: bool,
	overlapped: bool,
	fwd_err: bool,
	stdio_noinherit: bool,
	events: ^MultiQueue,
}

// Mirror of C `kvec_t(Proc *)` = { size_t n; size_t a; Proc **items; } (24 bytes).
// NOTE: it stores POINTERS to Proc (matching C's `kvec_t(Proc *)`), NOT Proc
// values. `items` is an array of pointers (modeled as ^rawptr for Odin's
// lack of `^^T` syntax); element [i] is a `^Proc`. 24 bytes so the
// Loop layout matches C (see loop.h).
Kvec_Proc_ptr :: struct {
	n:     c.size_t,
	a:     c.size_t,
	items: ^rawptr,
}

// LibuvProc (Proc + uv_process_t(136) + uv_process_options_t(64)
// + 4*uv_stdio_container_t(64) = matches C `LibuvProc`). Field order MUST
// match C's `typedef struct { Proc proc; uv_process_t uv;
// uv_process_options_t uvopts; uv_stdio_container_t uvstdio[4]; } LibuvProc;`.
// NOTE: Proc fields are `in_s/out_s/err_s` in C; here they are `in_s/out_s/err_s`.
LibuvProc :: struct {
	base:     Proc,
	uv:       uv_process_t,
	uvopts:   uv_process_options_t,
	uvstdio:  [4]uv_stdio_container_t,
}

// Inline init mirroring nvim's `proc_init` (proc.h). Sets sensible defaults
// so the caller can override argv/exepath/cb/events/etc. afterward.
proc_init :: proc(loop: ^Loop, kind: ProcType, data: rawptr) -> Proc {
	p: Proc
	p.kind = kind
	p.data = data
	p.loop = loop
	p.events = nil
	p.pid = 0
	p.status = -1
	p.refcount = 0
	p.stopped_time = 0
	p.cwd = nil
	p.argv = nil
	p.exepath = nil
	p.env = nil
	p.in_s.closed = false
	p.out_s.s.closed = false
	p.out_s.s.fd = 1  // STDOUT_FILENO
	p.err_s.s.closed = false
	p.err_s.s.fd = 2  // STDERR_FILENO
	p.cb = nil
	p.state_cb = nil
	p.internal_close_cb = nil
	p.internal_exit_cb = nil
	p.closed = false
	p.detach = false
	p.overlapped = false
	p.fwd_err = false
	p.stdio_noinherit = false
	return p
}

// --- PTY (os/pty_proc_unix.c) structs ---

// `struct winsize` — 8 bytes, 4× uint16.
Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

// `struct termios` (glibc Linux) — 60 bytes. NOTE: `core:sys/posix.termios` is NOT
// ABI-compatible (it is a `#sparse [Control_Char]cc_t` keyed map, not a flat cc_t[]
// array). This raw mirror matches the C layout byte-for-byte (verified via offsetof probe).
// Order: c_iflag@0 c_oflag@4 c_cflag@8 c_lflag@12 c_line@16 c_cc[32]@17, pad to 60.
Termios :: struct {
	c_iflag: c.uint,
	c_oflag: c.uint,
	c_cflag: c.uint,
	c_lflag: c.uint,
	c_line:  c.uchar,
	c_cc:    [32]c.uchar,
	_pad:    [11]c.uchar,
}

// `PtyProc` (pty_proc_unix.h) — must match C layout exactly. NOTE: `proc` is a
// reserved keyword in Odin, so the embedded `Proc` field is named `proc_base`.
PtyProc :: struct {
	proc_base: Proc,
	width:     c.ushort,
	height:    c.ushort,
	winsize:   Winsize,
	tty_fd:    c.int,
}

// Linux signal numbers not already defined in os_signal.odin.
// NOTE: `posix.signal_libc` maps SIGCHLD/SIGCONT to -1 (broken in this Odin version),
// so use literal Linux x86_64 values where needed.
SIGALRM : c.int = 14
SIGCHLD : c.int = 17
SIGCONT : c.int = 18

// ioctl request numbers (Linux x86_64, from <sys/ioctl.h> / <asm/ioctls.h>).
TIOCSWINSZ : c.uint = 0x5414
TIOCSCTTY  : c.uint = 0x540e
TCSETS     : c.uint = 0x5402
