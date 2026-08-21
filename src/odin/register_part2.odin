// register.odin part 2 — do_put, :registers display, get_reg_contents, write_reg_*
// Continues register_part1.odin (same package).

package main

import C "core:c"
import "core:c/libc"

@(private="file")
get_pos_r :: #force_inline proc "c"(base: rawptr, off: uintptr) -> ^Pos_T {
	return (^Pos_T)(uintptr(base) + off)
}


@(private="file")
cargv_at :: #force_inline proc "c"(p: ^rawptr, i: C.size_t) -> ^u8 {
	return (^u8)((^rawptr)(uintptr(p) + uintptr(i) * size_of(rawptr))^)
}

foreign _ {
	@(link_name = "beep_flush")
	beep_flush_r2 :: proc "c" () ---
	@(link_name = "get_last_insert_save")
	get_last_insert_save_r2 :: proc "c" () -> ^u8 ---
	@(link_name = "buf_is_empty")
	buf_is_empty_r :: proc "c" (buf: rawptr) -> bool ---
	@(link_name = "ml_get_len")
	ml_get_len_r2 :: proc "c" (lnum: C.int) -> C.int ---
}

@(private="file")
_beep_flush :: proc "c"() {
	beep_flush_r2()
}

@(private="file")
_get_last_insert_save :: proc "c"() -> ^u8 {
	return get_last_insert_save_r2()
}

// ── do_put ───────────────────────────────────────────────────────────────────

