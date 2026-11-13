package media

import "core:bytes"
import "core:os"
import "core:testing"

@(test)
jxl_codestream_bare :: proc(t: ^testing.T) {
	data := [?]u8{0xFF, 0x0A, 1, 2, 3, 4}
	cs, ok := jxlc_decode(data[:])
	testing.expect(t, ok, "decode bare JXL codestream")
	testing.expect(t, bytes.equal(cs, data[:]), "bare codestream matches input")
	testing.expect(t, raw_data(cs) == raw_data(data[:]), "bare codestream is zero-copy")
}

@(test)
jxl_container_jxlc :: proc(t: ^testing.T) {
	// JXL signature box (12) + ftyp box (16) + jxlc box (12)
	data := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x10,
		'f',
		't',
		'y',
		'p',
		'j',
		'x',
		'l',
		' ',
		0,
		0,
		0,
		0,
		0x00,
		0x00,
		0x00,
		0x0C,
		'j',
		'x',
		'l',
		'c',
		0xFF,
		0x0A,
		0xAA,
		0xBB,
	}
	cs, ok := jxlc_decode(data[:])
	testing.expect(t, ok, "decode jxlc container")
	testing.expect(t, bytes.equal(cs, {0xFF, 0x0A, 0xAA, 0xBB}), "jxlc payload")
	testing.expect(t, raw_data(cs) == raw_data(data[36:]), "jxlc is zero-copy")
}

@(test)
jxl_container_single_jxlp :: proc(t: ^testing.T) {
	data := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x10,
		'j',
		'x',
		'l',
		'p',
		0x80,
		0x00,
		0x00,
		0x00,
		0xFF,
		0x0A,
		1,
		2,
	}
	cs, ok := jxlc_decode(data[:])
	testing.expect(t, ok, "decode single-chunk jxlp")
	testing.expect(t, bytes.equal(cs, {0xFF, 0x0A, 1, 2}), "single jxlp payload")
	testing.expect(t, raw_data(cs) == raw_data(data[24:]), "single jxlp is zero-copy")
}

@(test)
jxl_container_multi_jxlp :: proc(t: ^testing.T) {
	// Two jxlp chunks separated by a non-codestream box.
	data := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0E,
		'j',
		'x',
		'l',
		'p',
		0x00,
		0x00,
		0x00,
		0x00,
		0xFF,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0C,
		'E',
		'x',
		'i',
		'f',
		0,
		0,
		0,
		0,
		0x00,
		0x00,
		0x00,
		0x0F,
		'j',
		'x',
		'l',
		'p',
		0x80,
		0x00,
		0x00,
		0x01,
		0x11,
		0x22,
		0x33,
	}
	cs, ok := jxlc_decode(data[:], context.allocator)
	testing.expect(t, ok, "decode multi-chunk jxlp")
	if ok {
		defer delete(cs)
		testing.expect(
			t,
			bytes.equal(cs, {0xFF, 0x0A, 0x11, 0x22, 0x33}),
			"concatenated jxlp codestream",
		)
	}
}

@(test)
jxl_invalid_inputs :: proc(t: ^testing.T) {
	// Empty / 1-byte
	_, ok_empty := jxlc_decode(nil)
	testing.expect(t, !ok_empty, "reject empty input")
	one := [?]u8{0xFF}
	_, ok_one := jxlc_decode(one[:])
	testing.expect(t, !ok_one, "reject 1-byte input")

	// Bad container signature
	bad_sig := [?]u8{0, 0, 0, 12, 'f', 't', 'y', 'p', 0, 0, 0, 0}
	_, ok_sig := jxlc_decode(bad_sig[:])
	testing.expect(t, !ok_sig, "reject bad signature")

	// Missing final jxlp flag
	unterminated := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0E,
		'j',
		'x',
		'l',
		'p',
		0x00,
		0x00,
		0x00,
		0x00,
		0xFF,
		0x0A,
	}
	_, ok_unterm := jxlc_decode(unterminated[:])
	testing.expect(t, !ok_unterm, "reject unterminated jxlp stream")

	// Out-of-order jxlp sequence
	bad_seq := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0E,
		'j',
		'x',
		'l',
		'p',
		0x00,
		0x00,
		0x00,
		0x00,
		0xFF,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0E,
		'j',
		'x',
		'l',
		'p',
		0x80,
		0x00,
		0x00,
		0x02,
		0x11,
		0x22,
	}
	_, ok_seq := jxlc_decode(bad_seq[:])
	testing.expect(t, !ok_seq, "reject out-of-order jxlp sequence")

	// jxlp payload shorter than 4-byte counter
	short_jxlp := [?]u8 {
		0x00,
		0x00,
		0x00,
		0x0C,
		'J',
		'X',
		'L',
		' ',
		0x0D,
		0x0A,
		0x87,
		0x0A,
		0x00,
		0x00,
		0x00,
		0x0B,
		'j',
		'x',
		'l',
		'p',
		0x80,
		0x00,
		0x00,
	}
	_, ok_short := jxlc_decode(short_jxlp[:])
	testing.expect(t, !ok_short, "reject jxlp without 4-byte counter")
}

@(test)
jxl_codestream_dimension_fixture :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("test/fixture/media/thumbnail.jxl", context.allocator)
	if !testing.expect(t, err == nil, "read thumbnail.jxl fixture") {return}
	defer delete(data)

	cs, cs_ok := jxlc_decode(data)
	if !testing.expect(t, cs_ok, "decode thumbnail.jxl codestream") {return}

	w, h, ok := jxl_codestream_dimension(cs)
	testing.expect(t, ok && w == 192 && h == 128, "thumbnail.jxl dimensions are 192x128")
}
