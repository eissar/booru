package library

import "core:mem"
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
	op:          string,
	id:          int,
	oid:         string,
	path:        string,
	tags:        []string,
	width:       int,
	height:      int,
	name:        string,
	mtime:       string,
	addedAt:     string,
	contentType: string,
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
