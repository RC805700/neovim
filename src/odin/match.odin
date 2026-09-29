package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// match.c port: :match/matchadd highlighting + search-hl engine glue.
// Publics are @(export); list-walk/statics are _o plains.

foreign _ {
	@(link_name = "syn_id2name")
	syn_id2name_e :: proc "c" (id: C.int) -> cstring ---
	@(link_name = "search_first_line")
	search_first_line_g: C.int
	@(link_name = "search_last_line")
	search_last_line_g: C.int
}
SEARCH_HL_PRIORITY :: 0
HLF_L_O :: 8
HLF_LC_O :: 9

E799_S :: "E799: Invalid ID: %ld (must be greater than or equal to 1)"
E801_S :: "E801: ID already taken: %ld"
E802_S :: "E802: Invalid ID: %ld (must be greater than or equal to 1)"
E803_S :: "E803: ID not found: %ld"
E798_S :: "E798: ID is reserved for \":match\": %d"
E798B_S :: "E798: ID is reserved for \"match\": %d"
E5030_S :: "E5030: Empty list at position %d"
E5031_S :: "E5031: List or number required at position %d"
E474_ITEM_S :: "E474: List item %d is either not a dictionary or an empty one"
E474_KEYS_S :: "E474: List item %d is missing one of the required keys"
E_DICTREQ_S :: "E715: Dictionary required"
E_INVALWIN_S :: "E957: Invalid window number"

// llpos_T mirror (12B).
Llpos_T :: struct {
	lnum: C.int,
	col:  C.int,
	len:  C.int,
}
#assert(size_of(Llpos_T) == 12)

// match_T mirror (cc-probed, 232B).
Match_T :: struct {
	rm:         Regmmatch_T,
	buf:        rawptr,
	lnum:       C.int,
	attr:       C.int,
	attr_cur:   C.int,
	first_lnum: C.int,
	startcol:   C.int,
	endcol:     C.int,
	is_addpos:  bool,
	has_cursor: bool,
	_pad:       [6]u8,
	tm:         proftime_T,
}
#assert(size_of(Match_T) == 232)

// matchitem_T mirror (cc-probed, 472B).
Matchitem_T :: struct {
	mit_next:         ^Matchitem_T,
	mit_id:           C.int,
	mit_priority:     C.int,
	mit_pattern:      ^u8,
	mit_match:        Regmmatch_T,
	mit_pos_array:    [^]Llpos_T,
	mit_pos_count:    C.int,
	mit_pos_cur:      C.int,
	mit_toplnum:      C.int,
	mit_botlnum:      C.int,
	mit_hl:           Match_T,
	mit_hlg_id:       C.int,
	mit_conceal_char: C.int,
}
#assert(size_of(Matchitem_T) == 472)

// Match-list head / next-ID for a window.
match_head_o :: proc "c" (wp: rawptr) -> ^Matchitem_T {
	context = runtime.default_context()
	return (^Matchitem_T)((^rawptr)(uintptr(wp) + W_MATCH_HEAD_OFF)^)
}

set_match_head_o :: proc "c" (wp: rawptr, m: ^Matchitem_T) {
	context = runtime.default_context()
	(^rawptr)(uintptr(wp) + W_MATCH_HEAD_OFF)^ = rawptr(m)
}

