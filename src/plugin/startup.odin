package plugin

import "core:fmt"
import "core:strings"

import "../library"
import "../vendor/sqlite"

startup_threaded_run_plugins :: proc(data: struct {
		library_path: string,
		plugins:      []NativePlugin,
	}) {
	defer free_all(context.temp_allocator)

	path := strings.clone_to_cstring(
		fmt.tprintf("%s/store.sqlite", data.library_path),
		context.temp_allocator,
	)
	db, rc := sqlite.open(path)
	if rc != sqlite.OK {
		if db != nil {sqlite.close(db)}
		fmt.eprintfln("plugin scan: open store failed: rc=%d", rc)
		return
	}
	defer sqlite.close(db)

	state := library.State {
		library_path = data.library_path,
		data_store   = db,
	}
	_ = run(&state, data.plugins, context.allocator)
}
