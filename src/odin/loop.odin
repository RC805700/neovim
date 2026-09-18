// loop.odin — port of src/nvim/event/loop.c
//
// The event-loop orchestrator. libuv is the engine (FFI via -luv); the
// Neovim-specific glue (queues, recursive guard, cross-thread async,
// close walk) is reimplemented here. `Loop` layout is ABI-compatible
// with C `struct loop` (see loop.h) so the remaining C callers
// (main.c event_init/event_teardown, proc.c, shell.c, etc.) keep
// linking against the Odin @(export) symbols.
//
// NOTE: the `Loop` type itself is defined in event_defs.odin (alongside
// `Proc`) because the two reference each other via pointers.

package main

import "core:c"
import "base:runtime"
import "core:c/libc"

@(export)
main_loop := Loop{}

// C-side helpers still linked (log.c). proc_teardown is provided by
// proc.odin (Odin port of event/proc.c).
foreign _ {
	@(link_name = "log_uv_handles")
	log_uv_handles :: proc(loop: rawptr) ---
}

@(export)
loop_init :: proc "c" (loop: ^Loop, data: rawptr) {
	context = runtime.default_context()
	uv_loop_init(&loop.uv)
	loop.recursive = 0
	loop.closing = false
	(^rawptr)(&loop.uv)^ = loop  // uv.data = loop
	loop.children = Kvec_Proc_ptr{}  // kvec zero-init
	loop.events = multiqueue_new(loop_on_put, loop)
	loop.fast_events = multiqueue_new_child(loop.events)
	loop.thread_events = multiqueue_new(nil, nil)
	uv_mutex_init(&loop.mutex)
	uv_async_init(&loop.uv, &loop.async, rawptr(loop_async_cb))
	uv_signal_init(&loop.uv, &loop.children_watcher)
	uv_timer_init(&loop.uv, &loop.children_kill_timer)
	uv_timer_init(&loop.uv, &loop.poll_timer)
	uv_timer_init(&loop.uv, &loop.exit_delay_timer)
	loop.poll_timer.data = xmalloc(c.size_t(size_of(bool)))
}

loop_uv_run :: proc(loop: ^Loop, ms: i64) -> bool {
	assert(loop.recursive == 0)  // must not re-enter uv_run
	loop.recursive += 1

	mode := uv_run_mode.UV_RUN_ONCE
	timeout_expired := (^bool)(loop.poll_timer.data)
	timeout_expired^ = false

	if ms > 0 {
		uv_timer_start(&loop.poll_timer, rawptr(loop_timer_cb), u64(ms), u64(ms))
	} else if ms == 0 {
		mode = uv_run_mode.UV_RUN_NOWAIT
	}

	uv_run(&loop.uv, mode)

	if ms > 0 {
		uv_timer_stop(&loop.poll_timer)
	}

	loop.recursive -= 1
	return timeout_expired^
}

@(export)
loop_poll_events :: proc "c" (loop: ^Loop, ms: i64) -> bool {
	context = runtime.default_context()
	timeout_expired := loop_uv_run(loop, ms)
	// C-faithful: drain fast_events ONLY. loop.events is NOT drained here
	// ("Does NOT process Loop.events, that is an application-specific
	// decision" — event/loop.c). Callers that need loop.events (proc_teardown,
	// state machine) drain it explicitly. Draining it here runs vim.schedule
	// callbacks before fed typeahead is processed, inverting C's ordering
	// (which-key trigger re-attach raced fed keys → "Recursion detected").
	// proc_wait() is unaffected: it drains its own queue via
	// loop_process_events_q (proc.odin).
	multiqueue_process_events(loop.fast_events)
	return timeout_expired
}

@(export)
loop_schedule_fast :: proc "c" (loop: ^Loop, event: Event) {
	context = runtime.default_context()
	uv_mutex_lock(&loop.mutex)
	multiqueue_put_event(loop.thread_events, event)
	uv_async_send(&loop.async)
	uv_mutex_unlock(&loop.mutex)
}

