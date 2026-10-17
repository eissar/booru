package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

import "../library"
import "../media"
import libwebp "../vendor/libwebp"

generate_thumbnail :: proc {
	generate_thumbnail_argb,
	generate_thumbnail_yuv,
}

generate_thumbnail_argb :: proc(root, oid: string, edge: c.int, img: media.Decoded_ARGB) -> bool {
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

generate_thumbnail_yuv :: proc(
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

generate_image_thumbnails :: proc(
	s: library.State,
	img: library.Image,
	sizes: bit_set[LOD_RESOLUTION],
) -> (
	generated, failed: int,
) {
	oid := img.oid
	id_prefix := fmt.tprintf("%d.", img.id)
	dir, open_err := os.open(fmt.tprintf("%v/images/", s.library_path), {.Read}, {})
	if open_err != nil {return 0, card(sizes)}
	defer os.close(dir)
	img_path := ""
	dents_buf: [32 * 1024]u8
	scan: for {
		n, err := linux.getdents(linux.Fd(os.fd(dir)), dents_buf[:])
		if err != nil || n == 0 {break}
		offset := 0
		for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if strings.has_prefix(name, id_prefix) {
				img_path = fmt.tprintf("%s/images/%s", s.library_path, name)
				break scan
			}
		}
	}
	data, err := os.read_entire_file(img_path, context.allocator)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
	format := media.detect_format(data)
	decoded: media.Decoded_ARGB
	yuv: media.Decoded_Dav1d_YUV
	#partial switch format {
	case .AVIF:
		offset, length, ok := media.Parse_AVIF(data)
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
			ok = generate_thumbnail(s.library_path, oid, edge, yuv)
		} else {
			ok = generate_thumbnail(s.library_path, oid, edge, decoded)
		}
		if ok {
			generated += 1
		} else {
			failed += 1
		}
	}
	return
}

// Generate only missing resolutions; failures are logged and do not prevent startup.
generate_missing_thumbnails :: proc(s: library.State) -> (generated, failed: int) {
	missing := make(map[string]bit_set[LOD_RESOLUTION])
	defer delete(missing)
	find_missing_thumbnails(s, &missing)
	for img in s.library_images {
		sizes, exists := missing[img.oid]
		if !exists {continue}
		n, f := generate_image_thumbnails(s, img, sizes)
		generated += n
		failed += f
	}
	return
}

filter_missing_thumbnails :: proc(
	dfd: ^os.File,
	list: ^map[string]bit_set[LOD_RESOLUTION],
	resolution: LOD_RESOLUTION,
) {
	dents_buf: [32 * 1024]u8

	fd := linux.Fd(os.fd(dfd))

	for {
		n, err := linux.getdents(fd, dents_buf[:])
		if err != nil {return}
		if n == 0 {break} 	// end of directory

		offset := 0
		for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name[0] == '.' {continue} 	// ignore ./../.*

			if !strings.has_suffix(name, ".webp") {continue}
			oid := name[:len(name) - len(".webp")]
			remaining, exists := list^[oid]
			if !exists {continue}
			remaining -= bit_set[LOD_RESOLUTION]{resolution}
			if remaining == {} {
				delete_key(list, oid)
			} else {
				value := &list^[oid]
				value^ = remaining
			}
		}
	}
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
}

find_missing_thumbnails :: proc(s: library.State, missing: ^map[string]bit_set[LOD_RESOLUTION]) {
	resolutions := make(map[string]LOD_RESOLUTION, allocator = context.temp_allocator)
	defer delete(resolutions)
	resolutions["64"] = .x64
	resolutions["128"] = .x128

	for img in s.library_images {
		missing^[img.oid] = {.x64, .x128}
	}

	for n, r in resolutions {
		pth := fmt.aprintf(
			"%v/thumbnails/%v",
			s.library_path,
			n, // e.g. 64
			allocator = context.temp_allocator,
		)
		osf, err := os.open(pth, {.Read}, {})
		if err != nil {
			continue
		}
		filter_missing_thumbnails(osf, missing, r)
		os.close(osf)
	}

	for n, r in resolutions {
		count := 0
		for _, sizes in missing^ {
			if r in sizes {count += 1}
		}
		fmt.printfln("missing %spx thumbnails: %d", n, count)
	}
}
