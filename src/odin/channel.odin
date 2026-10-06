package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/posix"

// channel.c port: Channel lifecycle, job/socket/stdio channels, output
// dispatch, info. Publics are @(export); C-statics are _o dormant plains.
// msgpack_rpc/*, terminal.c, ui_client.c stay C (FFI below).

foreign _ {
	@(link_name = "rpc_close")
	rpc_close_e :: proc "c" (chan: rawptr) ---
	@(link_name = "rpc_free")
	rpc_free_e :: proc "c" (chan: rawptr) ---
	@(link_name = "rpc_start")
	rpc_start_e :: proc "c" (chan: rawptr) ---
	@(link_name = "rpc_init")
	rpc_init_e :: proc "c" () ---
	@(link_name = "server_owns_pipe_address")
	server_owns_pipe_address_e :: proc "c" (address: cstring) -> bool ---
	@(link_name = "terminal_alloc")
	terminal_alloc_e :: proc "c" (buf: rawptr, opts: TerminalOptions_O) -> rawptr ---
	@(link_name = "terminal_set_state")
	terminal_set_state_e :: proc "c" (term: rawptr, suspended: bool) ---
	@(link_name = "terminal_receive")
	terminal_receive_e :: proc "c" (term: rawptr, data: ^u8, len: C.size_t) ---
	@(link_name = "terminal_destroy")
	terminal_destroy_e :: proc "c" (termpp: rawptr) ---
	// ui_client_attach_to_restarted_server now defined in ui_client.odin — call directly.
}

// Moved channel.c statics (single copy; no other C file touches them).
next_chan_id_g: u64 = 3
did_stdio_g: bool = false

CHAN_STDIO_O :: 1
CHAN_STDERR_O :: 2
KCHSTREAM_SOCKET_O :: 1
KCHSTREAM_STDIO_O :: 2
KCHSTREAM_STDERR_O :: 3
KCHSTREAM_INTERNAL_O :: 4
E_INVCHAN_S :: "E900: Invalid channel id"
E_INVSTREAM_S :: "E906: invalid stream for channel"
E_INVSTREAMRPC_S :: "E906: invalid stream for rpc channel, use 'rpc'"
E_STREAMKEY_S :: "E5210: dict key '%s' already set for buffered stream in channel %llu"
E_JOBSPAWN_S :: "E903: Process failed to start: %s: \"%s\""
EVENT_CHANOPEN_O :: 24
EVENT_CHANCLOSE_O :: 22

// StderrState mirror (1B).
StderrState_O :: struct {
	closed: bool,
}

// InternalState mirror (8B: cb@0, closed@4).
InternalState_O :: struct {
	cb:     C.int,
	closed: bool,
}

// RpcState mirror (cc-probed, 88B, info@56).
RpcState_O :: struct {
	_pad:  [56]u8,
	info:  Api_Dict,
	_tail: [8]u8,
}
#assert(size_of(RpcState_O) == 88)

// Channel mirror (cc-probed, 2008B).
Channel_O :: struct {
	id:                 u64,
	refcount:           C.size_t,
	events:             ^MultiQueue,
	streamtype:         C.int,
	_pad0:              [4]u8,
	stream:             LibuvProc,
	is_rpc:             bool,
	detach:             bool,
	_pad1:              [6]u8,
	rpc:                RpcState_O,
	term:               rawptr,
	on_data:            CallbackReader_E,
	on_stderr:          CallbackReader_E,
	on_exit:            Callback_E,
	exit_status:        C.int,
	callback_busy:      bool,
	callback_scheduled: bool,
	did_close_event:    bool,
	_pad2:              [1]u8,
}
#assert(size_of(Channel_O) == 2008)

// TerminalOptions mirror (cc-probed, 64B).
TerminalOptions_O :: struct {
	data:       rawptr,
	width:      u16,
	height:     u16,
	_pad0:      [4]u8,
	read_pause: proc "c" (pause: bool, data: rawptr),
	write:      proc "c" (buf: ^u8, size: C.size_t, data: rawptr),
	resize:     proc "c" (width: u16, height: u16, data: rawptr),
	resume:     proc "c" (data: rawptr),
	close:      proc "c" (data: rawptr),
	force_crlf: bool,
	_pad1:      [7]u8,
}
#assert(size_of(TerminalOptions_O) == 64)

// channel.h static inlines.
channel_instream_o :: proc "c" (chan: ^Channel_O) -> ^Stream {
	context = runtime.default_context()
	if chan.streamtype == 0 {
		return &((^Proc)(rawptr(&chan.stream))).in_s
	} else if chan.streamtype == KCHSTREAM_SOCKET_O {
		return &((^RStream)(rawptr(&chan.stream))).s
	} else if chan.streamtype == KCHSTREAM_STDIO_O {
		s := (^Stream)(rawptr(uintptr(&chan.stream) + 464))
		return s
	}
	libc.abort()
}

