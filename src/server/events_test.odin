package server

import elog "../event_log"
import "../http"
import "../library"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
events_resume :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-events-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	os.mkdir_all(fmt.tprintf("%s/events", root), os.Permissions_Default_Directory)
	_ = os.write_entire_file(
		fmt.tprintf("%s/events/2025-01.ndjson", root),
		"{\"id\":1}\n{\"id\":2}\n",
	)
	_ = os.write_entire_file(
		fmt.tprintf("%s/events/2025-02.ndjson", root),
		"{\"id\":3}\n{\"id\":4}\n",
	)

	cursor: elog.Cursor
	copy(cursor.shard[:], "2025-02.ndjson")
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		event_log = &log,
	}
	token := base64.encode(
		transmute([]u8)string("2025-01.ndjson:9"),
		base64.ENC_URL_TABLE,
		allocator = alloc,
		options = {.No_Padding},
	)
	out: strings.Builder
	strings.builder_init(&out, alloc)
	// Resuming returned cursors must deliver each event exactly once, even
	// across shards, an advancing append boundary, and a caught-up request.
	for offset in ([]i64{9, 18, 18}) {
		cursor.offset = offset
		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		handle_events(
			s,
			&res,
			{{method = "GET", query = fmt.tprintf("after=%s", token)}, alloc, {}},
		)
		if !testing.expect(t, res.status == .OK) {return}
		strings.write_bytes(&out, res.body)
		token = res.headers["X-Booru-Event-Cursor"]
	}
	testing.expect_value(t, strings.to_string(out), "{\"id\":2}\n{\"id\":3}\n{\"id\":4}\n")
}
