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
