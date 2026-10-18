package test

import "../src/library"
import "../src/replay"
import "../src/server"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:testing"
import "core:thread"

@(test)
server_get_mipmap_with_image_ids :: proc(t: ^testing.T) {
	images := make([dynamic]library.Image, context.temp_allocator)
	replay.load_library("test/fixture/library", &images, context.temp_allocator)
	lib := library.State {
		library_path   = "test/fixture/library",
		library_images = images[:],
	}
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
		// Shutdown wakes the blocking accept so Serve can return before join.
		_ = net.shutdown(sock, .Both)
		thread.join(worker)
		thread.destroy(worker)
	}

	state, body, errors, curl_err := os.process_exec(
		{
			command = {
				"curl",
				"--request",
				"GET",
				"--header",
				"Content-Type: text/plain",
				"--data-binary",
				"3,1,2",
				"--silent",
				"--show-error",
				"--fail",
				"--noproxy",
				"*",
				"--connect-timeout",
				"1",
				"--max-time",
				"5",
				fmt.tprintf("http://127.0.0.1:%d/mipmap/64", endpoint.port),
			},
		},
		context.allocator,
	)
	defer delete(body)
	defer delete(errors)
	if !testing.expect(
		t,
		curl_err == nil && state.exit_code == 0,
		fmt.tprintf("curl mipmap: %s (%v)", errors, curl_err),
	) {return}
	testing.expect(t, len(body) >= 12, "mipmap returns a WebP header")
	if len(body) >= 12 {
		testing.expect(t, string(body[:4]) == "RIFF", "RIFF signature")
		testing.expect(t, string(body[8:12]) == "WEBP", "WebP signature")
	}
}
