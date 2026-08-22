// search.odin — port of src/nvim/search.c (code for normal mode searching)
package main

import C "core:c"
import "core:c/libc"

foreign _ {
	@(link_name = "p_hls")
	p_hls: C.int
	@(link_name = "no_hlsearch")
	no_hlsearch: bool
	@(link_name = "set_no_hlsearch")
	set_no_hlsearch_r :: proc "c" (flag: bool) ---
	@(link_name = "p_ic")
	p_ic: C.int
	@(link_name = "p_scs")
	p_scs: C.int
	@(link_name = "p_ws")
	p_ws_g: C.int
	@(link_name = "no_smartcase")
	no_smartcase: bool
	@(link_name = "rc_did_emsg")
	rc_did_emsg: bool
	@(link_name = "called_emsg")
	called_emsg: C.int
	@(link_name = "searchcmdlen")
	searchcmdlen: C.int
	@(link_name = "msg_silent")
	msg_silent: C.int
	@(link_name = "cmd_silent")
	cmd_silent: bool
	@(link_name = "msg_scrolled")
	msg_scrolled: C.int
	@(link_name = "sc_col")
	sc_col: C.int
	@(link_name = "msg_nowait")
	msg_nowait: bool
	@(link_name = "dollar_vcol")
	dollar_vcol: C.int
	@(link_name = "g_do_tagpreview")
	g_do_tagpreview: C.int
	@(link_name = "p_msc")
	p_msc: C.longlong
	@(link_name = "KeyStuffed")
	KeyStuffed: bool

	@(link_name = "magic_isset")
	magic_isset_r :: proc "c" () -> C.int ---
	@(link_name = "skip_regexp_ex")
	skip_regexp_ex_r :: proc "c" (start: cstring, delim: C.int, magic: C.int, newstartp: ^^u8, did_escape: ^bool, magic_val: ^C.int) -> ^u8 ---
	@(link_name = "vim_regcomp")
	vim_regcomp :: proc "c" (expr: cstring, re_flags: C.int) -> rawptr ---
	@(link_name = "vim_regexec_multi")
	vim_regexec_multi_r :: proc "c" (rmp: ^Regmmatch_T, win: rawptr, buf: rawptr, lnum: C.int, col: C.int, tm: ^proftime_T, timed_out: ^C.int) -> C.int ---
	@(link_name = "vim_regexec")
	vim_regexec_r :: proc "c" (rmp: ^Regmatch_T, line: ^u8, col: C.int) -> C.int ---
	@(link_name = "vim_regfree")
	vim_regfree :: proc "c" (prog: rawptr) ---
	@(link_name = "add_to_history")
	add_to_history_r :: proc "c" (histype: C.int, str: cstring, len: C.size_t, in_map: bool, sep: C.int) ---
	@(link_name = "reverse_text")
	reverse_text_r :: proc "c" (s: cstring) -> ^u8 ---
	@(link_name = "redraw_all_later")
	redraw_all_later_s :: proc "c" (typ: C.int) ---
	// buf_get_changedtick is a C static inline — see buf_changedtick_inline below.

	@(link_name = "mb_isupper")
	mb_isupper_r :: proc "c" (a: C.int) -> bool ---
	@(link_name = "mb_strnicmp")
	mb_strnicmp_r :: proc "c" (s1: cstring, s2: cstring, nn: C.size_t) -> C.int ---
	@(link_name = "mb_strcmp_ic")
	mb_strcmp_ic_r :: proc "c" (ic: bool, s1: cstring, s2: cstring) -> C.int ---
	@(link_name = "utf_iscomposing_first")
	utf_iscomposing_first_r :: proc "c" (c: C.int) -> bool ---
	@(link_name = "utf_char2bytes")
	utf_char2bytes_r :: proc "c" (c: C.int, buf: ^u8) -> C.int ---
	@(link_name = "check_linecomment")
	check_linecomment_r :: proc "c" (line: ^u8) -> C.int ---
	@(link_name = "char_avail")
	char_avail_r :: proc "c" () -> bool ---
	// line_breakcheck/fast_breakcheck are Odin exports in input.odin — call directly.

	@(link_name = "inc")
	incl_pos :: proc "c" (lp: ^Pos_T) -> C.int ---
	@(link_name = "inc_cursor")
	inc_cursor_r :: proc "c" () -> C.int ---
	@(link_name = "dec_cursor")
	dec_cursor_r :: proc "c" () -> C.int ---

	@(link_name = "give_warning")
	give_warning_s :: proc "c" (message: cstring, hl: bool, hist: bool) ---
	@(link_name = "shortmess")
	shortmess_s :: proc "c" (x: C.int) -> bool ---
	@(link_name = "messaging")
	messaging_s :: proc "c" () -> bool ---
	@(link_name = "gotocmdline")
	gotocmdline_r :: proc "c" (clr: bool) ---
	@(link_name = "msg_clr_eos")
	msg_clr_eos_r :: proc "c" () ---
	@(link_name = "msg_check")
	msg_check_r :: proc "c" () ---
	@(link_name = "msg_strtrunc")
	msg_strtrunc_r :: proc "c" (s: ^u8, force: bool) -> ^u8 ---
	@(link_name = "msg_puts")
	msg_puts_s :: proc "c" (s: cstring) ---
	@(link_name = "msg_puts_title")
	msg_puts_title_s :: proc "c" (s: cstring) ---
	@(link_name = "msg_puts_hl")
	msg_puts_hl_s :: proc "c" (s: cstring, hl: C.int, hist: bool) ---
	@(link_name = "msg_prt_line")
	msg_prt_line_r :: proc "c" (s: ^u8, list: bool) ---
	@(link_name = "msg_trunc_attr")
	msg_trunc_s :: proc "c" (s: cstring, check: bool, hl_id: C.int) ---
	@(link_name = "msg_home_replace")
	msg_home_replace_r :: proc "c" (fname: ^u8) ---
	@(link_name = "msg_outtrans")
	msg_outtrans_s :: proc "c" (str: cstring, hl_id: C.int, hist: bool) -> C.int ---
	@(link_name = "ui_flush")
	ui_flush_s :: proc "c" () ---
	@(link_name = "show_cursor_info_later")
	show_cursor_info_later_r :: proc "c" (must_show: bool) ---
	@(link_name = "setcursor")
	setcursor_r :: proc "c" () ---
	@(link_name = "ui_cursor_shape")
	ui_cursor_shape_r :: proc "c" () ---
	@(link_name = "vim_beep")
	vim_beep_r :: proc "c" (val: C.int) ---
	@(link_name = "getvcol")
	getvcol_s :: proc "c" (wp: rawptr, p: ^Pos_T, start: ^C.int, cursor: ^C.int, end: ^C.int, flags: C.int) ---

	@(link_name = "profile_setlimit")
	profile_setlimit_r :: proc "c" (msec: C.longlong) -> proftime_T ---
	@(link_name = "profile_passed_limit")
	profile_passed_limit_r :: proc "c" (tm: proftime_T) -> bool ---

	@(link_name = "xstrnsave")
	xstrnsave_c :: proc "c" (s: cstring, len: C.size_t) -> ^u8 ---
}

// ── Constants ────────────────────────────────────────────────────────────────

// RE_SEARCH/RE_SUBST/RE_BOTH/RE_LAST: RE_SEARCH is in register.odin
RE_SUBST :: 1
RE_BOTH :: 2
RE_LAST :: 2

// byte access helpers (^u8 is not indexable in Odin)
b_at :: proc "c" (p: ^u8, i: C.int) -> u8 {
	return ([^]u8)(p)[i]
}
b_eq :: proc "c" (p: ^u8, v: u8) -> bool {
	return ([^]u8)(p)[0] == v
}
b_set :: proc "c" (p: ^u8, i: C.int, v: u8) {
	([^]u8)(p)[i] = v
}

SEARCH_REV :: 0x01
SEARCH_ECHO :: 0x02
SEARCH_MSG :: 0x0c
SEARCH_NFMSG :: 0x08
SEARCH_OPT :: 0x10
SEARCH_HIS :: 0x20
SEARCH_END :: 0x40
SEARCH_NOOF :: 0x80
SEARCH_START_F :: 0x100
SEARCH_MARK :: 0x200
SEARCH_KEEP :: 0x400
SEARCH_PEEK :: 0x800
SEARCH_COL :: 0x1000

SEARCH_STAT_DEF_TIMEOUT :: 40
SEARCH_STAT_BUF_LEN :: 16

NSUBEXP :: 10
MAX_SCHAR_SIZE :: 32
LSIZE_S :: 512

CPO_SEARCH :: 'c'
CPO_SHOWMATCH :: 'm'
CPO_MATCHBSL :: 'M'
CPO_LINEOFF :: 'o'
CPO_MATCH :: '%'
CPO_SCOLON :: ';'

CMOD_KEEPPATTERNS :: 0x080 // cmod_flags bit
RE_MAGIC :: 1

HIST_SEARCH :: 1

kOptBoFlagShowmatch_S :: 0x2000 // option_vars.generated.h kOptBoFlagShowmatch

// shortmess() takes a CHAR (option.c: vim_strchr(p_shm, x))
SHM_SEARCH :: 's'
SHM_SEARCHCOUNT :: 'S'
SHM_COMPLETIONSCAN :: 'C'

UPD_SOME_VALID_S :: 2
HLF_D_S :: 5 // highlight_defs.h hlf_T enum order
HLF_N_S :: 12
HLF_R_S :: 18

EVENT_SEARCHWRAPPED_S :: 96 // auevents_enum.generated.h

// ── Struct mirrors (offset-verified vs C) ────────────────────────────────────

Lpos_T :: struct {
	lnum: C.int,
	col:  C.int,
}

SearchOffset :: struct { // 16
	dir:  i8,
	line: bool,
	end:  bool,
	off:  C.longlong,
}

AdditionalData_S :: struct {} // opaque; only pointer passed around

SearchPattern :: struct { // 56
	pat:             ^u8,
	patlen:          C.size_t,
	magic:           bool,
	no_scs:          bool,
	timestamp:       Timestamp,
	off:             SearchOffset,
	additional_data: rawptr,
}

searchit_arg_T :: struct { // 24
	sa_stop_lnum: C.int,
	sa_tm:        ^proftime_T,
	sa_timed_out: C.int,
	sa_wrapped:   C.int,
}

Regmmatch_T :: struct #align(8) { // 184
	regprog:      rawptr,
	startpos:     [NSUBEXP]Lpos_T,
	endpos:       [NSUBEXP]Lpos_T,
	rmm_matchcol: C.int,
	rmm_ic:       C.int,
	rmm_maxcol:   C.int,
}

Regmatch_T :: struct #align(8) { // 176
	regprog:     rawptr,
	startp:      [NSUBEXP]^u8,
	endp:        [NSUBEXP]^u8,
	rm_matchcol: C.int,
	rm_ic:       C.int,
}

Cmdarg_T :: struct #align(8) { // 88 — fields at verified offsets
	oap:            rawptr,
	_line1:         C.int,
	_line2:         C.int,
	nchar:          C.int,
	nchar_composing_buf: [32]u8, // @20 (char[MB_MAXBYTES])
	nchar_len:      C.int,
	_opcount_pad:   [2]C.int,
	count0:         C.int,
	count1:         C.int,
	arg:            C.int,
	retval:         C.int,
	_tail:          [8]u8,
}

#assert(size_of(SearchOffset) == 16)
#assert(size_of(SearchPattern) == 56)
#assert(size_of(searchit_arg_T) == 24)
#assert(size_of(Regmmatch_T) == 184)
#assert(size_of(Regmatch_T) == 176)
#assert(size_of(Cmdarg_T) == 88)
#assert(offset_of(Cmdarg_T, count0) == 64)
#assert(offset_of(Cmdarg_T, arg) == 72)
#assert(offset_of(Cmdarg_T, retval) == 76)
#assert(offset_of(Cmdarg_T, nchar_len) == 52)

searchstat_T :: struct {
	cur:          C.int,
	cnt:          C.int,
	exact_match:  bool,
	incomplete:   C.int,
	last_maxcount: C.int,
}

SearchedFile :: struct {
	fp:      rawptr, // libc.FILE *
	name:    ^u8,
	lnum:    C.int,
	matched: bool,
}

// nchar_composing is char[nchar_len] inline after nchar@16..19.
cap_nchar_composing :: proc "c"(cap: ^Cmdarg_T) -> ^u8 {
	return (^u8)(uintptr(cap) + 20)
}

// ── win_T/buf_T field readers (offset-verified) ─────────────────────────────

w_p_rl_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+1024)^ }
w_p_rlc_r :: proc "c"(wp: rawptr) -> ^u8 { return (^^u8)(uintptr(wp)+1032)^ }
w_p_wrap_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+1124)^ }
w_topline_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+364)^ }
w_botline_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+612)^ }
w_leftcol_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+384)^ }
w_view_width_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+504)^ }
w_virtcol_r :: proc "c"(wp: rawptr) -> C.int { return (^C.int)(uintptr(wp)+596)^ }
w_set_curswant_r :: proc "c"(wp: rawptr) -> bool { return (^bool)(uintptr(wp)+152)^ }
w_p_so_r :: proc "c"(wp: rawptr) -> C.longlong { return (^C.longlong)(uintptr(wp)+1176)^ }
w_p_siso_r :: proc "c"(wp: rawptr) -> C.longlong { return (^C.longlong)(uintptr(wp)+1168)^ }

buf_ml_line_count_r :: proc "c"(buf: rawptr) -> C.int { return (^C.int)(uintptr(buf)+8)^ }
buf_ffname_r :: proc "c"(buf: rawptr) -> ^u8 { return (^^u8)(uintptr(buf)+160)^ }
buf_fname_r :: proc "c"(buf: rawptr) -> ^u8 { return (^^u8)(uintptr(buf)+176)^ }
buf_p_inf_r :: proc "c"(buf: rawptr) -> C.int { return (^C.int)(uintptr(buf)+10440)^ }
buf_p_mps_r :: proc "c"(buf: rawptr) -> ^u8 { return (^^u8)(uintptr(buf)+10568)^ }
buf_p_lisp_r :: proc "c"(buf: rawptr) -> C.int { return (^C.int)(uintptr(buf)+10544)^ }
buf_p_inc_r :: proc "c"(buf: rawptr) -> ^u8 { return (^^u8)(uintptr(buf)+10464)^ }
buf_p_def_r :: proc "c"(buf: rawptr) -> ^u8 { return (^^u8)(uintptr(buf)+10456)^ }

// ── Statics (file-private in C) ─────────────────────────────────────────────

spats := [2]SearchPattern{
	{nil, 0, true, false, 0, {'/', false, false, 0}, nil},
	{nil, 0, true, false, 0, {'/', false, false, 0}, nil},
}
last_idx: C.int = 0
lastc: [2]u8 = {0, 0}
lastcdir: Direction = .FORWARD
last_t_cmd := true
lastc_bytes: [MAX_SCHAR_SIZE + 1]u8
lastc_bytelen: C.int = 1

saved_spats: [2]SearchPattern
saved_mr_pattern: ^u8
saved_mr_patternlen: C.size_t
saved_spats_last_idx: C.int
saved_spats_no_hlsearch: bool

mr_pattern: ^u8
mr_patternlen: C.size_t

save_level: C.int = 0

saved_last_search_spat: SearchPattern
did_save_last_search_spat: C.int = 0
saved_last_idx: C.int = 0
saved_no_hlsearch: bool = false
saved_search_match_endcol: C.int
saved_search_match_lines: C.int

// search_match_endcol/search_match_lines are C globals used by incsearch — FFI
foreign _ {
	@(link_name = "search_match_endcol")
	search_match_endcol_g: C.int
	@(link_name = "search_match_lines")
	search_match_lines_g: C.int
}

free_spat :: proc "c"(spat: ^SearchPattern) {
	xfree(spat.pat)
	xfree(spat.additional_data)
}

foreign _ {
	@(link_name = "set_vim_var_nr")
	set_vim_var_nr_c :: proc "c" (idx: C.int, val: i64) ---
}

