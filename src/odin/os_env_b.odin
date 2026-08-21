package main

import "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/posix"

// ── C globals / helpers accessed by Odin (Phase B) ──

// The "real" home directory, set by startup_set_homedir.
homedir: cstring

_empty_str: [1]u8 = {0}

init :: proc() {
	default_vim_dir = cstring(&_empty_str[0])
	default_vimruntime_dir = cstring(&_empty_str[0])
	default_lib_dir = cstring(&_empty_str[0])
}

foreign _ {
	@(link_name = "environ")
	_c_environ: ^cstring

	@(link_name = "uv_os_homedir")
	_uv_os_homedir :: proc(buf: cstring, size: ^c.size_t) -> c.int ---

	// path / charset helpers
	@(link_name = "vim_isIDc")
	_vim_isIDc :: proc(c: c.int) -> bool ---
	@(link_name = "vim_ispathsep")
	_vim_ispathsep :: proc(c: c.int) -> bool ---
	@(link_name = "vim_isfilec")
	_vim_isfilec :: proc(c: c.int) -> bool ---
	@(link_name = "vim_strchr")
	_vim_strchr :: proc(s: cstring, c: c.int) -> cstring ---
	@(link_name = "vim_strsave_escaped")
	_vim_strsave_escaped :: proc(s: cstring, esc: cstring) -> cstring ---
	@(link_name = "skipwhite")
	_skipwhite :: proc(p: cstring) -> cstring ---
	@(link_name = "skip_expr")
	_skip_expr :: proc(pp: ^cstring, evalarg: rawptr) -> c.int ---
	@(link_name = "after_pathsep")
	_after_pathsep :: proc(b: cstring, p: cstring) -> c.int ---
	@(link_name = "path_tail")
	_path_tail :: proc(fname: cstring) -> cstring ---
	@(link_name = "path_tail_with_sep")
	_path_tail_with_sep :: proc(fname: cstring) -> cstring ---
	@(link_name = "concat_fnames")
	_concat_fnames :: proc(f1: NvimString, f2: NvimString, sep: bool) -> NvimString ---
	@(link_name = "append_path")
	_append_path :: proc(path: cstring, to_append: cstring, max_len: c.size_t) -> c.int ---
	@(link_name = "ExpandInit")
	_ExpandInit :: proc(xp: rawptr) ---
	@(link_name = "ExpandOne")
	_ExpandOne :: proc(xp: rawptr, str: cstring, orig: cstring, options: c.int, mode: c.int) -> cstring ---
	@(link_name = "modify_fname")
	_modify_fname :: proc(src: cstring, tilde_file: bool, usedlen: ^c.size_t, fnamep: ^cstring, buf: ^cstring, flen: ^c.size_t) -> c.int ---
	@(link_name = "path_is_absolute")
	_path_is_absolute :: proc(fname: cstring) -> bool ---
	@(link_name = "internal_error")
	_internal_error :: proc(w: cstring) ---
	@(link_name = "striequal")
	_striequal :: proc(a: cstring, b: cstring) -> bool ---
	@(link_name = "xmemrchr")
	_xmemrchr :: proc(s: cstring, ch: u8, len: c.size_t) -> cstring ---
	@(link_name = "xstrlcat")
	_xstrlcat :: proc(dst: cstring, src: cstring, dsize: c.size_t) -> c.size_t ---

	@(link_name = "get_vim_var_str")
	_get_vim_var_str :: proc(idx: c.int) -> cstring ---

	@(link_name = "xmemdupz")
	_xmemdupz :: proc(data: rawptr, len: c.size_t) -> cstring ---

	@(link_name = "strcasecmp")
	_strcasecmp :: proc(a: cstring, b: cstring) -> c.int ---
	@(link_name = "xmemcpyz")
	_xmemcpyz :: proc(dst: rawptr, src: rawptr, len: c.size_t) ---
}

@(export)
default_vim_dir: cstring
@(export)
default_vimruntime_dir: cstring
@(export)
default_lib_dir: cstring
@(export)
p_hf: cstring
@(export)
didset_vim: bool
@(export)
didset_vimruntime: bool


