package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// cursor_shape.c port: cursor/mouse shape table + guicursor parser.
// shape_table is an Odin global (C has `extern` via weak-mark; single copy).

SHAPE_IDX_N_O :: 0
SHAPE_IDX_V_O :: 1
SHAPE_IDX_I_O :: 2
SHAPE_IDX_R_O :: 3
SHAPE_IDX_C_O :: 4
SHAPE_IDX_CI_O :: 5
SHAPE_IDX_CR_O :: 6
SHAPE_IDX_O_O :: 7
SHAPE_IDX_VE_O :: 8
SHAPE_IDX_CLINE_O :: 9
SHAPE_IDX_STATUS_O :: 10
SHAPE_IDX_SDRAG_O :: 11
SHAPE_IDX_VSEP_O :: 12
SHAPE_IDX_VDRAG_O :: 13
SHAPE_IDX_MORE_O :: 14
SHAPE_IDX_MOREL_O :: 15
SHAPE_IDX_SM_O :: 16
SHAPE_IDX_TERM_O :: 17
SHAPE_IDX_COUNT_O :: 18

SHAPE_BLOCK_O :: 0
SHAPE_HOR_O :: 1
SHAPE_VER_O :: 2

SHAPE_MOUSE_O :: 1
SHAPE_CURSOR_O :: 2

E545_S :: "E545: Missing colon"
E546_S :: "E546: Illegal mode"
E548_S :: "E548: Digit expected"
E549_S :: "E549: Illegal percentage"

CursorEntry_T :: struct {
	full_name:  cstring,  // @0 (char*, 8B ABI-identical to ^u8)
	shape:      C.int,  // @8
	mshape:     C.int,  // @12
	percentage: C.int,  // @16
	blinkwait:  C.int,  // @20
	blinkon:    C.int,  // @24
	blinkoff:   C.int,  // @28
	id:         C.int,  // @32
	id_lm:      C.int,  // @36
	name:       cstring,  // @40
	used_for:   u8,  // @48
	_pad:       [7]u8,  // @49
}
#assert(size_of(CursorEntry_T) == 56)

@(export)
shape_table: [SHAPE_IDX_COUNT_O]CursorEntry_T = {
	{ "normal", 0, 0, 0, 700, 400, 250, 0, 0, "n", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "visual", 0, 0, 0, 700, 400, 250, 0, 0, "v", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "insert", 0, 0, 0, 700, 400, 250, 0, 0, "i", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "replace", 0, 0, 0, 700, 400, 250, 0, 0, "r", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "cmdline_normal", 0, 0, 0, 700, 400, 250, 0, 0, "c", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "cmdline_insert", 0, 0, 0, 700, 400, 250, 0, 0, "ci", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "cmdline_replace", 0, 0, 0, 700, 400, 250, 0, 0, "cr", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "operator", 0, 0, 0, 700, 400, 250, 0, 0, "o", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "visual_select", 0, 0, 0, 700, 400, 250, 0, 0, "ve", SHAPE_CURSOR_O + SHAPE_MOUSE_O, {} },
	{ "cmdline_hover", 0, 0, 0, 0, 0, 0, 0, 0, "e", SHAPE_MOUSE_O, {} },
	{ "statusline_hover", 0, 0, 0, 0, 0, 0, 0, 0, "s", SHAPE_MOUSE_O, {} },
	{ "statusline_drag", 0, 0, 0, 0, 0, 0, 0, 0, "sd", SHAPE_MOUSE_O, {} },
	{ "vsep_hover", 0, 0, 0, 0, 0, 0, 0, 0, "vs", SHAPE_MOUSE_O, {} },
	{ "vsep_drag", 0, 0, 0, 0, 0, 0, 0, 0, "vd", SHAPE_MOUSE_O, {} },
	{ "more", 0, 0, 0, 0, 0, 0, 0, 0, "m", SHAPE_MOUSE_O, {} },
	{ "more_lastline", 0, 0, 0, 0, 0, 0, 0, 0, "ml", SHAPE_MOUSE_O, {} },
	{ "showmatch", 0, 0, 0, 100, 100, 100, 0, 0, "sm", SHAPE_CURSOR_O, {} },
	{ "terminal", 0, 0, 0, 0, 0, 0, 0, 0, "t", SHAPE_CURSOR_O, {} },
}

foreign _ {
	@(link_name = "arena_array")
	arena_array_e :: proc "c" (arena: rawptr, max_size: C.size_t) -> Api_Array ---
	@(link_name = "p_guicursor")
	p_guicursor_g: ^u8
	@(link_name = "cmdline_at_end")
	cmdline_at_end_e :: proc "c" () -> bool ---
	@(link_name = "cmdline_overstrike")
	cmdline_overstrike_e :: proc "c" () -> bool ---
	// ui_mode_info_set now defined in ui.odin — call directly.
}

