package replay

import "../library"
import "../store"
import "../vendor/sqlite"
import "core:fmt"
import "core:os"
import "core:testing"

@(test)
timestamp_advances_commute_and_merge :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-timestamps-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	// Equal, backward and absent inputs must not erase creation seeds.
	values := [?][2]i64{{120, 190}, {90, 250}, {120, 250}, {0, 0}, {-1, -2}}
	orders := [?][5]int{{0, 1, 2, 3, 4}, {4, 3, 2, 1, 0}, {2, 4, 0, 3, 1}}
	for order in orders {
		s := library.State {
			library_path = root,
		}
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		defer store.Close(&s)
		testing.expect(t, sqlite.run(s.data_store, "BEGIN"))
		seed := `{"op":"add","id":1,"mtime":100,"added_at":200}`
		streams := make([dynamic]string, alloc)
		append(&streams, seed)
		for index in order {
			v := values[index]
			append(
				&streams,
				fmt.tprintf(`{{"op":"patch","id":1,"mtime":%d,"added_at":%d}}`, v[0], v[1]),
			)
		}
		testing.expect(t, replay(&s, streams[:], alloc) == nil)
		item, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
		testing.expect(t, rc == sqlite.OK && found)
		testing.expect(t, item.mtime == 120 && item.added_at == 250)

		// Independently reduce two partitions through the same projection reducer,
		// then merge their summaries in both orders into the creation seed.
		tx := sqlite.Tx {
			db = s.data_store,
		}
		for id in 2 ..= 5 {
			testing.expect(
				t,
				store.insert_item(&tx, {id = id, mtime = 100, added_at = 200}) == .None,
			)
		}
		for index, position in order {
			v := values[index]
			testing.expect(
				t,
				store.patch_item(&tx, {id = 2 + position % 2, mtime = v[0], added_at = v[1]}) ==
				.None,
			)
		}
		for id in 4 ..= 5 {
			for part in 0 ..< 2 {
				source := id == 4 ? 2 + part : 3 - part
				summary, exists, read_rc := store.read_image_by_id(s.data_store, source, alloc)
				testing.expect(t, read_rc == sqlite.OK && exists)
				testing.expect(
					t,
					store.patch_item(
						&tx,
						{id = id, mtime = summary.mtime, added_at = summary.added_at},
					) ==
					.None,
				)
			}
			merged, exists, read_rc := store.read_image_by_id(s.data_store, id, alloc)
			testing.expect(t, read_rc == sqlite.OK && exists)
			testing.expect(t, merged.mtime == item.mtime && merged.added_at == item.added_at)
		}
		testing.expect(t, sqlite.run(s.data_store, "COMMIT"))
	}
}

@(test)
overwrite_rejects_nonzero_timestamps :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-timestamps-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	seed := `{"op":"add","id":1,"oid":"a","mtime":100,"added_at":200}`
	cases := []struct {
		line:     string,
		expected: Error,
	} {
		{`{"op":"overwrite","id":1,"oid":"b","mtime":0,"added_at":0}`, .None},
		{`{"op":"overwrite","id":1,"oid":"b","mtime":300}`, .BadEvent},
		{`{"op":"overwrite","id":1,"oid":"b","added_at":300}`, .BadEvent},
		{`{"op":"overwrite","id":1,"oid":"b","mtime":50}`, .BadEvent},
		{`{"op":"overwrite","id":1,"oid":"b","added_at":-1}`, .BadEvent},
		{`{"op":"overwrite","id":1,"oid":"b","mtime":"0"}`, .BadEvent},
	}
	for test in cases {
		for full_replay in ([]bool{true, false}) {
			s := library.State {
				library_path = root,
			}
			if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
			defer store.Close(&s)
			if !full_replay {
				testing.expect(t, sqlite.run(s.data_store, "BEGIN"))
				testing.expect(t, replay(&s, {seed}, context.allocator) == nil)
				testing.expect(t, sqlite.run(s.data_store, "COMMIT"))
			}
			streams := full_replay ? []string{seed, test.line} : []string{test.line}
			testing.expect(t, sqlite.run(s.data_store, "BEGIN"))
			result := replay(&s, streams, context.allocator, full_replay)
			testing.expectf(
				t,
				result == test.expected,
				"%s (full=%v): got %v",
				test.line,
				full_replay,
				result,
			)
			testing.expect(t, sqlite.run(s.data_store, result == nil ? "COMMIT" : "ROLLBACK"))
			if result != nil {continue}
			item, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
			testing.expect(t, rc == sqlite.OK && found)
			testing.expect(t, item.oid == "b" && item.mtime == 100 && item.added_at == 200)
		}
	}
}
