package server

import "core:c"

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import elog "../event_log"
import "../http"
import "../library"
import "../replay"
import "../store"
import "../thumbnail"
import "../thumbnail/webpx"
import "../vendor/sqlite"

// Capture the streaming encoder solely for body assertions in unit tests.
materialize_mipmap_for_test :: proc(t: ^testing.T, res: ^http.Response) {
	if !testing.expect(t, res.body_stream != nil, "handler produces a streaming response") {return}
	data := cast(^Mipmap_Stream)res.body_stream_data
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, res.body_stream_length, context.temp_allocator)
	defer bytes.buffer_destroy(&buffer)
	err := webpx.Encode(data.files, &data.prefix, io.to_writer(bytes.buffer_to_stream(&buffer)))
	if !testing.expect(t, err == nil) {return}
	output := bytes.buffer_to_bytes(&buffer)
	testing.expect(t, len(output) == res.body_stream_length, "stream length matches headers")
	res.body = make([]u8, len(output), context.temp_allocator)
	copy(res.body, output)
	res.body_stream = nil
}

@(test)
mipmap_returns_contiguous_webp :: proc(t: ^testing.T) {
	oid :: "4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6"
	oid5 :: "9c2efc8f0c7cde25eb24ee5a589b919731e6a125793c05de070910d6ac2a5f8c"
	images := [3]library.Image {
		{id = 1, oid = oid},
		{id = 3, oid = "missing-file"},
		{id = 5, oid = oid5},
	}
	root, temp_err := os.make_directory_temp("", "booru-mipmap-*", context.allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	s := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	for img in images {
		if !testing.expect(
			t,
			sqlite.with_transaction(
				s.data_store,
				img,
				proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
					return c.int(store.insert_item(tx, item))
				},
			) ==
			sqlite.OK,
		) {return}
	}
	source, err := os.read_entire_file(
		"test/fixture/library/thumbnails/" + oid + ".webp",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil, "read thumbnail fixture") {return}
	source5, err5 := os.read_entire_file(
		"test/fixture/library/thumbnails/" + oid5 + ".webp",
		context.temp_allocator,
	)
	if !testing.expect(t, err5 == nil, "read second thumbnail fixture") {return}
	if !testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/thumbnails/64", root), os.Permissions_Default_Directory) ==
		nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/thumbnails/64/%s.webp", root, oid), source) == nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/thumbnails/64/%s.webp", root, oid5), source5) == nil,
	) {return}
	res := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res.headers)
	handle_mipmap(
		s,
		&res,
		http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
		transmute([]u8)string("1"),
	)
	materialize_mipmap_for_test(t, &res)
	testing.expect(t, res.status == .OK, "mipmap returns 200")
	testing.expect(t, res.headers["Content-Type"] == "image/webp", "mipmap sets WebP content type")
	testing.expect(t, len(res.body) > 12, "mipmap contains a WebP body")
	if len(res.body) > 12 {
		testing.expect(t, string(res.body[:4]) == "RIFF", "body starts with RIFF")
		testing.expect(t, string(res.body[8:12]) == "WEBP", "body identifies WebP")
	}
	testing.expect(
		t,
		bytes.contains(res.body, source[12:]),
		"contiguous body includes thumbnail chunks",
	)
	wire := http.marshal(res, context.temp_allocator)
	testing.expect(
		t,
		strings.has_suffix(wire, string(res.body)),
		"serialized response includes the complete body",
	)

	// Out-of-order IDs, unknown IDs, and an existing ID with no thumbnail on disk
	// must each retain a slot in request order.
	handle_mipmap(
		s,
		&res,
		http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
		transmute([]u8)string("5,2,1,3,4"),
	)
	materialize_mipmap_for_test(t, &res)
	testing.expect(t, res.status == .OK, "missing thumbnails do not crash the batch")
	testing.expect(
		t,
		strings.count(string(res.body), "ANMF") == 5,
		"each requested ID retains a frame, including missing thumbnails",
	)
	pos5 := bytes.index(res.body, source5[12:])
	pos1 := bytes.index(res.body, source[12:])
	testing.expect(
		t,
		pos5 >= 0 && pos1 > pos5,
		"frames preserve out-of-order request order (5 before 1)",
	)

	// GET with ?ids= returns the same batch as the POST body.
	post_body := res.body
	get_res := http.Response {
		headers = make(map[string]string),
	}
	defer delete(get_res.headers)
	handle_mipmap(
		s,
		&get_res,
		http.Req {
			{path = "/mipmap/64", query = "ids=5,2%2C1,3,4"},
			context.temp_allocator,
			time.now(),
		},
	)
	materialize_mipmap_for_test(t, &get_res)
	testing.expect(t, get_res.status == .OK, "GET with ids returns 200")
	testing.expect(t, bytes.equal(get_res.body, post_body), "GET body matches POST body")

	// Duplicate IDs keep a frame per requested slot.
	handle_mipmap(
		s,
		&res,
		http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
		transmute([]u8)string("1,1,3"),
	)
	materialize_mipmap_for_test(t, &res)
	testing.expect(t, res.status == .OK, "duplicate IDs do not crash the batch")
	testing.expect(
		t,
		strings.count(string(res.body), "ANMF") == 3,
		"each duplicate requested ID retains its own frame",
	)
	testing.expect(
		t,
		bytes.count(res.body, source[12:]) == 2,
		"duplicate ID emits its thumbnail frame twice",
	)
}

