package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

import "cli"
import elog "event_log"
import "importers"
import "library"
import "progress"
import "replay"
import "server"
import "store"
import "thumbnail"
import "vendor/sqlite"

fmt_timestamp :: proc(elapsed: time.Duration) -> string {
	if elapsed < time.Second {
		return fmt.tprintf("%.2f ms", time.duration_milliseconds(elapsed))
	} else {
		return fmt.tprintf("%.2f s", time.duration_seconds(elapsed))
	}
}

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
	ready_fd := daemonize() if cfg.daemon else {}

	if err := library.init_new_library(cfg.library); err != nil {
		log.fatal("library: initialize directory structure:", err)
		os.exit(1)
	}

	// Fail before replay rather than sharing the library with a live server.
	if cfg.socket != "" && server.unix_socket_in_use(cfg.socket) {
		log.fatalf("listen on unix socket %s: already in use by a running server", cfg.socket)
		os.exit(1)
	}

	event_log := elog.EventLog {
		root = cfg.library,
	}
	state := library.State {
		library_path = cfg.library,
		event_log    = &event_log,
	}

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

	stmt: ^sqlite.Stmt
	read_rc := sqlite.prepare_v2(
		state.data_store,
		`SELECT COALESCE(MAX(id), 0) FROM items`,
		-1,
		&stmt,
		nil,
	)
	if read_rc == sqlite.OK {
		read_rc = sqlite.step(stmt)
	}
	if read_rc != sqlite.ROW {
		sqlite.finalize(stmt)
		log.fatal("datastore type=sqlite read max ID: failed w/ error code:", read_rc)
		os.exit(1)
	}
	library.seed_ids_from_library(int(sqlite.column_int64(stmt, 0)))
	sqlite.finalize(stmt)
	log.infof(
		"Library initialized in %.2f ms: %s",
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

		result := importers.eagle_import(source, &state, fd)
		os.close(fd)
		log.infof(
			"Eagle import: %d imported, %d missing metadata, %d read errors",
			result.success,
			result.missing,
			result.read_errors,
		)
	}

	defer free_all(context.temp_allocator)

	cb: progress.Callback : proc(prg: progress.Progress) {
		fmt.println(prg)
		progress.current = prg
		if total, ok := prg.total.?; ok && prg.finished == total {progress.done = true}
	}

	scan_thread: ^thread.Thread
	if cfg.scan_thumbnail {
		scan_thread = thread.create_and_start_with_poly_data(struct {
				library_path:  string,
				prog_callback: progress.Callback,
			} {
				library_path = cfg.library,
				prog_callback = cb,
			}, thumbnail.startup_threaded_generate_missing_thumbnails)
		if scan_thread == nil {
			log.error("thumbnails: could not create scan thread")
		}
	}
	defer {
		if scan_thread != nil {thread.destroy(scan_thread)}
	}

	log.infof("total startup time=%v", fmt_timestamp(time.since(load_start)))

	// Bind last: the socket existing means the server is ready.
	sock: net.TCP_Socket
	accept: server.Accept_Proc = server.accept_tcp
	if cfg.socket != "" {
		err: string
		if sock, err = server.listen_unix(cfg.socket); err != "" {
			log.fatalf("listen on unix socket %s: %s", cfg.socket, err)
			os.exit(1)
		}
		accept = server.accept_unix
	} else {
		ep := net.Endpoint({net.IP4_Address{0, 0, 0, 0}, cfg.port})
		err: net.Network_Error
		if sock, err = net.listen_tcp(ep); err != nil {
			log.fatal(err)
			os.exit(1)
		}
	}

	defer net.close(sock)
	if cfg.daemon {daemon_ready(ready_fd)}

	server.Serve(&state, sock, accept) // this should take an allocator
}
