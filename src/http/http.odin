package http

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

Accept_Type :: enum {
	Html,
	Json,
	Webp,
	Avif,
	Jpeg,
	Png,
	Plain,
	Any,
}

Accept :: bit_set[Accept_Type]

// https://www.man7.org/linux/man-pages/man2/recv.2.html
Known_Headers :: struct {
	content_length: int,
	accept:         Accept,
	hx_request:     bool,
}

// bikeshed: store byte offsets/ lazy read somehow?
Header :: struct {
	method:        string,
	uri:           string,
	path:          string,
	query:         string, // raw query string, "" when absent
	known_headers: Known_Headers,
	headers:       map[string]string,
}

Req :: struct {
	header:   Header,
	alloc:    mem.Allocator,
	rec_time: time.Time,
}

// could add better error handling to this
read_header :: proc(
	sock: net.TCP_Socket,
	req_header: ^Header,
	raw_request: []u8,
	alloc: runtime.Allocator,
) -> (
	ok: bool,
) {
	raw_as_string := transmute(string)raw_request

	first_line := true
	for line in strings.split_iterator(&raw_as_string, "\r\n") {
		if line == "" {break} 	// `/r/n/r/n`

		if first_line == true {
			first_line = false

			// GET /path?query HTTP/1.1
			first_line, split_err := strings.split(line, " ", alloc)
			if split_err != nil || len(first_line) < 2 {
				fmt.eprintfln("passed invalid header")
				return false
			}

			req_header.method = strings.trim_space(first_line[0])
			req_header.uri = strings.trim_space(first_line[1])

			uri_parts, _ := strings.split(req_header.uri, "?", alloc)
			req_header.path = uri_parts[0]
			if len(uri_parts) > 1 {
				req_header.query = uri_parts[1]
			}
			continue
		}

		// headers
		cln := strings.index_byte(line, ':') // colon
		if cln < 0 {
			fmt.eprintfln("malformed header line, ignoring")
			continue
		}

		label := strings.trim_space(line[:cln])
		value := strings.trim_space(line[cln + 1:])

		if strings.equal_fold(label, "Content-Length") {
			n, _ := strconv.parse_int(value)
			req_header.known_headers.content_length = n
		}
		if strings.equal_fold(label, "Accept") {
			req_header.known_headers.accept = parse_accept(value)
		}
		if strings.equal_fold(label, "Hx-Request") {
			req_header.known_headers.hx_request = value == "true"
		}

		req_header.headers[label] = value
	}

	return req_header.method != "" && req_header.path != ""
}


parse_accept :: proc(val: string) -> (accept: Accept) {
	it := val
	for item in strings.split_iterator(&it, ",") {
		token := strings.trim_space(item)
		if idx := strings.index_byte(token, ';'); idx >= 0 {
			token = strings.trim_space(token[:idx])
		}
		switch {
		case strings.equal_fold(token, "text/html"):
			accept += {.Html}
		case strings.equal_fold(token, "application/json"):
			accept += {.Json}
		case strings.equal_fold(token, "image/webp"):
			accept += {.Webp}
		case strings.equal_fold(token, "image/avif"):
			accept += {.Avif}
		case strings.equal_fold(token, "image/jpeg"):
			accept += {.Jpeg}
		case strings.equal_fold(token, "image/png"):
			accept += {.Png}
		case strings.equal_fold(token, "text/plain"):
			accept += {.Plain}
		case token == "*/*":
			accept += {.Any}
		}
	}
	return accept
}

MAX_BODY_SIZE :: 16 * 1024 * 1024

// Reads once into caller-owned storage. Returns bytes read, zero at EOF,
// or -1 on a socket error. The caller handles buffering and partial reads.
read_body :: proc(sock: net.TCP_Socket, body: []u8) -> int {
	if len(body) == 0 {
		return 0
	}
	n, err := net.recv_tcp(sock, body)
	if err != nil {
		return -1
	}
	return n
}

// Reads until body is full or EOF. Returns total bytes read, or -1 on a
// socket error. On EOF or error, body may be partially filled.
read_body_sync :: proc(sock: net.TCP_Socket, body: []u8) -> int {
	if len(body) == 0 {
		return 0
	}
	read := 0
	for read < len(body) {
		// should do handling of net.TCP_Recv_Error
		// here.
		n, err := net.recv_tcp(sock, body[read:])
		if err != nil {
			return -1
		}
		if n == 0 {
			return read
		}
		read += n
	}
	return read
}
