package main

import "base:runtime"
import "core:os"
import "core:path/filepath"
import C "core:c"
import "core:c/libc"
import "core:sys/posix"

MAXPATHL :: 4096

ENV_LOGFILE :: "NVIM_LOG_FILE"
ENV_LOGFILE_WANT :: "__NVIM_LOG_FILE_WANT"
ENV_NVIM_APPNAME :: "NVIM_APPNAME"

@(export)
log_file_path: [MAXPATHL + 1]u8

@(export)
did_log_init: bool

set_log_path :: proc(s: string) {
  n := min(len(s), MAXPATHL)
  copy(log_file_path[:n], transmute([]u8)s)
  log_file_path[n] = 0
}

log_try_create :: proc(fname: string) -> bool {
  if len(fname) == 0 {
    return false
  }
  f, err := os.open(fname, {.Append, .Write, .Create})
  if err != nil {
    return false
  }
  os.close(f)
  return true
}

get_env_value :: proc(key: string) -> string {
	context = runtime.default_context()
	cv := os_getenv(cstring(raw_data(key)))
	if cv == nil {
		return ""
	}
	n: int = 0
	for ([^]u8)(cv)[n] != 0 {
		n += 1
	}
	res := make([]u8, n)
	cbytes := transmute([]u8)(([^]u8)(cv))[0:n]
	copy(res, cbytes)
	return string(res)
}

xdg_state_home_dir :: proc() -> string {
  xdg := get_env_value("XDG_STATE_HOME")
  if xdg != "" {
    return xdg
  }

  home := get_env_value("HOME")
  if home == "" {
    return ""
  }

  result, _ := filepath.join([]string{home, ".local", "state"})
  return result
}

@(export)
log_init :: proc "c" () {
  context = runtime.default_context()
  log_mutex_init()

  env_val := get_env_value(ENV_LOGFILE)
  user_set := env_val != ""

  if user_set && log_try_create(env_val) {
    set_log_path(env_val)
    os.set_env(ENV_LOGFILE, env_val)
    did_log_init = true
    return
  }

  if user_set {
    os.set_env(ENV_LOGFILE_WANT, env_val)
  }

  xdg := xdg_state_home_dir()
  if xdg != "" {
    appname := get_env_value(ENV_NVIM_APPNAME)
    if appname == "" {
      appname = "nvim"
    }

    log_dir, _ := filepath.join([]string{xdg, appname, "logs"})
    os.make_directory(log_dir)

    log_path, _ := filepath.join([]string{log_dir, "nvim.log"})
    if log_try_create(log_path) {
      set_log_path(log_path)
      os.set_env(ENV_LOGFILE, log_path)
      did_log_init = true
      return
    }
  }

  if !user_set {
    os.set_env(ENV_LOGFILE_WANT, "nvim.log")
  }

  if log_try_create("nvim.log") {
    set_log_path("nvim.log")
    os.set_env(ENV_LOGFILE, "nvim.log")
    did_log_init = true
    return
  }

  did_log_init = true
}

// —— Batch L1: log.c remainder (logmsg engine + file handling) ——

LOGLVL_DBG_O :: 1
LOGLVL_INF_O :: 2
LOGLVL_WRN_O :: 3
LOGLVL_ERR_O :: 4

ENV_NVIM_O :: "NVIM"

Nvim_Stats :: struct {
	fsync:    i64,  // @0
	redraw:   i64,  // @8
	log_skip: i16,  // @16
}
#assert(size_of(Nvim_Stats) == 24)

Uv_Timeval64 :: struct {
	tv_sec:  i64,  // @0
	tv_usec: i32,  // @4
	_pad:    i32,  // @8 (pad to 16)
}
#assert(size_of(Uv_Timeval64) == 16)

@(private = "file")
log_mutex_g: [40]u8  // uv_mutex_t, opaque
@(private = "file")
log_name_g: [32]u8

