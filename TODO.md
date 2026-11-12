high level tasks

- [ ] Move platform-specific `when ODIN_OS` branches that depend on platform-only imports into suffixed files such as `_windows.odin` and `_linux.odin`. Keep those imports in their platform files so `odin check -vet` does not flag imports needed only by another target. Cover `src/dirlist`, `src/importers/eagle_import.odin`, and `src/thumbnail/generate_missing_thumbnails.odin`, and audit for other occurrences.

Harden flat parser: validation, boundaries, tests/fuzzing.
Harden event semantics: required fields, patch/clear rules, ordering, replay progress, and failure recovery.

- [ ] [v1] Make events CloudEvent compatible.
- [ ] Review existing replay panic/error states and thoroughly evaluate when a failed incremental replay (`full_replay = false`) can safely fall back to full replay.
- [ ] Classify startup store errors and rebuild only when restartable. Already done: a stale schema (missing columns, detected as `SCHEMA_MISMATCH` from `prepare_item_patch`) discards `store.sqlite` and rebuilds once per startup (`src/main.odin`). Remaining: `PRAGMA user_version` check, `SQLITE_CORRUPT`, and refusing non-restartable errors. Restartable means the derived `store.sqlite` is bad or stale: e.g. a stale schema (`PRAGMA user_version` mismatch, such as a store without the `deleted` column) or `SQLITE_CORRUPT`; discard it and do a full replay, at most once per startup. Not restartable means rebuilding can't help: e.g. `SQLITE_FULL` (disk full), or a replay `.BadEvent`, where the log is the problem. The README's "discards and rebuilds" claim is not implemented yet.
- [ ] Enforce the assumption that older event shards are fully applied: either deduplicate, clean, and compress historical shards so they are immutable (locked by convention), or check their persisted offsets against actual file lengths.

- [ ] Test: `name` finalization (growth, shrink, clear, multibyte) trims NUL padding to the final name; order independence is covered by `steps_test.odin`.
- [ ] Test: comment patches at distinct anchors commute and reduce to the final text.
- [ ] Test: overwrite applies in log order across shards; the last assignment per LWW field wins.
- [ ] Test: `slop_pijul` round trip for empty comments, repeated lines, whitespace, line endings, multibyte UTF-8.
- [ ] Benchmark comment patches against direct XOR (high-water memory, shifted-suffix cost).
- [ ] Define behavior when a mixed patch+overwrite batch fails partway through `ev_append` (`src/server/handlers.odin`).

- [ ] Test: `handle_update_metadata` rejects a present-but-empty `oid` or `path` with 400 and appends nothing; JSON `null` on any field is a `BadEvent`.

- [ ] Test: `mtime` and `added_at` never decrease: a lower or zero value in a `patch` is ignored, `overwrite` carrying either is rejected, and the writer omits them when not greater than current.
- [ ] Test: patches clearing `name`, `comment` and tags replay to empty values, in both full and incremental replay.

# Store Write Path TODO

Writes are log-first: handlers and Eagle import append events, then run incremental replay (`replay.initiate_replay(s, full_replay = false)`), which is the only caller of the store write procs and saves shard cursors in the same tx. No `store.apply` wrapper is planned.

- [ ] Serialize appends, replay and `add` id allocation if handlers ever run concurrently; today `Serve` is synchronous.
// Rebuild path defers indexes and runs with foreign_keys = OFF because we trust event log writes.
// Consider running `PRAGMA foreign_key_check` after bulk insert if we ever stop trusting the event log.
- [ ] Optional: CI/pre-commit check that nothing outside `replay` calls the store write procs or writes to the DB directly.
- [ ] Normalize tags in the web handlers. Eagle import now lowercases tags, turns whitespace into `-`, canonicalizes anything else outside `is_allowed_tag_char` and records the original in a per-import remediation queue (`src/library/tags.odin`, `src/importers/eagle_import.odin`). `handle_ingest` and tag edits still store tags verbatim, and existing rows stay unvalidated. Tags flow into chip URLs, so a stray `&`, `=`, `#`, `%`, or `+` breaks the URL; once every write path is normalized, `filter_urls` needs no `net.percent_encode`.
- [ ] Add tests for `handle_delete` (store row removed, 404/500 paths).
- [x] Remove `core:log`; use `fmt.eprint*` instead.



# Lua Hook TODO

- [ ] Load every `lua/*.lua` in sorted order instead of the single `handlers.lua` (`src/server/lua_handle.odin`); later files win on conflicts.
- [ ] Send a reload event (e.g. over SSE) when a Lua file changes, so open pages refresh on save.

