package thumbnail

import "core:io"
import "core:net"


Thumb :: struct {
	bytes:  []u8, // Complete standalone WebP file; backing memory owned by caller.
	width:  u16le, // Actual thumbnail dimensions, not minus-one encoded values.
	height: u16le,
}

NOT_FOUND_64_WEBP :: #load("../../static/not_found_64.webp")
NOT_FOUND_128_WEBP :: #load("../../static/not_found_128.webp")
UNSUPPORTED_FILETYPE_64_WEBP :: #load("../../static/unsupported_filetype_64.webp")
UNSUPPORTED_FILETYPE_128_WEBP :: #load("../../static/unsupported_filetype_128.webp")
new_not_found_thumb :: proc(resolution: u16le) -> Thumb {
	if resolution == 128 {
		return Thumb{transmute([]u8)NOT_FOUND_128_WEBP, 128, 128}
	}
	return Thumb{transmute([]u8)NOT_FOUND_64_WEBP, 64, 64}
}


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
