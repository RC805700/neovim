package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// state.c port: main state machine + mode/safestate helpers.

K_EVENT_O :: -26365  // TERMCAP2KEY(KS_EXTRA=253, KE_EVENT=102)

MODE_OP_PENDING_O :: 0x04
MODE_SELECT_O :: 0x40
MODE_EXTERNCMD_O :: 0x5000
MODE_MAX_LENGTH_O :: 4

EVENT_MODECHANGED_O :: 84
EVENT_SAFESTATE_O :: 95

KOPTVEFLAG_ALL_O :: 0x04
KOPTVEFLAG_BLOCK_O :: 0x05
KOPTVEFLAG_INSERT_O :: 0x06

State_Check_O :: proc "c" (s: rawptr) -> C.int
State_Execute_O :: proc "c" (s: rawptr, key: C.int) -> C.int
VimState_O :: struct {
	check:   State_Check_O,  // @0
	execute: State_Execute_O,  // @8
}
#assert(size_of(VimState_O) == 16)

foreign _ {
	@(link_name = "safe_vgetc")
	safe_vgetc_e :: proc "c" () -> C.int ---
	@(link_name = "check_end_reg_executing")
	check_end_reg_executing_e :: proc "c" (advance: bool) ---
	@(link_name = "may_sync_undo")
	may_sync_undo_e :: proc "c" () ---
	@(link_name = "motion_force")
	motion_force_g: C.int
	@(link_name = "last_mode")
	last_mode_g: [MODE_MAX_LENGTH_O]u8
	@(link_name = "debug_mode")
	debug_mode_g: bool
	@(link_name = "ctrl_x_mode_not_defined_yet")
	ctrl_x_mode_not_defined_yet_e :: proc "c" () -> bool ---
	@(link_name = "restart_VIsual_select")
	restart_VIsual_select_g: C.int
	// must_redraw lives in register.odin — reuse directly.
	// cmdline_at_end/overstrike_e live in cursor_shape.odin — reuse directly.
}

@(private = "file")
was_safe_g: bool

// Main state machine (state.c public).
@(export)
state_enter :: proc "c" (s_in: rawptr) {
	context = runtime.default_context()
	s := (^VimState_O)(s_in)
	check_phase := true
	for {
		if check_phase {
			check_result: C.int = 1
			if s.check != nil {
				check_result = s.check(s_in)
			}
			if check_result == 0 {
				break
			} else if check_result == -1 {
				continue
			}
			check_phase = false
		}
		key: C.int = 0
		key_ok := false
		for !key_ok {
			if vpeekc_e() != 0 || typebuf.tb_len > 0 {
				key = safe_vgetc_e()
				key_ok = true
			} else if !multiqueue_empty(main_loop.events) {
				ui_flush()
				key = K_EVENT_O
				key_ok = true
			} else {
				if must_redraw != 0 && !need_wait_return_g && (State & MODE_CMDLINE_O) == 0 {
					update_screen()
					setcursor()
				}
				ui_flush()
				input_get(nil, 0, -1, typebuf.tb_change_cnt, main_loop.events)
				if input_available() == 0 && !multiqueue_empty(main_loop.events) {
					key = K_EVENT_O
					key_ok = true
				}
			}
		}
		if key == K_EVENT_O {
			check_end_reg_executing_e(true)
			may_sync_undo_e()
		}
		execute_result := s.execute(s_in, key)
		if execute_result == 0 {
			break
		} else if execute_result != -1 {
			check_phase = true
		}
	}
}

// Event-queue drain for K_EVENT states (state.c public).
@(export)
state_handle_k_event :: proc "c" () {
	context = runtime.default_context()
	for {
		ev := multiqueue_get(main_loop.events)
		if ev.handler != nil {
			ev.handler(&ev.argv[0])
		}
		if multiqueue_empty(main_loop.events) {
			return
		}
		os_breakcheck()
		if input_available() != 0 || got_int {
			return
		}
	}
}

// Virtual-edit need test (state.c public).
@(export)
virtual_active :: proc "c" (wp: rawptr) -> bool {
	context = runtime.default_context()
	if (State & MODE_TERMINAL_O) != 0 {
		return true
	}
	cur_ve_flags := get_ve_flags(wp)
	if cur_ve_flags == KOPTVEFLAG_ALL_O || ((cur_ve_flags & KOPTVEFLAG_INSERT_O) != 0 && (State & MODE_INSERT) != 0) {
		return true
	}
	if virtual_op_g != TriState.kNone {
		return virtual_op_g == TriState.kTrue
	}
	return (cur_ve_flags & KOPTVEFLAG_BLOCK_O) != 0 && VIsual_active && VIsual_mode == Ctrl_V
}

// Visual/select/op-pending aware state (state.c public).
@(export)
get_real_state :: proc "c" () -> C.int {
	context = runtime.default_context()
	if (State & MODE_NORMAL_O) != 0 {
		if VIsual_active {
			if VIsual_select_g {
				return MODE_SELECT_O
			}
			return MODE_VISUAL_O
		} else if finish_op_g {
			return MODE_OP_PENDING_O
		}
	}
	return State
}

