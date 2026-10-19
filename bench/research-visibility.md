# Visibility measurement research (gallery thumbnails / originals)

Status: research only. No benchmark or experiment has been run. Claims are tagged:
**[V]** verified in a primary source or the repo during this session,
**[S]** supported only by secondary or search-summary text,
**[R]** recommendation,
**[U]** uncertain / platform-specific / not verified.
Where the search tool returned only summaries (it could not dump spec text verbatim), the claim is tagged [S], not [V].

## 1. Repo facts (verified by reading `static/gallery.js`, `static/gallery.css`)
- [V] `draw()` runs from a coalesced `requestAnimationFrame` (`schedule()` / `pending`), and `transitionDraw()` keeps redrawing for 400 ms.
- [V] Per card per draw it reads `img.getBoundingClientRect()`. It then walks every ancestor calling `getComputedStyle` + `getBoundingClientRect`. It also reads the card rect, the card's computed border radius and the image's computed `object-fit`.
- [V] Culling uses only the viewport plus overflow-clipping ancestors. It does not model occlusion by the inspector or other overlays, and it does not know whether the original `<img>` has painted.
- [V] The canvas is `position: fixed; inset: 0; z-index: 0`. With `.gallery-previews-active`, `#gallery-main` is `position: relative; z-index: 1`, and the card and image backgrounds are `transparent`. `.gallery-card-meta` stays opaque. The native `<img>` paints over the canvas.
- [V] The source crop assumes a square decode canvas with content at the origin and the `WebPPictureRescale` rounding rule. A mismatch gives a wrong crop that no timing metric detects.

## 2. Corrections to the earlier (chat) report
| Earlier statement | Status now |
|---|---|
| "Cross-origin Element Timing needs `Timing-Allow-Origin` for `renderTime`" | Outdated. MDN states that `renderTime` was originally 0 for cross-origin, that this was resolved in late 2024, and that a slightly coarsened `renderTime` is available from Chrome/Edge 133 without TAO [S: MDN]. TAO still gives more accurate values. Not relevant for same-origin, but do not assert the old rule. |
| "IO v2 false negatives on rounded corners / transforms" | Rounded corners: **unsupported**, do not claim. The v2 text says false negatives are allowed and false positives are not [S]. Defined `false` cases: effective opacity ≠ 100% anywhere in the containing-block chain, any filter, transforms other than 2D translation or proportional 2D upscaling, and any case where the implementation cannot guarantee that the target is unoccluded [S: summary of w3c.github.io/IntersectionObserver/v2]. Hover transforms (probably scale-up) might be OK or not. Test it. |
| "`presentationTime` on LoAF entries" | **Unsupported.** The IDL retrieved lists `renderStart`, `styleAndLayoutStart`, `blockingDuration`, `firstUIEventTimestamp`, `scripts` (plus the base `startTime`/`duration`) and no `presentationTime` [S]. Do not rely on LoAF for presentation time. |
| "`beginFrame` unavailable in new headless" | Only weakly sourced. Third-party issue threads report `HeadlessExperimental.beginFrame` missing in recent Chromium (one cites 147+) [S]. Treat as [U], and check the actual Chrome version in use. |
| "getBoundingClientRect / getComputedStyle force layout" | Over-simplified. Paul Irish's list says they synchronously compute style and layout [S], but this means *flush if dirty*. If nothing invalidated style or layout since the last flush, the read is cheap. In a read-only loop, repeated reads after the first are mostly not full layouts. `getComputedStyle` flushes style, and some property reads also need layout. Cost depends on dirtiness, and it is not the same as "forced layout every call". Measure with a trace (see §7). [U per engine] |
| "IO evaluated once per rendering update" | Supported. The processing model is hooked into the HTML "update the rendering" step and notifications are delivered asynchronously [S]. Note that this is not per-pixel-continuous. |
| "Element Timing doesn't cover canvas" | Supported: w3c/element-timing issue #47 is the open feature request [S]. Treat canvas as not covered. |
| "Zero / negligible overhead" wording | Retracted. No instrumentation is free. Every option below has a cost that must be calibrated. |

