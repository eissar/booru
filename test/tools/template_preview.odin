#+feature dynamic-literals
package main


// template_preview: a self-contained, one-page template previewer for the
// Odin HTML renderer.
//
// It renders the six template cases from the synthetic fixture library and
// writes a single interactive page: a tab strip across the top (one tab per
// template), an input sidebar per tab, and an iframe viewer for the rendered
// markup.
//
// Nothing here is a second renderer. Every case calls the same
// src/render procs the test harness calls, so what you preview is exactly what
// test/html-fixture-tdd/fixture_harness_test.ts asserts on. The fixtures stay
// read-only baselines: this tool never writes into test/html-fixture-tdd/fixture.
//
// Modes:
//   template_preview                 -> serve the preview on 0.0.0.0:8971
//   template_preview --cases         -> print <<<CASE>>> blocks (harness parity)
//   template_preview --check         -> same, for diffing against the harness
//
// Nothing is written to disk. The page is assembled in memory and served.
//
// Usage: odin run test/tools -file -out:/tmp/template-preview
//
// Run it from the repository root: paths to fixtures and static assets are
// resolved relative to the process working directory.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import "../../src/render"

// Case identifiers. Order drives the tab strip.
CASE_NAMES := []string {
	"gallery_page",
	"gallery_content",
	"photo_grid",
	"item_card",
	"inspector",
	"toast",
}

CASE_TITLES := map[string]string {
	"gallery_page"    = "Gallery Page",
	"gallery_content" = "Gallery Content",
	"photo_grid"      = "Photo Grid",
	"item_card"       = "Item Card",
	"inspector"       = "Inspector",
	"toast"           = "Toast",
}

// ---------------------------------------------------------------------------
// fixture loading
// ---------------------------------------------------------------------------

// Event mirrors one NDJSON add-event from the fixture shard.
Event :: struct {
	op:           string,
	id:           int,
	oid:          string,
	thumbnailOid: string,
	path:         string,
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        string,
	addedAt:      string,
	contentType:  string,
}

FIXTURES_DIR :: "test/html-fixture-tdd/fixture"

// load_images reads the synthetic library event shard and returns the images
// in file order, matching the test harness exactly.
load_images :: proc(path: string) -> []render.Render_Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("template_preview: cannot read", path)
		fmt.eprintln("template_preview: run from the repository root")
		os.exit(1)
	}

	images: [dynamic]render.Render_Image
	lines := strings.split(string(data), "\n")
	defer delete(lines)

	for line in lines {
		if strings.trim_space(line) == "" { continue }
		ev: Event
		if err := json.unmarshal(transmute([]u8)line, &ev); err != nil {
			fmt.eprintln("template_preview: bad event:", err)
			os.exit(1)
		}
		if ev.op != "add" { continue }
		append(&images, render.Render_Image{
			id = ev.id,
			oid = ev.oid,
			thumbnail_oid = ev.thumbnailOid,
			path = ev.path,
			tags = ev.tags,
			width = ev.width,
			height = ev.height,
			name = ev.name,
			mtime = ev.mtime,
			added_at = ev.addedAt,
			content_type = ev.contentType,
		})
	}
	return images[:]
}

