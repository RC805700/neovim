package main

import "core:c"
import "core:c/libc"
import "base:runtime"
import "core:strings"

// ─────────────────────────────────────────────────────────────────
//  Port of src/nvim/os/shell.c to Odin.
//  Linux-only (MSWin branches dropped, matching prior ports).
//  Reuses the Odin-ported process/multiqueue/stream machinery.
// ─────────────────────────────────────────────────────────────────

// --- constants ---
NS_1_SECOND     : u64 = 1000000000  // 1 second, in nanoseconds
OUT_DATA_THRESHOLD :: 1024 * 10
SHELL_SPECIAL  :: "\t \"&'$;<>()\\|\n"
MAX_CHUNK_SIZE :: OUT_DATA_THRESHOLD / 2

// --- macros / helpers ---
GT :: proc(s: cstring) -> cstring { return s }

TAB : u8 = 9
NL  : u8 = 10
CAR : u8 = 13
READBIN  : cstring = "rb"
STDOUT_FILENO : c.int = 1
STDERR_FILENO : c.int = 2

// VV_SHELL_ERROR (eval_defs.h enum ordinal 6)
VV_SHELL_ERROR : c.int = 6

// ShellOpts (os/shell.h)
kShellOptFilter   : c.int = 1
kShellOptExpand   : c.int = 2
kShellOptDoOut    : c.int = 4
kShellOptRead     : c.int = 16
kShellOptWrite    : c.int = 32
kShellOptHideMess : c.int = 64

// EW_* flags (path.h)
EW_DIR       : c.int = 0x01
EW_FILE      : c.int = 0x02
EW_NOTFOUND  : c.int = 0x04
EW_SILENT    : c.int = 0x20
EW_EXEC      : c.int = 0x40
EW_KEEPDOLLAR : c.int = 0x800

// State / MODE (state_defs.h)
MODE_EXTERNCMD : c.int = 0x5000

// UIExtension
kUIMessages : c.int = 1

// HLF_* (highlight_defs.h)
HLF_SE : c.int = 20
HLF_SO : c.int = 21

// PROF_* (profile.h)
PROF_NONE : c.int = 0
PROF_YES  : c.int = 1

// types
char_u :: u8
varnumber_T :: u64
proftime_T :: u64

StringBuilder :: struct {
	size:     c.size_t,
	capacity: c.size_t,
	items:    ^u8,
}

// ─────────────────────────────────────────────────────────────────
//  Foreign C symbols (FFI) — reserved onto C until cutover.
// ─────────────────────────────────────────────────────────────────
foreign _ {
	@(link_name = "sandbox")
	sandbox: c.int

	@(link_name = "secure")
	secure: bool

	@(link_name = "p_verbose")
	p_verbose: c.int

	@(link_name = "State")
	State: c.int

	@(link_name = "no_check_timestamps")
	no_check_timestamps: c.int

	@(link_name = "do_profiling")
	do_profiling: c.int

	@(link_name = "emsg_silent")
	emsg_silent: c.int

	@(link_name = "lines_left")
	lines_left: c.int

	@(link_name = "msg_no_more")
	msg_no_more: u8 // C: EXTERN bool msg_no_more (1 byte!) — int decl clobbered ex_nesting_level

	@(link_name = "p_sh")
	p_sh: cstring

	@(link_name = "p_shcf")
	p_shcf: cstring

	@(link_name = "p_sxq")
	p_sxq: cstring

	@(link_name = "p_sxe")
	p_sxe: cstring

	@(link_name = "utf8len_tab_zero")
	utf8len_tab_zero: [256]u8

	// message
	@(link_name = "msg_puts")
	msg_puts :: proc "c" (s: cstring) ---
	@(link_name = "msg_putchar")
	msg_putchar :: proc "c" (c: c.int) ---
	@(link_name = "msg_start")
	msg_start :: proc "c" () ---
	@(link_name = "msg_end")
	msg_end :: proc "c" () -> bool ---
	@(link_name = "msg_outtrans")
	msg_outtrans :: proc "c" (str: cstring, hl_id: c.int, hist: bool) -> c.int ---
	@(link_name = "msg_outnum")
	msg_outnum :: proc "c" (n: c.int) ---
	@(link_name = "msg_sb_eol")
	msg_sb_eol :: proc "c" () ---
	@(link_name = "msg_ext_set_kind")
	msg_ext_set_kind :: proc "c" (msg_kind: cstring) ---
	@(link_name = "msg_ext_set_append")
	msg_ext_set_append :: proc "c" (append: bool) ---
	@(link_name = "msg_ext_no_fast")
	msg_ext_no_fast :: proc "c" () ---
	@(link_name = "msg_multiline")
	msg_multiline :: proc "c" (str: String, hl_id: c.int, check_int: bool, hist: bool, need_clear: ^bool) ---
	@(link_name = "msg_schedule_semsg")
	msg_schedule_semsg :: proc "c" (fmt: cstring, args: ..any) ---
	@(link_name = "smsg")
	smsg :: proc "c" (hl_id: c.int, s: cstring, args: ..any) ---
	@(link_name = "semsg")
	semsg :: proc "c" (fmt: cstring, args: ..any) ---
	@(link_name = "wait_return")
	wait_return :: proc "c" (redraw: c.int) ---

	// ui
	@(link_name = "ui_flush")
	ui_flush :: proc "c" () ---
	@(link_name = "ui_busy_start")
	ui_busy_start :: proc "c" () ---
	@(link_name = "ui_busy_stop")
	ui_busy_stop :: proc "c" () ---
	@(link_name = "ui_has")
	ui_has :: proc "c" (ext: c.int) -> bool ---

	// path / charset / strings
	@(link_name = "path_has_wildcard")
	path_has_wildcard :: proc "c" (p: cstring) -> bool ---
	@(link_name = "invocation_path_tail")
	invocation_path_tail :: proc "c" (invocation: cstring, len: ^c.size_t) -> cstring ---
	@(link_name = "backslash_halve")
	backslash_halve :: proc "c" (p: ^u8) ---
	@(link_name = "add_pathsep")
	add_pathsep :: proc "c" (p: ^u8) -> bool ---
	@(link_name = "vim_strsave_escaped_ext")
	vim_strsave_escaped_ext :: proc "c" (string: cstring, esc_chars: cstring, cc: u8, bsl: bool) -> cstring ---
	@(link_name = "vim_strnsave_unquoted")
	vim_strnsave_unquoted :: proc "c" (string: ^u8, length: c.size_t) -> cstring ---
	@(link_name = "vim_snprintf")
	vim_snprintf :: proc "c" (str: ^u8, str_m: c.size_t, fmt: cstring, args: ..any) -> c.int ---

	// misc
	@(link_name = "vim_tempname")
	vim_tempname :: proc "c" () -> cstring ---
	@(link_name = "check_secure")
	check_secure :: proc "c" () -> bool ---
	@(link_name = "make_filter_cmd")
	make_filter_cmd :: proc "c" (cmd: cstring, itmp: cstring, otmp: cstring, do_in: bool) -> cstring ---
	@(link_name = "tag_freematch")
	tag_freematch :: proc "c" () ---
	@(link_name = "restore_env_var")
	restore_env_var :: proc "c" (name: cstring, old_value: cstring, must_free: bool) ---
	@(link_name = "verbose_enter")
	verbose_enter :: proc "c" () ---
	@(link_name = "verbose_leave")
	verbose_leave :: proc "c" () ---
	@(link_name = "prof_child_enter")
	prof_child_enter :: proc "c" (tm: ^proftime_T) ---
	@(link_name = "prof_child_exit")
	prof_child_exit :: proc "c" (tm: ^proftime_T) ---
	@(link_name = "uv_strerror")
	os_strerror :: proc "c" (err: c.int) -> cstring ---

	// memory (link to C x* allocators)
	@(link_name = "xstrdup")
	xstrdup :: proc "c" (s: ^u8) -> ^u8 ---
	@(link_name = "xmemdupz")
	xmemdupz :: proc "c" (data: rawptr, len: c.size_t) -> ^u8 ---
	@(link_name = "xstrlcat")
	xstrlcat :: proc "c" (dst: ^u8, src: ^u8, size: c.size_t) -> c.size_t ---
	@(link_name = "vim_strchr")
	vim_strchr :: proc "c" (s: ^u8, c: c.int) -> ^u8 ---
}

