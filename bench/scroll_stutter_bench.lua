local target_url = os.getenv("GALLERY_URL")
local TARGET_CLEAN_SPEED = tonumber(os.getenv("TARGET_SPEED")) or 200000

local function build_fixture_html()
  local N = 1000
  local cards = {}
  for i = 1, N do
    local h = 300 + ((i - 1) * 37) % 900
    local media
    if i % 5 == 0 then
      media = string.format(
        '<video src="/image/%d" preload="none" muted loop playsinline width="600" height="%d" style="aspect-ratio: 600/%d" class="gallery-card-image order-1"></video>',
        i, h, h
      )
    else
      media = string.format(
        '<img src="/image/%d" loading="lazy" width="600" height="%d" style="aspect-ratio: 600/%d" class="gallery-card-image order-1"/>',
        i, h, h
      )
    end
    cards[i] = string.format(
      '<article class="masonry-item group" data-image-id="%d" data-render-order-id="%d">' ..
      '<div class="gallery-card relative overflow-hidden flex flex-col rounded-lg hover-card">' ..
      '<div class="gallery-card-slot order-2"><div class="gallery-card-meta block p-4 w-full peer">' ..
      '<span class="font-medium truncate">item-%d</span></div></div>%s</div></article>',
      i, i - 1, i, media
    )
  end

  return [[<!doctype html><html><head>
<link rel="stylesheet" href="/static/tailwind.css">
<link rel="stylesheet" href="/static/gallery.css">
<style>html,body{margin:0;width:1920px;height:1080px;overflow:hidden} .layout{width:1920px;height:1080px}</style>
<script>
window.ImageDecoder = class {
  static async isTypeSupported() { return true; }
  constructor() {
    this.complete = true;
    this.completed = Promise.resolve();
    this.tracks = { ready: Promise.resolve(), selectedTrack: { frameCount: ]] .. N .. [[ } };
  }
  async decode({ frameIndex } = {}) {
    if (frameIndex >= ]] .. N .. [[) throw new RangeError('end');
    const image = document.createElement('canvas');
    image.width = image.height = 512;
    image.displayWidth = image.displayHeight = 512;
    image.close = () => {};
    const c = image.getContext('2d');
    c.fillStyle = (frameIndex % 5 === 4) ? '#3b82f6' : '#ef4444';
    c.fillRect(0, 0, 512, 512);
    return { image };
  }
  close() {}
};
</script>
<script src="/static/gallery.js"></script>
</head><body>
<input type="radio" name="gallery-view" id="gallery-view-masonry" value="masonry" checked>
<input type="radio" name="gallery-view" id="gallery-view-grid" value="grid">
<div class="layout"><section class="main-content"><div id="photo-grid" class="masonry-grid">]] ..
    table.concat(cards) ..
  [[<div id="pagination-controls"></div></div></section><aside id="inspector"></aside></div>
<canvas id="thumbnail-background"></canvas></body></html>]]
end

