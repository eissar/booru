#+build linux
package event_log

import "core:os"
import "core:path/filepath"
import "core:sys/linux"

make_durable :: proc(ev_handle: ^os.File) -> (err: string) {
	if linux.fsync(linux.Fd(os.fd(ev_handle))) != .NONE {
		return "could not sync event log"
	}

	name := os.name(ev_handle) // this is cached / no addl syscall
	if name == "" {return "could not resolve event log path for syncing"}

	dir, dir_err := os.open(filepath.dir(name), {.Read}, os.Permissions_Default)
	if dir_err != nil {return "could not open events directory for syncing"}
	defer os.close(dir)
	if linux.fsync(linux.Fd(os.fd(dir))) != .NONE {return "could not sync events directory"}

	return
}
