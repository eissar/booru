// Masonry layout: one dispatcher, one policy.
//
// Every trigger (htmx settle, breakpoint change, view switch, boot) funnels
// into scheduleMasonrySync, a single rAF-coalesced queue. syncMasonry then
// rebuilds the grid as a pure function of what the DOM contains: the cards,
// the current view mode, and --masonry-columns. No state is carried between
// runs, so the same cards always pack the same way no matter which events
// led here (load more, delete, resize), or in what order they fired.

(function () {
  var syncQueued = false;
  var lastSyncKey = null;

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
    return w > 0 && h > 0 ? h / w : 1;
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

  // The sync key is the canonical spec of the layout: view, column count,
  // and each card's (order, image id) in canonical sequence. It is stable
  // across pack/unpack, so repeated triggers after a no-op settle skip.
  function buildSyncKey(view, columns, cards) {
    var parts = [];
    for (var i = 0; i < cards.length; i++) {
      parts.push(cardOrder(cards[i]) + ":" + cards[i].getAttribute("data-image-id"));
    }
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
    var key = buildSyncKey(view, columns, cards);
    if (key === lastSyncKey && packedColumnsMatch(grid, columns)) return;
    lastSyncKey = key;

    // Flatten: unload packed columns back into the grid, then re-append the
    // cards in canonical order.
    var packed = Array.from(grid.querySelectorAll(":scope > .masonry-column"));
    for (var i = 0; i < packed.length; i++) {
      var col = packed[i];
      while (col.firstChild) insertBeforePagination(grid, col.firstChild);
      col.remove();
    }
    for (var i = 0; i < cards.length; i++) insertBeforePagination(grid, cards[i]);

    // Grid/list views render flat cards; only masonry packs.
    if (columns === 0) return;

    var cols = [];
    for (var i = 0; i < columns; i++) {
      var col = document.createElement("div");
      col.className = "masonry-column";
      insertBeforePagination(grid, col);
      cols.push(col);
    }
    var heights = [];
    for (var i = 0; i < columns; i++) heights.push(0);
    for (var i = 0; i < cards.length; i++) {
      var shortest = 0;
      for (var j = 1; j < columns; j++) {
        if (heights[j] < heights[shortest]) shortest = j;
      }
      cols[shortest].appendChild(cards[i]);
      heights[shortest] += cardRatio(cards[i]);
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
  let pending = false,
    batchQueued = false,
    animateUntil = 0;
  const endpoint = "/mipmap/64";
  const imageSizes = new ResizeObserver(schedule);

  function shader(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS))
      throw Error(gl.getShaderInfoLog(shader));
    return shader;
  }

  function init() {
    gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true });
    if (!gl) throw Error("WebGL2 unavailable");
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
    if (!uniforms) return;
    const images = batch ? batch.images : [];
    const thumbnails = batch ? batch.thumbnails : [];
    const w = innerWidth,
      h = innerHeight,
      dpr = devicePixelRatio || 1;
    const width = Math.round(w * dpr),
      height = Math.round(h * dpr);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    gl.viewport(0, 0, width, height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program);
    gl.uniform2f(uniforms.screen, w, h);
    for (let i = 0; i < images.length; i++) {
      const img = images[i],
        thumb = thumbnails[i];
      if (!thumb || !img.isConnected) continue;
      const rect = img.getBoundingClientRect(); // Includes the actual CSS hover transform.
      if (!rect.width || !rect.height || rect.bottom <= 0 || rect.top >= h)
        continue;
      let left = 0,
        top = 0,
        right = w,
        bottom = h;
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
        if (css.overflowY !== "visible") {
          top = Math.max(top, box.top + node.clientTop);
          bottom = Math.min(
            bottom,
            box.top + node.clientTop + node.clientHeight,
          );
        }
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
      gl.uniform4f(uniforms.rect, rect.left, rect.top, rect.width, rect.height);
      gl.uniform4f(uniforms.clipRect, left, top, right, bottom);
      gl.uniform4f(
        uniforms.cardRect,
        cardRect.left,
        cardRect.top,
        cardRect.width,
        cardRect.height,
      );
      gl.uniform1f(uniforms.radius, radius);
      gl.bindTexture(gl.TEXTURE_2D_ARRAY, thumb.texture);
      gl.uniform1i(uniforms.layer, thumb.layer);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
  }

  function schedule() {
    if (pending || !uniforms) return;
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
    batch.abort.abort();
    batch.decoder?.close();
    for (const texture of batch.textures) gl.deleteTexture(texture);
    batch = null;
  }

  function requestBatch() {
    if (batchQueued || !uniforms) return;
    batchQueued = true;
    requestAnimationFrame(() => {
      batchQueued = false;
      releaseBatch();
      imageSizes.disconnect();
      const grid = getGrid();
      const cards = grid ? collectCards(grid) : [];
      const current = (batch = {
        images: cards.map((card) => card.querySelector(".gallery-card-image")),
        thumbnails: [],
        textures: [],
        abort: new AbortController(),
        decoder: null,
      });
      for (const img of current.images) imageSizes.observe(img);
      draw();
      if (!cards.length) return;
      // Capture request order before masonry or another response changes the DOM.
      const ids = cards.map((card) => card.dataset.imageId);
      loadBatch(current, ids)
        .catch((error) => {
          if (current.abort.signal.aborted) return;
          console.error("Mipmap preview:", error);
          document.documentElement.classList.remove("gallery-previews-active");
        })
        .finally(() => current.decoder?.close());
    });
  }

  async function loadBatch(current, ids) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: ids.join(","),
      cache: "no-store",
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
    const batchSize = Math.min(
      ids.length,
      64,
      gl.getParameter(gl.MAX_ARRAY_TEXTURE_LAYERS),
    );
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
        if (i % batchSize === 0) {
          const texture = gl.createTexture();
          if (!texture) throw Error("Texture allocation failed");
          current.textures.push(texture);
          gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
          // LINEAR uses only level zero; generating unused mip levels adds no value here.
          gl.texStorage3D(
            gl.TEXTURE_2D_ARRAY,
            1,
            gl.RGBA8,
            width,
            height,
            batchSize,
          );
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
        }
        const texture = current.textures[Math.floor(i / batchSize)],
          layer = i % batchSize;
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
        current.thumbnails[i] = { texture, layer, width, height };
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
  }

  // Only gallery responses replace the batch. Inspector requests, scrolling,
  // and view changes must not start another download.
  document.addEventListener("htmx:afterSwap", (event) => {
    const url = event.detail.xhr?.responseURL;
    if (!url) return;
    const path = new URL(url, location.href).pathname;
    if (path === "/fragment/items" || path === "/fragment/gallery-content")
      requestBatch();
  });

  document.addEventListener("scroll", schedule, true);
  window.addEventListener("resize", schedule);
  for (const event of ["pointerover", "pointerout", "transitionrun"]) {
    document.addEventListener(event, transitionDraw);
  }

  document.addEventListener("DOMContentLoaded", async () => {
    canvas = document.getElementById("thumbnail-background");
    if (!canvas || !globalThis.ImageDecoder) return;
    try {
      if (!(await ImageDecoder.isTypeSupported("image/webp"))) return;
      uniforms = init();
      document.documentElement.classList.add("gallery-previews-active");
      requestBatch();
    } catch (error) {
      console.error("Mipmap preview:", error);
    }
  });

  // Triggers. Each one is dumb: it only requests a sync.
  document.addEventListener("htmx:afterSettle", scheduleMasonrySync);

  ["(min-width: 768px)", "(min-width: 1024px)", "(min-width: 1280px)"].forEach(
    function (query) {
      matchMedia(query).addEventListener("change", scheduleMasonrySync);
    },
  );

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
})();

document.addEventListener("click", function (event) {
  var details = document.querySelectorAll("details");
  details.forEach(function (detail) {
    if (!detail.contains(event.target)) {
      detail.open = false;
    }
  });
});