// ─────────────────────────────────────────────────────────────────
//  Static helpers
// ─────────────────────────────────────────────────────────────────

save_patterns :: proc(num_pat: c.int, pat: ^^u8, num_file: ^c.int, file: ^^^u8) {
	context = runtime.default_context()
	file^ = (^^u8)(xmalloc(c.size_t(num_pat) * size_of(^u8)))
	for i := c.int(0); i < num_pat; i += 1 {
		s := xstrdup(([^]^u8)(pat)[i])
		backslash_halve(s)
		([^]^u8)(file^)[i] = s
	}
	num_file^ = num_pat
}

have_wildcard :: proc(num: c.int, file: ^^u8) -> bool {
	context = runtime.default_context()
	for i := c.int(0); i < num; i += 1 {
		if path_has_wildcard(transmute(cstring)(([^]^u8)(file)[i])) {
			return true
		}
	}
	return false
}

have_dollars :: proc(num: c.int, file: ^^u8) -> bool {
	context = runtime.default_context()
	for i := c.int(0); i < num; i += 1 {
		if vim_strchr(([^]^u8)(file)[i], c.int('$')) != nil {
			return true
		}
	}
	return false
}

// kv helpers for StringBuilder (kvec_t(char))
kv_init :: proc(sb: ^StringBuilder) {
	context = runtime.default_context()
	sb.size = 0
	sb.capacity = 0
	sb.items = nil
}

kv_resize :: proc(sb: ^StringBuilder, need: c.size_t) {
	context = runtime.default_context()
	newcap := sb.capacity
	if newcap == 0 {
		newcap = 16
	}
	for newcap < need {
		newcap *= 2
	}
	sb.items = (^u8)(xmalloc(newcap))
	sb.capacity = newcap
}

kv_push :: proc(sb: ^StringBuilder, c: u8) {
	context = runtime.default_context()
	if sb.size + 1 > sb.capacity {
		kv_resize(sb, sb.size + 1)
	}
	([^]u8)(sb.items)[sb.size] = c
	sb.size += 1
}

kv_concat_len :: proc(sb: ^StringBuilder, s: ^u8, len: c.size_t) {
	context = runtime.default_context()
	if sb.size + len > sb.capacity {
		kv_resize(sb, sb.size + len)
	}
	for i := c.size_t(0); i < len; i += 1 {
		([^]u8)(sb.items)[sb.size + i] = ([^]u8)(s)[i]
	}
	sb.size += len
}

kv_destroy :: proc(sb: ^StringBuilder) {
	context = runtime.default_context()
	if sb.items != nil {
		xfree(sb.items)
		sb.items = nil
	}
	sb.size = 0
	sb.capacity = 0
}

// ─────────────────────────────────────────────────────────────────
//  Exported functions
// ─────────────────────────────────────────────────────────────────

