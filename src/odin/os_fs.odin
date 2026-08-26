package main

import "core:c"
import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"
import "core:sys/linux"

// uv_translate_sys_error: convert POSIX errno → negative libuv error code
foreign _ {
	@(link_name = "uv_translate_sys_error")
	uv_translate_sys_error :: proc "c" (err: c.int) -> c.int ---
}

// Direct libc wrappers using raw linux syscalls (no name conflicts with posix package)
_c_open :: proc(path: cstring, flags: c.int, mode: c.int) -> c.int {
	// Build bit_sets from the raw int values. Open_Flags_Bits/Mode_Bits
	// ordinals are identity-mapped to their octal bit values (verified in
	// Odin core bits.odin), so set each bit whose value is present.
	ofl := linux.Open_Flags{}
	for i := 0; i < 32; i += 1 {
		if flags & (1 << u32(i)) != 0 {
			ofl |= linux.Open_Flags{transmute(linux.Open_Flags_Bits)u64(i)}
		}
	}
	mfl := linux.Mode{}
	for i := 0; i < 12; i += 1 {
		if mode & (1 << u32(i)) != 0 {
			mfl |= linux.Mode{transmute(linux.Mode_Bits)u64(i)}
		}
	}
	fd, err := linux.open(path, ofl, mfl)
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return c.int(fd)
}

_c_close :: proc(fd: c.int) -> c.int {
	err := linux.close(linux.Fd(fd))
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return 0
}

_c_read :: proc(fd: c.int, buf: [^]u8, count: c.size_t) -> c.ssize_t {
	n, err := linux.read(linux.Fd(fd), buf[:count])
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return c.ssize_t(n)
}

_c_write :: proc(fd: c.int, buf: [^]u8, count: c.size_t) -> c.ssize_t {
	n, err := linux.write(linux.Fd(fd), buf[:count])
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return c.ssize_t(n)
}

_c_fsync :: proc(fd: c.int) -> c.int {
	err := linux.fsync(linux.Fd(fd))
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return 0
}

_c_dup :: proc(fd: c.int) -> c.int {
	nfd, err := linux.dup(linux.Fd(fd))
	if err != .NONE {
		posix.set_errno(posix.Errno(err))
		return -1
	}
	return c.int(nfd)
}

// iovec for readv (same layout as C's struct iovec)
PosixIovec :: posix.iovec

// ─────────────────────────────────────────────────────────────────
//  Phase B types, constants, and additional FFI
// ─────────────────────────────────────────────────────────────────

// UVTimespec mirrors C's `uv_timespec_t` exactly (uv.h:360):
//   int64_t tv_sec; int32_t tv_nsec; (4 bytes padding to 16-byte stride)
UVTimespec :: struct #align(8) {
	tv_sec:  i64,
	tv_nsec: i32,
	_:       i32,
}

// UVStat mirrors C's `uv_stat_t` exactly (uv.h:382) — all uint64_t fields
// plus 4 uv_timespec_t members. This is the layout of C's `FileInfo.stat`,
// NOT a raw `struct stat`. Using this fixes a latent ABI mismatch where the
// old `CStat` (raw struct stat mirror) wrote fields at the wrong offsets.
UVStat :: struct #align(8) {
	st_dev:      u64,
	st_mode:     u64,
	st_nlink:    u64,
	st_uid:      u64,
	st_gid:      u64,
	st_rdev:     u64,
	st_ino:      u64,
	st_size:     u64,
	st_blksize:  u64,
	st_blocks:   u64,
	st_flags:    u64,
	st_gen:      u64,
	st_atim:     UVTimespec,
	st_mtim:     UVTimespec,
	st_ctim:     UVTimespec,
	st_birthtim: UVTimespec,
}

// FileInfo mirrors C's struct (uv_stat_t + path decomposition fields)
FileInfo :: struct {
	stat:       UVStat,
	prefix_off: c.size_t,
	root_off:   c.size_t,
	rest_off:   c.size_t,
	_type:      c.int,
}

// FileID mirrors C's struct
FileID :: struct {
	inode:     u64,
	device_id: u64,
}

// NvimString mirrors C's String (used by ui_call_chdir)
NvimString :: struct {
	data: cstring,
	size: c.size_t,
}