@(test)
gallery_until_id_snapshot_isolation :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer {
		err := free_all(context.temp_allocator)
		assert(err == nil)
	}

	state := library.State{}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)

	// Insert initial items (id 1, 2)
	initial_items := [2]library.Image {
		{id = 1, oid = "o1", name = "item 1", added_at = 100},
		{id = 2, oid = "o2", name = "item 2", added_at = 200},
	}
	for item in initial_items {
		if !testing.expect(
			t,
			sqlite.with_transaction(
				state.data_store,
				item,
				proc(tx: ^sqlite.Tx, it: library.Image) -> c.int {
					return c.int(store.insert_item(tx, it))
				},
			) ==
			sqlite.OK,
		) {return}
	}

	// 1. Initial visit to /gallery (until_id absent)
	res1 := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res1.headers)
	handle_gallery(state, &res1, {{path = "/gallery", query = "limit=10"}, alloc, time.Time{}})
	testing.expect_value(t, res1.status, http.STATUS.OK)
	html1 := string(res1.body)
	// Server determines max item ID = 2 and reflects it as until_id in markup
	testing.expect(
		t,
		strings.contains(html1, `<input type="hidden" name="until_id" value="2"/>`),
		"initial page contains until_id ceiling 2",
	)

	// Now insert a new item with id > until_id (id = 3)
	item3 := library.Image {
		id       = 3,
		oid      = "o3",
		name     = "item 3",
		added_at = 300,
	}
	if !testing.expect(
		t,
		sqlite.with_transaction(
			state.data_store,
			item3,
			proc(tx: ^sqlite.Tx, it: library.Image) -> c.int {
				return c.int(store.insert_item(tx, it))
			},
		) ==
		sqlite.OK,
	) {return}

	// 2. Paginated request or fragment request retaining until_id=2
	res2 := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res2.headers)
	handle_fragment_items(
		state,
		&res2,
		{{path = "/fragment/items", query = "limit=10&offset=0&until_id=2"}, alloc, time.Time{}},
	)
	testing.expect_value(t, res2.status, http.STATUS.OK)
	html2 := string(res2.body)
	testing.expect(t, strings.contains(html2, `data-image-id="1"`), "contains item 1")
	testing.expect(t, strings.contains(html2, `data-image-id="2"`), "contains item 2")
	testing.expect(t, !strings.contains(html2, `data-image-id="3"`), "excludes new item 3")
	testing.expect(
		t,
		strings.contains(res2.headers["Hx-Push-Url"], "until_id=2"),
		"Hx-Push-Url retains until_id=2",
	)

	// 3. Request without until_id now sees max_id = 3
	res3 := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res3.headers)
	handle_fragment_items(
		state,
		&res3,
		{{path = "/fragment/items", query = "limit=10&offset=0"}, alloc, time.Time{}},
	)
	testing.expect_value(t, res3.status, http.STATUS.OK)
	html3 := string(res3.body)
	testing.expect(
		t,
		strings.contains(html3, `data-image-id="3"`),
		"unconstrained query includes item 3",
	)
}

