package thumbnail

import "base:runtime"
import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"


Thumb :: struct {
	bytes:  []u8, // Complete standalone WebP file; backing memory owned by caller.
	width:  u16le, // Actual thumbnail dimensions, not minus-one encoded values.
	height: u16le,
}

NOT_FOUND_64_WEBP :: #load("../../static/not_found_64.webp")
NOT_FOUND_128_WEBP :: #load("../../static/not_found_128.webp")
UNSUPPORTED_FILETYPE_64_WEBP :: #load("../../static/unsupported_filetype_64.webp")
UNSUPPORTED_FILETYPE_128_WEBP :: #load("../../static/unsupported_filetype_128.webp")
new_not_found_thumb :: proc(resolution: u16le) -> Thumb {
	if resolution == 128 {
		return Thumb{transmute([]u8)NOT_FOUND_128_WEBP, 128, 128}
	}
	return Thumb{transmute([]u8)NOT_FOUND_64_WEBP, 64, 64}
}


// attempt to implement
// RFC9649 https://www.rfc-editor.org/info/rfc9649/
// contextless specifiers (e.g., 2.7.1.1) reference sections of
// aforementioned rfc.

FourCC :: enum {
	Unknown,
	RIFF,
	WEBP,
	VP8,
	VP8X,
	VP8L,
	ANIM,
	ANMF,
}

// 8 bytes fourCC, then size (little-endian, excludes padding)
ChunkHeader :: struct {
	fourcc: FourCC,
	size:   u32,
}

Chunk :: struct {
	using header: ChunkHeader,
	payload:      []u8,
	// HACK: fix this later
	size_plus_24: u32le,
}


ANMF_Flags :: enum u8 {
	disposal_method = 0,
	blend_method    = 1,
	_               = 2,
	_               = 3,
	_               = 4,
	_               = 5,
	_               = 6,
	_               = 7,
}
RIFF_CC := [4]u8{'R', 'I', 'F', 'F'}
WEBP_CC := [4]u8{'W', 'E', 'B', 'P'}
VP8_CC := [4]u8{'V', 'P', '8', ' '}
VP8X_CC := [4]u8{'V', 'P', '8', 'X'}
VP8L_CC := [4]u8{'V', 'P', '8', 'L'}
ANIM_CC := [4]u8{'A', 'N', 'I', 'M'}
ANMF_CC := [4]u8{'A', 'N', 'M', 'F'}


main :: proc() {
	// ANMF

	d, read_err := os.read_entire_file_from_path(
		"/home/eissar/code/lfs-booru-odin/src/thumbnail/t-metadata.json",
		context.temp_allocator,
	)
	if read_err != nil {fmt.println("couldn't read"); os.exit(1)}

	j, err := json.parse(d)
	if err != nil {fmt.println("couldn't parse"); os.exit(1)}

	chunks: [dynamic]Chunk
	// thumbs: [dynamic]Thumb
	for item in j.(json.Array) {
		obj := item.(json.Object)
		path := fmt.aprintf(
			"%v%v",
			"/home/eissar/code/lfs-booru-odin/src/thumbnail/",
			obj["thumb"],
		)
		d, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {fmt.println("could not read", path); os.exit(1)}

		chunk: Chunk
		parse_chunk(d[12:], &chunk)

		if chunk.fourcc == .VP8L {
			fmt.println("Unimplemented error: vp8L")
			os.exit(1)
		}
		if chunk.fourcc == .VP8 {
			append_elem(&chunks, chunk)
			continue
		}
	}

	// newThumbnailAtlas(thumbs[:])
}

// this copies a bunch of data
// passing riff_size - code smell
thumbnail_prefix :: proc(prefix: ^Webp_Extended_Prefix, riff_size: u32le) {
	// WEBP

	copy(prefix.WEBP[0:4], RIFF_CC[:])
	copy(prefix.WEBP[4:8], mem.slice_to_bytes([]u32le{riff_size})) // The size of the file in bytes, starting at offset 8.
	copy(prefix.WEBP[8:12], WEBP_CC[:])

	// VP8X
	webp_byte := transmute(u8)bit_set[WEBP_Flags;u8]{.Animated, .Alpha}
	copy(prefix.VP8X[0:4], VP8X_CC[:])
	copy(prefix.VP8X[4:8], mem.slice_to_bytes([]u32le{10}))
	// webp_byte: 1
	//  0, 0, 0 : 3 reserved
	// Canvas dimensions are populated by Thumbnail_MipMap.
	prefix.VP8X[8] = webp_byte

	// optional iccp chunk

	// REGION: ANIM chunk 8 (header) + 6
	anim_size_bytes := transmute([4]byte)u32le(6)
	copy(prefix.ANIM[0:4], ANIM_CC[:])
	copy(prefix.ANIM[4:8], anim_size_bytes[:])
	// 0, 0, 0, 0: bg color 32 bits
	// 0, 0      : loop count 16 bits
	copy(prefix.ANIM[8:14], mem.slice_to_bytes([]u8{0, 0, 0, 0, 0, 0}))
	// ENDREGION: ANIM
}

// creates multiple []u8 using provided allocator and returns a slice to them
Thumbnail_MipMap :: proc(streams: []Thumb, alloc: runtime.Allocator) -> [][]u8 {
	vec := make([][]u8, 3 + 9 * len(streams), alloc)

	length_of_thumbs := 0
	for &t in streams {
		if parse_fourcc(t.bytes[12:]) != .VP8 {
			if t.width == 128 {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_128_WEBP
			} else {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_64_WEBP
			}
		}
		// Assume VP8: key-frame dimensions are little-endian u14 values at these offsets.
		t.width = (u16le(t.bytes[26]) | u16le(t.bytes[27]) << 8) & 0x3fff
		t.height = (u16le(t.bytes[28]) | u16le(t.bytes[29]) << 8) & 0x3fff
		// subtract RIFF header, or 12 bytes per thumb
		length_of_thumbs += len(t.bytes) - 12
	}

	prefix := new(Webp_Extended_Prefix, alloc)
	riff_size := compute_extended_riff_size(RIFF_X_SIZE, len(streams), length_of_thumbs)
	thumbnail_prefix(prefix, riff_size)


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

	t := streams[0]
	edge := u32(max(t.width, t.height))
	sizes := [2]u32{edge, edge}
	for i in 0 ..< 2 {
		encoded := transmute([4]u8)u32le(sizes[i] - 1)
		dims[i] = make([]u8, 3, alloc)
		copy(dims[i], encoded[:3])
	}

	copy(prefix.VP8X[12:15], dims[0])
	copy(prefix.VP8X[15:18], dims[1])

	Vectorized_Webp_Extended(chunks[:], &vec, prefix, dims, alloc)
	return vec
}
