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
    });
  }

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