// Array append for arena arrays (pre-sized; C ADD_C equivalent).
arr_add_obj_o :: proc "c" (arr: ^Api_Array, val: Api_Object) {
	context = runtime.default_context()
	([^]Api_Object)(arr.items)[arr.size] = val
	arr.size += 1
}

// Dict put for arena dicts (pre-sized; C PUT_C equivalent).
dict_put_obj_o :: proc "c" (dic: ^Api_Dict, key: cstring, val: Api_Object) {
	context = runtime.default_context()
	slot := &([^]Key_Value_Pair)(dic.items)[dic.size]
	slot.key.data = transmute(^u8)(key)
	slot.key.size = libc.strlen(key)
	slot.value = val
	dic.size += 1
}

int_obj_o :: proc "c" (n: C.int) -> Api_Object {
	context = runtime.default_context()
	obj := Api_Object{t = 2}
	(^C.longlong)(uintptr(&obj) + 8)^ = C.longlong(n)
	return obj
}

// Cursor styles as API Array (cursor_shape.c public).
@(export)
mode_style_array :: proc "c" (arena: rawptr) -> Api_Array {
	context = runtime.default_context()
	all := arena_array_e(arena, SHAPE_IDX_COUNT_O)
	for i: C.int = 0; i < SHAPE_IDX_COUNT_O; i += 1 {
		cur := &shape_table[i]
		cap := C.size_t(3)
		if (cur.used_for & SHAPE_CURSOR_O) != 0 {
			cap = 12
		}
		dic := arena_dict_c(arena, cap)
		dict_put_obj_o(&dic, cstring("name"), CSTR_AS_OBJ(transmute(^u8)(cur.full_name)))
		dict_put_obj_o(&dic, cstring("short_name"), CSTR_AS_OBJ(transmute(^u8)(cur.name)))
		if (cur.used_for & SHAPE_MOUSE_O) != 0 {
			dict_put_obj_o(&dic, cstring("mouse_shape"), int_obj_o(cur.mshape))
		}
		if (cur.used_for & SHAPE_CURSOR_O) != 0 {
			shape_str: cstring
			if cur.shape == SHAPE_BLOCK_O {
				shape_str = cstring("block")
			} else if cur.shape == SHAPE_VER_O {
				shape_str = cstring("vertical")
			} else if cur.shape == SHAPE_HOR_O {
				shape_str = cstring("horizontal")
			} else {
				shape_str = cstring("unknown")
			}
			dict_put_obj_o(&dic, cstring("cursor_shape"), CSTR_AS_OBJ(transmute(^u8)(shape_str)))
			dict_put_obj_o(&dic, cstring("cell_percentage"), int_obj_o(cur.percentage))
			dict_put_obj_o(&dic, cstring("blinkwait"), int_obj_o(cur.blinkwait))
			dict_put_obj_o(&dic, cstring("blinkon"), int_obj_o(cur.blinkon))
			dict_put_obj_o(&dic, cstring("blinkoff"), int_obj_o(cur.blinkoff))
			dict_put_obj_o(&dic, cstring("hl_id"), int_obj_o(cur.id))
			dict_put_obj_o(&dic, cstring("id_lm"), int_obj_o(cur.id_lm))
			aid: C.int = 0
			if cur.id != 0 {
				aid = syn_id2attr_r(cur.id)
			}
			dict_put_obj_o(&dic, cstring("attr_id"), int_obj_o(aid))
			aid_lm: C.int = 0
			if cur.id_lm != 0 {
				aid_lm = syn_id2attr_r(cur.id_lm)
			}
			dict_put_obj_o(&dic, cstring("attr_id_lm"), int_obj_o(aid_lm))
		}
		arr_add_obj_o(&all, DICT_OBJ(dic))
	}
	return all
}

