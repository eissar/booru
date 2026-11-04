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
import "util"

DATA_DIR: string

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
	home := os.get_env("HOME", context.temp_allocator)
	data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data_home == "" {
		if home == "" {
			fmt.eprintln("error: HOME is required when XDG_DATA_HOME is unset")
			os.exit(2)
		}
		data_home, _ = os.join_path({home, ".local", "share"}, context.temp_allocator)
	} else if !os.is_absolute_path(data_home) {
		fmt.eprintln("error: XDG_DATA_HOME must be an absolute path")
		os.exit(2)
	}
	DATA_DIR, _ = os.join_path({data_home, "booru"}, context.allocator)
	defer delete(DATA_DIR, context.allocator)
	library_path := util.expand_home(cfg.library, home)
	// Bare names select managed libraries; explicit paths stay explicit.
	if !strings.has_prefix(cfg.library, ".") &&
	   !strings.has_prefix(cfg.library, "~") &&
	   !strings.contains(cfg.library, "/") &&
	   !strings.contains(cfg.library, `\`) {
		library_path, _ = os.join_path(
			{DATA_DIR, "libraries", cfg.library},
			context.temp_allocator,
		)
		info, stat_err := os.stat(cfg.library, context.temp_allocator)
		if stat_err == nil {
			if info.type == .Directory {
				fmt.eprintf(
					"warning: library %q resolves to %s; use -library:./%s for the directory in the current directory\n",
					cfg.library,
					library_path,
					cfg.library,
				)
			}
			os.file_info_delete(info, context.temp_allocator)
		}
	}
	library_path = strings.clone(library_path, context.allocator)
	defer delete(library_path, context.allocator)
	cfg.library = library_path
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

	cursor: elog.Cursor
	event_log := elog.EventLog {
		root   = cfg.library,
		cursor = &cursor,
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

	_, stat_err := os.stat(db_c, context.temp_allocator)
	if stat_err != nil && stat_err != .Not_Exist {
		fmt.panicf("stat store: %v", stat_err)
	}
	fresh_store := stat_err == .Not_Exist
	rc := store.Init(&state, db_c_str)
	if rc != 0 {
		log.fatal("datastore type=sqlite open: failed w/ error code:", rc)
		os.exit(1)
	}
	defer store.Close(&state)

	// Existing stores assume older shards are fully applied. The append boundary
	// is the calendar-current shard's end, not SQLite's applied cursor (nor the
	// latest historical shard, which may belong to a previous month).
	if !fresh_store {
		shard := elog.get_current_event_shard(context.temp_allocator)
		copy(cursor.shard[:], shard)
		path := fmt.tprintf("%s/events/%s", cfg.library, shard)
		info, err := os.stat(path, context.temp_allocator)
		if err != nil && err != .Not_Exist {
			fmt.panicf("stat event shard: %v", err)
		}
		if err == nil {cursor.offset = info.size}
	}
	replay.initiate_replay(&state, full_replay = fresh_store)

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
