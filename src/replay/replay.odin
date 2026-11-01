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

// Full replay of a single input, including final tag reduction.
replay :: proc(
	s: ^library.State,
	data: ^string,
	alloc: mem.Allocator,
	prog_callback: progress.Callback = nil,
) -> Error {
	return replay_inputs(s, data, nil, alloc, prog_callback)
}

@(private)
Scan :: struct {
	rows:     [dynamic]store.Tag_Row,
	// Creation history and current liveness, never tag membership or parity.
	seen_ids: map[int]bool,
	max_id:   int,
	finished: u64,
}

@(private)
replay_inputs :: proc(
	s: ^library.State,
	data: ^string,
	paths: []string,
	backing_alloc: mem.Allocator,
	prog_callback: progress.Callback,
) -> Error {
	// The reduction may overwrite duplicate rows, so own all decoded strings in
	// one arena rather than attempting to free strings through compacted rows.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, backing_alloc, backing_alloc)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	scan := Scan {
		rows     = make([dynamic]store.Tag_Row, backing_alloc),
		seen_ids = make(map[int]bool, backing_alloc),
	}
	defer delete(scan.rows)
	defer delete(scan.seen_ids)
	db := s.data_store
	if !sqlite.run(db, "BEGIN") {return .DATABASE_ERR}
	defer {if sqlite.get_autocommit(db) == 0 {sqlite.run(db, "ROLLBACK")}}
	tx := sqlite.Tx {
		db = db,
	}
	if prog_callback != nil {prog_callback({phase = "replay events"})}
	if data != nil {
		if err := scan_events(&tx, data, &scan, alloc, prog_callback); err != nil {return err}
	} else {
		for path, i in paths {
			bytes, read_err := os.read_entire_file(path, backing_alloc)
			if read_err != nil {
				fmt.eprintln("replay: cannot read", path, read_err)
				return .Corrupted
			}
			text := string(bytes)
			err := scan_events(&tx, &text, &scan, alloc, prog_callback)
			delete(bytes, backing_alloc)
			if err != nil {return err}
			if prog_callback !=
			   nil {prog_callback({phase = "replay files", finished = u64(i + 1)})}
		}
	}
	if store.insert_reduced_tags(&tx, reduce_tags(scan.rows[:])) !=
	   sqlite.OK {return .DATABASE_ERR}
	if !sqlite.run(db, "COMMIT") {return .DATABASE_ERR}
	// Historical maximum includes creations subsequently deleted.
	library.seed_ids_from_library(scan.max_id)
	return nil
}

@(private)
scan_events :: proc(
	tx: ^sqlite.Tx,
	data: ^string,
	scan: ^Scan,
	alloc: mem.Allocator,
	prog_callback: progress.Callback,
) -> Error {
	record: elog.Record
	record.fields = make([dynamic]elog.Field, 0, 16, alloc)
	defer delete(record.fields)
	for line in strings.split_lines_iterator(data) {
		if strings.trim_space(line) == "" {continue}
		item, op, tags, err := parse_item(line, &record, alloc)
		if err != nil {return err}
		if item.id <= 0 {return .BadEvent}
		rc: i32 = sqlite.OK
		switch op {
		case "add":
			if _, seen := scan.seen_ids[item.id]; seen {return .BadEvent}
			scan.seen_ids[item.id] = true
			scan.max_id = max(scan.max_id, item.id)
			rc = store.insert_into_items(tx, item)
		case "patch":
			if !scan.seen_ids[item.id] {return .BadEvent}
			rc = store.patch_item(tx, item)
		case "delete":
			if len(tags) != 0 || !scan.seen_ids[item.id] {return .BadEvent}
			rc = store.delete_item(tx, item.id)
			scan.seen_ids[item.id] = false
		case "regen_thumbnail":
			if len(tags) != 0 {return .BadEvent}
		// Derived artifact integrity is outside replay's scope.
		case:
			return .BadEvent
		}
		if rc != sqlite.OK {return .DATABASE_ERR}
		for tag in tags {append(&scan.rows, store.Tag_Row{item.id, tag})}
		scan.finished += 1
		if prog_callback !=
		   nil {prog_callback({phase = "replay events", finished = scan.finished})}
	}
	return nil
}

@(private)
parse_item :: proc(
	line: string,
	record: ^elog.Record,
	alloc: mem.Allocator,
) -> (
	item: library.Image,
	op: string,
	tags: []string,
	err: Error,
) {
	elog.parse_flat(line, record)
	for field in record.fields {
		// Legacy additive records are deliberately unsupported.
		if field.key == "tags" {return item, op, tags, .BadEvent}
		if field.key == "tags_xor" {
			if !field.is_array {return item, op, tags, .BadEvent}
			tags = make([]string, len(field.values), alloc)
			for token, i in field.values {
				if token.kind != .String {return item, op, tags, .BadEvent}
				tags[i] = replay_flat_string(token, alloc)
			}
			if elog.validate_tags_xor(tags) != "" {return item, op, tags, .BadEvent}
			continue
		}
		if field.is_array || len(field.values) != 1 {return item, op, tags, .BadEvent}
		token := field.values[0]
		if field.key == "id" || field.key == "width" || field.key == "height" {
			if token.kind != .Integer {return item, op, tags, .BadEvent}
			value, ok := strconv.parse_int(token.text)
			if !ok {return item, op, tags, .BadEvent}
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
		if field.key == "op" ||
		   field.key == "oid" ||
		   field.key == "path" ||
		   field.key == "ext" ||
		   field.key == "comment" ||
		   field.key == "name" ||
		   field.key == "content_type" {
			if token.kind != .String {return item, op, tags, .BadEvent}
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
			if token.kind != .Integer {return item, op, tags, .BadEvent}
			value, ok := strconv.parse_i64(token.text)
			if !ok {return item, op, tags, .BadEvent}
			item.mtime = value
		case "added_at":
			if token.kind != .Integer {return item, op, tags, .BadEvent}
			value, ok := strconv.parse_i64(token.text)
			if !ok {return item, op, tags, .BadEvent}
			item.added_at = value
		}
	}
	return
}

replay_flat_string :: proc(token: elog.Token, alloc: mem.Allocator) -> string {
	assert(token.kind == .String)
	// Retained tag strings must survive freeing the current shard buffer.
	if !token.has_escapes {return strings.clone(token.text[1:len(token.text) - 1], alloc)}
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
	if err := replay_inputs(s, nil, paths[:], alloc, prog_callback);
	   err != nil {fmt.panicf("replay: %v", err)}

	if rc := store.create_indexes(s.data_store); rc != sqlite.OK {
		fmt.panicf("replay: create indexes: %d", rc)
	}
}