/// Put contents of register "regname" into the text.
@(export)
do_put :: proc "c" (regname: C.int, reg_arg: ^Yankreg_T, dir_arg: C.int, count_arg: C.int, flags: C.int) {
	reg := reg_arg
	dir := dir_arg
	count := count_arg
	totlen: C.size_t = 0
	lnum: C.int = 0
	y_type: C.int
	y_size: C.size_t = 0
	y_width: C.int = 0
	vcol: C.int = 0
	y_array: [^]Str16 = nil
	nr_lines: C.int = 0
	allocated := false
	orig_start := get_pos_r(curbuf, B_OP_START)^
	orig_end := get_pos_r(curbuf, B_OP_END)^
	cur_ve_flags := get_ve_flags_r(curwin)

	cursor_pos :: #force_inline proc "c"() -> ^Pos_T {
		return (^Pos_T)(uintptr(curwin) + W_CURSOR)
	}
	op_start :: #force_inline proc "c"() -> ^Pos_T {
		return get_pos_r(curbuf, B_OP_START)
	}
	op_end :: #force_inline proc "c"() -> ^Pos_T {
		return get_pos_r(curbuf, B_OP_END)
	}

	// Remove any preinserted text
	if ins_compl_preinsert_effect_r() {
		ins_compl_delete_r(false)
	}

	op_start()^ = cursor_pos()^ // default for '[ mark
	op_end()^ = cursor_pos()^ // default for '] mark

	done := false // goto-end flag

	// Using inserted text works differently.
	if regname == '.' && reg == nil {
		non_linewise_vis := VIsual_active && VIsual_mode != 'V'

		command_start_char: rune = non_linewise_vis ? 'c' : ((flags & PUT_LINE) != 0 ? 'i' : (dir == FORWARD_DIR ? 'a' : 'i'))

		has_textput_events := has_event(EVENT_TEXTPUTPRE) || has_event(EVENT_TEXTPUTPOST)
		if has_textput_events {
			add_last_insert += 1
		}

		// To avoid 'autoindent' on linewise puts, create a new line with `:put _`.
		if (flags & PUT_LINE) != 0 {
			save_add_last_insert := add_last_insert
			add_last_insert = 0
			stuffcharReadbuff_r(K_COMMAND)
			if dir == FORWARD_DIR {
				stuffReadbuffLen_r(cstring("put _"), 5)
			} else {
				stuffReadbuffLen_r(cstring("put! _"), 6)
			}
			stuffcharReadbuff_r(C.int(CAR))
			add_last_insert = save_add_last_insert
		}

		if (flags & PUT_LINE) != 0 {
			stuffcharReadbuff_r(C.int(command_start_char))
			for count > 0 {
				stuff_inserted_r(0, 1, count != 1)
				count -= 1
				if count != 1 {
					s: [4]u8 = {'\n', ' ', Ctrl_U, 0}
					stuffReadbuffLen_r(transmute(cstring)(&s[0]), 3)
				}
			}
		} else {
			stuff_inserted_r(C.int(command_start_char), count, false)
		}

		// Text inserted later; fire TextPutPre/Post now.
		if has_event(EVENT_TEXTPUTPRE) {
			put_do_autocmd('.', nil, nil, false, dir)
		}
		if has_event(EVENT_TEXTPUTPOST) {
			put_do_autocmd('.', nil, nil, true, dir)
		}

		if has_textput_events {
			add_last_insert -= 1
			if add_last_insert == 0 {
				ga_clear_r(&last_insert_ga)
			}
		}

		// Simulate cursor-to-next-char motion after the insert.
		if (flags & PUT_CURSEND) != 0 {
			if (flags & PUT_LINE) != 0 {
				stuffReadbuff_r(cstring("j0"))
			} else {
				cp := get_cursor_pos_ptr_r()
				one_past_line := cp^ == 0
				eol := false
				if !one_past_line {
					eol = (^u8)(uintptr(cp) + uintptr(utfc_ptr2len(transmute(cstring)(cp))))^ == 0
				}

				ve_allows := cur_ve_flags == kOptVeFlagAll_V || cur_ve_flags == kOptVeFlagOnemore_V
				eof := get_i32_off(curbuf, B_ML_LINE_COUNT) == cursor_pos().lnum && one_past_line
				if ve_allows || !(eol || eof) {
					stuffcharReadbuff_r('l')
				}
			}
		} else if (flags & PUT_LINE) != 0 {
			stuffReadbuff_r(cstring("g'["))
		}

		// Save cursor position for ".p undo.
		if command_start_char == 'a' {
			if u_save_r(cursor_pos().lnum, cursor_pos().lnum + 1) == FAIL_R {
				return
			}
		}
		return
	}

	// For special registers create a fake yank register.
	insert_string: Str16
	if reg == nil && get_spec_reg(regname, &insert_string.data, &allocated, true) {
		if insert_string.data == nil {
			return
		}
	}

	if buf_read_ptr(curbuf, B_TERMINAL) == nil {
		// start undo now to avoid autocommand invalidating y_array
		if u_save_r(cursor_pos().lnum, cursor_pos().lnum + 1) == FAIL_R {
			return
		}
	}

	if insert_string.data != nil {
		insert_string.size = libc.strlen(transmute(cstring)(insert_string.data))
		y_type = kMTCharWise
		if regname == '=' {
			// split the string at NL characters; loop twice (count then fill)
			for true {
				y_size = 0
				ptr := insert_string.data
				ptrlen := insert_string.size
				for ptr != nil {
					if y_array != nil {
						y_array[y_size].data = ptr
					}
					y_size += 1
					tmp := transmute(^u8)(_vim_strchr(transmute(cstring)(ptr), 10))
					if tmp == nil {
						if y_array != nil {
							y_array[y_size - 1].size = ptrlen
						}
					} else {
						if y_array != nil {
							tmp^ = 0
							y_array[y_size - 1].size = C.size_t(uintptr(tmp) - uintptr(ptr))
							ptrlen -= y_array[y_size - 1].size + 1
						}
						tmp = (^u8)(uintptr(tmp) + 1)
						// A trailing '\n' makes the register linewise.
						if tmp^ == 0 {
							y_type = kMTLineWise
							break
						}
					}
					ptr = tmp
				}
				if y_array != nil {
					break
				}
				y_array = transmute([^]Str16)(xmalloc(C.size_t(y_size) * size_of(Str16)))
			}
		} else {
			y_size = 1 // use fake one-line yank register
			y_array = transmute([^]Str16)(&insert_string)
		}
		if has_event(EVENT_TEXTPUTPRE) {
			put_do_autocmd(regname, nil, &insert_string, false, dir)
		}
	} else {
		if has_event(EVENT_TEXTPUTPRE) {
			save_reg := reg
			if reg == nil {
				reg = get_yank_register(regname, YREG_PASTE)
			}
			put_do_autocmd(regname, reg, nil, false, dir)
			reg = save_reg
		}
		if reg == nil {
			reg = get_yank_register(regname, YREG_PASTE)
		}

		y_type = reg.y_type
		y_width = reg.y_width
		y_size = reg.y_size
		y_array = reg.y_array
	}

	if buf_read_ptr(curbuf, B_TERMINAL) != nil {
		terminal_paste_r(count, y_array, y_size)
		done = true
	} else {

		split_pos: C.int = 0
		if y_type == kMTLineWise {
			if (flags & PUT_LINE_SPLIT) != 0 {
				// "p"/"P" in Visual mode: split lines to put text between.
				if u_save_cursor_r() == FAIL_R {
					done = true
				}
				if !done {
					curline := get_cursor_line_ptr_r()
					p := get_cursor_pos_ptr_r()
					p_orig := p
					plen := C.size_t(get_cursor_pos_len_r())
					if dir == FORWARD_DIR && p^ != 0 {
						p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
					}
					// needed later for extmark_splice()
					split_pos = C.int(uintptr(p) - uintptr(curline))

					ptr := xmemdupz(p, plen - C.size_t(uintptr(p) - uintptr(p_orig)))
					ml_append_c(cursor_pos().lnum, ptr, 0, false)
					xfree(ptr)

					ptr = xmemdupz(get_cursor_line_ptr_r(), C.size_t(split_pos))
					ml_replace_c(cursor_pos().lnum, ptr, false)
					nr_lines += 1
					dir = FORWARD_DIR

					buf_updates_send_changes_r(curbuf, cursor_pos().lnum, 1, 1)
				}
			}
			if (flags & PUT_LINE_FORWARD) != 0 && !done {
				// Must be "p" for a Visual block: put lines below the block.
				cursor_pos()^ = get_pos_r(curbuf, B_VISUAL + 12)^
				dir = FORWARD_DIR
			}
			if !done {
				op_start()^ = cursor_pos()^
				op_end()^ = cursor_pos()^
			}
		}

		if !done {
			if (flags & PUT_LINE) != 0 { // ":put" or "p" in Visual line mode.
				y_type = kMTLineWise
			}

			if y_size == 0 || y_array == nil {
				semsg_fmt(cstring("E353: Nothing in register %s"),
					regname == 0 ? transmute(rawptr)(cstring("\"")) : transmute(rawptr)(transchar_r(regname)))
				done = true
			}
		}

		Block: if !done {
			if y_type == kMTBlockWise {
				lnum = cursor_pos().lnum + C.int(y_size) + 1
				lnum = min(lnum, get_i32_off(curbuf, B_ML_LINE_COUNT) + 1)
				if u_save_r(cursor_pos().lnum - 1, lnum) == FAIL_R {
					break Block
				}
			} else if y_type == kMTLineWise {
				lnum = cursor_pos().lnum
				// Correct line number for closed fold.
				if dir == BACKWARD_DIR {
					hasFolding(curwin, lnum, &lnum, nil)
				} else {
					hasFolding(curwin, lnum, nil, &lnum)
				}
				if dir == FORWARD_DIR {
					lnum += 1
				}
				// In an empty buffer the empty line is replaced; include it.
				if (buf_is_empty_r(curbuf) ? u_save_r(0, 2) : u_save_r(lnum - 1, lnum)) == FAIL_R {
					break Block
				}
				if dir == FORWARD_DIR {
					cursor_pos().lnum = lnum - 1
				} else {
					cursor_pos().lnum = lnum
				}
				op_start()^ = cursor_pos()^ // for mark_adjust()
			} else if u_save_cursor_r() == FAIL_R {
				break Block
			}

			if cur_ve_flags == kOptVeFlagAll_V && y_type == kMTCharWise {
				if gchar_cursor_r() == '\t' {
					viscol := getviscol_r()
					ts := (^i64)(uintptr(curbuf) + B_P_TS)^
					// Don't insert spaces when "p" on last pos of tab / "P" on first.
					if (dir == FORWARD_DIR ? tabstop_padding_r(viscol, ts, (^C.int)(uintptr(curbuf) + B_P_VTS_ARRAY)) != 1 : cursor_pos().coladd > 0) {
						coladvance_force_r(viscol)
					} else {
						cursor_pos().coladd = 0
					}
				} else if cursor_pos().coladd > 0 || gchar_cursor_r() == 0 {
					coladvance_force_r(getviscol_r() + (dir == FORWARD_DIR ? 1 : 0))
				}
			}

			lnum = cursor_pos().lnum
			col := cursor_pos().col

			// Block mode
			if y_type == kMTBlockWise {
				incr: C.int = 0
				bd: Block_Def
				c := gchar_cursor_r()
				endcol2: C.int = 0

				if dir == FORWARD_DIR && c != 0 {
					if cur_ve_flags == kOptVeFlagAll_V {
						getvcol_r(curwin, cursor_pos(), &col, nil, &endcol2, 0)
					} else {
						getvcol_r(curwin, cursor_pos(), nil, nil, &col, 0)
					}

					// move to start of next multi-byte character
					cursor_pos().col += C.int(utfc_ptr2len(transmute(cstring)(get_cursor_pos_ptr_r())))
					col += 1
				} else {
					getvcol_r(curwin, cursor_pos(), &col, nil, &endcol2, 0)
				}

				col += cursor_pos().coladd
				if cur_ve_flags == kOptVeFlagAll_V &&
					(cursor_pos().coladd > 0 || endcol2 == cursor_pos().col) {
					if dir == FORWARD_DIR && c == 0 {
						col += 1
					}
					if dir != FORWARD_DIR && c != 0 && cursor_pos().coladd > 0 {
						cursor_pos().col += 1
					}
					if c == '\t' {
						if dir == BACKWARD_DIR && cursor_pos().col != 0 {
							cursor_pos().col -= 1
						}
						if dir == FORWARD_DIR && col - 1 == endcol2 {
							cursor_pos().col += 1
						}
					}
				}
				cursor_pos().coladd = 0
				bd.textcol = 0
				for i: C.size_t = 0; i < y_size; i += 1 {
					spaces: C.int = 0
					shortline: u8
					// can just be 0 or 1, needed past buffer end
					lines_appended: C.int = 0

					bd.startspaces = 0
					bd.endspaces = 0
					vcol = 0
					delcount: C.int = 0

					// add a new line
					if cursor_pos().lnum > get_i32_off(curbuf, B_ML_LINE_COUNT) {
						if !ml_append_c(get_i32_off(curbuf, B_ML_LINE_COUNT), transmute(^u8)(cstring("")), 1, false) {
							break
						}
						nr_lines += 1
						lines_appended = 1
					}
					// advance to the position to insert at
					oldp := get_cursor_line_ptr_r()
					oldlen := get_cursor_line_len_r()

					p := oldp
					vcol = 0
					for vcol < col && p^ != 0 {
						incr = win_chartabsize_r(curwin, p, vcol)
						vcol += incr
						p = (^u8)(uintptr(p) + uintptr(utfc_ptr2len(transmute(cstring)(p))))
					}
					ptr := p
					bd.textcol = C.int(uintptr(ptr) - uintptr(oldp))

					shortline = (vcol < col) || (vcol == col && ptr^ == 0) ? 1 : 0

					if vcol < col { // line too short, pad with spaces
						bd.startspaces = col - vcol
					} else if vcol > col {
						bd.endspaces = vcol - col
						bd.startspaces = incr - bd.endspaces
						bd.textcol -= 1
						delcount = 1
						bd.textcol -= utf_head_off(transmute(cstring)(oldp),
							transmute(cstring)((^u8)(uintptr(oldp) + uintptr(bd.textcol))))
						if ((^u8)(uintptr(oldp) + uintptr(bd.textcol)))^ != '\t' {
							// Only a Tab can be split into spaces.
							delcount = 0
							bd.endspaces = 0
						}
					}

					yanklen := C.int(y_array[i].size)

					if (flags & PUT_BLOCK_INNER) == 0 {
						// spaces required to fill right side of block
						spaces = y_width + 1

						q := y_array[i].data
						for q^ != 0 {
							spaces -= win_chartabsize_r(curwin, q, 0)
							q = (^u8)(uintptr(q) + uintptr(utfc_ptr2len(transmute(cstring)(q))))
						}
						spaces = max(spaces, 0)
					}

					// check for multiplication overflow
					if yanklen + spaces != 0 &&
						count > (2147483647 - (bd.startspaces + bd.endspaces)) / (yanklen + spaces) {
						emsg(_t(e_resulting_text_too_long))
						break
					}

					totlen = C.size_t(count) * C.size_t(yanklen + spaces) +
						C.size_t(bd.startspaces) + C.size_t(bd.endspaces)
					newp := (^u8)(xmalloc(totlen + C.size_t(oldlen) + 1))

					// copy part up to cursor to new line
					ptr = newp
					libc.memmove(ptr, oldp, C.size_t(bd.textcol))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.textcol))

					// may insert some spaces before the new text
					libc.memset(ptr, ' ', C.size_t(bd.startspaces))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.startspaces))

					// insert the new text
					j: C.int = 0
					for j < count {
						libc.memmove(ptr, y_array[i].data, C.size_t(yanklen))
						ptr = (^u8)(uintptr(ptr) + uintptr(yanklen))

						// trailing spaces only if there's text behind
						if (j < count - 1 || shortline == 0) && spaces > 0 {
							libc.memset(ptr, ' ', C.size_t(spaces))
							ptr = (^u8)(uintptr(ptr) + uintptr(spaces))
						} else {
							totlen -= C.size_t(spaces) // didn't use these spaces
						}
						j += 1
					}

					// may insert some spaces after the new text
					libc.memset(ptr, ' ', C.size_t(bd.endspaces))
					ptr = (^u8)(uintptr(ptr) + uintptr(bd.endspaces))

					// move the text after the cursor to end of line
					columns := oldlen - bd.textcol - delcount + 1
					libc.memmove(ptr, (^u8)(uintptr(oldp) + uintptr(bd.textcol + delcount)), C.size_t(columns))
					ml_replace_c(cursor_pos().lnum, newp, false)
					extmark_splice_cols_r(curbuf, cursor_pos().lnum - 1, bd.textcol,
						delcount, C.int(totlen) + lines_appended, kExtmarkUndo)

					cursor_pos().lnum += 1
					if i == 0 {
						cursor_pos().col += bd.startspaces
					}
				}

				changed_lines_r(curbuf, lnum, 0,
					op_start().lnum + C.int(y_size) - nr_lines, nr_lines, true)

				// Set '[ mark.
				op_start()^ = cursor_pos()^
				op_start().lnum = lnum

				// adjust '] mark
				op_end().lnum = cursor_pos().lnum - 1
				op_end().col = max(bd.textcol + C.int(totlen) - 1, 0)
				op_end().coladd = 0
				if (flags & PUT_CURSEND) != 0 {
					cursor_pos()^ = op_end()^
					cursor_pos().col += 1

					// in Insert mode we might be after the NUL
					len := get_cursor_line_len_r()
					cursor_pos().col = min(cursor_pos().col, len)
				} else {
					cursor_pos().lnum = lnum
				}
			} else {
				yanklen := C.int(y_array[0].size)

				// Character or Line mode
				if y_type == kMTCharWise {
					// FORWARD is BACKWARD on the next char
					if dir == FORWARD_DIR && gchar_cursor_r() != 0 {
						bytelen := C.int(utfc_ptr2len(transmute(cstring)(get_cursor_pos_ptr_r())))

						col += bytelen
						if yanklen != 0 {
							cursor_pos().col += bytelen
							op_end().col += bytelen
						}
					}
					op_start()^ = cursor_pos()^
				} else if dir == BACKWARD_DIR {
					// Line mode: BACKWARD is FORWARD on previous line
					lnum -= 1
				}
				new_cursor := cursor_pos()^

				// simple case: insert into one line at a time
				if y_type == kMTCharWise && y_size == 1 {
					end_lnum: C.int = 0
					start_lnum := lnum
					first_byte_off: C.int = 0

					if VIsual_active {
						end_lnum = max(get_pos_r(curbuf, B_VISUAL + 12).lnum, get_pos_r(curbuf, B_VISUAL).lnum)
						if end_lnum > start_lnum {
							pos := Pos_T{lnum = lnum, col = col, coladd = 0}
							getvcol_r(curwin, &pos, nil, &vcol, nil, 0)
						}
					}

					if count == 0 || yanklen == 0 {
						if VIsual_active {
							lnum = end_lnum
						}
					} else if count > 2147483647 / yanklen {
						// multiplication overflow
						emsg(_t(e_resulting_text_too_long))
					} else {
						totlen = C.size_t(count) * C.size_t(yanklen)
						for true {
							oldp := ml_get(lnum)
							oldlen := ml_get_len_r2(lnum)
							if lnum > start_lnum {
								pos := Pos_T{lnum = lnum}
								if getvpos_r(curwin, &pos, vcol) == OK_R {
									col = pos.col
								} else {
									col = MAXCOL
								}
							}
							if VIsual_active && col > oldlen {
								lnum += 1
								continue
							}
							newp := (^u8)(xmalloc(totlen + C.size_t(oldlen) + 1))
							libc.memmove(newp, oldp, C.size_t(col))
							ptr := (^u8)(uintptr(newp) + uintptr(col))
							i: C.size_t = 0
							for i < C.size_t(count) {
								libc.memmove(ptr, y_array[0].data, C.size_t(yanklen))
								ptr = (^u8)(uintptr(ptr) + uintptr(yanklen))
								i += 1
							}
							libc.memmove(ptr, (^u8)(uintptr(oldp) + uintptr(col)), C.size_t(oldlen - col) + 1) // +1 NUL
							ml_replace_c(lnum, newp, false)

							// byte offset of last character
							first_byte_off = utf_head_off(transmute(cstring)(newp), transmute(cstring)((^u8)(uintptr(ptr) - 1)))

							// Place cursor on last putted char.
							if lnum == cursor_pos().lnum {
								changed_cline_bef_curs_r(curwin)
								invalidate_botline_win_r(curwin)
								cursor_pos().col += C.int(totlen) - 1
							}
							changed_bytes_r(lnum, col)
							extmark_splice_cols_r(curbuf, lnum - 1, col, 0, C.int(totlen), kExtmarkUndo)
							if VIsual_active {
								lnum += 1
							}
							if !(VIsual_active && lnum <= end_lnum) {
								break
							}
						}

						if VIsual_active { // reset lnum to last visual line
							lnum -= 1
						}
					}

					// put '] at first byte of last character
					op_end()^ = cursor_pos()^
					op_end().col -= first_byte_off

					// CTRL-O p in Insert mode: cursor after last char
					if totlen != 0 && (restart_edit != 0 || (flags & PUT_CURSEND) != 0) {
						cursor_pos().col += 1
					} else {
						cursor_pos().col -= first_byte_off
					}
				} else {
					new_lnum := new_cursor.lnum
					indent: C.int
					orig_indent: C.int = 0
					indent_diff: C.int = 0
					first_indent := true
					lendiff: C.int = 0

					if (flags & PUT_FIXINDENT) != 0 {
						orig_indent = get_indent_r()
					}

					cnt: C.int = 1
					for cnt <= count {
						i: C.size_t = 0
						if y_type == kMTCharWise {
							// Split current line in two at insert position.
							lnum = new_cursor.lnum
							srcptr := (^u8)(uintptr(ml_get(lnum)) + uintptr(col))
							ptrlen := C.size_t(ml_get_len_r2(lnum)) - C.size_t(col)
							totlen = y_array[y_size - 1].size
							newp := (^u8)(xmalloc(ptrlen + totlen + 1))
							libc.memcpy(newp, y_array[y_size - 1].data, totlen)
							libc.memcpy((^u8)(uintptr(newp) + uintptr(totlen)), srcptr, ptrlen + 1)
							ml_append_c(lnum, newp, 0, false)
							new_lnum += 1
							xfree(newp)

							oldp := ml_get(lnum)
							newp2 := (^u8)(xmalloc(C.size_t(col) + C.size_t(yanklen) + 1))
							libc.memmove(newp2, oldp, C.size_t(col))
							libc.memmove((^u8)(uintptr(newp2) + uintptr(col)), y_array[0].data, C.size_t(yanklen) + 1)
							ml_replace_c(lnum, newp2, false)

							cursor_pos().lnum = lnum
							i = 1
						}

						mfailed := false
						for i < y_size {
							if y_type != kMTCharWise || i < y_size - 1 {
								if !ml_append_c(lnum, y_array[i].data, 0, false) {
									mfailed = true
									break
								}
								new_lnum += 1
							}
							lnum += 1
							nr_lines += 1
							if (flags & PUT_FIXINDENT) != 0 {
								old_pos := cursor_pos()^
								cursor_pos().lnum = lnum
								ptr := ml_get(lnum)
								if cnt == count && i == y_size - 1 {
									lendiff = ml_get_len_r2(lnum)
								}
								if ptr^ == '#' && preprocs_left_r() {
									indent = 0 // Leave # lines at start
								} else if ptr^ == 0 {
									indent = 0 // Ignore empty lines
								} else if first_indent {
									indent_diff = orig_indent - get_indent_r()
									indent = orig_indent
									first_indent = false
								} else {
									indent = get_indent_r() + indent_diff
									if indent < 0 {
										indent = 0
									}
								}
								set_indent_r(indent, SIN_NOMARK)
								cursor_pos()^ = old_pos
								// remember how many chars were removed
								if cnt == count && i == y_size - 1 {
									lendiff -= ml_get_len_r2(lnum)
								}
							}
							i += 1
						}

						if !mfailed {
							totsize: i64 = 0
							lastsize: C.int = 0
							if y_type == kMTCharWise ||
								(y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) != 0) {
								k: C.size_t = 0
								for k < y_size - 1 {
									totsize += i64(y_array[k].size) + 1
									k += 1
								}
								lastsize = C.int(y_array[y_size - 1].size)
								totsize += i64(lastsize)
							}
							if y_type == kMTCharWise {
								extmark_splice_r(curbuf, new_cursor.lnum - 1, col, 0, 0, 0,
									C.int(y_size) - 1, lastsize, totsize, kExtmarkUndo)
							} else if y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) != 0 {
								// Account for last pasted NL + last NL
								extmark_splice_r(curbuf, new_cursor.lnum - 1, split_pos, 0, 0, 0,
									C.int(y_size) + 1, 0, totsize + 2, kExtmarkUndo)
							}

							if cnt == 1 {
								new_lnum = lnum
							}
						}
						cnt += 1
					}

					// Adjust marks.
					if y_type == kMTLineWise {
						op_start().col = 0
						if dir == FORWARD_DIR {
							op_start().lnum += 1
						}
					}

					kind: C.int = (y_type == kMTLineWise && (flags & PUT_LINE_SPLIT) == 0) ? kExtmarkUndo : kExtmarkNOOP
					mark_adjust(op_start().lnum + (y_type == kMTCharWise ? 1 : 0),
						MAXLNUM, nr_lines, 0, kind)

					// note changed text for displaying and folding
					if y_type == kMTCharWise {
						changed_lines_r(curbuf, cursor_pos().lnum, col,
							cursor_pos().lnum + 1, nr_lines, true)
					} else {
						changed_lines_r(curbuf, op_start().lnum, 0,
							op_start().lnum, nr_lines, true)
					}

					// Put '] mark on first byte of last inserted character.
					op_end().lnum = new_lnum
					col = max(0, C.int(y_array[y_size - 1].size) - lendiff)
					if col > 1 {
						op_end().col = col - 1
						if y_array[y_size - 1].size > 0 {
							op_end().col -= utf_head_off(
								transmute(cstring)(y_array[y_size - 1].data),
								transmute(cstring)((^u8)(uintptr(y_array[y_size - 1].data) + uintptr(y_array[y_size - 1].size - 1))))
						}
					} else {
						op_end().col = 0
					}

					if (flags & PUT_CURSLINE) != 0 {
						// ":put": cursor on last inserted line
						cursor_pos().lnum = lnum
						beginline(BL_WHITE | BL_FIX)
					} else if (flags & PUT_CURSEND) != 0 {
						// cursor after inserted text
						if y_type == kMTLineWise {
							if lnum >= get_i32_off(curbuf, B_ML_LINE_COUNT) {
								cursor_pos().lnum = get_i32_off(curbuf, B_ML_LINE_COUNT)
							} else {
								cursor_pos().lnum = lnum + 1
							}
							cursor_pos().col = 0
						} else {
							cursor_pos().lnum = new_lnum
							cursor_pos().col = col
							op_end()^ = cursor_pos()^
							if col > 1 {
								op_end().col = col - 1
							}
						}
					} else if y_type == kMTLineWise {
						// cursor on first non-blank of first inserted line
						cursor_pos().col = 0
						if dir == FORWARD_DIR {
							cursor_pos().lnum += 1
						}
						beginline(BL_WHITE | BL_FIX)
					} else { // cursor on first inserted character
						cursor_pos()^ = new_cursor
					}
				}
			}

			msgmore_r(nr_lines)
			set_i32_off(curwin, W_SET_CURSWANT, 1)

			// Make sure cursor is not after the NUL.
			len := get_cursor_line_len_r()
			if cursor_pos().col > len {
				if cur_ve_flags == kOptVeFlagAll_V {
					cursor_pos().coladd = cursor_pos().col - len
				}
				cursor_pos().col = len
			}
		} // Block:
	} // !terminal

	// end:
	if (cmdmod_cmod_flags & CMOD_LOCKMARKS) != 0 {
		get_pos_r(curbuf, B_OP_START)^ = orig_start
		get_pos_r(curbuf, B_OP_END)^ = orig_end
	}

	if has_event(EVENT_TEXTPUTPOST) {
		if insert_string.data == nil {
			put_do_autocmd(regname, reg, nil, true, dir)
		} else {
			put_do_autocmd(regname, nil, &insert_string, true, dir)
		}
	}

	if allocated {
		xfree(insert_string.data)
	}
	if regname == '=' {
		xfree(y_array)
	}

	if buf_read_ptr(curbuf, B_TERMINAL) == nil {
		VIsual_active = false
	}

	// If cursor is past EOL put it at the end.
	adjust_cursor_eol_r()
}