@(export)
search_regcomp :: proc "c"(
	pat_init: ^u8,
	patlen_init: C.size_t,
	used_pat: ^^u8,
	pat_save: C.int,
	pat_use: C.int,
	options: C.int,
	regmatch: ^Regmmatch_T,
) -> C.int {
	rc_did_emsg = false
	magic := magic_isset_r()
	pat := pat_init
	patlen := patlen_init

	if pat == nil || b_at(pat, 0) == 0 {
		i: C.int
		if pat_use == RE_LAST {
			i = last_idx
		} else {
			i = pat_use
		}
		if spats[i].pat == nil {
			if pat_use == RE_SUBST {
				emsg(cstring("E33: No previous substitute regular expression"))
			} else {
				emsg(cstring("E35: No previous regular expression"))
			}
			rc_did_emsg = true
			return 0 // FAIL
		}
		pat = spats[i].pat
		patlen = spats[i].patlen
		magic = spats[i].magic ? 1 : 0
		no_smartcase = spats[i].no_scs
	} else if options & SEARCH_HIS != 0 {
		add_to_history_r(HIST_SEARCH, transmute(cstring)(pat), patlen, true, 0)
	}

	if used_pat != nil {
		used_pat^ = pat
	}

	xfree(mr_pattern)
	if curwin != nil && w_p_rl_r(curwin) != 0 && b_at(w_p_rlc_r(curwin), 0) == 's' {
		mr_pattern = reverse_text_r(transmute(cstring)(pat))
	} else {
		mr_pattern = xstrnsave_c(transmute(cstring)(pat), patlen)
	}
	mr_patternlen = patlen

	if options & SEARCH_KEEP == 0 && cmdmod_cmod_flags & CMOD_KEEPPATTERNS == 0 {
		if pat_save == RE_SEARCH || pat_save == RE_BOTH {
			save_re_pat(RE_SEARCH, pat, patlen, magic)
		}
		if pat_save == RE_SUBST || pat_save == RE_BOTH {
			save_re_pat(RE_SUBST, pat, patlen, magic)
		}
	}

	regmatch.rmm_ic = ignorecase(pat)
	regmatch.rmm_maxcol = 0
	regmatch.regprog = vim_regcomp(transmute(cstring)(pat), magic != 0 ? RE_MAGIC : 0)
	if regmatch.regprog == nil {
		return 0
	}
	return 1 // OK
}

@(export)
get_search_pat :: proc "c"() -> ^u8 {
	return mr_pattern
}

@(export)
save_re_pat :: proc "c"(idx: C.int, pat: ^u8, patlen: C.size_t, magic: C.int) {
	if spats[idx].pat == pat {
		return
	}
	free_spat(&spats[idx])
	spats[idx].pat = xstrnsave_c(transmute(cstring)(pat), patlen)
	spats[idx].patlen = patlen
	spats[idx].magic = magic != 0
	spats[idx].no_scs = no_smartcase
	spats[idx].timestamp = os_time()
	spats[idx].additional_data = nil
	last_idx = idx
	if p_hls != 0 {
		redraw_all_later_s(UPD_SOME_VALID_S)
	}
	set_no_hlsearch_r(false)
}

@(export)
save_search_patterns :: proc "c"() {
	if save_level > 0 {
		save_level += 1
		return
	}
	save_level += 1

	for i := 0; i < 2; i += 1 {
		saved_spats[i] = spats[i]
		if spats[i].pat != nil {
			saved_spats[i].pat = xstrnsave_c(transmute(cstring)(spats[i].pat), spats[i].patlen)
			saved_spats[i].patlen = spats[i].patlen
		}
	}
	if mr_pattern == nil {
		saved_mr_pattern = nil
		saved_mr_patternlen = 0
	} else {
		saved_mr_pattern = xstrnsave_c(transmute(cstring)(mr_pattern), mr_patternlen)
		saved_mr_patternlen = mr_patternlen
	}
	saved_spats_last_idx = last_idx
	saved_spats_no_hlsearch = no_hlsearch
}

@(export)
restore_search_patterns :: proc "c"() {
	save_level -= 1
	if save_level != 0 {
		return
	}
	for i := 0; i < 2; i += 1 {
		free_spat(&spats[i])
		spats[i] = saved_spats[i]
	}
	set_vv_searchforward()
	xfree(mr_pattern)
	mr_pattern = saved_mr_pattern
	mr_patternlen = saved_mr_patternlen
	last_idx = saved_spats_last_idx
	set_no_hlsearch_r(saved_spats_no_hlsearch)
}

@(export)
free_search_patterns :: proc "c"() {
	for i := 0; i < 2; i += 1 {
		free_spat(&spats[i])
	}
	spats[0] = SearchPattern{}
	spats[1] = SearchPattern{}

	xfree(mr_pattern)
	mr_pattern = nil
	mr_patternlen = 0
}

@(export)
save_last_search_pattern :: proc "c"() {
	did_save_last_search_spat += 1
	if did_save_last_search_spat != 1 {
		return
	}
	saved_last_search_spat = spats[RE_SEARCH]
	if spats[RE_SEARCH].pat != nil {
		saved_last_search_spat.pat = xstrnsave_c(transmute(cstring)(spats[RE_SEARCH].pat), spats[RE_SEARCH].patlen)
		saved_last_search_spat.patlen = spats[RE_SEARCH].patlen
	}
	saved_last_idx = last_idx
	saved_no_hlsearch = no_hlsearch
}

@(export)
restore_last_search_pattern :: proc "c"() {
	did_save_last_search_spat -= 1
	if did_save_last_search_spat > 0 {
		return
	}
	if did_save_last_search_spat != 0 {
		emsg(cstring("E849: Too many delete and put commands")) // placeholder; C uses iemsg
		return
	}
	xfree(spats[RE_SEARCH].pat)
	spats[RE_SEARCH] = saved_last_search_spat
	saved_last_search_spat.pat = nil
	saved_last_search_spat.patlen = 0
	set_vv_searchforward()
	last_idx = saved_last_idx
	set_no_hlsearch_r(saved_no_hlsearch)
}

save_incsearch_state :: proc "c"() {
	saved_search_match_endcol = search_match_endcol_g
	saved_search_match_lines = search_match_lines_g
}

restore_incsearch_state :: proc "c"() {
	search_match_endcol_g = saved_search_match_endcol
	search_match_lines_g = saved_search_match_lines
}

@(export)
last_search_pattern :: proc "c"() -> ^u8 {
	return spats[RE_SEARCH].pat
}

@(export)
last_search_pattern_len :: proc "c"() -> C.size_t {
	return spats[RE_SEARCH].patlen
}

@(export)
ignorecase :: proc "c"(pat: ^u8) -> C.int {
	return ignorecase_opt(pat, p_ic, p_scs)
}

@(export)
ignorecase_opt :: proc "c"(pat: ^u8, ic_in: C.int, scs: C.int) -> C.int {
	ic := ic_in
	if ic != 0 && !no_smartcase && scs != 0 && !(ctrl_x_mode_not_default_r() && buf_p_inf_r(curbuf) != 0) {
		ic = pat_has_uppercase(pat) ? 0 : 1
	}
	no_smartcase = false
	return ic
}

foreign _ {
	@(link_name = "ctrl_x_mode_not_default")
	ctrl_x_mode_not_default_r :: proc "c" () -> bool ---
}

@(export)
pat_has_uppercase :: proc "c"(pat: ^u8) -> bool {
	p := pat
	magic_val: C.int = MAGIC_ON_S

	skip_regexp_ex_r(transmute(cstring)(pat), 0, magic_isset_r(), nil, nil, &magic_val)

	for b_at(p, 0) != 0 {
		l := utfc_ptr2len(transmute(cstring)(p))
		if l > 1 {
			if mb_isupper_r(utf_ptr2char(transmute(cstring)(p))) {
				return true
			}
			p = (^u8)(uintptr(p) + uintptr(l))
		} else if b_at(p, 0) == '\\' && magic_val <= MAGIC_ON_S {
			if b_at(p, 1) == '_' && b_at(p, 2) != 0 {
				p = (^u8)(uintptr(p) + 3)
			} else if b_at(p, 1) == '%' && b_at(p, 2) != 0 {
				p = (^u8)(uintptr(p) + 3)
			} else if b_at(p, 1) != 0 {
				p = (^u8)(uintptr(p) + 2)
			} else {
				p = (^u8)(uintptr(p) + 1)
			}
		} else if (b_at(p, 0) == '%' || b_at(p, 0) == '_') && magic_val == MAGIC_ALL_S {
			if b_at(p, 1) != 0 {
				p = (^u8)(uintptr(p) + 2)
			} else {
				p = (^u8)(uintptr(p) + 1)
			}
		} else if mb_isupper_r(C.int(b_at(p, 0))) {
			return true
		} else {
			p = (^u8)(uintptr(p) + 1)
		}
	}
	return false
}

MAGIC_NONE_S :: 1
MAGIC_OFF_S :: 2
MAGIC_ON_S :: 3
MAGIC_ALL_S :: 4

@(export)
last_csearch :: proc "c"() -> ^u8 {
	return &lastc_bytes[0]
}

@(export)
last_csearch_forward :: proc "c"() -> C.int {
	return lastcdir == .FORWARD ? 1 : 0
}

@(export)
last_csearch_until :: proc "c"() -> C.int {
	return last_t_cmd ? 1 : 0
}

@(export)
set_last_csearch :: proc "c"(c: C.int, s: ^u8, len: C.int) {
	lastc[0] = u8(c)
	lastc_bytelen = len
	if len != 0 {
		libc.memcpy(&lastc_bytes[0], s, C.size_t(len))
	} else {
		libc.memset(&lastc_bytes[0], 0, size_of(lastc_bytes))
	}
}

@(export)
set_csearch_direction :: proc "c"(cdir: Direction) {
	lastcdir = cdir
}

@(export)
set_csearch_until :: proc "c"(t_cmd: bool) {
	last_t_cmd = t_cmd
}

@(export)
last_search_pat :: proc "c"() -> ^u8 {
	return spats[last_idx].pat
}

@(export)
reset_search_dir :: proc "c"() {
	spats[0].off.dir = '/'
	set_vv_searchforward()
}

@(export)
set_last_search_pat :: proc "c"(s: cstring, idx: C.int, magic: C.int, setlast: bool) {
	free_spat(&spats[idx])
	if b_at(transmute(^u8)(s), 0) == 0 {
		spats[idx].pat = nil
		spats[idx].patlen = 0
	} else {
		spats[idx].patlen = libc.strlen(s)
		spats[idx].pat = xstrnsave_c(s, spats[idx].patlen)
	}
	spats[idx].timestamp = os_time()
	spats[idx].additional_data = nil
	spats[idx].magic = magic != 0
	spats[idx].no_scs = false
	spats[idx].off.dir = '/'
	set_vv_searchforward()
	spats[idx].off.line = false
	spats[idx].off.end = false
	spats[idx].off.off = 0
	if setlast {
		last_idx = idx
	}
	if save_level != 0 {
		free_spat(&saved_spats[idx])
		saved_spats[idx] = spats[0]
		if spats[idx].pat == nil {
			saved_spats[idx].pat = nil
			saved_spats[idx].patlen = 0
		} else {
			saved_spats[idx].pat = xstrnsave_c(transmute(cstring)(spats[idx].pat), spats[idx].patlen)
			saved_spats[idx].patlen = spats[idx].patlen
		}
		saved_spats_last_idx = last_idx
	}
	if p_hls != 0 && idx == last_idx && !no_hlsearch {
		redraw_all_later_s(UPD_SOME_VALID_S)
	}
}

@(export)
last_pat_prog :: proc "c"(regmatch: ^Regmmatch_T) {
	if spats[last_idx].pat == nil {
		regmatch.regprog = nil
		return
	}
	emsg_off += 1
	search_regcomp(transmute(^u8)(cstring("")), 0, nil, 0, last_idx, SEARCH_KEEP, regmatch)
	emsg_off -= 1
}

@(export)
set_search_direction :: proc "c"(cdir: C.int) {
	spats[0].off.dir = i8(cdir)
}

set_vv_searchforward :: proc "c"() {
	set_vim_var_nr_c(VV_SEARCHFORWARD_S, spats[0].off.dir == '/' ? 1 : 0)
}

VV_SEARCHFORWARD_S :: 56 // VV_SEARCHFORWARD index (vars.c VV list order)

// Return the number of the first submatch that matched (0 if none).
first_submatch :: proc "c"(rp: ^Regmmatch_T) -> C.int {
	submatch := C.int(1)
	for ;; submatch += 1 {
		if rp.startpos[submatch].lnum >= 0 {
			break
		}
		if submatch == 9 {
			submatch = 0
			break
		}
	}
	return submatch
}

// ── parse_search_pattern_offset ──────────────────────────────────────────────

@(export)
parse_search_pattern_offset :: proc "c"(
	pat: ^^u8,
	patlen: ^C.size_t,
	search_delim: C.int,
	options: C.int,
	strcopy: ^^u8,
	searchstr: ^^u8,
	searchstrlen: ^C.size_t,
	dircp: ^^u8,
	offset: ^SearchOffset,
) -> C.int {
	if pat^ == nil || b_at(pat^, 0) == 0 {
		return 0
	}

	cmdlen := C.int(0)
	ps := strcopy^

	searchstr^ = pat^
	searchstrlen^ = patlen^
	dircp^ = nil

	// Find end of regular expression; toss a matching '/' or '?'.
	p := skip_regexp_ex_r(transmute(cstring)(pat^), search_delim, magic_isset_r(), strcopy, nil, nil)
	if strcopy^ != ps {
		len := libc.strlen(transmute(cstring)(strcopy^))
		cmdlen += C.int(patlen^ - len)
		pat^ = strcopy^
		patlen^ = len
		searchstr^ = strcopy^
		searchstrlen^ = len
	}
	if b_eq(p, u8(search_delim)) {
		searchstrlen^ = C.size_t(uintptr(p) - uintptr(pat^))
		dircp^ = p
		b_set(p, 0, 0)
		p = (^u8)(uintptr(p) + 1)
	}

	offset.line = false
	offset.end = false
	offset.off = 0
	if b_eq(p, '+') || b_eq(p, '-') || ascii_isdigit_s(b_at(p, 0)) {
		offset.line = true
	} else if (options & SEARCH_OPT) != 0 && (b_eq(p, 'e') || b_eq(p, 's') || b_eq(p, 'b')) {
		if b_eq(p, 'e') {
			offset.end = true
		}
		p = (^u8)(uintptr(p) + 1)
	}
	if ascii_isdigit_s(b_at(p, 0)) || b_eq(p, '+') || b_eq(p, '-') {
		if ascii_isdigit_s(b_at(p, 0)) || ascii_isdigit_s(b_at(p, 1)) {
			offset.off = libc.atol(transmute(cstring)(p))
		} else if b_eq(p, '-') {
			offset.off = -1
		} else {
			offset.off = 1
		}
		p = (^u8)(uintptr(p) + 1)
		for ascii_isdigit_s(b_at(p, 0)) {
			p = (^u8)(uintptr(p) + 1)
		}
	}

	cmdlen += C.int(uintptr(p) - uintptr(pat^))
	patlen^ -= C.size_t(uintptr(p) - uintptr(pat^))
	pat^ = p

	return cmdlen
}

