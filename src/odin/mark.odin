// mark.odin — port of src/nvim/mark.c (marks, jumplist, changelist, tagstack adjust)
//
// Struct offsets verified against system headers via offsetof probe (2026-07):
//   pos_T=12 {lnum@0,col@4,coladd@8}  fmarkv_T=8  fmark_T=40  xfmark_T=48
//   visualinfo_T=32 {vi_start@0,vi_end@12,vi_mode@24}  taggy_T=64 {tagname@0,fmark@8,cur_match@48,cur_fnum@52}
//   WinInfo.wi_mark@8  tabpage_T{tp_next@8,tp_firstwin@40}  exarg_T{arg@0,forceit@76}

package main

import C "core:c"
import "core:c/libc"

// ── Constants ────────────────────────────────────────────────────────────────

NMARKS :: 26
EXTRA_MARKS :: 10
NGLOBALMARKS :: NMARKS + EXTRA_MARKS // 36
JUMPLISTSIZE :: 100
TAGSTACKSIZE :: 20
MAXLNUM :: 0x7fffffff
MAXCOL :: 0x7fffffff
NMARK_LOCAL_MAX :: 126

// MarkMoveRes
kMarkMoveSuccess :: 1
kMarkMoveFailed :: 2
kMarkSwitchedBuf :: 4
kMarkChangedCol :: 8
kMarkChangedLine :: 16
kMarkChangedCursor :: 32
kMarkChangedView :: 64

// MarkMove
kMarkBeginLine :: 1
kMarkContext :: 2
KMarkNoContext :: 4
kMarkSetView :: 8
kMarkJumpList :: 16

// MarkGet
kMarkBufLocal :: 0
kMarkAll :: 1
kMarkAllNoResolve :: 2

// MarkAdjustMode
kMarkAdjustNormal :: 0
kMarkAdjustApi :: 1
kMarkAdjustTerm :: 2

CMOD_KEEPJUMPS :: 0x0400
CMOD_LOCKMARKS :: 0x0800
kOptJopFlagStack :: 0x01

EVENT_MARKSET :: 82
AUGROUP_ALL :: -3

FORWARD_DIR :: 1
BACKWARD_DIR :: -1

GETF_SETMARK :: 0x01
BL_WHITE :: 1
BL_FIX :: 4
HLF_D :: 5

BUF_HAS_QF_ENTRY :: 1
BUF_HAS_LL_ENTRY :: 2

kObjectTypeInteger_API :: 2
kObjectTypeString_API :: 4
kObjectTypeDict_API :: 6

// ── Types ────────────────────────────────────────────────────────────────────

Pos_T :: struct {
	lnum:   C.int,
	col:    C.int,
	coladd: C.int,
}

Fmarkv_T :: struct {
	topline_offset: C.int,
	skipcol:        C.int,
}

INIT_FMARKV :: Fmarkv_T{MAXLNUM, 0}

Fmark_T :: struct {
	mark:            Pos_T,
	fnum:            C.int,
	timestamp:       Timestamp,
	view:            Fmarkv_T,
	additional_data: rawptr,
}

#assert(size_of(Fmark_T) == 40)

Xfmark_T :: struct {
	fmark: Fmark_T,
	fname: ^u8,
}

#assert(size_of(Xfmark_T) == 48)

Visualinfo_T :: struct {
	vi_start:    Pos_T,
	vi_end:      Pos_T,
	vi_mode:     C.int,
	vi_curswant: C.int,
}

#assert(size_of(Visualinfo_T) == 32)

Taggy_T :: struct {
	tagname:   ^u8,
	fmark:     Fmark_T,
	cur_match: C.int,
	cur_fnum:  C.int,
	user_data: ^u8,
}

#assert(size_of(Taggy_T) == 64)

// api/private Object mirror (no unions in Odin): type@0, data@8 (24-byte union)
Api_String :: struct {
	data: ^u8,
	size:     C.size_t,
}
Api_Object :: struct {
	t:    C.int,
	_pad: [4]u8,
	data: [24]u8,
}
#assert(size_of(Api_Object) == 32)
Key_Value_Pair :: struct {
	key:   Api_String,
	value: Api_Object,
}
#assert(size_of(Key_Value_Pair) == 48)
Api_Dict :: struct {
	size:     C.size_t,
	capacity: C.size_t,
	items:    ^Key_Value_Pair,
}
#assert(size_of(Api_Dict) == 24)

// ── win_T / buf_T / tabpage_T offsets ────────────────────────────────────────

W_BUFFER :: 8
W_NEXT :: 112
W_CURSOR :: 136
W_OLD_CURSOR_LNUM :: 168
W_OLD_VISUAL_LNUM :: 180
W_TOPLINE :: 364
W_TOPFILL :: 372
W_SKIPCOL :: 388
W_PCMARK :: 4296
W_PREV_PCMARK :: 4308
W_JUMPLIST :: 4320
W_JUMPLISTLEN :: 9120
W_JUMPLISTIDX :: 9124
W_CHANGELISTIDX :: 9128
W_TAGSTACK :: 9152
W_TAGSTACKLEN :: 10436
W_TAGSTACKIDX :: 10432

B_HANDLE :: 0
B_ML_LINE_COUNT :: 8 // buf_T.b_ml.ml_line_count (memline_T.ml_line_count@0)
B_FFNAME :: 160
B_WININFO :: 288 // kvec_t(WinInfo*): n@0,a@8,items@16
B_NAMEDM :: 384
B_VISUAL :: 1424
B_LAST_CURSOR :: 1464
B_LAST_INSERT :: 1504
B_LAST_CHANGE :: 1544
B_CHANGELIST :: 1584
B_CHANGELISTLEN :: 5584
B_OP_START :: 7704
B_OP_END :: 7728
B_HAS_QF_ENTRY :: 10168
B_PROMPT_START :: 11224

TP_NEXT :: 8
TP_FIRSTWIN :: 40
WI_MARK :: 8

EA_ARG :: 0
EA_FORCEIT :: 76

// ── Field accessors ──────────────────────────────────────────────────────────

@(private="file")
get_i32 :: #force_inline proc "c"(base: rawptr, off: uintptr) -> C.int {
	return (^C.int)(uintptr(base) + off)^
}

@(private="file")
set_i32 :: #force_inline proc "c"(base: rawptr, off: uintptr, v: C.int) {
	(^C.int)(uintptr(base) + off)^ = v
}

@(private="file")
get_pos :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(base) + off)
}

@(private="file")
get_fmark :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Fmark_T {
	return (^Fmark_T)(uintptr(base) + off)
}

@(private="file")
get_xfmark :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Xfmark_T {
	return (^Xfmark_T)(uintptr(base) + off)
}

@(private="file")
win_cursor :: #force_inline proc "c"(w: rawptr) -> ^Pos_T {
	return get_pos(w, W_CURSOR)
}

@(private="file")
buf_line_count :: #force_inline proc "c"(b: rawptr) -> C.int {
	return get_i32(b, B_ML_LINE_COUNT)
}

@(private="file")
xfmark_at :: #force_inline proc "c"(wp: rawptr, i: C.int) -> ^Xfmark_T {
	return (^Xfmark_T)(uintptr(wp) + W_JUMPLIST + uintptr(i) * size_of(Xfmark_T))
}

@(private="file")
fmark_at :: #force_inline proc "c"(base: rawptr, off: uintptr, i: C.int) -> ^Fmark_T {
	return (^Fmark_T)(uintptr(base) + off + uintptr(i) * size_of(Fmark_T))
}

// ── Globals ──────────────────────────────────────────────────────────────────

// Global marks A-Z, 0-9 (referenced by shada.c)
@(export)
namedfm: [NGLOBALMARKS]Xfmark_T

@(private="file")
fms_static: Fmark_T // pos_to_mark static

@(private="file")
fm_copy_static: Fmark_T // mark_move_to static

@(private="file")
did_title: bool // show_one_mark static

// ── Foreign: globals ─────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "first_tabpage")
	first_tabpage: rawptr

	@(link_name = "global_busy")
	global_busy: C.int

	@(link_name = "listcmd_busy")
	listcmd_busy: bool

	@(link_name = "cmdmod")
	cmdmod_cmod_flags: C.int // cmdmod_T.cmod_flags @0

	@(link_name = "jop_flags")
	jop_flags: u32

	@(link_name = "saved_cursor")
	saved_cursor: Pos_T

	@(link_name = "utfc_ptr2len")
	utfc_ptr2len :: proc "c" (p: cstring) -> C.int ---
	@(link_name = "utf_head_off")
	utf_head_off :: proc "c" (base_in: cstring, p_in: cstring) -> C.int ---
	// NOTE: e_* error strings are defined below as Odin literals (C's are
	// `const char[]` arrays — linking them as cstring globals would load array
	// CONTENT as a pointer).
}

// ── Foreign: C-only helpers ──────────────────────────────────────────────────

foreign _ {
	path_shorten_fname :: proc "c" (full_path: ^u8, dir_name: ^u8) -> ^u8 ---
	vim_ispathsep_nocolon :: proc "c" (c: C.int) -> bool ---

	qf_mark_adjust :: proc "c" (buf, wp: rawptr, line1, line2, amount, amount_after: C.int) -> bool ---
	extmark_adjust :: proc "c" (buf: rawptr, line1, line2, amount, amount_after, op: C.int) ---
	// foldMarkAdjust now defined in fold.odin — reuse directly.
	diff_mark_adjust :: proc "c" (buf: rawptr, line1, line2, amount, amount_after: C.int) ---

	ml_get :: proc "c" (lnum: C.int) -> ^u8 ---
	ml_get_buf :: proc "c" (buf: rawptr, lnum: C.int) -> ^u8 ---
	ml_get_buf_len :: proc "c" (buf: rawptr, lnum: C.int) -> C.int ---

	utf_ptr2char :: proc "c" (p_in: cstring) -> C.int ---
	ptr2cells :: proc "c" (p_in: cstring) -> C.int ---
	vim_isprintc :: proc "c" (c: C.int) -> bool ---

	message_filtered :: proc "c" (msg: cstring) -> bool ---
	msg_puts_title :: proc "c" (s: cstring) ---
	@(link_name = "msg")
	msg_msg :: proc "c" (s: cstring, hl_id: C.int) -> bool ---
	check_cursor :: proc "c" (wp: rawptr) ---
	beginline :: proc "c" (flags: C.int) ---
	set_topline :: proc "c" (wp: rawptr, lnum: C.int) ---
	// hasFolding now defined in fold.odin — reuse directly.
	linetabsize_eol :: proc "c" (wp: rawptr, lnum: C.int) -> C.int ---

	findpar :: proc "c" (pincl: ^bool, dir, count, what: C.int, both: bool) -> bool ---
	findsent :: proc "c" (dir: C.int, count: C.int) -> C.int ---

	has_event :: proc "c" (event: C.int) -> bool ---
	aucmd_defer :: proc "c" (event: C.int, fname, fname_io: ^u8, group: C.int, buf, eap: rawptr, data: ^Api_Object) ---

	@(link_name = "tv_dict_alloc")
	tv_dict_alloc_m :: proc "c" () -> rawptr ---
	@(link_name = "tv_dict_free")
	tv_dict_free_m :: proc "c" (d: rawptr) ---
	@(link_name = "tv_list_append_dict")
	tv_list_append_dict_m :: proc "c" (l, dict: rawptr) ---
	@(link_name = "tv_list_append_number")
	tv_list_append_number_m :: proc "c" (l: rawptr, n: i64) ---
	@(link_name = "tv_dict_add_nr")
	tv_dict_add_nr_m :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, nr: i64) -> C.int ---
	@(link_name = "tv_dict_add_str_len")
	tv_dict_add_str_len_m :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: cstring, len: C.int) -> C.int ---
	@(link_name = "tv_dict_add_str")
	tv_dict_add_str_m :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, val: cstring) -> C.int ---
	@(link_name = "tv_dict_add_list")
	tv_dict_add_list_m :: proc "c" (d: rawptr, key: cstring, key_len: C.size_t, list: rawptr) -> C.int ---
}

