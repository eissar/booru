package http

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:net"
import "core:strings"
import "core:testing"

// TODO: When reusing request buffers, reset them only after response sending completes.
Response :: struct {
	headers:            map[string]string,
	body:               []u8,
	status:             STATUS,
	// Optional streaming body; body remains empty when this is set.
	body_stream:        proc(conn: ^net.TCP_Socket, data: rawptr) -> io.Error,
	body_stream_data:   rawptr,
	// Optional reader body, sent after the headers and then closed (see res_file).
	body_reader:        io.Stream,
	// Negative means unknown length: no Content-Length is sent.
	body_stream_length: int,
}

// Serializes an HTTP/1.1 response. The caller owns the returned string.
// Uses an empty reason phrase, which HTTP/1.1 permits. Bodies are copied verbatim.
// Transfer-Encoding is unsupported; Content-Length is computed for body-bearing statuses.
@(require_results)
marshal :: proc(res: Response, alloc: runtime.Allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	fmt.sbprintf(&builder, "HTTP/1.1 %d \r\n", int(res.status))
	for name, value in res.headers {
		assert(!strings.contains(name, "\r") && !strings.contains(name, "\n"))
		assert(!strings.contains(value, "\r") && !strings.contains(value, "\n"))
		assert(!strings.equal_fold(name, "Transfer-Encoding"))
		if strings.equal_fold(name, "Content-Length") {continue}
		fmt.sbprintf(&builder, "%s: %s\r\n", name, value)
	}
	if int(res.status) < 200 || res.status == .NoContent || res.status == .NotModified {
		assert(len(res.body) == 0)
		strings.write_string(&builder, "\r\n")
	} else {
		streamed := res.body_stream != nil || res.body_reader.procedure != nil
		if streamed && res.body_stream_length < 0 {
			strings.write_string(&builder, "\r\n")
		} else {
			length := streamed ? res.body_stream_length : len(res.body)
			fmt.sbprintf(&builder, "Content-Length: %d\r\n\r\n", length)
			if !streamed {
				strings.write_bytes(&builder, res.body)
			}
		}
	}
	return strings.to_string(builder)
}

marshal_and_send :: proc(
	sock: net.TCP_Socket,
	res: Response,
	alloc: runtime.Allocator,
) -> net.TCP_Send_Error {
	defer if res.body_reader.procedure != nil {io.close(res.body_reader)}
	wire := marshal(res, alloc)
	defer delete(wire, alloc)

	remaining := transmute([]u8)wire
	for len(remaining) > 0 {
		sent, err := net.send_tcp(sock, remaining)
		if err != nil {return err}
		if sent == 0 {return .Connection_Closed}
		remaining = remaining[sent:]
	}
	if res.body_stream != nil {
		conn := sock
		if err := res.body_stream(&conn, res.body_stream_data); err != nil {
			return .Connection_Closed
		}
	}
	if res.body_reader.procedure != nil {
		if err := send_reader(sock, res.body_reader); err != nil {return .Connection_Closed}
	}
	return nil
}


@(test)
unit_marshal :: proc(t: ^testing.T) {
	headers := make(map[string]string)
	defer delete(headers)
	headers["Content-Type"] = "application/octet-stream"
	headers["content-length"] = "999"
	body := [3]u8{0, 255, 65}
	res := Response {
		headers = headers,
		body    = body[:],
		status  = .OK,
	}
	wire := marshal(res, context.temp_allocator)
	defer delete(wire, context.temp_allocator)
	expected :=
		"HTTP/1.1 200 \r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\n\r\n" +
		"\x00\xffA"
	testing.expect(t, wire == expected, "serializes headers and binary body")

	empty := marshal(Response{status = .NoContent}, context.temp_allocator)
	defer delete(empty, context.temp_allocator)
	testing.expect(t, empty == "HTTP/1.1 204 \r\n\r\n", "serializes a bodyless response")
}

@(test)
unit_res_file_streams_and_closes_reader :: proc(t: ^testing.T) {
	Source :: struct {
		data:   string,
		pos:    int,
		closed: bool,
	}
	source_proc :: proc(
		data: rawptr,
		mode: io.Stream_Mode,
		p: []byte,
		offset: i64,
		whence: io.Seek_From,
	) -> (
		n: i64,
		err: io.Error,
	) {
		src := (^Source)(data)
		#partial switch mode {
		case .Read:
			if src.pos == len(src.data) {return 0, .EOF}
			n = i64(copy(p, src.data[src.pos:]))
			src.pos += int(n)
			return n, nil
		case .Close:
			src.closed = true
			return 0, nil
		}
		return 0, .Unsupported
	}
	src := Source {
		data = "streamed body",
	}
	reader := io.Stream {
		procedure = source_proc,
		data      = &src,
	}

	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil, "listen") {return}
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if !testing.expect(t, dial_err == nil, "dial") {return}
	defer net.close(client)
	server, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil, "accept") {return}
	defer net.close(server)

	res := Response {
		headers = make(map[string]string, context.temp_allocator),
	}
	res_file(reader, len(src.data), &res)
	testing.expect(t, marshal_and_send(server, res, context.temp_allocator) == nil, "send")
	testing.expect(t, src.closed, "closes the reader after sending")

	expected :=
		"HTTP/1.1 200 \r\nContent-Type: application/octet-stream\r\nContent-Length: 13\r\n\r\n" +
		"streamed body"
	buf: [256]u8
	got := 0
	for got < len(expected) {
		n, recv_err := net.recv_tcp(client, buf[got:])
		if recv_err != nil || n == 0 {break}
		got += n
	}
	testing.expect_value(t, string(buf[:got]), expected)
}

