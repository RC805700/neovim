// fold.odin — port of src/nvim/fold.c (folding: manual/indent/expr/marker/syntax/diff)
//
// Layouts probe-verified 2026-07:
//   fold_T = 40 {fd_top@0(i32), fd_len@4, fd_nested(Garray 24)@8, fd_flags@32(u8),
//                pad, fd_small(TriState c.int)@36}
//   Wline_T=16 {wl_lnum@0, wl_size@4(u16), wl_valid@6, wl_folded@7, wl_foldend@8}
//   win_T: w_folds@648, w_fold_manual@672, w_foldinvalid@673, w_lines_valid@624,
//     w_lines@632, w_p_fen@864, w_p_fdi@872, w_p_fdl@880, w_p_fdm@896, w_p_fml@912,
//     w_p_fdn@920, w_p_fmr@944, w_p_fde@928, w_p_fdt@936, w_p_scb@1112,
//     w_p_cole@1144, w_p_script_ctx@1248 (sctx_T stride 24; kWinOptFoldtext=22)
//   buf_T: b_p_cms@10232
//
// Reuses package-wide: Pos_T/Garray/TriState(main,input), mark.odin FFI
// (ml_get*, utfc_ptr2len, setpcmark), register.odin helpers (u_save, extmark_splice_cols_r,
// changed_lines_r, buf_updates_send_changes_r), os_lang skipwhite, main.odin VV_*.

package main

import C "core:c"
import "core:c/libc"

// ── Constants ────────────────────────────────────────────────────────────────

MAX_LEVEL :: 20
FOLD_TEXT_LEN :: 51

FD_OPEN :: 0
FD_CLOSED :: 1
FD_LEVEL :: 2

DONE_NOTHING :: 0
DONE_ACTION :: 1
DONE_FOLD :: 2

UPD_INVERTED_F :: 20
kWinOptFoldtext :: 22
SCCTX_STRIDE :: 24 // sizeof(sctx_T): {sc_sid u32, sc_seq i32, sc_lnum i32, pad, sc_chan u64}

VV_LNUM_F :: 9
VV_FOLDSTART :: 23
VV_FOLDEND :: 24
VV_FOLDDASHES :: 25
VV_FOLDLEVEL :: 26

FORWARD_F :: 1
BACKWARD_F :: -1

// Error strings
e_nofold: cstring = "E490: No fold found"
e_foldcreate350: cstring = "E350: Cannot create fold with current 'foldmethod'"
e_folddelete351: cstring = "E351: Cannot delete fold with current 'foldmethod'"

// ── Types ────────────────────────────────────────────────────────────────────

Fold_T :: struct {
	fd_top:   C.int,
	fd_len:   C.int,
	fd_nested: Garray,
	fd_flags: u8,
	_pad0:    [3]u8,
	fd_small: TriState,
}
#assert(size_of(Fold_T) == 40)

Fline_T :: struct {
	wp:        rawptr,
	lnum:      C.int,
	off:       C.int,
	lnum_save: C.int,
	lvl:       C.int,
	lvl_next:  C.int,
	start:     C.int,
	end:       C.int,
	had_end:   C.int,
}

LevelGetter :: proc "c" (^Fline_T)

Foldinfo_T :: struct {
	fi_lnum:     C.int,
	fi_level:    C.int,
	fi_low_level: C.int,
	fi_lines:    C.int,
}
#assert(size_of(Foldinfo_T) == 16)

VirtTextChunk :: struct {
	text:  ^u8,
	hl_id: C.int,
}
#assert(size_of(VirtTextChunk) == 16)

Wline_T :: struct {
	wl_lnum:    C.int,
	wl_size:    u16,
	wl_valid:   bool,
	wl_folded:  bool,
	wl_foldend: C.int,
	_pad0:      [4]u8, // wl_lastlnum
}
#assert(size_of(Wline_T) == 16)

Kvec_VT :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: ^VirtTextChunk,
}
#assert(size_of(Kvec_VT) == 24)

Api_Error :: struct {
	typ: C.int,
	msg: ^u8,
}
#assert(size_of(Api_Error) == 16)

Kvec_Obj :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: ^Api_Object,
}

// ── Statics ──────────────────────────────────────────────────────────────────

fold_changed := false
invalid_top: C.int = 0
invalid_bot: C.int = 0
prev_lnum: C.int = 0
prev_lnum_lvl: C.int = -1
foldstartmarkerlen: C.size_t = 0
foldendmarker: ^u8 = nil
foldendmarkerlen: C.size_t = 0
got_fdt_error := false
last_wp: rawptr = nil
last_lnum: C.int = 0
ftres_entered := false

// ── Foreign globals ──────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "emsg_off")
	emsg_off: C.int

	@(link_name = "current_sctx")
	current_sctx_buf: [SCCTX_STRIDE]u8

	@(link_name = "disable_fold_update")
	disable_fold_update: C.int

	@(link_name = "need_diff_redraw")
	need_diff_redraw: bool

	@(link_name = "diff_context")
	diff_context_g: C.int

	@(link_name = "p_fcl")
	p_fcl: ^u8
}

// ── Foreign procs ────────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "changed_window_setting")
	changed_window_setting_r :: proc "c" (wp: rawptr) ---
	@(link_name = "diff_lnum_win")
	diff_lnum_win_r :: proc "c" (lnum: C.int, wp: rawptr) -> C.int ---
	@(link_name = "diff_infold")
	diff_infold_r :: proc "c" (wp: rawptr, lnum: C.int) -> bool ---
	@(link_name = "plines_win_nofold")
	plines_win_nofold_r :: proc "c" (wp: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "get_indent_buf")
	get_indent_buf_r :: proc "c" (buf: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "get_sw_value")
	get_sw_value_r :: proc "c" (buf: rawptr) -> C.int ---
	@(link_name = "syn_get_foldlevel")
	syn_get_foldlevel_r :: proc "c" (wp: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "eval_foldexpr")
	eval_foldexpr_r :: proc "c" (wp: rawptr, cp: ^C.int) -> C.int ---
	@(link_name = "eval_foldtext")
	eval_foldtext_r :: proc "c" (wp: rawptr) -> Api_Object ---
	@(link_name = "parse_virt_text")
	parse_virt_text_r :: proc "c" (chunks: Kvec_Obj, err: ^Api_Error, width: ^C.int, untab: bool) -> Kvec_VT ---
	@(link_name = "api_free_object")
	api_free_object_r :: proc "c" (value: Api_Object) ---
	@(link_name = "api_clear_error")
	api_clear_error_r :: proc "c" (value: ^Api_Error) ---
	@(link_name = "next_virt_text_chunk")
	next_virt_text_chunk_r :: proc "c" (vt: Kvec_VT, pos: ^C.size_t, attr: ^C.int) -> ^u8 ---
	@(link_name = "clear_virttext")
	clear_virttext_r :: proc "c" (text: ^Kvec_VT) ---
	@(link_name = "skip_comment")
	skip_comment_r :: proc "c" (line: ^u8, process: bool, include_space: bool, is_comment: ^bool) -> ^u8 ---
	@(link_name = "transstr")
	transstr_r :: proc "c" (s: cstring, untab: bool) -> ^u8 ---
	// linewhite now defined in search.odin — reuse directly.
	@(link_name = "ml_replace_buf")
	ml_replace_buf_r :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, copy: bool, noalloc: bool) -> C.int ---
	@(link_name = "put_line")
	put_line_r :: proc "c" (fd: ^libc.FILE, s: cstring) -> C.int ---
	@(link_name = "put_eol")
	put_eol_r :: proc "c" (fd: ^libc.FILE) -> C.int ---
	@(link_name = "tv_get_lnum")
	tv_get_lnum_r :: proc "c" (tv: ^Typval) -> C.int ---
	@(link_name = "ga_grow")
	ga_grow_r :: proc "c" (gap: ^Garray, n: C.int) ---
	@(link_name = "ga_init")
	ga_init_r2 :: proc "c" (gap: ^Garray, itemsize: C.int, growsize: C.int) ---
	// xmemcpyz reused from os_env.odin's _xmemcpyz
	// line_breakcheck reused from input.odin's line_breakcheck
	@(link_name = "mb_adjust_cursor")
	mb_adjust_cursor_r :: proc "c" () ---
	@(link_name = "vim_strchr")
	vim_strchr_c :: proc "c" (s: ^u8, c: C.int) -> ^u8 ---
}

// ── Field accessors ──────────────────────────────────────────────────────────

w_ptr_at :: #force_inline proc "c"(base: rawptr, off: uintptr) -> rawptr {
	return (^rawptr)(uintptr(base) + off)^
}
w_i32 :: #force_inline proc "c"(base: rawptr, off: uintptr) -> C.int {
	return (^C.int)(uintptr(base) + off)^
}
w_set_i32 :: #force_inline proc "c"(base: rawptr, off: uintptr, v: C.int) {
	(^C.int)(uintptr(base) + off)^ = v
}
w_bool :: #force_inline proc "c"(base: rawptr, off: uintptr) -> bool {
	return (^bool)(uintptr(base) + off)^
}
w_set_bool :: #force_inline proc "c"(base: rawptr, off: uintptr, v: bool) {
	(^bool)(uintptr(base) + off)^ = v
}
w_i64 :: #force_inline proc "c"(base: rawptr, off: uintptr) -> i64 {
	return (^i64)(uintptr(base) + off)^
}
w_str :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^u8 {
	return (^^u8)(uintptr(base) + off)^
}
w_ga :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Garray {
	return (^Garray)(uintptr(base) + off)
}

W_FOLDS :: 648
W_FOLD_MANUAL :: 672
W_FOLDINVALID :: 673
W_LINES_VALID :: 624
W_LINES :: 632
W_P_FEN :: 864
W_P_FDI :: 872
W_P_FDL :: 880
W_P_FDM :: 896
W_P_FML :: 912
W_P_FDN :: 920
W_P_FDE :: 928
W_P_SCRIPT_CTX :: 1248
W_P_FDT :: 936
W_P_FMR :: 944
W_P_SCB :: 1112
B_P_CMS :: 10232

fp_at :: #force_inline proc "c"(gap: ^Garray, i: C.int) -> ^Fold_T {
	return (^Fold_T)(uintptr(gap.ga_data) + uintptr(C.int(i)) * size_of(Fold_T))
}

GA_EMPTY_F :: #force_inline proc "c"(ga: ^Garray) -> bool {
	return ga.ga_len <= 0
}

// ── Exported functions ───────────────────────────────────────────────────────

/// Copy that folding state from window wp_from to wp_to.
@(export)
copyFoldingState :: proc "c" (wp_from, wp_to: rawptr) {
	w_set_bool(wp_to, W_FOLD_MANUAL, w_bool(wp_from, W_FOLD_MANUAL))
	w_set_bool(wp_to, W_FOLDINVALID, w_bool(wp_from, W_FOLDINVALID))
	cloneFoldGrowArray(w_ga(wp_from, W_FOLDS), w_ga(wp_to, W_FOLDS))
}

/// true if there may be folded lines in window win.
@(export)
hasAnyFolding :: proc "c" (win: rawptr) -> C.int {
	buf := w_ptr_at(win, W_BUFFER_M)
	return (!buf_bool_at(buf, B_TERMINAL) && w_bool(win, W_P_FEN)
		&& (!foldmethodIsManual(win) || !GA_EMPTY_F(w_ga(win, W_FOLDS)))) ? 1 : 0
}

/// true if line lnum in window win is part of a closed fold.
@(export)
hasFolding :: proc "c" (win: rawptr, lnum: C.int, firstp: ^C.int, lastp: ^C.int) -> bool {
	return hasFoldingWin(win, lnum, firstp, lastp, true, nil)
}

