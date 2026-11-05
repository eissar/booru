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
	first := `{"op":"add","id":1,"oid":"oid","path":"path","ext":"png","name":"before","content_type":"image/png","width":42,"height":43,"mtime":44,"added_at":45,"comment":"retained","tags_xor":["alpha","beta"]}
{"op":"add","id":2}
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
		os.write_entire_file(fmt.tprintf("%s/2026-03.ndjson", events), transmute([]u8)last) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2026-01.ndjson", events), transmute([]u8)first) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2026-02.ndjson", events), transmute([]u8)middle) ==
		nil,
	)
	rebuilt := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&rebuilt, ":memory:") == sqlite.OK) {return}
	defer store.Close(&rebuilt)
	initiate_replay(&rebuilt)
	log := elog.EventLog {
		db = rebuilt.data_store,
	}
	lengths := [3]int{len(first), len(middle), len(last)}
	shards := [3]string{"2026-01.ndjson", "2026-02.ndjson", "2026-03.ndjson"}
	for shard, i in shards {
		cursor, rc := elog.load_cursor(&log, shard)
		testing.expect(t, rc == sqlite.OK)
		testing.expect_value(t, cursor.offset, i64(lengths[i]))
	}
	testing.expect(t, library.requestNewId() > 900001)

	live: library.State
	if !testing.expect(t, store.Init(&live, ":memory:") == sqlite.OK) {return}
	defer store.Close(&live)
	rc := sqlite.with_transaction(live.data_store, 1, proc(tx: ^sqlite.Tx, id: int) -> c.int {
		rc := c.int(
			store.insert_item(
				tx,
				library.Image {
					id = id,
					oid = "oid",
					path = "path",
					ext = "png",
					name = "before",
					content_type = "image/png",
					width = 42,
					height = 43,
					mtime = 44,
					added_at = 45,
					comment = "retained",
				},
			),
		)
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"alpha", "beta"})
		if rc != sqlite.OK {return rc}
		rc = c.int(store.insert_item(tx, library.Image{id = 2}))
		if rc != sqlite.OK {return rc}
		rc = c.int(store.insert_item(tx, library.Image{id = 900001}))
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, 900001, {"ghost"})
		if rc != sqlite.OK {return rc}
		rc = c.int(store.patch_item(tx, library.Image{id = id, name = "middle"}))
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"alpha", "gamma"})
		if rc != sqlite.OK {return rc}
		rc = c.int(store.patch_item(tx, library.Image{id = id, name = "final"}))
		if rc != sqlite.OK {return rc}
		rc = store.toggle_tags(tx, id, {"beta", "dog"})
		if rc != sqlite.OK {return rc}
		return c.int(store.delete_item(tx, 900001))
	})
	testing.expect(t, rc == sqlite.OK)
	actual, read_rc := store.read_images(rebuilt.data_store, alloc)
	expected, live_rc := store.read_images(live.data_store, alloc)
	if testing.expect(
		t,
		read_rc == sqlite.OK && live_rc == sqlite.OK && len(actual) == 2 && len(expected) == 2,
	) {
		testing.expect_value(t, actual[0].id, expected[0].id)
		testing.expect_value(t, actual[0].name, "final")
		testing.expect_value(t, actual[0].name, expected[0].name)
		testing.expect_value(t, actual[0].width, expected[0].width)
		testing.expect_value(t, actual[0].comment, expected[0].comment)
		testing.expect(t, slice.equal(actual[0].tags, expected[0].tags))
		testing.expect(t, slice.equal(actual[0].tags, []string{"dog", "gamma"}))
	}
	// An omitted field after a populated insert must not inherit a prior binding.
	blank, found, blank_rc := store.read_image_by_id(rebuilt.data_store, 2, alloc)
	if testing.expect(t, blank_rc == sqlite.OK && found) {
		testing.expect(t, blank.oid == "" && blank.path == "" && blank.ext == "")
		testing.expect(t, blank.name == "" && blank.comment == "" && blank.content_type == "")
		testing.expect(
			t,
			blank.width == 0 && blank.height == 0 && blank.mtime == 0 && blank.added_at == 0,
		)
	}
	// Existing public entry point remains a complete single-input replay.
	single: library.State
	if !testing.expect(t, store.Init(&single, ":memory:") == sqlite.OK) {return}
	defer store.Close(&single)
	text := strings.concatenate({first, middle, last}, alloc)
	// Heap allocator exercises cleanup of decoded strings and compacted rows.
	if !testing.expect(t, sqlite.run(single.data_store, "BEGIN")) {return}
	testing.expect(t, replay(&single, {text}, context.allocator) == nil)
	testing.expect(t, sqlite.run(single.data_store, "COMMIT"))
	one, one_rc := store.read_images(single.data_store, alloc)
	if testing.expect(t, one_rc == sqlite.OK && len(one) == 2) {
		testing.expect_value(t, one[0].name, "final")
		testing.expect(t, slice.equal(one[0].tags, []string{"dog", "gamma"}))
	}
	store.Close(&single)
	testing.expect(t, single.data_store == nil)
}

@(test)
creation_reuse_and_invalid_lifecycle_roll_back :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	bad := []string {
		`{"op":"patch","id":2,"tags_xor":["cat"]}
{"op":"add","id":2}`,
		`{"op":"delete","id":1}
{"op":"patch","id":1,"tags_xor":["cat"]}`,
		`{"op":"delete","id":2}`,
		`{"op":"add","id":1}`,
		`{"op":"patch","id":1,"color":"red"}`,
		`{"op":"delete","id":1,"name":"x"}`,
		`{"op":"regen_thumbnail","id":1}`,
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
		if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
		testing.expect_value(t, replay(&s, {text}, context.allocator), Error.BadEvent)
		testing.expect(t, sqlite.run(s.data_store, "ROLLBACK"))
		images, rc := store.read_images(s.data_store, alloc)
		testing.expect(t, rc == sqlite.OK && len(images) == 0)
		testing.expect(t, sqlite.get_autocommit(s.data_store) != 0)
		store.Close(&s)
		testing.expect(t, s.data_store == nil)
	}
}

@(test)
validate_event_versions :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	cases := []struct {
		text:     string,
		expected: Error,
	} {
		{`{"op":"add","id":1,"version":0}`, .None},
		{`{"op":"add","id":1,"version":1}`, .UnsupportedVersion},
		{`{"op":"add","id":1,"version":-1}`, .BadEvent},
		{`{"op":"add","id":1,"version":"0"}`, .BadEvent},
		{`{"op":"add","id":1,"version":[]}`, .BadEvent},
		{`{"op":"unknown","id":1}`, .BadEvent},
		{`{"op":"add","id":1,"unknown":0}`, .BadEvent},
	}
	for test in cases {
		s: library.State
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
		result := replay(&s, {test.text}, context.allocator)
		testing.expect_value(t, result, test.expected)
		testing.expect(t, sqlite.run(s.data_store, result == nil ? "COMMIT" : "ROLLBACK"))
		images, rc := store.read_images(s.data_store, alloc)
		testing.expect(t, rc == sqlite.OK)
		testing.expect_value(t, len(images), test.expected == .None ? 1 : 0)
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
		if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
		testing.expect_value(t, replay(&s, {text}, context.allocator), Error.NotImplemented)
		testing.expect(t, sqlite.run(s.data_store, "ROLLBACK"))
		store.Close(&s)
	}
}

@(test)
cross_shard_reuse_rolls_back :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	first := `{"op":"add","id":7,"tags_xor":["cat"]}
{"op":"delete","id":7}
`
	last := `{"op":"add","id":7,"tags_xor":["dog"]}`
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	testing.expect_value(t, replay(&s, {first, last}, context.allocator), Error.BadEvent)
	testing.expect(t, sqlite.run(s.data_store, "ROLLBACK"))
	images, rc := store.read_images(s.data_store, alloc)
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
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	if !testing.expect(t, replay(&s, {text}, context.allocator) == nil) {return}
	testing.expect(t, sqlite.run(s.data_store, "COMMIT"))
	images, rc := store.read_images(s.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 2) {
		testing.expect(t, len(images[0].tags) == 0)
		testing.expect(t, slice.equal(images[1].tags, []string{"cat"}))
	}
}

@(test)
duplicate_patch_delivery_cancels :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	source := `{"op":"patch","id":1,"tags_xor":["cat","\u0064og"]}`
	record := elog.Record {
		fields = make([dynamic]elog.Field, 0, 16, alloc),
	}
	item, op, tags, err := parse_item(source, &record, alloc)
	testing.expect(t, err == nil)
	testing.expect(t, item.id == 1 && op == "patch")
	testing.expect_value(t, len(item.tags), 0)
	testing.expect(t, slice.equal(tags, []string{"cat", "dog"}))
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	text := `{"op":"add","id":1,"tags_xor":["cat"]}
{"op":"patch","id":1,"tags_xor":["cat","dog"]}
{"op":"patch","id":1,"tags_xor":["cat","dog"]}
`
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	testing.expect(t, replay(&s, {text}, context.allocator) == nil)
	testing.expect(t, sqlite.run(s.data_store, "COMMIT"))
	images, rc := store.read_images(s.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 1) {
		testing.expect(t, slice.equal(images[0].tags, []string{"cat"}))
	}
}
