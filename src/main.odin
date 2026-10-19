package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

import "cli"
import "core:c"
import elog "event_log"
import "importers"
import "library"
import "replay"
import "server"
import "store"
import "thumbnail"
import "vendor/sqlite"

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

	if err := library.init_new_library(cfg.library); err != nil {
		log.fatal("library: initialize directory structure:", err)
		os.exit(1)
	}

	event_log := elog.EventLog {
		root = cfg.library,
	}
	state := library.State {
		library_path = cfg.library,
		event_log    = &event_log,
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

	images, read_rc := store.read_images(state.data_store, context.temp_allocator)
	if read_rc != sqlite.OK {
		log.fatal("datastore type=sqlite read items: failed w/ error code:", read_rc)
		os.exit(1)
	}
	library.seed_ids_from_library(images)
	log.infof(
		"%d images loaded in %.2f ms: %s",
		len(images),
		time.duration_milliseconds(time.since(load_start)),
		cfg.library,
	)

	if cfg.import_eagle != "" {
		source := fmt.aprintf("%s/images", cfg.import_eagle)
		defer delete(source)

		fd, open_err := os.open(source, {.Read}, os.Permissions_Default)
		if open_err != nil {
			log.fatalf("open Eagle images directory %s: %v", source, open_err)
			os.exit(1)
		}

		result := importers.eagle_import(source, &state, linux.Fd(os.fd(fd)))
		os.close(fd)
		log.infof(
			"Eagle import: %d imported, %d missing metadata, %d read errors",
			result.success,
			result.missing,
			result.read_errors,
		)
	}

	if cfg.scanThumbnail {
		generated, failed := thumbnail.generate_missing_thumbnails(state)
		log.infof("thumbnails: %d generated, %d failed", generated, failed)
	}

	defer free_all(context.temp_allocator)

	server.Serve(&state, sock) // this should take an allocator
}