foreign _ {
	@(link_name = "g_min_log_level")
	g_min_log_level_g: C.int
	@(link_name = "g_stats")
	g_stats_g: Nvim_Stats
	@(link_name = "uv_gettimeofday")
	uv_gettimeofday_e :: proc "c" (tv: ^Uv_Timeval64) -> C.int ---
	@(link_name = "uv_print_all_handles")
	uv_print_all_handles_e :: proc "c" (loop: rawptr, file: ^libc.FILE) ---
	@(link_name = "uv_mutex_init_recursive")
	uv_mutex_init_recursive_e :: proc "c" (handle: rawptr) -> C.int ---
	@(link_name = "uv_mutex_lock")
	uv_mutex_lock_e :: proc "c" (handle: rawptr) ---
	@(link_name = "uv_mutex_unlock")
	uv_mutex_unlock_e :: proc "c" (handle: rawptr) ---
	@(link_name = "backtrace")
	backtrace_e :: proc "c" (array: ^rawptr, size: C.int) -> C.int ---
	@(link_name = "popen")
	popen_e :: proc "c" (cmd: cstring, mode: cstring) -> ^libc.FILE ---
	@(link_name = "pclose")
	pclose_e :: proc "c" (fp: ^libc.FILE) -> C.int ---
	@(link_name = "msg_schedule_semsg")
	msg_schedule_semsg_e :: proc "c" (fmt: cstring, #c_vararg args: ..any) ---
}

// Log mutex initializer (log.c public).
@(export)
log_mutex_init :: proc "c" () {
	context = runtime.default_context()
	uv_mutex_init_recursive_e(rawptr(&log_mutex_g[0]))
}

// Log mutex locker (log.c public).
@(export)
log_lock :: proc "c" () {
	context = runtime.default_context()
	uv_mutex_lock_e(rawptr(&log_mutex_g[0]))
}

// Log mutex unlocker (log.c public).
@(export)
log_unlock :: proc "c" () {
	context = runtime.default_context()
	uv_mutex_unlock_e(rawptr(&log_mutex_g[0]))
}

// Log emitter core (takes caller's va_list BY POINTER: C array params decay,
// so the shim passes the va state address; a by-value struct param would read
// 24 bytes where C pushed an 8-byte pointer — that crashed vfprintf).
@(export)
logmsg_v :: proc "c" (log_level: C.int, ctx: cstring, func_name: cstring, line_num: C.int, eol: bool, fmt: cstring, va: ^libc.va_list) -> bool {
	context = runtime.default_context()
	@(static) recursive: bool
	@(static) did_msg: bool
	if !did_log_init {
		g_stats_g.log_skip += 1
		return false
	}
	if log_level < g_min_log_level_g {
		return false
	}
	// No EXITFREE in this build: entered_free_all_mem arm absent (matches C).
	log_lock()
	ret := false
	if recursive {
		if !did_msg {
			did_msg = true
			fn := func_name
			if fn == nil {
				fn = ctx
			}
			msg_schedule_semsg_e(cstring("E5430: %s:%d: recursive log!"), fn, line_num)
		}
		g_stats_g.log_skip += 1
	} else {
		recursive = true
		log_file := open_log_file()
		ret = v_do_log_to_file_o(log_file, log_level, ctx, func_name, line_num, eol, fmt, va)
		if log_file != libc.stderr && log_file != libc.stdout {
			libc.fclose(log_file)
		}
		recursive = false
	}
	log_unlock()
	return ret
}

// libuv handle dumper (log.c public).
@(export)
log_uv_handles :: proc "c" (loop: rawptr) {
	context = runtime.default_context()
	log_lock()
	log_file := open_log_file()
	uv_print_all_handles_e(loop, log_file)
	if log_file != libc.stderr && log_file != libc.stdout {
		libc.fclose(log_file)
	}
	log_unlock()
}

// Log file opener, stderr fallback (log.c public).
@(export)
open_log_file :: proc "c" () -> ^libc.FILE {
	context = runtime.default_context()
	posix.set_errno(.NONE)
	if log_file_path[0] != 0 {
		f := libc.fopen(transmute(cstring)(&log_file_path[0]), cstring("a"))
		if f != nil {
			return f
		}
	}
	err := posix.errno()
	do_log_to_file_o(libc.stderr, LOGLVL_ERR_O, nil, cstring("open_log_file"), 167, true, cstring("failed to open $NVIM_LOG_FILE (%s): %s"), libc.strerror(C.int(err)), transmute(cstring)(&log_file_path[0]))
	return libc.stderr
}

// Non-variadic wrapper (C-static; plain proc).
do_log_to_file_o :: proc "c" (log_file: ^libc.FILE, log_level: C.int, ctx: cstring, func_name: cstring, line_num: C.int, eol: bool, fmt: cstring, #c_vararg args: ..any) -> bool {
	context = runtime.default_context()
	va: libc.va_list
	libc.va_start(&va, args)
	ret := v_do_log_to_file_o(log_file, log_level, ctx, func_name, line_num, eol, fmt, &va)
	libc.va_end(&va)
	return ret
}

// Log line writer (C-static; plain proc).
v_do_log_to_file_o :: proc "c" (log_file: ^libc.FILE, log_level: C.int, ctx: cstring, func_name: cstring, line_num: C.int, eol: bool, fmt: cstring, va: ^libc.va_list) -> bool {
	context = runtime.default_context()
	if log_level < LOGLVL_DBG_O || log_level > LOGLVL_ERR_O {
		libc.abort()
	}
	local_time: posix.tm
	if os_localtime(&local_time) == nil {
		return false
	}
	date_time: [20]u8
	if libc.strftime(transmute([^]u8)(&date_time[0]), C.size_t(len(date_time)), cstring("%Y-%m-%dT%H:%M:%S"), &local_time) == 0 {
		return false
	}
	millis: C.int = 0
	curtime: Uv_Timeval64
	if uv_gettimeofday_e(&curtime) == 0 {
		millis = C.int(curtime.tv_usec) / 1000
	}
	ui := ui_client_channel_id != 0
	if ui || log_name_g[0] == 0 || log_name_g[0] == '?' {
		parent_buf: [MAXPATHL + 1]u8
		parent := path_tail_e(os_getenv_buf(cstring(ENV_NVIM_O), transmute(cstring)(&parent_buf[0]), C.size_t(len(parent_buf))))
		serv := path_tail_e(get_vim_var_str(VV_SEND_SERVER_O))
		if parent != nil && ([^]u8)(parent)[0] != 0 {
			if ui {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("ui/c/%s"), parent)
			} else {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("c/%s"), parent)
			}
		} else if serv != nil && ([^]u8)(serv)[0] != 0 {
			if ui {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("ui/%s"), serv)
			} else {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("%s"), serv)
			}
		} else {
			pid := os_get_pid()
			if ui {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("ui.%-5lld"), C.longlong(pid))
			} else {
				libc.snprintf(transmute([^]u8)(&log_name_g[0]), C.size_t(len(log_name_g)), cstring("?.%-5lld"), C.longlong(pid))
			}
		}
	}
	levels := [4]cstring{"DBG", "INF", "WRN", "ERR"}
	name := transmute(cstring)(&log_name_g[0])
	dt := transmute(cstring)(&date_time[0])
	rv: C.int
	if line_num == -1 || func_name == nil {
		cstr := ctx
		if cstr == nil {
			cstr = cstring("?:")
		}
		rv = libc.fprintf(log_file, cstring("%s %s.%03d %-10s %s"), levels[log_level - 1], dt, millis, name, cstr)
	} else {
		cstr := ctx
		if cstr == nil {
			cstr = cstring("")
		}
		rv = libc.fprintf(log_file, cstring("%s %s.%03d %-10s %s%s:%d: "), levels[log_level - 1], dt, millis, name, cstr, func_name, line_num)
	}
	if rv < 0 {
		return false
	}
	if libc.vfprintf(log_file, fmt, va) < 0 {
		return false
	}
	if eol {
		libc.fputc(10, log_file)
	}
	if libc.fflush(log_file) == -1 {
		return false
	}
	return true
}

