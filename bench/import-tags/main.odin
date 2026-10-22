package main

import elog "../../src/event_log"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:time"
// Mirror the importer wire type so this benchmark remains runnable while importer edits are in progress.
EagleItem_Event :: struct {
	added_at:     i64 `json:"btime"`,
	comment:      string `json:"annotation"`,
	content_type: string `json:"-"`,
	ext:          string,
	height:       int,
	id:           int `json:"-"`,
	mtime:        i64,
	name:         string,
	oid:          string `json:"-"`,
	op:           string `json:"-"`,
	path:         string `json:"-"`,
	tags:         []string,
	width:        int,
}

ITEMS :: 100_000
SAMPLES :: 7

// Fixed metadata inputs: clean, unsupported characters, and normalization collisions.
// All cases deliberately use eight tags. No validation or remediation exists here yet.
CLEAN :: `{"name":"sample","ext":"png","width":1920,"height":1080,"btime":1700000000,"mtime":1700000001,"tags":["cat","black-cat","animal","portrait","outdoor","photo","favorite","reference"]}`
UNSUPPORTED :: `{"name":"sample","ext":"png","width":1920,"height":1080,"btime":1700000000,"mtime":1700000001,"tags":["cat🐕","black cat","animal!","portrait","outdoor","photo","favorite","reference"]}`
COLLISIONS :: `{"name":"sample","ext":"png","width":1920,"height":1080,"btime":1700000000,"mtime":1700000001,"tags":["cat🐕","cat🐈","cat","portrait","outdoor","photo","favorite","reference"]}`

run :: proc(input: string, count: int) -> (elapsed: f64, checksum: int) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	start := time.tick_now()
	// Bound memory like import batches; preserve allocations until each batch finishes.
	for base := 0; base < count; base += 256 {
		events := make([dynamic]elog.Event, alloc)
		for i in 0 ..< min(256, count - base) {
			item: EagleItem_Event
			if err := json.unmarshal(
				transmute([]u8)input,
				&item,
				json.DEFAULT_SPECIFICATION,
				alloc,
			); err != nil {
				fmt.panicf("decode: %v", err)
			}
			ev := cast(^elog.Event)&item
			ev.id = base + i + 1
			ev.op = "add"
			// Future tag validation/remediation belongs here.
			append(&events, ev^)
		}
		for ev in events {
			checksum += ev.id + len(ev.tags) + len(ev.tags[0])
		}
		free_all(alloc)
	}
	elapsed = time.duration_seconds(time.tick_since(start))
	return
}

main :: proc() {
	fmt.println(
		"BEFORE: metadata JSON decode + event append; no tag validation, file I/O, hashing, SQLite, or log serialization",
	)
	fmt.printf("%d items/sample; %d samples; 8 tags/item; 256 items/batch\n", ITEMS, SAMPLES)
	inputs := [?]string{CLEAN, UNSUPPORTED, COLLISIONS}
	names := [?]string{"clean", "unsupported", "collisions"}
	for input, index in inputs {
		run(input, 10_000) // warm up
		total, best, worst := f64(0), f64(1e9), f64(0)
		checksum := 0
		for _ in 0 ..< SAMPLES {
			seconds, sum := run(input, ITEMS)
			total += seconds
			best = min(best, seconds)
			worst = max(worst, seconds)
			checksum = sum
		}
		mean := total / SAMPLES
		fmt.printf(
			"%s: mean %.3f ms; range %.3f..%.3f ms; %.1f ns/item; %.0f items/s; checksum %d\n",
			names[index],
			mean * 1e3,
			best * 1e3,
			worst * 1e3,
			mean * 1e9 / ITEMS,
			ITEMS / mean,
			checksum,
		)
	}
}
