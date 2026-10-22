package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import elog "../../src/event_log"
import "../../src/importers"
import "../../src/library"
import "../../src/store"
import "../../src/vendor/sqlite"

FIXTURE_EAGLE_LIBRARY :: "test/fixture/eagle/fixture.library/images"
WARMUP :: 5
SAMPLES :: 100

// One sample = import the existing Eagle fixture into a fresh library and
// in-memory store. Includes real file copies, hashing, fsyncs and event log
// appends. Only the eagle_import call is timed.
sample :: proc() -> (elapsed: time.Duration, ok: bool) {
	fd, err := os.open(FIXTURE_EAGLE_LIBRARY, {.Read}, os.Permissions_Default)
	if err != nil {fmt.eprintln("open fixture:", err); return}
	defer os.close(fd)

	root, temp_err := os.make_directory_temp("", "booru-bench-import-*", context.allocator)
	if temp_err != nil {fmt.eprintln("temp dir:", temp_err); return}
	defer delete(root)
	defer os.remove_all(root)
	if init_err := library.init_new_library(root); init_err != nil {
		fmt.eprintln("init library:", init_err)
		return
	}

	log := elog.EventLog {
		root = root,
	}
	state := library.State {
		library_path = root,
		event_log    = &log,
	}
	if store.Init(&state, ":memory:") != sqlite.OK {fmt.eprintln("store init"); return}
	defer store.Close(&state)

	start := time.tick_now()
	res := importers.eagle_import(FIXTURE_EAGLE_LIBRARY, &state, fd)
	elapsed = time.tick_since(start)
	if res.success != 3 {fmt.eprintln("unexpected import result:", res); return}
	return elapsed, true
}

main :: proc() {
	for _ in 0 ..< WARMUP {
		if _, ok := sample(); !ok {os.exit(1)}
	}
	ms: [SAMPLES]f64
	for i in 0 ..< SAMPLES {
		d, ok := sample()
		if !ok {os.exit(1)}
		ms[i] = time.duration_milliseconds(d)
	}
	slice.sort(ms[:])
	sum: f64
	for v in ms {sum += v}
	fmt.printfln(
		"eagle fixture e2e import: %d samples; mean %.3f ms; median %.3f ms; range %.3f..%.3f ms",
		SAMPLES,
		sum / SAMPLES,
		ms[SAMPLES / 2],
		ms[0],
		ms[SAMPLES - 1],
	)
}
