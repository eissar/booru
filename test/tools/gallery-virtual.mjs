// Standalone browser regression for virtualized masonry.
// Run: node test/tools/gallery-virtual.mjs (CHROME_BIN overrides chromium).
//
// The real gallery runs in an iframe; resizing the iframe drives breakpoints. A sweep scrolls
// the whole gallery and checks, from what is rendered at each step:
// - only a bounded subset of cards is rendered, and it covers the viewport
// - cards never move while scrolling
// - every card shows up, in the column the masonry rule picks, directly below
//   the previous card in that column
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const N = 500;
const height = (i) => 300 + (i * 37) % 900; // width 600: ratio in [0.5, 2), no clamping
const card = (i) => `<article class="masonry-item group" data-image-id="${i}" data-render-order-id="${i}">`
 + '<div class="gallery-card relative overflow-hidden flex flex-col rounded-lg hover-card"><div class="gallery-card-slot order-2">'
 + `<div class="gallery-card-meta block p-4 w-full peer" hx-get="/fragment/inspect/${i}"><span class="font-medium truncate">${i}</span></div></div>`
 + `<img width="600" height="${height(i)}" style="aspect-ratio: 600/${height(i)}" class="gallery-card-image order-1"></div></article>`;
const gallery = `<!doctype html><html><head><link rel="stylesheet" href="/static/tailwind.css"><link rel="stylesheet" href="/static/gallery.css">
<style>html,body{margin:0;height:100%} #inspector{width:0} #inspector.open{width:240px}</style></head><body>
<input type="radio" name="gallery-view" id="gallery-view-masonry" value="masonry" checked>
<input type="radio" name="gallery-view" id="gallery-view-grid" value="grid">
<div class="layout" style="height:100%"><section class="main-content"><div id="photo-grid" class="masonry-grid">
${Array.from({length: N}, (_, i) => card(i)).join('')}<div id="pagination-controls"></div></div></section><aside id="inspector"></aside></div>
<canvas id="thumbnail-background"></canvas><script src="/static/gallery.js"></script></body></html>`;

