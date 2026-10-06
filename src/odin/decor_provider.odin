package main

import "base:runtime"
import C "core:c"
import "core:c/libc"

// —— decoration_provider.c port (Batch D1: mirrors + static engines) ——

foreign _ {
	@(link_name = "api_object_to_bool")
	api_object_to_bool_e :: proc "c" (obj: Api_Object, what: cstring, nil_value: bool, err: ^Api_Error) -> bool ---
	@(link_name = "hl_check_ns")
	hl_check_ns_e :: proc "c" () -> bool ---
	@(link_name = "decor_check_to_be_deleted")
	decor_check_to_be_deleted_e :: proc "c" () ---
	@(link_name = "ns_hl_active")
	ns_hl_active_g: C.int
}

KRETMULTI_O :: 3
KOBJTYPE_INTEGER_O :: 2
KOBJTYPE_ARRAY_O :: 5
KOBJTYPE_BUFFER_O :: 8
KOBJTYPE_WINDOW_O :: 9

// DecorProvider mirror (cc-probed via /tmp/opencode/probe_dp.c:
// ns@0/state@4/skip_row@8/skip_col@12/start@16/buf@20/win@24/line@28/
// range@32/end@36/hl_def@40/spell@44/conceal@48/hl_valid@52/cached@56/
// errcount@57, sizeof 60).
DecorProvider_O :: struct {
	ns_id:        u32,
	state:        C.int,
	win_skip_row: C.int,
	win_skip_col: C.int,
	redraw_start: C.int,
	redraw_buf:   C.int,
	redraw_win:   C.int,
	redraw_line:  C.int,
	redraw_range: C.int,
	redraw_end:   C.int,
	hl_def:       C.int,
	spell_nav:    C.int,
	conceal_line: C.int,
	hl_valid:     C.int,
	hl_cached:    bool,
	error_count:  u8,
	_pad:         [2]u8,
}
#assert(size_of(DecorProvider_O) == 60)
#assert(offset_of(DecorProvider_O, spell_nav) == 44)
#assert(offset_of(DecorProvider_O, error_count) == 57)

DP_STATE_ACTIVE_O :: 1
DP_STATE_WIN_DISABLED_O :: 2
DP_STATE_REDRAW_DISABLED_O :: 3
DP_STATE_DISABLED_O :: 4

// File-static decor_providers kvec (single copy; only this file touches it).
@(private = "file")
decor_providers_size_g: C.size_t = 0
@(private = "file")
decor_providers_cap_g: C.size_t = 0
@(private = "file")
decor_providers_items_g: ^DecorProvider_O = nil

dp_size_o :: proc "c" () -> C.size_t {
	context = runtime.default_context()
	return decor_providers_size_g
}

dp_item_o :: proc "c" (i: C.size_t) -> ^DecorProvider_O {
	context = runtime.default_context()
	return &([^]DecorProvider_O)(decor_providers_items_g)[i]
}

// kv_a mirror (kvec.h): grow to i+1 with roundup32 when capacity allows.
dp_grow_o :: proc "c" (i: C.size_t) -> ^DecorProvider_O {
	context = runtime.default_context()
	if decor_providers_cap_g <= i {
		decor_providers_cap_g = i + 1
		decor_providers_size_g = i + 1
		need := u32(decor_providers_cap_g)
		roundup32(&need)
		decor_providers_cap_g = C.size_t(need)
		decor_providers_items_g = (^DecorProvider_O)(xrealloc(decor_providers_items_g, C.size_t(decor_providers_cap_g) * size_of(DecorProvider_O)))
	} else if decor_providers_size_g <= i {
		decor_providers_size_g = i + 1
	}
	return &([^]DecorProvider_O)(decor_providers_items_g)[i]
}

int_obj_dp_o :: proc "c" (n: C.longlong) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = KOBJTYPE_INTEGER_O}
	(^C.longlong)(uintptr(&obj) + 8)^ = n
	return obj
}

win_obj_dp_o :: proc "c" (h: C.int) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = KOBJTYPE_WINDOW_O}
	(^C.longlong)(uintptr(&obj) + 8)^ = C.longlong(h)
	return obj
}

