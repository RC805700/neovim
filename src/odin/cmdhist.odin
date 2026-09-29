package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// cmdhist.c port: command-line history tables.
// All 17 publics are @(export); C statics are file-privates / _o plains.

foreign _ {
	@(link_name = "p_hi")
	p_hi: C.longlong // OptInt 'history'
	@(link_name = "maptick")
	maptick: C.int
	@(link_name = "get_cmdline_firstc")
	get_cmdline_firstc_e :: proc "c" () -> C.int ---
	@(link_name = "get_list_range")
	get_list_range_e :: proc "c" (str: ^^u8, num1: ^C.int, num2: ^C.int) -> C.int ---
}

HIST_DEFAULT :: -2
HIST_INVALID :: -1
HIST_CMD :: 0
// HIST_SEARCH :: 1 — search.odin, reuse.
HIST_EXPR :: 2
HIST_INPUT :: 3
HIST_DEBUG :: 4
HIST_COUNT :: 5

IOSIZE_CH :: 1025

E1510_CH_S :: "E1510: Value too large: %s"

// histentry_T mirror (cc-probed): size 40, hisnum@0, hisstr@8,
// hisstrlen@16, timestamp@24, additional_data@32.
Histentry_T :: struct {
	hisnum:          C.int,
	_pad:            [4]u8,
	hisstr:          cstring,
	hisstrlen:       C.size_t,
	timestamp:       Timestamp,
	additional_data: rawptr,
}
#assert(size_of(Histentry_T) == 40)

@(private = "file")
history_g: [HIST_COUNT][^]Histentry_T
@(private = "file")
hisidx_g: [HIST_COUNT]C.int = {-1, -1, -1, -1, -1}
@(private = "file")
hisnum_g: [HIST_COUNT]C.int
@(private = "file")
hislen_g: C.int
@(private = "file")
last_maptick_g: C.int = -1
@(private = "file")
history_names_g: [6]cstring = {"cmd", "search", "expr", "input", "debug", nil}
@(private = "file")
short_names_ch_g: [6]u8 = {':', '=', '@', '>', '?', '/'}
// NUL-terminated ": =@>?/" for vim_strchr (takes ^u8).
@(private = "file")
hist_chars_g: [7]u8 = {':', '=', '@', '>', '?', '/', 0}

// Return the length of the history tables.
@(export)
get_hislen :: proc "c" () -> C.int {
	context = runtime.default_context()
	return hislen_g
}

// Return a pointer to a specified history table.
@(export)
get_histentry :: proc "c" (hist_type: C.int) -> ^Histentry_T {
	context = runtime.default_context()
	return history_g[hist_type]
}

@(export)
set_histentry :: proc "c" (hist_type: C.int, entry: ^Histentry_T) {
	context = runtime.default_context()
	history_g[hist_type] = entry
}

@(export)
get_hisidx :: proc "c" (hist_type: C.int) -> ^C.int {
	context = runtime.default_context()
	return &hisidx_g[hist_type]
}

@(export)
get_hisnum :: proc "c" (hist_type: C.int) -> ^C.int {
	context = runtime.default_context()
	return &hisnum_g[hist_type]
}

// Translate a history character to the associated type number.
@(export)
hist_char2type :: proc "c" (c: C.int) -> C.int {
	context = runtime.default_context()
	switch c {
	case ':':
		return HIST_CMD
	case '=':
		return HIST_EXPR
	case '@':
		return HIST_INPUT
	case '>':
		return HIST_DEBUG
	case 0, '/', '?':
		return HIST_SEARCH
	case:
		return HIST_INVALID
	}
}

// Function given to ExpandGeneric() for ":history" first-arg completion.
@(export)
get_history_arg :: proc "c" (xp: ^expand_T, idx: C.int) -> cstring {
	context = runtime.default_context()
	short_names_count: C.int = 6
	history_name_count: C.int = 5
	if idx < short_names_count {
		xp.xp_buf[0] = i8(short_names_ch_g[idx])
		xp.xp_buf[1] = 0
		return transmute(cstring)(&xp.xp_buf[0])
	}
	if idx < short_names_count + history_name_count {
		return history_names_g[idx - short_names_count]
	}
	if idx == short_names_count + history_name_count {
		return cstring("all")
	}
	return nil
}

