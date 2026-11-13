package thumbnail

import "core:c"
import "core:fmt"
import "core:os"

import "../library"
import "../media"
import libwebp "../vendor/libwebp"

VIDEO_THUMBNAIL :: bit_set[media.Format] {
	.MP4,
	.MOV,
	.M4V,
	.ThreeGP,
	.WebM,
	.MKV,
	.AVI,
	.OGV,
	.MPG,
	.MPV,
	.WMV,
	.FLV,
}

SUPPORTED_THUMBNAIL :: bit_set[media.Format]{.PNG, .JPEG, .GIF, .WebP, .AVIF} | VIDEO_THUMBNAIL

// 8K^2 pixel limit (~256 MiB RGBA) for thumbnail source decoding.
MAX_THUMBNAIL_SOURCE_PIXELS :: 8192 * 8192

encode_thumbnail_argb :: proc(root, oid: string, edge: c.int, img: media.Decoded_ARGB) -> bool {
	dir := fmt.tprintf("%s/thumbnails/%d", root, edge)
	if err := os.mkdir_all(dir, os.Permissions_Default_Directory); err != nil && err != .Exist {
		fmt.eprintfln("thumbnail: mkdir %s: %v", dir, err)
		return false
	}
	path := fmt.tprintf("%s/%s.webp", dir, oid)
	// Exclusive creation also protects a thumbnail created since the scan.
	file, err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if err == .Exist {return true}
	if err != nil {
		fmt.eprintfln("thumbnail: open %s: %v", path, err)
		return false
	}
	pic: libwebp.WebPPicture
	initialized := libwebp.WebPPictureInitInternal(&pic, 0x0210) != 0
	defer libwebp.WebPPictureFree(&pic)
	pic.width, pic.height = img.width, img.height
	ok := initialized
	pic.use_argb = 1
	ok = ok && libwebp.WebPPictureImportRGBA(&pic, img.pixels, img.width * 4) != 0
	if ok {ok = libwebp.rescale(&pic, file, edge)}
	close_err := os.close(file)
	if !ok || close_err != nil {
		os.remove(path)
		fmt.eprintfln("thumbnail: encode/write failed: %s", path)
		return false
	}
	return true
}

encode_thumbnail_yuv :: proc(
	root, oid: string,
	edge: c.int,
	img: media.Decoded_YUV,
	alpha: ^media.Decoded_YUV = nil,
) -> bool {
	if alpha != nil && (alpha.width != img.width || alpha.height != img.height) {
		fmt.eprintfln("thumbnail: alpha dimensions do not match: %s", oid)
		return false
	}
	dir := fmt.tprintf("%s/thumbnails/%d", root, edge)
	if err := os.mkdir_all(dir, os.Permissions_Default_Directory); err != nil && err != .Exist {
		fmt.eprintfln("thumbnail: mkdir %s: %v", dir, err)
		return false
	}
	path := fmt.tprintf("%s/%s.webp", dir, oid)
	// Exclusive creation also protects a thumbnail created since the scan.
	file, err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if err == .Exist {return true}
	if err != nil {
		fmt.eprintfln("thumbnail: open %s: %v", path, err)
		return false
	}
	pic: libwebp.WebPPicture
	initialized := libwebp.WebPPictureInitInternal(&pic, 0x0210) != 0
	defer libwebp.WebPPictureFree(&pic)
	pic.width, pic.height = img.width, img.height
	ok := initialized
	pic.y, pic.u, pic.v = img.y, img.u, img.v
	pic.y_stride = c.int(img.y_stride)
	pic.uv_stride = c.int(img.uv_stride)
	if alpha != nil {
		pic.colorspace = libwebp.WEBP_YUV420A
		pic.a = alpha.y
		pic.a_stride = c.int(alpha.y_stride)
	} else if img.a != nil {
		pic.colorspace = libwebp.WEBP_YUV420A
		pic.a = img.a
		pic.a_stride = c.int(img.a_stride)
	}
	if ok {ok = libwebp.rescale(&pic, file, edge)}
	close_err := os.close(file)
	if !ok || close_err != nil {
		os.remove(path)
		fmt.eprintfln("thumbnail: encode/write failed: %s", path)
		return false
	}
	return true
}

encode_thumbnail_frame :: proc(
	root, oid: string,
	edge: c.int,
	frame: media.Decoded_Frame,
) -> bool {
	switch f in frame {
	case media.Decoded_ARGB:
		return encode_thumbnail_argb(root, oid, edge, f)
	case media.Decoded_YUV:
		return encode_thumbnail_yuv(root, oid, edge, f)
	}
	return false
}

