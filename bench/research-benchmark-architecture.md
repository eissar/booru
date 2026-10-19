# Benchmark architecture proposal: gallery thumbnail preview (WebGL2 canvas + ImageDecoder) vs native originals

Status: **proposal only. No code was written, no benchmark or experiment was run, and no app file was changed.**
`static/benchmark.html` is out of scope. Authoritative client behavior is `static/gallery.js` and `static/gallery.css`.
This document builds on `bench/research-headless-gpu.md` (GPU doc) and `bench/research-visibility.md` (visibility doc), and
corrects earlier chat-level claims (section 1).

Evidence labels:
- **[V]** read in a primary source or in this repo this session. Primary pages were fetched through a summarizing search tool, so the wording is paraphrased. Re-read the page before quoting.
- **[S]** secondary source or search-summary text only.
- **[K]** background knowledge, not re-verified.
- **[R]** recommendation.
- **[OPEN]** an empirical question the benchmark itself must answer. Do not assume an answer.

---

## 1. Corrections adopted (relative to earlier chat findings)

| Earlier claim | Correction in this proposal |
|---|---|
| Headless Chromium defaults to software rendering (SwiftShader) | **No universal default is claimed.** The Chromium headless GPU doc says to pass `--enable-gpu` "to disable forcing software rendering", which defers to default driver autodetection. On Linux this needs an X display. `--use-angle=vulkan` was "found to work at least on some Linux configurations" [V: chromium.googlesource.com/.../docs/gpu/using-gpu-hardware-in-headless-chrome.md]. The backend that actually ran must be verified per run (section 5.2). |
| Pass a bundle of flags such as `--ignore-gpu-blocklist`, Vulkan feature flags, disabling background throttling, and `--disable-frame-rate-limit` / `--disable-gpu-vsync` by default | **No blanket bypass or throttling-disable flags.** Start from the minimum documented flag (`--enable-gpu`). Everything else is a separate, labeled *condition* (section 5.3), never part of the baseline. |
| Zero or negligible overhead, "`performance.mark` costs sub-microsecond" | **Retracted.** Every instrument has a cost. Costs are unmeasured until the calibration phase (phase 1) measures them, per browser build and per configuration. No fixed per-mark cost is assumed. |
| IntersectionObserver gives exact continuous visible area | **Retracted.** IO notifies when the ratio crosses a listed threshold and is delivered asynchronously after the rendering update [S: w3.org/TR/intersection-observer]. It gives quantised membership only. |
| "Dropped frames" measured with `requestAnimationFrame` | **Retracted.** rAF callbacks are main-thread frame-start signals. They do not show compositor frame production, GPU completion or presentation. Dropped or janky frames are taken from Chromium trace frame events (`FrameSequenceTracker`, `PipelineReporter`, `FramePresented`) [V per the GPU doc, section 5], with rAF cadence reported only as a main-thread cadence, under that name. |
| Eliminate the CDN / Tailwind variability by self-hosting | **Production CDN/Tailwind runtime is the primary baseline.** A localized (self-hosted, precompiled) variant is an additional, separately labeled alternative. The app is not silently optimized (section 6.2). |
| `document.fonts.ready` before measuring | **Steady-state only.** Waiting for it hides the real initial-load behavior (`font-display: swap` reflows, ResizeObserver triggers). It may be used to define the *start* of steady-state scenarios (scroll, hover, inspector) and never for initial-load scenarios. |
| p99 of pooled frame times | **No pooled-frame p99 inference.** Frames within a run are autocorrelated, so pooling them treats a run as if it had thousands of independent samples. Summaries are per run, and inference is run-level paired with a bootstrap over runs (section 9). Tail statistics need an adequate number of runs and are reported with intervals, or not at all. |
| CPU throttling emulates slower hardware | **Corrected.** CDP CPU throttling is a slowdown factor applied to the page's main thread (renderer). It is not hardware emulation. It does not model a slower GPU, GPU process, decode threads, memory bandwidth or caches. Label it "main-thread slowdown" [K; check `Emulation.setCPUThrottlingRate` text]. Verify it was applied (see the chrome-devtools-mcp issue 1955 about throttling recorded as "none") [S]. |
| Screenshots as presentation evidence | **Corrected.** A CDP screenshot is composited content as captured by the browser, not physical presentation. It can perturb scheduling, so it only runs in a separate pass (section 8). |

---

## 2. Ground truth about the app (read from the files)

### 2.1 Page and DOM [V]
- Head: `<link rel=preload as=fetch href="/mipmap/64?ids=..." fetchpriority=high crossorigin=anonymous>`, then production CDN assets: htmx (unpkg), response-targets (jsdelivr), `cdn.tailwindcss.com` (runtime script), Google Fonts `Inter` with `display=swap`, and the settings icon from unpkg. Then `/static/gallery.css` and `/static/gallery.js` (non-deferred, so the script runs before the body is parsed; DOMContentLoaded gates `init`).
- `#gallery-main.gallery-main.main-scroll` has `overflow: hidden` and a `100vh - 4rem` height. The real scrollport is `.main-content` (`overflow: auto; scrollbar-gutter: stable`) inside `.layout`, with the `.inspector` sibling (`width: 0` → `var(--inspector-width)`, transition 150 ms).
- A single `<canvas id=thumbnail-background>`: `position: fixed; inset: 0; z-index: 0; pointer-events: none`. With `.gallery-previews-active`, `#gallery-main` is `position: relative; z-index: 1`, and card and image backgrounds are transparent. `.gallery-card-meta` stays opaque.
- Cards: `<img src="/image/<sha>" loading=lazy fetchpriority=high width height style="aspect-ratio" class="gallery-card-image transition-transform duration-300 peer-hover:scale-105 order-1">`. The hover scale comes from a Tailwind utility, so it exists only after the Tailwind runtime has generated the CSS (this matters for the localized alternative).
- `.hover-card` in `gallery.css` transitions `box-shadow` for 0.3 s.

