package media

import "core:encoding/endian"
import "core:testing"

// Two file-relative items; pitm selects the second. Payloads are parser markers,
// not AV1: decoding is covered by the real thumbnail fixture test.
avif_parser_fixture :: proc() -> [90]u8 {
	data := [90]u8 {
		0,
		0,
		0,
		74,
		'm',
		'e',
		't',
		'a',
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		14,
		'p',
		'i',
		't',
		'm',
		0,
		0,
		0,
		0,
		0,
		2,
		0,
		0,
		0,
		48,
		'i',
		'l',
		'o',
		'c',
		1,
		0,
		0,
		0,
		0x44,
		0,
		0,
		2,
		0,
		1,
		0,
		0,
		0,
		0,
		0,
		1,
		0,
		0,
		0,
		82,
		0,
		0,
		0,
		4,
		0,
		2,
		0,
		0,
		0,
		0,
		0,
		1,
		0,
		0,
		0,
		86,
		0,
		0,
		0,
		4,
		0,
		0,
		0,
		16,
		'm',
		'd',
		'a',
		't',
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
	}
	return data
}

@(test)
avif_primary_extent :: proc(t: ^testing.T) {
	data := avif_parser_fixture()
	offset, length, _, _, ok := decode(data[:])
	testing.expect(t, ok && offset == 86 && length == 4, "select primary item, not first extent")
}

@(test)
avif_invalid_extents :: proc(t: ^testing.T) {
	data := avif_parser_fixture()
	for n in 0 ..< len(data) {
		_, _, _, _, ok := decode(data[:n])
		testing.expectf(t, !ok, "reject truncated input at %d", n)
	}

	for case_index in 0 ..< 6 {
		data = avif_parser_fixture()
		switch case_index {
		case 0:
			endian.put_u32(data[66:70], .Big, 91) // Offset outside file.
		case 1:
			endian.put_u32(data[70:74], .Big, 5) // Extent runs past EOF.
		case 2:
			endian.put_u32(data[70:74], .Big, 0) // Empty extent.
		case 3:
			data[61] = 1 // idat-relative construction is unsupported.
		case 4:
			data[63] = 1 // External data reference is unsupported.
		case 5:
			data[65] = 0 // No extent for the primary item.
		}
		_, _, _, _, ok := decode(data[:])
		testing.expectf(t, !ok, "reject invalid/unsupported extent case %d", case_index)
	}

	// Add a second complete primary extent, so rejection is not just truncation.
	multiple: [98]u8
	data = avif_parser_fixture()
	copy(multiple[:74], data[:74])
	copy(multiple[82:], data[74:])
	endian.put_u32(multiple[:4], .Big, 82)
	endian.put_u32(multiple[26:30], .Big, 56)
	multiple[65] = 2
	endian.put_u32(multiple[50:54], .Big, 90)
	endian.put_u32(multiple[66:70], .Big, 94)
	endian.put_u32(multiple[74:78], .Big, 94)
	endian.put_u32(multiple[78:82], .Big, 4)
	_, _, _, _, ok := decode(multiple[:])
	testing.expect(t, !ok, "reject multiple primary extents")
}