kOptVeFlagAll_V :: 0x04
kOptVeFlagOnemore_V :: 0x08

/// display a string for do_dis(); truncate at end of screen line
@(private="file")
dis_msg :: proc "c"(p_arg: ^u8, skip_esc: bool) {
	p := p_arg
	n := Columns - 6
	for p^ != 0 &&
	!(p^ == 27 && skip_esc && (^u8)(uintptr(p) + 1)^ == 0) {
		cell := ptr2cells(transmute(cstring)(p))
		if n-cell < 0 {
			break
		}
		n -= cell
		l := utfc_ptr2len(transmute(cstring)(p))
		if l > 1 {
			msg_outtrans_len_r(transmute(cstring)(p), l, 0, false)
			p = (^u8)(uintptr(p) + uintptr(l))
		} else {
			msg_outtrans_len_r(transmute(cstring)(p), 1, 0, false)
			p = (^u8)(uintptr(p) + 1)
		}
	}
	os_breakcheck()
}

foreign _ {
	@(link_name = "msg_outtrans_len")
	msg_outtrans_len_r :: proc "c" (msgstr: cstring, len: C.int, hl_id: C.int, hist: bool) ---
	@(link_name = "msg_puts_hl")
	msg_puts_hl_r :: proc "c" (s: cstring, hl_id: C.int, hist: bool) ---
	@(link_name = "get_last_insert")
	get_last_insert_r :: proc "c" () -> Str16 ---
	@(link_name = "mb_tolower")
	mb_tolower_r :: proc "c" (c: C.int) -> C.int ---
}