// ── Small helpers ────────────────────────────────────────────────────────────

// Error strings (mirror errors.h; Odin literals — see note above).
e_umark:      cstring = "E78: Unknown mark"
e_marknotset: cstring = "E20: Mark not set"
e_markinval:  cstring = "E19: Mark has invalid line number"
e_invarg:     cstring = "E474: Invalid argument"
e_argreq:     cstring = "E471: Argument required"
e_invarg2:    cstring = "E475: Invalid argument: %s"

@(private="file")
mb_adv :: #force_inline proc "c"(p: ^u8) -> ^u8 {
	return (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
}

@(private="file")
lt_pos :: #force_inline proc "c"(a, b: Pos_T) -> bool {
	if a.lnum != b.lnum {
		return a.lnum < b.lnum
	} else if a.col != b.col {
		return a.col < b.col
	}
	return a.coladd < b.coladd
}

@(private="file")
equalpos :: #force_inline proc "c"(a, b: Pos_T) -> bool {
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

@(private="file")
ascii_islower_c :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= 'a' && c <= 'z'
}

@(private="file")
ascii_isupper_c :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= 'A' && c <= 'Z'
}

@(private="file")
ascii_isdigit_c :: #force_inline proc "c"(c: C.int) -> bool {
	return c >= '0' && c <= '9'
}

@(private="file")
xstrdup_b :: proc "c"(s: cstring) -> ^u8 {
	return transmute(^u8)(_xstrdup(s))
}

@(private="file")
semsg_invarg2 :: proc "c"(p: ^u8) {
	buf: [1025]u8
	n := libc.snprintf(&buf[0], size_of(buf), cstring("E475: Invalid argument: %s"), transmute(cstring)(p))
	buf[n if n >= 0 && n < 1024 else 1024] = 0
	emsg(transmute(cstring)(&buf[0]))
}

// ONE_ADJUST macro
@(private="file")
one_adjust :: #force_inline proc "c"(lp: ^C.int, line1, line2, amount, amount_after: C.int) {
	if lp^ >= line1 && lp^ <= line2 {
		if amount == MAXLNUM {
			lp^ = 0
		} else {
			lp^ += amount
		}
	} else if amount_after != 0 && lp^ > line2 {
		lp^ += amount_after
	}
}

// ONE_ADJUST_NODEL macro
@(private="file")
one_adjust_nodel :: #force_inline proc "c"(lp: ^C.int, line1, line2, amount, amount_after: C.int) {
	if lp^ >= line1 && lp^ <= line2 {
		if amount == MAXLNUM {
			lp^ = line1
		} else {
			lp^ += amount
		}
	} else if amount_after != 0 && lp^ > line2 {
		lp^ += amount_after
	}
}

// ONE_ADJUST_CURSOR macro
@(private="file")
one_adjust_cursor :: #force_inline proc "c"(posp: ^Pos_T, line1, line2, amount, amount_after: C.int) {
	if posp.lnum >= line1 && posp.lnum <= line2 {
		if amount == MAXLNUM {
			posp.lnum = max(line1 - 1, 1)
			posp.col = 0
		} else {
			posp.lnum += amount
		}
	} else if amount_after != 0 && posp.lnum > line2 {
		posp.lnum += amount_after
	}
}

// COL_ADJUST macro
@(private="file")
col_adjust_one :: #force_inline proc "c"(posp: ^Pos_T, lnum, mincol, lnum_amount, col_amount, spaces_removed: C.int) {
	if posp.lnum == lnum && posp.col >= mincol {
		posp.lnum += lnum_amount
		if col_amount < 0 && posp.col <= -col_amount {
			posp.col = 0
		} else if posp.col < spaces_removed {
			posp.col = col_amount + spaces_removed
		} else {
			posp.col += col_amount
		}
	}
}

// SET_FMARK macro (timestamp = os_time())
@(private="file")
set_fmark :: #force_inline proc "c"(fp: ^Fmark_T, mark_: Pos_T, fnum_: C.int, view_: Fmarkv_T) {
	fp.mark = mark_
	fp.fnum = fnum_
	fp.timestamp = os_time()
	fp.view = view_
	fp.additional_data = nil
}

// RESET_FMARK macro
@(private="file")
reset_fmark :: #force_inline proc "c"(fp: ^Fmark_T, mark_: Pos_T, fnum_: C.int, view_: Fmarkv_T) {
	free_fmark(fp^)
	set_fmark(fp, mark_, fnum_, view_)
}

// XFREE_CLEAR
@(private="file")
xfree_clear :: #force_inline proc "c"(p: ^rawptr) {
	xfree(p^)
	p^ = nil
}

// FOR_ALL_TAB_WINDOWS iteration start: returns first window of tab page
@(private="file")
tab_first_win :: #force_inline proc "c"(tp: rawptr) -> rawptr {
	if tp == curtab {
		return firstwin
	}
	return (^rawptr)(uintptr(tp) + TP_FIRSTWIN)^
}

// ── Exported functions ───────────────────────────────────────────────────────

// Set named mark "c" at current cursor position.
@(export)
setmark :: proc "c" (c: C.int) -> C.int {
	view := mark_view_make(curwin, win_cursor(curwin)^)
	return setmark_pos(c, win_cursor(curwin), get_i32(curbuf, B_HANDLE), &view)
}

/// Free fmark_T item
@(export)
free_fmark :: proc "c" (fm: Fmark_T) {
	xfree(fm.additional_data)
}

/// Free xfmark_T item
@(export)
free_xfmark :: proc "c" (fm: Xfmark_T) {
	xfree(fm.fname)
	free_fmark(fm.fmark)
}

/// Free and clear fmark_T item. Does not trigger "MarkSet" event.
@(export)
clear_fmark :: proc "c" (fm: ^Fmark_T, timestamp: Timestamp) {
	free_fmark(fm^)
	fm^ = Fmark_T{}
	fm.timestamp = timestamp
}

// Schedules "MarkSet" event.
@(private="file")
do_markset_autocmd :: proc "c"(c: u8, pos: ^Pos_T, buf: rawptr) {
	if !has_event(EVENT_MARKSET) {
		return
	}
	mark_str: [2]u8 = {c, 0}
	items: [3]Key_Value_Pair
	d := Api_Dict{0, 3, &items[0]}
	// PUT_C(data, "name", STRING_OBJ({mark_str, 1}))
	items[d.size] = Key_Value_Pair{
		key = Api_String{data = transmute(^u8)(cstring("name")), size = 4},
		value = Api_Object{t = kObjectTypeString_API},
	}
	(^Api_String)(uintptr(&items[d.size]) + 8)^ = Api_String{data = &mark_str[0], size = 1}
	d.size += 1
	// PUT_C(data, "line", INTEGER_OBJ(pos->lnum))
	items[d.size] = Key_Value_Pair{
		key = Api_String{data = transmute(^u8)(cstring("line")), size = 4},
		value = Api_Object{t = kObjectTypeInteger_API},
	}
	(^i64)(uintptr(&items[d.size]) + 8)^ = i64(pos.lnum)
	d.size += 1
	// PUT_C(data, "col", INTEGER_OBJ(pos->col))
	items[d.size] = Key_Value_Pair{
		key = Api_String{data = transmute(^u8)(cstring("col")), size = 3},
		value = Api_Object{t = kObjectTypeInteger_API},
	}
	(^i64)(uintptr(&items[d.size]) + 8)^ = i64(pos.col)
	d.size += 1

	obj: Api_Object
	obj.t = kObjectTypeDict_API
	(^Api_Dict)(uintptr(&obj) + 8)^ = d
	aucmd_defer(EVENT_MARKSET, &mark_str[0], nil, AUGROUP_ALL, buf, nil, &obj)
}

