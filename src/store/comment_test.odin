package store

import "../library"
import "../vendor/sqlite"
import "core:testing"

@(test)
comment_round_trip :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	state: library.State
	if !testing.expect(t, Init(&state, ":memory:") == sqlite.OK) {return}
	defer Close(&state)
	comment := "Unicode 猫, \"quotes\", \\ and\nnewlines"
	if !testing.expect(
		t,
		insert_into_items(
			state.data_store,
			library.Image{id = 1, oid = "oid", name = "match", comment = comment},
		) ==
		sqlite.OK,
	) {return}
	images, rc := read_images(state.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 1) {
		testing.expect_value(t, images[0].comment, comment)
	}
	matches, search_rc := search_images(state.data_store, "match", alloc)
	if testing.expect(t, search_rc == sqlite.OK && len(matches) == 1) {
		testing.expect_value(t, matches[0].comment, comment)
	}
	by_oid, found, oid_rc := read_image_by_oid(state.data_store, "oid", alloc)
	if testing.expect(t, found && oid_rc == sqlite.OK) {
		testing.expect_value(t, by_oid.comment, comment)
	}
	testing.expect(
		t,
		sqlite.with_transaction(
			state.data_store,
			library.Image{id = 1, comment = "updated"},
			patch_item,
		) ==
		sqlite.OK,
	)
	testing.expect(
		t,
		sqlite.with_transaction(state.data_store, library.Image{id = 1}, patch_item) == sqlite.OK,
	)
	image, id_found, id_rc := read_image_by_id(state.data_store, 1, alloc)
	if testing.expect(t, id_found && id_rc == sqlite.OK) {
		testing.expect_value(t, image.comment, "updated")
		testing.expect_value(t, image.name, "match")
	}
}
