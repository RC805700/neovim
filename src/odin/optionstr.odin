// optionstr.odin — port of src/nvim/optionstr.c (string option did_set_* callbacks)
package main

import C "core:c"
import "core:c/libc"

foreign _ {
	@(link_name = "parse_cino")
	parse_cino_o :: proc "c" (buf: rawptr) ---
}

// opt_strings_flags is static in C — ported here
opt_strings_flags_o :: proc "c"(val_in: ^u8, values: ^^u8, flagp: ^C.uint32_t, list: bool) -> C.int {
	val := val_in
	new_flags: C.uint32_t = 0

	// If not list and val is empty, then force one iteration of the while loop
	iter_one := b_at(val, 0) == 0 && !list

	for b_at(val, 0) != 0 || iter_one {
		i: C.uint = 0
		for {
			vi := ([^]^u8)(values)[i]
			if vi == nil {          // val not found in values[]
				return 0 // FAIL
			}
			ln := libc.strlen(transmute(cstring)(vi))
			if libc.strncmp(transmute(cstring)(vi), transmute(cstring)(val), ln) == 0 &&
			((list && b_at(val, C.int(ln)) == ',') || b_at(val, C.int(ln)) == 0) {
				val = (^u8)(uintptr(val) + uintptr(ln) + uintptr(b_at(val, C.int(ln)) == ',' ? 1 : 0))
				new_flags |= C.uint32_t(1) << i
				break // check next item in val list
			}
			i += 1
		}
		if iter_one {
			break
		}
	}
	if flagp != nil {
		flagp^ = new_flags
	}

	return 1 // OK
}

// vimoption_T.values_len at offset 96 (option.odin's mirror has _pad96 there)
opt_values_len :: #force_inline proc "c"(o: ^vimoption_T) -> C.size_t {
	return (^C.size_t)(uintptr(o) + 96)^
}

// kOpt indices needed here (from options_enum.generated.h)
kOptCasemap_E :: 31
kOptBackupcopy_E :: 16
kOptBelloff_E :: 20
kOptCompleteopt_E :: 54
kOptSessionoptions_E :: 255
kOptViewoptions_E :: 344
kOptFoldopen_E :: 112
kOptDisplay_E :: 76
kOptJumpoptions_E :: 157
kOptRedrawdebug_E :: 232
kOptTagcase_E :: 308
kOptTermpastefilter_E :: 317
kOptVirtualedit_E :: 345
kOptSwitchbuf_E :: 300
kOptTabclose_E :: 303
kOptWildoptions_E :: 355
kOptClipboard_E :: 43
kOptFileformats_E :: 95
kOptFileformat_E :: 94

// ── error literals (static const in optionstr.c) ────────────────────────────

E535_S :: "E535: Illegal character after <%c>"
E536_S :: "E536: Comma required"
E540_S :: "E540: Unclosed expression sequence"
E542_S :: "E542: Unbalanced groups"
E589_S :: "E589: 'backupext' and 'patchmode' are equal"
E595_S :: "E595: 'showbreak' contains unprintable or wide character"
E1511_S :: "E1511: Wrong number of characters for field \"%s\""
E1512_S :: "E1512: Wrong character width for field \"%s\""

// SHM_ALL table (optionstr.c static): order must match C exactly —
// {SHM_RO,SHM_MOD,SHM_LINES,SHM_WRI,SHM_ABBREVIATIONS,SHM_WRITE,SHM_TRUNC,
//  SHM_TRUNCALL,SHM_OVER,SHM_OVERALL,SHM_SEARCH,SHM_ATTENTION,SHM_INTRO,
//  SHM_COMPLETIONMENU,SHM_COMPLETIONSCAN,SHM_RECORDING,SHM_FILEINFO,
//  SHM_SEARCHCOUNT,SHM_UNDO,'n','f','x','i',0} (option_vars.h enum values).
SHM_ALL_S := [24]u8{'r', 'm', 'l', 'w', 'a', 'W', 't', 'T', 'o', 'O', 's', 'A', 'I', 'c', 'C', 'q', 'F', 'S', 'u', 'n', 'f', 'x', 'i', 0}

// ── leaf utilities ───────────────────────────────────────────────────────────

@(export)
didset_string_options :: proc "c"() {
	check_str_opt(kOptCasemap_E, nil)
	check_str_opt(kOptBackupcopy_E, nil)
	check_str_opt(kOptBelloff_E, nil)
	check_str_opt(kOptCompleteopt_E, nil)
	check_str_opt(kOptSessionoptions_E, nil)
	check_str_opt(kOptViewoptions_E, nil)
	check_str_opt(kOptFoldopen_E, nil)
	check_str_opt(kOptDisplay_E, nil)
	check_str_opt(kOptJumpoptions_E, nil)
	check_str_opt(kOptRedrawdebug_E, nil)
	check_str_opt(kOptTagcase_E, nil)
	check_str_opt(kOptTermpastefilter_E, nil)
	check_str_opt(kOptVirtualedit_E, nil)
	check_str_opt(kOptSwitchbuf_E, nil)
	check_str_opt(kOptTabclose_E, nil)
	check_str_opt(kOptWildoptions_E, nil)
	check_str_opt(kOptClipboard_E, nil)
}

@(export)
illegal_char :: proc "c"(errbuf: ^u8, errbuflen: C.size_t, c: C.int) -> ^u8 {
	if errbuf == nil {
		return transmute(^u8)(cstring(""))
	}
	libc.snprintf(errbuf, errbuflen, "E539: Illegal character <%s>",
		transmute(cstring)(transchar_o(c)))
	return errbuf
}

illegal_char_after_chr :: proc "c"(errbuf: ^u8, errbuflen: C.size_t, c: C.int) -> ^u8 {
	if errbuf == nil {
		return transmute(^u8)(cstring(""))
	}
	libc.snprintf(errbuf, errbuflen,
		"E535: Illegal character after <%s>", transmute(cstring)(transchar_o(c)))
	return errbuf
}

@(export)
check_buf_options :: proc "c"(buf: rawptr) {
	check_string_option((^u8)(uintptr(buf) + B_P_BH_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_BT_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FENC_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FF_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_DEF_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_INC_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_INEX_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_INDE_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_INDK_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FEX_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_KP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_MPS_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FO_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FLP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_ISK_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_COM_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CMS_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_NF_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_QE_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_SYN_OFF))
	check_string_option((^u8)(uintptr(buf) + SB_SYN_ISK))
	check_string_option((^u8)(uintptr(buf) + SB_P_SPC))
	check_string_option((^u8)(uintptr(buf) + SB_P_SPF))
	check_string_option((^u8)(uintptr(buf) + SB_P_SPL))
	check_string_option((^u8)(uintptr(buf) + SB_P_SPO))
	check_string_option((^u8)(uintptr(buf) + B_P_SUA_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CINK_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CINO_OFF))
	parse_cino_o(buf)
	check_string_option((^u8)(uintptr(buf) + B_P_LOP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FT_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CINW_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CINSD_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_COT_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CPT_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_CFU_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_OFU_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_KEYMAP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_GEFM_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_GP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_MP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_EFM_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_EP_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_PATH_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_TAGS_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_FFU_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_TFU_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_TC_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_DICT_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_DIA_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_TSR_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_TSRFU_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_LW_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_BKC_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_MENC_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_VSTS_OFF))
	check_string_option((^u8)(uintptr(buf) + B_P_VTS_OFF))
}

@(export)
free_string_option :: proc "c"(p: ^u8) {
	if p != empty_string_opt() {
		xfree(p)
	}
}

@(export)
clear_string_option :: proc "c"(pp: ^u8) {
	slot := (^^u8)(rawptr(uintptr(pp)))
	if slot^ != empty_string_opt() {
		xfree(slot^)
	}
	slot^ = empty_string_opt()
}

@(export)
check_string_option :: proc "c"(pp: ^u8) {
	slot := (^^u8)(rawptr(uintptr(pp)))
	if slot^ == nil {
		slot^ = empty_string_opt()
	}
}

// valid_filetype is static in C; valid_name is exported from option.odin
valid_filetype_o :: proc "c"(val: ^u8) -> bool {
	return valid_name(transmute(cstring)(val), cstring(".-_"))
}

@(export)
check_illegal_path_names :: proc "c"(val: ^u8, flags: C.uint32_t) -> bool {
	secure_v := secure
	nfname := (flags & kOptFlagNFname) != 0
	ndname := (flags & kOptFlagNDname) != 0
	if nfname {
		pat: cstring = secure_v != 0 ? "/\\*?[|;&<>\r\n" : "/\\*?[<>\r\n"
		if libc.strpbrk(transmute(cstring)(val), pat) != nil {
			return true
		}
	}
	if ndname {
		if libc.strpbrk(transmute(cstring)(val), "*?[|;&<>\r\n") != nil {
			return true
		}
	}
	return false
}

// opt_values is static in C: reads opt->values (+values_len)
opt_values_o :: proc "c"(opt_idx: C.int, values_len: ^C.size_t) -> ^^u8 {
	// viewoptions/fileformats alias handling
	idx := opt_idx
	if idx == kOptViewoptions_E {
		idx = kOptSessionoptions_E
	} else if idx == kOptFileformats_E {
		idx = kOptFileformat_E
	}
	opt := opt_at(idx)
	if values_len != nil {
		values_len^ = opt_values_len(opt)
	}
	return opt.values
}

check_str_opt :: proc "c"(opt_idx: C.int, varp: rawptr) -> C.int {
	v := varp
	if v == nil {
		v = opt_at(opt_idx).varp
	}
	opt := opt_at(opt_idx)
	is_list := (opt.flags & (kOptFlagComma | kOptFlagOneComma)) != 0
	// NOTE: must go through opt_values_o, NOT opt.values directly —
	// viewoptions/fileformats share their values table via alias
	return opt_strings_flags_o((^^u8)(v)^, opt_values_o(opt_idx, nil), opt.flags_var, is_list)
}

// C return convention (vim_defs.h): OK=1, FAIL=0
OK_S :: 1
FAIL_S :: 0

