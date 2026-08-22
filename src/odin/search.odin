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
	@(link_name = "buf_get_changedtick")
	buf_get_changedtick_r :: proc "c" (buf: rawptr) -> C.longlong ---

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
	@(link_name = "line_breakcheck_s")
	line_breakcheck_s :: proc "c" () ---
	@(link_name = "fast_breakcheck_s")
	fast_breakcheck_s :: proc "c" () ---

	@(link_name = "inc")
	incl_pos :: proc "c" (lp: ^Pos_T) -> C.int ---
	@(link_name = "inc_cursor")
	inc_cursor_r :: proc "c" () -> C.int ---
	@(link_name = "dec_cursor")
	dec_cursor_r :: proc "c" () -> C.int ---

	@(link_name = "give_warning2")
	give_warning_s :: proc "c" (message: cstring, hl: bool, hist: bool) ---
	@(link_name = "shortmess2")
	shortmess_s :: proc "c" (x: C.int) -> bool ---
	@(link_name = "messaging2")
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
	@(link_name = "msg_puts_title2")
	msg_puts_title_s :: proc "c" (s: cstring) ---
	@(link_name = "msg_puts_hl")
	msg_puts_hl_s :: proc "c" (s: cstring, hl: C.int, hist: bool) ---
	@(link_name = "msg_prt_line")
	msg_prt_line_r :: proc "c" (s: ^u8, list: bool) ---
	@(link_name = "msg_trunc_attr")
	msg_trunc_s :: proc "c" (s: cstring, check: bool, hl_id: C.int) ---
	@(link_name = "msg_home_replace")
	msg_home_replace_r :: proc "c" (fname: ^u8) ---
	@(link_name = "msg_outtrans2")
	msg_outtrans_s :: proc "c" (str: cstring, hl_id: C.int, hist: bool) -> C.int ---
	@(link_name = "ui_flush_s")
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

	@(link_name = "xstrnsave_c")
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

kOptBoFlagShowmatch :: 0x200 // best-effort bit; beep is cosmetic

SHM_SEARCH :: 0x100 // best-effort bits for shortmess()
SHM_SEARCHCOUNT :: 0x200
SHM_COMPLETIONSCAN :: 0x400

MODE_SHOWMATCH_S :: 64 // MODE_SHOWMATCH (State); cosmetic only

UPD_SOME_VALID_S :: 2
HLF_D_S :: 34 // HLF_D count; cosmetic
HLF_N_S :: 17
HLF_R_S :: 20

EVENT_SEARCHWRAPPED_S :: 0 // patched below if needed

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

save_incsearch_state :: proc() {
	saved_search_match_endcol = search_match_endcol_g
	saved_search_match_lines = search_match_lines_g
}

restore_incsearch_state :: proc() {
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
				line_breakcheck_s()
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