@(test)
write_handlers_reject_non_post :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)

	state := library.State{}
	{
		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		handle_delete(
			&state,
			&res,
			{{method = "GET", path = "/delete"}, alloc, time.Time{}},
			transmute([]u8)string("id=1"),
		)
		testing.expect_value(t, res.status, http.STATUS.MethodNotAllowed)
		testing.expect_value(t, res.headers["Allow"], "POST")
	}
	{
		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		handle_update_metadata(
			&state,
			&res,
			{{method = "GET", path = "/update-metadata"}, alloc, time.Time{}},
			transmute([]u8)string("id=1&name=x"),
		)
		testing.expect_value(t, res.status, http.STATUS.MethodNotAllowed)
		testing.expect_value(t, res.headers["Allow"], "POST")
	}
}

@(test)
update_metadata_rejects_empty_path_and_appends_nothing :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-update-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	if !testing.expect(
		t,
		elog.ev_append(&log, []elog.Event{{op = "add", id = 1, oid = "a", path = "p"}}) == "",
	) {return}
	replay.initiate_replay(&s)
	before := cursor
	for body in ([]string{"id=1&path=", "id=1&name=x&path=%09"}) {
		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		handle_update_metadata(
			&s,
			&res,
			{{method = "POST", path = "/update-metadata"}, alloc, time.Time{}},
			transmute([]u8)body,
		)
		testing.expectf(t, res.status == .BadRequest, "%s: got %v", body, res.status)
		testing.expectf(t, cursor == before, "%s: appended to the event log", body)
	}
	shard := fmt.tprintf("%s/events/%s", root, string(cursor.shard[:]))
	data, read_err := os.read_entire_file(shard, alloc)
	if !testing.expect(t, read_err == nil) {return}
	testing.expect_value(t, i64(len(data)), before.offset)
	image, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
	testing.expect(t, rc == sqlite.OK && found)
	testing.expect(t, image.oid == "a" && image.path == "p" && image.name == "")
}

@(test)
delete_removes_row_and_rejects_unknown_id :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-delete-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	if !testing.expect(
		t,
		elog.ev_append(
			&log,
			[]elog.Event{{op = "add", id = 1, ext = "png"}, {op = "add", id = 2, ext = "png"}},
		) ==
		"",
	) {return}
	replay.initiate_replay(&s)
	original := fmt.tprintf("%s/images/1.png", root)
	if !testing.expect(t, os.write_entire_file(original, []u8{1}) == nil) {return}
	shard := fmt.tprintf("%s/events/%s", root, string(cursor.shard[:]))

	res := http.Response {
		headers = make(map[string]string, alloc),
	}
	handle_delete(
		&s,
		&res,
		{{method = "POST", path = "/delete"}, alloc, time.Time{}},
		transmute([]u8)string("id=1"),
	)
	testing.expect_value(t, res.status, http.STATUS.OK)
	data, read_err := os.read_entire_file(shard, alloc)
	if !testing.expect(t, read_err == nil) {return}
	lines := strings.split_lines(strings.trim_right(string(data), "\n"), alloc)
	if testing.expect_value(t, len(lines), 3) {
		testing.expect(
			t,
			strings.contains(lines[2], `"id":1,`) && strings.contains(lines[2], `"op":"delete"`),
		)
	}
	_, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
	testing.expect(t, rc == sqlite.OK && !found)
	_, found, rc = store.read_image_by_id(s.data_store, 2, alloc)
	testing.expect(t, rc == sqlite.OK && found)
	testing.expect(t, !os.exists(original))

	// Already-deleted and unknown ids are 404 and leave the log untouched.
	before := cursor
	for body in ([]string{"id=1", "id=99"}) {
		res = http.Response {
			headers = make(map[string]string, alloc),
		}
		handle_delete(
			&s,
			&res,
			{{method = "POST", path = "/delete"}, alloc, time.Time{}},
			transmute([]u8)body,
		)
		testing.expectf(t, res.status == .NotFound, "%s: got %v", body, res.status)
		testing.expectf(t, cursor == before, "%s: appended to the event log", body)
	}
	after, after_err := os.read_entire_file(shard, alloc)
	testing.expect(t, after_err == nil && len(after) == len(data))
}

