package cli

import "core:flags"
import "core:fmt"
import "core:os"

Opts :: struct {
	/* default 8080 */
	port:          int `usage:"Port to bind."`,

	/* default test/fixture/library */
	library:       string `usage:"Path to the library root (contains events/ and images/)."`,
	import_eagle:  string `name:"import-eagle" usage:"Import an Eagle library root before serving."`,

	// pack: string
	/* remove cached renderer artifacts before startup */
	// resetCache/clearArtifacts: bool
	/* reset derived index artifacts and replay
       committed events from the beginning */
	// rebuildIndex: bool
	// Scan and generate missing thumbnails before listening by default.
	scanThumbnail: bool `usage:"Generate missing 64px and 128px thumbnails on startup."`,
}
//REGION: cli flag validation

check_valid_port :: proc(
	model: rawptr,
	name: string,
	value: any,
	args_tag: string,
) -> (
	error: string,
) {
	switch name {
	case "port":
		v := value.(int)
		if v < 1 || v > 65535 {
			error = fmt.tprintf("port must be 1..65535, got %v", v)
		}
	}
	return
}


getFlags :: proc() -> Opts {
	opts: Opts = {
		port          = 8080,
		library       = "test/fixture/library",
		scanThumbnail = true,
	}
	flags.register_flag_checker(check_valid_port)
	flags.parse_or_exit(&opts, os.args)
	return opts
}