// guicursor parser (cursor_shape.c public; returns error literal or nil).
@(export)
parse_shape_opt :: proc "c" (what: C.int) -> cstring {
	context = runtime.default_context()
	p: ^u8 = nil
	idx: C.int = 0
	length: C.int = 0
	found_ve := false
	for round: C.int = 1; round <= 2; round += 1 {
		if round == 2 || ([^]u8)(p_guicursor_g)[0] == 0 {
			clear_shape_table_o()
			if ([^]u8)(p_guicursor_g)[0] == 0 {
				ui_mode_info_set()
				return nil
			}
		}
		modep := p_guicursor_g
		for modep != nil && ([^]u8)(modep)[0] != 0 {
			colonp := transmute(^u8)(vim_strchr(transmute(cstring)(modep), ':'))
			commap := transmute(^u8)(vim_strchr(transmute(cstring)(modep), ','))
			if colonp == nil || (commap != nil && uintptr(commap) < uintptr(colonp)) {
				return cstring(E545_S)
			}
			if uintptr(colonp) == uintptr(modep) {
				return cstring(E546_S)
			}
			all_idx: C.int = -1
			for uintptr(modep) < uintptr(colonp) || all_idx >= 0 {
				if all_idx < 0 {
					if ([^]u8)(modep)[1] == '-' || ([^]u8)(modep)[1] == ':' {
						length = 1
					} else {
						length = 2
					}
					if length == 1 && tolower_asc_o(([^]u8)(modep)[0]) == 'a' {
						all_idx = SHAPE_IDX_COUNT_O - 1
					} else {
						idx = 0
						for idx < SHAPE_IDX_COUNT_O {
							if strncasecmp(transmute(cstring)(modep), shape_table[idx].name, C.size_t(length)) == 0 {
								break
							}
							idx += 1
						}
						if idx == SHAPE_IDX_COUNT_O || (shape_table[idx].used_for & u8(what)) == 0 {
							return cstring(E546_S)
						}
						if length == 2 && ([^]u8)(modep)[0] == 'v' && ([^]u8)(modep)[1] == 'e' {
							found_ve = true
						}
					}
					modep = ([^]u8)(uintptr(modep) + uintptr(length) + 1)
				}
				if all_idx >= 0 {
					idx = all_idx
					all_idx -= 1
				}
				p = ([^]u8)(uintptr(colonp) + 1)
				for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != ',' {
					i := C.int(([^]u8)(p)[0])
					length = 0
					if strncasecmp(transmute(cstring)(p), cstring("ver"), 3) == 0 {
						length = 3
					} else if strncasecmp(transmute(cstring)(p), cstring("hor"), 3) == 0 {
						length = 3
					} else if strncasecmp(transmute(cstring)(p), cstring("blinkwait"), 9) == 0 {
						length = 9
					} else if strncasecmp(transmute(cstring)(p), cstring("blinkon"), 7) == 0 {
						length = 7
					} else if strncasecmp(transmute(cstring)(p), cstring("blinkoff"), 8) == 0 {
						length = 8
					}
					if length != 0 {
						p = ([^]u8)(uintptr(p) + uintptr(length))
						if !ascii_isdigit(([^]u8)(p)[0]) {
							return cstring(E548_S)
						}
						n := getdigits_int(transmute(^^u8)(&p), false, 0)
						if length == 3 {
							if n == 0 {
								return cstring(E549_S)
							}
							if round == 2 {
								if tolower_asc_o(u8(i)) == 'v' {
									shape_table[idx].shape = SHAPE_VER_O
								} else {
									shape_table[idx].shape = SHAPE_HOR_O
								}
								shape_table[idx].percentage = n
							}
						} else if round == 2 {
							if length == 9 {
								shape_table[idx].blinkwait = n
							} else if length == 7 {
								shape_table[idx].blinkon = n
							} else {
								shape_table[idx].blinkoff = n
							}
						}
					} else if strncasecmp(transmute(cstring)(p), cstring("block"), 5) == 0 {
						if round == 2 {
							shape_table[idx].shape = SHAPE_BLOCK_O
						}
						p = ([^]u8)(uintptr(p) + 5)
					} else {
						endp := transmute(^u8)(vim_strchr(transmute(cstring)(p), '-'))
						if commap == nil {
							if endp == nil {
								endp = ([^]u8)(uintptr(p) + uintptr(libc.strlen(transmute(cstring)(p))))
							}
						} else if endp == nil || uintptr(endp) > uintptr(commap) {
							endp = commap
						}
						slashp := transmute(^u8)(vim_strchr(transmute(cstring)(p), '/'))
						if slashp != nil && uintptr(slashp) < uintptr(endp) {
							i = syn_check_group_c(p, C.size_t(uintptr(slashp) - uintptr(p)))
							p = ([^]u8)(uintptr(slashp) + 1)
						}
						if round == 2 {
							shape_table[idx].id = syn_check_group_c(p, C.size_t(uintptr(endp) - uintptr(p)))
							shape_table[idx].id_lm = shape_table[idx].id
							if slashp != nil && uintptr(slashp) < uintptr(endp) {
								shape_table[idx].id = i
							}
						}
						p = endp
					}
					if ([^]u8)(p)[0] == '-' {
						p = ([^]u8)(uintptr(p) + 1)
					}
				}
			}
			modep = p
			if modep != nil && ([^]u8)(modep)[0] == ',' {
				modep = ([^]u8)(uintptr(modep) + 1)
			}
		}
	}
	if !found_ve {
		shape_table[SHAPE_IDX_VE_O].shape = shape_table[SHAPE_IDX_V_O].shape
		shape_table[SHAPE_IDX_VE_O].percentage = shape_table[SHAPE_IDX_V_O].percentage
		shape_table[SHAPE_IDX_VE_O].blinkwait = shape_table[SHAPE_IDX_V_O].blinkwait
		shape_table[SHAPE_IDX_VE_O].blinkon = shape_table[SHAPE_IDX_V_O].blinkon
		shape_table[SHAPE_IDX_VE_O].blinkoff = shape_table[SHAPE_IDX_V_O].blinkoff
		shape_table[SHAPE_IDX_VE_O].id = shape_table[SHAPE_IDX_V_O].id
		shape_table[SHAPE_IDX_VE_O].id_lm = shape_table[SHAPE_IDX_V_O].id_lm
	}
	ui_mode_info_set()
	return nil
}

