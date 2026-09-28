package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:math"

// fuzzy.c port (Batch F1): fzy matching core (pure algorithm).
// All C-statics become _o plains; publics follow in F2/F3.

FUZZY_MATCH_MAX_LEN_O :: 1024

SCORE_MAX_O :: math.INF_F64
SCORE_MIN_O :: -math.INF_F64
SCORE_SCALE_O :: 1000.0
SCORE_GAP_LEADING_O :: -0.005
SCORE_GAP_TRAILING_O :: -0.005
SCORE_GAP_INNER_O :: -0.01
SCORE_MATCH_CONSECUTIVE_O :: 1.0
SCORE_MATCH_SLASH_O :: 0.9
SCORE_MATCH_WORD_O :: 0.8
SCORE_MATCH_CAPITAL_O :: 0.7
SCORE_MATCH_DOT_O :: 0.6

Match_Struct :: struct {
	needle_len:     C.int,  // @0
	haystack_len:   C.int,  // @4
	lower_needle:   [FUZZY_MATCH_MAX_LEN_O]C.int,  // @8
	lower_haystack: [FUZZY_MATCH_MAX_LEN_O]C.int,  // @4104
	match_bonus:    [FUZZY_MATCH_MAX_LEN_O]f64,  // @8200
}
#assert(size_of(Match_Struct) == 16392)

// Fuzzy item for list matching (fuzzy.c private struct).
FuzzyItem_T :: struct {
	idx:              C.int,  // @0
	_pad0:            C.int,  // @4
	item:             rawptr,  // @8 (listitem_T*)
	score:            C.int,  // @16
	_pad1:            C.int,  // @20
	lmatchpos:        rawptr,  // @24 (list_T*)
	pat:              cstring,  // @32
	itemstr:          ^u8,  // @40
	itemstr_alloced:  bool,  // @48
	_pad2:            [7]u8,  // @49
	startpos:         C.int,  // @56
	_pad3:            C.int,  // @60
}
#assert(size_of(FuzzyItem_T) == 64)

// Ordered-match precheck (C-static; plain proc).
has_match_o :: proc "c" (needle: cstring, haystack: cstring) -> C.int {
	context = runtime.default_context()
	if needle == nil || haystack == nil || ([^]u8)(needle)[0] == 0 {
		return FAIL_E
	}
	n_ptr := needle
	h_ptr := haystack
	for ([^]u8)(n_ptr)[0] != 0 {
		n_char := utf_ptr2char(n_ptr)
		found := false
		for ([^]u8)(h_ptr)[0] != 0 {
			h_char := utf_ptr2char(h_ptr)
			if n_char == h_char || mb_toupper_r(n_char) == h_char {
				found = true
				h_ptr = transmute(cstring)(uintptr(rawptr(h_ptr)) + uintptr(utfc_ptr2len(h_ptr)))
				break
			}
			h_ptr = transmute(cstring)(uintptr(rawptr(h_ptr)) + uintptr(utfc_ptr2len(h_ptr)))
		}
		if !found {
			return FAIL_E
		}
		n_ptr = transmute(cstring)(uintptr(rawptr(n_ptr)) + uintptr(utfc_ptr2len(n_ptr)))
	}
	return OK_E
}

// Separator bonus for codepoint (C-static; plain proc).
compute_bonus_codepoint_o :: proc "c" (last_c: C.int, c: C.int) -> f64 {
	context = runtime.default_context()
	if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || vim_iswordc(c) {
		if last_c == '/' {
			return SCORE_MATCH_SLASH_O
		}
		if last_c == '-' || last_c == '_' || last_c == ' ' {
			return SCORE_MATCH_WORD_O
		}
		if last_c == '.' {
			return SCORE_MATCH_DOT_O
		}
		if mb_isupper_r(c) && mb_islower_r2(last_c) {
			return SCORE_MATCH_CAPITAL_O
		}
	}
	return 0
}

