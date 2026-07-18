package main

import "core:c"
import "core:c/libc"
import "base:runtime"

// Constants mirroring C macros (globals.h / ascii_defs.h).
IOSIZE :: 1025 // file I/O and sprintf buffer size (globals.h:21)
PATHSEP :: u8('/') // ascii_defs.h:78
NUL :: u8(0) // ascii_defs.h:18

// ── C globals / helpers accessed by Odin (stdpaths port) ──

// C's NameBuff[MAXPATHL] — get_appname() writes here and returns it (C callers read it after).
// NOTE: _xstrlcpy, _xstrlcat, _xmemcpyz, _xmemdupz, _xstrdup, _path_is_absolute, _after_pathsep
// are already declared (foreign) in os_users.odin / os_env_b.odin / dl.odin — reused from there.
foreign _ {
	@(link_name = "NameBuff")
	name_buff: [4096]u8

	@(link_name = "memchrsub")
	_memchrsub :: proc(data: rawptr, ch: c.int, x: c.int, len: c.size_t) ---
	@(link_name = "vim_gettempdir")
	_vim_gettempdir :: proc() -> cstring ---
	@(link_name = "path_to_slash")
	_path_to_slash :: proc(p: cstring) -> cstring ---
	@(link_name = "memcnt")
	_memcnt :: proc(data: rawptr, ch: c.int, len: c.size_t) -> c.size_t ---
	@(link_name = "path_fnamecmp")
	_path_fnamecmp :: proc(fname1: cstring, fname2: cstring) -> c.int ---
	@(link_name = "strequal")
	_strequal :: proc(a: cstring, b: cstring) -> bool ---
}

// XDG variable type — exact values, C callers pass these ints.
XDGVarType :: enum c.int {
	kXDGNone = -1,
	kXDGConfigHome,
	kXDGDataHome,
	kXDGCacheHome,
	kXDGStateHome,
	kXDGRuntimeDir,
	kXDGConfigDirs,
	kXDGDataDirs,
}

// Names of the environment variables, mapped to XDGVarType values.
// Indexed by XDGVarType (kXDGConfigHome=0 .. kXDGDataDirs=6).
xdg_env_vars := [7]cstring{
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_CACHE_HOME",
	"XDG_STATE_HOME",
	"XDG_RUNTIME_DIR",
	"XDG_CONFIG_DIRS",
	"XDG_DATA_DIRS",
}

// Defaults for XDGVarType values (Linux). Used when env vars contain nothing.
// Indexed by XDGVarType (kXDGConfigHome=0 .. kXDGDataDirs=6).
xdg_defaults := [7]cstring{
	"~/.config",
	"~/.local/share",
	"~/.cache",
	"~/.local/state",
	nil, // kXDGRuntimeDir — Decided by vim_gettempdir().
	"/etc/xdg/",
	"/usr/local/share/:/usr/share/",
}

// Gets the value of $NVIM_APPNAME, or "nvim" if not set.
// Writes into the C global NameBuff and returns it.
@(export)
get_appname :: proc "c" (namelike: bool) -> cstring {
	context = runtime.default_context()
	env_val := os_getenv("NVIM_APPNAME")

	// Copy the resolved appname into NameBuff (the C global this function returns; C callers
	// read NameBuff after the call). os_getenv returns a fresh, NUL-terminated allocation.
	if env_val == nil {
		_xstrlcpy(cstring(&name_buff[0]), "nvim", c.size_t(len(name_buff)))
	} else {
		_xstrlcpy(cstring(&name_buff[0]), env_val, c.size_t(len(name_buff)))
		xfree(rawptr(env_val))
	}

	if namelike {
		// Appname may be a relative path, replace slashes to make it name-like.
		_memchrsub(rawptr(&name_buff[0]), c.int('/'), c.int('-'), c.size_t(len(name_buff)))
		_memchrsub(rawptr(&name_buff[0]), c.int('\\'), c.int('-'), c.size_t(len(name_buff)))
	}

	return cstring(&name_buff[0])
}

// Ensure that APPNAME is valid. Must be a name or relative path.
// Canonical @(export) version (was stdpaths.c; the private main.odin copy was removed).
@(export)
appname_is_valid :: proc "c" () -> bool {
	context = runtime.default_context()
	appname := get_appname(false)
	if (_path_is_absolute(appname)
		// TODO(justinmk): on Windows, path_is_absolute says "/" is NOT absolute. Should it?
		|| _strequal(appname, "/")
		|| _strequal(appname, "\\")
		|| _strequal(appname, ".")
		|| _strequal(appname, "..")
		|| _str_contains(appname, "/..")
		|| _str_contains(appname, "../")) {
		return false
	}
	return true
}

