package replay

import elog "../event_log"
import "../library"
import "../store"
import "../vendor/sqlite"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
ordered_shards_survivors_and_live_agreement :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	events := fmt.tprintf("%s/events", root)
	if !testing.expect(t, os.mkdir_all(events, os.Permissions_Default_Directory) == nil) {return}
	first := `{"op":"add","id":1,"name":"before","width":42,"comment":"retained","tags_xor":["alpha","beta"]}
{"op":"add","id":900001,"tags_xor":["ghost"]}
`
	middle := `{"op":"patch","id":1,"name":"middle","tags_xor":["alpha","gamma"]}
`
	last := `{"op":"patch","id":1,"name":"final","tags_xor":["beta","\u0064og"]}
{"op":"delete","id":900001}
`
	// Deliberately create files out of lexical order.
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/20.ndjson", events), transmute([]u8)last) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/00.ndjson", events), transmute([]u8)first) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/10.ndjson", events), transmute([]u8)middle) == nil,
	)
	rebuilt := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&rebuilt, ":memory:") == sqlite.OK) {return}
	defer store.Close(&rebuilt)
	initiate_replay(&rebuilt)
	testing.expect(t, library.requestNewId() > 900001)

	live: library.State
	if !testing.expect(t, store.Init(&live, ":memory:") == sqlite.OK) {return}
	defer store.Close(&live)
	rc := sqlite.with_transaction(live.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
		rc := store.insert_into_items(
			tx,
			library.Image{id = id, name = "before", width = 42, comment = "retained"},
		)
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"alpha", "beta"})
		if rc != sqlite.OK {return rc}
		rc = store.insert_into_items(tx, library.Image{id = 900001})
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, 900001, {"ghost"})
		if rc != sqlite.OK {return rc}
		rc = store.patch_item(tx, library.Image{id = id, name = "middle"})
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"alpha", "gamma"})
		if rc != sqlite.OK {return rc}
		rc = store.patch_item(tx, library.Image{id = id, name = "final"})
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"beta", "dog"})
		if rc != sqlite.OK {return rc}
		return store.delete_item(tx, 900001)
	})
	testing.expect(t, rc == sqlite.OK)
	actual, read_rc := store.read_images(rebuilt.data_store, alloc)
	expected, live_rc := store.read_images(live.data_store, alloc)
	if testing.expect(
		t,
		read_rc == sqlite.OK && live_rc == sqlite.OK && len(actual) == 1 && len(expected) == 1,
	) {
		testing.expect_value(t, actual[0].id, expected[0].id)
		testing.expect_value(t, actual[0].name, "final")
		testing.expect_value(t, actual[0].name, expected[0].name)
		testing.expect_value(t, actual[0].width, expected[0].width)
		testing.expect_value(t, actual[0].comment, expected[0].comment)
		testing.expect(t, slice.equal(actual[0].tags, expected[0].tags))
		testing.expect(t, slice.equal(actual[0].tags, []string{"dog", "gamma"}))
	}
	// Existing public entry point remains a complete single-input replay.
	single: library.State
	if !testing.expect(t, store.Init(&single, ":memory:") == sqlite.OK) {return}
	defer store.Close(&single)
	text := strings.concatenate({first, middle, last}, alloc)
	// Heap allocator exercises cleanup of decoded strings and compacted rows.
	testing.expect(t, replay(&single, &text, context.allocator) == nil)
	one, one_rc := store.read_images(single.data_store, alloc)
	if testing.expect(t, one_rc == sqlite.OK && len(one) == 1) {
		testing.expect_value(t, one[0].name, "final")
		testing.expect(t, slice.equal(one[0].tags, []string{"dog", "gamma"}))
	}
}

