package media

import "core:c"
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

// Scope: JXL decode currently targets 8-bit opaque RGB24 only (via avcodec libjxl).
// Returns the JXL codestream bytes in `data`.
// Zero-copy subslice for bare codestreams, `jxlc`, and single-chunk `jxlp`;
// multi-chunk `jxlp` streams are concatenated using `allocator`.
jxlc_decode :: proc(data: []u8, allocator := context.allocator) -> (codestream: []u8, ok: bool) {
	if len(data) < 2 {return}
	if ([2]u8{data[0], data[1]}) == JXL_Codestream_Prefix {
		return data, true
	}

	if len(data) < 12 {return}
	if (cast(^[12]u8)raw_data(data))^ != JXL_SIGNATURE_BOX {return}

	chunks: [dynamic]u8
	expected_seq: u32 = 0
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
			if pos + 16 > len(data) {
				delete(chunks)
				return
			}
			box_size, _ = endian.get_u64(data[pos + 8:pos + 16], .Big)
			header_sz = 16
		}
		if fourcc == {'u', 'u', 'i', 'd'} {header_sz += 16}
		if box_size < u64(header_sz) || box_size > u64(len(data) - pos) {
			delete(chunks)
			return
		}

		switch fourcc {
		case {'j', 'x', 'l', 'c'}:
			delete(chunks)
			return data[pos + header_sz:pos + int(box_size)], true
		case {'j', 'x', 'l', 'p'}:
			// jxlp payload starts with a 4-byte big-endian sequence counter;
			// bit 31 (0x80000000) is set on the final chunk.
			if int(box_size) - header_sz < 4 {
				delete(chunks)
				return
			}
			payload := data[pos + header_sz:pos + int(box_size)]
			counter, _ := endian.get_u32(payload[:4], .Big)
			seq := counter & 0x7FFFFFFF
			is_last := (counter & 0x80000000) != 0
			if seq != expected_seq {
				delete(chunks)
				return
			}
			chunk := payload[4:]
			if expected_seq == 0 && is_last {
				return chunk, true
			}
			if expected_seq == 0 {
				chunks = make([dynamic]u8, allocator)
			}
			append(&chunks, ..chunk)
			if is_last {
				return chunks[:], true
			}
			expected_seq += 1
		}

		pos += int(box_size)
	}
	delete(chunks)
	return
}

@(private = "file")
read_cs_bits :: proc(b: []u8, pos: ^uint, n: uint) -> (val: u64, ok: bool) {
	if pos^ + n > uint(len(b)) * 8 {return}
	weight: u64 = 1
	for _ in 0 ..< n {
		byte_bits := transmute(bit_set[0 ..< 8;u8])b[pos^ / 8]
		if int(pos^ % 8) in byte_bits {val += weight}
		weight *= 2
		pos^ += 1
	}
	return val, true
}

@(private = "file")
read_cs_dim :: proc(b: []u8, pos: ^uint, div8: u64) -> (dim: u64, ok: bool) {
	if div8 == 1 {return ((read_cs_bits(b, pos, 5) or_return) + 1) * 8, true}
	bit_widths := [4]uint{9, 13, 18, 30}
	bits := bit_widths[read_cs_bits(b, pos, 2) or_return]
	return (read_cs_bits(b, pos, bits) or_return) + 1, true
}

JXL_Codestream_Ratios := [7][2]u64{{1, 1}, {12, 10}, {4, 3}, {3, 2}, {16, 9}, {5, 4}, {2, 1}}

jxl_codestream_dimension :: proc(cs: []u8) -> (width, height: c.int, ok: bool) {
	if len(cs) < 3 {return}
	if ([2]u8{cs[0], cs[1]}) != JXL_Codestream_Prefix {return}

	body := cs[2:]
	pos: uint = 0

	div8 := read_cs_bits(body, &pos, 1) or_return
	ysize := read_cs_dim(body, &pos, div8) or_return
	ratio := read_cs_bits(body, &pos, 3) or_return

	// when ratio is set,
	// xsize must be derived from
	// ratio & ysize
	if ratio != 0 {
		r := JXL_Codestream_Ratios[ratio - 1]
		xsize := (ysize * r[0]) / r[1]
		if xsize == 0 || xsize > u64(max(c.int)) || ysize > u64(max(c.int)) {return}
		return c.int(xsize), c.int(ysize), true
	}

	xsize := read_cs_dim(body, &pos, div8) or_return
	if xsize > u64(max(c.int)) || ysize > u64(max(c.int)) {return}
	return c.int(xsize), c.int(ysize), true
}
