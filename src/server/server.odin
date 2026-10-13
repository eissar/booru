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

		res := http.Response {
			headers = make(map[string]string, context.temp_allocator),
		}

		req, ok := http.read_header(conn, &ib)
		if !ok {
			http.res_error("", &res, .BadRequest)
			http.marshal_and_send(conn, res, context.allocator)
			continue
		}

		if req.method != "GET" {
			http.res_error("", &res, .MethodNotAllowed)
			http.marshal_and_send(conn, res, context.allocator)
			continue
		}

		length := req.known_headers.content_length
		if length < 0 || length > http.MAX_BODY_SIZE {
			log.error("read body:", "invalid content-length from req of:", length)

			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, context.temp_allocator); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}

		body := make([]u8, length, context.temp_allocator)
		defer delete(body, context.temp_allocator)
		n := copy(body, ib.buf[ib.off:])
		received := http.read_body_sync(conn, body[n:])
		if received < 0 {
			log.error("read body:", "failed to receive request body")
			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, context.temp_allocator); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}
		if received != length - n {
			log.error("read body:", "connection closed before request body was complete")
			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, context.temp_allocator); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}

		switch {
		case req.path == "/" || req.path == "/gallery":
			handle_gallery(s, &res, req)
		case req.path == "/fragment/gallery-content":
			handle_fragment_gallery_content(s, &res, req)
		case req.path == "/fragment/items":
			handle_fragment_items(s, &res, req)
		case strings.starts_with(req.path, "/fragment/inspect/"):
			handle_fragment_inspect(s, &res, req)
		case strings.starts_with(req.path, "/mipmap/"):
			handle_mipmap(s, &res, {req, context.temp_allocator, rec_time}, body)
		case strings.starts_with(req.path, "/image/"):
			handle_image(s, &res, req)
		case strings.starts_with(req.path, "/static/"):
			handle_static(&res, req)
		case:
			http.res_text("Not Found", &res, .NotFound)
		}
		if err := http.marshal_and_send(conn, res, context.temp_allocator); err != nil {
			log.error("send response:", err)
		}
		net.close(conn)
	}
}
