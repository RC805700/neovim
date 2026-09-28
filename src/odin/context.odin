package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// context.c port: editor-state snapshots (context stack).
// Context_O mirror lives in eval.odin (27ao, 88B #assert) — reused via
// field offsets regs@0/jumps@16/bufs@32/gvars@48/funcs@64.

foreign _ {
	@(link_name = "shada_encode_regs")
	shada_encode_regs_e :: proc "c" () -> NvimString ---
	@(link_name = "shada_encode_jumps")
	shada_encode_jumps_e :: proc "c" () -> NvimString ---
	@(link_name = "shada_encode_buflist")
	shada_encode_buflist_e :: proc "c" () -> NvimString ---
	@(link_name = "shada_encode_gvars")
	shada_encode_gvars_e :: proc "c" () -> NvimString ---
	@(link_name = "shada_read_string")
	shada_read_string_e :: proc "c" (s: NvimString, flags: C.int) ---
	@(link_name = "string_to_array")
	string_to_array_e :: proc "c" (input: NvimString, crlf: bool, arena: rawptr) -> Api_Array ---
	@(link_name = "copy_array")
	copy_array_e :: proc "c" (array: Api_Array, arena: rawptr) -> Api_Array ---
	@(link_name = "copy_object")
	copy_object_e :: proc "c" (obj: Api_Object, arena: rawptr) -> Api_Object ---
	@(link_name = "api_free_array")
	api_free_array_e :: proc "c" (value: Api_Array) ---
	@(link_name = "exec_impl")
	exec_impl_e :: proc "c" (channel_id: u64, src: NvimString, opts: rawptr, err: rawptr) -> NvimString ---
}

@(export)
kCtxAll: C.int = KCTXREGS_O | KCTXJUMPS_O | KCTXBUFS_O | KCTXGVARS_O | KCTXSFUNCS_O | KCTXFUNCS_O

@(private = "file")
ctx_stack_size_g: C.size_t
@(private = "file")
ctx_stack_cap_g: C.size_t
@(private = "file")
ctx_stack_items_g: rawptr

// Stack slot accessor (Context is 88B).
ctx_at_o :: proc "c" (i: C.size_t) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(ctx_stack_items_g) + uintptr(i)*88)
}

// NULL-safe C string wrapper (cstr_as_string logic).
cstr_nvim_string_o :: proc "c" (s: cstring) -> NvimString {
	context = runtime.default_context()
	ns: NvimString
	if s == nil {
		ns.data = nil
		ns.size = 0
	} else {
		ns.data = s
		ns.size = libc.strlen(s)
	}
	return ns
}

// Clear + free the context stack (context.c public).
@(export)
ctx_free_all :: proc "c" () {
	context = runtime.default_context()
	for i: C.size_t = 0; i < ctx_stack_size_g; i += 1 {
		ctx_free(ctx_at_o(i))
	}
	if ctx_stack_items_g != nil {
		xfree(ctx_stack_items_g)
	}
	ctx_stack_size_g = 0
	ctx_stack_cap_g = 0
	ctx_stack_items_g = nil
}

// Context stack size (context.c public).
@(export)
ctx_size :: proc "c" () -> C.size_t {
	context = runtime.default_context()
	return ctx_stack_size_g
}

// Indexed stack access from top, NULL when out of bounds (context.c public).
@(export)
ctx_get :: proc "c" (index: C.size_t) -> rawptr {
	context = runtime.default_context()
	if index < ctx_stack_size_g {
		return ctx_at_o(ctx_stack_size_g - index - 1)
	}
	return nil
}

// Release context resources (context.c public).
@(export)
ctx_free :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	api_free_string_r((^NvimString)(uintptr(ctx) + 0)^)
	api_free_string_r((^NvimString)(uintptr(ctx) + 16)^)
	api_free_string_r((^NvimString)(uintptr(ctx) + 32)^)
	api_free_string_r((^NvimString)(uintptr(ctx) + 48)^)
	api_free_array_e((^Api_Array)(uintptr(ctx) + 64)^)
}

