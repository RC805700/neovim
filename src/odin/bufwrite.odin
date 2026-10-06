package main

import C "core:c"
import "base:runtime"
import "core:c/libc"
import "core:sys/linux"
import "core:sys/posix"

// bufwrite.c port: buffer-to-file writing.
// Publics are @(export); C-statics are _o dormant plains.

// —— Batch B1: tiny leaves ——

FIO_LATIN1_O :: 0x01
FIO_UTF8_O :: 0x02
FIO_UCS2_O :: 0x04
FIO_UCS4_O :: 0x08
FIO_UTF16_O :: 0x10
FIO_ENDIAN_L_O :: 0x80
FIO_NOCONVERT_O :: 0x2000
SMALLBUFSIZE_O :: 256

Error_T :: struct {
	num:   cstring, // 0
	msg:   ^u8,     // 8
	arg:   C.int,   // 16
	alloc: bool,    // 20
	_pad:  [3]u8,
}
#assert(size_of(Error_T) == 24)

Bw_Info_O :: struct {
	bw_fd:              C.int,    // 0
	_pad0:              [4]u8,
	bw_buf:             ^u8,      // 8
	bw_len:             C.int,    // 16
	bw_flags:           C.int,    // 20
	bw_first:           C.int,    // 24
	_pad1:              [4]u8,
	bw_conv_buf:        ^u8,      // 32
	bw_conv_buflen:     C.size_t, // 40
	bw_conv_error:      C.int,    // 48
	bw_conv_error_lnum: C.int,    // 52
	bw_start_lnum:      C.int,    // 56
	_pad2:              [4]u8,
	bw_iconv_fd:        rawptr,   // 64
}
#assert(size_of(Bw_Info_O) == 72)

E_READONLY_S :: "is read-only (cannot override: \"W\" in 'cpoptions')"
E_PATCHMODE_EMPTY_S :: "E206: Patchmode: can't touch empty original file"
E_CONV_FAILED_S :: "E513: Write error, conversion failed (make 'fenc' empty to override)"
E_CONV_FAILED_LINE_S :: "E513: Write error, conversion failed in line %" + "ld" + " (make 'fenc' empty to override)"
E_FS_FULL_S :: "E514: Write error (file system full?)"
E_NOMATCH_BT_S :: "E676: No matching autocommands for buftype=%s buffer"

foreign _ {
	@(link_name = "get_fio_flags")
	get_fio_flags_e :: proc "c" (name: cstring) -> C.int ---
	@(link_name = "time_differs")
	time_differs_e :: proc "c" (file_info: rawptr, mtime: i64, mtime_ns: i64) -> bool ---
	p_bk: C.int
	@(link_name = "p_bsk")
	p_bsk_g: ^u8
	@(link_name = "p_wb")
	p_wb_g: C.int
	@(link_name = "set_rw_fname")
	set_rw_fname_e :: proc "c" (fname: cstring, sfname: cstring) -> C.int ---
	@(link_name = "filemess")
	filemess_e :: proc "c" (buf: rawptr, name: cstring, s: cstring) ---
	@(link_name = "my_iconv_open")
	my_iconv_open_e :: proc "c" (to: cstring, from: cstring) -> rawptr ---
	@(link_name = "need_conversion")
	need_conversion_e :: proc "c" (fenc: cstring) -> bool ---
	@(link_name = "add_quoted_fname")
	add_quoted_fname_e :: proc "c" (ret_buf: cstring, bufsize: C.size_t, buf: rawptr, fname: cstring) ---
	@(link_name = "msg_add_fileformat")
	msg_add_fileformat_e :: proc "c" (eol_type: C.int) -> bool ---
	@(link_name = "msg_add_lines")
	msg_add_lines_e :: proc "c" (insert_space: C.int, lnum: C.int, nchars: i64) ---
	@(link_name = "iconv_close")
	iconv_close_e :: proc "c" (cd: rawptr) -> C.int ---
}

// —— Batch B6a: buf_write engine, part 1 (entry through open) ——

WRITEBUFSIZE_O :: 8192
E_EMPTY_BUFFER_S :: "E749: Empty buffer"
E_LONGNAME_S :: "E75: Name too long"
E166_S :: "E166: Can't open linked file for writing"
E212_S :: "E212: Can't open file for writing: %s"
E213_S :: "E213: Cannot convert (add ! to write without conversion)"
E214_S :: "E214: Can't find temp file for writing"
CPO_FNAMEAPP_O :: 'P'
CPO_FNAMEW_O :: 'F'
CPO_KEEPRO_O :: 'Z'
SHM_OVER_O :: 'o'
SHM_WRITE_O :: 'W'
SHM_WRI_O :: 'w'
ICONV_MULT_BW_O :: 8
B_LAST_CHANGETICK_OFF_O :: 248
B_FILE_ID_VALID_OFF_O :: 184
E512_S :: "E512: Close failed: %s"
E_FSYNC_S :: "E667: Fsync failed: %s"

cstr_u8_o :: proc "c" (s: cstring) -> ^u8 {
	context = runtime.default_context()
	return transmute(^u8)(rawptr(s))
}

restore_open_failed_o :: proc "c" (backup: cstring, backup_copy: bool, wfname: cstring, fname: cstring, newfile: bool, endp: ^C.int) {
	context = runtime.default_context()
	if backup != nil && wfname == fname {
		if backup_copy {
			if !os_path_exists(fname) {
				vim_rename_e(fname, backup)
			}
			if os_path_exists(fname) {
				os_remove(backup)
			}
		} else {
			vim_rename_e(backup, fname)
		}
	}
	if !newfile && !os_path_exists(fname) {
		endp^ = 0
	}
}

