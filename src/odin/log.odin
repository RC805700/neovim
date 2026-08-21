package main

import "base:runtime"
import "core:os"
import "core:path/filepath"

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
