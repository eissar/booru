local cards = {}
for i = 0, 19 do
  local w, h = 100, 180
  if i % 2 == 1 then w, h = 180, 100 end
  local media
  if i == 1 then
    media = string.format(
      "<video class=gallery-card-media preload=none width=%d height=%d style='aspect-ratio:%d/%d'></video>",
      w, h, w, h
    )
  else
    media = string.format(
      "<img class=gallery-card-media width=%d height=%d style='aspect-ratio:%d/%d'>",
      w, h, w, h
    )
  end
  cards[#cards + 1] = string.format(
    "<article class=masonry-item data-render-order-id='%d' data-image-id='%d'>" ..
    "<div class=gallery-card><div class=gallery-card-slot><div class=gallery-card-meta><span>item-%d</span></div></div>%s</div></article>",
    i, i, i, media
  )
end

local png_1x1 = "\137PNG\13\10\26\10\0\0\0\13IHDR\0\0\0\1\0\0\0\1\8\2\0\0\0\144wS\222\0\0\0\12IDATx\156c\248\15\0\0\1\1\0\5\24\216N\0\0\0\0IEND\174B`\130"

local function make_fixture_html(disable_decoder)
  local decoder_script = disable_decoder and [[
window.ImageDecoder = undefined;
]] or [[
window.__mipmapRequests = [];
const frameCounts = new WeakMap();
const realFetch = window.fetch;
window.fetch = async (...args) => {
  const url = new URL(args[0], location.href);
  if (url.pathname.startsWith('/mipmap/')) {
    window.__mipmapRequests.push(url.searchParams.get('ids'));
  }
  const response = await realFetch(...args);
  if (url.pathname.startsWith('/mipmap/'))
    frameCounts.set(response.body, url.searchParams.get('ids').split(',').length);
  return response;
};
window.ImageDecoder = class {
  static async isTypeSupported() { return true; }
  constructor({ data }) {
    this.complete = true;
    this.completed = Promise.resolve();
    this.tracks = { ready: Promise.resolve(), selectedTrack: { frameCount: frameCounts.get(data) } };
  }
  async decode() {
    const image = document.createElement('canvas');
    image.width = image.height = 64;
    image.displayWidth = image.displayHeight = 64;
    image.close = () => {};
    const c = image.getContext('2d');
    c.fillStyle = 'rgb(255, 0, 0)';
    c.fillRect(0, 0, 64, 64);
    return { image };
  }
  close() {}
};
]]
  return [[<!doctype html><html><head><style>
]] .. read_file("static/gallery.css") .. [[
html,body { margin:0; height:100%; } .main-content { height:400px; width:600px; overflow:auto; padding:0; }
.gallery-card { display:flex; flex-direction:column; overflow:hidden; }
.gallery-card-media { order:1; }
.gallery-card-slot { order:2; }
</style><script>
]] .. decoder_script .. [[
</script><script src='/static/gallery.js'></script></head><body>
<main id=gallery-main><div class=gallery-content><div id=gallery-layout><section class=main-content>
<div id=filter-bar>
  <input type=radio name=gallery-view id=gallery-view-masonry value=masonry checked>
  <input type=radio name=gallery-view id=gallery-view-grid value=grid>
  <input type=radio name=gallery-view id=gallery-view-list value=list>
</div>
<div id=photo-grid class=masonry-grid>]] ..
  table.concat(cards) ..
[[<div id=pagination-controls></div></div></section></div></div></main></body></html>]]
end