// Batch B6: full buf_write engine (entry + open + write loop + epilogue).
@(export)
buf_write :: proc "c" (buf_in: rawptr, fname_in: cstring, sfname_in: cstring, start_in: C.int, end_in: C.int, eap: rawptr, append: bool, forceit: bool, reset_changed: bool, filtering: bool) -> C.int {
	context = runtime.default_context()
	buf := buf_in
	fname := fname_in
	sfname := sfname_in
	start := start_in
	end := end_in
	retval: C.int = OK_E
	msg_save := msg_scroll
	prev_got_int := got_int
	whole := start == 1 && end == (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	write_undo_file := false
	sha_ctx: Sha256_Ctx
	bkc := get_bkc_flags(buf)
	if fname == nil || ([^]u8)(transmute(^u8)(fname))[0] == 0 {
		return FAIL_E
	}
	if (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil {
		emsg(cstring(E_EMPTY_BUFFER_S))
		return FAIL_E
	}
	if check_secure() {
		return FAIL_E
	}
	if libc.strlen(fname) >= C.size_t(MAXPATHL_O) {
		emsg(cstring(E_LONGNAME_S))
		return FAIL_E
	}
	write_info: Bw_Info_O
	write_info.bw_conv_buf = nil
	write_info.bw_conv_error = 0
	write_info.bw_conv_error_lnum = 0
	write_info.bw_iconv_fd = rawptr(~uintptr(0))
	ex_no_reprint_g = true
	if (^rawptr)(uintptr(buf) + B_FFNAME)^ == nil && reset_changed && whole && buf == curbuf && !bt_nofilename(buf) && !filtering && (!append || vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FNAMEAPP_O)) != nil) && vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FNAMEW_O)) != nil {
		if set_rw_fname_e(fname, sfname) == FAIL_E {
			return FAIL_E
		}
		buf = curbuf
	}
	if sfname == nil {
		sfname = fname
	}
	ffname := fname
	fname = sfname
	overwriting := (^rawptr)(uintptr(buf) + B_FFNAME)^ != nil && path_fnamecmp_r(ffname, (^cstring)(uintptr(buf) + B_FFNAME)^) == 0
	no_wait_return += 1
	orig_start := ((^Pos_T)(uintptr(buf) + B_OP_START))^
	orig_end := ((^Pos_T)(uintptr(buf) + B_OP_END))^
	(^C.int)(uintptr(buf) + B_OP_START)^ = start
	(^C.int)(uintptr(buf) + B_OP_START + 4)^ = 0
	(^C.int)(uintptr(buf) + B_OP_END)^ = end
	(^C.int)(uintptr(buf) + B_OP_END + 4)^ = 0
	failed := false
	buffer: ^u8 = nil
	bufsize: C.int = 0
	smallbuf: [256]u8 = {}
	err := Error_T{}
	perm: C.int = 0
	newfile := false
	device := false
	file_readonly := false
	backup: cstring = nil
	fenc_tofree: ^u8 = nil
	file_info_old: FileInfo = {}
	acl: rawptr = nil
	backup_copy := false
	dobackup := false
	made_writable := false
	wfname: cstring = nil
	fenc: cstring = nil
	converted := false
	wb_flags: C.int = 0
	notconverted := false
	no_eol := false
	nchars: C.int = 0
	lnum: C.int = 0
	fileformat: C.int = 0
	fd: C.int = -1
	for _ in 0..<1 {
		res := buf_write_do_autocmds_o(buf, &fname, &sfname, &ffname, start, &end, eap, append, filtering, reset_changed, overwriting, whole, orig_start, orig_end)
		if res != NOTDONE_O {
			return res
		}
		if (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
			op_start := (^Pos_T)(uintptr(buf) + B_OP_START)
			op_end := (^Pos_T)(uintptr(buf) + B_OP_END)
			op_start^ = orig_start
			op_end^ = orig_end
		}
		if shortmess(C.int(SHM_OVER_O)) && !exiting {
			msg_scroll = 0
		} else {
			msg_scroll = 1
		}
		if !filtering {
			filemess_e(buf, fname, cstring(""))
		}
		msg_scroll = 0
		buffer = transmute(^u8)(verbose_try_malloc(C.size_t(WRITEBUFSIZE_O)))
		if buffer == nil {
			buffer = transmute(^u8)(&smallbuf[0])
			bufsize = SMALLBUFSIZE_O
		} else {
			bufsize = WRITEBUFSIZE_O
		}
		err = Error_T{}
		perm = 0
		newfile = false
		device = false
		file_readonly = false
		backup = nil
		fenc_tofree = nil
		file_info_old = FileInfo{}
		acl = nil
		if get_fileinfo_o(buf, fname, overwriting, forceit, &file_info_old, &perm, &device, &newfile, &file_readonly, &err) == FAIL_E {
			failed = true
			break
		}
		if !newfile {
			acl = os_get_acl(fname)
		}
		p_bsk_s := transmute(cstring)(p_bsk_g)
		_ = p_bsk_s
		dobackup = p_wb_g != 0 || p_bk != 0 || ([^]u8)(p_pm_g)[0] != 0
		if dobackup && ([^]u8)(p_bsk_g)[0] != 0 && match_file_list_e(transmute(^u8)(p_bsk_g), transmute(^u8)(sfname), transmute(^u8)(ffname)) {
			dobackup = false
		}
		backup_copy = false
		prev_got_int = got_int
		got_int = false
		(^bool)(uintptr(buf) + B_SAVING_OFF)^ = true
		if !(append && ([^]u8)(p_pm_g)[0] == 0) && !filtering && perm >= 0 && dobackup {
			if buf_write_make_backup_o(fname, append, &file_info_old, acl, perm, get_bkc_flags(buf), file_readonly, forceit, &backup_copy, &backup, &err) == FAIL_E {
				retval = FAIL_E
				failed = true
				break
			}
		}
		made_writable = false
		if forceit && perm >= 0 && (perm & 0o200) == 0 && file_info_old.stat.st_uid == u64(posix.getuid()) && vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FWRITE_O)) == nil {
			perm |= 0o200
			os_setperm(fname, perm)
			made_writable = true
		}
		if forceit && overwriting && vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_KEEPRO_O)) == nil {
			(^C.int)(uintptr(buf) + B_P_RO_OFF)^ = 0
			need_maketitle_opt = true
			status_redraw_all()
		}
		end = min(end, (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^)
		if ((^C.int)(uintptr(buf) + B_ML_FLAGS_OFF)^ & ML_EMPTY_O) != 0 {
			start = end + 1
		}
		wfname = nil
		if reset_changed && !newfile && overwriting && !(exiting && backup != nil) {
			p_fs_v := (^C.int)(uintptr(buf) + B_P_FS_OFF)^
			fs_v := p_fs
			if p_fs_v >= 0 {
				fs_v = p_fs_v
			}
			ml_preserve(buf, false, fs_v != 0)
			if got_int {
				err = set_err_o(_t(cstring("Interrupted")))
				restore_open_failed_o(backup, backup_copy, wfname, fname, newfile, &end)
				if wfname != fname {
					xfree(rawptr(wfname))
				}
				failed = true
				break
			}
		}
		wfname = fname
		if eap != nil && (^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^ != 0 {
			eap_cmd := (^cstring)(uintptr(eap) + EXARG_CMD_OFF)^
			eap_enc_off := (^C.int)(uintptr(eap) + EXARG_FORCE_ENC_OFF_O)^
			eap_enc_ptr := transmute(^u8)(rawptr(uintptr(rawptr(eap_cmd)) + uintptr(eap_enc_off)))
			fenc = transmute(cstring)(enc_canonize_r(eap_enc_ptr))
			fenc_tofree = transmute(^u8)(fenc)
		} else {
			fenc = transmute(cstring)((^rawptr)(uintptr(buf) + B_P_FENC_OFF)^)
		}
		converted = need_conversion_e(fenc)
		wb_flags = 0
		if converted {
			wb_flags = get_fio_flags_e(fenc)
			if (wb_flags & (FIO_UCS2_O | FIO_UCS4_O | FIO_UTF16_O | FIO_UTF8_O)) != 0 {
				if (wb_flags & (FIO_UCS2_O | FIO_UTF16_O | FIO_UTF8_O)) != 0 {
					write_info.bw_conv_buflen = C.size_t(bufsize) * 2
				} else {
					write_info.bw_conv_buflen = C.size_t(bufsize) * 4
				}
				write_info.bw_conv_buf = transmute(^u8)(verbose_try_malloc(write_info.bw_conv_buflen))
				if write_info.bw_conv_buf == nil {
					end = 0
				}
			}
		}
		if converted && wb_flags == 0 {
			write_info.bw_iconv_fd = my_iconv_open_e(fenc, cstring("utf-8"))
			if write_info.bw_iconv_fd != rawptr(~uintptr(0)) {
				write_info.bw_conv_buflen = C.size_t(bufsize) * ICONV_MULT_BW_O
				write_info.bw_conv_buf = transmute(^u8)(verbose_try_malloc(write_info.bw_conv_buflen))
				if write_info.bw_conv_buf == nil {
					end = 0
				}
				write_info.bw_first = 1
			} else {
				if ([^]u8)(transmute(^u8)(p_ccv_e))[0] != 0 {
					wfname = transmute(cstring)(vim_tempname())
					if wfname == nil {
						err = set_err_o(_t(cstring(E214_S)))
						restore_open_failed_o(backup, backup_copy, wfname, fname, newfile, &end)
						if wfname != fname {
							xfree(rawptr(wfname))
						}
						failed = true
						break
					}
				}
			}
		}
		notconverted = false
		if converted && wb_flags == 0 && write_info.bw_iconv_fd == rawptr(~uintptr(0)) && wfname == fname {
			if !forceit {
				err = set_err_o(_t(cstring(E213_S)))
				restore_open_failed_o(backup, backup_copy, wfname, fname, newfile, &end)
				if wfname != fname {
					xfree(rawptr(wfname))
				}
				failed = true
				break
			}
			notconverted = true
		}
		checking := true
		for {
			if !converted || dobackup {
				checking = false
			}
			if checking {
				fd = -1
				write_info.bw_fd = fd
			} else {
				oflags: C.int = 0
				oflags |= posix.O_WRONLY
				if append {
					oflags |= posix.O_APPEND
					if forceit {
						oflags |= posix.O_CREAT
					}
				} else {
					oflags |= posix.O_CREAT | posix.O_TRUNC
				}
				mode := C.int(0o666)
				if perm >= 0 {
					mode = perm & 0o777
				}
				open_failed := false
				for {
					fd = os_open(wfname, oflags, mode)
					if fd >= 0 {
						break
					}
					if err.msg == nil {
						link_bad := false
						if !newfile && os_fileinfo_hardlinks(&file_info_old) > 1 {
							link_bad = true
						} else {
							li: FileInfo = {}
							if os_fileinfo_link(fname, &li) && !os_fileinfo_id_equal(&li, &file_info_old) {
								link_bad = true
							}
						}
						if link_bad {
							err = set_err_o(_t(cstring(E166_S)))
						} else {
							err = set_err_arg_o(_t(cstring(E212_S)), fd)
							if forceit && vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FWRITE_O)) == nil && perm >= 0 {
								if (perm & 0o200) == 0 {
									made_writable = true
								}
								perm |= 0o200
								if file_info_old.stat.st_uid != u64(posix.getuid()) || file_info_old.stat.st_gid != u64(posix.getgid()) {
									perm &= 0o777
								}
								if !append {
									os_remove(wfname)
								}
								continue
							}
						}
					}
					restore_open_failed_o(backup, backup_copy, wfname, fname, newfile, &end)
					if wfname != fname {
						xfree(rawptr(wfname))
					}
					open_failed = true
					break
				}
				if open_failed {
					failed = true
					break
				}
				write_info.bw_fd = fd
			}
			err = set_err_o(nil)
			write_info.bw_buf = buffer
			nchars = 0
			write_bin := false
			if eap != nil && (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ != 0 {
				write_bin = (^C.int)(uintptr(eap) + EXARG_FORCE_BIN_OFF_O)^ == FORCE_BIN_O
			} else {
				write_bin = (^C.int)(uintptr(buf) + B_P_BIN_OFF)^ != 0
			}
			if (^C.int)(uintptr(buf) + B_P_BOMB_OFF)^ != 0 && !write_bin && (!append || perm < 0) {
				write_info.bw_len = make_bom_o(buffer, fenc)
				if write_info.bw_len > 0 {
					write_info.bw_flags = FIO_NOCONVERT_O | wb_flags
					if buf_write_bytes_o(&write_info) == FAIL_E {
						end = 0
					} else {
						nchars += write_info.bw_len
					}
				}
			}
			write_info.bw_start_lnum = start
			write_undo_file = (^C.int)(uintptr(buf) + B_P_UDF_OFF)^ != 0 && overwriting && !append && !filtering && reset_changed && !checking
			if write_undo_file {
				sha256_start(&sha_ctx)
			}
			write_info.bw_len = 0
			write_info.bw_flags = wb_flags
			fileformat = get_fileformat_force(buf, eap)
			s := buffer
			lnum = start
			for lnum <= end {
				line := ml_get_buf(buf, lnum)
				if write_undo_file {
					line_s := transmute(cstring)(rawptr(uintptr(line) + 1))
					sha256_update(&sha_ctx, transmute(^u8)(line_s), C.size_t(libc.strlen(line_s)) + 1)
				}
				ptr := transmute(^u8)(rawptr(uintptr(line) - 1))
				for {
					ptr = transmute(^u8)(rawptr(uintptr(ptr) + 1))
					ch := ([^]u8)(ptr)[0]
					if ch == 0 {
						break
					}
					if ch == u8(NL_O) {
						([^]u8)(s)[0] = 0
					} else if ch == CAR_O && fileformat == EOL_MAC_S {
						([^]u8)(s)[0] = u8(NL_O)
					} else {
						([^]u8)(s)[0] = ch
					}
					s = transmute(^u8)(rawptr(uintptr(s) + 1))
					write_info.bw_len += 1
					if write_info.bw_len != bufsize {
						continue
					}
					if buf_write_bytes_o(&write_info) == FAIL_E {
						end = 0
						break
					}
					nchars += bufsize - write_info.bw_len
					s = transmute(^u8)(rawptr(uintptr(buffer) + uintptr(write_info.bw_len)))
					write_info.bw_start_lnum = lnum
				}
				if end == 0 {
					lnum += 1
					no_eol = true
					break
				}
				if lnum == end && (write_bin || (^C.int)(uintptr(buf) + B_P_FIXEOL_OFF_O)^ == 0) && ((write_bin && lnum == (^C.int)(uintptr(buf) + B_NO_EOL_LNUM_OFF)^) || (lnum == (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ && (^C.int)(uintptr(buf) + B_P_EOL_OFF)^ == 0)) {
					lnum += 1
					no_eol = true
					break
				}
				if fileformat == EOL_UNIX_S {
					([^]u8)(s)[0] = u8(NL_O)
					s = transmute(^u8)(rawptr(uintptr(s) + 1))
				} else {
					([^]u8)(s)[0] = CAR_O
					s = transmute(^u8)(rawptr(uintptr(s) + 1))
					if fileformat == EOL_DOS_S {
						write_info.bw_len += 1
						if write_info.bw_len == bufsize {
							if buf_write_bytes_o(&write_info) == FAIL_E {
								end = 0
								break
							}
							nchars += bufsize - write_info.bw_len
							s = transmute(^u8)(rawptr(uintptr(buffer) + uintptr(write_info.bw_len)))
						}
						([^]u8)(s)[0] = u8(NL_O)
						s = transmute(^u8)(rawptr(uintptr(s) + 1))
					}
				}
				write_info.bw_len += 1
				if write_info.bw_len == bufsize {
					if buf_write_bytes_o(&write_info) == FAIL_E {
						end = 0
						break
					}
					nchars += bufsize - write_info.bw_len
					s = transmute(^u8)(rawptr(uintptr(buffer) + uintptr(write_info.bw_len)))
					os_breakcheck()
					if got_int {
						end = 0
						break
					}
				}
				lnum += 1
			}
			if write_info.bw_len > 0 && end > 0 {
				remaining := write_info.bw_len
				if buf_write_bytes_o(&write_info) == FAIL_E {
					end = 0
				}
				nchars += remaining - write_info.bw_len
			}
			if end != 0 && write_info.bw_len > 0 {
				write_info.bw_conv_error = 1
				write_info.bw_conv_error_lnum = end
				end = 0
			}
			if (^C.int)(uintptr(buf) + B_P_FIXEOL_OFF_O)^ == 0 && (^C.int)(uintptr(buf) + B_P_EOF_OFF)^ != 0 {
				write_eintr_e(write_info.bw_fd, rawptr(cstr_u8_o(cstring("\x1a"))), C.size_t(1))
			}
			if !checking || end == 0 {
				break
			}
			checking = false
		}
		if failed {
			break
		}
		if !checking {
			fs_sync := p_fs
			if (^C.int)(uintptr(buf) + B_P_FS_OFF)^ >= 0 {
				fs_sync = (^C.int)(uintptr(buf) + B_P_FS_OFF)^
			}
			ferr := os_fsync(fd)
			if fs_sync != 0 && ferr != 0 && ferr != C.int(UV_ENOTSUP) && !device {
				err = set_err_arg_o(_t(cstring(E_FSYNC_S)), ferr)
				end = 0
			}
			if !backup_copy {
				os_copy_xattr(backup, wfname)
			}
			if backup != nil && !backup_copy {
				fi_new: FileInfo = {}
				if !os_fileinfo(wfname, &fi_new) || fi_new.stat.st_uid != file_info_old.stat.st_uid || fi_new.stat.st_gid != file_info_old.stat.st_gid {
					_ = os_fchown(fd, C.int(file_info_old.stat.st_uid), C.int(file_info_old.stat.st_gid))
					if perm >= 0 {
						os_setperm(wfname, perm)
					}
				}
				buf_set_file_id(buf)
			} else if !(^bool)(uintptr(buf) + B_FILE_ID_VALID_OFF_O)^ {
				buf_set_file_id(buf)
			}
			if cerr := os_close(fd); cerr != 0 {
				err = set_err_arg_o(_t(cstring(E512_S)), cerr)
				end = 0
			}
			if made_writable {
				perm &= ~C.int(0o200)
			}
			if perm >= 0 {
				os_setperm(wfname, perm)
			}
			if !backup_copy {
				os_set_acl(wfname, acl)
			}
			if wfname != fname {
				if end != 0 {
					if eval_charconvert(cstring("utf-8"), fenc, wfname, fname) == FAIL_E {
						write_info.bw_conv_error = 1
						end = 0
					}
				}
				os_remove(wfname)
				xfree(rawptr(wfname))
			}
		}
		if end == 0 {
			if err.msg == nil {
				if write_info.bw_conv_error != 0 {
					if write_info.bw_conv_error_lnum == 0 {
						err = set_err_o(_t(cstring(E_CONV_FAILED_S)))
					} else {
						emsg_buf := transmute(^u8)(xmalloc(300))
						libc.snprintf(emsg_buf, C.size_t(300), cstring("E513: Write error, conversion failed in line %ld (make 'fenc' empty to override)"), C.longlong(write_info.bw_conv_error_lnum))
						err = Error_T{msg = emsg_buf, alloc = true}
					}
				} else if got_int {
					err = set_err_o(_t(cstring(E_INTERR_S)))
				} else {
					err = set_err_o(_t(cstring(E_FS_FULL_S)))
				}
			}
			if backup != nil {
				if backup_copy {
					if got_int {
						msg(_t(cstring(E_INTERR_S)), HLF_E_O)
						ui_flush()
					}
					if os_copy(backup, fname, UV_FS_COPYFILE_FICLONE_O) == 0 {
						end = 1
					}
				} else {
					if vim_rename_e(backup, fname) == 0 {
						end = 1
					}
				}
			}
			failed = true
			break
		}
		lnum -= start
		no_wait_return -= 1
		if !filtering {
			add_quoted_fname_e(transmute(cstring)(&IObuff[0]), C.size_t(IOSIZE), buf, fname)
			msg_id: [IOSIZE + 14]u8 = {}
			libc.memmove(rawptr(&msg_id[0]), rawptr(cstr_u8_o(cstring("nvim.bufwrite "))), 14)
			xstrlcat(transmute(^u8)(&msg_id[0]), transmute(^u8)(&IObuff[0]), C.size_t(14 + libc.strlen(transmute(cstring)(&IObuff[0]))))
			insert_space := C.int(0)
			if write_info.bw_conv_error != 0 {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring(" CONVERSION ERROR"))), C.size_t(IOSIZE))
				insert_space = 1
				if write_info.bw_conv_error_lnum != 0 {
					io_len := libc.strlen(transmute(cstring)(&IObuff[0]))
					libc.snprintf(transmute(^u8)(rawptr(uintptr(&IObuff[0]) + uintptr(io_len))), C.size_t(IOSIZE) - C.size_t(io_len), cstring(" in line %lld;"), C.longlong(write_info.bw_conv_error_lnum))
				}
			} else if notconverted {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring("[NOT converted]"))), C.size_t(IOSIZE))
				insert_space = 1
			} else if converted {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring("[converted]"))), C.size_t(IOSIZE))
				insert_space = 1
			}
			if device {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring("[Device]"))), C.size_t(IOSIZE))
				insert_space = 1
			} else if newfile {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring("[New]"))), C.size_t(IOSIZE))
				insert_space = 1
			}
			if no_eol {
				xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring("[noeol]"))), C.size_t(IOSIZE))
				insert_space = 1
			}
			if msg_add_fileformat_e(fileformat) {
				insert_space = 1
			}
			msg_add_lines_e(insert_space, lnum, i64(nchars))
			if !shortmess(C.int(SHM_WRITE_O)) {
				if append {
					if shortmess(C.int(SHM_WRI_O)) {
						xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring(" [a]"))), C.size_t(IOSIZE))
					} else {
						xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring(" appended"))), C.size_t(IOSIZE))
					}
				} else {
					if shortmess(C.int(SHM_WRI_O)) {
						xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring(" [w]"))), C.size_t(IOSIZE))
					} else {
						xstrlcat(transmute(^u8)(&IObuff[0]), cstr_u8_o(_t(cstring(" written"))), C.size_t(IOSIZE))
					}
				}
			}
			ui_busy_start()
			prog := msg_progress(transmute(^u8)(&IObuff[0]), transmute(cstring)(&msg_id[0]), cstring("success"), 0, true, true)
			set_keep_msg(transmute(cstring)(prog), 0)
			ui_busy_stop()
		}
		if reset_changed && whole && !append && write_info.bw_conv_error == 0 && (overwriting || vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_PLUS_O)) != nil) {
			unchanged(buf, true, false)
			changedtick := i64(buf_changedtick_inline(buf))
			if (^i64)(uintptr(buf) + B_LAST_CHANGETICK_OFF_O)^ + 1 == changedtick {
				(^i64)(uintptr(buf) + B_LAST_CHANGETICK_OFF_O)^ = changedtick
			}
			u_unchanged(buf)
			u_update_save_nr(buf)
		}
		if overwriting {
			ml_timestamp(buf)
			if append {
				(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(BF_NEW_O)
			} else {
				(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(BF_WRITE_MASK_O)
			}
		}
		if ([^]u8)(p_pm_g)[0] != 0 && dobackup {
			org := modname_e(fname, transmute(cstring)(p_pm_g), false)
			if backup != nil {
				if org == nil {
					emsg(_t(cstring(E205_S)))
				} else if !os_path_exists(transmute(cstring)(org)) {
					vim_rename_e(backup, transmute(cstring)(org))
					backup = nil
					os_file_settime(transmute(cstring)(org), f64(file_info_old.stat.st_atim.tv_sec), f64(file_info_old.stat.st_mtim.tv_sec))
				}
			} else {
				if org == nil {
					emsg(_t(cstring(E206B_S)))
				} else {
					pm_flags: C.int = 0
					pm_flags |= posix.O_CREAT | posix.O_EXCL | posix.O_NOFOLLOW
					pm_mode := perm & 0o777
					if perm < 0 {
						pm_mode = C.int(0o666)
					}
					empty_fd := os_open(transmute(cstring)(org), pm_flags, pm_mode)
					if empty_fd < 0 {
						emsg(_t(cstring(E206B_S)))
					} else {
						linux.close(linux.Fd(empty_fd))
					}
				}
			}
			if org != nil {
				os_setperm(transmute(cstring)(org), C.int(os_getperm(fname) & 0o777))
				xfree(rawptr(org))
			}
		}
		if p_bk == 0 && backup != nil && write_info.bw_conv_error == 0 && os_remove(backup) != 0 {
			emsg(_t(cstring(E207_S)))
		}
		break
	}
	if failed {
		no_wait_return -= 1
	}
	// __EPILOGUE__ shared tail (fail/nofail)
	(^bool)(uintptr(buf) + B_SAVING_OFF)^ = false
	xfree(rawptr(backup))
	if buffer != transmute(^u8)(&smallbuf[0]) {
		xfree(rawptr(buffer))
	}
	xfree(rawptr(fenc_tofree))
	xfree(rawptr(write_info.bw_conv_buf))
	if write_info.bw_iconv_fd != rawptr(~uintptr(0)) {
		iconv_close_e(write_info.bw_iconv_fd)
		write_info.bw_iconv_fd = rawptr(~uintptr(0))
	}
	os_free_acl(acl)
	if err.msg != nil {
		add_quoted_fname_e(transmute(cstring)(&IObuff[0]), C.size_t(IOSIZE) - 100, buf, fname)
		emit_err_o(&err)
		retval = FAIL_E
		if end == 0 {
			msg_puts_hl(_t(cstring("\nWARNING: Original file may be lost or damaged\n")), HLF_E_O, true)
			msg_puts_hl(_t(cstring("don't quit the editor until the file is successfully written!")), HLF_E_O, true)
			if os_fileinfo(fname, &file_info_old) {
				buf_store_file_info_e(buf, &file_info_old)
				(^i64)(uintptr(buf) + B_MTIME_READ_OFF_O)^ = (^i64)(uintptr(buf) + B_MTIME_OFF_O)^
				(^i64)(uintptr(buf) + B_MTIME_READ_NS_OFF_O)^ = (^i64)(uintptr(buf) + B_MTIME_NS_OFF_O)^
			}
		}
	}
	msg_scroll = msg_save
	if retval == OK_E && write_undo_file {
		hash: [UNDO_HASH_SIZE]u8 = {}
		sha256_finish(&sha_ctx, &hash[0])
		u_write_undo(nil, false, buf, &hash[0])
	}
	if !should_abort_r(retval) {
		buf_write_do_post_autocmds_o(buf, fname, eap, append, filtering, reset_changed, whole)
		if aborting_r() {
			retval = 0
		}
	}
	got_int = got_int || prev_got_int
	return retval
}