@(export)
did_set_str_generic :: proc "c"(args: ^optset_T) -> cstring {
	if check_str_opt(args.os_idx, args.os_varp) != OK_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

did_set_option_listflag :: proc "c"(val: ^u8, flags: ^u8, errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	for s := val; b_at(s, 0) != 0; s = (^u8)(uintptr(s) + 1) {
		if _vim_strchr(transmute(cstring)(flags), C.int(b_at(s, 0))) == nil {
			return transmute(cstring)(illegal_char(errbuf, errbuflen, C.int(b_at(s, 0))))
		}
	}
	return nil
}

// ── Odin did_set_* dispatch ──────────────────────────────────────────────────
// Returns the Odin implementation for opt_idx, or nil to fall back to the
// C options-table function pointer. Callbacks are registered here as ported.
did_set_dispatch_o :: proc "c"(opt_idx: C.int) -> rawptr {
	switch opt_idx {
	case kOptAmbiwidth_E:
		return transmute(rawptr)(did_set_ambiwidth)
	case kOptEmoji_E:
		return transmute(rawptr)(did_set_emoji)
	case kOptConcealcursor_E:
		return transmute(rawptr)(did_set_concealcursor)
	case kOptCpoptions_E:
		return transmute(rawptr)(did_set_cpoptions)
	case kOptDisplay_E:
		return transmute(rawptr)(did_set_display)
	case kOptSelection_E:
		return transmute(rawptr)(did_set_selection)
	case kOptShortmess_E:
		return transmute(rawptr)(did_set_shortmess)
	case kOptWhichwrap_E:
		return transmute(rawptr)(did_set_whichwrap)
	case kOptKeymodel_E:
		return transmute(rawptr)(did_set_keymodel)
	case kOptShowcmdloc_E:
		return transmute(rawptr)(did_set_showcmdloc)
	case kOptSessionoptions_E:
		return transmute(rawptr)(did_set_sessionoptions)
	case kOptLispoptions_E:
		return transmute(rawptr)(did_set_lispoptions)
	case kOptMatchpairs_E:
		return transmute(rawptr)(did_set_matchpairs)
	case kOptShowbreak_E:
		return transmute(rawptr)(did_set_showbreak)
	case kOptEventignore_E:
		return transmute(rawptr)(did_set_eventignore)
	case kOptCompleteopt_E:
		return transmute(rawptr)(did_set_completeopt)
	case kOptCursorlineopt_E:
		return transmute(rawptr)(did_set_cursorlineopt)
	case kOptVirtualedit_E:
		return transmute(rawptr)(did_set_virtualedit)
	case kOptTagcase_E:
		return transmute(rawptr)(did_set_tagcase)
	case kOptDiffopt_E:
		return transmute(rawptr)(did_set_diffopt)
	case kOptDiffanchors_E:
		return transmute(rawptr)(did_set_diffanchors)
	case kOptWildmode_E:
		return transmute(rawptr)(did_set_wildmode)
	case kOptFormatoptions_E:
		return transmute(rawptr)(did_set_formatoptions)
	case kOptCompleteitemalign_E:
		return transmute(rawptr)(did_set_completeitemalign)
	case kOptFoldmethod_E:
		return transmute(rawptr)(did_set_foldmethod)
	case kOptVarsofttabstop_E:
		return transmute(rawptr)(did_set_varsofttabstop)
	case kOptVartabstop_E:
		return transmute(rawptr)(did_set_vartabstop)
	case kOptTitlestring_E:
		return transmute(rawptr)(did_set_titlestring)
	case kOptIconstring_E:
		return transmute(rawptr)(did_set_iconstring)
	case kOptSpellsuggest_E:
		return transmute(rawptr)(did_set_spellsuggest)
	case kOptSplitkeep_E:
		return transmute(rawptr)(did_set_splitkeep)
	case kOptStatusline_E:
		return transmute(rawptr)(did_set_statusline)
	case kOptTabline_E:
		return transmute(rawptr)(did_set_tabline)
	case kOptWinbar_E:
		return transmute(rawptr)(did_set_winbar)
	case kOptRulerformat_E:
		return transmute(rawptr)(did_set_rulerformat)
	case kOptStatuscolumn_E:
		return transmute(rawptr)(did_set_statuscolumn)
	case kOptComments_E:
		return transmute(rawptr)(did_set_comments)
	case kOptCommentstring_E:
		return transmute(rawptr)(did_set_commentstring)
	case kOptColorcolumn_E:
		return transmute(rawptr)(did_set_colorcolumn)
	case kOptSigncolumn_E:
		return transmute(rawptr)(did_set_signcolumn)
	case kOptIskeyword_E:
		return transmute(rawptr)(did_set_iskeyword)
	case kOptIsfname_E, kOptIsident_E, kOptIsprint_E:
		return transmute(rawptr)(did_set_isopt)
	case kOptVerbosefile_E:
		return transmute(rawptr)(did_set_verbosefile)
	case kOptMessagesopt_E:
		return transmute(rawptr)(did_set_messagesopt)
	case kOptMkspellmem_E:
		return transmute(rawptr)(did_set_mkspellmem)
	case kOptKeymap_E:
		return transmute(rawptr)(did_set_keymap)
	case kOptSpellfile_E:
		return transmute(rawptr)(did_set_spellfile)
	case kOptSpelllang_E:
		return transmute(rawptr)(did_set_spelllang)
	case kOptSpelloptions_E:
		return transmute(rawptr)(did_set_spelloptions)
	case kOptSpellcapcheck_E:
		return transmute(rawptr)(did_set_spellcapcheck)
	case kOptMousescroll_E:
		return transmute(rawptr)(did_set_mousescroll)
	case kOptCharconvert_E, kOptDiffexpr_E, kOptFoldtext_E, kOptFormatexpr_E,
	kOptIncludeexpr_E, kOptIndentexpr_E, kOptPatchexpr_E:
		return transmute(rawptr)(did_set_optexpr)
	case kOptHelpfile_E:
		return transmute(rawptr)(did_set_helpfile)
	case kOptHighlight_E:
		return transmute(rawptr)(did_set_highlight)
	case kOptFoldexpr_E:
		return transmute(rawptr)(did_set_foldexpr)
	case kOptFoldignore_E:
		return transmute(rawptr)(did_set_foldignore)
	case kOptFoldmarker_E:
		return transmute(rawptr)(did_set_foldmarker)
	case kOptInccommand_E:
		return transmute(rawptr)(did_set_inccommand)
	case kOptHelplang_E:
		return transmute(rawptr)(did_set_helplang)
	case kOptMouse_E:
		return transmute(rawptr)(did_set_mouse)
	case kOptShada_E:
		return transmute(rawptr)(did_set_shada)
	case kOptShellpipe_E, kOptShellredir_E:
		return transmute(rawptr)(did_set_shellpipe_redir)
	case kOptFiletype_E, kOptSyntax_E:
		return transmute(rawptr)(did_set_filetype_or_syntax)
	case kOptGuicursor_E:
		return transmute(rawptr)(did_set_guicursor)
	case kOptWinborder_E:
		return transmute(rawptr)(did_set_winborder)
	case kOptPumborder_E:
		return transmute(rawptr)(did_set_pumborder)
	case kOptWinhighlight_E:
		return transmute(rawptr)(did_set_winhighlight)
	case kOptComplete_E:
		return transmute(rawptr)(did_set_complete)
	case kOptBackground_E:
		return transmute(rawptr)(did_set_background)
	case kOptBuftype_E:
		return transmute(rawptr)(did_set_buftype)
	case kOptEncoding_E, kOptFileencoding_E, kOptMakeencoding_E:
		return transmute(rawptr)(did_set_encoding)
	case kOptFileformat_E:
		return transmute(rawptr)(did_set_fileformat)
	case kOptBackspace_E:
		return transmute(rawptr)(did_set_backspace)
	case kOptBackupcopy_E:
		return transmute(rawptr)(did_set_backupcopy)
	case kOptBackupext_E, kOptPatchmode_E:
		return transmute(rawptr)(did_set_backupext_or_patchmode)
	case kOptBreakat_E:
		return transmute(rawptr)(did_set_breakat)
	case kOptBreakindentopt_E:
		return transmute(rawptr)(did_set_breakindentopt)
	case kOptBufhidden_E:
		return transmute(rawptr)(did_set_bufhidden)
	case kOptFillchars_E, kOptListchars_E:
		return transmute(rawptr)(did_set_chars_option)
	case kOptCinoptions_E:
		return transmute(rawptr)(did_set_cinoptions)
	case:
	}
	return nil
}

// ── Batch 1: simple callbacks ────────────────────────────────────────────────

foreign _ {
	@(link_name = "p_bex")
	p_bex_g: ^u8
	@(link_name = "p_pm")
	p_pm_g: ^u8
	@(link_name = "p_breakat")
	p_breakat_g: ^u8
	@(link_name = "breakat_flags")
	breakat_flags_g: [256]u8
	@(link_name = "p_bkc")
	p_bkc_g: ^u8
	@(link_name = "opt_bkc_values")
	opt_bkc_values_g: [6]^u8
}

kOptBackspace_E :: 14
kOptBackupext_E :: 18
kOptPatchmode_E :: 217
kOptBreakat_E :: 23
kOptCinoptions_E :: 40

kOptBkcFlagYes_E :: 0x01
kOptBkcFlagAuto_E :: 0x02
kOptBkcFlagNo_E :: 0x04

OPT_LOCAL_E :: 0x02
OPT_GLOBAL_E :: 0x01

// local ascii helpers (mark.odin's are file-private)
is_digit_o :: #force_inline proc "c"(b: u8) -> bool {
	return b >= '0' && b <= '9'
}

@(export)
did_set_backspace :: proc "c"(args: ^optset_T) -> cstring {
	if is_digit_o(b_at(p_bs_g, 0)) {
		if b_at(p_bs_g, 0) != '2' {
			return cstring("E474: Invalid argument")
		}
		return nil
	}
	return did_set_str_generic(args)
}

@(export)
did_set_backupcopy :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	// os_oldval is OptValData union; string (NvimString) at offset 0
	old_str := (^NvimString)(uintptr(&args.os_oldval))^
	opt_flags := args.os_flags
	bkc := p_bkc_g
	flags := &bkc_flags_g

	if (opt_flags & OPT_LOCAL_E) != 0 {
		bkc = (^^u8)(uintptr(buf) + B_P_BKC_OFF)^
		flags = (^C.uint)(uintptr(buf) + B_BKC_FLAGS_OFF)
	} else if (opt_flags & OPT_GLOBAL_E) == 0 {
		// When using :set, clear the local flags.
		(^C.uint)(uintptr(buf) + B_BKC_FLAGS_OFF)^ = 0
	}

	if (opt_flags & OPT_LOCAL_E) != 0 && b_at(bkc, 0) == 0 {
		// make the local value empty: use the global value
		flags^ = 0
	} else {
		if opt_strings_flags_o(bkc, &opt_bkc_values_g[0], flags, true) == FAIL_S {
			return cstring("E474: Invalid argument")
		}

		if C.int((flags^ & kOptBkcFlagAuto_E) != 0) + C.int((flags^ & kOptBkcFlagYes_E) != 0) + C.int((flags^ & kOptBkcFlagNo_E) != 0) != 1 {
			// Must have exactly one of "auto", "yes" and "no".
			opt_strings_flags_o((^u8)(old_str.data), &opt_bkc_values_g[0], flags, true)
			return cstring("E474: Invalid argument")
		}
	}

	return nil
}

@(export)
did_set_backupext_or_patchmode :: proc "c"(args: ^optset_T) -> cstring {
	bex := b_at(p_bex_g, 0) == '.' ? (^u8)(uintptr(p_bex_g) + 1) : p_bex_g
	pm := b_at(p_pm_g, 0) == '.' ? (^u8)(uintptr(p_pm_g) + 1) : p_pm_g
	if libc.strcmp(transmute(cstring)(bex), transmute(cstring)(pm)) == 0 {
		return cstring("E589: 'backupext' and 'patchmode' are equal")
	}
	return nil
}

@(export)
did_set_breakat :: proc "c"(args: ^optset_T) -> cstring {
	for i := 0; i < 256; i += 1 {
		breakat_flags_g[i] = 0
	}
	if p_breakat_g != nil {
		for p := p_breakat_g; b_at(p, 0) != 0; p = (^u8)(uintptr(p) + 1) {
			breakat_flags_g[b_at(p, 0)] = 1
		}
	}
	return nil
}

// ── Batch 2: breakindentopt/bufhidden/chars_option ───────────────────────────

foreign _ {
	@(link_name = "p_lcs")
	p_lcs_g: ^u8
	@(link_name = "p_fcs")
	p_fcs_g: ^u8
	@(link_name = "opt_bh_values")
	opt_bh_values_g: [6]^u8
	@(link_name = "opt_bt_values")
	opt_bt_values_g: [9]^u8
}

kOptBreakindentopt_E :: 25
kOptBufhidden_E :: 27
// kOptBuftype_E (29) declared with Batch 12 below.
kOptFillchars_E :: 98
kOptListchars_E :: 175

kFillchars_E :: 0
kListchars_E :: 1

W_P_BRIOPT_OFF :: 824
// W_BRIOPT_LIST_OFF (4248) already in option.odin — reuse directly

did_set_opt_flags_o :: proc "c"(val: ^u8, values: ^^u8, flagp: ^C.uint32_t, list: bool) -> cstring {
	if opt_strings_flags_o(val, values, flagp, list) == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_breakindentopt :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	local_ptr := (^^u8)(uintptr(win) + W_P_BRIOPT_OFF)
	use_win := transmute(rawptr)(varp) == transmute(rawptr)(local_ptr)

	if !briopt_check_r(varp^, use_win ? win : nil) {
		return cstring("E474: Invalid argument")
	}

	// list setting requires a redraw
	if use_win && (^C.int)(uintptr(win) + W_BRIOPT_LIST_OFF)^ != 0 {
		redraw_all_later(UPD_NOT_VALID_S)
	}

	return nil
}

@(export)
did_set_bufhidden :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	return did_set_opt_flags_o((^^u8)(uintptr(buf) + B_P_BH_OFF)^, &opt_bh_values_g[0], nil, false)
}

did_set_global_chars_option_o :: proc "c"(win: rawptr, val: ^u8, what: C.int, opt_flags: C.int, errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	errmsg: cstring = nil
	local_ptr := what == kListchars_E ? (^^u8)(uintptr(win) + 1200) : (^^u8)(uintptr(win) + 1208)

	// only apply the global value to "win" when it does not have a
	// local value
	errmsg = set_chars_option(win, val, what,
		b_at(local_ptr^, 0) == 0 || (opt_flags & OPT_GLOBAL_S) == 0,
		errbuf, errbuflen)
	if errmsg != nil {
		return errmsg
	}

	// If the current window is set to use the global
	// 'listchars'/'fillchars' value, clear the window-local value.
	if (opt_flags & OPT_GLOBAL_S) == 0 {
		clear_string_option(transmute(^u8)(local_ptr))
	}

	// FOR_ALL_TAB_WINDOWS from first_tabpage
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^
		for wp != nil {
			// If the current window has a local value need to apply it
			// again, it was changed when setting the global value.
			opt := what == kListchars_E ? (^^u8)(uintptr(wp) + 1200) : (^^u8)(uintptr(wp) + 1208)
			if b_at(opt^, 0) == 0 {
				set_chars_option(wp, opt^, what, true, errbuf, errbuflen)
			}
			wp = (^rawptr)(uintptr(wp) + 112)^
		}
		tp = (^rawptr)(uintptr(tp) + 8)^
	}

	redraw_all_later(UPD_NOT_VALID_S)

	return nil
}

@(export)
did_set_chars_option :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	errmsg: cstring = nil

	if transmute(rawptr)(varp) == transmute(rawptr)(&p_lcs_g) {      // global 'listchars'
		errmsg = did_set_global_chars_option_o(win, varp^, kListchars_E, args.os_flags,
			args.os_errbuf, args.os_errbuflen)
	} else if transmute(rawptr)(varp) == transmute(rawptr)(&p_fcs_g) {  // global 'fillchars'
		errmsg = did_set_global_chars_option_o(win, varp^, kFillchars_E, args.os_flags,
			args.os_errbuf, args.os_errbuflen)
	} else if transmute(rawptr)(varp) == transmute(rawptr)((^^u8)(uintptr(win) + 1200)) {  // local 'listchars'
		errmsg = set_chars_option(win, varp^, kListchars_E, true,
			args.os_errbuf, args.os_errbuflen)
	} else if transmute(rawptr)(varp) == transmute(rawptr)((^^u8)(uintptr(win) + 1208)) {  // local 'fillchars'
		errmsg = set_chars_option(win, varp^, kFillchars_E, true,
			args.os_errbuf, args.os_errbuflen)
	}

	return errmsg
}

@(export)
did_set_cinoptions :: proc "c"(args: ^optset_T) -> cstring {
	// TODO(vim): recognize errors
	parse_cino_o(args.os_buf)
	return nil
}

// ── Batch 3: thin wrappers ───────────────────────────────────────────────────

kOptAmbiwidth_E :: 2
kOptEmoji_E :: 79
kOptConcealcursor_E :: 57
kOptCpoptions_E :: 61
kOptSelection_E :: 253
kOptShortmess_E :: 269
kOptWhichwrap_E :: 348

CPO_VI_S :: "aAbBcCdDeEfFiIJKlLmMnoOpPqrRsStuvWxXyZ$!%+>;~_" // option_vars.h
COCU_ALL_S :: "nvic" // option_vars.h, flags for 'concealcursor'
WW_ALL_COMMA_S :: "bshl<>[]~," // WW_ALL + ',' ('whichwrap' is comma-separated)
WW_ALL_S :: "bshl<>[]~" // option_vars.h (expand passes WW_ALL without comma)

foreign _ {
	@(link_name = "msg_grid_validate")
	msg_grid_validate_r :: proc "c" () ---
}

@(export)
did_set_ambiwidth :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	return check_chars_options()
}

@(export)
did_set_emoji :: proc "c"(args: ^optset_T) -> cstring {
	if check_str_opt(kOptAmbiwidth_E, nil) != OK_S {
		return cstring("E474: Invalid argument")
	}
	return check_chars_options()
}

