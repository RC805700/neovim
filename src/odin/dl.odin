package main

import "base:runtime"
import "core:c"
import "core:dynlib"

foreign _ {
	@(link_name = "xstrdup")
	_xstrdup :: proc "c" (s: cstring) -> cstring ---
}

@(export)
os_libcall :: proc "c" (libname, funcname: cstring, argv: cstring, argi: c.int, str_out: ^cstring, int_out: ^c.int) -> bool {
	context = runtime.default_context()

	if libname == nil || funcname == nil {
		return false
	}

	lib, lib_ok := dynlib.load_library(string(libname))
	if !lib_ok {
		return false
	}
	defer dynlib.unload_library(lib)

	fn, fn_ok := dynlib.symbol_address(lib, string(funcname))
	if !fn_ok {
		return false
	}

	if str_out != nil {
		sfn := (proc "c" (s: cstring) -> cstring)(fn)
		ifn := (proc "c" (i: c.int) -> cstring)(fn)
		res: cstring
		if argv != nil {
			res = sfn(argv)
		} else {
			res = ifn(argi)
		}
		addr := uintptr(rawptr(res))
		if addr != 0 && addr != 1 && addr != ~uintptr(0) {
			str_out^ = _xstrdup(res)
		} else {
			str_out^ = nil
		}
	} else {
		sfn := (proc "c" (s: cstring) -> c.int)(fn)
		ifn := (proc "c" (i: c.int) -> c.int)(fn)
		if argv != nil {
			int_out^ = sfn(argv)
		} else {
			int_out^ = ifn(argi)
		}
	}

	return true
}
