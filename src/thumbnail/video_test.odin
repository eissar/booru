package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../library"
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
	testing.expect(t, store.insert_into_items(state.data_store, images[0]) == sqlite.OK)

	// Startup scan generates both resolutions from the video's first frame.
	n, failed := generate_missing_thumbnails(state)
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
