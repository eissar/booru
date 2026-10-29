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
			"<span class=\"text-xs font-medium px-2 py-1 rounded backdrop-blur-sm tag-badge\"><a",
		)
		if link_class != "" {
			attr(b, "class", link_class)
			attr(b, "tabindex", "-1")
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

render_card_tags :: proc(tags: []string) -> string {
	b := strings.builder_make()
	write_tag_badges(&b, tags, "image-card-tags")
	return strings.to_string(b)
}

// render_card_actions writes the metadata action bar:
// a tag-edit popover and a download link.
render_card_actions :: proc(b: ^strings.Builder, image: library.Image) {
	id_buf: [20]u8
	id := fmt.bprintf(id_buf[:], "%d", image.id)

	wr(
		b,
		"<div class=\"card-actions\" data-hx-on-click=\"event.stopPropagation()\"><button type=\"button\" class=\"card-action-btn\" title=\"Edit tags\"",
	)
	attrf(b, "popovertarget", "card-tags-%s", id)
	attrf(b, "style", "anchor-name: --card-tags-%s;", id)
	wr(b, ">")
	inspector_icon(b, "hashtag", "Edit tags")
	wr(b, "</button><div")
	attrf(b, "id", "card-tags-%s", id)
	wr(b, " class=\"card-action-popover\" popover")
	attrf(b, "style", "position-anchor: --card-tags-%s;", id)
	wr(b, "><form hx-post=\"/update-metadata\"")
	attrf(b, "hx-target", "#card-tags-list-%s", id)
	wr(b, " hx-target-error=\"#toasts-log\" hx-swap=\"innerHTML\"")
	wr(
		b,
		" data-hx-on-htmx:after-request=\"if(event.detail.successful)this.closest(&#39;[popover]&#39;).hidePopover()\"><input type=\"hidden\" name=\"id\"",
	)
	attr(b, "value", id)
	wr(b, "/><input class=\"card-action-popover-input\" type=\"text\" name=\"tags\"")
	attr(b, "value", strings.join(image.tags, ", "))
	wr(
		b,
		" placeholder=\"tag1, tag2...\" autocomplete=\"off\" spellcheck=\"false\"/><div class=\"card-action-popover-row\"><button type=\"submit\" class=\"card-action-popover-save\">Save</button></div></form></div>",
	)

	wr(b, "<a class=\"card-action-btn\" title=\"Download\"")
	attrf(b, "href", "/image/%s", image.oid)
	attr(b, "download", image.name)
	wr(b, ">")
	inspector_icon(b, "arrow-down-tray", "Download")
	wr(b, "</a></div>")
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
	wr(&b, "</span><div")
	attrf(&b, "id", "card-tags-list-%d", image.id)
	wr(&b, " class=\"flex flex-wrap gap-2 text-xs mt-2\">")
	write_tag_badges(&b, image.tags, "image-card-tags")
	wr(&b, "</div>")
	render_card_actions(&b, image)
	wr(&b, "</div><img")
	attrf(&b, "src", "/image/%s", thumb_src)
	wr(&b, " loading=\"lazy\"")
	wr(
		&b,
		render_order >= 0 && render_order < 6 ? " fetchpriority=\"high\"" : " fetchpriority=\"low\"",
	)
	ia(&b, "width", image.width)
	ia(&b, "height", image.height)
	attr(&b, "style", aspect_ratio)
	wr(&b, " class=\"gallery-card-image order-1\"/>")
	wr(&b, "</div></article>")

	return strings.to_string(b)
}
