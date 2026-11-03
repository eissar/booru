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

@(test)
port_range_checked :: proc(t: ^testing.T) {
	testing.expect(t, check_valid_port(nil, "port", 0, "") != "")
	testing.expect(t, check_valid_port(nil, "port", 1, "") == "")
	testing.expect(t, check_valid_port(nil, "port", 65535, "") == "")
	testing.expect(t, check_valid_port(nil, "port", 65536, "") != "")
}
