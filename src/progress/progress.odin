package progress

import "base:runtime"
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

// items outlives any caller's context (handlers, worker threads, tests), so it
// uses the heap allocator instead of whichever context.allocator calls update first.
@(init, private = "file")
init_items :: proc "contextless" () {
	context = runtime.default_context()
	items = make(map[string]Progress, allocator = runtime.heap_allocator())
}

@(fini, private = "file")
fini_items :: proc "contextless" () {
	context = runtime.default_context()
	delete(items)
}

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

is_active :: proc(phase: string) -> bool {
	sync.mutex_lock(&mu)
	defer sync.mutex_unlock(&mu)
	p, ok := items[phase]
	return ok && !p.done
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
