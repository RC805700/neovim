package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// buffer_updates.c port: buffer change notification (channels + lua).
// All 11 exports; C file moved to bak/buffer_updates.c.

// B_HANDLE/B_ML_MFP/B_ML_LINE_COUNT/B_UPDATE_* offsets live in
// buffer.odin/eval.odin/mark.odin (values match the cc-probe).
B_UPDATE_NEED_CP_OFF :: 12712

LUA_INTERNAL_CALL_O :: u64(0x8000000000000001)

BufUpdateCallbacks_T :: struct {
	on_lines:      C.int,  // @0 (LuaRef)
	on_bytes:      C.int,  // @4
	on_changedtick: C.int,  // @8
	on_detach:     C.int,  // @12
	on_reload:     C.int,  // @16
	utf_sizes:     bool,  // @20
	preview:       bool,  // @21
	_pad:          [2]u8,  // @22
}
#assert(size_of(BufUpdateCallbacks_T) == 24)

foreign _ {
	@(link_name = "buf_collect_lines")
	buf_collect_lines_e :: proc "c" (buf: rawptr, n: C.size_t, start: C.int, start_idx: C.int, replace_nl: bool, l: rawptr, lstate: rawptr, arena: rawptr) ---
	// arena_array_e lives in cursor_shape.odin — reuse directly.
	// ml_flush_deleted_bytes is defined in memline.odin — call directly.
	// cmdpreview_g lives in optionstr.odin — reuse directly.
}

// kvec accessors over raw buffer slots.
uchans_size_o :: proc "c" (buf: rawptr) -> C.size_t {
	context = runtime.default_context()
	return (^C.size_t)(uintptr(buf) + B_UPDATE_CHANNELS_OFF)^
}
uchans_item_o :: proc "c" (buf: rawptr, i: C.size_t) -> u64 {
	context = runtime.default_context()
	return ([^]u64)((^rawptr)(uintptr(buf) + B_UPDATE_CHANNELS_OFF + 16)^)[i]
}
uchans_push_o :: proc "c" (buf: rawptr, id: u64) {
	context = runtime.default_context()
	base := uintptr(buf) + B_UPDATE_CHANNELS_OFF
	size := (^C.size_t)(base)^
	cap := (^C.size_t)(base + 8)^
	if size == cap {
		if cap == 0 {
			cap = 8
		} else {
			cap *= 2
		}
		(^C.size_t)(base + 8)^ = cap
		(^rawptr)(base + 16)^ = xrealloc((^rawptr)(base + 16)^, C.size_t(cap)*8)
	}
	([^]u64)((^rawptr)(base + 16)^)[size] = id
	(^C.size_t)(base)^ = size + 1
}
ucb_size_o :: proc "c" (buf: rawptr) -> C.size_t {
	context = runtime.default_context()
	return (^C.size_t)(uintptr(buf) + B_UPDATE_CALLBACKS_OFF)^
}
ucb_at_o :: proc "c" (buf: rawptr, i: C.size_t) -> ^BufUpdateCallbacks_T {
	context = runtime.default_context()
	return &([^]BufUpdateCallbacks_T)((^rawptr)(uintptr(buf) + B_UPDATE_CALLBACKS_OFF + 16)^)[i]
}
ucb_push_o :: proc "c" (buf: rawptr, cb: BufUpdateCallbacks_T) {
	context = runtime.default_context()
	base := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	size := (^C.size_t)(base)^
	cap := (^C.size_t)(base + 8)^
	if size == cap {
		if cap == 0 {
			cap = 8
		} else {
			cap *= 2
		}
		(^C.size_t)(base + 8)^ = cap
		(^rawptr)(base + 16)^ = xrealloc((^rawptr)(base + 16)^, C.size_t(cap)*size_of(BufUpdateCallbacks_T))
	}
	([^]BufUpdateCallbacks_T)((^rawptr)(base + 16)^)[size] = cb
	(^C.size_t)(base)^ = size + 1
}