encode_thumbnail :: proc {
	encode_thumbnail_argb,
	encode_thumbnail_yuv,
	encode_thumbnail_frame,
	encode_thumbnail_video,
}

// Decodes the first video frame of `path` and encodes it at `edge`, one WebP.
encode_thumbnail_video :: proc(root, oid: string, edge: c.int, path: string) -> bool {
	img, err := media.decode_video_first_frame(path, MAX_THUMBNAIL_SOURCE_PIXELS)
	if err != .None {
		fmt.eprintfln("thumbnail: cannot decode video %s: %v", oid, err)
		return false
	}
	defer media.free_decoded(&img)
	return encode_thumbnail_yuv(root, oid, edge, img)
}


generate_image_thumbnails :: proc(
	s: library.State,
	img: library.Image,
	sizes: bit_set[LOD_RESOLUTION],
) -> (
	generated, failed: int,
) {
	oid := img.oid
	img_path := fmt.tprintf("%s/images/%d.%s", s.library_path, img.id, img.ext)
	format, sniff_err := media.hack_sniff_first_32_bytes(img_path)
	if sniff_err != nil {
		fmt.eprintfln("thumbnail: sniff %s: %v", oid, sniff_err)
		return 0, card(sizes)
	}
	if format not_in SUPPORTED_THUMBNAIL {return 0, 0}
	#partial switch format {
	case .MP4, .MOV, .M4V, .ThreeGP, .WebM, .MKV, .AVI, .OGV, .MPG, .MPV, .WMV, .FLV:
		// Video formats generate their thumbnails inline: only the first
		// frame is decoded, never read into memory whole.
		for size in sizes {
			edge: c.int
			#partial switch size {
			case .x64:
				edge = 64
			case .x128:
				edge = 128
			case:
				continue
			}
			if encode_thumbnail(s.library_path, oid, edge, img_path) {
				generated += 1
			} else {
				failed += 1
			}
		}
		return
	}
	data, err := os.read_entire_file(img_path, context.allocator)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
	frame: media.Decoded_Frame
	alpha: media.Decoded_YUV
	alpha_picture: ^media.Decoded_YUV
	defer media.free_decoded(&frame)
	defer media.free_decoded(&alpha)
	#partial switch format {
	case .AVIF:
		offset, length, alpha_offset, alpha_length, ok := media.avif_decode(data)
		if !ok {
			fmt.eprintfln("thumbnail: cannot extract AVIF primary item: %s", oid)
			return 0, card(sizes)
		}
		yuv, decode_err := media.decode_yuv_dav1d(
			data[offset:offset + length],
			max_pixels = MAX_THUMBNAIL_SOURCE_PIXELS,
		)
		if decode_err != .None {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
		frame = yuv
		if alpha_length != 0 {
			alpha, decode_err = media.decode_yuv_dav1d(
				data[alpha_offset:alpha_offset + alpha_length],
				.I400,
				MAX_THUMBNAIL_SOURCE_PIXELS,
			)
			if decode_err != .None {
				fmt.eprintfln("thumbnail: cannot decode alpha %s: %v", oid, decode_err)
				return 0, card(sizes)
			}
			alpha_picture = &alpha
		}
	case .PNG, .JPEG, .GIF, .WebP:
		decoded, decode_err := media.decode_rgba(data, MAX_THUMBNAIL_SOURCE_PIXELS)
		if decode_err == .Too_Large {
			fmt.eprintfln(
				"thumbnail: skipping oversized image %s (%dx%d, limit %d pixels; non bounded thumbnail generation unimplemented)",
				oid,
				decoded.width,
				decoded.height,
				MAX_THUMBNAIL_SOURCE_PIXELS,
			)
			return 0, card(sizes)
		}
		if decoded.pixels == nil {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
		frame = decoded
	case:
		return 0, 0
	}
	for size in sizes {
		edge: c.int
		#partial switch size {
		case .x64:
			edge = 64
		case .x128:
			edge = 128
		case:
			continue
		}
		ok: bool
		if alpha_picture != nil {
			ok = encode_thumbnail(
				s.library_path,
				oid,
				edge,
				frame.(media.Decoded_YUV),
				alpha_picture,
			)
		} else {
			ok = encode_thumbnail(s.library_path, oid, edge, frame)
		}
		if ok {
			generated += 1
		} else {
			failed += 1
		}
	}
	return
}

