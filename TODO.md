high level tasks

- [ ] Allow user preference for max server memory usage (cap concurrent `Conn_Slot` count / large-body budget in `src/server/server.odin` instead of a fixed 64 slots × 4 MiB + unbounded 16 MiB uploads).
- [ ] Have `render_photo_grid` (`src/template/photo_grid.odin`) write cards into one `strings.Builder` instead of allocating 100 separate `render_item_card` builders.
- [ ] Render/preview `.url` (`application/x-mswinurl`) items in card, inspector, and duplicates templates instead of falling back to the unsupported-filetype placeholder.
- [ ] Support drag-and-drop ingestion of directories and `.zip` archives of `.url` files.

- [ ] Move platform-specific `when ODIN_OS` branches that depend on platform-only imports into suffixed files such as `_windows.odin` and `_linux.odin`. Keep those imports in their platform files so `odin check -vet` does not flag imports needed only by another target. Cover `src/dirlist`, `src/importers/eagle_import.odin`, and `src/thumbnail/generate_missing_thumbnails.odin`, and audit for other occurrences.

Harden flat parser: validation, boundaries, tests/fuzzing.
Harden event semantics: required fields, patch/clear rules, ordering, replay progress, and failure recovery.

- [ ] [deferred] Improved error handling:
  - Replace ad-hoc `bool` / `os.exit` / `panic` error paths with explicit error enums/unions that preserve failure context across package boundaries (`media`, `store`, `replay`, `importers`, `server`).
  - Separate error classes consistently: caller/input validation errors (4xx), transient I/O or resource exhaustion (retryable / 503), corrupt/invariant failures (abort or rebuild), and unsupported formats.
  - Attach actionable context (path, oid, shard/offset, sqlite error code) when logging at boundaries (`src/server/`, `src/main.odin`) without leaking internal details in HTTP responses.

- [ ] [v1] Make events CloudEvent compatible.
- [ ] [deferred] Revisit `oid` in `Event`: originals are `id`-addressed (`images/<id>.<ext>`) and `oid` is non-unique, so storing `oid` in the immutable event log couples domain history to mutable byte encodings and leaks thumbnail/URL cache keys into the log. Either move content/cache hashing to the SQLite projection and key thumbnails and `/image/:id` by `id` (with cache-busting), or adopt true content-addressed storage (`objects/<oid>`). Action on this point is postponed.
- [ ] Review existing replay panic/error states and thoroughly evaluate when a failed incremental replay (`full_replay = false`) can safely fall back to full replay.
- [ ] Classify startup store errors and rebuild only when restartable. Already done: a stale schema (missing columns, detected as `SCHEMA_MISMATCH` from `prepare_item_patch`) discards `store.sqlite` and rebuilds once per startup (`src/main.odin`). Remaining: `PRAGMA user_version` check, `SQLITE_CORRUPT`, and refusing non-restartable errors. Restartable means the derived `store.sqlite` is bad or stale: e.g. a stale schema (`PRAGMA user_version` mismatch, such as a store without the `deleted` column) or `SQLITE_CORRUPT`; discard it and do a full replay, at most once per startup. Not restartable means rebuilding can't help: e.g. `SQLITE_FULL` (disk full), or a replay `.BadEvent`, where the log is the problem. The README's "discards and rebuilds" claim is not implemented yet.
  - Consider: store a 32-bit hash of the `create_tables` + `create_indexes` DDL strings in `PRAGMA user_version` instead of a manually bumped integer, so any table, column, constraint, or index change triggers an O(1) rebuild without forgetting to bump a version.

- [ ] Test: `name` finalization (growth, shrink, clear, multibyte) trims NUL padding to the final name; order independence is covered by `steps_test.odin`.
- [ ] Test: comment patches at distinct anchors commute and reduce to the final text.
- [ ] Test: overwrite applies in log order across shards; the last assignment per LWW field wins.
- [ ] Test: `slop_pijul` round trip for empty comments, repeated lines, whitespace, line endings, multibyte UTF-8.
- [ ] Benchmark comment patches against direct XOR (high-water memory, shifted-suffix cost).
- [ ] Define behavior when a mixed patch+overwrite batch fails partway through `ev_append` (`src/server/handlers.odin`).

- [ ] Test: `handle_update_metadata` rejects a present-but-empty `path` with 400 and appends nothing; JSON `null` on any field is a `BadEvent`.

- [ ] Test: `mtime` and `added_at` never decrease: a lower or zero value in a `patch` is ignored, `overwrite` carrying either is rejected, and the writer omits them when not greater than current.
- [ ] Test: patches clearing `name`, `comment` and tags replay to empty values, in both full and incremental replay.

# Store Write Path TODO