ascii_isdigit_s :: proc "c"(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// ── searchit ─────────────────────────────────────────────────────────────────

@(export)
searchit :: proc "c"(
	win: rawptr,
	buf: rawptr,
	pos: ^Pos_T,
	end_pos: ^Pos_T,
	dir: Direction,
	pat: ^u8,
	patlen: C.size_t,
	count: C.int,
	options: C.int,
	pat_use: C.int,
	extra_arg: ^searchit_arg_T,
) -> C.int {
	count_left := count
	found: C.int
	lnum: C.int
	regmatch: Regmmatch_T
	ptr: ^u8
	matchcol: C.int
	endpos: Lpos_T
	matchpos: Lpos_T
	loop: C.int
	extra_col: C.int
	start_char_len: C.int
	match_ok := false
	nmatched: C.int
	submatch := C.int(0)
	first_match := true
	called_emsg_before := called_emsg
	break_loop := false
	stop_lnum := C.int(0)
	tm: ^proftime_T = nil
	timed_out: ^C.int = nil

	if extra_arg != nil {
		stop_lnum = extra_arg.sa_stop_lnum
		tm = extra_arg.sa_tm
		timed_out = &extra_arg.sa_timed_out
	}

	if search_regcomp(pat, patlen, nil, RE_SEARCH, pat_use, options & (SEARCH_HIS + SEARCH_KEEP), &regmatch) == 0 {
		if (options & SEARCH_MSG) != 0 && !rc_did_emsg {
			semsg(cstring("E383: Cannot search string: %s"), transmute(cstring)(mr_pattern))
		}
		return 0 // FAIL
	}

	search_from_match_end := _vim_strchr(transmute(cstring)(p_cpo), CPO_SEARCH) != nil

	// find the string
	for { // loop for count
		// set "extra_col"
		if pos.col == MAXCOL {
			start_char_len = 0
		} else if pos.lnum >= 1 && pos.lnum <= buf_ml_line_count_r(buf) && pos.col < MAXCOL - 2 {
			ptr = ml_get_buf(buf, pos.lnum)
			if ml_get_buf_len(buf, pos.lnum) <= pos.col {
				start_char_len = 1
			} else {
				start_char_len = utfc_ptr2len(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(pos.col)))
			}
		} else {
			start_char_len = 1
		}
		if dir == .FORWARD {
			extra_col = (options & SEARCH_START_F) != 0 ? 0 : start_char_len
		} else {
			extra_col = (options & SEARCH_START_F) != 0 ? start_char_len : 0
		}

		start_pos := pos^
		found = 0
		at_first_line := true
		if pos.lnum == 0 {
			pos.lnum = 1
			pos.col = 0
			at_first_line = false
		}
		lnum = 0
		if dir == .BACKWARD && start_pos.col == 0 && (options & SEARCH_START_F) == 0 {
			lnum = pos.lnum - 1
			at_first_line = false
		} else {
			lnum = pos.lnum
		}

		for loop = 0; loop <= 1; loop += 1 { // loop twice if 'wrapscan'
			for ; lnum > 0 && lnum <= buf_ml_line_count_r(buf); lnum += C.int(dir) {
				defer at_first_line = false
				// Stop after checking "stop_lnum", if it's set.
				if stop_lnum != 0 && (dir == .FORWARD ? lnum > stop_lnum : lnum < stop_lnum) {
					break
				}
				if tm != nil && profile_passed_limit_r(tm^) {
					break
				}

				col := at_first_line && (options & SEARCH_COL) != 0 ? pos.col : 0
				nmatched = vim_regexec_multi_r(&regmatch, win, buf, lnum, col, tm, timed_out)
				if regmatch.regprog == nil {
					break
				}
				if called_emsg > called_emsg_before || (timed_out != nil && timed_out^ != 0) {
					break
				}
				if nmatched > 0 {
					matchpos = regmatch.startpos[0]
					endpos = regmatch.endpos[0]
					submatch = first_submatch(&regmatch)
					if lnum + matchpos.lnum > buf_ml_line_count_r(buf) {
						ptr = transmute(^u8)(cstring(""))
					} else {
						ptr = ml_get_buf(buf, lnum + matchpos.lnum)
					}

					if dir == .FORWARD && at_first_line {
						match_ok = true
						for matchpos.lnum == 0 &&
						((((options & SEARCH_END) != 0 && first_match) ?
							(nmatched == 1 && endpos.col - 1 < start_pos.col + extra_col) :
							(matchpos.col - C.int(b_at(ptr, matchpos.col) == 0 ? 1 : 0) < start_pos.col + extra_col))) {
							if search_from_match_end {
								if nmatched > 1 {
									match_ok = false
									break
								}
								matchcol = endpos.col
								if matchcol == matchpos.col && b_at(ptr, matchcol) != 0 {
									matchcol += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(matchcol)))
								}
							} else {
								matchcol = regmatch.rmm_matchcol
								if b_at(ptr, matchcol) != 0 {
									matchcol += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(matchcol)))
								}
							}
							if matchcol == 0 && (options & SEARCH_START_F) != 0 {
								break
							}
							nmatched = vim_regexec_multi_r(&regmatch, win, buf, lnum, matchcol, tm, timed_out)
							if b_at(ptr, matchcol) == 0 || nmatched == 0 {
								match_ok = false
								break
							}
							if regmatch.regprog == nil {
								break
							}
							matchpos = regmatch.startpos[0]
							endpos = regmatch.endpos[0]
							submatch = first_submatch(&regmatch)
							if matchpos.lnum != 0 {
								break
							}
							ptr = ml_get_buf(buf, lnum)
						}
						if !match_ok {
							continue
						}
					}
					if dir == .BACKWARD {
						match_ok = false
						for {
							if loop != 0 ||
							(((options & SEARCH_END) != 0) ?
								(lnum + regmatch.endpos[0].lnum < start_pos.lnum ||
								 (lnum + regmatch.endpos[0].lnum == start_pos.lnum &&
								  regmatch.endpos[0].col - 1 < start_pos.col + extra_col)) :
								(lnum + regmatch.startpos[0].lnum < start_pos.lnum ||
								 (lnum + regmatch.startpos[0].lnum == start_pos.lnum &&
								  regmatch.startpos[0].col < start_pos.col + extra_col))) {
								match_ok = true
								matchpos = regmatch.startpos[0]
								endpos = regmatch.endpos[0]
								submatch = first_submatch(&regmatch)
							} else {
								break
							}

							if search_from_match_end {
								if nmatched > 1 {
									break
								}
								matchcol = endpos.col
								if matchcol == matchpos.col && b_at(ptr, matchcol) != 0 {
									matchcol += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(matchcol)))
								}
							} else {
								if matchpos.lnum > 0 {
									break
								}
								matchcol = matchpos.col
								if b_at(ptr, matchcol) != 0 {
									matchcol += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(matchcol)))
								}
							}
							nmatched = vim_regexec_multi_r(&regmatch, win, buf, lnum + matchpos.lnum, matchcol, tm, timed_out)
							if b_at(ptr, matchcol) == 0 || nmatched == 0 {
								if tm != nil && profile_passed_limit_r(tm^) {
									match_ok = false
								}
								break
							}
							if regmatch.regprog == nil {
								break
							}
							ptr = ml_get_buf(buf, lnum + matchpos.lnum)
						}
						if !match_ok {
							continue
						}
					}

					if (options & SEARCH_END) != 0 && (options & SEARCH_NOOF) == 0 &&
					!(matchpos.lnum == endpos.lnum && matchpos.col == endpos.col) {
						pos.lnum = lnum + endpos.lnum
						pos.col = endpos.col
						if endpos.col == 0 {
							if pos.lnum > 1 {
								pos.lnum -= 1
								pos.col = ml_get_buf_len(buf, pos.lnum)
							}
						} else {
							pos.col -= 1
							if pos.lnum <= buf_ml_line_count_r(buf) {
								ptr = ml_get_buf(buf, pos.lnum)
								pos.col -= utf_head_off(transmute(cstring)(ptr), transmute(cstring)(^u8)(uintptr(ptr) + uintptr(pos.col)))
							}
						}
						if end_pos != nil {
							end_pos.lnum = lnum + matchpos.lnum
							end_pos.col = matchpos.col
						}
					} else {
						pos.lnum = lnum + matchpos.lnum
						pos.col = matchpos.col
						if end_pos != nil {
							end_pos.lnum = lnum + endpos.lnum
							end_pos.col = endpos.col
						}
					}
					pos.coladd = 0
					if end_pos != nil {
						end_pos.coladd = 0
					}
					found = 1
					first_match = false

					search_match_lines_g = endpos.lnum - matchpos.lnum
					search_match_endcol_g = endpos.col
					break
				}
				line_breakcheck()
				if got_int {
					break
				}
				if (options & SEARCH_PEEK) != 0 && ((lnum - pos.lnum) & 0x3f) == 0 && char_avail_r() {
					break_loop = true
					break
				}
				if loop != 0 && lnum == start_pos.lnum {
					break
				}
			}
			at_first_line = false

			if regmatch.regprog == nil {
				break
			}

			if p_ws_g == 0 || stop_lnum != 0 || got_int ||
			called_emsg > called_emsg_before ||
			(timed_out != nil && timed_out^ != 0) ||
			break_loop || found != 0 || loop != 0 {
				break
			}

			lnum = dir == .BACKWARD ? buf_ml_line_count_r(buf) : 1
			if !shortmess_s(SHM_SEARCH) && shortmess_s(SHM_SEARCHCOUNT) && (options & SEARCH_MSG) != 0 {
				give_warning_s(dir == .BACKWARD ? cstring("search hit BOTTOM, continuing at TOP") : cstring("search hit TOP, continuing at BOTTOM"), true, false)
			}
			if extra_arg != nil {
				extra_arg.sa_wrapped = 1
			}
		}
		if got_int || called_emsg > called_emsg_before ||
		(timed_out != nil && timed_out^ != 0) || break_loop {
			break
		}
		count_left -= 1
		if !(count_left > 0 && found != 0) {
			break
		}
	} // count loop

	vim_regfree(regmatch.regprog)

	if found == 0 {
		if got_int {
			emsg(cstring("Interrupted"))
		} else if (options & SEARCH_MSG) == SEARCH_MSG {
			if p_ws_g != 0 {
				semsg(cstring("E486: Pattern not found: %s"), transmute(cstring)(mr_pattern))
			} else if lnum == 0 {
				semsg(cstring("E384: Search hit TOP without match for: %s"), transmute(cstring)(mr_pattern))
			} else {
				semsg(cstring("E385: Search hit BOTTOM without match for: %s"), transmute(cstring)(mr_pattern))
			}
		}
		return 0
	}

	if pos.lnum > buf_ml_line_count_r(buf) {
		pos.lnum = buf_ml_line_count_r(buf)
		pos.col = ml_get_buf_len(buf, pos.lnum)
		if pos.col > 0 {
			pos.col -= 1
		}
	}

	return submatch + 1
}

// ── FFI additions (C-only helpers) ───────────────────────────────────────────

foreign _ {
	@(link_name = "p_mat")
	p_mat: C.longlong
	@(link_name = "p_ri")
	p_ri: C.int
	@(link_name = "p_inc")
	p_inc: ^u8
	@(link_name = "p_def")
	p_def: ^u8
	@(link_name = "msg_hist_off")
	msg_hist_off: C.int

	@(link_name = "ins_compl_len")
	ins_compl_len_r :: proc "c" () -> C.int ---
	@(link_name = "compl_status_adding")
	compl_status_adding :: proc "c" () -> bool ---
	@(link_name = "compl_status_sol")
	compl_status_sol :: proc "c" () -> bool ---
	@(link_name = "ins_compl_add_infercase")
	ins_compl_add_infercase :: proc "c" (str_arg: ^u8, len: C.int, icase: bool, fname: ^u8, dir: C.int, cont_s_ipos: bool, score: C.int) -> C.int ---
	@(link_name = "ins_compl_check_keys")
	ins_compl_check_keys :: proc "c" (freq: C.int, in_compl_func: bool) ---
	@(link_name = "ins_compl_interrupted")
	ins_compl_interrupted :: proc "c" () -> bool ---

	@(link_name = "find_word_start")
	find_word_start :: proc "c" (p: ^u8) -> ^u8 ---
	@(link_name = "find_word_end")
	find_word_end :: proc "c" (p: ^u8) -> ^u8 ---
	@(link_name = "vim_iswordc")
	vim_iswordc_r :: proc "c" (c: C.int) -> bool ---
	@(link_name = "vim_iswordp")
	vim_iswordp_r :: proc "c" (p: ^u8) -> bool ---
	@(link_name = "get_leader_len")
	get_leader_len :: proc "c" (line: ^u8, flags: ^C.int, backward: bool, incomment: bool) -> C.int ---
	@(link_name = "vim_isfilec")
	vim_isfilec_2 :: proc "c" (c: C.int) -> bool ---

	@(link_name = "vim_fgets")
	vim_fgets :: proc "c" (buf: ^u8, size: C.int, fp: rawptr) -> C.int ---
	@(link_name = "file_name_in_line")
	file_name_in_line :: proc "c" (fname: ^u8, len: C.size_t, options: C.int, count: C.int, rel_fname: ^u8, name_res: ^^u8) -> ^u8 ---
	@(link_name = "find_file_name_in_path")
	find_file_name_in_path :: proc "c" (ptr: cstring, len: C.size_t, options: C.int, count: C.int, rel_fname: ^u8) -> ^u8 ---
	@(link_name = "path_full_compare")
	path_full_compare_r :: proc "c" (s1: cstring, s2: cstring, checkname: bool, expand: bool) -> C.int ---

	@(link_name = "win_split")
	win_split_r :: proc "c" (size: C.int, flags: C.int) -> C.int ---
	@(link_name = "prepare_tagpreview")
	prepare_tagpreview :: proc "c" (keep_help: bool) ---
	@(link_name = "getfile")
	getfile_r :: proc "c" (fnum: C.int, ffname: ^u8, sfname: ^u8, setpm: bool, lnum: C.int, forceit: bool) -> C.int ---
	@(link_name = "win_valid")
	win_valid_r :: proc "c" (wp: rawptr) -> bool ---
	@(link_name = "win_enter")
	win_enter_r :: proc "c" (wp: rawptr, undo_sync: bool) ---
	@(link_name = "validate_cursor")
	validate_cursor_r :: proc "c" () ---

	@(link_name = "msg_trunc")
	msg_trunc_r :: proc "c" (s: ^u8, check: bool, hl_id: C.int) ---
}

FNAME_INCL_S :: 8
FNAME_REL_S :: 16
kEqualFiles_S :: 1
kOptFdoFlagSearch_S :: 0x40
MODE_SHOWMATCH_VAL :: 0x6010 // MODE_SHOWMATCH | MODE_INSERT
HLF_R_S2 :: 18
LSIZE_C :: 512

// ── trivial pattern get/set family ──────────────────────────────────────────

@(export)
get_search_pattern :: proc "c"(pat: ^SearchPattern) {
	pat^ = spats[0]
}

@(export)
get_substitute_pattern :: proc "c"(pat: ^SearchPattern) {
	pat^ = spats[1]
	pat.off = SearchOffset{}
}

@(export)
get_search_pattern_timestamp :: proc "c"(substitute: bool) -> Timestamp {
	return spats[substitute ? RE_SUBST : RE_SEARCH].timestamp
}

@(export)
search_pattern_cleared :: proc "c"(substitute: bool) -> bool {
	return spats[substitute ? RE_SUBST : RE_SEARCH].pat == nil
}

@(export)
set_search_pattern :: proc "c"(pat: SearchPattern) {
	free_spat(&spats[0])
	spats[0] = pat
	set_vv_searchforward()
}

@(export)
set_substitute_pattern :: proc "c"(pat: SearchPattern) {
	free_spat(&spats[1])
	spats[1] = pat
	spats[1].off = SearchOffset{}
}

@(export)
set_last_used_pattern :: proc "c"(is_substitute_pattern: bool) {
	last_idx = is_substitute_pattern ? 1 : 0
}

@(export)
search_was_last_used :: proc "c"() -> bool {
	return last_idx == 0
}

@(export)
linewhite :: proc "c"(lnum: C.int) -> bool {
	p := skipwhite(transmute(cstring)(ml_get(lnum)))
	return b_at(transmute(^u8)(p), 0) == 0
}

// ── searchc: f/F/t/T character search ───────────────────────────────────────

