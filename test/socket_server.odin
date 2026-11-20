#+build linux, darwin, freebsd, openbsd, netbsd
package test

import "../src/library"
import "../src/server"
import "../src/store"
import "../src/vendor/sqlite"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:testing"
import "core:thread"

// Serves one request over a Unix socket.
@(test)
unix_socket_serves_request :: proc(t: ^testing.T) {
	root, dir_err := os.make_directory_temp("", "booru-socket-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil) {return}
	defer os.remove_all(root)
	sock_path := fmt.tprintf("%s/booru.sock", root)

	data := struct {
		sock: net.TCP_Socket,
		lib:  library.State,
	} {
		lib = {library_path = "test/fixture/library"},
	}
	if !testing.expect(t, store.Init(&data.lib, ":memory:") == sqlite.OK) {return}
	defer store.Close(&data.lib)

	listen_err: string
	data.sock, listen_err = server.listen_unix(sock_path)
	if !testing.expect_value(t, listen_err, "") {return}
	worker := thread.create_and_start_with_data(&data, proc(raw: rawptr) {
		defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
		data := cast(^struct {
			sock: net.TCP_Socket,
			lib:  library.State,
		})raw
		server.Serve(&data.lib, data.sock, server.accept_unix)
	})
	defer {
		_ = net.shutdown(data.sock, .Both)
		net.close(data.sock)
		thread.join(worker)
		thread.destroy(worker)
	}

	// A second server must not steal a live socket.
	_, second_err := server.listen_unix(sock_path)
	testing.expect(t, second_err != "", "live socket is refused")

	_, _ = test_http(t, "GET", "http://x/gallery", "", 200, unix_socket = sock_path)
}