// Save editor state (context.c public).
@(export)
ctx_save :: proc "c" (ctx_in: rawptr, flags: C.int) {
	context = runtime.default_context()
	ctx := ctx_in
	if ctx == nil {
		if ctx_stack_size_g == ctx_stack_cap_g {
			if ctx_stack_cap_g == 0 {
				ctx_stack_cap_g = 8
			} else {
				ctx_stack_cap_g *= 2
			}
			ctx_stack_items_g = xrealloc(ctx_stack_items_g, C.size_t(ctx_stack_cap_g)*88)
		}
		ctx = ctx_at_o(ctx_stack_size_g)
		libc.memset(ctx, 0, 88)
		ctx_stack_size_g += 1
	}
	if (flags & KCTXREGS_O) != 0 {
		(^NvimString)(uintptr(ctx) + 0)^ = shada_encode_regs_e()
	}
	if (flags & KCTXJUMPS_O) != 0 {
		(^NvimString)(uintptr(ctx) + 16)^ = shada_encode_jumps_e()
	}
	if (flags & KCTXBUFS_O) != 0 {
		(^NvimString)(uintptr(ctx) + 32)^ = shada_encode_buflist_e()
	}
	if (flags & KCTXGVARS_O) != 0 {
		(^NvimString)(uintptr(ctx) + 48)^ = shada_encode_gvars_e()
	}
	if (flags & KCTXFUNCS_O) != 0 {
		ctx_save_funcs_o(ctx, false)
	} else if (flags & KCTXSFUNCS_O) != 0 {
		ctx_save_funcs_o(ctx, true)
	}
}

// Restore editor state (context.c public).
@(export)
ctx_restore :: proc "c" (ctx_in: rawptr, flags: C.int) -> bool {
	context = runtime.default_context()
	ctx := ctx_in
	free_ctx := false
	if ctx == nil {
		if ctx_stack_size_g == 0 {
			return false
		}
		ctx_stack_size_g -= 1
		ctx = ctx_at_o(ctx_stack_size_g)
		free_ctx = true
	}
	op_shada := get_option_value(kOptShada_E, OPT_GLOBAL_S)
	set_option_value(kOptShada_E, str_optval(transmute(^u8)(cstring("!,'100,%")), 8), OPT_GLOBAL_S)
	if (flags & KCTXREGS_O) != 0 {
		shada_read_string_e((^NvimString)(uintptr(ctx) + 0)^, 1 | 4)
	}
	if (flags & KCTXJUMPS_O) != 0 {
		shada_read_string_e((^NvimString)(uintptr(ctx) + 16)^, 1 | 4)
	}
	if (flags & KCTXBUFS_O) != 0 {
		shada_read_string_e((^NvimString)(uintptr(ctx) + 32)^, 1 | 4)
	}
	if (flags & KCTXGVARS_O) != 0 {
		shada_read_string_e((^NvimString)(uintptr(ctx) + 48)^, 1 | 4)
	}
	if (flags & KCTXFUNCS_O) != 0 {
		ctx_restore_funcs_o(ctx)
	}
	if free_ctx {
		ctx_free(ctx)
	}
	set_option_value(kOptShada_E, op_shada, OPT_GLOBAL_S)
	optval_free(op_shada)
	return true
}

// Register restorer (C-static-inline; plain proc).
ctx_restore_regs_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	shada_read_string_e((^NvimString)(uintptr(ctx) + 0)^, 1 | 4)
}

// Jumplist restorer (C-static-inline; plain proc).
ctx_restore_jumps_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	shada_read_string_e((^NvimString)(uintptr(ctx) + 16)^, 1 | 4)
}

// Buffer-list restorer (C-static-inline; plain proc).
ctx_restore_bufs_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	shada_read_string_e((^NvimString)(uintptr(ctx) + 32)^, 1 | 4)
}