# Tag Remediation TODO

- [ ] Test the remediation path: import a temporary library with tags like `Black Cat`, `cat2` and `fav🐕`; assert the item's tags are canonical, the `<uuid>-remediation.ndjson` queue holds flat records with the original tags, and replay still matches the import.
- [ ] Decide how the remediation queue is consumed (UI listing, resolve/dismiss); nothing reads it yet.
- [ ] Linux: replace the per-original fsync loop after the Eagle import loop with one `syncfs` on the images directory (1k-item import: ~107 ms vs ~950 ms). Trade-offs: flushes the whole filesystem, and only reports writeback errors on Linux >= 5.8. Windows keeps per-file `FlushFileBuffers`.
- [ ] `os.open` on Linux resolves the path with a `readlink` of `/proc/self/fd/N` on every open (3 extra syscalls per imported item). Low priority next to the fsyncs; would need `linux.open` for the metadata and image files.

## RESEARCH
sccache - Mozilla's compiler cache - compiler artifacts can live in different remote storage backends

# Performance Audit TODO

- [ ] Verify `search_images` query plans use index order for all four sorts (unfiltered and tag-filtered) and benchmark them.

- [ ] Compare item and tag snapshots across the pre- and post-prepared-insert replay revisions using the same 100,000-event fixture; the benchmark currently checks repeatability within each run, not equality between revisions.
- [ ] Avoid redundant serialization: `SQLite (row → JSON) → Odin (JSON → Odin → JSON) → client`. Keep data typed until final serialization, or pass SQLite-produced JSON through without decoding and re-encoding when no transformation is needed.
- oha + valgrind/callgrind/memcheck

- Build a Lighthouse-like resource audit for representative Odin workloads:
  - Use AST search to identify semantic operations (allocation, buffer touch, cleanup, image decode, indexing, request handling) and generate debugger breakpoints with meaningful labels.
  - Capture timestamped events, call stacks, relevant variables, and resource samples at operation boundaries; distinguish before/after execution rather than treating a breakpoint on a call as its completion.
  - Sample cgroup memory and CPU externally, keeping the debugger and sampler outside the measured cgroup. Track `memory.current`, `memory.peak`, `memory.stat` components, and `cpu.stat`.
  - Combine samples and semantic events into annotated timelines and per-operation reports: elapsed/CPU time, memory growth, peak footprint, and memory retained after cleanup, for identical work across runs.
  - Use two passes: a debugger-assisted diagnostic pass for attribution, and an unpaused performance pass for realistic timing and peaks. Record debugger pause durations and avoid presenting instrumented timing as normal execution time.

# Media Decode TODO

- [ ] Check dimensions before decoding and skip oversized thumbnail inputs with a documented pixel-count limit and clear log.


# Thumbnail Preview TODO

- [ ] Explore server-driven adaptive thumbnail streaming: continuously sample TCP RTT and ACK-derived delivery rate to choose AV1/WebP and resolution for images not yet queued, without pausing transmission. Account for roughly one RTT of feedback lag and bound queued data so adaptation can take effect; use a framing format that supports independently encoded images instead of the precomputed WebP container.

- [ ] Add explicit preview memory budgeting for canvas backing storage and mipmap textures, accounting for viewport size and batch image count.

- If visible-grid redraws become a bottleneck, render changed slots into a persistent texture-backed framebuffer and blit it to the canvas on rAF. Compare blit bandwidth and framebuffer memory against drawing the cached textures; invalidate affected slots on sorting, scrolling, and resize.

# LOD 0 Micro-Atlas TODO

   - [ ] Reuse the writer, picture, and settings for bulk thumbnails (see `rescale_half` TODO in `src/thumbnail/create_thumbnail.odin`).
2. Port the Go atlas builder: decode every thumbnail → 48px micro thumb → pack 2048² sheets → PNG-encode to a content-keyed disk cache, and add `micro_page/x/y/w/h` fields to `library.Image` plus an immutable-cached `/api/atlas/:key/page_N.png` handler.
3. Swap the card renderer to a CSS-sprite div using the atlas as LOD 0 with the existing webp thumbs lazy-loaded as LOD 1, then update the render fixture tests.
4. Harden the mipmap handler: replace sequential sends with writev, right-size the arena, and assert response correctness in tests.

# Gallery Pagination TODO

- Infinite scroll: the load-more button fires on `intersect once root:.main-content` (click remains as fallback), with `hx-sync="#photo-grid:drop"`; default page size is 100.
- [ ] Verify infinite scroll in a browser: sentinel position after masonry packing, no duplicate pages on fast scroll, and a short first page that doesn't fill the viewport still chains loads.

