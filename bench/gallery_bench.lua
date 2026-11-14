local target_url = os.getenv("GALLERY_URL")

local function build_fixture_html()
  local cards = {}
  for i = 1, 40 do
    cards[#cards + 1] = string.format(
      "<article class=masonry-item data-render-order-id='%d' data-image-id='%d'>" ..
      "<div class=gallery-card><img class=gallery-card-media src='/thumb/%d' width=100 height=180></div></article>",
      i, i, i
    )
  end
  return [[<!doctype html><html><head><style>
]] .. read_file("static/gallery.css") .. [[
*, *::before, *::after { box-sizing: border-box; }
html,body { margin:0; height:100%; } .main-content { height:600px; width:800px; overflow:auto; }
#photo-grid { display:block; width:100%; } .masonry-item { height:200px; }
.gallery-card { height:200px; overflow:hidden; } .gallery-card-media { width:100px; height:180px; }
</style><script>
window.ImageDecoder = class {
  static async isTypeSupported() { return true; }
  constructor() {
    this.complete = true;
    this.completed = Promise.resolve();
    this.tracks = { ready: Promise.resolve(), selectedTrack: { frameCount: 40 } };
  }
  async decode({ frameIndex } = {}) {
    if (frameIndex >= 40) throw new RangeError('end of track');
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
end

describe("gallery-scroll-bench", function()
  local srv, b, nav_path

  before_all(function()
    if target_url and #target_url > 0 then
      b = cdp.open(target_url)
      nav_path = ""
    else
      srv = cdp.server({
        ["/static/gallery.js"] = { content_type = "text/javascript", body = read_file("static/gallery.js"), prefix = false },
        ["/mipmap/"]           = { content_type = "text/plain",      body = "test",                         prefix = true },
        ["/gallery"]           = { content_type = "text/html",       body = build_fixture_html(),           prefix = false },
      })
      b = cdp.open(srv:url())
      nav_path = "/gallery?limit=100"
    end
  end)

  after_all(function()
    if b then b:close() end
    if srv then srv:close() end
  end)

  it("initializes active preview surface within 10s and maintains scroll coverage", function()
    b:navigate(nav_path)

    local state = b:wait_for([[(() => {
      const s = window.booruPreviewSnapshot?.();
      if (!s) return false;
      if (s.state === 'failed') throw new Error('Gallery preview failed: ' + (s.error || 'unknown'));
      return (s.state === 'active' && s.active) ? s.state : false;
    })()]], 10000)
    assert_eq("active", state, "preview renderer did not become active")

    b:wait_for([[(() => {
      const s = window.booruPreviewSnapshot?.();
      if (s?.state === 'failed') throw new Error('Gallery preview failed: ' + (s.error || 'unknown'));
      return s?.images?.length > 0 && s.images.every(i => i.ready);
    })()]], 10000)

    local stats = b:eval([[new Promise((resolve, reject) => {
      const port = document.querySelector('.main-content');
      if (!port) return reject(new Error('gallery scrollport missing'));

      let samples = 0, badSamples = 0, worstBlanks = 0, firstBlank = null;
      let peakSpeed = 0, minAhead = Infinity, minBehind = Infinity;
      let lastT = performance.now(), lastY = port.scrollTop;
      const stepPx = Math.max(80, Math.floor(port.clientHeight * 0.45));

      const covers = (a, b) =>
        b && b.left <= a.left + 1 && b.top <= a.top + 1 && b.right >= a.right - 1 && b.bottom >= a.bottom - 1;

      const tick = (now) => {
        try {
          const snap = window.booruPreviewSnapshot();
          if (!snap.active) throw new Error('renderer reports active=false: ' + JSON.stringify({
            state: snap.state, error: snap.error,
            hasClass: document.documentElement.classList.contains('gallery-previews-active'),
          }));
          if (!snap.canvas?.isConnected) throw new Error('preview canvas disconnected');

          const dt = Math.max(1, now - lastT);
          const dy = Math.abs(port.scrollTop - lastY);
          const speed = (dy * 1000) / dt;
          if (speed > peakSpeed) peakSpeed = speed;
          lastT = now; lastY = port.scrollTop;

          const pr = port.getBoundingClientRect();
          const portClient = {
            left: pr.left + port.clientLeft,
            top: pr.top + port.clientTop,
            right: pr.left + port.clientLeft + port.clientWidth,
            bottom: pr.top + port.clientTop + port.clientHeight,
          };
          const sr = snap.canvas.getBoundingClientRect();
          minAhead = Math.min(minAhead, sr.bottom - portClient.bottom);
          minBehind = Math.min(minBehind, portClient.top - sr.top);

          if (dy > 0) {
            samples++;
            const byImg = new Map(snap.images.map(i => [i.image, i]));
            let blanks = 0;
            for (const img of document.querySelectorAll('.gallery-card-media')) {
              const ir = img.getBoundingClientRect();
              const cr = img.closest('.gallery-card')?.getBoundingClientRect() || ir;
              const r = {
                left: Math.max(ir.left, cr.left, portClient.left),
                top: Math.max(ir.top, cr.top, portClient.top),
                right: Math.min(ir.right, cr.right, portClient.right),
                bottom: Math.min(ir.bottom, cr.bottom, portClient.bottom),
              };
              if (r.right <= r.left || r.bottom <= r.top) continue;
              const entry = byImg.get(img);
              const originalReady = img.complete && img.naturalWidth > 0;
              const p = entry && entry.painted ? {
                left: sr.left + entry.painted.left,
                top: sr.top + entry.painted.top,
                right: sr.left + entry.painted.right,
                bottom: sr.top + entry.painted.bottom,
              } : null;
              const previewReady = p && covers(r, p);
              if (!originalReady && !previewReady) {
                blanks++;
                if (!firstBlank) firstBlank = { r: { l: r.left, t: r.top, r: r.right, b: r.bottom }, pr: { t: pr.top, b: pr.bottom }, painted: p, ready: entry?.ready };
              }
            }
            if (blanks > 0) { badSamples++; worstBlanks = Math.max(worstBlanks, blanks); }
          }

          if (port.scrollTop + port.clientHeight >= port.scrollHeight - 2) {
            return resolve({
              samples,
              badSamples,
              worstBlanks,
              peakSpeed: Math.round(peakSpeed),
              minAhead: Number.isFinite(minAhead) ? Math.round(minAhead) : 0,
              minBehind: Number.isFinite(minBehind) ? Math.round(minBehind) : 0,
              firstBlank,
            });
          }
          port.scrollTop = Math.min(port.scrollHeight, port.scrollTop + stepPx);
          requestAnimationFrame(() => setTimeout(() => requestAnimationFrame(tick), 0));
        } catch (e) {
          reject(e);
        }
      };
      requestAnimationFrame(tick);
    })]])

    print(string.format(
      "BENCH: samples=%d bad=%d worst=%d peakSpeed=%dpx/s minAhead=%dpx minBehind=%dpx",
      stats.samples, stats.badSamples, stats.worstBlanks,
      stats.peakSpeed, stats.minAhead, stats.minBehind
    ))
    if stats.firstBlank then
      local b0 = stats.firstBlank
      local p = b0.painted
      print(string.format("firstBlank: r=(%.1f,%.1f,%.1f,%.1f) painted=(%.1f,%.1f,%.1f,%.1f) ready=%s",
        b0.r.l, b0.r.t, b0.r.r, b0.r.b,
        p and p.left or -1, p and p.top or -1, p and p.right or -1, p and p.bottom or -1,
        tostring(b0.ready)))
    end
    assert(stats.samples > 0, "no scroll samples recorded")
    assert_eq(0, stats.badSamples, "detected blank cards during scroll")
  end)
end)
