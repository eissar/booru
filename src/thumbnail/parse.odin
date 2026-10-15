package thumbnail

import "core:encoding/endian"


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
	case {'A', 'L', 'P', 'H'}:
		return .ALPH
	case {'A', 'N', 'I', 'M'}:
		return .ANIM
	case {'A', 'N', 'M', 'F'}:
		return .ANMF
	}
	return .Unknown
}

parse_chunk_header :: proc "contextless" (b: []u8) -> (f: FourCC, size: u32, ok: bool) {
	f = parse_fourcc(b)
	if len(b) < 8 {return}
	size, ok = endian.get_u32(b[4:8], .Little)
	return
}
