package thumbnail

import "core:fmt"
import "core:strings"
import "core:time"

import "../library"
import "../progress"
import "../vendor/sqlite"

startup_threaded_generate_missing_thumbnails :: proc(data: struct {
		library_path:  string,
		prog_callback: progress.Callback,
	}) {
	defer free_all(context.temp_allocator)

	path := strings.clone_to_cstring(
		fmt.tprintf("%s/store.sqlite", data.library_path),
		context.temp_allocator,
	)
	db, rc := sqlite.open(path)
	if rc != sqlite.OK {
		if db != nil {sqlite.close(db)}
		fmt.eprintfln("thumbnail scan: open store failed: rc=%d", rc)
		return
	}
	defer sqlite.close(db)

	state := library.State {
		library_path = data.library_path,
		data_store   = db,
	}
	start := time.now()
	generated, failed := generate_missing_thumbnails(state, data.prog_callback)
	fmt.eprintfln(
		"thumbnails: generated=%d, failed=%d in %.2f ms",
		generated,
		failed,
		time.duration_milliseconds(time.since(start)),
	)
}
