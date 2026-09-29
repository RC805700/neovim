package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// linematch.c port: diff-block line-match tensor algorithm.
// Only 2 publics (both @(export)); the rest are _o plains (C-statics).
// Sole C caller is diff.c (ABI-compat only); zero Odin FFI to rewire.

LN_MAX_BUFS :: 8
LN_DECISION_MAX :: 255
MATCH_CHAR_MAX_LEN :: 800

// mmfile_t mirror (xdiff.h: {ptr: ^u8, size: C.int}).
Mmfile_T :: struct {
	ptr:  ^u8,
	size: C.int,
}
#assert(size_of(Mmfile_T) == 16)

// diffcmppath_T mirror: lev_score@0, path_n@8, choice_mem@16[256],
// choice@1040[255], decision@2064[255], optimal@4104.
Diffcmppath_T :: struct {
	df_lev_score:      C.int,
	_pad0:             [4]u8,
	df_path_n:         C.size_t,
	df_choice_mem:     [256]C.int,
	df_choice:         [255]C.int,
	_pad1:             [4]u8,
	df_decision:       [255]^Diffcmppath_T,
	df_optimal_choice: C.size_t,
}
#assert(size_of(Diffcmppath_T) == 4112)

// Element address (Odin forbids & on multi-pointer index).
dcmp_at_o :: proc "c" (base: rawptr, i: C.size_t) -> ^Diffcmppath_T {
	context = runtime.default_context()
	return (^Diffcmppath_T)(uintptr(base) + uintptr(i) * size_of(Diffcmppath_T))
}

line_len_o :: proc "c" (m: ^Mmfile_T) -> C.size_t {
	context = runtime.default_context()
	end := libc.memchr(rawptr(m.ptr), '\n', C.size_t(m.size))
	if end != nil {
		return C.size_t(uintptr(end) - uintptr(m.ptr))
	}
	return C.size_t(m.size)
}

// LCS length between two lines (two-row DP).
matching_chars_o :: proc "c" (m1: ^Mmfile_T, m2: ^Mmfile_T) -> C.int {
	context = runtime.default_context()
	s1len := min(C.size_t(MATCH_CHAR_MAX_LEN - 1), line_len_o(m1))
	s2len := min(C.size_t(MATCH_CHAR_MAX_LEN - 1), line_len_o(m2))
	s1 := m1.ptr
	s2 := m2.ptr
	rows: [2][MATCH_CHAR_MAX_LEN]C.int
	iri: C.size_t = 1
	for i: C.size_t = 0; i < s1len; i += 1 {
		iri = 1 - iri
		e1 := ([^]C.int)(&rows[iri][0])
		e2 := ([^]C.int)(&rows[1 - iri][0])
		for j: C.size_t = 0; j < s2len; j += 1 {
			if e2[j + 1] > e1[j + 1] {
				e1[j + 1] = e2[j + 1]
			}
			if e1[j] > e1[j + 1] {
				e1[j + 1] = e1[j]
			}
			if ([^]u8)(s1)[i] == ([^]u8)(s2)[j] && e2[j] + 1 > e1[j + 1] {
				e1[j + 1] = e2[j] + 1
			}
		}
	}
	return rows[iri][s2len]
}

// matching_chars ignoring whitespace.
matching_chars_iwhite_o :: proc "c" (s1: ^Mmfile_T, s2: ^Mmfile_T) -> C.int {
	context = runtime.default_context()
	sp: [2]Mmfile_T
	p: [2][MATCH_CHAR_MAX_LEN]u8
	for k := 0; k < 2; k += 1 {
		s := s1
		if k == 1 {
			s = s2
		}
		pi: C.size_t = 0
		slen := min(C.size_t(MATCH_CHAR_MAX_LEN - 1), line_len_o(s))
		for i: C.size_t = 0; i <= slen; i += 1 {
			e := ([^]u8)(s.ptr)[i]
			if e != ' ' && e != '\t' {
				p[k][pi] = e
				pi += 1
			}
		}
		sp[k] = Mmfile_T{ptr = &p[k][0], size = C.int(pi)}
	}
	return matching_chars_o(&sp[0], &sp[1])
}

// Pairwise match count over n buffers (3+-way ties normalized).
count_n_matched_chars_o :: proc "c" (sp: [^]rawptr, n: C.size_t, iwhite: bool) -> C.int {
	context = runtime.default_context()
	matched_chars: C.int = 0
	matched: C.int = 0
	for i: C.size_t = 0; i < n; i += 1 {
		for j := i + 1; j < n; j += 1 {
			mi := (^Mmfile_T)(sp[i])
			mj := (^Mmfile_T)(sp[j])
			if mi.ptr != nil && mj.ptr != nil {
				matched += 1
				if iwhite {
					matched_chars += matching_chars_iwhite_o(mi, mj)
				} else {
					matched_chars += matching_chars_o(mi, mj)
				}
			}
		}
	}
	if matched >= 2 {
		matched_chars *= 2
		matched_chars /= matched
	}
	return matched_chars
}

