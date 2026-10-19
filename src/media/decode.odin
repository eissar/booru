package media
import dav1d "../vendor/dav1d"
import libwebp "../vendor/libwebp"
import "core:c"
import stbi "vendor:stb/image"

// dav1d reports "try again" as -EAGAIN (DAV1D_ERR(EAGAIN)). EAGAIN is 11 on
// both Linux and the MSVC CRT. Defined locally instead of using
// core:sys/posix, which may not build on Windows; if it does, this constant
// can be dropped in favour of posix.EAGAIN.
EAGAIN :: 11

Decoded_ARGB :: struct {
	pixels:        [^]u8,
	width, height: c.int,
	free_pixels:   proc "c" (_: rawptr),
}

// Owns a dav1d picture reference; do not free copies of the same result.
// Plane pointers remain valid until free_decoded_dav1d.
Decoded_Dav1d_YUV :: struct {
	y, u, v:       [^]u8,
	y_stride:      int,
	uv_stride:     int,
	width, height: c.int,
	picture:       dav1d.Dav1dPicture,
}

Decode_Error :: enum {
	None,
	Failed,
	Unsupported,
}

// Takes extracted AV1 bytes, not an AVIF container. Accepts only 8-bit YUV420.
// Input is borrowed for this call; the returned picture owns its planes.
decode_yuv_dav1d :: proc(data: []u8) -> (img: Decoded_Dav1d_YUV, err: Decode_Error) {
	if len(data) == 0 {return {}, .Failed}

	settings: dav1d.Dav1dSettings
	dav1d.dav1d_default_settings(&settings)
	// TODO: Set a thumbnail source pixel-count limit via settings.frame_size_limit.

	decoder: ^dav1d.Dav1dContext
	if dav1d.dav1d_open(&decoder, &settings) < 0 {return {}, .Failed}
	defer dav1d.dav1d_close(&decoder)

	packet: dav1d.Dav1dData
	p, n := raw_data(data), c.size_t(len(data))
	if dav1d.dav1d_data_wrap(&packet, p, n, proc "c" (_: [^]u8, _: rawptr) {}, nil) < 0 {
		return {}, .Failed
	}
	defer dav1d.dav1d_data_unref(&packet)

	pic: dav1d.Dav1dPicture
	for {
		if packet.sz > 0 {
			err := dav1d.dav1d_send_data(decoder, &packet)
			if err < 0 && err != -EAGAIN {return {}, .Failed}
		}

		err := dav1d.dav1d_get_picture(decoder, &pic)
		if err == 0 {break}
		if err != -EAGAIN {return {}, .Failed}
		if packet.sz == 0 {
			// Input is consumed; the next call drains frame-threaded output.
			if dav1d.dav1d_get_picture(decoder, &pic) != 0 {return {}, .Failed}
			break
		}
	}

	if pic.p.bpc != 8 || pic.p.layout != .I420 {
		dav1d.dav1d_picture_unref(&pic)
		return {}, .Unsupported
	}

	return Decoded_Dav1d_YUV {
			y = ([^]u8)(pic.data[0]),
			u = ([^]u8)(pic.data[1]),
			v = ([^]u8)(pic.data[2]),
			y_stride = int(pic.stride[0]),
			uv_stride = int(pic.stride[1]),
			width = pic.p.w,
			height = pic.p.h,
			picture = pic,
		},
		.None
}


decode_rgba :: proc(data: []u8) -> (img: Decoded_ARGB, err: Decode_Error) {
	if len(data) == 0 || len(data) > int(max(c.int)) {return {}, .Failed}
	format := detect_format(data)
	p, n, w, h := raw_data(data), len(data), &img.width, &img.height
	#partial switch format {
	case .WebP:
		img.free_pixels = libwebp.WebPFree
		img.pixels = libwebp.WebPDecodeRGBA(p, c.size_t(n), w, h)
	case .PNG, .JPEG, .GIF:
		img.free_pixels = stbi.image_free
		img.pixels = stbi.load_from_memory(p, c.int(n), w, h, nil, 4)
	case:
		return {}, .Unsupported
	}
	if img.pixels == nil {return {}, .Failed}
	return img, .None
}

free_decoded_rgba :: proc(img: Decoded_ARGB) {
	if img.pixels != nil {img.free_pixels(img.pixels)}
}

free_decoded_dav1d :: proc(img: ^Decoded_Dav1d_YUV) {
	dav1d.dav1d_picture_unref(&img.picture)
	img^ = {}
}
free_decoded :: proc {
	free_decoded_rgba,
	free_decoded_dav1d,
}