// Set named mark "c" to position "pos".
@(export)
setmark_pos :: proc "c" (c: C.int, pos: ^Pos_T, fnum: C.int, view_pt: ^Fmarkv_T) -> C.int {
	view := view_pt != nil ? view_pt^ : INIT_FMARKV

	// Check for a special key (may cause islower() to crash).
	if c < 0 {
		return 0 // FAIL
	}

	if c == '\'' || c == '`' {
		if uintptr(pos) == uintptr(win_cursor(curwin)) {
			setpcmark()
			// keep it even when the cursor doesn't move
			get_pos(curwin, W_PREV_PCMARK)^ = get_pos(curwin, W_PCMARK)^
		} else {
			get_pos(curwin, W_PCMARK)^ = pos^
		}
		return 1 // OK
	}

	// Can't set a mark in a non-existent buffer.
	buf := buflist_findnr(fnum)
	if buf == nil {
		return 0 // FAIL
	}

	if c == '"' {
		reset_fmark(get_fmark(buf, B_LAST_CURSOR), pos^, get_i32(buf, B_HANDLE), view)
		do_markset_autocmd(u8(c), pos, buf)
		return 1 // OK
	}

	if c == '[' {
		get_pos(buf, B_OP_START)^ = pos^
		do_markset_autocmd(u8(c), pos, buf)
		return 1
	}
	if c == ']' {
		get_pos(buf, B_OP_END)^ = pos^
		do_markset_autocmd(u8(c), pos, buf)
		return 1
	}

	if c == '<' || c == '>' {
		vi := get_pos(buf, B_VISUAL)
		if c == '<' {
			vi^ = pos^
		} else {
			get_pos(buf, B_VISUAL + 12)^ = pos^
		}
		if get_i32(buf, B_VISUAL + 24) == 0 {
			// Visual_mode has not yet been set, use a sane default.
			set_i32(buf, B_VISUAL + 24, 'v')
		}
		do_markset_autocmd(u8(c), pos, buf)
		return 1
	}

	if c == ':' && bt_prompt(buf) {
		reset_fmark(get_fmark(buf, B_PROMPT_START), pos^, get_i32(buf, B_HANDLE), view)
		return 1
	}

	if ascii_islower_c(c) {
		i := c - 'a'
		reset_fmark(fmark_at(buf, B_NAMEDM, i), pos^, fnum, view)
		do_markset_autocmd(u8(c), pos, buf)
		return 1
	}
	if ascii_isupper_c(c) || ascii_isdigit_c(c) {
		i := ascii_isdigit_c(c) ? c - '0' + NMARKS : c - 'A'
		xm := get_xfmark(nil, 0)
		xm = get_xfmark(&namedfm[0], uintptr(i) * size_of(Xfmark_T))
		// RESET_XFMARK
		free_xfmark(xm^)
		xm.fname = nil
		set_fmark(&xm.fmark, pos^, fnum, view)
		do_markset_autocmd(u8(c), pos, buf)
		return 1
	}
	return 0 // FAIL
}

/// Remove every jump list entry referring to a given buffer.
@(export)
mark_jumplist_forget_file :: proc "c" (wp: rawptr, fnum: C.int) {
	jl_len := (^C.int)(uintptr(wp) + W_JUMPLISTLEN)
	i := jl_len^ - 1
	for i >= 0 {
		jm := xfmark_at(wp, i)
		if jm.fmark.fnum == fnum {
			free_xfmark(jm^)
			jl_idx := (^C.int)(uintptr(wp) + W_JUMPLISTIDX)
			if jl_idx^ > i {
				jl_idx^ -= 1
			}
			jl_len^ -= 1
			if jl_len^ > i {
				libc.memmove(jm, xfmark_at(wp, i + 1), C.size_t(jl_len^ - i) * size_of(Xfmark_T))
			}
		}
		i -= 1
	}
}

/// Delete every entry referring to file "fnum" from jumplist and tag stack.
@(export)
mark_forget_file :: proc "c" (wp: rawptr, fnum: C.int) {
	mark_jumplist_forget_file(wp, fnum)

	ts_len := (^C.int)(uintptr(wp) + W_TAGSTACKLEN)
	i := ts_len^ - 1
	for i >= 0 {
		tag := (^Taggy_T)(uintptr(wp) + W_TAGSTACK + uintptr(i) * size_of(Taggy_T))
		if tag.fmark.fnum == fnum {
			// tagstack_clear_entry
			xfree_clear((^rawptr)(tag))
			xfree_clear((^rawptr)(uintptr(tag) + 56))
			ts_idx := (^C.int)(uintptr(wp) + W_TAGSTACKIDX)
			if ts_idx^ > i {
				ts_idx^ -= 1
			}
			ts_len^ -= 1
			if ts_len^ > i {
				libc.memmove(tag, (^Taggy_T)(uintptr(wp) + W_TAGSTACK + uintptr(i + 1) * size_of(Taggy_T)),
					C.size_t(ts_len^ - i) * size_of(Taggy_T))
			}
		}
		i -= 1
	}
}

// Set the previous context mark to the current position and add it to the jump list.
@(export)
setpcmark :: proc "c" () {
	// for :global the mark is set only once
	if global_busy != 0 || listcmd_busy || (cmdmod_cmod_flags & CMOD_KEEPJUMPS) != 0 {
		return
	}

	get_pos(curwin, W_PREV_PCMARK)^ = get_pos(curwin, W_PCMARK)^
	win_cursor(curwin)^ = win_cursor(curwin)^ // no-op read to satisfy flow
	pc := get_pos(curwin, W_PCMARK)
	pc^ = win_cursor(curwin)^

	if pc.lnum == 0 {
		pc.lnum = 1
	}

	if (jop_flags & kOptJopFlagStack) != 0 {
		// jumpoptions=stack: discard everything after the current index.
		jl_len := (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)
		jl_idx := (^C.int)(uintptr(curwin) + W_JUMPLISTIDX)
		if jl_idx^ < jl_len^ - 1 {
			jl_len^ = jl_idx^ + 1
		}
	}

	// If jumplist is full: remove oldest entry
	jl_len := (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)
	jl_len^ += 1
	if jl_len^ > JUMPLISTSIZE {
		jl_len^ = JUMPLISTSIZE
		free_xfmark(xfmark_at(curwin, 0)^)
		libc.memmove(xfmark_at(curwin, 0), xfmark_at(curwin, 1), C.size_t(JUMPLISTSIZE - 1) * size_of(Xfmark_T))
	}
	set_i32(curwin, W_JUMPLISTIDX, jl_len^)
	fm := xfmark_at(curwin, jl_len^ - 1)

	view := mark_view_make(curwin, get_pos(curwin, W_PCMARK)^)
	// SET_XFMARK(fm, curwin->w_pcmark, curbuf->b_fnum, view, NULL)
	fm.fname = nil
	set_fmark(&fm.fmark, pc^, get_i32(curbuf, B_HANDLE), view)
}

// Change context: setpcmark(), move, then checkpcmark().
@(export)
checkpcmark :: proc "c" () {
	prev := get_pos(curwin, W_PREV_PCMARK)
	pc := get_pos(curwin, W_PCMARK)
	if prev.lnum != 0 && (equalpos(pc^, win_cursor(curwin)^) || pc.lnum == 0) {
		pc^ = prev^
	}
	prev.lnum = 0 // it has been checked
}

/// Get mark in "count" position in the |jumplist| relative to the current index.
@(export)
get_jumplist :: proc "c" (win: rawptr, count_arg: C.int) -> ^Fmark_T {
	count := count_arg
	jmp: ^Xfmark_T

	cleanup_jumplist(win, true)

	jl_len := (^C.int)(uintptr(win) + W_JUMPLISTLEN)
	jl_idx := (^C.int)(uintptr(win) + W_JUMPLISTIDX)
	if jl_len^ == 0 { // nothing to jump to
		return nil
	}

	for true {
		if jl_idx^ + count < 0 || jl_idx^ + count >= jl_len^ {
			return nil
		}

		// if first CTRL-O/CTRL-I after a jump, add cursor position to list
		if jl_idx^ == jl_len^ {
			setpcmark()
			jl_idx^ -= 1 // skip the new entry
			if jl_idx^ + count < 0 {
				return nil
			}
		}

		jl_idx^ += count

		jmp = xfmark_at(win, jl_idx^)
		if jmp.fmark.fnum == 0 {
			// Resolve the fnum (buff number) in the mark before returning it (shada)
			fname2fnum(jmp)
		}
		if jmp.fmark.fnum != get_i32(curbuf, B_HANDLE) {
			// Needs to switch buffer, if it can't find it skip the mark
			if buflist_findnr(jmp.fmark.fnum) == nil {
				count += count < 0 ? -1 : 1
				continue
			}
		}
		break
	}
	return &jmp.fmark
}

/// Get mark in "count" position in the |changelist| relative to the current index.
@(export)
get_changelist :: proc "c" (buf: rawptr, win: rawptr, count: C.int) -> ^Fmark_T {
	cl_len := (^C.int)(uintptr(buf) + B_CHANGELISTLEN)
	if cl_len^ == 0 { // nothing to jump to
		return nil
	}

	n := get_i32(win, W_CHANGELISTIDX)
	if n + count < 0 {
		if n == 0 {
			return nil
		}
		n = 0
	} else if n + count >= cl_len^ {
		if n == cl_len^ - 1 {
			return nil
		}
		n = cl_len^ - 1
	} else {
		n += count
	}
	set_i32(win, W_CHANGELISTIDX, n)
	fm := fmark_at(buf, B_CHANGELIST, n)
	// Changelist marks are always buffer local, Shada does not set it when loading
	fm.fnum = get_i32(curbuf, B_HANDLE)
	return fm
}

/// Get a named mark (all types).
@(export)
mark_get :: proc "c" (buf: rawptr, win: rawptr, fmp: ^Fmark_T, flag: C.int, name: C.int) -> ^Fmark_T {
	fm: ^Fmark_T
	if ascii_isupper_c(name) || ascii_isdigit_c(name) {
		// Global marks
		xfm := mark_get_global(flag != kMarkAllNoResolve, name)
		fm = &xfm.fmark
		if flag == kMarkBufLocal && xfm.fmark.fnum != get_i32(buf, B_HANDLE) {
			// Only wanted marks belonging to the buffer
			return pos_to_mark(buf, nil, Pos_T{})
		}
	} else if name > 0 && name < NMARK_LOCAL_MAX {
		// Local Marks
		fm = mark_get_local(buf, win, name)
	}
	if fmp != nil && fm != nil {
		fmp^ = fm^
		return fmp
	}
	return fm
}

/// Get a global mark {A-Z0-9}.
@(export)
mark_get_global :: proc "c" (resolve: bool, name_arg: C.int) -> ^Xfmark_T {
	name := name_arg
	if ascii_isdigit_c(name) {
		name = name - '0' + NMARKS
	} else if ascii_isupper_c(name) {
		name -= 'A'
	}
	mark := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(name) * size_of(Xfmark_T))

	if resolve && mark.fmark.fnum == 0 {
		// Resolve filename to fnum (SHADA marks)
		fname2fnum(mark)
	}
	return mark
}

