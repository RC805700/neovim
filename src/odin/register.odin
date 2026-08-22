// register.odin — port of src/nvim/register.c (yank registers, do_put, :registers)
//
// Struct layouts probe-verified (2026-07):
//   yankreg_T=40 {y_array@0,y_size@8,y_type@16,y_width@20,timestamp@24,additional_data@32}
//   block_def=64 {startspaces@0,endspaces@4,textlen@8,textstart@16,textcol@24,start_vcol@28,
//                 end_vcol@32,is_short@36,is_MAX@40,is_oneChar@44,pre_whitesp@48,
//                 pre_whitesp_c@52,end_char_vcols@56,start_char_vcols@60}
//   oparg_T=88  (accessed via offset constants below)
//
// Reuses package-wide: Pos_T/Str16 helpers, mark.odin FFI (ml_get*, utf_*, tv_*),
// digraph.odin `_t`, main.odin Garray, shell.odin xstrdup/xmemdupz, input.odin
// os_breakcheck, time.odin os_time/got_int, mark.odin e_invarg2/cmdmod_cmod_flags.

package main

import C "core:c"
import "core:c/libc"

// ── Constants ────────────────────────────────────────────────────────────────

PUT_FIXINDENT :: 1
PUT_CURSEND :: 2
PUT_CURSLINE :: 4
PUT_LINE :: 8
PUT_LINE_SPLIT :: 16
PUT_LINE_FORWARD :: 32
PUT_BLOCK_INNER :: 64

DELETION_REGISTER :: 36
NUM_SAVED_REGISTERS :: 37
STAR_REGISTER :: 37
PLUS_REGISTER :: 38
NUM_REGISTERS :: 39

kGRegNoExpr :: 1
kGRegExprSrc :: 2
kGRegList :: 4

YREG_PASTE :: 0
YREG_YANK :: 1
YREG_PUT :: 2

kMTCharWise :: 0
kMTLineWise :: 1
kMTBlockWise :: 2
kMTUnknown :: -1

REMAP_YES :: 0
REMAP_NONE :: -1

K_COMMAND :: -26877 // TERMCAP2KEY(KS_EXTRA=253, KE_COMMAND=104)

Ctrl_R :: 18
Ctrl_U :: 21
Ctrl_V :: 22
Ctrl_F :: 6
Ctrl_P :: 16
Ctrl_W :: 23
Ctrl_A :: 1
Ctrl_L :: 12

CTRL_V_STR :: "\x16"
CPO_REGAPPEND :: '>'
SIN_NOMARK :: 8
RE_SEARCH :: 0

FNAME_MESS :: 1
FNAME_EXP :: 2
FNAME_HYP :: 4
FIND_IDENT :: 1
FIND_STRING :: 2

kBoolVarTrue :: 1
kBoolVarFalse :: 0

EVENT_RECORDINGENTER :: 92
EVENT_RECORDINGLEAVE :: 93
EVENT_TEXTPUTPOST :: 130
EVENT_TEXTPUTPRE :: 131
EVENT_TEXTYANKPOST :: 132

REPLACE_FLAG :: 0x100
kExtmarkNOOP :: 0
kExtmarkUndo :: 1

OK_R :: 1
FAIL_R :: 0

// win_T / buf_T offsets (probe-verified)
W_CURSWANT :: 148
W_SET_CURSWANT :: 152
W_ALT_FNUM :: 776
B_FNAME :: 176
B_P_TS :: 10696
B_P_VTS_ARRAY :: 10784
B_TERMINAL :: 12488

// oparg_T offsets
OAP_OP_TYPE :: 0
OAP_REGNAME :: 4
OAP_MOTION_TYPE :: 8
OAP_START :: 20
OAP_END :: 32
OAP_INCLUSIVE :: 17
OAP_IS_VISUAL :: 65
OAP_LINE_COUNT :: 60
OAP_START_VCOL :: 68
OAP_END_VCOL :: 72
OAP_EXCL_TR_WS :: 84

// Error strings (Odin literals — C's are char[] arrays)
e_nolastcmd: cstring = "E30: No previous command line"
e_noinstext: cstring = "E29: No inserted text yet"
e_noprevre: cstring = "E35: No previous regular expression"
e_resulting_text_too_long: cstring = "E1240: Resulting text too long"

// ── Types ────────────────────────────────────────────────────────────────────

// C `String` mirror (16 bytes)
Str16 :: struct {
	data: ^u8,
	size: C.size_t,
}
#assert(size_of(Str16) == 16)

// register_defs.h yankreg_T (40 bytes)
Yankreg_T :: struct {
	y_array:         [^]Str16,
	y_size:          C.size_t,
	y_type:          C.int,
	y_width:         C.int,
	timestamp:       Timestamp,
	additional_data: rawptr,
}
#assert(size_of(Yankreg_T) == 40)

// register_defs.h struct block_def (64 bytes)
Block_Def :: struct {
	startspaces:      C.int,
	endspaces:        C.int,
	textlen:          C.int,
	_pad0:            [4]u8,
	textstart:        ^u8,
	textcol:          C.int,
	start_vcol:       C.int,
	end_vcol:         C.int,
	is_short:         C.int,
	is_MAX:           C.int,
	is_oneChar:       C.int,
	pre_whitesp:      C.int,
	pre_whitesp_c:    C.int,
	end_char_vcols:   C.int,
	start_char_vcols: C.int,
}
#assert(size_of(Block_Def) == 64)

// save_v_event_T is opaque (304 bytes) — stack buffer
Save_V_Event_T :: [304]u8

// ── Globals (statics moved from C) ───────────────────────────────────────────

expr_line: ^u8

execreg_lastc: C.int = 0 // NUL

y_regs: [NUM_REGISTERS]Yankreg_T

y_previous: ^Yankreg_T

empty_reg_static: Yankreg_T

do_record_regname: C.int

typ_recursive: bool

put_recursive: bool

get_expr_line_nested: C.int

// ── Foreign globals ──────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "restart_edit")
	restart_edit: C.int

	@(link_name = "textlock")
	textlock: C.int

	@(link_name = "VIsual_active")
	VIsual_active: bool

	@(link_name = "VIsual_mode")
	VIsual_mode: C.int

	@(link_name = "last_cmdline")
	last_cmdline: ^u8

	@(link_name = "new_last_cmdline")
	new_last_cmdline: ^u8

	@(link_name = "reg_recording")
	reg_recording: C.int

	@(link_name = "reg_executing")
	reg_executing: C.int

	@(link_name = "reg_recorded")
	reg_recorded: C.int

	@(link_name = "pending_end_reg_executing")
	pending_end_reg_executing: bool

	@(link_name = "redir_reg")
	redir_reg: C.int

	@(link_name = "must_redraw")
	must_redraw: C.int

	@(link_name = "add_last_insert")
	add_last_insert: C.int

	@(link_name = "last_insert_ga")
	last_insert_ga: Garray

	@(link_name = "msg_ext_skip_flush")
	msg_ext_skip_flush: bool

	@(link_name = "p_report")
	p_report: i64

	@(link_name = "p_sel")
	p_sel: ^u8
}

// ── Foreign procs ────────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "getcmdline")
	getcmdline :: proc "c" (firstc: C.int, count: C.int, indent: C.int, do_concat: bool) -> ^u8 ---
	@(link_name = "adjust_clipboard_name")
	adjust_clipboard_name :: proc "c" (name: ^C.int, quiet: bool, writing: bool) -> rawptr ---
	@(link_name = "get_clipboard")
	get_clipboard :: proc "c" (name: C.int, target: ^^Yankreg_T, quiet: bool) -> bool ---
	@(link_name = "set_clipboard")
	set_clipboard :: proc "c" (name: C.int, reg: ^Yankreg_T) ---
	@(link_name = "copy_string")
	copy_string :: proc "c" (str: Str16, arena: rawptr) -> Str16 ---
	@(link_name = "cstr_to_string")
	cstr_to_string_r :: proc "c" (str: cstring) -> Str16 ---
	@(link_name = "cbuf_to_string")
	cbuf_to_string_r :: proc "c" (buf: cstring, size: C.size_t) -> Str16 ---

	@(link_name = "mb_string2cells_len")
	mb_string2cells_len :: proc "c" (s: cstring, len: C.size_t) -> C.size_t ---
	@(link_name = "mb_string2cells")
	mb_string2cells_s :: proc "c" (s: cstring) -> C.size_t ---
	@(link_name = "vim_strsave_escape_ks")
	vim_strsave_escape_ks_r :: proc "c" (p: ^u8) -> ^u8 ---
	@(link_name = "vim_unescape_ks")
	vim_unescape_ks_r :: proc "c" (p: ^u8) -> C.size_t ---
	@(link_name = "vim_strsave_escaped_ext")
	vim_strsave_escaped_ext_r :: proc "c" (string: cstring, esc_chars: cstring, cc: u8, bsl: bool) -> ^u8 ---

	@(link_name = "showmode")
	showmode_r :: proc "c" () -> C.int ---
	@(link_name = "ui_has")
	ui_has_r :: proc "c" (cap: C.int) -> bool ---
	@(link_name = "get_recorded")
	get_recorded_r :: proc "c" () -> ^u8 ---
	@(link_name = "stuff_inserted")
	stuff_inserted_r :: proc "c" (c: C.int, count: C.int, no_esc: bool) -> C.int ---
	@(link_name = "stuffescaped")
	stuffescaped_r :: proc "c" (arg: cstring, literally: bool) ---
	@(link_name = "stuffcharReadbuff")
	stuffcharReadbuff_r :: proc "c" (c: C.int) ---
	@(link_name = "stuffReadbuffLen")
	stuffReadbuffLen_r :: proc "c" (s: cstring, len: i64) ---
	@(link_name = "stuffReadbuff")
	stuffReadbuff_r :: proc "c" (s: cstring) ---
	@(link_name = "ins_typebuf")
	ins_typebuf_r :: proc "c" (str: ^u8, noremap: C.int, offset: C.int, nottyped: bool, silent: bool) -> C.int ---
	@(link_name = "cmdline_paste_str")
	cmdline_paste_str_r :: proc "c" (s: cstring, literally: bool) ---

	@(link_name = "emsg_invreg")
	emsg_invreg_r :: proc "c" (name: C.int) ---
	@(link_name = "msgmore")
	msgmore_r :: proc "c" (n: C.int) ---
	@(link_name = "transchar")
	transchar_r :: proc "c" (c: C.int) -> ^u8 ---
	@(link_name = "adjust_cursor_eol")
	adjust_cursor_eol_r :: proc "c" () ---
	@(link_name = "decl")
	decl_pos :: proc "c" (p: ^Pos_T) -> C.int ---

	// u_save / u_save_cursor are now defined in undo.odin — reuse directly.
	@(link_name = "del_chars")
	del_chars_r :: proc "c" (count: C.int, fixpos: C.int) -> C.int ---
	@(link_name = "mb_charlen")
	mb_charlen_r :: proc "c" (str: cstring) -> C.int ---
	@(link_name = "oneright")
	oneright_r :: proc "c" () -> C.int ---
	@(link_name = "AppendCharToRedobuff")
	AppendCharToRedobuff_r :: proc "c" (c: C.int) ---

	@(link_name = "block_prep")
	block_prep_r :: proc "c" (oap: rawptr, bdp: ^Block_Def, lnum: C.int, is_del: bool) ---
	@(link_name = "charwise_block_prep")
	charwise_block_prep_r :: proc "c" (start: Pos_T, end: Pos_T, bdp: ^Block_Def, lnum: C.int, inclusive: bool) ---

	@(link_name = "ml_append")
	ml_append_c :: proc "c" (lnum: C.int, line: ^u8, len: C.int, newfile: bool) -> bool ---
	@(link_name = "ml_replace")
	ml_replace_c :: proc "c" (lnum: C.int, line: ^u8, copy: bool) -> C.int ---

	@(link_name = "get_cursor_line_ptr")
	get_cursor_line_ptr_r :: proc "c" () -> ^u8 ---
	@(link_name = "get_cursor_pos_ptr")
	get_cursor_pos_ptr_r :: proc "c" () -> ^u8 ---
	@(link_name = "get_cursor_line_len")
	get_cursor_line_len_r :: proc "c" () -> C.int ---
	@(link_name = "get_cursor_pos_len")
	get_cursor_pos_len_r :: proc "c" () -> C.int ---

	@(link_name = "update_topline")
	update_topline_r :: proc "c" (wp: rawptr) ---
	@(link_name = "update_screen")
	update_screen_r :: proc "c" () -> C.int ---
	@(link_name = "changed_lines")
	changed_lines_r :: proc "c" (buf: rawptr, lnum: C.int, col: C.int, lnume: C.int, xtra: C.int, do_buf_event: bool) ---
	@(link_name = "changed_bytes")
	changed_bytes_r :: proc "c" (lnum: C.int, col: C.int) ---
	@(link_name = "changed_cline_bef_curs")
	changed_cline_bef_curs_r :: proc "c" (wp: rawptr) ---
	@(link_name = "invalidate_botline_win")
	invalidate_botline_win_r :: proc "c" (wp: rawptr) ---
	@(link_name = "buf_updates_send_changes")
	buf_updates_send_changes_r :: proc "c" (buf: rawptr, firstline: C.int, num_added: i64, num_removed: i64) ---
	@(link_name = "extmark_splice")
	extmark_splice_r :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, old_row: C.int, old_col: C.int, old_byte: i64, new_row: C.int, new_col: C.int, new_byte: i64, undo: C.int) ---
	@(link_name = "extmark_splice_cols")
	extmark_splice_cols_r :: proc "c" (buf: rawptr, start_row: C.int, start_col: C.int, old_col: C.int, new_col: C.int, undo: C.int) ---

	@(link_name = "get_indent")
	get_indent_r :: proc "c" () -> C.int ---
	@(link_name = "set_indent")
	set_indent_r :: proc "c" (size: C.int, flags: C.int) -> bool ---
	@(link_name = "preprocs_left")
	preprocs_left_r :: proc "c" () -> bool ---

	@(link_name = "getvcol")
	getvcol_r :: proc "c" (wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) ---
	@(link_name = "getvpos")
	getvpos_r :: proc "c" (wp: rawptr, pos: ^Pos_T, wcol: C.int) -> C.int ---
	@(link_name = "coladvance_force")
	coladvance_force_r :: proc "c" (wcol: C.int) -> C.int ---
	@(link_name = "getviscol")
	getviscol_r :: proc "c" () -> C.int ---
	@(link_name = "win_chartabsize")
	win_chartabsize_r :: proc "c" (wp: rawptr, p: ^u8, col: C.int) -> C.int ---
	@(link_name = "tabstop_padding")
	tabstop_padding_r :: proc "c" (col: C.int, ts: i64, vts: ^C.int) -> C.int ---
	@(link_name = "get_ve_flags")
	get_ve_flags_r :: proc "c" (wp: rawptr) -> C.uint ---

	@(link_name = "ins_compl_preinsert_effect")
	ins_compl_preinsert_effect_r :: proc "c" () -> bool ---
	@(link_name = "ins_compl_delete")
	ins_compl_delete_r :: proc "c" (new_leader: bool) ---
	@(link_name = "terminal_paste")
	terminal_paste_r :: proc "c" (count: C.int, y_array: ^Str16, y_size: C.size_t) ---

	@(link_name = "file_name_at_cursor")
	file_name_at_cursor_r :: proc "c" (options: C.int, count: C.int, file_lnum: ^C.int) -> ^u8 ---
	@(link_name = "find_ident_under_cursor")
	find_ident_under_cursor_r :: proc "c" (text: ^^u8, find_type: C.int, offset: ^C.int) -> C.size_t ---
	@(link_name = "getaltfname")
	getaltfname_r :: proc "c" (errmsg: bool) -> ^u8 ---
	@(link_name = "check_fname")
	check_fname_r :: proc "c" () -> C.int ---
	// last_search_pat / set_last_search_pat now defined in search.odin — reuse directly.
	@(link_name = "buflist_findpat")
	buflist_findpat_r :: proc "c" (pattern: cstring, pattern_end: cstring, unlisted: bool, diffmode: bool, curtab_only: bool) -> C.int ---
	@(link_name = "buflist_name_nr")
	buflist_name_nr_r :: proc "c" (fnum: C.int, fname: ^^u8, lnum: ^C.int) -> C.int ---
	@(link_name = "getdigits_int")
	getdigits_int_r :: proc "c" (pp: ^^u8, strict: bool, def: C.int) -> C.int ---
	@(link_name = "utf_ptr2cells_len")
	utf_ptr2cells_len_r :: proc "c" (p: cstring, size: C.int) -> C.int ---
	@(link_name = "utf_ptr2len_len")
	utf_ptr2len_len_r :: proc "c" (p: cstring, size: C.int) -> C.int ---

	@(link_name = "get_v_event")
	get_v_event_r :: proc "c" (sve: rawptr) -> rawptr ---
	@(link_name = "restore_v_event")
	restore_v_event_r :: proc "c" (v_event: rawptr, sve: rawptr) ---
	@(link_name = "tv_dict_set_keys_readonly")
	tv_dict_set_keys_readonly_r :: proc "c" (dict: rawptr) ---
	@(link_name = "tv_dict_add_bool")
	tv_dict_add_bool_r :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: C.int) -> C.int ---
	@(link_name = "tv_list_append_allocated_string")
	tv_list_append_allocated_string_r :: proc "c" (l: rawptr, str: ^u8) ---
	@(link_name = "tv_dict_add_str_len")
	tv_dict_add_str_len_r2 :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: cstring, len: C.int) -> C.int ---
	@(link_name = "get_op_char")
	get_op_char_r :: proc "c" (optype: C.int) -> C.int ---

	@(link_name = "ga_init")
	ga_init_r :: proc "c" (gap: ^Garray, itemsize: C.int, growsize: C.int) ---
	@(link_name = "ga_concat_len")
	ga_concat_len_r :: proc "c" (gap: ^Garray, s: cstring, len: C.size_t) ---
	@(link_name = "ga_append")
	ga_append_r :: proc "c" (gap: ^Garray, c: u8) ---
	@(link_name = "ga_set_growsize")
	ga_set_growsize_r :: proc "c" (gap: ^Garray, growsize: C.int) ---
	@(link_name = "ga_clear")
	ga_clear_r :: proc "c" (gap: ^Garray) ---

	@(link_name = "ngettext")
	ngettext_r :: proc "c" (msgid, msgid_plural: cstring, n: C.long) -> cstring ---
}