@(export)
did_set_concealcursor :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	return did_set_option_listflag(varp^, transmute(^u8)(cstring(COCU_ALL_S)),
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_cpoptions :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	return did_set_option_listflag(varp^, transmute(^u8)(cstring(CPO_VI_S)),
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_shortmess :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	return did_set_option_listflag(varp^, &SHM_ALL_S[0],
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_whichwrap :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	// Add ',' to the list flags because 'whichwrap' is comma-separated.
	return did_set_option_listflag(varp^, transmute(^u8)(cstring(WW_ALL_COMMA_S)),
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_display :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	init_chartab_r()
	msg_grid_validate_r()
	return nil
}

@(export)
did_set_selection :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	if VIsual_active {
		// Visual selection may be drawn differently.
		redraw_curbuf_later(UPD_INVERTED_F)
	}
	return nil
}

// ── Batch 4: str_generic+side-effect + self-contained validators ─────────────

kOptKeymodel_E :: 159
kOptShowcmdloc_E :: 272
kOptLispoptions_E :: 172
kOptMatchpairs_E :: 181
kOptShowbreak_E :: 270
kOptEventignore_E :: 88

kOptSsopFlagSesdir_E :: 0x800
kOptSsopFlagCurdir_E :: 0x1000

foreign _ {
	@(link_name = "p_km")
	p_km_g: ^u8
	@(link_name = "km_stopsel")
	km_stopsel_g: bool
	@(link_name = "km_startsel")
	km_startsel_g: bool
	@(link_name = "p_cot")
	p_cot_g: ^u8
	@(link_name = "cot_flags")
	cot_flags_g: C.uint
	@(link_name = "opt_cot_values")
	opt_cot_values_g: [13]^u8
	@(link_name = "ssop_flags")
	ssop_flags_g: C.uint
	@(link_name = "opt_ssop_values")
	opt_ssop_values_g: [19]^u8
	@(link_name = "check_ei")
	check_ei_r :: proc "c" (ei: ^u8) -> C.int ---
}
// utfc_ptr2len/utf_ptr2char/ptr2cells live in mark.odin — reuse directly.
// _vim_strchr/VIsual_active/redraw_curbuf_later/comp_col/B_P_COT_OFF/
// B_COT_FLAGS_OFF/OPT_LOCAL_E/OPT_GLOBAL_E/E595_S reused from sibling files.

@(export)
did_set_keymodel :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	km_stopsel_g = _vim_strchr(transmute(cstring)(p_km_g), 'o') != nil
	km_startsel_g = _vim_strchr(transmute(cstring)(p_km_g), 'a') != nil
	return nil
}

@(export)
did_set_showcmdloc :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg == nil {
		comp_col()
	}
	return errmsg
}

@(export)
did_set_sessionoptions :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	if (ssop_flags_g & kOptSsopFlagCurdir_E) != 0 && (ssop_flags_g & kOptSsopFlagSesdir_E) != 0 {
		// Don't allow both "sesdir" and "curdir".
		old_str := (^NvimString)(uintptr(&args.os_oldval))^
		opt_strings_flags_o((^u8)(old_str.data), &opt_ssop_values_g[0], &ssop_flags_g, true)
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_lispoptions :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	if b_at(varp^, 0) != 0 && libc.strcmp(transmute(cstring)(varp^), "expr:0") != 0 &&
	libc.strcmp(transmute(cstring)(varp^), "expr:1") != 0 {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_matchpairs :: proc "c"(args: ^optset_T) -> cstring {
	p := (^^u8)(args.os_varp)^
	for b_at(p, 0) != 0 {
		x2: C.int = -1
		x3: C.int = -1
		p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
		if b_at(p, 0) != 0 {
			x2 = C.int(b_at(p, 0))
			p = (^u8)(uintptr(p) + 1)
		}
		if b_at(p, 0) != 0 {
			x3 = utf_ptr2char(transmute(cstring)(p))
			p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
		}
		if x2 != ':' || x3 == -1 || (b_at(p, 0) != 0 && b_at(p, 0) != ',') {
			return cstring("E474: Invalid argument")
		}
		if b_at(p, 0) == 0 {
			break
		}
		p = (^u8)(uintptr(p) + 1) // skip ','
	}
	return nil
}

@(export)
did_set_showbreak :: proc "c"(args: ^optset_T) -> cstring {
	s := (^^u8)(args.os_varp)^
	for b_at(s, 0) != 0 {
		if ptr2cells(transmute(cstring)(s)) != 1 {
			return cstring(E595_S)
		}
		s = (^u8)(uintptr(s) + uintptr(utfc_ptr2len(transmute(cstring)(s)))) // MB_PTR_ADV
	}
	return nil
}

@(export)
did_set_eventignore :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	if check_ei_r(varp^) == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_completeopt :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	opt_flags := args.os_flags
	cot := p_cot_g
	flags := &cot_flags_g

	if (opt_flags & OPT_LOCAL_E) != 0 {
		cot = (^^u8)(uintptr(buf) + B_P_COT_OFF)^
		flags = (^C.uint)(uintptr(buf) + B_COT_FLAGS_OFF)
	} else if (opt_flags & OPT_GLOBAL_E) == 0 {
		// When using :set, clear the local flags.
		(^C.uint)(uintptr(buf) + B_COT_FLAGS_OFF)^ = 0
	}

	if opt_strings_flags_o(cot, &opt_cot_values_g[0], flags, true) == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

// ── Batch 5: win/buf flag patterns + FFI one-liners + completeitemalign ──────

kOptCursorlineopt_E :: 65
kOptDiffopt_E :: 73
kOptDiffanchors_E :: 71
kOptWildmode_E :: 354
kOptFormatoptions_E :: 116
kOptCompleteitemalign_E :: 53

FO_ALL_S :: "tcro/q2vlb1mMBn,aw]jp" // option_vars.h, for 'formatoptions'

CPT_ABBR_E :: 0 // insexpand.h, "abbr"
CPT_KIND_E :: 1 // "kind"
CPT_MENU_E :: 2 // "menu"

W_P_VE_OFF :: 968
W_VIRTCOL_OFF :: 596

foreign _ {
	@(link_name = "p_ve")
	p_ve_g: ^u8
	@(link_name = "opt_ve_values")
	opt_ve_values_g: [7]^u8
	@(link_name = "p_tc")
	p_tc_g: ^u8
	@(link_name = "tc_flags")
	tc_flags_g: C.uint
	@(link_name = "opt_tc_values")
	opt_tc_values_g: [6]^u8
	@(link_name = "p_cia")
	p_cia_g: ^u8
	@(link_name = "cia_flags")
	cia_flags_g: C.uint
	@(link_name = "diffopt_changed")
	diffopt_changed_r :: proc "c" () -> C.int ---
	@(link_name = "diffanchors_changed")
	diffanchors_changed_r :: proc "c" (buflocal: bool) -> C.int ---
	@(link_name = "validate_virtcol")
	validate_virtcol_r :: proc "c" (wp: rawptr) ---
}
// fill_culopt_flags/check_opt_wim_r/coladvance_r reused from sibling files.

@(export)
did_set_cursorlineopt :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	// This could be changed to use opt_strings_flags() instead.
	if b_at(varp^, 0) == 0 || fill_culopt_flags(varp^, win) != OK_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_virtualedit :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	ve := p_ve_g
	flags := &ve_flags_g

	if (args.os_flags & OPT_LOCAL_E) != 0 {
		ve = (^^u8)(uintptr(win) + W_P_VE_OFF)^
		flags = (^C.uint)(uintptr(win) + W_VE_FLAGS_OFF)
	}

	if ((args.os_flags & OPT_LOCAL_E) != 0) && b_at(ve, 0) == 0 {
		// make the local value empty: use the global value
		flags^ = 0
	} else {
		if opt_strings_flags_o(ve, &opt_ve_values_g[0], flags, true) == FAIL_S {
			return cstring("E474: Invalid argument")
		} else if libc.strcmp(transmute(cstring)(ve),
		transmute(cstring)((^NvimString)(uintptr(&args.os_oldval))^.data)) != 0 {
			// Recompute cursor position in case the new 've' setting
			// changes something.
			validate_virtcol_r(win)
			coladvance_r(win, (^C.int)(uintptr(win) + W_VIRTCOL_OFF)^)
		}
	}
	return nil
}

@(export)
did_set_tagcase :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	opt_flags := args.os_flags
	p: ^u8
	flags: ^C.uint

	if (opt_flags & OPT_LOCAL_E) != 0 {
		p = (^^u8)(uintptr(buf) + B_P_TC_OFF)^
		flags = (^C.uint)(uintptr(buf) + B_TC_FLAGS_OFF)
	} else {
		p = p_tc_g
		flags = &tc_flags_g
	}

	if ((opt_flags & OPT_LOCAL_E) != 0) && b_at(p, 0) == 0 {
		// make the local value empty: use the global value
		flags^ = 0
	} else if opt_strings_flags_o(p, &opt_tc_values_g[0], flags, false) == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_diffopt :: proc "c"(args: ^optset_T) -> cstring {
	if diffopt_changed_r() == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_diffanchors :: proc "c"(args: ^optset_T) -> cstring {
	if diffanchors_changed_r((args.os_flags & OPT_LOCAL_E) != 0) == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_wildmode :: proc "c"(args: ^optset_T) -> cstring {
	if check_opt_wim_r() == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_formatoptions :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	return did_set_option_listflag(varp^, transmute(^u8)(cstring(FO_ALL_S)),
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_completeitemalign :: proc "c"(args: ^optset_T) -> cstring {
	p := p_cia_g
	new_cia_flags: C.uint = 0
	seen: [3]bool
	count: C.int = 0
	cbuf: [10]u8
	for b_at(p, 0) != 0 {
		pp := p
		copy_option_part(&pp, &cbuf[0], 10, ",")
		p = pp
		if count >= 3 {
			return cstring("E474: Invalid argument")
		}
		if libc.strcmp(transmute(cstring)(&cbuf[0]), "abbr") == 0 {
			if seen[CPT_ABBR_E] {
				return cstring("E474: Invalid argument")
			}
			new_cia_flags = new_cia_flags * 10 + CPT_ABBR_E
			seen[CPT_ABBR_E] = true
			count += 1
		} else if libc.strcmp(transmute(cstring)(&cbuf[0]), "kind") == 0 {
			if seen[CPT_KIND_E] {
				return cstring("E474: Invalid argument")
			}
			new_cia_flags = new_cia_flags * 10 + CPT_KIND_E
			seen[CPT_KIND_E] = true
			count += 1
		} else if libc.strcmp(transmute(cstring)(&cbuf[0]), "menu") == 0 {
			if seen[CPT_MENU_E] {
				return cstring("E474: Invalid argument")
			}
			new_cia_flags = new_cia_flags * 10 + CPT_MENU_E
			seen[CPT_MENU_E] = true
			count += 1
		} else {
			return cstring("E474: Invalid argument")
		}
	}
	if new_cia_flags == 0 || count != 3 {
		return cstring("E474: Invalid argument")
	}
	cia_flags_g = new_cia_flags
	return nil
}

// ── Batch 6: fold/tabstop/title/splitkeep ────────────────────────────────────

kOptFoldmethod_E :: 109
kOptVarsofttabstop_E :: 339
kOptVartabstop_E :: 340
kOptTitlestring_E :: 329
kOptIconstring_E :: 138
kOptSpellsuggest_E :: 290
kOptSplitkeep_E :: 292

STL_IN_ICON_E :: 1 // globals.h
STL_IN_TITLE_E :: 2

B_P_VSTS_ARR_OFF :: 10760
B_P_VTS_ARR_OFF :: 10784
W_HEIGHT_OFF :: 420
W_PREV_HEIGHT_OFF :: 428

foreign _ {
	@(link_name = "stl_syntax")
	stl_syntax_g: C.int
}
// foldUpdateAll/foldmethodIsDiff/foldmethodIsIndent/newFoldLevel from fold.odin,
// tabstop_set_o/did_set_title/spell_check_sps_r/xfree/is_digit_o reused.

@(export)
did_set_foldmethod :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}
	win := args.os_win
	foldUpdateAll(win)
	if foldmethodIsDiff(win) {
		newFoldLevel()
	}
	return nil
}

did_set_varsofttabstop_vartabstop_o :: proc "c"(buf: rawptr, varp_val: ^u8, arr_off: uintptr) -> cstring {
	if b_at(varp_val, 0) == 0 || (b_at(varp_val, 0) == '0' && b_at(varp_val, 1) == 0) {
		arr := (^rawptr)(uintptr(buf) + arr_off)
		xfree(arr^)
		arr^ = nil
		return nil
	}
	for cp := varp_val; b_at(cp, 0) != 0; cp = (^u8)(uintptr(cp) + 1) {
		if is_digit_o(b_at(cp, 0)) {
			continue
		}
		if b_at(cp, 0) == ',' && uintptr(cp) > uintptr(varp_val) &&
		b_at((^u8)(uintptr(cp) - 1), 0) != ',' {
			continue
		}
		return cstring("E474: Invalid argument")
	}
	oldarray := (^rawptr)(uintptr(buf) + arr_off)^
	if tabstop_set_o(varp_val, (^^u8)(uintptr(buf) + arr_off)) {
		xfree(oldarray)
	} else {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_varsofttabstop :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_varsofttabstop_vartabstop_o(args.os_buf, (^^u8)(args.os_varp)^,
		B_P_VSTS_ARR_OFF)
}

@(export)
did_set_vartabstop :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_varsofttabstop_vartabstop_o(args.os_buf, (^^u8)(args.os_varp)^,
		B_P_VTS_ARR_OFF)
	if errmsg != nil {
		return errmsg
	}
	win := args.os_win
	if foldmethodIsIndent(win) {
		foldUpdateAll(win)
	}
	return nil
}

did_set_titleiconstring_o :: proc "c"(args: ^optset_T, flagval: C.int) -> cstring {
	varp := (^^u8)(args.os_varp)
	// NULL => statusline syntax
	if _vim_strchr(transmute(cstring)(varp^), '%') != nil &&
	check_stl_option(varp^) == nil {
		stl_syntax_g |= flagval
	} else {
		stl_syntax_g &= ~flagval
	}
	did_set_title()
	return nil
}

@(export)
did_set_titlestring :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_titleiconstring_o(args, STL_IN_TITLE_E)
}

@(export)
did_set_iconstring :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_titleiconstring_o(args, STL_IN_ICON_E)
}

@(export)
did_set_spellsuggest :: proc "c"(args: ^optset_T) -> cstring {
	if spell_check_sps_r() != OK_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_splitkeep :: proc "c"(args: ^optset_T) -> cstring {
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^
		for wp != nil {
			(^C.int)(uintptr(wp) + W_PREV_HEIGHT_OFF)^ =
				(^C.int)(uintptr(wp) + W_HEIGHT_OFF)^
			wp = (^rawptr)(uintptr(wp) + 112)^
		}
		tp = (^rawptr)(uintptr(tp) + 8)^
	}
	return did_set_str_generic(args)
}

// ── Batch 7: statusline family + comments ────────────────────────────────────

kOptStatusline_E :: 296
kOptTabline_E :: 304
kOptWinbar_E :: 357
kOptRulerformat_E :: 242
kOptStatuscolumn_E :: 295
kOptComments_E :: 48
kOptCommentstring_E :: 49

COM_ALL_S :: "nbsmexflrO" // option_vars.h, all flags for 'comments'
E524_S :: "E524: Missing colon"
E525_S :: "E525: Zero length string"
E537_S :: "E537: 'commentstring' must be empty or contain %s"

W_NRWIDTH_OFF :: 11048

// WinConfig (480B, align 8) passed through opaquely: large structs travel
// MEMORY-class (caller passes pointer to copy), so identical size+align
// is ABI-equivalent without mirroring fields.
WinConfig_Opaque :: struct #align(8) { data: [480]u8 }

foreign _ {
	@(link_name = "p_ruf")
	p_ruf_g: ^u8
	@(link_name = "ru_wid")
	ru_wid_g: C.int
	@(link_name = "win_config_float")
	win_config_float_r :: proc "c" (wp: rawptr, cfg: WinConfig_Opaque) ---
}
// get_option_default_o/xfree/xmalloc_sp/comp_col/
// OPT_GLOBAL_S/OPT_LOCAL_S/strstr_c/skip_to_option_part/is_digit_o/illegal_char reused.

did_set_statustabline_rulerformat_o :: proc "c"(args: ^optset_T, rulerformat: bool,
statuscolumn: bool) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	if rulerformat {
		ru_wid_g = 0
	} else if statuscolumn {
		// reset 'statuscolumn' width
		(^C.int)(uintptr(win) + W_NRWIDTH_OFF)^ = 0
	}
	errmsg: cstring = nil
	s := varp^
	is_stl := args.os_idx == kOptStatusline_E

	// reset statusline to default when setting global option and empty string is being set
	if is_stl && ((args.os_flags & OPT_GLOBAL_S) != 0 || (args.os_flags & OPT_LOCAL_S) == 0) &&
	b_at(s, 0) == 0 {
		xfree(varp^)
		dflt := get_option_default_o(args.os_idx, args.os_flags)
		dstr := (^NvimString)(uintptr(&dflt.data))^
		dlen := libc.strlen(transmute(cstring)(dstr.data))
		dup := (^u8)(xmalloc_sp(dlen + 1))
		libc.strcpy(dup, transmute(cstring)(dstr.data))
		varp^ = dup
		s = varp^
	}

	// handle floating window statusline changes
	if is_stl && win != nil && (^bool)(uintptr(win) + W_FLOATING_OFF)^ {
		win_config_float_r(win, (^WinConfig_Opaque)(uintptr(win) + W_CONFIG_OFF)^)
	}

	if rulerformat && b_at(s, 0) == '%' {
		s = (^u8)(uintptr(s) + 1) // *++s
		if b_at(s, 0) == '-' { // ignore a '-'
			s = (^u8)(uintptr(s) + 1)
		}
		sl := s
		wid := getdigits_int_r(&sl, true, 0)
		s = sl
		ok := false
		if wid != 0 && b_at(s, 0) == '(' {
			errmsg = check_stl_option(p_ruf_g)
			ok = errmsg == nil
		}
		if ok {
			ru_wid_g = wid
		} else {
			// Validate the flags in 'rulerformat' only if it doesn't point to
			// a custom function ("%!" flag).
			if b_at(varp^, 1) != '!' {
				errmsg = check_stl_option(p_ruf_g)
			}
		}
	} else if rulerformat || b_at(s, 0) != '%' || b_at(s, 1) != '!' {
		// check 'statusline', 'winbar', 'tabline' or 'statuscolumn'
		// only if it doesn't start with "%!"
		errmsg = check_stl_option(s)
	}
	if rulerformat && errmsg == nil {
		comp_col()
	}
	return errmsg
}

