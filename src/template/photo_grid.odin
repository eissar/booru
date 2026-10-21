package template

import "core:fmt"
import "core:strings"

import "../library"

// render_photo_grid renders the masonry grid with its load-more controls.
// offset is the count displayed so far; has_more controls the control markup.
render_photo_grid :: proc(images: []library.Image, offset: int, has_more: bool) -> string {
	b := strings.builder_make()

	offset_buf: [20]u8
	offset_str := fmt.bprintf(offset_buf[:], "%d", offset)


	wr(&b, "<div id=\"photo-grid\" class=\"masonry-grid\">")
	// offset is the count shown including this page, so this batch starts at
	// position `offset - len(images)` in the listing. Cards carry globally
	// increasing render-order ids so client JS can restore canonical order
	// after masonry packing, regardless of arrival order.
	first_order := offset - len(images)
	for image, i in images {
		wr(&b, render_item_card(image, first_order + i))
	}

	wr(
		&b,
		"<div id=\"pagination-controls\" class=\"px-1 pb-1\"><input type=\"hidden\" name=\"offset\"",
	)
	attr(&b, "value", offset_str)
	wr(&b, "/>")
	if has_more {
		wr(
			&b,
			"<button type=\"button\" hx-get=\"/fragment/items\" hx-target=\"#pagination-controls\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" hx-select=\"#photo-grid > *\" hx-include=\"#filter-bar,#pagination-controls\" class=\"mt-6 w-full py-2 px-4 rounded bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Load more <span class=\"text-sm opacity-80\">(showing ",
		)
		escape_text(&b, offset_str)
		wr(&b, ")</span></button>")
	} else {
		wr(
			&b,
			"<div role=\"status\" class=\"gallery-status gallery-pagination-status\">No more to show <span class=\"ml-1 text-sm opacity-80\">(showing ",
		)
		escape_text(&b, offset_str)
		wr(&b, ")</span></div>")
	}
	wr(&b, "</div></div>")

	return strings.to_string(b)
}