channel_outstream_o :: proc "c" (chan: ^Channel_O) -> ^RStream {
	context = runtime.default_context()
	if chan.streamtype == 0 {
		return &((^Proc)(rawptr(&chan.stream))).out_s
	} else if chan.streamtype == KCHSTREAM_SOCKET_O {
		return (^RStream)(rawptr(&chan.stream))
	} else if chan.streamtype == KCHSTREAM_STDIO_O {
		return (^RStream)(rawptr(&chan.stream))
	}
	libc.abort()
}

// xfree with the plain-convention finalizer type for WBuffer.
xfree_finalizer_o :: proc(data: rawptr) {
	context = runtime.default_context()
	xfree(data)
}

callback_reader_set_o :: proc "c" (reader: ^CallbackReader_E) -> bool {
	context = runtime.default_context()
	return reader.cb.type != 0 || reader.self != nil
}

// Teardown the module.
@(export)
channel_teardown :: proc "c" () {
	context = runtime.default_context()
	i: u32 = 0
	for i < channels_g.set.h.n_keys {
		chan := (^Channel_O)(channels_g.values[uintptr(i)])
		channel_close(chan.id, KCHPART_ALL_O, nil)
		i += 1
	}
}

// Initializes the module.
@(export)
channel_init :: proc "c" () {
	context = runtime.default_context()
	channel_alloc(KCHSTREAM_STDERR_O)
	rpc_init_e()
}

// Channel is allocated with refcount 1 (decreased when stream closes).
@(export)
channel_alloc :: proc "c" (type: C.int) -> rawptr {
	context = runtime.default_context()
	chan := (^Channel_O)(xcalloc(1, size_of(Channel_O)))
	if type == KCHSTREAM_STDIO_O {
		chan.id = CHAN_STDIO_O
	} else if type == KCHSTREAM_STDERR_O {
		chan.id = CHAN_STDERR_O
	} else {
		chan.id = next_chan_id_g
		next_chan_id_g += 1
	}
	chan.events = multiqueue_new_child(main_loop.events)
	chan.refcount = 1
	chan.exit_status = -1
	chan.streamtype = type
	chan.detach = false
	if chan.id > u64(VARNUMBER_MAX_O) {
		libc.abort()
	}
	map_put_ref_uint64_t_ptr_t(&channels_g, chan.id, nil, nil)^ = rawptr(chan)
	return chan
}

@(export)
channel_create_event :: proc "c" (chan_raw: rawptr, ext_source: cstring) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	channel_event(chan, EVENT_CHANOPEN_O)
	_ = ext_source
}

@(export)
channel_incref :: proc "c" (chan_raw: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	chan.refcount += 1
}

@(export)
channel_decref :: proc "c" (chan_raw: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	if chan.refcount == 1 && !chan.did_close_event {
		chan.did_close_event = true
		channel_event(chan, EVENT_CHANCLOSE_O)
	}
	chan.refcount -= 1
	if chan.refcount == 0 {
		multiqueue_put_event(main_loop.events, event_create(free_channel_event_o, chan_raw))
	}
}

@(export)
callback_reader_free :: proc "c" (reader: ^CallbackReader_E) {
	context = runtime.default_context()
	callback_free(&reader.cb)
	ga_clear(transmute(^Garray)(uintptr(reader) + 24))
}

@(export)
callback_reader_start :: proc "c" (reader: ^CallbackReader_E, type: cstring) {
	context = runtime.default_context()
	ga_init(transmute(^Garray)(uintptr(reader) + 24), 1, 32)
	reader.type = type
}

channel_destroy_o :: proc "c" (chan: ^Channel_O) {
	context = runtime.default_context()
	if chan.is_rpc {
		rpc_free_e(chan)
	}
	if chan.streamtype == 0 {
		proc_free((^Proc)(rawptr(&chan.stream)))
	}
	callback_reader_free((^CallbackReader_E)(rawptr(uintptr(chan) + 1856)))
	callback_reader_free((^CallbackReader_E)(rawptr(uintptr(chan) + 1920)))
	callback_free(&chan.on_exit)
	multiqueue_free(chan.events)
	xfree(chan)
}

free_channel_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(([^]rawptr)(argv)[0])
	if chan.refcount > 0 {
		return
	}
	map_del_uint64_t_ptr_t(&channels_g, chan.id, nil)
	channel_destroy_o(chan)
}