/// ":dis" and ":registers": Display the contents of the yank registers.
@(export)
ex_display :: proc "c" (eap: rawptr) {
	arg := (^rawptr)(uintptr(eap) + EA_ARG)^
	name: C.int

	if arg != nil && (^u8)(arg)^ == 0 {
		arg = nil
	}
	hl_id: C.int = HLF_8

	msg_ext_set_kind(cstring("list_cmd"))
	msg_ext_skip_flush = true
	// Highlight title
	msg_puts_title(_t(cstring("\nType Name Content")))
	i: C.int = -1
	for i < NUM_REGISTERS && !got_int {
		name = get_register_name(i)
		if arg != nil && _vim_strchr(transmute(cstring)((^u8)(arg)), name) == nil {
			i += 1
			continue // did not ask for this register
		}

		switch get_reg_type(name, nil) {
		case kMTLineWise:
			type_ch := 'l'
			_ = type_ch
		}
		// compute type via small helper below
		tc := reg_type_char(get_reg_type(name, nil))

		yb: ^Yankreg_T
		if i == -1 {
			if y_previous != nil {
				yb = y_previous
			} else {
				yb = &y_regs[0]
			}
		} else {
			yb = &y_regs[i]
		}

		get_clipboard(name, &yb, true)

		if name == mb_tolower_r(redir_reg) ||
			(redir_reg == '"' && yb == y_previous) {
			i += 1
			continue // don't list register being written to
		}

		if yb.y_array != nil {
			do_show := false

			for j: C.size_t = 0; !do_show && j < yb.y_size; j += 1 {
				do_show = !message_filtered(transmute(cstring)(yb.y_array[j].data))
			}

			if do_show || yb.y_size == 0 {
				msg_putchar('\n')
				msg_puts(cstring("  "))
				msg_putchar(C.int(tc))
				msg_puts(cstring("  "))
				msg_putchar('"')
				msg_putchar(name)
				msg_puts(cstring("   "))

				n := Columns - 11
				for j: C.size_t = 0; j < yb.y_size && n > 1; j += 1 {
					if j > 0 {
						msg_puts_hl_r(cstring("^J"), hl_id, false)
						n -= 2
					}
					p := yb.y_array[j].data
					for p^ != 0 {
						cl := ptr2cells(transmute(cstring)(p))
						if n-cl < 0 {
							break
						}
						n -= cl
						clen := C.int(utfc_ptr2len(transmute(cstring)(p)))
						msg_outtrans_len_r(transmute(cstring)(p), clen, 0, false)
						p = (^u8)(uintptr(p) + uintptr(clen - 1))
						p = (^u8)(uintptr(p) + 1)
					}
				}
				if n > 1 && yb.y_type == kMTLineWise {
					msg_puts_hl_r(cstring("^J"), hl_id, false)
				}
			}
			os_breakcheck()
		}
		i += 1
	}

	// display last inserted text
	insert := get_last_insert_r()
	if insert.data != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '.') != nil) &&
		!got_int &&
		!message_filtered(transmute(cstring)(insert.data)) {
		msg_puts(cstring("\n  c  \".   "))
		dis_msg(insert.data, true)
	}

	// display last command line
	if last_cmdline != nil && (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), ':') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(last_cmdline)) {
		msg_puts(cstring("\n  c  \":   "))
		dis_msg(last_cmdline, false)
	}

	// display current file name
	fname := (^u8)(buf_read_ptr(curbuf, B_FNAME))
	if fname != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '%') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(fname)) {
		msg_puts(cstring("\n  c  \"%   "))
		dis_msg(fname, false)
	}

	// display alternate file name
	if (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '#') != nil) && !got_int {
		aname: ^u8
		dummy: C.int

		if buflist_name_nr_r(0, &aname, &dummy) != FAIL_R && !message_filtered(transmute(cstring)(aname)) {
			msg_puts(cstring("\n  c  \"#   "))
			dis_msg(aname, false)
		}
	}

	// display last search pattern
	if last_search_pat_r() != nil &&
		(arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '/') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(last_search_pat_r())) {
		msg_puts(cstring("\n  c  \"/   "))
		dis_msg(last_search_pat_r(), false)
	}

	// display last used expression
	if expr_line != nil && (arg == nil || _vim_strchr(transmute(cstring)((^u8)(arg)), '=') != nil) &&
		!got_int && !message_filtered(transmute(cstring)(expr_line)) {
		msg_puts(cstring("\n  c  \"=   "))
		dis_msg(expr_line, false)
	}
	msg_ext_skip_flush = false
}

