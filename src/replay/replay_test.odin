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
	first := `{"op":"add","id":1,"oid":"oid","path":"path","ext":"png","name":"before","content_type":"image/png","width":42,"height":43,"mtime":44,"added_at":45,"comment":"retained","tags":["alpha","beta"]}
{"op":"add","id":2}
{"op":"add","id":900001,"tags":["ghost"]}
`
	middle := `{"op":"patch","id":1,"name":"0f0c020b1e00","tags":["alpha","gamma"]}
`
	last := `{"op":"patch","id":1,"name":"0b000a050065","tags":["beta","\u0064og"]}
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
	lengths := [3]int{len(first), len(middle), len(last)}
	shards := [3]string{"2026-01.ndjson", "2026-02.ndjson", "2026-03.ndjson"}
	for shard, i in shards {
		cursor, rc := elog.load_cursor(rebuilt.data_store, shard)
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
		if !sqlite.run(tx.db, "UPDATE items SET name = 'middle' WHERE id = 1") {return 1}
		rc = store.toggle_tags(tx, id, {"alpha", "gamma"})
		if rc != sqlite.OK {return rc}
		if !sqlite.run(tx.db, "UPDATE items SET name = 'final' WHERE id = 1") {return 1}
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
	single := library.State {
		library_path = root,
	}
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
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	bad := []string {
		`{"op":"patch","id":2,"tags":["cat"]}
{"op":"add","id":2}`,
		`{"op":"delete","id":1}
{"op":"patch","id":1,"tags":["cat"]}`,
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
		s := library.State {
			library_path = root,
		}
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		text := strings.concatenate(
			{"{\"op\":\"add\",\"id\":1,\"tags\":[\"cat\"]}\n", event, "\n"},
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
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
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
		s := library.State {
			library_path = root,
		}
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
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	cleared := []string{`{"op":"patch","id":1,"comment":""}`}
	for event in cleared {
		s := library.State {
			library_path = root,
		}
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
	first := `{"op":"add","id":7,"tags":["cat"]}
{"op":"delete","id":7}
`
	last := `{"op":"add","id":7,"tags":["dog"]}`
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
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
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	text := `{"op":"add","id":1,"tags":["cat"]}
{"op":"add","id":2,"tags":["cat"]}
{"op":"patch","id":1,"tags":["cat"]}
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
	source := `{"op":"patch","id":1,"tags":["cat","\u0064og"]}`
	record := elog.Record {
		fields = make([dynamic]elog.Field, 0, 16, alloc),
	}
	parsed_name: [dynamic]u8
	parsed_comment: string
	item, op, tags, err := parse_item(source, &record, &parsed_name, &parsed_comment, alloc)
	testing.expect(t, err == nil)
	testing.expect(t, item.id == 1 && op == "patch")
	testing.expect_value(t, len(item.tags), 0)
	testing.expect(t, slice.equal(tags, []string{"cat", "dog"}))
	root, temp_err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, temp_err == nil) {return}
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	text := `{"op":"add","id":1,"tags":["cat"]}
{"op":"patch","id":1,"tags":["cat","dog"]}
{"op":"patch","id":1,"tags":["cat","dog"]}
`
	if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
	testing.expect(t, replay(&s, {text}, context.allocator) == nil)
	testing.expect(t, sqlite.run(s.data_store, "COMMIT"))
	images, rc := store.read_images(s.data_store, alloc)
	if testing.expect(t, rc == sqlite.OK && len(images) == 1) {
		testing.expect(t, slice.equal(images[0].tags, []string{"cat"}))
	}
}

