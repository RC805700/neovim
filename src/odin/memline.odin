package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/linux"
import "core:sys/posix"

// memline.c port: buffer text as a tree of pointer/data blocks over memfile.
// Publics are @(export); C-statics are _o dormant plains.

foreign _ {
	@(link_name = "inhibit_delete_count")
	inhibit_delete_count: C.int
	@(link_name = "mb_utflen")
	mb_utflen_e :: proc "c" (s: cstring, len: C.size_t, codepoints: ^C.size_t, codeunits: ^C.size_t) ---
	@(link_name = "get_trans_bufname")
	get_trans_bufname_e :: proc "c" (buf: rawptr) ---
	@(link_name = "shorten_dir")
	shorten_dir_e :: proc "c" (str: ^u8) ---
	@(link_name = "modname")
	modname_e :: proc "c" (fname: cstring, ext: cstring, prepend_dot: bool) -> ^u8 ---
	@(link_name = "uv_uptime")
	uv_uptime_e :: proc "c" (uptime: ^f64) -> C.int ---
	@(link_name = "vim_deltempdir")
	vim_deltempdir_e :: proc "c" () ---
	@(link_name = "buf_store_file_info")
	buf_store_file_info_e :: proc "c" (buf: rawptr, file_info: ^FileInfo) ---
	@(link_name = "same_directory")
	same_directory_e :: proc "c" (f1: ^u8, f2: ^u8) -> bool ---
	@(link_name = "has_autocmd")
	has_autocmd_e :: proc "c" (event: C.int, sfname: ^u8, buf: rawptr) -> bool ---
	@(link_name = "flush_buffers")
	flush_buffers_e :: proc "c" (flush_type: C.int) ---
	@(link_name = "allbuf_lock")
	allbuf_lock_g: C.int
	// gen_expand_wildcards_e lives in help.odin — reuse directly.
	@(link_name = "match_suffix")
	match_suffix_e :: proc "c" (fname: ^u8) -> bool ---
	@(link_name = "match_file_list")
	match_file_list_e :: proc "c" (list: ^u8, sfname: ^u8, ffname: ^u8) -> bool ---
	@(link_name = "p_wig")
	p_wig_g: ^u8
	@(link_name = "p_su")
	p_su_g: ^u8
	@(link_name = "readfile")
	readfile_e :: proc "c" (fname: ^u8, sfname: ^u8, from: C.int, skip: C.int, read: C.int, eap: rawptr, flags: C.int, silent: bool) -> C.int ---
	// changed_internal now defined in change.odin — call directly.
	@(link_name = "Versions")
	Versions_g: [5]cstring
	// os_get_username/os_fileinfo_inode are Odin exports (os_users/os_fs) — call directly.
}

DATA_ID_O :: 0x6461
PTR_ID_O :: 0x7074
BLOCK0_ID0_O :: 'b'
BLOCK0_ID1_O :: '0'
B0_FNAME_ORG_O :: 900
B0_FNAME_NOCRYPT_O :: 898
B0_FNAME_CRYPT_O :: 890
B0_UNAME_O :: 40
B0_HNAME_O :: 40
B0_MAGIC_LONG_O :: 0x30313233
B0_MAGIC_INT_O :: 0x20212223
B0_MAGIC_SHORT_O :: 0x10111213
B0_MAGIC_CHAR_O :: 0x55
B0_DIRTY_O :: 0x55
B0_FF_MASK_O :: 3
B0_SAME_DIR_O :: 4
B0_HAS_FENC_O :: 8
DB_MARKED_O :: u32(1) << 31
DB_INDEX_MASK_O :: ~u32(u32(1) << 31)
INDEX_SIZE_O :: 4
HEADER_SIZE_O :: 24
ML_LINE_DIRTY_O :: 0x02
ML_LOCKED_DIRTY_O :: 0x04
ML_LOCKED_POS_O :: 0x08
ML_ALLOCATED_O :: 0x10
ML_DELETE_O :: 0x11
ML_INSERT_O :: 0x12
ML_FIND_O :: 0x13
ML_FLUSH_O :: 0x02
B_CHG_OFF_O :: 208
B_P_FENC_OFF_O :: 10400
B_DEL_BYTES_OFF_O :: 12720
B_DEL_BYTES2_OFF_O :: 12728
B_DEL_CP_OFF_O :: 12736
B_DEL_CU_OFF_O :: 12744
B_UPD_NEED_CP_OFF_O :: 12712
// ZeroBlock byte offsets (2+10+4+4+4+4+40+40 header = 108 before fname).
B0_FNAME_AT_O :: 108
B0_FNAME_MAX_O :: 900

// infoptr_T mirror (24B: bnum@0, low@8, high@12, index@16).
Infoptr_O :: struct {
	bnum:  i64,
	low:   C.int,
	high:  C.int,
	index: C.int,
	_pad:  C.int,
}
#assert(size_of(Infoptr_O) == 24)

// chunksize_T mirror (8B).
Chunksize_O :: struct {
	numlines: C.int,
	totalsize: C.int,
}
#assert(size_of(Chunksize_O) == 8)

// PointerEntry mirror (24B: bnum@0, line_count@8, old_lnum@12, page_count@16).
PointerEntry_O :: struct {
	bnum:       i64,
	line_count: C.int,
	old_lnum:   C.int,
	page_count: C.int,
	_pad:       C.int,
}
#assert(size_of(PointerEntry_O) == 24)

// memline_T mirror (cc-probed, 112B).
Memline_O :: struct {
	line_count:   C.int,
	_pad0:        C.int,
	mfp:          ^Memfile_O,
	stack:        ^Infoptr_O,
	stack_top:    C.int,
	stack_size:   C.int,
	flags:        C.int,
	line_textlen: C.int,
	line_lnum:    C.int,
	_pad1:        C.int,
	line_ptr:     ^u8,
	line_offset:  C.size_t,
	line_offset_ff: C.int,
	_pad2:        C.int,
	locked:       ^Bhdr_O,
	locked_low:   C.int,
	locked_high:  C.int,
	locked_lineadd: C.int,
	_pad3:        C.int,
	chunksize:    ^Chunksize_O,
	numchunks:    C.int,
	usedchunks:   C.int,
}
#assert(size_of(Memline_O) == 112)

// DataBlock header mirror (24B: id@0, free@4, txt_start@8, txt_end@12, line_count@16).
DataBlock_O :: struct {
	id:         u16,
	_pad0:      [2]u8,
	free:       u32,
	txt_start:  u32,
	txt_end:    u32,
	line_count: i64,
}
#assert(size_of(DataBlock_O) == 24)

// PointerBlock header mirror (6B: 3xu16 + flex entries).
PointerBlock_O :: struct {
	id:        u16,
	count:     u16,
	count_max: u16,
}
#assert(size_of(PointerBlock_O) == 6)

// Byte-order helpers (memline.c statics).
long_to_char_o :: proc "c" (n: C.long, s_in: ^u8) {
	context = runtime.default_context()
	s := ([^]u8)(s_in)
	v := u64(n)
	s[0] = u8(v & 0xff)
	v = u64(u32(v) >> 8)
	s[1] = u8(v & 0xff)
	v = u64(u32(v) >> 8)
	s[2] = u8(v & 0xff)
	v = u64(u32(v) >> 8)
	s[3] = u8(v & 0xff)
}

char_to_long_o :: proc "c" (s_in: ^u8) -> C.long {
	context = runtime.default_context()
	s := ([^]u8)(s_in)
	return C.long(u32(s[0]) | (u32(s[1]) << 8) | (u32(s[2]) << 16) | (u32(s[3]) << 24))
}

// Lowest marked line (single copy; C's append/delete paths use this via extern).
@(export)
lowest_marked: C.int = 0

@(export)
ml_line_alloced :: proc "c" () -> C.int {
	context = runtime.default_context()
	return (^C.int)(uintptr(curbuf) + 40)^ & ML_LINE_DIRTY_O
}

@(export)
ml_add_deleted_len :: proc "c" (ptr: cstring, len: C.ssize_t) {
	context = runtime.default_context()
	ml_add_deleted_len_buf(curbuf, ptr, len)
}

@(export)
ml_add_deleted_len_buf :: proc "c" (buf: rawptr, ptr: cstring, len: C.ssize_t) {
	context = runtime.default_context()
	if inhibit_delete_count != 0 {
		return
	}
	maxlen := C.ssize_t(libc.strlen(ptr))
	l := len
	if l == -1 || l > maxlen {
		l = maxlen
	}
	(^C.size_t)(uintptr(buf) + B_DEL_BYTES_OFF_O)^ += C.size_t(l) + 1
	(^C.size_t)(uintptr(buf) + B_DEL_BYTES2_OFF_O)^ += C.size_t(l) + 1
	if (^bool)(uintptr(buf) + B_UPD_NEED_CP_OFF_O)^ {
		mb_utflen_e(ptr, C.size_t(l), (^C.size_t)(uintptr(buf) + B_DEL_CP_OFF_O), (^C.size_t)(uintptr(buf) + B_DEL_CU_OFF_O))
		(^C.size_t)(uintptr(buf) + B_DEL_CP_OFF_O)^ += 1
		(^C.size_t)(uintptr(buf) + B_DEL_CU_OFF_O)^ += 1
	}
}

// Store fileencoding at the end of b0_fname (memline.c static).
add_b0_fenc_o :: proc "c" (b0p: rawptr, buf: rawptr) {
	context = runtime.default_context()
	size := B0_FNAME_NOCRYPT_O
	fenc := (^cstring)(uintptr(buf) + B_P_FENC_OFF_O)^
	n := C.int(libc.strlen(fenc))
	fname := ([^]u8)(uintptr(b0p) + B0_FNAME_AT_O)
	if C.int(libc.strlen(transmute(cstring)(&fname[0]))) + n + 1 > C.int(size) {
		fname[B0_FNAME_MAX_O - 2] &= ~u8(B0_HAS_FENC_O)
	} else {
		libc.memmove(rawptr(&fname[size - int(n)]), transmute(rawptr)(fenc), C.size_t(n))
		fname[size - int(n) - 1] = 0
		fname[B0_FNAME_MAX_O - 2] |= u8(B0_HAS_FENC_O)
	}
}

E_ML_E317_S :: "E317: Pointer block id wrong"
E_ML_E317_2_S :: "E317: Pointer block id wrong 2"
E_ML_E322_S :: "E322: Line number out of range: %ld past the end"
E_ML_E323_S :: "E323: Line count wrong in block %ld"

// Grow the pointer-block stack; returns the previous top index.
ml_add_stack_o :: proc "c" (buf: rawptr) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	top := ml.stack_top
	if top == ml.stack_size {
		ml.stack_size += 5
		ml.stack = (^Infoptr_O)(xrealloc(rawptr(ml.stack), C.size_t(size_of(Infoptr_O)) * C.size_t(ml.stack_size)))
	}
	ml.stack_top += 1
	return top
}

// Fix pointer-block line counts after a failed insert/delete.
ml_lineadd_o :: proc "c" (buf: rawptr, count: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	idx := ml.stack_top - 1
	for idx >= 0 {
		ip := &([^]Infoptr_O)(ml.stack)[idx]
		hp := mf_get(mfp, ip.bnum, 1)
		if hp == nil {
			break
		}
		if (^u16)(hp.data)^ != PTR_ID_O {
			mf_put(mfp, hp, false, false)
			iemsg(cstring(E_ML_E317_2_S))
			break
		}
		([^]PointerEntry_O)(uintptr(hp.data) + 8)[ip.index].line_count += count
		ip.high += count
		mf_put(mfp, hp, true, false)
		idx -= 1
	}
}

// Find the data block containing lnum (ML_FIND/INSERT/DELETE/FLUSH).
ml_find_line_o :: proc "c" (buf: rawptr, lnum: C.int, action: C.int) -> ^Bhdr_O {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	if ml.locked != nil {
		if (action & 0x10) != 0 && ml.locked_low <= lnum && ml.locked_high >= lnum {
			if action == ML_INSERT_O {
				ml.locked_lineadd += 1
				ml.locked_high += 1
			} else if action == ML_DELETE_O {
				ml.locked_lineadd -= 1
				ml.locked_high -= 1
			}
			return ml.locked
		}
		mf_put(mfp, ml.locked, (ml.flags & ML_LOCKED_DIRTY_O) != 0, (ml.flags & ML_LOCKED_POS_O) != 0)
		ml.locked = nil
		if ml.locked_lineadd != 0 {
			ml_lineadd_o(buf, ml.locked_lineadd)
		}
	}
	if action == ML_FLUSH_O {
		return nil
	}
	bnum: i64 = 1
	page_count: u32 = 1
	low: C.int = 1
	high: C.int = ml.line_count
	if action == ML_FIND_O {
		top := ml.stack_top - 1
		for top >= 0 {
			ip := &([^]Infoptr_O)(ml.stack)[top]
			if ip.low <= lnum && ip.high >= lnum {
				bnum = ip.bnum
				low = ip.low
				high = ip.high
				ml.stack_top = top
				break
			}
			top -= 1
		}
		if top < 0 {
			ml.stack_top = 0
		}
	} else {
		ml.stack_top = 0
	}
	for {
		hp := mf_get(mfp, bnum, page_count)
		if hp == nil {
			break
		}
		if action == ML_INSERT_O {
			high += 1
		} else if action == ML_DELETE_O {
			high -= 1
		}
		if (^u16)(hp.data)^ == DATA_ID_O {
			ml.locked = hp
			ml.locked_low = low
			ml.locked_high = high
			ml.locked_lineadd = 0
			ml.flags &= ~(C.int(ML_LOCKED_DIRTY_O) | C.int(ML_LOCKED_POS_O))
			return hp
		}
		if (^u16)(hp.data)^ != PTR_ID_O {
			iemsg(cstring(E_ML_E317_S))
			mf_put(mfp, hp, false, false)
			break
		}
		pb_count := C.int(([^]u16)(hp.data)[1])
		top := ml_add_stack_o(buf)
		ip := &([^]Infoptr_O)(ml.stack)[top]
		ip.bnum = bnum
		ip.low = low
		ip.high = high
		ip.index = -1
		dirty := false
		idx: C.int = 0
		found := false
		for idx < pb_count {
			pe := &([^]PointerEntry_O)(uintptr(hp.data) + 8)[idx]
			t := pe.line_count
			low += t
			if low > lnum {
				ip.index = idx
				bnum = pe.bnum
				page_count = u32(pe.page_count)
				high = low - 1
				low -= t
				if bnum < 0 {
					bnum2 := mf_trans_del(mfp, bnum)
					if bnum != bnum2 {
						bnum = bnum2
						pe.bnum = bnum
						dirty = true
					}
				}
				found = true
				break
			}
			idx += 1
		}
		if !found {
			if lnum > ml.line_count {
				siemsg(cstring(E_ML_E322_S), C.longlong(lnum) - C.longlong(ml.line_count))
			} else {
				siemsg(cstring(E_ML_E323_S), C.longlong(bnum))
			}
			mf_put(mfp, hp, false, false)
			break
		}
		if action == ML_DELETE_O {
			([^]PointerEntry_O)(uintptr(hp.data) + 8)[idx].line_count -= 1
			dirty = true
		} else if action == ML_INSERT_O {
			([^]PointerEntry_O)(uintptr(hp.data) + 8)[idx].line_count += 1
			dirty = true
		}
		mf_put(mfp, hp, dirty, false)
	}
	if action == ML_DELETE_O {
		ml_lineadd_o(buf, 1)
	} else if action == ML_INSERT_O {
		ml_lineadd_o(buf, -1)
	}
	ml.stack_top = 0
	return nil
}

