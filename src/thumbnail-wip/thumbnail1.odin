package thumbnail

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:os"

import "../util"

Thumb :: struct {
	bytes:  []u8, // Complete standalone WebP file; backing memory owned by caller.
	width:  u32, // Actual thumbnail dimensions, not minus-one encoded values.
	height: u32,
}

// attempt to implement
// RFC9649 https://www.rfc-editor.org/info/rfc9649/
// contextless specifiers (e.g., 2.7.1.1) reference sections of
// aforementioned rfc.

// 8 bytes fourCC, then size (little-endian, excludes padding)
ChunkHeader :: struct {
	fourcc: []u8,
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
RIFF_CC :: []u8{'R', 'I', 'F', 'F'}
WEBP_CC :: []u8{'W', 'E', 'B', 'P'}
VP8_CC :: []u8{'V', 'P', '8', ' '}
VP8X_CC :: []u8{'V', 'P', '8', 'X'}
VP8L_CC :: []u8{'V', 'P', '8', 'L'}
ANIM_CC :: []u8{'A', 'N', 'I', 'M'}
ANMF_CC :: []u8{'A', 'N', 'M', 'F'}


main :: proc() {
	// ANMF

	d, read_err := os.read_entire_file_from_path(
		"/home/eissar/code/lfs-booru-odin/src/thumbnail/t-metadata.json",
		context.temp_allocator,
	)
	if read_err != nil {fmt.println("couldn't read"); os.exit(1)}

	j, err := json.parse(d)
	if err != nil {fmt.println("couldn't parse"); os.exit(1)}

	thumbs: [dynamic]ThumbBitstream
	for item in j.(json.Array) {
		obj := item.(json.Object)
		path := fmt.aprintf(
			"%v%v",
			"/home/eissar/code/lfs-booru-odin/src/thumbnail/",
			obj["thumb"],
		)
		d, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {fmt.println("could not read", path); os.exit(1)}

		ch := parse_chunk(d[12:])

		if bytes.equal(VP8L_CC, ch.fourcc) {
			fmt.println("Unimplemented error: vp8L")
			os.exit(1)
		}
		if bytes.equal(VP8_CC, ch.fourcc) {
			append_elem(
				&thumbs,
				ThumbBitstream {
					thumb = Thumb {
						bytes = d,
						width = u32(obj["thumbWidth"].(json.Float)),
						height = u32(obj["thumbHeight"].(json.Float)),
					},
					bitstream = transmute(Bitstream)ch,
				},
			)
			continue
		}
	}

	newThumbnailAtlas(thumbs[:])
}

/* returns a MipMap from the thumbnail atlas */
Vectorized_Thumbnail_MipMap :: proc "contextless" (input: []Thumb, b: []ThumbBitstream) {
	idx := 0
	for thumb in input {
		ch := parse_chunk(thumb.bytes[12:])

		if util.bytes_equal(VP8L_CC, ch.fourcc) {
			// TODO: use a prebuffered
			// THUMBNAIL_MISSING / UNSUPPORTED_TYPE
			// thumbnail
			idx += 1; continue
		}
		if util.bytes_equal(VP8_CC, ch.fourcc) {
			b[idx] = ThumbBitstream {
				thumb     = thumb,
				bitstream = transmute(Bitstream)ch,
			}
			idx += 1; continue
		}

	}

}
