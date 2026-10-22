#+build linux
package event_log

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/linux"

// Returns empty string on no error.
event_append :: proc(log: ^EventLog, e: Event) -> (err: string) {
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
	ascii: strings.Builder
	strings.builder_init(&ascii, context.temp_allocator)
	defer strings.builder_destroy(&ascii)
	encode_ascii_json(data, &ascii)
	payload := transmute([]u8)strings.to_string(ascii)
	if len(payload) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
	written, write_err := os.write(ev_handle, payload)
	if write_err != nil || written != len(payload) {return "could not write event payload"}
	if io.write_byte(os.to_writer(ev_handle), '\n') != nil {
		return "could not write event newline"
	}
	if linux.fsync(linux.Fd(os.fd(ev_handle))) != .NONE {
		return "could not sync event log"
	}

	when ODIN_OS == .Linux {
		dir, dir_err := os.open(
			fmt.tprintf("%s/events", log.root),
			{.Read},
			os.Permissions_Default,
		)
		if dir_err != nil {return "could not open events directory for syncing"}
		defer os.close(dir)
		if linux.fsync(linux.Fd(os.fd(dir))) != .NONE {return "could not sync events directory"}
	}
	return ""
}

// Appends one batch, flushing and syncing once.
events_append :: proc(log: ^EventLog, events: []Event) -> (err: string) {
	if len(events) == 0 {return ""}
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
	bufio.writer_init(&bw, input_stream, size = MAX_RECORD + 1, allocator = context.allocator)
	defer bufio.writer_destroy(&bw)

	buffered_stream := bufio.writer_to_stream(&bw)
	for event in events {
		data, marshal_err := json.marshal(event, opt, context.allocator)
		if marshal_err != nil {return "could not marshal event"}
		defer delete(data, context.allocator)
		ascii: strings.Builder
		strings.builder_init(&ascii, context.allocator)
		defer strings.builder_destroy(&ascii)
		encode_ascii_json(data, &ascii)
		payload := transmute([]u8)strings.to_string(ascii)
		if len(payload) >= MAX_RECORD {panic("event must be smaller than MAX_RECORD")}
		written, write_err := io.write(buffered_stream, payload)
		if write_err != nil || written != len(payload) {return "could not write event payload"}
		if io.write_byte(buffered_stream, '\n') != nil {
			return "could not write event newline"
		}
	}
	if bufio.writer_flush(&bw) != nil {
		return "could not flush event log"
	}
	if linux.fsync(linux.Fd(os.fd(ev_handle))) != .NONE {
		return "could not sync event log"
	}

	when ODIN_OS == .Linux {
		dir, dir_err := os.open(
			fmt.tprintf("%s/events", log.root),
			{.Read},
			os.Permissions_Default,
		)
		if dir_err != nil {return "could not open events directory for syncing"}
		defer os.close(dir)
		if linux.fsync(linux.Fd(os.fd(dir))) != .NONE {return "could not sync events directory"}
	}
	return ""
}