channel_destroy_early_o :: proc "c" (chan: ^Channel_O) {
	context = runtime.default_context()
	next_chan_id_g -= 1
	if chan.id != next_chan_id_g {
		libc.abort()
	}
	map_del_uint64_t_ptr_t(&channels_g, chan.id, nil)
	chan.id = 0
	chan.refcount -= 1
	if chan.refcount != 0 {
		libc.abort()
	}
	multiqueue_put_event(main_loop.events, event_create(free_channel_event_o, rawptr(chan)))
}

close_cb_o :: proc "c" (stream: ^Stream, data: rawptr) {
	context = runtime.default_context()
	channel_decref(data)
	_ = stream
}

// channel.h inlines needing arena allocation.
foreign _ {
	@(link_name = "arena_string")
	arena_string_e :: proc "c" (arena: rawptr, str: Api_String) -> Api_String ---
}

// Allocate terminal for channel (buf is a new, unmodified buffer).
@(export)
channel_terminal_alloc :: proc "c" (buf: rawptr, chan_raw: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	pty := (^PtyProc)(rawptr(&chan.stream))
	topts := TerminalOptions_O{}
	topts.data = chan_raw
	topts.width = pty.width
	topts.height = pty.height
	topts.read_pause = term_read_pause_o
	topts.write = term_write_o
	topts.resize = term_resize_o
	topts.resume = term_resume_o
	topts.close = term_close_o
	topts.force_crlf = false
	(^u64)(uintptr(buf) + uintptr(B_P_CHANNEL_OFF))^ = chan.id
	channel_incref(chan_raw)
	chan.term = terminal_alloc_e(buf, topts)
}

term_read_pause_o :: proc "c" (pause: bool, data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	pr := (^Proc)(rawptr(&chan.stream))
	if pr.out_s.s.closed {
		return
	}
	if pause {
		rstream_stop_inner(&pr.out_s)
	} else {
		rstream_start_inner(&pr.out_s)
	}
}

term_write_o :: proc "c" (buf: ^u8, size: C.size_t, data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	pr := (^Proc)(rawptr(&chan.stream))
	if pr.in_s.closed {
		return
	}
	wbuf := wstream_new_buffer(transmute(^u8)(xmemdup(rawptr(buf), C.size_t(size))), size, 1, xfree_finalizer_o)
	wstream_write(&pr.in_s, wbuf)
}

term_resize_o :: proc "c" (width: u16, height: u16, data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	pty_proc_resize((^PtyProc)(rawptr(&chan.stream)), width, height)
}

term_resume_o :: proc "c" (data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	pty_proc_resume((^PtyProc)(rawptr(&chan.stream)))
}

term_delayed_free_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(([^]rawptr)(argv)[0])
	pr := (^Proc)(rawptr(&chan.stream))
	if pr.in_s.pending_reqs != 0 || pr.out_s.s.pending_reqs != 0 {
		multiqueue_put_event(chan.events, event_create(term_delayed_free_o, rawptr(chan)))
		return
	}
	if chan.term != nil {
		terminal_destroy_e(rawptr(&chan.term))
	}
	channel_decref(rawptr(chan))
}

term_close_o :: proc "c" (data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	proc_stop((^Proc)(rawptr(&chan.stream)))
	multiqueue_put_event(chan.events, event_create(term_delayed_free_o, data))
}

@(export)
channel_event :: proc "c" (chan_raw: rawptr, event: C.int) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	if has_event(event) {
		channel_incref(chan_raw)
		multiqueue_put_event(main_loop.events, event_create(set_info_event_o, rawptr(chan), rawptr(uintptr(event))))
	}
}

set_info_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	av := ([^]rawptr)(argv)
	chan := (^Channel_O)(av[0])
	event := C.int(uintptr(av[1]))
	sve: Save_V_Event_T
	dict := get_v_event(rawptr(&sve))
	arena := Arena_O{}
	info := channel_info(chan.id, rawptr(&arena))
	retval := Typval_T{}
	object_to_vim_e(DICT_OBJ(info), &retval, nil)
	if retval.v_type != VAR_DICT {
		libc.abort()
	}
	tv_dict_add_dict(dict, cstring("info"), 4, retval.vval)
	tv_dict_set_keys_readonly(dict)
	apply_autocmds(event, nil, nil, true, curbuf)
	restore_v_event(dict, rawptr(&sve))
	arena_mem_free(arena_finish(rawptr(&arena)))
	channel_decref(rawptr(chan))
}

// False immediately after stopping a job (unlike terminal_running).
@(export)
channel_job_running :: proc "c" (id: u64) -> bool {
	context = runtime.default_context()
	chan := (^Channel_O)(find_channel_o(id))
	return chan != nil && chan.streamtype == 0 && !proc_is_stopped_o(rawptr(&chan.stream))
}

