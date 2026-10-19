// Verify the real gallery's initialization lifecycle without a browser/GPU.
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=await readFile(new URL('../../static/gallery.js',import.meta.url),'utf8');
function boot(options={}) {
 const listeners=[];
 const media=()=>({matches:false,addEventListener(){}});
 const sandbox={
  isSecureContext:true,
  localStorage:{getItem(){return null}},
  document:{addEventListener(name,fn){if(name==='DOMContentLoaded')listeners.push(fn)},
   getElementById(){return {}},documentElement:{setAttribute(){},classList:{remove(){},contains(){return false}}}},
  ResizeObserver:class {observe(){} disconnect(){}},
  matchMedia:media,addEventListener(){},requestAnimationFrame(){},
  console:{error(){}},...options,
 };
 sandbox.window=sandbox;
 const context=vm.createContext(sandbox);
 vm.runInContext(source,context);
 const initialize=listeners.find(fn=>fn.toString().includes('isSecureContext'));
 assert.ok(initialize,'initialization callback found');
 return {context,initialize};
}
for(const [options,reason] of [
 [{isSecureContext:false},/HTTPS or localhost/],
 [{},/ImageDecoder is unavailable/],
 [{ImageDecoder:{async isTypeSupported(){return false}}},/does not support image\/webp/],
]) {
 const {context,initialize}=boot(options);
 assert.equal(context.booruPreviewSnapshot().state,'starting');
 await initialize();
 const snapshot=context.booruPreviewSnapshot();
 assert.equal(snapshot.state,'failed');
 assert.match(snapshot.error,reason);
 assert.equal(snapshot.active,false);
}
let finish;
const {context,initialize}=boot({ImageDecoder:{isTypeSupported(){return new Promise(r=>{finish=r})}}});
const pending=initialize();
assert.equal(context.booruPreviewSnapshot().state,'starting','async capability check is not a failure');
finish(false);await pending;
assert.equal(context.booruPreviewSnapshot().state,'failed');
assert.match(context.booruPreviewSnapshot().error,/does not support/);
console.log('PASS: real gallery async startup lifecycle and secure-context/API/codec failure reasons');
