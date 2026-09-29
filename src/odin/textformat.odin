package main

import C "core:c"
import "base:runtime"

// textformat.c port: gq/internal/auto-format engine.
// Publics are @(export); paragraph walkers are _o plains.

foreign _ {
	@(link_name = "get_nolist_virtcol")
	get_nolist_virtcol_e :: proc "c" () -> C.int ---
	@(link_name = "get_number_indent")
	get_number_indent_e :: proc "c" (lnum: C.int) -> C.int ---
	@(link_name = "get_lisp_indent")
	get_lisp_indent_e :: proc "c" () -> C.int ---
	@(link_name = "get_expr_indent")
	get_expr_indent_e :: proc "c" () -> C.int ---
	@(link_name = "get_c_indent")
	get_c_indent_e :: proc "c" () -> C.int ---
	@(link_name = "cindent_on")
	cindent_on_e :: proc "c" () -> C.int ---
	@(link_name = "change_indent")
	change_indent_e :: proc "c" (type: C.int, amount: C.int, round: bool, keep_zero: bool) -> bool ---
	@(link_name = "del_bytes")
	del_bytes_e :: proc "c" (count: C.int, fixpos_arg: bool, use_delcombine: bool) -> C.int ---
	@(link_name = "open_line")
	open_line_e :: proc "c" (dir: C.int, flags: C.int, second_line_indent: C.int, did_do_comment: ^bool) -> bool ---
	@(link_name = "ins_str")
	ins_str_e :: proc "c" (s: ^u8, slen: C.size_t) ---
	@(link_name = "ins_bytes")
	ins_bytes_e :: proc "c" (p: ^u8) ---
	@(link_name = "insertchar")
	insertchar_e :: proc "c" (c: C.int, flags: C.int, second_indent: C.int) ---
	@(link_name = "backspace_until_column")
	backspace_until_column_e :: proc "c" (col: C.int) ---
	@(link_name = "del_char")
	del_char_e :: proc "c" (fixpos: bool) -> C.int ---
	@(link_name = "undisplay_dollar")
	undisplay_dollar_e :: proc "c" () ---
	@(link_name = "startPS")
	startPS_e :: proc "c" (lnum: C.int, para: C.int, both: bool) -> bool ---
	@(link_name = "set_can_cindent")
	set_can_cindent_e :: proc "c" (val: bool) ---
	@(link_name = "utf_allow_break_before")
	utf_allow_break_before_e :: proc "c" (cc: C.int) -> bool ---
	@(link_name = "utf_allow_break_after")
	utf_allow_break_after_e :: proc "c" (cc: C.int) -> bool ---
	@(link_name = "utf_allow_break")
	utf_allow_break_e :: proc "c" (cc: C.int, ncc: C.int) -> bool ---
	@(link_name = "did_ai")
	did_ai_g: bool
	@(link_name = "did_si")
	did_si_g: bool
	@(link_name = "can_si")
	can_si_g: bool
	@(link_name = "can_si_back")
	can_si_back_g: bool
	@(link_name = "replace_offset")
	replace_offset_g: C.int
	@(link_name = "old_indent")
	old_indent_g: C.int
	@(link_name = "Insstart")
	Insstart_g: Pos_T
}

FO_WRAP_O :: 't'
FO_WRAP_COMS_O :: 'c'
FO_Q_COMS_O :: 'q'
FO_Q_NUMBER_O :: 'n'
FO_Q_SECOND_O :: '2'
FO_INS_VI_O :: 'v'
FO_INS_BLANK_O :: 'b'
FO_MBYTE_BREAK_O :: 'm'
FO_ONE_LETTER_O :: '1'
FO_WHITE_PAR_O :: 'w'
FO_AUTO_O :: 'a'
FO_RIGOROUS_TW_O :: ']'
FO_PERIOD_ABBR_O :: 'p'

INSCHAR_FORMAT_O :: 1
INSCHAR_DO_COM_O :: 2
INSCHAR_NO_FEX_O :: 8
INSCHAR_COM_LIST_O :: 16

