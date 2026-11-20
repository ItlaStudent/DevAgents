const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function composerRolesBrowser() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-prv003-'));
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
    const sources = Object.fromEntries(['mission_control_ux', 'order_graph_ux', 'stylesheet_ux', 'tokens_ux', 'html_ux', 'external_models', 'core_api_prv004', 'bridge_client_prv003', 'onboarding_prv003', 'doctor_view_prv003'].map(name => [name, fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8')]));

    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={'../design/alerts':{raiseAlert:()=>{},clearAlert:()=>{},clearAlertsExcept:()=>{}},'../design/notice':{notice:m=>{throw Error(m)}},'../design/icons':{icons:new Proxy({},{get:()=>()=>''})},'../design/orbit_backdrop':{orbitBackdrop:()=>''}};
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return mod.exports;}
      imports['./tokens']=load('tokens_ux');imports['../design/html']=load('html_ux');imports['../external_models']=load('external_models');imports['../bridge/core_api']=load('core_api_prv004');imports['./order_graph']=load('order_graph_ux');load('stylesheet_ux').injectStylesheet();
      const p=Object.create(load('mission_control_ux').MissionControlPanel.prototype);
      Object.assign(p,{container:document.body,core:null,hooks:{},modelQuery:'',modelPickerOpen:false,modelRows:[],pinnedRoles:{plan:'',exec:'',audit:''},swarmSelection:[],swarmAuto:true,swarmEnabled:true});
      p.renderBody=()=>{};p.render();
      const pins={plan:{},exec:{},audit:{}};const extra={};const calls=[];let enabled=true;
      p.core={
        listProviders:async()=>[{name:'HTTP',models:[{name:'chat-free',is_free:true,available:true},{name:'other-free',is_free:true,available:true},{name:'paid-chat',is_free:false},{name:'hidden-chat',is_free:true},{name:'embedding',text_gen:false,is_free:true}]}],
        getPlanModel:async()=>pins.plan,getExecModel:async()=>pins.exec,getAuditModel:async()=>pins.audit,
        setPlanModel:async(provider,model)=>{calls.push(['plan',provider,model]);pins.plan={provider,model};},
        setExecModel:async(provider,model)=>{calls.push(['exec',provider,model]);pins.exec={provider,model};},
        setAuditModel:async(provider,model)=>{calls.push(['audit',provider,model]);pins.audit={provider,model};},
        getRoleModels:async()=>Object.values(extra),
        setRoleModel:async(role,provider,model)=>{calls.push([role,provider,model]);if(provider)extra[role]={role,provider,model};else delete extra[role];},
        getSwarmModels:async()=>[{provider:'HTTP',model:'chat-free'},{provider:'HTTP',model:'other-free'}],
        getSwarmEnabled:async()=>({enabled}),setSwarmEnabled:async value=>{enabled=value;},
        getGovernance:async()=>({mode:'free'}),getExternalAgents:async()=>[{provider:'agent:opencode',cli:'opencode',display:'OpenCode',session:'suscripcion',models:[{slug:'opencode/chat-free',display_name:'CLI gratis',free:true,text_gen:true}]}],
        setDeterministic:async value=>{window.noFallback=value;},
        getExternalPaths:async()=>({}),
        modelSelection:async()=>[{provider:'HTTP',model:'hidden-chat',show_in_selectors:false}],
        orderPreflight:async()=>({allowed:true,issues:[],message:''}),
      };
      window.panel=p;window.roleCalls=calls;window.rolePins=pins;
      window.loadPrv003=load;window.prv003Imports=imports;
    })()`);
    await evaluate('panel.refreshModelPickers()');
    await evaluate('panel.toggleModelPicker(true)');
    assert.equal(await evaluate("document.querySelectorAll('#model-role-rows select').length"),0);
    await evaluate("document.querySelector('#model-list [data-val=\"HTTP|chat-free\"]').click()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate("rolePins.plan.model"),'chat-free');
    assert.match(await evaluate("document.querySelector('#model-audit-warning').textContent"),/Revisión por decidir/);
    assert.doesNotMatch(await evaluate("document.querySelector('#model-audit-warning').textContent"),/Autorrevisada|Auditada/);
    await evaluate("document.querySelector('#model-search').value='does-not-match';document.querySelector('#model-search').dispatchEvent(new Event('input'))");
    await evaluate("document.querySelector('#model-list [data-val=\"\"]').click()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate("rolePins.plan.provider"),'');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'');
    console.log('PASS C2 DOM: elegir modelo y volver a Automático con búsqueda activa');
    await evaluate("document.querySelector('#model-search').value='';document.querySelector('#model-search').dispatchEvent(new Event('input'));document.querySelector('#model-list [data-val=\"agent:opencode|opencode/chat-free\"]').click()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'agent:opencode|opencode/chat-free');
    await evaluate("document.querySelector('#model-list [data-val=\"\"]').click()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate('rolePins.exec.provider'),'');
    assert.equal(await evaluate("document.querySelector('#sel-model').value"),'');
    console.log('PASS C2 DOM: CLI seleccionada en Modelo vuelve a Automático y limpia pin implícito');
    await evaluate("(() => {const c=document.querySelector('#chk-deterministic');c.checked=true;c.dispatchEvent(new Event('change'));})()");
    for(const role of ['exec','audit','second_audit','programmer','sidekick']) {
      await evaluate(`document.querySelector('#sel-add-role').value=${JSON.stringify(role)};document.querySelector('#btn-add-role').click()`);
      assert.equal(await evaluate(`document.querySelectorAll('[data-role-row=${role}]').length`),1);
      const options=await evaluate(`document.querySelector('[data-role=${role}]').innerHTML`);
      assert.match(options,/chat-free/);assert.doesNotMatch(options,/paid-chat|hidden-chat|embedding/);
      await evaluate(`(() => {const s=document.querySelector('[data-role=${role}]');s.value='HTTP|chat-free';s.dispatchEvent(new Event('change',{bubbles:true}));})()`);
      await evaluate("new Promise(r=>setTimeout(r,60))");
      assert.deepEqual(await evaluate('roleCalls.at(-1)'),[role,'HTTP','chat-free']);
      assert.equal(await evaluate("document.querySelector('#chk-swarm-enabled').checked"),true);
      assert.equal(await evaluate("document.querySelector('#chk-deterministic').checked"),true);
      await evaluate(`document.querySelector('[data-remove-role=${role}]').click()`);
      await evaluate("new Promise(r=>setTimeout(r,60))");
      assert.deepEqual(await evaluate('roleCalls.at(-1)'),[role,'','']);
      assert.equal(await evaluate(`document.querySelectorAll('[data-role-row=${role}]').length`),0);
    }
    console.log('PASS C2 C4 C5 DOM: cinco roles, envío y borrado del pin, enjambre activo, solo gratis/chat/visibles');
    await evaluate("(() => {const c=document.querySelector('#chk-swarm-enabled');c.checked=false;c.dispatchEvent(new Event('change'));})()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate('panel.swarmEnabled'),false);
    assert.equal(await evaluate('panel.swarmSelection.length'),2);
    await evaluate("(() => {const c=document.querySelector('#chk-swarm-enabled');c.checked=true;c.dispatchEvent(new Event('change'));})()");
    await evaluate("new Promise(r=>setTimeout(r,60))");
    assert.equal(await evaluate('panel.swarmEnabled'),true);
    await evaluate("document.querySelector('#model-search').value='';document.querySelector('#model-search').dispatchEvent(new Event('input'));document.querySelector('#model-advanced').open=true");
    const dump=await evaluate('document.body.innerText');
    assert.match(dump,/Revisión por decidir/); assert.match(dump,/Sin respaldo/);
    // Synthetic DOM acceptance of the native event contract; not a live order.
    await evaluate(`(() => {
      panel.orderId=7;panel.phase='running';panel.events=[{kind:'composer_review_v1',payload:{mode:'self_reviewed'}}];
      const e=document.createElement('div');e.id='synthetic-order-review';e.innerHTML=panel.orderPinBadge();document.body.appendChild(e);
    })()`);
    assert.match(await evaluate("document.querySelector('#synthetic-order-review').textContent"),/Autorrevisada/);
    assert.doesNotMatch(await evaluate("document.querySelector('#synthetic-order-review').textContent"),/Auditada/);
    console.log('PASS C3 C4 DOM: compositor neutro, evento efectivo simulado Autorrevisada, Sin respaldo y enjambre conserva miembros');
    // Regression of the orchestrator's exact steps 1/2. Real CoreApi and
    // BridgeClient; only the native host is simulated, with its FIFO fast/slow
    // queues, JSON envelopes and separate message tasks (never sync setters).
    await evaluate(`(() => {
      const trace=[];let listener;let fast=Promise.resolve(),slow=Promise.resolve();
      const pins={plan:{provider:'',model:''},exec:{provider:'',model:''},audit:{provider:'',model:''}};
      const responses={
        'core.providers.list':[{name:'prv003-local',local:true,models:[{name:'gpt-fixture',is_free:true,text_gen:true}]}],
        'core.swarm.getModels':[], 'core.governance.get':{mode:'local'},
        'core.external.agents':[], 'core.models.selection.v1':[], 'core.roles.getModels':[],
        'core.swarm.getEnabled':{enabled:true},
        'core.composer.review':{mode:'undecided',label:'Revisión por decidir',pending_verdict:true},
        'core.order.preflight':{allowed:true,issues:[],message:''},'core.external.paths.get':{},
      };
      window.chrome={webview:{
        addEventListener:(kind,fn)=>{if(kind==='message')listener=fn;},
        postMessage:raw=>{
          const message=JSON.parse(raw),isSlow=message.kind==='core.external.agents';
          trace.push(['send',message.kind,message.payload]);
          const task=async()=>{
            await new Promise(r=>setTimeout(r,isSlow?120:5));
            if(isSlow && window.holdExternal)await new Promise(r=>window.releaseExternal=r);
            let payload;const pin=message.kind.match(/^core\\.(plan|exec|audit)\\.(set|get)Model$/);
            if(pin){
              if(pin[2]==='set'){pins[pin[1]]={...message.payload};payload={applied:true};}
              else payload={...pins[pin[1]]};
            }else{
              if(!(message.kind in responses))throw Error('Unexpected native request '+message.kind);
              payload=responses[message.kind];
            }
            trace.push(['response',message.kind,payload]);
            await new Promise(r=>setTimeout(()=>{listener({data:JSON.stringify({id:message.id,status:'ok',payload})});r();},0));
          };
          if(isSlow)slow=slow.then(task);else fast=fast.then(task);
        },
      }};
      const {BridgeClient}=loadPrv003('bridge_client_prv003');
      const {CoreApi}=loadPrv003('core_api_prv004');
      panel.core=new CoreApi(new BridgeClient());panel.externalDetail='';panel.mainCliChoice='';
      window.nativeTrace=trace;window.nativePins=pins;
      prv003Imports['../design/tokens']=loadPrv003('tokens_ux');
      prv003Imports['./doctor_view']=loadPrv003('doctor_view_prv003');
      window.nativeWelcome=new (loadPrv003('onboarding_prv003').OnboardingModal)();
      nativeWelcome.show();
    })()`);
    await evaluate('panel.refreshModelPickers()');
    const { checkModelAutomatic } = await import('../../../tools/prv003_cabina.mjs');
    const controls = {
      evaluate,
      wait: async expression => {
        const deadline=Date.now()+2500;
        while(!await evaluate(expression)) {
          assert(Date.now()<deadline,`UI timeout: ${expression}; trace=${JSON.stringify(await evaluate('nativeTrace'))}`);
          await new Promise(r=>setTimeout(r,15));
        }
      },
      click: async selector => {
        const point=await evaluate(`(() => {const e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
        for(const type of ['mousePressed','mouseReleased']) await send('Input.dispatchMouseEvent',{type,...point,button:'left',clickCount:1});
      },
      select: async (selector,value) => {
        const previous=await evaluate(`document.querySelector(${JSON.stringify(selector)}).dataset.committed`);
        const reads=await evaluate("nativeTrace.filter(r=>r[0]==='send'&&r[1]==='core.external.agents').length");
        await evaluate('window.holdExternal=true');
        try {
          await evaluate(`(() => {const e=document.querySelector(${JSON.stringify(selector)});e.value=${JSON.stringify(value)};e.dispatchEvent(new Event('change',{bubbles:true}));})()`);
          await controls.wait(`nativeTrace.filter(r=>r[0]==='send'&&r[1]==='core.external.agents').length>${reads} && !!window.releaseExternal`);
          assert.equal(await evaluate(`document.querySelector(${JSON.stringify(selector)}).dataset.committed`),previous,'R4 committed must await the refreshed native state, not just the setter acknowledgement');
        } finally {
          await evaluate('window.holdExternal=false;window.releaseExternal?.();window.releaseExternal=null');
        }
      },
      capture: async name => {
        if(!process.env.PRV003_EVIDENCE_DIR)return;
        fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'r4-async-'+name+'.txt'),await evaluate('document.body.innerText'));
        const screenshot=await send('Page.captureScreenshot',{format:'png'});
        fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'r4-async-'+name+'.png'),Buffer.from(screenshot.data,'base64'));
      },
    };
    try {
      await checkModelAutomatic(controls);
      assert.deepEqual(await evaluate('nativePins.plan'),{provider:'',model:''});
      assert.match(await evaluate("document.querySelector('#model-chip-label').textContent"),/^Automático( · .*colmena)?$/);
      const setters=(await evaluate('nativeTrace')).filter(r=>r[0]==='send'&&r[1]==='core.plan.setModel');
      assert.deepEqual(setters.map(r=>r[2]),[{provider:'prv003-local',model:'gpt-fixture'},{provider:'',model:''}]);
      console.log('PASS R4 recorrido compartido: tutorial, eventos físicos, CoreApi/BridgeClient y host asíncrono FIFO; modelo y Automático confirmados por núcleo');
    } finally {
      console.log('R4_NATIVE_TRACE='+JSON.stringify(await evaluate('nativeTrace')));
    }
    // Tanda 4 (F0.5): «Comprobar este equipo» en el paso 1 del tutorial.
    await evaluate(`(() => {
      window.doctorCalls=0;
      window.core={...(window.core||{}),doctor:async()=>{doctorCalls++;return {version:1,ready:false,checks:[
        {id:'data_dir',status:'ok',title:'Carpeta de datos',detail:'C:\\\\datos',fix:''},
        {id:'webview2',status:'falla',title:'Runtime de WebView2',detail:'no está instalado <img src=x onerror="window.pwned=1">',fix:'Instala el Evergreen Runtime'},
        {id:'git',status:'aviso',title:'git',detail:'no está en el PATH',fix:'Instálalo desde git-scm.com'},
      ]};}};
      nativeWelcome.show();
    })()`);
    await evaluate(`document.querySelector('.ob-action[data-action="doctor"]').click()`);
    {
      const deadline=Date.now()+2500;
      while(!await evaluate(`document.querySelectorAll('#ob-doctor-list .doctor-row').length>0`)){
        assert(Date.now()<deadline,'doctor no pintó el informe');
        await new Promise(r=>setTimeout(r,15));
      }
    }
    assert.equal(await evaluate('doctorCalls'),1);
    assert.match(await evaluate(`document.querySelector('#ob-status-doctor').textContent`),/Falta 1 cosa antes de la primera orden/);
    // Solo lo que hay que arreglar: la fila ok no aparece.
    assert.deepEqual(await evaluate(`[...document.querySelectorAll('#ob-doctor-list .doctor-row')].map(r=>r.dataset.doctorId)`),['webview2','git']);
    assert.match(await evaluate(`document.querySelector('#ob-doctor-list [data-doctor-id="webview2"] .doctor-fix').textContent`),/Evergreen/);
    // El texto del motor nunca se interpreta como HTML.
    assert.equal(await evaluate(`document.querySelectorAll('#ob-doctor-list img').length`),0);
    assert.equal(await evaluate('window.pwned===undefined'),true);
    assert.match(await evaluate(`document.querySelector('#ob-doctor-list').textContent`),/<img src=x/);
    console.log('PASS T4 doctor: el tutorial pide el informe, enseña solo lo que falla y no interpreta HTML');
    await evaluate('nativeWelcome.hide()');
    if(process.env.PRV003_EVIDENCE_DIR) {
      fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'dom-synthetic.txt'),await evaluate('document.body.innerText'));
      const screenshot=await send('Page.captureScreenshot',{format:'png'});
      fs.writeFileSync(path.join(process.env.PRV003_EVIDENCE_DIR,'dom-synthetic.png'),Buffer.from(screenshot.data,'base64'));
    }
    assert.equal(browserErrors.length,0,JSON.stringify(browserErrors));
  } finally {
    try { await send('Browser.close', {}, undefined); } catch(error) { console.log('Browser close: '+error.message); }
    child.kill();
    await new Promise(resolve=>child.exitCode!==null?resolve():child.once('exit',resolve));
    fs.rmSync(profile,{recursive:true,force:true,maxRetries:10,retryDelay:200});
  }
};
if(require.main===module)module.exports().catch(error=>{console.error(error);process.exitCode=1;});
