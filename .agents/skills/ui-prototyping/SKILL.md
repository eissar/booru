---
name: ui-prototyping
description: "Explore visual variations of an existing template for comparison in `task preview`. For production markup changes, use html-fixture-tdd instead."
---

# ui-prototyping

Variants live in the JS inside `PREVIEW_SHELL` in `test/tools/template_preview.odin`. Do not change fixtures or `src/template/`.

## Workflow

1. Read the real template (`src/template/<name>.odin`) and its JS mirror in the preview shell. Prototypes are for visual examination, not interactivity. Match the original's look and real data (name, tags, thumbnail, dimensions); skip `hx-*`/`data-*` wiring unless the visual depends on it.
2. For each variant, add a `registerCase("<template>_<variant>", { title, schema, wrapper, render })` call in the "case registration" block. Do not extend the `renderCase` switch; that switch is for fixture-backed cases only.
   - Label tab titles `A`, `B`, `C`, … and refer to variants by those letters.
   - `schema`: sidebar inputs (reuse `CARD_SCHEMA` for cards).
   - `wrapper`: `{open, close}` HTML placed around the fragment inside the iframe. Put the variant's CSS in a `<style>` here.
   - `render(state)`: returns the HTML string.
3. Use inline styles or the wrapper `<style>` and existing theme variables (`--bg-surface`, `--border-color-light`, `--icon-filter`). New Tailwind utilities are unavailable: `static/tailwind.css` includes only classes used by `src/template`.
   - For local icons or static assets, always reference `STATIC_URL + "/icons/<name>.svg"`, never `/static/...` (the preview server mounts static assets at `/__static` and returns 204 for `/static/`).
4. Run `odin run -file test/tools/template_preview.odin -- --check` for tidy HTML checks. Stop there: do not run `task preview`, open a browser, syntax-check JS, or add validation tooling.
5. Give the user `task preview` and the tab letters for visual comparison. If one variant wins, promote it with `html-fixture-tdd` (fixture first), then delete the other `registerCase` calls.

## Existing examples

`item_card_overlay`, `item_card_polaroid`, `item_card_compact` (variants of `render_item_card`).