// Add a match to a window (pattern and/or positions); returns ID or -1.
match_add_o :: proc "c" (wp: rawptr, grp: cstring, pat: cstring, prio: C.int, id_in: C.int, pos_list: rawptr, conceal_char: cstring) -> C.int {
	context = runtime.default_context()
	id := id_in
	rtype: C.int = UPD_SOME_VALID_O
	if ([^]u8)(rawptr(grp))[0] == 0 || (pat != nil && ([^]u8)(rawptr(pat))[0] == 0) {
		return -1
	}
	if id < -1 || id == 0 {
		semsg(cstring(E799_S), C.longlong(id))
		return -1
	}
	if id == -1 {
		id = (^C.int)(uintptr(wp) + W_NEXT_MATCH_ID_OFF)^
		(^C.int)(uintptr(wp) + W_NEXT_MATCH_ID_OFF)^ = id + 1
	} else {
		cur := match_head_o(wp)
		for cur != nil {
			if cur.mit_id == id {
				semsg(cstring(E801_S), C.longlong(id))
				return -1
			}
			cur = cur.mit_next
		}
		if (^C.int)(uintptr(wp) + W_NEXT_MATCH_ID_OFF)^ < id + 100 {
			(^C.int)(uintptr(wp) + W_NEXT_MATCH_ID_OFF)^ = id + 100
		}
	}
	hlg_id := syn_check_group_c(transmute(^u8)(grp), libc.strlen(grp))
	if hlg_id == 0 {
		return -1
	}
	regprog: rawptr = nil
	if pat != nil {
		regprog = vim_regcomp(pat, RE_MAGIC)
		if regprog == nil {
			semsg(e_invarg2, pat)
			return -1
		}
	}
	m := (^Matchitem_T)(xcalloc(1, C.size_t(size_of(Matchitem_T))))
	failed := false
	if pos_list != nil && tv_list_len_o(pos_list) > 0 {
		m.mit_pos_array = ([^]Llpos_T)(xcalloc(C.size_t(tv_list_len_o(pos_list)), C.size_t(size_of(Llpos_T))))
		m.mit_pos_count = tv_list_len_o(pos_list)
	}
	m.mit_id = id
	m.mit_priority = prio
	if pat == nil {
		m.mit_pattern = nil
	} else {
		m.mit_pattern = xstrdup(transmute(^u8)(pat))
	}
	m.mit_hlg_id = hlg_id
	m.mit_match.regprog = regprog
	m.mit_match.rmm_ic = 0
	m.mit_match.rmm_maxcol = 0
	m.mit_conceal_char = 0
	if conceal_char != nil {
		m.mit_conceal_char = utf_ptr2char(conceal_char)
	}
	if pos_list != nil {
		toplnum: C.int = 0
		botlnum: C.int = 0
		i: C.int = 0
		li := (^ListItem)(tv_list_first_o(pos_list))
		for li != nil && !failed {
			next := (^ListItem)(li.li_next)
			lnum: C.int = 0
			col: C.int = 0
			length: C.int = 1
			error := false
			stored := false
			tv := (^Typval_T)(uintptr(li) + 16)
			if tv.v_type == VAR_LIST {
				subl := rawptr(tv.vval)
				subli := (^ListItem)(tv_list_first_o(subl))
				if subli == nil {
					semsg(cstring(E5030_S), tv_list_idx_of_item(pos_list, rawptr(li)))
					failed = true
				} else {
					lnum = C.int(tv_get_number_chk((^Typval_T)(uintptr(subli) + 16), &error))
					if error {
						failed = true
					} else if lnum > 0 {
						m.mit_pos_array[i].lnum = lnum
						subli = (^ListItem)(subli.li_next)
						if subli != nil {
							col = C.int(tv_get_number_chk((^Typval_T)(uintptr(subli) + 16), &error))
							if error {
								failed = true
							} else if col >= 0 {
								subli = (^ListItem)(subli.li_next)
								if subli != nil {
									length = C.int(tv_get_number_chk((^Typval_T)(uintptr(subli) + 16), &error))
									if length < 0 {
										// skip entry (error ignored, faithful)
									} else if error {
										failed = true
									}
								}
								if !failed && length >= 0 {
									m.mit_pos_array[i].col = col
									m.mit_pos_array[i].len = length
									stored = true
								}
							}
						} else {
							// single [lnum]: col stays 0, len stays 1
							stored = true
						}
					}
				}
			} else if tv.v_type == VAR_NUMBER {
				if transmute(C.longlong)(tv.vval) > 0 {
					m.mit_pos_array[i].lnum = C.int(transmute(C.longlong)(tv.vval))
					m.mit_pos_array[i].col = 0
					m.mit_pos_array[i].len = 0
					stored = true
				}
				// NOTE: C leaves lnum at 0 here (top/bot update below
				// uses 0, so no range redraw is set for number entries).
			} else {
				semsg(cstring(E5031_S), tv_list_idx_of_item(pos_list, rawptr(li)))
				failed = true
			}
			if !failed && stored {
				if toplnum == 0 || lnum < toplnum {
					toplnum = lnum
				}
				if botlnum == 0 || lnum >= botlnum {
					botlnum = lnum + 1
				}
				i += 1
			}
			li = next
		}
		if !failed && toplnum != 0 {
			redraw_win_range_later(wp, toplnum, botlnum)
			m.mit_toplnum = toplnum
			m.mit_botlnum = botlnum
			rtype = UPD_VALID_O
		}
	}
	if failed {
		vim_regfree(regprog)
		xfree(rawptr(m.mit_pattern))
		xfree(rawptr(m.mit_pos_array))
		xfree(rawptr(m))
		return -1
	}
	// Insert sorted by ascending priority.
	cur := match_head_o(wp)
	prev := cur
	for cur != nil && prio >= cur.mit_priority {
		prev = cur
		cur = cur.mit_next
	}
	if cur == prev {
		set_match_head_o(wp, m)
	} else {
		prev.mit_next = m
	}
	m.mit_next = cur
	redraw_later(wp, rtype)
	return id
}

// Delete match with ID (perr controls error messages).
match_delete_o :: proc "c" (wp: rawptr, id: C.int, perr: bool) -> C.int {
	context = runtime.default_context()
	cur := match_head_o(wp)
	prev := cur
	rtype: C.int = UPD_SOME_VALID_O
	if id < 1 {
		if perr {
			semsg(cstring(E802_S), C.longlong(id))
		}
		return -1
	}
	for cur != nil && cur.mit_id != id {
		prev = cur
		cur = cur.mit_next
	}
	if cur == nil {
		if perr {
			semsg(cstring(E803_S), C.longlong(id))
		}
		return -1
	}
	if cur == prev {
		set_match_head_o(wp, cur.mit_next)
	} else {
		prev.mit_next = cur.mit_next
	}
	vim_regfree(cur.mit_match.regprog)
	xfree(rawptr(cur.mit_pattern))
	if cur.mit_toplnum != 0 {
		redraw_win_range_later(wp, cur.mit_toplnum, cur.mit_botlnum)
		rtype = UPD_VALID_O
	}
	xfree(rawptr(cur.mit_pos_array))
	xfree(rawptr(cur))
	redraw_later(wp, rtype)
	return 0
}

