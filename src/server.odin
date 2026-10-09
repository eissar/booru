package main

import "core:bytes"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "cli"
import "http"
import "template"

// Loaded once at startup from the NDJSON event log; no DB for this prototype.
library_images: []template.Image
library_path: string

main :: proc() {

	// consider: `when ODIN_DEBUG { log.debug("debugging") }` on hot paths
	lvl := log.Level.Debug when ODIN_DEBUG else log.Level.Info
	context.logger = log.create_console_logger(
		lowest = lvl,
		opt = log.Options{.Level, .Short_File_Path, .Procedure, .Line},
	)
	defer log.destroy_console_logger(context.logger)

	cfg := cli.getFlags()
	library_path = cfg.library
	load_start := time.now()
	library_images = load_library(cfg.library)
	log.infof(
		"%d images loaded in %.2f ms: %s",
		len(library_images),
		time.duration_milliseconds(time.since(load_start)),
		cfg.library,
	)

	// net.parse_address
	sock, err := net.listen_tcp(net.Endpoint({net.IP4_Address{0, 0, 0, 0}, cfg.port}))
	if err != nil {
		log.fatal(err)
		os.exit(1)
	}

	// loop new client conns
	for conn, src, err := net.accept_tcp(sock); err == nil; conn, src, err = net.accept_tcp(sock) {
		_ = src

		// just read into a 16 kb slice
		raw: [16 * 1024]byte

		bytes_read, err := net.recv_tcp(conn, raw[:])
		if err != nil {
			log.error("recv error:", err)
			net.close(conn)
			continue
		}

		// intermediate buffer
		ib: bytes.Buffer
		bytes.buffer_init(&ib, raw[:bytes_read])

		req, ok := http.read_header(conn, &ib)
		if !ok {
			resp := "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
			continue
		}

		if req.method != "GET" {
			resp := "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nAllow: GET\r\n\r\n"
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
			continue
		}

		if req.known_headers.content_length > 0 {
			http.read_body(req, conn, &ib)
		}

		if req.path == "/" || req.path == "/gallery" {
			handle_gallery(req, conn)
			continue
		}

		if req.path == "/fragment/gallery-content" {
			handle_fragment_gallery_content(req, conn)
			continue
		}
		if req.path == "/fragment/items" {
			handle_fragment_items(req, conn)
			continue
		}
		if strings.starts_with(req.path, "/fragment/inspect/") {
			handle_fragment_inspect(req, conn)
			continue
		}
		if strings.starts_with(req.path, "/image/") {
			handle_image(req, conn)
			continue
		}
		if strings.starts_with(req.path, "/static/") {
			handle_static(req, conn)
			continue
		}

		// fallback
		resp := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}