ucs2bytes_o :: proc "c" (c_in: u32, pp: ^^u8, flags: C.int) -> bool {
	context = runtime.default_context()
	p := pp^
	c := c_in
	error := false
	if (flags & FIO_UCS4_O) != 0 {
		if (flags & FIO_ENDIAN_L_O) != 0 {
			([^]u8)(p)[0] = u8(c)
			([^]u8)(p)[1] = u8(c >> 8)
			([^]u8)(p)[2] = u8(c >> 16)
			([^]u8)(p)[3] = u8(c >> 24)
			p = transmute(^u8)(rawptr(uintptr(p) + 4))
		} else {
			([^]u8)(p)[0] = u8(c >> 24)
			([^]u8)(p)[1] = u8(c >> 16)
			([^]u8)(p)[2] = u8(c >> 8)
			([^]u8)(p)[3] = u8(c)
			p = transmute(^u8)(rawptr(uintptr(p) + 4))
		}
	} else if (flags & (FIO_UCS2_O | FIO_UTF16_O)) != 0 {
		if c >= 0x10000 {
			if (flags & FIO_UTF16_O) != 0 {
				c -= 0x10000
				if c >= 0x100000 {
					error = true
				}
				cc := C.int(((c >> 10) & 0x3ff) + 0xd800)
				if (flags & FIO_ENDIAN_L_O) != 0 {
					([^]u8)(p)[0] = u8(cc)
					([^]u8)(p)[1] = u8(cc >> 8)
				} else {
					([^]u8)(p)[0] = u8(cc >> 8)
					([^]u8)(p)[1] = u8(cc)
				}
				p = transmute(^u8)(rawptr(uintptr(p) + 2))
				c = (c & 0x3ff) + 0xdc00
			} else {
				error = true
			}
		}
		if (flags & FIO_ENDIAN_L_O) != 0 {
			([^]u8)(p)[0] = u8(c)
			([^]u8)(p)[1] = u8(c >> 8)
		} else {
			([^]u8)(p)[0] = u8(c >> 8)
			([^]u8)(p)[1] = u8(c)
		}
		p = transmute(^u8)(rawptr(uintptr(p) + 2))
	} else {
		if c >= 0x100 {
			error = true
			([^]u8)(p)[0] = 0xBF
		} else {
			([^]u8)(p)[0] = u8(c)
		}
		p = transmute(^u8)(rawptr(uintptr(p) + 1))
	}
	pp^ = p
	return error
}