// ── Constants ──
RUNTIME_DIRNAME : cstring = "runtime"
ENV_SEPCHAR   : c.int = ':'
EXPAND_BUF_LEN : c.int = 256
WILD_ADD_SLASH  : c.int = 0x10
WILD_SILENT     : c.int = 0x40
WILD_EXPAND_FREE : c.int = 2
EXPAND_FILES    : c.int = 2
ENV_SEPSTR      : cstring = ":"

_uptr :: proc "c" (p: cstring) -> uintptr { return uintptr(rawptr(p)) }

// ── expand_T struct mirror ──
xp_prefix_T :: enum c.int {
	XP_PREFIX_NONE,
	XP_PREFIX_NO,
	XP_PREFIX_INV,
}

Direction :: enum c.int {
	BACKWARD = -1,
	FORWARD = 1,
	BACKWARD_FILE = -3,
	FORWARD_FILE = 3,
}

pos_T :: struct {
	lnum:  i32,
	col:   i32,
	coladd: i32,
}

sctx_T :: struct {
	sc_sid:  c.int,
	sc_seq:  c.int,
	sc_lnum: i32,
	sc_chan: u64,
}

expand_T :: struct {
	xp_pattern:       cstring,
	xp_context:       c.int,
	xp_pattern_len:   c.size_t,
	xp_prefix:        xp_prefix_T,
	xp_arg:           cstring,
	xp_luaref:        c.int,
	xp_script_ctx:    sctx_T,
	xp_backslash:     c.int,
	xp_shell:         bool,
	xp_numfiles:      c.int,
	xp_col:           c.int,
	xp_selected:      c.int,
	xp_orig:          cstring,
	xp_files:         ^cstring,
	xp_files_abbr:    ^cstring,
	xp_files_kind:    ^cstring,
	xp_files_menu:    ^cstring,
	xp_files_info:    ^cstring,
	xp_line:          cstring,
	xp_buf:           [256]i8,
	xp_search_dir:    Direction,
	xp_pre_incsearch_pos: pos_T,
}

// ── startup / homedir ──

@(export)
startup_set_homedir :: proc(path: cstring) {
	context = runtime.default_context()
	xfree(rawptr(homedir))
	if path != nil {
		homedir = _xstrdup(path)
	} else {
		homedir = nil
	}
}

@(export)
os_homedir :: proc "c" () -> cstring {
	if homedir == nil {
		return nil
	}
	return homedir
}

@(export)
free_homedir :: proc "c" () {
	xfree(rawptr(homedir))
	homedir = nil
}

@(export)
os_hint_priority :: proc "c" () {
	// No-op on Linux (macOS-specific QoS hint removed).
}

@(export)
init_homedir :: proc "c" () {
	context = runtime.default_context()
	default_vim_dir = cstring(&_empty_str[0])
	default_vimruntime_dir = cstring(&_empty_str[0])
	default_lib_dir = cstring(&_empty_str[0])
	xfree(rawptr(homedir))
	homedir = nil

	var: cstring = os_getenv("HOME")

	if var == nil {
		var = os_uv_homedir()
	}

	if var != nil && ([^]u8)(var)[0] == '%' {
		p := _vim_strchr(cstring(rawptr(uintptr(rawptr(var)) + 1)), '%')
		if p != nil {
			buf: [MAXPATHL]u8
			libc.strncpy(&buf[0], cstring(rawptr(uintptr(rawptr(var)) + 1)), c.size_t(uintptr(rawptr(p)) - uintptr(rawptr(var)) - 1))
			exp := os_getenv(cstring(&buf[0]))
			if exp != nil && ([^]u8)(exp)[0] != 0 {
				var = _vim_strsave_escaped(exp, cstring(nil))
			}
			xfree(rawptr(exp))
		}
	}

	io: [MAXPATHL]u8
	if var != nil && os_realpath(var, cstring(&io[0]), c.size_t(MAXPATHL)) != nil {
		var = cstring(&io[0])
	}

	if (var == nil || ([^]u8)(var)[0] == 0) && os_dirname(cstring(&io[0]), c.size_t(MAXPATHL)) == OK {
		var = cstring(&io[0])
	}

	if var != nil {
		homedir = _xstrdup(var)
	}
}

