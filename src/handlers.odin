package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "http"
import "render"
import "template"

handle_root :: proc(req: http.Header, conn: net.TCP_Socket) {
	resp: string
	body := render.render_gallery_page(
		"Gallery",
		render.Renderer_Version,
		template.Gallery_Filter{limit = 25, sort = "idDesc"},
		nil,
		false,
	)
	resp = fmt.tprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\n\r\n%s",
		len(body),
		body,
	)
	net.send_tcp(conn, transmute([]u8)resp)
	net.close(conn)
}


handle_static :: proc(req: http.Header, conn: net.TCP_Socket) {
	resp: string
	rp := strings.split(req.path, "/")
	leaf := rp[len(rp) - 1]

	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") || len(leaf) < 3 {
		resp = "HTTP/1.1 404 Bad Request\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}

	local_fp := strings.join({"./static/", leaf}, "")
	data, success := os.read_entire_file(local_fp)
	if !success {
		resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}
	header := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", len(data))
	net.send_tcp(conn, transmute([]u8)header)
	net.send_tcp(conn, data)
	net.close(conn)
}
