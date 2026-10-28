package server

import "core:net"

// Unix sockets are out of scope on Windows; TCP mode is unaffected.
unix_socket_in_use :: proc(path: string) -> bool {return false}
listen_unix :: proc(path: string) -> (sock: net.TCP_Socket, err: string) {
	return {}, "unix sockets are not supported on Windows"
}
accept_unix :: proc(sock: net.TCP_Socket) -> (net.TCP_Socket, bool) {return {}, false}