// Api object constructors (C OBJ macro equivalents).
int_obj_bu_o :: proc "c" (n: C.longlong) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 2}
	(^C.longlong)(uintptr(&obj) + 8)^ = n
	return obj
}
bool_obj_bu_o :: proc "c" (b: bool) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 1}
	if b {
		([^]u8)(uintptr(&obj) + 8)[0] = 1
	} else {
		([^]u8)(uintptr(&obj) + 8)[0] = 0
	}
	return obj
}
nil_obj_bu_o :: proc "c" () -> Api_Object {
	context = runtime.default_context()
	return Api_Object{t = 0}
}
arr_obj_bu_o :: proc "c" (arr: Api_Array) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 5}
	(^Api_Array)(uintptr(&obj) + 8)^ = arr
	return obj
}
luaret_truthy_o :: proc "c" (res: ^Api_Object) -> bool {
	context = runtime.default_context()
	return res.t == 1 && ([^]u8)(uintptr(res) + 8)[0] != 0
}

// Stack arg array (MAXSIZE_TEMP_ARRAY equivalent, pre-sized).
Arg_Buf_O :: 11
arg_add_o :: proc(arr: ^Api_Array, val: Api_Object) {
	([^]Api_Object)(arr.items)[arr.size] = val
	arr.size += 1
}

// Channel/callback registration (buffer_updates.c public).
@(export)
buf_updates_register :: proc "c" (buf: rawptr, channel_id: u64, cb_in: BufUpdateCallbacks_T, send_buffer: bool) -> bool {
	context = runtime.default_context()
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
		return false
	}
	if channel_id == LUA_INTERNAL_CALL_O {
		ucb_push_o(buf, cb_in)
		if cb_in.utf_sizes {
			([^]u8)(uintptr(buf) + B_UPDATE_NEED_CP_OFF)[0] = 1
		}
		return true
	}
	n := uchans_size_o(buf)
	for i: C.size_t = 0; i < n; i += 1 {
		if uchans_item_o(buf, i) == channel_id {
			return true
		}
	}
	uchans_push_o(buf, channel_id)
	if send_buffer {
		items: [6]Api_Object
		args := Api_Array{size = 0, capacity = 6, items = &items[0]}
		arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
		arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
		arg_add_o(&args, int_obj_bu_o(0))
		arg_add_o(&args, int_obj_bu_o(-1))
		arena: Arena_O
		libc.memset(rawptr(&arena), 0, C.size_t(size_of(Arena_O)))
		line_count := C.size_t((^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^)
		linedata := Api_Array{size = 0, capacity = 0, items = nil}
		if line_count > 0 {
			linedata = arena_array_e(rawptr(&arena), line_count)
			buf_collect_lines_e(buf, line_count, 1, 0, true, rawptr(&linedata), nil, rawptr(&arena))
		}
		arg_add_o(&args, arr_obj_bu_o(linedata))
		arg_add_o(&args, bool_obj_bu_o(false))
		rpc_send_event_e(C.ulonglong(channel_id), cstring("nvim_buf_lines_event"), args)
		arena_mem_free(arena_finish(rawptr(&arena)))
	} else {
		buf_updates_changedtick_single(buf, channel_id)
	}
	return true
}

// Watcher presence test (buffer_updates.c public).
@(export)
buf_updates_active :: proc "c" (buf: rawptr) -> bool {
	context = runtime.default_context()
	return uchans_size_o(buf) != 0 || ucb_size_o(buf) != 0
}

// Detach notifier (buffer_updates.c public).
@(export)
buf_updates_send_end :: proc "c" (buf: rawptr, channelid: u64) {
	context = runtime.default_context()
	items: [1]Api_Object
	args := Api_Array{size = 0, capacity = 1, items = &items[0]}
	arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
	rpc_send_event_e(C.ulonglong(channelid), cstring("nvim_buf_detach_event"), args)
}

