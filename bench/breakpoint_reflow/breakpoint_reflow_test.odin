package breakpoint_reflow_bench

// Masonry column-count transitions on a large gallery, driven over CDP in
// headless Chromium (SwiftShader). The page is template.render_gallery_page
// with CARDS synthetic images; /static/* is served from ./static, everything
// else (/image, /mipmap) is 404, so no thumbnails or image decode are measured.
// Run from the repo root; needs chromium and libcurl:
//   odin test bench/breakpoint_reflow -define:CARDS=400 -define:RUNS=5
//
// Start: 1400x900 CSS px, 5 columns. zoom-in: 1120x720 @ dsf 1.25 (125% zoom of
// a 1400 device-px window), 4 columns. zoom-out: back, 5 columns.
// wall_ms: override sent until the column count is seen, plus two frames.
// sync_raf_ms: time inside rAF callbacks (gallery.js packs synchronously there).
// deferred_ms = wall - sync_raf: browser style/layout/paint and the rest.
// cards_per_sec = CARDS / wall_ms: cards repacked per second (median/best/worst).
//
// Reference (Chromium 156.0.8078.47, Linux, SwiftShader, 5 runs, median):
//   400 cards:  ~540 cards/s (wall ~0.74 s, sync rAF ~25 ms, 7.3k DOM nodes)
//   2000 cards: ~92 cards/s (wall ~21.7 s, sync rAF ~360 ms, 36k DOM nodes)
// Nearly all wall time is deferred main-thread CPU, not the synchronous pack.

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import curl "vendor:curl"

import "../../src/library"
import "../../src/template"

CARDS :: #config(CARDS, 400)
RUNS :: #config(RUNS, 5)

Metrics :: struct {
	width:             int `json:"width"`,
	height:            int `json:"height"`,
	deviceScaleFactor: f64 `json:"deviceScaleFactor"`,
	mobile:            bool `json:"mobile"`,
}
WIDE :: Metrics{1400, 900, 1, false}
ZOOMED :: Metrics{1120, 720, 1.25, false}

// Wraps requestAnimationFrame before gallery.js runs; gallery.js is unmodified.
HARNESS :: `window.__rafMs = 0;
const raf = window.requestAnimationFrame.bind(window);
window.requestAnimationFrame = fn => raf(t => { const s = performance.now(); try { fn(t); } finally { window.__rafMs += performance.now() - s; } });`

ws: ^curl.CURL
next_id: int

// call sends one CDP command and returns its "result", skipping events.
call :: proc(method: string, params: any = nil) -> json.Object {
	next_id += 1
	p := "{}"
	if params != nil {
		data, _ := json.marshal(params, allocator = context.temp_allocator)
		p = string(data)
	}
	// fmt treats '{' as format syntax, so the braces are arguments.
	msg := fmt.tprintf(`%s"id":%d,"method":"%s","params":%s%s`, "{", next_id, method, p, "}")
	sent: uint
	curl.ws_send(ws, raw_data(msg), uint(len(msg)), &sent, 0, curl.WS_TEXT)
	for {
		reply: [dynamic]u8
		reply.allocator = context.temp_allocator
		for {
			buf: [64 * 1024]u8
			n: uint
			meta: ^curl.ws_frame
			rc := curl.ws_recv(ws, &buf, len(buf), &n, &meta)
			if rc == .E_AGAIN {time.sleep(100 * time.Microsecond); continue}
			fmt.assertf(rc == .E_OK, "%s: ws_recv %v", method, rc)
			append(&reply, ..buf[:n])
			if meta.bytesleft == 0 && .CONT not_in meta.flags {break}
		}
		v, _ := json.parse(reply[:], allocator = context.temp_allocator)
		obj := v.(json.Object)
		if id, ok := obj["id"].(json.Float); !ok || int(id) != next_id {continue}
		fmt.assertf("error" not_in obj, "%s: %v", method, obj["error"])
		return obj["result"].(json.Object)
	}
}

evaluate :: proc(expression: string) -> json.Value {
	r := call("Runtime.evaluate", struct {
		expression:    string `json:"expression"`,
		returnByValue: bool `json:"returnByValue"`,
		awaitPromise:  bool `json:"awaitPromise"`,
	}{expression, true, true})
	return r["result"].(json.Object)["value"]
}

columns :: proc() -> int {
	return int(
		evaluate(`document.querySelectorAll('#photo-grid > .masonry-column').length`).(json.Float),
	)
}

