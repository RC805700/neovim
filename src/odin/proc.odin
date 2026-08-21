// proc.odin — Odin port of src/nvim/event/proc.c
// Process lifecycle: spawn, teardown, wait, stop, free, and the close/exit
// event machinery. Libuv is the engine (FFI via -luv); the LibuvProc-specific
// spawn/close lives in libuv_proc.odin.

package main

import "core:c"
import "base:runtime"

// Signal numbers: SIGTERM/SIGHUP/SIGINT are in os_signal.odin; SIGKILL here.
SIGKILL :: c.int(9)
UINT64_MAX :: u64(0xffffffffffffffff)
SIZE_MAX  :: uintptr(0xffffffffffffffff)

// Time for a process to exit cleanly before we send KILL.
KILL_TIMEOUT_MS :: u64(2000)

// SIGTERM is sent first for PTY (handled by pty_proc); for uv we send SIGTERM
// then SIGKILL via children_kill_cb.
proc_is_tearing_down: bool = false
exit_need_delay: c.int = 0

// Mirror of C `LOOP_PROCESS_EVENTS_UNTIL(loop, q, ms, cond)`: pump the loop
// until `cond()` is true or (ms != -1 and the timeout elapses). Returns when
// the condition holds.
loop_process_events_until :: proc(loop: ^Loop, ms: i64, cond: proc() -> bool) {
	for !cond() {
		if ms >= 0 {
			if !loop_poll_events(loop, ms) {
				return
			}
		} else {
			loop_poll_events(loop, ms)
		}
	}
}

// Mirror of C `LOOP_PROCESS_EVENTS(loop, multiqueue, timeout)`:
// if `q` has queued events, process THOSE (no poll); else poll the loop.
loop_process_events_q :: proc "c" (loop: ^Loop, q: ^MultiQueue, ms: i64) {
	context = runtime.default_context()
	if q != nil && !multiqueue_empty(q) {
		multiqueue_process_events(q)
	} else {
		loop_poll_events(loop, ms)
	}
}

// kvec helpers for Loop.children (Kvec_Proc_ptr).
kv_children_size :: proc(loop: ^Loop) -> c.size_t {
	return loop.children.n
}
kv_children_at :: proc(loop: ^Loop, i: c.size_t) -> ^Proc {
	return (^Proc)(([^]rawptr)(loop.children.items)[i])
}
kv_children_push :: proc(loop: ^Loop, p: ^Proc) {
	n := loop.children.n
	// Grow if needed (items is a heap array of `Proc *`, sized `a`).
	if n >= loop.children.a {
		new_a := loop.children.a * 2
		if new_a == 0 {
			new_a = 4
		}
		new_items := (^rawptr)(xmalloc(new_a * size_of(rawptr)))
		if loop.children.items != nil && n > 0 {
			copy(([^]rawptr)(new_items)[0:n], ([^]rawptr)(loop.children.items)[0:n])
			xfree(loop.children.items)
		}
		loop.children.items = new_items
		loop.children.a = new_a
	}
	([^]rawptr)(loop.children.items)[n] = rawptr(p)
	loop.children.n = n + 1
}
kv_children_remove_at :: proc(loop: ^Loop, i: c.size_t) {
	n := loop.children.n
	if i < n - 1 {
		copy(([^]rawptr)(loop.children.items)[i:n-1], ([^]rawptr)(loop.children.items)[i+1:n])
	}
	loop.children.n = n - 1
}