### 2.2 Draw path (`draw()`) [V]
- Called from `schedule()` through a single coalesced `requestAnimationFrame`, and directly from `scheduleMasonrySync()`'s rAF and from `requestBatch()`.
- Resizes the canvas to `round(innerWidth * dpr)` × `round(innerHeight * dpr)` when different, `viewport`, `clear` (whole canvas), then per card with a texture: `img.getBoundingClientRect()`, viewport top/bottom cull, a full ancestor walk (`getComputedStyle` + `getBoundingClientRect` on every ancestor), `card.getBoundingClientRect()`, `getComputedStyle(card)`, `getComputedStyle(img)`, 5 uniform calls, `bindTexture`, `drawArrays`.
- The cull rejects cards outside the viewport on top/bottom only. Horizontal and clip-ancestor rejection happen after the ancestor walk.
- No timer query, `finish`, `readPixels` or fence in the app. No IntersectionObserver.
- `schedule()` self-reschedules while `performance.now() < animateUntil`; `transitionDraw()` sets `animateUntil = now + 400`.

### 2.3 Triggers [V]
`scroll` (capture, all scrollers), `resize`, `ResizeObserver` on every card image, `pointerover`, `pointerout`, `transitionrun`, `schedule()` after each uploaded frame, and `requestBatch()` via `htmx:afterSwap` for `/fragment/items` and `/fragment/gallery-content` only. Masonry sync: `htmx:afterSettle`, media-query changes, view radio changes and DOMContentLoaded.

### 2.4 Batch lifecycle [V]
- `requestBatch()` coalesces through one rAF. It then calls `releaseBatch()` (abort, `decoder.close()`, `deleteTexture`), `imageSizes.disconnect()`, collects **all** cards in the grid (not only newly appended ones), builds a new `batch`, calls `draw()`, and starts `loadBatch(current, ids)`.
- Consequence to measure [OPEN]: an htmx *append* (`/fragment/items`) releases all existing thumbnails and re-requests every card. The previously uploaded previews are discarded. Whether that is visible (blank previews while the original has not loaded) is an empirical question.
- `loadBatch()` is `fetch(url, {priority: "high", signal})` → `ImageDecoder({data: response.body, type: "image/webp", preferAnimation: true})` → sequential `decode({frameIndex, completeFramesOnly: true})` → `texSubImage3D(..., image)` per frame, `gl.getError()` after upload, `schedule()` after each frame. A failure removes `gallery-previews-active`.
- Whether the first-batch `fetch` reuses the head preload is not established by reading the code [OPEN]. The code comment says it does.

---

## 3. What must be separated (metric families)

Never sum or equate these. Each has its own instrument (section 7).
1. **Network and server**: bytes, first byte, last byte, request count per URL, server-side generation time.
2. **Decode**: time from response bytes to `VideoFrame` per frame (`ImageDecoder`).
3. **Upload**: `texSubImage3D` call duration on the main thread (CPU-side only).
4. **Draw submit**: main-thread time inside `draw()`, split by phase (DOM reads / cull / GL submit).
5. **GPU execution**: timer queries if available [OPEN], else not measured.
6. **Compositor frame production and presentation feedback**: trace frame events. This is Chrome's presentation feedback, not physical display output.
7. **Content state per card** (what is drawn or painted, and when): "drawn" (draw call recorded) vs "painted" (original image painted) vs composited content in a screenshot.
8. **Visual correctness**: crop, alpha, stale images.

---

## 4. Phased architecture

Each phase ends with a decision gate (section 4.6). A failed gate stops the later phases that depend on it.

### 4.1 Phase 0: environment qualification (no app measurements)
Goals: pin versions, verify that the GPU path is what is claimed, determine which instruments exist.
- Record Chrome/Chromium build, OS/kernel, CPU model and governor, GPU model and driver, display/X state, container device mapping, full command line, `SystemInfo.getInfo` (`gpu.devices[0]`, `auxAttributes`, `featureStatus`) [V for the field list].
- A probe page, separate from the measured app: create a WebGL2 context; read `WEBGL_debug_renderer_info`; list extensions including `EXT_disjoint_timer_query_webgl2`; read `MAX_ARRAY_TEXTURE_LAYERS` and `MAX_CLIENT_WAIT_TIMEOUT_WEBGL`; test `ImageDecoder.isTypeSupported("image/webp")`. The probe may use `failIfMajorPerformanceCaveat`. The measured app must not [R].
- Run the headless GPU doc's minimum flags as separate configurations (section 5.3). Do not assume any one of them works.

### 4.2 Phase 1: instrument calibration
- Null fixture (a page with the same canvas size and DPR but no gallery) and known-cost fixture (a `draw()`-like function with a calibrated busy-wait, a fixture whose canvas is cleared at known times, and a delayed `<img>` with known load time).
- Measure for each instrument configuration: none, counters, marks, marks + timer queries, IO, Element Timing, tracing at several category sets. Outputs: the distribution of the main-thread time delta and frame-production delta relative to "none", with run-level intervals.
- Verify that each metric recovers the known value of the fixtures within a tolerance set in advance.
- Timer queries: granularity via empty queries; disjoint rate; whether results exist at all [OPEN].
- Output: an instrumentation-overhead table that every later report must cite. No overhead number is assumed beforehand.

### 4.3 Phase 2: baseline characterization on the unmodified production page
- The production CDN/Tailwind baseline (section 6.2), default app, the scenario matrix (section 10) on the primary configuration.
- Goal: where the time and visual gaps are, not to compare variants.

### 4.4 Phase 3: sensitivity and attribution
- Labeled variants: localized assets; forced GPU backends; throttle conditions; uncapped frame rate; instrumentation variants. One factor changes at a time.
- Trace-based attribution (do reads inside `draw()` flush style/layout? slice names discovered from the trace, not assumed).

### 4.5 Phase 4: candidate-change evaluation (future)
Only if a change is proposed. A/B on the same harness, run-level paired (section 9). The harness itself must not be changed between A and B.