@(export)
ml_setmarked :: proc "c" (lnum: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if lnum < 1 || lnum > ml.line_count || ml.mfp == nil {
		return
	}
	if lowest_marked == 0 || lowest_marked > lnum {
		lowest_marked = lnum
	}
	hp := ml_find_line_o(rawptr(curbuf), lnum, ML_FIND_O)
	if hp == nil {
		return
	}
	([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[lnum - ml.locked_low] |= DB_MARKED_O
	ml.flags |= ML_LOCKED_DIRTY_O
}

@(export)
ml_firstmarked :: proc "c" () -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if ml.mfp == nil {
		return 0
	}
	lnum := lowest_marked
	for lnum <= ml.line_count {
		hp := ml_find_line_o(rawptr(curbuf), lnum, ML_FIND_O)
		if hp == nil {
			return 0
		}
		i := lnum - ml.locked_low
		for lnum <= ml.locked_high {
			if (([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i] & DB_MARKED_O) != 0 {
				([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i] &= DB_INDEX_MASK_O
				ml.flags |= ML_LOCKED_DIRTY_O
				lowest_marked = lnum + 1
				return lnum
			}
			i += 1
			lnum += 1
		}
	}
	return 0
}

@(export)
ml_clearmarked :: proc "c" () {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if ml.mfp == nil {
		return
	}
	lnum := lowest_marked
	for lnum <= ml.line_count {
		hp := ml_find_line_o(rawptr(curbuf), lnum, ML_FIND_O)
		if hp == nil {
			return
		}
		i := lnum - ml.locked_low
		for lnum <= ml.locked_high {
			if (([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i] & DB_MARKED_O) != 0 {
				([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i] &= DB_INDEX_MASK_O
				ml.flags |= ML_LOCKED_DIRTY_O
			}
			i += 1
			lnum += 1
		}
	}
	lowest_marked = 0
}

ML_CHNK_ADDLINE_O :: 1
ML_CHNK_DELLINE_O :: 2
ML_CHNK_UPDLINE_O :: 3
MLCS_MAXL_O :: 800
MLCS_MINL_O :: 400
ML_APPEND_NEW_O :: 1
ML_APPEND_MARK_O :: 2
E_ML_E318_S :: "E318: Updated too many blocks?"
E_ML_E317_3_S :: "E317: Pointer block id wrong 3"
E_ML_E317_4_S :: "E317: Pointer block id wrong 4"
E_ML_E320_S :: "E320: Cannot find line %ld"
E_ML_E315_S :: "E315: ml_get: Invalid lnum: %ld"
E_ML_E316_S :: "E316: ml_get: Cannot find line %ldin buffer %d %s"
E_NO_LINES_S :: "--No lines in buffer--"
B_PREV_LINE_COUNT_OFF_O :: 12656
B_FLUSH_COUNT_OFF_O :: 12752
B_P_FIXEOL_OFF_O :: 10384
B_P_SWF_OFF_O :: 10672
B_TERMINAL_OFF_O :: 12488
B_SPELL_OFF_O :: 11171
B_HELP_OFF_O :: 11170
B_P_BIN_OFF_O :: 10136
B_P_EOL_OFF_O :: 10380
B_FLAGS_OFF_O :: 140
B_FFNAME_OFF_O :: 160
B_FNAME_OFF_O :: 176
B_MTIME_OFF_O :: 328
B_MTIME_NS_OFF_O :: 336
B_MTIME_READ_OFF_O :: 344
B_MTIME_READ_NS_OFF_O :: 352
B_ORIG_SIZE_OFF_O :: 360
B_ORIG_MODE_OFF_O :: 368
BF_RECOVERED_O :: 0x01
UB_FNAME_O :: 0
UB_SAME_DIR_O :: 1
E_ML_E304_S :: "E304: ml_upd_block0(): Didn't get block 0??"
ML_SEA_NONE_O :: 0
ML_SEA_READONLY_O :: 1
ML_SEA_EDIT_O :: 2
ML_SEA_RECOVER_O :: 3
ML_SEA_DELETE_O :: 4
ML_SEA_QUIT_O :: 5
ML_SEA_ABORT_O :: 6
EVENT_SWAPEXISTS_O :: 110
EVENT_BUFREADPOST_O :: 12
FLUSH_TYPEAHEAD_O :: 1
SHM_ATTENTION_O :: 'A'
VV_SWAPNAME_O :: 47
VV_SWAPCHOICE_O :: 48
EW_KEEPALL_O :: 0x10

// Swap-name pattern builder (memline.c static).
recov_file_names_o :: proc "c" (names: [^]rawptr, path: cstring, prepend_dot: bool) -> C.int {
	context = runtime.default_context()
	num_names: C.int = 0
	if prepend_dot {
		names[0] = rawptr(modname_e(path, cstring(".sw?"), true))
		if names[0] == nil {
			return num_names
		}
		num_names += 1
	}
	names[num_names] = rawptr(concat_fnames_r(NvimString{path, C.size_t(libc.strlen(path))}, NvimString{cstring(".sw?"), 4}, false).data)
	if num_names >= 1 {
		p := transmute(cstring)(names[num_names - 1])
		i := C.int(libc.strlen(transmute(cstring)(names[num_names - 1]))) - C.int(libc.strlen(transmute(cstring)(names[num_names])))
		if i > 0 {
			p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + uintptr(i)))
		}
		if libc.strcmp(p, transmute(cstring)(names[num_names])) != 0 {
			num_names += 1
		} else {
			xfree(names[num_names])
		}
	} else {
		num_names += 1
	}
	return num_names
}

// path.c expand_wildcards: internal glob + wildignore/suffix handling.
expand_wildcards_o :: proc "c" (num_pat: C.int, pat: rawptr, num_files: ^C.int, files: ^rawptr, flags: C.int) -> C.int {
	context = runtime.default_context()
	retval := gen_expand_wildcards_e(num_pat, pat, num_files, files, flags)
	if (flags & EW_KEEPALL_O) != 0 || retval == 0 {
		return retval
	}
	if (([^]u8)(p_wig_g))[0] != 0 {
		i: C.int = 0
		for i < num_files^ {
			f := ([^]^u8)(files^)[uintptr(i)]
			ffname := FullName_save_r(transmute(cstring)(f), false)
			if match_file_list_e(p_wig_g, f, transmute(^u8)(ffname)) {
				xfree(rawptr(f))
				j := i
				for j + 1 < num_files^ {
					([^]^u8)(files^)[uintptr(j)] = ([^]^u8)(files^)[uintptr(j) + 1]
					j += 1
				}
				num_files^ -= 1
				i -= 1
			}
			xfree(rawptr(ffname))
		}
	}
	if num_files^ > 1 && !got_int {
		non_suf_match: C.int = 0
		i: C.int = 0
		for i < num_files^ {
			if !match_suffix_e(([^]^u8)(files^)[uintptr(i)]) {
				p := ([^]^u8)(files^)[uintptr(i)]
				j := i
				for j > non_suf_match {
					([^]^u8)(files^)[uintptr(j)] = ([^]^u8)(files^)[uintptr(j) - 1]
					j -= 1
				}
				([^]^u8)(files^)[uintptr(non_suf_match)] = p
				non_suf_match += 1
			}
			i += 1
		}
	}
	if num_files^ == 0 {
		xfree(files^)
		files^ = nil
		return 0
	}
	return retval
}

// Enumerate swapfiles for fname into ret_list.
@(export)
recover_names :: proc "c" (fname: cstring, skip_curbuf: bool, ret_list: rawptr) {
	context = runtime.default_context()
	names: [6]rawptr
	tail: ^u8
	p: ^u8
	files: rawptr = nil
	fname_res: cstring = nil
	fname_buf: [MAXPATHL_O]u8
	if fname != nil {
		if resolve_symlink(fname, transmute(^u8)(&fname_buf[0])) == 1 {
			fname_res = transmute(cstring)(&fname_buf[0])
		} else {
			fname_res = fname
		}
	}
	dir_name_data := transmute(^u8)(xmalloc(C.size_t(libc.strlen(transmute(cstring)(p_dir_opt))) + 1))
	dirp := p_dir_opt
	for (([^]u8)(dirp))[0] != 0 {
		dir_name_size := copy_option_part(transmute(^^u8)(&dirp), dir_name_data, 31000, cstring(","))
		dn := ([^]u8)(dir_name_data)
		num_names: C.int
		if dn[0] == '.' && dn[1] == 0 {
			if fname == nil {
				names[0] = rawptr(xmemdupz(transmute(rawptr)(cstring("*.sw?")), 5))
				names[1] = rawptr(xmemdupz(transmute(rawptr)(cstring(".*.sw?")), 6))
				names[2] = rawptr(xmemdupz(transmute(rawptr)(cstring(".sw?")), 4))
				num_names = 3
			} else {
				num_names = recov_file_names_o(([^]rawptr)(rawptr(&names[0])), fname_res, true)
			}
		} else {
			if fname == nil {
				names[0] = rawptr(concat_fnames_r(NvimString{transmute(cstring)(dir_name_data), dir_name_size}, NvimString{cstring("*.sw?"), 5}, true).data)
				names[1] = rawptr(concat_fnames_r(NvimString{transmute(cstring)(dir_name_data), dir_name_size}, NvimString{cstring(".*.sw?"), 6}, true).data)
				names[2] = rawptr(concat_fnames_r(NvimString{transmute(cstring)(dir_name_data), dir_name_size}, NvimString{cstring(".sw?"), 4}, true).data)
				num_names = 3
			} else {
				p = transmute(^u8)(rawptr(uintptr(dir_name_data) + uintptr(dir_name_size)))
				if _after_pathsep(transmute(cstring)(dir_name_data), transmute(cstring)(p)) != 0 && dir_name_size > 1 && ([^]u8)(rawptr(uintptr(p) - 1))[0] == ([^]u8)(rawptr(uintptr(p) - 2))[0] {
					tail = make_percent_swname(transmute(cstring)(dir_name_data), transmute(cstring)(p), fname_res)
				} else {
					tail = transmute(^u8)(path_tail(fname_res))
					tail = transmute(^u8)(concat_fnames_r(NvimString{transmute(cstring)(dir_name_data), dir_name_size}, NvimString{transmute(cstring)(tail), C.size_t(libc.strlen(transmute(cstring)(tail)))}, true).data)
				}
				num_names = recov_file_names_o(([^]rawptr)(rawptr(&names[0])), transmute(cstring)(tail), false)
				xfree(rawptr(tail))
			}
		}
		num_files: C.int = 0
		if num_names == 0 {
			num_files = 0
		} else if expand_wildcards_o(num_names, rawptr(&names[0]), &num_files, &files, EW_KEEPALL_O | EW_FILE | EW_SILENT) == 0 {
			num_files = 0
		}
		if (([^]u8)(dirp))[0] == 0 && tv_list_len_o(ret_list) + num_files == 0 && fname != nil {
			swapname := modname_e(fname_res, cstring(".swp"), true)
			if swapname != nil {
				if os_path_exists(transmute(cstring)(swapname)) {
					files = xmalloc(size_of(rawptr))
					([^]rawptr)(files)[0] = rawptr(swapname)
					swapname = nil
					num_files = 1
				}
				xfree(rawptr(swapname))
			}
		}
		if skip_curbuf {
			mfp := (^Memfile_O)((^rawptr)(uintptr(curbuf) + 16)^)
			if mfp != nil && mfp.fname != nil {
				p := mfp.fname
				i: C.int = 0
				for i < num_files {
					if path_full_compare_r(transmute(cstring)(p), transmute(cstring)(([^]rawptr)(files)[uintptr(i)]), true, false) & kEqualFiles_S != 0 {
						xfree(([^]rawptr)(files)[uintptr(i)])
						num_files -= 1
						if num_files == 0 {
							xfree(rawptr(files))
							files = nil
						} else {
							j := i
							for j < num_files {
								([^]rawptr)(files)[uintptr(j)] = ([^]rawptr)(files)[uintptr(j) + 1]
								j += 1
							}
						}
					} else {
						i += 1
					}
				}
			}
		}
		i: C.int = 0
		for i < num_files {
			tv_list_append_allocated_string(ret_list, xstrdup(transmute(^u8)(([^]rawptr)(files)[uintptr(i)])))
			i += 1
		}
		i = 0
		for i < num_names {
			xfree(([^]rawptr)(rawptr(&names[0]))[uintptr(i)])
			i += 1
		}
		if num_files > 0 {
			freewild_e(num_files, rawptr(files))
		}
	}
	xfree(rawptr(dir_name_data))
}

// ml_get_buf_impl statics (memline.c file-statics).
ml_get_recursive_g: C.int = 0
ml_questions_g: [4]u8 = {'?', '?', '?', 0}
ml_empty_str_g: [1]u8 = {0}
// ml_flush_line reentry guard (memline.c file-static).
ml_flush_entered_g: bool = false

// Slot addresses for memmove (Odin forbids & on multi-pointer index).
// Pointer entries start at offset 8, NOT 6: C pads the 3xu16 header with
// 2 bytes to align the i64 inside PointerEntry (verified via byte dump:
// entries read at +6 come out shifted left by 16 bits).
PB_POINTER_AT_O :: 8
pe_addr_o :: proc "c" (blk: rawptr, i: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(blk) + PB_POINTER_AT_O + uintptr(i) * 24)
}
idx_addr_o :: proc "c" (blk: rawptr, i: C.int) -> rawptr {
	context = runtime.default_context()
	return rawptr(uintptr(blk) + 24 + uintptr(i) * 4)
}

// Append engine (memline.c static, 410 lines; activates with ml_flush_line).
ml_append_int_o :: proc "c" (buf: rawptr, lnum: C.int, line_arg: ^u8, len_arg: C.int, flags: C.int) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	line := line_arg
	len := len_arg
	if lnum > ml.line_count || ml.mfp == nil {
		return 0
	}
	if lowest_marked != 0 && lowest_marked > lnum {
		lowest_marked = lnum + 1
	}
	if len == 0 {
		len = C.int(libc.strlen(transmute(cstring)(line))) + 1
	}
	space_needed := i64(len) + 4
	mfp := ml.mfp
	page_size := i64(mfp.page_size)
	find_lnum := lnum
	if find_lnum == 0 {
		find_lnum = 1
	}
	hp := ml_find_line_o(buf, find_lnum, ML_INSERT_O)
	if hp == nil {
		return 0
	}
	ml.flags &= ~C.int(ML_EMPTY_O)
	db_idx: C.int
	if lnum == 0 {
		db_idx = -1
	} else {
		db_idx = lnum - ml.locked_low
	}
	line_count := ml.locked_high - ml.locked_low
	dp := hp.data
	if i64((^DataBlock_O)(dp).free) < space_needed && db_idx == line_count - 1 && lnum < ml.line_count {
		ml.locked_lineadd -= 1
		ml.locked_high -= 1
		hp = ml_find_line_o(buf, lnum + 1, ML_INSERT_O)
		if hp == nil {
			return 0
		}
		db_idx = -1
		line_count = ml.locked_high - ml.locked_low
		dp = hp.data
	}
	if (^C.int)(uintptr(buf) + B_PREV_LINE_COUNT_OFF_O)^ == 0 {
		(^C.int)(uintptr(buf) + B_PREV_LINE_COUNT_OFF_O)^ = ml.line_count
	}
	ml.line_count += 1
	if i64((^DataBlock_O)(dp).free) >= space_needed {
		ddp := (^DataBlock_O)(dp)
		ddp.txt_start -= u32(len)
		ddp.free -= u32(space_needed)
		ddp.line_count += 1
		if line_count > db_idx + 1 {
			offset: C.int
			if db_idx < 0 {
				offset = C.int(ddp.txt_end)
			} else {
				offset = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx] & DB_INDEX_MASK_O)
			}
			libc.memmove(rawptr(uintptr(dp) + uintptr(ddp.txt_start)), rawptr(uintptr(dp) + uintptr(ddp.txt_start) + uintptr(len)), C.size_t(C.int(offset) - (C.int(ddp.txt_start) + len)))
			i := line_count - 1
			for i > db_idx {
				([^]u32)(uintptr(dp) + HEADER_SIZE_O)[i + 1] = ([^]u32)(uintptr(dp) + HEADER_SIZE_O)[i] - u32(len)
				i -= 1
			}
			([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx + 1] = u32(offset - len)
		} else {
			([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx + 1] = ddp.txt_start
		}
		libc.memmove(rawptr(uintptr(dp) + uintptr(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx + 1])), rawptr(line), C.size_t(len))
		if (flags & ML_APPEND_MARK_O) != 0 {
			([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx + 1] |= DB_MARKED_O
		}
		ml.flags |= ML_LOCKED_DIRTY_O
		if (flags & ML_APPEND_NEW_O) == 0 {
			ml.flags |= ML_LOCKED_POS_O
		}
	} else {
		lines_moved: C.int
		page_count_left: C.int
		page_count_right: C.int
		hp_left: ^Bhdr_O
		hp_right: ^Bhdr_O
		hp_new: ^Bhdr_O
		data_moved: C.int = 0
		total_moved: C.int = 0
		in_left: bool
		lnum_left: C.int
		lnum_right: C.int
		line_count_left: C.int
		line_count_right: C.int
		pp_new: rawptr
		if db_idx < 0 {
			lines_moved = 0
			in_left = true
		} else {
			lines_moved = line_count - db_idx - 1
			if lines_moved == 0 {
				in_left = false
			} else {
				data_moved = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[db_idx] & DB_INDEX_MASK_O) - C.int((^DataBlock_O)(dp).txt_start)
				total_moved = data_moved + lines_moved * 4
				if i64((^DataBlock_O)(dp).free) + i64(total_moved) >= space_needed {
					in_left = true
					space_needed = i64(total_moved)
				} else {
					in_left = false
					space_needed += i64(total_moved)
				}
			}
		}
		new_pages := (space_needed + 24 + page_size - 1) / page_size
		hp_new = ml_new_data_o(mfp, (flags & ML_APPEND_NEW_O) != 0, new_pages)
		if db_idx < 0 {
			hp_left = hp_new
			hp_right = hp
			line_count_left = 0
			line_count_right = line_count
		} else {
			hp_left = hp
			hp_right = hp_new
			line_count_left = line_count
			line_count_right = 0
		}
		dp_right := (^DataBlock_O)(hp_right.data)
		dp_left := (^DataBlock_O)(hp_left.data)
		bnum_left := hp_left.bnum
		bnum_right := hp_right.bnum
		page_count_left = C.int(hp_left.page_count)
		page_count_right = C.int(hp_right.page_count)
		if !in_left {
			dp_right.txt_start -= u32(len)
			dp_right.free -= u32(len) + 4
			([^]u32)(uintptr(hp_right.data) + HEADER_SIZE_O)[0] = dp_right.txt_start
			if (flags & ML_APPEND_MARK_O) != 0 {
				([^]u32)(uintptr(hp_right.data) + HEADER_SIZE_O)[0] |= DB_MARKED_O
			}
			libc.memmove(rawptr(uintptr(hp_right.data) + uintptr(dp_right.txt_start)), rawptr(line), C.size_t(len))
			line_count_right += 1
		}
		if lines_moved != 0 {
			dp_right.txt_start -= u32(data_moved)
			dp_right.free -= u32(total_moved)
			libc.memmove(rawptr(uintptr(hp_right.data) + uintptr(dp_right.txt_start)), rawptr(uintptr(hp_left.data) + uintptr(dp_left.txt_start)), C.size_t(data_moved))
			offset := C.int(dp_right.txt_start - dp_left.txt_start)
			dp_left.txt_start += u32(data_moved)
			dp_left.free += u32(total_moved)
			to := line_count_right
			from := db_idx + 1
			for from < line_count_left {
				([^]u32)(uintptr(hp_right.data) + HEADER_SIZE_O)[to] = ([^]u32)(uintptr(dp) + HEADER_SIZE_O)[from] + u32(offset)
				from += 1
				to += 1
			}
			line_count_right += lines_moved
			line_count_left -= lines_moved
		}
		if in_left {
			dp_left.txt_start -= u32(len)
			dp_left.free -= u32(len) + 4
			([^]u32)(uintptr(hp_left.data) + HEADER_SIZE_O)[line_count_left] = dp_left.txt_start
			if (flags & ML_APPEND_MARK_O) != 0 {
				([^]u32)(uintptr(hp_left.data) + HEADER_SIZE_O)[line_count_left] |= DB_MARKED_O
			}
			libc.memmove(rawptr(uintptr(hp_left.data) + uintptr(dp_left.txt_start)), rawptr(line), C.size_t(len))
			line_count_left += 1
		}
		if db_idx < 0 {
			lnum_left = lnum + 1
			lnum_right = 0
		} else {
			lnum_left = 0
			if in_left {
				lnum_right = lnum + 2
			} else {
				lnum_right = lnum + 1
			}
		}
		dp_left.line_count = i64(line_count_left)
		dp_right.line_count = i64(line_count_right)
		if lines_moved != 0 || in_left {
			ml.flags |= ML_LOCKED_DIRTY_O
		}
		if (flags & ML_APPEND_NEW_O) == 0 && db_idx >= 0 && in_left {
			ml.flags |= ML_LOCKED_POS_O
		}
		mf_put(mfp, hp_new, true, false)
		lineadd := ml.locked_lineadd
		ml.locked_lineadd = 0
		ml_find_line_o(buf, 0, ML_FLUSH_O)
		stack_idx := ml.stack_top - 1
		for stack_idx >= 0 {
			ip := &([^]Infoptr_O)(ml.stack)[stack_idx]
			pb_idx := ip.index
			hp = mf_get(mfp, ip.bnum, 1)
			if hp == nil {
				return 0
			}
			if ([^]u16)(hp.data)[0] != PTR_ID_O {
				iemsg(cstring(E_ML_E317_3_S))
				mf_put(mfp, hp, false, false)
				return 0
			}
			pes := ([^]PointerEntry_O)(uintptr(hp.data) + 8)
			if ([^]u16)(hp.data)[1] < ([^]u16)(hp.data)[2] {
				if pb_idx + 1 < C.int(([^]u16)(hp.data)[1]) {
					libc.memmove(pe_addr_o(hp.data, pb_idx + 2), pe_addr_o(hp.data, pb_idx + 1), C.size_t(C.int(([^]u16)(hp.data)[1]) - pb_idx - 1) * size_of(PointerEntry_O))
				}
				([^]u16)(hp.data)[1] += 1
				pes[pb_idx].line_count = line_count_left
				pes[pb_idx].bnum = bnum_left
				pes[pb_idx].page_count = page_count_left
				pes[pb_idx + 1].line_count = line_count_right
				pes[pb_idx + 1].bnum = bnum_right
				pes[pb_idx + 1].page_count = page_count_right
				if lnum_left != 0 {
					pes[pb_idx].old_lnum = lnum_left
				}
				if lnum_right != 0 {
					pes[pb_idx + 1].old_lnum = lnum_right
				}
				mf_put(mfp, hp, true, false)
				ml.stack_top = stack_idx + 1
				if lineadd != 0 {
					ml.stack_top -= 1
					ml_lineadd_o(buf, lineadd)
					([^]Infoptr_O)(ml.stack)[ml.stack_top].high += lineadd
					ml.stack_top += 1
				}
				break
			}
			for {
				hp_new = ml_new_ptr_o(mfp)
				if hp_new == nil {
					return 0
				}
				pp_new = hp_new.data
				if hp.bnum != 1 {
					break
				}
				libc.memmove(pp_new, hp.data, C.size_t(page_size))
				([^]u16)(hp.data)[1] = 1
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[0].bnum = hp_new.bnum
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[0].line_count = ml.line_count
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[0].old_lnum = 1
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[0].page_count = 1
				mf_put(mfp, hp, true, false)
				hp = hp_new
				pes = ([^]PointerEntry_O)(uintptr(hp.data) + 8)
				ip.index = 0
				stack_idx += 1
			}
			total_moved2 := C.int(([^]u16)(hp.data)[1]) - pb_idx - 1
			if total_moved2 != 0 {
				libc.memmove(pe_addr_o(pp_new, 0), pe_addr_o(hp.data, pb_idx + 1), C.size_t(total_moved2) * size_of(PointerEntry_O))
				([^]u16)(pp_new)[1] = u16(total_moved2)
				([^]u16)(hp.data)[1] = ([^]u16)(hp.data)[1] - u16(total_moved2 - 1)
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx + 1].bnum = bnum_right
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx + 1].line_count = line_count_right
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx + 1].page_count = page_count_right
				if lnum_right != 0 {
					([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx + 1].old_lnum = lnum_right
				}
			} else {
				([^]u16)(pp_new)[1] = 1
				([^]PointerEntry_O)(uintptr(pp_new) + 8)[0].bnum = bnum_right
				([^]PointerEntry_O)(uintptr(pp_new) + 8)[0].line_count = line_count_right
				([^]PointerEntry_O)(uintptr(pp_new) + 8)[0].page_count = page_count_right
				([^]PointerEntry_O)(uintptr(pp_new) + 8)[0].old_lnum = lnum_right
			}
			([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx].bnum = bnum_left
			([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx].line_count = line_count_left
			([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx].page_count = page_count_left
			if lnum_left != 0 {
				([^]PointerEntry_O)(uintptr(hp.data) + 8)[pb_idx].old_lnum = lnum_left
			}
			lnum_left = 0
			lnum_right = 0
			line_count_right = 0
			i := C.int(0)
			for i < C.int(([^]u16)(pp_new)[1]) {
				line_count_right += ([^]PointerEntry_O)(uintptr(pp_new) + 8)[i].line_count
				i += 1
			}
			line_count_left = 0
			i = 0
			for i < C.int(([^]u16)(hp.data)[1]) {
				line_count_left += ([^]PointerEntry_O)(uintptr(hp.data) + 8)[i].line_count
				i += 1
			}
			bnum_left = hp.bnum
			bnum_right = hp_new.bnum
			page_count_left = 1
			page_count_right = 1
			mf_put(mfp, hp, true, false)
			mf_put(mfp, hp_new, true, false)
			stack_idx -= 1
		}
		if stack_idx < 0 {
			iemsg(cstring(E_ML_E318_S))
			ml.stack_top = 0
		}
	}
	ml_updatechunk_o(buf, lnum + 1, len, ML_CHNK_ADDLINE_O)
	return 1
}

// Create a new, empty, data block.
ml_new_data_o :: proc "c" (mfp: ^Memfile_O, negative: bool, page_count: i64) -> ^Bhdr_O {
	context = runtime.default_context()
	if page_count < 0 {
		libc.abort()
	}
	hp := mf_new(mfp, negative, u32(page_count))
	dp := (^DataBlock_O)(hp.data)
	dp.id = DATA_ID_O
	dp.txt_start = u32(page_count) * mfp.page_size
	dp.txt_end = dp.txt_start
	dp.free = dp.txt_start - HEADER_SIZE_O
	dp.line_count = 0
	return hp
}

// Create a new, empty, pointer block.
ml_new_ptr_o :: proc "c" (mfp: ^Memfile_O) -> ^Bhdr_O {
	context = runtime.default_context()
	hp := mf_new(mfp, false, 1)
	([^]u16)(hp.data)[0] = PTR_ID_O
	([^]u16)(hp.data)[1] = 0
	([^]u16)(hp.data)[2] = u16((mfp.page_size - PB_POINTER_AT_O) / 24)
	return hp
}

// ml_updatechunk cache statics (memline.c file-statics).
ml_upd_lastbuf_g: rawptr = nil
ml_upd_lastline_g: C.int = 0
ml_upd_lastcurline_g: C.int = 0
ml_upd_lastcurix_g: C.int = 0

@(export)
ml_flush_deleted_bytes :: proc "c" (buf: rawptr, codepoints: ^C.size_t, codeunits: ^C.size_t) -> C.size_t {
	context = runtime.default_context()
	ret := (^C.size_t)(uintptr(buf) + B_DEL_BYTES_OFF_O)^
	codepoints^ = (^C.size_t)(uintptr(buf) + B_DEL_CP_OFF_O)^
	codeunits^ = (^C.size_t)(uintptr(buf) + B_DEL_CU_OFF_O)^
	(^C.size_t)(uintptr(buf) + B_DEL_BYTES_OFF_O)^ = 0
	(^C.size_t)(uintptr(buf) + B_DEL_CP_OFF_O)^ = 0
	(^C.size_t)(uintptr(buf) + B_DEL_CU_OFF_O)^ = 0
	return ret
}

// Replace engine (activates ml_replace_* below).
@(export)
ml_replace_buf_len :: proc "c" (buf: rawptr, lnum: C.int, line_arg: ^u8, len_arg: C.size_t, copy: bool, noalloc: bool) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	line := line_arg
	if line == nil {
		return 0
	}
	if ml.mfp == nil && open_buffer(false, nil, 0) == 0 {
		return 0
	}
	if copy {
		if noalloc {
			libc.abort()
		}
		line = xmemdupz(rawptr(line), len_arg)
	}
	if ml.line_lnum != lnum {
		ml_flush_line_o(buf, false)
	}
	if (^C.size_t)(uintptr(buf) + B_UPDATE_CALLBACKS_OFF)^ != 0 {
		ml_add_deleted_len_buf(buf, transmute(cstring)(ml_get_buf(buf, lnum)), -1)
	}
	if (ml.flags & (ML_LINE_DIRTY_O | ML_ALLOCATED_O)) != 0 {
		xfree(rawptr(ml.line_ptr))
	}
	ml.line_ptr = line
	ml.line_textlen = C.int(len_arg) + 1
	ml.line_lnum = lnum
	ml.flags = (ml.flags | ML_LINE_DIRTY_O) & ~C.int(ML_EMPTY_O)
	if noalloc {
		ml_flush_line_o(buf, true)
	}
	return 1
}

