package thumbnail

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:slice"
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


Webp_Extended_Prefix :: struct {
	WEBP: [12]u8,
	VP8X: [18]u8,
	ANIM: [14]u8,
}

U14_MASK: u16 = (1 << 14) - 1 // 0011 1111 1111 1111 ; 0x3fff

newThumbnailAtlas :: proc(streams: []Thumb, vec: [][]u8, alloc: runtime.Allocator) {
	length_of_thumbs := 0
	for t in streams {
		// subtract RIFF header, or 12 bytes per thumb
		length_of_thumbs += len(t.bytes) - 12
	}

	prefix := new(Webp_Extended_Prefix, alloc)

	// WEBP
	riff_size := compute_extended_riff_size(RIFF_X_SIZE, len(streams), length_of_thumbs)

	copy(prefix.WEBP[0:4], RIFF_CC[:])
	copy(prefix.WEBP[4:8], mem.slice_to_bytes([]u32le{riff_size})) // The size of the file in bytes, starting at offset 8.
	copy(prefix.WEBP[8:12], WEBP_CC[:])

	// VP8X
	webp_byte := transmute(u8)bit_set[WEBP_Flags;u8]{.Animated, .Alpha}
	copy(prefix.VP8X[0:4], VP8X_CC[:])
	copy(prefix.VP8X[4:8], mem.slice_to_bytes([]u32le{10}))
	// webp_byte: 1
	//  0, 0, 0 : 3 reserved
	// 95, 0, 0 : 3 width: 96 , stored minus one
	// 95, 0, 0 : 3 height: 96, stored minus one
	copy(prefix.VP8X[8:18], mem.slice_to_bytes([]u8{webp_byte, 0, 0, 0, 95, 0, 0, 95, 0, 0}))

	// optional iccp chunk

	// REGION: ANIM chunk 8 (header) + 6
	anim_size_bytes := transmute([4]byte)u32le(6)
	copy(prefix.ANIM[0:4], ANIM_CC[:])
	copy(prefix.ANIM[4:8], anim_size_bytes[:])
	// 0, 0, 0, 0: bg color 32 bits
	// 0, 0      : loop count 16 bits
	copy(prefix.ANIM[8:14], mem.slice_to_bytes([]u8{0, 0, 0, 0, 0, 0}))
	// ENDREGION: ANIM

	// chunks: [dynamic]Chunk
	chunks := make([dynamic]Chunk, alloc)
	resize(&chunks, len(streams))

	chunk_idx := 0
	for s in streams {
		c := &chunks[chunk_idx]
		parse_chunk(s.bytes[12:], c)
		chunk_idx += 1
	}

	dims := new([2][]u8, alloc)

	{ 	// this is overly complex...
		b := chunks[0].payload
		width, _ := endian.get_u16(b[6:8], .Little)
		height, _ := endian.get_u16(b[8:10], .Little)
		w := transmute([4]u8)u32le((width & U14_MASK) - 1)
		h := transmute([4]u8)u32le((height & U14_MASK) - 1)
		dims[0] = make([]u8, 3, alloc)
		dims[1] = make([]u8, 3, alloc)
		copy(dims[0], w[:3])
		copy(dims[1], h[:3])
	}


	vec := vec
	Vectorized_Webp_Extended(chunks[:], &vec, prefix, dims)
}
