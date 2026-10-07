package main

import "base:runtime"
import C "core:c"
import "core:c/libc"

// —— ui_compositor.c port (Batch U1: state + tiny leaves) ——

// File-static state (single copies; nm-proven no other C users).
@(private = "file")
uc_composed_uis_g: C.int = 0
@(private = "file")
uc_layers_size_g: C.size_t = 0
@(private = "file")
uc_layers_cap_g: C.size_t = 0
@(private = "file")
uc_layers_items_g: [^]^ScreenGrid = nil
@(private = "file")
uc_bufsize_g: C.size_t = 0
@(private = "file")
uc_linebuf_g: [^]u32 = nil
@(private = "file")
uc_attrbuf_g: [^]i32 = nil
@(private = "file")
uc_chk_width_g: C.int = 0
@(private = "file")
uc_chk_height_g: C.int = 0
@(private = "file")
uc_curgrid_g: ^ScreenGrid = nil
@(private = "file")
uc_valid_screen_g: bool = true
@(private = "file")
uc_msg_current_row_g: C.int = 2147483647
@(private = "file")
uc_msg_was_scrolled_g: bool = false
@(private = "file")
uc_msg_sep_row_g: C.int = -1
@(private = "file")
uc_msg_sep_char_g: u32 = 32
@(private = "file")
uc_dbghl_normal_g: C.int = 0
@(private = "file")
uc_dbghl_clear_g: C.int = 0
@(private = "file")
uc_dbghl_composed_g: C.int = 0
@(private = "file")
uc_dbghl_recompose_g: C.int = 0

uc_layers_push_o :: proc "c" (grid: ^ScreenGrid) {
	context = runtime.default_context()
	if uc_layers_size_g == uc_layers_cap_g {
		if uc_layers_cap_g == 0 {
			uc_layers_cap_g = 8
		} else {
			uc_layers_cap_g *= 2
		}
		uc_layers_items_g = ([^]^ScreenGrid)(xrealloc(uc_layers_items_g, uc_layers_cap_g * size_of(^ScreenGrid)))
	}
	uc_layers_items_g[uc_layers_size_g] = grid
	uc_layers_size_g += 1
}

@(export)
ui_comp_init :: proc "c" () {
	context = runtime.default_context()
	uc_layers_push_o((^ScreenGrid)(&default_grid_u8))
	uc_curgrid_g = (^ScreenGrid)(&default_grid_u8)
}

@(export)
ui_comp_syn_init :: proc "c" () {
	context = runtime.default_context()
	uc_dbghl_normal_g = syn_check_group_c(transmute(^u8)(cstring("RedrawDebugNormal")), C.size_t(libc.strlen(cstring("RedrawDebugNormal"))))
	uc_dbghl_clear_g = syn_check_group_c(transmute(^u8)(cstring("RedrawDebugClear")), C.size_t(libc.strlen(cstring("RedrawDebugClear"))))
	uc_dbghl_composed_g = syn_check_group_c(transmute(^u8)(cstring("RedrawDebugComposed")), C.size_t(libc.strlen(cstring("RedrawDebugComposed"))))
	uc_dbghl_recompose_g = syn_check_group_c(transmute(^u8)(cstring("RedrawDebugRecompose")), C.size_t(libc.strlen(cstring("RedrawDebugRecompose"))))
}

@(export)
ui_comp_attach :: proc "c" (ui: rawptr) {
	context = runtime.default_context()
	uc_composed_uis_g += 1
	(^RemoteUI_O)(ui).composed = true
}

@(export)
ui_comp_detach :: proc "c" (ui: rawptr) {
	context = runtime.default_context()
	uc_composed_uis_g -= 1
	if uc_composed_uis_g == 0 {
		xfree(rawptr(uc_linebuf_g))
		uc_linebuf_g = nil
		xfree(rawptr(uc_attrbuf_g))
		uc_attrbuf_g = nil
		uc_bufsize_g = 0
	}
	(^RemoteUI_O)(ui).composed = false
}

@(export)
ui_comp_should_draw :: proc "c" () -> bool {
	context = runtime.default_context()
	return uc_composed_uis_g != 0 && uc_valid_screen_g
}