// File type bitmasks (same as Linux S_IFMT / S_IFREG / S_IFDIR etc.)
S_IFMT  :: u64(0xF000)
S_IFREG :: u64(0x8000)
S_IFDIR :: u64(0x4000)
S_IFBLK :: u64(0x6000)

// PathType mirrors enum in os/fs_defs.h (used by os_fileinfo2)
kPathUnknown   :: c.int(0)
kPathGeneric   :: c.int(1)
kPathDrive     :: c.int(2)
kPathUNC       :: c.int(3)
kPathDevice    :: c.int(4)
kPathDeviceUNC :: c.int(5)

// Return constants matching C
OK   :: 1
FAIL :: 0
NODE_NORMAL   :: 0
NODE_WRITABLE :: 1
NODE_OTHER    :: 2

// Additional FFI declarations — C standard library
foreign import clib "system:c"

foreign clib {
	@(link_name="fdopen")
	_c_fdopen :: proc(fd: c.int, mode: cstring) -> rawptr ---
	@(link_name="listxattr")
	_c_listxattr :: proc(path: cstring, list: rawptr, size: c.size_t) -> c.ssize_t ---
	@(link_name="getxattr")
	_c_getxattr :: proc(path: cstring, key: cstring, value: rawptr, size: c.size_t) -> c.ssize_t ---
	@(link_name="setxattr")
	_c_setxattr :: proc(path: cstring, key: cstring, value: rawptr, size: c.size_t, flags: c.int) -> c.int ---
}

foreign _ {
	@(link_name = "emsg")
	emsg :: proc "c" (msg: cstring) ---
}

// ─────────────────────────────────────────────────────────────────
//  Stat helpers — use core:sys/linux (raw syscalls) and map into the
//  UVStat layout that C's FileInfo.stat expects.
// ─────────────────────────────────────────────────────────────────

linux_stat_to_uvstat :: proc "contextless" (s: linux.Stat) -> UVStat {
	return UVStat{
		st_dev      = u64(s.dev),
		st_mode     = u64(transmute(u32)s.mode),
		st_nlink    = u64(s.nlink),
		st_uid      = u64(s.uid),
		st_gid      = u64(s.gid),
		st_rdev     = u64(s.rdev),
		st_ino      = u64(s.ino),
		st_size     = u64(s.size),
		st_blksize  = u64(s.blksize),
		st_blocks   = u64(s.blocks),
		st_atim     = UVTimespec{tv_sec = i64(s.atime.time_sec),  tv_nsec = i32(s.atime.time_nsec)},
		st_mtim     = UVTimespec{tv_sec = i64(s.mtime.time_sec),  tv_nsec = i32(s.mtime.time_nsec)},
		st_ctim     = UVTimespec{tv_sec = i64(s.ctime.time_sec),  tv_nsec = i32(s.ctime.time_nsec)},
		st_birthtim = UVTimespec{},
	}
}

_do_stat :: proc(path: cstring) -> (UVStat, bool) {
	s: linux.Stat
	if linux.stat(path, &s) != .NONE {
		return {}, false
	}
	return linux_stat_to_uvstat(s), true
}

_do_lstat :: proc(path: cstring) -> (UVStat, bool) {
	s: linux.Stat
	if linux.lstat(path, &s) != .NONE {
		return {}, false
	}
	return linux_stat_to_uvstat(s), true
}

_do_fstat :: proc(fd: c.int) -> (UVStat, bool) {
	s: linux.Stat
	if linux.fstat(linux.Fd(fd), &s) != .NONE {
		return {}, false
	}
	return linux_stat_to_uvstat(s), true
}

// C functions from Neovim
foreign _ {
	@(link_name = "ui_call_chdir")
	ui_call_chdir :: proc "c" (path: NvimString) ---

	@(link_name = "save_abs_path")
	save_abs_path :: proc "c" (name: cstring) -> cstring ---
}

// ─────────────────────────────────────────────────────────────────
//  Exported C functions — override the C symbols via weak linking
// ─────────────────────────────────────────────────────────────────

