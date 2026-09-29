package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// clipboard.c port: clipboard provider integration (*name adjustment,
// get/set via eval_call_provider, batch-change deferral).
// All 5 publics are @(export); batch counters are file-privates.

foreign _ {
	@(link_name = "cb_flags")
	cb_flags: C.uint
}

KOPT_CB_UNNAMED_O :: 0x01
KOPT_CB_UNNAMEDPLUS_O :: 0x02

MSG_NO_CLIP_S :: "clipboard: No provider. Try \":checkhealth\" or \":h clipboard\"."

@(private = "file")
batch_change_count_g: C.int
@(private = "file")
clipboard_delay_update_g: bool
@(private = "file")
clipboard_needs_update_g: bool
@(private = "file")
clipboard_didwarn_g: bool

// Which yankreg to use for register *name (NULL when not a clipboard).
@(export)
adjust_clipboard_name :: proc "c" (name: ^C.int, quiet: bool, writing: bool) -> ^Yankreg_T {
	context = runtime.default_context()
	target: ^Yankreg_T = nil
	explicit_cb_reg := name^ == '*' || name^ == '+'
	implicit_cb_reg := name^ == 0 && (cb_flags & (KOPT_CB_UNNAMED_O | KOPT_CB_UNNAMEDPLUS_O)) != 0
	if !explicit_cb_reg && !implicit_cb_reg {
		return target
	}
	if !eval_has_provider(cstring("clipboard"), false) {
		if batch_change_count_g <= 1 && !quiet && (!clipboard_didwarn_g || (explicit_cb_reg && redirecting_e() == 0)) {
			clipboard_didwarn_g = true
			msg_msg(cstring(MSG_NO_CLIP_S), 0)
		}
		return target
	}
	if explicit_cb_reg {
		if name^ == '*' {
			target = get_y_register(STAR_REGISTER)
		} else {
			target = get_y_register(PLUS_REGISTER)
		}
		if writing {
			flag: C.uint = KOPT_CB_UNNAMED_O
			if name^ != '*' {
				flag = KOPT_CB_UNNAMEDPLUS_O
			}
			if (cb_flags & flag) != 0 {
				clipboard_needs_update_g = false
			}
		}
		return target
	}
	if writing && clipboard_delay_update_g {
		clipboard_needs_update_g = true
		return target
	} else if !writing && clipboard_needs_update_g {
		return target
	}
	if (cb_flags & KOPT_CB_UNNAMEDPLUS_O) != 0 {
		if (cb_flags & KOPT_CB_UNNAMED_O) != 0 && writing {
			name^ = '"'
		} else {
			name^ = '+'
		}
		target = get_y_register(PLUS_REGISTER)
	} else {
		name^ = '*'
		target = get_y_register(STAR_REGISTER)
	}
	return target
}