@(export)
proc_spawn :: proc "c" (pr: ^Proc, in_s: bool, out_s: bool, err_s: bool) -> c.int {
	context = runtime.default_context()
	// forwarding stderr contradicts with processing it internally
	assert(!(err_s && pr.fwd_err))

	if in_s {
		uv_pipe_init(&pr.loop.uv, (^uv_pipe_t)(&pr.in_s.uv), 0)
	} else {
		pr.in_s.closed = true
	}

	if out_s {
		uv_pipe_init(&pr.loop.uv, (^uv_pipe_t)(&pr.out_s.s.uv), 0)
	} else {
		pr.out_s.s.closed = true
	}

	if err_s {
		uv_pipe_init(&pr.loop.uv, (^uv_pipe_t)(&pr.err_s.s.uv), 0)
	} else {
		pr.err_s.s.closed = true
	}

	status: c.int
	if pr.kind == ProcType.Uv {
		status = libuv_proc_spawn((^LibuvProc)(pr))
	} else {
		status = pty_proc_spawn((^PtyProc)(pr))
	}

	if status != 0 {
		if in_s {
			uv_close((^uv_handle_t)(&pr.in_s.uv), nil)
		}
		if out_s {
			uv_close((^uv_handle_t)(&pr.out_s.s.uv), nil)
		}
		if err_s {
			uv_close((^uv_handle_t)(&pr.err_s.s.uv), nil)
		}

		if pr.kind == ProcType.Uv {
			uv_close((^uv_handle_t)(&((^LibuvProc)(pr)).uv), nil)
		}
		proc_free(pr)
		pr.status = -1
		return status
	}

	if in_s {
		stream_init(nil, &pr.in_s, -1, (^uv_stream_t)(&pr.in_s.uv))
		pr.in_s.internal_data = pr
		pr.in_s.internal_close_cb = on_proc_stream_close
		pr.refcount += 1
	}

	if out_s {
		stream_init(nil, &pr.out_s.s, -1, (^uv_stream_t)(&pr.out_s.s.uv))
		pr.out_s.s.internal_data = pr
		pr.out_s.s.internal_close_cb = on_proc_stream_close
		// Wire read events to the job's event queue (set by channel.c). Matches
		// C proc_spawn (bak/event/proc.c:114). Without this, read_event is handled
		// synchronously (events==nil), but term_delayed_free (channel.c) checks
		// out.s.pending_reqs and re-queues forever if a pending read never drains
		// via the job's queue during teardown.
		pr.out_s.s.events = pr.events
		pr.refcount += 1
	}

	if err_s {
		stream_init(nil, &pr.err_s.s, -1, (^uv_stream_t)(&pr.err_s.s.uv))
		pr.err_s.s.internal_data = pr
		pr.err_s.s.internal_close_cb = on_proc_stream_close
		pr.err_s.s.events = pr.events
		pr.refcount += 1
	}

	pr.internal_exit_cb = on_proc_exit
	pr.internal_close_cb = decref
	pr.refcount += 1
	kv_children_push(pr.loop, pr)
	return 0
}

@(export)
proc_teardown :: proc "c" (loop: ^Loop) {
	context = runtime.default_context()
	proc_is_tearing_down = true
	for i := c.size_t(0); i < kv_children_size(loop); i += 1 {
		pr := kv_children_at(loop, i)
		if pr.detach || pr.kind == ProcType.Pty {
			// Close handles to process without killing it.
			e := event_create(proc_close_handles, pr)
			create_event(loop.events, e)
		} else {
			proc_stop(pr)
		}
	}

 	// Wait until all children exit and all close events are processed. Mirrors
	// C's LOOP_PROCESS_EVENTS_UNTIL / LOOP_PROCESS_EVENTS: when the queue has
	// pending events, process them WITHOUT polling libuv; only block on
	// loop_poll_events(-1) when the queue is empty. (A bare poll after every
	// process step deadlocks on requeueing handlers like term_delayed_free.)
	for !(kv_children_size(loop) == 0 && multiqueue_empty(loop.events)) {
		if !multiqueue_empty(loop.events) {
			multiqueue_process_events(loop.events)
		} else {
			loop_poll_events(loop, -1)
		}
	}
	pty_proc_teardown(loop)
}

@(export)
proc_close_streams :: proc "c" (pr: ^Proc) {
	context = runtime.default_context()
	stream_may_close(&pr.in_s)
	rstream_may_close(&pr.out_s)
	rstream_may_close(&pr.err_s)
}

