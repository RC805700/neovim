// undo.odin — port of src/nvim/undo.c (undo tree, u_save*, :undo/:earlier, undo files)
//
// Layouts probe-verified 2026-07:
//   u_header_T=1192 {uh_next@0,uh_prev@8,uh_alt_next@16,uh_alt_prev@24 (union ptr/int),
//     uh_seq@32,uh_walk@36,uh_entry@40,uh_getbot_entry@48,uh_cursor@56,uh_cursor_vcol@68,
//     uh_flags@72,uh_namedm[26]@80,uh_extmark(kvec)@1120,uh_visual@1144,uh_time@1176,
//     uh_save_nr@1184}
//   u_entry_T=40 {ue_next@0,ue_top@8,ue_bot@12,ue_lcount@16,ue_array@24(char**),ue_size@32}
//   ExtmarkUndoObject=56 {type@0,data@8}; ExtmarkSplice/Move=48; SavePos=24
//
// Union handling: uh_next..uh_alt_prev are union{ptr,int seq} — stored as rawptr;
// integer access via (^C.int)(uintptr(&field))^.

package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:crypto/sha2"
import "core:sys/posix"



// ── Constants ────────────────────────────────────────────────────────────────

UNDO_HASH_SIZE :: 32

UH_CHANGED :: 0x01
UH_EMPTYBUF :: 0x02
UH_RELOAD :: 0x04

UF_START_MAGIC :: "Vim\x9fUnDo\xe5"
UF_START_MAGIC_LEN :: 9
UF_HEADER_MAGIC :: 0x5fd0
UF_HEADER_END_MAGIC :: 0xe7aa
UF_ENTRY_MAGIC :: 0xf518
UF_ENTRY_END_MAGIC :: 0x3581
UF_VERSION :: 3
UF_LAST_SAVE_NR :: 1
UHP_SAVE_NR :: 1

ML_EMPTY :: 0x01
BL_SOL :: 2
SHM_UNDO_CH :: 'u'
NO_LOCAL_UNDOLEVEL :: -123456
kExtmarkSplice_U :: 0
kExtmarkMove_U :: 1

// buf_T offsets (probe-verified)
B_U_OLDHEAD :: 7752
B_U_NEWHEAD :: 7760
B_U_CURHEAD :: 7768
B_U_NUMHEAD :: 7776
B_U_SYNCED :: 7780 // bool
B_U_SEQ_LAST :: 7784
B_U_SAVE_NR_LAST :: 7788
B_U_SEQ_CUR :: 7792
B_U_TIME_CUR :: 7800
B_U_SAVE_NR_CUR :: 7808
B_U_LINE_PTR :: 7816
B_U_LINE_LNUM :: 7824
B_U_LINE_COLNR :: 7828
B_CHANGED :: 208
B_ML_FLAGS :: 40 // b_ml(8) + ml_flags(32)
B_NEW_CHANGE :: 5588
B_MODIFIED_WAS_SET :: 7741
B_DID_WARN :: 11169
B_P_FS :: 10532
B_P_MA :: 10584
B_P_UL :: 10928

// Error strings (Odin literals)
e_undo_list_corrupt: cstring = "E439: undo list corrupt"
e_undo_line_missing: cstring = "E440: undo line missing"
e_not_open_u: cstring = "E828: Cannot open undo file for writing: %s"
e_modifiable: cstring = "E21: Cannot make changes, 'modifiable' is off"
e_sandbox: cstring = "E48: Not allowed in sandbox"
e_textlock: cstring = "E565: Not allowed to change text or change window"
e_write_error_undofile: cstring = "E514: write error (file system full?)"

// ── Types ────────────────────────────────────────────────────────────────────

U_Entry_T :: struct {
	ue_next:   ^U_Entry_T,
	ue_top:    C.int,
	ue_bot:    C.int,
	ue_lcount: C.int,
	_pad0:     [4]u8,
	ue_array:  ^^u8,
	ue_size:   C.int,
}
#assert(size_of(U_Entry_T) == 40)

U_Header_T :: struct {
	uh_next:        rawptr, // union{ptr, int seq}
	uh_prev:        rawptr,
	uh_alt_next:    rawptr,
	uh_alt_prev:    rawptr,
	uh_seq:         C.int,
	uh_walk:        C.int,
	uh_entry:       ^U_Entry_T,
	uh_getbot_entry: ^U_Entry_T,
	uh_cursor:      Pos_T,
	uh_cursor_vcol: C.int,
	uh_flags:       C.int,
	uh_namedm:      [NMARKS]Fmark_T,
	uh_extmark:     Kvec_XUndo, // kvec_t(ExtmarkUndoObject): n,a,items
	uh_visual:      Visualinfo_T,
	uh_time:        C.long, // time_t
	uh_save_nr:     C.int,
}
#assert(size_of(U_Header_T) == 1192)

Extmark_Splice :: struct {
	start_row:  C.int,
	start_col:  C.int,
	old_row:    C.int,
	old_col:    C.int,
	new_row:    C.int,
	new_col:    C.int,
	start_byte: i64,
	old_byte:   i64,
	new_byte:   i64,
}
#assert(size_of(Extmark_Splice) == 48)

Extmark_Move :: struct {
	start_row:   C.int,
	start_col:   C.int,
	extent_row:  C.int,
	extent_col:  C.int,
	new_row:     C.int,
	new_col:     C.int,
	start_byte:  i64,
	extent_byte: i64,
	new_byte:    i64,
}
#assert(size_of(Extmark_Move) == 48)

ExtmarkUndoObject :: struct {
	type: C.int,
	_pad: [4]u8,
	data: [48]u8,
}
#assert(size_of(ExtmarkUndoObject) == 56)

Kvec_XUndo :: struct {
	n:      C.size_t,
	a:      C.size_t,
	items:  ^ExtmarkUndoObject,
}
#assert(size_of(Kvec_XUndo) == 24)

Bufinfo_T :: struct {
	bi_buf: rawptr,
	bi_fp:  ^libc.FILE,
}

// ── Statics ──────────────────────────────────────────────────────────────────

u_newcount, u_oldcount: C.int
undo_undoes := false
lastmark: C.int = 0

// ── Foreign globals ──────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "no_u_sync")
	no_u_sync: C.int

	@(link_name = "p_ul")
	p_ul: i64

	@(link_name = "p_fs")
	p_fs: C.int

	@(link_name = "p_udir")
	p_udir: ^u8

	@(link_name = "KeyTyped")
	KeyTyped: bool

	@(link_name = "fdo_flags")
	fdo_flags: C.uint
}

// ── Foreign procs ────────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "change_warning")
	change_warning_r :: proc "c" (buf: rawptr, col: C.int) ---
	@(link_name = "block_autocmds")
	block_autocmds_r :: proc "c" () ---
	@(link_name = "unblock_autocmds")
	unblock_autocmds_r :: proc "c" () ---
	@(link_name = "text_locked")
	text_locked_r :: proc "c" () -> bool ---
	@(link_name = "text_locked_msg")
	text_locked_msg_r :: proc "c" () ---
	@(link_name = "expr_map_locked")
	expr_map_locked_r :: proc "c" () -> bool ---
	@(link_name = "virtual_active")
	virtual_active_r :: proc "c" (wp: rawptr) -> bool ---
	@(link_name = "coladvance")
	coladvance_r :: proc "c" (wp: rawptr, wcol: C.int) -> C.int ---
	@(link_name = "check_cursor_lnum")
	check_cursor_lnum_r :: proc "c" (win: rawptr) ---
	@(link_name = "check_cursor_col")
	check_cursor_col_r :: proc "c" (win: rawptr) ---
	@(link_name = "changed")
	changed_r :: proc "c" (buf: rawptr) ---
	@(link_name = "unchanged")
	unchanged_r :: proc "c" (buf: rawptr, ff: bool, always_inc_changedtick: bool) ---
	@(link_name = "buf_updates_unload")
	buf_updates_unload_r :: proc "c" (buf: rawptr, can_reload: bool) ---
	@(link_name = "buf_updates_changedtick")
	buf_updates_changedtick_r :: proc "c" (buf: rawptr) ---
	// foldOpenCursor now defined in fold.odin — reuse directly.
	@(link_name = "messaging")
	messaging_r :: proc "c" () -> bool ---
	@(link_name = "msg_keep")
	msg_keep_r :: proc "c" (s: cstring, hl_id: C.int, keep: bool, multiline: bool) -> bool ---
	@(link_name = "give_warning")
	give_warning_r :: proc "c" (message: cstring, hl: bool, hist: bool) ---
	@(link_name = "verbose_enter")
	verbose_enter_r :: proc "c" () ---
	@(link_name = "verbose_leave")
	verbose_leave_r :: proc "c" () ---
	@(link_name = "verb_msg")
	verb_msg_r :: proc "c" (s: cstring) -> C.int ---
	@(link_name = "iemsg")
	iemsg_r :: proc "c" (s: cstring) ---
	@(link_name = "sort_strings")
	sort_strings_r :: proc "c" (files: ^^u8, count: C.int) ---
	@(link_name = "msg_start")
	msg_start_r :: proc "c" () ---
	@(link_name = "msg_end")
	msg_end_r :: proc "c" () -> bool ---
	@(link_name = "resolve_symlink")
	resolve_symlink_r :: proc "c" (fname: cstring, buf: ^u8) -> C.int ---
	@(link_name = "path_tail")
	path_tail_r :: proc "c" (fname: cstring) -> ^u8 ---
	@(link_name = "concat_fnames")
	concat_fnames_r :: proc "c" (fname1: NvimString, fname2: NvimString, sep: bool) -> NvimString ---
	@(link_name = "get2c")
	get2c_r :: proc "c" (fd: ^libc.FILE) -> C.int ---
	@(link_name = "get4c")
	get4c_r :: proc "c" (fd: ^libc.FILE) -> C.int ---
	@(link_name = "get8ctime")
	get8ctime_r :: proc "c" (fd: ^libc.FILE) -> C.long ---
	@(link_name = "read_eintr")
	read_eintr_r :: proc "c" (fd: C.int, buf: rawptr, bufsize: C.size_t) -> C.ssize_t ---
	@(link_name = "FullName_save")
	FullName_save_r :: proc "c" (fname: cstring, force: bool) -> ^u8 ---
	@(link_name = "get_buf_arg")
	get_buf_arg_r :: proc "c" (arg: ^Typval) -> rawptr ---
	@(link_name = "file_ff_differs")
	file_ff_differs_r :: proc "c" (buf: rawptr, ignore_empty: bool) -> bool ---
	@(link_name = "extmark_apply_undo")
	extmark_apply_undo_r :: proc "c" (undo_info: ExtmarkUndoObject, undo: bool) ---
	@(link_name = "ml_delete")
	ml_delete_r :: proc "c" (lnum: C.int) -> C.int ---
	// reuse time.odin's os_localtime_r (posix.time_t == C.long on this ABI)
}

@(private="file")
time_now :: proc "c"() -> C.long {
	return C.long(libc.time(nil))
}

// ── Field accessors ──────────────────────────────────────────────────────────

buf_ptr_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> rawptr {
	return (^rawptr)(uintptr(base) + off)^
}
buf_i32_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> C.int {
	return (^C.int)(uintptr(base) + off)^
}
buf_set_i32 :: #force_inline proc "c"(base: rawptr, off: uintptr, v: C.int) {
	(^C.int)(uintptr(base) + off)^ = v
}
buf_bool_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> bool {
	return (^bool)(uintptr(base) + off)^
}
buf_set_bool :: #force_inline proc "c"(base: rawptr, off: uintptr, v: bool) {
	(^bool)(uintptr(base) + off)^ = v
}
buf_i64_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> i64 {
	return (^i64)(uintptr(base) + off)^
}
buf_set_i64 :: #force_inline proc "c"(base: rawptr, off: uintptr, v: i64) {
	(^i64)(uintptr(base) + off)^ = v
}
buf_pos_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(base) + off)
}

// union field helpers on u_header
uh_next_ptr :: #force_inline proc "c"(uhp: ^U_Header_T) -> ^U_Header_T {
	return (^U_Header_T)(uhp.uh_next)
}
uh_prev_ptr :: #force_inline proc "c"(uhp: ^U_Header_T) -> ^U_Header_T {
	return (^U_Header_T)(uhp.uh_prev)
}
uh_alt_next_ptr :: #force_inline proc "c"(uhp: ^U_Header_T) -> ^U_Header_T {
	return (^U_Header_T)(uhp.uh_alt_next)
}
uh_alt_prev_ptr :: #force_inline proc "c"(uhp: ^U_Header_T) -> ^U_Header_T {
	return (^U_Header_T)(uhp.uh_alt_prev)
}
uh_set_next :: #force_inline proc "c"(uhp: ^U_Header_T, v: ^U_Header_T) {
	uhp.uh_next = v
}
uh_set_prev :: #force_inline proc "c"(uhp: ^U_Header_T, v: ^U_Header_T) {
	uhp.uh_prev = v
}
uh_set_alt_next :: #force_inline proc "c"(uhp: ^U_Header_T, v: ^U_Header_T) {
	uhp.uh_alt_next = v
}
uh_set_alt_prev :: #force_inline proc "c"(uhp: ^U_Header_T, v: ^U_Header_T) {
	uhp.uh_alt_prev = v
}
uh_seq_field :: #force_inline proc "c"(uhp: rawptr) -> C.int {
	return (^C.int)(uhp)^ // reads first 4 bytes of the union at offset given by caller
}
buf_oldhead :: #force_inline proc "c"(buf: rawptr) -> ^U_Header_T {
	return (^U_Header_T)(buf_ptr_at(buf, B_U_OLDHEAD))
}
buf_newhead :: #force_inline proc "c"(buf: rawptr) -> ^U_Header_T {
	return (^U_Header_T)(buf_ptr_at(buf, B_U_NEWHEAD))
}
buf_curhead :: #force_inline proc "c"(buf: rawptr) -> ^U_Header_T {
	return (^U_Header_T)(buf_ptr_at(buf, B_U_CURHEAD))
}
buf_set_oldhead :: #force_inline proc "c"(buf: rawptr, v: ^U_Header_T) {
	(^rawptr)(uintptr(buf) + B_U_OLDHEAD)^ = v
}
buf_set_newhead :: #force_inline proc "c"(buf: rawptr, v: ^U_Header_T) {
	(^rawptr)(uintptr(buf) + B_U_NEWHEAD)^ = v
}
buf_set_curhead :: #force_inline proc "c"(buf: rawptr, v: ^U_Header_T) {
	(^rawptr)(uintptr(buf) + B_U_CURHEAD)^ = v
}
ml_line_count_b :: #force_inline proc "c"(buf: rawptr) -> C.int {
	return buf_i32_at(buf, B_ML_LINE_COUNT)
}