fixture_filter :: proc() -> render.Gallery_Filter {
	return render.Gallery_Filter {
		limit = 2,
		sort = "addedAtAsc",
		offset = 2,
		gallery_url = "/gallery?limit=2&offset=0",
		fragment_url = "/fragment/gallery-content?limit=2&offset=0",
	}
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

// render_cases renders every template case and returns name -> html.
render_cases :: proc(images: []render.Render_Image) -> map[string]string {
	cases := make(map[string]string)

	if len(images) == 0 {
		fmt.eprintln("template_preview: fixture shard contained no add events")
		os.exit(1)
	}

	cases["toast"] = render.render_toast("Library imported", .Success)
	cases["item_card"] = render.render_item_card(images[0], -1)
	cases["photo_grid"] = render.render_card_grid(render.Render_Card_Grid_Input {
		cards = images[:2],
		offset = 2,
		has_more = true,
	})
	cases["inspector"] = render.render_inspector(images[0])

	filter := fixture_filter()
	cases["gallery_content"] = render.render_gallery_content(filter, images[:2], true)
	cases["gallery_page"] = render.render_gallery_page(
		"Synthetic library",
		render.Renderer_Version,
		filter,
		images[:2],
		true,
	)

	return cases
}

// ---------------------------------------------------------------------------
// harness parity mode
// ---------------------------------------------------------------------------

emit_cases :: proc(cases: map[string]string) {
	for name in CASE_NAMES {
		html, ok := cases[name]
		if !ok { continue }
		fmt.printf("<<<CASE %s>>>\n%s\n<<<END>>>\n", name, html)
	}
}

// ---------------------------------------------------------------------------
// preview assembly
// ---------------------------------------------------------------------------

// replace_all is a single-value wrapper over strings.replace_all, whose
// (output, was_allocation) return would otherwise need double assignment at
// every call site.
replace_all :: proc(s, old, new: string) -> string {
	out, _ := strings.replace_all(s, old, new)
	return out
}

// The previewer is served over HTTP and never written to disk, so rendered
// markup uses server-absolute paths that one server can resolve regardless of
// the page's own route.
STATIC_URL :: "/__static"
THUMB_URL :: "/__thumb"

// rewrite_asset_refs points a rendered fragment at the preview server. The app
// serves thumbnails at /image/<oid> and assets at /static/...; the previewer
// serves them from its own routes instead.
rewrite_asset_refs :: proc(html, thumb_url, static_url: string) -> string {
	s := replace_all(html, "src=\"/image/", fmt.tprintf("src=\"%s/", thumb_url))
	s = replace_all(s, "href=\"/static/", fmt.tprintf("href=\"%s/", static_url))
	s = replace_all(s, "src=\"/static/", fmt.tprintf("src=\"%s/", static_url))
	return s
}

// write_fragment_shell wraps a fragment in the DOM context its CSS expects.
//
// Several fragments are styled only in the presence of an ancestor that the
// real gallery page provides:
//
//   .booru-toast     scoped to `#toasts-log .booru-toast`
//   .inspector       width 0 unless an ancestor has `.gallery-main.inspector-open`
//
// The shell reproduces those ancestors so an isolated preview looks the same as
// the fragment does inside a real page.
write_fragment_shell :: proc(b: ^strings.Builder, name, fragment, static_url: string) {
	strings.write_string(b, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/>")
	strings.write_string(b, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>")
	strings.write_string(b, "<title>")
	strings.write_string(b, name)
	strings.write_string(b, "</title>")
	strings.write_string(b, "<script src=\"https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js\"></script>")
	strings.write_string(b, "<script src=\"https://cdn.jsdelivr.net/npm/htmx-ext-response-targets@2.0.4\"></script>")
	strings.write_string(b, "<script src=\"https://cdn.tailwindcss.com\"></script>")
	strings.write_string(b, "<link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;display=swap\" rel=\"stylesheet\"/>")
	strings.write_string(b, "<link href=\"")
	strings.write_string(b, static_url)
	strings.write_string(b, "/gallery.css\" rel=\"stylesheet\"/>")
	strings.write_string(b, "<script src=\"")
	strings.write_string(b, static_url)
	strings.write_string(b, "/gallery.js\"></script>")
	strings.write_string(b, "</head><body class=\"antialiased\">")

	switch name {
	case "Toast":
		// Toasts only get their chrome inside #toasts-log.
		strings.write_string(b, "<div id=\"toasts-log\" class=\"p-6\">")
		strings.write_string(b, fragment)
		strings.write_string(b, "</div>")

	case "Inspector":
		// render_inspector produces the *content* section that the real page
		// injects into #inspector-content. An isolated preview needs the aside
		// shell around it, plus .inspector-open on the main element, otherwise
		// `.inspector` collapses to width 0.
		strings.write_string(b, "<main id=\"gallery-main\" class=\"gallery-main inspector-open\" style=\"display:flex; align-items:stretch; height:100vh;\">")
		strings.write_string(b, "<aside id=\"inspector\" class=\"inspector shrink-0\"><div class=\"inspector-inner flex h-full flex-col\">")
		strings.write_string(b, "<header class=\"inspector-header shrink-0\"><div class=\"min-w-0\"><h2 class=\"truncate text-sm font-semibold\">Inspector</h2><p class=\"text-xs text-muted\">Image details</p></div></header>")
		strings.write_string(b, "<div id=\"inspector-content\" class=\"inspector-body min-h-0 flex-1 overflow-y-auto\">")
		strings.write_string(b, fragment)
		strings.write_string(b, "</div></div></aside></main>")

	case:
		strings.write_string(b, "<div class=\"p-6\">")
		strings.write_string(b, fragment)
		strings.write_string(b, "</div>")
	}

	strings.write_string(b, "</body></html>")
}

// build_documents produces one standalone HTML document per case. gallery_page
// is already a full document, so it is used verbatim; fragments get a shell.
build_documents :: proc(cases: map[string]string, thumb_url, static_url: string) -> map[string]string {
	docs := make(map[string]string)
	for name in CASE_NAMES {
		html, ok := cases[name]
		if !ok { continue }
		rewritten := rewrite_asset_refs(html, thumb_url, static_url)
		if name == "gallery_page" {
			docs[name] = rewritten
			continue
		}
		b := strings.builder_make()
		write_fragment_shell(&b, CASE_TITLES[name], rewritten, static_url)
		docs[name] = strings.to_string(b)
	}
	return docs
}

// json_string writes a JSON-escaped string literal (including quotes).
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case '<':
			// Escape "<" so a rendered fragment can never terminate the host
			// <script> block early (</script> inside the JSON payload).
			strings.write_string(b, "\\u003c")
		case:
			if r < 0x20 {
				fmt.sbprintf(b, "\\u%04x", u32(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

write_docs_json :: proc(b: ^strings.Builder, docs: map[string]string) {
	strings.write_string(b, "{")
	first := true
	for name in CASE_NAMES {
		doc, ok := docs[name]
		if !ok { continue }
		if !first { strings.write_string(b, ",") }
		first = false
		json_string(b, name)
		strings.write_string(b, ":")
		json_string(b, doc)
	}
	strings.write_string(b, "}")
}

// ---------------------------------------------------------------------------
// preview page
// ---------------------------------------------------------------------------

// PREVIEW_SHELL is the viewer chrome. The rendered documents arrive as a JSON
// payload and are injected into per-tab iframes with srcdoc, which keeps the
// full gallery_page document from leaking its styles into the fragment tabs.
PREVIEW_SHELL :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Template preview</title>
<style>
  :root {
    --bg: #0b0d12;
    --panel: #141821;
    --panel-2: #1b2130;
    --line: #2a3142;
    --ink: #e6e9ef;
    --muted: #8b93a7;
    --accent: #6366f1;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body {
    background: var(--bg);
    color: var(--ink);
    font: 13px/1.5 ui-sans-serif, Inter, system-ui, sans-serif;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  header {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
    border-bottom: 1px solid var(--line);
    background: var(--panel);
    flex: 0 0 auto;
  }
  header h1 { font-size: 13px; font-weight: 600; margin: 0; letter-spacing: .02em; }
  header .meta { color: var(--muted); font-size: 11px; }
  .tabs { display: flex; gap: 4px; flex-wrap: wrap; }
  .tab {
    appearance: none;
    border: 1px solid transparent;
    background: transparent;
    color: var(--muted);
    font: inherit;
    padding: 5px 10px;
    border-radius: 6px;
    cursor: pointer;
  }
  .tab:hover { background: var(--panel-2); color: var(--ink); }
  .tab[aria-selected="true"] {
    background: var(--panel-2);
    border-color: var(--line);
    color: var(--ink);
  }
  .spacer { flex: 1 1 auto; }
  .toggle {
    appearance: none; border: 1px solid var(--line); background: var(--panel-2);
    color: var(--muted); font: inherit; font-size: 11px; padding: 4px 8px;
    border-radius: 6px; cursor: pointer;
  }
  .toggle[aria-pressed="true"] { color: var(--ink); border-color: var(--accent); }

  main { flex: 1 1 auto; display: flex; min-height: 0; }

  aside {
    width: 300px;
    flex: 0 0 300px;
    border-right: 1px solid var(--line);
    background: var(--panel);
    overflow-y: auto;
    padding: 12px;
  }
  aside.hidden { display: none; }
  aside h2 {
    font-size: 11px; text-transform: uppercase; letter-spacing: .08em;
    color: var(--muted); margin: 0 0 10px;
  }
  .field { margin-bottom: 12px; }
  .field label {
    display: block; font-size: 11px; color: var(--muted); margin-bottom: 4px;
  }
  .field .hint { font-size: 10px; color: #5d6577; margin-top: 3px; }
  .field input[type="text"],
  .field input[type="number"],
  .field select {
    width: 100%;
    background: var(--bg);
    border: 1px solid var(--line);
    color: var(--ink);
    border-radius: 6px;
    padding: 6px 8px;
    font: inherit;
    font-size: 12px;
  }
  .field input:focus, .field select:focus {
    outline: none; border-color: var(--accent);
  }
  .field.check { display: flex; align-items: center; gap: 8px; }
  .field.check input { accent-color: var(--accent); }
  .field.check label { margin: 0; }
  .images { display: flex; flex-direction: column; gap: 4px; }
  .images .row {
    display: flex; align-items: center; gap: 8px;
    padding: 5px 7px; border: 1px solid var(--line); border-radius: 6px;
    cursor: pointer; background: var(--bg);
  }
  .images .row:hover { border-color: var(--accent); }
  .images .row img {
    width: 26px; height: 26px; object-fit: cover; border-radius: 4px;
    background: var(--panel-2);
  }
  .images .row span { font-size: 11px; }
  .images .row small { color: var(--muted); font-size: 10px; margin-left: auto; }
  aside .note {
    color: var(--muted); font-size: 11px; border-top: 1px solid var(--line);
    padding-top: 10px; margin-top: 14px;
  }
  aside .actions { display: flex; gap: 6px; margin-bottom: 14px; }
  aside .actions button {
    flex: 1 1 auto; appearance: none; cursor: pointer; font: inherit; font-size: 11px;
    padding: 6px 8px; border-radius: 6px; border: 1px solid var(--line);
    background: var(--panel-2); color: var(--ink);
  }
  aside .actions button:hover { border-color: var(--accent); }

  .stage { flex: 1 1 auto; display: flex; flex-direction: column; min-width: 0; background: var(--bg); }
  .stage .bar {
    display: flex; align-items: center; gap: 10px;
    padding: 7px 14px; border-bottom: 1px solid var(--line);
    background: var(--panel); color: var(--muted); font-size: 11px;
  }
  .stage .bar .case { color: var(--ink); font-weight: 600; }
  .frame-wrap { flex: 1 1 auto; min-height: 0; padding: 0; }
  iframe {
    width: 100%; height: 100%; border: 0; background: #fff; display: block;
  }
  #empty { padding: 24px; color: var(--muted); }
</style>
</head>
<body>
<header>
  <h1>Template preview</h1>
  <nav class="tabs" id="tabs" role="tablist"></nav>
  <span class="spacer"></span>
  <span class="meta" id="meta"></span>
  <button class="toggle" id="toggle-inputs" aria-pressed="true">inputs</button>
</header>

<main>
  <aside id="sidebar">
    <h2 id="sidebar-title">Input data</h2>
    <div class="actions">
      <button type="button" id="reset-case">Reset tab</button>
      <button type="button" id="reset-all">Reset all</button>
    </div>
    <div id="fields"></div>
    <div class="note">
      Inputs are local to this page and re-render the markup live. The
      fixture-backed baseline is never modified.
    </div>
  </aside>

  <section class="stage">
    <div class="bar">
      <span class="case" id="case-name"></span>
      <span id="render-info"></span>
    </div>
    <div class="frame-wrap">
      <iframe id="viewer" title="Rendered template"></iframe>
    </div>
  </section>
</main>

<script id="baseline" type="application/json">__DOCS_JSON__</script>
<script id="images" type="application/json">__IMAGES_JSON__</script>
<script>
(function () {
  "use strict";

  var BASELINE = JSON.parse(document.getElementById("baseline").textContent);
  var IMAGES = JSON.parse(document.getElementById("images").textContent);
  var ORDER = __CASE_ORDER__;
  var TITLES = __CASE_TITLES__;

  // --- escaping ---------------------------------------------------------
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  // Mirrors template.escape_attr / escape_text.
  function escText(s) { return esc(s); }

  // --- per-case field descriptors --------------------------------------
  // kind: text | number | bool | select | image | images
  var SCHEMA = {
    gallery_page: [
      { key: "title", kind: "text", label: "title", def: "Synthetic library" },
      { key: "version", kind: "text", label: "version", def: "default" },
      { key: "limit", kind: "number", label: "filter.limit", def: 2 },
      { key: "sort", kind: "select", label: "filter.sort", def: "addedAtAsc", options: ["", "addedAtAsc", "addedAtDesc"] },
      { key: "offset", kind: "number", label: "filter.offset", def: 2 },
      { key: "gallery_url", kind: "text", label: "filter.gallery_url", def: "/gallery?limit=2&offset=0" },
      { key: "fragment_url", kind: "text", label: "filter.fragment_url", def: "/fragment/gallery-content?limit=2&offset=0" },
      { key: "images", kind: "images", label: "images", def: [0, 1], max: 3 },
      { key: "has_more", kind: "bool", label: "has_more", def: true }
    ],
    gallery_content: [
      { key: "limit", kind: "number", label: "filter.limit", def: 2 },
      { key: "sort", kind: "select", label: "filter.sort", def: "addedAtAsc", options: ["", "addedAtAsc", "addedAtDesc"] },
      { key: "offset", kind: "number", label: "filter.offset", def: 2 },
      { key: "gallery_url", kind: "text", label: "filter.gallery_url", def: "/gallery?limit=2&offset=0" },
      { key: "fragment_url", kind: "text", label: "filter.fragment_url", def: "/fragment/gallery-content?limit=2&offset=0" },
      { key: "images", kind: "images", label: "images", def: [0, 1], max: 3 },
      { key: "has_more", kind: "bool", label: "has_more", def: true }
    ],
    photo_grid: [
      { key: "images", kind: "images", label: "cards", def: [0, 1], max: 3 },
      { key: "offset", kind: "number", label: "offset", def: 2 },
      { key: "has_more", kind: "bool", label: "has_more", def: true }
    ],
    item_card: [
      { key: "image", kind: "image", label: "image", def: 0 },
      { key: "render_order", kind: "number", label: "render_order", def: -1, hint: "-1 omits data-render-order-id; 0-5 also sets fetchpriority=high" }
    ],
    inspector: [
      { key: "image", kind: "image", label: "image", def: 0 }
    ],
    toast: [
      { key: "message", kind: "text", label: "message", def: "Library imported" },
      { key: "variant", kind: "select", label: "variant", def: "Success", options: ["Default", "Success", "Error"] }
    ]
  };

  var state = {};      // case -> { key: value }
  var active = null;

  function defaultsFor(name) {
    var out = {};
    (SCHEMA[name] || []).forEach(function (f) {
      out[f.key] = Array.isArray(f.def) ? f.def.slice() : f.def;
    });
    return out;
  }
  ORDER.forEach(function (name) { state[name] = defaultsFor(name); });

  // --- rendering (mirrors src/template/*.odin) --------------------------
  function itoa(n) { return String(n | 0); }
  function attr(name, value) { return " " + name + '="' + esc(value) + '"'; }
  function ia(name, value) { return " " + name + '="' + (value | 0) + '"'; }
  function aspectStyle(w, h) { return "aspect-ratio: " + (w | 0) + "/" + (h | 0); }

  var THUMB_URL = __THUMB_URL__;

  function thumbSrc(img) {
    var thumb = img.thumbnailOid && img.thumbnailOid !== "" ? img.thumbnailOid : img.oid;
    return THUMB_URL + "/" + thumb + ".webp";
  }

  function tagHref(tag) { return "/gallery?tags=" + esc(tag); }
  function tagFragmentHref(tag) { return "/fragment/gallery-content?tags=" + esc(tag); }

  function tagBadges(tags, linkClass) {
    var out = "";
    (tags || []).forEach(function (tag) {
      out += '<span class="text-xs font-medium px-2 py-1 rounded-full backdrop-blur-sm tag-badge"><a';
      if (linkClass) out += attr("class", linkClass);
      out += attr("href", tagHref(tag)) + attr("hx-get", tagFragmentHref(tag));
      out += ' hx-include="#filter-bar" hx-target=".gallery-content" hx-target-error="#toasts-log" hx-swap="outerHTML">';
      out += escText(tag) + "</a></span>";
    });
    return out;
  }

  function itemCard(image, renderOrder) {
    var s = "";
    var thumbSrcValue = thumbSrc(image);
    s += '<article class="masonry-item group"' + ia("data-image-id", image.id);
    if (renderOrder >= 0) s += ia("data-render-order-id", renderOrder);
    s += '><div class="gallery-card relative overflow-hidden flex flex-col rounded-lg hover-card"><div class="gallery-card-meta block p-4 w-full peer order-2"';
    s += attr("hx-get", "/fragment/inspect/" + image.id);
    s += ' hx-target="#inspector-content" hx-target-error="#toasts-log" hx-swap="innerHTML" data-hx-on-click="booruToggleInspector(true)"><span class="font-medium truncate">';
    s += escText(image.name);
    s += '</span><div class="flex flex-wrap gap-2 text-xs mt-2">';
    s += tagBadges(image.tags, "image-card-tags");
    s += '</div></div><img' + attr("src", thumbSrcValue) + ' loading="lazy"';
    s += (renderOrder >= 0 && renderOrder < 6) ? ' fetchpriority="high"' : ' fetchpriority="low"';
    s += ia("width", image.width) + ia("height", image.height);
    s += attr("style", aspectStyle(image.width, image.height));
    s += ' class="gallery-card-image transition-transform duration-300 peer-hover:scale-105 order-1"/></div></article>';
    return s;
  }

  function filterChip(key, value, display, galleryUrl, fragmentUrl) {
    var s = '<span class="filter-chip text-xs font-medium px-2 py-1 rounded-full backdrop-blur-sm tag-badge"><input type="hidden"';
    s += attr("name", key) + attr("value", value) + "/><a";
    s += attr("href", galleryUrl) + attr("hx-get", fragmentUrl);
    s += ' hx-target=".gallery-content" hx-target-error="#toasts-log" hx-swap="outerHTML">#';
    s += escText(display) + "×</a></span>";
    return s;
  }

  function filterBar(f) {
    var s = '<div id="filter-bar"><input type="hidden" name="limit"' + attr("value", itoa(f.limit)) + "/>";
    if (f.sort !== "") {
      s += filterChip("sort", f.sort, "sort: " + f.sort, f.gallery_url, f.fragment_url);
    }
    s += "</div>";
    return s;
  }

  function galleryContent(f, images, hasMore) {
    var s = '<div class="gallery-content">' + filterBar(f);
    s += '<div id="gallery-layout" class="layout"><section class="main-content">';
    s += photoGrid(images, f.offset, hasMore);
    s += "</section></div></div>";
    return s;
  }

  function photoGrid(images, offset, hasMore) {
    var s = '<div id="photo-grid" class="masonry-grid">';
    (images || []).forEach(function (img, i) { s += itemCard(img, i); });
    s += '<div id="pagination-controls" class="px-1 pb-1"><input type="hidden" name="offset"' + attr("value", itoa(offset)) + "/>";
    if (hasMore) {
      s += '<button type="button" hx-get="/fragment/items" hx-target="#pagination-controls" hx-target-error="#toasts-log" hx-swap="outerHTML" hx-select="#photo-grid > *" hx-include="#filter-bar,#pagination-controls" class="mt-6 w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring">Load more <span class="text-sm opacity-80">(showing ';
      s += escText(itoa(offset)) + ")</span></button>";
    } else {
      s += '<div role="status" class="gallery-status gallery-pagination-status">No more to show <span class="ml-1 text-sm opacity-80">(showing ';
      s += escText(itoa(offset)) + ")</span></div>";
    }
    s += "</div></div>";
    return s;
  }

  function inspectorIcon(name, alt) {
    var s = "<img" + attr("src", "https://unpkg.com/heroicons@2.0.18/24/outline/" + name + ".svg");
    s += ' class="h-4 w-4" style="filter: var(--icon-filter);"';
    if (alt) s += attr("alt", alt);
    s += "/>";
    return s;
  }

  function detailRow(label, value, breakAll) {
    var s = '<li class="flex flex-col gap-2"><span class="font-medium shrink-0">' + escText(label);
    s += '</span><span class="text-xs ' + (breakAll ? "break-all " : "") + 'text-muted">';
    s += escText(value) + "</span></li>";
    return s;
  }

  function inspector(image) {
    var b = "";
    var id = itoa(image.id);
    b += '<section class="space-y-4"><input type="hidden" name="id"' + attr("value", id) + "/><img";
    b += attr("src", thumbSrc(image)) + attr("alt", image.name);
    b += ' class="aspect-square w-full rounded-lg object-cover"/><div class="flex"><p class="text-xs text-muted w-full">';
    b += escText((image.width | 0) + " × " + (image.height | 0) + "\t|\t" + image.contentType);
    b += "</p>";

    b += '<button type="button" id="inspector-header-refresh" hx-get="/regen-thumbnail" hx-include="#inspector-content input[name=id]"';
    b += attr("hx-target", 'article[data-image-id="' + id + '"]');
    b += ' hx-swap="outerHTML" hx-indicator="#inspector-header-refresh" class="rounded p-1 hover-surface">';
    b += inspectorIcon("arrow-path", "Refresh") + "</button>";

    b += '<button type="button" id="inspector-header-delete" hx-post="/delete" hx-include="#inspector-content input[name=id]"';
    b += attr("hx-target", 'article[data-image-id="' + id + '"]');
    b += " hx-swap=\"delete\" hx-indicator=\"#inspector-header-delete\" class=\"rounded p-1 hover-surface\" data-hx-on:htmx:before-request=\"if(this.dataset.confirmed){delete this.dataset.confirmed;booruRequestMasonryReset?.()}else{event.preventDefault();this.dataset.confirmed='1';setTimeout(()=>delete this.dataset.confirmed,2000)}\" data-hx-on:htmx:after-request=\"if(event.detail.successful)document.getElementById('inspector-content').innerHTML=''\">";
    b += inspectorIcon("trash", "Delete") + "</button>";

    b += '<a id="inspector-header-download"' + attr("href", "/image/" + image.oid) + attr("download", image.name);
    b += ' class="rounded p-1 hover-surface">' + inspectorIcon("arrow-down-tray", "Download") + "</a>";

    b += '<a id="inspector-header-open-tab"' + attr("href", "/image/" + image.oid);
    b += ' target="_blank" rel="noopener noreferrer" class="rounded p-1 hover-surface">';
    b += inspectorIcon("arrow-top-right-on-square", "Open in new tab") + "</a></div>";

    b += '<form hx-post="/update-metadata" hx-target="#inspector-content" hx-swap="innerHTML"';
    b += attr("hx-indicator", "#inspector-name-save-" + id);
    b += '><ul class="space-y-4"><li class="flex flex-col gap-1"><span class="relative self-start inline-block font-medium text-sm">Name</span><div class="flex items-center gap-2"><input type="hidden" name="id"';
    b += attr("value", id) + "/><input" + attr("id", "image-name-" + id);
    b += ' class="flex-1 min-w-0 input-focus-underline text-xs text-muted" type="text" name="name"';
    b += attr("value", image.name);
    b += ' required autocomplete="off" spellcheck="false"/><button type="submit"';
    b += attr("id", "inspector-name-save-" + id);
    b += ' class="rounded p-1 hover-surface" style="position: relative;">';
    b += '<img src="https://unpkg.com/heroicons@2.0.18/24/outline/check.svg" alt="Save" class="h-4 w-4" style="filter: var(--icon-filter);"/></button></div></li>';

    b += '<li class="flex flex-col gap-2"><span class="font-medium shrink-0 flex items-center gap-1">Tags<button';
    b += attr("id", "tag-edit-btn-" + id);
    b += ' type="button" class="rounded p-0.5 hover-surface" data-hx-on-click="\n                                    const i = document.getElementById(\'image-tags-';
    b += esc(id);
    b += "');\n                                    i.classList.toggle('hidden');\n                                    if (!i.classList.contains('hidden')) i.focus();\n                                \">";
    b += '<img src="https://unpkg.com/heroicons@2.0.18/24/outline/pencil.svg" class="h-3 w-3" style="filter: var(--icon-filter);" alt="Edit tags"/></button></span><div class="flex flex-wrap gap-2">';
    if (!image.tags || image.tags.length === 0) {
      b += '<span class="text-xs text-muted">No tags</span>';
    } else {
      b += tagBadges(image.tags, "");
    }
    b += "</div><input" + attr("id", "image-tags-" + id);
    b += ' class="hidden flex-1 min-w-0 input-focus-underline text-xs text-muted" type="text" name="tags"';
    b += attr("value", (image.tags || []).join(" "));
    b += ' autocomplete="off" spellcheck="false"/></li>';

    b += detailRow("OID", image.oid, true);
    b += detailRow("Path", image.path, true);
    b += detailRow("Added", image.addedAt, false);
    b += detailRow("Modified", image.mtime, false);

    b += "</ul></form></section>";
    return b;
  }

  function toast(message, variant) {
    var s = '<div class="booru-toast ';
    if (variant === "Success") s += "booru-toast-success";
    else if (variant === "Error") s += "booru-toast-error";
    s += '" role="alert"><span>' + escText(message) + "</span>";
    s += '<button type="button" class="booru-toast-dismiss" hx-on-click="this.closest(\'.booru-toast\').remove()">Dismiss</button></div>';
    return s;
  }

  function writeSelect(id, name, options) {
    var s = "<select" + attr("id", id) + attr("name", name);
    s += ' class="block w-full border border-transparent rounded-lg py-2 px-3 input-field focus-ring">';
    options.forEach(function (o) {
      s += "<option" + attr("value", o.value) + (o.selected ? " selected" : "") + ">";
      s += escText(o.value) + "</option>";
    });
    return s + "</select>";
  }

  function writeToolbar(f) {
    var b = "";
    b += '<header id="toolbar" class="sticky top-0 z-20 backdrop-blur-lg" style="background-color: var(--bg-surface); border-bottom: 1px solid var(--border-color-light);"><div class="px-4 sm:px-6 lg:px-8 flex items-center h-16"><div class="gallery-view-controls mr-auto" aria-label="Gallery view"><input class="gallery-view-input" type="radio" name="gallery-view" id="gallery-view-masonry" value="masonry" checked/><input class="gallery-view-input" type="radio" name="gallery-view" id="gallery-view-grid" value="grid"/><input class="gallery-view-input" type="radio" name="gallery-view" id="gallery-view-list" value="list"/><label class="gallery-view-label" for="gallery-view-masonry">Masonry</label><label class="gallery-view-label" for="gallery-view-grid">Grid</label><label class="gallery-view-label" for="gallery-view-list">List</label></div><div class="flex items-center gap-4 text-sm flex-1 min-w-0 justify-end ml-auto"><form id="search-form" method="get" action="/gallery" class="flex items-center h-10 gap-2 w-full max-w-xs flex-shrink-0"><input id="search-input" type="search" name="q" placeholder="Search..." class="block w-full h-full border border-transparent rounded-lg px-4 input-field" required/>';
    b += '<button type="submit" class="h-full px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring">Search</button></form><div class="relative inline-block"><details class="relative" name="header"><summary id="settings-button" class="p-2 rounded cursor-pointer list-none hover-surface focus-ring"><img src="https://unpkg.com/heroicons@2.0.13/24/outline/cog.svg" class="h-5 w-5" style="filter: var(--icon-filter);" alt="Settings"/></summary><div class="absolute right-0 mt-2 w-64 rounded shadow-lg z-10 dropdown-container" style="background-color: var(--bg-surface);"><form id="preferences" method="get" action="/gallery" hx-get="/fragment/gallery-content" hx-target=".gallery-content" hx-target-error="#toasts-log" hx-swap="outerHTML" hx-include="#filter-bar" class="p-4 rounded-md space-y-3"><label class="block text-sm font-medium" for="page-size-input">Page size</label>';
    b += writeSelect("page-size-input", "limit", [
      { value: "2", selected: f.limit === 2 },
      { value: "10", selected: f.limit === 10 },
      { value: "25", selected: f.limit === 25 },
      { value: "50", selected: f.limit === 50 },
      { value: "100", selected: f.limit === 100 }
    ]);
    b += '<label class="block text-sm font-medium" for="sort-input">Sort</label>';
    b += writeSelect("sort-input", "sort", [
      { value: "idAsc", selected: f.sort === "idAsc" },
      { value: "idDesc", selected: f.sort === "idDesc" },
      { value: "addedAtAsc", selected: f.sort === "addedAtAsc" },
      { value: "addedAtDesc", selected: f.sort === "addedAtDesc" }
    ]);
    b += '<button type="submit" class="w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring">Apply</button></form></div></details></div><div class="relative inline-block"><button type="button" id="dark-mode-toggle" class="p-2 rounded cursor-pointer hover-surface focus-ring"><img class="h-5 w-5 sun-icon" src="https://unpkg.com/heroicons@2.0.18/24/outline/sun.svg" style="filter: var(--icon-filter);"/><img class="h-5 w-5 moon-icon" src="https://unpkg.com/heroicons@2.0.18/24/outline/moon.svg" style="filter: var(--icon-filter);"/></button></div><div class="relative inline-block"><button id="inspector-toggle" type="button" class="p-2 rounded cursor-pointer hover-surface focus-ring" data-hx-on-click="booruToggleInspector()"><img src="https://unpkg.com/heroicons@2.0.18/24/outline/information-circle.svg" class="h-5 w-5" style="filter: var(--icon-filter);" alt="Inspector"/></button></div><div class="relative inline-block"><details class="relative" name="header"><summary id="upload-button" aria-haspopup="true" class="p-2 rounded cursor-pointer list-none hover-surface focus-ring"><img src="https://unpkg.com/heroicons@2.0.13/24/outline/arrow-up-tray.svg" class="h-5 w-5" style="filter: var(--icon-filter);" alt="Upload"/></summary><div class="absolute right-0 mt-2 w-96 rounded shadow-lg z-10 overflow-auto dropdown-container max-h-80" style="-ms-overflow-style:none; scrollbar-width:none; background-color: var(--bg-surface);"><form id="upload-form" hx-post="/ingest" hx-encoding="multipart/form-data" hx-target="#toasts-log" hx-target-error="#toasts-log" hx-swap="beforeend" data-hx-on-dragover="event.preventDefault(); this.classList.add(\'opacity-75\', \'outline-dashed\', \'outline-2\', \'outline-indigo-500\')" data-hx-on-dragleave="event.preventDefault(); this.classList.remove(\'opacity-75\', \'outline-dashed\', \'outline-2\', \'outline-indigo-500\')" data-hx-on-drop="event.preventDefault(); this.classList.remove(\'opacity-75\', \'outline-dashed\', \'outline-2\', \'outline-indigo-500\'); if(event.dataTransfer.files.length > 0) document.getElementById(\'file-input\').files = event.dataTransfer.files;" class="p-4 rounded-md transition-all duration-200"><input type="file" name="image" id="file-input" class="block w-full text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:text-sm file:font-medium file:bg-indigo-50 file:text-indigo-700 hover:file:bg-indigo-100 mb-4" required/><button type="submit" id="submit-button" class="w-full py-2 px-4 rounded-md bg-indigo-600 text-white font-medium hover:bg-indigo-700 focus-ring">Upload</button></form></div></details></div></div></div></header>';
    return b;
  }

  function writeInspectorShell() {
    return '<aside id="inspector" class="inspector shrink-0 transition-[width] duration-150 ease-in-out"><div class="inspector-inner flex h-full flex-col"><header class="inspector-header shrink-0"><div class="min-w-0"><h2 class="truncate text-sm font-semibold">Inspector</h2><p class="text-xs text-muted">Image details</p></div><div class="ml-auto flex items-center gap-1"><button type="button" class="rounded p-1 hover-surface" data-hx-on-click="booruToggleInspector(false)"><img src="https://unpkg.com/heroicons@2.0.18/24/outline/x-mark.svg" class="h-4 w-4" style="filter: var(--icon-filter);" alt="Close"/></button></div></header><div id="inspector-content" class="inspector-body min-h-0 flex-1 overflow-y-auto" data-hx-on-after-swap="document.getElementById(\'gallery-main\')?.classList.add(\'inspector-open\')"></div><footer id="inspector-footer" class="inspector-footer shrink-0"><button type="button" hx-get="/genai/tags" hx-include="#inspector-content input[name=id]" hx-target="#inspector-ai-tags" hx-swap="innerHTML" class="rounded p-1 hover-surface"><img src="https://unpkg.com/heroicons@2.0.18/24/outline/sparkles.svg" class="h-4 w-4" style="filter: var(--icon-filter);" alt="Suggest tags"/></button><p class="text-xs text-muted">gen-ai</p><div id="inspector-ai-tags" data-hx-on-InspectorNavigation="this.replaceChildren()"></div></footer></div></aside>';
  }

  var STATIC_URL = __STATIC_URL__;

  // The host page embeds this script inline, so a literal closing-script
  // sequence must never appear in the source or the HTML parser will
  // terminate the block early. Tags are assembled from fragments instead.
  var LT = "<", GT = ">";
  function scriptTag(attrs) { return LT + "script" + (attrs ? " " + attrs : "") + GT; }
  function scriptEnd() { return LT + "/script" + GT; }

  function galleryPage(title, version, f, images, hasMore) {
    var b = "";
    b += '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/><title>';
    b += escText(title);
    b += "</title>";
    b += scriptTag('src="https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js"') + scriptEnd();
    b += scriptTag('src="https://cdn.jsdelivr.net/npm/htmx-ext-response-targets@2.0.4"') + scriptEnd();
    b += scriptTag('src="https://cdn.tailwindcss.com"') + scriptEnd();
    b += '<link rel="preconnect" href="https://fonts.googleapis.com"/><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous"/>';
    b += '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;display=swap" rel="stylesheet"/>';
    b += '<link href="' + STATIC_URL + '/gallery.css" rel="stylesheet"/>' + scriptTag('src="' + STATIC_URL + '/gallery.js"') + scriptEnd() + '</head><body';
    b += attr("data-renderer-version", version);
    b += ' class="antialiased" hx-ext="response-targets">';
    b += writeToolbar(f);
    b += '<main id="gallery-main" class="gallery-main main-scroll">' + scriptTag() + 'try{if(localStorage.getItem(\'inspector-open\')===\'true\')document.getElementById(\'gallery-main\')?.classList.add(\'inspector-open\')}catch(_){}' + scriptEnd();
    b += galleryContent(f, images, hasMore);
    b += writeInspectorShell();
    b += '</main><div id="toasts-log"></div></body></html>';
    return b;
  }

  function renderCase(name, st) {
    function pick(indices) {
      return (indices || []).map(function (i) { return IMAGES[i]; }).filter(Boolean);
    }
    var filter;
    switch (name) {
      case "toast":
        return toast(st.message, st.variant);
      case "item_card":
        return itemCard(IMAGES[st.image] || IMAGES[0], Number(st.render_order));
      case "photo_grid":
        return photoGrid(pick(st.images), Number(st.offset), !!st.has_more);
      case "inspector":
        return inspector(IMAGES[st.image] || IMAGES[0]);
      case "gallery_content":
        filter = {
          limit: Number(st.limit), sort: st.sort, offset: Number(st.offset),
          gallery_url: st.gallery_url, fragment_url: st.fragment_url
        };
        return galleryContent(filter, pick(st.images), !!st.has_more);
      case "gallery_page":
        filter = {
          limit: Number(st.limit), sort: st.sort, offset: Number(st.offset),
          gallery_url: st.gallery_url, fragment_url: st.fragment_url
        };
        return galleryPage(st.title, st.version, filter, pick(st.images), !!st.has_more);
    }
    return "";
  }

  // --- viewer -----------------------------------------------------------
  var viewer = document.getElementById("viewer");
  var sidebar = document.getElementById("sidebar");
  var fieldsEl = document.getElementById("fields");
  var tabsEl = document.getElementById("tabs");

  // Per-case wrappers. Several fragments are styled only in the presence of an
  // ancestor the real gallery page provides, so an isolated preview must
  // reproduce that context or it renders unstyled/collapsed:
  //
  //   toast      .booru-toast is scoped to #toasts-log .booru-toast
  //   inspector  .inspector is width 0 without .gallery-main.inspector-open
  var BASE_HEAD = "";
  (function buildHead() {
    var base = BASELINE.gallery_page || "";
    var headEnd = base.indexOf("</head>");
    if (headEnd < 0) return;
    BASE_HEAD = base.slice(0, headEnd) + "</head>";
  })();

  var WRAPPERS = {
    toast: {
      open: '<body class="antialiased"><div id="toasts-log" class="p-6">',
      close: "</div></body></html>"
    },
    inspector: {
      open: '<body class="antialiased"><main id="gallery-main" class="gallery-main inspector-open" style="display:flex; align-items:stretch; height:100vh;"><aside id="inspector" class="inspector shrink-0"><div class="inspector-inner flex h-full flex-col"><header class="inspector-header shrink-0"><div class="min-w-0"><h2 class="truncate text-sm font-semibold">Inspector</h2><p class="text-xs text-muted">Image details</p></div></header><div id="inspector-content" class="inspector-body min-h-0 flex-1 overflow-y-auto">',
      close: "</div></div></aside></main></body></html>"
    },
    _default: {
      open: '<body class="antialiased"><div class="p-6">',
      close: "</div></body></html>"
    }
  };

  function wrapperFor(name) {
    return WRAPPERS[name] || WRAPPERS._default;
  }

  function wrapDocument(name, html) {
    var isDoc = html.trimStart().toLowerCase().indexOf("<!doctype") === 0;
    if (isDoc) return html;
    var w = wrapperFor(name);
    return BASE_HEAD + w.open + html + w.close;
  }

  function renderInfo(name, html) {
    document.getElementById("render-info").textContent =
      html.length + " bytes · " + (html.match(/<[a-zA-Z]/g) || []).length + " elements";
  }

  function show(name) {
    active = name;
    var html = renderCase(name, state[name]);
    viewer.srcdoc = wrapDocument(name, html);
    document.getElementById("case-name").textContent = TITLES[name] || name;
    renderInfo(name, html);
    Array.prototype.forEach.call(tabsEl.children, function (btn) {
      btn.setAttribute("aria-selected", String(btn.dataset.case === name));
    });
    document.getElementById("sidebar-title").textContent = "Input data — " + (TITLES[name] || name);
    buildFields(name);
  }

  // --- field widgets ----------------------------------------------------
  function buildFields(name) {
    fieldsEl.innerHTML = "";
    (SCHEMA[name] || []).forEach(function (f) {
      var wrap = document.createElement("div");
      var st = state[name];
      if (f.kind === "bool") {
        wrap.className = "field check";
        var cb = document.createElement("input");
        cb.type = "checkbox";
        cb.id = "f-" + f.key;
        cb.checked = !!st[f.key];
        cb.addEventListener("change", function () { st[f.key] = cb.checked; show(name); });
        var lbl = document.createElement("label");
        lbl.htmlFor = cb.id;
        lbl.textContent = f.label;
        wrap.appendChild(cb);
        wrap.appendChild(lbl);
        fieldsEl.appendChild(wrap);
        return;
      }
      wrap.className = "field";
      var label = document.createElement("label");
      label.textContent = f.label;
      label.htmlFor = "f-" + f.key;
      wrap.appendChild(label);

      if (f.kind === "select") {
        var sel = document.createElement("select");
        sel.id = "f-" + f.key;
        f.options.forEach(function (opt) {
          var o = document.createElement("option");
          o.value = opt;
          o.textContent = opt === "" ? "(none)" : opt;
          sel.appendChild(o);
        });
        sel.value = st[f.key];
        sel.addEventListener("change", function () { st[f.key] = sel.value; show(name); });
        wrap.appendChild(sel);
      } else if (f.kind === "number") {
        var num = document.createElement("input");
        num.type = "number";
        num.id = "f-" + f.key;
        num.value = st[f.key];
        num.addEventListener("input", function () {
          st[f.key] = num.value === "" ? 0 : Number(num.value);
          show(name);
        });
        wrap.appendChild(num);
      } else if (f.kind === "text") {
        var txt = document.createElement("input");
        txt.type = "text";
        txt.id = "f-" + f.key;
        txt.value = st[f.key];
        txt.addEventListener("input", function () { st[f.key] = txt.value; show(name); });
        wrap.appendChild(txt);
      } else if (f.kind === "image") {
        wrap.appendChild(imagePicker(name, f, st, false));
      } else if (f.kind === "images") {
        wrap.appendChild(imagePicker(name, f, st, true));
      }
      if (f.hint) {
        var hint = document.createElement("div");
        hint.className = "hint";
        hint.textContent = f.hint;
        wrap.appendChild(hint);
      }
      fieldsEl.appendChild(wrap);
    });
  }

  function imagePicker(caseName, f, st, multi) {
    var box = document.createElement("div");
    box.className = "images";
    IMAGES.forEach(function (img, i) {
      var row = document.createElement("div");
      row.className = "row";
      var selected = multi ? (st[f.key] || []).indexOf(i) >= 0 : st[f.key] === i;
      row.style.borderColor = selected ? "var(--accent)" : "";
      row.style.background = selected ? "var(--panel-2)" : "";

      var thumb = document.createElement("img");
      thumb.src = thumbSrc(img);
      thumb.alt = img.name;
      row.appendChild(thumb);

      var span = document.createElement("span");
      span.textContent = img.name;
      row.appendChild(span);

      var small = document.createElement("small");
      small.textContent = "#" + img.id;
      row.appendChild(small);

      row.addEventListener("click", function () {
        if (multi) {
          var list = (st[f.key] || []).slice();
          var at = list.indexOf(i);
          if (at >= 0) list.splice(at, 1);
          else {
            if (f.max && list.length >= f.max) list.shift();
            list.push(i);
          }
          list.sort(function (a, b) { return a - b; });
          st[f.key] = list;
        } else {
          st[f.key] = i;
        }
        show(caseName);
      });
      box.appendChild(row);
    });
    return box;
  }

  // --- tabs -------------------------------------------------------------
  ORDER.forEach(function (name) {
    var btn = document.createElement("button");
    btn.className = "tab";
    btn.type = "button";
    btn.role = "tab";
    btn.dataset.case = name;
    btn.textContent = TITLES[name] || name;
    btn.addEventListener("click", function () { show(name); });
    tabsEl.appendChild(btn);
  });

  function refreshTabs() {
    ORDER.forEach(function (name) {
      var btn = tabsEl.querySelector('[data-case="' + name + '"]');
      if (btn) btn.textContent = TITLES[name] || name;
    });
  }

  document.getElementById("reset-case").addEventListener("click", function () {
    state[active] = defaultsFor(active);
    show(active);
  });
  document.getElementById("reset-all").addEventListener("click", function () {
    ORDER.forEach(function (n) { state[n] = defaultsFor(n); });
    show(active);
  });
  var toggle = document.getElementById("toggle-inputs");
  toggle.addEventListener("click", function () {
    var hidden = sidebar.classList.toggle("hidden");
    toggle.setAttribute("aria-pressed", String(!hidden));
  });

  document.getElementById("meta").textContent =
    IMAGES.length + " fixture images · " + ORDER.length + " templates";

  // --- navigation lockdown ---------------------------------------------
  // Rendered templates contain links to real app routes (/gallery, /fragment/*,
  // /image/*). This is a static preview with no server behind those routes, so
  // same-tab navigation is cancelled: the preview never reloads on a click.
  //
  // Links that explicitly ask for a new tab are left alone -- opening the full
  // image elsewhere does not disturb the preview.
  function blockNavigation(root) {
    root.addEventListener("click", function (ev) {
      var el = ev.target;
      while (el && el !== root) {
        if (el.tagName === "A") {
          var target = el.getAttribute("target");
          if (target === "_blank" && !el.hasAttribute("download")) return;
          ev.preventDefault();
          ev.stopPropagation();
          flash("navigation blocked: " + (el.getAttribute("href") || ""));
          return;
        }
        el = el.parentNode;
      }
    }, true); // capture, so template handlers see it last
  }

  // Also trap form submissions (the toolbar search and upload forms).
  function blockForms(root) {
    root.addEventListener("submit", function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      flash("form submission blocked");
    }, true);
  }

  var flashTimer = null;
  function flash(msg) {
    document.getElementById("render-info").textContent = msg;
    if (flashTimer) clearTimeout(flashTimer);
    flashTimer = setTimeout(function () {
      renderInfo(active, renderCase(active, state[active]));
    }, 1600);
  }

  // The viewer iframe is where rendered templates live, so that is what needs
  // trapping. srcdoc documents are same-origin, so the listeners attach to
  // their document on load.
  viewer.addEventListener("load", function () {
    var doc = null;
    try { doc = viewer.contentDocument; } catch (e) { doc = null; }
    if (!doc) return;
    blockNavigation(doc);
    blockForms(doc);
  });

  show(ORDER[0]);
})();
</script>
</body>
</html>
`

// json_string_value renders a bare JSON string literal for a single value.
json_string_value :: proc(s: string) -> string {
	b := strings.builder_make()
	json_string(&b, s)
	return strings.to_string(b)
}

// case_order_json renders the tab order as a JSON array literal.
case_order_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, "[")
	for name, i in CASE_NAMES {
		if i > 0 { strings.write_string(&b, ",") }
		json_string(&b, name)
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

// case_titles_json renders name -> title as a JSON object literal.
case_titles_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{")
	for name, i in CASE_NAMES {
		if i > 0 { strings.write_string(&b, ",") }
		json_string(&b, name)
		strings.write_string(&b, ":")
		json_string(&b, CASE_TITLES[name])
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// images_json renders the fixture images in the shape the viewer expects.
images_json :: proc(images: []render.Render_Image) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "[")
	for img, i in images {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{")
		fmt.sbprintf(&b, "\"id\":%d,", img.id)
		strings.write_string(&b, "\"oid\":")
		json_string(&b, img.oid)
		strings.write_string(&b, ",\"thumbnailOid\":")
		json_string(&b, img.thumbnail_oid)
		strings.write_string(&b, ",\"path\":")
		json_string(&b, img.path)
		strings.write_string(&b, ",\"tags\":[")
		for tag, j in img.tags {
			if j > 0 { strings.write_string(&b, ",") }
			json_string(&b, tag)
		}
		strings.write_string(&b, "],")
		fmt.sbprintf(&b, "\"width\":%d,\"height\":%d,", img.width, img.height)
		strings.write_string(&b, "\"name\":")
		json_string(&b, img.name)
		strings.write_string(&b, ",\"mtime\":")
		json_string(&b, img.mtime)
		strings.write_string(&b, ",\"addedAt\":")
		json_string(&b, img.added_at)
		strings.write_string(&b, ",\"contentType\":")
		json_string(&b, img.content_type)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

// build_preview_page assembles the full previewer document.
build_preview_page :: proc(cases: map[string]string, images: []render.Render_Image, thumb_url, static_url: string) -> string {
	docs := build_documents(cases, thumb_url, static_url)

	b := strings.builder_make()
	strings.write_string(&b, PREVIEW_SHELL)
	page := strings.to_string(b)

	docs_json := strings.builder_make()
	write_docs_json(&docs_json, docs)

	sub := replace_all(page, "__DOCS_JSON__", strings.to_string(docs_json))
	sub = replace_all(sub, "__IMAGES_JSON__", images_json(images))
	sub = replace_all(sub, "__CASE_ORDER__", case_order_json())
	sub = replace_all(sub, "__CASE_TITLES__", case_titles_json())
	sub = replace_all(sub, "__THUMB_URL__", json_string_value(thumb_url))
	sub = replace_all(sub, "__STATIC_URL__", json_string_value(static_url))
	return sub
}

// ---------------------------------------------------------------------------
// server
// ---------------------------------------------------------------------------

// Server is the state a request handler needs: the assembled page and the
// directory served for thumbnails.
Server :: struct {
	page:      string,
	fixtures:  string, // repository-relative fixtures dir
	static:    string, // repository-relative static dir
}

// content_type_for guesses a Content-Type from a file extension.
content_type_for :: proc(path: string) -> string {
	switch {
	case strings.has_suffix(path, ".css"):   return "text/css; charset=utf-8"
	case strings.has_suffix(path, ".js"):    return "text/javascript; charset=utf-8"
	case strings.has_suffix(path, ".html"):  return "text/html; charset=utf-8"
	case strings.has_suffix(path, ".webp"):  return "image/webp"
	case strings.has_suffix(path, ".png"):   return "image/png"
	case strings.has_suffix(path, ".jpg"), strings.has_suffix(path, ".jpeg"): return "image/jpeg"
	case strings.has_suffix(path, ".gif"):   return "image/gif"
	case strings.has_suffix(path, ".svg"):   return "image/svg+xml"
	case strings.has_suffix(path, ".json"):  return "application/json"
	}
	return "application/octet-stream"
}

// send_bytes writes a complete HTTP/1.1 response and closes the connection.
send_bytes :: proc(conn: net.TCP_Socket, status: string, ctype: string, body: []u8, extra := "") {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n",
		status, ctype, len(body), extra,
	)
	net.send_tcp(conn, transmute([]u8)head)
	if len(body) > 0 {
		net.send_tcp(conn, body)
	}
}

send_text :: proc(conn: net.TCP_Socket, status: string, ctype: string, body: string) {
	send_bytes(conn, status, ctype, transmute([]u8)body)
}

// serve_file reads and sends a file from disk, or 404s.
serve_file :: proc(conn: net.TCP_Socket, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		send_text(conn, "404 Not Found", "text/plain; charset=utf-8", fmt.tprintf("not found: %s\n", path))
		return
	}
	send_bytes(conn, "200 OK", content_type_for(path), data)
}

// handle_conn routes one request. Anything that is not the preview page or an
// asset is answered with a harmless 204, so the browser never navigates away.
handle_conn :: proc(srv: Server, conn: net.TCP_Socket) {
	buf: [16 * 1024]byte
	n, err := net.recv_tcp(conn, buf[:])
	if err != nil || n <= 0 {
		net.close(conn)
		return
	}

	// First line: METHOD SP TARGET SP VERSION
	line_end := strings.index(string(buf[:n]), "\r\n")
	if line_end < 0 { line_end = n }
	parts := strings.split(string(buf[:line_end]), " ")
	defer delete(parts)
	if len(parts) < 2 {
		net.close(conn)
		return
	}
	target := parts[1]

	// Strip the query string.
	path := target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}

	switch {
	case path == "/" || path == "/index.html":
		send_text(conn, "200 OK", "text/html; charset=utf-8", srv.page)

	case strings.has_prefix(path, STATIC_URL + "/"):
		name := path[len(STATIC_URL) + 1:]
		// Refuse traversal out of the static directory.
		if strings.contains(name, "..") {
			send_text(conn, "400 Bad Request", "text/plain; charset=utf-8", "bad path\n")
		} else {
			serve_file(conn, fmt.tprintf("%s/%s", srv.static, name))
		}

	case strings.has_prefix(path, THUMB_URL + "/"):
		name := path[len(THUMB_URL) + 1:]
		if strings.contains(name, "..") {
			send_text(conn, "400 Bad Request", "text/plain; charset=utf-8", "bad path\n")
		} else {
			serve_file(conn, fmt.tprintf("%s/library/thumbnails/%s", srv.fixtures, name))
		}

	case path == "/favicon.ico":
		send_bytes(conn, "204 No Content", "text/plain", nil)

	case:
		// Every other route belongs to the real app, which is not running here.
		// Answer 204 so htmx swaps nothing and the page stays put.
		send_bytes(conn, "204 No Content", "text/plain", nil)
	}

	net.close(conn)
}

// serve blocks, answering requests on the given port until interrupted.
serve :: proc(srv: Server, port: int) {
	// Bind all interfaces so the preview is reachable from other devices on the
	// network. This tool serves fixture data and a handful of repo files with no
	// authentication, so only run it on a network you trust.
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port})
	if err != nil {
		fmt.eprintln("template_preview: cannot listen on port", port, ":", err)
		os.exit(1)
	}
	defer net.close(sock)

	fmt.printf("template_preview: serving on 0.0.0.0:%d  (Ctrl-C to stop)\n", port)
	fmt.printf("template_preview:   local   http://127.0.0.1:%d/\n", port)
	fmt.printf("template_preview:   network http://<this-host-ip>:%d/\n", port)

	for {
		conn, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			// Transient accept failures (e.g. EINTR) should not kill the server.
			time.sleep(10 * time.Millisecond)
			continue
		}
		handle_conn(srv, conn)
	}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

usage :: proc() {
	fmt.eprintln("usage: template_preview [--serve|--cases] [fixtures_dir] [port]")
	fmt.eprintln("")
	fmt.eprintln("  --serve   serve the preview over HTTP (default)")
	fmt.eprintln("  --cases   print <<<CASE>>> blocks, matching test/html-fixture-tdd/fixture_harness.odin")
	fmt.eprintln("  --check   alias for --cases")
	fmt.eprintln("")
	fmt.eprintln("Nothing is written to disk in either mode.")
}

DEFAULT_PORT :: 8971

main :: proc() {
	mode := "--serve"
	dir := FIXTURES_DIR
	port := DEFAULT_PORT

	for arg, i in os.args {
		if i == 0 { continue }
		switch arg {
		case "--cases", "--check": mode = "--cases"
		case "--serve": mode = "--serve"
		case "--help", "-h":
			usage()
			return
		case:
			if len(arg) > 0 && arg[0] == '-' { continue }
			// A bare numeric argument is the port; anything else is the
			// fixtures directory.
			if p, ok := parse_int(arg); ok {
				port = p
			} else {
				dir = arg
			}
		}
	}

	images := load_images(fmt.tprintf("%s/library/events/2026-01.ndjson", dir))
	cases := render_cases(images)

	if mode == "--cases" {
		emit_cases(cases)
		return
	}

	page := build_preview_page(cases, images, THUMB_URL, STATIC_URL)
	serve(Server{page = page, fixtures = dir, static = "static"}, port)
}

// parse_int parses a non-negative decimal integer.
parse_int :: proc(s: string) -> (int, bool) {
	if s == "" { return 0, false }
	value := 0
	for r in s {
		if r < '0' || r > '9' { return 0, false }
		value = value * 10 + int(r - '0')
	}
	return value, true
}