//HACK: Force regeneration by removing existing thumbnails before encoding.
force_generate_image_thumbnails :: proc(
	s: library.State,
	img: library.Image,
	sizes: bit_set[LOD_RESOLUTION],
) -> (
	generated, failed: int,
) {
	oid := img.oid
	img_path := fmt.tprintf("%s/images/%d.%s", s.library_path, img.id, img.ext)
	format, sniff_err := media.hack_sniff_first_32_bytes(img_path)
	if sniff_err != nil {
		fmt.eprintfln("thumbnail: sniff %s: %v", oid, sniff_err)
		return 0, card(sizes)
	}
	if format not_in SUPPORTED_THUMBNAIL {return 0, 0}
	#partial switch format {
	case .MP4, .MOV, .M4V, .ThreeGP, .WebM, .MKV, .AVI, .OGV, .MPG, .MPV, .WMV, .FLV:
		// Video formats generate their thumbnails inline: only the first
		// frame is decoded, never read into memory whole.
		for size in sizes {
			edge: c.int
			#partial switch size {
			case .x64:
				edge = 64
			case .x128:
				edge = 128
			case:
				continue
			}
			path := fmt.tprintf("%s/thumbnails/%d/%s.webp", s.library_path, edge, oid)
			if err := os.remove(path); err != nil && err != .Not_Exist {
				fmt.eprintfln("thumbnail: remove %s: %v", path, err)
				failed += 1
				continue
			}
			if encode_thumbnail(s.library_path, oid, edge, img_path) {
				generated += 1
			} else {
				failed += 1
			}
		}
		return
	}
	data, err := os.read_entire_file(img_path, context.allocator)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
	frame: media.Decoded_Frame
	alpha: media.Decoded_YUV
	alpha_picture: ^media.Decoded_YUV
	defer media.free_decoded(&frame)
	defer media.free_decoded(&alpha)
	#partial switch format {
	case .AVIF:
		offset, length, alpha_offset, alpha_length, ok := media.avif_decode(data)
		if !ok {
			fmt.eprintfln("thumbnail: cannot extract AVIF primary item: %s", oid)
			return 0, card(sizes)
		}
		yuv, decode_err := media.decode_yuv_dav1d(
			data[offset:offset + length],
			max_pixels = MAX_THUMBNAIL_SOURCE_PIXELS,
		)
		if decode_err != .None {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
		frame = yuv
		if alpha_length != 0 {
			alpha, decode_err = media.decode_yuv_dav1d(
				data[alpha_offset:alpha_offset + alpha_length],
				.I400,
				MAX_THUMBNAIL_SOURCE_PIXELS,
			)
			if decode_err != .None {
				fmt.eprintfln("thumbnail: cannot decode alpha %s: %v", oid, decode_err)
				return 0, card(sizes)
			}
			alpha_picture = &alpha
		}
	case .PNG, .JPEG, .GIF, .WebP:
		decoded, decode_err := media.decode_rgba(data, MAX_THUMBNAIL_SOURCE_PIXELS)
		if decode_err == .Too_Large {
			fmt.eprintfln(
				"thumbnail: skipping oversized image %s (%dx%d, limit %d pixels; non bounded thumbnail generation unimplemented)",
				oid,
				decoded.width,
				decoded.height,
				MAX_THUMBNAIL_SOURCE_PIXELS,
			)
			return 0, card(sizes)
		}
		if decoded.pixels == nil {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
		frame = decoded
	case:
		return 0, 0
	}
	for size in sizes {
		edge: c.int
		#partial switch size {
		case .x64:
			edge = 64
		case .x128:
			edge = 128
		case:
			continue
		}
		path := fmt.tprintf("%s/thumbnails/%d/%s.webp", s.library_path, edge, oid)
		if err := os.remove(path); err != nil && err != .Not_Exist {
			fmt.eprintfln("thumbnail: remove %s: %v", path, err)
			failed += 1
			continue
		}
		ok: bool
		if alpha_picture != nil {
			ok = encode_thumbnail(
				s.library_path,
				oid,
				edge,
				frame.(media.Decoded_YUV),
				alpha_picture,
			)
		} else {
			ok = encode_thumbnail(s.library_path, oid, edge, frame)
		}
		if ok {
			generated += 1
		} else {
			failed += 1
		}
	}
	return
}
