package main

import "core:c"
import "core:c/libc"

@(export)
signal_watcher_init :: proc "c" (loop: ^Loop, watcher: ^SignalWatcher, data: rawptr) {
	uv_signal_init(&loop.uv, &watcher.uv)
	watcher.uv.data = watcher
	watcher.data = data
	watcher.cb = nil
	watcher.events = loop.fast_events
}

@(export)
signal_watcher_start :: proc "c" (watcher: ^SignalWatcher, cb: signal_cb, signum: c.int) {
	watcher.cb = cb
	uv_signal_start(&watcher.uv, rawptr(signal_watcher_cb), signum)
}

@(export)
signal_watcher_stop :: proc "c" (watcher: ^SignalWatcher) {
	uv_signal_stop(&watcher.uv)
}

@(export)
signal_watcher_close :: proc "c" (watcher: ^SignalWatcher, cb: signal_close_cb) {
	watcher.close_cb = cb
	uv_close((^uv_handle_t)(&watcher.uv), rawptr(close_cb))
}

signal_event :: proc(argv: ^rawptr) {
	watcher := (^SignalWatcher)(argv^)
	watcher.cb(watcher, watcher.uv.signum, watcher.data)
}

signal_watcher_cb :: proc(handle: ^uv_signal_t, signum: c.int) {
	watcher := (^SignalWatcher)(handle.data)
	create_event(watcher.events, event_create(signal_event, watcher))
}

close_cb :: proc(handle: ^uv_handle_t) {
	watcher := (^SignalWatcher)(handle.data)
	if watcher.close_cb != nil {
		watcher.close_cb(watcher, watcher.data)
	}
}