@(export)
searchc :: proc "c"(cap: ^Cmdarg_T, t_cmd_in: bool) -> C.int {
	c := cap.nchar
	dir := cap.arg
	count := cap.count1
	t_cmd := t_cmd_in
	stop := true

	if c != 0 {
		if !KeyStuffed {
			lastc[0] = u8(c)
			set_csearch_direction(dir == 1 ? .FORWARD : .BACKWARD)
			set_csearch_until(t_cmd)
			if cap.nchar_len != 0 {
				lastc_bytelen = cap.nchar_len
				libc.memcpy(&lastc_bytes[0], cap_nchar_composing(cap), C.size_t(cap.nchar_len))
			} else {
				lastc_bytelen = utf_char2bytes_r(c, &lastc_bytes[0])
			}
		}
	} else {
		if lastc[0] == 0 && lastc_bytelen <= 1 {
			return 0 // FAIL
		}
		dir = dir != 0 ? -C.int(lastcdir) : C.int(lastcdir)
		t_cmd = last_t_cmd
		c = C.int(lastc[0])

		if _vim_strchr(transmute(cstring)(p_cpo), CPO_SCOLON) == nil && count == 1 && t_cmd {
			stop = false
		}
	}

	oap_set_inclusive(cap.oap, dir != C.int(Direction.BACKWARD))

	p := get_cursor_line_ptr_r()
	col := win_cursor_col(curwin)
	line_len := get_cursor_line_len_r()

	for count > 0 {
		count -= 1
		for {
			if dir > 0 {
				col += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(p) + uintptr(col)))
				if col >= line_len {
					return 0
				}
			} else {
				if col == 0 {
					return 0
				}
				col -= utf_head_off(transmute(cstring)(p), transmute(cstring)(^u8)(uintptr(p) + uintptr(col) - 1)) + 1
			}
			if lastc_bytelen <= 1 {
				if b_at(p, col) == u8(c) && stop {
					break
				}
			} else if libc.memcmp((^u8)(uintptr(p) + uintptr(col)), &lastc_bytes[0], C.size_t(lastc_bytelen)) == 0 && stop {
				break
			}
			stop = true
		}
	}

	if t_cmd {
		col -= dir
		if dir < 0 {
			col += lastc_bytelen - 1
		} else {
			col -= utf_head_off(transmute(cstring)(p), transmute(cstring)(^u8)(uintptr(p) + uintptr(col)))
		}
	}
	win_cursor_set_col(curwin, col)

	return 1 // OK
}

// oparg_T.inclusive is at offset OAP_INCLUSIVE (see register.odin usage)
oap_set_inclusive :: proc "c"(oap: rawptr, v: bool) {
	(^bool)(uintptr(oap) + OAP_INCLUSIVE)^ = v
}

win_cursor_col :: proc "c"(wp: rawptr) -> C.int {
	return (^Pos_T)(uintptr(wp) + W_CURSOR_OFF).col
}

win_cursor_set_col :: proc "c"(wp: rawptr, col: C.int) {
	(^Pos_T)(uintptr(wp) + W_CURSOR_OFF).col = col
}

W_CURSOR_OFF :: 136

// ── search_for_exact_line (i_CTRL-X_CTRL-L / [i etc.) ───────────────────────

@(export)
search_for_exact_line :: proc "c"(buf: rawptr, pos: ^Pos_T, dir: Direction, pat: ^u8) -> C.int {
	start := C.int(0)
	compl_len := ins_compl_len_r()

	if buf_ml_line_count_r(buf) == 0 {
		return 0 // FAIL
	}
	for {
		pos.lnum += C.int(dir)
		if pos.lnum < 1 {
			if p_ws_g != 0 {
				pos.lnum = buf_ml_line_count_r(buf)
				if !shortmess_s(SHM_SEARCH) {
					give_warning_s(cstring("search hit BOTTOM, continuing at TOP"), true, false)
				}
			} else {
				pos.lnum = 1
				break
			}
		} else if pos.lnum > buf_ml_line_count_r(buf) {
			if p_ws_g != 0 {
				pos.lnum = 1
				if !shortmess_s(SHM_SEARCH) {
					give_warning_s(cstring("search hit TOP, continuing at BOTTOM"), true, false)
				}
			} else {
				pos.lnum = 1
				break
			}
		}
		if pos.lnum == start {
			break
		}
		if start == 0 {
			start = pos.lnum
		}
		ptr := ml_get_buf(buf, pos.lnum)
		p := skipwhite(transmute(cstring)(ptr))
		pos.col = C.int(uintptr(transmute(^u8)(p)) - uintptr(ptr))

		if compl_status_adding() && !compl_status_sol() {
			if mb_strcmp_ic_r(p_ic != 0, p, transmute(cstring)(pat)) == 0 {
				return 1 // OK
			}
		} else if b_at(transmute(^u8)(p), 0) != 0 {
			if (p_ic != 0 ? mb_strnicmp_r(p, transmute(cstring)(pat), C.size_t(compl_len)) :
				C.int(libc.strncmp(p, transmute(cstring)(pat), C.size_t(compl_len)))) == 0 {
				return 1
			}
		}
	}
	return 0
}

// ── is_zero_width + current_search (gn) ─────────────────────────────────────

is_zero_width :: proc "c"(pattern_in: ^u8, patternlen_in: C.size_t, move: bool, cur: ^Pos_T, direction: Direction) -> C.int {
	regmatch: Regmmatch_T
	result := C.int(-1)
	pos: Pos_T
	called_emsg_before := called_emsg
	flag := C.int(0)

	pattern := pattern_in
	patternlen := patternlen_in
	if pattern == nil {
		pattern = spats[last_idx].pat
		patternlen = spats[last_idx].patlen
	}

	if search_regcomp(pattern, patternlen, nil, RE_SEARCH, RE_SEARCH, SEARCH_KEEP, &regmatch) == 0 {
		return -1
	}

	regmatch.startpos[0].col = -1
	if move {
		pos = Pos_T{}
	} else {
		pos = cur^
		flag = SEARCH_START_F
	}
	if searchit(curwin, curbuf, &pos, nil, direction, pattern, patternlen, 1, SEARCH_KEEP + flag, RE_SEARCH, nil) != 0 {
		nmatched := C.int(0)
		for {
			regmatch.startpos[0].col += 1
			nmatched = vim_regexec_multi_r(&regmatch, curwin, curbuf, pos.lnum, regmatch.startpos[0].col, nil, nil)
			if nmatched != 0 {
				break
			}
			if !(regmatch.regprog != nil &&
			(direction == .FORWARD ? regmatch.startpos[0].col < pos.col : regmatch.startpos[0].col > pos.col)) {
				break
			}
		}
		if called_emsg == called_emsg_before {
			result = (nmatched != 0 &&
			regmatch.startpos[0].lnum == regmatch.endpos[0].lnum &&
			regmatch.startpos[0].col == regmatch.endpos[0].col) ? 1 : 0
		}
	}

		vim_regfree(regmatch.regprog)
	return result
}

// VIsual foreign var already declared in undo.odin (VIsual_g) — reuse directly.

@(export)
current_search :: proc "c"(count: C.int, forward: bool) -> C.int {
	old_p_ws := p_ws_g
	save_VIsual := VIsual_g

	if VIsual_active && b_at(p_sel_ptr(), 0) == 'e' && lt_pos_s(VIsual_g, win_cursor_r(curwin)^) {
		dec_cursor_r()
	}

	skip_first_backward := forward && VIsual_active && lt_pos_s(win_cursor_r(curwin)^, VIsual_g)

	pos := win_cursor_r(curwin)^
	orig_pos := pos
	if VIsual_active {
		if forward {
			_ = incl_pos(&pos)
		} else {
			_ = decl_pos(&pos)
		}
	}

	zero_width := is_zero_width(spats[last_idx].pat, spats[last_idx].patlen, true, &win_cursor_r(curwin)^, .FORWARD)
	if zero_width == -1 {
		return 0
	}

	end_pos: Pos_T
	for i := C.int(0); i < 2; i += 1 {
		dir: C.int
		if forward {
			if i == 0 && skip_first_backward {
				continue
			}
			dir = i
		} else {
			dir = (i == 0) ? 1 : 0
		}

		flags := C.int(0)
		if dir == 0 && zero_width == 0 {
			flags = SEARCH_END
		}
		end_pos = pos

		if i == 0 {
			p_ws_g = 0
		}

		result := searchit(curwin, curbuf, &pos, &end_pos,
			(dir != 0) ? .FORWARD : .BACKWARD,
			spats[last_idx].pat, spats[last_idx].patlen, i != 0 ? count : 1,
			SEARCH_KEEP | flags, RE_SEARCH, nil)

		p_ws_g = old_p_ws

		if i == 1 && result == 0 {
			win_cursor_r(curwin)^ = orig_pos
			if VIsual_active {
				VIsual_g = save_VIsual
			}
			return 0
		} else if i == 0 && result == 0 {
			if forward {
				pos = Pos_T{}
			} else {
				pos.lnum = buf_ml_line_count_r(buf_of_curwin())
				pos.col = ml_get_buf_len(buf_of_curwin(), pos.lnum)
			}
		}
	}

	start_pos := pos

	if !VIsual_active {
		VIsual_g = start_pos
	}

	win_cursor_r(curwin)^ = end_pos
	if lt_pos_s(VIsual_g, end_pos) && forward {
		if skip_first_backward {
			win_cursor_r(curwin)^ = pos
		} else {
			dec_cursor_r()
		}
	} else if VIsual_active && lt_pos_s(win_cursor_r(curwin)^, VIsual_g) && forward {
		win_cursor_r(curwin)^ = pos
	}
	VIsual_active = true
	VIsual_mode = 'v'

	if b_at(p_sel_ptr(), 0) == 'e' {
		if forward && ltoreq_pos(VIsual_g, win_cursor_r(curwin)^) {
			inc_cursor_r()
		} else if !forward && ltoreq_pos(win_cursor_r(curwin)^, VIsual_g) {
			_ = incl_pos(&VIsual_g)
		}
	}

	if (fdo_flags & kOptFdoFlagSearch_S) != 0 && KeyTyped {
		foldOpenCursor()
	}

	may_start_select('c')
	setmouse_r()
	redraw_curbuf_later_r(UPD_INVERTED_S2)
	_ = showmode_r()

	return 1
}

foreign _ {
	@(link_name = "may_start_select")
	may_start_select :: proc "c" (c: C.int) ---
	@(link_name = "setmouse")
	setmouse_r :: proc "c" () ---
	@(link_name = "apply_autocmds")
	apply_autocmds_c :: proc "c" (event: C.int, fname: cstring, fname2: cstring, group: bool, buf: rawptr) ---
}

// p_sel already declared in register.odin — use directly.
p_sel_ptr :: proc "c"() -> ^u8 {
	return p_sel
}

// buf_get_changedtick is a C static inline (buffer.h): changedtick_di.di_tv.vval.v_number
// changedtick_di@216, di_tv@+0, vval@+8
buf_changedtick_inline :: proc "c"(buf: rawptr) -> C.longlong {
	return (^C.longlong)(uintptr(buf) + 216 + 8)^
}

tv_list_len_i :: proc "c"(l: rawptr) -> C.int {
	if l == nil {
		return 0
	}
	// list_T.lv_len @60
	return (^C.int)(uintptr(l) + 60)^
}

UPD_INVERTED_S2 :: 20

buf_of_curwin :: proc "c"() -> rawptr {
	return (^^rawptr)(uintptr(curwin) + 8)^
}

lt_pos_s :: proc "c"(a, b: Pos_T) -> bool {
	if a.lnum != b.lnum {
		return a.lnum < b.lnum
	} else if a.col != b.col {
		return a.col < b.col
	}
	return a.coladd < b.coladd
}

ltoreq_pos :: proc "c"(a, b: Pos_T) -> bool {
	return !lt_pos_s(b, a)
}

// ── update_search_stat + cmdline_search_stat statics ────────────────────────

@(private="file")
us_lastpos: Pos_T
@(private="file")
us_cur: C.int
@(private="file")
us_cnt: C.int
@(private="file")
us_exact_match: bool
@(private="file")
us_incomplete: C.int
@(private="file")
us_last_maxcount: C.int
@(private="file")
us_chgtick: C.int
@(private="file")
us_lastpat: ^u8
@(private="file")
us_lastpatlen: C.size_t
@(private="file")
us_lbuf: rawptr

equalpos_s :: proc "c"(a, b: Pos_T) -> bool {
	return a.lnum == b.lnum && a.col == b.col && a.coladd == b.coladd
}

update_search_stat :: proc "c"(
	dirc: C.int,
	pos: ^Pos_T,
	cursor_pos: ^Pos_T,
	stat: ^searchstat_T,
	recompute: bool,
	maxcount: C.int,
	timeout: C.int,
) {
	save_ws := p_ws_g
	wraparound := false
	p := pos^

	stat.cur = 0
	stat.cnt = 0
	stat.exact_match = false
	stat.incomplete = 0
	stat.last_maxcount = 0

	empty_lastpos := us_lastpos.lnum == 0 && us_lastpos.col == 0 && us_lastpos.coladd == 0

	if dirc == 0 && !recompute && !empty_lastpos {
		stat.cur = us_cur
		stat.cnt = us_cnt
		stat.exact_match = us_exact_match
		stat.incomplete = us_incomplete
		stat.last_maxcount = C.int(p_msc)
		return
	}
	us_last_maxcount = maxcount
	wraparound = (dirc == '?' && lt_pos_s(us_lastpos, p)) ||
	(dirc == '/' && lt_pos_s(p, us_lastpos))

	spat_ok := us_lastpat != nil &&
	(libc.memcmp(us_lastpat, spats[last_idx].pat, us_lastpatlen) == 0) &&
	us_lastpatlen == spats[last_idx].patlen

	spat_cond := us_chgtick == C.int(buf_changedtick_inline(curbuf)) &&
	spat_ok &&
	equalpos_s(us_lastpos, cursor_pos^) && us_lbuf == curbuf

	if !spat_cond || wraparound || us_cur < 0 || (maxcount > 0 && us_cur > maxcount) || recompute {
		us_cur = 0
		us_cnt = 0
		us_exact_match = false
		us_incomplete = 0
		us_lastpos = Pos_T{}
		us_lbuf = curbuf
	}

	if equalpos_s(us_lastpos, cursor_pos^) && !wraparound &&
	(dirc == 0 || dirc == '/' ? us_cur < us_cnt : us_cur > 1) {
		us_cur += dirc == 0 ? 0 : dirc == '/' ? 1 : -1
	} else {
		start: proftime_T
		done_search := false
		endpos := Pos_T{}
		p_ws_g = 0
		if timeout > 0 {
			start = profile_setlimit_r(C.longlong(timeout))
		}
		for !got_int {
			if searchit(curwin, curbuf, &us_lastpos, &endpos, .FORWARD, nil, 0, 1, SEARCH_KEEP, RE_LAST, nil) == 0 {
				break
			}
			done_search = true
			if timeout > 0 && profile_passed_limit_r(start) {
				us_incomplete = 1
				break
			}
			us_cnt += 1
			if ltoreq_pos(us_lastpos, p) {
				us_cur = us_cnt
				if lt_pos_s(p, endpos) {
					us_exact_match = true
				}
			}
			fast_breakcheck()
			if maxcount > 0 && us_cnt > maxcount {
				us_incomplete = 2
				break
			}
		}
		if got_int {
			us_cur = -1
		}
		if done_search {
			xfree(us_lastpat)
			us_lastpat = xstrnsave_c(transmute(cstring)(spats[last_idx].pat), spats[last_idx].patlen)
			us_lastpatlen = spats[last_idx].patlen
			us_chgtick = C.int(buf_changedtick_inline(curbuf))
			us_lbuf = curbuf
			us_lastpos = p
		}
	}
	stat.cur = us_cur
	stat.cnt = us_cnt
	stat.exact_match = us_exact_match
	stat.incomplete = us_incomplete
	stat.last_maxcount = us_last_maxcount
	p_ws_g = save_ws
}

cmdline_search_stat :: proc "c"(
	dirc: C.int,
	pos: ^Pos_T,
	cursor_pos: ^Pos_T,
	show_top_bot_msg: bool,
	msgbuf: ^u8,
	msgbuflen: C.size_t,
	recompute: bool,
	maxcount: C.int,
	timeout: C.int,
) {
	stat: searchstat_T

	update_search_stat(dirc, pos, cursor_pos, &stat, recompute, maxcount, timeout)
	if stat.cur <= 0 {
		return
	}

	t: [SEARCH_STAT_BUF_LEN]u8
	len: C.size_t

	if w_p_rl_r(curwin) != 0 && b_at(w_p_rlc_r(curwin), 0) == 's' {
		if stat.incomplete == 1 {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[?/??]"))
		} else if stat.cnt > maxcount && stat.cur > maxcount {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[>%d/>%d]", maxcount, maxcount))
		} else if stat.cnt > maxcount {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[>%d/%d]", maxcount, stat.cur))
		} else {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[%d/%d]", stat.cnt, stat.cur))
		}
	} else {
		if stat.incomplete == 1 {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[?/??]"))
		} else if stat.cnt > maxcount && stat.cur > maxcount {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[>%d/>%d]", maxcount, maxcount))
		} else if stat.cnt > maxcount {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[%d/>%d]", stat.cur, maxcount))
		} else {
			len = C.size_t(libc.snprintf(&t[0], SEARCH_STAT_BUF_LEN, "[%d/%d]", stat.cur, stat.cnt))
		}
	}

	if show_top_bot_msg && len + 2 < SEARCH_STAT_BUF_LEN {
		libc.memmove((^u8)(uintptr(&t[0]) + 2), &t[0], len)
		b_set(&t[0], 0, 'W')
		b_set(&t[0], 1, ' ')
		len += 2
	}

	if len > msgbuflen {
		len = msgbuflen
	}
	libc.memmove((^u8)(uintptr(msgbuf) + uintptr(msgbuflen - len)), &t[0], len)

	if dirc == '?' && stat.cur == maxcount + 1 {
		stat.cur = -1
	}

	msg_ext_overwrite = true
	msg_ext_set_kind(cstring("search_count"))
	give_warning_s(transmute(cstring)(msgbuf), false, false)
}