make_bom_o :: proc "c" (buf_in: ^u8, name: cstring) -> C.int {
	context = runtime.default_context()
	buf := buf_in
	flags := get_fio_flags_e(name)
	if flags == FIO_LATIN1_O || flags == 0 {
		return 0
	}
	if flags == FIO_UTF8_O {
		([^]u8)(buf)[0] = 0xef
		([^]u8)(buf)[1] = 0xbb
		([^]u8)(buf)[2] = 0xbf
		return 3
	}
	p := buf
	ucs2bytes_o(0xfeff, &p, flags)
	return C.int(uintptr(p) - uintptr(buf))
}

set_err_num_o :: proc "c" (num: cstring, msg: cstring) -> Error_T {
	context = runtime.default_context()
	return Error_T{num = num, msg = transmute(^u8)(msg), arg = 0, alloc = false}
}

set_err_o :: proc "c" (msg: cstring) -> Error_T {
	context = runtime.default_context()
	return Error_T{num = nil, msg = transmute(^u8)(msg), arg = 0, alloc = false}
}

set_err_arg_o :: proc "c" (msg: cstring, arg: C.int) -> Error_T {
	context = runtime.default_context()
	return Error_T{num = nil, msg = transmute(^u8)(msg), arg = arg, alloc = false}
}

