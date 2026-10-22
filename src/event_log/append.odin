package event_log

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"

ev_append :: proc(log: ^EventLog, events: []Event) -> (err: string) {
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

	input_stream := os.to_writer(ev_handle)

	buf: [MAX_RECORD + 1]u8
	bw: bufio.Writer
	bufio.writer_init_with_buf(&bw, input_stream, buf[:])

	buffered_stream := bufio.writer_to_stream(&bw)
	// Flush per record: the buffer (MAX_RECORD + 1) always holds one whole
	// record plus newline, so each record is exactly one write and never split.
	for e in events {
		if err := write_event(buffered_stream, e); err != "" {return err}
		if bufio.writer_flush(&bw) != nil {
			return "could not flush event log"
		}
	}

	if err := make_durable(ev_handle); err != "" {
		return fmt.tprintf("make durable: %v", err)
	}

	return ""
}
