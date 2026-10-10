package server_test

import server "../src"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

// Run from the repository root with `odin test test`. Requires curl on PATH.
@(test)
server_get_gallery :: proc(t: ^testing.T) {
	// An empty library is enough to exercise the HTTP and gallery render paths.
	previous_path := server.library_path
	previous_images := server.library_images
	defer {
		server.library_path = previous_path
		server.library_images = previous_images
	}
	server.library_path = "test/fixture/library"
	server.library_images = nil

	sock, err := net.listen_tcp(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 0})
	if !testing.expect(t, err == nil, "listen on an ephemeral port") {return}
	defer net.close(sock)
	endpoint, endpoint_err := net.bound_endpoint(sock)
	if !testing.expect(t, endpoint_err == nil, "read listening port") {return}

	worker := thread.create_and_start_with_data(&sock, proc(data: rawptr) {
		defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
		server.Serve((cast(^net.TCP_Socket)data)^)
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
				"--silent",
				"--show-error",
				"--fail",
				"--noproxy",
				"*",
				"--connect-timeout",
				"1",
				"--max-time",
				"5",
				fmt.tprintf("http://127.0.0.1:%d/gallery", endpoint.port),
			},
		},
		context.allocator,
	)
	defer delete(body)
	defer delete(errors)
	if !testing.expect(
		t,
		curl_err == nil && state.exit_code == 0,
		fmt.tprintf("curl gallery: %s (%v)", errors, curl_err),
	) {return}
	testing.expect(t, strings.contains(string(body), "<html"), "gallery returns HTML")
	testing.expect(t, strings.contains(string(body), "</html>"), "gallery response is complete")
}