@(export)
channel_info :: proc "c" (id: u64, arena: rawptr) -> Api_Dict {
	context = runtime.default_context()
	chan := (^Channel_O)(find_channel_o(id))
	if chan == nil {
		return Api_Dict{}
	}
	info := arena_dict_c(arena, 9)
	dict_put_obj_o(&info, cstring("id"), INT_OBJ(i64(chan.id)))
	stream_desc := cstring("socket")
	if chan.streamtype == 0 {
		stream_desc = cstring("job")
		pr := (^Proc)(rawptr(&chan.stream))
		if pr.kind == ProcType.Pty {
			dict_put_obj_o(&info, cstring("pty"), string_obj_o(arena_string_e(arena, cstr_as_string_o(pty_proc_tty_name((^PtyProc)(rawptr(&chan.stream)))))))
		}
		n: C.size_t = 0
		for (transmute(^^u8)(pr.argv) != nil) && (([^]^u8)(pr.argv))[uintptr(n)] != nil {
			n += 1
		}
		argv := arena_array_e(arena, n)
		i: C.size_t = 0
		for i < n {
			arr_add_obj_o(&argv, CSTR_AS_OBJ(([^]^u8)(pr.argv)[uintptr(i)]))
			i += 1
		}
		dict_put_obj_o(&info, cstring("argv"), array_obj_o(argv))
	} else if chan.streamtype == KCHSTREAM_STDIO_O {
		stream_desc = cstring("stdio")
	} else if chan.streamtype == KCHSTREAM_STDERR_O {
		stream_desc = cstring("stderr")
	} else if chan.streamtype == KCHSTREAM_INTERNAL_O {
		dict_put_obj_o(&info, cstring("internal"), BOOL_OBJ(1))
		stream_desc = cstring("socket")
	}
	dict_put_obj_o(&info, cstring("stream"), CSTR_AS_OBJ(transmute(^u8)(stream_desc)))
	if chan.is_rpc {
		dict_put_obj_o(&info, cstring("mode"), CSTR_AS_OBJ(transmute(^u8)(cstring("rpc"))))
		dict_put_obj_o(&info, cstring("client"), DICT_OBJ(chan.rpc.info))
	} else if chan.term != nil {
		dict_put_obj_o(&info, cstring("mode"), CSTR_AS_OBJ(transmute(^u8)(cstring("terminal"))))
		dict_put_obj_o(&info, cstring("buf"), handle_obj_o(8, i64(terminal_buf_e(chan.term))))
		dict_put_obj_o(&info, cstring("buffer"), handle_obj_o(8, i64(terminal_buf_e(chan.term))))
		dict_put_obj_o(&info, cstring("exitcode"), INT_OBJ(i64(chan.exit_status)))
	} else {
		dict_put_obj_o(&info, cstring("mode"), CSTR_AS_OBJ(transmute(^u8)(cstring("bytes"))))
	}
	return info
}

int64_cmp_o :: proc "c" (pa: rawptr, pb: rawptr) -> C.int {
	context = runtime.default_context()
	a := (^i64)(pa)^
	b := (^i64)(pb)^
	if a == b {
		return 0
	}
	if a > b {
		return 1
	}
	return -1
}

@(export)
channel_all_info :: proc "c" (arena: rawptr) -> Api_Array {
	context = runtime.default_context()
	n := channels_g.set.h.n_keys
	items := ([^]i64)(arena_alloc(arena, C.size_t(n) * 8, true))
	i: u32 = 0
	for i < n {
		items[uintptr(i)] = i64(channels_g.set.keys[uintptr(i)])
		i += 1
	}
	qsort_e(rawptr(items), C.size_t(n), 8, int64_cmp_o)
	ret := arena_array_e(arena, C.size_t(n))
	j: C.size_t = 0
	for j < C.size_t(n) {
		arr_add_obj_o(&ret, DICT_OBJ(channel_info(u64(items[uintptr(j)]), arena)))
		j += 1
	}
	return ret
}

