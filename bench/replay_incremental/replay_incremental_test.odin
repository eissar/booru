package replay_incremental_bench

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../../src/library"
import "../../src/replay"
import "../../src/store"
import "../../src/vendor/sqlite"

SEED_ITEMS :: 100_000
TAGS :: [?]string{"cat", "dog", "bird", "fish", "tree", "sky", "sea", "red", "blue", "green"}

// Seeds SEED_ITEMS live items via full replay, then times incremental replay
// of patch batches inside BEGIN..ROLLBACK so every iteration sees the same store.
@(test)
bench_incremental_replay :: proc(t: ^testing.T) {
	// The swap tmpfile lives in library_path.
	root, dir_err := os.make_directory_temp("", "booru-replay-incremental-*", context.allocator)
	if !testing.expect(t, dir_err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	state := library.State {
		library_path = root,
	}
	if !testing.expect(
		t,
		store.Init(&state, ":memory:", foreign_keys = false) == sqlite.OK,
	) {return}
	defer store.Close(&state)
	db := state.data_store

	seed: strings.Builder
	strings.builder_init(&seed)
	defer strings.builder_destroy(&seed)
	tags := TAGS
	for id in 1 ..= SEED_ITEMS {
		fmt.sbprintf(
			&seed,
			`{{"op":"add","id":%d,"oid":"o%d","path":"p%d","ext":"png","name":"n%d","mtime":1000,"added_at":1000,"tags":["%s","%s"]}}` +
			"\n",
			id,
			id,
			id,
			id,
			tags[id % len(tags)],
			tags[(id % len(tags) + 1 + (id / 7) % (len(tags) - 1)) % len(tags)],
		)
	}
	if !testing.expect(t, sqlite.run(db, "BEGIN")) {return}
	if !testing.expect_value(
		t,
		replay.replay(&state, {strings.to_string(seed)}, context.allocator),
		replay.Error.None,
	) {return}
	if !testing.expect(t, sqlite.run(db, "COMMIT")) {return}

	r := rand.create(42)
	gen := rand.default_random_generator(&r)

	Case :: struct {
		label:  string,
		events: int,
		iters:  int,
	}
	cases := [?]Case {
		{"1 tag patch", 1, 201},
		{"1 name patch", 1, 201},
		{"100 mixed patches", 100, 101},
		{"20000 mixed patches", 20_000, 11},
	}
	for c in cases {
		durations := make([]f64, c.iters)
		defer delete(durations)
		for iter in 0 ..< c.iters {
			b: strings.Builder
			strings.builder_init(&b)
			defer strings.builder_destroy(&b)
			for e in 0 ..< c.events {
				id := 1 + int(rand.uint64(gen) % SEED_ITEMS)
				kind := c.label == "1 tag patch" ? 0 : c.label == "1 name patch" ? 1 : e % 3
				switch kind {
				case 0:
					fmt.sbprintf(
						&b,
						`{{"op":"patch","id":%d,"tags":["%s"]}}` + "\n",
						id,
						tags[e % len(tags)],
					)
				case 1:
					fmt.sbprintf(&b, `{{"op":"patch","id":%d,"name":"0a0b"}}` + "\n", id)
				case 2:
					fmt.sbprintf(&b, `{{"op":"patch","id":%d,"mtime":%d}}` + "\n", id, 2000 + iter)
				}
			}
			text := strings.to_string(b)
			if !testing.expect(t, sqlite.run(db, "BEGIN")) {return}
			start := time.tick_now()
			err := replay.replay(&state, {text}, context.allocator, full_replay = false)
			elapsed := time.tick_since(start)
			sqlite.run(db, "ROLLBACK")
			if !testing.expect_value(t, err, replay.Error.None) {return}
			free_all(context.temp_allocator)
			durations[iter] = f64(time.duration_nanoseconds(elapsed))
		}
		// Discard the first iteration as warmup.
		measured := durations[1:]
		slice.sort(measured)
		n := len(measured)
		median := n % 2 == 0 ? (measured[n / 2 - 1] + measured[n / 2]) / 2 : measured[n / 2]
		fmt.printf(
			"incremental %-20s median %9.1f us  p10 %9.1f us  p90 %9.1f us  (%d runs)\n",
			c.label,
			median / 1e3,
			measured[n / 10] / 1e3,
			measured[n * 9 / 10] / 1e3,
			n,
		)
	}
}
