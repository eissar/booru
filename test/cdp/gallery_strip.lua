local cards = {}
for i = 0, 39 do
  cards[#cards + 1] = string.format(
    "<article class=masonry-item data-render-order-id='%d' data-image-id='%d'>" ..
    "<div class=gallery-card><img class=gallery-card-image width=100 height=180></div></article>",
    i, i
  )
end

local fixture_html = [[<!doctype html><html><head><style>
]] .. read_file("static/gallery.css") .. [[
html,body { margin:0; height:100%; } .main-content { height:400px; width:600px; overflow:auto; padding:0; }
#photo-grid { display:block; width:100%; } .masonry-item { height:200px; }
.gallery-card { height:200px; overflow:hidden; } .gallery-card-image { width:100px; height:180px; }
</style><script>
// Each mipmap response contains one frame per requested image, not all cards.
const frameCounts = new WeakMap();
const realFetch = window.fetch;
window.fetch = async (...args) => {
  const response = await realFetch(...args);
  const url = new URL(args[0], location.href);
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
    c.fillStyle = 'red';
    c.fillRect(0, 0, 64, 64);
    return { image };
  }
  close() {}
};
</script><script src='/static/gallery.js'></script></head><body>
<input type=radio name=gallery-view value=grid checked>
<main id=gallery-main><section class=main-content><div id=photo-grid>]] ..
  table.concat(cards) ..
[[</div></section></main><canvas id=thumbnail-background></canvas></body></html>]]

describe("gallery-strip", function()
  local srv, b

  before_all(function()
    srv = cdp.server({
      ["/static/gallery.js"]     = { content_type = "text/javascript", body = read_file("static/gallery.js"),     prefix = false },
      ["/static/benchmark.html"] = { content_type = "text/html",       body = read_file("static/benchmark.html"), prefix = false },
      ["/mipmap/"]               = { content_type = "text/plain",      body = "test",                             prefix = true },
      ["/gallery"]               = { content_type = "text/html",       body = fixture_html,                      prefix = false },
      ["/"]                      = { content_type = "text/html",       body = fixture_html,                      prefix = false },
    })
    b = cdp.open(srv:url())
  end)

  after_all(function()
    if b then b:close() end
    if srv then srv:close() end
  end)

  it("attaches 7-height strip, scrolls with cards, recenters on jump, resizes, and survives htmx swap", function()
    b:navigate("/")
    b:wait_for_selector(".gallery-preview-surface", 5000)

    local init = b:eval([[(() => {
      const canvas = document.querySelector('canvas#thumbnail-background');
      const port = document.querySelector('.main-content');
      const grid = document.querySelector('#photo-grid');
      const h = port.clientHeight;
      return {
        attached: canvas.parentElement?.className === 'gallery-preview-surface',
        inGrid: canvas.closest('#photo-grid') === grid,
        sevenHeights: parseFloat(canvas.style.height) === 7 * h,
        threeAbove: parseFloat(canvas.style.top) === -3 * h,
        scrollHeight: port.scrollHeight,
        startTop: canvas.style.top,
        beforeRectTop: canvas.getBoundingClientRect().top,
      };
    })()]])

    assert(init.attached, "canvas not attached")
    assert(init.inGrid, "canvas outside scroll content")
    assert(init.sevenHeights, "not seven heights")
    assert(init.threeAbove, "not three heights above")
    assert_eq(8000, init.scrollHeight, "strip extended content height")

    b:eval([[document.querySelector('.main-content').scrollTop = 200]])
    b:sleep(100)
    local after_scroll = b:eval([[(() => {
      const c = document.querySelector('canvas#thumbnail-background');
      return { top: c.style.top, rectTop: c.getBoundingClientRect().top };
    })()]])
    assert_eq(init.startTop, after_scroll.top, "ordinary scroll rebased strip")
    assert(math.abs(after_scroll.rectTop - (init.beforeRectTop - 200)) < 1, "canvas did not scroll with cards")

    local jump_ok = b:eval([[new Promise(r => {
      const port = document.querySelector('.main-content');
      const canvas = document.querySelector('canvas#thumbnail-background');
      port.scrollTop = 3000;
      setTimeout(() => r(parseFloat(canvas.style.top) === 3000 - 3 * port.clientHeight), 120);
    })]])
    assert(jump_ok, "jump did not recenter")

    local resize_ok = b:eval([[new Promise(r => {
      const port = document.querySelector('.main-content');
      const canvas = document.querySelector('canvas#thumbnail-background');
      port.style.height = '300px';
      dispatchEvent(new Event('resize'));
      setTimeout(() => r(parseFloat(canvas.style.height) === 7 * port.clientHeight), 120);
    })]])
    assert(resize_ok, "resize did not resize strip")

    local swap = b:eval([[new Promise(r => {
      const grid = document.querySelector('#photo-grid');
      const canvas = document.querySelector('canvas#thumbnail-background');
      const replacement = grid.cloneNode(true);
      replacement.querySelector('.gallery-preview-surface').remove();
      grid.replaceWith(replacement);
      document.dispatchEvent(new CustomEvent('htmx:afterSwap', {
        detail: { xhr: { responseURL: location.origin + '/fragment/gallery-content' } }
      }));
      setTimeout(() => r({
        reattached: canvas.closest('#photo-grid') === replacement,
        count: document.querySelectorAll('#thumbnail-background').length,
      }), 120);
    })]])
    assert(swap.reattached, "swap lost canvas")
    assert_eq(1, swap.count, "duplicate canvas")
  end)

  it("benchmark overlay samples live gallery, excludes idle, counts undrawn, and panics on failure", function()
    b:navigate("/static/benchmark.html")
    b:wait_for([[(() => {
      const f = document.querySelector('#gallery');
      return f && typeof f.contentWindow?.booruPreviewSnapshot === 'function'
        && document.querySelector('#counts').textContent !== '—';
    })()]], 10000)

    local counts = b:eval([[document.querySelector('#counts').textContent]])
    assert_match("^%d+ / %d+$", counts, "overlay did not sample live gallery")

    b:eval([[document.querySelector('#reset').click()]])
    b:sleep(500)
    assert_eq("0 / 0", b:eval([[document.querySelector('#samples').textContent]]), "idle or warmup counted")

    b:eval([[(() => {
      const w = document.querySelector('#gallery').contentWindow;
      const snapshot = w.booruPreviewSnapshot;
      w.booruPreviewSnapshot = () => {
        const s = snapshot();
        return { ...s, images: s.images.map(i => ({ ...i, painted: null })) };
      };
      w.document.querySelector('.main-content').scrollTop += 100;
    })()]])
    b:sleep(250)
    assert_eq("1 / 1", b:eval([[document.querySelector('#samples').textContent]]), "missing submitted previews not counted once")

    b:sleep(300)
    assert_eq("1 / 1", b:eval([[document.querySelector('#samples').textContent]]), "idle inflated scroll samples")

    b:eval([[(() => {
      const w = document.querySelector('#gallery').contentWindow;
      const snapshot = w.booruPreviewSnapshot;
      w.booruPreviewSnapshot = () => ({ ...snapshot(), active: false });
    })()]])
    b:sleep(250)
    assert_match(
      "^FAILED: Benchmark invariant: renderer reports active but preview surface is disabled",
      b:eval([[document.querySelector('#status').textContent]]),
      "renderer failure did not panic"
    )
  end)
end)
