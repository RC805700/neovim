package main

import C "core:c"
import "base:runtime"
import "core:c/libc"

// sha256.c port: FIPS-180-2 SHA-256, zero Neovim dependencies.
// All 6 exports; C file moved to bak/sha256.c. The 64 unrolled P() rounds
// are a rotation loop (provably identical order); K table transcribed once
// and verified by the self-test + FIPS vectors below.

SHA256_BUFFER_SIZE_O :: 64
SHA256_SUM_SIZE_O :: 32
SHA_STEP_O :: 2

Sha256_Ctx :: struct {
	total:  [2]u32,  // @0
	state:  [8]u32,  // @8
	buffer: [64]u8,  // @40
}
#assert(size_of(Sha256_Ctx) == 104)

// Round constants (FIPS-180-2, transcribed from the P() lines).
SHA256_K := [64]u32{
	0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
	0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
	0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
	0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
	0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
	0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
	0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
	0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
	0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
	0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
	0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
	0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
	0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
	0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
	0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
	0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
}

@(private = "file")
sha256_hexit_g: [SHA256_BUFFER_SIZE_O + 1]u8
@(private = "file")
sha256_padding_g: [SHA256_BUFFER_SIZE_O]u8
@(private = "file")
sha256_tested_g: bool
@(private = "file")
sha256_failures_g: bool

sha256_rotr :: #force_inline proc "c" (x: u32, n: u32) -> u32 {
	return (x >> n) | (x << (32 - n))
}

// Block compressor (C-static; plain proc).
sha256_process_o :: proc "c" (ctx: ^Sha256_Ctx, data: ^u8) {
	context = runtime.default_context()
	d := ([^]u8)(data)
	W: [SHA256_BUFFER_SIZE_O]u32
	for i in 0..<16 {
		W[i] = u32(d[i*4]) << 24 | u32(d[i*4 + 1]) << 16 | u32(d[i*4 + 2]) << 8 | u32(d[i*4 + 3])
	}
	s0 := proc(x: u32) -> u32 {
		return sha256_rotr(x, 7) ~ sha256_rotr(x, 18) ~ (x >> 3)
	}
	s1 := proc(x: u32) -> u32 {
		return sha256_rotr(x, 17) ~ sha256_rotr(x, 19) ~ (x >> 10)
	}
	s2 := proc(x: u32) -> u32 {
		return sha256_rotr(x, 2) ~ sha256_rotr(x, 13) ~ sha256_rotr(x, 22)
	}
	s3 := proc(x: u32) -> u32 {
		return sha256_rotr(x, 6) ~ sha256_rotr(x, 11) ~ sha256_rotr(x, 25)
	}
	a := ctx.state[0]
	b := ctx.state[1]
	c := ctx.state[2]
	d0 := ctx.state[3]
	e := ctx.state[4]
	f := ctx.state[5]
	g := ctx.state[6]
	h := ctx.state[7]
	for t in 0..<64 {
		x := W[t]
		if t >= 16 {
			x = s1(W[t - 2]) + W[t - 7] + s0(W[t - 15]) + W[t - 16]
			W[t] = x
		}
		t1 := h + s3(e) + (g ~ (e & (f ~ g))) + SHA256_K[t] + x
		t2 := s2(a) + ((a & b) | (c & (a | b)))
		d0 += t1
		h = t1 + t2
		// Rotate to match C's P() argument rotation:
		// (a,b,c,d,e,f,g,h) -> (t1+t2, a, b, c, d+t1, e, f, g).
		na := t1 + t2
		nb := a
		nc := b
		nd := c
		ne := d0
		nf := e
		ng := f
		nh := g
		a, b, c, d0, e, f, g, h = na, nb, nc, nd, ne, nf, ng, nh
	}
	ctx.state[0] += a
	ctx.state[1] += b
	ctx.state[2] += c
	ctx.state[3] += d0
	ctx.state[4] += e
	ctx.state[5] += f
	ctx.state[6] += g
	ctx.state[7] += h
}

// Context initializer (sha256.c public).
@(export)
sha256_start :: proc "c" (ctx: ^Sha256_Ctx) {
	context = runtime.default_context()
	ctx.total[0] = 0
	ctx.total[1] = 0
	ctx.state[0] = 0x6A09E667
	ctx.state[1] = 0xBB67AE85
	ctx.state[2] = 0x3C6EF372
	ctx.state[3] = 0xA54FF53A
	ctx.state[4] = 0x510E527F
	ctx.state[5] = 0x9B05688C
	ctx.state[6] = 0x1F83D9AB
	ctx.state[7] = 0x5BE0CD19
}