@(export)
os_expand_wildcards :: proc "c" (num_pat: c.int, pat: ^^u8, num_file: ^c.int, file: ^^^u8, flags: c.int) -> c.int {
	context = runtime.default_context()
	i: c.int
	len: c.size_t
	p: ^u8
	extra_shell_arg: cstring = nil
	shellopts := kShellOptExpand | kShellOptSilent
	j: c.int
	tempname: cstring

	STYLE_ECHO    :: 0
	STYLE_GLOB    :: 1
	STYLE_VIMGLOB :: 2
	STYLE_PRINT   :: 3
	STYLE_BT      :: 4
	STYLE_GLOBSTAR :: 5

	shell_style := STYLE_ECHO
	check_spaces: bool
	did_find_nul: bool = false
	ampersand := false

	expand: {
	sh_vimglob_func := cstring("vimglob() { while [ $# -ge 1 ]; do echo \"$1\"; shift; done }; vimglob >")
	sh_globstar_opt := cstring("[[ ${BASH_VERSINFO[0]} -ge 4 ]] && shopt -s globstar; ")

	is_fish_shell := false
	ptail := invocation_path_tail(p_sh, nil)
	if len := c.size_t(0); ptail != nil {
		plen := c.size_t(0)
		for ([^]u8)(ptail)[plen] != 0 {
			plen += 1
		}
		if plen >= 4 && strings.compare(transmute(string)(([^]u8)(ptail)[0:4]), "fish") == 0 {
			is_fish_shell = true
		}
	}

	num_file^ = 0
	file^ = nil

	if !have_wildcard(num_pat, pat) {
		save_patterns(num_pat, pat, num_file, file)
		return OK
	}

	if sandbox != 0 && check_secure() {
		return FAIL
	}

	if secure {
		for i = 0; i < num_pat; i += 1 {
			if vim_strchr(([^]^u8)(pat)[i], c.int('`')) != nil && check_secure() {
				return FAIL
			}
		}
	}

	tempname = vim_tempname()
	if tempname == nil {
		emsg(GT(cstring("E303: Unable to open temp file for writing")))
		return FAIL
	}

	if num_pat == 1 {
		pa0 := ([^]^u8)(pat)[0]
		if ([^]u8)(pa0)[0] == '`' {
			_l := c.size_t(0)
			for ([^]u8)(pa0)[_l] != 0 {
				_l += 1
			}
			if _l > 2 && ([^]u8)(pa0)[_l-1] == '`' {
				shell_style = STYLE_BT
			}
		}
	} else if _l := c.size_t(0); true {
		_l2 := c.size_t(0)
		for ([^]u8)(p_sh)[_l2] != 0 {
			_l2 += 1
		}
		if _l2 >= 3 {
			if strings.compare(transmute(string)(([^]u8)(p_sh)[_l2-3:_l2]), "csh") == 0 {
				shell_style = STYLE_GLOB
			} else if strings.compare(transmute(string)(([^]u8)(p_sh)[_l2-3:_l2]), "zsh") == 0 {
				shell_style = STYLE_PRINT
			}
		}
	}

	if shell_style == STYLE_ECHO {
		pt := path_tail(p_sh)
		if strings.contains(string(pt), "bash") {
			shell_style = STYLE_GLOBSTAR
		} else if strings.contains(string(pt), "sh") {
			shell_style = STYLE_VIMGLOB
		}
	}

	len = c.size_t(0)
	for k := c.size_t(0); ([^]u8)(p_sh)[k] != 0; k += 1 {
		len += 1
	}
	len += 29
	if shell_style == STYLE_VIMGLOB {
		len += c.size_t(0)
		for ([^]u8)(sh_vimglob_func)[len-29] != 0 {
			break
		}
		// add length of sh_vimglob_func
		vl := c.size_t(0)
		for ([^]u8)(sh_vimglob_func)[vl] != 0 {
			vl += 1
		}
		len += vl
	} else if shell_style == STYLE_GLOBSTAR {
		vl := c.size_t(0)
		for ([^]u8)(sh_vimglob_func)[vl] != 0 {
			vl += 1
		}
		gl := c.size_t(0)
		for ([^]u8)(sh_globstar_opt)[gl] != 0 {
			gl += 1
		}
		len += vl + gl
	}

	for i = 0; i < num_pat; i += 1 {
		len += 1
		j = 0
		for ([^]u8)(([^]^u8)(pat)[i])[j] != 0 {
			if vim_strchr((^u8)(transmute(^u8)(cstring(SHELL_SPECIAL))), c.int(u8(([^]u8)(([^]^u8)(pat)[i])[j]))) != nil {
				len += 1
			}
			len += 1
			j += 1
		}
	}

	if is_fish_shell {
		len += c.size_t(cstr_len(transmute(^u8)(cstring("begin;"))) + cstr_len(transmute(^u8)(cstring(" end"))) - 1)
	}

	command := (^u8)(xmalloc(len))

	if shell_style == STYLE_BT {
		if is_fish_shell {
			xstrlcpy(transmute(cstring)(command), cstring("begin; "), len)
		} else {
			xstrlcpy(transmute(cstring)(command), cstring("("), len)
		}
		xstrlcat(command, (^u8)(uintptr(([^]^u8)(pat)[0]) + 1), len)
		p = (^u8)(uintptr(command) + uintptr(cstr_len(command)) - 1)
		if is_fish_shell {
			p^ = u8(';')
			p = (^u8)(uintptr(p) - 1)
			xstrlcat(command, (^u8)(transmute(^u8)(cstring(" end"))), len)
		} else {
			p^ = u8(')')
			p = (^u8)(uintptr(p) - 1)
		}
		for p > command && ascii_iswhite(p^) {
			p = (^u8)(uintptr(p) - 1)
		}
		if p^ == '&' {
			ampersand = true
			p^ = u8(' ')
		}
		xstrlcat(command, (^u8)(transmute(^u8)(cstring(">"))), len)
	} else {
		([^]u8)(command)[0] = 0
		if shell_style == STYLE_GLOB {
			if flags & EW_NOTFOUND != 0 {
				xstrlcat(command, (^u8)(transmute(^u8)(cstring("set nonomatch; "))), len)
			} else {
				xstrlcat(command, (^u8)(transmute(^u8)(cstring("unset nonomatch; "))), len)
			}
		}
		if shell_style == STYLE_GLOB {
			xstrlcat(command, (^u8)(transmute(^u8)(cstring("glob >"))), len)
		} else if shell_style == STYLE_PRINT {
			xstrlcat(command, (^u8)(transmute(^u8)(cstring("print -N >"))), len)
		} else if shell_style == STYLE_VIMGLOB {
			xstrlcat(command, transmute(^u8)(sh_vimglob_func), len)
		} else if shell_style == STYLE_GLOBSTAR {
			xstrlcat(command, transmute(^u8)(sh_globstar_opt), len)
			xstrlcat(command, transmute(^u8)(sh_vimglob_func), len)
		} else {
			xstrlcat(command, (^u8)(transmute(^u8)(cstring("echo >"))), len)
		}
	}

	xstrlcat(command, transmute(^u8)(tempname), len)

	if shell_style != STYLE_BT {
		for i = 0; i < num_pat; i += 1 {
			intick := false
			p = (^u8)(uintptr(command) + uintptr(cstr_len(command)))
			p^ = u8(' ')
			p = (^u8)(uintptr(p) + 1)
			j = 0
			for ([^]u8)(([^]^u8)(pat)[i])[j] != 0 {
				if ([^]u8)(([^]^u8)(pat)[i])[j] == '`' {
					intick = !intick
				} else if ([^]u8)(([^]^u8)(pat)[i])[j] == '\\' && ([^]u8)(([^]^u8)(pat)[i])[j+1] != 0 {
					if intick || vim_strchr((^u8)(transmute(^u8)(cstring(SHELL_SPECIAL))), c.int(u8(([^]u8)(([^]^u8)(pat)[i])[j+1]))) != nil || ([^]u8)(([^]^u8)(pat)[i])[j+1] == '`' {
						p^ = u8('\\')
						p = (^u8)(uintptr(p) + 1)
					}
					j += 1
				} else if !intick && ((flags & EW_KEEPDOLLAR) == 0 || ([^]u8)(([^]^u8)(pat)[i])[j] != '$') && vim_strchr((^u8)(transmute(^u8)(cstring(SHELL_SPECIAL))), c.int(u8(([^]u8)(([^]^u8)(pat)[i])[j]))) != nil {
					p^ = u8('\\')
					p = (^u8)(uintptr(p) + 1)
				}
				p^ = ([^]u8)(([^]^u8)(pat)[i])[j]
				p = (^u8)(uintptr(p) + 1)
				j += 1
			}
			p^ = 0
		}
	}

	if flags & EW_SILENT != 0 {
		shellopts |= kShellOptHideMess
	}

	if ampersand {
		xstrlcat(command, (^u8)(transmute(^u8)(cstring("&"))), len)
	}

	if shell_style == STYLE_PRINT {
		extra_shell_arg = "-G"
	} else if shell_style == STYLE_GLOB && !have_dollars(num_pat, pat) {
		extra_shell_arg = "-f"
	}

	i = call_shell(command, shellopts, nil)

	if ampersand {
		os_delay(10, true)
	}

	xfree(command)

	if i != 0 {
		os_remove(tempname)
		xfree(transmute(rawptr)(tempname))
		if flags & EW_SILENT == 0 {
			msg_putchar('\'')
			cmdline_row = Rows - 1
			emsg(GT(cstring("E79: Cannot expand wildcards")))
			msg_start()
		}
		if shell_style == STYLE_BT {
			return FAIL
		}
		break expand
	}

	fd := os_fopen(transmute(cstring)(tempname), READBIN)
	if fd == nil {
		if flags & EW_SILENT == 0 {
			emsg(GT(cstring("E79: Cannot expand wildcards")))
			msg_start()
		}
		xfree(transmute(rawptr)(tempname))
		break expand
	}
	if libc.fseek(transmute(^libc.FILE)(fd), libc.long(0), libc.Whence.END) < 0 {
		xfree(transmute(rawptr)(tempname))
		libc.fclose(transmute(^libc.FILE)(fd))
		return FAIL
	}
	templen := libc.ftell(transmute(^libc.FILE)(fd))
	if templen < 0 {
		xfree(transmute(rawptr)(tempname))
		libc.fclose(transmute(^libc.FILE)(fd))
		return FAIL
	}
	len = c.size_t(templen)
	libc.fseek(transmute(^libc.FILE)(fd), libc.long(0), libc.Whence.SET)
	buffer := (^u8)(xmalloc(len + 1))
	readlen := libc.fread(transmute(rawptr)(buffer), c.size_t(1), len, transmute(^libc.FILE)(fd))
	libc.fclose(transmute(^libc.FILE)(fd))
	os_remove(tempname)
	if readlen != len {
		semsg(GT(cstring("E190: Cannot read from \"%s\"")), tempname)
		xfree(transmute(rawptr)(tempname))
		xfree(transmute(rawptr)(buffer))
		return FAIL
	}
	xfree(transmute(rawptr)(tempname))

	if shell_style == STYLE_ECHO {
		([^]u8)(buffer)[len] = NL
		p = buffer
		for i = 0; p^ != NL; i += 1 {
			for p^ != ' ' && p^ != NL {
				p = (^u8)(uintptr(p) + 1)
			}
			p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
		}
	} else if shell_style == STYLE_BT || shell_style == STYLE_VIMGLOB || shell_style == STYLE_GLOBSTAR {
		([^]u8)(buffer)[len] = NUL
		p = buffer
		for i = 0; p^ != NUL; i += 1 {
			for p^ != NL && p^ != NUL {
				p = (^u8)(uintptr(p) + 1)
			}
			if p^ != NUL {
				p = (^u8)(uintptr(p) + 1)
			}
			p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
		}
	} else {
		check_spaces = false
		if shell_style == STYLE_PRINT && !did_find_nul {
			([^]u8)(buffer)[len] = NUL
			sl := cstr_len(buffer)
			if len != 0 && sl < len {
				did_find_nul = true
			} else {
				check_spaces = true
			}
		}
		if len != 0 && ([^]u8)(buffer)[len-1] == NUL {
			len -= 1
		} else {
			([^]u8)(buffer)[len] = NUL
		}
		for p = buffer; p < (^u8)(uintptr(buffer) + uintptr(len)); p = (^u8)(uintptr(p) + 1) {
			if p^ == NUL || (p^ == ' ' && check_spaces) {
				i += 1
				p^ = NUL
			}
		}
		if len != 0 {
			i += 1
		}
	}

	if i == 0 {
		xfree(transmute(rawptr)(buffer))
		break expand
	}
	num_file^ = i
	file^ = (^^u8)(xmalloc(c.size_t(i) * size_of(^u8)))

	p = buffer
	for i := c.int(0); i < num_file^; i += 1 {
		([^]^u8)(file^)[i] = p
		if shell_style == STYLE_ECHO || shell_style == STYLE_BT || shell_style == STYLE_VIMGLOB || shell_style == STYLE_GLOBSTAR {
			for !(shell_style == STYLE_ECHO && p^ == ' ') && p^ != NL && p^ != NUL {
				p = (^u8)(uintptr(p) + 1)
			}
			if p == (^u8)(uintptr(buffer) + uintptr(len)) {
				p^ = NUL
			} else {
				p^ = NUL
				p = (^u8)(uintptr(p) + 1)
				p = transmute(^u8)(skipwhite(transmute(cstring)(p)))
			}
		} else {
			for p^ != 0 && p < (^u8)(uintptr(buffer) + uintptr(len)) {
				p = (^u8)(uintptr(p) + 1)
			}
			p = (^u8)(uintptr(p) + 1)
		}
	}

	j := c.int(0)
	i := c.int(0)
	for i < num_file^ {
		if flags & EW_NOTFOUND == 0 && !os_path_exists(transmute(cstring)(([^]^u8)(file^)[i])) {
			continue
		}
		dir := os_isdir(transmute(cstring)(([^]^u8)(file^)[i]))
		if (dir && flags & EW_DIR == 0) || (!dir && flags & EW_FILE == 0) {
			continue
		}
		if !dir && flags & EW_EXEC != 0 && !os_can_exe(transmute(cstring)(([^]^u8)(file^)[i]), nil, flags & (EW_EXEC<<1) == 0) {
			continue
		}
		pp := (^u8)(xmalloc(cstr_len((^u8)(uintptr(([^]^u8)(file^)[i]) + 1)) + 1 + (dir ? 1 : 0)))
		xstrlcpy(transmute(cstring)(pp), transmute(cstring)(([^]^u8)(file^)[i]), c.size_t(cstr_len((^u8)(uintptr(([^]^u8)(file^)[i]) + 1))))
		if dir {
			add_pathsep(pp)
		}
		([^]^u8)(file^)[j] = pp
		j += 1
		i += 1
	}
	xfree(transmute(rawptr)(buffer))
	num_file^ = j

	if num_file^ == 0 {
		if file^ != nil {
			xfree(transmute(rawptr)(file^))
			file^ = nil
		}
		break expand
	}

	return OK
	}

	if flags & EW_NOTFOUND != 0 {
		save_patterns(num_pat, pat, num_file, file)
		return OK
	}
	return FAIL
}