/// Search folds starting at lnum.
@(export)
hasFoldingWin :: proc "c" (win: rawptr, lnum: C.int, firstp: ^C.int, lastp: ^C.int,
	cache: bool, infop: ^Foldinfo_T) -> bool {
	checkupdate(win)

	if hasAnyFolding(win) == 0 {
		if infop != nil {
			infop.fi_level = 0
		}
		return false
	}

	had_folded := false
	first: C.int = 0
	last: C.int = 0

	if cache {
		x := find_wl_entry(win, lnum)
		if x >= 0 {
			wlines := transmute([^]Wline_T)(w_ptr_at(win, W_LINES))
			first = wlines[x].wl_lnum
			last = wlines[x].wl_foldend
			had_folded = wlines[x].wl_folded
		}
	}

	lnum_rel := lnum
	level: C.int = 0
	low_level: C.int = 0
	fp: ^Fold_T = nil
	maybe_small := false
	use_level := false

	if first == 0 {
		// Recursively search for a fold that contains lnum.
		gap := w_ga(win, W_FOLDS)
		for true {
			if !foldFind(gap, lnum_rel, &fp) {
				break
			}

			// Remember lowest level of fold that starts in lnum.
			if lnum_rel == fp.fd_top && low_level == 0 {
				low_level = level + 1
			}

			first += fp.fd_top
			last += fp.fd_top

			// is this fold closed?
			had_folded = check_closed(win, fp, &use_level, level, &maybe_small, lnum - lnum_rel)
			if had_folded {
				last += fp.fd_len - 1
				break
			}

			// Fold found but open: check nested folds.
			gap = &fp.fd_nested
			lnum_rel -= fp.fd_top
			level += 1
		}
	}

	if !had_folded {
		if infop != nil {
			infop.fi_level = level
			infop.fi_lnum = lnum - lnum_rel
			infop.fi_low_level = low_level == 0 ? level : low_level
		}
		return false
	}

	last = min(last, ml_line_count_b(w_ptr_at(win, W_BUFFER)))
	if lastp != nil {
		lastp^ = last
	}
	if firstp != nil {
		firstp^ = first
	}
	if infop != nil {
		infop.fi_level = level + 1
		infop.fi_lnum = first
		infop.fi_low_level = low_level == 0 ? level + 1 : low_level
	}
	return true
}

/// fold level at line lnum in the current window.
foldLevel :: proc "c" (lnum: C.int) -> C.int {
	if invalid_top == 0 {
		checkupdate(curwin)
	} else if lnum == prev_lnum && prev_lnum_lvl >= 0 {
		return prev_lnum_lvl
	} else if lnum >= invalid_top && lnum <= invalid_bot {
		return -1
	}

	if hasAnyFolding(curwin) == 0 {
		return 0
	}

	return foldLevelWin(curwin, lnum)
}

/// Low level check if a line is folded.
@(export)
lineFolded :: proc "c" (win: rawptr, lnum: C.int) -> bool {
	return fold_info(win, lnum).fi_lines != 0
}

/// Count number of folded lines at lnum.
@(export)
fold_info :: proc "c" (win: rawptr, lnum: C.int) -> Foldinfo_T {
	info: Foldinfo_T
	last: C.int

	if hasFoldingWin(win, lnum, nil, &last, false, &info) {
		info.fi_lines = last - lnum + 1
	} else {
		info.fi_lines = 0
	}
	return info
}

@(export)
foldmethodIsManual :: proc "c" (wp: rawptr) -> bool {
	fdm := w_str(wp, W_P_FDM)
	return fdm^ != 0 && (^u8)(uintptr(fdm)+3)^ == 'u'
}

@(export)
foldmethodIsIndent :: proc "c" (wp: rawptr) -> bool {
	return w_str(wp, W_P_FDM)^ == 'i'
}

@(export)
foldmethodIsExpr :: proc "c" (wp: rawptr) -> bool {
	fdm := w_str(wp, W_P_FDM)
	return fdm^ != 0 && (^u8)(uintptr(fdm)+1)^ == 'x'
}

@(export)
foldmethodIsMarker :: proc "c" (wp: rawptr) -> bool {
	fdm := w_str(wp, W_P_FDM)
	return fdm^ != 0 && (^u8)(uintptr(fdm)+2)^ == 'r'
}

@(export)
foldmethodIsSyntax :: proc "c" (wp: rawptr) -> bool {
	return w_str(wp, W_P_FDM)^ == 's'
}

@(export)
foldmethodIsDiff :: proc "c" (wp: rawptr) -> bool {
	return w_str(wp, W_P_FDM)^ == 'd'
}

/// Close fold at pos, repeat count times.
@(export)
closeFold :: proc "c" (pos: Pos_T, count: C.int) {
	setFoldRepeat(pos, count, false)
}

@(export)
closeFoldRecurse :: proc "c" (pos: Pos_T) {
	setManualFold(pos, false, true, nil)
}

/// Open or close folds in lines first..last (Visual zo/zO/zc/zC).
@(export)
opFoldRange :: proc "c" (firstpos: Pos_T, lastpos: Pos_T, opening: C.int, recurse: C.int, had_visual: bool) {
	done: C.int = DONE_NOTHING
	first := firstpos.lnum
	last := lastpos.lnum
	lnum_next: C.int

	lnum := first
	for lnum <= last {
		temp := Pos_T{lnum = lnum}
		lnum_next = lnum
		if opening != 0 && recurse == 0 {
			hasFolding(curwin, lnum, nil, &lnum_next)
		}
		setManualFold(temp, opening != 0, recurse != 0, &done)
		if opening == 0 && recurse == 0 {
			hasFolding(curwin, lnum, nil, &lnum_next)
		}
		lnum = lnum_next + 1
	}
	if done == DONE_NOTHING {
		emsg(_t(e_nofold))
	}
	if had_visual {
		redraw_curbuf_later(UPD_INVERTED_F)
	}
}

@(export)
openFold :: proc "c" (pos: Pos_T, count: C.int) {
	setFoldRepeat(pos, count, true)
}

@(export)
openFoldRecurse :: proc "c" (pos: Pos_T) {
	setManualFold(pos, true, true, nil)
}

/// Open folds until cursor line not in closed fold.
@(export)
foldOpenCursor :: proc "c" () {
	checkupdate(curwin)
	if hasAnyFolding(curwin) != 0 {
		for true {
			done: C.int = DONE_NOTHING
			setManualFold(win_cursor_r(curwin)^, true, false, &done)
			if (done & DONE_ACTION) == 0 {
				break
			}
		}
	}
}

