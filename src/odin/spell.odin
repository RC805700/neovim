// spell.odin — port of src/nvim/spell.c (spell checking)
package main

import C "core:c"
import "core:c/libc"
import "core:sys/linux"

foreign _ {
	// ── options/globals ──
	// p_enc already declared in digraph.odin — reuse directly.

	// ── hashtab.c ──
	@(link_name = "hash_init")
	hash_init_r :: proc "c" (ht: rawptr) ---
	@(link_name = "hash_lookup")
	hash_lookup_r :: proc "c" (ht: rawptr, key: cstring, len: C.size_t, hash: C.size_t) -> rawptr ---
	@(link_name = "hash_add_item")
	hash_add_item_r :: proc "c" (ht: rawptr, hi: rawptr, key: ^u8, hash: C.size_t) ---
	@(link_name = "hash_clear_all")
	hash_clear_all_r :: proc "c" (ht: rawptr, off: C.size_t) ---
	@(link_name = "hash_hash")
	hash_hash_r :: proc "c" (key: cstring) -> C.size_t ---

	// ga_init_r/ga_clear_r already declared in register.odin — reuse directly.
	@(link_name = "ga_clear_strings")
	ga_clear_strings_r :: proc "c" (gap: rawptr) ---

	// ── spellfile.c (still C) ──
	@(link_name = "spell_load_file")
	spell_load_file_r :: proc "c" (fname: ^u8, lang: ^u8, slang: rawptr, silent: bool) -> rawptr ---
	@(link_name = "do_in_runtimepath")
	do_in_runtimepath_r :: proc "c" (name: cstring, flags: C.int, callback: rawptr, cookie: rawptr) -> C.int ---
	@(link_name = "open_spellbuf2")
	open_spellbuf_r :: proc "c" () -> rawptr ---

	// ── charset/mbyte ──
	@(link_name = "skipdigits")
	skipdigits_r :: proc "c" (p: cstring) -> cstring ---
	@(link_name = "skiphex")
	skiphex_r :: proc "c" (p: cstring) -> cstring ---
	@(link_name = "skipbin")
	skipbin_r :: proc "c" (p: cstring) -> cstring ---
	@(link_name = "getwhitecols")
	getwhitecols_r :: proc "c" (p: cstring) -> C.int ---
	@(link_name = "mb_charlen_len")
	mb_charlen_len_r :: proc "c" (s: cstring, len: C.size_t) -> C.int ---
	@(link_name = "utf_class")
	utf_class_r :: proc "c" (c: C.int) -> C.int ---
	@(link_name = "utf_fold")
	utf_fold_r :: proc "c" (a: C.int) -> C.int ---
	@(link_name = "mb_get_class")
	mb_get_class_r :: proc "c" (p: cstring) -> C.int ---

	// ── regexp ──
	@(link_name = "vim_regexec_prog")
	vim_regexec_prog_r :: proc "c" (prog: ^rawptr, ignore_case: bool, line: cstring, col: C.int) -> C.int ---

	// ── option.c / eval ──

	// ── syntax/decor/ui (draw.c, decor.c, syntax.c) ──
	@(link_name = "syn_get_id")
	syn_get_id_r :: proc "c" (wp: rawptr, lnum: C.int, col: C.int, trans: bool, can_spell: ^bool, change_state: bool) -> C.int ---
	@(link_name = "syntax_present")
	syntax_present_r :: proc "c" (wp: rawptr) -> bool ---
	// win_line: Odin export in drawline.odin (Batch 12e; was wrong 6-arg sig).
	@(link_name = "decor_redraw_reset")
	decor_redraw_reset_r :: proc "c" (wp: rawptr, ds: rawptr) ---
	@(link_name = "decor_redraw_line")
	decor_redraw_line_r :: proc "c" (wp: rawptr, lnum: C.int, ds: rawptr) ---
	@(link_name = "decor_redraw_col_impl")
	decor_redraw_col_impl_r :: proc "c" (wp: rawptr, col: C.int, win_col: C.int, hidden: bool, ds: rawptr, max_col: C.int) -> C.int ---
	@(link_name = "decor_providers_invoke_spell")
	decor_providers_invoke_spell_r :: proc "c" (wp: rawptr, start_row: C.int, start_col: C.int, end_row: C.int, end_col: C.int) ---
	@(link_name = "decor_state_free")
	decor_state_free_r :: proc "c" (ds: rawptr) ---

	// ── suggest.c (still C) ──
	@(link_name = "suggest_trie_walk")
	suggest_trie_walk_r :: proc "c" (su: rawptr, lp: rawptr, fword: ^u8, soundfold_ok: bool) -> bool ---
	@(link_name = "spell_suggest_list")
	spell_suggest_list_r :: proc "c" (gap: rawptr, word: cstring, maxcount: C.int, need_cap: bool, interactive: bool) ---

	// ── buffer/ex_cmds helpers ──
	@(link_name = "do_cmdline_cmd")
	do_cmdline_cmd_r :: proc "c" (cmd: cstring) -> C.int ---
}

// These are DEFINED here (C defined them in spell.c) — spellfile.c links to them.
@(export)
first_lang: rawptr = nil // slang_T* linked list head
@(export)
int_wordlist: ^u8 = nil // file for zG/zW
@(export)
spelltab: [1024]u8 // spelltab_T storage (C symbol: "spelltab")
@(export)
did_set_spelltab: bool = false
@(export)
repl_from: ^u8 = nil
@(export)
repl_to: ^u8 = nil

// ── Constants ────────────────────────────────────────────────────────────────

MAXWLEN :: 254
MAXREGIONS :: 8
REGION_ALL :: 0xff
SY_MAXLEN :: 30
SPL_FNAME_TMPL :: "%s.%s.spl"
SPL_FNAME_ADD :: ".add."
SPL_FNAME_ASCII :: ".ascii."

WF_REGION :: 0x01
WF_ONECAP :: 0x02
WF_ALLCAP :: 0x04
WF_RARE :: 0x08
WF_BANNED :: 0x10
WF_AFX :: 0x20
WF_FIXCAP :: 0x40
WF_KEEPCAP :: 0x80
WF_CAPMASK :: 0xC2

WF_HAS_AFF :: 0x0100
WF_NEEDCOMP :: 0x0200
WF_NOSUGGEST :: 0x0400
WF_COMPROOT :: 0x0800
WF_NOCOMPBEF :: 0x1000
WF_NOCOMPAFT :: 0x2000

WFP_RARE :: 0x01
WFP_NC :: 0x02
WFP_UP :: 0x04
WFP_COMPPERMIT :: 0x08
WFP_COMPFORBID :: 0x10

WF_RAREPFX :: WFP_RARE << 24
WF_PFX_NC :: WFP_NC << 24
WF_PFX_UP :: WFP_UP << 24
WF_PFX_COMPPERMIT :: WFP_COMPPERMIT << 24
WF_PFX_COMPFORBID :: WFP_COMPFORBID << 24

COMP_CHECKDUP :: 1
COMP_CHECKREP :: 2
COMP_CHECKCASE :: 4
COMP_CHECKTRIPLE :: 8

SP_TRUNCERROR :: -1
SP_FORMERROR :: -2
SP_OTHERERROR :: -3

SP_BANNED :: -1
SP_RARE :: 0
SP_OK :: 1
SP_LOCAL :: 2
SP_BAD :: 3

FIND_FOLDWORD :: 0
FIND_KEEPWORD :: 1
FIND_PREFIX :: 2
FIND_COMPOUND :: 3
FIND_KEEPCOMPOUND :: 4

CHAR_OTHER :: 0
CHAR_UPPER :: 1
CHAR_DIGIT :: 2

SPELL_ADD_GOOD :: 0
SPELL_ADD_BAD :: 1
SPELL_ADD_RARE :: 2

MAXWORDCOUNT :: 0xffff
WC_KEY_OFF :: 2 // offsetof(wordcount_T, wc_word): u16 count, NO padding (probe-verified)
MAXPATHL_S :: 4096

HLF_SPB :: 37 // hlf_T enum order (0-based, highlight_defs.h)
HLF_SPR :: 39
HLF_SPL :: 40
HLF_SPC :: 38
HLF_COUNT :: 41

// hlf_T enum order (highlight_defs.h): NONE=0..SPB=37,SPC=38,SPR=39,SPL=40,COUNT=41

// hlf_T enum order (highlight_defs.h): NONE=0,8C=1,EOB=2,TERM=3,AT=4,D=5,E=6,I=7,
// L=8,LC=9,M=10,CM=11,N=12,LNA=13,LNB=14,CLN=15,CLS=16,CLF=17,R=18,S=19,SBR=20,
// SPB=21,SPR=22,SPL=23,SPC=24,T=25,TB=26,TODO=27,USER=28,W=29,WR=30,COUNT=31

// SMT_ values for spell_move_to behaviour
SMT_ALL :: 0
SMT_BAD :: 1
SMT_RARE :: 2

kOptSpoFlagCamel :: 0x01 // best-effort 'spelloptions' bits
kOptSpoFlagNoplainbuffer :: 0x02

EVENT_SPELLFILEMISSING :: 107
DIP_ALL :: 0x02

e_no_spell_txt :: "E756: Spell checking is not enabled"

// ── Struct mirrors (offset-verified vs C via probes) ─────────────────────────

Fromto_T :: struct { // 16
	ft_from: ^u8,
	ft_to:   ^u8,
}

Salitem_T :: struct #align(8) { // 64
	sm_lead:    ^u8,
	sm_leadlen: C.int,
	sm_oneof:   ^u8,
	sm_rules:   ^u8,
	sm_to:      ^u8,
	sm_lead_w:  ^C.int,
	sm_oneof_w: ^C.int,
	sm_to_w:    ^C.int,
}

idx_T :: C.int
salfirst_T :: C.int

Syl_Item_T :: struct { // SY_MAXLEN+4 → 36, aligned 4
	sy_chars: [SY_MAXLEN]u8,
	sy_len:   C.int,
}

Spelload_T :: struct {
	sl_lang_buf: [MAXWLEN + 1]u8,
	sl_slang:    rawptr,
	sl_nobreak:  C.int,
}

// slang_T mirror — 4352 bytes. hashtab_T (296B) and garray_T (24B) kept as raw
// byte arrays where only C code manipulates them; garrays we touch get the
// package Garray mirror.
Slang_T :: struct #align(8) {
	sl_next:          rawptr, // ^Slang_T
	sl_name:          ^u8,
	sl_fname:         ^u8,
	sl_add:           bool,
	_pad25:           [7]u8,
	sl_fbyts:         ^u8,
	sl_fbyts_len:     C.int,
	_pad44:           [4]u8,
	sl_fidxs:         ^idx_T,
	sl_kbyts:         ^u8,
	_pad64x:          [0]u8,
	sl_kidxs:         ^idx_T,
	sl_pbyts:         ^u8,
	sl_pidxs:         ^idx_T,
	sl_info:          ^u8,
	sl_regions:       [MAXREGIONS * 2 + 1]u8, // @96, ends 113
	_midword_pad:     [7]u8,
	sl_midword:       ^u8, // @120
	sl_wordcount_buf: [296]u8, // hashtab_T @128
	sl_compmax:       C.int,
	sl_compminlen:    C.int,
	sl_compsylmax:    C.int,
	sl_compoptions:   C.int,
	sl_comppat:       Garray, // @440
	_compprog_pad:    [0]u8,
	sl_compprog:      rawptr, // regprog_T*
	sl_comprules:     ^u8,
	sl_compstartflags: ^u8,
	sl_compallflags:  ^u8,
	sl_nobreak:       bool,
	_syllable_pad:    [7]u8,
	sl_syllable:      ^u8,
	sl_syl_items:     Garray, // @512
	sl_prefixcnt:     C.int,
	_prefprog_pad:    [4]u8,
	sl_prefprog:      ^^rawptr, // regprog_T**
	sl_rep:           Garray, // @552
	sl_rep_first:     [256]C.short,
	sl_sal:           Garray, // @1088
	sl_sal_first:     [256]salfirst_T,
	sl_followup:      bool,
	sl_collapse:      bool,
	sl_rem_accents:   bool,
	sl_sofo:          bool,
	sl_repsal:        Garray, // @2144
	sl_repsal_first:  [256]C.short,
	sl_nosplitsugs:   bool,
	sl_nocompoundsugs: bool,
	_sugtime_pad:     [6]u8,
	sl_sugtime:       C.longlong, // time_t
	sl_sbyts:         ^u8,
	sl_sbyts_len:     C.int,
	_sidxs_pad:       [4]u8,
	sl_sidxs:         ^idx_T,
	sl_sugbuf:        rawptr, // buf_T*
	sl_sugloaded:     bool,
	sl_has_map:       bool,
	_maphash_pad:     [6]u8,
	sl_map_hash_buf:  [296]u8, // hashtab_T @2736
	sl_map_array:     [256]C.int, // @3032
	_maparr_pad:      [0]u8,
	sl_sounddone_buf: [296]u8, // hashtab_T @4056
}

Langp_T :: struct { // 32
	lp_slang:   rawptr, // ^Slang_T
	lp_sallang: rawptr,
	lp_replang: rawptr,
	lp_region:  C.int,
}

Spelltab_T :: struct { // 1024
	st_isw:  [256]bool,
	st_isu:  [256]bool,
	st_fold: [256]u8,
	st_upper: [256]u8,
}

Matchinf_T :: struct #align(8) { // 616
	mi_lp:          ^Langp_T,
	mi_word:        ^u8,
	mi_end:         ^u8,
	mi_fend:        ^u8,
	mi_cend:        ^u8,
	mi_fword:       [MAXWLEN + 1]u8,
	mi_fwordlen:    C.int,
	mi_prefarridx:  C.int,
	mi_prefcnt:     C.int,
	mi_prefixlen:   C.int,
	mi_cprefixlen:  C.int,
	mi_compoff:     C.int,
	mi_compflags:   [MAXWLEN]u8,
	mi_complen:     C.int,
	mi_compextra:   C.int,
	mi_result:      C.int,
	mi_capflags:    C.int,
	mi_win:         rawptr,
	mi_result2:     C.int,
	_end2_pad:      [4]u8,
	mi_end2:        ^u8,
}

Wordcount_T_prefix :: struct {
	wc_count: C.ushort,
	_pad2:    [6]u8,
}

#assert(size_of(Fromto_T) == 16)
#assert(size_of(Salitem_T) == 64)
#assert(size_of(Langp_T) == 32)
#assert(size_of(Spelltab_T) == 1024)
#assert(size_of(Matchinf_T) == 616)
#assert(offset_of(Matchinf_T, mi_fwordlen) == 296)
#assert(offset_of(Matchinf_T, mi_compflags) == 320)
#assert(offset_of(Matchinf_T, mi_win) == 592)

// ── inline helpers (C macros) ────────────────────────────────────────────────

