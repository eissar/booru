package server

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../http"
import "../library"
import "../store"
import "../thumbnail"
import "../vendor/sqlite"

// Capture the streaming encoder solely for body assertions in unit tests.
materialize_mipmap_for_test :: proc(t: ^testing.T, res: ^http.Response) {
	if !testing.expect(t, res.body_stream != nil, "handler produces a streaming response") {return}
	data := cast(^Mipmap_Stream)res.body_stream_data
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, res.body_stream_length, context.temp_allocator)
	defer bytes.buffer_destroy(&buffer)
	err := thumbnail.Write_Webp_X(
		data.files,
		&data.prefix,
		io.to_writer(bytes.buffer_to_stream(&buffer)),
	)
	if !testing.expect(t, err == nil) {return}
	output := bytes.buffer_to_bytes(&buffer)
	testing.expect(t, len(output) == res.body_stream_length, "stream length matches headers")
	res.body = make([]u8, len(output), context.temp_allocator)
	copy(res.body, output)
	res.body_stream = nil
}

@(test)
sorting_filtered_images_preserves_library_order :: proc(t: ^testing.T) {
	images := [?]library.Image{{id = 2, tags = {"match"}}, {id = 1, tags = {"match"}}}
	for tags in ([]([]string){nil, {"match"}}) {
		filtered := filter_images(images[:], tags)
		sort_gallery(filtered, "idAsc")
		testing.expect(t, filtered[0].id == 1 && filtered[1].id == 2)
		testing.expect(t, images[0].id == 2 && images[1].id == 1, "source order remains unchanged")
		delete(filtered)
	}
}

@(test)
image_falls_back_to_id_named_original :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer {
		err := free_all(context.temp_allocator)
		assert(err == nil)
	}

	root, err := os.make_directory_temp("", "booru-image-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)

	source, read_err := os.read_entire_file("test/fixture/library/images/1.png", alloc)
	if !testing.expect(t, read_err == nil) {return}
	if !testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/images", root), os.Permissions_Default_Directory) == nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/images/1.png", root), source) == nil,
	) {return}
	oid :: "4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6"
	images := [?]library.Image{{id = 1, oid = oid, content_type = "image/png"}}
	state := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)
	for img in images {
		if !testing.expect(t, store.insert_into_items(state.data_store, img) == sqlite.OK) {return}
	}
	res := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res.headers)

	handle_image(state, &res, {{path = "/image/" + oid}, alloc, time.Time{}})
	testing.expect(t, res.status == .OK)
	testing.expect(t, res.headers["Content-Type"] == "image/png")
	testing.expect(t, bytes.equal(res.body, source), "serve ID-named original")
	for path in ([]string{"/image/deadbeef", "/image/../1.png"}) {
		handle_image(state, &res, {{path = path}, alloc, time.Time{}})
		testing.expect(t, res.status == .NotFound)
	}

}

@(test)
mipmap_returns_contiguous_webp :: proc(t: ^testing.T) {
	oid :: "4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6"
	images := [2]library.Image{{id = 1, oid = oid}, {id = 3, oid = "missing-file"}}
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
		if !testing.expect(t, store.insert_into_items(s.data_store, img) == sqlite.OK) {return}
	}
	source, err := os.read_entire_file(
		"test/fixture/library/thumbnails/" + oid + ".webp",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil, "read thumbnail fixture") {return}
	if !testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/thumbnails/64", root), os.Permissions_Default_Directory) ==
		nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/thumbnails/64/%s.webp", root, oid), source) == nil,
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

	// Unknown IDs and an existing ID with no thumbnail must each retain a slot.
	handle_mipmap(
		s,
		&res,
		http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
		transmute([]u8)string("2,1,3,4"),
	)
	materialize_mipmap_for_test(t, &res)
	testing.expect(t, res.status == .OK, "missing thumbnails do not crash the batch")
	testing.expect(
		t,
		strings.count(string(res.body), "ANMF") == 4,
		"each requested ID retains a frame, including missing thumbnails",
	)
	testing.expect(t, bytes.contains(res.body, source[12:]), "batch retains the valid thumbnail")

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
			{path = "/mipmap/64", query = "ids=2%2C1,3,4"},
			context.temp_allocator,
			time.now(),
		},
	)
	materialize_mipmap_for_test(t, &get_res)
	testing.expect(t, get_res.status == .OK, "GET with ids returns 200")
	testing.expect(t, bytes.equal(get_res.body, post_body), "GET body matches POST body")
}
