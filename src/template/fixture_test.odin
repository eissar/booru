package template

// Render synthetic data and compare against hand-authored HTML fixtures.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "../library"
import "core:testing"

Event :: struct {
	op:           string,
	id:           int,
	oid:          string,
	path:         string,
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        i64,
	added_at:     i64,
	content_type: string,
}

load_images :: proc(path: string) -> []library.Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	images: [dynamic]library.Image
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
			library.Image {
				id = ev.id,
				oid = ev.oid,
				path = ev.path,
				tags = ev.tags,
				width = ev.width,
				height = ev.height,
				name = ev.name,
				mtime = ev.mtime,
				added_at = ev.added_at,
				content_type = ev.content_type,
			},
		)
	}
	return images[:]
}

expect_html_fixture :: proc(t: ^testing.T, name, html: string) {
	path := fmt.tprintf("test/html-fixture-tdd/fixture/%s.expected.html", name)
	expected_bytes, read_err := os.read_entire_file(path, context.allocator)
	if !testing.expect(
		t,
		read_err == nil,
		fmt.tprintf("HTML fixture %s: read error=%v", name, read_err),
	) {
		return
	}
	defer delete(expected_bytes)

	expected, expected_ok := normalize_html(string(expected_bytes))
	if !testing.expect(
		t,
		expected_ok,
		fmt.tprintf("HTML fixture %s: could not normalize expected HTML", name),
	) {
		return
	}
	defer delete(expected)

	actual, actual_ok := normalize_html(html)
	if !testing.expect(
		t,
		actual_ok,
		fmt.tprintf("HTML fixture %s: could not normalize actual HTML", name),
	) {
		return
	}
	defer delete(actual)

	testing.expect(
		t,
		actual == expected,
		fmt.tprintf(
			"HTML mismatch: %s\n--- expected (normalized)\n%s\n+++ actual (normalized)\n%s\n",
			path,
			expected,
			actual,
		),
	)
}

fixture_gallery_filter :: proc() -> Gallery_Filter {
	return {
		limit = 2,
		sort = "addedAtAsc",
		offset = 2,
		gallery_url = "/gallery?limit=2&offset=0",
		fragment_url = "/fragment/gallery-content?limit=2&offset=0",
	}
}

@(test)
html_toast :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	expect_html_fixture(t, "toast", render_toast("Library imported", .Success))
}

@(test)
html_item_card :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	expect_html_fixture(t, "item_card", render_item_card(images[0], -1))
}

@(test)
html_photo_grid :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	expect_html_fixture(t, "photo_grid", render_photo_grid(images[:2], 2, true))
}

@(test)
html_photo_grid_offset :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	// offset counts cards already shown including this page, so a second
	// page's cards must carry globally increasing render-order ids.
	expect_html_fixture(t, "photo_grid_offset", render_photo_grid(images[:2], 4, true))
}

@(test)
html_inspector :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	expect_html_fixture(t, "inspector", render_inspector(images[0]))
}

@(test)
html_gallery_content :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	expect_html_fixture(
		t,
		"gallery_content",
		render_gallery_content(fixture_gallery_filter(), images[:2], true),
	)
}

@(test)
html_gallery_page :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	context.allocator = alloc
	images := load_images("test/fixture/library/events/2026-01.ndjson")
	expect_html_fixture(
		t,
		"gallery_page",
		render_gallery_page("Synthetic library", fixture_gallery_filter(), images[:2], true),
	)
}
