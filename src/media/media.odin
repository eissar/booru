// Package media handles format detection, dimension probing, and decoding
// supported media formats (raster images, AVIF, and video first frames) into a
// format-agnostic decoded frame or pixel representation, with any pixel-count
// limit supplied by callers rather than hardcoded.
package media
import dav1d "../vendor/dav1d"
import ffmpeg "../vendor/ffmpeg"
import libwebp "../vendor/libwebp"
import "core:c"
import "core:fmt"
import "core:os"
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

// Owns a decoded YUV frame reference (and optional alpha plane); do not free
// copies of the same result. Plane pointers remain valid until free_decoded_yuv.
Decoded_YUV :: struct {
	y, u, v:       [^]u8,
	y_stride:      int,
	uv_stride:     int,
	a:             [^]u8,
	a_stride:      int,
	width, height: c.int,
	backing:       union {
		dav1d.Dav1dPicture,
		ffmpeg.Decoded_Frame,
	},
	alpha_picture: dav1d.Dav1dPicture,
}

// Zero-copy strided RGB24 view backed by an ffmpeg.Decoded_Frame so callers
// like WebPPictureImportRGB can consume FFmpeg's pixel buffer directly without
// allocating or expanding to RGBA.
Decoded_RGB24 :: struct {
	pixels:        [^]u8,
	stride:        c.int,
	width, height: c.int,
	backing:       ffmpeg.Decoded_Frame,
}

Decoded_Frame :: union {
	Decoded_ARGB,
	Decoded_YUV,
	Decoded_RGB24,
}

Decode_Error :: enum {
	None,
	Failed,
	Unsupported,
	Too_Large,
}

// Takes extracted AV1 bytes, not an AVIF container. Accepts 8-bit I420 or I400.
// Use I400 for alpha; its samples are returned in y, with no chroma planes.
// Input is borrowed for this call; the returned picture owns its planes.
// If max_pixels > 0, frames exceeding that pixel count fail to decode.
decode_yuv_dav1d :: proc(
	data: []u8,
	layout: dav1d.Dav1dPixelLayout = .I420,
	max_pixels: i64 = 0,
) -> (
	img: Decoded_YUV,
	err: Decode_Error,
) {
	if len(data) == 0 {return {}, .Failed}
	if layout != .I420 && layout != .I400 {return {}, .Unsupported}

	settings: dav1d.Dav1dSettings
	dav1d.dav1d_default_settings(&settings)
	if max_pixels > 0 {
		settings.frame_size_limit = c.uint(min(max_pixels, i64(max(c.uint))))
	}

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

	if pic.p.bpc != 8 || pic.p.layout != layout {
		dav1d.dav1d_picture_unref(&pic)
		return {}, .Unsupported
	}

	return Decoded_YUV {
			y = ([^]u8)(pic.data[0]),
			u = ([^]u8)(pic.data[1]),
			v = ([^]u8)(pic.data[2]),
			y_stride = int(pic.stride[0]),
			uv_stride = int(pic.stride[1]),
			width = pic.p.w,
			height = pic.p.h,
			backing = pic,
		},
		.None
}


// probe_dimensions reads image dimensions from headers without decoding pixels.
// Returns ok = false for unsupported/video formats or malformed headers.
probe_dimensions :: proc(data: []u8, format: Format) -> (width, height: c.int, ok: bool) {
	if len(data) == 0 || len(data) > int(max(c.int)) {return 0, 0, false}
	p, n := raw_data(data), len(data)
	#partial switch format {
	case .WebP:
		if libwebp.WebPGetInfo(p, c.size_t(n), &width, &height) == 0 {return 0, 0, false}
	case .PNG, .JPEG, .GIF:
		comp: c.int
		if stbi.info_from_memory(p, c.int(n), &width, &height, &comp) == 0 {return 0, 0, false}
	case .AVIF:
		offset, length, _, _, avif_ok := avif_decode(data)
		if !avif_ok {return 0, 0, false}
		yuv, err := decode_yuv_dav1d(data[offset:offset + length])
		if err != .None {return 0, 0, false}
		defer free_decoded_yuv(&yuv)
		width, height = yuv.width, yuv.height
	case:
		fmt.eprintfln("media: probe_dimensions called on unsupported format: %v", format)
		return 0, 0, false
	}
	if width <= 0 || height <= 0 {return 0, 0, false}
	return width, height, true
}

decode_rgba :: proc(data: []u8, max_pixels: i64 = 0) -> (img: Decoded_ARGB, err: Decode_Error) {
	if len(data) == 0 || len(data) > int(max(c.int)) {return {}, .Failed}
	format := detect_format(data)
	if format != .WebP && format != .PNG && format != .JPEG && format != .GIF {
		return {}, .Unsupported
	}
	w, h, ok := probe_dimensions(data, format)
	if !ok {return {}, .Failed}
	img.width, img.height = w, h
	if max_pixels > 0 && i64(w) * i64(h) > max_pixels {
		return img, .Too_Large
	}

	p, n := raw_data(data), len(data)
	#partial switch format {
	case .WebP:
		img.free_pixels = libwebp.WebPFree
		img.pixels = libwebp.WebPDecodeRGBA(p, c.size_t(n), &img.width, &img.height)
	case .PNG, .JPEG, .GIF:
		img.free_pixels = stbi.image_free
		img.pixels = stbi.load_from_memory(p, c.int(n), &img.width, &img.height, nil, 4)
	}
	if img.pixels == nil {return {}, .Failed}
	return img, .None
}

