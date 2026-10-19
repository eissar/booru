package server

import "core:testing"
import "core:time"

import "../http"
import "../library"
import "../store"
import "../vendor/sqlite"

@(test)
mipmap_rejects_malformed_ids :: proc(t: ^testing.T) {
	s: library.State
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)

	for body in ([]string{"invalid", "1,invalid"}) {
		res := http.Response {
			headers = make(map[string]string),
		}
		handle_mipmap(
			s,
			&res,
			http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
			transmute([]u8)body,
		)
		testing.expect(t, res.status == .BadRequest, "malformed IDs return 400")
		testing.expect(t, len(res.body) == 0, "rejected request has an empty body")
		delete(res.headers)
	}

	res := http.Response {
		headers = make(map[string]string),
	}
	defer delete(res.headers)
	handle_mipmap(
		s,
		&res,
		http.Req{{path = "/mipmap/64"}, context.temp_allocator, time.now()},
		transmute([]u8)string(","),
	)
	testing.expect(t, res.status == .NotFound, "no IDs returns 404")
}
