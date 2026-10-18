package replay_bench

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import elog "../../src/event_log"
import "../../src/library"
import "../../src/replay"
import "../../src/store"
import "../../src/vendor/sqlite"

Error :: replay.Error

replay_json :: proc(s: ^library.State, data: ^string, alloc: mem.Allocator) -> (err: Error) {
	db := s.data_store

	tx := sqlite.Tx{db}
	rc := sqlite.exec(db, "BEGIN", nil, nil, nil)
	if rc != sqlite.OK {return .DATABASE_ERR}

	// deferred rollback if we return error
	// tested to set named result for defer
	// so we can just do return nil/ return .DATABASE_ERR
	// and it works as you'd expect
	defer {
		if err != nil {
			if sqlite.get_autocommit(db) == 0 {
				sqlite.exec(db, "ROLLBACK", nil, nil, nil)
			}
			sqlite.close(db)
		}
	}

	for line in strings.split_lines_iterator(data) {
		if strings.trim_space(line) == "" {continue}

		ev: elog.Event
		if err := json.unmarshal(transmute([]u8)line, &ev, json.DEFAULT_SPECIFICATION, alloc);
		   err != nil {
			fmt.eprintln("library: bad event ", err)
			continue
		}

		// both 'add' and 'patch'
		// are just Event & op

		// switch
		switch ev.op {
		case "add":
			item := library.Image {
				id           = ev.id,
				oid          = ev.oid,
				path         = ev.path,
				ext          = ev.ext,
				tags         = ev.tags,
				width        = ev.width,
				height       = ev.height,
				name         = ev.name,
				mtime        = ev.mtime,
				added_at     = ev.added_at,
				content_type = ev.content_type,
			}
			rc := store.insert_into_items(&tx, item)
			if rc != sqlite.OK {
				return .DATABASE_ERR
			}
		case "patch":
			item := library.Image {
				id           = ev.id,
				oid          = ev.oid,
				path         = ev.path,
				ext          = ev.ext,
				tags         = ev.tags,
				width        = ev.width,
				height       = ev.height,
				name         = ev.name,
				mtime        = ev.mtime,
				added_at     = ev.added_at,
				content_type = ev.content_type,
			}
			rc := store.patch_item(&tx, item)
			if rc != sqlite.OK {
				return .DATABASE_ERR
			}

		case:
			fmt.eprintfln(
				"unsupported event type=%v . maybe corrupt library. continuing anyway.",
				ev.op,
			)
			continue
		}
	}
	commit_rc := sqlite.exec(db, "COMMIT", nil, nil, nil)
	if commit_rc != 0 {
		return .DATABASE_ERR
	}
	return nil
}

@(test)
test_replay :: proc(t: ^testing.T) {
	benchmark_replay(t, false)
}

@(test)
test_replay_flat_parse :: proc(t: ^testing.T) {
	benchmark_replay(t, true)
}

// Experimental end-to-end comparison: setup and result verification are not timed.
benchmark_replay :: proc(t: ^testing.T, flat: bool) {
	data, read_err := os.read_entire_file(
		"/tmp/booru_eagle_import_test/events/2026-10.ndjson",
		context.allocator,
	)
	if !testing.expect(t, read_err == nil, "read replay benchmark fixture") {return}
	defer delete(data)
	text := string(data)
	count := 0
	for line in strings.split_lines_iterator(&text) {
		if strings.trim_space(line) != "" {count += 1}
	}
	if !testing.expect(t, count > 0) {return}
	text = string(data)

	reference: library.State
	if !testing.expect(t, store.Init(&reference, ":memory:") == sqlite.OK) {return}
	defer store.Close(&reference)
	ref_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&ref_arena)
	defer mem.dynamic_arena_destroy(&ref_arena)
	if !testing.expect(
		t,
		replay_json(&reference, &text, mem.dynamic_arena_allocator(&ref_arena)) == nil,
	) {return}
	expected := replay_benchmark_snapshot(reference.data_store)
	defer delete(expected)

	Run :: struct {
		state:  ^library.State,
		flat:   bool,
		result: Error,
	}
	durations: [11]f64
	events_per_second: [11]f64
	mib_per_second: [11]f64
	for round in 0 ..< len(durations) {
		state: library.State
		if !testing.expect(t, store.Init(&state, ":memory:") == sqlite.OK) {return}
		defer store.Close(&state)
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		run := Run {
			state = &state,
			flat  = flat,
		}
		options := time.Benchmark_Options {
			count = count,
			input = data,
			user_data = &run,
			bench = proc(
				options: ^time.Benchmark_Options,
				alloc: mem.Allocator,
			) -> time.Benchmark_Error {
				run := cast(^Run)options.user_data
				text := string(options.input)
				if run.flat {
					run.result = replay.replay(run.state, &text, alloc)
				} else {
					run.result = replay_json(run.state, &text, alloc)
				}
				options.processed = len(options.input)
				return .Okay
			},
		}
		if !testing.expect(
			t,
			time.benchmark(&options, mem.dynamic_arena_allocator(&arena)) == .Okay,
		) {return}
		if !testing.expect(t, run.result == nil) {return}
		actual := replay_benchmark_snapshot(state.data_store)
		if !testing.expect(t, actual == expected, "identical item metadata and tags") {
			fmt.printf("snapshot lengths: expected=%d actual=%d\n", len(expected), len(actual))
			for i in 0 ..< min(len(expected), len(actual)) {
				if expected[i] != actual[i] {
					fmt.printf(
						"difference at %d: expected=%q actual=%q\n",
						i,
						expected[max(0, i - 40):min(len(expected), i + 100)],
						actual[max(0, i - 40):min(len(actual), i + 100)],
					)
					break
				}
			}
			delete(actual)
			return
		}
		delete(actual)
		durations[round] = f64(time.duration_nanoseconds(options.duration))
		events_per_second[round] = options.rounds_per_second
		mib_per_second[round] = options.megabytes_per_second
	}
	// Discard one warmup, then report the median of ten measured replays.
	slice.sort(durations[1:])
	slice.sort(events_per_second[1:])
	slice.sort(mib_per_second[1:])
	median_ns := (durations[5] + durations[6]) / 2
	label := "json.unmarshal"
	if flat {label = "flat_parser"}
	fmt.printf(
		"%s: %d events, median %.3f ms, %.0f ns/event, %.0f events/s, %.2f MiB/s (10 runs; DB setup excluded; rows/tags verified)\n",
		label,
		count,
		median_ns / 1e6,
		median_ns / f64(count),
		(events_per_second[5] + events_per_second[6]) / 2,
		(mib_per_second[5] + mib_per_second[6]) / 2,
	)
}

replay_benchmark_snapshot :: proc(db: ^sqlite.DB) -> string {
	out: strings.Builder
	strings.builder_init(&out)
	defer strings.builder_destroy(&out)
	queries := [2]cstring {
		"SELECT * FROM items ORDER BY id",
		"SELECT item_id, tag FROM item_tags ORDER BY item_id, tag",
	}
	for query in queries {
		stmt, ok := sqlite.prepare(db, query)
		assert(ok)
		defer sqlite.finalize(stmt)
		for {
			rc := sqlite.step(stmt)
			if rc == sqlite.DONE {break}
			assert(rc == sqlite.ROW)
			for i in 0 ..< int(sqlite.column_count(stmt)) {
				value := sqlite.column_string(stmt, i)
				fmt.sbprintf(&out, "%d:%s;", len(value), value)
			}
			strings.write_byte(&out, '\n')
		}
		strings.write_byte(&out, '\n')
	}
	return strings.clone(strings.to_string(out))
}
