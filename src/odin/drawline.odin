// drawline.odin — port of src/nvim/drawline.c (window line drawing)
package main

import C "core:c"
import "core:c/libc"

foreign _ {
	@(link_name = "decor_virt_line_rows")
	decor_virt_line_rows_r :: proc "c"(wp: rawptr, vl: rawptr, target_row: C.int, skip_cells: ^C.int) -> C.int ---
}

// decor_redraw_col (decoration.h:110 static inline).
decor_redraw_col_o :: proc "c"(wp: rawptr, col: C.int, win_col: C.int, hidden: bool, state: ^DecorState_O, max_col_last: C.int) -> C.int {
	if col <= state.col_last {
		return state.current
	}
	return decor_redraw_col_impl_r(wp, col, win_col, hidden, transmute(rawptr)(state), max_col_last)
}

// virt_line element for decor_virt_line_rows (24+4+4 = 32B).
VirtLine_O :: struct {
	line:     Kvec_VT, // 0
	flags:    C.int,   // 24
	overflow: C.int,   // 28 (VirtLineOverflow)
}
#assert(size_of(VirtLine_O) == 32)

// W_SCWIDTH_OFF reuses optionstr.odin (=680).
W_BOTFILL_OFF :: 380 // w_botfill (bool)
W_CLINE_ROW_OFF :: 592 // w_cline_row (int)
W_CLINE_HEIGHT_OFF :: 584 // w_cline_height (int)
HLF_FL_O :: 28
K_VL_LEFTCOL_O :: 1 // kVLLeftcol

B_MARKTREE_OFF :: 12512 // b_marktree (MarkTree[1])
MARKTREE_META_ROOT_OFF :: 8 // meta_root (u32[kMTMetaCount])
K_MTMETA_INLINE_O :: 0
TERM_ATTRS_MAX_O :: 1024

foreign _ {
	@(link_name = "decor_providers_invoke_line")
	decor_providers_invoke_line_r :: proc "c"(wp: rawptr, lnum: C.int) ---
	// validate_virtcol_r: optionstr.odin (identical sig).
	// decor_redraw_line_r: spell.odin (identical sig).
	@(link_name = "decor_has_more_decorations")
	decor_has_more_decorations_r :: proc "c"(state: rawptr, lnum: C.int) -> bool ---
	@(link_name = "prepare_search_hl_line")
	prepare_search_hl_line_r :: proc "c"(wp: rawptr, lnum: C.int, mincol: C.int, line: ^^u8, search_hl: rawptr, search_attr: ^C.int, search_attr_from_match: ^bool) -> bool ---
	@(link_name = "screen_search_hl")
	screen_search_hl_u8: u8 // address-of only (match_T passed opaquely)
	@(link_name = "ins_compl_win_active")
	ins_compl_win_active_r :: proc "c"(wp: rawptr) -> bool ---
	@(link_name = "ins_compl_lnum_in_range")
	ins_compl_lnum_in_range_r :: proc "c"(lnum: C.int) -> bool ---
	@(link_name = "terminal_get_line_attributes")
	terminal_get_line_attributes_r :: proc "c"(term: rawptr, wp: rawptr, linenr: C.int, term_attrs: ^C.int) ---
}

// buf_meta_total inline (buffer.h:91): b_marktree->meta_root[m].
buf_meta_total_o :: proc "c"(b: rawptr, m: C.int) -> u32 {
	return (^u32)(uintptr(b) + B_MARKTREE_OFF + MARKTREE_META_ROOT_OFF + uintptr(m) * 4)^
}

// decor_providers_setup (drawline.c:3346 static): vcols for the providers.
decor_providers_setup_o :: proc "c"(rows_to_draw: C.int, draw_from_line_start: bool, lnum: C.int, col: C.int, wp: rawptr) -> C.int {
	// Assume 1-cell ascii; ignore linebreak/breakindent/etc.
	rem_vcols: C.int
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
		width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp)
		width2 := width + win_col_off2_r(wp)
		first_row_width := width2
		if draw_from_line_start {
			first_row_width = width
		}
		rem_vcols = first_row_width + (rows_to_draw - 1) * width2
	} else {
		rem_vcols = (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - win_col_off_r(wp)
	}

	// Invalidate the line pointer anyway.
	decor_providers_invoke_line_r(wp, lnum - 1)
	validate_virtcol_r(wp)

	return invoke_range_next_o(wp, lnum, col, rem_vcols + 1)
}

foreign _ {
	@(link_name = "decor_providers_invoke_range")
	decor_providers_invoke_range_r :: proc "c"(wp: rawptr, lnum1: C.int, col1: C.int, lnum2: C.int, col2: C.int) ---
	@(link_name = "mb_off_next")
	mb_off_next_r :: proc "c"(base: ^u8, p: ^u8) -> C.int ---
}

// invoke_range_next (drawline.c:3371 static): next provider range.
invoke_range_next_o :: proc "c"(wp: rawptr, lnum: C.int, begin_col: C.int, col_off: C.int) -> C.int {
	line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
	line_len := ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
	co := max(col_off, 1)

	new_col: C.int
	if co <= line_len - begin_col {
		end_col := begin_col + co
		end_col += mb_off_next_r(line, (^u8)(uintptr(line) + uintptr(end_col)))
		decor_providers_invoke_range_r(wp, lnum - 1, begin_col, lnum - 1, end_col)
		validate_virtcol_r(wp)
		new_col = end_col
	} else {
		decor_providers_invoke_range_r(wp, lnum - 1, begin_col, lnum, 0)
		validate_virtcol_r(wp)
		new_col = 2147483647 // INT_MAX
	}

	return new_col
}

// ── Batch 12b1: charsize API mirrors + skip-to-display block ──────────────────

CharInfo_O :: struct {
	value: C.int32_t, // 0
	len:   C.int,     // 4
}
#assert(size_of(CharInfo_O) == 8)

StrCharInfo_O :: struct {
	ptr: ^u8,       // 0
	chr: CharInfo_O, // 8
}
#assert(size_of(StrCharInfo_O) == 16)

CharSize_O :: struct {
	width: C.int, // 0
	head:  C.int, // 4
	tail:  C.int, // 8
}
#assert(size_of(CharSize_O) == 12)

CharsizeArg_O :: struct {
	win:                 rawptr,   // 0
	line:                ^u8,      // 8
	use_tabstop:         bool,     // 16
	_pad17:              [3]u8,
	indent_width:        C.int,    // 20
	virt_row:            C.int,    // 24
	cur_text_width_left: C.int,    // 28
	cur_text_width_right: C.int,   // 32
	max_head_vcol:       C.int,    // 36
	iter:                [216]u8,  // 40 (MarkTreeIter, opaque)
}
#assert(size_of(CharsizeArg_O) == 256)

K_CHARSIZE_REGULAR_O :: false
K_CHARSIZE_FAST_O :: true

HLF_COUNT_O :: 76
FORWARD_O :: 1
SMT_ALL_O :: 0

// lcs_chars_T sub-fields (buffer_defs.h:1055-1072; multispace@56/leadmulti@64
// confirmed by optionstr.odin xfree sites).
LCS_SPACE_OFF :: 16
LCS_TRAIL_OFF :: 48
LCS_LEAD_OFF :: 44
LCS_NBSP_OFF :: 12
LCS_LEADTAB1_OFF :: 32
LCS_MULTISPACE_OFF :: 56
LCS_LEADMULTISPACE_OFF :: 64

foreign _ {
	@(link_name = "utf8len_tab")
	utf8len_tab_g: [256]u8
	@(link_name = "highlight_attr")
	highlight_attr_g: [HLF_COUNT_O]C.int
	@(link_name = "utf_ptr2CharInfo_impl")
	utf_ptr2CharInfo_impl_r :: proc "c"(p: ^u8, len: C.size_t) -> C.int32_t ---
	@(link_name = "utfc_next_impl")
	utfc_next_impl_r :: proc "c"(cur: StrCharInfo_O) -> StrCharInfo_O ---
	@(link_name = "init_charsize_arg")
	init_charsize_arg_r :: proc "c"(csarg: ^CharsizeArg_O, wp: rawptr, lnum: C.int, line: ^u8) -> bool ---
	@(link_name = "charsize_regular")
	charsize_regular_r :: proc "c"(csarg: ^CharsizeArg_O, cur: ^u8, vcol: C.int, cur_char: C.int32_t) -> CharSize_O ---
	@(link_name = "charsize_fast")
	charsize_fast_r :: proc "c"(csarg: ^CharsizeArg_O, cur: ^u8, vcol: C.int, cur_char: C.int32_t) -> CharSize_O ---
	// virtual_active_r: undo.odin (identical sig).
}

// mbyte.h:72 static inline.
utf_ptr2CharInfo_o :: proc "c"(p_in: ^u8) -> CharInfo_O {
	p := ([^]u8)(p_in)
	first := p[0]
	if first < 0x80 {
		return CharInfo_O{value = C.int32_t(first), len = 1}
	}
	slen := C.int(utf8len_tab_g[first])
	code := utf_ptr2CharInfo_impl_r(p, C.size_t(slen))
	if code < 0 {
		slen = 1
	}
	return CharInfo_O{value = code, len = slen}
}

// mbyte.h:108 static inline.
utf_ptr2StrCharInfo_o :: proc "c"(ptr: ^u8) -> StrCharInfo_O {
	return StrCharInfo_O{ptr = ptr, chr = utf_ptr2CharInfo_o(ptr)}
}

// mbyte.h:93 static inline utfc_next (ASCII-guarded wrapper around the impl).
// CALL THIS, never utfc_next_impl_r directly: the impl asserts *next >= 0x80.
utfc_next_o :: proc "c" (cur: StrCharInfo_O) -> StrCharInfo_O {
	nextp := (^u8)(uintptr(cur.ptr) + uintptr(cur.chr.len))
	next := nextp^
	if next < 0x80 {
		return StrCharInfo_O{ptr = nextp, chr = CharInfo_O{value = C.int32_t(next), len = 1}}
	}
	return utfc_next_impl_r(cur)
}

// plines.h:51 static inline dispatcher.
win_charsize_o :: proc "c"(cstype: bool, vcol: C.int, ptr: ^u8, chr: C.int32_t, csarg: ^CharsizeArg_O) -> CharSize_O {
	if cstype == K_CHARSIZE_FAST_O {
		return charsize_fast_r(csarg, ptr, vcol, chr)
	}
	return charsize_regular_r(csarg, ptr, vcol, chr)
}

// ── Batch 12a: win_line engine chunk 1 (setup) ─────────────────────────────────
// Constructed dormant as win_line_new (stub return at end); renamed to
// win_line + weak-marked at activation after the final chunk. Chunk map:
// 12a setup (1106-1495) | 12b loop-1 | 12c loop-2 | 12d flush/epilogue.

Spellvars_O :: struct {
	spv_has_spell:   bool,  // 0
	spv_unchanged:   bool,  // 1
	_pad2:           [2]u8,
	spv_checked_col: C.int, // 4
	spv_checked_lnum: C.int, // 8 (linenr_T)
	spv_cap_col:     C.int, // 12
	spv_capcol_lnum: C.int, // 16 (linenr_T)
}
#assert(size_of(Spellvars_O) == 20)

Diffline_O :: struct { // diffline_S: 8+4+4+4 = 20, align 8 → 24
	changes:    rawptr, // 0 (^diffline_change_T, opaque)
	num_changes: C.int, // 8
	bufidx:     C.int,  // 12
	lineoff:    C.int,  // 16
	_pad20:     [4]u8,
}
#assert(size_of(Diffline_O) == 24)

SPWORDLEN_O :: 150
FOLD_TEXT_LEN_O :: 51

// diffline_change_S: 4×colnr_T[8] = 128B (buffer_defs.h:813-818).
DiffChange_O :: struct {
	dc_start:          [8]C.int, // 0
	dc_end:            [8]C.int, // 32
	dc_start_lnum_off: [8]C.int, // 64
	dc_end_lnum_off:   [8]C.int, // 96
}
#assert(size_of(DiffChange_O) == 128)

foreign _ {
	@(link_name = "update_search_hl")
	update_search_hl_r :: proc "c"(wp: rawptr, lnum: C.int, col: C.int, line: ^^u8, search_hl: rawptr, has_match_conc: ^C.int, match_conc: ^C.int, lcs_eol_todo: bool, on_last_col: ^bool, search_attr_from_match: ^bool) -> C.int ---
	@(link_name = "ins_compl_col_range_attr")
	ins_compl_col_range_attr_r :: proc "c"(lnum: C.int, col: C.int) -> C.int ---
}

HLF_ADD_O :: 30
HLF_TXA_O :: 34
HLF_TXD_O :: 33
HLF_CHD_O :: 31
HLF_V_O :: 24
HLF_I_O :: 7
HLF_QFL_O :: 58

W_P_FDT_OFF :: 936 // w_p_fdt (^u8 slot)
W_P_LBR_OFF :: 952 // w_p_lbr (int)
W_SYN_ERROR_OFF :: 592 // synblock_T.b_syn_error (bool)
W_SYN_SLOW_OFF :: 593 // synblock_T.b_syn_slow (bool)
W_OLD_CURSOR_FCOL_OFF :: 172
W_OLD_CURSOR_LCOL_OFF :: 176
HLF_CONCEAL_O :: 36

foreign _ {
	// highlight_match_g: ex_cmds.odin (identical bool).
	@(link_name = "syntax_start")
	syntax_start_r :: proc "c"(wp: rawptr, lnum: C.int) ---
	@(link_name = "getvvcol")
	getvvcol_r :: proc "c"(wp: rawptr, pos: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) ---
	@(link_name = "gchar_pos")
	gchar_pos_r :: proc "c"(pos: ^Pos_T) -> C.int ---
	@(link_name = "cursor_is_block_during_visual")
	cursor_is_block_during_visual_r :: proc "c"(exclusive: bool) -> bool ---
	@(link_name = "win_bg_attr")
	win_bg_attr_r :: proc "c"(wp: rawptr) -> C.int ---
	@(link_name = "diff_check_with_linestatus")
	diff_check_with_linestatus_r :: proc "c"(wp: rawptr, lnum: C.int, linestatus: ^C.int) -> C.int ---
	@(link_name = "diff_find_change")
	diff_find_change_r :: proc "c"(wp: rawptr, lnum: C.int, diffline: ^Diffline_O) -> bool ---
	@(link_name = "diff_change_parse")
	diff_change_parse_r :: proc "c"(diffline: ^Diffline_O, change: rawptr, change_start: ^C.int, change_end: ^C.int) -> bool ---
}

// pos_T <= pos_T (mark_defs.h:120 static inline).
ltoreq_o :: proc "c"(a: Pos_T, b: Pos_T) -> bool {
	if a.lnum != b.lnum {
		return a.lnum < b.lnum
	} else if a.col != b.col {
		return a.col < b.col
	}
	return a.coladd <= b.coladd
}