foreign _ {
	@(link_name = "msg_ext_overwrite")
	msg_ext_overwrite: bool
}

// ── do_search ────────────────────────────────────────────────────────────────

@(export)
do_search :: proc "c"(
	oap: rawptr,
	dirc_in: C.int,
	search_delim_in: C.int,
	pat_init: ^u8,
	patlen_init: C.size_t,
	count: C.int,
	options: C.int,
	sia: ^searchit_arg_T,
) -> C.int {
	dirc := dirc_in
	search_delim := search_delim_in
	pat := pat_init
	patlen := patlen_init
	retval: C.int
	has_offset := false

	searchcmdlen = 0

	if spats[0].off.line && _vim_strchr(transmute(cstring)(p_cpo), CPO_LINEOFF) != nil {
		spats[0].off.line = false
		spats[0].off.off = 0
	}

	old_off := spats[0].off

	pos := win_cursor_r(curwin)^

	if dirc == 0 {
		dirc = C.int(spats[0].off.dir)
	} else {
		spats[0].off.dir = i8(dirc)
		set_vv_searchforward()
	}
	if options & SEARCH_REV != 0 {
		dirc = dirc == '/' ? '?' : '/'
	}

	if dirc == '/' {
		first_lnum: C.int
		if hasFolding(curwin, pos.lnum, nil, &last_lnum_dummy) {
			pos.lnum = last_lnum_dummy
			pos.col = MAXCOL - 2
		}
	} else {
		first_lnum2: C.int
		if hasFolding(curwin, pos.lnum, &first_lnum2, nil) {
			pos.lnum = first_lnum2
			pos.col = 0
		}
	}

	if no_hlsearch && options & SEARCH_KEEP == 0 {
		redraw_all_later_s(UPD_SOME_VALID_S)
		set_no_hlsearch_r(false)
	}

	strcopy: ^u8 = nil
	msgbuf: ^u8 = nil
	msgbuflen: C.size_t = 0
	show_search_stats := false

	for {
		show_top_bot_msg := false

		searchstr: ^u8 = pat
		searchstrlen: C.size_t = patlen
		dircp: ^u8 = nil

		if pat == nil || b_at(pat, 0) == 0 || b_at(pat, 0) == u8(search_delim) {
			if spats[RE_SEARCH].pat == nil {
				if spats[RE_SUBST].pat == nil {
					emsg(cstring("E35: No previous regular expression"))
					retval = 0
					break
				}
				searchstr = spats[RE_SUBST].pat
				searchstrlen = spats[RE_SUBST].patlen
			} else {
				searchstr = transmute(^u8)(cstring(""))
				searchstrlen = 0
			}
		}

		if pat != nil && b_at(pat, 0) != 0 {
			searchcmdlen += parse_search_pattern_offset(&pat, &patlen, search_delim, options,
				&strcopy, &searchstr, &searchstrlen, &dircp, &spats[0].off)
		}

		if (options & SEARCH_ECHO) != 0 && messaging_s() && msg_silent == 0 &&
		(!cmd_silent || !shortmess_s(SHM_SEARCHCOUNT)) {
			off_buf: [40]u8
			off_len: C.size_t = 0

			msg_start()
			msg_ext_set_kind(cstring("search_cmd"))

			if !cmd_silent &&
			(spats[0].off.line || spats[0].off.end || spats[0].off.off != 0) {
				b_set(&off_buf[0], C.int(off_len), u8(dirc))
				off_len += 1
				if spats[0].off.end {
					b_set(&off_buf[0], C.int(off_len), 'e')
					off_len += 1
				} else if !spats[0].off.line {
					b_set(&off_buf[0], C.int(off_len), 's')
					off_len += 1
				}
				if spats[0].off.off != 0 || spats[0].off.line {
					nn := libc.snprintf((^u8)(uintptr(&off_buf[0]) + uintptr(off_len)), size_of(off_buf) - off_len, "%lld", spats[0].off.off)
					off_len += C.size_t(nn)
				}
			}

			plen: C.size_t
			p: ^u8
			if b_at(searchstr, 0) == 0 {
				p = spats[0].pat
				plen = spats[0].patlen
			} else {
				p = searchstr
				plen = searchstrlen
			}

			msgbufsize: C.size_t
			if !shortmess_s(SHM_SEARCHCOUNT) || cmd_silent {
				if ui_has_s(kUIMessages_S) {
					msgbufsize = 0
				} else if msg_scrolled != 0 && !cmd_silent {
					msgbufsize = C.size_t((Rows - msg_row) * Columns - 1)
				} else {
					msgbufsize = C.size_t((Rows - msg_row - 1) * Columns + sc_col - 1)
				}
				if C.int(msgbufsize) < C.int(plen + off_len + SEARCH_STAT_BUF_LEN + 3) {
					msgbufsize = plen + off_len + SEARCH_STAT_BUF_LEN + 3
				}
			} else {
				msgbufsize = plen + off_len + 3
			}

			xfree(msgbuf)
			msgbuf = (^u8)(xmalloc(msgbufsize))
			libc.memset(msgbuf, ' ', msgbufsize)
			msgbuflen = msgbufsize - 1
			b_set(msgbuf, C.int(msgbuflen), 0)

			if !cmd_silent {
				ui_busy_start()
				b_set(msgbuf, 0, u8(dirc))
				if utf_iscomposing_first_r(utf_ptr2char(transmute(cstring)(p))) {
					b_set(msgbuf, 1, ' ')
					libc.memmove((^u8)(uintptr(msgbuf) + 2), p, plen)
				} else {
					libc.memmove((^u8)(uintptr(msgbuf) + 1), p, plen)
				}
				if off_len > 0 {
					libc.memmove((^u8)(uintptr(msgbuf) + uintptr(plen) + 1), &off_buf[0], off_len)
				}

				trunc := msg_strtrunc_r(msgbuf, true)
				if trunc != nil {
					xfree(msgbuf)
					msgbuf = trunc
					msgbuflen = libc.strlen(transmute(cstring)(msgbuf))
				}

				if w_p_rl_r(curwin) != 0 && b_at(w_p_rlc_r(curwin), 0) == 's' {
					r := reverse_text_r(transmute(cstring)(msgbuf))
					xfree(msgbuf)
					msgbuf = r
					msgbuflen = libc.strlen(transmute(cstring)(msgbuf))
					for b_at(r, 0) == ' ' {
						r = (^u8)(uintptr(r) + 1)
					}
				pat_len := C.size_t(uintptr(msgbuf) + uintptr(msgbuflen) - uintptr(r))
					libc.memmove(msgbuf, r, pat_len)
					if uintptr(r) - uintptr(msgbuf) >= uintptr(pat_len) {
					libc.memset(r, ' ', pat_len)
					} else {
						libc.memset((^u8)(uintptr(msgbuf) + uintptr(pat_len)), ' ', C.size_t(uintptr(r) - uintptr(msgbuf)))
					}
				}
				_ = msg_outtrans_s(transmute(cstring)(msgbuf), 0, false)
				msg_clr_eos_r()
				msg_check_r()

				gotocmdline_r(false)
				ui_flush_s()
				ui_busy_stop()
				msg_nowait = true
			}

			if !shortmess_s(SHM_SEARCHCOUNT) {
				show_search_stats = true
			}
		}

		if !spats[0].off.line && spats[0].off.off != 0 && pos.col < MAXCOL - 2 {
			c := spats[0].off.off
			if c > 0 {
				for ; c != 0; c -= 1 {
					if decl_pos(&pos) == -1 {
						break
					}
				}
				if c != 0 {
					pos.lnum = 0
					pos.col = MAXCOL
				}
			} else {
				for ; c != 0; c += 1 {
					if incl_pos(&pos) == -1 {
						break
					}
				}
				if c != 0 {
					pos.lnum = buf_ml_line_count_r(curbuf) + 1
					pos.col = 0
				}
			}
		}

		c := searchit(curwin, curbuf, &pos, nil, dirc == '/' ? .FORWARD : .BACKWARD,
			searchstr, searchstrlen, count,
			C.int(spats[0].off.end) * SEARCH_END +
			(options & (SEARCH_KEEP + SEARCH_PEEK + SEARCH_HIS + SEARCH_MSG +
			SEARCH_START_F +
			((pat != nil && b_at(pat, 0) == ';') ? 0 : SEARCH_NOOF))),
			RE_LAST, sia)

		if dircp != nil {
			b_set(dircp, 0, u8(search_delim))
		}

		if !shortmess_s(SHM_SEARCH) && sia != nil && sia.sa_wrapped != 0 {
			show_top_bot_msg = true
		}

		if c == 0 {
			retval = 0
			break
		}
		if spats[0].off.end && oap != nil {
			oap_set_inclusive(oap, true)
		}
		retval = 1

		if sia != nil && sia.sa_wrapped != 0 {
			apply_autocmds_c(EVENT_SEARCHWRAPPED_S, nil, nil, false, nil)
		}

		if !(options & SEARCH_NOOF != 0) || (pat != nil && b_at(pat, 0) == ';') {
			org_pos := pos

			if spats[0].off.line {
				cc := C.longlong(pos.lnum) + spats[0].off.off
				if cc < 1 {
					pos.lnum = 1
				} else if cc > C.longlong(buf_ml_line_count_r(curbuf)) {
					pos.lnum = buf_ml_line_count_r(curbuf)
				} else {
					pos.lnum = C.int(cc)
				}
				pos.col = 0
				retval = 2
			} else if pos.col < MAXCOL - 2 {
				cc := spats[0].off.off
				if cc > 0 {
					for cc > 0 {
						cc -= 1
						if incl_pos(&pos) == -1 {
							break
						}
					}
				} else {
					for cc < 0 {
						cc += 1
						if decl_pos(&pos) == -1 {
							break
						}
					}
				}
			}
			if !equalpos_s(pos, org_pos) {
				has_offset = true
			}
		}

		if show_search_stats {
			cmdline_search_stat(dirc, &pos, &win_cursor_r(curwin)^,
				show_top_bot_msg, msgbuf, msgbuflen,
				count != 1 || has_offset ||
				((fdo_flags & kOptFdoFlagSearch_S) == 0 &&
				hasFolding(curwin, win_cursor_r(curwin)^.lnum, nil, nil)),
				C.int(p_msc),
				SEARCH_STAT_DEF_TIMEOUT)
		}

		if !(options & SEARCH_OPT != 0) || pat == nil || b_at(pat, 0) != ';' {
			break
		}

		pat = (^u8)(uintptr(pat) + 1)
		dirc = C.int(b_at(pat, 0))
		search_delim = dirc
		if dirc != '?' && dirc != '/' {
			retval = 0
			emsg(cstring("E386: Expected '?' or '/'  after ';'"))
			break
		}
		pat = (^u8)(uintptr(pat) + 1)
		patlen -= 1
	}

	if options & SEARCH_MARK != 0 && retval != 0 {
		setpcmark()
	}
	if retval != 0 {
		win_cursor_r(curwin)^ = pos
		w_set_curswant_true(curwin)
	}

	if options & SEARCH_KEEP != 0 || cmdmod_cmod_flags & CMOD_KEEPPATTERNS != 0 {
		spats[0].off = old_off
	}
	xfree(strcopy)
	xfree(msgbuf)

	return retval
}

foreign _ {
	@(link_name = "ui_has")
	ui_has_s :: proc "c" (cap: C.int) -> bool ---
}

kUIMessages_S :: 4 // ui_defs.h kUICmdline=0..kUIMessages=4
UPD_INVERTED_S :: 20 // drawscreen.h
w_set_curswant_true :: proc "c"(wp: rawptr) {
	(^bool)(uintptr(wp) + 152)^ = true
}
last_lnum_dummy: C.int

// ── findmatch / findmatchlimit ───────────────────────────────────────────────

FM_BACKWARD :: 1
FM_FORWARD :: 2
FM_BLOCKSTOP :: 4
FM_SKIPCOMM :: 8

kMTLineWise_S :: 0 // kMTLineWise motion type

@(export)
findmatch :: proc "c"(oap: rawptr, initc: C.int) -> ^Pos_T {
	return findmatchlimit(oap, initc, 0, 0)
}

check_prevcol :: proc "c"(linep: ^u8, col_in: C.int, ch: C.int, prevcol: ^C.int) -> bool {
	col := col_in - 1
	if col > 0 {
		col -= utf_head_off(transmute(cstring)(linep), transmute(cstring)(^u8)(uintptr(linep) + uintptr(col)))
	}
	if prevcol != nil {
		prevcol^ = col
	}
	return col >= 0 && C.int(b_at(linep, col)) == ch
}

find_rawstring_end :: proc "c"(linep: ^u8, startpos: ^Pos_T, endpos: ^Pos_T) -> bool {
	p := (^u8)(uintptr(linep) + uintptr(startpos.col) + 1)
	for b_at(p, 0) != 0 && b_at(p, 0) != '(' {
		p = (^u8)(uintptr(p) + 1)
	}

	delim_len := C.size_t(uintptr(p) - uintptr(linep)) - C.size_t(startpos.col) - 1
	delim_copy := xmemdupz_c((^u8)(uintptr(linep) + uintptr(startpos.col) + 1), C.size_t(delim_len))
	found := false
	lnum := startpos.lnum
	for ; lnum <= endpos.lnum; lnum += 1 {
		line := ml_get(lnum)

		p = (^u8)(uintptr(line) + uintptr(lnum == startpos.lnum ? startpos.col + 1 : 0))
		for b_at(p, 0) != 0 {
			if lnum == endpos.lnum && C.int(uintptr(p) - uintptr(line)) >= endpos.col {
				break
			}
			if b_at(p, 0) == ')' &&
			libc.memcmp(delim_copy, (^u8)(uintptr(p) + 1), delim_len) == 0 &&
			b_at(p, C.int(delim_len + 1)) == '"' {
				found = true
				break
			}
			p = (^u8)(uintptr(p) + 1)
		}
		if found {
			break
		}
	}
	xfree(delim_copy)
	return found
}

foreign _ {
	@(link_name = "xmemdupz")
	xmemdupz_c :: proc "c" (s: ^u8, len: C.size_t) -> ^u8 ---
}

// Check matchpairs option for "*initc".
find_mps_values :: proc "c"(initc: ^C.int, findc: ^C.int, backwards: ^bool, switchit: bool) {
	ptr := buf_p_mps_r(curbuf)

	for b_at(ptr, 0) != 0 {
		if utf_ptr2char(transmute(cstring)(ptr)) == initc^ {
			if switchit {
				findc^ = initc^
				initc^ = utf_ptr2char(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(utfc_ptr2len(transmute(cstring)(ptr))) + 1))
				backwards^ = true
			} else {
				findc^ = utf_ptr2char(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(utfc_ptr2len(transmute(cstring)(ptr))) + 1))
				backwards^ = false
			}
			return
		}
		prev := ptr
		ptr = (^u8)(uintptr(ptr) + uintptr(utfc_ptr2len(transmute(cstring)(ptr))) + 1)
		if utf_ptr2char(transmute(cstring)(ptr)) == initc^ {
			if switchit {
				findc^ = initc^
				initc^ = utf_ptr2char(transmute(cstring)(prev))
				backwards^ = false
			} else {
				findc^ = utf_ptr2char(transmute(cstring)(prev))
				backwards^ = true
			}
			return
		}
		ptr = (^u8)(uintptr(ptr) + uintptr(utfc_ptr2len(transmute(cstring)(ptr))))
		if b_at(ptr, 0) == ',' {
			ptr = (^u8)(uintptr(ptr) + 1)
		}
	}
}

