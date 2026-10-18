package replay

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import elog "../event_log"
import "../library/"
import "../store"
import "../vendor/sqlite"

Error :: enum {
	BadEvent,
	Corrupted,
	DATABASE_ERR,
}

// load library at path root into v
load_library :: proc(root: string, images: ^[dynamic]library.Image, alloc: mem.Allocator) {
	events_dir := fmt.tprintf("%s/events", root)
	dir_fi, _ := os.stat(events_dir, alloc)
	if dir_fi.type != .Directory {fmt.eprintln("library: cannot open events dir", events_dir)}
	os.file_info_delete(dir_fi, alloc)

	w := os.walker_create(events_dir)
	defer os.walker_destroy(&w)

	for entry in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}

		if !strings.has_suffix(entry.name, ".ndjson") {
			continue
		}

		data, err := os.read_entire_file(entry.fullpath, alloc)
		defer delete(data, alloc)

		if err != nil {
			fmt.eprintln("library: cannot read", entry.fullpath)
			continue
		}
		load_ndjson(images, string(data), alloc)
	}
}

load_ndjson :: proc(images: ^[dynamic]library.Image, data: string, alloc: mem.Allocator) {
	lines := strings.split(data, "\n", alloc)

	for line in lines {
		if strings.trim_space(line) == "" {continue}
		ev: elog.Event

		if err := json.unmarshal(transmute([]u8)line, &ev, json.DEFAULT_SPECIFICATION, alloc);
		   err != nil {
			fmt.eprintln("library: bad event ", err)
			continue
		}

		if ev.op != "add" {continue}
		append(
			images,
			library.Image {
				id = ev.id,
				oid = ev.oid,
				path = ev.path,
				ext = ev.ext,
				tags = ev.tags,
				width = ev.width,
				height = ev.height,
				name = ev.name,
				mtime = ev.mtime,
				added_at = ev.added_at,
				content_type = ev.content_type,
			},
		)
	}
}

replay :: proc(s: ^library.State, data: ^string, alloc: mem.Allocator) -> (err: Error) {
	db := s.data_store

	tx := sqlite.Tx{db}
	rc := sqlite.exec(db, "BEGIN", nil, nil, nil)
	if rc != sqlite.OK {return .DATABASE_ERR}

	// deferred rollback if we return error
	// tested to set named result for defer
	// so we can just do return nil/ return .DATABASE_ERR
	// and it works as you'd expect
	defer {
		if err != nil {
			if sqlite.get_autocommit(db) == 0 {
				sqlite.exec(db, "ROLLBACK", nil, nil, nil)
			}
			sqlite.close(db)
		}
	}

	for line in strings.split_lines_iterator(data) {
		if strings.trim_space(line) == "" {continue}

		ev: elog.Event
		if err := json.unmarshal(transmute([]u8)line, &ev, json.DEFAULT_SPECIFICATION, alloc);
		   err != nil {
			fmt.eprintln("library: bad event ", err)
			continue
		}

		// both 'add' and 'patch'
		// are just Event & op

		// switch
		switch ev.op {
		case "add":
			item := library.Image {
				id           = ev.id,
				oid          = ev.oid,
				path         = ev.path,
				ext          = ev.ext,
				tags         = ev.tags,
				width        = ev.width,
				height       = ev.height,
				name         = ev.name,
				mtime        = ev.mtime,
				added_at     = ev.added_at,
				content_type = ev.content_type,
			}
			rc := store.insert_into_items(&tx, item)
			if rc != sqlite.OK {
				return .DATABASE_ERR
			}
		case "patch":
			item := library.Image {
				id           = ev.id,
				oid          = ev.oid,
				path         = ev.path,
				ext          = ev.ext,
				tags         = ev.tags,
				width        = ev.width,
				height       = ev.height,
				name         = ev.name,
				mtime        = ev.mtime,
				added_at     = ev.added_at,
				content_type = ev.content_type,
			}
			rc := store.patch_item(&tx, item)
			if rc != sqlite.OK {
				return .DATABASE_ERR
			}

		case:
			fmt.eprintfln(
				"unsupported event type=%v . maybe corrupt library. continuing anyway.",
				ev.op,
			)
			continue
		}
	}
	commit_rc := sqlite.exec(db, "COMMIT", nil, nil, nil)
	if commit_rc != 0 {
		return .DATABASE_ERR
	}
	return nil
}

@(test)
test_replay :: proc(t: ^testing.T) {
	r := "/tmp/booru_eagle_import_test/events/2026-10.ndjson"
	alloc := context.temp_allocator
	data, err := os.read_entire_file(r, alloc)
	defer delete(data, alloc)

	s: library.State
	rc := store.Init(&s, ":memory:") // sqlite in-memory database
	if !testing.expect(t, rc == sqlite.OK) {return}

	text := string(data)
	replay_err := replay(&s, &text, alloc)
	testing.expect(t, replay_err == nil)

	stmt, ok := sqlite.prepare(s.data_store, "SELECT COUNT(*) FROM items")
	if !ok {return}
	defer sqlite.finalize(stmt)
	if sqlite.step(stmt) == sqlite.ROW {
		fmt.println(sqlite.column_int64(stmt, 0))
	}

}

// this calls replay for each ndjson file
initiate_replay :: proc(root: string, images: ^[dynamic]library.Image, alloc: mem.Allocator) {
	events_dir := fmt.tprintf("%s/events", root)
	dir_fi, _ := os.stat(events_dir, alloc)
	if dir_fi.type != .Directory {fmt.eprintln("library: cannot open events dir", events_dir)}
	os.file_info_delete(dir_fi, alloc)

	w := os.walker_create(events_dir)
	defer os.walker_destroy(&w)

	for entry in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}

		if !strings.has_suffix(entry.name, ".ndjson") {
			continue
		}

		data, err := os.read_entire_file(entry.fullpath, alloc)
		defer delete(data, alloc)

		if err != nil {
			fmt.eprintln("library: cannot read", entry.fullpath)
			continue
		}
		load_ndjson(images, string(data), alloc)
	}
}
