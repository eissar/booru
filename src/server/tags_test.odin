package server

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import elog "../event_log"
import "../http"
import "../library"
import "../replay"
import "../store"
import "../vendor/sqlite"

@(test)
metadata_edits_write_membership_deltas :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-tag-edits-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, library.init_new_library(root) == nil) {return}
	cursor: elog.Cursor
	defer delete(cursor.shard)
	log := elog.EventLog {
		root      = root,
		cursor    = &cursor,
		allocator = context.allocator,
	}
	s := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
	defer store.Close(&s)
	initial := elog.Event {
		id       = 1,
		op       = "add",
		name     = "original",
		tags_xor = {"fox", "night"},
	}
	if !testing.expect(t, elog.ev_append(&log, []elog.Event{initial}) == "") {return}
	replay.initiate_replay(&s)
	path := fmt.tprintf("%s/events/%s", root, cursor.shard)

	cases := [?]struct {
		body:        string,
		tags, delta: []string,
		name:        string,
		writes:      bool,
		status:      http.STATUS,
	} {
		{"id=1&tags=fox,day", {"day", "fox"}, {"night", "day"}, "original", true, .OK},
		// Repeating the request must not flip anything again.
		{"id=1&tags=day,fox", {"day", "fox"}, nil, "original", false, .OK},
		{"id=1&tags=FOX,day,fox", {"day", "fox"}, nil, "original", false, .OK},
		// Missing tags preserve membership, including in a combined metadata edit.
		{"id=1&name=renamed", {"day", "fox"}, nil, "renamed", true, .OK},
		{"id=1&name=renamed&tags=fox,day", {"day", "fox"}, nil, "renamed", false, .OK},
		{"id=1&name=combined&tags=fox", {"fox"}, {"day"}, "combined", true, .OK},
		{"id=1&tags=", nil, {"fox"}, "combined", true, .OK},
		{"id=1&tags=", nil, nil, "combined", false, .OK},
		{"id=1&tags=night", {"night"}, {"night"}, "combined", true, .OK},
		{"id=1&tags=night!", {"night"}, nil, "combined", false, .BadRequest},
		{
			fmt.tprintf("id=1&tags=%s", strings.repeat("a", elog.MAX_RECORD, alloc)),
			{"night"},
			nil,
			"combined",
			false,
			.BadRequest,
		},
	}
	for tc in cases {
		before := cursor.offset
		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		req := http.Req{{method = "POST", headers = make(map[string]string, alloc)}, alloc, {}}
		handle_update_metadata(&s, &res, req, transmute([]u8)tc.body)
		if !testing.expectf(
			t,
			res.status == tc.status,
			"request %q status %v",
			tc.body,
			res.status,
		) {return}
		testing.expect(t, (cursor.offset > before) == tc.writes, "only changed valid edits append")
		img, found, rc := store.read_image_by_id(s.data_store, 1, alloc)
		if !testing.expect(t, rc == sqlite.OK && found) {return}
		testing.expect(t, slice.equal(img.tags, tc.tags), "desired membership applied")
		testing.expect(t, img.name == tc.name)

		data, read_err := os.read_entire_file(path, alloc)
		if !testing.expect(t, read_err == nil) {return}
		if tc.writes {
			record := string(data[before:])
			testing.expect(
				t,
				strings.count(record, "\n") == 1,
				"one inspector update is one event",
			)
			ev: elog.Event
			if !testing.expect(
				t,
				json.unmarshal(
					transmute([]u8)strings.trim_space(record),
					&ev,
					allocator = alloc,
				) ==
				nil,
			) {return}
			testing.expect(t, ev.op == "patch" && ev.id == 1)
			testing.expect(t, slice.equal(ev.tags_xor, tc.delta), "only changed keys are logged")
			if len(tc.delta) == 0 {
				testing.expect(
					t,
					!strings.contains(record, "\"tags_xor\""),
					"unchanged membership has no delta field",
				)
			}
		}
		// Rebuild from the complete log after every request, including rejected/no-op requests.
		rebuilt := library.State{}
		if !testing.expect(t, store.Init(&rebuilt, ":memory:") == sqlite.OK) {return}
		text := string(data)
		testing.expect(t, replay.replay(&rebuilt, &text, alloc) == nil)
		other, exists, read_rc := store.read_image_by_id(rebuilt.data_store, 1, alloc)
		testing.expect(t, read_rc == sqlite.OK && exists)
		testing.expect(
			t,
			slice.equal(img.tags, other.tags) && img.name == other.name,
			"live and rebuilt state agree",
		)
		store.Close(&rebuilt)
	}
}
