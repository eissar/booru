package store

import "../library"
import "../vendor/sqlite"
import "core:c"
import "core:testing"

@(test)
search_images_filters_sorts_and_pages :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	state: library.State
	if !testing.expect(t, Init(&state, ":memory:") == sqlite.OK) {return}
	defer Close(&state)
	images := [?]library.Image {
		{id = 1, oid = "o", name = "alpha", added_at = 50, tags = {"cat", "hot"}},
		{id = 2, oid = "o", name = "alpha", added_at = 100, tags = {"cat", "hot"}},
		{id = 3, oid = "o", name = "alpha", added_at = 100},
		{id = 4, oid = "o", name = "beta", added_at = 100, tags = {"cat", "hot"}},
		{id = 5, oid = "o", name = "alpha", added_at = 100, tags = {"cat", "hot"}},
		{id = 6, oid = "o", name = "alpha", added_at = 100, tags = {"hot"}},
	}
	for image in images {
		if !testing.expect(
			t,
			sqlite.with_transaction(
				state.data_store,
				image,
				proc(tx: ^sqlite.Tx, image: library.Image) -> c.int {
					rc := c.int(insert_item(tx, image))
					if rc != sqlite.OK {return rc}
					return toggle_tags(tx, image.id, image.tags)
				},
			) ==
			sqlite.OK,
		) {return}
	}
	tags := []string{"cat", "hot"}

	page, has_more, rc := search_images(
		state.data_store,
		"alpha",
		tags,
		"addedAtDesc",
		0,
		2,
		alloc,
	)
	if testing.expect(t, rc == sqlite.OK && len(page) == 2) {
		testing.expect(t, has_more)
		testing.expect_value(t, page[0].id, 5)
		testing.expect_value(t, page[1].id, 2)
	}

	page, has_more, rc = search_images(state.data_store, "alpha", tags, "addedAtDesc", 2, 2, alloc)
	if testing.expect(t, rc == sqlite.OK && len(page) == 1) {
		testing.expect(t, !has_more)
		testing.expect_value(t, page[0].id, 1)
	}

	// Test until_id ceiling constraint
	max_id, max_rc := read_max_item_id(state.data_store)
	testing.expect_value(t, max_rc, sqlite.OK)
	testing.expect_value(t, max_id, 6)

	// Ceiling at 4 excludes items 5 and 6
	page_until, _, rc_until := search_images(
		state.data_store,
		"alpha",
		tags,
		"addedAtDesc",
		0,
		10,
		alloc,
		until_id = 4,
	)
	if testing.expect(t, rc_until == sqlite.OK) {
		testing.expect_value(t, len(page_until), 2)
		testing.expect_value(t, page_until[0].id, 2)
		testing.expect_value(t, page_until[1].id, 1)
	}
}
