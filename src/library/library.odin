package library

import "core:mem"
import "core:sync"
// Library loading: replay NDJSON add-events into an in-memory image list.
// Prototype only -- no derived index, no DB.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"


State :: struct {
	library_path:   string,
	library_images: []Image,
}

Image :: struct {
	id:           int,
	oid:          string,
	path:         string,
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        string,
	added_at:     string,
	content_type: string,
}

Event :: struct {
	addedAt:     string,
	contentType: string,
	height:      int,
	id:          int,
	mtime:       string,
	name:        string,
	oid:         string,
	op:          string,
	path:        string,
	tags:        []string,
	width:       int,
}


// load library at path root into v
load_library :: proc(root: string, images: ^[dynamic]Image, alloc: mem.Allocator) {
	events_dir := fmt.tprintf("%s/events", root)
	dir_fi, _ := os.stat(events_dir, alloc)
	if dir_fi.type != .Directory {fmt.eprintln("library: cannot open events dir", events_dir)}
	os.file_info_delete(dir_fi, alloc)

	w := os.walker_create(events_dir)
	defer os.walker_destroy(&w)

	for entry in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}

		if !strings.has_suffix(entry.name, ".ndjson") {
			continue
		}

		data, err := os.read_entire_file(entry.fullpath, alloc)
		defer delete(data, alloc)

		if err != nil {
			fmt.eprintln("library: cannot read", entry.fullpath)
			continue
		}
		load_ndjson(images, string(data), alloc)
	}
}

load_ndjson :: proc(images: ^[dynamic]Image, data: string, alloc: mem.Allocator) {
	lines := strings.split(data, "\n", alloc)

	for line in lines {
		if strings.trim_space(line) == "" {continue}
		ev: Event

		if err := json.unmarshal(transmute([]u8)line, &ev, json.DEFAULT_SPECIFICATION, alloc);
		   err != nil {
			fmt.eprintln("library: bad event ", err)
			continue
		}

		if ev.op != "add" {continue}
		append(
			images,
			Image {
				id = ev.id,
				oid = ev.oid,
				path = ev.path,
				tags = ev.tags,
				width = ev.width,
				height = ev.height,
				name = ev.name,
				mtime = ev.mtime,
				added_at = ev.addedAt,
				content_type = ev.contentType,
			},
		)
	}
}

// init_new_library creates an empty library skeleton under root.
// Idempotent: existing directories are fine; a conflicting file or a
// permission failure returns an error.
init_new_library :: proc(root: string) -> os.Error {
	subdirs := [?]string{"events", "images", "thumbnails", "thumbnails/64", "thumbnails/128"}

	if err := os.mkdir_all(root, os.Permissions_Default_Directory); err != nil {
		return err
	}
	for sub in subdirs {
		path := fmt.tprintf("%s/%s", root, sub)
		if err := os.mkdir_all(path, os.Permissions_Default_Directory); err != nil {
			return err
		}
	}
	return nil
}

@(private = "file")
Id_Giver: struct {
	i:  int,
	mu: sync.Mutex,
}
@(init)
@(private = "file")
init_Id_Giver :: proc "contextless" () {
	sync.guard(&Id_Giver.mu)
	Id_Giver.i = 1
}

requestNewId :: proc() -> int {
	sync.guard(&Id_Giver.mu)
	id := Id_Giver.i
	Id_Giver.i += 1
	return id
}
