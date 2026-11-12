// Masonry layout: one dispatcher, one policy.
//
// Packing depends on the cards, view, column count and measured geometry.
// The same inputs produce the same columns regardless of the events that led here.
//
// Packed columns then render only the cards near the viewport: the rest stay
// in place with display: none, and column padding stands in for their height.

(function () {
  var syncQueued = false;
  var lastSyncKey = null;
  // The current masonry columns as packed by syncMasonry:
  // { el, cards, ratios, first, last }, where el holds cards[first..last].
  var packedColumns = [];
  // Hidden element in the grid that holds every card outside its column range.
  var parking = null;
  var anchorCard = null, anchorOffset = 0;
  var nearbyQueued = false;
  // Resize can change packing or just the visible range.
  var portSize = new ResizeObserver(function () {
    syncMasonry();
    draw();
  });
  var observedPort = null;

  function getGrid() {
    return document.getElementById("photo-grid");
  }

  function getCurrentView() {
    var checked = document.querySelector('input[name="gallery-view"]:checked');
    return checked instanceof HTMLInputElement ? checked.value : "masonry";
  }

  function insertBeforePagination(grid, el) {
    var pagination = grid.querySelector("#pagination-controls");
    if (pagination) grid.insertBefore(el, pagination);
    else grid.appendChild(el);
  }

  function cardRatio(card) {
    var img = card.querySelector("img[width][height]");
    if (!img) return 1;
    var w = Number(img.getAttribute("width"));
    var h = Number(img.getAttribute("height"));
    if (w <= 0 || h <= 0) return 1;
    return Math.min(Math.max(h / w, 0.5), 2.0);
  }

  function cardOrder(card) {
    var raw = card.getAttribute("data-render-order-id");
    var order = raw == null ? NaN : Number(raw);
    return Number.isFinite(order) ? order : Number.POSITIVE_INFINITY;
  }

  // collectCards returns every card in canonical render-order sequence,
  // wherever packing left them in the DOM.
  function collectCards(grid) {
    var cards = Array.from(grid.querySelectorAll(".masonry-item"));
    cards.sort(function (a, b) {
      return cardOrder(a) - cardOrder(b);
    });
    return cards;
  }

  function columnCount(grid) {
    var parsed = Number.parseInt(
      getComputedStyle(grid).getPropertyValue("--masonry-columns"),
      10,
    );
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
  }

  // Packing also depends on column width and the space between image tops.
  function buildSyncKey(view, columns, cards, geometry) {
    var parts = [];
    for (var i = 0; i < cards.length; i++) {
      parts.push(cardOrder(cards[i]) + ":" + cards[i].getAttribute("data-image-id") +
        ":" + cardRatio(cards[i]));
    }
    if (geometry) parts.push(geometry.width + ":" + geometry.gap);
    return view + "|" + columns + "|" + parts.join(",");
  }

  function packedColumnsMatch(grid, columns) {
    return grid.querySelectorAll(":scope > .masonry-column").length === columns;
  }

  function syncMasonry() {
    var grid = getGrid();
    if (!grid) return;

    var view = getCurrentView();
    var columns = view === "masonry" ? columnCount(grid) : 0;
    var cards = collectCards(grid);
    var port = grid.closest(".main-content");
    if (port !== observedPort) {
      portSize.disconnect();
      if (port) portSize.observe(port);
      observedPort = port;
    }

    var geometry = null;
    if (columns > 0) geometry = measureMasonry(grid);

    var key = buildSyncKey(view, columns, cards, geometry);
    if (key === lastSyncKey && packedColumnsMatch(grid, columns)) {
      if (geometry) showAroundAnchor(geometry);
      return;
    }
    lastSyncKey = key;

    packedColumns = [];
    var packed = Array.from(grid.querySelectorAll(":scope > .masonry-column"));

    // Grid/list views render flat cards in canonical order.
    if (columns === 0) {
      for (var i = 0; i < cards.length; i++) insertBeforePagination(grid, cards[i]);
      for (var i = 0; i < packed.length; i++) packed[i].remove();
      if (parking) parking.remove();
      return;
    }

    // Masonry parks each card not parked yet (visible cards in the old
    // columns, new flat cards); showNearbyCards brings the nearby ones back.
    if (!parking || parking.parentNode !== grid) {
      parking = document.createElement("div");
      parking.style.display = "none";
    }
    insertBeforePagination(grid, parking);
    var heights = [];
    for (var i = 0; i < columns; i++) {
      var col = document.createElement("div");
      col.className = "masonry-column";
      insertBeforePagination(grid, col);
      packedColumns.push({ el: col, cards: [], ratios: [], first: 0, last: -1 });
      heights.push(0);
    }
    for (var i = 0; i < cards.length; i++) {
      var shortest = 0;
      for (var j = 1; j < columns; j++) {
        if (heights[j] < heights[shortest]) shortest = j;
      }
      var ratio = cardRatio(cards[i]);
      var col = packedColumns[shortest];
      // Unmeasured: no range to render, so show the whole column.
      if (!geometry) {
        col.el.appendChild(cards[i]);
        col.last++;
      } else if (cards[i].parentNode !== parking) parking.appendChild(cards[i]);
      col.cards.push(cards[i]);
      col.ratios.push(ratio);
      if (geometry) {
        heights[shortest] += geometry.width * ratio + geometry.gap;
      } else {
        heights[shortest] += ratio;
      }
    }
    for (var i = 0; i < packed.length; i++) packed[i].remove();
    if (geometry) showAroundAnchor(geometry);
  }

  // Renders around the anchor's predicted top, then scrolls it back to its
  // offset. The anchor comes from the last showNearbyCards: by now a resize
  // has already laid out stale columns. Assign scrollTop outright, since
  // browser scroll anchoring may have adjusted it too.
  function showAroundAnchor(geometry) {
    var visibleTop = geometry.visibleTop, anchored = false;
    for (var c = 0; anchorCard && c < packedColumns.length; c++) {
      var col = packedColumns[c], index = col.cards.indexOf(anchorCard);
      if (index < 0) continue;
      var y = 0;
      for (var i = 0; i < index; i++) {
        y += geometry.width * col.ratios[i] + geometry.gap;
      }
      geometry.visibleTop = y - anchorOffset;
      anchored = true;
    }
    showNearbyCards(geometry);
    if (anchored) {
      geometry.port.scrollTop = geometry.scrollTop + geometry.visibleTop - visibleTop;
    }
  }

  /**
   * @typedef {Object} Geometry
   * @property {HTMLElement} port - Gallery scroll container.
   * @property {number} scrollTop - Scroll offset in pixels.
   * @property {number} visibleTop - Viewport top relative to the grid, in pixels.
   * @property {number} height - Scrollport height in pixels.
   * @property {number} width - Column width in pixels.
   * @property {number} gap - Metadata slot and inter-card gap in pixels.
   */

  // Reads what showNearbyCards needs. Callers measure before writing to the
  // DOM, so the browser never lays out collapsed columns and clamps scrollTop.
  /** @returns {Geometry|null} */
  function measureMasonry(grid) {
    var port = grid.closest(".main-content");
    if (!port) return null;
    var slot = grid.querySelector(":scope > .masonry-item .gallery-card-slot, :scope > .masonry-column .gallery-card-slot");
    if (!slot) return null;
    var style = getComputedStyle(grid);
    var height = slot.getBoundingClientRect().height;
    if (!height) return null;
    return {
      port: port,
      scrollTop: port.scrollTop,
      visibleTop: port.getBoundingClientRect().top + port.clientTop -
        grid.getBoundingClientRect().top,
      height: port.clientHeight,
      width: parseFloat(style.gridTemplateColumns),
      gap: height + parseFloat(style.rowGap),
    };
  }

  // Renders the cards within one viewport of the visible area. A card's height
  // is its image (column width × ratio) plus metadata and gap. Also records
  // the anchor: the highest card whose top is in the viewport.
  function showNearbyCards(geometry) {
    anchorCard = null;
    for (var c = 0; c < packedColumns.length; c++) {
      var col = packedColumns[c], y = 0, start = -1, end = 0, a = -1, b = -2;
      for (var i = 0; i < col.cards.length; i++) {
        var h = geometry.width * col.ratios[i] + geometry.gap;
        var near = y < geometry.visibleTop + 2 * geometry.height &&
          y + h > geometry.visibleTop - geometry.height;
        if (near && start < 0) start = y;
        if (near && a < 0) a = i;
        if (near) end = y + h, b = i;
        var offset = y - geometry.visibleTop;
        if (offset >= 0 && offset < geometry.height &&
            (!anchorCard || offset < anchorOffset)) {
          anchorCard = col.cards[i];
          anchorOffset = offset;
        }
        y += h;
      }
      // Move only the cards leaving or entering the column's range.
      for (var i = col.first; i <= col.last; i++) {
        if (i < a || i > b) parking.appendChild(col.cards[i]);
      }
      if (col.first > col.last || b < col.first || a > col.last) {
        col.el.append.apply(col.el, col.cards.slice(a, b + 1));
      } else {
        if (a < col.first) col.el.prepend.apply(col.el, col.cards.slice(a, col.first));
        if (b > col.last) col.el.append.apply(col.el, col.cards.slice(col.last + 1, b + 1));
      }
      col.first = a;
      col.last = b;
      var height = y;
      col.el.style.paddingTop = (start < 0 ? height : start) + "px";
      col.el.style.paddingBottom = (start < 0 ? 0 : height - end) + "px";
    }
  }

  // The single dispatcher: coalesce all triggers into one animation frame.
  function scheduleMasonrySync() {
    if (syncQueued) return;
    syncQueued = true;
    requestAnimationFrame(function () {
      syncQueued = false;
      syncMasonry();
      draw();
    });
  }

  // One current mipmap batch. No image-ID cache or cross-batch reuse.
  let canvas, gl, program, uniforms, batch;
  const thumbnailsByURL = new Map();
  const PAGE_LAYERS = 64;
  const MAX_PAGES = 8;
  const ringPages = [];
  let ringCursor = 0;
  let pending = false,
    batchQueued = false,
    animateUntil = 0;
  const endpoint = "/mipmap/64";
  const imageSizes = new ResizeObserver(() => draw());
  let previewSurface, stripTop = null, stripHeight = 0;
  let diagnosticsEnabled = false;
  const paintedPreviews = new Map();
  let rendererState = "starting", rendererError = null;

  let previewLogSequence = 0;
  let lastBacking = null;
  function previewLog(event, details = {}) {
    const record = {
      seq: ++previewLogSequence,
      ms: Math.round(performance.now()),
      event,
      state: rendererState,
      contextLost: gl ? gl.isContextLost() : null,
      backing: canvas ? [canvas.width, canvas.height] : null,
      dpr: devicePixelRatio || 1,
      images: batch?.images.length || 0,
      textures: ringPages.filter(Boolean).length,
      ...details,
    };
    console.info("[booru-webgl] " + JSON.stringify(record));
  }

  function failPreview(error) {
    previewLog("failure", {
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : null,
      lastBacking,
    });
    rendererState = "failed";
    rendererError = error instanceof Error ? error.message : String(error);
    document.documentElement.classList.remove("gallery-previews-active");
    console.error("[booru-webgl] Mipmap preview:", error);
  }

  // The strip lives in content coordinates. Scrolling moves its existing pixels
  // with the cards; JS only rebases when less than one viewport of buffer remains.
  function positionPreviewStrip() {
    const grid = getGrid();
    const scrollport = grid?.closest(".main-content");
    if (!grid || !scrollport) return null;
    if (!previewSurface || previewSurface.parentElement !== grid) {
      previewSurface?.remove();
      previewSurface = document.createElement("div");
      previewSurface.className = "gallery-preview-surface";
      previewSurface.appendChild(canvas);
      grid.appendChild(previewSurface);
      stripTop = null;
    }
    const gridRect = grid.getBoundingClientRect();
    const portRect = scrollport.getBoundingClientRect();
    const h = scrollport.clientHeight;
    const visibleTop = portRect.top + scrollport.clientTop - gridRect.top;
    if (stripTop === null || stripHeight !== h * 7 ||
        visibleTop < stripTop + h || visibleTop + h > stripTop + stripHeight - h) {
      stripTop = visibleTop - h * 3;
      stripHeight = h * 7;
    }
    canvas.style.top = `${stripTop}px`;
    canvas.style.height = `${stripHeight}px`;
    return { left: gridRect.left, top: gridRect.top + stripTop,
      width: grid.clientWidth, height: stripHeight };
  }

  function scrollPreview() {
    if (!uniforms) return;
    const grid = getGrid();
    const scrollport = grid?.closest(".main-content");
    if (!grid || !scrollport) return;
    const visibleTop = scrollport.getBoundingClientRect().top +
      scrollport.clientTop - grid.getBoundingClientRect().top;
    const h = scrollport.clientHeight;
    if (stripTop === null || stripHeight !== h * 7 ||
        visibleTop < stripTop + h || visibleTop + h > stripTop + stripHeight - h)
      schedule();
  }

  function shader(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS))
      throw Error(gl.getShaderInfoLog(shader));
    return shader;
  }

  function init() {
    gl = canvas.getContext("webgl2", {
      alpha: true, premultipliedAlpha: true, antialias: false, depth: false,
    });
    if (!gl) throw Error("WebGL2 unavailable");
    const rendererInfo = gl.getExtension("WEBGL_debug_renderer_info");
    previewLog("context-created", {
      attributes: gl.getContextAttributes(),
      version: gl.getParameter(gl.VERSION),
      renderer: gl.getParameter(rendererInfo ? rendererInfo.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
      vendor: gl.getParameter(rendererInfo ? rendererInfo.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
      maxViewport: Array.from(gl.getParameter(gl.MAX_VIEWPORT_DIMS) || []),
      maxRenderbuffer: gl.getParameter(gl.MAX_RENDERBUFFER_SIZE),
      maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE),
      maxArrayLayers: gl.getParameter(gl.MAX_ARRAY_TEXTURE_LAYERS),
    });
    const vs = shader(
      gl.VERTEX_SHADER,
      `#version 300 es
    uniform vec2 screen;
    uniform vec4 rect;
    out vec2 uv;
    out vec2 position;
    void main() {
      vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
      uv = p;
      position = rect.xy + p * rect.zw;
      gl_Position = vec4(position.x / screen.x * 2. - 1., 1. - position.y / screen.y * 2., 0, 1);
    }`,
    );
    const fs = shader(
      gl.FRAGMENT_SHADER,
      `#version 300 es
    precision highp float;
    uniform highp sampler2DArray tex;
    uniform int layer;
    uniform vec4 source;
    uniform vec4 clipRect;
    uniform vec4 cardRect;
    uniform float radius;
    in vec2 uv;
    in vec2 position;
    out vec4 color;
    void main() {
      if (any(lessThan(uv, vec2(0))) || any(greaterThan(uv, vec2(1)))) discard;
      if (any(lessThan(position, clipRect.xy)) || any(greaterThan(position, clipRect.zw))) discard;
      vec2 halfSize = cardRect.zw * .5;
      vec2 q = abs(position - cardRect.xy - halfSize) - halfSize + radius;
      float distance = length(max(q, 0.)) + min(max(q.x, q.y), 0.) - radius;
      float coverage = 1. - smoothstep(-.5, .5, distance);
      color = texture(tex, vec3(source.xy + uv * source.zw, float(layer)));
      color.a *= coverage;
      color.rgb *= color.a;
    }`,
    );
    program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS))
      throw Error(gl.getProgramInfoLog(program));
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    gl.useProgram(program);
    gl.bindVertexArray(gl.createVertexArray());
    gl.uniform1i(gl.getUniformLocation(program, "tex"), 0);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    return Object.fromEntries(
      [
        "screen",
        "rect",
        "source",
        "clipRect",
        "cardRect",
        "radius",
        "layer",
      ].map((name) => [name, gl.getUniformLocation(program, name)]),
    );
  }

  function draw() {
    if (!uniforms || rendererState === "failed") return;
    if (gl.isContextLost()) {
      failPreview(Error("WebGL context lost; reload the page to retry"));
      return;
    }
    if (diagnosticsEnabled) paintedPreviews.clear();
    const images = batch ? batch.images : [];
    const strip = positionPreviewStrip();
    if (!strip || !strip.width || !strip.height) return;
    const w = strip.width,
      h = strip.height;
    // Seven viewport heights can exceed the GPU's maximum backing-store size.
    // Preserve the CSS coverage and lower resolution rather than truncate it.
    const viewportLimit = gl.getParameter(gl.MAX_VIEWPORT_DIMS);
    const backingLimit = gl.getParameter(gl.MAX_RENDERBUFFER_SIZE);
    if (!viewportLimit || !backingLimit) {
      failPreview(Error("WebGL drawing limits unavailable; context may be lost"));
      return;
    }
    // Low-resolution previews do not need display-resolution backing pixels.
    const previewScale = 0.5;
    const dpr = Math.min(previewScale,
      viewportLimit[0] / w, viewportLimit[1] / h,
      backingLimit / w, backingLimit / h);
    const width = Math.max(1, Math.floor(w * dpr)),
      height = Math.max(1, Math.floor(h * dpr));
    if (canvas.width !== width || canvas.height !== height) {
      lastBacking = {
        css: [w, h], requestedDpr: previewScale, effectiveDpr: dpr,
        pixels: [width, height], rgbaMiB: +(width * height * 4 / 1048576).toFixed(2),
        maxViewport: Array.from(viewportLimit), maxRenderbuffer: backingLimit,
      };
      previewLog("backing-resize", lastBacking);
      canvas.width = width;
      canvas.height = height;
      if (gl.isContextLost()) {
        failPreview(Error("WebGL context lost during canvas resize"));
        return;
      }
    }
    gl.viewport(0, 0, width, height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program);
    gl.uniform2f(uniforms.screen, w, h);
    for (let i = 0; i < images.length; i++) {
      const img = images[i],
        thumb = thumbnailsByURL.get(img.src);
      if (!thumb || !img.isConnected ||
          (img.complete && img.naturalWidth > 0)) continue;
      const rect = img.getBoundingClientRect(); // Includes the actual CSS hover transform.
      if (!rect.width || !rect.height ||
          rect.bottom <= strip.top || rect.top >= strip.top + h)
        continue;
      let left = strip.left,
        top = strip.top,
        right = strip.left + w,
        bottom = strip.top + h;
      let insideGrid = true;
      // Respect the real scrollport and all overflow-clipping ancestors, not
      // just the window. clientWidth excludes the scrollbars.
      for (let node = img.parentElement; node; node = node.parentElement) {
        const css = getComputedStyle(node),
          box = node.getBoundingClientRect();
        if (css.overflowX !== "visible") {
          left = Math.max(left, box.left + node.clientLeft);
          right = Math.min(
            right,
            box.left + node.clientLeft + node.clientWidth,
          );
        }
        // Outer scrollport clipping is performed by the browser, not baked into
        // the bitmap: offscreen previews must already exist before scrolling.
        if (insideGrid && css.overflowY !== "visible") {
          top = Math.max(top, box.top + node.clientTop);
          bottom = Math.min(
            bottom,
            box.top + node.clientTop + node.clientHeight,
          );
        }
        if (node.id === "photo-grid") insideGrid = false;
      }
      if (right <= left || bottom <= top) continue;
      const card = img.closest(".gallery-card"),
        cardRect = card.getBoundingClientRect();
      const radius =
        parseFloat(getComputedStyle(card).borderTopLeftRadius) || 0;
      const css = getComputedStyle(img);
      // The decoded animation canvas is square; each thumbnail's content starts
      // at (0,0). Match WebPPictureRescale's rounded aspect-preserving dimensions.
      const originalW = Number(img.getAttribute("width")) || 1;
      const originalH = Number(img.getAttribute("height")) || 1;
      const edge = thumb.width;
      const contentW =
        originalW >= originalH
          ? edge
          : Math.max(1, Math.floor((edge * originalW) / originalH + 0.5));
      const contentH =
        originalH >= originalW
          ? edge
          : Math.max(1, Math.floor((edge * originalH) / originalW + 0.5));
      let sx = 0,
        sy = 0,
        sw = contentW,
        sh = contentH;
      if (css.objectFit === "cover") {
        const ratio = rect.width / rect.height,
          originalRatio = originalW / originalH;
        if (ratio > originalRatio) {
          sh *= originalRatio / ratio;
          sy = (contentH - sh) / 2;
        } else {
          sw *= ratio / originalRatio;
          sx = (contentW - sw) / 2;
        }
      }
      // Clamp to texel centers so filtering doesn't pull in the padded canvas.
      gl.uniform4f(
        uniforms.source,
        (sx + 0.5) / thumb.width,
        (sy + 0.5) / thumb.height,
        Math.max(0, sw - 1) / thumb.width,
        Math.max(0, sh - 1) / thumb.height,
      );
      gl.uniform4f(uniforms.rect,
        rect.left - strip.left, rect.top - strip.top, rect.width, rect.height);
      gl.uniform4f(uniforms.clipRect,
        left - strip.left, top - strip.top, right - strip.left, bottom - strip.top);
      gl.uniform4f(
        uniforms.cardRect,
        cardRect.left - strip.left,
        cardRect.top - strip.top,
        cardRect.width,
        cardRect.height,
      );
      gl.uniform1f(uniforms.radius, radius);
      gl.bindTexture(gl.TEXTURE_2D_ARRAY, thumb.texture);
      gl.uniform1i(uniforms.layer, thumb.layer);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (diagnosticsEnabled) paintedPreviews.set(img, {
        left: Math.max(rect.left, left) - strip.left,
        top: Math.max(rect.top, top) - strip.top,
        right: Math.min(rect.right, right) - strip.left,
        bottom: Math.min(rect.bottom, bottom) - strip.top,
      });
    }
    if (rendererState === "starting") rendererState = "active";
  }

  function schedule() {
    if (pending || !uniforms || rendererState === "failed") return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      draw();
      if (performance.now() < animateUntil) schedule();
    });
  }

  function transitionDraw() {
    animateUntil = performance.now() + 400;
    schedule();
  }

  function releaseBatch() {
    if (!batch) return;
    previewLog("batch-release");
    batch.abort.abort();
    batch.decoder?.close();
    for (const url of batch.requestedUrls) {
      if (!thumbnailsByURL.get(url)) thumbnailsByURL.delete(url);
    }
    batch = null;
  }

  function requestBatch() {
    if (batchQueued || !uniforms || rendererState === "failed") return;
    batchQueued = true;
    requestAnimationFrame(() => {
      batchQueued = false;
      if (rendererState === "failed") return;
      releaseBatch();
      imageSizes.disconnect();
      const grid = getGrid();
      const cards = grid ? collectCards(grid) : [];
      const current = (batch = {
        images: cards.map((card) => card.querySelector(".gallery-card-image")),
        requestedUrls: [],
        abort: new AbortController(),
        decoder: null,
      });
      previewLog("batch-start");
      for (const img of current.images) imageSizes.observe(img);
      draw();
      // Capture request order before masonry or another response changes the DOM.
      const ids = [], urls = [];
      for (const card of cards) {
        const url = card.querySelector(".gallery-card-image").src;
        if (thumbnailsByURL.has(url)) continue;
        thumbnailsByURL.set(url, null);
        ids.push(card.dataset.imageId);
        urls.push(url);
      }
      current.requestedUrls = urls;
      if (!ids.length) return;
      loadBatch(current, ids, urls)
        .catch((error) => {
          for (const url of urls)
            if (!thumbnailsByURL.get(url)) thumbnailsByURL.delete(url);
          if (current.abort.signal.aborted) return;
          failPreview(error);
        })
        .finally(() => current.decoder?.close());
    });
  }

  async function loadBatch(current, ids, urls) {
    // Same URL as the <link rel="preload"> in the page head, so the first
    // batch reuses that request. Keep the request mode and cache defaults.
    const response = await fetch(endpoint + "?ids=" + ids.join(","), {
      priority: "high",
      signal: current.abort.signal,
    });
    if (!response.ok || !response.body)
      throw Error(`Mipmap HTTP ${response.status}`);
    if (current.abort.signal.aborted) return;
    const decoder = (current.decoder = new ImageDecoder({
      data: response.body,
      type: "image/webp",
      preferAnimation: true,
    }));
    let streamError;
    const completed = decoder.completed.catch((error) => {
      streamError = error;
    });
    await decoder.tracks.ready;
    if (current.abort.signal.aborted) return;
    if (!decoder.tracks.selectedTrack) throw Error("No image track");
    let count = 0,
      width,
      height;
    for (let i = 0; ; i++) {
      if (streamError) throw streamError;
      if (decoder.complete && i >= decoder.tracks.selectedTrack.frameCount)
        break;
      let image;
      try {
        ({ image } = await decoder.decode({
          frameIndex: i,
          completeFramesOnly: true,
        }));
      } catch (error) {
        if (
          error instanceof RangeError &&
          decoder.complete &&
          i >= decoder.tracks.selectedTrack.frameCount
        )
          break;
        throw error;
      }
      try {
        if (current.abort.signal.aborted) return;
        if (i >= ids.length) throw Error("Too many frames in response");
        if (!i) {
          width = image.displayWidth;
          height = image.displayHeight;
        }
        if (image.displayWidth !== width || image.displayHeight !== height)
          throw Error("Unequal frame sizes");
        const slot = ringCursor++ % (MAX_PAGES * PAGE_LAYERS);
        const pageIdx = Math.floor(slot / PAGE_LAYERS);
        const layer = slot % PAGE_LAYERS;
        let page = ringPages[pageIdx];
        if (page && (page.width !== width || page.height !== height)) {
          for (const oldUrl of page.urls) if (oldUrl) thumbnailsByURL.delete(oldUrl);
          gl.deleteTexture(page.texture);
          page = ringPages[pageIdx] = null;
        }
        if (!page) {
          const texture = gl.createTexture();
          if (!texture) throw Error("Texture allocation failed");
          previewLog("texture-allocate", {
            index: pageIdx, width, height, layers: PAGE_LAYERS,
            rgbaMiB: +(width * height * PAGE_LAYERS * 4 / 1048576).toFixed(2),
          });
          gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
          // LINEAR uses only level zero; generating unused mip levels adds no value here.
          gl.texStorage3D(
            gl.TEXTURE_2D_ARRAY,
            1,
            gl.RGBA8,
            width,
            height,
            PAGE_LAYERS,
          );
          const allocationError = gl.getError();
          if (allocationError !== gl.NO_ERROR) {
            previewLog("texture-allocation-error", { code: `0x${allocationError.toString(16)}` });
            throw Error(`WebGL texture allocation failed: 0x${allocationError.toString(16)}`);
          }
          gl.texParameteri(
            gl.TEXTURE_2D_ARRAY,
            gl.TEXTURE_MIN_FILTER,
            gl.LINEAR,
          );
          gl.texParameteri(
            gl.TEXTURE_2D_ARRAY,
            gl.TEXTURE_MAG_FILTER,
            gl.LINEAR,
          );
          gl.texParameteri(
            gl.TEXTURE_2D_ARRAY,
            gl.TEXTURE_WRAP_S,
            gl.CLAMP_TO_EDGE,
          );
          gl.texParameteri(
            gl.TEXTURE_2D_ARRAY,
            gl.TEXTURE_WRAP_T,
            gl.CLAMP_TO_EDGE,
          );
          page = ringPages[pageIdx] = {
            texture,
            width,
            height,
            urls: new Array(PAGE_LAYERS).fill(null),
          };
        } else if (page.urls[layer]) {
          thumbnailsByURL.delete(page.urls[layer]);
        }
        const texture = page.texture;
        page.urls[layer] = urls[i];
        gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
        gl.texSubImage3D(
          gl.TEXTURE_2D_ARRAY,
          0,
          0,
          0,
          layer,
          width,
          height,
          1,
          gl.RGBA,
          gl.UNSIGNED_BYTE,
          image,
        );
        const error = gl.getError();
        if (error !== gl.NO_ERROR)
          throw Error(`WebGL error 0x${error.toString(16)}`);
        thumbnailsByURL.set(urls[i], { texture, layer, width, height });
        count++;
        schedule();
      } finally {
        image.close();
      }
    }
    await completed;
    if (streamError) throw streamError;
    if (count !== ids.length)
      throw Error(`Expected ${ids.length} frames, received ${count}`);
    previewLog("batch-complete", { frames: count });
  }

  // Read-only diagnostics for benchmark.html. No observers or work unless called.
  globalThis.booruPreviewSnapshot = () => {
    if (!diagnosticsEnabled) {
      diagnosticsEnabled = true;
      schedule(); // Populate draw records even when the gallery is idle.
    }
    if (gl?.isContextLost() && rendererState !== "failed") {
      rendererState = "failed";
      rendererError = "WebGL context lost";
    }
    return {
      state: rendererState,
      error: rendererError,
      active: rendererState === "active" && !!uniforms && !gl.isContextLost() &&
        document.documentElement.classList.contains("gallery-previews-active"),
      canvas: canvas?.isConnected ? canvas : null,
      images: batch ? batch.images.map((image, i) => ({
        image, ready: !!thumbnailsByURL.get(image.src), painted: paintedPreviews.get(image) || null,
      })) : [],
    };
  };

  // Only gallery responses replace the batch. Inspector requests, scrolling,
  // and view changes must not start another download.
  document.addEventListener("htmx:afterSwap", (event) => {
    const url = event.detail.xhr?.responseURL;
    if (!url) return;
    const path = new URL(url, location.href).pathname;
    if (path === "/fragment/items" || path === "/fragment/gallery-content")
      requestBatch();
  });

  document.addEventListener("load", (event) => {
    if (event.target instanceof HTMLImageElement &&
        event.target.classList.contains("gallery-card-image")) {
      schedule();
    }
  }, true);

  document.addEventListener("scroll", scrollPreview, true);
  for (const event of ["pointerover", "pointerout", "transitionrun"]) {
    document.addEventListener(event, transitionDraw);
  }

  document.addEventListener("DOMContentLoaded", async () => {
    canvas = document.getElementById("thumbnail-background");
    try {
      if (!canvas) throw Error("Missing #thumbnail-background canvas");
      previewLog("startup", {
        userAgent: navigator.userAgent, secureContext: globalThis.isSecureContext,
        imageDecoder: !!globalThis.ImageDecoder,
        viewport: [innerWidth, innerHeight], visibility: document.visibilityState,
      });
      canvas.addEventListener("webglcontextcreationerror", event => {
        previewLog("context-creation-error", { message: event.statusMessage });
      });
      canvas.addEventListener("webglcontextlost", event => {
        previewLog("context-lost", { message: event.statusMessage, lastBacking });
        failPreview(Error("WebGL context lost; reload the page to retry"));
      });
      if (!globalThis.isSecureContext)
        throw Error("ImageDecoder requires HTTPS or localhost; this page is not a secure context");
      if (!globalThis.ImageDecoder)
        throw Error("ImageDecoder is unavailable in this browser; use a supported Chromium browser");
      if (!(await ImageDecoder.isTypeSupported("image/webp")))
        throw Error("This browser's ImageDecoder does not support image/webp");
      uniforms = init();
      document.documentElement.classList.add("gallery-previews-active");
      requestBatch();
    } catch (error) {
      failPreview(error);
    }
  });

  // Triggers. Each one is dumb: it only requests a sync.
  document.addEventListener("htmx:afterSettle", scheduleMasonrySync);

  // Scrolling only changes which packed cards are near the viewport.
  document.addEventListener("scroll", function (event) {
    var grid = getGrid();
    if (nearbyQueued || !packedColumns.length || !grid ||
        event.target !== grid.closest(".main-content")) return;
    nearbyQueued = true;
    requestAnimationFrame(function () {
      nearbyQueued = false;
      var geometry = getGrid() && measureMasonry(getGrid());
      if (geometry) showNearbyCards(geometry);
    });
  }, true);

  document.addEventListener("DOMContentLoaded", function () {
    var requestedView = new URLSearchParams(window.location.search).get("view");
    if (
      requestedView === "masonry" ||
      requestedView === "grid" ||
      requestedView === "list"
    ) {
      var selected = document.getElementById("gallery-view-" + requestedView);
      if (selected instanceof HTMLInputElement) selected.checked = true;
    }

    var viewInputs = document.querySelectorAll('input[name="gallery-view"]');
    for (var i = 0; i < viewInputs.length; i++) {
      viewInputs[i].addEventListener("change", function (event) {
        var input = event.target;
        if (!(input instanceof HTMLInputElement) || !input.checked) return;
        var nextUrl = new URL(window.location.href);
        nextUrl.searchParams.set("view", input.value);
        window.history.replaceState(null, "", nextUrl);
        scheduleMasonrySync();
      });
    }

    scheduleMasonrySync();
  });
})();