/// Set new foldlevel for current window.
@(export)
newFoldLevel :: proc "c" () {
	newFoldLevelWin(curwin)

	if foldmethodIsDiff(curwin) && w_bool(curwin, W_P_SCB) {
		tp := first_tabpage
		for tp != nil {
			wp: rawptr = tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN)^
			for wp != nil {
				if wp != curwin && foldmethodIsDiff(wp) && w_bool(wp, W_P_SCB) {
					w_set_i32(wp, W_P_FDL, w_i32(curwin, W_P_FDL))
					newFoldLevelWin(wp)
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
		}
	}
}

newFoldLevelWin :: proc "c" (wp: rawptr) {
	checkupdate(wp)
	if w_bool(wp, W_FOLD_MANUAL) {
		ga := w_ga(wp, W_FOLDS)
		for i: C.int = 0; i < ga.ga_len; i += 1 {
			fp_at(ga, C.int(i)).fd_flags = FD_LEVEL
		}
		w_set_bool(wp, W_FOLD_MANUAL, false)
	}
	changed_window_setting_r(wp)
}

/// Apply 'foldclose' to all folds that don't contain the cursor.
@(export)
foldCheckClose :: proc "c" () {
	if p_fcl^ == 0 {
		return
	}

	checkupdate(curwin)
	if checkCloseRec(w_ga(curwin, W_FOLDS), win_cursor_r(curwin).lnum, C.int(w_i64(curwin, W_P_FDL))) {
		changed_window_setting_r(curwin)
	}
}

checkCloseRec :: proc "c" (gap: ^Garray, lnum: C.int, level: C.int) -> bool {
	retval := false

	for i: C.int = 0; i < gap.ga_len; i += 1 {
		fp := fp_at(gap, C.int(i))
		// Only manually opened folds may need to be closed.
		if fp.fd_flags == FD_OPEN {
			if level <= 0 && (lnum < fp.fd_top || lnum >= fp.fd_top + fp.fd_len) {
				fp.fd_flags = FD_LEVEL
				retval = true
			} else {
				retval = checkCloseRec(&fp.fd_nested, lnum - fp.fd_top, level - 1) || retval
			}
		}
	}
	return retval
}

/// true if manually creating/deleting a fold is allowed.
@(export)
foldManualAllowed :: proc "c" (create: bool) -> C.int {
	if foldmethodIsManual(curwin) || foldmethodIsMarker(curwin) {
		return 1
	}
	if create {
		emsg(_t(e_foldcreate350))
	} else {
		emsg(_t(e_folddelete351))
	}
	return 0
}

/// Create a fold from line start to line end (inclusive) in window wp.
@(export)
foldCreate :: proc "c" (wp: rawptr, start_arg: Pos_T, end_arg: Pos_T) {
	start := start_arg
	end := end_arg
	use_level := false
	closed := false
	level: C.int = 0
	start_rel := start
	end_rel := end

	if start.lnum > end.lnum {
		// reverse the range
		end = start_rel
		start = end_rel
		start_rel = start
		end_rel = end
	}

	// 'foldmethod' == "marker": add markers instead.
	if foldmethodIsMarker(wp) {
		foldCreateMarkers(wp, start, end)
		return
	}

	checkupdate(wp)

	i: C.int

	gap := w_ga(wp, W_FOLDS)
	fp: ^Fold_T = nil
	if gap.ga_len == 0 {
		i = 0
	} else {
		for true {
			if !foldFind(gap, start_rel.lnum, &fp) {
				break
			}
			if fp.fd_top + fp.fd_len > end_rel.lnum {
				// New fold completely inside this fold: one level deeper.
				gap = &fp.fd_nested
				start_rel.lnum -= fp.fd_top
				end_rel.lnum -= fp.fd_top
				if use_level || fp.fd_flags == FD_LEVEL {
					use_level = true
					if C.int(level) >= C.int(w_i64(wp, W_P_FDL)) {
						closed = true
					}
				} else if fp.fd_flags == FD_CLOSED {
					closed = true
				}
				level += 1
			} else {
				break
			}
		}
		if gap.ga_len == 0 {
			i = 0
		} else {
			i = C.int(uintptr(fp) - uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
		}
	}

	ga_grow_r(gap, 1)
	{
		fp_ins := fp_at(gap, i)
		fold_ga: Garray
		ga_init_r2(&fold_ga, C.int(size_of(Fold_T)), 10)

		// Count folds that will be contained in the new fold.
		cont: C.int = 0
		for i + cont < gap.ga_len {
			if fp_at(gap, i + cont).fd_top > end_rel.lnum {
				break
			}
			cont += 1
		}
		if cont > 0 {
			ga_grow_r(&fold_ga, cont)
			// First fold starts before new fold? New fold starts there.
			start_rel.lnum = min(start_rel.lnum, fp_ins.fd_top)

			// Last contained fold not fully inside? Adjust end.
			end_rel.lnum = max(end_rel.lnum,
				fp_at(gap, i + cont - 1).fd_top + fp_at(gap, i + cont - 1).fd_len - 1)
			// Move contained folds to inside new fold.
			libc.memmove(fold_ga.ga_data, fp_ins, size_of(Fold_T) * C.size_t(cont))
			fold_ga.ga_len += cont
			i += cont

			// Contained folds relative to the new fold.
			for j: C.int = 0; j < cont; j += 1 {
				fp_at(&fold_ga, C.int(j)).fd_top -= start_rel.lnum
			}
		}
		// Move remaining entries to one past the NEW fold's slot
		// (C: memmove(fp + 1, ga_data + i, ...) where fp is at the ORIGINAL i).
		if i < gap.ga_len {
			libc.memmove((^Fold_T)(uintptr(fp_ins) + size_of(Fold_T)), fp_at(gap, i),
				size_of(Fold_T) * C.size_t(gap.ga_len - i))
		}
		gap.ga_len = gap.ga_len + 1 - cont

		// insert new fold
		fp_ins.fd_nested = fold_ga
		fp_ins.fd_top = start_rel.lnum
		fp_ins.fd_len = end_rel.lnum - start_rel.lnum + 1

		// Want new fold closed; adjust containing folds if needed.
		if use_level && !closed && C.int(level) < C.int(w_i64(wp, W_P_FDL)) {
			closeFold(start, 1)
		}
		if !use_level {
			w_set_bool(wp, W_FOLD_MANUAL, true)
		}
		fp_ins.fd_flags = FD_CLOSED
		fp_ins.fd_small = .kNone

		changed_window_setting_r(wp)
	}
}

/// Delete folds in range (or at lnum when end==0).
@(export)
deleteFold :: proc "c" (wp: rawptr, start: C.int, end: C.int, recursive: C.int, had_visual: bool) {
	found_fp: ^Fold_T = nil
	found_off: C.int = 0
	maybe_small := false
	level: C.int = 0
	lnum := start
	did_one := false
	first_lnum: C.int = MAXLNUM
	last_lnum: C.int = 0

	checkupdate(wp)

	for lnum <= end {
		gap := w_ga(wp, W_FOLDS)
		found_ga: ^Garray = nil
		lnum_off: C.int = 0
		use_level := false
		for true {
			fp: ^Fold_T = nil
			if !foldFind(gap, lnum - lnum_off, &fp) {
				break
			}
			// lnum is inside this fold, remember info
			found_ga = gap
			found_fp = fp
			found_off = lnum_off

			// if "lnum" is folded, don't check nesting
			if check_closed(wp, fp, &use_level, level, &maybe_small, lnum_off) {
				break
			}

			// check nested folds
			gap = &fp.fd_nested
			lnum_off += fp.fd_top
			level += 1
		}
		if found_ga == nil {
			lnum += 1
		} else {
			lnum = found_fp.fd_top + found_fp.fd_len + found_off

			if foldmethodIsManual(wp) {
				deleteFoldEntry(wp, found_ga,
					C.int(uintptr(found_fp) - uintptr(found_ga.ga_data)) / C.int(size_of(Fold_T)),
					recursive != 0)
			} else {
				first_lnum = min(first_lnum, found_fp.fd_top + found_off)
				last_lnum = max(last_lnum, lnum)
				if !did_one {
					parseMarker(wp)
				}
				deleteFoldMarkers(wp, found_fp, recursive != 0, found_off)
			}
			did_one = true

			changed_window_setting_r(wp)
		}
	}
	if !did_one {
		emsg(_t(e_nofold))
		if had_visual {
			redraw_buf_later(w_ptr_at(wp, W_BUFFER), UPD_INVERTED_F)
		}
	} else {
		check_cursor_col_r(wp)
	}

	if last_lnum > 0 {
		buf := w_ptr_at(wp, W_BUFFER)
		changed_lines_r(buf, first_lnum, 0, last_lnum, 0, false)

		num_changed := i64(last_lnum - first_lnum)
		buf_updates_send_changes_r(buf, first_lnum, num_changed, num_changed)
	}
}

/// Remove all folding for window win.
@(export)
clearFolding :: proc "c" (win: rawptr) {
	deleteFoldRecurse(w_ptr_at(win, W_BUFFER), w_ga(win, W_FOLDS))
	w_set_bool(win, W_FOLDINVALID, false)
}

/// Update folds for changes between top and bot (inclusive).
@(export)
foldUpdate :: proc "c" (wp: rawptr, top: C.int, bot: C.int) {
	if disable_fold_update != 0 || ((State & 0x100 /*MODE_INSERT*/) != 0 && !foldmethodIsIndent(wp)) {
		return
	}

	if need_diff_redraw {
		return // will update later
	}

	ga := w_ga(wp, W_FOLDS)
	if ga.ga_len > 0 {
		// Mark all folds between top and bot as maybe-small.
		maybe_small_start := min(top, bot)
		maybe_small_end := max(top, bot)

		fp: ^Fold_T = nil
		foldFind(ga, maybe_small_start, &fp)
		for uintptr(fp) < uintptr(ga.ga_data) + uintptr(C.int(ga.ga_len))*size_of(Fold_T) &&
		fp.fd_top <= maybe_small_end {
			fp.fd_small = .kNone
			fp = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
		}
	}

	if foldmethodIsIndent(wp) || foldmethodIsExpr(wp) ||
		foldmethodIsMarker(wp) || foldmethodIsDiff(wp) || foldmethodIsSyntax(wp) {
		save_got_int := got_int

		got_int = false
		foldUpdateIEMS(wp, top, bot)
		got_int = got_int || save_got_int
	}
}

/// Updates folds when leaving insert-mode.
@(export)
foldUpdateAfterInsert :: proc "c" () {
	if foldmethodIsManual(curwin) || foldmethodIsSyntax(curwin) || foldmethodIsExpr(curwin) {
		return
	}

	foldUpdateAll(curwin)
	foldOpenCursor()
}

/// Update all lines in a window for folding (deferred).
@(export)
foldUpdateAll :: proc "c" (win: rawptr) {
	w_set_bool(win, W_FOLDINVALID, true)
	redraw_later(win, UPD_NOT_VALID)
}

/// Move to start/end of fold or fold at same level. FAIL if not moved.
@(export)
foldMoveTo :: proc "c" (updown: bool, dir: C.int, count: C.int) -> C.int {
	retval: C.int = FAIL_R
	fp: ^Fold_T = nil

	checkupdate(curwin)

	for n: C.int = 0; n < count; n += 1 {
		lnum_off: C.int = 0
		gap := w_ga(curwin, W_FOLDS)
		if gap.ga_len == 0 {
			break
		}
		use_level := false
		maybe_small := false
		lnum_found := win_cursor_r(curwin).lnum
		level: C.int = 0
		last := false
		for true {
			if !foldFind(gap, win_cursor_r(curwin).lnum - lnum_off, &fp) {
				if !updown || gap.ga_len == 0 {
					break
				}

				// Consider a fold above/below the cursor.
				// NOTE: fp may be NULL here when the nested array is empty
				// (C relies on pointer arithmetic; we guard explicitly).
				if dir == FORWARD_F {
					if fp != nil && C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)) >= gap.ga_len {
						break
					}
					if fp != nil {
						fp = (^Fold_T)(uintptr(fp) - size_of(Fold_T))
					}
					// fp==nil: C's fp-- lands before the array; the fp[1]
					// access below then reads element 0 — replicated by the
					// fidx==-1 path in the updown block.
				} else {
					if fp != nil && uintptr(fp) == uintptr(gap.ga_data) {
						break
					}
				}
				last = true
			}

			if !last {
				if check_closed(curwin, fp, &use_level, level, &maybe_small, lnum_off) {
					last = true
				}
				if last && !updown {
					break
				}
			}

			if updown {
				if dir == FORWARD_F {
					// to start of next fold if there is one
					// (fp may be NULL here — treat as index -1, so fp[1] == element 0)
					fidx: C.int = -1
					if fp != nil {
						fidx = C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T))
					}
					if fidx + 1 < gap.ga_len {
						next_fp := fp_at(gap, fidx + 1)
						lnum2 := next_fp.fd_top + lnum_off
						if lnum2 > win_cursor_r(curwin).lnum {
							lnum_found = lnum2
						}
					}
				} else {
					// to end of previous fold if there is one
					if fp != nil && uintptr(fp) > uintptr(gap.ga_data) {
						prev_fp := (^Fold_T)(uintptr(fp) - size_of(Fold_T))
						lnum2 := prev_fp.fd_top + lnum_off + prev_fp.fd_len - 1
						if lnum2 < win_cursor_r(curwin).lnum {
							lnum_found = lnum2
						}
					}
				}
			} else {
				// Open fold: set cursor to its start/end.
				if dir == FORWARD_F {
					lnum2 := fp.fd_top + lnum_off + fp.fd_len - 1
					if lnum2 > win_cursor_r(curwin).lnum {
						lnum_found = lnum2
					}
				} else {
					lnum2 := fp.fd_top + lnum_off
					if lnum2 < win_cursor_r(curwin).lnum {
						lnum_found = lnum2
					}
				}
			}

			if last {
				break
			}

			// Check nested folds (if any).
			gap = &fp.fd_nested
			lnum_off += fp.fd_top
			level += 1
		}
		if lnum_found != win_cursor_r(curwin).lnum {
			if retval == FAIL_R {
				setpcmark()
			}
			win_cursor_r(curwin).lnum = lnum_found
			win_cursor_r(curwin).col = 0
			retval = OK_R
		} else {
			break
		}
	}

	return retval
}

/// Init fold info in a new window.
@(export)
foldInitWin :: proc "c" (new_win: rawptr) {
	ga_init_r2(w_ga(new_win, W_FOLDS), C.int(size_of(Fold_T)), 10)
}

/// Find entry in win->w_lines[] for buffer line lnum; -1 if not found.
@(export)
find_wl_entry :: proc "c" (win: rawptr, lnum: C.int) -> C.int {
	valid := w_i32(win, W_LINES_VALID)
	wlines := transmute([^]Wline_T)(w_ptr_at(win, W_LINES))
	for i: C.int = 0; i < valid; i += 1 {
		if wlines[i].wl_valid {
			if lnum < wlines[i].wl_lnum {
				return -1
			}
			if lnum <= wlines[i].wl_foldend {
				return i
			}
		}
	}
	return -1
}

/// Adjust Visual area to include any fold at start/end completely.
@(export)
foldAdjustVisual :: proc "c" () {
	if !VIsual_active || hasAnyFolding(curwin) == 0 {
		return
	}

	startp := &VIsual_g
	endp := win_cursor_r(curwin)
	if !lt_pos_f(VIsual_g, win_cursor_r(curwin)^) {
		startp = win_cursor_r(curwin)
		endp = &VIsual_g
	}
	if hasFolding(curwin, startp.lnum, &startp.lnum, nil) {
		startp.col = 0
	}

	if !hasFolding(curwin, endp.lnum, nil, &endp.lnum) {
		return
	}

	endp.col = ml_get_len_r2(endp.lnum)
	if endp.col > 0 && p_sel^ == 'o' {
		endp.col -= 1
	}
	mb_adjust_cursor_r()
}

lt_pos_f :: #force_inline proc "c"(a, b: Pos_T) -> bool {
	if a.lnum != b.lnum {
		return a.lnum < b.lnum
	} else if a.col != b.col {
		return a.col < b.col
	}
	return a.coladd < b.coladd
}

/// Move cursor to first line of closed fold.
@(export)
foldAdjustCursor :: proc "c" (wp: rawptr) {
	hasFolding(wp, win_cursor_r(wp).lnum, &win_cursor_r(wp).lnum, nil)
}

// ── Internal fold_T helpers ──────────────────────────────────────────────────

/// Deep-copy garray of folds.
@(export)
cloneFoldGrowArray :: proc "c" (from: ^Garray, to: ^Garray) {
	ga_init_r2(to, from.ga_itemsize, from.ga_growsize)

	if GA_EMPTY_F(from) {
		return
	}

	ga_grow_r(to, from.ga_len)

	from_p := transmute([^]Fold_T)(from.ga_data)
	to_p := transmute([^]Fold_T)(to.ga_data)

	for i: C.int = 0; i < from.ga_len; i += 1 {
		to_p[i].fd_top = from_p[i].fd_top
		to_p[i].fd_len = from_p[i].fd_len
		to_p[i].fd_flags = from_p[i].fd_flags
		to_p[i].fd_small = from_p[i].fd_small
		cloneFoldGrowArray(&from_p[i].fd_nested, &to_p[i].fd_nested)
		to.ga_len += 1
	}
}

/// Binary search for lnum in folds array. Sets fpp.
foldFind :: proc "c" (gap: ^Garray, lnum: C.int, fpp: ^^Fold_T) -> bool {
	if gap.ga_len == 0 {
		fpp^ = nil
		return false
	}

	low: C.int = 0
	high: C.int = gap.ga_len - 1
	for low <= high {
		i := (low + high) / 2
		fp := fp_at(gap, i)
		if fp.fd_top > lnum {
			high = i - 1
		} else if fp.fd_top + fp.fd_len <= lnum {
			low = i + 1
		} else {
			fpp^ = fp
			return true
		}
	}
	fpp^ = fp_at(gap, low)
	return false
}

/// Fold level at lnum in window wp.
foldLevelWin :: proc "c" (wp: rawptr, lnum: C.int) -> C.int {
	fp: ^Fold_T = nil
	lnum_rel := lnum
	level: C.int = 0

	gap := w_ga(wp, W_FOLDS)
	for true {
		if !foldFind(gap, lnum_rel, &fp) {
			break
		}
		gap = &fp.fd_nested
		lnum_rel -= fp.fd_top
		level += 1
	}

	return level
}

/// Check if folds are invalid and update if needed.
checkupdate :: proc "c" (wp: rawptr) {
	if !w_bool(wp, W_FOLDINVALID) {
		return
	}

	foldUpdate(wp, 1, MAXLNUM)
	w_set_bool(wp, W_FOLDINVALID, false)
}

setFoldRepeat :: proc "c" (pos: Pos_T, count: C.int, do_open: bool) {
	for n: C.int = 0; n < count; n += 1 {
		done: C.int = DONE_NOTHING
		setManualFold(pos, do_open, false, &done)
		if (done & DONE_ACTION) == 0 {
			if n == 0 && (done & DONE_FOLD) == 0 {
				emsg(_t(e_nofold))
			}
			break
		}
	}
}