// REGION: asserts
@(test)
unit_smoke_res_helper :: proc(t: ^testing.T) {
	res: Response
	defer delete(res.headers)

	reset :: proc(res: ^Response) {
		delete(res.headers)
		res^ = Response {
			headers = make(map[string]string, 8),
		}
	}

	reset(&res)
	res_text("hello", &res)

	reset(&res)
	blob := [3]u8{1, 2, 3}
	res_blob(blob[:], &res)

	reset(&res)
	res_html(transmute([]u8)string("<p>hello</p>"), &res)

	reset(&res)
	res_json(transmute([]u8)string("{}"), &res)

	reset(&res)
	res_error("error", &res)

	reset(&res)
	res_redirect("/gallery", &res)
}
// Streams until `stream` returns an error. Connection closes when it ends.
res_event_stream :: proc(
	stream: proc(conn: ^net.TCP_Socket, data: rawptr) -> io.Error,
	data: rawptr,
	res: ^Response,
) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = "text/event-stream"
	res.headers["Cache-Control"] = "no-cache"
	res.headers["X-Accel-Buffering"] = "no"
	res.body_stream = stream
	res.body_stream_data = data
	res.body_stream_length = -1
	res.status = .OK
}

// Writes one SSE event; multi-line data becomes one `data:` line per line.
sse_event :: proc(conn: ^net.TCP_Socket, event, data: string) -> io.Error {
	b := strings.builder_make(context.temp_allocator)
	if event != "" {fmt.sbprintf(&b, "event: %s\n", event)}
	rest := data
	for line in strings.split_lines_iterator(&rest) {fmt.sbprintf(&b, "data: %s\n", line)}
	strings.write_byte(&b, '\n')

	remaining := transmute([]u8)strings.to_string(b)
	for len(remaining) > 0 {
		n, err := net.send_tcp(conn^, remaining)
		if err != nil || n == 0 {return .Unknown}
		remaining = remaining[n:]
	}
	return nil
}

assert_res_helper :: proc "contextless" (res: ^Response) {
	context = runtime.default_context()
	assert(res != nil)

	raw := cast(^runtime.Raw_Map)&res.headers
	assert(raw.allocator.procedure != nil)
}
// ENDREGION


res_text :: proc "contextless" (txt: string, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Text]
	res.body = transmute([]u8)txt
	res.status = status
}

res_blob :: proc(b: []u8, res: ^Response, type := Content_Type.Octet_Stream, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[type]
	res.body = b
	res.status = status
}

@(private = "file")
send_reader :: proc(conn: net.TCP_Socket, reader: io.Stream) -> io.Error {
	buf: [64 * 1024]u8 = ---
	for {
		n, read_err := io.read(reader, buf[:])
		for off := 0; off < n; {
			sent, send_err := net.send_tcp(conn, buf[off:n])
			if send_err != nil || sent <= 0 {return .Unknown}
			off += sent
		}
		if read_err == .EOF || n == 0 {break}
		if read_err != nil {return .Unknown}
	}
	return nil
}

// res_file streams `reader` (e.g. os.to_stream(file)) as the response body and closes it
// when done.
res_file :: proc(
	reader: io.Stream,
	length: int,
	res: ^Response,
	type := Content_Type.Octet_Stream,
	status := STATUS.OK,
) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[type]
	res.body = nil
	res.body_reader = reader
	res.body_stream_length = length
	res.status = status
}

// parapoly or whatever
res_html :: proc {
	res_html_string,
	res_html_bytes,
}

res_html_bytes :: proc(b: []u8, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Html]
	res.body = b
	res.status = status
}

res_html_string :: proc(b: string, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Html]
	res.body = transmute([]u8)b
	res.status = status
}

res_json :: proc(b: []u8, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Json]
	res.body = b
	res.status = status
}

res_error :: proc(txt: string, res: ^Response, status := STATUS.InternalServerError) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Text]
	res.body = transmute([]u8)txt
	res.status = status

}
res_redirect :: proc(location: string, res: ^Response, status := STATUS.Found) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Location"] = location
	res.body = nil
	res.status = status
}
