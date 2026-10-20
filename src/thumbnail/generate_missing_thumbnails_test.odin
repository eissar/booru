package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../library"
import "../store"
import libwebp "../vendor/libwebp"
import "../vendor/sqlite"

FIXTURE_LIBRARY :: "test/fixture/library"

@(test)
generate_missing_fixture_thumbnails :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-thumbnails-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	oid := "0aed5445db349824f16987bba714e513211cd8d0ae827f9459b157b763adfdb5"
	data, read_err := os.read_entire_file(
		fmt.tprintf("%s/thumbnails/%s.webp", FIXTURE_LIBRARY, oid),
		context.allocator,
	)
	if !testing.expect(t, read_err == nil) {return}
	defer delete(data)
	testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/images", root), os.Permissions_Default_Directory) == nil,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/images/2.webp", root), data) == nil)
	images := [?]library.Image{{id = 2, oid = oid}}
	state := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)
	testing.expect(t, store.insert_into_items(state.data_store, images[0]) == sqlite.OK)
	n, failed := generate_missing_thumbnails(state)
	testing.expect(t, n == 2 && failed == 0, "generate both resolutions")
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
	// Removing the source makes any accidental attempt to regenerate fail.
	os.remove(fmt.tprintf("%s/images/2.webp", root))
	n, failed = generate_missing_thumbnails(state)
	testing.expect(t, n == 0 && failed == 0, "existing thumbnails are skipped")
	os.remove(fmt.tprintf("%s/thumbnails/64/%s.webp", root, oid))
	n, failed = generate_missing_thumbnails(state)
	testing.expect(t, n == 0 && failed == 1, "missing source is reported without aborting")
}