/// Get a local mark (lowercase and symbols).
@(export)
mark_get_local :: proc "c" (buf: rawptr, win: rawptr, name: C.int) -> ^Fmark_T {
	mark: ^Fmark_T
	if ascii_islower_c(name) {
		// normal named mark
		mark = fmark_at(buf, B_NAMEDM, name - 'a')
	} else if name == '[' {
		// to start of previous operator
		mark = pos_to_mark(buf, nil, get_pos(buf, B_OP_START)^)
	} else if name == ']' {
		// to end of previous operator
		mark = pos_to_mark(buf, nil, get_pos(buf, B_OP_END)^)
	} else if name == '<' || name == '>' {
		// visual marks
		mark = mark_get_visual(buf, name)
	} else if name == '\'' || name == '`' {
		// previous context mark
		mark = pos_to_mark(curbuf, nil, get_pos(win, W_PCMARK)^)
	} else if name == '"' {
		// to position when leaving buffer
		mark = get_fmark(buf, B_LAST_CURSOR)
	} else if name == '^' {
		// to where last Insert mode stopped
		mark = get_fmark(buf, B_LAST_INSERT)
	} else if name == '.' {
		// to where last change was made
		mark = get_fmark(buf, B_LAST_CHANGE)
	} else if name == ':' && bt_prompt(buf) {
		// prompt start location
		mark = get_fmark(buf, B_PROMPT_START)
	} else {
		// motions, e.g {, }, (, ), ...
		mark = mark_get_motion(buf, win, name)
	}

	if mark != nil {
		mark.fnum = get_i32(buf, B_HANDLE)
	}

	return mark
}

/// Get marks that are actually motions but return them as marks: '{', '}', '(', ')'
@(export)
mark_get_motion :: proc "c" (buf: rawptr, win: rawptr, name: C.int) -> ^Fmark_T {
	mark: ^Fmark_T
	pos := win_cursor(curwin)^
	slcb := listcmd_busy
	listcmd_busy = true // avoid that '' is changed
	if name == '{' || name == '}' { // to previous/next paragraph
		incl: bool
		if findpar(&incl, name == '}' ? FORWARD_DIR : BACKWARD_DIR, 1, 0, false) {
			mark = pos_to_mark(buf, nil, win_cursor(curwin)^)
		}
	} else if name == '(' || name == ')' { // to previous/next sentence
		if findsent(name == ')' ? FORWARD_DIR : BACKWARD_DIR, 1) != 0 {
			mark = pos_to_mark(buf, nil, win_cursor(curwin)^)
		}
	}
	win_cursor(curwin)^ = pos
	listcmd_busy = slcb
	return mark
}

/// Get visual marks '<', '>'
@(export)
mark_get_visual :: proc "c" (buf: rawptr, name: C.int) -> ^Fmark_T {
	mark: ^Fmark_T
	if name == '<' || name == '>' {
		// start/end of visual area
		startp := get_pos(buf, B_VISUAL)^
		endp := get_pos(buf, B_VISUAL + 12)^
		if ((name == '<') == lt_pos(startp, endp) || endp.lnum == 0) && startp.lnum != 0 {
			mark = pos_to_mark(buf, nil, startp)
		} else {
			mark = pos_to_mark(buf, nil, endp)
		}

		if get_i32(buf, B_VISUAL + 24) == 'V' {
			if name == '<' {
				mark.mark.col = 0
			} else {
				mark.mark.col = MAXCOL
			}
			mark.mark.coladd = 0
		}
	}
	return mark
}

/// Wrap a pos_T into an fmark_T.
@(export)
pos_to_mark :: proc "c" (buf: rawptr, fmp: ^Fmark_T, pos: Pos_T) -> ^Fmark_T {
	fm := fmp == nil ? &fms_static : fmp
	fm.fnum = get_i32(buf, B_HANDLE)
	fm.mark = pos
	return fm
}

/// Attempt to switch to the buffer of the given global mark.
@(private="file")
switch_to_mark_buf :: proc "c"(fm: ^Fmark_T, pcmark_on_switch: bool) -> C.int {
	if fm.fnum != get_i32(curbuf, B_HANDLE) {
		// Switch to another file.
		getfile_flag: C.int = pcmark_on_switch ? GETF_SETMARK : 0
		res := buflist_getfile(fm.fnum, fm.mark.lnum, getfile_flag, 0) == 1
		return res ? kMarkSwitchedBuf : kMarkMoveFailed
	}
	return 0
}

/// Move to the given file mark, changing the buffer and cursor position.
@(export)
mark_move_to :: proc "c" (fm_arg: ^Fmark_T, flags: C.int) -> C.int {
	fm := fm_arg
	res: C.int = kMarkMoveSuccess
	errormsg: cstring
	if !mark_check(fm, &errormsg) {
		if errormsg != nil {
			emsg(errormsg)
		}
		return kMarkMoveFailed
	}

	if fm.fnum != get_i32(curbuf, B_HANDLE) {
		// Need to change buffer
		fm_copy_static = fm^ // Copy, autocommand may change it
		fm = &fm_copy_static
		// Jump to the file with the mark
		res |= switch_to_mark_buf(fm, (flags & kMarkJumpList) == 0)
		// Failed switching buffer
		if (res & kMarkMoveFailed) != 0 {
			return res
		}
		// Check line count now that the **destination buffer is loaded**.
		if !mark_check_line_bounds(curbuf, fm, &errormsg) {
			if errormsg != nil {
				emsg(errormsg)
			}
			res |= kMarkMoveFailed
			return res
		}
	} else if (flags & kMarkContext) != 0 {
		// Doing it in this condition avoids double context mark when switching buffer.
		setpcmark()
	}
	// Move the cursor while keeping track of what changed for the caller
	prev_pos := win_cursor(curwin)^
	pos := fm.mark
	// Set lnum again, autocommands my have changed it
	win_cursor(curwin)^ = fm.mark
	if (flags & kMarkBeginLine) != 0 {
		beginline(BL_WHITE | BL_FIX)
	}
	res = prev_pos.lnum != pos.lnum ? res | kMarkChangedLine | kMarkChangedCursor : res
	res = prev_pos.col != pos.col ? res | kMarkChangedCol | kMarkChangedCursor : res
	if (flags & kMarkSetView) != 0 {
		mark_view_restore(fm)
	}

	if (res & kMarkSwitchedBuf) != 0 || (res & kMarkChangedCursor) != 0 {
		check_cursor(curwin)
	}
	return res
}

/// Restore the mark view.
@(export)
mark_view_restore :: proc "c" (fm: ^Fmark_T) {
	if fm != nil && fm.view.topline_offset >= 0 {
		topline := fm.mark.lnum - fm.view.topline_offset
		// If the mark does not have a view, topline_offset is MAXLNUM.
		if topline >= 1 {
			set_topline(curwin, topline)
			skipcol := fm.view.skipcol
			w_skipcol := (^C.int)(uintptr(curwin) + W_SKIPCOL)
			w_skipcol^ = (skipcol > 0 && !hasFolding(curwin, topline, nil, nil) && skipcol < linetabsize_eol(curwin, topline)) ? skipcol : 0
		}
	}
}

@(export)
mark_view_make :: proc "c" (wp: rawptr, pos: Pos_T) -> Fmarkv_T {
	return Fmarkv_T{pos.lnum - get_i32(wp, W_TOPLINE), get_i32(wp, W_SKIPCOL)}
}

/// Search for the next named mark in the current file from a start position.
@(export)
getnextmark :: proc "c" (startpos: ^Pos_T, dir: C.int, begin_line: C.int) -> ^Fmark_T {
	result: ^Fmark_T
	pos := startpos^

	if dir == BACKWARD_DIR && begin_line != 0 {
		pos.col = 0
	} else if dir == FORWARD_DIR && begin_line != 0 {
		pos.col = MAXCOL
	}

	for i: C.int = 0; i < NMARKS; i += 1 {
		nm := fmark_at(curbuf, B_NAMEDM, i)
		if nm.mark.lnum > 0 {
			if dir == FORWARD_DIR {
				if (result == nil || lt_pos(nm.mark, result.mark)) && lt_pos(pos, nm.mark) {
					result = nm
				}
			} else {
				if (result == nil || lt_pos(result.mark, nm.mark)) && lt_pos(nm.mark, pos) {
					result = nm
				}
			}
		}
	}

	return result
}

// For an extended filemark: set the fnum from the fname (shada marks).
@(private="file")
fname2fnum :: proc "c"(fm: ^Xfmark_T) {
	if fm.fname == nil {
		return
	}

	// First expand "~/" in the file name to the home directory.
	if fm.fname^ == '~' && vim_ispathsep_nocolon(C.int((^u8)(uintptr(fm.fname) + 1)^)) {
		len := expand_env("~/", transmute(cstring)(&name_buff[0]), C.int(size_of(name_buff)))
		_xstrlcpy(transmute(cstring)(uintptr(&name_buff[0]) + uintptr(len)),
			transmute(cstring)(uintptr(fm.fname) + 2), C.size_t(MAXPATHL_INT) - len)
	} else {
		_xstrlcpy(transmute(cstring)(&name_buff[0]), transmute(cstring)(fm.fname), MAXPATHL_INT)
	}

	// Try to shorten the file name.
	os_dirname(transmute(cstring)(&IObuff[0]), C.size_t(size_of(IObuff) - 1))
	p := path_shorten_fname(&name_buff[0], &IObuff[0])

	// buflist_new() will call fmarks_check_names()
	_ = buflist_new(transmute(cstring)(&name_buff[0]), transmute(cstring)(p), 1, 0)
}

MAXPATHL_INT :: 4096