// Delete all matches in a window.
@(export)
clear_matches :: proc "c" (wp: rawptr) {
	context = runtime.default_context()
	for match_head_o(wp) != nil {
		m := match_head_o(wp).mit_next
		vim_regfree(match_head_o(wp).mit_match.regprog)
		xfree(rawptr(match_head_o(wp).mit_pattern))
		xfree(rawptr(match_head_o(wp).mit_pos_array))
		xfree(rawptr(match_head_o(wp)))
		set_match_head_o(wp, m)
	}
	redraw_later(wp, UPD_SOME_VALID_O)
}

// Match with ID or nil.
get_match_o :: proc "c" (wp: rawptr, id: C.int) -> ^Matchitem_T {
	context = runtime.default_context()
	cur := match_head_o(wp)
	for cur != nil && cur.mit_id != id {
		cur = cur.mit_next
	}
	return cur
}

// Init for prepare_search_hl().
@(export)
init_search_hl :: proc "c" (wp: rawptr, search_hl_raw: rawptr) {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	cur := match_head_o(wp)
	for cur != nil {
		cur.mit_hl.rm = cur.mit_match
		if cur.mit_hlg_id == 0 {
			cur.mit_hl.attr = 0
		} else {
			cur.mit_hl.attr = syn_id2attr_r(cur.mit_hlg_id)
		}
		cur.mit_hl.buf = (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
		cur.mit_hl.lnum = 0
		cur.mit_hl.first_lnum = 0
		cur.mit_hl.tm = profile_setlimit(p_rdt_g)
		cur = cur.mit_next
	}
	search_hl.buf = (^rawptr)(uintptr(wp) + W_BUFFER_OFF)^
	search_hl.lnum = 0
	search_hl.first_lnum = 0
	search_hl.attr = win_hl_attr_o(wp, HLF_L_O)
}

// Positional match in line lnum (1 found, 0 none).
next_search_hl_pos_o :: proc "c" (shl: ^Match_T, lnum: C.int, match: ^Matchitem_T, mincol: C.int) -> C.int {
	context = runtime.default_context()
	found: C.int = -1
	for i := match.mit_pos_cur; i < match.mit_pos_count; i += 1 {
		pos := &match.mit_pos_array[i]
		if pos.lnum == 0 {
			break
		}
		if pos.len == 0 && pos.col < mincol {
			continue
		}
		if pos.lnum == lnum {
			if found >= 0 {
				if pos.col < match.mit_pos_array[found].col {
					tmp := pos^
					pos^ = match.mit_pos_array[found]
					match.mit_pos_array[found] = tmp
				}
			} else {
				found = i
			}
		}
	}
	match.mit_pos_cur = 0
	if found >= 0 {
		start := match.mit_pos_array[found].col - 1
		if match.mit_pos_array[found].col == 0 {
			start = 0
		}
		end := start + match.mit_pos_array[found].len
		if match.mit_pos_array[found].col == 0 {
			end = MAXCOL
		}
		shl.lnum = lnum
		shl.rm.startpos[0].lnum = 0
		shl.rm.startpos[0].col = start
		shl.rm.endpos[0].lnum = 0
		shl.rm.endpos[0].col = end
		shl.is_addpos = true
		shl.has_cursor = false
		match.mit_pos_cur = found + 1
		return 1
	}
	return 0
}

// Search for the next hlsearch/match at/after mincol in lnum.
next_search_hl_o :: proc "c" (win: rawptr, search_hl: ^Match_T, shl: ^Match_T, lnum: C.int, mincol: C.int, cur: ^Matchitem_T) {
	context = runtime.default_context()
	matchcol: C.int
	nmatched: C.int = 0
	called_emsg_before := called_emsg
	if (lnum < search_first_line_g || lnum > search_last_line_g) && cur == nil {
		shl.lnum = 0
		return
	}
	if shl.lnum != 0 {
		l := shl.lnum + shl.rm.endpos[0].lnum - shl.rm.startpos[0].lnum
		if lnum > l {
			shl.lnum = 0
		} else if lnum < l || shl.rm.endpos[0].col > mincol {
			return
		}
	}
	for {
		if profile_passed_limit(shl.tm) {
			shl.lnum = 0
			break
		}
		if shl.lnum == 0 {
			matchcol = 0
		} else if _vim_strchr(transmute(cstring)(p_cpo), CPO_SEARCH) == nil || (shl.rm.endpos[0].lnum == 0 && shl.rm.endpos[0].col <= shl.rm.startpos[0].col) {
			matchcol = shl.rm.startpos[0].col
			ml := ml_get_buf(shl.buf, lnum)
			if ([^]u8)(ml)[matchcol] == 0 {
				matchcol += 1
				shl.lnum = 0
				break
			}
			matchcol += utfc_ptr2len(transmute(cstring)((^u8)(uintptr(ml) + uintptr(matchcol))))
		} else {
			matchcol = shl.rm.endpos[0].col
		}
		shl.lnum = lnum
		if shl.rm.regprog != nil {
			regprog_is_copy := shl != search_hl && cur != nil && shl == &cur.mit_hl && cur.mit_match.regprog == cur.mit_hl.rm.regprog
			timed_out: C.int = 0
			nmatched = vim_regexec_multi_r(&shl.rm, win, shl.buf, lnum, matchcol, &shl.tm, &timed_out)
			if regprog_is_copy {
				cur.mit_match.regprog = cur.mit_hl.rm.regprog
			}
			if called_emsg > called_emsg_before || got_int || timed_out != 0 {
				if shl == search_hl {
					vim_regfree(shl.rm.regprog)
					set_no_hlsearch(true)
				}
				shl.rm.regprog = nil
				shl.lnum = 0
				got_int = false
				break
			}
		} else if cur != nil {
			nmatched = next_search_hl_pos_o(shl, lnum, cur, matchcol)
		}
		if nmatched == 0 {
			shl.lnum = 0
			break
		}
		if shl.rm.startpos[0].lnum > 0 || shl.rm.startpos[0].col >= mincol || nmatched > 1 || shl.rm.endpos[0].col > mincol {
			shl.lnum += shl.rm.startpos[0].lnum
			break
		}
	}
}

// Advance to the match in line lnum or past it.
@(export)
prepare_search_hl :: proc "c" (wp: rawptr, search_hl_raw: rawptr, lnum: C.int) {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	cur := match_head_o(wp)
	shl: ^Match_T = nil
	shl_flag := false
	for cur != nil || !shl_flag {
		if !shl_flag {
			shl = search_hl
			shl_flag = true
		} else {
			shl = &cur.mit_hl
		}
		if shl.rm.regprog != nil && shl.lnum == 0 && re_multiline_r(shl.rm.regprog) {
			if shl.first_lnum == 0 {
				shl.first_lnum = lnum
				for shl.first_lnum > (^C.int)(uintptr(wp) + W_TOPLINE_OFF)^ {
					shl.first_lnum -= 1
					if hasFolding(wp, shl.first_lnum - 1, nil, nil) {
						break
					}
				}
			}
			if cur != nil {
				cur.mit_pos_cur = 0
			}
			pos_inprogress := true
			n: C.int = 0
			for shl.first_lnum < lnum && (shl.rm.regprog != nil || (cur != nil && pos_inprogress)) {
				next_search_hl_o(wp, search_hl, shl, shl.first_lnum, n, nil if shl == search_hl else cur)
				if cur == nil || cur.mit_pos_cur == 0 {
					pos_inprogress = false
				}
				if shl.lnum != 0 {
					shl.first_lnum = shl.lnum + shl.rm.endpos[0].lnum - shl.rm.startpos[0].lnum
					n = shl.rm.endpos[0].col
				} else {
					shl.first_lnum += 1
					n = 0
				}
			}
		}
		if shl != search_hl && cur != nil {
			cur = cur.mit_next
		}
	}
}

// has_cursor from cursor position vs match.
check_cur_search_hl_o :: proc "c" (wp: rawptr, shl: ^Match_T) {
	context = runtime.default_context()
	linecount := shl.rm.endpos[0].lnum - shl.rm.startpos[0].lnum
	cursor := (^Pos_T)(uintptr(wp) + W_CURSOR_OFF)^
	if cursor.lnum >= shl.lnum && cursor.lnum <= shl.lnum + linecount && (cursor.lnum > shl.lnum || cursor.col >= shl.rm.startpos[0].col) && (cursor.lnum < shl.lnum + linecount || cursor.col < shl.rm.endpos[0].col) {
		shl.has_cursor = true
	} else {
		shl.has_cursor = false
	}
}

// Prepare hlsearch/match highlighting for one window line.
@(export)
prepare_search_hl_line :: proc "c" (wp: rawptr, lnum: C.int, mincol: C.int, line: ^^u8, search_hl_raw: rawptr, search_attr: ^C.int, search_attr_from_match: ^bool) -> bool {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	cur := match_head_o(wp)
	shl: ^Match_T = nil
	shl_flag := false
	area_highlighting := false
	for cur != nil || !shl_flag {
		if !shl_flag {
			shl = search_hl
			shl_flag = true
		} else {
			shl = &cur.mit_hl
		}
		shl.startcol = MAXCOL
		shl.endcol = MAXCOL
		shl.attr_cur = 0
		shl.is_addpos = false
		shl.has_cursor = false
		if cur != nil {
			cur.mit_pos_cur = 0
		}
		next_search_hl_o(wp, search_hl, shl, lnum, mincol, nil if shl == search_hl else cur)
		line^ = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
		if shl.lnum != 0 && shl.lnum <= lnum {
			if shl.lnum == lnum {
				shl.startcol = shl.rm.startpos[0].col
			} else {
				shl.startcol = 0
			}
			if lnum == shl.lnum + shl.rm.endpos[0].lnum - shl.rm.startpos[0].lnum {
				shl.endcol = shl.rm.endpos[0].col
			} else {
				shl.endcol = MAXCOL
			}
			if shl == search_hl {
				check_cur_search_hl_o(wp, shl)
			}
			if shl.startcol == shl.endcol {
				if ([^]u8)(line^)[shl.endcol] != 0 {
					shl.endcol += utfc_ptr2len(transmute(cstring)((^u8)(uintptr(line^) + uintptr(shl.endcol))))
				} else {
					shl.endcol += 1
				}
			}
			if shl.startcol < mincol {
				shl.attr_cur = shl.attr
				search_attr^ = shl.attr
				search_attr_from_match^ = shl != search_hl
			}
			area_highlighting = true
		}
		if shl != search_hl && cur != nil {
			cur = cur.mit_next
		}
	}
	return area_highlighting
}

// Per-column search/match highlight update.
@(export)
update_search_hl :: proc "c" (wp: rawptr, lnum: C.int, col: C.int, line: ^^u8, search_hl_raw: rawptr, has_match_conc: ^C.int, match_conc: ^C.int, lcs_eol_todo: bool, on_last_col: ^bool, search_attr_from_match: ^bool) -> C.int {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	cur := match_head_o(wp)
	shl: ^Match_T = nil
	shl_flag := false
	search_attr: C.int = 0
	for cur != nil || !shl_flag {
		if !shl_flag && (cur == nil || cur.mit_priority > SEARCH_HL_PRIORITY) {
			shl = search_hl
			shl_flag = true
		} else {
			shl = &cur.mit_hl
		}
		if cur != nil {
			cur.mit_pos_cur = 0
		}
		pos_inprogress := true
		for shl.rm.regprog != nil || (cur != nil && pos_inprogress) {
			if shl.startcol != MAXCOL && col >= shl.startcol && col < shl.endcol {
				next_col := col + utfc_ptr2len(transmute(cstring)((^u8)(uintptr(line^) + uintptr(col))))
				if shl.endcol < next_col {
					shl.endcol = next_col
				}
				if shl == search_hl && shl.has_cursor {
					shl.attr_cur = win_hl_attr_o(wp, HLF_LC_O)
					if shl.attr_cur != shl.attr {
						search_hl_has_cursor_lnum_g = lnum
					}
				} else {
					shl.attr_cur = shl.attr
				}
				if cur != nil && shl != search_hl && syn_name2id_e(cstring("Conceal")) == cur.mit_hlg_id {
					if col == shl.startcol {
						has_match_conc^ = 2
					} else {
						has_match_conc^ = 1
					}
					match_conc^ = cur.mit_conceal_char
				} else {
					has_match_conc^ = 0
				}
			} else if col == shl.endcol {
				shl.attr_cur = 0
				next_search_hl_o(wp, search_hl, shl, lnum, col, nil if shl == search_hl else cur)
				if cur == nil || cur.mit_pos_cur == 0 {
					pos_inprogress = false
				}
				line^ = ml_get_buf((^rawptr)(uintptr(wp) + W_BUFFER_OFF)^, lnum)
				if shl.lnum == lnum {
					shl.startcol = shl.rm.startpos[0].col
					if shl.rm.endpos[0].lnum == 0 {
						shl.endcol = shl.rm.endpos[0].col
					} else {
						shl.endcol = MAXCOL
					}
					if shl == search_hl {
						check_cur_search_hl_o(wp, shl)
					}
					if shl.startcol == shl.endcol {
						p := (^u8)(uintptr(line^) + uintptr(shl.endcol))
						if ([^]u8)(p)[0] == 0 {
							shl.endcol += 1
						} else {
							shl.endcol += utfc_ptr2len(transmute(cstring)(p))
						}
					}
					continue
				}
			}
			break
		}
		if shl != search_hl && cur != nil {
			cur = cur.mit_next
		}
	}
	search_attr_from_match^ = false
	search_attr = search_hl.attr_cur
	cur = match_head_o(wp)
	shl_flag = false
	for cur != nil || !shl_flag {
		if !shl_flag && (cur == nil || cur.mit_priority > SEARCH_HL_PRIORITY) {
			shl = search_hl
			shl_flag = true
		} else {
			shl = &cur.mit_hl
		}
		if shl.attr_cur != 0 {
			search_attr = shl.attr_cur
			on_last_col^ = col + 1 >= shl.endcol
			search_attr_from_match^ = shl != search_hl
		}
		if shl != search_hl && cur != nil {
			cur = cur.mit_next
		}
	}
	if ([^]u8)((^u8)(uintptr(line^) + uintptr(col)))[0] == 0 && ((^C.int)(uintptr(wp) + W_P_LIST_OFF)^ != 0 && !lcs_eol_todo) {
		search_attr = 0
	}
	return search_attr
}

@(export)
get_prevcol_hl_flag :: proc "c" (wp: rawptr, search_hl_raw: rawptr, curcol: C.int) -> bool {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	prevcol := curcol
	base := (^C.int)(uintptr(wp) + W_LEFTCOL_OFF)^
	if (^C.int)(uintptr(wp) + W_P_WRAP_OFF)^ != 0 {
		base = (^C.int)(uintptr(wp) + W_SKIPCOL_OFF)^
	}
	if base > prevcol {
		prevcol += 1
	}
	if !search_hl.is_addpos && (prevcol == search_hl.startcol || (prevcol > search_hl.startcol && search_hl.endcol == MAXCOL)) {
		return true
	}
	cur := match_head_o(wp)
	for cur != nil {
		if !cur.mit_hl.is_addpos && (prevcol == cur.mit_hl.startcol || (prevcol > cur.mit_hl.startcol && cur.mit_hl.endcol == MAXCOL)) {
			return true
		}
		cur = cur.mit_next
	}
	return false
}

// Char-after-text highlight from hlsearch/matches.
@(export)
get_search_match_hl :: proc "c" (wp: rawptr, search_hl_raw: rawptr, col: C.int, char_attr: ^C.int) {
	context = runtime.default_context()
	search_hl := (^Match_T)(search_hl_raw)
	cur := match_head_o(wp)
	shl: ^Match_T = nil
	shl_flag := false
	for cur != nil || !shl_flag {
		if !shl_flag && (cur == nil || cur.mit_priority > SEARCH_HL_PRIORITY) {
			shl = search_hl
			shl_flag = true
		} else {
			shl = &cur.mit_hl
		}
		if col - 1 == shl.startcol && (shl == search_hl || !shl.is_addpos) {
			char_attr^ = shl.attr
		}
		if shl != search_hl && cur != nil {
			cur = cur.mit_next
		}
	}
}

// Parse optional matchadd() dict arg (conceal + window keys).
matchadd_dict_arg_o :: proc "c" (tv: ^Typval_T, conceal_char: ^^u8, win: ^rawptr) -> C.int {
	context = runtime.default_context()
	if tv.v_type != VAR_DICT {
		emsg(cstring(E_DICTREQ_S))
		return FAIL
	}
	di := tv_dict_find(rawptr(tv.vval), cstring("conceal"), 7)
	if di != nil {
		conceal_char^ = transmute(^u8)(tv_get_string((^Typval_T)(uintptr(di))))
	}
	di = tv_dict_find(rawptr(tv.vval), cstring("window"), 6)
	if di == nil {
		return OK
	}
	win^ = find_win_by_nr_or_id((^Typval_T)(uintptr(di)))
	if win^ == nil {
		emsg(cstring(E_INVALWIN_S))
		return FAIL
	}
	return OK
}

// "clearmatches()" function.
@(export)
f_clearmatches :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	win := get_optional_window(argvars, 0)
	if win != nil {
		clear_matches(win)
	}
}

