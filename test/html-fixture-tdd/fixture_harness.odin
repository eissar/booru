package main

// Test harness: reads the synthetic library NDJSON fixture, renders each
// template case to stdout in a stable delimited format so the Deno test can
// compare against fixtures structurally. This never reads the expected HTML.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/render"

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

load_images :: proc(path: string) -> []render.Render_Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	images: [dynamic]render.Render_Image
	lines := strings.split(string(data), "\n")
	defer delete(lines)
	for line in lines {
		if strings.trim_space(line) == "" {continue}
		ev: Event
		if err := json.unmarshal(transmute([]u8)line, &ev); err != nil {
			fmt.eprintln("bad event:", err)
			os.exit(1)
		}
		if ev.op != "add" {continue}
		append(
			&images,
			render.Render_Image {
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
	return images[:]
}

emit :: proc(name, html: string) {
	fmt.printf("<<<CASE %s>>>\n%s\n<<<END>>>\n", name, html)
}

main :: proc() {
	dir := os.args[1] if len(os.args) > 1 else "test/html-fixture-tdd/fixture"
	images := load_images("test/fixture/library/events/2026-01.ndjson")

	emit("toast", render.render_toast("Library imported", .Success))
	emit("item_card", render.render_item_card(images[0], -1))
	emit("photo_grid", render.render_card_grid({cards = images[:2], offset = 2, has_more = true}))
	emit("inspector", render.render_inspector(images[0]))

	filter := render.Gallery_Filter {
		limit        = 2,
		sort         = "addedAtAsc",
		offset       = 2,
		gallery_url  = "/gallery?limit=2&offset=0",
		fragment_url = "/fragment/gallery-content?limit=2&offset=0",
	}
	emit("gallery_content", render.render_gallery_content(filter, images[:2], true))
	emit(
		"gallery_page",
		render.render_gallery_page(
			"Synthetic library",
			render.Renderer_Version,
			filter,
			images[:2],
			true,
		),
	)
}