/// Synchronously wait for a process to finish.
@(export)
proc_wait :: proc "c" (pr: ^Proc, ms: c.int, events: ^MultiQueue) -> c.int {
	context = runtime.default_context()
	if pr.refcount == 0 {
		status := pr.status
		loop_process_events_q(pr.loop, pr.events, 0)
		return status
	}

	ev := events
	if ev == nil {
		ev = pr.events
	}

	// Increase refcount to stop the exit callback from being called (and
	// possibly freed) before we have a chance to get the status.
	pr.refcount += 1
	// Mirror C LOOP_PROCESS_EVENTS_UNTIL(proc->loop, ev, ms, cond): each
	// iteration, if `ev` has queued events process THOSE (without polling),
	// otherwise poll the loop. `ev` (e.g. jobwait's `waiting_jobs`) carries
	// the job's exit event, so it MUST be drained here or refcount never
	// reaches 1 and this loop spins forever.
	{
		remaining := i64(ms)
		before: u64 = remaining > 0 ? os_hrtime() : 0
		for !(got_int || pr.refcount == 1) {
			loop_process_events_q(pr.loop, ev, remaining)
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
	// Assume that a user hitting CTRL-C does not like the current job. Kill it.
	if got_int {
		got_int = false
		proc_stop(pr)
		if ms == -1 {
			for pr.refcount != 1 {
				loop_process_events_q(pr.loop, ev, -1)
			}
		} else {
			loop_process_events_q(pr.loop, ev, 0)
		}
		pr.status = -2
	}

	if pr.refcount == 1 {
		// Job exited, free its resources.
		decref(pr)
		if pr.events != nil {
			// decref() created an exit event, process it now.
			multiqueue_process_events(pr.events)
		}
	} else {
		pr.refcount -= 1
	}

	return pr.status
}

/// Ask a process to terminate and eventually kill if it doesn't respond.
@(export)
proc_stop :: proc "c" (pr: ^Proc) {
	context = runtime.default_context()
	exited := (pr.status >= 0)
	if exited || pr.stopped_time != 0 {
		return
	}
	pr.stopped_time = os_hrtime()

	if pr.kind == ProcType.Uv {
		pr.exit_signal = u8(SIGTERM)
		os_proc_tree_kill(pr.pid, SIGTERM)
	} else {
		// PTY: close streams to send SIGHUP.
		pr.exit_signal = u8(SIGHUP)
		proc_close_streams(pr)
	}

	uv_timer_start(&pr.loop.children_kill_timer, rawptr(children_kill_cb), KILL_TIMEOUT_MS, 0)
}

/// Frees process-owned resources.
@(export)
proc_free :: proc "c" (pr: ^Proc) {
	context = runtime.default_context()
	if pr.argv != nil {
		shell_free_argv(pr.argv)
		pr.argv = nil
	}
}

// Sends SIGKILL (or SIGTERM..SIGKILL for PTY jobs) to processes that did
// not terminate after proc_stop().
children_kill_cb :: proc(handle: ^uv_timer_t) {
	loop := (^Loop)(handle.loop.data)

	for i := c.size_t(0); i < kv_children_size(loop); i += 1 {
		pr := kv_children_at(loop, i)
		exited := (pr.status >= 0)
		if exited || pr.stopped_time == 0 {
			continue
		}
		term_sent := (UINT64_MAX == pr.stopped_time)
		if pr.kind != ProcType.Pty || term_sent {
			pr.exit_signal = u8(SIGKILL)
			os_proc_tree_kill(pr.pid, SIGKILL)
		} else {
			pr.exit_signal = u8(SIGTERM)
			os_proc_tree_kill(pr.pid, SIGTERM)
			pr.stopped_time = UINT64_MAX  // Flag: SIGTERM was sent.
			uv_timer_start(&pr.loop.children_kill_timer, rawptr(children_kill_cb), KILL_TIMEOUT_MS, 0)
		}
	}
}

proc_close_event :: proc(argv: ^rawptr) {
	pr := (^Proc)(([^]rawptr)(argv)[0])
	if pr.cb != nil {
		// User (hint: channel_job_start) is responsible for calling proc_free().
		pr.cb(pr, pr.status, pr.data)
	} else {
		proc_free(pr)
	}
}

decref :: proc(pr: ^Proc) {
	if pr.refcount -= 1; pr.refcount != 0 {
		return
	}

	loop := pr.loop
	i := c.size_t(0)
	for ; i < kv_children_size(loop); i += 1 {
		current := kv_children_at(loop, i)
		if current == pr {
			break
		}
	}
	assert(i < kv_children_size(loop))  // element found
	kv_children_remove_at(loop, i)
	e := event_create(proc_close_event, pr)
	create_event(pr.events, e)
}

proc_close :: proc(pr: ^Proc) {
	if proc_is_tearing_down && pr.closed && (pr.detach || pr.kind == ProcType.Pty) {
		// If a detached/pty process dies while tearing down it might get
		// closed twice.
		return
	}
	assert(!pr.closed)
	pr.closed = true

	if pr.detach {
		if pr.kind == ProcType.Uv {
			uv_unref((^uv_handle_t)(&((^LibuvProc)(pr)).uv))
		}
	}

	if pr.kind == ProcType.Uv {
		libuv_proc_close((^LibuvProc)(pr))
	} else if pr.kind == ProcType.Pty {
		pty_proc_close((^PtyProc)(pr))
	}
}

// Flush output stream.
flush_stream :: proc(pr: ^Proc, stream: ^RStream) {
	if stream == nil || stream.s.closed {
		return
	}

	max_bytes := uintptr(SIZE_MAX)
	// Don't limit remaining data size of PTY master unless when tearing down.
	if pr.kind != ProcType.Pty || proc_is_tearing_down {
		// Maximal remaining data size of terminated process is system buffer
		// size. Also helps with a child process that keeps the output streams
		// open.
		system_buffer_size := c.int(0)
		err := uv_recv_buffer_size((^uv_handle_t)(&stream.s.uv), &system_buffer_size)
		if err != 0 {
			system_buffer_size = ARENA_BLOCK_SIZE
		}
		max_bytes = uintptr(stream.num_bytes) + uintptr(system_buffer_size)
	}

	for !stream.s.closed && uintptr(stream.num_bytes) < max_bytes {
		num_bytes := stream.num_bytes
		loop_poll_events(pr.loop, 0)
		if stream.s.events != nil {
			multiqueue_process_events(stream.s.events)
		}

		if num_bytes == stream.num_bytes {
			if stream.read_cb != nil && !stream.did_eof {
				stream.read_cb(stream, (^u8)(stream.buffer), 0, stream.s.cb_data, true)
			}
			break
		}
	}
}

proc_close_handles :: proc(argv: ^rawptr) {
	pr := (^Proc)(([^]rawptr)(argv)[0])

	exit_need_delay += 1
	flush_stream(pr, &pr.out_s)
	flush_stream(pr, &pr.err_s)

	proc_close_streams(pr)
	proc_close(pr)
	exit_need_delay -= 1
}

exit_delay_cb :: proc(handle: ^uv_timer_t) {
	uv_timer_stop(&main_loop.exit_delay_timer)
	multiqueue_put_event(main_loop.fast_events, exit_event_event)
}

// Reusable exit_event Event for the fast_events queue.
exit_event_event: Event

exit_event :: proc(argv: ^rawptr) {
	status := c.int(uintptr(([^]rawptr)(argv)[0]))
	if exit_need_delay != 0 {
		exit_event_event = event_create(exit_event, rawptr(uintptr(status)))
		main_loop.exit_delay_timer.data = rawptr(uintptr(status))
		uv_timer_start(&main_loop.exit_delay_timer, rawptr(exit_delay_cb), 0, 0)
		return
	}

	if !exiting {
		if ui_client_channel_id != 0 {
			ui_client_exit_status = status
			os_exit(status)
		} else {
			assert(status == 0)  // Called from rpc_close(), which passes 0.
			preserve_exit(nil)
		}
	}
}

/// Performs self-exit because the primary RPC channel was closed.
@(export)
exit_on_closed_chan :: proc "c" (status: c.int) {
	context = runtime.default_context()
	e := event_create(exit_event, rawptr(uintptr(status)))
	multiqueue_put_event(main_loop.fast_events, e)
}

on_proc_exit :: proc(pr: ^Proc) {
	loop := pr.loop
	// Process has terminated, but there could still be data to be read. Queue
	// proc_close_handles as an event delayed after the libuv loop.
	queue := pr.events
	if queue == nil {
		queue = loop.events
	}
	e := event_create(proc_close_handles, pr)
	create_event(queue, e)
}

on_proc_stream_close :: proc(stream: ^Stream, data: rawptr) {
	pr := (^Proc)(data)
	decref(pr)
}
