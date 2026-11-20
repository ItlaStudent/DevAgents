const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function activityPanel() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-rel-activity-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'selector.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const pending = new Map();
  let stderr = '';
  child.stderr.on('data', data => { stderr += data; });
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function key(key, code, modifiers = 0) {
    for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key, code: key, windowsVirtualKeyCode: code, modifiers, ...(type === 'keyDown' && key === 'Enter' ? { text: '\r' } : {}) });
    await evaluate('new Promise(resolve => setTimeout(resolve, 30))');
  }
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    {
      // Esperar a que el documento pedido sustituya al about:blank inicial: con
      // solo readyState, la navegación podía llegar después y borrar el estado
      // ya montado (rojos intermitentes del 13 y 14-nov, update_ui y right_cards).
      const deadline = Date.now() + 10000;
      const ready = () => evaluate("location.href!=='about:blank' && document.readyState==='complete' && document.head!==null")
        .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
      while (!await ready()) {
        if (Date.now() >= deadline) throw new Error('Timeout esperando el documento de la prueba');
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    const ts = require('../node_modules/typescript');
    const files = {layout:'src/layout/layout.ts',chat:'src/panes/chat_panel.ts',icons:'src/design/icons.ts',style:'src/design/stylesheet.ts',tokens:'src/design/tokens.ts',html:'src/design/html.ts'};
    const sources = Object.fromEntries(Object.entries(files).map(([name,file]) => {
      const input = fs.readFileSync(name === 'style' && process.env.DEVAGENTS_ACTIVITY_STYLE ? process.env.DEVAGENTS_ACTIVITY_STYLE : path.join(__dirname,'..',file),'utf8');
      const out = ts.transpileModule(input,{reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}});
      assert.equal((out.diagnostics || []).length,0,'Transpilación sin diagnósticos');
      return [name,out.outputText];
    }));
    await send('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:false});
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={'../design/notice':{notice:message=>window.notices.push(message)},'../components/timeline':{Timeline:class {}},'../chat_activity':{},'../file_runtime':{}};
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return mod.exports;}
      window.notices=[];imports['../design/icons']=load('icons');imports['../design/html']=load('html');imports['./tokens']=load('tokens');load('style').injectStylesheet();
      window.layout=load('layout');window.layout.renderLayout(document.body);
      new (load('chat').ChatPanel)(document.getElementById('chat-host'));
      const floating=document.getElementById('right-cards-host');
      floating.innerHTML='<div class="rc-tools"><button class="rc-tool" id="test-windows" data-rc-action="panel">Ventanas</button></div><div class="rc-cards">Entorno y contexto</div>';
      floating.addEventListener('click',e=>{if(e.target.closest('[data-rc-action="panel"]'))window.toggleActivity();});
      window.toggleActivity=window.layout.initPanelToggles();
      window.popouts=[];document.addEventListener('devagents:open-window',e=>window.popouts.push(e.detail));
    })()`);
    async function click(id) {
      const point=await evaluate(`(() => {const r=document.getElementById(${JSON.stringify(id)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
      for (const type of ['mousePressed','mouseReleased']) await send('Input.dispatchMouseEvent',{type,...point,button:'left',clickCount:1});
    }
    async function state(collapsed) {
      assert.equal(await evaluate("document.getElementById('right-cards-host').dataset.collapsed"),String(collapsed),'Visibilidad de ventanas coherente');
      const label=collapsed?'Mostrar ventanas':'Ocultar ventanas';
      // r4: la barra de titulo ya no repite el control: queda solo el primero
      // de la fila de iconos sobre las ventanas.
      assert.deepEqual(await evaluate("['test-windows'].map(id=>{const el=document.getElementById(id);return [el.title,el.getAttribute('aria-label'),el.getAttribute('aria-expanded'),el.getAttribute('aria-controls')];})"),[[label,label,String(!collapsed),'right-cards-host']]);
      assert.equal(await evaluate("document.getElementById('btn-toggle-panel')"),null,'r4: un solo control para ocultar ventanas');
      assert.equal(await evaluate("localStorage.getItem('devagents.panel.right')"),String(collapsed),'Visibilidad persistida');
    }
    async function capture(name) {
      console.log('INNER_TEXT '+name+'='+await evaluate('document.body.innerText'));
      if(process.env.DEVAGENTS_ACTIVITY_CAPTURE){const file=process.env.DEVAGENTS_ACTIVITY_CAPTURE+'-'+name+'.png';fs.writeFileSync(file,Buffer.from((await send('Page.captureScreenshot',{format:'png'})).data,'base64'));console.log('SCREENSHOT='+file);}
    }
    for(const width of [683,1024,1440]){
      await send('Emulation.setDeviceMetricsOverride',{width,height:768,deviceScaleFactor:1,mobile:false});
      await click('test-windows'); await state(true);
      assert.equal(await evaluate("getComputedStyle(document.querySelector('.rc-cards')).display"),'none','Ocultar no deja riel de columna');
      assert.equal(await evaluate("getComputedStyle(document.getElementById('panel-secondary')).display"),'none','Actividad arranca como panel opcional cerrado');
      const hit=await evaluate("(() => {const b=document.getElementById('test-windows'),r=b.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)?.closest('button')?.id;})()");
      assert.equal(hit,'test-windows','El primer icono sigue alcanzable al ocultar ventanas');
      await capture(width+'-collapsed');
      await click('test-windows'); await state(false); await capture(width+'-expanded');
      assert.notEqual(await evaluate("getComputedStyle(document.querySelector('.rc-cards')).display"),'none');
      await click('test-windows'); await state(true);
      await click('test-windows'); await state(false);
    }
    await evaluate("document.getElementById('panel-secondary').dataset.collapsed='false';document.getElementById('chat-host').style.display='flex'");
    await click('chat-btn-popout');
    assert.deepEqual(await evaluate('window.popouts'),[{vista:'conversacion'}],'Ventana nueva llega al listener document del puente');
    assert.equal(await evaluate("document.getElementById('chat-btn-popout').getAttribute('aria-label')"),'Abrir la conversación en una ventana nueva');
    await evaluate("localStorage.setItem('devagents.panel.right','true');window.layout.renderLayout(document.body)");
    // Restauracion de las ventanas y arranque cerrado del dock son independientes.
    await evaluate(`(() => {const h=document.getElementById('right-cards-host');h.innerHTML='<div class="rc-tools"><button class="rc-tool" id="test-windows" data-rc-action="panel">Ventanas</button></div><div class="rc-cards">Ventanas</div>';h.addEventListener('click',e=>{if(e.target.closest('[data-rc-action="panel"]'))window.toggleActivity();});window.toggleActivity=window.layout.initPanelToggles();})()`);
    await state(true); await click('test-windows'); await state(false);
    assert.equal(await evaluate("getComputedStyle(document.getElementById('panel-secondary')).display"),'none');
    await evaluate("Object.defineProperty(window,'localStorage',{configurable:true,value:{getItem(){throw Error('denegado');},setItem(){throw Error('lleno');}}});window.layout.initPanelToggles();window.toggleActivity()");
    assert(await evaluate("window.notices.some(m=>m.includes('leer el estado')) && window.notices.some(m=>m.includes('guardar el estado'))"),'Errores de almacenamiento visibles');
    console.log('PASS r3: ventanas flotantes 683/1024/1440, clic real, primer icono alcanzable, dock cerrado al arrancar, persistencia, ARIA, popout y errores de almacenamiento. DOM sintético; cabina pendiente.');
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
};

if (require.main === module) module.exports().catch(error => { console.error(error); process.exitCode = 1; });