os_uv_homedir :: proc() -> cstring {
	homedir_buf: [MAXPATHL]u8
	homedir_buf[0] = 0
	sz := c.size_t(MAXPATHL)
	ret := _uv_os_homedir(cstring(&homedir_buf[0]), &sz)
	if ret == 0 && sz < c.size_t(MAXPATHL) {
		return cstring(&homedir_buf[0])
	}
	return nil
}

// ── expand_env family ──

@(export)
expand_env_save :: proc "c" (src: cstring) -> cstring {
	return expand_env_save_opt(src, false, nil)
}

@(export)
expand_env_save_opt :: proc "c" (src: cstring, one: bool, esc_chars: cstring) -> cstring {
	p := xmalloc(MAXPATHL)
	expand_env_esc(src, cstring(p), c.int(MAXPATHL), esc_chars, one, nil)
	return cstring(p)
}

@(export)
expand_env :: proc "c" (src: cstring, dst: cstring, dstlen: c.int) -> c.size_t {
	return expand_env_esc(src, dst, dstlen, nil, false, nil)
}

@(export)
expand_env_esc :: proc "c" (srcp: cstring, dst: cstring, dstlenp: c.int, esc_chars: cstring,
                            one: bool, prefix: cstring) -> c.size_t {
	context = runtime.default_context()
	dst_start := _uptr(dst)
	prefix_len := c.int(0)
	if prefix != nil {
		prefix_len = c.int(libc.strlen(prefix))
	}

	s := _uptr(_skipwhite(srcp))
	d := _uptr(dst)
	dl := dstlenp
	dl -= 1
	at_start := true
	for ([^]u8)(s)[0] != 0 && dl > 0 {
		if ([^]u8)(s)[0] == '`' && ([^]u8)(s)[1] == '=' {
			varp := s
			s += 2
			stmp: cstring = cstring(rawptr(s))
			_skip_expr(&stmp, nil)
			s = uintptr(rawptr(stmp))
			if ([^]u8)(s)[0] == '`' {
				s += 1
			}
			len := c.int(s - varp)
			if len > dl {
				len = dl
			}
			libc.memcpy(rawptr(d), rawptr(varp), c.size_t(len))
			d += uintptr(len)
			dl -= len
			continue
		}

		copy_char := true
		if ([^]u8)(s)[0] == '$' || (([^]u8)(s)[0] == '~' && at_start) {
			mustfree := false
			var: uintptr = 0
			tail: uintptr = 0

			if ([^]u8)(s)[0] != '~' {
				tail = s + 1
				var = d
				cl := dl - 1

				if ([^]u8)(tail)[0] == '{' && !_vim_isIDc(c.int('{')) {
					tail += 1
					for cl > 0 && ([^]u8)(tail)[0] != 0 && ([^]u8)(tail)[0] != '}' {
						([^]u8)(var)[0] = ([^]u8)(tail)[0]
						var += 1
						tail += 1
						cl -= 1
					}
				} else {
					for cl > 0 && ([^]u8)(tail)[0] != 0 && _vim_isIDc(c.int(([^]u8)(tail)[0])) {
						([^]u8)(var)[0] = ([^]u8)(tail)[0]
						var += 1
						tail += 1
						cl -= 1
					}
				}

				if ([^]u8)(s)[1] == '{' && ([^]u8)(tail)[0] != '}' {
					var = 0
				} else {
					if ([^]u8)(s)[1] == '{' {
						tail += 1
					}
					([^]u8)(var)[0] = 0
					var = uintptr(rawptr(vim_getenv(cstring(rawptr(var)))))
					mustfree = true
				}
			} else if ([^]u8)(s)[1] == 0 || _vim_ispathsep(c.int(([^]u8)(s)[1])) || _vim_strchr(", \t\n", c.int(([^]u8)(s)[1])) != nil {
				var = _uptr(homedir)
				tail = s + 1
			} else {
				tail = s
				var = d
				cl := dl - 1
				for cl > 0 && ([^]u8)(tail)[0] != 0 && _vim_isfilec(c.int(([^]u8)(tail)[0])) && !_vim_ispathsep(c.int(([^]u8)(tail)[0])) {
					([^]u8)(var)[0] = ([^]u8)(tail)[0]
					var += 1
					tail += 1
					cl -= 1
				}
				([^]u8)(var)[0] = 0
				var = ([^]u8)(d)[0] == 0 ? 0 : uintptr(rawptr(os_get_userdir(cstring(rawptr(var + 1)))))
				mustfree = true
				if var == 0 {
					xpc: expand_T
					_ExpandInit(&xpc)
					xpc.xp_context = EXPAND_FILES
					var = uintptr(rawptr(_ExpandOne(&xpc, cstring(rawptr(d)), nil, WILD_ADD_SLASH | WILD_SILENT, WILD_EXPAND_FREE)))
					mustfree = true
				}
			}

			if esc_chars != nil && var != 0 && libc.strpbrk(cstring(rawptr(var)), esc_chars) != nil {
				p := _vim_strsave_escaped(cstring(rawptr(var)), esc_chars)
				if mustfree {
					xfree(rawptr(var))
				}
				var = uintptr(rawptr(p))
				mustfree = true
			}

			if var != 0 && ([^]u8)(var)[0] != 0 {
				vl := c.int(libc.strlen(cstring(rawptr(var))))
				if c.size_t(vl) + libc.strlen(cstring(rawptr(tail))) + 1 < c.size_t(dl) {
					_xstrlcpy(cstring(rawptr(d)), cstring(rawptr(var)), c.size_t(dl))
					dl -= vl
					if _after_pathsep(cstring(rawptr(d)), cstring(rawptr(d + uintptr(vl)))) != 0 && _vim_ispathsep(c.int(([^]u8)(tail)[0])) {
						tail += 1
					}
					d += uintptr(vl)
					s = tail
					copy_char = false
				}
			}
			if mustfree {
				xfree(rawptr(var))
			}
		}

		if copy_char {
			at_start = false
			if ([^]u8)(s)[0] == '\\' && ([^]u8)(s)[1] != 0 {
				([^]u8)(d)[0] = ([^]u8)(s)[0]
				d += 1
				s += 1
				dl -= 1
			} else if (([^]u8)(s)[0] == ' ' || ([^]u8)(s)[0] == ',') && !one {
				at_start = true
			}
			if dl > 0 {
				([^]u8)(d)[0] = ([^]u8)(s)[0]
				d += 1
				s += 1
				dl -= 1

				srcp_b := _uptr(srcp)
				if prefix != nil && c.int(s - uintptr(prefix_len)) >= c.int(srcp_b) && libc.strncmp(cstring(rawptr(s - uintptr(prefix_len))), prefix, c.size_t(prefix_len)) == 0 {
					at_start = true
				}
			}
		}
	}
	([^]u8)(d)[0] = 0
	return c.size_t(d - dst_start)
}