@(export)
channel_job_start :: proc "c" (argv: rawptr, exepath: cstring, on_stdout: CallbackReader_E, on_stderr: CallbackReader_E, on_exit: Callback_E, pty: bool, rpc: bool, overlapped: bool, detach: bool, stdin_mode: C.int, cwd: cstring, pty_width: C.uint16_t, pty_height: C.uint16_t, env: rawptr, status_out: rawptr) -> rawptr {
	context = runtime.default_context()
	chan := (^Channel_O)(channel_alloc(KCHSTREAM_PROC_O))
	chan.on_data = on_stdout
	chan.on_stderr = on_stderr
	chan.on_exit = on_exit
	if pty {
		if detach {
			semsg(e_invarg2, cstring("terminal/pty job cannot be detached"))
			shell_free_argv(transmute(^^u8)(argv))
			if env != nil {
				tv_dict_free(env)
			}
			channel_destroy_early_o(chan)
			(^C.longlong)(status_out)^ = 0
			return nil
		}
		pv := pty_proc_init(&main_loop, rawptr(chan))
		libc.memcpy(rawptr(&chan.stream), rawptr(&pv), 1472)
		if pty_width > 0 {
			((^PtyProc)(rawptr(&chan.stream))).width = u16(pty_width)
		}
		if pty_height > 0 {
			((^PtyProc)(rawptr(&chan.stream))).height = u16(pty_height)
		}
	} else {
		chan.stream = libuv_proc_init(&main_loop, rawptr(chan))
	}
	pr := (^Proc)(rawptr(&chan.stream))
	pr.argv = transmute(^^u8)(argv)
	pr.exepath = transmute(^u8)(exepath)
	pr.cb = channel_proc_exit_cb_o
	pr.state_cb = channel_proc_state_cb_o
	pr.events = chan.events
	pr.detach = detach
	pr.cwd = transmute(^u8)(cwd)
	pr.env = env
	pr.overlapped = overlapped
	ex := pr.exepath
	if ex == nil {
		ex = pr.argv^
	}
	cmd := xstrdup(ex)
	has_out := false
	has_err := false
	if pr.kind == ProcType.Pty {
		has_out = true
		has_err = false
	} else {
		has_out = rpc || callback_reader_set_o(&chan.on_data)
		has_err = callback_reader_set_o(&chan.on_stderr)
		pr.fwd_err = chan.on_stderr.fwd_err
	}
	has_in := stdin_mode == KCHSTDIN_PIPE_O
	status := proc_spawn(pr, has_in, has_out, has_err)
	if status != 0 {
		semsg(cstring(E_JOBSPAWN_S), os_strerror(status), transmute(cstring)(cmd))
		xfree(rawptr(cmd))
		if pr.env != nil {
			tv_dict_free(pr.env)
		}
		channel_destroy_early_o(chan)
		(^C.longlong)(status_out)^ = C.longlong(pr.status)
		return nil
	}
	xfree(rawptr(cmd))
	if pr.env != nil {
		tv_dict_free(pr.env)
	}
	if has_in {
		wstream_init(&pr.in_s, 0)
	}
	if has_out {
		rstream_init(&pr.out_s)
	}
	if rpc {
		rpc_start_e(rawptr(chan))
	} else {
		if has_out {
			callback_reader_start(&chan.on_data, cstring("stdout"))
			rstream_start(&pr.out_s, on_channel_data, rawptr(chan))
		}
	}
	if has_err {
		callback_reader_start(&chan.on_stderr, cstring("stderr"))
		rstream_init(&pr.err_s)
		rstream_start(&pr.err_s, on_job_stderr, rawptr(chan))
	}
	(^C.longlong)(status_out)^ = C.longlong(chan.id)
	return rawptr(chan)
}

@(export)
channel_connect :: proc "c" (tcp: bool, address: cstring, rpc: bool, on_output: CallbackReader_E, timeout: C.int, error: ^cstring) -> u64 {
	context = runtime.default_context()
	channel: ^Channel_O
	if !tcp && rpc {
		if server_owns_pipe_address_e(address) {
			channel = (^Channel_O)(channel_alloc(KCHSTREAM_INTERNAL_O))
			((^InternalState_O)(rawptr(&channel.stream))).cb = LUA_NOREF_O
			rpc_start_e(rawptr(channel))
			channel_create_event(rawptr(channel), address)
			return channel.id
		}
	}
	channel = (^Channel_O)(channel_alloc(KCHSTREAM_SOCKET_O))
	if !socket_connect(&main_loop, (^RStream)(rawptr(&channel.stream)), tcp, address, timeout, error) {
		channel_decref(rawptr(channel))
		return 0
	}
	rs := (^RStream)(rawptr(&channel.stream))
	rs.s.internal_close_cb = close_cb_o
	rs.s.internal_data = rawptr(channel)
	wstream_init(&rs.s, 0)
	rstream_init(rs)
	if rpc {
		rpc_start_e(rawptr(channel))
	} else {
		channel.on_data = on_output
		callback_reader_start(&channel.on_data, cstring("data"))
		rstream_start(rs, on_channel_data, rawptr(channel))
	}
	channel_create_event(rawptr(channel), address)
	return channel.id
}

