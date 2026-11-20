// DOM/CSS de producto en Chromium instalado; CoreApi sintética, sin host ni proveedores.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const ts = require('typescript');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

async function run() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-settings-'));
  const executable = resolveBrowser();
  const fixture = path.join(profile, 'settings.html');
  fs.writeFileSync(fixture, '<!doctype html><html lang="es"><head><meta charset="utf-8"></head><body><main id="fixture" style="height:100vh;margin-left:240px"></main></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', sequence = 0, session, stderr = '';
  const pending = new Map();
  const errors = [];
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.stderr.on('data', data => { stderr += data; });
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
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
  async function settled() {
    await evaluate(`new Promise((resolve,reject)=>{let tries=0;const poll=()=>{const b=document.querySelector('#settings-body');if(b?.getAttribute('aria-busy')==='false')resolve();else if(++tries>200)reject(Error('Sección no termina de cargar'));else setTimeout(poll,10)};poll()})`);
  }
  async function open(section) {
    await evaluate(`document.querySelector('[data-section="${section}"]').click()`);
    await settled();
  }
  async function action(expression, method) {
    await evaluate(`window.calls=[];${expression}`);
    await evaluate('new Promise(resolve=>setTimeout(resolve,50))');
    assert(await evaluate(`window.calls.some(call=>call.method===${JSON.stringify(method)})`), `ACTION ${method} no llega al CoreApi sintético`);
  }
  const sourceFile = process.env.DEVAGENTS_SETTINGS_SOURCE || path.join(__dirname, '../src/panes/settings_memory.ts');
  const cssFile = process.env.DEVAGENTS_SETTINGS_CSS || path.join(__dirname, '../src/design/stylesheet.ts');
  const compile = filename => ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename }).outputText;
  const sources = { layout: compile(path.join(__dirname, '../src/layout/layout.ts')), html: compile(path.join(__dirname, '../src/design/html.ts')), settings: compile(sourceFile), css: compile(cssFile), tokens: compile(path.join(__dirname, '../src/design/tokens.ts')), icons: compile(path.join(__dirname, '../src/design/icons.ts')), themes: compile(path.join(__dirname, '../src/design/theme_registry.ts')) };
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(fixture).href }, undefined);
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
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const imports={'../layout/layout':{updatePermissionBadge:()=>{}},'../design/modal':{confirmModal:async()=>false}};
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>{if(!(n in imports))throw Error('Import inesperado '+n);return imports[n]});return mod.exports;}
      imports['../design/html']=load('html');
      const tokens=load('tokens');imports['./tokens']=tokens;const themes=load('themes').themes;
      imports['../design/icons']=load('icons');imports['../design/notice']={notice:()=>{}};imports['../layout/layout']=load('layout');load('css').injectStylesheet();
      window.applyFixtureTheme=id=>{for(const [key,value] of Object.entries(themes[id].colors))document.documentElement.style.setProperty(tokens.cssVar[key],value);document.documentElement.style.colorScheme=themes[id].base;window.themeId=id};
      window.applyFixtureTheme('black');
      const light=Object.values(themes).find(t=>t.base==='light');window.lightTheme=light.id;
      window.themeManager={getAvailableThemes:()=>Object.values(themes),getCurrentThemeId:()=>window.themeId,applyTheme:id=>window.applyFixtureTheme(id)};
      window.calls=[];window.failMethod='';window.emptyFixture=false;window.deferMethod='';
      const provider={name:'Fixture gratuito',api_style:'openai',base_url:'https://example.invalid',is_free_tier:true,keys:[],models:[{name:'modelo-fixture',is_free:true,available:true,context_window:32000}]};
      window.mockCore=new Proxy({},{get:(_,method)=>async(...args)=>{
        window.calls.push({method,args});
        if(method===window.failMethod)throw Error('Fallo sintético <script>malicioso</script>');
        if(method===window.deferMethod)await new Promise(resolve=>window.releaseDeferred=resolve);
        const values={listProviders:window.emptyFixture?[]:[provider],listKeys:[],catalogInfo:{catalog_path_abs:'C:/fixture/catalog.db',model_count:1,provider_count:1,key_count:0},getPlanModel:{provider:'',model:''},getGovernance:{mode:'hybrid'},setGovernance:{mode:args[0]},getBudget:{authorized:8,spent:2,remaining:6},getUsageWeek:{calls:0,total:0,prompt:0,completion:0,by_model:[],limited_keys:[]},listWebhooks:[],remoteStatus:{running:false,url:''},remoteStart:{url:'http://127.0.0.1:12345',token:'synthetic-fixture'},plugins:window.emptyFixture?[]:[{name:'plugin-fixture',folder:'C:/fixture/plugin',trusted:false,capabilities:[]}],pluginsDir:{path:'C:/fixture/plugins'},skills:[],mounts:[],memoryContext:{},status:{version:'fixture',engineReady:true,pid:1234,providerCount:1,keyCount:0},discoverModels:{count:1},pickFolder:{cancelled:false,path:'C:/fixture/skill'},getExternalAgents:window.emptyFixture?[]:[{provider:'agent:codex',cli:'codex',display:'Codex',exe:'C:/fixture/codex.exe',version:'0.98',acp:true,manufacturer:'OpenAI',session:'suscripcion',enumeration_status:'ok',detected_at_ms:0,selection_reason:'',models:[{slug:'gpt-fixture',display_name:'gpt-fixture',manufacturer:'OpenAI',reasoning_efforts:['low','medium','high'],reasoning_effort:'medium'}],label:'Codex (tu suscripción)'}],getExternalPaths:{},getExternalLimits:{task_timeout_ms:900000,task_max_turns:40,order_timeout_ms:3600000,order_max_turns:200},getCliQuotas:[{cli:'codex',format:'fixture',status:'ok',five_hour:{used_percent:38,reset_at:'16:05'},daily:{used_percent:30,reset_at:null},weekly:{used_percent:55,reset_at:null}}]};
        if(!(method in values)&&!['setHooks','setPermissions','forgetElevatedPermissions','setBudgetAuthorized','setPlanModel','setModelFavorite','addProvider','addKey','addMountPath','removeMountPath','trustPlugin','untrustPlugin','addWebhook','testWebhook','deleteWebhook','remoteStop','refreshExternalAgents','setExternalPaths','setExternalModelOptions','setExternalLimits'].includes(method))throw Error('Método no preparado '+method);
        return values[method];
      }});
      window.Settings=load('settings').UnifiedSettingsPanel;
      window.panel=new window.Settings(document.querySelector('#fixture'),window.mockCore);
    })()`);
    await settled();
    const controls = {
      providers: ['#form-add-key', '#key-provider', '#key-label', '#key-value', '#btn-toggle-add-provider'],
      models: ['#btn-discover-models', '#sel-plan-model', '#model-filter', '#model-table-body'],
      governance: ['.btn-gov-mode', '#inp-budget-authorized', '#btn-budget-save', '#usage-week-card'],
      permissions: ['.btn-perm-mode', '#perm-forget-elevated', '#perm-allow-input', '#perm-allow-add', '#perm-deny-input', '#perm-deny-add'],
      hooks: ['#hooks-enabled', '#hook-pre-edit', '#hook-post-edit', '#hook-pre-cmd', '#hook-post-cmd', '#hooks-save'],
      remote: ['#webhook-form', '#webhook-format', '#webhook-url', '#webhook-topic', '#webhook-secret', '#webhook-allow-private', '#remote-port', '#remote-origin', '#remote-start', '#remote-stop'],
      skills: ['#mount-input', '#mount-browse', '#mount-add'], plugins: ['#plugins-refresh', '.btn-plugin-trust'],
      memory: ['.empty-state', '.empty-state button'], appearance: ['.btn-theme', '.btn-layout', '#window-card', '#zoom-in'], about: ['.settings-card', '#btn-settings-refresh', '#help-card', '#help-tutorial'],
      // (e): «Agentes externos» de la maqueta (pág. 5), con los datos del motor.
      agents: ['#agents-refresh', '.agent-card', '.agent-path', '.agent-effort', '#lim-save', '.settings-tag--falta'],
    };
    let sections = 0, widths = 0, actions = 0;
    for (const width of [1024, 1440]) {
      await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
      for (const [section, selectors] of Object.entries(controls)) {
        await open(section);
        assert(await evaluate(`document.querySelector('#settings-body').getAttribute('role')==='region'&&document.querySelector('#settings-section-title')?.textContent.length>0`), 'GUARD hierarchy: región y título accesible');
        assert(await evaluate(`document.querySelector('[data-section="${section}"]').getAttribute('aria-current')==='page'`));
        for (const selector of selectors) assert(await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`), `CONTROL ${section} ${selector}`);
        assert(await evaluate(`!!document.querySelector('#settings-body .settings-card')`), `CARD ${section}`);
        const unlabeled = await evaluate(`[...document.querySelectorAll('#settings-body input,#settings-body select,#settings-body textarea')].filter(e=>!e.labels?.length&&!e.hasAttribute('aria-label')&&!e.hasAttribute('aria-labelledby')).map(e=>e.id)`);
        assert.deepEqual(unlabeled, [], `LABEL ${section}`);
        const geometry = await evaluate(`({document:document.documentElement.scrollWidth,viewport:innerWidth,body:document.querySelector('#settings-body').scrollWidth,client:document.querySelector('#settings-body').clientWidth})`);
        assert(geometry.document <= width && geometry.body <= geometry.client + 1, `GUARD responsive: ${section} ${width} ${JSON.stringify(geometry)}`);
        console.log(`PASS render ${section} width=${width} controls=${selectors.length} geometry=${JSON.stringify(geometry)}`);
        if (process.env.DEVAGENTS_SETTINGS_CAPTURE) {
          const prefix = process.env.DEVAGENTS_SETTINGS_CAPTURE + `-${section}-${width}`;
          fs.writeFileSync(prefix + '.txt', await evaluate("document.querySelector('#fixture').innerText"));
          const shot = await send('Page.captureScreenshot', { format: 'png' });
          fs.writeFileSync(prefix + '.png', Buffer.from(shot.data, 'base64'));
          console.log('CAPTURE fixture sintético=' + prefix + '.png');
        }
        sections++; widths++;
      }
    }
    await open('providers');
    await action("document.querySelector('#btn-toggle-add-provider').click();document.querySelector('#np-name').value='fixture-nuevo';document.querySelector('#np-url').value='https://example.invalid';document.querySelector('#form-add-provider').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))", 'addProvider'); actions++;
    await open('models'); await action("document.querySelector('#sel-plan-model').value='Fixture gratuito|modelo-fixture';document.querySelector('#sel-plan-model').dispatchEvent(new Event('change',{bubbles:true}))", 'setPlanModel'); actions++;
    await open('governance'); await action("document.querySelector('#inp-budget-authorized').value='9';document.querySelector('#btn-budget-save').click()", 'setBudgetAuthorized'); actions++;
    await open('permissions'); await action("document.querySelector('#perm-allow-input').value='git status';document.querySelector('#perm-allow-add').click()", 'setPermissions'); actions++;
    await open('permissions'); await action("document.querySelector('#perm-forget-elevated').click()", 'forgetElevatedPermissions'); actions++;
    await open('hooks'); await action("document.querySelector('#hooks-save').click()", 'setHooks'); actions++;
    await open('remote'); await action("document.querySelector('#webhook-url').value='https://example.invalid/avisos';document.querySelector('#webhook-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))", 'addWebhook'); actions++;
    await action("document.querySelector('#remote-start').click()", 'remoteStart'); actions++;
    assert(await evaluate("!document.querySelector('#remote-once').hidden&&document.querySelector('#remote-token').type==='password'"));
    await evaluate("document.querySelector('#remote-hide').click()");
    assert(await evaluate("document.querySelector('#remote-once').hidden&&document.querySelector('#remote-token').value===''") );
    await action("document.querySelector('#remote-stop').click()", 'remoteStop'); actions++;
    await open('skills'); await action("document.querySelector('#mount-input').value='C:/fixture';document.querySelector('#mount-add').click()", 'addMountPath'); actions++;
    await open('plugins'); await action("document.querySelector('.btn-plugin-trust').click()", 'trustPlugin'); actions++;
    await open('memory'); await action("document.querySelector('.empty-state button').click()", 'memoryContext'); actions++;
    await open('appearance'); await evaluate("document.querySelector('[data-theme=\"'+window.lightTheme+'\"]').click()");
    assert(await evaluate("window.themeManager.getCurrentThemeId()===window.lightTheme&&document.querySelector('[aria-pressed=\"true\"]').dataset.theme===window.lightTheme")); actions++;
    await open('about'); await action("document.querySelector('#btn-settings-refresh').click()", 'status'); actions++;
    console.log(`PASS acciones originales=${actions}`);
    await open('remote');
    await evaluate("document.querySelector('#webhook-empty-add').click()");
    assert.equal(await evaluate('document.activeElement.id'), 'webhook-url');
    assert.equal(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), 'solid', 'GUARD focus: control enfocado tiene outline visible');
    for (const [section, method] of [['providers', 'listProviders'], ['models', 'listProviders'], ['governance', 'getBudget'], ['permissions', 'setPermissions'], ['remote', 'listWebhooks'], ['skills', 'skills'], ['plugins', 'plugins'], ['memory', 'memoryContext'], ['about', 'status']]) {
      await open(section);
      await evaluate(`window.failMethod=${JSON.stringify(method)};window.panel.refresh()`); await settled();
      assert(await evaluate("!!document.querySelector('#settings-body [role=alert]')&&document.querySelector('#settings-body').innerText.includes('Fallo sintético <script>malicioso</script>')"), `ERROR ${section}`);
      assert.equal(await evaluate("document.querySelector('#settings-body script')===null"), true, `ESCAPE ${section}`);
      await evaluate("window.failMethod='';window.panel.refresh()"); await settled();
    }
    await open('remote'); await evaluate("window.deferMethod='listWebhooks';window.pendingRefresh=window.panel.refresh();void 0");
    assert(await evaluate("document.querySelector('#settings-body').getAttribute('aria-busy')==='true'&&document.querySelector('.settings-loading').getAttribute('role')==='status'"), 'GUARD loading: carga anunciada');
    await evaluate("window.deferMethod='';window.releaseDeferred();window.pendingRefresh"); await settled();
    await evaluate("window.emptyFixture=true");
    for (const section of ['providers', 'models', 'skills', 'plugins', 'memory']) {
      await open(section); await evaluate('window.panel.refresh()'); await settled();
      assert(await evaluate("!!document.querySelector('#settings-body .empty-state svg')&&!!document.querySelector('#settings-body .empty-state button')"), `EMPTY ${section}`);
    }
    assert.deepEqual(errors, [], 'Sin excepciones de navegador');
    console.log(`PASS Settings: ${sections} renders/12 pestañas, ${widths} mediciones de ancho, ${actions} acciones, 9 errores/escape, carga, vacíos y foco. Fixture sintético; cabina pendiente.`);
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
      console.log('TEMPORAL_RETIRADO=' + profile);
    }
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
