// time_watcher.odin — Odin port of src/nvim/event/time.c
// Keeps libuv as the engine (FFI via -luv); reimplements nvim TimeWatcher
// logic. All procs are @(export) proc "c" so the ~20 C consumers (channel.c,
// terminal.c, main.c, etc.) keep linking against the symbols.

package main

import "base:runtime"
import "core:c"

time_event :: proc(argv: ^rawptr) {
	watcher := (^TimeWatcher)(argv^)
	watcher.cb(watcher, watcher.data)
}

close_event :: proc(argv: ^rawptr) {
	watcher := (^TimeWatcher)(argv^)
	watcher.close_cb(watcher, watcher.data)
}

// uv_timer_cb signature used by libuv: void (*)(uv_timer_t*).
time_watcher_cb :: proc "c" (handle: ^uv_timer_t) {
	watcher := (^TimeWatcher)(handle.data)
	if watcher.blockable && !multiqueue_empty(watcher.events) {
		// the timer blocked and there already is an unprocessed event waiting
		return
	}
	e: Event
	e.handler = time_event
	e.argv[0] = watcher
	create_event(watcher.events, e)
}

time_close_cb :: proc "c" (handle: ^uv_handle_t) {
	watcher := (^TimeWatcher)(handle.data)
	if watcher.close_cb != nil {
		e: Event
		e.handler = close_event
		e.argv[0] = watcher
		create_event(watcher.events, e)
	}
}

@(export)
time_watcher_init :: proc "c" (loop: ^Loop, watcher: ^TimeWatcher, data: rawptr) {
	uv_timer_init(&loop.uv, &watcher.uv)
	watcher.uv.data = watcher
	watcher.data = data
	watcher.events = loop.fast_events
	watcher.blockable = false
}

@(export)
time_watcher_start :: proc "c" (watcher: ^TimeWatcher, cb: time_cb, timeout: u64, repeat: u64) {
	watcher.cb = cb
	uv_timer_start(&watcher.uv, rawptr(time_watcher_cb), timeout, repeat)
}

@(export)
time_watcher_stop :: proc "c" (watcher: ^TimeWatcher) {
	uv_timer_stop(&watcher.uv)
}

@(export)
time_watcher_close :: proc "c" (watcher: ^TimeWatcher, cb: time_cb) {
	watcher.close_cb = cb
	uv_close(transmute(^uv_handle_t)(&watcher.uv), rawptr(time_close_cb))
}
