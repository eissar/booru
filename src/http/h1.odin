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
		length := res.body_stream != nil ? res.body_stream_length : len(res.body)
		fmt.sbprintf(&builder, "Content-Length: %d\r\n\r\n", length)
		if res.body_stream == nil {
			strings.write_bytes(&builder, res.body)
		}
	}
	return strings.to_string(builder)
}

marshal_and_send :: proc(
	sock: net.TCP_Socket,
	res: Response,
	alloc: runtime.Allocator,
) -> net.TCP_Send_Error {
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