// get_undolevel
get_undolevel :: proc "c" (buf: rawptr) -> i64 {
	ul := buf_i64_at(buf, B_P_UL)
	if ul == NO_LOCAL_UNDOLEVEL {
		return p_ul
	}
	return ul
}

zero_fmark_additional_data :: proc "c" (fmarks: [^]Fmark_T) {
	for i := 0; i < NMARKS; i += 1 {
		xfree(fmarks[i].additional_data)
		fmarks[i].additional_data = nil
	}
}
// [undo part 2: u_save* family, undo_allowed, u_savecommon]


// u_save_line helpers
u_save_line_buf :: proc "c" (buf: rawptr, lnum: C.int) -> ^u8 {
	return xstrdup(ml_get_buf(buf, lnum))
}

u_save_line :: proc "c" (lnum: C.int) -> ^u8 {
	return u_save_line_buf(curbuf, lnum)
}

@(export)
u_save_cursor :: proc "c" () -> C.int {
	cur := (^C.int)(uintptr(curwin) + W_CURSOR)^
	top := cur > 0 ? cur - 1 : 0
	bot := cur + 1

	return u_save(top, bot)
}

@(export)
u_save :: proc "c" (top: C.int, bot: C.int) -> C.int {
	return u_save_buf(curbuf, top, bot)
}

@(export)
u_save_buf :: proc "c" (buf: rawptr, top: C.int, bot: C.int) -> C.int {
	if top >= bot || bot > ml_line_count_b(buf) + 1 {
		return FAIL_R // rely on caller to do error messages
	}

	if top + 2 == bot {
		u_saveline(buf, top + 1)
	}

	return u_savecommon(buf, top, bot, 0, false)
}

@(export)
u_savesub :: proc "c" (lnum: C.int) -> C.int {
	return u_savecommon(curbuf, lnum - 1, lnum + 1, lnum + 1, false)
}

@(export)
u_inssub :: proc "c" (lnum: C.int) -> C.int {
	return u_savecommon(curbuf, lnum - 1, lnum, lnum + 1, false)
}

@(export)
u_savedel :: proc "c" (lnum: C.int, nlines: C.int) -> C.int {
	return u_savecommon(curbuf, lnum - 1, lnum + nlines,
		nlines == ml_line_count_b(curbuf) ? 2 : lnum, false)
}

/// Return true when undo is allowed.
@(export)
undo_allowed :: proc "c" (buf: rawptr) -> bool {
	// Don't allow changes when 'modifiable' is off.
	if !buf_bool_at(buf, B_P_MA) {
		emsg(e_modifiable)
		return false
	}

	// In the sandbox it's not allowed to change the text.
	if sandbox != 0 {
		emsg(e_sandbox)
		return false
	}

	// Don't allow changes while editing the cmdline.
	if textlock != 0 || expr_map_locked_r() {
		emsg(e_textlock)
		return false
	}

	return true
}

/// Common code for various ways to save text before a change.
@(export)
u_savecommon :: proc "c" (buf: rawptr, top: C.int, bot: C.int, newbot: C.int, reload: bool) -> C.int {
	if !reload {
		if !undo_allowed(buf) {
			return FAIL_R
		}

		// warn for read-only file before making the change
		if buf == curbuf {
			change_warning_r(buf, 0)
		}

		if bot > ml_line_count_b(buf) + 1 {
			emsg(cstring("E881: Line count changed unexpectedly"))
			return FAIL_R
		}
	}

	uep: ^U_Entry_T
	prev_uep: ^U_Entry_T
	size := bot - top - 1

	// If b_u_synced is true make a new header.
	if buf_bool_at(buf, B_U_SYNCED) {
		buf_set_bool(buf, B_NEW_CHANGE, true)

		uhp: ^U_Header_T
		if get_undolevel(buf) >= 0 {
			uhp = (^U_Header_T)(xmalloc(size_of(U_Header_T)))
			uhp^ = U_Header_T{}
		}

		// If we undid more than we redid, move the entry lists before and
		// including b_u_curhead to an alternate branch.
		old_curhead := buf_curhead(buf)
		if old_curhead != nil {
			buf_set_newhead(buf, uh_next_ptr(old_curhead))
			buf_set_curhead(buf, nil)
		}

		// free headers to keep the size right
		for C.int(buf_i64_at(buf, B_U_NUMHEAD)) > C.int(get_undolevel(buf)) && buf_oldhead(buf) != nil {
			uhfree := buf_oldhead(buf)

			if uhfree == old_curhead {
				// Can't reconnect the branch, delete all of it.
				u_freebranch(buf, uhfree, &old_curhead)
			} else if uh_alt_next_ptr(uhfree) == nil {
				// There is no branch, only free one header.
				u_freeheader(buf, uhfree, &old_curhead)
			} else {
				// Free the oldest alternate branch as a whole.
				for uh_alt_next_ptr(uhfree) != nil {
					uhfree = uh_alt_next_ptr(uhfree)
				}
				u_freebranch(buf, uhfree, &old_curhead)
			}
		}

		if uhp == nil { // no undo at all
			if old_curhead != nil {
				u_freebranch(buf, old_curhead, nil)
			}
			buf_set_bool(buf, B_U_SYNCED, false)
			return OK_R
		}

		uh_set_prev(uhp, nil)
		uh_set_next(uhp, buf_newhead(buf))
		uh_set_alt_next(uhp, old_curhead)
		if old_curhead != nil {
			uh_set_alt_prev(uhp, uh_alt_prev_ptr(old_curhead))

			if uh_alt_prev_ptr(uhp) != nil {
				uh_set_alt_next(uh_alt_prev_ptr(uhp), uhp)
			}

			uh_set_alt_prev(old_curhead, uhp)

			if buf_oldhead(buf) == old_curhead {
				buf_set_oldhead(buf, uhp)
			}
		} else {
			uh_set_alt_prev(uhp, nil)
		}

		if buf_newhead(buf) != nil {
			uh_set_prev(buf_newhead(buf), uhp)
		}

		seq_last_p := (^C.int)(uintptr(buf) + B_U_SEQ_LAST)
		seq_last_p^ += 1
		uhp.uh_seq = seq_last_p^
		buf_set_i32(buf, B_U_SEQ_CUR, uhp.uh_seq)
		uhp.uh_time = time_now()
		uhp.uh_save_nr = 0
		buf_set_i64(buf, B_U_TIME_CUR, i64(uhp.uh_time) + 1)

		uhp.uh_walk = 0
		uhp.uh_entry = nil
		uhp.uh_getbot_entry = nil
		uhp.uh_cursor = win_cursor_r(curwin)^ // save cursor pos. for undo
		if virtual_active_r(curwin) && win_cursor_r(curwin).coladd > 0 {
			uhp.uh_cursor_vcol = getviscol_r()
		} else {
			uhp.uh_cursor_vcol = -1
		}

		// save changed and buffer empty flag for undo
		uhp.uh_flags = (buf_bool_at(buf, B_CHANGED) ? UH_CHANGED : 0) +
			((buf_i32_at(buf, B_ML_FLAGS) & ML_EMPTY) != 0 ? UH_EMPTYBUF : 0)

		// save named marks and Visual marks for undo
		nm_dst := (^Fmark_T)(uintptr(buf) + B_NAMEDM)
		zero_fmark_additional_data(transmute([^]Fmark_T)(nm_dst))
		nm_src := (^Fmark_T)(uintptr(buf) + B_NAMEDM)
		libc.memmove(&uhp.uh_namedm[0], nm_src, size_of(Fmark_T) * NMARKS)
		vi_src := (^Visualinfo_T)(uintptr(buf) + B_VISUAL)
		uhp.uh_visual = vi_src^

		buf_set_newhead(buf, uhp)

		if buf_oldhead(buf) == nil {
			buf_set_oldhead(buf, uhp)
		}
		buf_set_i32(buf, B_U_NUMHEAD, buf_i32_at(buf, B_U_NUMHEAD) + 1)
	} else {
		if get_undolevel(buf) < 0 { // no undo at all
			return OK_R
		}

		// When saving a single line just saved, skip. Check ten last changes.
		if size == 1 {
			uep = u_get_headentry(buf)
			prev_uep = nil
			for i := 0; i < 10; i += 1 {
				if uep == nil {
					break
				}

				// If lines have been inserted/deleted we give up.
				getbot := (^U_Entry_T)(buf_ptr_at(buf_newhead(buf), 48)) // uh_getbot_entry
				bad := getbot != uep ? (uep.ue_top + uep.ue_size + 1 !=
					(uep.ue_bot == 0 ? ml_line_count_b(buf) + 1 : uep.ue_bot)) :
					(uep.ue_lcount != ml_line_count_b(buf))
				if bad || (uep.ue_size > 1 &&
					top >= uep.ue_top &&
					top + 2 <= uep.ue_top + uep.ue_size + 1) {
					break
				}

				// If it's the same line we can skip saving it again.
				if uep.ue_size == 1 && uep.ue_top == top {
					if i > 0 {
						// Get ue_bot for the last entry now.
						u_getbot(buf)
						buf_set_bool(buf, B_U_SYNCED, false)

						// Move found entry to become the last entry.
						prev_uep.ue_next = uep.ue_next
						uep.ue_next = buf_newhead(buf).uh_entry
						buf_newhead(buf).uh_entry = uep
					}

					// The executed command may change the line count.
					if newbot != 0 {
						uep.ue_bot = newbot
					} else if bot > ml_line_count_b(buf) {
						uep.ue_bot = 0
					} else {
						uep.ue_lcount = ml_line_count_b(buf)
						buf_newhead(buf).uh_getbot_entry = uep
					}
					return OK_R
				}
				prev_uep = uep
				uep = uep.ue_next
			}
		}

		// find line number for ue_bot for previous u_save()
		u_getbot(buf)
	}

	// add lines in front of entry list
	uep = (^U_Entry_T)(xmalloc(size_of(U_Entry_T)))
	uep^ = U_Entry_T{}

	uep.ue_size = size
	uep.ue_top = top
	if newbot != 0 {
		uep.ue_bot = newbot
	} else if bot > ml_line_count_b(buf) {
		uep.ue_bot = 0
	} else {
		uep.ue_lcount = ml_line_count_b(buf)
		buf_newhead(buf).uh_getbot_entry = uep
	}

	if size > 0 {
		uep.ue_array = (^^u8)(xmalloc(C.size_t(size) * size_of(^u8)))
		i: C.int = 0
		lnum := top + 1
		for i < size {
			fast_breakcheck()
			if got_int {
				u_freeentry(uep, i)
				return FAIL_R
			}
			(^^u8)(uintptr(uep.ue_array) + uintptr(i) * size_of(^u8))^ = u_save_line_buf(buf, lnum)
			lnum += 1
			i += 1
		}
	} else {
		uep.ue_array = nil
	}

	uep.ue_next = buf_newhead(buf).uh_entry
	buf_newhead(buf).uh_entry = uep
	if reload {
		// buffer was reloaded, notify text change subscribers
		buf_newhead(buf).uh_flags |= UH_RELOAD
	}
	buf_set_bool(buf, B_U_SYNCED, false)
	undo_undoes = false

	return OK_R
}

// helper to reach buf->b_namedm as slice base
uhp_namedm :: #force_inline proc "c"(b: rawptr) -> ^Fmark_T {
	return (^Fmark_T)(uintptr(b) + B_NAMEDM)
}
// [undo part 3: undofile name resolution, hash, serialize/unserialize, read/write]

// Compute the hash for a buffer text into hash[UNDO_HASH_SIZE].
@(export)
u_compute_hash :: proc "c" (buf: rawptr, hash: ^u8) {
	context = runtime.default_context()
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	for lnum: C.int = 1; lnum <= ml_line_count_b(buf); lnum += 1 {
		p := ml_get_buf(buf, lnum)
		plen := libc.strlen(transmute(cstring)(p)) + 1
		sha2.update(&ctx, mem_view(p, C.size_t(plen)))
	}
	dig: [32]u8
	sha2.final(&ctx, dig[:])
	libc.memcpy(hash, &dig[0], UNDO_HASH_SIZE)
}

// Odin helper: []byte view over raw pointer (slice header: {items:^u8, len:int})
@(private="file")
Slice_View :: struct {
	items: ^u8,
	len:   int,
}

mem_view :: #force_inline proc "c"(p: rawptr, n: C.size_t) -> []byte {
	return transmute([]byte)(Slice_View{items = (^u8)(p), len = int(n)})
}

