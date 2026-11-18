package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../library"
import "../media"
import "../store"
import libwebp "../vendor/libwebp"
import "../vendor/sqlite"

@(test)
video_first_frame_thumbnail_fixture :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-video-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/images", root), os.Permissions_Default_Directory) == nil,
	)

	source, read_err := os.read_entire_file("test/fixture/media/thumbnail.mp4", context.allocator)
	if !testing.expect(t, read_err == nil, "read mp4 fixture") {return}
	defer delete(source)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/images/2.mp4", root), source) == nil)

	oid := "video-oid"
	images := [?]library.Image{{id = 2, oid = oid, ext = "mp4"}}
	state := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)
	testing.expect(
		t,
		sqlite.with_transaction(
			state.data_store,
			images[0],
			proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
				return c.int(store.insert_item(tx, item))
			},
		) ==
		sqlite.OK,
	)

	// Startup scan generates both resolutions from the video's first frame.
	n, failed := generate_missing_thumbnails(state, all = true)
	testing.expect(t, n == 2 && failed == 0, "generate both resolutions for video")

	edges := [?]int{64, 128}
	for edge in edges {
		output, e := os.read_entire_file(
			fmt.tprintf("%s/thumbnails/%d/%s.webp", root, edge, oid),
			context.allocator,
		)
		if !testing.expect(t, e == nil) {continue}
		defer delete(output)
		w, h, stride, uv_stride: c.int
		u, v: ^u8
		y := libwebp.WebPDecodeYUV(
			raw_data(output),
			c.size_t(len(output)),
			&w,
			&h,
			&u,
			&v,
			&stride,
			&uv_stride,
		)
		testing.expect(
			t,
			y != nil && max(w, h) == c.int(edge),
			"valid output with requested longest edge",
		)
		if y != nil {libwebp.WebPFree(y)}
	}

	// Regeneration replaces the existing thumbnails.
	n, failed = force_generate_image_thumbnails(state, images[0], {.x64, .x128})
	testing.expect(t, n == 2 && failed == 0, "regenerate both resolutions for video")
}

@(test)
video_probe_dimensions_fixture :: proc(t: ^testing.T) {
	path := "test/fixture/media/thumbnail.mp4"
	w, h, ok := media.probe_dimensions(nil, .MP4, path)
	testing.expect(t, ok, "probe_dimensions succeeds for mp4")

	frame, err := media.decode_frame(path)
	testing.expect(t, err == .None, "decode_frame succeeds for mp4")
	defer media.free_decoded(&frame)

	yuv, is_yuv := frame.(media.Decoded_YUV)
	testing.expect(t, is_yuv, "mp4 decodes to Decoded_YUV")
	testing.expect(t, w == yuv.width && h == yuv.height, "probed dimensions match decoded frame")

	_, _, no_path_ok := media.probe_dimensions(nil, .MP4)
	testing.expect(t, !no_path_ok, "probe_dimensions without path fails for video")
}