@(export)
did_set_statusline :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_statustabline_rulerformat_o(args, false, false)
}

@(export)
did_set_tabline :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_statustabline_rulerformat_o(args, false, false)
}

@(export)
did_set_winbar :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_statustabline_rulerformat_o(args, false, false)
}

@(export)
did_set_rulerformat :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_statustabline_rulerformat_o(args, true, false)
}

@(export)
did_set_statuscolumn :: proc "c"(args: ^optset_T) -> cstring {
	return did_set_statustabline_rulerformat_o(args, false, true)
}

@(export)
did_set_comments :: proc "c"(args: ^optset_T) -> cstring {
	s := (^^u8)(args.os_varp)^
	errmsg: cstring = nil
	for b_at(s, 0) != 0 {
		for b_at(s, 0) != 0 && b_at(s, 0) != ':' {
			if _vim_strchr(cstring(COM_ALL_S), C.int(b_at(s, 0))) == nil &&
			!is_digit_o(b_at(s, 0)) && b_at(s, 0) != '-' {
				errmsg = transmute(cstring)(illegal_char(args.os_errbuf, args.os_errbuflen,
					C.int(b_at(s, 0))))
				break
			}
			s = (^u8)(uintptr(s) + 1)
		}
		if b_at(s, 0) == 0 {
			s = (^u8)(uintptr(s) + 1) // *s++ == NUL
			errmsg = cstring(E524_S)
		} else if b_at((^u8)(uintptr(s) + 1), 0) == ',' ||
		b_at((^u8)(uintptr(s) + 1), 0) == 0 {
			s = (^u8)(uintptr(s) + 1)
			errmsg = cstring(E525_S)
		}
		if errmsg != nil {
			break
		}
		for b_at(s, 0) != 0 && b_at(s, 0) != ',' {
			if b_at(s, 0) == '\\' && b_at((^u8)(uintptr(s) + 1), 0) != 0 {
				s = (^u8)(uintptr(s) + 1)
			}
			s = (^u8)(uintptr(s) + 1)
		}
		s = skip_to_option_part(s)
	}
	return errmsg
}

@(export)
did_set_commentstring :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	if b_at(varp^, 0) != 0 && strstr_c(transmute(cstring)(varp^), "%s") == nil {
		return cstring(E537_S)
	}
	return nil
}

// ── Batch 8: columns/isopt/verbose/messagesopt/mkspellmem/keymap ─────────────

kOptColorcolumn_E :: 46
kOptSigncolumn_E :: 279
kOptIskeyword_E :: 154
kOptIsfname_E :: 152
kOptIsident_E :: 153
kOptIsprint_E :: 155
kOptVerbosefile_E :: 342
kOptMessagesopt_E :: 189
kOptMkspellmem_E :: 190
kOptKeymap_E :: 158

SCL_NUM_E :: -2 // 'signcolumn' set to "number"
B_IMODE_USE_INSERT_E :: -1
B_IMODE_NONE_E :: 0
B_IMODE_LMAP_E :: 1

W_P_CC_OFF :: 1072
W_P_SCL_OFF :: 1160
W_MINSCWIDTH_OFF :: 684

foreign _ {
	@(link_name = "check_isopt")
	check_isopt_r :: proc "c" (var: ^u8) -> C.int ---
	@(link_name = "p_vfile")
	p_vfile_g: ^u8
	@(link_name = "verbose_stop")
	verbose_stop_r :: proc "c" () ---
	@(link_name = "verbose_open")
	verbose_open_r :: proc "c" () -> C.int ---
	@(link_name = "messagesopt_changed")
	messagesopt_changed_r :: proc "c" () -> C.int ---
}
// check_colorcolumn_r/buf_init_chartab_r/set_iminsert_global/set_imsearch_global/
// keymap_init/valid_filetype_o/secure/W_NRWIDTH_OFF reused from sibling files.

@(export)
did_set_colorcolumn :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	local_ptr := (^^u8)(uintptr(win) + W_P_CC_OFF)
	return check_colorcolumn_r(varp^, transmute(rawptr)(varp) == transmute(rawptr)(local_ptr) ? win : nil)
}

@(export)
did_set_signcolumn :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	old_str := (^NvimString)(uintptr(&args.os_oldval))^
	local_ptr := (^^u8)(uintptr(win) + W_P_SCL_OFF)
	if check_signcolumn(varp^, transmute(rawptr)(varp) == transmute(rawptr)(local_ptr) ? win : nil) != OK_S {
		return cstring("E474: Invalid argument")
	}
	// When changing the 'signcolumn' to or from 'number', recompute the
	// width of the number column if 'number' or 'relativenumber' is set.
	if (b_at((^u8)(old_str.data), 0) == 'n' && b_at((^u8)(old_str.data), 1) == 'u') ||
	(^C.int)(uintptr(win) + W_MINSCWIDTH_OFF)^ == SCL_NUM_E {
		(^C.int)(uintptr(win) + W_NRWIDTH_OFF)^ = 0
	}
	return nil
}

@(export)
did_set_isopt :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	// 'isident', 'iskeyword', 'isprint' or 'isfname' option: refill g_chartab[]
	// If the new option is invalid, use old value.
	// 'lisp' option: refill g_chartab[] for '-' char
	if !buf_init_chartab_r(buf, true) {
		args.os_restore_chartab = true // need to restore it below
		return cstring("E474: Invalid argument") // error in value
	}
	return nil
}

@(export)
did_set_iskeyword :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	if transmute(rawptr)(varp) == transmute(rawptr)(&p_isk_g) { // only check for global-value
		if check_isopt_r(varp^) == FAIL_S {
			return cstring("E474: Invalid argument")
		}
	} else { // fallthrough for local-value
		return did_set_isopt(args)
	}
	return nil
}

@(export)
did_set_verbosefile :: proc "c"(args: ^optset_T) -> cstring {
	verbose_stop_r()
	if b_at(p_vfile_g, 0) != 0 && verbose_open_r() == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_messagesopt :: proc "c"(args: ^optset_T) -> cstring {
	if messagesopt_changed_r() == FAIL_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_mkspellmem :: proc "c"(args: ^optset_T) -> cstring {
	if spell_check_msm_r() != OK_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_keymap :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	varp := (^^u8)(args.os_varp)
	opt_flags := args.os_flags

	if !valid_filetype_o(varp^) {
		return cstring("E474: Invalid argument")
	}

	secure_save := secure

	// Reset the secure flag, since the value of 'keymap' has
	// been checked to be safe.
	secure = 0

	// load or unload key mapping tables
	errmsg := transmute(cstring)(keymap_init())

	secure = secure_save

	// Since we check the value, there is no need to set kOptFlagInsecure,
	// even when the value comes from a modeline.
	args.os_value_checked = true

	if errmsg == nil {
		if b_at((^^u8)(uintptr(buf) + B_P_KEYMAP_OFF)^, 0) != 0 {
			// Installed a new keymap, switch on using it.
			(^C.longlong)(uintptr(buf) + B_P_IMINSERT_OFF)^ = B_IMODE_LMAP_E
			if (^C.longlong)(uintptr(buf) + B_P_IMSEARCH_OFF)^ != B_IMODE_USE_INSERT_E {
				(^C.longlong)(uintptr(buf) + B_P_IMSEARCH_OFF)^ = B_IMODE_LMAP_E
			}
		} else {
			// Cleared the keymap, may reset 'iminsert' and 'imsearch'.
			if (^C.longlong)(uintptr(buf) + B_P_IMINSERT_OFF)^ == B_IMODE_LMAP_E {
				(^C.longlong)(uintptr(buf) + B_P_IMINSERT_OFF)^ = B_IMODE_NONE_E
			}
			if (^C.longlong)(uintptr(buf) + B_P_IMSEARCH_OFF)^ == B_IMODE_LMAP_E {
				(^C.longlong)(uintptr(buf) + B_P_IMSEARCH_OFF)^ = B_IMODE_USE_INSERT_E
			}
		}
		if (opt_flags & OPT_LOCAL_E) == 0 {
			set_iminsert_global(buf)
			set_imsearch_global(buf)
		}
		status_redraw_buf(buf)
	}

	return errmsg
}

// ── Batch 9: spell/mouse/optexpr/helpfile/highlight ──────────────────────────

kOptSpellfile_E :: 287
kOptSpelllang_E :: 288
kOptSpelloptions_E :: 289
kOptSpellcapcheck_E :: 286
kOptMousescroll_E :: 202
kOptHelpfile_E :: 128
kOptHighlight_E :: 132
kOptCharconvert_E :: 36
kOptDiffexpr_E :: 72
kOptFoldtext_E :: 113
kOptFormatexpr_E :: 114
kOptIncludeexpr_E :: 146
kOptIndentexpr_E :: 148
kOptPatchexpr_E :: 216

E5080_S :: "E5080: Digit expected"
E519_S :: "E519: Option not supported"
HIGHLIGHT_INIT_S :: "8:SpecialKey,~:EndOfBuffer,z:TermCursor,@:NonText,d:Directory,e:ErrorMsg,i:IncSearch,l:Search,y:CurSearch,m:MoreMsg,M:ModeMsg,n:LineNr,a:LineNrAbove,b:LineNrBelow,N:CursorLineNr,G:CursorLineSign,O:CursorLineFold,r:Question,s:StatusLine,S:StatusLineNC,c:VertSplit,t:Title,v:Visual,V:VisualNOS,w:WarningMsg,W:WildMenu,f:Folded,F:FoldColumn,A:DiffAdd,C:DiffChange,D:DiffDelete,T:DiffText,E:DiffTextAdd,>:SignColumn,-:Conceal,B:SpellBad,P:SpellCap,R:SpellRare,L:SpellLocal,+:Pmenu,=:PmenuSel,k:PmenuMatch,<:PmenuMatchSel,[:PmenuKind,]:PmenuKindSel,{:PmenuExtra,}:PmenuExtraSel,x:PmenuSbar,X:PmenuThumb,*:TabLine,#:TabLineSel,_:TabLineFill,!:CursorColumn,.:CursorLine,o:ColorColumn,q:QuickFixLine,z:StatusLineTerm,Z:StatusLineTermNC,g:MsgArea,h:ComplMatchIns,0:Whitespace,I:PreInsert"

foreign _ {
	@(link_name = "opt_spo_values")
	opt_spo_values_g: [3]^u8
	@(link_name = "p_mousescroll")
	p_mousescroll_g: ^u8
	@(link_name = "p_mousescroll_vert")
	p_mousescroll_vert_g: C.longlong
	@(link_name = "p_mousescroll_hor")
	p_mousescroll_hor_g: C.longlong
	@(link_name = "get_scriptlocal_funcname")
	get_scriptlocal_funcname_r :: proc "c" (funcname: ^u8) -> ^u8 ---
}
// valid_spellfile/valid_spelllang/did_set_spell_option/compile_cap_prog from
// spell.odin; didset_vim/didset_vimruntime/vim_unsetenv_ext from os_env.odin.

@(export)
did_set_spellfile :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	// When there is a window for this buffer in which 'spell'
	// is set load the wordlists.
	if !valid_spellfile(transmute(cstring)(varp^)) {
		return cstring("E474: Invalid argument")
	}
	return did_set_spell_option()
}

@(export)
did_set_spelllang :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	// When there is a window for this buffer in which 'spell'
	// is set load the wordlists.
	if !valid_spelllang(transmute(cstring)(varp^)) {
		return cstring("E474: Invalid argument")
	}
	return did_set_spell_option()
}

