package thumbnail

import "core:encoding/endian"

parse_chunk :: proc "contextless" (b: []u8) -> (chunk: Chunk) {
	chunk.fourcc = b[:4]
	sz, ok := endian.get_u32(b[4:8], .Little)
	// if !ok { /* buffer too short */}
	chunk.size = sz
	// If Chunk Size is odd, a single padding byte -- which MUST be 0 to conform with RIFF [RIFF-spec] -- is added.
	// we add %2 so we don't have to pad later
	chunk.payload = b[8:sz + (sz % 2)]
	return chunk
}
