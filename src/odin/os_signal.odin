package main

import "core:c"
import "core:c/libc"
import "core:sys/posix"

// Port of os/signal.c (nvim-specific signal glue). The libuv wrappers
// (signal_watcher_*) live in signal.odin; this file wires them into nvim.

// Signal numbers (Linux). These are compile-time constants.
SIGPIPE  :: c.int(13)
SIGHUP   :: c.int(1)
SIGINT   :: c.int(2)
SIGQUIT  :: c.int(3)
SIGTERM  :: c.int(15)
SIGTSTP  :: c.int(20)
SIGPWR   :: c.int(30)
SIGUSR1  :: c.int(10)
SIGWINCH :: c.int(28)

// C globals (still defined in C; linked via foreign _).
// NOTE: preserve_exit, set_vim_var_nr, apply_autocmds are already declared
// (memory.odin / main.odin) — reuse those, do not redeclare.
foreign _ {
	@(link_name = "p_awa")
	p_awa: c.int

	@(link_name = "v_dying")
	v_dying: c.int

	@(link_name = "IObuff")
	IObuff: [1025]u8

	@(link_name = "autowrite_all")
	autowrite_all :: proc() ---

	@(link_name = "ml_sync_all")
	ml_sync_all :: proc(check_file: c.int, check_char: c.int, do_fsync: bool) ---
}

// VimVarIndex / event_T constants.
VV_DYING     :: c.int(30)
EVENT_SIGNAL :: c.int(103)

// SignalWatcher instances (mirror C's static globals).
spipe, shup, sint, squit, sterm, ststp, susr1, swinch, spwr: SignalWatcher

rejecting_deadly: bool

@(export)
signal_init :: proc "c" () {
	when ODIN_OS != .Windows {
		// Unblock all signals so libuv doesn't hang after subprocess spawn (#5230).
		mask: posix.sigset_t
		posix.sigemptyset(&mask)
		if c.int(posix.pthread_sigmask(posix.Sig(posix.SIG_SETMASK), &mask, nil)) != 0 {
			libc.fprintf(libc.stderr, cstring("Could not unblock signals, nvim might behave strangely.\n"))
		}
	}

	signal_watcher_init(&main_loop, &spipe, nil)
	signal_watcher_init(&main_loop, &shup, nil)
	signal_watcher_init(&main_loop, &sint, nil)
	signal_watcher_init(&main_loop, &squit, nil)
	signal_watcher_init(&main_loop, &sterm, nil)
	signal_watcher_init(&main_loop, &ststp, nil)
	when ODIN_OS != .Windows {
		signal_watcher_init(&main_loop, &spwr, nil)
		signal_watcher_init(&main_loop, &susr1, nil)
		signal_watcher_init(&main_loop, &swinch, nil)
	}
	signal_start()
}

@(export)
signal_teardown :: proc "c" () {
	signal_stop()
	signal_watcher_close(&spipe, nil)
	signal_watcher_close(&shup, nil)
	signal_watcher_close(&sint, nil)
	signal_watcher_close(&squit, nil)
	signal_watcher_close(&sterm, nil)
	signal_watcher_close(&ststp, nil)
	when ODIN_OS != .Windows {
		signal_watcher_close(&spwr, nil)
		signal_watcher_close(&susr1, nil)
		signal_watcher_close(&swinch, nil)
	}
}

@(export)
signal_start :: proc "c" () {
	when ODIN_OS != .Windows {
		signal_watcher_start(&spipe, on_signal, SIGPIPE)
	}
	signal_watcher_start(&shup, on_signal, SIGHUP)
	signal_watcher_start(&sint, on_signal, SIGINT)
	when ODIN_OS != .Windows {
		signal_watcher_start(&squit, on_signal, SIGQUIT)
	}
	signal_watcher_start(&sterm, on_signal, SIGTERM)
	when ODIN_OS != .Windows {
		signal_watcher_start(&ststp, on_signal, SIGTSTP)
		signal_watcher_start(&spwr, on_signal, SIGPWR)
		signal_watcher_start(&susr1, on_signal, SIGUSR1)
		signal_watcher_start(&swinch, on_signal, SIGWINCH)
	}
}

@(export)
signal_stop :: proc "c" () {
	when ODIN_OS != .Windows {
		signal_watcher_stop(&spipe)
	}
	signal_watcher_stop(&shup)
	signal_watcher_stop(&sint)
	when ODIN_OS != .Windows {
		signal_watcher_stop(&squit)
	}
	signal_watcher_stop(&sterm)
	when ODIN_OS != .Windows {
		signal_watcher_stop(&ststp)
		signal_watcher_stop(&spwr)
		signal_watcher_stop(&susr1)
		signal_watcher_stop(&swinch)
	}
}

@(export)
signal_reject_deadly :: proc "c" () {
	rejecting_deadly = true
}

@(export)
signal_accept_deadly :: proc "c" () {
	rejecting_deadly = false
}

signal_name :: proc(signum: c.int) -> ^u8 {
	name := cstring("Unknown\x00")
	switch signum {
	case SIGPWR:   name = cstring("SIGPWR\x00")
	case SIGTERM:  name = cstring("SIGTERM\x00")
	case SIGTSTP:  name = cstring("SIGTSTP\x00")
	case SIGQUIT:  name = cstring("SIGQUIT\x00")
	case SIGHUP:   name = cstring("SIGHUP\x00")
	case SIGINT:   name = cstring("SIGINT\x00")
	case SIGUSR1:  name = cstring("SIGUSR1\x00")
	case SIGWINCH: name = cstring("SIGWINCH\x00")
	}
	return transmute(^u8)(name)
}
deadly_signal :: proc(signum: c.int) {
	set_vim_var_nr(VV_DYING, 1)
	v_dying = 1

	libc.fprintf(libc.stderr, cstring("Nvim: Caught deadly signal\n"))

	if p_awa != 0 && signum != SIGTERM && signum != SIGINT {
		autowrite_all()
	}
	preserve_exit(cstring(&IObuff[0]))
}

@(export)
on_signal :: proc(watcher: ^SignalWatcher, signum: c.int, data: rawptr) {
	assert(signum >= 0)
	switch signum {
	case SIGPWR:
		// Power failure: flush swap files to be safe.
		ml_sync_all(0, 0, true)
	case SIGPIPE:
		// Ignore.
	case SIGTSTP:
		if p_awa != 0 {
			autowrite_all()
		}
	case SIGHUP, SIGINT, SIGTERM, SIGQUIT:
		if !rejecting_deadly {
			deadly_signal(signum)
		}
	case SIGUSR1:
		apply_autocmds(EVENT_SIGNAL, cstring("SIGUSR1"), nil, true, curbuf)
	case SIGWINCH:
		apply_autocmds(EVENT_SIGNAL, cstring("SIGWINCH"), nil, true, curbuf)
	default: {
		libc.fprintf(libc.stderr, cstring("invalid signal: %d\n"), signum)
	}
	}
}