// Initialize command line history (also re-allocates when size changes).
@(export)
init_history :: proc "c" () {
	context = runtime.default_context()
	if !(p_hi >= 0 && p_hi <= C.longlong(max(C.int))) {
		libc.abort()
	}
	newlen: C.int = C.int(p_hi)
	oldlen := hislen_g
	if newlen == oldlen {
		return
	}
	for type_: C.int = 0; type_ < HIST_COUNT; type_ += 1 {
		temp: ^Histentry_T = nil
		if newlen > 0 {
			temp = (^Histentry_T)(xmalloc(C.size_t(newlen) * size_of(Histentry_T)))
		}
		j := hisidx_g[type_]
		if j >= 0 {
			l1 := min(j + 1, newlen)
			l2 := min(newlen, oldlen) - l1
			i1 := j + 1 - l1
			i2 := max(l1, oldlen - newlen + l1)
			if newlen != 0 {
				libc.memcpy(rawptr(&([^]Histentry_T)(temp)[0]), rawptr(&history_g[type_][i2]), C.size_t(l2) * size_of(Histentry_T))
				libc.memcpy(rawptr(&([^]Histentry_T)(temp)[l2]), rawptr(&history_g[type_][i1]), C.size_t(l1) * size_of(Histentry_T))
			}
			for i: C.int = 0; i < i1; i += 1 {
				hist_free_entry_o(&history_g[type_][i])
			}
			for i := i1 + l1; i < i2; i += 1 {
				hist_free_entry_o(&history_g[type_][i])
			}
		}
		l3: C.int = 0
		if j >= 0 {
			l3 = min(newlen, oldlen)
		}
		if newlen > 0 {
			libc.memset(rawptr(&([^]Histentry_T)(temp)[l3]), 0, C.size_t(newlen - l3) * size_of(Histentry_T))
		}
		hisidx_g[type_] = l3 - 1
		xfree(rawptr(history_g[type_]))
		history_g[type_] = ([^]Histentry_T)(temp)
	}
	hislen_g = newlen
}

hist_free_entry_o :: proc "c" (hisptr: ^Histentry_T) {
	context = runtime.default_context()
	xfree(rawptr(hisptr.hisstr))
	xfree(hisptr.additional_data)
	clear_hist_entry_o(hisptr)
}

clear_hist_entry_o :: proc "c" (hisptr: ^Histentry_T) {
	context = runtime.default_context()
	hisptr^ = {}
}

// Check if 'str' is already in history; move to front when asked.
in_history_o :: proc "c" (type_: C.int, str: cstring, move_to_front: C.int, sep: C.int) -> C.int {
	context = runtime.default_context()
	last_i: C.int = -1
	if hisidx_g[type_] < 0 {
		return 0
	}
	i := hisidx_g[type_]
	for {
		if history_g[type_][i].hisstr == nil {
			return 0
		}
		p := history_g[type_][i].hisstr
		if libc.strcmp(str, p) == 0 && (type_ != HIST_SEARCH || C.int(([^]u8)(rawptr(p))[history_g[type_][i].hisstrlen + 1]) == sep) {
			if move_to_front == 0 {
				return 1
			}
			last_i = i
			break
		}
		i -= 1
		if i < 0 {
			i = hislen_g - 1
		}
		if i == hisidx_g[type_] {
			break
		}
	}
	if last_i < 0 {
		return 0
	}
	ad := history_g[type_][i].additional_data
	save_hisstr := history_g[type_][i].hisstr
	save_hisstrlen := history_g[type_][i].hisstrlen
	for i != hisidx_g[type_] {
		i += 1
		if i >= hislen_g {
			i = 0
		}
		history_g[type_][last_i] = history_g[type_][i]
		last_i = i
	}
	xfree(ad)
	hisnum_g[type_] += 1
	history_g[type_][i].hisnum = hisnum_g[type_]
	history_g[type_][i].hisstr = save_hisstr
	history_g[type_][i].hisstrlen = save_hisstrlen
	history_g[type_][i].timestamp = os_time()
	history_g[type_][i].additional_data = nil
	return 1
}