free_decoded_rgba :: proc(img: Decoded_ARGB) {
	if img.pixels != nil {img.free_pixels(img.pixels)}
}

free_decoded_yuv :: proc(img: ^Decoded_YUV) {
	switch &b in img.backing {
	case dav1d.Dav1dPicture:
		dav1d.dav1d_picture_unref(&b)
	case ffmpeg.Decoded_Frame:
		ffmpeg.free_decoded_frame(&b)
	}
	if img.a != nil {
		dav1d.dav1d_picture_unref(&img.alpha_picture)
	}
	img^ = {}
}

free_decoded_frame :: proc(frame: ^Decoded_Frame) {
	switch &f in frame {
	case Decoded_ARGB:
		free_decoded_rgba(f)
	case Decoded_YUV:
		free_decoded_yuv(&f)
	case Decoded_RGB24:
		ffmpeg.free_decoded_frame(&f.backing)
	}
	frame^ = nil
}

decode_video_first_frame :: proc(
	path: string,
	max_pixels: i64 = 0,
) -> (
	img: Decoded_YUV,
	err: Decode_Error,
) {
	ff, ok := ffmpeg.first_frame(path)
	if !ok {return {}, .Failed}
	if ff.pix_fmt != ffmpeg.AV_PIX_FMT_YUV420P && ff.pix_fmt != ffmpeg.AV_PIX_FMT_YUVJ420P {
		ffmpeg.free_decoded_frame(&ff)
		return {}, .Unsupported
	}
	if max_pixels > 0 && i64(ff.width) * i64(ff.height) > max_pixels {
		w, h := ff.width, ff.height
		ffmpeg.free_decoded_frame(&ff)
		return {width = w, height = h}, .Too_Large
	}
	return Decoded_YUV {
			y = ff.y,
			u = ff.u,
			v = ff.v,
			y_stride = int(ff.y_stride),
			uv_stride = int(ff.uv_stride),
			width = ff.width,
			height = ff.height,
			backing = ff,
		},
		.None
}

free_decoded :: proc {
	free_decoded_rgba,
	free_decoded_yuv,
	free_decoded_frame,
}

// Decodes a still image or first video frame from `path`.
// Returns .Unsupported for formats that cannot be decoded, .Too_Large when
// dimensions exceed max_pixels (if > 0), and .Failed on I/O or decode errors.
decode_frame :: proc(
	path: string,
	max_pixels: i64 = 0,
) -> (
	frame: Decoded_Frame,
	err: Decode_Error,
) {
	format, sniff_err := hack_sniff_first_32_bytes(path)
	if sniff_err != nil {return nil, .Failed}
	switch format {
	case .MP4, .MOV, .M4V, .ThreeGP, .WebM, .MKV, .AVI, .OGV, .MPG, .MPV, .WMV, .FLV:
		// Video formats decode only the first frame, never reading the whole file.
		return decode_video_first_frame(path, max_pixels)
	case .JXL:
		// Scope: JXL decode currently targets 8-bit opaque RGB24 only.
		ff, ok := ffmpeg.first_frame(path)
		if !ok {return nil, .Failed}
		if ff.pix_fmt != ffmpeg.AV_PIX_FMT_RGB24 {
			ffmpeg.free_decoded_frame(&ff)
			return nil, .Unsupported
		}
		if ff.width <= 0 || ff.height <= 0 || ff.y == nil {
			ffmpeg.free_decoded_frame(&ff)
			return nil, .Failed
		}
		if max_pixels > 0 && i64(ff.width) * i64(ff.height) > max_pixels {
			ffmpeg.free_decoded_frame(&ff)
			return nil, .Too_Large
		}
		return Decoded_RGB24 {
				pixels = ff.y,
				stride = ff.y_stride,
				width = ff.width,
				height = ff.height,
				backing = ff,
			},
			.None
	case .AVIF, .PNG, .JPEG, .GIF, .WebP:
	case .Unknown:
		return nil, .Unsupported
	}

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {return nil, .Failed}
	defer delete(data)

	#partial switch format {
	case .AVIF:
		offset, length, alpha_offset, alpha_length, ok := avif_decode(data)
		if !ok {return nil, .Failed}
		yuv, decode_err := decode_yuv_dav1d(data[offset:offset + length], max_pixels = max_pixels)
		if decode_err != .None {return nil, decode_err}
		if alpha_length != 0 {
			alpha, alpha_err := decode_yuv_dav1d(
				data[alpha_offset:alpha_offset + alpha_length],
				.I400,
				max_pixels,
			)
			if alpha_err != .None {
				free_decoded_yuv(&yuv)
				return nil, alpha_err
			}
			if alpha.width != yuv.width || alpha.height != yuv.height {
				free_decoded_yuv(&yuv)
				free_decoded_yuv(&alpha)
				return nil, .Failed
			}
			yuv.a = alpha.y
			yuv.a_stride = alpha.y_stride
			yuv.alpha_picture = alpha.backing.(dav1d.Dav1dPicture)
		}
		return yuv, .None
	case .PNG, .JPEG, .GIF, .WebP:
		return decode_rgba(data, max_pixels)
	}
	return nil, .Unsupported
}
