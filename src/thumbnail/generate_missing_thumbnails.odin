package thumbnail

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import win "core:sys/windows"

import "../dirlist"
import "../library"
import "../media"
import "../store"
import libwebp "../vendor/libwebp"
import "../vendor/sqlite"


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

// Generate only missing resolutions; failures are logged and do not prevent startup.
generate_missing_thumbnails :: proc(s: library.State) -> (generated, failed: int) {
	missing := make(map[string]bit_set[LOD_RESOLUTION])
	defer delete(missing)
	find_missing_thumbnails(s, &missing)
	log.info("thumbnails: generate missing start")
	// Intentionally naive: SELECT everything and loop over the rows.
	images, rc := store.read_images(s.data_store, context.temp_allocator)
	if rc != sqlite.OK {
		fmt.eprintfln("thumbnail: read items: sqlite rc=%d", rc)
		return
	}
	for img in images {
		sizes, exists := missing[img.oid]
		if !exists {continue}
		n, f := generate_image_thumbnails(s, img, sizes)
		generated += n
		failed += f
	}
	return
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
}

resolution_pixels :: proc(size: LOD_RESOLUTION) -> int {
	// Enum order: x1024, x512, x256, x128, x64.
	return 1024 >> uint(size)
}

// Returns the largest resolution; ok is false for an empty set.
largest_resolution :: proc(sizes: bit_set[LOD_RESOLUTION]) -> (largest: LOD_RESOLUTION, ok: bool) {
	for size in sizes {
		// Smaller enum values represent larger resolutions.
		if !ok || size < largest {
			largest = size
			ok = true
		}
	}
	return
}

name_for_r := #partial [LOD_RESOLUTION]string {
	.x64  = "64",
	.x128 = "128",
}

// Seeds candidate OIDs from the store, then excludes existing thumbnail sizes.
find_missing_thumbnails :: proc(
	s: library.State,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128},
) {
	images, rc := store.read_images(s.data_store, context.temp_allocator)
	if rc != sqlite.OK {
		fmt.eprintfln("thumbnail: read items: sqlite rc=%d", rc)
		return
	}
	for img in images {
		check[img.oid] = resolutions
	}
	exclude_existing_thumbnails(s, check, resolutions)
}

// Resets caller-seeded OIDs to resolutions, then subtracts sizes found on disk.
// Does not add OIDs to check.
exclude_existing_thumbnails :: proc(
	s: library.State,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128},
) {
	for _, &entry in check {
		// set the list of res to check.
		// when we scan, we will remove
		// any matches for this entry
		entry = resolutions
	}

	// scan
	for res in resolutions {
		res_name := name_for_r[res]

		// open directory for a resolution
		// to check what oids are present
		pth := fmt.aprintf(
			"%v/thumbnails/%v",
			s.library_path,
			res_name,
			allocator = context.temp_allocator,
		)
		osf_for_r, open_err := os.open(pth, {.Read}, os.Permissions_Default_Directory)
		if open_err != nil {
			// if we can't open the directory for reading,
			// consider them all missing ?
			continue
		}
		defer os.close(osf_for_r)


		if ODIN_OS != .Windows && ODIN_OS != .Linux {
			panic("unsupported os")
		}
		when ODIN_OS == .Linux {
			dents_buf: [32 * 1024]u8 = ---
			for {
				n, err := linux.getdents(linux.Fd(os.fd(osf_for_r)), dents_buf[:])
				if err != nil {return}
				if n == 0 {break} 	// end of directory
				offset := 0
				for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
					name := linux.dirent_name(entry)
					if !strings.has_suffix(name, ".webp") {continue}
					oid := name[:len(name) - len(".webp")]
					if oid in check {
						check[oid] -= {res}
					}
				}
			}
		} else when ODIN_OS == .Windows {
			nt_buf: [4 * 1024]u64 = ---
			names := make([dynamic]string, 0, 1024)
			defer delete(names)
			for {
				clear(&names)
				n, ok := dirlist.read_batch(win.HANDLE(os.fd(osf_for_r)), nt_buf[:], &names, false)
				if !ok {return}
				if n == 0 {break} 	// end of directory
				for name in names {
					if !strings.has_suffix(name, ".webp") {continue}
					oid := name[:len(name) - len(".webp")]
					if oid in check {
						check[oid] -= {res}
					}
				}
			}
		}

	}
}
