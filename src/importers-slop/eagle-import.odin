package importers

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Eagle_Import_Ctx :: struct {
	root:        string,

	// error counters, so 3 missing / unreadable packs don't abort the batch
	missing:     int,
	read_errors: int,
}

METADATA_WARN_BYTES :: 2 * 1024 * 1024

// Pack_Metadata :: struct {
// 	id:   string, // cloned: the walker's allocator dies with the iteration
// 	json: []u8,
// }
openEaglePack :: proc(packPath: string, ctx: ^Eagle_Import_Ctx) {
	walker := filepath.walker_create(packPath)
	defer filepath.walker_destroy(&walker)

	for info in filepath.walker_walk(&walker) {
		// A failed read_directory yields a zeroed info; report and move on so
		// one unreadable pack does not abort the batch.
		if path, err := filepath.walker_error(&walker); err != nil {
			ctx.read_errors += 1
			fmt.eprintfln("error: walking %s: %v", path, err)
			continue
		}

		if info.type == .Directory {
			// A pack is <id>.info/; do not descend into anything else.
			if !strings.has_suffix(info.name, ".info") {
				filepath.walker_skip_dir(&walker)
			}
			continue
		}

		// known layout: <id>.info/metadata.json
		if !strings.has_suffix(info.fullpath, ".info/metadata.json") {
			continue
		}

		size := info.size
		if size > METADATA_WARN_BYTES {
			fmt.printfln("warning: %s is %.2f MiB", info.fullpath, f64(size) / (1024 * 1024))
		}

		data, read_err := os.read_entire_file(info.fullpath, context.allocator)
		if read_err != nil {
			ctx.missing += 1
			continue
		}
		// Frees per iteration; a defer here would pin every metadata file
		// until the whole walk finished.
		delete(data)

		// id := strings.trim_suffix(filepath.base(filepath.dir(info.fullpath)), ".info")
		// nothing else to do with the metadata yet
	}
}

main :: proc() {
	pth := "/home/eissar/Memes.library"

	root, join_err := filepath.join({pth, "images"})
	if join_err != nil {
		fmt.eprintfln("error: building library root: %v", join_err)
		return
	}
	defer delete(root)

	ctx := Eagle_Import_Ctx {
		root = root,
	}

	openEaglePack(ctx.root, &ctx)
}
