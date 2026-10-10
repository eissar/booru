package template

import "core:fmt"
import "core:strings"

// inspector_icon writes an icon <img> with the shared heroicons attributes.
inspector_icon :: proc(b: ^strings.Builder, name, alt: string) {
	wr(b, "<img")
	attr(b, "src", fmt.tprintf("https://unpkg.com/heroicons@2.0.18/24/outline/%s.svg", name))
	wr(b, " class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\"")
	if alt != "" {
		attr(b, "alt", alt)
	}
	wr(b, "/>")
}

// render_inspector renders the inspector details fragment for one image.
render_inspector :: proc(image: Image) -> string {
	b := strings.builder_make()
	id := itoa(image.id)

	wr(&b, "<section class=\"space-y-4\"><input type=\"hidden\" name=\"id\"")
	attr(&b, "value", id)
	wr(&b, "/><img")
	attr(&b, "src", fmt.tprintf("/image/%s", image.oid))
	attr(&b, "alt", image.name)
	wr(
		&b,
		" class=\"aspect-square w-full rounded-lg object-cover\"/><div class=\"flex\"><p class=\"text-xs text-muted w-full\">",
	)
	escape_text(&b, fmt.tprintf("%d × %d\t|\t%s", image.width, image.height, image.content_type))
	wr(&b, "</p>")

	// refresh button
	wr(
		&b,
		"<button type=\"button\" id=\"inspector-header-refresh\" hx-get=\"/regen-thumbnail\" hx-include=\"#inspector-content input[name=id]\"",
	)
	attr(&b, "hx-target", fmt.tprintf("article[data-image-id=\"%s\"]", id))
	wr(
		&b,
		" hx-swap=\"outerHTML\" hx-indicator=\"#inspector-header-refresh\" class=\"rounded p-1 hover-surface\">",
	)
	inspector_icon(&b, "arrow-path", "Refresh")
	wr(&b, "</button>")

	// delete button
	wr(
		&b,
		"<button type=\"button\" id=\"inspector-header-delete\" hx-post=\"/delete\" hx-include=\"#inspector-content input[name=id]\"",
	)
	attr(&b, "hx-target", fmt.tprintf("article[data-image-id=\"%s\"]", id))
	wr(
		&b,
		" hx-swap=\"delete\" hx-indicator=\"#inspector-header-delete\" class=\"rounded p-1 hover-surface\" data-hx-on:htmx:before-request=\"if(this.dataset.confirmed){delete this.dataset.confirmed;booruRequestMasonryReset?.()}else{event.preventDefault();this.dataset.confirmed='1';setTimeout(()=>delete this.dataset.confirmed,2000)}\" data-hx-on:htmx:after-request=\"if(event.detail.successful)document.getElementById('inspector-content').innerHTML=''\">",
	)
	inspector_icon(&b, "trash", "Delete")
	wr(&b, "</button>")

	// download link
	wr(&b, "<a id=\"inspector-header-download\"")
	attr(&b, "href", fmt.tprintf("/image/%s", image.oid))
	attr(&b, "download", image.name)
	wr(&b, " class=\"rounded p-1 hover-surface\">")
	inspector_icon(&b, "arrow-down-tray", "Download")
	wr(&b, "</a>")

	// open in new tab link
	wr(&b, "<a id=\"inspector-header-open-tab\"")
	attr(&b, "href", fmt.tprintf("/image/%s", image.oid))
	wr(&b, " target=\"_blank\" rel=\"noopener noreferrer\" class=\"rounded p-1 hover-surface\">")
	inspector_icon(&b, "arrow-top-right-on-square", "Open in new tab")
	wr(&b, "</a></div>")

	// metadata form
	wr(
		&b,
		"<form hx-post=\"/update-metadata\" hx-target=\"#inspector-content\" hx-swap=\"innerHTML\"",
	)
	attr(&b, "hx-indicator", fmt.tprintf("#inspector-name-save-%s", id))
	wr(
		&b,
		"><ul class=\"space-y-4\"><li class=\"flex flex-col gap-1\"><span class=\"relative self-start inline-block font-medium text-sm\">Name</span><div class=\"flex items-center gap-2\"><input type=\"hidden\" name=\"id\"",
	)
	attr(&b, "value", id)
	wr(&b, "/><input")
	attr(&b, "id", fmt.tprintf("image-name-%s", id))
	wr(
		&b,
		" class=\"flex-1 min-w-0 input-focus-underline text-xs text-muted\" type=\"text\" name=\"name\"",
	)
	attr(&b, "value", image.name)
	wr(&b, " required autocomplete=\"off\" spellcheck=\"false\"/><button type=\"submit\"")
	attr(&b, "id", fmt.tprintf("inspector-name-save-%s", id))
	wr(&b, " class=\"rounded p-1 hover-surface\" style=\"position: relative;\">")
	wr(
		&b,
		"<img src=\"https://unpkg.com/heroicons@2.0.18/24/outline/check.svg\" alt=\"Save\" class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\"/></button></div></li>",
	)

	// tags row
	wr(
		&b,
		"<li class=\"flex flex-col gap-2\"><span class=\"font-medium shrink-0 flex items-center gap-1\">Tags<button",
	)
	attr(&b, "id", fmt.tprintf("tag-edit-btn-%s", id))
	wr(
		&b,
		" type=\"button\" class=\"rounded p-0.5 hover-surface\" data-hx-on-click=\"\n                                    const i = document.getElementById('image-tags-",
	)
	escape_attr(&b, id)
	wr(
		&b,
		"');\n                                    i.classList.toggle('hidden');\n                                    if (!i.classList.contains('hidden')) i.focus();\n                                \">",
	)
	wr(
		&b,
		"<img src=\"https://unpkg.com/heroicons@2.0.18/24/outline/pencil.svg\" class=\"h-3 w-3\" style=\"filter: var(--icon-filter);\" alt=\"Edit tags\"/></button></span><div class=\"flex flex-wrap gap-2\">",
	)
	if len(image.tags) == 0 {
		wr(&b, "<span class=\"text-xs text-muted\">No tags</span>")
	} else {
		write_tag_badges(&b, image.tags, "")
	}
	wr(&b, "</div><input")
	attr(&b, "id", fmt.tprintf("image-tags-%s", id))
	wr(
		&b,
		" class=\"hidden flex-1 min-w-0 input-focus-underline text-xs text-muted\" type=\"text\" name=\"tags\"",
	)
	attr(&b, "value", strings.join(image.tags, " "))
	wr(&b, " autocomplete=\"off\" spellcheck=\"false\"/></li>")

	write_detail_row(&b, "OID", image.oid, true)
	write_detail_row(&b, "Path", image.path, true)
	write_detail_row(&b, "Added", image.added_at, false)
	write_detail_row(&b, "Modified", image.mtime, false)

	wr(&b, "</ul></form></section>")
	return strings.to_string(b)
}

// write_detail_row writes a read-only inspector label/value row. break_all is
// used for long values like the OID and path.
write_detail_row :: proc(b: ^strings.Builder, label, value: string, break_all: bool) {
	wr(b, "<li class=\"flex flex-col gap-2\"><span class=\"font-medium shrink-0\">")
	escape_text(b, label)
	wr(b, "</span><span class=\"text-xs ")
	wr(b, break_all ? "break-all " : "")
	wr(b, "text-muted\">")
	escape_text(b, value)
	wr(b, "</span></li>")
}
