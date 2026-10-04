package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/linux"
import "core:sys/posix"

// memfile.c port: swap-file block manager (virtual memory for buffers).
// All 17 publics are @(export); the 8 C-statics are _o dormant plains.

foreign _ {
	@(link_name = "did_swapwrite_msg")
	did_swapwrite_msg: bool
	@(link_name = "write_eintr")
	write_eintr_e :: proc "c" (fd: C.int, buf: rawptr, bufsize: C.size_t) -> C.ssize_t ---
}

// vim_lseek (os_defs.h macro over lseek/lseek64).
mf_lseek_o :: proc "c" (fd: C.int, offset: i64, whence: posix.Whence) -> i64 {
	return i64(posix.lseek(posix.FD(fd), posix.off_t(offset), whence))
}

E_BLOCK_NOT_LOCKED_S :: "E293: Block was not locked"
E_SWAP_SEEK_READ_S :: "E294: Seek error in swap file read"
E_SWAP_READ_S :: "E295: Read error in swap file"
E_SWAP_SEEK_WRITE_S :: "E296: Seek error in swap file write"
E_SWAP_WRITE_S :: "E297: Write error in swap file"
E_SWAP_SYMLINK_S :: "E300: Swap file already exists (symlink attack?)"
E_SWAPCLOSE_S :: "E72: Close error on swap file"

MFS_ALL_O :: 1
MFS_STOP_O :: 2
MFS_FLUSH_O :: 4
MFS_ZERO_O :: 8
BH_DIRTY_O :: 1
BH_LOCKED_O :: 2
MF_DIRTY_NO_O :: 0
MIN_SWAP_PAGE_O :: 1048
MAX_SWAP_PAGE_O :: 50000
MEMFILE_PAGE_O :: 4096

O_RDWR_O :: 2
O_CREAT_O :: 64
O_EXCL_O :: 128
O_TRUNC_O :: 512
O_NOFOLLOW_O :: 131072
S_IREAD_WRITE_O :: 384
SEEK_SET_O :: 0
SEEK_END_O :: 2
B_MAY_SWAP_OFF :: 11168

// bhdr_T mirror (cc-probed, 24B).
Bhdr_O :: struct {
	bnum:       i64,
	data:       rawptr,
	page_count: u32,
	flags:      u32,
}
#assert(size_of(Bhdr_O) == 24)

// memfile_T mirror (cc-probed, 176B).
Memfile_O :: struct {
	fname:       ^u8,
	ffname:      ^u8,
	fd:          C.int,
	flags:       C.int,
	reopen:      bool,
	_pad0:       [7]u8,
	free_first:  rawptr,
	hash:        Map_int64_t_ptr_t,
	trans:       Map_int64_t_int64_t,
	blocknr_max: i64,
	blocknr_min: i64,
	neg_count:   i64,
	infile_count: i64,
	page_size:   u32,
	dirty:       C.int,
}
#assert(size_of(Memfile_O) == 176)

// pmap helpers over mf_hash (dense values[0..n_keys], foreach pattern).
mf_hash_get_o :: proc "c" (mfp: ^Memfile_O, nr: i64) -> ^Bhdr_O {
	context = runtime.default_context()
	k := mh_get_int64_t(&mfp.hash.set, nr)
	if k == MH_TOMBSTONE {
		return nil
	}
	return (^Bhdr_O)(([^]rawptr)(mfp.hash.values)[uintptr(k)])
}

mf_hash_put_o :: proc "c" (mfp: ^Memfile_O, nr: i64, hp: ^Bhdr_O) {
	context = runtime.default_context()
	map_put_ref_int64_t_ptr_t(&mfp.hash, nr, nil, nil)^ = rawptr(hp)
}

mf_hash_del_o :: proc "c" (mfp: ^Memfile_O, nr: i64) {
	context = runtime.default_context()
	map_del_int64_t_ptr_t(&mfp.hash, nr, nil)
}

