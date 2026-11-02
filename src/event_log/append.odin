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
	// Synchronously pre-validate the batch: writes are slow, reads are fast.
	records := make([]strings.Builder, len(events))
	defer {
		for &record in records {strings.builder_destroy(&record)}
		delete(records)
	}
	for e, i in events {
		strings.builder_init(&records[i])
		if err := encode_event(e, &records[i]); err != "" {return err}
		strings.write_byte(&records[i], '\n')
	}
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
	// One write per complete record. An I/O error can leave an uncertain append.
	for record in records {
		payload := transmute([]u8)strings.to_string(record)
		written, write_err := io.write(input_stream, payload)
		if write_err != nil || written != len(payload) {return "could not write event record"}
	}

	end, seek_err := os.seek(ev_handle, 0, .Current)
	if seek_err != nil {return "could not get event log position"}

	if err := make_durable(ev_handle); err != "" {
		return fmt.tprintf("make durable: %v", err)
	}

	if string(log.cursor.shard[:]) != shard {
		copy(log.cursor.shard[:], shard)
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