// ── Small helpers ────────────────────────────────────────────────────────────

oap_get_i32 :: #force_inline proc "c"(oap: rawptr, off: uintptr) -> C.int {
	return (^C.int)(uintptr(oap) + off)^
}

oap_get_bool :: #force_inline proc "c"(oap: rawptr, off: uintptr) -> bool {
	return (^bool)(uintptr(oap) + off)^
}

oap_get_pos :: #force_inline proc "c"(oap: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(oap) + off)
}

buf_read_ptr :: #force_inline proc "c"(base: rawptr, off: uintptr) -> rawptr {
	return (^rawptr)(uintptr(base) + off)^
}

get_i32_off :: #force_inline proc "c"(base: rawptr, off: uintptr) -> C.int {
	return (^C.int)(uintptr(base) + off)^
}

set_i32_off :: #force_inline proc "c"(base: rawptr, off: uintptr, v: C.int) {
	(^C.int)(uintptr(base) + off)^ = v
}

ascii_isalnum_c :: #force_inline proc "c"(c: C.int) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

ascii_islower_r :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= 'a' && c <= 'z'
}

ascii_isupper_r :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= 'A' && c <= 'Z'
}

ascii_isdigit_r :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= '0' && c <= '9'
}

// register.h static inlines
op_reg_index :: proc "c"(regname: C.int) -> C.int {
	if ascii_isdigit_r(regname) {
		return regname - '0'
	} else if ascii_islower_r(regname) {
		return regname - 'a' + 10
	} else if ascii_isupper_r(regname) {
		return regname - 'A' + 10
	} else if regname == '-' {
		return DELETION_REGISTER
	} else if regname == '*' {
		return STAR_REGISTER
	} else if regname == '+' {
		return PLUS_REGISTER
	}
	return -1
}

is_append_register :: proc "c"(regname: C.int) -> bool {
	return ascii_isupper_r(regname)
}

is_literal_register :: proc "c"(regname: C.int) -> bool {
	return regname == '*' || regname == '+' || ascii_isalnum_c(regname)
}

get_register_name :: proc "c"(num: C.int) -> C.int {
	if num == -1 {
		return '"'
	} else if num < 10 {
		return num + '0'
	} else if num == DELETION_REGISTER {
		return '-'
	} else if num == STAR_REGISTER {
		return '*'
	} else if num == PLUS_REGISTER {
		return '+'
	}
	return num + 'a' - 10
}

reg_empty :: proc "c"(reg: ^Yankreg_T) -> bool {
	if reg.y_array == nil || reg.y_size == 0 {
		return true
	}
	if reg.y_size == 1 && reg.y_type == kMTCharWise && reg.y_array[0].size == 0 {
		return true
	}
	return false
}

get_pos_r2 :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(base) + off)
}

win_cursor_r :: #force_inline proc "c"(w: rawptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(w) + W_CURSOR)
}

// gchar_cursor() macro
gchar_cursor_r :: #force_inline proc "c"() -> u8 {
	return get_cursor_pos_ptr_r()^
}

semsg_fmt :: proc "c"(fmt: cstring, arg: rawptr) {
	buf: [1025]u8
	n := libc.snprintf(&buf[0], size_of(buf), fmt, arg)
	buf[n if n >= 0 && n < 1024 else 1024] = 0
	emsg(transmute(cstring)(&buf[0]))
}

// ── Exported functions ───────────────────────────────────────────────────────

/// @return the index of the register "" points to.
@(export)
get_unname_register :: proc "c" () -> C.int {
	return y_previous == nil ? -1 : C.int(uintptr(y_previous) - uintptr(&y_regs[0])) / C.int(size_of(Yankreg_T))
}

@(export)
get_y_register :: proc "c" (reg: C.int) -> ^Yankreg_T {
	return &y_regs[reg]
}

@(export)
get_y_previous :: proc "c" () -> ^Yankreg_T {
	return y_previous
}

/// Get an expression for the "\"=expr1" or "CTRL-R =expr1"
@(export)
get_expr_register :: proc "c" () -> C.int {
	new_line := getcmdline('=', 0, 0, true)
	if new_line == nil {
		return 0 // NUL
	}
	if new_line^ == 0 { // use previous line
		xfree(new_line)
	} else {
		set_expr_line(new_line)
	}
	return '='
}

/// Set the expression for the '=' register. Argument must be allocated.
@(export)
set_expr_line :: proc "c" (new_line: ^u8) {
	xfree(expr_line)
	expr_line = new_line
}

/// Get the result of the '=' register expression.
@(export)
get_expr_line :: proc "c" () -> ^u8 {
	if expr_line == nil {
		return nil
	}

	expr_copy := xstrdup(expr_line)

	if get_expr_line_nested >= 10 {
		return expr_copy
	}

	get_expr_line_nested += 1
	rv := eval_to_string(expr_copy, true, false)
	get_expr_line_nested -= 1
	xfree(expr_copy)
	return rv
}

/// Get the '=' register expression itself, without evaluating it.
@(export)
get_expr_line_src :: proc "c" () -> ^u8 {
	if expr_line == nil {
		return nil
	}
	return xstrdup(expr_line)
}

/// @return whether regname is a valid name of a yank register.
@(export)
valid_yank_reg :: proc "c" (regname: C.int, writing: bool) -> bool {
	if (regname > 0 && ascii_isalnum_c(regname)) ||
		(!writing && _vim_strchr(cstring("/#.%:="), regname) != nil) ||
		regname == '"' ||
		regname == '-' ||
		regname == '_' ||
		regname == '*' ||
		regname == '+' {
		return true
	}
	return false
}

/// Check if the default register should be a clipboard register.
@(export)
get_default_register_name :: proc "c" () -> C.int {
	name: C.int = 0
	adjust_clipboard_name(&name, true, false)
	return name
}

/// Iterate over registers regs.
@(export)
op_reg_iter :: proc "c" (iter: rawptr, regs: ^Yankreg_T, name: ^u8, reg: ^Yankreg_T, is_unnamed: ^bool) -> rawptr {
	name^ = 0
	base := uintptr(regs)
	iter_mark := iter == nil ? base : uintptr(iter)
	for (iter_mark-base)/size_of(Yankreg_T) < NUM_SAVED_REGISTERS &&
		reg_empty((^Yankreg_T)(iter_mark)) {
		iter_mark += size_of(Yankreg_T)
	}
	if (iter_mark-base)/size_of(Yankreg_T) == NUM_SAVED_REGISTERS || reg_empty((^Yankreg_T)(iter_mark)) {
		return nil
	}
	iter_off := C.int((iter_mark - base) / size_of(Yankreg_T))
	name^ = u8(get_register_name(iter_off))
	reg^ = (^Yankreg_T)(iter_mark)^
	is_unnamed^ = iter_mark == uintptr(y_previous)
	iter_mark += size_of(Yankreg_T)
	for (iter_mark-base)/size_of(Yankreg_T) < NUM_SAVED_REGISTERS {
		if !reg_empty((^Yankreg_T)(iter_mark)) {
			return transmute(rawptr)(iter_mark)
		}
		iter_mark += size_of(Yankreg_T)
	}
	return nil
}

/// Iterate over global registers.
@(export)
op_global_reg_iter :: proc "c" (iter: rawptr, name: ^u8, reg: ^Yankreg_T, is_unnamed: ^bool) -> rawptr {
	return op_reg_iter(iter, &y_regs[0], name, reg, is_unnamed)
}

/// Get a number of non-empty registers
@(export)
op_reg_amount :: proc "c" () -> C.size_t {
	ret: C.size_t = 0
	for i := 0; i < NUM_SAVED_REGISTERS; i += 1 {
		if !reg_empty(&y_regs[i]) {
			ret += 1
		}
	}
	return ret
}

/// Set register to a given value
@(export)
op_reg_set :: proc "c" (name: u8, reg: Yankreg_T, is_unnamed: bool) -> bool {
	i := op_reg_index(C.int(name))
	if i == -1 {
		return false
	}
	free_register(&y_regs[i])
	y_regs[i] = reg

	if is_unnamed {
		y_previous = &y_regs[i]
	}
	return true
}

/// Get register with the given name
@(export)
op_reg_get :: proc "c" (name: u8) -> ^Yankreg_T {
	i := op_reg_index(C.int(name))
	if i == -1 {
		return nil
	}
	return &y_regs[i]
}

/// Set the previous yank register
@(export)
op_reg_set_previous :: proc "c" (name: u8) -> bool {
	i := op_reg_index(C.int(name))
	if i == -1 {
		return false
	}

	y_previous = &y_regs[i]
	return true
}

/// Updates the "y_width" of a blockwise register based on its contents.
@(export)
update_yankreg_width :: proc "c" (reg: ^Yankreg_T) {
	if reg.y_type == kMTBlockWise {
		maxlen: C.size_t = 0
		for i: C.size_t = 0; i < reg.y_size; i += 1 {
			rowlen := mb_string2cells_len(transmute(cstring)(reg.y_array[i].data), reg.y_array[i].size)
			maxlen = max(maxlen, rowlen)
		}
		reg.y_width = max(reg.y_width, C.int(maxlen) - 1)
	}
}

