package main

import "core:bytes"
import "core:encoding/json"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"

import "http"

main :: proc() {
	// consider: `when ODIN_DEBUG { log.debug("debugging") }` on hot paths
	lvl := log.Level.Debug when ODIN_DEBUG else log.Level.Info
	context.logger = log.create_console_logger(
		lowest = lvl,
		opt = log.Options{.Level, .Short_File_Path, .Procedure, .Line},
	)
	defer log.destroy_console_logger(context.logger)

	cfg := getFlags()

	// if cfg.rebuildindex

	// net.parse_address
	// sock, err := net.listen_tcp(net.Endpoint({net.IP4_Address{127, 0, 0, 1}, cfg.port}))
	sock, err := net.listen_tcp(net.Endpoint({net.IP4_Address{0, 0, 0, 0}, cfg.port}))
	if err != nil {
		// #partial switch e in err {
		//     case net.Bind_Error ?
		// }
		log.fatal(err)
		os.exit(1)
	}

	// loop new client conns
	for conn, src, err := net.accept_tcp(sock); err == nil; conn, src, err = net.accept_tcp(sock) {
		// just read into a 16 kb slice
		raw: [16 * 1024]byte

		bytes_read, err := net.recv_tcp(conn, raw[:])
		if err != nil {
			// #partial switch e in err {
			//     case net.Bind_Error ?
			// }
			log.fatal(err)
			os.exit(1)
		}

		// intermediate buffer
		ib: bytes.Buffer
		bytes.buffer_init(&ib, raw[:bytes_read])

		// bytes_read: int
		req := http.read_header(conn, &ib)

		if req.content_len > 0 {
			if req.headers["Content-Type"] != "application/json" {
				resp := "HTTP/1.1 415 Unsupported Media Type\r\nContent-Length: 0\r\n\r\n"
				net.send_tcp(conn, transmute([]u8)resp)
				net.close(conn)
				continue
			}

			http.read_body(req, conn, &ib)
		}


		if req.path == "/" {
			handle_root(req, conn)
			continue
		}
		if req.path == "/gallery" {
			handle_gallery(req, conn)
			continue
		}

		if strings.starts_with(req.path, "/static/") {
			handle_static(req, conn)
			continue
		}

		// fallback
		resp := "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		continue
	}
}