// Check all file marks for a name that matches the file name in buf.
@(export)
fmarks_check_names :: proc "c" (buf: rawptr) {
	ffname := (^rawptr)(uintptr(buf) + B_FFNAME)^
	if ffname == nil {
		return
	}

	for i: C.int = 0; i < NGLOBALMARKS; i += 1 {
		fmarks_check_one((^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T)),
			(^u8)(ffname), buf)
	}

	tp := first_tabpage
	for tp != nil {
		wp := tab_first_win(tp)
		for wp != nil {
			jl_len := get_i32(wp, W_JUMPLISTLEN)
			for i: C.int = 0; i < jl_len; i += 1 {
				fmarks_check_one(xfmark_at(wp, i), (^u8)(ffname), buf)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
	}
}

@(private="file")
fmarks_check_one :: proc "c"(fm: ^Xfmark_T, name: ^u8, buf: rawptr) {
	if fm.fmark.fnum == 0 && fm.fname != nil && path_fnamecmp_safe(name, fm.fname) == 0 {
		fm.fmark.fnum = get_i32(buf, B_HANDLE)
		xfree_clear((^rawptr)(&fm.fname))
	}
}

@(private="file")
path_fnamecmp_safe :: proc "c"(a, b: ^u8) -> C.int {
	return _path_fnamecmp(transmute(cstring)(a), transmute(cstring)(b))
}

/// Check the position in fm is valid.
@(export)
mark_check :: proc "c" (fm: ^Fmark_T, errormsg: ^cstring) -> bool {
	if fm == nil {
		errormsg^ = _t(e_umark)
		return false
	} else if fm.mark.lnum <= 0 {
		// In both cases it's an error but only raise when equals to 0
		if fm.mark.lnum == 0 {
			errormsg^ = _t(e_marknotset)
		}
		return false
	}
	// Only check for valid line number if the buffer is loaded.
	if fm.fnum == get_i32(curbuf, B_HANDLE) && !mark_check_line_bounds(curbuf, fm, errormsg) {
		return false
	}
	return true
}

/// Check if a mark line number is greater than the buffer line count.
@(export)
mark_check_line_bounds :: proc "c" (buf: rawptr, fm: ^Fmark_T, errormsg: ^cstring) -> bool {
	if buf != nil && fm.mark.lnum > buf_line_count(buf) {
		errormsg^ = _t(e_markinval)
		return false
	}
	return true
}

/// Clear all marks and change list in the given buffer.
@(export)
clrallmarks :: proc "c" (buf: rawptr, timestamp: Timestamp) {
	for i: C.int = 0; i < NMARKS; i += 1 {
		clear_fmark(fmark_at(buf, B_NAMEDM, i), timestamp)
	}
	clear_fmark(get_fmark(buf, B_LAST_CURSOR), timestamp)
	get_fmark(buf, B_LAST_CURSOR).mark.lnum = 1
	clear_fmark(get_fmark(buf, B_LAST_INSERT), timestamp)
	clear_fmark(get_fmark(buf, B_LAST_CHANGE), timestamp)
	get_pos(buf, B_OP_START).lnum = 0 // start/end op mark cleared
	get_pos(buf, B_OP_END).lnum = 0
	cl_len := (^C.int)(uintptr(buf) + B_CHANGELISTLEN)
	for i: C.int = 0; i < cl_len^; i += 1 {
		clear_fmark(fmark_at(buf, B_CHANGELIST, i), timestamp)
	}
	cl_len^ = 0
}

// Get name of file from a filemark. Returns an allocated string.
@(export)
fm_getname :: proc "c" (fmark: ^Fmark_T, lead_len: C.int) -> ^u8 {
	if fmark.fnum == get_i32(curbuf, B_HANDLE) { // current buffer
		return mark_line(&fmark.mark, lead_len)
	}
	return buflist_nr2name(fmark.fnum, 0, 1)
}

/// Return the line at mark "mp". Truncate to fit in window. Allocated string.
@(private="file")
mark_line :: proc "c"(mp: ^Pos_T, lead_len: C.int) -> ^u8 {
	if mp.lnum == 0 || mp.lnum > buf_line_count(curbuf) {
		return xstrdup_b("-invalid-")
	}
	// Allow for up to 5 bytes per character.
	sw := skipwhite(transmute(cstring)(ml_get(mp.lnum)))
	s := xmemdupz(transmute(rawptr)(sw), libc.strlen(sw))

	// Truncate the line to fit it in the window
	len: C.int = 0
	p := s
	for p^ != 0 {
		len += ptr2cells(transmute(cstring)(p))
		if len >= Columns - lead_len {
			break
		}
		p = mb_adv(p)
	}
	p^ = 0
	return s
}

// print the marks
@(export)
ex_marks :: proc "c" (eap: rawptr) {
	arg := (^rawptr)(uintptr(eap) + EA_ARG)^
	if arg != nil && (^u8)(arg)^ == 0 {
		arg = nil
	}

	msg_ext_set_kind(cstring("list_cmd"))
	show_one_mark('\'', (^u8)(arg), get_pos(curwin, W_PCMARK), nil, 1)
	for i: C.int = 0; i < NMARKS; i += 1 {
		show_one_mark(i + 'a', (^u8)(arg), get_pos(curbuf, B_NAMEDM + uintptr(i) * 40), nil, 1)
	}
	for i: C.int = 0; i < NGLOBALMARKS; i += 1 {
		nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
		name: ^u8
		if nfm.fmark.fnum != 0 {
			name = fm_getname(&nfm.fmark, 15)
		} else {
			name = nfm.fname
		}
		if name != nil {
			show_one_mark(i >= NMARKS ? i - NMARKS + '0' : i + 'A',
				(^u8)(arg), &nfm.fmark.mark, name, nfm.fmark.fnum == get_i32(curbuf, B_HANDLE) ? 1 : 0)
			if nfm.fmark.fnum != 0 {
				xfree(name)
			}
		}
	}
	show_one_mark('"', (^u8)(arg), get_pos(curbuf, B_LAST_CURSOR), nil, 1)
	show_one_mark('[', (^u8)(arg), get_pos(curbuf, B_OP_START), nil, 1)
	show_one_mark(']', (^u8)(arg), get_pos(curbuf, B_OP_END), nil, 1)
	show_one_mark('^', (^u8)(arg), get_pos(curbuf, B_LAST_INSERT), nil, 1)
	show_one_mark('.', (^u8)(arg), get_pos(curbuf, B_LAST_CHANGE), nil, 1)
	if bt_prompt(curbuf) {
		show_one_mark(':', (^u8)(arg), get_pos(curbuf, B_PROMPT_START), nil, 1)
	}

	// Show the marks as where they will jump to.
	startp := get_pos(curbuf, B_VISUAL)
	endp := get_pos(curbuf, B_VISUAL + 12)
	posp: ^Pos_T
	if (lt_pos(startp^, endp^) || endp.lnum == 0) && startp.lnum != 0 {
		posp = startp
	} else {
		posp = endp
	}
	show_one_mark('<', (^u8)(arg), posp, nil, 1)
	show_one_mark('>', (^u8)(arg), posp == startp ? endp : startp, nil, 1)

	show_one_mark(-1, (^u8)(arg), nil, nil, 0)
}

/// @param current  in current file
@(private="file")
show_one_mark :: proc "c"(c: C.int, arg: ^u8, p: ^Pos_T, name_arg: ^u8, current: C.int) {
	mustfree := false
	name := name_arg

	if c == -1 { // finish up
		if did_title {
			did_title = false
		} else {
			if arg == nil {
				msg_msg(_t(cstring("No marks set")), 0)
			} else {
				buf: [1025]u8
				n := libc.snprintf(&buf[0], size_of(buf),
					cstring("E283: No marks matching \"%s\""), transmute(cstring)(arg))
				buf[n if n >= 0 && n < 1024 else 1024] = 0
				emsg(transmute(cstring)(&buf[0]))
			}
		}
	} else if !got_int && (arg == nil || vim_strchr_safe(arg, c) != nil) && p.lnum != 0 {
		// don't output anything if 'q' typed at --more-- prompt
		if name == nil && current != 0 {
			name = mark_line(p, 15)
			mustfree = true
		}
		if !message_filtered(transmute(cstring)(name)) {
			if !did_title {
				// Highlight title
				msg_puts_title(_t(cstring("\nmark line  col file/text")))
				did_title = true
			}
			msg_putchar('\n')
			if !got_int {
				libc.snprintf(&IObuff[0], size_of(IObuff), cstring(" %c %6d %4d "), c, p.lnum, p.col)
				msg_outtrans(transmute(cstring)(&IObuff[0]), 0, false)
				if name != nil {
					msg_outtrans(transmute(cstring)(name), current != 0 ? HLF_D : 0, false)
				}
			}
		}
		if mustfree {
			xfree(name)
		}
	}
}

@(private="file")
vim_strchr_safe :: proc "c"(s: ^u8, c: C.int) -> ^u8 {
	return transmute(^u8)(_vim_strchr(transmute(cstring)(s), c))
}

// ":delmarks[!] [marks]"
@(export)
ex_delmarks :: proc "c" (eap: rawptr) {
	from, to: C.int
	n: C.int
	pos := Pos_T{}

	arg := (^rawptr)(uintptr(eap) + EA_ARG)^
	forceit := (^bool)(uintptr(eap) + EA_FORCEIT)^

	if (^u8)(arg)^ == 0 && forceit {
		// clear all marks
		for i: C.int = 0; i < NMARKS; i += 1 {
			if fmark_at(curbuf, B_NAMEDM, i).mark.lnum != 0 {
				do_markset_autocmd(u8(i + 'a'), &pos, curbuf)
			}
		}
		if get_fmark(curbuf, B_LAST_CURSOR).mark.lnum != 0 {
			do_markset_autocmd('"', &pos, curbuf)
		}
		if get_fmark(curbuf, B_LAST_INSERT).mark.lnum != 0 {
			do_markset_autocmd('^', &pos, curbuf)
		}
		if get_fmark(curbuf, B_LAST_CHANGE).mark.lnum != 0 {
			do_markset_autocmd('.', &pos, curbuf)
		}
		if get_pos(curbuf, B_OP_START).lnum != 0 {
			do_markset_autocmd('[', &pos, curbuf)
		}
		if get_pos(curbuf, B_OP_END).lnum != 0 {
			do_markset_autocmd(']', &pos, curbuf)
		}
		clrallmarks(curbuf, os_time())
	} else if forceit {
		emsg(_t(e_invarg))
	} else if (^u8)(arg)^ == 0 {
		emsg(_t(e_argreq))
	} else {
		// clear specified marks only
		timestamp := os_time()
		p := (^u8)(arg)
		for p^ != 0 {
			lower := ascii_islower_c(C.int(p^))
			digit := ascii_isdigit_c(C.int(p^))
			if lower || digit || ascii_isupper_c(C.int(p^)) {
				if (^u8)(uintptr(p) + 1)^ == '-' {
					// clear range of marks
					from = C.int(p^)
					to = C.int((^u8)(uintptr(p) + 2)^)
					p2 := C.int((^u8)(uintptr(p) + 2)^)
					valid := lower ? ascii_islower_c(p2) : (digit ? ascii_isdigit_c(p2) : ascii_isupper_c(p2))
					if !valid || to < from {
						semsg_invarg2(p)
						return
					}
					p = (^u8)(uintptr(p) + 2)
				} else {
					// clear one mark
					from = C.int(p^)
					to = C.int(p^)
				}

				i := from
				for i <= to {
					if lower {
						nm := fmark_at(curbuf, B_NAMEDM, i - 'a')
						if nm.mark.lnum != 0 {
							do_markset_autocmd(u8(i), &pos, curbuf)
						}
						nm.mark.lnum = 0
						nm.timestamp = timestamp
					} else {
						n = digit ? i - '0' + NMARKS : i - 'A'
						nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(n) * size_of(Xfmark_T))
						if nfm.fmark.mark.lnum != 0 {
							buf := buflist_findnr(nfm.fmark.fnum)
							if buf == nil {
								buf = curbuf
							}
							do_markset_autocmd(u8(i), &pos, buf)
						}
						nfm.fmark.mark.lnum = 0
						nfm.fmark.fnum = 0
						nfm.fmark.timestamp = timestamp
						xfree_clear((^rawptr)(&nfm.fname))
					}
					i += 1
				}
			} else {
				// switch (*p)
				ch := p^
				when true {
					switch ch {
					case '"':
						if get_fmark(curbuf, B_LAST_CURSOR).mark.lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						clear_fmark(get_fmark(curbuf, B_LAST_CURSOR), timestamp)
					case '^':
						if get_fmark(curbuf, B_LAST_INSERT).mark.lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						clear_fmark(get_fmark(curbuf, B_LAST_INSERT), timestamp)
					case ':':
						// Readonly mark. No deletion allowed.
					case '.':
						if get_fmark(curbuf, B_LAST_CHANGE).mark.lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						clear_fmark(get_fmark(curbuf, B_LAST_CHANGE), timestamp)
					case '[':
						if get_pos(curbuf, B_OP_START).lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						get_pos(curbuf, B_OP_START).lnum = 0
					case ']':
						if get_pos(curbuf, B_OP_END).lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						get_pos(curbuf, B_OP_END).lnum = 0
					case '<':
						if get_pos(curbuf, B_VISUAL).lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						get_pos(curbuf, B_VISUAL).lnum = 0
					case '>':
						if get_pos(curbuf, B_VISUAL + 12).lnum != 0 {
							do_markset_autocmd(ch, &pos, curbuf)
						}
						get_pos(curbuf, B_VISUAL + 12).lnum = 0
					case ' ':
					case:
						semsg_invarg2(p)
						return
					}
				}
			}
			p = (^u8)(uintptr(p) + 1)
		}
	}
}

