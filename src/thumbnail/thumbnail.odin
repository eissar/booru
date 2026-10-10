package thumbnail

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"


Thumb :: struct {
	bytes:  []u8, // Complete standalone WebP file; backing memory owned by caller.
	width:  u32, // Actual thumbnail dimensions, not minus-one encoded values.
	height: u32,
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


// TODO: use a prebuffered
// THUMBNAIL_MISSING / UNSUPPORTED_TYPE
// thumbnail
Thumbnail_MipMap :: proc(streams: []Thumb, vec: [][]u8, alloc: runtime.Allocator) {
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
