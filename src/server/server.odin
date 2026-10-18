package server

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
// The caller owns the socket.
Serve :: proc(s: ^library.State, sock: net.TCP_Socket) {
	backing, err := make([]u8, REQUEST_ARENA_BACKING_SIZE, context.allocator)
	assert(err == nil)
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
		free_all(context.temp_allocator) // TODO: fix

		// just read into a 16 kb slice
		raw: [16 * 1024]byte


		rec_time := time.now()
		// todo: make more robust;
		// the header/ body handling
		// is ugly
		bytes_read, err := net.recv_tcp(conn, raw[:])
		if err != nil {
			log.error("recv error:", err)
			net.close(conn)
			continue
		}

		res := http.Response {
			headers = make(map[string]string, alloc),
		}
		// set this for all requests until we implement
		// keep alive support
		res.headers["Connection"] = "close"

		request_bytes := raw[:bytes_read]

		// todo rename
		req_header: http.Header
		req_header.headers = make(map[string]string, alloc)
		ok := http.read_header(conn, &req_header, request_bytes, alloc)

		if !ok {
			http.res_error("", &res, .BadRequest)
			http.marshal_and_send(conn, res, alloc)
			net.close(conn)
			continue
		}

		req: http.Req = {req_header, alloc, rec_time}

		length := req_header.known_headers.content_length
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

		// probably can do this more efficiently
		// for now, just strings. index of /r/n/r/n
		// offset of the
		off := strings.index(transmute(string)request_bytes, "\r\n\r\n")
		if off == -1 {
			// bad request
			http.res_error("Bad Request", &res, status = .BadRequest)
			if err := http.marshal_and_send(conn, res, alloc); err != nil {
				log.error("send response:", err)
			}
			net.close(conn)
			continue
		}

		n := copy(body, request_bytes[off + 4:])
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
		case req_header.path == "/" || req_header.path == "/gallery":
			handle_gallery(s^, &res, req)
		case req_header.path == "/fragment/gallery-content":
			handle_fragment_gallery_content(s^, &res, req)
		case req_header.path == "/fragment/items":
			handle_fragment_items(s^, &res, req)
		case req_header.path == "/regen-thumbnail":
			handle_regen_thumbnail(s, &res, req)
		case req_header.path == "/ingest":
			handle_ingest(s, &res, {req_header, alloc, rec_time}, body)
		case req_header.path == "/delete":
			handle_delete(s, &res, {req_header, alloc, rec_time}, body)
		case strings.starts_with(req_header.path, "/fragment/inspect/"):
			handle_fragment_inspect(s^, &res, req)
		case strings.starts_with(req_header.path, "/mipmap/"):
			handle_mipmap(s^, &res, {req_header, alloc, rec_time}, body)
		case strings.starts_with(req_header.path, "/image/"):
			handle_image(s^, &res, req)
		case strings.starts_with(req_header.path, "/static/"):
			handle_static(&res, req)
		// 404 cases
		case req_header.known_headers.hx_request:
			context.allocator = req.alloc
			res.headers["Vary"] = "Hx-Request"
			res.headers["HX-Reswap"] = "beforeend"
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
