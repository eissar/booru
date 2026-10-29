package template

import "../library"
import "core:fmt"
import "core:strings"

// Filter state for the gallery content region.
Gallery_Filter :: struct {
	limit:              int,
	sort:               string, // sort parameter name, e.g. "addedAtAsc"
	tags:               []string,
	offset:             int,
	gallery_url:        string, // full remove-chip URL
	fragment_url:       string, // fragment remove-chip URL
	extra_chips:        []Filter_Chip, // additional chips (deleted, etc.)
	// Thumbnail scan is running; the page shows a live progress indicator.
	thumbnails_pending: bool,
}

// A single removable filter chip beyond the sort chip.
Filter_Chip :: struct {
	key:          string,
	value:        string,
	display:      string,
	gallery_url:  string,
	fragment_url: string,
}

// render_filter_bar renders the filter bar with the hidden limit input and
// the removable filter chips.
render_filter_bar :: proc(f: Gallery_Filter) -> string {
	b := strings.builder_make()

	limit_buf: [20]u8
	limit := fmt.bprintf(limit_buf[:], "%d", f.limit)


	wr(
		&b,
		"<div id=\"filter-bar\"><div id=\"gallery-view-controls\" hx-preserve class=\"gallery-view-controls\" aria-label=\"Gallery view\"><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-masonry\" value=\"masonry\" checked/><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-grid\" value=\"grid\"/><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-list\" value=\"list\"/><label class=\"gallery-view-label rounded cursor-pointer\" for=\"gallery-view-masonry\" title=\"Masonry\"><img src=\"/static/icons/view-columns.svg\" class=\"gallery-view-icon\" style=\"filter: var(--icon-filter);\" alt=\"Masonry\"/></label><label class=\"gallery-view-label rounded cursor-pointer\" for=\"gallery-view-grid\" title=\"Grid\"><img src=\"/static/icons/squares-2x2.svg\" class=\"gallery-view-icon\" style=\"filter: var(--icon-filter);\" alt=\"Grid\"/></label><label class=\"gallery-view-label rounded cursor-pointer\" for=\"gallery-view-list\" title=\"List\"><img src=\"/static/icons/queue-list.svg\" class=\"gallery-view-icon\" style=\"filter: var(--icon-filter);\" alt=\"List\"/></label></div><input type=\"hidden\" name=\"limit\"",
	)
	attr(&b, "value", limit)
	wr(&b, "/>")
	if f.sort != "" {
		label_buf: [512]u8
		label: string
		if len("sort: ") + len(f.sort) <= len(label_buf) {
			label = fmt.bprintf(label_buf[:], "sort: %s", f.sort)
		} else {
			label = fmt.aprintf("sort: %s", f.sort)
			defer delete(label)
		}
		write_filter_chip(&b, "sort", f.sort, label, f.gallery_url, f.fragment_url)
	}
	for chip in f.extra_chips {
		write_filter_chip(
			&b,
			chip.key,
			chip.value,
			chip.display,
			chip.gallery_url,
			chip.fragment_url,
		)
	}
	wr(&b, "</div>")
	return strings.to_string(b)
}

write_filter_chip :: proc(
	b: ^strings.Builder,
	key, value, display, gallery_url, fragment_url: string,
) {
	wr(
		b,
		"<span class=\"filter-chip text-xs font-medium px-2 py-1 rounded backdrop-blur-sm tag-badge\"",
	)
	attr(b, "data-filter-key", key)
	wr(b, "><input type=\"hidden\"")
	attr(b, "name", key)
	attr(b, "value", value)
	wr(b, "/><a")
	attr(b, "href", gallery_url)
	attr(b, "hx-get", fragment_url)
	wr(b, " hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\">")
	escape_text(b, display)
	wr(b, "</a></span>")
}

// render_gallery_content renders the replaceable gallery content region.
render_gallery_content :: proc(
	filter: Gallery_Filter,
	images: []library.Image,
	has_more: bool,
) -> string {
	b := strings.builder_make()
	wr(&b, "<div class=\"gallery-content\">")
	wr(&b, "<div id=\"gallery-layout\" class=\"layout\"><section class=\"main-content\">")
	wr(&b, render_filter_bar(filter))
	wr(&b, render_photo_grid(images, filter.offset, has_more))
	wr(&b, "</section></div></div>")
	return strings.to_string(b)
}