OPENLINE_DELSPACES_O :: 0x01
OPENLINE_DO_COM_O :: 0x02
OPENLINE_KEEPTRAIL_O :: 0x04
OPENLINE_MARKFIX_O :: 0x08
OPENLINE_COM_LIST_O :: 0x10
OPENLINE_FORMAT_O :: 0x20

COM_START_O :: 's'
COM_MIDDLE_O :: 'm'
COM_END_O :: 'e'
COM_FIRST_O :: 'f'

MODE_VREPLACE_O :: 0x310
SIN_CHANGED_O :: 1
INDENT_SET_O :: 1

@(private = "file")
did_add_space_g: bool

// True if format option x is in effect (never when 'paste').
@(export)
has_format_option :: proc "c" (x: C.int) -> bool {
	context = runtime.default_context()
	if p_paste_g != 0 {
		return false
	}
	fo := (^rawptr)(uintptr(curbuf) + B_P_FO_OFF)^
	return _vim_strchr(transmute(cstring)(fo), x) != nil
}

// White char that can start a line break (not composing-double).
whitechar_o :: proc "c" (cc: C.int) -> bool {
	context = runtime.default_context()
	// NB: compare on C.int, not u8(cc) — multibyte chars like U+0120
	// truncate to 0x20 and would falsely match (C checks int equality).
	if cc != ' ' && cc != '\t' {
		return false
	}
	next := transmute(cstring)((^u8)(uintptr(get_cursor_pos_ptr()) + 1))
	return !utf_iscomposing_first(utf_ptr2char(next))
}

// Blank/comment-end lines are left untouched by formatting.
fmt_check_par_o :: proc "c" (lnum: C.int, leader_len: ^C.int, leader_flags: ^^u8, do_comments: bool) -> C.int {
	context = runtime.default_context()
	flags: ^u8 = nil
	ptr := ml_get(lnum)
	if do_comments {
		leader_len^ = get_leader_len(ptr, transmute(^C.int)(&flags), false, true)
	} else {
		leader_len^ = 0
	}
	if leader_len^ > 0 {
		f := flags
		for ([^]u8)(f)[0] != 0 && ([^]u8)(f)[0] != ':' && ([^]u8)(f)[0] != COM_END_O {
			f = (^u8)(uintptr(f) + 1)
		}
		flags = f
	}
	leader_flags^ = flags
	after := ([^]u8)(rawptr(uintptr(rawptr(ptr)) + uintptr(leader_len^)))[0]
	if after == 0 {
		return 1
	}
	if leader_len^ > 0 && ([^]u8)(flags)[0] == COM_END_O {
		return 1
	}
	if startPS_e(lnum, 0, false) {
		return 1
	}
	return 0
}

// True if line lnum ends in a white character.
ends_in_white_o :: proc "c" (lnum: C.int) -> bool {
	context = runtime.default_context()
	s := ml_get(lnum)
	if ([^]u8)(s)[0] == 0 {
		return false
	}
	l := ml_get_len_r2(lnum) - 1
	return ascii_iswhite(([^]u8)(s)[l])
}

// True if the two comment leaders match.
same_leader_o :: proc "c" (lnum: C.int, leader1_len: C.int, leader1_flags: ^u8, leader2_len: C.int, leader2_flags: ^u8) -> bool {
	context = runtime.default_context()
	idx1: C.int = 0
	idx2: C.int = 0
	if leader1_len == 0 {
		return leader2_len == 0
	}
	if leader1_flags != nil {
		p := leader1_flags
		for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != ':' {
			ch := ([^]u8)(p)[0]
			if ch == COM_FIRST_O {
				return leader2_len == 0
			}
			if ch == COM_END_O {
				return false
			}
			if ch == COM_START_O {
				if ml_get_len_r2(lnum) <= leader1_len {
					return false
				}
				if leader2_flags == nil || leader2_len == 0 {
					return false
				}
				p = leader2_flags
				for ([^]u8)(p)[0] != 0 && ([^]u8)(p)[0] != ':' {
					if ([^]u8)(p)[0] == COM_MIDDLE_O {
						return true
					}
					p = (^u8)(uintptr(p) + 1)
				}
				return false
			}
			p = (^u8)(uintptr(p) + 1)
		}
	}
	line1 := xstrnsave_c(transmute(cstring)(ml_get(lnum)), C.size_t(ml_get_len_r2(lnum)))
	for ascii_iswhite(([^]u8)(line1)[idx1]) {
		idx1 += 1
	}
	line2 := ml_get(lnum + 1)
	for idx2 < leader2_len {
		if !ascii_iswhite(([^]u8)(line2)[idx2]) {
			if ([^]u8)(line1)[idx1] != ([^]u8)(line2)[idx2] {
				break
			}
			idx1 += 1
		} else {
			for ascii_iswhite(([^]u8)(line1)[idx1]) {
				idx1 += 1
			}
		}
		idx2 += 1
	}
	xfree(rawptr(line1))
	return idx2 == leader2_len && idx1 == leader1_len
}

