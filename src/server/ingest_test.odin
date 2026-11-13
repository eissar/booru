package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../http"
import "../library"
import "../store"
import "../vendor/sqlite"

import elog "../event_log"

@(test)
ingest_inserts_epoch_ms_row_immediately :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer {
		err := free_all(context.temp_allocator)
		assert(err == nil)
	}

	root, temp_err := os.make_directory_temp("", "booru-ingest-*", alloc)
	if !testing.expect(t, temp_err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}

	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	state := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)

	png := []u8{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4}
	boundary :: "testboundary"
	body := make([dynamic]u8, alloc)
	head :=
		"--" +
		boundary +
		"\r\nContent-Disposition: form-data; name=\"image\"; filename=\"pic.png\"\r\n\r\n"
	append(&body, ..transmute([]u8)head)
	append(&body, ..png)
	tail := "\r\n--" + boundary + "--\r\n"
	append(&body, ..transmute([]u8)tail)

	headers := make(map[string]string, alloc)
	headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
	res := http.Response {
		headers = make(map[string]string, alloc),
	}
	before := time.to_unix_nanoseconds(time.now()) / 1_000_000
	handle_ingest(
		&state,
		&res,
		{{method = "POST", headers = headers}, alloc, time.Time{}},
		body[:],
	)
	after := time.to_unix_nanoseconds(time.now()) / 1_000_000
	testing.expect(t, res.status == .Created)

	items, rc := store.read_images(state.data_store, alloc)
	if !testing.expect(t, rc == sqlite.OK && len(items) == 1) {return}
	item := items[0]
	testing.expect(t, item.added_at >= before && item.added_at <= after && item.added_at > 0)
	testing.expect(t, item.mtime == 0)
	testing.expect(t, item.name == "pic" && item.ext == "png")

	shard := elog.get_current_event_shard(alloc)
	data, read_err := os.read_entire_file(fmt.tprintf("%s/events/%s", root, shard), alloc)
	if !testing.expect(t, read_err == nil) {return}
	line := string(data)
	testing.expect(t, strings.contains(line, fmt.tprintf("\"id\":%d", item.id)))
	testing.expect(t, strings.contains(line, fmt.tprintf("\"added_at\":%d", item.added_at)))
	testing.expect(t, strings.contains(line, "\"mtime\":0"))
}

@(test)
ingest_records_video_dimensions :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)

	root, temp_err := os.make_directory_temp("", "booru-ingest-*", alloc)
	if !testing.expect(t, temp_err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}

	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	state := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)

	video, read_err := os.read_entire_file("test/fixture/media/thumbnail.mp4", alloc)
	if !testing.expect(t, read_err == nil, "read mp4 fixture") {return}
	boundary :: "testboundary"
	body := make([dynamic]u8, alloc)
	head :=
		"--" +
		boundary +
		"\r\nContent-Disposition: form-data; name=\"image\"; filename=\"clip.mp4\"\r\n\r\n"
	append(&body, ..transmute([]u8)head)
	append(&body, ..video)
	tail := "\r\n--" + boundary + "--\r\n"
	append(&body, ..transmute([]u8)tail)

	headers := make(map[string]string, alloc)
	headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
	res := http.Response {
		headers = make(map[string]string, alloc),
	}
	handle_ingest(
		&state,
		&res,
		{{method = "POST", headers = headers}, alloc, time.Time{}},
		body[:],
	)
	if !testing.expect(t, res.status == .Created) {return}

	items, rc := store.read_images(state.data_store, alloc)
	if !testing.expect(t, rc == sqlite.OK && len(items) == 1) {return}
	testing.expectf(
		t,
		items[0].width == 192 && items[0].height == 128,
		"video dimensions %dx%d",
		items[0].width,
		items[0].height,
	)
}
