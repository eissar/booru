package server

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../http"
import "../library"

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
	root, err := os.make_directory_temp("", "booru-image-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	source, read_err := os.read_entire_file(
		"test/fixture/library/images/1.png",
		context.temp_allocator,
	)
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
		library_path   = root,
		library_images = images[:],
	}
	res := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res.headers)
	handle_image(state, &res, http.Header{path = "/image/" + oid})
	testing.expect(t, res.status == .OK)
	testing.expect(t, res.headers["Content-Type"] == "image/png")
	testing.expect(t, bytes.equal(res.body, source), "serve ID-named original")
	for path in ([]string{"/image/deadbeef", "/image/../1.png"}) {
		handle_image(state, &res, http.Header{path = path})
		testing.expect(t, res.status == .NotFound)
	}
}

@(test)
mipmap_returns_contiguous_webp :: proc(t: ^testing.T) {
	oid :: "4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6"
	images := [1]library.Image{{id = 1, oid = oid}}
	s := library.State {
		library_path   = "test/fixture/library",
		library_images = images[:],
	}
	source, err := os.read_entire_file(
		"test/fixture/library/thumbnails/" + oid + ".webp",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil, "read thumbnail fixture") {return}
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
}

@(test)
mipmap_rejects_invalid_requests :: proc(t: ^testing.T) {
	for path in ([]string{"/mipmap/3", "/mipmap/64"}) {
		res := http.Response {
			headers = make(map[string]string),
		}
		handle_mipmap(
			library.State{},
			&res,
			http.Req{{path = path}, context.temp_allocator, time.now()},
		)
		testing.expect(
			t,
			res.status == .BadRequest,
			"invalid resolution or empty body returns 400",
		)
		testing.expect(t, len(res.body) == 0, "rejected request has an empty body")
		delete(res.headers)
	}
}