// render_gallery_page renders the full initial gallery document.
render_gallery_page :: proc(
	title: string,
	filter: Gallery_Filter,
	images: []library.Image,
	has_more: bool,
) -> string {
	b := strings.builder_make()

	wr(
		&b,
		"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/><title>",
	)
	escape_text(&b, title)
	wr(&b, "</title>")
	// Starts the first mipmap batch before the body's <img> requests; the URL
	// must match the one gallery.js fetches.
	if len(images) > 0 {
		wr(&b, "<link rel=\"preload\" as=\"fetch\" href=\"/mipmap/64?ids=")
		for image, i in images {
			if i > 0 {wr(&b, ",")}
			wr(&b, fmt.tprint(image.id))
		}
		wr(&b, "\" fetchpriority=\"high\" crossorigin=\"anonymous\"/>")
	}
	wr(
		&b,
		"<script src=\"/static/htmx.min.js\"></script><script src=\"/static/htmx-response-targets.js\"></script><script src=\"/static/htmx-sse.js\"></script><link href=\"/static/tailwind.css\" rel=\"stylesheet\"/><link href=\"/static/gallery.css\" rel=\"stylesheet\"/><script src=\"/static/gallery.js\"></script></head><body",
	)
	wr(&b, " class=\"antialiased\" hx-ext=\"response-targets\">")
	write_toolbar(&b, filter)
	wr(
		&b,
		"<main id=\"gallery-main\" class=\"gallery-main main-scroll\"><script>try{if(localStorage.getItem('inspector-open')==='true')document.getElementById('gallery-main')?.classList.add('inspector-open')}catch(_){}</script>",
	)
	wr(&b, render_gallery_content(filter, images, has_more))
	write_inspector_shell(&b)
	wr(
		&b,
		"</main><canvas id=\"thumbnail-background\" aria-hidden=\"true\"></canvas><div id=\"toasts-log\"></div>",
	)
	write_toast_template(&b)
	wr(&b, "</body></html>")

	return strings.to_string(b)
}
// Select_Option is one <option> in a toolbar select.
Select_Option :: struct {
	value:    string,
	selected: bool,
}

