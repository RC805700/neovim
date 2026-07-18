package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

Timestamp :: u64

// C globals / procs still defined in C (os/input.c not yet ported).
@(link_name = "got_int")
got_int: bool

foreign _ {
	@(link_name = "os_input_ready")
	os_input_ready :: proc(events: rawptr) -> bool ---
}

@(private)
tz_cache: [64]u8

@(export)
os_hrtime :: proc "c" () -> u64 {
  ts: posix.timespec
  posix.clock_gettime(.MONOTONIC, &ts)
  return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}

@(export)
os_realtime :: proc "c" () -> i64 {
  return time.time_to_unix_nano(time.now())
}

@(export)
os_sleep :: proc "c" (ms: u64) {
  capped := ms
  if capped > u64(max(u32)) {
    capped = u64(max(u32))
  }
  time.sleep(time.Duration(capped) * time.Millisecond)
}

@(export)
os_localtime_r :: proc "c" (clock: ^posix.time_t, result: ^posix.tm) -> ^posix.tm {
  context = runtime.default_context()
  when ODIN_OS == .Windows {
    local_time := posix.localtime(clock)
    if local_time == nil {return nil}
    result^ = local_time^
    return result
  } else {
    tzs := os.get_env("TZ", context.allocator)
    defer delete(tzs)
    //tz := libc.getenv("TZ")
    tz := strings.clone_to_cstring(tzs)
    defer delete(tz)
    if libc.strncmp(cstring(&tz_cache[0]), tz, c.size_t(len(tz_cache) - 1)) != 0 {
      posix.tzset()
      libc.strncpy(([^]byte)(&tz_cache[0]), tz, c.size_t(len(tz_cache) - 1))
      tz_cache[len(tz_cache) - 1] = 0
    }
    return posix.localtime_r(clock, result)
  }
}

@(export)
os_localtime :: proc "c" (result: ^posix.tm) -> ^posix.tm {
  rawtime: posix.time_t
  libc.time(&rawtime)
  return os_localtime_r(&rawtime, result)
}

@(export)
os_ctime_r :: proc "c" (
  clock: ^posix.time_t,
  result: [^]u8,
  result_len: c.size_t,
  add_newline: bool,
) -> cstring {
  clock_local: posix.tm
  if os_localtime_r(clock, &clock_local) != nil {
    n := libc.strftime(result, result_len - 1, "%a %b %d %H:%M:%S %Y", &clock_local)
    if n == 0 {
      libc.strncpy(result, cstring("(Invalid)"), result_len - 1)
      result[result_len - 1] = 0
    }
  } else {
    libc.strncpy(result, cstring("(Invalid)"), result_len - 1)
    result[result_len - 1] = 0
  }
  if add_newline {
    cur_len := libc.strlen(cstring(result))
    if c.size_t(cur_len) < result_len - 1 {
      result[cur_len] = '\n'
      result[cur_len + 1] = 0
    }
  }
  return cstring(result)
}

@(export)
os_ctime :: proc "c" (result: [^]u8, result_len: c.size_t, add_newline: bool) -> cstring {
  rawtime: posix.time_t
  libc.time(&rawtime)
  return os_ctime_r(&rawtime, result, result_len, add_newline)
}

@(export)
os_strptime :: proc "c" (str, format: cstring, tm: ^posix.tm) -> cstring {
  when ODIN_OS == .Windows {
    return nil
  } else {
    return posix.strptime(transmute([^]u8)str, format, tm)
  }
}

@(export)
os_time :: proc "c" () -> Timestamp {
	return Timestamp(libc.time(nil))
}

@(export)
os_now :: proc "c" () -> u64 {
	return uv_now(&main_loop.uv)
}

@(export)
os_delay :: proc "c" (ms: u64, ignoreinput: bool) {
	m := ms
	if m > u64(max(c.int)) {
		m = u64(max(c.int))
	}
	remaining := i64(m)
	before := u64(0)
	if remaining > 0 {
		before = os_hrtime()
	}
	for {
		condition := false
		if ignoreinput {
			condition = got_int
		} else {
			condition = os_input_ready(nil)
		}
		if condition {
			break
		}
		if remaining == 0 {
			break
		}
		loop_poll_events(&main_loop, remaining)
		if remaining > 0 {
			now := os_hrtime()
			remaining -= i64((now - before) / 1_000_000)
			before = now
			if remaining <= 0 {
				break
			}
		}
	}
}