// Advance an mmfile past (lnum-1) newlines.
@(export)
fastforward_buf_to_lnum :: proc "c" (s_in: Mmfile_T, lnum: C.int) -> Mmfile_T {
	context = runtime.default_context()
	s := s_in
	for i: C.int = 0; i < lnum - 1; i += 1 {
		line_end := libc.memchr(rawptr(s.ptr), '\n', C.size_t(s.size))
		if line_end != nil {
			s.size = s.size - C.int(uintptr(line_end) - uintptr(s.ptr))
		} else {
			s.size = 0
		}
		s.ptr = transmute(^u8)(line_end)
		if s.ptr == nil {
			break
		}
		s.ptr = (^u8)(uintptr(s.ptr) + 1)
		s.size -= 1
	}
	return s
}

// N-dimensional tensor index from per-dimension values.
unwrap_indexes_o :: proc "c" (values: [^]C.int, diff_len: [^]C.int, ndiffs: C.size_t) -> C.size_t {
	context = runtime.default_context()
	num_unwrap_scalar: C.size_t = 1
	for k: C.size_t = 0; k < ndiffs; k += 1 {
		num_unwrap_scalar *= C.size_t(diff_len[k]) + 1
	}
	path_idx: C.size_t = 0
	for k: C.size_t = 0; k < ndiffs; k += 1 {
		num_unwrap_scalar /= C.size_t(diff_len[k]) + 1
		n := values[k]
		path_idx += num_unwrap_scalar * C.size_t(n)
	}
	return path_idx
}

