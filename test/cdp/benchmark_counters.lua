local gallery_html = [[<!doctype html><html><head><style>
html,body { margin:0; height:100%; }
.main-content { height:200px; width:200px; overflow:auto; }
#photo-grid { height:1000px; }
.gallery-card-image { width:100px; height:100px; display:block; }
#thumbnail-background { position:fixed; top:0; left:0; width:200px; height:1400px; display:block; pointer-events:none; }
</style><script>
window.__benchState = {
  state: 'starting',
  error: null,
  active: true,
  ready: true,
  painted: { left: 0, top: 0, right: 100, bottom: 100 },
};
window.booruPreviewSnapshot = function() {
  const s = window.__benchState;
  return {
    state: s.state,
    error: s.error,
    active: s.active,
    canvas: document.getElementById('thumbnail-background'),
    images: [{
      image: document.querySelector('.gallery-card-image'),
      ready: s.ready,
      painted: s.painted,
    }],
  };
};
</script></head><body>
<main><section class="main-content"><div id="photo-grid">
<img class="gallery-card-image">
</div></section></main>
<canvas id="thumbnail-background"></canvas>
</body></html>]]

describe("benchmark-counters", function()
  local srv, b

  before_all(function()
    srv = cdp.server({
      ["/static/benchmark.html"] = { content_type = "text/html", body = read_file("static/benchmark.html"), prefix = false },
      ["/gallery"]               = { content_type = "text/html", body = gallery_html,                       prefix = true },
    })
    b = cdp.open(srv:url())
  end)

  after_all(function()
    if b then b:close() end
    if srv then srv:close() end
  end)

  it("enforces async startup waits, warmup/idle exclusion, scroll coverage counters, and actionable failure", function()
    b:navigate("/static/benchmark.html")
    assert_match("limit=100", b:eval("document.getElementById('gallery').src"), "default gallery limit")

    b:wait_for([[document.getElementById('status').textContent.includes('Starting preview renderer')]], 3000)
    assert_eq("0 / 0", b:eval("document.getElementById('samples').textContent"), "starting state must not count")

    -- Warmup and idle frames must not count.
    b:eval([[document.getElementById('gallery').contentWindow.__benchState.state = 'active']])
    b:wait_for([[document.getElementById('status').textContent.includes('Armed')]], 3000)
    b:sleep(150)
    assert_eq("0 / 0", b:eval("document.getElementById('samples').textContent"), "warmup and idle must not count")

    -- Covered scroll counts in denominator only.
    b:eval([[document.getElementById('gallery').contentWindow.document.querySelector('.main-content').scrollTop = 20]])
    b:wait_for([[document.getElementById('samples').textContent === '0 / 1']], 3000)

    -- Resident but undrawn preview is missing.
    b:eval([[(() => {
      const cw = document.getElementById('gallery').contentWindow;
      cw.__benchState.painted = null;
      cw.document.querySelector('.main-content').scrollTop = 40;
    })()]])
    b:wait_for([[document.getElementById('samples').textContent === '1 / 2']], 3000)
    assert_eq("1", b:eval("document.getElementById('worst').textContent"), "worst blank count")
    assert_eq("1 / 1", b:eval("document.getElementById('counts').textContent"), "visible / blank counts")

    -- Idle cannot inflate denominator.
    b:sleep(250)
    assert_eq("1 / 2", b:eval("document.getElementById('samples').textContent"), "idle cannot inflate denominator")

    -- Actionable failure stops sampling.
    b:eval([[(() => {
      const s = document.getElementById('gallery').contentWindow.__benchState;
      s.state = 'failed';
      s.error = 'ImageDecoder requires HTTPS or localhost';
      s.active = false;
    })()]])
    b:wait_for([[document.getElementById('status').textContent.startsWith('FAILED:')]], 3000)
    assert_match("Gallery preview failed: ImageDecoder requires HTTPS or localhost", b:eval("document.getElementById('status').textContent"))

    b:sleep(200)
    assert_eq("1 / 2", b:eval("document.getElementById('samples').textContent"), "panic must stop sampling")
  end)

  it("fails on 10s startup timeout rather than waiting forever", function()
    b:navigate("/static/benchmark.html")
    b:wait_for([[document.getElementById('status').textContent.includes('Starting preview renderer')]], 3000)

    -- Offset performance.now() and trigger #go so startupStartedAt uses the controlled clock.
    b:eval([[(() => {
      window.__clockOffset = 0;
      const origNow = performance.now.bind(performance);
      performance.now = () => origNow() + window.__clockOffset;
      document.getElementById('go').click();
    })()]])
    b:wait_for([[(() => {
      const cw = document.getElementById('gallery').contentWindow;
      return cw && typeof cw.booruPreviewSnapshot === 'function';
    })()]], 3000)

    b:eval([[window.__clockOffset = 11000]])
    b:wait_for([[document.getElementById('status').textContent.startsWith('FAILED:')]], 3000)
    assert_match("preview initialization timed out", b:eval("document.getElementById('status').textContent"))
  end)
end)
