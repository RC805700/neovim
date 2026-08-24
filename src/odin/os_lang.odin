package main

// Port of src/nvim/os/lang.c to Odin.
//
// Linux-only (MSWin / __APPLE__ branches dropped). Locale functions back onto
// libc `setlocale`/POSIX and FFI to the handful of C internals the originals
// touched (vim variables, gettext setup, shell command output).
//
// Reuses declarations already present in other Odin files:
//   - main.odin:  set_vim_var_string, get_vim_var_str, setlocale,
//                 LC_* constants, VV_* constants, set_lang_var (full impl)
//   - os_env.odin: os_env_exists, os_setenv
//   - os_env_b.odin: expand_T, _uptr
//   - log.odin: MAXPATHL
//   - time.odin: tz_cache

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Locale category constants (from <locale.h>); LC_CTYPE/LC_TIME/LC_COLLATE/
// LC_MESSAGES are declared in main.odin.
LC_ALL     :: 6
LC_NUMERIC :: 1

// VV_* constants (VV_LANG/VV_LC_TIME/VV_CTYPE/VV_COLLATE/VV_PROGPATH) are
// declared in main.odin with their correct C enum values; set_lang_var reuses
// them. set_vim_var_string() indexes vimvars[] by these values.

// exarg_T — only the fields lang.c touches.
exarg_T :: struct {
	arg: cstring,
	cmd: cstring,
}

foreign _ {
	@(link_name = "strtok_r")
	strtok_r :: proc(str: cstring, delim: cstring, saveptr: ^cstring) -> cstring ---

	@(link_name = "strncasecmp")
	strncasecmp :: proc(s1: cstring, s2: cstring, n: c.size_t) -> c.int ---

	@(link_name = "malloc")
	malloc :: proc(size: c.size_t) -> rawptr ---

	@(link_name = "strdup")
	strdup :: proc(s: cstring) -> cstring ---

	// set_helplang_default — PORTED to Odin (option.odin)

	@(link_name = "maketitle")
	maketitle :: proc() ---

	@(link_name = "skiptowhite")
	skiptowhite :: proc(p: cstring) -> cstring ---

	@(link_name = "path_tail")
	path_tail :: proc(fname: cstring) -> cstring ---

	@(link_name = "path_tail_with_sep")
	path_tail_with_sep :: proc(fname: cstring) -> cstring ---

	@(link_name = "xstrlcpy")
	xstrlcpy :: proc(dst: cstring, src: cstring, dsize: c.size_t) -> c.size_t ---

	@(link_name = "bindtextdomain")
	bindtextdomain :: proc(domainname: cstring, dirname: cstring) -> cstring ---

	@(link_name = "textdomain")
	textdomain :: proc(domainname: cstring) -> cstring ---
}

// Locales cache (was static in lang.c; now owned by the Odin port).
did_init_locales: bool
locales: ^cstring

kShellOptSilent :: c.int(8)

PROJECT_NAME :: "nvim"

@(private)
get_locale_val :: proc(what: c.int) -> cstring {
	context = runtime.default_context()
	return setlocale(what, nil)
}

@(private)
is_valid_mess_lang :: proc(lang: cstring) -> bool {
	context = runtime.default_context()
	if lang == nil {
		return false
	}
	b := ([^]u8)(_uptr(lang))
	return ASCII_ISALPHA(b[0]) && ASCII_ISALPHA(b[1])
}

@(private)
get_mess_env :: proc() -> cstring {
	context = runtime.default_context()
	// Mirrors C's `#ifdef LC_MESSAGES` branch: return the locale string
	// directly (no validity filtering — that is get_mess_lang's job).
	return get_locale_val(LC_MESSAGES)
}

@(private)
ASCII_ISALPHA :: proc(c: u8) -> bool {
	context = runtime.default_context()
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

@(private)
ascii_isdigit :: proc "c" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
ascii_iswhite :: proc "c" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0b || c == 0x0c
}

@(private)
skipwhite :: proc "c" (p: cstring) -> cstring {
	cur := p
	b := ([^]u8)(_uptr(cur))
	for b[0] != 0 && ascii_iswhite(b[0]) {
		cur = transmute(cstring)(_uptr(cur) + 1)
		b = ([^]u8)(_uptr(cur))
	}
	return cur
}

@(private)
os_strtok :: proc(str: cstring, delim: cstring, saveptr: ^cstring) -> cstring {
	context = runtime.default_context()
	return strtok_r(str, delim, saveptr)
}

@(export)
get_mess_lang :: proc "c" () -> cstring {
	context = runtime.default_context()
	p := get_locale_val(LC_MESSAGES)
	if is_valid_mess_lang(p) {
		return p
	}
	return nil
}

@(export)
set_lang_var :: proc "c" () {
	context = runtime.default_context()
	loc := get_locale_val(LC_CTYPE)
	set_vim_var_string(VV_CTYPE, loc, -1)

	loc = get_mess_env()
	set_vim_var_string(VV_LANG, loc, -1)

	loc = get_locale_val(LC_TIME)
	set_vim_var_string(VV_LC_TIME, loc, -1)

	loc = get_locale_val(LC_COLLATE)
	set_vim_var_string(VV_COLLATE, loc, -1)
}

