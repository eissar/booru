package progress

import "core:slice"
import "core:sync"

Progress :: struct {
	phase:    string,
	finished: u64,
	total:    Maybe(u64),
}

@(private = "file")
mu: sync.Mutex
@(private = "file")
items: map[string]Progress

update :: proc(phase: string, finished: u64, total: Maybe(u64) = nil) {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	items[phase] = Progress {
		phase    = phase,
		finished = finished,
		total    = total,
	}
}

finish :: proc(phase: string) {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	delete_key(&items, phase)
	if len(items) == 0 {
		delete(items)
		items = {}
	}
}

snapshot :: proc(alloc := context.allocator) -> []Progress {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	out := make([]Progress, len(items), alloc)
	i := 0
	for _, p in items {
		out[i] = p
		i += 1
	}
	slice.sort_by(out, proc(a, b: Progress) -> bool {
		return a.phase < b.phase
	})
	return out
}
