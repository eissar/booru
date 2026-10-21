package event_log

import "core:bufio"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf16"
import "core:unicode/utf8"

import "../vendor/sqlite"

// TODO: (V1)
// make this larger to support
// events of a larger size.
// when you do so, we will
// need to enforce this
// at a database level as well.
MAX_RECORD :: 2048

// Replay progress: offset is the byte immediately after a committed newline.
Cursor :: struct {
	shard:  string,
	offset: i64,
}

Op :: enum {
	Add,
	Patch,
	Delete,
	Regen_Thumbnail,
}

// One writer owns the filesystem log. SQLite owns derived replay progress.
EventLog :: struct {
	root: string,
	db:   ^sqlite.DB,
}

Event :: struct {
	added_at:     i64 `json:"added_at,omitempty"`,
	comment:      string `json:"comment,omitempty"`,
	content_type: string `json:"content_type,omitempty"`,
	ext:          string `json:"ext,omitempty"`,
	height:       int `json:"height,omitempty"`,
	id:           int `json:"id"`,
	mtime:        i64 `json:"mtime,omitempty"`,
	name:         string `json:"name,omitempty"`,
	oid:          string `json:"oid,omitempty"`,
	op:           string `json:"op,omitempty"`,
	path:         string `json:"path,omitempty"`,
	tags:         []string `json:"tags,omitempty"`,
	width:        int `json:"width,omitempty"`,
}


// Returns empty string on no error.
event_append :: proc(log: ^EventLog, e: Event) -> (err: string) {
	shard := get_current_event_shard(context.temp_allocator)

	path, join_err := os.join_path({log.root, "events", shard}, context.temp_allocator)
	if join_err != nil {
		return "random error joining path?"
	}

	ev_opts := os.File_Flags{.Write, .Create, .Append}
	ev_handle, ev_open_err := os.open(path, ev_opts, os.Permissions_Default_File)
	if ev_open_err != nil {
		return "could not open event log for writing" // retryable?
	}
	defer os.close(ev_handle)

	opt := json.Marshal_Options {
		spec   = .JSON,
		pretty = false,
	}
	data, marshal_err := json.marshal(e, opt, context.temp_allocator)
	if marshal_err != nil {return "could not marshal event"}
	defer delete(data, context.temp_allocator)
	ascii: strings.Builder
	strings.builder_init(&ascii, context.temp_allocator)
	defer strings.builder_destroy(&ascii)
	encode_ascii_json(data, &ascii)
	payload := transmute([]u8)strings.to_string(ascii)
	if len(payload) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
	written, write_err := os.write(ev_handle, payload)
	if write_err != nil || written != len(payload) {return "could not write event payload"}
	if io.write_byte(os.to_writer(ev_handle), '\n') != nil {
		return "could not write event newline"
	}
	if os.sync(ev_handle) != nil {
		return "could not sync event log"
	}

	when ODIN_OS == .Linux {
		dir, dir_err := os.open(
			fmt.tprintf("%s/events", log.root),
			{.Read},
			os.Permissions_Default,
		)
		if dir_err != nil {return "could not open events directory for syncing"}
		defer os.close(dir)
		if os.sync(dir) != nil {return "could not sync events directory"}
	}
	return ""
}