/// Return an allocated string of the full path of the target undofile.
@(export)
u_get_undo_file_name :: proc "c" (buf_ffname: cstring, reading: bool) -> ^u8 {
	ffname := buf_ffname

	if ffname == nil {
		return nil
	}

	fname_buf: [4096]u8
	if resolve_symlink_r(ffname, &fname_buf[0]) == OK_R {
		ffname = transmute(cstring)(&fname_buf[0])
	}

	dir_name: [4097]u8
	munged_name := NvimString{}
	undo_file_name: ^u8

	ffname_len := libc.strlen(ffname)
	// Loop over 'undodir'. When reading find the first file that exists.
	dirp := p_udir
	for dirp^ != 0 {
		dir_len := copy_option_part(&dirp, &dir_name[0], 4096, cstring(","))
		if dir_len == 1 && dir_name[0] == '.' {
			// Use same directory as the ffname: "dir/name" -> "dir/.name.un~"
			undo_file_name = (^u8)(xmalloc(C.size_t(ffname_len) + 6))
			libc.memmove(undo_file_name, transmute(rawptr)(ffname), C.size_t(ffname_len) + 1)
			tail := path_tail_r(transmute(cstring)(undo_file_name))
			tail_len := C.size_t(ffname_len) - C.size_t(uintptr(tail) - uintptr(undo_file_name))
			libc.memmove((^u8)(uintptr(tail) + 1), tail, tail_len + 1)
			tail^ = '.'
			libc.memmove((^u8)(uintptr(tail) + uintptr(tail_len) + 1), transmute(rawptr)(cstring(".un~")), 5)
		} else {
			dir_name[dir_len] = 0

			// Remove trailing pathseps from directory name
			for dir_len > 1 && vim_ispathsep_nocolon(C.int(dir_name[dir_len - 1])) {
				dir_len -= 1
				dir_name[dir_len] = 0
			}

			has_directory := os_isdir(transmute(cstring)(&dir_name[0]))
			if !has_directory && dirp^ == 0 && !reading {
				// Last directory in list does not exist, create it.
				failed_dir_c: cstring
				ret := os_mkdir_recurse(transmute(cstring)(&dir_name[0]), 0o755, &failed_dir_c, nil)
				if ret != 0 {
					ebuf: [1025]u8
					n := libc.snprintf(&ebuf[0], size_of(ebuf),
						cstring("E5003: Unable to create directory \"%s\" for undo file: %s"),
						failed_dir_c, os_strerror(ret))
					ebuf[n if n >= 0 && n < 1024 else 1024] = 0
					emsg(transmute(cstring)(&ebuf[0]))
					xfree(transmute(rawptr)(failed_dir_c))
				} else {
					has_directory = true
				}
			}
			if has_directory {
				if munged_name.data == nil {
					munged_name = transmute(NvimString)(cbuf_to_string_r(ffname, C.size_t(ffname_len)))
					p := (^u8)(munged_name.data)
					for p^ != 0 {
						if vim_ispathsep_c(p^) {
							p^ = '%'
						}
						p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
					}
				}
				dn := NvimString{data = transmute(cstring)(&dir_name[0]), size = C.size_t(dir_len)}
				undo_file_name = (^u8)(concat_fnames_r(dn, munged_name, true).data)
			}
		}

		// When reading check if the file exists.
		if undo_file_name != nil && (!reading || os_path_exists(transmute(cstring)(undo_file_name))) {
			break
		}
		xfree(undo_file_name)
		undo_file_name = nil
	}

	xfree(transmute(rawptr)(munged_name.data))
	return undo_file_name
}

@(private="file")
vim_ispathsep_c :: proc "c"(c: u8) -> bool {
	// unix pathsep
	return c == '/'
}

/// Display an error for corrupted undo file
corruption_error :: proc "c" (mesg: cstring, file_name: cstring) {
	buf: [1025]u8
	n := libc.snprintf(&buf[0], size_of(buf), cstring("E825: Corrupted undo file (%s): %s"), mesg, file_name)
	buf[n if n >= 0 && n < 1024 else 1024] = 0
	emsg(transmute(cstring)(&buf[0]))
}

u_free_uhp :: proc "c" (uhp: ^U_Header_T) {
	uep := uhp.uh_entry
	for uep != nil {
		nuep := uep.ue_next
		u_freeentry(uep, uep.ue_size)
		uep = nuep
	}
	xfree(uhp)
}

// time_to_bytes: write time_t as 8 bytes big-endian (matches C inline in os/time.h)
time_to_bytes_od :: proc "c" (t: C.long, buf: [^]u8) {
	v := u64(t)
	for i := 0; i < 8; i += 1 {
		buf[i] = u8(v >> u32(56 - i * 8))
	}
}

// undo_write / undo_write_bytes / put_header_ptr
undo_write :: proc "c" (bi: ^Bufinfo_T, ptr: rawptr, len: C.size_t) -> bool {
	return libc.fwrite(ptr, len, 1, bi.bi_fp) == 1
}

undo_write_bytes :: proc "c" (bi: ^Bufinfo_T, nr: u64, len: C.size_t) -> bool {
	buf: [8]u8
	bufi: C.size_t = 0
	i := len - 1
	for bufi < len {
		buf[bufi] = u8(nr >> u32(i * 8))
		i -= 1
		bufi += 1
	}
	return undo_write(bi, &buf[0], len)
}

// correct put_header_ptr using full header offset
put_header_ptr_h :: proc "c" (bi: ^Bufinfo_T, uhp: ^U_Header_T) {
	seq := uhp != nil ? uhp.uh_seq : 0
	undo_write_bytes(bi, u64(seq), 4)
}

undo_read_4c_b :: proc "c" (bi: ^Bufinfo_T) -> C.int {
	return get4c_r(bi.bi_fp)
}

undo_read_2c_b :: proc "c" (bi: ^Bufinfo_T) -> C.int {
	return get2c_r(bi.bi_fp)
}

undo_read_byte_b :: proc "c" (bi: ^Bufinfo_T) -> C.int {
	return libc.fgetc(bi.bi_fp)
}

undo_read_time_b :: proc "c" (bi: ^Bufinfo_T) -> C.long {
	return get8ctime_r(bi.bi_fp)
}

undo_read :: proc "c" (bi: ^Bufinfo_T, buffer: rawptr, sz: C.size_t) -> bool {
	retval := libc.fread(buffer, sz, 1, bi.bi_fp) == 1
	if !retval {
		libc.memset(buffer, 0, sz)
	}
	return retval
}

undo_read_string :: proc "c" (bi: ^Bufinfo_T, len: C.size_t) -> ^u8 {
	ptr := xmallocz_r(len)
	if len > 0 && !undo_read(bi, ptr, len) {
		xfree(ptr)
		return nil
	}
	return ptr
}

serialize_pos_u :: proc "c" (bi: ^Bufinfo_T, pos: Pos_T) {
	undo_write_bytes(bi, u64(pos.lnum), 4)
	undo_write_bytes(bi, u64(pos.col), 4)
	undo_write_bytes(bi, u64(pos.coladd), 4)
}

unserialize_pos_u :: proc "c" (bi: ^Bufinfo_T, pos: ^Pos_T) {
	pos.lnum = max(undo_read_4c_b(bi), 0)
	pos.col = max(undo_read_4c_b(bi), 0)
	pos.coladd = max(undo_read_4c_b(bi), 0)
}

serialize_visualinfo_u :: proc "c" (bi: ^Bufinfo_T, info: ^Visualinfo_T) {
	serialize_pos_u(bi, info.vi_start)
	serialize_pos_u(bi, info.vi_end)
	undo_write_bytes(bi, u64(info.vi_mode), 4)
	undo_write_bytes(bi, u64(info.vi_curswant), 4)
}

unserialize_visualinfo_u :: proc "c" (bi: ^Bufinfo_T, info: ^Visualinfo_T) {
	unserialize_pos_u(bi, &info.vi_start)
	unserialize_pos_u(bi, &info.vi_end)
	info.vi_mode = undo_read_4c_b(bi)
	info.vi_curswant = undo_read_4c_b(bi)
}

/// Writes the undofile header.
serialize_header :: proc "c" (bi: ^Bufinfo_T, hash: ^u8) -> bool {
	buf := bi.bi_buf
	fp := bi.bi_fp

	if libc.fwrite(transmute(rawptr)(cstring(UF_START_MAGIC)), UF_START_MAGIC_LEN, 1, fp) != 1 {
		return false
	}

	undo_write_bytes(bi, UF_VERSION, 2)

	if !undo_write(bi, hash, UNDO_HASH_SIZE) {
		return false
	}

	undo_write_bytes(bi, u64(ml_line_count_b(buf)), 4)
	line_ptr := buf_ptr_at(buf, B_U_LINE_PTR)
	length: C.size_t = 0
	if line_ptr != nil {
		length = libc.strlen(transmute(cstring)(line_ptr))
	}
	undo_write_bytes(bi, u64(length), 4)
	if length > 0 && !undo_write(bi, line_ptr, length) {
		return false
	}
	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_LINE_LNUM)), 4)
	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_LINE_COLNR)), 4)

	put_header_ptr_h(bi, buf_oldhead(buf))
	put_header_ptr_h(bi, buf_newhead(buf))
	put_header_ptr_h(bi, buf_curhead(buf))

	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_NUMHEAD)), 4)
	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_SEQ_LAST)), 4)
	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_SEQ_CUR)), 4)
	time_buf: [8]u8
	time_to_bytes_od(C.long(buf_i64_at(buf, B_U_TIME_CUR)), &time_buf[0])
	undo_write(bi, &time_buf[0], 8)

	// Write optional fields.
	undo_write_bytes(bi, 4, 1)
	undo_write_bytes(bi, UF_LAST_SAVE_NR, 1)
	undo_write_bytes(bi, u64(buf_i32_at(buf, B_U_SAVE_NR_LAST)), 4)

	// Write end marker.
	undo_write_bytes(bi, 0, 1)

	return true
}

/// Writes an undo header.
serialize_uhp :: proc "c" (bi: ^Bufinfo_T, uhp: ^U_Header_T) -> bool {
	if !undo_write_bytes(bi, UF_HEADER_MAGIC, 2) {
		return false
	}

	put_header_ptr_h(bi, uh_next_ptr(uhp))
	put_header_ptr_h(bi, uh_prev_ptr(uhp))
	put_header_ptr_h(bi, uh_alt_next_ptr(uhp))
	put_header_ptr_h(bi, uh_alt_prev_ptr(uhp))
	undo_write_bytes(bi, u64(uhp.uh_seq), 4)
	serialize_pos_u(bi, uhp.uh_cursor)
	undo_write_bytes(bi, u64(uhp.uh_cursor_vcol), 4)
	undo_write_bytes(bi, u64(uhp.uh_flags), 2)
	for i := 0; i < NMARKS; i += 1 {
		serialize_pos_u(bi, uhp.uh_namedm[i].mark)
	}
	serialize_visualinfo_u(bi, &uhp.uh_visual)
	time_buf: [8]u8
	time_to_bytes_od(uhp.uh_time, &time_buf[0])
	undo_write(bi, &time_buf[0], 8)

	// Write optional fields.
	undo_write_bytes(bi, 4, 1)
	undo_write_bytes(bi, UHP_SAVE_NR, 1)
	undo_write_bytes(bi, u64(uhp.uh_save_nr), 4)

	// Write end marker.
	undo_write_bytes(bi, 0, 1)

	// Write all the entries.
	for uep := uhp.uh_entry; uep != nil; uep = uep.ue_next {
		undo_write_bytes(bi, UF_ENTRY_MAGIC, 2)
		if !serialize_uep(bi, uep) {
			return false
		}
	}
	undo_write_bytes(bi, UF_ENTRY_END_MAGIC, 2)

	// Write all extmark undo objects
	for i: C.size_t = 0; i < C.size_t(uhp.uh_extmark.n); i += 1 {
		ext := (^ExtmarkUndoObject)(uintptr(uhp.uh_extmark.items) + uintptr(i) * size_of(ExtmarkUndoObject))
		if !serialize_extmark(bi, ext) {
			return false
		}
	}
	undo_write_bytes(bi, UF_ENTRY_END_MAGIC, 2)

	return true
}

unserialize_uhp :: proc "c" (bi: ^Bufinfo_T, file_name: cstring) -> ^U_Header_T {
	uhp := (^U_Header_T)(xmalloc(size_of(U_Header_T)))
	uhp^ = U_Header_T{}

	// union fields hold sequence numbers while loading:
	(^C.int)(uintptr(&uhp.uh_next))^ = undo_read_4c_b(bi)
	(^C.int)(uintptr(&uhp.uh_prev))^ = undo_read_4c_b(bi)
	(^C.int)(uintptr(&uhp.uh_alt_next))^ = undo_read_4c_b(bi)
	(^C.int)(uintptr(&uhp.uh_alt_prev))^ = undo_read_4c_b(bi)
	uhp.uh_seq = undo_read_4c_b(bi)
	if uhp.uh_seq <= 0 {
		corruption_error(cstring("uh_seq"), file_name)
		xfree(uhp)
		return nil
	}
	unserialize_pos_u(bi, &uhp.uh_cursor)
	uhp.uh_cursor_vcol = undo_read_4c_b(bi)
	uhp.uh_flags = undo_read_2c_b(bi)
	cur_timestamp := os_time()
	for i := 0; i < NMARKS; i += 1 {
		unserialize_pos_u(bi, &uhp.uh_namedm[i].mark)
		uhp.uh_namedm[i].timestamp = cur_timestamp
		uhp.uh_namedm[i].fnum = 0
	}
	unserialize_visualinfo_u(bi, &uhp.uh_visual)
	uhp.uh_time = undo_read_time_b(bi)

	// Unserialize optional fields.
	for true {
		length := undo_read_byte_b(bi)

		if length == -1 { // EOF
			corruption_error(cstring("truncated"), file_name)
			u_free_uhp(uhp)
			return nil
		}
		if length == 0 {
			break
		}
		what := undo_read_byte_b(bi)
		switch what {
		case UHP_SAVE_NR:
			uhp.uh_save_nr = undo_read_4c_b(bi)
		case:
			// Field not supported, skip it.
			length -= 1
			for length >= 0 {
				undo_read_byte_b(bi)
				length -= 1
			}
		}
	}

	// Unserialize the uep list.
	last_uep: ^U_Entry_T = nil
	c := undo_read_2c_b(bi)
	for c == UF_ENTRY_MAGIC {
		error := false
		uep := unserialize_uep(bi, &error, file_name)
		if last_uep == nil {
			uhp.uh_entry = uep
		} else {
			last_uep.ue_next = uep
		}
		last_uep = uep
		if uep == nil || error {
			u_free_uhp(uhp)
			return nil
		}
		c = undo_read_2c_b(bi)
	}
	if c != UF_ENTRY_END_MAGIC {
		corruption_error(cstring("entry end"), file_name)
		u_free_uhp(uhp)
		return nil
	}

	// Unserialize all extmark undo information
	for c2 := undo_read_2c_b(bi); ; c2 = undo_read_2c_b(bi) {
		if c2 != UF_ENTRY_MAGIC {
			if c2 != UF_ENTRY_END_MAGIC {
				corruption_error(cstring("entry end"), file_name)
				u_free_uhp(uhp)
				return nil
			}
			break
		}
		error := false
		extup := unserialize_extmark(bi, &error, file_name)
		if error {
			xfree(extup)
			u_free_uhp(uhp)
			return nil
		}
		kv_push_xundo(&uhp.uh_extmark, extup^)
		xfree(extup)
	}

	return uhp
}