const harness = `<!doctype html><html><body style="margin:0">
<iframe style="border:0;width:1280px;height:900px"></iframe>
<script>
const N = ${N}, height = ${height}, card = ${card};
const f = document.querySelector('iframe');
const assert = (ok, msg) => { if (!ok) throw Error(msg); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => f.contentWindow.requestAnimationFrame(() => f.contentWindow.requestAnimationFrame(() => setTimeout(r, 20))));
const doc = () => f.contentDocument;
const port = () => doc().querySelector('.main-content');
const grid = () => doc().getElementById('photo-grid');
const cards = () => grid().querySelectorAll('.masonry-item');
const rendered = () => [...cards()].filter((el) => el.getClientRects().length);
const card0 = () => grid().querySelector('[data-image-id="0"]');
const fire = (type, detail) => doc().dispatchEvent(new CustomEvent(type, {bubbles: true, detail}));
async function load(width = 1280, h = 900) {
 f.style.width = width + 'px'; f.style.height = h + 'px';
 await new Promise((r) => { f.onload = r; f.src = '/gallery?' + Math.random(); });
 await frame();
}
async function resize(width, h = 900) { f.style.width = width + 'px'; f.style.height = h + 'px'; await sleep(200); await frame(); }

// Viewport and card boxes in grid coordinates.
function viewport() {
 const p = port(), top = p.getBoundingClientRect().top + p.clientTop - grid().getBoundingClientRect().top;
 return [top, top + p.clientHeight];
}
function boxes() {
 const g = grid().getBoundingClientRect(), out = new Map();
 for (const el of rendered()) {
  const r = el.getBoundingClientRect();
  if (r.height) out.set(Number(el.dataset.imageId), [r.left - g.left, r.top - g.top, r.height]);
 }
 return out;
}
function assertCovered(layout, label) {
 const [lo, hi] = viewport(), here = boxes();
 for (const [id, [, top, h]] of layout) if (top < hi && top + h > lo) assert(here.has(id), label + ': visible card ' + id + ' not rendered');
}

async function sweep(ids, label) {
 const layout = new Map(), steps = [];
 for (let y = 0; ; y += port().clientHeight / 2) {
  port().scrollTop = y;
  await frame();
  const here = boxes();
  assert(rendered().length < ids.length, label + ': ' + rendered().length + ' of ' + ids.length + ' cards rendered');
  for (const [id, box] of here) {
   const seen = layout.get(id);
   assert(!seen || seen.every((v, k) => Math.abs(v - box[k]) < 0.5), label + ': card ' + id + ' moved while scrolling');
   layout.set(id, box);
  }
  steps.push([viewport(), here]);
  if (port().scrollTop + port().clientHeight >= port().scrollHeight - 1) break;
 }
 assert(layout.size === ids.length, label + ': saw ' + layout.size + ' of ' + ids.length + ' cards');
 for (const [[lo, hi], here] of steps)
  for (const [id, [, top, h]] of layout) if (top < hi && top + h > lo) assert(here.has(id), label + ': visible card ' + id + ' not rendered');

 const columns = Number(getComputedStyle(grid()).getPropertyValue('--masonry-columns'));
 const gap = parseFloat(getComputedStyle(grid()).columnGap);
 const lefts = [...new Set([...layout.values()].map((b) => Math.round(b[0])))].sort((a, b) => a - b);
 assert(lefts.length === columns, label + ': ' + lefts.length + ' column positions for ' + columns + ' columns');
 const weight = Array(columns).fill(0), bottom = Array(columns).fill(-gap);
 for (const id of ids) {
  let s = 0;
  for (let j = 1; j < columns; j++) if (weight[j] < weight[s]) s = j;
  const [left, top, h] = layout.get(id);
  assert(Math.round(left) === lefts[s], label + ': card ' + id + ' not in column ' + s);
  assert(Math.abs(top - bottom[s] - gap) < 1, label + ': card ' + id + ' at ' + top + ', expected ' + (bottom[s] + gap));
  weight[s] += height(id) / 600;
  bottom[s] = top + h;
 }
 const end = grid().getBoundingClientRect().height, tallest = Math.max(...bottom);
 assert(end >= tallest && end <= tallest + gap + 1, label + ': grid height ' + end + ' for content ending at ' + tallest);
 return layout;
}

function topCard() {
 const [lo, hi] = viewport();
 const [id, box] = [...boxes()].filter(([, b]) => b[1] >= lo && b[1] < hi).sort((a, b) => a[1][1] - b[1][1])[0];
 return [id, box[1] - lo];
}
const ids = (n) => Array.from({length: n}, (_, i) => i);

const sections = [
 ['scroll at 5 columns', async () => { await load(); await sweep(ids(N), '1280'); }],
 ['far cards stop rendering and come back as the same node', async () => {
  await load();
  const node = card0();
  port().scrollTop = port().scrollHeight; await frame();
  assert(!node.getClientRects().length, 'card 0 still rendered at the end');
  port().scrollTop = 0; await frame();
  assert(card0() === node, 'card 0 came back as a different node');
 }],
 ['resize keeps the top visible card in place, then relayouts', async () => {
  await load();
  port().scrollTop = port().scrollHeight / 2; await frame();
  for (const width of [1100, 1200]) {
   const [id, offset] = topCard();
   await resize(width);
   const now = boxes().get(id);
   assert(now && Math.abs(now[1] - viewport()[0] - offset) < 1, 'card ' + id + ' moved from ' + offset + ' after resize to ' + width);
  }
  await sweep(ids(N), '1280->1100->1200');
 }],
 ['container narrows without a window resize', async () => {
  await load();
  doc().getElementById('inspector').classList.add('open'); await frame();
  await sweep(ids(N), 'inspector open');
 }],
 ['taller viewport renders newly visible cards without scrolling', async () => {
  await load(1280, 600);
  const layout = await sweep(ids(N), '600 tall');
  port().scrollTop = port().scrollHeight / 2; await frame();
  await resize(1280, 1400);
  assertCovered(layout, '600->1400 tall');
 }],
 ['grid view renders every card; masonry returns', async () => {
  await load();
  doc().getElementById('gallery-view-grid').click(); await frame();
  assert(rendered().length === N, 'grid view: ' + rendered().length + ' of ' + N + ' rendered');
  doc().getElementById('gallery-view-masonry').click(); await frame();
  await sweep(ids(N), 'back to masonry');
 }],
 ['htmx requests see every card; append keeps scroll', async () => {
  await load();
  port().scrollTop = port().scrollHeight / 2; await frame();
  const before = port().scrollTop;
  fire('htmx:beforeRequest');
  assert(cards().length === N, 'during request: ' + cards().length + ' of ' + N + ' in the DOM');
  fire('htmx:afterRequest', {successful: true}); fire('htmx:beforeSwap');
  doc().getElementById('pagination-controls').insertAdjacentHTML('beforebegin', card(N));
  fire('htmx:afterSettle'); await frame();
  assert(Math.abs(port().scrollTop - before) < 1, 'append moved scroll from ' + before + ' to ' + port().scrollTop);
  await sweep(ids(N + 1), 'after append');
 }],
 ['failed request returns to masonry', async () => {
  await load();
  fire('htmx:beforeRequest'); fire('htmx:afterRequest', {successful: false}); await frame();
  await sweep(ids(N), 'after failed request');
 }],
];

(async () => {
 const lines = [];
 for (const [name, run] of sections) {
  try { await run(); lines.push('PASS: ' + name); }
  catch (e) { lines.push('FAIL: ' + name + ': ' + e.message); }
 }
 document.body.dataset.result = lines.join('\\n');
})();
</script></body></html>`;

