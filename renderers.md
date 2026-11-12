# Custom Card Renderers Plan

## Problem

1. `src/template/item_card.odin` currently renders every card with `<img src="/image/<oid>" class="gallery-card-image order-1"/>`.
2. `handle_image` in `src/server/handlers.odin` checks for a flat `thumbnails/<oid>.webp` (whereas `src/thumbnail/generate.odin` writes `thumbnails/64/<oid>.webp` and `thumbnails/128/<oid>.webp`) and otherwise falls back to serving the original file (`images/<id>.<ext>`) with its `content_type`. For `.mp4` and other non-image media, `<img>` cannot decode the response.
3. Future media types need custom card renderers—such as `<video>`, spritesheets, and 3D carousels—rather than `<img>`.

## Plan

### 1. Dispatch Card Markup by Media Kind (`src/template/item_card.odin`)

Branch on `image.content_type` (or a media-kind helper) to emit the appropriate element while keeping the shared `gallery-card-image order-1` classes, `style="aspect-ratio: ..."`, and `width`/`height` attributes:

- **Images (`image/*`):** `<img src="/image/<oid>" .../>` (unchanged).
- **Video (`video/*`):** `<video src="/image/<oid>" muted loop playsinline ...></video>` (see video preloading below).
- **Custom renderers (spritesheet, 3D carousel, etc.):** a container such as `<div class="gallery-card-image order-1" data-renderer="..." data-src="/image/<oid>" ...></div>` (or `<canvas>`) initialized on the client.

### 2. Generalize `static/gallery.js` Beyond `HTMLImageElement`

The `#thumbnail-background` WebGL canvas already renders 64px mipmap previews behind cards until the DOM element is ready. `gallery.js` currently assumes every `.gallery-card-image` is an `<img>`:

- **Cache key:** Replace `img.src` in `thumbnailsByURL` with `card.dataset.imageId` (or `el.src || el.dataset.src || card.dataset.imageId`), since `<div>`/`<canvas>` elements have no `.src`.
- **Readiness check:** Replace `img.complete && img.naturalWidth > 0` with a media-type-aware check:
  - `HTMLImageElement`: `el.complete && el.naturalWidth > 0`
  - `HTMLVideoElement`: `el.readyState >= 2 && el.videoWidth > 0`
  - Custom renderers: `el.dataset.ready === "1"` (set once the first frame is painted)
- **Redraw triggers:** In addition to `load` on `HTMLImageElement`, call `schedule()` on `loadeddata` for `<video>` and on a custom event (e.g. `media:ready`) for custom renderers.
- **Aspect ratio:** Keep `width` and `height` attributes (or `data-width`/`data-height` fallback) on non-`<img>` elements so the WebGL mipmap `contentW`/`contentH` math continues to work.

### 3. Preserve the Transparency Handoff (`static/gallery.css`)

`.gallery-previews-active .gallery-card-image` sets `background-color: transparent` so the 64px WebGL mipmap shows through while loading. Custom renderers must keep their container transparent until their first frame is ready, then mark `data-ready="1"` and trigger a redraw.

### 4. Video Preloading & HTTP `Range` Support

- `preload="metadata"` only fetches container metadata (`readyState === 1` / `HAVE_METADATA`) and does not guarantee decoding or painting a frame (`readyState >= 2`); browsers often leave it blank until playback starts.
- **Lightweight idle cards:** Use `preload="none"` with `poster="/thumbnail/128/<oid>"` (backed by the already-generated `thumbnails/128/<oid>.webp` via a dedicated thumbnail route) and load/play on hover or click.
- **Autoplay/looping cards:** Use `preload="auto"` / `autoplay muted loop playsinline` gated by `IntersectionObserver` so off-screen cards do not hold active decoders.
- **Server `Range` (`206 Partial Content`) support:** `handle_image` in `src/server/handlers.odin` currently reads the full file with `os.read_entire_file` and returns `200 OK`. Adding `Range` support (`PartialContent` is already defined in `src/http/types.odin`) is required for seeking and for `preload="metadata"` to avoid downloading entire videos upfront.

### 5. Inspector (`src/template/inspector.odin`)

The inspector also renders `<img src="/image/<oid>">`. Update it to render `<video controls src="/image/<oid>">` (or the appropriate custom renderer) for non-image media types.