kv_push_xundo :: proc "c" (kv: ^Kvec_XUndo, v: ExtmarkUndoObject) {
	if kv.n == kv.a {
		newa: C.size_t = kv.a == 0 ? C.size_t(4) : kv.a * 2
		items := transmute(^ExtmarkUndoObject)(xrealloc(kv.items, newa * size_of(ExtmarkUndoObject)))
		kv.items = items
		kv.a = newa
	}
	(^ExtmarkUndoObject)(uintptr(kv.items) + uintptr(kv.n) * size_of(ExtmarkUndoObject))^ = v
	kv.n += 1
}

serialize_extmark :: proc "c" (bi: ^Bufinfo_T, extup: ^ExtmarkUndoObject) -> bool {
	if extup.type == kExtmarkSplice_U {
		undo_write_bytes(bi, UF_ENTRY_MAGIC, 2)
		undo_write_bytes(bi, u64(extup.type), 4)
		if !undo_write(bi, &extup.data, size_of(Extmark_Splice)) {
			return false
		}
	} else if extup.type == kExtmarkMove_U {
		undo_write_bytes(bi, UF_ENTRY_MAGIC, 2)
		undo_write_bytes(bi, u64(extup.type), 4)
		if !undo_write(bi, &extup.data, size_of(Extmark_Move)) {
			return false
		}
	}
	return true
}

unserialize_extmark :: proc "c" (bi: ^Bufinfo_T, error: ^bool, filename: cstring) -> ^ExtmarkUndoObject {
	buf: ^u8 = nil

	extup := (^ExtmarkUndoObject)(xmalloc(size_of(ExtmarkUndoObject)))

	typ := undo_read_4c_b(bi)
	extup.type = typ
	if typ == kExtmarkSplice_U {
		if !undo_read(bi, &extup.data, size_of(Extmark_Splice)) {
			goto_error_ext(error, extup, buf)
			return nil
		}
	} else if typ == kExtmarkMove_U {
		if !undo_read(bi, &extup.data, size_of(Extmark_Move)) {
			goto_error_ext(error, extup, buf)
			return nil
		}
	} else {
		goto_error_ext(error, extup, buf)
		return nil
	}

	xfree(buf)
	return extup
}

goto_error_ext :: proc "c" (error: ^bool, extup: ^ExtmarkUndoObject, buf: ^u8) {
	xfree(extup)
	if buf != nil {
		xfree(buf)
	}
	error^ = true
}

/// Serializes uep.
serialize_uep :: proc "c" (bi: ^Bufinfo_T, uep: ^U_Entry_T) -> bool {
	undo_write_bytes(bi, u64(uep.ue_top), 4)
	undo_write_bytes(bi, u64(uep.ue_bot), 4)
	undo_write_bytes(bi, u64(uep.ue_lcount), 4)
	undo_write_bytes(bi, u64(uep.ue_size), 4)

	for i: C.size_t = 0; i < C.size_t(uep.ue_size); i += 1 {
		line := (^^u8)(uintptr(uep.ue_array) + uintptr(i) * size_of(^u8))^
		length := libc.strlen(transmute(cstring)(line))
		if !undo_write_bytes(bi, u64(length), 4) {
			return false
		}
		if length > 0 && !undo_write(bi, line, length) {
			return false
		}
	}
	return true
}

unserialize_uep :: proc "c" (bi: ^Bufinfo_T, error: ^bool, file_name: cstring) -> ^U_Entry_T {
	uep := (^U_Entry_T)(xmalloc(size_of(U_Entry_T)))
	uep^ = U_Entry_T{}
	uep.ue_top = undo_read_4c_b(bi)
	uep.ue_bot = undo_read_4c_b(bi)
	uep.ue_lcount = undo_read_4c_b(bi)
	uep.ue_size = undo_read_4c_b(bi)

	array: ^^u8 = nil
	if uep.ue_size > 0 {
		array = (^^u8)(xmalloc(C.size_t(uep.ue_size) * size_of(^u8)))
		libc.memset(array, 0, C.size_t(uep.ue_size) * size_of(^u8))
	}
	uep.ue_array = array

	for i: C.size_t = 0; i < C.size_t(uep.ue_size); i += 1 {
		line_len := undo_read_4c_b(bi)
		line: ^u8
		if line_len >= 0 {
			line = undo_read_string(bi, C.size_t(line_len))
		} else {
			line = nil
			corruption_error(cstring("line length"), file_name)
		}
		if line == nil {
			error^ = true
			return uep
		}
		(^^u8)(uintptr(array) + uintptr(i) * size_of(^u8))^ = line
	}
	return uep
}
// [undo part 4: undo file read/write]


foreign _ {
	@(link_name = "fdopen")
	fdopen_r :: proc "c" (fd: C.int, mode: cstring) -> ^libc.FILE ---
	@(link_name = "getuid")
	getuid_r :: proc "c" () -> C.int ---
}

// table entry accessor
@(private="file")
uht_at :: #force_inline proc "c"(t: ^^U_Header_T, i: C.int) -> ^U_Header_T {
	return (^^U_Header_T)(uintptr(t) + uintptr(i) * size_of(^U_Header_T))^
}

// Write the undo tree in an undo file.
@(export)
u_write_undo :: proc "c" (name: cstring, forceit: bool, buf: rawptr, hash: ^u8) {
	fp: ^libc.FILE = nil
	write_ok := false
	file_name: ^u8

	if name == nil {
		ffname := (^u8)(buf_ptr_at(buf, B_FFNAME))
		file_name = u_get_undo_file_name(transmute(cstring)(ffname), false)
		if file_name == nil {
			return
		}
	} else {
		file_name = transmute(^u8)(name)
	}

	perm: C.int = 0o600
	ffname := buf_ptr_at(buf, B_FFNAME)
	if ffname != nil {
		perm = os_getperm(transmute(cstring)(ffname))
		if perm < 0 {
			perm = 0o600
		}
	}
	perm = perm & 0o666

	flow: {
		// If the undo file already exists, verify that it is one; delete it.
		if os_path_exists(transmute(cstring)(file_name)) {
			if name == nil || !forceit {
				fd := os_open(transmute(cstring)(file_name), 0, 0) // O_RDONLY
				if fd < 0 {
					break flow
				}
				mbuf: [UF_START_MAGIC_LEN]u8
				length := read_eintr_r(fd, &mbuf[0], UF_START_MAGIC_LEN)
				os_close(fd)
				if length < UF_START_MAGIC_LEN ||
					libcmemcmp(&mbuf[0], transmute(rawptr)(cstring(UF_START_MAGIC)), UF_START_MAGIC_LEN) != 0 {
					break flow
				}
			}
			os_remove(transmute(cstring)(file_name))
		}

		// No undo information at all.
		if buf_i32_at(buf, B_U_NUMHEAD) == 0 && buf_ptr_at(buf, B_U_LINE_PTR) == nil {
			break flow
		}

		O_CREAT :: 0o100
		O_WRONLY :: 1
		O_EXCL :: 0o200
		O_NOFOLLOW :: 0o400000
		fd := os_open(transmute(cstring)(file_name), O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, perm)
		if fd < 0 {
			semsg_u(e_not_open_u, file_name)
			break flow
		}
		os_setperm(transmute(cstring)(file_name), perm)

		// UNIX: try to set group same as original file.
		if ffname != nil {
			fi_old: FileInfo
			fi_new: FileInfo
			if os_fileinfo(transmute(cstring)(ffname), &fi_old) && os_fileinfo(transmute(cstring)(file_name), &fi_new) &&
				fi_old.stat.st_gid != fi_new.stat.st_gid &&
				os_fchown(fd, -1, C.int(fi_old.stat.st_gid)) == 0 {
				os_setperm(transmute(cstring)(file_name), (perm & 0o707) | ((perm & 0o07) << 3))
			}
		}

		fp = fdopen_r(fd, cstring("w"))
		if fp == nil {
			semsg_u(e_not_open_u, file_name)
			os_close(fd)
			os_remove(transmute(cstring)(file_name))
			break flow
		}

		// Undo must be synced.
		u_sync(true)

		bi := Bufinfo_T{bi_buf = buf, bi_fp = fp}

		ser: {
			if !serialize_header(&bi, hash) {
				break ser
			}

			lastmark += 1
			mark := lastmark
			uhp := buf_oldhead(buf)
			for uhp != nil {
				if uhp.uh_walk != mark {
					uhp.uh_walk = mark
					if !serialize_uhp(&bi, uhp) {
						break ser
					}
				}

				if uh_prev_ptr(uhp) != nil && uh_prev_ptr(uhp).uh_walk != mark {
					uhp = uh_prev_ptr(uhp)
				} else if uh_alt_next_ptr(uhp) != nil && uh_alt_next_ptr(uhp).uh_walk != mark {
					uhp = uh_alt_next_ptr(uhp)
				} else if uh_next_ptr(uhp) != nil && uh_alt_prev_ptr(uhp) == nil &&
					uh_next_ptr(uhp).uh_walk != mark {
					uhp = uh_next_ptr(uhp)
				} else if uh_alt_prev_ptr(uhp) != nil {
					uhp = uh_alt_prev_ptr(uhp)
				} else {
					uhp = uh_next_ptr(uhp)
				}
			}

			if undo_write_bytes(&bi, UF_HEADER_END_MAGIC, 2) {
				write_ok = true
			}

			b_p_fs_v := buf_i64_at(buf, B_P_FS)
			fs_on := b_p_fs_v >= 0 ? b_p_fs_v : i64(p_fs)
			if fs_on != 0 && libc.fflush(fp) == 0 && os_fsync(fd) != 0 {
				write_ok = false
			}
		}

		libc.fclose(fp)
		fp = nil

		if !write_ok {
			semsg_u(e_write_error_undofile, file_name)
		}
	} // flow

	if file_name != transmute(^u8)(name) {
		xfree(file_name)
	}
}

libcmemcmp :: proc "c" (a, b: rawptr, n: C.size_t) -> C.int {
	return libc.memcmp(a, b, n)
}

semsg_u :: proc "c" (fmt: cstring, arg: rawptr) {
	buf: [1025]u8
	n := libc.snprintf(&buf[0], size_of(buf), fmt, arg)
	buf[n if n >= 0 && n < 1024 else 1024] = 0
	emsg(transmute(cstring)(&buf[0]))
}

smsg_keep_u :: proc "c" (fmt: cstring, arg: rawptr) {
	buf: [1025]u8
	n := libc.snprintf(&buf[0], size_of(buf), fmt, arg)
	buf[n if n >= 0 && n < 1024 else 1024] = 0
	msg_keep_r(transmute(cstring)(&buf[0]), 0, true, false)
}