describe("gallery-preview-canvases", function()
  local srv, b

  before_all(function()
    srv = cdp.server({
      ["/static/gallery.js"] = { content_type = "text/javascript", body = read_file("static/gallery.js"), prefix = false },
      ["/mipmap/"]           = { content_type = "text/plain",      body = "test",                         prefix = true },
      ["/img.png"]           = { content_type = "image/png",       body = png_1x1,                        prefix = false },
      ["/"]                  = { content_type = "text/html",       body = make_fixture_html(false),       prefix = false },
      ["/no-decoder"]        = { content_type = "text/html",       body = make_fixture_html(true),        prefix = false },
    })
    b = cdp.open(srv:url())
  end)

  after_all(function()
    if b then b:close() end
    if srv then srv:close() end
  end)

  it("renders cropped per-card canvases, matches bounds across views, removes on img load, and reuses cache on htmx append/swap", function()
    b:navigate("/")
    b:wait_for([[(() => {
      const s = window.booruPreviewSnapshot?.();
      return s && s.active && s.images.length === 20 && s.images.every(i => i.ready);
    })()]], 5000)

    local init = b:eval([[(() => {
      const card0 = document.querySelector('[data-image-id="0"]');
      const card1 = document.querySelector('[data-image-id="1"]');
      const c0 = card0.querySelector('.gallery-card-preview');
      const m0 = card0.querySelector('.gallery-card-media');
      const c1 = card1.querySelector('.gallery-card-preview');
      const m1 = card1.querySelector('.gallery-card-media');
      const r0c = c0.getBoundingClientRect();
      const r0m = m0.getBoundingClientRect();
      const r1c = c1.getBoundingClientRect();
      const r1m = m1.getBoundingClientRect();
      return {
        noLegacyBg: !document.getElementById('thumbnail-background') && !document.querySelector('.gallery-preview-surface'),
        reqCount: window.__mipmapRequests.length,
        c0Attached: c0.parentElement === card0.querySelector('.gallery-card'),
        c0Dims: [c0.width, c0.height],
        c1Dims: [c1.width, c1.height],
        c0Z: getComputedStyle(c0).zIndex,
        cardIso: getComputedStyle(card0.querySelector('.gallery-card')).isolation,
        c0BoundsMatch: Math.abs(r0c.left - r0m.left) < 1 && Math.abs(r0c.top - r0m.top) < 1 &&
                       Math.abs(r0c.width - r0m.width) < 1 && Math.abs(r0c.height - r0m.height) < 1,
        c1BoundsMatch: Math.abs(r1c.left - r1m.left) < 1 && Math.abs(r1c.top - r1m.top) < 1 &&
                       Math.abs(r1c.width - r1m.width) < 1 && Math.abs(r1c.height - r1m.height) < 1,
        pixel0: Array.from(c0.getContext('2d').getImageData(0, 0, 1, 1).data),
      };
    })()]])

    assert(init.noLegacyBg, "legacy strip elements should not exist")
    assert_eq(1, init.reqCount, "expected exactly 1 initial mipmap request")
    assert(init.c0Attached, "preview canvas not inside .gallery-card")
    assert_eq(36, init.c0Dims[1], "portrait contentW")
    assert_eq(64, init.c0Dims[2], "portrait contentH")
    assert_eq(64, init.c1Dims[1], "landscape contentW")
    assert_eq(36, init.c1Dims[2], "landscape contentH")
    assert_eq("-1", init.c0Z, "preview canvas z-index")
    assert_eq("isolate", init.cardIso, "card isolation")
    assert(init.c0BoundsMatch, "masonry portrait preview bounds mismatch")
    assert(init.c1BoundsMatch, "masonry video preview bounds mismatch")
    assert_eq(255, init.pixel0[1], "canvas pixel R")
    assert_eq(255, init.pixel0[4], "canvas pixel A")

    -- View-switch preservation: masonry -> grid -> list -> masonry without re-fetching.
    local views = b:eval([[new Promise(resolve => {
      const card0 = document.querySelector('[data-image-id="0"]');
      const originalCanvas = card0.querySelector('.gallery-card-preview');
      const results = {};
      const checkBounds = () => {
        const c = card0.querySelector('.gallery-card-preview');
        const m = card0.querySelector('.gallery-card-media');
        const rc = c.getBoundingClientRect();
        const rm = m.getBoundingClientRect();
        return {
          sameCanvas: c === originalCanvas,
          match: Math.abs(rc.left - rm.left) < 1 && Math.abs(rc.top - rm.top) < 1 &&
                 Math.abs(rc.width - rm.width) < 1 && Math.abs(rc.height - rm.height) < 1 &&
                 rc.width > 0 && rc.height > 0,
        };
      };
      document.getElementById('gallery-view-grid').click();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        results.grid = checkBounds();
        document.getElementById('gallery-view-list').click();
        requestAnimationFrame(() => requestAnimationFrame(() => {
          results.list = checkBounds();
          document.getElementById('gallery-view-masonry').click();
          requestAnimationFrame(() => requestAnimationFrame(() => {
            results.masonry = checkBounds();
            results.reqCount = window.__mipmapRequests.length;
            resolve(results);
          }));
        }));
      }));
    })]])
    assert(views.grid.sameCanvas and views.grid.match, "grid view lost canvas or bounds mismatch")
    assert(views.list.sameCanvas and views.list.match, "list view lost canvas or bounds mismatch")
    assert(views.masonry.sameCanvas and views.masonry.match, "masonry return lost canvas or bounds mismatch")
    assert_eq(1, views.reqCount, "view switches should not re-fetch mipmaps")

    -- Image load removes preview canvas on <img>, keeps it on <video>.
    local loaded = b:eval([[new Promise(resolve => {
      const card0 = document.querySelector('[data-image-id="0"]');
      const img0 = card0.querySelector('.gallery-card-media');
      img0.addEventListener('load', () => {
        setTimeout(() => resolve({
          img0HasCanvas: !!card0.querySelector('.gallery-card-preview'),
          video1HasCanvas: !!document.querySelector('[data-image-id="1"] .gallery-card-preview'),
          snap0Ready: window.booruPreviewSnapshot().images[0].ready,
          snap0Canvas: window.booruPreviewSnapshot().images[0].canvas,
        }), 20);
      }, { once: true });
      img0.src = '/img.png';
    })]])
    assert(not loaded.img0HasCanvas, "loaded <img> should remove its preview canvas")
    assert(loaded.video1HasCanvas, "<video> card should keep its preview canvas")
    assert(loaded.snap0Ready, "loaded <img> should remain ready in snapshot")
    assert(loaded.snap0Canvas == nil, "loaded <img> snapshot canvas should be nil")

    -- /fragment/items append fetches only new IDs (20, 21), not 0..19.
    local append = b:eval([[new Promise(resolve => {
      const reqsBefore = window.__mipmapRequests.length;
      const pag = document.getElementById('pagination-controls');
      pag.insertAdjacentHTML('beforebegin',
        '<article class=masonry-item data-render-order-id=20 data-image-id=20><div class=gallery-card><div class=gallery-card-slot><div class=gallery-card-meta></div></div><img class=gallery-card-media width=100 height=180 style="aspect-ratio:100/180"></div></article>' +
        '<article class=masonry-item data-render-order-id=21 data-image-id=21><div class=gallery-card><div class=gallery-card-slot><div class=gallery-card-meta></div></div><img class=gallery-card-media width=100 height=180 style="aspect-ratio:100/180"></div></article>'
      );
      document.dispatchEvent(new CustomEvent('htmx:afterSettle'));
      document.dispatchEvent(new CustomEvent('htmx:afterSwap', {
        detail: { xhr: { responseURL: location.origin + '/fragment/items' } }
      }));
      const wait = () => {
        const c20 = document.querySelector('[data-image-id="20"] .gallery-card-preview');
        const c21 = document.querySelector('[data-image-id="21"] .gallery-card-preview');
        if (c20 && c21) {
          return resolve({
            newReqs: window.__mipmapRequests.slice(reqsBefore),
            c20Attached: !!c20,
            c21Attached: !!c21,
          });
        }
        requestAnimationFrame(wait);
      };
      requestAnimationFrame(wait);
    })]])
    assert_eq(1, #append.newReqs, "append should issue 1 new mipmap request")
    assert_eq("20,21", append.newReqs[1], "append should only request uncached IDs")

    -- /fragment/gallery-content swap reuses cached previews without re-fetching.
    local swap = b:eval([[new Promise(resolve => {
      const reqsBefore = window.__mipmapRequests.length;
      const grid = document.querySelector('#photo-grid');
      const replacement = grid.cloneNode(true);
      for (const el of replacement.querySelectorAll('.gallery-card-preview')) el.remove();
      grid.replaceWith(replacement);
      document.dispatchEvent(new CustomEvent('htmx:afterSettle'));
      document.dispatchEvent(new CustomEvent('htmx:afterSwap', {
        detail: { xhr: { responseURL: location.origin + '/fragment/gallery-content' } }
      }));
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const c2 = replacement.querySelector('[data-image-id="2"] .gallery-card-preview');
        const v1 = replacement.querySelector('[data-image-id="1"] .gallery-card-preview');
        const img0 = replacement.querySelector('[data-image-id="0"] .gallery-card-preview');
        resolve({
          reqsAdded: window.__mipmapRequests.length - reqsBefore,
          c2Restored: !!c2,
          c2Pixel: c2 ? Array.from(c2.getContext('2d').getImageData(0, 0, 1, 1).data) : null,
          v1Restored: !!v1,
          img0StillHidden: !img0,
        });
      }));
    })]])
    assert_eq(0, swap.reqsAdded, "gallery-content swap with cached IDs must not re-fetch")
    assert(swap.c2Restored, "cached preview not restored after gallery-content swap")
    assert_eq(255, swap.c2Pixel[1], "restored canvas should preserve pixels")
    assert(swap.v1Restored, "cached video preview not restored after swap")
    assert(swap.img0StillHidden, "already-loaded img should not re-attach canvas")
  end)

  it("degrades cleanly when ImageDecoder is unavailable", function()
    b:navigate("/no-decoder")
    local res = b:eval([[new Promise(resolve => {
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const s = window.booruPreviewSnapshot();
        const card0 = document.querySelector('[data-image-id="0"]');
        const img0 = card0.querySelector('.gallery-card-media');
        img0.addEventListener('load', () => {
          resolve({
            state: s.state,
            active: s.active,
            columns: document.querySelectorAll('.masonry-column').length,
            imgLoaded: img0.complete && img0.naturalWidth > 0,
            noCanvases: document.querySelectorAll('.gallery-card-preview').length === 0,
          });
        }, { once: true });
        img0.src = '/img.png';
      }));
    })]])
    assert_eq("failed", res.state, "expected failed preview state")
    assert(not res.active, "expected active=false when ImageDecoder unavailable")
    assert(res.columns > 0, "masonry columns should still pack")
    assert(res.imgLoaded, "<img> should still load")
    assert(res.noCanvases, "no preview canvases should be attached")
  end)
end)
