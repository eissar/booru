package thumbnail

import "core:c"
import "core:fmt"
import "core:os"

import "../library"
import libwebp "../vendor/libwebp"

write_missing_thumbnail :: proc(
	root, oid: string,
	edge: c.int,
	y, u, v: ^u8,
	w, h, stride, uv_stride: c.int,
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
	ok := libwebp.rescale(&pic, file, edge)
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
	oid: string,
	sizes: bit_set[library.LOD_RESOLUTION],
) -> (
	generated, failed: int,
) {
	data, err := os.read_entire_file(
		fmt.tprintf("%s/images/%s", s.library_path, oid),
		context.allocator,
	)
	if err != nil {
		fmt.eprintfln("thumbnail: read %s: %v", oid, err)
		return 0, card(sizes)
	}
	defer delete(data)
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
		fmt.eprintfln("thumbnail: cannot decode %s as WebP", oid)
		return 0, card(sizes)
	}
	defer libwebp.WebPFree(y)
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
		if write_missing_thumbnail(s.library_path, oid, edge, y, u, v, w, h, stride, uv_stride) {
			generated += 1
		} else {
			failed += 1
		}
	}
	return
}

// Generate only missing resolutions; failures are logged and do not prevent startup.
generate_missing_thumbnails :: proc(s: library.State) -> (generated, failed: int) {
	missing := make(map[string]bit_set[library.LOD_RESOLUTION])
	defer delete(missing)
	library.find_missing_thumbnails(s, &missing)
	for oid, sizes in missing {
		n, f := generate_image_thumbnails(s, oid, sizes)
		generated += n
		failed += f
	}
	return
}
