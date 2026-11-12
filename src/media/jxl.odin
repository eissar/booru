package media

import "core:encoding/endian"
import "core:fmt"
import "core:testing"

// https://www.iso.org/standard/80617.html

JXL_Box_Type :: enum {
	Unknown,
	JXL,
	ftyp,
	jxlc, // codestream
	jxlp, // picture
}


JXL_FourCC :: [4]u8{'J', 'X', 'L', ' '}
JXL_Codestream_Prefix :: [2]u8{'\xFF', '\n'}
JXL_SIGNATURE_BOX :: [12]u8{0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A}

// 12 bytes
JXL_Prefix :: struct {
	size:  [4]u8,
	type:  [4]u8,
	magic: [4]u8,
}

parse_jxl_prelude :: proc(data: []u8) -> (prefix: JXL_Prefix, ok: bool) {
	if len(data) < 12 {return JXL_Prefix{}, false}
	if ([2]u8{data[0], data[1]}) == JXL_Codestream_Prefix {return JXL_Prefix{}, false}

	mptr := cast(^[12]u8)raw_data(data[:12])

	return transmute(JXL_Prefix)mptr^, true
}

// An ISOBMFF-based container. This is a box-based container that includes a JPEG XL codestream box (jxlc)
// and can optionally include other boxes with additional information,
// such as Exif metadata. In this case, the file starts with the bytes

/// Returns the byte range of the JXL codestream in `data`.
jxlc_decode :: proc(data: []u8) -> (offset, length: int, ok: bool) {
	if len(data) < 2 {return}
	if ([2]u8{data[0], data[1]}) == JXL_Codestream_Prefix {
		return 0, len(data), true
	}

	if len(data) < 12 {return}
	if (cast(^[12]u8)raw_data(data))^ != JXL_SIGNATURE_BOX {return}

	pos := 12
	for pos + 8 <= len(data) {
		n, _ := endian.get_u32(data[pos:pos + 4], .Big)
		fourcc := [4]u8{data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]}

		header_sz := 8
		box_size := u64(n)
		switch n {
		case 0:
			box_size = u64(len(data) - pos)
		case 1:
			if pos + 16 > len(data) {return}
			box_size, _ = endian.get_u64(data[pos + 8:pos + 16], .Big)
			header_sz = 16
		}
		if fourcc == {'u', 'u', 'i', 'd'} {header_sz += 16}
		if box_size < u64(header_sz) || box_size > u64(len(data) - pos) {return}

		switch fourcc {
		case {'j', 'x', 'l', 'c'}:
			return pos + header_sz, int(box_size) - header_sz, true
		case {'j', 'x', 'l', 'p'}:
			// jxlp payload starts with a 4-byte big-endian sequence counter;
			// bit 31 (0x80000000) is set on the final chunk.
			if int(box_size) - header_sz < 4 {return}
			counter, _ := endian.get_u32(data[pos + header_sz:pos + header_sz + 4], .Big)
			if counter == 0x80000000 {
				return pos + header_sz + 4, int(box_size) - header_sz - 4, true
			}
			// Multi-chunk jxlp streams are non-contiguous and must be concatenated.
			return
		}

		pos += int(box_size)
	}
	return
}
