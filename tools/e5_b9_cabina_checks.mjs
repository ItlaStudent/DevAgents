import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(new URL('../shell/webui/package.json',import.meta.url));
const {transform}=require('esbuild');
async function load(path,imports={}) {
  const source=await readFile(new URL('../'+path,import.meta.url),'utf8');
  const result=await transform(source,{loader:'ts',format:'cjs',target:'es2020'});
  assert.equal(result.warnings.length,0);
  const mod={exports:{}};new Function('module','exports','require',result.code)(mod,mod.exports,n=>imports[n]||{});return mod.exports;
}
const {CoreApi}=await load('shell/webui/src/bridge/core_api.ts');
let checks=0;const check=(value,name)=>{assert.ok(value,name);checks++;console.log('ok '+name);};
const calls=[];let rejected=false;
const api=new CoreApi({send:async(kind,payload)=>{calls.push({kind,payload});return rejected?{error:'rejected'}:{payload:{ok:true}};}});
for(const [name,args,kind] of [
 ['listWebhooks',[],'core.webhooks.list'],['addWebhook',[{url:'https://example.test',event:'*',format:'json'}],'core.webhooks.add'],
 ['testWebhook',[7],'core.webhooks.test'],['deleteWebhook',[7],'core.webhooks.delete'],
 ['remoteStatus',[],'core.remote.status'],['remoteStart',[0,''],'core.remote.start'],['remoteStop',[],'core.remote.stop'],
]){
 await api[name](...args);check(calls.at(-1).kind===kind,'API '+name+' reaches bridge');
 rejected=true;await assert.rejects(api[name](...args),/rejected/);rejected=false;checks++;console.log('ok API '+name+' surfaces error');
}
const {UnifiedSettingsPanel}=await load('shell/webui/src/panes/settings_memory.ts',{'../design/html':await load('shell/webui/src/design/html.ts'),'../design/icons':{icons:{}},'../design/modal':{confirmModal:async()=>true}});
function attributes(){const values=new Map();return {setAttribute(name,value){values.set(name,String(value));},getAttribute(name){return values.get(name)??null;},removeAttribute(name){values.delete(name);},hasAttribute(name){return values.has(name);}};}
function element(){return {...attributes(),value:'',textContent:'',hidden:false,disabled:false,checked:false,listeners:{},addEventListener(n,fn){this.listeners[n]=fn;}};}
const elements={};
const body={...attributes(),get textContent(){return (this.markup||'').replace(/<[^>]*>/g,'');},set textContent(value){this.markup=String(value);},querySelector:s=>elements[s],querySelectorAll:()=>[],set innerHTML(text){this.markup=text;for(const id of [...text.matchAll(/id="([^"]+)"/g)].map(m=>m[1]))elements['#'+id]=element();if(elements['#remote-port'])elements['#remote-port'].value='0';if(elements['#remote-start'])elements['#remote-start'].disabled=false;if(elements['#webhook-format'])elements['#webhook-format'].value='json';},get innerHTML(){return this.markup;}};
const operations=[];
const core={
 listWebhooks:async()=>[{id:7,url:'https://example.test/<bad>',event:'*',format:'json',has_secret:true}],
 remoteStatus:async()=>({running:false,url:'',pid:0}),
 remoteStart:async(port,origin)=>{operations.push(['start',port,origin]);return {url:'http://127.0.0.1:12345',token:'fixture'};},
 remoteStop:async()=>{operations.push(['stop']);return {running:false,url:'',pid:0};},
 addWebhook:async config=>{operations.push(['add',config]);},
};
const panel=Object.create(UnifiedSettingsPanel.prototype);Object.assign(panel,{core,section:'remote',container:{querySelector:()=>body}});
await panel.renderRemoteSection();
check(body.innerHTML.includes('Avisos salientes')&&body.innerHTML.includes('Acceso remoto'),'settings renders both sections');
check(body.innerHTML.includes('&lt;bad&gt;')&&!body.innerHTML.includes('<bad>'),'external receiver URL escaped');
check(!elements['#webhook-allow-private'].checked && body.innerHTML.includes('Advertencia: permite acceder a loopback'),'private opt-in unchecked with visible warning');
await elements['#remote-start'].listeners.click();
check(operations.at(-1)[0]==='start'&&elements['#remote-token'].value==='fixture','start returns one-time token to password input');
elements['#remote-hide'].listeners.click();check(elements['#remote-token'].value==='','discard erases token');
await elements['#remote-stop'].listeners.click();check(operations.at(-1)[0]==='stop','stop reaches controller');
elements['#webhook-format'].value='ntfy';elements['#webhook-url'].value='https://example.test';elements['#webhook-topic'].value='topic';elements['#webhook-secret'].value='fixture';
elements['#webhook-allow-private'].checked=true;
await elements['#webhook-form'].listeners.submit({preventDefault(){}});
check(operations.at(-1)[1].url==='https://example.test/topic'&&operations.at(-1)[1].format==='ntfy','ntfy preset appends topic');
check(operations.at(-1)[1].allow_private===true,'explicit private opt-in reaches bridge');
elements['#webhook-format'].value='ntfy';elements['#webhook-topic'].value='../escape';
await elements['#webhook-form'].listeners.submit({preventDefault(){}});
check(elements['#webhook-message'].textContent.includes('Topic inválido'),'invalid ntfy topic visible');
core.remoteStart=async()=>{throw new Error('fixture start failure');};await elements['#remote-start'].listeners.click();
check(elements['#remote-message'].textContent.includes('fixture start failure')&&!elements['#remote-start'].disabled,'start error visible and retry enabled');
core.listWebhooks=async()=>{throw new Error('fixture list failure');};await panel.renderRemoteSection();
check(body.textContent.includes('fixture list failure'),'read error visible');
console.log(`${checks} checks, 0 failures`);