/// @return yankreg_T to use, according to the value of regname.
@(export)
get_yank_register :: proc "c" (regname: C.int, mode: C.int) -> ^Yankreg_T {
	reg: ^Yankreg_T

	if (mode == YREG_PASTE || mode == YREG_PUT) && get_clipboard(regname, &reg, false) {
		// reg is set to clipboard contents.
		return reg
	} else if mode == YREG_PUT && (regname == '*' || regname == '+') {
		// clipboard not available: return an empty register
		return &empty_reg_static
	} else if mode != YREG_YANK &&
		(regname == 0 || regname == '"' || regname == '*' || regname == '+') &&
		y_previous != nil {
		// paste from previous used register
		return y_previous
	}

	i := op_reg_index(regname)
	// when not 0-9, a-z, A-Z or '-'/'+'/'*': use register 0
	if i == -1 {
		i = 0
	}
	reg = &y_regs[i]

	if mode == YREG_YANK {
		// remember the written register for unnamed paste
		y_previous = reg
	}
	return reg
}

/// Check if the current yank register has kMTLineWise type
@(export)
yank_register_mline :: proc "c" (regname: C.int, reg: ^^Yankreg_T) -> bool {
	reg^ = nil
	if regname != 0 && !valid_yank_reg(regname, false) {
		return false
	}
	if regname == '_' { // black hole is always empty
		return false
	}
	reg^ = get_yank_register(regname, YREG_PASTE)
	return reg^^.y_type == kMTLineWise
}

/// @return a copy of contents in register name for use in do_put.
@(export)
copy_register :: proc "c" (name: C.int) -> ^Yankreg_T {
	reg := get_yank_register(name, YREG_PASTE)

	copy := (^Yankreg_T)(xmalloc(size_of(Yankreg_T)))
	copy^ = reg^
	if copy.y_size == 0 {
		copy.y_array = nil
	} else {
		copy.y_array = transmute([^]Str16)(xcalloc(copy.y_size, size_of(Str16)))
		for i: C.size_t = 0; i < copy.y_size; i += 1 {
			copy.y_array[i] = copy_string(reg.y_array[i], nil)
		}
	}
	return copy
}

/// Stuff string "p" into yank register "regname" as a single line.
stuff_yank :: proc "c"(regname: C.int, p: ^u8) -> C.int {
	// check for read-only register
	if regname != 0 && !valid_yank_reg(regname, true) {
		xfree(p)
		return FAIL_R
	}
	if regname == '_' { // black hole: don't do anything
		xfree(p)
		return OK_R
	}

	plen := libc.strlen(transmute(cstring)(p))
	reg := get_yank_register(regname, YREG_YANK)
	if is_append_register(regname) && reg.y_array != nil {
		pp := &reg.y_array[reg.y_size - 1]
		tmplen := pp.size + plen
		tmp := (^u8)(xmalloc(tmplen + 1))
		libc.memcpy(tmp, pp.data, pp.size)
		libc.memcpy((^u8)(uintptr(tmp) + uintptr(pp.size)), p, plen)
		(^u8)(uintptr(tmp) + uintptr(tmplen))^ = 0
		xfree(p)
		xfree(pp.data)
		pp^ = Str16{data = tmp, size = tmplen}
	} else {
		free_register(reg)
		reg.additional_data = nil
		reg.y_array = transmute([^]Str16)(xmalloc(size_of(Str16)))
		reg.y_array[0] = Str16{data = p, size = plen}
		reg.y_size = 1
		reg.y_type = kMTCharWise
	}
	reg.timestamp = os_time()
	return OK_R
}

/// Start or stop recording into a yank register.
@(export)
do_record :: proc "c" (c: C.int) -> C.int {
	retval: C.int

	if reg_recording == 0 {
		// start recording; registers 0-9, a-z and " are allowed
		if c < 0 || (!ascii_isalnum_c(c) && c != '"') {
			retval = FAIL_R
		} else {
			reg_recording = c
			showmode_r()
			do_record_regname = c
			retval = OK_R

			apply_autocmds(EVENT_RECORDINGENTER, nil, nil, false, curbuf)
		}
	} else { // stop recording
		sve: Save_V_Event_T
		dict := get_v_event_r(&sve)

		p := get_recorded_r()
		if p != nil {
			// Remove escaping for K_SPECIAL in multi-byte chars.
			vim_unescape_ks_r(p)
			tv_dict_add_str_m(dict, cstring("regcontents"), 11, transmute(cstring)(p))
		}

		buf: [NUMBUFLEN + 2]u8
		buf[0] = u8(do_record_regname)
		buf[1] = 0
		tv_dict_add_str_m(dict, cstring("regname"), 7, transmute(cstring)(&buf[0]))
		tv_dict_set_keys_readonly_r(dict)

		apply_autocmds(EVENT_RECORDINGLEAVE, nil, nil, false, curbuf)
		restore_v_event_r(dict, &sve)
		reg_recorded = reg_recording
		reg_recording = 0
		if p_ch == 0 || ui_has_r(kUIMessages) {
			showmode_r()
		} else {
			msg_msg(cstring(""), 0)
		}
		if p == nil {
			retval = FAIL_R
		} else {
			// don't change the default register here: save and restore.
			old_y_previous := y_previous

			retval = stuff_yank(do_record_regname, p)

			y_previous = old_y_previous
		}
	}
	return retval
}

/// Insert string "s" into the typeahead buffer.
put_in_typebuf :: proc "c"(s: ^u8, esc: bool, colon: bool, silent: bool) -> C.int {
	retval: C.int = OK_R

	put_reedit_in_typebuf(silent)
	if colon {
		retval = ins_typebuf_r(transmute(^u8)(cstring("\n")), REMAP_NONE, 0, true, silent)
	}
	if retval == OK_R {
		p: ^u8
		if esc {
			p = vim_strsave_escape_ks_r(s)
		} else {
			p = s
		}
		if p == nil {
			retval = FAIL_R
		} else {
			retval = ins_typebuf_r(p, esc ? REMAP_NONE : REMAP_YES, 0, true, silent)
		}
		if esc {
			xfree(p)
		}
	}
	if colon && retval == OK_R {
		retval = ins_typebuf_r(transmute(^u8)(cstring(":")), REMAP_NONE, 0, true, silent)
	}
	return retval
}

/// If "restart_edit" is not zero, put it in the typeahead buffer.
put_reedit_in_typebuf :: proc "c"(silent: bool) {
	if restart_edit == 0 {
		return
	}

	buf: [11]u8 = {0x80, 253, 104, 's', 't', 'a', 'r', 't', 'i', CAR, 0}
	if restart_edit == 'R' {
		buf[8] = 'r' // :startreplace
	} else if restart_edit == 'V' {
		buf[8] = 'g' // :startgreplace
	} else if restart_edit == 'A' {
		buf[8] = '!' // :startinsert!
	}
	if ins_typebuf_r(&buf[0], REMAP_NONE, 0, true, silent) == OK_R {
		restart_edit = 0
	}
}

/// Join line-continuation lines for :@<register>.
execreg_line_continuation :: proc "c"(lines: ^Str16, idx: ^C.size_t) -> ^u8 {
	cmd_start := idx^
	cmd_end := cmd_start

	ga: Garray
	ga_init_r(&ga, C.int(size_of(u8)), 400)

	// search backwards to find the first line of this command.
	for {
		cmd_start -= 1
		if cmd_start <= 0 {
			break
		}
		ln := (^Str16)(uintptr(lines) + uintptr(cmd_start) * size_of(Str16))
		pb := (^u8)(skipwhite(transmute(cstring)(ln.data)))
		if pb^ != '\\' && !(pb^ == '"' && (^u8)(uintptr(pb)+1)^ == '\\' && (^u8)(uintptr(pb)+2)^ == ' ') {
			break
		}
	}

	// join all the lines
	tmp := (^Str16)(uintptr(lines) + uintptr(cmd_start) * size_of(Str16))
	ga_concat_len_r(&ga, transmute(cstring)(tmp.data), tmp.size)
	j := cmd_start + 1
	for j <= cmd_end {
		tmp = (^Str16)(uintptr(lines) + uintptr(j) * size_of(Str16))
		p := (^u8)(skipwhite(transmute(cstring)(tmp.data)))
		if p^ == '\\' {
			if ga.ga_len > 400 {
				ga_set_growsize_r(&ga, min(ga.ga_len, 8000))
			}
			p = (^u8)(uintptr(p) + 1)
			ga_concat_len_r(&ga, transmute(cstring)(p), C.size_t(uintptr(tmp.data) + uintptr(tmp.size) - uintptr(p)))
		}
		j += 1
	}
	ga_append_r(&ga, 0)
	str := xmemdupz(ga.ga_data, C.size_t(ga.ga_len))
	ga_clear_r(&ga)

	idx^ = cmd_start
	return str
}

/// Execute a yank register: copy it into the stuff buffer
@(export)
do_execreg :: proc "c" (regname_arg: C.int, colon: C.int, addcr: C.int, silent: bool) -> C.int {
	retval: C.int = OK_R
	regname := regname_arg

	if regname == '@' { // repeat previous one
		if execreg_lastc == 0 {
			emsg(_t(e_nolastcmd_no_prev()))
			return FAIL_R
		}
		regname = execreg_lastc
	}
	// check for valid regname
	if regname == '%' || regname == '#' || !valid_yank_reg(regname, false) {
		emsg_invreg_r(regname)
		return FAIL_R
	}
	execreg_lastc = regname

	if regname == '_' { // black hole: don't stuff anything
		return OK_R
	}

	if regname == ':' { // use last command line
		if last_cmdline == nil {
			emsg(_t(e_nolastcmd))
			return FAIL_R
		}
		// don't keep the cmdline containing @:
		xfree(new_last_cmdline)
		new_last_cmdline = nil
		// Escape all control characters with a CTRL-V
		esc_arr := [31]u8{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31}
		p := vim_strsave_escaped_ext_r(transmute(cstring)(last_cmdline), transmute(cstring)(&esc_arr[0]), Ctrl_V, false)
		// When in Visual mode "'<,'>" will be prepended; remove it.
		if VIsual_active && libc.strncmp(transmute(cstring)(p), cstring("'<,'>"), 5) == 0 {
			retval = put_in_typebuf((^u8)(uintptr(p) + 5), true, true, silent)
		} else {
			retval = put_in_typebuf(p, true, true, silent)
		}
		xfree(p)
	} else if regname == '=' {
		p := get_expr_line()
		if p == nil {
			return FAIL_R
		}
		retval = put_in_typebuf(p, true, colon != 0, silent)
		xfree(p)
	} else if regname == '.' { // use last inserted text
		p := get_last_insert_save_r()
		if p == nil {
			emsg(_t(e_noinstext))
			return FAIL_R
		}
		retval = put_in_typebuf(p, false, colon != 0, silent)
		xfree(p)
	} else {
		reg := get_yank_register(regname, YREG_PASTE)
		if reg.y_array == nil {
			return FAIL_R
		}

		// Disallow remapping for ":@r".
		remap: C.int = colon != 0 ? REMAP_NONE : REMAP_YES

		// Insert lines into typeahead buffer, from last one to first one.
		put_reedit_in_typebuf(silent)
		i := reg.y_size
		for i > 0 {
			i -= 1
			// insert NL between lines and after last line if kMTLineWise
			if reg.y_type == kMTLineWise || i < reg.y_size - 1 || addcr != 0 {
				if ins_typebuf_r(transmute(^u8)(cstring("\n")), remap, 0, true, silent) == FAIL_R {
					return FAIL_R
				}
			}

			// Handle line-continuation for :@<register>
			str := reg.y_array[i].data
			free_str := false
			if colon != 0 && i > 0 {
				p := (^u8)(skipwhite(transmute(cstring)(str)))
				if p^ == '\\' || (p^ == '"' && (^u8)(uintptr(p)+1)^ == '\\' && (^u8)(uintptr(p)+2)^ == ' ') {
					str = execreg_line_continuation(reg.y_array, &i)
					free_str = true
				}
			}
			escaped := vim_strsave_escape_ks_r(str)
			if free_str {
				xfree(str)
			}
			retval = ins_typebuf_r(escaped, remap, 0, true, silent)
			xfree(escaped)
			if retval == FAIL_R {
				return FAIL_R
			}
			if colon != 0 && ins_typebuf_r(transmute(^u8)(cstring(":")), remap, 0, true, silent) == FAIL_R {
				return FAIL_R
			}
		}
		reg_executing = regname == 0 ? '"' : regname // disable the 'q' command
		pending_end_reg_executing = false
	}
	return retval
}

e_nolastcmd_no_prev :: proc "c"() -> cstring {
	return cstring("E748: No previously used register")
}

get_last_insert_save_r :: proc "c"() -> ^u8 {
	return get_last_insert_save_r2()
}

/// Insert a yank register: copy it into the Read buffer (CTRL-R).
@(export)
insert_reg :: proc "c" (regname: C.int, reg_arg: ^Yankreg_T, literally_arg: bool) -> C.int {
	retval: C.int = OK_R
	reg := reg_arg
	literally := literally_arg || is_literal_register(regname)

	os_breakcheck()
	if got_int {
		return FAIL_R
	}

	// check for valid regname
	if regname != 0 && !valid_yank_reg(regname, false) {
		return FAIL_R
	}

	arg: ^u8
	allocated: bool
	if regname == '.' { // Insert last inserted text.
		retval = stuff_inserted_r(0, 1, true)
	} else if get_spec_reg(regname, &arg, &allocated, true) {
		if arg == nil {
			return FAIL_R
		}
		stuffescaped_r(transmute(cstring)(arg), literally)
		if allocated {
			xfree(arg)
		}
	} else { // Name or number register.
		if reg == nil {
			reg = get_yank_register(regname, YREG_PASTE)
		}
		if reg.y_array == nil {
			retval = FAIL_R
		} else {
			for i: C.size_t = 0; i < reg.y_size; i += 1 {
				if regname == '-' && reg.y_type == kMTCharWise {
					dir: C.int = BACKWARD_DIR
					if (State & REPLACE_FLAG) != 0 {
						if u_save_cursor() == FAIL_R {
							return FAIL_R
						}
						del_chars_r(mb_charlen_r(transmute(cstring)(reg.y_array[0].data)), 1)
						curpos := win_cursor_r(curwin)^
						if oneright_r() == FAIL_R {
							// hit end of line, put forward instead
							dir = FORWARD_DIR
						}
						win_cursor_r(curwin)^ = curpos
					}

					AppendCharToRedobuff_r(Ctrl_R)
					AppendCharToRedobuff_r(regname)
					do_put(regname, nil, dir, 1, PUT_CURSEND)
				} else {
					stuffescaped_r(transmute(cstring)(reg.y_array[i].data), literally)
					// newline between lines and after last line if linewise
					if reg.y_type == kMTLineWise || i < reg.y_size - 1 {
						stuffcharReadbuff_r('\n')
					}
				}
			}
		}
	}

	return retval
}

