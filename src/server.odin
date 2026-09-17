package main

import "core:log"
import "core:net"
import "core:os"

main :: proc() {
	// consider: `when ODIN_DEBUG { log.debug("debugging") }` on hot paths
	lvl := log.Level.Debug when ODIN_DEBUG else log.Level.Info
	context.logger = log.create_console_logger(
		lowest = lvl,
		opt = log.Options{.Level, .Short_File_Path, .Procedure, .Line},
	)
	defer log.destroy_console_logger(context.logger)

	cfg := getFlags()

	// if cfg.rebuildindex

	sock, err := net.listen_tcp(net.Endpoint({net.IP4_Address{127, 0, 0, 1}, cfg.port}))
	if err != nil {
		// #partial switch e in err {
		//     case net.Bind_Error ?
		// }
		log.fatal(err)
		os.exit(1)
	}

	log.debug("debugging")
	log.infof("server running on port %v", cfg.port)
}