const server = createServer(async (req, res) => {
 const file = req.url.match(/^\/static\/(gallery\.js|gallery\.css|tailwind\.css)$/)?.[1];
 if (file) {
  res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : 'text/css');
  res.end(await readFile(new URL('../../static/' + file, import.meta.url)));
 } else { res.setHeader('Content-Type', 'text/html'); res.end(req.url.startsWith('/gallery') ? gallery : harness); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const profile = await mkdtemp(`${tmpdir()}/booru-virtual-`);
let result;
try {
 const proc = spawn(process.env.CHROME_BIN || 'chromium', [
  '--headless', '--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  '--disable-dev-shm-usage', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank']);
 let errors = ''; proc.stderr.on('data', (d) => errors += d);
 const timer = setTimeout(() => proc.kill('SIGKILL'), 180000);
 let socket;
 try {
  let port;
  for (let i = 0; i < 100 && !port; i++) {
   try { port = Number((await readFile(`${profile}/DevToolsActivePort`, 'utf8')).split('\n')[0]); }
   catch { await new Promise((r) => setTimeout(r, 50)); }
  }
  if (!port) throw Error(errors || 'No debugging port');
  const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page');
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { socket.onopen = r; socket.onerror = j; });
  let id = 0;
  const evaluate = (expression) => new Promise((resolve) => {
   const current = ++id;
   const listener = (e) => { const msg = JSON.parse(e.data); if (msg.id === current) { socket.removeEventListener('message', listener); resolve(msg.result?.result?.value); } };
   socket.addEventListener('message', listener);
   socket.send(JSON.stringify({id: current, method: 'Runtime.evaluate', params: {expression, returnByValue: true}}));
  });
  socket.send(JSON.stringify({id: ++id, method: 'Page.navigate', params: {url: `http://127.0.0.1:${server.address().port}/`}}));
  for (let i = 0; i < 1500 && !result; i++) {
   result = await evaluate('document.body?.dataset.result');
   if (!result) await new Promise((r) => setTimeout(r, 100));
  }
 } finally { clearTimeout(timer); socket?.close(); if (proc.exitCode === null && proc.signalCode === null) { proc.kill(); await new Promise((r) => proc.once('close', r)); } }
} finally { server.close(); await rm(profile, {recursive: true, force: true}); }
console.log(result || 'FAIL: no result');
process.exit(result && !result.includes('FAIL') ? 0 : 1);
