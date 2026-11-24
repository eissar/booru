package replay

import elog "../event_log"
import "../library"
import pijul "../slop_pijul"
import "../store"
import "../vendor/sqlite"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
full_then_incremental_replay_persists_progress :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-incremental-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	if !testing.expect(
		t,
		elog.ev_append(
			&log,
			[]elog.Event{{op = "add", id = 1, name = "before", tags = {"cat"}}},
		) ==
		"",
	) {return}
	initiate_replay(&s)
	saved, rc := elog.load_cursor(s.data_store, string(cursor.shard[:]))
	testing.expect(t, rc == sqlite.OK && saved == cursor)

	if !testing.expect(
		t,
		elog.ev_append(
			&log,
			[]elog.Event{{op = "patch", id = 1, name = "0303120a0065", tags = {"cat", "dog"}}},
		) ==
		"",
	) {return}
	for _ in 0 ..< 2 {
		initiate_replay(&s, full_replay = false)
		image, found, read_rc := store.read_image_by_id(s.data_store, 1, alloc)
		if !testing.expect(t, read_rc == sqlite.OK && found) {return}
		testing.expect_value(t, image.name, "after")
		testing.expect(t, slice.equal(image.tags, []string{"dog"}))
		saved, rc = elog.load_cursor(s.data_store, string(cursor.shard[:]))
		testing.expect(t, rc == sqlite.OK && saved == cursor)
	}
}

@(test)
incremental_application_and_cursor_roll_back_together :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-incremental-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	cursor: elog.Cursor
	copy(cursor.shard[:], "2026-01.ndjson")
	first := "{\"op\":\"add\",\"id\":1,\"name\":\"before\",\"tags\":[\"cat\"]}\n"
	cursor.offset = i64(len(first))
	tx := sqlite.Tx {
		db = s.data_store,
	}
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	defer {if sqlite.get_autocommit(s.data_store) == 0 {sqlite.run(s.data_store, "ROLLBACK")}}
	if !testing.expect(t, replay(&s, {first}, context.allocator) == nil) {return}
	if !testing.expect(t, elog.save_cursor(&tx, &cursor) == sqlite.OK) {return}
	if !testing.expect(t, sqlite.run(s.data_store, "COMMIT")) {return}

	patch := "{\"op\":\"patch\",\"id\":1,\"name\":\"0303120a0065\",\"tags\":[\"cat\",\"dog\"]}\n"
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	if !testing.expect(
		t,
		replay(&s, {patch}, context.allocator, full_replay = false) == nil,
	) {return}
	next := cursor
	next.offset += i64(len(patch))
	if !testing.expect(t, elog.save_cursor(&tx, &next) == sqlite.OK) {return}
	// A duplicate add fails after both application and cursor advancement.
	testing.expect_value(
		t,
		replay(&s, {first}, context.allocator, full_replay = false),
		Error.BadEvent,
	)
	if !testing.expect(t, sqlite.run(s.data_store, "ROLLBACK")) {return}
	image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
	if !testing.expect(t, rc == sqlite.OK && found) {return}
	testing.expect_value(t, image.name, "before")
	testing.expect(t, slice.equal(image.tags, []string{"cat"}))
	saved, cursor_rc := elog.load_cursor(s.data_store, string(cursor.shard[:]))
	testing.expect(t, cursor_rc == sqlite.OK && saved == cursor)
}

@(test)
incremental_patch_on_deleted_or_unknown_item_is_bad_event :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-incremental-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	seed := "{\"op\":\"add\",\"id\":1,\"tags\":[\"cat\"]}\n{\"op\":\"delete\",\"id\":1}\n"
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	if !testing.expect(t, replay(&s, {seed}, context.allocator) == nil) {return}
	if !testing.expect(t, sqlite.run(s.data_store, "COMMIT")) {return}
	events := [?]string {
		"{\"op\":\"patch\",\"id\":1,\"tags\":[\"dog\"]}\n",
		"{\"op\":\"patch\",\"id\":1,\"name\":\"0a0b\"}\n",
		"{\"op\":\"patch\",\"id\":2,\"tags\":[\"dog\"]}\n",
		"{\"op\":\"patch\",\"id\":2,\"name\":\"0a0b\"}\n",
		"{\"op\":\"add\",\"id\":2}\n{\"op\":\"delete\",\"id\":2}\n{\"op\":\"patch\",\"id\":2,\"tags\":[\"dog\"]}\n",
	}
	for event in events {
		if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
		testing.expect_value(
			t,
			replay(&s, {event}, context.allocator, full_replay = false),
			Error.BadEvent,
		)
		sqlite.run(s.data_store, "ROLLBACK")
	}
}