// "getmatches()" function.
@(export)
f_getmatches :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	win := get_optional_window(argvars, 0)
	tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_MAYKNOW_O)
	if win == nil {
		return
	}
	cur := match_head_o(win)
	for cur != nil {
		dict := tv_dict_alloc()
		if cur.mit_match.regprog == nil {
			for i := C.int(0); i < cur.mit_pos_count; i += 1 {
				llpos := &cur.mit_pos_array[i]
				if llpos.lnum == 0 {
					break
				}
				cap := C.ssize_t(1)
				if llpos.col > 0 {
					cap = 3
				}
				l := tv_list_alloc(cap)
				tv_list_append_number(l, C.longlong(llpos.lnum))
				if llpos.col > 0 {
					tv_list_append_number(l, C.longlong(llpos.col))
					tv_list_append_number(l, C.longlong(llpos.len))
				}
				buf: [30]u8
				buf[0] = 'p'
				buf[1] = 'o'
				buf[2] = 's'
				buf[3] = u8(u32('0') + u32(i + 1))
				buf[4] = 0
				// C keys pos1..pos8 by index; single-digit build above is
				// exact for i in 0..7 (pos_count <= 8).
				tv_dict_add_list(dict, transmute(cstring)(&buf[0]), 4, l)
			}
		} else {
			tv_dict_add_str(dict, cstring("pattern"), 7, transmute(cstring)(cur.mit_pattern))
		}
		tv_dict_add_str(dict, cstring("group"), 5, syn_id2name_e(cur.mit_hlg_id))
		tv_dict_add_nr(dict, cstring("priority"), 8, C.longlong(cur.mit_priority))
		tv_dict_add_nr(dict, cstring("id"), 2, C.longlong(cur.mit_id))
		if cur.mit_conceal_char != 0 {
			buf: [7]u8
			buflen := utf_char2bytes(cur.mit_conceal_char, &buf[0])
			buf[buflen] = 0
			tv_dict_add_str_len(dict, cstring("conceal"), 7, transmute(cstring)(&buf[0]), buflen)
		}
		tv_list_append_dict(rawptr(rettv.vval), dict)
		cur = cur.mit_next
	}
}