// ── home_replace family ──

@(export)
home_replace :: proc "c" (buf: rawptr, src: cstring, dst: cstring, dstlen: c.size_t, one: bool) -> c.size_t {
	context = runtime.default_context()
	dirlen: c.size_t = 0
	envlen: c.size_t = 0

	if src == nil {
		([^]u8)(_uptr(dst))[0] = 0
		return 0
	}

	if homedir != nil {
		dirlen = libc.strlen(homedir)
	}

	homedir_env := os_getenv("HOME")
	if homedir_env == nil {
		homedir_env = os_getenv("USERPROFILE")
	}
	homedir_env_mod := homedir_env
	must_free := false

	if homedir_env_mod != nil && ([^]u8)(_uptr(homedir_env_mod))[0] == '~' {
		must_free = true
		usedlen: c.size_t = 0
		flen := libc.strlen(homedir_env_mod)
		fbuf := cstring(nil)
		_modify_fname(homedir_env_mod, false, &usedlen, &homedir_env_mod, &fbuf, &flen)
		flen = libc.strlen(homedir_env_mod)
		if _vim_ispathsep(c.int(([^]u8)(_uptr(homedir_env_mod))[flen - 1])) {
			([^]u8)(_uptr(homedir_env_mod))[flen - 1] = 0
		}
	}

	if homedir_env_mod != nil {
		envlen = libc.strlen(homedir_env_mod)
	}

	dl := dstlen
	s := _uptr(src)
	if !one {
		s = _uptr(_skipwhite(src))
	}
	dst_p := _uptr(dst)
	for ([^]u8)(s)[0] != 0 && dl > 0 {
		p := homedir
		ln := dirlen
		for true {
			if ln != 0 && _path_fnamencmp(cstring(rawptr(s)), p, c.int(ln)) == 0 && (_vim_ispathsep(c.int(([^]u8)(s)[ln])) || (!one && (([^]u8)(s)[ln] == ',' || ([^]u8)(s)[ln] == ' ')) || ([^]u8)(s)[ln] == 0) {
				s += uintptr(ln)
				if dl > 0 {
					([^]u8)(dst_p)[0] = '~'
					dst_p += 1
					dl -= 1
				}
				break
			}
			if p == homedir_env_mod {
				break
			}
			p = homedir_env_mod
			ln = envlen
		}

		if dl == 0 {
			break
		}
		for ([^]u8)(s)[0] != 0 && (one || (([^]u8)(s)[0] != ',' && ([^]u8)(s)[0] != ' ')) && dl > 0 {
			([^]u8)(dst_p)[0] = ([^]u8)(s)[0]
			dst_p += 1
			s += 1
			dl -= 1
		}
		if dl == 0 {
			break
		}
		for (([^]u8)(s)[0] == ' ' || ([^]u8)(s)[0] == ',') && dl > 0 {
			([^]u8)(dst_p)[0] = ([^]u8)(s)[0]
			dst_p += 1
			s += 1
			dl -= 1
		}
	}
	([^]u8)(dst_p)[0] = 0

	xfree(rawptr(homedir_env))
	if must_free {
		xfree(rawptr(homedir_env_mod))
	}
	return c.size_t(dst_p - _uptr(dst))
}