@(export)
get_clipboard :: proc "c" (name: C.int, target: ^^Yankreg_T, quiet: bool) -> bool {
	context = runtime.default_context()
	errmsg := true
	nm := name
	reg := adjust_clipboard_name(&nm, quiet, false)
	if reg == nil {
		return false
	}
	free_register(reg)
	args := tv_list_alloc(1)
	regname: u8 = u8(nm)
	tv_list_append_string(args, &regname, 1)
	result := eval_call_provider(cstring("clipboard"), cstring("get"), args, false)
	if result.v_type != VAR_LIST {
		if result.v_type == VAR_NUMBER && transmute(C.longlong)(result.vval) == 0 {
			errmsg = false
		}
		free_clipboard_err_o(reg, errmsg)
		target^ = reg
		return false
	}
	res := rawptr(result.vval)
	lines: rawptr = nil
	pair := false
	if tv_list_len_o(res) == 2 {
		if (^Typval_T)(uintptr(tv_list_first_o(res)) + 16).v_type == VAR_LIST {
			pair = true
		}
	}
	if pair {
		first := (^Typval_T)(uintptr(tv_list_first_o(res)) + 16)
		last := (^Typval_T)(uintptr(tv_list_last_o(res)) + 16)
		lines = rawptr(first.vval)
		if last.v_type != VAR_STRING {
			free_clipboard_err_o(reg, errmsg)
			target^ = reg
			return false
		}
		regtype := transmute(cstring)(last.vval)
		if regtype == nil || libc.strlen(regtype) > 1 {
			free_clipboard_err_o(reg, errmsg)
			target^ = reg
			return false
		}
		c0 := ([^]u8)(rawptr(regtype))[0]
		if c0 == 0 {
			reg.y_type = kMTUnknown
		} else if c0 == 'v' || c0 == 'c' {
			reg.y_type = kMTCharWise
		} else if c0 == 'V' || c0 == 'l' {
			reg.y_type = kMTLineWise
		} else if c0 == 'b' || c0 == u8(Ctrl_V) {
			reg.y_type = kMTBlockWise
		} else {
			free_clipboard_err_o(reg, errmsg)
			target^ = reg
			return false
		}
	} else {
		lines = res
		reg.y_type = kMTUnknown
	}
	reg.y_array = ([^]Str16)(xcalloc(C.size_t(tv_list_len_o(lines)), C.size_t(size_of(Str16))))
	reg.y_size = C.size_t(tv_list_len_o(lines))
	reg.y_width = 0
	reg.additional_data = nil
	reg.timestamp = 0
	tv_idx: C.size_t = 0
	it := (^rawptr)(lines)^
	fail := false
	for it != nil {
		li := (^ListItem)(it)
		tv := (^Typval_T)(uintptr(li) + 16)
		if tv.v_type != VAR_STRING {
			fail = true
			break
		}
		s := transmute(cstring)(tv.vval)
		if s == nil {
			s = cstring("")
		}
		reg.y_array[tv_idx] = cstr_to_string_r(s)
		tv_idx += 1
		it = li.li_next
	}
	if fail {
		free_clipboard_err_o(reg, errmsg)
		target^ = reg
		return false
	}
	if reg.y_size > 0 && reg.y_array[reg.y_size - 1].size == 0 {
		if reg.y_type != kMTCharWise {
			xfree(rawptr(reg.y_array[reg.y_size - 1].data))
			reg.y_size -= 1
			if reg.y_type == kMTUnknown {
				reg.y_type = kMTLineWise
			}
		}
	} else {
		if reg.y_type == kMTUnknown {
			reg.y_type = kMTCharWise
		}
	}
	update_yankreg_width(reg)
	target^ = reg
	return true
}

// Error epilogue shared by get_clipboard's failure arms.
free_clipboard_err_o :: proc "c" (reg: ^Yankreg_T, errmsg: bool) {
	context = runtime.default_context()
	if reg.y_array != nil {
		for i: C.size_t = 0; i < reg.y_size; i += 1 {
			xfree(rawptr(reg.y_array[i].data))
		}
		xfree(rawptr(reg.y_array))
	}
	reg.y_array = nil
	reg.y_size = 0
	reg.additional_data = nil
	reg.timestamp = 0
	if errmsg {
		emsg(cstring("clipboard: provider returned invalid data"))
	}
}

@(export)
set_clipboard :: proc "c" (name: C.int, reg: ^Yankreg_T) {
	context = runtime.default_context()
	nm := name
	if adjust_clipboard_name(&nm, false, true) == nil {
		return
	}
	extra: C.ssize_t = 0
	if reg.y_type != kMTCharWise {
		extra = 1
	}
	lines := tv_list_alloc(C.ssize_t(reg.y_size) + extra)
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		tv_list_append_string(lines, reg.y_array[i].data, C.ssize_t(reg.y_array[i].size))
	}
	regtype: u8
	if reg.y_type == kMTLineWise {
		regtype = 'V'
		tv_list_append_string(lines, nil, 0)
	} else if reg.y_type == kMTCharWise {
		regtype = 'v'
	} else if reg.y_type == kMTBlockWise {
		regtype = 'b'
		tv_list_append_string(lines, nil, 0)
	} else {
		libc.abort()
	}
	args := tv_list_alloc(3)
	tv_list_append_list(args, lines)
	tv_list_append_string(args, &regtype, 1)
	nmbyte: u8 = u8(nm)
	tv_list_append_string(args, &nmbyte, 1)
	eval_call_provider(cstring("clipboard"), cstring("set"), args, true)
}

// Defer slow clipboard updates during batch operations.
@(export)
start_batch_changes :: proc "c" () {
	context = runtime.default_context()
	batch_change_count_g += 1
	if batch_change_count_g > 1 {
		return
	}
	clipboard_delay_update_g = true
}

// Counterpart to start_batch_changes.
@(export)
end_batch_changes :: proc "c" () {
	context = runtime.default_context()
	batch_change_count_g -= 1
	if batch_change_count_g > 0 {
		return
	}
	clipboard_delay_update_g = false
	if clipboard_needs_update_g {
		clipboard_needs_update_g = false
		set_clipboard(0, get_y_previous())
	}
}