Writes are log-first: handlers and Eagle import append events, then run incremental replay (`replay.initiate_replay(s, full_replay = false)`), which is the only caller of the store write procs and saves shard cursors in the same tx. No `store.apply` wrapper is planned.

- [ ] Serialize appends, replay and `add` id allocation if handlers ever run concurrently; today `Serve` is synchronous.
// Rebuild path defers indexes and runs with foreign_keys = OFF because we trust event log writes.
// Consider running `PRAGMA foreign_key_check` after bulk insert if we ever stop trusting the event log.
- [ ] Optional: CI/pre-commit check that nothing outside `replay` calls the store write procs or writes to the DB directly.
- [ ] Add tests for `handle_delete` (store row removed, 404/500 paths).

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

- [ ] Speed up `replay.replay` / `server.metadata_edits_write_membership_deltas` (~149ms, 1.35B Ir under callgrind because every `replay` scans all `swap.max_id` = 1,000,000 slots in `vtab_insert_items.advance`, `vtab_insert_item_tags.advance`, and `replay.odin:286` even for 1 item):
  - Track `high_id = max(high_id, item.id)` in `replay` / `Swap_Store` and bound those three loops to `high_id` instead of `swap.max_id`.
  - For sparse or small `!full_replay` runs, iterate `seen_ids` / dirty IDs (or `patch_states.entries` directly when nothing evicted to swap) instead of scanning `1..=high_id`.
  - Defer `init_swap` (swap tmpfile create / 64 MiB `truncate` / `mmap`) until the first LRU eviction so small replays don't allocate/unlink a swap file at all.
- [ ] `library.Image.tags`: `[]string` -> `[]u32` (tag IDs) once roaring bitmap tag index lands.
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

- [ ] Open question: should the UI trigger `refresh thumbnail` also re-probe metadata?
- [ ] Cache derived card media renderer state on disk under `thumbnails/max/{oid}.webp` (full-resolution resting still cover) and `thumbnails/interactive/{oid}/...` (multi-asset/interactive renderer outputs like 3D carousels).
- [ ] Make startup artifact scan (`max/`, `interactive/`) async as a background job (`generate_missing_thumbnails` already runs async on `startup_thread` surfaced in `#jobs-panel`; no general job queue yet).
- [ ] Add a post-ingest job hook in `handle_upload` (`src/server/handlers.odin`) to enqueue artifact generation for newly uploaded items.
- [ ] Unify missing-artifact registration per media handler (`matches`, `expected_paths`/`missing`, `generate`) across `64/`, `128/`, `max/`, and `interactive/` in one pass so a single source decode is shared.
- [ ] Enforce `max_pixels` before decoding pixels for video and JXL (`ffmpeg.first_frame` in `src/media/media.odin`).
- [ ] Non-bounded thumbnail generation unimplemented (images over `8192 * 8192` pixels are skipped).
- [ ] Fast path for AVIF dimension probing: `media.probe_dimensions` (`src/media/media.odin`) currently calls `decode_yuv_dav1d` (~569 us/op in `bench/probe/probe_test.odin` vs 0.2–3.7 us/op for header-only image probes). Parse the `ispe` box (`u32be` width/height) via `ipco`/`ipma` in `src/media/avif.odin` (accounting for `irot`/`imir` transforms if present, or fall back to the AV1 sequence header OBU) without decoding pixels.
- [ ] 1-byte thumbnail failure sentinel: when `media.decode_frame` in `src/thumbnail/generate.odin` fails deterministically (`.Unsupported`, `.Too_Large`, or corrupt `.Failed` data), write a 1-byte failure-reason enum to `thumbnails/{64,128}/{oid}.webp` instead of leaving the file missing. This lets `exclude_existing_thumbnails` skip permanently failed items via its `getdents` scan and `/mipmap` pick the embedded fallback (`NOT_FOUND_*` vs `UNSUPPORTED_FILETYPE_*`) by checking `len(bytes) == 1` on its existing file read, with no extra syscalls or DB columns. However, because `getdents` only sees filenames and not sizes, startup cannot distinguish 1-byte sentinels from real WebPs without `stat`, so `.Too_Large`/`.Unsupported` items won't auto-regenerate when support is later added unless sentinels are purged. Writing sentinels on transient I/O or missing-source `.Failed` errors would also suppress retries (breaking `generate_missing_fixture_thumbnails`), and direct readers of `thumbnails/{64,128}/*.webp` will see non-WebP 1-byte files.


# Thumbnail Preview TODO

