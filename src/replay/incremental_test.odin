package replay

import elog "../event_log"
import "../library"
import "../store"
import "../vendor/sqlite"
import "core:os"
import "core:slice"
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
	saved, rc := elog.load_cursor(&log, string(cursor.shard[:]))
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
		saved, rc = elog.load_cursor(&log, string(cursor.shard[:]))
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
	log := elog.EventLog {
		db = s.data_store,
	}
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
	saved, cursor_rc := elog.load_cursor(&log, string(cursor.shard[:]))
	testing.expect(t, cursor_rc == sqlite.OK && saved == cursor)
}
