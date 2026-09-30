package template

import "core:fmt"
import "core:strings"

// Filter state for the gallery content region.
Gallery_Filter :: struct {
	limit:        int,
	sort:         string, // sort parameter name, e.g. "addedAtAsc"
	tags:         []string,
	offset:       int,
	gallery_url:  string, // full remove-chip URL
	fragment_url: string, // fragment remove-chip URL
	extra_chips:  []Filter_Chip, // additional chips (deleted, etc.)
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
	wr(&b, "<div id=\"filter-bar\"><input type=\"hidden\" name=\"limit\"")
	attr(&b, "value", itoa(f.limit))
	wr(&b, "/>")
	if f.sort != "" {
		write_filter_chip(
			&b,
			"sort",
			f.sort,
			fmt.tprintf("sort: %s", f.sort),
			f.gallery_url,
			f.fragment_url,
		)
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
		"<span class=\"filter-chip text-xs font-medium px-2 py-1 rounded-full backdrop-blur-sm tag-badge\"><input type=\"hidden\"",
	)
	attr(b, "name", key)
	attr(b, "value", value)
	wr(b, "/><a")
	attr(b, "href", gallery_url)
	attr(b, "hx-get", fragment_url)
	wr(
		b,
		" hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\">#",
	)
	escape_text(b, display)
	wr(b, "×</a></span>")
}

// render_gallery_content renders the replaceable gallery content region.
render_gallery_content :: proc(filter: Gallery_Filter, images: []Image, has_more: bool) -> string {
	b := strings.builder_make()
	wr(&b, "<div class=\"gallery-content\">")
	wr(&b, render_filter_bar(filter))
	wr(&b, "<div id=\"gallery-layout\" class=\"layout\"><section class=\"main-content\">")
	wr(&b, render_photo_grid(images, filter.offset, has_more))
	wr(&b, "</section></div></div>")
	return strings.to_string(b)
}

// render_gallery_page renders the full initial gallery document. version is
// stamped on <body data-renderer-version>.
render_gallery_page :: proc(
	title, version: string,
	filter: Gallery_Filter,
	images: []Image,
	has_more: bool,
) -> string {
	b := strings.builder_make()

	wr(
		&b,
		"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/><title>",
	)
	escape_text(&b, title)
	wr(
		&b,
		"</title><script src=\"https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js\"></script><script src=\"https://cdn.jsdelivr.net/npm/htmx-ext-response-targets@2.0.4\"></script><script src=\"https://cdn.tailwindcss.com\"></script><link rel=\"preconnect\" href=\"https://fonts.googleapis.com\"/><link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin=\"anonymous\"/><link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;display=swap\" rel=\"stylesheet\"/><link href=\"/static/gallery.css\" rel=\"stylesheet\"/><script src=\"/static/gallery.js\"></script></head><body",
	)
	attr(&b, "data-renderer-version", version)
	wr(&b, " class=\"antialiased\" hx-ext=\"response-targets\">")
	write_toolbar(&b, filter)
	wr(
		&b,
		"<main id=\"gallery-main\" class=\"gallery-main main-scroll\"><script>try{if(localStorage.getItem('inspector-open')==='true')document.getElementById('gallery-main')?.classList.add('inspector-open')}catch(_){}</script>",
	)
	wr(&b, render_gallery_content(filter, images, has_more))
	write_inspector_shell(&b)
	wr(&b, "</main><div id=\"toasts-log\"></div></body></html>")

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
		"<header id=\"toolbar\" class=\"sticky top-0 z-20 backdrop-blur-lg\" style=\"background-color: var(--bg-surface); border-bottom: 1px solid var(--border-color-light);\"><div class=\"px-4 sm:px-6 lg:px-8 flex items-center h-16\"><div class=\"gallery-view-controls mr-auto\" aria-label=\"Gallery view\"><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-masonry\" value=\"masonry\" checked/><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-grid\" value=\"grid\"/><input class=\"gallery-view-input\" type=\"radio\" name=\"gallery-view\" id=\"gallery-view-list\" value=\"list\"/><label class=\"gallery-view-label\" for=\"gallery-view-masonry\">Masonry</label><label class=\"gallery-view-label\" for=\"gallery-view-grid\">Grid</label><label class=\"gallery-view-label\" for=\"gallery-view-list\">List</label></div><div class=\"flex items-center gap-4 text-sm flex-1 min-w-0 justify-end ml-auto\"><form id=\"search-form\" method=\"get\" action=\"/gallery\" class=\"flex items-center h-10 gap-2 w-full max-w-xs flex-shrink-0\"><input id=\"search-input\" type=\"search\" name=\"q\" placeholder=\"Search...\" class=\"block w-full h-full border border-transparent rounded-lg px-4 input-field\" required/>",
	)

	wr(
		b,
		"<button type=\"submit\" class=\"h-full px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Search</button></form><div class=\"relative inline-block\"><details class=\"relative\" name=\"header\"><summary id=\"settings-button\" class=\"p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"https://unpkg.com/heroicons@2.0.13/24/outline/cog.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Settings\"/></summary><div class=\"absolute right-0 mt-2 w-64 rounded shadow-lg z-10 dropdown-container\" style=\"background-color: var(--bg-surface);\"><form id=\"preferences\" method=\"get\" action=\"/gallery\" hx-get=\"/fragment/gallery-content\" hx-target=\".gallery-content\" hx-target-error=\"#toasts-log\" hx-swap=\"outerHTML\" hx-include=\"#filter-bar\" class=\"p-4 rounded-md space-y-3\"><label class=\"block text-sm font-medium\" for=\"page-size-input\">Page size</label>",
	)

	write_select(
		b,
		"page-size-input",
		"limit",
		{
			{"2", f.limit == 2},
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
		"<button type=\"submit\" class=\"w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Apply</button></form></div></details></div><div class=\"relative inline-block\"><button type=\"button\" id=\"dark-mode-toggle\" class=\"p-2 rounded cursor-pointer hover-surface focus-ring\"><img class=\"h-5 w-5 sun-icon\" src=\"https://unpkg.com/heroicons@2.0.18/24/outline/sun.svg\" style=\"filter: var(--icon-filter);\"/><img class=\"h-5 w-5 moon-icon\" src=\"https://unpkg.com/heroicons@2.0.18/24/outline/moon.svg\" style=\"filter: var(--icon-filter);\"/></button></div><div class=\"relative inline-block\"><button id=\"inspector-toggle\" type=\"button\" class=\"p-2 rounded cursor-pointer hover-surface focus-ring\" data-hx-on-click=\"booruToggleInspector()\"><img src=\"https://unpkg.com/heroicons@2.0.18/24/outline/information-circle.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Inspector\"/></button></div><div class=\"relative inline-block\"><details class=\"relative\" name=\"header\"><summary id=\"upload-button\" aria-haspopup=\"true\" class=\"p-2 rounded cursor-pointer list-none hover-surface focus-ring\"><img src=\"https://unpkg.com/heroicons@2.0.13/24/outline/arrow-up-tray.svg\" class=\"h-5 w-5\" style=\"filter: var(--icon-filter);\" alt=\"Upload\"/></summary><div class=\"absolute right-0 mt-2 w-96 rounded shadow-lg z-10 overflow-auto dropdown-container max-h-80\" style=\"-ms-overflow-style:none; scrollbar-width:none; background-color: var(--bg-surface);\"><form id=\"upload-form\" hx-post=\"/ingest\" hx-encoding=\"multipart/form-data\" hx-target=\"#toasts-log\" hx-target-error=\"#toasts-log\" hx-swap=\"beforeend\" data-hx-on-dragover=\"event.preventDefault(); this.classList.add('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500')\" data-hx-on-dragleave=\"event.preventDefault(); this.classList.remove('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500')\" data-hx-on-drop=\"event.preventDefault(); this.classList.remove('opacity-75', 'outline-dashed', 'outline-2', 'outline-indigo-500'); if(event.dataTransfer.files.length > 0) document.getElementById('file-input').files = event.dataTransfer.files;\" class=\"p-4 rounded-md transition-all duration-200\"><input type=\"file\" name=\"image\" id=\"file-input\" class=\"block w-full text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:text-sm file:font-medium file:bg-indigo-50 file:text-indigo-700 hover:file:bg-indigo-100 mb-4\" required/><button type=\"submit\" id=\"submit-button\" class=\"w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring\">Upload</button></form></div></details></div></div></div></header>",
	)
}