// Mode string into 4-byte buffer (state.c public).
@(export)
get_mode :: proc "c" (buf: ^u8) {
	context = runtime.default_context()
	b := ([^]u8)(buf)
	i: C.int = 0
	if State == MODE_HITRETURN_O || State == MODE_ASKMORE_O || State == MODE_SETWSIZE_O || ((State & MODE_CMDLINE_O) != 0 && ([^]u8)(get_cmdline_info_r())[CCLINE_ONE_KEY_OFF] != 0) {
		b[i] = 'r'
		i += 1
		if State == MODE_ASKMORE_O {
			b[i] = 'm'
			i += 1
		} else if (State & MODE_CMDLINE_O) != 0 {
			b[i] = '?'
			i += 1
		}
	} else if State == MODE_EXTERNCMD_O {
		b[i] = '!'
		i += 1
	} else if (State & MODE_INSERT) != 0 {
		if (State & VREPLACE_FLAG_O) != 0 {
			b[i] = 'R'
			i += 1
			b[i] = 'v'
			i += 1
		} else {
			if (State & REPLACE_FLAG) != 0 {
				b[i] = 'R'
			} else {
				b[i] = 'i'
			}
			i += 1
		}
		if ins_compl_active() {
			b[i] = 'c'
			i += 1
		} else if ctrl_x_mode_not_defined_yet_e() {
			b[i] = 'x'
			i += 1
		}
	} else if ((State & MODE_CMDLINE_O) != 0 || exmode_active) {
		b[i] = 'c'
		i += 1
		if exmode_active {
			b[i] = 'v'
			i += 1
		}
		if ((State & MODE_CMDLINE_O) != 0) && cmdline_overstrike_e() {
			b[i] = 'r'
			i += 1
		}
	} else if (State & MODE_TERMINAL_O) != 0 {
		b[i] = 't'
		i += 1
	} else if VIsual_active {
		if VIsual_select_g {
			b[i] = u8(C.int(VIsual_mode) + 's' - 'v')
			i += 1
		} else {
			b[i] = u8(VIsual_mode)
			i += 1
			if restart_VIsual_select_g != 0 {
				b[i] = 's'
				i += 1
			}
		}
	} else {
		b[i] = 'n'
		i += 1
		if finish_op_g {
			b[i] = 'o'
			i += 1
			b[i] = u8(motion_force_g)
			i += 1
		} else if (^rawptr)(uintptr(curbuf) + B_TERMINAL_OFF)^ != nil {
			b[i] = 't'
			i += 1
			if restart_edit == 'I' {
				b[i] = 'T'
				i += 1
			}
		} else if restart_edit == 'I' || restart_edit == 'R' || restart_edit == 'V' {
			b[i] = 'i'
			i += 1
			b[i] = u8(restart_edit)
			i += 1
		}
	}
	b[i] = 0
}

// ModeChanged autocmd trigger (state.c public).
@(export)
may_trigger_modechanged :: proc "c" () {
	context = runtime.default_context()
	if !has_event_r(EVENT_MODECHANGED_O) || got_int {
		return
	}
	curr_mode: [MODE_MAX_LENGTH_O]u8
	pattern_buf: [2*MODE_MAX_LENGTH_O]u8
	get_mode(&curr_mode[0])
	if libc.strcmp(transmute(cstring)(&curr_mode[0]), transmute(cstring)(&last_mode_g[0])) == 0 {
		return
	}
	sve: Save_V_Event_T
	v_event := get_v_event(&sve)
	tv_dict_add_str(v_event, cstring("new_mode"), 8, transmute(cstring)(&curr_mode[0]))
	tv_dict_add_str(v_event, cstring("old_mode"), 8, transmute(cstring)(&last_mode_g[0]))
	tv_dict_set_keys_readonly(v_event)
	// "old_mode:new_mode" without variadics (manual join).
	pp := 0
	for last_mode_g[pp] != 0 {
		pattern_buf[pp] = last_mode_g[pp]
		pp += 1
	}
	pattern_buf[pp] = ':'
	pp += 1
	j := 0
	for curr_mode[j] != 0 {
		pattern_buf[pp] = curr_mode[j]
		pp += 1
		j += 1
	}
	pattern_buf[pp] = 0
	apply_autocmds(EVENT_MODECHANGED_O, transmute(cstring)(&pattern_buf[0]), nil, false, curbuf)
	libc.memcpy(rawptr(&last_mode_g[0]), rawptr(&curr_mode[0]), C.size_t(len(curr_mode)))
	restore_v_event(v_event, &sve)
}

// Safe-state trigger (state.c public).
@(export)
may_trigger_safestate :: proc "c" (safe: bool) {
	context = runtime.default_context()
	is_safe := safe && is_safe_now_o()
	if was_safe_g != is_safe {
		// DLOG compiled out (no NVIM_LOG_DEBUG in this build).
	}
	if is_safe {
		apply_autocmds(EVENT_SAFESTATE_O, nil, nil, false, curbuf)
	}
	was_safe_g = is_safe
}

// Safe-state predicate (C-static; plain proc).
is_safe_now_o :: proc "c" () -> bool {
	context = runtime.default_context()
	return stuff_empty_e() && typebuf.tb_len == 0 && using_script_e() == 0 && global_busy == 0 && !debug_mode_g
}

// Safe-state invalidator (state.c public).
@(export)
state_no_longer_safe :: proc "c" (reason: cstring) {
	context = runtime.default_context()
	if was_safe_g && reason != nil {
		// DLOG compiled out (no NVIM_LOG_DEBUG in this build).
	}
	was_safe_g = false
}

// Safe-state query (state.c public).
@(export)
get_was_safe_state :: proc "c" () -> bool {
	context = runtime.default_context()
	return was_safe_g
}
