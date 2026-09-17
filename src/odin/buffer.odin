// buffer.odin — port of src/nvim/buffer.c (core buffer list model)
package main

import C "core:c"
import "core:c/libc"

// ── Batch 1: leaf functions ──────────────────────────────────────────────────

B_PREV_OFF :: 128
B_FNUM_OFF :: 0

E37_S :: "E37: No write since last change"
E37_BANG_S :: "E37: No write since last change (add ! to override)"
E89_S :: "E89: No write since last change for buffer %d (add ! to override)"
E948_S :: "E948: Job still running"
E948_BANG_S :: "E948: Job still running (add ! to end the job)"

foreign _ {
	@(link_name = "lastbuf")
	lastbuf_g: rawptr
	@(link_name = "channel_job_running")
	channel_job_running_r :: proc "c" (id: u64) -> bool ---
	@(link_name = "nvim_odin_get_top_file_num")
	nvim_odin_get_top_file_num_r :: proc "c" () -> C.int ---
	@(link_name = "nvim_odin_get_buf_free_count")
	nvim_odin_get_buf_free_count_r :: proc "c" () -> C.int ---
	@(link_name = "buffer_handles")
	buffer_handles_g: Map_int_ptr_t
}
// emsg/B_TERMINAL_OFF/curbuf reused from sibling files.

// semsg_int mirrors semsg(fmt, int): ints pass through libc.snprintf ..any
// correctly (option.odin E593 precedent); only cstring args corrupt.
semsg_int_o :: proc "c"(fmt: cstring, n: C.int) {
	buf: [321]u8 = {}
	libc.snprintf(&buf[0], C.size_t(size_of(buf)), fmt, n)
	emsg(transmute(cstring)(&buf[0]))
}

// Calculate the percentage that `part` is of the `whole`.
@(export)
calc_percentage :: proc "c"(part: i64, whole: i64) -> C.int {
	// With 32 bit longs and more than 21,474,836 lines multiplying by 100
	// causes an overflow, thus for large numbers divide instead.
	if part > 1000000 {
		return C.int(part / (whole / 100))
	}
	return C.int((part * 100) / whole)
}

// Check that "buf" points to a valid buffer in the buffer list.
//
// Can be slow if there are many buffers, prefer using bufref_valid().
@(export)
buf_valid :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	// Assume that we more often have a recent buffer,
	// start with the last one.
	bp := lastbuf_g
	for bp != nil {
		if bp == buf {
			return true
		}
		bp = (^rawptr)(uintptr(bp) + B_PREV_OFF)^
	}
	return false
}

@(export)
no_write_message_buf :: proc "c"(buf: rawptr) {
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
	channel_job_running_r(u64((^C.longlong)(uintptr(buf) + B_P_CHANNEL_OFF)^)) {
		emsg(E948_BANG_S)
	} else {
		semsg_int_o(E89_S, (^C.int)(uintptr(buf) + B_FNUM_OFF)^)
	}
}

@(export)
no_write_message :: proc "c"() {
	if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil &&
	channel_job_running_r(u64((^C.longlong)(uintptr(curbuf) + B_P_CHANNEL_OFF)^)) {
		emsg(E948_BANG_S)
	} else {
		emsg(E37_BANG_S)
	}
}

@(export)
no_write_message_nobang :: proc "c"(buf: rawptr) {
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
	channel_job_running_r(u64((^C.longlong)(uintptr(buf) + B_P_CHANNEL_OFF)^)) {
		emsg(E948_S)
	} else {
		emsg(E37_S)
	}
}

// ── Batch 3: wininfo lookup ──────────────────────────────────────────────────

B_WININFO_OFF :: 288
WI_WIN_OFF :: 0
WI_MARK_OFF :: 8
WI_OPTSET_OFF :: 48
WI_OPT_DIFF_OFF :: 72 // wi_opt@56 + wo_diff@16

// b_wininfo is kvec_t(WinInfo*): {size, capacity, items} with size_t fields.
wininfo_count_o :: proc "c"(buf: rawptr) -> u64 {
	return (^u64)(uintptr(buf) + B_WININFO_OFF)^
}

wininfo_at_o :: proc "c"(buf: rawptr, i: u64) -> rawptr {
	items := (^rawptr)(uintptr(buf) + B_WININFO_OFF + 16)^
	return ([^]rawptr)(items)[i]
}

// Check that "wip" has 'diff' set and the diff is only for another tab page.
// That's because a diff is local to a tab page.
wininfo_other_tab_diff_o :: proc "c"(wip: rawptr) -> bool {
	if (^bool)(uintptr(wip) + WI_OPT_DIFF_OFF)^ == false {
		return false
	}

	tp := curtab
	wp := tp == curtab ? firstwin : (^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
	for wp != nil {
		// return false when it's a window in the current tab page, thus
		// the buffer was in diff mode here
		if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == wp {
			return false
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return true
}

// Find info for the current window in buffer "buf".
// If not found, return the info for the most recently used window.
find_wininfo_o :: proc "c"(buf: rawptr, need_options: bool, skip_diff_buffer: bool) -> rawptr {
	n := wininfo_count_o(buf)
	for i: u64 = 0; i < n; i += 1 {
		wip := wininfo_at_o(buf, i)
		if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == curwin &&
		(!skip_diff_buffer || !wininfo_other_tab_diff_o(wip)) &&
		(!need_options || (^bool)(uintptr(wip) + WI_OPTSET_OFF)^) {
			return wip
		}
	}

	// If no wininfo for curwin, use the first in the list (that doesn't have
	// 'diff' set and is in another tab page).
	if skip_diff_buffer {
		for i: u64 = 0; i < n; i += 1 {
			wip := wininfo_at_o(buf, i)
			wi_win := (^rawptr)(uintptr(wip) + WI_WIN_OFF)^
			if !wininfo_other_tab_diff_o(wip) &&
			(!need_options || (^bool)(uintptr(wip) + WI_OPTSET_OFF)^ ||
			(wi_win != nil && (^rawptr)(uintptr(wi_win) + W_BUFFER)^ == buf)) {
				return wip
			}
		}
	} else if n > 0 {
		return wininfo_at_o(buf, 0)
	}
	return nil
}

// fmark_T{{1,0,0},0,0,INIT_FMARKV,NULL} — typed literal, layout-verified
// by mark.odin's #assert(size_of(Fmark_T) == 40).
@(private="file")
no_position_g: Fmark_T = {mark = Pos_T{1, 0, 0}, view = INIT_FMARKV}

// Find the mark for the buffer 'buf' for the current window.
//
// @return a pointer to no_position if no position is found.
@(export)
buflist_findfmark :: proc "c"(buf: rawptr) -> rawptr {
	wip := find_wininfo_o(buf, false, false)
	if wip == nil {
		return transmute(rawptr)(&no_position_g)
	}
	// ADDRESS of embedded wi_mark (C: &(wip->wi_mark)) — never deref.
	return transmute(rawptr)(uintptr(wip) + WI_MARK_OFF)
}

// Find the lnum for the buffer 'buf' for the current window.
@(export)
buflist_findlnum :: proc "c"(buf: rawptr) -> C.int {
	fm := buflist_findfmark(buf)
	return (^C.int)(uintptr(fm) + 0)^ // mark.lnum
}

// ── Batch 5: get_winopts ─────────────────────────────────────────────────────

WI_FOLD_MANUAL_OFF :: 1760
WI_FOLDS_OFF :: 1768
WI_CHANGELISTIDX_OFF :: 1792
WI_OPT_OFF :: 56
W_FOLD_MANUAL_OFF :: 672
W_FOLDINVALID_OFF :: 673
W_FOLDS_OFF :: 648
W_P_FDL_OFF :: 880
W_ONEBUF_OPT_OFF :: 816
W_ALLBUF_OPT_OFF :: 2520
K_WIN_STYLE_MINIMAL_O :: 1

foreign _ {
	@(link_name = "win_set_minimal_style")
	win_set_minimal_style_r :: proc "c" (wp: rawptr) ---
	@(link_name = "p_fdls")
	p_fdls_g: C.longlong
}
// clear_winopt/clearFolding/copy_winopt/cloneFoldGrowArray/didset_window_options/
// find_wininfo_o/curwin/W_S_OFF reused.

// Reset the local window options to the values last used in this window.
// If the buffer wasn't used in this window before, use the values from
// the most recently used window. If the values were never set, use the
// global values for the window.
@(export)
get_winopts :: proc "c"(buf: rawptr) {
	clear_winopt(transmute(rawptr)(uintptr(curwin) + W_ONEBUF_OPT_OFF))
	clearFolding(curwin)

	wip := find_wininfo_o(buf, true, true)
	if wip != nil && (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ != curwin &&
	(^rawptr)(uintptr(wip) + WI_WIN_OFF)^ != nil &&
	(^rawptr)(uintptr((^rawptr)(uintptr(wip) + WI_WIN_OFF)^) + W_BUFFER)^ == buf &&
	(^C.int)(uintptr((^rawptr)(uintptr(wip) + WI_WIN_OFF)^) + W_CONFIG_OFF)^ != K_WIN_STYLE_MINIMAL_O {
		wp := (^rawptr)(uintptr(wip) + WI_WIN_OFF)^
		copy_winopt(transmute(rawptr)(uintptr(wp) + W_ONEBUF_OPT_OFF),
			transmute(rawptr)(uintptr(curwin) + W_ONEBUF_OPT_OFF))
		(^bool)(uintptr(curwin) + W_FOLD_MANUAL_OFF)^ = (^bool)(uintptr(wp) + W_FOLD_MANUAL_OFF)^
		(^bool)(uintptr(curwin) + W_FOLDINVALID_OFF)^ = true
		cloneFoldGrowArray((^Garray)(uintptr(wp) + W_FOLDS_OFF),
			(^Garray)(uintptr(curwin) + W_FOLDS_OFF))
	} else if wip != nil && (^bool)(uintptr(wip) + WI_OPTSET_OFF)^ &&
	((^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == nil ||
	(^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == curwin ||
	(^C.int)(uintptr((^rawptr)(uintptr(wip) + WI_WIN_OFF)^) + W_CONFIG_OFF)^ != K_WIN_STYLE_MINIMAL_O) {
		copy_winopt(transmute(rawptr)(uintptr(wip) + WI_OPT_OFF),
			transmute(rawptr)(uintptr(curwin) + W_ONEBUF_OPT_OFF))
		(^bool)(uintptr(curwin) + W_FOLD_MANUAL_OFF)^ = (^bool)(uintptr(wip) + WI_FOLD_MANUAL_OFF)^
		(^bool)(uintptr(curwin) + W_FOLDINVALID_OFF)^ = true
		cloneFoldGrowArray((^Garray)(uintptr(wip) + WI_FOLDS_OFF),
			(^Garray)(uintptr(curwin) + W_FOLDS_OFF))
	} else {
		copy_winopt(transmute(rawptr)(uintptr(curwin) + W_ALLBUF_OPT_OFF),
			transmute(rawptr)(uintptr(curwin) + W_ONEBUF_OPT_OFF))
	}
	if wip != nil {
		(^C.int)(uintptr(curwin) + W_CHANGELISTIDX_OFF)^ =
			(^C.int)(uintptr(wip) + WI_CHANGELISTIDX_OFF)^
	}

	if (^C.int)(uintptr(curwin) + W_CONFIG_OFF)^ == K_WIN_STYLE_MINIMAL_O {
		didset_window_options(curwin, false)
		win_set_minimal_style_r(curwin)
	}

	// Set 'foldlevel' to 'foldlevelstart' if it's not negative.
	if p_fdls_g >= 0 {
		(^C.longlong)(uintptr(curwin) + W_P_FDL_OFF)^ = p_fdls_g
	}
	didset_window_options(curwin, false)
}

// ── Batch 4: free_buf_options ────────────────────────────────────────────────

B_KMAP_GA_OFF :: 7864
B_CFU_CB_OFF :: 10288
B_OFU_CB_OFF :: 10312
B_TSRFU_CB_OFF :: 10912
B_P_CPT_CB_OFF :: 10264
B_P_CPT_COUNT_OFF :: 10272
B_TFU_CB_OFF :: 10336
B_FFU_CB_OFF :: 10360
NO_LOCAL_UNDOLEVEL_O :: -123456
// spell.odin's SB_P_SPC_OFF/SB_CAP_PROG_OFF are synblock-relative.
SB_P_SPC_REL :: 1088
SB_CAP_PROG_REL :: 1096

foreign _ {
	@(link_name = "clear_cpt_callbacks")
	clear_cpt_callbacks_r :: proc "c" (callbacks: ^^rawptr, count: C.int) ---
}
// clear_string_option/xfree/keymap_ga_clear/ga_clear_r/vim_regfree/
// callback_free_r/B_P_*/SB_*/B_S_OFF reused.

clear_str_at_o :: #force_inline proc "c"(buf: rawptr, off: uintptr) {
	clear_string_option(transmute(^u8)(uintptr(buf) + off))
}

xfree_clear_at_o :: #force_inline proc "c"(buf: rawptr, off: uintptr) {
	slot := (^rawptr)(uintptr(buf) + off)
	xfree(slot^)
	slot^ = nil
}

@(export)
free_buf_options :: proc "c"(buf: rawptr, free_p_ff: bool) {
	if free_p_ff {
		clear_str_at_o(buf, B_P_FENC_OFF)
		clear_str_at_o(buf, B_P_FF_OFF)
		clear_str_at_o(buf, B_P_BH_OFF)
		clear_str_at_o(buf, B_P_BT_OFF)
	}
	clear_str_at_o(buf, B_P_DEF_OFF)
	clear_str_at_o(buf, B_P_INC_OFF)
	clear_str_at_o(buf, B_P_INEX_OFF)
	clear_str_at_o(buf, B_P_INDE_OFF)
	clear_str_at_o(buf, B_P_INDK_OFF)
	clear_str_at_o(buf, B_P_FP_OFF)
	clear_str_at_o(buf, B_P_FEX_OFF)
	clear_str_at_o(buf, B_P_KP_OFF)
	clear_str_at_o(buf, B_P_MPS_OFF)
	clear_str_at_o(buf, B_P_FO_OFF)
	clear_str_at_o(buf, B_P_FLP_OFF)
	clear_str_at_o(buf, B_P_ISK_OFF)
	clear_str_at_o(buf, B_P_VSTS_OFF)
	xfree_clear_at_o(buf, B_P_VSTS_NOPASTE_OFF)
	xfree_clear_at_o(buf, B_P_VSTS_ARR_OFF)
	clear_str_at_o(buf, B_P_VTS_OFF)
	xfree_clear_at_o(buf, B_P_VTS_ARR_OFF)
	clear_str_at_o(buf, B_P_KEYMAP_OFF)
	keymap_ga_clear((^Garray)(uintptr(buf) + B_KMAP_GA_OFF))
	ga_clear_r((^Garray)(uintptr(buf) + B_KMAP_GA_OFF))
	clear_str_at_o(buf, B_P_COM_OFF)
	clear_str_at_o(buf, B_P_CMS_OFF)
	clear_str_at_o(buf, B_P_NF_OFF)
	clear_str_at_o(buf, B_P_SYN_OFF)
	clear_str_at_o(buf, SB_SYN_ISK)
	clear_str_at_o(buf, B_S_OFF + SB_P_SPC_REL)
	clear_str_at_o(buf, SB_P_SPF)
	clear_str_at_o(buf, SB_P_SPL)
	clear_str_at_o(buf, SB_P_SPO)
	vim_regfree((^rawptr)(uintptr(buf) + B_S_OFF + SB_CAP_PROG_REL)^)
	(^rawptr)(uintptr(buf) + B_S_OFF + SB_CAP_PROG_REL)^ = nil
	clear_str_at_o(buf, B_P_SUA_OFF)
	clear_str_at_o(buf, B_P_FT_OFF)
	clear_str_at_o(buf, B_P_CINK_OFF)
	clear_str_at_o(buf, B_P_CINO_OFF)
	clear_str_at_o(buf, B_P_LOP_OFF)
	clear_str_at_o(buf, B_P_CINSD_OFF)
	clear_str_at_o(buf, B_P_CINW_OFF)
	clear_str_at_o(buf, B_P_COT_OFF)
	clear_str_at_o(buf, B_P_CPT_OFF)
	clear_str_at_o(buf, B_P_CFU_OFF)
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_CFU_CB_OFF))
	clear_str_at_o(buf, B_P_OFU_OFF)
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_OFU_CB_OFF))
	clear_str_at_o(buf, B_P_TSRFU_OFF)
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_TSRFU_CB_OFF))
	clear_cpt_callbacks_r((^^rawptr)(uintptr(buf) + B_P_CPT_CB_OFF),
		(^C.int)(uintptr(buf) + B_P_CPT_COUNT_OFF)^)
	(^C.int)(uintptr(buf) + B_P_CPT_COUNT_OFF)^ = 0
	clear_str_at_o(buf, B_P_GEFM_OFF)
	clear_str_at_o(buf, B_P_GP_OFF)
	clear_str_at_o(buf, B_P_MP_OFF)
	clear_str_at_o(buf, B_P_EFM_OFF)
	clear_str_at_o(buf, B_P_EP_OFF)
	clear_str_at_o(buf, B_P_PATH_OFF)
	clear_str_at_o(buf, B_P_TAGS_OFF)
	clear_str_at_o(buf, B_P_TC_OFF)
	clear_str_at_o(buf, B_P_TFU_OFF)
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_TFU_CB_OFF))
	clear_str_at_o(buf, B_P_FFU_OFF)
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_FFU_CB_OFF))
	clear_str_at_o(buf, B_P_DICT_OFF)
	clear_str_at_o(buf, B_P_DIA_OFF)
	clear_str_at_o(buf, B_P_TSR_OFF)
	clear_str_at_o(buf, B_P_QE_OFF)
	(^C.int)(uintptr(buf) + B_P_AC_OFF)^ = -1 // int, NOT OptInt!
	(^C.int)(uintptr(buf) + B_P_AR_OFF)^ = -1 // int, NOT OptInt!
	(^C.int)(uintptr(buf) + B_P_FS_OFF)^ = -1 // int, NOT OptInt!
	(^C.longlong)(uintptr(buf) + B_P_UL_OFF2)^ = NO_LOCAL_UNDOLEVEL_O // OptInt
	clear_str_at_o(buf, B_P_LW_OFF)
	clear_str_at_o(buf, B_P_BKC_OFF)
	clear_str_at_o(buf, B_P_MENC_OFF)
}

// Reference to a buffer that stores the value of buf_free_count.
Bufref_T :: struct {
	br_buf:            rawptr,
	br_fnum:           C.int,
	br_buf_free_count: C.int,
}

#assert(size_of(Bufref_T) == 16)

// @return the highest possible buffer number
@(export)
get_highest_fnum :: proc "c"() -> C.int {
	return nvim_odin_get_top_file_num_r() - 1
}

// Store "buf" in "bufref" and set the free count.
@(export)
set_bufref :: proc "c"(bufref: ^Bufref_T, buf: rawptr) {
	bufref.br_buf = buf
	bufref.br_fnum = buf == nil ? 0 : (^C.int)(uintptr(buf) + B_FNUM_OFF)^
	bufref.br_buf_free_count = nvim_odin_get_buf_free_count_r()
}

// Return true if "bufref->br_buf" points to the same buffer as when
// set_bufref() was called and it is a valid buffer.
// Only goes through the buffer list if buf_free_count changed.
@(export)
bufref_valid :: proc "c"(bufref: ^Bufref_T) -> bool {
	if bufref.br_buf_free_count == nvim_odin_get_buf_free_count_r() {
		return true
	}
	return buf_valid(bufref.br_buf) &&
		bufref.br_fnum == (^C.int)(uintptr(bufref.br_buf) + B_FNUM_OFF)^
}

// Find a file in the buffer list by buffer number.
@(export)
buflist_findnr :: proc "c"(nr: C.int) -> rawptr {
	n := nr
	if n == 0 {
		n = (^C.int)(uintptr(curwin) + W_ALT_FNUM)^
	}

	// pmap_get(int): return mapped value or NULL, never inserts.
	// NOTE: mh_get returns MH_TOMBSTONE (not n_buckets) on miss.
	mp := &buffer_handles_g
	k := mh_get_int(&mp.set, n)
	if k == MH_TOMBSTONE {
		return nil
	}
	return mp.values[k]
}

// ── Batch 5: buflist_new + buffer-creation helpers ───────────────────────────
// Offsets probed 2026-09-05 via off16/off16b (cc offsetof against real headers).

BUF_SIZE_O :: 12760
WININFO_SIZE_O :: 1800
B_VARS_OFF :: 11160
B_BUFVAR_OFF :: 11136
B_SFNAME_OFF :: 168
B_FLAGS_OFF :: 140
B_FILE_ID_VALID_OFF :: 184
B_FILE_ID_OFF :: 192
B_ML_MFP_OFF :: 16 // b_ml@8 + ml_mfp@8
B_PROMPT_TEXT_OFF :: 11176
B_PROMPT_CB_OFF :: 11184 // Callback, 16 bytes
B_PROMPT_INT_OFF :: 11200 // Callback, 16 bytes
B_PROMPT_APPEND_OFF :: 11216
B_UPDATE_CHANNELS_OFF :: 12664 // kvec 24B
B_UPDATE_CALLBACKS_OFF :: 12688 // kvec 24B
B_UCMDS_OFF :: 7680
B_START_FENC_OFF :: 11120
B_S_LANGP_OFF :: 12064 // b_s@11264 + b_langp@800
B_S_KEYWTAB_OFF :: 11264
B_S_KEYWTAB_IC_OFF :: 11560
B_WINFOFF_SIZE :: 288 // b_wininfo kvec: size@+0/cap@+8/items@+16
B_WINFOFF_CAP :: 296
B_WINFOFF_ITEMS :: 304
B_CHANGEDTICK_DI_OFF :: 216
BLN_CURBUF_O :: 1
BLN_DUMMY_O :: 4
BLN_NEW_O :: 8
BLN_NOOPT_O :: 16
BLN_NOCURWIN_O :: 128
BF_CHECK_RO_O :: 0x02
BF_NEVERLOADED_O :: 0x04
BF_DUMMY_O :: 0x80
BFA_WIPE_O :: 2
BFA_DEL_O :: 1
KBFF_CLEAR_WININFO_O :: 1
KBFF_INIT_CHANGEDTICK_O :: 2
VAR_NUMBER_O :: 1
VAR_FIXED_O :: 2
DI_FLAGS_RO_O :: 1
DI_FLAGS_FIX_O :: 4
MAP_ALL_MODES_O :: 0xff
EVENT_BUFADD_O :: 0
EVENT_BUFNEW_O :: 8
W14_S :: "W14: Warning: List of file names overflow"
CHANGEDTICK_S :: "changedtick"

foreign _ {
	@(link_name = "nvim_odin_set_top_file_num")
	nvim_odin_set_top_file_num_r :: proc "c" (v: C.int) ---
	// fname_expand/buflist_setfpos now defined below — call directly.
	@(link_name = "in_assert_fails")
	in_assert_fails_g: bool
	@(link_name = "msg_delay")
	msg_delay_r :: proc "c" (ms: u64, ignoreinput: bool) ---
	@(link_name = "vars_clear")
	vars_clear_r2 :: proc "c" (ht: rawptr) ---
	@(link_name = "hash_remove")
	hash_remove_r :: proc "c" (ht: rawptr, hi: rawptr) ---
	@(link_name = "uc_clear")
	uc_clear_r :: proc "c" (gap: rawptr) ---
	@(link_name = "extmark_free_all")
	extmark_free_all_r :: proc "c" (buf: rawptr) ---
	@(link_name = "map_clear_mode")
	map_clear_mode_r :: proc "c" (buf: rawptr, mode: C.int, local: bool, abbr: bool) ---
	@(link_name = "buf_free_callbacks")
	buf_free_callbacks_r :: proc "c" (buf: rawptr) ---
	@(link_name = "tv_dict_add")
	tv_dict_add_r :: proc "c" (d: rawptr, item: rawptr) -> C.int ---
}