mf_hash_destroy_o :: proc "c" (mfp: ^Memfile_O) {
	context = runtime.default_context()
	xfree(rawptr(mfp.hash.set.keys))
	xfree(rawptr(mfp.hash.set.h.hash))
	mfp.hash.set = Set_int64_t{}
	xfree(rawptr(mfp.hash.values))
	mfp.hash.values = nil
	xfree(rawptr(mfp.trans.set.keys))
	xfree(rawptr(mfp.trans.set.h.hash))
	mfp.trans.set = Set_int64_t{}
	xfree(rawptr(mfp.trans.values))
	mfp.trans.values = nil
}

// PERROR(msg) = semsg("%s: %s", msg, strerror(errno)).
mf_perror_o :: proc "c" (msg: cstring) {
	context = runtime.default_context()
	err := posix.errno()
	semsg(cstring("%s: %s"), msg, libc.strerror(C.int(err)))
}

// Allocate a block header and a block of memory for it.
mf_alloc_bhdr_o :: proc "c" (mfp: ^Memfile_O, page_count: u32) -> ^Bhdr_O {
	context = runtime.default_context()
	hp := (^Bhdr_O)(xmalloc(size_of(Bhdr_O)))
	hp.data = xmalloc(C.size_t(mfp.page_size) * C.size_t(page_count))
	hp.page_count = page_count
	return hp
}

// Free a block header and its block memory.
mf_free_bhdr_o :: proc "c" (hp: ^Bhdr_O) {
	context = runtime.default_context()
	xfree(hp.data)
	xfree(rawptr(hp))
}

// Insert a block in the free list.
mf_ins_free_o :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O) {
	context = runtime.default_context()
	hp.data = mfp.free_first
	mfp.free_first = rawptr(hp)
}

// Remove the first block in the free list and return it.
mf_rem_free_o :: proc "c" (mfp: ^Memfile_O) -> ^Bhdr_O {
	context = runtime.default_context()
	hp := (^Bhdr_O)(mfp.free_first)
	mfp.free_first = hp.data
	return hp
}

// Open a new or existing memory block file.
@(export)
mf_open :: proc "c" (fname: cstring, flags: C.int) -> ^Memfile_O {
	context = runtime.default_context()
	mfp := (^Memfile_O)(xcalloc(1, size_of(Memfile_O)))
	if fname == nil {
		mfp.fd = -1
	} else {
		if !mf_do_open_o(mfp, transmute(^u8)(fname), flags) {
			xfree(rawptr(mfp))
			return nil
		}
	}
	mfp.free_first = nil
	mfp.dirty = MF_DIRTY_NO_O
	mfp.page_size = MEMFILE_PAGE_O
	fi: FileInfo
	if mfp.fd >= 0 && os_fileinfo_fd(mfp.fd, &fi) {
		blocksize := os_fileinfo_blocksize(&fi)
		if blocksize >= MIN_SWAP_PAGE_O && blocksize <= MAX_SWAP_PAGE_O {
			mfp.page_size = u32(blocksize)
		}
	}
	if mfp.fd < 0 || (flags & (O_TRUNC_O | O_EXCL_O)) != 0 {
		mfp.blocknr_max = 0
	} else {
		size := mf_lseek_o(mfp.fd, 0, .END)
		if size <= 0 {
			mfp.blocknr_max = 0
		} else {
			mfp.blocknr_max = (size + i64(mfp.page_size) - 1) / i64(mfp.page_size)
		}
	}
	mfp.blocknr_min = -1
	mfp.neg_count = 0
	mfp.infile_count = mfp.blocknr_max
	return mfp
}

// Open a file for an existing memfile.
@(export)
mf_open_file :: proc "c" (mfp: ^Memfile_O, fname: cstring) -> C.int {
	context = runtime.default_context()
	if mf_do_open_o(mfp, transmute(^u8)(fname), O_RDWR_O | O_CREAT_O | O_EXCL_O) {
		mfp.dirty = MF_DIRTY_YES_O
		return 1
	}
	return 0
}