- Open question: choose a reasonable default for fresh loads after loading more. Load-more URLs currently omit offset; should refresh start with one page, restore the displayed count, or restore a position? Decide the URL semantics and default before implementing accumulated-offset restoration.

# Gallery Masonry TODO

- Current layout is stateless JS by design: `data-render-order-id` (stamped by `photo_grid.odin` as `offset - len(images) + i`) is the only order source; `gallery.js` holds just a sync key string and an rAF flag, with no per-card listeners.
- If the id-free variant is ever wanted: bind the canonical card sequence to the grid node's lifetime with `WeakMap<#photo-grid, sequence>` and purge entries via `isConnected` on each sync, so a wholesale swap (filter/tag clicks replace `.gallery-content`) garbage-collects the state with the old node automatically. What it buys: O(k) appends instead of O(n) repacks — n is a few hundred re-parented nodes, sub-millisecond, no image refetch. What it costs: the invariant burden, plus arrival-order-instead-of-listing-order under concurrent requests. Not a trade worth making at gallery scale.
- Long-term exit: if `grid-template-rows: masonry` ever lands cross-browser, the JS masonry and the render-order ids can be deleted outright; card markup needs no changes.

# Frontend / Native Browser TODO

- [ ] Replace JS default theme detection (`static/gallery.js`, `window.matchMedia("(prefers-color-scheme: dark)")`) and the `html:not([data-theme]) { visibility: hidden; }` render-blocking hack (`static/gallery.css`) with CSS `color-scheme: light dark` and `light-dark()` (or `@media (prefers-color-scheme: dark)`), keeping JS only for explicit `localStorage` user overrides.
- [ ] Replace the Inspector tag-edit input toggle (`src/template/inspector.odin`, `data-hx-on-click` toggling `.hidden` and calling `.focus()`) with a native `popover` and `autofocus` on the `<input>`.
- [x] Replace the custom drag-and-drop upload handlers (`src/template/gallery_page.odin`, `data-hx-on-dragover`/`dragleave`/`drop` on `#upload-form`) by letting `<input type="file">` act as the native drop target.
- [x] Replace JS Inspector open/close class toggling (`src/template/gallery_page.odin`, `data-hx-on::after-swap` / `booruToggleInspector`) with CSS `:has()` + `:empty` (e.g. `#gallery-main:has(#inspector-content:not(:empty))`) or `popover` (keeping JS only if `localStorage` persistence across reloads is still desired).
- [ ] Consider retaining inspector in DOM.
- [x] Remove dead `body.light-mode` and `body.dark-mode` CSS rules and duplicate variable blocks in `static/gallery.css` (lines 48, 67, 86–120, 336–341, 364–418); theming uses `html[data-theme='light'|'dark']`.
- [x] Consolidate the three separate `DOMContentLoaded` listeners in `static/gallery.js`.

# Web Lint TODO

Templates are Odin strings, so lint the rendered fixtures (`test/html-fixture-tdd/fixture/*.expected.html`) and `static/` instead. Findings below are from a trial run of each tool.

