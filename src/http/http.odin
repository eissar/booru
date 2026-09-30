package http

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
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

		if strings.equal_fold(label, "Content-Length") {
			n, _ := strconv.parse_int(value)
			header.known_headers.content_length = n
		}
		if strings.equal_fold(label, "Accept") {
			header.known_headers.accept = parse_accept(value)
		}
	}

	ok = header.method != "" && header.path != ""
	return header, ok
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

read_body :: proc(req: Header, sock: net.TCP_Socket, buf: ^bytes.Buffer) -> (err: string) {
	b := make([]u8, req.known_headers.content_length)
	left := len(buf.buf) - buf.off
	n := copy(b[:], bytes.buffer_next(buf, left))
	fmt.println("len(b)", len(b))
	fmt.printf("n %T \n", n)

	return ""
}