// findmatchlimit: find matching paren/brace with travel limit.
@(private="file")
fml_pos: Pos_T // C findmatchlimit's static pos

@(export)
findmatchlimit :: proc "c"(oap: rawptr, initc_in: C.int, flags: C.int, maxtravel: C.longlong) -> ^Pos_T {
pos := &fml_pos
	findc := C.int(0)
	count := C.int(0)
	backwards := false
	raw_string := false
	inquote := false
	hash_dir := C.int(0)
	comment_dir := C.int(0)
	traveled := C.int(0)
	ignore_cend := false
	match_escaped := C.int(0)
	dir := C.int(0)
	comment_col: C.int = MAXCOL
	lispcomm := false
	lisp := buf_p_lisp_r(curbuf) != 0
	skip_comments := (flags & FM_SKIPCOMM) != 0
	in_block_comment := false

	pos^ = win_cursor_r(curwin)^
	pos.coladd = 0
	linep := ml_get(pos.lnum)

	cpo_match := _vim_strchr(transmute(cstring)(p_cpo), CPO_MATCH) != nil
	cpo_bsl := _vim_strchr(transmute(cstring)(p_cpo), CPO_MATCHBSL) != nil

	if (flags & FM_BACKWARD) != 0 {
		dir = C.int(Direction.BACKWARD)
	} else if (flags & FM_FORWARD) != 0 {
		dir = C.int(Direction.FORWARD)
	} else {
		dir = 0
	}

	initc := initc_in
	if initc == '/' || initc == '*' || initc == 'R' {
		comment_dir = dir
		if initc == '/' {
			ignore_cend = true
		}
		backwards = dir == C.int(Direction.FORWARD) ? false : true
		raw_string = initc == 'R'
		initc = 0
	} else if initc != '#' && initc != 0 {
		find_mps_values(&initc, &findc, &backwards, true)
		if dir != 0 {
			backwards = dir == C.int(Direction.FORWARD) ? false : true
		}
		if findc == 0 {
			return nil
		}
	} else {
		if initc == '#' {
			hash_dir = dir
		} else {
			if !cpo_match {
				ptr := skipwhite(transmute(cstring)(linep))
				if b_at(transmute(^u8)(ptr), 0) == '#' && pos.col <= C.int(uintptr(transmute(^u8)(ptr)) - uintptr(linep)) {
					ptr2 := skipwhite(transmute(cstring)(^u8)(uintptr(transmute(^u8)(ptr)) + 1))
					if libc.strncmp(ptr2, "if", 2) == 0 ||
					libc.strncmp(ptr2, "endif", 5) == 0 ||
					libc.strncmp(ptr2, "el", 2) == 0 {
						hash_dir = 1
					}
				} else if b_at(linep, pos.col) == '/' {
					if b_at(linep, pos.col + 1) == '*' {
						comment_dir = C.int(Direction.FORWARD)
						backwards = false
						pos.col += 1
					} else if pos.col > 0 && b_at(linep, pos.col - 1) == '*' {
						comment_dir = C.int(Direction.BACKWARD)
						backwards = true
						pos.col -= 1
					}
				} else if b_at(linep, pos.col) == '*' {
					if b_at(linep, pos.col + 1) == '/' {
						comment_dir = C.int(Direction.BACKWARD)
						backwards = true
					} else if pos.col > 0 && b_at(linep, pos.col - 1) == '/' {
						comment_dir = C.int(Direction.FORWARD)
						backwards = false
					}
				}
			}

			if hash_dir == 0 && comment_dir == 0 {
				if b_at(linep, pos.col) == 0 && pos.col != 0 {
					pos.col -= 1
				}
				for {
					initc = utf_ptr2char(transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col)))
					if initc == 0 {
						break
					}
					find_mps_values(&initc, &findc, &backwards, false)
					if findc != 0 {
						break
					}
					pos.col += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col)))
				}
				if findc == 0 {
					if !cpo_match && b_at(transmute(^u8)(skipwhite(transmute(cstring)(linep))), 0) == '#' {
						hash_dir = 1
					} else {
						return nil
					}
				} else if !cpo_bsl {
					bslcnt := C.int(0)
					col := pos.col
					for check_prevcol(linep, col, '\\', &col) {
						bslcnt += 1
					}
					match_escaped = bslcnt & 1
				}
			}
		}
		if hash_dir != 0 {
			if oap != nil {
				b_set((^u8)(oap), kMTLineWise_S + OAP_MOTION_OFF, u8(kMTLineWise_S))
			}
			if initc != '#' {
				ptr3 := skipwhite(transmute(cstring)(skipwhite(transmute(cstring)(linep))))
				ptr3 = transmute(cstring)(^u8)(uintptr(transmute(^u8)(ptr3)) + 1)
				if libc.strncmp(ptr3, "if", 2) == 0 || libc.strncmp(ptr3, "el", 2) == 0 {
					hash_dir = 1
				} else if libc.strncmp(ptr3, "endif", 5) == 0 {
					hash_dir = -1
				} else {
					return nil
				}
			}
			pos.col = 0
			for !got_int {
				if hash_dir > 0 {
					if pos.lnum == buf_ml_line_count_r(curbuf) {
						break
					}
				} else if pos.lnum == 1 {
					break
				}
				pos.lnum += hash_dir
				linep = ml_get(pos.lnum)
				line_breakcheck()
				ptr4 := skipwhite(transmute(cstring)(linep))
				if b_at(transmute(^u8)(ptr4), 0) != '#' {
					continue
				}
				pos.col = C.int(uintptr(transmute(^u8)(ptr4)) - uintptr(linep))
				ptr5 := skipwhite(transmute(cstring)(^u8)(uintptr(transmute(^u8)(ptr4)) + 1))
				if hash_dir > 0 {
					if libc.strncmp(ptr5, "if", 2) == 0 {
						count += 1
					} else if libc.strncmp(ptr5, "el", 2) == 0 {
						if count == 0 {
							return pos
						}
					} else if libc.strncmp(ptr5, "endif", 5) == 0 {
						if count == 0 {
							return pos
						}
						count -= 1
					}
				} else {
					if libc.strncmp(ptr5, "if", 2) == 0 {
						if count == 0 {
							return pos
						}
						count -= 1
					} else if initc == '#' && libc.strncmp(ptr5, "el", 2) == 0 {
						if count == 0 {
							return pos
						}
					} else if libc.strncmp(ptr5, "endif", 5) == 0 {
						count += 1
					}
				}
			}
			return nil
		}
	}

	if w_p_rl_r(curwin) != 0 && _vim_strchr(cstring("()[]{}<>"), initc) != nil {
		backwards = !backwards
	}

	do_quotes := C.int(-1)
	at_start := C.int(0)
	start_in_quotes := TriState.kNone
	match_pos: Pos_T
	match_pos = Pos_T{}

	if (backwards && comment_dir != 0) || lisp || skip_comments {
		comment_col = check_linecomment_r(linep)
	}
	if lisp && comment_col != MAXCOL && pos.col > comment_col {
		lispcomm = true
	}
	if skip_comments && !in_block_comment && comment_col != MAXCOL && backwards && pos.col > comment_col {
		pos.col = comment_col
	}

	for !got_int {
		if backwards {
			if lispcomm && pos.col < comment_col {
				break
			}
			if pos.col == 0 {
				if pos.lnum == 1 {
					break
				}
				pos.lnum -= 1

				if maxtravel > 0 {
					traveled += 1
					if C.longlong(traveled) > maxtravel {
						break
					}
				}

				linep = ml_get(pos.lnum)
				pos.col = ml_get_len_r2(pos.lnum)
				do_quotes = -1
				line_breakcheck()

				if comment_dir != 0 || lisp || skip_comments {
					comment_col = check_linecomment_r(linep)
				}
				if lisp && comment_col != MAXCOL {
					pos.col = comment_col
				} else if skip_comments && !in_block_comment &&
				comment_col != MAXCOL && pos.col > comment_col {
					pos.col = comment_col
				}
			} else {
				pos.col -= 1
				pos.col -= utf_head_off(transmute(cstring)(linep), transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col)))
			}
		} else {
			if b_at(linep, pos.col) == 0 ||
			(lisp && comment_col != MAXCOL && pos.col == comment_col) {
				if pos.lnum == buf_ml_line_count_r(curbuf) || lispcomm {
					break
				}
				pos.lnum += 1

				if maxtravel != 0 {
					traveled += 1
					if C.longlong(traveled) > maxtravel {
						break
					}
				}

				linep = ml_get(pos.lnum)
				pos.col = 0
				do_quotes = -1
				line_breakcheck()
				if lisp || skip_comments {
					comment_col = check_linecomment_r(linep)
				}
			} else {
				pos.col += utfc_ptr2len(transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col)))
			}
		}

		if skip_comments && comment_dir == 0 && !inquote {
			if backwards {
				if !in_block_comment && pos.col > 0 &&
				b_at(linep, pos.col - 1) == '*' && b_at(linep, pos.col) == '/' &&
				(comment_col == MAXCOL || pos.col < comment_col) {
					in_block_comment = true
				} else if in_block_comment && pos.col > 0 &&
				b_at(linep, pos.col - 1) == '/' && b_at(linep, pos.col) == '*' {
					in_block_comment = false
				}
			} else {
				if !in_block_comment && b_at(linep, pos.col) == '/' &&
				b_at(linep, pos.col + 1) == '*' &&
				(comment_col == MAXCOL || pos.col < comment_col) {
					in_block_comment = true
				} else if in_block_comment && pos.col > 0 &&
				b_at(linep, pos.col - 1) == '*' && b_at(linep, pos.col) == '/' {
					in_block_comment = false
				}
			}
		}

		if pos.col == 0 && (flags & FM_BLOCKSTOP) != 0 &&
		(b_at(linep, 0) == '{' || b_at(linep, 0) == '}') {
			if C.int(b_at(linep, 0)) == findc && count == 0 {
				return pos
			}
			break
		}

		if comment_dir != 0 {
			if comment_dir == C.int(Direction.FORWARD) {
				if b_at(linep, pos.col) == '*' && b_at(linep, pos.col + 1) == '/' {
					pos.col += 1
					return pos
				}
			} else {
				if pos.col == 0 {
					continue
				} else if raw_string {
					if b_at(linep, pos.col - 1) == 'R' &&
					b_at(linep, pos.col) == '"' &&
					_vim_strchr(transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col) + 1), '(') != nil {
						endp := curwin == nil ? &match_pos : &win_cursor_r(curwin)^
						if count > 0 {
							endp = &match_pos
						} else {
							endp = &win_cursor_r(curwin)^
						}
					if !find_rawstring_end(linep, pos, endp) {
						count += 1
						match_pos = pos^
						match_pos.col -= 1
					}
						linep = ml_get(pos.lnum)
					}
				} else if b_at(linep, pos.col - 1) == '/' &&
				b_at(linep, pos.col) == '*' &&
				(pos.col == 1 || b_at(linep, pos.col - 2) != '*') &&
				pos.col < comment_col {
					count += 1
					match_pos = pos^
					match_pos.col -= 1
				} else if b_at(linep, pos.col - 1) == '*' && b_at(linep, pos.col) == '/' {
					if count > 0 {
						pos^ = match_pos
					} else if pos.col > 1 && b_at(linep, pos.col - 2) == '/' &&
					pos.col <= comment_col {
						pos.col -= 2
					} else if ignore_cend {
						continue
					} else {
						return nil
					}
					return pos
				}
			}
			continue
		}

		if cpo_match {
			do_quotes = 0
		} else if do_quotes == -1 {
			at_start = do_quotes
			qptr := linep
			for b_at(qptr, 0) != 0 {
				if uintptr(qptr) == uintptr(linep) + uintptr(pos.col) + (backwards ? 1 : 0) {
					at_start = do_quotes & 1
				}
				if b_at(qptr, 0) == '"' &&
				(uintptr(qptr) == uintptr(linep) || (b_at(qptr, -1) != '\'' || b_at(qptr, 1) != '\'')) {
					do_quotes += 1
				}
				if b_at(qptr, 0) == '\\' && b_at(qptr, 1) != 0 {
					qptr = (^u8)(uintptr(qptr) + 1)
				}
				qptr = (^u8)(uintptr(qptr) + 1)
			}
			do_quotes &= 1

			if do_quotes == 0 {
				inquote = false
				if b_at(qptr, -1) == '\\' {
					do_quotes = 1
					if start_in_quotes == .kNone {
						inquote = at_start != 0
						if inquote {
							start_in_quotes = .kTrue
						}
					} else if backwards {
						inquote = true
					}
				}
				if pos.lnum > 1 {
					pprev := ml_get(pos.lnum - 1)
					if b_at(pprev, 0) != 0 && b_at(pprev, ml_get_len_r2(pos.lnum - 1) - 1) == '\\' {
						do_quotes = 1
						if start_in_quotes == .kNone {
							inquote = at_start != 0
							if inquote {
								start_in_quotes = .kTrue
							}
						} else if !backwards {
							inquote = true
						}
					}
					linep = ml_get(pos.lnum)
				}
			}
		}
		if start_in_quotes == .kNone {
			start_in_quotes = .kFalse
		}

		cc := utf_ptr2char(transmute(cstring)(^u8)(uintptr(linep) + uintptr(pos.col)))
		switch cc {
		case 0:
			if pos.col == 0 || b_at(linep, pos.col - 1) != '\\' {
				inquote = false
				start_in_quotes = .kFalse
			}
		case '"':
			if do_quotes != 0 {
				col2 := pos.col - 1
				for ; col2 >= 0; col2 -= 1 {
					if b_at(linep, col2) != '\\' {
						break
					}
				}
				if ((pos.col - 1 - col2) & 1) == 0 {
					inquote = !inquote
					start_in_quotes = .kFalse
				}
			}
		case '\'':
			if !cpo_match && initc != '\'' && findc != '\'' {
				if backwards {
					if pos.col > 1 {
						if b_at(linep, pos.col - 2) == '\'' {
							pos.col -= 2
							break
						} else if b_at(linep, pos.col - 2) == '\\' &&
						pos.col > 2 && b_at(linep, pos.col - 3) == '\'' {
							pos.col -= 3
							break
						}
					}
				} else if b_at(linep, pos.col + 1) != 0 {
					if b_at(linep, pos.col + 1) == '\\' &&
					b_at(linep, pos.col + 2) != 0 && b_at(linep, pos.col + 3) == '\'' {
						pos.col += 3
						break
					} else if b_at(linep, pos.col + 2) == '\'' {
						pos.col += 2
						break
					}
				}
			}
			fallthrough
		case:
			if buf_p_lisp_r(curbuf) != 0 &&
			(_vim_strchr(cstring("(){}[]"), cc) != nil) &&
			pos.col > 1 &&
			check_prevcol(linep, pos.col, '\\', nil) &&
			check_prevcol(linep, pos.col - 1, '#', nil) {
				break
			}

			if skip_comments &&
			(in_block_comment ||
			(comment_col != MAXCOL && pos.col >= comment_col)) {
				break
			}

			if (!inquote || start_in_quotes == .kTrue) &&
			(cc == initc || cc == findc) {
				bslcnt := C.int(0)

				if !cpo_bsl {
					col3 := pos.col
					for check_prevcol(linep, col3, '\\', &col3) {
						bslcnt += 1
					}
				}
				if cpo_bsl || (bslcnt & 1) == match_escaped {
					if cc == initc {
						count += 1
					} else {
						if count == 0 {
							return pos
						}
						count -= 1
					}
				}
			}
		}
	}

	if comment_dir == C.int(Direction.BACKWARD) && count > 0 {
		pos^ = match_pos
		return pos
	}
	return nil
}

OAP_MOTION_OFF :: 8 // oparg_T.motion_type offset (register.odin: oap fields)

// ── showmatch ────────────────────────────────────────────────────────────────

