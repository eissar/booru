# Research: headless GPU rendering benchmarks and JS visibility measurement

Status: research only. **No experiment was run.** `static/benchmark.html` was ignored.
Authoritative client behavior: `static/gallery.js`, `static/gallery.css`.

Evidence labels:
- **[V]** validated: the claim was returned by a search that fetched the cited primary URL, with the text quoted or closely paraphrased. The fetch went through a summarizing search tool, not a raw page read.
- **[K]** background knowledge that was not re-verified this session. Treat as a hypothesis and check it.
- **[U]** uncertain, platform-specific or version-dependent, or the source was not retrievable.

Caveat on method: pages were fetched via `google_search` with a `urls` array. Several primary pages were only partly retrievable (see "Gaps"). Anything marked [V] is only as good as that summary. Re-read the primary page before relying on exact wording.

## 1. Current app facts relevant to measurement (from `static/gallery.js`)
- WebGL2 context: `canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true })` (line 148). No `failIfMajorPerformanceCaveat`.
- Each draw queries DOM geometry and style: `getBoundingClientRect` and `getComputedStyle` at lines ~237, 247–248, 266–269. This can force style and layout work on the main thread.
- A `ResizeObserver` triggers rescheduling (line 136). Draw scheduling uses `requestAnimationFrame` (lines 123, 325, 348).
- No `IntersectionObserver`, no timer queries, no `readPixels`, no `finish` in the app.
- Consequence: main-thread DOM-read cost and GPU draw cost are separate. They need separate instruments.

## 2. Headless Chromium on Linux and real GPU verification

### Validated [V]
Source: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/using-gpu-hardware-in-headless-chrome.md
- "Headless Chrome can utilize the local machine's GPU, at least in some circumstances."
- "With headless Chrome, pass the command line argument `--enable-gpu` to disable forcing software rendering. This defers to Chrome's default OpenGL driver autodetection, which on Linux requires that X display is available (i.e. X11 server is available and `DISPLAY` env var is set accordingly)."
- "While the default auto-detection doesn't seem to work without X11, forcing Vulkan backend (`--use-angle=vulkan`) have been found to work at least on some Linux configurations."
- The doc defers container and server details to an external guide ("Server Side Headless Linux Chrome With GPUs"). It has no `/dev/dri` or Docker instructions.

Source: https://chromium.googlesource.com/chromium/src/+/main/docs/gpu/swiftshader.md
- SwiftShader runs purely on the CPU.
- Automatic fallback to SwiftShader for WebGL is deprecated for security reasons. Opt-in is `--enable-unsafe-swiftshader`.
- Flags mentioned in the doc: `--use-gl=angle`, `--use-angle=swiftshader`, `--use-angle=swiftshader-webgl`, `--use-gl=swiftshader`, `--use-gl=swiftshader-webgl`, `--use-vulkan=swiftshader`.

Source: Chromium headless README https://chromium.googlesource.com/chromium/src/+/lkgr/headless/README.md, and https://developer.chrome.com/docs/automation-and-testing/headless-chrome-shell, https://developer.chrome.com/blog/removing-headless-old-from-chrome
- New headless (`--headless`, `--headless=new`, since Chrome 112) shares the browser code with headful Chrome. It creates platform windows but does not display them.
- Old headless was split out as the `chrome-headless-shell` binary. `--headless=old` was removed from the main Chrome binary in Chrome 132.
- `HeadlessExperimental.beginFrame` works only with `chrome-headless-shell`, not with `--headless=new`.

Source: https://chromedevtools.github.io/devtools-protocol/tot/SystemInfo/ (fields as returned by the summary of `SystemInfo.pdl`)
- `SystemInfo.getInfo` returns `gpu: GPUInfo`.
- `GPUInfo`: `devices` (element 0 is the primary GPU), optional `auxAttributes`, optional `featureStatus`, `driverBugWorkarounds`, `videoDecoding`, `videoEncoding`.
- `GPUDevice`: `vendorId`, `deviceId` (0 if unavailable), optional `subSysId` and `revision` (Windows only), `vendorString`, `deviceString`, `driverVendor`, `driverVersion`.
- The earlier draft's `glRenderer` and `glVendor` fields were **not** in this field list. Do not rely on them. Treat the contents of `auxAttributes` and `featureStatus` as build-dependent dictionaries.