/// If "regname" is a special register, return true and store its value.
@(export)
get_spec_reg :: proc "c" (regname: C.int, argp: ^^u8, allocated: ^bool, errmsg: bool) -> bool {
	argp^ = nil
	allocated^ = false
	switch regname {
	case '%': // file name
		if errmsg {
			check_fname_r()
		}
		argp^ = (^u8)(buf_read_ptr(curbuf, B_FNAME))
		return true

	case '#': // alternate file name
		argp^ = getaltfname_r(errmsg)
		return true

	case '=': // result of expression
		argp^ = get_expr_line()
		allocated^ = true
		return true

	case ':': // last command line
		if last_cmdline == nil && errmsg {
			emsg(_t(e_nolastcmd))
		}
		argp^ = last_cmdline
		return true

	case '/': // last search-pattern
		if last_search_pat() == nil && errmsg {
			emsg(_t(e_noprevre))
		}
		argp^ = last_search_pat()
		return true

	case '.': // last inserted text
		argp^ = get_last_insert_save_r()
		allocated^ = true
		if argp^ == nil && errmsg {
			emsg(_t(e_noinstext))
		}
		return true

	case Ctrl_F, Ctrl_P: // filename under cursor
		if !errmsg {
			return false
		}
		argp^ = file_name_at_cursor_r(FNAME_MESS | FNAME_HYP | (regname == Ctrl_P ? FNAME_EXP : 0), 1, nil)
		allocated^ = true
		return true

	case Ctrl_W, Ctrl_A: // word/WORD under cursor
		if !errmsg {
			return false
		}
		cnt := find_ident_under_cursor_r(argp, regname == Ctrl_W ? (FIND_IDENT | FIND_STRING) : FIND_STRING, nil)
		argp^ = cnt != 0 ? xmemdupz(transmute(rawptr)(argp^), cnt) : nil
		allocated^ = true
		return true

	case Ctrl_L: // line under cursor
		if !errmsg {
			return false
		}
		w_buffer := buf_read_ptr(curwin, W_BUFFER)
		argp^ = ml_get_buf(w_buffer, get_i32_off(win_cursor_r(curwin), 0))
		return true

	case '_': // black hole: always empty
		argp^ = transmute(^u8)(cstring(""))
		return true
	}

	return false
}

/// Paste a yank register into the command line (CTRL-R).
@(export)
cmdline_paste_reg :: proc "c" (regname: C.int, literally_arg: bool, remcr: bool) -> bool {
	literally := literally_arg || is_literal_register(regname)

	reg := get_yank_register(regname, YREG_PASTE)
	if reg.y_array == nil {
		return false
	}

	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		cmdline_paste_str_r(transmute(cstring)(reg.y_array[i].data), literally)

		// Insert ^M between lines, unless remcr.
		if i < reg.y_size - 1 && !remcr {
			cmdline_paste_str_r(cstring("\r"), literally)
		}

		os_breakcheck()
		if got_int {
			return false
		}
	}
	return true
}

/// Shift the delete registers: "9 cleared, "8 becomes "9, etc.
@(export)
shift_delete_registers :: proc "c" (y_append: bool) {
	free_register(&y_regs[9]) // free register "9
	n := 9
	for n > 1 {
		y_regs[n] = y_regs[n - 1]
		n -= 1
	}
	if !y_append {
		y_previous = &y_regs[1]
	}
	y_regs[1].y_array = nil // set register "1 to empty
}

// EXITFREE
@(export)
clear_registers :: proc "c" () {
	for i := 0; i < NUM_REGISTERS; i += 1 {
		free_register(&y_regs[i])
	}
}

/// Free contents of yankreg reg.
@(export)
free_register :: proc "c" (reg: ^Yankreg_T) {
	xfree_clear_reg(&reg.additional_data)
	if reg.y_array == nil {
		return
	}

	i := reg.y_size
	for i > 0 {
		i -= 1
		// API_CLEAR_STRING
		xfree(reg.y_array[i].data)
	}
	xfree(reg.y_array)
	reg.y_array = nil
}

xfree_clear_reg :: proc "c"(p: ^rawptr) {
	xfree(p^)
	p^ = nil
}

/// Copy a block range into a register.
yank_copy_line :: proc "c"(reg: ^Yankreg_T, bd: ^Block_Def, y_idx: C.size_t, exclude_trailing_space: bool) {
	if exclude_trailing_space {
		bd.endspaces = 0
	}
	sz := bd.startspaces + bd.endspaces + bd.textlen
	pnew := xmallocz_r(C.size_t(sz))
	reg.y_array[y_idx].data = pnew
	libc.memset(pnew, ' ', C.size_t(bd.startspaces))
	pnew = (^u8)(uintptr(pnew) + uintptr(bd.startspaces))
	libc.memmove(pnew, bd.textstart, C.size_t(bd.textlen))
	pnew = (^u8)(uintptr(pnew) + uintptr(bd.textlen))
	libc.memset(pnew, ' ', C.size_t(bd.endspaces))
	pnew = (^u8)(uintptr(pnew) + uintptr(bd.endspaces))
	if exclude_trailing_space {
		s := bd.textlen + bd.endspaces

		for s > 0 && ascii_iswhite_byte(((^u8)(uintptr(bd.textstart) + uintptr(s) - 1))^) {
			s = s - utf_head_off(transmute(cstring)(bd.textstart),
				transmute(cstring)((^u8)(uintptr(bd.textstart) + uintptr(s) - 1))) - 1
			pnew = (^u8)(uintptr(pnew) - 1)
		}
	}
	pnew^ = 0
	reg.y_array[y_idx].size = C.size_t(uintptr(pnew) - uintptr(reg.y_array[y_idx].data))
}

ascii_iswhite_byte :: #force_inline proc "c"(b: u8) -> bool {
	return b == ' ' || b == '\t'
}

@(export)
op_yank_reg :: proc "c" (oap: rawptr, message: bool, reg_arg: ^Yankreg_T, append: bool) {
	reg := reg_arg
	newreg: Yankreg_T // new yank register when appending
	yank_type := oap_get_i32(oap, OAP_MOTION_TYPE)
	yanklines := C.size_t(oap_get_i32(oap, OAP_LINE_COUNT))
	yankendlnum := oap_get_pos(oap, OAP_END).lnum
	bd: Block_Def

	curr := reg // copy of current register
	// append to existing contents
	if append && reg.y_array != nil {
		reg = &newreg
	} else {
		free_register(reg) // free previously yanked lines
	}

	// cursor at column 1 before+after, non-inclusive: always linewise
	if yank_type == kMTCharWise &&
		oap_get_pos(oap, OAP_START).col == 0 &&
		!oap_get_bool(oap, OAP_INCLUSIVE) &&
		(!oap_get_bool(oap, OAP_IS_VISUAL) || p_sel^ == 'o') &&
		oap_get_pos(oap, OAP_END).col == 0 &&
		yanklines > 1 {
		yank_type = kMTLineWise
		yankendlnum -= 1
		yanklines -= 1
	}

	reg.y_size = yanklines
	reg.y_type = yank_type
	reg.y_width = 0
	reg.y_array = transmute([^]Str16)(xcalloc(yanklines, size_of(Str16)))
	reg.additional_data = nil
	reg.timestamp = os_time()

	y_idx: C.size_t = 0
	lnum := oap_get_pos(oap, OAP_START).lnum

	if yank_type == kMTBlockWise {
		// Visual block mode
		reg.y_width = oap_get_i32(oap, OAP_END_VCOL) - oap_get_i32(oap, OAP_START_VCOL)

		if get_i32_off(curwin, W_CURSWANT) == MAXCOL && reg.y_width > 0 {
			reg.y_width -= 1
		}
	}

	for lnum <= yankendlnum {
		switch reg.y_type {
		case kMTBlockWise:
			block_prep_r(oap, &bd, lnum, false)
			yank_copy_line(reg, &bd, y_idx, oap_get_bool(oap, OAP_EXCL_TR_WS))

		case kMTLineWise:
			reg.y_array[y_idx] = cbuf_to_string_r(transmute(cstring)(ml_get(lnum)),
				C.size_t(ml_get_len_r2(lnum)))

		case kMTCharWise:
			charwise_block_prep_r(oap_get_pos(oap, OAP_START)^, oap_get_pos(oap, OAP_END)^,
				&bd, lnum, oap_get_bool(oap, OAP_INCLUSIVE))
			// make sure bd.textlen is not longer than the text
			tmp := C.int(libc.strlen(transmute(cstring)(bd.textstart)))
			if tmp < bd.textlen {
				bd.textlen = tmp
			}
			yank_copy_line(reg, &bd, y_idx, false)

		case:
			// kMTUnknown: NOTREACHED
		}
		lnum += 1
		y_idx += 1
	}

	if curr != reg { // append the new block to the old block
		new_ptr := transmute([^]Str16)(xmalloc(size_of(Str16) * (curr.y_size + reg.y_size)))
		j: C.size_t = 0
		for j < curr.y_size {
			new_ptr[j] = curr.y_array[j]
			j += 1
		}
		xfree(curr.y_array)
		curr.y_array = new_ptr

		if yank_type == kMTLineWise {
			// kMTLineWise overrides kMTCharWise and kMTBlockWise
			curr.y_type = kMTLineWise
		}

		// Concatenate last line of old with first line of new, unless Vi compat.
		if curr.y_type == kMTCharWise && _vim_strchr(transmute(cstring)(p_cpo), '>') == nil {
			pnew := (^u8)(xmalloc(curr.y_array[curr.y_size - 1].size + reg.y_array[0].size + 1))
			j -= 1
			last := &curr.y_array[j]
			libc.memcpy(pnew, last.data, last.size)
			libc.memcpy((^u8)(uintptr(pnew) + uintptr(last.size)), reg.y_array[0].data, reg.y_array[0].size + 1)
			xfree(last.data)
			last^ = Str16{data = pnew, size = last.size + reg.y_array[0].size}
			j += 1
			// API_CLEAR_STRING(reg->y_array[0])
			xfree(reg.y_array[0].data)
			y_idx = 1
		} else {
			y_idx = 0
		}
		for y_idx < reg.y_size {
			curr.y_array[j] = reg.y_array[y_idx]
			j += 1
			y_idx += 1
		}
		curr.y_size = j
		xfree(reg.y_array)
	}

	if message { // Display message about yank?
		if yank_type == kMTCharWise && yanklines == 1 {
			yanklines = 0
		}
		if yanklines > C.size_t(p_report) {
			namebuf: [100]u8

			if oap_get_i32(oap, OAP_REGNAME) == 0 {
				namebuf[0] = 0
			} else {
				libc.snprintf(&namebuf[0], size_of(namebuf),
					_t(cstring(" into \"%c")), C.int(oap_get_i32(oap, OAP_REGNAME)))
			}

			// redisplay now, so message is not deleted
			update_topline_r(curwin)
			if must_redraw != 0 {
				update_screen_r()
			}
			fmt: cstring
			if yank_type == kMTBlockWise {
				fmt = ngettext_r(cstring("block of %ld line yanked%s"),
					cstring("block of %ld lines yanked%s"), C.long(yanklines))
			} else {
				fmt = ngettext_r(cstring("%ld line yanked%s"),
					cstring("%ld lines yanked%s"), C.long(yanklines))
			}
			mbuf: [256]u8
			libc.snprintf(&mbuf[0], size_of(mbuf), _t(fmt), C.long(yanklines), &namebuf[0])
			msg_msg(transmute(cstring)(&mbuf[0]), 0)
		}
	}

	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		// Set "'[" and "']" marks.
		get_pos_r2(curbuf, B_OP_START)^ = oap_get_pos(oap, OAP_START)^
		get_pos_r2(curbuf, B_OP_END)^ = oap_get_pos(oap, OAP_END)^
		if yank_type == kMTLineWise {
			get_pos_r2(curbuf, B_OP_START).col = 0
			get_pos_r2(curbuf, B_OP_END).col = MAXCOL
		}
		if yank_type != kMTLineWise && !oap_get_bool(oap, OAP_INCLUSIVE) {
			// Exclude the end position.
			_ = decl_pos(get_pos_r2(curbuf, B_OP_END))
		}
	}
}

/// Format the register type as a string ("v", "V", "^V{width}").
@(export)
format_reg_type :: proc "c" (reg_type: C.int, reg_width: C.int, buf: [^]u8, bufsize: C.size_t) -> C.size_t {
	switch reg_type {
	case kMTLineWise:
		buf[0] = 'V'
		buf[1] = 0
		return 1
	case kMTCharWise:
		buf[0] = 'v'
		buf[1] = 0
		return 1
	case kMTBlockWise:
		return C.size_t(libc.snprintf(buf, bufsize, cstring("\x16%d"), reg_width + 1))
	case:
		buf[0] = 0
		return 0
	}
}

add_regtype_to_dict :: proc "c"(reg: ^Yankreg_T, dict: rawptr, buf: ^u8, bufsize: C.size_t) {
	// "reg" is NULL when pasting a special register, which is charwise.
	len := format_reg_type(reg != nil ? reg.y_type : kMTCharWise,
		reg != nil ? reg.y_width : 0, buf, bufsize)
	tv_dict_add_str_len_r2(dict, cstring("regtype"), 7, transmute(cstring)(buf), C.int(len))
}