// Global-vars restorer (C-static-inline; plain proc).
ctx_restore_gvars_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	shada_read_string_e((^NvimString)(uintptr(ctx) + 48)^, 1 | 4)
}

// Function collector via :func! redump (C-static-inline; plain proc).
ctx_save_funcs_o :: proc "c" (ctx: rawptr, scriptonly: bool) {
	context = runtime.default_context()
	(^Api_Array)(uintptr(ctx) + 64)^ = Api_Array{size = 0, capacity = 0, items = nil}
	err: Api_Error = {typ = -1, msg = nil}
	ht := transmute(^Hashtab_T)(func_tbl_get())
	n := ht.ht_used
	arr := ([^]rawptr)(ht.ht_array)
	todo := n
	i: C.size_t = 0
	for todo > 0 {
		hi_key := ([^]rawptr)(uintptr(arr) + uintptr(i)*16)[1]
		i += 1
		if hi_key == nil || hi_key == transmute(rawptr)(&hash_removed) {
			continue
		}
		todo -= 1
		name := transmute(cstring)(hi_key)
		islambda := libc.strncmp(name, cstring("<lambda>"), 8) == 0
		isscript := ([^]u8)(name)[0] == 0x80
		if !islambda && (!scriptonly || isscript) {
			cmd_len := 7 + libc.strlen(name) + 1
			cmd := ([^]u8)(xmalloc(C.size_t(cmd_len)))
			libc.snprintf(cmd, C.size_t(cmd_len), cstring("func! %s"), name)
			opts: [1]u8
			opts[0] = 1
			func_body := exec_impl_e(u64(0x8000000000000000), cstr_nvim_string_o(transmute(cstring)(cmd)), rawptr(&opts[0]), rawptr(&err))
			xfree(cmd)
			if err.typ == -1 {
				grow_ctx_funcs_o(ctx)
				slot_arr := (^Api_Array)(uintptr(ctx) + 64)
				([^]Api_Object)(slot_arr.items)[slot_arr.size] = string_obj_cx_o(func_body)
				slot_arr.size += 1
			}
			api_clear_error_r(&err)
		}
	}
}

// Array grower for the funcs slot (xrealloc doubling from nil).
grow_ctx_funcs_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	dst := (^Api_Array)(uintptr(ctx) + 64)
	if dst.size == dst.capacity {
		if dst.capacity == 0 {
			dst.capacity = 8
		} else {
			dst.capacity *= 2
		}
		dst.items = (^Api_Object)(xrealloc(dst.items, C.size_t(dst.capacity)*32))
	}
}

// STRING_OBJ equivalent (NvimString payload).
string_obj_cx_o :: proc "c" (s: NvimString) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 4}
	(^NvimString)(uintptr(&obj) + 8)^ = s
	return obj
}

// Function replayer (C-static-inline; plain proc).
ctx_restore_funcs_o :: proc "c" (ctx: rawptr) {
	context = runtime.default_context()
	arr := (^Api_Array)(uintptr(ctx) + 64)
	for i: C.size_t = 0; i < arr.size; i += 1 {
		item := &([^]Api_Object)(arr.items)[i]
		str := (^NvimString)(uintptr(item) + 8)^
		do_cmdline_cmd(str.data)
	}
}

// Readfile-array to String (C-static-inline; plain proc).
array_to_string_o :: proc "c" (array: Api_Array, err: rawptr) -> NvimString {
	context = runtime.default_context()
	sbuf := NvimString{data = nil, size = 0}
	list_tv: Typval_T
	list_tv.v_type = VAR_UNKNOWN
	obj := Api_Object{t = 5}
	(^Api_Array)(uintptr(&obj) + 8)^ = array
	object_to_vim_e(obj, transmute(^Typval_T)(&list_tv), err)
	if list_tv.v_type != VAR_LIST {
		libc.abort()
	}
	out_size: C.size_t = 0
	out_buf: rawptr = nil
	if !encode_vim_list_to_buf(rawptr(list_tv.vval), &out_size, &out_buf) {
		api_set_error_r(err, 2, cstring("%s"), transmute(rawptr)(cstring("E474: Failed to convert list to msgpack string buffer")))
	}
	sbuf.data = transmute(cstring)(out_buf)
	sbuf.size = out_size
	tv_clear(transmute(^Typval_T)(&list_tv))
	return sbuf
}