/// Loads the undo tree from an undo file.
@(export)
u_read_undo :: proc "c" (name: ^u8, hash: ^u8, orig_name: cstring) {
	uhp_table: ^^U_Header_T = nil
	line_ptr: ^u8 = nil
	num_read_uhps: C.int = 0

	file_name: ^u8
	if name == nil {
		ffname := (^u8)(buf_ptr_at(curbuf, B_FFNAME))
		file_name = u_get_undo_file_name(transmute(cstring)(ffname), true)
		if file_name == nil {
			return
		}

		// Only read if undo file owner matches text owner or current user.
		fi_orig: FileInfo
		fi_undo: FileInfo
		if os_fileinfo(orig_name, &fi_orig) && os_fileinfo(transmute(cstring)(file_name), &fi_undo) &&
			fi_orig.stat.st_uid != fi_undo.stat.st_uid && fi_undo.stat.st_uid != u64(getuid_r()) {
			xfree(file_name)
			return
		}
	} else {
		file_name = name
	}

	fp := libc.fopen(transmute(cstring)(file_name), cstring("r"))
	err := false

	body: {
		if fp == nil {
			if name != nil || p_verbose > 0 {
				semsg_u(cstring("E822: Cannot open undo file for reading: %s"), file_name)
			}
			err = true
			break body
		}

		bi := Bufinfo_T{bi_buf = curbuf, bi_fp = fp}

		magic_buf: [UF_START_MAGIC_LEN]u8
		if libc.fread(&magic_buf[0], UF_START_MAGIC_LEN, 1, fp) != 1 ||
			libcmemcmp(&magic_buf[0], transmute(rawptr)(cstring(UF_START_MAGIC)), UF_START_MAGIC_LEN) != 0 {
			semsg_u(cstring("E823: Not an undo file: %s"), file_name)
			err = true
			break body
		}
		version := get2c_r(fp)
		if version != UF_VERSION {
			semsg_u(cstring("E824: Incompatible undo file: %s"), file_name)
			err = true
			break body
		}

		read_hash: [UNDO_HASH_SIZE]u8
		if !undo_read(&bi, &read_hash[0], UNDO_HASH_SIZE) {
			corruption_error(cstring("hash"), transmute(cstring)(file_name))
			err = true
			break body
		}
		line_count := undo_read_4c_b(&bi)
		if libcmemcmp(hash, &read_hash[0], UNDO_HASH_SIZE) != 0 ||
			line_count != ml_line_count_b(curbuf) {
			give_warning_r(cstring("File contents changed, cannot use undo info"), true, true)
			err = true
			break body
		}

		// Read undo data for "U" command.
		str_len := undo_read_4c_b(&bi)
		if str_len < 0 {
			err = true
			break body
		}
		if str_len > 0 {
			line_ptr = undo_read_string(&bi, C.size_t(str_len))
		}
		line_lnum := undo_read_4c_b(&bi)
		line_colnr := undo_read_4c_b(&bi)
		if line_lnum < 0 || line_colnr < 0 {
			corruption_error(cstring("line lnum/col"), transmute(cstring)(file_name))
			err = true
			break body
		}

		old_header_seq := undo_read_4c_b(&bi)
		new_header_seq := undo_read_4c_b(&bi)
		cur_header_seq := undo_read_4c_b(&bi)
		num_head := undo_read_4c_b(&bi)
		seq_last := undo_read_4c_b(&bi)
		seq_cur := undo_read_4c_b(&bi)
		seq_time := undo_read_time_b(&bi)

		// Optional header fields.
		last_save_nr: C.int = 0
		for true {
			length := undo_read_byte_b(&bi)
			if length == 0 || length == -1 {
				break
			}
			what := undo_read_byte_b(&bi)
			switch what {
			case UF_LAST_SAVE_NR:
				last_save_nr = undo_read_4c_b(&bi)
			case:
				length -= 1
				for length >= 0 {
					undo_read_byte_b(&bi)
					length -= 1
				}
			}
		}

		if num_head > 0 {
			uhp_table = (^^U_Header_T)(xmalloc(C.size_t(num_head) * size_of(^U_Header_T)))
			libc.memset(uhp_table, 0, C.size_t(num_head) * size_of(^U_Header_T))
		}

		c := undo_read_2c_b(&bi)
		for c == UF_HEADER_MAGIC {
			if num_read_uhps >= num_head {
				corruption_error(cstring("num_head too small"), transmute(cstring)(file_name))
				err = true
				break body
			}
			uhp := unserialize_uhp(&bi, transmute(cstring)(file_name))
			if uhp == nil {
				err = true
				break body
			}
			(^^U_Header_T)(uintptr(uhp_table) + uintptr(num_read_uhps) * size_of(^U_Header_T))^ = uhp
			num_read_uhps += 1
			c = undo_read_2c_b(&bi)
		}
		if num_read_uhps != num_head {
			corruption_error(cstring("num_head"), transmute(cstring)(file_name))
			err = true
			break body
		}
		if c != UF_HEADER_END_MAGIC {
			corruption_error(cstring("end marker"), transmute(cstring)(file_name))
			err = true
			break body
		}

		// Swizzle seq numbers into pointers.
		old_idx, new_idx, cur_idx := i32(-1), i32(-1), i32(-1)
		for i: C.int = 0; i < num_head; i += 1 {
			uhp := uht_at(uhp_table, i)
			if uhp == nil {
				continue
			}
			for j: C.int = 0; j < num_head; j += 1 {
				uj := uht_at(uhp_table, j)
				if uj != nil && i != j && uhp.uh_seq == uj.uh_seq {
					corruption_error(cstring("duplicate uh_seq"), transmute(cstring)(file_name))
					err = true
					break body
				}
			}
			// swizzle each union field: seq -> pointer
			swz: [4]uintptr = {0, 8, 16, 24}
			for k := 0; k < 4; k += 1 {
				fieldp := uintptr(uhp) + uintptr(swz[k])
				seq := (^C.int)(fieldp)^
				(^rawptr)(fieldp)^ = nil
				for j: C.int = 0; j < num_head; j += 1 {
					uj := uht_at(uhp_table, C.int(j))
					if uj != nil && i != C.int(j) && uj.uh_seq == seq {
						(^rawptr)(fieldp)^ = uj
						break
					}
				}
			}
			if old_header_seq > 0 && old_idx < 0 && uhp.uh_seq == old_header_seq {
				old_idx = i32(i)
			}
			if new_header_seq > 0 && new_idx < 0 && uhp.uh_seq == new_header_seq {
				new_idx = i32(i)
			}
			if cur_header_seq > 0 && cur_idx < 0 && uhp.uh_seq == cur_header_seq {
				cur_idx = i32(i)
			}
		}

		// Use info from the file.
		u_blockfree(curbuf)
		buf_set_oldhead(curbuf, old_idx < 0 ? nil : uht_at(uhp_table, C.int(old_idx)))
		buf_set_newhead(curbuf, new_idx < 0 ? nil : uht_at(uhp_table, C.int(new_idx)))
		buf_set_curhead(curbuf, cur_idx < 0 ? nil : uht_at(uhp_table, C.int(cur_idx)))
		(^rawptr)(uintptr(curbuf) + B_U_LINE_PTR)^ = line_ptr
		buf_set_i32(curbuf, B_U_LINE_LNUM, line_lnum)
		buf_set_i32(curbuf, B_U_LINE_COLNR, line_colnr)
		buf_set_i32(curbuf, B_U_NUMHEAD, num_head)
		buf_set_i32(curbuf, B_U_SEQ_LAST, seq_last)
		buf_set_i32(curbuf, B_U_SEQ_CUR, seq_cur)
		buf_set_i64(curbuf, B_U_TIME_CUR, i64(seq_time))
		buf_set_i32(curbuf, B_U_SAVE_NR_LAST, last_save_nr)
		buf_set_i32(curbuf, B_U_SAVE_NR_CUR, last_save_nr)

		buf_set_bool(curbuf, B_U_SYNCED, true)
		xfree(uhp_table)
		uhp_table = nil // success: error path must not free it again

		if name != nil {
			smsg_keep_u(cstring("Finished reading undo file %s"), file_name)
		}
	} // body

	if err {
		xfree(line_ptr)
		if uhp_table != nil {
			for i: C.int = 0; i < num_read_uhps; i += 1 {
				uhpi := uht_at(uhp_table, i)
				if uhpi != nil {
					u_free_uhp(uhpi)
				}
			}
			xfree(uhp_table)
		}
	}

	if fp != nil {
		libc.fclose(fp)
	}
	if file_name != name {
		xfree(file_name)
	}
}
// [undo part 5: u_undo/u_doit/undo_time/u_undoredo/u_undo_end, ex_*/f_* funcs]


W_P_COLE :: 1144
B_NEXT :: 120
BL_SOL_FIX :: BL_SOL | BL_FIX

foreign _ {
	@(link_name = "VIsual")
	VIsual_g: Pos_T

	@(link_name = "firstbuf")
	firstbuf: rawptr

	@(link_name = "check_pos")
	check_pos_r :: proc "c" (buf: rawptr, pos: ^Pos_T) ---
}

// ── u_undo / u_redo / u_undo_and_forget ──────────────────────────────────────

@(export)
u_undo :: proc "c" (count_arg: C.int) -> bool {
	count := count_arg
	// If we get an undo command while executing a macro, behave like vi.
	if !buf_bool_at(curbuf, B_U_SYNCED) {
		u_sync(true)
		count = 1
	}

	if _vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_UNDO_CH)) == nil {
		undo_undoes = true
	} else {
		undo_undoes = !undo_undoes
	}
	u_doit(count, false, true)
	return true // unused; kept for symmetry
}

CPO_UNDO_CH :: 'u'

@(export)
u_redo :: proc "c" (count: C.int) {
	if _vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_UNDO_CH)) == nil {
		undo_undoes = false
	}
	u_doit(count, false, true)
}

/// Undo and remove the branch from the undo tree.
@(export)
u_undo_and_forget :: proc "c" (count_arg: C.int, do_buf_event: bool) -> bool {
	count := count_arg
	if buf_bool_at(curbuf, B_U_SYNCED) == false {
		u_sync(true)
		count = 1
	}
	undo_undoes = true
	u_doit(count, true, do_buf_event)

	if buf_curhead(curbuf) == nil {
		return false // nothing was undone
	}

	to_forget := buf_curhead(curbuf)
	buf_set_newhead(curbuf, uh_next_ptr(to_forget))
	buf_set_curhead(curbuf, uh_alt_next_ptr(to_forget))
	if buf_curhead(curbuf) != nil {
		uh_set_alt_next(to_forget, nil)
		uh_set_alt_prev(buf_curhead(curbuf), uh_alt_prev_ptr(to_forget))
		nx := uh_next_ptr(buf_curhead(curbuf))
		buf_set_i32(curbuf, B_U_SEQ_CUR, nx != nil ? nx.uh_seq : 0)
	} else if buf_newhead(curbuf) != nil {
		buf_set_i32(curbuf, B_U_SEQ_CUR, buf_newhead(curbuf).uh_seq)
	}
	if uh_alt_prev_ptr(to_forget) != nil {
		uh_set_alt_next(uh_alt_prev_ptr(to_forget), buf_curhead(curbuf))
	}
	if buf_newhead(curbuf) != nil {
		uh_set_prev(buf_newhead(curbuf), buf_curhead(curbuf))
	}
	if buf_i32_at(curbuf, B_U_SEQ_LAST) == to_forget.uh_seq {
		buf_set_i32(curbuf, B_U_SEQ_LAST, buf_i32_at(curbuf, B_U_SEQ_LAST) - 1)
	}
	u_freebranch(curbuf, to_forget, nil)
	return true
}

/// Undo or redo, depending on undo_undoes, count times.
u_doit :: proc "c" (startcount: C.int, quiet: bool, do_buf_event: bool) {
	if !undo_allowed(curbuf) {
		return
	}

	u_newcount = 0
	u_oldcount = 0
	if (buf_i32_at(curbuf, B_ML_FLAGS) & ML_EMPTY) != 0 {
		u_oldcount = -1
	}

	msg_ext_set_kind(cstring("undo"))
	count := startcount
	for count > 0 {
		count -= 1
		// Do the change warning now (may reload the buffer).
		change_warning_r(curbuf, 0)

		if undo_undoes {
			if buf_curhead(curbuf) == nil { // first undo
				buf_set_curhead(curbuf, buf_newhead(curbuf))
			} else if get_undolevel(curbuf) > 0 { // multi level undo
				buf_set_curhead(curbuf, uh_next_ptr(buf_curhead(curbuf)))
			}
			// nothing to undo
			if buf_i32_at(curbuf, B_U_NUMHEAD) == 0 || buf_curhead(curbuf) == nil {
				buf_set_curhead(curbuf, buf_oldhead(curbuf))
				beep_flush_r()
				if count == startcount - 1 {
					if !shortmess(SHM_UNDO_CH) {
						msg_msg(_t(cstring("Already at oldest change")), 0)
					}
					return
				}
				break
			}

			u_undoredo(true, do_buf_event)
		} else {
			if buf_curhead(curbuf) == nil || get_undolevel(curbuf) <= 0 {
				beep_flush_r() // nothing to redo
				if count == startcount - 1 {
					if !shortmess(SHM_UNDO_CH) {
						msg_msg(_t(cstring("Already at newest change")), 0)
					}
					return
				}
				break
			}

			u_undoredo(false, do_buf_event)

			// Advance for next redo.
			if uh_prev_ptr(buf_curhead(curbuf)) == nil {
				buf_set_newhead(curbuf, buf_curhead(curbuf))
			}
			buf_set_curhead(curbuf, uh_prev_ptr(buf_curhead(curbuf)))
		}
	}
	u_undo_end(undo_undoes, false, quiet)
}

// ── undo_time ────────────────────────────────────────────────────────────────