// Set file_id for a buffer. Must always be called when b_fname is changed!
@(export)
buf_set_file_id :: proc "c"(buf: rawptr) {
	file_id: FileID
	if (^rawptr)(uintptr(buf) + B_FNAME)^ != nil &&
		os_fileid((^cstring)(uintptr(buf) + B_FNAME)^, &file_id) {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = true
		(^FileID)(uintptr(buf) + B_FILE_ID_OFF)^ = file_id
	} else {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = false
	}
}

// Check that file_id in buffer "buf" matches (C static: no export/weak).
buf_same_file_id_o :: proc "c"(buf: rawptr, file_id: ^FileID) -> bool {
	return (^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ &&
		os_fileid_equal(transmute(^FileID)(uintptr(buf) + B_FILE_ID_OFF), file_id)
}

// Check if "buf" is a different file than "ffname" (C static).
otherfile_buf_o :: proc "c"(buf: rawptr, ffname: cstring, file_id_p: ^FileID, file_id_valid: bool) -> bool {
	// no name is different
	if ffname == nil || b_at(transmute(^u8)(ffname), 0) == 0 ||
		(^rawptr)(uintptr(buf) + B_FFNAME)^ == nil {
		return true
	}
	if path_fnamecmp_r(ffname, (^cstring)(uintptr(buf) + B_FFNAME)^) == 0 {
		return false
	}
	file_id: FileID
	fip := file_id_p
	fiv := file_id_valid
	// If no struct stat given, get it now
	if fip == nil {
		fip = &file_id
		fiv = os_fileid(ffname, fip)
	}
	if !fiv {
		// file_id not valid, assume files are different.
		return true
	}
	// Use dev/ino to check if the files are the same, even when the names
	// are different (possible with links).
	if buf_same_file_id_o(buf, fip) {
		buf_set_file_id(buf)
		if buf_same_file_id_o(buf, fip) {
			return false
		}
	}
	return true
}

// Find buffer with matching file id/name, starting at the last buffer
// (C static: no export/weak).
buflist_findname_file_id_o :: proc "c"(ffname: cstring, file_id: ^FileID, file_id_valid: bool) -> rawptr {
	// Start at the last buffer, expect to find a match sooner.
	buf := lastbuf_g
	for buf != nil {
		if ((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & BF_DUMMY_O) == 0 &&
			!otherfile_buf_o(buf, ffname, file_id, file_id_valid) {
			return buf
		}
		buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
	}
	return nil
}

// Run b:undo_ftplugin for a buffer being wiped (C static).
trigger_undo_ftplugin_o :: proc "c"(buf: rawptr, win: rawptr) {
	window_layout_lock()
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
	(^C.int)(uintptr(win) + W_LOCKED_OFF)^ += 1
	// b:undo_ftplugin may be set, undo it
	do_cmdline_cmd_r(cstring("if exists('b:undo_ftplugin') | exe b:undo_ftplugin | endif"))
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
	(^C.int)(uintptr(win) + W_LOCKED_OFF)^ -= 1
	window_layout_unlock()
}

// Free window-info list of a buffer (C static: no export/weak).
clear_wininfo_o :: proc "c"(buf: rawptr) {
	n := (^uint)(uintptr(buf) + B_WINFOFF_SIZE)^
	items := (^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^
	for i: uint = 0; i < n; i += 1 {
		free_wininfo(([^]rawptr)(items)[i], buf)
	}
	(^uint)(uintptr(buf) + B_WINFOFF_SIZE)^ = 0
}

// Free stuff in the buffer for ":bdel" and wiping (C static).
free_buffer_stuff_o :: proc "c"(buf: rawptr, free_flags: C.int) {
	if (free_flags & KBFF_CLEAR_WININFO_O) != 0 {
		clear_wininfo_o(buf) // including window-local options
		free_buf_options(buf, true)
		ga_clear_r(transmute(^Garray)(uintptr(buf) + B_S_LANGP_OFF))
	}
	// Avoid losing b:changedtick when deleting buffer: clearing variables
	// implies using clear_tv() on b:changedtick and that sets changedtick
	// to zero.
	vars := (^rawptr)(uintptr(buf) + B_VARS_OFF)^
	changedtick_hi := hash_find_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF),
		cstring(CHANGEDTICK_S))
	if changedtick_hi != nil {
		hash_remove_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF), changedtick_hi)
	}
	vars_clear_r2(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF)) // free all vars
	hash_init_r(transmute(rawptr)(uintptr(vars) + DV_HASHTAB_OFF))
	if (free_flags & KBFF_INIT_CHANGEDTICK_O) != 0 {
		buf_init_changedtick_o(buf)
	}
	uc_clear_r(transmute(rawptr)(uintptr(buf) + B_UCMDS_OFF)) // local user cmds
	extmark_free_all_r(buf) // delete any extmarks
	map_clear_mode_r(buf, MAP_ALL_MODES_O, true, false) // local mappings
	map_clear_mode_r(buf, MAP_ALL_MODES_O, true, true) // local abbrevs
	sf := (^rawptr)(uintptr(buf) + B_START_FENC_OFF)^
	if sf != nil {
		xfree(sf)
		(^rawptr)(uintptr(buf) + B_START_FENC_OFF)^ = nil
	}
	buf_free_callbacks_r(buf)
}

// Initialize b:changedtick and changedtick_val attribute (C static inline).
buf_init_changedtick_o :: proc "c"(buf: rawptr) {
	di := uintptr(buf) + B_CHANGEDTICK_DI_OFF
	// di_tv: v_type@0 (int), v_lock@4 (int), vval.v_number@8 (int64).
	(^C.int)(di)^ = VAR_NUMBER_O
	(^C.int)(di + 4)^ = VAR_FIXED_O
	(^C.longlong)(di + 8)^ = (^C.longlong)(di + 8)^ // v_number = current tick
	// di_flags@16 (u8): RO|FIX. di_key@17: "changedtick\0" (12 bytes).
	(^u8)(di + 16)^ = DI_FLAGS_RO_O | DI_FLAGS_FIX_O
	libc.memcpy(rawptr(di + 17), transmute(rawptr)(cstring(CHANGEDTICK_S)), 12)
	tv_dict_add_r((^rawptr)(uintptr(buf) + B_VARS_OFF)^, rawptr(di))
}

