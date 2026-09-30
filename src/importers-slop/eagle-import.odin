package importers

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// filepath.Walk_Proc :: #type proc(info: os.File_Info, in_err: os.Error, user_data: rawptr) -> (err: os.Error, skip_dir: bool)


Eagle_Import_Ctx :: struct {
	root:        string,

	// error counters, so 3 missing / unreadable packs don't abort the batch
	missing:     int,
	read_errors: int,
}

METADATA_WARN_BYTES :: 2 * 1024 * 1024

// Pack_Metadata :: struct {
// 	id:   string, // cloned: temp allocator dies with the callback
// 	json: []u8,
// }
openEaglePack :: proc(packPath: string, ctx: ^Eagle_Import_Ctx) {
	walkInfoDirs :: proc(
		info: os.File_Info,
		in_err: os.Error,
		eagle_ctx: rawptr,
	) -> (
		err: os.Error,
		skip_dir: bool,
	) {
		ctx := cast(^Eagle_Import_Ctx)eagle_ctx

		if !info.is_dir {return nil, false}
		if !strings.has_suffix(info.name, ".info") {return nil, false}

		// known layout: <id>.info/metadata.json
		meta_path := filepath.join({info.fullpath, "metadata.json"})
		defer delete(meta_path)

		data, ok := os.read_entire_file(meta_path, context.allocator)
		if !ok {
			ctx.missing += 1
			return nil, false
		}
		defer delete(data)

		if len(data) > METADATA_WARN_BYTES {
			fmt.printfln("warning: %s is %.2f MiB", meta_path, f64(len(data)) / (1024 * 1024))
		}

		// id := strings.clone(strings.trim_suffix(info.name, ".info"))
		// nothing else to do in <id>.info/
		return nil, true
	}
	err := filepath.walk(packPath, walkInfoDirs, ctx)
	if err != nil {fmt.print("err:", err)}

}

main :: proc() {
	pth := "/home/eissar/Memes.library"

	ctx := Eagle_Import_Ctx {
		root = filepath.join({pth, "/images"}),
	}
	defer delete(ctx.root)

	openEaglePack(ctx.root, &ctx)
}
