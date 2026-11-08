package replay

import "core:container/lru"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

import elog "../event_log"
import "../library/"
import "../progress"
import pijul "../slop_pijul"
import "../store"
import "../vendor/sqlite"

Error :: enum {
	None,
	BadEvent,
	UnsupportedVersion,
	// Writers omit empty strings; explicit string clears are not implemented yet.
	NotImplemented,
	DATABASE_ERR,
}

Patch_State :: struct {
	mtime:    i64,
	added_at: i64,
	name:     [dynamic]u8,
	comment:  string,
	tags:     [dynamic]u8,
}

Item_Status :: enum u8 {
	Absent,
	Live,
	Deleted,
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

	swap := init_swap(s.library_path)
	defer destroy_swap(&swap)

	// Bounded in-memory working set; evictions spill to swap.bin
	patch_states: lru.Cache(int, Patch_State)
	lru.init(&patch_states, capacity = 10_000, entries_allocator = alloc, node_allocator = alloc)
	defer lru.destroy(&patch_states, call_on_remove = false)
	patch_states.on_remove = on_evict_to_swap
	patch_states.on_remove_user_data = &swap

	seen_ids := make(map[int]Item_Status, alloc)
	finished: u64

	db := s.data_store
	tx := sqlite.Tx {
		db = db,
	}
	if prog_callback != nil {prog_callback({phase = "replay events"})}

	record: elog.Record
	record.fields = make([dynamic]elog.Field, 0, 16, alloc)

	// Statements for event stream reduction
	item_patch: ^sqlite.Stmt
	if !full_replay {
		patch_rc: i32
		item_patch, patch_rc = store.prepare_item_patch(db)
		if patch_rc != sqlite.OK {return .DATABASE_ERR}
	}
	defer {if item_patch != nil {sqlite.finalize(item_patch)}}
	item_delete, delete_rc := store.prepare_item_delete(db)
	if delete_rc != sqlite.OK {return .DATABASE_ERR}
	defer sqlite.finalize(item_delete)
	lww_items := make(map[int]library.Image, alloc)

	// process event streams
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
			rc: i32 = sqlite.OK
			store_err: store.Error
			// Lifecycle: the only place item status is decided (lifecycle.fly).
			if full_replay {
				next_status, ok := lifecycle_step(seen_ids[item.id], op)
				if !ok {return .BadEvent}
				seen_ids[item.id] = next_status
			}
			switch op {
			case "add":
				if full_replay {
					// seed
					lww_items[item.id] = item
					state := Patch_State {
						mtime    = item.mtime,
						added_at = item.added_at,
					}
					if len(item.name) != 0 {
						state.name = make([dynamic]u8, len(item.name), alloc)
						copy(state.name[:], transmute([]u8)item.name)
					}
					if len(item.comment) != 0 {
						state.comment = strings.clone(item.comment, alloc)
					}
					lru.set(&patch_states, item.id, state)
				} else {
					store_err = store.insert_item(&tx, item)
				}
			case "patch":
				if !full_replay && (item.mtime != 0 || item.added_at != 0) {
					store_err = store.patch_item(&tx, item, item_patch)
				} else if full_replay {
					state, ok := lru.get(&patch_states, item.id)
					if !ok &&
					   seen_ids[item.id] != .Absent {state = swap_read(&swap, item.id, alloc)}
					if item.mtime != 0 {state.mtime = max(state.mtime, item.mtime)}
					if item.added_at != 0 {state.added_at = max(state.added_at, item.added_at)}
					lru.set(&patch_states, item.id, state)
				}
			case "overwrite":
				if full_replay {
					existing := lww_items[item.id]
					if len(item.oid) > 0 {existing.oid = item.oid}
					if len(item.path) > 0 {existing.path = item.path}
					if len(item.ext) > 0 {existing.ext = item.ext}
					if len(item.content_type) > 0 {existing.content_type = item.content_type}
					if item.width > 0 {existing.width = item.width}
					if item.height > 0 {existing.height = item.height}
					lww_items[item.id] = existing
				} else {
					// In incremental replay, apply overwrite directly
					store_err = store.overwrite_item(&tx, item)
				}
			case "delete":
				if !full_replay {
					// TODO: full replay's delete is provisional until delete is a tombstone
					store_err = store.delete_item(&tx, item.id, item_delete)
				}
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
				state, ok := lru.get(&patch_states, item.id)
				if !ok && seen_ids[item.id] != .Absent {state = swap_read(&swap, item.id, alloc)}
				if !full_replay && state.name == nil {
					// In incremental replay without the add event, read the current name as seed.
					curr, found, read_rc := store.read_image_by_id(db, item.id, alloc)
					if read_rc != sqlite.OK || !found {return .DATABASE_ERR}
					state.name = make([dynamic]u8, len(curr.name), alloc)
					copy(state.name[:], transmute([]u8)curr.name)
				}
				if len(state.name) <
				   len(parsed_patch_name) {resize(&state.name, len(parsed_patch_name))}
				for b, idx in parsed_patch_name {state.name[idx] ~= b}
				lru.set(&patch_states, item.id, state)
			}
			if len(parsed_patch_comment) != 0 {
				state, ok := lru.get(&patch_states, item.id)
				if !ok && seen_ids[item.id] != .Absent {state = swap_read(&swap, item.id, alloc)}
				if !full_replay && len(state.comment) == 0 {
					curr, found, read_rc := store.read_image_by_id(db, item.id, alloc)
					if read_rc != sqlite.OK || !found {return .DATABASE_ERR}
					state.comment = curr.comment
				}
				state.comment = pijul.apply_patch(state.comment, parsed_patch_comment, alloc)
				lru.set(&patch_states, item.id, state)
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
				state, ok := lru.get(&patch_states, item.id)
				if !ok && seen_ids[item.id] != .Absent {state = swap_read(&swap, item.id, alloc)}
				if state.tags.allocator.procedure == nil {state.tags = make([dynamic]u8, alloc)}
				if len(state.tags) <= index {resize(&state.tags, index + 1)}
				state.tags[index] ~= 1
				lru.set(&patch_states, item.id, state)
			}
			finished += 1
			if prog_callback != nil {prog_callback({phase = "replay events", finished = finished})}
		}
		if prog_callback != nil {prog_callback({phase = "replay files", finished = u64(i + 1)})}
	}
	// Flush remaining hot items in LRU cache to swap backing
	for id, node in patch_states.entries {
		swap_write(&swap, id, &node.value)
	}

	tag_stmt: ^sqlite.Stmt
	defer {if tag_stmt != nil {sqlite.finalize(tag_stmt)}}
	rc := sqlite.prepare_v2(
		db,
		"INSERT INTO item_tags (item_id, tag) VALUES (?1, ?2)",
		-1,
		&tag_stmt,
		nil,
	)
	if rc != sqlite.OK {return .DATABASE_ERR}

	// Finalization: insert complete item rows in ascending ID order
	if full_replay {
		if vtab_insert_items(db, &swap, &lww_items, &seen_ids) != sqlite.OK {
			return .DATABASE_ERR
		}
		for id := 1; id <= swap.max_id; id += 1 {
			if swap.index[id] == 0 {continue}
			status := seen_ids[id]
			if status == .Absent || status == .Deleted {continue}
			state := swap_read(&swap, id, context.temp_allocator)
			for present, index in state.tags {
				if present == 0 {continue}
				rc = sqlite.bind_int64(tag_stmt, 1, i64(id))
				if rc != sqlite.OK {return .DATABASE_ERR}
				if !sqlite.bind_string(tag_stmt, 2, dictionary[index]) {return .DATABASE_ERR}
				rc = sqlite.step(tag_stmt)
				if rc != sqlite.DONE {return .DATABASE_ERR}
				rc = sqlite.reset(tag_stmt)
				if rc != sqlite.OK {return .DATABASE_ERR}
			}
		}
	} else {
		force_write, force_write_rc := store.prepare_item_force_write(db)
		if force_write_rc != sqlite.OK {return .DATABASE_ERR}
		defer sqlite.finalize(force_write)

		for id := 1; id <= swap.max_id; id += 1 {
			if swap.index[id] == 0 {continue}
			state := swap_read(&swap, id, context.temp_allocator)
			length := len(state.name)
			for length > 0 && state.name[length - 1] == 0 {length -= 1}
			name := string(state.name[:length])

			err := store.force_write_item(
				&tx,
				id,
				name = len(name) > 0 ? &name : nil,
				comment = len(state.comment) > 0 ? &state.comment : nil,
				mtime = state.mtime > 0 ? &state.mtime : nil,
				added_at = state.added_at > 0 ? &state.added_at : nil,
				prepared = force_write,
			)
			if err != .None && err != .NotFound {return .DATABASE_ERR}
			if len(state.tags) != 0 {
				for present, index in state.tags {
					if present == 0 {continue}
					rc = sqlite.bind_int64(tag_stmt, 1, i64(id))
					if rc != sqlite.OK {return .DATABASE_ERR}
					if !sqlite.bind_string(tag_stmt, 2, dictionary[index]) {return .DATABASE_ERR}
					rc = sqlite.step(tag_stmt)
					if rc != sqlite.DONE {return .DATABASE_ERR}
					rc = sqlite.reset(tag_stmt)
					if rc != sqlite.OK {return .DATABASE_ERR}
				}
			}
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

	// Extract op, id, version upfront
	for f in record.fields {
		if f.key == "version" {
			if f.is_array || len(f.values) != 1 {return item, op, tags, .BadEvent}
			token := f.values[0]
			if token.kind != .Integer {return item, op, tags, .BadEvent}
			value, ok := strconv.parse_int(token.text)
			if !ok || value < 0 {return item, op, tags, .BadEvent}
			if value >
			   elog.MAX_SUPPORTED_EVENT_VERSION {return item, op, tags, .UnsupportedVersion}
			continue
		}
		if f.is_array || len(f.values) != 1 {continue}
		token := f.values[0]
		switch f.key {
		case "op":
			if token.kind == .String {
				op = replay_flat_string(token, alloc)
			}
		case "id":
			if token.kind == .Integer {
				if value, ok := strconv.parse_int(token.text); ok {
					item.id = value
				}
			}
		}
	}

	if op == "" {return item, op, tags, .BadEvent}

	switch op {
	case "add":
		for field in record.fields {
			if field.key == "op" || field.key == "id" || field.key == "version" {continue}
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
			if field.is_array || len(field.values) != 1 {return item, op, tags, .BadEvent}
			token := field.values[0]
			switch field.key {
			case "oid":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.oid = replay_flat_string(token, alloc)
			case "path":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.path = replay_flat_string(token, alloc)
			case "ext":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.ext = replay_flat_string(token, alloc)
			case "content_type":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.content_type = replay_flat_string(token, alloc)
			case "name":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.name = replay_flat_string(token, alloc)
			case "comment":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				item.comment = replay_flat_string(token, alloc)
			case "width":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_int(token.text);
				   ok {item.width = v} else {return item, op, tags, .BadEvent}
			case "height":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_int(token.text);
				   ok {item.height = v} else {return item, op, tags, .BadEvent}
			case "mtime":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_i64(token.text);
				   ok {item.mtime = v} else {return item, op, tags, .BadEvent}
			case "added_at":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_i64(token.text);
				   ok {item.added_at = v} else {return item, op, tags, .BadEvent}
			case:
				return item, op, tags, .BadEvent
			}
		}

	case "patch":
		for field in record.fields {
			if field.key == "op" || field.key == "id" || field.key == "version" {continue}
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
			if field.is_array || len(field.values) != 1 {return item, op, tags, .BadEvent}
			token := field.values[0]
			switch field.key {
			case "name":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				text := replay_flat_string(token, alloc)
				name_bytes^ = make([dynamic]u8, len(text) / 2, alloc)
				_, hex_ok := hex.decode_into_buffer(transmute([]u8)text, name_bytes[:])
				if len(text) % 2 != 0 || !hex_ok {return item, op, tags, .BadEvent}
			case "comment":
				if token.kind != .String {return item, op, tags, .BadEvent}
				if token.text == `""` {return item, op, tags, .NotImplemented}
				comment_patch^ = replay_flat_string(token, alloc)
			case "mtime":
				if token.kind == .Integer && token.text == "0" {continue}
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_i64(token.text);
				   ok {item.mtime = v} else {return item, op, tags, .BadEvent}
			case "added_at":
				if token.kind == .Integer && token.text == "0" {continue}
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_i64(token.text);
				   ok {item.added_at = v} else {return item, op, tags, .BadEvent}
			case "width", "height":
				if token.kind == .Integer && token.text == "0" {continue}
				return item, op, tags, .BadEvent
			case:
				return item, op, tags, .BadEvent
			}
		}

	case "overwrite":
		for field in record.fields {
			if field.key == "op" || field.key == "id" || field.key == "version" {continue}
			if field.is_array || len(field.values) != 1 {return item, op, tags, .BadEvent}
			token := field.values[0]
			switch field.key {
			case "oid":
				if token.kind != .String {return item, op, tags, .BadEvent}
				item.oid = replay_flat_string(token, alloc)
			case "path":
				if token.kind != .String {return item, op, tags, .BadEvent}
				item.path = replay_flat_string(token, alloc)
			case "ext":
				if token.kind != .String {return item, op, tags, .BadEvent}
				item.ext = replay_flat_string(token, alloc)
			case "content_type":
				if token.kind != .String {return item, op, tags, .BadEvent}
				item.content_type = replay_flat_string(token, alloc)
			case "width":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_int(token.text);
				   ok {item.width = v} else {return item, op, tags, .BadEvent}
			case "height":
				if token.kind != .Integer {return item, op, tags, .BadEvent}
				if v, ok := strconv.parse_int(token.text);
				   ok {item.height = v} else {return item, op, tags, .BadEvent}
			case "mtime", "added_at":
				if token.kind == .Integer && token.text == "0" {continue}
				return item, op, tags, .BadEvent
			case:
				return item, op, tags, .BadEvent
			}
		}

	case "delete":
		for field in record.fields {
			if field.key == "op" || field.key == "id" || field.key == "version" {continue}
			if !field.is_array &&
			   field.values[0].kind == .Integer &&
			   field.values[0].text == "0" {continue}
			return item, op, tags, .BadEvent
		}

	case:
		return item, op, tags, .BadEvent
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

// lifecycle_step is accepts/next from lifecycle.fly. It sees only the owning item's
// status and the op, so events on different items are independent.
lifecycle_step :: proc(s: Item_Status, op: string) -> (next: Item_Status, ok: bool) {
	switch op {
	case "add":
		if s != .Absent {return s, false}
		return .Live, true
	case "patch", "overwrite":
		if s != .Live {return s, false}
		return .Live, true
	case "delete":
		if s != .Live {return s, false}
		return .Deleted, true
	}
	return s, false
}
