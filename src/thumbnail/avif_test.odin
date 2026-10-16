package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../media"
import libwebp "../vendor/libwebp"

@(test)
avif_thumbnail_fixture :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("test/fixture/media/thumbnail.avif", context.allocator)
	if !testing.expect(t, err == nil, "read AVIF fixture") {return}
	defer delete(data)
	offset, length, ok := media.Parse_AVIF(data)
	if !testing.expect(t, ok, "extract primary AV1 item") {return}
	img := media.decode_yuv_dav1d(data[offset:offset + length])
	if !testing.expect(t, img.y != nil, "decode AVIF fixture") {return}
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
