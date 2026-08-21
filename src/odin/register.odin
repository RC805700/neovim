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
	decl_pos :: proc "c" (p: ^Pos_T) ---

	@(link_name = "u_save")
	u_save_r :: proc "c" (top: C.int, bot: C.int) -> C.int ---
	@(link_name = "u_save_cursor")
	u_save_cursor_r :: proc "c" () -> C.int ---
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
	@(link_name = "last_search_pat")
	last_search_pat_r :: proc "c" () -> ^u8 ---
	@(link_name = "set_last_search_pat")
	set_last_search_pat_r :: proc "c" (s: cstring, idx: C.int, magic: C.int, setlast: bool) ---
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
						if u_save_cursor_r() == FAIL_R {
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
		if last_search_pat_r() == nil && errmsg {
			emsg(_t(e_noprevre))
		}
		argp^ = last_search_pat_r()
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
			decl_pos(get_pos_r2(curbuf, B_OP_END))
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