/// Undo or redo over the timeline. (:undo N / :earlier / :later)
@(export)
undo_time :: proc "c" (step: C.int, sec: bool, file: bool, absolute: bool) {
	if text_locked_r() {
		text_locked_msg_r()
		return
	}

	// Make sure the current undoable change is synced.
	if !buf_bool_at(curbuf, B_U_SYNCED) {
		u_sync(true)
	}

	u_newcount = 0
	u_oldcount = 0
	if (buf_i32_at(curbuf, B_ML_FLAGS) & ML_EMPTY) != 0 {
		u_oldcount = -1
	}

	target: C.int
	closest: C.int
	uhp: ^U_Header_T = nil
	dosec := sec
	dofile := file
	above := false
	did_undo := true

	if absolute {
		target = step
		closest = -1
	} else {
		if dosec {
			target = C.int(buf_i64_at(curbuf, B_U_TIME_CUR)) + step
		} else if dofile {
			if step < 0 {
				// Going back to previous write.
				uhp = buf_curhead(curbuf)
				if uhp != nil {
					uhp = uh_next_ptr(uhp)
				} else {
					uhp = buf_newhead(curbuf)
				}
				if uhp != nil && uhp.uh_save_nr != 0 {
					target = buf_i32_at(curbuf, B_U_SAVE_NR_CUR) + step
				} else {
					target = buf_i32_at(curbuf, B_U_SAVE_NR_CUR) + step + 1
				}
				if target <= 0 {
					dofile = false
				}
			} else {
				target = buf_i32_at(curbuf, B_U_SAVE_NR_CUR) + step
				if target > buf_i32_at(curbuf, B_U_SAVE_NR_LAST) {
					target = buf_i32_at(curbuf, B_U_SEQ_LAST) + 1
					dofile = false
				}
			}
		} else {
			target = buf_i32_at(curbuf, B_U_SEQ_CUR) + step
		}
		if step < 0 {
			target = max(target, 0)
			closest = -1
		} else {
			if dosec {
				closest = C.int(time_now() + 1)
			} else if dofile {
				closest = buf_i32_at(curbuf, B_U_SAVE_NR_LAST) + 2
			} else {
				closest = buf_i32_at(curbuf, B_U_SEQ_LAST) + 2
			}
			if target >= closest {
				target = closest - 1
			}
		}
	}
	closest_start := closest
	closest_seq := buf_i32_at(curbuf, B_U_SEQ_CUR)
	mark: C.int
	nomark: C.int = 0

	at_zero := target == 0

	if !at_zero {
		// May do this twice: search for target, then for closest.
		for round := 1; round <= 2; round += 1 {
			mark = lastmark + 1
			lastmark += 1
			nomark = lastmark + 1
			lastmark += 1

			if buf_curhead(curbuf) == nil { // at leaf of the tree
				uhp = buf_newhead(curbuf)
			} else {
				uhp = buf_curhead(curbuf)
			}

			for uhp != nil {
				uhp.uh_walk = mark
				val := dosec ? C.int(uhp.uh_time) : dofile ? uhp.uh_save_nr : uhp.uh_seq

				if round == 1 && !(dofile && val == 0) {
					// Remember header closest to the target.
					dir_ok := step < 0 ? uhp.uh_seq <= buf_i32_at(curbuf, B_U_SEQ_CUR) : uhp.uh_seq > buf_i32_at(curbuf, B_U_SEQ_CUR)
					better := false
					if dir_ok {
						if dosec && val == closest {
							better = step < 0 ? uhp.uh_seq < closest_seq : uhp.uh_seq > closest_seq
						} else {
							if closest == closest_start {
								better = true
							} else if val > target {
								better = closest > target ? val-target <= closest-target : val-target <= target-closest
							} else {
								better = closest > target ? target-val <= closest-target : target-val <= target-closest
							}
						}
					}
					if better {
						closest = val
						closest_seq = uhp.uh_seq
					}
				}

				// Found a match?
				if target == val && !dosec {
					target = uhp.uh_seq
					break
				}

				// walk the tree
				if uh_prev_ptr(uhp) != nil && uh_prev_ptr(uhp).uh_walk != nomark &&
					uh_prev_ptr(uhp).uh_walk != mark {
					uhp = uh_prev_ptr(uhp)
				} else if uh_alt_next_ptr(uhp) != nil &&
					uh_alt_next_ptr(uhp).uh_walk != nomark &&
					uh_alt_next_ptr(uhp).uh_walk != mark {
					uhp = uh_alt_next_ptr(uhp)
				} else if uh_next_ptr(uhp) != nil && uh_alt_prev_ptr(uhp) == nil &&
					uh_next_ptr(uhp).uh_walk != nomark &&
					uh_next_ptr(uhp).uh_walk != mark {
					if uhp == buf_curhead(curbuf) {
						uhp.uh_walk = nomark
					}
					uhp = uh_next_ptr(uhp)
				} else {
					// backtrack
					uhp.uh_walk = nomark
					if uh_alt_prev_ptr(uhp) != nil {
						uhp = uh_alt_prev_ptr(uhp)
					} else {
						uhp = uh_next_ptr(uhp)
					}
				}
			}

			if uhp != nil { // found it
				break
			}

			if absolute {
				ebuf: [64]u8
				n := libc.snprintf(&ebuf[0], size_of(ebuf), cstring("E830: Undo number %ld not found"), C.long(step))
				ebuf[n if n >= 0 && n < 63 else 63] = 0
				emsg(transmute(cstring)(&ebuf[0]))
				return
			}

			if closest == closest_start {
				if !shortmess(SHM_UNDO_CH) {
					if step < 0 {
						msg_msg(_t(cstring("Already at oldest change")), 0)
					} else {
						msg_msg(_t(cstring("Already at newest change")), 0)
					}
				}
				return
			}

			target = closest_seq
			dosec = false
			dofile = false
			if step < 0 {
				above = true
			}
		}
	}

	// If we found it: follow the path to go where we want to be.
	if uhp != nil || at_zero {
		// First go up the tree as much as needed.
		for !got_int {
			change_warning_r(curbuf, 0)

			uhp = buf_curhead(curbuf)
			if uhp == nil {
				uhp = buf_newhead(curbuf)
			} else {
				uhp = uh_next_ptr(uhp)
			}
			if uhp == nil ||
				(target > 0 && uhp.uh_walk != mark) ||
				(uhp.uh_seq == target && !above) {
				break
			}
			buf_set_curhead(curbuf, uhp)
			u_undoredo(true, true)
			if target > 0 {
				uhp.uh_walk = nomark // don't go back down here
			}
		}

		// When back to origin, redo is not needed.
		if target > 0 {
			// Go down the tree (redo), branching off where needed.
			for !got_int {
				change_warning_r(curbuf, 0)

				uhp = buf_curhead(curbuf)
				if uhp == nil {
					break
				}

				// Go back to first branch with a mark.
				for uh_alt_prev_ptr(uhp) != nil && uh_alt_prev_ptr(uhp).uh_walk == mark {
					uhp = uh_alt_prev_ptr(uhp)
				}

				// Find the last branch with a mark, that's the one.
				last := uhp
				for uh_alt_next_ptr(last) != nil && uh_alt_next_ptr(last).uh_walk == mark {
					last = uh_alt_next_ptr(last)
				}
				if last != uhp {
					// Make used branch first in the alternatives list.
					for uh_alt_prev_ptr(uhp) != nil {
						uhp = uh_alt_prev_ptr(uhp)
					}
					if uh_alt_next_ptr(last) != nil {
						uh_set_alt_prev(uh_alt_next_ptr(last), uh_alt_prev_ptr(last))
					}
					uh_set_alt_next(uh_alt_prev_ptr(last), uh_alt_next_ptr(last))
					uh_set_alt_prev(last, nil)
					uh_set_alt_next(last, uhp)
					uh_set_alt_prev(uhp, last)

					if buf_oldhead(curbuf) == uhp {
						buf_set_oldhead(curbuf, last)
					}
					uhp = last
					if uh_next_ptr(uhp) != nil {
						uh_set_prev(uh_next_ptr(uhp), uhp)
					}
				}
				buf_set_curhead(curbuf, uhp)

				if uhp.uh_walk != mark {
					break // must have reached the target
				}

				// Stop when going backwards and didn't find exact header.
				if uhp.uh_seq == target && above {
					buf_set_i32(curbuf, B_U_SEQ_CUR, target - 1)
					break
				}

				u_undoredo(false, true)

				// Advance curhead below the header we last used.
				if uh_prev_ptr(uhp) == nil {
					buf_set_newhead(curbuf, uhp)
				}
				buf_set_curhead(curbuf, uh_prev_ptr(uhp))
				did_undo = false

				if uhp.uh_seq == target { // found it!
					break
				}

				uhp = uh_prev_ptr(uhp)
				if uhp == nil || uhp.uh_walk != mark {
					iemsg_r(cstring("E838: internal error: undo_time()"))
					break
				}
			}
		}
	}
	u_undo_end(did_undo, absolute, false)
}
// [undo part 6: u_undoredo, u_undo_end, u_sync, ex_*/f_*, free/clear family]


W_BUFFER_M :: W_BUFFER // alias (already public from mark.odin)

/// u_undoredo: common code for undo and redo
u_undoredo :: proc "c" (undo: bool, do_buf_event: bool) {
	newarray: ^^u8 = nil
	newlnum: C.int = MAXLNUM
	new_curpos := win_cursor_r(curwin)^
	newlist: ^U_Entry_T = nil
	namedm: [NMARKS]Fmark_T
	curhead := buf_curhead(curbuf)

	// Don't want autocommands using the undo structures here.
	block_autocmds_r()

	old_flags := curhead.uh_flags
	new_flags := (buf_bool_at(curbuf, B_CHANGED) ? UH_CHANGED : 0) |
		((buf_i32_at(curbuf, B_ML_FLAGS) & ML_EMPTY) != 0 ? UH_EMPTYBUF : 0) |
		(old_flags & UH_RELOAD)
	setpcmark()

	// save marks before undo/redo
	zero_fmark_additional_data(uhp_namedm(curbuf))
	libc.memmove(&namedm[0], uhp_namedm(curbuf), size_of(Fmark_T) * NMARKS)
	visualinfo := (^Visualinfo_T)(uintptr(curbuf) + B_VISUAL)^
	get_pos_r2(curbuf, B_OP_START).lnum = ml_line_count_b(curbuf)
	get_pos_r2(curbuf, B_OP_START).col = 0
	get_pos_r2(curbuf, B_OP_END).lnum = 0
	get_pos_r2(curbuf, B_OP_END).col = 0

	uep := curhead.uh_entry
	for uep != nil {
		nuep := uep.ue_next
		top := uep.ue_top
		bot := uep.ue_bot
		if bot == 0 {
			bot = ml_line_count_b(curbuf) + 1
		}
		if top > ml_line_count_b(curbuf) || top >= bot ||
			bot > ml_line_count_b(curbuf) + 1 {
			unblock_autocmds_r()
			iemsg_r(cstring("E438: u_undo: line numbers wrong"))
			changed_r(curbuf)
			return
		}

		oldsize := bot - top - 1 // number of lines before undo
		newsize := uep.ue_size   // number of lines after undo

		// Decide about the cursor position.
		{
			lnum := curhead.uh_cursor.lnum
			if lnum >= top && lnum <= top + newsize + 1 {
				new_curpos = curhead.uh_cursor
				newlnum = -1
			} else if top < newlnum {
				i: C.int = 0
				for i < newsize && i < oldsize {
					line_a := (^^u8)(uintptr(uep.ue_array) + uintptr(i) * size_of(^u8))^
					line_a_c := libc.strcmp(transmute(cstring)(line_a),
						transmute(cstring)(ml_get(top + 1 + C.int(i))))
					if line_a_c != 0 {
						break
					}
				}
				if i == newsize && newlnum == MAXLNUM && uep.ue_next == nil {
					newlnum = top
					new_curpos.lnum = newlnum + 1
				} else if i < newsize {
					newlnum = top + C.int(i)
					new_curpos.lnum = newlnum + 1
				}
			}
		}

		empty_buffer := false

		// Delete lines between top and bot, saving them in newarray.
		if oldsize > 0 {
			newarray = (^^u8)(xmalloc(C.size_t(oldsize) * size_of(^u8)))
			i := oldsize
			lnum := bot - 1
			for {
				i -= 1
				if i < 0 {
					break
				}
				(^^u8)(uintptr(newarray) + uintptr(i) * size_of(^u8))^ = u_save_line(lnum)
				if ml_line_count_b(curbuf) == 1 {
					empty_buffer = true
				}
				ml_delete_r(lnum)
				lnum -= 1
			}
		} else {
			newarray = nil
		}

		// cursor on a valid line after deletions
		check_cursor_lnum_r(curwin)

		// Insert the lines in u_array between top and bot.
		if newsize != 0 {
			lnum := top
			for i := C.int(0); i < newsize; i += 1 {
				line := (^^u8)(uintptr(uep.ue_array) + uintptr(i) * size_of(^u8))^
				if empty_buffer && lnum == 0 {
					ml_replace_c(1, line, true)
				} else {
					ml_append_flags_c(lnum, line, 0, 0)
				}
				xfree(line)
				lnum += 1
			}
			xfree(uep.ue_array)
		}

		// Adjust marks
		if oldsize != newsize {
			mark_adjust(top + 1, top + oldsize, MAXLNUM, newsize - oldsize, kExtmarkNOOP)
			if get_pos_r2(curbuf, B_OP_START).lnum > top + oldsize {
				get_pos_r2(curbuf, B_OP_START).lnum += newsize - oldsize
			}
			if get_pos_r2(curbuf, B_OP_END).lnum > top + oldsize {
				get_pos_r2(curbuf, B_OP_END).lnum += newsize - oldsize
			}
		}

		if oldsize > 0 || newsize > 0 {
			changed_lines_r(curbuf, top + 1, 0, bot, newsize - oldsize, do_buf_event)
			if spell_check_window(curwin) && bot <= ml_line_count_b(curbuf) {
				redrawWinline(curwin, bot)
			}
		}

		// Set '[ mark.
		get_pos_r2(curbuf, B_OP_START).lnum = min(get_pos_r2(curbuf, B_OP_START).lnum, top + 1)
		// Set the '] mark.
		if newsize == 0 && top + 1 > get_pos_r2(curbuf, B_OP_END).lnum {
			get_pos_r2(curbuf, B_OP_END).lnum = top + 1
		} else if top + newsize > get_pos_r2(curbuf, B_OP_END).lnum {
			get_pos_r2(curbuf, B_OP_END).lnum = top + newsize
		}

		u_newcount += newsize
		u_oldcount += oldsize
		uep.ue_size = oldsize
		uep.ue_array = newarray
		uep.ue_bot = top + newsize + 1

		// insert this entry in front of the new entry list
		uep.ue_next = newlist
		newlist = uep
		uep = nuep
	}

	// Ensure '[ and '] marks are within bounds.
	get_pos_r2(curbuf, B_OP_START).lnum = min(get_pos_r2(curbuf, B_OP_START).lnum, ml_line_count_b(curbuf))
	get_pos_r2(curbuf, B_OP_END).lnum = min(get_pos_r2(curbuf, B_OP_END).lnum, ml_line_count_b(curbuf))

	// Adjust Extmarks
	if undo {
		for i := C.int(uh_extmark_size(curhead)) - 1; i > -1; i -= 1 {
			extmark_apply_undo_r(uh_extmark_at(curhead, i)^, undo)
		}
	} else {
		for i := C.int(0); i < C.int(uh_extmark_size(curhead)); i += 1 {
			extmark_apply_undo_r(uh_extmark_at(curhead, i)^, undo)
		}
	}
	if (curhead.uh_flags & UH_RELOAD) != 0 {
		buf_updates_unload_r(curbuf, true)
	}

	// Set the cursor to the desired position.
	win_cursor_r(curwin)^ = new_curpos
	check_cursor_lnum_r(curwin)

	curhead.uh_entry = newlist
	curhead.uh_flags = new_flags
	if (old_flags & UH_EMPTYBUF) != 0 && buf_is_empty(curbuf) {
		buf_set_i32(curbuf, B_ML_FLAGS, buf_i32_at(curbuf, B_ML_FLAGS) | ML_EMPTY)
	}
	if (old_flags & UH_CHANGED) != 0 {
		changed_r(curbuf)
	} else {
		unchanged_r(curbuf, false, true)
	}

	if do_buf_event {
		buf_updates_changedtick_r(curbuf)
	}

	// restore marks from before undo/redo
	buf_namedm := transmute([^]Fmark_T)(uhp_namedm(curbuf))
	for i := 0; i < NMARKS; i += 1 {
		if curhead.uh_namedm[i].mark.lnum != 0 {
			free_fmark(buf_namedm[i])
			buf_namedm[i] = curhead.uh_namedm[i]
		}
		if namedm[i].mark.lnum != 0 {
			curhead.uh_namedm[i] = namedm[i]
		} else {
			curhead.uh_namedm[i].mark.lnum = 0
		}
	}
	if curhead.uh_visual.vi_start.lnum != 0 {
		vi_buf := (^Visualinfo_T)(uintptr(curbuf) + B_VISUAL)
		vi_buf^ = curhead.uh_visual
		curhead.uh_visual = visualinfo
	}

	// one-line-off cursor adjustment (for "o" command)
	if curhead.uh_cursor.lnum + 1 == win_cursor_r(curwin).lnum &&
		win_cursor_r(curwin).lnum > 1 {
		win_cursor_r(curwin).lnum -= 1
	}
	if win_cursor_r(curwin).lnum <= ml_line_count_b(curbuf) {
		if curhead.uh_cursor.lnum == win_cursor_r(curwin).lnum {
			win_cursor_r(curwin).col = curhead.uh_cursor.col
			if virtual_active_r(curwin) && curhead.uh_cursor_vcol >= 0 {
				coladvance_r(curwin, curhead.uh_cursor_vcol)
			} else {
				win_cursor_r(curwin).coladd = 0
			}
		} else {
			beginline(BL_SOL_FIX)
		}
	} else {
		win_cursor_r(curwin).col = 0
		win_cursor_r(curwin).coladd = 0
	}

	check_cursor(curwin)

	// Remember where we are for "g-"/":earlier 10s".
	buf_set_i32(curbuf, B_U_SEQ_CUR, curhead.uh_seq)
	if undo {
		nx := uh_next_ptr(curhead)
		buf_set_i32(curbuf, B_U_SEQ_CUR, nx != nil ? nx.uh_seq : 0)
	}

	// For ":earlier 1f"/":later 1f".
	if curhead.uh_save_nr != 0 {
		if undo {
			buf_set_i32(curbuf, B_U_SAVE_NR_CUR, curhead.uh_save_nr - 1)
		} else {
			buf_set_i32(curbuf, B_U_SAVE_NR_CUR, curhead.uh_save_nr)
		}
	}

	buf_set_i64(curbuf, B_U_TIME_CUR, i64(curhead.uh_time))

	unblock_autocmds_r()
}

