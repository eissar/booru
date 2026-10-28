package cli

import "core:testing"

@(test)
socket_with_port_rejected :: proc(t: ^testing.T) {
	opts := Opts {
		socket = "bin/booru.sock",
		port   = 9000,
	}
	testing.expect(t, resolve_listen_mode(&opts) != "")
}

@(test)
port_defaults_without_socket :: proc(t: ^testing.T) {
	opts: Opts
	testing.expect(t, resolve_listen_mode(&opts) == "")
	testing.expect_value(t, opts.port, 8080)

	opts = Opts {
		socket = "bin/booru.sock",
	}
	testing.expect(t, resolve_listen_mode(&opts) == "")
	testing.expect_value(t, opts.port, 0)
}