// Fill match struct codepoints + bonuses (C-static; plain proc).
setup_match_struct_o :: proc "c" (match: ^Match_Struct, needle: cstring, haystack: cstring) {
	context = runtime.default_context()
	i: C.int = 0
	p := needle
	for ([^]u8)(p)[0] != 0 && i < FUZZY_MATCH_MAX_LEN_O {
		c := utf_ptr2char(p)
		match.lower_needle[i] = mb_tolower_r(c)
		i += 1
		p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
	}
	match.needle_len = i
	i = 0
	p = haystack
	prev_c: C.int = '/'
	for ([^]u8)(p)[0] != 0 && i < FUZZY_MATCH_MAX_LEN_O {
		c := utf_ptr2char(p)
		match.lower_haystack[i] = mb_tolower_r(c)
		match.match_bonus[i] = compute_bonus_codepoint_o(prev_c, c)
		prev_c = c
		p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
		i += 1
	}
	match.haystack_len = i
}

// Single DP row (C-static-inline; plain proc).
match_row_o :: proc "c" (match: ^Match_Struct, row: C.int, curr_D: [^]f64, curr_M: [^]f64, last_D: [^]f64, last_M: [^]f64) {
	context = runtime.default_context()
	n := match.needle_len
	m := match.haystack_len
	i := row
	gap_score := SCORE_GAP_INNER_O
	if i == n - 1 {
		gap_score = SCORE_GAP_TRAILING_O
	}
	prev_score := SCORE_MIN_O
	prev_M := SCORE_MIN_O
	prev_D := SCORE_MIN_O
	for j: C.int = 0; j < m; j += 1 {
		if match.lower_needle[i] == match.lower_haystack[j] {
			score := SCORE_MIN_O
			if i == 0 {
				score = f64(j)*SCORE_GAP_LEADING_O + match.match_bonus[j]
			} else if j != 0 {
				score = max(prev_M + match.match_bonus[j], prev_D + SCORE_MATCH_CONSECUTIVE_O)
			}
			prev_D = last_D[j]
			prev_M = last_M[j]
			curr_D[j] = score
			next := prev_score + gap_score
			if score > next {
				next = score
			}
			curr_M[j] = next
			prev_score = next
		} else {
			prev_D = last_D[j]
			prev_M = last_M[j]
			curr_D[j] = SCORE_MIN_O
			prev_score = prev_score + gap_score
			curr_M[j] = prev_score
		}
	}
}

// Full match with position backtrace (C-static; plain proc).
match_positions_o :: proc "c" (needle: cstring, haystack: cstring, positions: ^u32) -> f64 {
	context = runtime.default_context()
	if needle == nil || haystack == nil || ([^]u8)(needle)[0] == 0 {
		return SCORE_MIN_O
	}
	match: Match_Struct
	setup_match_struct_o(&match, needle, haystack)
	n := match.needle_len
	m := match.haystack_len
	if m > FUZZY_MATCH_MAX_LEN_O || n > m {
		return SCORE_MIN_O
	} else if n == m {
		equal := true
		for i: C.int = 0; i < n; i += 1 {
			if match.lower_needle[i] != match.lower_haystack[i] {
				equal = false
				break
			}
		}
		if equal {
			if positions != nil {
				for i: C.int = 0; i < n; i += 1 {
					([^]u32)(positions)[i] = u32(i)
				}
			}
			return SCORE_MAX_O
		}
	}
	if u64(n) > (max(u64)/8)/FUZZY_MATCH_MAX_LEN_O/2 {
		return SCORE_MIN_O
	}
	block := ([^]f64)(xmalloc(C.size_t(8*FUZZY_MATCH_MAX_LEN_O*n*2)))
	at_row := proc(block: [^]f64, r: C.int) -> [^]f64 {
		return ([^]f64)(uintptr(block) + uintptr(r*FUZZY_MATCH_MAX_LEN_O*8))
	}
	match_row_o(&match, 0, at_row(block, 0), at_row(block, n), at_row(block, 0), at_row(block, n))
	for i: C.int = 1; i < n; i += 1 {
		match_row_o(&match, i, at_row(block, i), at_row(block, n + i), at_row(block, i - 1), at_row(block, n + i - 1))
	}
	if positions != nil {
		match_required := false
		i := n - 1
		j := m - 1
		for i >= 0 {
			for j >= 0 {
				Di := at_row(block, i)
				Mi := at_row(block, n + i)
				if Di[j] != SCORE_MIN_O && (match_required || Di[j] == Mi[j]) {
					match_required = i != 0 && j != 0 && Mi[j] == at_row(block, i - 1)[j - 1] + SCORE_MATCH_CONSECUTIVE_O
					([^]u32)(positions)[i] = u32(j)
					j -= 1
					break
				}
				j -= 1
			}
			i -= 1
		}
	}
	result := at_row(block, n + n - 1)[m - 1]
	xfree(block)
	return result
}

