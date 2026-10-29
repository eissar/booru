package event_log

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:io"
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
	root:   string,
	db:     ^sqlite.DB,
	cursor: ^Cursor,
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


// Preserve JSON syntax and existing escapes; encode only raw non-ASCII runes.
@(private)
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

// Writes one newline-terminated record to w. Does not flush or sync.
write_event :: proc(w: io.Writer, e: any, loc := #caller_location) -> (err: string) {
	opt := json.Marshal_Options {
		spec   = .JSON,
		pretty = false,
	}
	data, marshal_err := json.marshal(e, opt, context.allocator, loc)
	if marshal_err != nil {return "could not marshal event"}
	defer delete(data, context.allocator, loc)

	ascii: strings.Builder
	strings.builder_init(&ascii, context.allocator, loc)
	defer strings.builder_destroy(&ascii)
	encode_ascii_json(data, &ascii)

	payload := transmute([]u8)strings.to_string(ascii)
	if len(payload) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD", loc)}
	written, write_err := io.write(w, payload, nil)
	if write_err != nil || written != len(payload) {return "could not write event payload"}
	if io.write_byte(w, '\n', nil) != nil {return "could not write event newline"}
	return ""
}

EventRemediation :: struct {
	using _:        Event,
	REMEDIATE_tags: []string `json:"REMEDIATE_tags,omitempty"`,
}

is_allowed_tag_char :: proc(c: rune) -> bool {
	return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || c == '-'
}