// Appends one batch, flushing and syncing once.
events_append :: proc(log: ^EventLog, events: []Event) -> (err: string) {
	if len(events) == 0 {return ""}
	shard := get_current_event_shard(context.temp_allocator)

	path, join_err := os.join_path({log.root, "events", shard}, context.temp_allocator)
	if join_err != nil {
		return "random error joining path?"
	}

	ev_opts := os.File_Flags{.Write, .Create, .Append}
	ev_handle, ev_open_err := os.open(path, ev_opts, os.Permissions_Default_File)
	if ev_open_err != nil {
		return "could not open event log for writing" // retryable?
	}
	defer os.close(ev_handle)

	opt := json.Marshal_Options {
		spec   = .JSON,
		pretty = false,
	}

	input_stream := os.to_writer(ev_handle)

	bw: bufio.Writer
	bufio.writer_init(&bw, input_stream, size = 1024, allocator = context.allocator)
	defer bufio.writer_destroy(&bw)

	buffered_stream := bufio.writer_to_stream(&bw)
	for event in events {
		data, marshal_err := json.marshal(event, opt, context.allocator)
		if marshal_err != nil {return "could not marshal event"}
		defer delete(data, context.allocator)
		ascii: strings.Builder
		strings.builder_init(&ascii, context.allocator)
		defer strings.builder_destroy(&ascii)
		encode_ascii_json(data, &ascii)
		payload := transmute([]u8)strings.to_string(ascii)
		if len(payload) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
		written, write_err := io.write(buffered_stream, payload)
		if write_err != nil || written != len(payload) {return "could not write event payload"}
		if io.write_byte(buffered_stream, '\n') != nil {
			return "could not write event newline"
		}
	}
	if bufio.writer_flush(&bw) != nil {
		return "could not flush event log"
	}
	if os.sync(ev_handle) != nil {
		return "could not sync event log"
	}

	when ODIN_OS == .Linux {
		dir, dir_err := os.open(
			fmt.tprintf("%s/events", log.root),
			{.Read},
			os.Permissions_Default,
		)
		if dir_err != nil {return "could not open events directory for syncing"}
		defer os.close(dir)
		if os.sync(dir) != nil {return "could not sync events directory"}
	}
	return ""
}

// Preserve JSON syntax and existing escapes; encode only raw non-ASCII runes.
@(private = "file")
encode_ascii_json :: proc(data: []u8, out: ^strings.Builder) {
	hex := "0123456789abcdef"
	text := string(data)
	for offset := 0; offset < len(text); {
		r, width := utf8.decode_rune_in_string(text[offset:])
		if r == utf8.RUNE_ERROR && width == 1 {panic("invalid UTF-8 in marshaled event")}
		offset += width
		if r < 128 {
			strings.write_byte(out, u8(r))
			continue
		}
		units := [2]rune{r, 0}
		count := 1
		if r > 0xffff {
			units[0], units[1] = utf16.encode_surrogate_pair(r)
			count = 2
		}
		shifts := [4]uint{12, 8, 4, 0}
		for unit in units[:count] {
			strings.write_string(out, "\\u")
			for shift in shifts {
				strings.write_byte(out, hex[(u32(unit) >> shift) & 15])
			}
		}
	}
}

// Missing shards start at offset zero. Cursor.shard borrows the input string.
load_cursor :: proc(log: ^EventLog, shard: string) -> (cursor: Cursor, rc: c.int) {
	cursor.shard = shard
	stmt: ^sqlite.Stmt
	rc = sqlite.prepare_v2(
		log.db,
		"SELECT byte_offset FROM replay_cursors WHERE shard = ?",
		-1,
		&stmt,
		nil,
	)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return cursor, rc}
	if !sqlite.bind_string(stmt, 1, shard) {return cursor, 1} 	// SQLITE_ERROR
	rc = sqlite.step(stmt)
	if rc == sqlite.DONE {return cursor, sqlite.OK}
	if rc != sqlite.ROW {return cursor, rc}
	cursor.offset = sqlite.column_int64(stmt, 0)
	return cursor, sqlite.OK
}

// Caller must apply events and save their cursor in this same transaction.
// Never commits or rolls back; filesystem appends are not protected by SQLite.
save_cursor :: proc(tx: ^sqlite.Tx, cursor: Cursor) -> c.int {
	if cursor.offset < 0 || sqlite.get_autocommit(tx.db) != 0 {return sqlite.MISUSE}
	stmt: ^sqlite.Stmt
	rc := sqlite.prepare_v2(
		tx.db,
		`INSERT INTO replay_cursors (shard, byte_offset) VALUES (?, ?)
		ON CONFLICT(shard) DO UPDATE SET byte_offset = excluded.byte_offset`,
		-1,
		&stmt,
		nil,
	)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return rc}
	if !sqlite.bind_string(stmt, 1, cursor.shard) {return 1} 	// SQLITE_ERROR
	rc = sqlite.bind_int64(stmt, 2, cursor.offset)
	if rc != sqlite.OK {return rc}
	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return rc}
	return sqlite.OK
}

get_current_event_shard :: proc(allocator := context.allocator) -> string {
	year, month, _ := time.date(time.now())
	return fmt.aprintf("%04d-%02d.ndjson", year, int(month), allocator = allocator)
}