// —— Batch F2: matchfuzzy engine ——

// Multi-word fuzzy matcher (fuzzy.c public).
@(export)
fuzzy_match :: proc "c" (str: ^u8, pat_arg: cstring, matchseq: bool, outScore: ^C.int, matches: ^u32, maxMatches: C.int) -> bool {
	context = runtime.default_context()
	complete := false
	numMatches: C.int = 0
	pat_chars: C.int = 0
	outScore^ = 0
	save_pat := xstrdup_o(transmute(^u8)(pat_arg))
	pat := ([^]u8)(save_pat)
	p := pat
	for {
		if matchseq {
			complete = true
		} else {
			p = ([^]u8)(skipwhite(transmute(cstring)(p)))
			if p[0] == 0 {
				break
			}
			pat = p
			for p[0] != 0 && utf_ptr2char(transmute(cstring)(p)) != ' ' && utf_ptr2char(transmute(cstring)(p)) != '\t' {
				p = ([^]u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
			}
			if p[0] == 0 {
				complete = true
			}
			p[0] = 0
		}
		pat_chars = mb_charlen_r(transmute(cstring)(&pat[0]))
		if pat_chars > maxMatches {
			pat_chars = maxMatches
		}
		if numMatches > maxMatches - pat_chars {
			numMatches = 0
			outScore^ = FUZZY_SCORE_NONE_O
			break
		}
		score := FUZZY_SCORE_NONE_O
		if has_match_o(transmute(cstring)(&pat[0]), transmute(cstring)(str)) == OK_E {
			fzy_score := match_positions_o(transmute(cstring)(&pat[0]), transmute(cstring)(str), &([^]u32)(matches)[numMatches])
			if fzy_score != SCORE_MIN_O {
				if fzy_score == SCORE_MAX_O {
					score = max(C.int)
				} else if fzy_score < 0 {
					score = C.int(math.ceil(fzy_score*SCORE_SCALE_O - 0.5))
				} else {
					score = C.int(math.floor(fzy_score*SCORE_SCALE_O + 0.5))
				}
			}
		}
		if score == FUZZY_SCORE_NONE_O {
			numMatches = 0
			outScore^ = FUZZY_SCORE_NONE_O
			break
		}
		if score > 0 && outScore^ > max(C.int) - score {
			outScore^ = max(C.int)
		} else if score < 0 && outScore^ < min(C.int) + 1 - score {
			outScore^ = min(C.int) + 1
		} else {
			outScore^ += score
		}
		numMatches += pat_chars
		if complete || numMatches >= maxMatches {
			break
		}
		p = ([^]u8)(uintptr(p) + 1)
	}
	xfree(save_pat)
	return numMatches != 0
}

// List-item comparator for qsort (C-static; plain proc).
fuzzy_match_item_compare_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	a := (^FuzzyItem_T)(s1)
	b := (^FuzzyItem_T)(s2)
	if a.score == b.score {
		pat := transmute(cstring)(a.pat)
		patlen := libc.strlen(pat)
		exact1 := a.startpos >= 0 && libc.strncmp(pat, transmute(cstring)(uintptr(a.itemstr) + uintptr(a.startpos)), patlen) == 0
		exact2 := b.startpos >= 0 && libc.strncmp(pat, transmute(cstring)(uintptr(b.itemstr) + uintptr(b.startpos)), patlen) == 0
		if exact1 == exact2 {
			if a.idx == b.idx {
				return 0
			}
			if a.idx > b.idx {
				return 1
			}
			return -1
		} else if exact2 {
			return 1
		}
		return -1
	} else {
		if a.score > b.score {
			return -1
		}
		return 1
	}
}

