package progress

import "core:slice"
import "core:sync"

Progress :: struct {
	phase:    string,
	finished: u64,
	total:    Maybe(u64),
	done:     bool,
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
		done     = false,
	}
}

finish :: proc(phase: string) {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	if p, ok := &items[phase]; ok {
		p.done = true
		if total, has_total := p.total.?; has_total {
			p.finished = total
		}
	}
}

has_active :: proc() -> bool {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	for _, p in items {
		if !p.done {return true}
	}
	return false
}

// Dependent jobs should keep a parent phase active (e.g. "startup" around
// "startup.thumbnails" / "startup.phash") so has_active stays true between steps.
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