// Creates an RPC channel from a tcp/pipe socket connection.
@(export)
channel_from_connection :: proc "c" (watcher_raw: rawptr) {
	context = runtime.default_context()
	channel := (^Channel_O)(channel_alloc(KCHSTREAM_SOCKET_O))
	socket_watcher_accept((^SocketWatcher)(watcher_raw), (^RStream)(rawptr(&channel.stream)))
	rs := (^RStream)(rawptr(&channel.stream))
	rs.s.internal_close_cb = close_cb_o
	rs.s.internal_data = rawptr(channel)
	wstream_init(&rs.s, 0)
	rstream_init(rs)
	rpc_start_e(rawptr(channel))
	channel_create_event(rawptr(channel), transmute(cstring)(&((^SocketWatcher)(watcher_raw)).addr[0]))
}

// Creates an API channel from stdin/stdout (embedding).
@(export)
channel_from_stdio :: proc "c" (rpc: bool, on_output: CallbackReader_E, error: ^cstring) -> u64 {
	context = runtime.default_context()
	if !headless_mode && !embedded_mode {
		error^ = cstring("can only be opened in headless mode")
		return 0
	}
	if did_stdio_g {
		error^ = cstring("channel was already open")
		return 0
	}
	did_stdio_g = true
	channel := (^Channel_O)(channel_alloc(KCHSTREAM_STDIO_O))
	stdin_dup_fd: C.int = 0
	stdout_dup_fd: C.int = 1
	if embedded_mode {
		stdin_dup_fd = posix.fcntl(0, posix.FCNTL_Cmd.DUPFD_CLOEXEC, posix.STDERR_FILENO + 1)
		stdout_dup_fd = posix.fcntl(1, posix.FCNTL_Cmd.DUPFD_CLOEXEC, posix.STDERR_FILENO + 1)
		posix.dup2(posix.STDERR_FILENO, posix.STDOUT_FILENO)
		posix.dup2(posix.STDERR_FILENO, posix.STDIN_FILENO)
	}
	rs := (^RStream)(rawptr(&channel.stream))
	os := (^Stream)(rawptr(uintptr(&channel.stream) + 464))
	rstream_init_fd(&main_loop, rs, stdin_dup_fd)
	wstream_init_fd(&main_loop, os, stdout_dup_fd, 0)
	if rpc {
		rpc_start_e(rawptr(channel))
	} else {
		channel.on_data = on_output
		callback_reader_start(&channel.on_data, cstring("stdin"))
		rstream_start(rs, on_channel_data, rawptr(channel))
	}
	return channel.id
}

// data is consumed.
@(export)
channel_send :: proc "c" (id: u64, data: ^u8, len: C.size_t, data_owned: bool, error: ^cstring) -> C.size_t {
	context = runtime.default_context()
	chan := (^Channel_O)(find_channel_o(id))
	written: C.size_t = 0
	if chan == nil {
		error^ = cstring(E_INVCHAN_S)
		if data_owned {
			xfree(rawptr(data))
		}
		return written
	}
	if chan.streamtype == KCHSTREAM_STDERR_O {
		st := (^StderrState_O)(rawptr(&chan.stream))
		if st.closed {
			error^ = cstring("Can't send data to closed stream")
			if data_owned {
				xfree(rawptr(data))
			}
			return written
		}
		wres := os_write(2, ([^]u8)(data), len, false)
		if wres >= 0 {
			written = C.size_t(wres)
		}
		if data_owned {
			xfree(rawptr(data))
		}
		return written
	}
	if chan.streamtype == KCHSTREAM_INTERNAL_O {
		if chan.is_rpc {
			error^ = cstring("Can't send raw data to rpc channel")
			if data_owned {
				xfree(rawptr(data))
			}
			return written
		}
		ist := (^InternalState_O)(rawptr(&chan.stream))
		if chan.term == nil || ist.closed {
			error^ = cstring("Can't send data to closed stream")
			if data_owned {
				xfree(rawptr(data))
			}
			return written
		}
		terminal_receive_e(chan.term, data, len)
		written = len
		if data_owned {
			xfree(rawptr(data))
		}
		return written
	}
	instrm := channel_instream_o(chan)
	if instrm.closed {
		error^ = cstring("Can't send data to closed stream")
		if data_owned {
			xfree(rawptr(data))
		}
		return written
	}
	if chan.is_rpc {
		error^ = cstring("Can't send raw data to rpc channel")
		if data_owned {
			xfree(rawptr(data))
		}
		return written
	}
	d := rawptr(data)
	if !data_owned {
		d = xmemdup(rawptr(data), C.size_t(len))
	}
	buf := wstream_new_buffer(transmute(^u8)(d), len, 1, xfree_finalizer_o)
	if wstream_write(instrm, buf) == 0 {
		return len
	}
	return 0
}

