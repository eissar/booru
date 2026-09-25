package main

// Library loading: replay NDJSON add-events into an in-memory image list.
// Prototype only -- no derived index, no DB.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "template"

Event :: struct {
	op:           string,
	id:           int,
	oid:          string,
	thumbnailOid: string,
	path:         string,
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        string,
	addedAt:      string,
	contentType:  string,
}

load_library :: proc(root: string) -> []template.Image {
	images: [dynamic]template.Image

	events_dir := fmt.tprintf("%s/events", root)
	dir, open_err := os.open(events_dir)
	if open_err != nil {
		fmt.eprintln("library: cannot open events dir", events_dir, open_err)
		return images[:]
	}
	defer os.close(dir)
	entries, err := os.read_dir(dir, -1)
	if err != nil {
		fmt.eprintln("library: cannot read events dir", events_dir, err)
		return images[:]
	}
	defer {
		for entry in entries { os.file_info_delete(entry) }
		delete(entries)
	}
	for entry in entries {
		if !strings.has_suffix(entry.name, ".ndjson") { continue }
		fp := fmt.tprintf("%s/%s", events_dir, entry.name)
		data, ok := os.read_entire_file(fp)
		if !ok {
			fmt.eprintln("library: cannot read", fp)
			continue
		}
		load_ndjson(&images, string(data), fp)
		delete(data)
	}
	return images[:]
}

load_ndjson :: proc(images: ^[dynamic]template.Image, data: string, src: string) {
	lines := strings.split(data, "\n")
	defer delete(lines)
	for line in lines {
		if strings.trim_space(line) == "" { continue }
		ev: Event
		if err := json.unmarshal(transmute([]u8)line, &ev); err != nil {
			fmt.eprintln("library: bad event in", src, ":", err)
			continue
		}
		if ev.op != "add" { continue }
		append(images, template.Image{
			id            = ev.id,
			oid           = ev.oid,
			thumbnail_oid = ev.thumbnailOid,
			path          = ev.path,
			tags          = ev.tags,
			width         = ev.width,
			height        = ev.height,
			name          = ev.name,
			mtime         = ev.mtime,
			added_at      = ev.addedAt,
			content_type  = ev.contentType,
		})
	}
}
