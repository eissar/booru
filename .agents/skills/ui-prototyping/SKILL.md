---
name: ui-prototyping
description: "Prototype N visual variations of an existing template (e.g. render_item_card) so the user can compare them in `task preview`. Use when asked to explore, mock up, or create variations of a rendered component without changing production markup. Not for shipping markup changes; use html-fixture-tdd for that."
---

# ui-prototyping

Variants live only in `test/tools/template_preview.odin` (the JS inside `PREVIEW_SHELL`). They have no fixture and never touch `src/template/`.

## Workflow

1. Read the real template (`src/template/<name>.odin`) and its JS mirror in the preview shell. Prototypes are for visual examination, not interactivity. Match the original's look and real data (name, tags, thumbnail, dimensions); skip `hx-*`/`data-*` wiring unless the visual depends on it.
2. For each variant, add a `registerCase("<template>_<variant>", { title, schema, wrapper, render })` call in the "case registration" block. Do not extend the `renderCase` switch; that switch is for fixture-backed cases only.
   - `schema`: sidebar inputs (reuse `CARD_SCHEMA` for cards).
   - `wrapper`: `{open, close}` HTML placed around the fragment inside the iframe. Put the variant's CSS in a `<style>` here.
   - `render(state)`: returns the HTML string.
3. Styling & Assets: use inline styles or the wrapper `<style>`. `static/tailwind.css` is purged to classes used by `src/template`, so new Tailwind utilities will not exist. Existing theme variables (`--bg-surface`, `--border-color-light`, `--icon-filter`) are available.
   - For local icons or static assets, always reference `STATIC_URL + "/icons/<name>.svg"`, never `/static/...` (the preview server mounts static assets at `/__static` and returns 204 for `/static/`).
4. Check: `task preview -- <port>`, open the page, and click each tab. The page JS can be syntax-checked by saving the last `<script>` of `curl localhost:<port>/` and running `node --check`.
5. Hand the user the port and the tab names. If one variant wins, promote it with `html-fixture-tdd` (fixture first), then delete the other `registerCase` calls.

## Existing examples

`item_card_overlay`, `item_card_polaroid`, `item_card_compact` (variants of `render_item_card`).
