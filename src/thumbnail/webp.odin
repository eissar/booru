package thumbnail

import "core:encoding/endian"
import "core:mem"

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
	ALPH,
	ANIM,
	ANMF,
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
VP8X_CC := [4]u8{'V', 'P', '8', 'X'}
ANIM_CC := [4]u8{'A', 'N', 'I', 'M'}
ANMF_CC := [4]u8{'A', 'N', 'M', 'F'}


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
	// Canvas dimensions are populated by Prepare_Webp_X.
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

Webp_Extended_Prefix :: struct {
	WEBP: [12]u8,
	VP8X: [18]u8,
	ANIM: [14]u8,
}

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