## 3. IntersectionObserver (v1 and v2)
- [S] v1 intersection is computed against the root, with clipping by overflow ancestors between the target and the root taken into account. This fits the inner `#gallery-main` scrollport with `root: null`. Verify empirically, including with nested `overflow:hidden` card wrappers.
- [S] The thresholds define when a notification is delivered, namely when the ratio crosses a listed value. Entries are queued and delivered asynchronously after the rendering update.
  - **Consequence:** sparse thresholds cannot give exact continuous coverage. With `[0,1]` you only learn when an element becomes partially visible or fully visible. Area-time integrals built from sparse thresholds are approximations bounded by the threshold spacing. A dense threshold list (e.g. 0, 0.05, …, 1) raises the notification count and cost. Between notifications the ratio is unknown, so it is wrong to claim exact coverage. Use it for *membership in the viewport* and treat visible-area accounting as quantised. [R]
- [S] v1 ignores opacity, occlusion and paint state. It says nothing about whether pixels exist.
- [S] v2 `trackVisibility: true` requires `delay >= 100` ms. `isVisible` is conservative. The result is unusable for sub-100 ms blank-time accounting. [R] Use it only as an occasional spot check for overlay occlusion (for example by the inspector). It does not see the canvas behind an element as a distinct layer. [U]
- Sources: https://www.w3.org/TR/intersection-observer/ , https://w3c.github.io/IntersectionObserver/v2/ , https://web.dev/articles/intersectionobserver-v2 , https://github.com/mozilla/standards-positions/issues/672 , https://github.com/web-platform-tests/interop/issues/1080 (v2 interop status; read for cross-browser support).
- Gap: normative clip-algorithm text was not extracted in this session. Read section "Compute the Intersection of a Target Element and the Root" directly. [U]

