package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// profile.c port: profiling (proftime_T arithmetic, :profile command,
// function/script line timing, --startuptime report).
// proftime_T itself is shell.odin's u64 alias — reused directly.

foreign _ {
	// ex_breakadd — PORTED (debugger.odin).
	@(link_name = "setvbuf")
	setvbuf_e :: proc "c" (stream: rawptr, buf: rawptr, mode: C.int, size: C.size_t) -> C.int ---
	// time_fd is EXTERN in globals.h, defined by main.c.o — C retains it.
	@(link_name = "time_fd")
	time_fd: rawptr
}

PROF_PAUSED :: 2 // globals.h (PROF_NONE=0/YES=1 in shell.odin)
EXPAND_PROFILE :: 35 // cmdexpand_defs.h (cc-probed)
VV_PROFILING_O :: 37 // eval_defs.h (cc-probed)
K_SPECIAL_O :: 0x80 // keycodes.h
_IOFBF_O :: 0 // stdio.h (Linux)

E750_S :: "E750: First use \":profile start {fname}\""

// ufunc_T profiling offsets not already in userfunc.odin (all cc-probed).
UF_TML_START_OFF_O :: 152
UF_TML_WAIT_OFF_O :: 168
UF_TML_IDX_OFF_O :: 176
UF_TML_EXECED_OFF_O :: 180
// funccall_T.fc_prof_child (cc-probed; FC_FUNC_OFF_O=0 reused).
FC_PROF_CHILD_OFF_O :: 2032

// scriptitem_T profiling field offsets (cc-probed).
SI_NAME_OFF_O :: 8
SI_LUA_OFF_O :: 16
SI_PROF_ON_OFF_O :: 17
SI_PR_FORCE_OFF_O :: 18
SI_PR_CHILD_OFF_O :: 24
SI_PR_NEST_OFF_O :: 32
SI_PR_COUNT_OFF_O :: 36
SI_PR_TOTAL_OFF_O :: 40
SI_PR_SELF_OFF_O :: 48
SI_PR_START_OFF_O :: 56
SI_PR_CHILDREN_OFF_O :: 64
SI_PRL_GA_OFF_O :: 72
SI_PRL_START_OFF_O :: 96
SI_PRL_CHILDREN_OFF_O :: 104
SI_PRL_WAIT_OFF_O :: 112
SI_PRL_IDX_OFF_O :: 120
SI_PRL_EXECED_OFF_O :: 124

// sn_prl_T: {snp_count int@0, total u64@8, self u64@16} = 24B.
Sn_Prl_T :: struct {
	snp_count: C.int,
	_pad:      [4]u8,
	total:     proftime_T,
	self:      proftime_T,
}
#assert(size_of(Sn_Prl_T) == 24)

// --startuptime stream (see foreign time_fd above).

@(private = "file")
prof_wait_time_g: proftime_T
@(private = "file")
startuptime_buf_g: [8193]u8
@(private = "file")
profile_fname_g: cstring
@(private = "file")
profile_pause_time_g: proftime_T
@(private = "file")
wait_time_g: proftime_T
@(private = "file")
g_start_time_g: proftime_T
@(private = "file")
g_prev_time_g: proftime_T
@(private = "file")
pexpand_what_g: C.int
@(private = "file")
pexpand_cmds_g: [8]cstring = {"continue", "dump", "file", "func", "pause", "start", "stop", nil}
@(private = "file")
profile_msg_buf_g: [50]u8

// Gets the current time.
@(export)
profile_start :: proc "c" () -> proftime_T {
	context = runtime.default_context()
	return os_hrtime()
}

// Elapsed time from tm until now.
@(export)
profile_end :: proc "c" (tm: proftime_T) -> proftime_T {
	context = runtime.default_context()
	return profile_sub(os_hrtime(), tm)
}

// "seconds.microseconds" rendering (static buf, not multithread-safe).
@(export)
profile_msg :: proc "c" (tm: proftime_T) -> cstring {
	context = runtime.default_context()
	libc.snprintf(([^]u8)(&profile_msg_buf_g[0]), 50, cstring("%10.6lf"), f64(profile_signed(tm)) / 1000000000.0)
	return transmute(cstring)(&profile_msg_buf_g[0])
}

// Time msec into the future (zero time when msec <= 0).
@(export)
profile_setlimit :: proc "c" (msec: C.longlong) -> proftime_T {
	context = runtime.default_context()
	if msec <= 0 {
		return profile_zero()
	}
	if !(msec <= C.longlong(max(i64)) / 1000000 - 1) {
		libc.abort()
	}
	nsec := proftime_T(msec) * 1000000
	return os_hrtime() + nsec
}

// True when current time has passed tm (false when timer unset).
@(export)
profile_passed_limit :: proc "c" (tm: proftime_T) -> bool {
	context = runtime.default_context()
	if tm == 0 {
		return false
	}
	return profile_cmp(os_hrtime(), tm) < 0
}

