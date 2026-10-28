#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:fmt"
import "core:sys/posix"

// Forks; the parent blocks until the child calls daemon_ready, prints the
// child's PID and exits 0, or exits 1 if the child dies first. Call before any
// threads start. stdout/stderr are inherited; redirect them to keep logs.
daemonize :: proc() -> (ready_fd: posix.FD) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		fmt.eprintln("daemon: pipe failed")
		posix._exit(1)
	}
	pid := posix.fork()
	switch pid {
	case -1:
		fmt.eprintln("daemon: fork failed")
		posix._exit(1)
	case 0:
		posix.close(fds[0])
		posix.setsid()
		return fds[1]
	}
	posix.close(fds[1])
	b: [1]byte
	if posix.read(fds[0], &b[0], 1) != 1 {
		fmt.eprintln("daemon: server exited before it was ready")
		posix._exit(1)
	}
	fmt.println(pid)
	posix._exit(0)
}

daemon_ready :: proc(fd: posix.FD) {
	b := [1]byte{1}
	posix.write(fd, &b[0], 1)
	posix.close(fd)
}