// Callstack dumper to file (log.c public; HAVE_EXECINFO_BACKTRACE is on).
@(export)
log_callstack_to_file :: proc "c" (log_file: ^libc.FILE, func_name: cstring, line_num: C.int) {
	context = runtime.default_context()
	trace: [100]rawptr
	trace_size := backtrace_e(&trace[0], 100)
	exepath: [MAXPATHL]u8
	exepathlen := C.size_t(MAXPATHL)
	if os_exepath(transmute(cstring)(&exepath[0]), &exepathlen) != 0 {
		libc.abort()
	}
	if 24 + exepathlen >= 1025 {
		libc.abort()
	}
	cmdbuf: [1025 + 20*100 + MAXPATHL]u8
	libc.snprintf(transmute([^]u8)(&cmdbuf[0]), C.size_t(len(cmdbuf)), cstring("addr2line -e %s -f -p"), transmute(cstring)(&exepath[0]))
	for i := 1; i < int(trace_size); i += 1 {
		buf: [20]u8
		libc.snprintf(transmute([^]u8)(&buf[0]), C.size_t(len(buf)), cstring(" %p"), trace[i])
		xstrlcat(&cmdbuf[0], &buf[0], C.size_t(len(cmdbuf)))
	}
	do_log_to_file_o(log_file, LOGLVL_DBG_O, nil, func_name, line_num, true, cstring("trace:"))
	fp := popen_e(transmute(cstring)(&cmdbuf[0]), cstring("r"))
	if fp == nil {
		libc.abort()
	}
	linebuf: [1025]u8
	for libc.fgets(transmute([^]u8)(&linebuf[0]), len(linebuf) - 1, fp) != nil {
		libc.fprintf(log_file, cstring("  %s"), transmute(cstring)(&linebuf[0]))
	}
	pclose_e(fp)
	if log_file != libc.stderr && log_file != libc.stdout {
		libc.fclose(log_file)
	}
}

// Callstack dumper (log.c public).
@(export)
log_callstack :: proc "c" (func_name: cstring, line_num: C.int) {
	context = runtime.default_context()
	log_lock()
	log_file := open_log_file()
	log_callstack_to_file(log_file, func_name, line_num)
	log_unlock()
}
