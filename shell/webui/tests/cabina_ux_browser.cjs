const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function browserFocus() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-ux-focus-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'selector.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const pending = new Map();
  const browserErrors = [];
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
      if (message.method === 'Runtime.exceptionThrown' ||
          (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') ||
          (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) browserErrors.push(message);
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
    const url = pathToFileURL(html).href;
    const { targetId } = await send('Target.createTarget', { url }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    await send('Log.enable');
    // The initial about:blank can already be complete before file navigation commits.
    const deadline = Date.now() + 10000;
    // A probe that races the navigation commit fails with a destroyed context: retry it.
    const ready = () => evaluate(`location.href===${JSON.stringify(url)} && document.readyState==='complete' && document.head!==null`)
      .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
    while (!await ready()) {
      assert(Date.now() < deadline, `Timeout waiting for selector document: ${url}`);
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    const sources = Object.fromEntries(['mission_control_ux', 'order_graph_ux', 'stylesheet_ux', 'tokens_ux', 'html_ux', 'external_models', 'alerts_ux'].map(name => [name, fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8')]));
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={'../design/notice':{notice:message=>{throw Error(message)}},'../design/icons':{icons:new Proxy({},{get:()=>()=>''})},'../design/orbit_backdrop':{orbitBackdrop:()=>''}};
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return mod.exports;}
      imports['./tokens']=load('tokens_ux');imports['../design/html']=load('html_ux');imports['../design/alerts']=load('alerts_ux');imports['../external_models']=load('external_models');imports['../bridge/core_api']=imports['../bridge/core_api']||{eventPayload:(e)=>e.payload??{}};imports['./order_graph']=load('order_graph_ux');load('stylesheet_ux').injectStylesheet();
      window.externalModelRows=imports['../external_models'].externalModelRows;
      const p=Object.create(load('mission_control_ux').MissionControlPanel.prototype);
      Object.assign(p,{container:document.body,core:null,hooks:{},modelQuery:'',modelPickerOpen:false,modelRows:[
        {provider:'Google',model:'gemma',fav:true,ctx:0,free:true,available:true},
        {provider:'Cohere',model:'command',ctx:0,free:true,available:true},
        {provider:'Cohere',model:'command2',ctx:0,free:true,available:true},
        {provider:'NVIDIA',model:'nemotron',ctx:0,free:true,available:true}
      ],pinnedRoles:{plan:'',exec:'',audit:''},swarmSelection:[]});
      p.renderBody=()=>{};p.renderSwarmList=()=>{};p.render();p.toggleModelPicker(true);window.panel=p;
    })()`);
    await evaluate("document.querySelector('#model-groups-toggle').click()");
    await evaluate("new Promise(resolve=>setTimeout(resolve,50))");
    await evaluate("document.querySelector('#model-search').focus()");
    await key('Tab', 9);
    assert.equal(await evaluate('document.activeElement.id'), 'model-groups-toggle');
    const count = await evaluate("document.querySelectorAll('#model-list summary, #model-list .model-item').length");
    assert.equal(await evaluate("[...document.querySelectorAll('#model-list summary, #model-list .model-item')].filter(el=>el.tabIndex===0).length"), 1, 'La lista debe tener un único punto de Tab');
    await key('Tab', 9);
    assert(await evaluate("document.activeElement===document.querySelector('#model-list [data-val=\"\"]')"));
    for (let i = 0; i < count; i++) {
      if (i) await key('ArrowDown', 40);
      const actual = await evaluate("({tag:document.activeElement.tagName,id:document.activeElement.id,text:document.activeElement.textContent.trim().slice(0,60)})");
      console.log(`TAB ${i} ${JSON.stringify(actual)}`);
      assert(await evaluate(`document.activeElement===[...document.querySelectorAll('#model-list summary, #model-list .model-item')][${i}]`), 'Orden de flechas en grupos/opciones incorrecto');
      assert.equal(await evaluate("[...document.querySelectorAll('#model-list summary, #model-list .model-item')].filter(el=>el.tabIndex===0).length"), 1);
    }
    await key('Tab', 9);
    assert.equal(await evaluate('document.activeElement.id'), 'btn-external-refresh');
    await key('Tab', 9, 8);
    assert(await evaluate("document.activeElement===[...document.querySelectorAll('#model-list summary, #model-list .model-item')].at(-1)"));
    await key('Tab', 9, 8);
    assert.equal(await evaluate('document.activeElement.id'), 'model-groups-toggle');
    await key('Tab', 9, 8);
    assert.equal(await evaluate('document.activeElement.id'), 'model-search');
    await key('ArrowDown', 40);
    await key('End', 35);
    await key('ArrowUp', 38);
    await key('ArrowDown', 40);
    await key('ArrowLeft', 37);
    assert(await evaluate("document.activeElement.tagName==='SUMMARY' && !document.activeElement.parentElement.open"));
    assert(await evaluate("[...document.querySelectorAll('#model-list details:not([open]) .model-item')].every(el=>el.tabIndex===-1)"), 'Opciones colapsadas enfocables');
    await key('Enter', 13);
    assert(await evaluate('document.activeElement.parentElement.open'), 'Enter conserva apertura nativa');
    await key('ArrowDown', 40);
    assert(await evaluate("document.activeElement.matches('.model-item')"));
    await evaluate("document.activeElement.closest('details').open=false");
    await evaluate("new Promise(resolve=>setTimeout(resolve,50))");
    assert(await evaluate("document.activeElement.tagName==='SUMMARY'"), 'Colapsar desde fuera devuelve foco al encabezado');
    await evaluate("document.querySelector('#model-groups-toggle').click()");
    await evaluate("document.querySelector('#model-groups-toggle').click()");
    await evaluate("new Promise(resolve=>setTimeout(resolve,50))");
    assert(await evaluate("[...document.querySelectorAll('#model-list details:not([open]) .model-item')].every(el=>el.tabIndex===-1)"));
    await evaluate("document.querySelector('#model-search').value='command';document.querySelector('#model-search').dispatchEvent(new Event('input',{bubbles:true}))");
    assert.equal(await evaluate("[...document.querySelectorAll('#model-list summary, #model-list .model-item')].filter(el=>el.tabIndex===0).length"), 1);
    await evaluate("document.querySelector('#model-search').value='sin coincidencias';document.querySelector('#model-search').dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#model-search').focus()");
    await key('ArrowDown', 40);
    assert(await evaluate("document.activeElement===document.querySelector('#model-list [data-val=\"\"]')"));
    await key('Tab', 9);
    assert.equal(await evaluate('document.activeElement.id'), 'btn-external-refresh');
    await evaluate("document.querySelector('#model-search').value='';document.querySelector('#model-search').dispatchEvent(new Event('input',{bubbles:true}))");
    console.log('INNER_TEXT=' + await evaluate("document.querySelector('#model-picker').innerText"));
    // el selector se comporta como un popover real (Escape, clic fuera).
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'flex');
    await evaluate("document.querySelector('#model-search').focus()");
    await key('Escape', 27);
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'none', 'CK-CAB-022 Escape cierra el selector');
    assert.equal(await evaluate('document.activeElement.id'), 'btn-model-picker', 'CK-CAB-022 Escape devuelve el foco al chip');
    console.log('CK-CAB-022 PASS Escape cierra y devuelve el foco');

    // Escape con el foco/evento FUERA del compositor (p. ej. en body tras
    // repintar el plan): el popover debe cerrarse igual. Antes el listener
    // colgaba del contenedor y este caso no llegaba nunca, dejando el panel
    // encima del plan. Se despacha en `document`, que no es descendiente del
    // contenedor, para reproducir ese escenario.
    assert.equal(await evaluate("window.panel.toggleModelPicker(true)"), undefined);
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'flex');
    await evaluate("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))");
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'none', 'CK-CAB-022 Escape con foco fuera cierra el selector');
    console.log('CK-CAB-022 PASS Escape con foco fuera del compositor cierra');

    // Escape en «Buscar modelos…» limpia el texto si lo hay; si está vacío, cierra.
    await evaluate("window.panel.toggleModelPicker(true)");
    await evaluate("const s=document.querySelector('#model-search');s.value='command';s.dispatchEvent(new Event('input',{bubbles:true}))");
    await evaluate("document.querySelector('#model-search').focus()");
    await key('Escape', 27);
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'flex', 'CK-CAB-022 Escape en el buscador con texto no cierra');
    assert.equal(await evaluate("document.querySelector('#model-search').value"), '', 'CK-CAB-022 Escape limpia el buscador');
    assert.equal(await evaluate("window.panel.modelQuery"), '');
    await key('Escape', 27);
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'none', 'CK-CAB-022 el segundo Escape cierra');
    console.log('CK-CAB-022 PASS Escape en el buscador limpia y luego cierra');

    // Clic fuera del panel (fuera del chip y del popover) lo cierra.
    await evaluate("window.panel.toggleModelPicker(true)");
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'flex');
    await evaluate("document.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))");
    assert.equal(await evaluate("document.querySelector('#model-picker').style.display"), 'none', 'CK-CAB-022 clic fuera cierra');
    console.log('CK-CAB-022 PASS clic fuera cierra el selector');

    // Enviar una orden retira el selector (dejaría tapado el plan).
    assert.equal(await evaluate(`(() => { const p=window.panel; p.attachments=[]; p.submit=async()=>{}; p.toggleModelPicker(true); document.querySelector('#mission-composer-input').value='orden'; document.querySelector('#btn-mission-send').click(); return p.modelPickerOpen; })()`), false, 'CK-CAB-022 enviar cierra el selector');
    console.log('CK-CAB-022 PASS enviar una orden cierra el selector');

    // Un plan pendiente de aprobar también lo retira.
    assert.equal(await evaluate(`(() => { const p=window.panel; p.toggleModelPicker(true); p.setPhase('awaiting-approval'); return p.modelPickerOpen; })()`), false, 'CK-CAB-022 plan pendiente cierra el selector');
    console.log('CK-CAB-022 PASS el plan pendiente cierra el selector');
    if (process.env.DEVAGENTS_UX_CAPTURE) {
      const shot = await send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(process.env.DEVAGENTS_UX_CAPTURE, Buffer.from(shot.data, 'base64'));
      console.log('SCREENSHOT=' + process.env.DEVAGENTS_UX_CAPTURE);
    }
    console.log('PASS recorrido real sobre DOM/CSS generados por MissionControlPanel');
    await evaluate(`(() => {
      const p=window.panel;
      window.pinCalls=[];
      p.core={setPlanModel:async(...args)=>window.pinCalls.push(['plan',...args]),
        setExecModel:async(...args)=>window.pinCalls.push(['exec',...args]),
        getExternalPaths:async()=>({})};
      p.refreshModelPickers=async()=>{};
      p.modelQuery='';
      p.modelRows=window.externalModelRows([{provider:'agent:opencode',cli:'opencode',display:'OpenCode',exe:'C:/fixture/opencode.exe',
        version:'1.18.25',session:'api_key',enumeration_status:'enumerated',models:[
          {slug:'opencode/x-free',display_name:'opencode/x-free',manufacturer:'unknown',reasoning_efforts:[],free:true,label:'OpenCode · opencode/x-free (gratis)'},
          {slug:'opencode/claude-opus-5',display_name:'opencode/claude-opus-5',manufacturer:'anthropic',reasoning_efforts:[],free:false}
        ]}]);
      p.toggleModelPicker(true);p.renderModelList();
      document.querySelector('#model-list details').open=true;
    })()`);
    const freeSelector = '#model-list [data-val="agent:opencode|opencode/x-free"]';
    const freeText = await evaluate(`document.querySelector(${JSON.stringify(freeSelector)}).innerText`);
    assert.match(freeText,/Gratis/);
    assert.doesNotMatch(freeText,/API bloqueada|caído/);
    assert.match(await evaluate("document.querySelector('#model-list').innerText"),/API bloqueada/);
    const rect = await evaluate(`(() => {const r=document.querySelector(${JSON.stringify(freeSelector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    await send('Input.dispatchMouseEvent',{type:'mousePressed',...rect,button:'left',clickCount:1});
    await send('Input.dispatchMouseEvent',{type:'mouseReleased',...rect,button:'left',clickCount:1});
    await evaluate('new Promise(resolve=>setTimeout(resolve,30))');
    // elegir una CLI sin plan/veredicto en el selector principal
    // fija el EJECUTOR (setExecModel); opencode ya no pisa el planificador.
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:opencode','opencode/x-free']],'CK-CAB-023 la CLI de la lista va al ejecutor');
    assert.equal(await evaluate("document.querySelector('#external-pin-exec').disabled"),false);
    assert.match(await evaluate("document.querySelector('.external-cli-summary').innerText"),/gratis/);
    // r2: para una CLI sin protocolo de plan/veredicto el botón «Usar como
    // planificador» queda deshabilitado y explica el motivo — el preflight ya
    // no puede bloquear una orden fijada por esta vía.
    assert.equal(await evaluate("document.querySelector('#external-pin-plan').disabled"),true,'CK-CAB-002 pin-plan deshabilitado para CLI sin plan/veredicto');
    assert.match(await evaluate("document.querySelector('#external-pin-plan').title"),/plan\/veredicto/,'CK-CAB-002 el title explica el motivo');
    await evaluate("document.querySelector('#external-pin-plan').click()");
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:opencode','opencode/x-free']],'CK-CAB-002 el botón deshabilitado no fija planificador');
    console.log('CK-CAB-002 INNER_TEXT=' + await evaluate("document.body.innerText"));
    if (process.env.DEVAGENTS_OPENCODE_CAPTURE) {
      const shot=await send('Page.captureScreenshot',{format:'png'});
      fs.writeFileSync(process.env.DEVAGENTS_OPENCODE_CAPTURE,Buffer.from(shot.data,'base64'));
      console.log('CK-CAB-002 SCREENSHOT='+process.env.DEVAGENTS_OPENCODE_CAPTURE);
    }
    console.log('PASS CK-CAB-002 opencode free browser selector clicks plan and execution bridge with synthetic catalog');

    // ── · Claude Code como EJECUTOR, no como modelo de la orden ──
    // Con un planificador ya fijado (Cohere|command), elegir Claude Code en el
    // selector principal debe fijarlo como ejecutor (setExecModel), dejar el
    // planificador intacto y recomponer el chip con los dos roles. Codex y los
    // modelos de nube siguen yendo al planificador. Todo sobre el DOM real.
    await evaluate(`(() => {
      const p=window.panel;
      window.pinCalls=[];
      p.orderId=0;
      p.externalDetail='';
      delete p.refreshModelPickers;
      p.enginePlan={provider:'Cohere',model:'command'};
      p.engineExec={provider:'',model:''};
      p.agents=[
        {provider:'agent:claude-code',cli:'claude-code',display:'Claude Code',exe:'C:/fixture/claude.exe',
         version:'2.0.0',session:'suscripcion',enumeration_status:'enumerated',models:[
           {slug:'claude-code',display_name:'Claude Code',manufacturer:'anthropic',reasoning_efforts:[],free:false,label:'Claude Code (tu suscripción)'}]},
        {provider:'agent:codex',cli:'codex',display:'Codex',exe:'C:/fixture/codex.exe',
         version:'0.159.2',session:'suscripcion',enumeration_status:'enumerated',models:[
           {slug:'gpt-6.1-sol',display_name:'Sol 6.1',manufacturer:'OpenAI',reasoning_efforts:[],free:false,label:'Codex · gpt-6.1-sol (tu suscripción)'}]},
      ];
      p.core={
        setPlanModel:async(provider,model)=>{window.pinCalls.push(['plan',provider,model]);p.enginePlan={provider,model};return {applied:true};},
        setExecModel:async(provider,model)=>{window.pinCalls.push(['exec',provider,model]);p.engineExec={provider,model};return {applied:true};},
        setAuditModel:async(provider,model)=>{window.pinCalls.push(['audit',provider,model]);return {applied:true};},
        listProviders:async()=>[{name:'Cohere',enabled:true,local:false,models:[{name:'command',available:true,is_free:true,text_gen:true}]}],
        getPlanModel:async()=>p.enginePlan,
        getExecModel:async()=>p.engineExec,
        getAuditModel:async()=>({provider:'',model:''}),
        getSwarmModels:async()=>[],
        getGovernance:async()=>({mode:'hybrid'}),
        getExternalAgents:async()=>p.agents,
        getExternalPaths:async()=>({}),
        setDeterministic:async()=>({applied:true}),
        orderPreflight:async()=>({allowed:true,issues:[],message:'',subscription_notice:''}),
      };
      p.pinnedRoles={plan:'Cohere|command',exec:'',audit:''};
      p.modelRows=window.externalModelRows(p.agents);
      p.modelQuery='';p.toggleModelPicker(true);p.renderModelList();
    })()`);

    // Vía 1: clic en la fila «Claude Code» de la lista buscable.
    const ccSelector = '#model-list [data-val="agent:claude-code|claude-code"]';
    assert.equal(await evaluate(`(() => { const el=document.querySelector(${JSON.stringify(ccSelector)}); el.closest('details').open=true; el.click(); return true; })()`), true);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:claude-code','claude-code']],'CK-CAB-023 elegir Claude Code fija el ejecutor, nunca el planificador');
    assert.deepEqual(await evaluate('window.panel.enginePlan'),{provider:'Cohere',model:'command'},'CK-CAB-023 el planificador queda intacto');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'agent:claude-code|claude-code','CK-PRV-003 el selector único refleja la CLI elegida');
    assert.equal(await evaluate("window.panel.engineExec.model"),'claude-code','CK-CAB-023 la CLI sigue fijada en el pin real de ejecutor');
    const chipText = await evaluate("document.querySelector('#model-chip-label').innerText");
    assert.match(chipText,/command/,'CK-CAB-023 el chip muestra el planificador');
    assert.match(chipText,/Claude Code/,'CK-CAB-023 el chip muestra el ejecutor');
    console.log('CK-CAB-023 CHIP=' + chipText);
    // r2: el detalle de la CLI incompatible no ofrece fijarla como planificador.
    assert.equal(await evaluate("document.querySelector('#external-pin-plan').disabled"),true,'CK-CAB-023 pin-plan deshabilitado para Claude Code');
    assert.match(await evaluate("document.querySelector('#external-pin-plan').title"),/plan\/veredicto/,'CK-CAB-023 el title explica el motivo');

    // Vía 2: cambio del select nativo «Modelo de la orden (planificador)».
    await evaluate(`(() => { window.pinCalls=[]; const sel=document.querySelector('#sel-model'); sel.value='agent:claude-code|claude-code'; sel.dispatchEvent(new Event('change',{bubbles:true})); })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:claude-code','claude-code']],'CK-CAB-023 el select principal también manda la CLI al ejecutor');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'agent:claude-code|claude-code','CK-PRV-003 el selector único conserva la elección CLI');

    // Codex sigue ocupando el rol de planificador, como hoy.
    await evaluate(`(() => { window.pinCalls=[]; const sel=document.querySelector('#sel-model'); sel.value='agent:codex|gpt-6.1-sol'; sel.dispatchEvent(new Event('change',{bubbles:true})); })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['plan','agent:codex','gpt-6.1-sol'],['exec','','']],'CK-PRV-003 Codex fija el planificador y sustituye la elección CLI implícita');

    // Un modelo de nube sigue ocupando el rol de planificador, como hoy.
    await evaluate(`(() => { window.pinCalls=[]; const sel=document.querySelector('#sel-model'); sel.value='Cohere|command'; sel.dispatchEvent(new Event('change',{bubbles:true})); })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['plan','Cohere','command']],'CK-CAB-023 un modelo de nube sigue fijándose como planificador');
    console.log('CK-CAB-023 PASS Claude Code fija ejecutor con planificador intacto y chip con ambos roles; Codex y nube sin cambios');

    // ── r2 · Planificador automático + elegir Claude Code ──
    // Sin pin de planificador, la CLI se fija solo como ejecutor y el chip lo
    // nombra; el planificador sigue automático.
    await evaluate(`(() => {
      const p=window.panel;
      window.pinCalls=[];
      p.enginePlan={provider:'',model:''};
      p.engineExec={provider:'',model:''};
      p.pinnedRoles={plan:'',exec:'',audit:''};
      p.externalDetail='';
      const el=document.querySelector('#model-list [data-val="agent:claude-code|claude-code"]');
      el.closest('details').open=true; el.click();
    })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:claude-code','claude-code']],'CK-CAB-023 (r2) con planificador automático la CLI solo fija el ejecutor');
    assert.deepEqual(await evaluate('window.panel.enginePlan'),{provider:'',model:''},'CK-CAB-023 (r2) el planificador sigue automático');
    const chipAuto = await evaluate("document.querySelector('#model-chip-label').innerText");
    assert.match(chipAuto,/^Ejecutor: Claude Code/,'CK-CAB-023 (r2) el chip nombra el ejecutor');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'agent:claude-code|claude-code','CK-PRV-003 Modelo refleja CLI con planificador automático');

    // ── r2 · Pin viejo de planificador incompatible ──
    // Si el planificador quedó fijado a una CLI sin plan/veredicto (pin viejo
    // de sesiones anteriores al arreglo), elegir un ejecutor CLI lo limpia:
    // vuelve a automático en vez de dejar la orden bloqueada por el preflight.
    await evaluate(`(() => {
      const p=window.panel;
      window.pinCalls=[];
      p.enginePlan={provider:'agent:claude-code',model:'claude-code'};
      p.engineExec={provider:'',model:''};
      p.pinnedRoles={plan:'agent:claude-code|claude-code',exec:'',audit:''};
      p.externalDetail='';
      const el=document.querySelector('#model-list [data-val="agent:claude-code|claude-code"]');
      el.closest('details').open=true; el.click();
    })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['exec','agent:claude-code','claude-code'],['plan','','']],'CK-CAB-023 (r2) el pin viejo incompatible se limpia al elegir la CLI');
    assert.deepEqual(await evaluate('window.panel.enginePlan'),{provider:'',model:''},'CK-CAB-023 (r2) el planificador vuelve a automático');
    const chipHealed = await evaluate("document.querySelector('#model-chip-label').innerText");
    assert.match(chipHealed,/^Ejecutor: Claude Code/,'CK-CAB-023 (r2) el chip ya no muestra el pin inválido');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'agent:claude-code|claude-code','CK-PRV-003 Modelo refleja CLI tras limpiar planificador incompatible');

    // ── r2 · El botón «Usar como planificador» sigue disponible para Codex ──
    await evaluate(`(() => { const p=window.panel; window.pinCalls=[]; p.externalDetail='agent:codex|gpt-6.1-sol'; p.renderExternalDetail(); })()`);
    assert.equal(await evaluate("document.querySelector('#external-pin-plan').disabled"),false,'CK-CAB-023 (r2) pin-plan disponible para Codex');
    assert.equal(await evaluate("document.querySelector('#external-pin-plan').title"),'','CK-CAB-023 (r2) sin motivo de bloqueo para Codex');
    await evaluate("document.querySelector('#external-pin-plan').click()");
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['plan','agent:codex','gpt-6.1-sol']],'CK-CAB-023 (r2) Codex sigue fijándose como planificador desde el detalle');
    console.log('CK-CAB-023 r2 PASS automático, pin viejo limpiado y Codex intacto');

    // ── r3 · El rol de auditor también es de solo-ejecutor para CLI sin protocolo ──
    // Claude Code (cualquier CLI no-Codex) no puede auditar: el detalle no
    // ofrece el botón y el select de auditor no lista la opción. Codex y los
    // modelos de nube quedan intactos.
    await evaluate(`(() => { const p=window.panel; window.pinCalls=[]; p.externalDetail='agent:claude-code|claude-code'; p.renderExternalDetail(); })()`);
    assert.equal(await evaluate("document.querySelector('#external-pin-audit').disabled"),true,'CK-CAB-023 (r3) pin-audit deshabilitado para Claude Code');
    assert.match(await evaluate("document.querySelector('#external-pin-audit').title"),/plan\/veredicto/,'CK-CAB-023 (r3) el title explica el motivo');
    await evaluate("document.querySelector('#external-pin-audit').click()");
    await evaluate('new Promise(resolve=>setTimeout(resolve,30))');
    assert.deepEqual(await evaluate('window.pinCalls'),[],'CK-CAB-023 (r3) el botón deshabilitado no fija auditor');
    await evaluate("document.querySelector('#sel-add-role').value='audit';document.querySelector('#btn-add-role').click()");
    const auditCliOption = `document.querySelector('#sel-model-audit option[value="agent:claude-code|claude-code"]')`;
    assert.equal(await evaluate(`${auditCliOption}.disabled`),true,'CK-CAB-023 (r3) el selector de auditor no ofrece la CLI sin protocolo');
    assert.match(await evaluate(`${auditCliOption}.title`),/plan\/veredicto/,'CK-CAB-023 (r3) la opción explica el motivo');
    assert.equal(await evaluate(`document.querySelector('#sel-model-audit option[value="agent:codex|gpt-6.1-sol"]').disabled`),false,'CK-CAB-023 (r3) Codex sigue elegible como auditor');
    await evaluate(`(() => { window.pinCalls=[]; const sel=document.querySelector('#sel-model-audit'); sel.value='agent:claude-code|claude-code'; sel.dispatchEvent(new Event('change',{bubbles:true})); })()`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,60))');
    assert.deepEqual(await evaluate('window.pinCalls'),[],'CK-CAB-023 (r3) el binding de auditor descarta la CLI sin protocolo');
    // Con Codex el botón de auditor vuelve a estar activo y fija su rol como antes.
    await evaluate(`(() => { const p=window.panel; window.pinCalls=[]; p.externalDetail='agent:codex|gpt-6.1-sol'; p.renderExternalDetail(); })()`);
    assert.equal(await evaluate("document.querySelector('#external-pin-audit').disabled"),false,'CK-CAB-023 (r3) pin-audit disponible para Codex');
    assert.equal(await evaluate("document.querySelector('#external-pin-audit').title"),'','CK-CAB-023 (r3) sin motivo de bloqueo para Codex');
    await evaluate("document.querySelector('#external-pin-audit').click()");
    await evaluate('new Promise(resolve=>setTimeout(resolve,80))');
    assert.deepEqual(await evaluate('window.pinCalls'),[['audit','agent:codex','gpt-6.1-sol']],'CK-CAB-023 (r3) Codex sí se fija como auditor');
    console.log('CK-CAB-023 r3 PASS auditor solo para CLIs con protocolo; Codex intacto');

    // ── T2d-D6 · «Solo gratis» no esconde en silencio a la CLI que no entra ──
    // Gemini con cuenta personal de Google (sin_sesion + motivo del motor): en
    // «Solo gratis» queda una fila suya deshabilitada con el motivo; Claude
    // Code (suscripción) sigue elegible. Fuera de «Solo gratis», la fila normal
    // (deshabilitada por no tener sesión) y sin el sufijo.
    const geminiReason = 'cuenta personal de Google: desde el 18-jun-2026 Gemini CLI solo funciona con licencia de empresa (GOOGLE_CLOUD_PROJECT) o clave de pago; para cuentas personales Google ofrece Antigravity CLI';
    const showPickers = mode => evaluate(`(async () => {
      const p=window.panel;
      p.enginePlan={provider:'',model:''}; p.engineExec={provider:'',model:''};
      p.pinnedRoles={plan:'',exec:'',audit:''}; p.mainCliChoice='';
      p.agents=[p.agents[0],
        {provider:'agent:gemini-cli',cli:'gemini-cli',display:'Gemini CLI',exe:'C:/fixture/gemini.cmd',version:'0.53.1',
         session:'sin_sesion',session_reason:${JSON.stringify(geminiReason)},enumeration_status:'no_enumerable',models:[
           {slug:'gemini-cli',display_name:'Gemini CLI',manufacturer:'google',reasoning_efforts:[],free:false}]}];
      p.core.getGovernance=async()=>({mode:${JSON.stringify(mode)}});
      await p.refreshModelPickers();
      const g=document.querySelector('#sel-model option[value="agent:gemini-cli|gemini-cli"]');
      const c=document.querySelector('#sel-model option[value="agent:claude-code|claude-code"]');
      const b=document.querySelector('#model-list [data-blocked="agent:gemini-cli|gemini-cli"]');
      return { gemini: g ? { text: g.textContent, disabled: g.disabled, count: document.querySelectorAll('#sel-model option[value="agent:gemini-cli|gemini-cli"]').length } : null,
               claude: c ? { text: c.textContent, disabled: c.disabled } : null,
               list: { blocked: b ? b.textContent : null, clickable: document.querySelectorAll('#model-list .model-item[data-val="agent:gemini-cli|gemini-cli"]').length,
                       group: document.querySelector('#model-list [data-group="free-blocked"] > summary')?.textContent ?? null } };
    })()`);
    const free = await showPickers('free');
    assert.ok(free.gemini, 'T2d-D6 en «Solo gratis» Gemini sigue en el selector');
    assert.equal(free.gemini.disabled, true, 'T2d-D6 deshabilitado: no se puede elegir');
    assert.equal(free.gemini.count, 1, 'T2d-D6 una sola fila por agente');
    assert.ok(free.gemini.text.includes('sin sesión — ' + geminiReason), 'T2d-D6 la fila lleva el motivo del motor');
    assert.match(free.gemini.text, /no entra en Solo gratis$/, 'T2d-D6 y dice por qué no entra');
    assert.deepEqual(free.claude && free.claude.disabled, false, 'T2d-D6 Claude Code (suscripción) sigue elegible en Solo gratis');
    assert.doesNotMatch(free.claude.text, /no entra en Solo gratis/);
    assert.ok(free.list.blocked && free.list.blocked.includes('sin sesión — ' + geminiReason), 'T2d-D6 la lista buscable también lo muestra con el motivo');
    assert.equal(free.list.clickable, 0, 'T2d-D6 en la lista no es un botón elegible');
    assert.match(free.list.group, /^No entran en Solo gratis/, 'T2d-D6 grupo propio en la lista');
    const hybrid = await showPickers('hybrid');
    assert.equal(hybrid.list.blocked, null, 'T2d-D6 fuera de Solo gratis no hay grupo de bloqueados');
    assert.equal(hybrid.gemini.disabled, true, 'T2d-D6 fuera de Solo gratis sigue sin poder elegirse (sin sesión)');
    assert.doesNotMatch(hybrid.gemini.text, /no entra en Solo gratis/, 'T2d-D6 el sufijo es solo de Solo gratis');
    assert.ok(hybrid.gemini.text.includes('sin sesión — cuenta personal de Google'), 'T2d-D6 el motivo también fuera de Solo gratis');
    console.log('T2d-D6 PASS ' + free.gemini.text);

    console.log('CK-CAB-002 BROWSER_ERRORS='+JSON.stringify(browserErrors));
    assert.deepEqual(browserErrors,[]);
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
};