buf_obj_dp_o :: proc "c" (h: C.int) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = KOBJTYPE_BUFFER_O}
	(^C.longlong)(uintptr(&obj) + 8)^ = C.longlong(h)
	return obj
}

args_push_dp_o :: proc "c" (arr: ^Api_Array, val: Api_Object) {
	context = runtime.default_context()
	([^]Api_Object)(arr.items)[arr.size] = val
	arr.size += 1
}

wp_buf_dp_o :: proc "c" (wp: rawptr) -> rawptr {
	context = runtime.default_context()
	return (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
}

// —— Batch D2: invoke family (all callers rebind from C weaks) ——

@(export)
decor_providers_invoke_spell :: proc "c" (wp: rawptr, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int) {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state != DP_STATE_DISABLED_O && p.spell_nav != LUA_NOREF_O {
			items: [6]Api_Object
			args := Api_Array{size = 0, capacity = 6, items = &items[0]}
			args_push_dp_o(&args, win_obj_dp_o((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(wp_buf_dp_o(wp)) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(start_row)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(start_col)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(end_row)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(end_col)))
			decor_provider_invoke_o(C.int(i), cstring("spell"), p.spell_nav, args, true, nil)
		}
	}
}

@(export)
decor_providers_invoke_conceal_line :: proc "c" (wp: rawptr, row: C.int) -> bool {
	context = runtime.default_context()
	buf := wp_buf_dp_o(wp)
	keys := (^MarkTree_O)(uintptr(buf) + B_MARKTREE_OFF).n_keys
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state != DP_STATE_DISABLED_O && p.conceal_line != LUA_NOREF_O {
			items: [4]Api_Object
			args := Api_Array{size = 0, capacity = 4, items = &items[0]}
			args_push_dp_o(&args, win_obj_dp_o((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(buf) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(row)))
			decor_provider_invoke_o(C.int(i), cstring("conceal_line"), p.conceal_line, args, true, nil)
		}
	}
	return (^MarkTree_O)(uintptr(buf) + B_MARKTREE_OFF).n_keys > keys
}

@(export)
decor_providers_start :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state != DP_STATE_DISABLED_O && p.redraw_start != LUA_NOREF_O {
			items: [2]Api_Object
			args := Api_Array{size = 0, capacity = 2, items = &items[0]}
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(display_tick_g)))
			active := decor_provider_invoke_o(C.int(i), cstring("start"), p.redraw_start, args, true, nil)
			if active {
				dp_item_o(i).state = DP_STATE_ACTIVE_O
			} else {
				dp_item_o(i).state = DP_STATE_REDRAW_DISABLED_O
			}
		} else if p.state != DP_STATE_DISABLED_O {
			dp_item_o(i).state = DP_STATE_ACTIVE_O
		}
	}
}

@(export)
decor_providers_invoke_win :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	if decor_state_g.current_end != 0 || decor_state_g.future_begin != C.int((^Kvec_Int)(&decor_state_g.ranges_i).n) {
		libc.abort()
	}
	if dp_size_o() > 0 {
		validate_botline_win(wp)
	}
	buf := wp_buf_dp_o(wp)
	botline := (^C.int)(uintptr(wp) + W_BOTLINE_OFF)^
	line_count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	if botline > line_count {
		botline = line_count
	}
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state == DP_STATE_WIN_DISABLED_O {
			dp_item_o(i).state = DP_STATE_ACTIVE_O
		}
		p = dp_item_o(i)
		p.win_skip_row = 0
		p.win_skip_col = 0
		if p.state == DP_STATE_ACTIVE_O && p.redraw_win != LUA_NOREF_O {
			items: [4]Api_Object
			args := Api_Array{size = 0, capacity = 4, items = &items[0]}
			args_push_dp_o(&args, win_obj_dp_o((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(buf) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong((^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) - 1))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(botline) - 1))
			if !decor_provider_invoke_o(C.int(i), cstring("win"), p.redraw_win, args, true, nil) {
				dp_item_o(i).state = DP_STATE_WIN_DISABLED_O
			}
		}
	}
}

