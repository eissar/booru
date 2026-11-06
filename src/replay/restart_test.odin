package replay

import elog "../event_log"
import "../library"
import "../store"
import "../vendor/sqlite"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
persistent_restart_catchup :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-restart-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	shard := elog.get_current_event_shard(alloc)
	path := fmt.tprintf("%s/events/%s", root, shard)
	first := "{\"op\":\"add\",\"id\":1,\"name\":\"before\",\"tags\":[\"cat\"]}\n"
	pending := "{\"op\":\"patch\",\"id\":1,\"name\":\"0303120a0065\",\"tags\":[\"cat\",\"dog\"]}\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)first) == nil) {return}
	db_path := strings.clone_to_cstring(fmt.tprintf("%s/store.sqlite", root), alloc)
	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, db_path) == sqlite.OK) {return}
	initiate_replay(&s)
	// A deleted ID still belongs to the allocation high-water mark. Reserve a
	// value above the process allocator so a no-op replay must seed from SQLite.
	high := library.requestNewId() + 100
	if !testing.expect(
		t,
		sqlite.run(
			s.data_store,
			strings.clone_to_cstring(
				fmt.tprintf("UPDATE sqlite_sequence SET seq = %d WHERE name = 'items'", high),
				alloc,
			),
		),
	) {return}
	store.Close(&s)

	for restart in 0 ..< 3 {
		if restart == 1 {
			if !testing.expect(
				t,
				os.write_entire_file(path, transmute([]u8)fmt.tprintf("%s%s", first, pending)) ==
				nil,
			) {return}
		}
		if !testing.expect(t, store.Init(&s, db_path) == sqlite.OK) {return}
		copy(cursor.shard[:], shard)
		info, stat_err := os.stat(path, alloc)
		if !testing.expect(t, stat_err == nil) {store.Close(&s); return}
		cursor.offset = info.size
		initiate_replay(&s, full_replay = false)
		image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
		testing.expect(t, rc == sqlite.OK && found)
		testing.expect(t, len(image.tags) == 1)
		if len(image.tags) == 1 {
			testing.expect(t, image.tags[0] == ("cat" if restart == 0 else "dog"))
		}
		testing.expect(t, image.name == ("before" if restart == 0 else "after"))
		saved, cursor_rc := elog.load_cursor(&log, shard)
		testing.expect(t, cursor_rc == sqlite.OK && saved == cursor)
		testing.expect(t, library.requestNewId() > high)
		store.Close(&s)
	}
}
