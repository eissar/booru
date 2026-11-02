package replay

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import elog "../event_log"
import "../library/"
import "../progress"
import "../store"
import "../vendor/sqlite"

Error :: enum {
	None,
	BadEvent,
	Corrupted,
	DATABASE_ERR,
}

// Full replay of an ordered slice of event streams.
replay :: proc(
	s: ^library.State,
	streams: []string,
	backing_alloc: mem.Allocator,
	prog_callback: progress.Callback = nil,
) -> Error {
	seen_ids := make(map[int]bool, backing_alloc)
	defer delete(seen_ids)
	max_id: int
	finished: u64
	if prog_callback != nil {prog_callback({phase = "replay events"})}

	db := s.data_store
	if !sqlite.run(db, "BEGIN") {return .DATABASE_ERR}
	defer {if sqlite.get_autocommit(db) == 0 {sqlite.run(db, "ROLLBACK")}}

	tx := sqlite.Tx {
		db = db,
	}
	record: elog.Record
	record.fields = make([dynamic]elog.Field, 0, 16, backing_alloc)
	defer delete(record.fields)

	for stream, i in streams {
		text := stream
		data := &text
		for line in strings.split_lines_iterator(data) {
			if strings.trim_space(line) == "" {continue}
			item, op := parse_item(line, &record, backing_alloc)
			rc: i32 = sqlite.OK
			switch op {
			case "add":
				if _, seen := seen_ids[item.id]; seen {return .BadEvent}
				seen_ids[item.id] = true
				max_id = max(max_id, item.id)
				rc = store.insert_into_items(&tx, item)
			case "patch":
				if !seen_ids[item.id] {return .BadEvent}
				rc = store.patch_item(&tx, item)
			case "delete":
				if !seen_ids[item.id] {return .BadEvent}
				rc = store.delete_item(&tx, item.id)
				seen_ids[item.id] = false
			case "regen_thumbnail":
			// Derived artifact integrity is outside replay's scope.
			case:
			}
			if rc != sqlite.OK {return .DATABASE_ERR}
			finished += 1
			if prog_callback != nil {prog_callback({phase = "replay events", finished = finished})}
		}
		if prog_callback != nil {prog_callback({phase = "replay files", finished = u64(i + 1)})}
	}

	if !sqlite.run(db, "COMMIT") {return .DATABASE_ERR}
	// Historical maximum includes creations subsequently deleted.
	library.seed_ids_from_library(max_id)
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
		case "comment":
			item.comment = replay_flat_string(token, alloc)
		case "name":
			item.name = replay_flat_string(token, alloc)
		case "content_type":
			item.content_type = replay_flat_string(token, alloc)
		case "mtime":
			assert(token.kind == .Integer)
			value, ok := strconv.parse_i64(token.text)
			assert(ok)
			item.mtime = value
		case "added_at":
			assert(token.kind == .Integer)
			value, ok := strconv.parse_i64(token.text)
			assert(ok)
			item.added_at = value
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

initiate_replay :: proc(s: ^library.State, prog_callback: progress.Callback = nil) {
	if prog_callback != nil {prog_callback({phase = "replay files"})}
	alloc := context.temp_allocator
	events_dir := fmt.tprintf("%s/events", s.library_path)
	dir_fi, stat_err := os.stat(events_dir, alloc)
	if stat_err != nil ||
	   dir_fi.type !=
		   .Directory {fmt.panicf("replay: cannot open events dir %s: %v", events_dir, stat_err)}
	os.file_info_delete(dir_fi, alloc)
	paths := make([dynamic]string, alloc)
	defer {
		for path in paths {delete(path, alloc)}
		delete(paths)
	}
	w := os.walker_create(events_dir)
	defer os.walker_destroy(&w)
	for entry in os.walker_walk(&w) {
		if _, err := os.walker_error(&w);
		   err != nil {fmt.panicf("replay: cannot walk %s: %v", events_dir, err)}
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".ndjson") {continue}
		append(&paths, strings.clone(entry.fullpath, alloc))
	}
	if _, err := os.walker_error(&w);
	   err != nil {fmt.panicf("replay: cannot walk %s: %v", events_dir, err)}
	slice.sort(paths[:])
	streams := make([]string, len(paths), alloc)
	defer {
		for stream in streams {delete(stream, alloc)}
		delete(streams, alloc)
	}
	for path, i in paths {
		bytes, read_err := os.read_entire_file(path, alloc)
		if read_err != nil {fmt.panicf("replay: cannot read %s: %v", path, read_err)}
		streams[i] = string(bytes)
	}
	if err := replay(s, streams, alloc, prog_callback); err != nil {fmt.panicf("replay: %v", err)}

	if rc := store.create_indexes(s.data_store); rc != sqlite.OK {
		fmt.panicf("replay: create indexes: %d", rc)
	}
}
