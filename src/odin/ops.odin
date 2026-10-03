package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// ops.c port: Vim operators (shift/delete/tilde/change/yank/join/...).
// Publics are @(export); C-statics are _o dormant plains.

// OP_NOP/DELETE/YANK/LSHIFT/RSHIFT already in eval.odin/ex_docmd.odin — reuse.
OP_CHANGE_O :: 3
OP_FILTER_O :: 6
OP_TILDE_O :: 7
OP_INDENT_O :: 8
OP_FORMAT_O :: 9
OP_COLON_O :: 10
OP_UPPER_O :: 11
OP_LOWER_O :: 12
OP_JOIN_O :: 13
OP_JOIN_NS_O :: 14
OP_ROT13_O :: 15
OP_REPLACE_O :: 16
OP_INSERT_O :: 17
OP_APPEND_O :: 18
OP_FOLD_O :: 19
OP_FOLDOPEN_O :: 20
OP_FOLDOPENREC_O :: 21
OP_FOLDCLOSE_O :: 22
OP_FOLDCLOSEREC_O :: 23
OP_FOLDDEL_O :: 24
OP_FOLDDELREC_O :: 25
OP_FORMAT2_O :: 26
OP_FUNCTION_O :: 27
OP_NR_ADD_O :: 28
OP_NR_SUB_O :: 29
OPF_LINES_O :: 1
OPF_CHANGE_O :: 2
K_COMMAND_O :: -26877
CMDARG_CMDCHAR_OFF_O :: 12

opchars_g: [30][3]u8 = {
	{0, 0, 0},
	{'d', 0, 2},
	{'y', 0, 0},
	{'c', 0, 2},
	{'<', 0, 3},
	{'>', 0, 3},
	{'!', 0, 3},
	{'g', '~', 2},
	{'=', 0, 3},
	{'g', 'q', 3},
	{':', 0, 1},
	{'g', 'U', 2},
	{'g', 'u', 2},
	{'J', 0, 3},
	{'g', 'J', 3},
	{'g', '?', 2},
	{'r', 0, 2},
	{'I', 0, 2},
	{'A', 0, 2},
	{'z', 'f', 0},
	{'z', 'o', 1},
	{'z', 'O', 1},
	{'z', 'c', 1},
	{'z', 'C', 1},
	{'z', 'd', 1},
	{'z', 'D', 1},
	{'g', 'w', 3},
	{'g', '@', 2},
	{1, 0, 2},
	{24, 0, 2},
}

@(export)
get_op_type :: proc "c" (char1: C.int, char2: C.int) -> C.int {
	context = runtime.default_context()
	if char1 == 'r' {
		return OP_REPLACE_O
	}
	if char1 == '~' {
		return OP_TILDE_O
	}
	if char1 == 'g' && char2 == Ctrl_A {
		return OP_NR_ADD_O
	}
	if char1 == 'g' && char2 == Ctrl_X_O {
		return OP_NR_SUB_O
	}
	if char1 == 'z' && char2 == 'y' {
		return OP_YANK_O
	}
	i: C.int = 0
	for {
		if C.int(opchars_g[uintptr(i)][0]) == char1 && C.int(opchars_g[uintptr(i)][1]) == char2 {
			break
		}
		if i == C.int(len(opchars_g)) - 1 {
			_internal_error(cstring("get_op_type()"))
			break
		}
		i += 1
	}
	return i
}

@(export)
op_on_lines :: proc "c" (op: C.int) -> C.int {
	context = runtime.default_context()
	return C.int(opchars_g[uintptr(op)][2]) & OPF_LINES_O
}

@(export)
op_is_change :: proc "c" (op: C.int) -> C.int {
	context = runtime.default_context()
	return C.int(opchars_g[uintptr(op)][2]) & OPF_CHANGE_O
}

@(export)
get_op_char :: proc "c" (optype: C.int) -> C.int {
	context = runtime.default_context()
	return C.int(opchars_g[uintptr(optype)][0])
}

@(export)
get_extra_op_char :: proc "c" (optype: C.int) -> C.int {
	context = runtime.default_context()
	return C.int(opchars_g[uintptr(optype)][1])
}

@(export)
clear_oparg :: proc "c" (oap: rawptr) {
	context = runtime.default_context()
	libc.memset(oap, 0, 88)
}

