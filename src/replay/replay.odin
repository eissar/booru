package replay

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import elog "../event_log"
import "../library/"
import "../progress"
import pijul "../slop_pijul"
import "../store"
import "../vendor/sqlite"

Error :: enum {
	None,
	BadEvent,
	Corrupted,
	UnsupportedVersion,
	// Writers omit empty strings; explicit string clears are not implemented yet.
	NotImplemented,
	DATABASE_ERR,
}

// Applies event streams inside the caller's transaction.
replay :: proc(
	s: ^library.State,
	streams: []string,
	backing_alloc: mem.Allocator,
	prog_callback: progress.Callback = nil,
	full_replay := true,
) -> Error {
	// Own all temporary reduction state and decoded strings until replay ends.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, backing_alloc, backing_alloc)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	tag_indexes := make(map[string]int, alloc)
	dictionary := make([dynamic]string, alloc)
	// TODO: Migrate to packed bitsets eventually to reduce memory.
	tag_memberships := make(map[int][dynamic]u8, alloc)
	seen_ids := make(map[int]bool, alloc)
	// Name deltas keep their full byte extent until reduction against the seed name at finalization.
	name_accs := make(map[int][dynamic]u8, alloc)
	comment_accs := make(map[int]string, alloc)
	finished: u64
	db := s.data_store
	tx := sqlite.Tx {
		db = db,
	}
	if prog_callback != nil {prog_callback({phase = "replay events"})}
	record: elog.Record
	record.fields = make([dynamic]elog.Field, 0, 16, alloc)
	item_insert: ^sqlite.Stmt
	defer {if item_insert != nil {sqlite.finalize(item_insert)}}
	item_patch, patch_rc := store.prepare_item_patch(db)
	if patch_rc != sqlite.OK {return .DATABASE_ERR}
	defer sqlite.finalize(item_patch)
	item_delete, delete_rc := store.prepare_item_delete(db)
	if delete_rc != sqlite.OK {return .DATABASE_ERR}
	defer sqlite.finalize(item_delete)
	for stream, i in streams {
		text := stream
		data := &text
		for line in strings.split_lines_iterator(data) {
			if strings.trim_space(line) == "" {continue}
			parsed_patch_name: [dynamic]u8
			parsed_patch_comment: string
			item, op, tags, err := parse_item(
				line,
				&record,
				&parsed_patch_name,
				&parsed_patch_comment,
				alloc,
			)
			if err != nil {return err}
			if item.id <= 0 {return .BadEvent}
			if op == "delete" {
				for field in record.fields {
					if field.key == "op" || field.key == "id" || field.key == "version" {continue}
					// Odin json omitempty still writes integer zeros; treat them as absent.
					if !field.is_array &&
					   field.values[0].kind == .Integer &&
					   field.values[0].text == "0" {continue}
					return .BadEvent
				}
			}
			rc: i32 = sqlite.OK
			store_err: store.Error
			switch op {
			case "add":
				if full_replay {
					if _, seen := seen_ids[item.id]; seen {return .BadEvent}
					seen_ids[item.id] = true
					if item_insert == nil {
						item_insert, rc = store.prepare_item_insert(db)
						if rc != sqlite.OK {return .DATABASE_ERR}
					}
					store_err = store.insert_item(&tx, item, item_insert)
				} else {
					store_err = store.insert_item(&tx, item)
				}
				if len(item.name) != 0 {
					acc := make([dynamic]u8, len(item.name), alloc)
					copy(acc[:], transmute([]u8)item.name)
					name_accs[item.id] = acc
				}
				if len(item.comment) != 0 {
					comment_accs[item.id] = strings.clone(item.comment, alloc)
				}
			case "patch":
				if full_replay && !seen_ids[item.id] {return .BadEvent}
				store_err = store.patch_item(&tx, item, item_patch)
			case "delete":
				if full_replay && !seen_ids[item.id] {return .BadEvent}
				store_err = store.delete_item(&tx, item.id, item_delete)
				if full_replay {seen_ids[item.id] = false}
			case:
				return .BadEvent
			}
			#partial switch store_err {
			case .None:
			case .NotFound, .DuplicateID:
				return .BadEvent
			case:
				return .DATABASE_ERR
			}
			if len(parsed_patch_name) != 0 {
				acc, has_acc := name_accs[item.id]
				if !has_acc {
					// In incremental replay without the add event, read the current name as seed.
					curr, found, read_rc := store.read_image_by_id(db, item.id, alloc)
					if read_rc != sqlite.OK || !found {return .DATABASE_ERR}
					acc = make([dynamic]u8, len(curr.name), alloc)
					copy(acc[:], transmute([]u8)curr.name)
				}
				if len(acc) < len(parsed_patch_name) {resize(&acc, len(parsed_patch_name))}
				for b, idx in parsed_patch_name {acc[idx] ~= b}
				name_accs[item.id] = acc
			}
			if len(parsed_patch_comment) != 0 {
				curr_comment, has_comment := comment_accs[item.id]
				if !has_comment {
					curr, found, read_rc := store.read_image_by_id(db, item.id, alloc)
					if read_rc != sqlite.OK || !found {return .DATABASE_ERR}
					curr_comment = curr.comment
				}
				new_comment := pijul.apply_patch(curr_comment, parsed_patch_comment, alloc)
				comment_accs[item.id] = new_comment
			}
			if !full_replay {
				if len(tags) != 0 {
					if store.toggle_tags(&tx, item.id, tags) != sqlite.OK {
						return .DATABASE_ERR
					}
				}
				finished += 1
				if prog_callback != nil {
					prog_callback({phase = "replay events", finished = finished})
				}
				continue // Incremental replay applies tags directly.
			}
			for tag in tags {
				index, known := tag_indexes[tag]
				if !known {
					owned_tag := strings.clone(tag, alloc)
					index = len(dictionary)
					tag_indexes[owned_tag] = index
					append(&dictionary, owned_tag)
				}
				membership := tag_memberships[item.id]
				if membership.allocator.procedure == nil {membership = make([dynamic]u8, alloc)}
				if len(membership) <= index {resize(&membership, index + 1)}
				membership[index] ~= 1
				tag_memberships[item.id] = membership
			}
			finished += 1
			if prog_callback != nil {prog_callback({phase = "replay events", finished = finished})}
		}
		if prog_callback != nil {prog_callback({phase = "replay files", finished = u64(i + 1)})}
	}
	name_stmt, comment_stmt: ^sqlite.Stmt
	defer {
		if name_stmt != nil {sqlite.finalize(name_stmt)}
		if comment_stmt != nil {sqlite.finalize(comment_stmt)}
	}
	if sqlite.prepare_v2(
		   db,
		   "UPDATE items SET name = ?2 WHERE id = ?1 AND deleted = 0",
		   -1,
		   &name_stmt,
		   nil,
	   ) !=
	   sqlite.OK {return .DATABASE_ERR}
	if sqlite.prepare_v2(
		   db,
		   "UPDATE items SET comment = ?2 WHERE id = ?1 AND deleted = 0",
		   -1,
		   &comment_stmt,
		   nil,
	   ) !=
	   sqlite.OK {return .DATABASE_ERR}
	for id, &acc in name_accs {
		if sqlite.bind_int64(name_stmt, 1, i64(id)) != sqlite.OK {return .DATABASE_ERR}
		length := len(acc)
		for length > 0 && acc[length - 1] == 0 {length -= 1}
		if !sqlite.bind_string(name_stmt, 2, string(acc[:length])) {return .DATABASE_ERR}
		if sqlite.step(name_stmt) != sqlite.DONE {return .DATABASE_ERR}
		if sqlite.reset(name_stmt) != sqlite.OK {return .DATABASE_ERR}
	}
	for id, comment in comment_accs {
		if sqlite.bind_int64(comment_stmt, 1, i64(id)) != sqlite.OK {return .DATABASE_ERR}
		if !sqlite.bind_string(comment_stmt, 2, comment) {return .DATABASE_ERR}
		if sqlite.step(comment_stmt) != sqlite.DONE {return .DATABASE_ERR}
		if sqlite.reset(comment_stmt) != sqlite.OK {return .DATABASE_ERR}
	}
	stmt: ^sqlite.Stmt
	defer {if stmt != nil {sqlite.finalize(stmt)}}
	rc := sqlite.prepare_v2(
		db,
		"INSERT INTO item_tags (item_id, tag) VALUES (?1, ?2)",
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK {return .DATABASE_ERR}
	for id, membership in tag_memberships {
		// Deleted items have no row; the old SELECT dropped their tags implicitly.
		if !seen_ids[id] {continue}
		for present, index in membership {
			if present == 0 {continue}
			rc = sqlite.bind_int64(stmt, 1, i64(id))
			if rc != sqlite.OK {return .DATABASE_ERR}
			if !sqlite.bind_string(stmt, 2, dictionary[index]) {return .DATABASE_ERR}
			rc = sqlite.step(stmt)
			if rc != sqlite.DONE {return .DATABASE_ERR}
			rc = sqlite.reset(stmt)
			if rc != sqlite.OK {return .DATABASE_ERR}
		}
	}
	return nil
}
@(private)
parse_item :: proc(
	line: string,
	record: ^elog.Record,
	name_bytes: ^[dynamic]u8,
	comment_patch: ^string,
	alloc: mem.Allocator,
) -> (
	item: library.Image,
	op: string,
	tags: []string,
	err: Error,
) {
	elog.parse_flat(line, record)
	for field in record.fields {
		if field.key == "tags" {
			if !field.is_array {return item, op, tags, .BadEvent}
			tags = make([]string, len(field.values), alloc)
			for token, i in field.values {
				if token.kind != .String {return item, op, tags, .BadEvent}
				tags[i] = replay_flat_string(token, alloc)
			}
			if elog.validate_tags(tags) != "" {return item, op, tags, .BadEvent}
			continue
		}
		if field.key == "tags_xor" {return item, op, tags, .BadEvent}
		if field.key == "name_xor" {return item, op, tags, .BadEvent}
		if field.is_array || len(field.values) != 1 {return item, op, tags, .BadEvent}
		token := field.values[0]
		// Absent version means version 0.
		if field.key == "version" {
			if token.kind != .Integer {return item, op, tags, .BadEvent}
			value, ok := strconv.parse_int(token.text)
			if !ok || value < 0 {return item, op, tags, .BadEvent}
			if value >
			   elog.MAX_SUPPORTED_EVENT_VERSION {return item, op, tags, .UnsupportedVersion}
			continue
		}
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
			if token.text == `""` && field.key != "op" {return item, op, tags, .NotImplemented}
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
			text := replay_flat_string(token, alloc)
			op_text := op
			if op_text == "" {
				for f in record.fields {
					if f.key == "op" &&
					   !f.is_array &&
					   len(f.values) == 1 &&
					   f.values[0].kind == .String {
						op_text = replay_flat_string(f.values[0], alloc)
						break
					}
				}
			}
			switch op_text {
			case "add":
				item.comment = text
			case "patch":
				comment_patch^ = text
			case "delete":
				return item, op, tags, .BadEvent
			case:
				item.comment = text
			}
		case "name":
			text := replay_flat_string(token, alloc)
			// In add events, name is the initial plaintext seed.
			// In patch events, name is the hex UTF-8 byte XOR delta.
			// If op field appears after name in JSON, look for op in record.fields:
			op_text := op
			if op_text == "" {
				for f in record.fields {
					if f.key == "op" &&
					   !f.is_array &&
					   len(f.values) == 1 &&
					   f.values[0].kind == .String {
						op_text = replay_flat_string(f.values[0], alloc)
						break
					}
				}
			}
			switch op_text {
			case "add":
				item.name = text
			case "patch":
				name_bytes^ = make([dynamic]u8, len(text) / 2, alloc)
				_, hex_ok := hex.decode_into_buffer(transmute([]u8)text, name_bytes[:])
				if len(text) % 2 != 0 || !hex_ok {return item, op, tags, .BadEvent}
			case "delete":
				return item, op, tags, .BadEvent
			case:
				// If op is unknown or yet unparsed, default to storing name seed
				item.name = text
			}
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
		case:
			return item, op, tags, .BadEvent
		}
	}
	return
}