// MB_PTR_ADV: advance one character.
mb_ptr_adv :: proc "c" (p: ^u8) -> ^u8 {
	return (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
}

// MB_PTR_BACK(s, p): back up one character.
mb_ptr_back :: proc "c" (s: ^u8, p: ^u8) -> ^u8 {
	return (^u8)(uintptr(p) - uintptr(utf_head_off(transmute(cstring)(s), transmute(cstring)((^u8)(uintptr(p) - 1))) + 1))
}

// SPELL_ISUPPER(c): spelltab-aware upper check.
spell_isupper :: proc "c"(c: C.int) -> bool {
	if c >= 128 {
		return mb_isupper_r(c)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return st.st_isu[c]
}

// SPELL_TOFOLD(c)
spell_tofold :: proc "c"(c: C.int) -> C.int {
	if c >= 128 {
		return utf_fold_r(c)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return C.int(st.st_fold[c])
}

// SPELL_TOUPPER(c)
spell_toupper :: proc "c"(c: C.int) -> C.int {
	if c >= 128 {
		return mb_toupper_r(c)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return C.int(st.st_upper[c])
}

foreign _ {
	@(link_name = "mb_toupper")
	mb_toupper_r :: proc "c" (a: C.int) -> C.int ---
}

// ── win_T/synblock_T/buf_T field readers (offset-verified) ──────────────────

W_S_OFF :: 16 // win_T.w_s → synblock_T*
W_P_SPELL_OFF :: 1052
SB_LANGP_OFF :: 800 // synblock_T.b_langp (Garray)
SB_P_SPL_OFF :: 1112 // ^u8 'spelllang'
SB_CAP_PROG_OFF :: 1096 // regprog_T* b_cap_prog
SB_P_SPO_FLAGS_OFF :: 1128 // unsigned b_p_spo_flags

win_s_r :: proc "c"(wp: rawptr) -> rawptr {
	return (^rawptr)(uintptr(wp) + W_S_OFF)^
}
w_p_spell_r :: proc "c"(wp: rawptr) -> C.int {
	return (^C.int)(uintptr(wp) + W_P_SPELL_OFF)^
}
sb_langp_r :: proc "c"(sb: rawptr) -> ^Garray {
	return (^Garray)(uintptr(sb) + SB_LANGP_OFF)
}
sb_p_spl_r :: proc "c"(sb: rawptr) -> ^u8 {
	return (^^u8)(uintptr(sb) + SB_P_SPL_OFF)^
}
sb_cap_prog_r :: proc "c"(sb: rawptr) -> rawptr {
	return (^rawptr)(uintptr(sb) + SB_CAP_PROG_OFF)^
}
sb_cap_prog_set :: proc "c"(sb: rawptr, v: rawptr) {
	(^rawptr)(uintptr(sb) + SB_CAP_PROG_OFF)^ = v
}
sb_p_spo_flags_r :: proc "c"(sb: rawptr) -> C.uint {
	return (^C.uint)(uintptr(sb) + SB_P_SPO_FLAGS_OFF)^
}

// ── spell_check ──────────────────────────────────────────────────────────────

@(export)
spell_check :: proc "c"(wp: rawptr, ptr: ^u8, attrp: ^C.int, capcol: ^C.int, docount: bool) -> C.size_t {
	// A word never starts at a space or a control character.
	if C.int(b_at(ptr, 0)) <= ' ' {
		return 1
	}

	ws := win_s_r(wp)
	if ga_empty_sp(sb_langp_r(ws)) {
		return 1
	}

	nrlen: C.size_t = 0
	wrongcaplen: C.size_t = 0
	count_word := docount
	use_camel_case := (sb_p_spo_flags_r(ws) & kOptSpoFlagCamel) != 0
	is_camel_case := false

	mi: Matchinf_T
	mi = Matchinf_T{}

	// A number is always OK. Also skip hex/binary; still check "3GPP".
	if b_at(ptr, 0) >= '0' && b_at(ptr, 0) <= '9' {
		if b_at(ptr, 0) == '0' && (b_at(ptr, 1) == 'b' || b_at(ptr, 1) == 'B') {
			mi.mi_end = transmute(^u8)(skipbin_r(transmute(cstring)(^u8)(uintptr(ptr) + 2)))
		} else if b_at(ptr, 0) == '0' && (b_at(ptr, 1) == 'x' || b_at(ptr, 1) == 'X') {
			mi.mi_end = transmute(^u8)(skiphex_r(transmute(cstring)(^u8)(uintptr(ptr) + 2)))
		} else {
			mi.mi_end = transmute(^u8)(skipdigits_r(transmute(cstring)(ptr)))
		}
		nrlen = C.size_t(uintptr(mi.mi_end) - uintptr(ptr))
	}

	mi.mi_word = ptr
	mi.mi_fend = ptr
	if spell_iswordp(mi.mi_fend, wp) {
		if use_camel_case {
			mi.mi_fend = advance_camelcase_word(ptr, wp, &is_camel_case)
		} else {
			for {
				mi.mi_fend = mb_ptr_adv(mi.mi_fend)
				if !(b_at(mi.mi_fend, 0) != 0 && spell_iswordp(mi.mi_fend, wp)) {
					break
				}
			}
		}
		if capcol != nil && capcol^ == 0 && sb_cap_prog_r(ws) != nil {
			c := utf_ptr2char(transmute(cstring)(ptr))
			if !spell_isupper(c) {
				wrongcaplen = C.size_t(uintptr(mi.mi_fend) - uintptr(ptr))
			}
		}
	}
	if capcol != nil {
		capcol^ = -1
	}

	mi.mi_end = mi.mi_fend
	mi.mi_capflags = 0
	mi.mi_cend = nil
	mi.mi_win = wp

	if b_at(mi.mi_fend, 0) != 0 {
		mi.mi_fend = mb_ptr_adv(mi.mi_fend)
	}

	spell_casefold(wp, ptr, C.int(uintptr(mi.mi_fend) - uintptr(ptr)), &mi.mi_fword[0], MAXWLEN + 1)
	mi.mi_fwordlen = C.int(libc.strlen(transmute(cstring)(&mi.mi_fword[0])))

	if is_camel_case && mi.mi_fwordlen > 0 {
		// introduce a fake word end space into the folded word.
		b_set(&mi.mi_fword[0], mi.mi_fwordlen - 1, ' ')
	}

	mi.mi_result = SP_BAD
	mi.mi_result2 = SP_BAD

	langp := sb_langp_r(ws)
	for lpi := C.int(0); lpi < langp.ga_len; lpi += 1 {
		mi.mi_lp = langp_entry(langp, lpi)

		slang := mi.mi_lp.lp_slang
		if (^Slang_T)(slang).sl_fidxs == nil {
			continue
		}

		find_word(&mi, FIND_FOLDWORD)
		find_word(&mi, FIND_KEEPWORD)
		find_prefix(&mi, FIND_FOLDWORD)

		if (^Slang_T)(slang).sl_nobreak && mi.mi_result == SP_BAD && mi.mi_result2 != SP_BAD {
			mi.mi_result = mi.mi_result2
			mi.mi_end = mi.mi_end2
		}

		if count_word && mi.mi_result == SP_OK {
			count_common_word((^Slang_T)(slang), ptr, C.int(uintptr(mi.mi_end) - uintptr(ptr)), 1)
			count_word = false
		}
	}

	if mi.mi_result != SP_OK {
		if nrlen > 0 {
			if mi.mi_result == SP_BAD || mi.mi_result == SP_BANNED {
				return nrlen
			}
		} else if !spell_iswordp_nmw(ptr, wp) {
			if capcol != nil && sb_cap_prog_r(ws) != nil {
				regmatch: Regmatch_T
				regmatch.regprog = sb_cap_prog_r(ws)
				regmatch.rm_ic = 0
				r := vim_regexec_r(&regmatch, ptr, 0) != 0
				sb_cap_prog_set(ws, regmatch.regprog)
				if r {
					capcol^ = C.int(uintptr(regmatch.endp[0]) - uintptr(ptr))
				}
			}
			return C.size_t(utfc_ptr2len(transmute(cstring)(ptr)))
		} else if mi.mi_end == ptr {
			mi.mi_end = mb_ptr_adv(mi.mi_end)
		} else if mi.mi_result == SP_BAD && langp_entry(langp, 0).lp_slang != nil &&
		(^Slang_T)(langp_entry(langp, 0).lp_slang).sl_nobreak {
			save_result := mi.mi_result

			mi.mi_lp = langp_entry(langp, 0)
			if mi.mi_lp.lp_slang != nil && (^Slang_T)(mi.mi_lp.lp_slang).sl_fidxs != nil {
				p := mi.mi_word
				fp := &mi.mi_fword[0]
				for true {
					p = mb_ptr_adv(p)
					fp = mb_ptr_adv(fp)
					if uintptr(p) >= uintptr(mi.mi_end) {
						break
					}
					mi.mi_compoff = C.int(uintptr(fp) - uintptr(&mi.mi_fword[0]))
					find_word(&mi, FIND_COMPOUND)
					if mi.mi_result != SP_BAD {
						mi.mi_end = p
						break
					}
				}
				mi.mi_result = save_result
			}
		}

		if mi.mi_result == SP_BAD || mi.mi_result == SP_BANNED {
			attrp^ = HLF_SPB
		} else if mi.mi_result == SP_RARE {
			attrp^ = HLF_SPR
		} else {
			attrp^ = HLF_SPL
		}
	}

	if wrongcaplen > 0 && (mi.mi_result == SP_OK || mi.mi_result == SP_RARE) {
		attrp^ = HLF_SPC
		return wrongcaplen
	}

	return C.size_t(uintptr(mi.mi_end) - uintptr(ptr))
}

ga_empty_sp :: proc "c"(ga: ^Garray) -> bool {
	return ga.ga_len <= 0
}

langp_entry :: proc "c"(ga: ^Garray, i: C.int) -> ^Langp_T {
	return (^Langp_T)(uintptr(ga.ga_data) + uintptr(i) * size_of(Langp_T))
}

@(export)
spell_iswordp :: proc "c"(p_in: ^u8, wp: rawptr) -> bool {
	sb := win_s_r(wp)
	p := p_in
	l := utfc_ptr2len(transmute(cstring)(p))
	s := p
	if l == 1 {
		// be quick for ASCII
		if (^bool)(uintptr(sb) + SB_SPELL_ISMW_OFF + uintptr(b_at(p, 0)))^ {
			s = (^u8)(uintptr(p) + 1)
		}
	} else {
		c := utf_ptr2char(transmute(cstring)(p))
		if (c < 256 ? (^bool)(uintptr(sb) + SB_SPELL_ISMW_OFF + uintptr(c))^ :
		((^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^ != nil &&
		_vim_strchr(transmute(cstring)((^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^), c) != nil)) {
			s = (^u8)(uintptr(p) + uintptr(l))
		}
	}

	c2 := utf_ptr2char(transmute(cstring)(s))
	if c2 > 255 {
		return spell_mb_isword_class(mb_get_class_r(transmute(cstring)(s)), wp)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return st.st_isw[c2]
}

SB_SPELL_ISMW_OFF :: 824 // synblock_T.b_spell_ismw bool[256]
SB_SPELL_ISMW_MB_OFF :: 1080 // ^u8 b_spell_ismw_mb
SB_CJK_OFF :: 1132

@(export)
spell_iswordp_nmw :: proc "c"(p: ^u8, wp: rawptr) -> bool {
	c := utf_ptr2char(transmute(cstring)(p))
	if c > 255 {
		return spell_mb_isword_class(mb_get_class_r(transmute(cstring)(p)), wp)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return st.st_isw[c]
}

spell_mb_isword_class :: proc "c"(cl: C.int, wp: rawptr) -> bool {
	if (^bool)(uintptr(win_s_r(wp)) + SB_CJK_OFF)^ {
		// East Asian characters are not considered word characters.
		return cl == 2 || cl == 0x2800
	}
	return cl >= 2 && cl != 0x2070 && cl != 0x2080 && cl != 3
}

spell_iswordp_w :: proc "c"(p: ^C.int, wp: rawptr) -> bool {
	sb := win_s_r(wp)
	s: ^C.int
	in_mw := false
	if p^ < 256 {
		in_mw = (^bool)(uintptr(sb) + SB_SPELL_ISMW_OFF + uintptr(p^))^
	} else {
		mb := (^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^
		in_mw = mb != nil && _vim_strchr(transmute(cstring)(mb), p^) != nil
	}
	if in_mw {
		s = (^C.int)(uintptr(p) + size_of(C.int))
	} else {
		s = p
	}

	if s^ > 255 {
		return spell_mb_isword_class(utf_class_r(s^), wp)
	}
	st := (^Spelltab_T)(&spelltab[0])
	return st.st_isw[s^]
}

@(export)
spell_casefold :: proc "c"(wp: rawptr, str: ^u8, len: C.int, buf: ^u8, buflen: C.int) -> C.int {
	if len >= buflen {
		b_set(buf, 0, 0)
		return 0 // FAIL
	}

	outi := C.int(0)

	p := uintptr(str)
	end := uintptr(str) + uintptr(len)
	for p < end {
		if outi + 6 > buflen { // MB_MAXBYTES
			b_set(buf, outi, 0)
			return 0 // FAIL
		}
		c := utf_ptr2char(transmute(cstring)(^u8)(p))
		l := utfc_ptr2len(transmute(cstring)(^u8)(p))
		p += uintptr(l)

		// greek capital sigma folds to final sigma at word end.
		if c == 0x03a3 || c == 0x03c2 {
			if p == end || !spell_iswordp((^u8)(p), wp) {
				c = 0x03c2
			} else {
				c = 0x03c3
			}
		} else {
			c = spell_tofold(c)
		}

		outi += utf_char2bytes_r(c, (^u8)(uintptr(buf) + uintptr(outi)))
	}
	b_set(buf, outi, 0)

	return 1 // OK
}

get_char_type :: proc "c"(c: C.int) -> C.int {
	if c >= '0' && c <= '9' {
		return CHAR_DIGIT
	}
	if spell_isupper(c) {
		return CHAR_UPPER
	}
	return CHAR_OTHER
}

advance_camelcase_word :: proc "c"(str: ^u8, wp: rawptr, is_camel_case: ^bool) -> ^u8 {
	end := str

	is_camel_case^ = false

	if b_at(str, 0) == 0 {
		return str
	}

	c := utf_ptr2char(transmute(cstring)(end))
	end = mb_ptr_adv(end)
	last_last_type := C.int(-1)
	last_type := get_char_type(c)

	for b_at(end, 0) != 0 && spell_iswordp(end, wp) {
		c = utf_ptr2char(transmute(cstring)(end))
		this_type := get_char_type(c)

		if last_last_type == CHAR_UPPER && last_type == CHAR_UPPER && this_type == CHAR_OTHER {
			is_camel_case^ = true
			end = mb_ptr_back(str, end)
			break
		} else if (this_type == CHAR_UPPER && last_type == CHAR_OTHER) ||
		(this_type != last_type && (this_type == CHAR_DIGIT || last_type == CHAR_DIGIT)) {
			is_camel_case^ = true
			break
		}

		last_last_type = last_type
		last_type = this_type

		end = mb_ptr_adv(end)
	}

	return end
}

// Check if the word at "mip->mi_word" is in the tree.
// mode: FIND_FOLDWORD / FIND_KEEPWORD / FIND_PREFIX / FIND_COMPOUND /
// FIND_KEEPCOMPOUND. For a match mip->mi_result is updated.
find_word :: proc "c"(mip: ^Matchinf_T, mode: C.int) {
	wlen := C.int(0)
	flen := C.int(0)
	ptr: ^u8
	slang := (^Slang_T)(mip.mi_lp.lp_slang)
	byts: ^u8
	idxs: ^idx_T

	if mode == FIND_KEEPWORD || mode == FIND_KEEPCOMPOUND {
		// Check for word with matching case in keep-case tree.
		ptr = mip.mi_word
		flen = 9999 // no case folding, always enough bytes
		byts = slang.sl_kbyts
		idxs = slang.sl_kidxs

		if mode == FIND_KEEPCOMPOUND {
			wlen += mip.mi_compoff
		}
	} else {
		// Check for case-folded in case-folded tree.
		ptr = &mip.mi_fword[0]
		flen = mip.mi_fwordlen
		byts = slang.sl_fbyts
		idxs = slang.sl_fidxs

		if mode == FIND_PREFIX {
			wlen = mip.mi_prefixlen
			flen -= mip.mi_prefixlen
		} else if mode == FIND_COMPOUND {
			wlen = mip.mi_compoff
			flen -= mip.mi_compoff
		}
	}

	if byts == nil {
		return
	}
	arridx := idx_T(0)
	endlen: [MAXWLEN]C.int
	endidx: [MAXWLEN]idx_T
	endidxcnt := C.int(0)

	for true {
		if flen <= 0 && b_at(mip.mi_fend, 0) != 0 {
			flen = fold_more(mip)
		}

		len := C.int(b_at(byts, arridx))
		arridx += 1

		// If the first possible byte is a zero the word could end here.
		if b_at(byts, arridx) == 0 {
			if endidxcnt == MAXWLEN {
				emsg(cstring("E759: Format error in spell file"))
				return
			}
			endlen[endidxcnt] = wlen
			endidx[endidxcnt] = arridx
			endidxcnt += 1
			arridx += 1
			len -= 1

			// Skip over the zeros: several flag/region combinations.
			for len > 0 && b_at(byts, arridx) == 0 {
				arridx += 1
				len -= 1
			}
			if len == 0 {
				break // no children, word must end here
			}
		}

		// Stop looking at end of the line.
		if b_at(ptr, wlen) == 0 {
			break
		}

		// Perform a binary search in the list of accepted bytes.
		c := C.int(b_at(ptr, wlen))
		if c == '\t' {
			c = ' '
		}
		lo := arridx
		hi := arridx + len - 1
		for lo < hi {
			m2 := (lo + hi) / 2
			if C.int(b_at(byts, m2)) > c {
				hi = m2 - 1
			} else if C.int(b_at(byts, m2)) < c {
				lo = m2 + 1
			} else {
				lo = m2
				hi = m2
				break
			}
		}

		// Stop if there is no matching byte.
		if hi < lo || C.int(b_at(byts, lo)) != c {
			break
		}

		// Continue at the child (if there is one).
		arridx = int_at(idxs, lo)
		wlen += 1
		flen -= 1

		// One space in the good word may stand for several spaces in the
		// checked word.
		if c == ' ' {
			for true {
				if flen <= 0 && b_at(mip.mi_fend, 0) != 0 {
					flen = fold_more(mip)
				}
				if b_at(ptr, wlen) != ' ' && b_at(ptr, wlen) != '\t' {
					break
				}
				wlen += 1
				flen -= 1
			}
		}
	}

	// Verify that one of the possible endings is valid. Try the longest first.
	for endidxcnt > 0 {
		endidxcnt -= 1
		arridx = endidx[endidxcnt]
		wlen = endlen[endidxcnt]

		if utf_head_off(transmute(cstring)(ptr), transmute(cstring)(^u8)(uintptr(ptr) + uintptr(wlen))) > 0 {
			continue // not at first byte of character
		}
		word_ends: bool
		if spell_iswordp((^u8)(uintptr(ptr) + uintptr(wlen)), mip.mi_win) {
			if slang.sl_compprog == nil && !slang.sl_nobreak {
				continue // next char is a word character
			}
			word_ends = false
		} else {
			word_ends = true
		}
		prefix_found := false

		if mode != FIND_KEEPWORD {
			// Compute byte length in original word; length may change when
			// folding case. Shortcut when folded == keep-case.
			p := mip.mi_word
			if libc.strncmp(transmute(cstring)(ptr), transmute(cstring)(p), C.size_t(wlen)) != 0 {
				s := ptr
				for uintptr(s) < uintptr(ptr) + uintptr(wlen) {
					s = mb_ptr_adv(s)
					p = mb_ptr_adv(p)
				}
				wlen = C.int(uintptr(p) - uintptr(mip.mi_word))
			}
		}

		// Check flags and region. For FIND_PREFIX check condition+prefix ID.
		len3 := C.int(b_at(byts, arridx - 1))
		for ; len3 > 0 && b_at(byts, arridx) == 0; {
			flags := C.uint(int_at(idxs, arridx))

			skip_this := false
			if mode == FIND_FOLDWORD {
				if mip.mi_cend != (^u8)(uintptr(mip.mi_word) + uintptr(wlen)) {
					mip.mi_cend = (^u8)(uintptr(mip.mi_word) + uintptr(wlen))
					mip.mi_capflags = captype(mip.mi_word, mip.mi_cend)
				}
				if mip.mi_capflags == WF_KEEPCAP ||
				!spell_valid_case(mip.mi_capflags, C.int(flags)) {
					skip_this = true
				}
			} else if mode == FIND_PREFIX && !prefix_found {				c4 := valid_word_prefix(mip.mi_prefcnt, mip.mi_prefarridx,
					C.int(flags),
					(^u8)(uintptr(mip.mi_word) + uintptr(mip.mi_cprefixlen)),
					slang, false)
				if c4 == 0 {
					skip_this = true
				} else {
					if (c4 & WF_RAREPFX) != 0 {
						flags |= WF_RARE
					}
					prefix_found = true
				}
			}

			if !skip_this && slang.sl_nobreak {
				if (mode == FIND_COMPOUND || mode == FIND_KEEPCOMPOUND) &&
				(flags & WF_BANNED) == 0 {
					// NOBREAK: found a valid following word; done.
					mip.mi_result = SP_OK
					break
				}
			} else if !skip_this &&
			(mode == FIND_COMPOUND || mode == FIND_KEEPCOMPOUND || !word_ends) {
				// No compound flag or word shorter than COMPOUNDMIN: reject.
				if (flags >> 24) == 0 ||
				wlen - mip.mi_compoff < slang.sl_compminlen {
					skip_this = true
				}

				// Multi-byte chars: check char length against COMPOUNDMIN.
				if !skip_this && slang.sl_compminlen > 0 &&
				mb_charlen_len_r(transmute(cstring)(^u8)(uintptr(mip.mi_word) + uintptr(mip.mi_compoff)),
					C.size_t(wlen - mip.mi_compoff)) < slang.sl_compminlen {
					skip_this = true
				}

				// Limit compound words to COMPOUNDWORDMAX if no syllable max.
				if !skip_this && !word_ends &&
				mip.mi_complen + mip.mi_compextra + 2 > slang.sl_compmax &&
				slang.sl_compsylmax == MAXWLEN {
					skip_this = true
				}

				// Don't allow compounding on a side where an affix was added,
				// unless COMPOUNDPERMITFLAG was used.
				if !skip_this && mip.mi_complen > 0 && (flags & WF_NOCOMPBEF) != 0 {
					skip_this = true
				}
				if !skip_this && !word_ends && (flags & WF_NOCOMPAFT) != 0 {
					skip_this = true
				}

				// Quick check if compounding possible with this flag.
				if !skip_this &&
				!byte_in_str(mip.mi_complen == 0 ? slang.sl_compstartflags : slang.sl_compallflags,
					C.int(flags >> 24)) {
					skip_this = true
				}

				// CHECKCOMPOUNDPATTERN match discards the compound word.
				if !skip_this &&
				match_checkcompoundpattern(ptr, wlen, &slang.sl_comppat) {
					skip_this = true
				}

				if !skip_this && mode == FIND_COMPOUND {
					// Need to check the caps type of the appended compound word.
					cp: ^u8
					if libc.strncmp(transmute(cstring)(ptr), transmute(cstring)(mip.mi_word), C.size_t(mip.mi_compoff)) != 0 {
						// case folding may have changed the length
						cp = mip.mi_word
						s := ptr
						for uintptr(s) < uintptr(ptr) + uintptr(mip.mi_compoff) {
							s = mb_ptr_adv(s)
							cp = mb_ptr_adv(cp)
						}
					} else {
						cp = (^u8)(uintptr(mip.mi_word) + uintptr(mip.mi_compoff))
					}
					capflags := captype(cp, (^u8)(uintptr(mip.mi_word) + uintptr(wlen)))
					if capflags == WF_KEEPCAP ||
					(capflags == WF_ALLCAP && (flags & WF_FIXCAP) != 0) {
						skip_this = true
					}

					if !skip_this && capflags != WF_ALLCAP {
						// Char before word being a word char: no Onecap word.
						cp2 := mb_ptr_back(mip.mi_word, cp)
						bad: bool
						if spell_iswordp_nmw(cp2, mip.mi_win) {
							bad = capflags == WF_ONECAP
						} else {
							bad = (flags & WF_ONECAP) != 0 && capflags != WF_ONECAP
						}
						if bad {
							skip_this = true
						}
					}
				}

				// Word ends: compound flags must match a COMPOUNDRULE and the
				// number of syllables must not be too large.
				if !skip_this {
					b_set(&mip.mi_compflags[0], mip.mi_complen, u8(flags >> 24))
					b_set(&mip.mi_compflags[0], mip.mi_complen + 1, 0)
					if word_ends {
						fword: [MAXWLEN]u8
						mem_zero_sp(&fword[0], MAXWLEN)

						if slang.sl_compsylmax < MAXWLEN {
							// "fword" only needed for checking syllables.
							if ptr == mip.mi_word {
								spell_casefold(mip.mi_win, ptr, wlen, &fword[0], MAXWLEN)
							} else {
								xmemcpyz_sp(&fword[0], ptr, C.size_t(endlen[endidxcnt]))
							}
						}
						if !can_compound(slang, &fword[0], &mip.mi_compflags[0]) {
							skip_this = true
						}
					} else if slang.sl_comprules != nil &&
					!match_compoundrule(slang, &mip.mi_compflags[0]) {
						skip_this = true
					}
				}

				if !skip_this && (flags & WF_NEEDCOMP) != 0 {
					// word only valid in a compound
					skip_this = true
				}
			}

			if skip_this {
				len3 -= 1
				arridx += 1
				continue
			}

			nobreak_result: C.int = SP_OK

			if !word_ends {
				save_result := mip.mi_result
				save_end := mip.mi_end
				save_lp := mip.mi_lp

				if slang.sl_nobreak {
					mip.mi_result = SP_BAD
				}

				// Find following word in case-folded tree.
				mip.mi_compoff = endlen[endidxcnt]
				if mode == FIND_KEEPWORD {
					// Byte length in case-folded word from "wlen".
					pf := &mip.mi_fword[0]
					if libc.strncmp(transmute(cstring)(ptr), transmute(cstring)(pf), C.size_t(wlen)) != 0 {
						s := ptr
						for uintptr(s) < uintptr(ptr) + uintptr(wlen) {
							s = mb_ptr_adv(s)
							pf = mb_ptr_adv(pf)
						}
						mip.mi_compoff = C.int(uintptr(pf) - uintptr(&mip.mi_fword[0]))
					}
				}
				mip.mi_complen += 1
				if (flags & WF_COMPROOT) != 0 {
					mip.mi_compextra += 1
				}

				win_langp := sb_langp_r(win_s_r(mip.mi_win))
				for lpi := C.int(0); lpi < win_langp.ga_len; lpi += 1 {
					if slang.sl_nobreak {
						mip.mi_lp = langp_entry(win_langp, lpi)
						lps := (^Slang_T)(mip.mi_lp.lp_slang)
						if lps.sl_fidxs == nil || !lps.sl_nobreak {
							continue
						}
					}

					find_word(mip, FIND_COMPOUND)

					if !slang.sl_nobreak || mip.mi_result == SP_BAD {
						mip.mi_compoff = wlen
						find_word(mip, FIND_KEEPCOMPOUND)
					}

					if !slang.sl_nobreak {
						break
					}
				}
				mip.mi_complen -= 1
				if (flags & WF_COMPROOT) != 0 {
					mip.mi_compextra -= 1
				}
				mip.mi_lp = save_lp

				if slang.sl_nobreak {
					nobreak_result = mip.mi_result
					mip.mi_result = save_result
					mip.mi_end = save_end
				} else {
					if mip.mi_result == SP_OK {
						break
					}
					len3 -= 1
					arridx += 1
					continue
				}
			}

			res: C.int = SP_BAD
			if (flags & WF_BANNED) != 0 {
				res = SP_BANNED
			} else if (flags & WF_REGION) != 0 {
				// Check region.
				if (C.uint(mip.mi_lp.lp_region) & (flags >> 16)) != 0 {
					res = SP_OK
				} else {
					res = SP_LOCAL
				}
			} else if (flags & WF_RARE) != 0 {
				res = SP_RARE
			} else {
				res = SP_OK
			}

			// Always use the longest match and the best result.
			if nobreak_result == SP_BAD {
				if mip.mi_result2 > res {
					mip.mi_result2 = res
					mip.mi_end2 = (^u8)(uintptr(mip.mi_word) + uintptr(wlen))
				} else if mip.mi_result2 == res &&
				uintptr(mip.mi_end2) < uintptr(mip.mi_word) + uintptr(wlen) {
					mip.mi_end2 = (^u8)(uintptr(mip.mi_word) + uintptr(wlen))
				}
			} else if mip.mi_result > res {
				mip.mi_result = res
				mip.mi_end = (^u8)(uintptr(mip.mi_word) + uintptr(wlen))
			} else if mip.mi_result == res &&
			uintptr(mip.mi_end) < uintptr(mip.mi_word) + uintptr(wlen) {
				mip.mi_end = (^u8)(uintptr(mip.mi_word) + uintptr(wlen))
			}

			if mip.mi_result == SP_OK {
				break
			}
			len3 -= 1
			arridx += 1
		}

		if mip.mi_result == SP_OK {
			break
		}
	}
}

mem_zero_sp :: proc "c"(p: ^u8, n: C.int) {
	libc.memset(p, 0, C.size_t(n))
}

xmemcpyz_sp :: proc "c"(dst: ^u8, src: ^u8, n: C.size_t) {
	libc.memcpy(dst, src, n)
	b_set(dst, C.int(n), 0)
}

int_at :: proc "c" (p: ^C.int, i: C.int) -> C.int {
	return ([^]C.int)(p)[i]
}

@(export)
spell_valid_case :: proc "c"(wordflags: C.int, treeflags: C.int) -> bool {
	return (wordflags == WF_ALLCAP && (treeflags & WF_FIXCAP) == 0) ||
	((treeflags & (WF_ALLCAP | WF_KEEPCAP)) == 0 &&
	((treeflags & WF_ONECAP) == 0 || (wordflags & WF_ONECAP) != 0))
}

// mb_ptr2char_adv: c = utf_ptr2char(p); p += utf_ptr2len(p)
mb_ptr2char_adv :: proc "c"(pp: ^^u8) -> C.int {
	p := pp^
	c := utf_ptr2char(transmute(cstring)(p))
	pp^ = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
	return c
}

@(export)
captype :: proc "c"(word: ^u8, end: ^u8) -> C.int {
	p := word

	// find first letter
	for !spell_iswordp_nmw(p, curwin) {
		if end == nil ? b_at(p, 0) == 0 : uintptr(p) >= uintptr(end) {
			return 0 // only non-word characters, illegal word
		}
		p = mb_ptr_adv(p)
	}
	c := mb_ptr2char_adv(&p)
	allcap := spell_isupper(c)
	firstcap := allcap
	past_second := false

	// Need to check all letters to find a word with mixed upper/lower.
	for ; end == nil ? b_at(p, 0) != 0 : uintptr(p) < uintptr(end); {
		if spell_iswordp_nmw(p, curwin) {
			c = utf_ptr2char(transmute(cstring)(p))
			if !spell_isupper(c) {
				// UUl -> KEEPCAP
				if past_second && allcap {
					return WF_KEEPCAP
				}
				allcap = false
			} else if !allcap {
				// UlU -> KEEPCAP
				return WF_KEEPCAP
			}
			past_second = true
		}
		p = mb_ptr_adv(p)
	}

	if allcap {
		return WF_ALLCAP
	}
	if firstcap {
		return WF_ONECAP
	}
	return 0
}

@(export)
nofold_len :: proc "c"(fword: ^u8, flen: C.int, word: ^u8) -> C.int {
	i := C.int(0)

	p := fword
	for uintptr(p) < uintptr(fword) + uintptr(flen) {
		i += 1
		p = mb_ptr_adv(p)
	}
	p = word
	for i > 0 {
		i -= 1
		p = mb_ptr_adv(p)
	}
	return C.int(uintptr(p) - uintptr(word))
}

@(export)
byte_in_str :: proc "c"(str_in: ^u8, n: C.int) -> bool {
	str := str_in
	for b_at(str, 0) != 0 {
		if C.int(b_at(str, 0)) == n {
			return true
		}
		str = (^u8)(uintptr(str) + 1)
	}
	return false
}

@(export)
match_checkcompoundpattern :: proc "c"(ptr: ^u8, wlen: C.int, gap: ^Garray) -> bool {
	i := C.int(0)
	for ; i + 1 < gap.ga_len; i += 2 {
		items := ([^]^u8)(gap.ga_data)
		p := items[i + 1]
		plen := libc.strlen(transmute(cstring)(p))
		if libc.strncmp(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(wlen)), transmute(cstring)(p), plen) == 0 {
			// Second part matches; check first part at end of previous word.
			p = items[i]
			len := C.int(libc.strlen(transmute(cstring)(p)))
			if len <= wlen && libc.strncmp(transmute(cstring)(^u8)(uintptr(ptr) + uintptr(wlen - len)), transmute(cstring)(p), C.size_t(len)) == 0 {
				return true
			}
		}
	}
	return false
}

@(export)
can_compound :: proc "c"(slang: ^Slang_T, word: ^u8, flags: ^u8) -> bool {
	uflags: [MAXWLEN * 2]u8
	mem_zero_sp(&uflags[0], MAXWLEN * 2)

	if slang.sl_compprog == nil {
		return false
	}
	// Convert single byte flags to utf8 characters.
	p := uintptr(&uflags[0])
	for i := C.int(0); b_at(flags, i) != 0; i += 1 {
		n := utf_char2bytes_r(C.int(b_at(flags, i)), (^u8)(p))
		p += uintptr(n)
	}
	b_set((^u8)(p), 0, 0)
	if vim_regexec_prog_r(&slang.sl_compprog, false, transmute(cstring)(&uflags[0]), 0) == 0 {
		return false
	}

	// Count syllables last. Too many AND compound words above
	// COMPOUNDWORDMAX: compounding not allowed.
	if slang.sl_compsylmax < MAXWLEN &&
	count_syllables(slang, word) > slang.sl_compsylmax {
		return libc.strlen(transmute(cstring)(flags)) < C.size_t(slang.sl_compmax)
	}
	return true
}

@(export)
match_compoundrule :: proc "c"(slang: ^Slang_T, compflags: ^u8) -> bool {
	// loop over the COMPOUNDRULE entries
	p := slang.sl_comprules
	for b_at(p, 0) != 0 {
		// loop over the flags in the compound word we have made
		i := C.int(0)
		for true {
			c := C.int(b_at(compflags, i))
			if c == 0 {
				// found a rule matching the flags so far
				return true
			}
			if b_at(p, 0) == '/' || b_at(p, 0) == 0 {
				break // end of rule, too short
			}
			if b_at(p, 0) == '[' {
				matched := false

				p = (^u8)(uintptr(p) + 1)
				for b_at(p, 0) != ']' && b_at(p, 0) != 0 {
					if C.int(b_at(p, 0)) == c {
						matched = true
					}
					p = (^u8)(uintptr(p) + 1)
				}
				if !matched {
					break // none matches
				}
			} else if C.int(b_at(p, 0)) != c {
				break // flag of word doesn't match flag in pattern
			}
			p = (^u8)(uintptr(p) + 1)
			i += 1
		}

		// Skip to next "/", where next pattern starts.
		q := _vim_strchr(transmute(cstring)(p), '/')
		if q == nil {
			break
		}
		p = transmute(^u8)(q)
	}

	// No rule matches these flags: no compound can start with them.
	return false
}

@(export)
valid_word_prefix :: proc "c"(totprefcnt: C.int, arridx: C.int, flags: C.int, word: ^u8, slang: ^Slang_T, cond_req: bool) -> C.int {
	prefid := C.int(C.uint(flags) >> 24)
	for prefcnt := totprefcnt - 1; prefcnt >= 0; prefcnt -= 1 {
		pidx := int_at(slang.sl_pidxs, arridx + prefcnt)

		// Check the prefix ID.
		if prefid != (pidx & 0xff) {
			continue
		}

		// Prefix doesn't combine and word already has a suffix.
		if (flags & WF_HAS_AFF) != 0 && (pidx & WF_PFX_NC) != 0 {
			continue
		}

		// The condition index is in the two bytes above prefix ID byte.
		rp := (^rawptr)(uintptr(slang.sl_prefprog) + uintptr((C.uint(pidx) >> 8) & 0xffff) * size_of(rawptr))
		if rp^ != nil {
			if vim_regexec_prog_r(rp, false, transmute(cstring)(word), 0) == 0 {
				continue
			}
		} else if cond_req {
			continue
		}

		// Match! Return the WF_ flags.
		return pidx
	}
	return 0
}

// Check if the word at "mip->mi_word" has a matching prefix; then check the
// following word. For a match mip->mi_result is updated.
find_prefix :: proc "c"(mip: ^Matchinf_T, mode: C.int) {
	arridx := idx_T(0)
	wlen := C.int(0)
	slang := (^Slang_T)(mip.mi_lp.lp_slang)

	byts := slang.sl_pbyts
	if byts == nil {
		return
	}
	// Prefixes are always case-folded.
	ptr := &mip.mi_fword[0]
	flen := mip.mi_fwordlen
	if mode == FIND_COMPOUND {
		ptr = (^u8)(uintptr(ptr) + uintptr(mip.mi_compoff))
		flen -= mip.mi_compoff
	}
	idxs := slang.sl_pidxs

	for true {
		if flen == 0 && b_at(mip.mi_fend, 0) != 0 {
			flen = fold_more(mip)
		}

		len := C.int(b_at(byts, arridx))
		arridx += 1

		// First possible byte zero: prefix could end here.
		if b_at(byts, arridx) == 0 {
			mip.mi_prefarridx = arridx
			mip.mi_prefcnt = len
			for len > 0 && b_at(byts, arridx) == 0 {
				arridx += 1
				len -= 1
			}
			mip.mi_prefcnt -= len

			// Find the word that comes after the prefix.
			mip.mi_prefixlen = wlen
			if mode == FIND_COMPOUND {
				mip.mi_prefixlen += mip.mi_compoff
			}

			// Case-folded length may differ from original length.
			mip.mi_cprefixlen = nofold_len(&mip.mi_fword[0], mip.mi_prefixlen, mip.mi_word)
			find_word(mip, FIND_PREFIX)

			if len == 0 {
				break // no children, prefix must end here
			}
		}

		// Stop looking at end of the line.
		if b_at(ptr, wlen) == 0 {
			break
		}

		// Binary search in the list of accepted bytes.
		c := C.int(b_at(ptr, wlen))
		lo := arridx
		hi := arridx + len - 1
		for lo < hi {
			m2 := (lo + hi) / 2
			if C.int(b_at(byts, m2)) > c {
				hi = m2 - 1
			} else if C.int(b_at(byts, m2)) < c {
				lo = m2 + 1
			} else {
				lo = m2
				hi = m2
				break
			}
		}

		// Stop if there is no matching byte.
		if hi < lo || C.int(b_at(byts, lo)) != c {
			break
		}

		// Continue at the child (if there is one).
		arridx = int_at(idxs, lo)
		wlen += 1
		flen -= 1
	}
}

// Fold at least one more character; do until next non-word char (included).
fold_more :: proc "c"(mip: ^Matchinf_T) -> C.int {
	p := mip.mi_fend
	for true {
		mip.mi_fend = mb_ptr_adv(mip.mi_fend)
		if !(b_at(mip.mi_fend, 0) != 0 && spell_iswordp(mip.mi_fend, mip.mi_win)) {
			break
		}
	}

	// Include the non-word character so we can check for the word end.
	if b_at(mip.mi_fend, 0) != 0 {
		mip.mi_fend = mb_ptr_adv(mip.mi_fend)
	}

	spell_casefold(mip.mi_win, p, C.int(uintptr(mip.mi_fend) - uintptr(p)),
		(^u8)(uintptr(&mip.mi_fword[0]) + uintptr(mip.mi_fwordlen)),
		MAXWLEN - mip.mi_fwordlen)
	flen := C.int(libc.strlen(transmute(cstring)(^u8)(uintptr(&mip.mi_fword[0]) + uintptr(mip.mi_fwordlen))))
	mip.mi_fwordlen += flen
	return flen
}

@(export)
count_common_word :: proc "c"(lp: ^Slang_T, word: ^u8, len: C.int, count: u8) {
	buf: [MAXWLEN]u8
	p: cstring

	if len == -1 {
		p = transmute(cstring)(word)
	} else if len >= MAXWLEN {
		return
	} else {
		xmemcpyz_sp(&buf[0], word, C.size_t(len))
		p = transmute(cstring)(&buf[0])
	}

	hash := hash_hash_r(p)
	p_len := libc.strlen(p)
	ht := &lp.sl_wordcount_buf[0]
	hi := hash_lookup_r(ht, p, p_len, hash)
	// HASHITEM_EMPTY: hi->hi_key == NULL or points to ht->ht_array (tombstone).
	// hi_key is at offset 8 in hashitem_T (u64 hash then key ptr).
	hi_key := hi == nil ? nil : (^rawptr)(uintptr(hi) + 8)^
	// hash_removed is a C global char; HASHITEM_EMPTY checks NULL or that.
	if hi_key != nil && hi_key == transmute(rawptr)(&hash_removed_c) {
		hi_key = nil
	}
	if hi_key == nil {
		wc := (^Wordcount_T_alloc)(xmalloc_sp(WC_KEY_OFF + p_len + 1))
		libc.memcpy(&wc.wc_word[0], transmute(^u8)(p), p_len + 1)
		wc.wc_count = C.ushort(count)
		hash_add_item_r(ht, hi, &wc.wc_word[0], hash)
	} else {
		// HI2WC(hi): (wordcount_T *)(hi_key - WC_KEY_OFF)
		wc := (^Wordcount_T_alloc)(uintptr(hi_key) - WC_KEY_OFF)
		newc := C.uint(wc.wc_count) + C.uint(count)
		if newc > MAXWORDCOUNT {
			newc = MAXWORDCOUNT
		}
		wc.wc_count = C.ushort(newc)
	}
}

// wordcount_T allocation mirror (flexible array → leading fields; wc_word
// follows at offset WC_KEY_OFF=8)
Wordcount_T_alloc :: struct {
	wc_count: C.ushort,
	wc_word:  [1]u8,
}

foreign _ {
	@(link_name = "xmalloc")
	xmalloc_sp :: proc "c" (size: C.size_t) -> rawptr ---
	@(link_name = "hash_removed")
	hash_removed_c: u8
}

@(export)
init_syl_tab :: proc "c"(slang: ^Slang_T) -> C.int {
	ga_init_r(&slang.sl_syl_items, size_of(Syl_Item_T), 4)
	p := _vim_strchr(transmute(cstring)(slang.sl_syllable), '/')
	for p != nil {
		q := transmute(^u8)(p)
		b_set(q, 0, 0)
		q = (^u8)(uintptr(q) + 1)
		if b_at(q, 0) == 0 { // trailing slash
			break
		}
		s := q
		p2 := _vim_strchr(transmute(cstring)(q), '/')
		l: C.int
		if p2 == nil {
			l = C.int(libc.strlen(transmute(cstring)(s)))
		} else {
			l = C.int(uintptr(transmute(^u8)(p2)) - uintptr(s))
		}
		if l >= SY_MAXLEN {
			return SP_FORMERROR
		}

		// GA_APPEND_VIA_PTR(syl_item_T, &slang->sl_syl_items)
		if slang.sl_syl_items.ga_len >= slang.sl_syl_items.ga_maxlen {
			ga_grow_sp(&slang.sl_syl_items, 1)
		}
		syl := (^Syl_Item_T)(uintptr(slang.sl_syl_items.ga_data) + uintptr(slang.sl_syl_items.ga_len) * size_of(Syl_Item_T))
		slang.sl_syl_items.ga_len += 1
		xmemcpyz_sp(&syl.sy_chars[0], s, C.size_t(l))
		syl.sy_len = l
	}
	return 1 // OK
}

foreign _ {
	@(link_name = "ga_grow")
	ga_grow_sp :: proc "c" (gap: rawptr, n: C.int) ---
}

count_syllables :: proc "c"(slang: ^Slang_T, word: ^u8) -> C.int {
	if slang.sl_syllable == nil {
		return 0
	}

	cnt := C.int(0)
	skip := false

	p := word
	for b_at(p, 0) != 0 {
		// When running into a space reset counter.
		if b_at(p, 0) == ' ' {
			p = (^u8)(uintptr(p) + 1)
			cnt = 0
			continue
		}

		// Find longest match of syllable items.
		len := C.int(0)
		for i := C.int(0); i < slang.sl_syl_items.ga_len; i += 1 {
			syl := (^Syl_Item_T)(uintptr(slang.sl_syl_items.ga_data) + uintptr(i) * size_of(Syl_Item_T))
			if syl.sy_len > len &&
			libc.strncmp(transmute(cstring)(p), transmute(cstring)(&syl.sy_chars[0]), C.size_t(syl.sy_len)) == 0 {
				len = syl.sy_len
			}
		}
		if len != 0 { // found a match, count syllable
			cnt += 1
			skip = false
		} else {
			// No recognized syllable item; at least a syllable char then?
			c := utf_ptr2char(transmute(cstring)(p))
			len = utfc_ptr2len(transmute(cstring)(p))
			if _vim_strchr(transmute(cstring)(slang.sl_syllable), c) == nil {
				skip = false // No, search for next syllable
			} else if !skip {
				cnt += 1 // Yes, count it
				skip = true // don't count following syllable chars
			}
		}
		p = (^u8)(uintptr(p) + uintptr(len))
	}
	return cnt
}

// ── slang lifecycle ──────────────────────────────────────────────────────────

@(export)
slang_alloc :: proc "c"(lang: ^u8) -> ^Slang_T {
	lp := (^Slang_T)(xcalloc_sp(1, size_of(Slang_T)))

	if lang != nil {
		lp.sl_name = xstrdup_r(transmute(cstring)(lang))
	}
	ga_init_r(&lp.sl_rep, size_of(Fromto_T), 10)
	ga_init_r(&lp.sl_repsal, size_of(Fromto_T), 10)
	lp.sl_compmax = MAXWLEN
	lp.sl_compsylmax = MAXWLEN
	hash_init_r(&lp.sl_wordcount_buf[0])

	return lp
}

@(export)
slang_free :: proc "c"(lp: ^Slang_T) {
	xfree(lp.sl_name)
	xfree(lp.sl_fname)
	slang_clear(lp)
	xfree(lp)
}

free_salitem :: proc "c"(smp: ^Salitem_T) {
	xfree(smp.sm_lead)
	// Don't free sm_oneof and sm_rules, they point into sm_lead.
	xfree(smp.sm_to)
	xfree(smp.sm_lead_w)
	xfree(smp.sm_oneof_w)
	xfree(smp.sm_to_w)
}

free_fromto :: proc "c"(ftp: ^Fromto_T) {
	xfree(ftp.ft_from)
	xfree(ftp.ft_to)
}

@(export)
slang_clear :: proc "c"(lp: ^Slang_T) {
	xfree_clear_sp(&lp.sl_fbyts)
	xfree_clear_sp(&lp.sl_kbyts)
	xfree_clear_sp(&lp.sl_pbyts)

	xfree_clear_sp(&lp.sl_fidxs)
	xfree_clear_sp(&lp.sl_kidxs)
	xfree_clear_sp(&lp.sl_pidxs)

	// GA_DEEP_CLEAR(&lp->sl_rep, fromto_T, free_fromto)
	ga_deep_clear_fromto(&lp.sl_rep)
	ga_deep_clear_fromto(&lp.sl_repsal)

	if lp.sl_sofo {
		// wide char lists
		for i := C.int(0); i < lp.sl_sal.ga_len; i += 1 {
			item := (^rawptr)(uintptr(lp.sl_sal.ga_data) + uintptr(i) * size_of(rawptr))
			xfree(item^)
		}
		ga_clear_r(&lp.sl_sal)
	} else {
		for i := C.int(0); i < lp.sl_sal.ga_len; i += 1 {
			free_salitem((^Salitem_T)(uintptr(lp.sl_sal.ga_data) + uintptr(i) * size_of(Salitem_T)))
		}
		ga_clear_r(&lp.sl_sal)
	}

	for i := C.int(0); i < lp.sl_prefixcnt; i += 1 {
		vim_regfree((^rawptr)(uintptr(lp.sl_prefprog) + uintptr(i) * size_of(rawptr))^)
	}
	lp.sl_prefixcnt = 0
	xfree_clear_sp(&lp.sl_prefprog)
	xfree_clear_sp(&lp.sl_info)
	xfree_clear_sp(&lp.sl_midword)

	vim_regfree(lp.sl_compprog)
	lp.sl_compprog = nil
	xfree_clear_sp(&lp.sl_comprules)
	xfree_clear_sp(&lp.sl_compstartflags)
	xfree_clear_sp(&lp.sl_compallflags)

	xfree_clear_sp(&lp.sl_syllable)
	ga_clear_r(&lp.sl_syl_items)

	ga_clear_strings_r(&lp.sl_comppat)

	hash_clear_all_r(&lp.sl_wordcount_buf[0], WC_KEY_OFF)
	hash_init_r(&lp.sl_wordcount_buf[0])

	hash_clear_all_r(&lp.sl_map_hash_buf[0], 0)

	// Clear info from .sug file.
	slang_clear_sug(lp)

	lp.sl_compmax = MAXWLEN
	lp.sl_compminlen = 0
	lp.sl_compsylmax = MAXWLEN
	b_set(&lp.sl_regions[0], 0, 0)
}

ga_deep_clear_fromto :: proc "c"(gap: ^Garray) {
	for i := C.int(0); i < gap.ga_len; i += 1 {
		free_fromto((^Fromto_T)(uintptr(gap.ga_data) + uintptr(i) * size_of(Fromto_T)))
	}
	ga_clear_r(gap)
}

@(export)
slang_clear_sug :: proc "c"(lp: ^Slang_T) {
	xfree_clear_sp(&lp.sl_sbyts)
	xfree_clear_sp(&lp.sl_sidxs)
	xfree(lp.sl_sugbuf)
							xfree(lp.sl_sugbuf)
	lp.sl_sugbuf = nil
	lp.sl_sugloaded = false
	lp.sl_sugtime = 0
}

foreign _ {
	@(link_name = "xcalloc")
	xcalloc_sp :: proc "c" (n: C.size_t, sz: C.size_t) -> rawptr ---
	@(link_name = "xstrdup")
	xstrdup_r :: proc "c" (s: cstring) -> ^u8 ---
}

// XFREE_CLEAR(ptr): xfree(ptr); ptr = NULL. pp is the address of the field.
xfree_clear_sp :: proc "c"(pp: rawptr) {
	p := (^rawptr)(pp)^
	xfree(p)
	(^rawptr)(pp)^ = nil
}

@(export)
spell_enc :: proc "c"() -> ^u8 {
	if libc.strlen(transmute(cstring)(p_enc)) < 60 &&
	libc.strcmp(transmute(cstring)(p_enc), "iso-8859-15") != 0 {
		return p_enc
	}
	return transmute(^u8)(cstring("latin1"))
}

int_wordlist_spl :: proc "c"(fname: ^u8) {
	libc.snprintf(fname, MAXPATHL_S, SPL_FNAME_TMPL, transmute(cstring)(int_wordlist), transmute(cstring)(spell_enc()))
}

// Load word list(s) for "lang" from Vim spell file(s).
spell_load_lang :: proc "c"(lang: ^u8) {
	fname_enc: [85]u8
	r := C.int(0)
	sl: Spelload_T

	libc.strcpy(&sl.sl_lang_buf[0], transmute(cstring)(lang))
	sl.sl_slang = nil
	sl.sl_nobreak = 0

	// Disallow deleting the current buffer.
	buf_locked_inc(curbuf, 1)

	round := C.int(1)
	for ; round <= 2; round += 1 {
		libc.snprintf(&fname_enc[0], 80, "spell/%s.%s.spl", transmute(cstring)(lang), transmute(cstring)(spell_enc()))
		r = do_in_runtimepath_r(transmute(cstring)(&fname_enc[0]), 0, transmute(rawptr)(spell_load_cb_c), &sl)

		if r == 0 && b_at(&sl.sl_lang_buf[0], 0) != 0 {
			// Try loading the ASCII version.
			libc.snprintf(&fname_enc[0], 80, "spell/%s.ascii.spl", transmute(cstring)(lang))
			r = do_in_runtimepath_r(transmute(cstring)(&fname_enc[0]), 0, transmute(rawptr)(spell_load_cb_c), &sl)

			if r == 0 && b_at(&sl.sl_lang_buf[0], 0) != 0 && round == 1 {
				if apply_autocmds(EVENT_SPELLFILEMISSING, transmute(cstring)(lang), transmute(cstring)(buf_fname_r(curbuf)), false, curbuf) {
					continue
				}
			}
			break
		}
		break
	}

	if r == 0 {
		if starting != 0 {
			autocmd_buf: [512]u8
			libc.snprintf(&autocmd_buf[0], 512,
				"autocmd VimEnter * call v:lua.require'nvim.spellfile'.get('%s')|set spell",
				transmute(cstring)(lang))
			do_cmdline_cmd_r(transmute(cstring)(&autocmd_buf[0]))
		} else {
			semsg_sp(cstring("Warning: Cannot find word list \"%s.%s.spl\" or \"%s.ascii.spl\""),
				transmute(cstring)(lang), transmute(cstring)(spell_enc()), transmute(cstring)(lang))
		}
	} else if sl.sl_slang != nil {
		// At least one file was loaded, now load ALL the additions.
		n := libc.strlen(transmute(cstring)(&fname_enc[0]))
		libc.strcpy(([^]u8)(uintptr(&fname_enc[0]) + uintptr(n) - 3), "add.spl")
		do_in_runtimepath_r(transmute(cstring)(&fname_enc[0]), DIP_ALL, transmute(rawptr)(spell_load_cb_c), &sl)
	}

	buf_locked_inc(curbuf, -1)
}

semsg_sp :: proc "c"(fmt: cstring, a, b, cc: cstring) {
	tmp: [1024]u8
	libc.snprintf(&tmp[0], 1024, fmt, a, b, cc)
	emsg(transmute(cstring)(&tmp[0]))
}

foreign _ {
	@(link_name = "b_locked_offset_helper")
	_b_locked_unused: u8 // placeholder (removed below)
}

buf_locked_inc :: proc "c"(buf: rawptr, d: C.int) {
	(^C.int)(uintptr(buf) + 144)^ += d // buf_T.b_locked @144
}

// spell_load_cb must be passed as a C function pointer to do_in_runtimepath.
@(export)
spell_load_cb_c :: proc "c"(num_fnames: C.int, fnames: ^^u8, all: bool, cookie: rawptr) -> bool {
	slp := (^Spelload_T)(cookie)
	for i := C.int(0); i < num_fnames; i += 1 {
		slang := (^Slang_T)(spell_load_file_r(([^]^u8)(fnames)[i], &slp.sl_lang_buf[0], nil, false))

		if slang == nil {
			continue
		}

		// NOBREAK from previously loaded file also applies to ".add" files.
		if slp.sl_nobreak != 0 && slang.sl_add {
			slang.sl_nobreak = true
		} else if slang.sl_nobreak {
			slp.sl_nobreak = 1
		}

		slp.sl_slang = slang

		if !all {
			break
		}
	}

	return num_fnames > 0
}

@(export)
spell_check_window :: proc "c"(wp: rawptr) -> bool {
	return w_p_spell_r(wp) != 0 &&
	b_at(sb_p_spl_r(win_s_r(wp)), 0) != 0 &&
	sb_langp_r(win_s_r(wp)).ga_len > 0 &&
	(^rawptr)(sb_langp_r(win_s_r(wp)).ga_data)^ != nil
}

@(export)
no_spell_checking :: proc "c"(wp: rawptr) -> bool {
	if w_p_spell_r(wp) == 0 || b_at(sb_p_spl_r(win_s_r(wp)), 0) == 0 ||
	ga_empty_sp(sb_langp_r(win_s_r(wp))) {
		emsg(cstring("E756: Spell checking is not possible"))
		return true
	}
	return false
}

@(export)
spell_cat_line :: proc "c"(buf: ^u8, line: ^u8, maxlen: C.int) {
	p := transmute(^u8)(skipwhite(transmute(cstring)(line)))
	for _vim_strchr(cstring("*#/\"\t"), C.int(b_at(p, 0))) != nil {
		p = transmute(^u8)(skipwhite(transmute(cstring)(^u8)(uintptr(p) + 1)))
	}

	if b_at(p, 0) == 0 {
		return
	}

	n := C.int(uintptr(p) - uintptr(line)) + 1
	if n < maxlen - 1 {
		libc.memset(buf, ' ', C.size_t(n))
		libc.strncpy(([^]u8)(uintptr(buf) + uintptr(n)), transmute(cstring)(p), C.size_t(maxlen - n))
	}
}

clear_midword :: proc "c"(wp: rawptr) {
	sb := win_s_r(wp)
	libc.memset((^u8)(uintptr(sb) + SB_SPELL_ISMW_OFF), 0, 256)
	mb := (^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)
	xfree(mb^)
	mb^ = nil
}

use_midword :: proc "c"(lp: ^Slang_T, wp: rawptr) {
	if lp.sl_midword == nil {
		return
	}

	sb := win_s_r(wp)
	p := lp.sl_midword
	for b_at(p, 0) != 0 {
		c := utf_ptr2char(transmute(cstring)(p))
		l := utfc_ptr2len(transmute(cstring)(p))
		if c < 256 && l <= 2 {
			(^bool)(uintptr(sb) + SB_SPELL_ISMW_OFF + uintptr(c))^ = true
		} else if (^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^ == nil {
			(^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^ = xmemdupz_sp(p, C.size_t(l))
		} else {
			old := (^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^
			n := libc.strlen(transmute(cstring)(old))
			bp := xstrnsave_c(transmute(cstring)(old), C.size_t(n) + C.size_t(l))
			xfree(old)
			(^^u8)(uintptr(sb) + SB_SPELL_ISMW_MB_OFF)^ = bp
			xmemcpyz_sp((^u8)(uintptr(bp) + uintptr(n)), p, C.size_t(l))
		}
		p = (^u8)(uintptr(p) + uintptr(l))
	}
}

find_region :: proc "c"(rp: ^u8, region: ^u8) -> C.int {
	i := C.int(0)
	for true {
		if b_at(rp, i) == 0 {
			return REGION_ALL
		}
		if b_at(rp, i) == b_at(region, 0) && b_at(rp, i + 1) == b_at(region, 1) {
			break
		}
		i += 2
	}
	return i / 2
}

@(export)
spell_delete_wordlist :: proc "c"() {
	if int_wordlist == nil {
		return
	}

	fname: [MAXPATHL_S]u8
	mem_zero_sp(&fname[0], MAXPATHL_S)
	os_remove(transmute(cstring)(int_wordlist))
	int_wordlist_spl(&fname[0])
	os_remove(transmute(cstring)(&fname[0]))
	xfree(int_wordlist)
	int_wordlist = nil
}


// ── parse_spelllang ──────────────────────────────────────────────────────────

@(private="file")
parse_spell_recursive: bool = false

foreign _ {
	@(link_name = "path_full_compare")
	path_full_compare_sp :: proc "c" (s1: cstring, s2: cstring, checkname: bool, expand: bool) -> C.int ---
	@(link_name = "path_fnamecmp")
	path_fnamecmp_r :: proc "c" (s1: cstring, s2: cstring) -> C.int ---
	@(link_name = "redraw_later")
	redraw_later_sp :: proc "c" (wp: rawptr, typ: C.int) ---
}

UPD_NOT_VALID_SP :: 40

STRICMP_eq :: proc "c"(a, b: cstring) -> bool {
	return _strcasecmp(a, b) == 0
}

@(export)
parse_spelllang :: proc "c"(wp: rawptr) -> ^u8 {
	region_cp: [3]u8
	lang: [MAXWLEN + 1]u8
	spf_name: [MAXPATHL_S]u8
	use_region: ^u8 = nil
	dont_use_region := false
	nobreak := false
	ret_msg: cstring = nil

	sb := win_s_r(wp)
	bufref: [64]u8 // bufref_T is small; opaque storage
	mem_zero_sp(&bufref[0], 64)
	set_bufref((^Bufref_T)(&bufref[0]), buf_of_win(wp))

	if parse_spell_recursive {
		return nil
	}
	parse_spell_recursive = true

	ga: Garray
	ga_init_r(&ga, size_of(Langp_T), 2)
	clear_midword(wp)

	spl_copy := xstrdup_r(transmute(cstring)(sb_p_spl_r(sb)))

	(^bool)(uintptr(sb) + SB_CJK_OFF)^ = false

	splp := spl_copy
	for b_at(splp, 0) != 0 {
		len := C.int(copy_option_part(&splp, &lang[0], MAXWLEN, ","))
		region: ^u8 = nil

		if !valid_spelllang_c(&lang[0]) {
			continue
		}

		slang: ^Slang_T = nil
		filename := false
		if len > 4 && path_fnamecmp_r(transmute(cstring)(^u8)(uintptr(&lang[0]) + uintptr(len - 4)), ".spl") == 0 {
			filename = true

			// Locate a region and remove it from the file name.
			tailp := _vim_strchr(path_tail(transmute(cstring)(&lang[0])), '_')
			p := tailp == nil ? nil : transmute(^u8)(tailp)
			if p != nil && ascii_isalpha_sp(b_at(p, 1)) && ascii_isalpha_sp(b_at(p, 2)) &&
			!ascii_isalpha_sp(b_at(p, 3)) {
				b_set(&region_cp[0], 0, b_at(p, 1))
				b_set(&region_cp[0], 1, b_at(p, 2))
				b_set(&region_cp[0], 2, 0)
				libc.memmove(p, (^u8)(uintptr(p) + 3), C.size_t(len - C.int(uintptr(p)-uintptr(&lang[0])) - 2))
				region = &region_cp[0]
			} else {
				dont_use_region = true
			}

			for sl := (^Slang_T)(first_lang); sl != nil; sl = (^Slang_T)(sl.sl_next) {
				if path_full_compare_sp(transmute(cstring)(&lang[0]), transmute(cstring)(sl.sl_fname), false, true) == kEqualFiles_S {
					slang = sl
					break
				}
			}
		} else {
			if len > 3 && b_at(&lang[0], len - 3) == '_' {
				region = (^u8)(uintptr(&lang[0]) + uintptr(len - 2))
				b_set(&lang[0], len - 3, 0)
			} else {
				dont_use_region = true
			}

			for sl := (^Slang_T)(first_lang); sl != nil; sl = (^Slang_T)(sl.sl_next) {
				if STRICMP_eq(transmute(cstring)(&lang[0]), transmute(cstring)(sl.sl_name)) {
					slang = sl
					break
				}
			}
		}

		if region != nil {
			if use_region != nil && libc.strcmp(transmute(cstring)(region), transmute(cstring)(use_region)) != 0 {
				dont_use_region = true
			}
			use_region = region
		}

		// If not found try loading the language now.
		if slang == nil {
			if filename {
				spell_load_file_r(&lang[0], &lang[0], nil, false)
			} else {
				spell_load_lang(&lang[0])
				if !bufref_valid((^Bufref_T)(&bufref[0])) || !win_valid_any_tab(wp) {
					ret_msg = "E797: SpellFileMissing autocommand deleted buffer"
					break
				}
			}
		}

		// Loop over the languages; several files per "lang".
		for sl := (^Slang_T)(first_lang); sl != nil; sl = (^Slang_T)(sl.sl_next) {
			found: bool
			if filename {
				found = path_full_compare_sp(transmute(cstring)(&lang[0]), transmute(cstring)(sl.sl_fname), false, true) == kEqualFiles_S
			} else {
				found = STRICMP_eq(transmute(cstring)(&lang[0]), transmute(cstring)(sl.sl_name))
			}
			if found {
				region_mask: C.int = REGION_ALL
				if !filename && region != nil {
					c := find_region(&sl.sl_regions[0], region)
					if c == REGION_ALL {
						if sl.sl_add {
							if b_at(&sl.sl_regions[0], 0) != 0 {
								region_mask = 0
							}
						} else {
							semsg_sp(cstring("Warning: region %s not supported"), transmute(cstring)(region), cstring(""), cstring(""))
						}
					} else {
						region_mask = C.int(C.uint(1) << C.uint(c))
					}
				}

				if region_mask != 0 {
					if ga.ga_len >= ga.ga_maxlen {
						ga_grow_sp(&ga, 1)
					}
					p_ := langp_entry(&ga, ga.ga_len)
					ga.ga_len += 1
					p_.lp_slang = sl
					p_.lp_region = region_mask

					use_midword(sl, wp)
					if sl.sl_nobreak {
						nobreak = true
					}
				}
			}
		}
	}

	// round 0: int_wordlist; round 1+: entries in 'spellfile'.
	spf := sb_p_spf_r(sb)
	round := C.int(0)
	for ; round == 0 || b_at(spf, 0) != 0; round += 1 {
		if round == 0 {
			if int_wordlist == nil {
				continue
			}
			int_wordlist_spl(&spf_name[0])
		} else {
			len := C.int(copy_option_part(&spf, &spf_name[0], MAXPATHL_S - 4, ","))
			libc.strcpy(([^]u8)(uintptr(&spf_name[0]) + uintptr(len)), ".spl")

			c := C.int(0)
			for ; c < ga.ga_len; c += 1 {
				p := (^Langp_T)(uintptr(ga.ga_data) + uintptr(c) * size_of(Langp_T)).lp_slang
				fname := p == nil ? nil : (^Slang_T)(p).sl_fname
				if fname != nil &&
				path_full_compare_sp(transmute(cstring)(&spf_name[0]), transmute(cstring)(fname), false, true) == kEqualFiles_S {
					break
				}
			}
			if c < ga.ga_len {
				continue
			}
		}

		slang: ^Slang_T = nil

		for sl := (^Slang_T)(first_lang); sl != nil; sl = (^Slang_T)(sl.sl_next) {
			if path_full_compare_sp(transmute(cstring)(&spf_name[0]), transmute(cstring)(sl.sl_fname), false, true) == kEqualFiles_S {
				slang = sl
				break
			}
		}
		if slang == nil {
			if round == 0 {
				libc.strcpy(&lang[0], "internal wordlist")
			} else {
				libc.strncpy(&lang[0], path_tail(transmute(cstring)(&spf_name[0])), MAXWLEN + 1)
				pp := _vim_strchr(transmute(cstring)(&lang[0]), '.')
				if pp != nil {
					b_set(transmute(^u8)(pp), 0, 0)
				}
			}
			slang = (^Slang_T)(spell_load_file_r(&spf_name[0], &lang[0], nil, true))

			if slang != nil && nobreak {
				slang.sl_nobreak = true
			}
		}
		if slang != nil {
			region_mask: C.int = REGION_ALL
			if use_region != nil && !dont_use_region {
				c := find_region(&slang.sl_regions[0], use_region)
				if c != REGION_ALL {
					region_mask = C.int(C.uint(1) << C.uint(c))
				} else if b_at(&slang.sl_regions[0], 0) != 0 {
					region_mask = 0
				}
			}

			if region_mask != 0 {
				if ga.ga_len >= ga.ga_maxlen {
					ga_grow_sp(&ga, 1)
				}
				p_ := langp_entry(&ga, ga.ga_len)
				ga.ga_len += 1
				p_.lp_slang = slang
				p_.lp_sallang = nil
				p_.lp_replang = nil
				p_.lp_region = region_mask

				use_midword(slang, wp)
			}
		}
	}

	// Store the new b_langp value.
	ga_clear_r(sb_langp_r(sb))
	sb_langp_r(sb)^ = ga

	// Figure out sound folding and REP languages.
	for i := C.int(0); i < ga.ga_len; i += 1 {
		lp := langp_entry(&ga, i)
		lps := (^Slang_T)(lp.lp_slang)

		if lps.sl_sal.ga_len > 0 {
			lp.lp_sallang = lp.lp_slang
		} else {
			for j := C.int(0); j < ga.ga_len; j += 1 {
				lp2 := langp_entry(&ga, j)
				lps2 := (^Slang_T)(lp2.lp_slang)
				if lps2.sl_sal.ga_len > 0 &&
				libc.strncmp(transmute(cstring)(lps.sl_name), transmute(cstring)(lps2.sl_name), 2) == 0 {
					lp.lp_sallang = lp2.lp_slang
					break
				}
			}
		}

		if lps.sl_rep.ga_len > 0 {
			lp.lp_replang = lp.lp_slang
		} else {
			for j := C.int(0); j < ga.ga_len; j += 1 {
				lp2 := langp_entry(&ga, j)
				lps2 := (^Slang_T)(lp2.lp_slang)
				if lps2.sl_rep.ga_len > 0 &&
				libc.strncmp(transmute(cstring)(lps.sl_name), transmute(cstring)(lps2.sl_name), 2) == 0 {
					lp.lp_replang = lp2.lp_slang
					break
				}
			}
		}
	}
	redraw_later_sp(wp, UPD_NOT_VALID_SP)

	xfree(spl_copy)
	parse_spell_recursive = false
	return transmute(^u8)(ret_msg)
}

buf_of_win :: proc "c"(wp: rawptr) -> rawptr {
	return (^^rawptr)(uintptr(wp) + 8)^
}

SB_P_SPF_OFF :: 1104 // verify below

sb_p_spf_r :: proc "c"(sb: rawptr) -> ^u8 {
	return (^^u8)(uintptr(sb) + SB_P_SPF_OFF)^
}

valid_spelllang_c :: proc "c"(val: ^u8) -> bool {
	return valid_spelllang(transmute(cstring)(val))
}

ascii_isalpha_sp :: proc "c"(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

foreign _ {
}

@(export)
valid_spelllang :: proc "c"(val: cstring) -> bool {
	return valid_name(val, ".-_,@")
}

@(export)
valid_spellfile :: proc "c"(val: cstring) -> bool {
	spf_name: [MAXPATHL_S]u8
	spf := transmute(^u8)(val)
	for b_at(spf, 0) != 0 {
		l := copy_option_part((^^u8)(uintptr(&spf)), &spf_name[0], MAXPATHL_S, cstring(","))
		if l >= MAXPATHL_S - 4 || l < 4 ||
		libc.strcmp(transmute(cstring)((^u8)(uintptr(&spf_name[0]) + uintptr(l - 4))), cstring(".add")) != 0 {
			return false
		}
		s := (^u8)(&spf_name[0])
		for b_at(s, 0) != 0 {
			if !vim_is_fname_char_r(b_at(s, 0)) {
				return false
			}
			s = (^u8)(uintptr(s) + 1)
		}
	}
	return true
}

foreign _ {
	@(link_name = "os_path_exists")
	os_path_exists_sp :: proc "c" (fname: cstring) -> bool ---
}

// ── decor navigation + spell_move_to ─────────────────────────────────────────

DECOR_STATE_SIZE :: 328
DECOR_STATE_SPELL_OFF :: 320

foreign _ {
	// decor_state: typed mirror DecorState_O in drawline.odin (Batch 9).
	@(link_name = "concat_str")
	concat_str_r :: proc "c" (s1: cstring, s2: cstring) -> ^u8 ---
}

// decor_state address via the typed mirror (drawline.odin).
decor_state_buf_p :: proc "c"() -> ^u8 {
	return transmute(^u8)(&decor_state_g)
}

decor_spell_nav_col :: proc "c"(wp: rawptr, lnum: C.int, decor_lnum: ^C.int, col: C.int) -> C.int {
	if decor_lnum^ != lnum {
		decor_redraw_reset_r(wp, decor_state_buf_p())
		decor_providers_invoke_spell_r(wp, lnum - 1, col, lnum - 1, -1)
		decor_redraw_line_r(wp, lnum - 1, decor_state_buf_p())
		decor_lnum^ = lnum
	}
	decor_redraw_col_inline(wp, col, false, decor_state_buf_p(), MAXCOL)
	return (^C.int)(uintptr(decor_state_buf_p()) + DECOR_STATE_SPELL_OFF)^
}

can_syn_spell :: proc "c"(wp: rawptr, lnum: C.int, col: C.int) -> bool {
	can_spell := false
	syn_get_id_r(wp, lnum, col, false, &can_spell, false)
	return can_spell
}

// Moves to next spell error. Returns 0 if not found, else word length.
@(export)
spell_move_to :: proc "c"(wp: rawptr, dir: C.int, behaviour: C.int, curline: bool, attrp: ^C.int) -> C.size_t {
	if no_spell_checking(wp) {
		return 0
	}

	found_pos: Pos_T
	has_syntax := syntax_present_r(wp)
	found_len: C.size_t = 0
	attr: C.int = HLF_COUNT
	buf: ^u8 = nil
	buflen: C.size_t = 0
	skip := C.int(0)
	capcol := C.int(-1)
	found_one := false
	wrapped := false

	ret: C.size_t = 0

	lnum := win_cursor_r(wp)^.lnum
	// clearpos(&found_pos)
	found_pos = Pos_T{}

	// Save and reset the global DecorState.
	saved_decor_start: [DECOR_STATE_SIZE]u8
	libc.memcpy(&saved_decor_start[0], decor_state_buf_p(), DECOR_STATE_SIZE)
	libc.memset(decor_state_buf_p(), 0, DECOR_STATE_SIZE)
	decor_lnum := C.int(-1)

	theend_break := false
	for !got_int {
		line := ml_get_buf(buf_of_win(wp), lnum)

		len := C.size_t(ml_get_buf_len(buf_of_win(wp), lnum))
		if buflen < len + MAXWLEN + 2 {
			xfree(buf)
			buflen = len + MAXWLEN + 2
			buf = (^u8)(xmalloc_sp(buflen))
		}

		if lnum == 1 {
			capcol = 0
		}

		if capcol == 0 {
			capcol = getwhitecols_r(transmute(cstring)(line))
		} else if curline && wp == curwin {
			col := getwhitecols_r(transmute(cstring)(line))
			if check_need_cap(curwin, lnum, col) {
				capcol = col
			}
			line = ml_get_buf(buf_of_win(wp), lnum)
		}

		empty_line := b_at(transmute(^u8)(skipwhite(transmute(cstring)(line))), 0) == 0
		libc.strcpy(buf, transmute(cstring)(line))
		if lnum < buf_ml_line_count_r(buf_of_win(wp)) {
			spell_cat_line((^u8)(uintptr(buf) + uintptr(libc.strlen(transmute(cstring)(buf)))),
				ml_get_buf(buf_of_win(wp), lnum + 1), MAXWLEN)
		}
		p := (^u8)(uintptr(buf) + uintptr(skip))
		endp := (^u8)(uintptr(buf) + uintptr(len))
		for uintptr(p) < uintptr(endp) {
			// When searching backward don't search after the cursor.
			if dir == C.int(Direction.BACKWARD) &&
			lnum == win_cursor_r(wp)^.lnum &&
			!wrapped &&
			C.int(uintptr(p) - uintptr(buf)) >= win_cursor_r(wp)^.col {
				break
			}

			attr = HLF_COUNT
			len = spell_check(wp, p, &attr, &capcol, false)

			if attr != HLF_COUNT {
				if behaviour == SMT_ALL ||
				(behaviour == SMT_BAD && attr == HLF_SPB) ||
				(behaviour == SMT_RARE && attr == HLF_SPR) {
					// Forward: only accept bad word after the cursor.
					accept := dir == C.int(Direction.BACKWARD) ||
					lnum != win_cursor_r(wp)^.lnum || wrapped ||
					(C.int(uintptr(p) - uintptr(buf)) +
					(curline ? C.int(len) : 0) > win_cursor_r(wp)^.col)
					if accept {
						col2 := C.int(uintptr(p) - uintptr(buf))

						no_plain_buffer := (sb_p_spo_flags_r(win_s_r(wp)) & kOptSpoFlagNoplainbuffer) != 0
						can_spell := !no_plain_buffer
						dv := decor_spell_nav_col(wp, lnum, &decor_lnum, col2)
						switch dv {
						case 1: // kTrue
							can_spell = true
						case 0: // kFalse
							can_spell = false
						case: // kNone (-1)
							if has_syntax {
								can_spell = can_syn_spell(wp, lnum, col2)
							}
						}

						if !can_spell {
							attr = HLF_COUNT
						}

						if can_spell {
							found_one = true
							found_pos = Pos_T{lnum, col2, 0}
							if dir == C.int(Direction.FORWARD) {
								win_cursor_r(wp)^ = found_pos
								if attrp != nil {
									attrp^ = attr
								}
								ret = len
								theend_break = true
								break
							} else if curline {
								found_pos.col += C.int(len)
							}
							found_len = len
						}
					} else {
						found_one = true
					}
				}
			}

			p = (^u8)(uintptr(p) + uintptr(len))
			capcol -= C.int(len)
		}

		if theend_break {
			break
		}

		if dir == C.int(Direction.BACKWARD) && found_pos.lnum != 0 {
			win_cursor_r(wp)^ = found_pos
			ret = found_len
			break
		}

		if curline {
			break
		}

		if lnum == win_cursor_r(wp)^.lnum && wrapped {
			break
		}

		if dir == C.int(Direction.BACKWARD) {
			if lnum > 1 {
				lnum -= 1
			} else if p_ws_g == 0 {
				break
			} else {
				lnum = buf_ml_line_count_r(buf_of_win(wp))
				wrapped = true
				if !shortmess(SHM_SEARCH) {
					give_warning_s(cstring("search hit BOTTOM, continuing at TOP"), true, false)
				}
			}
			capcol = -1
		} else {
			if lnum < buf_ml_line_count_r(buf_of_win(wp)) {
				lnum += 1
			} else if p_ws_g == 0 {
				break
			} else {
				lnum = 1
				wrapped = true
				if !shortmess(SHM_SEARCH) {
					give_warning_s(cstring("search hit TOP, continuing at BOTTOM"), true, false)
				}
			}

			if lnum == win_cursor_r(wp)^.lnum && !found_one {
				break
			}

			if attr == HLF_COUNT {
				skip = C.int(uintptr(p) - uintptr(endp))
			} else {
				skip = 0
			}

			capcol -= 1

			if empty_line {
				capcol = 0
			}
		}

		line_breakcheck()
	}

	decor_state_free_r(decor_state_buf_p())
	libc.memcpy(decor_state_buf_p(), &saved_decor_start[0], DECOR_STATE_SIZE)
	xfree(buf)
	return ret
}

// Check if word at line/col must start with a capital ('spellcapcheck').
@(export)
check_need_cap :: proc "c"(wp: rawptr, lnum: C.int, col: C.int) -> bool {
	sb := win_s_r(wp)
	if sb_cap_prog_r(sb) == nil {
		return false
	}

	need_cap := false
	line: ^u8 = col != 0 ? ml_get_buf(buf_of_win(wp), lnum) : nil
	line_copy: ^u8 = nil
	endcol := C.int(0)
	if col == 0 || getwhitecols_r(transmute(cstring)(line)) >= col {
		if lnum == 1 {
			need_cap = true
		} else {
			line = ml_get_buf(buf_of_win(wp), lnum - 1)
			if b_at(transmute(^u8)(skipwhite(transmute(cstring)(line))), 0) == 0 {
				need_cap = true
			} else {
				// Append a space in place of the line break.
				line_copy = concat_str_r(transmute(cstring)(line), " ")
				line = line_copy
				endcol = C.int(libc.strlen(transmute(cstring)(line)))
			}
		}
	} else {
		endcol = col
	}

	if endcol > 0 {
		regmatch: Regmatch_T
		regmatch.regprog = sb_cap_prog_r(sb)
		regmatch.rm_ic = 0

		p := (^u8)(uintptr(line) + uintptr(endcol))
		for true {
			p = mb_ptr_back(line, p)
			if p == line || spell_iswordp_nmw(p, wp) {
				break
			}
			if vim_regexec_r(&regmatch, p, 0) != 0 &&
			uintptr(regmatch.endp[0]) == uintptr(line) + uintptr(endcol) {
				need_cap = true
				break
			}
		}
		sb_cap_prog_set(sb, regmatch.regprog)
	}

	xfree(line_copy)

	return need_cap
}

foreign _ {
	@(link_name = "sub_nsubs")
	sub_nsubs_sp: C.int
	// (C ints, NOT longlong: C's strong 4B symbols win the link and the two
	// globals are adjacent — 8B accesses straddle both (Batch-38 lesson).)
	@(link_name = "sub_nlines")
	sub_nlines_sp: C.int
	@(link_name = "ml_replace")
	ml_replace_sp :: proc "c" (lnum: C.int, line: ^u8, copy: bool) -> C.int ---
	@(link_name = "inserted_bytes")
	inserted_bytes_r :: proc "c" (lnum: C.int, col: C.int, oldlen: C.int, newlen: C.int) ---
	// do_sub_msg now defined in ex_cmds.odin — call directly.
}

@(export)
ex_spellrepall :: proc "c"(eap: rawptr) {
	pos := win_cursor_r(curwin)^
	save_ws := p_ws_g
	prev_lnum := C.int(0)

	if repl_from == nil || repl_to == nil {
		emsg(cstring("E752: No previous spell replacement"))
		return
	}
	repl_from_len := libc.strlen(transmute(cstring)(repl_from))
	repl_to_len := libc.strlen(transmute(cstring)(repl_to))
	addlen := C.longlong(repl_to_len) - C.longlong(repl_from_len)

	frompatsize := repl_from_len + 7
	frompat := (^u8)(xmalloc_sp(frompatsize))
	libc.snprintf(frompat, frompatsize, "\\V\\<%s\\>", transmute(cstring)(repl_from))
	p_ws_g = 0

	sub_nsubs_sp = 0
	sub_nlines_sp = 0
	win_cursor_r(curwin)^.lnum = 0
	for !got_int {
		if do_search(nil, '/', '/', frompat, libc.strlen(transmute(cstring)(frompat)), 1, SEARCH_KEEP, nil) == 0 ||
		u_save_cursor() == 0 {
			break
		}

		line := get_cursor_line_ptr_r()
		if addlen <= 0 ||
		libc.strncmp(transmute(cstring)(^u8)(uintptr(line) + uintptr(win_cursor_r(curwin)^.col)),
			transmute(cstring)(repl_to), repl_to_len) != 0 {
			p := (^u8)(xmalloc_sp(C.size_t(get_cursor_line_len_r() + C.int(addlen)) + 1))
			libc.memmove(p, line, C.size_t(win_cursor_r(curwin)^.col))
			libc.strcpy(([^]u8)(uintptr(p) + uintptr(win_cursor_r(curwin)^.col)), transmute(cstring)(repl_to))
			libc.strcat(p, transmute(cstring)(^u8)(uintptr(line) + uintptr(win_cursor_r(curwin)^.col + C.int(repl_from_len))))
			_ = ml_replace_sp(win_cursor_r(curwin)^.lnum, p, false)
			inserted_bytes_r(win_cursor_r(curwin)^.lnum, win_cursor_r(curwin)^.col,
				C.int(repl_from_len), C.int(repl_to_len))

			if win_cursor_r(curwin)^.lnum != prev_lnum {
				sub_nlines_sp += 1
				prev_lnum = win_cursor_r(curwin)^.lnum
			}
			sub_nsubs_sp += 1
		}
		win_cursor_r(curwin)^.col += C.int(repl_to_len)
	}

	p_ws_g = save_ws
	win_cursor_r(curwin)^ = pos
	xfree(frompat)

	if sub_nsubs_sp == 0 {
		semsg_one(cstring("E753: Not found: %s"), transmute(cstring)(repl_from))
	} else {
		_ = do_sub_msg(false)
	}
}



semsg_one :: proc "c"(fmt: cstring, a: cstring) {
	tmp: [1024]u8
	libc.snprintf(&tmp[0], 1024, fmt, a)
	emsg(transmute(cstring)(&tmp[0]))
}

// Make a copy of "word" with the first letter upper/lower cased.
@(export)
onecap_copy :: proc "c"(word: ^u8, wcopy: ^u8, upper: bool) {
	p := word
	c := mb_ptr2char_adv(&p)
	if upper {
		c = spell_toupper(c)
	} else {
		c = spell_tofold(c)
	}
	l := utf_char2bytes_r(c, wcopy)
	libc.strncpy(([^]u8)(uintptr(wcopy) + uintptr(l)), transmute(cstring)(p), C.size_t(MAXWLEN - l))
}

// Make a copy of "word" with all letters upper cased.
@(export)
allcap_copy :: proc "c"(word: ^u8, wcopy: ^u8) {
	d := wcopy
	s := word
	for b_at(s, 0) != 0 {
		c := mb_ptr2char_adv(&s)

		if c == 0xdf { // ß → SS
			c = 'S'
			if uintptr(d) - uintptr(wcopy) >= MAXWLEN - 1 {
				break
			}
			b_set(d, 0, u8(c))
			d = (^u8)(uintptr(d) + 1)
		} else {
			c = spell_toupper(c)
		}

		if uintptr(d) - uintptr(wcopy) >= MAXWLEN - 6 { // MB_MAXBYTES
			break
		}
		n := utf_char2bytes_r(c, d)
		d = (^u8)(uintptr(d) + uintptr(n))
	}
	b_set(d, 0, 0)
}

@(export)
make_case_word :: proc "c"(fword: ^u8, cword: ^u8, flags: C.int) {
	if (flags & WF_ALLCAP) != 0 {
		allcap_copy(fword, cword)
	} else if (flags & WF_ONECAP) != 0 {
		onecap_copy(fword, cword, true)
	} else {
		libc.strcpy(cword, transmute(cstring)(fword))
	}
}

// ── soundfold family ─────────────────────────────────────────────────────────

@(export)
eval_soundfold :: proc "c"(word: cstring) -> ^u8 {
	if w_p_spell_r(curwin) != 0 && b_at(sb_p_spl_r(win_s_r(curwin)), 0) != 0 {
		langp := sb_langp_r(win_s_r(curwin))
		for lpi := C.int(0); lpi < langp.ga_len; lpi += 1 {
			lp := langp_entry(langp, lpi)
			if (^Slang_T)(lp.lp_slang).sl_sal.ga_len > 0 {
				sound: [MAXWLEN]u8
				spell_soundfold((^Slang_T)(lp.lp_slang), transmute(^u8)(word), false, &sound[0])
				return xstrdup_r(transmute(cstring)(&sound[0]))
			}
		}
	}
	return xstrdup_r(word)
}

// Turn "inword" into its sound-a-like equivalent in "res[MAXWLEN]".
@(export)
spell_soundfold :: proc "c"(slang: ^Slang_T, inword: ^u8, folded: bool, res: ^u8) {
	if slang.sl_sofo {
		spell_soundfold_sofo(slang, inword, res)
	} else {
		fword: [MAXWLEN]u8
		word: ^u8
		if folded {
			word = inword
		} else {
			spell_casefold(curwin, inword, C.int(libc.strlen(transmute(cstring)(inword))), &fword[0], MAXWLEN)
			word = &fword[0]
		}
		spell_soundfold_wsal(slang, word, res)
	}
}

// SOFOFROM/SOFOTO character mapping.
spell_soundfold_sofo :: proc "c"(slang: ^Slang_T, inword: ^u8, res: ^u8) {
	ri := C.int(0)
	prevc := C.int(0)

	s := inword
	for b_at(s, 0) != 0 {
		c := mb_ptr2char_adv(&s)
		if utf_class_r(c) == 0 {
			c = ' '
		} else if c < 256 {
			c = C.int(slang.sl_sal_first[c])
		} else {
			ip := (^C.int)(([^]^C.int)(slang.sl_sal.ga_data)[c & 0xff])
			if ip == nil {
				c = 0
			} else {
				for true {
					if ip^ == 0 { // not found
						c = 0
						break
					}
					if ip^ == c { // match!
						c = ([^]C.int)(ip)[1]
						break
					}
					ip = (^C.int)(uintptr(ip) + 2 * size_of(C.int))
				}
			}
		}

		if c != 0 && c != prevc {
			ri += utf_char2bytes_r(c, (^u8)(uintptr(res) + uintptr(ri)))
			if ri + 6 > MAXWLEN {
				break
			}
			prevc = c
		}
	}

	b_set(res, ri, 0)
}

// SAL-items sound folding (Aspell phonet.cpp algorithm, multibyte).
spell_soundfold_wsal :: proc "c"(slang: ^Slang_T, inword: ^u8, res: ^u8) {
	word: [MAXWLEN]C.int
	wres: [MAXWLEN]C.int
	libc.memset(&word[0], 0, MAXWLEN * size_of(C.int))
	did_white := false

	// Convert to wide chars; remove accents/non-word chars if wanted.
	wordlen := C.int(0)
	s := inword
	for b_at(s, 0) != 0 {
		t := s
		c := mb_ptr2char_adv(&s)
		if slang.sl_rem_accents {
			if utf_class_r(c) == 0 {
				if did_white {
					continue
				}
				c = ' '
				did_white = true
			} else {
				did_white = false
				if !spell_iswordp_nmw(t, curwin) {
					continue
				}
			}
		}
		word[wordlen] = c
		wordlen += 1
	}
	word[wordlen] = 0

	smp := (^Salitem_T)(slang.sl_sal.ga_data)
	libc.memset(&wres[0], 0, MAXWLEN * size_of(C.int))
	k := C.int(0)
	p0 := C.int(-333)
	reslen := C.int(0)
	z := C.int(0)

	i := C.int(0)
	for word[i] != 0 {
		c := word[i]
		n := slang.sl_sal_first[c & 0xff]
		z0 := C.int(0)

		if n >= 0 {
			ws: ^C.int
			pf: ^C.int
			done := false
			for true {
				ws = sal_at(smp, n).sm_lead_w
				if (ws^ & 0xff) != (c & 0xff) || ws^ == 0 {
					break
				}
				// Quickly skip entries that don't match the word.
				if c != ws^ {
					n += 1
					continue
				}
				k = sal_at(smp, n).sm_leadlen
				if k > 1 {
					if word[i + 1] != int_at(ws, 1) {
						n += 1
						continue
					}
					if k > 2 {
						j := C.int(2)
						for ; j < k; j += 1 {
							if word[i + j] != int_at(ws, j) {
								break
							}
						}
						if j < k {
							n += 1
							continue
						}
					}
				}

				pf = sal_at(smp, n).sm_oneof_w
				if pf != nil {
					// Match with one of the chars in "sm_oneof".
					for pf^ != 0 && pf^ != word[i + k] {
						pf = (^C.int)(uintptr(pf) + size_of(C.int))
					}
					if pf^ == 0 {
						n += 1
						continue
					}
					k += 1
				}
				sb := sal_at(smp, n).sm_rules
				pri := C.int(5) // default priority

				p0 = C.int(b_at(sb, 0))
				k0 := k
				for b_at(sb, 0) == '-' && k > 1 {
					k -= 1
					sb = (^u8)(uintptr(sb) + 1)
				}
				if b_at(sb, 0) == '<' {
					sb = (^u8)(uintptr(sb) + 1)
				}
				if b_at(sb, 0) >= '0' && b_at(sb, 0) <= '9' {
					pri = C.int(b_at(sb, 0)) - '0'
					sb = (^u8)(uintptr(sb) + 1)
				}
				if b_at(sb, 0) == '^' && b_at(sb, 1) == '^' {
					sb = (^u8)(uintptr(sb) + 1)
				}

				// NOTE: C precedence: (A || B) && (C || D) && (E || F) — fully
				// parenthesized because Odin mixes && / || left-assoc.
				head_ok := false
				if b_at(sb, 0) == 0 {
					head_ok = true
				} else if b_at(sb, 0) == '^' {
					ok1 := i == 0 || !(word[i - 1] == ' ' ||
					wsal_iswordp(&word[0], i - 1, curwin, "m1"))
					ok2 := b_at(sb, 1) != '$' ||
					!wsal_iswordp(&word[0], i + k0, curwin, "p2")
					head_ok = ok1 && ok2
				} else if b_at(sb, 0) == '$' && i > 0 {
					head_ok = wsal_iswordp(&word[0], i - 1, curwin, "m1") &&
					!wsal_iswordp(&word[0], i + k0, curwin, "p2")
				}

				if head_ok {
					// search for followup rules, if: followup and k > 1 and
					// NO '-' in searchstring
					c0 := word[i + k - 1]
					n0 := slang.sl_sal_first[c0 & 0xff]

					if slang.sl_followup && k > 1 && n0 >= 0 &&
					p0 != '-' && word[i + k] != 0 {
						// Test follow-up rule for "word[i + k]".
						for true {
							ws = sal_at(smp, n0).sm_lead_w
							if (ws^ & 0xff) != (c0 & 0xff) {
								break
							}
							if c0 != ws^ {
								n0 += 1
								continue
							}
							k0 = sal_at(smp, n0).sm_leadlen
							if k0 > 1 {
								if word[i + k] != int_at(ws, 1) {
									n0 += 1
									continue
								}
								if k0 > 2 {
									pfw := (^C.int)(uintptr(&word[0]) + uintptr(i + k + 1))
									j := C.int(2)
									for ; j < k0; j += 1 {
										if pfw^ != int_at(ws, j) {
											break
										}
										pfw = (^C.int)(uintptr(pfw) + size_of(C.int))
									}
									if j < k0 {
										n0 += 1
										continue
									}
								}
							}
							k0 += k - 1

							pf = sal_at(smp, n0).sm_oneof_w
							if pf != nil {
								for pf^ != 0 && pf^ != word[i + k0] {
									pf = (^C.int)(uintptr(pf) + size_of(C.int))
								}
								if pf^ == 0 {
									n0 += 1
									continue
								}
								k0 += 1
							}

							p0 = 5
							sb3 := sal_at(smp, n0).sm_rules
							for b_at(sb3, 0) == '-' {
								// "k0" gets NOT reduced because "if (k0 == k)"
								sb3 = (^u8)(uintptr(sb3) + 1)
							}
							if b_at(sb3, 0) == '<' {
								sb3 = (^u8)(uintptr(sb3) + 1)
							}
							if b_at(sb3, 0) >= '0' && b_at(sb3, 0) <= '9' {
								p0 = C.int(b_at(sb3, 0)) - '0'
								sb3 = (^u8)(uintptr(sb3) + 1)
							}

							if b_at(sb3, 0) == 0 ||
							(b_at(sb3, 0) == '$' &&
							!wsal_iswordp(&word[0], i + k0, curwin, "p2")) {
								if k0 == k {
									// just a piece of the string
									n0 += 1
									continue
								}
								if p0 < pri {
									// priority too low
									n0 += 1
									continue
								}
								// rule fits; stop search
								break
							}
							n0 += 1
						}
					}

					if p0 >= pri && (sal_at(smp, n0).sm_lead_w^ & 0xff) == (c0 & 0xff) {
						n += 1
						continue
					}

					// replace string
					ws = sal_at(smp, n).sm_to_w
					sb4 := sal_at(smp, n).sm_rules
					p0 = _vim_strchr(transmute(cstring)(sb4), '<') != nil ? 1 : 0
					if p0 == 1 && z == 0 {
						// rule with '<' is used
						if reslen > 0 && ws != nil && ws^ != 0 &&
						(wres[reslen - 1] == c || wres[reslen - 1] == ws^) {
							reslen -= 1
						}
						z0 = 1
						z = 1
						k0 = 0
						if ws != nil {
							for ws^ != 0 && word[i + k0] != 0 {
								word[i + k0] = ws^
								k0 += 1
								ws = (^C.int)(uintptr(ws) + size_of(C.int))
							}
						}
						if k > k0 {
							libc.memmove((^u8)(uintptr(&word[0]) + uintptr(i + k0)),
								 (^u8)(uintptr(&word[0]) + uintptr(i + k)),
								C.size_t(wordlen - (i + k) + 1) * size_of(C.int))
						}
						// new "actual letter"
						c = word[i]
					} else {
						// no '<' rule used
						i += k - 1
						z = 0
						if ws != nil {
							for ws^ != 0 && int_at(ws, 1) != 0 && reslen < MAXWLEN {
								if reslen == 0 || wres[reslen - 1] != ws^ {
									wres[reslen] = ws^
									reslen += 1
								}
								ws = (^C.int)(uintptr(ws) + size_of(C.int))
							}
						}
						if ws == nil {
							c = 0
						} else {
							c = ws^
						}
						if strstr_c(transmute(cstring)(sb4), "^^") != nil {
							if c != 0 && reslen < MAXWLEN {
								wres[reslen] = c
								reslen += 1
							}
							libc.memmove(&word[0],
								 (^u8)(uintptr(&word[0]) + uintptr(i + 1)),
								C.size_t(wordlen - (i + 1) + 1) * size_of(C.int))
							i = 0
							z0 = 1
						}
					}
					done = true
				}
				break
			}
			if done {
				// fall through to z0 handling below
			}
		} else if c == ' ' || (c >= 0x09 && c <= 0x0d) { // ascii_iswhite
			c = ' '
			k = 1
		}

		if z0 == 0 {
			if k != 0 && p0 == 0 && reslen < MAXWLEN && c != 0 &&
			(!slang.sl_collapse || reslen == 0 || wres[reslen - 1] != c) {
				// condense only double letters
				wres[reslen] = c
				reslen += 1
			}

			i += 1
			z = 0
			k = 0
		}
	}

	// Convert wide chars in "wres" to a multi-byte string in "res".
	l := C.int(0)
	for nn := C.int(0); nn < reslen; nn += 1 {
		l += utf_char2bytes_r(wres[nn], (^u8)(uintptr(res) + uintptr(l)))
		if l + 6 > MAXWLEN {
			break
		}
	}
	b_set(res, l, 0)
}


sal_at :: proc "c" (smp: ^Salitem_T, n: C.int) -> ^Salitem_T {
	return (^Salitem_T)(uintptr(smp) + uintptr(n) * size_of(Salitem_T))
}

// ── chartab + reload/free ────────────────────────────────────────────────────

@(export)
clear_spell_chartab :: proc "c"(sp: ^Spelltab_T) {
	libc.memset(&sp.st_isw[0], 0, 256)
	libc.memset(&sp.st_isu[0], 0, 256)

	for i := C.int(0); i < 256; i += 1 {
		sp.st_fold[i] = u8(i)
		sp.st_upper[i] = u8(i)
	}

	for i := C.int('0'); i <= '9'; i += 1 {
		sp.st_isw[i] = true
	}
	for i := C.int('A'); i <= 'Z'; i += 1 {
		sp.st_isw[i] = true
		sp.st_isu[i] = true
		sp.st_fold[i] = u8(i + 0x20)
	}
	for i := C.int('a'); i <= 'z'; i += 1 {
		sp.st_isw[i] = true
		sp.st_upper[i] = u8(i - 0x20)
	}
}

@(export)
init_spell_chartab :: proc "c"() {
	st := (^Spelltab_T)(&spelltab[0])
	did_set_spelltab = false
	clear_spell_chartab(st)
	for i := C.int(128); i < 256; i += 1 {
		f := utf_fold_r(i)
		u := mb_toupper_r(i)

		st.st_isu[i] = mb_isupper_r(i)
		st.st_isw[i] = st.st_isu[i] || mb_islower_r2(i)
		st.st_fold[i] = f < 256 ? u8(f) : u8(i)
		st.st_upper[i] = u < 256 ? u8(u) : u8(i)
	}
}

foreign _ {
	@(link_name = "mb_islower")
	mb_islower_r2 :: proc "c" (a: C.int) -> bool ---
	@(link_name = "hash_find")
	hash_find_r :: proc "c" (ht: rawptr, key: cstring) -> rawptr ---
}

// iterate all buffers via b_next @120
@(export)
spell_free_all :: proc "c"() {
	buf := firstbuf
	for buf != nil {
		ga_clear_r((^Garray)(uintptr(buf) + 11264 + SB_LANGP_OFF)) // buf_T.b_s embedded, .b_langp @+800
		buf = (^rawptr)(uintptr(buf) + B_NEXT_OFF)^
	}

	for first_lang != nil {
		slang := (^Slang_T)(first_lang)
		first_lang = slang.sl_next
		slang_free(slang)
	}

	spell_delete_wordlist()

	if repl_to != nil {
		xfree(repl_to)
		repl_to = nil
	}
	if repl_from != nil {
		xfree(repl_from)
		repl_from = nil
	}
}

B_NEXT_OFF :: 120

buf_of_buf :: proc "c"(b: rawptr) -> rawptr {
	return (^rawptr)(uintptr(b) + 11264)^ // buf_T.b_s @11264
}

@(export)
spell_reload :: proc "c"() {
	init_spell_chartab()
	spell_free_all()

	// FOR_ALL_WINDOWS_IN_TAB: walk tabpage->tp_firstwin, win->w_next
	tp := curtab
	if tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^ // tabpage_T.tp_firstwin @40
		for wp != nil {
			if b_at(sb_p_spl_r(win_s_r(wp)), 0) != 0 {
				if w_p_spell_r(wp) != 0 {
					parse_spelllang(wp)
					break
				}
			}
			wp = (^rawptr)(uintptr(wp) + 112)^ // win_T.w_next @112
		}
	}
}

foreign _ {
	@(link_name = "ml_open_file")
	ml_open_file_sp :: proc "c" (buf: rawptr) ---
}

@(export)
open_spellbuf :: proc "c"() -> rawptr {
	buf := xcalloc_sp(1, 12760) // sizeof(buf_T)

	(^bool)(uintptr(buf) + 11171)^ = true // b_spell
	(^C.int)(uintptr(buf) + 10672)^ = 1 // b_p_swf
	ml_open_sp(buf)
	ml_open_file_sp(buf)

	return buf
}

foreign _ {
	@(link_name = "ml_open")
	ml_open_sp :: proc "c" (buf: rawptr) -> C.int ---
}

@(export)
close_spellbuf :: proc "c"(buf: rawptr) {
	if buf == nil {
		return
	}
	ml_close_sp(buf, true)
	xfree(buf)
}

foreign _ {
	@(link_name = "ml_close")
	ml_close_sp :: proc "c" (buf: rawptr, del_file: bool) ---
}

// ── did_set_spell_option / compile_cap_prog ─────────────────────────────────

@(export)
did_set_spell_option :: proc "c"() -> cstring {
	errmsg: cstring = nil

	// FOR_ALL_WINDOWS_IN_TAB(curtab): first window with curbuf and 'spell'
	tp := curtab
	if tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^
		for wp != nil {
			if buf_of_win(wp) == curbuf && w_p_spell_r(wp) != 0 {
				errmsg = transmute(cstring)(parse_spelllang(wp))
				break
			}
			wp = (^rawptr)(uintptr(wp) + 112)^
		}
	}
	return errmsg
}

SB_P_SPC_OFF :: 1088 // verify below

@(export)
compile_cap_prog :: proc "c"(synblock: rawptr) -> cstring {
	rp := sb_cap_prog_r(synblock)
	spc := (^^u8)(uintptr(synblock) + SB_P_SPC_OFF)^

	if spc == nil || b_at(spc, 0) == 0 {
		sb_cap_prog_set(synblock, nil)
	} else {
		// Prepend ^ so we only match at one column
		re := concat_str_r("^", transmute(cstring)(spc))
		sb_cap_prog_set(synblock, vim_regcomp(transmute(cstring)(re), RE_MAGIC))
		xfree(re)
		if sb_cap_prog_r(synblock) == nil {
			sb_cap_prog_set(synblock, rp) // restore previous program
			return cstring("E474: Invalid argument")
		}
	}

	vim_regfree(rp)
	return nil
}

// ── dump family (:spelldump, insert-mode completion) ─────────────────────────

DUMPFLAG_KEEPCASE :: 1
DUMPFLAG_COUNT :: 2
DUMPFLAG_ICASE :: 4
DUMPFLAG_ONECAP :: 8
DUMPFLAG_ALLCAP :: 16

foreign _ {
	@(link_name = "vim_is_fname_char")
	vim_is_fname_char_r :: proc "c" (c: u8) -> bool ---
}

// :spellinfo
@(export)
ex_spellinfo :: proc "c"(eap: rawptr) {
	if no_spell_checking(curwin) {
		return
	}

	msg_ext_set_kind(cstring("list_cmd"))
	msg_start()
	langp := sb_langp_r(win_s_r(curwin))
	for lpi := C.int(0); lpi < langp.ga_len && !got_int; lpi += 1 {
		lp := langp_entry(langp, lpi)
		slang := (^Slang_T)(lp.lp_slang)
		msg_puts_s(cstring("file: "))
		msg_puts_s(transmute(cstring)(slang.sl_fname))
		p := slang.sl_info
		if lpi < langp.ga_len || p != nil {
			msg_putchar('\n')
		}
		if p != nil {
			msg_puts_s(transmute(cstring)(p))
			if lpi < langp.ga_len - 1 {
				msg_putchar('\n')
			}
		}
	}
	_ = msg_end()
}

// Dumps one word; applies case mods and appends a line (or adds completion).
dump_word :: proc "c"(
	slang: ^Slang_T,
	word: ^u8,
	pat: ^u8,
	dir: ^Direction,
	dumpflags: C.int,
	wordflags: C.int,
	lnum: C.int,
) {
	keepcap := false
	cword: [MAXWLEN]u8
	badword: [MAXWLEN + 10]u8
	flags := wordflags

	if (dumpflags & DUMPFLAG_ONECAP) != 0 {
		flags |= WF_ONECAP
	}
	if (dumpflags & DUMPFLAG_ALLCAP) != 0 {
		flags |= WF_ALLCAP
	}

	if (dumpflags & DUMPFLAG_KEEPCASE) == 0 && (flags & WF_CAPMASK) != 0 {
		make_case_word(word, &cword[0], flags)
		tw := &cword[0]
		if dump_word_tail(slang, tw, pat, dir, dumpflags, flags, lnum, keepcap) {
			return
		}
		return
	}
	tw := word
	if (dumpflags & DUMPFLAG_KEEPCASE) != 0 &&
	((captype(word, nil) & WF_KEEPCAP) == 0 || (flags & WF_FIXCAP) != 0) {
		keepcap = true
	}
	if dump_word_tail(slang, tw, pat, dir, dumpflags, flags, lnum, keepcap) {
		return
	}
}

// shared tail of dump_word (kept separate for clarity)
dump_word_tail :: proc "c"(
	slang: ^Slang_T,
	tw: ^u8,
	pat: ^u8,
	dir: ^Direction,
	dumpflags: C.int,
	flags: C.int,
	lnum: C.int,
	keepcap: bool,
) -> bool {
	p := tw
	if pat == nil {
		// Add flags and regions after a slash.
		if ((flags & (WF_BANNED | WF_RARE | WF_REGION)) != 0) || keepcap {
			libc.strcpy(&badword_buf[0], transmute(cstring)(tw))
			libc.strcat(&badword_buf[0], "/")
			if keepcap {
				libc.strcat(&badword_buf[0], "=")
			}
			if (flags & WF_BANNED) != 0 {
				libc.strcat(&badword_buf[0], "!")
			} else if (flags & WF_RARE) != 0 {
				libc.strcat(&badword_buf[0], "?")
			}
			if (flags & WF_REGION) != 0 {
				for i := C.int(0); i < 7; i += 1 {
					if (C.uint(flags) & (C.uint(0x10000) << C.uint(i))) != 0 {
						blen := libc.strlen(transmute(cstring)(&badword_buf[0]))
						tmpn: [16]u8
						libc.snprintf(&tmpn[0], 16, "%d", i + 1)
						libc.strcat(&badword_buf[0], transmute(cstring)(&tmpn[0]))
					}
				}
			}
			p = &badword_buf[0]
		}

		if (dumpflags & DUMPFLAG_COUNT) != 0 {
			hi := hash_find_r(&(^Slang_T)(slang).sl_wordcount_buf[0], transmute(cstring)(tw))
			hk := hi == nil ? nil : (^rawptr)(uintptr(hi) + 8)^
			if hk != nil && hk != transmute(rawptr)(&hash_removed_c) {
				wc := (^Wordcount_T_alloc)(uintptr(hk) - WC_KEY_OFF)
				tmpb: [1025]u8
				libc.snprintf(&tmpb[0], 1025, "%s\t%d", transmute(cstring)(tw), C.int(wc.wc_count))
				_ = ml_append(lnum, &tmpb[0], 0, false)
				return false
			}
		}

		_ = ml_append(lnum, p, 0, false)
	} else if (((dumpflags & DUMPFLAG_ICASE) != 0 ?
		mb_strnicmp_r(transmute(cstring)(p), transmute(cstring)(pat), libc.strlen(transmute(cstring)(pat))) :
		C.int(libc.strncmp(transmute(cstring)(p), transmute(cstring)(pat), libc.strlen(transmute(cstring)(pat))))) == 0) &&
	ins_compl_add_infercase(p, C.int(libc.strlen(transmute(cstring)(p))), p_ic != 0, nil, C.int(dir^), false, 0) == 1 {
		// if dir was BACKWARD then honor it just once
		dir^ = .FORWARD
	}
	return true
}

badword_buf: [MAXWLEN + 10]u8 // static storage (C used a stack array; single-threaded)


// Find matching prefixes for "word"; returns updated lnum.
dump_prefixes :: proc "c"(
	slang: ^Slang_T,
	word: ^u8,
	pat: ^u8,
	dir: ^Direction,
	dumpflags: C.int,
	flags: C.int,
	startlnum: C.int,
) -> C.int {
	arridx: [MAXWLEN]idx_T
	curi: [MAXWLEN]C.int
	prefix: [MAXWLEN]u8
	word_up: [MAXWLEN]u8
	has_word_up := false
	lnum := startlnum

	c := utf_ptr2char(transmute(cstring)(word))
	if spell_toupper(c) != c {
		onecap_copy(word, &word_up[0], true)
		has_word_up = true
	}

	byts := slang.sl_pbyts
	idxs := slang.sl_pidxs
	if byts != nil {
		depth := C.int(0)
		arridx[0] = 0
		curi[0] = 1
		for depth >= 0 && !got_int {
			n := arridx[depth]
			len := C.int(b_at(byts, n))
			if curi[depth] > len {
				depth -= 1
				line_breakcheck()
			} else {
				n += curi[depth]
				curi[depth] += 1
				cc := C.int(b_at(byts, n))
				if cc == 0 {
					// End of prefix: count IDs.
					i := C.int(1)
					for ; i < len; i += 1 {
						if b_at(byts, n + i) != 0 {
							break
						}
					}
					curi[depth] += i - 1

					cc = valid_word_prefix(i, n, flags, word, slang, false)
					if cc != 0 {
						libc.strncpy(([^]u8)(uintptr(&prefix[0]) + uintptr(depth)),
							transmute(cstring)(word), C.size_t(MAXWLEN - depth))
						dump_word(slang, &prefix[0], pat, dir, dumpflags,
							(cc & WF_RAREPFX) != 0 ? (flags | WF_RARE) : flags, lnum)
						if lnum != 0 {
							lnum += 1
						}
					}

					if has_word_up {
						cc = valid_word_prefix(i, n, flags, &word_up[0], slang, true)
						if cc != 0 {
							libc.strncpy(([^]u8)(uintptr(&prefix[0]) + uintptr(depth)),
								transmute(cstring)(&word_up[0]), C.size_t(MAXWLEN - depth))
							dump_word(slang, &prefix[0], pat, dir, dumpflags,
								(cc & WF_RAREPFX) != 0 ? (flags | WF_RARE) : flags, lnum)
							if lnum != 0 {
								lnum += 1
							}
						}
					}
				} else if depth < MAXWLEN - 1 {
					b_set(&prefix[0], depth, u8(cc))
					depth += 1
					arridx[depth] = int_at(idxs, n)
					curi[depth] = 1
				}
			}
		}
	}

	return lnum
}

// kOptScopeBuf == 2 (option_defs.h kOptScopeGlobal=0,Win,Tab,Buf)
OPT_LOCAL_c: C.int = 2

@(export)
ex_spelldump :: proc "c"(eap: rawptr) {
	if no_spell_checking(curwin) {
		return
	}
	// Read 'spelllang' from the current window BEFORE creating a new one.
	spl_copy := xstrdup_r(transmute(cstring)(sb_p_spl_r(win_s_r(curwin))))

	do_cmdline_cmd_r("new")

	// enable spelling locally in the new window (set_option_value takes
	// OptIndex+OptVal in this tree — use Ex commands instead)
	setcmd: [MAXPATHL_S]u8
	libc.snprintf(&setcmd[0], MAXPATHL_S, "setlocal spell spelllang=%s",
		transmute(cstring)(spl_copy))
	xfree(spl_copy)
	do_cmdline_cmd_r(transmute(cstring)(&setcmd[0]))

	if !buf_is_empty(curbuf) {
		return
	}

	forceit := (^C.int)(uintptr(eap) + 76)^ != 0 // exarg_T.forceit @76
	spell_dump_compl(nil, 0, nil, forceit ? DUMPFLAG_COUNT : 0)

	if buf_ml_line_count_r(curbuf) > 1 {
		_ = ml_delete_r(buf_ml_line_count_r(curbuf))
	}
	redraw_later_sp(curwin, UPD_NOT_VALID_SP)
}

@(export)
spell_dump_compl :: proc "c"(pat: ^u8, ic: C.int, dir: ^Direction, dumpflags_arg: C.int) {
	arridx: [MAXWLEN]idx_T
	curi: [MAXWLEN]C.int
	word: [MAXWLEN]u8
	lnum := C.int(0)
	region_names: ^u8 = nil
	do_region := true
	dumpflags := dumpflags_arg

	if pat != nil {
		if ic != 0 {
			dumpflags |= DUMPFLAG_ICASE
		} else {
			n := captype(pat, nil)
			if n == WF_ONECAP {
				dumpflags |= DUMPFLAG_ONECAP
			} else if n == WF_ALLCAP && libc.strlen(transmute(cstring)(pat)) > C.size_t(utfc_ptr2len(transmute(cstring)(pat))) {
				dumpflags |= DUMPFLAG_ALLCAP
			}
		}
	}

	// All languages must support the same regions or none at all.
	langp := sb_langp_r(win_s_r(curwin))
	for lpi := C.int(0); lpi < langp.ga_len; lpi += 1 {
		lp := langp_entry(langp, lpi)
		p := &(^Slang_T)(lp.lp_slang).sl_regions[0]
		if b_at(p, 0) != 0 {
			if region_names == nil {
				region_names = p
			} else if libc.strcmp(transmute(cstring)(region_names), transmute(cstring)(p)) != 0 {
				do_region = false
				break
			}
		}
	}

	if do_region && region_names != nil && pat == nil {
		tmpb: [1025]u8
		libc.snprintf(&tmpb[0], 1025, "/regions=%s", transmute(cstring)(region_names))
		_ = ml_append(lnum, &tmpb[0], 0, false)
		lnum += 1
	} else {
		do_region = false
	}

	// Loop over all files loaded for 'spelllang'.
	for lpi := C.int(0); lpi < langp.ga_len; lpi += 1 {
		lp := langp_entry(langp, lpi)
		slang := (^Slang_T)(lp.lp_slang)
		if slang.sl_fbyts == nil { // reloading failed
			continue
		}

		if pat == nil {
			tmpf: [1025]u8
			libc.snprintf(&tmpf[0], 1025, "# file: %s", transmute(cstring)(slang.sl_fname))
			_ = ml_append(lnum, &tmpf[0], 0, false)
			lnum += 1
		}

		patlen := C.int(0)
		if pat != nil && slang.sl_pbyts == nil {
			patlen = C.int(libc.strlen(transmute(cstring)(pat)))
		} else {
			patlen = -1
		}

		for round := C.int(1); round <= 2; round += 1 {
			byts: ^u8
			idxs: ^idx_T
			if round == 1 {
				dumpflags = dumpflags &~ C.int(DUMPFLAG_KEEPCASE)
				byts = slang.sl_fbyts
				idxs = slang.sl_fidxs
			} else {
				dumpflags |= DUMPFLAG_KEEPCASE
				byts = slang.sl_kbyts
				idxs = slang.sl_kidxs
			}
			if byts == nil {
				continue
			}
			depth := C.int(0)
			arridx[0] = 0
			curi[0] = 1
			for depth >= 0 && !got_int &&
			(pat == nil || !ins_compl_interrupted()) {
				if curi[depth] > C.int(b_at(byts, arridx[depth])) {
					depth -= 1
					line_breakcheck()
					ins_compl_check_keys(50, false)
				} else {
					n := arridx[depth] + curi[depth]
					curi[depth] += 1
					c := C.int(b_at(byts, n))
					if c == 0 || depth >= MAXWLEN - 1 {
						flags := int_at(idxs, n)
						if (round == 2 || (flags & WF_KEEPCAP) == 0) &&
						(flags & WF_NEEDCOMP) == 0 &&
						(do_region || (flags & WF_REGION) == 0 ||
						((C.uint(flags) >> 16) & C.uint(lp.lp_region)) != 0) {
							b_set(&word[0], depth, 0)
							if !do_region {
								flags = flags &~ C.int(WF_REGION)
							}

							c = C.int(C.uint(flags) >> 24)
							if c == 0 || curi[depth] == 2 {
								dump_word(slang, &word[0], pat, dir, dumpflags, flags, lnum)
								if pat == nil {
									lnum += 1
								}
							}

							if c != 0 {
								lnum = dump_prefixes(slang, &word[0], pat, dir, dumpflags, flags, lnum)
							}
						}
					} else {
						b_set(&word[0], depth, u8(c))
						depth += 1
						arridx[depth] = int_at(idxs, n)
						curi[depth] = 1

						if depth <= patlen &&
						mb_strnicmp_r(transmute(cstring)(&word[0]), transmute(cstring)(pat), C.size_t(depth)) != 0 {
							depth -= 1
						}
					}
				}
			}
		}
	}
}

@(export)
spell_to_word_end :: proc "c"(start: ^u8, win: rawptr) -> ^u8 {
	p := start

	for b_at(p, 0) != 0 && spell_iswordp(p, win) {
		p = mb_ptr_adv(p)
	}
	return p
}

@(private="file")
spell_expand_need_cap := false

@(export)
spell_word_start :: proc "c"(startcol: C.int) -> C.int {
	if no_spell_checking(curwin) {
		return startcol
	}

	line := get_cursor_line_ptr_r()

	p := (^u8)(uintptr(line) + uintptr(startcol))
	for uintptr(p) > uintptr(line) {
		p = mb_ptr_back(line, p)
		if spell_iswordp_nmw(p, curwin) {
			break
		}
	}

	col := C.int(0)

	for uintptr(p) > uintptr(line) {
		col = C.int(uintptr(p) - uintptr(line))
		p = mb_ptr_back(line, p)
		if !spell_iswordp(p, curwin) {
			break
		}
		col = 0
	}

	return col
}

@(export)
spell_expand_check_cap :: proc "c"(col: C.int) {
	spell_expand_need_cap = check_need_cap(curwin, win_cursor_r(curwin)^.lnum, col)
}

@(export)
expand_spelling :: proc "c"(lnum: C.int, pat: ^u8, matchp: ^rawptr) -> C.int {
	ga: Garray
	spell_suggest_list_r(&ga, transmute(cstring)(pat), 100, spell_expand_need_cap, true)
	matchp^ = ga.ga_data
	return ga.ga_len
}
decor_col_last_off: C.int = 296 // DecorState.col_last
decor_current_off: C.int = 300 // DecorState.current


decor_redraw_col_inline :: proc "c"(wp: rawptr, col: C.int, hidden: bool, ds: rawptr, max_col_last: C.int) {
	if col > (^C.int)(uintptr(ds) + uintptr(decor_col_last_off))^ {
		_ = decor_redraw_col_impl_r(wp, col, 0, hidden, ds, max_col_last)
	}
}

// e_format C global (char*), referenced by other files:
@(export)
e_format: cstring = "E759: Format error in spell file"

foreign _ {
	@(link_name = "xmemdupz")
	xmemdupz_sp :: proc "c" (s: ^u8, len: C.size_t) -> ^u8 ---
}

#assert(size_of(Slang_T) == 4352)
#assert(offset_of(Slang_T, sl_wordcount_buf) == 128)
#assert(offset_of(Slang_T, sl_comppat) == 440)
#assert(offset_of(Slang_T, sl_rep) == 552)
#assert(offset_of(Slang_T, sl_sal) == 1088)
#assert(offset_of(Slang_T, sl_repsal) == 2144)
#assert(offset_of(Slang_T, sl_map_hash_buf) == 2736)
#assert(offset_of(Slang_T, sl_map_array) == 3032)
#assert(offset_of(Slang_T, sl_sounddone_buf) == 4056)

// Bounds-checked spell_iswordp_w wrapper used by wsal (catches rule-index OOB)
wsal_iswordp :: proc "c"(word: ^C.int, idx: C.int, wp: rawptr, tag: cstring) -> bool {
	if idx < 0 || idx >= MAXWLEN {
		dbg: [96]u8
		n := copy(dbg[:], "WSAL OOB ")
		tl := libc.strlen(tag)
		libc.memcpy(&dbg[n], transmute(rawptr)(tag), C.size_t(tl))
		n += int(tl)
		dbg[n] = ' '
		n += 1
		v := idx
		if v < 0 {
			dbg[n] = '-'
			n += 1
			v = -v
		}
		digits: [12]u8
	 dn2 := 0
		for v > 0 {
			digits[dn2] = u8('0' + v % 10)
			v /= 10
			dn2 += 1
		}
		for i := 0; i < dn2; i += 1 {
			dbg[n+i] = digits[dn2-1-i]
		}
		n += dn2
		dbg[n] = '\n'
		linux.write(2, dbg[:n+1])
		return false
	}
	return spell_iswordp_w((^C.int)(uintptr(word) + uintptr(idx) * size_of(C.int)), wp)
}

