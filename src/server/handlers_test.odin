package server

import "core:bytes"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../http"
import "../library"

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