emit_err_o :: proc "c" (e: ^Error_T) {
	context = runtime.default_context()
	if e.num != nil {
		if e.arg != 0 {
			semsg(cstring("%s: %s%s: %s"), e.num, transmute(cstring)(&IObuff[0]), transmute(cstring)(e.msg), os_strerror(e.arg))
		} else {
			semsg(cstring("%s: %s%s"), e.num, transmute(cstring)(&IObuff[0]), transmute(cstring)(e.msg))
		}
	} else if e.arg != 0 {
		semsg(transmute(cstring)(e.msg), os_strerror(e.arg))
	} else {
		emsg(transmute(cstring)(e.msg))
	}
	if e.alloc {
		xfree(rawptr(e.msg))
	}
}

check_mtime_o :: proc "c" (buf: rawptr, file_info: rawptr) -> C.int {
	context = runtime.default_context()
	if (^i64)(uintptr(buf) + B_MTIME_READ_OFF_O)^ != 0 && time_differs_e(file_info, (^i64)(uintptr(buf) + B_MTIME_READ_OFF_O)^, (^i64)(uintptr(buf) + B_MTIME_READ_NS_OFF_O)^) {
		msg_scroll = 1
		msg_silent = 0
		msg(_t(cstring("WARNING: The file has been changed since reading it!!!")), HLF_E_O)
		if ask_yesno(_t(cstring("Do you really want to write to it"))) == 'n' {
			return FAIL_E
		}
		msg_scroll = 0
	}
	return OK_E
}

// —— Batch B2: fileinfo cluster ——

CPO_FWRITE_O :: 'W'
S_IFMT_O :: 0o170000
S_IFREG_O :: 0o100000
S_IFDIR_O :: 0o040000

get_fileinfo_os_o :: proc "c" (fname: cstring, file_info_old: ^FileInfo, overwriting: bool, perm: ^C.int, device: ^bool, newfile: ^bool, err: ^Error_T) -> C.int {
	context = runtime.default_context()
	perm^ = -1
	if !os_fileinfo(fname, file_info_old) {
		newfile^ = true
	} else {
		perm^ = C.int(file_info_old.stat.st_mode)
		if (file_info_old.stat.st_mode & S_IFMT_O) != S_IFREG_O {
			if (file_info_old.stat.st_mode & S_IFMT_O) == S_IFDIR_O {
				err^ = set_err_num_o(cstring("E502"), _t(cstring("is a directory")))
				return FAIL_E
			}
			if os_nodetype(fname) != NODE_WRITABLE {
				err^ = set_err_num_o(cstring("E503"), _t(cstring("is not a file or writable device")))
				return FAIL_E
			}
			device^ = true
			newfile^ = true
			perm^ = -1
		}
	}
	return OK_E
}

