high level tasks

- [ ] Move platform-specific `when ODIN_OS` branches that depend on platform-only imports into suffixed files such as `_windows.odin` and `_linux.odin`. Keep those imports in their platform files so `odin check -vet` does not flag imports needed only by another target. Cover `src/dirlist`, `src/importers/eagle_import.odin`, and `src/thumbnail/generate_missing_thumbnails.odin`, and audit for other occurrences.

Harden flat parser: validation, boundaries, tests/fuzzing.
Add event types: implement remaining operations.
Harden event semantics: required fields, patch/clear rules, ordering, replay progress, and failure recovery.
lfs-booru parity achieved

 Not quite: `library_images` is gone and handlers read from the SQLite store, but `handle_ingest` and the Eagle importer don't apply their events to the store, so new items only appear after a restart.

# Store Write Path TODO

- [ ] Add `store.apply(tx, event)` as the only public store write proc; make `insert_*`, `patch_item`, `delete_item` in `src/store/store.odin` `@(private = "package")`. Move the op `switch` out of `replay.replay` (`src/replay/replay.odin`) so replay just loops `apply`. Unknown ops should error, not `continue`.
- [ ] Runtime handlers apply events to SQLite: after `elog.event_append` succeeds in upload/delete (`src/server/handlers.odin`), open a tx and call `store.apply`. Order: log first, then apply (a failed apply is recovered by replay). `handle_delete` already does this (log, then `sqlite.with_transaction(db, id, store.delete_item)`); `handle_ingest` and Eagle import don't, so uploads/imports don't show until restart. Route delete through `apply` too.
- [ ] `apply` advances the per-shard replay cursor in the same SQLite tx as the state change, so store and cursor can't drift (lfs-booru: `applyEvent(event, nextCursor)` in `src/index_store.ts`).
- [ ] Serialize runtime applies (and `add` id allocation) if handlers run concurrently (lfs-booru: `this.mu` + `nextIdMutex`).
- [ ] Keep a batch path: replay/import open one tx and `apply` every line (lfs-booru: `applyEventsFromFile`).
- [ ] Rebuild path: defer secondary indexes (`items_added_at`, `item_tags_by_tag`) and the FK check during full replay. Create the indexes after the bulk insert, then run `PRAGMA foreign_key_check`. In a 1.2M-event probe this took ~2.4 s vs ~10.9 s with indexes maintained per insert. Use WAL + `synchronous=OFF` only on a disposable temp DB that is verified and published afterward; keep indexes and FKs in place for live handlers. Notes are in the pi sessions under `--srv-code-lfs-booru--` (2026-10-18), probe at `/var/tmp/lfs-booru-odin-probe/`.
- [ ] Optional: CI/pre-commit check that nothing outside `store` writes to the DB directly.
- [ ] Add `hx-get` to `#search-form` (`src/template/gallery_page.odin`), whose native submit sends `q=a+b` and is now rejected with `ENCODING_ERR_MSG`. Its input is also named `q`, which `parse_gallery_query` never reads (it only parses `limit`, `offset`, `sort`, `tags`), so search does nothing today.
- [ ] Validate tags as kebab-case where they are produced: `eagle_import` unmarshals Eagle JSON into `EagleItem_Event` and casts it straight to `elog.Event` (`src/importers/eagle_import.odin:172`), with no tag processing, and `library.new_add_event` only sets `op`/`id` despite its comment. Tags flow verbatim into chip URLs, so a stray `&`, `=`, `#`, `%`, or `+` breaks the URL structurally (the browser normalizes spaces only). Decide reject vs normalize (lowercase, spaces to `-`); a rejection will skip items whose Eagle libraries use tags like `Big Cat`, and existing rows stay unvalidated. Then `filter_urls` needs no `net.percent_encode`.
- [ ] Add tests for `handle_delete` (store row removed, 404/500 paths) and `handle_ingest`.
- [ ] `handle_delete`: a failed `os.remove` is now logged to stderr and still returns 200 (see the TODO in the handler); decide how failed removals of remote/proxied originals get retried or reconciled.
- [ ] Remove `core:log` (still used in `src/main.odin` and `src/server/server.odin`); use `fmt.eprint*` instead.
- [ ] `main.odin` seeds the id counter from `store.read_images` after replay; replace with a `SELECT MAX(id)` query.
- [ ] `generate_missing_thumbnails` and `find_missing_thumbnails` each run `store.read_images` (naive double read); `lookup_thumbnail_oid_by_id` runs two queries per id in `handle_mipmap`. Revisit if startup or mipmap throughput regresses; add a `handle_mipmap` case to `bench/handlers`.