@(export)
os_open :: proc "c" (path: cstring, flags: c.int, mode: c.int) -> c.int {
	context = runtime.default_context()
	if path == nil {
		return -1 // UV_EINVAL (same as C: uv_fs_open asserts on NULL)
	}
	fd := _c_open(path, flags, mode)
	if fd < 0 {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return fd
}

@(export)
os_close :: proc "c" (fd: c.int) -> c.int {
	context = runtime.default_context()
	if _c_close(fd) < 0 {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_read :: proc "c" (fd: c.int, ret_eof: ^bool, ret_buf: [^]u8, size: c.size_t, non_blocking: bool) -> c.ptrdiff_t {
	context = runtime.default_context()
	ret_eof^ = false
	if ret_buf == nil {
		return 0
	}
	read_bytes: c.size_t = 0
	for read_bytes < size {
		bp := ([^]u8)(uintptr(ret_buf) + uintptr(read_bytes))
		n := _c_read(fd, bp, size - read_bytes)
		if n > 0 {
			read_bytes += c.size_t(n)
		}
		if n < 0 {
			err := posix.errno()
			if non_blocking && err == .EAGAIN { break }
			if err == .EINTR || err == .EAGAIN { continue }
			return c.ptrdiff_t(uv_translate_sys_error(c.int(err)))
		}
		if n == 0 {
			ret_eof^ = true
			break
		}
	}
	return c.ptrdiff_t(read_bytes)
}

@(export)
os_write :: proc "c" (fd: c.int, buf: [^]u8, size: c.size_t, non_blocking: bool) -> c.ptrdiff_t {
	context = runtime.default_context()
	if buf == nil {
		return 0
	}
	written_bytes: c.size_t = 0
	for written_bytes < size {
		bp := ([^]u8)(uintptr(buf) + uintptr(written_bytes))
		n := _c_write(fd, bp, size - written_bytes)
		if n > 0 {
			written_bytes += c.size_t(n)
		}
		if n < 0 {
			err := posix.errno()
			if non_blocking && err == .EAGAIN { break }
			if err == .EINTR || err == .EAGAIN { continue }
			return c.ptrdiff_t(uv_translate_sys_error(c.int(err)))
		}
		if n == 0 {
			return -1 // UV_UNKNOWN
		}
	}
	return c.ptrdiff_t(written_bytes)
}

@(export)
os_readv :: proc "c" (fd: c.int, ret_eof: ^bool, iov: [^]PosixIovec, iov_size: c.size_t, non_blocking: bool) -> c.ptrdiff_t {
	context = runtime.default_context()
	ret_eof^ = false
	read_bytes: c.size_t = 0
	toread: c.size_t = 0
	for i in 0 ..< iov_size {
		toread += iov[i].iov_len
	}
	cur_iov := iov
	cur_iov_size := iov_size
	for read_bytes < toread && cur_iov_size > 0 && !ret_eof^ {
		n := posix.readv(posix.FD(fd), cur_iov, c.int(cur_iov_size))
		if n == 0 {
			ret_eof^ = true
		}
		if n > 0 {
			read_bytes += c.size_t(n)
			remaining := c.size_t(n)
			for cur_iov_size > 0 && remaining > 0 {
				if remaining < cur_iov[0].iov_len {
					cur_iov[0].iov_len -= remaining
					cur_iov[0].iov_base = rawptr(uintptr(cur_iov[0].iov_base) + uintptr(remaining))
					remaining = 0
				} else {
					remaining -= cur_iov[0].iov_len
					cur_iov_size -= 1
					cur_iov = cur_iov[1:]
				}
			}
		} else if n < 0 {
			err := posix.errno()
			if non_blocking && err == .EAGAIN { break }
			if err == .EINTR || err == .EAGAIN { continue }
			return c.ptrdiff_t(uv_translate_sys_error(c.int(err)))
		}
	}
	return c.ptrdiff_t(read_bytes)
}

@(export)
os_fsync :: proc "c" (fd: c.int) -> c.int {
	context = runtime.default_context()
	if _c_fsync(fd) < 0 {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_open_stdin_fd :: proc "c" () -> c.int {
	context = runtime.default_context()
	fd := _c_dup(0)
	if fd < 0 {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return fd
}

// ─────────────────────────────────────────────────────────────────
//  Phase B — Exported C functions
// ─────────────────────────────────────────────────────────────────

// Package-level side-table for os_scandir (Directory* → DIR*)
dir_handle_map: map[uintptr]rawptr

// ──────────────────────────
//  B1: Simple wrappers
// ──────────────────────────

@(export)
os_chdir :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	if posix.chdir(path) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	ui_call_chdir(NvimString{path, c.size_t(len(string(path)))})
	return 0
}

@(export)
os_dirname :: proc "c" (buf: cstring, len: c.size_t) -> c.int {
	context = runtime.default_context()
	result := posix.getcwd(([^]byte)(buf), len)
	if result == nil {
		return FAIL
	}
	return OK
}

@(export)
os_mkdir :: proc "c" (path: cstring, mode: c.int32_t) -> c.int {
	context = runtime.default_context()
	if posix.mkdir(path, transmute(posix.mode_t)u32(mode)) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_mkdir_recurse :: proc "c" (dir: cstring, mode: c.int32_t, failed_dir: ^cstring, created: ^cstring) -> c.int {
	context = runtime.default_context()
	// Mirror C's os_mkdir_recurse: walk components, skip ones that are
	// already directories, and only call os_mkdir on missing ones.
	// (Avoids opening existing directories, which fails with EPERM in some
	// sandboxes, unlike C's uv_fs_mkdir which only stats.)
	dir_str := string(dir)
	if len(dir_str) == 0 {
		return -1
	}
	created_set := false
	buf := make([]byte, len(dir_str) + 1)
	defer delete(buf)
	copy(buf, dir_str)
	buf[len(dir_str)] = 0

	// Skip leading separators; absolute paths start walking from root.
	i := 0
	for i < len(buf) && buf[i] == '/' {
		i += 1
	}
	if i == 0 {
		i = 1
	}
	for i < len(buf) {
		j := i
		for j < len(buf) && buf[j] != '/' {
			j += 1
		}
		if j < len(buf) {
			buf[j] = 0
		}
		if !os_isdir(cstring(&buf[i])) {
			ret := os_mkdir(cstring(&buf[i]), mode)
			if ret != 0 {
				if failed_dir != nil {
					failed_dir^ = strings.clone_to_cstring(string(dir))
				}
				if j < len(buf) {
					buf[j] = '/'
				}
				return ret
			}
			if !created_set && created != nil {
				created^ = strings.clone_to_cstring(string(dir))
				created_set = true
			}
		}
		if j >= len(buf) {
			break
		}
		buf[j] = '/'
		i = j + 1
	}
	if !created_set && created != nil {
		created^ = strings.clone_to_cstring(string(dir))
	}
	return 0
}

@(export)
os_mkdtemp :: proc "c" (templ: cstring, path: cstring) -> c.int {
	context = runtime.default_context()
	templ_len := c.size_t(len(string(templ)))
	buf := make([]u8, templ_len + 1)
	defer delete(buf)
	for i: c.size_t = 0; i <= templ_len; i += 1 {
		buf[i] = ([^]u8)(templ)[i]
	}
	result := posix.mkdtemp(raw_data(buf))
	if result == nil {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	for i: c.size_t = 0; i <= templ_len; i += 1 {
		([^]u8)(path)[i] = buf[i]
		if buf[i] == 0 { break }
	}
	return 0
}

@(export)
os_rmdir :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	if posix.rmdir(path) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_remove :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	if posix.unlink(path) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_rename :: proc "c" (path: cstring, new_path: cstring) -> c.int {
	context = runtime.default_context()
	if posix.rename(path, new_path) == -1 {
		return FAIL
	}
	return OK
}

@(export)
os_copy :: proc "c" (path: cstring, new_path: cstring, flags: c.int) -> c.int {
	context = runtime.default_context()
	// os.copy_file takes (dst, src) — note argument order
	err := os.copy_file(string(new_path), string(path))
	if err != nil {
		switch e in err {
		case os.Platform_Error:
			return uv_translate_sys_error(c.int(e))
		case os.General_Error, io.Error, runtime.Allocator_Error:
			return -1
		}
	}
	return 0
}

@(export)
os_setperm :: proc "c" (name: cstring, perm: c.int) -> c.int {
	context = runtime.default_context()
	if posix.chmod(name, transmute(posix.mode_t)u32(perm)) == .FAIL {
		return FAIL
	}
	return OK
}

@(export)
os_chown :: proc "c" (path: cstring, owner: c.int, group: c.int) -> c.int {
	context = runtime.default_context()
	if posix.chown(path, posix.uid_t(owner), posix.gid_t(group)) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_fchown :: proc "c" (fd: c.int, owner: c.int, group: c.int) -> c.int {
	context = runtime.default_context()
	if posix.fchown(posix.FD(fd), posix.uid_t(owner), posix.gid_t(group)) == .FAIL {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	return 0
}

@(export)
os_file_settime :: proc "c" (path: cstring, atime: c.double, mtime: c.double) -> c.int {
	context = runtime.default_context()
	ts: [2]linux.Time_Spec
	ts[0].time_sec  = uint(atime)
	ts[0].time_nsec = uint((atime - c.double(c.long(atime))) * 1_000_000_000.0)
	ts[1].time_sec  = uint(mtime)
	ts[1].time_nsec = uint((mtime - c.double(c.long(mtime))) * 1_000_000_000.0)
	err := linux.utimensat(linux.AT_FDCWD, path, &ts[0], {})
	if err != .NONE {
		return uv_translate_sys_error(c.int(posix.Errno(err)))
	}
	return 0
}

@(export)
os_dup :: proc "c" (fd: c.int) -> c.int {
	context = runtime.default_context()
	for {
		nfd, err := linux.dup(linux.Fd(fd))
		if err != .NONE {
			posix.set_errno(posix.Errno(err))
			if err == .EINTR { continue }
			return uv_translate_sys_error(c.int(posix.errno()))
		}
		return c.int(nfd)
	}
}

@(export)
os_dup_cloexec :: proc "c" (fd: c.int) -> c.int {
	context = runtime.default_context()
	newfd := os_dup(fd)
	if newfd >= 0 {
		os_set_cloexec(newfd)
	}
	return newfd
}

@(export)
os_set_cloexec :: proc "c" (fd: c.int) -> c.int {
	context = runtime.default_context()
	flags := posix.fcntl(posix.FD(fd), .GETFD)
	if flags < 0 {
		return -1
	}
	if flags & posix.FD_CLOEXEC == 0 {
		if posix.fcntl(posix.FD(fd), .SETFD, flags | posix.FD_CLOEXEC) < 0 {
			return -1
		}
	}
	return 0
}

@(export)
os_file_mkdir :: proc "c" (fname: cstring, mode: c.int32_t) -> c.int {
	context = runtime.default_context()
	fname_str := string(fname)
	parent := filepath.dir(fname_str)
	if !os.is_directory(parent) {
		err := os.make_directory_all(parent)
		if err != nil {
		switch e in err {
		case os.Platform_Error:
			return uv_translate_sys_error(c.int(e))
		case os.General_Error, io.Error, runtime.Allocator_Error:
			return -1
		}
		}
	}
	return 0
}

@(export)
os_file_is_readable :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	return linux.access(name, linux.R_OK) == .NONE
}

@(export)
os_file_is_writable :: proc "c" (name: cstring) -> c.int {
	context = runtime.default_context()
	if linux.access(name, linux.W_OK) != .NONE {
		return 0
	}
	if os.is_directory(string(name)) {
		return 2
	}
	return 1
}

@(export)
os_fopen :: proc "c" (path: cstring, flags: cstring) -> rawptr {
	context = runtime.default_context()
	iflags: c.int = 0
	f := ([^]byte)(flags)
	f0 := rune(f[0])
	f1 := rune(f[1])
	has_b := (f1 == 'b') || (f1 != 0 && rune(f[2]) == 'b')
	mode_char := f1
	if has_b { mode_char = 0 }
	switch f0 {
	case 'r':
		iflags = posix.O_RDONLY
		if mode_char == '+' { iflags = posix.O_RDWR }
	case 'w':
		iflags = posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC
		if mode_char == '+' { iflags = posix.O_RDWR | posix.O_CREAT | posix.O_TRUNC }
	case 'a':
		iflags = posix.O_WRONLY | posix.O_CREAT | posix.O_APPEND
		if mode_char == '+' { iflags = posix.O_RDWR | posix.O_CREAT | posix.O_APPEND }
	case:
		return nil
	}
	fd := os_open(path, iflags, 0o666)
	if fd < 0 {
		return nil
	}
	return _c_fdopen(fd, flags)
}

// ──────────────────────────
//  B2: Stat-based functions
// ──────────────────────────

@(export)
os_getperm :: proc "c" (name: cstring) -> c.int32_t {
	context = runtime.default_context()
	// NOTE: use the raw-syscall errno (returned value), NOT posix.errno() —
	// raw syscalls don't set C errno, so posix.errno() returns stale values.
	st, ok := _do_stat(name)
	if !ok {
		return uv_translate_sys_error(c.int(linux.Errno.ENOENT))
	}
	return c.int32_t(st.st_mode)
}

@(export)
os_path_exists :: proc "c" (path: cstring) -> bool {
	context = runtime.default_context()
	_, ok := _do_stat(path)
	return ok
}

@(export)
os_isdir :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	st, ok := _do_stat(name)
	if !ok {
		return false
	}
	return (st.st_mode & S_IFMT) == S_IFDIR
}

@(export)
os_isrealdir :: proc "c" (name: cstring) -> bool {
	context = runtime.default_context()
	st, ok := _do_lstat(name)
	if !ok {
		return false
	}
	if (st.st_mode & S_IFMT) == S_IFDIR {
		// It's a directory. Check it's not a symlink by stat-ing the symlink itself.
		// lstat returns info about the link, not the target. If the path is a symlink,
		// lstat won't return S_IFDIR. So this check is sufficient.
		return true
	}
	return false
}

@(export)
os_nodetype :: proc "c" (name: cstring) -> c.int {
	context = runtime.default_context()
	st, ok := _do_stat(name)
	if !ok {
		return NODE_NORMAL
	}
	mode := st.st_mode & S_IFMT
	if mode == S_IFREG || mode == S_IFDIR {
		return NODE_NORMAL
	}
	if mode == S_IFBLK {
		return NODE_OTHER
	}
	return NODE_WRITABLE
}

@(export)
os_fileinfo :: proc "c" (path: cstring, file_info: ^FileInfo) -> bool {
	context = runtime.default_context()
	if file_info == nil { return false }
	file_info^ = {}
	st, ok := _do_stat(path)
	if !ok {
		return false
	}
	file_info.stat = st
	return true
}

@(export)
os_fileinfo_link :: proc "c" (path: cstring, file_info: ^FileInfo) -> bool {
	context = runtime.default_context()
	if file_info == nil { return false }
	if path == nil { return false }
	file_info^ = {}
	st, ok := _do_lstat(path)
	if !ok {
		return false
	}
	file_info.stat = st
	return true
}

@(export)
os_fileinfo_fd :: proc "c" (fd: c.int, file_info: ^FileInfo) -> bool {
	context = runtime.default_context()
	if file_info == nil { return false }
	file_info^ = {}
	st, ok := _do_fstat(fd)
	if !ok {
		return false
	}
	file_info.stat = st
	return true
}

@(export)
os_fileinfo_id_equal :: proc "c" (a: ^FileInfo, b: ^FileInfo) -> bool {
	context = runtime.default_context()
	return a.stat.st_ino == b.stat.st_ino && a.stat.st_dev == b.stat.st_dev
}

@(export)
os_fileinfo_id :: proc "c" (file_info: ^FileInfo, file_id: ^FileID) {
	context = runtime.default_context()
	file_id.inode = file_info.stat.st_ino
	file_id.device_id = file_info.stat.st_dev
}

@(export)
os_fileinfo_inode :: proc "c" (file_info: ^FileInfo) -> u64 {
	context = runtime.default_context()
	return file_info.stat.st_ino
}

@(export)
os_fileinfo_size :: proc "c" (file_info: ^FileInfo) -> u64 {
	context = runtime.default_context()
	return u64(file_info.stat.st_size)
}

@(export)
os_fileinfo_hardlinks :: proc "c" (file_info: ^FileInfo) -> u64 {
	context = runtime.default_context()
	return file_info.stat.st_nlink
}

@(export)
os_fileinfo_blocksize :: proc "c" (file_info: ^FileInfo) -> u64 {
	context = runtime.default_context()
	return u64(file_info.stat.st_blksize)
}

@(export)
os_fileid :: proc "c" (path: cstring, file_id: ^FileID) -> bool {
	context = runtime.default_context()
	st, ok := _do_stat(path)
	if !ok {
		return false
	}
	file_id.inode = st.st_ino
	file_id.device_id = st.st_dev
	return true
}

@(export)
os_fileid_equal :: proc "c" (a: ^FileID, b: ^FileID) -> bool {
	context = runtime.default_context()
	return a.inode == b.inode && a.device_id == b.device_id
}

@(export)
os_file_owned :: proc "c" (fname: cstring) -> bool {
	context = runtime.default_context()
	uid := posix.getuid()
	st, ok := _do_stat(fname)
	fstat_ok := ok && st.st_uid == u64(uid)
	lst, lok := _do_lstat(fname)
	lstat_ok := lok && lst.st_uid == u64(uid)
	return fstat_ok && lstat_ok
}

// ──────────────────────────
//  ACL stubs (HAVE_ACL not defined on this platform — no-op / NULL)
// ──────────────────────────

@(export)
os_get_acl :: proc "c" (fname: cstring) -> rawptr {
	context = runtime.default_context()
	return nil
}

@(export)
os_set_acl :: proc "c" (fname: cstring, aclent: rawptr) {
	context = runtime.default_context()
	// no-op
}

@(export)
os_free_acl :: proc "c" (aclent: rawptr) {
	context = runtime.default_context()
	// no-op
}

// ──────────────────────────
//  os_fileinfo2 — path decomposition only (no stat on UNIX)
// ──────────────────────────

@(export)
os_fileinfo2 :: proc "c" (path: cstring, info: ^FileInfo) -> bool {
	context = runtime.default_context()
	if info == nil || path == nil {
		return false
	}
	info^ = {}
	// Count leading path separators (path_skip_sep on UNIX).
	leading_slashes: c.size_t = 0
	p := ([^]byte)(path)
	for p[leading_slashes] == '/' {
		leading_slashes += 1
	}
	info._type = kPathGeneric
	info.rest_off = leading_slashes
	if leading_slashes > 2 {
		info.root_off = leading_slashes - 1
	} else {
		info.root_off = 0
	}
	info.prefix_off = info.root_off
	return true
}

// ──────────────────────────
//  os_copy_xattr — copy extended attributes (HAVE_XATTR)
// ──────────────────────────

@(export)
os_copy_xattr :: proc "c" (from_file: cstring, to_file: cstring) {
	context = runtime.default_context()
	if from_file == nil {
		return
	}
	size := _c_listxattr(from_file, nil, 0)
	if size <= 0 {
		return
	}
	xattr_buf := xmalloc(c.size_t(size))
	defer xfree(xattr_buf)
	size = _c_listxattr(from_file, xattr_buf, c.size_t(size))
	if size <= 0 {
		return
	}
	max_vallen: c.ssize_t = 0
	val: rawptr = nil
	defer if val != nil { xfree(val) }

	round := 0
	for round < 2 {
		key := rawptr(xattr_buf)
		remaining := size
		for remaining > 0 {
			vallen := _c_getxattr(from_file, cstring(key), val, c.size_t(max_vallen))
			if vallen >= 0 && round == 1 && val != nil {
				if _c_setxattr(to_file, cstring(key), val, c.size_t(vallen), 0) != 0 {
					emsg("Failed to set extended attribute")
					return
				}
			} else if vallen < 0 {
				err := posix.errno()
				#partial switch err {
				case .ENOTSUP, .EACCES, .EPERM:
					// skip this attribute
				case .ERANGE:
					emsg("Extended attribute value too big")
					return
				case .E2BIG:
					emsg("Extended attribute list too big")
					return
				case:
					emsg("Failed to get extended attribute")
					return
				}
			}
			if round == 0 && vallen > max_vallen {
				max_vallen = vallen
			}
			keylen := c.ssize_t(len(string(cstring(key))) + 1)
			remaining -= keylen
			key = rawptr(uintptr(key) + uintptr(keylen))
		}
		if round == 1 {
			break
		}
		if max_vallen > 0 {
			val = xmalloc(c.size_t(max_vallen) + 1)
		}
		round += 1
	}
}

// ──────────────────────────
//  B3: Path/exec functions
// ──────────────────────────

@(export)
os_exepath :: proc "c" (buffer: cstring, size: ^c.size_t) -> c.int {
	context = runtime.default_context()
	n := posix.readlink("/proc/self/exe", ([^]u8)(buffer), size^)
	if n < 0 {
		return uv_translate_sys_error(c.int(posix.errno()))
	}
	([^]u8)(buffer)[n] = 0
	size^ = c.size_t(n)
	return 0
}

@(export)
os_realpath :: proc "c" (name: cstring, buf: cstring, buf_len: c.size_t) -> cstring {
	context = runtime.default_context()
	resolved := posix.realpath(name)
	if resolved == nil {
		return nil
	}
	defer posix.free(rawptr(resolved))
	resolved_str := string(resolved)
	resolved_len := c.size_t(len(resolved_str))
	if buf == nil {
		alloced := xmalloc(resolved_len + 1)
		_cstr_copy(cstring(alloced), resolved, resolved_len + 1)
		return cstring(alloced)
	}
	_cstr_copy(buf, resolved, min(resolved_len + 1, buf_len))
	return buf
}

@(export)
os_can_exe :: proc "c" (name: cstring, abspath: ^cstring, use_path: bool) -> bool {
	context = runtime.default_context()
	name_str := string(name)
	
	// If not using PATH or name contains dir separator, check directly
	if !use_path || contains_dir_sep(name_str) {
		return is_executable(name, abspath)
	}

	// Walk PATH
	path_env := posix.getenv("PATH")
	if path_env == nil {
		return false
	}
	path_str := string(path_env)
	
	path_parts := strings.split(path_str, ":")
	defer delete(path_parts)
	
	for part in path_parts {
		if len(part) == 0 { continue }
		full_path := filepath.join({part, name_str}) or_continue
		full_cstr := strings.clone_to_cstring(full_path)
		defer delete(full_cstr)
		if is_executable(full_cstr, abspath) {
			return true
		}
	}
	return false
}

is_executable :: proc(name: cstring, abspath: ^cstring) -> bool {
	st, ok := _do_stat(name)
	if !ok {
		return false
	}
	if (st.st_mode & S_IFMT) != S_IFREG {
		return false
	}
	if linux.access(name, linux.X_OK) != .NONE {
		return false
	}
	if abspath != nil {
		abspath^ = save_abs_path(name)
	}
	return true
}

contains_dir_sep :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == '/' { return true }
	}
	return false
}

_cstr_copy :: proc "contextless" (dst: cstring, src: cstring, n: c.size_t) {
	dp := ([^]byte)(dst)
	sp := ([^]byte)(src)
	for i: c.size_t = 0; i < n; i += 1 {
		dp[i] = sp[i]
		if sp[i] == 0 { break }
	}
}

// ──────────────────────────
//  B4: Directory iteration
// ──────────────────────────

// C's Directory struct (contains uv_fs_t + uv_dirent_t); we use rawptr to match its address
// and store the posix DIR* handle in a side-table.

@(export)
os_scandir :: proc "c" (dir: rawptr, path: cstring) -> bool {
	context = runtime.default_context()
	handle := posix.opendir(path)
	if handle == nil {
		return false
	}
	dir_handle_map[uintptr(dir)] = rawptr(handle)
	return true
}

@(export)
os_scandir_next :: proc "c" (dir: rawptr) -> cstring {
	context = runtime.default_context()
	handle := dir_handle_map[uintptr(dir)]
	if handle == nil {
		return nil
	}
	ent := posix.readdir(posix.DIR(handle))
	if ent == nil {
		return nil
	}
	return cstring(&ent.d_name[0])
}

@(export)
os_closedir :: proc "c" (dir: rawptr) {
	context = runtime.default_context()
	handle := dir_handle_map[uintptr(dir)]
	if handle != nil {
		posix.closedir(posix.DIR(handle))
		delete_key(&dir_handle_map, uintptr(dir))
	}
}