// Close a memory file and optionally delete the associated file.
@(export)
mf_close :: proc "c" (mfp: ^Memfile_O, del_file: bool) {
	context = runtime.default_context()
	if mfp == nil {
		return
	}
	if mfp.fd >= 0 && linux.close(linux.Fd(mfp.fd)) != .NONE {
		emsg(cstring(E_SWAPCLOSE_S))
	}
	if del_file && mfp.fname != nil {
		os_remove(transmute(cstring)(mfp.fname))
	}
	i: u32 = 0
	for i < mfp.hash.set.h.n_keys {
		mf_free_bhdr_o((^Bhdr_O)(([^]rawptr)(mfp.hash.values)[uintptr(i)]))
		i += 1
	}
	for mfp.free_first != nil {
		xfree(rawptr(mf_rem_free_o(mfp)))
	}
	mf_hash_destroy_o(mfp)
	mf_free_fnames(mfp)
	xfree(rawptr(mfp))
}

// Close the swap file for a memfile. Used when 'swapfile' is reset.
@(export)
mf_close_file :: proc "c" (buf: rawptr, getlines: bool) {
	context = runtime.default_context()
	mfp := (^Memfile_O)((^rawptr)(uintptr(buf) + 16)^)
	if mfp == nil || mfp.fd < 0 {
		return
	}
	if getlines {
		lnum: C.int = 1
		for lnum <= (^C.int)(uintptr(buf) + 8)^ {
			ml_get_buf(buf, lnum)
			lnum += 1
		}
	}
	if linux.close(linux.Fd(mfp.fd)) != .NONE {
		emsg(cstring(E_SWAPCLOSE_S))
	}
	mfp.fd = -1
	if mfp.fname != nil {
		os_remove(transmute(cstring)(mfp.fname))
		mf_free_fnames(mfp)
	}
}

// Set new size for a memfile.
@(export)
mf_new_page_size :: proc "c" (mfp: ^Memfile_O, new_size: u32) {
	context = runtime.default_context()
	mfp.page_size = new_size
}

// Get a new block.
@(export)
mf_new :: proc "c" (mfp: ^Memfile_O, negative: bool, page_count: u32) -> ^Bhdr_O {
	context = runtime.default_context()
	hp: ^Bhdr_O = nil
	freep := (^Bhdr_O)(mfp.free_first)
	if !negative && freep != nil && freep.page_count >= page_count {
		if freep.page_count > page_count {
			hp = mf_alloc_bhdr_o(mfp, page_count)
			hp.bnum = freep.bnum
			freep.bnum += i64(page_count)
			freep.page_count -= page_count
		} else {
			p := xmalloc(C.size_t(mfp.page_size) * C.size_t(page_count))
			hp = mf_rem_free_o(mfp)
			hp.data = p
		}
	} else {
		hp = mf_alloc_bhdr_o(mfp, page_count)
		if negative {
			hp.bnum = mfp.blocknr_min
			mfp.blocknr_min -= 1
			mfp.neg_count += 1
		} else {
			hp.bnum = mfp.blocknr_max
			mfp.blocknr_max += i64(page_count)
		}
	}
	hp.flags = BH_LOCKED_O | BH_DIRTY_O
	mfp.dirty = MF_DIRTY_YES_O
	hp.page_count = page_count
	mf_hash_put_o(mfp, hp.bnum, hp)
	libc.memset(hp.data, 0, C.size_t(mfp.page_size) * C.size_t(page_count))
	return hp
}

