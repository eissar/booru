---
name: html-fixture-tdd
description: "Fixture-first TDD for the libraryless Odin HTML pipeline in lfs-booru-odin (htmx frontend, no JSX/templates). Use when adding or changing any rendered HTML — templates in src/template/, handlers in src/render/, or htmx-driven client behavior. The workflow: hand-edit the expected HTML fixture first, watch the test go red, then bring the Odin code into agreement. Triggers: add UI, change markup, new template, htmx fragment, update the page/card/toast/grid."
---

# html-fixture-tdd

## The core discipline

**The fixture is the spec. HTML changes always start in `test/html-fixture-tdd/fixture/*.expected.html`, never in `.odin` code.** Odin's JSX-like ergonomics are poor, so writing markup directly in builder calls is error-prone; editing real HTML first is readable, reviewable, and diffable. This reverses the usual "regenerate fixture from code" trap, which trains agents to paste whatever the code emitted — never do that.

## Workflow

1. **Edit the fixture by hand.** Open the relevant `test/html-fixture-tdd/fixture/<case>.expected.html` and write the exact markup you want — structure, attributes, classes, htmx attributes (`hx-get`, `hx-target`, `hx-swap`), ids for `hx-target`/dialogs. Fixtures are one-per-template:
   - `item_card` → `src/template/item_card.odin`
   - `photo_grid` → `src/template/photo_grid.odin`
   - `gallery_content` → `src/template/gallery_page.odin` (content proc)
   - `gallery_page` → `src/template/gallery_page.odin` (page proc)
   - `inspector` → `src/template/inspector.odin`
   - `toast` → `src/template/toast.odin`

2. **Run the test to see RED.**

   ```
   task test:render
   ```

   (also included in `odin test test -all-packages` from the repo root; requires Perl and `HTML::Tidy5`, available on Debian as `libhtml-tidy5-perl`)

   Individual Odin tests in `src/render/fixture_test.odin` render each case and invoke `test/html-fixture-tdd/compare_html.pl` to compare HTML::Tidy5-normalized strings against fixtures (alphabetically sorted attributes and normalized formatting). Tidy can repair markup, so this is not identical to DOM structural comparison. Confirm the failing case is the one you edited, failing for the reason you expect.

3. **Update the Odin code to match.** Change only the template file(s) mapped to that fixture. Shared escaping helpers live in `src/template/html.odin` (`write_text`, `write_attr`, `write_attr_bool`, `escape`). Prefer editing the smallest sibling; don't touch other fixtures.

4. **Run again to GREEN.** Repeat steps 1–4 per feature increment. Small loops: one markup change → one code change → one test run.

5. **Client behavior follows the fixture.** For htmx interactions, ensure endpoints/handlers return fragments whose structure matches what the fixture (and `src/render/render.odin`) produce. New ids/classes introduced in the fixture get wired in `static/` JS/CSS in the same pass.

## Rules & guardrails

- **Never** feed fixture content back from rendered output. There is no fixture-regeneration step for TDD changes; expected HTML is hand-authored.
- **Never modify a fixture to make a failing test pass** — only to change the spec. If a test fails and you didn't intend a markup change, the code is wrong; fix the code.
- **Fixtures must stay consistent with each other.** `gallery_page` embeds `photo_grid`/`item_card` output; if a shared component's markup changes, update every affected fixture before touching code.
- **Bounded retries.** If a template proc needs more than two revisions to match a fixture, stop and reconsider the fixture or the data model rather than iterating blindly.
- **Escaping is part of the spec.** Put literal escaped entities (`&amp;`, `&lt;` …) in the fixture where you expect them; use `write_text`/`write_attr` in code so they arise naturally.
- Run `task fmt` (and the format check) before committing, per AGENTS.md.
- Adding a brand-new template: create the fixture file first, add an individual test in `src/render/fixture_test.odin`, then RED → implement → GREEN.