@(export)
decor_providers_invoke_line :: proc "c" (wp: rawptr, row: C.int) {
	context = runtime.default_context()
	decor_state_g.running_decor_provider = true
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state == DP_STATE_ACTIVE_O && p.redraw_line != LUA_NOREF_O {
			items: [3]Api_Object
			args := Api_Array{size = 0, capacity = 3, items = &items[0]}
			args_push_dp_o(&args, win_obj_dp_o((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(wp_buf_dp_o(wp)) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(row)))
			if !decor_provider_invoke_o(C.int(i), cstring("line"), p.redraw_line, args, true, nil) {
				dp_item_o(i).state = DP_STATE_WIN_DISABLED_O
			}
			hl_check_ns_e()
		}
	}
	decor_state_g.running_decor_provider = false
}

@(export)
decor_providers_invoke_range :: proc "c" (wp: rawptr, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int) {
	context = runtime.default_context()
	decor_state_g.running_decor_provider = true
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state == DP_STATE_ACTIVE_O && p.redraw_range != LUA_NOREF_O {
			if p.win_skip_row > end_row || (p.win_skip_row == end_row && p.win_skip_col >= end_col) {
				continue
			}
			items: [6]Api_Object
			args := Api_Array{size = 0, capacity = 6, items = &items[0]}
			args_push_dp_o(&args, win_obj_dp_o((^C.int)(uintptr(wp) + W_HANDLE_OFF)^))
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(wp_buf_dp_o(wp)) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(start_row)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(start_col)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(end_row)))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(end_col)))
			res := Api_Array{}
			status := decor_provider_invoke_o(C.int(i), cstring("range"), p.redraw_range, args, true, &res)
			// lua call might have reallocated decor_providers
			p = dp_item_o(i)
			if !status {
				p.state = DP_STATE_WIN_DISABLED_O
			} else if res.size >= 1 {
				first := ([^]Api_Object)(res.items)[0]
				if first.t == KOBJTYPE_BOOL_O {
					if !(^bool)(&first.data[0])^ {
						p.state = DP_STATE_WIN_DISABLED_O
					}
				} else if first.t == KOBJTYPE_INTEGER_O {
					row := (^C.longlong)(&first.data[0])^
					col: C.longlong = 0
					if res.size >= 2 {
						second := ([^]Api_Object)(res.items)[1]
						if second.t == KOBJTYPE_INTEGER_O {
							col = (^C.longlong)(&second.data[0])^
						}
					}
					p.win_skip_row = C.int(row)
					p.win_skip_col = C.int(col)
				}
			}
			api_free_array_e(res)
			hl_check_ns_e()
		}
	}
	decor_state_g.running_decor_provider = false
}

@(export)
decor_providers_invoke_buf :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state == DP_STATE_ACTIVE_O && p.redraw_buf != LUA_NOREF_O {
			items: [2]Api_Object
			args := Api_Array{size = 0, capacity = 2, items = &items[0]}
			args_push_dp_o(&args, buf_obj_dp_o((^C.int)(uintptr(buf) + B_HANDLE_OFF)^))
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(display_tick_g)))
			decor_provider_invoke_o(C.int(i), cstring("buf"), p.redraw_buf, args, true, nil)
		}
	}
}

@(export)
decor_providers_invoke_end :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		p := dp_item_o(i)
		if p.state != DP_STATE_DISABLED_O && p.redraw_end != LUA_NOREF_O {
			items: [1]Api_Object
			args := Api_Array{size = 0, capacity = 1, items = &items[0]}
			args_push_dp_o(&args, int_obj_dp_o(C.longlong(display_tick_g)))
			decor_provider_invoke_o(C.int(i), cstring("end"), p.redraw_end, args, true, nil)
		}
	}
	decor_check_to_be_deleted_e()
}

@(export)
decor_provider_invalidate_hl :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		dp_item_o(i).hl_cached = false
	}
	if ns_hl_active_g != 0 {
		ns_hl_active_g = -1
		hl_check_ns_e()
	}
}

// —— Batch D3: provider lifecycle ——