uh_extmark_size :: #force_inline proc "c"(uhp: ^U_Header_T) -> C.size_t {
	return uhp.uh_extmark.n
}

uh_extmark_at :: #force_inline proc "c"(uhp: ^U_Header_T, i: C.int) -> ^ExtmarkUndoObject {
	return (^ExtmarkUndoObject)(uintptr(uhp.uh_extmark.items) + uintptr(i) * size_of(ExtmarkUndoObject))
}

// ml_append with flags: reuse register.odin's ml_append_c (flags==0 → newfile=false)
ml_append_flags_c :: #force_inline proc "c"(lnum: C.int, line: ^u8, len: C.int, flags: C.int) -> C.int {
	ok := ml_append_c(lnum, line, len, false)
	return ok ? 1 : 0
}

/// If we deleted or added lines, report the number of lines changed.
u_undo_end :: proc "c" (did_undo_arg: bool, absolute: bool, quiet: bool) {
	did_undo := did_undo_arg
	if (fdo_flags & kOptFdoFlagUndo_U) != 0 && KeyTyped {
		foldOpenCursor()
	}

	if quiet || global_busy != 0 || !messaging_r() || shortmess(SHM_UNDO_CH) {
		return
	}

	if (buf_i32_at(curbuf, B_ML_FLAGS) & ML_EMPTY) != 0 {
		u_newcount -= 1
	}

	u_oldcount -= u_newcount
	msgstr: cstring
	if u_oldcount == -1 {
		msgstr = cstring("more line")
	} else if u_oldcount < 0 {
		msgstr = cstring("more lines")
	} else if u_oldcount == 1 {
		msgstr = cstring("line less")
	} else if u_oldcount > 1 {
		msgstr = cstring("fewer lines")
	} else {
		u_oldcount = u_newcount
		if u_newcount == 1 {
			msgstr = cstring("change")
		} else {
			msgstr = cstring("changes")
		}
	}

	uhp: ^U_Header_T
	if buf_curhead(curbuf) != nil {
		if absolute && uh_next_ptr(buf_curhead(curbuf)) != nil {
			uhp = uh_next_ptr(buf_curhead(curbuf))
			did_undo = false
		} else if did_undo {
			uhp = buf_curhead(curbuf)
		} else {
			uhp = uh_next_ptr(buf_curhead(curbuf))
		}
	} else {
		uhp = buf_newhead(curbuf)
	}

	msgbuf: [80]u8
	if uhp == nil {
		msgbuf[0] = 0
	} else {
		undo_fmt_time(&msgbuf[0], size_of(msgbuf), uhp.uh_time)
	}

	{
		tp := first_tabpage
		for tp != nil {
			wp: rawptr = nil
			if tp == curtab {
				wp = firstwin
			} else {
				wp = (^rawptr)(uintptr(tp) + TP_FIRSTWIN)^
			}
			for wp != nil {
				if buf_ptr_at(wp, W_BUFFER_M) == curbuf && buf_i32_at(wp, W_P_COLE) > 0 {
					redraw_later(wp, UPD_NOT_VALID)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
		}
	}

	if VIsual_active {
		check_pos_r(curbuf, &VIsual_g)
	}

	sbuf: [256]u8
	n := libc.snprintf(&sbuf[0], size_of(sbuf), _t(cstring("%ld %s; %s #%ld  %s")),
		C.long(u_oldcount < 0 ? -u_oldcount : u_oldcount),
		_t(msgstr),
		did_undo ? _t(cstring("before")) : _t(cstring("after")),
		C.long(uhp == nil ? 0 : uhp.uh_seq),
		transmute(cstring)(&msgbuf[0]))
	sbuf[n if n >= 0 && n < 255 else 255] = 0
	msg_keep_r(transmute(cstring)(&sbuf[0]), 0, true, false)
}

kOptFdoFlagUndo_U :: 0x200

/// Put the timestamp of an undo header in buf in a nice format.
@(export)
undo_fmt_time :: proc "c" (buf: [^]u8, buflen: C.size_t, tt: C.long) {
	now := time_now()
	if now - tt >= 100 {
		tmbuf: [128]u8
		tt_v := tt
		os_localtime_r(transmute(^posix.time_t)(&tt_v), transmute(^posix.tm)(&tmbuf[0]))
		n: C.size_t
		if now - tt < (60 * 60 * 12) {
			n = libc.strftime(transmute([^]libc.char)(buf), buflen, cstring("%H:%M:%S"), transmute(^libc.tm)(&tmbuf[0]))
		} else {
			n = libc.strftime(transmute([^]libc.char)(buf), buflen, cstring("%Y/%m/%d %H:%M:%S"), transmute(^libc.tm)(&tmbuf[0]))
		}
		if n == 0 {
			buf[0] = 0
		}
	} else {
		seconds := now - tt
		fmt := ngettext_r(cstring("%ld second ago"), cstring("%ld seconds ago"), seconds)
		nn := libc.snprintf(buf, buflen, _t(fmt), seconds)
		_ = nn
	}
}

/// u_sync: stop adding to the current entry list
@(export)
u_sync :: proc "c" (force: bool) {
	if buf_bool_at(curbuf, B_U_SYNCED) || (!force && no_u_sync > 0) {
		return
	}

	if get_undolevel(curbuf) < 0 {
		buf_set_bool(curbuf, B_U_SYNCED, true) // no entries, nothing to do
	} else {
		u_getbot(curbuf) // compute ue_bot of previous u_save
		buf_set_curhead(curbuf, nil)
	}
}

/// ":undolist": List the leafs of the undo tree
@(export)
ex_undolist :: proc "c" (eap: rawptr) {
	changes := 1

	lastmark += 1
	mark := lastmark
	nomark := lastmark + 1
	lastmark += 1
	ga_lines: Str_List

	uhp := buf_oldhead(curbuf)
	for uhp != nil {
		if uh_prev_ptr(uhp) == nil && uhp.uh_walk != nomark && uhp.uh_walk != mark {
			libc.snprintf(&IObuff[0], size_of(IObuff), cstring("%6d %7d  "),
				uhp.uh_seq, changes)
				sl := libc.strlen(transmute(cstring)(&IObuff[0]))
				undo_fmt_time(&IObuff[sl], size_of(IObuff) - C.size_t(sl), uhp.uh_time)
				if uhp.uh_save_nr > 0 {
					for libc.strlen(transmute(cstring)(&IObuff[0])) < 33 {
						_xstrlcat(transmute(cstring)(&IObuff[0]), cstring(" "), size_of(IObuff))
						_ = sl
					}
					l2 := libc.strlen(transmute(cstring)(&IObuff[0]))
					libc.snprintf(&IObuff[l2], size_of(IObuff) - l2, cstring("  %3d"), uhp.uh_save_nr)
				}
				str_list_push(&ga_lines, xstrdup(&IObuff[0]))
		}

		uhp.uh_walk = mark

		if uh_prev_ptr(uhp) != nil && uh_prev_ptr(uhp).uh_walk != nomark &&
			uh_prev_ptr(uhp).uh_walk != mark {
			uhp = uh_prev_ptr(uhp)
			changes += 1
		} else if uh_alt_next_ptr(uhp) != nil &&
			uh_alt_next_ptr(uhp).uh_walk != nomark &&
			uh_alt_next_ptr(uhp).uh_walk != mark {
			uhp = uh_alt_next_ptr(uhp)
		} else if uh_next_ptr(uhp) != nil && uh_alt_prev_ptr(uhp) == nil &&
			uh_next_ptr(uhp).uh_walk != nomark &&
			uh_next_ptr(uhp).uh_walk != mark {
			uhp = uh_next_ptr(uhp)
			changes -= 1
		} else {
			uhp.uh_walk = nomark
			if uh_alt_prev_ptr(uhp) != nil {
				uhp = uh_alt_prev_ptr(uhp)
			} else {
				uhp = uh_next_ptr(uhp)
				changes -= 1
			}
		}
	}

	msg_ext_set_kind(cstring("list_cmd"))
	if ga_lines.n == 0 {
		msg_msg(_t(cstring("Nothing to undo")), 0)
	} else {
		sort_strings_r((^^u8)(ga_lines.items), C.int(ga_lines.n))

		msg_start_r()
		msg_puts_hl_r(_t(cstring("number changes  when               saved")), HLF_T_U, false)
		for i: C.size_t = 0; i < ga_lines.n && !got_int; i += 1 {
			msg_putchar('\n')
			if got_int {
				break
			}
			s := str_list_at(&ga_lines, i)
			msg_puts(transmute(cstring)(s))
		}
		msg_end_r()

		str_list_clear(&ga_lines)
	}
}

HLF_T_U :: 23 // HLF_T index in highlight enum ('t' title)

Str_List :: struct {
	n:      C.size_t,
	a:      C.size_t,
	items:  rawptr,
}

str_list_push :: proc "c" (l: ^Str_List, s: ^u8) {
	if l.n == l.a {
		newa := l.a == 0 ? C.size_t(20) : l.a * 2
		items := xrealloc(l.items, newa * size_of(^u8))
		l.items = items
		l.a = newa
	}
	(^rawptr)(uintptr(l.items) + uintptr(l.n) * size_of(rawptr))^ = s
	l.n += 1
}

str_list_at :: #force_inline proc "c"(l: ^Str_List, i: C.size_t) -> ^u8 {
	return (^u8)((^rawptr)(uintptr(l.items) + uintptr(i) * size_of(rawptr))^)
}

str_list_clear :: proc "c" (l: ^Str_List) {
	for i: C.size_t = 0; i < l.n; i += 1 {
		xfree(str_list_at(l, i))
	}
	xfree(l.items)
	l.items = nil
	l.n = 0
	l.a = 0
}

/// ":undojoin": continue adding to the last entry list
@(export)
ex_undojoin :: proc "c" (eap: rawptr) {
	if buf_newhead(curbuf) == nil {
		return // nothing changed before
	}
	if buf_curhead(curbuf) != nil {
		emsg(cstring("E790: undojoin is not allowed after undo"))
		return
	}
	if buf_bool_at(curbuf, B_U_SYNCED) {
		// fall through
	} else {
		return // already unsynced
	}
	if get_undolevel(curbuf) < 0 {
		return // no entries, nothing to do
	}
	buf_set_bool(curbuf, B_U_SYNCED, false) // Append next change to last entry
}

/// Called after writing/reloading; an undo means buffer is modified.
@(export)
u_unchanged :: proc "c" (buf: rawptr) {
	u_unch_branch(buf_oldhead(buf))
	buf_set_bool(buf, B_DID_WARN, false)
}

/// After reload with 'undoreload': find first changed line, set cursor there.
@(export)
u_find_first_changed :: proc "c" () {
	uhp := buf_newhead(curbuf)

	if buf_curhead(curbuf) != nil || uhp == nil {
		return
	}
	uep := uhp.uh_entry
	if uep.ue_top != 0 || uep.ue_bot != 0 {
		return
	}

	lnum: C.int = 1
	for lnum < ml_line_count_b(curbuf) && lnum <= C.int(uep.ue_size) {
		arr_line := (^^u8)(uintptr(uep.ue_array) + uintptr(lnum - 1) * size_of(^u8))^
		if libc.strcmp(transmute(cstring)(ml_get_buf(curbuf, lnum)),
			transmute(cstring)(arr_line)) != 0 {
			uhp.uh_cursor.col = 0
			uhp.uh_cursor.coladd = 0
			uhp.uh_cursor.lnum = lnum
			return
		}
		lnum += 1
	}
	if ml_line_count_b(curbuf) != C.int(uep.ue_size) {
		uhp.uh_cursor.col = 0
		uhp.uh_cursor.coladd = 0
		uhp.uh_cursor.lnum = lnum
	}
}

/// Increase write count, store in last undo header.
@(export)
u_update_save_nr :: proc "c" (buf: rawptr) {
	buf_set_i32(buf, B_U_SAVE_NR_LAST, buf_i32_at(buf, B_U_SAVE_NR_LAST) + 1)
	buf_set_i32(buf, B_U_SAVE_NR_CUR, buf_i32_at(buf, B_U_SAVE_NR_LAST))
	uhp := buf_curhead(buf)
	if uhp != nil {
		uhp = uh_next_ptr(uhp)
	} else {
		uhp = buf_newhead(buf)
	}
	if uhp != nil {
		uhp.uh_save_nr = buf_i32_at(buf, B_U_SAVE_NR_LAST)
	}
}

u_unch_branch :: proc "c" (uhp: ^U_Header_T) {
	uh := uhp
	for uh != nil {
		uh.uh_flags |= UH_CHANGED
		if uh_alt_next_ptr(uh) != nil {
			u_unch_branch(uh_alt_next_ptr(uh)) // recursive
		}
		uh = uh_prev_ptr(uh)
	}
}

/// Get pointer to last added entry; error+NULL when invalid.
u_get_headentry :: proc "c" (buf: rawptr) -> ^U_Entry_T {
	nh := buf_newhead(buf)
	if nh == nil || nh.uh_entry == nil {
		iemsg_r(e_undo_list_corrupt)
		return nil
	}
	return nh.uh_entry
}

/// u_getbot(): compute line number of previous u_save (only when !b_u_synced).
u_getbot :: proc "c" (buf: rawptr) {
	uep_chk := u_get_headentry(buf)
	if uep_chk == nil {
		return
	}

	uep := buf_newhead(buf).uh_getbot_entry
	if uep != nil {
		extra := ml_line_count_b(buf) - uep.ue_lcount
		uep.ue_bot = uep.ue_top + uep.ue_size + 1 + extra
		if uep.ue_bot < 1 || uep.ue_bot > ml_line_count_b(buf) {
			iemsg_r(e_undo_line_missing)
			uep.ue_bot = uep.ue_top + 1
		}

		buf_newhead(buf).uh_getbot_entry = nil
	}

	buf_set_bool(buf, B_U_SYNCED, true)
}

/// Free one header and its entry list, adjusting pointers.
u_freeheader :: proc "c" (buf: rawptr, uhp: ^U_Header_T, uhpp: ^^U_Header_T) {
	if uh_alt_next_ptr(uhp) != nil {
		u_freebranch(buf, uh_alt_next_ptr(uhp), uhpp)
	}

	if uh_alt_prev_ptr(uhp) != nil {
		uh_set_alt_next(uh_alt_prev_ptr(uhp), nil)
	}

	if uh_next_ptr(uhp) == nil {
		buf_set_oldhead(buf, uh_prev_ptr(uhp))
	} else {
		uh_set_prev(uh_next_ptr(uhp), uh_prev_ptr(uhp))
	}

	if uh_prev_ptr(uhp) == nil {
		buf_set_newhead(buf, uh_next_ptr(uhp))
	} else {
		uhap := uh_prev_ptr(uhp)
		for uhap != nil {
			uh_set_next(uhap, uh_next_ptr(uhp))
			uhap = uh_alt_next_ptr(uhap)
		}
	}

	u_freeentries(buf, uhp, uhpp)
}

/// Free an alternate branch and any following alternate branches.
u_freebranch :: proc "c" (buf: rawptr, uhp: ^U_Header_T, uhpp: ^^U_Header_T) {
	if uhp == buf_oldhead(buf) {
		for buf_oldhead(buf) != nil {
			u_freeheader(buf, buf_oldhead(buf), uhpp)
		}
		return
	}

	if uh_alt_prev_ptr(uhp) != nil {
		uh_set_alt_next(uh_alt_prev_ptr(uhp), nil)
	}

	next := uhp
	for next != nil {
		tofree := next
		if uh_alt_next_ptr(tofree) != nil {
			u_freebranch(buf, uh_alt_next_ptr(tofree), uhpp) // recursive
		}
		next = uh_prev_ptr(tofree)
		u_freeentries(buf, tofree, uhpp)
	}
}

/// Free all entries for one header and the header itself.
u_freeentries :: proc "c" (buf: rawptr, uhp: ^U_Header_T, uhpp: ^^U_Header_T) {
	if buf_curhead(buf) == uhp {
		buf_set_curhead(buf, nil)
	}
	if buf_newhead(buf) == uhp {
		buf_set_newhead(buf, nil)
	}
	if uhpp != nil && uhp == uhpp^ {
		uhpp^ = nil
	}

	uep := uhp.uh_entry
	for uep != nil {
		nuep := uep.ue_next
		u_freeentry(uep, uep.ue_size)
		uep = nuep
	}

	// kv_destroy(uhp->uh_extmark)
	xfree(uhp.uh_extmark.items)
	uhp.uh_extmark = Kvec_XUndo{}

	xfree(uhp)
	buf_set_i32(buf, B_U_NUMHEAD, buf_i32_at(buf, B_U_NUMHEAD) - 1)
}

/// free entry uep and n lines in uep->ue_array[]
u_freeentry :: proc "c" (uep: ^U_Entry_T, n_arg: C.int) {
	n := n_arg
	for n > 0 {
		n -= 1
		xfree((^^u8)(uintptr(uep.ue_array) + uintptr(n) * size_of(^u8))^)
	}
	xfree(uep.ue_array)
	xfree(uep)
}

/// invalidate the undo buffer (storage already released)
@(export)
u_clearall :: proc "c" (buf: rawptr) {
	buf_set_oldhead(buf, nil)
	buf_set_newhead(buf, nil)
	buf_set_curhead(buf, nil)
	buf_set_bool(buf, B_U_SYNCED, true)
	buf_set_i32(buf, B_U_NUMHEAD, 0)
	(^rawptr)(uintptr(buf) + B_U_LINE_PTR)^ = nil
	buf_set_i32(buf, B_U_LINE_LNUM, 0)
}

/// Free all allocated memory blocks for the buffer.
@(export)
u_blockfree :: proc "c" (buf: rawptr) {
	for buf_oldhead(buf) != nil {
		u_freeheader(buf, buf_oldhead(buf), nil)
	}
	xfree(buf_ptr_at(buf, B_U_LINE_PTR))
}

/// Free all blocks and invalidate the undo buffer.
@(export)
u_clearallandblockfree :: proc "c" (buf: rawptr) {
	u_blockfree(buf)
	u_clearall(buf)
}

/// Save the line lnum for the "U" command.
u_saveline :: proc "c" (buf: rawptr, lnum: C.int) {
	if lnum == buf_i32_at(buf, B_U_LINE_LNUM) {
		return
	}
	if lnum < 1 || lnum > ml_line_count_b(buf) {
		return
	}
	u_clearline(buf)
	buf_set_i32(buf, B_U_LINE_LNUM, lnum)
	if buf_ptr_at(curwin, W_BUFFER) == buf && win_cursor_r(curwin).lnum == lnum {
		buf_set_i32(buf, B_U_LINE_COLNR, win_cursor_r(curwin).col)
	} else {
		buf_set_i32(buf, B_U_LINE_COLNR, 0)
	}
	(^rawptr)(uintptr(buf) + B_U_LINE_PTR)^ = u_save_line_buf(buf, lnum)
}

/// clear the line saved for the "U" command
@(export)
u_clearline :: proc "c" (buf: rawptr) {
	if buf_ptr_at(buf, B_U_LINE_PTR) == nil {
		return
	}

	p := buf_ptr_at(buf, B_U_LINE_PTR)
	xfree(p)
	(^rawptr)(uintptr(buf) + B_U_LINE_PTR)^ = nil
	buf_set_i32(buf, B_U_LINE_LNUM, 0)
}

/// Implementation of the "U" command.
@(export)
u_undoline :: proc "c" () {
	if buf_ptr_at(curbuf, B_U_LINE_PTR) == nil ||
		buf_i32_at(curbuf, B_U_LINE_LNUM) > ml_line_count_b(curbuf) {
		beep_flush_r()
		return
	}

	// first save the line for the 'u' command
	if u_savecommon(curbuf, buf_i32_at(curbuf, B_U_LINE_LNUM) - 1,
		buf_i32_at(curbuf, B_U_LINE_LNUM) + 1, 0, false) == FAIL_R {
		return
	}

	oldp := u_save_line(buf_i32_at(curbuf, B_U_LINE_LNUM))
	line_ptr := (^u8)(buf_ptr_at(curbuf, B_U_LINE_PTR))
	ml_replace_c(buf_i32_at(curbuf, B_U_LINE_LNUM), line_ptr, true)
	extmark_splice_cols_r(curbuf, buf_i32_at(curbuf, B_U_LINE_LNUM) - 1, 0,
		C.int(libc.strlen(transmute(cstring)(oldp))),
		C.int(libc.strlen(transmute(cstring)(line_ptr))), kExtmarkUndo)
	changed_bytes_r(buf_i32_at(curbuf, B_U_LINE_LNUM), 0)
	xfree(line_ptr)
	(^rawptr)(uintptr(curbuf) + B_U_LINE_PTR)^ = oldp

	t := buf_i32_at(curbuf, B_U_LINE_COLNR)
	if win_cursor_r(curwin).lnum == buf_i32_at(curbuf, B_U_LINE_LNUM) {
		buf_set_i32(curbuf, B_U_LINE_COLNR, win_cursor_r(curwin).col)
	}
	win_cursor_r(curwin).col = t
	win_cursor_r(curwin).lnum = buf_i32_at(curbuf, B_U_LINE_LNUM)
	check_cursor_col_r(curwin)
}

/// Check if 'modified' flag is set or file has changed on disk.
@(export)
bufIsChanged :: proc "c" (buf: rawptr) -> bool {
	return bt_prompt(buf) ? buf_bool_at(buf, B_MODIFIED_WAS_SET) :
		(!bt_dontwrite(buf) && (buf_bool_at(buf, B_CHANGED) || file_ff_differs_r(buf, true)))
}

@(export)
anyBufIsChanged :: proc "c" () -> bool {
	buf := firstbuf
	for buf != nil {
		if bufIsChanged(buf) {
			return true
		}
		buf = buf_ptr_at(buf, B_NEXT)
	}
	return false
}

@(export)
curbufIsChanged :: proc "c" () -> bool {
	return bufIsChanged(curbuf)
}

/// Append list of undo blocks to a newly allocated list (for undotree()).
u_eval_tree :: proc "c" (buf: rawptr, first_uhp: ^U_Header_T) -> rawptr {
	list := tv_list_alloc(-3)

	uhp := first_uhp
	for uhp != nil {
		dict := tv_dict_alloc()
		tv_dict_add_nr(dict, cstring("seq"), 3, C.longlong(uhp.uh_seq))
		tv_dict_add_nr(dict, cstring("time"), 4, C.longlong(uhp.uh_time))
		if uhp == buf_newhead(buf) {
			tv_dict_add_nr(dict, cstring("newhead"), 7, 1)
		}
		if uhp == buf_curhead(buf) {
			tv_dict_add_nr(dict, cstring("curhead"), 7, 1)
		}
		if uhp.uh_save_nr > 0 {
			tv_dict_add_nr(dict, cstring("save"), 4, C.longlong(uhp.uh_save_nr))
		}

		if uh_alt_next_ptr(uhp) != nil {
			tv_dict_add_list(dict, cstring("alt"), 3, u_eval_tree(buf, uh_alt_next_ptr(uhp)))
		}

		tv_list_append_dict(list, dict)
		uhp = uh_prev_ptr(uhp)
	}

	return list
}

/// "undofile(name)" function
@(export)
f_undofile :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	rettv.v_type = VAR_STRING_U
	(^rawptr)(uintptr(rettv) + 8)^ = nil
	fname := tv_get_string(transmute(^Typval_T)(&([^]Typval)(argvars)[0]))

	if ([^]u8)(fname)[0] == 0 {
		return
	}
	ffname := FullName_save_r(fname, true)
	if ffname != nil {
		(^rawptr)(uintptr(rettv) + 8)^ = u_get_undo_file_name(transmute(cstring)(ffname), false)
	}
	xfree(ffname)
}