// print the jumplist
@(export)
ex_jumps :: proc "c" (eap: rawptr) {
	cleanup_jumplist(curwin, true)
	// Highlight title
	msg_ext_set_kind(cstring("list_cmd"))
	msg_puts_title(_t(cstring("\n jump line  col file/text")))
	jl_len := get_i32(curwin, W_JUMPLISTLEN)
	jl_idx := get_i32(curwin, W_JUMPLISTIDX)
	for i: C.int = 0; i < jl_len && !got_int; i += 1 {
		jm := xfmark_at(curwin, i)
		if jm.fmark.mark.lnum != 0 {
			name := fm_getname(&jm.fmark, 16)

			// Make sure to output the current indicator, even when on a wiped buffer.
			if name == nil && i == jl_idx {
				name = xstrdup_b("-invalid-")
			}
			// apply :filter /pat/ or file name not available
			if name == nil || message_filtered(transmute(cstring)(name)) {
				xfree(name)
				continue
			}

			msg_putchar('\n')
			if got_int {
				xfree(name)
				break
			}
			libc.snprintf(&IObuff[0], size_of(IObuff), cstring("%c %2d %5d %4d "),
				i == jl_idx ? '>' : ' ',
				i > jl_idx ? i - jl_idx : jl_idx - i,
				jm.fmark.mark.lnum, jm.fmark.mark.col)
			msg_outtrans(transmute(cstring)(&IObuff[0]), 0, false)
			msg_outtrans(transmute(cstring)(name), jm.fmark.fnum == get_i32(curbuf, B_HANDLE) ? HLF_D : 0, false)
			xfree(name)
			os_breakcheck()
		}
	}
	if get_i32(curwin, W_JUMPLISTIDX) == get_i32(curwin, W_JUMPLISTLEN) {
		msg_puts(cstring("\n>"))
	}
}

@(export)
ex_clearjumps :: proc "c" (eap: rawptr) {
	free_jumplist(curwin)
	set_i32(curwin, W_JUMPLISTLEN, 0)
	set_i32(curwin, W_JUMPLISTIDX, 0)
}

// print the changelist
@(export)
ex_changes :: proc "c" (eap: rawptr) {
	msg_ext_set_kind(cstring("list_cmd"))
	// Highlight title
	msg_puts_title(_t(cstring("\nchange line  col text")))

	cl_len := get_i32(curbuf, B_CHANGELISTLEN)
	cl_idx := get_i32(curwin, W_CHANGELISTIDX)
	for i: C.int = 0; i < cl_len && !got_int; i += 1 {
		cm := fmark_at(curbuf, B_CHANGELIST, i)
		if cm.mark.lnum != 0 {
			msg_putchar('\n')
			if got_int {
				break
			}
			libc.snprintf(&IObuff[0], size_of(IObuff), cstring("%c %3d %5d %4d "),
				i == cl_idx ? '>' : ' ',
				i > cl_idx ? i - cl_idx : cl_idx - i,
				cm.mark.lnum, cm.mark.col)
			msg_outtrans(transmute(cstring)(&IObuff[0]), 0, false)
			name := mark_line(&cm.mark, 17)
			msg_outtrans(transmute(cstring)(name), HLF_D, false)
			xfree(name)
			os_breakcheck()
		}
	}
	if get_i32(curwin, W_CHANGELISTIDX) == get_i32(curbuf, B_CHANGELISTLEN) {
		msg_puts(cstring("\n>"))
	}
}

// Adjust marks between "line1" and "line2" (inclusive) to move "amount" lines.
@(export)
mark_adjust :: proc "c" (line1, line2, amount, amount_after: C.int, op: C.int) {
	mark_adjust_buf(curbuf, line1, line2, amount, amount_after, true, kMarkAdjustNormal, op)
}

// mark_adjust_nofold(): same as mark_adjust() but without adjusting folds.
@(export)
mark_adjust_nofold :: proc "c" (line1, line2, amount, amount_after: C.int, op: C.int) {
	mark_adjust_buf(curbuf, line1, line2, amount, amount_after, false, kMarkAdjustNormal, op)
}