wait_columns :: proc(n: int) {
	for columns() != n {time.sleep(50 * time.Millisecond)}
}

// Two frames and a 300 ms tail, so the deferred frame lands before sampling.
idle :: proc() {
	evaluate(
		`new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300))))`,
	)
}

KEYS :: [?]string {
	"ThreadTime",
	"LayoutCount",
	"LayoutDuration",
	"RecalcStyleCount",
	"RecalcStyleDuration",
}

metrics :: proc() -> (m: [len(KEYS)]f64) {
	for item in call("Performance.getMetrics")["metrics"].(json.Array) {
		o := item.(json.Object)
		for k, i in KEYS {if o["name"].(json.String) == k {m[i] = o["value"].(json.Float)}}
	}
	return
}

FIELDS :: [?]string {
	"wall_ms",
	"sync_raf_ms",
	"deferred_ms",
	"cpu_ms",
	"layout_count",
	"layout_ms",
	"style_count",
	"style_ms",
	"dom_nodes",
}

transition :: proc(to: Metrics, want: int) -> [len(FIELDS)]f64 {
	evaluate(`window.__rafMs = 0`)
	was := columns()
	fmt.assertf(was != want, "already at %d columns; zoom would not cross a breakpoint", want)
	before := metrics()
	start := time.tick_now()
	call("Emulation.setDeviceMetricsOverride", to)
	wait_columns(want)
	idle()
	wall := time.duration_milliseconds(time.tick_since(start)) - 300
	after := metrics()
	raf := evaluate(`window.__rafMs`).(json.Float)
	nodes := evaluate(`document.getElementsByTagName('*').length`).(json.Float)
	d: [len(KEYS)]f64
	for k in 0 ..< len(KEYS) {d[k] = after[k] - before[k]}
	return {wall, raf, wall - raf, d[0] * 1000, d[1], d[2] * 1000, d[3], d[4] * 1000, nodes}
}