### 4.6 Decision gates
| Gate | Question | Pass criterion (set before running) | If it fails |
|---|---|---|---|
| G0 | Is the intended GPU backend actually in use? | `SystemInfo` and probe renderer string agree with the intended backend, and it is not SwiftShader/llvmpipe unless that is the labeled control | Stop. Fix the environment or relabel the data set as software |
| G1 | Is the instrumentation floor acceptable? | The calibrated overhead is below a pre-registered fraction of the smallest effect of interest, with its interval | Reduce the instrumentation, move it to a separate pass, or report the effect only as "within the floor" |
| G2 | Does the harness recover known fixtures? | Known blank intervals/draw costs are recovered within tolerance | Do not interpret app results for that metric |
| G3 | Is run-to-run variance small enough for the planned number of runs? | The bootstrap interval half-width of the primary metric, on a pilot, is below the effect size of interest at the planned N | Increase N, fix confounders, or drop the tail metric |
| G4 | Does the preload actually match the stream `fetch`? | Server access log shows exactly one `/mipmap/64` per first load (to be confirmed per configuration) | Report a double fetch as a finding; separate the metrics of the first batch accordingly |
| G5 | Is the layout/clip assumption valid in all views? | The sampled ground truth (screenshot or geometry pass) agrees with the drawn rectangles in masonry/grid/list/inspector states | Treat visual results for that state as invalid until understood |

---

## 5. Browser automation, GPU path and flags

### 5.1 Automation
- Drive Chromium through CDP (raw, Puppeteer or Playwright). The tool matters less than recording its version and ensuring identical settings across runs. The harness runs in its own process and keeps page-side code minimal.
- The harness must not inject large scripts that run during timed windows. Injection occurs before navigation (`Page.addScriptToEvaluateOnNewDocument`) only if an instrument needs it, and counts as part of that instrument's overhead.

### 5.2 Verified backend
Per run, and recorded in the artifact:
- `SystemInfo.getInfo` [V for fields: `devices[].vendorId/deviceId/vendorString/deviceString/driverVendor/driverVersion`, optional `auxAttributes`, `featureStatus`]. Treat `auxAttributes` / `featureStatus` as build-dependent.
- The probe context's `UNMASKED_RENDERER_WEBGL` (ANGLE backend string expected [K]; may be masked in some builds [U]).
- `chrome://gpu` text from a separate page, if available [K].
- The run is *invalid* if the renderer is software and the configuration was not labeled as the software control.

### 5.3 Configuration matrix (each a labeled condition)
| ID | Flags (beyond harness basics) | Purpose |
|---|---|---|
| C-default | headless as documented for the build, no GPU flag | Observed default of this machine (**no universal claim**) |
| C-gpu | `--enable-gpu` [V: GPU doc] | Documented way to stop forcing software rendering. On Linux this may need an X display [V]. |
| C-gpu-vk | `--enable-gpu --use-angle=vulkan` [V: "at least on some Linux configurations"] | Alternative backend where autodetection fails |
| C-sw | `--use-angle=swiftshader` plus `--enable-unsafe-swiftshader` [V names in swiftshader.md; opt-in for automatic fallback is deprecated] | Negative control only |
| C-headed | headed with a real display and verified GPU | Cross-check of new headless vs headed pacing [OPEN] |
| C-bf | `chrome-headless-shell` + `HeadlessExperimental.beginFrame` | Deterministic work comparison only, never throughput. Availability by version is [U] |
| C-uncapped | any of the above plus frame-rate/vsync flags | Cost exposure; separate label, never the default. Flag names are [K] |

Not part of any baseline: `--ignore-gpu-blocklist`, forced Vulkan feature sets, `--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`, `--no-sandbox`. If a specific environment forces one (for example `--no-sandbox` in a container), record it as a variable and never silently include it. Headless windows may not need these; test rather than assume [OPEN].

---

## 6. Controls and confounders

### 6.1 Inputs
- Identical dataset (fixed image bytes, IDs, order, aspect ratios), content-hashed (`/mipmap/64` response body hash, `/image/*` hashes). Fixed viewport, DPR, window size. Fixed theme (`localStorage.theme`) and view (`?view=`).
- Fixed page size options from the fixture (`2, 10, 25, 50, 100`), plus larger synthetic sizes if the server allows (to reach more than one 64-layer texture array and the `ids` URL length limit) [OPEN].
- Alpha-channel originals are a separate class in the dataset (the preview shows through transparent pixels because the image background is transparent).

### 6.2 CDN, Tailwind and fonts: preserved production baseline plus labeled alternative
- **P (production)**: unchanged page: unpkg, jsdelivr, `cdn.tailwindcss.com`, Google Fonts, unpkg icon. The page's behavior including the Tailwind runtime JIT is the baseline. External variability is real here. Control it by recording, not removing: per-request timing, status, `Server-Timing`/headers when present, resolved IP, `Date`, cache state and bytes. Run interleaved and repeated, and report CDN-attributed variance separately. If the internet is not available, label the run as "offline-impossible", not substituted.
- **L (localized)**: the same HTML with the third-party URLs rewritten by the harness (request interception or a local mirror) to byte-identical copies of the same versions, and a precompiled Tailwind stylesheet *only if* it is generated from the same class set and its output equivalence to the runtime result is verified (hover scale `peer-hover:scale-105`, `duration-300`, `order-1`) [OPEN: equivalence]. L is never the baseline and results are never mixed with P. The app is not modified; interception happens in the harness.
- Differences P − L quantify the CDN and runtime-JIT effect. Do not state it in advance.
- **Fonts**: initial-load scenarios take fonts as they arrive (P) with `display=swap` reflow included. `document.fonts.ready` is used only to define the start of *steady-state* scenarios (scroll, hover, inspector, view switch) and the harness records when it resolved. Record `fonts.status` and the number of resize/ResizeObserver-triggered draws after font arrival for load scenarios.

### 6.3 Cache and process state levels
Each result carries a level label.
- **L0**: new profile, empty HTTP cache, cold server state (restart or documented cache reset), no CDN cache control (CDN state cannot be controlled; record).
- **L1**: warm HTTP cache and server, new browser process.
- **L2**: warm cache, same process, second navigation.
- Optional **L3**: back/forward cache. Do not mix levels in a statistic.
- Cache-disable CDP controls change preload and fetch matching behavior. They are a separate labeled condition, not "cold". [K]

