package event_log

import "core:fmt"
import "core:io"
import "core:os"
import "core:sync"
import "core:time"

import "../library"

Cursor :: struct {
	i:  int,
	mu: sync.Mutex,
}

// each library at most one
// EventLog with one cursor
EventLog :: struct {
	cur:  Cursor,
	root: string,
}

// we could also be
// using the Cursor to track
// byte offsets of the
// eventlogs, for faster parsing
// returns empty string on no err
event_append :: proc(log: ^EventLog, e: ^library.Event) -> (err: string) {
	shard := get_current_event_shard(context.temp_allocator)

	path, join_err := os.join_path({log.root, "events", shard}, context.temp_allocator)
	if join_err != nil {
		return "random error joining path?"
	}

	ev_opts := os.File_Flags{.Write, .Create, .Append}
	ev_handle, ev_open_err := os.open(path, ev_opts, os.Permissions_Default_File)
	if ev_open_err != nil {
		return "could not open event log for writing" // retryable?
	}

	_ = fmt.wprintln(os.to_stream(ev_handle), e)

	return ""
}


get_current_event_shard :: proc(allocator := context.allocator) -> string {
	year, month, _ := time.date(time.now())
	return fmt.aprintf("%04d-%02d.ndjson", year, int(month), allocator = allocator)
}