setManualFold :: proc "c" (pos: Pos_T, opening: bool, recurse: bool, donep: ^C.int) -> C.int {
	if foldmethodIsDiff(curwin) && w_bool(curwin, W_P_SCB) {
		// Do same operation in other diff-mode windows.
		tp := first_tabpage
		for tp != nil {
			wp: rawptr = tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN)^
			for wp != nil {
				if wp != curwin && foldmethodIsDiff(wp) && w_bool(wp, W_P_SCB) {
					dlnum := diff_lnum_win_r(win_cursor_r(curwin).lnum, wp)
					if dlnum != 0 {
						setManualFoldWin(wp, dlnum, opening, recurse, nil)
					}
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT)^
		}
	}

	return setManualFoldWin(curwin, pos.lnum, opening, recurse, donep)
}

setManualFoldWin :: proc "c" (wp: rawptr, lnum_arg: C.int, opening: bool, recurse: bool, donep: ^C.int) -> C.int {
	lnum := lnum_arg
	fp: ^Fold_T = nil
	fp2: ^Fold_T = nil
	found: ^Fold_T = nil
	level: C.int = 0
	use_level := false
	found_fold := false
	next: C.int = MAXLNUM
	off: C.int = 0
	done: C.int = 0

	checkupdate(wp)

	gap := w_ga(wp, W_FOLDS)
	for true {
		if !foldFind(gap, lnum, &fp) {
			if fp != nil && C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)) < gap.ga_len {
				next = fp.fd_top + off
			}
			break
		}

		found_fold = true

		if C.int((uintptr(fp)+size_of(Fold_T)-uintptr(gap.ga_data))/size_of(Fold_T)) < gap.ga_len {
			next = fp_at(gap, C.int((uintptr(fp)-uintptr(gap.ga_data))/size_of(Fold_T))+1).fd_top + off
		}

		// Change from level-dependent to manual folding.
		if use_level || fp.fd_flags == FD_LEVEL {
			use_level = true
			fp.fd_flags = C.int(level) >= C.int(w_i64(wp, W_P_FDL)) ? FD_CLOSED : FD_OPEN
			nested := transmute([^]Fold_T)(fp.fd_nested.ga_data)
			for j: C.int = 0; j < fp.fd_nested.ga_len; j += 1 {
				nested[j].fd_flags = FD_LEVEL
			}
		}

		// Close recursively means closing the fold.
		if !opening && recurse {
			if fp.fd_flags != FD_CLOSED {
				done |= DONE_ACTION
				fp.fd_flags = FD_CLOSED
			}
		} else if fp.fd_flags == FD_CLOSED {
			if opening {
				fp.fd_flags = FD_OPEN
				done |= DONE_ACTION
				if recurse {
					foldOpenNested(fp)
				}
			}
			break
		}

		// fold is open, check nested folds
		found = fp
		gap = &fp.fd_nested
		lnum -= fp.fd_top
		off += fp.fd_top
		level += 1
	}
	if found_fold {
		if !opening && found != nil {
			found.fd_flags = FD_CLOSED
			done |= DONE_ACTION
		}
		w_set_bool(wp, W_FOLD_MANUAL, true)
		if (done & DONE_ACTION) != 0 {
			changed_window_setting_r(wp)
		}
		done |= DONE_FOLD
	} else if donep == nil && wp == curwin {
		emsg(_t(e_nofold))
	}

	if donep != nil {
		donep^ |= done
	}

	return next
}

foldOpenNested :: proc "c" (fpr: ^Fold_T) {
	nested := transmute([^]Fold_T)(fpr.fd_nested.ga_data)
	for i: C.int = 0; i < fpr.fd_nested.ga_len; i += 1 {
		foldOpenNested(&nested[i])
		nested[i].fd_flags = FD_OPEN
	}
}

deleteFoldEntry :: proc "c" (wp: rawptr, gap: ^Garray, idx: C.int, recursive: bool) {
	fp := fp_at(gap, idx)
	if recursive || GA_EMPTY_F(&fp.fd_nested) {
		deleteFoldRecurse(w_ptr_at(wp, W_BUFFER), &fp.fd_nested)
		gap.ga_len -= 1
		if idx < gap.ga_len {
			libc.memmove(fp, fp_at(gap, idx+1), size_of(Fold_T) * C.size_t(gap.ga_len - idx))
		}
	} else {
		moved := fp.fd_nested.ga_len
		ga_grow_r(gap, moved - 1)
		{
			// re-fetch fp, array may have been reallocated
			fp = fp_at(gap, idx)

			nfp := transmute([^]Fold_T)(fp.fd_nested.ga_data)
			for i: C.int = 0; i < moved; i += 1 {
				nfp[i].fd_top += fp.fd_top
				if fp.fd_flags == FD_LEVEL {
					nfp[i].fd_flags = FD_LEVEL
				}
				if fp.fd_small == .kNone {
					nfp[i].fd_small = .kNone
				}
			}

			if idx + 1 < gap.ga_len {
				libc.memmove(fp_at(gap, idx+moved), fp_at(gap, idx+1),
					size_of(Fold_T) * C.size_t(gap.ga_len - (idx + 1)))
			}
			libc.memmove(fp, nfp, size_of(Fold_T) * C.size_t(moved))
			xfree(nfp)
			gap.ga_len += moved - 1
		}
	}
}

/// Delete nested folds recursively.
@(export)
deleteFoldRecurse :: proc "c" (bp: rawptr, gap: ^Garray) {
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		deleteFoldRecurse(bp, &fp_at(gap, C.int(i)).fd_nested)
	}
	if gap.ga_data != nil {
		xfree(gap.ga_data)
		gap.ga_data = nil
	}
	gap.ga_len = 0
	gap.ga_maxlen = 0
}

/// Update line numbers of folds for inserted/deleted lines.
@(export)
foldMarkAdjust :: proc "c" (wp: rawptr, line1_arg: C.int, line2_arg: C.int, amount: C.int, amount_after: C.int) {
	line1 := line1_arg
	line2 := line2_arg
	if amount == MAXLNUM && line2 >= line1 && line2 - line1 >= -amount_after {
		line2 = line1 - amount_after - 1
	}
	if line2 < line1 {
		line2 = line1
	}
	if (State & 0x100 /*MODE_INSERT*/) != 0 && amount == 1 && line2 == MAXLNUM {
		line1 -= 1
	}
	foldMarkAdjustRecurse(wp, w_ga(wp, W_FOLDS), line1, line2, amount, amount_after)
}

foldMarkAdjustRecurse :: proc "c" (wp: rawptr, gap: ^Garray, line1: C.int, line2: C.int,
	amount: C.int, amount_after: C.int) {
	if gap.ga_len == 0 {
		return
	}

	top := ((State & 0x100) != 0 && amount == 1 && line2 == MAXLNUM) ? line1 + 1 : line1

	fp: ^Fold_T = nil
	foldFind(gap, line1, &fp)

	i := C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
	for i < gap.ga_len {
		fp = fp_at(gap, i)

		last := fp.fd_top + fp.fd_len - 1

		// 1. fold completely above line1: nothing to do
		if last < line1 {
			continue
		}

		// 6. fold below line2: only adjust for amount_after
		if fp.fd_top > line2 {
			if amount_after == 0 {
				break
			}
			fp.fd_top += amount_after
		} else {
			if fp.fd_top >= top && last <= line2 {
				// 4. fold completely contained in range
				if amount == MAXLNUM {
					deleteFoldEntry(wp, gap, i, true)
					i -= 1
				} else {
					fp.fd_top += amount
				}
			} else {
				if fp.fd_top < top {
					// 2 or 3: correct nested folds too
					foldMarkAdjustRecurse(wp, &fp.fd_nested, line1 - fp.fd_top,
						line2 - fp.fd_top, amount, amount_after)
					if last <= line2 {
						// 2. fold contains line1, line2 below fold
						if amount == MAXLNUM {
							fp.fd_len = line1 - fp.fd_top
						} else {
							fp.fd_len += amount
						}
					} else {
						// 3. fold contains line1 and line2
						fp.fd_len += amount_after
					}
				} else {
					// 5. fold below line1 containing line2
					if amount == MAXLNUM {
						foldMarkAdjustRecurse(wp, &fp.fd_nested, 0, line2 - fp.fd_top,
							amount, amount_after + (fp.fd_top - top))
						fp.fd_len -= line2 - fp.fd_top + 1
						fp.fd_top = line1
					} else {
						foldMarkAdjustRecurse(wp, &fp.fd_nested, 0, line2 - fp.fd_top,
							amount, amount_after - amount)
						fp.fd_len += amount_after - amount
						fp.fd_top += amount
					}
				}
			}
		}
		i += 1
	}
}

/// Lowest 'foldlevel' that makes deepest nested fold in wp.
@(export)
getDeepestNesting :: proc "c" (wp: rawptr) -> C.int {
	checkupdate(wp)
	return getDeepestNestingRecurse(w_ga(wp, W_FOLDS))
}

getDeepestNestingRecurse :: proc "c" (gap: ^Garray) -> C.int {
	maxlevel: C.int = 0

	for i: C.int = 0; i < gap.ga_len; i += 1 {
		level := getDeepestNestingRecurse(&fp_at(gap, C.int(i)).fd_nested) + 1
		maxlevel = max(maxlevel, level)
	}

	return maxlevel
}

/// Check if fold is closed; updates nested-fold info.
check_closed :: proc "c" (wp: rawptr, fp: ^Fold_T, use_levelp: ^bool, level: C.int,
	maybe_smallp: ^bool, lnum_off: C.int) -> bool {
	closed := false

	if use_levelp^ || fp.fd_flags == FD_LEVEL {
		use_levelp^ = true
		if C.int(level) >= C.int(w_i64(wp, W_P_FDL)) {
			closed = true
		}
	} else if fp.fd_flags == FD_CLOSED {
		closed = true
	}

	if fp.fd_small == .kNone {
		maybe_smallp^ = true
	}
	if closed {
		if maybe_smallp^ {
			fp.fd_small = .kNone
		}
		checkSmall(wp, fp, lnum_off)
		if fp.fd_small == .kTrue {
			closed = false
		}
	}
	return closed
}

checkSmall :: proc "c" (wp: rawptr, fp: ^Fold_T, lnum_off: C.int) {
	if fp.fd_small != .kNone {
		return
	}

	setSmallMaybe(&fp.fd_nested)

	if i64(fp.fd_len) > w_i64(wp, W_P_FML) {
		fp.fd_small = .kFalse
	} else {
		count: C.int = 0
		for n: C.int = 0; n < fp.fd_len; n += 1 {
			count += plines_win_nofold_r(wp, fp.fd_top + lnum_off + n)
			if i64(count) > w_i64(wp, W_P_FML) {
				fp.fd_small = .kFalse
				return
			}
		}
		fp.fd_small = .kTrue
	}
}

setSmallMaybe :: proc "c" (gap: ^Garray) {
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		fp_at(gap, C.int(i)).fd_small = .kNone
	}
}

// ── Marker folding ───────────────────────────────────────────────────────────

foldCreateMarkers :: proc "c" (wp: rawptr, start: Pos_T, end: Pos_T) {
	buf := w_ptr_at(wp, W_BUFFER)
	if !w_bool(buf, B_P_MA) {
		emsg(e_modifiable_u)
		return
	}
	parseMarker(wp)

	foldAddMarker(buf, start, w_str(wp, W_P_FMR), foldstartmarkerlen)
	foldAddMarker(buf, end, foldendmarker, foldendmarkerlen)

	changed_lines_r(buf, start.lnum, 0, end.lnum, 0, false)

	num_changed := i64(1 + end.lnum - start.lnum)
	buf_updates_send_changes_r(buf, start.lnum, num_changed, num_changed)
}

e_modifiable_u: cstring = "E21: Cannot make changes, 'modifiable' is off"

foldAddMarker :: proc "c" (buf: rawptr, pos: Pos_T, marker: ^u8, markerlen: C.size_t) {
	cms := w_str(buf, B_P_CMS)
	p := strstr_r(transmute(cstring)(cms), cstring("%s"))
	line_is_comment := false
	lnum := pos.lnum

	line := ml_get_buf(buf, lnum)
	line_len := C.size_t(ml_get_buf_len(buf, lnum))
	added: C.size_t = 0

	if u_save(lnum - 1, lnum + 1) != OK_R {
		return
	}

	skip_comment_r(line, false, false, &line_is_comment)
	newline := (^u8)(xmalloc(line_len + markerlen + libc.strlen(transmute(cstring)(cms)) + 1))
	libc.memcpy(newline, line, line_len + 1)
	if p == nil || line_is_comment {
		_xmemcpyz((^u8)(uintptr(newline) + uintptr(line_len)), marker, markerlen)
		added = markerlen
	} else {
		cms_p := C.size_t(uintptr(p) - uintptr(transmute(rawptr)(cms)))
		libc.memcpy((^u8)(uintptr(newline) + uintptr(line_len)), cms, cms_p + 1)
		libc.memcpy((^u8)(uintptr(newline) + uintptr(line_len) + uintptr(cms_p)), marker, markerlen)
		tail := (^u8)(uintptr(p) + 2)
		libc.memcpy((^u8)(uintptr(newline) + uintptr(line_len) + uintptr(cms_p) + uintptr(markerlen)),
			transmute(rawptr)(tail), libc.strlen(transmute(cstring)(tail)) + 1)
		added = C.size_t(markerlen) + libc.strlen(transmute(cstring)(cms)) - 2
	}
	ml_replace_buf_r(buf, lnum, newline, false, false)
	if added != 0 {
		extmark_splice_cols_r(buf, lnum - 1, C.int(line_len), 0, C.int(added), kExtmarkUndo)
	}
}