### Recommendations
1. **Do not add `failIfMajorPerformanceCaveat` to the measured app context.** It changes context-creation behavior (a software fallback fails instead of running), so the measured app would differ from the real app. If you want a guard, create a separate probe canvas outside the measured page and check it there. [K]
2. **Do not blindly pass `--ignore-gpu-blocklist` or force Vulkan feature flags** (`--enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan`). These alter what users get. The doc evidence only supports `--enable-gpu` and `--use-angle=vulkan` as things "found to work at least on some Linux configurations". Use the minimum set that produces a hardware renderer. Record the flags with the results. Run a "default flags" configuration as a baseline and label forced-flag configurations as a separate scenario.
3. Backend matrix (each a labeled condition, not assumed equivalent): `--use-gl=angle` with `--use-angle=gl`, `gl-egl` or `vulkan` [K for the names `gl`/`gl-egl`; `vulkan` and `swiftshader` are named in the docs [V]]. Use SwiftShader only as a labeled negative control, with `--enable-unsafe-swiftshader`.
4. Verify the renderer **after** the run starts, with passive reads. These do not change app context creation:
   - CDP `SystemInfo.getInfo`: `devices[0]` vendor/device/driver. This describes the browser's GPU view. [V for fields]. A SwiftShader device can be identified via `deviceString` or `driverVendor`. The exact strings are [U].
   - A separate probe page or context that reads `WEBGL_debug_renderer_info` `UNMASKED_RENDERER_WEBGL`. Its output is expected to include an `ANGLE (...)` string with the backend. [K; the SwiftShader format appeared in the earlier search results]. Note some Chrome versions mask the renderer string in privacy modes [U].
   - `chrome://gpu` content, collected from a separate run or tab. [K]
5. Containers [K/U]: `/dev/dri/renderD*` passthrough, group membership (`render`/`video`), NVIDIA runtime and EGL libs. `--no-sandbox` is needed only when the container cannot provide the sandbox's namespaces. Log it as a variable. None of this is covered by the validated Chromium doc.
6. Headed under Xvfb: likely no DRI or hardware GL, so it is not automatically a hardware path [K/U]. Verify with step 4. Treat "headed" as valid only with a real display or verified GPU renderer.

## 3. Timer queries (`EXT_disjoint_timer_query_webgl2`)

### Validated [V]
Sources: https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query_webgl2/ , https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query/ , MDN https://developer.mozilla.org/en-US/docs/Web/API/EXT_disjoint_timer_query
- The WebGL2 extension exposes `TIME_ELAPSED_EXT` (0x88BF), `QUERY_COUNTER_BITS_EXT` (0x8864) and `GPU_DISJOINT_EXT` (0x8FBB). `TIMESTAMP_EXT` (0x8E28) with `queryCounterEXT` belongs to the WebGL1 extension interface. The summary of the WebGL2 spec listed it, so **check the registry page for whether the WebGL2 interface has `queryCounterEXT`**. [U]
- Queries are asynchronous. Results are polled with `QUERY_RESULT_AVAILABLE` and read with `QUERY_RESULT`. `GPU_DISJOINT_EXT` indicates a disjoint event that invalidates timing results.
- The verbatim spec sentence about results only becoming available in a later task or frame was **not retrieved** from the Khronos page by the tool. Operational behavior is consistent with it (widely documented) but the normative wording is unverified. [U]
- Chromium issue https://issues.chromium.org/40779345: the extension has been available in Chrome. The issue text discusses the Spectre-style timer risk and notes the extension is exposed regardless of `#enable-webgl-developer-extensions`. The final resolution and current mitigations (precision clamping, gating) were **not determined**. [U]

