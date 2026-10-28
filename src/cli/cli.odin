package cli

import "core:flags"
import "core:fmt"
import "core:os"

Opts :: struct {
	/* default 8080 unless -socket is set */
	port:           int `usage:"Port to bind. Mutually exclusive with -socket."`,
	socket:         string `usage:"Listen on this Unix socket path instead of TCP."`,
	daemon:         bool `usage:"Detach; return once the server is ready to serve."`,

	/* default test/fixture/library */
	library:        string `usage:"Path to the library root (contains events/ and images/)."`,
	import_eagle:   string `name:"import-eagle" usage:"Import an Eagle library root before serving."`,

	// pack: string
	/* remove cached renderer artifacts before startup */
	// resetCache/clearArtifacts: bool
	/* reset derived index artifacts and replay
       committed events from the beginning */
	// rebuildIndex: bool
	// Scan and generate missing thumbnails before listening by default.
	scan_thumbnail: bool `name:"scan-thumbnail" usage:"Generate missing 64px and 128px thumbnails on startup."`,
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

// Port has no struct default so an explicit -port is detectable.
resolve_listen_mode :: proc(opts: ^Opts) -> (error: string) {
	if opts.socket != "" && opts.port != 0 {
		return "-socket and -port are mutually exclusive"
	}
	if opts.socket == "" && opts.port == 0 {opts.port = 8080}
	return
}

getFlags :: proc() -> Opts {
	opts: Opts = {
		library        = "test/fixture/library",
		scan_thumbnail = true,
	}
	flags.register_flag_checker(check_valid_port)
	flags.parse_or_exit(&opts, os.args)
	if msg := resolve_listen_mode(&opts); msg != "" {
		fmt.eprintln("error:", msg)
		os.exit(2)
	}
	return opts
}