// Channel unregistrar (buffer_updates.c public).
@(export)
buf_updates_unregister :: proc "c" (buf: rawptr, channelid: u64) {
	context = runtime.default_context()
	size := uchans_size_o(buf)
	if size == 0 {
		return
	}
	j: C.size_t = 0
	found: C.size_t = 0
	base := uintptr(buf) + B_UPDATE_CHANNELS_OFF
	arr := ([^]u64)((^rawptr)(base + 16)^)
	for i: C.size_t = 0; i < size; i += 1 {
		if arr[i] == channelid {
			found += 1
		} else {
			if i != j {
				arr[j] = arr[i]
			}
			j += 1
		}
	}
	if found != 0 {
		(^C.size_t)(base)^ -= found
		buf_updates_send_end(buf, channelid)
		if found == size {
			xfree((^rawptr)(base + 16)^)
			(^C.size_t)(base)^ = 0
			(^C.size_t)(base + 8)^ = 0
			(^rawptr)(base + 16)^ = nil
		}
	}
}

// Callback vector clearer (buffer_updates.c public).
@(export)
buf_free_callbacks :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	cbase := uintptr(buf) + B_UPDATE_CHANNELS_OFF
	xfree((^rawptr)(cbase + 16)^)
	(^C.size_t)(cbase)^ = 0
	(^C.size_t)(cbase + 8)^ = 0
	(^rawptr)(cbase + 16)^ = nil
	bbase := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	barr := ([^]BufUpdateCallbacks_T)((^rawptr)(bbase + 16)^)
	for i: C.size_t = 0; i < (^C.size_t)(bbase)^; i += 1 {
		buffer_update_callbacks_free(barr[i])
	}
	xfree((^rawptr)(bbase + 16)^)
	(^C.size_t)(bbase)^ = 0
	(^C.size_t)(bbase + 8)^ = 0
	(^rawptr)(bbase + 16)^ = nil
}

// Unload notifier with reload retention (buffer_updates.c public).
@(export)
buf_updates_unload :: proc "c" (buf: rawptr, can_reload: bool) {
	context = runtime.default_context()
	size := uchans_size_o(buf)
	if size != 0 {
		for i: C.size_t = 0; i < size; i += 1 {
			buf_updates_send_end(buf, uchans_item_o(buf, i))
		}
		cbase := uintptr(buf) + B_UPDATE_CHANNELS_OFF
		xfree((^rawptr)(cbase + 16)^)
		(^C.size_t)(cbase)^ = 0
		(^C.size_t)(cbase + 8)^ = 0
		(^rawptr)(cbase + 16)^ = nil
	}
	bbase := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	j: C.size_t = 0
	n := (^C.size_t)(bbase)^
	for i: C.size_t = 0; i < n; i += 1 {
		cb := ucb_at_o(buf, i)^
		thecb: C.int = LUA_NOREF_O
		keep := false
		if can_reload && cb.on_reload != LUA_NOREF_O {
			keep = true
			thecb = cb.on_reload
		} else if cb.on_detach != LUA_NOREF_O {
			thecb = cb.on_detach
		}
		if thecb != LUA_NOREF_O {
			items: [1]Api_Object
			args := Api_Array{size = 0, capacity = 1, items = &items[0]}
			arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
			textlock += 1
			evname := cstring("detach")
			if keep {
				evname = cstring("reload")
			}
			nlua_call_ref_e(thecb, evname, args, KRETNILBOOL_O, nil, nil)
			textlock -= 1
		}
		if keep {
			ucb_at_o(buf, j)^ = ucb_at_o(buf, i)^
			j += 1
		} else {
			buffer_update_callbacks_free(cb)
		}
	}
	(^C.size_t)(bbase)^ = j
	if (^C.size_t)(bbase)^ == 0 {
		xfree((^rawptr)(bbase + 16)^)
		(^C.size_t)(bbase)^ = 0
		(^C.size_t)(bbase + 8)^ = 0
		(^rawptr)(bbase + 16)^ = nil
	}
}

