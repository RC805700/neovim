package main

import "base:runtime"
import "core:c"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"

ARENA_BLOCK_SIZE :: 4096

// libuv error codes (negated POSIX errno)
UV_EIO     :: -5
UV_EINVAL  :: -22
UV_EROFS   :: -30
UV_ENOTSUP :: -95

// FileDescriptor struct — mirrors C layout (src/nvim/os/fileio_defs.h)
// Must match C's: int fd; char *buffer; char *read_pos; char *write_pos;
// bool wr; bool eof; bool non_blocking; uint64_t bytes_read;
FileDescriptor :: struct #align(8) {
	fd:           c.int,
	buffer:       rawptr,
	read_pos:     rawptr,
	write_pos:    rawptr,
	wr:           bool,
	eof:          bool,
	non_blocking: bool,
	bytes_read:   u64,
}

// Inlined os_file_mkdir — create parent directories for a file path
_file_mkdir :: proc(fname: cstring, mode: c.int) -> c.int {
	path := string(fname)
	parent_dir := filepath.dir(path)
	err := os.make_directory_all(parent_dir, os.Permissions_Default_Directory)
	if err != nil {
		switch e in err {
		case os.General_Error:
			if e == .Exist {
				return 0
			}
		case os.Platform_Error:
			return uv_translate_sys_error(c.int(e))
		case io.Error, runtime.Allocator_Error:
			return -1
		}
		return -1
	}
	return 0
}

// ─────────────────────────────────────────────────────────────────
//  Exported C functions — override C symbols via weak linking
// ─────────────────────────────────────────────────────────────────

@(export)
file_open :: proc "c" (ret_fp: ^FileDescriptor, fname: cstring, flags: c.int, mode: c.int) -> c.int {
	context = runtime.default_context()
	os_open_flags: c.int = 0
	wr := 0  // kNone

	if flags & 2 != 0 { // kFileCreate
		os_open_flags |= posix.O_CREAT | posix.O_WRONLY
		wr = 1  // kTrue
	}
	if flags & 16 != 0 { // kFileCreateOnly
		os_open_flags |= posix.O_CREAT | posix.O_EXCL | posix.O_WRONLY
		wr = 1
	}
	if flags & 32 != 0 { // kFileTruncate
		os_open_flags |= posix.O_TRUNC | posix.O_WRONLY
		wr = 1
	}
	if flags & 64 != 0 { // kFileAppend
		os_open_flags |= posix.O_APPEND | posix.O_WRONLY
		wr = 1
	}
	if flags & 4 != 0 { // kFileWriteOnly
		os_open_flags |= posix.O_WRONLY
		wr = 1
	}
	if flags & 1 != 0 && wr != 1 { // kFileReadOnly, but only if not already write
		os_open_flags |= posix.O_RDONLY
	}
	if flags & 8 != 0 { // kFileNoSymlink
		os_open_flags |= posix.O_NOFOLLOW
	}
	if flags & 256 != 0 { // kFileMkDir
		os_open_flags |= posix.O_CREAT | posix.O_WRONLY
		mkdir_ret := _file_mkdir(fname, mode)
		if mkdir_ret < 0 {
			return mkdir_ret
		}
	}

	fd := os_open(fname, os_open_flags, mode)
	if fd < 0 {
		return fd
	}
	return file_open_fd(ret_fp, fd, flags)
}

@(export)
file_open_fd :: proc "c" (ret_fp: ^FileDescriptor, fd: c.int, flags: c.int) -> c.int {
	context = runtime.default_context()
	ret_fp.wr = flags & (2 | 16 | 32 | 64 | 4) != 0
	ret_fp.non_blocking = flags & 128 != 0
	ret_fp.fd = fd
	ret_fp.eof = false
	buf := make([]u8, ARENA_BLOCK_SIZE)
	ret_fp.buffer = rawptr(raw_data(buf))
	ret_fp.read_pos = ret_fp.buffer
	ret_fp.write_pos = ret_fp.buffer
	ret_fp.bytes_read = 0
	return 0
}