@(export)
ui_comp_layers_adjust :: proc "c" (layer_idx_in: C.size_t, raise: bool) {
	context = runtime.default_context()
	layer_idx := layer_idx_in
	size := uc_layers_size_g
	layer := uc_layers_items_g[layer_idx]
	if raise {
		for layer_idx < size - 1 && layer.zindex > uc_layers_items_g[layer_idx + 1].zindex {
			uc_layers_items_g[layer_idx] = uc_layers_items_g[layer_idx + 1]
			uc_layers_items_g[layer_idx].comp_index = layer_idx
			uc_layers_items_g[layer_idx].pending_comp_index_update = true
			layer_idx += 1
		}
	} else {
		for layer_idx > 0 && layer.zindex < uc_layers_items_g[layer_idx - 1].zindex {
			uc_layers_items_g[layer_idx] = uc_layers_items_g[layer_idx - 1]
			uc_layers_items_g[layer_idx].comp_index = layer_idx
			uc_layers_items_g[layer_idx].pending_comp_index_update = true
			layer_idx -= 1
		}
	}
	uc_layers_items_g[layer_idx] = layer
	layer.comp_index = layer_idx
	layer.pending_comp_index_update = true
}

@(export)
ui_comp_set_screen_valid :: proc "c" (valid: bool) -> bool {
	context = runtime.default_context()
	old_val := uc_valid_screen_g
	uc_valid_screen_g = valid
	if !valid {
		uc_msg_sep_row_g = -1
	}
	return old_val
}

// —— Batch U2: grid management ——

uc_layers_ensure_o :: proc "c" (extra: C.size_t) {
	context = runtime.default_context()
	if uc_layers_size_g + extra > uc_layers_cap_g {
		if uc_layers_cap_g == 0 {
			uc_layers_cap_g = 8
		}
		for uc_layers_size_g + extra > uc_layers_cap_g {
			uc_layers_cap_g *= 2
		}
		uc_layers_items_g = ([^]^ScreenGrid)(xrealloc(uc_layers_items_g, uc_layers_cap_g * size_of(^ScreenGrid)))
	}
}

@(export)
ui_comp_put_grid :: proc "c" (grid: ^ScreenGrid, row: C.int, col: C.int, height: C.int, width: C.int, valid: bool, on_top: bool) -> bool {
	context = runtime.default_context()
	moved := false
	grid.pending_comp_index_update = true
	if grid.comp_index != 0 {
		moved = (row != grid.comp_row) || (col != grid.comp_col)
		if ui_comp_should_draw() {
			// Redraw the area covered by the old position, and is not covered
			// by the new position. Disable the grid so that compose_area() will not
			// use it.
			grid.comp_disabled = true
			compose_area_o(grid.comp_row, row, grid.comp_col, grid.comp_col + grid.comp_width)
			if grid.comp_col < col {
				compose_area_o(max(row, grid.comp_row), min(row + height, grid.comp_row + grid.comp_height), grid.comp_col, col)
			}
			if col + width < grid.comp_col + grid.comp_width {
				compose_area_o(max(row, grid.comp_row), min(row + height, grid.comp_row + grid.comp_height), col + width, grid.comp_col + grid.comp_width)
			}
			compose_area_o(row + height, grid.comp_row + grid.comp_height, grid.comp_col, grid.comp_col + grid.comp_width)
			grid.comp_disabled = false
		}
		grid.comp_row = row
		grid.comp_col = col
	} else {
		moved = true
		for i: C.size_t = 0; i < uc_layers_size_g; i += 1 {
			if uc_layers_items_g[i] == grid {
				libc.abort()
			}
		}
		insert_at := uc_layers_size_g
		for insert_at > 0 && uc_layers_items_g[insert_at - 1].zindex > grid.zindex {
			insert_at -= 1
		}
		if curwin != nil && insert_at > 0 && uc_layers_items_g[insert_at - 1] == (^ScreenGrid)(uintptr(curwin) + W_GRID_ALLOC_OFF) && uc_layers_items_g[insert_at - 1].zindex == grid.zindex && !on_top {
			insert_at -= 1
		}
		// not found: new grid
		uc_layers_ensure_o(1)
		uc_layers_size_g += 1
		for i := uc_layers_size_g - 1; i > insert_at; i -= 1 {
			uc_layers_items_g[i] = uc_layers_items_g[i - 1]
			uc_layers_items_g[i].comp_index = i
			uc_layers_items_g[i].pending_comp_index_update = true
		}
		uc_layers_items_g[insert_at] = grid
		grid.comp_row = row
		grid.comp_col = col
		grid.comp_index = insert_at
		grid.pending_comp_index_update = true
	}
	grid.comp_height = height
	grid.comp_width = width
	if moved && valid && ui_comp_should_draw() {
		compose_area_o(grid.comp_row, grid.comp_row + grid.rows, grid.comp_col, grid.comp_col + grid.cols)
	}
	return moved
}