- [ ] Defer loading originals in gallery cards: loading originals is by design, but set the card `src` (`/image/<oid>`) only after the card has stayed in the viewport for a while (or after a longer settle delay), and show the `/mipmap/64` preview until then. Only touches `static/gallery.js` and the card template (`src/template/card_media_render.odin`, with fixture-first updates); no server change.
- [ ] Explore server-driven adaptive thumbnail streaming: continuously sample TCP RTT and ACK-derived delivery rate to choose AV1/WebP and resolution for images not yet queued, without pausing transmission. Account for roughly one RTT of feedback lag and bound queued data so adaptation can take effect; use a framing format that supports independently encoded images instead of the precomputed WebP container.

- [ ] Add explicit preview memory budgeting for canvas backing storage and mipmap textures, accounting for viewport size and batch image count.

- If visible-grid redraws become a bottleneck, render changed slots into a persistent texture-backed framebuffer and blit it to the canvas on rAF. Compare blit bandwidth and framebuffer memory against drawing the cached textures; invalidate affected slots on sorting, scrolling, and resize.

# Gallery Pagination TODO

- Infinite scroll: the load-more button fires on `intersect once root:.main-content` (click remains as fallback), with `hx-sync="#photo-grid:drop"`; default page size is 100.

- Open question: choose a reasonable default for fresh loads after loading more. Load-more URLs currently omit offset; should refresh start with one page, restore the displayed count, or restore a position? Decide the URL semantics and default before implementing accumulated-offset restoration.

# Gallery Masonry TODO

- Current layout is stateless JS by design: `data-render-order-id` (stamped by `photo_grid.odin` as `offset - len(images) + i`) is the only order source; `gallery.js` holds just a sync key string and an rAF flag, with no per-card listeners.
- If the id-free variant is ever wanted: bind the canonical card sequence to the grid node's lifetime with `WeakMap<#photo-grid, sequence>` and purge entries via `isConnected` on each sync, so a wholesale swap (filter/tag clicks replace `.gallery-content`) garbage-collects the state with the old node automatically. What it buys: O(k) appends instead of O(n) repacks — n is a few hundred re-parented nodes, sub-millisecond, no image refetch. What it costs: the invariant burden, plus arrival-order-instead-of-listing-order under concurrent requests. Not a trade worth making at gallery scale.
- Long-term exit: if `grid-template-rows: masonry` ever lands cross-browser, the JS masonry and the render-order ids can be deleted outright; card markup needs no changes.

# Frontend / Native Browser TODO

- [-] Replace JS default theme detection (`static/gallery.js`, `window.matchMedia("(prefers-color-scheme: dark)")`) and the `html:not([data-theme]) { visibility: hidden; }` render-blocking hack (`static/gallery.css`) with CSS `color-scheme: light dark` and `light-dark()` (or `@media (prefers-color-scheme: dark)`), keeping JS only for explicit `localStorage` user overrides. (Current impl has better browser support.)
- [ ] Replace the custom drag-and-drop upload handlers (`src/template/gallery_page.odin`, `data-hx-on-dragover`/`dragleave`/`drop` on `#upload-form`, plus `window` `dragover`/`drop` in `static/gallery.js`) by letting `<input type="file">` act as the native drop target (if URL/HTML image drops are no longer needed).
- [ ] Consider retaining inspector in DOM.

# Web Lint TODO

Templates are Odin strings, so lint the rendered fixtures (`test/html-fixture-tdd/fixture/*.expected.html`) and `static/` instead. Findings below are from a trial run of each tool.

