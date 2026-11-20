const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
function load(name,imports={}) {
  const mod={exports:{}};
  const source=fs.readFileSync(path.resolve(__dirname,'../dist',name+'.test.cjs'),'utf8');
  new Function('module','exports','require',source)(mod,mod.exports,n=>imports[n]??{});
  return mod.exports;
}
const image=load('image_attachments');
let confirmed=true;
const notices=[];
const {MissionControlPanel}=load('mission_control_attachments',{
  '../design/html':load('html_attachments'),
  '../image_attachments':image,
  '../design/icons':{icons:new Proxy({},{get:()=>()=>''})},
  '../design/modal':{confirmModal:async()=>confirmed},
  '../design/notice':{notice:(message)=>notices.push(message)},
});
const {CoreApi}=load('core_api_attachments');
function panel() {
  const p=Object.create(MissionControlPanel.prototype);
  Object.assign(p,{attachments:[],attachError:'',attachQueue:Promise.resolve(),attachmentReads:0});
  p.renderChips=()=>{};
  p.container={querySelector:()=>null};
  return p;
}
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==','base64');
const file=()=>Object.assign(new Blob([png],{type:'image/png'}),{name:'test.png'});
global.createImageBitmap=async()=>({width:1,height:1,close(){}});
(async()=>{
  let checks=0;
  const p=panel();await p.attachFiles([file()]);
  assert.equal(p.attachments.length,1);assert.equal(p.attachments[0].mime,'image/png');checks++;console.log('ok compositor acepta imagen validada');
  await Promise.all([p.attachFiles([file(),file()]),p.attachFiles([file(),file()])]);
  assert.equal(p.attachments.length,4);assert.match(p.attachError,/4 imágenes/);assert.equal(p.attachmentReads,0);checks++;console.log('ok lecturas concurrentes respetan cuatro');
  const corrupt=Object.assign(new Blob(['no PNG'],{type:'image/png'}),{name:'fake.png'});
  const rejected=panel();await rejected.attachFiles([corrupt]);assert.equal(rejected.attachments.length,0);assert.match(rejected.attachError,/PNG, JPEG o WebP/);checks++;console.log('ok archivo renombrado rechazado con error visible');
  const text=Object.assign(new Blob(['hola'],{type:'text/plain'}),{name:'contexto.txt'});
  await rejected.attachFiles([text]);assert.equal(rejected.attachments[0].content,'hola');checks++;console.log('ok adjunto de texto existente preservado');
  const selected=panel();confirmed=false;
  assert.equal(await selected.attachPickedElement(file(),'#button'),false);assert.equal(selected.attachments.length,0);checks++;console.log('ok selección cancelada no adjunta');
  confirmed=true;assert.equal(await selected.attachPickedElement(file(),'#button'),true);assert.equal(selected.attachments.length,1);assert.match(selected.attachments[0].elementContext,/elemento señalado/);checks++;console.log('ok selección confirmada adjunta captura y contexto');
  await selected.attachPickedElement(file(),'x'.repeat(16385));assert.equal(selected.attachments.length,1);assert.match(selected.attachError,/contexto/);checks++;console.log('ok contexto de página acotado');
  await Promise.all(Array.from({length:4},()=>selected.attachPickedElement(file(),'#other')));
  assert.equal(selected.attachments.length,4);assert.equal(selected.attachmentReads,0);assert.match(selected.attachError,/4 imágenes/);checks++;console.log('ok capturas concurrentes respetan cuatro');
  function element() { return {value:'',style:{},dataset:{},listeners:{},addEventListener(n,fn){this.listeners[n]=fn;},focus(){},click(){this.clicked=true;}}; }
  const input=element(),send=element(),drop=element(),picker=element(),button=element();
  const elements={'#mission-composer-input':input,'#btn-mission-send':send,'#mission-composer':drop,'#composer-file-input':picker,'#btn-composer-attach':button};
  const bound=panel();bound.phase='idle';bound.hooks={};bound.core=null;
  bound.container={querySelector:s=>elements[s]??null,addEventListener(){}};
  bound.bindShell();
  button.listeners.click();assert.equal(picker.clicked,true);checks++;console.log('ok botón abre selector de archivo');
  picker.files=[file()];picker.listeners.change();await bound.attachQueue;
  input.listeners.paste({clipboardData:{files:[file()]},preventDefault(){}});await bound.attachQueue;
  drop.listeners.drop({dataTransfer:{files:[file()]},preventDefault(){}});await bound.attachQueue;
  assert.equal(bound.attachments.length,3);checks++;console.log('ok elegir pegar y arrastrar llegan al validador');
  let requestText,requestAttachments;bound.submit=async(text,display,attachments)=>{requestText=text;requestAttachments=attachments;};
  input.value='haz este botón rojo';send.listeners.click();assert.equal(requestText,'haz este botón rojo');assert.equal(requestAttachments.length,3);assert.ok(!requestText.includes('data_base64'));checks++;console.log('ok envío separa imágenes del prompt');
  bound.attachmentReads=1;requestText=null;input.value='espera';send.listeners.click();assert.equal(requestText,null);assert.equal(input.value,'espera');assert.match(notices.at(-1),/validación/);checks++;console.log('ok envío espera las lecturas pendientes');
  const remove=element();remove.dataset.rm='0';const chips=element();chips.querySelectorAll=()=>[remove];
  const removable=panel();removable.attachments=[{...selected.attachments[0],name:'<img onerror=evil>'}];
  removable.container={querySelector:()=>chips};MissionControlPanel.prototype.renderChips.call(removable);
  assert.ok(chips.innerHTML.includes('&lt;img'));remove.listeners.click();assert.equal(removable.attachments.length,0);checks++;console.log('ok chip escapa nombres y quitar elimina imagen y contexto');
  const submitted=panel();submitted.phase='idle';submitted.orderEpoch=0;submitted.pinnedRoles={plan:''};submitted.turns=[];
  submitted.attachments=[selected.attachments[0]];submitted.setPhase=()=>{};submitted.toggleCancel=()=>{};submitted.isPlanningEpoch=()=>true;
  submitted.fail=e=>{submitted.error=e;};submitted.renderBody=()=>{};submitted.waitForPlan=async()=>{};
  submitted.showConfiguration=()=>{};submitted.core={orderPreflight:async()=>({allowed:true,issues:[],message:''}),submitOrder:async()=>{throw new Error('rechazado por motor');}};
  await submitted.submit('hazlo',undefined,submitted.attachments.slice());assert.equal(submitted.attachments.length,1);assert.match(submitted.error,/rechazado/);checks++;console.log('ok rechazo motor conserva la imagen');
  submitted.showConfiguration=()=>{};submitted.core={orderPreflight:async()=>({allowed:true,issues:[],message:''}),submitOrder:async()=>({orderId:42})};await submitted.submit('hazlo',undefined,submitted.attachments.slice());assert.equal(submitted.attachments.length,0);checks++;console.log('ok aceptación motor consume adjuntos enviados');
  const api=Object.create(CoreApi.prototype);let request;
  api.call=(method,params)=>{request={method,params};return Promise.resolve({orderId:1});};
  await api.submitOrder('hazlo','default','conversation',{attachments:[{name:'test.png',data_base64:'YWJj'}]});
  assert.equal(request.method,'core.order.submit');assert.deepEqual(request.params.attachments,[{name:'test.png',data_base64:'YWJj'}]);checks++;console.log('ok adjuntos viajan separados del texto en el puente');
  console.log(`${checks} checks PASS`);
})().catch(e=>{console.error(e);process.exitCode=1;});
