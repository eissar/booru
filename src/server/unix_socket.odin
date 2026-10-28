#+build linux, darwin, freebsd, openbsd, netbsd
package server

import "core:net"
import "core:strings"
import "core:sys/posix"

// core:net has no AF_UNIX, and net.accept_tcp / net.bound_endpoint hit
// unreachable() on a non-INET address. Only bind/listen/accept go through
// posix; the fd is wrapped as a net.TCP_Socket so recv/send/close work as-is.

// Reports whether a server is accepting on `path`. A stale socket file
// (crash/SIGKILL) refuses the connect and reports false.
unix_socket_in_use :: proc(path: string) -> bool {
	addr: posix.sockaddr_un
	if len(path) >= len(addr.sun_path) {return false}
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 {return false}
	defer posix.close(fd)
	return posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK
}

// Binds a Unix stream socket at `path`. Refuses a live socket; replaces a
// stale one.
listen_unix :: proc(path: string) -> (sock: net.TCP_Socket, err: string) {
	addr: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(addr.sun_path) {
		return {}, "path must be 1..107 bytes"
	}
	if unix_socket_in_use(path) {return {}, "already in use by a running server"}
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))

	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 {return {}, "socket failed"}
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK ||
	   posix.listen(fd, 128) != .OK {
		posix.close(fd)
		return {}, "bind/listen failed"
	}
	return net.TCP_Socket(fd), ""
}

accept_unix :: proc(sock: net.TCP_Socket) -> (net.TCP_Socket, bool) {
	fd := posix.accept(posix.FD(sock), nil, nil)
	return net.TCP_Socket(fd), fd != -1
}