@(export)
get_decor_provider :: proc "c" (ns_id: C.int, force: bool) -> ^DecorProvider_O {
	context = runtime.default_context()
	if ns_id <= 0 {
		libc.abort()
	}
	n := dp_size_o()
	for i: C.size_t = 0; i < n; i += 1 {
		p := dp_item_o(i)
		if p.ns_id == u32(ns_id) {
			return p
		}
	}
	if !force {
		return nil
	}
	item := dp_grow_o(n)
	item^ = DecorProvider_O{
		ns_id        = u32(ns_id),
		state        = DP_STATE_DISABLED_O,
		redraw_start = LUA_NOREF_O,
		redraw_buf   = LUA_NOREF_O,
		redraw_win   = LUA_NOREF_O,
		redraw_line  = LUA_NOREF_O,
		redraw_range = LUA_NOREF_O,
		redraw_end   = LUA_NOREF_O,
		hl_def       = LUA_NOREF_O,
		spell_nav    = LUA_NOREF_O,
		conceal_line = -1,
	}
	return item
}

clear_ref_dp_o :: proc "c" (ref: ^C.int) {
	context = runtime.default_context()
	if ref^ != LUA_NOREF_O {
		api_free_luaref_e(ref^)
		ref^ = LUA_NOREF_O
	}
}

@(export)
decor_provider_clear :: proc "c" (p: ^DecorProvider_O) {
	context = runtime.default_context()
	if p == nil {
		return
	}
	clear_ref_dp_o(&p.redraw_start)
	clear_ref_dp_o(&p.redraw_buf)
	clear_ref_dp_o(&p.redraw_win)
	clear_ref_dp_o(&p.redraw_line)
	clear_ref_dp_o(&p.redraw_range)
	clear_ref_dp_o(&p.redraw_end)
	clear_ref_dp_o(&p.spell_nav)
	clear_ref_dp_o(&p.conceal_line)
	p.state = DP_STATE_DISABLED_O
}

@(export)
decor_free_all_mem :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < dp_size_o(); i += 1 {
		decor_provider_clear(dp_item_o(i))
	}
	xfree(decor_providers_items_g)
	decor_providers_items_g = nil
	decor_providers_size_g = 0
	decor_providers_cap_g = 0
}

decor_provider_error_o :: proc "c" (provider: ^DecorProvider_O, name: cstring, msg: cstring) {
	context = runtime.default_context()
	ns := describe_ns_e(provider.ns_id, cstring("(UNKNOWN PLUGIN)"))
	logmsg_e(4, nil, cstring("decor_provider_error"), 29, true, cstring("Error in decoration provider \"%s\" (ns=%s):\n%s"), name, ns, msg)
	msg_schedule_semsg_multiline_e(cstring("Decoration provider \"%s\" (ns=%s):\n%s"), name, ns, msg)
}

// Note we pass in a provider index as this function may cause decor_providers
// providers to be reallocated so we need to be careful with DecorProvider pointers.
decor_provider_invoke_o :: proc "c" (provider_idx: C.int, name: cstring, ref: C.int, args: Api_Array, default_true: bool, res: ^Api_Array) -> bool {
	context = runtime.default_context()
	err := Api_Error{typ = -1, msg = nil}
	textlock += 1
	mode: C.int = KRETNILBOOL_O
	if res != nil {
		mode = KRETMULTI_O
	}
	ret := nlua_call_ref_e(ref, name, args, mode, nil, rawptr(&err))
	textlock -= 1
	// We get the provider here via an index in case the above call to
	// nlua_call_ref causes decor_providers to be reallocated.
	provider := dp_item_o(C.size_t(provider_idx))
	if err.typ == -1 {
		provider.error_count = 0
		if res != nil {
			if ret.t != KOBJTYPE_ARRAY_O {
				libc.abort()
			}
			res^ = (^Api_Array)(uintptr(&ret) + 8)^
			return true
		} else {
			if api_object_to_bool_e(ret, cstring("provider %s retval"), default_true, &err) {
				return true
			}
		}
	}
	if err.typ != -1 && provider.error_count < CB_MAX_ERROR_O {
		decor_provider_error_o(provider, name, transmute(cstring)(err.msg))
		provider.error_count += 1
		if provider.error_count >= CB_MAX_ERROR_O {
			provider.state = DP_STATE_DISABLED_O
		}
	}
	api_clear_error_r(&err)
	api_free_object_r(ret)
	return false
}