// List fuzzy matcher (C-static; plain proc).
fuzzy_match_in_list_o :: proc "c" (l: rawptr, str: ^u8, matchseq: bool, key: cstring, item_cb: ^Callback_E, retmatchpos: bool, fmatchlist: rawptr, max_matches: C.int) {
	context = runtime.default_context()
	length := tv_list_len_o(l)
	if length == 0 {
		return
	}
	if max_matches > 0 && length > max_matches {
		length = max_matches
	}
	items := ([^]FuzzyItem_T)(xcalloc(C.size_t(length), size_of(FuzzyItem_T)))
	match_count: C.int = 0
	matches: [FUZZY_MATCH_MAX_LEN_O]u32
	li := (^rawptr)(l)^
	for li != nil {
		if max_matches > 0 && match_count >= max_matches {
			break
		}
		itemstr: ^u8 = nil
		itemstr_allocate := false
		rettv: Typval_T
		rettv.v_type = VAR_UNKNOWN
		tv := (^Typval_T)(uintptr(li) + 16)
		if tv.v_type == VAR_STRING {
			itemstr = transmute(^u8)(tv.vval)
		} else if tv.v_type == VAR_DICT && (key != nil || (^C.int)(uintptr(item_cb) + 8)^ != C.int(CallbackType.kCallbackNone)) {
			if key != nil {
				itemstr = transmute(^u8)(tv_dict_get_string(rawptr(tv.vval), key, false))
			} else {
				argv: [2]Typval_T
				(^C.int)(uintptr(rawptr(tv.vval)) + 8)^ += 1
				argv[0].v_type = VAR_DICT
				argv[0].vval = tv.vval
				argv[1].v_type = VAR_UNKNOWN
				if callback_call(rawptr(item_cb), 1, &argv[0], transmute(^Typval_T)(&rettv)) {
					if rettv.v_type == VAR_STRING {
						itemstr = transmute(^u8)(rettv.vval)
						itemstr_allocate = true
					}
				}
				tv_dict_unref(rawptr(tv.vval))
			}
		}
		score: C.int = 0
		if itemstr != nil && fuzzy_match(itemstr, transmute(cstring)(str), matchseq, &score, &matches[0], FUZZY_MATCH_MAX_LEN_O) {
			itemstr_copy := itemstr
			if itemstr_allocate {
				itemstr_copy = xstrdup_o(itemstr)
			}
			match_positions: rawptr = nil
			if retmatchpos {
				match_positions = tv_list_alloc(KLISTLEN_MAYKNOW_O)
				j: C.int = 0
				pp := transmute(cstring)(str)
				for ([^]u8)(pp)[0] != 0 && j < FUZZY_MATCH_MAX_LEN_O {
					pc := utf_ptr2char(pp)
					if (pc != ' ' && pc != '\t') || matchseq {
						tv_list_append_number(match_positions, C.longlong(matches[j]))
						j += 1
					}
					pp = transmute(cstring)(uintptr(rawptr(pp)) + uintptr(utfc_ptr2len(pp)))
				}
			}
			items[match_count].idx = match_count
			items[match_count].item = li
			items[match_count].score = score
			items[match_count].pat = transmute(cstring)(str)
			items[match_count].startpos = C.int(matches[0])
			items[match_count].itemstr = itemstr_copy
			items[match_count].itemstr_alloced = itemstr_allocate
			items[match_count].lmatchpos = match_positions
			match_count += 1
		}
		tv_clear(transmute(^Typval_T)(&rettv))
		li = (^rawptr)(li)^
	}
	if match_count > 0 {
		qsort_e(rawptr(items), C.size_t(match_count), size_of(FuzzyItem_T), fuzzy_match_item_compare_o)
		retlist: rawptr
		if retmatchpos {
			li0 := tv_list_find(fmatchlist, 0)
			retlist = (^rawptr)(uintptr(li0) + 24)^
		} else {
			retlist = fmatchlist
		}
		for i: C.int = 0; i < match_count; i += 1 {
			tv_list_append_tv(retlist, (^Typval_T)(uintptr(items[i].item) + 16))
		}
		if retmatchpos {
			li2 := tv_list_find(fmatchlist, -2)
			retlist = (^rawptr)(uintptr(li2) + 24)^
			for i: C.int = 0; i < match_count; i += 1 {
				if items[i].lmatchpos == nil {
					libc.abort()
				}
				tv_list_append_list(retlist, items[i].lmatchpos)
				items[i].lmatchpos = nil
			}
			li1 := tv_list_find(fmatchlist, -1)
			retlist = (^rawptr)(uintptr(li1) + 24)^
			for i: C.int = 0; i < match_count; i += 1 {
				tv_list_append_number(retlist, C.longlong(items[i].score))
			}
		}
	}
	for i: C.int = 0; i < match_count; i += 1 {
		if items[i].itemstr_alloced {
			xfree(items[i].itemstr)
		}
		if items[i].lmatchpos != nil {
			libc.abort()
		}
	}
	xfree(items)
}