@(export)
ml_replace :: proc "c" (lnum: C.int, line: ^u8, copy: bool) -> C.int {
	context = runtime.default_context()
	return ml_replace_buf(curbuf, lnum, line, copy, false)
}

@(export)
ml_replace_len :: proc "c" (lnum: C.int, line: ^u8, len: C.size_t, copy: bool) -> C.int {
	context = runtime.default_context()
	return ml_replace_buf_len(curbuf, lnum, line, len, copy, false)
}

@(export)
ml_replace_buf :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, copy: bool, noalloc: bool) -> C.int {
	context = runtime.default_context()
	len: C.size_t = max(C.size_t)
	if line != nil {
		len = C.size_t(libc.strlen(transmute(cstring)(line)))
	}
	return ml_replace_buf_len(buf, lnum, line, len, copy, noalloc)
}

// Flush pending line, then append (memline.c static).
ml_append_flush_o :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, len: C.int, flags: C.int) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if lnum > ml.line_count {
		return 0
	}
	if ml.line_lnum != 0 {
		ml_flush_line_o(buf, false)
	}
	return ml_append_int_o(buf, lnum, line, len, flags)
}

@(export)
ml_append :: proc "c" (lnum: C.int, line: ^u8, len: C.int, newfile: bool) -> C.int {
	context = runtime.default_context()
	fl := C.int(0)
	if newfile {
		fl = ML_APPEND_NEW_O
	}
	return ml_append_flags(lnum, line, len, fl)
}

@(export)
ml_append_flags :: proc "c" (lnum: C.int, line: ^u8, len: C.int, flags: C.int) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if ml.mfp == nil && open_buffer(false, nil, 0) == 0 {
		return 0
	}
	return ml_append_flush_o(curbuf, lnum, line, len, flags)
}

@(export)
ml_append_buf :: proc "c" (buf: rawptr, lnum: C.int, line: ^u8, len: C.int, newfile: bool) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if ml.mfp == nil {
		return 0
	}
	fl := C.int(0)
	if newfile {
		fl = ML_APPEND_NEW_O
	}
	return ml_append_flush_o(buf, lnum, line, len, fl)
}