cstr_len :: proc(s: ^u8) -> c.size_t {
	context = runtime.default_context()
	n := c.size_t(0)
	for ([^]u8)(s)[n] != 0 {
		n += 1
	}
	return n
}

@(export)
shell_build_argv :: proc "c" (cmd: cstring, extra_args: cstring) -> ^^u8 {
	context = runtime.default_context()
	extra: c.size_t = 0
	if cmd != nil {
		extra = tokenize(p_shcf, nil)
	}
	argc := tokenize(p_sh, nil) + extra
	rv := (^^u8)(xmalloc((argc + 4) * size_of(^u8)))

	i := tokenize(p_sh, rv)

	if extra_args != nil {
		([^]^u8)(rv)[i] = xstrdup(transmute(^u8)(extra_args))
		i += 1
	}

	if cmd != nil {
		i += tokenize(p_shcf, transmute(^^u8)(uintptr(rv) + uintptr(i)*8))
		([^]^u8)(rv)[i] = shell_xescape_xquote(cmd)
		i += 1
	}

	([^]^u8)(rv)[i] = nil
	return rv
}

@(export)
shell_free_argv :: proc "c" (argv: ^^u8) {
	context = runtime.default_context()
	if argv == nil {
		return
	}
	p := argv
	for p^ != nil {
		xfree(transmute(rawptr)(p^))
		p = (^^u8)(uintptr(p) + 8)
	}
	xfree(transmute(rawptr)(argv))
}

