package http

import "core:bytes"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
// https://www.man7.org/linux/man-pages/man2/recv.2.html

// bikeshed: store byte offsets/ lazy read somehow?
Header :: struct {
	method:      string,
	uri:         string,
	path:        string,
	query:       string, // raw query string, "" when absent
	content_len: int,
	headers:     map[string]string,
}

read_header :: proc(sock: net.TCP_Socket, buf: ^bytes.Buffer) -> (header: Header, ok: bool) {
	header.headers = make(map[string]string)

	{ 	// first line

		fl, ib_err := bytes.buffer_read_string(buf, '\n')
		if ib_err != nil {
			log.error(ib_err)
			return header, false
		}

		fl = strings.trim_right(fl, "\r\n")

		// GET /path?query HTTP/1.1
		first_line, split_err := strings.split(fl, " ")
		if split_err != nil || len(first_line) < 2 {
			log.error("passed invalid header")
			return header, false
		}
		header.method = strings.trim_space(first_line[0])
		header.uri = strings.trim_space(first_line[1])

		uri_parts, _ := strings.split(header.uri, "?")
		header.path = uri_parts[0]
		if len(uri_parts) > 1 {
			header.query = uri_parts[1]
		}
	}

	for { 	// other headers
		line, ib_err := bytes.buffer_read_string(buf, '\n')
		if ib_err != nil {
			// EOF without the terminating blank line: tolerate it if we
			// already collected headers, otherwise reject.
			break
		}

		line = strings.trim_right(line, "\r\n")
		if line == "" {
			break
		}

		colon := strings.index_byte(line, ':')
		if colon < 0 {
			log.error("malformed header line, ignoring")
			continue
		}
		label := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		header.headers[label] = value

		if label == "Content-Length" {
			n, _ := strconv.parse_int(value)
			// don't bother check ok
			header.content_len = n
		}
	}

	ok = header.method != "" && header.path != ""
	return header, ok
}

read_body :: proc(req: Header, sock: net.TCP_Socket, buf: ^bytes.Buffer) -> (err: string) {
	// TODO: make non case sensitive
	chunk := bytes.buffer_next(buf, req.content_len)

	_ = chunk
	return ""
}