@(test)
incremental_patch_on_evicted_id_reads_swap :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-incremental-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	seed := "{\"op\":\"add\",\"id\":1,\"name\":\"a\"}\n{\"op\":\"add\",\"id\":2,\"name\":\"x\"}\n"
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	if !testing.expect(t, replay(&s, {seed}, context.allocator) == nil) {return}
	if !testing.expect(t, sqlite.run(s.data_store, "COMMIT")) {return}
	// a->b on 1, x->y on 2 evicts 1 to swap, then b->c on 1 must resume from swap.
	batch := "{\"op\":\"patch\",\"id\":1,\"name\":\"03\"}\n{\"op\":\"patch\",\"id\":2,\"name\":\"01\"}\n{\"op\":\"patch\",\"id\":1,\"name\":\"01\"}\n"
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	if !testing.expect(
		t,
		replay(&s, {batch}, context.allocator, full_replay = false, lru_cap = 1) == nil,
	) {return}
	if !testing.expect(t, sqlite.run(s.data_store, "COMMIT")) {return}
	expected := [?]struct {
		id:   int,
		name: string,
	}{{1, "c"}, {2, "y"}}
	for want in expected {
		image, found, rc := store.read_image_by_id(s.data_store, want.id, alloc)
		if !testing.expect(t, rc == sqlite.OK && found) {return}
		testing.expect_value(t, image.name, want.name)
	}
}

@(test)
patch_clears_name_comment_and_tags_full_and_incremental :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-incremental-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	seed_b := strings.builder_make(alloc)
	elog.write_event(
		strings.to_writer(&seed_b),
		elog.Event {
			op = "add",
			id = 1,
			name = "before",
			comment = "keep\nthis",
			tags = {"cat", "dog"},
		},
	)
	clear_b := strings.builder_make(alloc)
	elog.write_event(
		strings.to_writer(&clear_b),
		elog.Event {
			op = "patch",
			id = 1,
			name = elog.name_delta("before", "", alloc),
			comment = pijul.generate_patch("keep\nthis", "", alloc),
			tags = {"cat", "dog"},
		},
	)
	seed := strings.to_string(seed_b)
	clear := strings.to_string(clear_b)

	full := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&full, ":memory:") == sqlite.OK) {return}
	defer store.Close(&full)
	if !testing.expect(t, sqlite.run(full.data_store, "BEGIN")) {return}
	if !testing.expect(t, replay(&full, {seed, clear}, context.allocator) == nil) {return}
	if !testing.expect(t, sqlite.run(full.data_store, "COMMIT")) {return}

	incremental := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&incremental, ":memory:") == sqlite.OK) {return}
	defer store.Close(&incremental)
	if !testing.expect(t, sqlite.run(incremental.data_store, "BEGIN")) {return}
	if !testing.expect(t, replay(&incremental, {seed}, context.allocator) == nil) {return}
	if !testing.expect(t, sqlite.run(incremental.data_store, "COMMIT")) {return}
	if !testing.expect(t, sqlite.run(incremental.data_store, "BEGIN")) {return}
	if !testing.expect(
		t,
		replay(&incremental, {clear}, context.allocator, full_replay = false) == nil,
	) {return}
	if !testing.expect(t, sqlite.run(incremental.data_store, "COMMIT")) {return}

	for s in ([]^library.State{&full, &incremental}) {
		image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
		if !testing.expect(t, rc == sqlite.OK && found) {return}
		testing.expect_value(t, image.name, "")
		testing.expect_value(t, image.comment, "")
		testing.expect_value(t, len(image.tags), 0)
	}
}