@(export)
showmatch :: proc "c"(c: C.int) {
	vcol := C.int(0)

	// Only show match for chars in the 'matchpairs' option.
	p := buf_p_mps_r(curbuf)
	found := false
	for b_at(p, 0) != 0 {
		if utf_ptr2char(transmute(cstring)(p)) == c && (w_p_rl_r(curwin) != 0 ? p_ri == 0 : p_ri != 0) {
			found = true
			break
		}
		p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))) + 1)
		if utf_ptr2char(transmute(cstring)(p)) == c && (w_p_rl_r(curwin) != 0 ? p_ri != 0 : p_ri == 0) {
			found = true
			break
		}
		p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
		if b_at(p, 0) == 0 {
			return
		}
	}
	if !found {
		return
	}

	lpos := findmatch(nil, 0)
	if lpos == nil {
		vim_beep_r(kOptBoFlagShowmatch_S)
		return
	}

	if lpos.lnum < w_topline_r(curwin) || lpos.lnum >= w_botline_r(curwin) {
		return
	}

	if w_p_wrap_r(curwin) == 0 {
		getvcol_s(curwin, lpos, nil, nil, &vcol, 0)
	}

	col_visible := w_p_wrap_r(curwin) != 0 ||
	(vcol >= w_leftcol_r(curwin) && vcol < w_leftcol_r(curwin) + w_view_width_r(curwin))
	if !col_visible {
		return
	}

	mpos := lpos^
	save_cursor := win_cursor_r(curwin)^

	// Handle "$" in 'cpo': stop displaying the "$".
	save_dollar_vcol := dollar_vcol
	if dollar_vcol >= 0 && dollar_vcol == w_virtcol_r(curwin) {
		dollar_vcol = -1
	}
	// curwin->w_virtcol++
	w_virtcol_add(curwin, 1)

	save_state := State
	State = MODE_SHOWMATCH_VAL
	ui_cursor_shape_r()
	win_cursor_r(curwin)^ = mpos
	// *so = 0; *siso = 0 — via offsets; save first
	save_so := w_p_so_r(curwin)
	save_siso := w_p_siso_r(curwin)
	w_p_so_set(curwin, 0)
	w_p_siso_set(curwin, 0)
	show_cursor_info_later_r(false)
	_ = update_screen_r()
	setcursor_r()
	ui_flush_s()
	dollar_vcol = save_dollar_vcol

	if _vim_strchr(transmute(cstring)(p_cpo), CPO_SHOWMATCH) != nil {
		os_delay(C.ulonglong(p_mat)*100 + 8, true)
	} else if !char_avail_r() {
		os_delay(C.ulonglong(p_mat)*100 + 9, false)
	}
	win_cursor_r(curwin)^ = save_cursor
	w_p_so_set(curwin, save_so)
	w_p_siso_set(curwin, save_siso)
	State = save_state
	ui_cursor_shape_r()
}

w_virtcol_add :: proc "c"(wp: rawptr, n: C.int) {
	(^C.int)(uintptr(wp) + 596)^ += n
}
w_p_so_set :: proc "c"(wp: rawptr, v: C.longlong) {
	(^C.longlong)(uintptr(wp) + 1176)^ = v
}
w_p_siso_set :: proc "c"(wp: rawptr, v: C.longlong) {
	(^C.longlong)(uintptr(wp) + 1168)^ = v
}

// ── f_searchcount ────────────────────────────────────────────────────────────

foreign _ {
	@(link_name = "tv_dict_find")
	tv_dict_find_r :: proc "c" (d: rawptr, key: cstring, len: C.ssize_t) -> rawptr ---
	@(link_name = "tv_get_number_chk")
	tv_get_number_chk_r :: proc "c" (arg: ^Typval, err: ^bool) -> C.longlong ---
	// tv_list_len is a C static inline — see tv_list_len_i below.
}

// dictitem_T in this tree: di_tv is FIRST (typval_defs.h TV_DICTITEM_STRUCT)
di_tv_of :: proc "c"(di: rawptr) -> ^Typval {
	return (^Typval)(di)
}
li_tv_of :: proc "c"(li: rawptr) -> ^Typval {
	return (^Typval)(uintptr(li) + 16)
}
tv_vval_dict :: proc "c"(tv: ^Typval) -> rawptr {
	return (^rawptr)(uintptr(tv) + 8)^
}

VAR_LIST_S :: 4 // VAR_LIST in typval enum

tv_get_string_chk_r :: proc "c"(arg: ^Typval) -> ^u8 {
	return tv_get_string_chk_r2(arg)
}
tv_v_list_ptr :: proc "c"(tv: ^Typval) -> rawptr {
	return (^rawptr)(uintptr(tv) + 8)^
}

@(export)
f_searchcount :: proc "c"(argvars: ^Typval, rettv: ^Typval, fptr: rawptr) {
	pos := win_cursor_r(curwin)^
	pattern: ^u8 = nil
	maxcount := C.int(p_msc)
	timeout: C.int = SEARCH_STAT_DEF_TIMEOUT
	recompute := true
	stat: searchstat_T

	tv_dict_alloc_ret_r(rettv)

	if shortmess_s(SHM_SEARCHCOUNT) {
		recompute = true
	}

	if ([^]Typval)(argvars)[0].v_type != VAR_UNKNOWN {
		err := false

		if tv_check_nonnull_dict_arg(argvars, 0) == 0 {
			return
		}
		dict := tv_vval_dict(&([^]Typval)(argvars)[0])
		di := tv_dict_find_r(dict, "timeout", -C.ssize_t(1))
		if di != nil {
			timeout = C.int(tv_get_number_chk_r(di_tv_of(di), &err))
			if err {
				return
			}
		}
		di = tv_dict_find_r(dict, "maxcount", -C.ssize_t(1))
		if di != nil {
			maxcount = C.int(tv_get_number_chk_r(di_tv_of(di), &err))
			if err {
				return
			}
		}
		di = tv_dict_find_r(dict, "recompute", -C.ssize_t(1))
		if di != nil {
			recompute = tv_get_number_chk_r(di_tv_of(di), &err) != 0
			if err {
				return
			}
		}
		di = tv_dict_find_r(dict, "pattern", -C.ssize_t(1))
		if di != nil {
			pattern = tv_get_string_chk_r(di_tv_of(di))
			if pattern == nil {
				return
			}
		}
		di = tv_dict_find_r(dict, "pos", -C.ssize_t(1))
		if di != nil {
			di_tv := di_tv_of(di)
			if di_tv.v_type != VAR_LIST_S {
				semsg(cstring("E728: Using a Dictionary as a Number"), "pos")
				return
			}
			l := tv_v_list_ptr(di_tv)
			if tv_list_len_i(l) != 3 {
				semsg(cstring("E1210: Number required for argument 1"), "List format should be [lnum, col, off]")
				return
			}
			li := tv_list_find(l, 0)
			if li != nil {
				pos.lnum = C.int(tv_get_number_chk_r(li_tv_of(li), &err))
				if err {
					return
				}
			}
			li = tv_list_find(l, 1)
			if li != nil {
				pos.col = C.int(tv_get_number_chk_r(li_tv_of(li), &err)) - 1
				if err {
					return
				}
			}
			li = tv_list_find(l, 2)
			if li != nil {
				pos.coladd = C.int(tv_get_number_chk_r(li_tv_of(li), &err))
				if err {
					return
				}
			}
		}
	}

	save_last_search_pattern()
	save_incsearch_state()
	if pattern != nil {
		if b_at(pattern, 0) == 0 {
			restore_last_search_pattern()
			restore_incsearch_state()
			return
		}
		xfree(spats[last_idx].pat)
		spats[last_idx].patlen = libc.strlen(transmute(cstring)(pattern))
		spats[last_idx].pat = xstrnsave_c(transmute(cstring)(pattern), spats[last_idx].patlen)
	}
	if spats[last_idx].pat == nil || b_at(spats[last_idx].pat, 0) == 0 {
		restore_last_search_pattern()
		restore_incsearch_state()
		return
	}

	update_search_stat(0, &pos, &pos, &stat, recompute, maxcount, timeout)

	tv_dict_add_nr_m(tv_vval_dict(rettv), cstring("current"), 8, i64(stat.cur))
	tv_dict_add_nr_m(tv_vval_dict(rettv), cstring("total"), 5, i64(stat.cnt))
	tv_dict_add_nr_m(tv_vval_dict(rettv), cstring("exact_match"), 12, i64(bool_int(stat.exact_match)))
	tv_dict_add_nr_m(tv_vval_dict(rettv), cstring("incomplete"), 10, i64(stat.incomplete))
	tv_dict_add_nr_m(tv_vval_dict(rettv), cstring("maxcount"), 8, i64(stat.last_maxcount))

	restore_last_search_pattern()
	restore_incsearch_state()
}

bool_int :: proc "c"(b: bool) -> C.int {
	return b ? 1 : 0
}

foreign _ {
	@(link_name = "tv_check_for_nonnull_dict_arg")
	tv_check_nonnull_dict_arg :: proc "c" (argvars: ^Typval, idx: C.int) -> C.int ---
	@(link_name = "tv_get_string_chk")
	tv_get_string_chk_r2 :: proc "c" (arg: ^Typval) -> ^u8 ---
}

// ── find_pattern_in_path ([i, [d, [I, i_CTRL-X_CTRL-[ etc.) ─────────────────

FIND_ANY_S :: 1
FIND_DEFINE_S :: 2
CHECK_PATH_S :: 3
ACTION_SHOW_S :: 1
ACTION_GOTO_S :: 2
ACTION_SPLIT_S :: 3
ACTION_SHOW_ALL_S :: 4
ACTION_EXPAND_S :: 5

get_line_and_copy :: proc "c"(lnum: C.int, buf: ^u8) -> ^u8 {
	line := ml_get(lnum)
	libc.strncpy(buf, transmute(cstring)(line), LSIZE_C)
	return buf
}