get_fileinfo_o :: proc "c" (buf: rawptr, fname: cstring, overwriting: bool, forceit: bool, file_info_old: ^FileInfo, perm: ^C.int, device: ^bool, newfile: ^bool, readonly: ^bool, err: ^Error_T) -> C.int {
	context = runtime.default_context()
	if get_fileinfo_os_o(fname, file_info_old, overwriting, perm, device, newfile, err) == FAIL_E {
		return FAIL_E
	}
	readonly^ = false
	if !device^ && !newfile^ {
		readonly^ = os_file_is_writable(fname) == 0
		if !forceit && readonly^ {
			if vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FWRITE_O)) != nil {
				err^ = set_err_num_o(cstring("E504"), _t(cstring(E_READONLY_S)))
			} else {
				err^ = set_err_num_o(cstring("E505"), _t(cstring("is read-only (add ! to override)")))
			}
			return FAIL_E
		}
		if overwriting && !forceit {
			if check_mtime_o(buf, file_info_old) == FAIL_E {
				return FAIL_E
			}
		}
	}
	return OK_E
}

@(export)
buf_get_backup_name :: proc "c" (fname: cstring, dirp: ^cstring, no_prepend_dot: bool, backup_ext: cstring) -> cstring {
	context = runtime.default_context()
	backup: ^u8 = nil
	dir_len := copy_option_part(transmute(^^u8)(dirp), transmute(^u8)(&IObuff[0]), IOSIZE, cstring(","))
	p := transmute(^u8)(rawptr(uintptr(&IObuff[0]) + uintptr(dir_len)))
	if ([^]u8)(dirp^)[0] == 0 && !os_isdir(transmute(cstring)(&IObuff[0])) {
		failed_dir: cstring = nil
		ret := os_mkdir_recurse(transmute(cstring)(&IObuff[0]), 0o755, &failed_dir, nil)
		if ret != 0 {
			semsg(_t(cstring("E303: Unable to create directory \"%s\" for backup file: %s")), failed_dir, os_strerror(ret))
			xfree(rawptr(failed_dir))
		}
	}
	if dir_len > 1 && _after_pathsep(transmute(cstring)(&IObuff[0]), transmute(cstring)(p)) != 0 && ([^]u8)(rawptr(uintptr(p) - 1))[0] == ([^]u8)(rawptr(uintptr(p) - 2))[0] {
		p2 := make_percent_swname(transmute(cstring)(&IObuff[0]), transmute(cstring)(p), fname)
		if p2 != nil {
			backup = modname_e(transmute(cstring)(p2), backup_ext, no_prepend_dot)
			xfree(rawptr(p2))
		}
	}
	if backup == nil {
		rootname := get_file_in_dir(transmute(^u8)(fname), transmute(^u8)(&IObuff[0]))
		if rootname != nil {
			backup = modname_e(transmute(cstring)(rootname), backup_ext, no_prepend_dot)
			xfree(rawptr(rootname))
		}
	}
	return transmute(cstring)(backup)
}

// —— Batch B3: convert cluster ——

foreign _ {
	@(link_name = "iconv")
	iconv_e :: proc "c" (cd: rawptr, inbuf: ^cstring, inbytesleft: ^C.size_t, outbuf: ^cstring, outbytesleft: ^C.size_t) -> C.size_t ---
}

buf_write_convert_with_iconv_o :: proc "c" (ip: ^Bw_Info_O, bufp: ^cstring, lenp: ^C.int) -> C.int {
	context = runtime.default_context()
	length := C.int(lenp^)
	from := bufp^
	fromlen := C.size_t(length)
	tolen := ip.bw_conv_buflen
	to := ip.bw_conv_buf
	if ip.bw_first != 0 {
		save_len := tolen
		to_c := transmute(cstring)(to)
		// NOTE: C passes NULLs for in/out to output the shift state; the
		// literal NULL out-param needs a local (can't take & of nil).
		iconv_e(ip.bw_iconv_fd, nil, nil, &to_c, &tolen)
		to = transmute(^u8)(to_c)
		if to == nil {
			to = ip.bw_conv_buf
			tolen = save_len
		}
		ip.bw_first = 0
	}
	from_c := from
	if iconv_e(ip.bw_iconv_fd, &from_c, &fromlen, transmute(^cstring)(&to), &tolen) == ~C.size_t(0) && posix.errno() != .EINVAL {
		ip.bw_conv_error = 1
		return -1
	}
	bufp^ = transmute(cstring)(ip.bw_conv_buf)
	lenp^ = C.int(uintptr(to) - uintptr(ip.bw_conv_buf))
	return length - C.int(fromlen)
}

buf_write_convert_o :: proc "c" (ip: ^Bw_Info_O, bufp: ^cstring, lenp: ^C.int) -> C.int {
	context = runtime.default_context()
	flags := ip.bw_flags
	wlen := C.int(lenp^)
	if (flags & (FIO_UCS4_O | FIO_UTF16_O | FIO_UCS2_O | FIO_LATIN1_O)) != 0 {
		c: u32 = 0
		n: C.int = 0
		p := transmute(^u8)(bufp^)
		if (flags & FIO_LATIN1_O) != 0 {
			p = transmute(^u8)(bufp^)
		} else {
			p = ip.bw_conv_buf
		}
		wlen = 0
		for wlen < lenp^ {
			n = utf_ptr2len_len_r(transmute(cstring)(rawptr(uintptr(transmute(^u8)(bufp^)) + uintptr(wlen))), lenp^ - wlen)
			if n > lenp^ - wlen {
				break
			}
			if n > 1 {
				c = u32(utf_ptr2char(transmute(cstring)(rawptr(uintptr(transmute(^u8)(bufp^)) + uintptr(wlen)))))
			} else {
				c = u32(([^]u8)(rawptr(uintptr(transmute(^u8)(bufp^)) + uintptr(wlen)))[0])
			}
			if (flags & FIO_LATIN1_O) == 0 {
				need: C.size_t = 2
				if (flags & FIO_UCS4_O) != 0 {
					need = 4
				}
				if (flags & FIO_UTF16_O) != 0 && c >= 0x10000 {
					need = 4
				}
				if C.size_t(uintptr(p) - uintptr(ip.bw_conv_buf)) + need > ip.bw_conv_buflen {
					return FAIL_E
				}
			}
			if ucs2bytes_o(c, &p, flags) && ip.bw_conv_error == 0 {
				ip.bw_conv_error = 1
				ip.bw_conv_error_lnum = ip.bw_start_lnum
			}
			if c == u32('\n') {
				ip.bw_start_lnum += 1
			}
			wlen += n
		}
		if (flags & FIO_LATIN1_O) != 0 {
			lenp^ = C.int(uintptr(p) - uintptr(transmute(^u8)(bufp^)))
		} else {
			bufp^ = transmute(cstring)(ip.bw_conv_buf)
			lenp^ = C.int(uintptr(p) - uintptr(ip.bw_conv_buf))
		}
	}
	if ip.bw_iconv_fd != rawptr(~uintptr(0)) {
		return buf_write_convert_with_iconv_o(ip, bufp, lenp)
	}
	return wlen
}

buf_write_bytes_o :: proc "c" (ip: ^Bw_Info_O) -> C.int {
	context = runtime.default_context()
	buf := ip.bw_buf
	length := ip.bw_len
	flags := ip.bw_flags
	converted := length
	remaining: C.int = 0
	if (flags & FIO_NOCONVERT_O) == 0 {
		bp := transmute(cstring)(buf)
		lp := length
		converted = buf_write_convert_o(ip, &bp, &lp)
		if converted < 0 {
			return FAIL_E
		}
		buf = transmute(^u8)(bp)
		length = lp
		remaining = ip.bw_len - converted
	}
	ip.bw_len = remaining
	if ip.bw_fd >= 0 {
		wlen := write_eintr_e(ip.bw_fd, rawptr(buf), C.size_t(length))
		if wlen < C.ssize_t(length) {
			return FAIL_E
		}
	}
	if remaining > 0 {
		libc.memmove(rawptr(ip.bw_buf), rawptr(uintptr(ip.bw_buf) + uintptr(converted)), C.size_t(remaining))
	}
	return OK_E
}