@(export)
file_open_stdin :: proc "c" (fp: ^FileDescriptor) -> c.int {
	context = runtime.default_context()
	error := file_open_fd(fp, os_open_stdin_fd(), 1 | 128) // kFileReadOnly | kFileNonBlocking
	if error != 0 {
		return error
	}
	return 0
}

@(export)
file_open_buffer :: proc "c" (ret_fp: ^FileDescriptor, data: cstring, len: c.size_t) {
	context = runtime.default_context()
	ret_fp.wr = false
	ret_fp.non_blocking = false
	ret_fp.fd = -1
	ret_fp.eof = true
	ret_fp.buffer = nil
	ret_fp.read_pos = rawptr(data)
	ret_fp.write_pos = rawptr(transmute(uintptr)data + uintptr(len))
	ret_fp.bytes_read = 0
}

@(export)
file_close :: proc "c" (fp: ^FileDescriptor, do_fsync: bool) -> c.int {
	context = runtime.default_context()
	if fp.fd < 0 {
		return 0
	}
	flush_error: c.int
	if do_fsync {
		flush_error = file_fsync(fp)
	} else {
		flush_error = file_flush(fp)
	}
	close_error := os_close(fp.fd)
	xfree(fp.buffer)
	if close_error != 0 {
		return close_error
	}
	return flush_error
}

@(export)
file_fsync :: proc "c" (fp: ^FileDescriptor) -> c.int {
	context = runtime.default_context()
	if !fp.wr {
		return 0
	}
	flush_error := file_flush(fp)
	if flush_error != 0 {
		return flush_error
	}
	fsync_error := os_fsync(fp.fd)
	if fsync_error != UV_EINVAL && fsync_error != UV_EROFS && fsync_error != UV_ENOTSUP {
		return fsync_error
	}
	return 0
}

@(export)
file_flush :: proc "c" (fp: ^FileDescriptor) -> c.int {
	context = runtime.default_context()
	if !fp.wr {
		return 0
	}
	to_write := uintptr(fp.write_pos) - uintptr(fp.read_pos)
	if to_write == 0 {
		return 0
	}
	wres := os_write(fp.fd, transmute([^]u8)fp.read_pos, c.size_t(to_write), fp.non_blocking)
	fp.read_pos = fp.buffer
	fp.write_pos = fp.buffer
	if wres < 0 || c.ptrdiff_t(to_write) != wres {
		if wres >= 0 {
			return UV_EIO
		}
		return c.int(wres)
	}
	return 0
}

@(export)
file_read :: proc "c" (fp: ^FileDescriptor, ret_buf: cstring, size: c.size_t) -> c.ptrdiff_t {
	context = runtime.default_context()
	buffered := uintptr(fp.write_pos) - uintptr(fp.read_pos)
	from_buffer := _min(buffered, uintptr(size))

	_cpy(rawptr(ret_buf), fp.read_pos, from_buffer)

	buf := rawptr(transmute(uintptr)ret_buf + from_buffer)
	read_remaining := uintptr(size) - from_buffer
	if read_remaining == 0 {
		fp.bytes_read += u64(from_buffer)
		fp.read_pos = rawptr(uintptr(fp.read_pos) + from_buffer)
		return c.ptrdiff_t(from_buffer)
	}

	// consumed all buffered data; restart buffer
	fp.read_pos = fp.buffer
	fp.write_pos = fp.buffer

	// readv path
	called_read := false
	for read_remaining > 0 {
		if fp.eof || (called_read && fp.non_blocking) {
			break
		}
		iov: [2]posix.iovec
		iov[0] = posix.iovec{buf, c.size_t(read_remaining)}
		iov[1] = posix.iovec{fp.write_pos, c.size_t(ARENA_BLOCK_SIZE)}
		r_ret := os_readv(fp.fd, &fp.eof, &iov[0], 2, fp.non_blocking)
		if r_ret > 0 {
			ur_ret := uintptr(r_ret)
			if ur_ret > read_remaining {
				fp.write_pos = rawptr(uintptr(fp.write_pos) + (ur_ret - read_remaining))
				read_remaining = 0
			} else {
				buf = rawptr(uintptr(buf) + ur_ret)
				read_remaining -= ur_ret
			}
		} else if r_ret < 0 {
			return r_ret
		}
		called_read = true
	}

	fp.bytes_read += u64(uintptr(size) - read_remaining)
	return c.ptrdiff_t(uintptr(size) - read_remaining)
}