- [ ] Add `html-validate` (devDependency, `.htmlvalidate.json` extending `html-validate:recommended` with `void-style`, `no-inline-style`, `attribute-boolean-style` off) and a `task lint:html` over the fixtures. Keep it out of the pre-commit hook. Current findings: 11× `<img>` missing `alt` (`wcag/h37`; decorative images may just need `alt=""`), 2× `aria-label-misuse` (`gallery_content`, `gallery_page`), 1× `<button>` without accessible text (`gallery_page`).
- [ ] Run `npx modern-web-guidance@latest legacy-scan static --json` occasionally (not in CI; findings need review against each rule's `keepWhen`/`dropWhen`). Current findings: `gallery.js:939` theme override doesn't update `<meta name="color-scheme">` (see the theme item above), `gallery.css:1146` recolors an icon with an `invert()`/`sepia()`/`saturate()`/`hue-rotate()` chain instead of `mask` + `currentColor`, `benchmark.html:225` Enter-to-submit isn't IME-safe (`event.isComposing`). Fixtures and `src/template` are clean. Optionally install its agent skill (`npx modern-web-guidance install`).
- [ ] Optional: `stylelint` + `stylelint-plugin-use-baseline` on `static/gallery.css` as a warning, with the deliberately used newer features ignored (anchor positioning, `:popover-open`, `::details-content`, `content-visibility`, `scrollbar-gutter`) so new non-Baseline features stand out. Use this or `@eslint/css` `use-baseline`, not both.
- [ ] Optional: `eslint` + `eslint-plugin-baseline-js` on `static/gallery.js`. No Baseline findings today; `recommended` reports 6× `no-redeclare` (repeated `var i`/`col`) and an unused `i` at line 826.
- Skipped: webhint (retired), Lighthouse/axe/pa11y (need a running server and headless browser), `vnu` (needs Java, overlaps html-validate), `doiuse` (superseded by `use-baseline`).

# Importer TODO

- [ ] Add `import_begin` and `import_end` events around each full-library import, where `import_begin` records the run ID, source path, and expected item count and `import_end` records the added, skipped, and failed counts, and tag every `add` from that run with the run ID. At load time, treat an `import_begin` with no matching `import_end` as an interrupted import, log how many of its `add` events exist against the expected count, and let the user resume by re-running the import. Take an exclusive non-blocking `flock` on `<library>/.import.lock` for the whole import so two runs can't append to the log at once, and keep the file handle open until the import finishes so the OS releases the lock on exit or crash.

# JXL Support

Estimates, using about 85 KB in thumbnails per image:
~ 80 KB for LOD 0.
~ 4 KB for LOD 1.
~ 1 KB for LOD 2.

1,000 images
- LOD 0: ~80 MB
- LOD 1: ~4 MB
- LOD 2: ~1 MB
- Total: ~85 MB (range 43–158 MB)

10,000 images
- LOD 0: ~800 MB
- LOD 1: ~40 MB
- LOD 2: ~10 MB
- Total: ~850 MB (range 0.4–1.6 GB)

100,000 images
- LOD 0: ~8 GB
- LOD 1: ~400 MB
- LOD 2: ~100 MB
- Total: ~8.5 GB (range 4.3–16 GB)

1,000,000 images
- LOD 0: ~80 GB
- LOD 1: ~4 GB
- LOD 2: ~1 GB
- Total: ~85 GB (range 43–160 GB)

I hadn't considered this, but storing a bunch of small files is bad.
most file systems have smallest block size of 4kb, meaning
LOD 1 + 2 take up 8 kb instead of 5.

an idea was to store thumbnails in a DB, which makes even more sense with
that in mind. The file layout to the user still stays stupid simple,
with LOD 0 stored in the /thumbnails dir, like my original first instinct
was while making the project

we can add JXL support in-place.
if user sends Accept: image/jxl
we can skip the mipmap stuff and just send the user the JXL
and let progressive decode handle everything

6kb/item is negligible, especially as a sane default.
we can raise alerts to users with less reasonable library sizes

===
JXL//
toast:
> slow network connection ; not loading high res images
|open settings| |dismiss|


# Template TODO

- [ ] Evaluate `core:fmt` for templates: Python-style `{n:v}` argument indices, plus user formatters (`fmt.register_user_formatter`) on distinct types such as `Html_Text` and `Html_Attr` that escape automatically. Watch for these:
  - `{` is a directive, so HTML, CSS and JSON braces must be written as `{{`.
  - Format errors render silently into the output as `%!(...)`.
  - The format string is parsed at runtime on every call.
  - User formatters are global (`set_user_formatters` can only be called once).
  - Compare against the current `strings.Builder` and `escape_*` approach in the fixture tests.

atproto integration ? ~/Public/booru-atproto.md

## orphan ids
issue: when original file is deleted or
filebytes change, we leave behind dead thumbnail files.
like /thumbnails/64/<oid>.webp

solution after increment_id if lib.id % 5 -> detect_orphan_oid

INVARIANT:
Rebuild incompatible databases; never migrate them.
The derived-store compatibility check and rebuild lifecycle aren’t implemented.
Roaring bitmap tag indexes are not implemented.

Proxied libraries referencing originals outside the library.
External-original resolution isn’t implemented; current operations assume managed originals.

A human-readable portability warning for proxied libraries.
The root warning file isn’t generated. Its final name remains undecided.

Implicit event version 0, with startup refusal for unsupported versions.
Omitting version already matches your decision. MAX_SUPPORTED_VERSION = 0 and the compatibility gate don’t exist yet.


// TODO: test throughput MB/s for image formats -> webp

filesystem heuristics
FS_Heuristics :: struct {
   write_cache_mode: int, // 1 write back, 0 write through, -1 unknown
   rotational:       int, // 1, 0, -1
   fs_kind:          FS_Kind, // .Block, .Tmpfs, .Network, .Fuse, .Unknown
   mount_sync:       bool,
   mount_nobarrier:  bool,
   syncfs_reports_errors: bool, // kernel >= 5.8
}
