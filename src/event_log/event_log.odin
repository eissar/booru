package event_log

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sync"
import "core:time"

// TODO: (V1)
// make this larger to support
// events of a larger size.
// when you do so, we will
// need to enforce this
// at a database level as well.
MAX_RECORD :: 2048

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

Event :: struct {
	added_at:     string,
	content_type: string,
	ext:          string,
	height:       int,
	id:           int,
	mtime:        string,
	name:         string,
	oid:          string,
	op:           string,
	path:         string,
	tags:         []string,
	width:        int,
}


// we could also be
// using the Cursor to track
// byte offsets of the
// eventlogs, for faster parsing
// returns empty string on no err
event_append :: proc(log: ^EventLog, e: ^Event) -> (err: string) {
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
	defer os.close(ev_handle)

	opt := json.Marshal_Options {
		spec   = .JSON,
		pretty = false,
	}
	data, marshal_err := json.marshal(e, opt, context.temp_allocator)
	if marshal_err != nil {return "could not marshal event"}
	defer delete(data, context.temp_allocator)
	if len(data) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
	os.write(ev_handle, data)
	if io.write_byte(os.to_writer(ev_handle), '\n') != nil {
		return "could not write event newline"
	}

	return ""
}

events_append :: proc(log: ^EventLog, e: ^Event) -> (err: string) {
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
	defer os.close(ev_handle)

	opt := json.Marshal_Options {
		spec   = .JSON,
		pretty = false,
	}

	input_stream := os.to_writer(ev_handle)

	bw: bufio.Writer
	bufio.writer_init(&bw, input_stream, size = 1024, allocator = context.temp_allocator)

	buffered_stream := bufio.writer_to_stream(&bw)
	data, marshal_err := json.marshal(e, opt, context.temp_allocator)
	if marshal_err != nil {return "could not marshal event"}
	defer delete(data, context.temp_allocator)
	if len(data) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
	io.write(buffered_stream, data)
	if io.write_byte(buffered_stream, '\n') != nil {
		return "could not write event newline"
	}
	if bufio.writer_flush(&bw) != nil {
		return "could not flush event log"
	}

	return ""
}


get_current_event_shard :: proc(allocator := context.allocator) -> string {
	year, month, _ := time.date(time.now())
	return fmt.aprintf("%04d-%02d.ndjson", year, int(month), allocator = allocator)
}