// Score every subset path through the current tensor cell.
try_possible_paths_o :: proc "c" (df_iters: [^]C.int, paths: [^]C.size_t, npaths: C.int, path_idx: C.int, choice: ^C.int, diffcmppath: rawptr, diff_len: [^]C.int, ndiffs: C.size_t, diff_blk: [^]rawptr, iwhite: bool) {
	context = runtime.default_context()
	if path_idx == npaths {
		if choice^ > 0 {
			from_vals: [LN_MAX_BUFS]C.int
			to_vals := df_iters
			mm: [LN_MAX_BUFS]Mmfile_T
			current_lines: [LN_MAX_BUFS]rawptr
			for k: C.size_t = 0; k < ndiffs; k += 1 {
				from_vals[k] = df_iters[k]
				if (choice^ & (C.int(1) << k)) != 0 {
					from_vals[k] -= 1
					mm[k] = fastforward_buf_to_lnum((^Mmfile_T)(diff_blk[k])^, df_iters[k])
				} else {
					mm[k] = Mmfile_T{}
				}
				current_lines[k] = rawptr(&mm[k])
			}
			unwrapped_idx_from := unwrap_indexes_o(([^]C.int)(&from_vals[0]), diff_len, ndiffs)
			unwrapped_idx_to := unwrap_indexes_o(to_vals, diff_len, ndiffs)
			matched_chars := count_n_matched_chars_o(([^]rawptr)(&current_lines[0]), ndiffs, iwhite)
			score := ([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_from].df_lev_score + matched_chars
			if score > ([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_lev_score {
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_path_n = 1
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_decision[0] = dcmp_at_o(diffcmppath, unwrapped_idx_from)
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_choice[0] = choice^
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_lev_score = score
			} else if score == ([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_lev_score {
				k := ([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_path_n
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_path_n = k + 1
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_decision[k] = dcmp_at_o(diffcmppath, unwrapped_idx_from)
				([^]Diffcmppath_T)(diffcmppath)[unwrapped_idx_to].df_choice[k] = choice^
			}
		}
		return
	}
	bit_place := paths[path_idx]
	choice^ |= C.int(1) << bit_place
	try_possible_paths_o(df_iters, paths, npaths, path_idx + 1, choice, diffcmppath, diff_len, ndiffs, diff_blk, iwhite)
	choice^ &= ~(C.int(1) << bit_place)
	try_possible_paths_o(df_iters, paths, npaths, path_idx + 1, choice, diffcmppath, diff_len, ndiffs, diff_blk, iwhite)
}

// Fill the tensor with best-path decisions.
populate_tensor_o :: proc "c" (df_iters: [^]C.int, ch_dim: C.size_t, diffcmppath: rawptr, diff_len: [^]C.int, ndiffs: C.size_t, diff_blk: [^]rawptr, iwhite: bool) {
	context = runtime.default_context()
	if ch_dim == ndiffs {
		npaths: C.int = 0
		paths: [LN_MAX_BUFS]C.size_t
		for j: C.size_t = 0; j < ndiffs; j += 1 {
			if df_iters[j] > 0 {
				paths[npaths] = j
				npaths += 1
			}
		}
		choice: C.int = 0
		unwrapper_idx_to := unwrap_indexes_o(df_iters, diff_len, ndiffs)
		([^]Diffcmppath_T)(diffcmppath)[unwrapper_idx_to].df_lev_score = -1
		try_possible_paths_o(df_iters, ([^]C.size_t)(&paths[0]), npaths, 0, &choice, diffcmppath, diff_len, ndiffs, diff_blk, iwhite)
		return
	}
	for i: C.int = 0; i <= diff_len[ch_dim]; i += 1 {
		df_iters[ch_dim] = i
		populate_tensor_o(df_iters, ch_dim + 1, diffcmppath, diff_len, ndiffs, diff_blk, iwhite)
	}
}

// Optimal line alignment of a diff block across 2+ buffers.
@(export)
linematch_nbuffers :: proc "c" (diff_blk: [^]rawptr, diff_len: [^]C.int, ndiffs: C.size_t, decisions: ^^C.int, iwhite: bool) -> C.size_t {
	context = runtime.default_context()
	if !(ndiffs <= LN_MAX_BUFS) {
		libc.abort()
	}
	memsize: C.size_t = 1
	memsize_decisions: C.size_t = 0
	for i: C.size_t = 0; i < ndiffs; i += 1 {
		if !(diff_len[i] >= 0) {
			libc.abort()
		}
		memsize *= C.size_t(diff_len[i]) + 1
		memsize_decisions += C.size_t(diff_len[i])
	}
	diffcmppath := ([^]Diffcmppath_T)(xmalloc(C.size_t(size_of(Diffcmppath_T)) * memsize))
	n := C.size_t(1) << ndiffs
	for i: C.size_t = 0; i < memsize; i += 1 {
		diffcmppath[i].df_lev_score = 0
		diffcmppath[i].df_path_n = 0
		for j: C.size_t = 0; j < n; j += 1 {
			diffcmppath[i].df_choice_mem[j] = -1
		}
	}
	df_iters: [LN_MAX_BUFS]C.int
	populate_tensor_o(([^]C.int)(&df_iters[0]), 0, rawptr(diffcmppath), diff_len, ndiffs, diff_blk, iwhite)
	u := unwrap_indexes_o(diff_len, diff_len, ndiffs)
	startNode := dcmp_at_o(rawptr(diffcmppath), u)
	decisions^ = (^C.int)(xmalloc(C.size_t(size_of(C.int)) * memsize_decisions))
	n_optimal: C.size_t = 0
	test_charmatch_paths_o(startNode, 0)
	for startNode.df_path_n > 0 {
		j := startNode.df_optimal_choice
		([^]C.int)(decisions^)[n_optimal] = startNode.df_choice[j]
		n_optimal += 1
		startNode = startNode.df_decision[j]
	}
	for i: C.size_t = 0; i < (n_optimal / 2); i += 1 {
		tmp := ([^]C.int)(decisions^)[i]
		([^]C.int)(decisions^)[i] = ([^]C.int)(decisions^)[n_optimal - 1 - i]
		([^]C.int)(decisions^)[n_optimal - 1 - i] = tmp
	}
	xfree(rawptr(diffcmppath))
	return n_optimal
}

// Fewest path changes from start to end (memoized).
test_charmatch_paths_o :: proc "c" (node: ^Diffcmppath_T, lastdecision: C.int) -> C.size_t {
	context = runtime.default_context()
	if node.df_choice_mem[lastdecision] == -1 {
		if node.df_path_n == 0 {
			node.df_choice_mem[lastdecision] = 0
		} else {
			minimum_turns := max(C.size_t)
			for i: C.size_t = 0; i < node.df_path_n; i += 1 {
				add: C.size_t = 0
				if lastdecision != node.df_choice[i] {
					add = 1
				}
				t := test_charmatch_paths_o(node.df_decision[i], node.df_choice[i]) + add
				if t < minimum_turns {
					node.df_optimal_choice = i
					minimum_turns = t
				}
			}
			node.df_choice_mem[lastdecision] = C.int(minimum_turns)
		}
	}
	return C.size_t(node.df_choice_mem[lastdecision])
}