@(export)
did_set_spelloptions :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	opt_flags := args.os_flags
	val := (^NvimString)(uintptr(&args.os_newval))^.data

	if (opt_flags & OPT_LOCAL_E) == 0 &&
	opt_strings_flags_o((^u8)(val), &opt_spo_values_g[0], &spo_flags_g, true) != OK_S {
		return cstring("E474: Invalid argument")
	}
	if (opt_flags & OPT_GLOBAL_E) == 0 &&
	opt_strings_flags_o((^u8)(val), &opt_spo_values_g[0],
		(^C.uint32_t)(uintptr((^rawptr)(uintptr(win) + W_S_OFF)^) + SB_P_SPO_FLAGS_OFF), true) != OK_S {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_spellcapcheck :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	// When 'spellcapcheck' is set compile the regexp program.
	return compile_cap_prog((^rawptr)(uintptr(win) + W_S_OFF)^)
}

@(export)
did_set_mousescroll :: proc "c"(args: ^optset_T) -> cstring {
	vertical: C.longlong = -1
	horizontal: C.longlong = -1

	string := p_mousescroll_g

	for {
		end := _vim_strchr(transmute(cstring)(string), ',')
		end_u8 := transmute(^u8)(end)
		length: uintptr = end != nil ? uintptr(end_u8) - uintptr(string) :
			uintptr(libc.strlen(transmute(cstring)(string)))

		// Both "ver:" and "hor:" are 4 bytes long.
		// They should be followed by at least one digit.
		if length <= 4 {
			return cstring("E474: Invalid argument")
		}

		direction: ^C.longlong
		if b_at(string, 0) == 'v' && b_at(string, 1) == 'e' &&
		b_at(string, 2) == 'r' && b_at(string, 3) == ':' {
			direction = &vertical
		} else if b_at(string, 0) == 'h' && b_at(string, 1) == 'o' &&
		b_at(string, 2) == 'r' && b_at(string, 3) == ':' {
			direction = &horizontal
		} else {
			return cstring("E474: Invalid argument")
		}

		// If the direction has already been set, this is a duplicate.
		if direction^ != -1 {
			return cstring("E474: Invalid argument")
		}

		// Verify that only digits follow the colon.
		for i: uintptr = 4; i < length; i += 1 {
			if !is_digit_o(([^]u8)(string)[i]) {
				return cstring(E5080_S)
			}
		}

		sp := (^u8)(uintptr(string) + 4)
		direction^ = C.longlong(getdigits_int_r(&sp, false, -1))
		string = sp

		// Num options are generally kept within the signed int range.
		// We know this number won't be negative because we've already checked for
		// a minus sign. We'll allow 0 as a means of disabling mouse scrolling.
		if direction^ == -1 {
			return cstring("E474: Invalid argument")
		}

		if end == nil {
			break
		}

		string = (^u8)(uintptr(end_u8) + 1)
	}

	// If a direction wasn't set, fallback to the default value.
	p_mousescroll_vert_g = vertical == -1 ? 3 : vertical // MOUSESCROLL_VERT_DFLT
	p_mousescroll_hor_g = horizontal == -1 ? 6 : horizontal // MOUSESCROLL_HOR_DFLT

	return nil
}

@(export)
did_set_optexpr :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)

	// If the option value starts with <SID> or s:, then replace that with
	// the script identifier.
	name := get_scriptlocal_funcname_r(varp^)
	if name != nil {
		free_string_option(varp^)
		varp^ = name
	}
	return nil
}

@(export)
did_set_helpfile :: proc "c"(args: ^optset_T) -> cstring {
	// May compute new values for $VIM and $VIMRUNTIME
	if didset_vim {
		vim_unsetenv_ext("VIM")
	}
	if didset_vimruntime {
		vim_unsetenv_ext("VIMRUNTIME")
	}
	return nil
}

@(export)
did_set_highlight :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)

	if libc.strcmp(transmute(cstring)(varp^), HIGHLIGHT_INIT_S) != 0 {
		return cstring(E519_S)
	}
	return nil
}

// ── Batch 10: fold family + misc small ───────────────────────────────────────

kOptFoldexpr_E :: 104
kOptFoldignore_E :: 105
kOptFoldmarker_E :: 108
kOptInccommand_E :: 144
kOptHelplang_E :: 130
kOptMouse_E :: 197
kOptShada_E :: 256
kOptShellpipe_E :: 260
kOptShellredir_E :: 262

MOUSE_ALL_S :: "anvichr" // option_vars.h, all possible characters
E526_S :: "E526: Missing number after <%s>"
E527_S :: "E527: Missing comma"
E528_S :: "E528: Must specify a ' value"
E1577_S :: "E1577: Invalid format string, only one \"%s\" is allowed"

foreign _ {
	@(link_name = "cmdpreview")
	cmdpreview_g: bool
	@(link_name = "p_shada")
	p_shada_g: ^u8
	@(link_name = "get_shada_parameter")
	get_shada_parameter_r :: proc "c" (typ: C.int) -> C.int ---
	@(link_name = "transchar_byte")
	transchar_byte_r :: proc "c" (c: C.int) -> ^u8 ---
}
// foldmethodIsExpr/foldmethodIsMarker/foldmethodIsIndent/foldUpdateAll from
// fold.odin; libc.snprintf used instead of variadic vim_snprintf (boxing).

@(export)
did_set_foldexpr :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	did_set_optexpr(args)
	if foldmethodIsExpr(win) {
		foldUpdateAll(win)
	}
	return nil
}

@(export)
did_set_foldignore :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	if foldmethodIsIndent(win) {
		foldUpdateAll(win)
	}
	return nil
}

@(export)
did_set_foldmarker :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	p := _vim_strchr(transmute(cstring)(varp^), ',')

	if p == nil {
		return cstring(E536_S)
	}

	if transmute(^u8)(p) == varp^ || b_at(transmute(^u8)(p), 1) == 0 {
		return cstring("E474: Invalid argument")
	}

	if foldmethodIsMarker(win) {
		foldUpdateAll(win)
	}

	return nil
}

@(export)
did_set_inccommand :: proc "c"(args: ^optset_T) -> cstring {
	if cmdpreview_g {
		return cstring("E474: Invalid argument")
	}
	return did_set_str_generic(args)
}

@(export)
did_set_helplang :: proc "c"(args: ^optset_T) -> cstring {
	// Check for "", "ab", "ab,cd", etc.
	s := p_hlg_g
	for b_at(s, 0) != 0 {
		if b_at(s, 1) == 0 ||
		((b_at(s, 2) != ',' || b_at(s, 3) == 0) && b_at(s, 2) != 0) {
			return cstring("E474: Invalid argument")
		}
		if b_at(s, 2) == 0 {
			break
		}
		s = (^u8)(uintptr(s) + 3)
	}
	return nil
}

@(export)
did_set_mouse :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)

	return did_set_option_listflag(varp^, transmute(^u8)(cstring(MOUSE_ALL_S)),
		args.os_errbuf, args.os_errbuflen)
}

@(export)
did_set_shellpipe_redir :: proc "c"(args: ^optset_T) -> cstring {
	seen := false

	p := (^u8)((^NvimString)(uintptr(&args.os_newval))^.data)
	for b_at(p, 0) != 0 {
		if b_at(p, 0) != '%' {
			p = (^u8)(uintptr(p) + 1)
			continue
		}
		if b_at(p, 1) == 0 {
			return cstring(E1577_S)
		}
		if b_at(p, 1) == '%' {
			p = (^u8)(uintptr(p) + 1) // skip second %
			p = (^u8)(uintptr(p) + 1)
			continue
		}

		if b_at(p, 1) == 's' {
			if seen {
				return cstring(E1577_S)
			}
			seen = true
			p = (^u8)(uintptr(p) + 1) // consume 's'
			p = (^u8)(uintptr(p) + 1)
			continue
		}
		return cstring(E1577_S)
	}
	return nil
}

// ── Batch 11: filetype/border/highlight/guicursor/complete ───────────────────

kOptFiletype_E :: 97
kOptSyntax_E :: 302
kOptGuicursor_E :: 122
kOptWinborder_E :: 359
kOptPumborder_E :: 224
kOptWinhighlight_E :: 365
kOptComplete_E :: 51

LSIZE_E :: 512 // tag.h, max line size scratch buffer
SHAPE_CURSOR_E :: 2 // cursor_shape.h, text cursor shape

foreign _ {
	@(link_name = "p_winborder")
	p_winborder_g: ^u8
	@(link_name = "p_pumborder")
	p_pumborder_g: ^u8
	@(link_name = "parse_winborder")
	parse_winborder_r :: proc "c" (fconfig: ^WinConfig_Opaque, border_opt: ^u8, err: ^Api_Error) -> bool ---
	@(link_name = "set_cpt_callbacks")
	set_cpt_callbacks_r :: proc "c" (args: ^optset_T) -> C.int ---
}
// parse_winhl_opt/VIsual_active/valid_filetype_o/illegal_char_after_chr reused.

@(export)
did_set_filetype_or_syntax :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)

	if !valid_filetype_o(varp^) {
		return cstring("E474: Invalid argument")
	}

	old_str := (^NvimString)(uintptr(&args.os_oldval))^
	args.os_value_changed = libc.strcmp(transmute(cstring)(old_str.data),
		transmute(cstring)(varp^)) != 0

	// Since we check the value, there is no need to set kOptFlagInsecure,
	// even when the value comes from a modeline.
	args.os_value_checked = true

	return nil
}

parse_border_opt_o :: proc "c"(border_opt: ^u8) -> bool {
	fconfig: WinConfig_Opaque = {}
	err: Api_Error
	err.typ = -1 // kErrorTypeNone (api/private/defs.h) — NOT 0; ERROR_INIT
	err.msg = nil
	result := true
	if !parse_winborder_r(&fconfig, border_opt, &err) {
		result = false
	}
	api_clear_error_r(&err)
	return result
}