@(export)
mark_adjust_buf :: proc "c" (buf: rawptr, line1, line2, amount, amount_after: C.int,
	adjust_folds: bool, mode: C.int, op: C.int) {
	fnum := get_i32(buf, B_HANDLE)

	if line2 < line1 && amount_after == 0 { // nothing to do
		return
	}

	by_api := mode == kMarkAdjustApi
	by_term := mode == kMarkAdjustTerm

	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
		// named marks, lower case and upper case
		for i: C.int = 0; i < NMARKS; i += 1 {
			one_adjust(&fmark_at(buf, B_NAMEDM, i).mark.lnum, line1, line2, amount, amount_after)
			nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
			if nfm.fmark.fnum == fnum {
				one_adjust_nodel(&nfm.fmark.mark.lnum, line1, line2, amount, amount_after)
			}
		}
		for i := NMARKS; i < NGLOBALMARKS; i += 1 {
			nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
			if nfm.fmark.fnum == fnum {
				one_adjust_nodel(&nfm.fmark.mark.lnum, line1, line2, amount, amount_after)
			}
		}

		// last Insert position
		one_adjust(&get_fmark(buf, B_LAST_INSERT).mark.lnum, line1, line2, amount, amount_after)

		// last change position
		one_adjust(&get_fmark(buf, B_LAST_CHANGE).mark.lnum, line1, line2, amount, amount_after)

		// last cursor position, if it was set
		lc := get_fmark(buf, B_LAST_CURSOR)
		if !equalpos(lc.mark, Pos_T{1, 0, 0}) && (!by_term || lc.mark.lnum < buf_line_count(buf)) {
			one_adjust(&lc.mark.lnum, line1, line2, amount, amount_after)
		}

		// on prompt buffer adjust the last prompt start location mark
		if bt_prompt(buf) {
			one_adjust_nodel(&get_fmark(buf, B_PROMPT_START).mark.lnum, line1, line2, amount, amount_after)
		}

		// list of change positions
		cl_len := get_i32(buf, B_CHANGELISTLEN)
		for i: C.int = 0; i < cl_len; i += 1 {
			one_adjust_nodel(&fmark_at(buf, B_CHANGELIST, i).mark.lnum, line1, line2, amount, amount_after)
		}

		// Visual area
		one_adjust_nodel(&get_pos(buf, B_VISUAL).lnum, line1, line2, amount, amount_after)
		one_adjust_nodel(&get_pos(buf, B_VISUAL + 12).lnum, line1, line2, amount, amount_after)

		// quickfix marks
		if !qf_mark_adjust(buf, nil, line1, line2, amount, amount_after) {
			hqe := (^C.int)(uintptr(buf) + B_HAS_QF_ENTRY)
			hqe^ &= ~C.int(BUF_HAS_QF_ENTRY)
		}
		// location lists
		found_one := false
		tp := first_tabpage
		for tp != nil {
			wp := tab_first_win(tp)
			for wp != nil {
				found_one = found_one || qf_mark_adjust(buf, wp, line1, line2, amount, amount_after)
				wp = (^rawptr)(uintptr(wp) + W_NEXT)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
		}
		if !found_one {
			hqe := (^C.int)(uintptr(buf) + B_HAS_QF_ENTRY)
			hqe^ &= ~C.int(BUF_HAS_LL_ENTRY)
		}
	}

	if op != 0 { // kExtmarkNOOP
		extmark_adjust(buf, line1, line2, amount, amount_after, op)
	}

	if (^rawptr)(uintptr(curwin) + W_BUFFER)^ == buf {
		// previous context mark
		one_adjust(&get_pos(curwin, W_PCMARK).lnum, line1, line2, amount, amount_after)

		// previous pcmark
		one_adjust(&get_pos(curwin, W_PREV_PCMARK).lnum, line1, line2, amount, amount_after)

		// saved cursor for formatting
		if saved_cursor.lnum != 0 {
			one_adjust_nodel(&saved_cursor.lnum, line1, line2, amount, amount_after)
		}
	}

	// Adjust items in all windows related to the current buffer.
	tp := first_tabpage
	for tp != nil {
		wp := tab_first_win(tp)
		for wp != nil {
			if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
				// Marks in the jumplist.
				jl_len := get_i32(wp, W_JUMPLISTLEN)
				for i: C.int = 0; i < jl_len; i += 1 {
					jm := xfmark_at(wp, i)
					if jm.fmark.fnum == fnum {
						one_adjust_nodel(&jm.fmark.mark.lnum, line1, line2, amount, amount_after)
					}
				}
			}

			if (^rawptr)(uintptr(wp) + W_BUFFER)^ == buf {
				if (cmdmod_cmod_flags & CMOD_LOCKMARKS) == 0 {
					// marks in the tag stack
					ts_len := get_i32(wp, W_TAGSTACKLEN)
					for i: C.int = 0; i < ts_len; i += 1 {
						tag := (^Taggy_T)(uintptr(wp) + W_TAGSTACK + uintptr(i) * size_of(Taggy_T))
						if tag.fmark.fnum == fnum {
							one_adjust_nodel(&tag.fmark.mark.lnum, line1, line2, amount, amount_after)
						}
					}
				}

				// the displayed Visual area
				if get_i32(wp, W_OLD_CURSOR_LNUM) != 0 {
					one_adjust_nodel((^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM), line1, line2, amount, amount_after)
					one_adjust_nodel((^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM), line1, line2, amount, amount_after)
				}

				// topline and cursor position for windows with the same buffer
				// other than the current window
				w_cursor_lnum := get_pos(wp, W_CURSOR).lnum
				if by_api || (by_term ? w_cursor_lnum < buf_line_count(buf) : wp != curwin) {
					w_topline := (^C.int)(uintptr(wp) + W_TOPLINE)
					if w_topline^ >= line1 && w_topline^ <= line2 {
						if amount == MAXLNUM { // topline is deleted
							if by_api && amount_after > line1 - line2 - 1 {
								// api: adjusted later via fix_cursor()
							} else {
								w_topline^ = max(line1 - 1, 1)
							}
						} else if w_topline^ > line1 {
							// keep topline on the same line
							w_topline^ += amount
						}
						set_i32(wp, W_TOPFILL, 0)
					} else if amount_after != 0 && w_topline^ > line2 + (by_api && line2 < line1 ? 1 : 0) {
						// api: display new line if inserted right at topline
						w_topline^ += amount_after
						set_i32(wp, W_TOPFILL, 0)
					}
				}
				if !by_api && (by_term ? get_pos(wp, W_CURSOR).lnum < buf_line_count(buf) : wp != curwin) {
					one_adjust_cursor(get_pos(wp, W_CURSOR), line1, line2, amount, amount_after)
				}

				if adjust_folds {
					foldMarkAdjust(wp, line1, line2, amount, amount_after)
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
	}

	// adjust diffs
	diff_mark_adjust(buf, line1, line2, amount, amount_after)

	// adjust per-window "last cursor" positions
	kv_n := (^C.size_t)(uintptr(buf) + B_WININFO)^
	kv_items := (^^rawptr)(uintptr(buf) + B_WININFO + 16)
	for i: C.size_t = 0; i < kv_n; i += 1 {
		wip := (^rawptr)(uintptr(kv_items) + uintptr(i) * size_of(rawptr))^
		wi_mark := get_fmark(wip, WI_MARK)
		if !by_term || wi_mark.mark.lnum < buf_line_count(buf) {
			one_adjust_cursor(&wi_mark.mark, line1, line2, amount, amount_after)
		}
	}
}

// Adjust marks in line "lnum" at column "mincol" and further.
@(export)
mark_col_adjust :: proc "c" (lnum, mincol, lnum_amount, col_amount: C.int, spaces_removed: C.int) {
	fnum := get_i32(curbuf, B_HANDLE)

	if (col_amount == 0 && lnum_amount == 0) || (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
		return // nothing to do
	}
	// named marks, lower case and upper case
	for i: C.int = 0; i < NMARKS; i += 1 {
		col_adjust_one(&fmark_at(curbuf, B_NAMEDM, i).mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
		nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
		if nfm.fmark.fnum == fnum {
			col_adjust_one(&nfm.fmark.mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
		}
	}
	for i := NMARKS; i < NGLOBALMARKS; i += 1 {
		nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
		if nfm.fmark.fnum == fnum {
			col_adjust_one(&nfm.fmark.mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
		}
	}

	// last Insert position
	col_adjust_one(&get_fmark(curbuf, B_LAST_INSERT).mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)

	// last change position
	col_adjust_one(&get_fmark(curbuf, B_LAST_CHANGE).mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)

	if bt_prompt(curbuf) {
		col_adjust_one(&get_fmark(curbuf, B_PROMPT_START).mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
	}

	// list of change positions
	cl_len := get_i32(curbuf, B_CHANGELISTLEN)
	for i: C.int = 0; i < cl_len; i += 1 {
		col_adjust_one(&fmark_at(curbuf, B_CHANGELIST, i).mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
	}

	// Visual area
	col_adjust_one(get_pos(curbuf, B_VISUAL), lnum, mincol, lnum_amount, col_amount, spaces_removed)
	col_adjust_one(get_pos(curbuf, B_VISUAL + 12), lnum, mincol, lnum_amount, col_amount, spaces_removed)

	// previous context mark
	col_adjust_one(get_pos(curwin, W_PCMARK), lnum, mincol, lnum_amount, col_amount, spaces_removed)

	// previous pcmark
	col_adjust_one(get_pos(curwin, W_PREV_PCMARK), lnum, mincol, lnum_amount, col_amount, spaces_removed)

	// saved cursor for formatting
	col_adjust_one(&saved_cursor, lnum, mincol, lnum_amount, col_amount, spaces_removed)

	// Adjust items in all windows related to the current buffer.
	tp := first_tabpage
	for tp != nil {
		wp := tab_first_win(tp)
		for wp != nil {
			// marks in the jumplist
			jl_len := get_i32(wp, W_JUMPLISTLEN)
			for i: C.int = 0; i < jl_len; i += 1 {
				jm := xfmark_at(wp, i)
				if jm.fmark.fnum == fnum {
					col_adjust_one(&jm.fmark.mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
				}
			}

			if (^rawptr)(uintptr(wp) + W_BUFFER)^ == curbuf {
				// marks in the tag stack
				ts_len := get_i32(wp, W_TAGSTACKLEN)
				for i: C.int = 0; i < ts_len; i += 1 {
					tag := (^Taggy_T)(uintptr(wp) + W_TAGSTACK + uintptr(i) * size_of(Taggy_T))
					if tag.fmark.fnum == fnum {
						col_adjust_one(&tag.fmark.mark, lnum, mincol, lnum_amount, col_amount, spaces_removed)
					}
				}

				// cursor position for other windows with the same buffer
				if wp != curwin {
					col_adjust_one(get_pos(wp, W_CURSOR), lnum, mincol, lnum_amount, col_amount, spaces_removed)
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
	}
}

// When deleting lines, remove duplicate marks in the jumplist.
@(export)
cleanup_jumplist :: proc "c" (wp: rawptr, loadfiles: bool) {
	jl_len := (^C.int)(uintptr(wp) + W_JUMPLISTLEN)
	jl_idx := (^C.int)(uintptr(wp) + W_JUMPLISTIDX)

	if loadfiles {
		// Load all the files from the jump list.
		for i: C.int = 0; i < jl_len^; i += 1 {
			jm := xfmark_at(wp, i)
			if jm.fmark.fnum == 0 && jm.fmark.mark.lnum != 0 {
				fname2fnum(jm)
			}
		}
	}

	to: C.int = 0
	from: C.int = 0
	for from < jl_len^ {
		if jl_idx^ == from {
			jl_idx^ = to
		}
		i := from + 1
		for i < jl_len^ {
			ji := xfmark_at(wp, i)
			jf := xfmark_at(wp, from)
			if ji.fmark.fnum == jf.fmark.fnum && jf.fmark.fnum != 0 && ji.fmark.mark.lnum == jf.fmark.mark.lnum {
				break
			}
			i += 1
		}

		mustfree: bool
		if i >= jl_len^ { // not duplicate
			mustfree = false
		} else if i > from + 1 { // non-adjacent duplicate
			// jumpoptions=stack: remove duplicates only when adjacent.
			mustfree = (jop_flags & kOptJopFlagStack) == 0
		} else { // adjacent duplicate
			mustfree = true
		}

		if mustfree {
			xfree(xfmark_at(wp, from).fname)
		} else {
			if to != from {
				xfmark_at(wp, to)^ = xfmark_at(wp, from)^
			}
			to += 1
		}
		from += 1
	}
	if jl_idx^ == jl_len^ {
		jl_idx^ = to
	}
	jl_len^ = to

	// When pointer is below last jump, remove the jump if it matches the current line.
	if loadfiles && jl_len^ != 0 && jl_idx^ == jl_len^ {
		fm_last := xfmark_at(wp, jl_len^ - 1)
		if fm_last.fmark.fnum == get_i32(curbuf, B_HANDLE) && fm_last.fmark.mark.lnum == win_cursor(curwin).lnum {
			xfree(fm_last.fname)
			jl_len^ -= 1
			jl_idx^ -= 1
		}
	}
}

// Copy the jumplist from window "from" to window "to".
@(export)
copy_jumplist :: proc "c" (from, to: rawptr) {
	from_len := get_i32(from, W_JUMPLISTLEN)
	for i: C.int = 0; i < from_len; i += 1 {
		src := xfmark_at(from, i)
		dst := xfmark_at(to, i)
		dst^ = src^
		if src.fname != nil {
			dst.fname = xstrdup(src.fname)
		}
	}
	set_i32(to, W_JUMPLISTLEN, from_len)
	set_i32(to, W_JUMPLISTIDX, get_i32(from, W_JUMPLISTIDX))
}

/// Iterate over jumplist items.
@(export)
mark_jumplist_iter :: proc "c" (iter: rawptr, win: rawptr, fm: ^Xfmark_T) -> rawptr {
	jl_len := get_i32(win, W_JUMPLISTLEN)
	if iter == nil && jl_len == 0 {
		fm^ = Xfmark_T{}
		return nil
	}
	iter_mark := iter == nil ? xfmark_at(win, 0) : (^Xfmark_T)(iter)
	fm^ = iter_mark^
	if uintptr(iter_mark) == uintptr(xfmark_at(win, jl_len - 1)) {
		return nil
	}
	return (^rawptr)(uintptr(iter_mark) + size_of(Xfmark_T))
}

/// Iterate over global marks.
@(export)
mark_global_iter :: proc "c" (iter: rawptr, name: ^u8, fm: ^Xfmark_T) -> rawptr {
	name^ = 0
	base := uintptr(&namedfm[0])
	iter_mark := iter == nil ? base : uintptr(iter)
	for (iter_mark-base)/size_of(Xfmark_T) < NGLOBALMARKS && (^Xfmark_T)(iter_mark).fmark.mark.lnum == 0 {
		iter_mark += size_of(Xfmark_T)
	}
	if (iter_mark-base)/size_of(Xfmark_T) == NGLOBALMARKS || (^Xfmark_T)(iter_mark).fmark.mark.lnum == 0 {
		return nil
	}
	iter_off := (iter_mark - base) / size_of(Xfmark_T)
	name^ = iter_off < NMARKS ? u8('A' + iter_off) : u8('0' + (iter_off - NMARKS))
	fm^ = (^Xfmark_T)(iter_mark)^
	iter_mark += size_of(Xfmark_T)
	for (iter_mark-base)/size_of(Xfmark_T) < NGLOBALMARKS {
		if (^Xfmark_T)(iter_mark).fmark.mark.lnum != 0 {
			return transmute(rawptr)(iter_mark)
		}
		iter_mark += size_of(Xfmark_T)
	}
	return nil
}

// Get next buffer mark for iteration.
@(private="file")
next_buffer_mark :: proc "c"(buf: rawptr, mark_name: ^u8) -> ^Fmark_T {
	switch mark_name^ {
	case 0:
		mark_name^ = '"'
		return get_fmark(buf, B_LAST_CURSOR)
	case '"':
		mark_name^ = '^'
		return get_fmark(buf, B_LAST_INSERT)
	case '^':
		mark_name^ = '.'
		return get_fmark(buf, B_LAST_CHANGE)
	case '.':
		mark_name^ = 'a'
		return fmark_at(buf, B_NAMEDM, 0)
	case 'z':
		return nil
	case:
		mark_name^ += 1
		return fmark_at(buf, B_NAMEDM, C.int(mark_name^ - 'a'))
	}
}

/// Iterate over buffer marks.
@(export)
mark_buffer_iter :: proc "c" (iter: rawptr, buf: rawptr, name: ^u8, fm: ^Fmark_T) -> rawptr {
	name^ = 0
	base := uintptr(fmark_at(buf, B_NAMEDM, 0))
	mark_name: u8
	if iter == nil {
		mark_name = 0
	} else if iter == transmute(rawptr)(get_fmark(buf, B_LAST_CURSOR)) {
		mark_name = '"'
	} else if iter == transmute(rawptr)(get_fmark(buf, B_LAST_INSERT)) {
		mark_name = '^'
	} else if iter == transmute(rawptr)(get_fmark(buf, B_LAST_CHANGE)) {
		mark_name = '.'
	} else {
		mark_name = u8('a' + (uintptr(iter)-base)/size_of(Fmark_T))
	}
	iter_mark := next_buffer_mark(buf, &mark_name)
	for iter_mark != nil && iter_mark.mark.lnum == 0 {
		iter_mark = next_buffer_mark(buf, &mark_name)
	}
	if iter_mark == nil {
		return nil
	}
	if mark_name != 0 {
		name^ = mark_name
	} else {
		name^ = u8('a' + (uintptr(transmute(rawptr)(iter_mark))-base)/size_of(Fmark_T))
	}
	fm^ = iter_mark^
	return transmute(rawptr)(iter_mark)
}

/// Set global mark.
@(export)
mark_set_global :: proc "c" (name: u8, fm: Xfmark_T, update: bool) -> bool {
	idx := mark_global_index(C.char(name))
	if idx == -1 {
		return false
	}
	fm_tgt := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(idx) * size_of(Xfmark_T))
	if update && fm.fmark.timestamp <= fm_tgt.fmark.timestamp {
		return false
	}
	if fm_tgt.fmark.mark.lnum != 0 {
		free_xfmark(fm_tgt^)
	}
	fm_tgt^ = fm
	return true
}

/// Set local mark.
@(export)
mark_set_local :: proc "c" (name: u8, buf: rawptr, fm: Fmark_T, update: bool) -> bool {
	fm_tgt: ^Fmark_T
	c := C.int(name)
	if ascii_islower_c(c) {
		fm_tgt = fmark_at(buf, B_NAMEDM, c - 'a')
	} else if c == '"' {
		fm_tgt = get_fmark(buf, B_LAST_CURSOR)
	} else if c == '^' {
		fm_tgt = get_fmark(buf, B_LAST_INSERT)
	} else if c == ':' {
		fm_tgt = get_fmark(buf, B_PROMPT_START)
	} else if c == '.' {
		fm_tgt = get_fmark(buf, B_LAST_CHANGE)
	} else {
		return false
	}
	if update && fm.timestamp <= fm_tgt.timestamp {
		return false
	}
	if fm_tgt.mark.lnum != 0 {
		free_fmark(fm_tgt^)
	}
	fm_tgt^ = fm
	return true
}

// Free items in the jumplist of window "wp".
@(export)
free_jumplist :: proc "c" (wp: rawptr) {
	jl_len := (^C.int)(uintptr(wp) + W_JUMPLISTLEN)
	for i: C.int = 0; i < jl_len^; i += 1 {
		free_xfmark(xfmark_at(wp, i)^)
	}
	jl_len^ = 0
}

@(export)
set_last_cursor :: proc "c" (win: rawptr) {
	w_buffer := (^rawptr)(uintptr(win) + W_BUFFER)^
	if w_buffer != nil {
		reset_fmark(get_fmark(w_buffer, B_LAST_CURSOR), win_cursor(win)^, 0, INIT_FMARKV)
	}
}

// EXITFREE: free all global marks.
@(export)
free_all_marks :: proc "c" () {
	for i: C.int = 0; i < NGLOBALMARKS; i += 1 {
		nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
		if nfm.fmark.mark.lnum != 0 {
			free_xfmark(nfm^)
		}
	}
	namedfm = {}
}

/// Adjust position to point to the first byte of a multi-byte character.
@(export)
mark_mb_adjustpos :: proc "c" (buf: rawptr, lp: ^Pos_T) {
	if lp.col > 0 || lp.coladd > 1 {
		p := ml_get_buf(buf, lp.lnum)
		if p^ == 0 || ml_get_buf_len(buf, lp.lnum) < lp.col {
			lp.col = 0
		} else {
			lp.col -= utf_head_off(transmute(cstring)(p), transmute(cstring)(uintptr(p) + uintptr(lp.col)))
		}
		// Reset "coladd" when the cursor would be on the right half of a
		// double-wide character.
		if lp.coladd == 1 && (^u8)(uintptr(p) + uintptr(lp.col))^ != '\t' && vim_isprintc(utf_ptr2char(transmute(cstring)(uintptr(p) + uintptr(lp.col)))) && ptr2cells(transmute(cstring)(uintptr(p) + uintptr(lp.col))) > 1 {
			lp.coladd = 0
		}
	}
}

// Add information about mark 'mname' to list 'l'.
@(private="file")
add_mark :: proc "c"(l: rawptr, mname: ^u8, mnamelen: C.size_t, pos: ^Pos_T, bufnr: C.int, fname: ^u8) -> C.int {
	if pos.lnum <= 0 {
		return 1 // OK
	}

	d := tv_dict_alloc_m()
	tv_list_append_dict_m(l, d)

	lpos := tv_list_alloc(-3) // kListLenMayKnow

	tv_list_append_number_m(lpos, i64(bufnr))
	tv_list_append_number_m(lpos, i64(pos.lnum))
	tv_list_append_number_m(lpos, i64(pos.col < MAXCOL ? pos.col + 1 : MAXCOL))
	tv_list_append_number_m(lpos, i64(pos.coladd))

	if tv_dict_add_str_len_m(d, cstring("mark"), 4, transmute(cstring)(mname), C.int(mnamelen)) == 0 || tv_dict_add_list_m(d, cstring("pos"), 3, lpos) == 0 || (fname != nil && tv_dict_add_str_m(d, cstring("file"), 4, transmute(cstring)(fname)) == 0) {
		return 0 // FAIL
	}

	return 1 // OK
}

/// Get information about marks local to a buffer.
@(export)
get_buf_local_marks :: proc "c" (buf: rawptr, l: rawptr) {
	mname: [3]u8 = {'\'', ' ', 0}

	// Marks 'a' to 'z'
	for i: C.int = 0; i < NMARKS; i += 1 {
		mname[1] = u8('a' + i)
		add_mark(l, &mname[0], 2, get_pos(buf, B_NAMEDM + uintptr(i) * 40), get_i32(buf, B_HANDLE), nil)
	}

	// Mark '' is a window local mark and not a buffer local mark
	add_mark(l, transmute(^u8)(cstring("''")), 2, get_pos(curwin, W_PCMARK), get_i32(curbuf, B_HANDLE), nil)

	add_mark(l, transmute(^u8)(cstring("'\"")), 2, get_pos(buf, B_LAST_CURSOR), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("'[")), 2, get_pos(buf, B_OP_START), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("']")), 2, get_pos(buf, B_OP_END), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("'^")), 2, get_pos(buf, B_LAST_INSERT), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("'.")), 2, get_pos(buf, B_LAST_CHANGE), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("'<")), 2, get_pos(buf, B_VISUAL), get_i32(buf, B_HANDLE), nil)
	add_mark(l, transmute(^u8)(cstring("'>")), 2, get_pos(buf, B_VISUAL + 12), get_i32(buf, B_HANDLE), nil)
}

/// Get a global mark (might not have its fnum resolved).
@(export)
get_raw_global_mark :: proc "c" (name: u8) -> Xfmark_T {
	idx := mark_global_index(C.char(name))
	return (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(idx) * size_of(Xfmark_T))^
}

/// Get information about global marks ('A' to 'Z' and '0' to '9').
@(export)
get_global_marks :: proc "c" (l: rawptr) {
	mname: [3]u8 = {'\'', ' ', 0}
	name: ^u8

	// Marks 'A' to 'Z' and '0' to '9'
	for i: C.int = 0; i < NMARKS + EXTRA_MARKS; i += 1 {
		nfm := (^Xfmark_T)(uintptr(&namedfm[0]) + uintptr(i) * size_of(Xfmark_T))
		if nfm.fmark.fnum != 0 {
			name = buflist_nr2name(nfm.fmark.fnum, 1, 1)
		} else {
			name = nfm.fname
		}
		if name != nil {
			mname[1] = i >= NMARKS ? u8(i - NMARKS + '0') : u8(i + 'A')

			add_mark(l, &mname[0], 2, &nfm.fmark.mark, nfm.fmark.fnum, name)
			if nfm.fmark.fnum != 0 {
				xfree(name)
			}
		}
	}
}

// mark_global_index from mark.h (static inline in C)
@(private="file")
mark_global_index :: proc "c"(name: C.char) -> C.int {
	c := C.int(name)
	if ascii_isupper_c(c) {
		return c - 'A'
	} else if ascii_isdigit_c(c) {
		return NMARKS + (c - '0')
	}
	return -1
}