// Convert history name to its HIST_ equivalent.
get_histtype_o :: proc "c" (name: cstring, len: C.size_t, return_default: bool) -> C.int {
	context = runtime.default_context()
	if len == 0 {
		if return_default {
			return HIST_DEFAULT
		}
		return hist_char2type(get_cmdline_firstc_e())
	}
	for i: C.int = 0; history_names_g[i] != nil; i += 1 {
		if strncasecmp(name, history_names_g[i], len) == 0 {
			return i
		}
	}
	if vim_strchr(&hist_chars_g[0], C.int(([^]u8)(rawptr(name))[0])) != nil && len == 1 {
		return hist_char2type(C.int(([^]u8)(rawptr(name))[0]))
	}
	return HIST_INVALID
}

// Add the given string to the given history (moves existing to front).
@(export)
add_to_history :: proc "c" (histype: C.int, new_entry: cstring, new_entrylen: C.size_t, in_map: bool, sep: C.int) {
	context = runtime.default_context()
	if hislen_g == 0 || histype == HIST_INVALID {
		return
	}
	if histype == HIST_DEFAULT {
		libc.abort()
	}
	if (cmdmod_cmod_flags & CMOD_KEEPPATTERNS) != 0 && histype == HIST_SEARCH {
		return
	}
	if histype == HIST_SEARCH && in_map {
		if maptick == last_maptick_g && hisidx_g[HIST_SEARCH] >= 0 {
			hisptr := &history_g[HIST_SEARCH][hisidx_g[HIST_SEARCH]]
			hist_free_entry_o(hisptr)
			hisnum_g[histype] -= 1
			hisidx_g[HIST_SEARCH] -= 1
			if hisidx_g[HIST_SEARCH] < 0 {
				hisidx_g[HIST_SEARCH] = hislen_g - 1
			}
		}
		last_maptick_g = -1
	}
	if in_history_o(histype, new_entry, 1, sep) != 0 {
		return
	}
	hisidx_g[histype] += 1
	if hisidx_g[histype] == hislen_g {
		hisidx_g[histype] = 0
	}
	hisptr := &history_g[histype][hisidx_g[histype]]
	hist_free_entry_o(hisptr)
	hisptr.hisstr = transmute(cstring)(xstrnsave_c(new_entry, new_entrylen + 2))
	hisptr.timestamp = os_time()
	hisptr.additional_data = nil
	([^]u8)(rawptr(hisptr.hisstr))[new_entrylen + 1] = u8(sep)
	hisptr.hisstrlen = new_entrylen
	hisnum_g[histype] += 1
	hisptr.hisnum = hisnum_g[histype]
	if histype == HIST_SEARCH && in_map {
		last_maptick_g = maptick
	}
}

// Get identifier of newest history entry.
get_history_idx_o :: proc "c" (histype: C.int) -> C.int {
	context = runtime.default_context()
	if hislen_g == 0 || histype < 0 || histype >= HIST_COUNT || hisidx_g[histype] < 0 {
		return -1
	}
	return history_g[histype][hisidx_g[histype]].hisnum
}

// Calculate history index from a number.
calc_hist_idx_o :: proc "c" (histype: C.int, num: C.int) -> C.int {
	context = runtime.default_context()
	i: C.int
	if hislen_g == 0 || histype < 0 || histype >= HIST_COUNT {
		return -1
	}
	i = hisidx_g[histype]
	if i < 0 || num == 0 {
		return -1
	}
	hist := history_g[histype]
	if num > 0 {
		wrapped := false
		for hist[i].hisnum > num {
			i -= 1
			if i < 0 {
				if wrapped {
					break
				}
				i += hislen_g
				wrapped = true
			}
		}
		if i >= 0 && hist[i].hisnum == num && hist[i].hisstr != nil {
			return i
		}
	} else if -num <= hislen_g {
		i += num + 1
		if i < 0 {
			i += hislen_g
		}
		if hist[i].hisstr != nil {
			return i
		}
	}
	return -1
}

