package template

import "../library"
import "core:fmt"
import "core:strings"

// tag_href builds the full-page gallery link for a tag.
tag_href :: proc(tag: string) -> string {
	b := strings.builder_make()
	wr(&b, "/gallery?tags=")
	escape_attr(&b, tag)
	return strings.to_string(b)
}

// tag_fragment_href builds the gallery-content fragment link for a tag.
tag_fragment_href :: proc(tag: string) -> string {
	b := strings.builder_make()
	wr(&b, "/fragment/gallery-content?tags=")
	escape_attr(&b, tag)
	return strings.to_string(b)
}

// write_tag_badges writes the shared tag badge markup used by cards and the
// inspector. `link_class` optionally adds a class to each anchor.
write_tag_badges :: proc(b: ^strings.Builder, tags: []string, link_class: string) {
	for tag in tags {
		wr(
			b,
			"<span class=\"text-xs font-medium px-2 py-1 rounded-full backdrop-blur-sm tag-badge\"><a",
		)
		if link_class != "" {
			attr(b, "class", link_class)
			attr(b, "hx-trigger", "click consume")
		}
		attr(b, "href", tag_href(tag))
		attr(b, "hx-get", tag_fragment_href(tag))
		wr(
			b,
			" hx-include=\"#filter-bar\" hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\">",
		)
		escape_text(b, tag)
		wr(b, "</a></span>")
	}
}

// render_item_card renders a single masonry image card. render_order is the
// positional index in the listing; the first six load with high priority.
render_item_card :: proc(image: library.Image, render_order: int) -> string {
	b := strings.builder_make()

	// 14 + 1 for / ; 20 bytes for each digit
	aspect_ratio_buf: [55]u8
	aspect_ratio := fmt.bprintf(
		aspect_ratio_buf[:],
		"aspect-ratio: %d/%d",
		image.width,
		image.height,
	)


	thumb_src := image.oid

	wr(&b, "<article class=\"masonry-item group\"")
	ia(&b, "data-image-id", image.id)
	if render_order >= 0 {
		ia(&b, "data-render-order-id", render_order)
	}
	wr(
		&b,
		"><div class=\"gallery-card relative overflow-hidden flex flex-col rounded-lg hover-card\"><div class=\"gallery-card-meta block p-4 w-full peer order-2\"",
	)
	attrf(&b, "hx-get", "/fragment/inspect/%d", image.id)
	attrf(&b, "hx-vals", "%s\"order\":%d%s", "{", render_order, "}")
	wr(
		&b,
		" hx-target=\"#inspector-content\" hx-target-error=\"#toasts-log\" hx-swap=\"innerHTML\"><span class=\"font-medium truncate\">",
	)
	escape_text(&b, image.name)
	wr(&b, "</span><div class=\"flex flex-wrap gap-2 text-xs mt-2\">")
	write_tag_badges(&b, image.tags, "image-card-tags")
	wr(&b, "</div></div><img")
	attrf(&b, "src", "/image/%s", thumb_src)
	wr(&b, " loading=\"lazy\"")
	wr(
		&b,
		render_order >= 0 && render_order < 6 ? " fetchpriority=\"high\"" : " fetchpriority=\"low\"",
	)
	ia(&b, "width", image.width)
	ia(&b, "height", image.height)
	attr(&b, "style", aspect_ratio)
	wr(&b, " class=\"gallery-card-image order-1\"/></div></article>")

	return strings.to_string(b)
}
