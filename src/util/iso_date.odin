package util

import "base:runtime"
import "core:fmt"
import "core:time"

iso_date :: proc(t: time.Time, alloc: runtime.Allocator) -> (iso: string, ok: bool) {
	dt := time.time_to_datetime(t) or_return
	return fmt.aprintf(
			"%04d%02d%02dT%02d%02d%02dZ",
			dt.year,
			dt.month,
			dt.day,
			dt.hour,
			dt.minute,
			dt.second,
			allocator = alloc,
			newline = false,
		),
		true
}