// matchfuzzy()/matchfuzzypos() driver (C-static; plain proc).
do_fuzzymatch_o :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, retmatchpos: bool) {
	context = runtime.default_context()
	a0 := &([^]Typval_T)(argvars)[0]
	a1 := &([^]Typval_T)(argvars)[1]
	a2 := &([^]Typval_T)(argvars)[2]
	if a0.v_type != VAR_LIST || rawptr(a0.vval) == nil {
	fname := cstring("matchfuzzypos()")
		if !retmatchpos {
			fname = cstring("matchfuzzy()")
		}
		semsg(cstring(E_LISTARG_S), fname)
		return
	}
	if a1.v_type != VAR_STRING || rawptr(a1.vval) == nil {
		semsg(e_invarg2, tv_get_string(a1))
		return
	}
	cb: Callback_E
	cb.data = nil
	cb.type = 0
	key: cstring = nil
	matchseq := false
	max_matches: C.int = 0
	if a2.v_type != VAR_UNKNOWN {
		if tv_check_for_nonnull_dict_arg(argvars, 2) == FAIL_E {
			return
		}
		d := rawptr(a2.vval)
		di := tv_dict_find(d, cstring("key"), -1)
		if di != nil {
			ditv := (^Typval_T)(di)
			if ditv.v_type != VAR_STRING || rawptr(ditv.vval) == nil || ([^]u8)(ditv.vval)[0] == 0 {
				semsg(cstring(E_INVARGNVAL_S), cstring("key"), tv_get_string(ditv))
				return
			}
			key = tv_get_string(ditv)
		} else if !tv_dict_get_callback(d, cstring("text_cb"), -1, &cb) {
			semsg(cstring(E475_VAL_S), cstring("text_cb"))
			return
		}
		di = tv_dict_find(d, cstring("limit"), -1)
		if di != nil {
			ditv := (^Typval_T)(di)
			if ditv.v_type != VAR_NUMBER {
				semsg(cstring(E475_VAL_S), cstring("limit"))
				return
			}
			max_matches = C.int(tv_get_number_chk(ditv, nil))
		}
		if tv_dict_has_key(d, cstring("matchseq")) {
			matchseq = true
		}
	}
	if retmatchpos {
		tv_list_alloc_ret(transmute(^Typval)(rettv), 3)
	} else {
		tv_list_alloc_ret(transmute(^Typval)(rettv), KLISTLEN_UNKNOWN_O)
	}
	if retmatchpos {
		tv_list_append_list(rawptr(rettv.vval), tv_list_alloc(KLISTLEN_UNKNOWN_O))
		tv_list_append_list(rawptr(rettv.vval), tv_list_alloc(KLISTLEN_UNKNOWN_O))
		tv_list_append_list(rawptr(rettv.vval), tv_list_alloc(KLISTLEN_UNKNOWN_O))
	}
	fuzzy_match_in_list_o(rawptr(a0.vval), transmute(^u8)(tv_get_string(a1)), matchseq, key, &cb, retmatchpos, rawptr(rettv.vval), max_matches)
	callback_free(&cb)
}

// matchfuzzy() builtin (fuzzy.c public, table-bound).
@(export)
f_matchfuzzy :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	do_fuzzymatch_o(argvars, rettv, false)
}

// matchfuzzypos() builtin (fuzzy.c public, table-bound).
@(export)
f_matchfuzzypos :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	do_fuzzymatch_o(argvars, rettv, true)
}

// —— Batch F3: string matchers + search ——

Fuzmatch_Str_T :: struct {
	idx:   C.int,  // @0
	str:   ^u8,  // @8
	score: C.int,  // @16
}
#assert(size_of(Fuzmatch_Str_T) == 24)

foreign _ {
	@(link_name = "find_line_end")
	find_line_end_e :: proc "c" (ptr: ^u8) -> ^u8 ---
	@(link_name = "ctrl_x_mode_whole_line")
	ctrl_x_mode_whole_line_e :: proc "c" () -> bool ---
}

// String comparator for qsort (C-static; plain proc).
fuzzy_match_str_compare_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	a := (^Fuzmatch_Str_T)(s1)
	b := (^Fuzmatch_Str_T)(s2)
	if a.score == b.score {
		if a.idx == b.idx {
			return 0
		}
		if a.idx > b.idx {
			return 1
		}
		return -1
	} else {
		if a.score > b.score {
			return -1
		}
		return 1
	}
}