// Get existing block "nr" with "page_count" pages.
@(export)
mf_get :: proc "c" (mfp: ^Memfile_O, nr: i64, page_count: u32) -> ^Bhdr_O {
	context = runtime.default_context()
	if nr >= mfp.blocknr_max || nr <= mfp.blocknr_min {
		return nil
	}
	hp := mf_hash_get_o(mfp, nr)
	if hp == nil {
		if nr < 0 || nr >= mfp.infile_count {
			return nil
		}
		if page_count > 0 {
			hp = mf_alloc_bhdr_o(mfp, page_count)
		}
		if hp == nil {
			return nil
		}
		hp.bnum = nr
		hp.flags = 0
		hp.page_count = page_count
		if mf_read_o(mfp, hp) == 0 {
			mf_free_bhdr_o(hp)
			return nil
		}
	} else {
		mf_hash_del_o(mfp, hp.bnum)
	}
	hp.flags |= BH_LOCKED_O
	mf_hash_put_o(mfp, hp.bnum, hp)
	return hp
}

// Release the block *hp.
@(export)
mf_put :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O, dirty: bool, infile: bool) {
	context = runtime.default_context()
	flags := hp.flags
	if (flags & BH_LOCKED_O) == 0 {
		iemsg(cstring(E_BLOCK_NOT_LOCKED_S))
	}
	flags &= ~u32(BH_LOCKED_O)
	if dirty {
		flags |= BH_DIRTY_O
		if mfp.dirty != MF_DIRTY_YES_NOSYNC_O {
			mfp.dirty = MF_DIRTY_YES_O
		}
	}
	hp.flags = flags
	if infile {
		mf_trans_add_o(mfp, hp)
	}
}

// Signal block as no longer used (may put it in the free list).
@(export)
mf_free :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O) {
	context = runtime.default_context()
	xfree(hp.data)
	mf_hash_del_o(mfp, hp.bnum)
	if hp.bnum < 0 {
		xfree(rawptr(hp))
		mfp.neg_count -= 1
	} else {
		mf_ins_free_o(mfp, hp)
	}
}

// Sync memory file to disk.
@(export)
mf_sync :: proc "c" (mfp: ^Memfile_O, flags: C.int) -> C.int {
	context = runtime.default_context()
	got_int_save := got_int
	if mfp.fd < 0 {
		mfp.dirty = MF_DIRTY_NO_O
		return 0
	}
	got_int = false
	status: C.int = 1
	hp: ^Bhdr_O = nil
	i: u32 = 0
	for i < mfp.hash.set.h.n_keys {
		hp = (^Bhdr_O)(([^]rawptr)(mfp.hash.values)[uintptr(i)])
		if ((flags & MFS_ALL_O) != 0 || hp.bnum >= 0) && (hp.flags & BH_DIRTY_O) != 0 &&
		   (status == 1 || (hp.bnum >= 0 && hp.bnum < mfp.infile_count)) {
			if (flags & MFS_ZERO_O) != 0 && hp.bnum != 0 {
				i += 1
				continue
			}
			if mf_write_o(mfp, hp) == 0 {
				if status == 0 {
					break
				}
				status = 0
			}
			if (flags & MFS_STOP_O) != 0 {
				if os_char_avail() {
					break
				}
			} else if main_loop.recursive == 0 {
				os_breakcheck()
			}
			if got_int {
				break
			}
		}
		i += 1
	}
	if hp == nil || status == 0 {
		mfp.dirty = MF_DIRTY_NO_O
	}
	if (flags & MFS_FLUSH_O) != 0 {
		if os_fsync(mfp.fd) != 0 {
			status = 0
		}
	}
	got_int = got_int || got_int_save
	return status
}

// Set dirty flag for all blocks with a positive block number.
@(export)
mf_set_dirty :: proc "c" (mfp: ^Memfile_O) {
	context = runtime.default_context()
	i: u32 = 0
	for i < mfp.hash.set.h.n_keys {
		hp := (^Bhdr_O)(([^]rawptr)(mfp.hash.values)[uintptr(i)])
		if hp.bnum > 0 {
			hp.flags |= BH_DIRTY_O
		}
		i += 1
	}
	mfp.dirty = MF_DIRTY_YES_O
}