@(export)
win_line :: proc "c"(wp: rawptr, lnum: C.int, startrow: C.int, endrow: C.int, col_rows: C.int, concealed: bool, spv: ^Spellvars_O, foldinfo: Wlv_Foldinfo) -> C.int {
	vcol_prev: C.int = -1 // wlv.vcol of previous character
	grid := (^GridView)(uintptr(wp) + W_GRID_OFF) // window grid
	view_width := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^
	view_height := (^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^

	cur := curwin
	in_curline := wp == cur && lnum == (^C.int)(uintptr(cur) + W_CURSOR_OFF)^
	has_fold := foldinfo.fi_level != 0 && foldinfo.fi_lines > 0
	has_foldtext: bool = has_fold && (([^]u8)((^rawptr)(uintptr(wp) + W_P_FDT_OFF)^))[0] != 0

	is_wrapped := (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 &&
		!has_fold // never wrap folded lines

	saved_attr2: C.int = 0 // char_attr saved for n_attr
	n_attr3: C.int = 0 // chars with overruling special attr
	saved_attr3: C.int = 0 // char_attr saved for n_attr3

	fromcol_prev: C.int = -2 // start of inverting after cursor
	noinvcur := false // don't invert the cursor
	lnum_in_visual_area := false

	char_attr_pri: C.int = 0 // high-priority attributes
	char_attr_base: C.int = 0 // low-priority attributes
	area_highlighting := false // Visual/incsearch highlighting in line
	vi_attr: C.int = 0 // Visual + incsearch attributes
	area_attr: C.int = 0 // attributes desired by highlighting
	search_attr: C.int = 0 // 'hlsearch'/ComplMatchIns attributes
	vcol_save_attr: C.int = 0 // saved attr for 'cursorcolumn'
	decor_attr: C.int = 0 // syntax + extmark attributes
	has_syntax := false // buffer has syntax highlighting
	folded_attr: C.int = 0 // folded-line attributes
	eol_hl_off: C.int = 0 // 1 if highlighted char after EOL
	nextline: [SPWORDLEN_O * 2]u8 // next-line text start
	nextlinecol: C.int = 0 // column where nextline[] starts
	nextline_idx: C.int = 0 // index where next line starts
	spell_attr: C.int = 0 // spelling attributes
	word_end: C.int = 0 // last byte with same spell_attr
	cur_checked_col: C.int = 0 // checked column for current line
	extra_check := false // extra highlighting
	multi_attr: C.int = 0 // multibyte attributes
	mb_l: C.int = 1 // multi-byte byte length
	mb_c: C.int = 0 // decoded multi-byte character
	mb_schar: u32 = 0 // complete screen char
	change_start: C.int = MAXCOL // first col of changed area
	change_end: C.int = -1 // last col of changed area
	in_multispace := false // in multiple consecutive spaces
	multispace_pos: C.int = 0 // position in lcs-multispace string

	n_extra_next: C.int = 0 // n_extra after current extra chars
	extra_attr_next: C.int = -1 // extra_attr after current extra chars

	search_attr_from_match := false // search_attr is from :match
	has_decor := false // buffer has decoration

	saved_search_attr: C.int = 0 // search_attr when n_extra hits zero
	saved_area_attr: C.int = 0 // idem for area_attr
	saved_decor_attr: C.int = 0 // idem for decor_attr
	saved_search_attr_from_match := false

	win_col_offset: C.int = 0 // offset for window columns
	area_active := false // in Visual selection, for virtual text
	decor_need_recheck := false // decor_recheck_draw_col() at next char

	buf_fold: [FOLD_TEXT_LEN_O]u8 // get_foldtext value
	fold_vt := Kvec_VT{} // VIRTTEXT_EMPTY
	foldtext_free: ^u8 = nil

	// 'cursorlineopt' screenline + cursor in this line
	cul_screenline := false
	// margin columns for the screen line ('cursorlineopt' screenline)
	left_curline_col: C.int = 0
	right_curline_col: C.int = 0

	match_conc: C.int = 0 // cchar for match functions
	on_last_col := false
	syntax_flags: C.int = 0
	syntax_seqnr: C.int = 0
	prev_syntax_id: C.int = 0
	conceal_attr := win_hl_attr_o(wp, HLF_CONCEAL_O)
	is_concealing := false
	did_wcol := false

	if !(startrow < endrow) {
		libc.abort()
	}

	// Variables passed between functions.
	wlv := WinLineVars{
		lnum = lnum,
		foldinfo = foldinfo,
		startrow = startrow,
		row = startrow,
		fromcol = -10,
		tocol = MAXCOL,
		vcol_sbr = -1,
		old_boguscols = 0,
		prev_num_attr = -1,
	}

	buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	// No text when concealed or filler past last line.
	draw_text := !concealed && (lnum != (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ + 1)

	decor_provider_end_col: C.int
	check_decor_providers := false

	if col_rows == 0 && draw_text {
		// Speed up the loop: extra_check for linebreak/trailing space/syntax.
		extra_check = (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0
		ws := (^rawptr)(uintptr(wp) + W_S_OFF)^
		if syntax_present_r(wp) && (^bool)(uintptr(ws) + W_SYN_ERROR_OFF)^ == false &&
			(^bool)(uintptr(ws) + W_SYN_SLOW_OFF)^ == false && !has_foldtext {
			// Prepare syntax highlighting; on error stop it.
			save_did_emsg := did_emsg_g()
			did_emsg_set(false)
			syntax_start_r(wp, lnum)
			if did_emsg_g() != 0 {
				(^bool)(uintptr(ws) + W_SYN_ERROR_OFF)^ = true
			} else {
				did_emsg_set(save_did_emsg != 0)
				if (^bool)(uintptr(ws) + W_SYN_SLOW_OFF)^ == false {
					has_syntax = true
					extra_check = true
				}
			}
		}

		check_decor_providers = true

		// 'colorcolumn' columns.
		if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil {
			wlv.color_cols = nil
		} else {
			wlv.color_cols = (^[^]C.int)(uintptr(wp) + W_P_CC_COLS_OFF)^
		}
		advance_color_col_o(&wlv, wlv.vcol - wlv.vcol_off_co)

		// Visual active in this window.
		if VIsual_active && (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == (^rawptr)(uintptr(cur) + W_BUFFER_OFF)^ {
			top: ^Pos_T
			bot: ^Pos_T
			cur_cursor := (^Pos_T)(uintptr(cur) + W_CURSOR_OFF)

			if ltoreq_o(cur_cursor^, VIsual_g) {
				// Visual is after the cursor.
				top = cur_cursor
				bot = &VIsual_g
			} else {
				// Visual is before the cursor.
				top = &VIsual_g
				bot = cur_cursor
			}
			lnum_in_visual_area = (lnum >= top.lnum && lnum <= bot.lnum)
			if VIsual_mode == Ctrl_V {
				// Block mode.
				if lnum_in_visual_area {
					wlv.fromcol = (^C.int)(uintptr(wp) + W_OLD_CURSOR_FCOL_OFF)^
					wlv.tocol = (^C.int)(uintptr(wp) + W_OLD_CURSOR_LCOL_OFF)^
				}
			} else {
				// Non-block mode.
				if lnum > top.lnum && lnum <= bot.lnum {
					wlv.fromcol = 0
				} else if lnum == top.lnum {
					if VIsual_mode == 'V' { // linewise
						wlv.fromcol = 0
					} else {
						getvvcol_r(wp, top, &wlv.fromcol, nil, nil, 0)
						if gchar_pos_r(top) == 0 { // NUL
							wlv.tocol = wlv.fromcol + 1
						}
					}
				}
				if VIsual_mode != 'V' && lnum == bot.lnum {
					if p_sel^ == 'e' && bot.col == 0 && bot.coladd == 0 {
						wlv.fromcol = -10
						wlv.tocol = MAXCOL
					} else if bot.col == MAXCOL {
						wlv.tocol = MAXCOL
					} else {
						pos := bot^
						if p_sel^ == 'e' {
							getvvcol_r(wp, &pos, &wlv.tocol, nil, nil, 0)
						} else {
							getvvcol_r(wp, &pos, nil, nil, &wlv.tocol, 0)
							wlv.tocol += 1
						}
					}
				}
			}

			// Invert (highlight) the char under the cursor.
			if !highlight_match_g && in_curline &&
				cursor_is_block_during_visual_r(p_sel^ == 'e') {
				noinvcur = true
			}

			// Inverting in this line sets area_highlighting.
			if wlv.fromcol >= 0 {
				area_highlighting = true
				vi_attr = win_hl_attr_o(wp, HLF_V_O)
			}
			// Handle 'incsearch' and ":s///c" highlighting.
		} else if highlight_match_g && wp == cur &&
			!has_foldtext && lnum >= (^C.int)(uintptr(cur) + W_CURSOR_OFF)^ &&
			lnum <= (^C.int)(uintptr(cur) + W_CURSOR_OFF)^ + search_match_lines_g {
			if lnum == (^C.int)(uintptr(cur) + W_CURSOR_OFF)^ {
				getvvcol_r(cur, (^Pos_T)(uintptr(cur) + W_CURSOR_OFF), &wlv.fromcol, nil, nil, 0)
			} else {
				wlv.fromcol = 0
			}
			if lnum == (^C.int)(uintptr(cur) + W_CURSOR_OFF)^ + search_match_lines_g {
				pos := Pos_T{lnum = lnum, col = search_match_endcol_g}
				getvvcol_r(cur, &pos, &wlv.tocol, nil, nil, 0)
			}
			// At least one character; happens past end of line.
			if wlv.fromcol == wlv.tocol && search_match_endcol_g != 0 {
				wlv.tocol = wlv.fromcol + 1
			}
			area_highlighting = true
			vi_attr = win_hl_attr_o(wp, HLF_I_O)
		}
	}

	bg_attr := win_bg_attr_r(wp)

	linestatus: C.int = 0
	wlv.filler_lines = diff_check_with_linestatus_r(wp, lnum, &linestatus)
	line_changes := Diffline_O{}
	change_index: C.int = -1
	if linestatus < 0 {
		if linestatus == -1 {
			if diff_find_change_r(wp, lnum, &line_changes) {
				wlv.diff_hlf = HLF_ADD_O // added line
			} else if line_changes.num_changes > 0 {
				added := diff_change_parse_r(&line_changes,
					([^]rawptr)(line_changes.changes)[0],
					&change_start, &change_end)
				if change_start == 0 {
					if added {
						wlv.diff_hlf = HLF_TXA_O // added text on changed line
					} else {
						wlv.diff_hlf = HLF_TXD_O // changed text on changed line
					}
				} else {
					wlv.diff_hlf = HLF_CHD_O // unchanged text on changed line
				}
				change_index = 0
			} else {
				wlv.diff_hlf = HLF_CHD_O // changed line
				change_index = 0
			}
		} else {
			wlv.diff_hlf = HLF_ADD_O // added line
		}
		area_highlighting = true
	}
	virt_lines := Kvec_VT{} // KV_INITIAL_VALUE
	wlv.n_virt_lines = decor_virt_lines_r(wp, lnum - 1, lnum, &wlv.n_virt_below, &virt_lines, true)
	// Preserve virt_lines count for topline visibility.
	total_virt_rows := wlv.n_virt_lines
	wlv.filler_lines += wlv.n_virt_lines
	if lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		wlv.virt_below_skip = min(wlv.n_virt_below,
			wlv.n_virt_lines - (^C.int)(uintptr(wp) + W_TOPFILL_OFF)^)
		wlv.n_virt_below -= wlv.virt_below_skip
		wlv.filler_lines_skip = wlv.filler_lines - wlv.virt_below_skip -
			(^C.int)(uintptr(wp) + W_TOPFILL_OFF)^
		wlv.n_virt_lines = min(wlv.n_virt_lines, wlv.filler_lines)
	}
	wlv.filler_todo = wlv.filler_lines

	// Cursor line highlighting for 'cursorline' in the current window.
	if (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 &&
		(^C.uint)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ != kOptCuloptFlagNumber_S &&
		lnum == (^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ &&
		// No cursor line in text with Visual active (selection unclear).
		!(wp == cur && VIsual_active) {
		cul_screenline = (is_wrapped &&
			((^C.uint)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ & kOptCuloptFlagScreenline_S) != 0)
		if !cul_screenline {
			apply_cursorline_highlight_o(wp, &wlv)
		} else {
			margin_columns_win_o(wp, &left_curline_col, &right_curline_col)
		}
		area_highlighting = true
	}

	sign_line_attr: C.int = 0
	// TODO(bfredl, vigoux): line_attr should not take priority over decoration!
	decor_redraw_signs_r(wp, buf, wlv.lnum - 1, transmute(rawptr)(&wlv.sattrs[0]),
		&sign_line_attr, &wlv.sign_cul_attr, &wlv.sign_num_attr)

	statuscol := Statuscol_O{}
	if (([^]u8)((^rawptr)(uintptr(wp) + W_P_STC_OFF)^))[0] != 0 { // NUL
		// Draw the 'statuscolumn'.
		statuscol.draw = true
		statuscol.sattrs = transmute(rawptr)(&wlv.sattrs[0])
		statuscol.lnum = lnum
		statuscol.foldinfo = foldinfo
		statuscol.width = win_col_off_r(wp)
		if use_cursor_line_highlight(wp, lnum) {
			statuscol.sign_cul_id = wlv.sign_cul_attr
		} else {
			statuscol.sign_cul_id = 0
		}
	} else if wlv.sign_cul_attr > 0 {
		if use_cursor_line_highlight(wp, lnum) {
			wlv.sign_cul_attr = syn_id2attr_r(wlv.sign_cul_attr)
		} else {
			wlv.sign_cul_attr = 0
		}
	}
	if wlv.sign_num_attr > 0 {
		wlv.sign_num_attr = syn_id2attr_r(wlv.sign_num_attr)
	}
	if sign_line_attr > 0 {
		wlv.line_attr = syn_id2attr_r(sign_line_attr)
	}

	// Highlight the current line in the quickfix window.
	if bt_quickfix((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) &&
		qf_current_entry_r(wp) == lnum {
		wlv.line_attr = win_hl_attr_o(wp, HLF_QFL_O)
	}

	if wlv.line_attr_lowprio != 0 || wlv.line_attr != 0 {
		area_highlighting = true
	}

	line_attr_save := wlv.line_attr
	line_attr_lowprio_save := wlv.line_attr_lowprio

	if spv.spv_has_spell && col_rows == 0 && draw_text {
		// Prepare for spell checking.
		extra_check = true

		// Word wrapped from previous line: current line start is valid.
		if lnum == spv.spv_checked_lnum {
			cur_checked_col = spv.spv_checked_col
		}
		// Previous line unchecked, check for capital (first line of an
		// updated region or after a closed fold).
		if spv.spv_capcol_lnum == 0 && check_need_cap(wp, lnum, 0) {
			spv.spv_cap_col = 0
		} else if lnum != spv.spv_capcol_lnum {
			spv.spv_cap_col = -1
		}
		spv.spv_checked_lnum = 0

		// Start of the next line, for words wrapping to it: "et<break>al.".
		// Trick: skip a few chars for C/shell/Vim comments.
		nextline[SPWORDLEN_O] = 0 // NUL
		if lnum < (^C.int)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_ML_LINE_COUNT_OFF)^ {
			line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum + 1)
			spell_cat_line((^u8)(&nextline[SPWORDLEN_O]), line, SPWORDLEN_O)
		}
		line := ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)

		// Empty current line: check first word in next line for capital.
		ptr := skipwhite(cstring(line))
		ptrb := ([^]u8)(ptr)
		if ptrb[0] == 0 { // NUL
			spv.spv_cap_col = 0
			spv.spv_capcol_lnum = lnum + 1
		} else if spv.spv_cap_col == 0 {
			// First word with a capital: skip white space.
			spv.spv_cap_col = C.int(uintptr(rawptr(ptr)) - uintptr(line))
		}

		// Copy the end of the current line into nextline[].
		if nextline[SPWORDLEN_O] == 0 { // NUL
			// No next line or it is empty.
			nextlinecol = MAXCOL
			nextline_idx = 0
		} else {
			line_len := ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
			if line_len < SPWORDLEN_O {
				// Short line: use it fully, append next-line start.
				nextlinecol = 0
				libc.memmove(&nextline[0], line, C.size_t(line_len))
				// STRMOVE(nextline+line_len, nextline+SPWORDLEN)
				libc.memmove((^u8)(uintptr(&nextline[0]) + uintptr(line_len)),
					&nextline[SPWORDLEN_O],
					C.size_t(libc.strlen(cstring(&nextline[SPWORDLEN_O]))) + 1)
				nextline_idx = line_len + 1
			} else {
				// Long line: last SPWORDLEN bytes only.
				nextlinecol = line_len - SPWORDLEN_O
				libc.memmove(&nextline[0],
					(^u8)(uintptr(line) + uintptr(nextlinecol)), SPWORDLEN_O)
				nextline_idx = SPWORDLEN_O + 1
			}
		}
	}
		_ = decor_provider_end_col
		_ = check_decor_providers
		_ = view_height
		_ = grid
		_ = vcol_prev
		_ = saved_attr2
		_ = n_attr3
		_ = saved_attr3
		_ = fromcol_prev
		_ = noinvcur
		_ = lnum_in_visual_area
		_ = char_attr_pri
		_ = char_attr_base
		_ = vcol_save_attr
		_ = decor_attr
		_ = has_syntax
		_ = folded_attr
		_ = eol_hl_off
		_ = nextlinecol
		_ = nextline_idx
		_ = spell_attr
		_ = word_end
		_ = cur_checked_col
		_ = extra_check
		_ = multi_attr
		_ = mb_l
		_ = mb_c
		_ = mb_schar
		_ = change_end
		_ = in_multispace
		_ = multispace_pos
		_ = n_extra_next
		_ = extra_attr_next
		_ = search_attr_from_match
		_ = has_decor
		_ = saved_search_attr
		_ = saved_area_attr
		_ = saved_decor_attr
		_ = saved_search_attr_from_match
		_ = win_col_offset
		_ = area_active
		_ = decor_need_recheck
		_ = buf_fold
		_ = fold_vt
		_ = foldtext_free
		_ = cul_screenline
		_ = left_curline_col
		_ = right_curline_col
		_ = match_conc
		_ = on_last_col
		_ = syntax_flags
		_ = syntax_seqnr
		_ = prev_syntax_id
		_ = conceal_attr
		_ = is_concealing
		_ = did_wcol
		_ = line_attr_save
		_ = line_attr_lowprio_save
		_ = draw_text
		_ = in_curline
		_ = has_fold
		_ = has_foldtext
		_ = is_wrapped
		_ = vi_attr
		_ = area_attr
		_ = search_attr
		_ = bg_attr
		_ = change_index
		_ = line_changes
		_ = area_highlighting
		_ = statuscol
	// CHUNK-12b1: trailcol/leadcol/listchars + skip-to-display.
	// Current line + position (C:1492-1494, after spell prep).
	line: ^u8
	if draw_text {
		line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
	} else {
		line = transmute(^u8)(cstring(""))
	}
	ptr := line
	trailcol: C.int = MAXCOL // start of trailing spaces
	leadcol: C.int = 0 // start of leading spaces

	lcs_eol_todo := true // track even if lcs_eol is NUL
	lcs_eol := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + 0)^ // 'eol'
	lcs_prec_todo := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + 8)^ // 'prec'

	if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && !has_foldtext && draw_text {
		if (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_SPACE_OFF)^ != 0 ||
			(^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_MULTISPACE_OFF)^ != nil ||
			(^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADMULTISPACE_OFF)^ != nil ||
			(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TRAIL_OFF)^ != 0 ||
			(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEAD_OFF)^ != 0 ||
			(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_NBSP_OFF)^ != 0 {
			extra_check = true
		}
		// Start of trailing whitespace.
		if (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TRAIL_OFF)^ != 0 {
			trailcol = ml_get_buf_len((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
			for trailcol > 0 && ascii_iswhite(([^]u8)(ptr)[trailcol - 1]) {
				trailcol -= 1
			}
			trailcol += C.int(uintptr(ptr) - uintptr(line))
		}
		// End of leading whitespace.
		if (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEAD_OFF)^ != 0 ||
			(^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADMULTISPACE_OFF)^ != nil ||
			(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADTAB1_OFF)^ != 0 {
			leadcol = 0
			for ascii_iswhite(([^]u8)(ptr)[leadcol]) {
				leadcol += 1
			}
			if ([^]u8)(ptr)[leadcol] == 0 { // NUL
				// All-spaces line counts as trailing.
				leadcol = 0
			} else {
				// First non-space column.
				leadcol += C.int(uintptr(ptr) - uintptr(line) + 1)
			}
		}
	}

	// 'nowrap' or wrapped-but-unfitting line: first displayed character.
	start_vcol: C.int
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
		if startrow == 0 {
			start_vcol = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
		} else {
			start_vcol = 0
		}
	} else {
		start_vcol = w_leftcol_r(wp)
	}

	if has_foldtext {
		wlv.vcol = start_vcol
	} else if start_vcol > 0 && col_rows == 0 {
		prev_ptr := ptr
		cs := CharSize_O{}
		csarg := CharsizeArg_O{}
		cstype := init_charsize_arg_r(&csarg, wp, lnum, line)
		csarg.max_head_vcol = start_vcol
		vcol := wlv.vcol
		ci := utf_ptr2StrCharInfo_o(ptr)
		for vcol < start_vcol {
			cs = win_charsize_o(cstype, vcol, ci.ptr, ci.chr.value, &csarg)
			vcol += cs.width
			prev_ptr = ci.ptr
			if ([^]u8)(prev_ptr)[0] == 0 { // NUL
				break
			}
			ci = utfc_next_o(ci)
			if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 {
				prev_space := ([^]u8)(prev_ptr)[0] == ' '
				next_space := ([^]u8)(ci.ptr)[0] == ' '
				prev_is_space := false
				if uintptr(prev_ptr) > uintptr(line) {
					prev_is_space = ([^]u8)(uintptr(prev_ptr) - 1)[0] == ' '
				}
				in_multispace = prev_space && (next_space || prev_is_space)
				if !in_multispace {
					multispace_pos = 0
				} else if uintptr(ci.ptr) >= uintptr(line) + uintptr(leadcol) &&
					(^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_MULTISPACE_OFF)^ != nil {
					multispace_pos += 1
					if (([^]u8)((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_MULTISPACE_OFF)^))[multispace_pos] == 0 {
						multispace_pos = 0
					}
				} else if uintptr(ci.ptr) < uintptr(line) + uintptr(leadcol) &&
					(^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADMULTISPACE_OFF)^ != nil {
					multispace_pos += 1
					if (([^]u8)((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADMULTISPACE_OFF)^))[multispace_pos] == 0 {
						multispace_pos = 0
					}
				}
			}
		}
		wlv.vcol = vcol
		ptr = ci.ptr
		charsize := cs.width
		head := cs.head

		// End of line before displayed part ('cuc'/'colorcolumn'/
		// 'virtualedit'/Visual/fold may need it).
		if wlv.vcol < start_vcol && ((^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 ||
			wlv.color_cols != nil || virtual_active_r(wp) ||
			(VIsual_active && (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^ == (^rawptr)(uintptr(cur) + W_BUFFER_OFF)^) ||
			has_fold) {
			wlv.vcol = start_vcol
		}

		// Character straddling the screen edge: back up, skip head cells.
		if wlv.vcol > start_vcol {
			wlv.vcol -= charsize
			ptr = prev_ptr
		}

		if start_vcol > wlv.vcol {
			wlv.skip_cells = start_vcol - wlv.vcol - head
		}

		// Inverted text before the screen.
		if wlv.tocol <= wlv.vcol {
			wlv.fromcol = 0
		} else if wlv.fromcol >= 0 && wlv.fromcol < wlv.vcol {
			wlv.fromcol = wlv.vcol
		}

		// Non-zero w_skipcol: first line needs 'showbreak'.
		if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
			wlv.need_showbreak = true
		}
			// Spell check from word start at the skipped region.
		if spv.spv_has_spell {
			linecol := C.int(uintptr(ptr) - uintptr(line))
			spell_hlf: C.int = HLF_COUNT_O

			pos := (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
			(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ = lnum
			(^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ = linecol
			slen := spell_move_to(wp, FORWARD_O, SMT_ALL_O, true, &spell_hlf)

			// spell_move_to() may ml_get() and invalidate "line".
			line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
			ptr = (^u8)(uintptr(line) + uintptr(linecol))

			if slen == 0 || (^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ > linecol {
				// No bad word at line start: wait for word end.
				spell_hlf = HLF_COUNT_O
				word_end = C.int(uintptr(spell_to_word_end(ptr, wp)) - uintptr(line) + 1)
			} else {
				// Bad word: attributes until word end.
				if slen > 2147483647 {
					libc.abort()
				}
				word_end = (^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ + C.int(slen) + 1

				// Index into actual attributes.
				if spell_hlf != HLF_COUNT_O {
					spell_attr = highlight_attr_g[spell_hlf]
				}
			}
			(^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^ = pos

			// Restart syntax highlighting for this line.
			if has_syntax {
				syntax_start_r(wp, lnum)
			}
		}
	}
	// CHUNK-12b2: decor providers, cursor invert, search-hl, loop prelude.
	if check_decor_providers {
		col := C.int(uintptr(ptr) - uintptr(line))
		decor_provider_end_col = decor_providers_setup_o(endrow - startrow,
			start_vcol == 0, lnum, col, wp)
		line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
		ptr = (^u8)(uintptr(line) + uintptr(col))
	}

	decor_redraw_line_r(wp, lnum - 1, transmute(rawptr)(&decor_state_g))
	if !has_decor && decor_has_more_decorations_r(transmute(rawptr)(&decor_state_g), lnum - 1) {
		has_decor = true
		extra_check = true
	}

	// Highlighting for a cursor that can't be disabled (per-char checks off).
	if wlv.fromcol >= 0 {
		if noinvcur {
			if wlv.fromcol == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
				// Highlight starts at cursor: start just after it.
				fromcol_prev = wlv.fromcol
				wlv.fromcol = -1
			} else if wlv.fromcol < (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
				// Restart highlighting after the cursor.
				fromcol_prev = (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
			}
		}
		if wlv.fromcol >= wlv.tocol {
			wlv.fromcol = -1
		}
	}

	if col_rows == 0 && draw_text && !has_foldtext {
		v := C.int(uintptr(ptr) - uintptr(line))
		if prepare_search_hl_line_r(wp, lnum, v, &line,
			transmute(rawptr)(&screen_search_hl_u8), &search_attr,
			&search_attr_from_match) {
			area_highlighting = true
		}
		ptr = (^u8)(uintptr(line) + uintptr(v)) // "line" may move
	}

	if (State & MODE_INSERT) != 0 && ins_compl_win_active_r(wp) &&
		(in_curline || ins_compl_lnum_in_range_r(lnum)) {
		area_highlighting = true
	}

	win_line_start_o(wp, &wlv)
	draw_cols := true
	leftcols_width: C.int = 0

	// No highlight after TERM_ATTRS_MAX columns.
	term_attrs: [TERM_ATTRS_MAX_O]C.int = {}
	if (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil {
		terminal_get_line_attributes_r(
			(^(^rawptr))(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^,
			wp, lnum, &term_attrs[0])
		extra_check = true
	}

	may_have_inline_virt := !has_foldtext &&
		buf_meta_total_o((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, K_MTMETA_INLINE_O) > 0
	has_virt_line := false
	virt_line_flags: C.int = 0
	// virt_lines index + starting row (persist to skip visited rows).
	virt_line_index: C.int = 0
	virt_line_start_row: C.int = 0
	virt_line_skip_cells: C.int = 0
	// CHUNK-12c1: main while loop — filler/virt-lines, columns, row commit.
	for {
		has_match_conc: C.int = 0 // match wants to conceal
		decor_conceal: C.int = 0

		did_decrement_ptr := false
		_ = did_decrement_ptr

		// Extmark highlights if the approximation fell short.
		if check_decor_providers && C.int(uintptr(ptr) - uintptr(line)) >= decor_provider_end_col {
			col := C.int(uintptr(ptr) - uintptr(line))
			decor_provider_end_col = invoke_range_next_o(wp, lnum, col, 100)
			line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
			ptr = (^u8)(uintptr(line) + uintptr(col))
			if !has_decor && decor_has_more_decorations_r(transmute(rawptr)(&decor_state_g), lnum - 1) {
				has_decor = true
				extra_check = true
			}
		}

		// Skip quickly when working on the text.
		if draw_cols {
			if cul_screenline {
				wlv.cul_attr = 0
				wlv.line_attr = line_attr_save
				wlv.line_attr_lowprio = line_attr_lowprio_save
			}

			if wlv.off != 0 {
				libc.abort()
			}

			if wlv.filler_todo > 0 {
				// nvim_buf_set_extmark: virt_lines_overflow
				virt_rows_todo := wlv.filler_todo - (wlv.filler_lines - wlv.n_virt_lines)
				if virt_rows_todo > 0 {
					target_row := total_virt_rows - virt_rows_todo
					// Rows spanned by the virtual line holding target_row.
					// NOTE: items are virt_line (32B), not VirtTextChunk.
					vls := transmute([^]VirtLine_O)(virt_lines.items)
					for virt_line_index < C.int(virt_lines.n) {
						line_rows := decor_virt_line_rows_r(wp,
							transmute(rawptr)(&vls[virt_line_index]), 0, nil)
						if target_row < virt_line_start_row + line_rows {
							has_virt_line = true
							virt_line_flags = vls[virt_line_index].flags
							decor_virt_line_rows_r(wp,
								transmute(rawptr)(&vls[virt_line_index]),
								target_row - virt_line_start_row,
								&virt_line_skip_cells)
							break
						}
						virt_line_start_row += line_rows
						virt_line_index += 1
					}
				}
			}
			if has_virt_line && (virt_line_flags & K_VL_LEFTCOL_O) != 0 {
				// Skip columns.
			} else if statuscol.draw {
				// Draw 'statuscolumn'.
				v := C.int(uintptr(ptr) - uintptr(line))
				draw_statuscol_o(wp, &wlv, col_rows, &statuscol)
				if (^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ {
					break
				}
				if draw_text {
					// Evaluating 'statuscolumn' may free the line.
					line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
					ptr = (^u8)(uintptr(line) + uintptr(v))
				}
			} else {
				// Builtin info columns: fold, sign, number.
				draw_foldcolumn_o(wp, &wlv)

				// w_scwidth is zero when signcol=number is used.
				for sign_idx: C.int = 0; sign_idx < (^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^; sign_idx += 1 {
					draw_sign_o(false, wp, &wlv, sign_idx)
				}

				draw_lnum_col_o(wp, &wlv)
			}

			win_col_offset = wlv.off

			// Only updating the columns: stop here when done.
			if col_rows > 0 {
				wlv_put_linebuf_o(wp, &wlv, min(wlv.off, view_width), false, bg_attr, 0)
				// More screen lines needed when:
				// - 'statuscolumn' needs drawing, or
				// - LineNrAbove/Below is used, or
				// - still drawing filler lines.
				if (wlv.row + 1 - wlv.startrow < col_rows &&
					(statuscol.draw ||
						win_hl_attr_o(wp, HLF_LNA_O) != win_hl_attr_o(wp, HLF_N_O) ||
						win_hl_attr_o(wp, HLF_LNB_O) != win_hl_attr_o(wp, HLF_N_O))) ||
					wlv.filler_todo > 0 {
					wlv.row += 1
					if wlv.row == endrow {
						break
					}
					wlv.filler_todo -= 1
					has_virt_line = false
					if wlv.filler_todo == 0 &&
						((^bool)(uintptr(wp) + W_BOTFILL_OFF)^ || !draw_text) {
						break
					}
					// win_line_start(wp, &wlv);
					wlv.col = 0
					wlv.off = 0
					continue
				} else {
					break
				}
			}

			// 'breakindent' applies: show it.
			if (^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ == false {
				handle_breakindent_o(wp, &wlv)
			}
			handle_showbreak_and_filler_o(wp, &wlv)
			if (^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ {
				handle_breakindent_o(wp, &wlv)
			}

			wlv.col = wlv.off
			draw_cols = false
			if wlv.filler_todo <= 0 {
				leftcols_width = wlv.off
			}
			if has_decor && wlv.row == startrow + wlv.filler_lines {
				// Hide virt_text on text hidden by 'nowrap'/'smoothscroll'.
				decor_redraw_col_o(wp, C.int(uintptr(ptr) - uintptr(line)) - 1,
					wlv.off, true, &decor_state_g, decor_provider_end_col - 1)
			}
			if wlv.col >= view_width {
				wlv.col = view_width
				wlv.off = view_width
				break // -> end_check (CHUNK-12e)
			}
		}

		// CHUNK-12c3: cursorline-row, change-display, folded setup, per-char attrs.
		if cul_screenline && wlv.filler_todo <= 0 &&
			wlv.vcol >= left_curline_col && wlv.vcol < right_curline_col {
			apply_cursorline_highlight_o(wp, &wlv)
		}

		// Displaying '$' of a change command: stop at the cursor.
		if dollar_vcol >= 0 && in_curline && wlv.vcol >= (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
			draw_virt_text_o(wp, buf, win_col_offset, &wlv.col, wlv.row)
			// Don't clear anything after wlv.col.
			wlv_put_linebuf_o(wp, &wlv, wlv.col, false, bg_attr, 0)
			// Pretend the window is done, except with 'cursorcolumn'.
			if (^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 {
				wlv.row = (^C.int)(uintptr(wp) + W_CLINE_ROW_OFF)^ +
					(^C.int)(uintptr(wp) + W_CLINE_HEIGHT_OFF)^
			} else {
				wlv.row = view_height
			}
			break
		}

		draw_folded := has_fold && wlv.row == startrow + wlv.filler_lines
		if draw_folded && wlv.n_extra == 0 {
			wlv.char_attr = win_hl_attr_o(wp, HLF_FL_O)
			folded_attr = wlv.char_attr
			decor_attr = 0
		}

		extmark_attr: C.int = 0
		if wlv.filler_todo <= 0 &&
			(area_highlighting || spv.spv_has_spell || extra_check) {
			if wlv.n_extra == 0 || !wlv.extra_for_extmark {
				wlv.reset_extra_attr = false
			}

			if has_decor && wlv.n_extra == 0 {
				// Duplicate the Visual check after this block (not in p_extra).
				if wlv.vcol == wlv.fromcol ||
					(wlv.vcol + 1 == wlv.fromcol &&
						(wlv.n_extra == 0 && utf_ptr2cells_r(cstring(ptr)) > 1)) ||
					(vcol_prev == fromcol_prev && vcol_prev < wlv.vcol &&
						wlv.vcol < wlv.tocol) {
					area_active = true
				} else if area_active &&
					(wlv.vcol == wlv.tocol ||
						(noinvcur && wlv.vcol == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^)) {
					area_active = false
				}

				selected := (area_active || (area_highlighting && noinvcur &&
					wlv.vcol == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^))
				// Inline virt-text positions resolve after lower-priority
				// inline draws.
				if decor_need_recheck {
					if !may_have_inline_virt {
						decor_recheck_draw_col_r(wlv.off, selected,
							transmute(rawptr)(&decor_state_g))
					}
					decor_need_recheck = false
				}
				extmark_attr = decor_redraw_col_o(wp, C.int(uintptr(ptr) - uintptr(line)),
					may_have_inline_virt ? -3 : wlv.off,
					selected, &decor_state_g, decor_provider_end_col - 1)
				if may_have_inline_virt {
					handle_inline_virtual_text_o(wp, &wlv, C.ptrdiff_t(uintptr(ptr) - uintptr(line)), selected)
					if wlv.n_extra > 0 && wlv.virt_inline_hl_mode <= .Replace {
						// Restore search/area attrs at n_extra zero.
						// TODO(bfredl): ugly as fuck, find another way.
						saved_search_attr = search_attr
						saved_area_attr = area_attr
						saved_decor_attr = decor_attr
						saved_search_attr_from_match = search_attr_from_match
						search_attr = 0
						area_attr = 0
						decor_attr = 0
						search_attr_from_match = false
					}
				}
			}

			area_attr_p: ^C.int
			if wlv.extra_for_extmark && wlv.virt_inline_hl_mode <= .Replace {
				area_attr_p = &saved_area_attr
			} else {
				area_attr_p = &area_attr
			}

			// Visual/match highlighting in this line.
			if wlv.vcol == wlv.fromcol ||
				(wlv.vcol + 1 == wlv.fromcol &&
					((wlv.n_extra == 0 && utf_ptr2cells_r(cstring(ptr)) > 1) ||
						(wlv.n_extra > 0 && wlv.p_extra != nil &&
							utf_ptr2cells_r(cstring(wlv.p_extra)) > 1))) ||
				(vcol_prev == fromcol_prev && vcol_prev < wlv.vcol &&
					wlv.vcol < wlv.tocol) {
				area_attr_p^ = vi_attr // start highlighting
				area_active = true
			} else if area_attr_p^ != 0 &&
				(wlv.vcol == wlv.tocol ||
					(noinvcur && wlv.vcol == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^)) {
				area_attr_p^ = 0 // stop highlighting
				area_active = false
			}

			if !has_foldtext && wlv.n_extra == 0 {
				// 'hlsearch'/match start-end (re-check after each end).
				v := C.int(uintptr(ptr) - uintptr(line))
				search_attr = update_search_hl_r(wp, lnum, v, &line,
					transmute(rawptr)(&screen_search_hl_u8),
					&has_match_conc, &match_conc, lcs_eol_todo,
					&on_last_col, &search_attr_from_match)
				ptr = (^u8)(uintptr(line) + uintptr(v)) // line may move

				// No conceal over EOL or EOL is missed, with bad results.
				if ([^]u8)(ptr)[0] == 0 { // NUL
					has_match_conc = 0
				}

				// ComplMatchIns highlight needed?
				if (State & MODE_INSERT) != 0 && ins_compl_win_active_r(wp) &&
					(in_curline || ins_compl_lnum_in_range_r(lnum)) {
					ins_match_attr := ins_compl_col_range_attr_r(lnum,
						C.int(uintptr(ptr) - uintptr(line)))
					if ins_match_attr > 0 {
						search_attr = hl_combine_attr_r(search_attr, ins_match_attr)
					}
				}
			}

			if wlv.diff_hlf != 0 {
				if line_changes.num_changes > 0 && change_index >= 0 &&
					change_index < line_changes.num_changes - 1 {
					dc := transmute([^]DiffChange_O)(line_changes.changes)
					if C.int(uintptr(ptr) - uintptr(line)) >=
						dc[change_index + 1].dc_start[line_changes.bufidx] {
						change_index += 1
					}
				}
				added := false
				if line_changes.num_changes > 0 && change_index >= 0 &&
					change_index < line_changes.num_changes {
					dc := transmute([^]DiffChange_O)(line_changes.changes)
					added = diff_change_parse_r(&line_changes, transmute(rawptr)(&dc[change_index]),
						&change_start, &change_end)
				}
				// Extra text (eg virtual text) gets line diff HL, not text HL.
				if wlv.diff_hlf == HLF_CHD_O &&
					C.int(uintptr(ptr) - uintptr(line)) >= change_start &&
					wlv.n_extra == 0 {
					if added {
						wlv.diff_hlf = HLF_TXA_O // added text
					} else {
						wlv.diff_hlf = HLF_TXD_O // changed text
					}
				}
				if (wlv.diff_hlf == HLF_TXD_O || wlv.diff_hlf == HLF_TXA_O) &&
					((C.int(uintptr(ptr) - uintptr(line)) >= change_end && wlv.n_extra == 0) ||
						(wlv.n_extra > 0 && wlv.extra_for_extmark)) {
					wlv.diff_hlf = HLF_CHD_O // changed line
				}
				set_line_attr_for_diff_o(wp, &wlv)
			}

			// Which highlight attributes to use.
			if area_attr != 0 {
				char_attr_pri = hl_combine_attr_r(wlv.line_attr, area_attr)
				if !highlight_match_g {
					// Search HL shows in Visual area if possible.
					char_attr_pri = hl_combine_attr_r(search_attr, char_attr_pri)
				}
			} else if search_attr != 0 {
				char_attr_pri = hl_combine_attr_r(wlv.line_attr, search_attr)
			} else if wlv.line_attr != 0 &&
				((wlv.fromcol == -10 && wlv.tocol == MAXCOL) ||
					wlv.vcol < wlv.fromcol || vcol_prev < fromcol_prev ||
					wlv.vcol >= wlv.tocol) {
				// wlv.line_attr outside Visual/incsearch area
				// (area_attr may be 0 with "noinvcur").
				char_attr_pri = wlv.line_attr
			} else {
				char_attr_pri = 0
			}
			char_attr_base = hl_combine_attr_r(folded_attr, decor_attr)
			wlv.char_attr = hl_combine_attr_r(char_attr_base, char_attr_pri)
		}
		// X // closes filler/attr if-REMOVED

			if draw_folded && has_foldtext && wlv.n_extra == 0 && wlv.col == win_col_offset {
				v := C.int(uintptr(ptr) - uintptr(line))
				lnume := lnum + foldinfo.fi_lines - 1
				libc.memset(&buf_fold[0], ' ', FOLD_TEXT_LEN_O)
				wlv.p_extra = get_foldtext(wp, lnum, lnume, transmute(Foldinfo_T)(foldinfo),
					&buf_fold[0], &fold_vt)
				wlv.n_extra = C.int(libc.strlen(cstring(wlv.p_extra)))

				if uintptr(wlv.p_extra) != uintptr(&buf_fold[0]) {
					if foldtext_free != nil {
						libc.abort()
					}
					foldtext_free = wlv.p_extra
				}
				wlv.sc_extra = 0 // NUL
				wlv.sc_final = 0 // NUL
				([^]u8)(wlv.p_extra)[wlv.n_extra] = 0 // NUL

				// Evaluating 'foldtext' may free the line.
				line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
				ptr = (^u8)(uintptr(line) + uintptr(v))
			}

			// 'fold' fillchar after 'foldtext' (or eol listchar if transparent).
			if draw_folded && wlv.n_extra == 0 && wlv.col < view_width &&
				(has_foldtext || (([^]u8)(ptr)[0] == 0 &&
					((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 || !lcs_eol_todo ||
						lcs_eol == 0))) {
				// Fill rest of line with 'fold'.
				wlv.sc_extra = (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLD_OFF)^
				wlv.sc_final = 0 // NUL
				wlv.n_extra = view_width - wlv.col
				// No search HL past the first filler char.
				search_attr = 0
			}

			if draw_folded && wlv.n_extra != 0 && wlv.col >= view_width {
				// Truncate the folding.
				wlv.n_extra = 0
			}

			// Next character for the screen (p_extra = inserted specials;
			// sc_extra when all chars equal; sc_final forced at the end).
			if wlv.n_extra > 0 {
				if wlv.sc_extra != 0 || (wlv.n_extra == 1 && wlv.sc_final != 0) {
					if wlv.n_extra == 1 && wlv.sc_final != 0 {
						mb_schar = wlv.sc_final
					} else {
						mb_schar = wlv.sc_extra
					}
					mb_c = schar_get_first_codepoint(mb_schar)
					wlv.n_extra -= 1
				} else {
					if wlv.p_extra == nil {
						libc.abort()
					}
					mb_l = utfc_ptr2len(cstring(wlv.p_extra))
					mb_schar = utfc_ptr2schar_r(cstring(wlv.p_extra), &mb_c)
					// mb_l=0 at end-of-line NUL
					if mb_l > wlv.n_extra || mb_l == 0 {
						mb_l = 1
					}

					// Double-width char not fitting: '>' in last column,
					// char goes to next line (pointer NOT advanced).
					if wlv.col >= view_width - 1 && schar_cells(mb_schar) == 2 {
						mb_c = '>'
						mb_l = 1
						mb_schar = u32(mb_c) // schar_from_ascii
						multi_attr = win_hl_attr_o(wp, HLF_AT_O)

						if wlv.cul_attr != 0 {
							if wlv.line_attr_lowprio != 0 {
								multi_attr = hl_combine_attr_r(wlv.cul_attr, multi_attr)
							} else {
								multi_attr = hl_combine_attr_r(multi_attr, wlv.cul_attr)
							}
						}
					} else {
						wlv.n_extra -= mb_l
						wlv.p_extra = (^u8)(uintptr(wlv.p_extra) + uintptr(mb_l))
					}

					// Double-width char not fitting left: '<' first column
					// (not for unprintables).
					if wlv.filler_todo <= 0 && wlv.skip_cells > 0 && mb_l > 1 {
						if wlv.n_extra > 0 {
							n_extra_next = wlv.n_extra
							extra_attr_next = wlv.extra_attr
						}
						wlv.n_extra = 1
						wlv.sc_extra = u32(MB_FILLER_CHAR_O)
						wlv.sc_final = 0 // NUL
						mb_schar = 32 // ' '
						mb_c = ' '
						mb_l = 1
						wlv.n_attr += 1
						wlv.extra_attr = win_hl_attr_o(wp, HLF_AT_O)
					}
				}

				if wlv.n_extra <= 0 {
					// Restore search/area attrs when n_extra runs out.
					if n_extra_next <= 0 {
						if search_attr == 0 {
							search_attr = saved_search_attr
							saved_search_attr = 0
						}
						if area_attr == 0 && ([^]u8)(ptr)[0] != 0 { // NUL
							area_attr = saved_area_attr
							saved_area_attr = 0
						}
						if decor_attr == 0 {
							decor_attr = saved_decor_attr
							saved_decor_attr = 0
						}
						if wlv.extra_for_extmark {
							// wlv.extra_attr applies here, not further.
							wlv.reset_extra_attr = true
							extra_attr_next = -1
						}
						wlv.extra_for_extmark = false
					} else {
						if wlv.sc_extra == 0 && wlv.sc_final == 0 {
							libc.abort()
						}
						if wlv.p_extra == nil {
							libc.abort()
						}
						wlv.sc_extra = 0 // NUL
						wlv.sc_final = 0 // NUL
						wlv.n_extra = n_extra_next
						n_extra_next = 0
						// wlv.extra_attr applies here, extra_attr_next after.
						wlv.reset_extra_attr = true
						if extra_attr_next < 0 {
							libc.abort()
						}
					}
				}
			} else if wlv.filler_todo > 0 {
				// Filler lines first: wait with text, init these.
				mb_c = ' '
				mb_schar = 32 // schar_from_ascii(' ')
			} else if has_foldtext || (has_fold && wlv.col >= view_width) {
				// Skip the buffer line itself.
				mb_schar = 0 // NUL
			} else {
				prev_ptr := ptr

				// First byte of next char.
				c0 := C.int(([^]u8)(ptr)[0])
				if c0 == 0 { // NUL
					// No more cells to skip.
					wlv.skip_cells = 0
				}

				// Character from the line itself.
				mb_l = utfc_ptr2len(cstring(ptr))
				mb_schar = utfc_ptr2schar_r(cstring(ptr), &mb_c)

				// Overlong ASCII / ASCII with composing char (not NUL): normal.
				if mb_l > 1 && mb_c < 0x80 {
					c0 = mb_c
				}

				if (mb_l == 1 && c0 >= 0x80) || (mb_l >= 1 && mb_c == 0) ||
					(mb_l > 1 && !vim_isprintc(mb_c)) {
					// Illegal UTF-8 / non-printable: <xx> or fullwidth ?.
					transchar_hex_r((^u8)(&wlv.extra[0]), mb_c)
					if (^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 { // reverse
						rl_mirror_ascii_r((^u8)(&wlv.extra[0]), nil)
					}

					wlv.p_extra = (^u8)(&wlv.extra[0])
					mb_c = mb_ptr2char_adv(&wlv.p_extra)
					mb_schar = schar_from_char(mb_c)
					wlv.n_extra = C.int(libc.strlen(cstring(wlv.p_extra)))
					wlv.sc_extra = 0 // NUL
					wlv.sc_final = 0 // NUL
					if area_attr == 0 && search_attr == 0 {
						wlv.n_attr = wlv.n_extra + 1
						wlv.extra_attr = win_hl_attr_o(wp, HLF_8_O)
						saved_attr2 = wlv.char_attr // save current attr
					}
				} else if mb_l == 0 { // NUL at end-of-line
					mb_l = 1
				}
				// Double-width char not fitting: '>' in last column,
				// char moves to next line.
				if wlv.col >= view_width - 1 && schar_cells(mb_schar) == 2 {
					mb_schar = u32('>') // schar_from_ascii
					mb_c = '>'
					mb_l = 1
					multi_attr = win_hl_attr_o(wp, HLF_AT_O)
					// Pointer back: char shows at next line start.
					ptr = (^u8)(uintptr(ptr) - 1)
					did_decrement_ptr = true
				} else if ([^]u8)(ptr)[0] != 0 { // NUL
					ptr = (^u8)(uintptr(ptr) + uintptr(mb_l) - 1)
				}

				// Double-width char not fitting left: '<' first column
				// (not for unprintables).
				if wlv.skip_cells > 0 && mb_l > 1 && wlv.n_extra == 0 {
					wlv.n_extra = 1
					wlv.sc_extra = u32(MB_FILLER_CHAR_O)
					wlv.sc_final = 0 // NUL
					mb_schar = 32 // ' '
					mb_c = ' '
					mb_l = 1
					if area_attr == 0 && search_attr == 0 {
						wlv.n_attr = wlv.n_extra + 1
						wlv.extra_attr = win_hl_attr_o(wp, HLF_AT_O)
						saved_attr2 = wlv.char_attr // save current attr
					}
				}
			// NOTE: final else stays open (closes at C:2743 end-of-print).

			// CHUNK-12c6: syntax + spell attributes for this char.
			ptr = (^u8)(uintptr(ptr) + 1)

			decor_attr = 0
			if extra_check {
				ws := (^rawptr)(uintptr(wp) + W_S_OFF)^
				no_plain_buffer := ((^i64)(uintptr(ws) + SYN_SPO_FLAGS_OFF)^ & K_OPT_SPO_NOPLAINBUFFER_O) != 0
				can_spell := !no_plain_buffer

				// Syntax/extmark attributes (not at line start when a
				// double-wide char didn't fit).
				v := C.int(uintptr(ptr) - uintptr(line))
				prev_v := C.int(uintptr(prev_ptr) - uintptr(line))
				if has_syntax && v > 0 {
					// Character syntax attribute; on error disable it.
					save_did_emsg := did_emsg_g()
					did_emsg_set(false)

					decor_attr = get_syntax_attr_r(v - 1,
						spv.spv_has_spell ? &can_spell : nil, false)

					if did_emsg_g() != 0 {
						(^bool)(uintptr(ws) + W_SYN_ERROR_OFF)^ = true
						has_syntax = false
					} else {
						did_emsg_set(save_did_emsg != 0)
					}

					if (^bool)(uintptr(ws) + W_SYN_SLOW_OFF)^ {
						has_syntax = false
					}

					// Multi-line regexp may invalidate the line.
					line = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
					ptr = (^u8)(uintptr(line) + uintptr(v))
					prev_ptr = (^u8)(uintptr(line) + uintptr(prev_v))

					// No concealing past EOL (breaks line highlighting).
					if mb_schar == 0 {
						syntax_flags = 0
					} else {
						syntax_flags = get_syntax_info_r(&syntax_seqnr)
					}
				}

				if has_decor && v > 0 {
					// Extmarks beat syntax.c.
					decor_attr = hl_combine_attr_r(decor_attr, extmark_attr)
					decor_conceal = (^C.int)(uintptr(transmute(rawptr)(&decor_state_g)) + 308)^
					can_spell = tristate_to_bool_o(
						(^C.int)(uintptr(transmute(rawptr)(&decor_state_g)) + 320)^, can_spell)
				}

				char_attr_base = hl_combine_attr_r(folded_attr, decor_attr)
				wlv.char_attr = hl_combine_attr_r(char_attr_base, char_attr_pri)

				// Spell check (not at EOL; needs no-syntax or @Spell).
				v1 := C.int(uintptr(ptr) - uintptr(line))
				if spv.spv_has_spell && v1 >= word_end && v1 > cur_checked_col {
					spell_attr = 0
					// No cap_col at EOL or with only whitespace after.
					if mb_schar != 0 && (([^]u8)(skipwhite(cstring(prev_ptr))))[0] != 0 && can_spell {
						p: ^u8
						spell_hlf: C.int = HLF_COUNT_O
						v1 -= mb_l - 1

						// nextline[] has the next-line start concatenated.
						if (C.int(uintptr(prev_ptr) - uintptr(line)) - nextlinecol) >= 0 {
							p = (^u8)(uintptr(&nextline[0]) +
								uintptr(C.int(uintptr(prev_ptr) - uintptr(line)) - nextlinecol))
						} else {
							p = prev_ptr
						}
						spv.spv_cap_col -= C.int(uintptr(prev_ptr) - uintptr(line))
						tmplen := spell_check_r(wp, p, &spell_hlf, &spv.spv_cap_col, spv.spv_unchanged)
						if tmplen > 2147483647 {
							libc.abort()
						}
						slen := C.int(tmplen)
						word_end = v1 + slen

						// Insert mode: only HL a word not touching the cursor.
						if spell_hlf != HLF_COUNT_O &&
							(State & MODE_INSERT) != 0 &&
							(^C.int)(uintptr(wp) + W_CURSOR_OFF)^ == lnum &&
							(^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ >= C.int(uintptr(prev_ptr) - uintptr(line)) &&
							(^C.int)(uintptr(wp) + W_CURSOR_OFF + 4)^ < word_end {
							spell_hlf = HLF_COUNT_O
							spell_redraw_lnum_g = lnum
						}

						if spell_hlf == HLF_COUNT_O && uintptr(p) != uintptr(prev_ptr) &&
							(C.int(uintptr(p) - uintptr(&nextline[0])) + slen) > nextline_idx {
							// Good word continues on the next line.
							spv.spv_checked_lnum = lnum + 1
							spv.spv_checked_col = C.int(uintptr(p) - uintptr(&nextline[0])) + slen - nextline_idx
						}

						// Index into actual attributes.
						if spell_hlf != HLF_COUNT_O {
							spell_attr = highlight_attr_g[spell_hlf]
						}

						if spv.spv_cap_col > 0 {
							if uintptr(p) != uintptr(prev_ptr) &&
								(C.int(uintptr(p) - uintptr(&nextline[0])) + spv.spv_cap_col) >= nextline_idx {
								// Next line must start with a capital.
								spv.spv_capcol_lnum = lnum + 1
								spv.spv_cap_col = C.int(uintptr(p) - uintptr(&nextline[0])) + spv.spv_cap_col - nextline_idx
							} else {
								// Actual column.
								spv.spv_cap_col += C.int(uintptr(prev_ptr) - uintptr(line))
							}
						}
					}
				}
				if spell_attr != 0 {
					char_attr_base = hl_combine_attr_r(char_attr_base, spell_attr)
					wlv.char_attr = hl_combine_attr_r(char_attr_base, char_attr_pri)
				}

				if (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil {
					if wlv.vcol < TERM_ATTRS_MAX_O {
						wlv.char_attr = hl_combine_attr_r(term_attrs[wlv.vcol], wlv.char_attr)
					} else {
						wlv.char_attr = hl_combine_attr_r(0, wlv.char_attr)
					}
				}
			}
			// TEMP-12c7: content goes here (inside else, inside for).
			// CHUNK-12c7: linebreak handling (inside extra_check).
			// No linebreak for leading-space long-letter starts (would
			// break at the line start unexpectedly). Allow linebreak once
			// non-'breakat' chars are found.
			if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 && !wlv.need_lbr &&
				mb_schar != 0 && !vim_isbreak_o(C.int(([^]u8)(ptr)[0])) {
				wlv.need_lbr = true
			}
			// Last space before word: check for line break.
			if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 && c0 == mb_c &&
				mb_c < 128 && wlv.need_lbr && vim_isbreak_o(mb_c) &&
				!vim_isbreak_o(C.int(([^]u8)(ptr)[0])) {
				mb_off := utf_head_off_r(line, (^u8)(uintptr(ptr) - 1))
				p := (^u8)(uintptr(ptr) - (uintptr(mb_off) + 1))

				csarg := CharsizeArg_O{}
				// lnum == 0: no virtual text counted here.
				cstype := init_charsize_arg_r(&csarg, wp, 0, line)
				// TODO(zeertzjq): consider using CharSize.tail here.
				wlv.n_extra = win_charsize_o(cstype, wlv.vcol, p,
					utf_ptr2CharInfo_o(p).value, &csarg).width - 1

				if on_last_col && mb_c != '\t' {
					// No search/match HL over the line break (TABs keep
					// the full character width).
					search_attr = 0
				}

				if mb_c == '\t' && wlv.n_extra + wlv.col > view_width {
					buf := (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
					wlv.n_extra = tabstop_padding_r(wlv.vcol,
						(^i64)(uintptr(buf) + B_P_TS_OFF)^,
						transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^)) - 1
				}
				if mb_off > 0 {
					wlv.sc_extra = u32(MB_FILLER_CHAR_O)
				} else {
					wlv.sc_extra = 32 // ' '
				}
				wlv.sc_final = 0 // NUL
				if mb_c < 128 && ascii_iswhite(u8(mb_c)) {
					if mb_c == '\t' {
						// See "Tab alignment" below.
						fix_for_boguscols_o(&wlv)
					}
					if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 {
						mb_c = ' '
						mb_schar = u32(mb_c) // schar_from_ascii
					}
				}
			}
			} // REAL closes if-extra_check (C:2487)

			// CHUNK-12c8: non-printable characters (inside else).
			// Handling of non-printable characters.
			if !vim_isprintc(mb_c) {
				// File character may become something else on screen.
				if mb_c == '\t' &&
					((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 ||
						(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^ != 0) {
					tab_len: C.int = 0
					vcol_adjusted := wlv.vcol // minus showbreak length
					lcs_tab1 := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^
					lcs_tab2 := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB2_OFF)^
					lcs_tab3 := (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB3_OFF)^
					// leadtab overrides when before leadcol.
					if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
						(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADTAB1_OFF2)^ != 0 &&
						uintptr(ptr) < uintptr(line) + uintptr(leadcol) {
						lcs_tab1 = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADTAB1_OFF2)^
						lcs_tab2 = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADTAB2_OFF)^
						lcs_tab3 = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_LEADTAB3_OFF)^
					}
					sbr := get_showbreak_value(wp)

					// Adjust tab_len at the first column after showbreak.
					if sbr^ != 0 && wlv.vcol == wlv.vcol_sbr &&
						(^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
						vcol_adjusted = wlv.vcol - mb_charlen_r(cstring(sbr))
					}
					// Tab amount depends on current column.
					tab_len = tabstop_padding_r(vcol_adjusted,
						(^i64)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_P_TS_OFF)^,
						transmute(^C.int)((^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_P_VTS_ARR_OFF)^)) - 1

					if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ == 0 ||
						(^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 {
						wlv.n_extra = tab_len
					} else {
						saved_nextra := wlv.n_extra

						if wlv.vcol_off_co > 0 {
							// Characters to conceal.
							tab_len += wlv.vcol_off_co
						}
						// boguscols before fix_for_boguscols() above.
						if lcs_tab1 != 0 && wlv.old_boguscols > 0 && wlv.n_extra > tab_len {
							tab_len += wlv.n_extra - tab_len
						}

						if tab_len > 0 {
							// n_extra>0: chars for a tab, else calc width.
							tab2_len := C.size_t(schar_len(lcs_tab2))
							slen := C.size_t(tab_len) * tab2_len
							if lcs_tab3 != 0 {
								slen += C.size_t(schar_len(lcs_tab3)) - tab2_len
							}
							if wlv.n_extra > 0 {
								slen += C.size_t(wlv.n_extra - tab_len)
							}
							mb_schar = lcs_tab1
							mb_c = schar_get_first_codepoint(mb_schar)
							p := get_extra_buf_o(slen + 1)
							libc.memset(p, ' ', slen)
							([^]u8)(p)[slen] = 0 // NUL
							wlv.p_extra = p
							for i: C.int = 0; i < tab_len; i += 1 {
								if ([^]u8)(p)[0] == 0 { // NUL
									tab_len = i
									break
								}
								lcs := lcs_tab2

								// tab3 for the last char.
								if lcs_tab3 != 0 && i == tab_len - 1 {
									lcs = lcs_tab3
								}
								slen2 := schar_get_adv(&p, lcs)
								wlv.n_extra += C.int(slen2) - (saved_nextra > 0 ? 1 : 0)
								// NOTE: C advances p via schar_get_adv; p_extra
								// stays at the buffer start (set above).
							}
							// n_extra adjusted by fix_for_boguscols() below.
							if wlv.vcol_off_co > 0 {
								wlv.n_extra -= wlv.vcol_off_co
							}
						}
					}

					{
						vc_saved := wlv.vcol_off_co

						// Tab alignment identical regardless of
						// 'conceallevel': tab compensates concealed chars,
						// resetting vcol_off_co and boguscols so far.
						// (Tab may exceed 'tabstop' with concealed chars.)
						fix_for_boguscols_o(&wlv)

						// Highlighting for the tab set below (reverts the
						// fix_for_boguscols() call).
						if wlv.n_extra == tab_len + vc_saved &&
							(^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
							(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_TAB1_OFF)^ != 0 {
							tab_len += vc_saved
						}
					}

					if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 {
						if wlv.n_extra == 0 && lcs_tab3 != 0 {
							mb_schar = lcs_tab3
						} else {
							mb_schar = lcs_tab1
						}
						if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 &&
							wlv.p_extra != nil && ([^]u8)(wlv.p_extra)[0] != 0 { // NUL
							wlv.sc_extra = 0 // NUL (p_extra from above)
						} else {
							wlv.sc_extra = lcs_tab2
						}
						wlv.sc_final = lcs_tab3
						wlv.n_attr = tab_len + 1
						wlv.extra_attr = win_hl_attr_o(wp, HLF_0_O)
						saved_attr2 = wlv.char_attr // save current attr
					} else {
						wlv.sc_final = 0 // NUL
						wlv.sc_extra = 32 // ' '
						mb_schar = 32 // ' '
					}
					mb_c = schar_get_first_codepoint(mb_schar)
				} else if mb_schar == 0 &&
					((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 ||
						((wlv.fromcol >= 0 || fromcol_prev >= 0) &&
							wlv.tocol > wlv.vcol && VIsual_mode != Ctrl_V &&
							wlv.col < view_width &&
							!(noinvcur && lnum == (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ &&
								wlv.vcol == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^))) &&
					lcs_eol_todo && lcs_eol != 0 {
					// '$' after the line / extra char with line break.
					// Diff lines keep highlighting after "$".
					if wlv.diff_hlf == 0 && wlv.line_attr == 0 &&
						wlv.line_attr_lowprio == 0 {
						// Virtualedit visual selections may pass EOL.
						if !(area_highlighting && virtual_active_r(wp) &&
							wlv.tocol != MAXCOL && wlv.vcol < wlv.tocol) {
							wlv.p_extra = transmute(^u8)(cstring(""))
						}
						wlv.n_extra = 0
					}
					if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
						(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_EOL_OFF)^ > 0 {
						mb_schar = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_EOL_OFF)^
					} else {
						mb_schar = 32 // ' '
					}
					lcs_eol_todo = false
					ptr = (^u8)(uintptr(ptr) - 1) // back at the NUL
					wlv.extra_attr = win_hl_attr_o(wp, HLF_AT_O)
					wlv.n_attr = 1
					mb_c = schar_get_first_codepoint(mb_schar)
				} else if mb_schar != 0 {
					wlv.p_extra = transchar_buf_r((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, mb_c)
					if wlv.n_extra == 0 {
						wlv.n_extra = byte2cells_r(mb_c) - 1
					}
					if (dy_flags_g & K_OPT_DY_UHEX_O) != 0 &&
						(^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 {
						rl_mirror_ascii_r(wlv.p_extra, nil) // reverse "<12>"
					}
					wlv.sc_extra = 0 // NUL
					wlv.sc_final = 0 // NUL
					if (^C.int)(uintptr(wp) + W_P_LBR_OFF)^ != 0 {
						mb_c = C.int(([^]u8)(wlv.p_extra)[0])
						p := get_extra_buf_o(C.size_t(wlv.n_extra) + 1)
						libc.memset(p, ' ', C.size_t(wlv.n_extra))
						libc.memcpy(p, (^u8)(uintptr(wlv.p_extra) + 1),
							libc.strlen(cstring(wlv.p_extra)) - 1)
						([^]u8)(p)[wlv.n_extra] = 0 // NUL
						wlv.p_extra = p
					} else {
						wlv.n_extra = byte2cells_r(mb_c) - 1
						mb_c = C.int(([^]u8)(wlv.p_extra)[0])
						wlv.p_extra = (^u8)(uintptr(wlv.p_extra) + 1)
					}
					wlv.n_attr = wlv.n_extra + 1
					wlv.extra_attr = win_hl_attr_o(wp, HLF_8_O)
					saved_attr2 = wlv.char_attr // save current attr
					mb_schar = u32(mb_c) // schar_from_ascii
				} else if VIsual_active &&
					(VIsual_mode == Ctrl_V || VIsual_mode == 'v') &&
					virtual_active_r(wp) && wlv.tocol != MAXCOL &&
					wlv.vcol < wlv.tocol && wlv.col < view_width {
					mb_c = ' '
					mb_schar = schar_from_char(mb_c)
					ptr = (^u8)(uintptr(ptr) - 1) // back at the NUL
				}

			// CHUNK-12c9: conceal handling (inside else; closes it).
			if (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ > 0 &&
				(wp != curwin || lnum != (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ ||
					conceal_cursor_line(wp)) &&
				((syntax_flags & HL_CONCEAL_O) != 0 || has_match_conc > 0 ||
					decor_conceal > 0) &&
				!(lnum_in_visual_area &&
					vim_strchr_c(transmute(^u8)((^rawptr)(uintptr(wp) + W_P_COCU_OFF)^), 'v') == nil) {
				syntax_conceal := (syntax_flags & HL_CONCEAL_O) != 0
				wlv.char_attr = conceal_attr
				if ((prev_syntax_id != syntax_seqnr && syntax_conceal) ||
					has_match_conc > 1 || decor_conceal > 1) &&
					((syntax_conceal && syn_get_sub_char_r() != 0) ||
						(has_match_conc != 0 && match_conc != 0) ||
						(decor_conceal != 0 && decor_state_g.conceal_char != 0) ||
						(^C.int)(uintptr(wp) + W_P_COLE_OFF)^ == 1) &&
					(^C.int)(uintptr(wp) + W_P_COLE_OFF)^ != 3 {
					if schar_cells(mb_schar) > 1 {
						// Concealed double-width: one more virtual column.
						wlv.n_extra += 1
					}

					// First concealed item: display one character.
					if has_match_conc != 0 && match_conc != 0 {
						mb_schar = schar_from_char(match_conc)
					} else if decor_conceal != 0 && decor_state_g.conceal_char != 0 {
						mb_schar = decor_state_g.conceal_char
						if decor_state_g.conceal_attr != 0 {
							wlv.char_attr = decor_state_g.conceal_attr
						}
					} else if syntax_conceal && syn_get_sub_char_r() != 0 { // NUL
						mb_schar = schar_from_char(syn_get_sub_char_r())
					} else if (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_CONCEAL_OFF)^ != 0 {
						mb_schar = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_CONCEAL_OFF)^
					} else {
						mb_schar = 32 // ' '
					}

					mb_c = schar_get_first_codepoint(mb_schar)

					prev_syntax_id = syntax_seqnr

					if wlv.n_extra > 0 {
						wlv.vcol_off_co += wlv.n_extra
					}
					wlv.vcol += wlv.n_extra
					if is_wrapped && wlv.n_extra > 0 {
						wlv.boguscols += wlv.n_extra
						wlv.col += wlv.n_extra
					}
					wlv.n_extra = 0
					wlv.n_attr = 0
				} else if wlv.skip_cells == 0 {
					is_concealing = true
					wlv.skip_cells = 1
				}
			} else {
				prev_syntax_id = 0
				is_concealing = false
			}

			if wlv.skip_cells > 0 && did_decrement_ptr {
				// No '>' shown: pointer back to avoid getting stuck.
				ptr = (^u8)(uintptr(ptr) + 1)
			}
			} // REAL closes final else (C:2743)

			// CHUNK-12d1: cursor wcol, extra_attr apply, precedes, EOL hl.
			// Cursor line with concealing: fix cursor column at its spot.
			// (Virtualedit may never reach it; fix at end of line.)
			if !did_wcol && wlv.filler_todo <= 0 && in_curline &&
				conceal_cursor_line(wp) &&
				(wlv.vcol + wlv.skip_cells >= (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ ||
					mb_schar == 0) {
				(^C.int)(uintptr(wp) + W_WCOL_OFF)^ = wlv.col - wlv.boguscols
				// Concealed screen cells before the cursor on this line
				// (skip_cells = concealed cell at cursor, uncounted).
				(^C.int)(uintptr(wp) + W_WCOL_CONCEAL_OFF)^ =
					wlv.vcol_off_co + wlv.skip_cells
				if wlv.vcol + wlv.skip_cells < (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ {
					// Cursor past EOL with 'virtualedit'.
					(^C.int)(uintptr(wp) + W_WCOL_OFF)^ +=
						(^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ - wlv.vcol - wlv.skip_cells
				}
				(^C.int)(uintptr(wp) + W_WROW_OFF)^ = wlv.row
				did_wcol = true
				(^C.int)(uintptr(wp) + W_VALID_OFF)^ |= VALID_WCOL_O | VALID_WROW_O | VALID_VIRTCOL_O
			}

			// wlv.extra_attr, not over visual selection.
			if wlv.n_attr > 0 && !search_attr_from_match {
				wlv.char_attr = hl_combine_attr_r(wlv.char_attr, wlv.extra_attr)
				if wlv.reset_extra_attr {
					wlv.reset_extra_attr = false
					if extra_attr_next >= 0 {
						wlv.extra_attr = extra_attr_next
						extra_attr_next = -1
					} else {
						wlv.extra_attr = 0
						// search_attr_from_match restores with extra_attr.
						search_attr_from_match = saved_search_attr_from_match
					}
				}
			}

			// Column 0 but past the first char: 'listchars' precedes.
			prec_ok := false
			if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
				prec_ok = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && wlv.row == 0
			} else {
				prec_ok = w_leftcol_r(wp) > 0
			}
			if lcs_prec_todo != 0 && (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
				prec_ok && wlv.filler_todo <= 0 && wlv.skip_cells <= 0 &&
				mb_schar != 0 {
				lcs_prec_todo = 0 // NUL
				if schar_cells(mb_schar) > 1 {
					// Double-width overwritten by precedes: fill half.
					wlv.sc_extra = 62 // MB_FILLER_CHAR '>'
					wlv.sc_final = 0 // NUL
					if wlv.n_extra > 0 {
						if wlv.p_extra == nil {
							libc.abort()
						}
						n_extra_next = wlv.n_extra
						extra_attr_next = wlv.extra_attr
						wlv.n_attr = max(wlv.n_attr + 1, 2)
					} else {
						wlv.n_attr = 2
					}
					wlv.n_extra = 1
					wlv.extra_attr = win_hl_attr_o(wp, HLF_AT_O)
				}
				mb_schar = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_PREC_OFF)^
				lcs_prec_todo = 0 // NUL
				mb_c = schar_get_first_codepoint(mb_schar)
				saved_attr3 = wlv.char_attr // save current attr
				wlv.char_attr = win_hl_attr_o(wp, HLF_AT_O) // overwriting
				n_attr3 = 1
			}

			// At/past end of the text line.
			if mb_schar == 0 && eol_hl_off == 0 {
				// Whether prevcol starts search_hl or a match.
				prevcol_hl_flag := get_prevcol_hl_flag_r(wp,
					transmute(rawptr)(&screen_search_hl_u8),
					C.int(uintptr(ptr) - uintptr(line)) - 1)

				// Invert at least one char (Visual/empty line/match at
				// EOL; past the last screen char overwrite it — tricky!
				// Not needed when '$' showed for 'list').
				if lcs_eol_todo &&
					((area_attr != 0 && wlv.vcol == wlv.fromcol &&
						(VIsual_mode != Ctrl_V || lnum == VIsual_g.lnum ||
							lnum == (^C.int)(uintptr(cur) + W_CURSOR_OFF)^)) ||
						prevcol_hl_flag) {
					n: C.int = 0

					if wlv.col >= view_width {
						n = -1
					}
					if n != 0 {
						// Window boundary: HL the last char instead.
						wlv.off += n
						wlv.col += n
					} else {
						// Blank character to highlight.
						linebuf_char_g[wlv.off] = 32 // ' '
					}
					if area_attr == 0 && !has_fold {
						// Highest-priority 'search_hl'/match attributes.
						get_search_match_hl_r(wp,
							transmute(rawptr)(&screen_search_hl_u8),
							C.int(uintptr(ptr) - uintptr(line)), &wlv.char_attr)
					}

					eol_attr := wlv.char_attr
					if wlv.cul_attr != 0 {
						eol_attr = hl_combine_attr_r(wlv.cul_attr, wlv.char_attr)
					}

					linebuf_attr_g[wlv.off] = eol_attr
					linebuf_vcol_g[wlv.off] = wlv.vcol
					wlv.col += 1
					wlv.off += 1
					wlv.vcol += 1
					eol_hl_off = 1
				}
			}
			// CHUNK-12d2: end-of-line fill, cursorcolumn, emit, advance.
			// At end of the text line.
			if mb_schar == 0 {
				// Highlight 'cursorcolumn'/'colorcolumn' past EOL.

				// Line ends before left margin.
				wlv.vcol = max(wlv.vcol, start_vcol + wlv.col - win_col_off_r(wp))
				// Boguscols done: draw to the right edge for 'cursorcolumn'.
				wlv.col -= wlv.boguscols
				wlv.boguscols = 0

				advance_color_col_o(&wlv, wlv.vcol - wlv.vcol_off_co)

				// Same alignment with/without listchars=eol:X.
				eol_skip: C.int = 0
				if lcs_eol_todo && eol_hl_off == 0 {
					eol_skip = 1
				}

				if has_decor {
					decor_redraw_eol_r(wp, transmute(rawptr)(&decor_state_g),
						&wlv.line_attr, wlv.col + eol_skip)
				}

				for i := wlv.col; i < view_width; i += 1 {
					linebuf_vcol_g[wlv.off + (i - wlv.col)] = wlv.vcol + (i - wlv.col)
				}

				if ((^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 &&
					(^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ >= wlv.vcol - wlv.vcol_off_co - eol_hl_off &&
					(^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ < view_width * C.int(uintptr(wlv.row - startrow + 1)) + start_vcol &&
					lnum != (^C.int)(uintptr(wp) + W_CURSOR_OFF)^) ||
					wlv.color_cols != nil || wlv.line_attr_lowprio != 0 ||
					wlv.line_attr != 0 || wlv.diff_hlf != 0 ||
					(^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil {
					rightmost_vcol := get_rightmost_vcol_o(wp, wlv.color_cols)
					cuc_attr := win_hl_attr_o(wp, HLF_CUC_O)
					mc_attr := win_hl_attr_o(wp, HLF_MC_O)

					if wlv.diff_hlf == HLF_TXD_O || wlv.diff_hlf == HLF_TXA_O {
						wlv.diff_hlf = HLF_CHD_O
						set_line_attr_for_diff_o(wp, &wlv)
					}

					diff_attr := C.int(0)
					if wlv.diff_hlf != 0 {
						diff_attr = win_hl_attr_o(wp, wlv.diff_hlf)
					}

					base_attr := hl_combine_attr_r(wlv.line_attr_lowprio, diff_attr)
					if base_attr != 0 || wlv.line_attr != 0 ||
						(^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil {
						rightmost_vcol = 2147483647 // INT_MAX
					}

					for wlv.col < view_width {
						linebuf_char_g[wlv.off] = 32 // ' '

						advance_color_col_o(&wlv, wlv.vcol - wlv.vcol_off_co)

						col_attr := base_attr
						if (^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 &&
							wlv.vcol - wlv.vcol_off_co == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ &&
							lnum != (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
							col_attr = hl_combine_attr_r(col_attr, cuc_attr)
						} else if wlv.color_cols != nil &&
							wlv.vcol - wlv.vcol_off_co == wlv.color_cols[0] {
							col_attr = hl_combine_attr_r(col_attr, mc_attr)
						}

						if (^rawptr)(uintptr((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) + B_TERMINAL_OFF)^ != nil &&
							wlv.vcol < TERM_ATTRS_MAX_O {
							col_attr = hl_combine_attr_r(col_attr, term_attrs[wlv.vcol])
						}

						col_attr = hl_combine_attr_r(col_attr, wlv.line_attr)

						linebuf_attr_g[wlv.off] = col_attr
						// linebuf_vcol[] filled by the for loop above.
						wlv.off += 1
						wlv.col += 1
						wlv.vcol += 1

						if wlv.vcol - wlv.vcol_off_co > rightmost_vcol {
							break
						}
					}
				}

			if fold_vt.n > 0 {
				draw_virt_text_item_o(buf, win_col_offset, fold_vt, .Combine, view_width, 0, 0)
			}
			draw_virt_text_o(wp, buf, win_col_offset, &wlv.col, wlv.row)
			// Increasing virtual columns for curswant/coladd on click past EOL.
			wlv_put_linebuf_o(wp, &wlv, wlv.col, true, bg_attr, SLF_INC_VCOL_O)
			wlv.row += 1

			// Cursor line updated: save w_cline_* (saves plines_win() later).
			if in_curline {
				(^C.int)(uintptr(cur) + W_CLINE_ROW_OFF)^ = startrow
				(^C.int)(uintptr(cur) + W_CLINE_HEIGHT_OFF)^ = wlv.row - startrow
				(^bool)(uintptr(cur) + W_CLINE_FOLDED_OFF)^ = has_fold
				(^C.int)(uintptr(cur) + W_VALID_OFF)^ |= VALID_CHEIGHT_O | VALID_CROW_O
			}

			break
		}

			// CHUNK-12d3: extends char, cursorcolumn highlight, lowprio combine.
			// Show "extends" from 'listchars' past the line end.
			lcs_ext := get_lcs_ext_o(wp)
			if lcs_ext != 0 && wlv.filler_todo <= 0 && wlv.col == view_width - 1 &&
				!has_foldtext {
				if has_decor && ([^]u8)(ptr)[0] == 0 && lcs_eol == 0 && lcs_eol_todo {
					// Virtual text just after the last char.
					decor_redraw_col_o(wp, C.int(uintptr(ptr) - uintptr(line)), -1,
						false, &decor_state_g, decor_provider_end_col - 1)
				}
				if ([^]u8)(ptr)[0] != 0 ||
					(lcs_eol > 0 && lcs_eol_todo) ||
					(wlv.n_extra > 0 && (wlv.sc_extra != 0 || ([^]u8)(wlv.p_extra)[0] != 0)) ||
					(may_have_inline_virt && has_more_inline_virt_o(&wlv, C.ptrdiff_t(uintptr(ptr) - uintptr(line)))) {
					mb_schar = lcs_ext
					wlv.char_attr = win_hl_attr_o(wp, HLF_AT_O)
					mb_c = schar_get_first_codepoint(mb_schar)
				}
			}

			advance_color_col_o(&wlv, wlv.vcol - wlv.vcol_off_co)

			// Cursorcolumn highlight (not on the cursor itself).
			// 'colorcolumn' too, when different from 'cursorcolumn'.
			vcol_save_attr = -1
			if !lnum_in_visual_area && search_attr == 0 && area_attr == 0 &&
				wlv.filler_todo <= 0 {
				if (^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 &&
					wlv.vcol - wlv.vcol_off_co == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ &&
					lnum != (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
					vcol_save_attr = wlv.char_attr
					wlv.char_attr = hl_combine_attr_r(win_hl_attr_o(wp, HLF_CUC_O), wlv.char_attr)
				} else if wlv.color_cols != nil &&
					wlv.vcol - wlv.vcol_off_co == wlv.color_cols[0] {
					vcol_save_attr = wlv.char_attr
					wlv.char_attr = hl_combine_attr_r(win_hl_attr_o(wp, HLF_MC_O), wlv.char_attr)
				}
			}

			if wlv.filler_todo <= 0 {
				// Lowest-priority line attr first, everything overrides it.
				low := wlv.line_attr_lowprio
				high := wlv.char_attr

				if wlv.line_attr_lowprio != 0 {
					line_ae := syn_attr2entry_r(wlv.line_attr_lowprio)
					char_ae := syn_attr2entry_r(wlv.char_attr)
					win_normal_bg := normal_bg_g
					win_normal_cterm_bg := C.int(cterm_normal_bg_color_g)

					// Window-local Normal background ('winhighlight').
					if bg_attr != 0 {
						norm_ae := syn_attr2entry_r(bg_attr)
						win_normal_bg = norm_ae.rgb_bg_color
						win_normal_cterm_bg = C.int(norm_ae.cterm_bg_color)
					}
					char_is_normal_bg := false
					if ui_rgb_attached_r() {
						char_is_normal_bg = char_ae.rgb_bg_color == win_normal_bg
					} else {
						char_is_normal_bg = C.int(char_ae.cterm_bg_color) == win_normal_cterm_bg
					}

					// CursorLine background over Normal's: reverse the order.
					if (line_ae.rgb_bg_color >= 0 || line_ae.cterm_bg_color > 0) && char_is_normal_bg {
						low = wlv.char_attr
						high = wlv.line_attr_lowprio
					}
				}
				wlv.char_attr = hl_combine_attr_r(low, high)
			}

			// CHUNK-12d4: store char, skip/wrap advance, decor peek.
			if wlv.filler_todo <= 0 {
				vcol_prev = wlv.vcol
			}

			// Store character to be displayed.
			// Skip characters left of the screen for 'nowrap'.
			if wlv.filler_todo > 0 {
				// TODO(bfredl): main render loop should handle virtual
				// lines chunks too (wrapping and other Nice Things).
			} else if wlv.skip_cells <= 0 {
				// Store the character.
				linebuf_char_g[wlv.off] = mb_schar
				if multi_attr != 0 {
					linebuf_attr_g[wlv.off] = multi_attr
					multi_attr = 0
				} else {
					linebuf_attr_g[wlv.off] = wlv.char_attr
				}

				linebuf_vcol_g[wlv.off] = wlv.vcol

				if schar_cells(mb_schar) > 1 {
					// Two screen columns needed.
					wlv.off += 1
					wlv.col += 1
					// UTF-8: 0 in the second screen char.
					linebuf_char_g[wlv.off] = 0
					linebuf_attr_g[wlv.off] = linebuf_attr_g[wlv.off - 1]

					linebuf_vcol_g[wlv.off] = wlv.vcol + 1
					wlv.vcol += 1

					// "wlv.tocol" halfway through a char: move to char
					// end or highlighting won't stop.
					if wlv.tocol == wlv.vcol {
						wlv.tocol += 1
					}
				}
				wlv.off += 1
				wlv.col += 1
			} else if (^C.int)(uintptr(wp) + W_P_COLE_OFF)^ > 0 && is_concealing {
				concealed_wide := schar_cells(mb_schar) > 1

				wlv.skip_cells -= 1
				wlv.vcol_off_co += 1
				if concealed_wide {
					// Concealed double-width: one more virtual column.
					wlv.vcol += 1
					wlv.vcol_off_co += 1
				}

				if wlv.n_extra > 0 {
					wlv.vcol_off_co += wlv.n_extra
				}

				if is_wrapped {
					// 'wrap' voodoo: advance the column so the line
					// wraps early (same screen space with concealed
					// parts, keeping cursor computations right).
					// boguscols tracks bad columns against trailing junk.
					if wlv.n_extra > 0 {
						wlv.vcol += wlv.n_extra
						wlv.col += wlv.n_extra
						wlv.boguscols += wlv.n_extra
						wlv.n_extra = 0
						wlv.n_attr = 0
					}

					if concealed_wide {
						// Two screen columns needed.
						wlv.boguscols += 1
						wlv.col += 1
					}

					wlv.boguscols += 1
					wlv.col += 1
				} else {
					if wlv.n_extra > 0 {
						wlv.vcol += wlv.n_extra
						wlv.n_extra = 0
						wlv.n_attr = 0
					}
				}
			} else {
				wlv.skip_cells -= 1
			}

			// Skipped cells count toward vcol.
			if wlv.skipped_cells > 0 {
				wlv.vcol += wlv.skipped_cells
				wlv.skipped_cells = 0
			}

			// "wlv.vcol" advances past the number/relativenumber column.
			if wlv.filler_todo <= 0 {
				wlv.vcol += 1
			}

			if vcol_save_attr >= 0 {
				wlv.char_attr = vcol_save_attr
			}

			// Restore attributes after "precedes" in 'listchars'.
			if n_attr3 > 0 {
				n_attr3 -= 1
				if n_attr3 == 0 {
					wlv.char_attr = saved_attr3
				}
			}

			// Restore attributes after last 'listchars'/'number' char.
			if wlv.n_attr > 0 {
				wlv.n_attr -= 1
				if wlv.n_attr == 0 {
					wlv.char_attr = saved_attr2
				}
			}

			if has_decor && wlv.filler_todo <= 0 && wlv.col >= view_width {
				// End of screen line: peek for decorations just after.
				if is_wrapped && wlv.n_extra == 0 {
					decor_redraw_col_o(wp, C.int(uintptr(ptr) - uintptr(line)), -3,
						false, &decor_state_g, decor_provider_end_col - 1)
					// Recheck virtual text positions on next screen line.
					decor_need_recheck = true
				} else if !is_wrapped {
					// No wrapping: right_align/win_col virt_text for the
					// whole text line may still need display.
					decor_recheck_draw_col_r(-1, true, transmute(rawptr)(&decor_state_g))
					decor_redraw_col_o(wp, MAXCOL, -1, true, &decor_state_g,
						decor_provider_end_col - 1)
				}
			}
			// CHUNK-12d5: end_check + row advance + return.
			// end_check: end of screen line with more to come: show it.
			// (No more to display is caught above.)
			if wlv.col >= view_width &&
				(!has_foldtext || wlv.filler_todo > 0) &&
				(wlv.col <= leftcols_width || ([^]u8)(ptr)[0] != 0 ||
					wlv.filler_todo > 0 ||
					((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
						(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_EOL_OFF)^ != 0 &&
						lcs_eol_todo) ||
					(wlv.n_extra != 0 &&
						(wlv.sc_extra != 0 || ([^]u8)(wlv.p_extra)[0] != 0)) ||
					(may_have_inline_virt &&
						has_more_inline_virt_o(&wlv, C.ptrdiff_t(uintptr(ptr) - uintptr(line))))) {
				grid_width := (^ScreenGrid)(grid.target).cols
				wrap := is_wrapped && // wrapping, not a folded line
					wlv.filler_todo <= 0 && // not diff filler lines
					lcs_eol_todo && // lcs_eol not printed
					wlv.row != endrow - 1 && // not the last displayed line
					view_width == grid_width && // window spans its grid
					(^C.int)(uintptr(wp) + W_P_RL_OFF)^ == 0 // not right-to-left
				_ = wrap

				draw_col := wlv.col - wlv.boguscols

				for i := draw_col; i < view_width; i += 1 {
					linebuf_vcol_g[wlv.off + (i - draw_col)] = wlv.vcol - 1
				}

				// 'cursorline' highlight.
				if wlv.boguscols != 0 &&
					(wlv.line_attr_lowprio != 0 || wlv.line_attr != 0) {
					attr := hl_combine_attr_r(wlv.line_attr_lowprio, wlv.line_attr)
					for draw_col < view_width {
						linebuf_char_g[wlv.off] = schar_from_char(' ')
						linebuf_attr_g[wlv.off] = attr
						// linebuf_vcol[] filled by the for loop above.
						wlv.off += 1
						draw_col += 1
					}
				}

				if has_virt_line {
					vls := transmute([^]VirtLine_O)(virt_lines.items)
					overflow := vls[virt_line_index].overflow
					virt_row_scroll := overflow == K_VL_OVERFLOW_SCROLL_O ||
						(overflow == K_VL_OVERFLOW_AUTO_O &&
							(^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0)
					if virt_row_scroll {
						virt_line_skip_cells = w_leftcol_r(wp)
					}
					draw_virt_text_item_o(buf,
						(virt_line_flags & K_VL_LEFTCOL_O) != 0 ? 0 : win_col_offset,
						vls[virt_line_index].line, .Replace, view_width, 0,
						virt_line_skip_cells)
				} else if wlv.filler_todo <= 0 {
					draw_virt_text_o(wp, buf, win_col_offset, &draw_col, wlv.row)
				}

				wlv_put_linebuf_o(wp, &wlv, draw_col, true, bg_attr,
					wrap ? SLF_WRAP_O : 0)
				if wrap {
					current_row := wlv.row
					dummy_col: C.int = 0 // unused
					current_grid := grid_adjust(grid, &current_row, &dummy_col)

					// Force redraw of the next line's first column.
					current_grid.attrs[current_grid.line_offset[current_row + 1]] = -1
				}

				wlv.boguscols = 0
				wlv.vcol_off_co = 0
				wlv.row += 1

				// Not wrapping and diff lines done: break here.
				if !is_wrapped && wlv.filler_todo <= 0 {
					break
				}

				// Window too narrow: draw all "@" lines.
				if wlv.col <= leftcols_width {
					win_draw_end(wp, 64, true, wlv.row, // '@'
						(^C.int)(uintptr(wp) + W_VIEW_HEIGHT_OFF)^, HLF_AT_O)
					set_empty_rows_r(wp, wlv.row)
					wlv.row = endrow
				}

				// Line too long for screen: break here.
				if wlv.row == endrow {
					wlv.row += 1
					break
				}

				win_line_start_o(wp, &wlv)
				draw_cols = true

				lcs_prec_todo = (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_PREC_OFF)^
				if wlv.filler_todo <= 0 {
					wlv.need_showbreak = true
				}
				if statuscol.draw && vim_strchr_c(transmute(^u8)(p_cpo), CPO_NUMCOL_O) != nil &&
					wlv.row > startrow + wlv.filler_lines {
					statuscol.draw = false // no status column with "n" in 'cpo'
				}
				wlv.filler_todo -= 1
				has_virt_line = false
				virt_line_flags = 0
				// Filler below the last file line, or no text: break here.
				if wlv.filler_todo == 0 &&
					((^bool)(uintptr(wp) + W_BOTFILL_OFF)^ || !draw_text) {
					break
				}
			}
		// CHUNK-12d6: loop close + epilogue + return.
		// (for-loop continues via internal breaks; falls through per row)
	} // closes for-every-character (C:3286)

	clear_virttext_r(&fold_vt)
	// kv_destroy(virt_lines)
	xfree(virt_lines.items)
	virt_lines = Kvec_VT{}
	xfree(foldtext_free)
	return wlv.row
}

// ── Batch 11: statuscolumn draw ─────────────────────────────────────────────────

W_STATUSCOL_LINE_COUNT_OFF :: 11052
// w_nrwidth_line_count reuses optionstr.odin W_NRWIDTH_OFF (=11048).
W_NRWIDTH_VAL_OFF :: 676 // w_nrwidth
W_NRWIDTH_WIDTH_OFF :: 11056
W_REDR_STATUSCOL_OFF :: 710 // bool
// w_valid reuses window.odin W_VALID_OFF (=540).
W_P_STC_OFF :: 1088 // ^u8 slot

STL_SIGNCOL_O :: 115
STL_FOLDCOL_O :: 67
MAX_STCWIDTH_O :: 47
// VALID_WCOL_O + MAXPATHL_O reuse window.odin (=2, =4096).

Stl_Hlrec_O :: struct {
	start:  ^u8,   // 0
	userhl: C.int, // 8
	item:   C.int, // 12 (StlFlag)
}
#assert(size_of(Stl_Hlrec_O) == 16)

Statuscol_O :: struct {
	width:      C.int,              // 0
	lnum:       C.int,              // 4
	sign_cul_id: C.int,             // 8
	draw:       bool,               // 12
	_pad13:     [3]u8,
	hlrec:      [^]Stl_Hlrec_O,     // 16
	foldinfo:   Wlv_Foldinfo,       // 24
	fold_vcol:  [9]C.int,           // 40
	sattrs:     rawptr,             // 80 (^SignTextAttrs)
}
#assert(size_of(Statuscol_O) == 88)

foreign _ {
	@(link_name = "display_tick")
	display_tick_g: u64
	@(link_name = "decor_virt_lines")
	decor_virt_lines_r :: proc "c"(wp: rawptr, start_row: C.int, end_row: C.int, num_below: ^C.int, lines: rawptr, apply_folds: bool) -> C.int ---
	@(link_name = "diff_check_fill")
	diff_check_fill_r :: proc "c"(wp: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "build_statuscol_str")
	build_statuscol_str_r :: proc "c"(wp: rawptr, lnum: C.int, relnum: C.int, virtnum: C.int, buf: ^u8, stcp: ^Statuscol_O) -> C.int ---
	@(link_name = "transstr_buf")
	transstr_buf_r :: proc "c"(s: ^u8, slen: C.ssize_t, buf: ^u8, buflen: C.size_t, untab: bool) -> C.size_t ---
}

// draw_statuscol cache statics (drawline.c:713-716).
@(private="file")
stc_prev_virtnum_f: C.int = 0
@(private="file")
stc_prev_wp_f:      rawptr
@(private="file")
stc_prev_lnum_f:    C.int = 0
@(private="file")
stc_prev_tick_f:    u64 = 0

// Build and draw the 'statuscolumn' string (plain, C-static).
draw_statuscol_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars, col_rows: C.int, stcp: ^Statuscol_O) {
	// Filler lines belong to the line above.
	lnum := wlv.lnum - (((wlv.n_virt_lines - wlv.filler_todo) < wlv.n_virt_below) ? 1 : 0)

	// Cache v:virtnum for virtual lines. Check virt_below on the previous
	// line only when lnum < w_topline (mouse_comp_pos uses the same).
	reset := stc_prev_wp_f != wp || stc_prev_tick_f != display_tick_g || lnum != stc_prev_lnum_f
	reset_virt := lnum == wlv.lnum ? wlv.filler_lines_skip : wlv.virt_below_skip
	if reset && lnum < (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
		virt_below_prev: C.int = 0
		virt_lines_prev := decor_virt_lines_r(wp, lnum - 1, lnum, &virt_below_prev, nil, true)
		diff_fill_prev := diff_check_fill_r(wp, lnum - 1)
		reset_virt += virt_lines_prev + diff_fill_prev - virt_below_prev
	}
	stc_prev_virtnum_f = (reset ? -reset_virt : stc_prev_virtnum_f) - ((wlv.filler_todo > 0) ? 1 : 0)
	virtnum := wlv.filler_todo > 0 ? stc_prev_virtnum_f : wlv.row - wlv.startrow - wlv.filler_lines
	// lnum v:vars for first row, first non-filler, first filler of current.
	relnum: C.int = -1
	if virtnum == -reset_virt - 1 || virtnum == 0 {
		relnum = abs(get_cursor_rel_lnum_r(wp, lnum))
	}

	stc_prev_tick_f = display_tick_g
	stc_prev_lnum_f = lnum
	stc_prev_wp_f = wp

	buf: [MAXPATHL_O]u8
	// Line count changed: estimate full width with the largest line number.
	if (^C.int)(uintptr(wp) + W_STATUSCOL_LINE_COUNT_OFF)^ !=
		(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ {
		(^C.int)(uintptr(wp) + W_STATUSCOL_LINE_COUNT_OFF)^ =
			(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^
		width := build_statuscol_str_r(wp,
			(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^,
			(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^, 0, &buf[0], stcp)
		if width > stcp.width {
			addwidth := min(width - stcp.width, MAX_STCWIDTH_O - stcp.width)
			(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ += addwidth
			(^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^ =
				(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^
			if col_rows > 0 {
				// Only the column redraws: text needs redraw as well.
				(^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ = true
				stc_prev_lnum_f = 0
				return
			}
			stcp.width += addwidth
			(^C.int)(uintptr(wp) + W_VALID_OFF)^ &= ~C.int(VALID_WCOL_O)
		}
	}

	width := build_statuscol_str_r(wp, lnum, relnum, virtnum, &buf[0], stcp)
	// Force redraw on error or truncation.
	if ((^rawptr)(uintptr(wp) + W_P_STC_OFF)^ == nil) ||
		(width > stcp.width && stcp.width < MAX_STCWIDTH_O) {
		if (^rawptr)(uintptr(wp) + W_P_STC_OFF)^ == nil { // reset on error
			(^C.int)(uintptr(wp) + W_NRWIDTH_OFF)^ = 0
			nw: C.int = 0
			if (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
				(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
				nw = number_width(wp)
			}
			(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ = nw
		} else { // avoid truncating 'statuscolumn'
			(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^ +=
				min(width - stcp.width, MAX_STCWIDTH_O - stcp.width)
			(^C.int)(uintptr(wp) + W_NRWIDTH_WIDTH_OFF)^ =
				(^C.int)(uintptr(wp) + W_NRWIDTH_VAL_OFF)^
		}
		(^bool)(uintptr(wp) + W_REDR_STATUSCOL_OFF)^ = true
		stc_prev_lnum_f = 0
		return
	}

	p := &buf[0]
	transbuf: [MAXPATHL_O]u8
	fold_vcol: [^]C.int = nil
	slen := libc.strlen(cstring(p))
	scl_attr := win_hl_attr_o(wp,
		use_cursor_line_highlight(wp, wlv.lnum) ? HLF_CLS_O : HLF_SC_O)
	num_attr := get_line_number_attr_o(wp, wlv)
	cur_attr := num_attr

	// Draw each segment with its highlighting.
	spi := 0
	for stcp.hlrec[spi].start != nil {
		sp := &stcp.hlrec[spi]
		textlen := C.ssize_t(uintptr(sp.start) - uintptr(p))
		// Make all characters printable.
		translen := transstr_buf_r(p, textlen, &transbuf[0], MAXPATHL_O, true)
		draw_col_buf_o(wp, wlv, &transbuf[0], C.size_t(translen), cur_attr, fold_vcol, false)
		attr := sp.item == STL_SIGNCOL_O ? scl_attr : sp.item == STL_FOLDCOL_O ? 0 : num_attr
		cur_attr = hl_combine_attr_r(attr,
			sp.userhl < 0 ? syn_id2attr_r(-sp.userhl) : 0)
		if sp.item == STL_FOLDCOL_O {
			fold_vcol = &stcp.fold_vcol[0]
		} else {
			fold_vcol = nil
		}
		p = sp.start
		spi += 1
	}
	translen := transstr_buf_r(p, C.ssize_t(uintptr(&buf[0]) + uintptr(slen) - uintptr(p)),
		&transbuf[0], MAXPATHL_O, true)
	draw_col_buf_o(wp, wlv, &transbuf[0], C.size_t(translen), cur_attr, fold_vcol, false)
	draw_col_fill_o(wlv, 32, stcp.width - width, cur_attr)
}

// ── Batch 10: inline virtual text + decor iteration ───────────────────────────

foreign _ {
	@(link_name = "decor_init_draw_col")
	decor_init_draw_col_r :: proc "c"(win_col: C.int, hidden: bool, item: ^DecorRange_O) ---
	@(link_name = "decor_recheck_draw_col")
	decor_recheck_draw_col_r :: proc "c"(win_col: C.int, hidden: bool, state: rawptr) ---
}

// Feed inline virtual text into wlv extra-text slots (plain, C-static).
handle_inline_virtual_text_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars, v: C.ptrdiff_t, selected: bool) {
	for wlv.n_extra == 0 {
		if wlv.virt_inline_i >= wlv.virt_inline.n {
			// Find inline virtual text at v.
			wlv.virt_inline = Kvec_VT{} // VIRTTEXT_EMPTY
			wlv.virt_inline_i = 0
			state := &decor_state_g
			end := state.current_end

			for i: C.int = 0; i < end; i += 1 {
				item := &([^]DecorRange_O)(state.slots.items)[state.ranges_i.items[i]]
				if item.draw_col == -3 {
					// Position of later non-inline items decidable now.
					decor_init_draw_col_r(wlv.off, selected, item)
				}
				if item.start_row != state.row ||
					item.kind != K_DECOR_VIRTTEXT_O {
					continue
				}
				vt := (^DecorVirtText_O)(item.vt)
				if vt.pos != K_VPOS_INLINE_O || vt.width == 0 {
					continue
				}
				if item.draw_col >= -1 && item.start_col == C.int(v) {
					wlv.virt_inline = vt.data
					wlv.virt_inline_hl_mode = HlMode_O(vt.hl_mode)
					item.draw_col = INT_MIN_O
					break
				}
			}
			if wlv.virt_inline.n == 0 {
				// No more inline virtual text here.
				break
			}
		} else {
			// Inside multi-chunk inline virtual text.
			attr: C.int = 0
			text := next_virt_text_chunk_r(wlv.virt_inline, &wlv.virt_inline_i, &attr)
			if text == nil {
				continue
			}
			wlv.p_extra = text
			wlv.n_extra = C.int(libc.strlen(cstring(text)))
			if wlv.n_extra == 0 {
				continue
			}
			wlv.sc_extra = 0 // NUL
			wlv.sc_final = 0 // NUL
			wlv.extra_attr = attr
			wlv.n_attr = mb_charlen_r(cstring(text))
			// Text left of the first window column: skip cells.
			if wlv.skip_cells > 0 {
				virt_text_width := C.int(mb_string2cells_s(cstring(text)))
				if virt_text_width > wlv.skip_cells {
					skip_remaining := wlv.skip_cells
					// Skip cells in the text.
					for skip_remaining > 0 {
						cells := utf_ptr2cells_r(cstring(wlv.p_extra))
						if cells > skip_remaining {
							break
						}
						c_len := utfc_ptr2len(cstring(wlv.p_extra))
						skip_remaining -= cells
						wlv.p_extra = (^u8)(uintptr(wlv.p_extra) + uintptr(c_len))
						wlv.n_extra -= c_len
						wlv.n_attr -= 1
					}
					// Skipped cells count toward vcol.
					wlv.skipped_cells += wlv.skip_cells - skip_remaining
					wlv.skip_cells = skip_remaining
				} else {
					// Whole text left of window: drop, take next chunk.
					wlv.skip_cells -= virt_text_width
					// Skipped cells count toward vcol.
					wlv.skipped_cells += virt_text_width
					wlv.n_attr = 0
					wlv.n_extra = 0
					continue
				}
			}
			if wlv.n_extra <= 0 {
				libc.abort()
			}
			wlv.extra_for_extmark = true
		}
	}
}

// More inline virtual text available at v? (plain, C-static).
has_more_inline_virt_o :: proc "c"(wlv: ^WinLineVars, v: C.ptrdiff_t) -> bool {
	if wlv.virt_inline_i < wlv.virt_inline.n {
		return true
	}

	state := &decor_state_g
	count := C.int(state.ranges_i.n)
	cur_end := state.current_end
	fut_beg := state.future_begin
	indices := state.ranges_i.items
	slots := ([^]DecorRange_O)(state.slots.items)

	beg_pos: [2]C.int = { 0, fut_beg }
	end_pos: [2]C.int = { cur_end, count }

	for pos_i := 0; pos_i < 2; pos_i += 1 {
		i := beg_pos[pos_i]
		for i < end_pos[pos_i] {
			item := &slots[indices[i]]
			if item.start_row != state.row ||
				item.kind != K_DECOR_VIRTTEXT_O {
				i += 1
				continue
			}
			vt := (^DecorVirtText_O)(item.vt)
			if vt.pos != K_VPOS_INLINE_O || vt.width == 0 {
				i += 1
				continue
			}
			if item.draw_col >= -1 && item.start_col >= C.int(v) {
				return true
			}
			i += 1
		}
	}
	return false
}

// ── Batch 9: DecorState mirrors + draw_virt_text ─────────────────────────────
// Layouts: DecorState pahole (328B), DecorRange pahole (96B: union@32,
// attr_id@88, draw_col@92), DecorVirtText cc-probed (48B), DecorRangeSlot =
// union{range,next_free_i} (96B), WinExtmark (drawline.h:15-19, 24B).

DecorVirtText_O :: struct {
	flags:   u8,        // 0
	hl_mode: u8,        // 1
	prio:    u16,       // 2 (DecorPriority)
	width:   C.int,     // 4
	col:     C.int,     // 8
	pos:     C.int,     // 12 (VirtTextPos)
	data:    Kvec_VT,   // 16 (virt_text; virt_lines shares the 24B)
	next:    rawptr,    // 40 (^DecorVirtText_O)
}
#assert(size_of(DecorVirtText_O) == 48)

DecorRange_O :: struct {
	start_row:   C.int,  // 0
	start_col:   C.int,  // 4
	end_row:     C.int,  // 8
	end_col:     C.int,  // 12
	ordering:    C.int,  // 16
	prio_in:     u32,    // 20
	owned:       bool,   // 24
	kind:        u8,     // 25 (DecorRangeKind)
	_pad26:      [6]u8,  // union needs 8-align
	vt:          rawptr, // 32 (data.vt; sh/ui share the union)
	_unionpad:   [48]u8, // ...to attr_id@88
	attr_id:     C.int,  // 88
	draw_col:    C.int,  // 92
}
#assert(size_of(DecorRange_O) == 96)
#assert(offset_of(DecorRange_O, vt) == 32)
#assert(offset_of(DecorRange_O, draw_col) == 92)

Kvec_DRS :: struct { // kvec_t(DecorRangeSlot): items are 96B unions
	n:     C.size_t, // 0
	a:     C.size_t, // 8
	items: rawptr,   // 16
}
Kvec_Int :: struct { // kvec_t(int)
	n:     C.size_t,
	a:     C.size_t,
	items: [^]C.int,
}

DecorState_O :: struct {
	_opaque0:    [216]u8,  // MarkTreeIter itr (opaque)
	slots:       Kvec_DRS, // 216
	ranges_i:    Kvec_Int, // 240
	current_end: C.int,    // 264
	future_begin: C.int,  // 268
	_pad272:     [20]u8,  // free_slot_i..win..top_row (opaque here)
	row:         C.int,    // 292
	col_last:    C.int,    // 296
	current:     C.int,    // 300
	eol_col:     C.int,    // 304
	conceal:     C.int,    // 308
	conceal_char: u32,     // 312 (schar_T)
	conceal_attr: C.int,   // 316
	spell:       C.int,    // 320 (TriState)
	running_decor_provider: bool, // 324
	itr_valid:   bool,     // 325
	_pad326:     [2]u8,
}
#assert(size_of(DecorState_O) == 328)
#assert(offset_of(DecorState_O, row) == 292)
#assert(offset_of(DecorState_O, eol_col) == 304)

WinExtmark_O :: struct {
	ns_id:   C.int, // 0 (NS/handle_T)
	_pad4:   [4]u8,
	mark_id: u64,    // 8
	win_row: C.int,  // 16
	win_col: C.int,  // 20
}
#assert(size_of(WinExtmark_O) == 24)

Kvec_WE :: struct {
	n:     C.size_t,
	a:     C.size_t,
	items: [^]WinExtmark_O,
}

K_DECOR_HIGHLIGHT_O :: 0
K_DECOR_SIGN_O :: 1
K_DECOR_VIRTTEXT_O :: 2
K_DECOR_VIRTLINES_O :: 3
K_DECOR_UIWATCHED_O :: 4

K_VPOS_EOL_O :: 0
K_VPOS_EOL_RIGHT_O :: 1
K_VPOS_INLINE_O :: 2
K_VPOS_OVERLAY_O :: 3
K_VPOS_RIGHT_O :: 4
K_VPOS_WINCOL_O :: 5

K_VT_REPEAT_LINEBREAK_O :: 8

INT_MIN_O :: -2147483648

foreign _ {
	@(link_name = "decor_state")
	decor_state_g: DecorState_O
	@(link_name = "win_extmark_arr")
	win_extmark_arr_g: Kvec_WE
	@(link_name = "decor_virt_pos")
	decor_virt_pos_r :: proc "c"(decor: ^DecorRange_O) -> bool ---
	@(link_name = "decor_virt_pos_kind")
	decor_virt_pos_kind_r :: proc "c"(decor: ^DecorRange_O) -> C.int ---
}

// Push a WinExtmark (kv_push idiom, Batch-16 growth).
win_extmark_push_o :: proc "c"(m: WinExtmark_O) {
	a := &win_extmark_arr_g
	if a.n == a.a {
		a.a = a.a != 0 ? a.a * 2 : 8
		a.items = ([^]WinExtmark_O)(xrealloc(a.items,
			a.a * size_of(WinExtmark_O)))
	}
	a.items[a.n] = m
	a.n += 1
}

// Draw row decorations with virtual text (plain, C-static).
draw_virt_text_o :: proc "c"(wp: rawptr, buf: rawptr, col_off: C.int, end_col: ^C.int, win_row: C.int) {
	state := &decor_state_g
	max_col := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^
	right_pos := max_col
	do_eol := state.eol_col > -1

	end := state.current_end

	// Total width of "eol_right_align" virtual text.
	total_w: C.int = 0

	for i: C.int = 0; i < end; i += 1 {
		slot := &([^]DecorRange_O)(state.slots.items)[state.ranges_i.items[i]]
		if !(slot.start_row == state.row && decor_virt_pos_r(slot)) {
			continue
		}

		vt: ^DecorVirtText_O = nil
		if slot.kind == K_DECOR_VIRTTEXT_O {
			if slot.vt == nil {
				libc.abort()
			}
			vt = (^DecorVirtText_O)(slot.vt)
		}
		if decor_virt_pos_r(slot) && slot.draw_col == -1 {
			updated := true
			pos := decor_virt_pos_kind_r(slot)

			if do_eol && pos == K_VPOS_EOL_RIGHT_O {
				eol_off: C.int = 0
				if total_w == 0 {
					// Look ahead at remaining decor items.
					for j := i; j < end; j += 1 {
						la := &([^]DecorRange_O)(state.slots.items)[state.ranges_i.items[j]]
						if la.start_row != state.row ||
							!decor_virt_pos_r(la) || la.draw_col != -1 {
							continue
						}

						la_vt: ^DecorVirtText_O = nil
						if la.kind == K_DECOR_VIRTTEXT_O {
							if la.vt == nil {
								libc.abort()
							}
							la_vt = (^DecorVirtText_O)(la.vt)
						}

						if decor_virt_pos_kind_r(la) == K_VPOS_EOL_RIGHT_O {
							// One extra space for EOL-alignment spacing.
							total_w += (la_vt.width + 1)
						}
					}

					// No trailing space after the last entry.
					total_w -= 1

					if total_w <= (right_pos - state.eol_col) {
						eol_off = right_pos - total_w - state.eol_col
					}
				}
				slot.draw_col = state.eol_col + eol_off
			} else if pos == K_VPOS_RIGHT_O {
				right_pos -= vt.width
				slot.draw_col = right_pos
			} else if pos == K_VPOS_EOL_O && do_eol {
				slot.draw_col = state.eol_col
			} else if pos == K_VPOS_WINCOL_O {
				slot.draw_col = max(col_off + vt.col, 0)
			} else {
				updated = false
			}
			if updated && (slot.draw_col < 0 || slot.draw_col >= (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^) {
				// Out of window: don't draw at all.
				slot.draw_col = INT_MIN_O
			}
		}
		if slot.draw_col < 0 {
			continue
		}
		if slot.kind == K_DECOR_UIWATCHED_O {
			// Send mark position to UI (union ui: ns u32@0, mark u32@4).
			ui_ns := (^u32)(slot.vt)^
			ui_mark := (^u32)(uintptr(slot.vt) + 4)^
			win_extmark_push_o(WinExtmark_O{
				ns_id = C.int(ui_ns),
				mark_id = u64(ui_mark),
				win_row = win_row,
				win_col = slot.draw_col,
			})
		}
		if vt != nil {
			vcol := slot.draw_col - col_off
			col := draw_virt_text_item_o(buf, slot.draw_col, vt.data,
				HlMode_O(vt.hl_mode), max_col, vcol, 0)
			if do_eol && (vt.pos == K_VPOS_EOL_O || vt.pos == K_VPOS_EOL_RIGHT_O) {
				state.eol_col = col + 1
			}
			end_col^ = max(end_col^, col)
		}
		if vt == nil || (vt.flags & K_VT_REPEAT_LINEBREAK_O) == 0 {
			slot.draw_col = INT_MIN_O // deactivate
		}
	}
}

// ── Batch 8: virt-text item draw ──────────────────────────────────────────────

foreign _ {
	@(link_name = "hl_blend_attrs")
	hl_blend_attrs_r :: proc "c"(back_attr: C.int, front_attr: C.int, through: ^bool) -> C.int ---
}

// [^]u8 cursor back to cstring for utf FFI.
vsp_cstr_o :: proc "c"(p: [^]u8) -> cstring {
	return transmute(cstring)(p)
}

// Draw one virtual-text run into linebuf (plain, C-static). Returns end col.
draw_virt_text_item_o :: proc "c"(buf: rawptr, col: C.int, vt: Kvec_VT, hl_mode: HlMode_O, max_col: C.int, vcol: C.int, skip_cells: C.int) -> C.int {
	virt_str := cstring("")
	virt_attr: C.int = 0
	virt_pos: C.size_t = 0
	c := col
	vc := vcol
	sk := skip_cells

	for c < max_col {
		if sk >= 0 && ([^]u8)(virt_str)[0] == 0 {
			if virt_pos >= vt.n {
				break
			}
			virt_attr = 0
			virt_str = cstring(next_virt_text_chunk_r(vt, &virt_pos, &virt_attr))
			if virt_str == nil {
				break
			}
		}
		// Skip cells in the text.
		vsp := ([^]u8)(virt_str)
		for sk > 0 && vsp[0] != 0 {
			c_len := utfc_ptr2len(vsp_cstr_o(vsp))
			cells: C.int
			if vsp[0] == '\t' {
				cells = tabstop_padding_r(vc, (^i64)(uintptr(buf) + B_P_TS_OFF)^,
					transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
			} else {
				cells = utf_ptr2cells_r(vsp_cstr_o(vsp))
			}
			sk -= cells
			vc += cells
			vsp = ([^]u8)(uintptr(vsp) + uintptr(c_len))
		}
		virt_str = cstring(vsp)
		// Double-width char or TAB that doesn't fit: pad with spaces.
		draw_str := sk < 0 ? cstring(" ") : virt_str
		if ([^]u8)(draw_str)[0] == 0 {
			continue
		}
		if sk > 0 {
			libc.abort()
		}
		attr: C.int
		through := false
		if hl_mode == .Combine {
			attr = hl_combine_attr_r(linebuf_attr_g[c], virt_attr)
		} else if hl_mode == .Blend {
			through = (([^]u8)(draw_str)[0] == ' ')
			attr = hl_blend_attrs_r(linebuf_attr_g[c], virt_attr, &through)
		} else {
			attr = virt_attr
		}
		dummy: [2]u32 = { 32, 32 } // ' ' ' '
		maxcells := max_col - c
		// Overwriting right half of double-width: clear the left half.
		if !through && linebuf_char_g[c] == 0 {
			if c <= 0 {
				libc.abort()
			}
			linebuf_char_g[c - 1] = 32 // ' '
			// Clear right half too (line_putchar assertion).
			linebuf_char_g[c] = 32 // ' '
		}
		ds := transmute(^u8)(draw_str)
		dest := &linebuf_char_g[c]
		if through {
			dest = &dummy[0]
		}
		cells := line_putchar_o(buf, &ds, dest, maxcells, vc)
		for i: C.int = 0; i < cells; i += 1 {
			linebuf_attr_g[c] = attr
			c += 1
		}
		if sk < 0 {
			sk += 1
		} else {
			vc += cells
			virt_str = transmute(cstring)(ds)
		}
	}
	return c
}

// ── Batch 7: breakindent/showbreak handlers ───────────────────────────────────

W_BRIOPT_SBR_OFF :: 4244 // w_briopt_sbr (bool)
FCS_DIFF_OFF :: 60 // fcs.diff
HLF_DED_O :: 32

foreign _ {
	@(link_name = "get_breakindent_win")
	get_breakindent_win_r :: proc "c"(wp: rawptr, line: ^u8) -> C.int ---
}

// Draw 'breakindent' for wrapped lines (plain, C-static).
handle_breakindent_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	// Indent wrapped text; also applies when need_showbreak is set.
	if (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ != 0 &&
		(wlv.row > wlv.startrow + wlv.filler_lines || wlv.need_showbreak) {
		attr: C.int = 0
		if wlv.diff_hlf != 0 {
			attr = win_hl_attr_o(wp, wlv.diff_hlf)
		}
		num := get_breakindent_win_r(wp,
			ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, wlv.lnum))
		if wlv.row == wlv.startrow {
			num -= win_col_off2_r(wp)
			if wlv.n_extra < 0 {
				num = 0
			}
		}

		vcol_before := wlv.vcol

		for i: C.int = 0; i < num; i += 1 {
			linebuf_char_g[wlv.off] = 32 // ' '

			advance_color_col_o(wlv, wlv.vcol)
			myattr := attr
			if wlv.color_cols != nil && wlv.vcol == wlv.color_cols[0] {
				myattr = hl_combine_attr_r(win_hl_attr_o(wp, HLF_MC_O), myattr)
			}
			linebuf_attr_g[wlv.off] = myattr
			linebuf_vcol_g[wlv.off] = wlv.vcol // vcols, sorry I don't make the rules
			wlv.vcol += 1
			wlv.off += 1
		}

		// Correct start of highlighted area for 'breakindent'.
		if wlv.fromcol >= vcol_before && wlv.fromcol < wlv.vcol {
			wlv.fromcol = wlv.vcol
		}

		// Correct end of highlighted area ('linebreak' needs it too).
		if wlv.tocol == vcol_before {
			wlv.tocol = wlv.vcol
		}
	}

	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && wlv.startrow == 0 &&
		(^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 &&
		(^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ {
		wlv.need_showbreak = false
	}
}

// Filler lines + 'showbreak' at broken lines (plain, C-static).
handle_showbreak_and_filler_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	remaining := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - wlv.off
	if wlv.filler_todo > wlv.filler_lines - wlv.n_virt_lines {
		// TODO(bfredl): check this doesn't inhibit TUI-style clear-to-EOL.
		draw_col_fill_o(wlv, 32, remaining, 0)
	} else if wlv.filler_todo > 0 {
		// Draw "deleted" diff line(s).
		c := (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_DIFF_OFF)^
		draw_col_fill_o(wlv, c, remaining, win_hl_attr_o(wp, HLF_DED_O))
	}

	sbr := get_showbreak_value(wp)
	if sbr^ != 0 && wlv.need_showbreak {
		// 'showbreak' at each broken line; beats 'cursorline'.
		attr := hl_combine_attr_r(wlv.cul_attr, win_hl_attr_o(wp, HLF_AT_O))
		vcol_before := wlv.vcol
		draw_col_buf_o(wp, wlv, sbr, libc.strlen(cstring(sbr)), attr, nil, true)
		wlv.vcol_sbr = wlv.vcol

		// Correct start of highlighted area for 'showbreak'.
		if wlv.fromcol >= vcol_before && wlv.fromcol < wlv.vcol {
			wlv.fromcol = wlv.vcol
		}

		// Correct end of highlighted area ('linebreak' needs it too).
		if wlv.tocol == vcol_before {
			wlv.tocol = wlv.vcol
		}
	}

	if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 || wlv.startrow > 0 ||
		(^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ == 0 ||
		!(^bool)(uintptr(wp) + W_BRIOPT_SBR_OFF)^ {
		wlv.need_showbreak = false
	}
}

// ── Batch 6: wlv_put_linebuf ──────────────────────────────────────────────────

HLF_AT_O :: 4
LCS_PREC_OFF :: 8 // lcs.prec

// Flush the wlv linebuf segment to the window grid (plain, C-static).
wlv_put_linebuf_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars, endcol: C.int, clear_end: bool, bg_attr: C.int, flags: C.int) {
	grid := (^GridView)(uintptr(wp) + W_GRID_OFF)

	startcol: C.int = 0
	end_c := endcol
	clear_width := clear_end ? (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ : end_c
	fl := flags

	if (fl & SLF_RIGHTLEFT_O) != 0 {
		libc.abort()
	}
	if (^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 {
		linebuf_mirror(&startcol, &end_c, &clear_width,
			(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^)
		fl |= SLF_RIGHTLEFT_O
	}

	// "<<<" on the first line for 'smoothscroll'.
	if wlv.row == 0 && (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 &&
		// Don't overwrite 'showbreak' text with "<<<".
		get_showbreak_value(wp)^ == 0 &&
		// Don't overwrite 'listchars' precedes text with "<<<".
		!((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 &&
			(^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_PREC_OFF)^ != 0) {
		off: C.int = 0
		if (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 &&
			(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
			// Keep the line number: "123 text" becomes "123<<<xt".
			for off < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ &&
				ascii_isdigit_o(schar_get_ascii(linebuf_char_g[off])) {
				off += 1
			}
		}

		for i: C.int = 0; i < 3 && off < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^; i += 1 {
			if off + 1 < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ &&
				linebuf_char_g[off + 1] == 0 {
				// First half of double-width overwritten: space the rest.
				linebuf_char_g[off + 1] = 32 // ' '
			}
			linebuf_char_g[off] = 60 // '<'
			linebuf_attr_g[off] = hl_attr_active_g[HLF_AT_O]
			off += 1
		}
	}

	row := wlv.row
	coloff: C.int = 0
	g := grid_adjust(grid, &row, &coloff)
	grid_put_linebuf(g, row, coloff, startcol, end_c, clear_width, bg_attr,
		0, wlv.vcol - 1, fl)
}

// ── Batch 5: line-start + cursorline/diff attrs + margin cache ────────────────

HLF_CUL_O :: 56

foreign _ {
	@(link_name = "syn_attr2entry")
	syn_attr2entry_r :: proc "c"(attr: C.int) -> HlAttrs ---
	@(link_name = "qf_current_entry")
	qf_current_entry_r :: proc "c"(wp: rawptr) -> C.int ---
	@(link_name = "hl_get_underline")
	hl_get_underline_r :: proc "c"() -> C.int ---
}

// extra_buf statics (drawline.c:137-138).
@(private="file")
extra_buf_f:      ^u8
@(private="file")
extra_buf_size_f: C.size_t = 0

// Scratch buffer, grown as needed (plain, C-static).
get_extra_buf_o :: proc "c"(size: C.size_t) -> ^u8 {
	sz := max(size, 64)
	if extra_buf_size_f < sz {
		xfree(extra_buf_f)
		extra_buf_f = (^u8)(xmalloc(sz))
		extra_buf_size_f = sz
	}
	return extra_buf_f
}

// Start a screen line at column zero (plain, C-static).
win_line_start_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	wlv.col = 0
	wlv.off = 0
	wlv.need_lbr = false
	for i: C.int = 0; i < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^; i += 1 {
		linebuf_char_g[i] = 32 // ' '
		linebuf_attr_g[i] = 0
		linebuf_vcol_g[i] = -1
	}
}

// CursorLine highlight compromise (#7383, plain, C-static).
apply_cursorline_highlight_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	wlv.cul_attr = win_hl_attr_o(wp, HLF_CUL_O)
	ae := syn_attr2entry_r(wlv.cul_attr)
	// Low-priority CursorLine if fg unset, else full ("same as Vim") priority.
	if ae.rgb_fg_color == -1 && ae.cterm_fg_color == 0 {
		wlv.line_attr_lowprio = wlv.cul_attr
	} else {
		if (State & MODE_INSERT) == 0 && bt_quickfix((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^) &&
			qf_current_entry_r(wp) == wlv.lnum {
			wlv.line_attr = hl_combine_attr_r(wlv.cul_attr, wlv.line_attr)
		} else {
			wlv.line_attr = wlv.cul_attr
		}
	}
}

// Diff-mode line attribute with CursorLine overlay (plain, C-static).
set_line_attr_for_diff_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	wlv.line_attr = win_hl_attr_o(wp, wlv.diff_hlf)
	// Overlay CursorLine onto diff-mode highlight.
	if wlv.cul_attr != 0 {
		if wlv.line_attr_lowprio != 0 { // Low-priority CursorLine
			wlv.line_attr = hl_combine_attr_r(
				hl_combine_attr_r(wlv.cul_attr, wlv.line_attr),
				hl_get_underline_r())
		} else {
			wlv.line_attr = hl_combine_attr_r(wlv.line_attr, wlv.cul_attr)
		}
	}
}

// margin_columns_win cache statics (drawline.c:190-196).
@(private="file")
margin_saved_virtcol_f: C.int = 0
@(private="file")
margin_prev_wp_f:       rawptr
@(private="file")
margin_prev_width1_f:   C.int = 0
@(private="file")
margin_prev_width2_f:   C.int = 0
@(private="file")
margin_prev_left_f:     C.int = 0
@(private="file")
margin_prev_right_f:    C.int = 0

// 'cursorlineopt' screenline margins (plain, C-static).
margin_columns_win_o :: proc "c"(wp: rawptr, left_col: ^C.int, right_col: ^C.int) {
	// Cached on w_virtcol.
	cur_col_off := win_col_off_r(wp)
	width1 := (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - cur_col_off
	width2 := width1 + win_col_off2_r(wp)

	if margin_saved_virtcol_f == (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ &&
		margin_prev_wp_f == wp && margin_prev_width1_f == width1 &&
		margin_prev_width2_f == width2 {
		right_col^ = margin_prev_right_f
		left_col^ = margin_prev_left_f
		return
	}

	left_col^ = 0
	right_col^ = width1

	if (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ >= width1 && width2 > 0 {
		right_col^ = width1 + (((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ - width1) / width2 + 1) * width2
	}
	if (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ >= width1 && width2 > 0 {
		left_col^ = ((^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^ - width1) / width2 * width2 + width1
	}

	// Cache values.
	margin_prev_left_f = left_col^
	margin_prev_right_f = right_col^
	margin_prev_wp_f = wp
	margin_prev_width1_f = width1
	margin_prev_width2_f = width2
	margin_saved_virtcol_f = (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
}

// ── Batch 4: putchar + sign/number columns ───────────────────────────────────

// Reuse: W_P_NU/RNU_OFF + W_MINSCWIDTH_OFF (optionstr.odin),
// W_SKIPCOL_OFF (option.odin), W_BUFFER/TOPLINE_OFF (window.odin).
W_P_BRI_OFF :: 820 // w_p_bri (int)

SIGN_WIDTH_O :: 2
SCL_NUM_O :: -2
CPO_NUMCOL_O :: 'n'

foreign _ {
	@(link_name = "transchar_hex")
	transchar_hex_r :: proc "c"(buf: ^u8, c: C.int) -> C.size_t ---
}

foreign _ {
	@(link_name = "get_syntax_attr")
	get_syntax_attr_r :: proc "c"(col: C.int, can_spell: ^bool, keep_state: bool) -> C.int ---
	@(link_name = "get_syntax_info")
	get_syntax_info_r :: proc "c"(seqnrp: ^C.int) -> C.int ---
	@(link_name = "spell_check")
	spell_check_r :: proc "c"(wp: rawptr, ptr: ^u8, attrp: ^C.int, capcol: ^C.int, docount: bool) -> C.size_t ---
	@(link_name = "spell_redraw_lnum")
	spell_redraw_lnum_g: C.int
}

SYN_SPO_FLAGS_OFF :: 1128 // synblock_T.b_p_spo_flags (OptInt)
K_OPT_SPO_NOPLAINBUFFER_O :: 0x02
foreign _ {
	@(link_name = "utf_head_off")
	utf_head_off_r :: proc "c"(base: ^u8, p: ^u8) -> C.int ---
	// breakat_flags_g: optionstr.odin (identical [256]u8).
}

foreign _ {
	@(link_name = "transchar_buf")
	transchar_buf_r :: proc "c"(buf: rawptr, c: C.int) -> ^u8 ---
	@(link_name = "byte2cells")
	byte2cells_r :: proc "c"(b: C.int) -> C.int ---
	@(link_name = "dy_flags")
	dy_flags_g: C.uint
}

K_OPT_DY_UHEX_O :: 0x04
foreign _ {
	@(link_name = "syn_get_sub_char")
	syn_get_sub_char_r :: proc "c"() -> C.int ---
}

// W_P_COLE_OFF reuses window.odin (=1144).
HL_CONCEAL_O :: 131072
LCS_CONCEAL_OFF :: 72 // lcs.conceal
foreign _ {
	@(link_name = "get_prevcol_hl_flag")
	get_prevcol_hl_flag_r :: proc "c"(wp: rawptr, search_hl: rawptr, curcol: C.int) -> bool ---
	@(link_name = "get_search_match_hl")
	get_search_match_hl_r :: proc "c"(wp: rawptr, search_hl: rawptr, col: C.int, char_attr: ^C.int) ---
}

// W_WCOL/W_WROW_OFF reuse window.odin (=604/=600).
W_WCOL_CONCEAL_OFF :: 608 // w_wcol_conceal_off
W_CLINE_FOLDED_OFF :: 588 // w_cline_folded (bool)
VALID_CHEIGHT_O :: 0x08
// VALID_CROW_O reuses window.odin (=0x10).
VALID_WROW_O :: 0x01
VALID_VIRTCOL_O :: 0x04
// VALID_WCOL_O reuses window.odin (=0x02).
foreign _ {
	@(link_name = "decor_redraw_eol")
	decor_redraw_eol_r :: proc "c"(wp: rawptr, state: rawptr, eol_attr: ^C.int, eol_col: C.int) -> bool ---
	@(link_name = "normal_bg")
	normal_bg_g: C.int
	@(link_name = "cterm_normal_bg_color")
	cterm_normal_bg_color_g: C.int
	@(link_name = "ui_rgb_attached")
	ui_rgb_attached_r :: proc "c"() -> bool ---
}

HLF_CUC_O :: 55
foreign _ {
	@(link_name = "set_empty_rows")
	set_empty_rows_r :: proc "c"(wp: rawptr, used: C.int) ---
}

K_VL_OVERFLOW_SCROLL_O :: 1
K_VL_OVERFLOW_AUTO_O :: 3
HLF_0_O :: 59
HLF_8_O :: 1
W_P_COCU_OFF :: 1136 // w_p_cocu (^u8 slot)
LCS_TAB1_OFF :: 20
// LCS_TAB2_OFF reuses optionstr.odin (=24).
LCS_TAB3_OFF :: 28
LCS_LEADTAB1_OFF2 :: 32
// LCS_LEADTAB2_OFF reuses optionstr.odin (=36).
LCS_LEADTAB3_OFF :: 40
LCS_EOL_OFF :: 0

// charset.h:36 static inline.
vim_isbreak_o :: proc "c"(c: C.int) -> bool {
	return breakat_flags_g[u8(c)] != 0
}

// TriState→bool with default (types_defs.h:52 macro).
tristate_to_bool_o :: proc "c"(val: C.int, default: bool) -> bool {
	if val == 1 { // kTrue
		return true
	} else if val == 0 { // kFalse
		return false
	}
	return default
}
MB_FILLER_CHAR_O :: '<'
FCS_FOLD_OFF :: 40 // fcs.fold
HLF_CLS_O :: 16
HLF_SC_O :: 35
HLF_CLN_O :: 15
HLF_LNA_O :: 13
HLF_LNB_O :: 14
HLF_N_O :: 12
HLF_MC_O :: 57

foreign _ {
	@(link_name = "syn_id2attr")
	syn_id2attr_r :: proc "c"(hl_id: C.int) -> C.int ---
	@(link_name = "decor_redraw_signs")
	decor_redraw_signs_r :: proc "c"(wp: rawptr, buf: rawptr, row: C.int, sattrs: rawptr, line_id: ^C.int, cul_id: ^C.int, num_id: ^C.int) ---
	@(link_name = "get_cursor_rel_lnum")
	get_cursor_rel_lnum_r :: proc "c"(wp: rawptr, lnum: C.int) -> C.int ---
	@(link_name = "rl_mirror_ascii")
	rl_mirror_ascii_r :: proc "c"(s: ^u8, e: ^u8) ---
	@(link_name = "skiptowhite")
	skiptowhite_r :: proc "c"(p: cstring) -> cstring ---
}

// Put one UTF-8 char into a line buffer (plain, C-static).
// Double-width char with one cell left emits space without advancing *pp.
// Handles composing chars. Returns cells used.
line_putchar_o :: proc "c"(buf: rawptr, pp: ^^u8, dest: [^]u32, maxcells: C.int, vcol: C.int) -> C.int {
	// Caller handles overwriting the right half of a double-width char.
	if dest[0] == 0 {
		libc.abort()
	}

	p := pp^
	pc := ([^]u8)(p)
	cells := utf_ptr2cells_r(cstring(p))
	c_len := utfc_ptr2len(cstring(p))
	if maxcells <= 0 {
		libc.abort()
	}
	if cells > maxcells {
		dest[0] = 32 // ' '
		return 1
	}

	if pc[0] == '\t' {
		cells = tabstop_padding_r(vcol, (^i64)(uintptr(buf) + B_P_TS_OFF)^,
			transmute(^C.int)((^rawptr)(uintptr(buf) + B_P_VTS_ARR_OFF)^))
		cells = min(cells, maxcells)
	}

	// Overwriting the left half of a double-width char: clear right half.
	if cells < maxcells && dest[cells] == 0 {
		dest[cells] = 32 // ' '
	}
	if pc[0] == '\t' {
		for c: C.int = 0; c < cells; c += 1 {
			dest[c] = 32 // ' '
		}
	} else {
		u8c: C.int
		dest[0] = utfc_ptr2schar_r(cstring(p), &u8c)
		if cells > 1 {
			dest[1] = 0
		}
	}

	pp^ = (^u8)(uintptr(p) + uintptr(c_len))
	return cells
}

// Draw buffer text into the linebuf (plain, C-static).
draw_col_buf_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars, text: ^u8, len: C.size_t, attr: C.int, fold_vcol: [^]C.int, inc_vcol: bool) {
	ptr := text
	fvc := fold_vcol
	for uintptr(ptr) < uintptr(text) + uintptr(len) &&
		wlv.off < (^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ {
		cells := line_putchar_o((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^,
			&ptr, &linebuf_char_g[wlv.off],
			(^C.int)(uintptr(wp) + W_VIEW_WIDTH_OFF)^ - wlv.off, wlv.off)
		myattr := attr
		if inc_vcol {
			advance_color_col_o(wlv, wlv.vcol)
			if wlv.color_cols != nil && wlv.vcol == wlv.color_cols[0] {
				myattr = hl_combine_attr_r(win_hl_attr_o(wp, HLF_MC_O), myattr)
			}
		}
		for c: C.int = 0; c < cells; c += 1 {
			linebuf_attr_g[wlv.off] = myattr
			if inc_vcol {
				linebuf_vcol_g[wlv.off] = wlv.vcol
				wlv.vcol += 1
			} else if fvc != nil {
				linebuf_vcol_g[wlv.off] = fvc[0]
				fvc = ([^]C.int)(uintptr(fvc) + size_of(C.int))
			} else {
				linebuf_vcol_g[wlv.off] = -1
			}
			wlv.off += 1
		}
	}
}

// Draw a sign (or blanks) into the sign column (plain, C-static).
draw_sign_o :: proc "c"(nrcol: bool, wp: rawptr, wlv: ^WinLineVars, sign_idx: C.int) {
	sattr := wlv.sattrs[sign_idx]
	scl_attr := win_hl_attr_o(wp,
		use_cursor_line_highlight(wp, wlv.lnum) ? HLF_CLS_O : HLF_SC_O)

	if sattr.text[0] != 0 && wlv.row == wlv.startrow + wlv.filler_lines && wlv.filler_todo <= 0 {
		fill: C.int = SIGN_WIDTH_O
		if nrcol {
			fill = number_width(wp) + 1
		}
		attr: C.int = 0
		if wlv.sign_cul_attr != 0 {
			attr = wlv.sign_cul_attr
		} else if sattr.hl_id != 0 {
			attr = syn_id2attr_r(sattr.hl_id)
		}
		attr = hl_combine_attr_r(scl_attr, attr)
		draw_col_fill_o(wlv, 32, fill, attr)
		sign_pos := wlv.off - SIGN_WIDTH_O - (nrcol ? 1 : 0)
		if sign_pos < 0 {
			libc.abort()
		}
		linebuf_char_g[sign_pos] = sattr.text[0]
		linebuf_char_g[sign_pos + 1] = sattr.text[1]
	} else {
		if nrcol {
			libc.abort() // handled in draw_lnum_col()
		}
		draw_col_fill_o(wlv, 32, SIGN_WIDTH_O, scl_attr)
	}
}

// "%*d " line-number string (plain, C static inline).
get_line_number_str_o :: proc "c"(wp: rawptr, lnum: C.int, buf: ^u8, buf_len: C.size_t) {
	num: C.int
	fmt := cstring("%*d ")
	if (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 &&
		(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ == 0 {
		// 'number' + 'norelativenumber'
		num = lnum
	} else {
		// 'relativenumber', never negative
		num = abs(get_cursor_rel_lnum_r(wp, lnum))
		if num == 0 && (^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 &&
			(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
			// 'number' + 'relativenumber'
			num = lnum
			fmt = cstring("%-*d ")
		}
	}

	libc.snprintf(buf, buf_len, fmt, number_width(wp), num)
}

// True when CursorLineNr applies to the number column (plain, C-static).
use_cursor_line_nr_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) -> bool {
	return (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 &&
		wlv.lnum == (^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ &&
		((^C.uint)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ & kOptCuloptFlagNumber_S) != 0 &&
		(wlv.row == wlv.startrow + wlv.filler_lines ||
			(wlv.row > wlv.startrow + wlv.filler_lines &&
				((^C.uint)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ & kOptCuloptFlagLine_S) != 0))
}

// Line-number attribute with sign numhl priority (plain, C-static).
get_line_number_attr_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) -> C.int {
	numhl_attr := wlv.sign_num_attr

	// Previous sign numhl for virt_lines of the previous line.
	if (wlv.n_virt_lines - wlv.filler_todo) < wlv.n_virt_below {
		if wlv.prev_num_attr == -1 {
			decor_redraw_signs_r(wp, (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^,
				wlv.lnum - 2, nil, nil, nil, &wlv.prev_num_attr)
			if wlv.prev_num_attr > 0 {
				wlv.prev_num_attr = syn_id2attr_r(wlv.prev_num_attr)
			}
		}
		numhl_attr = wlv.prev_num_attr
	}

	if use_cursor_line_nr_o(wp, wlv) {
		// TODO(vim): CursorLine instead of CursorLineNr when unset?
		return hl_combine_attr_r(win_hl_attr_o(wp, HLF_CLN_O), numhl_attr)
	}

	if (^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0 {
		if wlv.lnum < (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
			// LineNrAbove
			return hl_combine_attr_r(win_hl_attr_o(wp, HLF_LNA_O), numhl_attr)
		}
		if wlv.lnum > (^C.int)(uintptr(wp) + W_CURSOR_OFF)^ {
			// LineNrBelow
			return hl_combine_attr_r(win_hl_attr_o(wp, HLF_LNB_O), numhl_attr)
		}
	}

	return hl_combine_attr_r(win_hl_attr_o(wp, HLF_N_O), numhl_attr)
}

// Display the absolute/relative line number (plain, C-static).
draw_lnum_col_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	has_cpo_n := vim_strchr_c(transmute(^u8)(p_cpo), CPO_NUMCOL_O) != nil

	if ((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
		(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0) &&
		(wlv.row == wlv.startrow + wlv.filler_lines || !has_cpo_n) &&
		// No number in a wrapped line with "n" in 'cpo' ('breakindent' wants it).
		!((has_cpo_n && (^C.int)(uintptr(wp) + W_P_BRI_OFF)^ == 0) &&
			(^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 &&
			wlv.lnum == (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^) {
		// 'signcolumn' number + sign present: show the sign instead.
		if (^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ == SCL_NUM_O &&
			wlv.sattrs[0].text[0] != 0 &&
			wlv.row == wlv.startrow + wlv.filler_lines && wlv.filler_todo <= 0 {
			draw_sign_o(true, wp, wlv, 0)
		} else {
			// Line number (blank space after wrapping).
			width := number_width(wp) + 1
			attr := get_line_number_attr_o(wp, wlv)
			if wlv.row == wlv.startrow + wlv.filler_lines &&
				((^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ == 0 || wlv.row > 0 ||
					((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 &&
						(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0)) {
				buf: [32]u8
				get_line_number_str_o(wp, wlv.lnum, &buf[0], size_of(buf))
				if (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^ > 0 && wlv.startrow == 0 {
					for c := &buf[0]; c^ == ' '; c = (^u8)(uintptr(c) + 1) {
						c^ = '-'
					}
				}
				if (^C.int)(uintptr(wp) + W_P_RL_OFF)^ != 0 { // reverse numbers
					num := skipwhite(cstring(&buf[0]))
					rl_mirror_ascii_r(transmute(^u8)(num),
						transmute(^u8)(skiptowhite_r(num)))
				}
				draw_col_buf_o(wp, wlv, &buf[0], C.size_t(width), attr, nil, false)
			} else {
				draw_col_fill_o(wlv, 32, width, attr)
			}
		}
	}
}

// ── Batch 3: win_hl_attr + draw_foldcolumn ───────────────────────────────────

W_NS_HL_ATTR_OFF :: 40 // w_ns_hl_attr (int*)

HLF_CLF_O :: 17
HLF_FC_O :: 29

foreign _ {
	@(link_name = "ns_hl_fast")
	ns_hl_fast_g: C.int
}

// Window highlight attribute (highlight.h:116 static inline).
win_hl_attr_o :: proc "c"(wp: rawptr, hlf: C.int) -> C.int {
	// w_ns_hl_attr may be NULL when checking highlights before redraw.
	ns_attrs := (^[^]C.int)(uintptr(wp) + W_NS_HL_ATTR_OFF)^
	if ns_attrs != nil && ns_hl_fast_g < 0 {
		return ns_attrs[hlf]
	}
	return hl_attr_active_g[hlf]
}

// Setup for drawing the 'foldcolumn', if there is one (plain, C-static).
draw_foldcolumn_o :: proc "c"(wp: rawptr, wlv: ^WinLineVars) {
	fdc := compute_foldcolumn(wp, 0)
	if fdc > 0 {
		attr := win_hl_attr_o(wp,
			use_cursor_line_highlight(wp, wlv.lnum) ? HLF_CLF_O : HLF_FC_O)
		is_virt := wlv.filler_todo > 0
		fill_foldcolumn(wp, wlv.foldinfo, wlv.lnum, attr, fdc, is_virt,
			&wlv.off, nil, nil)
	}
}

// ── Batch 2: column-fill + foldcolumn + cursorline leaves ────────────────────

// w_p_wrap reuses option.odin W_P_WRAP_OFF (=1124).
W_P_LIST_OFF :: 956 // w_p_list (int)
W_P_CUL_OFF :: 1060 // w_p_cul (int)
W_CURSORLINE_OFF :: 156 // w_cursorline (linenr_T)
// w_p_lcs_chars (W_P_LCS_CHARS_OFF=200) / w_p_fcs_chars (W_P_FCS_CHARS_OFF=280)
// sub-field offsets (buffer_defs.h:1055-1097, cc-probed):
LCS_EXT_OFF :: 4 // lcs.ext
FCS_FOLDOPEN_OFF :: 44
FCS_FOLDCLOSED_OFF :: 48
FCS_FOLDSEP_OFF :: 52
FCS_FOLDINNER_OFF :: 56

// Fill linebuf cells with a fill char (plain, C-static).
draw_col_fill_o :: proc "c"(wlv: ^WinLineVars, fillchar: u32, width: C.int, attr: C.int) {
	for i: C.int = 0; i < width; i += 1 {
		linebuf_char_g[wlv.off] = fillchar
		linebuf_attr_g[wlv.off] = attr
		wlv.off += 1
	}
}

// True when CursorLineSign highlight applies.
@(export)
use_cursor_line_highlight :: proc "c"(wp: rawptr, lnum: C.int) -> bool {
	return (^C.int)(uintptr(wp) + W_P_CUL_OFF)^ != 0 &&
		lnum == (^C.int)(uintptr(wp) + W_CURSORLINE_OFF)^ &&
		((^C.uint)(uintptr(wp) + W_P_CULOPT_FLAGS_OFF)^ & kOptCuloptFlagNumber_S) != 0
}

// Foldcolumn separator char for a level/column (plain, C static inline).
foldcolumn_sep_char_o :: proc "c"(first_level: C.int, i: C.int, wp: rawptr) -> u32 {
	if first_level == 1 {
		return (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLDSEP_OFF)^
	} else if (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLDINNER_OFF)^ != 0 {
		return (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLDINNER_OFF)^
	} else if first_level + i <= 9 {
		return u32(48 + first_level + i) // schar_from_ascii('0'+...)
	}
	return u32(62) // schar_from_ascii('>')
}

// Draw the foldcolumn (or fill statuscolumn buffers). Monocell chars.
@(export)
fill_foldcolumn :: proc "c"(wp: rawptr, foldinfo: Wlv_Foldinfo, lnum: C.int, attr: C.int, fdc: C.int, is_virt: bool, wlv_off: ^C.int, out_vcol: [^]C.int, out_buffer: [^]u32) {
	closed := foldinfo.fi_level != 0 && foldinfo.fi_lines > 0
	level := foldinfo.fi_level

	// Column too narrow: start at the lowest fitting level, numbers for depth.
	first_level := max(level - fdc - (closed ? 1 : 0) + 1, 1)
	closedcol := min(fdc, level)

	for i: C.int = 0; i < fdc; i += 1 {
		symbol: u32 = 0
		if i >= level {
			symbol = 32 // ' '
		} else if i == closedcol - 1 && closed {
			symbol = (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLDCLOSED_OFF)^
		} else if foldinfo.fi_lnum == lnum && first_level + i >= foldinfo.fi_low_level {
			symbol = (^u32)(uintptr(wp) + W_P_FCS_CHARS_OFF + FCS_FOLDOPEN_OFF)^
		} else {
			symbol = foldcolumn_sep_char_o(first_level, i, wp)
		}

		// Don't show foldopen/foldclose twice: fold level of lnum-1.
		if is_virt && foldinfo.fi_level != 0 && foldinfo.fi_lnum == lnum {
			outer_level := max(foldinfo.fi_low_level - 1, 0)
			outer_first_level := max(outer_level - fdc + 1, 1)
			if i >= outer_level {
				symbol = 32 // ' '
			} else {
				symbol = foldcolumn_sep_char_o(outer_first_level, i, wp)
			}
		}

		vcol: C.int = -3
		if i >= level {
			vcol = -1
		} else if i == closedcol - 1 && closed {
			vcol = -2
		}
		if out_buffer != nil {
			out_vcol[i] = vcol
			out_buffer[i] = symbol
		} else {
			linebuf_vcol_g[wlv_off^] = vcol
			linebuf_attr_g[wlv_off^] = attr
			linebuf_char_g[wlv_off^] = symbol
			wlv_off^ += 1
		}
	}
}

// 'listchars' extends char for wp, or NUL when unused (plain, C-static).
get_lcs_ext_o :: proc "c"(wp: rawptr) -> u32 {
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
		// Line never continues past the screen with 'wrap'.
		return 0 // NUL
	}
	if ((^C.uint32_t)(uintptr(wp) + W_P_WRAP_FLAGS_OFF)^ & C.uint32_t(kOptFlagInsecure)) != 0 {
		// 'nowrap' from a modeline: forcibly use '>'.
		return 62
	}
	if (^C.int)(uintptr(wp) + W_P_LIST_OFF)^ == 0 {
		return 0
	}
	return (^u32)(uintptr(wp) + W_P_LCS_CHARS_OFF + LCS_EXT_OFF)^
}

// ── Batch 1: winlinevars_T mirror + pure wlv leaves ─────────────────────────
// (win_line itself is a 2200-line engine; leaves port bottom-up. Layouts via
// pahole on drawline.c.o DWARF — winlinevars_T is file-local to drawline.c,
// so no cc-offsetof probe possible; pahole reads the real thing.)

// HlMode (decoration_defs.h:47-53, 4B enum).
HlMode_O :: enum C.int {
	Unknown = 0,
	Replace = 1,
	Combine = 2,
	Blend   = 3,
}

// foldinfo_T (fold_defs.h:8-13, 4×int32 = 16B).
Wlv_Foldinfo :: struct {
	fi_lnum:      C.int, // 0
	fi_level:     C.int, // 4
	fi_low_level: C.int, // 8
	fi_lines:     C.int, // 12
}
#assert(size_of(Wlv_Foldinfo) == 16)

// SignTextAttrs (pahole: text[2]@0/8B, hl_id@8/4B = 12B).
Wlv_SignTextAttrs :: struct {
	text:  [2]u32, // 0
	hl_id: C.int,  // 8
}
#assert(size_of(Wlv_SignTextAttrs) == 12)

// winlinevars_T (pahole: 336B; holes after need_showbreak@88[3B],
// need_lbr@272[7B], reset_extra_attr@316[3B]).
WinLineVars :: struct {
	lnum:               C.int,              // 0
	foldinfo:           Wlv_Foldinfo,       // 4
	startrow:           C.int,              // 20
	row:                C.int,              // 24
	vcol:               C.int,              // 28 (colnr_T)
	col:                C.int,              // 32
	boguscols:          C.int,              // 36
	old_boguscols:      C.int,              // 40
	vcol_off_co:        C.int,              // 44
	off:                C.int,              // 48
	cul_attr:           C.int,              // 52
	line_attr:          C.int,              // 56
	line_attr_lowprio:  C.int,              // 60
	sign_num_attr:      C.int,              // 64
	prev_num_attr:      C.int,              // 68
	sign_cul_attr:      C.int,              // 72
	fromcol:            C.int,              // 76
	tocol:              C.int,              // 80
	vcol_sbr:           C.int,              // 84 (colnr_T)
	need_showbreak:     bool,               // 88
	_pad89:             [3]u8,
	char_attr:          C.int,              // 92
	n_extra:            C.int,              // 96
	n_attr:             C.int,              // 100
	p_extra:            ^u8,                // 104
	extra_attr:         C.int,              // 112
	sc_extra:           u32,                // 116 (schar_T)
	sc_final:           u32,                // 120 (schar_T)
	extra_for_extmark:  bool,               // 124
	extra:              [11]u8,             // 125
	diff_hlf:           C.int,              // 136 (hlf_T)
	n_virt_lines:       C.int,              // 140
	n_virt_below:       C.int,              // 144
	filler_lines:       C.int,              // 148
	filler_todo:        C.int,              // 152
	virt_below_skip:    C.int,              // 156
	filler_lines_skip:  C.int,              // 160
	sattrs:             [9]Wlv_SignTextAttrs, // 164 (SIGN_SHOW_MAX=9)
	need_lbr:           bool,               // 272
	_pad273:            [7]u8,
	virt_inline:        Kvec_VT,            // 280 (VirtText kvec, 24B)
	virt_inline_i:      C.size_t,           // 304
	virt_inline_hl_mode: HlMode_O,          // 312
	reset_extra_attr:   bool,               // 316
	_pad317:            [3]u8,
	skip_cells:         C.int,              // 320
	skipped_cells:      C.int,              // 324
	color_cols:         [^]C.int,           // 328
}
#assert(size_of(WinLineVars) == 336)

W_P_CUC_OFF :: 1056 // w_p_cuc (int)

// Advance wlv->color_cols past columns before vcol (plain, C-static).
advance_color_col_o :: proc "c"(wlv: ^WinLineVars, vcol: C.int) {
	if wlv.color_cols != nil {
		for wlv.color_cols[0] >= 0 && vcol > wlv.color_cols[0] {
			wlv.color_cols = ([^]C.int)(uintptr(wlv.color_cols) + size_of(C.int))
		}
		if wlv.color_cols[0] < 0 {
			wlv.color_cols = nil
		}
	}
}

// Fold concealed-column compensation back into the counters
// (plain, C-static).
fix_for_boguscols_o :: proc "c"(wlv: ^WinLineVars) {
	wlv.n_extra += wlv.vcol_off_co
	wlv.vcol -= wlv.vcol_off_co
	wlv.vcol_off_co = 0
	wlv.col -= wlv.boguscols
	wlv.old_boguscols = wlv.boguscols
	wlv.boguscols = 0
}

// Rightmost column needing colorcolumn/cursorcolumn highlight
// (plain, C-static).
get_rightmost_vcol_o :: proc "c"(wp: rawptr, color_cols: [^]C.int) -> C.int {
	ret: C.int = 0

	if (^C.int)(uintptr(wp) + W_P_CUC_OFF)^ != 0 {
		ret = (^C.int)(uintptr(wp) + W_VIRTCOL_OFF)^
	}

	if color_cols != nil {
		// Rightmost colorcolumn to possibly draw.
		i := 0
		for color_cols[i] >= 0 {
			ret = max(ret, color_cols[i])
			i += 1
		}
	}

	return ret
}
