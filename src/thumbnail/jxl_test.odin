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
jxl_thumbnail_fixture :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-jxl-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/images", root), os.Permissions_Default_Directory) == nil,
	)

	source, read_err := os.read_entire_file("test/fixture/media/thumbnail.jxl", context.allocator)
	if !testing.expect(t, read_err == nil, "read jxl fixture") {return}
	defer delete(source)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/images/2.jxl", root), source) == nil)

	oid := "jxl-oid"
	images := [?]library.Image{{id = 2, oid = oid, ext = "jxl"}}
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

	n, failed := generate_missing_thumbnails(state)
	testing.expect(t, n == 2 && failed == 0, "generate both resolutions for jxl")

	edges := [?]int{64, 128}
	for edge in edges {
		output, e := os.read_entire_file(
			fmt.tprintf("%s/thumbnails/%d/%s.webp", root, edge, oid),
			context.allocator,
		)
		if !testing.expect(t, e == nil) {continue}
		defer delete(output)
		w, h: c.int
		ok := libwebp.WebPGetInfo(raw_data(output), c.size_t(len(output)), &w, &h) != 0
		testing.expect(
			t,
			ok && max(w, h) == c.int(edge),
			"valid WebP output with requested longest edge",
		)
	}

	n, failed = force_generate_image_thumbnails(state, images[0], {.x64, .x128})
	testing.expect(t, n == 2 && failed == 0, "regenerate both resolutions for jxl")
}