@(private="file")
reg_type_char :: proc "c"(mt: C.int) -> u8 {
	switch mt {
	case kMTLineWise:
		return 'l'
	case kMTCharWise:
		return 'c'
	case:
		return 'b'
	}
}

/// Used for getregtype(): register type or kMTUnknown for error.
@(export)
get_reg_type :: proc "c" (regname: C.int, reg_width: ^C.int) -> C.int {
	switch regname {
	case '%', '#', '=', ':', '/', '.', Ctrl_F, Ctrl_P, Ctrl_W, Ctrl_A, '_':
		return kMTCharWise
	}

	if regname != 0 && !valid_yank_reg(regname, false) {
		return kMTUnknown
	}

	reg := get_yank_register(regname, YREG_PASTE)

	if reg.y_array != nil {
		if reg_width != nil && reg.y_type == kMTBlockWise {
			reg_width^ = reg.y_width
		}
		return reg.y_type
	}
	return kMTUnknown
}

/// When flags has kGRegList return a list with text s; otherwise just s.
@(private="file")
get_reg_wrap_one_line :: proc "c"(s: ^u8, flags: C.int) -> rawptr {
	if (flags & kGRegList) == 0 {
		return s
	}
	list := tv_list_alloc(1)
	tv_list_append_allocated_string_r(list, s)
	return list
}