// Binary buffer to readfile()-style list.
buffer_to_tv_list_o :: proc "c" (buf: ^u8, len: C.size_t) -> rawptr {
	context = runtime.default_context()
	l := tv_list_alloc(-1)
	tv_list_append_string(l, transmute(^u8)(cstring("")), 0)
	if len > 0 {
		encode_list_write(l, transmute(cstring)(buf), len)
	}
	return l
}

@(export)
on_channel_data :: proc "c" (stream: ^RStream, buf: ^u8, count: C.size_t, data: rawptr, eof: bool) -> C.size_t {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	return on_channel_output_o(stream, chan, buf, count, eof, &chan.on_data)
}

@(export)
on_job_stderr :: proc "c" (stream: ^RStream, buf: ^u8, count: C.size_t, data: rawptr, eof: bool) -> C.size_t {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	return on_channel_output_o(stream, chan, buf, count, eof, &chan.on_stderr)
}

on_channel_output_o :: proc "c" (stream: ^RStream, chan: ^Channel_O, buf: ^u8, count: C.size_t, eof: bool, reader: ^CallbackReader_E) -> C.size_t {
	context = runtime.default_context()
	if chan.term != nil {
		terminal_receive_e(chan.term, buf, count)
	}
	if eof {
		reader.eof = true
	}
	if callback_reader_set_o(reader) {
		ga_concat_len(transmute(^Garray)(uintptr(reader) + 24), transmute(cstring)(buf), count)
		schedule_channel_event_o(chan)
	}
	return count
}

// Schedule callbacks as a deferred event.
schedule_channel_event_o :: proc "c" (chan: ^Channel_O) {
	context = runtime.default_context()
	if !chan.callback_scheduled {
		if !chan.callback_busy {
			multiqueue_put_event(chan.events, event_create(on_channel_event_o, rawptr(chan)))
			channel_incref(rawptr(chan))
		}
		chan.callback_scheduled = true
	}
}

on_channel_event_o :: proc "c" (argv: ^rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(([^]rawptr)(argv)[0])
	chan.callback_busy = true
	chan.callback_scheduled = false
	exit_status := chan.exit_status
	channel_reader_callbacks(rawptr(chan), &chan.on_data)
	channel_reader_callbacks(rawptr(chan), &chan.on_stderr)
	if exit_status > -1 {
		channel_callback_call_o(chan, nil)
		chan.exit_status = -1
	}
	chan.callback_busy = false
	if chan.callback_scheduled {
		multiqueue_put_event(chan.events, event_create(on_channel_event_o, rawptr(chan)))
		channel_incref(rawptr(chan))
	}
	channel_decref(rawptr(chan))
}

@(export)
channel_reader_callbacks :: proc "c" (chan_raw: rawptr, reader: ^CallbackReader_E) {
	context = runtime.default_context()
	chan := (^Channel_O)(chan_raw)
	if reader.buffered {
		if reader.eof {
			if reader.self != nil {
				if tv_dict_find(reader.self, reader.type, -1) == nil {
					data := buffer_to_tv_list_o(transmute(^u8)((^Garray)(rawptr(uintptr(reader) + 24)).ga_data), C.size_t((^Garray)(rawptr(uintptr(reader) + 24)).ga_len))
					tv_dict_add_list(reader.self, reader.type, C.size_t(libc.strlen(reader.type)), data)
				} else {
					semsg(cstring(E_STREAMKEY_S), reader.type, C.ulonglong(chan.id))
				}
			} else {
				channel_callback_call_o(chan, reader)
			}
			reader.eof = false
		}
	} else {
		is_eof := reader.eof
		if (^Garray)(rawptr(uintptr(reader) + 24)).ga_len > 0 {
			channel_callback_call_o(chan, reader)
		}
		if is_eof {
			channel_callback_call_o(chan, reader)
			reader.eof = false
		}
	}
}

channel_proc_exit_cb_o :: proc "c" (pr: ^Proc, status: C.int, data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	if chan.term != nil {
		terminal_close_r(rawptr(&chan.term), C.int(status))
	}
	if !exiting && ui_client_channel_id == chan.id {
		ui_client_attach_to_restarted_server(pr.status != 0)
		if ui_client_channel_id == chan.id {
			exit_on_closed_chan(status)
		}
	}
	exited := status >= 0
	if exited && chan.on_exit.type != 0 {
		schedule_channel_event_o(chan)
	}
	if exited {
		chan.exit_status = status
	}
	channel_decref(rawptr(chan))
}

channel_proc_state_cb_o :: proc "c" (pr: ^Proc, suspended: bool, data: rawptr) {
	context = runtime.default_context()
	chan := (^Channel_O)(data)
	if chan.term != nil {
		terminal_set_state_e(chan.term, suspended)
	}
	_ = pr
}