@(export)
profile_zero :: proc "c" () -> proftime_T {
	context = runtime.default_context()
	return 0
}

@(export)
profile_divide :: proc "c" (tm: proftime_T, count: C.int) -> proftime_T {
	context = runtime.default_context()
	if count <= 0 {
		return profile_zero()
	}
	// C round() is round-half-away; tm/count >= 0 so +0.5 truncation matches.
	return proftime_T(f64(tm) / f64(count) + 0.5)
}

@(export)
profile_add :: proc "c" (tm1: proftime_T, tm2: proftime_T) -> proftime_T {
	context = runtime.default_context()
	return tm1 + tm2
}

@(export)
profile_sub :: proc "c" (tm1: proftime_T, tm2: proftime_T) -> proftime_T {
	context = runtime.default_context()
	return tm1 - tm2
}

@(export)
profile_self :: proc "c" (self: proftime_T, total: proftime_T, children: proftime_T) -> proftime_T {
	context = runtime.default_context()
	if total <= children {
		return self
	}
	return profile_sub(profile_add(self, total), children)
}

profile_get_wait_o :: proc "c" () -> proftime_T {
	context = runtime.default_context()
	return prof_wait_time_g
}

// Sets the current waittime.
@(export)
profile_set_wait :: proc "c" (wait: proftime_T) {
	context = runtime.default_context()
	prof_wait_time_g = wait
}

// tma - (waittime - tm).
@(export)
profile_sub_wait :: proc "c" (tm: proftime_T, tma: proftime_T) -> proftime_T {
	context = runtime.default_context()
	tm3 := profile_sub(profile_get_wait_o(), tm)
	return profile_sub(tma, tm3)
}

profile_equal_o :: proc "c" (tm1: proftime_T, tm2: proftime_T) -> bool {
	context = runtime.default_context()
	return tm1 == tm2
}

// Signed duration (wraparound-aware per #10452).
@(export)
profile_signed :: proc "c" (tm: proftime_T) -> i64 {
	context = runtime.default_context()
	if tm <= u64(max(i64)) {
		return i64(tm)
	}
	return -i64(max(u64) - tm)
}

// <0: tm2<tm1, 0: equal, >0: tm2>tm1.
@(export)
profile_cmp :: proc "c" (tm1: proftime_T, tm2: proftime_T) -> C.int {
	context = runtime.default_context()
	if tm1 == tm2 {
		return 0
	}
	if profile_signed(tm2 - tm1) < 0 {
		return -1
	}
	return 1
}

