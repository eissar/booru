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
  var cachedLayout = null;
  var canonicalCards = null;
  // Container resize (e.g. inspector opening) can change column packing.
  var contentSize = new ResizeObserver(function () {
    syncMasonry();
  });
  var observedContent = null;

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
    var img = card.querySelector(".gallery-card-media[width][height]");
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
    canonicalCards = cards;
    return cards;
  }

  function getCanonicalCards(grid) {
    if (!grid) return [];
    if (canonicalCards && canonicalCards.length) {
      var valid = true;
      for (var i = 0; i < canonicalCards.length; i++) {
        if (!canonicalCards[i].isConnected) { valid = false; break; }
      }
      if (valid && grid.getElementsByClassName("masonry-item").length === canonicalCards.length) {
        return canonicalCards;
      }
    }
    return collectCards(grid);
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
    var content = grid.closest(".main-content");
    if (content !== observedContent) {
      contentSize.disconnect();
      if (content) contentSize.observe(content);
      observedContent = content;
    }

    var geometry = null;
    if (columns > 0) geometry = measureMasonry(grid);
    else cachedLayout = null;

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
      document.documentElement.scrollTop = geometry.scrollTop + geometry.visibleTop - visibleTop;
    }
  }

  /**
   * @typedef {Object} Geometry
   * @property {number} scrollTop - Root scroll offset in pixels.
   * @property {number} visibleTop - Viewport top relative to the grid, in pixels.
   * @property {number} height - Viewport height in pixels.
   * @property {number} width - Column width in pixels.
   * @property {number} gap - Metadata slot and inter-card gap in pixels.
   */

  function measurePort(grid) {
    var scrollTop = document.documentElement.scrollTop;
    var visibleTop = -grid.getBoundingClientRect().top;
    return {
      grid: grid,
      gridTop: scrollTop - visibleTop,
      scrollTop: scrollTop,
      visibleTop: visibleTop,
      height: window.innerHeight,
      width: 0,
      gap: 0,
    };
  }

  // Reads what showNearbyCards needs. Callers measure before writing to the
  // DOM, so the browser never lays out collapsed columns and clamps scrollTop.
  /** @returns {Geometry|null} */
  function measureMasonry(grid) {
    var layout = measurePort(grid);
    var slot = grid.querySelector(":scope > .masonry-item .gallery-card-slot, :scope > .masonry-column .gallery-card-slot");
    if (!slot) {
      cachedLayout = layout;
      return null;
    }
    var style = getComputedStyle(grid);
    var height = slot.getBoundingClientRect().height;
    if (!height) {
      cachedLayout = layout;
      return null;
    }
    layout.width = parseFloat(style.gridTemplateColumns);
    layout.gap = height + parseFloat(style.rowGap);
    cachedLayout = layout;
    return layout;
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
    });
  }

  const endpoint = "/mipmap/64";
  const previewsById = new Map();
  const previewCanvasByCard = new WeakMap();
  const inFlightIds = new Set();
  const activeBatches = new Set();
  let previewState = "starting",
    previewError = null;

  function releaseBatches() {
    for (const current of activeBatches) {
      current.abort.abort();
      current.decoder?.close();
      for (const id of current.ids) inFlightIds.delete(id);
    }
    activeBatches.clear();
  }

  function failPreview(error) {
    previewState = "failed";
    previewError = error instanceof Error ? error.message : String(error);
    releaseBatches();
    console.error("[booru-preview] Mipmap preview:", error);
  }

  function isMediaLoaded(media) {
    return media instanceof HTMLImageElement && media.complete && media.naturalWidth > 0;
  }

  function removeCardPreview(card) {
    const existing = previewCanvasByCard.get(card);
    if (existing) {
      existing.remove();
      previewCanvasByCard.delete(card);
    }
  }

  function attachPreview(card, previewCanvas) {
    const cardEl = card.querySelector(".gallery-card");
    const media = card.querySelector(".gallery-card-media");
    if (!cardEl || !media) return;
    if (isMediaLoaded(media)) {
      removeCardPreview(card);
      return;
    }
    const existing = previewCanvasByCard.get(card);
    if (existing && existing.parentElement === cardEl && existing.isConnected) return;
    const stale = cardEl.querySelector(":scope > .gallery-card-preview");
    if (stale) stale.remove();

    let canvas = previewCanvas;
    if (canvas.isConnected) {
      canvas = document.createElement("canvas");
      canvas.className = "gallery-card-preview";
      canvas.setAttribute("aria-hidden", "true");
      canvas.width = previewCanvas.width;
      canvas.height = previewCanvas.height;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      ctx.drawImage(previewCanvas, 0, 0);
    }
    const origW = Number(media.getAttribute("width")) || 0;
    const origH = Number(media.getAttribute("height")) || 0;
    const aspectRatio =
      media.style.aspectRatio || (origW > 0 && origH > 0 ? origW + "/" + origH : "");
    if (aspectRatio) {
      canvas.style.aspectRatio = aspectRatio;
    } else {
      canvas.style.removeProperty("aspect-ratio");
    }
    cardEl.appendChild(canvas);
    previewCanvasByCard.set(card, canvas);
  }

  function requestBatch(replace = false) {
    if (previewState !== "active") return;
    if (replace) releaseBatches();

    const grid = getGrid();
    const cards = grid ? collectCards(grid) : [];
    const ids = [];
    const cardsByIndex = [];
    const batchIndexById = new Map();

    for (const card of cards) {
      const id = card.dataset.imageId;
      if (!id) continue;
      const cached = previewsById.get(id);
      if (cached) {
        attachPreview(card, cached);
        continue;
      }
      if (inFlightIds.has(id)) continue;
      if (!card.querySelector(".gallery-card-media")) continue;
      let idx = batchIndexById.get(id);
      if (idx === undefined) {
        idx = ids.length;
        batchIndexById.set(id, idx);
        ids.push(id);
        cardsByIndex.push([card]);
      } else {
        cardsByIndex[idx].push(card);
      }
    }

    if (!ids.length) return;
    for (const id of ids) inFlightIds.add(id);
    const current = {
      ids,
      cardsByIndex,
      abort: new AbortController(),
      decoder: null,
    };
    activeBatches.add(current);
    loadBatch(current)
      .catch((error) => {
        if (current.abort.signal.aborted) return;
        failPreview(error);
      })
      .finally(() => {
        current.decoder?.close();
        for (const id of current.ids) inFlightIds.delete(id);
        activeBatches.delete(current);
      });
  }

  async function loadBatch(current) {
    // Same URL as the <link rel="preload"> in the page head, so the first
    // batch reuses that request. Keep the request mode and cache defaults.
    const { ids, cardsByIndex } = current;
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
    let count = 0;
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
        const id = ids[i];
        const cards = cardsByIndex[i];
        const media = cards[0]?.querySelector(".gallery-card-media");
        const originalW = Number(media?.getAttribute("width")) || 1;
        const originalH = Number(media?.getAttribute("height")) || 1;
        const edge = image.displayWidth;
        const contentW =
          originalW >= originalH
            ? edge
            : Math.max(1, Math.floor((edge * originalW) / originalH + 0.5));
        const contentH =
          originalH >= originalW
            ? edge
            : Math.max(1, Math.floor((edge * originalH) / originalW + 0.5));
        const previewCanvas = document.createElement("canvas");
        previewCanvas.className = "gallery-card-preview";
        previewCanvas.setAttribute("aria-hidden", "true");
        previewCanvas.width = contentW;
        previewCanvas.height = contentH;
        const ctx = previewCanvas.getContext("2d");
        if (!ctx) throw Error("2D canvas context unavailable");
        ctx.drawImage(image, 0, 0, contentW, contentH, 0, 0, contentW, contentH);
        previewsById.set(id, previewCanvas);
        for (const card of cards) {
          if (card.isConnected) attachPreview(card, previewCanvas);
        }
        count++;
      } finally {
        image.close();
      }
    }
    await completed;
    if (streamError) throw streamError;
    if (count !== ids.length)
      throw Error(`Expected ${ids.length} frames, received ${count}`);
  }

  // Read-only diagnostics for benchmarks and tests. No observers or work unless called.
  globalThis.booruPreviewSnapshot = () => {
    const grid = getGrid();
    const cards = getCanonicalCards(grid);
    return {
      state: previewState,
      error: previewError,
      active: previewState === "active",
      images: cards.map((card) => {
        const image = card.querySelector(".gallery-card-media");
        const id = card.dataset.imageId;
        const canvas = previewCanvasByCard.get(card) || null;
        return {
          image,
          ready: !!(id && previewsById.has(id)),
          canvas: canvas && canvas.isConnected ? canvas : null,
        };
      }),
    };
  };

  // Only gallery responses request mipmap previews; sync masonry immediately
  // on swap so appended cards never paint below the makespan before settling.
  let lastSwapXhr = null;
  document.addEventListener("htmx:afterSwap", (event) => {
    const xhr = event.detail.xhr;
    if (xhr && xhr === lastSwapXhr) return;
    if (xhr) {
      lastSwapXhr = xhr;
      queueMicrotask(() => {
        if (lastSwapXhr === xhr) lastSwapXhr = null;
      });
    }
    canonicalCards = null;
    const url = xhr?.responseURL;
    const path = url ? new URL(url, location.href).pathname : "";
    const grid = getGrid();
    if (path === "/fragment/items" || path === "/fragment/gallery-content" ||
        (grid && getCurrentView() === "masonry" && grid.querySelector(":scope > .masonry-item"))) {
      syncMasonry();
    }
    if (path === "/fragment/items") requestBatch(false);
    else if (path === "/fragment/gallery-content") requestBatch(true);
  });

  document.addEventListener("load", (event) => {
    const img = event.target;
    if (!(img instanceof HTMLImageElement) ||
        !img.classList.contains("gallery-card-media")) return;
    const card = img.closest(".masonry-item");
    if (card) removeCardPreview(card);
  }, true);

  document.addEventListener("DOMContentLoaded", async function () {
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

    var toggle = document.getElementById("dark-mode-toggle");
    if (toggle) {
      toggle.addEventListener("click", function () {
        var currentTheme = document.documentElement.getAttribute("data-theme");
        var newTheme = currentTheme === "dark" ? "light" : "dark";
        document.documentElement.setAttribute("data-theme", newTheme);
        localStorage.setItem("theme", newTheme);
      });
    }

    try {
      if (!globalThis.isSecureContext)
        throw Error("ImageDecoder requires HTTPS or localhost; this page is not a secure context");
      if (!globalThis.ImageDecoder)
        throw Error("ImageDecoder is unavailable in this browser; use a supported Chromium browser");
      if (!(await ImageDecoder.isTypeSupported("image/webp")))
        throw Error("This browser's ImageDecoder does not support image/webp");
      previewState = "active";
      requestBatch(true);
    } catch (error) {
      failPreview(error);
    }
  });

  // Triggers. Each one is dumb: it only requests a sync.
  document.addEventListener("htmx:afterSettle", scheduleMasonrySync);
  window.addEventListener("resize", scheduleMasonrySync);

  // Scrolling only updates nearby packed cards in masonry view.
  function onScroll(event) {
    if (packedColumns.length === 0 || event.target !== document) return;
    if (!cachedLayout || !cachedLayout.grid.isConnected) {
      var grid = getGrid();
      if (!grid) return;
      cachedLayout = measureMasonry(grid);
    }
    if (!cachedLayout || !cachedLayout.width) return;

    if (!nearbyQueued) {
      nearbyQueued = true;
      requestAnimationFrame(function () {
        nearbyQueued = false;
        if (packedColumns.length && cachedLayout && cachedLayout.width &&
            cachedLayout.grid.isConnected) {
          var scrollTop = document.documentElement.scrollTop;
          showNearbyCards({
            scrollTop: scrollTop,
            visibleTop: scrollTop - cachedLayout.gridTop,
            height: cachedLayout.height,
            width: cachedLayout.width,
            gap: cachedLayout.gap,
          });
        }
      });
    }
  }

  document.addEventListener("scroll", onScroll, true);
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
})();

(function () {
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
