package cdp_test

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Route :: struct {
	path:         string,
	content_type: string,
	body:         string,
	prefix:       bool,
}

Server :: struct {
	sock:    net.TCP_Socket,
	port:    int,
	routes:  []Route,
	running: bool,
	thr:     ^thread.Thread,
}

Browser :: struct {
	sock:        net.TCP_Socket,
	process:     os.Process,
	profile_dir: string,
	base_url:    string,
	next_id:     int,
	load_fired:  bool,
	closed:      bool,
}

// --- HTTP Fixture Server (immutable routes slice, stack-only per request) ---

server_loop :: proc(data: rawptr) {
	s := cast(^Server)data
	buf: [8192]u8
	hdr_buf: [512]u8
	for sync.atomic_load(&s.running) {
		client, _, err := net.accept_tcp(s.sock)
		if err != nil {
			continue
		}
		n, rerr := net.recv_tcp(client, buf[:])
		if rerr == nil && n > 0 {
			req := string(buf[:n])
			path := "/"
			if sp1 := strings.index_byte(req, ' '); sp1 >= 0 {
				rest := req[sp1 + 1:]
				if sp2 := strings.index_byte(rest, ' '); sp2 >= 0 {
					path = rest[:sp2]
				}
			}
			if q := strings.index_byte(path, '?'); q >= 0 {
				path = path[:q]
			}
			matched: Route
			found := false
			for r in s.routes {
				if (r.prefix && strings.has_prefix(path, r.path)) ||
				   (!r.prefix && path == r.path) {
					matched = r
					found = true
					break
				}
			}
			if found {
				hdr := fmt.bprintf(
					hdr_buf[:],
					"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
					matched.content_type,
					len(matched.body),
				)
				send_all(client, transmute([]u8)hdr)
				send_all(client, transmute([]u8)matched.body)
			} else {
				not_found := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
				net.send_tcp(client, transmute([]u8)not_found)
			}
		}
		net.close(client)
	}
}

start_server :: proc(routes: []Route, alloc: mem.Allocator) -> (^Server, bool) {
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		return nil, false
	}
	bound, berr := net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return nil, false
	}
	s := new(Server, alloc)
	s.sock = sock
	s.port = bound.port
	s.routes = routes
	sync.atomic_store(&s.running, true)
	s.thr = thread.create_and_start_with_data(s, server_loop)
	return s, true
}

stop_server :: proc(s: ^Server) {
	if s == nil || !sync.atomic_load(&s.running) {
		return
	}
	sync.atomic_store(&s.running, false)
	if wake, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = s.port});
	   err == nil {
		net.close(wake)
	}
	net.close(s.sock)
	thread.join(s.thr)
	thread.destroy(s.thr)
}

// --- WebSocket (RFC 6455, local ws://127.0.0.1) ---

recv_exact :: proc(sock: net.TCP_Socket, dst: []u8) -> bool {
	off := 0
	for off < len(dst) {
		n, err := net.recv_tcp(sock, dst[off:])
		if err != nil || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

ws_connect :: proc(ws_url: string) -> (net.TCP_Socket, bool) {
	if !strings.has_prefix(ws_url, "ws://") {
		return {}, false
	}
	rest := ws_url[5:]
	slash := strings.index_byte(rest, '/')
	host_port := rest if slash < 0 else rest[:slash]
	path := "/" if slash < 0 else rest[slash:]
	colon := strings.index_byte(host_port, ':')
	if colon < 0 {
		return {}, false
	}
	port, pok := strconv.parse_int(host_port[colon + 1:])
	if !pok {
		return {}, false
	}

	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		return {}, false
	}

	nonce: [16]u8
	crypto.rand_bytes(nonce[:])
	key := base64.encode(nonce[:], allocator = context.temp_allocator)
	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path,
		host_port,
		key,
	)
	if !send_all(sock, transmute([]u8)req) {
		net.close(sock)
		return {}, false
	}

	hdr_buf: [4096]u8
	hdr_len := 0
	for hdr_len < len(hdr_buf) {
		n, rerr := net.recv_tcp(sock, hdr_buf[hdr_len:])
		if rerr != nil || n <= 0 {
			net.close(sock)
			return {}, false
		}
		hdr_len += n
		if strings.contains(string(hdr_buf[:hdr_len]), "\r\n\r\n") {
			break
		}
	}
	if !strings.has_prefix(string(hdr_buf[:hdr_len]), "HTTP/1.1 101") {
		net.close(sock)
		return {}, false
	}
	return sock, true
}

