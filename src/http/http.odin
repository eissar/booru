package http

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
// https://www.man7.org/linux/man-pages/man2/recv.2.html

// bikeshed: store byte offsets/ lazy read somehow?
Header :: struct {
	method: string,
	uri:    string,
	path:   string,
}

NEWLINE_DELIMITER := "\r\n"
HEADER_TERMINATOR := "\r\n\r\n"

read_header :: proc(sock: net.TCP_Socket, buf: []byte) -> (header: Header, offset: int) {
	_, err := net.recv_tcp(sock, buf)
	if err != nil {
		// #partial switch e in err {
		//     case net.Bind_Error ?
		// }
		log.fatal(err)
		os.exit(1)
	}


	{
		first_line_offset := bytes.index(buf, transmute([]byte)NEWLINE_DELIMITER)
		if offset == -1 {
			log.fatal("passed invalid header")
			os.exit(1)
		}
		// GET / HTTP/1.1
		first_line, err := strings.split(transmute(string)buf[:first_line_offset], " ")
		if err != nil {
			log.fatal("passed invalid header")
			os.exit(1)
		}

		header.method = strings.trim_space(first_line[0])
		header.uri = strings.trim_space(first_line[1])
		header.path = strings.split(first_line[1], "?")[0]

	}

	// we save a little bit by using the offset ?
	offset = bytes.index(buf, transmute([]byte)HEADER_TERMINATOR)
	if offset == -1 {
		// TODO: don't crash here
		log.fatal("passed invalid header")
		os.exit(1)
	}

	return header, offset
}