VAR_STRING_U :: 2 // typval_T VAR_STRING

/// "undotree()" function
@(export)
f_undotree :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	tv_dict_alloc_ret(transmute(^Typval_T)(rettv))

	tv := &([^]Typval)(argvars)[0]
	buf := tv.v_type == VAR_UNKNOWN_U ? curbuf : get_buf_arg_r(tv)
	if buf == nil {
		return
	}

	dict := (^rawptr)(uintptr(rettv) + 8)^

	tv_dict_add_nr(dict, cstring("synced"), 6, C.longlong(buf_bool_at(buf, B_U_SYNCED)))
	tv_dict_add_nr(dict, cstring("seq_last"), 8, C.longlong(buf_i32_at(buf, B_U_SEQ_LAST)))
	tv_dict_add_nr(dict, cstring("save_last"), 9, C.longlong(buf_i32_at(buf, B_U_SAVE_NR_LAST)))
	tv_dict_add_nr(dict, cstring("seq_cur"), 7, C.longlong(buf_i32_at(buf, B_U_SEQ_CUR)))
	tv_dict_add_nr(dict, cstring("time_cur"), 8, C.longlong(buf_i64_at(buf, B_U_TIME_CUR)))
	tv_dict_add_nr(dict, cstring("save_cur"), 8, C.longlong(buf_i32_at(buf, B_U_SAVE_NR_CUR)))

	tv_dict_add_list(dict, cstring("entries"), 7, u_eval_tree(buf, buf_oldhead(buf)))
}

VAR_UNKNOWN_U :: 0

/// Given buffer, return undo header, creating one first if needed.
@(export)
u_force_get_undo_header :: proc "c" (buf: rawptr) -> ^U_Header_T {
	uhp: ^U_Header_T = nil
	if buf_curhead(buf) != nil {
		uhp = buf_curhead(buf)
	} else if buf_newhead(buf) != nil {
		uhp = buf_newhead(buf)
	}
	if uhp == nil {
		u_savecommon(buf, 0, 1, 1, true)

		uhp = buf_curhead(buf)
		if uhp == nil {
			uhp = buf_newhead(buf)
			if get_undolevel(buf) > 0 && uhp == nil {
				libc.abort()
			}
		}
	}
	return uhp
}