/// Execute autocommands for TextYankPost.
@(export)
do_autocmd_textyankpost :: proc "c" (oap: rawptr, reg: ^Yankreg_T) {
	if typ_recursive || !has_event(EVENT_TEXTYANKPOST) {
		return
	}

	typ_recursive = true

	sve: Save_V_Event_T
	dict := get_v_event_r(&sve)

	// The yanked text contents.
	list := tv_list_alloc(C.ssize_t(reg.y_size))
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		tv_list_append_string(list, reg.y_array[i].data, C.ssize_t(reg.y_array[i].size))
	}
	(^C.int)(uintptr(list) + 72)^ = VAR_FIXED_VAL
	tv_dict_add_list_m(dict, cstring("regcontents"), 11, list)

	// Register type.
	buf: [NUMBUFLEN + 2]u8
	add_regtype_to_dict(reg, dict, &buf[0], size_of(buf))

	// Name of requested register, or empty string for unnamed operation.
	buf[0] = u8(oap_get_i32(oap, OAP_REGNAME))
	buf[1] = 0
	tv_dict_add_str_m(dict, cstring("regname"), 7, transmute(cstring)(&buf[0]))

	// Motion type: inclusive or exclusive.
	tv_dict_add_bool_r(dict, cstring("inclusive"), 9,
		oap_get_bool(oap, OAP_INCLUSIVE) ? kBoolVarTrue : kBoolVarFalse)

	// Kind of operation: yank, delete, change).
	buf[0] = u8(get_op_char_r(oap_get_i32(oap, OAP_OP_TYPE)))
	buf[1] = 0
	tv_dict_add_str_m(dict, cstring("operator"), 8, transmute(cstring)(&buf[0]))

	// Selection type: visual or not.
	tv_dict_add_bool_r(dict, cstring("visual"), 6,
		oap_get_bool(oap, OAP_IS_VISUAL) ? kBoolVarTrue : kBoolVarFalse)

	tv_dict_set_keys_readonly_r(dict)
	textlock += 1
	apply_autocmds(EVENT_TEXTYANKPOST, nil, nil, false, curbuf)
	textlock -= 1
	restore_v_event_r(dict, &sve)

	typ_recursive = false
}

VAR_FIXED_VAL :: 2 // VAR_FIXED from types_defs (0 unlocked, 1 readonly, 2 fixed)

/// Trigger TextPutPre or TextPutPost autocommand.
put_do_autocmd :: proc "c"(regname: C.int, reg: ^Yankreg_T, insert: ^Str16, post: bool, dir: C.int) {
	if put_recursive || (regname == '_' && reg == nil) {
		return
	}

	if regname != '.' && insert == nil && reg == nil {
		// pasting text in normal mode in a terminal buffer
		return
	}

	sve: Save_V_Event_T
	v_event := get_v_event_r(&sve)

	list := tv_list_alloc(reg != nil ? C.ssize_t(reg.y_size) : 1)

	if regname == '.' {
		if last_insert_ga.ga_data != nil {
			// last inserted text for "regcontents"
			tv_list_append_string(list, (^u8)(last_insert_ga.ga_data), C.ssize_t(last_insert_ga.ga_len))
		}
	} else if insert != nil {
		tv_list_append_string(list, insert.data, C.ssize_t(insert.size))
	} else {
		for n: C.size_t = 0; n < reg.y_size; n += 1 {
			tv_list_append_string(list, reg.y_array[n].data, C.ssize_t(reg.y_array[n].size))
		}
	}

	(^C.int)(uintptr(list) + 72)^ = VAR_FIXED_VAL
	tv_dict_add_list_m(v_event, cstring("regcontents"), 11, list)

	buf: [NUMBUFLEN + 2]u8

	// register name or empty string for unnamed operation
	buf[0] = u8(regname)
	buf[1] = 0
	buflen: C.size_t = buf[0] == 0 ? 0 : 1
	tv_dict_add_str_len_r2(v_event, cstring("regname"), 7, transmute(cstring)(&buf[0]), C.int(buflen))

	// kind of operation (P, p)
	buf[0] = dir == BACKWARD_DIR ? 'P' : 'p'
	buf[1] = 0
	tv_dict_add_str_len_r2(v_event, cstring("operator"), 8, transmute(cstring)(&buf[0]), 1)

	add_regtype_to_dict(reg, v_event, &buf[0], size_of(buf))

	tv_dict_add_bool_r(v_event, cstring("visual"), 6, VIsual_active ? kBoolVarTrue : kBoolVarFalse)

	// Lock the dictionary and its keys
	tv_dict_set_keys_readonly_r(v_event)

	put_recursive = true
	textlock += 1
	if post {
		apply_autocmds(EVENT_TEXTPUTPOST, nil, nil, false, curbuf)
	} else {
		apply_autocmds(EVENT_TEXTPUTPRE, nil, nil, false, curbuf)
	}
	textlock -= 1
	put_recursive = false

	// Empty the dictionary, v:event is still valid
	restore_v_event_r(v_event, &sve)
}

/// Yanks the text between oap->start and oap->end into a yank register.
@(export)
op_yank :: proc "c" (oap: rawptr, message: bool) -> bool {
	// check for read-only register
	regname := oap_get_i32(oap, OAP_REGNAME)
	if regname != 0 && !valid_yank_reg(regname, true) {
		beep_flush_r()
		return false
	}
	if regname == '_' {
		return true // black hole: nothing to do
	}

	reg := get_yank_register(regname, YREG_YANK)
	op_yank_reg(oap, message, reg, is_append_register(regname))
	set_clipboard(regname, reg)
	do_autocmd_textyankpost(oap, reg)
	return true
}

beep_flush_r :: proc "c"() {
	beep_flush_r2()
}

// xmallocz: allocate size+1 bytes, zeroed
xmallocz_r :: proc "c"(size: C.size_t) -> ^u8 {
	p := (^u8)(xmalloc(size + 1))
	libc.memset(p, 0, size + 1)
	return p
}
// [register part 2: do_put, :registers display, get_reg_contents, write_reg_*]

@(private="file")
get_pos_r :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(base) + off)
}


@(private="file")
cargv_at :: #force_inline proc "c"(p: ^rawptr, i: C.size_t) -> ^u8 {
	return (^u8)((^rawptr)(uintptr(p) + uintptr(i) * size_of(rawptr))^)
}

foreign _ {
	@(link_name = "beep_flush")
	beep_flush_r2 :: proc "c" () ---
	@(link_name = "get_last_insert_save")
	get_last_insert_save_r2 :: proc "c" () -> ^u8 ---
	@(link_name = "buf_is_empty")
	buf_is_empty_r :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "ml_get_len")
	ml_get_len_r2 :: proc "c" (lnum: C.int) -> C.int ---
}

@(private="file")
_beep_flush :: proc "c"() {
	beep_flush_r2()
}

@(private="file")
_get_last_insert_save :: proc "c"() -> ^u8 {
	return get_last_insert_save_r2()
}

// ── do_put ───────────────────────────────────────────────────────────────────