ws_send_frame :: proc(sock: net.TCP_Socket, opcode: u8, payload: []u8) -> bool {
	hdr: [14]u8
	hdr_len := 0
	hdr[0] = 0x80 | opcode
	n := len(payload)
	if n < 126 {
		hdr[1] = 0x80 | u8(n)
		hdr_len = 2
	} else if n <= 65535 {
		hdr[1] = 0x80 | 126
		endian.put_u16(hdr[2:4], .Big, u16(n))
		hdr_len = 4
	} else {
		hdr[1] = 0x80 | 127
		endian.put_u64(hdr[2:10], .Big, u64(n))
		hdr_len = 10
	}
	mask: [4]u8
	crypto.rand_bytes(mask[:])
	copy(hdr[hdr_len:hdr_len + 4], mask[:])
	hdr_len += 4

	if !send_all(sock, hdr[:hdr_len]) {
		return false
	}
	if n == 0 {
		return true
	}
	masked := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		masked[i] = payload[i] ~ mask[i & 3]
	}
	return send_all(sock, masked)
}

ws_recv_text :: proc(sock: net.TCP_Socket) -> (string, bool) {
	msg := make([dynamic]u8, context.temp_allocator)
	for {
		hdr: [2]u8
		if !recv_exact(sock, hdr[:]) {
			return "", false
		}
		fin := (hdr[0] & 0x80) != 0
		opcode := hdr[0] & 0x0f
		masked := (hdr[1] & 0x80) != 0
		plen := u64(hdr[1] & 0x7f)
		if plen == 126 {
			ext: [2]u8
			if !recv_exact(sock, ext[:]) {return "", false}
			val, _ := endian.get_u16(ext[:], .Big)
			plen = u64(val)
		} else if plen == 127 {
			ext: [8]u8
			if !recv_exact(sock, ext[:]) {return "", false}
			val, _ := endian.get_u64(ext[:], .Big)
			plen = val
		}
		mask: [4]u8
		if masked && !recv_exact(sock, mask[:]) {
			return "", false
		}
		payload := make([]u8, int(plen), context.temp_allocator)
		if plen > 0 && !recv_exact(sock, payload) {
			return "", false
		}
		if masked {
			for i in 0 ..< len(payload) {
				payload[i] ~= mask[i & 3]
			}
		}
		switch opcode {
		case 0x8:
			return "", false
		case 0x9:
			ws_send_frame(sock, 0xA, payload)
		case 0xA:
			continue
		case 0x0, 0x1:
			append(&msg, ..payload)
			if fin {
				return string(msg[:]), true
			}
		}
	}
}

// --- Chromium + CDP ---

http_get_local :: proc(port: int, path: string) -> (string, bool) {
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		return "", false
	}
	defer net.close(sock)
	req := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n",
		path,
		port,
	)
	if !send_all(sock, transmute([]u8)req) {
		return "", false
	}
	out := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	content_len := -1
	hdr_end := -1
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			append(&out, ..buf[:n])
			s := string(out[:])
			if hdr_end < 0 {
				if sep := strings.index(s, "\r\n\r\n"); sep >= 0 {
					hdr_end = sep + 4
					for line in strings.split_lines(s[:sep], context.temp_allocator) {
						if strings.has_prefix(
							strings.to_lower(line, context.temp_allocator),
							"content-length:",
						) {
							if v, ok := strconv.parse_int(strings.trim_space(line[15:])); ok {
								content_len = v
							}
						}
					}
				}
			}
			if hdr_end >= 0 && content_len >= 0 && len(out) - hdr_end >= content_len {
				return string(out[hdr_end:hdr_end + content_len]), true
			}
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	if hdr_end < 0 {
		return "", false
	}
	return string(out[hdr_end:]), true
}