@(export)
home_replace_save :: proc "c" (buf: rawptr, src: cstring) -> cstring {
	context = runtime.default_context()
	len: c.size_t = 3
	if src != nil {
		len += libc.strlen(src)
	}
	dst := xmalloc(len)
	home_replace(buf, src, cstring(dst), len, true)
	return cstring(dst)
}

// ── env name expansion / misc ──

@(export)
get_env_name :: proc "c" (xp: ^expand_T, idx: c.int) -> cstring {
	context = runtime.default_context()
	envname := os_getenvname_at_index(c.size_t(idx))
	if envname != nil {
		_xstrlcpy(cstring(rawptr(&xp.xp_buf[0])), envname, c.size_t(EXPAND_BUF_LEN))
		xfree(rawptr(envname))
		return cstring(rawptr(&xp.xp_buf[0]))
	}
	return nil
}

@(export)
os_setenv_append_path :: proc "c" (fname: cstring) -> bool {
	context = runtime.default_context()
	if !_path_is_absolute(fname) {
		_internal_error("os_setenv_append_path()")
		return false
	}
	tail := _path_tail_with_sep(fname)
	dirlen := c.size_t(uintptr(rawptr(tail)) - uintptr(rawptr(fname)))
	os_buf: [MAXPATHL]u8
	_xmemcpyz(&os_buf[0], rawptr(fname), dirlen)
	path := os_getenv("PATH")
	pathlen := c.size_t(0)
	if path != nil {
		pathlen = libc.strlen(path)
	}
	newlen := pathlen + dirlen + 2
	retval := false
	if newlen < c.size_t(0x7fffffff) {
		temp := xmalloc(newlen)
		if pathlen == 0 {
			([^]u8)(temp)[0] = 0
		} else {
			_xstrlcpy(cstring(temp), path, newlen)
			if u8(ENV_SEPCHAR) != ([^]u8)(path)[pathlen - 1] {
				_xstrlcat(cstring(temp), ENV_SEPSTR, newlen)
			}
		}
		_xstrlcat(cstring(temp), cstring(rawptr(&os_buf[0])), newlen)
		os_setenv("PATH", cstring(temp), 1)
		xfree(rawptr(temp))
		retval = true
	}
	xfree(rawptr(path))
	return retval
}

