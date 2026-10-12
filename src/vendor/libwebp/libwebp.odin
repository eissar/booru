package libwebp

import "core:c"

// Requires libwebp (input encoding) and webpinfo (output validation).
foreign import webp "system:webp"

WEBP_ENCODER_ABI_VERSION :: 0x0210

// Mirrors of encode.h structs. Keep field order identical to the C headers.
WebPConfig :: struct {
	lossless:          c.int,
	quality:           c.float,
	method:            c.int,
	image_hint:        c.int,
	target_size:       c.int,
	target_PSNR:       c.float,
	segments:          c.int,
	sns_strength:      c.int,
	filter_strength:   c.int,
	filter_sharpness:  c.int,
	filter_type:       c.int,
	autofilter:        c.int,
	alpha_compression: c.int,
	alpha_filtering:   c.int,
	alpha_quality:     c.int,
	pass:              c.int,
	show_compressed:   c.int,
	preprocessing:     c.int,
	partitions:        c.int,
	partition_limit:   c.int,
	emulate_jpeg_size: c.int,
	thread_level:      c.int,
	low_memory:        c.int,
	near_lossless:     c.int,
	exact:             c.int,
	use_delta_palette: c.int,
	use_sharp_yuv:     c.int,
	qmin:              c.int,
	qmax:              c.int,
}

WebPPicture :: struct {
	use_argb:        c.int,
	colorspace:      c.int,
	width:           c.int,
	height:          c.int,
	y, u, v:         [^]u8,
	y_stride:        c.int,
	uv_stride:       c.int,
	a:               [^]u8,
	a_stride:        c.int,
	pad1:            [2]u32,
	argb:            [^]u32,
	argb_stride:     c.int,
	pad2:            [3]u32,
	writer:          WebPWriterFunction,
	custom_ptr:      rawptr,
	extra_info_type: c.int,
	extra_info:      [^]u8,
	stats:           rawptr,
	error_code:      c.int,
	progress_hook:   rawptr,
	user_data:       rawptr,
	pad3:            [3]u32,
	pad4, pad5:      [^]u8,
	pad6:            [8]u32,
	memory_:         rawptr,
	memory_argb_:    rawptr,
	pad7:            [2]rawptr,
}

WebPWriterFunction :: proc "c" (data: [^]u8, data_size: c.size_t, picture: ^WebPPicture) -> c.int

WebPMemoryWriter :: struct {
	mem:      [^]u8,
	size:     c.size_t,
	max_size: c.size_t,
	pad:      [1]u32,
}

foreign webp {
	WebPEncodeRGB :: proc(rgb: ^u8, width, height, stride: c.int, quality: c.float, output: ^^u8) -> c.size_t ---
	WebPDecodeRGB :: proc(data: [^]u8, data_size: c.size_t, width, height: ^c.int) -> ^u8 ---
	WebPDecodeYUV :: proc(data: [^]u8, data_size: c.size_t, width, height: ^c.int, u, v: ^^u8, stride, uv_stride: ^c.int) -> ^u8 ---
	WebPFree :: proc(p: rawptr) ---

	WebPConfigInitInternal :: proc(config: ^WebPConfig, preset: c.int, quality: c.float, version: c.int) -> c.int ---
	WebPPictureInitInternal :: proc(picture: ^WebPPicture, version: c.int) -> c.int ---
	WebPPictureImportRGB :: proc(picture: ^WebPPicture, rgb: [^]u8, rgb_stride: c.int) -> c.int ---
	WebPPictureRescale :: proc(picture: ^WebPPicture, width, height: c.int) -> c.int ---
	WebPPictureFree :: proc(picture: ^WebPPicture) ---
	WebPEncode :: proc(config: ^WebPConfig, picture: ^WebPPicture) -> c.int ---
	WebPMemoryWriterInit :: proc(writer: ^WebPMemoryWriter) ---
	WebPMemoryWriterClear :: proc(writer: ^WebPMemoryWriter) ---
	WebPMemoryWrite :: proc "c" (data: [^]u8, data_size: c.size_t, picture: ^WebPPicture) -> c.int ---
}