// Return true if the current buffer is empty, unnamed, unmodified and used
// in only one window. That means it can be reused.
@(export)
curbuf_reusable :: proc "c"() -> bool {
	return curbuf != nil &&
		(^rawptr)(uintptr(curbuf) + B_FFNAME)^ == nil &&
		(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ <= 1 &&
		(^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ == nil &&
		((^rawptr)(uintptr(curbuf) + B_ML_MFP_OFF)^ == nil || buf_is_empty(curbuf)) &&
		!bt_quickfix(curbuf) &&
		!curbufIsChanged()
}

// Add a file name to the buffer list. This is the ONLY way to create a
// new buffer (besides spell-file buffers).
@(export)
buflist_new :: proc "c"(ffname_arg: cstring, sfname_arg: cstring, lnum: C.int, flags: C.int) -> rawptr {
	ffname := ffname_arg
	sfname := sfname_arg
	fname_expand(curbuf, &ffname, &sfname) // will allocate ffname
	// If the file name already exists in the list, update the entry.
	// We can use inode numbers when the file exists. Works better for
	// hard links.
	file_id: FileID
	file_id_valid := sfname != nil && os_fileid(sfname, &file_id)
	buf: rawptr = nil
	if ffname != nil && (flags & (BLN_DUMMY_O | BLN_NEW_O)) == 0 {
		buf = buflist_findname_file_id_o(ffname, &file_id, file_id_valid)
	}
	if buf != nil {
		xfree(transmute(rawptr)(ffname))
		if lnum != 0 {
			buflist_setfpos(buf, (flags & BLN_NOCURWIN_O) != 0 ? nil : curwin,
				lnum, 0, false)
		}
		if (flags & BLN_NOOPT_O) == 0 {
			// Copy the options now, if 'cpo' doesn't have 's' and not done already.
			buf_copy_options(buf, 0)
		}
		if (flags & BLN_LISTED_O) != 0 && !(^bool)(uintptr(buf) + B_P_BL_OFF)^ {
			(^bool)(uintptr(buf) + B_P_BL_OFF)^ = true
			bref: Bufref_T
			set_bufref(&bref, buf)
			if (flags & BLN_DUMMY_O) == 0 {
				if apply_autocmds(EVENT_BUFADD_O, nil, nil, false, buf) &&
					!bufref_valid(&bref) {
					return nil
				}
			}
		}
		return buf
	}
	// If the current buffer has no name and no contents, use the current
	// buffer. Otherwise: Need to allocate a new buffer structure.
	buf = nil
	if (flags & BLN_CURBUF_O) != 0 && curbuf_reusable() {
		bref: Bufref_T
		buf = curbuf
		set_bufref(&bref, buf)
		trigger_undo_ftplugin_o(buf, curwin)
		// It's like this buffer is deleted. Watch out for autocommands that
		// change curbuf! If that happens, allocate a new buffer anyway.
		buf_freeall(buf, BFA_WIPE_O | BFA_DEL_O)
		if aborting_r() { // autocmds may abort script processing
			xfree(transmute(rawptr)(ffname))
			return nil
		}
		if !bufref_valid(&bref) {
			buf = nil // buf was deleted; allocate a new buffer
		}
	}
	if buf != curbuf || curbuf == nil {
		buf = xcalloc(1, BUF_SIZE_O)
		// init b: variables
		vars := tv_dict_alloc_r()
		(^rawptr)(uintptr(buf) + B_VARS_OFF)^ = vars
		init_var_dict_r(vars, transmute(rawptr)(uintptr(buf) + B_BUFVAR_OFF), VAR_SCOPE_O)
		buf_init_changedtick_o(buf)
	}
	if ffname != nil {
		(^rawptr)(uintptr(buf) + B_FFNAME)^ = transmute(rawptr)(ffname)
		(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = transmute(rawptr)(xstrdup_o(transmute(^u8)(sfname)))
	}
	clear_wininfo_o(buf)
	curwin_info := xcalloc(1, WININFO_SIZE_O)
	// kv_push(buf->b_wininfo, curwin_info).
	wisz := (^uint)(uintptr(buf) + B_WINFOFF_SIZE)^
	wicap := (^uint)(uintptr(buf) + B_WINFOFF_CAP)^
	if wisz == wicap {
		newcap := wicap << 1
		if newcap == 0 {
			newcap = 8
		}
		newitems := xrealloc((^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^,
			C.size_t(newcap * 8))
		(^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^ = newitems
		(^uint)(uintptr(buf) + B_WINFOFF_CAP)^ = newcap
	}
	([^]rawptr)((^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^)[wisz] = curwin_info
	(^uint)(uintptr(buf) + B_WINFOFF_SIZE)^ = wisz + 1
	if buf == curbuf {
		free_buffer_stuff_o(buf, KBFF_INIT_CHANGEDTICK_O) // delete local vars et al.
		// Init the options.
		(^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^ = false
		buf_copy_options(buf, BCO_ENTER_O)
		// need to reload lmaps and set b:keymap_name
		(^i16)(uintptr(buf) + B_KMAP_STATE_OFF)^ |= i16(KEYMAP_INIT_S)
	} else {
		// put new buffer at the end of the buffer list
		(^rawptr)(uintptr(buf) + B_NEXT_OFF)^ = nil
		if firstbuf == nil { // buffer list is empty
			(^rawptr)(uintptr(buf) + B_PREV_OFF)^ = nil
			firstbuf = buf
		} else { // append new buffer at end of list
			(^rawptr)(uintptr(lastbuf_g) + B_NEXT_OFF)^ = buf
			(^rawptr)(uintptr(buf) + B_PREV_OFF)^ = lastbuf_g
		}
		lastbuf_g = buf
		top := nvim_odin_get_top_file_num_r()
		(^C.int)(uintptr(buf) + B_FNUM_OFF)^ = top
		nvim_odin_set_top_file_num_r(top + 1)
		new_item: bool = false
		slot := map_put_ref_int_ptr_t(&buffer_handles_g,
			(^C.int)(uintptr(buf) + B_FNUM_OFF)^, nil, &new_item)
		slot^ = buf
		if top + 1 < 0 { // wrap around (may cause duplicates)
			emsg(cstring(W14_S))
			if emsg_silent == 0 && !in_assert_fails_g {
				msg_delay_r(3001, true) // make sure it is noticed
			}
			nvim_odin_set_top_file_num_r(1)
		}
		// Always copy the options from the current buffer.
		buf_copy_options(buf, BCO_ALWAYS_S)
	}
	wi := (^Fmark_T)(uintptr(curwin_info) + WI_MARK_OFF)
	wi^ = Fmark_T{mark = Pos_T{1, 0, 0}, view = INIT_FMARKV}
	(^C.int)(uintptr(curwin_info) + WI_MARK_OFF)^ = lnum
	(^rawptr)(uintptr(curwin_info) + WI_WIN_OFF)^ = curwin
	hash_init_r(transmute(rawptr)(uintptr(buf) + B_S_KEYWTAB_OFF))
	hash_init_r(transmute(rawptr)(uintptr(buf) + B_S_KEYWTAB_IC_OFF))
	(^rawptr)(uintptr(buf) + B_FNAME)^ = (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^
	if !file_id_valid {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = false
	} else {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = true
		(^FileID)(uintptr(buf) + B_FILE_ID_OFF)^ = file_id
	}
	(^bool)(uintptr(buf) + B_U_SYNCED)^ = true
	(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ = BF_CHECK_RO_O | BF_NEVERLOADED_O
	if (flags & BLN_DUMMY_O) != 0 {
		(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ |= BF_DUMMY_O
	}
	buf_clear_file(buf)
	clrallmarks(buf, 0) // clear marks
	fmarks_check_names(buf) // check file marks for this file
	(^bool)(uintptr(buf) + B_P_BL_OFF)^ =
		(flags & BLN_LISTED_O) != 0 ? true : false // init 'buflisted'
	// kv_destroy + kv_init update_channels/update_callbacks.
	for off in ([]uint{B_UPDATE_CHANNELS_OFF, B_UPDATE_CALLBACKS_OFF}) {
		o := uintptr(off)
		it := (^rawptr)(uintptr(buf) + o)^
		if it != nil {
			xfree(it)
		}
		(^uint)(uintptr(buf) + o)^ = 0
		(^uint)(uintptr(buf) + o + 8)^ = 0
		(^rawptr)(uintptr(buf) + o + 16)^ = nil
	}
	if (flags & BLN_DUMMY_O) == 0 {
		// Tricky: these autocommands may change the buffer list.
		bref2: Bufref_T
		set_bufref(&bref2, buf)
		if apply_autocmds(EVENT_BUFNEW_O, nil, nil, false, buf) &&
			!bufref_valid(&bref2) {
			return nil
		}
		if (flags & BLN_LISTED_O) != 0 &&
			apply_autocmds(EVENT_BUFADD_O, nil, nil, false, buf) &&
			!bufref_valid(&bref2) {
			return nil
		}
		if aborting_r() {
			// Autocmds may abort script processing.
			return nil
		}
	}
	(^u64)(uintptr(buf) + B_PROMPT_CB_OFF)^ = 0 // kCallbackNone
	(^u64)(uintptr(buf) + B_PROMPT_CB_OFF + 8)^ = 0
	(^u64)(uintptr(buf) + B_PROMPT_INT_OFF)^ = 0 // kCallbackNone
	(^u64)(uintptr(buf) + B_PROMPT_INT_OFF + 8)^ = 0
	(^rawptr)(uintptr(buf) + B_PROMPT_TEXT_OFF)^ = nil
	(^Fmark_T)(uintptr(buf) + B_PROMPT_START)^ =
		Fmark_T{mark = Pos_T{1, 0, 0}, view = INIT_FMARKV}
	(^C.int)(uintptr(buf) + B_PROMPT_START + 4)^ = 2 // default prompt is "% "
	(^bool)(uintptr(buf) + B_PROMPT_APPEND_OFF)^ = true
	return buf
}

// ── Batch 6: buf_freeall ─────────────────────────────────────────────────────

BFA_KEEP_UNDO_O :: 4
BFA_IGNORE_ABORT_O :: 8
BF_READERR_O :: C.int(0x40)
EVENT_BUFDELETE_O :: 2
EVENT_BUFUNLOAD_O :: 14
EVENT_BUFWIPEOUT_O :: 17
KEXTMARK_NO_UNDO_O :: 2

foreign _ {
	// buf_close_terminal now defined below — call directly.
	@(link_name = "end_visual_mode")
	end_visual_mode_r :: proc "c" () ---
	@(link_name = "diff_buf_delete")
	diff_buf_delete_r :: proc "c" (buf: rawptr) ---
	@(link_name = "syntax_clear")
	syntax_clear_r :: proc "c" (block: rawptr) ---
}

// Free all memory associated with a buffer (unload; wipe if BFA_WIPE).
@(export)
buf_freeall :: proc "c"(buf: rawptr, flags: C.int) -> bool {
	is_curbuf := buf == curbuf
	is_curwin := curwin != nil &&
		(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf
	the_curwin := curwin
	the_curtab := curtab
	// Make sure the buffer isn't closed by autocommands.
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
	(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ += 1
	bref: Bufref_T
	set_bufref(&bref, buf)
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil {
		buf_close_terminal(buf)
	}
	buf_updates_unload_r(buf, false)
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil &&
		apply_autocmds(EVENT_BUFUNLOAD_O, (^cstring)(uintptr(buf) + B_FNAME)^,
			(^cstring)(uintptr(buf) + B_FNAME)^, false, buf) &&
		!bufref_valid(&bref) {
		// Autocommands deleted the buffer.
		return false
	}
	if (flags & BFA_DEL_O) != 0 && (^bool)(uintptr(buf) + B_P_BL_OFF)^ &&
		apply_autocmds(EVENT_BUFDELETE_O, (^cstring)(uintptr(buf) + B_FNAME)^,
			(^cstring)(uintptr(buf) + B_FNAME)^, false, buf) &&
		!bufref_valid(&bref) {
		// Autocommands may delete the buffer.
		return false
	}
	if (flags & BFA_WIPE_O) != 0 &&
		apply_autocmds(EVENT_BUFWIPEOUT_O, (^cstring)(uintptr(buf) + B_FNAME)^,
			(^cstring)(uintptr(buf) + B_FNAME)^, false, buf) &&
		!bufref_valid(&bref) {
		// Autocommands may delete the buffer.
		return false
	}
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
	(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ -= 1
	// If the buffer was in curwin and the window has changed, go back to
	// that window, if it still exists.
	if is_curwin && curwin != the_curwin && win_valid_any_tab(the_curwin) {
		block_autocmds_r()
		goto_tabpage_win(the_curtab, the_curwin)
		unblock_autocmds_r()
	}
	// autocmds may abort script processing
	if (flags & BFA_IGNORE_ABORT_O) == 0 && aborting_r() {
		return false
	}
	// It's possible that autocommands change curbuf to the one being
	// deleted. Only return if curbuf changed to the deleted buffer.
	if buf == curbuf && !is_curbuf {
		return false
	}
	// If curbuf, stop Visual mode just before freeing, but after autocmds
	// that may restart it. (No EXITFREE in this build: no entered_free_all_mem.)
	if buf == curbuf && VIsual_active {
		end_visual_mode_r()
	}
	diff_buf_delete_r(buf) // Can't use 'diff' for unloaded buffer.
	// Remove any ownsyntax, unless exiting.
	if curwin != nil && (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf {
		reset_synblock_r(curwin)
	}
	// No folds in an empty buffer.
	tp := first_tabpage
	for tp != nil {
		wp := tp == curtab ? firstwin :
			(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				clearFolding(wp)
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
		tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
	}
	// Autocommands may have opened another terminal. Block them this time.
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil {
		block_autocmds_r()
		buf_close_terminal(buf)
		unblock_autocmds_r()
	}
	count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	ml_close_sp(buf, true) // close and delete the memline/memfile
	(^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ = 0 // no lines in buffer
	// Ensure marks are adjusted for cleared buffer in case buffer not on
	// disk: if it is reloaded the buffer will be empty.
	if bt_nofilename(buf) && !exiting {
		mark_adjust_buf(buf, 1, count, MAXLNUM, -count, false,
			kMarkAdjustNormal, KEXTMARK_NO_UNDO_O)
	}
	if (flags & BFA_KEEP_UNDO_O) == 0 {
		// free the memory allocated for undo and reset all undo information
		u_clearallandblockfree(buf)
	}
	syntax_clear_r(transmute(rawptr)(uintptr(buf) + B_S_OFF)) // reset syntax
	(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~BF_READERR_O // read err irrelevant
	return true
}

// ── Batch 7: buflist_getfile ─────────────────────────────────────────────────

GETF_ALT_O :: 0x02
GETF_SWITCH_O :: 0x04
KOPT_SWB_VSPLIT_O :: 0x10
KOPT_SWB_SPLIT_O :: 0x04
KOPT_SWB_NEWTAB_O :: 0x08
KOPT_JOP_VIEW_O :: 0x02
E_NOALT_S :: "E23: No alternate file"
E_BUFNOTFOUND_S :: "E92: Buffer %d not found"

foreign _ {
	@(link_name = "swbuf_goto_win_with_buf")
	swbuf_goto_win_with_buf_r :: proc "c" (buf: rawptr) -> rawptr ---
	@(link_name = "swb_flags")
	swb_flags_g: C.uint
	@(link_name = "tabpage_new")
	tabpage_new_r :: proc "c" () ---
	@(link_name = "p_sol")
	p_sol_g: C.int
}

// Go to buffer "n" (bnumber, alternate, ...). Return FAIL for failure.
@(export)
buflist_getfile :: proc "c"(n: C.int, lnum_in: C.int, options: C.int, forceit: C.int) -> C.int {
	wp: rawptr = nil
	fm: ^Fmark_T = nil
	buf := buflist_findnr(n)
	if buf == nil {
		if (options & GETF_ALT_O) != 0 && n == 0 {
			emsg(cstring(E_NOALT_S))
		} else {
			semsg_int_o(cstring(E_BUFNOTFOUND_S), n)
		}
		return FAIL
	}
	// if alternate file is the current buffer, nothing to do
	if buf == curbuf {
		return OK
	}
	if text_or_buf_locked_r() {
		return FAIL
	}
	lnum := lnum_in
	col: C.int = 0
	restore_view := false
	// altfpos may be changed by getfile(), get it now
	if lnum == 0 {
		fm = transmute(^Fmark_T)(buflist_findfmark(buf))
		lnum = fm.mark.lnum
		col = fm.mark.col
		restore_view = true
	}
	if (options & GETF_SWITCH_O) != 0 {
		// If 'switchbuf' is set jump to the window containing "buf".
		wp = swbuf_goto_win_with_buf_r(buf)
		// If 'switchbuf' contains "split", "vsplit" or "newtab" and the
		// current buffer isn't empty: open new tab or window
		if wp == nil &&
			(swb_flags_g & (KOPT_SWB_VSPLIT_O | KOPT_SWB_SPLIT_O | KOPT_SWB_NEWTAB_O)) != 0 &&
			!buf_is_empty(curbuf) {
			if (swb_flags_g & KOPT_SWB_NEWTAB_O) != 0 {
				tabpage_new_r()
			} else if win_split(0, (swb_flags_g & KOPT_SWB_VSPLIT_O) != 0 ? WSP_VERT_O : 0) == FAIL {
				return FAIL
			}
			(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false // RESET_BINDING
			(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
		}
	}
	RedrawingDisabled += 1
	// GETFILE_SUCCESS(x) is ((x) <= 0): getfile returns 0/-ve on success.
	if getfile((^C.int)(uintptr(buf) + B_FNUM_OFF)^, nil, nil,
		(options & GETF_SETMARK) != 0, lnum, forceit != 0) <= 0 {
		RedrawingDisabled -= 1
		// cursor is at to BOL and w_cursor.lnum is checked due to getfile()
		if p_sol_g == 0 && col != 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col // w_cursor.col
			check_cursor_col_r(curwin)
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0 // coladd
			(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
		}
		if (jop_flags & KOPT_JOP_VIEW_O) != 0 && restore_view {
			mark_view_restore(fm)
		}
		return OK
	}
	RedrawingDisabled -= 1
	return FAIL
}

// ── Batch 8: alternate-file helpers ──────────────────────────────────────────

CMOD_KEEPALT_O :: 0x0100

// Create a buffer for the alternate file; set w_alt_fnum unless :keepalt.
@(export)
setaltfname :: proc "c"(ffname: cstring, sfname: cstring, lnum: C.int) -> rawptr {
	// Create a buffer. 'buflisted' is not set if it's a new buffer.
	buf := buflist_new(ffname, sfname, lnum, 0)
	if buf != nil && (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
		(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
	}
	return buf
}

// Get alternate file name for current window. NULL if none (E23 if errmsg).
@(export)
getaltfname :: proc "c"(errmsg: bool) -> cstring {
	aname: ^u8 = nil
	dummy: C.int = 0
	if buflist_name_nr(0, &aname, &dummy) == FAIL {
		if errmsg {
			emsg(cstring(E_NOALT_S))
		}
		return nil
	}
	return transmute(cstring)(aname)
}

// Add a file name to the buflist and return its number.
@(export)
buflist_add :: proc "c"(fname: cstring, flags: C.int) -> C.int {
	buf := buflist_new(fname, nil, 0, flags)
	if buf != nil {
		return (^C.int)(uintptr(buf) + B_FNUM_OFF)^
	}
	return 0
}

// Set alternate cursor position for the current buffer and window "win".
@(export)
buflist_altfpos :: proc "c"(win: rawptr) {
	buflist_setfpos(curbuf, win, (^C.int)(uintptr(win) + W_CURSOR_OFF)^,
		(^C.int)(uintptr(win) + W_CURSOR_OFF + 4)^, true)
}

// Check that "ffname" is not the same file as current file.
@(export)
otherfile :: proc "c"(ffname: cstring) -> bool {
	return otherfile_buf_o(curbuf, ffname, nil, false)
}

// ── Batch 9: buffer-naming cluster ───────────────────────────────────────────

E95_S :: "E95: Buffer with this name already exists"
DOBUF_WIPE_O :: 4

foreign _ {
	@(link_name = "FullName_save")
	fullname_save_r :: proc "c" (fname: cstring, force: bool) -> cstring ---
	@(link_name = "ml_setname")
	ml_setname_r :: proc "c" (buf: rawptr) ---
	@(link_name = "check_arg_idx")
	check_arg_idx_r :: proc "c" (win: rawptr) ---
	@(link_name = "ml_timestamp")
	ml_timestamp_r :: proc "c" (buf: rawptr) ---
}

// Find file in buffer list by name (must be for the current window).
@(export)
buflist_findname_exp :: proc "c"(fname: cstring) -> rawptr {
	buf: rawptr = nil
	// First make the name into a full path name (force expansion on UNIX).
	ffname := fullname_save_r(fname, true)
	if ffname != nil {
		buf = buflist_findname(ffname)
		xfree(transmute(rawptr)(ffname))
	}
	return buf
}

// Find file in buffer list by full-path name. Skips dummy buffers.
@(export)
buflist_findname :: proc "c"(ffname: cstring) -> rawptr {
	file_id: FileID
	file_id_valid := os_fileid(ffname, &file_id)
	return buflist_findname_file_id_o(ffname, &file_id, file_id_valid)
}

// Set the file name for a buffer. FAIL if name already in use by other buffer.
@(export)
setfname :: proc "c"(buf: rawptr, ffname_arg: cstring, sfname_arg: cstring, message: bool) -> C.int {
	ffname := ffname_arg
	sfname := sfname_arg
	obuf: rawptr = nil
	file_id: FileID
	file_id_valid := false
	if ffname == nil || b_at(transmute(^u8)(ffname), 0) == 0 {
		// Removing the name.
		if (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ != (^rawptr)(uintptr(buf) + B_FFNAME)^ {
			xfree((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
		} else {
			(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = nil
		}
		xfree((^rawptr)(uintptr(buf) + B_FFNAME)^)
		(^rawptr)(uintptr(buf) + B_FFNAME)^ = nil
	} else {
		fname_expand(buf, &ffname, &sfname) // will allocate ffname
		if ffname == nil { // out of memory
			return FAIL
		}
		// If the file name is already used in another buffer:
		// - if the buffer is loaded, fail
		// - if the buffer is not loaded, delete it from the list
		file_id_valid = os_fileid(ffname, &file_id)
		if ((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & BF_DUMMY_O) == 0 {
			obuf = buflist_findname_file_id_o(ffname, &file_id, file_id_valid)
		}
		if obuf != nil && obuf != buf {
			in_use := false
			// during startup a window may use a buffer that is not loaded yet
			tp := first_tabpage
			for tp != nil {
				wp := tp == curtab ? firstwin :
					(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
				for wp != nil {
					if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == obuf {
						in_use = true
					}
					wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				}
				tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
			}
			// it's loaded or used in a window, fail
			if (^rawptr)(uintptr(obuf) + B_ML_MFP_OFF)^ != nil || in_use {
				if message {
					emsg(cstring(E95_S))
				}
				xfree(transmute(rawptr)(ffname))
				return FAIL
			}
			// delete from the list
			close_buffer(nil, obuf, DOBUF_WIPE_O, false, false, false)
		}
		sfname = transmute(cstring)(xstrdup_o(transmute(^u8)(sfname)))
		if (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ != (^rawptr)(uintptr(buf) + B_FFNAME)^ {
			xfree((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
		}
		xfree((^rawptr)(uintptr(buf) + B_FFNAME)^)
		(^rawptr)(uintptr(buf) + B_FFNAME)^ = transmute(rawptr)(ffname)
		(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = transmute(rawptr)(sfname)
	}
	(^rawptr)(uintptr(buf) + B_FNAME)^ = (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^
	if !file_id_valid {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = false
	} else {
		(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF)^ = true
		(^FileID)(uintptr(buf) + B_FILE_ID_OFF)^ = file_id
	}
	buf_name_changed(buf)
	return OK
}

// Crude way of changing the name of a buffer. Use with care!
@(export)
buf_set_name :: proc "c"(fnum: C.int, name: cstring) {
	buf := buflist_findnr(fnum)
	if buf == nil {
		return
	}
	if (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ != (^rawptr)(uintptr(buf) + B_FFNAME)^ {
		xfree((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
	}
	xfree((^rawptr)(uintptr(buf) + B_FFNAME)^)
	(^rawptr)(uintptr(buf) + B_FFNAME)^ = transmute(rawptr)(xstrdup_o(transmute(^u8)(name)))
	(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = nil
	// Allocate ffname and expand into full path.
	fname_expand(buf, transmute(^cstring)(uintptr(buf) + B_FFNAME),
		transmute(^cstring)(uintptr(buf) + B_SFNAME_OFF))
	(^rawptr)(uintptr(buf) + B_FNAME)^ = (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^
}

// Take care of what needs to be done when the name of buffer "buf" changed.
@(export)
buf_name_changed :: proc "c"(buf: rawptr) {
	// If the file name changed, also change the name of the swapfile.
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil {
		ml_setname_r(buf)
	}
	if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf {
		check_arg_idx_r(curwin) // check file name for arg list
	}
	maketitle() // set window title
	status_redraw_all_r() // status lines need to be redrawn
	fmarks_check_names(buf) // check named file marks
	ml_timestamp_r(buf) // reset timestamp
}

// ── Batch 10: set_curbuf + enter_buffer + do_buffer ──────────────────────────
// Offsets probed 2026-09-05 via off21: b_p_tw@10704 (== B_P_TW_OFF2),
// b_did_filetype@7742(bool), b_last_used@376(i64), w_topline_was_set@368(bool);
// b_help@11170/w_p_diff@832 matched existing consts.

B_DID_FILETYPE_OFF :: 7742
B_LAST_USED_OFF :: 376
W_TOPLINE_WAS_SET_OFF :: 368
EVENT_BUFWINENTER_O :: 15
SHM_FILEINFO_O :: 'F'
DOBUF_GOTO_O :: 0
DOBUF_DEL_O :: 3
DOBUF_FORCEIT_O :: 1

foreign _ {
	@(link_name = "VIsual_reselect")
	visual_reselect_g: C.int
	@(link_name = "diff_buf_add")
	diff_buf_add_r :: proc "c" (buf: rawptr) ---
	@(link_name = "need_fileinfo")
	need_fileinfo_g: bool
	@(link_name = "buf_check_timestamp")
	buf_check_timestamp_r :: proc "c" (buf: rawptr) -> C.int ---
	@(link_name = "inindent")
	inindent_r :: proc "c" (extra: C.int) -> bool ---
	@(link_name = "scroll_cursor_halfway")
	scroll_cursor_halfway_r :: proc "c" (wp: rawptr, atend: bool, prefer_above: bool) ---
}

// Wrapper around the (still C) do_buffer_ext engine.
@(export)
do_buffer :: proc "c"(action: C.int, start: C.int, dir: C.int, count: C.int, forceit: C.int) -> C.int {
	return do_buffer_ext(action, start, dir, count, forceit != 0 ? DOBUF_FORCEIT_O : 0)
}

// ── Batch 11b: do_buffer_ext engine ──────────────────────────────────────────

DOBUF_FIRST_O :: 1
DOBUF_LAST_O :: 2
DOBUF_MOD_O :: 3
DOBUF_CURRENT_O :: 0
DOBUF_SPLIT_O :: 1
DOBUF_SKIPHELP_O :: 4
KOPT_JOP_CLEAN_O :: 0x04
CMOD_CONFIRM_O :: 0x0080
E84_S :: "E84: No modified buffer found"
E85_S :: "E85: There is no listed buffer"
E86_S :: "E86: Buffer %ld does not exist"
E87_S :: "E87: Cannot go beyond last buffer"
E88_S :: "E88: Cannot go before first buffer"
E89KILL_S :: "E89: %s will be killed (add ! to override)"
E1546_S :: "E1546: Cannot switch to a closing buffer"

foreign _ {
	@(link_name = "dialog_changed")
	dialog_changed_r :: proc "c" (buf: rawptr, checkall: bool) ---
	@(link_name = "dialog_close_terminal")
	dialog_close_terminal_r :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "p_confirm")
	p_confirm_g: C.int
	@(link_name = "p_write")
	p_write_g: C.int
	@(link_name = "terminal_running")
	terminal_running_r :: proc "c" (term: rawptr) -> bool ---
	@(link_name = "can_abandon")
	can_abandon_r :: proc "c" (buf: rawptr, forceit: bool) -> bool ---
	@(link_name = "au_new_curbuf")
	au_new_curbuf_g: Bufref_T
}

// Implementation of the commands for the buffer list (:bnext, :bdelete...).
@(export)
do_buffer_ext :: proc "c"(action: C.int, start: C.int, dir: C.int, count_in: C.int, flags: C.int) -> C.int {
	count := count_in
	buf: rawptr = nil
	bp: rawptr = nil
	update_jumplist := true
	unload := action == DOBUF_UNLOAD_O || action == DOBUF_DEL_O || action == DOBUF_WIPE_O
	if start == DOBUF_FIRST_O {
		buf = firstbuf
	} else if start == DOBUF_LAST_O {
		buf = lastbuf_g
	} else {
		buf = curbuf
	}
	if start == DOBUF_MOD_O { // find next modified buffer
		for count > 0 {
			count -= 1
			for {
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				if buf == nil {
					buf = firstbuf
				}
				if buf == curbuf || bufIsChanged(buf) {
					break
				}
			}
		}
		if !bufIsChanged(buf) {
			emsg(cstring(E84_S))
			return FAIL
		}
	} else if start == DOBUF_FIRST_O && count != 0 { // find specified buffer number
		for buf != nil && (^C.int)(uintptr(buf) + B_FNUM_OFF)^ != count {
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
	} else {
		help_only := (flags & DOBUF_SKIPHELP_O) != 0 &&
			(^bool)(uintptr(buf) + B_HELP_OFF)^
		for count > 0 || (bp != buf && !unload &&
			!(help_only ? (^bool)(uintptr(buf) + B_HELP_OFF)^ :
				(^bool)(uintptr(buf) + B_P_BL_OFF)^)) {
			// remember the buffer where we start, we come back there when
			// all buffers are unlisted.
			if bp == nil {
				bp = buf
			}
			if dir == FORWARD_DIR {
				nxt := (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				buf = nxt != nil ? nxt : firstbuf
			} else {
				prv := (^rawptr)(uintptr(buf) + B_PREV_OFF)^
				buf = prv != nil ? prv : lastbuf_g
			}
			// Avoid non-help buffers if the starting point was a help
			// buffer and vice-versa. Don't count unlisted buffers.
			if unload || (help_only ? (^bool)(uintptr(buf) + B_HELP_OFF)^ :
				((^bool)(uintptr(buf) + B_P_BL_OFF)^ &&
					((flags & DOBUF_SKIPHELP_O) == 0 ||
						!(^bool)(uintptr(buf) + B_HELP_OFF)^))) {
				count -= 1
				bp = nil // use this buffer as new starting point
			}
			if bp == buf {
				// back where we started, didn't find anything.
				emsg(cstring(E85_S))
				return FAIL
			}
		}
	}
	if buf == nil { // could not find it
		if start == DOBUF_FIRST_O {
			// don't warn when deleting
			if !unload {
				semsg(cstring(E86_S), C.longlong(count))
			}
		} else if dir == FORWARD_DIR {
			emsg(cstring(E87_S))
		} else {
			emsg(cstring(E88_S))
		}
		return FAIL
	}
	if action == DOBUF_GOTO_O && buf != curbuf &&
		!check_can_set_curbuf_forceit(flags & DOBUF_FORCEIT_O) {
		// disallow navigating to another buffer when 'winfixbuf' is applied
		return FAIL
	}
	if (action == DOBUF_GOTO_O || action == DOBUF_SPLIT_O) &&
		((^C.int)(uintptr(buf) + B_FLAGS_OFF)^ & BF_DUMMY_O) != 0 {
		// disallow navigating to the dummy buffer
		semsg(cstring(E86_S), C.longlong(count))
		return FAIL
	}
	// delete buffer "buf" from memory and/or the list
	if unload {
		forward: C.int
		bref: Bufref_T
		if !can_unload_buffer_o(buf) {
			return FAIL
		}
		set_bufref(&bref, buf)
		// When unloading or deleting a buffer that's already unloaded and
		// unlisted: fail silently.
		if action != DOBUF_WIPE_O &&
			(^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil &&
			!(^bool)(uintptr(buf) + B_P_BL_OFF)^ {
			return FAIL
		}
		if (flags & DOBUF_FORCEIT_O) == 0 && bufIsChanged(buf) {
			if (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && p_write_g != 0 {
				dialog_changed_r(buf, false)
				if !bufref_valid(&bref) {
					// Autocommand deleted buffer, oops! It's not changed now.
					return FAIL
				}
				// If it's still changed fail silently, the dialog already
				// mentioned why it fails.
				if bufIsChanged(buf) {
					return FAIL
				}
			} else {
				semsg_int_o(cstring(E89_S), (^C.int)(uintptr(buf) + B_FNUM_OFF)^)
				return FAIL
			}
		}
		if (flags & DOBUF_FORCEIT_O) == 0 &&
			(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
			terminal_running_r((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^) {
			if p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0 {
				if !dialog_close_terminal_r(buf) {
					return FAIL
				}
			} else {
				semsg_safe(cstring(E89KILL_S),
					(^rawptr)(uintptr(buf) + B_FNAME)^)
				return FAIL
			}
		}
		buf_fnum := (^C.int)(uintptr(buf) + B_FNUM_OFF)^
		// When closing the current buffer stop Visual mode.
		if buf == curbuf && VIsual_active {
			end_visual_mode_r()
		}
		// If deleting the last (listed) buffer, make it empty.
		// The last (listed) buffer cannot be unloaded.
		bp = nil
		bp2 := firstbuf
		for bp2 != nil {
			if (^bool)(uintptr(bp2) + B_P_BL_OFF)^ && bp2 != buf {
				bp = bp2
				break
			}
			bp2 = (^rawptr)(uintptr(bp2) + B_NEXT_OFF)^
		}
		if bp == nil && buf == curbuf {
			return empty_curbuf_o(true, flags & DOBUF_FORCEIT_O, action)
		}
		// If the deleted buffer is the current one, close the current
		// window (unless it's the only non-floating window).
		for buf == curbuf &&
			!(win_locked(curwin) != 0 ||
				(^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) + B_LOCKED_OFF)^ > 0) &&
			(is_aucmd_win_r(lastwin_g) || !last_window(curwin)) {
			if win_close(curwin, false, false) == FAIL {
				break
			}
		}
		// If the buffer to be deleted is not the current one, delete it here.
		if buf != curbuf {
			if (jop_flags & KOPT_JOP_CLEAN_O) != 0 {
				// Remove the buffer to be deleted from the jump list.
				mark_jumplist_forget_file(curwin, buf_fnum)
			}
			close_windows(buf, false)
			// close_windows() refuses to close curtab's last non-float
			// window. If it still shows buf, retry the delete from there.
			if buf != curbuf && bufref_valid(&bref) &&
				(^rawptr)(uintptr(firstwin) + W_BUFFER_OFF)^ == buf &&
				one_window(firstwin, nil) {
				// Switch to buf's holder window without entering it.
				switchwin: Switchwin_T
				rv := switch_win_noblock_r(&switchwin, firstwin, curtab, true)
				// retry (recurse)
				do_buffer_ext(action, start, dir, count, flags)
				restore_win_noblock_r(&switchwin, true)
				_ = rv
			}
			if buf != curbuf && bufref_valid(&bref) &&
				(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 0 {
				close_buffer(nil, buf, action, false, false, false)
			}
			return OK
		}
		// Deleting the current buffer: need to find another buffer to go
		// to. First use au_new_curbuf if valid, then the most recently
		// visited (jumplist), then loaded neighbors, then any buffer.
		buf = nil // Selected buffer.
		bp = nil // Used when no loaded buffer found.
		if au_new_curbuf_g.br_buf != nil && bufref_valid(&au_new_curbuf_g) &&
			(^C.int)(uintptr(au_new_curbuf_g.br_buf) + B_LOCKED_SPLIT_OFF)^ == 0 {
			buf = au_new_curbuf_g.br_buf
		} else if (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ > 0 {
			if (jop_flags & KOPT_JOP_CLEAN_O) != 0 {
				mark_jumplist_forget_file(curwin, buf_fnum)
			}
			if (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ > 0 {
				jumpidx := (^C.int)(uintptr(curwin) + W_JUMPLISTIDX)^
				if (jop_flags & KOPT_JOP_CLEAN_O) != 0 {
					if jumpidx == (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ {
						jumpidx = (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ - 1
						(^C.int)(uintptr(curwin) + W_JUMPLISTIDX)^ = jumpidx
					}
				} else {
					jumpidx -= 1
					if jumpidx < 0 {
						jumpidx = (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ - 1
					}
				}
				forward = jumpidx
				for (jop_flags & KOPT_JOP_CLEAN_O) != 0 ||
					jumpidx != (^C.int)(uintptr(curwin) + W_JUMPLISTIDX)^ {
					jb := (^Xfmark_T)(uintptr(curwin) + W_JUMPLIST + uintptr(jumpidx) * 48)
					buf = buflist_findnr(jb.fmark.fnum)
					if buf != nil {
						// Skip current and unlisted bufs. Also skip a
						// quickfix or closing buffer (may be deleted soon).
						if buf == curbuf || !(^bool)(uintptr(buf) + B_P_BL_OFF)^ ||
							bt_quickfix(buf) ||
							(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ != 0 {
							buf = nil
						} else if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
							// skip unloaded buf, but may keep it for later
							if bp == nil {
								bp = buf
							}
							buf = nil
						}
					}
					if buf != nil { // found a valid buffer: stop searching
						if (jop_flags & KOPT_JOP_CLEAN_O) != 0 {
							(^C.int)(uintptr(curwin) + W_JUMPLISTIDX)^ = jumpidx
							update_jumplist = false
						}
						break
					}
					// advance to older entry in jump list
					if jumpidx == 0 &&
						(^C.int)(uintptr(curwin) + W_JUMPLISTIDX)^ ==
						(^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ {
						break
					}
					jumpidx -= 1
					if jumpidx < 0 {
						jumpidx = (^C.int)(uintptr(curwin) + W_JUMPLISTLEN)^ - 1
					}
					if jumpidx == forward { // List exhausted for sure
						break
					}
				}
			}
		}
		if buf == nil { // No previous buffer, Try 2'nd approach
			fwd := true
			buf = (^rawptr)(uintptr(curbuf) + B_NEXT_OFF)^
			for {
				if buf == nil {
					if !fwd { // tried both directions
						break
					}
					buf = (^rawptr)(uintptr(curbuf) + B_PREV_OFF)^
					fwd = false
					continue
				}
				// in non-help buffer, try to skip help buffers, and vv
				if (^bool)(uintptr(buf) + B_HELP_OFF)^ ==
					(^bool)(uintptr(curbuf) + B_HELP_OFF)^ &&
					(^bool)(uintptr(buf) + B_P_BL_OFF)^ &&
					!bt_quickfix(buf) &&
					(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ == 0 {
					if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil { // loaded
						break
					}
					if bp == nil { // remember unloaded buf for later
						bp = buf
					}
				}
				buf = fwd ? (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ :
					(^rawptr)(uintptr(buf) + B_PREV_OFF)^
			}
		}
		if buf == nil { // No loaded buffer, use unloaded one
			buf = bp
		}
		if buf == nil { // No loaded buffer, find listed one
			buf2 := firstbuf
			for buf2 != nil {
				if (^bool)(uintptr(buf2) + B_P_BL_OFF)^ && buf2 != curbuf &&
					!bt_quickfix(buf2) &&
					(^C.int)(uintptr(buf2) + B_LOCKED_SPLIT_OFF)^ == 0 {
					buf = buf2
					break
				}
				buf2 = (^rawptr)(uintptr(buf2) + B_NEXT_OFF)^
			}
		}
		if buf == nil { // Still no buffer, just take one
			nxt := (^rawptr)(uintptr(curbuf) + B_NEXT_OFF)^
			if nxt != nil {
				buf = nxt
			} else {
				buf = (^rawptr)(uintptr(curbuf) + B_PREV_OFF)^
			}
			if bt_quickfix(buf) ||
				(buf != curbuf &&
					(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ != 0) {
				buf = nil
			}
		}
	}
	if buf == nil {
		// Autocommands must have wiped out all other buffers. Only option
		// now is to make the current buffer empty.
		return empty_curbuf_o(false, flags & DOBUF_FORCEIT_O, action)
	}
	// make "buf" the current buffer
	// If 'switchbuf' is set jump to the window containing "buf".
	if action == DOBUF_SPLIT_O && swbuf_goto_win_with_buf_r(buf) != nil {
		return OK
	}
	// Whether splitting or not, don't open a closing buffer in more windows.
	if buf != curbuf &&
		(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ != 0 {
		emsg(cstring(E1546_S))
		return FAIL
	}
	if action == DOBUF_SPLIT_O && win_split(0, 0) == FAIL { // split window first
		return FAIL
	}
	// go to current buffer - nothing to do
	if buf == curbuf {
		return OK
	}
	// Check if the current buffer may be abandoned.
	if action == DOBUF_GOTO_O && !can_abandon_r(curbuf, (flags & DOBUF_FORCEIT_O) != 0) {
		if (p_confirm_g != 0 || (cmdmod_cmod_flags & CMOD_CONFIRM_O) != 0) && p_write_g != 0 {
			bref2: Bufref_T
			set_bufref(&bref2, buf)
			dialog_changed_r(curbuf, false)
			if !bufref_valid(&bref2) {
				// Autocommand deleted buffer, oops!
				return FAIL
			}
		}
		if bufIsChanged(curbuf) {
			no_write_message()
			return FAIL
		}
	}
	// Go to the other buffer.
	set_curbuf(buf, action, update_jumplist)
	if action == DOBUF_SPLIT_O {
		(^bool)(uintptr(curwin) + W_P_SCB_OFF)^ = false // RESET_BINDING
		(^bool)(uintptr(curwin) + W_P_CRB_OFF)^ = false
	}
	if aborting_r() { // autocmds may abort script processing
		return FAIL
	}
	return OK
}

// Go to the last known line number for the current buffer (C static).
buflist_getfpos_o :: proc "c"() {
	fm := transmute(^Fmark_T)(buflist_findfmark(curbuf))
	fpos := &fm.mark
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = fpos.lnum
	check_cursor_lnum_r(curwin)
	if p_sol_g != 0 {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	} else {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = fpos.col
		check_cursor_col_r(curwin)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	}
	if (jop_flags & KOPT_JOP_VIEW_O) != 0 {
		mark_view_restore(fm)
	}
}

// Set current buffer to "buf". Executes autocommands and closes old buffer.
@(export)
set_curbuf :: proc "c"(buf: rawptr, action: C.int, update_jumplist: bool) {
	unload := action == DOBUF_UNLOAD_O || action == DOBUF_DEL_O || action == DOBUF_WIPE_O
	old_tw := (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^
	if update_jumplist {
		setpcmark()
	}
	if (cmdmod_cmod_flags & CMOD_KEEPALT_O) == 0 {
		(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ = (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^
	}
	buflist_altfpos(curwin) // remember curpos
	// Don't restart Select mode after switching to another buffer.
	visual_reselect_g = 0
	// close_windows() or apply_autocmds() may change curbuf and wipe "buf".
	prevbuf := curbuf
	prevbufref: Bufref_T
	newbufref: Bufref_T
	set_bufref(&prevbufref, prevbuf)
	set_bufref(&newbufref, buf)
	// Autocommands may delete the current buffer and/or the buffer we want
	// to go to. In those cases don't close the buffer.
	if !apply_autocmds(EVENT_BUFLEAVE_O, nil, nil, false, curbuf) ||
		(bufref_valid(&prevbufref) && bufref_valid(&newbufref) && !aborting_r()) {
		if prevbuf == (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ {
			reset_synblock_r(curwin)
		}
		if unload {
			close_windows(prevbuf, false)
		}
		if bufref_valid(&prevbufref) && !aborting_r() {
			// Do not sync when in Insert mode and the buffer is open in
			// another window (might be a timer in another window).
			if prevbuf == curbuf &&
				((State & MODE_INSERT) == 0 || (^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ <= 1) {
				u_sync(false)
			}
			close_buffer(curwin, prevbuf,
				unload ? action :
				(action == DOBUF_GOTO_O && !buf_hide(prevbuf) &&
					!bufIsChanged(prevbuf)) ? DOBUF_UNLOAD_O : 0,
				false, false, true)
		}
	}
	// An autocommand may have deleted "buf", already entered it, or aborted.
	// If curwin->w_buffer is null, enter_buffer() will make it valid again.
	valid := buf_valid(buf)
	if (valid && buf != curbuf && !aborting_r()) ||
		(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == nil {
		// If the buffer is not valid but curwin->w_buffer is NULL we must
		// enter some buffer. Using the last one is hopefully OK.
		enter_buffer_o(valid ? buf : lastbuf_g)
		if old_tw != (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^ {
			check_colorcolumn_r(nil, curwin)
		}
	}
	if bufref_valid(&prevbufref) &&
		(^rawptr)(uintptr(prevbuf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(prevbuf) + B_TERMINAL_OFF)^)
	}
}

// Enter a new current buffer. Old curbuf must have been abandoned already!
// (C static: no export/weak.)
enter_buffer_o :: proc "c"(buf: rawptr) {
	// Stop Visual mode before changing curbuf (buf_freeall should've done
	// this already if curwin->w_buffer is invalid). No EXITFREE in build.
	if VIsual_active {
		end_visual_mode_r()
	}
	if (^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ != nil {
		(^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^) + B_NWINDOWS_OFF)^ -= 1
	}
	// Get the buffer in the current window.
	(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ = buf
	curbuf = buf
	(^C.int)(uintptr(curbuf) + B_NWINDOWS_OFF)^ += 1
	// Copy buffer and window local option values. Not for a help buffer.
	buf_copy_options(buf, BCO_ENTER_O | BCO_NOHELP_S)
	if !(^bool)(uintptr(buf) + B_HELP_OFF)^ {
		get_winopts(buf)
	} else {
		// Remove all folds in the window.
		clearFolding(curwin)
	}
	foldUpdateAll(curwin) // update folds (later).
	if (^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ != 0 {
		diff_buf_add_r(curbuf)
	}
	// ADDRESS of embedded b_s (Batch-10 lesson).
	(^rawptr)(uintptr(curwin) + W_S_OFF)^ =
		transmute(rawptr)(uintptr(curbuf) + B_S_OFF)
	// Cursor on first line by default.
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = 1
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
	(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	(^bool)(uintptr(curwin) + W_TOPLINE_WAS_SET_OFF)^ = false
	// mark cursor position as being invalid
	(^C.int)(uintptr(curwin) + W_VALID_OFF)^ = 0
	// Make sure the buffer is loaded.
	if (^rawptr)(uintptr(curbuf) + B_ML_MFP_OFF)^ == nil { // need to load file
		// If there is no filetype, allow for detecting one.
		if b_at((^u8)(uintptr(curbuf) + B_P_FT_OFF), 0) == 0 {
			(^bool)(uintptr(curbuf) + B_DID_FILETYPE_OFF)^ = false
		}
		open_buffer(false, nil, 0)
	} else {
		if msg_silent == 0 && !shortmess(SHM_FILEINFO_O) {
			need_fileinfo_g = true // display file info after redraw
		}
		// check if file changed
		buf_check_timestamp_r(curbuf)
		(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = 1
		(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ = 0
		apply_autocmds(EVENT_BUFENTER_O, nil, nil, false, curbuf)
		apply_autocmds(EVENT_BUFWINENTER_O, nil, nil, false, curbuf)
	}
	// If autocommands did not change the cursor position, restore cursor
	// lnum and possibly cursor col.
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == 1 && inindent_r(0) {
		buflist_getfpos_o()
	}
	check_arg_idx_r(curwin) // check for valid arg_idx
	maketitle()
	// when autocmds didn't change it
	if (^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ == 1 &&
		!(^bool)(uintptr(curwin) + W_TOPLINE_WAS_SET_OFF)^ {
		scroll_cursor_halfway_r(curwin, false, false) // redisplay at position
	}
	// Change directories when the 'acd' option is set.
	do_autochdir()
	if (^i16)(uintptr(curbuf) + B_KMAP_STATE_OFF)^ & i16(KEYMAP_INIT_S) != 0 {
		keymap_init()
	}
	// May need to set the spell language (only after proper setup).
	if !(^bool)(uintptr(curbuf) + B_HELP_OFF)^ &&
		(^C.int)(uintptr(curwin) + W_P_SPELL_OFF)^ != 0 {
		ws := (^rawptr)(uintptr(curwin) + W_S_OFF)^
		spl := (^rawptr)(uintptr(ws) + SB_P_SPL_OFF)^
		if spl != nil && b_at(transmute(^u8)(spl), 0) != 0 {
			parse_spelllang(curwin)
		}
	}
	(^C.longlong)(uintptr(curbuf) + B_LAST_USED_OFF)^ = C.longlong(libc.time(nil))
	if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
		terminal_check_size_r((^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^)
	}
	redraw_later(curwin, UPD_NOT_VALID)
}

// ── Batch 11a: do_buffer_ext helpers (dormant; engine ports next) ────────────

B_SAVING_OFF :: 272
ECMD_ONE_O :: 1
ECMD_FORCEIT_O :: 0x08
E937_S :: "E937: Attempt to delete a buffer that is in use: %s"

foreign _ {
	@(link_name = "updating_screen")
	updating_screen_g: bool
	// do_ecmd now defined in ex_cmds.odin — call directly.
}

// Can buffer "buf" be unloaded? (C static: no export/weak.)
can_unload_buffer_o :: proc "c"(buf: rawptr) -> bool {
	can_unload := (^C.int)(uintptr(buf) + B_LOCKED_OFF)^ == 0
	if can_unload && updating_screen_g {
		// FOR_ALL_WINDOWS_IN_TAB(wp, curtab) = firstwin (curtab nuance).
		wp := firstwin
		for wp != nil {
			if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
				can_unload = false
				break
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	// Don't unload the buffer while it's still being saved.
	if can_unload && (^bool)(uintptr(buf) + B_SAVING_OFF)^ {
		can_unload = false
	}
	if !can_unload {
		fname := (^rawptr)(uintptr(buf) + B_FNAME)^
		if fname == nil {
			fname = (^rawptr)(uintptr(buf) + B_FFNAME)^
		}
		semsg_safe(cstring(E937_S),
			fname != nil ? transmute(rawptr)(fname) : transmute(rawptr)(cstring("[No Name]")))
	}
	return can_unload
}

// Make the current buffer empty (delete/unload last buffer). (C static.)
empty_curbuf_o :: proc "c"(close_others: bool, forceit: C.int, action: C.int) -> C.int {
	buf := curbuf
	if action == DOBUF_UNLOAD_O {
		emsg(cstring("E90: Cannot unload last buffer"))
		return FAIL
	}
	bref: Bufref_T
	set_bufref(&bref, buf)
	if close_others {
		can_close_all_others := true
		if (^bool)(uintptr(curwin) + W_FLOATING_OFF)^ {
			// Closing all other windows with this buffer may leave only
			// floating windows.
			can_close_all_others = false
			wp := firstwin
			for !(^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
				if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ != curbuf {
					// Found another non-floating window with a different
					// (probably unlisted) buffer: closing is fine.
					can_close_all_others = true
					break
				}
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
		}
		// If fine to close all other windows with this buffer, keep the
		// current window and close others; otherwise close_windows() would
		// refuse the last non-floating window, so allow closing current.
		close_windows(buf, can_close_all_others)
	}
	setpcmark()
	retval := do_ecmd(0, nil, nil, nil, ECMD_ONE_O, forceit != 0 ? ECMD_FORCEIT_O : 0, curwin)
	// do_ecmd() may create a new buffer, then we have to delete the old
	// one. But do_ecmd() may have done that already: check if the buffer
	// still exists.
	if buf != curbuf && bufref_valid(&bref) &&
		(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0 {
		close_buffer(nil, buf, action, false, false, false)
	}
	if !close_others {
		need_fileinfo_g = false
	} else if retval == OK && !shortmess(SHM_FILEINFO_O) {
		// do_ecmd() does not display file info for a new empty buffer.
		need_fileinfo_g = true
	}
	return retval
}

// ── Batch 12: goto_buffer + handle_swap_exists ───────────────────────────────
// exarg_T offsets probed earlier (cmdidx@64/cmd@40/forceit@76); CMD_bnext=30,
// sbnext=397, bNext=21, bprevious=32, sbNext=392, sbprevious=398; cleanup_T=16B.

CMD_BNEXT_O :: 30
CMD_SBNEXT_O :: 397
CMD_BNEXT_UP_O :: 21
CMD_BPREV_O :: 32
CMD_SBNEXT_UP_O :: 392
CMD_BPREV_UP_O :: 398
SEA_NONE_O :: 0
SEA_DIALOG_O :: 1
SEA_QUIT_O :: 2
SEA_RECOVER_O :: 3
EXARG_CMD_OFF :: 40
EXARG_CMDIDX_OFF :: 64
EXARG_FORCEIT_OFF :: 76

foreign _ {
	@(link_name = "enter_cleanup")
	enter_cleanup_r :: proc "c" (csp: rawptr) ---
	@(link_name = "leave_cleanup")
	leave_cleanup_r :: proc "c" (csp: rawptr) ---
	@(link_name = "ml_recover")
	ml_recover_r :: proc "c" (checkext: bool) ---
	// do_modelines now defined below — call directly.
	@(link_name = "swap_exists_action")
	swap_exists_action_g: C.int
	@(link_name = "swap_exists_did_quit")
	swap_exists_did_quit_g: bool
}

// Go to another buffer. Handles the result of the ATTENTION dialog.
@(export)
goto_buffer :: proc "c"(eap: rawptr, start: C.int, dir: C.int, count: C.int) {
	save_sea := swap_exists_action_g
	skip_help_buf := false
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	if cmdidx == CMD_BNEXT_O || cmdidx == CMD_SBNEXT_O || cmdidx == CMD_BNEXT_UP_O ||
		cmdidx == CMD_BPREV_O || cmdidx == CMD_SBNEXT_UP_O || cmdidx == CMD_BPREV_UP_O {
		skip_help_buf = true
	}
	old_curbuf: Bufref_T
	set_bufref(&old_curbuf, curbuf)
	if swap_exists_action_g == SEA_NONE_O {
		swap_exists_action_g = SEA_DIALOG_O
	}
	cmd := (^cstring)(uintptr(eap) + EXARG_CMD_OFF)^
	forceit := (^C.int)(uintptr(eap) + EXARG_FORCEIT_OFF)^
	_ = do_buffer_ext(cmd != nil && b_at(transmute(^u8)(cmd), 0) == 's' ? DOBUF_SPLIT_O : DOBUF_GOTO_O,
		start, dir, count,
		(forceit != 0 ? DOBUF_FORCEIT_O : 0) | (skip_help_buf ? DOBUF_SKIPHELP_O : 0))
	if swap_exists_action_g == SEA_QUIT_O && cmd != nil && b_at(transmute(^u8)(cmd), 0) == 's' {
		cs: [16]u8
		// Reset the error/interrupt/exception state here so that
		// aborting() returns false when closing a window.
		enter_cleanup_r(&cs[0])
		// Quitting means closing the split window, nothing else.
		win_close(curwin, true, false)
		swap_exists_action_g = save_sea
		swap_exists_did_quit_g = true
		// Restore the error/interrupt/exception state if not discarded by a
		// new aborting error, interrupt, or uncaught exception.
		leave_cleanup_r(&cs[0])
	} else {
		handle_swap_exists(&old_curbuf)
	}
}

// Handle the situation of swap_exists_action being set.
@(export)
handle_swap_exists :: proc "c"(old_curbuf: ^Bufref_T) {
	old_tw := (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^
	buf: rawptr
	if swap_exists_action_g == SEA_QUIT_O {
		cs: [16]u8
		// Reset the error/interrupt/exception state here so that
		// aborting() returns false when closing a buffer.
		enter_cleanup_r(&cs[0])
		// User selected Quit at ATTENTION prompt. Go back to previous
		// buffer. If that buffer is gone or the same as the current one,
		// open a new, empty buffer.
		swap_exists_action_g = SEA_NONE_O // don't want it again
		swap_exists_did_quit_g = true
		close_buffer(curwin, curbuf, DOBUF_UNLOAD_O, false, false, true)
		if old_curbuf == nil || !bufref_valid(old_curbuf) || old_curbuf.br_buf == curbuf {
			// Block autocommands here because curwin->w_buffer may be NULL.
			block_autocmds_r()
			buf = buflist_new(nil, nil, 1, BLN_CURBUF_O | BLN_LISTED_O)
			unblock_autocmds_r()
		} else {
			buf = old_curbuf.br_buf
		}
		if buf != nil {
			enter_buffer_o(buf)
			if old_tw != (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^ {
				check_colorcolumn_r(nil, curwin)
			}
		}
		// If "old_curbuf" is NULL we are in big trouble here...
		// Restore the error/interrupt/exception state if not discarded by a
		// new aborting error, interrupt, or uncaught exception.
		leave_cleanup_r(&cs[0])
	} else if swap_exists_action_g == SEA_RECOVER_O {
		// Reset the error/interrupt/exception state here so that
		// aborting() returns false when recovering.
		cs: [16]u8
		enter_cleanup_r(&cs[0])
		// User selected Recover at ATTENTION prompt.
		msg_scroll = true
		ml_recover_r(false)
		msg_puts(cstring("\n")) // don't overwrite the last message
		cmdline_row = msg_row
		do_modelines(0)
		// Restore the error/interrupt/exception state if not discarded by a
		// new aborting error, interrupt, or uncaught exception.
		leave_cleanup_r(&cs[0])
	}
	swap_exists_action_g = SEA_NONE_O
}

// ── Batch 13: free_buffer (dormant; close_buffer ports later) ────────────────
// additional_data@12496 probed via off25 (b_namedm/b_changelist/dv_refcount
// all matched existing consts).

B_ADDITIONAL_DATA_OFF :: 12496
DV_REFCOUNT_OFF :: 8
DO_NOT_FREE_CNT_O :: 0x3fffffff
JUMPLISTSIZE_O :: 100

foreign _ {
	@(link_name = "nvim_odin_set_buf_free_count")
	nvim_odin_set_buf_free_count_r :: proc "c" (v: C.int) ---
	@(link_name = "tv_dict_item_copy")
	tv_dict_item_copy_r :: proc "c" (di: rawptr) -> rawptr ---
	@(link_name = "aubuflocal_remove")
	aubuflocal_remove_r :: proc "c" (buf: rawptr) ---
	@(link_name = "au_pending_free_buf")
	au_pending_free_buf_g: rawptr
}

// Free a buffer structure and its buffer-related contents (C static).
// The file itself must have been dealt with already (buf_freeall).
free_buffer_o :: proc "c"(buf: rawptr) {
	map_del_int_ptr_t(&buffer_handles_g, (^C.int)(uintptr(buf) + B_FNUM_OFF)^, nil)
	nvim_odin_set_buf_free_count_r(nvim_odin_get_buf_free_count_r() + 1)
	// b:changedtick uses an item in buf_T.
	free_buffer_stuff_o(buf, KBFF_CLEAR_WININFO_O)
	vars := (^rawptr)(uintptr(buf) + B_VARS_OFF)^
	if (^C.int)(uintptr(vars) + DV_REFCOUNT_OFF)^ > DO_NOT_FREE_CNT_O {
		tv_dict_add_r(vars,
			tv_dict_item_copy_r(transmute(rawptr)(uintptr(buf) + B_CHANGEDTICK_DI_OFF)))
	}
	unref_var_dict_r(vars)
	aubuflocal_remove_r(buf)
	xfree((^rawptr)(uintptr(buf) + B_ADDITIONAL_DATA_OFF)^)
	xfree((^rawptr)(uintptr(buf) + B_PROMPT_TEXT_OFF)^)
	// kv_destroy(buf->b_wininfo).
	it := (^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^
	if it != nil {
		xfree(it)
	}
	(^uint)(uintptr(buf) + B_WINFOFF_SIZE)^ = 0
	(^uint)(uintptr(buf) + B_WINFOFF_CAP)^ = 0
	(^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^ = nil
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_PROMPT_CB_OFF))
	callback_free_r(transmute(rawptr)(uintptr(buf) + B_PROMPT_INT_OFF))
	clear_fmark(transmute(^Fmark_T)(uintptr(buf) + B_LAST_CURSOR), 0)
	clear_fmark(transmute(^Fmark_T)(uintptr(buf) + B_LAST_INSERT), 0)
	clear_fmark(transmute(^Fmark_T)(uintptr(buf) + B_LAST_CHANGE), 0)
	clear_fmark(transmute(^Fmark_T)(uintptr(buf) + B_PROMPT_START), 0)
	for i := 0; i < NMARKS; i += 1 {
		free_fmark((^Fmark_T)(uintptr(buf) + B_NAMEDM + uintptr(i) * 40)^)
	}
	for i := 0; i < int((^C.int)(uintptr(buf) + B_CHANGELISTLEN)^); i += 1 {
		free_fmark((^Fmark_T)(uintptr(buf) + B_CHANGELIST + uintptr(i) * 40)^)
	}
	if autocmd_busy_g {
		// Do not free the buffer structure while autocommands are executing,
		// it's still needed. Free it when autocmd_busy is reset.
		// CLEAR_FIELD(b_namedm): 26 x 40B.
		libc.memset(rawptr(uintptr(buf) + B_NAMEDM), 0, NMARKS * 40)
		// CLEAR_FIELD(b_changelist): 100 x 40B.
		libc.memset(rawptr(uintptr(buf) + B_CHANGELIST), 0, JUMPLISTSIZE_O * 40)
		(^rawptr)(uintptr(buf) + B_NEXT_OFF)^ = au_pending_free_buf_g
		au_pending_free_buf_g = buf
	} else {
		xfree(buf)
		if curbuf == buf {
			curbuf = nil // make clear it's not to be used
		}
	}
}

// ── Batch 14: open_buffer + read_buffer + buf_ensure_loaded ──────────────────
// Offsets probed 2026-09-05 via off26: b_p_ro@10616(int)/b_p_bin@10136(int)/
// b_modified_was_set@7741(bool)/b_last_changedtick@248+256+264(i64)/
// mf_dirty@172(int)/aco_save_T 56B. OPEN_CHR_FILES is BSD-only → Linux path is
// fifo/sock only.

// B_P_RO/B_P_BIN reused from option.odin (10616/10136, matched probe).
B_MODIFIED_WAS_SET_OFF :: 7741
B_LAST_CHANGEDTICK_OFF :: 248
B_LAST_CHANGEDTICK_I_OFF :: 256
B_LAST_CHANGEDTICK_PUM_OFF :: 264
MF_DIRTY_OFF :: 172
MF_DIRTY_YES_O :: 1
MF_DIRTY_YES_NOSYNC_O :: 2
READ_NEW_O :: 0x01
READ_STDIN_O :: 0x04
READ_BUFFER_O :: 0x08
READ_FIFO_O :: 0x40
READ_NOWINENTER_O :: 0x80
READ_NOFILE_O :: 0x100
CPO_INTMOD_O :: 'i'
VALID_TOPLINE_O :: 0x80
EVENT_STDINREADPOST_O :: 108
E82_S :: "E82: Cannot allocate any buffer, exiting..."
E83_S :: "E83: Cannot allocate buffer, using other one..."

foreign _ {
	@(link_name = "readfile")
	readfile_r :: proc "c" (fname: cstring, sfname: cstring, from: C.int, lines_to_skip: C.int, lines_to_read: C.int, eap: rawptr, flags: C.int, silent: bool) -> C.int ---
	@(link_name = "apply_autocmds_retval")
	apply_autocmds_retval_r :: proc "c" (event: C.int, fname: cstring, fname2: cstring, force: bool, buf: rawptr, retval: ^C.int) -> bool ---
	@(link_name = "aucmd_prepbuf")
	aucmd_prepbuf_r :: proc "c" (aco: rawptr, buf: rawptr) ---
	@(link_name = "aucmd_restbuf")
	aucmd_restbuf_r :: proc "c" (aco: rawptr) ---
	@(link_name = "ml_open")
	ml_open_r :: proc "c" (buf: rawptr) -> C.int ---
	@(link_name = "save_file_ff")
	save_file_ff_r :: proc "c" (buf: rawptr) ---
	@(link_name = "get_local_additions")
	get_local_additions_r :: proc "c" () ---
	@(link_name = "readonlymode")
	readonlymode_g: bool
}

// True for "nofile"/"quickfix"/"terminal"/"prompt" buffers: not read from file.
bt_nofileread_o :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^cstring)(uintptr(buf) + B_P_BT_OFF)^
	if bt == nil {
		return false
	}
	c0 := b_at(transmute(^u8)(bt), 0)
	c2 := b_at(transmute(^u8)(bt), 2)
	return (c0 == 'n' && c2 == 'f') || c0 == 't' || c0 == 'q' || c0 == 'p'
}

// Read data from buffer for retrying (fifo/stdin second pass). (C static.)
read_buffer_o :: proc "c"(read_stdin: bool, eap: rawptr, flags: C.int) -> C.int {
	retval: C.int = OK
	silent := shortmess(SHM_FILEINFO_O)
	// Read from the buffer which the text is already filled in and append
	// at the end (allows retry when fileformat/fileencoding was misguessed).
	line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	ff := read_stdin ? nil : (^cstring)(uintptr(curbuf) + B_FFNAME)^
	sf := read_stdin ? nil : (^cstring)(uintptr(curbuf) + B_FNAME)^
	retval = readfile_r(ff, sf, line_count, 0, MAXLNUM, eap, flags | READ_BUFFER_O, silent)
	if retval == OK {
		// Delete the binary lines.
		line_count -= 1
		for line_count >= 0 {
			ml_delete_r(1)
			line_count -= 1
		}
	} else {
		// Delete the converted lines.
		for (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ > line_count {
			ml_delete_r(line_count)
		}
	}
	// Put the cursor on the first line.
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = 1
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
	if read_stdin {
		// Set or reset 'modified' before executing autocommands, so that
		// it can be changed there.
		if !readonlymode_g && !buf_is_empty(curbuf) {
			changed_r(curbuf)
		} else if retval != FAIL {
			unchanged_r(curbuf, false, true)
		}
		apply_autocmds_retval_r(EVENT_STDINREADPOST_O, nil, nil, false, curbuf, &retval)
	}
	return retval
}

// Ensure buffer "buf" is loaded.
@(export)
buf_ensure_loaded :: proc "c"(buf: rawptr) -> bool {
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil {
		return true // already open (common case)
	}
	aco: [56]u8
	// Make sure the buffer is in a window.
	aucmd_prepbuf_r(&aco[0], buf)
	// status can be OK or NOTDONE (which also means ok/done)
	status := open_buffer(false, nil, 0)
	aucmd_restbuf_r(&aco[0])
	return status != FAIL
}

// Open current buffer: open the memfile and read the file into memory.
@(export)
open_buffer :: proc "c"(read_stdin: bool, eap: rawptr, flags_arg: C.int) -> C.int {
	flags := flags_arg
	retval: C.int = OK
	old_curbuf: Bufref_T
	old_tw := (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^
	read_fifo := false
	silent := shortmess(SHM_FILEINFO_O)
	// The 'readonly' flag is only set when BF_NEVERLOADED is being reset.
	if readonlymode_g && (^rawptr)(uintptr(curbuf) + B_FFNAME)^ != nil &&
		((^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ & BF_NEVERLOADED_O) != 0 {
		(^C.int)(uintptr(curbuf) + B_P_RO_OFF)^ = 1
	}
	if ml_open_r(curbuf) == FAIL {
		// There MUST be a memfile, otherwise we can't do anything.
		close_buffer(curwin, curbuf, 0, false, false, false)
		curbuf = nil
		bf := firstbuf
		for bf != nil {
			if (^rawptr)(uintptr(bf) + B_ML_MFP_OFF)^ != nil {
				curbuf = bf
				break
			}
			bf = (^rawptr)(uintptr(bf) + B_NEXT_OFF)^
		}
		// If there is no memfile at all, exit (no changes to lose).
		if curbuf == nil {
			emsg(cstring(E82_S))
			// Don't try to do any saving, with "curbuf" NULL almost
			// nothing will work.
			v_dying = 2
			getout(2)
		}
		emsg(cstring(E83_S))
		enter_buffer_o(curbuf)
		if old_tw != (^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^ {
			check_colorcolumn_r(nil, curwin)
		}
		return FAIL
	}
	// Do not sync this buffer yet, may first want to read the file.
	mfp := (^rawptr)(uintptr(curbuf) + B_ML_MFP_OFF)^
	if mfp != nil {
		(^C.int)(uintptr(mfp) + MF_DIRTY_OFF)^ = MF_DIRTY_YES_NOSYNC_O
	}
	// The autocommands in readfile() may change the buffer, but only AFTER
	// reading the file.
	set_bufref(&old_curbuf, curbuf)
	(^bool)(uintptr(curbuf) + B_MODIFIED_WAS_SET_OFF)^ = false
	// mark cursor position as being invalid
	(^C.int)(uintptr(curwin) + W_VALID_OFF)^ = 0
	// A buffer without an actual file should not use the buffer name.
	if bt_nofileread_o(curbuf) {
		flags |= READ_NOFILE_O
	}
	// Read the file if there is one.
	if (^rawptr)(uintptr(curbuf) + B_FFNAME)^ != nil {
		save_bin := (^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^
		perm := os_getperm((^cstring)(uintptr(curbuf) + B_FFNAME)^)
		if perm >= 0 && (C.int(perm) & 0o170000 == 0o10000 ||
			C.int(perm) & 0o170000 == 0o140000) {
			read_fifo = true
		}
		if read_fifo {
			(^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ = 1
		}
		retval = readfile_r((^cstring)(uintptr(curbuf) + B_FFNAME)^,
			(^cstring)(uintptr(curbuf) + B_FNAME)^, 0, 0, MAXLNUM, eap,
			flags | READ_NEW_O | (read_fifo ? READ_FIFO_O : 0), silent)
		if read_fifo {
			(^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ = save_bin
			if retval == OK {
				// don't add READ_FIFO here, otherwise we won't be able
				// to detect the encoding
				retval = read_buffer_o(false, eap, flags)
			}
		}
		// Help buffer: populate *local-additions* in help.txt
		if bt_help(curbuf) {
			get_local_additions_r()
		}
	} else if read_stdin {
		save_bin := (^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^
		// First read the text in binary mode into the buffer, then read
		// from that same buffer and append at the end (retry support).
		(^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ = 1
		retval = readfile_r(nil, nil, 0, 0, MAXLNUM, nil,
			flags | (READ_NEW_O + READ_STDIN_O), silent)
		(^C.int)(uintptr(curbuf) + B_P_BIN_OFF)^ = save_bin
		if retval == OK {
			retval = read_buffer_o(true, eap, flags)
		}
	}
	// Can now sync this buffer in ml_sync_all().
	mfp = (^rawptr)(uintptr(curbuf) + B_ML_MFP_OFF)^
	if mfp != nil && (^C.int)(uintptr(mfp) + MF_DIRTY_OFF)^ == MF_DIRTY_YES_NOSYNC_O {
		(^C.int)(uintptr(mfp) + MF_DIRTY_OFF)^ = MF_DIRTY_YES_O
	}
	// if first time loading this buffer, init b_chartab[]
	if ((^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ & BF_NEVERLOADED_O) != 0 {
		buf_init_chartab_r(curbuf, false)
		parse_cino_r(curbuf)
	}
	// Set/reset the Changed flag first, autocmds may change the buffer.
	// When reading stdin the buffer always needs writing (unless readonly).
	// When interrupted and 'cpoptions' contains 'i' set changed flag.
	if (got_int && vim_strchr_c(p_cpo, C.int(CPO_INTMOD_O)) != nil) ||
		(^bool)(uintptr(curbuf) + B_MODIFIED_WAS_SET_OFF)^ ||
		(aborting_r() && vim_strchr_c(p_cpo, C.int(CPO_INTMOD_O)) != nil) {
		changed_r(curbuf)
	} else if retval != FAIL && !read_stdin && !read_fifo {
		unchanged_r(curbuf, false, true)
	}
	save_file_ff_r(curbuf) // keep this fileformat
	// Set last_changedtick to avoid triggering a TextChanged autocommand
	// right after it was added.
	tick := (^C.longlong)(uintptr(curbuf) + B_CHANGEDTICK_DI_OFF + 8)^
	(^C.longlong)(uintptr(curbuf) + B_LAST_CHANGEDTICK_OFF)^ = tick
	(^C.longlong)(uintptr(curbuf) + B_LAST_CHANGEDTICK_I_OFF)^ = tick
	(^C.longlong)(uintptr(curbuf) + B_LAST_CHANGEDTICK_PUM_OFF)^ = tick
	// require "!" to overwrite the file, because it wasn't read completely
	if aborting_r() {
		(^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ |= BF_READERR_O
	}
	// Need to update automatic folding (before autocommands: they may use it).
	foldUpdateAll(curwin)
	// need to set w_topline, unless some autocommand already did that.
	if ((^C.int)(uintptr(curwin) + W_VALID_OFF)^ & VALID_TOPLINE_O) == 0 {
		(^C.int)(uintptr(curwin) + W_TOPLINE_OFF)^ = 1
		(^C.int)(uintptr(curwin) + W_TOPFILL_OFF)^ = 0
	}
	apply_autocmds_retval_r(EVENT_BUFENTER_O, nil, nil, false, curbuf, &retval)
	if retval == FAIL {
		return retval
	}
	// The autocommands may have changed the current buffer. Apply the
	// modelines to the correct buffer, if it still exists and is loaded.
	if bufref_valid(&old_curbuf) &&
		(^rawptr)(uintptr(old_curbuf.br_buf) + B_ML_MFP_OFF)^ != nil {
		aco: [56]u8
		// Go to the buffer that was opened, make sure it is in a window.
		aucmd_prepbuf_r(&aco[0], old_curbuf.br_buf)
		do_modelines(0)
		(^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^ &= ~(C.int(BF_CHECK_RO_O) | C.int(BF_NEVERLOADED_O))
		if (flags & READ_NOWINENTER_O) == 0 {
			apply_autocmds_retval_r(EVENT_BUFWINENTER_O, nil, nil, false, curbuf, &retval)
		}
		// restore curwin/curbuf and a few other things
		aucmd_restbuf_r(&aco[0])
	}
	return retval
}

// ── Batch 15: do_bufdel (:bdelete/:bwipeout/:bunload ex entry) ───────────────

E488_S :: "E488: Trailing characters: %s"
E515_S :: "E515: No buffers were unloaded"
E516_S :: "E516: No buffers were deleted"
E517_S :: "E517: No buffers were wiped out"
IOSIZE_O :: 1025

foreign _ {
	@(link_name = "skipwhite")
	skipwhite_r :: proc "c" (p: cstring) -> cstring ---
}

// Delete or unload buffers by number/range/pattern. Returns errmsg or NULL.
@(export)
do_bufdel :: proc "c"(command: C.int, arg_in: cstring, addr_count: C.int, start_bnr: C.int, end_bnr: C.int, forceit: C.int) -> cstring {
	arg := arg_in
	do_current: C.int = 0 // delete current buffer?
	deleted: C.int = 0 // number of buffers deleted
	errormsg: cstring = nil
	bnr: C.int // buffer number
	if addr_count == 0 {
		do_buffer(command, DOBUF_CURRENT_O, FORWARD_DIR, 0, forceit)
	} else {
		if addr_count == 2 {
			if b_at(transmute(^u8)(arg), 0) != 0 { // range + arg not allowed
				// ex_errmsg(e_trailing_arg, arg): format into IObuff
				// (C uses ex_error_buf static; IObuff equally transient).
				// libc.snprintf is #c_vararg (native) — cstring-safe.
				libc.snprintf(&IObuff[0], IOSIZE_O, cstring(E488_S), arg)
				return transmute(cstring)(&IObuff[0])
			}
			bnr = start_bnr
		} else { // addr_count == 1
			bnr = end_bnr
		}
		for !got_int {
			os_breakcheck()
			// delete the current buffer last, otherwise when the current
			// buffer is deleted the next one becomes current and may then
			// also be deleted, etc.
			if bnr == (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ {
				do_current = bnr
			} else if do_buffer(command, DOBUF_FIRST_O, FORWARD_DIR, bnr, forceit) == OK {
				deleted += 1
			}
			// find next buffer number to delete/unload
			if addr_count == 2 {
				bnr += 1
				if bnr > end_bnr {
					break
				}
			} else { // addr_count == 1
				arg = skipwhite_r(arg)
				if b_at(transmute(^u8)(arg), 0) == 0 {
					break
				}
				if !ascii_isdigit_o(b_at(transmute(^u8)(arg), 0)) {
					p := skiptowhite_esc_r(arg)
					bnr = buflist_findpat(arg, p, command == DOBUF_WIPE_O, false, false)
					if bnr < 0 { // failed
						break
					}
					arg = p
				} else {
					p := transmute(^u8)(arg)
					bnr = getdigits_int_r(&p, false, 0)
					arg = transmute(cstring)(p)
				}
			}
		}
		if !got_int && do_current != 0 &&
			do_buffer(command, DOBUF_FIRST_O, FORWARD_DIR, do_current, forceit) == OK {
			deleted += 1
		}
		if deleted == 0 {
			if command == DOBUF_UNLOAD_O {
				xstrlcpy_o(transmute(cstring)(&IObuff[0]), cstring(E515_S), IOSIZE_O)
			} else if command == DOBUF_DEL_O {
				xstrlcpy_o(transmute(cstring)(&IObuff[0]), cstring(E516_S), IOSIZE_O)
			} else {
				xstrlcpy_o(transmute(cstring)(&IObuff[0]), cstring(E517_S), IOSIZE_O)
			}
			errormsg = transmute(cstring)(&IObuff[0])
		} else if C.longlong(deleted) >= p_report {
			// NGETTEXT singular/plural (C-locale behavior).
			if command == DOBUF_UNLOAD_O {
				smsg(0, cstring(deleted == 1 ? "%d buffer unloaded" : "%d buffers unloaded"), deleted)
			} else if command == DOBUF_DEL_O {
				smsg(0, cstring(deleted == 1 ? "%d buffer deleted" : "%d buffers deleted"), deleted)
			} else {
				smsg(0, cstring(deleted == 1 ? "%d buffer wiped out" : "%d buffers wiped out"), deleted)
			}
		}
	}
	return errormsg
}

// ascii_isdigit is a C static inline: exact equivalent.
ascii_isdigit_o :: proc "c"(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// ── Batch 48: bt_* family + buf_hide ─────────────────────────────────────────

CMOD_HIDE_O :: 0x0020
E382_S :: "E382: Cannot write, 'buftype' option is set"

foreign _ {
	@(link_name = "p_hid")
	p_hid_g: C.int
	@(link_name = "cmdwin_buf")
	cmdwin_buf_g: rawptr
}

// Buftype predicates (all pure one-liners over b_p_bt/b_help/terminal).
@(export)
bt_help :: proc "c"(buf: rawptr) -> bool {
	return buf != nil && (^bool)(uintptr(buf) + B_HELP_OFF)^
}

@(export)
bt_normal :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return true
	}
	return b_at(bt, 0) == 0
}

@(export)
bt_quickfix :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	return b_at(bt, 0) == 'q'
}

@(export)
bt_terminal :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	return b_at(bt, 0) == 't'
}

@(export)
bt_nofilename :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	// NOTE: C also accepts "acwrite" ('a'); terminal covered explicitly.
	return (b_at(bt, 0) == 'n' && b_at(bt, 2) == 'f') ||
		b_at(bt, 0) == 'a' ||
		(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil ||
		b_at(bt, 0) == 'p'
}

@(export)
bt_nofile :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	return b_at(bt, 0) == 'n' && b_at(bt, 2) == 'f'
}

@(export)
bt_dontwrite :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	return b_at(bt, 0) == 'n' ||
		(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil ||
		b_at(bt, 0) == 'p'
}

@(export)
bt_dontwrite_msg :: proc "c"(buf: rawptr) -> bool {
	if bt_dontwrite(buf) {
		emsg(cstring(E382_S))
		return true
	}
	return false
}

@(export)
bt_prompt :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	bt := (^u8)((^rawptr)(uintptr(buf) + B_P_BT_OFF)^)
	if bt == nil {
		return false
	}
	return b_at(bt, 0) == 'p'
}

@(export)
bt_cmdwin :: proc "c"(buf: rawptr) -> bool {
	return buf != nil && buf == cmdwin_buf_g
}

// True when buffer "buf" should be hidden (per 'hidden'/":hide"/'bufhidden').
@(export)
buf_hide :: proc "c"(buf: rawptr) -> bool {
	if buf == nil {
		return false
	}
	// 'bufhidden' overrules 'hidden' and ":hide", check it first.
	bh := (^u8)((^rawptr)(uintptr(buf) + B_P_BH_OFF)^)
	c0: u8 = 0
	if bh != nil {
		c0 = b_at(bh, 0)
	}
	if c0 == 'u' || c0 == 'w' || c0 == 'd' {
		return false // "unload"/"wipe"/"delete"
	}
	if c0 == 'h' {
		return true // "hide"
	}
	return p_hid_g != 0 || (cmdmod_cmod_flags & CMOD_HIDE_O) != 0
}

// ── Batch 17: small leaves (buf_clear_file/clear, spname/get_fname,
// set_buflisted, contents_changed, wipe_buffer, is_empty, changedtick x2,
// read_buffer_into) ──────────────────────────────────────────────────────

B_ML_FLAGS_OFF :: 40 // b_ml@8 + ml_flags@32 (cc-probed)
B_NO_EOL_LNUM_OFF :: 11100
B_P_EOF_OFF :: 10376
B_START_EOF_OFF :: 11104
B_P_EOL_OFF :: 10380
B_START_EOL_OFF :: 11108
B_START_BOMB_OFF :: 11132
DICT_WATCHERS_OFF :: 336 // dict_T.watchers (QUEUE, cc-probed)
ML_EMPTY_O :: 0x01
READ_DUMMY_O :: 0x10
EXARG_SIZE_O :: 192 // sizeof(exarg_T), cc-probed

foreign _ {
	@(link_name = "deleted_lines_mark")
	deleted_lines_mark_r :: proc "c" (lnum: C.int, count: C.int) ---
	@(link_name = "prep_exarg")
	prep_exarg_r :: proc "c" (eap: rawptr, buf: rawptr) ---
	@(link_name = "qf_stack_get_bufnr")
	qf_stack_get_bufnr_r :: proc "c" () -> C.int ---
	@(link_name = "tv_dict_watcher_notify")
	tv_dict_watcher_notify_r :: proc "c" (dict: rawptr, key: cstring, newtv: ^Typval_T, oldtv: ^Typval_T) ---
	@(link_name = "msg_qflist")
	msg_qflist_g: ^u8
	@(link_name = "msg_loclist")
	msg_loclist_g: ^u8
}

// StringBuilder append helpers (proc "c" so exports can use them; shell.odin's
// kv_push/kv_concat_len are plain procs with fixed context — uncallable here).
sb_grow_o :: proc "c"(sb: ^StringBuilder, need: C.size_t) {
	newcap := sb.capacity
	if newcap == 0 {
		newcap = 16
	}
	for newcap < need {
		newcap *= 2
	}
	sb.items = (^u8)(xrealloc(sb.items, newcap))
	sb.capacity = newcap
}
sb_push_o :: proc "c"(sb: ^StringBuilder, ch: u8) {
	if sb.size + 1 > sb.capacity {
		sb_grow_o(sb, sb.size + 1)
	}
	([^]u8)(sb.items)[sb.size] = ch
	sb.size += 1
}
sb_concat_o :: proc "c"(sb: ^StringBuilder, s: ^u8, len: C.size_t) {
	if len == 0 {
		return
	}
	if sb.size + len > sb.capacity {
		sb_grow_o(sb, sb.size + len)
	}
	libc.memcpy(rawptr(uintptr(sb.items) + uintptr(sb.size)), s, len)
	sb.size += len
}
// tv_dict_is_watched is a C static inline (eval/typval.h:223):
// d && !QUEUE_EMPTY(&d->watchers); QUEUE is void*[2], NEXT at [0].
tv_dict_is_watched_o :: proc "c"(d: rawptr) -> bool {
	if d == nil {
		return false
	}
	w := uintptr(d) + DICT_WATCHERS_OFF
	return (^rawptr)(w)^ != rawptr(w)
}

// Reset buffer to a single empty line (used when re-reading a file).
@(export)
buf_clear_file :: proc "c"(buf: rawptr) {
	(^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ = 1
	unchanged_r(buf, true, true)
	(^C.int)(uintptr(buf) + B_P_EOF_OFF)^ = 0
	(^C.int)(uintptr(buf) + B_START_EOF_OFF)^ = 0
	(^C.int)(uintptr(buf) + B_P_EOL_OFF)^ = 1
	(^C.int)(uintptr(buf) + B_START_EOL_OFF)^ = 1
	(^C.int)(uintptr(buf) + B_P_BOMB_OFF)^ = 0
	(^C.int)(uintptr(buf) + B_START_BOMB_OFF)^ = 0
	(^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ = nil
	(^C.int)(uintptr(buf) + B_ML_FLAGS_OFF)^ = ML_EMPTY_O // empty buffer
}

// Clear the current buffer contents.
@(export)
buf_clear :: proc "c"() {
	line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	extmark_free_all_r(curbuf) // delete any extmarks
	for (^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O == 0 {
		ml_delete_r(1)
	}
	deleted_lines_mark_r(1, line_count) // prepare for display
}

// Special buffer name, or NULL for a normal file name.
@(export)
buf_spname :: proc "c"(buf: rawptr) -> ^u8 {
	if bt_quickfix(buf) {
		// Differentiate quickfix vs location list via the global qf stack.
		if (^C.int)(uintptr(buf) + B_FNUM_OFF)^ == qf_stack_get_bufnr_r() {
			return msg_qflist_g
		}
		return msg_loclist_g
	}
	// No _file_ for "nofile": b_sfname holds the user-given name.
	if bt_nofilename(buf) {
		if (^rawptr)(uintptr(buf) + B_FNAME)^ != nil {
			return (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
		}
		if bt_cmdwin(buf) {
			return transmute(^u8)(cstring("[Command Line]"))
		}
		if bt_prompt(buf) {
			return transmute(^u8)(cstring("[Prompt]"))
		}
		return transmute(^u8)(cstring("[Scratch]"))
	}
	if (^rawptr)(uintptr(buf) + B_FNAME)^ == nil {
		return buf_get_fname(buf)
	}
	return nil
}

// "buf->b_fname", or "[No Name]" when NULL.
@(export)
buf_get_fname :: proc "c"(buf: rawptr) -> ^u8 {
	if (^rawptr)(uintptr(buf) + B_FNAME)^ == nil {
		return transmute(^u8)(cstring("[No Name]"))
	}
	return (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
}

// Set 'buflisted' for curbuf, triggering autocommands on change.
@(export)
set_buflisted :: proc "c"(on: C.int) {
	if on == (^C.int)(uintptr(curbuf) + B_P_BL_OFF)^ {
		return
	}
	(^C.int)(uintptr(curbuf) + B_P_BL_OFF)^ = on
	if on != 0 {
		apply_autocmds(EVENT_BUFADD_O, nil, nil, false, curbuf)
	} else {
		apply_autocmds(EVENT_BUFDELETE_O, nil, nil, false, curbuf)
	}
}

// Re-read "buf" from disk into a dummy buffer and compare line by line.
// Returns true when the contents changed (or could not be checked).
@(export)
buf_contents_changed :: proc "c"(buf: rawptr) -> bool {
	differ := true
	// Allocate a buffer without putting it in the buffer list.
	newbuf := buflist_new(nil, nil, 1, BLN_DUMMY_O)
	if newbuf == nil {
		return true
	}
	// Force 'fileencoding' and 'fileformat' to be equal.
	ea: [EXARG_SIZE_O]u8
	prep_exarg_r(&ea[0], buf)
	// Set curwin/curbuf to buf and save a few things.
	aco: [56]u8
	aucmd_prepbuf_r(&aco[0], newbuf)
	// Don't trigger autocommands now (nasty side-effects like wiping).
	block_autocmds_r()
	if ml_open_r(curbuf) == OK &&
		readfile_r((^cstring)(uintptr(buf) + B_FFNAME)^,
			(^cstring)(uintptr(buf) + B_FNAME)^,
			0, 0, MAXLNUM, &ea[0], READ_NEW_O | READ_DUMMY_O, false) == OK {
		// Compare the two files line by line.
		if (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ ==
			(^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
			differ = false
			lnum: C.int = 1
			for lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ {
				if libc.strcmp(cstring(ml_get_buf(buf, lnum)),
					cstring(ml_get(lnum))) != 0 {
					differ = true
					break
				}
				lnum += 1
			}
		}
	}
	xfree((^rawptr)(uintptr(&ea[0]) + 40)^) // exarg_T.cmd@40
	// Restore curwin/curbuf and a few other things.
	aucmd_restbuf_r(&aco[0])
	if curbuf != newbuf { // safety check
		wipe_buffer(newbuf, false)
	}
	unblock_autocmds_r()
	return differ
}

// Wipe out a (typically temporary) buffer.
@(export)
wipe_buffer :: proc "c"(buf: rawptr, aucmd: bool) {
	if !aucmd {
		// Don't trigger BufDelete autocommands here.
		block_autocmds_r()
	}
	close_buffer(nil, buf, DOBUF_WIPE_O, false, true, false)
	if !aucmd {
		unblock_autocmds_r()
	}
}

// True when the buffer holds a single empty line.
@(export)
buf_is_empty :: proc "c"(buf: rawptr) -> bool {
	return (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ == 1 &&
		ml_get_buf(buf, 1)^ == 0
}

// Increment b:changedtick.
@(export)
buf_inc_changedtick :: proc "c"(buf: rawptr) {
	buf_set_changedtick(buf, buf_changedtick_inline(buf) + 1)
}

// Set b:changedtick (notifying dict watchers, like C).
@(export)
buf_set_changedtick :: proc "c"(buf: rawptr, changedtick: C.longlong) {
	old_val: Typval_T
	libc.memcpy(&old_val, rawptr(uintptr(buf) + B_CHANGEDTICK_DI_OFF),
		C.size_t(size_of(Typval_T)))
	(^C.longlong)(uintptr(buf) + B_CHANGEDTICK_DI_OFF + 8)^ = changedtick
	if tv_dict_is_watched_o((^rawptr)(uintptr(buf) + B_VARS_OFF)^) {
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
		tv_dict_watcher_notify_r((^rawptr)(uintptr(buf) + B_VARS_OFF)^,
			cstring(rawptr(uintptr(buf) + B_CHANGEDTICK_DI_OFF + 17)),
			transmute(^Typval_T)(uintptr(buf) + B_CHANGEDTICK_DI_OFF), &old_val)
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
	}
}

// Read buffer lines [start, end] into a StringBuilder (NL-joined).
@(export)
read_buffer_into :: proc "c"(buf: rawptr, start: C.int, end: C.int, sb: rawptr) {
	if buf == nil || sb == nil {
		return
	}
	if (^C.int)(uintptr(buf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O != 0 {
		return
	}
	SB := transmute(^StringBuilder)(sb)
	written: C.size_t = 0
	lnum := start
	lp := ml_get_buf(buf, lnum)
	lplen := C.size_t(ml_get_buf_len(buf, lnum))
	for {
		len: C.size_t = 0
		if lplen == 0 {
			len = 0
		} else if ([^]u8)(lp)[written] == NL {
			// NL -> NUL translation
			len = 1
			sb_push_o(SB, NUL)
		} else {
			s := vim_strchr((^u8)(uintptr(lp) + uintptr(written)), C.int(NL))
			if s == nil {
				len = lplen - written
			} else {
				len = C.size_t(uintptr(s) - (uintptr(lp) + uintptr(written)))
			}
			sb_concat_o(SB, (^u8)(uintptr(lp) + uintptr(written)), len)
		}
		if len == lplen - written {
			// Finished a line: add NL unless this line should not have one.
			// (Odin && / || need explicit grouping — NOT C precedence.)
			no_eol := lnum != end
			bin_fix := (^C.int)(uintptr(buf) + B_P_BIN_OFF)^ == 0 &&
				(^C.int)(uintptr(buf) + B_P_FIXEOL_OFF)^ != 0
			last_line := lnum != (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ ||
				(^C.int)(uintptr(buf) + B_P_EOL_OFF)^ != 0
			if no_eol || bin_fix ||
				(lnum != (^C.int)(uintptr(buf) + B_NO_EOL_LNUM_OFF)^ && last_line) {
				sb_push_o(SB, NL)
			}
			lnum += 1
			if lnum > end {
				break
			}
			lp = ml_get_buf(buf, lnum)
			lplen = C.size_t(ml_get_buf_len(buf, lnum))
			written = 0
		} else if len > 0 {
			written += len
		}
	}
}

// ── Batch 18: close_buffer (unload/delete/wipe engine) ──────────────────────

EVENT_BUFWINLEAVE_O :: 16
EVENT_BUFHIDDEN_O :: 6
E855_S :: "E855: Autocommands caused command to abort"

foreign _ {
	@(link_name = "diffopt_hiddenoff")
	diffopt_hiddenoff_r :: proc "c" () -> bool ---
}

// Close/unload/delete/wipe buffer "buf" shown in window "win".
// Returns true when we got to the end and unloaded "buf".
@(export)
close_buffer :: proc "c"(win: rawptr, buf: rawptr, action: C.int, abort_if_last: bool, ignore_abort: bool, set_context: bool) -> bool {
	unload_buf := action != 0
	del_buf := action == DOBUF_DEL_O || action == DOBUF_WIPE_O
	wipe_buf := action == DOBUF_WIPE_O

	is_curwin := curwin != nil && curwin == win &&
		(^rawptr)(uintptr(curwin) + W_BUFFER_OFF)^ == buf
	the_curtab := curtab

	// CHECK_CURBUF is a no-op (no ABORT_ON_INTERNAL_ERROR in this build).

	// Force unloading/deleting when 'bufhidden' says so, but not for
	// terminal buffers ('bufhidden'=="hide" must NOT free — the caller
	// takes care of that, otherwise we could never free a buffer).
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ == nil {
		bh := (^u8)((^rawptr)(uintptr(buf) + B_P_BH_OFF)^)
		c0: u8 = 0
		if bh != nil {
			c0 = b_at(bh, 0)
		}
		if c0 == 'd' { // 'bufhidden' == "delete"
			del_buf = true
			unload_buf = true
		} else if c0 == 'w' { // 'bufhidden' == "wipe"
			del_buf = true
			unload_buf = true
			wipe_buf = true
		} else if c0 == 'u' { // 'bufhidden' == "unload"
			unload_buf = true
		}
	}
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil &&
		(unload_buf || del_buf || wipe_buf) {
		// Terminal buffers can only be wiped.
		unload_buf = true
		del_buf = true
		wipe_buf = true
	}

	// Disallow deleting a locked buffer (already closing). Unloading is OK.
	if (del_buf || wipe_buf) && !can_unload_buffer_o(buf) {
		return false
	}

	win_valid := win_valid_any_tab(win)
	if set_context && win_valid && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf {
		// Remember last cursor + window options when closing the last
		// window for the buffer (used to be curwin-only; ":only" would
		// otherwise lose options like 'foldmethod').
		if (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 1 {
			set_last_cursor(win)
		}
		lnum := (^C.int)(uintptr(win) + W_CURSOR_OFF)^
		buflist_setfpos(buf, win, lnum == 1 ? 0 : lnum,
			(^C.int)(uintptr(win) + W_CURSOR_OFF + 4)^, true)
	}

	bufref: Bufref_T
	set_bufref(&bufref, buf)

	// When the buffer is no longer in a window, trigger BufWinLeave.
	if win_valid && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf &&
		(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 1 {
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
		(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ += 1
		if apply_autocmds(EVENT_BUFWINLEAVE_O,
			(^cstring)(uintptr(buf) + B_FNAME)^,
			(^cstring)(uintptr(buf) + B_FNAME)^, false, buf) &&
			!bufref_valid(&bufref) {
			// Autocommands deleted the buffer.
			emsg(cstring(E855_S))
			return false
		}
		(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
		(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ -= 1
		if abort_if_last && one_window(win, nil) {
			// Autocommands made this the only window.
			emsg(cstring(E855_S))
			return false
		}

		// Hidden but not unloaded: trigger BufHidden.
		if !unload_buf {
			(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
			(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ += 1
			if apply_autocmds(EVENT_BUFHIDDEN_O,
				(^cstring)(uintptr(buf) + B_FNAME)^,
				(^cstring)(uintptr(buf) + B_FNAME)^, false, buf) &&
				!bufref_valid(&bufref) {
				// Autocommands deleted the buffer.
				emsg(cstring(E855_S))
				return false
			}
			(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
			(^C.int)(uintptr(buf) + B_LOCKED_SPLIT_OFF)^ -= 1
			if abort_if_last && one_window(win, nil) {
				// Autocommands made this the only window.
				emsg(cstring(E855_S))
				return false
			}
		}
		// Autocmds may abort script processing.
		if !ignore_abort && aborting_r() {
			return false
		}
		win_valid = win_valid && win_valid_any_tab(win)
	}

	// If the buffer was in curwin and the window changed, go back to that
	// window if it still exists (avoids ":edit x" + "tabnext" BufUnload
	// autocmd leaving a window behind without a buffer).
	if is_curwin && curwin != win && win_valid {
		block_autocmds_r()
		goto_tabpage_win(the_curtab, win)
		unblock_autocmds_r()
	}

	// A deleted quickfix window loses its 'winfixheight'.
	if bt_quickfix(buf) && win_valid &&
		(^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf {
		(^C.int)(uintptr(win) + W_P_WFH_OFF)^ = 0
	}

	// Remember if the buffer may be hidden soon, or is already hidden.
	hiding_buf := (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 0 ||
		(win_valid && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf &&
			(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 1)

	if diffopt_hiddenoff_r() && !unload_buf && hiding_buf {
		diff_buf_delete_r(buf) // clear 'diff' for hidden buffer
	}

	// Another window shows the buffer, or not unloading: done.
	if !hiding_buf || !unload_buf {
		return false
	}

	// Always remove the buffer when there is no file name.
	if (^rawptr)(uintptr(buf) + B_FFNAME)^ == nil {
		del_buf = true
	}

	// Free everything file-related (fires BufDelete autocmds when del_buf).
	// Abort when nothing was freed or autocmds deleted the buffer.
	bfa: C.int = (del_buf ? BFA_DEL_O : 0) + (wipe_buf ? BFA_WIPE_O : 0) +
		(ignore_abort ? BFA_IGNORE_ABORT_O : 0)
	if !buf_freeall(buf, bfa) {
		return false
	}

	clear_w_buf := false
	win_valid = win_valid && win_valid_any_tab(win)
	if win_valid && (^rawptr)(uintptr(win) + W_BUFFER_OFF)^ == buf {
		// Autocmds may have opened/closed windows for this buffer despite
		// b_locked_split. Decrement for the close we do here; defer
		// clearing w_buffer until after dict-watcher operations (.
		// buf_clear_file()) so tabpagebuflist() never sees a window
		// with a NULL buffer.
		(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ -= 1
		clear_w_buf = true
	}

	// Remove the buffer from the list. Don't wipe while it is used in a
	// window (unless free_all_mem, which has no EXITFREE in this build —
	// the entered_free_all_mem clause is dropped to match compiled C).
	if wipe_buf && (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ <= 0 &&
		((^rawptr)(uintptr(buf) + B_PREV_OFF)^ != nil ||
			(^rawptr)(uintptr(buf) + B_NEXT_OFF)^ != nil) {
		if clear_w_buf {
			(^rawptr)(uintptr(win) + W_BUFFER_OFF)^ = nil
		}
		tp := first_tabpage
		for tp != nil {
			wp := tp == curtab ? firstwin :
				(^rawptr)(uintptr(tp) + TP_FIRSTWIN_OFF)^
			for wp != nil {
				mark_forget_file(wp, (^C.int)(uintptr(buf) + B_FNUM_OFF)^)
				wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
			}
			tp = (^rawptr)(uintptr(tp) + TP_NEXT_OFF)^
		}
		if (^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ !=
			(^rawptr)(uintptr(buf) + B_FFNAME)^ {
			xfree((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
			(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = nil
		} else {
			(^rawptr)(uintptr(buf) + B_SFNAME_OFF)^ = nil
		}
		xfree((^rawptr)(uintptr(buf) + B_FFNAME)^)
		(^rawptr)(uintptr(buf) + B_FFNAME)^ = nil
		if (^rawptr)(uintptr(buf) + B_PREV_OFF)^ == nil {
			firstbuf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		} else {
			(^rawptr)(uintptr((^rawptr)(uintptr(buf) + B_PREV_OFF)^) + B_NEXT_OFF)^ =
				(^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
		if (^rawptr)(uintptr(buf) + B_NEXT_OFF)^ == nil {
			lastbuf_g = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
		} else {
			(^rawptr)(uintptr((^rawptr)(uintptr(buf) + B_NEXT_OFF)^) + B_PREV_OFF)^ =
				(^rawptr)(uintptr(buf) + B_PREV_OFF)^
		}
		free_buffer_o(buf)
	} else {
		if del_buf {
			// Free internals + reset options (":bdel" ~= Vim 5.7).
			free_buffer_stuff_o(buf, KBFF_CLEAR_WININFO_O | KBFF_INIT_CHANGEDTICK_O)
			// Make it look like a new buffer.
			(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ = BF_CHECK_RO_O | BF_NEVERLOADED_O
			// Init the options when loaded again.
			(^bool)(uintptr(buf) + B_P_INITIALIZED_OFF)^ = false
		}
		// Dict watchers set b_locked; keep them away from windows here.
		textlock += 1
		buf_clear_file(buf)
		textlock -= 1
		if clear_w_buf {
			(^rawptr)(uintptr(win) + W_BUFFER_OFF)^ = nil
		}
		if del_buf {
			(^C.int)(uintptr(buf) + B_P_BL_OFF)^ = 0
		}
	}
	// NOTE: at this point "curbuf" may be invalid!
	return true
}

// ── Batch 19: buffer-pattern cluster (buflist_findpat + buflist_match/
// fname_match statics, ExpandBufnames + buf_time_compare) ─────────────────

BUF_DIFF_FILTER_O :: 0x2000
WILD_HOME_REPLACE_O :: 0x02
WILD_BUFLASTUSED_O :: 0x1000
FUZZY_SCORE_NONE_O :: C.int(-2147483648) // INT_MIN
E93_S :: "E93: More than one match for %s"
E94_S :: "E94: No matching buffer for %s"

foreign _ {
	@(link_name = "file_pat_to_reg_pat")
	file_pat_to_reg_pat_r :: proc "c"(pat: cstring, pat_end: cstring, allow_dirs: cstring, no_bslash: bool) -> ^u8 ---
	@(link_name = "diff_mode_buf")
	diff_mode_buf_r :: proc "c"(buf: rawptr) -> bool ---
	@(link_name = "p_fic")
	p_fic_g: C.int
	@(link_name = "p_wic")
	p_wic_g: C.int
	@(link_name = "qsort")
	qsort_r :: proc "c"(base: rawptr, nmemb: C.size_t, size: C.size_t, compar: proc "c"(s1: rawptr, s2: rawptr) -> C.int) ---
}

// qsort comparator on b_last_used (C static in buffer.c).
buf_time_compare_o :: proc "c"(s1: rawptr, s2: rawptr) -> C.int {
	buf1 := (^rawptr)(s1)^
	buf2 := (^rawptr)(s2)^
	t1 := (^C.longlong)(uintptr(buf1) + B_LAST_USED_OFF)^
	t2 := (^C.longlong)(uintptr(buf2) + B_LAST_USED_OFF)^
	if t1 == t2 {
		return 0
	}
	return t1 > t2 ? -1 : 1
}

// Match regprog against short name, then full name (C static).
buflist_match_o :: proc "c"(rmp: ^Regmatch_T, buf: rawptr, ignore_case: bool) -> ^u8 {
	// First try the short file name, then the long file name.
	match := fname_match_o(rmp, (^u8)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^),
		ignore_case)
	if match == nil && rmp.regprog != nil {
		match = fname_match_o(rmp, (^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^),
			ignore_case)
	}
	return match
}

// Match regprog against one file name; ~/ expansion retry (C static).
fname_match_o :: proc "c"(rmp: ^Regmatch_T, name: ^u8, ignore_case: bool) -> ^u8 {
	// Extra check for valid arguments.
	if name == nil || rmp.regprog == nil {
		return nil
	}
	// Ignore case when 'fileignorecase' or the argument is set.
	rmp.rm_ic = (p_fic_g != 0 || ignore_case) ? 1 : 0
	if vim_regexec_r(rmp, name, 0) != 0 {
		return name
	}
	if rmp.regprog != nil {
		// Replace $(HOME) with '~' and try matching again.
		p := home_replace_save(nil, cstring(name))
		hit := vim_regexec_r(rmp, transmute(^u8)(p), 0) != 0
		xfree(transmute(rawptr)(p))
		if hit {
			return name
		}
	}
	return nil
}

// Find buffer matching "pattern" (%=current, #=alternate, else 4 anchoring
// attempts over listed then unlisted buffers). Returns fnum, -2 if ambiguous.
@(export)
buflist_findpat :: proc "c"(pattern: cstring, pattern_end: cstring, unlisted: bool, diffmode: bool, curtab_only: bool) -> C.int {
	match: C.int = -1

	pat0 := (^u8)(pattern)
	if uintptr(transmute(rawptr)(pattern_end)) == uintptr(transmute(rawptr)(pat0)) + 1 &&
		(([^]u8)(pat0)[0] == '%' || ([^]u8)(pat0)[0] == '#') {
		match = ([^]u8)(pat0)[0] == '%' ? (^C.int)(uintptr(curbuf) + B_FNUM_OFF)^ :
			(^C.int)(uintptr(curwin) + W_ALT_FNUM)^
		found_buf := buflist_findnr(match)
		if diffmode && (found_buf == nil || !diff_mode_buf_r(found_buf)) {
			match = -1
		}
	} else {
		// Four anchoring attempts: 0=none, 1='^', 2='$', 3=both; listed
		// first, then unlisted if requested and nothing matched.
		pat := file_pat_to_reg_pat_r(pattern, pattern_end, nil, false)
		if pat == nil {
			return -1
		}
		patlen := libc.strlen(cstring(pat))
		toggledollar := patlen >= 2 && ([^]u8)(pat)[patlen - 1] == '$'

		find_listed := true
		for {
			for attempt: C.int = 0; attempt <= 3; attempt += 1 {
				// May add '^' and '$'.
				if toggledollar {
					([^]u8)(pat)[patlen - 1] = attempt < 2 ? 0 : '$'
				}
				p := pat
				if ([^]u8)(p)[0] == '^' && (attempt & 1) == 0 { // add/remove '^'
					p = (^u8)(uintptr(p) + 1)
				}

				regmatch: Regmatch_T
				regmatch.regprog = vim_regcomp(cstring(p),
					magic_isset() ? RE_MAGIC : 0)

				buf := lastbuf_g
				for buf != nil {
					if regmatch.regprog == nil {
						// Invalid pattern, possibly after switching engine.
						xfree(transmute(rawptr)(pat))
						return -1
					}
					if (^C.int)(uintptr(buf) + B_P_BL_OFF)^ ==
						(find_listed ? 1 : 0) &&
						(!diffmode || diff_mode_buf_r(buf)) &&
						buflist_match_o(&regmatch, buf, false) != nil {
						if curtab_only {
							// Ignore matches not open in the current tab
							// (tp == curtab here, so walk firstwin).
							found_window := false
							wp := firstwin
							for wp != nil {
								if (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == buf {
									found_window = true
									break
								}
								wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
							}
							if !found_window {
								buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
								continue
							}
						}
						if match >= 0 { // already found a match
							match = -2
							break
						}
						match = (^C.int)(uintptr(buf) + B_FNUM_OFF)^
					}
					buf = (^rawptr)(uintptr(buf) + B_PREV_OFF)^
				}

				vim_regfree(regmatch.regprog)
				if match >= 0 { // found one match
					break
				}
			}

			// Only search unlisted buffers if no listed buffer matched.
			if !unlisted || !find_listed || match != -1 {
				break
			}
			find_listed = false
		}

		xfree(transmute(rawptr)(pat))
	}

	if match == -2 {
		semsg_safe(cstring(E93_S), transmute(rawptr)(pattern))
	} else if match < 0 {
		semsg_safe(cstring(E94_S), transmute(rawptr)(pattern))
	}
	return match
}

// Find all listed buffer names matching "pat" (":buf"/":sbuf" expansion).
// Returns OK when matches are found, FAIL otherwise.
@(export)
ExpandBufnames :: proc "c"(pat: ^u8, num_file: ^C.int, file: ^^^u8, options: C.int) -> C.int {
	matches: rawptr = nil
	to_free := false

	num_file^ = 0 // return values in case of FAIL
	file^ = nil

	if (options & BUF_DIFF_FILTER_O) != 0 &&
		(^C.int)(uintptr(curwin) + W_P_DIFF_OFF)^ == 0 {
		return FAIL
	}

	fuzzy := cmdline_fuzzy_complete_c(pat)

	patc: ^u8 = nil
	fuzmatch: rawptr = nil
	regmatch: Regmatch_T

	// Copy "pat", turning a leading "^" into "\(^\|[\/]\)" for regex matching.
	if !fuzzy {
		if ([^]u8)(pat)[0] == '^' && ([^]u8)(pat)[1] != 0 {
			patc = xstrdup_o((^u8)(uintptr(pat) + 1))
			to_free = true
		} else if ([^]u8)(pat)[0] == '^' {
			patc = transmute(^u8)(cstring(""))
		} else {
			patc = pat
		}
		regmatch.regprog = vim_regcomp(cstring(patc), RE_MAGIC)
	}

	count: C.int = 0
	score: C.int = 0
	// round 1: count the matches. round 2: build the match array.
	for round: C.int = 1; round <= 2; round += 1 {
		count = 0
		buf := firstbuf
		for buf != nil {
			if (^C.int)(uintptr(buf) + B_P_BL_OFF)^ == 0 { // skip unlisted
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				continue
			}
			if (options & BUF_DIFF_FILTER_O) != 0 {
				// Skip buffers not suitable for :diffget/:diffput.
				if buf == curbuf || !diff_mode_buf_r(buf) {
					buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
					continue
				}
			}

			p: ^u8 = nil
			if !fuzzy {
				if regmatch.regprog == nil {
					// Invalid pattern, possibly after recompiling.
					if to_free {
						xfree(transmute(rawptr)(patc))
					}
					return FAIL
				}
				p = buflist_match_o(&regmatch, buf, p_wic_g != 0)
			} else {
				p = nil
				// First try the short file name.
				score = fuzzy_match_str_c(
					(^u8)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^), pat)
				if score != FUZZY_SCORE_NONE_O {
					p = (^u8)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
				}
				if p == nil {
					// Then the full path file name.
					score = fuzzy_match_str_c(
						(^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^), pat)
					if score != FUZZY_SCORE_NONE_O {
						p = (^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^)
					}
				}
			}

			if p == nil {
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				continue
			}

			if round == 1 {
				count += 1
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				continue
			}

			if (options & WILD_HOME_REPLACE_O) != 0 {
				p = (^u8)(home_replace_save(buf, cstring(p)))
			} else {
				p = xstrdup_o(p)
			}

			if !fuzzy {
				if matches != nil {
					// bufmatch_T is 16 bytes: buf@0, match@8.
					(^rawptr)(uintptr(matches) + uintptr(count * 16))^ = buf
					(^rawptr)(uintptr(matches) + uintptr(count * 16) + 8)^ =
						rawptr(p)
					count += 1
				} else {
					([^]^u8)(file^)[count] = p
					count += 1
				}
			} else {
				// fuzmatch_str_T is 24 bytes: idx@0, str@8, score@16.
				(^C.int)(uintptr(fuzmatch) + uintptr(count * 24))^ = count
				(^rawptr)(uintptr(fuzmatch) + uintptr(count * 24) + 8)^ =
					rawptr(p)
				(^C.int)(uintptr(fuzmatch) + uintptr(count * 24) + 16)^ = score
				count += 1
			}
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
		if count == 0 { // no match found, break here
			break
		}
		if round == 1 {
			if !fuzzy {
				file^ = ([^]^u8)(xmalloc(C.size_t(count) * 8))
				if (options & WILD_BUFLASTUSED_O) != 0 {
					matches = xmalloc(C.size_t(count) * 16)
				}
			} else {
				fuzmatch = xmalloc(C.size_t(count) * 24)
			}
		}
	}

	if !fuzzy {
		vim_regfree(regmatch.regprog)
		if to_free {
			xfree(transmute(rawptr)(patc))
		}
	}

	if !fuzzy {
		if matches != nil {
			if count > 1 {
				qsort_r(matches, C.size_t(count), 16, buf_time_compare_o)
			}

			// If the current buffer is first, place it at the end.
			if (^rawptr)(uintptr(matches))^ == curbuf {
				for i: C.int = 1; i < count; i += 1 {
					([^]^u8)(file^)[i - 1] =
						(^u8)((^rawptr)(uintptr(matches) + uintptr(i * 16) + 8)^)
				}
				([^]^u8)(file^)[count - 1] =
					(^u8)((^rawptr)(uintptr(matches) + 8)^)
			} else {
				for i: C.int = 0; i < count; i += 1 {
					([^]^u8)(file^)[i] =
						(^u8)((^rawptr)(uintptr(matches) + uintptr(i * 16) + 8)^)
				}
			}
			xfree(matches)
		}
	} else {
		fuzzymatches_to_strmatches_c(fuzmatch, transmute(rawptr)(file), count,
			false)
	}

	num_file^ = count
	return count == 0 ? FAIL : OK
}

// ── Batch 20: :ls/:file display (buflist_list, fileinfo, col_print,
// append_arg_number) ─────────────────────────────────────────────────────

BF_NOTEDITED_O :: 0x08
BF_NEW_O :: 0x10
BF_WRITE_MASK_O :: 0x58 // NOTEDITED+NEW+READERR
SHM_MOD_O :: C.int('m')
SHM_RO_O :: C.int('r')
W_ARG_IDX_INVALID_OFF :: 796
K_UIMESSAGES_O :: C.int(4) // ui_defs.h; NOTE: shell.odin's kUIMessages=1 is
// WRONG (that's kUIPopupmenu) — pre-existing, out of scope; use this here.
NO_LINES_MSG_S :: "--No lines in buffer--"

foreign _ {
	@(link_name = "need_wait_return")
	need_wait_return_g: bool
}

// List all known file names (":files"/":buffers" command).
@(export)
buflist_list :: proc "c"(eap: rawptr) {
	buf := firstbuf
	buflist: Garray
	buflist_data: rawptr = nil

	msg_ext_set_kind(cstring("list_cmd"))
	arg := (^cstring)(uintptr(eap))^
	if vim_strchr(transmute(^u8)(arg), 't') != nil {
		ga_init_o(&buflist, 8, 50)
		b := firstbuf
		for b != nil {
			ga_grow_o(&buflist, 1)
			([^]rawptr)(buflist.ga_data)[buflist.ga_len] = b
			buflist.ga_len += 1
			b = (^rawptr)(uintptr(b) + B_NEXT_OFF)^
		}

		qsort_r(buflist.ga_data, C.size_t(buflist.ga_len), 8,
			buf_time_compare_o)

		buflist_data = buflist.ga_data
		buf = ([^]rawptr)(buflist_data)[0]
	}
	p_idx: C.int = 0

	for buf != nil && !got_int {
		is_terminal := (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil
		job_running := is_terminal &&
			terminal_running_r((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^)

		// Skip unspecified buffers (each clause mirrors C exactly).
		b_bl := (^C.int)(uintptr(buf) + B_P_BL_OFF)^
		b_flags := (^C.int)(uintptr(buf) + B_FLAGS_OFF)^
		skip := (b_bl == 0 && (^C.int)(uintptr(eap) + 76)^ == 0 &&
				vim_strchr(transmute(^u8)(arg), 'u') == nil) ||
			(vim_strchr(transmute(^u8)(arg), 'u') != nil && b_bl != 0)
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), '+') != nil &&
				((b_flags & BF_READERR_O) != 0 || !bufIsChanged(buf)))
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), 'a') != nil &&
				((^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil ||
					(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0))
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), 'h') != nil &&
				((^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil ||
					(^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ != 0))
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), 'R') != nil &&
				(!is_terminal || !job_running))
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), 'F') != nil &&
				(!is_terminal || job_running))
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), '-') != nil &&
				(^C.int)(uintptr(buf) + B_P_MA_OFF)^ != 0)
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), '=') != nil &&
				(^C.int)(uintptr(buf) + B_P_RO_OFF)^ == 0)
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), 'x') != nil &&
				(b_flags & BF_READERR_O) == 0)
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), '%') != nil && buf != curbuf)
		skip = skip ||
			(vim_strchr(transmute(^u8)(arg), '#') != nil &&
				(buf == curbuf ||
					(^C.int)(uintptr(curwin) + W_ALT_FNUM)^ !=
					(^C.int)(uintptr(buf) + B_FNUM_OFF)^))
		if !skip {
			name := buf_spname(buf)
			if name != nil {
				xstrlcpy_o(cstring(&name_buff[0]), cstring(name), MAXPATHL)
			} else {
				home_replace(buf,
					cstring((^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)),
					cstring(&name_buff[0]), MAXPATHL, true)
			}

			if !message_filtered(cstring(&name_buff[0])) {
				changed_char := C.int(' ')
				if (b_flags & BF_READERR_O) != 0 {
					changed_char = C.int('x')
				} else if bufIsChanged(buf) {
					changed_char = C.int('+')
				}
				ro_char := C.int(' ')
				if (^C.int)(uintptr(buf) + B_P_MA_OFF)^ == 0 {
					ro_char = C.int('-')
				} else if (^C.int)(uintptr(buf) + B_P_RO_OFF)^ != 0 {
					ro_char = C.int('=')
				}
				if is_terminal {
					ro_char = C.int(terminal_running_r(
						(^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^) ? 'R' : 'F')
				}

				if !ui_has(K_UIMESSAGES_O) || msg_col > 0 {
					msg_putchar('\n')
				}
				alt_char := C.int(' ')
				if buf == curbuf {
					alt_char = C.int('%')
				} else if (^C.int)(uintptr(curwin) + W_ALT_FNUM)^ ==
					(^C.int)(uintptr(buf) + B_FNUM_OFF)^ {
					alt_char = C.int('#')
				}
				mfp_char := C.int(' ')
				if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ != nil {
					if (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ == 0 {
						mfp_char = C.int('h')
					} else {
						mfp_char = C.int('a')
					}
				}
				len := libc.snprintf(&IObuff[0], C.size_t(IOSIZE_O - 20),
					cstring("%3d%c%c%c%c%c \"%s\""),
					(^C.int)(uintptr(buf) + B_FNUM_OFF)^,
					b_bl != 0 ? C.int(' ') : C.int('u'),
					alt_char, mfp_char,
					ro_char, changed_char, cstring(&name_buff[0]))

				if len > IOSIZE_O - 20 {
					len = IOSIZE_O - 20
				}

				// Put "line 999" in column 40 or after the file name.
				i := 40 - vim_strsize_r(cstring(&IObuff[0]))
				for {
					([^]u8)(&IObuff[0])[len] = ' '
					len += 1
					i -= 1
					if !(i > 0 && len < IOSIZE_O - 18) {
						break
					}
				}
				if vim_strchr(transmute(^u8)(arg), 't') != nil &&
					(^C.longlong)(uintptr(buf) + B_LAST_USED_OFF)^ != 0 {
					undo_fmt_time(
						([^]u8)((^u8)(uintptr(&IObuff[0]) + uintptr(len))),
						C.size_t(C.int(IOSIZE_O) - len),
						C.long((^C.longlong)(uintptr(buf) + B_LAST_USED_OFF)^))
				} else {
					ln := C.longlong(buflist_findlnum(buf))
					if buf == curbuf {
						ln = C.longlong((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
					}
					len += libc.snprintf(
						(^u8)(uintptr(&IObuff[0]) + uintptr(len)),
						C.size_t(C.int(IOSIZE_O) - len), cstring("line %ld"),
						ln)
				}

				msg_outtrans(cstring(&IObuff[0]), 0, false)
				line_breakcheck()
			}
		}
		// Advance (== C for-increment).
		if buflist_data != nil {
			p_idx += 1
			if p_idx < buflist.ga_len {
				buf = ([^]rawptr)(buflist_data)[p_idx]
			} else {
				buf = nil
			}
		} else {
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
		}
	}

	if buflist_data != nil {
		ga_clear_r(&buflist)
	}
}

// Show file info for the current buffer (":file"/CTRL-G).
@(export)
fileinfo :: proc "c"(fullname: C.int, shorthelp: C.int, dont_truncate: bool) {
	buffer := (^u8)(xmalloc(C.size_t(IOSIZE_O)))
	bufferlen: C.size_t = 0
	bptr := (^u8)(uintptr(buffer) + uintptr(bufferlen))
	vrem := C.size_t(C.int(IOSIZE_O)) - bufferlen

	if fullname > 1 { // 2 CTRL-G: include buffer number
		bufferlen += C.size_t(libc.snprintf(bptr, vrem, cstring("buf %d: "),
			(^C.int)(uintptr(curbuf) + B_FNUM_OFF)^))
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
	}

	([^]u8)(buffer)[bufferlen] = '"'
	bufferlen += 1

	name := buf_spname(curbuf)
	if name != nil {
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		bufferlen += C.size_t(libc.snprintf(bptr, vrem, cstring("%s"),
			cstring(name)))
	} else {
		fname := (^u8)((^rawptr)(uintptr(curbuf) + B_FNAME)^)
		ffname := (^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^)
		src := (fullname == 0 && fname != nil) ? fname : ffname
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		bufferlen += home_replace(shorthelp != 0 ? curbuf : nil, cstring(src),
			cstring(bptr), vrem, true)
	}

	dontwrite := bt_dontwrite(curbuf)
	mod_str := cstring(" ")
	if curbufIsChanged() {
		mod_str = shortmess(SHM_MOD_O) ? cstring(" [+]") :
			cstring(" [Modified]")
	}
	bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
	vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
	bflags := (^C.int)(uintptr(curbuf) + B_FLAGS_OFF)^
	notedited_str := cstring("")
	if (bflags & BF_NOTEDITED_O) != 0 && !dontwrite {
		notedited_str = cstring("[Not edited]")
	}
	new_str := cstring("")
	if (bflags & BF_NEW_O) != 0 && !dontwrite {
		new_str = cstring("[New]")
	}
	readerr_str := cstring("")
	if (bflags & BF_READERR_O) != 0 {
		readerr_str = cstring("[Read errors]")
	}
	ro_str := cstring("")
	if (^C.int)(uintptr(curbuf) + B_P_RO_OFF)^ != 0 {
		ro_str = shortmess(SHM_RO_O) ? cstring("[RO]") : cstring("[readonly]")
	}
	trail_str := cstring("")
	if curbufIsChanged() || (bflags & BF_WRITE_MASK_O) != 0 ||
		(^C.int)(uintptr(curbuf) + B_P_RO_OFF)^ != 0 {
		trail_str = cstring(" ")
	}
	bufferlen += C.size_t(libc.snprintf(bptr, vrem,
		cstring("\"%s%s%s%s%s%s"), mod_str, notedited_str, new_str,
		readerr_str, ro_str, trail_str))

	if (^C.int)(uintptr(curbuf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O != 0 {
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		bufferlen += C.size_t(libc.snprintf(bptr, vrem, cstring("%s"),
			cstring(NO_LINES_MSG_S)))
	} else if p_ru_g != 0 {
		// Current line/column already on screen.
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		ml_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		line_fmt := cstring("%ld lines --%d%%--")
		if ml_count == 1 {
			line_fmt = cstring("%ld line --%d%%--")
		}
		bufferlen += C.size_t(libc.snprintf(bptr, vrem, line_fmt,
			C.longlong(ml_count),
			calc_percentage(i64((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^),
				i64(ml_count))))
	} else {
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		ml_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
		bufferlen += C.size_t(libc.snprintf(bptr, vrem,
			cstring("line %ld of %ld --%d%%-- col "),
			C.longlong((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^),
			C.longlong(ml_count),
			calc_percentage(i64((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^),
				i64(ml_count))))
		validate_virtcol_r(curwin)
		bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
		vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
		bufferlen += C.size_t(col_print(bptr, vrem,
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ + 1,
			(^C.int)(uintptr(curwin) + W_VIRTCOL_OFF)^ + 1))
	}

	bptr = (^u8)(uintptr(buffer) + uintptr(bufferlen))
	vrem = C.size_t(C.int(IOSIZE_O)) - bufferlen
	append_arg_number(curwin, bptr, vrem)

	if dont_truncate {
		// Temporarily set msg_scroll to avoid truncation.
		msg_start()
		n := msg_scroll
		msg_scroll = true
		msg_msg(cstring(buffer), 0)
		msg_scroll = n
	} else {
		p := msg_trunc_r(buffer, false, 0)
		if restart_edit != 0 || (msg_scrolled != 0 && !need_wait_return_g) {
			// Repeat the message after redraw when restart_edit is set
			// or the screen scrolled without a wait-return prompt.
			set_keep_msg_r(cstring(p), 0)
		}
	}

	xfree(buffer)
}

// Format "col" (or "col-vcol") into "buf".
@(export)
col_print :: proc "c"(buf: ^u8, buflen: C.size_t, col: C.int, vcol: C.int) -> C.int {
	if col == vcol {
		return libc.snprintf(buf, buflen, cstring("%d"), col)
	}
	return libc.snprintf(buf, buflen, cstring("%d-%d"), col, vcol)
}

// Append "(2 of 8)" to "buf" when editing more than one file.
@(export)
append_arg_number :: proc "c"(wp: rawptr, buf: ^u8, buflen: C.size_t) -> C.int {
	// ALIST(curwin) is a POINTER (alist_T *w_alist) — double deref.
	// Nothing to do when there is at most one file.
	if (^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^))^ <= 1 {
		return 0
	}

	msg := cstring(" (%d of %d)")
	if (^bool)(uintptr(wp) + W_ARG_IDX_INVALID_OFF)^ {
		msg = cstring(" ((%d) of %d)")
	}

	return libc.snprintf(buf, buflen, msg,
		(^C.int)(uintptr(wp) + W_ARG_IDX_OFF)^ + 1,
		(^C.int)(uintptr((^rawptr)(uintptr(curwin) + W_ALIST_OFF)^))^)
}

// ── Batch 21: ex_buffer_all (:ball/:sball/:unhide — open a window for a
// number of buffers) ─────────────────────────────────────────────────────

EXARG_ADDR_COUNT_OFF :: 80
EXARG_LINE2_OFF :: 88
CMD_UNHIDE_O :: 499
CMD_SUNHIDE_O :: 441

foreign _ {
	@(link_name = "autocmd_no_enter")
	autocmd_no_enter_g: C.int
	@(link_name = "autocmd_no_leave")
	autocmd_no_leave_g: C.int
	@(link_name = "autowrite")
	autowrite_r :: proc "c"(buf: rawptr, forceit: bool) -> C.int ---
	@(link_name = "vgetc")
	vgetc_r :: proc "c"() -> C.int ---
}

// Open a window for a number of buffers (:ball, :sball, :unhide, ...).
@(export)
ex_buffer_all :: proc "c"(eap: rawptr) {
	split_ret: C.int = OK
	open_wins: C.int = 0
	had_tab := cmdmod_tab_o()

	// Maximum number of windows to open.
	count: C.int = 9999 // as many as possible
	if (^C.int)(uintptr(eap) + EXARG_ADDR_COUNT_OFF)^ != 0 {
		count = (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	}

	// Also load inactive buffers (not for :unhide/:sunhide).
	cmdidx := (^C.int)(uintptr(eap) + EXARG_CMDIDX_OFF)^
	all := cmdidx != CMD_UNHIDE_O && cmdidx != CMD_SUNHIDE_O

	// Stop Visual mode (cursor/"VIsual" may be invalid after switching).
	reset_VIsual_and_resel_r()

	setpcmark()

	// Close superfluous windows (two for the same buffer, non-full-width).
	if had_tab > 0 {
		goto_tabpage_tp(first_tabpage, true, true)
	}
	for {
		tpnext := (^rawptr)(uintptr(curtab) + TP_NEXT_OFF)^
		// Try to close floating windows first.
		wp := (^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^ ? lastwin_g :
			firstwin
		for wp != nil {
			wpnext: rawptr = nil
			if (^bool)(uintptr(wp) + W_FLOATING_OFF)^ {
				wprev := (^rawptr)(uintptr(wp) + W_PREV_OFF)^
				if (^bool)(uintptr(wprev) + W_FLOATING_OFF)^ {
					wpnext = wprev
				} else {
					wpnext = firstwin
				}
			} else {
				wnext := (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
				if wnext == nil ||
					(^bool)(uintptr(wnext) + W_FLOATING_OFF)^ {
					wpnext = nil
				} else {
					wpnext = wnext
				}
			}
			wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
			dup_win := (^C.int)(uintptr(wbuf) + B_NWINDOWS_OFF)^ > 1 ||
				(^bool)(uintptr(wp) + W_FLOATING_OFF)^
			narrow: bool
			if (cmdmod_split_o() & WSP_VERT_O) != 0 {
				narrow = (^C.int)(uintptr(wp) + W_HEIGHT_OFF)^ +
					(^C.int)(uintptr(wp) + W_HSEP_HEIGHT_OFF)^ +
					(^C.int)(uintptr(wp) + W_STATUS_HEIGHT_OFF)^ <
					Rows - C.int(p_ch) - tabline_height() - global_stl_height()
			} else {
				narrow = (^C.int)(uintptr(wp) + W_WIDTH_OFF)^ != Columns
			}
			extra := had_tab > 0 && wp != firstwin
			if (dup_win || narrow || extra) && firstwin != lastwin_g &&
				!(win_locked(wp) != 0 ||
					(^C.int)(uintptr(wbuf) + B_LOCKED_OFF)^ > 0) &&
				!is_aucmd_win_r(wp) {
				if win_close(wp, false, false) == FAIL {
					break
				}
				// An autocommand may do something strange: start over.
				if (^bool)(uintptr(lastwin_g) + W_FLOATING_OFF)^ {
					wpnext = lastwin_g
				} else {
					wpnext = firstwin
				}
				tpnext = first_tabpage
				open_wins = 0
			} else {
				open_wins += 1
			}
			wp = wpnext
		}

		// Without ":tab" only do the current tab page.
		if had_tab == 0 || tpnext == nil {
			break
		}
		goto_tabpage_tp(tpnext, true, true)
	}

	// Go through the buffer list. Open a window where missing, move the
	// window to the right position otherwise. Watch out for autocommands
	// deleting buffers or windows! No Win/Buf Enter/Leave autocmds here.
	autocmd_no_enter_g += 1
	// lastwin may be aucmd_win.
	win_enter(lastwin_nofloating(nil), false)
	autocmd_no_leave_g += 1
	buf := firstbuf
	for buf != nil && open_wins < count {
		// Check if this buffer needs a window.
		if ((!all && (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil) ||
			(^C.int)(uintptr(buf) + B_P_BL_OFF)^ == 0) {
			buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
			continue
		}

		nwp: rawptr = nil
		if had_tab != 0 {
			// With ":tab" don't move the window.
			if (^C.int)(uintptr(buf) + B_NWINDOWS_OFF)^ > 0 {
				nwp = lastwin_g // buffer has a window, skip it
			} else {
				nwp = nil
			}
		} else {
			// Check if this buffer already has a window.
			nwp = firstwin
			for nwp != nil {
				if !(^bool)(uintptr(nwp) + W_FLOATING_OFF)^ &&
					(^rawptr)(uintptr(nwp) + W_BUFFER_OFF)^ == buf {
					break
				}
				nwp = (^rawptr)(uintptr(nwp) + W_NEXT_OFF)^
			}
			// If the buffer already has a window, move it.
			if nwp != nil {
				win_move_after(nwp, curwin)
			}
		}

		if nwp == nil && split_ret == OK {
			bufref: Bufref_T
			set_bufref(&bufref, buf)
			// Split the window and put the buffer in it.
			p_ea_save := p_ea_g
			p_ea_g = 1 // use space from all windows
			split_ret = win_split(0, WSP_ROOM_O | WSP_BELOW_O)
			open_wins += 1
			p_ea_g = p_ea_save
			if split_ret == FAIL {
				buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
				continue
			}

			// Open the buffer in this window.
			swap_exists_action_g = SEA_DIALOG_O
			set_curbuf(buf, DOBUF_GOTO_O, (jop_flags & KOPT_JOP_CLEAN_O) == 0)
			if !bufref_valid(&bufref) {
				// Autocommands deleted the buffer.
				swap_exists_action_g = SEA_NONE_O
				break
			}
			if swap_exists_action_g == SEA_QUIT_O {
				cs: [16]u8

				// Reset error/interrupt state so aborting() is false
				// when closing the window.
				enter_cleanup_r(&cs[0])

				// User selected Quit at ATTENTION prompt: close window.
				win_close(curwin, true, false)
				open_wins -= 1
				swap_exists_action_g = SEA_NONE_O
				swap_exists_did_quit_g = true

				// Restore error/interrupt state unless discarded.
				leave_cleanup_r(&cs[0])
			} else {
				handle_swap_exists(nil)
			}
		}

		os_breakcheck()
		if got_int {
			vgetc_r() // only break file loading, not the rest
			break
		}
		// Autocommands deleted the buffer or aborted script processing!
		if aborting_r() {
			break
		}
		// With ":tab" open a new tab for a new window repeatedly.
		if had_tab > 0 && tabpage_index(nil) <= C.int(p_tpm_g) {
			set_cmdmod_tab_o(9999)
		}
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}
	autocmd_no_enter_g -= 1
	win_enter(firstwin, false) // back to first window
	autocmd_no_leave_g -= 1

	// Close superfluous windows.
	wp := lastwin_g
	for open_wins > count {
		wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		r := (buf_hide(wbuf) || !bufIsChanged(wbuf) ||
			autowrite_r(wbuf, false) == OK) && !is_aucmd_win_r(wp)
		if !win_valid(wp) {
			// BufWrite autocommands made the window invalid: start over.
			wp = lastwin_g
		} else if r {
			win_close(wp, !buf_hide(wbuf), false)
			open_wins -= 1
			wp = lastwin_g
		} else {
			wp = (^rawptr)(uintptr(wp) + W_PREV_OFF)^
			if wp == nil {
				break
			}
		}
	}
}

// ── Batch 22: title cluster (maketitle/resettitle/value_change) +
// modelines (do_modelines/chk_modeline) ──────────────────────────────────
// NOTE: free_titles() is #ifdef EXITFREE in C — this build has no EXITFREE,
// so the symbol doesn't exist here (same reason win_free_all stays C).

STL_IN_ICON_O :: 1
STL_IN_TITLE_O :: 2
SID_MODELINE_O :: -1
ETYPE_MODELINE_O :: 4

// CharBoundsOff mirrors C (mbyte_defs.h:71): two int8, 2 bytes total.
CharBoundsOff :: struct {
	begin_off: i8,
	end_off:   i8,
}
#assert(size_of(CharBoundsOff) == 2)

foreign _ {
	@(link_name = "redrawing")
	redrawing_r :: proc "c"() -> bool ---
	@(link_name = "p_titlelen")
	p_titlelen_g: C.longlong
	@(link_name = "p_titlestring")
	p_titlestring_g: ^u8
	@(link_name = "p_iconstring")
	p_iconstring_g: ^u8
	@(link_name = "build_stl_str_hl")
	build_stl_str_hl_r :: proc "c"(wp: rawptr, out: ^u8, outlen: C.size_t, fmt: cstring, opt_idx: C.int, opt_scope: C.int, fillchar: C.int, maxwidth: C.int, hltab: rawptr, hltab_len: rawptr, tabtab: rawptr, stcp: rawptr) -> C.int ---
	@(link_name = "ui_call_set_icon")
	ui_call_set_icon_r :: proc "c"(icon: NvimString) ---
	@(link_name = "ui_call_set_title")
	ui_call_set_title_r :: proc "c"(title: NvimString) ---
	@(link_name = "utf_cp_bounds")
	utf_cp_bounds_r :: proc "c"(base: ^u8, p: ^u8) -> CharBoundsOff ---
	@(link_name = "p_mls")
	p_mls_g: C.longlong
	@(link_name = "min_vim_version")
	min_vim_version_r :: proc "c"() -> C.int ---
	@(link_name = "estack_push")
	estack_push_r :: proc "c"(etype: C.int, name: cstring, lnum: C.int) -> rawptr ---
	@(link_name = "estack_pop")
	estack_pop_r :: proc "c"() ---
}

// NvimString from a C string (cstr_as_string logic: NULL-safe, no alloc).
nvim_str_o :: proc "c"(s: ^u8) -> NvimString {
	if s == nil {
		return NvimString{}
	}
	return NvimString{data = cstring(s), size = libc.strlen(cstring(s))}
}

@(private="file")
lasttitle_f: ^u8
@(private="file")
lasticon_f: ^u8

// Put the title/icon name in the window title bar and icon.
@(export)
maketitle :: proc "c"() {
	title_str: ^u8 = nil
	icon_str: ^u8 = nil
	buf: [IOSIZE_O]u8

	if !redrawing_r() {
		// Postpone updating the title when 'lazyredraw' is set.
		need_maketitle_opt = true
		return
	}

	need_maketitle_opt = false
	if p_title_g == 0 && p_icon_g == 0 && lasttitle_f == nil &&
		lasticon_f == nil {
		return // nothing to do
	}

	if p_title_g != 0 {
		maxlen: C.int = 0

		if p_titlelen_g > 0 {
			maxlen = C.int(max(p_titlelen_g * C.longlong(Columns) / 100, 10))
		}

		if p_titlestring_g != nil && p_titlestring_g^ != 0 {
			if (stl_syntax_g & STL_IN_TITLE_O) != 0 {
				build_stl_str_hl_r(curwin, &buf[0], C.size_t(IOSIZE_O),
					cstring(p_titlestring_g), kOptTitlestring_E, 0, 0, maxlen,
					nil, nil, nil, nil)
				title_str = &buf[0]
			} else {
				title_str = p_titlestring_g
			}
		} else {
			// Format: "fname + (path) (1 of 2) - Nvim".
			build_stl_str_hl_r(curwin, &buf[0], C.size_t(IOSIZE_O),
				cstring("%t%( %M%)%( (%{expand('%:p:~:h')})%)%a - Nvim"),
				kOptTitlestring_E, 0, 0, maxlen, nil, nil, nil, nil)
			title_str = &buf[0]
		}
	}
	mustset := value_change_o(title_str, &lasttitle_f)

	if p_icon_g != 0 {
		icon_str = &buf[0]
		if p_iconstring_g != nil && p_iconstring_g^ != 0 {
			if (stl_syntax_g & STL_IN_ICON_O) != 0 {
				build_stl_str_hl_r(curwin, &buf[0], C.size_t(IOSIZE_O),
					cstring(p_iconstring_g), kOptIconstring_E, 0, 0, 0,
					nil, nil, nil, nil)
			} else {
				icon_str = p_iconstring_g
			}
		} else {
			name := buf_spname(curbuf)
			if name == nil {
				name = transmute(^u8)(path_tail(cstring(
					(^u8)((^rawptr)(uintptr(curbuf) + B_FNAME)^))))
			}
			// Truncate name at 100 bytes (on a character boundary).
			namelen := C.int(libc.strlen(cstring(name)))
			if namelen > 100 {
				namelen -= 100
				namelen += C.int(utf_cp_bounds_r(name,
					(^u8)(uintptr(name) + uintptr(namelen))).end_off)
				name = (^u8)(uintptr(name) + uintptr(namelen))
			}
			xstrlcpy_o(cstring(&buf[0]), cstring(name), IOSIZE_O)
			trans_characters_o(&buf[0], IOSIZE_O)
		}
	}

	if value_change_o(icon_str, &lasticon_f) {
		mustset = true
	}

	if mustset {
		resettitle()
	}
}

// Title/icon helper: store "str" into "*last" when different.
// Returns true when resettitle() is to be called (C static).
value_change_o :: proc "c"(str: ^u8, last: ^^u8) -> bool {
	diff := (str == nil) != (last^ == nil)
	if !diff && str != nil && last^ != nil {
		diff = libc.strcmp(cstring(str), cstring(last^)) != 0
	}
	if diff {
		xfree(transmute(rawptr)(last^))
		if str == nil {
			last^ = nil
			resettitle()
		} else {
			last^ = xstrdup_o(str)
			return true
		}
	}
	return false
}

// Set current window title/icon on the UI.
@(export)
resettitle :: proc "c"() {
	ui_call_set_icon_r(nvim_str_o(lasticon_f))
	ui_call_set_title_r(nvim_str_o(lasttitle_f))
}

// ascii_isspace (ascii_defs.h:165, static inline): \t\n\v\f\r + space.
ascii_isspace_o :: proc "c"(c: C.int) -> bool {
	return (c >= 9 && c <= 13) || c == ' '
}

@(private="file")
do_modelines_entered: bool

// Process modelines for the current file (top/bottom "mls" lines).
@(export)
do_modelines :: proc "c"(flags: C.int) {
	if (^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^ == 0 ||
		C.int(p_mls_g) == 0 {
		return
	}

	// Disallow recursive entry (a modeline autocmd reloading via ":do").
	if do_modelines_entered {
		return
	}

	do_modelines_entered = true
	nmlines := C.int(p_mls_g)
	lnum: C.int = 1
	for (^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^ != 0 &&
		lnum <= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ &&
		lnum <= nmlines {
		if chk_modeline_o(lnum, flags) == FAIL {
			nmlines = 0
		}
		lnum += 1
	}

	lnum = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^
	for (^C.int)(uintptr(curbuf) + B_P_ML_OFF2)^ != 0 && lnum > 0 &&
		lnum > nmlines &&
		lnum > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT_OFF)^ - nmlines {
		if chk_modeline_o(lnum, flags) == FAIL {
			nmlines = 0
		}
		lnum -= 1
	}
	do_modelines_entered = false
}

// Check a single line for a mode string (C static).
// Returns FAIL when an error is encountered.
chk_modeline_o :: proc "c"(lnum: C.int, flags: C.int) -> C.int {
	retval: C.int = OK
	// ESTACK_CHECK_DECLARATION is a no-op (no ABORT_ON_INTERNAL_ERROR).

	prev: C.int = -1
	s := ml_get(lnum)
	line_end := (^u8)(uintptr(s) + uintptr(C.int(ml_get_len_r2(lnum))))
	for ([^]u8)(s)[0] != 0 {
		if prev == -1 || ascii_isspace_o(prev) {
			if (prev != -1 &&
				libc.strncmp(cstring(s), cstring("ex:"), 3) == 0) ||
				libc.strncmp(cstring(s), cstring("vi:"), 3) == 0 {
				break
			}
			// Accept both "vim" and "Vim".
			if (([^]u8)(s)[0] == 'v' || ([^]u8)(s)[0] == 'V') &&
				([^]u8)(s)[1] == 'i' && ([^]u8)(s)[2] == 'm' {
				e: ^u8 = nil
				if ([^]u8)(s)[3] == '<' || ([^]u8)(s)[3] == '=' ||
					([^]u8)(s)[3] == '>' {
					e = (^u8)(uintptr(s) + 4)
				} else {
					e = (^u8)(uintptr(s) + 3)
				}
				vers: i64 = 0
				if !_try_getdigits(&e, &vers) {
					prev = C.int(([^]u8)(s)[0])
					s = (^u8)(uintptr(s) + 1)
					continue
				}

				vim_version := min_vim_version_r()
				set_like := libc.strncmp(skipwhite(cstring(
					(^u8)(uintptr(e) + 1))), cstring("set"), 3) == 0
				s3 := ([^]u8)(s)[3]
				version_ok := s3 == ':' ||
					(i64(vim_version) >= vers && ascii_isdigit_o(s3)) ||
					(i64(vim_version) < vers && s3 == '<') ||
					(i64(vim_version) > vers && s3 == '>') ||
					(i64(vim_version) == vers && s3 == '=')
				if ([^]u8)(e)[0] == ':' && (([^]u8)(s)[0] != 'V' || set_like) &&
					version_ok {
					break
				}
			}
		}
		prev = C.int(([^]u8)(s)[0])
		s = (^u8)(uintptr(s) + 1)
	}

	if ([^]u8)(s)[0] == 0 {
		return retval
	}

	// Skip over "ex:", "vi:" or "vim...:".
	for ([^]u8)(s)[0] != ':' {
		s = (^u8)(uintptr(s) + 1)
	}
	s = (^u8)(uintptr(s) + 1)

	line_len := C.size_t(uintptr(line_end) - uintptr(s))
	linecopy := xstrnsave_c(cstring(s), line_len) // copy; it will change
	s = linecopy
	line_end = (^u8)(uintptr(s) + uintptr(line_len))

	// Prepare for emsg().
	estack_push_r(ETYPE_MODELINE_O, cstring("modelines"), lnum)
	// ESTACK_CHECK_SETUP is a no-op.

	end := false
	for !end {
		s = transmute(^u8)(skipwhite(cstring(s)))
		if ([^]u8)(s)[0] == 0 {
			break
		}

		// Find end of set command (':' or EOL), unescaping "\:".
		e := s
		for ([^]u8)(e)[0] != ':' && ([^]u8)(e)[0] != 0 {
			if ([^]u8)(e)[0] == '\\' && ([^]u8)(e)[1] == ':' {
				libc.memmove(transmute(rawptr)(e),
					transmute(rawptr)((^u8)(uintptr(e) + 1)),
					C.size_t(uintptr(line_end) - (uintptr(e) + 1)) + 1)
				line_end = (^u8)(uintptr(line_end) - 1)
			}
			e = (^u8)(uintptr(e) + 1)
		}
		if ([^]u8)(e)[0] == 0 {
			end = true
		}

		// A "set"/"se" command requires a terminating ':'; text after it
		// is ignored ("vi:set opt: foo" — foo not interpreted).
		if libc.strncmp(cstring(s), cstring("set "), 4) == 0 ||
			libc.strncmp(cstring(s), cstring("se "), 3) == 0 {
			if ([^]u8)(e)[0] != ':' { // no terminating ':'?
				break
			}
			end = true
			if ([^]u8)(s)[2] == ' ' {
				s = (^u8)(uintptr(s) + 3)
			} else {
				s = (^u8)(uintptr(s) + 4)
			}
		}
		([^]u8)(e)[0] = 0 // truncate the set command

		if ([^]u8)(s)[0] != 0 { // skip over an empty "::"
			secure_save := secure
			save_sid := (^C.int)(uintptr(&current_sctx_buf[0]))^
			save_seq := (^C.int)(uintptr(&current_sctx_buf[0]) + 4)^
			save_lnum := (^C.int)(uintptr(&current_sctx_buf[0]) + 8)^
			(^C.int)(uintptr(&current_sctx_buf[0]))^ = SID_MODELINE_O
			(^C.int)(uintptr(&current_sctx_buf[0]) + 4)^ = 0
			(^C.int)(uintptr(&current_sctx_buf[0]) + 8)^ = lnum
			// Make sure no risky things run as a side effect.
			secure = 1

			retval = do_set(s, OPT_MODELINE_S | OPT_LOCAL_S | flags)

			secure = secure_save
			(^C.int)(uintptr(&current_sctx_buf[0]))^ = save_sid
			(^C.int)(uintptr(&current_sctx_buf[0]) + 4)^ = save_seq
			(^C.int)(uintptr(&current_sctx_buf[0]) + 8)^ = save_lnum
			if retval == FAIL { // stop if error found
				break
			}
		}
		// Advance to next part (careful not to go off the end).
		if uintptr(e) == uintptr(line_end) {
			s = e
		} else {
			s = (^u8)(uintptr(e) + 1)
		}
	}

	// ESTACK_CHECK_NOW is a no-op.
	estack_pop_r()
	xfree(transmute(rawptr)(linecopy))

	return retval
}

// ── Batch 23: final buffer.c leaves (buf_close_terminal, buflist_nr2name,
// buflist_setfpos, buflist_name_nr, fname_expand, do_autochdir, get_rel_pos)
// NOTE: buflist_slash_adjust is #ifdef BACKSLASH_IN_FILENAME (Windows-only),
// like completeslash — skipped on Linux. ──────────────────────────────────

KCDCAUSE_AUTO_O :: 2 // CdCause.kCdCauseAuto (vim_defs.h:53)

foreign _ {
	@(link_name = "terminal_close")
	terminal_close_r :: proc "c"(termpp: rawptr, status: C.int) ---
	@(link_name = "fix_fname")
	fix_fname_r :: proc "c"(fname: cstring) -> ^u8 ---
	@(link_name = "vim_chdirfile")
	vim_chdirfile_r :: proc "c"(fname: cstring, cause: C.int) -> C.int ---
	@(link_name = "win_get_fill")
	win_get_fill_r :: proc "c"(wp: rawptr, lnum: C.int) -> C.int ---
}

// Close the terminal link of buffer "buf".
@(export)
buf_close_terminal :: proc "c"(buf: rawptr) {
	// assert(buf->terminal) is debug-only (no assert in Odin).
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ += 1
	terminal_close_r(rawptr(uintptr(buf) + B_TERMINAL_OFF), -1)
	(^C.int)(uintptr(buf) + B_LOCKED_OFF)^ -= 1
}

// Name of file 'n' in the buffer list (home-shortened, allocated or NULL).
@(export)
buflist_nr2name :: proc "c"(n: C.int, fullname: C.int, helptail: C.int) -> ^u8 {
	buf := buflist_findnr(n)
	if buf == nil {
		return nil
	}
	src := (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
	if fullname != 0 {
		src = (^u8)((^rawptr)(uintptr(buf) + B_FFNAME)^)
	}
	ctx: rawptr = nil
	if helptail != 0 {
		ctx = buf
	}
	return (^u8)(home_replace_save(ctx, cstring(src)))
}

// Set line/column (+window options) for buffer "buf", window "win".
@(export)
buflist_setfpos :: proc "c"(buf: rawptr, win: rawptr, lnum_in: C.int, col: C.int, copy_options: bool) {
	lnum := lnum_in
	n := (^u64)(uintptr(buf) + B_WINFOFF_SIZE)^
	items := (^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^
	i: u64 = 0
	wip: rawptr = nil
	for i < n {
		wip = ([^]rawptr)(items)[i]
		if (^rawptr)(uintptr(wip) + WI_WIN_OFF)^ == win {
			break
		}
		i += 1
	}

	if i == n {
		// Allocate a new entry.
		wip = xcalloc(1, WININFO_SIZE_O)
		(^rawptr)(uintptr(wip) + WI_WIN_OFF)^ = win
		if lnum == 0 { // set lnum even when it's 0
			lnum = 1
		}
	} else {
		// Remove the entry from the list (kv_shift by 1: memmove + shrink).
		if i < n - 1 {
			libc.memmove(rawptr(uintptr(items) + uintptr(i * 8)),
				rawptr(uintptr(items) + uintptr((i + 1) * 8)),
				C.size_t((n - 1 - i) * 8))
		}
		(^u64)(uintptr(buf) + B_WINFOFF_SIZE)^ = n - 1
		if copy_options && (^bool)(uintptr(wip) + WI_OPTSET_OFF)^ {
			clear_winopt(transmute(rawptr)(uintptr(wip) + WI_OPT_OFF))
			deleteFoldRecurse(buf, transmute(^Garray)(uintptr(wip) + WI_FOLDS_OFF))
		}
	}
	if lnum != 0 {
		(^C.int)(uintptr(wip) + WI_MARK_OFF)^ = lnum
		(^C.int)(uintptr(wip) + WI_MARK_OFF + 4)^ = col
		if win != nil {
			pos := Pos_T{lnum = lnum, col = col, coladd = 0}
			(^Fmarkv_T)(uintptr(wip) + WI_MARK_OFF + 24)^ =
				mark_view_make(win, pos)
		}
	}
	if win != nil {
		(^C.int)(uintptr(wip) + WI_CHANGELISTIDX_OFF)^ =
			(^C.int)(uintptr(win) + W_CHANGELISTIDX)^
	}
	if copy_options && win != nil {
		// Save the window-specific option values.
		copy_winopt(transmute(rawptr)(uintptr(win) + W_ONEBUF_OPT_OFF),
			transmute(rawptr)(uintptr(wip) + WI_OPT_OFF))
		(^bool)(uintptr(wip) + WI_FOLD_MANUAL_OFF)^ =
			(^bool)(uintptr(win) + W_FOLD_MANUAL_OFF)^
		cloneFoldGrowArray(transmute(^Garray)(uintptr(win) + W_FOLDS_OFF),
			transmute(^Garray)(uintptr(wip) + WI_FOLDS_OFF))
		(^bool)(uintptr(wip) + WI_OPTSET_OFF)^ = true
	}

	// Insert the entry in front of the list (kv_pushp + shift right).
	n2 := (^u64)(uintptr(buf) + B_WINFOFF_SIZE)^
	cap := (^u64)(uintptr(buf) + B_WINFOFF_CAP)^
	if n2 == cap {
		newcap := cap << 1
		if newcap == 0 {
			newcap = 8
		}
		items = xrealloc(items, C.size_t(newcap * 8))
		(^rawptr)(uintptr(buf) + B_WINFOFF_ITEMS)^ = items
		(^u64)(uintptr(buf) + B_WINFOFF_CAP)^ = newcap
	}
	if n2 > 0 {
		libc.memmove(rawptr(uintptr(items) + 8), rawptr(uintptr(items)),
			C.size_t(n2 * 8))
	}
	([^]rawptr)(items)[0] = wip
	(^u64)(uintptr(buf) + B_WINFOFF_SIZE)^ = n2 + 1
}

// File name + line number for file 'fnum' (for '%'/'#' expansion).
@(export)
buflist_name_nr :: proc "c"(fnum: C.int, fname: ^^u8, lnum: ^C.int) -> C.int {
	buf := buflist_findnr(fnum)
	if buf == nil || (^rawptr)(uintptr(buf) + B_FNAME)^ == nil {
		return FAIL
	}

	fname^ = (^u8)((^rawptr)(uintptr(buf) + B_FNAME)^)
	lnum^ = buflist_findlnum(buf)

	return OK
}

// Expand "*ffname" to a full path; default "*sfname" from it when NULL.
// The old "*ffname" pointer value is not freed (C contract).
@(export)
fname_expand :: proc "c"(buf: rawptr, ffname: ^cstring, sfname: ^cstring) {
	if ffname^ == nil { // no file name given, nothing to do
		return
	}
	if sfname^ == nil { // no short file name given, use ffname
		sfname^ = ffname^
	}
	ffname^ = transmute(cstring)(fix_fname_r(ffname^)) // expand to full path

	// MSWIN shortcut resolution dropped (Linux-only port).
}

// Change directory to the current file's directory when 'autochdir'.
@(export)
do_autochdir :: proc "c"() {
	if p_acd_g != 0 {
		if starting == 0 &&
			(^rawptr)(uintptr(curbuf) + B_FFNAME)^ != nil &&
			vim_chdirfile_r(cstring((^u8)((^rawptr)(uintptr(curbuf) + B_FFNAME)^)),
				KCDCAUSE_AUTO_O) == OK {
			last_chdir_reason_g = transmute(rawptr)(cstring("autochdir"))
			shorten_fnames(true)
		}
	}
}

// Relative cursor position ("%99", "Top"/"Bot"/"All") for the statusline.
@(export)
get_rel_pos :: proc "c"(wp: rawptr, buf: ^u8, buflen: C.int) -> C.int {
	// Need at least 3 chars for writing.
	if buflen < 3 {
		return 0
	}

	above := (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ - 1
	above += win_get_fill_r(wp, (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) -
		(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
	if (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ == 1 &&
		(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^ >= 1 {
		// All lines displayed plus filler indication: seeing everything.
		above = 0
	}
	wbuf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	below := (^C.int)(uintptr(wbuf) + B_ML_LINE_COUNT_OFF)^ -
		(^C.int)(uintptr(wp) + W_BOTLINE_OFF)^ + 1
	if below <= 0 {
		return libc.snprintf(buf, C.size_t(buflen), cstring("%s"),
			cstring(above == 0 ? "All" : "Bot"))
	}

	if above <= 0 {
		return libc.snprintf(buf, C.size_t(buflen), cstring("%s"),
			cstring("Top"))
	}

	perc := calc_percentage(i64(above), i64(above + below))
	tmp: [8]u8
	// Localized percentage value.
	libc.snprintf(&tmp[0], C.size_t(8), cstring("%d%%"), perc)
	return libc.snprintf(buf, C.size_t(buflen), cstring("%3s"),
		cstring(&tmp[0]))
}