// Reset all profiling information.
@(export)
profile_reset :: proc "c" () {
	context = runtime.default_context()
	for id: C.int = 1; id <= script_items_g.ga_len; id += 1 {
		si := ([^]rawptr)(script_items_g.ga_data)[uintptr(id - 1)]
		if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ {
			(^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ = false
			(^bool)(uintptr(si) + SI_PR_FORCE_OFF_O)^ = false
			(^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^ = profile_zero()
			(^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^ = 0
			(^C.int)(uintptr(si) + SI_PR_COUNT_OFF_O)^ = 0
			(^proftime_T)(uintptr(si) + SI_PR_TOTAL_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(si) + SI_PR_SELF_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(si) + SI_PR_START_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(si) + SI_PR_CHILDREN_OFF_O)^ = profile_zero()
			ga_clear((^Garray)(uintptr(si) + SI_PRL_GA_OFF_O))
			(^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(si) + SI_PRL_CHILDREN_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(si) + SI_PRL_WAIT_OFF_O)^ = profile_zero()
			(^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ = -1
			(^C.int)(uintptr(si) + SI_PRL_EXECED_OFF_O)^ = 0
		}
	}
	todo := func_hashtab.ht_used
	hi := func_hashtab.ht_array
	for ; todo > 0; hi = rawptr(uintptr(hi) + uintptr(HASHITEM_SIZE_O)) {
		key := (^rawptr)(uintptr(hi) + HI_KEY_OFF_O)^
		if key == nil || key == transmute(rawptr)(&hash_removed) {
			continue
		}
		todo -= 1
		fp := rawptr(uintptr(key) - uintptr(UF_NAME_OFF_O))
		if (^bool)(uintptr(fp) + UF_PROF_INIT_OFF_O)^ {
			(^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ = 0
			(^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^ = 0
			(^proftime_T)(uintptr(fp) + UF_TM_TOTAL_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(fp) + UF_TM_SELF_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(fp) + UF_TM_CHILDREN_OFF_O)^ = profile_zero()
			n := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
			cnt := ([^]C.int)((^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^)
			tot := ([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^)
			sel := ([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^)
			for i: C.int = 0; i < n; i += 1 {
				cnt[i] = 0
				tot[i] = 0
				sel[i] = 0
			}
			(^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(fp) + UF_TML_CHILDREN_OFF_O)^ = profile_zero()
			(^proftime_T)(uintptr(fp) + UF_TML_WAIT_OFF_O)^ = profile_zero()
			(^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ = -1
			(^C.int)(uintptr(fp) + UF_TML_EXECED_OFF_O)^ = 0
		}
	}
	xfree(rawptr(profile_fname_g))
	profile_fname_g = nil
}

// ":profile cmd args".
@(export)
ex_profile :: proc "c" (eap: rawptr) {
	context = runtime.default_context()
	arg := (^cstring)(uintptr(eap) + EXARG_ARG_OFF)^
	e := skiptowhite(transmute(cstring)(arg))
	len := C.int(uintptr(rawptr(e)) - uintptr(rawptr(arg)))
	e = skipwhite(e)
	if len == 5 && libc.strncmp(arg, cstring("start"), 5) == 0 && ([^]u8)(rawptr(e))[0] != 0 {
		xfree(rawptr(profile_fname_g))
		profile_fname_g = expand_env_save_opt(transmute(cstring)(e), true, nil)
		do_profiling = PROF_YES
		profile_set_wait(profile_zero())
		set_vim_var_nr(VV_PROFILING_O, 1)
	} else if do_profiling == PROF_NONE {
		emsg(_t(cstring(E750_S)))
	} else if libc.strcmp(arg, cstring("stop")) == 0 {
		profile_dump()
		do_profiling = PROF_NONE
		set_vim_var_nr(VV_PROFILING_O, 0)
		profile_reset()
	} else if libc.strcmp(arg, cstring("pause")) == 0 {
		if do_profiling == PROF_YES {
			profile_pause_time_g = profile_start()
		}
		do_profiling = PROF_PAUSED
	} else if libc.strcmp(arg, cstring("continue")) == 0 {
		if do_profiling == PROF_PAUSED {
			profile_pause_time_g = profile_end(profile_pause_time_g)
			profile_set_wait(profile_add(profile_get_wait_o(), profile_pause_time_g))
		}
		do_profiling = PROF_YES
	} else if libc.strcmp(arg, cstring("dump")) == 0 {
		profile_dump()
	} else {
		ex_breakadd(eap)
	}
}

// Function given to ExpandGeneric() for :profile completion.
@(export)
get_profile_name :: proc "c" (xp: ^expand_T, idx: C.int) -> cstring {
	context = runtime.default_context()
	if pexpand_what_g == 0 {
		return pexpand_cmds_g[idx]
	}
	return nil
}

// Command line completion for :profile.
@(export)
set_context_in_profile_cmd :: proc "c" (xp: ^expand_T, arg: cstring) {
	context = runtime.default_context()
	xp.xp_context = EXPAND_PROFILE
	pexpand_what_g = 0
	xp.xp_pattern = arg
	end_subcmd := skiptowhite(arg)
	if ([^]u8)(rawptr(end_subcmd))[0] == 0 {
		return
	}
	sublen := C.int(uintptr(rawptr(end_subcmd)) - uintptr(rawptr(arg)))
	if (sublen == 5 && libc.strncmp(arg, cstring("start"), 5) == 0) || (sublen == 4 && libc.strncmp(arg, cstring("file"), 4) == 0) {
		xp.xp_context = EXPAND_FILES
		xp.xp_pattern = skipwhite(end_subcmd)
		return
	} else if sublen == 4 && libc.strncmp(arg, cstring("func"), 4) == 0 {
		xp.xp_context = EXPAND_USER_FUNC_O
		xp.xp_pattern = skipwhite(end_subcmd)
		return
	}
	xp.xp_context = EXPAND_NOTHING_S
}

// Called when starting to wait for user input.
@(export)
prof_input_start :: proc "c" () {
	context = runtime.default_context()
	wait_time_g = profile_start()
}

// Called when finished waiting for user input.
@(export)
prof_input_end :: proc "c" () {
	context = runtime.default_context()
	wait_time_g = profile_end(wait_time_g)
	profile_set_wait(profile_add(profile_get_wait_o(), wait_time_g))
}

// True when a function in the current script should be profiled.
@(export)
prof_def_func :: proc "c" () -> bool {
	context = runtime.default_context()
	if current_sctx_sc_sid() > 0 {
		si := ([^]rawptr)(script_items_g.ga_data)[uintptr(current_sctx_sc_sid() - 1)]
		return (^bool)(uintptr(si) + SI_PR_FORCE_OFF_O)^
	}
	return false
}

// Print count and times for one function or function line.
prof_func_line_o :: proc "c" (fd: rawptr, count: C.int, total: ^proftime_T, self: ^proftime_T, prefer_self: bool) {
	context = runtime.default_context()
	f := (^libc.FILE)(fd)
	if count > 0 {
		libc.fprintf(f, cstring("%5d "), count)
		if prefer_self && profile_equal_o(total^, self^) {
			libc.fprintf(f, cstring("           "))
		} else {
			libc.fprintf(f, cstring("%s "), profile_msg(total^))
		}
		if !prefer_self && profile_equal_o(total^, self^) {
			libc.fprintf(f, cstring("           "))
		} else {
			libc.fprintf(f, cstring("%s "), profile_msg(self^))
		}
	} else {
		libc.fprintf(f, cstring("                            "))
	}
}

prof_sort_list_o :: proc "c" (fd: rawptr, sorttab: [^]rawptr, st_len: C.int, title: cstring, prefer_self: bool) {
	context = runtime.default_context()
	f := (^libc.FILE)(fd)
	libc.fprintf(f, cstring("FUNCTIONS SORTED ON %s TIME\n"), title)
	libc.fprintf(f, cstring("count  total (s)   self (s)  function\n"))
	for i: C.int = 0; i < 20 && i < st_len; i += 1 {
		fp := sorttab[i]
		prof_func_line_o(fd, (^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^, (^proftime_T)(uintptr(fp) + UF_TM_TOTAL_OFF_O), (^proftime_T)(uintptr(fp) + UF_TM_SELF_OFF_O), prefer_self)
		if ([^]u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O))[0] == u8(K_SPECIAL_O) {
			libc.fprintf(f, cstring(" <SNR>%s()\n"), transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O + 3)))
		} else {
			libc.fprintf(f, cstring(" %s()\n"), transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
		}
	}
	libc.fprintf(f, cstring("\n"))
}

prof_total_cmp_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	p1 := (^rawptr)(s1)^
	p2 := (^rawptr)(s2)^
	return profile_cmp((^proftime_T)(uintptr(p1) + UF_TM_TOTAL_OFF_O)^, (^proftime_T)(uintptr(p2) + UF_TM_TOTAL_OFF_O)^)
}

prof_self_cmp_o :: proc "c" (s1: rawptr, s2: rawptr) -> C.int {
	context = runtime.default_context()
	p1 := (^rawptr)(s1)^
	p2 := (^rawptr)(s2)^
	return profile_cmp((^proftime_T)(uintptr(p1) + UF_TM_SELF_OFF_O)^, (^proftime_T)(uintptr(p2) + UF_TM_SELF_OFF_O)^)
}

// Start profiling function fp.
@(export)
func_do_profile :: proc "c" (fp: rawptr) {
	context = runtime.default_context()
	len := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
	if !(^bool)(uintptr(fp) + UF_PROF_INIT_OFF_O)^ {
		if len == 0 {
			len = 1
		}
		(^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^ = 0
		(^proftime_T)(uintptr(fp) + UF_TM_SELF_OFF_O)^ = profile_zero()
		(^proftime_T)(uintptr(fp) + UF_TM_TOTAL_OFF_O)^ = profile_zero()
		if (^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^ == nil {
			(^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^ = xcalloc(C.size_t(len), C.size_t(size_of(C.int)))
		}
		if (^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^ == nil {
			(^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^ = xcalloc(C.size_t(len), C.size_t(size_of(proftime_T)))
		}
		if (^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^ == nil {
			(^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^ = xcalloc(C.size_t(len), C.size_t(size_of(proftime_T)))
		}
		(^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ = -1
		(^bool)(uintptr(fp) + UF_PROF_INIT_OFF_O)^ = true
	}
	(^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ = 1
}

// Prepare profiling for entering a child (pairs with prof_child_exit).
@(export)
prof_child_enter :: proc "c" (tm: ^proftime_T) {
	context = runtime.default_context()
	fc := get_current_funccal()
	if fc != nil && (^bool)(uintptr((^rawptr)(fc)^) + UF_PROFILING_OFF_O)^ {
		(^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^ = profile_start()
	}
	script_prof_save(tm)
}

// Account time spent in a child (after prof_child_enter).
@(export)
prof_child_exit :: proc "c" (tm: ^proftime_T) {
	context = runtime.default_context()
	fc := get_current_funccal()
	if fc != nil && (^bool)(uintptr((^rawptr)(fc)^) + UF_PROFILING_OFF_O)^ {
		fp := (^rawptr)(fc)^
		(^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^ = profile_end((^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^)
		(^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^ = profile_sub_wait(tm^, (^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^)
		(^proftime_T)(uintptr(fp) + UF_TM_CHILDREN_OFF_O)^ = profile_add((^proftime_T)(uintptr(fp) + UF_TM_CHILDREN_OFF_O)^, (^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^)
		(^proftime_T)(uintptr(fp) + UF_TML_CHILDREN_OFF_O)^ = profile_add((^proftime_T)(uintptr(fp) + UF_TML_CHILDREN_OFF_O)^, (^proftime_T)(uintptr(fc) + FC_PROF_CHILD_OFF_O)^)
	}
	script_prof_restore(tm)
}

// Called when starting to read a function line.
@(export)
func_line_start :: proc "c" (cookie: rawptr) {
	context = runtime.default_context()
	fcp := cookie
	fp := (^rawptr)(fcp)^
	lnum := sourcing_lnum_o()
	nlines := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
	if (^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ != 0 && lnum >= 1 && lnum <= nlines {
		(^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ = lnum - 1
		for (^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ > 0 && funcline_at_o(fp, (^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^) == nil {
			(^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ -= 1
		}
		(^C.int)(uintptr(fp) + UF_TML_EXECED_OFF_O)^ = 0
		(^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^ = profile_start()
		(^proftime_T)(uintptr(fp) + UF_TML_CHILDREN_OFF_O)^ = profile_zero()
		(^proftime_T)(uintptr(fp) + UF_TML_WAIT_OFF_O)^ = profile_get_wait_o()
	}
}

// Called when actually executing a function line.
@(export)
func_line_exec :: proc "c" (cookie: rawptr) {
	context = runtime.default_context()
	fcp := cookie
	fp := (^rawptr)(fcp)^
	if (^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ != 0 && (^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ >= 0 {
		(^C.int)(uintptr(fp) + UF_TML_EXECED_OFF_O)^ = 1
	}
}

// Called when done with a function line.
@(export)
func_line_end :: proc "c" (cookie: rawptr) {
	context = runtime.default_context()
	fcp := cookie
	fp := (^rawptr)(fcp)^
	if (^C.int)(uintptr(fp) + UF_PROFILING_OFF_O)^ != 0 && (^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ >= 0 {
		if (^C.int)(uintptr(fp) + UF_TML_EXECED_OFF_O)^ != 0 {
			idx := (^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^
			([^]C.int)((^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^)[idx] += 1
			(^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^ = profile_end((^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^)
			(^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^ = profile_sub_wait((^proftime_T)(uintptr(fp) + UF_TML_WAIT_OFF_O)^, (^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^)
			tot := ([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^)
			tot[idx] = profile_add(tot[idx], (^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^)
			sel := ([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^)
			sel[idx] = profile_self(sel[idx], (^proftime_T)(uintptr(fp) + UF_TML_START_OFF_O)^, (^proftime_T)(uintptr(fp) + UF_TML_CHILDREN_OFF_O)^)
		}
		(^C.int)(uintptr(fp) + UF_TML_IDX_OFF_O)^ = -1
	}
}

// FUNCLINE(fp, i): ga_data[i] or nil.
funcline_at_o :: proc "c" (fp: rawptr, i: C.int) -> rawptr {
	context = runtime.default_context()
	return ([^]rawptr)((^rawptr)(uintptr(fp) + UF_LINES_OFF_O + 16)^)[uintptr(i)]
}

// Dump profiling results for all functions to fd.
func_dump_profile_o :: proc "c" (fd: rawptr) {
	context = runtime.default_context()
	f := (^libc.FILE)(fd)
	st_len: C.int = 0
	todo := func_hashtab.ht_used
	if todo == 0 {
		return
	}
	sorttab := ([^]rawptr)(xmalloc(C.size_t(size_of(rawptr)) * todo))
	hi := func_hashtab.ht_array
	for ; todo > 0; hi = rawptr(uintptr(hi) + uintptr(HASHITEM_SIZE_O)) {
		key := (^rawptr)(uintptr(hi) + HI_KEY_OFF_O)^
		if key == nil || key == transmute(rawptr)(&hash_removed) {
			continue
		}
		todo -= 1
		fp := rawptr(uintptr(key) - uintptr(UF_NAME_OFF_O))
		if !(^bool)(uintptr(fp) + UF_PROF_INIT_OFF_O)^ {
			continue
		}
		sorttab[st_len] = fp
		st_len += 1
		if ([^]u8)(rawptr(uintptr(fp) + UF_NAME_OFF_O))[0] == u8(K_SPECIAL_O) {
			libc.fprintf(f, cstring("FUNCTION  <SNR>%s()\n"), transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O + 3)))
		} else {
			libc.fprintf(f, cstring("FUNCTION  %s()\n"), transmute(cstring)(rawptr(uintptr(fp) + UF_NAME_OFF_O)))
		}
		if (^C.int)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O)^ != 0 {
			should_free := false
			ctx := (^sctx_T)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O)^
			p := get_scriptname_e(ctx, &should_free)
			libc.fprintf(f, cstring("    Defined: %s:%d\n"), p, (^C.int)(uintptr(fp) + UF_SCRIPT_CTX_OFF_O + 8)^)
			if should_free {
				xfree(rawptr(p))
			}
		}
		if (^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^ == 1 {
			libc.fprintf(f, cstring("Called 1 time\n"))
		} else {
			libc.fprintf(f, cstring("Called %d times\n"), (^C.int)(uintptr(fp) + UF_TM_COUNT_OFF_O)^)
		}
		libc.fprintf(f, cstring("Total time: %s\n"), profile_msg((^proftime_T)(uintptr(fp) + UF_TM_TOTAL_OFF_O)^))
		libc.fprintf(f, cstring(" Self time: %s\n"), profile_msg((^proftime_T)(uintptr(fp) + UF_TM_SELF_OFF_O)^))
		libc.fprintf(f, cstring("\n"))
		libc.fprintf(f, cstring("count  total (s)   self (s)\n"))
		n := (^C.int)(uintptr(fp) + UF_LINES_OFF_O)^
		for i: C.int = 0; i < n; i += 1 {
			if funcline_at_o(fp, i) == nil {
				continue
			}
			prof_func_line_o(fd, ([^]C.int)((^rawptr)(uintptr(fp) + UF_TML_COUNT_OFF_O)^)[i], &([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_TOTAL_OFF_O)^)[i], &([^]proftime_T)((^rawptr)(uintptr(fp) + UF_TML_SELF_OFF_O)^)[i], true)
			libc.fprintf(f, cstring("%s\n"), transmute(cstring)(funcline_at_o(fp, i)))
		}
		libc.fprintf(f, cstring("\n"))
	}
	if st_len > 0 {
		qsort_e(rawptr(sorttab), C.size_t(st_len), C.size_t(size_of(rawptr)), prof_total_cmp_o)
		prof_sort_list_o(fd, sorttab, st_len, cstring("TOTAL"), false)
		qsort_e(rawptr(sorttab), C.size_t(st_len), C.size_t(size_of(rawptr)), prof_self_cmp_o)
		prof_sort_list_o(fd, sorttab, st_len, cstring("SELF"), true)
	}
	xfree(rawptr(sorttab))
}

// Start profiling a script.
@(export)
profile_init :: proc "c" (si: rawptr) {
	context = runtime.default_context()
	(^C.int)(uintptr(si) + SI_PR_COUNT_OFF_O)^ = 0
	(^proftime_T)(uintptr(si) + SI_PR_TOTAL_OFF_O)^ = profile_zero()
	(^proftime_T)(uintptr(si) + SI_PR_SELF_OFF_O)^ = profile_zero()
	ga_init((^Garray)(uintptr(si) + SI_PRL_GA_OFF_O), C.int(size_of(Sn_Prl_T)), 100)
	(^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ = -1
	(^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ = true
	(^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^ = 0
}

// Save time when starting to invoke another script or function.
@(export)
script_prof_save :: proc "c" (tm: ^proftime_T) {
	context = runtime.default_context()
	sid := current_sctx_sc_sid()
	if sid > 0 && sid <= script_items_g.ga_len {
		si := ([^]rawptr)(script_items_g.ga_data)[uintptr(sid - 1)]
		if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ {
			nest := (^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^
			(^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^ = nest + 1
			if nest == 0 {
				(^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^ = profile_start()
			}
		}
	}
	tm^ = profile_get_wait_o()
}

// Count time spent in children after invoking another script or function.
@(export)
script_prof_restore :: proc "c" (tm: ^proftime_T) {
	context = runtime.default_context()
	sid := current_sctx_sc_sid()
	if !(sid > 0 && sid <= script_items_g.ga_len) {
		return
	}
	si := ([^]rawptr)(script_items_g.ga_data)[uintptr(sid - 1)]
	if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ {
		nest := (^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^ - 1
		(^C.int)(uintptr(si) + SI_PR_NEST_OFF_O)^ = nest
		if nest == 0 {
			(^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^ = profile_end((^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^)
			(^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^ = profile_sub_wait(tm^, (^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^)
			(^proftime_T)(uintptr(si) + SI_PR_CHILDREN_OFF_O)^ = profile_add((^proftime_T)(uintptr(si) + SI_PR_CHILDREN_OFF_O)^, (^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^)
			(^proftime_T)(uintptr(si) + SI_PRL_CHILDREN_OFF_O)^ = profile_add((^proftime_T)(uintptr(si) + SI_PRL_CHILDREN_OFF_O)^, (^proftime_T)(uintptr(si) + SI_PR_CHILD_OFF_O)^)
		}
	}
}

// Dump profiling results for all scripts to fd.
script_dump_profile_o :: proc "c" (fd: rawptr) {
	context = runtime.default_context()
	f := (^libc.FILE)(fd)
	for id: C.int = 1; id <= script_items_g.ga_len; id += 1 {
		si := ([^]rawptr)(script_items_g.ga_data)[uintptr(id - 1)]
		if !(^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ {
			continue
		}
		libc.fprintf(f, cstring("SCRIPT  %s\n"), transmute(cstring)((^rawptr)(uintptr(si) + SI_NAME_OFF_O)^))
		if (^C.int)(uintptr(si) + SI_PR_COUNT_OFF_O)^ == 1 {
			libc.fprintf(f, cstring("Sourced 1 time\n"))
		} else {
			libc.fprintf(f, cstring("Sourced %d times\n"), (^C.int)(uintptr(si) + SI_PR_COUNT_OFF_O)^)
		}
		libc.fprintf(f, cstring("Total time: %s\n"), profile_msg((^proftime_T)(uintptr(si) + SI_PR_TOTAL_OFF_O)^))
		libc.fprintf(f, cstring(" Self time: %s\n"), profile_msg((^proftime_T)(uintptr(si) + SI_PR_SELF_OFF_O)^))
		libc.fprintf(f, cstring("\n"))
		libc.fprintf(f, cstring("count  total (s)   self (s)\n"))
		sfd := os_fopen(transmute(cstring)((^rawptr)(uintptr(si) + SI_NAME_OFF_O)^), cstring("r"))
		if sfd == nil {
			libc.fprintf(f, cstring("Cannot open file!\n"))
		} else {
			i: C.int = 0
			for {
				if vim_fgets(&IObuff[0], IOSIZE_O, sfd) != 0 {
					break
				}
				if ([^]u8)(&IObuff[0])[IOSIZE_O - 2] != 0 && ([^]u8)(&IObuff[0])[IOSIZE_O - 2] != 10 {
					n := IOSIZE_O - 2
					for n > 0 && (([^]u8)(&IObuff[0])[n] & 0xc0) == 0x80 {
						n -= 1
					}
					([^]u8)(&IObuff[0])[n] = 10
					([^]u8)(&IObuff[0])[n + 1] = 0
				}
				ga := (^Garray)(uintptr(si) + SI_PRL_GA_OFF_O)
				pp: ^Sn_Prl_T = nil
				if i < ga.ga_len {
					pp = &([^]Sn_Prl_T)((^rawptr)(uintptr(si) + SI_PRL_GA_OFF_O + 16)^)[uintptr(i)]
					if pp.snp_count <= 0 {
						pp = nil
					}
				}
				if pp != nil {
					libc.fprintf(f, cstring("%5d "), pp.snp_count)
					if profile_equal_o(pp.total, pp.self) {
						libc.fprintf(f, cstring("           "))
					} else {
						libc.fprintf(f, cstring("%s "), profile_msg(pp.total))
					}
					libc.fprintf(f, cstring("%s "), profile_msg(pp.self))
				} else {
					libc.fprintf(f, cstring("                            "))
				}
				libc.fprintf(f, cstring("%s"), transmute(cstring)(&IObuff[0]))
				i += 1
			}
			libc.fclose((^libc.FILE)(sfd))
		}
		libc.fprintf(f, cstring("\n"))
	}
}

// Dump the profiling info to profile_fname (no-op when unset).
@(export)
profile_dump :: proc "c" () {
	context = runtime.default_context()
	if profile_fname_g == nil {
		return
	}
	fd := os_fopen(profile_fname_g, cstring("w"))
	if fd == nil {
		semsg(cstring(E_NOTOPEN_S), profile_fname_g)
	} else {
		script_dump_profile_o(fd)
		func_dump_profile_o(fd)
		libc.fclose((^libc.FILE)(fd))
	}
}

// Called when starting to read a script line.
@(export)
script_line_start :: proc "c" () {
	context = runtime.default_context()
	sid := current_sctx_sc_sid()
	if sid <= 0 || sid > script_items_g.ga_len {
		return
	}
	si := ([^]rawptr)(script_items_g.ga_data)[uintptr(sid - 1)]
	if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ && sourcing_lnum_o() >= 1 {
		ga := (^Garray)(uintptr(si) + SI_PRL_GA_OFF_O)
		ga_grow(ga, sourcing_lnum_o() - ga.ga_len)
		(^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ = sourcing_lnum_o() - 1
		for ga.ga_len <= (^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ && ga.ga_len < ga.ga_maxlen {
			pp := &([^]Sn_Prl_T)((^rawptr)(uintptr(si) + SI_PRL_GA_OFF_O + 16)^)[uintptr(ga.ga_len)]
			pp.snp_count = 0
			pp.total = profile_zero()
			pp.self = profile_zero()
			ga.ga_len += 1
		}
		(^C.int)(uintptr(si) + SI_PRL_EXECED_OFF_O)^ = 0
		(^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^ = profile_start()
		(^proftime_T)(uintptr(si) + SI_PRL_CHILDREN_OFF_O)^ = profile_zero()
		(^proftime_T)(uintptr(si) + SI_PRL_WAIT_OFF_O)^ = profile_get_wait_o()
	}
}

// Called when actually executing a script line.
@(export)
script_line_exec :: proc "c" () {
	context = runtime.default_context()
	sid := current_sctx_sc_sid()
	if sid <= 0 || sid > script_items_g.ga_len {
		return
	}
	si := ([^]rawptr)(script_items_g.ga_data)[uintptr(sid - 1)]
	if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ && (^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ >= 0 {
		(^C.int)(uintptr(si) + SI_PRL_EXECED_OFF_O)^ = 1
	}
}

// Called when done with a script line.
@(export)
script_line_end :: proc "c" () {
	context = runtime.default_context()
	sid := current_sctx_sc_sid()
	if sid <= 0 || sid > script_items_g.ga_len {
		return
	}
	si := ([^]rawptr)(script_items_g.ga_data)[uintptr(sid - 1)]
	ga := (^Garray)(uintptr(si) + SI_PRL_GA_OFF_O)
	if (^bool)(uintptr(si) + SI_PROF_ON_OFF_O)^ && (^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ >= 0 && (^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ < ga.ga_len {
		if (^C.int)(uintptr(si) + SI_PRL_EXECED_OFF_O)^ != 0 {
			pp := &([^]Sn_Prl_T)((^rawptr)(uintptr(si) + SI_PRL_GA_OFF_O + 16)^)[uintptr((^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^)]
			pp.snp_count += 1
			(^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^ = profile_end((^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^)
			(^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^ = profile_sub_wait((^proftime_T)(uintptr(si) + SI_PRL_WAIT_OFF_O)^, (^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^)
			pp.total = profile_add(pp.total, (^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^)
			pp.self = profile_self(pp.self, (^proftime_T)(uintptr(si) + SI_PRL_START_OFF_O)^, (^proftime_T)(uintptr(si) + SI_PRL_CHILDREN_OFF_O)^)
		}
		(^C.int)(uintptr(si) + SI_PRL_IDX_OFF_O)^ = -1
	}
}

// Saves previous time before something that could nest.
@(export)
time_push :: proc "c" (rel: ^proftime_T, start: ^proftime_T) {
	context = runtime.default_context()
	now := profile_start()
	rel^ = profile_sub(now, g_prev_time_g)
	start^ = now
	g_prev_time_g = now
}

// Restores prev time after something that could nest.
@(export)
time_pop :: proc "c" (tp: proftime_T) {
	context = runtime.default_context()
	g_prev_time_g -= tp
}

time_diff_o :: proc "c" (then: proftime_T, now: proftime_T) {
	context = runtime.default_context()
	diff := profile_sub(now, then)
	libc.fprintf((^libc.FILE)(time_fd), cstring("%07.3lf"), f64(diff) / 1.0E6)
}

// Initializes the startuptime report (no-op when time_fd is NULL).
@(export)
time_start :: proc "c" (message: cstring) {
	context = runtime.default_context()
	if time_fd == nil {
		return
	}
	g_prev_time_g = profile_start()
	g_start_time_g = g_prev_time_g
	libc.fprintf((^libc.FILE)(time_fd), cstring("\ntimes in msec\n"))
	libc.fprintf((^libc.FILE)(time_fd), cstring(" clock   self+sourced   self:  sourced script\n"))
	libc.fprintf((^libc.FILE)(time_fd), cstring(" clock   elapsed:              other lines\n\n"))
	time_msg(message, nil)
}

// Prints timing info to the startuptime report.
@(export)
time_msg :: proc "c" (mesg: cstring, start: ^proftime_T) {
	context = runtime.default_context()
	if time_fd == nil {
		return
	}
	now := profile_start()
	time_diff_o(g_start_time_g, now)
	if start != nil {
		libc.fprintf((^libc.FILE)(time_fd), cstring("  "))
		time_diff_o(start^, now)
	}
	libc.fprintf((^libc.FILE)(time_fd), cstring("  "))
	time_diff_o(g_prev_time_g, now)
	g_prev_time_g = now
	libc.fprintf((^libc.FILE)(time_fd), cstring(": %s\n"), mesg)
}

// Opens the --startuptime report stream.
@(export)
time_init :: proc "c" (fname: cstring, proc_name: cstring) {
	context = runtime.default_context()
	time_fd = rawptr(libc.fopen(fname, cstring("a")))
	if time_fd == nil {
		libc.fprintf(libc.stderr, cstring(E_NOTOPEN_S), fname)
		return
	}
	r := setvbuf_e(time_fd, rawptr(&startuptime_buf_g[0]), _IOFBF_O, 8193)
	if r != 0 {
		time_fd = nil
		libc.fprintf(libc.stderr, cstring("time_init: setvbuf failed: %d %s"), r, uv_err_name(r))
		return
	}
	libc.fprintf((^libc.FILE)(time_fd), cstring("--- Startup times for process: %s ---\n"), proc_name)
}

// Flushes the startuptimes to disk.
@(export)
time_finish :: proc "c" () {
	context = runtime.default_context()
	if time_fd == nil {
		return
	}
	time_msg(cstring("--- NVIM STARTED ---\n"), nil)
	libc.fclose((^libc.FILE)(time_fd))
	time_fd = nil
}