// Clear all entries in a history.
@(export)
clr_history :: proc "c" (histype: C.int) -> C.int {
	context = runtime.default_context()
	if hislen_g != 0 && histype >= 0 && histype < HIST_COUNT {
		hisptr := history_g[histype]
		i := hislen_g
		for ; i > 0; i -= 1 {
			hist_free_entry_o(hisptr)
			hisptr = (^Histentry_T)(uintptr(hisptr) + size_of(Histentry_T))
		}
		hisidx_g[histype] = -1
		hisnum_g[histype] = 0
		return OK_E
	}
	return FAIL_E
}

// Remove all entries matching {str} from a history.
del_history_entry_o :: proc "c" (histype: C.int, str: cstring) -> C.int {
	context = runtime.default_context()
	if hislen_g == 0 || histype < 0 || histype >= HIST_COUNT || ([^]u8)(rawptr(str))[0] == 0 || hisidx_g[histype] < 0 {
		return 0
	}
	idx := hisidx_g[histype]
	regmatch: Regmatch_T
	regmatch.regprog = vim_regcomp(str, RE_MAGIC + RE_STRING_O)
	if regmatch.regprog == nil {
		return 0
	}
	regmatch.rm_ic = 0
	found := false
	i := idx
	last := idx
	for {
		hisptr := &history_g[histype][i]
		if hisptr.hisstr == nil {
			break
		}
		if vim_regexec_r(&regmatch, transmute(^u8)(hisptr.hisstr), 0) != 0 {
			found = true
			hist_free_entry_o(hisptr)
		} else {
			if i != last {
				history_g[histype][last] = hisptr^
				clear_hist_entry_o(hisptr)
			}
			last -= 1
			if last < 0 {
				last += hislen_g
			}
		}
		i -= 1
		if i < 0 {
			i += hislen_g
		}
		if i == idx {
			break
		}
	}
	if history_g[histype][idx].hisstr == nil {
		hisidx_g[histype] = -1
	}
	vim_regfree(regmatch.regprog)
	if found {
		return 1
	}
	return 0
}

// Remove an indexed entry from a history.
del_history_idx_o :: proc "c" (histype: C.int, idx_in: C.int) -> C.int {
	context = runtime.default_context()
	i := calc_hist_idx_o(histype, idx_in)
	if i < 0 {
		return 0
	}
	idx := hisidx_g[histype]
	hist_free_entry_o(&history_g[histype][i])
	if histype == HIST_SEARCH && maptick == last_maptick_g && i == idx {
		last_maptick_g = -1
	}
	for i != idx {
		j := (i + 1) % hislen_g
		history_g[histype][i] = history_g[histype][j]
		i = j
	}
	clear_hist_entry_o(&history_g[histype][idx])
	i -= 1
	if i < 0 {
		i += hislen_g
	}
	hisidx_g[histype] = i
	return 1
}

// "histadd()" function.
@(export)
f_histadd :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	rettv.vval = transmute(rawptr)(C.longlong(0))
	if check_secure() {
		return
	}
	a0 := (([^]Typval_T)(argvars))[0]
	str := tv_get_string_chk(&a0)
	histype: C.int = HIST_INVALID
	if str != nil {
		histype = get_histtype_o(str, libc.strlen(str), false)
	}
	if histype == HIST_INVALID {
		return
	}
	buf: [NUMBUFLEN]u8
	a1 := (([^]Typval_T)(argvars))[1]
	str = tv_get_string_buf(&a1, &buf[0])
	if ([^]u8)(rawptr(str))[0] == 0 {
		return
	}
	init_history()
	add_to_history(histype, str, libc.strlen(str), false, 0)
	rettv.vval = transmute(rawptr)(C.longlong(1))
}