/// Put contents of register "regname" into the text.
@(export)
do_put :: proc "c" (regname: C.int, reg_arg: ^Yankreg_T, dir_arg: C.int, count_arg: C.int, flags: C.int) {
	reg := reg_arg
	dir := dir_arg
	count := count_arg
	totlen: C.size_t = 0
	lnum: C.int = 0
	y_type: C.int
	y_size: C.size_t = 0
	y_width: C.int = 0
	vcol: C.int = 0
	y_array: [^]Str16 = nil
	nr_lines: C.int = 0
	allocated := false
	orig_start := get_pos_r(curbuf, B_OP_START)^
	orig_end := get_pos_r(curbuf, B_OP_END)^
	cur_ve_flags := get_ve_flags_r(curwin)

	cursor_pos :: #force_inline proc "c"() -> ^Pos_T {
		return (^Pos_T)(uintptr(curwin) + W_CURSOR)
	}
	op_start :: #force_inline proc "c"() -> ^Pos_T {
		return get_pos_r(curbuf, B_OP_START)
	}
	op_end :: #force_inline proc "c"() -> ^Pos_T {
		return get_pos_r(curbuf, B_OP_END)
	}

	// Remove any preinserted text
	if ins_compl_preinsert_effect_r() {
		ins_compl_delete_r(false)
	}

	op_start()^ = cursor_pos()^ // default for '[ mark
	op_end()^ = cursor_pos()^ // default for '] mark

	done := false // goto-end flag

	// Using inserted text works differently.
	if regname == '.' && reg == nil {
		non_linewise_vis := VIsual_active && VIsual_mode != 'V'

		command_start_char: rune = non_linewise_vis ? 'c' : ((flags & PUT_LINE) != 0 ? 'i' : (dir == FORWARD_DIR ? 'a' : 'i'))

		has_textput_events := has_event(EVENT_TEXTPUTPRE) || has_event(EVENT_TEXTPUTPOST)
		if has_textput_events {
			add_last_insert += 1
		}

		// To avoid 'autoindent' on linewise puts, create a new line with `:put _`.
		if (flags & PUT_LINE) != 0 {
			save_add_last_insert := add_last_insert
			add_last_insert = 0
			stuffcharReadbuff_r(K_COMMAND)
			if dir == FORWARD_DIR {
				stuffReadbuffLen_r(cstring("put _"), 5)
			} else {
				stuffReadbuffLen_r(cstring("put! _"), 6)
			}
			stuffcharReadbuff_r(C.int(CAR))
			add_last_insert = save_add_last_insert
		}

		if (flags & PUT_LINE) != 0 {
			stuffcharReadbuff_r(C.int(command_start_char))
			for count > 0 {
				stuff_inserted_r(0, 1, count != 1)
				count -= 1
				if count != 1 {
					s: [4]u8 = {'\n', ' ', Ctrl_U, 0}
					stuffReadbuffLen_r(transmute(cstring)(&s[0]), 3)
				}
			}
		} else {
			stuff_inserted_r(C.int(command_start_char), count, false)
		}

		// Text inserted later; fire TextPutPre/Post now.
		if has_event(EVENT_TEXTPUTPRE) {
			put_do_autocmd('.', nil, nil, false, dir)
		}
		if has_event(EVENT_TEXTPUTPOST) {
			put_do_autocmd('.', nil, nil, true, dir)
		}

		if has_textput_events {
			add_last_insert -= 1
			if add_last_insert == 0 {
				ga_clear_r(&last_insert_ga)
			}
		}

		// Simulate cursor-to-next-char motion after the insert.
		if (flags & PUT_CURSEND) != 0 {
			if (flags & PUT_LINE) != 0 {
				stuffReadbuff_r(cstring("j0"))
			} else {
				cp := get_cursor_pos_ptr_r()
				one_past_line := cp^ == 0
				eol := false
				if !one_past_line {
					eol = (^u8)(uintptr(cp) + uintptr(utfc_ptr2len(transmute(cstring)(cp))))^ == 0
				}

				ve_allows := cur_ve_flags == kOptVeFlagAll_V || cur_ve_flags == kOptVeFlagOnemore_V
				eof := get_i32_off(curbuf, B_ML_LINE_COUNT) == cursor_pos().lnum && one_past_line
				if ve_allows || !(eol || eof) {
					stuffcharReadbuff_r('l')
				}
			}
		} else if (flags & PUT_LINE) != 0 {
			stuffReadbuff_r(cstring("g'["))
		}

		// Save cursor position for ".p undo.
		if command_start_char == 'a' {
			if u_save(cursor_pos().lnum, cursor_pos().lnum + 1) == FAIL_R {
				return
			}
		}
		return
	}

	// For special registers create a fake yank register.
	insert_string: Str16
	if reg == nil && get_spec_reg(regname, &insert_string.data, &allocated, true) {
		if insert_string.data == nil {
			return
		}
	}

	if buf_read_ptr(curbuf, B_TERMINAL) == nil {
		// start undo now to avoid autocommand invalidating y_array
		if u_save(cursor_pos().lnum, cursor_pos().lnum + 1) == FAIL_R {
			return
		}
	}

	if insert_string.data != nil {
		insert_string.size = libc.strlen(transmute(cstring)(insert_string.data))
		y_type = kMTCharWise
		if regname == '=' {
			// split the string at NL characters; loop twice (count then fill)
			for true {
				y_size = 0
				ptr := insert_string.data
				ptrlen := insert_string.size
				for ptr != nil {
					if y_array != nil {
						y_array[y_size].data = ptr
					}
					y_size += 1
					tmp := transmute(^u8)(_vim_strchr(transmute(cstring)(ptr), 10))
					if tmp == nil {
						if y_array != nil {
							y_array[y_size - 1].size = ptrlen
						}
					} else {
						if y_array != nil {
							tmp^ = 0
							y_array[y_size - 1].size = C.size_t(uintptr(tmp) - uintptr(ptr))
							ptrlen -= y_array[y_size - 1].size + 1
						}
						tmp = (^u8)(uintptr(tmp) + 1)
						// A trailing '\n' makes the register linewise.
						if tmp^ == 0 {
							y_type = kMTLineWise
							break
						}
					}
					ptr = tmp
				}
				if y_array != nil {
					break
				}
				y_array = transmute([^]Str16)(xmalloc(C.size_t(y_size) * size_of(Str16)))
			}
		} else {
			y_size = 1 // use fake one-line yank register
			y_array = transmute([^]Str16)(&insert_string)
		}
		if has_event(EVENT_TEXTPUTPRE) {
			put_do_autocmd(regname, nil, &insert_string, false, dir)
		}
	} else {
		if has_event(EVENT_TEXTPUTPRE) {
			save_reg := reg
			if reg == nil {
				reg = get_yank_register(regname, YREG_PASTE)
			}
			put_do_autocmd(regname, reg, nil, false, dir)
			reg = save_reg
		}
		if reg == nil {
			reg = get_yank_register(regname, YREG_PASTE)
		}

		y_type = reg.y_type
		y_width = reg.y_width
		y_size = reg.y_size
		y_array = reg.y_array
	}

	if buf_read_ptr(curbuf, B_TERMINAL) != nil {
		terminal_paste_r(count, y_array, y_size)
		done = true
	} else {

		split_pos: C.int = 0
		if y_type == kMTLineWise {
			if (flags & PUT_LINE_SPLIT) != 0 {
				// "p"/"P" in Visual mode: split lines to put text between.
				if u_save_cursor() == FAIL_R {
					done = true
				}
				if !done {
					curline := get_cursor_line_ptr_r()
					p := get_cursor_pos_ptr_r()
					p_orig := p
					plen := C.size_t(get_cursor_pos_len_r())
					if dir == FORWARD_DIR && p^ != 0 {
						p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
					}
					// needed later for extmark_splice()
					split_pos = C.int(uintptr(p) - uintptr(curline))

					ptr := xmemdupz(p, plen - C.size_t(uintptr(p) - uintptr(p_orig)))
					ml_append_c(cursor_pos().lnum, ptr, 0, false)
					xfree(ptr)

					ptr = xmemdupz(get_cursor_line_ptr_r(), C.size_t(split_pos))
					ml_replace_c(cursor_pos().lnum, ptr, false)
					nr_lines += 1
					dir = FORWARD_DIR

					buf_updates_send_changes_r(curbuf, cursor_pos().lnum, 1, 1)
				}
			}
			if (flags & PUT_LINE_FORWARD) != 0 && !done {
				// Must be "p" for a Visual block: put lines below the block.
				cursor_pos()^ = get_pos_r(curbuf, B_VISUAL + 12)^
				dir = FORWARD_DIR
			}
			if !done {
				op_start()^ = cursor_pos()^
				op_end()^ = cursor_pos()^
			}
		}

		if !done {
			if (flags & PUT_LINE) != 0 { // ":put" or "p" in Visual line mode.
				y_type = kMTLineWise
			}

			if y_size == 0 || y_array == nil {
				semsg_fmt(cstring("E353: Nothing in register %s"),
					regname == 0 ? transmute(rawptr)(cstring("\"")) : transmute(rawptr)(transchar_r(regname)))
				done = true
			}
		}

		Block: if !done {
			if y_type == kMTBlockWise {
				lnum = cursor_pos().lnum + C.int(y_size) + 1
				lnum = min(lnum, get_i32_off(curbuf, B_ML_LINE_COUNT) + 1)
				if u_save(cursor_pos().lnum - 1, lnum) == FAIL_R {
					break Block
				}
			} else if y_type == kMTLineWise {
				lnum = cursor_pos().lnum
				// Correct line number for closed fold.
				if dir == BACKWARD_DIR {
					hasFolding(curwin, lnum, &lnum, nil)
				} else {
					hasFolding(curwin, lnum, nil, &lnum)
				}
				if dir == FORWARD_DIR {
					lnum += 1
				}
				// In an empty buffer the empty line is replaced; include it.
				if (buf_is_empty_r(curbuf) ? u_save(0, 2) : u_save(lnum - 1, lnum)) == FAIL_R {
					break Block
				}
				if dir == FORWARD_DIR {
					cursor_pos().lnum = lnum - 1
				} else {
					cursor_pos().lnum = lnum
				}
				op_start()^ = cursor_pos()^ // for mark_adjust()
			} else if u_save_cursor() == FAIL_R {
				break Block
			}

			if cur_ve_flags == kOptVeFlagAll_V && y_type == kMTCharWise {
				if gchar_cursor_r() == '\t' {
					viscol := getviscol_r()
					ts := (^i64)(uintptr(curbuf) + B_P_TS)^
					// Don't insert spaces when "p" on last pos of tab / "P" on first.
					if (dir == FORWARD_DIR ? tabstop_padding_r(viscol, ts, (^C.int)(uintptr(curbuf) + B_P_VTS_ARRAY)) != 1 : cursor_pos().coladd > 0) {
						coladvance_force_r(viscol)
					} else {
						cursor_pos().coladd = 0
					}
				} else if cursor_pos().coladd > 0 || gchar_cursor_r() == 0 {
					coladvance_force_r(getviscol_r() + (dir == FORWARD_DIR ? 1 : 0))
				}
			}

			lnum = cursor_pos().lnum
			col := cursor_pos().col

			// Block mode
			if y_type == kMTBlockWise {
				incr: C.int = 0
				bd: Block_Def
				c := gchar_cursor_r()
				endcol2: C.int = 0

				if dir == FORWARD_DIR && c != 0 {
					if cur_ve_flags == kOptVeFlagAll_V {
						getvcol_r(curwin, cursor_pos(), &col, nil, &endcol2, 0)
					} else {
						getvcol_r(curwin, cursor_pos(), nil, nil, &col, 0)
					}

					// move to start of next multi-byte character
					cursor_pos().col += C.int(utfc_ptr2len(transmute(cstring)(get_cursor_pos_ptr_r())))
					col += 1
				} else {
					getvcol_r(curwin, cursor_pos(), &col, nil, &endcol2, 0)
				}

				col += cursor_pos().coladd
				if cur_ve_flags == kOptVeFlagAll_V &&
					(cursor_pos().coladd > 0 || endcol2 == cursor_pos().col) {
					if dir == FORWARD_DIR && c == 0 {
						col += 1
					}
					if dir != FORWARD_DIR && c != 0 && cursor_pos().coladd > 0 {
						cursor_pos().col += 1
					}
					if c == '\t' {
						if dir == BACKWARD_DIR && cursor_pos().col != 0 {
							cursor_pos().col -= 1
						}
						if dir == FORWARD_DIR && col - 1 == endcol2 {
							cursor_pos().col += 1
						}
					}
				}
				cursor_pos().coladd = 0
				bd.textcol = 0
				for i: C.size_t = 0; i < y_size; i += 1 {
					spaces: C.int = 0
					shortline: u8
					// can just be 0 or 1, needed past buffer end
					lines_appended: C.int = 0

					bd.startspaces = 0
					bd.endspaces = 0
					vcol = 0
					delcount: C.int = 0

					// add a new line
					if cursor_pos().lnum > get_i32_off(curbuf, B_ML_LINE_COUNT) {
						if !ml_append_c(get_i32_off(curbuf, B_ML_LINE_COUNT), transmute(^u8)(cstring("")), 1, false) {
							break
						}
						nr_lines += 1
						lines_appended = 1
					}
					// advance to the position to insert at
					oldp := get_cursor_line_ptr_r()
					oldlen := get_cursor_line_len_r()

					p := oldp
					vcol = 0
					for vcol < col && p^ != 0 {
						incr = win_chartabsize_r(curwin, p, vcol)
						vcol += incr
						p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
					}
					ptr := p
					bd.textcol = C.int(uintptr(ptr) - uintptr(oldp))

					shortline = (vcol < col) || (vcol == col && ptr^ == 0) ? 1 : 0

					if vcol < col { // line too short, pad with spaces
						bd.startspaces = col - vcol
					} else if vcol > col {
						bd.endspaces = vcol - col
						bd.startspaces = incr - bd.endspaces
						bd.textcol -= 1
						delcount = 1
						bd.textcol -= utf_head_off(transmute(cstring)(oldp),
							transmute(cstring)((^u8)(uintptr(oldp) + uintptr(bd.textcol))))
						if ((^u8)(uintptr(oldp) + uintptr(bd.textcol)))^ != '\t' {
							// Only a Tab can be split into spaces.
							delcount = 0
							bd.endspaces = 0
						}
					}

					yanklen := C.int(y_array[i].size)

					if (flags & PUT_BLOCK_INNER) == 0 {
						// spaces required to fill right side of block
						spaces = y_width + 1

						q := y_array[i].data
						for q^ != 0 {
							spaces -= win_chartabsize_r(curwin, q, 0)
							q = (^u8)(uintptr(q) + uintptr(utfc_ptr2len(transmute(cstring)(q))))
						}
						spaces = max(spaces, 0)
					}

					// check for multiplication overflow
					if yanklen + spaces != 0 &&
						count > (2147483647 - (bd.startspaces + bd.endspaces)) / (yanklen + spaces) {
						emsg(_t(e_resulting_text_too_long))
						break
					}

					totlen = C.size_t(count) * C.size_t(yanklen + spaces) +
						C.size_t(bd.startspaces) + C.size_t(bd.endspaces)
					newp := (^u8)(xmalloc(totlen + C.size_t(oldlen) + 1))

					// copy part up to cursor to new line
					ptr = newp
					libc.memmove(ptr, oldp, C.size_t(bd.textcol))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.textcol))

					// may insert some spaces before the new text
					libc.memset(ptr, ' ', C.size_t(bd.startspaces))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.startspaces))

					// insert the new text
					j: C.int = 0
					for j < count {
						libc.memmove(ptr, y_array[i].data, C.size_t(yanklen))
						ptr = (^u8)(uintptr(ptr) + uintptr(yanklen))

						// trailing spaces only if there's text behind
						if (j < count - 1 || shortline == 0) && spaces > 0 {
							libc.memset(ptr, ' ', C.size_t(spaces))
							ptr = (^u8)(uintptr(ptr) + uintptr(spaces))
						} else {
							totlen -= C.size_t(spaces) // didn't use these spaces
						}
						j += 1
					}

					// may insert some spaces after the new text
					libc.memset(ptr, ' ', C.size_t(bd.endspaces))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.endspaces))

					// move the text after the cursor to end of line
					columns := oldlen - bd.textcol - delcount + 1
					libc.memmove(ptr, (^u8)(uintptr(oldp) + uintptr(bd.textcol + delcount)), C.size_t(columns))
					ml_replace_c(cursor_pos().lnum, newp, false)
					extmark_splice_cols_r(curbuf, cursor_pos().lnum - 1, bd.textcol,
						delcount, C.int(totlen) + lines_appended, kExtmarkUndo)

					cursor_pos().lnum += 1
					if i == 0 {
						cursor_pos().col += bd.startspaces
					}
				}

				changed_lines_r(curbuf, lnum, 0,
					op_start().lnum + C.int(y_size) - nr_lines, nr_lines, true)

				// Set '[ mark.
				op_start()^ = cursor_pos()^
				op_start().lnum = lnum

				// adjust '] mark
				op_end().lnum = cursor_pos().lnum - 1
				op_end().col = max(bd.textcol + C.int(totlen) - 1, 0)
				op_end().coladd = 0
				if (flags & PUT_CURSEND) != 0 {
					cursor_pos()^ = op_end()^
					cursor_pos().col += 1

					// in Insert mode we might be after the NUL
					len := get_cursor_line_len_r()
					cursor_pos().col = min(cursor_pos().col, len)
				} else {
					cursor_pos().lnum = lnum
				}
			} else {
				yanklen := C.int(y_array[0].size)

				// Character or Line mode
				if y_type == kMTCharWise {
					// FORWARD is BACKWARD on the next char
					if dir == FORWARD_DIR && gchar_cursor_r() != 0 {
						bytelen := C.int(utfc_ptr2len(transmute(cstring)(get_cursor_pos_ptr_r())))

						col += bytelen
						if yanklen != 0 {
							cursor_pos().col += bytelen
							op_end().col += bytelen
						}
					}
					op_start()^ = cursor_pos()^
				} else if dir == BACKWARD_DIR {
					// Line mode: BACKWARD is FORWARD on previous line
					lnum -= 1
				}
				new_cursor := cursor_pos()^

				// simple case: insert into one line at a time
				if y_type == kMTCharWise && y_size == 1 {
					end_lnum: C.int = 0
					start_lnum := lnum
					first_byte_off: C.int = 0

					if VIsual_active {
						end_lnum = max(get_pos_r(curbuf, B_VISUAL + 12).lnum, get_pos_r(curbuf, B_VISUAL).lnum)
						if end_lnum > start_lnum {
							pos := Pos_T{lnum = lnum, col = col, coladd = 0}
							getvcol_r(curwin, &pos, nil, &vcol, nil, 0)
						}
					}

					if count == 0 || yanklen == 0 {
						if VIsual_active {
							lnum = end_lnum
						}
					} else if count > 2147483647 / yanklen {
						// multiplication overflow
						emsg(_t(e_resulting_text_too_long))
					} else {
						totlen = C.size_t(count) * C.size_t(yanklen)
						for true {
							oldp := ml_get(lnum)
							oldlen := ml_get_len_r2(lnum)
							if lnum > start_lnum {
								pos := Pos_T{lnum = lnum}
								if getvpos_r(curwin, &pos, vcol) == OK_R {
									col = pos.col
								} else {
									col = MAXCOL
								}
							}
							if VIsual_active && col > oldlen {
								lnum += 1
								continue
							}
							newp := (^u8)(xmalloc(totlen + C.size_t(oldlen) + 1))
							libc.memmove(newp, oldp, C.size_t(col))
							ptr := (^u8)(uintptr(newp) + uintptr(col))
							i: C.size_t = 0
							for i < C.size_t(count) {
								libc.memmove(ptr, y_array[0].data, C.size_t(yanklen))
								ptr = (^u8)(uintptr(ptr) + uintptr(yanklen))
								i += 1
							}
							libc.memmove(ptr, (^u8)(uintptr(oldp) + uintptr(col)), C.size_t(oldlen - col) + 1) // +1 NUL
							ml_replace_c(lnum, newp, false)

							// byte offset of last character
							first_byte_off = utf_head_off(transmute(cstring)(newp), transmute(cstring)((^u8)(uintptr(ptr) - 1)))

							// Place cursor on last putted char.
							if lnum == cursor_pos().lnum {
								changed_cline_bef_curs_r(curwin)
								invalidate_botline_win_r(curwin)
								cursor_pos().col += C.int(totlen) - 1
							}
							changed_bytes_r(lnum, col)
							extmark_splice_cols_r(curbuf, lnum - 1, col, 0, C.int(totlen), kExtmarkUndo)
							if VIsual_active {
								lnum += 1
							}
							if !(VIsual_active && lnum <= end_lnum) {
								break
							}
						}

						if VIsual_active { // reset lnum to last visual line
							lnum -= 1
						}
					}

					// put '] at first byte of last character
					op_end()^ = cursor_pos()^
					op_end().col -= first_byte_off

					// CTRL-O p in Insert mode: cursor after last char
					if totlen != 0 && (restart_edit != 0 || (flags & PUT_CURSEND) != 0) {
						cursor_pos().col += 1
					} else {
						cursor_pos().col -= first_byte_off
					}
				} else {
					new_lnum := new_cursor.lnum
					indent: C.int
					orig_indent: C.int = 0
					indent_diff: C.int = 0
					first_indent := true
					lendiff: C.int = 0

					if (flags & PUT_FIXINDENT) != 0 {
						orig_indent = get_indent_r()
					}

					cnt: C.int = 1
					for cnt <= count {
						i: C.size_t = 0
						if y_type == kMTCharWise {
							// Split current line in two at insert position.
							lnum = new_cursor.lnum
							srcptr := (^u8)(uintptr(ml_get(lnum)) + uintptr(col))
							ptrlen := C.size_t(ml_get_len_r2(lnum)) - C.size_t(col)
							totlen = y_array[y_size - 1].size
							newp := (^u8)(xmalloc(ptrlen + totlen + 1))
							libc.memcpy(newp, y_array[y_size - 1].data, totlen)
							libc.memcpy((^u8)(uintptr(newp) + uintptr(totlen)), srcptr, ptrlen + 1)
							ml_append_c(lnum, newp, 0, false)
							new_lnum += 1
							xfree(newp)

							oldp := ml_get(lnum)
							newp2 := (^u8)(xmalloc(C.size_t(col) + C.size_t(yanklen) + 1))
							libc.memmove(newp2, oldp, C.size_t(col))
							libc.memmove((^u8)(uintptr(newp2) + uintptr(col)), y_array[0].data, C.size_t(yanklen) + 1)
							ml_replace_c(lnum, newp2, false)

							cursor_pos().lnum = lnum
							i = 1
						}

						mfailed := false
						for i < y_size {
							if y_type != kMTCharWise || i < y_size - 1 {
								if !ml_append_c(lnum, y_array[i].data, 0, false) {
									mfailed = true
									break
								}
								new_lnum += 1
							}
							lnum += 1
							nr_lines += 1
							if (flags & PUT_FIXINDENT) != 0 {
								old_pos := cursor_pos()^
								cursor_pos().lnum = lnum
								ptr := ml_get(lnum)
								if cnt == count && i == y_size - 1 {
									lendiff = ml_get_len_r2(lnum)
								}
								if ptr^ == '#' && preprocs_left_r() {
									indent = 0 // Leave # lines at start
								} else if ptr^ == 0 {
									indent = 0 // Ignore empty lines
								} else if first_indent {
									indent_diff = orig_indent - get_indent_r()
									indent = orig_indent
									first_indent = false
								} else {
									indent = get_indent_r() + indent_diff
									if indent < 0 {
										indent = 0
									}
								}
								set_indent_r(indent, SIN_NOMARK)
								cursor_pos()^ = old_pos
								// remember how many chars were removed
								if cnt == count && i == y_size - 1 {
									lendiff -= ml_get_len_r2(lnum)
								}
							}
							i += 1
						}

						if !mfailed {
							totsize: i64 = 0
							lastsize: C.int = 0
							if y_type == kMTCharWise ||
								(y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) != 0) {
								k: C.size_t = 0
								for k < y_size - 1 {
									totsize += i64(y_array[k].size) + 1
									k += 1
								}
								lastsize = C.int(y_array[y_size - 1].size)
								totsize += i64(lastsize)
							}
							if y_type == kMTCharWise {
								extmark_splice_r(curbuf, new_cursor.lnum - 1, col, 0, 0, 0,
									C.int(y_size) - 1, lastsize, totsize, kExtmarkUndo)
							} else if y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) != 0 {
								// Account for last pasted NL + last NL
								extmark_splice_r(curbuf, new_cursor.lnum - 1, split_pos, 0, 0, 0,
									C.int(y_size) + 1, 0, totsize + 2, kExtmarkUndo)
							}

							if cnt == 1 {
								new_lnum = lnum
							}
						}
						cnt += 1
					}

					// Adjust marks.
					if y_type == kMTLineWise {
						op_start().col = 0
						if dir == FORWARD_DIR {
							op_start().lnum += 1
						}
					}

					kind: C.int = (y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) == 0) ? kExtmarkUndo : kExtmarkNOOP
					mark_adjust(op_start().lnum + (y_type == kMTCharWise ? 1 : 0),
						MAXLNUM, nr_lines, 0, kind)

					// note changed text for displaying and folding
					if y_type == kMTCharWise {
						changed_lines_r(curbuf, cursor_pos().lnum, col,
							cursor_pos().lnum + 1, nr_lines, true)
					} else {
						changed_lines_r(curbuf, op_start().lnum, 0,
							op_start().lnum, nr_lines, true)
					}

					// Put '] mark on first byte of last inserted character.
					op_end().lnum = new_lnum
					col = max(0, C.int(y_array[y_size - 1].size) - lendiff)
					if col > 1 {
						op_end().col = col - 1
						if y_array[y_size - 1].size > 0 {
							op_end().col -= utf_head_off(
								transmute(cstring)(y_array[y_size - 1].data),
								transmute(cstring)((^u8)(uintptr(y_array[y_size - 1].data) + uintptr(y_array[y_size - 1].size - 1))))
						}
					} else {
						op_end().col = 0
					}

					if (flags & PUT_CURSLINE) != 0 {
						// ":put": cursor on last inserted line
						cursor_pos().lnum = lnum
						beginline(BL_WHITE | BL_FIX)
					} else if (flags & PUT_CURSEND) != 0 {
						// cursor after inserted text
						if y_type == kMTLineWise {
							if lnum >= get_i32_off(curbuf, B_ML_LINE_COUNT) {
								cursor_pos().lnum = get_i32_off(curbuf, B_ML_LINE_COUNT)
							} else {
								cursor_pos().lnum = lnum + 1
							}
							cursor_pos().col = 0
						} else {
							cursor_pos().lnum = new_lnum
							cursor_pos().col = col
							op_end()^ = cursor_pos()^
							if col > 1 {
								op_end().col = col - 1
							}
						}
					} else if y_type == kMTLineWise {
						// cursor on first non-blank of first inserted line
						cursor_pos().col = 0
						if dir == FORWARD_DIR {
							cursor_pos().lnum += 1
						}
						beginline(BL_WHITE | BL_FIX)
					} else { // cursor on first inserted character
						cursor_pos()^ = new_cursor
					}
				}
			}

			msgmore_r(nr_lines)
			set_i32_off(curwin, W_SET_CURSWANT, 1)

			// Make sure cursor is not after the NUL.
			len := get_cursor_line_len_r()
			if cursor_pos().col > len {
				if cur_ve_flags == kOptVeFlagAll_V {
					cursor_pos().coladd = cursor_pos().col - len
				}
				cursor_pos().col = len
			}
		} // Block:
	} // !terminal

	// end:
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
		get_pos_r(curbuf, B_OP_START)^ = orig_start
		get_pos_r(curbuf, B_OP_END)^ = orig_end
	}

	if has_event(EVENT_TEXTPUTPOST) {
		if insert_string.data == nil {
			put_do_autocmd(regname, reg, nil, true, dir)
		} else {
			put_do_autocmd(regname, nil, &insert_string, true, dir)
		}
	}

	if allocated {
		xfree(insert_string.data)
	}
	if regname == '=' {
		xfree(y_array)
	}

	if buf_read_ptr(curbuf, B_TERMINAL) == nil {
		VIsual_active = false
	}

	// If cursor is past EOL put it at the end.
	adjust_cursor_eol_r()
}