@(export)
loop_schedule_deferred :: proc "c" (loop: ^Loop, event: Event) {
	context = runtime.default_context()
	eventp := (^Event)(xmalloc(c.size_t(size_of(Event))))
	eventp^ = event
	loop_schedule_fast(loop, event_create(loop_deferred_event, loop, eventp))
}

loop_deferred_event :: proc(argv: ^rawptr) {
	loop := (^Loop)(argv^)
	eventp := (^Event)((^rawptr)(rawptr(uintptr(argv) + size_of(rawptr)))^)
	multiqueue_put_event(loop.events, eventp^)
	xfree(eventp)
}

@(export)
loop_on_put :: proc(queue: ^MultiQueue, data: rawptr) {
	loop := (^Loop)(data)
	if loop.recursive != 0 {
		uv_stop(&loop.uv)
	}
}

loop_walk_cb :: proc(handle: ^uv_handle_t, arg: rawptr) {
	if uv_is_closing(handle) == 0 {
		uv_close(handle, nil)
	}
}

@(export)
loop_close :: proc "c" (loop: ^Loop, wait: bool) -> bool {
	context = runtime.default_context()
	rv := true
	loop.closing = true
	uv_mutex_destroy(&loop.mutex)
	uv_close((^uv_handle_t)(&loop.children_watcher), nil)
	uv_close((^uv_handle_t)(&loop.children_kill_timer), nil)
	uv_close((^uv_handle_t)(&loop.poll_timer), rawptr(loop_timer_close_cb))
	uv_close((^uv_handle_t)(&loop.exit_delay_timer), nil)
	uv_close((^uv_handle_t)(&loop.async), nil)

	start: u64 = 0
	if wait {
		start = os_hrtime()
	}
	didstop := false
	for {
		uv_run(&loop.uv, loop_didstop_mode(didstop))
		if (uv_loop_close(&loop.uv) != UV_EBUSY) || !wait {
			break
		}
		elapsed_s := (os_hrtime() - start) / 1000000000
		if elapsed_s >= 2 {
			rv = false
			log_uv_handles(loop)
			break
		}
		if !didstop {
			uv_stop(&loop.uv)
			uv_walk(&loop.uv, rawptr(loop_walk_cb), nil)
			didstop = true
		}
	}
	multiqueue_free(loop.fast_events)
	multiqueue_free(loop.thread_events)
	multiqueue_free(loop.events)
	// loop.children.items is freed by C (kvec_destroy / free_all_mem).
	return rv
}

loop_didstop_mode :: proc(didstop: bool) -> uv_run_mode {
	if didstop {
		return uv_run_mode.UV_RUN_DEFAULT
	}
	return uv_run_mode.UV_RUN_NOWAIT
}

@(export)
loop_purge :: proc "c" (loop: ^Loop) {
	context = runtime.default_context()
	uv_mutex_lock(&loop.mutex)
	multiqueue_purge_events(loop.thread_events)
	multiqueue_purge_events(loop.fast_events)
	uv_mutex_unlock(&loop.mutex)
}

@(export)
loop_size :: proc "c" (loop: ^Loop) -> c.size_t {
	uv_mutex_lock(&loop.mutex)
	rv := multiqueue_size(loop.thread_events)
	uv_mutex_unlock(&loop.mutex)
	return rv
}

loop_async_cb :: proc(handle: ^uv_async_t) {
	l := (^Loop)(handle.loop.data)
	uv_mutex_lock(&l.mutex)
	multiqueue_move_events(l.fast_events, l.thread_events)
	uv_mutex_unlock(&l.mutex)
}

loop_timer_cb :: proc(handle: ^uv_timer_t) {
	timeout_expired := (^bool)(handle.data)
	timeout_expired^ = true
}

loop_timer_close_cb :: proc(handle: ^uv_handle_t) {
	xfree(handle.data)
}