deleteFoldMarkers :: proc "c" (wp: rawptr, fp: ^Fold_T, recursive: bool, lnum_off: C.int) {
	if recursive {
		nested := transmute([^]Fold_T)(fp.fd_nested.ga_data)
		for i: C.int = 0; i < fp.fd_nested.ga_len; i += 1 {
			deleteFoldMarkers(wp, &nested[i], true, lnum_off + fp.fd_top)
		}
	}
	foldDelMarker(w_ptr_at(wp, W_BUFFER), fp.fd_top + lnum_off, w_str(wp, W_P_FMR),
		foldstartmarkerlen)
	foldDelMarker(w_ptr_at(wp, W_BUFFER), fp.fd_top + lnum_off + fp.fd_len - 1,
		foldendmarker, foldendmarkerlen)
}

/// Delete marker at end of line lnum (with 'commentstring' if it matches).
foldDelMarker :: proc "c" (buf: rawptr, lnum: C.int, marker: ^u8, markerlen: C.size_t) {
	if lnum > ml_line_count_b(buf) {
		return
	}

	cms := w_str(buf, B_P_CMS)
	line := ml_get_buf(buf, lnum)
	p := line
	for p^ != 0 {
		if libc.strncmp(transmute(cstring)(p), transmute(cstring)(marker), markerlen) != 0 {
			p = (^u8)(uintptr(p) + 1)
			continue
		}
		length := markerlen
		if ascii_isdigit_u(((^u8)(uintptr(p) + uintptr(length)))^) {
			length += 1
		}
		if cms^ != 0 {
			cms2 := strstr_r(transmute(cstring)(cms), cstring("%s"))
			cms_off := uintptr(cms2) - uintptr(transmute(rawptr)(cms))
			tail2 := (^u8)(uintptr(cms2) + 2)
			if cms2 != nil &&
				uintptr(p)-uintptr(line) >= cms_off &&
				libc.strncmp(transmute(cstring)((^u8)(uintptr(p)-cms_off)),
					transmute(cstring)(cms), C.size_t(cms_off)) == 0 &&
				libc.strncmp(transmute(cstring)((^u8)(uintptr(p)+uintptr(length))), transmute(cstring)(tail2), libc.strlen(transmute(cstring)(tail2))) == 0 {
				p = (^u8)(uintptr(p) - cms_off)
				length += libc.strlen(transmute(cstring)(cms)) - 2
			}
		}
		if u_save(lnum - 1, lnum + 1) == OK_R {
			newline := (^u8)(xmalloc(C.size_t(ml_get_buf_len(buf, lnum)) - C.size_t(length) + 1))
			libc.memcpy(newline, line, C.size_t(uintptr(p) - uintptr(line)))
			libc.memcpy((^u8)(uintptr(newline) + (uintptr(p) - uintptr(line))), transmute(rawptr)((^u8)(uintptr(p)+uintptr(length))),
				libc.strlen(transmute(cstring)((^u8)(uintptr(p)+uintptr(length)))) + 1)
			ml_replace_buf_r(buf, lnum, newline, false, false)
			extmark_splice_cols_r(buf, lnum - 1, C.int(uintptr(p) - uintptr(line)),
				C.int(length), 0, kExtmarkUndo)
		}
		break
	}
}

ascii_isdigit_u :: #force_inline proc "c"(b: u8) -> bool {
	return b >= '0' && b <= '9'
}

// ── get_foldtext / foldtext_cleanup ──────────────────────────────────────────

/// Generates text to display for a closed fold.
@(export)
get_foldtext :: proc "c" (wp: rawptr, lnum: C.int, lnume: C.int, foldinfo: Foldinfo_T,
	buf: ^u8, vt: ^Kvec_VT) -> ^u8 {
	text: ^u8 = nil
	save_did_emsg := did_emsg_g()

	if last_wp == nil || last_wp != wp || last_lnum > lnum || last_lnum == 0 {
		got_fdt_error = false
	}

	if !got_fdt_error {
		did_emsg_set(false)
	}

	if w_str(wp, W_P_FDT)^ != 0 {
		dashes: [MAX_LEVEL + 2]u8

		set_vim_var_nr(VV_FOLDSTART, i64(lnum))
		set_vim_var_nr(VV_FOLDEND, i64(lnume))

		level := min(foldinfo.fi_level, C.int(size_of(dashes)) - 1)
		libc.memset(&dashes[0], '-', C.size_t(level))
		dashes[level] = 0
		set_vim_var_string(VV_FOLDDASHES, transmute(cstring)(&dashes[0]), C.ssize_t(level))
		set_vim_var_nr(VV_FOLDLEVEL, i64(level))

		if !got_fdt_error {
			save_curwin := curwin
			saved_sctx := current_sctx_buf

			curwin = wp
			curbuf = w_ptr_at(wp, W_BUFFER)
			libc.memcpy(&current_sctx_buf[0],
				(^rawptr)(uintptr(wp) + W_P_SCRIPT_CTX + uintptr(kWinOptFoldtext) * SCCTX_STRIDE),
				SCCTX_STRIDE)

			emsg_off += 1

			obj := eval_foldtext_r(wp)
			if obj.t == kObjectTypeString_API { // kObjectTypeString
				text = (^Api_String)(uintptr(&obj) + 8)^.data
			} else if obj.t == kObjectTypeArray_API { // kObjectTypeArray
				err: Api_Error
				vt2 := parse_virt_text_r((^Kvec_Obj)(uintptr(&obj)+8)^, &err, nil, false)
			if err.msg == nil {
				(^u8)(buf)^ = 0
				text = buf
			}
				api_clear_error_r(&err)
				// free the array object contents
				arr := (^Kvec_Obj)(uintptr(&obj) + 8)^
				for k: C.size_t = 0; k < arr.n; k += 1 {
					api_free_object_r((^Api_Object)(uintptr(arr.items) + uintptr(k) * size_of(Api_Object))^)
				}
				xfree(arr.items)
			}
			// NOTE: for other types just free.
			if obj.t != kObjectTypeString_API && obj.t != kObjectTypeArray_API && obj.t != 0 {
				api_free_object_r(obj)
			}

			emsg_off -= 1

			if text == nil || did_emsg_g() != 0 {
				got_fdt_error = true
			}

			curwin = save_curwin
			curbuf = w_ptr_at(curwin, W_BUFFER)
			current_sctx_buf = saved_sctx
		}
		last_lnum = lnum
		last_wp = wp
		set_vim_var_string(VV_FOLDDASHES, nil, -1)

		if did_emsg_g() == 0 && save_did_emsg != 0 {
			did_emsg_set(save_did_emsg != 0)
		}

		if text != nil {
			p := text
			for p^ != 0 {
				length := C.int(utfc_ptr2len(transmute(cstring)(p)))
				if length > 1 {
					if !vim_isprintc(utf_ptr2char(transmute(cstring)(p))) {
						break
					}
					p = (^u8)(uintptr(p) + uintptr(length) - 1)
				} else if p^ == '\t' {
					p^ = ' '
				} else if ptr2cells(transmute(cstring)(p)) > 1 {
					break
				}
				p = (^u8)(uintptr(p) + 1)
			}
			if p^ != 0 {
				p = transstr_r(transmute(cstring)(text), true)
				xfree(text)
				text = p
			}
		}
	}
	if text == nil {
		count := lnume - lnum + 1
		fmt := ngettext_f(cstring("+--%3d line folded"), cstring("+--%3d lines folded "), C.long(count))
		libc.snprintf(buf, FOLD_TEXT_LEN, _t(fmt), C.int(count))
		text = buf
	}
	return text
}

foreign _ {
	@(link_name = "did_emsg")
	did_emsg_flag: C.int
}

did_emsg_g :: #force_inline proc "c"() -> C.int { return did_emsg_flag }
did_emsg_set :: #force_inline proc "c"(v: bool) { did_emsg_flag = v ? 1 : 0 }

ngettext_f :: proc "c" (a, b: cstring, n: C.long) -> cstring {
	return ngettext_r(a, b, n)
}

kObjectTypeArray_API :: 5

// ── foldtext_cleanup ─────────────────────────────────────────────────────────

foldtext_cleanup :: proc "c" (str: ^u8) {
	cms_start := (^u8)(skipwhite(transmute(cstring)(w_str(curbuf, B_P_CMS))))
	cms_slen := libc.strlen(transmute(cstring)(cms_start))
	for cms_slen > 0 && ascii_iswhite_u((^u8)(uintptr(cms_start)+uintptr(cms_slen)-1)^) {
		cms_slen -= 1
	}

	cms_end := strstr_r(transmute(cstring)(cms_start), cstring("%s"))
	cms_elen: C.size_t = 0
	if cms_end != nil {
		cms_elen = cms_slen - C.size_t(uintptr(cms_end) - uintptr(transmute(rawptr)(cms_start)))
		cms_slen = C.size_t(uintptr(cms_end) - uintptr(transmute(rawptr)(cms_start)))

		for cms_slen > 0 && ascii_iswhite_u((^u8)(uintptr(cms_start)+uintptr(cms_slen)-1)^) {
			cms_slen -= 1
		}

		s := (^u8)(skipwhite(transmute(cstring)((^u8)(uintptr(cms_end) + 2))))
		cms_elen -= C.size_t(uintptr(s) - uintptr(cms_end))
		cms_end = transmute(^u8)(s)
	}
	parseMarker(curwin)

	did1 := false
	did2 := false

	s := str
	for s^ != 0 {
		length: C.size_t = 0
		if libc.strncmp(transmute(cstring)(s), transmute(cstring)(w_str(curwin, W_P_FMR)), foldstartmarkerlen) == 0 {
			length = foldstartmarkerlen
		} else if libc.strncmp(transmute(cstring)(s), transmute(cstring)(foldendmarker), foldendmarkerlen) == 0 {
			length = foldendmarkerlen
		}
		if length > 0 {
			if ascii_isdigit_u((^u8)(uintptr(s)+uintptr(length))^) {
				length += 1
			}

			p := s
			for uintptr(p) > uintptr(str) && ascii_iswhite_u(((^u8)(uintptr(p)-1))^) {
				p = (^u8)(uintptr(p) - 1)
			}
			if uintptr(p) >= uintptr(str)+uintptr(cms_slen) &&
				libc.strncmp(transmute(cstring)((^u8)(uintptr(p)-uintptr(cms_slen))),
					transmute(cstring)(cms_start), cms_slen) == 0 {
				length += C.size_t(uintptr(s) - uintptr(p)) + cms_slen
				s = (^u8)(uintptr(p) - uintptr(cms_slen))
			}
		} else if cms_end != nil {
			if !did1 && cms_slen > 0 && libc.strncmp(transmute(cstring)(s), transmute(cstring)(cms_start), cms_slen) == 0 {
				length = cms_slen
				did1 = true
			} else if !did2 && cms_elen > 0 && libc.strncmp(transmute(cstring)(s), transmute(cstring)(cms_end), cms_elen) == 0 {
				length = cms_elen
				did2 = true
			}
		}
		if length != 0 {
			for ascii_iswhite_u((^u8)(uintptr(s)+uintptr(length))^) {
				length += 1
			}
			strmove(s, (^u8)(uintptr(s) + uintptr(length)))
		} else {
			s = (^u8)(uintptr(s) + uintptr(utfc_ptr2len(transmute(cstring)(s))))
		}
	}
}

ascii_iswhite_u :: #force_inline proc "c"(b: u8) -> bool {
	return b == ' ' || b == '\t'
}

strmove :: #force_inline proc "c"(dst: ^u8, src: ^u8) {
	len := libc.strlen(transmute(cstring)(src))
	libc.memmove(dst, src, len + 1)
}