@(test)
bench_breakpoint_reflow :: proc(t: ^testing.T) {
	images := make([]library.Image, CARDS)
	defer delete(images)
	for &image, i in images {
		image = {
			id     = i + 1,
			oid    = fmt.tprintf("bench%d", i),
			name   = fmt.tprintf("Image %d.jpg", i),
			width  = 400 + (i % 5) * 100,
			height = 300 + (i % 7) * 100,
		}
	}
	page: string
	{
		// Templates leave intermediates on context.allocator, like handlers'
		// per-request arena; the page lives until the test ends.
		context.allocator = context.temp_allocator
		page = template.render_gallery_page(
			"bench",
			{limit = CARDS, offset = CARDS},
			images,
			false,
		)
	}

	server := struct {
		sock: net.TCP_Socket,
		page: string,
	} {
		page = page,
	}
	server.sock, _ = net.listen_tcp({net.IP4_Loopback, 0})
	ep, _ := net.bound_endpoint(server.sock)
	worker := thread.create_and_start_with_data(
		&server,
		proc(raw: rawptr) {
			s := cast(^struct {
				sock: net.TCP_Socket,
				page: string,
			})raw
			for {
				conn, _, err := net.accept_tcp(s.sock)
				if err != nil {return}
				buf: [16 * 1024]u8
				n, _ := net.recv_tcp(conn, buf[:])
				fields := strings.fields(string(buf[:n]), context.temp_allocator)
				if len(fields) < 2 {net.close(conn); continue} 	// preconnect
				path := strings.split(fields[1], "?", context.temp_allocator)[0]
				body, status, kind := "", "404 Not Found", "text/plain"
				if path == "/" {
					body, status, kind = s.page, "200 OK", "text/html; charset=utf-8"
				} else if data, read_err := os.read_entire_file(path[1:], context.temp_allocator);
				   strings.has_prefix(path, "/static/") && read_err == nil {
					body, status = string(data), "200 OK"
					kind = strings.has_suffix(path, ".css") ? "text/css" : "text/javascript"
				}
				net.send_tcp(
					conn,
					transmute([]u8)fmt.tprintf(
						"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
						status,
						kind,
						len(body),
					),
				)
				net.send_tcp(conn, transmute([]u8)body)
				net.close(conn)
				free_all(context.temp_allocator)
			}
		},
	)
	defer {
		net.shutdown(server.sock, .Both)
		net.close(server.sock)
		thread.join(worker)
		thread.destroy(worker)
	}

	profile, _ := os.make_directory_temp("", "booru-zoom-*", context.temp_allocator)
	defer os.remove_all(profile)
	chrome, start_err := os.process_start(
		{
			command = {
				"chromium",
				"--headless=new",
				"--no-sandbox",
				"--use-angle=swiftshader",
				"--enable-unsafe-swiftshader",
				"--disable-dev-shm-usage",
				fmt.tprintf("--user-data-dir=%s", profile),
				"--remote-debugging-port=0",
				"about:blank",
			},
		},
	)
	if !testing.expectf(t, start_err == nil, "start chromium: %v", start_err) {return}
	defer {
		_ = os.process_kill(chrome)
		_, _ = os.process_wait(chrome)
	}

	port: int
	for port == 0 {
		time.sleep(50 * time.Millisecond)
		data, _ := os.read_entire_file(
			fmt.tprintf("%s/DevToolsActivePort", profile),
			context.temp_allocator,
		)
		port, _ = strconv.parse_int(strings.split_lines(string(data), context.temp_allocator)[0])
	}
	get :: proc(url: string) -> json.Value {
		body: [dynamic]u8
		body.allocator = context.temp_allocator
		h := curl.easy_init()
		defer curl.easy_cleanup(h)
		curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
		curl.easy_setopt(h, .WRITEDATA, &body)
		curl.easy_setopt(
			h,
			.WRITEFUNCTION,
			proc "c" (buf: [^]byte, size, n: c.size_t, out: rawptr) -> c.size_t {
				context = runtime.default_context()
				append(cast(^[dynamic]u8)out, ..buf[:size * n])
				return size * n
			},
		)
		curl.easy_perform(h)
		v, _ := json.parse(body[:], allocator = context.temp_allocator)
		return v
	}
	version := get(fmt.tprintf("http://127.0.0.1:%d/json/version", port)).(json.Object)
	ws_url: string
	for target in get(fmt.tprintf("http://127.0.0.1:%d/json/list", port)).(json.Array) {
		o := target.(json.Object)
		if o["type"].(json.String) == "page" {ws_url = o["webSocketDebuggerUrl"].(json.String)}
	}
	ws = curl.easy_init()
	defer curl.easy_cleanup(ws)
	curl.easy_setopt(ws, .URL, strings.clone_to_cstring(ws_url, context.temp_allocator))
	curl.easy_setopt(ws, .CONNECT_ONLY, c.long(2)) // 2: WebSocket
	if !testing.expect(t, curl.easy_perform(ws) == .E_OK, "ws connect") {return}

	call("Performance.enable")
	call("Page.enable") // addScriptToEvaluateOnNewDocument needs it
	call("Page.addScriptToEvaluateOnNewDocument", struct {
		source: string `json:"source"`,
	}{HARNESS})
	call("Emulation.setDeviceMetricsOverride", WIDE)
	call("Page.navigate", struct {
		url: string `json:"url"`,
	}{fmt.tprintf("http://%s/", net.endpoint_to_string(ep, context.temp_allocator))})
	wait_columns(5)
	idle()

	fmt.printf(
		"bench=breakpoint-reflow cards=%d runs=%d browser=%q\n",
		CARDS,
		RUNS,
		version["Browser"].(json.String),
	)
	results: [2][len(FIELDS)][RUNS]f64
	for run in 0 ..< RUNS {
		for to, i in ([2]Metrics{ZOOMED, WIDE}) {
			r := transition(to, i == 0 ? 4 : 5)
			for f in 0 ..< len(FIELDS) {results[i][f][run] = r[f]}
		}
	}
	fields := FIELDS
	for name, i in ([2]string{"zoom-in (5->4)", "zoom-out (4->5)"}) {
		// Cards repacked into the new column count per second of wall time.
		rates: [RUNS]f64
		for run in 0 ..< RUNS {rates[run] = CARDS / results[i][0][run] * 1000}
		slice.sort(rates[:])
		fmt.printf(
			"bench=breakpoint-reflow case=%q cards_per_sec=%.0f best_cards_per_sec=%.0f worst_cards_per_sec=%.0f",
			name,
			rates[RUNS / 2],
			rates[RUNS - 1],
			rates[0],
		)
		for &values, f in results[i] {
			slice.sort(values[:])
			fmt.printf(" %s=%.1f", fields[f], values[RUNS / 2])
		}
		fmt.println()
	}
}
