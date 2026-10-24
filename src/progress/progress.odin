package progress

Progress :: struct {
	phase:    string,
	finished: u64,
	total:    Maybe(u64),
}

Callback :: proc(progress: Progress)

// Latest scan progress, written by the scan thread and read racily by SSE handlers.
current: Progress
done: bool