foreign _ {
	@(link_name = "get_vim_var_nr")
	get_vim_var_nr_f :: proc "c" (idx: C.int) -> i64 ---
}

foreign _ {
	@(link_name = "strstr")
	strstr_r :: proc "c" (haystack, needle: cstring) -> ^u8 ---
}

// ── foldUpdateIEMS / Recurse ─────────────────────────────────────────────────

foldUpdateIEMS :: proc "c" (wp: rawptr, top_arg: C.int, bot_arg: C.int) {
	top := top_arg
	bot := bot_arg
	// Avoid recursive calls.
	if invalid_top != 0 {
		return
	}

	if w_bool(wp, W_FOLDINVALID) {
		top = 1
		bot = ml_line_count_b(w_ptr_at(wp, W_BUFFER))
		w_set_bool(wp, W_FOLDINVALID, false)
		setSmallMaybe(w_ga(wp, W_FOLDS))
	}

	if foldmethodIsDiff(wp) {
		if top > diff_context_g {
			top -= diff_context_g
		} else {
			top = 1
		}
		bot += diff_context_g
	}

	top = min(top, ml_line_count_b(w_ptr_at(wp, W_BUFFER)))

	fline: Fline_T

	fold_changed = false
	fline.wp = wp
	fline.off = 0
	fline.lvl = 0
	fline.lvl_next = -1
	fline.start = 0
	fline.end = MAX_LEVEL + 1
	fline.had_end = MAX_LEVEL + 1

	invalid_top = top
	invalid_bot = bot

	getlevel: LevelGetter = nil

	if foldmethodIsMarker(wp) {
		getlevel = foldlevelMarker

		parseMarker(wp)

		if top > 1 {
			level := foldLevelWin(wp, top - 1)

			fline.lnum = top - 1
			fline.lvl = level
			getlevel(&fline)

			if fline.lvl > level {
				fline.lvl = level - (fline.lvl - fline.lvl_next)
			} else {
				fline.lvl = fline.lvl_next
			}
		}
		fline.lnum = top
		getlevel(&fline)
	} else {
		fline.lnum = top
		if foldmethodIsExpr(wp) {
			getlevel = foldlevelExpr
			if top > 1 {
				fline.lnum -= 1
			}
		} else if foldmethodIsSyntax(wp) {
			getlevel = foldlevelSyntax
		} else if foldmethodIsDiff(wp) {
			getlevel = foldlevelDiff
		} else {
			getlevel = foldlevelIndent
			if top > 1 {
				fline.lnum -= 1
			}
		}

		// Backup to a line with defined fold level.
		fline.lvl = -1
		for !got_int {
			fline.lvl_next = -1
			getlevel(&fline)
			if fline.lvl >= 0 {
				break
			}
			fline.lnum -= 1
		}
	}

	// Syntax folds: extend bot to end of current containing fold.
	if getlevel == foldlevelSyntax {
		gap := w_ga(wp, W_FOLDS)
		fpn: ^Fold_T = nil
		current_fdl := 0
		fold_start_lnum: C.int = 0
		lnum_rel := fline.lnum

		for current_fdl: C.int = 0; current_fdl < fline.lvl; current_fdl += 1 {
			if !foldFind(gap, lnum_rel, &fpn) {
				break
			}
			current_fdl += 1

			fold_start_lnum += fpn.fd_top
			gap = &fpn.fd_nested
			lnum_rel -= fpn.fd_top
		}
		if fpn != nil && C.int(current_fdl) == fline.lvl {
			fold_end_lnum := fold_start_lnum + fpn.fd_len
			bot = max(bot, fold_end_lnum)
		}
	}

	start := fline.lnum
	end := bot
	if start > end && end < ml_line_count_b(w_ptr_at(wp, W_BUFFER)) {
		end = start
	}

	fp: ^Fold_T = nil

	for !got_int {
		if fline.lnum > ml_line_count_b(w_ptr_at(wp, W_BUFFER)) {
			break
		}
		if fline.lnum > end {
			if getlevel != foldlevelMarker && getlevel != foldlevelSyntax && getlevel != foldlevelExpr {
				break
			}
			if (start <= end && foldFind(w_ga(wp, W_FOLDS), end, &fp) &&
				fp.fd_top + fp.fd_len - 1 > end) ||
				(fline.lvl == 0 && foldFind(w_ga(wp, W_FOLDS), fline.lnum, &fp) &&
				fp.fd_top < fline.lnum) {
				end = fp.fd_top + fp.fd_len - 1
			} else if getlevel == foldlevelSyntax &&
				foldLevelWin(wp, fline.lnum) != fline.lvl {
				end = fline.lnum
			} else {
				break
			}
		}

		if fline.lvl > 0 {
			invalid_top = fline.lnum
			invalid_bot = end
			end = foldUpdateIEMSRecurse(w_ga(wp, W_FOLDS), 1, start, &fline, getlevel, end, FD_LEVEL)
			start = fline.lnum
		} else {
			if fline.lnum == ml_line_count_b(w_ptr_at(wp, W_BUFFER)) {
				break
			}
			fline.lnum += 1
			fline.lvl = fline.lvl_next
			getlevel(&fline)
		}
	}

	foldRemove(wp, w_ga(wp, W_FOLDS), start, end)

	if fold_changed && w_bool(wp, W_P_FEN) {
		changed_window_setting_r(wp)
	}

	if end != bot {
		redraw_win_range_later(wp, top, end)
	}

	invalid_top = 0
}

foldUpdateIEMSRecurse :: proc "c" (gap: ^Garray, level: C.int, startlnum: C.int,
	flp: ^Fline_T, getlevel: LevelGetter, bot_arg: C.int, topflags: u8) -> C.int {
	bot := bot_arg
	fp: ^Fold_T = nil

	if getlevel == foldlevelMarker && flp.start <= flp.lvl - level && flp.lvl > 0 {
		foldFind(gap, startlnum - 1, &fp)
		if fp != nil && (C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)) >= gap.ga_len
			|| fp.fd_top >= startlnum) {
			fp = nil
		}
	}

	fp2: ^Fold_T = nil
	lvl := level
	startlnum2 := startlnum
	firstlnum := flp.lnum
	finish := false
	linecount := ml_line_count_b(w_ptr_at(flp.wp, W_BUFFER)) - flp.off

	flp.lnum_save = flp.lnum
	for !got_int {
		line_breakcheck()

		lvl = min(flp.lvl, MAX_LEVEL)
		if flp.lnum > firstlnum && (level > lvl - flp.start || C.int(level) >= flp.had_end) {
			lvl = 0
		}

		if flp.lnum > bot && !finish && fp != nil {
			if getlevel != foldlevelMarker && getlevel != foldlevelExpr && getlevel != foldlevelSyntax {
				break
			}
			i := 0
			fp2 = fp
			if lvl >= level {
				ll := flp.lnum - fp.fd_top
				for foldFind(&fp2.fd_nested, ll, &fp2) {
					i += 1
					ll -= fp2.fd_top
				}
			}
			if lvl < C.int(level) + C.int(i) {
				foldFind(&fp.fd_nested, flp.lnum - fp.fd_top, &fp2)
				if fp2 != nil {
					bot = fp2.fd_top + fp2.fd_len - 1 + fp.fd_top
				}
			} else if fp.fd_top + fp.fd_len <= flp.lnum && lvl >= level {
				finish = true
			} else {
				break
			}
		}

		if fp == nil && (lvl != level ||
			flp.lnum_save >= bot ||
			flp.start != 0 ||
			flp.had_end <= MAX_LEVEL ||
			flp.lnum == linecount) {
			for !got_int {
				concat := (flp.start != 0 || flp.had_end <= MAX_LEVEL) ? 0 : 1

				gi := C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T))
				found := false
				if gap.ga_len > 0 {
					if foldFind(gap, startlnum, &fp) {
						found = true
					} else if gi >= 0 && gi < gap.ga_len && fp.fd_top <= firstlnum {
						found = true
					} else if foldFind(gap, firstlnum - C.int(concat), &fp) {
						found = true
					} else {
						gi = C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T))
						if gi >= 0 && gi < gap.ga_len &&
							((lvl < level && fp.fd_top < flp.lnum) ||
							 (lvl >= level && fp.fd_top <= flp.lnum_save)) {
							found = true
						}
					}
				}
				if found {
					if fp.fd_top + fp.fd_len + C.int(concat) > firstlnum {
						if fp.fd_top == firstlnum {
							// exact match
						} else if fp.fd_top >= startlnum {
							if fp.fd_top > firstlnum {
								foldMarkAdjustRecurse(flp.wp, &fp.fd_nested,
									0, MAXLNUM, fp.fd_top - firstlnum, 0)
							} else {
								foldMarkAdjustRecurse(flp.wp, &fp.fd_nested,
									0, firstlnum - fp.fd_top - 1,
									MAXLNUM, fp.fd_top - firstlnum)
							}
							fp.fd_len += fp.fd_top - firstlnum
							fp.fd_top = firstlnum
							fp.fd_small = .kNone
							fold_changed = true
						} else if (flp.start != 0 && lvl == level) || (firstlnum != startlnum) {
							breakstart: C.int
							breakend: C.int
							if firstlnum != startlnum {
								breakstart = startlnum
								breakend = firstlnum
							} else {
								breakstart = flp.lnum
								breakend = flp.lnum
							}
							foldRemove(flp.wp, &fp.fd_nested, breakstart - fp.fd_top,
								breakend - fp.fd_top)
							idx := C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
							foldSplit(w_ptr_at(flp.wp, W_BUFFER), gap, idx, breakstart, breakend - 1)
							fp = fp_at(gap, idx + 1)
							if getlevel == foldlevelMarker || getlevel == foldlevelExpr || getlevel == foldlevelSyntax {
								finish = true
							}
						}
						if fp.fd_top == startlnum && concat != 0 {
							idx := C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
							if idx != 0 {
								fp2 = fp_at(gap, idx - 1)
								if fp2.fd_top + fp2.fd_len == fp.fd_top {
									foldMerge(flp.wp, fp2, gap, fp)
									fp = fp2
								}
							}
						}
						break
					}
					if fp.fd_top >= startlnum {
						deleteFoldEntry(flp.wp, gap,
							C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)), true)
					} else {
						fp.fd_len = startlnum - fp.fd_top
						foldMarkAdjustRecurse(flp.wp, &fp.fd_nested,
							fp.fd_len, MAXLNUM, MAXLNUM, 0)
						fold_changed = true
					}
				} else {
					// Insert new fold.
					i := C.int(0)
					if gap.ga_len != 0 {
						i = C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
					}
					foldInsert(gap, i)
					fp = fp_at(gap, i)
					fp.fd_top = firstlnum
					fp.fd_len = bot - firstlnum + 1
					if topflags == FD_OPEN {
						w_set_bool(flp.wp, W_FOLD_MANUAL, true)
						fp.fd_flags = FD_OPEN
					} else if i <= 0 {
						fp.fd_flags = topflags
						if topflags != FD_LEVEL {
							w_set_bool(flp.wp, W_FOLD_MANUAL, true)
						}
					} else {
						fp.fd_flags = fp_at(gap, i-1).fd_flags
					}
					fp.fd_small = .kNone
					if getlevel == foldlevelMarker || getlevel == foldlevelExpr || getlevel == foldlevelSyntax {
						finish = true
					}
					fold_changed = true
					break
				}
			}
		}

		if lvl < level || flp.lnum > linecount {
			break
		}

		if lvl > level && fp != nil {
			// Nested fold: recurse.
			bot = max(bot, flp.lnum)

			flp.lnum = flp.lnum_save - fp.fd_top
			flp.off += fp.fd_top
			i := C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
			bot = foldUpdateIEMSRecurse(&fp.fd_nested, level + 1,
				startlnum2 - fp.fd_top, flp, getlevel, bot - fp.fd_top, fp.fd_flags)
			fp = fp_at(gap, i)
			flp.lnum += fp.fd_top
			flp.lnum_save += fp.fd_top
			flp.off -= fp.fd_top
			bot += fp.fd_top
			startlnum2 = flp.lnum
		} else {
			// Get the level of the next line.
			flp.lnum = flp.lnum_save
			ll := flp.lnum + 1
			for !got_int {
				prev_lnum = flp.lnum
				prev_lnum_lvl = flp.lvl

				flp.lnum += 1
				if flp.lnum > linecount {
					break
				}
				flp.lvl = flp.lvl_next
				getlevel(flp)
				if flp.lvl >= 0 || flp.had_end <= MAX_LEVEL {
					break
				}
			}
			prev_lnum = 0
			if flp.lnum > linecount {
				break
			}

			flp.lnum_save = flp.lnum
			flp.lnum = ll
		}
	}

	if fp == nil { // only when got_int set
		return bot
	}

	// Fold extends at least to lnum.
	if fp.fd_len < flp.lnum - fp.fd_top {
		fp.fd_len = flp.lnum - fp.fd_top
		fp.fd_small = .kNone
		fold_changed = true
	} else if fp.fd_top + fp.fd_len > linecount {
		fp.fd_len = linecount - fp.fd_top + 1
	}

	foldRemove(flp.wp, &fp.fd_nested, startlnum2 - fp.fd_top, flp.lnum - 1 - fp.fd_top)

	if lvl < level {
		if fp.fd_len != flp.lnum - fp.fd_top {
			if fp.fd_top + fp.fd_len - 1 > bot {
				if getlevel == foldlevelMarker || getlevel == foldlevelExpr || getlevel == foldlevelSyntax {
					bot = fp.fd_top + fp.fd_len - 1
					fp.fd_len = flp.lnum - fp.fd_top
				} else {
					i := C.int(uintptr(fp)-uintptr(gap.ga_data)) / C.int(size_of(Fold_T))
					foldSplit(w_ptr_at(flp.wp, W_BUFFER), gap, i, flp.lnum, bot)
					fp = fp_at(gap, i)
				}
			} else {
				fp.fd_len = flp.lnum - fp.fd_top
			}
			fold_changed = true
		}
	}

	// delete following folds that end before the current line
	for true {
		fp2 = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
		if C.int(uintptr(fp2)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)) >= gap.ga_len ||
			fp2.fd_top > flp.lnum {
			break
		}
		if fp2.fd_top + fp2.fd_len > flp.lnum {
			if fp2.fd_top < flp.lnum {
				foldMarkAdjustRecurse(flp.wp, &fp2.fd_nested,
					0, flp.lnum - fp2.fd_top - 1, MAXLNUM, fp2.fd_top - flp.lnum)
				fp2.fd_len -= flp.lnum - fp2.fd_top
				fp2.fd_top = flp.lnum
				fold_changed = true
			}

			if lvl >= level {
				foldMerge(flp.wp, fp, gap, fp2)
			}
			break
		}
		fold_changed = true
		deleteFoldEntry(flp.wp, gap,
			C.int(uintptr(fp2)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)), true)
	}

	bot = max(bot, flp.lnum - 1)

	return bot
}

