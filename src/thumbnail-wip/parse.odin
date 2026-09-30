package thumbnail

import "core:encoding/endian"

// An optional alpha subchunk (Section 2.7.1.2) for the frame.
// A bitstream subchunk (Section 2.7.1.3) for the frame.
// An optional list of unknown chunks (Section 2.7.1.6).
//
// Note: The 'ANMF' payload, Frame Data, consists of individual padded chunks, as described by the RIFF file format (Section 2.3).
//
// frames : x,y,w,h 24|24|24|24 (bits)
// duration,reserved,blending_method,disposal_method 24|6|1|1 (bits)
// the rest is the payload
// https://www.rfc-editor.org/info/rfc9649/#section-2.7.1.1-8.18.1
// x: 24b
// parse_anmf :: proc(b: []u8) -> (chunk: ANMF) {
// 	ok: bool
// 	// need to construct manually. u8*3 = 24 + 0 to manually create u32
// 	chunk.x, ok = endian.get_u32([]byte{b[0], b[1], b[2], 0}, .Little)
// 	// if !ok { /* buffer too short */}
// 	chunk.y, ok = endian.get_u32([]byte{b[3], b[4], b[5], 0}, .Little)
// 	chunk.w, ok = endian.get_u32([]byte{b[6], b[7], b[8], 0}, .Little)
// 	chunk.x, ok = endian.get_u32([]byte{b[9], b[10], b[11], 0}, .Little)
//
// 	chunk.duration, ok = endian.get_u32([]byte{b[12], b[13], b[14], 0}, .Little)
// 	// the next 8 bits (one byte)
// 	// reserved,blending_method,disposal_method 6|1|1
// 	chunk.flags = transmute(bit_set[ANMF_Flags;u8])b[15]
//
// 	// Each ANMF frame contains exactly one bitstream, either VP8  or VP8L.
// 	// payload := b[15:]
// 	return chunk
// }


// Animated WebP	One or more ANMF chunks
// extended format
// "The WebP file format is based on the RIFF [RIFF-spec] document format"
// WEBP_Extended :: struct {
// 	Header: []u32, // 12 bytes long
// 	VP8X:   ChunkHeader, // 8 bytes
// 	flags:  bit_set[WEBP_Flags;u8],
// 	Width:  []u8, // 3 byte =  24 bit
// 	Height: []u8, // 3 byte =  24 bit
// 	// ICCP:   []u8,
// 	ANIM:   []u8,
// 	EXIF:   []u8,
// 	XMP:    []u8,
// 	// "An optional list of unknown chunks" 2.7.1.6
// 	// UNK:  []^RFC9649_OPT_CHUNK,
// }
parse_chunk :: proc(b: []u8) -> (chunk: Chunk) {
	chunk.fourcc = b[:4]
	sz, ok := endian.get_u32(b[4:8], .Little)
	// if !ok { /* buffer too short */}
	chunk.size = sz
	// If Chunk Size is odd, a single padding byte -- which MUST be 0 to conform with RIFF [RIFF-spec] -- is added.
	// we add %2 so we don't have to pad later
	chunk.payload = b[8:sz + (sz % 2)]
	return chunk
}