@(export)
ui_comp_remove_grid :: proc "c" (grid: ^ScreenGrid) {
	context = runtime.default_context()
	if grid == (^ScreenGrid)(&default_grid_u8) {
		libc.abort()
	}
	if grid.comp_index == 0 {
		// grid wasn't present
		return
	}
	if uc_curgrid_g == grid {
		uc_curgrid_g = (^ScreenGrid)(&default_grid_u8)
	}
	for i := grid.comp_index; i < uc_layers_size_g - 1; i += 1 {
		uc_layers_items_g[i] = uc_layers_items_g[i + 1]
		uc_layers_items_g[i].comp_index = i
		uc_layers_items_g[i].pending_comp_index_update = true
	}
	uc_layers_size_g -= 1
	grid.comp_index = 0
	grid.pending_comp_index_update = true
	// recompose the area under the grid
	// inefficient when being overlapped: only draw up to grid->comp_index
	ui_comp_compose_grid(grid)
}

@(export)
ui_comp_set_grid :: proc "c" (handle: C.int) -> bool {
	context = runtime.default_context()
	if uc_curgrid_g.handle == handle {
		return true
	}
	grid: ^ScreenGrid = nil
	for i: C.size_t = 0; i < uc_layers_size_g; i += 1 {
		if uc_layers_items_g[i].handle == handle {
			grid = uc_layers_items_g[i]
			break
		}
	}
	if grid != nil {
		uc_curgrid_g = grid
		return true
	}
	return false
}

@(export)
ui_comp_raise_grid :: proc "c" (grid: ^ScreenGrid, new_index: C.size_t) {
	context = runtime.default_context()
	old_index := grid.comp_index
	for i := old_index; i < new_index; i += 1 {
		uc_layers_items_g[i] = uc_layers_items_g[i + 1]
		uc_layers_items_g[i].comp_index = i
		uc_layers_items_g[i].pending_comp_index_update = true
	}
	uc_layers_items_g[new_index] = grid
	grid.comp_index = new_index
	grid.pending_comp_index_update = true
	for i := old_index; i < new_index; i += 1 {
		grid2 := uc_layers_items_g[i]
		startcol := max(grid.comp_col, grid2.comp_col)
		endcol := min(grid.comp_col + grid.cols, grid2.comp_col + grid2.cols)
		compose_area_o(max(grid.comp_row, grid2.comp_row), min(grid.comp_row + grid.rows, grid2.comp_row + grid2.rows), startcol, endcol)
	}
}

@(export)
ui_comp_grid_cursor_goto :: proc "c" (grid_handle: C.longlong, r: C.longlong, c: C.longlong) {
	context = runtime.default_context()
	if !ui_comp_set_grid(C.int(grid_handle)) {
		return
	}
	cursor_row := uc_curgrid_g.comp_row + C.int(r)
	cursor_col := uc_curgrid_g.comp_col + C.int(c)
	// TODO(bfredl): maybe not the best time to do this, for efficiency we
	// should configure all grids before entering win_update()
	if uc_curgrid_g != (^ScreenGrid)(&default_grid_u8) {
		new_index := uc_layers_size_g - 1
		for new_index > 1 && uc_layers_items_g[new_index].zindex > uc_curgrid_g.zindex {
			new_index -= 1
		}
		if uc_curgrid_g.comp_index < new_index {
			ui_comp_raise_grid(uc_curgrid_g, new_index)
		}
	}
	if cursor_col >= (^ScreenGrid)(&default_grid_u8).cols || cursor_row >= (^ScreenGrid)(&default_grid_u8).rows {
		// TODO(bfredl): this happens with 'writedelay', refactor?
		// abort();
		return
	}
	ui_composed_call_grid_cursor_goto(1, i64(cursor_row), i64(cursor_col))
}

