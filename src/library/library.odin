package library

import "core:mem"
import "core:sys/linux"
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

filter_missing_thumbnails :: proc(
	dfd: ^os.File,
	list: ^map[string]bit_set[LOD_RESOLUTION],
	resolution: LOD_RESOLUTION,
) {
	dents_buf: [32 * 1024]u8

	fd := linux.Fd(os.fd(dfd))

	for {
		n, err := linux.getdents(fd, dents_buf[:])
		if err != nil {return}
		if n == 0 {break} 	// end of directory

		offset := 0
		for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name[0] == '.' {continue} 	// ignore ./../.*

			if !strings.has_suffix(name, ".webp") {continue}
			oid := name[:len(name) - len(".webp")]
			remaining, exists := list^[oid]
			if !exists {continue}
			remaining -= bit_set[LOD_RESOLUTION]{resolution}
			if remaining == {} {
				delete_key(list, oid)
			} else {
				value := &list^[oid]
				value^ = remaining
			}
		}
	}
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
}

find_missing_thumbnails :: proc(s: State, missing: ^map[string]bit_set[LOD_RESOLUTION]) {
	resolutions := make(map[string]LOD_RESOLUTION, allocator = context.temp_allocator)
	defer delete(resolutions)
	resolutions["64"] = .x64
	resolutions["128"] = .x128

	for img in s.library_images {
		missing^[img.oid] = {.x64, .x128}
	}

	for n, r in resolutions {
		pth := fmt.aprintf(
			"%v/thumbnails/%v",
			s.library_path,
			n, // e.g. 64
			allocator = context.temp_allocator,
		)
		osf, err := os.open(pth, {.Read}, {})
		if err != nil {
			continue
		}
		filter_missing_thumbnails(osf, missing, r)
		os.close(osf)
	}

	for n, r in resolutions {
		count := 0
		for _, sizes in missing^ {
			if r in sizes {count += 1}
		}
		fmt.printfln("missing %spx thumbnails: %d", n, count)
	}
}
