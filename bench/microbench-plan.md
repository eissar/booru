# Microbenchmark Split Plan for `bench/scroll_stutter_bench.lua`

## Why `scroll_stutter_bench.lua` Takes 30s and Conflates Bottlenecks

`bench/scroll_stutter_bench.lua` scrolls the full `283,109px` height down and back up at `20,000 px/s` (`~28.3s` for Pass 1 alone), while mixing five distinct sources of >20ms tasks:

1. **Startup (`DOMContentLoaded` + initial layout + `syncMasonry`)**:
   - Initial layout & forced layout (`measureMasonry` / `ResizeObserver`): `95.6ms` + `97.7ms` + `61.8ms`
   - `DOMContentLoaded` (`static/gallery.js` WebGL2 init + `requestBatch`): `198–241ms` (`270–317ms` parser finish task)
   - First `scheduleMasonrySync()` rAF (`syncMasonry`, `collectCards`, `showNearbyCards`, `recordMasonryLayouts`): `60.5–121.5ms`
2. **Background `loadBatch()` + `gl.getError()` sync flushes**:
   - `wait_for` returns once `512` of `1000` mipmaps are ready (`MAX_PAGES * PAGE_LAYERS = 512`), leaving frames `513..1000` decoding/uploading during Pass 1.
   - `booruPreviewSnapshot()` sets `diagnosticsEnabled = true`, which triggers `gl.getError()` after every `gl.texSubImage3D` (`static/gallery.js:868`), forcing `CommandBufferHelper::Finish` / `WaitForGetOffset` IPC stalls (`20–87ms` per call, `~950ms` over 2.5s).
3. **Per-frame benchmark harness overhead (`5.5–15ms/frame`)**:
   - Calling `window.booruPreviewSnapshot()` (`1000` `image.src` + `Map.get` calls) and `countBlanks()` (`querySelectorAll('.gallery-card-media')` + `getBoundingClientRect()` on visible cards) inside every rAF tick.
4. **Main-thread scroll work (`200k px/s`)**:
   - `0` tasks ≥20ms at `20k px/s` once `loadBatch` settles and `countBlanks` is removed.
   - At `200k px/s`: `LayerTreeHost::WaitForCommitCompletion` (`23.9ms`) and `ProxyMain::BeginMainFrame` (`22.5–31.7ms`, including `UpdateLifecycle` `19.6ms` / `UpdateStyleAndLayout` `11.8ms`).
5. **GPU / SwiftShader rasterization (`CrGpuMain`)**:
   - `77–107` tasks ≥20ms (`20–69.5ms` each, e.g. `GpuChannel::ExecuteDeferredRequest` / `RendererRasterWorker` / `RasterDecoderImpl::DoEndRasterCHROMIUM`) rasterizing the `960x3780` WebGL2 strip and `600x800` JPEGs, throttling rAF to ~33–38 fps even when `CrRendererMain` is idle.

---

## Microbenchmark Suite (1–3s Each)

Run each via `odin run bench/gallery_bench.odin -file -- bench/micro/<name>.lua` using `bench/fixtures/noisy.webp` and `bench/fixtures/noisy.jpg`.

### 1. `bench/micro/startup_masonry.lua` (~1.5s)
* **Isolates:** `DOMContentLoaded`, initial forced layout, and first `syncMasonry()` rAF.
* **Setup:** 1,000 mixed cards (`noisy.jpg`, `noisy.webp`), `1920x1080` viewport.
* **Measurement:** `PerformanceObserver` (`long-animation-frame` + `longtask`) + `rAF` callback timing from navigation until first `syncMasonry()` + `draw()` completes.
* **Metrics / Budgets:** `domContentLoadedMs`, `firstSyncRafMs`, `forcedLayoutCount`, `maxLongTaskMs` (target: no task >20ms after initial parse, or track baseline `~270ms` / `~81ms` down).

