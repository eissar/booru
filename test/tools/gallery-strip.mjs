// Standalone browser regression for the rolling preview surface.
// Run: node test/tools/gallery-strip.mjs (CHROME_BIN overrides chromium).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { mkdtemp, rm } from 'node:fs/promises';

const js = await readFile(new URL('../../static/gallery.js', import.meta.url));
const css = await readFile(new URL('../../static/gallery.css', import.meta.url));
const benchmark = await readFile(new URL('../../static/benchmark.html', import.meta.url));
const html = `<!doctype html><html><head><style>
${css}
html,body { margin:0; height:100%; } .main-content { height:400px; width:600px; overflow:auto; }
#photo-grid { display:block; width:100%; } .masonry-item { height:200px; }
.gallery-card { height:200px; overflow:hidden; } .gallery-card-image { width:100px; height:180px; }
</style><script>
// Exercise the real upload/draw path without a server-side library or decoder.
window.ImageDecoder = class {
 static async isTypeSupported() { return true; }
 constructor() { this.complete=true; this.completed=Promise.resolve();
 this.tracks={ready:Promise.resolve(),selectedTrack:{frameCount:40}}; }
 async decode() { const image=document.createElement('canvas'); image.width=image.height=64;
 image.displayWidth=image.displayHeight=64; image.close=()=>{};
 const c=image.getContext('2d'); c.fillStyle='red'; c.fillRect(0,0,64,64); return {image}; }
 close() {}
};
</script><script src='/static/gallery.js'></script></head><body>
<input type=radio name=gallery-view value=grid checked>
<main id=gallery-main><section class=main-content><div id=photo-grid>
${Array.from({length:40}, (_,i)=>`<article class=masonry-item data-render-order-id='${i}' data-image-id='${i}'><div class=gallery-card><img class=gallery-card-image width=100 height=180></div></article>`).join('')}
</div></section></main><canvas id=thumbnail-background></canvas>
<script>
addEventListener('DOMContentLoaded', async () => {
 const wait=()=>new Promise(r=>setTimeout(r,100));
 const assert=(ok,msg)=>{if(!ok)throw Error(msg)};
 try {
 for(let i=0;i<20 && !document.querySelector('.gallery-preview-surface');i++)await wait();
 const canvas=document.querySelector('canvas#thumbnail-background');
 const port=document.querySelector('.main-content'); const grid=document.querySelector('#photo-grid');
 assert(canvas.parentElement?.className==='gallery-preview-surface','canvas not attached');
 assert(canvas.closest('#photo-grid')===grid,'canvas outside scroll content');
 const h=port.clientHeight; assert(parseFloat(canvas.style.height)===7*h,'not seven heights');
 assert(parseFloat(canvas.style.top)===-3*h,'not three heights above');
 assert(port.scrollHeight===8000,'strip extended content height: '+port.scrollHeight);
 const startTop=canvas.style.top; const before=canvas.getBoundingClientRect().top;
 port.scrollTop=200; await wait();
 assert(canvas.style.top===startTop,'ordinary scroll rebased strip');
 assert(Math.abs(canvas.getBoundingClientRect().top-(before-200))<1,'canvas did not scroll with cards');
 port.scrollTop=3000; await wait();
 assert(parseFloat(canvas.style.top)===3000-3*h,'jump did not recenter: '+canvas.style.top+' scroll='+port.scrollTop);
 port.style.height='300px'; dispatchEvent(new Event('resize')); await wait();
 assert(parseFloat(canvas.style.height)===7*port.clientHeight,'resize did not resize strip');
 const replacement=grid.cloneNode(true); replacement.querySelector('.gallery-preview-surface').remove();
 grid.replaceWith(replacement);
 document.dispatchEvent(new CustomEvent('htmx:afterSwap',{detail:{xhr:{responseURL:location.origin+'/fragment/gallery-content'}}}));
 await wait();
 assert(canvas.closest('#photo-grid')===replacement,'swap lost canvas');
 assert(document.querySelectorAll('#thumbnail-background').length===1,'duplicate canvas');
 document.body.dataset.result='PASS';
 } catch(e) { document.body.dataset.result='FAIL: '+e.message; }
});
</script></body></html>`;
const server = createServer((req,res)=>{
 if(req.url==='/static/gallery.js'){res.setHeader('Content-Type','text/javascript');res.end(js);}
 else if(req.url.startsWith('/mipmap/')){res.end('test');}
 else if(req.url.startsWith('/static/benchmark.html')){res.setHeader('Content-Type','text/html');res.end(benchmark);}
 else {res.setHeader('Content-Type','text/html');res.end(html);}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const profile=await mkdtemp(`${tmpdir()}/booru-strip-`);
try {
 const proc=spawn(process.env.CHROME_BIN || 'chromium', [
 '--headless','--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader',
 '--disable-dev-shm-usage',`--user-data-dir=${profile}`,'--remote-debugging-port=0',
 'about:blank']);
 let errors=''; proc.stderr.on('data',d=>errors+=d);
 const timer=setTimeout(()=>proc.kill('SIGKILL'),30000);
 let socket;
 try {
  let port;
  for(let i=0;i<100;i++) {
   try { port=Number((await readFile(`${profile}/DevToolsActivePort`,'utf8')).split('\n')[0]);break; }
   catch { await new Promise(r=>setTimeout(r,50)); }
  }
  if(!port)throw Error(errors || 'No debugging port');
  const targets=await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page=targets.find(t=>t.type==='page');
  socket=new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r,j)=>{socket.onopen=r;socket.onerror=j});
  await new Promise(r=>setTimeout(r,300));
  let id=0;
  socket.send(JSON.stringify({id:++id,method:'Runtime.enable'}));
  const evaluate=expression=>new Promise((resolve,reject)=>{
   const current=++id;
   const deadline=setTimeout(()=>{socket.removeEventListener('message',listener);reject(Error('CDP evaluation timed out: '+expression+'\n'+errors))},5000);
   const listener=e=>{const msg=JSON.parse(e.data);if(msg.id===current){clearTimeout(deadline);socket.removeEventListener('message',listener);if(msg.error || msg.result?.exceptionDetails)reject(Error(JSON.stringify(msg)));else resolve(msg.result?.result?.value)}};
   socket.addEventListener('message',listener);
   socket.send(JSON.stringify({id:current,method:'Runtime.evaluate',params:{expression,returnByValue:true}}));
  });
  socket.send(JSON.stringify({id:++id,method:'Page.navigate',params:{url:`http://127.0.0.1:${server.address().port}/`}}));
  let result;
  for(let i=0;i<150;i++) {
   result=await evaluate('document.body?.dataset.result');
   if(result)break;
   await new Promise(r=>setTimeout(r,100));
  }
  if(result!=='PASS')throw Error(result || JSON.stringify(await evaluate('({state:document.readyState,html:document.body?.outerHTML.slice(-1200),url:location.href})')) || errors);
  console.log('PASS: seven-height strip, compositor-relative scroll, rebase, resize, htmx replacement');
  socket.send(JSON.stringify({id:++id,method:'Page.navigate',params:{url:`http://127.0.0.1:${server.address().port}/static/benchmark.html`}}));
  let overlay;
  for(let i=0;i<100;i++) {
   overlay=await evaluate(`(() => { const f=document.querySelector('#gallery'); if(!f)return null;
    return {counts:document.querySelector('#counts').textContent,
      samples:document.querySelector('#samples').textContent,
      status:document.querySelector('#status').textContent,
      hook:typeof f.contentWindow?.booruPreviewSnapshot}; })()`);
   if(overlay?.hook==='function' && overlay.counts!=='—')break;
   await new Promise(r=>setTimeout(r,100));
  }
  if(overlay?.hook!=='function' || !/^\d+ \/ \d+$/.test(overlay.counts))
    throw Error('Overlay did not sample live gallery: '+JSON.stringify(overlay));
  console.log('PASS: benchmark iframe loads real client and samples coverage diagnostics');
  // Let the fixture's automatic scroll/swap sequence finish, then isolate the
  // counter test: idle must not grow the denominator or count warmup blanks.
  for(let i=0;i<50;i++) {
    if(await evaluate(`document.querySelector('#gallery').contentDocument.body.dataset.result === 'PASS'`))break;
    await new Promise(r=>setTimeout(r,100));
  }
  await evaluate(`document.querySelector('#reset').click()`);
  await new Promise(r=>setTimeout(r,500));
  const idle=await evaluate(`document.querySelector('#samples').textContent`);
  if(idle!=='0 / 0')throw Error('Idle or warmup counted: '+idle);
  await evaluate(`(() => { const w=document.querySelector('#gallery').contentWindow;
    const snapshot=w.booruPreviewSnapshot;
    w.booruPreviewSnapshot=()=>{const s=snapshot();return {...s,images:s.images.map(i=>({...i,painted:null}))}};
    w.document.querySelector('.main-content').scrollTop += 100;
  })()`);
  await new Promise(r=>setTimeout(r,250));
  const bad=await evaluate(`document.querySelector('#samples').textContent`);
  if(bad!=='1 / 1')throw Error('Missing submitted previews not counted exactly once: '+bad+' '+await evaluate(`JSON.stringify({status:document.querySelector('#status').textContent,counts:document.querySelector('#counts').textContent,snapshot:document.querySelector('#gallery').contentWindow.booruPreviewSnapshot().images.map(i=>({ready:i.ready,painted:i.painted})).slice(0,2)})`));
  await new Promise(r=>setTimeout(r,300));
  if(await evaluate(`document.querySelector('#samples').textContent`)!==bad)
    throw Error('Idle inflated scroll samples');
  await evaluate(`(() => {const w=document.querySelector('#gallery').contentWindow;
    const snapshot=w.booruPreviewSnapshot;
    w.booruPreviewSnapshot=()=>({...snapshot(),active:false});})()`);
  await new Promise(r=>setTimeout(r,250));
  const failure=await evaluate(`document.querySelector('#status').textContent`);
  if(!failure.startsWith('FAILED: Benchmark invariant: renderer reports active but preview surface is disabled'))
    throw Error('Renderer failure did not panic: '+failure);
  console.log('PASS: idle/warmup excluded, undrawn previews counted, idle denominator stable, renderer failure panics');
 } finally { clearTimeout(timer);socket?.close();if(proc.exitCode===null && proc.signalCode===null){proc.kill();await new Promise(r=>proc.once('close',r));} }
} finally {server.close();await rm(profile,{recursive:true,force:true});}
