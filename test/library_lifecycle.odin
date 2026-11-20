package test

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"

import elog "../src/event_log"
import "../src/importers"
import "../src/library"
import "../src/replay"
import "../src/server"
import "../src/store"
import "../src/vendor/sqlite"

// Exercise real HTTP reads/deletes/merges, then rebuild from the on-disk event log.
@(test)
import_browse_delete_merge_replay :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, err := os.make_directory_temp("", "booru-lifecycle-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}

	ids: [3]int
	images: []library.Image
	{
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

		fixture :: "test/fixture/eagle/fixture.library/images"
		fd, open_err := os.open(fixture, {.Read}, os.Permissions_Default)
		if !testing.expect(t, open_err == nil) {return}
		defer os.close(fd)
		result := importers.eagle_import(fixture, &state, fd)
		if !testing.expect(
			t,
			result.success == 3 && result.missing == 1 && result.read_errors == 0,
		) {
			return
		}
		read, rc := store.read_images(state.data_store, context.temp_allocator)
		if !testing.expect(t, rc == sqlite.OK && len(read) == 3) {return}
		images = read
		for image, i in images {ids[i] = image.id}

		sock, listen_err := net.listen_tcp(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 0})
		if !testing.expect(t, listen_err == nil) {return}
		defer net.close(sock)
		endpoint, endpoint_err := net.bound_endpoint(sock)
		if !testing.expect(t, endpoint_err == nil) {return}
		data := struct {
			sock:  net.TCP_Socket,
			state: ^library.State,
		}{sock, &state}
		worker := thread.create_and_start_with_data(&data, proc(raw: rawptr) {
			defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
			data := cast(^struct {
				sock:  net.TCP_Socket,
				state: ^library.State,
			})raw
			server.Serve(data.state, data.sock)
		})
		defer {
			// Close before joining to wake accept on Windows.
			_ = net.shutdown(sock, .Both)
			net.close(sock)
			sock = {}
			thread.join(worker)
			thread.destroy(worker)
		}

		base := fmt.tprintf("http://127.0.0.1:%d", endpoint.port)
		gallery, ok := test_http(t, "GET", fmt.tprintf("%s/gallery", base), "", 200)
		if !ok {return}
		for id in ids {
			testing.expect(t, strings.contains(gallery, fmt.tprintf("data-image-id=\"%d\"", id)))
		}
		_, image_ok := test_http(
			t,
			"GET",
			fmt.tprintf("%s/image/%s", base, images[0].oid),
			"",
			200,
		)
		if !image_ok {return}

		_, deleted := test_http(
			t,
			"POST",
			fmt.tprintf("%s/delete", base),
			fmt.tprintf("id=%d", ids[0]),
			200,
		)
		if !deleted {return}
		gallery, ok = test_http(t, "GET", fmt.tprintf("%s/gallery", base), "", 200)
		if !ok {return}
		testing.expect(t, !strings.contains(gallery, fmt.tprintf("data-image-id=\"%d\"", ids[0])))
		for id in ids[1:] {
			testing.expect(t, strings.contains(gallery, fmt.tprintf("data-image-id=\"%d\"", id)))
		}
		_, _ = test_http(
			t,
			"GET",
			fmt.tprintf("%s/fragment/inspect/%d?order=0", base, ids[0]),
			"",
			404,
		)
		_, file_err := os.stat(
			fmt.tprintf("%s/images/%d.%s", root, ids[0], images[0].ext),
			context.temp_allocator,
		)
		testing.expect(t, file_err == .Not_Exist, "deleted original is removed")

		// Rejected merges write nothing; the final replay below would show it.
		merge_rejects := [?]struct {
			body:   string,
			status: int,
		} {
			{fmt.tprintf("into=%d", ids[1]), 400},
			{fmt.tprintf("into=%d&from=%d", ids[1], ids[1]), 400},
			{fmt.tprintf("into=%d&from=%d,%d", ids[1], ids[2], ids[2]), 400},
			{fmt.tprintf("into=%d&from=%d,x", ids[1], ids[2]), 400},
			{fmt.tprintf("into=%d&from=%d,%d", ids[1], ids[2], ids[0]), 404},
			{fmt.tprintf("into=%d&from=%d", ids[0], ids[2]), 404},
		}
		for tc in merge_rejects {
			_, _ = test_http(t, "POST", fmt.tprintf("%s/merge", base), tc.body, tc.status)
		}
		// Client-sent field values are ignored; the merge comes from current state.
		_, merged := test_http(
			t,
			"POST",
			fmt.tprintf("%s/merge", base),
			fmt.tprintf("into=%d&from=%d&name=bogus&tags=bogus&comment=bogus", ids[1], ids[2]),
			200,
		)
		if !merged {return}
		gallery, ok = test_http(t, "GET", fmt.tprintf("%s/gallery", base), "", 200)
		if !ok {return}
		testing.expect(t, !strings.contains(gallery, fmt.tprintf("data-image-id=\"%d\"", ids[2])))
		testing.expect(t, strings.contains(gallery, fmt.tprintf("data-image-id=\"%d\"", ids[1])))
		_, file_err = os.stat(
			fmt.tprintf("%s/images/%d.%s", root, ids[2], images[2].ext),
			context.temp_allocator,
		)
		testing.expect(t, file_err == .Not_Exist, "merged source original is removed")
		_, _ = test_http(
			t,
			"POST",
			fmt.tprintf("%s/merge", base),
			fmt.tprintf("into=%d&from=%d", ids[1], ids[2]),
			404,
		)
	}

	// The server and its SQLite connection are now closed. Rebuild from disk,
	// not the previous database: a missing delete event would resurrect the item.
	restarted := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&restarted, ":memory:") == sqlite.OK) {
		return
	}
	defer store.Close(&restarted)
	replay.initiate_replay(&restarted)
	remaining, rc := store.read_images(restarted.data_store, context.temp_allocator)
	if !testing.expect(
		t,
		rc == sqlite.OK && len(remaining) == 1 && remaining[0].id == ids[1],
		"only the merge target survives replay",
	) {return}
	keep, from := images[1], images[2]
	want_tags := slice.clone_to_dynamic(keep.tags, context.temp_allocator)
	for tag in from.tags {
		if !slice.contains(want_tags[:], tag) {append(&want_tags, tag)}
	}
	slice.sort(want_tags[:])
	got := remaining[0]
	testing.expect(t, slice.equal(got.tags, want_tags[:]), "merged tags are unioned")
	testing.expect(t, got.name == keep.name, "merge target name wins")
	testing.expect(t, strings.has_prefix(got.comment, keep.comment), "target comment is kept")
	testing.expect(
		t,
		strings.contains(got.comment, fmt.tprintf("merged #%d name=%q", from.id, from.name)),
		"source name is noted in the comment",
	)
	testing.expect(t, strings.contains(got.comment, from.comment), "source comment is merged")
}