@(export)
reset_lbr :: proc "c" () -> bool {
	context = runtime.default_context()
	if (^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ == 0 {
		return false
	}
	(^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ = 0
	(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O)
	return true
}

@(export)
restore_lbr :: proc "c" (lbr_saved: bool) {
	context = runtime.default_context()
	if (^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ != 0 || !lbr_saved {
		return
	}
	(^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ = 1
	(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_WROW_O | VALID_WCOL_O | VALID_VIRTCOL_O)
}

@(export)
skip_comment :: proc "c" (line_in: ^u8, process: bool, include_space: bool, is_comment: ^bool) -> ^u8 {
	context = runtime.default_context()
	line := line_in
	comment_flags: ^u8 = nil
	leader_offset := get_last_leader_offset(line, &comment_flags)
	is_comment^ = false
	if leader_offset != -1 {
		for ([^]u8)(comment_flags)[0] != 0 {
			if ([^]u8)(comment_flags)[0] == COM_END_O || ([^]u8)(comment_flags)[0] == ':' {
				break
			}
			comment_flags = transmute(^u8)(rawptr(uintptr(comment_flags) + 1))
		}
		if ([^]u8)(comment_flags)[0] != COM_END_O {
			is_comment^ = true
		}
	}
	if process == false {
		return line
	}
	lead_len := get_leader_len(line, &comment_flags, false, include_space)
	if lead_len == 0 {
		return line
	}
	for ([^]u8)(comment_flags)[0] != 0 {
		if ([^]u8)(comment_flags)[0] == COM_END_O || ([^]u8)(comment_flags)[0] == ':' {
			break
		}
		comment_flags = transmute(^u8)(rawptr(uintptr(comment_flags) + 1))
	}
	if ([^]u8)(comment_flags)[0] == ':' || ([^]u8)(comment_flags)[0] == 0 {
		line = transmute(^u8)(rawptr(uintptr(line) + uintptr(lead_len)))
	}
	return line
}

is_ex_cmdchar_o :: proc "c" (cap: rawptr) -> bool {
	context = runtime.default_context()
	cmdchar := (^C.int)(uintptr(cap) + CMDARG_CMDCHAR_OFF_O)^
	return cmdchar == ':' || cmdchar == K_COMMAND_O
}

@(export)
get_region_bytecount :: proc "c" (buf: rawptr, start_lnum: C.int, end_lnum: C.int, start_col: C.int, end_col: C.int) -> C.longlong {
	context = runtime.default_context()
	max_lnum := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	if start_lnum > max_lnum {
		return 0
	}
	if start_lnum == end_lnum {
		return C.longlong(end_col) - C.longlong(start_col)
	}
	deleted_bytes := C.longlong(ml_get_buf_len(buf, start_lnum)) - C.longlong(start_col) + 1
	i: C.int = 1
	for i <= end_lnum - start_lnum - 1 {
		if start_lnum + i > max_lnum {
			return deleted_bytes
		}
		deleted_bytes += C.longlong(ml_get_buf_len(buf, start_lnum + i)) + 1
		i += 1
	}
	if end_lnum > max_lnum {
		return deleted_bytes
	}
	return deleted_bytes + C.longlong(end_col)
}

get_vts_o :: proc "c" (vts_array: ^C.int, index: C.int) -> C.int {
	context = runtime.default_context()
	arr := ([^]C.int)(vts_array)
	ts: C.int
	if index < 1 {
		ts = 0
	} else if index <= arr[0] {
		ts = arr[uintptr(index)]
	} else {
		ts = arr[uintptr(arr[0])]
	}
	return ts
}

get_vts_sum_o :: proc "c" (vts_array: ^C.int, index: C.int) -> C.int {
	context = runtime.default_context()
	arr := ([^]C.int)(vts_array)
	sum: C.int = 0
	i: C.int = 1
	for i <= index && i <= arr[0] {
		sum += arr[uintptr(i)]
		i += 1
	}
	if i <= index {
		sum += arr[uintptr(arr[0])] * (index - arr[0])
	}
	return sum
}

get_new_sw_indent_o :: proc "c" (left: bool, round: bool, amount: C.longlong, sw_val: C.longlong) -> C.longlong {
	context = runtime.default_context()
	count := C.longlong(get_indent())
	if round {
		i := trim_to_int(count / sw_val)
		j := trim_to_int(count % sw_val)
		amt := amount
		if j != 0 && left {
			amt -= 1
		}
		if left {
			i = max(i - C.int(amt), 0)
		} else {
			i += C.int(amt)
		}
		count = C.longlong(i) * sw_val
	} else {
		if left {
			count = max(count - sw_val * amount, 0)
		} else {
			count += sw_val * amount
		}
	}
	return count
}

get_new_vts_indent_o :: proc "c" (left: bool, round: bool, amount: C.int, vts_array: ^C.int) -> C.longlong {
	context = runtime.default_context()
	indent := C.longlong(get_indent())
	vtsi: C.int = 0
	vts_indent: C.int = 0
	ts: C.int = 0
	for C.longlong(vts_indent) <= indent {
		vtsi += 1
		ts = get_vts_o(vts_array, vtsi)
		vts_indent += ts
	}
	vts_indent -= ts
	vtsi -= 1
	offset := indent - C.longlong(vts_indent)
	if round {
		if left {
			if offset == 0 {
				indent = C.longlong(get_vts_sum_o(vts_array, vtsi - amount))
			} else {
				indent = C.longlong(get_vts_sum_o(vts_array, vtsi - (amount - 1)))
			}
		} else {
			indent = C.longlong(get_vts_sum_o(vts_array, vtsi + amount))
		}
	} else {
		if left {
			if amount > vtsi {
				indent = 0
			} else {
				indent = C.longlong(get_vts_sum_o(vts_array, vtsi - amount)) + offset
			}
		} else {
			indent = C.longlong(get_vts_sum_o(vts_array, vtsi + amount)) + offset
		}
	}
	return indent
}

@(export)
shift_line :: proc "c" (left: bool, round: bool, amount: C.int, call_changed_bytes: C.int) {
	context = runtime.default_context()
	count: C.longlong
	sw_val := (^C.longlong)(uintptr(curbuf) + B_P_SW_OFF)^
	ts_val := (^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^
	vts_array := (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
	if sw_val != 0 {
		count = get_new_sw_indent_o(left, round, C.longlong(amount), sw_val)
	} else if vts_array == nil || ([^]C.int)(vts_array)[0] == 0 {
		count = get_new_sw_indent_o(left, round, C.longlong(amount), ts_val)
	} else {
		count = get_new_vts_indent_o(left, round, amount, vts_array)
	}
	if (State & VREPLACE_FLAG_O) != 0 {
		change_indent(INDENT_SET_O, trim_to_int(count), false, call_changed_bytes != 0)
	} else {
		sin := C.int(0)
		if call_changed_bytes != 0 {
			sin = SIN_CHANGED_O
		}
		set_indent(trim_to_int(count), sin)
	}
}

foreign _ {
	// tabstop_fromto now defined in indent.odin — call directly.
	@(link_name = "VIsual_select_reg")
	VIsual_select_reg_g: C.int
	@(link_name = "display_dollar")
	display_dollar_e :: proc "c" (col_arg: C.int) ---
	@(link_name = "get_sw_value_indent")
	get_sw_value_indent_e :: proc "c" (buf: rawptr, left: bool) -> C.int ---
	// fix_indent now defined in indent.odin — call directly.
	@(link_name = "edit")
	edit_e :: proc "c" (cmdchar: C.int, startln: bool, count: C.int) -> bool ---
	@(link_name = "stuffnumReadbuff")
	stuffnumReadbuff_e :: proc "c" (n: C.int) ---
	@(link_name = "p_opfunc")
	p_opfunc_g: cstring
	@(link_name = "p_fp")
	p_fp_g: cstring
	// p_sel: reuse register.odin's p_sel (^u8) — no duplicate VAR link_name.
	@(link_name = "bomb_size")
	bomb_size_e :: proc "c" () -> C.int ---
	@(link_name = "redo_VIsual_busy")
	redo_VIsual_busy_g: bool
	@(link_name = "utf_eat_space")
	utf_eat_space_e :: proc "c" (cc: C.int) -> bool ---
}

FO_REMOVE_COMS_O :: 'j'
FO_MBYTE_JOIN_O :: 'M'
FO_MBYTE_JOIN2_O :: 'B'
CPO_JOINCOL_O :: 'q'
CPO_YANK_O :: 'y'
CPO_FILTER_O :: '!'
CPO_REDO_O :: 'r'
K_LUA_O :: -26621
CA_COMMAND_BUSY_O :: 1
CA_NO_ADJ_OP_END_O :: 2
KOPT_BO_OPERATOR_O :: 0x4000
OAP_RESTORE_CURSOR_O :: 56
CAP_NCHAR_O :: 16
CAP_COUNT0_O :: 64
CAP_COUNT1_O :: 68
CAP_ARG_O :: 72
CAP_RETVAL_O :: 76
CAP_SEARCHBUF_O :: 80

Redo_Visual_T :: struct {
	rv_mode:       C.int,
	rv_line_count: C.int,
	rv_vcol:       C.int,
	rv_count:      C.int,
	rv_arg:        C.int,
}
#assert(size_of(Redo_Visual_T) == 20)

redo_VIsual_g: Redo_Visual_T

Indenter_T :: proc "c" () -> C.int

foreign _ {
	@(link_name = "prep_redo")
	prep_redo_e :: proc "c" (regname: C.int, num: C.int, cmd1: C.int, cmd2: C.int, cmd3: C.int, cmd4: C.int, cmd5: C.int) ---
	@(link_name = "prep_redo_num2")
	prep_redo_num2_e :: proc "c" (regname: C.int, num1: C.int, cmd1: C.int, cmd2: C.int, num2: C.int, cmd3: C.int, cmd4: C.int, cmd5: C.int) ---
	@(link_name = "AppendToRedobuff")
	append_to_redobuff_e :: proc "c" (s: cstring) ---
	@(link_name = "AppendToRedobuffLit")
	append_to_redobuff_lit_e :: proc "c" (str: cstring, len: C.int) ---
	@(link_name = "AppendToRedobuffSpec")
	append_to_redobuff_spec_e :: proc "c" (s: cstring) ---
	@(link_name = "AppendNumberToRedobuff")
	append_number_to_redobuff_e :: proc "c" (n: C.int) ---
	@(link_name = "ResetRedobuff")
	reset_redobuff_e :: proc "c" () ---
	@(link_name = "CancelRedo")
	cancel_redo_e :: proc "c" () ---
	@(link_name = "repeat_luaref")
	repeat_luaref_g: C.int
	@(link_name = "restore_visual_mode")
	restore_visual_mode_e :: proc "c" () ---
	@(link_name = "unadjust_for_sel")
	unadjust_for_sel_e :: proc "c" () -> bool ---
	@(link_name = "clearop")
	clearop_e :: proc "c" (oap: rawptr) ---
	@(link_name = "clearopbeep")
	clearopbeep_e :: proc "c" (oap: rawptr) ---
	@(link_name = "may_clear_cmdline")
	may_clear_cmdline_e :: proc "c" () ---
	// op_reindent now defined in indent.odin — call directly.
	// vim_beep now defined in ui.odin — call directly.
	@(link_name = "resel_VIsual_mode")
	resel_VIsual_mode_g: C.int
	@(link_name = "resel_VIsual_vcol")
	resel_VIsual_vcol_g: C.int
	@(link_name = "resel_VIsual_line_count")
	resel_VIsual_line_count_g: C.int
}

OAP_EMPTY_O :: 64
OAP_MOTION_FORCE_O :: 12
OAP_USE_REG_ONE_O :: 16
CPO_EMPTYREGION_O :: 'E'
B_OP_START_ORIG_O :: 7716
REPLACE_CR_NCHAR_O :: -1
REPLACE_NL_NCHAR_O :: -2

mb_adjust_opend_o :: proc "c" (oap: rawptr) {
	context = runtime.default_context()
	inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
	if !inclusive {
		return
	}
	end_lnum := (^C.int)(uintptr(oap) + OAP_END)^
	line := ml_get(end_lnum)
	end_col := (^C.int)(uintptr(oap) + OAP_END + 4)^
	ptr := transmute(^u8)(rawptr(uintptr(line) + uintptr(end_col)))
	if ([^]u8)(ptr)[0] != 0 {
		p2 := transmute(^u8)(rawptr(uintptr(ptr) - uintptr(C.int(utf_head_off(transmute(cstring)(line), transmute(cstring)(ptr))))))
		p2 = transmute(^u8)(rawptr(uintptr(p2) + uintptr(utfc_ptr2len(transmute(cstring)(p2))) - 1))
		(^C.int)(uintptr(oap) + OAP_END + 4)^ = C.int(uintptr(p2) - uintptr(line))
	}
}

pbyte_o :: proc "c" (lp: Pos_T, c: C.int) {
	context = runtime.default_context()
	if c > 255 {
		libc.abort()
	}
	p := ml_get_buf_mut(curbuf, lp.lnum)
	line_textlen := (^Memline_O)(uintptr(curbuf) + 8).line_textlen
	col := lp.col
	if col >= line_textlen {
		if line_textlen > 1 {
			col = line_textlen - 2
		} else {
			col = 0
		}
	}
	([^]u8)(p)[uintptr(col)] = u8(c)
	if curbuf_splice_pending_g == 0 {
		extmark_splice_cols(curbuf, lp.lnum - 1, col, 1, 1, kExtmarkUndo)
	}
}

replace_character_o :: proc "c" (c: C.int) {
	context = runtime.default_context()
	n := State
	State = REPLACE_FLAG | MODE_INSERT
	ins_char(c)
	State = n
	dec_cursor()
}

@(export)
block_prep :: proc "c" (oap: rawptr, bdp: ^Block_Def, lnum: C.int, is_del: bool) {
	context = runtime.default_context()
	incr: C.int = 0
	lbr_saved := reset_lbr()
	bdp.startspaces = 0
	bdp.endspaces = 0
	bdp.textlen = 0
	bdp.start_vcol = 0
	bdp.end_vcol = 0
	bdp.is_short = 0
	bdp.is_oneChar = 0
	bdp.pre_whitesp = 0
	bdp.pre_whitesp_c = 0
	bdp.end_char_vcols = 0
	bdp.start_char_vcols = 0
	line := ml_get(lnum)
	prev_pstart := line
	csarg: CharsizeArg_O
	cstype := init_charsize_arg(&csarg, curwin, lnum, line)
	ci := utf_ptr2StrCharInfo_o(line)
	vcol := bdp.start_vcol
	start_vcol := (^C.int)(uintptr(oap) + OAP_START_VCOL)^
	for vcol < start_vcol && ([^]u8)(ci.ptr)[0] != 0 {
		incr = win_charsize_o(cstype, vcol, ci.ptr, ci.chr.value, &csarg).width
		vcol += incr
		if ci.chr.value == 32 || ci.chr.value == 9 {
			bdp.pre_whitesp += incr
			bdp.pre_whitesp_c += 1
		} else {
			bdp.pre_whitesp = 0
			bdp.pre_whitesp_c = 0
		}
		prev_pstart = ci.ptr
		ci = utfc_next_o(ci)
	}
	bdp.start_vcol = vcol
	pstart := ci.ptr
	bdp.start_char_vcols = incr
	if bdp.start_vcol < start_vcol {
		bdp.end_vcol = bdp.start_vcol
		bdp.is_short = 1
		if !is_del || (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_APPEND_O {
			bdp.endspaces = (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - start_vcol + 1
		}
	} else {
		bdp.startspaces = bdp.start_vcol - start_vcol
		if is_del && bdp.startspaces != 0 {
			bdp.startspaces = bdp.start_char_vcols - bdp.startspaces
		}
		pend := pstart
		bdp.end_vcol = bdp.start_vcol
		if bdp.end_vcol > (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
			bdp.is_oneChar = 1
			if (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_INSERT_O {
				bdp.endspaces = bdp.start_char_vcols - bdp.startspaces
			} else if (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_APPEND_O {
				bdp.startspaces += (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - start_vcol + 1
				bdp.endspaces = bdp.start_char_vcols - bdp.startspaces
			} else {
				bdp.startspaces = (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - start_vcol + 1
				if is_del && (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ != OP_LSHIFT_O {
					bdp.startspaces = bdp.start_char_vcols - (bdp.start_vcol - start_vcol)
					bdp.endspaces = bdp.end_vcol - (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - 1
				}
			}
		} else {
			cstype = init_charsize_arg(&csarg, curwin, lnum, line)
			ci = utf_ptr2StrCharInfo_o(pend)
			vcol = bdp.end_vcol
			prev_pend := pend
			for vcol <= (^C.int)(uintptr(oap) + OAP_END_VCOL)^ && ([^]u8)(ci.ptr)[0] != 0 {
				prev_pend = ci.ptr
				incr = win_charsize_o(cstype, vcol, ci.ptr, ci.chr.value, &csarg).width
				vcol += incr
				ci = utfc_next_o(ci)
			}
			bdp.end_vcol = vcol
			pend = ci.ptr
			take_short := false
			if bdp.end_vcol <= (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
				take_short = true
			}
			if take_short {
				allow := false
				if !is_del {
					allow = true
				}
				if (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_APPEND_O {
					allow = true
				}
				if (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_REPLACE_O {
					allow = true
				}
				if !allow {
					take_short = false
				}
			}
			if take_short {
				bdp.is_short = 1
				short_append := false
				if (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_APPEND_O {
					short_append = true
				}
				if virtual_op_g != TriState.kFalse {
					short_append = true
				}
				if short_append {
					inc2 := C.int(0)
					if (^bool)(uintptr(oap) + OAP_INCLUSIVE)^ {
						inc2 = 1
					}
					bdp.endspaces = (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - bdp.end_vcol + inc2
				}
			} else if bdp.end_vcol > (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
				bdp.endspaces = bdp.end_vcol - (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - 1
				if !is_del && bdp.endspaces != 0 {
					bdp.endspaces = incr - bdp.endspaces
					if pend != pstart {
						pend = prev_pend
					}
				}
			}
		}
		bdp.end_char_vcols = incr
		if is_del && bdp.startspaces != 0 {
			pstart = prev_pstart
		}
		bdp.textlen = C.int(uintptr(pend) - uintptr(pstart))
	}
	bdp.textcol = C.int(uintptr(pstart) - uintptr(line))
	bdp.textstart = pstart
	restore_lbr(lbr_saved)
}

@(export)
charwise_block_prep :: proc "c" (start_in: Pos_T, end_in: Pos_T, bdp: ^Block_Def, lnum: C.int, inclusive: bool) {
	context = runtime.default_context()
	st := start_in
	en := end_in
	startcol: C.int = 0
	endcol: C.int = MAXCOL
	cs: C.int
	ce: C.int
	p := ml_get(lnum)
	plen := ml_get_len(lnum)
	bdp.startspaces = 0
	bdp.endspaces = 0
	bdp.is_oneChar = 0
	bdp.start_char_vcols = 0
	if lnum == st.lnum {
		startcol = st.col
		if virtual_op_g != TriState.kFalse {
			getvcol(curwin, &st, &cs, nil, &ce, 0)
			if ce != cs && st.coladd > 0 {
				bdp.start_char_vcols = ce - cs + 1
				spaces := bdp.start_char_vcols - st.coladd
				if spaces < 0 {
					spaces = 0
				}
				bdp.startspaces = spaces
				startcol += 1
			}
		}
	}
	if lnum == en.lnum {
		endcol = en.col
		if virtual_op_g != TriState.kFalse {
			getvcol(curwin, &en, &cs, nil, &ce, 0)
			p_end := transmute(^u8)(rawptr(uintptr(p) + uintptr(endcol)))
			if ([^]u8)(p_end)[0] == 0 || (cs + en.coladd < ce && utf_head_off(transmute(cstring)(p), transmute(cstring)(p_end)) == 0) {
				if st.lnum == en.lnum && st.col == en.col {
					bdp.is_oneChar = 1
					sp2 := en.coladd - st.coladd
					if inclusive {
						sp2 += 1
					}
					bdp.startspaces = sp2
					endcol = startcol
				} else {
					es := en.coladd
					if inclusive {
						es += 1
					}
					bdp.endspaces = es
					if inclusive {
						endcol -= 1
					}
				}
			}
		}
	}
	if endcol == MAXCOL {
		endcol = ml_get_len(lnum)
	}
	if startcol > endcol || bdp.is_oneChar != 0 {
		bdp.textlen = 0
	} else {
		inc := C.int(0)
		if inclusive {
			inc = 1
		}
		bdp.textlen = endcol - startcol + inc
	}
	bdp.textcol = startcol
	if startcol <= plen {
		bdp.textstart = transmute(^u8)(rawptr(uintptr(p) + uintptr(startcol)))
	} else {
		bdp.textstart = p
	}
}

shift_block_o :: proc "c" (oap: rawptr, amount: C.int) {
	context = runtime.default_context()
	left := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ == OP_LSHIFT_O
	oldstate := State
	newp: ^u8
	oldcol := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	sw_val := get_sw_value_indent_e(curbuf, left)
	ts_val := C.int((^C.longlong)(uintptr(curbuf) + B_P_TS_OFF)^)
	bd := Block_Def{}
	incr: C.int = 0
	old_p_ri := p_ri
	p_ri = 0
	State = MODE_INSERT
	block_prep(oap, &bd, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, true)
	if bd.is_short != 0 {
		return
	}
	total := C.uint(C.uint(amount) * C.uint(sw_val))
	if C.int(total) / sw_val != amount {
		return
	}
	tot := C.int(total)
	oldp := get_cursor_line_ptr()
	old_line_len := get_cursor_line_len()
	startcol: C.int
	oldlen: C.int
	newlen: C.int
	if !left {
		tot += bd.pre_whitesp
		ws_vcol := bd.start_vcol - bd.pre_whitesp
		old_textstart := bd.textstart
		if bd.startspaces != 0 {
			if utfc_ptr2len(transmute(cstring)(bd.textstart)) == 1 {
				bd.textstart = transmute(^u8)(rawptr(uintptr(bd.textstart) + 1))
			} else {
				ws_vcol = 0
				bd.startspaces = 0
			}
		}
		csarg: CharsizeArg_O
		cstype := init_charsize_arg(&csarg, curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, bd.textstart)
		ci := utf_ptr2StrCharInfo_o(bd.textstart)
		vcol := bd.start_vcol
		for ci.chr.value == 32 || ci.chr.value == 9 {
			incr = win_charsize_o(cstype, vcol, ci.ptr, ci.chr.value, &csarg).width
			ci = utfc_next_o(ci)
			tot += incr
			vcol += incr
		}
		bd.textstart = ci.ptr
		bd.start_vcol = vcol
		tabs: C.int = 0
		spaces: C.int = 0
		b_p_et := (^C.int)(uintptr(curbuf) + B_P_ET_OFF2)^
		if b_p_et == 0 {
			vts := (^C.int)((^rawptr)(uintptr(curbuf) + B_P_VTS_ARR_OFF)^)
			tabstop_fromto(ws_vcol, ws_vcol + C.int(tot), ts_val, vts, &tabs, &spaces)
		} else {
			spaces = C.int(tot)
		}
		col_pre := bd.pre_whitesp_c
		if bd.startspaces != 0 {
			col_pre -= 1
		}
		bd.textcol -= col_pre
		new_line_len := bd.textcol + tabs + spaces + (old_line_len - C.int(uintptr(bd.textstart) - uintptr(oldp)))
		newp = transmute(^u8)(xmalloc(C.size_t(new_line_len) + 1))
		libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(bd.textcol))
		startcol = bd.textcol
		oldlen = C.int(uintptr(bd.textstart) - uintptr(old_textstart)) + col_pre
		newlen = tabs + spaces
		libc.memset(rawptr(uintptr(newp) + uintptr(bd.textcol)), C.int(9), C.size_t(tabs))
		libc.memset(rawptr(uintptr(newp) + uintptr(bd.textcol) + uintptr(tabs)), C.int(32), C.size_t(spaces))
		libc.memmove(rawptr(uintptr(newp) + uintptr(bd.textcol) + uintptr(tabs) + uintptr(spaces)), rawptr(bd.textstart), C.size_t(libc.strlen(transmute(cstring)(bd.textstart))) + 1)
		if newlen - oldlen != new_line_len - old_line_len {
			libc.abort()
		}
	} else {
		verbatim_copy_end: ^u8
		verbatim_copy_width: C.int
		non_white := bd.textstart
		if bd.startspaces != 0 {
			non_white = transmute(^u8)(rawptr(uintptr(non_white) + uintptr(C.int(utfc_ptr2len(transmute(cstring)(non_white))))))
		}
		non_white_col := bd.start_vcol
		csarg: CharsizeArg_O
		cstype := init_charsize_arg(&csarg, curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, bd.textstart)
		for ascii_iswhite(([^]u8)(non_white)[0]) {
			incr = win_charsize_o(cstype, non_white_col, non_white, C.int32_t(([^]u8)(non_white)[0]), &csarg).width
			non_white_col += incr
			non_white = transmute(^u8)(rawptr(uintptr(non_white) + 1))
		}
		start_vcol := (^C.int)(uintptr(oap) + OAP_START_VCOL)^
		block_space_width := non_white_col - start_vcol
		shift_amount := block_space_width
		if tot < shift_amount {
			shift_amount = tot
		}
		destination_col := non_white_col - shift_amount
		verbatim_copy_end = bd.textstart
		verbatim_copy_width = bd.start_vcol
		if bd.startspaces != 0 {
			verbatim_copy_width -= bd.start_char_vcols
		}
		cstype = init_charsize_arg(&csarg, curwin, 0, bd.textstart)
		ci := utf_ptr2StrCharInfo_o(verbatim_copy_end)
		for verbatim_copy_width < destination_col {
			incr = win_charsize_o(cstype, verbatim_copy_width, ci.ptr, ci.chr.value, &csarg).width
			if verbatim_copy_width + incr > destination_col {
				break
			}
			verbatim_copy_width += incr
			ci = utfc_next_o(ci)
		}
		verbatim_copy_end = ci.ptr
		if destination_col - verbatim_copy_width < 0 {
			libc.abort()
		}
		fill := destination_col - verbatim_copy_width
		fixedlen := C.int(uintptr(verbatim_copy_end) - uintptr(oldp))
		new_line_len := fixedlen + fill + (old_line_len - C.int(uintptr(non_white) - uintptr(oldp)))
		newp = transmute(^u8)(xmalloc(C.size_t(new_line_len) + 1))
		startcol = fixedlen
		oldlen = bd.textcol + C.int(uintptr(non_white) - uintptr(bd.textstart)) - fixedlen
		newlen = fill
		libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(fixedlen))
		libc.memset(rawptr(uintptr(newp) + uintptr(fixedlen)), C.int(32), C.size_t(fill))
		libc.memmove(rawptr(uintptr(newp) + uintptr(fixedlen) + uintptr(fill)), rawptr(non_white), C.size_t(libc.strlen(transmute(cstring)(non_white))) + 1)
		if newlen - oldlen != new_line_len - old_line_len {
			libc.abort()
		}
	}
	ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, newp, false)
	changed_bytes((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, bd.textcol)
	extmark_splice_cols(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, startcol, oldlen, newlen, kExtmarkUndo)
	State = oldstate
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = oldcol
	p_ri = old_p_ri
}

block_insert_o :: proc "c" (oap: rawptr, s: ^u8, slen: C.size_t, b_insert: bool, bdp: ^Block_Def) {
	context = runtime.default_context()
	ts_val: C.int
	count: C.int = 0
	spaces: C.int = 0
	offset: C.int
	newp: ^u8
	oldp: ^u8
	oldstate := State
	State = MODE_INSERT
	for lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum + 1; lnum <= (^Pos_T)(uintptr(oap) + OAP_END)^.lnum; lnum += 1 {
		block_prep(oap, bdp, lnum, true)
		if bdp.is_short != 0 && b_insert {
			continue
		}
		oldp = ml_get(lnum)
		if b_insert {
			ts_val = bdp.start_char_vcols
			spaces = bdp.startspaces
			if spaces != 0 {
				count = ts_val - 1
			}
			offset = bdp.textcol
		} else {
			ts_val = bdp.end_char_vcols
			if bdp.is_short == 0 {
				spaces = 0
				if bdp.endspaces != 0 {
					spaces = ts_val - bdp.endspaces
				}
				if spaces != 0 {
					count = ts_val - 1
				}
				offset = bdp.textcol + bdp.textlen
				if spaces != 0 {
					offset -= 1
				}
			} else {
				if bdp.is_MAX == 0 {
					spaces = (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - bdp.end_vcol + 1
				}
				count = spaces
				offset = bdp.textcol + bdp.textlen
			}
		}
		if spaces > 0 {
			offset -= C.int(utf_head_off(transmute(cstring)(oldp), transmute(cstring)(rawptr(uintptr(oldp) + uintptr(offset)))))
		}
		if spaces < 0 {
			spaces = 0
		}
		extra_alloc: C.size_t = 0
		if spaces > 0 && bdp.is_short == 0 {
			extra_alloc = C.size_t(ts_val - spaces)
		}
		newp = transmute(^u8)(xmalloc(C.size_t(ml_get_len(lnum)) + C.size_t(spaces) + slen + extra_alloc + C.size_t(count) + 1))
		libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(offset))
		oldp = transmute(^u8)(rawptr(uintptr(oldp) + uintptr(offset)))
		startcol := offset
		libc.memset(rawptr(uintptr(newp) + uintptr(offset)), C.int(32), C.size_t(spaces))
		libc.memmove(rawptr(uintptr(newp) + uintptr(offset) + uintptr(spaces)), rawptr(s), slen)
		offset += C.int(slen)
		skipped: C.int = 0
		if spaces > 0 && bdp.is_short == 0 {
			if ([^]u8)(oldp)[0] == TAB_O {
				libc.memset(rawptr(uintptr(newp) + uintptr(offset) + uintptr(spaces)), C.int(32), C.size_t(ts_val - spaces))
				oldp = transmute(^u8)(rawptr(uintptr(oldp) + 1))
				count += 1
				skipped = 1
			} else {
				count = spaces
			}
		}
		if spaces > 0 {
			offset += count
		}
		tail := oldp
		libc.memmove(rawptr(uintptr(newp) + uintptr(offset)), rawptr(tail), C.size_t(libc.strlen(transmute(cstring)(tail))) + 1)
		ml_replace(lnum, newp, false)
		extmark_splice_cols(curbuf, lnum - 1, startcol, skipped, offset - startcol, kExtmarkUndo)
		if lnum == (^Pos_T)(uintptr(oap) + OAP_END)^.lnum {
			(^C.int)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
			(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = offset
			vi_end := (^Visualinfo_T)(uintptr(curbuf) + B_VISUAL)^.vi_end
			if vi_end.coladd != 0 {
				vi_end.col += vi_end.coladd
				vi_end.coladd = 0
				(^Visualinfo_T)(uintptr(curbuf) + B_VISUAL)^.vi_end = vi_end
			}
		}
	}
	State = oldstate
	if (^Pos_T)(uintptr(oap) + OAP_START)^.lnum < (^Pos_T)(uintptr(oap) + OAP_END)^.lnum {
		changed_lines(curbuf, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum + 1, 0, (^Pos_T)(uintptr(oap) + OAP_END)^.lnum + 1, 0, true)
	}
}

@(export)
op_tilde :: proc "c" (oap: rawptr) {
	context = runtime.default_context()
	bd := Block_Def{}
	did_change := false
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	is_visual := (^bool)(uintptr(oap) + OAP_IS_VISUAL)^
	inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
	if u_save(start_lnum - 1, end_lnum + 1) == 0 {
		return
	}
	pos := (^Pos_T)(uintptr(oap) + OAP_START)^
	if motion_type == kMTBlockWise {
		for pos.lnum <= end_lnum {
			block_prep(oap, &bd, pos.lnum, false)
			pos.col = bd.textcol
			one_change := false
			if swapchars_o(op_type, &pos, bd.textlen) {
				one_change = true
			}
			if one_change {
				did_change = true
			}
			pos.lnum += 1
		}
		if did_change {
			changed_lines(curbuf, start_lnum, 0, end_lnum + 1, 0, true)
		}
	} else {
		if motion_type == kMTLineWise {
			(^C.int)(uintptr(oap) + OAP_START + 4)^ = 0
			pos.col = 0
			(^C.int)(uintptr(oap) + OAP_END + 4)^ = ml_get_len(end_lnum)
			if (^C.int)(uintptr(oap) + OAP_END + 4)^ != 0 {
				(^C.int)(uintptr(oap) + OAP_END + 4)^ -= 1
			}
		} else if !inclusive {
			dec(rawptr(uintptr(oap) + OAP_END))
		}
		end_col := (^C.int)(uintptr(oap) + OAP_END + 4)^
		if pos.lnum == end_lnum {
			did_change = swapchars_o(op_type, &pos, end_col - pos.col + 1)
		} else {
			for {
				n := end_lnum
				if pos.lnum == end_lnum {
					n = end_col
				} else {
					n = ml_get_pos_len(rawptr(&pos))
				}
				if swapchars_o(op_type, &pos, n) {
					did_change = true
				}
				end_pos := (^Pos_T)(uintptr(oap) + OAP_END)^
				if ltoreq_o(end_pos, pos) || inc(rawptr(&pos)) == -1 {
					break
				}
			}
		}
		if did_change {
			changed_lines(curbuf, start_lnum, (^Pos_T)(uintptr(oap) + OAP_START)^.col, end_lnum + 1, 0, true)
		}
	}
	if !did_change && is_visual {
		redraw_curbuf_later(UPD_INVERTED_S)
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
	}
	if C.longlong(line_count) > p_report {
		msg := ngettext_r(cstring("%ld line changed"), cstring("%ld lines changed"), C.long(line_count))
		smsg(0, msg, C.longlong(line_count))
	}
}

swapchars_o :: proc "c" (op_type: C.int, pos: ^Pos_T, length: C.int) -> bool {
	context = runtime.default_context()
	did_change := false
	todo := length
	for todo > 0 {
		todo -= 1
		length := utfc_ptr2len(transmute(cstring)(ml_get_pos(rawptr(pos))))
		if length > 0 {
			todo -= length - 1
		}
		if swapchar(op_type, pos) {
			did_change = true
		}
		if inc(rawptr(pos)) == -1 {
			break
		}
	}
	return did_change
}

@(export)
swapchar :: proc "c" (op_type: C.int, pos: ^Pos_T) -> bool {
	context = runtime.default_context()
	c := gchar_pos(rawptr(pos))
	if c >= 0x80 && op_type == OP_ROT13_O {
		return false
	}
	nc := c
	if mb_islower_r2(c) {
		if op_type == OP_ROT13_O {
			nc = ((c - 'a' + 13) % 26) + 'a'
		} else if op_type != OP_LOWER_O {
			nc = mb_toupper_r(c)
		}
	} else if mb_isupper_r(c) {
		if op_type == OP_ROT13_O {
			nc = ((c - 'A' + 13) % 26) + 'A'
		} else if op_type != OP_UPPER_O {
			nc = mb_tolower_r(c)
		}
	}
	if nc != c {
		if c >= 0x80 || nc >= 0x80 {
			sp := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos^
			del_bytes(utf_ptr2len_o(transmute(cstring)(get_cursor_pos_ptr())), false, false)
			ins_char(nc)
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = sp
		} else {
			pbyte_o(pos^, nc)
		}
		return true
	}
	return false
}

@(export)
op_shift :: proc "c" (oap: rawptr, curs_top: bool, amount: C.int) {
	context = runtime.default_context()
	block_col: C.int = 0
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	if u_save(start_lnum - 1, end_lnum + 1) == 0 {
		return
	}
	if motion_type == kMTBlockWise {
		block_col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	}
	i := line_count - 1
	for i >= 0 {
		first_char := ([^]u8)(get_cursor_line_ptr())[0]
		if first_char == 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
		} else if motion_type == kMTBlockWise {
			shift_block_o(oap, amount)
		} else if first_char != '#' || !preprocs_left() {
			shift_line(op_type == OP_LSHIFT_O, p_sr_g != 0, amount, 0)
		}
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
		i -= 1
	}
	if motion_type == kMTBlockWise {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = start_lnum
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = block_col
	} else if curs_top {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = start_lnum
		beginline(BL_SOL | BL_FIX)
	} else {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
	}
	foldOpenCursor()
	if i64(line_count) > p_report {
		op: cstring
		if op_type == OP_RSHIFT_O {
			op = cstring(">")
		} else {
			op = cstring("<")
		}
		msg_single := ngettext_r(cstring("%ld line %sed %d time"), cstring("%ld line %sed %d times"), C.long(amount))
		msg_plural := ngettext_r(cstring("%ld lines %sed %d time"), cstring("%ld lines %sed %d times"), C.long(amount))
		msg := ngettext_r(msg_single, msg_plural, C.long(line_count))
		vim_snprintf(&IObuff[0], C.size_t(IOSIZE_O), msg, i64(line_count), op, C.int(amount))
		msg_keep_r(transmute(cstring)(&IObuff[0]), 0, true, false)
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		opl := (^Pos_T)(uintptr(oap) + OAP_END)^
		opl.col = ml_get_len(opl.lnum)
		if opl.col > 0 {
			opl.col -= 1
		}
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = opl
	}
	changed_lines(curbuf, start_lnum, 0, end_lnum + 1, 0, true)
}

@(export)
op_delete :: proc "c" (oap: rawptr) -> C.int {
	context = runtime.default_context()
	lnum: C.int
	bd := Block_Def{}
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	regname := (^C.int)(uintptr(oap) + OAP_REGNAME)^
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	start_col := (^Pos_T)(uintptr(oap) + OAP_START)^.col
	end_col := (^Pos_T)(uintptr(oap) + OAP_END)^.col
	inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
	is_visual := (^bool)(uintptr(oap) + OAP_IS_VISUAL)^
	use_reg_one := (^bool)(uintptr(oap) + OAP_USE_REG_ONE_O)^
	empty := (^bool)(uintptr(oap) + OAP_EMPTY_O)^
	motion_force := (^C.int)(uintptr(oap) + OAP_MOTION_FORCE_O)^
	old_lcount := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	wbuf := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	_ = wbuf
	if (^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O != 0 {
		return OK
	}
	if empty {
		return u_save_cursor()
	}
	if (^C.int)(uintptr(curbuf) + B_P_MA_OFF)^ == 0 {
		emsg(e_modifiable)
		return FAIL
	}
	if VIsual_select_g && is_visual {
		(^C.int)(uintptr(oap) + OAP_REGNAME)^ = VIsual_select_reg_g
		regname = VIsual_select_reg_g
	}
	mb_adjust_opend_o(oap)
	start_lnum = (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	start_col = (^Pos_T)(uintptr(oap) + OAP_START)^.col
	end_col = (^Pos_T)(uintptr(oap) + OAP_END)^.col
	if motion_type == kMTCharWise && !is_visual && line_count > 1 && motion_force == 0 && op_type == OP_DELETE_O {
		ptr := transmute(^u8)(rawptr(uintptr(ml_get(end_lnum)) + uintptr(end_col)))
		if ([^]u8)(ptr)[0] != 0 {
			incl := (^C.int)(uintptr(oap) + OAP_INCLUSIVE)^
			ptr = transmute(^u8)(rawptr(uintptr(ptr) + uintptr(incl)))
		}
		ptr = transmute(^u8)(skipwhite(transmute(cstring)(ptr)))
		if ([^]u8)(ptr)[0] == 0 && inindent(0) {
			motion_type = kMTLineWise
			(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTLineWise
		}
	}
	only_marks := false
	if motion_type != kMTLineWise && line_count == 1 && op_type == OP_DELETE_O && ([^]u8)(ml_get(start_lnum))[0] == 0 {
		if virtual_op_g != TriState.kFalse {
			only_marks = true
		} else {
			if vim_strchr(p_cpo, C.int(CPO_EMPTYREGION_O)) != nil {
				beep_flush_r()
			}
			return OK
		}
	}
	if !only_marks {
		if regname != '_' {
			reg: ^Yankreg_T = nil
			did_yank := false
			if regname != 0 {
				if !valid_yank_reg(regname, true) {
					beep_flush_r()
					return OK
				}
				reg = get_yank_register(regname, YREG_YANK)
			}
			if motion_type == kMTLineWise || line_count > 1 || use_reg_one {
				shift_delete_registers(is_append_register(regname))
				reg = get_y_register(1)
				op_yank_reg(oap, false, reg, false)
				did_yank = true
			}
			if regname == 0 && motion_type != kMTLineWise && line_count == 1 {
				reg = get_yank_register('-', YREG_YANK)
				op_yank_reg(oap, false, reg, false)
				did_yank = true
			}
			if did_yank || regname == 0 {
				if reg == nil {
					libc.abort()
				}
				set_clipboard(regname, reg)
				do_autocmd_textyankpost(oap, reg)
			}
			regname = (^C.int)(uintptr(oap) + OAP_REGNAME)^
		}
		if motion_type == kMTBlockWise {
			if u_save(start_lnum - 1, end_lnum + 1) == 0 {
				return FAIL
			}
			lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
			for lnum <= end_lnum {
				block_prep(oap, &bd, lnum, true)
				if bd.textlen == 0 {
					lnum += 1
					continue
				}
				if lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = bd.textcol + bd.startspaces
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
				}
				n := bd.textlen - bd.startspaces - bd.endspaces
				oldp := ml_get(lnum)
				newp := transmute(^u8)(xmalloc(C.size_t(ml_get_len(lnum)) - C.size_t(n) + 1))
				libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(bd.textcol))
				libc.memset(rawptr(uintptr(newp) + uintptr(bd.textcol)), C.int(32), C.size_t(bd.startspaces) + C.size_t(bd.endspaces))
				tail := transmute(^u8)(rawptr(uintptr(oldp) + uintptr(bd.textcol) + uintptr(bd.textlen)))
				libc.memmove(rawptr(uintptr(newp) + uintptr(bd.textcol) + uintptr(bd.startspaces) + uintptr(bd.endspaces)), rawptr(tail), C.size_t(libc.strlen(transmute(cstring)(tail))) + 1)
				ml_replace(lnum, newp, false)
				extmark_splice_cols(curbuf, lnum - 1, bd.textcol, bd.textlen, bd.startspaces + bd.endspaces, kExtmarkUndo)
				lnum += 1
			}
			check_cursor_col(curwin)
			changed_lines(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^, end_lnum + 1, 0, true)
			(^C.int)(uintptr(oap) + OAP_LINE_COUNT)^ = 0
		} else if motion_type == kMTLineWise {
			if op_type == OP_CHANGE_O {
				if line_count > 1 {
					lnum = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
					del_lines(line_count - 1, true)
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
				}
				if u_save_cursor() == 0 {
					return FAIL
				}
				if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ != 0 {
					beginline(BL_WHITE)
					did_ai_g = true
					ai_col_g = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				} else {
					beginline(0)
				}
				truncate_line(0)
				if line_count > 1 {
					u_clearline(curbuf)
				}
			} else {
				del_lines(line_count, true)
				beginline(BL_WHITE | BL_FIX)
				u_clearline(curbuf)
			}
		} else {
			if virtual_op_g != TriState.kFalse {
				if gchar_pos(rawptr(uintptr(oap) + OAP_START)) == '\t' {
					endcol: C.int = 0
					if u_save_cursor() == 0 {
						return FAIL
					}
					if line_count == 1 {
						endcol = getviscol2((^C.int)(uintptr(oap) + OAP_END + 4)^, (^C.int)(uintptr(oap) + OAP_END + 8)^)
					}
					coladvance_force(getviscol2((^C.int)(uintptr(oap) + OAP_START + 4)^, (^C.int)(uintptr(oap) + OAP_START + 8)^))
					(^Pos_T)(uintptr(oap) + OAP_START)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
					if line_count == 1 {
						coladvance(curwin, endcol)
						(^C.int)(uintptr(oap) + OAP_END + 4)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
						(^C.int)(uintptr(oap) + OAP_END + 8)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^
						(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
					}
				}
				if gchar_pos(rawptr(uintptr(oap) + OAP_END)) == '\t' && (^C.int)(uintptr(oap) + OAP_END + 8)^ == 0 && inclusive {
					if u_save((^C.int)(uintptr(oap) + OAP_END)^ - 1, (^C.int)(uintptr(oap) + OAP_END)^ + 1) == 0 {
						return FAIL
					}
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
					coladvance_force(getviscol2((^C.int)(uintptr(oap) + OAP_END + 4)^, (^C.int)(uintptr(oap) + OAP_END + 8)^))
					(^Pos_T)(uintptr(oap) + OAP_END)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
				}
				mb_adjust_opend_o(oap)
			}
			start_lnum = (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
			end_lnum = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
			start_col = (^Pos_T)(uintptr(oap) + OAP_START)^.col
			end_col = (^Pos_T)(uintptr(oap) + OAP_END)^.col
			inclusive = (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
			if line_count == 1 {
				if u_save_cursor() == 0 {
					return FAIL
				}
				if vim_strchr(p_cpo, C.int(CPO_DOLLAR_O)) != nil && op_type == OP_CHANGE_O && end_lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ && !is_visual {
					dadj := C.int(0)
					if !inclusive {
						dadj = 1
					}
					display_dollar_e(end_col - dadj)
				}
				n := end_col - start_col + 1
				if !inclusive {
					n -= 1
				}
				if virtual_op_g != TriState.kFalse {
					len := get_cursor_line_len()
					if (^C.int)(uintptr(oap) + OAP_END + 8)^ != 0 && (^C.int)(uintptr(oap) + OAP_END + 4)^ >= len - 1 && !((^C.int)(uintptr(oap) + OAP_START + 8)^ != 0 && (^C.int)(uintptr(oap) + OAP_END + 4)^ >= len - 1) {
						n += 1
					}
					if n == 0 && (^C.int)(uintptr(oap) + OAP_START + 8)^ != (^C.int)(uintptr(oap) + OAP_END + 8)^ {
						n = 1
					}
					if gchar_cursor() != 0 {
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
					}
				}
				fixpos := virtual_op_g == TriState.kFalse
				use_dc := op_type == OP_DELETE_O && !is_visual
				del_bytes(n, fixpos, use_dc)
			} else {
				curpos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				if u_save((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + line_count) == 0 {
					return FAIL
				}
				curbuf_splice_pending_g += 1
				startpos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				deleted_bytes := get_region_bytecount(curbuf, startpos.lnum, end_lnum, startpos.col, end_col)
				if inclusive {
					deleted_bytes += 1
				}
				truncate_line(1)
				curpos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
				del_lines(line_count - 2, false)
				n := end_col + 1
				if !inclusive {
					n -= 1
				}
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
				del_bytes(n, virtual_op_g == TriState.kFalse, op_type == OP_DELETE_O && !is_visual)
				(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = curpos
				do_join(2, false, false, false, false)
				curbuf_splice_pending_g -= 1
				extmark_splice(curbuf, startpos.lnum - 1, startpos.col, line_count - 1, n, i64(deleted_bytes), 0, 0, 0, kExtmarkUndo)
			}
			if op_type == OP_DELETE_O {
				auto_format(false, true)
			}
		}
		msgmore_r((^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ - old_lcount)
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		if motion_type == kMTBlockWise {
			(^C.int)(uintptr(curbuf) + B_OP_END)^ = end_lnum
			(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ = start_col
		} else {
			(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		}
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
	}
	return OK
}

@(export)
op_replace :: proc "c" (oap: rawptr, c_in: C.int) -> C.int {
	context = runtime.default_context()
	c := c_in
	n: C.int
	bd := Block_Def{}
	after_p: ^u8 = nil
	had_ctrl_v_cr := false
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
	wbuf := (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if (ml.flags & ML_EMPTY_O) != 0 || (^bool)(uintptr(oap) + OAP_EMPTY_O)^ {
		return OK
	}
	if c == REPLACE_CR_NCHAR_O {
		had_ctrl_v_cr = true
		c = C.int(CAR)
	} else if c == REPLACE_NL_NCHAR_O {
		had_ctrl_v_cr = true
		c = NL_O
	}
	mb_adjust_opend_o(oap)
	start_lnum = (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	if u_save(start_lnum - 1, end_lnum + 1) == 0 {
		return FAIL
	}
	if motion_type == kMTBlockWise {
		if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
			bd.is_MAX = 1
		}
		for (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ <= end_lnum {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
			block_prep(oap, &bd, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, true)
			skip_line := false
			if bd.textlen == 0 {
				if virtual_op_g == TriState.kFalse {
					skip_line = true
				}
				if bd.is_MAX != 0 {
					skip_line = true
				}
			}
			if skip_line && (virtual_op_g == TriState.kFalse || bd.is_MAX != 0) {
			}
			if !(bd.textlen == 0 && (virtual_op_g == TriState.kFalse || bd.is_MAX != 0)) {
				n = 0
				if virtual_op_g != TriState.kFalse && bd.is_short != 0 && ([^]u8)(bd.textstart)[0] == 0 {
					vpos := Pos_T{(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0, 0}
					getvpos(curwin, &vpos, (^C.int)(uintptr(oap) + OAP_START_VCOL)^)
					bd.startspaces += vpos.coladd
					n = bd.startspaces
				} else {
					if bd.startspaces != 0 {
						n = bd.start_char_vcols - 1
					} else {
						n = 0
					}
				}
				post := C.int(0)
				if bd.endspaces != 0 && bd.is_oneChar == 0 && bd.end_char_vcols > 0 {
					post = bd.end_char_vcols - 1
				}
				n += post
				numc := (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - (^C.int)(uintptr(oap) + OAP_START_VCOL)^ + 1
				if bd.is_short != 0 {
					short_ok := false
					if virtual_op_g == TriState.kFalse {
						short_ok = true
					}
					if bd.is_MAX != 0 {
						short_ok = true
					}
					if short_ok {
						numc -= ((^C.int)(uintptr(oap) + OAP_END_VCOL)^ - bd.end_vcol) + 1
					}
				}
				if utf_char2cells_e(c) > 1 {
					if (numc & 1) != 0 && bd.is_short == 0 {
						bd.endspaces += 1
						n += 1
					}
					numc = numc / 2
				}
				num_chars := numc
				numc *= utf_char2len_r(c)
				oldp := get_cursor_line_ptr()
				oldlen := get_cursor_line_len()
				newp_size := C.size_t(bd.textcol) + C.size_t(bd.startspaces)
				if had_ctrl_v_cr || (c != '\r' && c != '\n') {
					newp_size += C.size_t(numc)
					if bd.is_short == 0 {
						newp_size += C.size_t(bd.endspaces + oldlen - bd.textcol - bd.textlen)
					}
				}
				newp := transmute(^u8)(xmallocz(newp_size))
				libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(bd.textcol))
				oldp = transmute(^u8)(rawptr(uintptr(oldp) + uintptr(bd.textcol) + uintptr(bd.textlen)))
				libc.memset(rawptr(uintptr(newp) + uintptr(bd.textcol)), C.int(32), C.size_t(bd.startspaces))
				after_p_len: C.size_t = 0
				col := oldlen - bd.textcol - bd.textlen + 1
				newrows: C.int = 0
				newcols: C.int = 0
				if had_ctrl_v_cr || (c != '\r' && c != '\n') {
					newp_len := bd.textcol + bd.startspaces
					for num_chars -= 1; num_chars >= 0; num_chars -= 1 {
						newp_len += utf_char2bytes(c, transmute(^u8)(rawptr(uintptr(newp) + uintptr(newp_len))))
					}
					if bd.is_short == 0 {
						libc.memset(rawptr(uintptr(newp) + uintptr(newp_len)), C.int(32), C.size_t(bd.endspaces))
						newp_len += bd.endspaces
						libc.memmove(rawptr(uintptr(newp) + uintptr(newp_len)), rawptr(oldp), C.size_t(col))
					}
					newcols = newp_len - bd.textcol
				} else {
					after_p_len = C.size_t(col)
					after_p = transmute(^u8)(xmalloc(after_p_len))
					libc.memmove(rawptr(after_p), rawptr(oldp), after_p_len)
					newrows = 1
				}
				ml_replace((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, newp, false)
				curbuf_splice_pending_g += 1
				baselnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
				if after_p != nil {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
					ml_append(baselnum, after_p, C.int(after_p_len), false)
					appended_lines_mark((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 1)
					(^C.int)(uintptr(oap) + OAP_END)^ += 1
					xfree(rawptr(after_p))
					after_p = nil
				}
				curbuf_splice_pending_g -= 1
				extmark_splice(curbuf, baselnum - 1, bd.textcol, 0, bd.textlen, i64(bd.textlen), newrows, newcols, i64(newrows + newcols), kExtmarkUndo)
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
		}
	} else {
		if motion_type == kMTLineWise {
			(^C.int)(uintptr(oap) + OAP_START + 4)^ = 0
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
			(^C.int)(uintptr(oap) + OAP_END + 4)^ = ml_get_len((^C.int)(uintptr(oap) + OAP_END)^)
			if (^C.int)(uintptr(oap) + OAP_END + 4)^ != 0 {
				(^C.int)(uintptr(oap) + OAP_END + 4)^ -= 1
			}
		} else if !inclusive {
			dec(rawptr(uintptr(oap) + OAP_END))
		}
		for ltoreq_o((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^, (^Pos_T)(uintptr(oap) + OAP_END)^) {
			done := false
			n = gchar_cursor()
			if n != 0 {
				new_byte_len := utf_char2len_r(c)
				old_byte_len := utfc_ptr2len(transmute(cstring)(get_cursor_pos_ptr()))
				if new_byte_len > 1 || old_byte_len > 1 {
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(oap) + OAP_END)^ {
						(^C.int)(uintptr(oap) + OAP_END + 4)^ += new_byte_len - old_byte_len
					}
					replace_character_o(c)
					done = true
				} else {
					if n == TAB_O {
						end_vcol := C.int(0)
						if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(oap) + OAP_END)^ {
							end_vcol = getviscol2((^C.int)(uintptr(oap) + OAP_END + 4)^, (^C.int)(uintptr(oap) + OAP_END + 8)^)
						}
						coladvance_force(getviscol())
						if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(oap) + OAP_END)^ {
							getvpos(curwin, (^Pos_T)(rawptr(uintptr(oap) + OAP_END)), end_vcol)
						}
					}
					if gchar_cursor() != 0 {
						pbyte_o((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^, c)
						done = true
					}
				}
			}
			if !done && virtual_op_g != TriState.kFalse && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(oap) + OAP_END)^ {
				virtcols := (^C.int)(uintptr(oap) + OAP_END + 8)^
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^Pos_T)(uintptr(oap) + OAP_START)^.lnum && (^C.int)(uintptr(oap) + OAP_START + 4)^ == (^C.int)(uintptr(oap) + OAP_END + 4)^ && (^C.int)(uintptr(oap) + OAP_START + 8)^ != 0 {
					virtcols -= (^C.int)(uintptr(oap) + OAP_START + 8)^
				}
				coladvance_force(getviscol2((^C.int)(uintptr(oap) + OAP_END + 4)^, (^C.int)(uintptr(oap) + OAP_END + 8)^) + 1)
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= (virtcols + 1)
				for virtcols >= 0 {
					if utf_char2len_r(c) > 1 {
						replace_character_o(c)
					} else {
						pbyte_o((^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^, c)
					}
					if inc(rawptr(uintptr(curwin) + W_CURSOR_OFF)) == -1 {
						break
					}
					virtcols -= 1
				}
			}
			if inc_cursor() == -1 {
				break
			}
		}
	}
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
	check_cursor(curwin)
	changed_lines(curbuf, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum, (^Pos_T)(uintptr(oap) + OAP_START)^.col, (^Pos_T)(uintptr(oap) + OAP_END)^.lnum + 1, 0, true)
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
	}
	return OK
}

@(export)
op_change :: proc "c" (oap: rawptr) -> C.int {
	context = runtime.default_context()
	pre_textlen: C.int = 0
	pre_indent: C.int = 0
	firstline: ^u8
	bd := Block_Def{}
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	l := (^C.int)(uintptr(oap) + OAP_START + 4)^
	if motion_type == kMTLineWise {
		l = 0
		can_si_g = may_do_si()
	}
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if (ml.flags & ML_EMPTY_O) != 0 {
		if u_save_cursor() == 0 {
			return 0
		}
	} else if op_delete(oap) == 0 {
		return 0
	}
	if l > (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ && ([^]u8)(ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^))[0] != 0 && virtual_op_g == TriState.kFalse {
		inc_cursor()
	}
	if motion_type == kMTBlockWise {
		if virtual_op_g != TriState.kFalse && ((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ > 0 || gchar_cursor() == 0) {
			coladvance_force(getviscol())
		}
		firstline = ml_get((^Pos_T)(uintptr(oap) + OAP_START)^.lnum)
		pre_textlen = ml_get_len((^Pos_T)(uintptr(oap) + OAP_START)^.lnum)
		pre_indent = getwhitecols(transmute(cstring)(firstline))
		bd.textcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
	}
	if motion_type == kMTLineWise {
		fix_indent()
	}
	save_finish_op := finish_op_g
	finish_op_g = false
	retval := edit_e(0, false, 1)
	finish_op_g = save_finish_op
	if motion_type == kMTBlockWise && (^Pos_T)(uintptr(oap) + OAP_START)^.lnum != (^Pos_T)(uintptr(oap) + OAP_END)^.lnum && !got_int {
		firstline = ml_get((^Pos_T)(uintptr(oap) + OAP_START)^.lnum)
		if bd.textcol > pre_indent {
			new_indent := getwhitecols(transmute(cstring)(firstline))
			pre_textlen += new_indent - pre_indent
			bd.textcol += new_indent - pre_indent
		}
		ins_len := ml_get_len((^Pos_T)(uintptr(oap) + OAP_START)^.lnum) - pre_textlen
		if ins_len > 0 {
			ins_text := transmute(^u8)(xmalloc(C.size_t(ins_len) + 1))
			xmemcpyz(rawptr(ins_text), rawptr(uintptr(firstline) + uintptr(bd.textcol)), C.size_t(ins_len))
			linenr := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum + 1
			for linenr <= (^Pos_T)(uintptr(oap) + OAP_END)^.lnum {
				block_prep(oap, &bd, linenr, true)
				if bd.is_short == 0 || virtual_op_g != TriState.kFalse {
					vpos := Pos_T{0, 0, 0}
					if bd.is_short != 0 {
						vpos.lnum = linenr
						getvpos(curwin, &vpos, (^C.int)(uintptr(oap) + OAP_START_VCOL)^)
					} else {
						vpos.coladd = 0
					}
					oldp := ml_get(linenr)
					newp := transmute(^u8)(xmalloc(C.size_t(ml_get_len(linenr)) + C.size_t(vpos.coladd) + C.size_t(ins_len) + 1))
					libc.memmove(rawptr(newp), rawptr(oldp), C.size_t(bd.textcol))
					newlen := bd.textcol
					libc.memset(rawptr(uintptr(newp) + uintptr(newlen)), C.int(32), C.size_t(vpos.coladd))
					newlen += vpos.coladd
					libc.memmove(rawptr(uintptr(newp) + uintptr(newlen)), rawptr(ins_text), C.size_t(ins_len))
					newlen += ins_len
					tail := transmute(^u8)(rawptr(uintptr(oldp) + uintptr(bd.textcol)))
					libc.memmove(rawptr(uintptr(newp) + uintptr(newlen)), rawptr(tail), C.size_t(libc.strlen(transmute(cstring)(tail))) + 1)
					ml_replace(linenr, newp, false)
					extmark_splice_cols(curbuf, linenr - 1, bd.textcol, 0, vpos.coladd + ins_len, kExtmarkUndo)
				}
				linenr += 1
			}
			check_cursor(curwin)
			changed_lines(curbuf, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum + 1, 0, (^Pos_T)(uintptr(oap) + OAP_END)^.lnum + 1, 0, true)
			xfree(rawptr(ins_text))
		}
	}
	auto_format(false, true)
	if retval {
		return 1
	}
	return 0
}

@(export)
adjust_cursor_eol :: proc "c" () {
	context = runtime.default_context()
	cur_ve_flags := get_ve_flags(curwin)
	adj_cursor := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 && gchar_cursor() == 0 && (cur_ve_flags & KOPT_VE_ONEMORE_O) == 0 && (cur_ve_flags & KOPT_VE_ALL_O) == 0 && !(restart_edit != 0 || (State & MODE_INSERT) != 0)
	if !adj_cursor {
		return
	}
	dec_cursor()
	if cur_ve_flags == KOPT_VE_ALL_O {
		scol: C.int
		ecol: C.int
		getvcol(curwin, (^Pos_T)(rawptr(uintptr(curwin) + W_CURSOR_OFF)), &scol, nil, &ecol, 0)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = ecol - scol + 1
	}
}

@(export)
op_insert :: proc "c" (oap: rawptr, count1: C.int) {
	context = runtime.default_context()
	pre_textlen: C.int = 0
	ind_pre_col: C.int = 0
	ind_pre_vcol: C.int = 0
	firstline: ^u8
	bd := Block_Def{}
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
		bd.is_MAX = 1
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	redraw_curbuf_later(UPD_INVERTED_S)
	update_screen()
	if motion_type == kMTBlockWise {
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ > 0 {
			old_ve_flags := (^C.uint)(uintptr(curwin) + W_VE_FLAGS_OFF)^
			if u_save_cursor() == 0 {
				return
			}
			(^C.uint)(uintptr(curwin) + W_VE_FLAGS_OFF)^ = KOPT_VE_ALL_O
			coladvance_force(getviscol())
			if op_type == OP_APPEND_O {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= 1
			}
			(^C.uint)(uintptr(curwin) + W_VE_FLAGS_OFF)^ = old_ve_flags
		}
		block_prep(oap, &bd, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum, true)
		ind_pre_col = getwhitecols_curline()
		ind_pre_vcol = get_indent()
		pre_textlen = ml_get_len((^Pos_T)(uintptr(oap) + OAP_START)^.lnum) - bd.textcol
		if op_type == OP_APPEND_O {
			pre_textlen -= bd.textlen
		}
	}
	if op_type == OP_APPEND_O {
		if motion_type == kMTBlockWise && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ == 0 {
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
			for ([^]u8)(get_cursor_pos_ptr())[0] != 0 && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ < bd.textcol + bd.textlen {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ += 1
			}
			if bd.is_short != 0 && bd.is_MAX == 0 {
				if u_save_cursor() == 0 {
					return
				}
				for i: C.int = 0; i < bd.endspaces; i += 1 {
					ins_char(' ')
				}
				bd.textlen += bd.endspaces
			}
		} else {
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
			check_cursor_col(curwin)
			if ([^]u8)(ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^))[0] != 0 && (^C.int)(uintptr(oap) + OAP_START_VCOL)^ != (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
				inc_cursor()
			}
		}
	}
	t1 := (^Pos_T)(uintptr(oap) + OAP_START)^
	start_insert := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	edit_e(0, false, count1)
	if t1.lnum == (^Pos_T)(uintptr(curbuf) + B_OP_START_ORIG_O)^.lnum && lt_pos_o((^Pos_T)(uintptr(curbuf) + B_OP_START_ORIG_O)^, t1) {
		(^Pos_T)(uintptr(oap) + OAP_START)^ = (^Pos_T)(uintptr(curbuf) + B_OP_START_ORIG_O)^
	}
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != (^Pos_T)(uintptr(oap) + OAP_START)^.lnum || got_int {
		return
	}
	if motion_type == kMTBlockWise {
		ind_post_vcol: C.int = 0
		bd2 := Block_Def{}
		did_indent := false
		ind_post_col := getwhitecols_curline()
		if (^C.int)(uintptr(curbuf) + B_OP_START)^ > ind_pre_col && ind_post_col > ind_pre_col {
			bd.textcol += ind_post_col - ind_pre_col
			ind_post_vcol = get_indent()
			bd.start_vcol += ind_post_vcol - ind_pre_vcol
			did_indent = true
		}
		if (^Pos_T)(uintptr(oap) + OAP_START)^.lnum == (^Pos_T)(uintptr(curbuf) + B_OP_START_ORIG_O)^.lnum && bd.is_MAX == 0 && !did_indent {
			t := getviscol2((^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 4)^, (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 8)^)
			if op_type == OP_INSERT_O && (^C.int)(uintptr(oap) + OAP_START + 4)^ + (^C.int)(uintptr(oap) + OAP_START + 8)^ != (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 4)^ + (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 8)^ {
				(^C.int)(uintptr(oap) + OAP_START + 4)^ = (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 4)^
				pre_textlen -= t - (^C.int)(uintptr(oap) + OAP_START_VCOL)^
				(^C.int)(uintptr(oap) + OAP_START_VCOL)^ = t
			} else if op_type == OP_APPEND_O && (^C.int)(uintptr(oap) + OAP_START + 4)^ + (^C.int)(uintptr(oap) + OAP_START + 8)^ >= (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 4)^ + (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 8)^ {
				(^C.int)(uintptr(oap) + OAP_START + 4)^ = (^C.int)(uintptr(curbuf) + B_OP_START_ORIG_O + 4)^
				pre_textlen += bd.textlen
				pre_textlen -= t - (^C.int)(uintptr(oap) + OAP_START_VCOL)^
				(^C.int)(uintptr(oap) + OAP_START_VCOL)^ = t
				(^C.int)(uintptr(oap) + OAP_OP_TYPE)^ = OP_INSERT_O
				op_type = OP_INSERT_O
			}
		}
		if did_indent && bd.textcol - ind_post_col > 0 {
			(^C.int)(uintptr(oap) + OAP_START + 4)^ += ind_post_col - ind_pre_col
			(^C.int)(uintptr(oap) + OAP_START_VCOL)^ += ind_post_vcol - ind_pre_vcol
			(^C.int)(uintptr(oap) + OAP_END + 4)^ += ind_post_col - ind_pre_col
			(^C.int)(uintptr(oap) + OAP_END_VCOL)^ += ind_post_vcol - ind_pre_vcol
		}
		block_prep(oap, &bd2, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum, true)
		if did_indent && bd.textcol - ind_post_col > 0 {
			(^C.int)(uintptr(oap) + OAP_START + 4)^ -= ind_post_col - ind_pre_col
			(^C.int)(uintptr(oap) + OAP_START_VCOL)^ -= ind_post_vcol - ind_pre_vcol
			(^C.int)(uintptr(oap) + OAP_END + 4)^ -= ind_post_col - ind_pre_col
			(^C.int)(uintptr(oap) + OAP_END_VCOL)^ -= ind_post_vcol - ind_pre_vcol
		}
		short_ok := false
		if bd.is_MAX == 0 {
			short_ok = true
		}
		if bd2.textlen < bd.textlen {
			short_ok = true
		}
		if short_ok {
			if op_type == OP_APPEND_O {
				pre_textlen += bd2.textlen - bd.textlen
				if bd2.endspaces != 0 {
					bd2.textlen -= 1
				}
			}
			bd.textcol = bd2.textcol
			bd.textlen = bd2.textlen
		}
		firstline = ml_get((^Pos_T)(uintptr(oap) + OAP_START)^.lnum)
		len := ml_get_len((^Pos_T)(uintptr(oap) + OAP_START)^.lnum)
		add := bd.textcol
		offset: C.int = 0
		if op_type == OP_APPEND_O {
			add += bd.textlen
			if bd.is_MAX != 0 && start_insert.lnum == Insstart_g.lnum && start_insert.col > Insstart_g.col {
				offset = start_insert.col - Insstart_g.col
				add -= offset
				if (^C.int)(uintptr(oap) + OAP_END_VCOL)^ > offset {
					(^C.int)(uintptr(oap) + OAP_END_VCOL)^ -= offset + 1
				} else {
					return
				}
			}
		}
		if add > len {
			add = len
		}
		firstline = transmute(^u8)(rawptr(uintptr(firstline) + uintptr(add)))
		len -= add
		ins_len := len - pre_textlen - offset
		if pre_textlen >= 0 && ins_len > 0 {
			ins_text := transmute(^u8)(xmalloc(C.size_t(ins_len) + 1))
			xmemcpyz(rawptr(ins_text), rawptr(firstline), C.size_t(ins_len))
			if u_save((^Pos_T)(uintptr(oap) + OAP_START)^.lnum, (^Pos_T)(uintptr(oap) + OAP_END)^.lnum + 1) == 1 {
				block_insert_o(oap, ins_text, C.size_t(ins_len), op_type == OP_INSERT_O, &bd)
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = (^C.int)(uintptr(oap) + OAP_START + 4)^
			check_cursor(curwin)
			xfree(rawptr(ins_text))
		}
	}
	auto_format(false, true)
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
	}
}

hexupper_nr_g: bool = false

@(export)
op_addsub :: proc "c" (oap: rawptr, Prenum1: C.int, g_cmd: bool) {
	context = runtime.default_context()
	bd := Block_Def{}
	change_cnt: C.longlong = 0
	amount := Prenum1
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	disable_fold_update += 1
	if !VIsual_active {
		pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
		if u_save_cursor() == 0 {
			disable_fold_update -= 1
			return
		}
		if do_addsub(op_type, &pos, 0, amount) {
			change_cnt = 1
		}
		disable_fold_update -= 1
		if change_cnt != 0 {
			changed_lines(curbuf, pos.lnum, 0, pos.lnum + 1, 0, true)
		}
	} else {
		length: C.int
		startpos: Pos_T
		if u_save(start_lnum - 1, end_lnum + 1) == 0 {
			disable_fold_update -= 1
			return
		}
		pos := (^Pos_T)(uintptr(oap) + OAP_START)^
		for pos.lnum <= end_lnum {
			if motion_type == kMTBlockWise {
				block_prep(oap, &bd, pos.lnum, false)
				pos.col = bd.textcol
				length = bd.textlen
			} else if motion_type == kMTLineWise {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
				pos.col = 0
				length = ml_get_len(pos.lnum)
			} else {
				if pos.lnum == start_lnum && !(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ {
					dec(rawptr(uintptr(oap) + OAP_END))
					end_lnum = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
				}
				length = ml_get_len(pos.lnum)
				pos.col = 0
				if pos.lnum == start_lnum {
					pos.col += (^Pos_T)(uintptr(oap) + OAP_START)^.col
					length -= (^Pos_T)(uintptr(oap) + OAP_START)^.col
				}
				if pos.lnum == end_lnum {
					length = ml_get_len(end_lnum)
					end_col := (^Pos_T)(uintptr(oap) + OAP_END)^.col
					if end_col > length - 1 {
						end_col = length - 1
					}
					(^C.int)(uintptr(oap) + OAP_END + 4)^ = end_col
					length = end_col - pos.col + 1
				}
			}
			if do_addsub(op_type, &pos, length, amount) {
				if change_cnt == 0 {
					startpos = (^Pos_T)(uintptr(curbuf) + B_OP_START)^
				}
				change_cnt += 1
			}
			if g_cmd && change_cnt != 0 {
				amount += Prenum1
			}
			pos.lnum += 1
		}
		disable_fold_update -= 1
		if change_cnt != 0 {
			changed_lines(curbuf, start_lnum, 0, end_lnum + 1, 0, true)
		}
		if change_cnt == 0 && (^bool)(uintptr(oap) + OAP_IS_VISUAL)^ {
			redraw_curbuf_later(UPD_INVERTED_S)
		}
		if change_cnt > 0 && (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
			(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = startpos
		}
		if i64(change_cnt) > p_report {
			msg := ngettext_r(cstring("%ld lines changed"), cstring("%ld lines changed"), C.long(change_cnt))
			smsg(0, msg, C.longlong(change_cnt))
		}
	}
}

@(export)
do_addsub :: proc "c" (op_type: C.int, pos: ^Pos_T, length_in: C.int, Prenum1: C.int) -> bool {
	context = runtime.default_context()
	pre: C.int = 0
	n: u64 = 0
	blank_unsigned := false
	negative := false
	was_positive := true
	visual := VIsual_active
	did_change := false
	save_cursor := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	maxlen: C.int = 0
	startpos: Pos_T
	endpos: Pos_T
	save_coladd: C.int = 0
	length := length_in
	nf := (^u8)((^rawptr)(uintptr(curbuf) + B_P_NF_OFF)^)
	do_hex := vim_strchr(nf, 'x') != nil
	do_oct := vim_strchr(nf, 'o') != nil
	do_bin := vim_strchr(nf, 'b') != nil
	do_alpha := vim_strchr(nf, 'p') != nil
	do_unsigned := vim_strchr(nf, 'u') != nil
	do_blank := vim_strchr(nf, 'k') != nil
	if virtual_active(curwin) {
		save_coladd = pos.coladd
		pos.coladd = 0
	}
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos^
	ptr := ml_get(pos.lnum)
	linelen := ml_get_len(pos.lnum)
	col := pos.col
	for _ in 0..<1 {
		adj := C.int(0)
		if save_coladd != 0 {
			adj = 1
		}
		if col + adj >= linelen {
			break
		}
		if !VIsual_active {
			if do_bin {
				for col > 0 && ascii_isbdigit(([^]u8)(ptr)[uintptr(col)]) {
					col -= 1
					col -= utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
				}
			}
			if do_hex {
				for col > 0 && ascii_isxdigit(([^]u8)(ptr)[uintptr(col)]) {
					col -= 1
					col -= utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
				}
			}
			hex_overlap := false
			if do_bin && do_hex && col > 0 {
				c0 := ([^]u8)(ptr)[uintptr(col)]
				cm := ([^]u8)(ptr)[uintptr(col) - 1]
				cp := ([^]u8)(ptr)[uintptr(col) + 1]
				if (c0 == 'X' || c0 == 'x') && cm == '0' && utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col) - 1))) == 0 && ascii_isxdigit(cp) {
					hex_overlap = true
				}
			}
			if hex_overlap {
				col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				for col > 0 && ascii_isdigit(([^]u8)(ptr)[uintptr(col)]) {
					col -= 1
					col -= utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
				}
			}
			found_num := false
			if do_hex && col > 0 {
				c0 := ([^]u8)(ptr)[uintptr(col)]
				cm := ([^]u8)(ptr)[uintptr(col) - 1]
				cp := ([^]u8)(ptr)[uintptr(col) + 1]
				if (c0 == 'X' || c0 == 'x') && cm == '0' && utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col) - 1))) == 0 && ascii_isxdigit(cp) {
					found_num = true
				}
			}
			if !found_num && do_bin && col > 0 {
				c0 := ([^]u8)(ptr)[uintptr(col)]
				cm := ([^]u8)(ptr)[uintptr(col) - 1]
				cp := ([^]u8)(ptr)[uintptr(col) + 1]
				if (c0 == 'B' || c0 == 'b') && cm == '0' && utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col) - 1))) == 0 && ascii_isbdigit(cp) {
					found_num = true
				}
			}
			if found_num {
				col -= 1
				col -= utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
			} else {
				col = pos.col
				for ([^]u8)(ptr)[uintptr(col)] != 0 && !ascii_isdigit(([^]u8)(ptr)[uintptr(col)]) {
					take_alpha := false
					if do_alpha && ascii_isalpha_o(([^]u8)(ptr)[uintptr(col)]) {
						take_alpha = true
					}
					if take_alpha {
						break
					}
					col += 1
				}
				for col > 0 && ascii_isdigit(([^]u8)(ptr)[uintptr(col) - 1]) {
					take_alpha := false
					if do_alpha && ascii_isalpha_o(([^]u8)(ptr)[uintptr(col) - 1]) {
						take_alpha = true
					}
					if take_alpha {
						break
					}
					col -= 1
				}
			}
		}
		if visual {
			for ([^]u8)(ptr)[uintptr(col)] != 0 && length > 0 && !ascii_isdigit(([^]u8)(ptr)[uintptr(col)]) {
				take_alpha := false
				if do_alpha && ascii_isalpha_o(([^]u8)(ptr)[uintptr(col)]) {
					take_alpha = true
				}
				if take_alpha {
					break
				}
				mb_len := utfc_ptr2len(transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))))
				col += mb_len
				length -= mb_len
			}
			if length == 0 {
				break
			}
			if col > pos.col && ([^]u8)(ptr)[uintptr(col) - 1] == '-' && utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col) - 1))) == 0 && !do_unsigned {
				if do_blank && col >= 2 && !ascii_iswhite(([^]u8)(ptr)[uintptr(col) - 2]) {
					blank_unsigned = true
				} else {
					negative = true
					was_positive = false
				}
			}
		}
		firstdigit := C.int(([^]u8)(ptr)[uintptr(col)])
		if !ascii_isdigit(u8(firstdigit)) {
			take_alpha := false
			if do_alpha && ascii_isalpha_o(u8(firstdigit)) {
				take_alpha = true
			}
			if !take_alpha {
				beep_flush_r()
				break
			}
		}
		if do_alpha && ascii_isalpha_o(u8(firstdigit)) {
			if op_type == OP_NR_SUB_O {
				ord := C.int(0)
				if firstdigit < 'a' {
					ord = firstdigit - 'A'
				} else {
					ord = firstdigit - 'a'
				}
				if ord < Prenum1 {
					if firstdigit >= 'A' && firstdigit <= 'Z' {
						firstdigit = 'A'
					} else {
						firstdigit = 'a'
					}
				} else {
					firstdigit -= Prenum1
				}
			} else {
				ord := C.int(0)
				if firstdigit < 'a' {
					ord = firstdigit - 'A'
				} else {
					ord = firstdigit - 'a'
				}
				if 26 - ord - 1 < Prenum1 {
					if firstdigit >= 'A' && firstdigit <= 'Z' {
						firstdigit = 'Z'
					} else {
						firstdigit = 'z'
					}
				} else {
					firstdigit += Prenum1
				}
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
			startpos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			did_change = true
			del_char(false)
			ins_char(firstdigit)
			endpos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
		} else {
			if col > 0 && ([^]u8)(ptr)[uintptr(col) - 1] == '-' && utf_head_off(transmute(cstring)(ptr), transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col) - 1))) == 0 && !visual && !do_unsigned {
				if do_blank && col >= 2 && !ascii_iswhite(([^]u8)(ptr)[uintptr(col) - 2]) {
					blank_unsigned = true
				} else {
					col -= 1
					negative = true
				}
			}
			if visual && VIsual_mode != 'V' {
				if (^C.int)(uintptr(curbuf) + B_VISUAL + 24)^ == MAXCOL {
					maxlen = linelen - col
				} else {
					maxlen = length
				}
			}
			overflow := false
			what := C.int(0)
			if do_bin {
				what += STR2NR_BIN_O
			}
			if do_oct {
				what += STR2NR_OCT_O
			}
			if do_hex {
				what += STR2NR_HEX_O
			}
			vim_str2nr(transmute(cstring)(rawptr(uintptr(ptr) + uintptr(col))), transmute(^cstring)(&pre), &length, what, nil, &n, C.size_t(maxlen), false, &overflow)
			if pre != 0 && negative {
				col += 1
				length -= 1
				negative = false
			}
			subtract := false
			if op_type == OP_NR_SUB_O {
				subtract = !subtract
			}
			if negative {
				subtract = !subtract
			}
			oldn := n
			if !overflow {
				if subtract {
					n = n - u64(Prenum1)
				} else {
					n = n + u64(Prenum1)
				}
			}
			if pre == 0 {
				if subtract {
					if n > oldn {
						n = 1 + (n ~ max(u64))
						negative = !negative
					}
				} else {
					if n < oldn {
						n = (n ~ max(u64))
						negative = !negative
					}
				}
				if n == 0 {
					negative = false
				}
			}
			if (do_unsigned || blank_unsigned) && negative {
				if subtract {
					n = 0
				} else {
					n = max(u64)
				}
				negative = false
			}
			if visual && !was_positive && !negative && col > 0 {
				col -= 1
				length += 1
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
			startpos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			did_change = true
			todel := length
			c := gchar_cursor()
			if c == '-' {
				length -= 1
			}
			for todel > 0 {
				todel -= 1
				if c < 0x100 && c >= 'A' {
					is_alpha := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
					if is_alpha {
						hexupper_nr_g = c >= 'A' && c <= 'Z'
					}
				}
				del_char(false)
				c = gchar_cursor()
			}
			buf1 := transmute(^u8)(xmalloc(C.size_t(length) + C.size_t(NUMBUFLEN)))
			bp := buf1
			if negative && (!visual || was_positive) {
				([^]u8)(bp)[0] = '-'
				bp = transmute(^u8)(rawptr(uintptr(bp) + 1))
			}
			if pre != 0 {
				([^]u8)(bp)[0] = '0'
				bp = transmute(^u8)(rawptr(uintptr(bp) + 1))
				length -= 1
			}
			if pre == 'b' || pre == 'B' || pre == 'x' || pre == 'X' {
				([^]u8)(bp)[0] = u8(pre)
				bp = transmute(^u8)(rawptr(uintptr(bp) + 1))
				length -= 1
			}
			buf2: [65]u8
			buf2len: C.int = 0
			if pre == 'b' || pre == 'B' {
				bits := C.size_t(8 * size_of(n))
				for bits > 0 {
					if ((n >> (bits - 1)) & 0x1) != 0 {
						break
					}
					bits -= 1
				}
				for bits > 0 && buf2len < 64 {
					ch: u8 = '0'
					bits -= 1
					if ((n >> bits) & 0x1) != 0 {
						ch = '1'
					}
					buf2[buf2len] = ch
					buf2len += 1
				}
				buf2[buf2len] = 0
			} else if pre == 0 {
				buf2len = vim_snprintf(&buf2[0], 65, cstring("%lu"), C.ulong(n))
			} else if pre == '0' {
				buf2len = vim_snprintf(&buf2[0], 65, cstring("%lo"), C.ulong(n))
			} else if hexupper_nr_g {
				buf2len = vim_snprintf(&buf2[0], 65, cstring("%lX"), C.ulong(n))
			} else {
				buf2len = vim_snprintf(&buf2[0], 65, cstring("%lx"), C.ulong(n))
			}
			length -= buf2len
			if firstdigit == '0' {
				oct_guard := false
				if do_oct && pre == '0' {
					oct_guard = true
				}
				if !oct_guard {
					for length > 0 {
						length -= 1
						([^]u8)(bp)[0] = '0'
						bp = transmute(^u8)(rawptr(uintptr(bp) + 1))
					}
				}
			}
			([^]u8)(bp)[0] = 0
			buf1len := C.int(uintptr(bp) - uintptr(buf1))
			libc.memmove(rawptr(uintptr(buf1) + uintptr(buf1len)), rawptr(&buf2[0]), C.size_t(buf2len))
			buf1len += buf2len
			ins_str(buf1, C.size_t(buf1len))
			xfree(rawptr(buf1))
			endpos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ != 0 {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ -= 1
			}
		}
		if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
			(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = startpos
			(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = endpos
			if (^C.int)(uintptr(curbuf) + B_OP_END + 4)^ > 0 {
				(^C.int)(uintptr(curbuf) + B_OP_END + 4)^ -= 1
			}
		}
		break
	}
	if visual {
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = save_cursor
	} else if did_change {
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	} else if virtual_active(curwin) {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = save_coladd
	}
	return did_change
}

op_colon_o :: proc "c" (oap: rawptr) {
	context = runtime.default_context()
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	is_visual := (^bool)(uintptr(oap) + OAP_IS_VISUAL)^
	start_lnum := (^Pos_T)(uintptr(oap) + OAP_START)^.lnum
	end_lnum := (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
	stuffcharReadbuff_r(':')
	if is_visual {
		stuffReadbuff_r(cstring("'<,'>"))
	} else {
		if start_lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
			stuffcharReadbuff_r('.')
		} else {
			stuffnumReadbuff_e(start_lnum)
		}
		endOfStartFold := start_lnum
		hasFolding(curwin, start_lnum, nil, &endOfStartFold)
		if end_lnum != start_lnum && end_lnum != endOfStartFold {
			stuffcharReadbuff_r(',')
			if end_lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
				stuffcharReadbuff_r('.')
			} else if end_lnum == (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
				stuffcharReadbuff_r('$')
			} else if start_lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ && !hasFolding(curwin, end_lnum, nil, nil) {
				stuffReadbuff_r(cstring(".+"))
				stuffnumReadbuff_e(line_count - 1)
			} else {
				stuffnumReadbuff_e(end_lnum)
			}
		}
	}
	if op_type != OP_COLON_O {
		stuffReadbuff_r(cstring("!"))
	}
	if op_type == OP_INDENT_O {
		stuffReadbuff_r(transmute(cstring)(get_equalprg()))
		stuffReadbuff_r(cstring("\n"))
	} else if op_type == OP_FORMAT_O {
		b_fp := (^u8)((^rawptr)(uintptr(curbuf) + B_P_FP_OFF)^)
		if b_fp != nil && ([^]u8)(b_fp)[0] != 0 {
			stuffReadbuff_r(transmute(cstring)(b_fp))
		} else if p_fp_g != nil && ([^]u8)(transmute(^u8)(p_fp_g))[0] != 0 {
			stuffReadbuff_r(p_fp_g)
		} else {
			stuffReadbuff_r(cstring("fmt"))
		}
		stuffReadbuff_r(cstring("\n']"))
	}
}

@(export)
opfunc_cb: Callback_E

@(export)
did_set_operatorfunc :: proc "c" (args: rawptr) -> cstring {
	context = runtime.default_context()
	if option_set_callback_func(transmute(^u8)(p_opfunc_g), rawptr(&opfunc_cb)) == 0 {
		return e_invarg_s
	}
	return nil
}

@(export)
set_ref_in_opfunc :: proc "c" (copyID: C.int) -> bool {
	context = runtime.default_context()
	return set_ref_in_callback(&opfunc_cb, copyID, nil, nil)
}

opfunc_block_s: [6]u8 = {'b', 'l', 'o', 'c', 'k', 0}
opfunc_line_s: [5]u8 = {'l', 'i', 'n', 'e', 0}
opfunc_char_s: [5]u8 = {'c', 'h', 'a', 'r', 0}

op_function_o :: proc "c" (oap: rawptr) {
	context = runtime.default_context()
	motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
	inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
	orig_start := (^Pos_T)(uintptr(curbuf) + B_OP_START)^
	orig_end := (^Pos_T)(uintptr(curbuf) + B_OP_END)^
	if p_opfunc_g == nil || ([^]u8)(transmute(^u8)(p_opfunc_g))[0] == 0 {
		emsg(cstring("E774: 'operatorfunc' is empty"))
	} else {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(oap) + OAP_END)^
		if motion_type != kMTLineWise && !inclusive {
			dec(rawptr(uintptr(curbuf) + B_OP_END))
		}
		argv: [2]Typval_T
		argv[0].v_type = VAR_STRING
		argv[1].v_type = VAR_UNKNOWN
		if motion_type == kMTBlockWise {
			argv[0].vval = rawptr(&opfunc_block_s[0])
		} else if motion_type == kMTLineWise {
			argv[0].vval = rawptr(&opfunc_line_s[0])
		} else {
			argv[0].vval = rawptr(&opfunc_char_s[0])
		}
		save_virtual_op := virtual_op_g
		virtual_op_g = TriState.kNone
		save_finish_op := finish_op_g
		finish_op_g = false
		rettv: Typval_T
		if callback_call(rawptr(&opfunc_cb), 1, &argv[0], &rettv) {
			tv_clear(&rettv)
		}
		virtual_op_g = save_virtual_op
		finish_op_g = save_finish_op
		if (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
			(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = orig_start
			(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = orig_end
		}
	}
}

get_op_vcol_o :: proc "c" (oap: rawptr, redo_VIsual_vcol: C.int, initial: bool) {
	context = runtime.default_context()
	start: C.int
	end: C.int
	if VIsual_mode != Ctrl_V || (!initial && (^C.int)(uintptr(oap) + OAP_END + 4)^ < (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^) {
		return
	}
	(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTBlockWise
	mark_mb_adjustpos((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_END)))
	getvvcol(curwin, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_START)), transmute(^C.int)(rawptr(uintptr(oap) + OAP_START_VCOL)), nil, transmute(^C.int)(rawptr(uintptr(oap) + OAP_END_VCOL)), 0)
	if !redo_VIsual_busy_g {
		getvvcol(curwin, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_END)), &start, nil, &end, 0)
		start_vcol := (^C.int)(uintptr(oap) + OAP_START_VCOL)^
		if start < start_vcol {
			start_vcol = start
		}
		(^C.int)(uintptr(oap) + OAP_START_VCOL)^ = start_vcol
		if end > (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
			if initial && ([^]u8)(p_sel)[0] == 'e' && start >= 1 && start - 1 >= (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
				(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = start - 1
			} else {
				(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = end
			}
		}
	}
	if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = MAXCOL
		(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = 0
		for (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^.lnum; (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ <= (^Pos_T)(uintptr(oap) + OAP_END)^.lnum; (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1 {
			getvvcol(curwin, (^Pos_T)(rawptr(uintptr(curwin) + W_CURSOR_OFF)), nil, nil, &end, 0)
			if end > (^C.int)(uintptr(oap) + OAP_END_VCOL)^ {
				(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = end
			}
		}
	} else if redo_VIsual_busy_g {
		(^C.int)(uintptr(oap) + OAP_END_VCOL)^ = (^C.int)(uintptr(oap) + OAP_START_VCOL)^ + redo_VIsual_vcol - 1
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum
	coladvance(curwin, (^C.int)(uintptr(oap) + OAP_END_VCOL)^)
	(^Pos_T)(uintptr(oap) + OAP_END)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
	coladvance(curwin, (^C.int)(uintptr(oap) + OAP_START_VCOL)^)
	(^Pos_T)(uintptr(oap) + OAP_START)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
}

line_count_info_o :: proc "c" (line: ^u8, wc: ^C.longlong, cc: ^C.longlong, limit: C.longlong, eol_size: C.int) -> C.longlong {
	context = runtime.default_context()
	i: C.longlong = 0
	words: C.longlong = 0
	chars: C.longlong = 0
	is_word := false
	for i < limit && ([^]u8)(line)[uintptr(i)] != 0 {
		if is_word {
			if ascii_isspace_o(C.int(([^]u8)(line)[uintptr(i)])) {
				words += 1
				is_word = false
			}
		} else if !ascii_isspace_o(C.int(([^]u8)(line)[uintptr(i)])) {
			is_word = true
		}
		chars += 1
		i += C.longlong(utfc_ptr2len(transmute(cstring)(rawptr(uintptr(line) + uintptr(i)))))
	}
	if is_word {
		words += 1
	}
	wc^ += words
	if i < limit && ([^]u8)(line)[uintptr(i)] == 0 {
		i += C.longlong(eol_size)
		chars += C.longlong(eol_size)
	}
	cc^ += chars
	return i
}

linetabsize_str_o :: proc "c" (s: ^u8) -> C.int {
	context = runtime.default_context()
	return linetabsize_col(0, s)
}

@(export)
cursor_pos_info :: proc "c" (dict: rawptr) {
	context = runtime.default_context()
	buf1: [50]u8
	buf2: [40]u8
	byte_count: C.longlong = 0
	bom_count: C.longlong = 0
	byte_count_cursor: C.longlong = 0
	char_count: C.longlong = 0
	char_count_cursor: C.longlong = 0
	word_count: C.longlong = 0
	word_count_cursor: C.longlong = 0
	min_pos: Pos_T
	max_pos: Pos_T
	oa: [88]u8
	libc.memset(&oa[0], 0, 88)
	bd := Block_Def{}
	l_VIsual_active := VIsual_active
	l_VIsual_mode := VIsual_mode
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if (ml.flags & ML_EMPTY_O) != 0 {
		if dict == nil {
			msg_e(cstring("--No lines in buffer--"), 0)
			return
		}
	} else {
		eol_size: C.int = 1
		if get_fileformat(curbuf) == EOL_DOS_S {
			eol_size = 2
		}
		last_check: C.longlong = 100000
		line_count_selected: C.int = 0
		line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		if l_VIsual_active {
			if lt_pos_o(VIsual_g, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^) {
				min_pos = VIsual_g
				max_pos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			} else {
				min_pos = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				max_pos = VIsual_g
			}
			if ([^]u8)(p_sel)[0] == 'e' && max_pos.col > 0 {
				max_pos.col -= 1
			}
			if l_VIsual_mode == Ctrl_V {
				saved_sbr := p_sbr_g
				saved_w_sbr := (^u8)((^rawptr)(uintptr(curwin) + W_P_SBR_OFF)^)
				p_sbr_g = empty_string_opt()
				(^rawptr)(uintptr(curwin) + W_P_SBR_OFF)^ = rawptr(empty_string_opt())
				(^bool)(uintptr(rawptr(&oa[0])) + OAP_IS_VISUAL)^ = true
				(^C.int)(uintptr(rawptr(&oa[0])) + OAP_MOTION_TYPE)^ = kMTBlockWise
				(^C.int)(uintptr(rawptr(&oa[0])) + OAP_OP_TYPE)^ = OP_NOP_O
				getvcols(curwin, &min_pos, &max_pos, transmute(^C.int)(rawptr(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)), transmute(^C.int)(rawptr(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)), 0)
				p_sbr_g = saved_sbr
				(^rawptr)(uintptr(curwin) + W_P_SBR_OFF)^ = rawptr(saved_w_sbr)
				if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
					(^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ = MAXCOL
				}
				if (^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ < (^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^ {
					(^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ += (^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^
					(^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^ = (^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ - (^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^
					(^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ -= (^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^
				}
			}
			line_count_selected = max_pos.lnum - min_pos.lnum + 1
		}
		lnum: C.int = 1
		for lnum <= line_count {
			if byte_count > last_check {
				os_breakcheck()
				if got_int {
					return
				}
				last_check = byte_count + 100000
			}
			on_select := false
			if l_VIsual_active && lnum >= min_pos.lnum && lnum <= max_pos.lnum {
				on_select = true
			}
			if on_select {
				s: ^u8 = nil
				len: C.int = 0
				if l_VIsual_mode == Ctrl_V {
					if virtual_active(curwin) {
						virtual_op_g = TriState.kTrue
					} else {
						virtual_op_g = TriState.kFalse
					}
					block_prep(rawptr(&oa[0]), &bd, lnum, false)
					virtual_op_g = TriState.kNone
					s = bd.textstart
					len = bd.textlen
				} else if l_VIsual_mode == 'V' {
					s = ml_get(lnum)
					len = MAXCOL
				} else {
					start_col: C.int = 0
					if lnum == min_pos.lnum {
						start_col = min_pos.col
					}
					end_col: C.int = MAXCOL
					if lnum == max_pos.lnum {
						end_col = max_pos.col - start_col + 1
					}
					s = transmute(^u8)(rawptr(uintptr(ml_get(lnum)) + uintptr(start_col)))
					len = end_col
				}
				if s != nil {
					byte_count_cursor += line_count_info_o(s, &word_count_cursor, &char_count_cursor, C.longlong(len), eol_size)
					if lnum == line_count && (^C.int)(uintptr(curbuf) + B_P_EOL_OFF)^ == 0 && ((^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ != 0 || (^C.int)(uintptr(curbuf) + B_P_FIXEOL_OFF)^ == 0) && C.int(libc.strlen(transmute(cstring)(s))) < len {
						byte_count_cursor -= C.longlong(eol_size)
					}
				}
			} else {
				if lnum == (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ {
					word_count_cursor += word_count
					char_count_cursor += char_count
					byte_count_cursor = byte_count + line_count_info_o(ml_get(lnum), &word_count_cursor, &char_count_cursor, C.longlong((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^) + 1, eol_size)
				}
			}
			byte_count += line_count_info_o(ml_get(lnum), &word_count, &char_count, C.longlong(MAXCOL), eol_size)
			lnum += 1
		}
		if (^C.int)(uintptr(curbuf) + B_P_EOL_OFF)^ == 0 && ((^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ != 0 || (^C.int)(uintptr(curbuf) + B_P_FIXEOL_OFF)^ == 0) {
			byte_count -= C.longlong(eol_size)
		}
		if dict == nil {
			if l_VIsual_active {
				if l_VIsual_mode == Ctrl_V && (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ < MAXCOL {
					getvcols(curwin, &min_pos, &max_pos, &min_pos.col, &max_pos.col, 0)
					cols := C.longlong((^C.int)(uintptr(rawptr(&oa[0])) + OAP_END_VCOL)^ + 1) - C.longlong((^C.int)(uintptr(rawptr(&oa[0])) + OAP_START_VCOL)^)
					vim_snprintf(&buf1[0], 50, cstring("%lld Cols; "), cols)
				} else {
					buf1[0] = 0
				}
				if char_count_cursor == byte_count_cursor && char_count == byte_count {
					vim_snprintf(&IObuff[0], C.size_t(IOSIZE_O), cstring("Selected %s%lld of %lld Lines; %lld of %lld Words; %lld of %lld Bytes"), transmute(cstring)(&buf1[0]), C.longlong(line_count_selected), C.longlong(line_count), word_count_cursor, word_count, byte_count_cursor, byte_count)
				} else {
					vim_snprintf(&IObuff[0], C.size_t(IOSIZE_O), cstring("Selected %s%lld of %lld Lines; %lld of %lld Words; %lld of %lld Chars; %lld of %lld Bytes"), transmute(cstring)(&buf1[0]), C.longlong(line_count_selected), C.longlong(line_count), word_count_cursor, word_count, char_count_cursor, char_count, byte_count_cursor, byte_count)
				}
			} else {
				p := get_cursor_line_ptr()
				validate_virtcol(curwin)
				col_print(&buf1[0], 50, (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ + 1, (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ + 1)
				col_print(&buf2[0], 40, get_cursor_line_len(), linetabsize_str_o(p))
				if char_count_cursor == byte_count_cursor && char_count == byte_count {
					vim_snprintf(&IObuff[0], C.size_t(IOSIZE_O), cstring("Col %s of %s; Line %lld of %lld; Word %lld of %lld; Byte %lld of %lld"), transmute(cstring)(&buf1[0]), transmute(cstring)(&buf2[0]), C.longlong((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^), C.longlong(line_count), word_count_cursor, word_count, byte_count_cursor, byte_count)
				} else {
					vim_snprintf(&IObuff[0], C.size_t(IOSIZE_O), cstring("Col %s of %s; Line %lld of %lld; Word %lld of %lld; Char %lld of %lld; Byte %lld of %lld"), transmute(cstring)(&buf1[0]), transmute(cstring)(&buf2[0]), C.longlong((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^), C.longlong(line_count), word_count_cursor, word_count, char_count_cursor, char_count, byte_count_cursor, byte_count)
				}
			}
		}
		bom_count = C.longlong(bomb_size_e())
		if dict == nil && bom_count > 0 {
			io_len := libc.strlen(transmute(cstring)(&IObuff[0]))
			vim_snprintf(transmute(^u8)(rawptr(uintptr(&IObuff[0]) + uintptr(io_len))), C.size_t(IOSIZE_O) - io_len, cstring("(+%lld for BOM)"), bom_count)
		}
		if dict == nil {
			save_shm := p_shm
			p_shm = empty_string_opt()
			if p_ch < 1 {
				msg_start()
				msg_scroll = 1
			}
			msg_e(transmute(cstring)(&IObuff[0]), 0)
			p_shm = save_shm
		}
	}
	if dict != nil {
		tv_dict_add_nr(dict, cstring("words"), 5, word_count)
		tv_dict_add_nr(dict, cstring("chars"), 5, char_count)
		tv_dict_add_nr(dict, cstring("bytes"), 5, byte_count + bom_count)
		if l_VIsual_active {
			tv_dict_add_nr(dict, cstring("visual_bytes"), 12, byte_count_cursor)
			tv_dict_add_nr(dict, cstring("visual_chars"), 12, char_count_cursor)
			tv_dict_add_nr(dict, cstring("visual_words"), 12, word_count_cursor)
		} else {
			tv_dict_add_nr(dict, cstring("cursor_bytes"), 12, byte_count_cursor)
			tv_dict_add_nr(dict, cstring("cursor_chars"), 12, char_count_cursor)
			tv_dict_add_nr(dict, cstring("cursor_words"), 12, word_count_cursor)
		}
	}
}

@(export)
do_join :: proc "c" (count: C.size_t, insert_space: bool, save_undo: bool, use_formatoptions: bool, setmark: bool) -> C.int {
	context = runtime.default_context()
	curr: ^u8 = nil
	curr_start: ^u8 = nil
	cend: ^u8
	endcurr1: C.int = 0
	endcurr2: C.int = 0
	currsize: C.int = 0
	sumsize: C.int = 0
	ret: C.int = OK
	comments: ^C.int = nil
	remove_comments := use_formatoptions && has_format_option(C.int(FO_REMOVE_COMS_O))
	prev_was_comment := false
	if count < 1 {
		libc.abort()
	}
	if save_undo && u_save((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + C.int(count)) == 0 {
		return FAIL
	}
	spaces := transmute(^u8)(xcalloc(count, 1))
	if remove_comments {
		comments = transmute(^C.int)(xcalloc(count, 4))
	}
	t: C.int = 0
	for t < C.int(count) {
		curr_start = ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + t)
		curr = curr_start
		if t == 0 && setmark && (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
			(^C.int)(uintptr(curwin) + B_OP_START)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
			(^C.int)(uintptr(curwin) + B_OP_START + 4)^ = C.int(libc.strlen(transmute(cstring)(curr)))
		}
		if remove_comments {
			if t > 0 && prev_was_comment {
				new_curr := skip_comment(curr, true, insert_space, &prev_was_comment)
				([^]C.int)(comments)[uintptr(t)] = C.int(uintptr(new_curr) - uintptr(curr))
				curr = new_curr
			} else {
				curr = skip_comment(curr, false, insert_space, &prev_was_comment)
			}
		}
		if insert_space && t > 0 {
			curr = transmute(^u8)(skipwhite(transmute(cstring)(curr)))
			join_ok := false
			if ([^]u8)(curr)[0] != 0 && ([^]u8)(curr)[0] != ')' && sumsize != 0 && endcurr1 != 9 {
				join_ok = true
			}
			if join_ok && has_format_option(C.int(FO_MBYTE_JOIN_O)) {
				c0 := utf_ptr2char(transmute(cstring)(curr))
				if !(c0 < 0x100 && endcurr1 < 0x100) {
					join_ok = false
				}
			}
			if join_ok && has_format_option(C.int(FO_MBYTE_JOIN2_O)) {
				c0 := utf_ptr2char(transmute(cstring)(curr))
				if !((c0 < 0x100 && !utf_eat_space_e(endcurr1)) || (endcurr1 < 0x100 && !utf_eat_space_e(c0))) {
					join_ok = false
				}
			}
			if join_ok {
				if endcurr1 == ' ' {
					endcurr1 = endcurr2
				} else {
					([^]u8)(spaces)[uintptr(t)] += 1
				}
				if p_js != 0 && (endcurr1 == '.' || endcurr1 == '?' || endcurr1 == '!') {
					([^]u8)(spaces)[uintptr(t)] += 1
				}
			}
		}
		if t > 0 && curbuf_splice_pending_g == 0 {
			removed := C.int(uintptr(curr) - uintptr(curr_start))
			extmark_splice(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, sumsize, 1, removed, i64(removed + 1), 0, C.int(([^]u8)(spaces)[uintptr(t)]), i64(([^]u8)(spaces)[uintptr(t)]), kExtmarkUndo)
		}
		currsize = C.int(libc.strlen(transmute(cstring)(curr)))
		sumsize += currsize + C.int(([^]u8)(spaces)[uintptr(t)])
		endcurr1 = 0
		endcurr2 = 0
		if insert_space && currsize > 0 {
			cend = transmute(^u8)(rawptr(uintptr(curr) + uintptr(currsize)))
			cend = mb_ptr_back(curr, cend)
			endcurr1 = utf_ptr2char(transmute(cstring)(cend))
			if uintptr(cend) > uintptr(curr) {
				cend = mb_ptr_back(curr, cend)
				endcurr2 = utf_ptr2char(transmute(cstring)(cend))
			}
		}
		line_breakcheck()
		if got_int {
			ret = FAIL
			break
		}
		t += 1
	}
	if ret != FAIL {
		col := sumsize - currsize - C.int(([^]u8)(spaces)[uintptr(C.int(count) - 1)])
		newp_len := C.size_t(sumsize)
		newp := transmute(^u8)(xmallocz(newp_len))
		cend = transmute(^u8)(rawptr(uintptr(newp) + uintptr(sumsize)))
		curbuf_splice_pending_g += 1
		t = C.int(count) - 1
		for {
			cend = transmute(^u8)(rawptr(uintptr(cend) - uintptr(currsize)))
			libc.memmove(rawptr(cend), rawptr(curr), C.size_t(currsize))
			if ([^]u8)(spaces)[uintptr(t)] > 0 {
				cend = transmute(^u8)(rawptr(uintptr(cend) - uintptr(([^]u8)(spaces)[uintptr(t)])))
				libc.memset(rawptr(cend), C.int(32), C.size_t(([^]u8)(spaces)[uintptr(t)]))
			}
			spaces_removed := C.int(uintptr(curr) - uintptr(curr_start)) - C.int(([^]u8)(spaces)[uintptr(t)])
			lnum := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + t
			mincol: C.int = 0
			lnum_amount := -t
			col_amount := C.int(uintptr(cend) - uintptr(newp) - uintptr(spaces_removed))
			mark_col_adjust(lnum, mincol, lnum_amount, col_amount, spaces_removed)
			if t == 0 {
				break
			}
			curr_start = ml_get((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + t - 1)
			curr = curr_start
			if remove_comments {
				curr = transmute(^u8)(rawptr(uintptr(curr) + uintptr(([^]C.int)(comments)[uintptr(t) - 1])))
			}
			if insert_space && t > 1 {
				curr = transmute(^u8)(skipwhite(transmute(cstring)(curr)))
			}
			currsize = C.int(libc.strlen(transmute(cstring)(curr)))
			t -= 1
		}
		ml_replace_len((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, newp, newp_len, false)
		if setmark && (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
			(^C.int)(uintptr(curwin) + B_OP_END)^ = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
			(^C.int)(uintptr(curwin) + B_OP_END + 4)^ = sumsize
		}
		changed_lines(curbuf, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, currsize, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1, 0, true)
		t = (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
		del_lines(C.int(count) - 1, false)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = t
		curbuf_splice_pending_g -= 1
		(^C.int)(uintptr(curbuf) + B_DELETED_BYTES2_OFF)^ = 0
		join_col := col
		if vim_strchr(p_cpo, C.int(CPO_JOINCOL_O)) != nil {
			join_col = currsize
		}
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = join_col
		check_cursor_col(curwin)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	}
	xfree(rawptr(spaces))
	if remove_comments {
		xfree(rawptr(comments))
	}
	return ret
}

pos_equal_dp_o :: proc "c" (a: Pos_T, b: Pos_T) -> bool {
	context = runtime.default_context()
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

@(export)
do_pending_operator :: proc "c" (cap: rawptr, old_col: C.int, gui_yank: bool) {
	context = runtime.default_context()
	oap := (^rawptr)(uintptr(cap))^
	lbr_saved := (^C.int)(uintptr(curwin) + W_P_LBR_OFF)^
	old_cursor := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	finish_op := finish_op_g
	op_type := (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
	if (finish_op || VIsual_active) && op_type != OP_NOP_O {
		empty_region_error := false
		restart_edit_save: C.int = 0
		include_line_break := false
		redo_yank := vim_strchr(p_cpo, C.int(CPO_YANK_O)) != nil && !gui_yank
		reset_lbr()
		(^bool)(uintptr(oap) + OAP_IS_VISUAL)^ = VIsual_active
		motion_force := (^C.int)(uintptr(oap) + OAP_MOTION_FORCE_O)^
		motion_type := (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
		cmdchar := (^C.int)(uintptr(cap) + CMDARG_CMDCHAR_OFF_O)^
		nchar := (^C.int)(uintptr(cap) + CAP_NCHAR_O)^
		count0 := (^C.int)(uintptr(cap) + CAP_COUNT0_O)^
		count1 := (^C.int)(uintptr(cap) + CAP_COUNT1_O)^
		if motion_force == 'V' {
			motion_type = kMTLineWise
			(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTLineWise
		} else if motion_force == 'v' {
			if motion_type == kMTLineWise {
				(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = false
			} else if motion_type == kMTCharWise {
				(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = !(^bool)(uintptr(oap) + OAP_INCLUSIVE)^
			}
			motion_type = kMTCharWise
			(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTCharWise
		} else if motion_force == Ctrl_V {
			if !VIsual_active {
				VIsual_active = true
				VIsual_g = (^Pos_T)(uintptr(oap) + OAP_START)^
			}
			VIsual_mode = Ctrl_V
			VIsual_select_g = false
			visual_reselect_g = 0
		}
		if (redo_yank || op_type != OP_YANK_O) && ((!VIsual_active || motion_force != 0) || ((is_ex_cmdchar_o(cap) || cmdchar == K_LUA_O) && op_type != OP_COLON_O)) && cmdchar != 'D' && op_type != OP_FOLD_O && op_type != OP_FOLDOPEN_O && op_type != OP_FOLDOPENREC_O && op_type != OP_FOLDCLOSE_O && op_type != OP_FOLDCLOSEREC_O && op_type != OP_FOLDDEL_O && op_type != OP_FOLDDELREC_O {
			prep_redo_e((^C.int)(uintptr(oap) + OAP_REGNAME)^, count0, get_op_char(op_type), get_extra_op_char(op_type), motion_force, cmdchar, nchar)
			if cmdchar == '/' || cmdchar == '?' {
				if vim_strchr(p_cpo, C.int(CPO_REDO_O)) == nil {
					append_to_redobuff_lit_e(transmute(cstring)((^rawptr)(uintptr(cap) + CAP_SEARCHBUF_O)^), -1)
				}
				append_to_redobuff_e(cstring("\n"))
			} else if is_ex_cmdchar_o(cap) {
				if repeat_cmdline_g == nil {
					reset_redobuff_e()
				} else {
					if cmdchar == ':' {
						append_to_redobuff_lit_e(repeat_cmdline_g, -1)
					} else {
						append_to_redobuff_spec_e(repeat_cmdline_g)
					}
					append_to_redobuff_e(cstring("\n"))
					xfree(rawptr(repeat_cmdline_g))
					repeat_cmdline_g = nil
				}
			} else if cmdchar == K_LUA_O {
				append_number_to_redobuff_e(repeat_luaref_g)
				append_to_redobuff_e(cstring("\n"))
			}
		}
		if redo_VIsual_busy_g {
			(^Pos_T)(uintptr(oap) + OAP_START)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += redo_VIsual_g.rv_line_count - 1
			minln := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
			maxln := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
			if minln > maxln {
				minln = maxln
			}
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = minln
			VIsual_mode = redo_VIsual_g.rv_mode
			if redo_VIsual_g.rv_vcol == MAXCOL || VIsual_mode == 'v' {
				if VIsual_mode == 'v' {
					if redo_VIsual_g.rv_line_count <= 1 {
						validate_virtcol(curwin)
						(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = (^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ + redo_VIsual_g.rv_vcol - 1
					} else {
						(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = redo_VIsual_g.rv_vcol
					}
				} else {
					(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = MAXCOL
				}
				coladvance(curwin, (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^)
			}
			(^C.int)(uintptr(cap) + CAP_COUNT0_O)^ = redo_VIsual_g.rv_count
			count0 = redo_VIsual_g.rv_count
			if count0 == 0 {
				count1 = 1
			} else {
				count1 = count0
			}
			(^C.int)(uintptr(cap) + CAP_COUNT1_O)^ = count1
		} else if VIsual_active {
			if !gui_yank {
				(^Pos_T)(uintptr(curbuf) + B_VISUAL)^ = VIsual_g
				(^Pos_T)(uintptr(curbuf) + B_VISUAL + 12)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
				(^C.int)(uintptr(curbuf) + B_VISUAL + 24)^ = VIsual_mode
				restore_visual_mode_e()
				(^C.int)(uintptr(curbuf) + B_VISUAL + 28)^ = (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^
				(^C.int)(uintptr(curbuf) + B_VISUAL_MODE_EVAL)^ = VIsual_mode
			}
			if VIsual_select_g && VIsual_mode == 'V' && (^C.int)(uintptr(oap) + OAP_OP_TYPE)^ != OP_DELETE_O {
				if lt_pos_o(VIsual_g, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^) {
					VIsual_g.col = 0
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = ml_get_len((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
				} else {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
					VIsual_g.col = ml_get_len(VIsual_g.lnum)
				}
				VIsual_mode = 'v'
			} else if VIsual_mode == 'v' {
				include_line_break = unadjust_for_sel_e()
			}
			(^Pos_T)(uintptr(oap) + OAP_START)^ = VIsual_g
			if VIsual_mode == 'V' {
				(^C.int)(uintptr(oap) + OAP_START + 4)^ = 0
				(^C.int)(uintptr(oap) + OAP_START + 8)^ = 0
			}
		}
		op_type = (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
		motion_type = (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
		if lt_pos_o((^Pos_T)(uintptr(oap) + OAP_START)^, (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^) {
			if !VIsual_active {
				lnum_tmp := (^C.int)(uintptr(oap) + OAP_START)^
				if hasFolding(curwin, lnum_tmp, transmute(^C.int)(rawptr(uintptr(oap) + OAP_START)), nil) {
					(^C.int)(uintptr(oap) + OAP_START + 4)^ = 0
				}
				if ((^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 || (^bool)(uintptr(oap) + OAP_INCLUSIVE)^ || motion_type == kMTLineWise) && hasFolding(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, nil, transmute(^C.int)(rawptr(uintptr(curwin) + W_CURSOR_OFF))) {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = get_cursor_line_len()
				}
			}
			(^Pos_T)(uintptr(oap) + OAP_END)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
			(^C.int)(uintptr(curwin) + W_VALID_OFF)^ &= ~C.int(VALID_VIRTCOL_O)
		} else {
			if !VIsual_active && motion_type == kMTLineWise {
				if hasFolding(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, transmute(^C.int)(rawptr(uintptr(curwin) + W_CURSOR_OFF)), nil) {
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
				}
				if hasFolding(curwin, (^C.int)(uintptr(oap) + OAP_START)^, nil, transmute(^C.int)(rawptr(uintptr(oap) + OAP_START))) {
					(^C.int)(uintptr(oap) + OAP_START + 4)^ = ml_get_len((^C.int)(uintptr(oap) + OAP_START)^)
				}
			}
			(^Pos_T)(uintptr(oap) + OAP_END)^ = (^Pos_T)(uintptr(oap) + OAP_START)^
			(^Pos_T)(uintptr(oap) + OAP_START)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
		}
		check_pos((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_END)))
		(^C.int)(uintptr(oap) + OAP_LINE_COUNT)^ = (^Pos_T)(uintptr(oap) + OAP_END)^.lnum - (^Pos_T)(uintptr(oap) + OAP_START)^.lnum + 1
		if virtual_active(curwin) {
			virtual_op_g = TriState.kTrue
		} else {
			virtual_op_g = TriState.kFalse
		}
		if VIsual_active || redo_VIsual_busy_g {
			get_op_vcol_o(oap, redo_VIsual_g.rv_vcol, true)
			if !redo_VIsual_busy_g && !gui_yank {
				resel_VIsual_mode_g = VIsual_mode
				if (^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ == MAXCOL {
					resel_VIsual_vcol_g = MAXCOL
				} else {
					if VIsual_mode != Ctrl_V {
						getvvcol(curwin, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_END)), nil, nil, transmute(^C.int)(rawptr(uintptr(oap) + OAP_END_VCOL)), 0)
					}
					if VIsual_mode == Ctrl_V || (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^ <= 1 {
						if VIsual_mode != Ctrl_V {
							getvvcol(curwin, transmute(^Pos_T)(rawptr(uintptr(oap) + OAP_START)), transmute(^C.int)(rawptr(uintptr(oap) + OAP_START_VCOL)), nil, nil, 0)
						}
						resel_VIsual_vcol_g = (^C.int)(uintptr(oap) + OAP_END_VCOL)^ - (^C.int)(uintptr(oap) + OAP_START_VCOL)^ + 1
					} else {
						resel_VIsual_vcol_g = (^C.int)(uintptr(oap) + OAP_END_VCOL)^
					}
				}
				resel_VIsual_line_count_g = (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
			}
			if (redo_yank || op_type != OP_YANK_O) && op_type != OP_COLON_O && op_type != OP_FOLD_O && op_type != OP_FOLDOPEN_O && op_type != OP_FOLDOPENREC_O && op_type != OP_FOLDCLOSE_O && op_type != OP_FOLDCLOSEREC_O && op_type != OP_FOLDDEL_O && op_type != OP_FOLDDELREC_O && motion_force == 0 {
				if cmdchar == 'g' && (nchar == 'n' || nchar == 'N') {
					prep_redo_e((^C.int)(uintptr(oap) + OAP_REGNAME)^, count0, get_op_char(op_type), get_extra_op_char(op_type), motion_force, cmdchar, nchar)
				} else if !is_ex_cmdchar_o(cap) && cmdchar != K_LUA_O {
					opchar := get_op_char(op_type)
					extra_opchar := get_extra_op_char(op_type)
					nch: C.int = 0
					if op_type == OP_REPLACE_O {
						nch = nchar
					}
					if nch == REPLACE_CR_NCHAR_O {
						nch = C.int(CAR)
					} else if nch == REPLACE_NL_NCHAR_O {
						nch = NL_O
					}
					if opchar == 'g' && extra_opchar == '@' {
						prep_redo_num2_e((^C.int)(uintptr(oap) + OAP_REGNAME)^, 0, 0, 'v', count0, opchar, extra_opchar, nch)
					} else {
						prep_redo_e((^C.int)(uintptr(oap) + OAP_REGNAME)^, 0, 0, 'v', opchar, extra_opchar, nch)
					}
				}
				if !redo_VIsual_busy_g {
					redo_VIsual_g.rv_mode = resel_VIsual_mode_g
					redo_VIsual_g.rv_vcol = resel_VIsual_vcol_g
					redo_VIsual_g.rv_line_count = resel_VIsual_line_count_g
					redo_VIsual_g.rv_count = count0
					redo_VIsual_g.rv_arg = (^C.int)(uintptr(cap) + CAP_ARG_O)^
				}
			}
			inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
			if motion_force == 0 || motion_type == kMTLineWise {
				inclusive = true
				(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = true
			}
			if VIsual_mode == 'V' {
				motion_type = kMTLineWise
				(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTLineWise
			} else if VIsual_mode == 'v' {
				motion_type = kMTCharWise
				(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTCharWise
				if ([^]u8)(ml_get_pos(transmute(rawptr)(uintptr(oap) + OAP_END)))[0] == 0 && (include_line_break || virtual_op_g == TriState.kFalse) {
					(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = false
					inclusive = false
					if ([^]u8)(p_sel)[0] != 'o' && op_on_lines(op_type) == 0 && (^Pos_T)(uintptr(oap) + OAP_END)^.lnum < (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
						(^Pos_T)(uintptr(oap) + OAP_END)^.lnum += 1
						(^C.int)(uintptr(oap) + OAP_END + 4)^ = 0
						(^C.int)(uintptr(oap) + OAP_END + 8)^ = 0
						(^C.int)(uintptr(oap) + OAP_LINE_COUNT)^ += 1
					}
				}
			}
			redo_VIsual_busy_g = false
			if !gui_yank {
				VIsual_active = false
				setmouse()
				mouse_dragging_g = 0
				may_clear_cmdline_e()
				if (op_type == OP_YANK_O || op_type == OP_COLON_O || op_type == OP_FUNCTION_O || op_type == OP_FILTER_O) && motion_force == 0 {
					restore_lbr(lbr_saved != 0)
					redraw_curbuf_later(UPD_INVERTED_S)
				}
			}
		}
		inclusive := (^bool)(uintptr(oap) + OAP_INCLUSIVE)^
		if inclusive {
			l := utfc_ptr2len(transmute(cstring)(ml_get_pos(transmute(rawptr)(uintptr(oap) + OAP_END))))
			if l > 1 {
				(^C.int)(uintptr(oap) + OAP_END + 4)^ += l - 1
			}
		}
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
		start_pos := (^Pos_T)(uintptr(oap) + OAP_START)^
		end_pos := (^Pos_T)(uintptr(oap) + OAP_END)^
		empt := motion_type != kMTLineWise
		if empt {
			if !inclusive {
				empt = true
			} else if op_type == OP_YANK_O && gchar_pos(transmute(rawptr)(uintptr(oap) + OAP_END)) == 0 {
				empt = true
			} else {
				empt = false
			}
		}
		if empt {
			if !pos_equal_dp_o(start_pos, end_pos) {
				empt = false
			}
		}
		if empt {
			if !(virtual_op_g != TriState.kFalse && (^Pos_T)(uintptr(oap) + OAP_START)^.coladd != (^Pos_T)(uintptr(oap) + OAP_END)^.coladd) {
			} else {
				empt = false
			}
		}
		(^bool)(uintptr(oap) + OAP_EMPTY_O)^ = empt
		if empt && vim_strchr(p_cpo, C.int(CPO_EMPTYREGION_O)) != nil {
			empty_region_error = true
		}
		is_visual := (^bool)(uintptr(oap) + OAP_IS_VISUAL)^
		if is_visual && (empt || (^C.int)(uintptr(curbuf) + B_P_MA_OFF)^ == 0 || op_type == OP_FOLD_O) {
			restore_lbr(lbr_saved != 0)
			redraw_curbuf_later(UPD_INVERTED_S)
		}
		line_count := (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
		if motion_type == kMTCharWise && !inclusive && (retval_of(cap) & CA_NO_ADJ_OP_END_O) == 0 && (^Pos_T)(uintptr(oap) + OAP_END)^.col == 0 && (!is_visual || ([^]u8)(p_sel)[0] == 'o') && line_count > 1 {
			(^bool)(uintptr(oap) + OAP_END_ADJUSTED_O)^ = true
			(^C.int)(uintptr(oap) + OAP_LINE_COUNT)^ -= 1
			line_count -= 1
			(^Pos_T)(uintptr(oap) + OAP_END)^.lnum -= 1
			if inindent(0) {
				motion_type = kMTLineWise
				(^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^ = kMTLineWise
			} else {
				(^C.int)(uintptr(oap) + OAP_END + 4)^ = ml_get_len((^Pos_T)(uintptr(oap) + OAP_END)^.lnum)
				if (^C.int)(uintptr(oap) + OAP_END + 4)^ != 0 {
					(^C.int)(uintptr(oap) + OAP_END + 4)^ -= 1
					(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = true
					inclusive = true
				}
			}
		} else {
			(^bool)(uintptr(oap) + OAP_END_ADJUSTED_O)^ = false
		}
		op_type = (^C.int)(uintptr(oap) + OAP_OP_TYPE)^
		motion_type = (^C.int)(uintptr(oap) + OAP_MOTION_TYPE)^
		line_count = (^C.int)(uintptr(oap) + OAP_LINE_COUNT)^
		switch op_type {
		case OP_LSHIFT_O, OP_RSHIFT_O:
			shift_cnt := C.int(1)
			if is_visual {
				shift_cnt = count1
			}
			op_shift(oap, true, shift_cnt)
			auto_format(false, true)
		case OP_JOIN_O, OP_JOIN_NS_O:
			jcount := line_count
			if jcount < 2 {
				jcount = 2
			}
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + jcount - 1 > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
				beep_flush_r()
			} else {
				join_sp := false
				if op_type == OP_JOIN_O {
					join_sp = true
				}
				do_join(C.size_t(jcount), join_sp, true, true, true)
				auto_format(false, true)
			}
		case OP_DELETE_O:
			visual_reselect_g = 0
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				op_delete(oap)
				if motion_type == kMTLineWise && has_format_option(C.int(FO_AUTO_O)) && u_save_cursor() == OK {
					auto_format(false, true)
				}
			}
		case OP_YANK_O:
			if empty_region_error {
				if !gui_yank {
					vim_beep(C.uint(KOPT_BO_OPERATOR_O))
					cancel_redo_e()
				}
			} else {
				restore_lbr(lbr_saved != 0)
				(^bool)(uintptr(oap) + OAP_EXCL_TR_WS)^ = cmdchar == 'z'
				if (^bool)(uintptr(oap) + OAP_RESTORE_CURSOR_O)^ {
					(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap) + OAP_CURSOR_START_O)^
				}
				op_yank(oap, !gui_yank)
			}
			check_cursor_col(curwin)
		case OP_CHANGE_O:
			visual_reselect_g = 0
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				if !KeyTyped {
					restart_edit_save = restart_edit
				} else {
					restart_edit_save = 0
				}
				restart_edit = 0
				restore_lbr(lbr_saved != 0)
				(^C.longlong)(uintptr(curbuf) + B_LAST_CHANGEDTICK_I_OFF)^ = buf_changedtick_inline(curbuf)
				if op_change(oap) != 0 {
					(^C.int)(uintptr(cap) + CAP_RETVAL_O)^ |= CA_COMMAND_BUSY_O
				}
				if restart_edit == 0 {
					restart_edit = restart_edit_save
				}
			}
		case OP_FILTER_O:
			if vim_strchr(p_cpo, C.int(CPO_FILTER_O)) != nil {
				append_to_redobuff_e(cstring("!\r"))
			} else {
				bangredo_g = true
			}
			fallthrough
		case OP_INDENT_O, OP_COLON_O:
			if op_type == OP_INDENT_O && ([^]u8)(get_equalprg())[0] == 0 {
				if (^C.int)(uintptr(curbuf) + B_P_LISP_OFF)^ != 0 {
					if use_indentexpr_for_lisp() {
						op_reindent(oap, get_expr_indent)
					} else {
						op_reindent(oap, get_lisp_indent)
					}
				} else {
					inde := (^u8)((^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^)
					if inde != nil && ([^]u8)(inde)[0] != 0 {
						op_reindent(oap, get_expr_indent)
					} else {
						op_reindent(oap, get_c_indent_e)
					}
				}
			} else {
				op_colon_o(oap)
			}
		case OP_TILDE_O, OP_UPPER_O, OP_LOWER_O, OP_ROT13_O:
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				op_tilde(oap)
			}
			check_cursor_col(curwin)
		case OP_FORMAT_O:
			fex := (^u8)((^rawptr)(uintptr(curbuf) + B_P_FEX_OFF)^)
			if fex != nil && ([^]u8)(fex)[0] != 0 {
				op_formatexpr(oap)
			} else {
				fp := (^u8)((^rawptr)(uintptr(curbuf) + B_P_FP_OFF)^)
				if (p_fp_g != nil && ([^]u8)(transmute(^u8)(p_fp_g))[0] != 0) || (fp != nil && ([^]u8)(fp)[0] != 0) {
					op_colon_o(oap)
				} else {
					op_format(oap, false)
				}
			}
		case OP_FORMAT2_O:
			op_format(oap, true)
		case OP_FUNCTION_O:
			save_rv := redo_VIsual_g
			restore_lbr(lbr_saved != 0)
			op_function_o(oap)
			redo_VIsual_g = save_rv
		case OP_INSERT_O, OP_APPEND_O:
			visual_reselect_g = 0
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				restart_edit_save = restart_edit
				restart_edit = 0
				restore_lbr(lbr_saved != 0)
				(^C.longlong)(uintptr(curbuf) + B_LAST_CHANGEDTICK_I_OFF)^ = buf_changedtick_inline(curbuf)
				op_insert(oap, count1)
				reset_lbr()
				auto_format(false, true)
				if restart_edit == 0 {
					restart_edit = restart_edit_save
				} else {
					(^C.int)(uintptr(cap) + CAP_RETVAL_O)^ |= CA_COMMAND_BUSY_O
				}
			}
		case OP_REPLACE_O:
			visual_reselect_g = 0
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				restore_lbr(lbr_saved != 0)
				op_replace(oap, nchar)
			}
		case OP_FOLD_O:
			visual_reselect_g = 0
			foldCreate(curwin, (^Pos_T)(uintptr(oap) + OAP_START)^, (^Pos_T)(uintptr(oap) + OAP_END)^)
		case OP_FOLDOPEN_O, OP_FOLDOPENREC_O, OP_FOLDCLOSE_O, OP_FOLDCLOSEREC_O:
			visual_reselect_g = 0
			opening := C.int(0)
			if op_type == OP_FOLDOPEN_O || op_type == OP_FOLDOPENREC_O {
				opening = 1
			}
			recurse := C.int(0)
			if op_type == OP_FOLDOPENREC_O || op_type == OP_FOLDCLOSEREC_O {
				recurse = 1
			}
			opFoldRange((^Pos_T)(uintptr(oap) + OAP_START)^, (^Pos_T)(uintptr(oap) + OAP_END)^, opening, recurse, is_visual)
		case OP_FOLDDEL_O, OP_FOLDDELREC_O:
			visual_reselect_g = 0
			rec2 := C.int(0)
			if op_type == OP_FOLDDELREC_O {
				rec2 = 1
			}
			deleteFold(curwin, (^Pos_T)(uintptr(oap) + OAP_START)^.lnum, (^Pos_T)(uintptr(oap) + OAP_END)^.lnum, rec2, is_visual)
		case OP_NR_ADD_O, OP_NR_SUB_O:
			if empty_region_error {
				vim_beep(C.uint(KOPT_BO_OPERATOR_O))
				cancel_redo_e()
			} else {
				VIsual_active = true
				restore_lbr(lbr_saved != 0)
				op_addsub(oap, count1, redo_VIsual_g.rv_arg != 0)
				VIsual_active = false
			}
			check_cursor_col(curwin)
		case:
			clearopbeep_e(oap)
		}
		virtual_op_g = TriState.kNone
		if !gui_yank {
			end_adj := (^bool)(uintptr(oap) + OAP_END_ADJUSTED_O)^
			if p_sol_g == 0 && motion_type == kMTLineWise && !end_adj && (op_type == OP_LSHIFT_O || op_type == OP_RSHIFT_O || op_type == OP_DELETE_O) {
				reset_lbr()
				(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = old_col
				coladvance(curwin, old_col)
			}
		} else {
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = old_cursor
		}
		clearop_e(oap)
		motion_force_g = 0
	}
}

retval_of :: proc "c" (cap: rawptr) -> C.int {
	context = runtime.default_context()
	return (^C.int)(uintptr(cap) + CAP_RETVAL_O)^
}
