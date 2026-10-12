package thumbnail

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"

import "../library"
import libwebp "../vendor/libwebp"

// Reads <library_path>/thumbnails/<oid>.webp into memory.
// Caller owns the returned slice and must delete it with `allocator`.
@(private = "file")
read_thumbnail :: proc(
	state: library.State,
	oid: string,
	allocator := context.allocator,
) -> (
	data: []u8,
	err: os.Error,
) {
	path := fmt.tprintf("%s/thumbnails/%s.webp", state.library_path, oid)
	return os.read_entire_file(path, allocator)
}

DEFAULT_CONFIG := libwebp.WebPConfig {
	quality           = 75,
	method            = 4,
	segments          = 4,
	sns_strength      = 50,
	filter_strength   = 60,
	filter_type       = 1,
	alpha_compression = 1,
	alpha_filtering   = 1,
	alpha_quality     = 100,
	pass              = 1,
	near_lossless     = 100,
	qmax              = 100,
}


// Prints the thumbnail size, rescales it to half width/height in YUV 4:2:0,
// re-encodes it, then prints the new size and the % reduction.
// Lossless WebP is decoded to YUV here, which is lossy; acceptable for thumbnails.
// Any error aborts (returns false) without fallback.
rescale_thumbnail_half :: proc(state: library.State, oid: string) -> bool {
	data, err := read_thumbnail(state, oid, context.temp_allocator)
	if err != nil {
		fmt.printfln("read failed: %v", err)
		return false
	}
	fmt.printfln("original: %d bytes", len(data))

	w, h, stride, uv_stride: c.int
	u, v: ^u8
	y := libwebp.WebPDecodeYUV(
		raw_data(data),
		c.size_t(len(data)),
		&w,
		&h,
		&u,
		&v,
		&stride,
		&uv_stride,
	)
	if y == nil {
		fmt.println("decode failed")
		return false
	}
	defer libwebp.WebPFree(y)

	// y/u/v point into the decoder buffer, freed by the defer above.
	pic := libwebp.WebPPicture {
		width     = w,
		height    = h,
		y         = y,
		u         = u,
		v         = v,
		y_stride  = stride,
		uv_stride = uv_stride,
	}
	defer libwebp.WebPPictureFree(&pic)

	new_len, ok := rescale_half1(&pic, &DEFAULT_CONFIG)
	if !ok {
		fmt.printfln("rescale/encode failed: error_code=%d", pic.error_code)
		return false
	}
	reduction := 100.0 * (1.0 - f64(new_len) / f64(len(data)))
	fmt.printfln("rescaled %dx%d: %d bytes (-%.1f%%)", pic.width, pic.height, new_len, reduction)
	return true
}

// Halves the picture and counts encoded bytes without storing them.
// uses DEFAULT_CONFIG if cfg is nil or not passed
// example of using custom_ptr / userdata ptr
// from libwebp
rescale_half1 :: proc(
	pic: ^libwebp.WebPPicture,
	cfg: ^libwebp.WebPConfig = nil,
) -> (
	size: int,
	ok: bool,
) {
	cfg := &DEFAULT_CONFIG if cfg == nil else cfg
	if libwebp.WebPPictureRescale(pic, max(pic.width / 2, 1), max(pic.height / 2, 1)) == 0 {
		return
	}

	pic.writer = proc "c" (
		data: [^]u8,
		data_size: c.size_t,
		picture: ^libwebp.WebPPicture,
	) -> c.int {
		(^int)(picture.custom_ptr)^ += int(data_size)
		return 1
	}
	pic.custom_ptr = &size

	defer pic.custom_ptr = nil
	ok = libwebp.WebPEncode(cfg, pic) != 0
	return
}

// Halves the picture and writes the encoded WebP to file. Caller closes the file.
// TODO: Initialize the writer, picture, and settings once and reuse them for bulk thumbnails.
rescale_half :: proc(
	pic: ^libwebp.WebPPicture,
	file: ^os.File,
	cfg: ^libwebp.WebPConfig = nil,
) -> bool {
	cfg := &DEFAULT_CONFIG if cfg == nil else cfg
	assert(file != nil)

	if libwebp.WebPPictureRescale(pic, max(pic.width / 2, 1), max(pic.height / 2, 1)) == 0 {
		return false
	}

	pic.writer = proc "c" (
		data: [^]u8,
		data_size: c.size_t,
		picture: ^libwebp.WebPPicture,
	) -> c.int {
		context = runtime.default_context()
		file := (^os.File)(picture.custom_ptr)
		bytes := data[:int(data_size)]
		for len(bytes) > 0 {
			n, err := os.write(file, bytes)
			if err != nil || n <= 0 {return 0}
			bytes = bytes[n:]
		}
		return 1
	}
	pic.custom_ptr = file
	defer pic.custom_ptr = nil

	return libwebp.WebPEncode(cfg, pic) != 0
}
