// Deterministic regression of the actual benchmark script, without a GPU.
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html = await readFile(new URL('../../static/benchmark.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
let now = 0, callbacks = [];
function element() {
  return { textContent: '', value: '', style: {}, checked: false, listeners: {},
    addEventListener(name, fn) { this.listeners[name] = fn; }, replaceChildren() {},
    getAttribute(name) { return this[name]; } };
}
const fields = new Map();
for (const id of ['gallery','url','status','boxes','speed','travel','windowSpeed','runway','counts','buffer','worst','samples','areaTime','highlight','reset','go']) fields.set(id, element());
fields.get('url').value = '/gallery';
class Image {}
const img = new Image();
img.complete = false; img.naturalWidth = 0;
const rect = { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 };
img.getBoundingClientRect = () => rect;
const port = { scrollTop: 0, clientWidth: 200, clientHeight: 200, clientTop: 0, clientLeft: 0,
  getBoundingClientRect: () => ({left:0,top:0,right:200,bottom:200}) };
let item = { image: img, ready: true, painted: rect };
let active = true, state = 'starting', error = null;
const child = {
  HTMLImageElement: Image, innerWidth: 200, innerHeight: 200,
  location: { href: 'http://localhost/gallery' }, addEventListener() {},
  document: { querySelector: () => port, querySelectorAll: () => [img], addEventListener() {} },
  booruPreviewSnapshot: () => ({state, error, active, canvas: { isConnected: true,
    getBoundingClientRect: () => ({left:0,top:0,right:200,bottom:1400,width:200,height:1400}) }, images:[item]}),
};
fields.get('gallery').contentWindow = child;
const context = vm.createContext({ URL, URLSearchParams, Map, Number, Math, Error, Array,
  location: {href:'http://localhost/static/benchmark.html',origin:'http://localhost',search:''},
  performance: {now: () => now}, requestAnimationFrame: fn => callbacks.push(fn),
  document: {hidden:false,getElementById:id=>fields.get(id),createElement:element} });
vm.runInContext(script, context);
assert.match(fields.get('gallery').src, /limit=100/);
fields.get('gallery').listeners.load();
function step(time) { now=time; const next=callbacks;callbacks=[];for(const fn of next)fn(); }
step(100);
assert.match(fields.get('status').textContent, /Starting preview renderer/);
assert.equal(fields.get('samples').textContent, '0 / 0');
state = 'active';
step(200); step(300);
assert.equal(fields.get('samples').textContent,'0 / 0','warmup and idle must not count');
port.scrollTop=20; step(400);
assert.equal(fields.get('samples').textContent,'0 / 1','covered scroll counts in denominator only');
item={...item,painted:null}; port.scrollTop=40; step(500);
assert.equal(fields.get('samples').textContent,'1 / 2','resident but undrawn preview is missing');
step(600);step(700);
assert.equal(fields.get('samples').textContent,'1 / 2','idle cannot inflate denominator');
state='failed'; error='ImageDecoder requires HTTPS or localhost'; active=false;
assert.throws(()=>step(800),/Gallery preview failed: ImageDecoder requires HTTPS or localhost/);
assert.match(fields.get('status').textContent,/^FAILED:/);
assert.equal(callbacks.length,0,'panic must stop sampling');
// A renderer that never starts must fail rather than wait forever.
state='starting'; error=null; active=false;
vm.runInContext(script, context);
fields.get('gallery').listeners.load();
assert.throws(()=>step(11000), /preview initialization timed out/);
assert.equal(callbacks.length,0);
console.log('PASS: async startup waits, actionable failure, startup timeout, defaults, coverage and scroll counters');
