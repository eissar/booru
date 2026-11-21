package server

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

import "../http"
import "../library"
import "../progress"
import "../template"

// TODO: put /dev/* behind a flag or a runtime global; enabled unconditionally
// while prototyping.
DEV_ROUTES :: true

REQUEST_ARENA_BACKING_SIZE :: 1 * mem.Megabyte + http.MAX_BODY_SIZE
RECV_POLL_INTERVAL :: time.Second
IDLE_TIMEOUT :: 10 * time.Second
REQUEST_TIMEOUT :: 30 * time.Second

Conn_Slot :: struct {
	backing: []u8,
	arena:   mem.Arena,
	raw:     [16 * 1024]byte,
	conn:    net.TCP_Socket,
	req:     http.Req,
	res:     http.Response,
}

Accept_Proc :: #type proc(sock: net.TCP_Socket) -> (net.TCP_Socket, bool)

accept_tcp :: proc(sock: net.TCP_Socket) -> (net.TCP_Socket, bool) {
	conn, _, err := net.accept_tcp(sock, net.DEFAULT_TCP_OPTIONS)
	return conn, err == nil
}

// Serve handles requests on an already-listening socket until accept fails.
// The caller owns the socket.
Serve :: proc(s: ^library.State, sock: net.TCP_Socket, accept: Accept_Proc = accept_tcp) {
	bitlist := ~Bitlist{}
	slots := make([]Conn_Slot, 64, context.allocator)
	defer {
		for i in 0 ..< len(slots) {
			if len(slots[i].backing) > 0 {
				delete(slots[i].backing, context.allocator)
			}
		}
		delete(slots, context.allocator)
	}

	if accept == accept_tcp {
		if ep, endpoint_err := net.bound_endpoint(sock); endpoint_err == nil {
			when ODIN_TEST {
				log.debugf("server listening on http://%v", net.endpoint_to_string(ep))
			} else {
				fmt.eprintfln("server listening on http://%v", net.endpoint_to_string(ep))
			}
		}
	}

	// loop new client conns
	for conn, accepted := accept(sock); accepted; conn, accepted = accept(sock) {
		idx, slot_ok := acquire(&bitlist)
		if !slot_ok {
			net.close(conn)
			continue
		}
		slot := &slots[idx]
		if len(slot.backing) == 0 {
			err: mem.Allocator_Error
			slot.backing, err = make([]u8, REQUEST_ARENA_BACKING_SIZE, context.allocator)
			assert(err == nil)
			mem.arena_init(&slot.arena, slot.backing)
		}
		alloc := mem.arena_allocator(&slot.arena)
		slot.conn = conn

		free_all(alloc)
		free_all(context.temp_allocator) // TODO: fix

		rec_time := time.now()
		if opt_err := net.set_option(slot.conn, .Receive_Timeout, RECV_POLL_INTERVAL);
		   opt_err != nil {
			fmt.eprintfln("set_option Receive_Timeout: %v", opt_err)
		}

		total_read: int
		header_end_idx := -1
		header_complete: bool
		recv_failed: bool
		for total_read < len(slot.raw) {
			n, recv_err := net.recv_tcp(slot.conn, slot.raw[total_read:])
			if recv_err == .Timeout || recv_err == .Would_Block {
				elapsed := time.since(rec_time)
				limit := total_read == 0 ? IDLE_TIMEOUT : REQUEST_TIMEOUT
				if elapsed > limit {
					recv_failed = true
					break
				}
				continue
			}
			if recv_err != nil {
				fmt.eprintln("recv error:", recv_err)
				recv_failed = true
				break
			}
			if n == 0 {break}
			total_read += n

			if idx_found := bytes.index(slot.raw[:total_read], []u8{'\r', '\n', '\r', '\n'});
			   idx_found >= 0 {
				header_end_idx = idx_found
				header_complete = true
				break
			}
		}

		if recv_failed || total_read == 0 {
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		}

		slot.res = http.Response {
			headers = make(map[string]string, alloc),
		}
		// set this for all requests until we implement
		// keep alive support
		slot.res.headers["Connection"] = "close"

		slot.req = http.Req {
			alloc    = alloc,
			rec_time = rec_time,
		}
		slot.req.header.headers = make(map[string]string, alloc)
		header_ok :=
			header_complete &&
			http.read_header(slot.conn, &slot.req.header, slot.raw[:header_end_idx + 4], alloc)

		has_transfer_encoding := false
		for name in slot.req.header.headers {
			if strings.equal_fold(name, "Transfer-Encoding") {
				has_transfer_encoding = true
				break
			}
		}

		length := slot.req.header.known_headers.content_length
		body_too_large := header_ok && length > http.MAX_BODY_SIZE

		switch {
		case !header_complete && total_read >= len(slot.raw):
			http.res_error("request too large.", &slot.res, .RequestHeaderFieldsTooLarge)
			if send_err := http.marshal_and_send(slot.conn, slot.res, alloc); send_err != nil {
				fmt.eprintln("send response:", send_err)
			}
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		case !header_ok || length < 0:
			http.res_error("", &slot.res, .BadRequest)
			if send_err := http.marshal_and_send(slot.conn, slot.res, alloc); send_err != nil {
				fmt.eprintln("send response:", send_err)
			}
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		case has_transfer_encoding:
			http.res_error("Transfer-Encoding not supported.", &slot.res, .NotImplemented)
			if send_err := http.marshal_and_send(slot.conn, slot.res, alloc); send_err != nil {
				fmt.eprintln("send response:", send_err)
			}
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		case body_too_large:
			http.res_error("request body too large.", &slot.res, .ContentTooLarge)
			if send_err := http.marshal_and_send(slot.conn, slot.res, alloc); send_err != nil {
				fmt.eprintln("send response:", send_err)
			}
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		}

		body := make([]u8, length, alloc)
		body_read := copy(body, slot.raw[header_end_idx + 4:total_read])
		for body_read < length {
			n, recv_err := net.recv_tcp(slot.conn, body[body_read:])
			if recv_err == .Timeout || recv_err == .Would_Block {
				if time.since(rec_time) > REQUEST_TIMEOUT {
					recv_failed = true
					break
				}
				continue
			}
			if recv_err != nil {
				fmt.eprintln("recv body:", recv_err)
				recv_failed = true
				break
			}
			if n == 0 {break}
			body_read += n
		}
		if recv_failed || body_read < length {
			http.res_error("incomplete request body.", &slot.res, .BadRequest)
			if send_err := http.marshal_and_send(slot.conn, slot.res, alloc); send_err != nil {
				fmt.eprintln("send response:", send_err)
			}
			net.close(slot.conn)
			release(&bitlist, idx)
			continue
		}

		res := &slot.res
		req := slot.req
		req_header := req.header

		// TODO: put behind a flag or a runtime global that switches on dynamic
		// Lua loading; enabled unconditionally while prototyping.
		when true {
			if lua_handle(res, req, body) {
				if err := http.marshal_and_send(slot.conn, res^, alloc); err != nil {
					fmt.eprintln("send response:", err)
				}
				net.close(slot.conn)
				release(&bitlist, idx)
				continue
			}
		}

		switch {
		case req_header.method == "POST" && progress.is_active("startup"):
			res.headers["Retry-After"] = "5"
			res.headers["Vary"] = "Hx-Request"
			if req_header.known_headers.hx_request {
				res.headers["HX-Reswap"] = "beforeend"
				http.res_html(
					template.render_toast(
						"Server starting up, try again shortly",
						.Error,
						req.alloc,
					),
					res,
					.ServiceUnavailable,
				)
			} else {
				http.res_text("Service Unavailable", res, .ServiceUnavailable)
			}
		case req_header.path == "/" || req_header.path == "/gallery":
			handle_gallery(s^, res, req)
		case req_header.path == "/fragment/gallery-content":
			handle_fragment_gallery_content(s^, res, req)
		case req_header.path == "/fragment/items":
			handle_fragment_items(s^, res, req)
		case req_header.path == "/api/events":
			handle_events(s^, res, req)
		case req_header.path == "/events/progress":
			handle_sse_progress(res)
		case req_header.path == "/duplicates":
			handle_duplicates(s^, res, req)
		case req_header.path == "/merge":
			handle_merge(s, res, req, body)
		case req_header.path == "/regen-thumbnail":
			handle_regen_thumbnail(s, res, req)
		case req_header.path == "/ingest":
			handle_ingest(s, res, req, body)
		case req_header.path == "/delete":
			handle_delete(s, res, req, body)
		case req_header.path == "/update-metadata":
			handle_update_metadata(s, res, req, body)
		case DEV_ROUTES && req_header.path == "/dev/preview":
			handle_dev_preview(s^, res, req)
		case DEV_ROUTES && req_header.path == "/dev/preview/mtime":
			handle_dev_preview_mtime(res, req)
		case strings.starts_with(req_header.path, "/fragment/inspect/"):
			handle_fragment_inspect(s^, res, req)
		case strings.starts_with(req_header.path, "/mipmap/"):
			handle_mipmap(s^, res, req, body)
		case strings.starts_with(req_header.path, "/image/"):
			handle_image(s^, res, req)
		case strings.starts_with(req_header.path, "/static/"):
			handle_static(res, req)
		// 404 cases
		case req_header.known_headers.hx_request:
			res.headers["Vary"] = "Hx-Request"
			res.headers["HX-Reswap"] = "beforeend"
			http.res_html(template.render_toast("Not Found", .Error, req.alloc), res, .NotFound)
		case:
			res.headers["Vary"] = "Hx-Request"
			http.res_text("Not Found", res, .NotFound)
		}


		if err := http.marshal_and_send(slot.conn, res^, alloc); err != nil {
			fmt.eprintln("send response:", err)
		}

		net.close(slot.conn)
		release(&bitlist, idx)
	}
}
