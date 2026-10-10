package thumbnail

import "core:bytes"
import "core:c"
import "core:testing"

// Requires libwebp and libwebpdemux. Run: odin test src/thumbnail-wip
foreign import webp "system:webp"
foreign import webpdemux "system:webpdemux"

@(private = "file")
WebP_Data :: struct {
	bytes: ^u8,
	size:  c.size_t,
}

foreign webp {
	WebPEncodeRGB :: proc(rgb: ^u8, width, height, stride: c.int, quality: c.float, output: ^^u8) -> c.size_t ---
	WebPFree :: proc(p: rawptr) ---
}

foreign webpdemux {
	WebPAnimDecoderNewInternal :: proc(data: ^WebP_Data, options: rawptr, abi_version: c.int) -> rawptr ---
	WebPAnimDecoderGetNext :: proc(decoder: rawptr, output: ^^u8, timestamp: ^c.int) -> c.int ---
	WebPAnimDecoderDelete :: proc(decoder: rawptr) ---
}

@(test)
vectorized_webp_extended_riff_size :: proc(t: ^testing.T) {
	// Complete 1x1 red, lossy WebP.
	sample := []u8 {
		82,
		73,
		70,
		70,
		60,
		0,
		0,
		0,
		87,
		69,
		66,
		80,
		86,
		80,
		56,
		32,
		48,
		0,
		0,
		0,
		208,
		1,
		0,
		157,
		1,
		42,
		1,
		0,
		1,
		0,
		2,
		0,
		52,
		37,
		160,
		2,
		116,
		186,
		1,
		248,
		0,
		3,
		176,
		0,
		254,
		240,
		196,
		11,
		255,
		32,
		185,
		97,
		117,
		200,
		215,
		255,
		32,
		63,
		228,
		7,
		252,
		128,
		255,
		248,
		242,
		0,
		0,
		0,
	}
	thumbs := [1]Thumb{{bytes = sample, width = 1, height = 1}}
	storage: [9][]u8
	vec := storage[:]
	newThumbnailAtlas(thumbs[:], storage[:], context.temp_allocator)

	expected := []u8{116, 0, 0, 0}
	actual := vec[0][4:8]
	if !testing.expect(
		t,
		bytes.equal(actual, expected),
		"extended RIFF size matches expected bytes",
	) {
		when ODIN_DEBUG {
			dump_hex("expected RIFF size", expected)
			dump_hex("actual RIFF size", actual)
			dump_hex("webp section:", vec[0])
		}
	}
}

@(test)
vectorized_webp_extended_decodes :: proc(t: ^testing.T) {
	// Lossy encoding produces a simple VP8 chunk, as expected by the writer.
	pixel := [3]u8{255, 0, 0}
	encoded: ^u8
	size := WebPEncodeRGB(&pixel[0], 1, 1, 3, 75, &encoded)
	if !testing.expect(t, size > 0 && encoded != nil, "encode input thumbnail") {return}
	defer WebPFree(encoded)

	thumbs := [1]Thumb{{bytes = (cast([^]u8)encoded)[:int(size)], width = 1, height = 1}}
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	segments := Vectorized_Webp_Extended(thumbs[:], int(size) - 12)
	for segment in segments {
		bytes.buffer_write(&buf, segment)
	}

	output := bytes.buffer_to_bytes(&buf)
	data := WebP_Data {
		bytes = &output[0],
		size  = c.size_t(len(output)),
	}
	// WEBP_DEMUX_ABI_VERSION; nil options select the decoder defaults.
	decoder := WebPAnimDecoderNewInternal(&data, nil, 0x0107)
	if !testing.expect(t, decoder != nil, "libwebp accepts generated animation") {return}
	defer WebPAnimDecoderDelete(decoder)

	decoded: ^u8
	timestamp: c.int
	ok := WebPAnimDecoderGetNext(decoder, &decoded, &timestamp)
	testing.expect(t, ok != 0 && decoded != nil, "libwebp successfully decodes frame")
}