browser_open :: proc(base_url: string, alloc: mem.Allocator) -> (^Browser, string) {
	tmp, terr := os.temp_dir(context.temp_allocator)
	if terr != nil {
		tmp = "/tmp"
	}
	profile, perr := os.make_directory_temp(tmp, "booru-cdp-", alloc)
	if perr != nil {
		return nil, "failed to create temp profile directory"
	}

	chrome := os.get_env("CHROME_BIN", context.temp_allocator)
	if len(chrome) == 0 {
		chrome = "chromium"
	}

	chrome_env: [dynamic]string
	chrome_env.allocator = context.temp_allocator
	if parent_env, env_err := os.environ(context.temp_allocator); env_err == nil {
		for entry in parent_env {
			if strings.starts_with(entry, "DISPLAY=") ||
			   strings.starts_with(entry, "WAYLAND_DISPLAY=") {
				continue
			}
			append(&chrome_env, entry)
		}
	}

	proc_handle, serr := os.process_start(
		os.Process_Desc {
			command = {
				chrome,
				"--headless",
				"--no-sandbox",
				"--enable-webgl",
				"--ignore-gpu-blocklist",
				"--use-gl=angle",
				"--use-angle=swiftshader",
				"--enable-unsafe-swiftshader",
				"--disable-dev-shm-usage",
				fmt.tprintf("--user-data-dir=%s", profile),
				"--remote-debugging-port=0",
				"about:blank",
			},
			env = chrome_env[:] if len(chrome_env) > 0 else nil,
		},
	)
	if serr != nil {
		os.remove_all(profile)
		return nil, "failed to spawn chromium"
	}

	port := 0
	active_port_path := fmt.tprintf("%s/DevToolsActivePort", profile)
	for _ in 0 ..< 100 {
		if data, rerr := os.read_entire_file(active_port_path, context.temp_allocator);
		   rerr == nil {
			lines := strings.split_lines(string(data), context.temp_allocator)
			if len(lines) > 0 {
				if p, pok := strconv.parse_int(strings.trim_space(lines[0])); pok && p > 0 {
					port = p
					break
				}
			}
		}
		time.sleep(50 * time.Millisecond)
	}

	ws_url := ""
	if port > 0 {
		for _ in 0 ..< 40 {
			if body, ok := http_get_local(port, "/json/list"); ok {
				if val, jerr := json.parse(
					transmute([]u8)body,
					.JSON,
					true,
					context.temp_allocator,
				); jerr == nil {
					if arr, is_arr := val.(json.Array); is_arr {
						for item in arr {
							obj, is_obj := item.(json.Object)
							if !is_obj {continue}
							t, _ := obj["type"].(json.String)
							u, _ := obj["webSocketDebuggerUrl"].(json.String)
							if t == "page" && len(u) > 0 {
								ws_url = u
								break
							}
						}
					}
				}
			}
			if len(ws_url) > 0 {
				break
			}
			time.sleep(50 * time.Millisecond)
		}
	}

	sock: net.TCP_Socket
	wok: bool
	if len(ws_url) > 0 {
		sock, wok = ws_connect(ws_url)
	}
	if !wok {
		_ = os.process_kill(proc_handle)
		_, _ = os.process_wait(proc_handle)
		os.remove_all(profile)
		return nil, "failed to connect to chromium CDP"
	}

	b := new(Browser, alloc)
	b.sock = sock
	b.process = proc_handle
	b.profile_dir = profile
	b.base_url = strings.clone(base_url, alloc)
	_, _ = cdp_call(b, "Page.enable", "{}")
	return b, ""
}

browser_close :: proc(b: ^Browser) {
	if b == nil || b.closed {
		return
	}
	b.closed = true
	net.close(b.sock)
	_ = os.process_kill(b.process)
	_, _ = os.process_wait(b.process)
	os.remove_all(b.profile_dir)
}

cdp_call :: proc(b: ^Browser, method: string, params_json: string) -> (json.Object, string) {
	b.next_id += 1
	id := b.next_id
	id_buf: [32]u8
	id_str := strconv.write_int(id_buf[:], i64(id), 10)
	payload := strings.concatenate(
		{`{"id":`, id_str, `,"method":"`, method, `","params":`, params_json, `}`},
		context.temp_allocator,
	)
	if !ws_send_frame(b.sock, 0x1, transmute([]u8)payload) {
		return nil, "CDP send failed"
	}
	for {
		raw, ok := ws_recv_text(b.sock)
		if !ok {
			return nil, "CDP recv failed"
		}
		val, jerr := json.parse(transmute([]u8)raw, .JSON, true, context.temp_allocator)
		if jerr != nil {
			continue
		}
		obj, is_obj := val.(json.Object)
		if !is_obj {
			continue
		}
		if m, has_m := obj["method"].(json.String); has_m && m == "Page.loadEventFired" {
			b.load_fired = true
		}
		msg_id, has_id := obj["id"].(json.Integer)
		if !has_id || int(msg_id) != id {
			continue
		}
		if err_obj, has_err := obj["error"].(json.Object); has_err {
			msg, _ := err_obj["message"].(json.String)
			return nil, msg if len(msg) > 0 else "CDP error"
		}
		res, _ := obj["result"].(json.Object)
		return res, ""
	}
}

cdp_wait_event :: proc(b: ^Browser, event_name: string) -> bool {
	for {
		raw, ok := ws_recv_text(b.sock)
		if !ok {
			return false
		}
		val, jerr := json.parse(transmute([]u8)raw, .JSON, true, context.temp_allocator)
		if jerr != nil {
			continue
		}
		obj, is_obj := val.(json.Object)
		if !is_obj {
			continue
		}
		if method, has_m := obj["method"].(json.String); has_m && method == event_name {
			return true
		}
	}
}

cdp_eval :: proc(b: ^Browser, expr: string) -> (json.Value, string) {
	expr_bytes, _ := json.marshal(expr, {}, context.temp_allocator)
	params := strings.concatenate(
		{`{"expression":`, string(expr_bytes), `,"returnByValue":true,"awaitPromise":true}`},
		context.temp_allocator,
	)
	res, err := cdp_call(b, "Runtime.evaluate", params)
	if len(err) > 0 {
		return nil, err
	}
	if exc, has_exc := res["exceptionDetails"].(json.Object); has_exc {
		if ex_obj, ok := exc["exception"].(json.Object); ok {
			if desc, ok2 := ex_obj["description"].(json.String); ok2 && len(desc) > 0 {
				return nil, desc
			}
		}
		text, _ := exc["text"].(json.String)
		return nil, text if len(text) > 0 else "JS exception"
	}
	r_obj, _ := res["result"].(json.Object)
	if r_obj == nil {
		return nil, ""
	}
	return r_obj["value"], ""
}
