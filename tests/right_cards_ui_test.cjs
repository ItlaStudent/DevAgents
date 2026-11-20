// E1-E6 + r2 — columna derecha como pila de ventanas plegables
// (Entorno, Contexto, Resultados, Cambios, Tareas, Actividad), fila de
// herramientas y Terminal como panel propio. Arnés: Chromium real por CDP, igual que
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
const { resolveBrowser } = require('./browser_resolver.cjs');

module.exports = async function rightCardsUi() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-rel-rightcards-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'right-cards.html');
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
  // CK025_RED=1: modo de recoleccion para la corrida ROJA sobre el codigo de
  // main; cada seccion nueva informa PASS/FAIL por separado en vez de cortar la
  // corrida en el primer fallo. Sin la variable, un fallo aborta como siempre.
  const collect = process.env.CK025_RED === '1';
  const sections = [];
  async function sec(name, fn) {
    try { await fn(); sections.push([name, true]); console.log('SECTION PASS ' + name); }
    catch (error) {
      if (!collect) throw error;
      sections.push([name, false]);
      console.log('SECTION FAIL ' + name + ' :: ' + String(error && error.message || error).split(String.fromCharCode(10))[0].slice(0, 220));
    }
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
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });

    const componentBundle = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/right_cards.test.cjs'), 'utf8');
    const stylesBundle = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/right_cards_styles.test.cjs'), 'utf8');

    // 1. Tema de la referencia + hoja real + componente real.
    await evaluate(`(() => {
      const root = document.documentElement.style;
      const vars = {'--bg-app':'#0A0A0A','--bg-titlebar':'#0A0A0A','--bg-sidebar':'#0A0A0A','--bg-activitybar':'#0A0A0A','--bg-statusbar':'#0A0A0A','--surface-1':'#131312','--surface-2':'#1E1D1B','--border':'rgba(250,247,244,0.07)','--border-strong':'rgba(250,247,244,0.16)','--fg':'#F2EFE9','--fg-muted':'#C7C1B8','--fg-subtle':'#9A958E','--accent':'#D9D3C7','--accent-soft':'rgba(217,211,199,0.2)','--accent-contrast':'#0A0A0A','--bg-panel':'#111110','--bg-main':'#0A0A0A','--success':'#79996A','--warning':'#C89246','--danger':'#C4553D'};
      for (const [k,v] of Object.entries(vars)) root.setProperty(k, v);
      const styles = {exports:{}};
      new Function('module','exports',${JSON.stringify(stylesBundle)})(styles, styles.exports);
      styles.exports.injectStylesheet();
      const comp = {exports:{}};
      new Function('module','exports',${JSON.stringify(componentBundle)})(comp, comp.exports);
      const Real = comp.exports.RightCardsPanel;
      window.RightCardsPanel = class extends Real { constructor(h, co, a, o) { super(h, co, a, o || { pollMs: 3600000 }); } };
      window.RightCardsReal = Real;
      window.rcFormat = comp.exports.formatTokens; window.rcPath = comp.exports.isEngineInternalPath;
      return true;
    })()`);

    // 2. Columna real: panel-secondary con su hueco principal y los dos hosts
    //    que crea main.ts (tarjetas arriba, chat debajo).
    await evaluate(`(() => {
      document.body.innerHTML = '<div id="app-shell" style="display:flex;height:100vh"><main class="central" id="panel-secondary" style="width:360px;flex:0 0 360px;position:relative"><div class="col grow" id="panel-secondary-main" style="min-height:0;position:relative"></div></main></div>';
      const main = document.getElementById('panel-secondary-main');
      const rcHost = document.createElement('div'); rcHost.id = 'right-cards-host'; rcHost.style.width='100%'; main.appendChild(rcHost);
      window.rcEvents = [];
      for (const name of ['devagents:open-file','devagents:settings-section']) document.addEventListener(name, e => window.rcEvents.push([name, e.detail]));
      window.rcLog = [];
      window.rcActions = {
        togglePanel: () => window.rcLog.push('panel'),
        toggleTerminal: () => window.rcLog.push('terminal'),
        toggleActivity: () => window.rcLog.push('activity'),
        toggleBrowser: () => window.rcLog.push('browser'),
        showExplorer: () => window.rcLog.push('explorer'),
        showMenu: () => window.rcLog.push('menu'),
        activeOrderId: () => window.rcOrderId || 0,
      };
      window.rcStub = (over = {}) => ({
        calls: { listDir: 0, gitBranch: 0, gitStatus: 0, gitCommit: 0, remoteStatus: 0, listArtifacts: 0, cancelOrder: 0, listSessions: 0, usageSummary: 0, listProviders: 0 },
        sessions: over.sessions || null, usage: over.usage || null, providers: over.providers || null, artifactsByOrder: over.artifactsByOrder || null,
        args: {},
        root: over.root !== undefined ? over.root : 'C:\\\\proyectos\\\\calculadora',
        repo: over.repo || { isRepo: true, branch: 'main' },
        remote: over.remote || { running: false, url: '', pid: 0 },
        artifacts: over.artifacts || [],
        orderId: over.orderId || 0,
        changes: over.changes || [],
        counts: over.counts || { added: 0, removed: 0 },
        commitError: over.commitError || null,
        async listDir() { this.calls.listDir++; return { root: this.root, entries: [] }; },
        async gitBranch(r) { this.calls.gitBranch++; this.args.gitBranchRoot = r; return { root: this.root, isRepo: this.repo.isRepo, branch: this.repo.branch }; },
        async gitStatus(r) {
          this.calls.gitStatus++; this.args.gitStatusRoot = r;
          return { root: this.root, isRepo: this.repo.isRepo, branch: this.repo.branch, added: this.counts.added, removed: this.counts.removed, truncated: over.truncated === true,
            files: this.changes.map((f) => ({ path: f.path, added: f.added, removed: f.removed, untracked: !!f.untracked })) };
        },
        async gitCommit(request) {
          this.calls.gitCommit++; this.args.commit = request;
          if (this.commitError) throw new Error(this.commitError);
          return { root: this.root, hash: '0123456789abcdef0123456789abcdef01234567', files: request.files };
        },
        async remoteStatus() { this.calls.remoteStatus++; return { ...this.remote }; },
        async listArtifacts(o) { this.calls.listArtifacts++; this.args.artifactsOrder = o; return this.artifactsByOrder ? (this.artifactsByOrder[o] || []) : this.artifacts; },
        ...(over.sessions ? { async listSessions(mode) { this.calls.listSessions++; this.args.sessionsMode = mode; return this.sessions; } } : {}),
        ...(over.usage ? { async usageSummary(o) { this.calls.usageSummary++; return this.usage[o] || { last_prompt: 0 }; } } : {}),
        ...(over.providers ? { async listProviders() { this.calls.listProviders++; return this.providers; } } : {}),
        async cancelOrder(o) { this.calls.cancelOrder++; this.args.cancelOrder = o; return { cancelled: true }; },
      });
      window.rcCore = window.rcStub();
      window.rc = new window.RightCardsPanel(rcHost, window.rcCore, window.rcActions);
      window.P = {};
      window.mk = (id, over = {}, opts, parent) => { const host = document.createElement('div'); host.id = id; (parent || document.body).appendChild(host); const core = window.rcStub(over); const panel = new window.RightCardsPanel(host, core, window.rcActions, opts); window.P[id] = { core, panel, host }; return true; };
      return true;
    })()`);
    await evaluate('new Promise(r=>setTimeout(r,150))');


    await sec('r3 filtro Windows: mayusculas, separadores y segmentos de traversal', async () => {
      const cases = [
        ['DevAgents-Workspace/x', true], ['DEVAGENTS-WORKSPACE\\x', true],
        ['devagents-workspace', true], ['devagents-workspace/a/b', true],
        ['devagents-workspace/../x', false], ['devagents-workspace/./x', false],
        ['devagents-workspace/a/../../x', false], ['./devagents-workspace/x', false],
        ['devagents-workspace-old/x', false], ['a/devagents-workspace/x', false],
        ['/devagents-workspace/x', false], ['devagents-workspace\\..\\x', false],
      ];
      for (const [input, expected] of cases) assert.equal(await q(`window.rcPath(${JSON.stringify(input)})`), expected, input);
    });

    await sec('r3 cinco ventanas flotantes y Actividad fuera de la pila', async () => {
      assert.deepEqual(await q(`[...document.querySelectorAll('#right-cards-host .rc-card')].map(e=>e.dataset.rcSection)`), ['entorno','contexto','resultados','cambios','tareas']);
      assert.equal(await q(`typeof window.rc.activityHost`), 'undefined', 'Actividad ya no pertenece a las ventanas');
    });

    // 3. Fila de herramientas (r4-3): seis botones de 28x28 con iconos de 16 px.
    await sec('v1-r4 fila de herramientas: seis botones de 28x28 con iconos de 16 px', async () => {
      assert.equal(await q(`document.querySelectorAll('.rc-tool').length`), 6, 'seis herramientas del chat');
      assert.deepEqual(await q(`[...document.querySelectorAll('.rc-tool')].map(b=>b.dataset.rcAction)`), ['panel', 'terminal', 'browser', 'explorer', 'activity', 'menu']);
      const tools = await q(`[...document.querySelectorAll('.rc-tool')].map(b=>{const r=b.getBoundingClientRect();const s=b.querySelector('svg');return [r.width,r.height,s.getAttribute('width'),s.getAttribute('height'),b.title||'',b.getAttribute('aria-label')||''];})`);
      for (const [w, h, sw, sh, title, aria] of tools) {
        assert.equal(w, 28, 'boton 28 de ancho'); assert.equal(h, 28, 'boton 28 de alto');
        assert.equal(sw, '16', 'icono 16'); assert.equal(sh, '16', 'icono 16');
        assert(title.length > 0, 'title accesible'); assert(aria.length > 0, 'aria-label accesible');
      }
      for (const action of ['panel', 'terminal', 'browser', 'explorer', 'activity', 'menu']) {
        await clickSelector(`.rc-tool[data-rc-action="${action}"]`);
      }
      assert.deepEqual(await q('window.rcLog'), ['panel', 'terminal', 'browser', 'explorer', 'activity', 'menu'], 'cada icono alterna su vista existente');
    });

    await sec('v1 adaptado: Entorno, Resultados, Contexto, Cambios, Confirmar, Tareas, plegado, estilos, scroll', async () => {
      // 4. Entorno (r2): filas con icono — equipo, carpeta con su nombre y el padre
      //    atenuado EN UNA LINEA, rama y Control remoto. Sin «Ruta» duplicada.
      const env = await q(`(() => {
        const row = k => document.querySelector('#right-cards-host [data-rc-env="' + k + '"]');
        const parent = row('project').querySelector('.rc-env__parent');
        return {
          computer: row('computer')?.textContent.trim(),
          computerIcon: !!row('computer')?.querySelector('svg'),
          project: row('project')?.querySelector('.rc-env__name')?.textContent,
          projectIcon: !!row('project')?.querySelector('svg'),
          parent: parent?.textContent,
          parentColor: getComputedStyle(parent).color,
          parentOverflow: getComputedStyle(parent).textOverflow,
          parentWrap: getComputedStyle(parent).whiteSpace,
          parentTitle: parent?.title,
          projectRowH: row('project').getBoundingClientRect().height,
          rutaLabels: [...document.querySelectorAll('#right-cards-host .rc-env__row')].filter(r => r.textContent.includes('Ruta')).length,
          branch: row('branch')?.textContent || '',
          fork: !!row('branch')?.querySelector('svg'),
          remoteIcon: !!row('remote')?.querySelector('svg'),
          state: document.querySelector('#right-cards-host .rc-remote__state')?.textContent,
          hasSwitch: !!document.querySelector('#right-cards-host .rc-switch'),
        };
      })()`);
      assert.equal(env.computer, 'Esta computadora', 'fila del equipo');
      assert(env.computerIcon && env.projectIcon && env.fork && env.remoteIcon, 'cada fila de Entorno lleva su icono');
      assert.equal(env.project, 'calculadora', 'ultimo segmento de la raiz');
      assert.equal(env.parent, 'C:\\proyectos\\', 'carpeta padre atenuada');
      assert.equal(env.parentTitle, 'C:\\proyectos\\calculadora', 'la ruta completa va en el title');
      assert.equal(env.parentColor, 'rgb(154, 149, 142)', 'padre en gris #9A958E');
      assert.equal(env.parentOverflow, 'ellipsis', 'padre con elipsis');
      assert.equal(env.parentWrap, 'nowrap', 'padre en una sola linea');
      assert(env.projectRowH < 40, 'proyecto y padre caben en UNA linea');
      assert.equal(env.rutaLabels, 0, 'se acabo la «Ruta» duplicada');
      assert(env.branch.includes('main'), 'rama simulada por el puente');
      assert.equal(env.state, 'Desactivado', 'interruptor neutral apagado');
      assert.equal(env.hasSwitch, false);
      assert.equal(await q('window.rcCore.args.gitBranchRoot'), 'C:\\proyectos\\calculadora', 'la rama se consulta en la raiz autorizada');

      // 5. Enlace de Control remoto: abre Ajustes -> Acceso remoto sin fingir conmutación.
      await clickSelector('[data-rc-configure-remote]');
      assert.deepEqual(await q(`window.rcEvents.filter(e=>e[0]==='devagents:settings-section')`), [['devagents:settings-section', 'remote']], 'abre la seccion existente sin inventar puerto ni tokens');
      assert.equal(await q(`document.querySelector('.rc-remote__state').textContent`), 'Desactivado', 'el enlace no cambia el estado real');
      assert.equal(await q(`document.querySelector('.rc-switch')`), null, 'no se presenta un interruptor sin acción');

      // 6. Resultados: sin archivos, y luego 7 unicos (5 + Mostrar mas) sin duplicar.
      assert.match(await q(`document.querySelector('[data-rc-section="resultados"] .rc-empty')?.textContent || ''`), /Aún no hay archivos/);
      await evaluate('window.rcOrderId = 5');
      await evaluate(`(() => {
        window.rc.appendEvents([
          {id:1,ts:1,source:'x',kind:'file_written',payload:{file_path:'C:/p/a.html'}},
          {id:2,ts:2,source:'x',kind:'file_written',payload:{path:'C:/p/b.js'}},
          {id:3,ts:3,source:'x',kind:'file_written',payload:{artifact_name:'c.json'}},
          {id:4,ts:4,source:'x',kind:'tool_call',payload:{file_path:'C:/p/ignorado.js'}},
        ]);
        window.rc.appendEvents([
          {id:5,ts:5,source:'x',kind:'file_written',payload:{file_path:'C:/p/a.html'}},
          {id:6,ts:6,source:'x',kind:'file_written',payload:{file_path:'C:/p/d.ts'}},
          {id:7,ts:7,source:'x',kind:'file_written',payload:{file_path:'C:/p/e.css'}},
          {id:8,ts:8,source:'x',kind:'file_written',payload:{file_path:'C:/p/f.md'}},
          {id:9,ts:9,source:'x',kind:'file_written',payload:{file_path:'C:/p/g.zig'}},
        ]);
        return true;
      })()`);
      assert.equal(await q(`document.querySelectorAll('.rc-file').length`), 5, 'siete unicos: se ven cinco');
      assert.equal(await q(`document.querySelector('.rc-more')?.textContent`), 'Mostrar más (2)', 'Mostrar más con los restantes');
      await clickSelector('.rc-more');
      assert.equal(await q(`document.querySelectorAll('.rc-file').length`), 7, 'Mostrar más expande sin duplicar');
      assert.equal(await q(`document.querySelector('.rc-more')`), null, 'sin boton cuando ya no quedan');
      await clickSelector('[data-rc-file="C:/p/e.css"]');
      assert.deepEqual(await q(`window.rcEvents.filter(e=>e[0]==='devagents:open-file')`), [['devagents:open-file', 'C:/p/e.css']], 'la fila abre con la accion existente');

      // 6.4 Contexto (E3): sin datos «—» (nunca 0 % inventado); con el evento
      //     simulado al 75 % pinta el porcentaje y la barra en ámbar #C89246.
      assert.equal(await q(`document.querySelector('#right-cards-host [data-rc-section="contexto"] .rc-context__pct').textContent`), '—', 'sin datos no se inventa 0 %');
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__fill').style.width`), '0%', 'sin datos la barra no finge llenado');
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__label').textContent`), 'Sin datos');
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:98304,tokens:24576,pct:75,turns:4}}))`);
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__pct').textContent`), '75 %', 'el evento publica el uso del hilo');
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__fill').style.width`), '75%', 'la barra refleja el porcentaje');
      assert.equal(await q(`getComputedStyle(document.querySelector('#right-cards-host .rc-context__fill')).backgroundColor`), 'rgb(200, 146, 70)', 'desde 70 % en el tono de aviso del tema');
      assert.equal(await q(`document.querySelector('#right-cards-host [data-rc-context]').dataset.rcContextSource`), 'estimated', 'sin uso medido es una estimacion');
      assert.match(await q(`document.querySelector('#right-cards-host .rc-context__label').title`), /no ha reportado uso.*caracteres/, 'el motivo de la estimacion va en el title');
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__label').textContent`), 'Estimado');
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__track').getAttribute('aria-valuenow')`), '75');
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:0,tokens:0,pct:null,turns:0}}))`);
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-context__pct').textContent`), '—', 'sin hilo vuelve a «—»');

      // 6.4b r2: el hilo ya esta abierto y su uso se publico ANTES de que la
      //      tarjeta existiera (main.ts crea MissionControlPanel antes). Al
      //      montar, la tarjeta pide el estado vigente y lo muestra igualmente.
      await evaluate(`(() => {
        const host=document.createElement('div');host.id='rc-host-context-mount';document.body.appendChild(host);
        window.rcContextPublished={chars:65536,tokens:16384,pct:50,turns:2};
        window.rcContextRequests=0;
        window.rcContextResponder=()=>{window.rcContextRequests++;document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:window.rcContextPublished}));};
        document.addEventListener('devagents:thread-usage-request',window.rcContextResponder);
        document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:window.rcContextPublished}));
        window.rcContextCore=window.rcStub();
        window.rcContextMount=new window.RightCardsPanel(host,window.rcContextCore,window.rcActions);
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,80))');
      assert.equal(await q(`document.querySelector('#rc-host-context-mount .rc-context__pct').textContent`), '50 %', 'el uso publicado antes del montaje se ve al montar');
      assert.equal(await q(`document.querySelector('#rc-host-context-mount .rc-context__fill').style.width`), '50%', 'la barra usa el estado recuperado');
      assert.equal(await q(`document.querySelector('#rc-host-context-mount .rc-context__label').textContent`), 'Estimado');
      assert.equal(await q(`window.rcContextRequests >= 1`), true, 'la tarjeta pide el uso actual al montar');
      await evaluate(`(() => {document.removeEventListener('devagents:thread-usage-request',window.rcContextResponder);window.rcContextMount.destroy();return true;})()`);

      // 6.5 Cambios (E4): cinco tarjetas en orden, +12 verde / −3 rojo en 24 px,
      //     7 archivos -> 5 + Mostrar más, nombres escapados y apertura real.
      assert.equal(await q(`document.querySelectorAll('#right-cards-host .rc-card').length`), 5, 'cinco ventanas: Entorno, Contexto, Resultados, Cambios y Tareas');
      assert.deepEqual(await q(`[...document.querySelectorAll('#right-cards-host .rc-card__title')].map(t=>t.textContent)`), ['Entorno', 'Contexto', 'Resultados', 'Cambios', 'Tareas en segundo plano']);
      assert.equal(await q(`document.querySelector('#right-cards-host .rc-confirm').disabled`), true, 'sin cambios el boton esta desactivado');
      assert.match(await q(`document.querySelector('#right-cards-host .rc-confirm').title`), /No hay cambios/, 'desactivado con motivo');
      await evaluate(`(() => {
        const host=document.createElement('div');host.id='rc-host-changes';document.body.appendChild(host);
        const files=[
          {path:'src/<b>peligro</b>.ts',added:4,removed:1,untracked:false},
          {path:'src/app.ts',added:2,removed:1,untracked:false},
          {path:'src/b.ts',added:2,removed:1,untracked:false},
          {path:'src/c.ts',added:2,removed:0,untracked:false},
          {path:'src/d.ts',added:1,removed:0,untracked:false},
          {path:'docs/e.md',added:1,removed:0,untracked:false},
          {path:'nuevo.txt',added:0,removed:0,untracked:true},
        ];
        window.rcChangesFiles=files.map(f=>f.path);
        const core=window.rcStub({changes:files, counts:{added:12,removed:3}});
        window.rcChangesCore=core;
        window.rcChanges=new window.RightCardsPanel(host, core, window.rcActions);
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q(`window.rcChangesCore.calls.gitStatus >= 1`), true, 'Cambios consulta core.git.status al montar');
      assert.equal(await q(`window.rcChangesCore.args.gitStatusRoot`), 'C:\\proyectos\\calculadora', 'consulta la raiz autorizada');
      const counts = await q(`(() => {const host=document.getElementById('rc-host-changes');const add=host.querySelector('.rc-changes__add');const del=host.querySelector('.rc-changes__del');return {add:add.textContent, del:del.textContent, addColor:getComputedStyle(add).color, delColor:getComputedStyle(del).color, size:getComputedStyle(host.querySelector('.rc-changes__counts')).fontSize};})()`);
      assert.equal(counts.add, '+12');
      assert.equal(counts.del, '−3');
      assert.equal(counts.addColor, 'rgb(121, 153, 106)', '+N en #79996A');
      assert.equal(counts.delColor, 'rgb(196, 85, 61)', '−M en #C4553D');
      assert.equal(counts.size, '12px', 'r4-3: contadores en 12 px');
      assert.equal(await q(`!!document.querySelector('#rc-host-changes .rc-changes__head .rc-confirm')`), true, '«Confirmar cambios» va en la cabecera junto a +A −R');
      assert.equal(await q(`document.querySelectorAll('#rc-host-changes .rc-change').length`), 5, 'siete archivos: se ven cinco');
      // (tanda 1): la fila dice en qué carpeta está el archivo.
      assert.equal(await q(`document.querySelector('#rc-host-changes [data-rc-change="src/app.ts"] .rc-change__name').textContent`), 'src/app.ts', 'Cambios muestra la ruta relativa, no solo el nombre');
      assert.equal(await q(`document.querySelector('#rc-host-changes [data-rc-change="src/app.ts"] .rc-change__name .subtle').textContent`), 'src/', 'la carpeta va atenuada delante del nombre');
      assert.equal(await q(`!!document.querySelector('#rc-host-changes .rc-change__name b')`), false, 'la carpeta se escapa como el nombre');
      assert.equal(await q(`document.querySelector('#rc-host-changes .rc-changes__more')?.textContent`), 'Mostrar más (2)');
      assert.equal(await q(`document.getElementById('rc-host-changes').innerHTML.includes('<b>')`), false, 'nombres de archivo escapados en el DOM');
      assert.equal(await q(`document.getElementById('rc-host-changes').innerHTML.includes('&lt;b&gt;')`), true);
      await clickSelector('#rc-host-changes .rc-changes__more');
      assert.equal(await q(`document.querySelectorAll('#rc-host-changes .rc-change').length`), 7, 'Mostrar más expande sin duplicar');
      assert.equal(await q(`document.querySelector('#rc-host-changes .rc-changes__more')`), null, 'sin boton cuando ya no quedan');
      assert.equal(await q(`document.querySelector('#rc-host-changes .rc-change[data-rc-change="nuevo.txt"] .rc-change__new')?.textContent`), 'nuevo', 'sin seguimiento rotulado');
      assert.equal(await q(`document.querySelector('#rc-host-changes .rc-confirm').disabled`), false, 'con cambios el boton se activa');
      await clickSelector('#rc-host-changes .rc-change[data-rc-change="nuevo.txt"]');
      assert.deepEqual(await q(`window.rcEvents.filter(e=>e[0]==='devagents:open-file').slice(-1)`), [['devagents:open-file', 'C:\\proyectos\\calculadora\\nuevo.txt']], 'la ruta relativa abre absoluta en la raiz');

      // 6.6 Confirmar cambios (E5): cancelar no llama al puente; confirmar sin
      //     mensaje lo exige sin llamar; con mensaje llama a core.git.commit con
      //     TODOS los archivos y el mensaje, cierra el modal y refresca.
      await clickSelector('#rc-host-changes .rc-confirm');
      assert.equal(await q(`!!document.querySelector('#rc-host-changes dialog[open]')`), true, 'el modal se abre');
      assert.equal(await q(`document.querySelectorAll('#rc-host-changes .rc-modal__file').length`), 7, 'el modal lista todos los archivos');
      await clickSelector('#rc-host-changes [data-rc-cancel]');
      assert.equal(await q(`window.rcChangesCore.calls.gitCommit`), 0, 'cancelar no ejecuta git');
      assert.equal(await q(`document.querySelector('#rc-host-changes dialog')`), null, 'cancelar cierra el modal');
      await clickSelector('#rc-host-changes .rc-confirm');
      await clickSelector('#rc-host-changes [data-rc-modal-confirm]');
      assert.equal(await q(`window.rcChangesCore.calls.gitCommit`), 0, 'sin mensaje no se ejecuta git');
      assert.equal(await q(`document.querySelector('#rc-host-changes .rc-modal__error').hidden`), false, 'el error de validacion se ve en el modal');
      assert.match(await q(`document.querySelector('#rc-host-changes .rc-modal__error').textContent`), /Escribe el mensaje/);
      await evaluate(`(() => {document.querySelector('#rc-host-changes .rc-modal__message').value='cab025 desde el modal';return true;})()`);
      const statusBeforeCommit = await q(`window.rcChangesCore.calls.gitStatus`);
      await clickSelector('#rc-host-changes [data-rc-modal-confirm]');
      await evaluate('new Promise(r=>setTimeout(r,150))');
      const commit = await q(`window.rcChangesCore.args.commit`);
      assert.equal(commit.message, 'cab025 desde el modal', 'el mensaje es el que escribio el usuario');
      assert.deepEqual(commit.files, await q('window.rcChangesFiles'), 'se confirman exactamente los archivos listados');
      assert.equal(commit.root, 'C:\\proyectos\\calculadora');
      assert.equal(await q(`document.querySelector('#rc-host-changes dialog')`), null, 'el modal se cierra tras el commit');
      assert(await q(`window.rcChangesCore.calls.gitStatus > ${statusBeforeCommit}`), 'el estado se refresca tras el commit');

      // 6.7 El error de git queda visible en el modal, sin cerrarlo, y el
      //     refresco manual y order_done vuelven a consultar el estado.
      await evaluate(`(() => {
        const host=document.createElement('div');host.id='rc-host-fail';document.body.appendChild(host);
        const core=window.rcStub({changes:[{path:'solo.txt',added:1,removed:0}], counts:{added:1,removed:0}, commitError:'E_NATIVE_CONSENT_REQUIRED: falta la autorizacion del host'});
        window.rcFailCore=core;
        window.rcFail=new window.RightCardsPanel(host, core, window.rcActions);
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,150))');
      await clickSelector('#rc-host-fail .rc-confirm');
      await evaluate(`(() => {document.querySelector('#rc-host-fail .rc-modal__message').value='intento fallido';return true;})()`);
      await clickSelector('#rc-host-fail [data-rc-modal-confirm]');
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q(`!!document.querySelector('#rc-host-fail dialog[open]')`), true, 'un fallo de git no cierra el modal');
      assert.match(await q(`document.querySelector('#rc-host-fail .rc-modal__error').textContent`), /falta la autorizacion del host/);
      await clickSelector('#rc-host-fail [data-rc-cancel]');
      const statusBeforeRefresh = await q(`window.rcChangesCore.calls.gitStatus`);
      await clickSelector('#rc-host-changes [data-rc-refresh]');
      assert(await q(`window.rcChangesCore.calls.gitStatus > ${statusBeforeRefresh}`), 'el boton de refrescar consulta el estado');
      await evaluate(`window.rcChanges.appendEvents([{id:30,ts:30,source:'x',kind:'order_done',payload:{}}])`);
      await evaluate('new Promise(r=>setTimeout(r,80))');
      assert(await q(`window.rcChangesCore.calls.gitStatus > ${statusBeforeRefresh} + 1`), 'order_done refresca Cambios');

      // 6.8 Tareas en segundo plano (E6 v1): una terminal viva con parar,
      //     dos task_* en curso con tiempo que avanza, tres finalizadas y
      //     cancelación con confirmación (sin confirmar no se llama al puente).
      await evaluate(`(() => {
        const host=document.createElement('div');host.id='rc-host-tasks';document.body.appendChild(host);
        const core=window.rcStub();
        window.rcTasksCore=core;
        window.rcOrderId=9;
        window.rcTerminalStops=0;
        document.addEventListener('devagents:terminal-stop',()=>{window.rcTerminalStops++;});
        window.rcTasks=new window.RightCardsPanel(host, core, window.rcActions);
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q(`document.querySelector('#rc-host-tasks .rc-task')`), null, 'sin procesos vivos no hay filas');
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:terminal-state',{detail:{running:true,terminalId:5,startedAt:Date.now()-42000}}))`);
      assert.equal(await q(`document.querySelectorAll('#rc-host-tasks .rc-task--terminal').length`), 1, 'fila de la terminal propia viva');
      const terminalSeconds = await q(`(() => {const [m,s]=document.querySelector('#rc-host-tasks .rc-task--terminal .rc-task__time').textContent.split(':').map(Number);return m*60+s;})()`);
      assert(terminalSeconds >= 42 && terminalSeconds < 60, 'tiempo transcurrido de la terminal desde startedAt');
      const tasksNow = await q('Date.now()');
      await evaluate(`window.rcTasks.appendEvents([
        {id:100,ts:${tasksNow - 65000},source:'x',kind:'task_started',payload:{task_id:'t1',description:'Pruebas de calculadora'}},
        {id:101,ts:${tasksNow - 125000},source:'x',kind:'task_started',payload:{task_id:'t2',description:'Servidor de desarrollo'}},
        {id:102,ts:${tasksNow - 200000},source:'x',kind:'task_started',payload:{task_id:'t3',description:'Compilar'}},
        {id:103,ts:${tasksNow - 190000},source:'x',kind:'task_done',payload:{task_id:'t3'}},
        {id:104,ts:${tasksNow - 180000},source:'x',kind:'task_started',payload:{task_id:'t4',description:'Probar'}},
        {id:105,ts:${tasksNow - 170000},source:'x',kind:'task_done',payload:{task_id:'t4'}},
        {id:106,ts:${tasksNow - 160000},source:'x',kind:'task_started',payload:{task_id:'t5',description:'Auditar'}},
        {id:107,ts:${tasksNow - 150000},source:'x',kind:'task_done',payload:{task_id:'t5'}},
      ])`);
      assert.equal(await q(`document.querySelectorAll('#rc-host-tasks .rc-task[data-rc-task]').length`), 2, 'dos tareas task_* en curso');
      assert.deepEqual(await q(`[...document.querySelectorAll('#rc-host-tasks .rc-task[data-rc-task] .rc-task__name')].map(n=>n.textContent)`), ['Pruebas de calculadora', 'Servidor de desarrollo']);
      const t1Seconds = await q(`(() => {const [m,s]=document.querySelector('#rc-host-tasks .rc-task[data-rc-task="t1"] .rc-task__time').textContent.split(':').map(Number);return m*60+s;})()`);
      assert(t1Seconds >= 65 && t1Seconds < 120, 'tiempo desde el ts del evento');
      assert.equal(await q(`document.querySelector('#rc-host-tasks .rc-tasks__finished').textContent.includes('3 finalizados')`), true, 'contador de finalizadas de la sesión');
      assert.notEqual(await q('window.rcTasks.tasksTick'), null, 'con tareas vivas queda programado el reloj');
      const beforeTick = await q(`document.querySelector('#rc-host-tasks .rc-task[data-rc-task="t1"] .rc-task__time').textContent`);
      await evaluate('new Promise(r=>setTimeout(r,1150))');
      await evaluate('window.rcTasks.tickTasks()');
      const afterTick = await q(`document.querySelector('#rc-host-tasks .rc-task[data-rc-task="t1"] .rc-task__time').textContent`);
      assert.notEqual(afterTick, beforeTick, 'el tiempo transcurrido se repinta cada segundo');
      await clickSelector('#rc-host-tasks [data-rc-finished-toggle]');
      assert.equal(await q(`document.querySelectorAll('#rc-host-tasks .rc-task--done').length`), 3, 'el contador despliega las terminadas');
      assert.equal(await q(`[...document.querySelectorAll('#rc-host-tasks .rc-task--done .rc-task__status')].every(s=>s.textContent==='Completada')`), true);
      await clickSelector('#rc-host-tasks [data-rc-kill-terminal]');
      assert.equal(await q('window.rcTerminalStops'), 1, 'cerrar la terminal pide pty.kill al componente real');
      assert.equal(await q(`document.querySelector('#rc-host-tasks .rc-task--terminal')`), null, 'la fila de la terminal desaparece');
      await clickSelector('#rc-host-tasks [data-rc-cancel-task="t1"]');
      assert.equal(await q(`!!document.querySelector('#rc-host-tasks dialog[data-rc-task-modal][open]')`), true, 'cancelar abre confirmación');
      assert.equal(await q('window.rcTasksCore.calls.cancelOrder'), 0, 'sin confirmar no llama al puente');
      await clickSelector('#rc-host-tasks [data-rc-task-abort]');
      assert.equal(await q('window.rcTasksCore.calls.cancelOrder'), 0, 'volver tampoco llama al puente');
      assert.equal(await q(`document.querySelector('#rc-host-tasks dialog')`), null, 'volver cierra el diálogo');
      await clickSelector('#rc-host-tasks [data-rc-cancel-task="t1"]');
      await clickSelector('#rc-host-tasks [data-rc-task-confirm]');
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q('window.rcTasksCore.calls.cancelOrder'), 1, 'confirmar llama a core.order.cancel');
      assert.equal(await q('window.rcTasksCore.args.cancelOrder'), 9, 'cancela la orden activa');
      assert.equal(await q(`document.querySelectorAll('#rc-host-tasks .rc-task[data-rc-task]').length`), 0, 'las tareas pasan a finalizadas');
      assert.equal(await q(`document.querySelector('#rc-host-tasks .rc-tasks__finished').textContent.includes('5 finalizados')`), true, 'las canceladas también cuentan');
      assert.equal(await q('window.rcTasks.tasksTick'), null, 'sin procesos vivos no queda intervalo');
      await evaluate(`window.rcTasks.appendEvents([{id:110,ts:Date.now(),source:'x',kind:'task_started',payload:{task_id:'t9',description:'Larga'}}])`);
      assert.notEqual(await q('window.rcTasks.tasksTick'), null, 'con una tarea viva late el reloj');
      await evaluate('window.rcTasks.destroy()');
      assert.equal(await q('window.rcTasks.tasksTick'), null, 'destroy limpia el intervalo');
      await evaluate('window.rcOrderId=0');

      // 7. Plegado por tarjeta: clic, Enter, espacio y persistencia por usuario.
      await clickSelector('[data-rc-section="entorno"] .rc-card__head');
      assert.equal(await q(`document.querySelector('[data-rc-section="entorno"] .rc-card__body').hidden`), true);
      assert.equal(await q(`document.querySelector('[data-rc-section="entorno"] .rc-card__head').getAttribute('aria-expanded')`), 'false');
      assert.equal(await q(`localStorage.getItem('devagents.panel.right.cards')`), JSON.stringify({ entorno: true, contexto: false, resultados: false, cambios: false, tareas: false }), 'plegado persistido en su clave');
      assert.equal(await q(`localStorage.getItem('devagents.panel.right')`), null, 'no toca la clave del plegado de la columna');
      await evaluate(`(() => {const host=document.createElement('div');host.id='rc-host-2';document.body.appendChild(host);window.rc2=new window.RightCardsPanel(host, window.rcCore, window.rcActions);return true;})()`);
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q(`document.querySelector('#rc-host-2 [data-rc-section="entorno"] .rc-card__body').hidden`), true, 'releer la clave restaura el plegado');
      await keyOn('[data-rc-section="resultados"] .rc-card__head', 'Enter', 'Enter', 13, '\r');
      assert.equal(await q(`document.querySelector('[data-rc-section="resultados"] .rc-card__body').hidden`), true, 'Enter pliega');
      await keyOn('[data-rc-section="resultados"] .rc-card__head', ' ', 'Space', 32);
      assert.equal(await q(`document.querySelector('[data-rc-section="resultados"] .rc-card__body').hidden`), false, 'espacio despliega');

      // 8. Sin repositorio -> «sin git»; remoto encendido; recuperacion de artefactos;
      //    y el nombre del proyecto se escapa.
      await evaluate(`(() => {
        const host=document.createElement('div');host.id='rc-host-3';document.body.appendChild(host);
        const core=window.rcStub({root:'/home/<b>demo', repo:{isRepo:false}, remote:{running:true,url:'http://127.0.0.1:9',pid:2}, artifacts:[{file_path:'C:/p/recuperado.html'}], orderId:7});
        window.rcOrderId=7;
        window.rc3core=core;
        window.rc3=new window.RightCardsPanel(host, core, window.rcActions);
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,150))');
      assert.equal(await q(`document.querySelector('#rc-host-3 .rc-env__name').textContent`), '<b>demo');
      assert.equal(await q(`[...document.querySelectorAll('#rc-host-3 .rc-env__row')].some(r=>r.textContent.includes('sin git'))`), true, 'sin git cuando la raiz no es repositorio');
      assert.equal(await q(`document.querySelector('#rc-host-3 [data-rc-configure-remote]').textContent.trim()`), 'Configurar control remoto', 'enlace honesto con estado leído de remoteStatus');
      assert.equal(await q(`document.querySelector('#rc-host-3 .rc-remote__state').textContent`), 'Activado');
      assert.equal(await q(`document.querySelector('#rc-host-3 .rc-confirm').disabled`), true, 'sin repositorio no se puede confirmar');
      assert.match(await q(`document.querySelector('#rc-host-3 .rc-confirm').title`), /no es un repositorio/, 'desactivado con el motivo exacto');
      assert.equal(await q(`document.getElementById('rc-host-3').innerHTML.includes('<b>')`), false, 'texto externo escapado');
      assert.equal(await q(`document.getElementById('rc-host-3').innerHTML.includes('&lt;b&gt;')`), true);
      assert.equal(await q('window.rc3core.args.artifactsOrder'), 7, 'artefactos de la orden activa');
      assert.equal(await q(`document.querySelector('#rc-host-3 .rc-file[data-rc-file="C:/p/recuperado.html"]') ? true : false`), true, 'da_list_artifacts_json recupera lo ya escrito');

      // 9. Estilos de la especificacion: #131312, borde 1 px rgba(250,247,244,0.07),
      //    radio 6 px, relleno 20 px, separacion 12 px, titulo 19 px seminegrita.
      const style = await q(`(() => {
        const card = document.querySelector('#right-cards-host .rc-card');
        const cs = getComputedStyle(card);
        const body = document.querySelector('#right-cards-host [data-rc-section="resultados"] .rc-card__body');
        const title = document.querySelector('#right-cards-host .rc-card__title');
        const cards = document.querySelector('#right-cards-host .rc-cards');
        return { bg: cs.backgroundColor, border: cs.borderTopColor, borderWidth: cs.borderTopWidth, radius: cs.borderRadius,
          pad: getComputedStyle(body).paddingLeft, gap: getComputedStyle(cards).rowGap,
          titleSize: getComputedStyle(title).fontSize, titleWeight: getComputedStyle(title).fontWeight,
          overflow: getComputedStyle(cards).overflowY };
      })()`);
      assert.equal(style.bg, 'rgb(10, 10, 10)', 'ventana con el fondo de la app');
      assert.equal(style.border, 'rgba(250, 247, 244, 0.07)', 'borde de la referencia');
      assert.equal(style.borderWidth, '1px');
      assert.equal(style.radius, '8px', 'radio 8 px');
      assert.equal(style.pad, '10px', 'r4-3: relleno compacto del cuerpo');
      assert.equal(style.gap, '8px', 'separacion de 8 px entre ventanas');
      assert.equal(style.titleSize, '13px', 'r4-3: cabecera 13 px (referencia del dueno)');
      assert.equal(style.titleWeight, '600', 'seminegrita');
      assert.equal(style.overflow, 'auto', 'la columna se desplaza si no cabe');

      // 10. Columna corta: las tarjetas se desplazan de verdad, sin perder el chat.
      await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 300, deviceScaleFactor: 1, mobile: false });
      await settle();
      const scroll = await q(`(() => {const cards=document.querySelector('#right-cards-host .rc-cards');return {sh:cards.scrollHeight, ch:cards.clientHeight};})()`);
      assert(scroll.sh > scroll.ch, 'con la columna corta las tarjetas hacen scroll');
      await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });
      await settle();

      // 11. El chat reescribe SU host y las tarjetas sobreviven (por eso son dos).
      await evaluate(`(() => {const h=document.createElement('div');h.id='chat-host';h.className='chat-host';document.body.appendChild(h);h.innerHTML='<div id="chat-content">Actividad</div>';return true;})()`);
      assert.equal(await q(`document.querySelectorAll('#right-cards-host .rc-card').length`), 5, 'el render del chat no borra las ventanas');
      assert.equal(await q(`!!document.querySelector('#right-cards-host #chat-content')`), false, 'Actividad fuera de las ventanas');
      assert.equal(await q(`!!document.getElementById('chat-content')`), true);

    });

    // ======================================================================
    // r2
    // ======================================================================
    const sleep = ms => evaluate(`new Promise(r=>setTimeout(r,${ms}))`);
    await evaluate(`localStorage.removeItem('devagents.panel.right.cards')`);

    await sec('12. CK-CAB-025 r2 disposicion: pila vertical de ventanas con 8 px entre', async () => {
      // 12. r2 disposicion: pila vertical de ventanas con 8 px entre
      //     ellas; nada acoplado; la columna se desplaza entera.
      const stack = await q(`(() => {
        const cards = [...document.querySelectorAll('#right-cards-host .rc-cards > .rc-card')];
        const rects = cards.map(c => c.getBoundingClientRect());
        const gaps = rects.slice(1).map((r, i) => Math.round(r.top - rects[i].bottom));
        return { ids: cards.map(c => c.dataset.rcSection), gaps, inColumn: cards.every(c => c.parentElement.classList.contains('rc-cards')),
          dockedBottom: !!document.querySelector('#right-cards-host #panel-bottom, #panel-secondary #panel-bottom'),
          sameX: new Set(rects.map(r => Math.round(r.left))).size };
      })()`);
      assert.deepEqual(stack.ids, ['entorno', 'contexto', 'resultados', 'cambios', 'tareas'], 'CK-CAB-025 r2: cinco ventanas en orden');
      assert(stack.gaps.every(g => g === 8), 'CK-CAB-025 r2: 8 px entre ventanas, medidos: ' + stack.gaps);
      assert.equal(stack.sameX, 1, 'CK-CAB-025 r2: pila vertical (todas alineadas)');
      assert.equal(stack.dockedBottom, false, 'CK-CAB-025 r2: nada acoplado debajo');
    });

    await sec('13. CK-CAB-025 r2 resumen plegado de cada ventana (a la derecha de la cabecera).', async () => {
      // 13. r2 resumen plegado de cada ventana (a la derecha de la cabecera).
      await evaluate(`window.rcOrderId = 31`);
      await evaluate(`window.mk('s1', {root:'C:\\\\proyectos\\\\calculadora', changes:[{path:'a.ts',added:12,removed:3}], counts:{added:12,removed:3}})`);
      await sleep(200);
      await evaluate(`window.P.s1.panel.appendEvents([
        {id:1,ts:Date.now(),source:'x',kind:'file_written',payload:{file_path:'C:/p/a.html'}},
        {id:2,ts:Date.now(),source:'x',kind:'file_written',payload:{file_path:'C:/p/b.js'}},
        {id:3,ts:Date.now(),source:'x',kind:'file_written',payload:{file_path:'C:/p/c.css'}},
        {id:4,ts:Date.now(),source:'x',kind:'task_started',payload:{task_id:'t1',description:'Uno'}},
        {id:5,ts:Date.now(),source:'x',kind:'task_started',payload:{task_id:'t2',description:'Dos'}},
      ])`);
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:1000,tokens:250,pct:40,turns:2}}))`);
      assert.equal(await q(`getComputedStyle(document.querySelector('#s1 [data-rc-summary="entorno"]')).display`), 'none', 'CK-CAB-025 r2: desplegada no resume');
      for (const card of ['entorno', 'contexto', 'resultados', 'cambios', 'tareas']) {
        await clickSelector(`#s1 [data-rc-fold="${card}"]`);
      }
      const sum = await q(`(() => { const t = k => document.querySelector('#s1 [data-rc-summary="' + k + '"]'); return {
        entorno: t('entorno').textContent, contexto: t('contexto').textContent.trim(), miniW: t('contexto').querySelector('.rc-mini__fill')?.style.width,
        resultados: t('resultados').textContent, cambios: t('cambios').textContent, tareas: t('tareas').textContent,
        display: getComputedStyle(t('resultados')).display, chevron: !!document.querySelector('#s1 [data-rc-fold="entorno"] .rc-card__chevron svg'),
        expanded: document.querySelector('#s1 [data-rc-fold="entorno"]').getAttribute('aria-expanded') }; })()`);
      assert.equal(sum.entorno, 'calculadora', 'CK-CAB-025 r2 resumen Entorno = nombre del proyecto');
      assert.equal(sum.contexto, '40 %', 'CK-CAB-025 r2 resumen Contexto = «N %»');
      assert.equal(sum.miniW, '40%', 'CK-CAB-025 r2 resumen Contexto lleva mini barra');
      assert.equal(sum.resultados, '3', 'CK-CAB-025 r2 resumen Resultados = numero de archivos');
      assert.equal(sum.cambios, '+12−3', 'CK-CAB-025 r2 resumen Cambios = «+A −R»');
      assert.equal(sum.tareas, '2 en curso', 'CK-CAB-025 r2 resumen Tareas = «N en curso»');
      assert.equal(sum.display, 'flex', 'resumen visible al plegar');
      assert.equal(sum.expanded, 'false');
      await evaluate(`window.mk('s2', {changes:[], counts:{added:0,removed:0}})`);
      await sleep(200);
      await clickSelector('#s2 [data-rc-fold="cambios"]');
      await clickSelector('#s2 [data-rc-fold="tareas"]');
      assert.equal(await q(`document.querySelector('#s2 [data-rc-summary="cambios"]').textContent`), '', 'CK-CAB-025 r2 Cambios limpio no resume nada');
      assert.equal(await q(`document.querySelector('#s2 [data-rc-summary="tareas"]').textContent`), '', 'CK-CAB-025 r2 sin tareas no resume nada');
      await evaluate(`localStorage.removeItem('devagents.panel.right.cards')`);
    });

    await sec('14. CK-CAB-025 r2 Contexto REAL: prompt_tokens de la ultima llamada / ventana del modelo.', async () => {
      // 14. r2 Contexto REAL: prompt_tokens de la ultima llamada / ventana del modelo.
      await evaluate(`window.rcOrderId = 7`);
      await evaluate(`window.mk('c1', {sessions:[{id:7,conversation_id:'conv-A',status_text:'done',title:'t',created_at:1}],
        usage:{7:{last_prompt:121200,last_provider:'Gemini',last_model:'gemini-2.5-pro'}},
        providers:[{name:'Gemini',models:[{name:'gemini-2.5-pro',context_window:1000000}]}]})`);
      await sleep(250);
      const ctx = await q(`(() => { const h = document.querySelector('#c1 .rc-context__head'); return { text: h.textContent.replace(/\\s+/g,' ').trim(),
        w: document.querySelector('#c1 .rc-context__fill').style.width, src: document.querySelector('#c1 [data-rc-context]').dataset.rcContextSource,
        free: document.querySelector('#c1 .rc-context__rows')?.textContent || '', summary: document.querySelector('#c1 [data-rc-summary="contexto"]').textContent.trim() }; })()`);
      assert.equal(ctx.text, '12 % usado · 121,2k / 1M', 'CK-CAB-025 r2 contexto real: 12 % usado · 121,2k / 1M');
      assert.equal(ctx.w, '12%', 'CK-CAB-025 r2 la barra refleja el % real');
      assert.equal(ctx.src, 'measured');
      assert(ctx.free.includes('Libre') && ctx.free.includes('878,8k'), 'CK-CAB-025 r2 desglose: solo lo medido (ultima llamada y libre): ' + ctx.free);
      assert(!/System tools|MCP|Skills/i.test(ctx.free), 'CK-CAB-025 r2 no se inventan categorias');
      assert.equal(ctx.summary, '12 %', 'el resumen plegado usa el mismo porcentaje');
      assert.equal(await q(`window.P.c1.core.calls.usageSummary >= 1`), true, 'consulta core.usage');
      // El evento external_agent_finished trae prompt_tokens + modelo: % con la ventana del catalogo.
      await evaluate(`window.rcOrderId = 8`);
      await evaluate(`window.mk('c4', {providers:[{name:'Gemini',models:[{name:'gemini-2.5-pro',context_window:1000000}]}]})`);
      await sleep(150);
      await evaluate(`window.P.c4.panel.appendEvents([{id:1,ts:Date.now(),source:'x',kind:'external_agent_finished',payload:{prompt_tokens:50000,completion_tokens:10,provider:'Gemini',model:'gemini-2.5-pro'}}])`);
      await sleep(150);
      assert.equal(await q(`document.querySelector('#c4 .rc-context__head').textContent.replace(/\\s+/g,' ').trim()`), '5 % usado · 50k / 1M', 'CK-CAB-025 r2 evento con prompt_tokens + ventana -> %');
      // Modelo sin ventana en el catalogo: se dice, no se inventa un porcentaje.
      await evaluate(`window.rcOrderId = 9`);
      await evaluate(`window.mk('c2', {sessions:[{id:9,conversation_id:'conv-B'}], usage:{9:{last_prompt:3000,last_provider:'X',last_model:'raro'}}, providers:[{name:'X',models:[{name:'otro',context_window:8000}]}]})`);
      await sleep(250);
      assert.match(await q(`document.querySelector('#c2 .rc-context__head').textContent.replace(/\\s+/g,' ').trim()`), /^3k tokens de prompt · ventana desconocida$/, 'CK-CAB-025 r2 sin ventana no hay % inventado');
      assert.equal(await q(`document.querySelector('#c2 .rc-context__fill').style.width`), '0%');
      // Sin uso medido: «estimado», con el motivo en el title.
      await evaluate(`window.mk('c3', {sessions:[{id:9,conversation_id:'conv-B'}], usage:{}})`);
      await sleep(200);
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:8192,tokens:2048,pct:6,turns:3}}))`);
      assert.equal(await q(`document.querySelector('#c3 [data-rc-context]').dataset.rcContextSource`), 'estimated', 'CK-CAB-025 r2 sin medicion: estimado');
      assert.equal(await q(`document.querySelector('#c3 .rc-context__label').textContent`), 'Estimado');
      assert.match(await q(`document.querySelector('#c3 .rc-context__label').title`), /no ha reportado uso/);
    });

    await sec('15. CK-CAB-025 r2 Cambios: devagents-workspace/ nunca aparece.', async () => {
      // 15. r2 Cambios: devagents-workspace/ nunca aparece.
      await evaluate(`(() => {
        window.mk('x1', {changes:[
          {path:'devagents-workspace/.beats/spaces/orden-12/index.html',untracked:true},
          {path:'devagents-workspace\\\\.beats\\\\spaces\\\\orden-13\\\\a.txt',untracked:true},
          {path:'src/real.ts',added:2,removed:1},
          {path:'nuevo.md',untracked:true}], counts:{added:9,removed:4}});
        window.mk('x2', {changes:[{path:'devagents-workspace/.beats/spaces/orden-1/x.txt',untracked:true},{path:'devagents-workspace/y.json',added:5,removed:5}], counts:{added:5,removed:5}});
        return true; })()`);
      await sleep(250);
      const rows = await q(`[...document.querySelectorAll('#x1 .rc-change')].map(r => r.dataset.rcChange)`);
      assert.deepEqual(rows, ['src/real.ts', 'nuevo.md'], 'CK-CAB-025 r2 exclusion de devagents-workspace en Cambios');
      assert.equal(await q(`document.querySelector('#x1 .rc-changes__counts').textContent`), '+2−1', 'CK-CAB-025 r2 los totales no cuentan la carpeta interna');
      assert.equal(await q(`document.getElementById('x1').innerHTML.includes('devagents-workspace')`), false);
      await clickSelector('#x1 .rc-confirm');
      assert.equal(await q(`document.querySelectorAll('#x1 .rc-modal__file').length`), 2, 'el modal solo lista lo del usuario');
      await evaluate(`document.querySelector('#x1 .rc-modal__message').value='solo mio'`);
      await clickSelector('#x1 [data-rc-modal-confirm]');
      await sleep(150);
      assert.deepEqual(await q(`window.P.x1.core.args.commit.files`), ['src/real.ts', 'nuevo.md'], 'CK-CAB-025 r2 el commit no arrastra la carpeta interna');
      assert.match(await q(`document.querySelector('#x2 [data-rc-section="cambios"] .rc-empty').textContent`), /Sin cambios pendientes/, 'CK-CAB-025 r2 solo carpeta interna = arbol limpio');
      assert.equal(await q(`document.querySelector('#x2 .rc-confirm').disabled`), true);
    });

    await sec('16. CK-CAB-025 r2 Resultados por conversacion; «Nueva conversacion» los vacia.', async () => {
      // 16. r2 Resultados por conversacion; «Nueva conversacion» los vacia.
      await evaluate(`window.rcOrderId = 7`);
      await evaluate(`window.mk('r1', {sessions:[{id:7,conversation_id:'cA'},{id:8,conversation_id:'cA'},{id:9,conversation_id:'cB'}],
        artifactsByOrder:{7:[{file_path:'C:/p/a7.txt'}],8:[{file_path:'C:/p/a8.txt'}],9:[{file_path:'C:/p/b9.txt'}]}})`);
      await sleep(250);
      const names = () => q(`[...document.querySelectorAll('#r1 .rc-file')].map(f => f.dataset.rcFile.split('/').pop())`);
      assert.deepEqual(await names(), ['a7.txt', 'a8.txt'], 'CK-CAB-025 r2 Resultados: todas las ordenes de la conversacion activa');
      await evaluate(`window.rcOrderId = 9; document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:1,tokens:1,pct:0,turns:1}}))`);
      await sleep(250);
      assert.deepEqual(await names(), ['b9.txt'], 'CK-CAB-025 r2 al abrir otra sesion, solo los de esa sesion');
      await evaluate(`window.rcOrderId = 0; document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:0,tokens:0,pct:null,turns:0}}))`);
      await sleep(150);
      assert.deepEqual(await names(), [], 'CK-CAB-025 r2 Nueva conversacion vacia Resultados');
      assert.match(await q(`document.querySelector('#r1 [data-rc-section="resultados"] .rc-empty').textContent`), /Aún no hay archivos/);
      assert.equal(await q(`document.querySelector('#r1 [data-rc-summary="resultados"]').textContent`), '0', 'la cuenta de la cabecera tambien');
      await evaluate(`window.rcOrderId = 7; document.dispatchEvent(new CustomEvent('devagents:thread-usage',{detail:{chars:1,tokens:1,pct:0,turns:1}}))`);
      await sleep(250);
      await evaluate(`window.P.r1.panel.appendEvents([{id:50,ts:Date.now(),source:'x',kind:'file_written',payload:{file_path:'C:/p/vivo.txt'}}])`);
      assert.deepEqual(await names(), ['a7.txt', 'vivo.txt', 'a8.txt'], 'CK-CAB-025 r2 lo escrito en vivo se suma a su conversacion');
      assert.equal(await q(`document.querySelector('#r1 [data-rc-summary="resultados"]').textContent`), '3');
    });

    await sec('17. CK-CAB-025 r2 Entorno se refresca: order_done, foco, cambio de proyecto, intervalo solo visible.', async () => {
      // 17. r2 Entorno se refresca: order_done, foco, cambio de proyecto, intervalo solo visible.
      await evaluate(`window.rcOrderId = 0`);
      await evaluate(`window.mk('e2', {root:'C:\\\\uno\\\\proyecto-a'})`);
      await sleep(200);
      const listDirOf = id => q(`window.P.${id}.core.calls.listDir`);
      const base = await listDirOf('e2');
      await evaluate(`window.P.e2.panel.appendEvents([{id:1,ts:Date.now(),source:'x',kind:'order_done',payload:{}}])`);
      await sleep(150);
      assert((await listDirOf('e2')) > base, 'CK-CAB-025 r2 Entorno se relee tras order_done');
      const afterDone = await listDirOf('e2');
      await evaluate(`window.dispatchEvent(new Event('focus'))`);
      await sleep(150);
      assert((await listDirOf('e2')) > afterDone, 'CK-CAB-025 r2 Entorno se relee al recuperar el foco');
      await evaluate(`window.P.e2.core.root = 'D:\\\\otro\\\\proyecto-b'; window.P.e2.core.repo = {isRepo:true, branch:'feature/x'}; document.dispatchEvent(new CustomEvent('devagents:workspace-changed'))`);
      await sleep(200);
      assert.equal(await q(`document.querySelector('#e2 .rc-env__name').textContent`), 'proyecto-b', 'CK-CAB-025 r2 Entorno sigue al cambio de proyecto');
      assert(await q(`document.querySelector('#e2 [data-rc-env="branch"]').textContent.includes('feature/x')`), 'y a la rama nueva');
      await evaluate(`window.mk('e1', {}, {pollMs: 150})`);
      await sleep(120);
      const poll0 = await listDirOf('e1');
      await sleep(600);
      const poll1 = await listDirOf('e1');
      assert(poll1 >= poll0 + 2, 'CK-CAB-025 r2 el intervalo relee Entorno mientras esta visible: ' + poll0 + ' -> ' + poll1);
      await evaluate(`document.getElementById('e1').style.display = 'none'`);
      await sleep(200);
      const hidden0 = await listDirOf('e1');
      await sleep(600);
      assert.equal(await listDirOf('e1'), hidden0, 'CK-CAB-025 r2 oculta no sondea');
      await evaluate(`window.P.e1.panel.destroy()`);
      // Ahead/behind solo si el host lo devuelve.
      await evaluate(`(() => { window.mk('e3', {}); const c = window.P.e3.core; const orig = c.gitBranch.bind(c); c.gitBranch = async r => ({ ...(await orig(r)), ahead: 2, behind: 1 }); window.P.e3.panel.refreshEnvironment(); return true; })()`);
      await sleep(200);
      assert.equal(await q(`document.querySelector('#e3 .rc-env__sync')?.textContent.trim()`), '↑2 ↓1', 'ahead/behind cuando el host lo devuelve');
      assert.equal(await q(`document.querySelector('#e2 .rc-env__sync')`), null, 'sin dato del host no se inventa');
    });

    await sec('18. CK-CAB-025 r2 a 360 px de columna nada desborda y el texto largo termina en elipsis con title.', async () => {
      // 18. r2 a 360 px de columna nada desborda y el texto largo termina en elipsis con title.
      await evaluate(`(() => { const col = document.getElementById('panel-secondary'); col.style.width = '360px'; col.style.flex = '0 0 360px'; return true; })()`);
      const longRoot = 'C:\\Workspace\\Usuario\\Desktop\\Proyectos\\una-carpeta-intermedia-muy-larga\\Proyecto con un nombre extremadamente largo para probar la elipsis';
      await evaluate(`window.rcCore.root = ${JSON.stringify(longRoot)}; window.rc.refreshEnvironment()`);
      await sleep(200);
      const fit = await q(`(() => {
        const cards = document.querySelector('#right-cards-host .rc-cards');
        const over = [...cards.querySelectorAll('.rc-card, .rc-card *')].filter(e => e.getBoundingClientRect().right > cards.getBoundingClientRect().right + 1).map(e => e.className).slice(0, 5);
        const row = document.querySelector('#right-cards-host [data-rc-env="project"]');
        const name = row.querySelector('.rc-env__name');
        return { colW: document.getElementById('panel-secondary').getBoundingClientRect().width, scrollX: cards.scrollWidth > cards.clientWidth, over,
          rowH: row.getBoundingClientRect().height, nameOver: getComputedStyle(name).textOverflow, nameTitle: name.title };
      })()`);
      assert(fit.colW <= 361, 'columna de 360 px: ' + fit.colW);
      assert.equal(fit.scrollX, false, 'CK-CAB-025 r2 a 360 px no hay desbordamiento horizontal');
      assert.deepEqual(fit.over, [], 'CK-CAB-025 r2 a 360 px ningun elemento se sale de la ventana');
      assert(fit.rowH < 40, 'proyecto + padre siguen en una linea: ' + fit.rowH);
      assert.equal(fit.nameOver, 'ellipsis');
      assert.equal(fit.nameTitle, longRoot, 'CK-CAB-025 r2 el title lleva la ruta completa');
      await evaluate(`(() => { const col = document.getElementById('panel-secondary'); col.style.width = ''; col.style.flex = ''; window.rcCore.root = 'C:\\\\proyectos\\\\calculadora'; return true; })()`);
    });

    await sec('19. CK-CAB-025 r3 ventanas dentro del chat y paneles opcionales a la derecha', async () => {
      for (const file of ['right_cards_layout.test.js', 'right_cards_router.test.js', 'right_cards_toggle.test.js']) {
        await evaluate(fs.readFileSync(path.join(__dirname, '../shell/webui/dist/' + file), 'utf8'));
      }
      await evaluate(`(() => {
        for (const id of Object.keys(window.P)) window.P[id].panel.destroy();
        window.rc.destroy();
        RcLayoutTest.renderLayout(document.body);
        localStorage.setItem('devagents.panel.bottom.collapsed','false');
        window.pty = { spawn: 0, kill: 0 }; window.termStates = [];
        document.addEventListener('devagents:terminal-state', e => window.termStates.push(e.detail));
        // primer arranque sin terminales vivas (pty.read {list:true} vacío).
        window.bridgeClient = { send: async (kind, payload) => {
          if (kind === 'pty.read' && payload && payload.list === true) return {status:'ok',payload:{terminals:[]}};
          throw new Error('Petición de puente no simulada: ' + kind);
        } };
        const base = { listDir: async () => ({root:'C:/p',entries:[{name:'a.txt',path:'C:/p/a.txt',isDir:false}]}),
          ptySpawn: async () => {window.pty.spawn++;return {terminalId:42,mode:'conpty'};},
          ptyRead: async () => ({data:'',offset:0}), ptyWrite: async () => ({}), ptyResize: async () => ({}),
          ptyKill: async () => {window.pty.kill++;return {};} };
        const core = new Proxy(base,{get:(t,k)=>k in t ? t[k] : async()=>({})});
        window.termRouter = new RcRouterTest.ViewRouter(core);
        const host = document.getElementById('right-cards-host');
        window.termRc = new window.RightCardsPanel(host,window.rcStub(),Object.assign({},window.rcActions,{
          togglePanel: () => window.floatToggle(), toggleTerminal: () => RcToggleTest.toggleTerminalPanel(),
          toggleActivity: () => RcToggleTest.toggleRightPanel('activity'), showExplorer: () => RcToggleTest.toggleRightPanel('explorer')
        }));
        window.floatToggle = RcLayoutTest.initPanelToggles();
        document.getElementById('pane-mission-container').innerHTML = '<div class="col" style="height:100%"><div id="mission-body" class="grow scroll-y"><div>Conversacion</div></div><div><div id="mission-composer">Escribe una orden</div></div></div>';
        return true;
      })()`);
      const visible = id => q(`getComputedStyle(document.getElementById('${id}')).display !== 'none'`);
      assert.equal(await visible('panel-secondary'), false, 'arranque sin panel aunque antes estuviera abierto');
      assert.equal(await q('window.pty.spawn'), 0, 'PTY se crea solo al pedir la terminal');
      const geometry = await q(`(() => {const host=document.getElementById('right-cards-host'),area=document.getElementById('editor-area');return {
        inside:area.contains(host), pos:getComputedStyle(host).position, bg:getComputedStyle(host).backgroundColor,
        border:getComputedStyle(host).borderLeftWidth, chat:document.getElementById('pane-mission-container').getBoundingClientRect().width,
        area:area.getBoundingClientRect().width, separate:!document.getElementById('panel-secondary').contains(host)};})()`);
      assert(geometry.inside && geometry.separate, JSON.stringify(geometry));
      assert.equal(geometry.pos,'absolute'); assert.equal(geometry.bg,'rgba(0, 0, 0, 0)'); assert.equal(geometry.border,'0px');
      assert.equal(geometry.chat,geometry.area,'el chat ocupa todo el ancho');
      await send('Emulation.setDeviceMetricsOverride',{width:1920,height:1080,deviceScaleFactor:1,mobile:false});
      const textBox = await q(`(() => {const text=document.querySelector('#mission-body > div').getBoundingClientRect(), composer=document.getElementById('mission-composer').getBoundingClientRect(), cards=document.querySelector('.rc-cards').getBoundingClientRect();return {text:text.width,composer:composer.width,right:Math.max(text.right,composer.right),left:cards.left};})()`);
      assert(textBox.text<=760 && textBox.composer<=760 && textBox.right<textBox.left,'conversacion centrada con maximo sin ventanas encima: '+JSON.stringify(textBox));
      await send('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:false});
      await clickSelector('.rc-tool[data-rc-action="panel"]');
      assert.equal(await q(`getComputedStyle(document.querySelector('.rc-cards')).display`),'none');
      assert.equal(await q(`localStorage.getItem('devagents.panel.right')`),'true');
      assert(await q(`document.getElementById('mission-body').getBoundingClientRect().top >= document.querySelector('.rc-tools').getBoundingClientRect().bottom`),'la fila de iconos no tapa el chat al ocultar ventanas');
      await evaluate('RcLayoutTest.initPanelToggles()');
      assert.equal(await q(`getComputedStyle(document.querySelector('.rc-cards')).display`),'none','se restaura la visibilidad');
      await evaluate('window.floatToggle()');
      await clickSelector('.rc-tool[data-rc-action="terminal"]'); await sleep(250);
      assert.equal(await visible('panel-secondary'),true);
      assert.equal(await q(`document.getElementById('panel-secondary').contains(document.getElementById('panel-bottom'))`),true);
      const rect = await q(`(() => {const p=document.getElementById('panel-secondary').getBoundingClientRect(),c=document.getElementById('central-container').getBoundingClientRect();return {left:p.left,right:c.right,height:p.height};})()`);
      assert(rect.left>=rect.right-1 && rect.height>200,'terminal a la derecha: '+JSON.stringify(rect));
      const termId = () => q(`(() => {document.dispatchEvent(new CustomEvent('devagents:terminal-state-request'));return window.termStates.at(-1)?.terminalId;})()`);
      assert.equal(await termId(),42);
      await clickSelector('.rc-tool[data-rc-action="terminal"]');
      assert.equal(await visible('panel-secondary'),false); assert.equal(await termId(),42);
      await clickSelector('.rc-tool[data-rc-action="terminal"]'); await sleep(100);
      assert.equal(await termId(),42); assert.equal(await q('window.pty.spawn'),1); assert.equal(await q('window.pty.kill'),0);
      await clickSelector('#btn-close-side-panel'); assert.equal(await visible('panel-secondary'),false);
      await clickSelector('.rc-tool[data-rc-action="activity"]');
      assert.equal(await visible('panel-secondary'),true); assert.equal(await visible('chat-host'),true);
      assert.equal(await q(`!!document.querySelector('.rc-cards #chat-host, .rc-card--actividad')`),false);
      await clickSelector('.rc-tool[data-rc-action="activity"]'); assert.equal(await visible('panel-secondary'),false);
      await clickSelector('.rc-tool[data-rc-action="explorer"]'); await sleep(150);
      assert.equal(await visible('panel-secondary'),true);
      assert.match(await q(`document.getElementById('right-explorer-body').innerText`),/a.txt/);
      await clickSelector('.rc-tool[data-rc-action="explorer"]'); assert.equal(await visible('panel-secondary'),false);
      await evaluate(`window.termRouter.observeOrderEvents([{kind:'shell_command',payload:{command:'echo agente',status:'running'}}])`); await sleep(100);
      assert.equal(await visible('panel-secondary'),true,'la ejecucion del agente puede mostrar el panel');
      await clickSelector('#btn-close-side-panel');
      await evaluate(`window.termRouter.observeOrderEvents([{kind:'shell_command',payload:{status:'delta',chunk:'hola'}}])`);
      assert.equal(await visible('panel-secondary'),false,'cerrar durante un comando no se deshace con cada delta');
      await evaluate(`window.termRouter.runInTerminal('echo usuario')`);
      assert.equal(await q('window.pty.spawn'),1,'ejecutar por el router reutiliza la PTY');
      if (process.env.CK025_EVIDENCE_DIR) {
        fs.writeFileSync(path.join(process.env.CK025_EVIDENCE_DIR,'r3-terminal.png'),Buffer.from((await send('Page.captureScreenshot',{format:'png'})).data,'base64'));
        fs.writeFileSync(path.join(process.env.CK025_EVIDENCE_DIR,'r3-terminal-dom.txt'),await q('document.body.innerText'));
        await clickSelector('#btn-close-side-panel');
        fs.writeFileSync(path.join(process.env.CK025_EVIDENCE_DIR,'r3-flotantes.png'),Buffer.from((await send('Page.captureScreenshot',{format:'png'})).data,'base64'));
        fs.writeFileSync(path.join(process.env.CK025_EVIDENCE_DIR,'r3-flotantes-dom.txt'),await q('document.body.innerText'));
      }
    });

    // ======================================================================
    // r4 — ajustes del dueno tras probar la r3 en la cabina:
    // 1) un solo control de ocultar ventanas; 2) las dos carpetas gemelas de
    // la barra de actividades; 3) tamanyos de la referencia de Claude;
    // 4) ventanas SOLO en la vista Agente.
    // ======================================================================
    await sec('r4-1: un SOLO control para ocultar las ventanas (sin duplicado en la barra de titulo)', async () => {
      await evaluate(`document.getElementById('btn-close-side-panel')?.click()`);
      assert.equal(await q(`document.getElementById('btn-toggle-panel')`), null, 'r4-1: la barra de titulo ya no repite el control de ocultar ventanas');
      assert.equal(await q(`document.querySelectorAll('[data-rc-action="panel"]').length`), 1, 'r4-1: queda un unico control en la fila de iconos');
      assert.notEqual(await q(`getComputedStyle(document.querySelector('#right-cards-host .rc-cards')).display`), 'none', 'r4-1: estado inicial desplegado');
      await clickSelector('#right-cards-host .rc-tool[data-rc-action="panel"]');
      assert.equal(await q(`getComputedStyle(document.querySelector('#right-cards-host .rc-cards')).display`), 'none', 'r4-1: el control unico oculta las ventanas');
      assert.equal(await q(`localStorage.getItem('devagents.panel.right')`), 'true', 'r4-1: persistencia intacta');
      await clickSelector('#right-cards-host .rc-tool[data-rc-action="panel"]');
      assert.notEqual(await q(`getComputedStyle(document.querySelector('#right-cards-host .rc-cards')).display`), 'none', 'r4-1: el mismo control las vuelve a mostrar');
      const meta = await q(`(() => {const b=document.querySelector('#right-cards-host [data-rc-action="panel"]');return [b.title,b.getAttribute('aria-label')||'',b.getAttribute('aria-expanded'),b.getAttribute('aria-controls')];})()`);
      assert(meta[0].length > 0 && meta[1].length > 0 && meta[2] !== null, 'r4-1: title, aria-label y aria-expanded del control unico: ' + JSON.stringify(meta));
      assert.equal(meta[3], 'right-cards-host', 'r4-1: aria-controls apunta al host de las ventanas');
      const rowIcon = await q(`document.querySelector('#right-cards-host [data-rc-action="panel"] svg')?.getAttribute('width')`);
      assert.equal(rowIcon, '16', 'r4-3: icono del control a 16 px');
    });

    await sec('r4-2: la barra de actividades ya no tiene dos carpetas gemelas (icono y title distintos)', async () => {
      const bar = await q(`(() => {
        const sig = el => (el?.innerHTML || '').replace(/\\s+/g, '');
        const ids = ['agent', 'explorer', 'search', 'monitor', 'spaces', 'mcp', 'issues', 'settings'];
        const byId = Object.fromEntries(ids.map(id => [id, sig(document.getElementById('act-' + id))]));
        return {
          // (c): Ayuda y Desplegar panel no son vistas (sin data-view).
          views: [...document.querySelectorAll('.activity-bar__item[data-view]')].map(e => e.dataset.view),
          byId,
          tExplorer: document.getElementById('act-explorer')?.title || '',
          tIssues: document.getElementById('act-issues')?.title || '',
        };
      })()`);
      assert.deepEqual(bar.views, ['agent', 'explorer', 'search', 'monitor', 'spaces', 'mcp', 'issues', 'settings'], 'r4-2: una sola botonera con cada vista una vez');
      for (const id of Object.keys(bar.byId)) assert(bar.byId[id].length > 0, 'r4-2: icono presente en ' + id);
      assert.equal(new Set(Object.values(bar.byId)).size, Object.keys(bar.byId).length, 'r4-2: todos los iconos de la barra son distintos entre si (explorador e incidencias ya no son gemelos): ' + JSON.stringify(bar.byId));
      assert(bar.tExplorer.toLowerCase().includes('archiv'), 'r4-2: el title del explorador dice que abre archivos');
      assert(bar.tIssues.toLowerCase().includes('incidencia'), 'r4-2: el title de la segunda carpeta dice que abre las incidencias');
    });

    await sec('r4-3: tamanyos de la referencia (titulo 13 px seminegrita, resumenes 12 px atenuados, iconos 16 px en botones de 28 px, relleno compacto)', async () => {
      const m = await q(`(() => {
        const g = (el, p) => getComputedStyle(el)[p];
        const head = document.querySelector('#right-cards-host .rc-card__head');
        const sum = document.querySelector('#right-cards-host .rc-card__summary');
        const body = document.querySelector('#right-cards-host .rc-card__body');
        const tool = document.querySelector('#right-cards-host .rc-tool');
        const svg = tool?.querySelector('svg');
        const row = document.querySelector('#right-cards-host .rc-env__row');
        const counts = document.querySelector('#right-cards-host .rc-changes__counts');
        return { ts: g(head,'fontSize'), tw: g(head,'fontWeight'), hp: g(head,'paddingLeft'),
          ss: g(sum,'fontSize'), sp: g(sum,'color'), bp: g(body,'paddingLeft'),
          bw: g(tool,'width'), bh: g(tool,'height'), is: svg ? svg.getAttribute('width') : '',
          rs: g(row,'fontSize'), cs: counts ? g(counts,'fontSize') : '' };
      })()`);
      assert.equal(m.ts, '13px', 'r4-3: titulo de ~13 px: ' + m.ts);
      assert.equal(m.tw, '600', 'r4-3: seminegrita');
      assert.equal(m.hp, '10px', 'r4-3: relleno de cabecera ~10 px');
      assert.equal(m.ss, '12px', 'r4-3: resumen ~12 px: ' + m.ss);
      assert.equal(m.sp, 'rgb(154, 149, 142)', 'r4-3: resumen atenuado (fg-subtle del tema)');
      assert.equal(m.bp, '10px', 'r4-3: cuerpo compacto (~10 px)');
      assert.equal(m.bw, '28px', 'r4-3: boton de icono ~28 px');
      assert.equal(m.bh, '28px', 'r4-3: boton de icono ~28 px');
      assert.equal(m.is, '16', 'r4-3: icono de fila ~16 px');
      assert(parseFloat(m.rs) <= 13 && parseFloat(m.rs) >= 12, 'r4-3: filas 12-13 px: ' + m.rs);
      if (m.cs) assert.equal(m.cs, '12px', 'r4-3: contadores de Cambios a 12 px');
    });

    await sec('r4-4: las ventanas existen SOLO en la vista Agente; en las demas se ocultan y al volver reaparecen con su estado', async () => {
      await evaluate(`document.getElementById('btn-close-side-panel')?.click()`);
      await clickSelector('#right-cards-host [data-rc-fold="resultados"]');
      const foldedBefore = await q(`document.querySelector('#right-cards-host [data-rc-section="resultados"] .rc-card__body').hidden`);
      const measure = `(() => { const h = document.getElementById('right-cards-host'); return {
        disp: getComputedStyle(h).display, viewHidden: h.dataset.viewHidden || '',
        central: document.getElementById('central-container').classList.contains('cards-view-hidden') }; })()`;
      let st = await q(measure);
      assert.equal(st.viewHidden, '', 'r4-4: arranque en Agente sin marca de vista oculta');
      assert.notEqual(st.disp, 'none', 'r4-4: visibles en Agente');
      await evaluate(`document.dispatchEvent(new CustomEvent('devagents:view-changed', { detail: 'explorer' }))`);
      st = await q(measure);
      assert.equal(st.disp, 'none', 'r4-4: fuera de Agente no hay ni fila de iconos ni ventanas: ' + JSON.stringify(st));
      assert.equal(st.viewHidden, 'true', 'r4-4: marcada la vista oculta');
      assert.equal(st.central, true, 'r4-4: el chat recupera su ancho completo');
      await evaluate(`window.termRouter.show('monitor')`);
      st = await q(measure);
      assert.equal(st.disp, 'none', 'r4-4: el router real tambien las oculta en Monitor');
      await evaluate(`window.termRouter.show('agent')`);
      st = await q(measure);
      assert.notEqual(st.disp, 'none', 'r4-4: al volver a Agente reaparecen');
      assert.equal(st.viewHidden, 'false', 'r4-4: marca de vista deshecha');
      assert.equal(st.central, false, 'r4-4: el padding de las ventanas vuelve');
      assert.equal(await q(`document.querySelector('#right-cards-host [data-rc-section="resultados"] .rc-card__body').hidden`), foldedBefore, 'r4-4: el plegado individual se conserva');
      await clickSelector('#right-cards-host [data-rc-fold="resultados"]');
      await evaluate(`localStorage.removeItem('devagents.panel.right.cards'); localStorage.removeItem('devagents.panel.right');`);
    });

    // ======================================================================
    // r5 - el hilo del chat se desplaza a todo el ancho del area:
    // su barra queda en el borde derecho, por fuera de las ventanas, y no
    // aparece ninguna linea/barra entre la conversacion y ellas (referencia
    // claude-scroll-a-la-derecha.png).
    // ======================================================================
    await sec('r5: el scroll del chat llega al borde derecho, por fuera de las ventanas y sin separador visible', async () => {
      await evaluate(`(() => {
        document.dispatchEvent(new CustomEvent('devagents:view-changed', { detail: 'agent' }));
        const host = document.getElementById('right-cards-host');
        if (host.dataset.collapsed === 'true') document.querySelector('#right-cards-host [data-rc-action="panel"]').click();
        document.getElementById('pane-mission-container').innerHTML = '<div class="col grow" style="height:100%;background:var(--bg-main)">' +
          '<div class="grow" style="position:relative;min-height:0;display:flex;flex-direction:column">' +
          '<div class="grow scroll-y" id="mission-body" style="display:flex;flex-direction:column;align-items:stretch"></div>' +
          '</div>' +
          '<div style="padding:12px 16px 16px"><div class="card" id="mission-composer">Escribe una orden</div></div></div>';
        const body = document.getElementById('mission-body');
        for (let i = 0; i < 40; i++) {
          const turn = document.createElement('div');
          turn.className = 'turno';
          turn.style.height = '48px';
          turn.textContent = 'Turno ' + i + ' de una conversacion larga que obliga a desplazarse';
          body.appendChild(turn);
        }
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,80))');
      const m = await q(`(() => {
        const body = document.getElementById('mission-body');
        const area = document.getElementById('editor-area').getBoundingClientRect();
        const host = document.getElementById('right-cards-host').getBoundingClientRect();
        const cardsEl = document.querySelector('#right-cards-host .rc-cards');
        const cards = cardsEl.getBoundingClientRect();
        const turn = document.querySelector('#mission-body > *').getBoundingClientRect();
        const cs = getComputedStyle(body), cc = getComputedStyle(cardsEl);
        return {
          overflowY: cs.overflowY, scrollable: body.scrollHeight > body.clientHeight,
          bodyRight: body.getBoundingClientRect().right, areaRight: area.right,
          cardsRight: cards.right, hostRight: host.right, cardsLeft: cards.left,
          turnRight: turn.right, turnLeft: turn.left, turnWidth: turn.width,
          bodyBorderRight: cs.borderRightWidth, bodyShadow: cs.boxShadow,
          cardsBorderLeft: cc.borderLeftWidth, cardsDirection: cc.direction,
        };
      })()`);
      assert(m.scrollable, 'r5: el hilo de prueba se desplaza de verdad: ' + JSON.stringify(m));
      assert.equal(m.overflowY, 'auto', 'r5: el contenedor del chat es el que tiene overflow');
      assert(Math.abs(m.bodyRight - m.areaRight) <= 1, 'r5: el scroll del chat llega al borde derecho del area: ' + JSON.stringify(m));
      assert(m.bodyRight >= m.cardsRight, 'r5: el scroll queda a la derecha de las ventanas: ' + JSON.stringify(m));
      assert(m.bodyRight >= m.hostRight - 1, 'r5: el scroll alcanza el borde del area, no muere en el hueco de las ventanas');
      assert.equal(m.bodyBorderRight, '0px', 'r5: sin borde vertical entre conversacion y ventanas');
      assert.equal(m.cardsBorderLeft, '0px', 'r5: las ventanas no dibujan borde hacia la conversacion');
      assert.equal(m.bodyShadow, 'none', 'r5: sin sombra que simule un separador: ' + m.bodyShadow);
      assert(m.turnRight <= m.cardsLeft + 1, 'r5: la conversacion sigue a la izquierda de las ventanas: ' + JSON.stringify(m));
      assert(m.turnWidth <= 760.5, 'r5: la conversacion mantiene su ancho maximo: ' + m.turnWidth);
      assert.equal(m.cardsDirection, 'ltr', 'r5: si las ventanas se desplazan, su barra va a su derecha, no junto al chat');
    });

    // ======================================================================
    // r6 - una SOLA barra de desplazamiento vertical, en el borde
    // derecho del area del chat (referencia r5-dos-barras.png). La "barra
    // anterior" que el dueno veia entre la conversacion y las ventanas era el
    // minimapa del transcript (#mission-minimap): su caja de viewport dibuja
    // un borde de 1 px con --accent y sus marcas un relleno con --fg-subtle,
    // de modo que parece un scrollbar. Con las ventanas a la vista no debe
    // existir; la unica pista vertical es la del hilo, en el borde derecho.
    // ======================================================================
    await sec('r6: una sola barra de desplazamiento vertical, en el borde derecho del area del chat', async () => {
      await evaluate(`(() => {
        document.dispatchEvent(new CustomEvent('devagents:view-changed', { detail: 'agent' }));
        const host = document.getElementById('right-cards-host');
        const cardsNow = document.querySelector('#right-cards-host .rc-cards');
        if (host.dataset.collapsed === 'true' || getComputedStyle(cardsNow).display === 'none') {
          document.querySelector('#right-cards-host [data-rc-action="panel"]').click();
        }
        document.getElementById('central-container').classList.remove('cards-hidden');
        document.getElementById('pane-mission-container').innerHTML =
          '<div class="col grow" style="height:100%;background:var(--bg-main)">' +
            '<div class="grow" style="position:relative;min-height:0;display:flex;flex-direction:column">' +
              '<div class="grow scroll-y" id="mission-body" style="display:flex;flex-direction:column;align-items:stretch"></div>' +
              '<div id="mission-minimap" style="display:block"><span class="mmap-mark" style="top:4px;height:12px"></span><span class="mmap-vp" style="top:0;height:40px"></span></div>' +
            '</div>' +
            '<div style="padding:12px 16px 16px"><div class="card" id="mission-composer">Escribe una orden</div></div>' +
          '</div>';
        const body = document.getElementById('mission-body');
        for (let i = 0; i < 60; i++) {
          const turn = document.createElement('div');
          turn.className = 'turno';
          turn.style.height = '48px';
          turn.textContent = 'Turno ' + i + ' de una conversacion larga que obliga a desplazarse';
          body.appendChild(turn);
        }
        const cards = document.querySelector('#right-cards-host .rc-cards');
        const filler = document.createElement('div');
        filler.id = 'r6-filler';
        filler.style.cssText = 'flex:0 0 900px;min-height:900px';
        cards.appendChild(filler);
        cards.scrollTop = 0;
        return true;
      })()`);
      await evaluate('new Promise(r=>setTimeout(r,100))');
      const m = await q(`(() => {
        const pane = document.getElementById('pane-mission-container');
        const body = document.getElementById('mission-body');
        const area = document.getElementById('editor-area').getBoundingClientRect();
        const cardsEl = document.querySelector('#right-cards-host .rc-cards');
        const cards = cardsEl.getBoundingClientRect();
        const minimap = document.getElementById('mission-minimap');
        const mm = getComputedStyle(minimap);
        const bars = [];
        for (const el of pane.querySelectorAll('*')) {
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden') continue;
          const scrollBar = (cs.overflowY === 'auto' || cs.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 1 && cs.scrollbarWidth !== 'none';
          if (scrollBar) bars.push({ id: el.id || el.className || el.tagName, right: el.getBoundingClientRect().right, overflowY: cs.overflowY });
        }
        if (mm.display !== 'none' && minimap.getBoundingClientRect().width > 0) bars.push({ id: 'mission-minimap', right: minimap.getBoundingClientRect().right, minimap: true });
        const cs = getComputedStyle(body);
        return { bars, areaRight: area.right, cardsLeft: cards.left, bodyRight: body.getBoundingClientRect().right,
          bodyOverflow: cs.overflowY, scrollable: body.scrollHeight > body.clientHeight,
          minimapDisplay: mm.display, minimapWidth: minimap.getBoundingClientRect().width,
          cardsScrollbarWidth: getComputedStyle(cardsEl).scrollbarWidth };
      })()`);
      assert(m.scrollable, 'r6: el hilo de prueba se desplaza de verdad: ' + JSON.stringify(m));
      assert.equal(m.bodyOverflow, 'auto', 'r6: el hilo sigue siendo el contenedor que se desplaza');
      assert.equal(m.minimapDisplay, 'none', 'r6: con las ventanas a la vista no hay una segunda pista vertical (minimapa): ' + JSON.stringify(m));
      assert.equal(m.bars.length, 1, 'r6: exactamente una barra de desplazamiento vertical en el area del chat: ' + JSON.stringify(m.bars));
      assert.equal(m.bars[0].id, 'mission-body', 'r6: la unica barra es la del hilo: ' + JSON.stringify(m.bars));
      assert(Math.abs(m.bodyRight - m.areaRight) <= 1, 'r6: la barra del hilo esta en el borde derecho del area: ' + JSON.stringify(m));
      assert(m.bodyRight >= m.cardsLeft, 'r6: la barra queda a la derecha de las ventanas: ' + JSON.stringify(m));
      assert.equal(m.cardsScrollbarWidth, 'none', 'r6: las ventanas no dibujan otra barra junto a la del chat: ' + m.cardsScrollbarWidth);

      // El minimapa sigue disponible cuando las ventanas se ocultan. Al
      // volver a mostrarlas, la unica pista vertical vuelve a ser la del hilo.
      const back = await q(`(() => {
        const c = document.getElementById('central-container');
        const mm = document.getElementById('mission-minimap');
        mm.style.display = '';
        c.classList.add('cards-hidden');
        const recovered = getComputedStyle(mm).display;
        c.classList.remove('cards-hidden');
        const hidden = getComputedStyle(mm).display;
        return { recovered, hidden };
      })()`);
      assert.notEqual(back.recovered, 'none', 'r6: al ocultar las ventanas el minimapa puede volver: ' + JSON.stringify(back));
      assert.equal(back.hidden, 'none', 'r6: con las ventanas a la vista vuelve a ocultarse: ' + JSON.stringify(back));

      // La conversacion se desplaza sin arrastrar las ventanas flotantes.
      const before = await q(`(() => {const c=document.querySelector('#right-cards-host .rc-cards').getBoundingClientRect();return {top:c.top,left:c.left,height:c.height};})()`);
      await evaluate(`(() => {const b=document.getElementById('mission-body');b.scrollTop=0;b.scrollTop=b.scrollHeight;return b.scrollTop;})()`);
      const after = await q(`(() => {const b=document.getElementById('mission-body'),c=document.querySelector('#right-cards-host .rc-cards').getBoundingClientRect();return {top:b.scrollTop,max:b.scrollHeight-b.clientHeight,ctop:c.top,cleft:c.left,cheight:c.height};})()`);
      assert(after.top > 0 && Math.abs(after.top - after.max) <= 1, 'r6: el hilo llega al final al desplazarse: ' + JSON.stringify(after));
      assert.equal(after.ctop, before.top, 'r6: las ventanas no se desplazan con el chat (top)');
      assert.equal(after.cleft, before.left, 'r6: las ventanas no se desplazan con el chat (left)');

      // Rueda del raton: sobre la conversacion mueve el hilo; sobre las
      // ventanas mueve su columna y no el hilo.
      await evaluate(`document.getElementById('mission-body').scrollTop = 0; document.querySelector('#right-cards-host .rc-cards').scrollTop = 0;`);
      const bodyPoint = await q(`(() => {const r=document.getElementById('mission-body').getBoundingClientRect();return {x:r.left+80,y:Math.max(r.top+60,r.bottom-120)};})()`);
      await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: bodyPoint.x, y: bodyPoint.y, deltaX: 0, deltaY: 240 });
      await evaluate('new Promise(r=>setTimeout(r,120))');
      const wheelBody = await q(`document.getElementById('mission-body').scrollTop`);
      assert(wheelBody > 0, 'r6: la rueda sobre la conversacion desplaza el hilo: ' + wheelBody);

      await evaluate(`document.getElementById('mission-body').scrollTop = 0; document.querySelector('#right-cards-host .rc-cards').scrollTop = 0;`);
      const cardsPoint = await q(`(() => {const r=document.querySelector('#right-cards-host .rc-cards').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+80};})()`);
      await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: cardsPoint.x, y: cardsPoint.y, deltaX: 0, deltaY: 180 });
      await evaluate('new Promise(r=>setTimeout(r,120))');
      const wheelCards = await q(`(() => {const b=document.getElementById('mission-body'),c=document.querySelector('#right-cards-host .rc-cards');return {body:b.scrollTop,cards:c.scrollTop};})()`);
      assert(wheelCards.cards > 0, 'r6: la rueda sobre las ventanas desplaza su columna: ' + JSON.stringify(wheelCards));
      assert.equal(wheelCards.body, 0, 'r6: la rueda sobre las ventanas no mueve el hilo: ' + JSON.stringify(wheelCards));

      await evaluate(`document.getElementById('r6-filler')?.remove(); document.getElementById('mission-body').scrollTop = 0;`);
    });

    if (collect) {
      const bad = sections.filter(x => !x[1]).length;
      console.log('RED-SUMMARY secciones=' + sections.length + ' fallan=' + bad + ' pasan=' + (sections.length - bad));
      process.exitCode = bad ? 1 : 0;
      return;
    }
    console.log('PASS CK-CAB-025 E1-E6 + r2 + r3 + r4 + r5 + r6: pila de cinco ventanas (8 px, nada acoplado, scroll de columna), resumen plegado de cada ventana (proyecto, N % + mini barra, archivos, +A−R, N en curso), Entorno con iconos / padre en una linea con elipsis / refresco por order_done, foco, cambio de proyecto e intervalo solo visible / ahead-behind solo si el host lo da, Contexto real (12 % usado · 121,2k / 1M; evento con prompt_tokens; sin ventana no hay %; estimado con motivo), Resultados por conversacion (otra sesion y Nueva conversacion), Cambios sin devagents-workspace (filas, totales, modal y commit), Confirmar en la cabecera, Tareas, 360 px sin desbordes, Terminal como panel propio abierta/cerrada por su icono conservando el id de sesion pty; r4: un solo control de ocultar ventanas, sin iconos gemelos en la barra de actividades, tamanyos de la referencia (titulo 13 px, resumenes 12 px, iconos 16 px en botones de 28 px, relleno 10 px) y ventanas solo en la vista Agente; r5: el hilo del chat se desplaza a todo el ancho del area con su barra en el borde derecho, por fuera de las ventanas y sin separador visible entre conversacion y ventanas; r6: una sola barra de desplazamiento vertical, la del hilo, en el borde derecho del area del chat (el minimapa del transcript, que parecia una segunda barra, se oculta con las ventanas a la vista y las ventanas no dibujan otra), rueda del raton sobre conversacion y ventanas y sin arrastrar las ventanas. DOM real en Chromium; cabina pendiente.');
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