// Keep byte-offset chunk info for a line (memline.c static).
ml_updatechunk_o :: proc "c" (buf: rawptr, line: C.int, len: C.int, updtype: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	curline := ml_upd_lastcurline_g
	curix := ml_upd_lastcurix_g
	hp: ^Bhdr_O
	dp: rawptr
	if ml.usedchunks == -1 || len == 0 {
		return
	}
	if ml.chunksize == nil {
		ml.chunksize = (^Chunksize_O)(xmalloc(size_of(Chunksize_O) * 100))
		ml.numchunks = 100
		ml.usedchunks = 1
		([^]Chunksize_O)(ml.chunksize)[0].numlines = 1
		([^]Chunksize_O)(ml.chunksize)[0].totalsize = 1
	}
	if updtype == ML_CHNK_UPDLINE_O && ml.line_count == 1 {
		ml.usedchunks = 1
		([^]Chunksize_O)(ml.chunksize)[0].numlines = 1
		([^]Chunksize_O)(ml.chunksize)[0].totalsize = ml.line_textlen
		return
	}
	if buf != ml_upd_lastbuf_g || line != ml_upd_lastline_g + 1 || updtype != ML_CHNK_ADDLINE_O {
		curline = 1
		curix = 0
		for curix < ml.usedchunks - 1 && line >= curline + ([^]Chunksize_O)(ml.chunksize)[curix].numlines {
			curline += ([^]Chunksize_O)(ml.chunksize)[curix].numlines
			curix += 1
		}
	} else if curix < ml.usedchunks - 1 && line >= curline + ([^]Chunksize_O)(ml.chunksize)[curix].numlines {
		curline += ([^]Chunksize_O)(ml.chunksize)[curix].numlines
		curix += 1
	}
	curchk_n := curix
	ln := len
	if updtype == ML_CHNK_DELLINE_O {
		ln = -ln
	}
	([^]Chunksize_O)(ml.chunksize)[curchk_n].totalsize += ln
	if updtype == ML_CHNK_ADDLINE_O {
		rest: C.int
	([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines += 1
		if ml.usedchunks + 1 >= ml.numchunks {
			ml.numchunks = ml.numchunks * 3 / 2
			ml.chunksize = (^Chunksize_O)(xrealloc(rawptr(ml.chunksize), C.size_t(size_of(Chunksize_O)) * C.size_t(ml.numchunks)))
		}
		if ([^]Chunksize_O)(ml.chunksize)[curix].numlines >= MLCS_MAXL_O {
			end_idx: C.int
			text_end: C.int
			libc.memmove(rawptr(&([^]Chunksize_O)(ml.chunksize)[curix + 1]), rawptr(&([^]Chunksize_O)(ml.chunksize)[curix]), C.size_t(ml.usedchunks - curix) * size_of(Chunksize_O))
			size: C.int = 0
			linecnt: C.int = 0
			for curline < ml.line_count && linecnt < MLCS_MINL_O {
				hp = ml_find_line_o(buf, curline, ML_FIND_O)
				if hp == nil {
					ml.usedchunks = -1
					return
				}
				dp = hp.data
				count := ml.locked_high - ml.locked_low + 1
				idx := curline - ml.locked_low
				curline = ml.locked_high + 1
				rest = count - idx
				if linecnt + rest > MLCS_MINL_O {
					end_idx = idx + MLCS_MINL_O - linecnt - 1
					linecnt = MLCS_MINL_O
				} else {
					end_idx = count - 1
					linecnt += rest
				}
				if idx == 0 {
					text_end = C.int((^DataBlock_O)(dp).txt_end)
				} else {
					text_end = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O)
				}
				size += text_end - C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[end_idx] & DB_INDEX_MASK_O)
			}
			([^]Chunksize_O)(ml.chunksize)[curix].numlines = linecnt
			([^]Chunksize_O)(ml.chunksize)[curix + 1].numlines -= linecnt
			([^]Chunksize_O)(ml.chunksize)[curix].totalsize = size
			([^]Chunksize_O)(ml.chunksize)[curix + 1].totalsize -= size
			ml.usedchunks += 1
			ml_upd_lastbuf_g = nil
			return
		} else if ([^]Chunksize_O)(ml.chunksize)[curix].numlines >= MLCS_MINL_O && curix == ml.usedchunks - 1 && ml.line_count - line <= 1 {
			curchk_n = curix + 1
			ml.usedchunks += 1
			if line == ml.line_count {
				([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines = 0
				([^]Chunksize_O)(ml.chunksize)[curchk_n].totalsize = 0
			} else {
				hp = ml_find_line_o(buf, ml.line_count, ML_FIND_O)
				if hp == nil {
					ml.usedchunks = -1
					return
				}
				dp = hp.data
				if (^DataBlock_O)(dp).line_count == 1 {
					rest = C.int((^DataBlock_O)(dp).txt_end - (^DataBlock_O)(dp).txt_start)
				} else {
					rest = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[(^DataBlock_O)(dp).line_count - 2] & DB_INDEX_MASK_O) - C.int((^DataBlock_O)(dp).txt_start)
				}
				([^]Chunksize_O)(ml.chunksize)[curchk_n].totalsize = rest
				([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines = 1
				([^]Chunksize_O)(ml.chunksize)[curix].totalsize -= rest
				([^]Chunksize_O)(ml.chunksize)[curix].numlines -= 1
			}
		}
	} else if updtype == ML_CHNK_DELLINE_O {
		([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines -= 1
		ml_upd_lastbuf_g = nil
		if curix < ml.usedchunks - 1 && (([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines + ([^]Chunksize_O)(ml.chunksize)[curix + 1].numlines) <= MLCS_MINL_O {
			curix += 1
			curchk_n = curix
		} else if curix == 0 && ([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines <= 0 {
			ml.usedchunks -= 1
			libc.memmove(rawptr(ml.chunksize), rawptr(&([^]Chunksize_O)(ml.chunksize)[1]), C.size_t(ml.usedchunks) * size_of(Chunksize_O))
			return
		} else if curix == 0 || (([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines > 10 && (([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines + ([^]Chunksize_O)(ml.chunksize)[curix - 1].numlines) > MLCS_MINL_O) {
			return
		}
		([^]Chunksize_O)(ml.chunksize)[curix - 1].numlines += ([^]Chunksize_O)(ml.chunksize)[curchk_n].numlines
		([^]Chunksize_O)(ml.chunksize)[curix - 1].totalsize += ([^]Chunksize_O)(ml.chunksize)[curchk_n].totalsize
		ml.usedchunks -= 1
		if curix < ml.usedchunks {
			libc.memmove(rawptr(&([^]Chunksize_O)(ml.chunksize)[curix]), rawptr(&([^]Chunksize_O)(ml.chunksize)[curix + 1]), C.size_t(ml.usedchunks - curix) * size_of(Chunksize_O))
		}
		return
	}
	ml_upd_lastbuf_g = buf
	ml_upd_lastline_g = line
	ml_upd_lastcurline_g = curline
	ml_upd_lastcurix_g = curix
}

// Delete engine (memline.c static; activates ml_delete_* below).
ml_delete_int_o :: proc "c" (buf: rawptr, lnum: C.int, flags: C.int) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if lowest_marked != 0 && lowest_marked > lnum {
		lowest_marked -= 1
	}
	if ml.line_count == 1 {
		if (flags & ML_DEL_MESSAGE_O) != 0 {
			set_keep_msg_r(cstring(E_NO_LINES_S), 0)
		}
		i := ml_replace_buf(buf, 1, transmute(^u8)(cstring("")), true, false)
		ml.flags |= ML_EMPTY_O
		return i
	}
	mfp := ml.mfp
	if mfp == nil {
		return 0
	}
	hp := ml_find_line_o(buf, lnum, ML_DELETE_O)
	if hp == nil {
		return 0
	}
	dp := hp.data
	count := ml.locked_high - ml.locked_low + 2
	idx := lnum - ml.locked_low
	if (^C.int)(uintptr(buf) + B_PREV_LINE_COUNT_OFF_O)^ == 0 {
		(^C.int)(uintptr(buf) + B_PREV_LINE_COUNT_OFF_O)^ = ml.line_count
	}
	ml.line_count -= 1
	line_start := C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx] & DB_INDEX_MASK_O)
	line_size: C.int
	if idx == 0 {
		line_size = C.int((^DataBlock_O)(dp).txt_end) - line_start
	} else {
		line_size = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O) - line_start
	}
	if line_size < 1 {
		libc.abort()
	}
	ml_add_deleted_len_buf(buf, transmute(cstring)(rawptr(uintptr(dp) + uintptr(line_start))), C.ssize_t(line_size - 1))
	ret: C.int = 0
	err := false
	if count == 1 {
		mf_free(mfp, hp)
		ml.locked = nil
		stack_idx := ml.stack_top - 1
		for stack_idx >= 0 {
			ml.stack_top = 0
			ip := &([^]Infoptr_O)(ml.stack)[stack_idx]
			idx = ip.index
			hp = mf_get(mfp, ip.bnum, 1)
			if hp == nil {
				err = true
				break
			}
			if ([^]u16)(hp.data)[0] != PTR_ID_O {
				iemsg(cstring(E_ML_E317_4_S))
				mf_put(mfp, hp, false, false)
				err = true
				break
			}
			([^]u16)(hp.data)[1] -= 1
			count = C.int(([^]u16)(hp.data)[1])
			if count == 0 {
				mf_free(mfp, hp)
			} else {
				if count != idx {
					libc.memmove(pe_addr_o(hp.data, idx), pe_addr_o(hp.data, idx + 1), C.size_t(count - idx) * size_of(PointerEntry_O))
				}
				mf_put(mfp, hp, true, false)
				ml.stack_top = stack_idx
				if ml.locked_lineadd != 0 {
					ml_lineadd_o(buf, ml.locked_lineadd)
					([^]Infoptr_O)(ml.stack)[ml.stack_top].high += ml.locked_lineadd
				}
				ml.stack_top += 1
				break
			}
			stack_idx -= 1
		}
	} else {
		text_start := C.int((^DataBlock_O)(dp).txt_start)
		libc.memmove(rawptr(uintptr(dp) + uintptr(text_start) + uintptr(line_size)), rawptr(uintptr(dp) + uintptr(text_start)), C.size_t(line_start - text_start))
		i := idx
		for i < count - 1 {
			([^]u32)(uintptr(dp) + HEADER_SIZE_O)[i] = ([^]u32)(uintptr(dp) + HEADER_SIZE_O)[i + 1] + u32(line_size)
			i += 1
		}
		(^DataBlock_O)(dp).free += u32(line_size) + 4
		(^DataBlock_O)(dp).txt_start += u32(line_size)
		(^DataBlock_O)(dp).line_count -= 1
		ml.flags |= (ML_LOCKED_DIRTY_O | ML_LOCKED_POS_O)
	}
	ml_updatechunk_o(buf, lnum, line_size, ML_CHNK_DELLINE_O)
	if !err {
		ret = 1
	}
	return ret
}

// Flush cached line back to its data block (memline.c static).
ml_flush_line_o :: proc "c" (buf: rawptr, noalloc: bool) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if ml.line_lnum == 0 || ml.mfp == nil {
		return
	}
	if (ml.flags & ML_LINE_DIRTY_O) != 0 {
		if ml_flush_entered_g {
			return
		}
		ml_flush_entered_g = true
		(^C.int)(uintptr(buf) + B_FLUSH_COUNT_OFF_O)^ += 1
		lnum := ml.line_lnum
		new_line := ml.line_ptr
		hp := ml_find_line_o(buf, lnum, ML_FIND_O)
		if hp == nil {
			siemsg(cstring(E_ML_E320_S), C.longlong(lnum))
		} else {
			dp := hp.data
			idx := lnum - ml.locked_low
			start := C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx] & DB_INDEX_MASK_O)
			old_line := rawptr(uintptr(dp) + uintptr(start))
			old_len: C.int
			if idx == 0 {
				old_len = C.int((^DataBlock_O)(dp).txt_end) - start
			} else {
				old_len = C.int(([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O) - start
			}
			new_len := ml.line_textlen
			extra := new_len - old_len
			if C.int((^DataBlock_O)(dp).free) >= extra {
				count := ml.locked_high - ml.locked_low + 1
				if extra != 0 && idx < count - 1 {
					libc.memmove(rawptr(uintptr(dp) + uintptr((^DataBlock_O)(dp).txt_start) - uintptr(extra)), rawptr(uintptr(dp) + uintptr((^DataBlock_O)(dp).txt_start)), C.size_t(start - C.int((^DataBlock_O)(dp).txt_start)))
					i := idx + 1
					for i < count {
						([^]u32)(uintptr(dp) + HEADER_SIZE_O)[i] -= u32(extra)
						i += 1
					}
				}
				([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx] -= u32(extra)
				(^DataBlock_O)(dp).free -= u32(extra)
				(^DataBlock_O)(dp).txt_start -= u32(extra)
				libc.memmove(rawptr(uintptr(old_line) - uintptr(extra)), rawptr(new_line), C.size_t(new_len))
				ml.flags |= (ML_LOCKED_DIRTY_O | ML_LOCKED_POS_O)
				if extra != 0 {
					ml_updatechunk_o(buf, lnum, extra, ML_CHNK_UPDLINE_O)
				}
			} else {
				mark := C.int(0)
				if (([^]u32)(uintptr(dp) + HEADER_SIZE_O)[idx] & DB_MARKED_O) != 0 {
					mark = ML_APPEND_MARK_O
				}
				ml_append_int_o(buf, lnum, new_line, new_len, mark)
				ml_delete_int_o(buf, lnum, 0)
			}
		}
		if !noalloc {
			xfree(rawptr(new_line))
		}
		ml_flush_entered_g = false
	} else if (ml.flags & ML_ALLOCATED_O) != 0 {
		if noalloc {
			libc.abort()
		}
		xfree(rawptr(ml.line_ptr))
	}
	ml.flags &= ~(C.int(ML_LINE_DIRTY_O) | C.int(ML_ALLOCATED_O))
	ml.line_lnum = 0
	ml.line_offset = 0
}

// Core line reader (memline.c static).
ml_get_buf_impl_o :: proc "c" (buf: rawptr, lnum_in: C.int, will_change: bool) -> ^u8 {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if ml.mfp == nil {
		ml.line_textlen = 1
		return transmute(^u8)(&ml_empty_str_g[0])
	}
	lnum := lnum_in
	if lnum > ml.line_count {
		if ml_get_recursive_g == 0 {
			ml_get_recursive_g += 1
			siemsg(cstring(E_ML_E315_S), C.longlong(lnum))
			ml_get_recursive_g -= 1
		}
		ml_flush_line_o(buf, false)
		libc.memcpy(rawptr(&ml_questions_g[0]), transmute(rawptr)(cstring("???")), 4)
		ml.line_textlen = 4
		ml.line_lnum = lnum
		return transmute(^u8)(&ml_questions_g[0])
	}
	if lnum < 1 {
		lnum = 1
	}
	if ml.line_lnum != lnum {
		ml_flush_line_o(buf, false)
		hp := ml_find_line_o(buf, lnum, ML_FIND_O)
		if hp == nil {
			if ml_get_recursive_g == 0 {
				ml_get_recursive_g += 1
				get_trans_bufname_e(buf)
				shorten_dir_e(transmute(^u8)(&name_buff[0]))
				siemsg(cstring(E_ML_E316_S), C.longlong(lnum), (^C.int)(uintptr(buf) + 0)^, transmute(cstring)(&name_buff[0]))
				ml_get_recursive_g -= 1
			}
			libc.memcpy(rawptr(&ml_questions_g[0]), transmute(rawptr)(cstring("???")), 4)
			ml.line_textlen = 4
			ml.line_lnum = lnum
			return transmute(^u8)(&ml_questions_g[0])
		}
		idx := lnum - ml.locked_low
		start := ([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx] & DB_INDEX_MASK_O
		end: u32
		if idx == 0 {
			end = (^DataBlock_O)(hp.data).txt_end
		} else {
			end = ([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O
		}
		ml.line_ptr = transmute(^u8)(rawptr(uintptr(hp.data) + uintptr(start)))
		ml.line_textlen = C.int(end - start)
		ml.line_lnum = lnum
		ml.flags &= ~(C.int(ML_LINE_DIRTY_O) | C.int(ML_ALLOCATED_O))
	}
	if will_change {
		ml.flags |= (ML_LOCKED_DIRTY_O | ML_LOCKED_POS_O)
		ml_add_deleted_len_buf(buf, transmute(cstring)(ml.line_ptr), -1)
	}
	return ml.line_ptr
}

@(export)
ml_get :: proc "c" (lnum: C.int) -> ^u8 {
	context = runtime.default_context()
	return ml_get_buf_impl_o(curbuf, lnum, false)
}

@(export)
ml_get_buf :: proc "c" (buf: rawptr, lnum: C.int) -> ^u8 {
	context = runtime.default_context()
	return ml_get_buf_impl_o(buf, lnum, false)
}

@(export)
ml_get_buf_mut :: proc "c" (buf: rawptr, lnum: C.int) -> ^u8 {
	context = runtime.default_context()
	return ml_get_buf_impl_o(buf, lnum, true)
}

@(export)
ml_get_pos :: proc "c" (pos: rawptr) -> ^u8 {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(pos) + 0)^
	col := (^C.int)(uintptr(pos) + 4)^
	return transmute(^u8)(rawptr(uintptr(ml_get_buf_impl_o(curbuf, lnum, false)) + uintptr(col)))
}

@(export)
ml_get_len :: proc "c" (lnum: C.int) -> C.int {
	context = runtime.default_context()
	return ml_get_buf_len(curbuf, lnum)
}

@(export)
ml_get_pos_len :: proc "c" (pos: rawptr) -> C.int {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(pos) + 0)^
	col := (^C.int)(uintptr(pos) + 4)^
	return ml_get_buf_len(curbuf, lnum) - col
}

@(export)
ml_get_buf_len :: proc "c" (buf: rawptr, lnum: C.int) -> C.int {
	context = runtime.default_context()
	line := ml_get_buf_impl_o(buf, lnum, false)
	if line == nil || line^ == 0 {
		return 0
	}
	ml := (^Memline_O)(uintptr(buf) + 8)
	if ml.line_textlen <= 0 {
		libc.abort()
	}
	return ml.line_textlen - 1
}

@(export)
gchar_pos :: proc "c" (pos: rawptr) -> C.int {
	context = runtime.default_context()
	lnum := (^C.int)(uintptr(pos) + 0)^
	col := (^C.int)(uintptr(pos) + 4)^
	if col == MAXCOL || col > ml_get_len(lnum) {
		return 0
	}
	return utf_ptr2char(transmute(cstring)(ml_get_pos(pos)))
}

@(export)
ml_delete_buf :: proc "c" (buf: rawptr, lnum: C.int, message: bool) -> C.int {
	context = runtime.default_context()
	ml_flush_line_o(buf, false)
	fl := C.int(0)
	if message {
		fl = ML_DEL_MESSAGE_O
	}
	return ml_delete_int_o(buf, lnum, fl)
}

@(export)
ml_delete :: proc "c" (lnum: C.int) -> C.int {
	context = runtime.default_context()
	return ml_delete_flags(lnum, 0)
}

@(export)
ml_delete_flags :: proc "c" (lnum: C.int, flags: C.int) -> C.int {
	context = runtime.default_context()
	ml_flush_line_o(curbuf, false)
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	if lnum < 1 || lnum > ml.line_count {
		return 0
	}
	return ml_delete_int_o(curbuf, lnum, flags)
}

@(export)
ml_find_line_or_offset :: proc "c" (buf: rawptr, lnum: C.int, offp: ^C.int, no_ff: bool) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	text_end: C.int
	offset: C.int
	extra: C.int = 0
	ffdos := C.int(0)
	if !no_ff && get_fileformat(buf) == EOL_DOS_S {
		ffdos = 1
	}
	can_cache := lnum != 0 && ffdos == 0 && ml.line_lnum == lnum
	if lnum == 0 || ml.line_lnum < lnum || !no_ff {
		ml_flush_line_o(curbuf, false)
	} else if can_cache && ml.line_offset > 0 {
		return C.int(ml.line_offset)
	}
	if ml.usedchunks == -1 || ml.chunksize == nil || lnum < 0 {
		if no_ff && ml.mfp != nil && (lnum == 1 || lnum == 2) {
			return lnum - 1
		}
		return -1
	}
	if offp == nil {
		offset = 0
	} else {
		offset = offp^
	}
	if lnum == 0 && offset <= 0 {
		return 1
	}
	curline: C.int = 1
	curix: C.int = 0
	size: C.int = 0
	for curix < ml.usedchunks - 1 && ((lnum != 0 && lnum >= curline + ([^]Chunksize_O)(ml.chunksize)[curix].numlines) || (offset != 0 && offset > size + ([^]Chunksize_O)(ml.chunksize)[curix].totalsize + ffdos * ([^]Chunksize_O)(ml.chunksize)[curix].numlines)) {
		curline += ([^]Chunksize_O)(ml.chunksize)[curix].numlines
		size += ([^]Chunksize_O)(ml.chunksize)[curix].totalsize
		if offset != 0 && ffdos != 0 {
			size += ([^]Chunksize_O)(ml.chunksize)[curix].numlines
		}
		curix += 1
	}
	for (lnum != 0 && curline < lnum) || (offset != 0 && size < offset) {
		if curline > ml.line_count {
			return -1
		}
		hp := ml_find_line_o(buf, curline, ML_FIND_O)
		if hp == nil {
			return -1
		}
		count := ml.locked_high - ml.locked_low + 1
		idx := curline - ml.locked_low
		start_idx := idx
		if idx == 0 {
			text_end = C.int((^DataBlock_O)(hp.data).txt_end)
		} else {
			text_end = C.int(([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O)
		}
		if lnum != 0 {
			if curline + (count - idx) >= lnum {
				idx += lnum - curline - 1
			} else {
				idx = count - 1
			}
		} else {
			extra = 0
			for {
				if !(offset >= size + text_end - C.int(([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx] & DB_INDEX_MASK_O) + ffdos) {
					break
				}
				if ffdos != 0 {
					size += 1
				}
				if idx == count - 1 {
					extra = 1
					break
				}
				idx += 1
			}
		}
		len := text_end - C.int(([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx] & DB_INDEX_MASK_O)
		size += len
		if offset != 0 && size >= offset {
			if size + ffdos == offset {
				offp^ = 0
			} else if idx == start_idx {
				offp^ = offset - size + len
			} else {
				offp^ = offset - size + len - (text_end - C.int(([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[idx - 1] & DB_INDEX_MASK_O))
			}
			curline += idx - start_idx + extra
			if curline > ml.line_count {
				return -1
			}
			return curline
		}
		curline = ml.locked_high + 1
	}
	if lnum != 0 {
		if ffdos != 0 {
			size += lnum - 1
		}
		if ((^C.int)(uintptr(buf) + B_P_FIXEOL_OFF_O)^ == 0 || (^C.int)(uintptr(buf) + B_P_BIN_OFF_O)^ != 0) && (^C.int)(uintptr(buf) + B_P_EOL_OFF_O)^ == 0 && lnum > ml.line_count {
			size -= ffdos + 1
		}
	}
	if can_cache && size > 0 {
		ml.line_offset = C.size_t(size)
	}
	return size
}

@(export)
goto_byte :: proc "c" (cnt: C.int) -> C.int {
	context = runtime.default_context()
	boff := cnt
	ml_flush_line_o(curbuf, false)
	setpcmark()
	if boff != 0 {
		boff -= 1
	}
	lnum := ml_find_line_or_offset(curbuf, 0, &boff, false)
	if lnum < 1 {
		ml := (^Memline_O)(uintptr(curbuf) + 8)
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = ml.line_count
		(^C.int)(uintptr(curwin) + W_CURSWANT_OFF)^ = MAXCOL
		coladvance(curwin, MAXCOL)
	} else {
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF)^ = lnum
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 4)^ = boff
		(^C.int)(uintptr(curwin) + W_CURSOR_OFF + 8)^ = 0
		(^bool)(uintptr(curwin) + W_SET_CURSWANT_OFF)^ = true
	}
	check_cursor(curwin)
	mb_adjust_cursor_r()
	return 1
}

@(export)
inc :: proc "c" (lp: rawptr) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	col := (^C.int)(uintptr(lp) + 4)^
	if col != MAXCOL {
		p := ml_get_pos(lp)
		if p^ != 0 {
			l := utfc_ptr2len(transmute(cstring)(p))
			(^C.int)(uintptr(lp) + 4)^ = col + l
			if ([^]u8)(p)[uintptr(l)] != 0 {
				return 0
			}
			return 2
		}
	}
	if (^C.int)(uintptr(lp) + 0)^ != ml.line_count {
		(^C.int)(uintptr(lp) + 4)^ = 0
		(^C.int)(uintptr(lp) + 0)^ += 1
		(^C.int)(uintptr(lp) + 8)^ = 0
		return 1
	}
	return -1
}

@(export)
incl :: proc "c" (lp: rawptr) -> C.int {
	context = runtime.default_context()
	r := inc(lp)
	if r >= 1 && (^C.int)(uintptr(lp) + 4)^ != 0 {
		r = inc(lp)
	}
	return r
}

@(export)
dec :: proc "c" (lp: rawptr) -> C.int {
	context = runtime.default_context()
	(^C.int)(uintptr(lp) + 8)^ = 0
	col := (^C.int)(uintptr(lp) + 4)^
	if col == MAXCOL {
		p := ml_get((^C.int)(uintptr(lp) + 0)^)
		ln := ml_get_len((^C.int)(uintptr(lp) + 0)^)
		(^C.int)(uintptr(lp) + 4)^ = ln - utf_head_off(transmute(cstring)(p), transmute(cstring)(rawptr(uintptr(p) + uintptr(ln))))
		return 0
	}
	if col > 0 {
		(^C.int)(uintptr(lp) + 4)^ = col - 1
		p := ml_get((^C.int)(uintptr(lp) + 0)^)
		nc := (^C.int)(uintptr(lp) + 4)^
		(^C.int)(uintptr(lp) + 4)^ = nc - utf_head_off(transmute(cstring)(p), transmute(cstring)(rawptr(uintptr(p) + uintptr(nc))))
		return 0
	}
	if (^C.int)(uintptr(lp) + 0)^ > 1 {
		(^C.int)(uintptr(lp) + 0)^ -= 1
		p := ml_get((^C.int)(uintptr(lp) + 0)^)
		ln := ml_get_len((^C.int)(uintptr(lp) + 0)^)
		(^C.int)(uintptr(lp) + 4)^ = ln - utf_head_off(transmute(cstring)(p), transmute(cstring)(rawptr(uintptr(p) + uintptr(ln))))
		return 1
	}
	return -1
}

@(export)
swapfile_dict :: proc "c" (fname: cstring, d: rawptr) {
	context = runtime.default_context()
	b0: [1024]u8
	fd := os_open(fname, 0, 0)
	if fd >= 0 {
		if read_eintr_r(fd, rawptr(&b0[0]), 1024) == 1024 {
			if !ml_check_b0_id_o(rawptr(&b0[0])) {
				tv_dict_add_str_len(d, cstring("error"), 5, cstring("Not a swap file"), 15)
			} else if b0_magic_wrong_o(rawptr(&b0[0])) != 0 {
				tv_dict_add_str_len(d, cstring("error"), 5, cstring("Magic number mismatch"), 21)
			} else {
				tv_dict_add_str_len(d, cstring("version"), 7, transmute(cstring)(&b0[2]), 10)
				tv_dict_add_str_len(d, cstring("user"), 4, transmute(cstring)(&b0[28]), 40)
				tv_dict_add_str_len(d, cstring("host"), 4, transmute(cstring)(&b0[68]), 40)
				tv_dict_add_str_len(d, cstring("fname"), 5, transmute(cstring)(&b0[108]), 900)
				tv_dict_add_nr(d, cstring("pid"), 3, C.longlong(swapfile_proc_running_o(rawptr(&b0[0]), fname)))
				tv_dict_add_nr(d, cstring("mtime"), 5, C.longlong(char_to_long_o(transmute(^u8)(&b0[16]))))
				dirty: C.longlong = 0
				if b0[1007] != 0 {
					dirty = 1
				}
				tv_dict_add_nr(d, cstring("dirty"), 5, dirty)
				tv_dict_add_nr(d, cstring("inode"), 5, C.longlong(char_to_long_o(transmute(^u8)(&b0[20]))))
			}
		} else {
			tv_dict_add_str_len(d, cstring("error"), 5, cstring("Cannot read file"), 16)
		}
		linux.close(linux.Fd(fd))
	} else {
		tv_dict_add_str_len(d, cstring("error"), 5, cstring("Cannot open file"), 16)
	}
}

@(export)
resolve_symlink :: proc "c" (fname: cstring, buf: ^u8) -> C.int {
	context = runtime.default_context()
	tmp: [MAXPATHL_O]u8
	depth: C.int = 0
	if fname == nil {
		return 0
	}
	xstrlcpy(transmute(cstring)(&tmp[0]), fname, MAXPATHL_O)
	for {
		depth += 1
		if depth == 100 {
			semsg(cstring("E773: Symlink loop for \"%s\""), fname)
			return 0
		}
		ret := C.ssize_t(readlink_e(transmute(cstring)(&tmp[0]), buf, MAXPATHL_O - 1))
		if ret <= 0 {
			err := posix.errno()
			if err == .EINVAL || err == .ENOENT {
				if depth == 1 {
					return 0
				}
				break
			}
			return 0
		}
		([^]u8)(buf)[uintptr(ret)] = 0
		if path_is_absolute_e(transmute(cstring)(buf)) {
			libc.strcpy(transmute(^u8)(&tmp[0]), transmute(cstring)(buf))
		} else {
			tail := path_tail(transmute(cstring)(&tmp[0]))
			if C.size_t(libc.strlen(tail)) + C.size_t(libc.strlen(transmute(cstring)(buf))) >= MAXPATHL_O {
				return 0
			}
			libc.strcpy(transmute(^u8)(tail), transmute(cstring)(buf))
		}
	}
	return vim_FullName_e(transmute(cstring)(&tmp[0]), transmute(cstring)(buf), MAXPATHL_O, true)
}

@(export)
get_file_in_dir :: proc "c" (fname: ^u8, dname: ^u8) -> ^u8 {
	context = runtime.default_context()
	dn := ([^]u8)(dname)
	if dn[0] == '.' && dn[1] == 0 {
		tail := transmute(cstring)(path_tail(transmute(cstring)(fname)))
		tailp := rawptr(tail)
		return transmute(^u8)(cbuf_to_string_r(transmute(cstring)(fname), C.size_t(uintptr(tailp) - uintptr(fname)) + C.size_t(libc.strlen(tail))).data)
	}
	dname_len := C.size_t(libc.strlen(transmute(cstring)(dname)))
	if dn[0] == '.' && _vim_ispathsep(C.int(dn[1])) {
		tail := transmute(cstring)(path_tail(transmute(cstring)(fname)))
		tailp := rawptr(tail)
		if tailp == rawptr(fname) {
			return transmute(^u8)(concat_fnames_r(NvimString{transmute(cstring)(rawptr(uintptr(dname) + 2)), dname_len - 2}, NvimString{tail, C.size_t(libc.strlen(tail))}, true).data)
		}
		save_char := ([^]u8)(tailp)[0]
		([^]u8)(tailp)[0] = 0
		tmp := concat_fnames_r(NvimString{transmute(cstring)(fname), C.size_t(uintptr(tailp) - uintptr(fname))}, NvimString{transmute(cstring)(rawptr(uintptr(dname) + 2)), dname_len - 2}, true)
		([^]u8)(tailp)[0] = save_char
		retval := concat_fnames_r(tmp, NvimString{tail, C.size_t(libc.strlen(tail))}, true)
		xfree(rawptr(tmp.data))
		return transmute(^u8)(retval.data)
	}
	tail := transmute(cstring)(path_tail(transmute(cstring)(fname)))
	return transmute(^u8)(concat_fnames_r(NvimString{transmute(cstring)(dname), dname_len}, NvimString{tail, C.size_t(libc.strlen(tail))}, true).data)
}

@(export)
makeswapname :: proc "c" (fname: ^u8, ffname: ^u8, buf: rawptr, dir_name: ^u8) -> ^u8 {
	context = runtime.default_context()
	fname_res := transmute(cstring)(fname)
	fname_buf: [MAXPATHL_O]u8
	if resolve_symlink(transmute(cstring)(fname), transmute(^u8)(&fname_buf[0])) == 1 {
		fname_res = transmute(cstring)(&fname_buf[0])
	}
	_ = ffname
	_ = buf
	len := C.int(libc.strlen(transmute(cstring)(dir_name)))
	s := rawptr(uintptr(dir_name) + uintptr(len))
	if _after_pathsep(transmute(cstring)(dir_name), transmute(cstring)(s)) != 0 && len > 1 && ([^]u8)(rawptr(uintptr(s) - 1))[0] == ([^]u8)(rawptr(uintptr(s) - 2))[0] {
		r: ^u8 = nil
		s2 := make_percent_swname(transmute(cstring)(dir_name), transmute(cstring)(s), fname_res)
		if s2 != nil {
			r = modname_e(transmute(cstring)(s2), cstring(".swp"), false)
			xfree(rawptr(s2))
		}
		return r
	}
	dn := ([^]u8)(dir_name)
	r := modname_e(fname_res, cstring(".swp"), dn[0] == '.' && dn[1] == 0)
	if r == nil {
		return nil
	}
	s2 := get_file_in_dir(r, dir_name)
	xfree(rawptr(r))
	return s2
}

@(export)
make_percent_swname :: proc "c" (dir: cstring, dir_end: cstring, name: cstring) -> ^u8 {
	context = runtime.default_context()
	nm := name
	if nm == nil {
		nm = cstring("")
	}
	fname := fix_fname_r(nm)
	if fname == nil {
		return nil
	}
	fi: FileInfo
	if !os_fileinfo2(transmute(cstring)(fname), &fi) {
		xfree(rawptr(fname))
		return nil
	}
	fixed_data := rawptr(uintptr(fname) + uintptr(fi.root_off))
	if fi._type == kPathDeviceUNC {
		if fi.root_off < 2 {
			libc.abort()
		}
		fixed_data = rawptr(uintptr(fixed_data) - 2)
		([^]u8)(fixed_data)[0] = '/'
	}
	p := transmute(cstring)(fixed_data)
	for ([^]u8)(transmute(rawptr)(p))[0] != 0 {
		if _vim_ispathsep(C.int(([^]u8)(transmute(rawptr)(p))[0])) {
			([^]u8)(transmute(rawptr)(p))[0] = '%'
		}
		p = transmute(cstring)(rawptr(uintptr(transmute(rawptr)(p)) + uintptr(utfc_ptr2len(p))))
	}
	fixed_size := C.size_t(uintptr(transmute(rawptr)(p)) - uintptr(fixed_data))
	dp := ([^]u8)(dir_end)
	([^]u8)(rawptr(uintptr(dp) - 1))[0] = 0
	d := concat_fnames_r(NvimString{dir, C.size_t(uintptr(transmute(rawptr)(dir_end)) - uintptr(transmute(rawptr)(dir)) - 1)}, NvimString{transmute(cstring)(fixed_data), fixed_size}, true)
	xfree(rawptr(fname))
	return transmute(^u8)(d.data)
}

@(export)
decl :: proc "c" (lp: rawptr) -> C.int {
	context = runtime.default_context()
	r := dec(lp)
	if r == 1 && (^C.int)(uintptr(lp) + 4)^ != 0 {
		r = dec(lp)
	}
	return r
}

@(export)
ml_sync_all :: proc "c" (check_file: C.int, check_char: C.int, do_fsync: bool) {
	context = runtime.default_context()
	buf := firstbuf
	for buf != nil {
		ml := (^Memline_O)(uintptr(buf) + 8)
		if ml.mfp == nil || ml.mfp.fname == nil {
			buf = (^rawptr)(uintptr(buf) + 120)^
			continue
		}
		ml_flush_line_o(buf, false)
		ml_find_line_o(buf, 0, ML_FLUSH_O)
		if bufIsChanged(buf) && check_file != 0 && mf_need_trans(ml.mfp) && (^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^ != nil {
			fi: FileInfo
			if !os_fileinfo(transmute(cstring)((^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^), &fi) || i64(fi.stat.st_mtim.tv_sec) != i64((^u64)(uintptr(buf) + B_MTIME_READ_OFF_O)^) || i64(fi.stat.st_mtim.tv_nsec) != i64((^u64)(uintptr(buf) + B_MTIME_READ_NS_OFF_O)^) || os_fileinfo_size(&fi) != (^u64)(uintptr(buf) + B_ORIG_SIZE_OFF_O)^ {
				ml_preserve(buf, false, do_fsync)
				did_check_timestamps_g = false
				need_check_timestamps_g = true
			}
		}
		if ml.mfp.dirty == MF_DIRTY_YES_O {
			fl := C.int(0)
			if check_char != 0 {
				fl |= MFS_STOP_O
			}
			if do_fsync && bufIsChanged(buf) {
				fl |= MFS_FLUSH_O
			}
			mf_sync(ml.mfp, fl)
			if check_char != 0 && os_char_avail() {
				break
			}
		}
		buf = (^rawptr)(uintptr(buf) + 120)^
	}
}

@(export)
ml_preserve :: proc "c" (buf: rawptr, message: bool, do_fsync: bool) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	got_int_save := got_int
	if mfp == nil || mfp.fname == nil {
		if message {
			emsg(cstring("E313: Cannot preserve, there is no swap file"))
		}
		return
	}
	got_int = false
	ml_flush_line_o(buf, false)
	ml_find_line_o(buf, 0, ML_FLUSH_O)
	fl := C.int(MFS_ALL_O)
	if do_fsync {
		fl |= MFS_FLUSH_O
	}
	status := mf_sync(mfp, fl)
	ml.stack_top = 0
	if mf_need_trans(mfp) && !got_int {
		lnum: C.int = 1
		failed := false
		for mf_need_trans(mfp) && lnum <= ml.line_count {
			hp := ml_find_line_o(buf, lnum, ML_FIND_O)
			if hp == nil {
				status = 0
				failed = true
				break
			}
			lnum = ml.locked_high + 1
		}
		if !failed {
			ml_find_line_o(buf, 0, ML_FLUSH_O)
			fl2 := C.int(MFS_ALL_O)
			if do_fsync {
				fl2 |= MFS_FLUSH_O
			}
			if mf_sync(mfp, fl2) == 0 {
				status = 0
			}
			ml.stack_top = 0
		}
	}
	got_int = got_int || got_int_save
	if message {
		if status == 1 {
			msg(cstring("File preserved"), 0)
		} else {
			emsg(cstring("E314: Preserve failed"))
		}
	}
}


// Update the timestamp or the B0_SAME_DIR flag of the .swp file.
ml_upd_block0_o :: proc "c" (buf: rawptr, what: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	if mfp == nil {
		return
	}
	hp := mf_get(mfp, 0, 1)
	if hp == nil {
		iemsg(cstring(E_ML_E304_S))
		return
	}
	if what == UB_FNAME_O {
		set_b0_fname_o(rawptr(hp.data), buf)
	} else {
		set_b0_dir_flag_o(rawptr(hp.data), buf)
	}
	mf_put(mfp, hp, true, false)
}

// Write file name and timestamp into block 0 (memline.c static).
set_b0_fname_o :: proc "c" (b0p: rawptr, buf: rawptr) {
	context = runtime.default_context()
	fname_base := uintptr(b0p) + B0_FNAME_AT_O
	ffname := (^cstring)(uintptr(buf) + B_FFNAME_OFF_O)^
	if ffname == nil {
		([^]u8)(fname_base)[0] = 0
	} else {
		uname: [B0_UNAME_O]u8
		flen := home_replace(nil, ffname, transmute(cstring)(fname_base), B0_FNAME_CRYPT_O, true)
		if ([^]u8)(fname_base)[0] == '~' {
			retval := os_get_username(transmute(cstring)(&uname[0]), B0_UNAME_O)
			ulen := C.size_t(libc.strlen(transmute(cstring)(&uname[0])))
			if retval == 0 || ulen + flen > B0_FNAME_CRYPT_O - 1 {
				xstrlcpy(transmute(cstring)(fname_base), ffname, B0_FNAME_CRYPT_O)
			} else {
				libc.memmove(rawptr(fname_base + uintptr(ulen) + 1), rawptr(fname_base + 1), C.size_t(flen))
				libc.memmove(rawptr(fname_base + 1), rawptr(&uname[0]), ulen)
			}
		}
		fi: FileInfo
		if os_fileinfo(ffname, &fi) {
			long_to_char_o(C.long(fi.stat.st_mtim.tv_sec), transmute(^u8)(rawptr(uintptr(b0p) + 16)))
			long_to_char_o(C.long(os_fileinfo_inode(&fi)), transmute(^u8)(rawptr(uintptr(b0p) + 20)))
			buf_store_file_info_e(buf, &fi)
			(^u64)(uintptr(buf) + B_MTIME_READ_OFF_O)^ = (^u64)(uintptr(buf) + B_MTIME_OFF_O)^
			(^u64)(uintptr(buf) + B_MTIME_READ_NS_OFF_O)^ = (^u64)(uintptr(buf) + B_MTIME_NS_OFF_O)^
		} else {
			long_to_char_o(0, transmute(^u8)(rawptr(fname_base + 912)))
			long_to_char_o(0, transmute(^u8)(rawptr(fname_base + 916)))
			(^u64)(uintptr(buf) + B_MTIME_OFF_O)^ = 0
			(^u64)(uintptr(buf) + B_MTIME_NS_OFF_O)^ = 0
			(^u64)(uintptr(buf) + B_MTIME_READ_OFF_O)^ = 0
			(^u64)(uintptr(buf) + B_MTIME_READ_NS_OFF_O)^ = 0
			(^i64)(uintptr(buf) + B_ORIG_SIZE_OFF_O)^ = 0
			(^C.int)(uintptr(buf) + B_ORIG_MODE_OFF_O)^ = 0
		}
	}
	add_b0_fenc_o(b0p, curbuf)
}

// Update the B0_SAME_DIR flag (memline.c static).
set_b0_dir_flag_o :: proc "c" (b0p: rawptr, buf: rawptr) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	fbase := uintptr(b0p) + B0_FNAME_AT_O
	if same_directory_e(ml.mfp.fname, (^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^) {
		([^]u8)(fbase)[B0_FNAME_MAX_O - 2] |= B0_SAME_DIR_O
	} else {
		([^]u8)(fbase)[B0_FNAME_MAX_O - 2] = u8(C.int(([^]u8)(fbase)[B0_FNAME_MAX_O - 2]) & ~C.int(B0_SAME_DIR_O))
	}
}

@(export)
ml_close :: proc "c" (buf: rawptr, del_file: C.int) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	if ml.mfp == nil {
		return
	}
	mf_close(ml.mfp, del_file != 0)
	if ml.line_lnum != 0 && (ml.flags & (ML_LINE_DIRTY_O | ML_ALLOCATED_O)) != 0 {
		xfree(rawptr(ml.line_ptr))
	}
	xfree(rawptr(ml.stack))
	if ml.chunksize != nil {
		xfree(rawptr(ml.chunksize))
		ml.chunksize = nil
	}
	ml.mfp = nil
	(^C.int)(uintptr(buf) + B_FLAGS_OFF_O)^ &= ~C.int(BF_RECOVERED_O)
}

@(export)
ml_close_all :: proc "c" (del_file: bool) {
	context = runtime.default_context()
	df := C.int(0)
	if del_file {
		df = 1
	}
	buf := firstbuf
	for buf != nil {
		ml_close(buf, df)
		buf = (^rawptr)(uintptr(buf) + 120)^
	}
	spell_delete_wordlist()
	vim_deltempdir_e()
}

@(export)
ml_close_notmod :: proc "c" () {
	context = runtime.default_context()
	buf := firstbuf
	for buf != nil {
		if !bufIsChanged(buf) {
			ml_close(buf, 1)
		}
		buf = (^rawptr)(uintptr(buf) + 120)^
	}
}

@(export)
ml_timestamp :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	ml_upd_block0_o(buf, UB_FNAME_O)
}

// ZeroBlock checks (memline.c statics).
ml_check_b0_id_o :: proc "c" (b0p: rawptr) -> bool {
	context = runtime.default_context()
	b := ([^]u8)(b0p)
	return b[0] == u8(BLOCK0_ID0_O) && b[1] == u8(BLOCK0_ID1_O)
}

b0_magic_wrong_o :: proc "c" (b0p: rawptr) -> C.int {
	context = runtime.default_context()
	base := uintptr(b0p)
	if (^i64)(base + 1008)^ != B0_MAGIC_LONG_O {
		return 1
	}
	if (^u32)(base + 1016)^ != u32(B0_MAGIC_INT_O) {
		return 1
	}
	if (^u16)(base + 1020)^ != u16(0x1213) {
		return 1
	}
	if ([^]u8)(b0p)[1022] != u8(B0_MAGIC_CHAR_O) {
		return 1
	}
	return 0
}

// PID of the swapfile owner, or zero if not running (memline.c static).
swapfile_proc_running_o :: proc "c" (b0p: rawptr, swap_fname: cstring) -> C.int {
	context = runtime.default_context()
	st: FileInfo
	uptime: f64
	if os_fileinfo(swap_fname, &st) && uv_uptime_e(&uptime) == 0 && u64(st.stat.st_mtim.tv_sec) < os_time() - u64(uptime) {
		return 0
	}
	pid := C.int(char_to_long_o(transmute(^u8)(rawptr(uintptr(b0p) + 24))))
	if os_proc_running(pid) {
		return pid
	}
	return 0
}

@(export)
ml_setflags :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	mfp := (^Memfile_O)((^rawptr)(uintptr(buf) + 16)^)
	if mfp == nil {
		return
	}
	hp := mf_hash_get_o(mfp, 0)
	if hp != nil {
		b0p := uintptr(hp.data)
		if (^bool)(uintptr(buf) + B_CHG_OFF_O)^ {
			([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 1] = B0_DIRTY_O
		} else {
			([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 1] = 0
		}
		fl := ([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 2]
		fl = (fl & ~u8(B0_FF_MASK_O)) | u8(get_fileformat(buf) + 1)
		([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 2] = fl
		add_b0_fenc_o(rawptr(b0p), buf)
		hp.flags |= BH_DIRTY_O
		mf_sync(mfp, MFS_ZERO_O)
	}
}

// Open a new memline for buf (startup path).
@(export)
ml_open :: proc "c" (buf: rawptr) -> C.int {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	ml.stack_size = 0
	ml.stack = nil
	ml.stack_top = 0
	ml.locked = nil
	ml.line_lnum = 0
	ml.line_offset = 0
	ml.chunksize = nil
	ml.usedchunks = 0
	if (cmdmod_cmod_flags & CMOD_NOSWAPFILE_S) != 0 {
		(^bool)(uintptr(buf) + B_P_SWF_OFF_O)^ = false
	}
	if (^rawptr)(uintptr(buf) + B_TERMINAL_OFF_O)^ == nil && p_uc != 0 && (^bool)(uintptr(buf) + B_P_SWF_OFF_O)^ {
		(^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ = true
	} else {
		(^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ = false
	}
	mfp := mf_open(nil, 0)
	if mfp == nil {
		ml.mfp = nil
		return 0
	}
	ml.mfp = mfp
	ml.flags = ML_EMPTY_O
	ml.line_count = 1
	hp := mf_new(mfp, false, 1)
	if hp.bnum != 0 {
		iemsg(cstring("E298: Didn't get block nr 0?"))
		mf_put(mfp, hp, false, false)
		mf_close(mfp, true)
		ml.mfp = nil
		return 0
	}
	b0p := uintptr(hp.data)
	([^]u8)(b0p)[0] = u8(BLOCK0_ID0_O)
	([^]u8)(b0p)[1] = u8(BLOCK0_ID1_O)
	([^]i64)(b0p + 1008)[0] = B0_MAGIC_LONG_O
	([^]u32)(b0p + 1016)[0] = u32(B0_MAGIC_INT_O)
	([^]u16)(b0p + 1020)[0] = u16(0x1213)
	([^]u8)(b0p)[1022] = u8(B0_MAGIC_CHAR_O)
	ver := xstpcpy(transmute(^u8)(rawptr(b0p + 2)), transmute(^u8)(cstring("VIM ")))
	xstrlcpy(transmute(cstring)(ver), Versions_g[0], 6)
	long_to_char_o(C.long(mfp.page_size), transmute(^u8)(rawptr(b0p + 12)))
	if !(^bool)(uintptr(buf) + B_SPELL_OFF_O)^ {
		if (^bool)(uintptr(buf) + B_CHG_OFF_O)^ {
			([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 1] = B0_DIRTY_O
		} else {
			([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 1] = 0
		}
		([^]u8)(b0p + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 2] = u8(get_fileformat(buf) + 1)
		set_b0_fname_o(rawptr(b0p), buf)
		os_get_username(transmute(cstring)(rawptr(b0p + 28)), B0_UNAME_O)
		([^]u8)(b0p)[28 + B0_UNAME_O - 1] = 0
		os_get_hostname(transmute(cstring)(rawptr(b0p + 68)), B0_HNAME_O)
		([^]u8)(b0p)[68 + B0_HNAME_O - 1] = 0
		long_to_char_o(C.long(os_get_pid()), transmute(^u8)(rawptr(b0p + 24)))
	}
	mf_put(mfp, hp, true, false)
	if !(^bool)(uintptr(buf) + B_HELP_OFF_O)^ && !(^bool)(uintptr(buf) + B_SPELL_OFF_O)^ {
		mf_sync(mfp, 0)
	}
	hp = ml_new_ptr_o(mfp)
	if hp == nil {
		mf_close(mfp, true)
		ml.mfp = nil
		return 0
	}
	if hp.bnum != 1 {
		iemsg(cstring("E298: Didn't get block nr 1?"))
		mf_put(mfp, hp, false, false)
		mf_close(mfp, true)
		ml.mfp = nil
		return 0
	}
	([^]u16)(hp.data)[1] = 1
	pe := ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)
	pe[0].bnum = 2
	pe[0].page_count = 1
	pe[0].old_lnum = 1
	pe[0].line_count = 1
	mf_put(mfp, hp, true, false)
	hp = ml_new_data_o(mfp, false, 1)
	if hp.bnum != 2 {
		iemsg(cstring("E298: Didn't get block nr 2?"))
		mf_put(mfp, hp, false, false)
		mf_close(mfp, true)
		ml.mfp = nil
		return 0
	}
	dp := (^DataBlock_O)(hp.data)
	dp.txt_start -= 1
	([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[0] = dp.txt_start
	dp.free -= 1 + 4
	dp.line_count = 1
	([^]u8)(uintptr(hp.data) + uintptr(dp.txt_start))[0] = 0
	return 1
}

// Find a non-existing swapfile name; may show the ATTENTION dialog.
@(export)
findswapname :: proc "c" (buf: rawptr, dirp: ^^u8, old_fname: cstring, found_existing_dir: ^bool) -> ^u8 {
	context = runtime.default_context()
	buf_fname := (^^u8)(uintptr(buf) + B_FNAME_OFF_O)^
	dir_len := C.size_t(libc.strlen(transmute(cstring)(dirp^))) + 1
	dir_name := transmute(^u8)(xmalloc(dir_len))
	copy_option_part(dirp, dir_name, dir_len, cstring(","))
	fname := makeswapname(transmute(^u8)(buf_fname), (^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^, buf, dir_name)
	for {
		if fname == nil {
			break
		}
		f := ([^]u8)(fname)
		n := C.size_t(libc.strlen(transmute(cstring)(fname)))
		if n == 0 {
			xfree(rawptr(fname))
			fname = nil
			break
		}
		fi: FileInfo
		if !os_fileinfo_link(transmute(cstring)(fname), &fi) {
			break
		}
		if old_fname != nil && path_fnamecmp_r(transmute(cstring)(fname), old_fname) == 0 {
			break
		}
		if n >= 2 && f[n - 2] == 'w' && f[n - 1] == 'p' {
			if !recoverymode && buf_fname != nil && !(^bool)(uintptr(buf) + B_HELP_OFF_O)^ && ((^C.int)(uintptr(buf) + B_FLAGS_OFF_O)^ & BF_DUMMY_O) == 0 {
				fd := os_open(transmute(cstring)(fname), 0, 0)
				differ := false
				if fd >= 0 {
					b0: [1024]u8
					if read_eintr_r(fd, rawptr(&b0[0]), 1024) == 1024 {
						i := 0
						for i < 900 {
							if b0[108 + i] == '\\' {
								b0[108 + i] = '/'
							}
							i += 1
						}
						ml_proc_running_g = swapfile_proc_running_o(rawptr(&b0[0]), transmute(cstring)(fname))
						if b0[108 + B0_FNAME_MAX_O - 2] & B0_SAME_DIR_O != 0 {
							if path_fnamecmp_r(path_tail(transmute(cstring)((^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^)), path_tail(transmute(cstring)(&b0[108]))) != 0 || !same_directory_e(fname, (^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^) {
								expand_env(transmute(cstring)(&b0[108]), transmute(cstring)(&name_buff[0]), MAXPATHL_O)
								if fnamecmp_ino_o(transmute(cstring)((^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^), transmute(cstring)(&name_buff[0]), char_to_long_o(transmute(^u8)(&b0[20]))) {
									differ = true
								}
							}
						} else {
							expand_env(transmute(cstring)(&b0[108]), transmute(cstring)(&name_buff[0]), MAXPATHL_O)
							if fnamecmp_ino_o(transmute(cstring)((^^u8)(uintptr(buf) + B_FFNAME_OFF_O)^), transmute(cstring)(&name_buff[0]), char_to_long_o(transmute(^u8)(&b0[20]))) {
								differ = true
							}
						}
					}
					linux.close(linux.Fd(fd))
				}
				if !differ && ((^C.int)(uintptr(buf) + B_FLAGS_OFF_O)^ & BF_RECOVERED_O) == 0 && vim_strchr(transmute(cstring)(p_shm), C.int('A')) == nil {
					choice: C.int = ML_SEA_NONE_O
					if os_path_exists(transmute(cstring)(buf_fname)) && swapfile_unchanged_o(transmute(cstring)(fname)) {
						choice = ML_SEA_DELETE_O
						if p_verbose > 0 {
							verb_msg(cstring("Found a swap file that is not useful, deleting it"))
						}
					}
					if choice == ML_SEA_NONE_O && swap_exists_action_g != SEA_NONE_O && has_autocmd_e(EVENT_SWAPEXISTS_O, buf_fname, buf) {
						choice = do_swapexists_o(buf, transmute(cstring)(fname))
					}
					if choice == ML_SEA_NONE_O && swap_exists_action_g == SEA_READONLY_O {
						choice = ML_SEA_READONLY_O
					}
					ml_proc_running_g = 0
					if choice == ML_SEA_NONE_O {
						no_wait_return += 1
						msg := StringBuilder{}
						msg.items = transmute(^u8)(xmalloc(1025))
						msg.capacity = 1025
						msg.size = 0
						fhname := home_replace_save(nil, transmute(cstring)(fname))
						attention_message_o(buf, transmute(cstring)(fname), fhname, &msg)
						got_int = false
						flush_buffers_e(FLUSH_TYPEAHEAD_O)
						if swap_exists_action_g != SEA_NONE_O {
							ml_sb_printf_o(&msg, cstring("%s"), cstring("Swap file \""))
							ml_sb_printf_o(&msg, cstring("%s"), fhname)
							ml_sb_printf_o(&msg, cstring("%s"), cstring("\" already exists!"))
							run_but := cstring("&Open Read-Only\n&Edit anyway\n&Recover\n&Quit\n&Abort")
							but := cstring("&Open Read-Only\n&Edit anyway\n&Recover\n&Delete it\n&Quit\n&Abort")
							buttons := but
							if ml_proc_running_g != 0 {
								buttons = run_but
							}
							choice = do_dialog(VIM_WARNING_O, cstring("VIM - ATTENTION"), transmute(cstring)(msg.items), buttons, 1, nil, false)
							if ml_proc_running_g != 0 && choice >= 4 {
								choice += 1
							}
							msg_reset_scroll()
						} else {
							need_clear := false
							msg_ext_set_kind(cstring("wmsg"))
							msg_multiline(String{data = transmute(cstring)(msg.items), size = msg.size}, 0, false, false, &need_clear)
						}
						no_wait_return -= 1
						xfree(rawptr(msg.items))
						xfree(transmute(rawptr)(fhname))
					}
					if choice == ML_SEA_READONLY_O {
						(^C.int)(uintptr(buf) + B_P_RO_OFF)^ = 1
					} else if choice == ML_SEA_EDIT_O {
					} else if choice == ML_SEA_RECOVER_O {
						swap_exists_action_g = SEA_RECOVER_O
					} else if choice == ML_SEA_DELETE_O {
						os_remove(transmute(cstring)(fname))
					} else if choice == ML_SEA_QUIT_O {
						swap_exists_action_g = SEA_QUIT_O
					} else if choice == ML_SEA_ABORT_O {
						swap_exists_action_g = SEA_QUIT_O
						got_int = true
					} else {
						msg_puts(cstring("\n"))
						if msg_silent == 0 {
							need_wait_return_g = true
						}
					}
					if choice != ML_SEA_NONE_O && !os_path_exists(transmute(cstring)(fname)) {
						break
					}
				}
			}
		}
		if f[n - 1] == 'a' {
			if f[n - 2] == 'a' {
				emsg(cstring("E326: Too many swap files found"))
				xfree(rawptr(fname))
				fname = nil
				break
			}
			f[n - 2] -= 1
			f[n - 1] = 'z' + 1
		}
		f[n - 1] -= 1
	}
	if os_isdir(transmute(cstring)(dir_name)) {
		found_existing_dir^ = true
	} else if !found_existing_dir^ && (([^]u8)(dirp^))[0] == 0 {
		failed_dir: cstring = nil
		ret := os_mkdir_recurse(transmute(cstring)(dir_name), 0o755, &failed_dir, nil)
		if ret != 0 {
			semsg(cstring("E303: Unable to create directory \"%s\" for swap file, recovery impossible: %s"), failed_dir, os_strerror(ret))
			xfree(transmute(rawptr)(failed_dir))
		}
	}
	xfree(rawptr(dir_name))
	return fname
}

// Open a swapfile for an existing memfile.
@(export)
ml_open_file :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	if mfp == nil || mfp.fd >= 0 || !(^bool)(uintptr(buf) + B_P_SWF_OFF_O)^ || (cmdmod_cmod_flags & CMOD_NOSWAPFILE_S) != 0 || (^rawptr)(uintptr(buf) + B_TERMINAL_OFF_O)^ != nil {
		return
	}
	if (^bool)(uintptr(buf) + B_SPELL_OFF_O)^ {
		fname := vim_tempname()
		if fname != nil {
			mf_open_file(mfp, fname)
		}
		(^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ = false
		return
	}
	dirp := p_dir_opt
	found_existing_dir := false
	for {
		if (([^]u8)(dirp))[0] == 0 {
			break
		}
		fname := findswapname(buf, &dirp, nil, &found_existing_dir)
		if dirp == nil {
			break
		}
		if fname == nil {
			continue
		}
		if mf_open_file(mfp, transmute(cstring)(fname)) == 1 {
			mfp.dirty = MF_DIRTY_YES_NOSYNC_O
			ml_upd_block0_o(buf, UB_SAME_DIR_O)
			if mf_sync(mfp, MFS_ZERO_O) == 1 {
				mf_set_dirty(mfp)
				break
			}
			mf_close_file(buf, false)
		}
	}
	if (([^]u8)(p_dir_opt))[0] != 0 && mfp.fname == nil {
		need_wait_return_g = true
		no_wait_return += 1
		sp := buf_spname(buf)
		spname := transmute(cstring)((^^u8)(uintptr(buf) + B_FNAME_OFF_O)^)
		if sp != nil {
			spname = transmute(cstring)(sp)
		}
		semsg(cstring("E303: Unable to open swap file for \"%s\", recovery impossible"), spname)
		no_wait_return -= 1
	}
	(^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ = false
}

// Open a swapfile for all buffers that need one.
@(export)
ml_open_files :: proc "c" () {
	context = runtime.default_context()
	buf := firstbuf
	for buf != nil {
		if (^C.int)(uintptr(buf) + B_P_RO_OFF)^ == 0 || bufIsChanged(buf) {
			ml_open_file(buf)
		}
		buf = (^rawptr)(uintptr(buf) + 120)^
	}
}

@(export)
check_need_swap :: proc "c" (newfile: bool) {
	context = runtime.default_context()
	old_silent := msg_silent
	msg_silent = 0
	ml := (^Memline_O)(uintptr(curbuf) + 8)
	_ = ml
	if (^bool)(uintptr(curbuf) + B_MAY_SWAP_OFF)^ && ((^C.int)(uintptr(curbuf) + B_P_RO_OFF)^ == 0 || !newfile) {
		ml_open_file(curbuf)
	}
	msg_silent = old_silent
}

// Rename the swapfile when the buffer file name changes.
@(export)
ml_setname :: proc "c" (buf: rawptr) {
	context = runtime.default_context()
	success := false
	ml := (^Memline_O)(uintptr(buf) + 8)
	mfp := ml.mfp
	if mfp.fd < 0 {
		if p_uc != 0 && (cmdmod_cmod_flags & CMOD_NOSWAPFILE_S) == 0 {
			ml_open_file(buf)
		}
		return
	}
	dirp := p_dir_opt
	found_existing_dir := false
	for {
		if (([^]u8)(dirp))[0] == 0 {
			break
		}
		fname := findswapname(buf, &dirp, transmute(cstring)(mfp.fname), &found_existing_dir)
		if dirp == nil {
			break
		}
		if fname == nil {
			continue
		}
		if path_fnamecmp_r(transmute(cstring)(fname), transmute(cstring)(mfp.fname)) == 0 {
			xfree(rawptr(fname))
			success = true
			break
		}
		if mfp.fd >= 0 {
			linux.close(linux.Fd(mfp.fd))
			mfp.fd = -1
		}
		if vim_rename_e(transmute(cstring)(mfp.fname), transmute(cstring)(fname)) == 0 {
			success = true
			mf_free_fnames(mfp)
			mf_set_fnames(mfp, transmute(cstring)(fname))
			ml_upd_block0_o(buf, UB_SAME_DIR_O)
			break
		}
		xfree(rawptr(fname))
	}
	if mfp.fd == -1 {
		mfp.fd = os_open(transmute(cstring)(mfp.fname), O_RDWR_O, 0)
		if mfp.fd < 0 {
			emsg(cstring("E301: Oops, lost the swap file!!!"))
			return
		}
		os_set_cloexec(mfp.fd)
	}
	if !success {
		emsg(cstring("E302: Could not rename swap file"))
	}
}

// Last proc_running value for the ATTENTION dialog (memline.c file-static).
ml_proc_running_g: C.int = 0

// Append bytes to a StringBuilder with xrealloc growth (kv_resize loses data).
ml_sb_append_o :: proc "c" (sb: ^StringBuilder, s: rawptr, len: C.size_t) {
	context = runtime.default_context()
	if len == 0 {
		return
	}
	need := sb.size + len + 1
	if need > sb.capacity {
		newcap := sb.capacity
		if newcap == 0 {
			newcap = 16
		}
		for newcap < need {
			newcap *= 2
		}
		sb.items = (^u8)(xrealloc(rawptr(sb.items), newcap))
		sb.capacity = newcap
	}
	libc.memcpy(rawptr(uintptr(sb.items) + uintptr(sb.size)), s, len)
	sb.size += len
	([^]u8)(sb.items)[sb.size] = 0
}

// Minimal kv_printf (%s/%d/%%) over ..any (own proc — no C vararg ABI issue).
ml_sb_printf_o :: proc "c" (sb: ^StringBuilder, fmt: cstring, args: ..any) {
	context = runtime.default_context()
	f := ([^]u8)(transmute(rawptr)(fmt))
	ai := 0
	i: uintptr = 0
	for f[i] != 0 {
		if f[i] != '%' {
			ml_sb_append_o(sb, rawptr(&f[i]), 1)
			i += 1
			continue
		}
		i += 1
		c := f[i]
		i += 1
		if c == '%' {
			pct: u8 = '%'
			ml_sb_append_o(sb, rawptr(&pct), 1)
		} else if c == 's' {
			a := args[ai]
			ai += 1
			if s, ok := a.(string); ok {
				ml_sb_append_o(sb, rawptr(raw_data(s)), C.size_t(len(s)))
			} else if cs, ok := a.(cstring); ok {
				ml_sb_append_o(sb, transmute(rawptr)(cs), C.size_t(libc.strlen(cs)))
			}
		} else if c == 'd' {
			a := args[ai]
			ai += 1
			n: i64 = 0
			if v, ok := a.(C.int); ok {
				n = i64(v)
			} else if v, ok := a.(int); ok {
				n = i64(v)
			} else if v, ok := a.(C.long); ok {
				n = i64(v)
			}
			nb: [32]u8
			neg := false
			if n < 0 {
				neg = true
				n = -n
			}
			pos := 31
			if n == 0 {
				nb[31] = '0'
			} else {
				for n > 0 && pos > 0 {
					nb[pos] = u8(n % 10) + '0'
					n /= 10
					pos -= 1
				}
				if neg {
					nb[pos] = '-'
				} else {
					pos += 1
				}
			}
			ml_sb_append_o(sb, rawptr(&nb[pos + 1]), C.size_t(31 - pos))
		}
	}
}

// True if the swapfile looks OK with no changes (memline.c static).
swapfile_unchanged_o :: proc "c" (fname: cstring) -> bool {
	context = runtime.default_context()
	b0: [1024]u8
	if !os_path_exists(fname) {
		return false
	}
	fd := os_open(fname, 0, 0)
	if fd < 0 {
		return false
	}
	if read_eintr_r(fd, rawptr(&b0[0]), 1024) != 1024 {
		linux.close(linux.Fd(fd))
		return false
	}
	ret := true
	if !ml_check_b0_id_o(rawptr(&b0[0])) || b0_magic_wrong_o(rawptr(&b0[0])) != 0 {
		ret = false
	}
	if b0[1007] != 0 {
		ret = false
	}
	if b0[68] == 0 {
		ret = false
	} else {
		hostname: [B0_HNAME_O]u8
		os_get_hostname(transmute(cstring)(&hostname[0]), B0_HNAME_O)
		hostname[B0_HNAME_O - 1] = 0
		b0[68 + B0_HNAME_O - 1] = 0
		if _strcasecmp(transmute(cstring)(&b0[68]), transmute(cstring)(&hostname[0])) != 0 {
			ret = false
		}
	}
	if char_to_long_o(transmute(^u8)(&b0[24])) == 0 || swapfile_proc_running_o(rawptr(&b0[0]), fname) != 0 {
		ret = false
	}
	linux.close(linux.Fd(fd))
	return ret
}

// NUL-termination check for b0 strings (memline.c static).
ml_check_b0_strings_o :: proc "c" (b0p: rawptr) -> bool {
	context = runtime.default_context()
	if libc.memchr(rawptr(b0p), 0, 10) == nil {
		return false
	}
	if libc.memchr(rawptr(uintptr(b0p) + 28), 0, B0_UNAME_O) == nil {
		return false
	}
	if libc.memchr(rawptr(uintptr(b0p) + 68), 0, B0_HNAME_O) == nil {
		return false
	}
	if libc.memchr(rawptr(uintptr(b0p) + 108), 0, B0_FNAME_CRYPT_O) == nil {
		return false
	}
	return true
}

// Load swapfile info into msg (memline.c static).
swapfile_info_o :: proc "c" (fname: cstring, msg: ^StringBuilder) -> C.long {
	context = runtime.default_context()
	x: C.long = 0
	uname: [B0_UNAME_O]u8
	fi: FileInfo
	if os_fileinfo(fname, &fi) {
		if os_get_uname(C.uint(fi.stat.st_uid), transmute(cstring)(&uname[0]), B0_UNAME_O) == 1 {
			ml_sb_printf_o(msg, cstring("%s%s"), cstring("          owned by: "), transmute(cstring)(&uname[0]))
			ml_sb_printf_o(msg, cstring("%s"), cstring("   dated: "))
		} else {
			ml_sb_printf_o(msg, cstring("%s"), cstring("             dated: "))
		}
		x = C.long(fi.stat.st_mtim.tv_sec)
		ctime_buf: [100]u8
		ml_sb_printf_o(msg, cstring("%s"), os_ctime_r(transmute(^posix.time_t)(&x), transmute([^]u8)(&ctime_buf[0]), 100, true))
	}
	b0: [1024]u8
	fd := os_open(fname, 0, 0)
	if fd >= 0 {
		if read_eintr_r(fd, rawptr(&b0[0]), 1024) == 1024 {
			if libc.strncmp(transmute(cstring)(&b0[2]), cstring("VIM 3.0"), 7) == 0 {
				ml_sb_printf_o(msg, cstring("%s"), cstring("         [from Vim version 3.0]"))
			} else if !ml_check_b0_id_o(rawptr(&b0[0])) {
				ml_sb_printf_o(msg, cstring("%s"), cstring("         [does not look like a Nvim swap file]"))
			} else if !ml_check_b0_strings_o(rawptr(&b0[0])) {
				ml_sb_printf_o(msg, cstring("%s"), cstring("         [garbled strings (not nul terminated)]"))
			} else {
				ml_sb_printf_o(msg, cstring("%s"), cstring("         file name: "))
				if b0[108] == 0 {
					ml_sb_printf_o(msg, cstring("%s"), cstring("[No Name]"))
				} else {
					ml_sb_printf_o(msg, cstring("%s"), transmute(cstring)(&b0[108]))
				}
				ml_sb_printf_o(msg, cstring("%s"), cstring("\n          modified: "))
				if b0[1007] != 0 {
					ml_sb_printf_o(msg, cstring("%s"), cstring("YES"))
				} else {
					ml_sb_printf_o(msg, cstring("%s"), cstring("no"))
				}
				if b0[28] != 0 {
					ml_sb_printf_o(msg, cstring("%s"), cstring("\n         user name: "))
					ml_sb_printf_o(msg, cstring("%s"), transmute(cstring)(&b0[28]))
				}
				if b0[68] != 0 {
					if b0[28] != 0 {
						ml_sb_printf_o(msg, cstring("%s"), cstring("   host name: "))
					} else {
						ml_sb_printf_o(msg, cstring("%s"), cstring("\n         host name: "))
					}
					ml_sb_printf_o(msg, cstring("%s"), transmute(cstring)(&b0[68]))
				}
				if char_to_long_o(transmute(^u8)(&b0[24])) != 0 {
					ml_sb_printf_o(msg, cstring("%s"), cstring("\n        process ID: "))
					ml_sb_printf_o(msg, cstring("%d"), C.int(char_to_long_o(transmute(^u8)(&b0[24]))))
					ml_proc_running_g = swapfile_proc_running_o(rawptr(&b0[0]), fname)
					if ml_proc_running_g != 0 {
						ml_sb_printf_o(msg, cstring("%s"), cstring(" (STILL RUNNING)"))
					}
				}
				if b0_magic_wrong_o(rawptr(&b0[0])) != 0 {
					ml_sb_printf_o(msg, cstring("%s"), cstring("\n         [not usable on this computer]"))
				}
			}
		} else {
			ml_sb_printf_o(msg, cstring("%s"), cstring("         [cannot be read]"))
		}
		linux.close(linux.Fd(fd))
	} else {
		ml_sb_printf_o(msg, cstring("%s"), cstring("         [cannot be opened]"))
	}
	ml_sb_printf_o(msg, cstring("\n"))
	return x
}

// Build the ATTENTION message (memline.c static).
attention_message_o :: proc "c" (buf: rawptr, fname: cstring, fhname: cstring, msg: ^StringBuilder) {
	context = runtime.default_context()
	b_fname := (^^u8)(uintptr(buf) + B_FNAME_OFF_O)^
	if b_fname == nil {
		libc.abort()
	}
	emsg(cstring("E325: ATTENTION"))
	ml_sb_printf_o(msg, cstring("%s"), cstring("Found a swap file by the name \""))
	ml_sb_printf_o(msg, cstring("%s\"\n"), fhname)
	swap_mtime := swapfile_info_o(fname, msg)
	ml_sb_printf_o(msg, cstring("%s"), cstring("While opening file \""))
	ml_sb_printf_o(msg, cstring("%s\"\n"), transmute(cstring)(b_fname))
	fi: FileInfo
	if !os_fileinfo(transmute(cstring)(b_fname), &fi) {
		ml_sb_printf_o(msg, cstring("%s"), cstring("      CANNOT BE FOUND"))
	} else {
		ml_sb_printf_o(msg, cstring("%s"), cstring("             dated: "))
		x := C.long(fi.stat.st_mtim.tv_sec)
		ctime_buf: [50]u8
		ml_sb_printf_o(msg, cstring("%s"), os_ctime_r(transmute(^posix.time_t)(&x), transmute([^]u8)(&ctime_buf[0]), 50, true))
		if swap_mtime != 0 && x > swap_mtime {
			ml_sb_printf_o(msg, cstring("%s"), cstring("      NEWER than swap file!\n"))
		}
	}
	ml_sb_printf_o(msg, cstring("%s"), cstring("\n(1) Another program may be editing the same file.  If this is the case,\n    be careful not to end up with two different instances of the same\n    file when making changes.  Quit, or continue with caution.\n"))
	ml_sb_printf_o(msg, cstring("%s"), cstring("(2) An edit session for this file crashed.\n"))
	ml_sb_printf_o(msg, cstring("%s"), cstring("    If this is the case, use \":recover\" or \"nvim -r "))
	ml_sb_printf_o(msg, cstring("%s"), transmute(cstring)(b_fname))
	ml_sb_printf_o(msg, cstring("%s"), cstring("\"\n    to recover the changes (see \":help recovery\").\n"))
	ml_sb_printf_o(msg, cstring("%s"), cstring("    If you did this already, delete the swap file \""))
	ml_sb_printf_o(msg, cstring("%s"), transmute(cstring)(fname))
	ml_sb_printf_o(msg, cstring("%s"), cstring("\"\n    to avoid this message.\n"))
}

// Trigger SwapExists autocommands (memline.c static).
do_swapexists_o :: proc "c" (buf: rawptr, fname: cstring) -> C.int {
	context = runtime.default_context()
	set_vim_var_string(VV_SWAPNAME_O, fname, -1)
	set_vim_var_string(VV_SWAPCHOICE_O, nil, -1)
	allbuf_lock_g += 1
	apply_autocmds(EVENT_SWAPEXISTS_O, transmute(cstring)((^^u8)(uintptr(buf) + B_FNAME_OFF_O)^), nil, false, nil)
	allbuf_lock_g -= 1
	set_vim_var_string(VV_SWAPNAME_O, nil, -1)
	vc := get_vim_var_str(VV_SWAPCHOICE_O)
	if vc == nil {
		return ML_SEA_NONE_O
	}
	ch := ([^]u8)(transmute(rawptr)(vc))[0]
	if ch == 'o' {
		return ML_SEA_READONLY_O
	} else if ch == 'e' {
		return ML_SEA_EDIT_O
	} else if ch == 'r' {
		return ML_SEA_RECOVER_O
	} else if ch == 'd' {
		return ML_SEA_DELETE_O
	} else if ch == 'q' {
		return ML_SEA_QUIT_O
	} else if ch == 'a' {
		return ML_SEA_ABORT_O
	}
	return ML_SEA_NONE_O
}

// Inode-aware file comparison (memline.c static).
fnamecmp_ino_o :: proc "c" (fname_c: cstring, fname_s: cstring, ino_block0: C.long) -> bool {
	context = runtime.default_context()
	ino_c: u64 = 0
	ino_s: u64
	buf_c: [MAXPATHL_O]u8
	buf_s: [MAXPATHL_O]u8
	fi: FileInfo
	if os_fileinfo(fname_c, &fi) {
		ino_c = os_fileinfo_inode(&fi)
	}
	if os_fileinfo(fname_s, &fi) {
		ino_s = os_fileinfo_inode(&fi)
	} else {
		ino_s = u64(ino_block0)
	}
	if ino_c != 0 && ino_s != 0 {
		return ino_c != ino_s
	}
	retval_c := vim_FullName_e(fname_c, transmute(cstring)(&buf_c[0]), MAXPATHL_O, true)
	retval_s := vim_FullName_e(fname_s, transmute(cstring)(&buf_s[0]), MAXPATHL_O, true)
	if retval_c == 1 && retval_s == 1 {
		return libc.strcmp(transmute(cstring)(&buf_c[0]), transmute(cstring)(&buf_s[0])) != 0
	}
	if ino_s == 0 && ino_c == 0 && retval_c == 0 && retval_s == 0 {
		return libc.strcmp(fname_c, fname_s) != 0
	}
	return true
}

// Recover curbuf from its swapfile.
@(export)
ml_recover :: proc "c" (checkext: bool) {
	context = runtime.default_context()
	buf: rawptr = nil
	mfp: ^Memfile_O = nil
	fname_used: ^u8 = nil
	hp: ^Bhdr_O = nil
	b0_fenc: ^u8 = nil
	directly := false
	serious_error: bool = true
	orig_file_status: C.int = NOTDONE_O
	recoverymode = true
	mlcur := (^Memline_O)(uintptr(curbuf) + 8)
	called_from_main := mlcur.mfp == nil
	fname := transmute(cstring)((^^u8)(uintptr(curbuf) + B_FNAME_OFF_O)^)
	if fname == nil {
		fname = cstring("")
	}
	flen := C.int(libc.strlen(fname))
	if checkext && flen >= 4 && mb_strnicmp_e(transmute(cstring)(rawptr(uintptr(transmute(rawptr)(fname)) + uintptr(flen) - 4)), cstring(".s"), 2) == 0 && vim_strchr(cstring("abcdefghijklmnopqrstuvw"), C.int(tolower_asc_o(([^]u8)(transmute(rawptr)(fname))[uintptr(flen) - 2]))) != nil && ASCII_ISALPHA(([^]u8)(transmute(rawptr)(fname))[uintptr(flen) - 1]) {
		directly = true
		fname_used = xstrdup(transmute(^u8)(fname))
	} else {
		items_tv := Typval_T{}
		tv_list_alloc_ret(transmute(^Typval)(&items_tv), 0)
		recover_names(fname, true, items_tv.vval)
		n_swaps := tv_list_len_o(items_tv.vval)
		if n_swaps == 0 {
			tv_clear(transmute(^Typval_T)(&items_tv))
			semsg(cstring("E305: No swap file found for %s"), fname)
			ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
			return
		}
		if n_swaps > 1 {
			argv: [2]Typval_T
			argv[0] = items_tv
			argv[1] = Typval_T{}
			nlua_call_typval_e(cstring("vim._core.swapfile"), cstring("select_swap"), &argv[0], nil)
			tv_clear(transmute(^Typval_T)(&items_tv))
			ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
			return
		}
		first := tv_list_first_o(items_tv.vval)
		fname_used = xstrdup(transmute(^u8)((^Typval_T)(uintptr(first) + 16).vval))
		tv_clear(transmute(^Typval_T)(&items_tv))
	}
	if fname_used == nil {
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	if called_from_main && ml_open(curbuf) == 0 {
		getout(1)
	}
	buf = xmalloc(12760)
	bml := (^Memline_O)(uintptr(buf) + 8)
	bml.stack_size = 0
	bml.stack = nil
	bml.stack_top = 0
	bml.line_lnum = 0
	bml.line_offset = 0
	bml.locked = nil
	bml.flags = 0
	p := xstrdup(fname_used)
	mfp = mf_open(transmute(cstring)(fname_used), 0)
	fname_used = p
	if mfp == nil || mfp.fd < 0 {
		semsg(cstring("E306: Cannot open %s"), transmute(cstring)(fname_used))
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	bml.mfp = mfp
	mfp.page_size = MIN_SWAP_PAGE_O
	hl_id: C.int = HLF_E_O
	msg_ext_set_kind(cstring("emsg"))
	hp = mf_get(mfp, 0, 1)
	if hp == nil {
		msg_start()
		msg_puts_hl(cstring("Unable to read block 0 from "), hl_id, true)
		msg_outtrans(transmute(cstring)(mfp.fname), hl_id, true)
		msg_puts_hl(cstring("\nMaybe no changes were made or Nvim did not update the swap file."), hl_id, true)
		msg_end()
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	b0p := rawptr(hp.data)
	if libc.strncmp(transmute(cstring)(rawptr(uintptr(b0p) + 2)), cstring("VIM 3.0"), 7) == 0 {
		msg_start()
		msg_outtrans(transmute(cstring)(mfp.fname), 0, true)
		msg_puts_hl(cstring(" cannot be used with this version of Nvim.\n"), 0, true)
		msg_puts_hl(cstring("Use Vim version 3.0.\n"), 0, true)
		msg_end()
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	if !ml_check_b0_id_o(b0p) {
		semsg(cstring("E307: %s does not look like a Nvim swap file"), transmute(cstring)(mfp.fname))
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	if b0_magic_wrong_o(b0p) != 0 {
		msg_start()
		msg_outtrans(transmute(cstring)(mfp.fname), hl_id, true)
		msg_puts_hl(cstring(" cannot be used on this computer.\n"), hl_id, true)
		msg_puts_hl(cstring("The file was created on "), hl_id, true)
		([^]u8)(uintptr(b0p) + B0_FNAME_AT_O)[0] = 0
		msg_puts_hl(transmute(cstring)(rawptr(uintptr(b0p) + 68)), hl_id, true)
		msg_puts_hl(cstring(",\nor the file has been damaged."), hl_id, true)
		msg_end()
		ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
		return
	}
	if mfp.page_size != u32(char_to_long_o(transmute(^u8)(rawptr(uintptr(b0p) + 12)))) {
		previous_page_size := mfp.page_size
		mf_new_page_size(mfp, u32(char_to_long_o(transmute(^u8)(rawptr(uintptr(b0p) + 12)))))
		if mfp.page_size < previous_page_size {
			msg_start()
			msg_outtrans(transmute(cstring)(mfp.fname), hl_id, true)
			msg_puts_hl(cstring(" has been damaged (page size is smaller than minimum value).\n"), hl_id, true)
			msg_end()
			ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
			return
		}
		size := mf_lseek_o(mfp.fd, 0, .END)
		if size <= 0 {
			mfp.blocknr_max = 0
		} else {
			mfp.blocknr_max = size / i64(mfp.page_size)
		}
		mfp.infile_count = mfp.blocknr_max
		np := xmalloc(C.size_t(mfp.page_size))
		libc.memmove(rawptr(np), hp.data, C.size_t(previous_page_size))
		xfree(hp.data)
		hp.data = np
		b0p = rawptr(hp.data)
	}
	if directly {
		bs := uintptr(b0p) + B0_FNAME_AT_O
		i := 0
		for i < 900 {
			if ([^]u8)(bs)[uintptr(i)] == '\\' {
				([^]u8)(bs)[uintptr(i)] = '/'
			}
			i += 1
		}
		expand_env(transmute(cstring)(rawptr(bs)), transmute(cstring)(&name_buff[0]), MAXPATHL_O)
		if setfname(curbuf, transmute(cstring)(&name_buff[0]), nil, true) == 0 {
			ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
			return
		}
	}
	msg_ext_set_kind(cstring("wmsg"))
	msg_ext_skip_flush = true
	home_replace(nil, transmute(cstring)(mfp.fname), transmute(cstring)(&name_buff[0]), MAXPATHL_O, true)
	smsg(0, cstring("Using swap file \"%s\""), transmute(cstring)(&name_buff[0]))
	sp := buf_spname(curbuf)
	if sp != nil {
		xstrlcpy(transmute(cstring)(&name_buff[0]), transmute(cstring)(sp), MAXPATHL_O)
	} else {
		home_replace(nil, transmute(cstring)((^^u8)(uintptr(curbuf) + B_FFNAME_OFF_O)^), transmute(cstring)(&name_buff[0]), MAXPATHL_O, true)
	}
	msg_putchar('\n')
	smsg(0, cstring("Original file \"%s\""), transmute(cstring)(&name_buff[0]))
	msg_putchar('\n')
	msg_ext_skip_flush = false
	org_file_info: FileInfo
	swp_file_info: FileInfo
	mtime := C.long(char_to_long_o(transmute(^u8)(rawptr(uintptr(b0p) + 16))))
	cff := (^^u8)(uintptr(curbuf) + B_FFNAME_OFF_O)^
	if cff != nil && os_fileinfo(transmute(cstring)(cff), &org_file_info) && ((os_fileinfo(transmute(cstring)(mfp.fname), &swp_file_info) && i64(org_file_info.stat.st_mtim.tv_sec) > i64(swp_file_info.stat.st_mtim.tv_sec)) || i64(org_file_info.stat.st_mtim.tv_sec) != i64(mtime)) {
		emsg(cstring("E308: Warning: Original file may have been changed"))
	}
	ui_flush()
	b0_ff := C.int(([^]u8)(uintptr(b0p) + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 2]) & B0_FF_MASK_O
	if (([^]u8)(uintptr(b0p) + B0_FNAME_AT_O)[B0_FNAME_MAX_O - 2] & B0_HAS_FENC_O) != 0 {
		fnsize := B0_FNAME_NOCRYPT_O
		fp := rawptr(uintptr(b0p) + B0_FNAME_AT_O + uintptr(fnsize))
		for fp != rawptr(uintptr(b0p) + B0_FNAME_AT_O) && ([^]u8)(rawptr(uintptr(fp) - 1))[0] != 0 {
			fp = rawptr(uintptr(fp) - 1)
		}
		b0_fenc = transmute(^u8)(xstrnsave(transmute(cstring)(fp), C.size_t(uintptr(b0p) + B0_FNAME_AT_O + uintptr(fnsize) - uintptr(fp))))
	}
	mf_put(mfp, hp, false, false)
	hp = nil
	for (mlcur.flags & ML_EMPTY_O) == 0 {
		ml_delete(1)
	}
	if cff != nil {
		orig_file_status = readfile_e(transmute(^u8)(cff), nil, 0, 0, MAXLNUM, nil, READ_NEW_O, false)
	}
	if b0_ff != 0 {
		set_fileformat(b0_ff - 1, OPT_LOCAL_S)
	}
	if b0_fenc != nil {
		set_option_value_give_err(kOptFileencoding_E, str_optval(b0_fenc, C.size_t(libc.strlen(transmute(cstring)(b0_fenc)))), OPT_LOCAL_S)
		xfree(rawptr(b0_fenc))
	}
	unchanged(curbuf, true, true)
	bnum: i64 = 1
	page_count: u32 = 1
	lnum: C.int = 0
	line_count: C.int = 0
	idx: C.int = 0
	error: C.int = 0
	bml.stack_top = 0
	bml.stack = nil
	bml.stack_size = 0
	cannot_open := cff == nil
	serious_error = false
	for !got_int {
		if hp != nil {
			mf_put(mfp, hp, false, false)
		}
		hp = mf_get(mfp, bnum, page_count)
		if hp == nil {
			if bnum == 1 {
				semsg(cstring("E309: Unable to read block 1 from %s"), transmute(cstring)(mfp.fname))
				ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
				return
			}
			error += 1
			ml_append(lnum, transmute(^u8)(cstring("???MANY LINES MISSING")), 0, true)
			lnum += 1
		} else {
			if ([^]u16)(hp.data)[0] == PTR_ID_O {
				ptr_block_error := false
				pb_max := u16((u32(mfp.page_size) - PB_POINTER_AT_O) / 24)
				if ([^]u16)(hp.data)[2] != pb_max {
					ptr_block_error = true
					([^]u16)(hp.data)[2] = pb_max
				}
				if ([^]u16)(hp.data)[1] > ([^]u16)(hp.data)[2] {
					ptr_block_error = true
					([^]u16)(hp.data)[1] = ([^]u16)(hp.data)[2]
				}
				if ptr_block_error {
					emsg(cstring("E1364: Warning: Pointer block corrupted"))
				}
				if idx == 0 && line_count != 0 {
					i := C.int(0)
					for i < C.int(([^]u16)(hp.data)[1]) {
						line_count -= ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[i].line_count
						i += 1
					}
					if line_count != 0 {
						error += 1
						ml_append(lnum, transmute(^u8)(cstring("???LINE COUNT WRONG")), 0, true)
						lnum += 1
					}
				}
				if ([^]u16)(hp.data)[1] == 0 {
					ml_append(lnum, transmute(^u8)(cstring("???EMPTY BLOCK")), 0, true)
					lnum += 1
					error += 1
				} else if idx < C.int(([^]u16)(hp.data)[1]) {
					pe_bnum := ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].bnum
					if pe_bnum < 0 {
						if !cannot_open {
							line_count = ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].line_count
							pe_old_lnum := ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].old_lnum
							if line_count <= 0 || pe_old_lnum < 1 || readfile_e(transmute(^u8)(cff), nil, lnum, pe_old_lnum - 1, line_count, nil, 0, false) != 1 {
								cannot_open = true
							} else {
								lnum += line_count
							}
						}
						if cannot_open {
							error += 1
							ml_append(lnum, transmute(^u8)(cstring("???LINES MISSING")), 0, true)
							lnum += 1
						}
						idx += 1
						line_breakcheck()
						continue
					}
					top := ml_add_stack_o(buf)
					ip := &([^]Infoptr_O)(bml.stack)[top]
					ip.bnum = bnum
					ip.index = idx
					bnum = ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].bnum
					line_count = ([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].line_count
					page_count = u32(([^]PointerEntry_O)(uintptr(hp.data) + PB_POINTER_AT_O)[idx].page_count)
					if page_count < 1 || bnum + i64(page_count) > mfp.blocknr_max + 1 {
						error += 1
						ml_append(lnum, transmute(^u8)(cstring("???ILLEGAL BLOCK NUMBER")), 0, true)
						lnum += 1
						idx = ip.index + 1
						bnum = ip.bnum
						page_count = 1
						bml.stack_top -= 1
						line_breakcheck()
						continue
					}
					idx = 0
					line_breakcheck()
					continue
				}
			} else {
				dp := (^DataBlock_O)(hp.data)
				if dp.id != DATA_ID_O {
					if bnum == 1 {
						semsg(cstring("E310: Block 1 ID wrong (%s not a .swp file?)"), transmute(cstring)(mfp.fname))
						ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
						return
					}
					error += 1
					ml_append(lnum, transmute(^u8)(cstring("???BLOCK MISSING")), 0, true)
					lnum += 1
				} else {
					has_error := false
					if hp.page_count != page_count {
						error += 1
						ml_append(lnum, transmute(^u8)(cstring("??? BLOCK PAGE COUNT MISMATCH")), 0, true)
						lnum += 1
						page_count = hp.page_count
					}
					if u64(page_count) * u64(mfp.page_size) != u64(dp.txt_end) {
						ml_append(lnum, transmute(^u8)(cstring("??? from here until ???END lines may be messed up")), 0, true)
						lnum += 1
						error += 1
						has_error = true
						dp.txt_end = u32(u64(page_count) * u64(mfp.page_size))
					}
					if dp.txt_start < HEADER_SIZE_O || dp.txt_start > dp.txt_end {
						ml_append(lnum, transmute(^u8)(cstring("??? block header corrupted")), 0, true)
						lnum += 1
						error += 1
						has_error = true
						dp.txt_start = dp.txt_end
					}
					([^]u8)(uintptr(hp.data) + uintptr(dp.txt_end) - 1)[0] = 0
					if line_count != C.int(dp.line_count) {
						ml_append(lnum, transmute(^u8)(cstring("??? from here until ???END lines may have been inserted/deleted")), 0, true)
						lnum += 1
						error += 1
						has_error = true
					}
					did_questions := false
					i := i64(0)
					for i < dp.line_count {
						if uintptr(rawptr(&([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i])) >= uintptr(hp.data) + uintptr(dp.txt_start) {
							error += 1
							ml_append(lnum, transmute(^u8)(cstring("??? lines may be missing")), 0, true)
							lnum += 1
							break
						}
						txt_start := C.int(([^]u32)(uintptr(hp.data) + HEADER_SIZE_O)[i] & DB_INDEX_MASK_O)
						lp: ^u8
						if txt_start <= C.int(HEADER_SIZE_O) || txt_start >= C.int(dp.txt_end) {
							error += 1
							if !did_questions {
								did_questions = true
								lp = transmute(^u8)(cstring("???"))
							} else {
								i += 1
								continue
							}
						} else {
							did_questions = false
							lp = transmute(^u8)(rawptr(uintptr(hp.data) + uintptr(txt_start)))
						}
						ml_append(lnum, lp, 0, true)
						lnum += 1
						i += 1
					}
					if has_error {
						ml_append(lnum, transmute(^u8)(cstring("???END")), 0, true)
						lnum += 1
					}
				}
			}
		}
		if bml.stack_top == 0 {
			break
		}
		bml.stack_top -= 1
		ip := &([^]Infoptr_O)(bml.stack)[bml.stack_top]
		bnum = ip.bnum
		idx = ip.index + 1
		page_count = 1
		line_breakcheck()
	}
	if orig_file_status != 1 || mlcur.line_count != lnum * 2 + 1 {
		if !(mlcur.line_count == 2 && ml_get(1)^ == 0) {
			changed_internal(curbuf)
			buf_inc_changedtick(curbuf)
		}
	} else {
		idx = 1
		for idx <= lnum {
			p := xstrnsave(transmute(cstring)(ml_get(idx)), C.size_t(ml_get_len(idx)))
			i := libc.strcmp(transmute(cstring)(p), transmute(cstring)(ml_get(idx + lnum)))
			xfree(rawptr(p))
			if i != 0 {
				changed_internal(curbuf)
				buf_inc_changedtick(curbuf)
				break
			}
			idx += 1
		}
	}
	for mlcur.line_count > lnum && (mlcur.flags & ML_EMPTY_O) == 0 {
		ml_delete(mlcur.line_count)
	}
	(^C.int)(uintptr(curbuf) + B_FLAGS_OFF_O)^ |= BF_RECOVERED_O
	check_cursor(curwin)
	msg_ext_skip_flush = !got_int
	recoverymode = false
	if got_int {
		emsg(cstring("E311: Recovery Interrupted"))
	} else if error != 0 {
		no_wait_return += 1
		msg_ext_set_kind(cstring("emsg"))
		msg(cstring(">>>>>>>>>>>>>\n"), 0)
		emsg(cstring("E312: Errors detected while recovering; look for lines starting with ???"))
		no_wait_return -= 1
		msg_putchar('\n')
		msg(cstring("See \":help E312\" for more information."), 0)
		msg(cstring("\n>>>>>>>>>>>>>"), 0)
	} else {
		msg_ext_set_kind(cstring("wmsg"))
		if (^bool)(uintptr(curbuf) + B_CHG_OFF_O)^ {
			msg(cstring("Recovery completed. You should check if everything is OK."), 0)
			msg_puts(cstring("\n(You might want to write out this file under another name\n"))
			msg_puts(cstring("and run diff with the original file to check for changes)"))
		} else {
			msg(cstring("Recovery completed. Buffer contents equals file contents."), 0)
		}
		msg_puts(cstring("\nYou may want to delete the .swp file now."))
		if swapfile_proc_running_o(b0p, transmute(cstring)(fname_used)) != 0 {
			msg_puts(cstring("\nNote: process STILL RUNNING: "))
			msg_outnum(C.int(char_to_long_o(transmute(^u8)(rawptr(uintptr(b0p) + 24)))))
		}
		if !ui_has(K_UIMESSAGES_O) {
			msg_puts(cstring("\n\n"))
		}
		cmdline_row = msg_row
	}
	redraw_curbuf_later(UPD_NOT_VALID_S)
	ml_recover_end_o(buf, mfp, fname_used, hp, serious_error, called_from_main)
}

// Shared epilogue for ml_recover (C's theend label).
ml_recover_end_o :: proc "c" (buf: rawptr, mfp: ^Memfile_O, fname_used: ^u8, hp: ^Bhdr_O, serious_error: bool, called_from_main: bool) {
	context = runtime.default_context()
	msg_ext_skip_flush = false
	xfree(rawptr(fname_used))
	recoverymode = false
	if mfp != nil {
		if hp != nil {
			mf_put(mfp, hp, false, false)
		}
		mf_close(mfp, false)
	}
	if buf != nil {
		bml := (^Memline_O)(uintptr(buf) + 8)
		xfree(rawptr(bml.stack))
		xfree(rawptr(buf))
	}
	if serious_error && called_from_main {
		ml_close(curbuf, 1)
	} else {
		apply_autocmds(EVENT_BUFREADPOST_O, nil, transmute(cstring)((^^u8)(uintptr(curbuf) + B_FNAME_OFF_O)^), false, curbuf)
		apply_autocmds(EVENT_BUFWINENTER_O, nil, transmute(cstring)((^^u8)(uintptr(curbuf) + B_FNAME_OFF_O)^), false, curbuf)
	}
}