// "setmatches()" function.
@(export)
f_setmatches :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	s: rawptr = nil
	win := get_optional_window(argvars, 1)
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if argvars.v_type != VAR_LIST {
		emsg(cstring(E_LISTREQ_S))
		return
	}
	if win == nil {
		return
	}
	l := rawptr(argvars.vval)
	li_idx: C.int = 0
	li := (^ListItem)(tv_list_first_o(l))
	for li != nil {
		tv := (^Typval_T)(uintptr(li) + 16)
		d: rawptr = nil
		if tv.v_type != VAR_DICT {
			semsg(cstring(E474_ITEM_S), li_idx)
			return
		}
		d = rawptr(tv.vval)
		if d == nil {
			semsg(cstring(E474_ITEM_S), li_idx)
			return
		}
		if tv_dict_find(d, cstring("group"), 5) == nil || (tv_dict_find(d, cstring("pattern"), 7) == nil && tv_dict_find(d, cstring("pos1"), 4) == nil) || tv_dict_find(d, cstring("priority"), 8) == nil || tv_dict_find(d, cstring("id"), 2) == nil {
			semsg(cstring(E474_KEYS_S), li_idx)
			return
		}
		li_idx += 1
		li = (^ListItem)(li.li_next)
	}
	clear_matches(win)
	match_add_failed := false
	li = (^ListItem)(tv_list_first_o(l))
	for li != nil {
		d := rawptr((^Typval_T)(uintptr(li) + 16).vval)
		di := tv_dict_find(d, cstring("pattern"), 7)
		i: C.int = 0
		if di == nil {
			if s == nil {
				s = tv_list_alloc(9)
			}
			for i = 1; i < 9; i += 1 {
				buf: [30]u8
				buf[0] = 'p'
				buf[1] = 'o'
				buf[2] = 's'
				buf[3] = u8(u32('0') + u32(i))
				buf[4] = 0
				pos_di := tv_dict_find(d, transmute(cstring)(&buf[0]), -1)
				if pos_di != nil {
					if (^C.int)(uintptr(pos_di))^ != VAR_LIST {
						return
					}
					tv_list_append_tv(s, (^Typval_T)(uintptr(pos_di)))
					tv_list_ref_o(s)
				} else {
					break
				}
			}
		}
		group_buf: [NUMBUFLEN]u8
		group := tv_dict_get_string_buf(d, cstring("group"), &group_buf[0])
		priority := C.int(tv_dict_get_number(d, cstring("priority")))
		id := C.int(tv_dict_get_number(d, cstring("id")))
		conceal_di := tv_dict_find(d, cstring("conceal"), 7)
		conceal: cstring = nil
		if conceal_di != nil {
			conceal = tv_get_string((^Typval_T)(uintptr(conceal_di)))
		}
		if i == 0 {
			if match_add_o(win, group, tv_dict_get_string(d, cstring("pattern"), false), priority, id, nil, conceal) != id {
				match_add_failed = true
			}
		} else {
			if match_add_o(win, group, nil, priority, id, s, conceal) != id {
				match_add_failed = true
			}
			tv_list_unref(s)
			s = nil
		}
		li = (^ListItem)(li.li_next)
	}
	if !match_add_failed {
		rettv.vval = transmute(rawptr)(C.longlong(0))
	}
}