// String-match sorter (C-static; plain proc).
fuzzy_match_str_sort_o :: proc "c" (fm: rawptr, sz: C.int) {
	context = runtime.default_context()
	qsort_e(fm, C.size_t(sz), size_of(Fuzmatch_Str_T), fuzzy_match_str_compare_o)
}

// Func-name comparator (<SNR> last; C-static; plain proc).
fuzzy_match_func_compare_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	a := (^Fuzmatch_Str_T)(s1)
	b := (^Fuzmatch_Str_T)(s2)
	a_lt := ([^]u8)(a.str)[0] != '<'
	b_lt := ([^]u8)(b.str)[0] != '<'
	if a_lt && !b_lt {
		return -1
	}
	if !a_lt && b_lt {
		return 1
	}
	if a.score == b.score {
		if a.idx == b.idx {
			return 0
		}
		if a.idx > b.idx {
			return 1
		}
		return -1
	}
	if a.score > b.score {
		return -1
	}
	return 1
}

// Func-name sorter (C-static; plain proc).
fuzzy_match_func_sort_o :: proc "c" (fm: rawptr, sz: C.int) {
	context = runtime.default_context()
	qsort_e(fm, C.size_t(sz), size_of(Fuzmatch_Str_T), fuzzy_match_func_compare_o)
}

// Score a pattern in a string, 0 on no match (fuzzy.c public).
@(export)
fuzzy_match_str :: proc "c" (str: ^u8, pat: ^u8) -> C.int {
	context = runtime.default_context()
	if str == nil || pat == nil {
		return 0
	}
	score := FUZZY_SCORE_NONE_O
	matchpos: [FUZZY_MATCH_MAX_LEN_O]u32
	fuzzy_match(str, transmute(cstring)(pat), true, &score, &matchpos[0], FUZZY_MATCH_MAX_LEN_O)
	return score
}

// Match positions garray, NULL on no match (fuzzy.c public).
@(export)
fuzzy_match_str_with_pos :: proc "c" (str: ^u8, pat: ^u8) -> ^Garray {
	context = runtime.default_context()
	if str == nil || pat == nil {
		return nil
	}
	match_positions := transmute(^Garray)(xmalloc(C.size_t(size_of(Garray))))
	ga_init(match_positions, C.int(size_of(u32)), 10)
	score := FUZZY_SCORE_NONE_O
	matches: [FUZZY_MATCH_MAX_LEN_O]u32
	if !fuzzy_match(str, transmute(cstring)(pat), false, &score, &matches[0], FUZZY_MATCH_MAX_LEN_O) || score == FUZZY_SCORE_NONE_O {
		ga_clear(match_positions)
		xfree(match_positions)
		return nil
	}
	j: C.int = 0
	p := transmute(cstring)(pat)
	for ([^]u8)(p)[0] != 0 {
		pc := utf_ptr2char(p)
		if pc != ' ' && pc != '\t' {
			ga_grow(match_positions, 1)
			([^]u32)(match_positions.ga_data)[match_positions.ga_len] = matches[j]
			match_positions.ga_len += 1
			j += 1
		}
		p = transmute(cstring)(uintptr(rawptr(p)) + uintptr(utfc_ptr2len(p)))
	}
	return match_positions
}

// Word-by-word line matcher (fuzzy.c public).
@(export)
fuzzy_match_str_in_line :: proc "c" (ptr: ^^u8, pat: ^u8, len: ^C.int, current_pos: ^Pos_T, score: ^C.int) -> bool {
	context = runtime.default_context()
	str := ptr^
	strBegin := str
	end: ^u8 = nil
	start: ^u8 = nil
	found := false
	if str == nil || pat == nil {
		return found
	}
	line_end := find_line_end_e(str)
	for uintptr(str) < uintptr(line_end) {
		start = find_word_start(str)
		if ([^]u8)(start)[0] == 0 {
			break
		}
		end = find_word_end(start)
		save_end := ([^]u8)(end)[0]
		([^]u8)(end)[0] = 0
		score^ = fuzzy_match_str(start, pat)
		([^]u8)(end)[0] = save_end
		if score^ != FUZZY_SCORE_NONE_O {
			len^ = C.int(uintptr(end) - uintptr(start))
			found = true
			ptr^ = start
			if current_pos != nil {
				current_pos.col += C.int(uintptr(end) - uintptr(strBegin))
			}
			break
		}
		str = end
		for ([^]u8)(str)[0] != 0 && !vim_iswordp(str) {
			str = ([^]u8)(uintptr(str) + uintptr(utfc_ptr2len(transmute(cstring)(str))))
		}
	}
	if !found {
		ptr^ = line_end
	}
	return found
}

