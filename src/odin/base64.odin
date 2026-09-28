package main

import C "core:c"
import "core:c/libc"
import "base:runtime"

// base64.c port (Batch M2): base64 codec, no Neovim dependencies.
// Both exports; C file moved to bak/base64.c. Little-endian byte swaps are
// explicit (ODIN_ENDIAN guard, grid.odin Batch 1 precedent).

B64_ALPHABET_S :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// 1-based alphabet index (0 = not in alphabet; mirrors char_to_index table).
b64_index_o :: proc "c" (c: u8) -> u8 {
	context = runtime.default_context()
	if c >= 'A' && c <= 'Z' {
		return c - 'A' + 1
	}
	if c >= 'a' && c <= 'z' {
		return c - 'a' + 27
	}
	if c >= '0' && c <= '9' {
		return c - '0' + 53
	}
	if c == '+' {
		return 63
	}
	if c == '/' {
		return 64
	}
	return 0
}

// Host-to-big-endian (little-endian branch; x86_64 target).
b64_htobe64_o :: proc "c" (x: u64) -> u64 {
	context = runtime.default_context()
	when ODIN_ENDIAN == .Little {
		b := transmute([8]u8)(x)
		return u64(b[0]) << 56 | u64(b[1]) << 48 | u64(b[2]) << 40 | u64(b[3]) << 32 | u64(b[4]) << 24 | u64(b[5]) << 16 | u64(b[6]) << 8 | u64(b[7])
	} else {
		return x
	}
}

// Host-to-big-endian 32-bit (little-endian branch).
b64_htobe32_o :: proc "c" (x: u32) -> u32 {
	context = runtime.default_context()
	when ODIN_ENDIAN == .Little {
		b := transmute([4]u8)(x)
		return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	} else {
		return x
	}
}

// Base64 encoder (base64.c public).
@(export)
base64_encode :: proc "c" (src: cstring, src_len: C.size_t) -> ^u8 {
	context = runtime.default_context()
	if src == nil {
		libc.abort()
	}
	n := uint(src_len)
	out_len := ((n + 2) / 3) * 4
	dest := transmute([^]u8)(xmalloc(C.size_t(out_len + 1)))
	s := transmute([^]u8)(src)
	alpha := transmute([^]u8)(cstring(B64_ALPHABET_S))
	src_i: uint = 0
	out_i: uint = 0
	for src_i + 7 < n {
		bits_h: u64 = 0
		libc.memcpy(rawptr(&bits_h), rawptr(&s[src_i]), 8)
		bits_be := b64_htobe64_o(bits_h)
		dest[out_i + 0] = alpha[(bits_be >> 58) & 0x3F]
		dest[out_i + 1] = alpha[(bits_be >> 52) & 0x3F]
		dest[out_i + 2] = alpha[(bits_be >> 46) & 0x3F]
		dest[out_i + 3] = alpha[(bits_be >> 40) & 0x3F]
		dest[out_i + 4] = alpha[(bits_be >> 34) & 0x3F]
		dest[out_i + 5] = alpha[(bits_be >> 28) & 0x3F]
		dest[out_i + 6] = alpha[(bits_be >> 22) & 0x3F]
		dest[out_i + 7] = alpha[(bits_be >> 16) & 0x3F]
		src_i += 6
		out_i += 8
	}
	for src_i + 3 < n {
		bits_h: u32 = 0
		libc.memcpy(rawptr(&bits_h), rawptr(&s[src_i]), 4)
		bits_be := b64_htobe32_o(bits_h)
		dest[out_i + 0] = alpha[(bits_be >> 26) & 0x3F]
		dest[out_i + 1] = alpha[(bits_be >> 20) & 0x3F]
		dest[out_i + 2] = alpha[(bits_be >> 14) & 0x3F]
		dest[out_i + 3] = alpha[(bits_be >> 8) & 0x3F]
		src_i += 3
		out_i += 4
	}
	if src_i + 2 < n {
		dest[out_i + 0] = alpha[s[src_i] >> 2]
		dest[out_i + 1] = alpha[((s[src_i] & 0x3) << 4) | (s[src_i + 1] >> 4)]
		dest[out_i + 2] = alpha[(s[src_i + 1] & 0xF) << 2 | (s[src_i + 2] >> 6)]
		dest[out_i + 3] = alpha[(s[src_i + 2] & 0x3F)]
		out_i += 4
	} else if src_i + 1 < n {
		dest[out_i + 0] = alpha[s[src_i] >> 2]
		dest[out_i + 1] = alpha[((s[src_i] & 0x3) << 4) | (s[src_i + 1] >> 4)]
		dest[out_i + 2] = alpha[(s[src_i + 1] & 0xF) << 2]
		out_i += 3
	} else if src_i < n {
		dest[out_i + 0] = alpha[s[src_i] >> 2]
		dest[out_i + 1] = alpha[(s[src_i] & 0x3) << 4]
		out_i += 2
	}
	for out_i < out_len {
		dest[out_i] = '='
		out_i += 1
	}
	dest[out_len] = 0
	return &dest[0]
}

// Base64 decoder (base64.c public; output NOT NUL-terminated).
@(export)
base64_decode :: proc "c" (src: cstring, src_len: C.size_t, out_lenp: ^C.size_t) -> ^u8 {
	context = runtime.default_context()
	if src == nil || out_lenp == nil {
		libc.abort()
	}
	n := uint(src_len)
	dest: [^]u8 = nil
	failed := false
	out_len: uint = 0
	if n % 4 != 0 {
		failed = true
	} else {
		out_len = (n / 4) * 3
		if n >= 1 && ([^]u8)(src)[n - 1] == '=' {
			out_len -= 1
		}
		if n >= 2 && ([^]u8)(src)[n - 2] == '=' {
			out_len -= 1
		}
		s := transmute([^]u8)(src)
		dest = transmute([^]u8)(xmalloc(C.size_t(out_len)))
		acc: C.int = 0
		acc_len: C.int = 0
		out_i: uint = 0
		src_i: uint = 0
		leftover_i: C.int = -1
		for src_i < n && !failed {
			c := s[src_i]
			d := b64_index_o(c)
			if d == 0 {
				if c == '=' {
					leftover_i = C.int(src_i)
					break
				}
				failed = true
			} else {
				acc = ((acc << 6) & 0xFFF) + C.int(d) - 1
				acc_len += 6
				if acc_len >= 8 {
					acc_len -= 8
					dest[out_i] = u8(acc >> u32(acc_len))
					out_i += 1
				}
			}
			src_i += 1
		}
		if !failed {
			if acc_len > 4 || ((acc & ((1 << u32(acc_len)) - 1)) != 0) {
				failed = true
			}
		}
		if !failed && leftover_i > -1 {
			padding_len := acc_len / 2
			padding_chars: C.int = 0
			li := uint(leftover_i)
			for li < n && !failed {
				if s[li] != '=' {
					failed = true
				}
				padding_chars += 1
				li += 1
			}
			if !failed && padding_chars != padding_len {
				failed = true
			}
		}
	}
	if failed {
		if dest != nil {
			xfree(rawptr(dest))
		}
		out_lenp^ = 0
		return nil
	}
	out_lenp^ = C.size_t(out_len)
	return &dest[0]
}
