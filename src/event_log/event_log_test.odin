package event_log

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
cursor_outlives_request_arena :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-cursor-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/events", root), os.Permissions_Default_Directory) == nil,
	) {return}
	cursor: Cursor
	defer delete(cursor.shard)
	log := EventLog {
		root      = root,
		cursor    = &cursor,
		allocator = context.allocator,
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	expected := get_current_event_shard(context.temp_allocator)
	for id in 1 ..= 2 {
		{
			context.allocator = mem.dynamic_arena_allocator(&arena)
			if !testing.expect(t, ev_append(&log, []Event{{id = id, op = "add"}}) == "") {return}
		}
		mem.dynamic_arena_free_all(&arena)
		testing.expect(t, cursor.shard == expected)
	}
}
