package store

import "../library"
import "../vendor/sqlite"
import "core:c"
import "core:testing"

@(test)
tags_are_explicit_and_toggle_in_transaction :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	s: library.State
	if !testing.expect(t, Init(&s, ":memory:") == sqlite.OK) {return}
	defer Close(&s)
	image := library.Image {
		id   = 1,
		name = "before",
		tags = {"ignored"},
	}
	testing.expect(
		t,
		sqlite.with_transaction(
			s.data_store,
			image,
			proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
				return insert_item(tx, item)
			},
		) ==
		sqlite.OK,
	)
	testing.expect(
		t,
		sqlite.with_transaction(
			s.data_store,
			image,
			proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
				return patch_item(tx, item)
			},
		) ==
		sqlite.OK,
	)
	got, found, rc := read_image_by_id(s.data_store, 1, alloc)
	testing.expect(t, found && rc == sqlite.OK && len(got.tags) == 0)
	testing.expect(t, toggle_tags(&sqlite.Tx{db = s.data_store}, 1, {"cat"}) == sqlite.MISUSE)
	testing.expect(
		t,
		sqlite.with_transaction(s.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
				return toggle_tags(tx, id, {"cat", "猫", "twice", "twice"})
			}) == sqlite.OK,
	)
	got, found, rc = read_image_by_id(s.data_store, 1, alloc)
	if testing.expect(t, found && rc == sqlite.OK && len(got.tags) == 2) {
		testing.expect_value(t, got.tags[0], "cat")
		testing.expect_value(t, got.tags[1], "猫")
	}
	testing.expect(
		t,
		sqlite.with_transaction(s.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
				return toggle_tags(tx, id, {"cat", "new"})
			}) == sqlite.OK,
	)
	got, found, rc = read_image_by_id(s.data_store, 1, alloc)
	if testing.expect(t, found && rc == sqlite.OK && len(got.tags) == 2) {
		testing.expect_value(t, got.tags[0], "new")
		testing.expect_value(t, got.tags[1], "猫")
	}
}

@(test)
toggle_failure_rolls_back_tags_and_metadata :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	s: library.State
	if !testing.expect(t, Init(&s, ":memory:") == sqlite.OK) {return}
	defer Close(&s)
	testing.expect(
		t,
		sqlite.with_transaction(s.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
				rc := insert_item(tx, library.Image{id = id, name = "before"})
				if rc != sqlite.OK {return rc}
				return toggle_tags(tx, id, {"keep"})
			}) == sqlite.OK,
	)
	// Fail after both deleting an existing tag and inserting a new one.
	testing.expect(
		t,
		sqlite.run(
			s.data_store,
			`CREATE TRIGGER reject_bad_tag BEFORE INSERT ON item_tags WHEN NEW.tag = 'bad' BEGIN SELECT RAISE(ABORT, 'bad tag'); END`,
		),
	)
	rc := sqlite.with_transaction(s.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
			rc := patch_item(tx, library.Image{id = id, name = "after"})
			if rc != sqlite.OK {return rc}
			return toggle_tags(tx, id, {"keep", "new", "bad"})
		})
	testing.expect(t, rc != sqlite.OK)
	got, found, read_rc := read_image_by_id(s.data_store, 1, alloc)
	if testing.expect(t, found && read_rc == sqlite.OK && len(got.tags) == 1) {
		testing.expect_value(t, got.name, "before")
		testing.expect_value(t, got.tags[0], "keep")
	}
	// A tag failure must also roll back creation in the same transaction.
	rc = sqlite.with_transaction(s.data_store, 2, proc(tx: ^sqlite.Tx, id: int) -> c.int {
		rc := insert_item(tx, library.Image{id = id})
		if rc != sqlite.OK {return rc}
		return toggle_tags(tx, id, {"good", "bad"})
	})
	testing.expect(t, rc != sqlite.OK)
	_, found, read_rc = read_image_by_id(s.data_store, 2, alloc)
	testing.expect(t, !found && read_rc == sqlite.OK)
	testing.expect(t, sqlite.get_autocommit(s.data_store) != 0)
}