- [ ] Add `html-validate` (devDependency, `.htmlvalidate.json` extending `html-validate:recommended` with `void-style`, `no-inline-style`, `attribute-boolean-style` off) and a `task lint:html` over the fixtures. Keep it out of the pre-commit hook. Current findings: 11× `<img>` missing `alt` (`wcag/h37`; decorative images may just need `alt=""`), 2× `aria-label-misuse` (`gallery_content`, `gallery_page`), 1× `<button>` without accessible text (`gallery_page`).
- [ ] Run `pnpm dlx modern-web-guidance@latest legacy-scan static --json` occasionally (not in CI; findings need review against each rule's `keepWhen`/`dropWhen`). Current findings: `gallery.js:939` theme override doesn't update `<meta name="color-scheme">` (see the theme item above), `gallery.css:1146` recolors an icon with an `invert()`/`sepia()`/`saturate()`/`hue-rotate()` chain instead of `mask` + `currentColor`, `benchmark.html:225` Enter-to-submit isn't IME-safe (`event.isComposing`). Fixtures and `src/template` are clean. Optionally install its agent skill (`pnpm dlx modern-web-guidance install`).
- [ ] Optional: `stylelint` + `stylelint-plugin-use-baseline` on `static/gallery.css` as a warning, with the deliberately used newer features ignored (anchor positioning, `:popover-open`, `::details-content`, `content-visibility`, `scrollbar-gutter`) so new non-Baseline features stand out. Use this or `@eslint/css` `use-baseline`, not both.
- [ ] Optional: `eslint` + `eslint-plugin-baseline-js` on `static/gallery.js`. No Baseline findings today; `recommended` is clean (the `no-redeclare` and unused `i` findings are fixed).
- Skipped: webhint (retired), Lighthouse/axe/pa11y (need a running server and headless browser), `vnu` (needs Java, overlaps html-validate), `doiuse` (superseded by `use-baseline`).

# Importer TODO

- [ ] Add `import_begin` and `import_end` events around each full-library import, where `import_begin` records the run ID, source path, and expected item count and `import_end` records the added, skipped, and failed counts, and tag every `add` from that run with the run ID. At load time, treat an `import_begin` with no matching `import_end` as an interrupted import, log how many of its `add` events exist against the expected count, and let the user resume by re-running the import. Take an exclusive non-blocking `flock` on `<library>/.import.lock` for the whole import so two runs can't append to the log at once, and keep the file handle open until the import finishes so the OS releases the lock on exit or crash.

# Duplicate Detection TODO

- [ ] Fix `/duplicates` Apply all (`src/template/duplicates_page.odin`, `POST /merge`): commit ready groups in one request/replay instead of sequential `/merge` requests, remove committed groups from the page, and stop at the first failure.
- [ ] Restructure `/duplicates` to swap inside the persistent app shell (`.main-content` / `#gallery-main` via `hx-get="/duplicates"` + `hx-push-url="true"`, keeping `#toasts-log` and `#jobs-panel` SSE alive across navigation, and serving either the fragment on `HX-Request` or the full shell on direct load/refresh).

# JXL Support

- [ ] Non-RGB24 JXL decode (alpha/RGBA, grayscale, >8-bit)
- [ ] `Accept: image/jxl` passthrough to skip WebP mipmaps


# Template TODO

- [ ] Evaluate `core:fmt` for templates: Python-style `{n:v}` argument indices, plus user formatters (`fmt.register_user_formatter`) on distinct types such as `Html_Text` and `Html_Attr` that escape automatically. Watch for these:
  - `{` is a directive, so HTML, CSS and JSON braces must be written as `{{`.
  - Format errors render silently into the output as `%!(...)`.
  - The format string is parsed at runtime on every call.
  - User formatters are global (`set_user_formatters` can only be called once).
  - Compare against the current `strings.Builder` and `escape_*` approach in the fixture tests.
- [ ] Consider deduplicating the `<img>` branches in `write_card_media` (`src/template/card_media_render.odin`), `render_inspector` and `write_duplicate_group`: the image, `.max` and unsupported cases differ only in `src`, so pick `src` in the content-type switch and emit the tag once (fixtures should not change).

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
Implemented: `elog.MAX_SUPPORTED_EVENT_VERSION` (`0`) and `.UnsupportedVersion` in `src/replay/replay.odin` (tested in `src/replay/replay_test.odin`).


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
-> is rotational/slow & has lots of memory - mmap actual memory during replay?

gallery views are persistent - not disposable !
certain views are dynamic e.g., unsorted
other, static views - can retain scroll position.
navigation is an easy win as far as utility and
convenience : BUT - retaining layout and filters
should be done very carefully. should be opt in?

--
viewer - masonry with no gap or metadata, w/ snapping - scroll snaps to image boundaries instead of smooth scroll.

## search
is bm25 w/ fts ever worse than exact fts with skilled users who know exact keywords?

shebang !semantic ?
opt in for fuzzy seems bad.

queries with quotes for exact phrases should be sorted by date by default "to be"

- search ergonomics
currently bad ergonomics - no chip grouping .
every chip removal automatically initiates a new search.
keywords can't be modified individually.
no sort predicate ?

should sort even be a chip?
if sort is a chip, why shouldn't view be one? view:grid

Amdahl's Law (the serial fraction dominates): If even 15% of total time is serialized (SQLite writer lock, transaction commits, queue mutex), infinite cores cap speedup at 1 / 0.15 ≈ 6.7×

- [ ] Jobs/progress UI: make groups dismissable, improve rendering of hierarchical phases (e.g. `total == nil` sub-phases / `0` noise), or render as a tree/DAG.
- [ ] Consider Multi-Index Hashing (MIH) for O(N) all-pairs PDQ duplicate detection at 100k+ items.

# Test & Replay Issues

- [ ] **Multi-source `/merge` untested.** The lifecycle e2e test merges a single source, because only 2 items remain after its delete. Nothing covers `from=a,b` folding in order, skipping a source comment the target already contains, or the `DEV_ROUTES` `sample=1` shortcut (the unit test that covered these was removed when the test moved to e2e).
- [ ] **`/duplicates` untested.** It has no handler test and no HTML fixture, so the page's switch to `POST /merge` is not covered.

local behavioral telemetry -> ranking heuristic e.g lru/frecency