@(export)
did_set_winborder :: proc "c"(args: ^optset_T) -> cstring {
	if !parse_border_opt_o(p_winborder_g) {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_pumborder :: proc "c"(args: ^optset_T) -> cstring {
	if !parse_border_opt_o(p_pumborder_g) {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_winhighlight :: proc "c"(args: ^optset_T) -> cstring {
	win := args.os_win
	varp := (^^u8)(args.os_varp)
	local_ptr := (^^u8)(uintptr(win) + W_P_WINHL_OFF)
	if !parse_winhl_opt(varp^, transmute(rawptr)(varp) == transmute(rawptr)(local_ptr) ? win : nil) {
		return cstring("E474: Invalid argument")
	}
	return nil
}

@(export)
did_set_guicursor :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := parse_shape_opt_r(SHAPE_CURSOR_E)
	if errmsg != nil {
		return errmsg
	}
	if VIsual_active {
		// In Visual mode cursor may be drawn differently.
		redrawWinline(curwin, (^C.int)(uintptr(curwin) + W_CURSOR_OFF)^)
	}
	return nil
}

@(export)
did_set_complete :: proc "c"(args: ^optset_T) -> cstring {
	varp := (^^u8)(args.os_varp)
	buffer: [LSIZE_E]u8
	char_before: u8 = 0

	p := varp^
	for b_at(p, 0) != 0 {
		libc.memset(&buffer[0], 0, LSIZE_E)
		buf_ptr := (^u8)(&buffer[0])
		escape := false

		// Extract substring while handling escaped commas
		for b_at(p, 0) != 0 && (b_at(p, 0) != ',' || escape) &&
		uintptr(buf_ptr) < uintptr(&buffer[0]) + (LSIZE_E - 1) {
			if b_at(p, 0) == '\\' && b_at(p, 1) == ',' {
				escape = true // Mark escape mode
				p = (^u8)(uintptr(p) + 1) // Skip '\'
			} else {
				escape = false
				buf_ptr^ = b_at(p, 0)
				buf_ptr = (^u8)(uintptr(buf_ptr) + 1)
			}
			p = (^u8)(uintptr(p) + 1)
		}
		buf_ptr^ = 0

		if _vim_strchr(cstring(".wbuksid]tUfFo"), C.int(buffer[0])) == nil {
			return transmute(cstring)(illegal_char(args.os_errbuf, args.os_errbuflen,
				C.int(buffer[0])))
		}

		if _vim_strchr(cstring("ksF"), C.int(buffer[0])) == nil && buffer[1] != 0 &&
		buffer[1] != '^' {
			char_before = buffer[0]
		} else {
			// Test for a number after '^'
			t := _vim_strchr(transmute(cstring)(&buffer[0]), '^')
			if t != nil {
				tu := transmute(^u8)(t)
				tu^ = 0 // *t = NUL
				tu = (^u8)(uintptr(tu) + 1) // t++
				if b_at(tu, 0) == 0 {
					char_before = '^'
				} else {
					for b_at(tu, 0) != 0 {
						if !is_digit_o(b_at(tu, 0)) {
							char_before = '^'
							break
						}
						tu = (^u8)(uintptr(tu) + 1)
					}
				}
			}
		}
		if char_before != 0 {
			if args.os_errbuf != nil {
				return transmute(cstring)(illegal_char_after_chr(args.os_errbuf,
					args.os_errbuflen, C.int(char_before)))
			}
			return nil
		}
		// Skip comma and spaces
		for b_at(p, 0) == ',' || b_at(p, 0) == ' ' {
			p = (^u8)(uintptr(p) + 1)
		}
	}

	if set_cpt_callbacks_r(args) != OK_S {
		return transmute(cstring)(illegal_char_after_chr(args.os_errbuf,
			args.os_errbuflen, 'F'))
	}
	return nil
}

@(export)
did_set_shada :: proc "c"(args: ^optset_T) -> cstring {
	errbuf := args.os_errbuf
	errbuflen := args.os_errbuflen

	s := p_shada_g
	for b_at(s, 0) != 0 {
		// Check it's a valid character
		if _vim_strchr(cstring("!\"%'/:<@cfhnrs"), C.int(b_at(s, 0))) == nil {
			return transmute(cstring)(illegal_char(errbuf, errbuflen, C.int(b_at(s, 0))))
		}
		if b_at(s, 0) == 'n' { // name is always last one
			break
		} else if b_at(s, 0) == 'r' { // skip until next ','
			for {
				s = (^u8)(uintptr(s) + 1) // *++s
				if b_at(s, 0) == 0 || b_at(s, 0) == ',' {
					break
				}
			}
		} else if b_at(s, 0) == '%' {
			// optional number
			for {
				s = (^u8)(uintptr(s) + 1)
				if !is_digit_o(b_at(s, 0)) {
					break
				}
			}
		} else if b_at(s, 0) == '!' || b_at(s, 0) == 'h' || b_at(s, 0) == 'c' {
			s = (^u8)(uintptr(s) + 1) // no extra chars
		} else { // must have a number
			for {
				s = (^u8)(uintptr(s) + 1)
				if !is_digit_o(b_at(s, 0)) {
					break
				}
			}

			if !is_digit_o(b_at((^u8)(uintptr(s) - 1), 0)) {
				if errbuf != nil {
					libc.snprintf(errbuf, errbuflen, E526_S,
						rawptr(transchar_byte_r(C.int(b_at((^u8)(uintptr(s) - 1), 0)))))
					return transmute(cstring)(errbuf)
				} else {
					return cstring("")
				}
			}
		}
		if b_at(s, 0) == ',' {
			s = (^u8)(uintptr(s) + 1)
		} else if b_at(s, 0) != 0 {
			if errbuf != nil {
				return cstring(E527_S)
			} else {
				return cstring("")
			}
		}
	}
	if b_at(p_shada_g, 0) != 0 && get_shada_parameter_r('\'') < 0 {
		return cstring(E528_S)
	}
	return nil
}

// ── Batch 13: check_stl_option + check_signcolumn ────────────────────────────

W_P_NU_OFF :: 960
W_P_RNU_OFF :: 964
W_MAXSCWIDTH_OFF :: 688
W_SCWIDTH_OFF :: 680

SCL_NO_E :: -1 // 'signcolumn' set to "no"

// C string with all 'statusline' option flags (option_vars.h STL_ALL order,
// incl. the duplicated T/X/@ tail).
STL_ALL_S :: "fFtcvVlLnkoObBrRhHyYwWmMqPpPaNSCs{=<*#$TXTXT@"

// check_stl_option's static errbuf (ERR_BUFLEN 80).
@(private="file")
stl_check_errbuf: [80]u8

foreign _ {
	@(link_name = "opt_scl_values")
	opt_scl_values_g: [23]^u8
}
// Batch 13 exports below (check_stl_option, check_signcolumn).

@(export)
check_stl_option :: proc "c"(s_in: ^u8) -> cstring {
	s := s_in
	groupdepth: C.int = 0

	for b_at(s, 0) != 0 {
		// Check for valid keys after % sequences
		for b_at(s, 0) != 0 && b_at(s, 0) != '%' {
			s = (^u8)(uintptr(s) + 1)
		}
		if b_at(s, 0) == 0 {
			break
		}
		s = (^u8)(uintptr(s) + 1)
		if b_at(s, 0) == '%' || b_at(s, 0) == '<' || b_at(s, 0) == '=' {
			s = (^u8)(uintptr(s) + 1)
			continue
		}
		if b_at(s, 0) == ')' {
			s = (^u8)(uintptr(s) + 1)
			groupdepth -= 1
			if groupdepth < 0 {
				break
			}
			continue
		}
		if b_at(s, 0) == '-' {
			s = (^u8)(uintptr(s) + 1)
		}
		for is_digit_o(b_at(s, 0)) {
			s = (^u8)(uintptr(s) + 1)
		}
		if b_at(s, 0) == '*' {
			continue
		}
		if b_at(s, 0) == '.' {
			s = (^u8)(uintptr(s) + 1)
			for b_at(s, 0) != 0 && is_digit_o(b_at(s, 0)) {
				s = (^u8)(uintptr(s) + 1)
			}
		}
		if b_at(s, 0) == '(' {
			groupdepth += 1
			continue
		}
		if _vim_strchr(cstring(STL_ALL_S), C.int(b_at(s, 0))) == nil {
			return transmute(cstring)(illegal_char(&stl_check_errbuf[0], 80,
				C.int(b_at(s, 0))))
		}
		if b_at(s, 0) == '{' {
			s = (^u8)(uintptr(s) + 1) // *++s
			reevaluate := b_at(s, 0) == '%'

			if reevaluate {
				s = (^u8)(uintptr(s) + 1) // *++s
				if b_at(s, 0) == '}' {
					// "}" is not allowed immediately after "%{%"
					return transmute(cstring)(illegal_char(&stl_check_errbuf[0],
						80, '}'))
				}
			}
			for ((b_at(s, 0) != '}') || (reevaluate &&
			b_at((^u8)(uintptr(s) - 1), 0) != '%')) && (b_at(s, 0) != 0) {
				s = (^u8)(uintptr(s) + 1)
			}
			if b_at(s, 0) != '}' {
				return cstring(E540_S)
			}
		}
	}
	if groupdepth != 0 {
		return cstring(E542_S)
	}
	return nil
}

@(export)
check_signcolumn :: proc "c"(scl: ^u8, wp: rawptr) -> C.int {	val := empty_string_opt()
	if scl != nil {
		val = scl
	} else if wp != nil {
		val = (^^u8)(uintptr(wp) + W_P_SCL_OFF)^
	}

	if b_at(val, 0) == 0 {
		return FAIL_S
	}

	if opt_strings_flags_o(val, &opt_scl_values_g[0], nil, false) != OK_S {
		if libc.strncmp(transmute(cstring)(val), "auto:", 5) != 0 ||
		libc.strlen(transmute(cstring)(val)) != 8 ||
		!is_digit_o(b_at(val, 5)) || b_at(val, 6) != '-' || !is_digit_o(b_at(val, 7)) {
			return FAIL_S
		}
		// auto:<NUM>-<NUM>
		min := C.int(b_at(val, 5)) - '0'
		max := C.int(b_at(val, 7)) - '0'
		if min < 1 || max < 2 || min > 8 || min >= max {
			return FAIL_S
		}
		if wp == nil {
			return OK_S
		}
		(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = min
		(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = max
	} else {
		if wp == nil {
			return OK_S
		}
		if libc.strncmp(transmute(cstring)(val), "no", 2) == 0 { // no
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = SCL_NO_E
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = SCL_NO_E
		} else if libc.strncmp(transmute(cstring)(val), "nu", 2) == 0 &&
		((^C.int)(uintptr(wp) + W_P_NU_OFF)^ != 0 ||
		(^C.int)(uintptr(wp) + W_P_RNU_OFF)^ != 0) { // number
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = SCL_NUM_E
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = SCL_NUM_E
		} else if libc.strncmp(transmute(cstring)(val), "yes:", 4) == 0 { // yes:<NUM>
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = C.int(b_at(val, 4)) - '0'
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = C.int(b_at(val, 4)) - '0'
		} else if b_at(val, 0) == 'y' { // yes
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = 1
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = 1
		} else if libc.strncmp(transmute(cstring)(val), "auto:", 5) == 0 { // auto:<NUM>
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = 0
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = C.int(b_at(val, 5)) - '0'
		} else { // auto
			(^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^ = 0
			(^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^ = 1
		}
	}

	minsc := (^C.int)(uintptr(wp) + W_MINSCWIDTH_OFF)^
	maxsc := (^C.int)(uintptr(wp) + W_MAXSCWIDTH_OFF)^
	scw := (^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^
	scwidth := minsc <= 0 ? 0 : min(maxsc, scw)
	(^C.int)(uintptr(wp) + W_SCWIDTH_OFF)^ = max(minsc, scwidth)
	return OK_S
}

// ── Batch 12 (final): background/buftype/encoding/fileformat ─────────────────

kOptBackground_E :: 13
kOptBuftype_E :: 29
kOptEncoding_E :: 80
kOptFileencoding_E :: 92
kOptMakeencoding_E :: 179
// kOptFileformat_E (94) already declared above.

E21_S :: "E21: Cannot make changes, 'modifiable' is off"
EOL_MAC_E :: 2 // option_vars.h, CR
UPD_VALID_O :: 10 // drawscreen.h
UPD_NOT_VALID_O :: 40

B_TERMINAL_OFF :: 12488
B_PROMPT_START_OFF :: 11224
B_ML_LINE_COUNT_OFF :: 8
W_STATUS_HEIGHT_OFF :: 432
W_REDR_STATUS_OFF :: 708

foreign _ {
	@(link_name = "p_bg")
	p_bg_g: ^u8
	// p_fenc/redraw_titles/spell_reload/p_enc/opt_bt_values already
	// exported/declared in option.odin/spell.odin/digraph.odin/Batch 2.
	@(link_name = "ml_setflags")
	ml_setflags_r :: proc "c" (buf: rawptr) ---
	@(link_name = "init_highlight")
	init_highlight_r :: proc "c" (both: bool, reset: bool) ---
	@(link_name = "do_unlet")
	do_unlet_r :: proc "c" (name: cstring, name_len: C.size_t, forceit: bool) -> C.int ---
 	@(link_name = "enc_canonize")
 	enc_canonize_r :: proc "c" (enc: ^u8) -> ^u8 ---
 	@(link_name = "terminal_notify_theme")
 	terminal_notify_theme_r :: proc "c" (term: rawptr, dark: bool) ---
}
// redraw_later/redraw_buf_later/free_fmark/os_time/firstbuf reused.

@(export)
did_set_background :: proc "c"(args: ^optset_T) -> cstring {
	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}

	old_str := (^NvimString)(uintptr(&args.os_oldval))^
	if b_at((^u8)(old_str.data), 0) == b_at(p_bg_g, 0) {
		// Value was not changed
		return nil
	}

	dark := b_at(p_bg_g, 0) == 'd'

	init_highlight_r(false, false)

	if (dark != (b_at(p_bg_g, 0) == 'd')) &&
	get_var_value("g:colors_name") != nil {
		// The color scheme must have set 'background' back to another
		// value, that's not what we want here.  Disable the color
		// scheme and set the colors again.
		do_unlet_r("g:colors_name", 13, true)
		free_string_option(p_bg_g)
		want := dark ? cstring("dark") : cstring("light")
		dlen := libc.strlen(want)
		dup := (^u8)(xmalloc_sp(dlen + 1))
		libc.strcpy(dup, want)
		(^^u8)(&p_bg_g)^ = dup
		check_string_option(transmute(^u8)(&p_bg_g))
		init_highlight_r(false, false)
	}

	// Notify all terminal buffers that the background color changed so they can
	// send a theme update notification
	buf := firstbuf
	for buf != nil {
		if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil {
			terminal_notify_theme_r((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^, dark)
		}
		buf = (^rawptr)(uintptr(buf) + 120)^ // b_next
	}

	return nil
}

@(export)
did_set_buftype :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	win := args.os_win
	bt := (^^u8)(uintptr(buf) + B_P_BT_OFF)^
	// When 'buftype' is set, check for valid value.
	if ((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ != nil && b_at(bt, 0) != 't') ||
	((^rawptr)(uintptr(buf) + B_TERMINAL_OFF)^ == nil && b_at(bt, 0) == 't') ||
	opt_strings_flags_o(bt, &opt_bt_values_g[0], nil, false) != OK_S {
		return cstring("E474: Invalid argument")
	}
	// buftype=prompt:
	if b_at(bt, 0) == 'p' {
		// Set default value for 'comments'
		empty := (^u8)(xmalloc_sp(1))
		empty^ = 0
		set_option_direct(kOptComments_E, str_optval(empty, 0), OPT_LOCAL_S, -6) // SID_NONE
		// set the prompt start position to lastline.
		promptp := uintptr(buf) + B_PROMPT_START_OFF
		next_lnum := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		next_col := (^C.int)(promptp + 4)^ // mark.col
		free_fmark((^Fmark_T)(promptp)^)
		(^C.int)(promptp)^ = next_lnum // mark.lnum
		(^C.int)(promptp + 4)^ = next_col // mark.col
		(^C.int)(promptp + 8)^ = 0 // mark.coladd
		(^C.int)(promptp + 12)^ = 0 // fnum
		(^u64)(promptp + 16)^ = u64(os_time()) // timestamp
		(^Fmarkv_T)(promptp + 24)^ = INIT_FMARKV // view
		(^rawptr)(promptp + 32)^ = nil // additional_data
	}
	if (^C.int)(uintptr(win) + W_STATUS_HEIGHT_OFF)^ != 0 || global_stl_height() != 0 {
		(^bool)(uintptr(win) + W_REDR_STATUS_OFF)^ = true
		redraw_later(win, UPD_VALID_O)
	}
	(^bool)(uintptr(buf) + B_HELP_OFF)^ = b_at(bt, 0) == 'h'
	redraw_titles()
	return nil
}

@(export)
did_set_encoding :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	varp := (^^u8)(args.os_varp)
	opt_flags := args.os_flags
	// Get the global option to compare with, otherwise we would have to check
	// two values for all local options.
	gvarp := nvim_odin_get_varp_scope_from(args.os_idx, OPT_GLOBAL_S, buf, nil)

	if gvarp == transmute(rawptr)(&p_fenc_g) {
		if (^C.longlong)(uintptr(buf) + B_P_MA_OFF)^ == 0 && opt_flags != OPT_GLOBAL_S {
			return cstring(E21_S)
		}

		if _vim_strchr(transmute(cstring)(varp^), ',') != nil {
			// No comma allowed in 'fileencoding'; catches confusing it
			// with 'fileencodings'.
			return cstring("E474: Invalid argument")
		}
		// May show a "+" in the title now.
		redraw_titles()
		// Add 'fileencoding' to the swap file.
		ml_setflags_r(buf)
	}

	// canonize the value, so that strcmp() can be used on it
	p := enc_canonize_r(varp^)
	xfree(varp^)
	varp^ = p
	if transmute(rawptr)(varp) == transmute(rawptr)(&p_enc) {
		// only encoding=utf-8 allowed
		if libc.strcmp(transmute(cstring)(p_enc), "utf-8") != 0 {
			return cstring(E519_S)
		}
		spell_reload()
	}
	return nil
}

@(export)
did_set_fileformat :: proc "c"(args: ^optset_T) -> cstring {
	buf := args.os_buf
	old_str := (^NvimString)(uintptr(&args.os_oldval))^
	opt_flags := args.os_flags
	if (^C.longlong)(uintptr(buf) + B_P_MA_OFF)^ == 0 && (opt_flags & OPT_GLOBAL_S) == 0 {
		return cstring(E21_S)
	}

	errmsg := did_set_str_generic(args)
	if errmsg != nil {
		return errmsg
	}

	redraw_titles()
	// update flag in swap file
	ml_setflags_r(buf)
	// Redraw needed when switching to/from "mac": a CR in the text
	// will be displayed differently.
	if get_fileformat(buf) == EOL_MAC_E || b_at((^u8)(old_str.data), 0) == 'm' {
		redraw_buf_later(buf, UPD_NOT_VALID_O)
	}
	return nil
}

// ── Batch 14: cmdline-completion expand machinery ────────────────────────────
// Signatures: (args: ^Optexpand_T, numMatches: ^C.int, matches: ^rawptr) -> C.int.
// matches is char*** (out-param); numMatches is int* (out-param).

// optexpand_T (option_defs.h, probed): varp@0 idx@8 opt_value@16
// append@24 incl_orig@25 regmatch@32 xp@40 set_arg@48, size 56.
OET_VARP_OFF :: 0
OET_IDX_OFF :: 8
OET_OPT_VALUE_OFF :: 16
OET_APPEND_OFF :: 24
OET_INCL_ORIG_OFF :: 25
OET_REGMATCH_OFF :: 32
OET_XP_OFF :: 40
OET_SET_ARG_OFF :: 48

CompleteListItemGetter_T :: proc "c" (xp: rawptr, idx: C.int) -> ^u8

@(private="file")
set_opt_callback_orig_option: ^u8
@(private="file")
set_opt_callback_func: CompleteListItemGetter_T
@(private="file")
expand_eiw: bool

foreign _ {
	@(link_name = "ExpandGeneric")
	expand_generic_r :: proc "c" (pat: cstring, xp: rawptr, regmatch: rawptr,
		matches: ^rawptr, numMatches: ^C.int, func: CompleteListItemGetter_T,
		escaped: bool) ---
	@(link_name = "get_event_name_no_group")
	get_event_name_no_group_r :: proc "c" (xp: rawptr, idx: C.int, win: bool) -> ^u8 ---
	@(link_name = "get_encoding_name")
	get_encoding_name_r :: proc "c" (xp: rawptr, idx: C.int) -> ^u8 ---
	@(link_name = "get_highlight_name")
	get_highlight_name_r :: proc "c" (xp: rawptr, idx: C.int) -> ^u8 ---
	@(link_name = "p_ei")
	p_ei_g: ^u8
	@(link_name = "opt_dip_algorithm_values")
	opt_dip_algorithm_values_g: [5]^u8
	@(link_name = "opt_dip_inline_values")
	opt_dip_inline_values_g: [5]^u8
	@(link_name = "opt_ff_values")
	opt_ff_values_g: [4]^u8
}
// xstrdup replicated via xmalloc_sp+strcpy (optval_copy pattern); xmemdupz,
// IObuff (os_signal, same storage as C), XPP_PATTERN reused.

expand_set_opt_callback_o :: proc "c"(xp: rawptr, idx: C.int) -> ^u8 {
	if idx == 0 {
		if set_opt_callback_orig_option != nil {
			return set_opt_callback_orig_option
		} else {
			return transmute(^u8)(cstring("")) // empty strings are ignored
		}
	}
	return set_opt_callback_func(xp, idx - 1)
}

// Expand an option that accepts a list of string values.
expand_set_opt_string_o :: proc "c"(args: rawptr, values: [^]^u8, numValues: C.size_t,
numMatches: ^C.int, matches: ^rawptr) -> C.int {
	regmatch := (^rawptr)(uintptr(args) + OET_REGMATCH_OFF)^
	include_orig_val := (^bool)(uintptr(args) + OET_INCL_ORIG_OFF)^
	option_val := (^^u8)(uintptr(args) + OET_OPT_VALUE_OFF)^

	// Assume numValues is small since they are fixed enums, so just allocate
	// upfront instead of needing two passes to calculate output size.
	arr := ([^]^u8)(xmalloc_sp(C.size_t(8) * (C.size_t(numValues) + 1)))
	matches^ = arr

	count: C.int = 0

	if include_orig_val && b_at(option_val, 0) != 0 {
		sz := libc.strlen(transmute(cstring)(option_val))
		dup := (^u8)(xmalloc_sp(sz + 1))
		libc.memcpy(dup, option_val, sz)
		b_set(dup, C.int(sz), 0)
		arr[count] = dup
		count += 1
	}

	v := values
	for v[0] != nil {
		if b_at(v[0], 0) == 0 {
			// Ignore empty
		} else if include_orig_val && b_at(option_val, 0) != 0 {
			if libc.strcmp(transmute(cstring)(v[0]), transmute(cstring)(option_val)) == 0 {
				// already listed
			} else if vim_regexec_r((^Regmatch_T)(regmatch), v[0], 0) != 0 {
				sz := libc.strlen(transmute(cstring)(v[0]))
				dup := (^u8)(xmalloc_sp(sz + 1))
				libc.memcpy(dup, v[0], sz)
				b_set(dup, C.int(sz), 0)
				arr[count] = dup
				count += 1
			}
		} else if vim_regexec_r((^Regmatch_T)(regmatch), v[0], 0) != 0 {
			sz := libc.strlen(transmute(cstring)(v[0]))
			dup := (^u8)(xmalloc_sp(sz + 1))
			libc.memcpy(dup, v[0], sz)
			b_set(dup, C.int(sz), 0)
			arr[count] = dup
			count += 1
		}
		v = ([^]^u8)(uintptr(v) + 8)
	}
	if count == 0 {
		xfree(matches^)
		matches^ = nil
		return FAIL_S
	}
	numMatches^ = count
	return OK_S
}

// Expand an option with a callback that iterates through a list of possible names.
expand_set_opt_generic_o :: proc "c"(args: rawptr, func: CompleteListItemGetter_T,
numMatches: ^C.int, matches: ^rawptr) -> C.int {
	incl := (^bool)(uintptr(args) + OET_INCL_ORIG_OFF)^
	optv := (^^u8)(uintptr(args) + OET_OPT_VALUE_OFF)^
	set_opt_callback_orig_option = incl ? optv : nil
	set_opt_callback_func = func

	// not using fuzzy as currently EXPAND_STRING_SETTING doesn't use it
	expand_generic_r("", (^rawptr)(uintptr(args) + OET_XP_OFF)^,
		(^rawptr)(uintptr(args) + OET_REGMATCH_OFF)^, matches, numMatches,
		expand_set_opt_callback_o, false)

	set_opt_callback_orig_option = nil
	set_opt_callback_func = nil
	return OK_S
}

// Expand an option which is a list of flags.
expand_set_opt_listflag_o :: proc "c"(args: rawptr, flags: ^u8, numMatches: ^C.int,
matches: ^rawptr) -> C.int {
	option_val := (^^u8)(uintptr(args) + OET_OPT_VALUE_OFF)^
	cmdline_val := (^^u8)(uintptr(args) + OET_SET_ARG_OFF)^
	append := (^bool)(uintptr(args) + OET_APPEND_OFF)^
	include_orig_val := (^bool)(uintptr(args) + OET_INCL_ORIG_OFF)^ &&
		b_at(option_val, 0) != 0

	num_flags := libc.strlen(transmute(cstring)(flags))

	// Assume we only have small number of flags, so just allocate max size.
	arr := ([^]^u8)(xmalloc_sp(C.size_t(8) * (C.size_t(num_flags) + 1)))
	matches^ = arr

	count: C.int = 0

	if include_orig_val {
		sz := libc.strlen(transmute(cstring)(option_val))
		dup := (^u8)(xmalloc_sp(sz + 1))
		libc.memcpy(dup, option_val, sz)
		b_set(dup, C.int(sz), 0)
		arr[count] = dup
		count += 1
	}

	for flag := flags; b_at(flag, 0) != 0; flag = (^u8)(uintptr(flag) + 1) {
		if append && _vim_strchr(transmute(cstring)(option_val), C.int(b_at(flag, 0))) != nil {
			continue
		}

		if _vim_strchr(transmute(cstring)(cmdline_val), C.int(b_at(flag, 0))) == nil {
			if include_orig_val && b_at(option_val, 1) == 0 &&
			b_at(flag, 0) == b_at(option_val, 0) {
				// This value is already used as the first choice as it's the
				// existing flag. Just skip it to avoid duplicate.
				continue
			}
			arr[count] = xmemdupz(transmute(rawptr)(flag), 1)
			count += 1
		}
	}

	if count == 0 {
		xfree(matches^)
		matches^ = nil
		return FAIL_S
	}
	numMatches^ = count
	return OK_S
}

completing_value_for_subopt_o :: proc "c"(args: rawptr, name_suffix: cstring) -> bool {
	xp := (^rawptr)(uintptr(args) + OET_XP_OFF)^
	pat := (^rawptr)(uintptr(xp) + XPP_PATTERN)^
	colon := (^u8)(uintptr(transmute(^u8)(pat)) - 1)
	set_arg := (^^u8)(uintptr(args) + OET_SET_ARG_OFF)^
	length := libc.strlen(name_suffix)

	if uintptr(transmute(^u8)(colon)) < uintptr(set_arg) {
		return false
	}
	return uintptr(transmute(^u8)(colon)) - uintptr(set_arg) >= uintptr(length) &&
		libc.strncmp(transmute(cstring)((^u8)(uintptr(transmute(^u8)(colon)) - uintptr(length))),
			name_suffix, length) == 0
}

@(export)
expand_set_str_generic :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	idx := (^C.int)(uintptr(args) + OET_IDX_OFF)^
	opt := opt_at(idx)
	return expand_set_opt_string_o(args, ([^]^u8)(opt.values), opt_values_len(opt), numMatches, matches)
}

@(export)
expand_set_chars_option :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	varp := (^rawptr)(uintptr(args) + OET_VARP_OFF)^
	win := curwin
	is_lcs := transmute(rawptr)(varp) == transmute(rawptr)(&p_lcs_g) ||
		transmute(rawptr)(varp) == transmute(rawptr)(uintptr(win) + 1200)
	if is_lcs {
		return expand_set_opt_generic_o(args, get_listchars_name, numMatches, matches)
	}
	return expand_set_opt_generic_o(args, get_fillchars_name, numMatches, matches)
}

@(export)
expand_set_concealcursor :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, transmute(^u8)(cstring(COCU_ALL_S)),
		numMatches, matches)
}

@(export)
expand_set_cpoptions :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, transmute(^u8)(cstring(CPO_VI_S)),
		numMatches, matches)
}

@(export)
expand_set_diffopt :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	xp := (^rawptr)(uintptr(args) + OET_XP_OFF)^
	pat := (^^u8)(uintptr(xp) + XPP_PATTERN)^
	set_arg := (^^u8)(uintptr(args) + OET_SET_ARG_OFF)^

	if uintptr(transmute(^u8)(pat)) > uintptr(set_arg) &&
	b_at((^u8)(uintptr(transmute(^u8)(pat)) - 1), 0) == ':' {
		if completing_value_for_subopt_o(args, "algorithm") {
			return expand_set_opt_string_o(args, &opt_dip_algorithm_values_g[0], 4,
				numMatches, matches)
		}
		if completing_value_for_subopt_o(args, "inline") {
			return expand_set_opt_string_o(args, &opt_dip_inline_values_g[0], 4,
				numMatches, matches)
		}
		return FAIL_S
	}

	return expand_set_str_generic(args, numMatches, matches)
}