// write_select writes a select element with the shared input classes.
write_select :: proc(b: ^strings.Builder, id, name: string, options: []Select_Option) {
	wr(b, "<select")
	attr(b, "id", id)
	attr(b, "name", name)
	wr(
		b,
		" class=\"block w-full border border-transparent rounded-lg py-2 px-3 input-field focus-ring\">",
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
		"<aside id=\"inspector\" class=\"inspector shrink-0 transition-[width] duration-150 ease-in-out\"><div class=\"inspector-inner flex h-full flex-col\"><header class=\"inspector-header shrink-0\"><div class=\"min-w-0\"><h2 class=\"truncate text-sm font-semibold\">Inspector</h2><p class=\"text-xs text-muted\">Image details</p></div><div class=\"ml-auto flex items-center gap-1\"><button type=\"button\" class=\"rounded p-1 hover-surface\" data-hx-on-click=\"booruToggleInspector(false)\"><img src=\"https://unpkg.com/heroicons@2.0.18/24/outline/x-mark.svg\" class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\" alt=\"Close\"/></button></div></header><div id=\"inspector-content\" class=\"inspector-body min-h-0 flex-1 overflow-y-auto\" data-hx-on-after-swap=\"document.getElementById('gallery-main')?.classList.add('inspector-open')\"></div><footer id=\"inspector-footer\" class=\"inspector-footer shrink-0\"><button type=\"button\" hx-get=\"/genai/tags\" hx-include=\"#inspector-content input[name=id]\" hx-target=\"#inspector-ai-tags\" hx-swap=\"innerHTML\" class=\"rounded p-1 hover-surface\"><img src=\"https://unpkg.com/heroicons@2.0.18/24/outline/sparkles.svg\" class=\"h-4 w-4\" style=\"filter: var(--icon-filter);\" alt=\"Suggest tags\"/></button><p class=\"text-xs text-muted\">gen-ai</p><div id=\"inspector-ai-tags\" data-hx-on-InspectorNavigation=\"this.replaceChildren()\"></div></footer></div></aside>",
	)
}