// Context to Dict (context.c public).
@(export)
ctx_to_dict :: proc "c" (ctx: rawptr, arena: rawptr) -> Api_Dict {
	context = runtime.default_context()
	if ctx == nil {
		libc.abort()
	}
	rv := arena_dict_c(arena, 5)
	put_c_dict_c(rawptr(&rv), cstring("regs"), arr_obj_cx_o(string_to_array_e((^NvimString)(uintptr(ctx) + 0)^, false, arena)))
	put_c_dict_c(rawptr(&rv), cstring("jumps"), arr_obj_cx_o(string_to_array_e((^NvimString)(uintptr(ctx) + 16)^, false, arena)))
	put_c_dict_c(rawptr(&rv), cstring("bufs"), arr_obj_cx_o(string_to_array_e((^NvimString)(uintptr(ctx) + 32)^, false, arena)))
	put_c_dict_c(rawptr(&rv), cstring("gvars"), arr_obj_cx_o(string_to_array_e((^NvimString)(uintptr(ctx) + 48)^, false, arena)))
	put_c_dict_c(rawptr(&rv), cstring("funcs"), arr_obj_cx_o(copy_array_e((^Api_Array)(uintptr(ctx) + 64)^, arena)))
	return rv
}

// ARRAY_OBJ equivalent.
arr_obj_cx_o :: proc "c" (arr: Api_Array) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 5}
	(^Api_Array)(uintptr(&obj) + 8)^ = arr
	return obj
}

// Dict to Context (context.c public).
@(export)
ctx_from_dict :: proc "c" (dict: Api_Dict, ctx: rawptr, err: rawptr) -> C.int {
	context = runtime.default_context()
	if ctx == nil {
		libc.abort()
	}
	types: C.int = 0
	i: C.size_t = 0
	for i < dict.size {
		if (^C.int)(uintptr(err) + 0)^ != -1 {
			break
		}
		item := &([^]Key_Value_Pair)(dict.items)[i]
		if item.value.t != 5 {
			i += 1
			continue
		}
		if strequal(transmute(cstring)(item.key.data), cstring("regs")) {
			types |= KCTXREGS_O
			(^NvimString)(uintptr(ctx) + 0)^ = array_to_string_o((^Api_Array)(uintptr(&item.value) + 8)^, err)
		} else if strequal(transmute(cstring)(item.key.data), cstring("jumps")) {
			types |= KCTXJUMPS_O
			(^NvimString)(uintptr(ctx) + 16)^ = array_to_string_o((^Api_Array)(uintptr(&item.value) + 8)^, err)
		} else if strequal(transmute(cstring)(item.key.data), cstring("bufs")) {
			types |= KCTXBUFS_O
			(^NvimString)(uintptr(ctx) + 32)^ = array_to_string_o((^Api_Array)(uintptr(&item.value) + 8)^, err)
		} else if strequal(transmute(cstring)(item.key.data), cstring("gvars")) {
			types |= KCTXGVARS_O
			(^NvimString)(uintptr(ctx) + 48)^ = array_to_string_o((^Api_Array)(uintptr(&item.value) + 8)^, err)
		} else if strequal(transmute(cstring)(item.key.data), cstring("funcs")) {
			types |= KCTXFUNCS_O
			copied := copy_object_e(item.value, nil)
			(^Api_Array)(uintptr(ctx) + 64)^ = (^Api_Array)(uintptr(&copied) + 8)^
		}
		i += 1
	}
	return types
}