@(export)
shell_argv_to_str :: proc "c" (argv: ^^u8) -> cstring {
	context = runtime.default_context()
	n := c.size_t(0)
	p := argv
	rv := (^u8)(xcalloc(256, size_of(^u8)))
	maxsize: c.size_t = 256
	if p^ == nil {
		return transmute(cstring)(rv)
	}
	for p^ != nil {
		xstrlcat(rv, transmute(^u8)(cstring("'")), maxsize)
		xstrlcat(rv, p^, maxsize)
		n = xstrlcat(rv, transmute(^u8)(cstring("' ")), maxsize)
		if n >= maxsize {
			break
		}
		p = (^^u8)(uintptr(p) + 8)
	}
	if n < maxsize {
		([^]u8)(rv)[n-1] = u8(0)
	} else {
		([^]u8)(rv)[maxsize-4] = u8('.')
		([^]u8)(rv)[maxsize-3] = u8('.')
		([^]u8)(rv)[maxsize-2] = u8('.')
		([^]u8)(rv)[maxsize-1] = u8(0)
	}
	return transmute(cstring)(rv)
}

@(export)
os_call_shell :: proc "c" (cmd: ^u8, opts: c.int, extra_args: ^u8) -> c.int {
	context = runtime.default_context()
	input := StringBuilder{}
	kv_init(&input)
	output: ^u8 = nil
	output_ptr: ^^u8 = nil
	current_state := State
	forward_output := true

	signal_reject_deadly()

	if opts & (kShellOptHideMess | kShellOptExpand) != 0 {
		forward_output = false
	} else {
		State = MODE_EXTERNCMD
		if opts & kShellOptWrite != 0 {
			read_input(&input)
		}
		if opts & kShellOptRead != 0 {
			output_ptr = &output
			forward_output = false
		} else if opts & kShellOptDoOut != 0 {
			forward_output = false
		}
	}

	nread: c.size_t
	exitcode := do_os_system(shell_build_argv(transmute(cstring)(cmd), transmute(cstring)(extra_args)),
		transmute(^u8)(input.items), input.size, output_ptr, &nread,
		emsg_silent != 0, forward_output)
	kv_destroy(&input)

	if output != nil {
		write_output(output, nread, true)
		xfree(transmute(rawptr)(output))
	}

	if emsg_silent == 0 && exitcode != 0 && opts & kShellOptSilent == 0 {
		msg_ext_set_kind("shell_ret")
		msg_ext_no_fast()
		if !ui_has(kUIMessages) {
			msg_putchar('\'')
		}
		msg_puts(GT(cstring("shell returned ")))
		msg_outnum(exitcode)
	}

	State = current_state
	signal_accept_deadly()

	return exitcode
}