channel_callback_call_o :: proc "c" (chan: ^Channel_O, reader: ^CallbackReader_E) {
	context = runtime.default_context()
	argv: [4]Typval_T
	argv[0] = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(chan.id))}
	cb: ^Callback_E
	if reader != nil {
		l := buffer_to_tv_list_o(transmute(^u8)((^Garray)(rawptr(uintptr(reader) + 24)).ga_data), C.size_t((^Garray)(rawptr(uintptr(reader) + 24)).ga_len))
		tv_list_ref_o(l)
		argv[1] = Typval_T{v_type = VAR_LIST, v_lock = VAR_UNLOCKED, vval = l}
		ga_clear(transmute(^Garray)(uintptr(reader) + 24))
		cb = &reader.cb
		argv[2] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(reader.type)}
	} else {
		argv[1] = Typval_T{v_type = VAR_NUMBER, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(C.longlong(chan.exit_status))}
		cb = &chan.on_exit
		argv[2] = Typval_T{v_type = VAR_STRING, v_lock = VAR_UNLOCKED, vval = transmute(rawptr)(cstring("exit"))}
	}
	rettv := Typval_T{}
	callback_call(rawptr(cb), 3, &argv[0], &rettv)
	tv_clear(&rettv)
	if reader != nil {
		tv_list_unref(argv[1].vval)
	}
}

// Closes a channel. Returns true if successful.
@(export)
channel_close :: proc "c" (id: u64, part: C.int, error: ^cstring) -> bool {
	context = runtime.default_context()
	err_local: cstring = nil
	err := &err_local
	if error != nil {
		err = error
	}
	chan := (^Channel_O)(find_channel_o(id))
	if chan == nil {
		if id < next_chan_id_g {
			return true
		}
		err^ = cstring(E_INVCHAN_S)
		return false
	}
	close_main := false
	if part == KCHPART_RPC_O || part == KCHPART_ALL_O {
		close_main = true
		if chan.is_rpc {
			rpc_close_e(rawptr(chan))
		} else if part == KCHPART_RPC_O {
			err^ = cstring(E_INVSTREAM_S)
			return false
		}
	} else if (part == KCHPART_STDIN_O || part == KCHPART_STDOUT_O) && chan.is_rpc {
		err^ = cstring(E_INVSTREAMRPC_S)
		return false
	}
	if chan.streamtype == KCHSTREAM_SOCKET_O {
		if !close_main {
			err^ = cstring(E_INVSTREAM_S)
			return false
		}
		rstream_may_close((^RStream)(rawptr(&chan.stream)))
	} else if chan.streamtype == 0 {
		pr := (^Proc)(rawptr(&chan.stream))
		if part == KCHPART_STDIN_O || close_main {
			stream_may_close(&pr.in_s)
		}
		if part == KCHPART_STDOUT_O || close_main {
			rstream_may_close(&pr.out_s)
		}
		if part == KCHPART_STDERR_O || part == KCHPART_ALL_O {
			rstream_may_close(&pr.err_s)
		}
		if pr.kind == ProcType.Pty && part == KCHPART_ALL_O {
			pty_proc_close_master((^PtyProc)(rawptr(&chan.stream)))
		}
	} else if chan.streamtype == KCHSTREAM_STDIO_O {
		rs := (^RStream)(rawptr(&chan.stream))
		os := (^Stream)(rawptr(uintptr(&chan.stream) + 464))
		if part == KCHPART_STDIN_O || close_main {
			rstream_may_close(rs)
		}
		if part == KCHPART_STDOUT_O || close_main {
			stream_may_close(os)
		}
		if part == KCHPART_STDERR_O {
			err^ = cstring(E_INVSTREAM_S)
			return false
		}
	} else if chan.streamtype == KCHSTREAM_STDERR_O {
		if part != KCHPART_ALL_O && part != KCHPART_STDERR_O {
			err^ = cstring(E_INVSTREAM_S)
			return false
		}
		st := (^StderrState_O)(rawptr(&chan.stream))
		if !st.closed {
			st.closed = true
			if !exiting {
				libc.freopen(cstring("/dev/null"), cstring("w"), libc.stderr)
			}
			channel_decref(rawptr(chan))
		}
	} else if chan.streamtype == KCHSTREAM_INTERNAL_O {
		if !close_main {
			err^ = cstring(E_INVSTREAM_S)
			return false
		}
		if chan.term != nil {
			ist := (^InternalState_O)(rawptr(&chan.stream))
			api_free_luaref_e(ist.cb)
			ist.cb = -2
			ist.closed = true
			terminal_close_r(rawptr(&chan.term), 0)
			chan.exit_status = 0
		} else {
			channel_decref(rawptr(chan))
		}
	}
	return true
}