### 6.4 Network
- Primary: loopback with no shaping, to isolate CPU/GPU/decode cost.
- Throttled scenarios, by decreasing fidelity:
  1. **Packet-level** shaping outside the browser (for example Linux `tc` netem/tbf in an isolated network namespace, or a shaping proxy), because it naturally includes handshake round trips and protocol behavior [V-ish: Lighthouse docs and DebugBear/Catchpoint summaries call packet-level the most faithful].
  2. **CDP request-level** throttling, only as a secondary comparison. Facts validated this session [S via search summary of Lighthouse `docs/throttling.md`, discussion 15594]:
     - Lighthouse default "simulated" throttling runs an unthrottled load and models a slow network and CPU from the trace. It is not applied.
     - DevTools (request-level) throttling operates between the HTTP cache and the connection layer, so it cannot model TCP slow start, DNS, connection setup, TLS, packet loss, redirects or HTTP/2 prioritization. Lighthouse itself avoids packet-level throttling because OS rules would affect the whole host.
  - Facts about the CDP implementation [S, search summary only]: throttling is a network-service interceptor (`services/network/throttling/throttling_network_interceptor.cc`) that meters delivery by `downloadThroughput`, `uploadThroughput` and `latency`, and divides bandwidth equally across active requests instead of following priority. This is relevant here: the stream `fetch` (`priority: "high"`) competes with the native `<img>` requests, so request-level throttling may change the preview-versus-original race compared with a real link [OPEN].
  - **Streaming limitation: not validated.** The search did not find primary documentation about how `Network.emulateNetworkConditions` interacts with a chunked response consumed as a `ReadableStream` (chunk pacing, burstiness, whether `ImageDecoder` sees realistic progressive arrival). Also `Network.emulateNetworkConditions` appears to be supplemented or deprecated in favor of `Network.emulateNetworkConditionsByRule` and `Network.overrideNetworkState` in current Chromium [S, unconfirmed; check the protocol page for the build used]. Do not assume the stream's arrival pattern under CDP throttling matches a real link. Characterize it first (see experiment E-NET below).
- Record the *measured* delivered throughput and the first/last byte times per request, not the nominal setting. Verify that throttling was in effect from the artifacts.
- **CPU slowdown** (`Emulation.setCPUThrottlingRate`): main-thread slowdown only, not hardware emulation [K]. Label it so. Pair it with the pinned-core hardware control, not replace it.

### 6.5 CPU, memory, scheduling
- Pin browser and server to disjoint cores (for example `taskset`/cgroups) and record the placement. Fixed frequency governor, or at least recorded. Thermal state recorded (temperature before and after each run).
- Interleave scenario/condition order across runs (randomized blocks) so drift does not align with one condition. Each run uses a fresh browser context, and for L0 a fresh profile.
- Idle gap between runs; measure a short calibration busy-loop before each run to detect host noise, and discard or flag runs outside a pre-registered band [R]. Report how many were flagged.

### 6.6 Server and worker costs
- Server: per-request generation time, bytes, first byte, last byte for `/mipmap/64?ids=N`, `/fragment/items`, `/fragment/gallery-content`, `/image/*`. Existing `bench/handlers` and `test/tools/bench.sh` (oha) cover in-process and whole-server throughput [V: bench/README.md]. Use them for the server-only baseline, and the end-to-end harness for per-request timing under browser load.
- Is the response truly progressive (frames arrive as generated) or buffered then sent? Determine from first-byte vs last-byte times as N grows [OPEN].
- Client: `ImageDecoder` runs off the main thread, but the app serializes `decode()` calls. Measure per-frame decode-await time and the upload call duration separately.

---

## 7. Instruments (what each can and cannot tell you)

