// E1/E2 — tarjetas del panel derecho (Entorno/Resultados) y fila de
// herramientas de la columna. Arnés: Chromium real por CDP, igual que
// shell/webui/tests/activity_panel.test.cjs; este comprobador vive en tests/
// para que build.zig (paso test-webui) lo corra desde la raíz del repo.
//
// Carga el componente REAL compilado a CJS (build_rightcards_test.mjs) y la
// hoja de estilos real; los colores de la referencia se inyectan como
// variables de tema (el ThemeManager no está montado aquí).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

module.exports = async function planModeUi() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-plan-mode-'));
  const executable = process.env.DEVAGENTS_TEST_BROWSER || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const html = path.join(profile, 'plan-mode.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const browserErrors = [];
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
      if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message.params.exceptionDetails);
      if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') browserErrors.push(message.params);
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
  const settle = () => evaluate('new Promise(resolve => setTimeout(resolve, 60))');
  async function clickSelector(selector) {
    const present = await evaluate(`(() => {const el=document.querySelector(${JSON.stringify(selector)});if(!el)return false;el.scrollIntoView({block:'center'});return true;})()`);
    assert(present, 'elemento presente para el clic: ' + selector);
    await settle();
    const point = await evaluate(`(() => {const el=document.querySelector(${JSON.stringify(selector)});const r=el.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
    await settle();
  }
  async function keyOn(selector, keyName, code, vk, text) {
    await evaluate(`document.querySelector(${JSON.stringify(selector)}).focus()`);
    for (const type of ['keyDown', 'keyUp']) {
      await send('Input.dispatchKeyEvent', { type, key: keyName, code, windowsVirtualKeyCode: vk, ...(type === 'keyDown' && text ? { text } : {}) });
    }
    await settle();
  }
  const q = evaluate;
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
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
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });


    const sources = Object.fromEntries(['mission','html','icons','style','core','tokens','auto','context','codeCopy','activity','theme','labels','graph'].map(name => [name, fs.readFileSync(path.join(__dirname, '../shell/webui/dist', ({mission:'mission_plan', html:'html_plan', icons:'icons_plan', style:'style_plan', core:'core_plan',tokens:'tokens_plan',auto:'auto_plan',context:'context_plan',codeCopy:'code_copy_plan',activity:'activity_plan',theme:'theme_plan',labels:'labels_plan',graph:'order_graph_plan'})[name]+'.test.cjs'), 'utf8')]));
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={
        '../design/notice':{notice:message=>window.notices.push(message)},
        '../design/orbit_backdrop':{orbitBackdrop:()=>''},
        '../design/markdown':{renderMarkdown:t=>imports['../design/html'].escapeText(t)},
        '../components/copy_image_menu':{installCopyImageMenu:()=>{}},
        '../session_groups':{conversationIdForSession:()=> 'test-conversation'},
        '../ui_diag':{synthProblems:()=>[]},
        '../layout/layout':{updatePermissionBadge:()=>{}},
      };
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return mod.exports;}
      window.notices=[];imports['./bridge/core_api']=load('core');imports['./tokens']=load('tokens');imports['./auto_compact']=load('auto');imports['../chat_activity']=load('activity');imports['../design/html']=load('html');imports['../bridge/core_api']=imports['./bridge/core_api'];imports['./order_graph']=load('graph');imports['../design/icons']=load('icons');load('style').injectStylesheet();
      imports['../bridge/core_api']=imports['./bridge/core_api'];
      imports['./context_usage']=load('context');
      imports['./notice']=imports['../design/notice'];
      imports['../design/code_copy']=load('codeCopy');
      new (load('theme').ThemeManager)().applyTheme('black');
      imports['../design/status_labels']=load('labels');
      const {MissionControlPanel}=load('mission');
      MissionControlPanel.prototype.refreshStatus=async()=>{};
      MissionControlPanel.prototype.refreshModelPickers=async()=>{};
      MissionControlPanel.prototype.startStatusWatch=()=>{};MissionControlPanel.prototype.stopStatusWatch=()=>{};
      window.prv003DrainNewEvents=MissionControlPanel.prototype.drainNewEvents;
      MissionControlPanel.prototype.startEventLoop=()=>{};MissionControlPanel.prototype.drainNewEvents=async()=>{};
      window.MissionControlPanel=MissionControlPanel;
      window.calls=[];
      window.plan={understanding:'Crear estilos sin ejecutarlos',needs_clarification:false,questions:[],tasks:[{id:'t1',department:'programacion',task_type:'programar',description:'Crear estilos.css',depends_on:[],contract_fields:[]}],wait_for_plan_approval:true};
      window.fake={
        getDeterministic:async()=>({enabled:false}),getAgenticIterations:async()=>({iterations:1}),
        orderPreflight:async()=>({allowed:true,issues:[],budget:{remaining:0}}),
        submitOrder:async(...args)=>{calls.push(['submit',...args]);return {orderId:41}},
        pollPlan:async()=>({done:true,ok:true}),getPlan:async()=>plan,
        orderEvents:async()=>[],orderStatus:async()=>({status:2}),
        replanOrder:async(id,text)=>{calls.push(['replan',id,text]);plan={...plan,understanding:'Plan revisado: '+text}},
        cancelOrder:async id=>{calls.push(['cancel',id]);return {cancelled:true}},
        answerOrder:async(id,answers)=>{calls.push(['answer',id,answers]);plan={understanding:'Plan con lenguaje aclarado',questions:[],tasks:[{id:'t1',department:'programacion',description:'Crear estilos.css',depends_on:[]}],wait_for_plan_approval:true}},
        dispatchOrder:async id=>{calls.push(['dispatch',id]);return {dispatching:true}},
        orderWorktree:async()=>({}),createCheckpoint:async()=>({sha:'fixture',untrackedCount:0}),
      };
      document.body.innerHTML='<main id="host" style="width:760px;height:900px"></main>';
      window.panel=new MissionControlPanel(document.getElementById('host'),fake);
      panel.startStatusWatch=()=>{};panel.stopStatusWatch=()=>{};panel.startEventLoop=()=>{};
      panel.drainNewEvents=async()=>{};
      window.CoreApi=load('core').CoreApi;
    })()`);
    assert.equal(await q(`!!document.querySelector('#wait-plan-approval')`), true, 'interruptor en la ventana Modos del compositor');
    assert.match(await q(`document.querySelector('label[for="wait-plan-approval"]').innerText`), /Esperar mi aprobación del plan/);
    await clickSelector('#btn-modes-picker');
    await clickSelector('#wait-plan-approval');
    assert.equal(await q(`localStorage.getItem('devagents.waitPlanApproval.v1')`), 'true', 'preferencia persistida');
    await evaluate(`panel=new MissionControlPanel(document.getElementById('host'),fake)`);
    assert.equal(await q(`document.querySelector('#wait-plan-approval').checked`), true);
    await evaluate(`panel.submit('crea estilos.css')`);
    assert.equal(await q(`calls.filter(c=>c[0]==='submit')[0][4].waitForPlanApproval`), true, 'campo enviado al motor');
    assert.equal(await q(`calls.filter(c=>c[0]==='dispatch').length`), 0);
    assert.match(await q(`document.body.innerText`), /Crear estilos sin ejecutarlos/);
    for (const selector of ['#btn-approve','#btn-plan-changes','#btn-discard']) assert.equal(await q(`!!document.querySelector('${selector}')`), true, selector);
    await evaluate(`document.querySelector('#plan-change-request').value='Usa azul';document.querySelector('#plan-change-request').dispatchEvent(new Event('input',{bubbles:true}))`);
    await clickSelector('#btn-plan-changes');
    await evaluate(`new Promise(r=>setTimeout(r,700))`);
    assert.deepEqual(await q(`calls.find(c=>c[0]==='replan')`), ['replan',41,'Usa azul']);
    assert.match(await q(`document.body.innerText`), /Plan revisado: Usa azul/);
    assert.equal(await q(`calls.filter(c=>c[0]==='dispatch').length`), 0, 'pedir cambios nunca ejecuta');
    await clickSelector('#btn-approve');
    assert.deepEqual(await q(`calls.filter(c=>c[0]==='dispatch')`), [['dispatch',41]], 'aprobar usa el despacho existente una vez');
    await evaluate(`panel.phase='awaiting-approval';panel.plan=plan;panel.orderId=41;panel.renderBody();document.getElementById('mission-body').scrollTop=0;window.scrollTo(0,0)`);
    await clickSelector('#btn-discard');
    assert.deepEqual(await q(`calls.filter(c=>c[0]==='cancel')`), [['cancel',41]], 'cancelar llega al motor');
    assert.equal(await q(`calls.filter(c=>c[0]==='dispatch').length`), 1);
    await evaluate(`panel.phase='idle';panel.render();document.querySelector('#mission-composer-input').focus()`);
    await keyOn('#mission-composer-input','Tab','Tab',9);
    // La activación por teclado nativa del checkbox sigue disponible sin secuestrar Shift+Tab.
    await clickSelector('#btn-modes-picker');
    await evaluate(`document.querySelector('#wait-plan-approval').focus()`);
    await keyOn('#wait-plan-approval',' ','Space',32,' ');
    assert.equal(await q(`document.querySelector('#wait-plan-approval').checked`), false);
    await clickSelector('#btn-modes-picker');
    await evaluate(`(async()=>{const api=Object.create(CoreApi.prototype);api.call=async(type,payload)=>{calls.push(['api',type,payload]);return {orderId:5}};await api.submitOrder('plan','fixture','conversation',{waitForPlanApproval:true});await api.replanOrder(5,'cambia');})()`);
    assert.equal(await q(`calls.find(c=>c[0]==='api'&&c[1]==='core.order.submit')[2].waitForPlanApproval`),true);
    assert.deepEqual(await q(`calls.find(c=>c[0]==='api'&&c[1]==='core.order.replan')[2]`),{orderId:5,changes:'cambia'});
    await evaluate(`window.questionPlan={understanding:'Necesito aclarar el lenguaje',questions:[{id:'target-language',text:'¿Qué lenguaje uso?',options:['C','Zig']}],needs_clarification:true,tasks:[],wait_for_plan_approval:true};panel.plan=questionPlan;panel.orderId=42;panel.phase='clarifying';panel.renderBody()`);
    assert.match(await q('document.body.innerText'),/¿Qué lenguaje uso\?/);
    await clickSelector('#btn-discard');
    assert.deepEqual(await q(`calls.filter(c=>c[0]==='cancel').at(-1)`),['cancel',42],'también se puede cancelar ante preguntas');
    await evaluate(`panel.plan=questionPlan;panel.orderId=43;panel.phase='clarifying';panel.renderBody()`);
    await clickSelector('#btn-send-answers');
    await evaluate(`new Promise(r=>setTimeout(r,700))`);
    assert.deepEqual(await q(`calls.find(c=>c[0]==='answer')`),['answer',43,[{question_id:'target-language',answer:'C'}]]);
    assert.match(await q('document.body.innerText'),/Plan con lenguaje aclarado/);
    assert.equal(await q(`calls.filter(c=>c[0]==='dispatch').length`),1,'responder no aprueba ni ejecuta');
    const evidence=path.join(__dirname,'../zig-out/test-evidence/plan-mode');
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 1000, deviceScaleFactor: 1, mobile: false });
    await evaluate(`panel.phase='awaiting-approval';panel.plan=plan;panel.orderId=43;panel.setPlanMode(true);document.getElementById('mission-body').scrollTop=0;window.scrollTo(0,0)`);
    fs.mkdirSync(evidence, { recursive: true });
    fs.writeFileSync(path.join(evidence,'webui-plan-dom.txt'),await q('document.body.innerText'));
    fs.writeFileSync(path.join(evidence,'webui-plan.png'),Buffer.from((await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    fs.writeFileSync(path.join(evidence,'webui-console.txt'),JSON.stringify(browserErrors,null,2));
    assert.deepEqual(browserErrors,[], 'sin errores JS en Chromium');
    console.log('PASS CK-VER1-002: compositor persistente y accesible, campo del motor, entendimiento y tareas, pedir cambios sin ejecutar, aprobar una vez, cancelar por motor; DOM real Chromium. Puente y planificador simulados.');

    // R5: real submit, event drain and order view, with simulated async events.
    // Never append a synthetic badge to the DOM.
    const { checkSelfReviewedOrder, SELF_REVIEW_ORDER } = await import('../tools/prv003_cabina.mjs');
    const dispatchesBefore = await q("calls.filter(c=>c[0]==='dispatch').length");
    await evaluate(`(() => {
      plan={understanding:'Ejecución gobernada sin despacho',needs_clarification:false,questions:[],tasks:[{id:'t1',department:'programacion',task_type:'ejecutar',description:'Ejecutar cmd /c echo PRV003',depends_on:[]}],wait_for_plan_approval:true};
      fake.orderEvents=async(id,since)=>{
        await new Promise(r=>setTimeout(r,35));
        return since<1?[{id:1,kind:'composer_review_v1',payload:{mode:'self_reviewed',label:'Autorrevisada',pending_verdict:true}}]:[];
      };
      panel=new MissionControlPanel(document.getElementById('host'),fake);
      panel.drainNewEvents=window.prv003DrainNewEvents;
      panel.setPlanMode(true);
    })()`);
    await checkSelfReviewedOrder({
      evaluate,
      click: clickSelector,
      wait: async expression => {
        const deadline=Date.now()+5000;
        while(!await q(expression)) {
          assert(Date.now()<deadline,`R5 UI timeout: ${expression}`);
          await new Promise(r=>setTimeout(r,25));
        }
      },
      capture: async name => {
        if(!process.env.PRV003_EVIDENCE_DIR)return;
        fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'r5-dom-'+name+'.txt'),await q('document.body.innerText'));
        const screenshot=await send('Page.captureScreenshot',{format:'png'});
        fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'r5-dom-'+name+'.png'),Buffer.from(screenshot.data,'base64'));
      },
    });
    assert.equal(await q("calls.filter(c=>c[0]==='submit').at(-1)[1]"),SELF_REVIEW_ORDER);
    assert.equal(await q("calls.filter(c=>c[0]==='dispatch').length"),dispatchesBefore);
    assert.equal(await q("panel.phase"),'awaiting-approval');
    assert.deepEqual(browserErrors,[], 'R5 sin errores JS en la vista real de la orden');
    console.log('PASS R5 recorrido compartido paso 5: clic físico Enviar, submit/sondeo/drenaje reales, evento asíncrono simulado, nodo de cabecera Autorrevisada y aprobación pendiente sin despacho');
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