// True when a paragraph starts in line lnum.
paragraph_start_o :: proc "c" (lnum: C.int) -> bool {
	context = runtime.default_context()
	leader_len: C.int = 0
	leader_flags: ^u8 = nil
	next_leader_len: C.int = 0
	next_leader_flags: ^u8 = nil
	if lnum <= 1 {
		return true
	}
	p := ml_get(lnum - 1)
	if ([^]u8)(p)[0] == 0 {
		return true
	}
	do_comments := has_format_option(FO_Q_COMS_O)
	if fmt_check_par_o(lnum - 1, &leader_len, &leader_flags, do_comments) != 0 {
		return true
	}
	if fmt_check_par_o(lnum, &next_leader_len, &next_leader_flags, do_comments) != 0 {
		return true
	}
	if has_format_option(FO_WHITE_PAR_O) && !ends_in_white_o(lnum - 1) {
		return true
	}
	if has_format_option(FO_Q_NUMBER_O) && get_number_indent_e(lnum) > 0 {
		return true
	}
	if !same_leader_o(lnum - 1, leader_len, leader_flags, next_leader_len, next_leader_flags) {
		return true
	}
	return false
}

// Textwidth for formatting ('tw', else 'wm', else 0; ff forces default).
@(export)
comp_textwidth :: proc "c" (ff: bool) -> C.int {	context = runtime.default_context()
	textwidth := C.int((^C.longlong)(uintptr(curbuf) + B_P_TW_OFF2)^)
	if textwidth == 0 && (^C.longlong)(uintptr(curbuf) + B_P_WM_OFF2)^ != 0 {
		textwidth = (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - C.int((^C.longlong)(uintptr(curbuf) + B_P_WM_OFF2)^)
		textwidth -= win_fdccol_count(curwin)
		textwidth -= (^C.int)(uintptr(curwin) + W_SCWIDTH_OFF)^
		if (^C.int)(uintptr(curwin) + W_P_NU_OFF)^ != 0 || (^C.int)(uintptr(curwin) + W_P_RNU_OFF)^ != 0 {
			textwidth -= 8
		}
	}
	if textwidth < 0 {
		textwidth = 0
	}
	if ff && textwidth == 0 {
		textwidth = (^C.int)(uintptr(curwin) + W_VIEW_WIDTH_OFF)^ - 1
		if textwidth > 79 {
			textwidth = 79
		}
	}
	return textwidth
}

// Format text at the current insert position.
@(export)
internal_format :: proc "c" (textwidth: C.int, second_indent_in: C.int, flags: C.int, format_only: bool, c: C.int) {
	context = runtime.default_context()
	second_indent := second_indent_in
	cc: C.int
	save_char: u8 = 0
	haveto_redraw := false
	fo_ins_blank := has_format_option(FO_INS_BLANK_O)
	fo_multibyte := has_format_option(FO_MBYTE_BREAK_O)
	fo_rigor_tw := has_format_option(FO_RIGOROUS_TW_O)
	fo_white_par := has_format_option(FO_WHITE_PAR_O)
	first_line := true
	leader_len: C.int
	no_leader := false
	do_comments := (flags & INSCHAR_DO_COM_O) != 0
	has_lbr := (^C.int)(uintptr(curwin) + W_P_LBR_OFF)^
	(^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ = 0
	if (^C.int)(uintptr(curbuf) + B_P_AI_OFF)^ == 0 && (State & VREPLACE_FLAG_O) == 0 {
		cc = gchar_cursor()
		if cc == ' ' || cc == '\t' {
			save_char = u8(cc)
			pchar_cursor('x')
		}
	}
	for !got_int {
		startcol: C.int
		wantcol: C.int
		foundcol: C.int
		end_foundcol: C.int = 0
		orig_col: C.int = 0
		saved_text: ^u8 = nil
		col: C.int
		did_do_comment := false
		vc := get_nolist_virtcol_e()
		if c != 0 {
			vc += char2cells(c)
		} else {
			vc += char2cells(gchar_cursor())
		}
		if vc <= textwidth {
			break
		}
		if no_leader {
			do_comments = false
		} else if (flags & INSCHAR_FORMAT_O) == 0 && has_format_option(FO_WRAP_COMS_O) {
			do_comments = true
		}
		if do_comments {
			line := get_cursor_line_ptr()
			leader_len = get_leader_len(line, nil, false, true)
			if leader_len == 0 && (^C.int)(uintptr(curbuf) + B_P_CIN_OFF)^ != 0 {
				comment_start := check_linecomment_r(line)
				if comment_start != MAXCOL {
					leader_len = get_leader_len((^u8)(uintptr(line) + uintptr(comment_start)), nil, false, true)
					if leader_len != 0 {
						leader_len += comment_start
					}
				}
			}
		} else {
			leader_len = 0
		}
		if leader_len == 0 {
			no_leader = true
		}
		if (flags & INSCHAR_FORMAT_O) == 0 && leader_len == 0 && !has_format_option(FO_WRAP_O) {
			break
		}
		startcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
		if startcol == 0 {
			break
		}
		coladvance(curwin, textwidth)
		wantcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = startcol
		foundcol = 0
		skip_pos: C.int = 0
		for (!fo_ins_blank && !has_format_option(FO_INS_VI_O)) || (flags & INSCHAR_FORMAT_O) != 0 || (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ != Insstart_g.lnum || (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ >= Insstart_g.col {
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == startcol && c != 0 {
				cc = c
			} else {
				cc = gchar_cursor()
			}
			if whitechar_o(cc) {
				end_col := (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				wcc: C.int = 0
				for (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 && whitechar_o(cc) {
					dec_cursor()
					cc = gchar_cursor()
					if wcc < 2 {
						wcc += 1
					}
				}
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == 0 && whitechar_o(cc) {
					break
				}
				if has_format_option(FO_PERIOD_ABBR_O) && cc == '.' && wcc < 2 {
					continue
				}
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ < leader_len {
					break
				}
				if has_format_option(FO_ONE_LETTER_O) {
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == 0 {
						break
					}
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ <= leader_len {
						break
					}
					col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
					dec_cursor()
					cc = gchar_cursor()
					if whitechar_o(cc) {
						continue
					}
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
				}
				inc_cursor()
				end_foundcol = end_col + 1
				foundcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ <= wantcol {
					break
				}
			} else if ((cc >= 0x100 || !utf_allow_break_before_e(cc)) && fo_multibyte) {
				ncc: C.int
				allow_break: bool
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ != startcol {
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ < leader_len {
						break
					}
					col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
					inc_cursor()
					ncc = gchar_cursor()
					allow_break = utf_allow_break_e(cc, ncc)
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ != skip_pos && allow_break {
						foundcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
						end_foundcol = foundcol
						if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ <= wantcol {
							break
						}
					}
					(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
				}
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == 0 {
					break
				}
				ncc = cc
				col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				dec_cursor()
				cc = gchar_cursor()
				if whitechar_o(cc) {
					continue
				}
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ < leader_len {
					break
				}
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
				skip_pos = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
				allow_break = utf_allow_break_e(cc, ncc)
				if allow_break {
					foundcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
					end_foundcol = foundcol
				}
				if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ <= wantcol {
					ncc_allow_break := utf_allow_break_before_e(ncc)
					if allow_break {
						break
					}
					if !ncc_allow_break && !fo_rigor_tw {
						if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == startcol {
							end_foundcol = 0
							foundcol = 0
							break
						}
						col = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
						inc_cursor()
						cc = ncc
						ncc = gchar_cursor()
						if ncc == 0 {
							ncc = c
						}
						allow_break = utf_allow_break_e(cc, ncc)
						if allow_break {
							if ncc == 0 {
								end_foundcol = 0
								foundcol = 0
							} else {
								end_foundcol = (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
								foundcol = end_foundcol
							}
							break
						}
						(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = col
					}
				}
			}
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == 0 {
				break
			}
			dec_cursor()
		}
		if foundcol == 0 {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = startcol
			break
		}
		undisplay_dollar_e()
		if (State & VREPLACE_FLAG_O) != 0 {
			orig_col = startcol
		} else {
			replace_offset_g = startcol - end_foundcol
		}
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = foundcol
		cc = gchar_cursor()
		for whitechar_o(cc) && (!fo_white_par || (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ < startcol) {
			inc_cursor()
			cc = gchar_cursor()
		}
		startcol -= (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^
		if startcol < 0 {
			startcol = 0
		}
		if (State & VREPLACE_FLAG_O) != 0 {
			saved_text = xstrnsave_c(transmute(cstring)(get_cursor_pos_ptr()), C.size_t(get_cursor_pos_len()))
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = orig_col
			([^]u8)(saved_text)[startcol] = 0
			if !fo_white_par {
				backspace_until_column_e(foundcol)
			}
		} else {
			if !fo_white_par {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = foundcol
			}
		}
		ol_flags: C.int = OPENLINE_DELSPACES_O + OPENLINE_MARKFIX_O
		if fo_white_par {
			ol_flags += OPENLINE_KEEPTRAIL_O
		}
		if do_comments {
			ol_flags += OPENLINE_DO_COM_O
		}
		ol_flags += OPENLINE_FORMAT_O
		if (flags & INSCHAR_COM_LIST_O) != 0 {
			ol_flags += OPENLINE_COM_LIST_O
		}
		ol_indent := old_indent_g
		if (flags & INSCHAR_COM_LIST_O) != 0 {
			ol_indent = second_indent
		}
		open_line_e(FORWARD_O, ol_flags, ol_indent, &did_do_comment)
		if (flags & INSCHAR_COM_LIST_O) == 0 {
			old_indent_g = 0
		}
		if did_do_comment {
			no_leader = false
		}
		replace_offset_g = 0
		if first_line {
			if (flags & INSCHAR_COM_LIST_O) == 0 {
				if second_indent < 0 && has_format_option(FO_Q_NUMBER_O) {
					second_indent = get_number_indent_e((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1)
				}
				if second_indent >= 0 {
					if (State & VREPLACE_FLAG_O) != 0 {
						change_indent_e(INDENT_SET_O, second_indent, false, true)
					} else if leader_len > 0 && second_indent - leader_len > 0 {
						padding := second_indent - leader_len
						for i: C.int = 0; i < padding; i += 1 {
							ins_str_e(transmute(^u8)(cstring(" ")), 1)
						}
					} else {
						set_indent_r(second_indent, SIN_CHANGED_O)
					}
				}
			}
			first_line = false
		}
		if (State & VREPLACE_FLAG_O) != 0 {
			ins_bytes_e(saved_text)
			xfree(rawptr(saved_text))
		} else {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ += startcol
			len := get_cursor_line_len()
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > len {
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = len
			}
		}
		haveto_redraw = true
		set_can_cindent_e(true)
		did_ai_g = false
		did_si_g = false
		can_si_g = false
		can_si_back_g = false
		line_breakcheck()
	}
	if save_char != 0 {
		pchar_cursor(save_char)
	}
	(^C.int)(uintptr(curwin) + W_P_LBR_OFF)^ = has_lbr
	if !format_only && haveto_redraw {
		update_topline_r(curwin)
		redraw_curbuf_later(UPD_VALID_O)
	}
}

OAP_END_ADJUSTED_O :: 18
OAP_CURSOR_START_O :: 44
UPD_INVERTED_O :: 20
kBufOptFormatexpr_O :: 36

// Format from the current line to end of paragraph (auto-format).
@(export)
auto_format :: proc "c" (trailblank: bool, prev_line: bool) {
	context = runtime.default_context()
	if !has_format_option(FO_AUTO_O) {
		return
	}
	pos := (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	old := get_cursor_line_ptr()
	check_auto_format(false)
	wasatend := pos.col == get_cursor_line_len()
	if ([^]u8)(old)[0] != 0 && !trailblank && wasatend {
		dec_cursor()
		cc := gchar_cursor()
		if (cc != ' ' && cc != '\t') && (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ > 0 && has_format_option(FO_ONE_LETTER_O) {
			dec_cursor()
		}
		cc = gchar_cursor()
		if whitechar_o(cc) {
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			return
		}
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
	}
	if ([^]u8)(old)[0] != 0 && !trailblank && !wasatend && pos.col > 0 && (State & MODE_INSERT) != 0 {
		line := get_cursor_line_ptr()
		if whitechar_o(C.int(([^]u8)(line)[pos.col - 1])) {
			(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = pos
			return
		}
	}
	if has_format_option(FO_WRAP_COMS_O) && !has_format_option(FO_WRAP_O) && get_leader_len(old, nil, false, true) == 0 {
		return
	}
	if prev_line && !paragraph_start_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^) {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
		if u_save_cursor() == FAIL {
			return
		}
	}
	saved_cursor = pos
	format_lines(-1, false)
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = saved_cursor
	saved_cursor.lnum = 0
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
		coladvance(curwin, MAXCOL)
	} else {
		check_cursor_col(curwin)
	}
	if !wasatend && has_format_option(FO_WHITE_PAR_O) {
		linep := get_cursor_line_ptr()
		len := get_cursor_line_len()
		if (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ == len {
			plinep := xstrnsave_c(transmute(cstring)(linep), C.size_t(len) + 2)
			([^]u8)(plinep)[len] = ' '
			([^]u8)(plinep)[len + 1] = 0
			ml_replace_c((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, plinep, false)
			did_add_space_g = true
		} else {
			check_auto_format(false)
		}
	}
	check_cursor(curwin)
}

// Delete the space added by auto_format, if still there.
@(export)
check_auto_format :: proc "c" (end_insert: bool) {
	context = runtime.default_context()
	if !did_add_space_g {
		return
	}
	cc := gchar_cursor()
	if !whitechar_o(cc) {
		did_add_space_g = false
	} else {
		c := C.int(' ')
		if !end_insert {
			inc_cursor()
			c = gchar_cursor()
			dec_cursor()
		}
		if c != 0 {
			del_char_e(false)
			did_add_space_g = false
		}
	}
}

// Implementation of the format operator 'gq'.
@(export)
op_format :: proc "c" (oap_raw: rawptr, keep_cursor: bool) {
	context = runtime.default_context()
	old_line_count := (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^
	start := (^Pos_T)(uintptr(oap_raw) + OAP_START)^
	end := (^Pos_T)(uintptr(oap_raw) + OAP_END)^
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = (^Pos_T)(uintptr(oap_raw) + OAP_CURSOR_START_O)^
	if u_save(start.lnum - 1, end.lnum + 1) == FAIL {
		return
	}
	(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = start
	if (^bool)(uintptr(oap_raw) + OAP_IS_VISUAL)^ {
		redraw_curbuf_later(UPD_INVERTED_O)
	}
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_START)^ = start
	}
	if keep_cursor {
		saved_cursor = (^Pos_T)(uintptr(oap_raw) + OAP_CURSOR_START_O)^
	}
	format_lines((^C.int)(uintptr(oap_raw) + OAP_LINE_COUNT)^, keep_cursor)
	if (^bool)(uintptr(oap_raw) + OAP_END_ADJUSTED_O)^ && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
	}
	beginline(BL_WHITE + BL_FIX)
	old_line_count = (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ - old_line_count
	msgmore_r(old_line_count)
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS_O) == 0 {
		(^Pos_T)(uintptr(curbuf) + B_OP_END)^ = (^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^
	}
	if keep_cursor {
		(^Pos_T)(uintptr(curwin) + W_CURSOR_OFF)^ = saved_cursor
		saved_cursor.lnum = 0
		check_cursor(curwin)
	}
	if (^bool)(uintptr(oap_raw) + OAP_IS_VISUAL)^ {
		wp := firstwin
		for wp != nil {
			if (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ != 0 {
				if (^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ > (^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ {
					(^C.int)(uintptr(wp) + W_OLD_CURSOR_LNUM_OFF)^ += old_line_count
				} else {
					(^C.int)(uintptr(wp) + W_OLD_VISUAL_LNUM_OFF)^ += old_line_count
				}
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
}

// Format operator using 'formatexpr', fallback to internal.
@(export)
op_formatexpr :: proc "c" (oap_raw: rawptr) {
	context = runtime.default_context()
	if (^bool)(uintptr(oap_raw) + OAP_IS_VISUAL)^ {
		redraw_curbuf_later(UPD_INVERTED_O)
	}
	start := (^Pos_T)(uintptr(oap_raw) + OAP_START)^
	if fex_format(start.lnum, C.long((^C.int)(uintptr(oap_raw) + OAP_LINE_COUNT)^), 0) != 0 {
		op_format(oap_raw, false)
	}
}

// Evaluate 'formatexpr' for line lnum.
@(export)
fex_format :: proc "c" (lnum: C.int, count: C.long, c: C.int) -> C.int {
	context = runtime.default_context()
	use_sandbox := was_set_insecurely(curwin, kOptFormatexpr_E, OPT_LOCAL_S) != 0
	save_sctx := current_sctx_buf
	set_vim_var_nr(VV_LNUM_F, i64(lnum))
	set_vim_var_nr(VV_COUNT_O, i64(count))
	set_vim_var_char(c)
	fex := xstrdup((^u8)((^rawptr)(uintptr(curbuf) + B_P_FEX_OFF)^))
	for i := 0; i < 24; i += 1 {
		current_sctx_buf[i] = ([^]u8)(rawptr(uintptr(curbuf) + B_P_SCRIPT_CTX_OFF + uintptr(C.int(kBufOptFormatexpr_O) * 24)))[i]
	}
	if use_sandbox {
		sandbox += 1
	}
	r := eval_to_number(transmute(cstring)(fex), true)
	if use_sandbox {
		sandbox -= 1
	}
	set_vim_var_string(VV_CHAR_O, nil, -1)
	xfree(rawptr(fex))
	current_sctx_buf = save_sctx
	return C.int(r)
}

// Format line_count lines from the cursor (negative: to end of paragraph).
@(export)
format_lines :: proc "c" (line_count: C.int, avoid_fex: bool) {
	context = runtime.default_context()
	is_not_par: bool
	next_is_not_par: bool
	is_end_par: bool
	prev_is_end_par := false
	next_is_start_par := false
	leader_len: C.int = 0
	next_leader_len: C.int
	leader_flags: ^u8 = nil
	next_leader_flags: ^u8 = nil
	advance := true
	second_indent: C.int = -1
	first_par_line := true
	smd_save: C.int
	count: C.long
	need_set_indent := true
	first_line := (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^
	force_format := false
	old_state := State
	max_len := comp_textwidth(true) * 3
	do_comments := has_format_option(FO_Q_COMS_O)
	do_comments_list: C.int = 0
	do_second_indent := has_format_option(FO_Q_SECOND_O)
	do_number_indent := has_format_option(FO_Q_NUMBER_O)
	do_trail_white := has_format_option(FO_WHITE_PAR_O)
	if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ > 1 {
		is_not_par = fmt_check_par_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1, &leader_len, &leader_flags, do_comments) != 0
	} else {
		is_not_par = true
	}
	next_is_not_par = fmt_check_par_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, &next_leader_len, &next_leader_flags, do_comments) != 0
	is_end_par = is_not_par || next_is_not_par
	if !is_end_par && do_trail_white {
		is_end_par = !ends_in_white_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ - 1)
	}
	(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
	count = C.long(line_count)
	for count != 0 && !got_int {
		if advance {
			(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
			prev_is_end_par = is_end_par
			is_not_par = next_is_not_par
			leader_len = next_leader_len
			leader_flags = next_leader_flags
		}
		if count == 1 || (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
			next_is_not_par = true
			next_leader_len = 0
			next_leader_flags = nil
		} else {
			next_is_not_par = fmt_check_par_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1, &next_leader_len, &next_leader_flags, do_comments) != 0
			if do_number_indent {
				next_is_start_par = get_number_indent_e((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1) > 0
			}
		}
		advance = true
		is_end_par = is_not_par || next_is_not_par || next_is_start_par
		if !is_end_par && do_trail_white {
			is_end_par = !ends_in_white_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
		}
		if is_not_par {
			if line_count < 0 {
				break
			}
		} else {
			if first_par_line && (do_second_indent || do_number_indent) && prev_is_end_par && (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ < (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ {
				if do_second_indent && ml_get_len_r2((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1) != 0 {
					if leader_len == 0 && next_leader_len == 0 {
						second_indent = get_indent_lnum_r((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ + 1)
					} else {
						second_indent = next_leader_len
						do_comments_list = 1
					}
				} else if do_number_indent {
					if leader_len == 0 && next_leader_len == 0 {
						second_indent = get_number_indent_e((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
					} else {
						second_indent = get_number_indent_e((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
						do_comments_list = 1
					}
				}
			}
			if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ >= (^C.int)(uintptr(curbuf) + B_ML_LINE_COUNT)^ || !same_leader_o((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, leader_len, leader_flags, next_leader_len, next_leader_flags) {
				if next_leader_flags == nil || ([^]u8)(next_leader_flags)[0] != ':' || ([^]u8)(next_leader_flags)[1] != '/' || ([^]u8)(next_leader_flags)[2] != '/' || check_linecomment_r(get_cursor_line_ptr()) == MAXCOL {
					is_end_par = true
				}
			}
			if is_end_par || force_format {
				if need_set_indent {
					indent: C.int = 0
					if (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ == first_line {
						indent = get_indent_r()
					} else if (^C.int)(uintptr(curbuf) + B_P_LISP_OFF)^ != 0 {
						indent = get_lisp_indent_e()
					} else {
						if cindent_on_e() != 0 {
							if ([^]u8)((^rawptr)(uintptr(curbuf) + B_P_INDE_OFF)^)[0] != 0 {
								indent = get_expr_indent_e()
							} else {
								indent = get_c_indent_e()
							}
						} else {
							indent = get_indent_r()
						}
					}
					set_indent_r(indent, SIN_CHANGED_O)
				}
				State = MODE_NORMAL_O
				coladvance(curwin, MAXCOL)
				for (^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ != 0 {
					cc := gchar_cursor()
					if cc != ' ' && cc != '\t' {
						break
					}
					dec_cursor()
				}
				State = MODE_INSERT
				smd_save = p_smd_g
				p_smd_g = 0
				ins_flags: C.int = INSCHAR_FORMAT_O
				if do_comments {
					ins_flags += INSCHAR_DO_COM_O
				}
				if do_comments && do_comments_list != 0 {
					ins_flags += INSCHAR_COM_LIST_O
				}
				if avoid_fex {
					ins_flags += INSCHAR_NO_FEX_O
				}
				insertchar_e(0, ins_flags, second_indent)
				State = old_state
				p_smd_g = smd_save
				ui_cursor_shape()
				second_indent = -1
				need_set_indent = is_end_par
				if is_end_par {
					if line_count < 0 {
						break
					}
					first_par_line = true
				}
				force_format = false
			}
			if !is_end_par {
				advance = false
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ += 1
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = 0
				if line_count < 0 && u_save_cursor() == FAIL {
					break
				}
				if next_leader_len > 0 {
					del_bytes_e(next_leader_len, false, false)
					mark_col_adjust((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0, 0, -next_leader_len, 0)
				} else if second_indent > 0 {
					indent := getwhitecols_curline()
					if indent > 0 {
						del_bytes_e(indent, false, false)
						mark_col_adjust((^C.int)(uintptr(curwin) + W_CURSOR_OFF)^, 0, 0, -indent, 0)
					}
				}
				(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ -= 1
				if do_join_r(2, true, false, false, false) == FAIL {
					beep_flush_r2()
					break
				}
				first_par_line = false
				force_format = get_cursor_line_len() > max_len
			}
		}
		line_breakcheck()
		count -= 1
	}
}
