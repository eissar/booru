package jobs

import "core:sync"

// import "../library"

Abort_Flag :: struct {
	raw: bool,
}

// Job :: #type proc(state: library.State, flag: ^Abort_Flag)

is_aborted :: proc(f: ^Abort_Flag) -> bool {
	if f == nil {return false}
	return sync.atomic_load(&f.raw)
}

abort :: proc(f: ^Abort_Flag) {
	if f == nil {return}
	sync.atomic_store(&f.raw, true)
}
