package bench

import cdp "../test/cdp"
import "core:fmt"
import "core:os"

main :: proc() {
	path := os.args[1] if len(os.args) > 1 else "bench/gallery_bench.lua"
	if err, ok := cdp.run_lua_file(path); !ok {
		fmt.eprintln("BENCH FAILED:", err)
		os.exit(1)
	}
}