kOptVeFlagAll_V :: 0x04
kOptVeFlagOnemore_V :: 0x08

/// display a string for do_dis(); truncate at end of screen line
@(private="file")
dis_msg :: proc "c"(p_arg: ^u8, skip_esc: bool) {
	p := p_arg
	n := Columns - 6
	for p^ != 0 &&
	!(p^ == 27 && skip_esc && (^u8)(uintptr(p) + 1)^ == 0) {
		cell := ptr2cells(transmute(cstring)(p))
		if n-cell < 0 {
			break
		}
		n -= cell
		l := utfc_ptr2len(transmute(cstring)(p))
		if l > 1 {
			msg_outtrans_len_r(transmute(cstring)(p), l, 0, false)
			p = (^u8)(uintptr(p) + uintptr(l))
		} else {
			msg_outtrans_len_r(transmute(cstring)(p), 1, 0, false)
			p = (^u8)(uintptr(p) + 1)
		}
	}
	os_breakcheck()
}

foreign _ {
	@(link_name = "msg_outtrans_len")
	msg_outtrans_len_r :: proc "c" (msgstr: cstring, len: C.int, hl_id: C.int, hist: bool) ---
	@(link_name = "msg_puts_hl")
	msg_puts_hl_r :: proc "c" (s: cstring, hl_id: C.int, hist: bool) ---
	@(link_name = "get_last_insert")
	get_last_insert_r :: proc "c" () -> Str16 ---
	@(link_name = "mb_tolower")
	mb_tolower_r :: proc "c" (c: C.int) -> C.int ---
}

/// ":dis" and ":registers": Display the contents of the yank registers.
@(export)
ex_display :: proc "c" (eap: rawptr) {
	arg := (^rawptr)(uintptr(eap) + EA_ARG)^
	name: C.int

	if arg != nil && (^u8)(arg)^ == 0 {
		arg = nil
	}
	hl_id: C.int = HLF_8

	msg_ext_set_kind(cstring("list_cmd"))
	msg_ext_skip_flush = true
	// Highlight title
	msg_puts_title(_t(cstring("\nType Name Content")))
	i: C.int = -1
	for i < NUM_REGISTERS && !got_int {
		name = get_register_name(i)
		if arg != nil && _vim_strchr(transmute(cstring)((^u8)(arg)), name) == nil {
			i += 1
			continue // did not ask for this register
		}

		switch get_reg_type(name, nil) {
		case kMTLineWise:
			type_ch := 'l'
			_ = type_ch
		}
		// compute type via small helper below
		tc := reg_type_char(get_reg_type(name, nil))

		yb: ^Yankreg_T
		if i == -1 {
			if y_previous != nil {
				yb = y_previous
			} else {
				yb = &y_regs[0]
			}
		} else {
			yb = &y_regs[i]
		}

		get_clipboard(name, &yb, true)

		if name == mb_tolower_r(redir_reg) ||
			(redir_reg == '"' && yb == y_previous) {
			i += 1
			continue // don't list register being written to
		}

		if yb.y_array != nil {
			do_show := false

			for j: C.size_t = 0; !do_show && j < yb.y_size; j += 1 {
				do_show = !message_filtered(transmute(cstring)(yb.y_array[j].data))
			}

			if do_show || yb.y_size == 0 {
				msg_putchar('\n')
				msg_puts(cstring("  "))
				msg_putchar(C.int(tc))
				msg_puts(cstring("  "))
				msg_putchar('"')
				msg_putchar(name)
				msg_puts(cstring("   "))

				n := Columns - 11
				for j: C.size_t = 0; j < yb.y_size && n > 1; j += 1 {
					if j > 0 {
						msg_puts_hl_r(cstring("^J"), hl_id, false)
						n -= 2
					}
					p := yb.y_array[j].data
					for p^ != 0 {
						cl := ptr2cells(transmute(cstring)(p))
						if n-cl < 0 {
							break
						}
						n -= cl
						clen := C.int(utfc_ptr2len(transmute(cstring)(p)))
						msg_outtrans_len_r(transmute(cstring)(p), clen, 0, false)
						p = (^u8)(uintptr(p) + uintptr(clen - 1))
						p = (^u8)(uintptr(p) + 1)
					}
				}
				if n > 1 && yb.y_type == kMTLineWise {
					msg_puts_hl_r(cstring("^J"), hl_id, false)
				}
			}
			os_breakcheck()
		}
		i += 1
	}

	// display last inserted text
	insert := get_last_insert_r()
	if insert.data != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '.') != nil) &&
		!got_int &&
		!message_filtered(transmute(cstring)(insert.data)) {
		msg_puts(cstring("\n  c  \".   "))
		dis_msg(insert.data, true)
	}

	// display last command line
	if last_cmdline != nil && (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), ':') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(last_cmdline)) {
		msg_puts(cstring("\n  c  \":   "))
		dis_msg(last_cmdline, false)
	}

	// display current file name
	fname := (^u8)(buf_read_ptr(curbuf, B_FNAME))
	if fname != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '%') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(fname)) {
		msg_puts(cstring("\n  c  \"%   "))
		dis_msg(fname, false)
	}

	// display alternate file name
	if (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '#') != nil) && !got_int {
		aname: ^u8
		dummy: C.int

		if buflist_name_nr_r(0, &aname, &dummy) != FAIL_R && !message_filtered(transmute(cstring)(aname)) {
			msg_puts(cstring("\n  c  \"#   "))
			dis_msg(aname, false)
		}
	}

	// display last search pattern
	if last_search_pat() != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '/') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(last_search_pat())) {
		msg_puts(cstring("\n  c  \"/   "))
		dis_msg(last_search_pat(), false)
	}

	// display last used expression
	if expr_line != nil && (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '=') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(expr_line)) {
		msg_puts(cstring("\n  c  \"=   "))
		dis_msg(expr_line, false)
	}
	msg_ext_skip_flush = false
}

@(private="file")
reg_type_char :: proc "c"(mt: C.int) -> u8 {
	switch mt {
	case kMTLineWise:
		return 'l'
	case kMTCharWise:
		return 'c'
	case:
		return 'b'
	}
}

/// Used for getregtype(): register type or kMTUnknown for error.
@(export)
get_reg_type :: proc "c" (regname: C.int, reg_width: ^C.int) -> C.int {
	switch regname {
	case '%', '#', '=', ':', '/', '.', Ctrl_F, Ctrl_P, Ctrl_W, Ctrl_A, '_':
		return kMTCharWise
	}

	if regname != 0 && !valid_yank_reg(regname, false) {
		return kMTUnknown
	}

	reg := get_yank_register(regname, YREG_PASTE)

	if reg.y_array != nil {
		if reg_width != nil && reg.y_type == kMTBlockWise {
			reg_width^ = reg.y_width
		}
		return reg.y_type
	}
	return kMTUnknown
}