@(test)
reject_bad_events_and_creation_reuse_atomically :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	bad := []string {
		`{"op":"unknown","id":1}`,
		`{"id":1}`,
		`{"op":123,"id":1}`,
		`{"op":"patch","id":"1"}`,
		`{"op":"patch","id":0}`,
		`{"op":"patch","id":2,"tags_xor":["cat"]}
{"op":"add","id":2}`,
		`{"op":"delete","id":1}
{"op":"patch","id":1,"tags_xor":["cat"]}`,
		`{"op":"delete","id":2}`,
		`{"op":"patch","id":1,"width":true}`,
		`{"op":"patch","id":1,"mtime":"now"}`,
		`{"op":"patch","id":1,"name":[]}`,
		`{"op":"patch","id":1,"tags":[]}`,
		`{"op":"patch","id":1,"tags_xor":"cat"}`,
		`{"op":"patch","id":1,"tags_xor":[false]}`,
		`{"op":"patch","id":1,"tags_xor":[""]}`,
		`{"op":"patch","id":1,"tags_xor":["Cat"]}`,
		`{"op":"patch","id":1,"tags_xor":["cat","\u0063at"]}`,
		`{"op":"delete","id":1,"tags_xor":["cat"]}`,
		`{"op":"regen_thumbnail","id":1,"tags_xor":["cat"]}`,
		`{"op":"add","id":1}`,
		`{"op":"patch","id":1,"color":"red"}`,
		`{"op":"delete","id":1,"name":"x"}`,
		`{"op":"regen_thumbnail","id":1,"width":5}`,
		`{"op":"regen_thumbnail","id":2}`,
		`{"op":"delete","id":1}
{"op":"regen_thumbnail","id":1}`,
		`{"op":"delete","id":1}
{"op":"add","id":1}`,
	}
	for event in bad {
		s: library.State
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		text := strings.concatenate(
			{"{\"op\":\"add\",\"id\":1,\"tags_xor\":[\"cat\"]}\n", event, "\n"},
			alloc,
		)
		testing.expect_value(t, replay(&s, &text, context.allocator), Error.BadEvent)
		images, rc := store.read_images(s.data_store, alloc)
		testing.expect(t, rc == sqlite.OK && len(images) == 0)
		testing.expect(t, sqlite.get_autocommit(s.data_store) != 0)
		store.Close(&s)
	}
}

@(test)
explicit_empty_scalars_are_not_implemented :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	cleared := []string{`{"op":"patch","id":1,"comment":""}`, `{"op":"patch","id":1,"name":""}`}
	for event in cleared {
		s: library.State
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		text := strings.concatenate({"{\"op\":\"add\",\"id\":1}\n", event, "\n"}, alloc)
		testing.expect_value(t, replay(&s, &text, context.allocator), Error.NotImplemented)
		store.Close(&s)
	}
}

@(test)
shard_failure_and_cross_shard_reuse_roll_back :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-replay-failure-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	first := fmt.tprintf("%s/00.ndjson", root)
	last := fmt.tprintf("%s/10.ndjson", root)
	text := `{"op":"add","id":7,"tags_xor":["cat"]}
{"op":"delete","id":7}
`
	testing.expect(t, os.write_entire_file(first, transmute([]u8)text) == nil)
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	paths := []string{first, last}
	testing.expect_value(t, replay_inputs(&s, nil, paths, context.allocator, nil), Error.Corrupted)
	images, rc := store.read_images(s.data_store, alloc)
	testing.expect(t, rc == sqlite.OK && len(images) == 0)
	text = `{"op":"add","id":7,"tags_xor":["dog"]}`
	testing.expect(t, os.write_entire_file(last, transmute([]u8)text) == nil)
	testing.expect_value(t, replay_inputs(&s, nil, paths, context.allocator, nil), Error.BadEvent)
	images, rc = store.read_images(s.data_store, alloc)
	testing.expect(t, rc == sqlite.OK && len(images) == 0)
}

@(test)
identical_tags_on_distinct_items_are_independent :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	text := `{"op":"add","id":1,"tags_xor":["cat"]}
{"op":"add","id":2,"tags_xor":["cat"]}
{"op":"patch","id":1,"tags_xor":["cat"]}
`
	if !testing.expect(t, replay(&s, &text, context.allocator) == nil) {return}
	images, rc := store.read_images(s.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 2) {
		testing.expect(t, len(images[0].tags) == 0)
		testing.expect(t, slice.equal(images[1].tags, []string{"cat"}))
	}
}

@(test)
parsed_tags_own_strings_and_duplicate_patch_delivery_cancels :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	source := `{"op":"patch","id":1,"tags_xor":["cat","\u0064og"]}`
	buffer := slice.clone(transmute([]u8)source, alloc)
	record := elog.Record {
		fields = make([dynamic]elog.Field, 0, 16, alloc),
	}
	item, op, tags, err := parse_item(string(buffer), &record, alloc)
	for &b in buffer {b = 'x'}
	testing.expect(t, err == nil && item.id == 1 && op == "patch")
	testing.expect_value(t, len(item.tags), 0)
	testing.expect(t, slice.equal(tags, []string{"cat", "dog"}))
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	text := `{"op":"add","id":1,"tags_xor":["cat"]}
{"op":"patch","id":1,"tags_xor":["cat","dog"]}
{"op":"patch","id":1,"tags_xor":["cat","dog"]}
{"op":"regen_thumbnail","id":1,"width":0,"mtime":0}
`
	testing.expect(t, replay(&s, &text, context.allocator) == nil)
	images, rc := store.read_images(s.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 1) {
		testing.expect(t, slice.equal(images[0].tags, []string{"cat"}))
	}
}