// Returns true if `s` contains the substring `sub`. (Replaces C's strstr != NULL check.)
_str_contains :: proc(s: cstring, sub: cstring) -> bool {
	if s == nil || sub == nil {
		return false
	}
	sp := _uptr(s)
	subp := _uptr(sub)
	sublen := libc.strlen(sub)
	if sublen == 0 {
		return true
	}
	slen := libc.strlen(s)
	for i := uintptr(0); i + uintptr(sublen) <= uintptr(slen); i += 1 {
		match := true
		for j := uintptr(0); j < uintptr(sublen); j += 1 {
			if ([^]u8)(sp + i + j) != ([^]u8)(subp + j) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// Remove duplicate directories in the given XDG directory list.
// `ret` is freed; returns an [allocated] joined string.
xdg_remove_duplicate :: proc(ret: cstring, sep: cstring) -> cstring {
	data: [dynamic]cstring
	defer delete(data)

	// Tokenize by `sep` (reimplements os_strtok=strtok_r inline; cstring is opaque so use
	// uintptr byte scanning). `ret` is mutated by the scan (matches strtok_r semantics).
	rest := _uptr(ret)
	sepp := _uptr(sep)
	first := true
	for {
		// skip leading separators
		for ([^]u8)(rest)[0] == ([^]u8)(sepp)[0] && ([^]u8)(rest)[0] != 0 {
			rest += 1
		}
		if ([^]u8)(rest)[0] == 0 {
			break
		}
		// find end of token
		tok := rest
		for ([^]u8)(rest)[0] != 0 && ([^]u8)(rest)[0] != ([^]u8)(sepp)[0] {
			rest += 1
		}
		is_sep := ([^]u8)(rest)[0] == ([^]u8)(sepp)[0]
		if is_sep {
			([^]u8)(rest)[0] = 0
			rest += 1
		}

		// Check if not already in the list.
		is_duplicate := false
		for i in 0 ..< len(data) {
			if _path_fnamecmp(data[i], cstring(rawptr(tok))) == 0 {
				is_duplicate = true
				break
			}
		}
		if !is_duplicate {
			append(&data, cstring(rawptr(tok)))
		}
		if !is_sep {
			break
		}
	}

	// Join with separators into an allocated result.
	total := c.size_t(0)
	for i in 0 ..< len(data) {
		total += libc.strlen(data[i])
		if i > 0 {
			total += libc.strlen(sep)
		}
	}
	// +1 for NUL.
	result := xmalloc(total + 1)
	rp := ([^]u8)(rawptr(result))
	pos := c.size_t(0)
	for i in 0 ..< len(data) {
		if i > 0 {
			slen := libc.strlen(sep)
			for j in 0 ..< slen {
				rp[pos] = ([^]u8)(sep)[j]
				pos += 1
			}
		}
		dl := libc.strlen(data[i])
		for j in 0 ..< dl {
			rp[pos] = ([^]u8)(data[i])[j]
			pos += 1
		}
	}
	rp[pos] = 0

	xfree(rawptr(ret))
	return cstring(result)
}

// Return XDG variable value (allocated).
@(export)
stdpaths_get_xdg_var :: proc "c" (idx: c.int) -> cstring {
	context = runtime.default_context()
	env := xdg_env_vars[idx]
	fallback := xdg_defaults[idx]

	env_val := os_getenv(env)

	if env_val == nil && os_env_exists(env, false) {
		env_val = _xstrdup("")
	}

	_path_to_slash(env_val)

	ret: cstring = nil
	if env_val != nil {
		ret = env_val
	} else if fallback != nil {
		ret = expand_env_save(fallback)
	} else if idx == c.int(XDGVarType.kXDGRuntimeDir) {
		// Special-case: stdpath('run') is defined at startup.
		ret = _vim_gettempdir()
		if ret == nil {
			ret = _xstrdup("/tmp/")
		}
		rlen := libc.strlen(ret)
		// Trim trailing slash.
		ret = _xmemdupz(rawptr(ret), rlen >= 2 ? rlen - 1 : 0)
	}

	if (idx == c.int(XDGVarType.kXDGDataDirs) || idx == c.int(XDGVarType.kXDGConfigDirs)) && ret != nil {
		ret = xdg_remove_duplicate(ret, ENV_SEPSTR)
	}

	return ret
}

// Concatenate `a` and `b` into a freshly `xmalloc`'d buffer (Odin allocator), adding a
// path separator only if `sep` is set and `a` does not already end in one. Replicates C's
// `do_concat_fnames`. Returns an Odin-heap pointer (consistent with how C frees returned
// strings via xfree). NOTE: we must NOT call C's `concat_fnames_realloc` here — that uses
// libc `realloc` while our strings come from Odin's heap allocator, which would crash.
concat_paths :: proc(a: cstring, b: cstring, sep: bool) -> cstring {
	context = runtime.default_context()
	if a == nil {
		if b == nil {
			return nil
		}
		return _xstrdup(b)
	}
	if b == nil {
		return _xstrdup(a)
	}
	a_len := libc.strlen(a)
	b_len := libc.strlen(b)
	total := a_len + (c.size_t(1) if sep else c.size_t(0)) + b_len + 1
	out := xmalloc(total)
	op := ([^]u8)(out)
	// copy a
	for i in 0 ..< a_len {
		op[i] = ([^]u8)(a)[i]
	}
	pos := a_len
	if sep && a_len > 0 && _after_pathsep(a, cstring(rawptr(_uptr(a) + uintptr(a_len)))) == 0 {
		op[pos] = PATHSEP
		pos += 1
	}
	for i in 0 ..< b_len {
		op[pos+i] = ([^]u8)(b)[i]
	}
	pos += b_len
	op[pos] = 0
	return cstring(out)
}

// Return Nvim-specific XDG directory subpath: "{xdg_directory}/$NVIM_APPNAME".
@(export)
get_xdg_home :: proc "c" (idx: c.int) -> cstring {
	context = runtime.default_context()
	dir := stdpaths_get_xdg_var(idx)
	appname := get_appname(false)
	appname_len := libc.strlen(appname)
	assert(appname_len < (IOSIZE - 6)) // sizeof("-data") == 6

	if dir != nil {
		appname_buf := xmalloc(appname_len + 1)
		for i in 0 ..< appname_len {
			([^]u8)(appname_buf)[i] = ([^]u8)(appname)[i]
		}
		([^]u8)(appname_buf)[appname_len] = 0
		result := concat_paths(dir, cstring(appname_buf), true)
		xfree(rawptr(dir))
		xfree(appname_buf)
		return result
	}
	return nil
}

// Return subpath of $XDG_CACHE_HOME.
@(export)
stdpaths_user_cache_subpath :: proc "c" (fname: cstring) -> cstring {
	context = runtime.default_context()
	return concat_paths(get_xdg_home(c.int(XDGVarType.kXDGCacheHome)), fname, true)
}

// Return subpath of $XDG_CONFIG_HOME.
@(export)
stdpaths_user_conf_subpath :: proc "c" (fname: cstring) -> cstring {
	context = runtime.default_context()
	return concat_paths(get_xdg_home(c.int(XDGVarType.kXDGConfigHome)), fname, true)
}

// Return subpath of $XDG_DATA_HOME.
@(export)
stdpaths_user_data_subpath :: proc "c" (fname: cstring) -> cstring {
	context = runtime.default_context()
	return concat_paths(get_xdg_home(c.int(XDGVarType.kXDGDataHome)), fname, true)
}

// Return subpath of $XDG_STATE_HOME, with optional trailing path separators and comma escaping.
@(export)
stdpaths_user_state_subpath :: proc "c" (fname: cstring, trailing_pathseps: c.size_t,
	escape_commas: bool) -> cstring {
	context = runtime.default_context()
	ret := concat_paths(get_xdg_home(c.int(XDGVarType.kXDGStateHome)), fname, true)
	len := libc.strlen(ret)
	numcommas := c.size_t(escape_commas ? _memcnt(rawptr(ret), c.int(','), len) : 0)
	if numcommas != 0 || trailing_pathseps != 0 {
		newlen := len + numcommas + trailing_pathseps
		newret := xmalloc(newlen + 1)
		nrp := ([^]u8)(newret)
		// copy current ret into the front
		for i in 0 ..< len {
			nrp[i] = ([^]u8)(ret)[i]
		}
		xfree(rawptr(ret))
		ret = cstring(newret)

		for i in 0 ..< trailing_pathseps {
			([^]u8)(ret)[len+numcommas+i] = PATHSEP
		}
		newlen -= trailing_pathseps

		for numcommas != 0 && len > 0 {
			newlen -= 1
			([^]u8)(ret)[newlen] = ([^]u8)(ret)[len-1]
			len -= 1
			if ([^]u8)(ret)[newlen] == u8(',') {
				newlen -= 1
				([^]u8)(ret)[newlen] = u8('\\')
			}
		}
		([^]u8)(ret)[newlen] = NUL
	}
	return ret
}
