package main

import C "core:c"
import "core:intrinsics"
import "base:runtime"

// math.c port (Batch M1): pure bit/float helpers, zero Neovim dependencies.
// All 7 exports; C file moved to bak/math.c. cc-probed FP_* (glibc math.h).

FP_ZERO_O :: 2
FP_SUBNORMAL_O :: 3
FP_NORMAL_O :: 4

// Float classifier (math.c public).
@(export)
xfpclassify :: proc "c" (d: f64) -> C.int {
	context = runtime.default_context()
	m := transmute(u64)(d)
	e := u64(0x7ff) & (m >> 52)
	m = u64(0xfffffffffffff) & m
	if e == 0x000 {
		if m != 0 {
			return FP_SUBNORMAL_O
		}
		return FP_ZERO_O
	} else if e == 0x7ff {
		if m != 0 {
			return FP_NAN_O
		}
		return FP_INFINITE_O
	}
	return FP_NORMAL_O
}

// Infinity test (math.c public).
@(export)
xisinf :: proc "c" (d: f64) -> C.int {
	context = runtime.default_context()
	if xfpclassify(d) == FP_INFINITE_O {
		return 1
	}
	return 0
}

// NaN test (math.c public).
@(export)
xisnan :: proc "c" (d: f64) -> C.int {
	context = runtime.default_context()
	if xfpclassify(d) == FP_NAN_O {
		return 1
	}
	return 0
}

// Trailing-zero counter (math.c public).
@(export)
xctz :: proc "c" (x: u64) -> C.int {
	context = runtime.default_context()
	if x == 0 {
		return 64
	}
	return C.int(intrinsics.count_trailing_zeros(x))
}

// Population counter (math.c public).
@(export)
xpopcount :: proc "c" (x: u64) -> C.uint {
	context = runtime.default_context()
	return C.uint(intrinsics.count_ones(x))
}

// Overflow-checked digit append (math.c public).
@(export)
vim_append_digit_int :: proc "c" (value: ^C.int, digit: C.int) -> C.int {
	context = runtime.default_context()
	x := value^
	if x > (max(C.int) - digit) / 10 {
		return FAIL_E
	}
	value^ = x * 10 + digit
	return OK_E
}

// Int64 clamp to int (math.c public).
@(export)
trim_to_int :: proc "c" (x: C.longlong) -> C.int {
	context = runtime.default_context()
	if x > C.longlong(max(C.int)) {
		return max(C.int)
	}
	if x < C.longlong(min(C.int)) {
		return min(C.int)
	}
	return C.int(x)
}
