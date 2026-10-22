#+build windows
package event_log

import "core:os"

// Windows does not require fsync on directories
// to make filenames durable
make_durable :: proc(ev_handle: ^os.File) -> (err: string) {
	if os.sync(ev_handle) != nil {
		return "could not sync event log"
	}

	return
}