| Instrument | Gives | Does not give | Overhead |
|---|---|---|---|
| CDP `Network` events / HAR-like log | Request timing, bytes, priority, cache source, initiator | Time of decode, paint | Unmeasured until phase 1 |
| Server access log with timing | Request count per URL (G4), server time | Browser-side time | Unmeasured |
| In-page counters / marks (section 11 hooks) | Main-thread time per phase, counts, per-card state-change times | GPU time; presentation | Unmeasured until phase 1; **not** assumed fixed per mark |
| `EXT_disjoint_timer_query_webgl2` | GPU time of a bracketed command span, if available | Presentation; reliable on every backend | Unmeasured [OPEN]; `GPU_DISJOINT_EXT` samples discarded and counted [V: khronos registry text via summary] |
| Chromium trace (`Tracing.start`) | Compositor/Viz frame events, `FrameSequenceTracker`, `PipelineReporter`, `FramePresented`, drop reasons if present, style/layout slices under `draw()` [V for the existence of the first group per the rendering benchmark doc; names must be discovered from the actual trace] | Exact per-draw GPU time; physical display | Grows with category set; calibrated per category set |
| LoAF / long tasks | Stall diagnosis over 50 ms [V] | Presentation time (not in the IDL seen) [S]; ordinary 17–50 ms frames | Unmeasured |
| IntersectionObserver v1 | Quantised viewport membership as of the last rendering update, honoring overflow clips [S] | Exact continuous area; paint state; occlusion | Unmeasured; dense thresholds cost more |
| Element Timing | First paint of annotated originals (render time) [S] | Canvas content (open issue w3c/element-timing#47) [S]; later repaints | Unmeasured; use on a sample |
| CDP screenshot / screencast | Composited content as captured by the browser, for ground truth pixels | Physical presentation; timing is perturbed | Separate pass only |
| `readPixels` | Correctness of the drawing buffer | Presentation | Only in the same task as a draw, or with a context that preserves the buffer; a different config than timed runs [S: Khronos 1.0 §2.2, WebGL issue 3615; 2.0 wording unchecked] |

Policy: the **timing pass**, **trace pass**, **visibility/screenshot pass** and **correctness pass** are separate runs of the same scenario. A number is only reported from the pass that produced it.

---

## 8. Metric definitions

Notation: a *run* is one browser context executing one scenario once. A *window* is the interval between two harness-defined event times on the trace-aligned clock.

### 8.1 Clock alignment
- `performance.timeOrigin + performance.now()` is mapped to trace timestamps using a `performance.mark` (which appears in the trace under `blink.user_timing` [K]) emitted at the start of each window. The map's residual is measured in phase 1 and reported. Do not assume it is zero.

### 8.2 Load/stream metrics (per run)
- `t_preload_response_start`, `t_mipmap_fetch_start`, `t_mipmap_headers`, `t_decoder_tracks_ready`, `t_frame_decoded[i]`, `t_uploaded[i]`, `t_first_draw_with_texture[i]`, `t_stream_complete`. All from the network log, hooks, or both.
- `mipmap_request_count` per page load (server log), expected 1 (G4).
- `bytes_wasted_on_append`: the bytes of `/mipmap/64` re-downloaded for already-present cards.

### 8.3 Card state machine (per card)
States: `placeholder → preview_drawn → original_painted`, plus `released`, `replaced`.
- `preview_drawn[i]`: the first `draw()` that issued a `drawArrays` for card `i` after its texture upload. Meaning: the draw call was *recorded*, not presented. Named "drawn", never "presented".
- `original_painted[i]`: from Element Timing on a sample of cards, or from the screenshot pass (pixel match against a reference). Not from `load`, `complete` or `decode()`.
- `refinement_latency[i] = original_painted[i] − preview_drawn[i]` (may be negative: the original won the race, which counts as a finding).
- `first_useful_pixel[i] = min(preview_drawn, original_painted)` with a `source` flag.
- Page-level: `t_X_coverage`, the earliest time at which a fraction X of the *cards intersecting the first viewport* are `preview_drawn` or `original_painted`. The set of cards is the DOM-geometry ground truth at the window start, from the harness, not from IO.

### 8.4 Visibility accounting
- IO gives quantised membership only. Report blank *card-count·time* using state-change events, and blank *area·time* only as an approximation with the sampling interval and geometry-change caveat stated. No claim of exact continuous coverage.
- The ground-truth coverage snapshots come from the screenshot pass at a few pre-set instants (not continuous) [R].

### 8.5 Frame and cost metrics
- **Main-thread draw cost** `draw_ms` per call, split into `dom_read_ms`, `cull_ms`, `gl_ms` if the phase hooks exist. A distribution per run, summarized per run (median, a high quantile only when the run has enough calls), never pooled across runs for inference.
- **Draw count** per window and per trigger source (`scroll`, `resize`, `ResizeObserver`, `pointer*`, `transitionrun`, `upload`, `masonry`, `batch`). In idle steady state the expected draw count is zero unless `animateUntil` is active [OPEN: verify].
- **Frame production / presentation**: from the trace only. `frames_produced / frames_expected` per frame-sequence type and drop reasons if present [V per rendering benchmark doc: throughput as `100 * frames_produced / frames_expected`]. Called "Chrome-reported presentation", not physical display. rAF cadence is reported as "main-thread rAF interval" and is **not** used to claim dropped frames.
- **GPU time**: timer-query samples if available, with disjoint count; otherwise "not measured".
- **Scroll lag** (canvas relative to DOM): in the screenshot pass, the vertical offset between a card's DOM rect and the drawn thumbnail position at pre-set scroll positions during a gesture [OPEN: whether any lag is visible and under which main-thread load]. The architecture only exposes the possibility: the canvas is redrawn from the main thread after the compositor has scrolled the DOM [K].
- **Layout flush cost**: in the trace pass, style/layout slices nested in `draw()`, to answer whether the geometry reads force work [OPEN]. They flush only when dirty.
- **Resource churn**: textures created/deleted, decoders created/closed, aborted fetches, peak texture count, optional GPU memory from the trace [K].

### 8.6 Correctness metrics
- Crop formula check (sampled pixel comparison against a reference render of the same card), stale-texture draws (a texture whose id differs from the card's current id, in the window between `releaseBatch` and the new batch), alpha-original blend check, count of `gallery-previews-active` removals.

---

## 9. Statistics

- **Unit of inference is the run.** Each run yields one summary per metric (median, trimmed or specific quantile where the run has enough samples, counts, totals). Per-frame/per-draw series are kept as artifacts for plots and diagnostics only. Frames within a run are autocorrelated, so pooled-frame p99 values are not used for inference.
- **Pairing and design**: interleaved A/B (or condition blocks) in randomized order within blocks, with each block on the same machine state. Compare paired per-block differences. Where pairing is impossible, use unpaired designs and say so.
- **Intervals**: percentile or BCa bootstrap **over runs** (resample runs, or blocks for paired designs), not over frames. Report the interval for the median difference or ratio. A hierarchical bootstrap (blocks, then runs) is allowed when a session structure exists. Hodges-Lehmann estimator or permutation tests are acceptable for tests. Use multiplicity control (for example Holm) when scanning many cells, or state the scan as exploratory.
- **Tails**: a high quantile at the run level (for example p95 of draw time in a run) needs enough samples in the run. A tail *across runs* (for example the worst of runs, p95 of run medians) needs a large number of runs. Pilot-based power analysis (G3) sets N. If N is too small the tail is reported as "not estimable at this N", with the raw points shown, rather than as a number. A p99 of per-run quantiles is only reported when the number of runs allows it and the interval is shown.
- **Warm-up** is defined per scenario (shader compile, first texture allocation, JIT) and reported separately as first-use cost. It is not silently dropped.
- **Pre-registration**: metrics, windows, exclusions (host-noise band), N and the minimum effect of interest are written before the main run. Flagged/excluded runs are listed with reasons.
- **Reporting**: raw per-run values, the intervals, the instrumentation floor from phase 1 beside each result, and the label (cache level, config ID, network condition, asset variant P or L, pass type).

---

## 10. Scenario matrix

All scenarios use the primary configuration after G0 passes, in views masonry / grid / list unless noted, inspector closed unless noted. "Pass" abbreviations: T timing, R trace, V visibility/screenshot, C correctness.

| ID | Scenario | Variations | Primary metrics | Passes |
|---|---|---|---|---|
| S1 | Initial load, production assets | L0/L1/L2; page size 2,10,50,100; P vs L | 8.2, 8.3, `mipmap_request_count`; font reflow draws | T R V |
| S2 | **Preload / stream / native `<img>` race** | Server-side delay injection on `/mipmap/64` vs `/image/*` (each way, separately); loopback vs packet-level shaping; lazy-load threshold distance (cards below the fold) | per-card `source` of first useful pixel; `refinement_latency` sign; whether the preview ever appears | T V |
| S3 | Preload timing variants | `fetch` before/after preload response; preload response ahead of script | G4, duplicate-fetch detection (server log) | T |
| S4 | Idle steady state (after load, after `fonts.ready` marker) | 10 s window | Draw count (expected 0 unless an animation window is active), CPU use | T R |
| S5 | Scroll inside `.main-content` | Synthesized gestures (section 10.1), slow / fast; masonry/grid/list; during stream vs after complete | `draw_ms`, draw count by trigger, trace frame metrics, scroll lag (V), blank cards during scroll | T R V |
| S6 | Hover sweep | Pointer paths crossing many cards; inspector closed/open; hover transform on cards with Tailwind present | Draw count per 400 ms window, `draw_ms`, frame metrics; does `pointerover` on non-card elements add draws | T R |
| S7 | Inspector open/close and resize | Open, close, open during stream; masonry/grid/list; width 150 ms transition | `ResizeObserver`-triggered draws, clip correctness (`.main-content` shrink), layout flush in trace | T R V C |
| S8 | View switch | masonry↔grid↔list; during stream; after stream | `syncMasonry` time, draws after reparent, visual correctness mid-switch | T R V C |
| S9 | htmx **append** (`/fragment/items`) | At end of scroll; page sizes; previews complete vs in progress | Wasted bytes, blank-preview interval for existing cards, textures deleted/re-created, `releaseBatch`→first draw gap | T R V |
| S10 | htmx **filter / page-size replacement** (`/fragment/gallery-content`) | During stream, after stream | Abort cleanliness (no stale draws, texture and decoder counts), time to first useful pixel of new viewport | T R V C |
| S11 | Rapid successive swaps | 3-5 swaps within a short interval | `batchQueued` coalescing, aborted fetch count, stale-texture draws | T C |
| S12 | Failure injection | 500; truncated body; slow body; WebP frame-count mismatch; unequal frame sizes | Fallback to native images, class removal, no uncaught errors | T C |
| S13 | Window resize / DPR change | Fixed sizes sequence | Canvas reallocation cost, correctness after resize | T R V C |
| S14 | Hardware control | Same S5/S6 on C-gpu vs C-gpu-vk vs C-sw vs C-headed | Backend-attributable change in `draw_ms`, GPU time, frame metrics | T R |
| S15 | Throttle characterization | CDP request-level vs packet-level at the same nominal rate, loopback reference | Chunk arrival times of the `/mipmap/64` stream, first-frame time, per-card order effects (experiment E-NET below) | T |
| S16 | CPU slowdown | `Emulation.setCPUThrottlingRate` at a few factors, labeled main-thread slowdown | Effect on draw count, `draw_ms`, blank interval (does the preview still win over native images?) | T R |
| S17 | Production vs localized assets | S1, S5, S9 with P vs L | Quantify CDN/runtime Tailwind effect | T R |
| S18 | Alpha originals | Dataset subset with alpha | Blend correctness, refinement visibility | V C |

### 10.1 Realistic scrolling input
- Use `Input.synthesizeScrollGesture` where possible so input goes through the browser input pipeline. Parameters validated this session from the DevTools protocol Input page (via search summary) [V/S]: `gestureSourceType` (optional; default queries the platform for the preferred type), `speed` (optional integer, pixels per second, default 800), `preventFling` (optional boolean, default true), `repeatCount` (optional integer, repeats beyond the first, default 0). Not retrieved: the full `GestureSourceType` enumeration (expected `default`, `touch`, `mouse` [K]) and how `repeatDelayMs` interacts with `repeatCount` [OPEN]. Read the protocol page for the pinned build.
- Because `preventFling` defaults to true, **fling/momentum is off by default**. If a scenario needs inertia, the parameter must be set and its effect verified in the trace (the platform behavior is [U]); an explicit label "synthetic gesture, no fling" is attached otherwise.
- Alternative: `Input.dispatchMouseEvent` with `mouseWheel`, a series with controlled deltas and timestamps.
- Scroll target: `Input` coordinates must be inside `.main-content`, not the window. Verify in the trace which scroller moved (`scroll` events with capture hit multiple scrollers).
- `element.scrollTop = ...` or `scrollTo` is allowed only for deterministic *positioning* between measured windows, never as the measured input.
- Gesture parameters are written to the artifact.

### 10.2 Experiment E-NET (before relying on any throttled scenario)
1. Serve a streaming body (a synthetic WebP or arbitrary bytes) with known server-side chunk timestamps.
2. Fetch it in the page as the app does, record `ReadableStream` chunk arrival times (`performance.now()` in a measurement-only page).
3. Compare: no throttle, CDP request-level throttle, packet-level shaping, at the same nominal rate.
4. Output: chunk size/time distribution, burstiness, total time vs nominal, and whether concurrent native image requests share bandwidth equally under CDP [S] versus under packet-level shaping.
5. Decision: use CDP throttling in the main matrix only if the stream arrival pattern is acceptable for the question being asked.

---

## 11. Optional future app hooks (no implementation; exact existing function names in `static/gallery.js`)

Principles: every hook is optional, guarded by a single presence check, and removable. **No claim is made about their cost**; phase 1 calibrates each one. Prefer external observation first (CDP, trace, server log). Add a hook only if an external method cannot answer a question.

| Function in `static/gallery.js` | What a hook could record | Question it answers |
|---|---|---|
| `draw()` | Start/end timestamps; counts of cards considered, culled by the top/bottom cull, rejected by the clip chain, skipped for missing texture, and drawn; optionally phase timestamps around the DOM-read block and the GL block | Per-draw main-thread cost and what fraction of cards pay the ancestor walk |
| `draw()` (inside the loop) | One-time per card per batch: first `drawArrays` for `thumbnails[i]` (store batch id, index, timestamp) | `preview_drawn[i]` |
| `schedule()` | Which trigger asked (needs an argument or a caller tag) and whether it was coalesced | Draw count by trigger source (hover/scroll/resize/RO/upload) |
| `transitionDraw()` | Count and the extension of `animateUntil` | How often 400 ms redraw windows are opened and extended |
| `requestBatch()` | Mark at entry (queued), at the rAF run, card count, batch id | Batch rebuild frequency and timing on append/replace |
| `releaseBatch()` | Mark with number of textures deleted and whether a decoder existed | Resource churn on append/replace |
| `loadBatch(current, ids)` | Marks at: response headers received, `decoder.tracks.ready`, each decoded frame (index), each `texSubImage3D` return, `completed` | Stream/decode/upload latencies per frame |
| `init()` | Result of context creation, extension presence checks (kept read-only), shader compile/link duration | First-use cost, the GPU backend string if exposed through the app |
| `syncMasonry()` | Start/end, columns, card count, whether the early return happened | Reparent cost, no-op frequency |
| `scheduleMasonrySync()` | Which trigger queued it | Masonry sync trigger frequency |
| `globalThis.booruToggleInspector` | Mark at toggle | Anchor for the inspector scenario window |
| `imageSizes` (the `ResizeObserver` callback `schedule`) | Count of RO notifications per window | RO-driven draw count during inspector/hover transforms |

A read-only snapshot accessor (for example `globalThis.booruBenchSnapshot()` returning batch id, card count, uploaded count, texture count, `animateUntil`) would reduce the need for `evaluate` polling. It is a new name and optional.

Where an external method suffices, prefer it:
- Request count and timing: server log and CDP `Network`.
- Frame production: trace.
- Original paint: Element Timing sample or screenshots.
- Layout flush inside `draw()`: trace slices.

---

## 12. Artifact JSON schema (example, abbreviated)

One JSON document per run, plus raw files referenced by relative path. `schema_version` bumps on any field change. Fields marked `null` where not measured. Example values are illustrative and are **not** results.

```json
{
  "schema_version": 1,
  "run": {
    "id": "2000-01-01T00:00:00Z-s05-c-gpu-L1-0007",
    "scenario": "S5",
    "pass": "timing",
    "block": 3,
    "order_in_block": 2,
    "cache_level": "L1",
    "asset_variant": "P",
    "view": "masonry",
    "inspector": "closed",
    "page_size": 50,
    "seed": 12345,
    "valid": true,
    "invalid_reasons": []
  },
  "environment": {
    "browser": { "product": "string", "version": "string", "user_agent": "string", "command_line": ["..."] },
    "config_id": "C-gpu",
    "gpu_verified": {
      "system_info_device0": { "vendorString": "...", "deviceString": "...", "driverVendor": "...", "driverVersion": "..." },
      "probe_renderer_string": "ANGLE (...)",
      "is_software": false,
      "timer_query_available": null,
      "max_array_texture_layers": null,
      "max_client_wait_timeout_webgl": null
    },
    "host": { "os": "...", "kernel": "...", "cpu": "...", "governor": "...", "cpu_affinity_browser": "...", "cpu_affinity_server": "...", "temp_start_c": null, "temp_end_c": null },
    "display": { "mode": "headless-new", "x_display": null, "viewport": [1280, 800], "dpr": 1 },
    "throttle": {
      "network": { "kind": "none|cdp|packet", "nominal": null, "verified_from_artifact": null },
      "cpu": { "kind": "none|cdp_main_thread_slowdown", "rate": null, "verified": null }
    },
    "calibration_ref": "calibration/2000-01-01.json",
    "host_noise_probe_ms": null
  },
  "dataset": {
    "name": "string",
    "ids_hash": "sha256:...",
    "mipmap_body_hash": "sha256:...",
    "alpha_originals": 0
  },
  "instrumentation": {
    "level": "none|counters|marks|marks+timer|trace|screenshots",
    "hooks": ["draw", "loadBatch"],
    "trace_categories": [],
    "gesture": { "method": "Input.synthesizeScrollGesture", "params": { "speed": 800, "preventFling": true, "repeatCount": 0, "gestureSourceType": "default" } },
    "clock_map": { "mark_name": "bench-start", "residual_us": null }
  },
  "network_log": [
    { "url": "/mipmap/64?ids=...", "request_count_for_url": 1, "priority": "High", "from_cache": null,
      "t_request_start_ms": null, "t_first_byte_ms": null, "t_last_byte_ms": null, "bytes": null, "chunk_times_ms": null }
  ],
  "server": { "log_path": "server.log", "mipmap_requests": 1, "generation_ms": null },
  "load": {
    "t_tracks_ready_ms": null, "t_stream_complete_ms": null, "fonts_status_at_steady_start": null,
    "frames": [ { "i": 0, "t_decoded_ms": null, "t_uploaded_ms": null, "t_first_draw_ms": null } ]
  },
  "cards": [
    { "index": 0, "id": "string", "preview_drawn_ms": null, "original_painted_ms": null,
      "first_pixel_source": "preview|original|none", "refinement_latency_ms": null, "released_ms": null }
  ],
  "draws": {
    "count": null, "by_trigger": { "scroll": 0, "resize": 0, "ro": 0, "pointer": 0, "transition": 0, "upload": 0, "masonry": 0, "batch": 0 },
    "series_path": "draws.f64",
    "per_run_summary": { "draw_ms_median": null, "draw_ms_q95": null, "q95_valid": false, "samples": null }
  },
  "frames": {
    "source": "trace",
    "sequences": [ { "type": "wheel_scroll", "produced": null, "expected": null, "drop_reasons": {} } ],
    "raf_interval_ms_summary": { "label": "main-thread rAF interval, not frame drops", "median": null }
  },
  "gpu": { "timer_query_samples": null, "disjoint_count": null, "note": "null if unavailable" },
  "resources": { "textures_created": null, "textures_deleted": null, "decoders_closed": null, "aborted_fetches": null },
  "correctness": { "stale_texture_draws": null, "crop_mismatch_cards": null, "alpha_mismatch_cards": null, "previews_class_removed": false },
  "artifacts": { "trace": "trace.json.gz", "screenshots": [], "har_like": "network.json" },
  "exclusions": { "flagged_by_noise_band": false, "notes": [] }
}
```

Aggregate artifact (one per experiment): the list of run IDs, the pre-registered design (N per cell, effect of interest, exclusion rules), per-cell run-level summaries, bootstrap intervals (method, resamples, seed), and the calibration table used.

---

## 13. Open empirical questions (do not assume answers)

1. Which GPU path (default vs `--enable-gpu` vs `--use-angle=vulkan`) is hardware on the target machine, and does new headless pace frames like headed? Both require X on Linux for autodetection per the doc [V].
2. Is `EXT_disjoint_timer_query_webgl2` present, with what granularity and overhead, on each backend? Does the WebGL2 interface include `queryCounterEXT`? Normative result-availability wording was not retrieved [U].
3. Overhead of each instrument (marks, counters, IO, Element Timing, trace categories, screenshots), per configuration.
4. Does the stream `fetch` reuse the head preload in all timings (G4)? Is the request mode/credentials match sufficient?
5. How does CDP request-level throttling pace a streamed response, and does it reproduce real-link behavior and the stream-vs-image bandwidth sharing (E-NET)? Documentation for this interaction was not found.
6. Do the geometry reads in `draw()` flush style/layout, or are they mostly cheap reads of clean state? Depends on dirtiness at the moment of the read.
7. Does a canvas lag behind compositor-scrolled DOM under main-thread load? How visible is it?
8. How often is the preview visible before the native original on first load, and does that depend on the lazy-load distance and cache level?
9. How much does an append (full re-request) cost in bytes and visible blank previews?
10. Is the localized Tailwind output equivalent to the runtime result (hover scale, transitions)? What is the P-vs-L difference?
11. Is the `HeadlessExperimental.beginFrame` available in the pinned build? Only weakly sourced as unavailable in new headless [S].
12. Do `pointerover`/`pointerout` on non-card elements cause avoidable 400 ms redraw windows? What is the idle draw count?
13. Does `texSubImage3D` with a `VideoFrame` follow the canvas's premultiplied alpha convention for alpha originals?
14. How many runs are needed (G3) to estimate the tails that matter?
15. Full `GestureSourceType` values and `repeatDelayMs` semantics for the pinned build; fling behavior with `preventFling: false` in headless.

---

## 14. Sources
- GPU in headless: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/using-gpu-hardware-in-headless-chrome.md
- SwiftShader: https://chromium.googlesource.com/chromium/src/+/main/docs/gpu/swiftshader.md
- Headless README: https://chromium.googlesource.com/chromium/src/+/lkgr/headless/README.md ; https://developer.chrome.com/docs/automation-and-testing/headless-chrome-shell
- DevTools protocol: https://chromedevtools.github.io/devtools-protocol/tot/Input/ (`synthesizeScrollGesture`), https://chromedevtools.github.io/devtools-protocol/tot/Network/ (`emulateNetworkConditions`), https://chromedevtools.github.io/devtools-protocol/tot/SystemInfo/, https://chromedevtools.github.io/devtools-protocol/tot/Emulation/ (`setCPUThrottlingRate`, not fetched)
- Lighthouse throttling: https://github.com/GoogleChrome/lighthouse/blob/main/docs/throttling.md ; https://github.com/GoogleChrome/lighthouse/discussions/15594
- Packet-level vs DevTools throttling (secondary): https://www.catchpoint.com/blog/full-throttle-comparing-packet-level-and-devtools-throttling ; https://www.debugbear.com/blog/packet-level-throttling ; https://www.debugbear.com/blog/chrome-devtools-network-throttling
- Chromium throttling implementation reference (from search summary, not opened): `services/network/throttling/throttling_network_interceptor.cc`; https://issues.chromium.org/issues/40741083
- Throttling silently not applied in one tool (secondary): https://github.com/ChromeDevTools/chrome-devtools-mcp/issues/1955
- Rendering/frame metrics: https://chromium.googlesource.com/chromium/src/+/main/docs/speed/benchmark/harnesses/rendering.md ; https://chromium.googlesource.com/chromium/src/+/lkgr/docs/speed/debug-janks.md ; https://perfetto.dev/docs/analysis/stdlib-docs
- Timer queries: https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query_webgl2/
- WebGL drawing buffer: https://registry.khronos.org/webgl/specs/latest/1.0/#2.2 ; https://github.com/KhronosGroup/WebGL/issues/3615
- IntersectionObserver: https://www.w3.org/TR/intersection-observer/ ; https://w3c.github.io/IntersectionObserver/v2/
- Element Timing / LoAF: https://w3c.github.io/element-timing/ ; https://github.com/w3c/element-timing/issues/47 ; https://www.w3.org/TR/long-animation-frames/ ; https://developer.chrome.com/docs/web-platform/long-animation-frames
- WebCodecs: https://www.w3.org/TR/webcodecs/
- Repo: `static/gallery.js`, `static/gallery.css`, `test/html-fixture-tdd/fixture/*.expected.html`, `bench/README.md`, `bench/research-headless-gpu.md`, `bench/research-visibility.md`

Search-validation notes for this document: the `Input.synthesizeScrollGesture` parameter defaults, the Lighthouse throttling semantics and the CDP throttling interceptor description came from summarizing search results, not raw page reads. CDP behavior with streamed bodies was searched for and **not found** in primary documentation.
