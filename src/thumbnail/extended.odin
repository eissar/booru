package thumbnail

import "base:runtime"
import "core:mem"
// An extended format file consists of:
//
// A 'VP8X' Chunk with information about features used in the file.
// An optional 'ICCP' Chunk with a color profile.
// An optional 'ANIM' Chunk with animation control data.
// Image data.
// An optional 'EXIF' Chunk with Exif metadata.
// An optional 'XMP ' Chunk with XMP metadata.
// An optional list of unknown chunks (Section 2.7.1.6).

// the image data can have two different structures:
// Image type	Image data consists of
// Still WebP	VP8  or VP8L, optionally with ALPH
// if ANIM is present (always is for our use case)

// 'RIFF': 32 bits
// The ASCII characters 'R', 'I', 'F', 'F'.
// 'WEBP': 32 bits
// The ASCII characters 'W', 'E', 'B', 'P'.

// 2 | 1 | 1 | 1 | 1 | 1 | 1
WEBP_Flags :: enum u8 {
	Reserved = 0,
	Animated = 1,
	XMP      = 2,
	Exif     = 3,
	Alpha    = 4,
	ICC      = 5,
	_        = 6,
	_        = 7,
}


// Riff Extended Size
//
// our decided format:
// WEBP     12
// VP8X     18  (8 + 10)
// ANIM     14  (8 + 6)
RIFF_X_SIZE :: 12 + 18 + 14

Webp_Extended_Prefix :: struct {
	WEBP: [12]u8,
	VP8X: [18]u8,
	ANIM: [14]u8,
}

@(private = "file")
vec_push :: proc "contextless" (vec: [][]u8, idx: ^int, data: []u8) {
	context = runtime.default_context()
	vec[idx^] = data
	idx^ += 1
}


compute_extended_riff_size :: proc "contextless" (
	base_file_size, frame_count, image_chunks_size: int,
) -> u32le {
	base_payload_size := base_file_size - 8
	frame_headers_size := 24 * frame_count
	riff_size := base_payload_size + frame_headers_size + image_chunks_size
	return u32le(riff_size)
}


// v may be of fixed size. semantically , v=vectorized
// for use with writev later
Vectorized_Webp_Extended :: proc "contextless" (
	streams: []Chunk,
	v: ^[][]u8,
	p: ^Webp_Extended_Prefix,
	dims: ^[2][]u8, // 0=w,1=h
) {
	vec_idx := 0

	vec_push(v[:], &vec_idx, p.WEBP[:])
	vec_push(v[:], &vec_idx, p.VP8X[:])
	vec_push(v[:], &vec_idx, p.ANIM[:])

	for &chunk in streams {
		// bitstream means
		// vp8 without the prelude

		if chunk.fourcc == .VP8L {continue}
		if chunk.fourcc != .VP8 {continue}

		// these are ANMF - animation frames
		// in our project 1 frame=1 thumb
		vec_push(v[:], &vec_idx, ANMF_CC[:])
		vec_push(v[:], &vec_idx, mem.any_to_bytes(chunk.size_plus_24))

		// frame x(u24)/y(u24) (6 byte)
		vec_push(v[:], &vec_idx, []u8{0, 0, 0, 0, 0, 0})

		vec_push(v[:], &vec_idx, dims[0][:])
		vec_push(v[:], &vec_idx, dims[1][:])

		// duration in ms
		ANMF_Flags_Byte := transmute(u8)bit_set[ANMF_Flags;u8]{}
		vec_push(
			v[:],
			&vec_idx,
			mem.slice_to_bytes(
				[]u8 {
					30,
					0,
					0, // duration in ms/3 byte
					ANMF_Flags_Byte,
				},
			),
		)

		vec_push(v[:], &vec_idx, VP8_CC[:])
		vec_push(v[:], &vec_idx, mem.any_to_bytes(chunk.size))
		vec_push(v[:], &vec_idx, chunk.payload)
	}
}
