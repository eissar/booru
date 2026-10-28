package main

import "core:fmt"
import "core:os"

daemonize :: proc() -> int {
	fmt.eprintln("error: -daemon is not supported on Windows")
	os.exit(2)
}

daemon_ready :: proc(fd: int) {}