@(export)
file_try_read_buffered :: proc "c" (fp: ^FileDescriptor, size: c.size_t) -> cstring {
	context = runtime.default_context()
	buffered := uintptr(fp.write_pos) - uintptr(fp.read_pos)
	if buffered >= uintptr(size) {
		ret := fp.read_pos
		fp.read_pos = rawptr(uintptr(fp.read_pos) + uintptr(size))
		fp.bytes_read += u64(uintptr(size))
		return cstring(ret)
	}
	return nil
}

@(export)
file_write :: proc "c" (fp: ^FileDescriptor, buf: cstring, size: c.size_t) -> c.ptrdiff_t {
	context = runtime.default_context()
	if size < file_space(fp) {
		_cpy(fp.write_pos, rawptr(buf), uintptr(size))
		fp.write_pos = rawptr(uintptr(fp.write_pos) + uintptr(size))
		return c.ptrdiff_t(size)
	}
	status := file_flush(fp)
	if status < 0 {
		return c.ptrdiff_t(status)
	}
	if size < ARENA_BLOCK_SIZE {
		_cpy(fp.write_pos, rawptr(buf), uintptr(size))
		fp.write_pos = rawptr(uintptr(fp.write_pos) + uintptr(size))
		return c.ptrdiff_t(size)
	}
	wres := os_write(fp.fd, transmute([^]u8)buf, size, fp.non_blocking)
	if wres != c.ptrdiff_t(size) && wres >= 0 {
		return UV_EIO
	}
	return wres
}

@(export)
file_skip :: proc "c" (fp: ^FileDescriptor, size: c.size_t) -> c.ptrdiff_t {
	context = runtime.default_context()
	buffered := uintptr(fp.write_pos) - uintptr(fp.read_pos)
	from_buffer := _min(buffered, uintptr(size))
	skip_remaining := uintptr(size) - from_buffer
	if skip_remaining == 0 {
		fp.read_pos = rawptr(uintptr(fp.read_pos) + from_buffer)
		fp.bytes_read += u64(from_buffer)
		return c.ptrdiff_t(from_buffer)
	}
	fp.read_pos = fp.buffer
	fp.write_pos = fp.buffer
	called_read := false
	for skip_remaining > 0 {
		if fp.eof || (called_read && fp.non_blocking) {
			break
		}
		r_ret := os_read(fp.fd, &fp.eof, transmute([^]u8)fp.buffer, ARENA_BLOCK_SIZE, fp.non_blocking)
		if r_ret < 0 {
			return r_ret
		} else if uintptr(r_ret) > skip_remaining {
			fp.read_pos = rawptr(uintptr(fp.buffer) + skip_remaining)
			fp.write_pos = rawptr(uintptr(fp.buffer) + uintptr(r_ret))
			fp.bytes_read += u64(uintptr(size))
			return c.ptrdiff_t(size)
		}
		skip_remaining -= uintptr(r_ret)
		called_read = true
	}
	fp.bytes_read += u64(uintptr(size) - skip_remaining)
	return c.ptrdiff_t(uintptr(size) - skip_remaining)
}

//  Internal helpers

file_space :: proc(fp: ^FileDescriptor) -> c.size_t {
	return c.size_t(uintptr(fp.buffer) + ARENA_BLOCK_SIZE - uintptr(fp.write_pos))
}

_cpy :: proc(dst, src: rawptr, n: uintptr) {
	for i: uintptr = 0; i < n; i += 1 {
		(cast([^]u8)dst)[i] = (cast([^]u8)src)[i]
	}
}

_min :: proc(a, b: uintptr) -> uintptr {
	return a if a < b else b
}