@(export)
expand_set_encoding :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_generic_o(args, get_encoding_name_r, numMatches, matches)
}

@(export)
expand_set_eventignore :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	expand_eiw = (^rawptr)(uintptr(args) + OET_VARP_OFF)^ != transmute(rawptr)(&p_ei_g)
	return expand_set_opt_generic_o(args, get_eventignore_name, numMatches, matches)
}

@(export)
expand_set_formatoptions :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, transmute(^u8)(cstring(FO_ALL_S)),
		numMatches, matches)
}

@(export)
expand_set_mouse :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, transmute(^u8)(cstring(MOUSE_ALL_S)),
		numMatches, matches)
}

@(export)
expand_set_shortmess :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, &SHM_ALL_S[0], numMatches, matches)
}

@(export)
expand_set_whichwrap :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_listflag_o(args, transmute(^u8)(cstring(WW_ALL_S)),
		numMatches, matches)
}

@(export)
expand_set_winhighlight :: proc "c"(args: rawptr, numMatches: ^C.int, matches: ^rawptr) -> C.int {
	return expand_set_opt_generic_o(args, get_highlight_name_r, numMatches, matches)
}

// Function given to ExpandGeneric() to obtain the possible arguments of the
// fileformat options.
@(export)
get_fileformat_name :: proc "c"(xp: rawptr, idx: C.int) -> ^u8 {
	if idx >= 4 {
		return nil
	}
	return opt_ff_values_g[idx]
}

FCS_NAMES_S := [21]cstring{"stl", "stlnc", "wbr", "horiz", "horizup", "horizdown",
	"vert", "vertleft", "vertright", "verthoriz", "fold", "foldopen", "foldclose",
	"foldsep", "foldinner", "diff", "msgsep", "eob", "lastline", "trunc", "truncrl"}
LCS_NAMES_S := [12]cstring{"eol", "extends", "nbsp", "precedes", "space", "tab",
	"leadtab", "lead", "trail", "conceal", "multispace", "leadmultispace"}

// Function given to ExpandGeneric() to obtain possible arguments of the
// 'fillchars' option.
@(export)
get_fillchars_name :: proc "c"(xp: rawptr, idx: C.int) -> ^u8 {
	if idx < 0 || idx >= 21 {
		return nil
	}
	return transmute(^u8)(FCS_NAMES_S[idx])
}

// Function given to ExpandGeneric() to obtain possible arguments of the
// 'listchars' option.
@(export)
get_listchars_name :: proc "c"(xp: rawptr, idx: C.int) -> ^u8 {
	if idx < 0 || idx >= 12 {
		return nil
	}
	return transmute(^u8)(LCS_NAMES_S[idx])
}

@(export)
get_eventignore_name :: proc "c"(xp: rawptr, idx: C.int) -> ^u8 {
	pat := (^^u8)(uintptr(xp) + XPP_PATTERN)^
	subtract := b_at(pat, 0) == '-'
	// 'eventignore(win)' allows special keyword "all" in addition to
	// all event names.
	if !subtract && idx == 0 {
		return transmute(^u8)(cstring("all"))
	}

	name := get_event_name_no_group_r(xp, idx - 1 + (subtract ? 1 : 0), expand_eiw)
	if name == nil {
		return nil
	}

	p := &IObuff[0]
	if subtract {
		p^ = '-'
		p = (^u8)(uintptr(p) + 1)
	}
	libc.strcpy(p, transmute(cstring)(name))
	return &IObuff[0]
}

@(export)
check_ff_value :: proc "c"(p: ^u8) -> C.int {
	return opt_strings_flags_o(p, &opt_ff_values_g[0], nil, false)
}

// ── Batch 15: set_chars_option machinery (cutover) ───────────────────────────
// schar_T = u32. Lcs/Fcs structs mirrored field-for-field (probed offsets).
// C's static lcs_chars/fcs_chars scratch globals move here (no C reader
// outside optionstr.c); per-window w_p_lcs/fcs_chars stay in C structs.

LCS_TAB2_OFF :: 24
LCS_LEADTAB2_OFF :: 36
CP_NONE_OFF :: max(uintptr)

Lcs_Chars :: struct {
	eol:            u32,
	ext:            u32,
	prec:           u32,
	nbsp:           u32,
	space:          u32,
	tab1:           u32,
	tab2:           u32,
	tab3:           u32,
	leadtab1:       u32,
	leadtab2:       u32,
	leadtab3:       u32,
	lead:           u32,
	trail:          u32,
	multispace:     ^u32,
	leadmultispace: ^u32,
	conceal:        u32,
}