// ── foldInsert / foldSplit / foldRemove / foldMerge / foldMoveRange ─────────

foldInsert :: proc "c" (gap: ^Garray, i: C.int) {
	ga_grow_r(gap, 1)

	fp := fp_at(gap, i)
	if gap.ga_len > 0 && i < gap.ga_len {
		libc.memmove(fp_at(gap, i+1), fp, size_of(Fold_T) * C.size_t(gap.ga_len - i))
	}
	gap.ga_len += 1
	ga_init_r2(&fp.fd_nested, C.int(size_of(Fold_T)), 10)
}

foldSplit :: proc "c" (buf: rawptr, gap: ^Garray, i: C.int, top: C.int, bot: C.int) {
	_ = buf
	foldInsert(gap, i + 1)

	fp := fp_at(gap, i)
	nfp := fp_at(gap, i + 1)
	nfp.fd_top = bot + 1
	nfp.fd_len = fp.fd_len - (nfp.fd_top - fp.fd_top)
	nfp.fd_flags = fp.fd_flags
	nfp.fd_small = .kNone
	fp.fd_small = .kNone

	gap1 := &fp.fd_nested
	gap2 := &nfp.fd_nested
	fp2: ^Fold_T = nil
	foldFind(gap1, bot + 1 - fp.fd_top, &fp2)
	if fp2 != nil {
		length := gap1.ga_len - C.int(uintptr(fp2)-uintptr(gap1.ga_data))/C.int(size_of(Fold_T))
		if length > 0 {
			ga_grow_r(gap2, length)
			for idx: C.int = 0; idx < length; idx += 1 {
				dst := fp_at(gap2, C.int(idx))
				src := (^Fold_T)(uintptr(fp2) + uintptr(idx) * size_of(Fold_T))
				dst^ = src^
				dst.fd_top -= nfp.fd_top - fp.fd_top
			}
			gap2.ga_len = length
			gap1.ga_len -= length
		}
	}
	fp.fd_len = top - fp.fd_top
	fold_changed = true
}

foldRemove :: proc "c" (wp: rawptr, gap: ^Garray, top: C.int, bot: C.int) {
	if bot < top {
		return
	}

	fp: ^Fold_T = nil

	for gap.ga_len > 0 {
		if foldFind(gap, top, &fp) && fp.fd_top < top {
			// 2/3: delete nested folds
			foldRemove(wp, &fp.fd_nested, top - fp.fd_top, bot - fp.fd_top)
			if fp.fd_top + fp.fd_len - 1 > bot {
				// 3: split it
				foldSplit(w_ptr_at(wp, W_BUFFER), gap,
					C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)), top, bot)
			} else {
				// 2: truncate at top
				fp.fd_len = top - fp.fd_top
			}
			fold_changed = true
			continue
		}
		if gap.ga_data == nil ||
			C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)) >= gap.ga_len ||
			fp.fd_top > bot {
			break // 6: below bot
		}
		if fp.fd_top >= top {
			fold_changed = true
			if fp.fd_top + fp.fd_len - 1 > bot {
				// 5: start below bot
				foldMarkAdjustRecurse(wp, &fp.fd_nested,
					0, bot - fp.fd_top, MAXLNUM, fp.fd_top - bot - 1)
				fp.fd_len -= bot - fp.fd_top + 1
				fp.fd_top = bot + 1
				break
			}

			// 4: delete completely contained fold.
			deleteFoldEntry(wp, gap,
				C.int(uintptr(fp)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)), true)
		}
	}
}

foldReverseOrder :: proc "c" (gap: ^Garray, start_arg: C.int, end_arg: C.int) {
	start := start_arg
	end := end_arg
	for start < end {
		left := fp_at(gap, start)
		right := fp_at(gap, end)
		tmp := left^
		left^ = right^
		right^ = tmp
		start += 1
		end -= 1
	}
}

truncate_fold :: proc "c" (wp: rawptr, fp: ^Fold_T, end_arg: C.int) {
	end := end_arg
	end += 1
	foldRemove(wp, &fp.fd_nested, end - fp.fd_top, MAXLNUM)
	fp.fd_len = end - fp.fd_top
}

@(export)
foldMoveRange :: proc "c" (wp: rawptr, gap: ^Garray, line1: C.int, line2: C.int, dest: C.int) {
	fp: ^Fold_T = nil
	range_len := line2 - line1 + 1
	move_len := dest - line2
	at_start := foldFind(gap, line1 - 1, &fp)

	if at_start {
		if fp.fd_top + fp.fd_len - 1 > dest {
			// Case 4: move nested folds.
			foldMoveRange(wp, &fp.fd_nested, line1 - fp.fd_top, line2 - fp.fd_top, dest - fp.fd_top)
			return
		} else if fp.fd_top + fp.fd_len - 1 > line2 {
			// Case 3
			foldMarkAdjustRecurse(wp, &fp.fd_nested, line1 - fp.fd_top,
				line2 - fp.fd_top, MAXLNUM, -range_len)
			fp.fd_len -= range_len
		} else {
			// Case 2: truncate above line1.
			truncate_fold(wp, fp, line1 - 1)
		}
		fp = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
	}

	valid := gap.ga_len > 0 && uintptr(fp) < uintptr(gap.ga_data) + uintptr(C.int(gap.ga_len))*size_of(Fold_T)

	if !valid || fp.fd_top > dest {
		return // Case 10
	} else if fp.fd_top > line2 {
		for valid_loop(gap, fp) && fp.fd_top + fp.fd_len - 1 <= dest {
			fp.fd_top -= range_len
			fp = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
		}
		if valid_loop(gap, fp) && fp.fd_top <= dest {
			truncate_fold(wp, fp, dest)
			fp.fd_top -= range_len
		}
		return
	} else if fp.fd_top + fp.fd_len - 1 > dest {
		// Case 7
		foldMarkAdjustRecurse(wp, &fp.fd_nested, line2 + 1 - fp.fd_top,
			dest - fp.fd_top, MAXLNUM, -move_len)
		fp.fd_len -= move_len
		fp.fd_top += move_len
		return
	}

	// Case 5 or 6
	move_start := C.size_t(uintptr(fp)-uintptr(gap.ga_data)) / C.size_t(size_of(Fold_T))
	move_end: C.size_t = 0

	for valid_loop(gap, fp) && fp.fd_top <= dest {
		if fp.fd_top <= line2 {
			if fp.fd_top + fp.fd_len - 1 > line2 {
				truncate_fold(wp, fp, line2)
			}
			fp.fd_top += move_len
			fp = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
			continue
		}

		if move_end == 0 {
			move_end = C.size_t(uintptr(fp)-uintptr(gap.ga_data)) / C.size_t(size_of(Fold_T))
		}

		if fp.fd_top + fp.fd_len - 1 > dest {
			truncate_fold(wp, fp, dest)
		}

		fp.fd_top -= range_len
		fp = (^Fold_T)(uintptr(fp) + size_of(Fold_T))
	}
	dest_index := C.size_t(uintptr(fp)-uintptr(gap.ga_data)) / C.size_t(size_of(Fold_T))

	if move_end == 0 {
		return
	}
	foldReverseOrder(gap, C.int(move_start), C.int(dest_index) - 1)
	foldReverseOrder(gap, C.int(move_start), C.int(move_start) + C.int(dest_index) - C.int(move_end) - 1)
	foldReverseOrder(gap, C.int(move_start) + C.int(dest_index) - C.int(move_end), C.int(dest_index) - 1)
}

valid_loop :: #force_inline proc "c"(gap: ^Garray, fp: ^Fold_T) -> bool {
	return gap.ga_len > 0 && uintptr(fp) < uintptr(gap.ga_data) + uintptr(C.int(gap.ga_len))*size_of(Fold_T)
}

foldMerge :: proc "c" (wp: rawptr, fp1: ^Fold_T, gap: ^Garray, fp2: ^Fold_T) {
	gap1 := &fp1.fd_nested
	gap2 := &fp2.fd_nested

	fp3: ^Fold_T = nil
	fp4: ^Fold_T = nil
	if foldFind(gap1, fp1.fd_len - 1, &fp3) && foldFind(gap2, 0, &fp4) {
		foldMerge(wp, fp3, gap2, fp4)
	}

	if !GA_EMPTY_F(gap2) {
		ga_grow_r(gap1, gap2.ga_len)
		for idx: C.int = 0; idx < gap2.ga_len; idx += 1 {
			dst := fp_at(gap1, gap1.ga_len)
			dst^ = fp_at(gap2, C.int(idx))^
			dst.fd_top += fp1.fd_len
			gap1.ga_len += 1
		}
		gap2.ga_len = 0
	}

	fp1.fd_len += fp2.fd_len
	deleteFoldEntry(wp, gap,
		C.int(uintptr(fp2)-uintptr(gap.ga_data))/C.int(size_of(Fold_T)), true)
	fold_changed = true
}

// ── Level getters ────────────────────────────────────────────────────────────

foldlevelIndent :: proc "c" (flp: ^Fline_T) {
	lnum := flp.lnum + flp.off

	buf := w_ptr_at(flp.wp, W_BUFFER)
	s := (^u8)(skipwhite(transmute(cstring)(ml_get_buf(buf, lnum))))

	if s^ == 0 || _vim_strchr(transmute(cstring)(w_str(flp.wp, W_P_FDI)), C.int(s^)) != nil {
		flp.lvl = lnum == 1 || lnum == ml_line_count_b(buf) ? 0 : -1
	} else {
		flp.lvl = get_indent_buf_r(buf, lnum) / get_sw_value_r(buf)
	}
	flp.lvl = min(flp.lvl, C.int(max(0, w_i64(flp.wp, W_P_FDN))))
}

foldlevelDiff :: proc "c" (flp: ^Fline_T) {
	flp.lvl = diff_infold_r(flp.wp, flp.lnum + flp.off) ? 1 : 0
}

