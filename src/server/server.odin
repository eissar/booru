package server

import "core:bytes"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"

import "../http"
import "../library"

// Serve handles requests on an already-listening socket until accept fails.
// The caller owns the socket and must initialize library_path and library_images.
Serve :: proc(s: library.State, sock: net.TCP_Socket) {
	// loop new client conns
	for conn, src, err := net.accept_tcp(sock); err == nil; conn, src, err = net.accept_tcp(sock) {

		// just read into a 16 kb slice
		raw: [16 * 1024]byte

		rec_time := time.now()
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
			handle_gallery(s, req, conn)
			continue
		}

		if req.path == "/fragment/gallery-content" {
			handle_fragment_gallery_content(s, req, conn)
			continue
		}
		if req.path == "/fragment/items" {
			handle_fragment_items(s, req, conn)
			continue
		}
		if strings.starts_with(req.path, "/fragment/inspect/") {
			handle_fragment_inspect(s, req, conn)
			continue
		}
		if strings.starts_with(req.path, "/mipmap/") {
			handle_mipmap(s, {req, context.allocator, rec_time}, conn)
			continue
		}
		if strings.starts_with(req.path, "/image/") {
			handle_image(s, req, conn)
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
