package template

import "core:fmt"
import "core:strings"
import "core:time"

import "../library"

// inspector_icon writes an icon <img> with the shared heroicons attributes.
inspector_icon :: proc(b: ^strings.Builder, name, alt: string) {
	wr(b, "<img")
	attrf(b, "src", "/static/icons/%s.svg", name)
	wr(b, " class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\"")
	if alt != "" {
		attr(b, "alt", alt)
	}
	wr(b, "/>")
}

// render_inspector renders the inspector details fragment for one image.
render_inspector :: proc(image: library.Image, order: int = 0) -> string {
	b := strings.builder_make()

	id_buf: [20]u8 // 64i
	id := fmt.bprintf(id_buf[:], "%d", image.id)

	wr(&b, "<section class=\"space-y-4\"><input type=\"hidden\" name=\"id\"")
	attr(&b, "value", id)
	wr(&b, "/><input type=\"hidden\" name=\"order\"")
	ia(&b, "value", order)
	wr(&b, "/><img")
	attrf(&b, "src", "/image/%s", image.oid)
	attr(&b, "alt", image.name)
	wr(
		&b,
		" class=\"aspect-square w-full rounded-lg object-cover\"/><div class=\"flex\"><p class=\"text-xs text-muted w-full\">",
	)
	textf(&b, "%d × %d\t|\t%s", image.width, image.height, image.content_type)
	wr(&b, "</p>")

	// refresh button
	wr(
		&b,
		"<button type=\"button\" id=\"inspector-header-refresh\" hx-get=\"/regen-thumbnail\" hx-include=\"#inspector-content > section > input\"",
	)
	attrf(&b, "hx-target", "article[data-image-id=\"%s\"]", id)
	wr(
		&b,
		" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" hx-indicator=\"#inspector-header-refresh\" class=\"rounded p-1 hover-surface\">",
	)
	inspector_icon(&b, "arrow-path", "Refresh")
	wr(&b, "</button>")

	// delete button
	wr(
		&b,
		"<button type=\"button\" id=\"inspector-header-delete\" hx-post=\"/delete\" hx-include=\"#inspector-content > section > input[name=id]\"",
	)
	attrf(&b, "hx-target", "article[data-image-id=\"%s\"]", id)
	wr(
		&b,
		" hx-swap=\"delete\" hx-indicator=\"#inspector-header-delete\" class=\"rounded p-1 hover-surface\" data-hx-on:htmx:before-request=\"if(this.dataset.confirmed){delete this.dataset.confirmed}else{event.preventDefault();this.dataset.confirmed='1';setTimeout(()=>delete this.dataset.confirmed,2000)}\" data-hx-on:htmx:after-request=\"if(event.detail.successful)document.getElementById('inspector-content').innerHTML=''\">",
	)
	inspector_icon(&b, "trash", "Delete")
	wr(&b, "</button>")

	// download link
	wr(&b, "<a id=\"inspector-header-download\"")
	attrf(&b, "href", "/image/%s", image.oid)
	attr(&b, "download", image.name)
	wr(&b, " class=\"rounded p-1 hover-surface\">")
	inspector_icon(&b, "arrow-down-tray", "Download")
	wr(&b, "</a>")

	// open in new tab link
	wr(&b, "<a id=\"inspector-header-open-tab\"")
	attrf(&b, "href", "/image/%s", image.oid)
	wr(&b, " target=\"_blank\" rel=\"noopener noreferrer\" class=\"rounded p-1 hover-surface\">")
	inspector_icon(&b, "arrow-top-right-on-square", "Open in new tab")
	wr(&b, "</a></div>")

	// metadata form
	wr(
		&b,
		"<form hx-post=\"/update-metadata\" hx-target=\"#inspector-content\" hx-swap=\"innerHTML\"",
	)
	attrf(&b, "hx-indicator", "#inspector-name-save-%s", id)
	wr(
		&b,
		"><ul class=\"space-y-4\"><li class=\"flex flex-col gap-1\"><span class=\"relative self-start inline-block font-medium text-sm\">Name</span><div class=\"flex items-center gap-2\"><input type=\"hidden\" name=\"id\"",
	)
	attr(&b, "value", id)
	wr(&b, "/><input")
	attrf(&b, "id", "image-name-%s", id)
	wr(
		&b,
		" class=\"flex-1 min-w-0 input-focus-underline text-xs text-muted\" type=\"text\" name=\"name\"",
	)
	attr(&b, "value", image.name)
	wr(&b, " required autocomplete=\"off\" spellcheck=\"false\"/><button type=\"submit\"")
	attrf(&b, "id", "inspector-name-save-%s", id)
	wr(&b, " class=\"rounded p-1 hover-surface\" style=\"position: relative;\">")
	wr(
		&b,
		"<img src=\"/static/icons/check.svg\" alt=\"Save\" class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\"/></button></div></li>",
	)

	// comment row shares the metadata form's save button.
	wr(&b, "<li class=\"flex flex-col gap-1\"><label")
	attrf(&b, "for", "image-comment-%s", id)
	wr(&b, " class=\"font-medium text-sm\">Comment</label><textarea")
	attrf(&b, "id", "image-comment-%s", id)
	wr(
		&b,
		" name=\"comment\" rows=\"4\" class=\"w-full input-focus-underline text-xs text-muted\">",
	)
	escape_text(&b, image.comment)
	wr(&b, "</textarea></li>")

	// tags row
	wr(
		&b,
		"<li class=\"flex flex-col gap-2\"><span class=\"font-medium shrink-0 flex items-center gap-1\">Tags<button",
	)
	attrf(&b, "id", "tag-edit-btn-%s", id)
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
		"<img src=\"/static/icons/pencil.svg\" class=\"h-3 w-3\" style=\"filter: var(--icon-filter);\" alt=\"Edit tags\"/></button></span><div class=\"flex flex-wrap gap-2\">",
	)
	if len(image.tags) == 0 {
		wr(&b, "<span class=\"text-xs text-muted\">No tags</span>")
	} else {
		write_tag_badges(&b, image.tags, "")
	}
	wr(&b, "</div><input")
	attrf(&b, "id", "image-tags-%s", id)
	wr(
		&b,
		" class=\"hidden flex-1 min-w-0 input-focus-underline text-xs text-muted\" type=\"text\" name=\"tags\"",
	)
	attr(&b, "value", strings.join(image.tags, " "))
	wr(&b, " autocomplete=\"off\" spellcheck=\"false\"/></li>")

	write_detail_row(&b, "OID", image.oid, true)
	write_detail_row(&b, "Path", image.path, true)
	write_detail_row(&b, "Added", format_timestamp_ms(image.added_at), false)
	write_detail_row(&b, "Modified", format_timestamp_ms(image.mtime), false)

	wr(&b, "</ul></form></section>")
	return strings.to_string(b)
}

// format_timestamp_ms renders epoch milliseconds as UTC ISO text; zero is blank.
@(private = "file")
format_timestamp_ms :: proc(ms: i64) -> string {
	if ms == 0 {return ""}
	dt, _ := time.time_to_datetime(time.Time{_nsec = ms * 1_000_000})
	return fmt.tprintf(
		"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		ms % 1000,
	)
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
