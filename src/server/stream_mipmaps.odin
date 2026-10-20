package server

import "core:io"
import "core:net"

@(private = "file")
socket_writer_proc :: proc(
	data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	socket := (^net.TCP_Socket)(data)

	#partial switch mode {
	case .Write:
		bw, send_err := net.send_tcp(socket^, p)
		if send_err != nil {
			return i64(bw), .Unknown
		}
		if bw != len(p) {
			return i64(bw), .Short_Write
		}
		return i64(bw), nil

	case .Flush:
		// This adapter has no buffer of its own.
		return 0, nil

	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}

	return 0, .Unsupported
}

socket_writer :: proc(socket: ^net.TCP_Socket) -> io.Writer {
	return {procedure = socket_writer_proc, data = socket}
}
