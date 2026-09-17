package template

import "core:strings"

// render_photo_grid renders the masonry grid with its load-more controls.
// offset is the count displayed so far; has_more controls the control markup.
render_photo_grid :: proc(images: []Image, offset: int, has_more: bool) -> string {
	b := strings.builder_make()

	wr(&b, "<div id=\"photo-grid\" class=\"masonry-grid\">")
	for image, i in images {
		wr(&b, render_item_card(image, i))
	}

	wr(&b, "<div id=\"pagination-controls\" class=\"px-1 pb-1\"><input type=\"hidden\" name=\"offset\"")
	attr(&b, "value", itoa(offset))
	wr(&b, "/>")
	if has_more {
		wr(&b, "<button type=\"button\" hx-get=\"/fragment/items\" hx-target=\"#pagination-controls\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" hx-select=\"#photo-grid > *\" hx-include=\"#filter-bar,#pagination-controls\" class=\"mt-6 w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Load more <span class=\"text-sm opacity-80\">(showing ")
		escape_text(&b, itoa(offset))
		wr(&b, ")</span></button>")
	} else {
		wr(&b, "<div role=\"status\" class=\"gallery-status gallery-pagination-status\">No more to show <span class=\"ml-1 text-sm opacity-80\">(showing ")
		escape_text(&b, itoa(offset))
		wr(&b, ")</span></div>")
	}
	wr(&b, "</div></div>")

	return strings.to_string(b)
}