pos_equal_fz :: proc "c" (a: Pos_T, b: Pos_T) -> bool {
	context = runtime.default_context()
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

// Buffer fuzzy search with wraparound (fuzzy.c public).
@(export)
search_for_fuzzy_match :: proc "c" (buf: rawptr, pos: ^Pos_T, pattern: ^u8, dir: C.int, start_pos: ^Pos_T, len: ^C.int, ptr: ^^u8, score: ^C.int) -> bool {
	context = runtime.default_context()
	current_pos := pos^
	circly_end: Pos_T
	found_new_match := false
	looped_around := false
	whole_line := ctrl_x_mode_whole_line_e()
	if buf == curbuf {
		circly_end = start_pos^
	} else {
		circly_end.lnum = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
		circly_end.col = 0
		circly_end.coladd = 0
	}
	if whole_line && start_pos.lnum != pos.lnum {
		current_pos.lnum += dir
	}
	for {
		if looped_around && ((whole_line && current_pos.lnum == circly_end.lnum) || (!whole_line && pos_equal_fz(current_pos, circly_end))) {
			break
		}
		if current_pos.lnum >= 1 && current_pos.lnum <= (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
			ptr^ = ml_get_buf(buf, current_pos.lnum)
			if !whole_line {
				ptr^ = ([^]u8)(uintptr(ptr^) + uintptr(current_pos.col))
			}
			if ptr^ != nil && ([^]u8)(ptr^)[0] != 0 {
				if !whole_line {
					found_new_match = fuzzy_match_str_in_line(ptr, pattern, len, &current_pos, score)
					if found_new_match {
						pos^ = current_pos
						break
					} else if looped_around && current_pos.lnum == circly_end.lnum {
						break
					}
				} else {
					line := ptr^
					p := transmute(cstring)(skipwhite(transmute(cstring)(line)))
					if fuzzy_match_str(transmute(^u8)(p), pattern) != FUZZY_SCORE_NONE_O {
						found_new_match = true
						pos^ = current_pos
						ptr^ = transmute(^u8)(p)
						len^ = ml_get_buf_len(buf, current_pos.lnum) - C.int(uintptr(rawptr(p)) - uintptr(line))
						break
					}
				}
			}
		}
		if dir == C.int(Direction.FORWARD) {
			current_pos.lnum += 1
			if current_pos.lnum > (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^ {
				if p_ws_g != 0 {
					current_pos.lnum = 1
					looped_around = true
				} else {
					break
				}
			}
		} else {
			current_pos.lnum -= 1
			if current_pos.lnum < 1 {
				if p_ws_g != 0 {
					current_pos.lnum = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT)^
					looped_around = true
				} else {
					break
				}
			}
		}
		current_pos.col = 0
	}
	return found_new_match
}

// Free match array (fuzzy.c public; mirrors C exactly incl. [count] index).
@(export)
fuzmatch_str_free :: proc "c" (fuzmatch: rawptr, count: C.int) {
	context = runtime.default_context()
	if fuzmatch == nil {
		return
	}
	for i: C.int = 0; i < count; i += 1 {
		xfree(([^]Fuzmatch_Str_T)(fuzmatch)[count].str)
	}
	xfree(fuzmatch)
}

// Sorted matches to string array (fuzzy.c public).
@(export)
fuzzymatches_to_strmatches :: proc "c" (fuzmatch: rawptr, matches: rawptr, count: C.int, funcsort: bool) {
	context = runtime.default_context()
	if count <= 0 {
		xfree(fuzmatch)
		return
	}
	([^]rawptr)(matches)[0] = xmalloc(C.size_t(count)*8)
	if funcsort {
		fuzzy_match_func_sort_o(fuzmatch, count)
	} else {
		fuzzy_match_str_sort_o(fuzmatch, count)
	}
	for i: C.int = 0; i < count; i += 1 {
		([^]rawptr)(([^]rawptr)(matches)[0])[i] = ([^]Fuzmatch_Str_T)(fuzmatch)[i].str
	}
	xfree(fuzmatch)
}
