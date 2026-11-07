package replay_mixed_bench

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

// Full replay of a log containing every op; setup and verification are not timed.
@(test)
test_replay_mixed :: proc(t: ^testing.T) {
	if !testing.expect(t, ensure_mixed_events_file(), "generate mixed replay events") {return}
	data, read_err := os.read_entire_file(MIXED_EVENTS_PATH, context.allocator)
	if !testing.expect(t, read_err == nil, "read mixed replay fixture") {return}
	defer delete(data)
	text := string(data)
	count := strings.count(text, "\n")
	durations: [6]f64 // first is a warmup
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
		if !testing.expect(t, sqlite.run(state.data_store, "BEGIN")) {return}
		start := time.tick_now()
		err := replay.replay(&state, {text}, mem.dynamic_arena_allocator(&arena))
		durations[round] = f64(time.duration_nanoseconds(time.tick_since(start)))
		if !testing.expect(t, err == nil) {return}
		if !testing.expect(t, sqlite.run(state.data_store, "COMMIT")) {return}
		stmt, ok := sqlite.prepare(state.data_store, "SELECT COUNT(*) FROM items")
		if !testing.expect(t, ok) {return}
		defer sqlite.finalize(stmt)
		if !testing.expect(t, sqlite.step(stmt) == sqlite.ROW) {return}
		// Deleted items keep a row, so every add is present.
		if !testing.expect(t, sqlite.column_int64(stmt, 0) == MIXED_ADD_COUNT) {return}
	}
	slice.sort(durations[1:])
	median_ns := durations[1 + (len(durations) - 1) / 2]
	fmt.printf(
		"replay mixed: %d events, median %.3f ms, %.0f ns/event, %.0f events/s (5 runs; DB setup excluded; item count checked)\n",
		count,
		median_ns / 1e6,
		median_ns / f64(count),
		f64(count) / (median_ns / 1e9),
	)
}