// "histdel()" function.
@(export)
f_histdel :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	n: C.int
	a0 := (([^]Typval_T)(argvars))[0]
	str := tv_get_string_chk(&a0)
	if str == nil {
		n = 0
	} else if (([^]Typval_T)(argvars))[1].v_type == VAR_UNKNOWN {
		n = clr_history(get_histtype_o(str, libc.strlen(str), false))
	} else if (([^]Typval_T)(argvars))[1].v_type == VAR_NUMBER {
		a1 := (([^]Typval_T)(argvars))[1]
		n = del_history_idx_o(get_histtype_o(str, libc.strlen(str), false), C.int(tv_get_number(&a1)))
	} else {
		buf: [NUMBUFLEN]u8
		a1 := (([^]Typval_T)(argvars))[1]
		n = del_history_entry_o(get_histtype_o(str, libc.strlen(str), false), transmute(cstring)(tv_get_string_buf(&a1, &buf[0])))
	}
	rettv.vval = transmute(rawptr)(C.longlong(n))
}

// "histget()" function.
@(export)
f_histget :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (([^]Typval_T)(argvars))[0]
	str := tv_get_string_chk(&a0)
	if str == nil {
		rettv.vval = nil
	} else {
		idx: C.int
		type_ := get_histtype_o(str, libc.strlen(str), false)
		if (([^]Typval_T)(argvars))[1].v_type == VAR_UNKNOWN {
			idx = get_history_idx_o(type_)
		} else {
			a1 := (([^]Typval_T)(argvars))[1]
			idx = C.int(tv_get_number_chk(&a1, nil))
		}
		idx = calc_hist_idx_o(type_, idx)
		if idx < 0 {
			rettv.vval = transmute(rawptr)(xstrnsave_c(cstring(""), 0))
		} else {
			rettv.vval = transmute(rawptr)(xstrnsave_c(history_g[type_][idx].hisstr, history_g[type_][idx].hisstrlen))
		}
	}
	rettv.v_type = VAR_STRING
}

// "histnr()" function.
@(export)
f_histnr :: proc "c" (argvars: ^Typval_T, rettv: ^Typval_T, fptr: rawptr) {
	context = runtime.default_context()
	a0 := (([^]Typval_T)(argvars))[0]
	histname := tv_get_string_chk(&a0)
	i: C.int = HIST_INVALID
	if histname != nil {
		i = get_histtype_o(histname, libc.strlen(histname), false)
	}
	if i != HIST_INVALID {
		rettv.vval = transmute(rawptr)(C.longlong(get_history_idx_o(i)))
	} else {
		rettv.vval = transmute(rawptr)(C.longlong(HIST_INVALID))
	}
}

