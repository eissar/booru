package handlers_bench

// Handler-only throughput: each iteration calls the handler in-process with a
// fresh request arena (as server.Serve does) and no socket I/O, so TCP,
// header parsing, and response marshaling are not measured.
// Run from the repo root; the fixture is copied to .test-data/ first.
//   odin test bench/handlers -out:bin/bench-handlers -o:speed

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "../../src/http"
import "../../src/library"
import "../../src/replay"
import "../../src/server"
import "../../src/store"
import "../../src/vendor/sqlite"

FIXTURE :: "test/fixture/library"
LIBRARY :: ".test-data/handlers-bench-library"

ROUNDS :: 5
ROUND_DURATION :: 400 * time.Millisecond

Case :: struct {
	name:   string,
	path:   string,
	query:  string,
	status: http.STATUS,
	run:    proc(s: ^library.State, res: ^http.Response, req: http.Req),
}

@(test)
bench_handlers :: proc(t: ^testing.T) {
	os.remove_all(LIBRARY)
	if err := os.make_directory_all(".test-data"); err != nil && err != .Exist {
		testing.expectf(t, false, "mkdir .test-data: %v", err)
		return
	}
	if !testing.expect(t, os.copy_directory_all(LIBRARY, FIXTURE) == nil, "copy fixture") {return}
	// Force the original-file fallback in handle_image for item 3.
	oid3 := "9c2efc8f0c7cde25eb24ee5a589b919731e6a125793c05de070910d6ac2a5f8c"
	if !testing.expect(
		t,
		os.remove(fmt.tprintf("%s/thumbnails/%s.webp", LIBRARY, oid3)) == nil,
	) {return}

	state := library.State {
		library_path = LIBRARY,
	}
	if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
	defer store.Close(&state)
	replay.initiate_replay(&state)

	fixture_images, read_rc := store.read_images(state.data_store, context.temp_allocator)
	if !testing.expect(t, read_rc == sqlite.OK, "read fixture items") {return}
	defer free_all(context.temp_allocator)

	cases := [?]Case {
		{
			"gallery",
			"/gallery",
			"",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_gallery(s^, res, req)
			},
		},
		{
			"fragment/gallery-content",
			"/fragment/gallery-content",
			"",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_fragment_gallery_content(s^, res, req)
			},
		},
		{
			"fragment/items",
			"/fragment/items",
			"",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_fragment_items(s^, res, req)
			},
		},
		{
			"fragment/items (tag filter)",
			"/fragment/items",
			"tags=synthetic&sort=addedAtAsc",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_fragment_items(s^, res, req)
			},
		},
		{
			"fragment/inspect/1",
			"/fragment/inspect/1",
			"order=0",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_fragment_inspect(s^, res, req)
			},
		},
		{
			"image (thumbnail)",
			"/image/4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6",
			"",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_image(s^, res, req)
			},
		},
		{
			"image (original fallback)",
			"/image/9c2efc8f0c7cde25eb24ee5a589b919731e6a125793c05de070910d6ac2a5f8c",
			"",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_image(s^, res, req)
			},
		},
		{
			// Batch OID lookup in one query, including duplicate/out-of-order IDs.
			"mipmap (batch 64)",
			"/mipmap/64",
			"ids=1,2,3,1,2,3,1",
			.OK,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_mipmap(s^, res, req)
			},
		},
		{
			"regen-thumbnail (stub, 501)",
			"/regen-thumbnail",
			"id=1&order=0",
			.NotImplemented,
			proc(s: ^library.State, res: ^http.Response, req: http.Req) {
				server.handle_regen_thumbnail(s, res, req)
			},
		},
	}

	req_backing := make([]u8, 4 * mem.Megabyte)
	defer delete(req_backing)
	req_arena: mem.Arena
	mem.arena_init(&req_arena, req_backing)
	req_alloc := mem.arena_allocator(&req_arena)

	fmt.printf("bench=handlers fixture_items=%d library=%q\n", len(fixture_images), LIBRARY)
	for c in cases {
		one :: proc(
			c: Case,
			s: ^library.State,
			alloc: mem.Allocator,
		) -> (
			status: http.STATUS,
			body_len: int,
		) {
			res := http.Response {
				headers = make(map[string]string, alloc),
			}
			req := http.Req {
				header = {
					path = c.path,
					query = c.query,
					headers = make(map[string]string, alloc),
				},
				alloc = alloc,
				rec_time = time.now(),
			}
			c.run(s, &res, req)
			return res.status, len(res.body)
		}

		free_all(req_alloc)
		status, body_len := one(c, &state, req_alloc)
		if !testing.expectf(
			t,
			status == c.status,
			"%s: status %v, want %v",
			c.name,
			status,
			c.status,
		) {
			continue
		}

		for _ in 0 ..< 200 {
			free_all(req_alloc)
			one(c, &state, req_alloc)
		}

		rates: [ROUNDS]f64
		per_op_us: [ROUNDS]f64
		for round in 0 ..< ROUNDS {
			n := 0
			start := time.now()
			for time.since(start) < ROUND_DURATION {
				free_all(req_alloc)
				one(c, &state, req_alloc)
				n += 1
			}
			elapsed := time.duration_seconds(time.since(start))
			rates[round] = f64(n) / elapsed
			per_op_us[round] = elapsed * 1e6 / f64(n)
		}
		slice.sort(rates[:])
		slice.sort(per_op_us[:])
		fmt.printf(
			"bench=handlers case=%q req_per_sec=%.0f median_us=%.1f best_req_per_sec=%.0f worst_req_per_sec=%.0f body_bytes=%d\n",
			c.name,
			rates[ROUNDS / 2],
			per_op_us[ROUNDS / 2],
			rates[ROUNDS - 1],
			rates[0],
			body_len,
		)
	}
}