Fcs_Chars :: struct {
	stl:       u32,
	stlnc:     u32,
	wbr:       u32,
	horiz:     u32,
	horizup:   u32,
	horizdown: u32,
	vert:      u32,
	vertleft:  u32,
	vertright: u32,
	verthoriz: u32,
	fold:      u32,
	foldopen:  u32,
	foldclose: u32,
	foldsep:   u32,
	foldinner: u32,
	diff:      u32,
	msgsep:    u32,
	eob:       u32,
	lastline:  u32,
	trunc:     u32,
	truncrl:   u32,
}

#assert(size_of(Lcs_Chars) == 80)
#assert(size_of(Fcs_Chars) == 84)

@(private="file")
lcs_chars_g: Lcs_Chars
@(private="file")
fcs_chars_g: Fcs_Chars

// chars_tab entry: cp as field offset (CP_NONE = NULL), NUL-terminated name
// + optional default/fallback literals (nil cstring = C NULL).
Chars_Tab_Entry :: struct {
	off:      uintptr,
	name:     cstring,
	def:      cstring,
	fallback: cstring,
}

LCS_TAB_S := [12]Chars_Tab_Entry{
	{0, "eol", nil, nil},
	{4, "extends", nil, nil},
	{8, "nbsp", nil, nil},
	{12, "precedes", nil, nil},
	{16, "space", nil, nil},
	{24, "tab", nil, nil},
	{36, "leadtab", nil, nil},
	{44, "lead", nil, nil},
	{48, "trail", nil, nil},
	{72, "conceal", nil, nil},
	{CP_NONE_OFF, "multispace", nil, nil},
	{CP_NONE_OFF, "leadmultispace", nil, nil},
}

FCS_TAB_S := [21]Chars_Tab_Entry{
	{0, "stl", " ", nil},
	{4, "stlnc", " ", nil},
	{8, "wbr", " ", nil},
	{12, "horiz", "─", "-"},
	{16, "horizup", "┴", "-"},
	{20, "horizdown", "┬", "-"},
	{24, "vert", "│", "|"},
	{28, "vertleft", "┤", "|"},
	{32, "vertright", "├", "|"},
	{36, "verthoriz", "┼", "+"},
	{40, "fold", "·", "-"},
	{44, "foldopen", "-", nil},
	{48, "foldclose", "+", nil},
	{52, "foldsep", "│", "|"},
	{56, "foldinner", nil, nil},
	{60, "diff", "-", nil},
	{64, "msgsep", " ", nil},
	{68, "eob", "~", nil},
	{72, "lastline", "@", nil},
	{76, "trunc", ">", nil},
	{80, "truncrl", "<", nil},
}

E834_S :: "E834: Conflicts with value of 'listchars'"
E835_S :: "E835: Conflicts with value of 'fillchars'"
E1572_S :: "E1572: 'listchars' field \"leadtab\" requires \"tab\" to be specified"

W_P_LCS_CHARS_OFF :: 200
W_P_FCS_CHARS_OFF :: 280

foreign _ {
	@(link_name = "schar_from_str")
	schar_from_str_r :: proc "c" (str: cstring) -> u32 ---
	@(link_name = "schar_from_char")
	schar_from_char_r :: proc "c" (c: C.int) -> u32 ---
	@(link_name = "hexhex2nr")
	hexhex2nr_r :: proc "c" (p: cstring) -> C.int ---
	@(link_name = "utfc_ptr2schar")
	utfc_ptr2schar_r :: proc "c" (p: cstring, firstc: ^C.int) -> u32 ---
}
// char2cells/ptr2cells/utfc_ptr2len reused; E1511_S/E1512_S exist.

field_value_err_o :: proc "c"(errbuf: ^u8, errbuflen: C.size_t, fmt: cstring, name: cstring) -> ^u8 {
	if errbuf == nil {
		return transmute(^u8)(cstring(""))
	}
	libc.snprintf(errbuf, errbuflen, fmt, rawptr(transmute(^u8)(name)))
	return errbuf
}

// Calls mb_cptr2char_adv(p) and returns the character.
// If "p" starts with "\x", "\u" or "\U" the hex or unicode value is used.
// Returns 0 for invalid hex or invalid UTF-8 byte.
get_encoded_char_adv_o :: proc "c"(pp: ^^u8) -> u32 {
	s := pp^

	if b_at(s, 0) == '\\' && (b_at(s, 1) == 'x' || b_at(s, 1) == 'u' || b_at(s, 1) == 'U') {
		num: i64 = 0
		nbytes := b_at(s, 1) == 'x' ? 1 : b_at(s, 1) == 'u' ? 2 : 4
		for nbytes > 0 {
			nbytes -= 1
			pp^ = (^u8)(uintptr(pp^) + 2)
			n := hexhex2nr_r(transmute(cstring)(pp^))
			if n < 0 {
				return 0
			}
			num = num * 256 + i64(n)
		}
		pp^ = (^u8)(uintptr(pp^) + 2)
		return u32(char2cells(C.int(num)) > 1 ? 0 : i64(schar_from_char_r(C.int(num))))
	}

	clen := utfc_ptr2len(transmute(cstring)(s))
	firstc: C.int = 0
	c := utfc_ptr2schar_r(transmute(cstring)(s), &firstc)
	pp^ = (^u8)(uintptr(pp^) + uintptr(clen))
	// Invalid UTF-8 byte or doublewidth not allowed
	if (clen == 1 && firstc > 127) || char2cells(firstc) > 1 {
		return 0
	}
	return c
}

// Handle setting 'listchars' or 'fillchars'. Assume monocell characters.
@(export)
set_chars_option :: proc "c"(wp: rawptr, value_in: ^u8, what: C.int, apply: bool,
errbuf: ^u8, errbuflen: C.size_t) -> cstring {
	value := value_in
	last_multispace: ^u8 = nil // Last occurrence of "multispace:"
	last_lmultispace: ^u8 = nil // Last occurrence of "leadmultispace:"
	multispace_len: C.int = 0 // Length of lcs-multispace string
	lead_multispace_len: C.int = 0 // Length of lcs-leadmultispace string

	is_lcs := what == kListchars_E
	base := uintptr(&lcs_chars_g)
	tab: []Chars_Tab_Entry
	entries: C.int
	if is_lcs {
		tab = LCS_TAB_S[:]
		entries = 12
		if b_at((^^u8)(uintptr(wp) + 1200)^, 0) == 0 {
			value = p_lcs_g // local value is empty, use the global value
		}
	} else {
		base = uintptr(&fcs_chars_g)
		tab = FCS_TAB_S[:]
		entries = 21
		if b_at((^^u8)(uintptr(wp) + 1208)^, 0) == 0 {
			value = p_fcs_g // local value is empty, use the global value
		}
	}

	// first round: check for valid value, second round: assign values
	rounds: C.int = apply ? 1 : 0
	for round: C.int = 0; round <= rounds; round += 1 {
		has_tab := false
		has_leadtab := false

		if round > 0 {
			// After checking that the value is valid: set defaults
			for i: C.int = 0; i < entries; i += 1 {
				if tab[i].off != CP_NONE_OFF {
					// XXX: Characters taking 2 columns is forbidden (TUI limitation?).
					// Set old defaults in this case.
					fp := (^u32)(base + tab[i].off)
					if tab[i].def != nil && ptr2cells(transmute(cstring)(tab[i].def)) == 1 {
						fp^ = schar_from_str_r(tab[i].def)
					} else if tab[i].fallback != nil {
						fp^ = schar_from_str_r(tab[i].fallback)
					} else {
						fp^ = schar_from_str_r(transmute(cstring)(tab[i].def))
					}
				}
			}

			if is_lcs {
				lcs_chars_g.tab1 = 0
				lcs_chars_g.tab3 = 0
				lcs_chars_g.leadtab1 = 0
				lcs_chars_g.leadtab3 = 0

				if multispace_len > 0 {
					lcs_chars_g.multispace = (^u32)(xmalloc_sp(C.size_t(multispace_len + 1) * 4))
					([^]u32)(lcs_chars_g.multispace)[multispace_len] = 0
				} else {
					lcs_chars_g.multispace = nil
				}

				if lead_multispace_len > 0 {
					lcs_chars_g.leadmultispace = (^u32)(xmalloc_sp(C.size_t(lead_multispace_len + 1) * 4))
					([^]u32)(lcs_chars_g.leadmultispace)[lead_multispace_len] = 0
				} else {
					lcs_chars_g.leadmultispace = nil
				}
			}
		}

		p := value
		for b_at(p, 0) != 0 {
			i: C.int = 0
			for ; i < entries; i += 1 {
				nlen := libc.strlen(tab[i].name)
				if !(libc.strncmp(transmute(cstring)(p), tab[i].name,
				C.size_t(nlen)) == 0 &&
				b_at(p, C.int(nlen)) == ':') {
					continue
				}

				s := (^u8)(uintptr(p) + uintptr(nlen) + 1)

				if is_lcs && libc.strcmp(tab[i].name, "multispace") == 0 {
					if round == 0 {
						// Get length of lcs-multispace string in the first round
						last_multispace = p
						multispace_len = 0
						for b_at(s, 0) != 0 && b_at(s, 0) != ',' {
							c1 := get_encoded_char_adv_o(&s)
							if c1 == 0 {
								return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
									cstring(E1512_S), tab[i].name))
							}
							multispace_len += 1
						}
						if multispace_len == 0 {
							// lcs-multispace cannot be an empty string
							return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
								cstring(E1511_S), tab[i].name))
						}
					} else {
						multispace_pos: C.int = 0
						for b_at(s, 0) != 0 && b_at(s, 0) != ',' {
							c1 := get_encoded_char_adv_o(&s)
							if p == last_multispace {
								([^]u32)(lcs_chars_g.multispace)[multispace_pos] = c1
								multispace_pos += 1
							}
						}
					}
					p = s
					break
				}

				if is_lcs && libc.strcmp(tab[i].name, "leadmultispace") == 0 {
					if round == 0 {
						// Get length of lcs-leadmultispace string in first round
						last_lmultispace = p
						lead_multispace_len = 0
						for b_at(s, 0) != 0 && b_at(s, 0) != ',' {
							c1 := get_encoded_char_adv_o(&s)
							if c1 == 0 {
								return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
									cstring(E1512_S), tab[i].name))
							}
							lead_multispace_len += 1
						}
						if lead_multispace_len == 0 {
							// lcs-leadmultispace cannot be an empty string
							return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
								cstring(E1511_S), tab[i].name))
						}
					} else {
						multispace_pos: C.int = 0
						for b_at(s, 0) != 0 && b_at(s, 0) != ',' {
							c1 := get_encoded_char_adv_o(&s)
							if p == last_lmultispace {
								([^]u32)(lcs_chars_g.leadmultispace)[multispace_pos] = c1
								multispace_pos += 1
							}
						}
					}
					p = s
					break
				}

				if b_at(s, 0) == 0 {
					return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
						cstring(E1511_S), tab[i].name))
				}
				c1 := get_encoded_char_adv_o(&s)
				if c1 == 0 {
					return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
						cstring(E1512_S), tab[i].name))
				}
				c2: u32 = 0
				c3: u32 = 0
				// NOTE: offsets are per-struct; qualify with is_lcs since
				// fcs fields share offsets (e.g. vert@24 == tab2@24).
				is_tab := is_lcs && tab[i].off == LCS_TAB2_OFF
				is_leadtab := is_lcs && tab[i].off == LCS_LEADTAB2_OFF
				if is_tab || is_leadtab {
					if b_at(s, 0) == 0 {
						return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
							cstring(E1511_S), tab[i].name))
					}
					c2 = get_encoded_char_adv_o(&s)
					if c2 == 0 {
						return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
							cstring(E1512_S), tab[i].name))
					}
					if !(b_at(s, 0) == ',' || b_at(s, 0) == 0) {
						c3 = get_encoded_char_adv_o(&s)
						if c3 == 0 {
							return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
								cstring(E1512_S), tab[i].name))
						}
				}
				if is_tab {
					has_tab = true
				} else if is_leadtab {
					has_leadtab = true
				}
			}

			if b_at(s, 0) == ',' || b_at(s, 0) == 0 {
				if round > 0 {
					if is_tab {
						lcs_chars_g.tab1 = c1
						lcs_chars_g.tab2 = c2
						lcs_chars_g.tab3 = c3
					} else if is_leadtab {
						lcs_chars_g.leadtab1 = c1
						lcs_chars_g.leadtab2 = c2
						lcs_chars_g.leadtab3 = c3
					} else if tab[i].off != CP_NONE_OFF {
						(^u32)(base + tab[i].off)^ = c1
					}
				}
					p = s
					break
				} else {
					return transmute(cstring)(field_value_err_o(errbuf, errbuflen,
						cstring(E1511_S), tab[i].name))
				}
			}

			if i == entries {
				return cstring("E474: Invalid argument")
			}

			if b_at(p, 0) == ',' {
				p = (^u8)(uintptr(p) + 1)
			}
		}

		if is_lcs && has_leadtab && !has_tab {
			return cstring(E1572_S)
		}
	}

	if apply {
		if is_lcs {
			xfree((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + 56)^)
			xfree((^rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF + 64)^)
			libc.memcpy(transmute(rawptr)(uintptr(wp) + W_P_LCS_CHARS_OFF),
				transmute(rawptr)(&lcs_chars_g), size_of(Lcs_Chars))
		} else {
			libc.memcpy(transmute(rawptr)(uintptr(wp) + W_P_FCS_CHARS_OFF),
				transmute(rawptr)(&fcs_chars_g), size_of(Fcs_Chars))
		}
	}

	return nil // no error
}

@(export)
check_chars_options :: proc "c"() -> cstring {
	if set_chars_option(curwin, p_lcs_g, kListchars_E, false, nil, 0) != nil {
		return cstring(E834_S)
	}
	if set_chars_option(curwin, p_fcs_g, kFillchars_E, false, nil, 0) != nil {
		return cstring(E835_S)
	}
	tp := first_tabpage
	for tp != nil {
		wp := (^rawptr)(uintptr(tp) + 40)^
		for wp != nil {
			if set_chars_option(wp, (^^u8)(uintptr(wp) + 1200)^, kListchars_E, true, nil, 0) != nil {
				return cstring(E834_S)
			}
			if set_chars_option(wp, (^^u8)(uintptr(wp) + 1208)^, kFillchars_E, true, nil, 0) != nil {
				return cstring(E835_S)
			}
			wp = (^rawptr)(uintptr(wp) + 112)^
		}
		tp = (^rawptr)(uintptr(tp) + 8)^
	}
	return nil
}