replay_flat_string :: proc(token: elog.Token, alloc: mem.Allocator) -> string {
	assert(token.kind == .String)
	if !token.has_escapes {return token.text[1:len(token.text) - 1]}
	value, err := json.unquote_string(json.Token{kind = .String, text = token.text}, .JSON, alloc)
	assert(err == .None)
	return value
}

initiate_replay :: proc(
	s: ^library.State,
	prog_callback: progress.Callback = nil,
	full_replay := true,
) {
	upper: elog.Cursor
	if !full_replay {
		upper = s.event_log.cursor^ // capture by value
	}
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
		if !full_replay && entry.name != string(upper.shard[:]) {continue}
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
		if full_replay {
			bytes, read_err := os.read_entire_file(path, alloc)
			if read_err != nil {fmt.panicf("replay: cannot read %s: %v", path, read_err)}
			streams[i] = string(bytes)
			for len(streams[i]) > 0 && streams[i][len(streams[i]) - 1] != '\n' {
				streams[i] = streams[i][:len(streams[i]) - 1]
			}
			continue // Full replay reads the entire shard.
		}

		cursor, rc := elog.load_cursor(s.event_log, string(upper.shard[:]))
		if rc != sqlite.OK {fmt.panicf("replay: load cursor: %d", rc)}
		if cursor.offset < 0 || cursor.offset > upper.offset {
			fmt.panicf("replay: cursor outside append boundary")
		}
		file, open_err := os.open(path, {.Read})
		if open_err != nil {fmt.panicf("replay: cannot open %s: %v", path, open_err)}
		bytes := make([]u8, int(upper.offset - cursor.offset), alloc)
		read := 0
		for read < len(bytes) {
			n, read_err := os.read_at(file, bytes[read:], cursor.offset + i64(read))
			read += n
			if read == len(bytes) {break}
			if read_err != nil || n == 0 {
				fmt.panicf("replay: cannot read %s: %v", path, read_err)
			}
		}
		os.close(file)
		streams[i] = string(bytes)
	}
	db := s.data_store
	if !sqlite.run(db, "BEGIN") {fmt.panicf("replay: begin transaction")}
	defer {if sqlite.get_autocommit(db) == 0 {sqlite.run(db, "ROLLBACK")}}
	tx := sqlite.Tx {
		db = db,
	}
	if err := replay(s, streams, alloc, prog_callback, full_replay); err != nil {
		fmt.panicf("replay: %v", err)
	}
	for path, i in paths {
		cursor := upper
		if full_replay {
			copy(cursor.shard[:], path[len(path) - len(cursor.shard):])
			cursor.offset = i64(len(streams[i]))
		}
		if rc := elog.save_cursor(&tx, &cursor); rc != sqlite.OK {
			fmt.panicf("replay: save cursor: %d", rc)
		}
	}
	if !sqlite.run(db, "COMMIT") {fmt.panicf("replay: commit transaction")}

	if rc := store.create_indexes(s.data_store); rc != sqlite.OK {
		fmt.panicf("replay: create indexes: %d", rc)
	}
	stmt: ^sqlite.Stmt
	rc := sqlite.prepare_v2(
		db,
		"SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'items'), 0)",
		-1,
		&stmt,
		nil,
	)
	defer {if stmt != nil {sqlite.finalize(stmt)}}
	if rc != sqlite.OK || sqlite.step(stmt) != sqlite.ROW {
		fmt.panicf("replay: read item ID sequence")
	}
	library.seed_ids_from_library(int(sqlite.column_int64(stmt, 0)))
	if full_replay && s.event_log != nil && s.event_log.cursor != nil {
		s.event_log.cursor^ = {}
		if len(paths) > 0 {
			path := paths[len(paths) - 1]
			copy(s.event_log.cursor.shard[:], path[len(path) - len(s.event_log.cursor.shard):])
			s.event_log.cursor.offset = i64(len(streams[len(streams) - 1]))
		}
	}
}