(function () {
  var savedTheme = localStorage.getItem("theme");
  var isDarkMode = savedTheme
    ? savedTheme === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.setAttribute(
    "data-theme",
    isDarkMode ? "dark" : "light",
  );
  document.addEventListener("DOMContentLoaded", function () {
    var toggle = document.getElementById("dark-mode-toggle");
    if (toggle) {
      toggle.addEventListener("click", function () {
        var currentTheme = document.documentElement.getAttribute("data-theme");
        var newTheme = currentTheme === "dark" ? "light" : "dark";
        document.documentElement.setAttribute("data-theme", newTheme);
        localStorage.setItem("theme", newTheme);
      });
    }
  });
})();

(function () {
  globalThis.booruToggleInspector = function (forceOpen) {
    var main = document.getElementById("gallery-main");
    if (!main) return;
    var state = main.classList.toggle("inspector-open", forceOpen);
    localStorage.setItem("inspector-open", String(state));
  };

  // booruShowLocalToast appends a client-side toast to #toasts-log, cloned
  // from #toast-template. level is a booru-toast-[level] modifier
  // ("success", "error"); omit it for the default style.
  globalThis.booruShowLocalToast = function (message, level) {
    var template = document.getElementById("toast-template");
    var log = document.getElementById("toasts-log");
    if (!(template instanceof HTMLTemplateElement) || !log) return;
    var fragment = template.content.cloneNode(true);
    var toast = fragment.querySelector(".booru-toast");
    if (level) toast.classList.add("booru-toast-" + level);
    fragment.querySelector(".toast-message").textContent = message;
    fragment.querySelector(".booru-toast-dismiss").addEventListener("click", function () {
      toast.remove();
    });
    log.appendChild(fragment);
  };
})();

document.addEventListener("click", function (event) {
  var details = document.querySelectorAll("details");
  details.forEach(function (detail) {
    if (!detail.contains(event.target)) {
      detail.open = false;
    }
  });
});

(function () {
  var dragTimer;
  window.addEventListener("dragover", function (event) {
    if (!event.dataTransfer || !event.dataTransfer.types.length) return;
    event.preventDefault();
    document.documentElement.classList.add("is-dragging");
    var uploadDetails = document.getElementById("upload-button")?.closest("details");
    if (uploadDetails) uploadDetails.open = true;
    clearTimeout(dragTimer);
    dragTimer = setTimeout(function () {
      document.documentElement.classList.remove("is-dragging");
    }, 150);
  });
  window.addEventListener("drop", function (event) {
    event.preventDefault();
    clearTimeout(dragTimer);
    document.documentElement.classList.remove("is-dragging");
  });
})();
