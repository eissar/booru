package replay_bench

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../../src/library"
import "../../src/replay"
import "../../src/store"
import "../../src/vendor/sqlite"

// End-to-end production replay; setup and verification are not timed.
@(test)
test_replay :: proc(t: ^testing.T) {
	if !testing.expect(t, ensure_events_file(), "generate replay benchmark events") {return}
	data, read_err := os.read_entire_file(EVENTS_PATH, context.allocator)
	if !testing.expect(t, read_err == nil, "read replay benchmark fixture") {return}
	defer delete(data)
	text := string(data)
	count := 0
	for line in strings.split_lines_iterator(&text) {
		if strings.trim_space(line) != "" {count += 1}
	}
	if !testing.expect(t, count > 0) {return}
	// Compare later rounds with the warmup to check deterministic output.
	expected: string
	defer delete(expected)

	Run :: struct {
		state:  ^library.State,
		result: replay.Error,
	}
	durations: [11]f64
	events_per_second: [11]f64
	mib_per_second: [11]f64
	for round in 0 ..< len(durations) {
		state: library.State
		if !testing.expect(
			t,
			store.Init(&state, ":memory:", foreign_keys = false) == sqlite.OK,
		) {return}
		defer store.Close(&state)
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		run := Run {
			state = &state,
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
				if !sqlite.run(run.state.data_store, "BEGIN") {
					run.result = .DATABASE_ERR
				} else {
					run.result = replay.replay(run.state, {text}, alloc)
					if !sqlite.run(
						run.state.data_store,
						run.result == nil ? "COMMIT" : "ROLLBACK",
					) {
						run.result = .DATABASE_ERR
					}
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
		stmt, ok := sqlite.prepare(state.data_store, "SELECT COUNT(*) FROM items")
		if !testing.expect(t, ok) {return}
		defer sqlite.finalize(stmt)
		if !testing.expect(t, sqlite.step(stmt) == sqlite.ROW) {return}
		if !testing.expect(t, sqlite.column_int64(stmt, 0) == i64(count)) {return}
		actual := replay_benchmark_snapshot(state.data_store)
		if round == 0 {expected = strings.clone(actual)}
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
	fmt.printf(
		"replay: %d events, median %.3f ms, %.0f ns/event, %.0f events/s, %.2f MiB/s (10 runs; DB setup excluded; row count and repeatability checked)\n",
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
