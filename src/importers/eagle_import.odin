package importers

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "core:encoding/json"

import "../library"

Eagle_Import_Ctx :: struct {
	success:     int,
	missing:     int,
	read_errors: int,
}

METADATA_MAX_BYTES :: 2 * 1024 * 1024

Palette :: struct {
	color: [3]int,
	ratio: f64,
}

// the full available data is here.
EagleItem :: struct {
	annotation:        string,
	btime:             i64,
	comments:          []json.Value, // shape unknown
	customThumbnail:   bool,
	deletedTime:       i64,
	duration:          f64,
	ext:               string,
	folders:           []string,
	height:            int,
	id:                string,
	isDeleted:         bool,
	lastModified:      i64,
	modificationTime:  i64,
	mtime:             i64,
	name:              string,
	noThumbnail:       bool,
	palettes:          []Palette,
	processingPalette: bool,
	resolutionHeight:  int,
	resolutionWidth:   int,
	size:              i64,
	star:              int,
	tags:              []string,
	url:               string,
	width:             int,
}

// transmutable into Event
EagleItem_Event :: struct {
	addedAt:     Iso_Time `json:"btime"`,
	contentType: string `json:"-"`,
	height:      int,
	id:          int `json:"-"`,
	mtime:       Iso_Time,
	name:        string,
	oid:         string `json:"-"`,
	op:          string `json:"-"`,
	path:        string `json:"-"`,
	tags:        []string,
	width:       int,
}

// WIP
// fd, open_err := linux.open(cpath, {.DIRECTORY})
eagle_import :: proc(root: string, ctx: ^Eagle_Import_Ctx, rootFd: linux.Fd) {
	data := make([]u8, METADATA_MAX_BYTES, context.allocator)
	defer delete(data, context.allocator)

	buf: [1024 * 4]u8
	for {
		defer free_all(context.temp_allocator) // technically optional

		n, err := linux.getdents(rootFd, buf[:])
		if err != .NONE {
			ctx.read_errors += 1
			fmt.eprintfln("error: reading %s: %v", root, err, flush = true)
			return
		}
		if n == 0 {break}

		offs := 0
		for {
			ent, cont := linux.dirent_iterate_buf(buf[:n], &offs)
			if !cont {break}

			// An item is <id>.info/
			// skip everything else (including . and ..).
			name := linux.dirent_name(ent)

			// TODO: some filesystems report .UNKNOWN
			if ent.type != .DIR || !strings.has_suffix(name, ".info") {continue}

			meta_path := fmt.tprintf("%s/%s/metadata.json", root, name)

			meta_Fd: ^os.File
			meta_err: os.Error
			meta_info: os.File_Info
			meta_Fd, meta_err = os.open(meta_path, {.Read}, os.Permissions_Default)
			defer os.close(meta_Fd)

			if meta_err == .Not_Exist {
				ctx.missing += 1
				continue
			}
			if meta_err != nil {
				ctx.read_errors += 1
				continue
			}

			i, read_err := os.read(meta_Fd, data)
			if read_err != nil {
				ctx.read_errors += 1
				continue
			}

			probe_eof := [1]u8{}
			// we do another read with the existing file handle.
			// with zero bytes remaining, it should return .EOF
			//
			// this is much faster than doing an fstat/file
			if _, eof := os.read(meta_Fd, probe_eof[:]); eof != .EOF {
				ctx.read_errors += 1
				continue
			}


			item: EagleItem_Event

			// this is usually unsafe but fine because
			// @(test) eagle_item_transmutable_into_event
			ev := cast(^library.Event)&item
			library.new_add_event(ev)

			// we reuse the buffer so
			// need to bound to read bytes (i)
			json_err := json.unmarshal(
				data[:i],
				&item,
				json.DEFAULT_SPECIFICATION,
				context.temp_allocator,
			)

			if json_err != nil {
				// no unique error tracking
				ctx.read_errors += 1
				continue
			}

			// copy file into images/

			// write an event


			if ctx.success < 10 {fmt.println(ev)}
			ctx.success += 1
		}
	}
}

@(test) // just for convenience, ignore
eagle_import_test :: proc(t: ^testing.T) {
	root, join_err := os.join_path({"/home/eissar/Memes.library", "images"}, context.allocator)
	defer delete(root, context.allocator)

	if join_err != nil {
		fmt.eprintfln("error: building library root: %v", join_err)
		return
	}

	ctx := Eagle_Import_Ctx{}

	fd, err := os.open(root, {.Read}, os.Permissions_Default)
	if err != nil {
		fmt.panicf("error opening lib dir %v ; err=%v", root, err)
	}

	eagle_import(root, &ctx, linux.Fd(os.fd(fd)))

	fmt.println(ctx)
}