@(export)
find_pattern_in_path :: proc "c"(
	ptr: ^u8,
	dir: Direction,
	len: C.size_t,
	whole: bool,
	skip_comments_in: bool,
	type_: C.int,
	count: C.int,
	action: C.int,
	start_lnum: C.int,
	end_lnum_in: C.int,
	forceit: bool,
	silent: bool,
) {
	files: [^]SearchedFile
	bigger: [^]SearchedFile
	max_path_depth := C.int(50)
	match_count := C.int(1)

	new_fname: ^u8
	prev_fname: ^u8 = nil
	depth_displayed := C.int(-1)
	matched := false
	did_show := false
	found := false
	already: ^u8 = nil
	startp: ^u8 = nil
	curwin_save: rawptr = nil
	l_g_do_tagpreview := g_do_tagpreview

	regmatch: Regmatch_T
	incl_regmatch: Regmatch_T
	def_regmatch: Regmatch_T
	regmatch.regprog = nil
	incl_regmatch.regprog = nil
	def_regmatch.regprog = nil

	file_line := (^u8)(xmalloc(LSIZE_C))
	defer xfree(file_line)

	fpip_end: bool = false // emulate goto fpip_end via flag+block below

	if type_ != CHECK_PATH_S && type_ != FIND_DEFINE_S && !compl_status_sol() {
		patsize := len + 5
		patbuf := (^u8)(xmalloc(patsize))
		if whole {
			libc.snprintf(patbuf, patsize, "\\<%.*s\\>", C.int(len), transmute(cstring)(ptr))
		} else {
			libc.snprintf(patbuf, patsize, "%.*s", C.int(len), transmute(cstring)(ptr))
		}
		regmatch.rm_ic = ignorecase(patbuf)
		regmatch.regprog = vim_regcomp(transmute(cstring)(patbuf), magic_isset_r() != 0 ? RE_MAGIC : 0)
		xfree(patbuf)
		if regmatch.regprog == nil {
			fpip_end = true
		}
	}
	if !fpip_end {
		inc_opt := b_at(buf_p_inc_r(curbuf), 0) == 0 ? p_inc : buf_p_inc_r(curbuf)
		curr_fname := buf_fname_r(curbuf)
		dir_cur := dir
		count_left := count
		files_arr := xcalloc_c(C.size_t(max_path_depth), size_of(SearchedFile))
		files = ([^]SearchedFile)(files_arr)
		old_files := max_path_depth
		depth := C.int(-1)
		depth_displayed = -1

		end_lnum := end_lnum_in < buf_ml_line_count_r(curbuf) ? end_lnum_in : buf_ml_line_count_r(curbuf)
		lnum := start_lnum < end_lnum ? start_lnum : end_lnum
		line := get_line_and_copy(lnum, file_line)

		for true {
			p: ^u8 = nil
			define_matched := false
			outer_break := false

			if incl_regmatch.regprog != nil && vim_regexec_r(&incl_regmatch, line, 0) != 0 {
				p_fname := curr_fname == buf_fname_r(curbuf) ? buf_ffname_r(curbuf) : curr_fname

				if strstr_c(transmute(cstring)(inc_opt), cstring("\\zs")) != nil {
					new_fname = find_file_name_in_path(transmute(cstring)(incl_regmatch.startp[0]),
						C.size_t(uintptr(incl_regmatch.endp[0]) - uintptr(incl_regmatch.startp[0])),
						FNAME_EXP | FNAME_INCL_S | FNAME_REL_S, 1, p_fname)
				} else {
					new_fname = file_name_in_line(incl_regmatch.endp[0], 0,
						FNAME_EXP | FNAME_INCL_S | FNAME_REL_S, 1, p_fname, nil)
				}
				already_searched := false
				if new_fname != nil {
					i := C.int(0)
					for ;; i += 1 {
						if i == depth + 1 {
							i = old_files
						}
						if i == max_path_depth {
							break
						}
						if path_full_compare_r(transmute(cstring)(new_fname), transmute(cstring)(files[i].name), true, true) & kEqualFiles_S != 0 {
							if type_ != CHECK_PATH_S && action == ACTION_SHOW_ALL_S && files[i].matched {
								msg_putchar('\n')
								if !got_int {
									msg_home_replace_r(new_fname)
									msg_puts_s(cstring(" (includes previously listed match)"))
									prev_fname = nil
								}
							}
							xfree(new_fname)
							new_fname = nil
							already_searched = true
							break
						}
					}
				}

				if type_ == CHECK_PATH_S && (action == ACTION_SHOW_ALL_S || (new_fname == nil && !already_searched)) {
					if did_show {
						msg_putchar('\n')
					} else {
						gotocmdline_r(true)
						msg_puts_title_s(cstring("--- Included files "))
						if action != ACTION_SHOW_ALL_S {
							msg_puts_title_s(cstring("not found "))
						}
						msg_puts_title_s(cstring("in path ---\n"))
					}
					did_show = true
					for depth_displayed < depth && !got_int {
						depth_displayed += 1
						for i := C.int(0); i < depth_displayed; i += 1 {
							msg_puts_s(cstring("  "))
						}
						msg_home_replace_r(files[depth_displayed].name)
						msg_puts_s(cstring(" -->\n"))
					}
					if !got_int {
						for i := C.int(0); i <= depth_displayed; i += 1 {
							msg_puts_s(cstring("  "))
						}
						if new_fname != nil {
							_ = msg_outtrans_s(transmute(cstring)(new_fname), HLF_D_S, false)
						} else {
							qp: ^u8 = nil
							qi := C.int(0)
							if strstr_c(transmute(cstring)(inc_opt), cstring("\\zs")) != nil {
								qp = incl_regmatch.startp[0]
								qi = C.int(uintptr(incl_regmatch.endp[0]) - uintptr(incl_regmatch.startp[0]))
							} else {
								qp = incl_regmatch.endp[0]
								for b_at(qp, 0) != 0 && !vim_isfilec_2(C.int(b_at(qp, 0))) {
									qp = (^u8)(uintptr(qp) + 1)
								}
								for vim_isfilec_2(C.int(b_at(qp, qi))) {
									qi += 1
								}
							}
							if qi == 0 {
								qp = incl_regmatch.endp[0]
								qi = C.int(libc.strlen(transmute(cstring)(qp)))
							} else if uintptr(qp) > uintptr(line) {
								if b_at(qp, -1) == '"' || b_at(qp, -1) == '<' {
									qp = (^u8)(uintptr(qp) - 1)
									qi += 1
								}
								if b_at(qp, qi) == '"' || b_at(qp, qi) == '>' {
									qi += 1
								}
							}
							save_char := b_at(qp, qi)
							b_set(qp, qi, 0)
							_ = msg_outtrans_s(transmute(cstring)(qp), HLF_D_S, false)
							b_set(qp, qi, save_char)
						}

						if new_fname == nil && action == ACTION_SHOW_ALL_S {
							if already_searched {
								msg_puts_s(cstring("  (Already listed)"))
							} else {
								msg_puts_s(cstring("  NOT FOUND"))
							}
						}
					}
				}

				if new_fname != nil {
					// Push the new file onto the file stack
					if depth + 1 == old_files {
						bigger = ([^]SearchedFile)(xmalloc(size_of(SearchedFile) * C.size_t(max_path_depth) * 2))
						for i := C.int(0); i <= depth; i += 1 {
							bigger[i] = files[i]
						}
						for i := depth + 1; i < old_files + max_path_depth; i += 1 {
							bigger[i].fp = nil
							bigger[i].name = nil
							bigger[i].lnum = 0
							bigger[i].matched = false
						}
						for i := old_files; i < max_path_depth; i += 1 {
							bigger[i + max_path_depth] = files[i]
						}
						old_files += max_path_depth
						max_path_depth *= 2
						xfree(files_arr)
						files_arr = ([^]SearchedFile)(bigger)
						files = bigger
					}
					if os_fopen(transmute(cstring)(new_fname), cstring("r")) == nil {
						xfree(new_fname)
						new_fname = nil
					} else {
						files[depth + 1].fp = os_fopen(transmute(cstring)(new_fname), cstring("r"))
						depth += 1
						if depth == old_files {
							xfree(files[old_files].name)
							old_files += 1
						}
						files[depth].name = new_fname
						curr_fname = new_fname
						files[depth].lnum = 0
						files[depth].matched = false
						if action == ACTION_EXPAND_S && !shortmess_s(SHM_COMPLETIONSCAN) && !silent {
							msg_hist_off = 1
							libc.snprintf(&IObuff[0], IOSIZE_S, "Scanning included file: %s", transmute(cstring)(new_fname))
							msg_trunc_r(&IObuff[0], true, HLF_R_S)
							msg_hist_off = 0
						} else if p_verbose >= 5 {
							verbose_enter_r()
							vmsg_buf(cstring("Searching included file %s"), new_fname)
							verbose_leave_r()
						}
					}
				}
			} else {
				p = line
				for true { // search_line: emulation (backward goto target)
					define_matched = false
					if def_regmatch.regprog != nil && vim_regexec_r(&def_regmatch, line, 0) != 0 {
						p = def_regmatch.endp[0]
						for b_at(p, 0) != 0 && !vim_iswordc_r(C.int(b_at(p, 0))) {
							p = (^u8)(uintptr(p) + 1)
						}
						define_matched = true
					}

					if def_regmatch.regprog == nil || define_matched {
						matched = false
						if define_matched || compl_status_sol() {
							startp = transmute(^u8)(skipwhite(transmute(cstring)(p)))
							matched = (p_ic != 0 ?
								mb_strnicmp_r(transmute(cstring)(startp), transmute(cstring)(ptr), len) :
								C.int(libc.strncmp(transmute(cstring)(startp), transmute(cstring)(ptr), len))) == 0
							if matched && define_matched && whole && vim_iswordc_r(C.int(b_at(startp, C.int(len)))) {
								matched = false
							}
						} else if regmatch.regprog != nil &&
						vim_regexec_r(&regmatch, line, C.int(uintptr(p) - uintptr(line))) != 0 {
							matched = true
							startp = regmatch.startp[0]
							if skip_comments_in {
								if (b_at(line, 0) != '#' ||
								libc.strncmp(skipwhite(transmute(cstring)(^u8)(uintptr(line)+1)), "define", 6) != 0) &&
								get_leader_len(line, nil, false, true) != 0 {
									matched = false
								}

								sp := line
								if matched || (b_at(sp, 0) == '/' && b_at(sp, 1) == '*') || b_at(sp, 0) == '*' {
									for b_at(sp, 0) != 0 && uintptr(sp) < uintptr(startp) {
										if matched && b_at(sp, 0) == '/' &&
										(b_at(sp, 1) == '*' || b_at(sp, 1) == '/') {
											matched = false
											if b_at(sp, 1) == '/' {
												break
											}
											sp = (^u8)(uintptr(sp) + 1)
										} else if !matched && b_at(sp, 0) == '*' && b_at(sp, 1) == '/' {
											matched = true
											sp = (^u8)(uintptr(sp) + 1)
										}
										sp = (^u8)(uintptr(sp) + 1)
									}
								}
							}
						}
					}

					if !matched {
						break // leave search_line loop → continue outer
					}

					if action == ACTION_EXPAND_S {
						cont_s_ipos := false
						if depth == -1 && lnum == win_cursor_r(curwin)^.lnum {
							outer_break = true
							break
						}
						found = true
						aux := startp
						p = startp
						exm: { // exit_matched goto emulation
							if compl_status_adding() && libc.strlen(transmute(cstring)(p)) >= C.size_t(ins_compl_len_r()) {
								p = (^u8)(uintptr(p) + uintptr(ins_compl_len_r()))
								if vim_iswordp_r(p) {
									break exm // goto exit_matched
								}
								p = find_word_start(p)
							}
							p = find_word_end(p)
							i := C.int(uintptr(p) - uintptr(aux))

							if compl_status_adding() && i == ins_compl_len_r() {
								// IObuff > compl_length, so the strncpy works
								libc.memcpy(&IObuff[0], aux, C.size_t(i))

								// Get the next line.
								if depth < 0 {
									if lnum >= end_lnum {
										break exm // goto exit_matched
									}
									lnum += 1
									line = get_line_and_copy(lnum, file_line)
								} else if vim_fgets(file_line, LSIZE_C, files[depth].fp) != 0 {
									break exm // goto exit_matched
								}

								already = transmute(^u8)(skipwhite(transmute(cstring)(file_line)))
								aux = already
								p = find_word_start(already)
								p = find_word_end(p)
								if uintptr(p) > uintptr(aux) {
									if b_at(aux, 0) != ')' && b_at(&IObuff[0], i - 1) != '\t' {
										if b_at(&IObuff[0], i-1) != ' ' {
											b_set(&IObuff[0], i, ' ')
											i += 1
										}
										// IObuff =~ "\(\k\|\i\).* ", thus i >= 2
										if p_js != 0 &&
										(b_at(&IObuff[0], i-2) == '.' ||
										b_at(&IObuff[0], i-2) == '?' ||
										b_at(&IObuff[0], i-2) == '!') {
											b_set(&IObuff[0], i, ' ')
											i += 1
										}
									}
									// copy as much as possible of the new word
									if C.int(uintptr(p)-uintptr(aux)) >= IOSIZE_S - i {
										p = (^u8)(uintptr(aux) + uintptr(IOSIZE_S - i - 1))
									}
									libc.memcpy((^u8)(uintptr(&IObuff[0]) + uintptr(i)), aux, C.size_t(uintptr(p) - uintptr(aux)))
									i += C.int(uintptr(p) - uintptr(aux))
									cont_s_ipos = true
								}
								b_set(&IObuff[0], i, 0)
								aux = &IObuff[0]

								if i == ins_compl_len_r() {
									break exm // goto exit_matched
								}
							}

							add_r := ins_compl_add_infercase(aux, i, p_ic != 0,
								curr_fname == buf_fname_r(curbuf) ? nil : curr_fname,
								C.int(dir_cur), cont_s_ipos, 0)
							if add_r == 1 { // OK: dir was BACKWARD, honor it just once
								dir_cur = .FORWARD
							} else if add_r == 0 { // FAIL
								outer_break = true
								break exm
							}
						}
					} else if action == ACTION_SHOW_ALL_S {
						found = true
						if !did_show {
							gotocmdline_r(true)
						}
						if curr_fname != prev_fname {
							if did_show {
								msg_putchar('\n')
							}
							if !got_int {
								msg_home_replace_r(curr_fname)
							}
							prev_fname = curr_fname
						}
						did_show = true
						if !got_int {
							show_pat_in_path(line, type_, true, action,
								depth == -1 ? nil : files[depth].fp,
								depth == -1 ? &lnum : &files[depth].lnum,
								match_count)
							match_count += 1
						}

						for i := C.int(0); i <= depth; i += 1 {
							files[i].matched = true
						}
					} else {
						count_left -= 1
						if count_left > 0 {
							break // leave search_line loop; not the target match yet
						}
						found = true
						if depth == -1 && lnum == win_cursor_r(curwin)^.lnum && l_g_do_tagpreview == 0 {
							emsg(cstring("E387: Match is on current line"))
						} else if action == ACTION_SHOW_S {
							show_pat_in_path(line, type_, did_show, action,
								depth == -1 ? nil : files[depth].fp,
								depth == -1 ? &lnum : &files[depth].lnum, 1)
							did_show = true
						} else {
							if l_g_do_tagpreview != 0 {
								curwin_save = curwin
								prepare_tagpreview(true)
							}
							if action == ACTION_SPLIT_S {
								if win_split_r(0, 0) == 0 {
									outer_break = true
									break
								}
								reset_binding_w(curwin)
							}
							if depth == -1 {
								if l_g_do_tagpreview != 0 {
									if !win_valid_r(curwin_save) {
										outer_break = true
										break
									}
									if getfile_r(buf_fnum_of(buf_of_curwin()), nil, nil, true, lnum, forceit) > 0 {
										outer_break = true
										break
									}
								} else {
									setpcmark()
								}
								win_cursor_r(curwin)^.lnum = lnum
								check_cursor_r(curwin)
							} else {
								if getfile_r(0, files[depth].name, nil, true, files[depth].lnum, forceit) > 0 {
									outer_break = true
									break
								}
								win_cursor_r(curwin)^.lnum = files[depth].lnum
							}
						}
						if action != ACTION_SHOW_S {
							win_cursor_r(curwin)^.col = C.int(uintptr(startp) - uintptr(line))
							w_set_curswant_true(curwin)
						}

						if l_g_do_tagpreview != 0 &&
						curwin != curwin_save && win_valid_r(curwin_save) {
							validate_cursor_r()
							redraw_later_r(curwin, UPD_VALID_S)
							win_enter_r(curwin_save, true)
						}
						outer_break = true
					}

					// exit_matched:
					matched = false
					if def_regmatch.regprog == nil &&
					action == ACTION_EXPAND_S &&
					!compl_status_sol() &&
					b_at(startp, 0) != 0 &&
					b_at(startp, utfc_ptr2len(transmute(cstring)(startp))) != 0 {
						continue // goto search_line
					}
				} // search_line loop
			}
			if outer_break {
				break
			}

			line_breakcheck()
			if action == ACTION_EXPAND_S {
				ins_compl_check_keys(30, false)
			}
			if got_int || ins_compl_interrupted() {
				break
			}

			// Read the next line. When reading an included file and hitting
			// EOF, close the file and continue in the including file.
			for depth >= 0 && already == nil &&
			vim_fgets(file_line, LSIZE_C, files[depth].fp) != 0 {
				libc.fclose(transmute(^libc.FILE)(files[depth].fp))
				old_files -= 1
				files[old_files].name = files[depth].name
				files[old_files].matched = files[depth].matched
				depth -= 1
				curr_fname = depth == -1 ? buf_fname_r(curbuf) : files[depth].name
				if depth_displayed > depth {
					depth_displayed = depth
				}
			}
			if depth >= 0 {
				files[depth].lnum += 1
				line = file_line
				// Remove any CR and LF from the line.
				ii := libc.strlen(transmute(cstring)(line))
				if ii > 0 && b_at(line, C.int(ii)-1) == '\n' {
					ii -= 1
					b_set(line, C.int(ii), 0)
				}
				if ii > 0 && b_at(line, C.int(ii)-1) == '\r' {
					ii -= 1
					b_set(line, C.int(ii), 0)
				}
			} else if already == nil {
				lnum += 1
				if lnum > end_lnum {
					break
				}
				line = get_line_and_copy(lnum, file_line)
			}
			already = nil
		}

		// Close any files that are still open.
		for i := C.int(0); i <= depth; i += 1 {
			libc.fclose(transmute(^libc.FILE)(files[i].fp))
			xfree(files[i].name)
		}
		for i := old_files; i < max_path_depth; i += 1 {
			xfree(files[i].name)
		}
		xfree(files_arr)

		if type_ == CHECK_PATH_S {
			if !did_show {
				if action != ACTION_SHOW_ALL_S {
					msg_msg(cstring("All included files were found"), 0)
				} else {
					msg_msg(cstring("No included files"), 0)
				}
			}
		} else if !found && action != ACTION_EXPAND_S && !silent {
			if got_int || ins_compl_interrupted() {
				emsg(cstring("Interrupted"))
			} else if type_ == FIND_DEFINE_S {
				emsg(cstring("E388: Couldn't find definition"))
			} else {
				emsg(cstring("E389: Couldn't find pattern"))
			}
		}
		if action == ACTION_SHOW_S || action == ACTION_SHOW_ALL_S {
			msg_end_r()
		}
	}

	vim_regfree(regmatch.regprog)
	vim_regfree(incl_regmatch.regprog)
	vim_regfree(def_regmatch.regprog)
}

foreign _ {
	@(link_name = "xcalloc")
	xcalloc_c :: proc "c" (n: C.size_t, sz: C.size_t) -> rawptr ---
	@(link_name = "strstr")
	strstr_c :: proc "c" (haystack: cstring, needle: cstring) -> cstring ---
	@(link_name = "p_js")
	p_js: C.longlong
}

IOSIZE_S :: 1025 // globals.h IOSIZE

vmsg_buf :: proc "c"(fmt: cstring, s: ^u8) {
	tmp: [1025]u8
	libc.snprintf(&tmp[0], 1025, transmute(cstring)(fmt), transmute(cstring)(s))
	msg_trunc_r(&tmp[0], true, HLF_R_S)
}

// RESET_BINDING(wp): w_p_scb@1112 and w_p_crb@1152 = false
reset_binding_w :: proc "c"(wp: rawptr) {
	(^bool)(uintptr(wp) + 1112)^ = false
	(^bool)(uintptr(wp) + 1152)^ = false
}

buf_fnum_of :: proc "c"(buf: rawptr) -> C.int {
	return (^C.int)(buf)^ // buf_T.handle is at offset 0
}

foreign _ {
	@(link_name = "check_cursor")
	check_cursor_r :: proc "c" (wp: rawptr) ---
}

UPD_VALID_S :: 10 // drawscreen.h

// Show pattern in path (used by [i, [d, :isearch, :ilist, :psearch).
show_pat_in_path :: proc "c"(
	line_in: ^u8,
	type_: C.int,
	did_show: bool,
	action: C.int,
	fp: rawptr,
	lnum: ^C.int,
	count: C.int,
) {
	if did_show {
		msg_putchar('\n')
	} else if msg_silent == 0 {
		gotocmdline_r(true)
	}
	if got_int {
		return
	}
	line := line_in
	linelen := libc.strlen(transmute(cstring)(line))
	for true {
		p := (^u8)(uintptr(line) + uintptr(linelen) - 1)
		if fp != nil {
			if uintptr(p) >= uintptr(line) && b_at(p, 0) == '\n' {
				p = (^u8)(uintptr(p) - 1)
			}
			if uintptr(p) >= uintptr(line) && b_at(p, 0) == '\r' {
				p = (^u8)(uintptr(p) - 1)
			}
			b_set(p, 1, 0)
		}
		if action == ACTION_SHOW_ALL_S {
			tmpn: [32]u8
			libc.snprintf(&tmpn[0], 32, "%3d: ", count)
			msg_puts_s(transmute(cstring)(&tmpn[0]))
			libc.snprintf(&tmpn[0], 32, "%4d", lnum^)
			msg_puts_hl_s(transmute(cstring)(&tmpn[0]), HLF_N_S, false)
			msg_puts_s(cstring(" "))
		}
		msg_prt_line_r(line, false)

		if got_int || type_ != FIND_DEFINE_S || uintptr(p) < uintptr(line) || b_at(p, 0) != '\\' {
			break
		}

		if fp != nil {
			if vim_fgets(line, LSIZE_C, fp) != 0 {
				break
			}
			linelen = libc.strlen(transmute(cstring)(line))
			lnum^ += 1
		} else {
			lnum^ += 1
			if lnum^ > buf_ml_line_count_r(curbuf) {
				break
			}
			line = ml_get(lnum^)
			linelen = C.size_t(ml_get_len_r2(lnum^))
		}
		msg_putchar('\n')
	}
}