// Release as many blocks as possible. Used in case of out of memory.
@(export)
mf_release_all :: proc "c" () -> bool {
	context = runtime.default_context()
	retval := false
	buf := firstbuf
	for buf != nil {
		mfp := (^Memfile_O)((^rawptr)(uintptr(buf) + 16)^)
		if mfp != nil {
			if mfp.fd < 0 && (^bool)(uintptr(buf) + B_MAY_SWAP_OFF)^ {
				ml_open_file(buf)
			}
			if mfp.fd >= 0 {
				i: u32 = 0
				for i < mfp.hash.set.h.n_keys {
					hp := (^Bhdr_O)(([^]rawptr)(mfp.hash.values)[uintptr(i)])
					if (hp.flags & BH_LOCKED_O) == 0 &&
					   ((hp.flags & BH_DIRTY_O) == 0 || mf_write_o(mfp, hp) != 0) {
						mf_hash_del_o(mfp, hp.bnum)
						mf_free_bhdr_o(hp)
						retval = true
					} else {
						i += 1
					}
				}
			}
		}
		buf = (^rawptr)(uintptr(buf) + 120)^
	}
	return retval
}

// Read a block from disk.
mf_read_o :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O) -> C.int {
	context = runtime.default_context()
	if mfp.fd < 0 {
		return 0
	}
	page_size := mfp.page_size
	offset := i64(page_size) * hp.bnum
	if mf_lseek_o(mfp.fd, offset, .SET) != offset {
		mf_perror_o(cstring(E_SWAP_SEEK_READ_S))
		return 0
	}
	if hp.page_count > max(u32) / page_size {
		libc.abort()
	}
	size := page_size * hp.page_count
	if u32(read_eintr_r(mfp.fd, hp.data, C.size_t(size))) != size {
		mf_perror_o(cstring(E_SWAP_READ_S))
		return 0
	}
	return 1
}

// Write a block to disk.
mf_write_o :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O) -> C.int {
	context = runtime.default_context()
	if mfp.fd < 0 && !mfp.reopen {
		return 0
	}
	if hp.bnum < 0 {
		if mf_trans_add_o(mfp, hp) == 0 {
			return 0
		}
	}
	page_size := mfp.page_size
	for {
		nr := hp.bnum
		hp2: ^Bhdr_O = nil
		if nr > mfp.infile_count {
			nr = mfp.infile_count
			hp2 = mf_hash_get_o(mfp, nr)
		} else {
			hp2 = hp
		}
		offset := i64(page_size) * nr
		page_count: u32
		if hp2 == nil {
			page_count = 1
		} else {
			page_count = hp2.page_count
		}
		size := page_size * page_count
		attempt: C.int = 1
		for attempt <= 2 {
			if mfp.fd >= 0 {
				if mf_lseek_o(mfp.fd, offset, .SET) != offset {
					mf_perror_o(cstring(E_SWAP_SEEK_WRITE_S))
					return 0
				}
				data := hp.data
				if hp2 != nil {
					data = hp2.data
				}
				if u32(write_eintr_e(C.int(mfp.fd), data, C.size_t(size))) == size {
					break
				}
			}
			if attempt == 1 {
				if mfp.fd >= 0 {
					linux.close(linux.Fd(mfp.fd))
				}
				mfp.fd = os_open(transmute(cstring)(mfp.fname), mfp.flags, S_IREAD_WRITE_O)
				mfp.reopen = mfp.fd < 0
			}
			if attempt == 2 || mfp.fd < 0 {
				if !did_swapwrite_msg {
					emsg(cstring(E_SWAP_WRITE_S))
				}
				did_swapwrite_msg = true
				return 0
			}
			attempt += 1
		}
		did_swapwrite_msg = false
		if hp2 != nil {
			hp2.flags &= ~u32(BH_DIRTY_O)
		}
		if nr + i64(page_count) > mfp.infile_count {
			mfp.infile_count = nr + i64(page_count)
		}
		if nr == hp.bnum {
			break
		}
	}
	return 1
}