@(export)
call_shell :: proc "c" (cmd: ^u8, opts: c.int, extra_shell_arg: ^u8) -> c.int {
	context = runtime.default_context()
	retval: c.int
	wait_time: proftime_T

	if p_verbose > 3 {
		verbose_enter()
		cmds: cstring = p_sh
		if cmd != nil {
			cmds = transmute(cstring)(cmd)
		}
		smsg(0, GT("Executing command: \"%s\""), cmds)
		if !ui_has(kUIMessages) {
			msg_putchar('\'')
		}
		verbose_leave()
	}

	if do_profiling == PROF_YES {
		prof_child_enter(&wait_time)
	}

	if ([^]u8)(p_sh)[0] == 0 {
		emsg(GT(cstring("E91: 'shell' option is empty")))
		retval = -1
	} else {
		tag_freematch()
		retval = os_call_shell(cmd, opts, extra_shell_arg)
	}

	set_vim_var_nr(VV_SHELL_ERROR, i64(retval))
	if do_profiling == PROF_YES {
		prof_child_exit(&wait_time)
	}

	return retval
}

@(export)
get_cmd_output :: proc "c" (cmd: cstring, infile: cstring, flags: c.int, ret_len: ^c.size_t) -> cstring {
	context = runtime.default_context()
	buffer: ^u8 = nil

	if check_secure() {
		return nil
	}

	tempname := vim_tempname()
	if tempname == nil {
		emsg(GT(cstring("E303: Unable to open temp file for writing")))
		return nil
	}

	command := make_filter_cmd(cmd, infile, tempname, false)

	no_check_timestamps += 1
	call_shell(transmute(^u8)(command), kShellOptDoOut | kShellOptExpand | flags, nil)
	no_check_timestamps -= 1

	xfree(transmute(rawptr)(command))

	fd := os_fopen(tempname, READBIN)

	gc: {
	len_l: c.long
	if fd == nil || libc.fseek(transmute(^libc.FILE)(fd), libc.long(0), libc.Whence.END) == -1 {
		semsg(GT(cstring("E483: Cannot read from %s")), tempname)
		if fd != nil {
			libc.fclose(transmute(^libc.FILE)(fd))
		}
		break gc
	}
	len_l = libc.ftell(transmute(^libc.FILE)(fd))
	if len_l == -1 || libc.fseek(transmute(^libc.FILE)(fd), libc.long(0), libc.Whence.SET) == -1 {
		semsg(GT(cstring("E483: Cannot read from %s")), tempname)
		if fd != nil {
			libc.fclose(transmute(^libc.FILE)(fd))
		}
		break gc
	}

	len := c.size_t(len_l)
	buffer = (^u8)(xmalloc(len + 1))
	i := libc.fread(transmute(rawptr)(buffer), c.size_t(1), len, transmute(^libc.FILE)(fd))
	libc.fclose(transmute(^libc.FILE)(fd))
	os_remove(tempname)
	if i != len {
		semsg(GT(cstring("E190: Cannot read from \"%s\"")), tempname)
		if buffer != nil {
	xfree(transmute(rawptr)(buffer))
			buffer = nil
		}
	} else if ret_len == nil {
		for k := c.size_t(0); k < len; k += 1 {
			if ([^]u8)(buffer)[k] == NUL {
				([^]u8)(buffer)[k] = 1
			}
		}
		([^]u8)(buffer)[len] = NUL
	} else {
		ret_len^ = len
	}
	}

	xfree(transmute(rawptr)(tempname))
	return transmute(cstring)(buffer)
}

@(export)
os_system :: proc "c" (argv: ^^u8, input: ^u8, len: c.size_t, output: ^^u8, nread: ^c.size_t) -> c.int {
	context = runtime.default_context()
	return do_os_system(argv, input, len, output, nread, true, false)
}

do_os_system :: proc(argv: ^^u8, input: ^u8, len: c.size_t, output: ^^u8, nread: ^c.size_t,
                     silent: bool, forward_output: bool) -> c.int {
	exitcode: c.int = -1
	events: ^MultiQueue = nil

	dos: {
	out_data_decide_throttle(0)
	out_data_ring(nil, 0)
	has_input := (input != nil && len > 0)

	buf := StringBuilder{}
	kv_init(&buf)
	data_cb: stream_read_cb = system_data_cb
	if nread != nil {
		nread^ = 0
	}

	if forward_output {
		data_cb = out_data_cb
	} else if output == nil {
		data_cb = nil
	}

	prog := (^u8)(xmalloc(MAXPATHL))
	xstrlcpy(transmute(cstring)(prog), transmute(cstring)(([^]^u8)(argv)[0]), MAXPATHL)

	uvpr := libuv_proc_init(&main_loop, transmute(rawptr)(&buf))
	pr := &uvpr.base
	events = multiqueue_new_child(main_loop.events)
	pr.events = events
	pr.argv = argv
	status := proc_spawn(pr, has_input, true, true)
	if status != 0 {
		loop_poll_events(&main_loop, 0)
		if !silent {
			msg_puts(GT(cstring("\nshell failed to start: ")))
			msg_outtrans(os_strerror(status), 0, false)
			msg_puts(": ")
			msg_outtrans(transmute(cstring)(prog), 0, false)
			msg_putchar('\'')
		}
		break dos
	}

	if has_input {
		wstream_init(&pr.in_s, 0)
	}
	rstream_init(&pr.out_s)
	rstream_start(&pr.out_s, data_cb, transmute(rawptr)(&buf))
	rstream_init(&pr.err_s)
	rstream_start(&pr.err_s, data_cb, transmute(rawptr)(&buf))

	if has_input {
		input_buffer := wstream_new_buffer(input, len, 1, nil)
		if wstream_write(&pr.in_s, input_buffer) != 0 {
			proc_stop(pr)
			break dos
		}
		wstream_set_write_cb(&pr.in_s, shell_write_cb, nil)
	}

	ui_busy_start()
	ui_flush()
	if forward_output {
		msg_sb_eol()
		msg_start()
		msg_no_more = 1
		lines_left = -1
	}
	exitcode = proc_wait(pr, -1, nil)
	if !got_int && out_data_decide_throttle(0) {
		out_data_ring(nil, c.size_t(SIZE_MAX))
	}
	if forward_output {
		no_wait_return = 1
		msg_end()
		no_wait_return = 0
		msg_no_more = 0
	}

	ui_busy_stop()

	if output != nil {
		if buf.size == 0 {
			output^ = nil
			nread^ = 0
			kv_destroy(&buf)
		} else {
			nread^ = buf.size
			kv_push(&buf, NUL)
			output^ = transmute(^u8)(buf.items)
		}
	}
	}

	multiqueue_free(events)
	return exitcode
}

