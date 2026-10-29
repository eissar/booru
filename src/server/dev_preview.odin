package server

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../http"
import "../library"
import "../store"
import "../template"
import "../vendor/sqlite"

// handle_dev_preview serves /dev/preview: every template rendered with real
// library data on one page, using the app's own CSS and scripts. Query:
// image (index into the library), render_order. Variants are Lua `handle`
// overrides of /dev/preview/* paths (see lua_handle.odin).
handle_dev_preview :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	params := make(map[string]string)
	if !parse_query_params(req.header.query, &params) {
		http.res_error("", res, .BadRequest)
		return
	}

	images, rc := store.read_images(s.data_store, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}

	index, _ := parse_int_param(params["image"])
	index = clamp(index, 0, max(len(images) - 1, 0))
	order := -1
	if v, ok := parse_int_param(params["render_order"]); ok {order = v}

	b := strings.builder_make()
	template.wr(
		&b,
		"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/><title>Preview</title><script src=\"/static/htmx.min.js\"></script><script src=\"/static/htmx-response-targets.js\"></script><link href=\"/static/tailwind.css\" rel=\"stylesheet\"/><link href=\"/static/gallery.css\" rel=\"stylesheet\"/><script src=\"/static/gallery.js\"></script></head><body class=\"antialiased\" hx-ext=\"response-targets\">",
	)

	// Reload when handlers.lua changes: on window focus the current mtime is
	// sent back; the server answers 204, or HX-Refresh when it differs.
	// Option: answer with the re-rendered #dev-preview-cases plus a fresh
	// #lua-mtime as out-of-band swaps (hx-swap-oob="true") instead, keeping
	// scroll position and inputs without a full reload.
	template.wr(&b, "<input type=\"hidden\" id=\"lua-mtime\" name=\"lua_mtime\"")
	template.attr(&b, "value", fmt.tprint(lua_mtime()))
	template.wr(
		&b,
		"/><div hx-get=\"/dev/preview/mtime\" hx-trigger=\"focus from:window\" hx-include=\"#lua-mtime\" hx-swap=\"none\"></div>",
	)

	template.wr(
		&b,
		"<main class=\"main-content\"><form id=\"dev-preview-controls\" hx-get=\"/dev/preview\" hx-trigger=\"change\" hx-target=\"#dev-preview-cases\" hx-select=\"#dev-preview-cases\" hx-swap=\"outerHTML\" hx-push-url=\"true\"><label>image <select name=\"image\">",
	)
	for image, i in images {
		template.wr(&b, "<option")
		template.attr(&b, "value", fmt.tprint(i))
		if i == index {template.wr(&b, " selected")}
		template.wr(&b, ">")
		template.escape_text(&b, image.name)
		template.wr(&b, "</option>")
	}
	template.wr(
		&b,
		"</select></label> <label>render_order <input type=\"number\" name=\"render_order\" min=\"-1\"",
	)
	template.attr(&b, "value", fmt.tprint(order))
	template.wr(&b, "/></label></form><div id=\"dev-preview-cases\">")

	if len(images) == 0 {
		template.wr(&b, "<p>Library is empty.</p>")
	} else {
		image := images[index]
		pair := images[index:min(index + 2, len(images))]
		filter := template.Gallery_Filter {
			limit        = len(pair),
			offset       = index + len(pair),
			gallery_url  = "/gallery",
			fragment_url = "/fragment/gallery-content",
		}
		section(&b, "toast", template.render_toast("Library imported", .Success))
		section(
			&b,
			"item_card",
			strings.concatenate(
				{
					"<div class=\"masonry-grid\">",
					template.render_item_card(image, order),
					"</div>",
				},
			),
		)
		section(&b, "photo_grid", template.render_photo_grid(pair, index + len(pair), true))
		section(
			&b,
			"inspector",
			strings.concatenate(
				{
					"<div class=\"inspector-body\" style=\"max-width: 24rem\">",
					template.render_inspector(image),
					"</div>",
				},
			),
		)
		section(&b, "gallery_content", template.render_gallery_content(filter, pair, true))
	}
	template.wr(&b, "</div></main><div id=\"toasts-log\"></div></body></html>")
	http.res_html(strings.to_string(b), res)
}

// handle_dev_preview_mtime serves /dev/preview/mtime: 204 when the page's
// lua_mtime is current, HX-Refresh when handlers.lua has changed since.
handle_dev_preview_mtime :: proc(res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	params := make(map[string]string)
	parse_query_params(req.header.query, &params)
	sent, _ := strconv.parse_i64(params["lua_mtime"])
	if sent != lua_mtime() {res.headers["HX-Refresh"] = "true"}
	http.res_text("", res, .NoContent)
}

@(private = "file")
section :: proc(b: ^strings.Builder, name, html: string) {
	template.wr(b, "<section style=\"margin-block: 2rem\"><h2 class=\"font-semibold\">")
	template.escape_text(b, name)
	template.wr(b, "</h2>")
	template.wr(b, html)
	template.wr(b, "</section>")
}