@(export)
ui_comp_mouse_focus :: proc "c" (row: C.int, col: C.int) -> ^ScreenGrid {
	context = runtime.default_context()
	for i := int(uc_layers_size_g) - 1; i > 0; i -= 1 {
		grid := uc_layers_items_g[uintptr(i)]
		if grid.mouse_enabled && row >= grid.comp_row && row < grid.comp_row + grid.rows && col >= grid.comp_col && col < grid.comp_col + grid.cols {
			return grid
		}
	}
	if ui_has(K_UIMULTIGRID_O) {
		wp := firstwin
		for wp != nil {
			grid := (^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF)
			if grid.mouse_enabled && row >= (^C.int)(uintptr(wp) + W_WINROW_OFF)^ && row < (^C.int)(uintptr(wp) + W_WINROW_OFF)^ + grid.rows && col >= (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ && col < (^C.int)(uintptr(wp) + W_WINCOL_OFF)^ + grid.cols {
				return grid
			}
			wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
		}
	}
	return nil
}

@(export)
ui_comp_get_grid_at_coord :: proc "c" (row: C.int, col: C.int) -> ^ScreenGrid {
	context = runtime.default_context()
	for i := int(uc_layers_size_g) - 1; i > 0; i -= 1 {
		grid := uc_layers_items_g[uintptr(i)]
		if row >= grid.comp_row && row < grid.comp_row + grid.rows && col >= grid.comp_col && col < grid.comp_col + grid.cols {
			return grid
		}
	}
	wp := firstwin
	for wp != nil {
		grid := (^ScreenGrid)(uintptr(wp) + W_GRID_ALLOC_OFF)
		if row >= grid.comp_row && row < grid.comp_row + grid.rows && col >= grid.comp_col && col < grid.comp_col + grid.cols && !(^bool)(uintptr(wp) + WCFG_HIDE_OFF)^ {
			return grid
		}
		wp = (^rawptr)(uintptr(wp) + W_NEXT_OFF)^
	}
	return (^ScreenGrid)(&default_grid_u8)
}

// —— Batch U3: compose engine ——

KLINEFLAG_WRAP_O: C.int = 1
KLINEFLAG_INVALID_O: C.int = 2
KOPTRDB_COMPOSITOR_O: C.uint = 0x01
KOPTRDB_INVALID_O: C.uint = 0x04
HLF_MSGSEP_O: C.int = 61

compose_line_o :: proc "c" (row_in: C.longlong, startcol_in: C.longlong, endcol_in: C.longlong, flags_in: C.int) {
	context = runtime.default_context()
	startcol := C.int(max(startcol_in, 0))
	endcol := C.int(endcol_in)
	flags := flags_in
	// If rightleft is set, startcol may be -1. In such cases, the assertions
	// will fail because no overlap is found. Adjust startcol to prevent it.
	// in case we start on the right half of a double-width char, we need to
	// check the left half. But skip it in output if it wasn't doublewidth.
	skipstart: C.int = 0
	skipend: C.int = 0
	if startcol > 0 && (flags & KLINEFLAG_INVALID_O) != 0 {
		startcol -= 1
		skipstart = 1
	}
	dg := (^ScreenGrid)(&default_grid_u8)
	if endcol < dg.cols && (flags & KLINEFLAG_INVALID_O) != 0 {
		endcol += 1
		skipend = 1
	}
	col := startcol
	row := C.int(row_in)
	grid: ^ScreenGrid = nil
	bg_base := ([^]u32)(dg.chars)
	bg_off := uintptr(dg.line_offset[uintptr(row)]) + uintptr(startcol)
	bg_attrs_base := ([^]i32)(dg.attrs)
	for col < endcol {
		until: C.int = 0
		for i: C.size_t = 0; i < uc_layers_size_g; i += 1 {
			g := uc_layers_items_g[i]
			// compose_line may have been called after a shrinking operation but
			// before the resize has actually been applied. Therefore, we need to
			// first check to see if any grids have pending updates to width/height,
			// to ensure that we don't accidentally put any characters into `linebuf`
			// that have been invalidated.
			grid_width := min(g.cols, g.comp_width)
			grid_height := min(g.rows, g.comp_height)
			if g.comp_row > row || row >= g.comp_row + grid_height || g.comp_disabled {
				continue
			}
			if g.comp_col <= col && col < g.comp_col + grid_width {
				grid = g
				until = g.comp_col + grid_width
			} else if g.comp_col > col {
				until = min(until, g.comp_col)
			}
		}
		until = min(until, endcol)
		if grid == nil {
			libc.abort()
		}
		if !(until > col) {
			libc.abort()
		}
		if !(until <= dg.cols) {
			libc.abort()
		}
		n := until - col
		if row == uc_msg_sep_row_g && grid.comp_index <= (^ScreenGrid)(&msg_grid_u8).comp_index {
			// TODO(bfredl): when we implement borders around floating windows, then
			// msgsep can just be a border "around" the message grid.
			grid = (^ScreenGrid)(&msg_grid_u8)
			msg_sep_attr := i32(hl_attr_active_g[HLF_MSGSEP_O])
			for i := col; i < until; i += 1 {
				uc_linebuf_g[uintptr(i - startcol)] = uc_msg_sep_char_g
				uc_attrbuf_g[uintptr(i - startcol)] = msg_sep_attr
			}
		} else {
			off := uintptr(grid.line_offset[uintptr(row - grid.comp_row)]) + uintptr(col - grid.comp_col)
			libc.memmove(rawptr(uintptr(uc_linebuf_g) + uintptr(col - startcol) * 4), rawptr(uintptr(grid.chars) + off * 4), C.size_t(n) * 4)
			libc.memmove(rawptr(uintptr(uc_attrbuf_g) + uintptr(col - startcol) * 4), rawptr(uintptr(grid.attrs) + off * 4), C.size_t(n) * 4)
			if grid.comp_col + grid.cols > until && grid.chars[off + uintptr(n)] == 0 {
				uc_linebuf_g[uintptr(until - 1 - startcol)] = 32
				if col == startcol && n == 1 {
					skipstart = 0
				}
			}
		}
		// 'pumblend' and 'winblend'
		if grid.blending {
			width: C.int = 1
			for i := col - startcol; i < until - startcol; i += width {
				width = 1
				// negative space
				thru := (uc_linebuf_g[uintptr(i)] == 32 || uc_linebuf_g[uintptr(i)] == schar_from_char(0x2800)) && bg_base[bg_off + uintptr(i)] != 0
				if i + 1 < endcol - startcol && bg_base[bg_off + uintptr(i) + 1] == 0 {
					width = 2
					thru = thru && (uc_linebuf_g[uintptr(i) + 1] == 32 || uc_linebuf_g[uintptr(i) + 1] == schar_from_char(0x2800))
				}
				uc_attrbuf_g[uintptr(i)] = i32(hl_blend_attrs_r(C.int(bg_attrs_base[bg_off + uintptr(i)]), C.int(uc_attrbuf_g[uintptr(i)]), &thru))
				if width == 2 {
					uc_attrbuf_g[uintptr(i) + 1] = i32(hl_blend_attrs_r(C.int(bg_attrs_base[bg_off + uintptr(i) + 1]), C.int(uc_attrbuf_g[uintptr(i) + 1]), &thru))
				}
				if thru {
					libc.memmove(rawptr(uintptr(uc_linebuf_g) + uintptr(i) * 4), rawptr(uintptr(bg_base) + (bg_off + uintptr(i)) * 4), C.size_t(width) * 4)
				}
			}
		}
		// Tricky: if overlap caused a doublewidth char to get cut-off, must
		// replace the visible half with a space.
		if uc_linebuf_g[uintptr(col - startcol)] == 0 {
			uc_linebuf_g[uintptr(col - startcol)] = 32
			if col == endcol - 1 {
				skipend = 0
			}
		} else if col == startcol && n > 1 && uc_linebuf_g[1] == 0 {
			skipstart = 0
		}
		col = until
	}
	if uc_linebuf_g[uintptr(endcol - startcol) - 1] == 0 {
		skipend = 0
	}
	if !(endcol <= uc_chk_width_g) {
		libc.abort()
	}
	if !(C.int(row_in) < uc_chk_height_g) {
		libc.abort()
	}
	if !(grid != nil && (grid == (^ScreenGrid)(&default_grid_u8) || (grid.comp_col == 0 && grid.cols == Columns))) {
		flags = flags & ~KLINEFLAG_WRAP_O
	}
	for i := skipstart; i < (endcol - skipend) - startcol; i += 1 {
		if uc_attrbuf_g[uintptr(i)] < 0 {
			if rdb_flags_g & KOPTRDB_INVALID_O != 0 {
				libc.abort()
			} else {
				uc_attrbuf_g[uintptr(i)] = 0
			}
		}
	}
	ui_composed_call_raw_line(1, i64(row), i64(startcol + skipstart), i64(endcol - skipend), i64(endcol - skipend), 0, flags, (^u32)(rawptr(uintptr(uc_linebuf_g) + uintptr(skipstart) * 4)), (^C.int32_t)(rawptr(uintptr(uc_attrbuf_g) + uintptr(skipstart) * 4)))
}

compose_debug_o :: proc "c" (startrow: C.longlong, endrow_in: C.longlong, startcol: C.longlong, endcol_in: C.longlong, syn_id: C.int, delay: bool) {
	context = runtime.default_context()
	if rdb_flags_g & KOPTRDB_COMPOSITOR_O == 0 || startcol >= endcol_in {
		return
	}
	dg := (^ScreenGrid)(&default_grid_u8)
	endrow := min(endrow_in, C.longlong(dg.rows))
	endcol := min(endcol_in, C.longlong(dg.cols))
	attr := syn_id2attr_r(syn_id)
	if delay {
		debug_delay_o(endrow - startrow)
	}
	for row := C.int(startrow); C.longlong(row) < endrow; row += 1 {
		ui_composed_call_raw_line(1, i64(row), i64(startcol), i64(startcol), i64(endcol), i64(attr), 0, uc_linebuf_g, (^C.int32_t)(uc_attrbuf_g))
	}
	if delay {
		debug_delay_o(endrow - startrow)
	}
}

debug_delay_o :: proc "c" (lines: C.longlong) {
	context = runtime.default_context()
	ui_call_flush()
	wd: u64
	if p_wd_g >= 0 {
		wd = u64(p_wd_g)
	} else {
		wd = u64(-p_wd_g)
	}
	n := lines
	if n > 5 {
		n = 5
	}
	if n < 1 {
		n = 1
	}
	os_sleep(u64(n) * wd)
}

compose_area_o :: proc "c" (startrow: C.int, endrow_in: C.int, startcol: C.int, endcol_in: C.int) {
	context = runtime.default_context()
	compose_debug_o(C.longlong(startrow), C.longlong(endrow_in), C.longlong(startcol), C.longlong(endcol_in), uc_dbghl_recompose_g, true)
	dg := (^ScreenGrid)(&default_grid_u8)
	endrow := min(endrow_in, dg.rows)
	endcol := min(endcol_in, dg.cols)
	if endcol <= startcol {
		return
	}
	for r := startrow; r < endrow; r += 1 {
		compose_line_o(C.longlong(r), C.longlong(startcol), C.longlong(endcol), KLINEFLAG_INVALID_O)
	}
}

// compose the area under the grid.
//
// This is needed when some option affecting composition is changed,
// such as 'pumblend' for popupmenu grid.
@(export)
ui_comp_compose_grid :: proc "c" (grid: ^ScreenGrid) {
	context = runtime.default_context()
	if ui_comp_should_draw() {
		compose_area_o(grid.comp_row, grid.comp_row + grid.rows, grid.comp_col, grid.comp_col + grid.cols)
	}
}

@(export)
ui_comp_raw_line :: proc "c" (grid_in: C.longlong, row_in: C.longlong, startcol_in: C.longlong, endcol_in: C.longlong, clearcol_in: C.longlong, clearattr: C.longlong, flags_in: C.int, chunk: ^u32, attrs: ^i32) {
	context = runtime.default_context()
	if !ui_comp_should_draw() || !ui_comp_set_grid(C.int(grid_in)) {
		return
	}
	row := row_in + C.longlong(uc_curgrid_g.comp_row)
	startcol := startcol_in + C.longlong(uc_curgrid_g.comp_col)
	endcol := endcol_in + C.longlong(uc_curgrid_g.comp_col)
	clearcol := clearcol_in + C.longlong(uc_curgrid_g.comp_col)
	flags := flags_in
	if uc_curgrid_g != (^ScreenGrid)(&default_grid_u8) {
		flags = flags & ~KLINEFLAG_WRAP_O
	}
	if !(endcol <= clearcol) {
		libc.abort()
	}
	// TODO(bfredl): this should not really be necessary. But on some condition
	// when resizing nvim, a window will be attempted to be drawn on the older
	// and possibly larger global screen size.
	dg := (^ScreenGrid)(&default_grid_u8)
	if row >= C.longlong(dg.rows) {
		return
	}
	if clearcol > C.longlong(dg.cols) {
		if startcol >= C.longlong(dg.cols) {
			return
		}
		clearcol = C.longlong(dg.cols)
		endcol = min(endcol, clearcol)
	}
	covered := curgrid_covered_above_o(C.int(row), C.int(row), C.int(startcol), C.int(clearcol))
	// TODO(bfredl): eventually should just fix compose_line to respect clearing
	// and optimize it for uncovered lines.
	if (flags & KLINEFLAG_INVALID_O) != 0 || covered || uc_curgrid_g.blending {
		compose_debug_o(row, row + 1, startcol, clearcol, uc_dbghl_composed_g, true)
		compose_line_o(row, startcol, clearcol, flags)
	} else {
		compose_debug_o(row, row + 1, startcol, endcol, uc_dbghl_normal_g, endcol >= clearcol)
		compose_debug_o(row, row + 1, endcol, clearcol, uc_dbghl_clear_g, true)
		for i: C.longlong = 0; i < endcol - startcol; i += 1 {
			if ([^]i32)(rawptr(attrs))[uintptr(i)] < 0 {
				libc.abort()
			}
		}
		ui_composed_call_raw_line(1, row, startcol, endcol, clearcol, clearattr, flags, chunk, attrs)
	}
}

@(export)
ui_comp_msg_set_pos :: proc "c" (grid: C.longlong, row: C.longlong, scrolled: bool, sep_char: NvimString, zindex: C.longlong, compindex: C.longlong) {
	context = runtime.default_context()
	mg := (^ScreenGrid)(&msg_grid_u8)
	mg.pending_comp_index_update = true
	mg.comp_row = C.int(row)
	if scrolled && row > 0 {
		uc_msg_sep_row_g = C.int(row) - 1
		if sep_char.data != nil {
			uc_msg_sep_char_g = schar_from_buf(transmute(^u8)(sep_char.data), sep_char.size)
		}
	} else {
		uc_msg_sep_row_g = -1
	}
	if row > C.longlong(uc_msg_current_row_g) && ui_comp_should_draw() {
		dg := (^ScreenGrid)(&default_grid_u8)
		compose_area_o(max(uc_msg_current_row_g - 1, 0), C.int(row), 0, dg.cols)
	} else if row < C.longlong(uc_msg_current_row_g) && ui_comp_should_draw() && (uc_msg_current_row_g < Rows || (scrolled && !uc_msg_was_scrolled_g)) {
		delta := uc_msg_current_row_g - C.int(row)
		if mg.blending {
			first_row := C.int(row)
			if scrolled {
				first_row -= 1
			}
			if first_row < 0 {
				first_row = 0
			}
			compose_area_o(first_row, Rows - delta, 0, Columns)
		} else {
			// scroll separator together with message text
			first_row := C.int(row)
			if uc_msg_was_scrolled_g {
				first_row -= 1
			}
			if first_row < 0 {
				first_row = 0
			}
			ui_composed_call_grid_scroll(1, i64(first_row), i64(Rows), 0, i64(Columns), i64(delta), 0)
			if scrolled && !uc_msg_was_scrolled_g && row > 0 {
				compose_area_o(C.int(row) - 1, C.int(row), 0, Columns)
			}
		}
	}
	uc_msg_current_row_g = C.int(row)
	uc_msg_was_scrolled_g = scrolled
}

// check if curgrid is covered by any other grid within the rectangle
curgrid_covered_above_o :: proc "c" (top: C.int, bot: C.int, left: C.int, right: C.int) -> bool {
	context = runtime.default_context()
	// check all layers above curgrid. if any intersect with the given rectangle, then consider the
	// curgrid covered. account for the msg_sep_row if the msg_grid layer was scrolled.
	for i := uc_curgrid_g.comp_index + 1; i < uc_layers_size_g; i += 1 {
		g := uc_layers_items_g[i]
		grid_top := g.comp_row
		if g == (^ScreenGrid)(&msg_grid_u8) && uc_msg_was_scrolled_g {
			grid_top -= 1
		}
		grid_bot := g.comp_row + g.comp_height - 1
		grid_left := g.comp_col
		grid_right := g.comp_col + g.comp_width - 1
		if right >= grid_left && left <= grid_right && bot >= grid_top && top <= grid_bot {
			return true
		}
	}
	return false
}

@(export)
ui_comp_grid_scroll :: proc "c" (grid: C.longlong, top_in: C.longlong, bot_in: C.longlong, left_in: C.longlong, right_in: C.longlong, rows: C.longlong, cols: C.longlong) {
	context = runtime.default_context()
	if !ui_comp_should_draw() || !ui_comp_set_grid(C.int(grid)) {
		return
	}
	top := top_in + C.longlong(uc_curgrid_g.comp_row)
	bot := bot_in + C.longlong(uc_curgrid_g.comp_row)
	left := left_in + C.longlong(uc_curgrid_g.comp_col)
	right := right_in + C.longlong(uc_curgrid_g.comp_col)
	covered := curgrid_covered_above_o(C.int(top), C.int(bot), C.int(left), C.int(right))
	if covered || uc_curgrid_g.blending {
		// TODO(bfredl):
		// 1. check if rectangles actually overlap
		// 2. calculate subareas that can scroll.
		compose_debug_o(top, bot, left, right, uc_dbghl_recompose_g, true)
		for r := top + max(-rows, C.longlong(0)); r < bot - max(rows, C.longlong(0)); r += 1 {
			// TODO(bfredl): workaround for win_update() performing two scrolls in a
			// row, where the latter might scroll invalid space created by the first.
			// ideally win_update() should keep track of this itself and not scroll
			// the invalid space.
			off := uintptr(uc_curgrid_g.line_offset[uintptr(C.int(r) - uc_curgrid_g.comp_row)]) + uintptr(C.int(left) - uc_curgrid_g.comp_col)
			if uc_curgrid_g.attrs[off] >= 0 {
				compose_line_o(r, left, right, 0)
			}
		}
	} else {
		ui_composed_call_grid_scroll(1, top, bot, left, right, rows, cols)
		if rdb_flags_g & KOPTRDB_COMPOSITOR_O != 0 {
			debug_delay_o(2)
		}
	}
}

@(export)
ui_comp_grid_resize :: proc "c" (grid: C.longlong, width: C.longlong, height: C.longlong) {
	context = runtime.default_context()
	if grid == 1 {
		ui_composed_call_grid_resize(1, width, height)
		uc_chk_width_g = C.int(width)
		uc_chk_height_g = C.int(height)
		new_bufsize := C.size_t(width)
		if uc_bufsize_g != new_bufsize {
			xfree(rawptr(uc_linebuf_g))
			xfree(rawptr(uc_attrbuf_g))
			uc_linebuf_g = ([^]u32)(xmalloc(new_bufsize * 4))
			uc_attrbuf_g = ([^]i32)(xmalloc(new_bufsize * 4))
			uc_bufsize_g = new_bufsize
		}
	}
}