@(export)
os_shell_is_cmdexe :: proc "c" (sh: cstring) -> bool {
	if ([^]u8)(sh)[0] == 0 {
		return false
	}
	if _striequal(sh, "$COMSPEC") {
		comspec := os_getenv_noalloc("COMSPEC")
		return _striequal("cmd.exe", _path_tail(comspec))
	}
	if _striequal(sh, "cmd.exe") || _striequal(sh, "cmd") {
		return true
	}
	return _striequal("cmd.exe", _path_tail(sh))
}

@(export)
os_free_fullenv :: proc "c" (env: ^cstring) {
	if env == nil {
		return
	}
	it := env
	for ([^]cstring)(it)[0] != nil {
		xfree(rawptr(([^]cstring)(it)[0]))
		it = ([^]cstring)(uintptr(rawptr(it)) + size_of(cstring))
	}
	xfree(rawptr(env))
}

@(export)
os_getenvname_at_index :: proc "c" (index: c.size_t) -> cstring {
	context = runtime.default_context()
	environ := _c_environ
	for i := c.size_t(0); i <= index; i += 1 {
		e := ([^]cstring)(uintptr(rawptr(environ)) + uintptr(i))
		if e[0] == nil {
			return nil
		}
	}
	str := ([^]cstring)(uintptr(rawptr(environ)) + uintptr(index))[0]
	end := _vim_strchr(str, '=')
	if end == nil {
		return nil
	}
	len := c.size_t(uintptr(rawptr(end)) - uintptr(rawptr(str)))
	return _xmemdupz(rawptr(str), len)
}

@(export)
vim_env_iter :: proc "c" (delim: u8, val: cstring, iter: rawptr, dir: ^cstring, len: ^c.size_t) -> rawptr {
	context = runtime.default_context()
	varval := cstring(iter)
	if iter == nil {
		varval = val
	}
	([^]cstring)(dir)[0] = varval
	dirend := _vim_strchr(varval, c.int(delim))
	if dirend == nil {
		([^]c.size_t)(len)[0] = libc.strlen(varval)
		return nil
	}
	([^]c.size_t)(len)[0] = c.size_t(uintptr(rawptr(dirend)) - uintptr(rawptr(varval)))
	return rawptr(uintptr(rawptr(dirend)) + 1)
}

@(export)
vim_env_iter_rev :: proc "c" (delim: u8, val: cstring, iter: rawptr, dir: ^cstring, len: ^c.size_t) -> rawptr {
	context = runtime.default_context()
	varend := cstring(iter)
	if iter == nil {
		varend = cstring(rawptr(uintptr(rawptr(val)) + uintptr(libc.strlen(val)) - 1))
	}
	varlen := c.size_t(uintptr(rawptr(varend)) - uintptr(rawptr(val))) + 1
	colon := _xmemrchr(val, delim, varlen)
	if colon == nil {
		([^]c.size_t)(len)[0] = varlen
		([^]cstring)(dir)[0] = val
		return nil
	}
	([^]cstring)(dir)[0] = cstring(rawptr(uintptr(rawptr(colon)) + 1))
	([^]c.size_t)(len)[0] = c.size_t(uintptr(rawptr(varend)) - uintptr(rawptr(colon)))
	return rawptr(uintptr(rawptr(colon)) - 1)
}

@(export)
vim_get_prefix_from_exepath :: proc "c" (exe_name: cstring) {
	context = runtime.default_context()
	_xstrlcpy(exe_name, _get_vim_var_str(VV_PROGPATH), c.size_t(MAXPATHL))
	path_end := _path_tail_with_sep(exe_name)
	([^]u8)(path_end)[0] = 0
	path_end = _path_tail(exe_name)
	([^]u8)(path_end)[0] = 0
}

// ── vim_getenv ──

_vim_runtime_dir :: proc(vimdir: cstring) -> cstring {
	if vimdir == nil || ([^]u8)(vimdir)[0] == 0 {
		return nil
	}
	vimdir_len := libc.strlen(vimdir)
	p := _concat_fnames(NvimString{data = vimdir, size = vimdir_len},
	                     NvimString{data = RUNTIME_DIRNAME, size = 7}, true)
	if os_isdir(p.data) {
		return p.data
	}
	xfree(rawptr(p.data))
	return nil
}