foldlevelExpr :: proc "c" (flp: ^Fline_T) {
	lnum := flp.lnum + flp.off

	save_win := curwin
	curwin = flp.wp
	curbuf = w_ptr_at(flp.wp, W_BUFFER)
	set_vim_var_nr(VV_LNUM_F, i64(lnum))

	flp.start = 0
	flp.had_end = flp.end
	flp.end = MAX_LEVEL + 1
	if lnum <= 1 {
		flp.lvl = 0
	}

	save_keytyped := KeyTyped

	c: C.int
	n := eval_foldexpr_r(flp.wp, &c)
	KeyTyped = save_keytyped

	switch c {
	case 'a':
		if flp.lvl >= 0 {
			flp.lvl += n
			flp.lvl_next = flp.lvl
		}
		flp.start = n
	case 's':
		if flp.lvl >= 0 {
			if n > flp.lvl {
				flp.lvl_next = 0
			} else {
				flp.lvl_next = flp.lvl - n
			}
			flp.end = flp.lvl_next + 1
		}
	case '>':
		flp.lvl = n
		flp.lvl_next = n
		flp.start = 1
	case '<':
		flp.lvl_next = min(flp.lvl, n - 1)
		flp.end = n
	case '=':
		flp.lvl_next = flp.lvl
	case:
		if n < 0 {
			flp.lvl_next = flp.lvl
		} else {
			flp.lvl_next = n
		}
		flp.lvl = n
	}

	if flp.lvl < 0 {
		if lnum <= 1 {
			flp.lvl = 0
			flp.lvl_next = 0
		}
		if lnum == ml_line_count_b(curbuf) {
			flp.lvl_next = 0
		}
	}

	curwin = save_win
	curbuf = w_ptr_at(curwin, W_BUFFER)
}

parseMarker :: proc "c" (wp: rawptr) {
	fmr := w_str(wp, W_P_FMR)
	foldendmarker = vim_strchr_c(fmr, ',')
	foldstartmarkerlen = C.size_t(uintptr(foldendmarker) - uintptr(fmr))
	foldendmarker = (^u8)(uintptr(foldendmarker) + 1)
	foldendmarkerlen = libc.strlen(transmute(cstring)(foldendmarker))
}

foldlevelMarker :: proc "c" (flp: ^Fline_T) {
	start_lvl := flp.lvl

	startmarker := w_str(flp.wp, W_P_FMR)
	cstart := startmarker^
	startmarker = (^u8)(uintptr(startmarker) + 1)
	cend := foldendmarker^

	flp.start = 0
	flp.lvl_next = flp.lvl

	s := ml_get_buf(w_ptr_at(flp.wp, W_BUFFER), flp.lnum + flp.off)
	for s^ != 0 {
		if s^ == cstart &&
			libc.strncmp(transmute(cstring)((^u8)(uintptr(s)+1)), transmute(cstring)(startmarker), foldstartmarkerlen - 1) == 0 {
			s = (^u8)(uintptr(s) + uintptr(foldstartmarkerlen))
			if ascii_isdigit_u(s^) {
				n := libc.atoi(transmute(cstring)(s))
				if n > 0 {
					flp.lvl = C.int(n)
					flp.lvl_next = C.int(n)
					flp.start = max(n - start_lvl, 1)
				}
			} else {
				flp.lvl += 1
				flp.lvl_next += 1
				flp.start += 1
			}
		} else if s^ == cend &&
			libc.strncmp(transmute(cstring)((^u8)(uintptr(s)+1)), transmute(cstring)((^u8)(uintptr(foldendmarker)+1)), foldendmarkerlen - 1) == 0 {
			s = (^u8)(uintptr(s) + uintptr(foldendmarkerlen))
			if ascii_isdigit_u(s^) {
				n := libc.atoi(transmute(cstring)(s))
				if n > 0 {
					flp.lvl = C.int(n)
					flp.lvl_next = C.int(n) - 1
					flp.lvl_next = min(flp.lvl_next, start_lvl)
				}
			} else {
				flp.lvl_next -= 1
			}
		} else {
			s = (^u8)(uintptr(s) + uintptr(utfc_ptr2len(transmute(cstring)(s))))
		}
	}

	flp.lvl_next = max(flp.lvl_next, 0)
}

foldlevelSyntax :: proc "c" (flp: ^Fline_T) {
	lnum := flp.lnum + flp.off

	flp.lvl = syn_get_foldlevel_r(flp.wp, lnum)
	flp.start = 0
	if lnum < ml_line_count_b(w_ptr_at(flp.wp, W_BUFFER)) {
		n := syn_get_foldlevel_r(flp.wp, lnum + 1)
		if n > flp.lvl {
			flp.start = n - flp.lvl
			flp.lvl = n
		}
	}
}

// ── put_folds (session file support) ─────────────────────────────────────────

@(export)
put_folds :: proc "c" (fd: ^libc.FILE, wp: rawptr) -> C.int {
	if foldmethodIsManual(wp) {
		if put_line_r(fd, cstring("silent! normal! zE")) == FAIL_R ||
			put_folds_recurse(fd, w_ga(wp, W_FOLDS), 0) == FAIL_R ||
			put_line_r(fd, cstring("let &fdl = &fdl")) == FAIL_R {
			return FAIL_R
		}
	}

	if w_bool(wp, W_FOLD_MANUAL) {
		return put_foldopen_recurse(fd, wp, w_ga(wp, W_FOLDS), 0)
	}

	return OK_R
}

put_folds_recurse :: proc "c" (fd: ^libc.FILE, gap: ^Garray, off: C.int) -> C.int {
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		fp := fp_at(gap, C.int(i))
		if put_folds_recurse(fd, &fp.fd_nested, off + fp.fd_top) == FAIL_R {
			return FAIL_R
		}
		if libc.fprintf(fd, cstring("sil! %ld,%ldfold"),
			C.long(fp.fd_top + off), C.long(fp.fd_top + off + fp.fd_len - 1)) < 0 ||
			put_eol_r(fd) == FAIL_R {
			return FAIL_R
		}
	}
	return OK_R
}

put_foldopen_recurse :: proc "c" (fd: ^libc.FILE, wp: rawptr, gap: ^Garray, off: C.int) -> C.int {
	for i: C.int = 0; i < gap.ga_len; i += 1 {
		fp := fp_at(gap, C.int(i))
		if fp.fd_flags != FD_LEVEL {
			if !GA_EMPTY_F(&fp.fd_nested) {
				if libc.fprintf(fd, cstring("%ld"), C.long(fp.fd_top + off)) < 0 ||
					put_eol_r(fd) == FAIL_R ||
					put_line_r(fd, cstring("sil! normal! zo")) == FAIL_R {
					return FAIL_R
				}
				if put_foldopen_recurse(fd, wp, &fp.fd_nested, off + fp.fd_top) == FAIL_R {
					return FAIL_R
				}
				if fp.fd_flags == FD_CLOSED {
					if put_fold_open_close(fd, fp, off) == FAIL_R {
						return FAIL_R
					}
				}
			} else {
				level := foldLevelWin(wp, off + fp.fd_top)
				if (fp.fd_flags == FD_CLOSED && C.int(w_i64(wp, W_P_FDL)) >= level) ||
					(fp.fd_flags != FD_CLOSED && C.int(w_i64(wp, W_P_FDL)) < level) {
					if put_fold_open_close(fd, fp, off) == FAIL_R {
						return FAIL_R
					}
				}
			}
		}
	}

	return OK_R
}

put_fold_open_close :: proc "c" (fd: ^libc.FILE, fp: ^Fold_T, off: C.int) -> C.int {
	if libc.fprintf(fd, cstring("%ld"), C.long(fp.fd_top + off)) < 0 ||
		put_eol_r(fd) == FAIL_R ||
		libc.fprintf(fd, cstring("sil! normal! z%c"),
			fp.fd_flags == FD_CLOSED ? C.int('c') : C.int('o')) < 0 ||
		put_eol_r(fd) == FAIL_R {
		return FAIL_R
	}

	return OK_R
}

// ── f_fold* functions ────────────────────────────────────────────────────────

foldclosed_both :: proc "c" (argvars: ^Typval, rettv: ^Typval, end: bool) {
	lnum := tv_get_lnum_r(argvars)
	if lnum >= 1 && lnum <= ml_line_count_b(curbuf) {
		first: C.int
		last: C.int
		if hasFoldingWin(curwin, lnum, &first, &last, false, nil) {
			(^i64)(uintptr(rettv) + 8)^ = i64(end ? last : first)
			return
		}
	}
	(^i64)(uintptr(rettv) + 8)^ = -1
}

@(export)
f_foldclosed :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	foldclosed_both(argvars, rettv, false)
}

@(export)
f_foldclosedend :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	foldclosed_both(argvars, rettv, true)
}

@(export)
f_foldlevel :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	lnum := tv_get_lnum_r(argvars)
	if lnum >= 1 && lnum <= ml_line_count_b(curbuf) {
		(^i64)(uintptr(rettv) + 8)^ = i64(foldLevel(lnum))
	}
}

@(export)
f_foldtext :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	rettv.v_type = VAR_STRING_U_F
	(^rawptr)(uintptr(rettv) + 8)^ = nil

	foldstart := C.int(get_vim_var_nr_f(VV_FOLDSTART))
	foldend := C.int(get_vim_var_nr_f(VV_FOLDEND))
	dashes := get_vim_var_str_f(VV_FOLDDASHES)
	if foldstart > 0 && foldend <= ml_line_count_b(curbuf) {
		lnum: C.int
		for lnum = foldstart; lnum < foldend; lnum += 1 {
			if !linewhite(lnum) {
				break
			}
		}

		s := (^u8)(skipwhite(transmute(cstring)(ml_get(lnum))))
		if s^ == '/' && ((^u8)(uintptr(s)+1)^ == '*' || (^u8)(uintptr(s)+1)^ == '/') {
			s = (^u8)(skipwhite(transmute(cstring)((^u8)(uintptr(s)+2))))
			if (^u8)(skipwhite(transmute(cstring)(s)))^ == 0 && lnum + 1 < foldend {
				s = (^u8)(skipwhite(transmute(cstring)(ml_get(lnum + 1))))
				if s^ == '*' {
					s = (^u8)(skipwhite(transmute(cstring)((^u8)(uintptr(s)+1))))
				}
			}
		}
		count := foldend - foldstart + 1
		txt := ngettext_f(cstring("+-%s%3d line: "), cstring("+-%s%3d lines: "), C.long(count))
		len := libc.strlen(txt) + libc.strlen(dashes) + 20 + libc.strlen(transmute(cstring)(s))
		r := (^u8)(xmalloc(len))
		libc.snprintf(r, len, txt, dashes, C.int(count))
		rlen := libc.strlen(transmute(cstring)(r))
		libc.memcpy((^u8)(uintptr(r)+uintptr(rlen)), s, libc.strlen(transmute(cstring)(s)) + 1)
		foldtext_cleanup((^u8)(uintptr(r)+uintptr(rlen)))
		(^rawptr)(uintptr(rettv) + 8)^ = r
	}
}

VAR_STRING_U_F :: 2

foreign _ {
	@(link_name = "get_vim_var_nr")
	get_vim_var_nr_f2 :: proc "c" (idx: C.int) -> i64 ---
	@(link_name = "get_vim_var_str")
	get_vim_var_str_f :: proc "c" (idx: C.int) -> cstring ---
}

@(export)
f_foldtextresult :: proc "c" (argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	buf: [FOLD_TEXT_LEN]u8

	rettv.v_type = VAR_STRING_U_F
	(^rawptr)(uintptr(rettv) + 8)^ = nil
	if ftres_entered {
		return
	}
	ftres_entered = true
	lnum := max(tv_get_lnum_r(argvars), 0)

	info := fold_info(curwin, lnum)
	if info.fi_lines > 0 {
		vt: Kvec_VT
		text := get_foldtext(curwin, lnum, lnum + info.fi_lines - 1, info, &buf[0], &vt)
		if text == &buf[0] {
			text = xstrdup(text)
		}
		if vt.n > 0 {
			pos: C.size_t = 0
			for pos < vt.n {
				attr: C.int = 0
				new_text := next_virt_text_chunk_r(vt, &pos, &attr)
				if new_text == nil {
					break
				}
				tlen := libc.strlen(transmute(cstring)(text)) + libc.strlen(transmute(cstring)(new_text)) + 1
				cat := (^u8)(xmalloc(tlen))
				libc.memcpy(cat, text, libc.strlen(transmute(cstring)(text)) + 1)
				libc.memcpy((^u8)(uintptr(cat) + uintptr(libc.strlen(transmute(cstring)(text)))), new_text,
					libc.strlen(transmute(cstring)(new_text)) + 1)
				xfree(text)
				text = cat
			}
		}
		clear_virttext_r(&vt)
		(^rawptr)(uintptr(rettv) + 8)^ = text
	}

	ftres_entered = false
}