### Not verified (do not claim without measuring)
- Chrome's timer granularity, whether results are coarsened, per-query overhead, and availability on each ANGLE backend (GL, EGL, Vulkan). Treat all as unknown.
- Whether `TIME_ELAPSED_EXT` on ANGLE/Vulkan covers the same span as on native GL.
- Whether a trace of GPU events is equivalent to the GPU execution time of one draw. **It is not established, and this document does not claim it.**

### Recommendations
- Feature-detect with `gl.getExtension("EXT_disjoint_timer_query_webgl2")`. Record `getQueryParameter`/`getQuery(TIME_ELAPSED_EXT, QUERY_COUNTER_BITS_EXT)` bits. Mark runs where the extension is absent as "no GPU timing" instead of substituting something else.
- Ring of N queries (e.g. 4–8), one query per measured draw or pass. Do not read results in the same task. Poll on later frames. Check `GPU_DISJOINT_EXT` after resolution and discard disjoint samples, counting them.
- Calibrate: run empty and trivially small queries, and record the set of distinct non-zero durations to estimate the granularity empirically.
- Measure the overhead by A/B: the same scripted scenario with queries off and on, compared on main-thread frame time distributions and trace data. Do not assume it is negligible.
- Be explicit about scope: a timer query brackets GL commands issued between begin and end. Texture uploads (`ImageDecoder` frames to texture arrays) should be inside or outside the bracket on purpose.
- Because the app has one draw per frame over many cards, the query bracket should surround the whole draw function's GL calls. Per-card queries would multiply overhead.

## 4. Fences, `readPixels`, `finish`

### Validated [V]
Source: MDN https://developer.mozilla.org/en-US/docs/Web/API/WebGL2RenderingContext/clientWaitSync , https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices ; Khronos WebGL2 spec https://registry.khronos.org/webgl/specs/latest/2.0/ (retrieval was via MDN snippets; the exact spec paragraph was not located)
- `clientWaitSync(sync, flags, timeout)` waits up to `timeout` nanoseconds. The timeout must not exceed `gl.MAX_CLIENT_WAIT_TIMEOUT_WEBGL` (query it with `getParameter`). Return values: `ALREADY_SIGNALED`, `TIMEOUT_EXPIRED`, `CONDITION_SATISFIED`, `WAIT_FAILED`.
- `SYNC_FLUSH_COMMANDS_BIT` requests a flush before waiting.
- `readPixels` to client memory is a synchronous readback and creates a sync point. Async patterns use `PIXEL_PACK_BUFFER` with fences.

### Uncertain [U]
- Whether `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` is 0 in current Chrome (earlier claim from memory). Read it at runtime and record it.
- What the error is when exceeding the max (`INVALID_OPERATION` vs `INVALID_VALUE`). Not confirmed.
- Whether `gl.finish()` in Chrome waits for real GPU completion or only flushes. The MDN summary says it blocks until commands are complete, but Chrome's multi-process implementation could differ. **Do not use `finish()` as the measurement boundary without verifying.** If used, it perturbs the pipeline (serializes CPU and GPU) so numbers are not representative of real throughput.

### Recommendations
- No `readPixels`, `finish`, or blocking `clientWaitSync` inside timed runs. Use these only in a separate correctness mode (for example a post-run `readPixels` check of the canvas, which verifies the draw output but is not a physical presentation check).
- A fence is a GPU completion signal for commands up to the fence, as seen by the context. It is not a presentation signal and not a compositing signal.

## 5. Frame and presentation tracing

