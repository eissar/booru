package main

import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

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
	// once
	client: net.TCP_Socket
	src: net.Endpoint
	client, src, err = net.accept_tcp(sock)
	if err != nil {
		log.fatal(err)
		os.exit(1)
	}

	data: [2048]byte
	for br, err := net.recv_tcp(client, data[:]); br > 0; {
		log.info(br)
		if err != nil {
			log.fatal(err)
			os.exit(1)
		}
		// if you run into r/n/r/n/ (13,10,13,10) then
		// head is complete
		break
	}
	net.close(client)


	log.infof("%v", data)
	text := strings.string_from_ptr(&data[0], len(data))
	log.infof("%v", text)
}
