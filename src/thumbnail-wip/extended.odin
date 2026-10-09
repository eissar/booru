package thumbnail

import "core:bytes"
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


// s: File Size: 32 bits (uint32)
// The size of the file in bytes, starting at offset 8. The maximum value of this field is 232 minus 10 bytes, and thus the size of the whole file is at most 4 GiB minus 2 bytes.
newWebpExtendedFile :: proc(streams: []Thumb, buf: ^bytes.Buffer) {
	// Assumes thumbnails contain only padded image chunks after the 12-byte RIFF/WebP header.
	file_size: u64 = 12 + 18 + 14
	for s in streams {
		file_size += 8 + 16 + u64(len(s.bytes[12:]))
	}
	assert(file_size <= 0xFFFF_FFFE)
	bytes.buffer_grow(buf, int(file_size))

	// FIX: this incl skipped frames
	riff_size := u32le(file_size - 8)
	// our decided format:
	// WEBP     12
	// VP8X     18  (8 + 10)
	// ANIM     14  (8 + 6)

	// REGION: WebP File Header
	bytes.buffer_write(buf, RIFF_CC) // 4 bytes ;12 bits
	bytes.buffer_write(buf, mem.ptr_to_bytes(&riff_size)) // file size minus 8
	bytes.buffer_write(buf, WEBP_CC) // 4 bytes ;12 bits

	// REGION: VP8X
	bytes.buffer_write(buf, VP8X_CC)
	vp8x_size := u32le(10)
	bytes.buffer_write(buf, mem.ptr_to_bytes(&vp8x_size))
	// just say alpha for now
	bytes.buffer_write_byte(buf, transmute(u8)bit_set[WEBP_Flags;u8]{.Animated, .Alpha}) // 1 byte
	bytes.buffer_write(buf, []u8{0, 0, 0}) // 3 bytes reserved
	//canvas width/height: 96 x 96, stored minus one
	bytes.buffer_write(buf, []u8{95, 0, 0}) // 3 bytes
	bytes.buffer_write(buf, []u8{95, 0, 0}) // 3 bytes

	// optional iccp chunk

	// REGION: ANIM chunk 8 (header) + 6
	bytes.buffer_write(buf, ANIM_CC)
	anim_size := u32le(6)
	bytes.buffer_write(buf, mem.ptr_to_bytes(&anim_size))
	// bg color 32 bits / uint32
	bytes.buffer_write(buf, []u8{0, 0, 0, 0}) // 4 bytes
	// loop count 16 bits / 2 bytes
	bytes.buffer_write(buf, []u8{0, 0}) // 2 bytes

	// REGION: Image data. for us this means ANMF
	Thumbnail_MipMap(streams, buf)
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
	vec[idx^] = data
	idx^ += 1
}

// for use with writev later
Vectorized_Webp_Extended :: proc(streams: []Thumb, streams_len: int) -> [][]u8 {
	vec_idx := 0

	// subtract 8 for ... reason
	// 24 = fixed header per riff
	riff_size := u32le(RIFF_X_SIZE - 8 + 24 * len(streams) + streams_len)

	// this should also get passed as a parameter
	// we can know the size of the thing
	// maybe new -> mem.resize
	vec := new([1024][]u8, context.allocator)
	defer free(vec)
	// vec := new([][]u8, RIFF_X_SIZE)

	// REGION: WEBP (12)
	vec_push(vec[:], &vec_idx, RIFF_CC)
	// this is wrong btw
	vec_push(vec[:], &vec_idx, mem.slice_to_bytes([]u32le{riff_size}))
	vec_push(vec[:], &vec_idx, WEBP_CC)
	// ENDREGION: WEBP

	// REGION: VP8X
	vec_push(vec[:], &vec_idx, VP8X_CC)
	vec_push(vec[:], &vec_idx, mem.slice_to_bytes([]u32le{10}))

	webp_byte := transmute(u8)bit_set[WEBP_Flags;u8]{.Animated, .Alpha}
	// webp_byte: 1
	//  0, 0, 0 : 3 reserved
	// 95, 0, 0 : 3 width: 96 , stored minus one
	// 95, 0, 0 : 3 height: 96, stored minus one
	vec_push(vec[:], &vec_idx, mem.slice_to_bytes([]u8{webp_byte, 0, 0, 0, 95, 0, 0, 95, 0, 0}))
	// ENDREGION: VP8X

	// optional iccp chunk

	// REGION: ANIM chunk 8 (header) + 6
	vec_push(vec[:], &vec_idx, ANIM_CC)
	anim_size_bytes := transmute([4]byte)u32le(6)
	vec_push(vec[:], &vec_idx, anim_size_bytes[:])
	// 0, 0, 0, 0: bg color 32 bits
	// 0, 0      : loop count 16 bits
	vec_push(vec[:], &vec_idx, mem.slice_to_bytes([]u8{0, 0, 0, 0, 0, 0}))
	// ENDREGION: ANIM

	for thumb in streams {
		ch := parse_chunk(thumb.bytes[12:])
		if ch.fourcc == .VP8L {continue}
		if ch.fourcc != .VP8 {continue}

		s := thumb.bytes[12:]

		vec_push(vec[:], &vec_idx, ANMF_CC)
		frame_size := []u32le{u32le(16 + len(s))}
		vec_push(vec[:], &vec_idx, mem.slice_to_bytes(frame_size))

		// frame x(u24)/y(u24) (6 byte)
		vec_push(vec[:], &vec_idx, []u8{0, 0, 0, 0, 0, 0})

		// w := transmute([4]u8)u32le(stream.width - 1)
		// h := transmute([4]u8)u32le(stream.height - 1)
		// bytes.buffer_write(buf, w[:3])
		// bytes.buffer_write(buf, h[:3])
		vec_push(vec[:], &vec_idx, mem.slice_to_bytes([]u8{95, 0, 0, 95, 0, 0}))

		// duration in ms
		ANMF_Flags_Byte := transmute(u8)bit_set[ANMF_Flags;u8]{}
		vec_push(
			vec[:],
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

		vec_push(vec[:], &vec_idx, s)


	}

	// vec[vec_idx]
	return vec[:vec_idx]
}


// this will get called in web requests.
newThumbnailAtlas :: proc(streams: []Thumb) {
	length_of_thumbs := 0
	for t in streams {
		length_of_thumbs += len(t.bytes)
	}
	Vectorized_Webp_Extended(streams, length_of_thumbs)
}


//ENDREGION:
