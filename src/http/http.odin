package http

import "core:bytes"
import "core:fmt"
import "core:io"
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
	content_len: int,
	headers:     map[string]string,
}

SLASH_R := "\r"
NEWLINE_DELIMITER := []u8{'\r', '\n'}
HEADER_TERMINATOR := []u8{'\r', '\n', '\r', '\n'}

read_header :: proc(sock: net.TCP_Socket, buf: ^bytes.Buffer) -> (header: Header) {

	{ 	// first line

		fl, ib_err := bytes.buffer_read_string(buf, '\n')
		if ib_err != nil {
			log.fatal(ib_err)
			os.exit(1)
		}

		fl = strings.trim_right(fl, "\r")
		fmt.println(fl)

		// GET / HTTP/1.1
		first_line, split_err := strings.split(fl, " ")

		if split_err != nil {
			log.fatal("passed invalid header")
			os.exit(1)
		}
		header.method = strings.trim_space(first_line[0])
		header.uri = strings.trim_space(first_line[1])
		header.path = strings.split(first_line[1], "?")[0]
	}

	line: string
	for { 	// other headers
		line, ib_err := bytes.buffer_read_string(buf, '\n')
		if ib_err != nil {
			fmt.println("ERROR")
			break
		}

		if line == "\r\n" {
			break
		}

		label := strings.trim_space(strings.split(line, ":")[0])
		value := strings.trim_space(strings.split(line, ":")[1])

		header.headers[label] = value

		if label == "Content-Length" {
			n, _ := strconv.parse_int(value)
			// don't bother check ok
			header.content_len = n
			continue
		}
	}

	fmt.printfln("%v", header)
	return header
}

read_body :: proc(req: Header, sock: net.TCP_Socket, buf: ^bytes.Buffer) -> (err: string) {
	// TODO: make non case sensitive
	chunk := bytes.buffer_next(buf, req.content_len)

	fmt.printfln("%v", string(chunk))
	return ""
}