_remove_tail :: proc(path: cstring, pend: cstring, dirname: cstring) -> cstring {
	len := libc.strlen(dirname)
	new_tail := cstring(rawptr(uintptr(rawptr(pend)) - uintptr(len) - 1))
	if uintptr(rawptr(new_tail)) >= uintptr(rawptr(path)) && _path_fnamencmp(new_tail, dirname, c.int(len)) == 0 && (new_tail == path || _after_pathsep(path, new_tail) != 0) {
		return new_tail
	}
	return pend
}

@(export)
vim_getenv :: proc "c" (name: cstring) -> cstring {
	context = runtime.default_context()

	kos_env_path := os_getenv(name)
	if kos_env_path != nil {
		return kos_env_path
	}

	vimruntime := libc.strcmp(name, "VIMRUNTIME") == 0
	if !vimruntime && libc.strcmp(name, "VIM") != 0 {
		return nil
	}

	vim_path := cstring(nil)
	if vimruntime && ([^]u8)(default_vimruntime_dir)[0] == 0 {
		kos_env_path = os_getenv("VIM")
		if kos_env_path != nil {
			vim_path = _vim_runtime_dir(kos_env_path)
			if vim_path == nil {
				vim_path = kos_env_path
			} else {
				xfree(rawptr(kos_env_path))
			}
		}
	}

	if vim_path == nil {
		if p_hf != nil && _vim_strchr(p_hf, '$') == nil {
			vim_path = p_hf
		}

		exe_name: [MAXPATHL]u8
		if vim_path == nil {
			vim_get_prefix_from_exepath(cstring(&exe_name[0]))
			if _append_path(cstring(&exe_name[0]), "share/nvim/runtime/", c.size_t(MAXPATHL)) == OK {
				vim_path = cstring(&exe_name[0])
			}
		}

		if vim_path != nil {
			vim_path_end := _path_tail(vim_path)

			if vim_path == p_hf {
				vim_path_end = _remove_tail(vim_path, vim_path_end, "doc")
			}
			if !vimruntime {
				vim_path_end = _remove_tail(vim_path, vim_path_end, RUNTIME_DIRNAME)
			}
			if uintptr(rawptr(vim_path_end)) > uintptr(rawptr(vim_path)) && _after_pathsep(vim_path, vim_path_end) != 0 {
				vim_path_end = cstring(rawptr(uintptr(rawptr(vim_path_end)) - 1))
			}
			vim_path = _xmemdupz(rawptr(vim_path), c.size_t(uintptr(rawptr(vim_path_end)) - uintptr(rawptr(vim_path))))

			if !os_isdir(vim_path) {
				xfree(rawptr(vim_path))
				vim_path = nil
			}
		}
	}

	if vim_path == nil {
		if vimruntime && ([^]u8)(default_vimruntime_dir)[0] != 0 {
			vim_path = _xstrdup(default_vimruntime_dir)
		} else if ([^]u8)(default_vim_dir)[0] != 0 {
			if vimruntime {
				vim_path = _vim_runtime_dir(default_vim_dir)
				if vim_path == nil {
					vim_path = _xstrdup(default_vim_dir)
				}
			}
		}
	}

	if vim_path != nil {
		if vimruntime {
			os_setenv("VIMRUNTIME", vim_path, 1)
			didset_vimruntime = true
		} else {
			os_setenv("VIM", vim_path, 1)
			didset_vim = true
		}
	}
	return vim_path
}

@(export)
vim_setenv_ext :: proc "c" (name: cstring, val: cstring) {
	context = runtime.default_context()
	os_setenv(name, val, 1)
	if _strcasecmp(name, "HOME") == 0 {
		init_homedir()
	} else if didset_vim && _strcasecmp(name, "VIM") == 0 {
		didset_vim = false
	} else if didset_vimruntime && _strcasecmp(name, "VIMRUNTIME") == 0 {
		didset_vimruntime = false
	}
}

@(export)
vim_unsetenv_ext :: proc "c" (var: cstring) {
	context = runtime.default_context()
	os_unsetenv(var)
	if _strcasecmp(var, "VIM") == 0 {
		didset_vim = false
	} else if _strcasecmp(var, "VIMRUNTIME") == 0 {
		didset_vimruntime = false
	}
}
