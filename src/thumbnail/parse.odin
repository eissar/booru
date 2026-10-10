package thumbnail

import "core:encoding/endian"

// vp8 stores dims as u14
U14_MASK: u32le = (1 << 14) - 1 // 0011 1111 1111 1111 ; 0x3fff

parse_fourcc :: proc "contextless" (b: []u8) -> FourCC {
	if len(b) < 4 {return .Unknown}
	cc := [4]u8{b[0], b[1], b[2], b[3]}
	switch cc {
	case {'R', 'I', 'F', 'F'}:
		return .RIFF
	case {'W', 'E', 'B', 'P'}:
		return .WEBP
	case {'V', 'P', '8', ' '}:
		return .VP8
	case {'V', 'P', '8', 'X'}:
		return .VP8X
	case {'V', 'P', '8', 'L'}:
		return .VP8L
	case {'A', 'N', 'I', 'M'}:
		return .ANIM
	case {'A', 'N', 'M', 'F'}:
		return .ANMF
	}
	return .Unknown
}

// accepts a riff chunk without the prelude
parse_chunk :: proc "contextless" (b: []u8, v: ^Chunk) {
	v.fourcc = parse_fourcc(b)
	sz, ok := endian.get_u32(b[4:8], .Little)
	// if !ok { /* buffer too short */}
	v.size = sz
	v.size_plus_24 = u32le(v.size + 24)
	// If Chunk Size is odd, a single padding byte -- which MUST be 0 to conform with RIFF [RIFF-spec] -- is added.
	// we add %2 so we don't have to pad later
	v.payload = b[8:]
}