// write_toolbar writes the static gallery toolbar. The page-size and sort
// selects mark the active options as selected.
write_toolbar :: proc(b: ^strings.Builder, f: Gallery_Filter) {
	wr(
		b,
		"<header id=\"toolbar\" class=\"sticky top-0 z-20 backdrop-blur-lg\" style=\"background-color: var(--bg-surface); border-bottom: 1px solid var(--border-color-light);\"><div class=\"toolbar-row flex items-center h-16\"><div class=\"toolbar-actions flex items-center gap-4 text-sm flex-1 min-w-0\">",
	)

	wr(
		b,
		"<div class=\"relative inline-block\"><details class=\"relative\" name=\"header\"><summary id=\"settings-button\" class=\"toolbar-icon-button p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"/static/icons/cog.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Settings\"/></summary><div class=\"absolute right-0 mt-2 w-64 rounded z-10 dropdown-container\" style=\"background-color: var(--bg-surface);\"><form id=\"preferences\" method=\"get\" action=\"/gallery\" hx-get=\"/fragment/gallery-content\" hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" hx-include=\"#filter-bar\" class=\"p-4 rounded space-y-3\"><label class=\"block text-sm font-medium\" for=\"page-size-input\">Page size</label>",
	)

	write_select(
		b,
		"page-size-input",
		"limit",
		{
			{"10", f.limit == 10},
			{"25", f.limit == 25},
			{"50", f.limit == 50},
			{"100", f.limit == 100},
		},
	)

	wr(b, "<label class=\"block text-sm font-medium\" for=\"sort-input\">Sort</label>")
	write_select(
		b,
		"sort-input",
		"sort",
		{
			{"idAsc", f.sort == "idAsc"},
			{"idDesc", f.sort == "idDesc"},
			{"addedAtAsc", f.sort == "addedAtAsc"},
			{"addedAtDesc", f.sort == "addedAtDesc"},
		},
	)

	wr(
		b,
		"<button type=\"submit\" class=\"w-full py-2 px-4 rounded bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Apply</button></form></div></details></div><div class=\"relative inline-block\"><button type=\"button\" id=\"dark-mode-toggle\" class=\"toolbar-icon-button p-2 rounded cursor-pointer hover-surface focus-ring\"><img class=\"h-5 w-5 sun-icon\" src=\"/static/icons/sun.svg\" style=\"filter: var(--icon-filter);\"/><img class=\"h-5 w-5 moon-icon\" src=\"/static/icons/moon.svg\" style=\"filter: var(--icon-filter);\"/></button></div><div class=\"relative inline-block\"><details class=\"relative\" name=\"header\"><summary id=\"upload-button\" aria-haspopup=\"true\" class=\"toolbar-icon-button p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"/static/icons/arrow-up-tray.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Upload\"/></summary><div class=\"absolute right-0 mt-2 w-96 rounded z-10 overflow-auto dropdown-container max-h-80\" style=\"-ms-overflow-style:none; scrollbar-width:none; background-color: var(--bg-surface);\"><form id=\"upload-form\" hx-post=\"/ingest\" hx-encoding=\"multipart/form-data\" hx-target=\"#toasts-log\" hx-target-error=\"#toasts-log\" hx-swap=\"beforeend\" data-hx-on-dragover=\"event.preventDefault(); this.classList.add('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500')\" data-hx-on-dragleave=\"event.preventDefault(); this.classList.remove('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500')\" data-hx-on-drop=\"event.preventDefault(); this.classList.remove('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500'); if(event.dataTransfer.files.length > 0) document.getElementById('file-input').files = event.dataTransfer.files;\" class=\"p-4 rounded transition-all duration-200\"><input type=\"file\" name=\"image\" id=\"file-input\" class=\"block w-full text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:text-sm file:font-medium file:bg-indigo-50 file:text-indigo-700 hover:file:bg-indigo-100 mb-4\" required/><button type=\"submit\" id=\"submit-button\" class=\"w-full py-2 px-4 rounded bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Upload</button></form></div></details></div>",
	)
	wr(
		b,
		"<div class=\"relative inline-block\"><details class=\"relative\" name=\"header\"><summary id=\"jobs-button\" aria-label=\"Jobs\" class=\"toolbar-icon-button p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"/static/icons/rectangle-stack.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Jobs\"/></summary><div id=\"jobs-panel\" class=\"absolute right-0 mt-2 w-72 p-4 rounded z-10 dropdown-container\" style=\"background-color: var(--bg-surface);\">",
	)
	if f.thumbnails_pending {
		wr(
			b,
			"<div id=\"thumbnail-progress\" class=\"thumbnail-progress\" role=\"status\" aria-live=\"polite\" hx-ext=\"sse\" sse-connect=\"/events/progress\" sse-swap=\"progress\" sse-close=\"done\"></div>",
		)
	} else {
		wr(b, "<div class=\"gallery-status\">No jobs</div>")
	}
	wr(b, "</div></details></div>")
	wr(
		b,
		"<details class=\"toolbar-search\"><summary class=\"toolbar-icon-button mobile-search-toggle p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"/static/icons/magnifying-glass.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"\"/><span class=\"sr-only\">Search gallery</span></summary><form id=\"search-form\" method=\"get\" action=\"/gallery\" hx-get=\"/fragment/gallery-content\" hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" class=\"flex items-center h-10 gap-4 w-full max-w-xs flex-shrink-0\"><input id=\"search-input\" type=\"search\" autofocus name=\"q\" placeholder=\"Search...\" class=\"block w-full h-full border border-transparent rounded px-4 input-field\" required/><button type=\"submit\" class=\"search-submit hover-surface focus-ring\" aria-label=\"Search\" tabindex=\"-1\"><img src=\"/static/icons/magnifying-glass.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"\"/></button></form></details></div></div></header>",
	)
}

// write_select writes a select element with the shared input classes.
write_select :: proc(b: ^strings.Builder, id, name: string, options: []Select_Option) {
	wr(b, "<select")
	attr(b, "id", id)
	attr(b, "name", name)
	wr(
		b,
		" class=\"block w-full border border-transparent rounded py-2 px-3 input-field focus-ring\">",
	)
	for opt in options {
		wr(b, "<option")
		attr(b, "value", opt.value)
		if opt.selected {wr(b, " selected")}
		wr(b, ">")
		escape_text(b, opt.value)
		wr(b, "</option>")
	}
	wr(b, "</select>")
}

// write_inspector_shell writes the static inspector aside.
write_inspector_shell :: proc(b: ^strings.Builder) {
	wr(
		b,
		"<aside id=\"inspector\" class=\"inspector shrink-0 transition-[width] duration-150 ease-in-out\"><div class=\"inspector-inner flex h-full flex-col\"><header class=\"inspector-header shrink-0\"><div class=\"min-w-0\"><h2 class=\"truncate font-semibold\">Inspector</h2><p class=\"text-muted\">Image details</p></div><div class=\"ml-auto flex items-center gap-1\"><button type=\"button\" class=\"rounded p-1 hover-surface\" data-hx-on-click=\"booruToggleInspector(false)\"><img src=\"/static/icons/x-mark.svg\" class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\" alt=\"Close\"/></button></div></header><div id=\"inspector-content\" class=\"inspector-body min-h-0 flex-1 overflow-y-auto\" data-hx-on::after-swap=\"document.getElementById('gallery-main')?.classList.add('inspector-open')\"></div></div></aside>",
	)
}
