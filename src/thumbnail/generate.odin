package thumbnail

import "core:c"
import "core:fmt"
import "core:os"

import "../library"
import "../media"
import libwebp "../vendor/libwebp"

SUPPORTED_THUMBNAIL :: bit_set[media.Format]{.PNG, .JPEG, .GIF, .WebP, .AVIF}

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
	img: media.Decoded_Dav1d_YUV,
) -> bool {
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
	if ok {ok = libwebp.rescale(&pic, file, edge)}
	close_err := os.close(file)
	if !ok || close_err != nil {
		os.remove(path)
		fmt.eprintfln("thumbnail: encode/write failed: %s", path)
		return false
	}
	return true
}

encode_thumbnail :: proc {
	encode_thumbnail_argb,
	encode_thumbnail_yuv,
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
	data, err := os.read_entire_file(img_path, context.allocator)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
	decoded: media.Decoded_ARGB
	yuv: media.Decoded_Dav1d_YUV
	#partial switch format {
	case .AVIF:
		offset, length, ok := media.decode(data)
		if !ok {
			fmt.eprintfln("thumbnail: cannot extract AVIF primary item: %s", oid)
			return 0, card(sizes)
		}
		decode_err: media.Decode_Error
		yuv, decode_err = media.decode_yuv_dav1d(data[offset:offset + length])
		if decode_err != .None {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
	case .PNG, .JPEG, .GIF, .WebP:
		decoded, _ = media.decode_rgba(data)
		if decoded.pixels == nil {
			fmt.eprintfln("thumbnail: cannot decode %s", oid)
			return 0, card(sizes)
		}
	case:
		return 0, 0
	}
	defer media.free_decoded(decoded)
	defer media.free_decoded_dav1d(&yuv)
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
		if format == .AVIF {
			ok = encode_thumbnail(s.library_path, oid, edge, yuv)
		} else {
			ok = encode_thumbnail(s.library_path, oid, edge, decoded)
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
	data, err := os.read_entire_file(img_path, context.allocator)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
	decoded: media.Decoded_ARGB
	yuv: media.Decoded_Dav1d_YUV
	#partial switch format {
	case .AVIF:
		offset, length, ok := media.decode(data)
		if !ok {
			fmt.eprintfln("thumbnail: cannot extract AVIF primary item: %s", oid)
			return 0, card(sizes)
		}
		decode_err: media.Decode_Error
		yuv, decode_err = media.decode_yuv_dav1d(data[offset:offset + length])
		if decode_err != .None {
			fmt.eprintfln("thumbnail: cannot decode %s: %v", oid, decode_err)
			return 0, card(sizes)
		}
	case .PNG, .JPEG, .GIF, .WebP:
		decoded, _ = media.decode_rgba(data)
		if decoded.pixels == nil {
			fmt.eprintfln("thumbnail: cannot decode %s", oid)
			return 0, card(sizes)
		}
	case:
		return 0, 0
	}
	defer media.free_decoded(decoded)
	defer media.free_decoded_dav1d(&yuv)
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
		if format == .AVIF {
			ok = encode_thumbnail(s.library_path, oid, edge, yuv)
		} else {
			ok = encode_thumbnail(s.library_path, oid, edge, decoded)
		}
		if ok {
			generated += 1
		} else {
			failed += 1
		}
	}
	return
}
