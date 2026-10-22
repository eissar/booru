package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../media"
import libwebp "../vendor/libwebp"
import "../vendor/webpinfo"

@(test)
avif_alpha_thumbnail_fixture :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("test/fixture/media/thumbnail-alpha.avif", context.allocator)
	if !testing.expect(t, err == nil, "read alpha AVIF fixture") {return}
	defer delete(data)

	offset, length, alpha_offset, alpha_length, ok := media.decode(data)
	if !testing.expect(t, ok && alpha_length != 0, "extract color and alpha items") {
		return
	}
	img, decode_err := media.decode_yuv_dav1d(data[offset:offset + length])
	if !testing.expect(t, decode_err == .None, "decode color") {return}
	defer media.free_decoded_dav1d(&img)

	alpha, alpha_err := media.decode_yuv_dav1d(
		data[alpha_offset:alpha_offset + alpha_length],
		.I400,
	)
	if !testing.expect(t, alpha_err == .None, "decode alpha") {return}
	defer media.free_decoded_dav1d(&alpha)

	root, temp_err := os.make_directory_temp("", "booru-avif-alpha-*", context.allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)

	edges := [?]c.int{64, 128}
	for edge in edges {
		if !testing.expect(
			t,
			encode_thumbnail_yuv(root, "alpha", edge, img, &alpha),
			"encode alpha thumbnail",
		) {continue}

		path := fmt.tprintf("%s/thumbnails/%d/alpha.webp", root, edge)
		output, read_err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, read_err == nil, "read thumbnail") {continue}
		defer delete(output)

		has_alpha: c.int
		status := webpinfo.inspect(raw_data(output), len(output), &has_alpha)
		testing.expect(t, status == .OK, "valid WebP")
		testing.expect(t, has_alpha != 0, "thumbnail preserves alpha")
	}
}

@(test)
avif_thumbnail_fixture :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("test/fixture/media/thumbnail.avif", context.allocator)
	if !testing.expect(t, err == nil, "read AVIF fixture") {return}
	defer delete(data)
	offset, length, _, _, ok := media.decode(data)
	if !testing.expect(t, ok, "extract primary AV1 item") {return}
	img, decode_err := media.decode_yuv_dav1d(data[offset:offset + length])
	if !testing.expect(t, decode_err == .None, "decode AVIF fixture") {return}
	defer media.free_decoded_dav1d(&img)

	root, temp_err := os.make_directory_temp("", "booru-avif-*", context.allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	edges := [?]c.int{64, 128}
	for edge in edges {
		path := fmt.tprintf("%s/%d.webp", root, edge)
		file, open_err := os.create(path)
		if !testing.expect(t, open_err == nil) {continue}
		pic := libwebp.WebPPicture {
			width     = img.width,
			height    = img.height,
			y         = img.y,
			u         = img.u,
			v         = img.v,
			y_stride  = c.int(img.y_stride),
			uv_stride = c.int(img.uv_stride),
		}
		encoded := libwebp.rescale(&pic, file, edge)
		libwebp.WebPPictureFree(&pic)
		os.close(file)
		if !testing.expect(t, encoded, "encode thumbnail") {continue}
		output, read_err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, read_err == nil) {continue}
		defer delete(output)
		w, h: c.int
		pixels := libwebp.WebPDecodeRGBA(raw_data(output), c.size_t(len(output)), &w, &h)
		testing.expect(
			t,
			pixels != nil && max(w, h) == edge,
			"valid WebP with requested longest edge",
		)
		if pixels != nil {libwebp.WebPFree(pixels)}
	}
}
