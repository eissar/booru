package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "cli"
import "core:c"
import elog "event_log"
import "library"
import "replay"
import "server"
import "store"
import "thumbnail"
import "vendor/sqlite"

// Loaded once at startup from the NDJSON event log; no DB for this prototype.
// library_images: [dynamic]library.Image
// library_path: string

main :: proc() {
	load_start := time.now()

	// consider: `when ODIN_DEBUG { log.debug("debugging") }` on hot paths
	lvl := log.Level.Debug when ODIN_DEBUG else log.Level.Info
	context.logger = log.create_console_logger(
		lowest = lvl,
		opt = log.Options{.Level, .Short_File_Path, .Procedure, .Line},
	)
	defer log.destroy_console_logger(context.logger)


	cfg := cli.getFlags()

	backing := make([]u8, 64 * mem.Megabyte)
	defer delete(backing)

	arena: mem.Arena
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)

	images := make([dynamic]library.Image, alloc)
	replay.load_library(cfg.library, &images, alloc)
	library.seed_ids_from_library(images[:])
	defer free_all(alloc)

	event_log := elog.EventLog {
		root = cfg.library,
	}
	state := library.State {
		library_images = images[:],
		library_path   = cfg.library,
		event_log      = &event_log,
	}

	log.infof(
		"%d images loaded in %.2f ms: %s",
		len(state.library_images),
		time.duration_milliseconds(time.since(load_start)),
		cfg.library,
	)

	if cfg.scanThumbnail {
		generated, failed := thumbnail.generate_missing_thumbnails(state)
		log.infof("thumbnails: %d generated, %d failed", generated, failed)
	}

	ep := net.Endpoint({net.IP4_Address{0, 0, 0, 0}, cfg.port})
	// net.parse_address
	sock, err := net.listen_tcp(ep)
	if err != nil {
		log.fatal(err)
		os.exit(1)
	}

	log.infof("server listening on %v", net.endpoint_to_string(ep))

	defer net.close(sock)


	db_c := fmt.aprintf(
		"%v/%v",
		state.library_path,
		"store.sqlite",
		allocator = context.temp_allocator,
	)
	db_c_str := strings.clone_to_cstring(db_c, context.temp_allocator)

	rc := store.Init(&state, db_c_str)
	if rc != 0 {
		log.fatal("datastore type=sqlite open: failed w/ error code:", rc)
		os.exit(1)
	}
	defer store.Close(&state)

	// replay events from the event log
	replay.initiate_replay(&state)

	// TODO : stop reading from s.library_images everywhere
	// so we can free this without defer
	defer free_all(context.temp_allocator)

	server.Serve(&state, sock) // this should take an allocator
}