## 4. Element Timing / paint timing / LCP / LoAF
- [S] `PerformanceElementTiming` entries expose `renderTime` and `loadTime`. A newer spec revision discusses `paintTime`/`presentationTime` via a paint-timing mixin, with `renderTime` defined relative to them (w3c/paint-timing#121) [S]. Which attributes each shipped browser exposes is [U]. Check MDN's compatibility table.
- [S] Entries are for annotated elements (`elementtiming` attribute) of supported types (images and text), reported once per element. Therefore they give the first paint of an original, not later repaints.
- [S] Cross-origin: see the correction above (Chrome 133+).
- [S] Canvas is unsupported (element-timing#47). The preview can therefore not be observed with Element Timing.
- [U] LCP: LCP candidate eligibility excludes canvas in my recollection. I did not verify it this session. Do not use LCP as a per-card metric either way.
- [S] LoAF is Chromium-only. It reports frames over 50 ms, with script attribution. It is a stall diagnostic and not a presentation timestamp. It will not see ordinary 17–50 ms frames.
- Sources: https://w3c.github.io/element-timing/ , https://developer.mozilla.org/en-US/docs/Web/API/PerformanceElementTiming , https://developer.mozilla.org/en-US/docs/Web/API/PerformanceElementTiming/renderTime , https://github.com/w3c/element-timing/issues/47 , https://github.com/w3c/paint-timing/issues/121 , https://www.w3.org/TR/long-animation-frames/ , https://developer.chrome.com/docs/web-platform/long-animation-frames .
- Overhead caveat: putting `elementtiming` on every image may add observer entries and bookkeeping. Its cost is not measured. [R] Sample, or compare configurations.

## 5. Painted vs decoded vs submitted vs presented
- [S] The WebGL spec presents the drawing buffer to the page compositor "immediately before a compositing operation", only if `clear`/`drawArrays`/`drawElements` ran since the last compositing, and by default clears the buffer after compositing. With `preserveDrawingBuffer: false`, `readPixels`/`toDataURL` after the rendering function returns is undefined [S: Khronos WebGL 1.0 §2.2; issue KhronosGroup/WebGL#3615]. The WebGL 2.0 wording was not checked. [U]
  - Consequence: readback must happen in the same task as the draw, or the context needs `preserveDrawingBuffer: true`. Changing the context attribute could change performance, so a readback build is a different configuration from the timed one. [R]
- [U] A `drawArrays` return only means the command was recorded. GPU completion needs a sync (`fenceSync`/`finish`), and both stall or perturb the pipeline. Presentation to the display is a further step. Neither the CDP nor the spec text consulted exposes a per-frame display timestamp. Tracing categories (`viz`, `gpu`, `cc`) may expose swap/presentation events. That claim is from memory and unverified.
- [S] `img.decode()` resolves when the image can be painted. It does not prove it was painted, composited, or in view. `img.complete`/`naturalWidth` only means loaded and parsed. [V for the semantics of `complete`, from HTML spec memory; recheck]
- **Screenshots are not physical presentation.** `Page.captureScreenshot` captures compositor output obtained by the browser. The search results did not document whether it reads the live display surface or a separately produced frame, and the `fromSurface` option varies across tooling [S]. It cannot prove what a monitor displayed, and a screenshot can itself perturb frame scheduling. Treat it as the best available *composited-content* ground truth, and not as presentation timing. [R]
- Headless: GPU/ANGLE backend (hardware vs SwiftShader) must be recorded in the results, because presentation behavior and raster cost differ. [R]
- Cross-origin taint: not an issue for same-origin images. Taint would only matter for `drawImage` of cross-origin images onto a 2D canvas for comparison. CDP screenshots bypass page-level taint. [U, from memory]

## 6. Preview behind original, and alpha originals
- [V] CSS makes the image background transparent and the canvas sits behind. So the preview shows wherever the `<img>` has no opaque painted pixels, and the original covers it once painted.
- **Alpha originals (needs verification):** if an original has transparency, the preview shows through those pixels, so "original refinement" is visually blended with the preview rather than replacing it. Then "covered by original" is not a valid assumption, and a blank-area metric based on "original painted ⇒ preview irrelevant" is wrong for alpha. Check the dataset for images with alpha channels, and handle them as a separate class. [R]
- [S] WebCodecs `ImageDecoder` outputs `VideoFrame`s. Upload via `texImage3D`/`texSubImage3D` respects `UNPACK_PREMULTIPLY_ALPHA_WEBGL` according to a Chromium issue (40230259) discussing `texImage2D` [S]. The shader's alpha convention (premultiplied or not) must match the canvas's `premultipliedAlpha` setting and the blend state. That is unverified for the 3D path. [U] The preview itself being wrong for alpha images is a correctness check, separate from timing.
- Sources: https://www.w3.org/TR/webcodecs/ , https://issues.chromium.org/issues/40230259 .

## 7. Proposed metrics (definitions, with their limits)
Define per-card state transitions with timestamps rather than continuous integrals:
`placeholder → preview_drawn → original_painted`, plus `released` and `replaced` states.
- **Coverage snapshot** at sampled instants: the sum of visible card area with a pixel source / total visible area. Visible area from IO is quantised ([R] cross-check against a geometry pass in calibration only, not in the timed pass).
- **Blank area·time**: accumulate area × interval between state-change events. This is an approximation when the geometry changes during scroll, and must be reported with that qualification.
- **First useful image**: earliest of `preview_drawn` or `original_painted`, with a flag for which one. Page-level: time to X% coverage of the first viewport.
- **Refinement latency**: `original_painted − preview_drawn`. `original_painted` is observed via Element Timing (sampled) or screenshot comparison, not via `load`/`decode`.
- **Stale / wrong image**: compare the texture-layer→id map at draw time with the card's current id, count draws in the window between `releaseBatch` and the new batch, and run sampled pixel checks against a reference render. Also check the crop formula.
- "Drawn" means a draw call was recorded. It does not mean the pixels were presented. Name the metric accordingly. [R]

## 8. Instrumentation and calibration plan
1. Cheap counters in `draw()` (cards considered/culled/drawn/missing-texture). These are plain integer increments, but not free; calibrate them too.
2. One IO v1 observer as an independent in-viewport signal, with a modest threshold list. Measure its cost against the baseline.
3. Sampled Element Timing on a subset of originals.
4. LoAF or long tasks for stall attribution.
5. Chromium trace on a few runs, to count how much time `getBoundingClientRect`/`getComputedStyle` flushes take inside `draw()`. This answers "do reads force layout here" empirically (§2).
6. Screenshots and `readPixels` in a separate calibration pass only.
7. Calibration: A/B/C configurations (no instrumentation; counters; counters + IO; + Element Timing), ≥ N runs each, compare frame-time distributions, and report deltas with confidence intervals. Build a synthetic fixture with known blank intervals (a delayed `<img>`, a canvas cleared at known times), and check that each metric recovers the known value within a tolerance. Include a fixture with alpha originals.
8. Matrix: masonry/grid/list; inner scroll (fixed velocity and jump); inspector open/resize; hover transform; htmx append and filter replace; cold/warm cache; throttled network; GPU vs SwiftShader.

## 9. Ranked recommendations
1. [R] Report "drawn" and "painted" states with explicit definitions. Never describe them as "presented".
2. [R] Use counters in `draw()` plus an IO v1 membership signal. Do not claim exact coverage from sparse thresholds.
3. [R] Use a CDP screenshot, in a separate pass, as ground truth for composited content, together with a synthetic calibration fixture.
4. [R] Use Element Timing on a sample, for the first-paint timing of originals only.
5. [R] Trace once to measure whether the geometry reads in `draw()` actually flush layout, then decide whether to cache the clip chain.
6. [R] Do not use IO v2, LCP, `img.complete` or `decode()` as per-card visibility proxies. Treat LoAF as stall attribution only.
7. [R] Handle alpha originals as a separate class and verify the premultiplied-alpha path.

## 10. Open uncertainties
- Exact normative IO clip algorithm and v2 transform rules; cross-browser support of v2.
- Which of `renderTime`/`paintTime`/`presentationTime` each shipped browser exposes, and the coarsening rules of Chrome 133+.
- Whether `Page.captureScreenshot` perturbs frame timing, and what it reads from.
- `HeadlessExperimental.beginFrame` availability by Chromium version.
- WebGL 2 text on drawing-buffer clearing; `texSubImage3D` with `VideoFrame` and alpha.
- Layout-flush cost of `draw()` on real pages.
- LCP canvas eligibility.
- Everything platform-specific about GPU backend and presentation.

## 11. Sources
- https://www.w3.org/TR/intersection-observer/
- https://w3c.github.io/IntersectionObserver/v2/
- https://web.dev/articles/intersectionobserver-v2
- https://github.com/mozilla/standards-positions/issues/672
- https://github.com/web-platform-tests/interop/issues/1080
- https://w3c.github.io/element-timing/
- https://developer.mozilla.org/en-US/docs/Web/API/PerformanceElementTiming
- https://developer.mozilla.org/en-US/docs/Web/API/PerformanceElementTiming/renderTime
- https://github.com/w3c/element-timing/issues/47
- https://github.com/w3c/paint-timing/issues/121
- https://www.w3.org/TR/long-animation-frames/
- https://developer.chrome.com/docs/web-platform/long-animation-frames
- https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureScreenshot
- https://screenshotone.com/blog/take-a-screenshot-from-the-surface-in-puppeteer-and-chrome-devtools-protocol/
- https://github.com/heygen-com/hyperframes/issues/294 (secondary, for beginFrame)
- https://gist.github.com/paulirish/5d52fb081b3570c81e3a
- https://registry.khronos.org/webgl/specs/latest/1.0/#2.2
- https://github.com/KhronosGroup/WebGL/issues/3615
- https://www.w3.org/TR/webcodecs/
- https://issues.chromium.org/issues/40230259
