// arabic.odin — port of src/nvim/arabic.c (Arabic shaping, 344 lines)
package main

import C "core:c"

// ── Batch 2a: full arabic.c port ────────────────────────────────────────────
// Single export cluster (maycombine/combine/shape); everything else is a
// file-private/plain helper mirroring C's statics.

foreign _ {
	@(link_name = "p_arshape")
	p_arshape_g: C.int
	@(link_name = "p_tbidi")
	p_tbidi_g: C.int
}

Achar_T :: struct {
	c:        u32,
	isolated: u32,
	initial:  u32,
	medial:   u32,
	final:    u32,
}

// Sorted presentation-forms table (arabic.c:102-157, verbatim values).
@(private="file")
achars_f: [54]Achar_T = {
	{ 0x0621, 0xfe80, 0, 0, 0 },
	{ 0x0622, 0xfe81, 0, 0, 0xfe82 },
	{ 0x0623, 0xfe83, 0, 0, 0xfe84 },
	{ 0x0624, 0xfe85, 0, 0, 0xfe86 },
	{ 0x0625, 0xfe87, 0, 0, 0xfe88 },
	{ 0x0626, 0xfe89, 0xfe8b, 0xfe8c, 0xfe8a },
	{ 0x0627, 0xfe8d, 0, 0, 0xfe8e },
	{ 0x0628, 0xfe8f, 0xfe91, 0xfe92, 0xfe90 },
	{ 0x0629, 0xfe93, 0, 0, 0xfe94 },
	{ 0x062a, 0xfe95, 0xfe97, 0xfe98, 0xfe96 },
	{ 0x062b, 0xfe99, 0xfe9b, 0xfe9c, 0xfe9a },
	{ 0x062c, 0xfe9d, 0xfe9f, 0xfea0, 0xfe9e },
	{ 0x062d, 0xfea1, 0xfea3, 0xfea4, 0xfea2 },
	{ 0x062e, 0xfea5, 0xfea7, 0xfea8, 0xfea6 },
	{ 0x062f, 0xfea9, 0, 0, 0xfeaa },
	{ 0x0630, 0xfeab, 0, 0, 0xfeac },
	{ 0x0631, 0xfead, 0, 0, 0xfeae },
	{ 0x0632, 0xfeaf, 0, 0, 0xfeb0 },
	{ 0x0633, 0xfeb1, 0xfeb3, 0xfeb4, 0xfeb2 },
	{ 0x0634, 0xfeb5, 0xfeb7, 0xfeb8, 0xfeb6 },
	{ 0x0635, 0xfeb9, 0xfebb, 0xfebc, 0xfeba },
	{ 0x0636, 0xfebd, 0xfebf, 0xfec0, 0xfebe },
	{ 0x0637, 0xfec1, 0xfec3, 0xfec4, 0xfec2 },
	{ 0x0638, 0xfec5, 0xfec7, 0xfec8, 0xfec6 },
	{ 0x0639, 0xfec9, 0xfecb, 0xfecc, 0xfeca },
	{ 0x063a, 0xfecd, 0xfecf, 0xfed0, 0xfece },
	{ 0x0640, 0, 0x0640, 0x0640, 0x0640 },
	{ 0x0641, 0xfed1, 0xfed3, 0xfed4, 0xfed2 },
	{ 0x0642, 0xfed5, 0xfed7, 0xfed8, 0xfed6 },
	{ 0x0643, 0xfed9, 0xfedb, 0xfedc, 0xfeda },
	{ 0x0644, 0xfedd, 0xfedf, 0xfee0, 0xfede },
	{ 0x0645, 0xfee1, 0xfee3, 0xfee4, 0xfee2 },
	{ 0x0646, 0xfee5, 0xfee7, 0xfee8, 0xfee6 },
	{ 0x0647, 0xfee9, 0xfeeb, 0xfeec, 0xfeea },
	{ 0x0648, 0xfeed, 0, 0, 0xfeee },
	{ 0x0649, 0xfeef, 0, 0, 0xfef0 },
	{ 0x064a, 0xfef1, 0xfef3, 0xfef4, 0xfef2 },
	{ 0x064b, 0xfe70, 0, 0, 0 },
	{ 0x064c, 0xfe72, 0, 0, 0 },
	{ 0x064d, 0xfe74, 0, 0, 0 },
	{ 0x064e, 0xfe76, 0, 0xfe77, 0 },
	{ 0x064f, 0xfe78, 0, 0xfe79, 0 },
	{ 0x0650, 0xfe7a, 0, 0xfe7b, 0 },
	{ 0x0651, 0xfe7c, 0, 0xfe7c, 0 },
	{ 0x0652, 0xfe7e, 0, 0xfe7f, 0 },
	{ 0x0653, 0, 0, 0, 0 },
	{ 0x0654, 0, 0, 0, 0 },
	{ 0x0655, 0, 0, 0, 0 },
	{ 0x067e, 0xfb56, 0xfb58, 0xfb59, 0xfb57 },
	{ 0x0686, 0xfb7a, 0xfb7c, 0xfb7d, 0xfb7b },
	{ 0x0698, 0xfb8a, 0, 0, 0xfb8b },
	{ 0x06a9, 0xfb8e, 0xfb90, 0xfb91, 0xfb8f },
	{ 0x06af, 0xfb92, 0xfb94, 0xfb95, 0xfb93 },
	{ 0x06cc, 0xfbfc, 0xfbfe, 0xfbff, 0xfbfd },
}

A_HAMZA_O :: 0x0621
A_ALEF_MADDA_O :: 0x0622
A_ALEF_HAMZA_ABOVE_O :: 0x0623
A_ALEF_HAMZA_BELOW_O :: 0x0625
A_ALEF_O :: 0x0627
A_LAM_O :: 0x0644
A_HAMZA_ABOVE_O :: 0x0654 // unused, documented for table readers
A_BYTE_ORDER_MARK_O :: 0xfeff

