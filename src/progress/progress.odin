package progress

Progress :: struct {
	phase:    string,
	finished: u64,
	total:    Maybe(u64),
}

Callback :: proc(progress: Progress)