// Streaming updater (sha256.c public).
@(export)
sha256_update :: proc "c" (ctx: ^Sha256_Ctx, input: ^u8, length: C.size_t) {
	context = runtime.default_context()
	if length == 0 {
		return
	}
	left := ctx.total[0] & (SHA256_BUFFER_SIZE_O - 1)
	ctx.total[0] += u32(length)
	if ctx.total[0] < u32(length) {
		ctx.total[1] += 1
	}
	fill := C.size_t(SHA256_BUFFER_SIZE_O) - C.size_t(left)
	inp := input
	n := length
	if left != 0 && n >= fill {
		libc.memcpy(rawptr(uintptr(&ctx.buffer[0]) + uintptr(left)), rawptr(inp), C.size_t(fill))
		sha256_process_o(ctx, &ctx.buffer[0])
		n -= fill
		inp = (^u8)(uintptr(inp) + uintptr(fill))
		left = 0
	}
	for n >= SHA256_BUFFER_SIZE_O {
		sha256_process_o(ctx, inp)
		n -= SHA256_BUFFER_SIZE_O
		inp = (^u8)(uintptr(inp) + SHA256_BUFFER_SIZE_O)
	}
	if n != 0 {
		libc.memcpy(rawptr(uintptr(&ctx.buffer[0]) + uintptr(left)), rawptr(inp), C.size_t(n))
	}
}

// Finalizer with bit-length padding (sha256.c public).
@(export)
sha256_finish :: proc "c" (ctx: ^Sha256_Ctx, digest: ^u8) {
	context = runtime.default_context()
	high := (ctx.total[0] >> 29) | (ctx.total[1] << 3)
	low := ctx.total[0] << 3
	msglen: [8]u8
	msglen[0] = u8(high >> 24)
	msglen[1] = u8(high >> 16)
	msglen[2] = u8(high >> 8)
	msglen[3] = u8(high)
	msglen[4] = u8(low >> 24)
	msglen[5] = u8(low >> 16)
	msglen[6] = u8(low >> 8)
	msglen[7] = u8(low)
	last := ctx.total[0] & 0x3F
	padn := u32(120) - last
	if last < 56 {
		padn = 56 - last
	}
	sha256_padding_g[0] = 0x80
	sha256_update(ctx, &sha256_padding_g[0], C.size_t(padn))
	sha256_update(ctx, &msglen[0], 8)
	out := ([^]u8)(digest)
	for i in 0..<8 {
		out[i*4] = u8(ctx.state[i] >> 24)
		out[i*4 + 1] = u8(ctx.state[i] >> 16)
		out[i*4 + 2] = u8(ctx.state[i] >> 8)
		out[i*4 + 3] = u8(ctx.state[i])
	}
}

// Hex digest of buffer (+ optional salt) in static storage (sha256.c public).
@(export)
sha256_bytes :: proc "c" (buf: ^u8, buf_len: C.size_t, salt: ^u8, salt_len: C.size_t) -> cstring {
	context = runtime.default_context()
	sha256_self_test()
	ctx: Sha256_Ctx
	sha256_start(&ctx)
	sha256_update(&ctx, buf, buf_len)
	if salt != nil {
		sha256_update(&ctx, salt, salt_len)
	}
	sum: [SHA256_SUM_SIZE_O]u8
	sha256_finish(&ctx, &sum[0])
	for j: C.size_t = 0; j < SHA256_SUM_SIZE_O; j += 1 {
		libc.snprintf(&sha256_hexit_g[j*SHA_STEP_O], C.size_t(3), cstring("%02x"), C.int(sum[j]))
	}
	sha256_hexit_g[len(sha256_hexit_g) - 1] = 0
	return transmute(cstring)(&sha256_hexit_g[0])
}

// FIPS-180-2 self test, runs once (sha256.c public).
@(export)
sha256_self_test :: proc "c" () -> bool {
	context = runtime.default_context()
	if sha256_tested_g {
		return !sha256_failures_g
	}
	sha256_tested_g = true
	msgs := [2]cstring{
		"abc",
		"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
	}
	vectors := [3]cstring{
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
		"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
	}
	output: [SHA256_BUFFER_SIZE_O + 1]u8
	for i in 0..<3 {
		if i < 2 {
			hexit := sha256_bytes(transmute(^u8)(msgs[i]), libc.strlen(msgs[i]), nil, 0)
			libc.memcpy(rawptr(&output[0]), rawptr(hexit), C.size_t(len(output)))
		} else {
			ctx: Sha256_Ctx
			buf: [1000]u8
			sum: [SHA256_SUM_SIZE_O]u8
			sha256_start(&ctx)
			libc.memset(rawptr(&buf[0]), 'a', C.size_t(len(buf)))
			for j in 0..<1000 {
				sha256_update(&ctx, &buf[0], 1000)
			}
			sha256_finish(&ctx, &sum[0])
			for j: C.size_t = 0; j < SHA256_SUM_SIZE_O; j += 1 {
				libc.snprintf(&output[j*SHA_STEP_O], C.size_t(3), cstring("%02x"), C.int(sum[j]))
			}
		}
		if libc.memcmp(rawptr(&output[0]), rawptr(vectors[i]), C.size_t(SHA256_BUFFER_SIZE_O)) != 0 {
			sha256_failures_g = true
			output[len(output) - 1] = 0
		}
	}
	return !sha256_failures_g
}
