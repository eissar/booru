package test

import "../src/library"
import "../src/replay"
import "../src/server"
import "../src/store"
import "../src/vendor/sqlite"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:testing"
import "core:thread"

@(test)
server_get_mipmap_with_image_ids :: proc(t: ^testing.T) {
	lib := library.State {
		library_path = "test/fixture/library",
	}
	if !testing.expect(t, store.Init(&lib, ":memory:") == sqlite.OK) {return}
	defer store.Close(&lib)
	replay.initiate_replay(&lib)
	data := struct {
		sock: net.TCP_Socket,
		lib:  library.State,
	}{}
	sock, err := net.listen_tcp(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 0})
	if !testing.expect(t, err == nil, "listen on an ephemeral port") {return}
	defer net.close(sock)
	endpoint, endpoint_err := net.bound_endpoint(sock)
	if !testing.expect(t, endpoint_err == nil, "read listening port") {return}

	data.sock = sock
	data.lib = lib
	worker := thread.create_and_start_with_data(&data, proc(raw: rawptr) {
		defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
		data := cast(^struct {
			sock: net.TCP_Socket,
			lib:  library.State,
		})raw
		server.Serve(&data.lib, data.sock)
	})
	defer {
		// Close before joining to wake accept on Windows; avoid a deferred double-close.
		_ = net.shutdown(sock, .Both)
		net.close(sock)
		sock = {}
		thread.join(worker)
		thread.destroy(worker)
	}

	body, ok := test_http(
		t,
		"GET",
		fmt.tprintf("http://127.0.0.1:%d/mipmap/64", endpoint.port),
		"3,1,2",
		200,
		content_type = "text/plain",
	)
	if !ok {return}
	testing.expect(t, len(body) >= 12, "mipmap returns a WebP header")
	if len(body) >= 12 {
		testing.expect(t, string(body[:4]) == "RIFF", "RIFF signature")
		testing.expect(t, string(body[8:12]) == "WEBP", "WebP signature")
	}
}