// "matchadd()" function.
@(export)
f_matchadd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	grpbuf: [NUMBUFLEN]u8
	patbuf: [NUMBUFLEN]u8
	grp := tv_get_string_buf_chk(argvars, &grpbuf[0])
	pat := tv_get_string_buf_chk((^Typval_T)(uintptr(argvars) + 16), &patbuf[0])
	prio: C.int = 10
	id: C.int = -1
	error := false
	conceal_char: cstring = nil
	win := curwin
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	if grp == nil || pat == nil {
		return
	}
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	if a2.v_type != VAR_UNKNOWN {
		prio = C.int(tv_get_number_chk(a2, &error))
		a3 := (^Typval_T)(uintptr(argvars) + 48)
		if a3.v_type != VAR_UNKNOWN {
			id = C.int(tv_get_number_chk(a3, &error))
			a4 := (^Typval_T)(uintptr(argvars) + 64)
			if a4.v_type != VAR_UNKNOWN {
				cc: ^u8 = nil
				if matchadd_dict_arg_o(a4, &cc, &win) == FAIL {
					return
				}
				conceal_char = transmute(cstring)(cc)
			}
		}
	}
	if error {
		return
	}
	if id >= 1 && id <= 3 {
		semsg(cstring(E798_S), C.int(id))
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(match_add_o(win, grp, pat, prio, id, nil, conceal_char)))
}