/// When flags has kGRegList return a list with text s; otherwise just s.
@(private="file")
get_reg_wrap_one_line :: proc "c"(s: ^u8, flags: C.int) -> rawptr {
	if (flags & kGRegList) == 0 {
		return s
	}
	list := tv_list_alloc(1)
	tv_list_append_allocated_string_r(list, s)
	return list
}

/// Gets the contents of a register (for @r expressions and getreg()).
@(export)
get_reg_contents :: proc "c" (regname_arg: C.int, flags: C.int) -> rawptr {
	regname := regname_arg
	// Don't allow using an expression register inside an expression.
	if regname == '=' {
		if (flags & kGRegNoExpr) != 0 {
			return nil
		}
		if (flags & kGRegExprSrc) != 0 {
			return get_reg_wrap_one_line(get_expr_line_src(), flags)
		}
		return get_reg_wrap_one_line(get_expr_line(), flags)
	}

	if regname == '@' { // "@@" used for unnamed register
		regname = '"'
	}

	// check for valid regname
	if regname != 0 && !valid_yank_reg(regname, false) {
		return nil
	}

	retval: ^u8
	allocated: bool
	if get_spec_reg(regname, &retval, &allocated, false) {
		if retval == nil {
			return nil
		}
		if allocated {
			return get_reg_wrap_one_line(retval, flags)
		}
		return get_reg_wrap_one_line(xstrdup(retval), flags)
	}

	reg := get_yank_register(regname, YREG_PUT)
	if reg.y_array == nil {
		return nil
	}

	if (flags & kGRegList) != 0 {
		list := tv_list_alloc(C.ssize_t(reg.y_size))
		for i: C.size_t = 0; i < reg.y_size; i += 1 {
			tv_list_append_string(list, reg.y_array[i].data, C.ssize_t(reg.y_array[i].size))
		}

		return list
	}

	// Compute length of resulting string.
	length: C.size_t = 0
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		length += reg.y_array[i].size
		// newline between lines and after last if linewise
		if reg.y_type == kMTLineWise || i < reg.y_size - 1 {
			length += 1
		}
	}

	retval = (^u8)(xmalloc(length + 1))

	// Copy the lines of the yank register into the string.
	length = 0
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		libc.memcpy((^u8)(uintptr(retval) + uintptr(length)), reg.y_array[i].data, reg.y_array[i].size + 1)
		length += reg.y_array[i].size

		if reg.y_type == kMTLineWise || i < reg.y_size - 1 {
			(^u8)(uintptr(retval) + uintptr(length))^ = '\n'
			length += 1
		}
	}
	(^u8)(uintptr(retval) + uintptr(length))^ = 0

	return retval
}

@(private="file")
init_write_reg :: proc "c"(name: C.int, old_y_previous: ^^Yankreg_T, must_append: bool) -> ^Yankreg_T {
	if !valid_yank_reg(name, true) { // check for valid reg name
		emsg_invreg_r(name)
		return nil
	}

	// Don't want to change the current (unnamed) register.
	old_y_previous^ = y_previous

	reg := get_yank_register(name, YREG_YANK)
	if !is_append_register(name) && !must_append {
		free_register(reg)
	}
	return reg
}

/// str_to_reg — put a string into a register.
@(private="file")
str_to_reg :: proc "c"(y_ptr: ^Yankreg_T, yank_type_arg: C.int, str: rawptr, len: C.size_t,
	blocklen: C.int, str_list: bool) {
	yank_type := yank_type_arg
	if y_ptr.y_array == nil { // NULL means empty register
		y_ptr.y_size = 0
	}

	if yank_type == kMTUnknown {
		cs: ^u8
		if str_list {
			cs = nil
			yank_type = kMTLineWise
		} else {
			cs = (^u8)(str)
			yank_type = (len > 0 && ((^u8)(uintptr(cs) + uintptr(len) - 1)^ == '\n' || (^u8)(uintptr(cs) + uintptr(len) - 1)^ == '\r')) ? kMTLineWise : kMTCharWise
		}
	}

	newlines: C.size_t = 0
	extraline := false // extra line at the end
	append := false    // append to last line in register

	// Count the number of lines within the string
	if str_list {
		for cargv_at(transmute(^rawptr)(str), newlines) != nil {
			newlines += 1
		}
	} else {
		cs := (^u8)(str)
		newlines = C.size_t(_memcnt(str, C.int('\n'), len))
		if yank_type == kMTCharWise || len == 0 || (^u8)(uintptr(cs) + uintptr(len) - 1)^ != '\n' {
			extraline = true
			newlines += 1 // extra newline at the end
		}
		if y_ptr.y_size > 0 && y_ptr.y_type == kMTCharWise {
			append = true
			newlines -= 1 // uncount newline when appending first line
		}
	}

	// Without any lines make the register empty.
	if y_ptr.y_size + newlines == 0 {
		xfree_clear_reg(transmute(^rawptr)(&y_ptr.y_array))
		return
	}

	// Grow the register array to hold pointers to the new lines.
	pp := transmute([^]Str16)(xrealloc(y_ptr.y_array, (y_ptr.y_size + newlines) * size_of(Str16)))
	y_ptr.y_array = pp

	lnum := y_ptr.y_size // The current line number.

	maxlen: C.size_t = 0

	// Find the end of each line and save it into the array.
	if str_list {
		k: C.size_t = 0
		for cargv_at(transmute(^rawptr)(str), k) != nil {
			sk := cargv_at(transmute(^rawptr)(str), k)
			pp[lnum] = cstr_to_string_r(transmute(cstring)(sk))
			if yank_type == kMTBlockWise {
				charlen := mb_string2cells_s(transmute(cstring)(sk))
				maxlen = max(maxlen, charlen)
			}
			k += 1
			lnum += 1
		}
	} else {
		cs := (^u8)(str)
		start := cs
		end := (^u8)(uintptr(cs) + uintptr(len))
		for uintptr(start) < uintptr(end) + (extraline ? 1 : 0) {
			charlen: C.int = 0

			line_end := start
			for uintptr(line_end) < uintptr(end) { // find end of line
				if line_end^ == '\n' {
					break
				}
				if yank_type == kMTBlockWise {
					charlen += utf_ptr2cells_len_r(transmute(cstring)(line_end), C.int(uintptr(end) - uintptr(line_end)))
				}

				if line_end^ == 0 {
					line_end = (^u8)(uintptr(line_end) + 1) // registers can have NUL chars
				} else {
					line_end = (^u8)(uintptr(line_end) + uintptr(utf_ptr2len_len_r(transmute(cstring)(line_end), C.int(uintptr(end) - uintptr(line_end)))))
				}
			}
			line_len := uintptr(line_end) - uintptr(start)
			maxlen = max(maxlen, C.size_t(charlen))

			// When appending, copy previous line and free it after.
			extra: C.size_t = 0
			if append {
				lnum -= 1
				extra = pp[lnum].size
			}
			s := xmallocz_r(C.size_t(line_len) + extra)
			if extra > 0 {
				libc.memcpy(s, pp[lnum].data, extra)
			}
			if line_len > 0 {
				libc.memcpy((^u8)(uintptr(s) + uintptr(extra)), start, C.size_t(line_len))
			}
			s_len := extra + C.size_t(line_len)

			if append {
				xfree(pp[lnum].data)
				append = false // only first line is appended
			}
			pp[lnum] = Str16{data = s, size = s_len}

			// Convert NULs to '\n' to prevent truncation.
			_memchrsub(pp[lnum].data, 0, '\n', s_len)

			start = (^u8)(uintptr(start) + line_len + 1)
			lnum += 1
		}
	}
	y_ptr.y_type = yank_type
	y_ptr.y_size = lnum
	xfree_clear_reg(&y_ptr.additional_data)
	y_ptr.timestamp = os_time()
	if yank_type == kMTBlockWise {
		y_ptr.y_width = blocklen == -1 ? C.int(maxlen) - 1 : blocklen
	} else {
		y_ptr.y_width = 0
	}
}

@(private="file")
finish_write_reg :: proc "c"(name: C.int, reg: ^Yankreg_T, old_y_previous: ^Yankreg_T) {
	// Send text of clipboard register to the clipboard.
	set_clipboard(name, reg)

	// ':let @" = "val"' should change the meaning of the "" register
	if name != '"' {
		y_previous = old_y_previous
	}
}

/// store str in register name
@(export)
write_reg_contents :: proc "c" (name: C.int, str: cstring, len: i64, must_append: C.int) {
	write_reg_contents_ex(name, str, len, must_append != 0, kMTUnknown, 0)
}

@(export)
write_reg_contents_lst :: proc "c" (name: C.int, strings: ^rawptr, must_append: bool, yank_type: C.int, block_len: C.int) {
	if name == '/' || name == '=' || name == '#' {
		s0 := cargv_at(strings, 0)
		s1 := cargv_at(strings, 1)
		s := s0
		if s0 == nil {
			s = transmute(^u8)(cstring(""))
		} else if s1 != nil {
			buf: [1025]u8
			n := libc.snprintf(&buf[0], size_of(buf), cstring("E883: Register '%c' cannot contain multiple lines"), name)
			buf[n if n >= 0 && n < 1024 else 1024] = 0
			emsg(transmute(cstring)(&buf[0]))
			return
		}
		write_reg_contents_ex(name, transmute(cstring)(s), -1, must_append, yank_type, block_len)
		return
	}

	// black hole: nothing to do
	if name == '_' {
		return
	}

	old_y_previous: ^Yankreg_T
	reg := init_write_reg(name, &old_y_previous, must_append)
	if reg == nil {
		return
	}

	str_to_reg(reg, yank_type, strings, libc.strlen(transmute(cstring)(strings)),
		block_len, true)
	finish_write_reg(name, reg, old_y_previous)
}

/// write_reg_contents_ex — store str in register name.
@(export)
write_reg_contents_ex :: proc "c" (name: C.int, str: cstring, len_arg: i64, must_append: bool,
	yank_type: C.int, block_len: C.int) {
	len := len_arg
	if len < 0 {
		len = i64(libc.strlen(str))
	}

	// Special case: '/' search pattern
	if name == '/' {
		set_last_search_pat(str, RE_SEARCH, 1, true)
		return
	}

	if name == '#' {
		if len == 0 {
			set_i32_off(curwin, W_ALT_FNUM, 0) // clear altfile
			return
		}

		buf: rawptr

		if ascii_isdigit_r(C.int((^u8)(uintptr(transmute(rawptr)(str)))^)) {
			num := libc.atoi(str)

			buf = buflist_findnr(num)
			if buf == nil {
				nbuf: [64]u8
				n := libc.snprintf(&nbuf[0], size_of(nbuf), _t(cstring("E86: Buffer %ld does not exist")), C.long(num))
				nbuf[n if n >= 0 && n < 63 else 63] = 0
				emsg(transmute(cstring)(&nbuf[0]))
			}
		} else {
			buf = buflist_findnr(buflist_findpat_r(str, transmute(cstring)((^u8)(uintptr(transmute(rawptr)(str)) + uintptr(len))), true, false, false))
		}
		if buf == nil {
			return
		}
		set_i32_off(curwin, W_ALT_FNUM, get_i32_off(buf, B_HANDLE))
		return
	}

	if name == '=' {
		offset: C.size_t = 0
		totlen := C.size_t(len)

		if must_append && expr_line != nil {
			// append to existing expr_line
			exprlen := libc.strlen(transmute(cstring)(expr_line))

			totlen += exprlen
			offset = exprlen
		}

		expr_line = (^u8)(xrealloc(expr_line, totlen + 1))
		libc.memcpy((^u8)(uintptr(expr_line) + uintptr(offset)), transmute(rawptr)(str), C.size_t(len))
		(^u8)(uintptr(expr_line) + uintptr(totlen))^ = 0

		return
	}

	if name == '_' { // black hole: nothing to do
		return
	}

	old_y_previous: ^Yankreg_T
	reg := init_write_reg(name, &old_y_previous, must_append)
	if reg == nil {
		return
	}
	str_to_reg(reg, yank_type, transmute(rawptr)(str), C.size_t(len), block_len, false)
	finish_write_reg(name, reg, old_y_previous)
}

/// @param[out] reg Expected to be empty
@(export)
prepare_yankreg_from_object :: proc "c" (reg: ^Yankreg_T, regtype: Str16, lines: C.size_t) -> bool {
	_ = lines
	type_ch := regtype.data != nil ? regtype.data^ : 0

	switch type_ch {
	case 0:
		reg.y_type = kMTUnknown
	case 'v', 'c':
		reg.y_type = kMTCharWise
	case 'V', 'l':
		reg.y_type = kMTLineWise
	case 'b':
		reg.y_type = kMTBlockWise
	case 22: // Ctrl_V
		reg.y_type = kMTBlockWise
	case:
		return false
	}

	reg.y_width = 0
	if regtype.size > 1 {
		if reg.y_type != kMTBlockWise {
			return false
		}

		// allow "b7" for a block at least 7 spaces wide
		if !ascii_isdigit_r(C.int((^u8)(uintptr(regtype.data) + 1)^)) {
			return false
		}
		p := (^u8)(uintptr(regtype.data) + 1)
		p_ptr := &p
		reg.y_width = getdigits_int_r(p_ptr, false, 1) - 1
		if regtype.size > C.size_t(uintptr(p) - uintptr(regtype.data)) {
			return false
		}
	}

	reg.additional_data = nil
	reg.timestamp = 0
	return true
}

@(export)
finish_yankreg_from_object :: proc "c" (reg: ^Yankreg_T, clipboard_adjust: bool) {
	if reg.y_size > 0 && reg.y_array[reg.y_size - 1].size == 0 {
		// a known-to-be charwise yank might have a final linebreak
		if reg.y_type != kMTCharWise {
			if reg.y_type == kMTUnknown || clipboard_adjust {
				reg.y_size -= 1
			}
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
}