A_S_LAM_ALEF_MADDA_ABOVE_O :: 0xfef5
A_F_LAM_ALEF_MADDA_ABOVE_O :: 0xfef6
A_S_LAM_ALEF_HAMZA_ABOVE_O :: 0xfef7
A_F_LAM_ALEF_HAMZA_ABOVE_O :: 0xfef8
A_S_LAM_ALEF_HAMZA_BELOW_O :: 0xfef9
A_F_LAM_ALEF_HAMZA_BELOW_O :: 0xfefa
A_S_LAM_ALEF_O :: 0xfefb
A_F_LAM_ALEF_O :: 0xfefc

// Binary search over the sorted table (C static find_achar).
find_achar_o :: proc "c"(c: C.int) -> ^Achar_T {
	h := len(achars_f)
	l := 0
	for l < h {
		m := (h + l) / 2
		if achars_f[m].c == u32(c) {
			return &achars_f[m]
		}
		if u32(c) < achars_f[m].c {
			h = m
		} else {
			l = m + 1
		}
	}
	return nil
}

// Combination (2-char) → isolated ligature (C static chg_c_laa2i).
chg_c_laa2i_o :: proc "c"(hid_c: C.int) -> C.int {
	tempc: C.int = 0
	switch hid_c {
	case A_ALEF_MADDA_O:
		tempc = A_S_LAM_ALEF_MADDA_ABOVE_O
	case A_ALEF_HAMZA_ABOVE_O:
		tempc = A_S_LAM_ALEF_HAMZA_ABOVE_O
	case A_ALEF_HAMZA_BELOW_O:
		tempc = A_S_LAM_ALEF_HAMZA_BELOW_O
	case A_ALEF_O:
		tempc = A_S_LAM_ALEF_O
	}
	return tempc
}

// Combination-isolated → final ligature (C static chg_c_laa2f).
chg_c_laa2f_o :: proc "c"(hid_c: C.int) -> C.int {
	tempc: C.int = 0
	switch hid_c {
	case A_ALEF_MADDA_O:
		tempc = A_F_LAM_ALEF_MADDA_ABOVE_O
	case A_ALEF_HAMZA_ABOVE_O:
		tempc = A_F_LAM_ALEF_HAMZA_ABOVE_O
	case A_ALEF_HAMZA_BELOW_O:
		tempc = A_F_LAM_ALEF_HAMZA_BELOW_O
	case A_ALEF_O:
		tempc = A_F_LAM_ALEF_O
	}
	return tempc
}

// Whether two letters can join (C static can_join).
can_join_o :: proc "c"(c1: C.int, c2: C.int) -> C.int {
	a1 := find_achar_o(c1)
	a2 := find_achar_o(c2)
	if a1 != nil && a2 != nil &&
		(a1.initial != 0 || a1.medial != 0) &&
		(a2.final != 0 || a2.medial != 0) {
		return 1
	}
	return 0
}

// Whether `two` could combine with a preceding LAM.
@(export)
arabic_maycombine :: proc "c"(two: C.int) -> bool {
	if p_arshape_g != 0 && p_tbidi_g == 0 {
		return two == A_ALEF_MADDA_O ||
			two == A_ALEF_HAMZA_ABOVE_O ||
			two == A_ALEF_HAMZA_BELOW_O ||
			two == A_ALEF_O
	}
	return false
}

// Whether (one, two) form an Arabic combining pair (LAM + alef variant).
@(export)
arabic_combine :: proc "c"(one: C.int, two: C.int) -> bool {
	if one == A_LAM_O {
		return arabic_maycombine(two)
	}
	return false
}

// C statics as plain procs (called from proc "c" shape engine).
a_is_iso_o :: proc "c"(c: C.int) -> bool {
	return find_achar_o(c) != nil
}

a_is_ok_o :: proc "c"(c: C.int) -> bool {
	return a_is_iso_o(c) || c == A_BYTE_ORDER_MARK_O
}

a_is_valid_o :: proc "c"(c: C.int) -> bool {
	return a_is_ok_o(c) && c != A_HAMZA_O
}

// Shape character c given its neighbours. c1p is in/out (composing char).
@(export)
arabic_shape :: proc "c"(c: C.int, c1p: ^C.int, prev_c: C.int, prev_c1: C.int, next_c: C.int) -> C.int {
	// Non-Arabic passes through untouched.
	if !a_is_ok_o(c) {
		return c
	}

	curr_c: C.int = 0
	curr_laa := arabic_combine(c, c1p^)
	prev_laa := arabic_combine(prev_c, prev_c1)

	if curr_laa {
		if a_is_valid_o(prev_c) && can_join_o(prev_c, A_LAM_O) != 0 && !prev_laa {
			curr_c = chg_c_laa2f_o(c1p^)
		} else {
			curr_c = chg_c_laa2i_o(c1p^)
		}
		// Remove the composing character.
		c1p^ = 0
	} else {
		curr_a := find_achar_o(c)
		backward_combine: C.int = 0
		if !prev_laa && can_join_o(prev_c, c) != 0 {
			backward_combine = 1
		}
		forward_combine := can_join_o(c, next_c)

		if backward_combine != 0 {
			if forward_combine != 0 {
				curr_c = C.int(curr_a.medial)
			} else {
				curr_c = C.int(curr_a.final)
			}
		} else {
			if forward_combine != 0 {
				curr_c = C.int(curr_a.initial)
			} else {
				curr_c = C.int(curr_a.isolated)
			}
		}
	}

	// Missing from the table → keep the original character.
	if curr_c == 0 {
		curr_c = c
	}
	return curr_c
}