// Non-blinking block in visual check (cursor_shape.c public).
@(export)
cursor_is_block_during_visual :: proc "c" (exclusive: bool) -> bool {
	context = runtime.default_context()
	mode_idx := SHAPE_IDX_V_O
	if exclusive {
		mode_idx = SHAPE_IDX_VE_O
	}
	return shape_table[mode_idx].shape == SHAPE_BLOCK_O && shape_table[mode_idx].blinkon == 0
}

// Mode name to index (cursor_shape.c public).
@(export)
cursor_mode_str2int :: proc "c" (mode: cstring) -> C.int {
	context = runtime.default_context()
	for mode_idx: C.int = 0; mode_idx < SHAPE_IDX_COUNT_O; mode_idx += 1 {
		if libc.strcmp(shape_table[mode_idx].full_name, mode) == 0 {
			return mode_idx
		}
	}
	logmsg_e(3, nil, cstring("cursor_mode_str2int"), 297, true, cstring("Unknown mode %s"), mode)
	return -1
}

// Syntax-ID cursor use check (cursor_shape.c public).
@(export)
cursor_mode_uses_syn_id :: proc "c" (syn_id: C.int) -> bool {
	context = runtime.default_context()
	if ([^]u8)(p_guicursor_g)[0] == 0 {
		return false
	}
	for mode_idx: C.int = 0; mode_idx < SHAPE_IDX_COUNT_O; mode_idx += 1 {
		if shape_table[mode_idx].id == syn_id || shape_table[mode_idx].id_lm == syn_id {
			return true
		}
	}
	return false
}

// Current mode table index (cursor_shape.c public).
@(export)
cursor_get_mode_idx :: proc "c" () -> C.int {
	context = runtime.default_context()
	if State == MODE_SHOWMATCH_VAL {
		return SHAPE_IDX_SM_O
	} else if State & MODE_TERMINAL_O != 0 {
		return SHAPE_IDX_TERM_O
	} else if State & VREPLACE_FLAG_O != 0 {
		return SHAPE_IDX_R_O
	} else if State & REPLACE_FLAG != 0 {
		return SHAPE_IDX_R_O
	} else if State & MODE_INSERT != 0 {
		return SHAPE_IDX_I_O
	} else if State & MODE_CMDLINE_O != 0 {
		if cmdline_at_end_e() {
			return SHAPE_IDX_C_O
		} else if cmdline_overstrike_e() {
			return SHAPE_IDX_CR_O
		} else {
			return SHAPE_IDX_CI_O
		}
	} else if finish_op_g {
		return SHAPE_IDX_O_O
	} else if VIsual_active {
		if ([^]u8)(p_sel)[0] == 'e' {
			return SHAPE_IDX_VE_O
		} else {
			return SHAPE_IDX_V_O
		}
	} else {
		return SHAPE_IDX_N_O
	}
}

// Table reset (C-static; plain proc).
clear_shape_table_o :: proc "c" () {
	context = runtime.default_context()
	for idx: C.int = 0; idx < SHAPE_IDX_COUNT_O; idx += 1 {
		shape_table[idx].shape = SHAPE_BLOCK_O
		shape_table[idx].blinkwait = 0
		shape_table[idx].blinkon = 0
		shape_table[idx].blinkoff = 0
		shape_table[idx].id = 0
		shape_table[idx].id_lm = 0
	}
}
