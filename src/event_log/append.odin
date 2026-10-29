package event_log

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

ev_append :: proc {
	append_records,
	append_remediation,
}

@(private)
append_records :: proc(log: ^EventLog, events: []Event) -> (err: string) {
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

	end, seek_err := os.seek(ev_handle, 0, .Current)
	if seek_err != nil {return "could not get event log position"}

	if err := make_durable(ev_handle); err != "" {
		return fmt.tprintf("make durable: %v", err)
	}

	if log.cursor.shard != shard {
		delete(log.cursor.shard)
		log.cursor.shard = strings.clone(shard)
	}
	log.cursor.offset = end

	return ""
}

@(private)
append_remediation :: proc(rq_handle: ^os.File, rem: EventRemediation) -> (err: string) {
	buf: [MAX_RECORD + 1]u8
	bw: bufio.Writer
	bufio.writer_init_with_buf(&bw, os.to_writer(rq_handle), buf[:])

	if err := write_event(bufio.writer_to_stream(&bw), rem); err != "" {return err}
	if bufio.writer_flush(&bw) != nil {
		return "could not flush remediation queue"
	}

	return ""
}