/// Gets the contents of a register (for @r expressions and getreg()).
@(export)
get_reg_contents :: proc "c" (regname_arg: C.int, flags: C.int) -> rawptr {
	regname := regname_arg
	// Don't allow using an expression register inside an expression.
	if regname == '=' {
		if (flags & kGRegNoExpr) != 0 {
			return nil
		}
		if (flags & kGRegExprSrc) != 0 {
			return get_reg_wrap_one_line(get_expr_line_src(), flags)
		}
		return get_reg_wrap_one_line(get_expr_line(), flags)
	}

	if regname == '@' { // "@@" used for unnamed register
		regname = '"'
	}

	// check for valid regname
	if regname != 0 && !valid_yank_reg(regname, false) {
		return nil
	}

	retval: ^u8
	allocated: bool
	if get_spec_reg(regname, &retval, &allocated, false) {
		if retval == nil {
			return nil
		}
		if allocated {
			return get_reg_wrap_one_line(retval, flags)
		}
		return get_reg_wrap_one_line(xstrdup(retval), flags)
	}

	reg := get_yank_register(regname, YREG_PUT)
	if reg.y_array == nil {
		return nil
	}

	if (flags & kGRegList) != 0 {
		list := tv_list_alloc(C.ssize_t(reg.y_size))
		for i: C.size_t = 0; i < reg.y_size; i += 1 {
			tv_list_append_string(list, reg.y_array[i].data, C.ssize_t(reg.y_array[i].size))
		}

		return list
	}

	// Compute length of resulting string.
	length: C.size_t = 0
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		length += reg.y_array[i].size
		// newline between lines and after last if linewise
		if reg.y_type == kMTLineWise || i < reg.y_size - 1 {
			length += 1
		}
	}

	retval = (^u8)(xmalloc(length + 1))

	// Copy the lines of the yank register into the string.
	length = 0
	for i: C.size_t = 0; i < reg.y_size; i += 1 {
		libc.memcpy((^u8)(uintptr(retval) + uintptr(length)), reg.y_array[i].data, reg.y_array[i].size + 1)
		length += reg.y_array[i].size

		if reg.y_type == kMTLineWise || i < reg.y_size - 1 {
			(^u8)(uintptr(retval) + uintptr(length))^ = '\n'
			length += 1
		}
	}
	(^u8)(uintptr(retval) + uintptr(length))^ = 0

	return retval
}

