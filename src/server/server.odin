package server

import "core:bytes"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

import "../http"
import "../library"
import "../template"

REQUEST_ARENA_BACKING_SIZE :: 1 * mem.Megabyte + http.MAX_BODY_SIZE

// Serve handles requests on an already-listening socket until accept fails.
// The caller owns the socket and must initialize library_path and library_images.
Serve :: proc(s: library.State, sock: net.TCP_Socket) {

	backing, err := make([]u8, REQUEST_ARENA_BACKING_SIZE, context.allocator)
	assert(err != nil)
	defer delete(backing, context.allocator)

	arena: mem.Arena
	// request scoped arena, we free_all explicitly before each conn
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	// loop new client conns
	for conn, src, err := net.accept_tcp(sock, net.DEFAULT_TCP_OPTIONS);
	    err == nil;
	    conn, src, err = net.accept_tcp(sock, net.DEFAULT_TCP_OPTIONS) {

		free_all(alloc)

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
			headers = make(map[string]string, alloc),
		}


		req: http.Header
		req.headers = make(map[string]string, alloc)


		ok := http.read_header(conn, &ib, &req, alloc)
		if !ok {
			http.res_error("", &res, .BadRequest)
			http.marshal_and_send(conn, res, alloc)
			continue
		}

		length := req.known_headers.content_length
		if length < 0 || length > http.MAX_BODY_SIZE {
			log.error("read body:", "invalid content-length from req of:", length)

			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, alloc); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}

		body := make([]u8, length, alloc)
		// defer delete(body, alloc)

		n := copy(body, ib.buf[ib.off:])
		received := http.read_body_sync(conn, body[n:])
		if received < 0 {
			log.error("read body:", "failed to receive request body")
			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, alloc); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}
		if received != length - n {
			log.error("read body:", "connection closed before request body was complete")
			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, alloc); err != nil {
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
		case req.path == "/ingest":
			handle_ingest(s, &res, {req, alloc, rec_time}, body)
		case strings.starts_with(req.path, "/fragment/inspect/"):
			handle_fragment_inspect(s, &res, req)
		case strings.starts_with(req.path, "/mipmap/"):
			handle_mipmap(s, &res, {req, alloc, rec_time}, body)
		case strings.starts_with(req.path, "/image/"):
			handle_image(s, &res, req)
		case strings.starts_with(req.path, "/static/"):
			handle_static(&res, req)
		// 404 cases
		case req.known_headers.hx_request:
			res.headers["Vary"] = "Hx-Request"
			http.res_html(template.render_toast("Not Found", .Error), &res, .NotFound)
		case:
			res.headers["Vary"] = "Hx-Request"
			http.res_text("Not Found", &res, .NotFound)
		}
		if err := http.marshal_and_send(conn, res, alloc); err != nil {
			log.error("send response:", err)
		}

		net.close(conn)
	}
}
