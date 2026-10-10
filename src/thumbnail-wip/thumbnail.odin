package thumbnail

import "core:bytes"
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
//
// ANMF
// Appends ANMF frames; the caller writes the RIFF, VP8X, and ANIM headers.
Thumbnail_MipMap :: proc(streams: []Thumb, buf: ^bytes.Buffer) {
	for stream in streams {
		type := parse_fourcc(buf.buf[:])
		if type == .VP8L || type == .Unknown {
			fmt.println("UNSUPPORTED fourcc while generating mipmap")
			continue
		}

		s := stream.bytes[12:]

		bytes.buffer_write(buf, ANMF_CC[:])
		frame_size := u32le(16 + len(s))
		bytes.buffer_write(buf, mem.ptr_to_bytes(&frame_size))
		// frame x/y
		bytes.buffer_write(buf, []u8{0, 0, 0}) // 3 bytes
		bytes.buffer_write(buf, []u8{0, 0, 0}) // 3 bytes
		// width/height (-1)
		w := transmute([4]u8)u32le(stream.width - 1)
		h := transmute([4]u8)u32le(stream.height - 1)
		bytes.buffer_write(buf, w[:3])
		bytes.buffer_write(buf, h[:3])
		// duration in ms
		bytes.buffer_write(buf, []u8{30, 0, 0}) // 3 bytes

		bytes.buffer_write_byte(buf, transmute(u8)bit_set[ANMF_Flags;u8]{})
		bytes.buffer_write(buf, s)
	}
}