@(test)
overwrite_applies_in_log_order_across_shards :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	events := fmt.tprintf("%s/events", root)
	if !testing.expect(t, os.mkdir_all(events, os.Permissions_Default_Directory) == nil) {return}
	first := `{"op":"add","id":1,"oid":"a","path":"p","ext":"png","content_type":"image/png","width":10,"height":20}
{"op":"overwrite","id":1,"oid":"b","width":11}
`
	middle := `{"op":"overwrite","id":1,"oid":"c","height":22}
`
	last := `{"op":"overwrite","id":1,"path":"q","width":0}
`
	// Deliberately create files out of lexical order.
	shards := [3][2]string {
		{"2026-03.ndjson", last},
		{"2026-01.ndjson", first},
		{"2026-02.ndjson", middle},
	}
	for shard in shards {
		testing.expect(
			t,
			os.write_entire_file(
				fmt.tprintf("%s/%s", events, shard[0]),
				transmute([]u8)shard[1],
			) ==
			nil,
		)
	}
	full := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&full, ":memory:") == sqlite.OK) {return}
	defer store.Close(&full)
	initiate_replay(&full)

	// Incremental replay applies overwrites through the store, not overwrite_step.
	incremental := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&incremental, ":memory:") == sqlite.OK) {return}
	defer store.Close(&incremental)
	testing.expect(t, sqlite.run(incremental.data_store, "BEGIN"))
	testing.expect(t, replay(&incremental, {first}, context.allocator) == nil)
	testing.expect(t, sqlite.run(incremental.data_store, "COMMIT"))
	for stream in ([]string{middle, last}) {
		testing.expect(t, sqlite.run(incremental.data_store, "BEGIN"))
		testing.expect(
			t,
			replay(&incremental, {stream}, context.allocator, full_replay = false) == nil,
		)
		testing.expect(t, sqlite.run(incremental.data_store, "COMMIT"))
	}

	for s in ([]^library.State{&full, &incremental}) {
		image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
		if !testing.expect(t, rc == sqlite.OK && found) {return}
		testing.expect_value(t, image.oid, "c")
		testing.expect_value(t, image.path, "q")
		testing.expect_value(t, image.ext, "png")
		testing.expect_value(t, image.content_type, "image/png")
		testing.expect_value(t, image.width, 11)
		testing.expect_value(t, image.height, 22)
	}
}

@(test)
name_finalization_trims_nul_padding :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	// Grow, shrink, clear, multibyte, then shrink within multibyte.
	names := [?]string{"ab", "abcdef", "x", "", "日本語", "é"}
	lines := make([]string, len(names), alloc)
	lines[0] = `{"op":"add","id":1,"name":"ab"}`
	for i in 1 ..< len(names) {
		lines[i] = fmt.tprintf(
			`{{"op":"patch","id":1,"name":"%s"}}`,
			elog.name_delta(names[i - 1], names[i], alloc),
		)
	}

	incremental := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&incremental, ":memory:") == sqlite.OK) {return}
	defer store.Close(&incremental)
	testing.expect(t, sqlite.run(incremental.data_store, "BEGIN"))
	testing.expect(t, replay(&incremental, {lines[0]}, context.allocator) == nil)
	testing.expect(t, sqlite.run(incremental.data_store, "COMMIT"))

	for k in 1 ..< len(names) {
		full := library.State {
			library_path = root,
		}
		if !testing.expect(t, store.Init(&full, ":memory:") == sqlite.OK) {return}
		defer store.Close(&full)
		testing.expect(t, sqlite.run(full.data_store, "BEGIN"))
		testing.expect(t, replay(&full, lines[:k + 1], context.allocator) == nil)
		testing.expect(t, sqlite.run(full.data_store, "COMMIT"))

		testing.expect(t, sqlite.run(incremental.data_store, "BEGIN"))
		testing.expect(
			t,
			replay(&incremental, {lines[k]}, context.allocator, full_replay = false) == nil,
		)
		testing.expect(t, sqlite.run(incremental.data_store, "COMMIT"))

		for s in ([]^library.State{&full, &incremental}) {
			image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
			if !testing.expect(t, rc == sqlite.OK && found) {return}
			testing.expect_value(t, image.name, names[k])
		}
	}
}

@(test)
json_null_field_is_bad_event :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-replay-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	fields := [?]struct {
		op:   string,
		keys: []string,
	} {
		{
			"add",
			{
				"oid",
				"path",
				"ext",
				"content_type",
				"name",
				"comment",
				"width",
				"height",
				"mtime",
				"added_at",
				"tags",
				"version",
			},
		},
		{"patch", {"name", "comment", "mtime", "added_at", "width", "height", "tags", "version"}},
		{
			"overwrite",
			{"oid", "path", "ext", "content_type", "width", "height", "mtime", "added_at"},
		},
		{"delete", {"mtime", "version"}},
	}
	lines := make([dynamic]string, alloc)
	append(&lines, `{"op":null,"id":1}`, `{"op":"patch","id":null}`)
	for f in fields {
		for key in f.keys {
			// add creates a fresh id; the rest act on the seeded live item.
			append(
				&lines,
				fmt.tprintf(`{{"op":"%s","id":%d,"%s":null}}`, f.op, f.op == "add" ? 2 : 1, key),
			)
		}
	}
	for line in lines {
		s := library.State {
			library_path = root,
		}
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		defer store.Close(&s)
		text := strings.concatenate({`{"op":"add","id":1}`, "\n", line, "\n"}, alloc)
		testing.expect(t, sqlite.run(s.data_store, "BEGIN"))
		result := replay(&s, {text}, context.allocator)
		testing.expectf(t, result == .BadEvent, "%s: got %v", line, result)
		testing.expect(t, sqlite.run(s.data_store, "ROLLBACK"))
	}
}