system_data_cb :: proc(stream: ^RStream, buf: ^u8, count: c.size_t, data: rawptr, eof: bool) -> c.size_t {
	context = runtime.default_context()
	dbuf := (^StringBuilder)(data)
	kv_concat_len(dbuf, buf, count)
	return count
}

out_data_decide_throttle :: proc(size: c.size_t) -> bool {
	context = runtime.default_context()
	started: u64 = 0
	received: c.size_t = 0
	visit: c.size_t = 0
	pulse_msg: [4]u8 = { ' ', ' ', ' ', 0 }

	if size == 0 {
		previous_decision := (visit > 0)
		started = 0
		received = 0
		visit = 0
		return previous_decision
	}

	received += size
	if received < OUT_DATA_THRESHOLD || (started == 0 && received < size + 1000) {
		return false
	} else if visit == 0 {
		started = os_hrtime()
	} else {
		since := os_hrtime() - started
		if since < (u64(visit) * (NS_1_SECOND / 10)) {
			return true
		}
		if since > (3 * NS_1_SECOND) {
			received = 0
			visit = 0
			return false
		}
	}

	visit += 1
	tick := visit % 4
	if tick > 0 { pulse_msg[0] = '.' } else { pulse_msg[0] = ' ' }
	if tick > 1 { pulse_msg[1] = '.' } else { pulse_msg[1] = ' ' }
	if tick > 2 { pulse_msg[2] = '.' } else { pulse_msg[2] = ' ' }
	if visit == 1 {
		msg_puts("...\n")
	}
	msg_putchar('\r')
	msg_puts(transmute(cstring)(&pulse_msg[0]))
	msg_putchar('\r')
	ui_flush()
	return true
}

out_data_ring :: proc(output: ^u8, size: c.size_t) {
	context = runtime.default_context()
	last_skipped: [MAX_CHUNK_SIZE]u8
	last_skipped_len: c.size_t = 0

	if output == nil && size == 0 {
		last_skipped_len = 0
		return
	}

	if output == nil && size == c.size_t(SIZE_MAX) {
		out_data_append_to_screen(&last_skipped[0], &last_skipped_len, STDOUT_FILENO, true)
		return
	}

	if size >= MAX_CHUNK_SIZE {
		start := size - MAX_CHUNK_SIZE
		for k := c.size_t(0); k < MAX_CHUNK_SIZE; k += 1 {
			last_skipped[k] = ([^]u8)(output)[start+k]
		}
		last_skipped_len = MAX_CHUNK_SIZE
	} else if size > 0 {
		keep_len := MIN(last_skipped_len, MAX_CHUNK_SIZE - size)
		keep_start := last_skipped_len - keep_len
		if keep_start != 0 {
			for k := c.size_t(0); k < keep_len; k += 1 {
				last_skipped[k] = last_skipped[keep_start+k]
			}
		}
		for k := c.size_t(0); k < size; k += 1 {
			last_skipped[keep_len+k] = ([^]u8)(output)[k]
		}
		last_skipped_len = keep_len + size
	}
}

MIN :: proc(a, b: c.size_t) -> c.size_t {
	context = runtime.default_context()
	if a < b { return a }
	return b
}

out_data_event :: proc(argv: ^rawptr) {
	context = runtime.default_context()
	need_clear := true
	fd := (c.int)(uintptr(([^]rawptr)(argv)[2]))
	hl: c.int = HLF_SO
	kind: cstring = "shell_out"
	if fd == STDERR_FILENO {
		hl = HLF_SE
		kind = "shell_err"
	}
	msg_ext_set_kind(kind)
	msg_ext_set_append(true)
	msg_ext_no_fast()
	msg_multiline(String{data = transmute(cstring)(([^]^u8)(argv)[0]), size = c.size_t(uintptr(([^]^u8)(argv)[1]))}, hl, false, false, &need_clear)
	xfree(([^]^u8)(argv)[0])
	ui_flush()
}

out_data_append_to_screen :: proc(output: ^u8, count: ^c.size_t, fd: c.int, eof: bool) {
	context = runtime.default_context()
	p := output
	end := (^u8)(uintptr(output) + uintptr(count^))
	for uintptr(p) < uintptr(end) {
		i: c.int = 1
		if p^ != 0 {
			i = utfc_ptr2len_len(p, c.int(count^) - c.int(uintptr(p) - uintptr(output)))
		}
		if !eof && i == 1 && utf8len_tab_zero[p^] > u8(uintptr(end) - uintptr(p)) {
			count^ = c.size_t(uintptr(p) - uintptr(output))
			break
		}
		p = (^u8)(uintptr(p) + uintptr(i))
	}
	str := xmemdupz(transmute(rawptr)(output), count^)
	if ui_has(kUIMessages) {
		multiqueue_put_event(main_loop.fast_events, event_create(out_data_event, transmute(rawptr)(str), transmute(rawptr)(count^), transmute(rawptr)(i64(fd))))
	} else {
		argv := ([3]rawptr){ transmute(rawptr)(str), transmute(rawptr)(count^), transmute(rawptr)(i64(fd)) }
		out_data_event(&argv[0])
	}
}

utfc_ptr2len_len :: proc(p: ^u8, len: c.int) -> c.int {
	context = runtime.default_context()
	if p == nil || len <= 0 {
		return 0
	}
	if p^ < 0x80 {
		return 1
	}
	// simplified: uses utf8len_tab_zero for leading byte
	if p^ < 0xc0 {
		return 1
	}
	l := c.int(utf8len_tab_zero[p^])
	if l == 0 {
		return 1
	}
	return l
}

out_data_cb :: proc(stream: ^RStream, ptr: ^u8, count: c.size_t, data: rawptr, eof: bool) -> c.size_t {
	context = runtime.default_context()
	if count > 0 && out_data_decide_throttle(count) {
		out_data_ring(ptr, count)
	} else if count > 0 {
		c := count
		out_data_append_to_screen(ptr, &c, stream.s.fd, eof)
	}
	return count
}