// Make block number positive and add it to the translation list.
mf_trans_add_o :: proc "c" (mfp: ^Memfile_O, hp: ^Bhdr_O) -> C.int {
	context = runtime.default_context()
	if hp.bnum >= 0 {
		return 1
	}
	new_bnum: i64
	freep := (^Bhdr_O)(mfp.free_first)
	page_count := hp.page_count
	if freep != nil && freep.page_count >= page_count {
		new_bnum = freep.bnum
		if freep.page_count > page_count {
			freep.bnum += i64(page_count)
			freep.page_count -= page_count
		} else {
			freep = mf_rem_free_o(mfp)
			xfree(rawptr(freep))
		}
	} else {
		new_bnum = mfp.blocknr_max
		mfp.blocknr_max += i64(page_count)
	}
	old_bnum := hp.bnum
	mf_hash_del_o(mfp, hp.bnum)
	hp.bnum = new_bnum
	mf_hash_put_o(mfp, new_bnum, hp)
	map_put_ref_int64_t_int64_t(&mfp.trans, old_bnum, nil, nil)^ = new_bnum
	return 1
}

// Lookup translation from trans list and delete the entry.
@(export)
mf_trans_del :: proc "c" (mfp: ^Memfile_O, old_nr: i64) -> i64 {
	context = runtime.default_context()
	num := map_ref_int64_t_int64_t(&mfp.trans, old_nr, nil)
	if num == nil {
		return old_nr
	}
	mfp.neg_count -= 1
	new_bnum := num^
	map_del_int64_t_int64_t(&mfp.trans, old_nr, nil)
	return new_bnum
}

// Frees mf_fname and mf_ffname.
@(export)
mf_free_fnames :: proc "c" (mfp: ^Memfile_O) {
	context = runtime.default_context()
	if mfp.fname != nil {
		xfree(rawptr(mfp.fname))
		mfp.fname = nil
	}
	if mfp.ffname != nil {
		xfree(rawptr(mfp.ffname))
		mfp.ffname = nil
	}
}

// Set the simple file name and the full file name of the swapfile.
@(export)
mf_set_fnames :: proc "c" (mfp: ^Memfile_O, fname: cstring) {
	context = runtime.default_context()
	mfp.fname = transmute(^u8)(fname)
	mfp.ffname = transmute(^u8)(FullName_save_r(fname, false))
}

// Make name of memfile's swapfile a full path. Used before doing a :cd.
@(export)
mf_fullname :: proc "c" (mfp: ^Memfile_O) {
	context = runtime.default_context()
	if mfp == nil || mfp.fname == nil || mfp.ffname == nil {
		return
	}
	xfree(rawptr(mfp.fname))
	mfp.fname = mfp.ffname
	mfp.ffname = nil
}

// Return true if there are any translations pending for memfile.
@(export)
mf_need_trans :: proc "c" (mfp: ^Memfile_O) -> bool {
	context = runtime.default_context()
	return mfp.fname != nil && mfp.neg_count > 0
}

// Open memfile's swapfile. "fname" is consumed (also on error).
mf_do_open_o :: proc "c" (mfp: ^Memfile_O, fname: ^u8, flags: C.int) -> bool {
	context = runtime.default_context()
	mf_set_fnames(mfp, transmute(cstring)(fname))
	if mfp.fname == nil {
		libc.abort()
	}
	fi: FileInfo
	if (flags & O_CREAT_O) != 0 && os_fileinfo_link(transmute(cstring)(mfp.fname), &fi) {
		mfp.fd = -1
		emsg(cstring(E_SWAP_SYMLINK_S))
	} else {
		flags := flags | O_NOFOLLOW_O
		mfp.flags = flags
		mfp.fd = os_open(transmute(cstring)(mfp.fname), flags, S_IREAD_WRITE_O)
	}
	if mfp.fd < 0 {
		mf_free_fnames(mfp)
		return false
	}
	os_set_cloexec(mfp.fd)
	return true
}
