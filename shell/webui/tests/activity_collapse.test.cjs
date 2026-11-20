// — la barra de actividad con la barra lateral plegada.
//
// Bug: con `.sidebar[data-collapsed='true']`, pulsar `.activity-bar__item`
// cambiaba la vista pero la barra seguía en su franja plegada, así que parecía
// que no pasaba nada. Debe desplegarse mostrando ESE panel y persistir el
// estado con la misma clave de localStorage, icono y título que el botón de
// plegar; con la barra ya desplegada el comportamiento no cambia.
//
// DOM/CSS de producto en Chromium instalado; CoreApi sintética, sin host ni
// motor. Desde shell/webui: node tests/activity_collapse.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function activityCollapse() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-cab020-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'cab020.html');
  fs.writeFileSync(html, '<!doctype html><html lang="es"><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
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
  async function click(id) {
    const point = await evaluate(`(() => {const r=document.getElementById(${JSON.stringify(id)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
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
    const files = { layout: 'src/layout/layout.ts', icons: 'src/design/icons.ts', style: 'src/design/stylesheet.ts', tokens: 'src/design/tokens.ts', html: 'src/design/html.ts', router: 'src/app/view_router.ts' };
    const sources = Object.fromEntries(Object.entries(files).map(([name, file]) => {
      const input = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
      const out = ts.transpileModule(input, { reportDiagnostics: true, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
      assert.equal((out.diagnostics || []).length, 0, 'Transpilación sin diagnósticos: ' + file);
      return [name, out.outputText];
    }));
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      const mods={};
      const imports={
        '../design/notice':{notice:message=>window.notices.push(message)},
        '../bridge/core_api':{CoreApi:class {}},
        '../terminal/xterm_terminal':{XtermTerminal:class {}},
        '../panes/SpacesPanel':{SpacesPanel:class {}},
        '../design/file_icons':{fileIcon:()=>({color:'',svg:''}),folderIcon:()=>({color:'',svg:''})},
        '../design/modal':{promptModal:async()=>null,confirmModal:async()=>false},
        '../session_groups':{grupoPorFecha:()=>'',coincideBusqueda:()=>false,agruparPorConversacion:()=>[],planPendienteVigente:()=>false,ordenarPorReciente:()=>[]},
      };
      function load(name){const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||mods[n]||{});mods[name]=mod.exports;return mod.exports;}
      window.notices=[];
      const icons=load('icons'); imports['../design/icons']=icons; window.icons=icons.icons;
      const html=load('html'); imports['../design/html']=html;
      const tokens=load('tokens'); imports['./tokens']=tokens;
      load('style').injectStylesheet();
      const layout=load('layout'); imports['../layout/layout']=layout;
      // (c): esta prueba cubre el plegado de A · IDE clásica; el de B lo cubre layout_b.test.cjs.
      localStorage.setItem('devagents.layout.v1','A'); document.documentElement.dataset.layout='A';
      layout.renderLayout(document.body);
      window.initPanelToggles=()=>layout.initPanelToggles();
      const vr=load('router');
      const router=Object.create(vr.ViewRouter.prototype);
      router.current='agent';
      router.panes={mission:document.getElementById('pane-mission-container'),editor:document.getElementById('monaco-editor-container'),verification:document.getElementById('pane-verification-container'),catalog:document.getElementById('pane-catalog-container'),settings:document.getElementById('pane-settings-container'),mcp:document.getElementById('pane-mcp-container'),issues:document.getElementById('pane-issues-container'),monitor:document.getElementById('pane-monitor-container'),diff:document.getElementById('pane-diff-container')};
      router.hooks={};
      router.spacesPanel=null;
      router.treeRoot='';
      router.core={listDir:async()=>({root:'',entries:[]}),listSessions:async()=>[],repoEmbedStatus:async()=>({state:'empty'})};
      router.bindActivityBar();
      window.initPanelToggles();
    })()`);

    const read = () => evaluate(`(() => {
      const sidebar=document.getElementById('sidebar-primary');
      const btn=document.getElementById('btn-sidebar-collapse');
      const tmp=document.createElement('div'); tmp.innerHTML=window.icons.chevronLeft(14);
      return {
        collapsed: sidebar.dataset.collapsed,
        stored: localStorage.getItem('devagents.panel.left'),
        buttonTitle: btn.title,
        buttonIcon: btn.innerHTML,
        expandedIcon: tmp.innerHTML,
        sidebarTitle: document.getElementById('sidebar-title').textContent,
        sidebarWidth: sidebar.getBoundingClientRect().width,
        activeViews: Array.from(document.querySelectorAll('.activity-bar__item.is-active')).map(el=>el.dataset.view),
      };
    })()`);

    // Arranque: la barra lateral está desplegada.
    let s = await read();
    assert.equal(s.collapsed, 'false', 'Arranca desplegada');

    // Plegar con el botón real: referencia de cómo debe quedar al desplegar.
    await click('btn-sidebar-collapse');
    s = await read();
    assert.equal(s.collapsed, 'true', 'El botón pliega');
    assert.equal(s.stored, 'true', 'El botón guarda el plegado');
    assert.equal(s.buttonTitle, 'Desplegar barra lateral');
    assert.ok(s.sidebarWidth <= 40, `Franja plegada estrecha (${s.sidebarWidth}px)`);

    // El caso del encargo: pulsar un icono con la barra plegada.
    await click('act-issues');
    s = await read();
    assert.equal(s.collapsed, 'false', 'GUARD CK-CAB-020: el icono de actividad despliega la barra');
    assert.equal(s.stored, 'false', 'Se guarda con la misma clave que el botón de plegar');
    assert.equal(s.buttonTitle, 'Plegar barra lateral', 'Mismo título que el botón de plegar');
    assert.equal(s.buttonIcon, s.expandedIcon, 'Mismo icono que el botón desplegado');
    assert.equal(s.sidebarTitle, 'Incidencias', 'Muestra la barra lateral de ESE panel');
    assert.deepEqual(s.activeViews, ['issues'], 'Ese icono queda activo');
    assert.ok(s.sidebarWidth > 200, `Barra lateral desplegada visible (${s.sidebarWidth}px)`);

    // Otro icono distinto vuelve a desplegar mostrando SU panel.
    await click('btn-sidebar-collapse');
    await click('act-search');
    s = await read();
    assert.equal(s.collapsed, 'false');
    assert.equal(s.sidebarTitle, 'Búsqueda global');
    assert.deepEqual(s.activeViews, ['search']);
    assert.equal(s.stored, 'false');

    // Con la barra ya desplegada, pulsar otro icono no altera la persistencia.
    await click('act-explorer');
    s = await read();
    assert.equal(s.collapsed, 'false', 'Ya desplegada, el icono no la pliega');
    assert.equal(s.stored, 'false', 'La persistencia no cambia al ya estar desplegada');
    assert.equal(s.sidebarTitle, 'Explorador de archivos');

    console.log('PASS CK-CAB-020: el icono de actividad despliega la barra lateral, muestra SU panel y persiste igual que el botón; ya desplegada el comportamiento no cambia.');
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