// —— Batch B4: autocmd cluster ——

EVENT_BUFWRITECMD_O :: 19
EVENT_BUFWRITEPOST_O :: 20
EVENT_BUFWRITEPRE_O :: 21
EVENT_FILEAPPENDCMD_O :: 48
EVENT_FILEAPPENDPOST_O :: 49
EVENT_FILEAPPENDPRE_O :: 50
EVENT_FILEWRITECMD_O :: 59
EVENT_FILEWRITEPOST_O :: 60
EVENT_FILEWRITEPRE_O :: 61
EVENT_FILTERWRITEPOST_O :: 64
EVENT_FILTERWRITEPRE_O :: 65
CPO_PLUS_O :: '+'
E203_S :: "E203: Autocommands deleted or unloaded buffer to be written"
E204_S :: "E204: Autocommand changed number of lines in unexpected way"

foreign _ {
	@(link_name = "apply_autocmds_exarg")
	apply_autocmds_exarg_e :: proc "c" (event: C.int, fname: cstring, fname2: cstring, force: bool, buf: rawptr, eap: rawptr) -> bool ---
}

buf_write_do_autocmds_o :: proc "c" (buf_in: rawptr, fnamep: ^cstring, sfnamep: ^cstring, ffnamep: ^cstring, start: C.int, endp: ^C.int, eap: rawptr, append: bool, filtering: bool, reset_changed: bool, overwriting: bool, whole: bool, orig_start: Pos_T, orig_end: Pos_T) -> C.int {
	context = runtime.default_context()
	buf := buf_in
	old_line_count := (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
	msg_save := msg_scroll
	aco: [56]u8 = {}
	did_cmd := false
	nofile_err := false
	empty_memline := (^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil
	bufref: Bufref_T
	sfname := sfnamep^
	buf_ffname := ffnamep^ == transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^)
	buf_sfname := sfname == transmute(cstring)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
	buf_fname_f := fnamep^ == transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^)
	buf_fname_s := fnamep^ == transmute(cstring)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
	aucmd_prepbuf_r(rawptr(&aco[0]), buf)
	set_bufref(&bufref, buf)
	if append {
		did_cmd = apply_autocmds_exarg_e(EVENT_FILEAPPENDCMD_O, sfname, sfname, false, curbuf, eap)
		if !did_cmd {
			if overwriting && bt_nofilename(curbuf) {
				nofile_err = true
			} else {
				apply_autocmds_exarg_e(EVENT_FILEAPPENDPRE_O, sfname, sfname, false, curbuf, eap)
			}
		}
	} else if filtering {
		apply_autocmds_exarg_e(EVENT_FILTERWRITEPRE_O, nil, sfname, false, curbuf, eap)
	} else if reset_changed && whole {
		was_changed := curbufIsChanged()
		did_cmd = apply_autocmds_exarg_e(EVENT_BUFWRITECMD_O, sfname, sfname, false, curbuf, eap)
		if did_cmd {
			if was_changed && !curbufIsChanged() {
				u_unchanged(curbuf)
				u_update_save_nr(curbuf)
			}
		} else {
			if overwriting && bt_nofilename(curbuf) {
				nofile_err = true
			} else {
				apply_autocmds_exarg_e(EVENT_BUFWRITEPRE_O, sfname, sfname, false, curbuf, eap)
			}
		}
	} else {
		did_cmd = apply_autocmds_exarg_e(EVENT_FILEWRITECMD_O, sfname, sfname, false, curbuf, eap)
		if !did_cmd {
			if overwriting && bt_nofilename(curbuf) {
				nofile_err = true
			} else {
				apply_autocmds_exarg_e(EVENT_FILEWRITEPRE_O, sfname, sfname, false, curbuf, eap)
			}
		}
	}
	aucmd_restbuf_r(rawptr(&aco[0]))
	if !bufref_valid(&bufref) {
		buf = nil
	}
	if buf == nil || ((^rawptr)(uintptr(buf) + B_ML_MFP_OFF)^ == nil && !empty_memline) || did_cmd || nofile_err || aborting_r() {
		if buf != nil && (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
			op_start := (^Pos_T)(uintptr(buf) + B_OP_START)
			op_end := (^Pos_T)(uintptr(buf) + B_OP_END)
			op_start^ = orig_start
			op_end^ = orig_end
		}
		no_wait_return -= 1
		msg_scroll = msg_save
		if nofile_err {
			semsg(e_invarg2, cstring(E_NOMATCH_BT_S))
		}
		if nofile_err || aborting_r() {
			return FAIL_E
		}
		if did_cmd {
			if buf == nil {
				return OK_E
			}
			if overwriting {
				ml_timestamp(buf)
				if append {
					(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(BF_NEW_O)
				} else {
					(^C.int)(uintptr(buf) + B_FLAGS_OFF)^ &= ~C.int(BF_WRITE_MASK_O)
				}
			}
			if reset_changed && (^bool)(uintptr(buf) + B_CHANGED_OFF)^ && !append && (overwriting || vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_PLUS_O)) != nil) {
				return FAIL_E
			}
			return OK_E
		}
		if !aborting_r() {
			emsg(cstring(E203_S))
		}
		return FAIL_E
	}
	if (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ != old_line_count {
		if whole {
			endp^ = (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
		} else if (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ > old_line_count {
			endp^ += (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^ - old_line_count
		} else {
			endp^ -= old_line_count - (^C.int)(uintptr(buf) + B_ML_LINE_COUNT_OFF)^
			if endp^ < start {
				no_wait_return -= 1
				msg_scroll = msg_save
				emsg(cstring(E204_S))
				return FAIL_E
			}
		}
	}
	if buf_ffname {
		ffnamep^ = transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^)
	}
	if buf_sfname {
		sfnamep^ = transmute(cstring)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
	}
	if buf_fname_f {
		fnamep^ = transmute(cstring)((^rawptr)(uintptr(buf) + B_FFNAME)^)
	}
	if buf_fname_s {
		fnamep^ = transmute(cstring)((^rawptr)(uintptr(buf) + B_SFNAME_OFF)^)
	}
	return NOTDONE_O
}

buf_write_do_post_autocmds_o :: proc "c" (buf: rawptr, fname: cstring, eap: rawptr, append: bool, filtering: bool, reset_changed: bool, whole: bool) {
	context = runtime.default_context()
	aco: [56]u8 = {}
	aucmd_prepbuf_r(rawptr(&aco[0]), buf)
	if append {
		apply_autocmds_exarg_e(EVENT_FILEAPPENDPOST_O, fname, fname, false, curbuf, eap)
	} else if filtering {
		apply_autocmds_exarg_e(EVENT_FILTERWRITEPOST_O, nil, fname, false, curbuf, eap)
	} else if reset_changed && whole {
		apply_autocmds_exarg_e(EVENT_BUFWRITEPOST_O, fname, fname, false, curbuf, eap)
	} else {
		apply_autocmds_exarg_e(EVENT_FILEWRITEPOST_O, fname, fname, false, curbuf, eap)
	}
	aucmd_restbuf_r(rawptr(&aco[0]))
}

// —— Batch B5: backup cluster ——

kOptBkcFlagBreaksymlink_O :: 0x08
kOptBkcFlagBreakhardlink_O :: 0x10
UV_FS_COPYFILE_FICLONE_O :: 0x0002
E205_S :: "E205: Patchmode: can't save original file"
E206B_S :: "E206: Patchmode: can't touch empty original file"
E207_S :: "E207: Can't delete backup file"
E209B_S :: "E509: Cannot create backup file (add ! to override)"
E510_S :: "E510: Can't make backup file (add ! to override)"
E504B_S :: "E504: "

buf_write_make_backup_o :: proc "c" (fname: cstring, append: bool, file_info_old: ^FileInfo, acl: rawptr, perm_in: C.int, bkc: C.uint, file_readonly: bool, forceit: bool, backup_copyp: ^bool, backupp: ^cstring, err: ^Error_T) -> C.int {
	context = runtime.default_context()
	perm := perm_in
	file_info: FileInfo
	no_prepend_dot := false
	if (bkc & kOptBkcFlagYes_E) != 0 || append {
		backup_copyp^ = true
	} else if (bkc & kOptBkcFlagAuto_E) != 0 {
		if os_fileinfo_hardlinks(file_info_old) > 1 || !os_fileinfo_link(fname, &file_info) || !os_fileinfo_id_equal(&file_info, file_info_old) {
			backup_copyp^ = true
		} else {
			dirlen := C.size_t(uintptr(path_tail_e(fname)) - uintptr(transmute(^u8)(fname)))
			if dirlen >= C.size_t(MAXPATHL_O) {
				libc.abort()
			}
			tmp_fname: [4096]u8
			xmemcpyz(rawptr(&tmp_fname[0]), rawptr(transmute(^u8)(fname)), dirlen)
			i: C.int = 4913
			for {
				found := false
				libc.snprintf(transmute(^u8)(rawptr(uintptr(&tmp_fname[0]) + uintptr(dirlen))), C.size_t(MAXPATHL_O) - dirlen, cstring("%d"), i)
				if !os_fileinfo_link(transmute(cstring)(&tmp_fname[0]), &file_info) {
					found = true
				}
				if found {
					break
				}
				i += 123
			}
			oflags: C.int = 0
			oflags |= posix.O_CREAT | posix.O_WRONLY | posix.O_EXCL | posix.O_NOFOLLOW
			fd := os_open(transmute(cstring)(&tmp_fname[0]), oflags, perm)
			if fd < 0 {
				backup_copyp^ = true
			} else {
				_ = os_fchown(fd, C.int(file_info_old.stat.st_uid), C.int(file_info_old.stat.st_gid))
				if !os_fileinfo(transmute(cstring)(&tmp_fname[0]), &file_info) || file_info.stat.st_uid != file_info_old.stat.st_uid || file_info.stat.st_gid != file_info_old.stat.st_gid || C.int(file_info.stat.st_mode) != perm {
					backup_copyp^ = true
				}
				linux.close(linux.Fd(fd))
				os_remove(transmute(cstring)(&tmp_fname[0]))
			}
		}
	}
	if (bkc & kOptBkcFlagBreaksymlink_O) != 0 || (bkc & kOptBkcFlagBreakhardlink_O) != 0 {
		file_info_link_ok := os_fileinfo_link(fname, &file_info)
		if (bkc & kOptBkcFlagBreaksymlink_O) != 0 && file_info_link_ok && !os_fileinfo_id_equal(&file_info, file_info_old) {
			backup_copyp^ = false
		}
		if (bkc & kOptBkcFlagBreakhardlink_O) != 0 && os_fileinfo_hardlinks(file_info_old) > 1 && (!file_info_link_ok || os_fileinfo_id_equal(&file_info, file_info_old)) {
			backup_copyp^ = false
		}
	}
	backup_ext := cstring(".bak")
	if ([^]u8)(p_bex_g)[0] != 0 {
		backup_ext = transmute(cstring)(p_bex_g)
	}
	if backup_copyp^ {
		some_error := false
		dirp := transmute(cstring)(p_bdir_opt)
		for ([^]u8)(transmute(^u8)(dirp))[0] != 0 {
			file_info_new: FileInfo
			backupp^ = buf_get_backup_name(fname, &dirp, no_prepend_dot, backup_ext)
			if backupp^ == nil {
				some_error = true
				break
			}
			if os_fileinfo(backupp^, &file_info_new) {
				if os_fileinfo_id_equal(&file_info_new, file_info_old) {
					xfree(rawptr(backupp^))
					backupp^ = nil
				} else if p_bk == 0 {
					wp := transmute(^u8)(rawptr(uintptr(transmute(^u8)(backupp^)) + uintptr(libc.strlen(backupp^)) - 1 - uintptr(libc.strlen(backup_ext))))
					if uintptr(wp) < uintptr(transmute(^u8)(backupp^)) {
						wp = transmute(^u8)(backupp^)
					}
					([^]u8)(wp)[0] = 'z'
					for ([^]u8)(wp)[0] > 'a' && os_fileinfo(backupp^, &file_info_new) {
						([^]u8)(wp)[0] -= 1
					}
					if ([^]u8)(wp)[0] == 'a' {
						xfree(rawptr(backupp^))
						backupp^ = nil
					}
				}
			}
			if backupp^ != nil {
				os_remove(backupp^)
				if os_copy(fname, backupp^, UV_FS_COPYFILE_FICLONE_O) != 0 {
					err^ = set_err_o(_t(cstring(E209B_S)))
					xfree(rawptr(backupp^))
					backupp^ = nil
					break
				}
				os_setperm(backupp^, perm & 0o777)
				if file_info_new.stat.st_gid != file_info_old.stat.st_gid && os_chown(backupp^, transmute(C.int)(u32(0xffffffff)), C.int(file_info_old.stat.st_gid)) != 0 {
					os_setperm(backupp^, (perm & 0o707) | ((perm & 0o7) << 3))
				}
				os_file_settime(backupp^, f64(file_info_old.stat.st_atim.tv_sec), f64(file_info_old.stat.st_mtim.tv_sec))
				os_set_acl(backupp^, acl)
				os_copy_xattr(fname, backupp^)
				err^ = set_err_o(nil)
				break
			}
		}
		if backupp^ == nil && err.msg == nil {
			err^ = set_err_o(_t(cstring(E209B_S)))
		}
		if (some_error || err.msg != nil) && !forceit {
			return FAIL_E
		}
		err^ = set_err_o(nil)
	} else {
		if file_readonly && vim_strchr(transmute(cstring)(p_cpo), C.int(CPO_FWRITE_O)) != nil {
			err^ = set_err_num_o(cstring("E504"), _t(cstring(E_READONLY_S)))
			return FAIL_E
		}
		dirp := transmute(cstring)(p_bdir_opt)
		for ([^]u8)(transmute(^u8)(dirp))[0] != 0 {
			backupp^ = buf_get_backup_name(fname, &dirp, no_prepend_dot, backup_ext)
			if backupp^ != nil {
				if p_bk == 0 && os_path_exists(backupp^) {
					p := transmute(^u8)(rawptr(uintptr(transmute(^u8)(backupp^)) + uintptr(libc.strlen(backupp^)) - 1 - uintptr(libc.strlen(backup_ext))))
					if uintptr(p) < uintptr(transmute(^u8)(backupp^)) {
						p = transmute(^u8)(backupp^)
					}
					([^]u8)(p)[0] = 'z'
					for ([^]u8)(p)[0] > 'a' && os_path_exists(backupp^) {
						([^]u8)(p)[0] -= 1
					}
					if ([^]u8)(p)[0] == 'a' {
						xfree(rawptr(backupp^))
						backupp^ = nil
					}
				}
			}
			if backupp^ != nil {
				os_remove(backupp^)
				if vim_rename_e(fname, backupp^) == 0 {
					break
				}
				xfree(rawptr(backupp^))
				backupp^ = nil
			}
		}
		if backupp^ == nil && !forceit {
			err^ = set_err_o(_t(cstring(E510_S)))
			return FAIL_E
		}
	}
	return OK_E
}
