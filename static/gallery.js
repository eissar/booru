// TODO: the logic for masonry layout is unnecessarily complex.
// fix it.

(function () {
  var galleryColHeights = [];
  var pendingMasonryResetRequests = 0;
  var isReflowingMasonry = false;
  var masonryResetQueued = false;

  function clearMasonryLayout() {
    isReflowingMasonry = true;
    var grid = document.getElementById("photo-grid");
    if (!grid) {
      isReflowingMasonry = false;
      return;
    }
    var pagination = grid.querySelector("#pagination-controls");
    var columns = grid.querySelectorAll(".masonry-column");

    var articles = [];
    for (var i = 0; i < columns.length; i++) {
      var col = columns[i];
      while (col.firstChild) {
        var child = col.firstChild;
        if (child.nodeType === 1) {
          articles.push(child);
          col.removeChild(child);
        } else {
          if (pagination) grid.insertBefore(child, pagination);
          else grid.appendChild(child);
        }
      }
      col.remove();
    }

    articles.sort(function (a, b) {
      var aOrder = Number(a.dataset.renderOrderId);
      var bOrder = Number(b.dataset.renderOrderId);
      return aOrder - bOrder;
    });

    for (var i = 0; i < articles.length; i++) {
      if (pagination) grid.insertBefore(articles[i], pagination);
      else grid.appendChild(articles[i]);
    }

    galleryColHeights = [];
    Promise.resolve().then(function () {
      isReflowingMasonry = false;
    });
  }

  function resetMasonryLayout() {
    isReflowingMasonry = true;
    try {
      clearMasonryLayout();
      layoutMasonry();
    } finally {
      Promise.resolve().then(function () {
        isReflowingMasonry = false;
      });
    }
  }

  function queueMasonryReset() {
    if (masonryResetQueued) return;
    masonryResetQueued = true;
    requestAnimationFrame(function () {
      masonryResetQueued = false;
      resetMasonryLayout();
    });
  }

  function layoutMasonry() {
    var grid = document.getElementById("photo-grid");
    if (!grid) return;

    var styles = getComputedStyle(grid);
    var parsedColumns = Number.parseInt(
      styles.getPropertyValue("--masonry-columns"),
      10,
    );
    var columns =
      Number.isFinite(parsedColumns) && parsedColumns > 0 ? parsedColumns : 1;
    var cols = [];
    var pagination = grid.querySelector("#pagination-controls");
    var existingCols = Array.from(
      grid.querySelectorAll(":scope > .masonry-column"),
    );

    for (var i = 0; i < columns; i++) {
      var col = existingCols[i];
      if (!col) {
        col = document.createElement("div");
        col.className = "masonry-column";
        if (pagination) grid.insertBefore(col, pagination);
        else grid.appendChild(col);
      }
      cols.push(col);
    }

    for (var i = 0; i < columns; i++) {
      if (galleryColHeights[i] == null) galleryColHeights[i] = 0;
    }

    var newArticles = Array.from(
      grid.querySelectorAll(":scope > article.masonry-item"),
    );

    newArticles.forEach(function (article) {
      var img = article.querySelector("img[width][height]");
      var ratio = 1;
      if (img) {
        var w = Number(img.getAttribute("width"));
        var h = Number(img.getAttribute("height"));
        ratio = w > 0 && h > 0 ? h / w : 1;
      }

      var shortest = 0;
      for (var i = 1; i < columns; i++) {
        if (galleryColHeights[i] < galleryColHeights[shortest]) shortest = i;
      }

      cols[shortest].appendChild(article);
      galleryColHeights[shortest] += ratio;
    });
  }

  function getCurrentView() {
    var checked = document.querySelector('input[name="gallery-view"]:checked');
    return checked instanceof HTMLInputElement ? checked.value : "masonry";
  }

  globalThis.booruLayoutMasonry = layoutMasonry;
  globalThis.booruClearMasonry = clearMasonryLayout;
  globalThis.booruRequestMasonryReset = function () {
    queueMasonryReset();
  };
  globalThis.booruGetCurrentView = getCurrentView;

  function removedMasonryItem(node) {
    if (node.nodeType !== 1) return false;
    if (node.matches && node.matches("article.masonry-item")) return true;
    return !!(node.querySelector && node.querySelector("article.masonry-item"));
  }

  function observeMasonryDeletes() {
    var grid = document.getElementById("photo-grid");
    if (!grid || grid.dataset.masonryDeleteObserver === "1") return;
    grid.dataset.masonryDeleteObserver = "1";

    new MutationObserver(function (mutations) {
      if (isReflowingMasonry) return;

      for (var i = 0; i < mutations.length; i++) {
        var removed = mutations[i].removedNodes;
        for (var j = 0; j < removed.length; j++) {
          if (removedMasonryItem(removed[j])) {
            if (grid.contains(removed[j])) continue;
            queueMasonryReset();
            return;
          }
        }
      }
    }).observe(grid, { childList: true, subtree: true });
  }

  function pathFromUrl(value) {
    if (!value) return "";
    try {
      return new URL(value, location.href).pathname;
    } catch (_err) {
      return "";
    }
  }

  function isDeleteRequest(event) {
    var detail = event.detail || {};
    var pathInfo = detail.pathInfo || {};
    var requestConfig = detail.requestConfig || {};
    var paths = [
      pathInfo.requestPath,
      pathInfo.finalRequestPath,
      requestConfig.path,
      detail.xhr && detail.xhr.responseURL,
    ];

    for (var i = 0; i < paths.length; i++) {
      if (pathFromUrl(paths[i]) === "/delete") return true;
    }

    var elt = detail.elt || requestConfig.elt || detail.target;
    if (elt && elt.getAttribute && elt.getAttribute("hx-post") === "/delete") {
      return true;
    }
    if (elt && elt.closest && elt.closest('[hx-post="/delete"]')) return true;

    return false;
  }

  ["(min-width: 768px)", "(min-width: 1024px)", "(min-width: 1280px)"].forEach(
    function (query) {
      matchMedia(query).addEventListener("change", function () {
        requestAnimationFrame(function () {
          if (getCurrentView() === "masonry") {
            resetMasonryLayout();
          }
        });
      });
    },
  );

  document.addEventListener("htmx:beforeSend", function (event) {
    if (isDeleteRequest(event)) pendingMasonryResetRequests++;
  });

  document.addEventListener("htmx:afterSettle", function (event) {
    if (pendingMasonryResetRequests > 0 || isDeleteRequest(event)) {
      pendingMasonryResetRequests = 0;
      resetMasonryLayout();
      return;
    }

    if (getCurrentView() === "masonry") {
      layoutMasonry();
    } else {
      clearMasonryLayout();
    }
    observeMasonryDeletes();
  });

  document.addEventListener("DOMContentLoaded", function () {
    if (getCurrentView() === "masonry") {
      layoutMasonry();
    }
    observeMasonryDeletes();
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

document.addEventListener("DOMContentLoaded", function () {
  var viewInputs = document.querySelectorAll('input[name="gallery-view"]');
  var views = new Set(["masonry", "grid", "list"]);
  var requestedView = new URLSearchParams(window.location.search).get("view");
  if (requestedView && views.has(requestedView)) {
    var selected = document.getElementById("gallery-view-" + requestedView);
    if (selected instanceof HTMLInputElement) selected.checked = true;
  }

  viewInputs.forEach(function (input) {
    input.addEventListener("change", function () {
      if (!(input instanceof HTMLInputElement) || !input.checked) return;
      var nextUrl = new URL(window.location.href);
      nextUrl.searchParams.set("view", input.value);
      window.history.replaceState(null, "", nextUrl);
      if (input.value === "masonry") {
        globalThis.booruLayoutMasonry?.();
      } else {
        globalThis.booruClearMasonry?.();
      }
    });
  });

  if (globalThis.booruGetCurrentView?.() === "masonry") {
    globalThis.booruLayoutMasonry?.();
  } else {
    globalThis.booruClearMasonry?.();
  }
});