@(private="file")
init_write_reg :: proc "c"(name: C.int, old_y_previous: ^^Yankreg_T, must_append: bool) -> ^Yankreg_T {
	if !valid_yank_reg(name, true) { // check for valid reg name
		emsg_invreg_r(name)
		return nil
	}

	// Don't want to change the current (unnamed) register.
	old_y_previous^ = y_previous

	reg := get_yank_register(name, YREG_YANK)
	if !is_append_register(name) && !must_append {
		free_register(reg)
	}
	return reg
}

/// str_to_reg — put a string into a register.
@(private="file")
str_to_reg :: proc "c"(y_ptr: ^Yankreg_T, yank_type_arg: C.int, str: rawptr, len: C.size_t,
	blocklen: C.int, str_list: bool) {
	yank_type := yank_type_arg
	if y_ptr.y_array == nil { // NULL means empty register
		y_ptr.y_size = 0
	}

	if yank_type == kMTUnknown {
		cs: ^u8
		if str_list {
			cs = nil
			yank_type = kMTLineWise
		} else {
			cs = (^u8)(str)
			yank_type = (len > 0 && ((^u8)(uintptr(cs) + uintptr(len) - 1)^ == '\n' || (^u8)(uintptr(cs) + uintptr(len) - 1)^ == '\r')) ? kMTLineWise : kMTCharWise
		}
	}

	newlines: C.size_t = 0
	extraline := false // extra line at the end
	append := false    // append to last line in register

	// Count the number of lines within the string
	if str_list {
		for cargv_at(transmute(^rawptr)(str), newlines) != nil {
			newlines += 1
		}
	} else {
		cs := (^u8)(str)
		newlines = C.size_t(_memcnt(str, C.int('\n'), len))
		if yank_type == kMTCharWise || len == 0 || (^u8)(uintptr(cs) + uintptr(len) - 1)^ != '\n' {
			extraline = true
			newlines += 1 // extra newline at the end
		}
		if y_ptr.y_size > 0 && y_ptr.y_type == kMTCharWise {
			append = true
			newlines -= 1 // uncount newline when appending first line
		}
	}

	// Without any lines make the register empty.
	if y_ptr.y_size + newlines == 0 {
		xfree_clear_reg(transmute(^rawptr)(&y_ptr.y_array))
		return
	}

	// Grow the register array to hold pointers to the new lines.
	pp := transmute([^]Str16)(xrealloc(y_ptr.y_array, (y_ptr.y_size + newlines) * size_of(Str16)))
	y_ptr.y_array = pp

	lnum := y_ptr.y_size // The current line number.

	maxlen: C.size_t = 0

	// Find the end of each line and save it into the array.
	if str_list {
		k: C.size_t = 0
		for cargv_at(transmute(^rawptr)(str), k) != nil {
			sk := cargv_at(transmute(^rawptr)(str), k)
			pp[lnum] = cstr_to_string_r(transmute(cstring)(sk))
			if yank_type == kMTBlockWise {
				charlen := mb_string2cells_s(transmute(cstring)(sk))
				maxlen = max(maxlen, charlen)
			}
			k += 1
			lnum += 1
		}
	} else {
		cs := (^u8)(str)
		start := cs
		end := (^u8)(uintptr(cs) + uintptr(len))
		for uintptr(start) < uintptr(end) + (extraline ? 1 : 0) {
			charlen: C.int = 0

			line_end := start
			for uintptr(line_end) < uintptr(end) { // find end of line
				if line_end^ == '\n' {
					break
				}
				if yank_type == kMTBlockWise {
					charlen += utf_ptr2cells_len_r(transmute(cstring)(line_end), C.int(uintptr(end) - uintptr(line_end)))
				}

				if line_end^ == 0 {
					line_end = (^u8)(uintptr(line_end) + 1) // registers can have NUL chars
				} else {
					line_end = (^u8)(uintptr(line_end) + uintptr(utf_ptr2len_len_r(transmute(cstring)(line_end), C.int(uintptr(end) - uintptr(line_end)))))
				}
			}
			line_len := uintptr(line_end) - uintptr(start)
			maxlen = max(maxlen, C.size_t(charlen))

			// When appending, copy previous line and free it after.
			extra: C.size_t = 0
			if append {
				lnum -= 1
				extra = pp[lnum].size
			}
			s := xmallocz_r(C.size_t(line_len) + extra)
			if extra > 0 {
				libc.memcpy(s, pp[lnum].data, extra)
			}
			if line_len > 0 {
				libc.memcpy((^u8)(uintptr(s) + uintptr(extra)), start, C.size_t(line_len))
			}
			s_len := extra + C.size_t(line_len)

			if append {
				xfree(pp[lnum].data)
				append = false // only first line is appended
			}
			pp[lnum] = Str16{data = s, size = s_len}

			// Convert NULs to '\n' to prevent truncation.
			_memchrsub(pp[lnum].data, 0, '\n', s_len)

			start = (^u8)(uintptr(start) + line_len + 1)
			lnum += 1
		}
	}
	y_ptr.y_type = yank_type
	y_ptr.y_size = lnum
	xfree_clear_reg(&y_ptr.additional_data)
	y_ptr.timestamp = os_time()
	if yank_type == kMTBlockWise {
		y_ptr.y_width = blocklen == -1 ? C.int(maxlen) - 1 : blocklen
	} else {
		y_ptr.y_width = 0
	}
}