// :history command - print a history.
@(export)
ex_history :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	histype1: C.int = HIST_CMD
	histype2: C.int = HIST_CMD
	hisidx1: C.int = 1
	hisidx2: C.int = -1
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	msg_ext_set_kind(cstring("list_cmd"))
	if hislen_g == 0 {
		msg_msg(_t(cstring("'history' option is zero")), 0)
		return
	}
	end := transmute(^u8)(arg)
	if !(ascii_isdigit(([^]u8)(end)[0]) || ([^]u8)(end)[0] == '-' || ([^]u8)(end)[0] == ',') {
		for ascii_isalpha_o(([^]u8)(end)[0]) || vim_strchr(&hist_chars_g[0], C.int(([^]u8)(end)[0])) != nil {
			end = (^u8)(uintptr(end) + 1)
		}
		histype1 = get_histtype_o(transmute(cstring)(arg), C.size_t(uintptr(end) - uintptr(rawptr(arg))), false)
		if histype1 == HIST_INVALID {
			if strncasecmp(transmute(cstring)(arg), cstring("all"), C.size_t(uintptr(end) - uintptr(rawptr(arg)))) == 0 {
				histype1 = 0
				histype2 = HIST_COUNT - 1
			} else {
				semsg(cstring(E488_S), arg)
				return
			}
		} else {
			histype2 = histype1
		}
	}
	if get_list_range_e(&end, &hisidx1, &hisidx2) == 0 || ([^]u8)(end)[0] != 0 {
		if ([^]u8)(end)[0] != 0 {
			semsg(cstring(E488_S), transmute(cstring)(end))
		} else {
			semsg(cstring(E1510_CH_S), arg)
		}
		return
	}
	for ; got_int == false && histype1 <= histype2; histype1 += 1 {
		libc.snprintf(([^]u8)(&IObuff[0]), IOSIZE_CH, cstring("\n      #  %s history"), history_names_g[histype1])
		msg_puts_title(transmute(cstring)(&IObuff[0]))
		idx := hisidx_g[histype1]
		hist := history_g[histype1]
		j := hisidx1
		k := hisidx2
		if j < 0 {
			if -j > hislen_g {
				j = 0
			} else {
				j = hist[(hislen_g + j + idx + 1) % hislen_g].hisnum
			}
		}
		if k < 0 {
			if -k > hislen_g {
				k = 0
			} else {
				k = hist[(hislen_g + k + idx + 1) % hislen_g].hisnum
			}
		}
		if idx >= 0 && j <= k {
			i := idx + 1
			for {
				if i == hislen_g {
					i = 0
				}
				if hist[i].hisstr != nil && hist[i].hisnum >= j && hist[i].hisnum <= k && !message_filtered(hist[i].hisstr) {
					msg_putchar('\n')
					shown: C.int = ' '
					if i == idx {
						shown = '>'
					}
					n := C.int(libc.snprintf(([^]u8)(&IObuff[0]), IOSIZE_CH, cstring("%c%6d  "), shown, hist[i].hisnum))
					if vim_strsize(hist[i].hisstr) > Columns - 10 {
						trunc_string_e(hist[i].hisstr, (^u8)(uintptr(rawptr(&IObuff[0])) + uintptr(n)), Columns - 10, IOSIZE_CH - n)
					} else {
						xstrlcpy(transmute(cstring)(rawptr(uintptr(rawptr(&IObuff[0])) + uintptr(n))), hist[i].hisstr, C.size_t(IOSIZE_CH - n))
					}
					msg_outtrans(transmute(cstring)(&IObuff[0]), 0, false)
				}
				if i == idx {
					break
				}
				i += 1
				if got_int {
					break
				}
			}
		}
	}
}

// Iterate over history items.
@(export)
hist_iter :: proc "c" (iter: rawptr, history_type: u8, zero: bool, hist: ^Histentry_T) -> rawptr {
	context = runtime.default_context()
	hist^ = {}
	if hisidx_g[history_type] == -1 {
		return nil
	}
	hstart := history_g[history_type]
	hlast := (^Histentry_T)(uintptr(history_g[history_type]) + uintptr(hisidx_g[history_type]) * size_of(Histentry_T))
	hend := (^Histentry_T)(uintptr(history_g[history_type]) + uintptr(hislen_g - 1) * size_of(Histentry_T))
	hiter: ^Histentry_T
	if iter == nil {
		hfirst := hlast
		for {
			hfirst = (^Histentry_T)(uintptr(hfirst) + size_of(Histentry_T))
			if uintptr(hfirst) > uintptr(hend) {
				hfirst = hstart
			}
			if hfirst.hisstr != nil {
				break
			}
			if hfirst == hlast {
				break
			}
		}
		hiter = hfirst
	} else {
		hiter = (^Histentry_T)(iter)
	}
	if hiter == nil {
		return nil
	}
	hist^ = hiter^
	if zero {
		hiter^ = {}
	}
	if hiter == hlast {
		return nil
	}
	hiter = (^Histentry_T)(uintptr(hiter) + size_of(Histentry_T))
	if uintptr(hiter) > uintptr(hend) {
		return rawptr(hstart)
	}
	return rawptr(hiter)
}

// Get array of history items.
@(export)
hist_get_array :: proc "c" (history_type: u8, new_hisidx: ^^C.int, new_hisnum: ^^C.int) -> ^Histentry_T {
	context = runtime.default_context()
	init_history()
	new_hisidx^ = &hisidx_g[history_type]
	new_hisnum^ = &hisnum_g[history_type]
	return history_g[history_type]
}
