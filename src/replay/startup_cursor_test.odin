package replay

import elog "../event_log"
import "../library"
import "../store"
import "../vendor/sqlite"
import "core:fmt"
import "core:os"
import "core:testing"

@(test)
full_replay_initializes_append_cursor :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-startup-cursor-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	first := "{\"op\":\"add\",\"id\":1}\n"
	last := "{\"op\":\"add\",\"id\":2}\n"
	if !testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/events/2026-01.ndjson", root),
			transmute([]u8)first,
		) ==
		nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/events/2026-02.ndjson", root),
			fmt.tprintf("%spartial", last),
		) ==
		nil,
	) {return}
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
	initiate_replay(&s)
	testing.expect(t, string(cursor.shard[:]) == "2026-02.ndjson")
	testing.expect_value(t, cursor.offset, i64(len(last)))
	saved, rc := elog.load_cursor(&log, "2026-02.ndjson")
	testing.expect(t, rc == sqlite.OK && saved == cursor)
}

@(test)
full_replay_empty_log_clears_append_cursor :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-empty-cursor-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	copy(cursor.shard[:], "2026-01.ndjson")
	cursor.offset = 10
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
	initiate_replay(&s)
	testing.expect(t, cursor == (elog.Cursor{}))
}