### 2. `bench/micro/mipmap_upload.lua` (~1.5s)
* **Isolates:** `loadBatch()` WebP `ImageDecoder` + `gl.texSubImage3D` ring-buffer upload and the `gl.getError()` sync-flush cost.
* **Setup:** Navigate, wait for `batch-complete` (all 1,000 frames decoded) **without** calling `booruPreviewSnapshot()` first (Mode A: `diagnosticsEnabled = false`), then repeat with `booruPreviewSnapshot()` called immediately (Mode B: `diagnosticsEnabled = true`).
* **Metrics / Budgets:** Total `loadBatch` wall time, max single `rAF`/microtask stall (`ms`), `droppedFrames` during upload.

### 3. `bench/micro/scroll_dom_only.lua` (~2s)
* **Isolates:** `onScroll` + `showNearbyCards()` DOM park/unpark + `UpdateStyleAndLayout` on `CrRendererMain`.
* **Setup:** Wait for `loadBatch` to finish (`512` ready + settle), do **not** call `booruPreviewSnapshot()`/`countBlanks()` in the rAF loop. Scroll a fixed 2.0s window (`0 -> 40,000px` at `20k px/s`, and `0 -> 400,000px` wrapped at `200k px/s`).
* **Metrics / Budgets:** `p50Dt`, `p95Dt`, `maxDt`, `dropped` (`dt > 20ms`), `LoAF` count ≥50ms, and total `showNearbyCards` JS time.

### 4. `bench/micro/webgl_strip_draw.lua` (~1.5s)
* **Isolates:** `positionPreviewStrip()` + `draw()` + SwiftShader `960x3780` canvas rasterization (`CrGpuMain` / `WaitForCommitCompletion`).
* **Setup:** 1,000 `<video>`-only cards (or uncached `/image/` that stays incomplete) so every visible card is drawn by WebGL2, after `loadBatch` settles. Scroll for 1.5s at `200k px/s` (forcing `stripTop` rebases and full `draw()` passes) without `countBlanks()`.
* **Metrics / Budgets:** `drawCount`, avg/max `draw()` JS ms, `p50Dt`, `p95Dt`, `maxDt`, `dropped`.

### 5. `bench/micro/blank_check_overhead.lua` (~1s)
* **Isolates:** Benchmark harness cost (`window.booruPreviewSnapshot()` + `countBlanks()`) so measurement overhead is tracked separately from app code.
* **Setup:** Idle page (no scrolling) after `512` mipmaps ready; run `booruPreviewSnapshot()` + `countBlanks()` for 60 frames and measure `snapMs` + `blanksMs` + `dt`.
* **Metrics / Budgets:** `avgSnapMs`, `avgBlanksMs`, `p95Dt` (baseline: `~2.7ms` + `~2.8ms` per frame).

---

## Recommended Execution & Iteration Order

1. **Fix `gl.getError()` in `static/gallery.js`** (only check `gl.getError()` once at `batch-complete` or behind an explicit flag, never per-frame inside `texSubImage3D` when `booruPreviewSnapshot()` is used) -> verify with `mipmap_upload.lua` (~1.5s).
2. **Decouple `countBlanks` / `booruPreviewSnapshot()` from every rAF tick** in `scroll_stutter_bench.lua` (sample periodically or compute from `cardLayouts` / lightweight dirty checks) -> verify with `blank_check_overhead.lua` (~1s).
3. **Iterate on `scroll_dom_only.lua` and `webgl_strip_draw.lua`** (~2s each) to eliminate remaining >20ms `UpdateLifecycle` / `WaitForCommitCompletion` / SwiftShader bottlenecks at `200k px/s`.
4. **Iterate on `startup_masonry.lua`** (~1.5s) to break up `DOMContentLoaded` and `syncMasonry` >20ms tasks.
5. **Run full `bench/scroll_stutter_bench.lua`** as the end-to-end integration gate once the microbenchmarks are green.