@(test)
merge_folds_multiple_sources_in_order :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-merge-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	log := elog.EventLog {
		root   = root,
		cursor = &cursor,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	// "shared" is on both sources and absent on into; b's comment repeats a's.
	if !testing.expect(
		t,
		elog.ev_append(
			&log,
			[]elog.Event {
				{op = "add", id = 1, name = "t", comment = "base", tags = {"x"}},
				{
					op = "add",
					id = 2,
					ext = "png",
					name = "a",
					comment = "from a",
					tags = {"shared", "only-a"},
				},
				{
					op = "add",
					id = 3,
					ext = "png",
					name = "b",
					comment = "from a",
					tags = {"shared", "only-b"},
				},
			},
		) ==
		"",
	) {return}
	replay.initiate_replay(&s)
	for id in 2 ..= 3 {
		original := fmt.tprintf("%s/images/%d.png", root, id)
		if !testing.expect(t, os.write_entire_file(original, []u8{1}) == nil) {return}
	}
	shard := fmt.tprintf("%s/events/%s", root, string(cursor.shard[:]))
	before, before_err := os.read_entire_file(shard, alloc)
	if !testing.expect(t, before_err == nil) {return}

	res := http.Response {
		headers = make(map[string]string, alloc),
	}
	handle_merge(
		&s,
		&res,
		{{method = "POST", path = "/merge"}, alloc, time.Time{}},
		transmute([]u8)string("into=1&from=2,3"),
	)
	testing.expect_value(t, res.status, http.STATUS.OK)

	into, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
	if !testing.expect(t, rc == sqlite.OK && found) {return}
	testing.expect_value(t, into.name, "t")
	testing.expect_value(
		t,
		into.comment,
		"base\nmerged #2 name=\"a\"\nfrom a\nmerged #3 name=\"b\"",
	)
	testing.expect(t, slice.equal(into.tags, []string{"only-a", "only-b", "shared", "x"}))
	for id in 2 ..= 3 {
		_, source_found, source_rc := store.read_image_by_id(s.data_store, id, alloc)
		testing.expect(t, source_rc == sqlite.OK && !source_found)
		testing.expect(t, !os.exists(fmt.tprintf("%s/images/%d.png", root, id)))
	}
	after, after_err := os.read_entire_file(shard, alloc)
	if !testing.expect(t, after_err == nil) {return}
	appended := strings.split_lines(strings.trim_right(string(after[len(before):]), "\n"), alloc)
	if testing.expect_value(t, len(appended), 3) {
		ops := [3][2]string {
			{`"id":1,`, `"op":"patch"`},
			{`"id":2,`, `"op":"delete"`},
			{`"id":3,`, `"op":"delete"`},
		}
		for want, i in ops {
			testing.expectf(
				t,
				strings.contains(appended[i], want[0]) && strings.contains(appended[i], want[1]),
				"record %d: %s",
				i,
				appended[i],
			)
		}
	}
}
