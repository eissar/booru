package server

import elog "../event_log"
import "../http"
import "../library"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

handle_events :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	if req.header.method != "GET" {
		res.headers["Allow"] = "GET"
		http.res_text("Method Not Allowed", res, .MethodNotAllowed)
		return
	}
	params := make(map[string]string, req.alloc)
	defer delete(params)
	if !parse_query_params(req.header.query, &params, req.alloc) {
		http.res_text(ENCODING_ERR_MSG, res, .BadRequest)
		return
	}
	token, present := params["after"]
	if !present {
		http.res_text("Missing cursor", res, .BadRequest)
		return
	}
	decoded, decode_err := base64.decode(token, base64.DEC_URL_TABLE, allocator = req.alloc)
	if decode_err != nil {
		http.res_text("Invalid cursor", res, .BadRequest)
		return
	}
	defer delete(decoded, req.alloc)
	text := string(decoded)
	separator := strings.index(text, ":")
	if separator < 0 {
		http.res_text("Invalid cursor", res, .BadRequest)
		return
	}
	after: elog.Cursor
	copy(after.shard[:], text[:separator])
	offset, ok := strconv.parse_i64(text[separator + 1:])
	if !ok {
		http.res_text("Invalid cursor", res, .BadRequest)
		return
	}
	after.offset = offset
	// Capture the append boundary before reading any files.
	upper := s.event_log.cursor^
	start_shard := string(after.shard[:])
	upper_shard := string(upper.shard[:])
	if start_shard > upper_shard || (start_shard == upper_shard && after.offset > upper.offset) {
		http.res_text("Invalid cursor", res, .BadRequest)
		return
	}
	out: strings.Builder
	strings.builder_init(&out, req.alloc)

	if upper != (elog.Cursor{}) { 	// if not nil init
		paths := make([dynamic]string, req.alloc)
		defer {
			for path in paths {delete(path, req.alloc)}
			delete(paths)
		}
		root := fmt.aprintf("%s/events", s.event_log.root, allocator = req.alloc)
		defer delete(root, req.alloc)
		w := os.walker_create(root)
		defer os.walker_destroy(&w)
		for entry in os.walker_walk(&w) {
			if entry.type == .Directory || !strings.has_suffix(entry.name, ".ndjson") {continue}
			if entry.name > upper_shard {continue}
			append(&paths, strings.clone(entry.fullpath, req.alloc))
		}
		if _, err := os.walker_error(&w); err != nil {
			http.res_error("Cannot read event log", res)
			return
		}
		slice.sort(paths[:])
		found := after == (elog.Cursor{})
		found_upper := false
		for path in paths {
			shard := path[len(path) - 14:]
			if shard < start_shard {continue}
			data, read_err := os.read_entire_file(path, req.alloc)
			if read_err != nil {http.res_error("Cannot read event log", res); return}
			defer delete(data, req.alloc)
			end := i64(len(data))
			if shard == upper_shard {
				found_upper = true
				end = upper.offset
				if end < 0 ||
				   end > i64(len(data)) {http.res_error("Invalid event log boundary", res); return}
			}
			begin: i64
			if shard == start_shard {begin = after.offset; found = true}
			if begin > end || (begin > 0 && data[begin - 1] != '\n') {
				http.res_text("Invalid cursor", res, .BadRequest)
				return
			}
			// Omit an incomplete trailing record without changing the log cursor.
			for end > begin && data[end - 1] != '\n' {end -= 1}
			strings.write_bytes(&out, data[begin:end])
		}
		if !found {http.res_text("Invalid cursor", res, .BadRequest); return}
		if !found_upper {http.res_error("Missing event log boundary shard", res); return}
	}
	http.res_text(strings.to_string(out), res)
	res.headers["Content-Type"] = "application/x-ndjson"
	res.headers["Cache-Control"] = "no-store"
	shard := ""
	if upper != (elog.Cursor{}) {shard = string(upper.shard[:])}
	cursor_text := fmt.aprintf("%s:%d", shard, upper.offset, allocator = req.alloc)
	defer delete(cursor_text, req.alloc)
	res.headers["X-Booru-Event-Cursor"] = base64.encode(
		transmute([]u8)cursor_text,
		base64.ENC_URL_TABLE,
		allocator = req.alloc,
		options = {.No_Padding},
	)
}
