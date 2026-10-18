package replay

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import elog "../event_log"
import "../library/"
import "../store"
import "../vendor/sqlite"

Error :: enum {
	BadEvent,
	Corrupted,
	DATABASE_ERR,
}

replay :: proc(s: ^library.State, data: ^string, alloc: mem.Allocator) -> Error {
	db := s.data_store
	if !sqlite.run(db, "BEGIN") {return .DATABASE_ERR}
	defer {
		if sqlite.get_autocommit(db) == 0 {sqlite.run(db, "ROLLBACK")}
	}
	tx := sqlite.Tx {
		db = db,
	}
	record: elog.Record
	record.fields = make([dynamic]elog.Field, 0, 16, alloc)
	defer delete(record.fields)
	for line in strings.split_lines_iterator(data) {
		if strings.trim_space(line) == "" {continue}
		item, op := parse_item(line, &record, alloc)
		rc: i32 = sqlite.OK
		switch op {
		case "add":
			rc = store.insert_into_items(&tx, item)
		case "patch":
			rc = store.patch_item(&tx, item)
		case "delete":
			rc = store.delete_item(&tx, item.id)
		case "regen_thumbnail":
			// basic event replay - validating derived artifact integrity is out of scope.
			continue
		case:
			continue
		}
		if rc != sqlite.OK {return .DATABASE_ERR}
	}
	if !sqlite.run(db, "COMMIT") {return .DATABASE_ERR}
	return nil
}

@(private = "file")
parse_item :: proc(
	line: string,
	record: ^elog.Record,
	alloc: mem.Allocator,
) -> (
	item: library.Image,
	op: string,
) {
	elog.parse_flat(line, record)
	for field in record.fields {
		if field.key == "tags" {
			assert(field.is_array)
			item.tags = make([]string, len(field.values), alloc)
			for token, i in field.values {
				item.tags[i] = replay_flat_string(token, alloc)
			}
			continue
		}
		assert(!field.is_array && len(field.values) == 1)
		token := field.values[0]
		if field.key == "id" || field.key == "width" || field.key == "height" {
			assert(token.kind == .Integer)
			value, ok := strconv.parse_int(token.text)
			assert(ok)
			switch field.key {
			case "id":
				item.id = value
			case "width":
				item.width = value
			case "height":
				item.height = value
			}
			continue
		}
		switch field.key {
		case "op":
			op = replay_flat_string(token, alloc)
		case "oid":
			item.oid = replay_flat_string(token, alloc)
		case "path":
			item.path = replay_flat_string(token, alloc)
		case "ext":
			item.ext = replay_flat_string(token, alloc)
		case "name":
			item.name = replay_flat_string(token, alloc)
		case "content_type":
			item.content_type = replay_flat_string(token, alloc)
		case "mtime":
			item.mtime = replay_flat_string(token, alloc)
		case "added_at":
			item.added_at = replay_flat_string(token, alloc)
		}
	}

	return
}

replay_flat_string :: proc(token: elog.Token, alloc: mem.Allocator) -> string {
	assert(token.kind == .String)
	if !token.has_escapes {return token.text[1:len(token.text) - 1]}
	value, _, ok := strconv.unquote_string(token.text, alloc)
	assert(ok)
	return value
}

// this calls replay for each ndjson file
initiate_replay :: proc(s: ^library.State) {
	alloc := context.temp_allocator
	events_dir := fmt.tprintf("%s/events", s.library_path)
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
		text := string(data)
		if replay_err := replay(s, &text, alloc); replay_err != nil {
			fmt.panicf("replay: %s: %v", entry.fullpath, replay_err)
		}
	}
}