- [ ] In `gen_item_thumbnail_versions`, try `images/<id>.<ext>` directly using `img.ext`.
  Fall back to scanning for the `<id>.` prefix only when the extension is missing or the direct read fails.


## RESEARCH
sccache - Mozilla's compiler cache - compiler artifacts can live in different remote storage backends

# Performance Audit TODO
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

- [ ] Add a canvas pixel budget and a bounded texture cache so preview memory stays bounded as viewport size and loaded-card count grow.

- [ ] Validate VP8 thumbnail headers and dimensions before assembling mipmaps; the writer currently assumes valid VP8 input and a uniform longest edge.

- If visible-grid redraws become a bottleneck, render changed slots into a persistent texture-backed framebuffer and blit it to the canvas on rAF. Compare blit bandwidth and framebuffer memory against drawing the cached textures; invalidate affected slots on sorting, scrolling, and resize.
- Expose the RIFF frame-to-image-ID mapping so the GPU cache can follow images across reordered or filtered streams instead of using endpoint/frame-index keys.

# LOD 0 Micro-Atlas TODO

   - [ ] Reuse the writer, picture, and settings for bulk thumbnails (see `rescale_half` TODO in `src/thumbnail/create_thumbnail.odin`).
2. Port the Go atlas builder: decode every thumbnail → 48px micro thumb → pack 2048² sheets → PNG-encode to a content-keyed disk cache, and add `micro_page/x/y/w/h` fields to `library.Image` plus an immutable-cached `/api/atlas/:key/page_N.png` handler.
3. Swap the card renderer to a CSS-sprite div using the atlas as LOD 0 with the existing webp thumbs lazy-loaded as LOD 1, then update the render fixture tests.
4. Harden the mipmap handler: replace sequential sends with writev, right-size the arena, and assert response correctness in tests.

# Gallery Pagination TODO

- Open question: choose a reasonable default for fresh loads after loading more. Load-more URLs currently omit offset; should refresh start with one page, restore the displayed count, or restore a position? Decide the URL semantics and default before implementing accumulated-offset restoration.

# Gallery Masonry TODO

- Current layout is stateless JS by design: `data-render-order-id` (stamped by `photo_grid.odin` as `offset - len(images) + i`) is the only order source; `gallery.js` holds just a sync key string and an rAF flag, with no per-card listeners.
- If the id-free variant is ever wanted: bind the canonical card sequence to the grid node's lifetime with `WeakMap<#photo-grid, sequence>` and purge entries via `isConnected` on each sync, so a wholesale swap (filter/tag clicks replace `.gallery-content`) garbage-collects the state with the old node automatically. What it buys: O(k) appends instead of O(n) repacks — n is a few hundred re-parented nodes, sub-millisecond, no image refetch. What it costs: the invariant burden, plus arrival-order-instead-of-listing-order under concurrent requests. Not a trade worth making at gallery scale.
- Long-term exit: if `grid-template-rows: masonry` ever lands cross-browser, the JS masonry and the render-order ids can be deleted outright; card markup needs no changes.

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
Incremental indexing, including Roaring bitmap tag indexes.
Neither the bitmap index nor incremental projection updates are implemented.

Proxied libraries referencing originals outside the library.
External-original resolution isn’t implemented; current operations assume managed originals.

A human-readable portability warning for proxied libraries.
The root warning file isn’t generated. Its final name remains undecided.

Implicit event version 0, with startup refusal for unsupported versions.
Omitting version already matches your decision. MAX_SUPPORTED_VERSION = 0 and the compatibility gate don’t exist yet.


// TODO: test throughput MB/s for image formats -> webp