// "matchaddpos()" function.
@(export)
f_matchaddpos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(-1))
	buf: [NUMBUFLEN]u8
	group := tv_get_string_buf_chk(argvars, &buf[0])
	if group == nil {
		return
	}
	a1 := (^Typval_T)(uintptr(argvars) + 16)
	if a1.v_type != VAR_LIST {
		semsg(cstring(E_LISTARG_S), cstring("matchaddpos()"))
		return
	}
	l := rawptr(a1.vval)
	if tv_list_len_o(l) == 0 {
		return
	}
	error := false
	prio: C.int = 10
	id: C.int = -1
	conceal_char: cstring = nil
	win := curwin
	a2 := (^Typval_T)(uintptr(argvars) + 32)
	if a2.v_type != VAR_UNKNOWN {
		prio = C.int(tv_get_number_chk(a2, &error))
		a3 := (^Typval_T)(uintptr(argvars) + 48)
		if a3.v_type != VAR_UNKNOWN {
			id = C.int(tv_get_number_chk(a3, &error))
			a4 := (^Typval_T)(uintptr(argvars) + 64)
			if a4.v_type != VAR_UNKNOWN {
				cc: ^u8 = nil
				if matchadd_dict_arg_o(a4, &cc, &win) == FAIL {
					return
				}
				conceal_char = transmute(cstring)(cc)
			}
		}
	}
	if error {
		return
	}
	if id == 1 || id == 2 {
		semsg(cstring(E798B_S), C.int(id))
		return
	}
	rettv.vval = transmute(rawptr)(C.longlong(match_add_o(win, group, nil, prio, id, l, conceal_char)))
}