// Change notifier (buffer_updates.c public).
@(export)
buf_updates_send_changes :: proc "c" (buf: rawptr, firstline: C.int, num_added: C.longlong, num_removed: C.longlong) {
	context = runtime.default_context()
	codepoints: C.size_t = 0
	codeunits: C.size_t = 0
	deleted_bytes := ml_flush_deleted_bytes(buf, &codepoints, &codeunits)
	if !buf_updates_active(buf) {
		return
	}
	send_tick := !(cmdpreview_g && buf == curbuf)
	badchannelid: u64 = 0
	arena: Arena_O
	libc.memset(rawptr(&arena), 0, C.size_t(size_of(Arena_O)))
	linedata := Api_Array{size = 0, capacity = 0, items = nil}
	if num_added > 0 && uchans_size_o(buf) != 0 {
		linedata = arena_array_e(rawptr(&arena), C.size_t(num_added))
		buf_collect_lines_e(buf, C.size_t(num_added), firstline, 0, true, rawptr(&linedata), nil, rawptr(&arena))
	}
	n := uchans_size_o(buf)
	for i: C.size_t = 0; i < n; i += 1 {
		channelid := uchans_item_o(buf, i)
		items: [6]Api_Object
		args := Api_Array{size = 0, capacity = 6, items = &items[0]}
		arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
		if send_tick {
			arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
		} else {
			arg_add_o(&args, nil_obj_bu_o())
		}
		arg_add_o(&args, int_obj_bu_o(C.longlong(firstline) - 1))
		arg_add_o(&args, int_obj_bu_o(C.longlong(firstline) - 1 + C.longlong(num_removed)))
		arg_add_o(&args, arr_obj_bu_o(linedata))
		arg_add_o(&args, bool_obj_bu_o(false))
		if !rpc_send_event_e(C.ulonglong(channelid), cstring("nvim_buf_lines_event"), args) {
			badchannelid = channelid
		}
	}
	if badchannelid != 0 {
		logmsg_e(4, nil, cstring("buf_updates_send_changes"), 258, true, cstring("Disabling buffer updates for dead channel %llu"), badchannelid)
		buf_updates_unregister(buf, badchannelid)
	}
	arena_mem_free(arena_finish(rawptr(&arena)))
	bbase := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	j: C.size_t = 0
	m := (^C.size_t)(bbase)^
	for i: C.size_t = 0; i < m; i += 1 {
		cb := ucb_at_o(buf, i)^
		keep := true
		if cb.on_lines != LUA_NOREF_O && (cb.preview || !cmdpreview_g) {
			items: [8]Api_Object
			args := Api_Array{size = 0, capacity = 8, items = &items[0]}
			arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
			if send_tick {
				arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
			} else {
				arg_add_o(&args, nil_obj_bu_o())
			}
			arg_add_o(&args, int_obj_bu_o(C.longlong(firstline) - 1))
			arg_add_o(&args, int_obj_bu_o(C.longlong(firstline) - 1 + C.longlong(num_removed)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(firstline) - 1 + C.longlong(num_added)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(deleted_bytes)))
			if cb.utf_sizes {
				arg_add_o(&args, int_obj_bu_o(C.longlong(codepoints)))
				arg_add_o(&args, int_obj_bu_o(C.longlong(codeunits)))
			}
			textlock += 1
			res := nlua_call_ref_e(cb.on_lines, cstring("lines"), args, KRETNILBOOL_O, nil, nil)
			textlock -= 1
			if luaret_truthy_o(&res) {
				buffer_update_callbacks_free(cb)
				keep = false
			}
		}
		if keep {
			ucb_at_o(buf, j)^ = ucb_at_o(buf, i)^
			j += 1
		}
	}
	(^C.size_t)(bbase)^ = j
}