### Validated [V]
- Chromium rendering benchmark doc https://chromium.googlesource.com/chromium/src/+/main/docs/speed/benchmark/harnesses/rendering.md and https://chromium.googlesource.com/chromium/src/+/lkgr/docs/speed/debug-janks.md: `FrameSequenceTracker` tracks sequences such as compositor animations, main-thread animations, pinch zoom, rAF, touch and wheel scrolls. Throughput is `frames_produced / frames_expected` (code excerpt: `100 * data.frames_produced / data.frames_expected`). A dropped frame is a sequence where fewer frames were produced than expected. The doc tells you to look at `FramePresented` sub-events of the `FrameSequenceTracker` event to find when they were dropped.
- Perfetto standard library / Chrome (search results; the `perfetto.dev/docs/data-sources/frametimeline` page is the **Android** FrameTimeline page, not Chrome): `PipelineReporter` (frame stage breakdown), `EventLatency` (input latency), `Commit`; the proto `chrome_frame_reporter.proto` with `ChromeFrameReporter.State` (e.g. `STATE_NO_UPDATE_DESIRED`, `STATE_PRESENTED_ALL`) and `FrameDropReason` (e.g. `REASON_DISPLAY_COMPOSITOR`, `REASON_MAIN_THREAD`); stdlib `chrome_scroll_jank_cause_descriptions`. See https://perfetto.dev/docs/analysis/stdlib-docs and https://perfetto.dev/docs/reference/trace-packet-proto .
- The exact set of Chrome frame tables/views in the current stdlib was **not enumerated**. [U]

### What traces do and do not show
- Trace frame events (`FrameSequenceTracker`, `PipelineReporter`, `FramePresented`) describe compositor and Viz frame production and presentation feedback as reported by Chrome. They are the right tool for dropped frames and which stage (main, compositor, display) dropped.
- **They are not exact per-draw GPU execution time.** A WebGL draw's GPU time is not equivalent to any single trace event. Use timer queries for GPU time and treat them as a distinct, partially verified instrument (section 3).
- **Presentation reported by Chrome is not proof of physical display output.** Neither is a screenshot (a screenshot reads composited output or captured surface, not the scanout). In headless there may be no real display, so "presented" means Chrome's presentation feedback. [K/U]
- rAF callbacks mark main-thread frame starts, are throttled when hidden or occluded, and say nothing about GPU or presentation completion. [K]

