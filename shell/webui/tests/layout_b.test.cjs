// (c) — panel izquierdo B · Unificada por defecto y A · IDE clásica
// elegible (maqueta aprobada, páginas 1 y 5). C · Centro de mando (12-nov) es
// B con el grafo de la orden fijo arriba (marca data-centro).
//
// DOM/CSS de producto en Chromium instalado; CoreApi sintética, sin host ni
// motor. Desde shell/webui: node tests/layout_b.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function layoutB() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'angel-pub006c-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'pub006c.html');
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
    const files = { layout: 'src/layout/layout.ts', icons: 'src/design/icons.ts', style: 'src/design/stylesheet.ts', tokens: 'src/design/tokens.ts', html: 'src/design/html.ts', router: 'src/app/view_router.ts', sg: 'src/session_groups.ts', sl: 'src/design/status_labels.ts' };
    const sources = Object.fromEntries(Object.entries(files).map(([name, file]) => {
      const input = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
      const out = ts.transpileModule(input, { reportDiagnostics: true, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
      assert.equal((out.diagnostics || []).length, 0, 'Transpilación sin diagnósticos: ' + file);
      return [name, out.outputText];
    }));
    await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
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
      imports['../session_groups']=load('sg'); imports['../design/status_labels']=load('sl');
      layout.renderLayout(document.body);
      window.layoutMod=layout;
      layout.initLayout();
      window.initPanelToggles=()=>layout.initPanelToggles();
      const vr=load('router');
      const router=Object.create(vr.ViewRouter.prototype);
      router.current='agent';
      router.panes={mission:document.getElementById('pane-mission-container'),editor:document.getElementById('monaco-editor-container'),verification:document.getElementById('pane-verification-container'),catalog:document.getElementById('pane-catalog-container'),settings:document.getElementById('pane-settings-container'),mcp:document.getElementById('pane-mcp-container'),issues:document.getElementById('pane-issues-container'),monitor:document.getElementById('pane-monitor-container'),diff:document.getElementById('pane-diff-container')};
      router.hooks={};
      router.spacesPanel=null;
      router.treeRoot='';
      const ahora=Math.floor(Date.now()/1000);
      window.sesiones=[{order_id:11,title:'Página de precios',status_text:'running',created_at:ahora-60,conversation_id:'c11'},{order_id:12,title:'Reloj analógico',status_text:'done',created_at:ahora-120,conversation_id:'c12'},{order_id:13,title:'Documentar la API',status_text:'failed',created_at:ahora-180,conversation_id:'c13'},{order_id:14,title:'Migración antigua',status_text:'done',created_at:ahora-40*86400,conversation_id:'c14'}];
      router.core={listDir:async()=>({root:'C:/proyecto/devagents-beats',entries:[{name:'shell',path:'shell',is_dir:true},{name:'README.md',path:'README.md',is_dir:false}]}),listSessions:async()=>window.sesiones,repoEmbedStatus:async()=>({state:'empty'}),mcpStatus:async()=>({connected:true}),mcpTools:async()=>[{name:'leer'}],status:async()=>({engineReady:true,version:'0.1.0',providerCount:14,keyCount:12}),catalogInfo:async()=>({model_count:612}),pendingApprovals:async()=>[]};
      router.sessionsRefresher={request(){void router.revalidateSessions();}};
      router.sessionsCache=[]; router.showArchived=false; router.sessionFilter=''; router.sessionCatFilter=''; router.expandedDirs=new Set();
      router.bindActivityBar();
      window.initPanelToggles();
      router.bindLayout();
      window.router=router;
    })()`);


    const settle = () => evaluate('new Promise(r=>setTimeout(r,80))');
    const w = id => evaluate(`(() => { const e=document.getElementById(${JSON.stringify(id)}); return e ? Math.round(e.getBoundingClientRect().width) : -1; })()`);
    const st = () => evaluate(`(() => {
      const vis = e => !!e && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
      const open = Array.from(document.querySelectorAll('#sidebar-sections .sb-sec')).filter(s => !document.getElementById('sb-body-'+s.dataset.view).hidden).map(s=>s.dataset.view);
      const collapse = document.getElementById('btn-sidebar-collapse');
      return {
        layout: document.documentElement.dataset.layout,
        stored: localStorage.getItem('devagents.layout.v1'),
        sections: Array.from(document.querySelectorAll('#sidebar-sections .sb-sec')).map(s=>s.dataset.view),
        open,
        savedOpen: localStorage.getItem('devagents.sections.v1'),
        expanded: Object.fromEntries(Array.from(document.querySelectorAll('.sb-sec__toggle')).map(b=>[b.id,b.getAttribute('aria-expanded')])),
        current: window.router.current,
        collapsed: document.getElementById('sidebar-primary').dataset.collapsed,
        panelLeft: localStorage.getItem('devagents.panel.left'),
        sidebarWidth: document.getElementById('sidebar-primary').getBoundingClientRect().width,
        railVisible: vis(document.getElementById('activity-bar')),
        railWidth: document.getElementById('activity-bar').getBoundingClientRect().width,
        expandShown: vis(document.getElementById('act-expand')),
        footShown: vis(document.getElementById('sidebar-foot')),
        headerShown: vis(document.querySelector('#sidebar-primary > .sidebar__header')),
        oldBodyShown: vis(document.getElementById('sidebar-body')),
        collapseIn: collapse.parentElement.id,
      };
    })()`);
    // 9-nov: Spaces ya no es sección (cada orden crea el suyo; se gestiona en la vista central).
    const views = ['agent', 'explorer', 'search', 'mcp', 'issues', 'monitor'];

    // (a) Arranque sin clave: B, sin franja con el panel abierto (maqueta: .rail.narrow{display:none}).
    await settle();
    let s = await st();
    assert.equal(s.layout, 'B', 'B es la disposición por defecto');
    assert.deepEqual(s.sections, views, 'Una sección por vista, en el orden de la maqueta');
    assert.equal(s.railVisible, false, 'Con el panel abierto NO hay franja de iconos');
    assert.ok(s.footShown, 'Pie con Configuración y Ayuda');
    assert.ok(!s.headerShown && !s.oldBodyShown, 'Nada de la barra lateral de A');
    assert.deepEqual(s.open, ['agent'], 'Por defecto solo Sesiones abierta');
    assert.equal(s.expanded['sb-sec-agent'], 'true');
    assert.equal(s.expanded['sb-sec-monitor'], 'false');

    // (b) Botones de cada cabecera, siempre visibles aunque la sección esté cerrada (navSec).
    const tools = await evaluate(`(() => {
      const vis = id => { const e=document.getElementById(id); return !!e && e.getBoundingClientRect().width > 0; };
      return { archivo: vis('sb-archive-menu'), plegar: vis('btn-sidebar-collapse'), nueva: vis('sb-new-chat'), refreshSes: !!document.querySelector('#sb-tools-agent #sb-refresh'),
        arbol: vis('sb-tree-refresh'), spNew: !!document.getElementById('sb-spaces-new'), mcpDot: vis('sb-mcp-dot'), mcpOk: document.getElementById('sb-mcp-dot')?.classList.contains('is-ok'), monitor: vis('sb-monitor-refresh'),
        busqueda: document.getElementById('sb-tools-search').children.length, incidencias: document.getElementById('sb-tools-issues').children.length };
    })()`);
    assert.deepEqual(tools, { archivo: true, plegar: true, nueva: false, refreshSes: false, arbol: true, spNew: false, mcpDot: true, mcpOk: true, monitor: true, busqueda: 0, incidencias: 0 },
      'Sesiones: Archivo y Plegar (sin + ni Actualizar); Archivos: Actualizar árbol; sin Spaces; MCP: punto; Monitor: Actualizar');
    assert.equal(s.collapseIn, 'titlebar-sidebar-slot', 'El botón de la barra lateral vive arriba a la izquierda (como Claude)');

    // (c) Sesiones va aparte: abrir Archivos no la cierra ni cambia el panel central.
    await click('sb-sec-explorer'); await settle();
    s = await st();
    assert.deepEqual(s.open, ['agent', 'explorer'], 'Sesiones y una de las de abajo a la vez');
    assert.equal(s.current, 'agent', 'Abrir una sección no cambia la vista central');
    assert.equal(await evaluate("document.querySelector('#sb-body-explorer .sb-sec__content').innerText.includes('README.md')"), true, 'Archivos pinta su árbol');
    assert.equal(await evaluate("document.querySelector('#sb-body-agent .sb-sec__content').innerText.includes('Reloj analógico')"), true, 'Sesiones sigue pintada');
    await click('sb-sec-agent'); await settle();
    s = await st();
    assert.deepEqual(s.open, ['explorer'], 'Cerrar Sesiones deja Archivos abierta');
    assert.equal(s.savedOpen, '["explorer"]', 'Las secciones abiertas se recuerdan');
    assert.equal(await evaluate('document.activeElement && document.activeElement.id'), 'sb-sec-agent', 'El foco sigue en la cabecera pulsada');
    await click('sb-sec-agent'); await settle();

    // (d) Enlace «Abrir el Monitor»: resumen en la sección, detalle en el centro.
    await click('sb-sec-monitor'); await settle();
    s = await st();
    assert.deepEqual(s.open, ['agent', 'monitor'], '9-nov: de las de abajo solo una abierta; abrir Monitor cierra Archivos');
    assert.equal(s.expanded['sb-sec-explorer'], 'false', 'Archivos queda plegada');
    assert.equal(await evaluate("document.querySelector('#sb-body-monitor .sb-sec__content').innerText.includes('612')"), true, 'Monitor pinta su resumen');
    await evaluate("document.querySelector('#sb-body-monitor [data-sec-open]').click()"); await settle();
    s = await st();
    assert.equal(s.current, 'monitor', '«Abrir el Monitor» lleva el Monitor al centro');
    assert.deepEqual(s.open, ['agent', 'monitor'], 'y deja las secciones como estaban');
    await evaluate("window.router.show('agent')"); await settle();

    // (e) Sesiones como la maqueta: un campo de búsqueda con la categoría dentro, grupos plegables y puntos de estado.
    const ses = await evaluate(`(() => {
      const b=document.querySelector('#sb-body-agent .sb-sec__content');
      const field=b.querySelector('.sess-search__field');
      return { field: !!field && !!field.querySelector('#sb-sess-filter') && !!field.querySelector('#sb-sess-cat'),
        groups: Array.from(b.querySelectorAll('.sess-group__head')).map(h=>[h.textContent.trim(), h.getAttribute('aria-expanded')]),
        dots: Object.fromEntries(Array.from(b.querySelectorAll('.sess-row')).map(r=>[r.dataset.order, (r.querySelector('.sess-dot')||{}).className||''])),
        agentIcon: b.querySelectorAll('.sess-row .list-item__icon').length };
    })()`);
    assert.ok(ses.field, 'Un solo campo con la lupa, el texto y la categoría');
    assert.deepEqual(ses.groups, [['Hoy · 3', 'true'], ['Anteriores · 1', 'false']], 'Grupos con su número; abierto el primero, plegados los demás');
    assert.match(ses.dots['11'], /sess-dot--run/); assert.match(ses.dots['12'], /sess-dot--ok/); assert.match(ses.dots['13'], /sess-dot--bad/);
    assert.equal(ses.agentIcon, 0, 'Sin el icono del agente en cada fila: punto de estado');
    await evaluate("document.querySelectorAll('#sb-body-agent .sess-group__head')[1].click()"); await settle();
    assert.equal(await evaluate("JSON.parse(localStorage.getItem('devagents.sessgroups.v1'))['Anteriores']"), false, 'El grupo desplegado se recuerda');

    // (e2) Auditoría P2-4: con un filtro, los grupos con coincidencias se abren.
    await evaluate("localStorage.removeItem('devagents.sessgroups.v1'); window.router.refreshSessions()"); await settle();
    await evaluate("(() => { const i=document.getElementById('sb-sess-filter'); i.value='Migración'; i.dispatchEvent(new Event('input',{bubbles:true})); })()"); await settle(); await settle();
    const filtro = await evaluate("(() => { const r=document.querySelector('#sb-body-agent .sess-row[data-order=\"14\"]'); return !!r && r.getBoundingClientRect().height > 0; })()");
    assert.equal(filtro, true, 'La coincidencia dentro de «Anteriores» (plegado por defecto) se ve al filtrar');
    await evaluate("(() => { const i=document.getElementById('sb-sess-filter'); i.value=''; i.dispatchEvent(new Event('input',{bubbles:true})); })()"); await settle(); await settle();

    // (e3) «Configuración» del pie lleva a Configuración.
    await click('sb-foot-settings'); await settle();
    assert.equal(await evaluate('window.router.current'), 'settings', 'El pie abre Configuración');
    await evaluate("window.router.show('agent')"); await settle();

    // (f) Menú Archivo: dos acciones; Escape lo cierra y devuelve el foco.
    await click('sb-archive-menu');
    assert.ok(await evaluate("document.getElementById('sb-archive-before').getBoundingClientRect().width > 0 && document.getElementById('sb-show-archived').getBoundingClientRect().width > 0"), 'Archivo muestra sus dos acciones');
    await evaluate("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))");
    assert.equal(await evaluate("document.getElementById('sb-archive-pop').hidden"), true, 'Escape cierra el menú');
    assert.equal(await evaluate('document.activeElement.id'), 'sb-archive-menu');

    // (g) Petición del propietario (8-nov), comportamiento de Claude: botón arriba a la izquierda (Ctrl+B),
    // sin franja de iconos; oculta, el ratón sobre el botón la muestra flotando, al alejarse
    // desaparece y un clic la fija.
    const mover = async (x, y) => send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
    const centro = id => evaluate(`(() => { const r=document.getElementById(${JSON.stringify(id)}).getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    const peek = () => evaluate("(() => { const sb=document.getElementById('sidebar-primary'); return {cls: sb.classList.contains('is-peek'), w: Math.round(sb.getBoundingClientRect().width), pos: getComputedStyle(sb).position}; })()");
    const btnTitle = () => evaluate("document.getElementById('btn-sidebar-collapse').title");
    assert.equal(await btnTitle(), 'Ocultar barra lateral (Ctrl+B)');
    await click('btn-sidebar-collapse'); await settle();
    s = await st();
    assert.equal(s.collapsed, 'true');
    assert.equal(s.sidebarWidth, 0, 'Oculta: sin panel');
    assert.equal(s.railVisible, false, 'Oculta: SIN franja de iconos (como Claude)');
    assert.equal(await btnTitle(), 'Mostrar barra lateral (Ctrl+B)');
    let c = await centro('btn-sidebar-collapse');
    await mover(900, 400); await settle();
    await mover(c.x, c.y); await settle();
    let pk = await peek();
    assert.ok(pk.cls && pk.w >= 250 && pk.pos === 'absolute', `Ratón encima: aparece flotando (${JSON.stringify(pk)})`);
    await mover(120, 300); await settle();
    assert.ok((await peek()).cls, 'Se puede navegar dentro sin que desaparezca');
    await mover(900, 400); await evaluate('new Promise(r=>setTimeout(r,400))');
    assert.equal((await peek()).cls, false, 'Al alejar el ratón desaparece');
    assert.equal((await st()).collapsed, 'true', 'y sigue oculta');
    c = await centro('btn-sidebar-collapse');
    await mover(c.x, c.y); await settle();
    await click('btn-sidebar-collapse'); await settle();
    s = await st();
    assert.equal(s.collapsed, 'false', 'Un clic la fija');
    assert.equal((await peek()).cls, false, 'fijada ya no es flotante');
    assert.equal(s.panelLeft, 'false');
    await evaluate("document.dispatchEvent(new KeyboardEvent('keydown',{key:'b',ctrlKey:true,bubbles:true}))"); await settle();
    assert.equal((await st()).collapsed, 'true', 'Ctrl+B la oculta');
    await evaluate("document.dispatchEvent(new KeyboardEvent('keydown',{key:'b',ctrlKey:true,bubbles:true}))"); await settle();
    assert.equal((await st()).collapsed, 'false', 'y la vuelve a mostrar');
    await mover(900, 400);
    // Sesiones arriba ocupando el alto; las demás secciones abajo (petición del propietario).
    const pila = await evaluate(`(() => { const sec=v=>document.querySelector('.sb-sec[data-view="'+v+'"]').getBoundingClientRect();
      const foot=document.getElementById('sidebar-foot').getBoundingClientRect(); const m=sec('monitor');
      return { agentTop: Math.round(sec('agent').top), monitorBottom: Math.round(m.bottom), footTop: Math.round(foot.top) }; })()`);
    assert.ok(pila.footTop - pila.monitorBottom <= 12, `Las secciones de abajo quedan pegadas al pie (${JSON.stringify(pila)})`);
    await evaluate("window.router.show('search')"); await settle();

    // (h) A · IDE clásica: la cabina de antes.
    await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'A'}))"); await settle();
    s = await st();
    assert.equal(s.layout, 'A'); assert.equal(s.stored, 'A', 'La elección se guarda');
    assert.deepEqual(s.sections, [], 'En A no hay secciones');
    assert.ok(s.railVisible && s.headerShown && s.oldBodyShown, 'En A: franja, cabecera y barra lateral por vista');
    assert.equal(s.collapseIn, 'sidebar-header-tools', 'Plegar vuelve a la cabecera de A');
    assert.ok(!s.footShown, 'En A no hay pie');
    // Auditoría P2-1: al pasar a A su barra lateral se pinta sola con la vista activa (aquí, Búsqueda).
    assert.equal(s.current, 'search');
    assert.equal(await evaluate("!!document.querySelector('#sidebar-body #search-input')"), true, 'En A la barra lateral de la vista activa se pinta sin pulsar nada');
    await evaluate("window.router.show('agent')"); await settle();
    assert.equal(await evaluate("document.getElementById('sidebar-body').innerText.includes('Reloj analógico')"), true, 'En A las sesiones se pintan en la barra lateral');

    // (i) C se aplica como B con la marca del Centro de mando; un valor
    // guardado desconocido se lee como B. Se vuelve a A para seguir.
    await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'C'}))"); await settle();
    assert.equal((await st()).layout, 'B', 'C usa la barra de la Unificada');
    assert.equal(await evaluate("document.documentElement.dataset.centro"), '1', 'C marca el Centro de mando');
    await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'A'}))"); await settle();
    assert.equal(await evaluate("document.documentElement.dataset.centro ?? null"), null, 'A quita la marca');
    const leido = await evaluate("(() => { const r={}; for (const v of ['C','x','A','B']) { localStorage.setItem('devagents.layout.v1', v); r[v]=window.layoutMod.readLayout(); } localStorage.setItem('devagents.layout.v1','A'); return r; })()");
    assert.deepEqual(leido, { C: 'C', x: 'B', A: 'A', B: 'B' });

    // (j) Sin data-layout el router se comporta como A (nunca deja el contenido en un contenedor oculto).
    await evaluate("delete document.documentElement.dataset.layout; document.dispatchEvent(new CustomEvent('devagents:layout-changed'))"); await settle();
    s = await st();
    assert.deepEqual(s.sections, []); assert.ok(s.oldBodyShown, 'Sin atributo: barra lateral de A visible');

    // (k) Vuelta a B: se recuperan las secciones que el usuario dejó abiertas.
    await evaluate("document.dispatchEvent(new CustomEvent('devagents:set-layout',{detail:'B'}))"); await settle();
    s = await st();
    assert.equal(s.layout, 'B');
    assert.ok(s.open.includes('search') && !s.open.includes('explorer') && !s.open.includes('monitor'), 'Secciones abiertas recordadas (una sola de las de abajo: la última, Búsqueda)');

    // (l) Ningún id se pierde.
    const ids = ['sidebar-title', 'sidebar-actions', 'sidebar-body', 'btn-sidebar-collapse', 'sidebar-header-tools', 'sidebar-sections', 'sidebar-foot', 'sb-foot-settings', 'sb-foot-help', 'act-help', 'act-expand', 'act-settings', 'sb-archive-menu', 'sb-archive-before', 'sb-show-archived', 'sb-new-chat', 'btn-browser', 'btn-settings', 'status-monitor', ...views.map(v => 'act-' + v)];
    const missing = await evaluate(`${JSON.stringify(ids)}.filter(id=>!document.getElementById(id))`);
    assert.deepEqual(missing, [], 'Ningún id falta');
    // Barra de título y de estado de B como la maqueta (los ids siguen, ocultos).
    assert.deepEqual([await w('btn-browser'), await w('status-monitor')], [0, 0], 'En B sin navegador en la barra de título y sin Monitor en la de estado');
    // 10-nov (propietario): la tuerca de Configuración SÍ va en la barra de título, junto a la campana.
    assert.ok(await w('btn-settings') > 0, 'En B la tuerca de Configuración se ve en la barra de título');
    assert.equal(await evaluate(`document.getElementById('btn-attention').nextElementSibling?.id`), 'btn-settings', 'La tuerca va justo después de la campana');

    // (n) 10-nov (propietario): atrás/avanzar entre vistas, Configuración sin la franja
    // Agente/Dev y su «×» vuelve a donde se estaba.
    const nav = await evaluate(`(() => { const r = window.router; const out = {};
      r.show('agent'); r.show('monitor'); r.show('settings');
      out.tabbar = getComputedStyle(document.getElementById('tab-bar')).display;
      r.closeSettings(); out.trasCerrar = document.documentElement.dataset.view;
      out.tabbarFuera = getComputedStyle(document.getElementById('tab-bar')).display;
      r.back(); out.trasAtras = document.documentElement.dataset.view;
      out.atrasHabilitado = !document.getElementById('btn-nav-back').disabled;
      r.forward(); out.trasAvanzar = document.documentElement.dataset.view;
      return out; })()`);
    assert.equal(nav.tabbar, 'none', 'En Configuración no se ve la franja Nueva conversación / Agente / Dev');
    assert.equal(nav.trasCerrar, 'monitor', 'La × de Configuración vuelve a la vista anterior');
    assert.notEqual(nav.tabbarFuera, 'none', 'Fuera de Configuración la franja vuelve');
    assert.equal(nav.trasAtras, 'agent', 'Atrás vuelve a la vista anterior del historial');
    assert.equal(nav.trasAvanzar, 'monitor', 'Avanzar rehace el paso');

    // (m) Bug visto por el propietario (8-nov): chat → abrir un archivo (showEditor) → volver al chat.
    // Las ventanas de la derecha escuchan devagents:view-changed; volver tiene que anunciar «agent».
    const anuncios = await evaluate(`(() => { const v=[]; const f=e=>v.push(e.detail); document.addEventListener('devagents:view-changed', f);
      window.router.show('agent'); window.router.showEditor(); window.router.show('agent');
      document.removeEventListener('devagents:view-changed', f); return v; })()`);
    assert.deepEqual(anuncios.slice(-2), ['explorer', 'agent'], 'Volver al chat tras abrir un archivo anuncia «agent» (las ventanas de la derecha reaparecen)');

    console.log('PASS CK-PUB-006c/e: B sin franja de iconos; botón arriba a la izquierda con vista flotante, fijar con clic y Ctrl+B; Sesiones arriba y el resto abajo; secciones independientes con sus botones; A elegible; C aplica la Unificada con el Centro de mando.');
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