tokenize :: proc(str: cstring, argv: ^^u8) -> c.size_t {
	context = runtime.default_context()
	argc := c.size_t(0)
	p := transmute(^u8)(str)

	for p^ != 0 {
		len := word_length(p)
		if argv != nil {
			([^]^u8)(argv)[argc] = transmute(^u8)(vim_strnsave_unquoted(p, len))
		}
		argc += 1
		p = transmute(^u8)(skipwhite(transmute(cstring)((^u8)(uintptr(p) + uintptr(len)))))
	}

	return argc
}

word_length :: proc(str: ^u8) -> c.size_t {
	context = runtime.default_context()
	p := str
	inquote := false
	length := c.size_t(0)

	for p^ != 0 && (inquote || (p^ != ' ' && p^ != TAB)) {
		if p^ == '"' {
			inquote = !inquote
		} else if p^ == '\\' && inquote {
			p = (^u8)(uintptr(p) + 1)
			length += 1
		}
		p = (^u8)(uintptr(p) + 1)
		length += 1
	}

	return length
}

read_input :: proc(buf: ^StringBuilder) {
	context = runtime.default_context()
	start := curbuf_field_lnum(curbuf, 0)  // b_op_start.lnum
	end := curbuf_field_lnum(curbuf, 1)    // b_op_end.lnum
	read_buffer_into(curbuf, start, end, buf)
}

curbuf_field_lnum :: proc(b: rawptr, which: c.int) -> c.int {
	context = runtime.default_context()
	// buf_T.b_op_start at offset 7704, b_op_end at 7728 (each pos_T=8, lnum at 0)
	if which == 0 {
		return (^c.int)(uintptr(b) + 7704)^
	}
	return (^c.int)(uintptr(b) + 7728)^
}

write_output :: proc(output: ^u8, remaining: c.size_t, eof: bool) -> c.size_t {
	context = runtime.default_context()
	if output == nil {
		return 0
	}

	start := output
	off := c.size_t(0)
	rem := remaining
	o := output
	for off < rem {
		if ([^]u8)(o)[off] == CAR && ([^]u8)(o)[off+1] == NL && !curbuf_bin(curbuf) {
			([^]u8)(o)[off] = NUL
			ml_append(curwin_lnum(curwin) + 1, o, c.int(off) + 1, false)
			skip := off + 2
			o = (^u8)(uintptr(o) + uintptr(skip))
			rem -= skip
			off = 0
			set_curwin_lnum(curwin, curwin_lnum(curwin) + 1)
			continue
		} else if (([^]u8)(o)[off] == CAR && !curbuf_bin(curbuf)) || ([^]u8)(o)[off] == NL {
			([^]u8)(o)[off] = NUL
			ml_append(curwin_lnum(curwin) + 1, o, c.int(off) + 1, false)
			skip := off + 1
			o = (^u8)(uintptr(o) + uintptr(skip))
			rem -= skip
			off = 0
			set_curwin_lnum(curwin, curwin_lnum(curwin) + 1)
			continue
		}
		if ([^]u8)(o)[off] == NUL {
			([^]u8)(o)[off] = NL
		}
		off += 1
	}

	if eof {
		if rem != 0 {
			ml_append(curwin_lnum(curwin) + 1, o, 0, false)
			set_curbuf_no_eol(curbuf, curwin_lnum(curwin) + 1)
			o = (^u8)(uintptr(o) + uintptr(rem))
		} else {
			set_curbuf_no_eol(curbuf, 0)
		}
	}

	ui_flush()
	return c.size_t(uintptr(o) - uintptr(start))
}

curbuf_bin :: proc(b: rawptr) -> bool {
	context = runtime.default_context()
	// buf_T.b_p_bin at offset 10136 (bool)
	return (^bool)(uintptr(b) + 10136)^
}

curwin_lnum :: proc(w: rawptr) -> c.int {
	context = runtime.default_context()
	// win_T.w_cursor at offset 136, lnum at 0
	return (^c.int)(uintptr(w) + 136)^
}

set_curwin_lnum :: proc(w: rawptr, v: c.int) {
	context = runtime.default_context()
	(^c.int)(uintptr(w) + 136)^ = v
}

set_curbuf_no_eol :: proc(b: rawptr, v: c.int) {
	context = runtime.default_context()
	// buf_T.b_no_eol_lnum at offset 11100
	(^c.int)(uintptr(b) + 11100)^ = v
}

foreign _ {
	@(link_name = "ml_append")
	ml_append :: proc "c" (lnum: c.int, line: ^u8, len: c.int, heap: bool) -> bool ---
}

shell_write_cb :: proc(stream: ^Stream, data: rawptr, status: c.int) {
	context = runtime.default_context()
	if status != 0 {
		msg_schedule_semsg(GT(cstring("E5677: Error writing input to shell-command: %s")), uv_err_name(status))
	}
	stream_may_close(stream)
}

shell_xescape_xquote :: proc(cmd: cstring) -> ^u8 {
	context = runtime.default_context()
	if ([^]u8)(p_sxq)[0] == 0 {
		return xstrdup(transmute(^u8)(cmd))
	}

	ecmd := transmute(^u8)(cmd)
	if ([^]u8)(p_sxe)[0] != 0 && strings.compare(transmute(string)(([^]u8)(p_sxq)[0:2]), "(") == 0 {
		ecmd = transmute(^u8)(vim_strsave_escaped_ext(cmd, p_sxe, '^', false))
	}
	ecmd_len := cstr_len(ecmd)
	p_sxq_len := cstr_len(transmute(^u8)(p_sxq))
	ncmd_size := ecmd_len + p_sxq_len * 2 + 1
	ncmd := (^u8)(xmalloc(ncmd_size))

	if strings.compare(transmute(string)(([^]u8)(p_sxq)[0:2]), "(") == 0 {
		vim_snprintf(ncmd, ncmd_size, "(%s)", transmute(cstring)(ecmd))
	} else if strings.compare(transmute(string)(([^]u8)(p_sxq)[0:2]), "\"(") == 0 {
		vim_snprintf(ncmd, ncmd_size, "\"(%s)\"", transmute(cstring)(ecmd))
	} else {
		vim_snprintf(ncmd, ncmd_size, "%s%s%s", transmute(cstring)(p_sxq), transmute(cstring)(ecmd), transmute(cstring)(p_sxq))
	}

	if ecmd != transmute(^u8)(cmd) {
		xfree(transmute(rawptr)(ecmd))
	}

	return ncmd
}