@(export)
init_locale :: proc "c" () {
	context = runtime.default_context()
	setlocale(LC_ALL, cstring(""))
	setlocale(LC_NUMERIC, cstring("C"))

	localepath: [MAXPATHL]u8 = {}
	xstrlcpy(cstring(&localepath[0]), get_vim_var_str(VV_PROGPATH), MAXPATHL)

	tail := path_tail_with_sep(cstring(&localepath[0]))
	([^]u8)(_uptr(tail))[0] = 0
	tail = path_tail(cstring(&localepath[0]))
	xstrlcpy(tail, cstring("share/locale"), MAXPATHL - c.size_t(_uptr(tail) - _uptr(cstring(&localepath[0]))))

	bindtextdomain(cstring(PROJECT_NAME), cstring(&localepath[0]))
	textdomain(cstring(PROJECT_NAME))
}

@(export)
ex_language :: proc "c" (eap: ^exarg_T) {
	context = runtime.default_context()
	VIM_LC_MESSAGES: c.int = LC_MESSAGES
	what: c.int = LC_ALL
	whatstr := cstring("")
	name := eap.arg

	p := skiptowhite(eap.arg)
	pb := ([^]u8)(_uptr(p))
	if (pb[0] == 0 || ascii_iswhite(pb[0])) && (_uptr(p) - _uptr(eap.arg)) >= 3 {
		alen := c.size_t(_uptr(p) - _uptr(eap.arg))
		if strncasecmp(eap.arg, cstring("messages"), alen) == 0 {
			what = VIM_LC_MESSAGES
			name = skipwhite(p)
			whatstr = cstring("messages ")
		} else if strncasecmp(eap.arg, cstring("ctype"), alen) == 0 {
			what = LC_CTYPE
			name = skipwhite(p)
			whatstr = cstring("ctype ")
		} else if strncasecmp(eap.arg, cstring("time"), alen) == 0 {
			what = LC_TIME
			name = skipwhite(p)
			whatstr = cstring("time ")
		} else if strncasecmp(eap.arg, cstring("collate"), alen) == 0 {
			what = LC_COLLATE
			name = skipwhite(p)
			whatstr = cstring("collate ")
		}
	}

	if ([^]u8)(_uptr(name))[0] == 0 {
		if what == VIM_LC_MESSAGES {
			p = get_mess_env()
		} else {
			p = setlocale(what, nil)
		}
		if p == nil || ([^]u8)(_uptr(p))[0] == 0 {
			p = cstring("Unknown")
		}
		buf: [256]u8 = {}
		libc.snprintf(&buf[0], 256, cstring("Current %slanguage: \"%s\""), rawptr(whatstr), rawptr(p))
		emsg(cstring(&buf[0]))
	} else {
		loc := setlocale(what, name)
		setlocale(LC_NUMERIC, cstring("C"))
		if loc == nil {
			buf: [256]u8 = {}
			libc.snprintf(&buf[0], 256, cstring("E197: Cannot set language to \"%s\""), rawptr(name))
			emsg(cstring(&buf[0]))
		} else {
			os_setenv(cstring("LC_ALL"), cstring(""), 1)
			if what != LC_TIME && what != LC_COLLATE {
				if what == LC_ALL {
					os_setenv(cstring("LANG"), name, 1)
					os_setenv(cstring("LANGUAGE"), cstring(""), 1)
				}
				if what != LC_CTYPE {
					os_setenv(cstring("LC_MESSAGES"), name, 1)
					set_helplang_default(transmute(^u8)(name))
				}
			}
			set_lang_var()
			maketitle()
		}
	}
}

@(private)
find_locales :: proc() -> ^cstring {
	context = runtime.default_context()
	locale_a := get_cmd_output(cstring("locale -a"), nil, kShellOptSilent, nil)
	if locale_a == nil {
		return nil
	}

	count := 0
	cap := 20
	data := ([^]cstring)(malloc(c.size_t(cap) * c.size_t(size_of(cstring))))
	saveptr: cstring = nil
	loc := os_strtok(locale_a, cstring("\n"), &saveptr)
	for loc != nil {
		if count >= cap {
			cap *= 2
			newdata := ([^]cstring)(malloc(c.size_t(cap) * c.size_t(size_of(cstring))))
			for k in 0 ..< count {
				newdata[k] = data[k]
			}
			libc.free(rawptr(data))
			data = newdata
		}
		data[count] = strdup(loc)
		count += 1
		loc = os_strtok(nil, cstring("\n"), &saveptr)
	}
	xfree(rawptr(locale_a))

	data[count] = nil
	return data
}

@(private)
init_locales :: proc() {
	context = runtime.default_context()
	if did_init_locales {
		return
	}
	did_init_locales = true
	locales = find_locales()
}

@(export)
free_locales :: proc "c" () {
	context = runtime.default_context()
	if locales == nil {
		return
	}
	i := 0
	arr := ([^]cstring)(locales)
	for arr[i] != nil {
		libc.free(rawptr(arr[i]))
		i += 1
	}
	libc.free(rawptr(locales))
	locales = nil
}

@(export)
get_lang_arg :: proc "c" (xp: ^expand_T, idx: c.int) -> cstring {
	context = runtime.default_context()
	if idx == 0 {
		return cstring("messages")
	}
	if idx == 1 {
		return cstring("ctype")
	}
	if idx == 2 {
		return cstring("time")
	}
	if idx == 3 {
		return cstring("collate")
	}
	init_locales()
	if locales == nil {
		return nil
	}
	return ([^]cstring)(locales)[idx - 4]
}

@(export)
get_locales :: proc "c" (xp: ^expand_T, idx: c.int) -> cstring {
	context = runtime.default_context()
	init_locales()
	if locales == nil {
		return nil
	}
	return ([^]cstring)(locales)[idx]
}

@(export)
lang_init :: proc "c" () {
	context = runtime.default_context()
	// __APPLE__ branch dropped (Linux-only build).
}