// Splice notifier (buffer_updates.c public).
@(export)
buf_updates_send_splice :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, start_byte: C.longlong, old_row: C.int, old_col: C.int, old_byte: C.longlong, new_row: C.int, new_col: C.int, new_byte: C.longlong) {
	context = runtime.default_context()
	if !buf_updates_active(buf) || (old_byte == 0 && new_byte == 0) {
		return
	}
	bbase := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	j: C.size_t = 0
	m := (^C.size_t)(bbase)^
	for i: C.size_t = 0; i < m; i += 1 {
		cb := ucb_at_o(buf, i)^
		keep := true
		if cb.on_bytes != LUA_NOREF_O && (cb.preview || !cmdpreview_g) {
			items: [11]Api_Object
			args := Api_Array{size = 0, capacity = 11, items = &items[0]}
			arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
			arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(start_row)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(start_col)))
			arg_add_o(&args, int_obj_bu_o(start_byte))
			arg_add_o(&args, int_obj_bu_o(C.longlong(old_row)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(old_col)))
			arg_add_o(&args, int_obj_bu_o(old_byte))
			arg_add_o(&args, int_obj_bu_o(C.longlong(new_row)))
			arg_add_o(&args, int_obj_bu_o(C.longlong(new_col)))
			arg_add_o(&args, int_obj_bu_o(new_byte))
			textlock += 1
			res := nlua_call_ref_e(cb.on_bytes, cstring("bytes"), args, KRETNILBOOL_O, nil, nil)
			textlock -= 1
			if luaret_truthy_o(&res) {
				buffer_update_callbacks_free(cb)
				keep = false
			}
		}
		if keep {
			ucb_at_o(buf, j)^ = ucb_at_o(buf, i)^
			j += 1
		}
	}
	(^C.size_t)(bbase)^ = j
}

// Changedtick broadcaster (buffer_updates.c public).
@(export)
buf_updates_changedtick :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	n := uchans_size_o(buf)
	for i: C.size_t = 0; i < n; i += 1 {
		buf_updates_changedtick_single(buf, uchans_item_o(buf, i))
	}
	bbase := uintptr(buf) + B_UPDATE_CALLBACKS_OFF
	j: C.size_t = 0
	m := (^C.size_t)(bbase)^
	for i: C.size_t = 0; i < m; i += 1 {
		cb := ucb_at_o(buf, i)^
		keep := true
		if cb.on_changedtick != LUA_NOREF_O {
			items: [2]Api_Object
			args := Api_Array{size = 0, capacity = 2, items = &items[0]}
			arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
			arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
			textlock += 1
			res := nlua_call_ref_e(cb.on_changedtick, cstring("changedtick"), args, KRETNILBOOL_O, nil, nil)
			textlock -= 1
			if luaret_truthy_o(&res) {
				buffer_update_callbacks_free(cb)
				keep = false
			}
		}
		if keep {
			ucb_at_o(buf, j)^ = ucb_at_o(buf, i)^
			j += 1
		}
	}
	(^C.size_t)(bbase)^ = j
}

// Single-channel changedtick (buffer_updates.c public).
@(export)
buf_updates_changedtick_single :: proc "c" (buf: rawptr, channel_id: u64) {
	context = runtime.default_context()
	items: [2]Api_Object
	args := Api_Array{size = 0, capacity = 2, items = &items[0]}
	arg_add_o(&args, int_obj_bu_o(C.longlong((^C.int)(uintptr(buf) + B_HANDLE_OFF)^)))
	arg_add_o(&args, int_obj_bu_o(buf_changedtick_inline(buf)))
	rpc_send_event_e(C.ulonglong(channel_id), cstring("nvim_buf_changedtick_event"), args)
}

// Callback ref releaser (buffer_updates.c public).
@(export)
buffer_update_callbacks_free :: proc "c" (cb_in: BufUpdateCallbacks_T) {
	context = runtime.default_context()
	api_free_luaref_e(cb_in.on_lines)
	api_free_luaref_e(cb_in.on_bytes)
	api_free_luaref_e(cb_in.on_changedtick)
	api_free_luaref_e(cb_in.on_reload)
	api_free_luaref_e(cb_in.on_detach)
}