// "matcharg()" function.
@(export)
f_matcharg :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	id := C.int(tv_get_number(argvars))
	n: C.int = 0
	if id >= 1 && id <= 3 {
		n = 2
	}
	tv_list_alloc_ret(transmute(^Typval)(rettv), n)
	if id >= 1 && id <= 3 {
		m := get_match_o(curwin, id)
		if m != nil {
			tv_list_append_string(rawptr(rettv.vval), transmute(^u8)(syn_id2name_e(m.mit_hlg_id)), -1)
			tv_list_append_string(rawptr(rettv.vval), m.mit_pattern, -1)
		} else {
			tv_list_append_string(rawptr(rettv.vval), nil, 0)
			tv_list_append_string(rawptr(rettv.vval), nil, 0)
		}
	}
}

// "matchdelete()" function.
@(export)
f_matchdelete :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	win := get_optional_window(argvars, 1)
	if win == nil {
		rettv.vval = transmute(rawptr)(C.longlong(-1))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(match_delete_o(win, C.int(tv_get_number(argvars)), true)))
	}
}

// ":[N]match {group} {pattern}".
@(export)
ex_match :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	line2 := (^C.int)(uintptr(eap) + EXARG_LINE2_OFF)^
	id: C.int
	if line2 <= 3 {
		id = C.int(line2)
	} else {
		emsg(cstring(E476_S))
		return
	}
	if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
		match_delete_o(curwin, id, false)
	}
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	end: cstring
	if ends_excmd(C.int(([^]u8)(rawptr(arg))[0])) != 0 {
		end = arg
	} else if strncasecmp_o(arg, cstring("none"), 4) == 0 && (ascii_iswhite(([^]u8)(rawptr(arg))[4]) || ends_excmd(C.int(([^]u8)(rawptr(arg))[4])) != 0) {
		end = transmute(cstring)(rawptr(uintptr(rawptr(arg)) + 4))
	} else {
		p := skiptowhite(arg)
		g: ^u8 = nil
		if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
			g = xmemdupz(rawptr(arg), C.size_t(uintptr(rawptr(p)) - uintptr(rawptr(arg))))
		}
		p = skipwhite(transmute(cstring)(p))
		if ([^]u8)(p)[0] == 0 {
			xfree(rawptr(g))
			semsg(e_invarg2, arg)
			return
		}
		end = transmute(cstring)(skip_regexp_e(transmute(^u8)(rawptr(uintptr(rawptr(p)) + 1)), C.int(([^]u8)(p)[0]), 1))
		if !(^bool)(uintptr(eap) + EXARG_SKIP_OFF)^ {
			after := skipwhite(transmute(cstring)(rawptr(uintptr(rawptr(end)) + 1)))
			if ([^]u8)(rawptr(end))[0] != 0 && ends_excmd(C.int(([^]u8)(rawptr(after))[0])) == 0 {
				xfree(rawptr(g))
				([^]rawptr)(uintptr(eap) + EXARG_ERRMSG_OFF)[0] = rawptr(ex_errmsg(cstring(E488_S), end))
				return
			}
			if ([^]u8)(rawptr(end))[0] != ([^]u8)(p)[0] {
				xfree(rawptr(g))
				semsg(e_invarg2, transmute(cstring)(p))
				return
			}
			c := ([^]u8)(rawptr(end))[0]
			([^]u8)(rawptr(end))[0] = 0
			match_add_o(curwin, transmute(cstring)(g), transmute(cstring)(rawptr(uintptr(rawptr(p)) + 1)), 10, id, nil, nil)
			xfree(rawptr(g))
			([^]u8)(rawptr(end))[0] = c
		}
	}
	([^]cstring)(uintptr(eap) + EXARG_NEXTCMD_OFF)[0] = find_nextcmd(end)
}