### Recommendations
- Capture traces via CDP `Tracing.start`/`Tracing.end` (category selection must be verified against the Chromium version; see https://chromium.googlesource.com/chromium/src/+/main/base/trace_event/builtin_categories.h , not fetched). Analyze with `trace_processor` SQL. Discover available slice names with `SELECT DISTINCT name FROM slice` before writing queries, instead of assuming names.
- Report from traces: dropped/produced frame counts per sequence, and drop reasons if present. Report from JS: main-thread draw time (split by phase). Report from timer queries: GPU time. Keep the three separate and never sum them.
- Measure tracing overhead too: tracing itself changes timing, so take trace runs and non-trace runs and compare. Use the non-trace runs for timing, the trace runs for frame analysis.

## 6. BeginFrame determinism vs realistic throughput
- [V] BeginFrame control exists only in `chrome-headless-shell`, not in `--headless=new`.
- [K/U] It removes vsync and scheduler variability, so it is useful for a deterministic per-frame work comparison, but it does not represent real compositor pacing. Do not present its results as user-visible throughput.
- For realistic throughput use new headless (or headed with a verified GPU) with real input (`Input.synthesizeScrollGesture` or wheel events) so scrolling goes through the compositor. Flags that remove frame-rate limiting (`--disable-frame-rate-limit`, `--disable-gpu-vsync`) are [K] and should be a separate "uncapped" scenario, not the default.

## 7. JS visibility measurement with minimal overhead
Sources: https://web.dev/articles/intersectionobserver-v2 , https://webperf.tips/tip/layout-thrashing/ , MDN IntersectionObserver (found via search; not fetched in this round).
- [V-ish] `getBoundingClientRect` after DOM writes can force synchronous layout; `IntersectionObserver` is asynchronous. IO v2 (`trackVisibility`) adds occlusion detection, which is not needed here.
- [K, verify in the spec https://w3c.github.io/IntersectionObserver/] IO's `root` can be the scrollport `#gallery-main`, and ancestor `overflow` clips are included in the intersection computation. IO reports geometry as of the last rendering update, which may lag a hover transform or a resize that happened since. It does not replace the per-draw geometry the shader needs (actual rect, border radius) unless you cache it.
- Recommendations:
  - Keep the production draw logic as the reference (authoritative per the task). Add instrumentation around it only: `performance.now()` pairs for phases (DOM reads, cull, GL) into a preallocated typed array, flushed after the run.
  - Detect forced layout from traces (`UpdateLayoutTree`/`Layout` slices nested under the draw) instead of guessing.
  - If you evaluate an IO-based visible set, compare it to a ground-truth pass (`getBoundingClientRect` plus ancestor clip) outside the timed window and report mismatches by scenario (hover transform, inspector resize, htmx replacement, masonry/grid/list).

## 8. Experiment design (not executed)
1. **Gate:** record Chromium version, flags, `SystemInfo.getInfo`, probe-context renderer string, `chrome://gpu`. Mark the run invalid if the renderer is software (unless it is the labeled SwiftShader control).
2. **Conditions:** default flags vs minimal GPU flags (`--enable-gpu`, optionally `--use-angle=vulkan` or `gl-egl`) vs SwiftShader control; new headless vs headed (verified) vs `chrome-headless-shell` BeginFrame (deterministic only).
3. **Scenarios** (scripted, identical across conditions): masonry, grid and list; scroll inside `#gallery-main`; inspector resize; hover transforms; htmx append; filter replacement (batch release before the new batch); initial `/mipmap/64` stream with `ImageDecoder` uploads.
4. **Instruments, one concern each:** JS phase timers; timer-query ring (if available); trace frame events; long-task/long-animation-frame observers [K].
5. **Overhead calibration:** off vs marks vs marks+queries vs tracing. Report deltas. Determine timer granularity with empty queries.
6. **Controls:** pinned versions, fixed viewport and DPR, warm caches, GPU clocks and CPU governor noted, >=20 repetitions with warm-up discarded, median/p95/p99.
7. **Correctness:** post-run `readPixels` or screenshot comparison, labeled as a draw-correctness check and not a presentation proof.

## 9. Ranked recommendations
1. Verify the renderer from outside the measured context (CDP `SystemInfo.getInfo` plus a probe context), and invalidate software runs. Do not change the app's context attributes.
2. Use minimal, documented flags (`--enable-gpu`, `--use-angle=vulkan` where needed). Do not force the blocklist bypass or Vulkan feature sets by default. Treat forced flags as a separate labeled condition.
3. Separate instruments for main-thread time, GPU time (timer queries) and frame/presentation (traces). Never equate them and never sum them.
4. Treat timer-query granularity, overhead and per-backend availability as unknown until calibrated.
5. Keep blocking sync (`finish`, `readPixels`, `clientWaitSync` with timeout) out of timed paths. Read `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` at runtime.
6. Use real input and compositor scrolling for throughput. Use BeginFrame (`chrome-headless-shell`) only for deterministic work-cost comparison.
7. Discover trace event and table names from the actual trace before writing analysis.
8. If visibility is optimized, validate any IO-based approach against the existing DOM-query logic.

## 10. Open items / gaps
- Khronos normative text for timer-query result availability and for `queryCounterEXT` in the WebGL2 interface was not retrieved.
- Chrome's current timer-query precision handling (issue 40779345 resolution) not determined.
- WebGL2 spec paragraph on `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` and `finish()` semantics in Chrome not located.
- `cc/metrics/frame_sequence_tracker.h` header comment not retrieved; only the rendering doc and code excerpt were.
- Perfetto's Chrome-specific frame analysis page was not found. The `frametimeline` URL is Android-only.
- Container GPU passthrough and the Xvfb GPU behavior are unverified.