@(private="file")
finish_write_reg :: proc "c"(name: C.int, reg: ^Yankreg_T, old_y_previous: ^Yankreg_T) {
	// Send text of clipboard register to the clipboard.
	set_clipboard(name, reg)

	// ':let @" = "val"' should change the meaning of the "" register
	if name != '"' {
		y_previous = old_y_previous
	}
}

/// store str in register name
@(export)
write_reg_contents :: proc "c" (name: C.int, str: cstring, len: i64, must_append: C.int) {
	write_reg_contents_ex(name, str, len, must_append != 0, kMTUnknown, 0)
}

@(export)
write_reg_contents_lst :: proc "c" (name: C.int, strings: ^rawptr, must_append: bool, yank_type: C.int, block_len: C.int) {
	if name == '/' || name == '=' || name == '#' {
		s0 := cargv_at(strings, 0)
		s1 := cargv_at(strings, 1)
		s := s0
		if s0 == nil {
			s = transmute(^u8)(cstring(""))
		} else if s1 != nil {
			buf: [1025]u8
			n := libc.snprintf(&buf[0], size_of(buf), cstring("E883: Register '%c' cannot contain multiple lines"), name)
			buf[n if n >= 0 && n < 1024 else 1024] = 0
			emsg(transmute(cstring)(&buf[0]))
			return
		}
		write_reg_contents_ex(name, transmute(cstring)(s), -1, must_append, yank_type, block_len)
		return
	}

	// black hole: nothing to do
	if name == '_' {
		return
	}

	old_y_previous: ^Yankreg_T
	reg := init_write_reg(name, &old_y_previous, must_append)
	if reg == nil {
		return
	}

	str_to_reg(reg, yank_type, strings, libc.strlen(transmute(cstring)(strings)),
		block_len, true)
	finish_write_reg(name, reg, old_y_previous)
}

/// write_reg_contents_ex — store str in register name.
@(export)
write_reg_contents_ex :: proc "c" (name: C.int, str: cstring, len_arg: i64, must_append: bool,
	yank_type: C.int, block_len: C.int) {
	len := len_arg
	if len < 0 {
		len = i64(libc.strlen(str))
	}

	// Special case: '/' search pattern
	if name == '/' {
		set_last_search_pat_r(str, RE_SEARCH, 1, true)
		return
	}

	if name == '#' {
		if len == 0 {
			set_i32_off(curwin, W_ALT_FNUM, 0) // clear altfile
			return
		}

		buf: rawptr

		if ascii_isdigit_r(C.int((^u8)(uintptr(transmute(rawptr)(str)))^)) {
			num := libc.atoi(str)

			buf = buflist_findnr(num)
			if buf == nil {
				nbuf: [64]u8
				n := libc.snprintf(&nbuf[0], size_of(nbuf), _t(cstring("E86: Buffer %ld does not exist")), C.long(num))
				nbuf[n if n >= 0 && n < 63 else 63] = 0
				emsg(transmute(cstring)(&nbuf[0]))
			}
		} else {
			buf = buflist_findnr(buflist_findpat_r(str, transmute(cstring)((^u8)(uintptr(transmute(rawptr)(str)) + uintptr(len))), true, false, false))
		}
		if buf == nil {
			return
		}
		set_i32_off(curwin, W_ALT_FNUM, get_i32_off(buf, B_HANDLE))
		return
	}

	if name == '=' {
		offset: C.size_t = 0
		totlen := C.size_t(len)

		if must_append && expr_line != nil {
			// append to existing expr_line
			exprlen := libc.strlen(transmute(cstring)(expr_line))

			totlen += exprlen
			offset = exprlen
		}

		expr_line = (^u8)(xrealloc(expr_line, totlen + 1))
		libc.memcpy((^u8)(uintptr(expr_line) + uintptr(offset)), transmute(rawptr)(str), C.size_t(len))
		(^u8)(uintptr(expr_line) + uintptr(totlen))^ = 0

		return
	}

	if name == '_' { // black hole: nothing to do
		return
	}

	old_y_previous: ^Yankreg_T
	reg := init_write_reg(name, &old_y_previous, must_append)
	if reg == nil {
		return
	}
	str_to_reg(reg, yank_type, transmute(rawptr)(str), C.size_t(len), block_len, false)
	finish_write_reg(name, reg, old_y_previous)
}

/// @param[out] reg Expected to be empty
@(export)
prepare_yankreg_from_object :: proc "c" (reg: ^Yankreg_T, regtype: Str16, lines: C.size_t) -> bool {
	_ = lines
	type_ch := regtype.data != nil ? regtype.data^ : 0

	switch type_ch {
	case 0:
		reg.y_type = kMTUnknown
	case 'v', 'c':
		reg.y_type = kMTCharWise
	case 'V', 'l':
		reg.y_type = kMTLineWise
	case 'b':
		reg.y_type = kMTBlockWise
	case 22: // Ctrl_V
		reg.y_type = kMTBlockWise
	case:
		return false
	}

	reg.y_width = 0
	if regtype.size > 1 {
		if reg.y_type != kMTBlockWise {
			return false
		}

		// allow "b7" for a block at least 7 spaces wide
		if !ascii_isdigit_r(C.int((^u8)(uintptr(regtype.data) + 1)^)) {
			return false
		}
		p := (^u8)(uintptr(regtype.data) + 1)
		p_ptr := &p
		reg.y_width = getdigits_int_r(p_ptr, false, 1) - 1
		if regtype.size > C.size_t(uintptr(p) - uintptr(regtype.data)) {
			return false
		}
	}

	reg.additional_data = nil
	reg.timestamp = 0
	return true
}

@(export)
finish_yankreg_from_object :: proc "c" (reg: ^Yankreg_T, clipboard_adjust: bool) {
	if reg.y_size > 0 && reg.y_array[reg.y_size - 1].size == 0 {
		// a known-to-be charwise yank might have a final linebreak
		if reg.y_type != kMTCharWise {
			if reg.y_type == kMTUnknown || clipboard_adjust {
				reg.y_size -= 1
			}
			if reg.y_type == kMTUnknown {
				reg.y_type = kMTLineWise
			}
		}
	} else {
		if reg.y_type == kMTUnknown {
			reg.y_type = kMTCharWise
		}
	}

	update_yankreg_width(reg)
}