describe("scroll-stutter-bench", function()
  local srv, b, nav_path

  before_all(function()
    if target_url and #target_url > 0 then
      b = cdp.open(target_url)
      nav_path = ""
    else
      srv = cdp.server({
        ["/static/gallery.js"]   = { content_type = "text/javascript", body = read_file("static/gallery.js"),   prefix = false },
        ["/static/gallery.css"]  = { content_type = "text/css",        body = read_file("static/gallery.css"),  prefix = false },
        ["/static/tailwind.css"] = { content_type = "text/css",        body = read_file("static/tailwind.css"), prefix = false },
        ["/mipmap/"]             = { content_type = "text/plain",      body = "test",                             prefix = true },
        ["/gallery"]             = { content_type = "text/html",       body = build_fixture_html(),               prefix = false },
      })
      b = cdp.open(srv:url())
      nav_path = "/gallery?limit=1000"
    end
  end)

  after_all(function()
    if b then b:close() end
    if srv then srv:close() end
  end)

  it("holds 60fps across 1000 mixed cards at escalating scroll speeds", function()
    b:navigate(nav_path)

    b:wait_for([[(() => {
      const s = window.booruPreviewSnapshot?.();
      if (!s) return false;
      if (s.state === 'failed') throw new Error('Gallery preview failed: ' + (s.error || 'unknown'));
      const readyCount = s.images.filter(i => i.ready).length;
      return (s.state === 'active' && s.active && s.images.length > 0 && readyCount >= Math.min(s.images.length, 512)) ? true : false;
    })()]], 30000)

    local report = b:eval([[new Promise((resolve, reject) => {
      const port = document.querySelector('.main-content');
      if (!port) return reject(new Error('gallery scrollport missing'));

      const MAX_FRAME_DT_MS = 20.0; // >20ms misses a 60Hz VSync (16.67ms)
      const MIN_FPS = 59.0;
      const MAX_JITTER_MS = 2.0;    // p95dt - p50dt
      const MIN_PASS_MS = 1500;     // ensure every pass runs long enough to catch GC/layout spikes
      const MAX_PASSES = 10;
      const passes = [];
      let speed = 20000;

      const covers = (a, b) =>
        b && b.left <= a.left + 1 && b.top <= a.top + 1 && b.right >= a.right - 1 && b.bottom >= a.bottom - 1;

      const countBlanks = (snap, portClient, sr) => {
        const byImg = new Map(snap.images.map(i => [i.image, i]));
        let blanks = 0;
        for (const el of document.querySelectorAll('.gallery-card-image')) {
          const ir = el.getBoundingClientRect();
          if (ir.width <= 0 || ir.height <= 0) continue;
          const cr = el.closest('.gallery-card')?.getBoundingClientRect() || ir;
          const r = {
            left: Math.max(ir.left, cr.left, portClient.left),
            top: Math.max(ir.top, cr.top, portClient.top),
            right: Math.min(ir.right, cr.right, portClient.right),
            bottom: Math.min(ir.bottom, cr.bottom, portClient.bottom),
          };
          if (r.right <= r.left || r.bottom <= r.top) continue;
          const entry = byImg.get(el);
          const originalReady = el.tagName === 'IMG' && el.complete && el.naturalWidth > 0;
          const p = entry && entry.painted ? {
            left: sr.left + entry.painted.left,
            top: sr.top + entry.painted.top,
            right: sr.left + entry.painted.right,
            bottom: sr.top + entry.painted.bottom,
          } : null;
          if (!originalReady && !(p && covers(r, p))) blanks++;
        }
        return blanks;
      };

      const runPass = (passNum, targetSpeed) => new Promise((done) => {
        port.scrollTop = 0;
        const maxScroll = Math.max(1, port.scrollHeight - port.clientHeight);
        let dir = 1;
        let pos = 0;
        let lastT = null;
        let startT = null;
        let frames = 0;
        let totalDist = 0;
        let maxDt = 0;
        let dropped = 0;
        let totalBlanks = 0;
        const dts = [];

        const step = (now) => {
          const snap = window.booruPreviewSnapshot();
          if (!snap.active) return reject(new Error('renderer became inactive: ' + snap.error));

          if (lastT === null) {
            lastT = now;
            startT = now;
            return requestAnimationFrame(step);
          }

          const dt = now - lastT;
          lastT = now;
          frames++;
          if (frames > 2) {
            dts.push(dt);
            if (dt > maxDt) maxDt = dt;
            if (dt > MAX_FRAME_DT_MS) dropped++;
          }

          const pr = port.getBoundingClientRect();
          const portClient = {
            left: pr.left + port.clientLeft,
            top: pr.top + port.clientTop,
            right: pr.left + port.clientLeft + port.clientWidth,
            bottom: pr.top + port.clientTop + port.clientHeight,
          };
          const sr = snap.canvas.getBoundingClientRect();
          totalBlanks += countBlanks(snap, portClient, sr);

          const delta = (targetSpeed * Math.min(dt, 100)) / 1000;
          if (dir === 1) {
            const next = Math.min(maxScroll, pos + delta);
            totalDist += next - pos;
            pos = next;
            port.scrollTop = pos;
            if (pos >= maxScroll - 1) dir = -1;
          } else {
            const next = Math.max(0, pos - delta);
            totalDist += pos - next;
            pos = next;
            port.scrollTop = pos;
            if (pos <= 1) {
              if (now - startT < MIN_PASS_MS) {
                dir = 1;
              } else {
                const elapsedSec = Math.max(0.001, (now - startT) / 1000);
                const fps = frames / elapsedSec;
                const sorted = [...dts].sort((a, b) => a - b);
                const p50Dt = sorted[Math.floor(sorted.length * 0.50)] || 0;
                const p95Dt = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))] || 0;
                const jitter = Math.max(0, p95Dt - p50Dt);
                const reasons = [];
                if (dropped > 0) reasons.push(`dropped=${dropped} (maxdt=${maxDt.toFixed(1)}ms)`);
                if (fps < MIN_FPS) reasons.push(`fps=${fps.toFixed(1)}<${MIN_FPS}`);
                if (jitter > MAX_JITTER_MS) reasons.push(`jitter=${jitter.toFixed(1)}ms>${MAX_JITTER_MS}ms`);
                return done({
                  pass: passNum,
                  targetSpeed: Math.round(targetSpeed),
                  actualSpeed: Math.round(totalDist / elapsedSec),
                  fps: Math.round(fps * 10) / 10,
                  p50Dt: Math.round(p50Dt * 10) / 10,
                  p95Dt: Math.round(p95Dt * 10) / 10,
                  maxDt: Math.round(maxDt * 10) / 10,
                  jitter: Math.round(jitter * 10) / 10,
                  dropped,
                  blanks: totalBlanks,
                  stuttered: reasons.length > 0,
                  reason: reasons.length > 0 ? reasons.join(', ') : 'ok',
                });
              }
            }
          }
          requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      });

      (async () => {
        let maxCleanSpeed = 0;
        let maxCleanFps = 0;
        for (let p = 1; p <= MAX_PASSES; p++) {
          const res = await runPass(p, speed);
          passes.push(res);
          if (res.stuttered) break;
          maxCleanSpeed = res.actualSpeed;
          maxCleanFps = res.fps;
          speed = Math.round(speed * 1.5);
        }
        resolve({ passes, maxCleanSpeed, maxCleanFps, scrollHeight: port.scrollHeight });
      })().catch(reject);
    })]])

    print(string.format("STUTTER BENCH (1000 mixed cards, 1920x1080, 512px textures, scrollHeight=%dpx):", report.scrollHeight))
    for _, p in ipairs(report.passes) do
      print(string.format(
        "  pass=%2d target=%6dpx/s actual=%6dpx/s fps=%5.1f p50=%4.1fms p95=%4.1fms max=%5.1fms jitter=%4.1fms dropped=%d blanks=%d [%s]",
        p.pass, p.targetSpeed, p.actualSpeed, p.fps, p.p50Dt, p.p95Dt, p.maxDt, p.jitter, p.dropped, p.blanks, p.reason
      ))
    end
    print(string.format("SUMMARY: maxCleanSpeed=%dpx/s (target>=%dpx/s) maxCleanFps=%.1f",
      report.maxCleanSpeed, TARGET_CLEAN_SPEED, report.maxCleanFps))

    assert(report.maxCleanSpeed >= TARGET_CLEAN_SPEED,
      string.format("stuttered before target speed: maxCleanSpeed=%dpx/s < %dpx/s",
        report.maxCleanSpeed, TARGET_CLEAN_SPEED))
  end)
end)
