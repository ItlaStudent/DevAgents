// DS-UI2 (16-oct-2026): segunda tanda de pulido visible para la demo.
// Aserciones sobre los módulos REALES compilados a CJS (ver build_dsui2_test.mjs).
const assert = require('node:assert/strict');
let failed = 0;
function check(name, cond, detail) {
  if (cond) console.log(`  ok: ${name}`);
  else { failed += 1; console.error(`  FAIL: ${name}${detail ? ` -> ${detail}` : ''}`); }
}

const { statusLabel, departmentLabel } = require('../shell/webui/dist/status_labels.dsui2.test.cjs');
const { MissionControlPanel } = require('../shell/webui/dist/mission_control.dsui2.test.cjs');
const { MonitorPanel } = require('../shell/webui/dist/monitor_panel.dsui2.test.cjs');
const { renderLayout } = require('../shell/webui/dist/layout.dsui2.test.cjs');
const { RefreshCoalescer } = require('../shell/webui/dist/refresh_coalescer.dsui2.test.cjs');

const tick = () => new Promise((r) => setTimeout(r, 0));

// ── P1: una sola función de etiqueta para órdenes y fases ────────────────
for (const [input, expected] of [
  ['done', 'Hecha'], ['failed', 'Fallida'], ['cancelled', 'Cancelada'],
  ['interrupted', 'Interrumpida'], ['audit_unavailable', 'Sin auditar'],
  ['awaiting_approval', 'Pendiente de aprobar'], ['planning', 'Planificando'],
  ['running', 'Ejecutando'], ['idle', 'Inactivo'], ['error', 'Error'],
  ['awaiting-approval', 'Pendiente de aprobar'], ['audit-unavailable', 'Sin auditar'],
  ['best-of-n', 'Eligiendo candidata'], ['chat', 'Conversación'],
  ['planned', 'Plan sin aprobar'], ['clarifying', 'Necesita aclaraciones'],
  ['pending', 'Pendiente'], ['approved', 'Aprobada'], ['rejected', 'Rechazada'],
  ['awaiting_best_of_n', 'Eligiendo candidata'],
]) {
  check(`statusLabel(${input}) = ${expected}`, statusLabel(input) === expected, statusLabel(input));
}
// DaOrderStatus numérico (mismo orden que el enum C).
check('statusLabel(5 numérico) = Hecha', statusLabel(5) === 'Hecha', statusLabel(5));
check('statusLabel(6 numérico) = Fallida', statusLabel(6) === 'Fallida', statusLabel(6));
check('statusLabel(9 numérico) = Cancelada', statusLabel(9) === 'Cancelada', statusLabel(9));
check('desconocido se conserva', statusLabel('raro') === 'raro', statusLabel('raro'));
check('vacío -> cadena vacía', statusLabel('') === '' && statusLabel(null) === '');

// ── P4: departamentos con su nombre en español ──────────────────────────
for (const [input, expected] of [
  ['programacion', 'Programación'], ['documentacion', 'Documentación'],
  ['auditoria', 'Auditoría'], ['investigacion', 'investigacion'],
  ['testing', 'Pruebas'], ['diseno', 'Diseño'], ['correccion', 'Corrección'],
]) {
  check(`departmentLabel(${input}) = ${expected}`, departmentLabel(input) === expected, departmentLabel(input));
}

// ── P4: concordancia 1 tarea / N tareas + badge de departamento ─────────
const mc = Object.create(MissionControlPanel.prototype);
mc.events = [];
const one = mc.planTasksMarkup([{ id: 't1', task_type: 'programar', department: 'programacion', description: 'x', contract_fields: [], depends_on: [] }]);
check('concordancia singular «1 tarea»', /Plan propuesto · 1 tarea</.test(one), one.slice(0, 120));
check('no dice «1 tareas»', !/1 tareas/.test(one));
check('badge de departamento traducido', one.includes('>Programación</span>'), one.slice(0, 200));
const many = mc.planTasksMarkup([
  { id: 't1', task_type: 'programar', department: 'programacion', description: 'x', contract_fields: [], depends_on: [] },
  { id: 't2', task_type: 'documentar', department: 'documentacion', description: 'y', contract_fields: [], depends_on: [] },
]);
check('concordancia plural «2 tareas»', /Plan propuesto · 2 tareas</.test(many), many.slice(0, 120));

// ── P7: Monitor, modelo de planificación legible ────────────────────────
const mon = Object.create(MonitorPanel.prototype);
mon.errors = {};
mon.catalog = { model_count: 0 };
mon.status = { running: true, pid: 1, version: '0.1.0', governanceMode: 'free', activeModel: 'auto (router)', activeProvider: '', keyLabel: '', keyCount: 0, providerCount: 0, engineReady: true, initError: '' };
const resumenHtml = mon.renderResumen();
check('el resumen no enseña el crudo «auto (rou…»', !/auto \(rou/.test(resumenHtml), resumenHtml.slice(0, 400));
check('el resumen muestra «Automático (router)»', resumenHtml.includes('Automático (router)'), resumenHtml.slice(0, 400));
mon.status = { ...mon.status, activeModel: 'command-a-reasoning', activeProvider: 'Cohere' };
check('con modelo fijo muestra proveedor / modelo', mon.renderResumen().includes('Cohere / command-a-reasoning'));

// ── P1 (Monitor): estado de sesión traducido, sin `done`/`failed` ───────
const mon2 = Object.create(MonitorPanel.prototype);
mon2.errors = {};
mon2.sessions = [
  { id: 1, title: 'a', status_text: 'done' },
  { id: 2, title: 'b', status_text: 'failed' },
  { id: 3, title: 'c', status_text: 'cancelled' },
];
const sesHtml = mon2.renderSesiones();
check('Monitor no muestra `done` crudo', !/>done</.test(sesHtml) && !sesHtml.includes('badge">done'));
check('Monitor traduce done/failed/cancelled', sesHtml.includes('Hecha') && sesHtml.includes('Fallida') && sesHtml.includes('Cancelada'), sesHtml.replace(/\s+/g, ' ').slice(0, 300));

// ── P5: la política de respaldo ya no es un aviso naranja permanente ────
const prevDocument = global.document;
const children = [];
global.document = {
  createElement: () => ({ style: {}, textContent: '', setAttribute() {}, addEventListener() {}, appendChild(c) { children.push(c); } }),
  dispatchEvent() {},
};
global.CustomEvent = class { constructor(type, { detail }) { this.type = type; this.detail = detail; } };
const host = { style: {}, textContent: '', appendChild(c) { children.push(c); } };
mc.container = { querySelector: (s) => (s === '#order-configuration' ? host : null) };
mc.plan = null;
mc.showConfiguration({ allowed: true, issues: [], message: 'Respaldo: se prueba el siguiente candidato elegible distinto' });
check('política sin conflictos no pinta el texto crudo', host.textContent === '', host.textContent);
check('política sin conflictos no usa el color de aviso', !host.style.cssText.includes('--warning'), host.style.cssText);
check('política sin conflictos queda oculta', host.style.display === 'none', host.style.display);
mc.showConfiguration({ allowed: true, issues: [], message: 'Determinista: si el modelo falla, la orden falla' });
// 11-nov (propietario): «Sin respaldo» ya no es una línea fija bajo el compositor;
// se ve como chip junto a «Modos» (renderModeChips).
check('modelo fijo no repite una línea fija bajo el compositor', host.textContent === '', host.textContent);
check('modelo fijo: la línea queda oculta', host.style.display === 'none', host.style.display);
mc.showConfiguration({ allowed: false, issues: [{ role: 'planificador', provider: 'Cohere', model: 'x', reason: 'sin clave activa', action: 'añade una clave' }], message: '' });
// propietario (10-nov): los conflictos ya no se escriben bajo el chat; son alertas
// de la esquina (design/alerts.ts, probadas en attention.test.cjs).
check('conflicto real ya no se pinta bajo el chat', host.textContent === '' && host.style.display === 'none', host.textContent);

// P2 (corrección auditoría): presupuesto bajo SIN conflictos -> sigue aviso.
mc.plan = null;
mc.showConfiguration({ allowed: true, issues: [], message: '', budget: { authorized: 10, spent: 9, remaining: 1 }, paid_roles: [0, 5, 5] });
check('presupuesto bajo va a la esquina, no bajo el chat', host.textContent === '' && host.style.display === 'none', host.style.display);
global.document = prevDocument;

// ── P6: barra inferior del panel derecho, sin cortar la 4ª pestaña ──────
const fake = { innerHTML: '' };
renderLayout(fake);
check('pestaña Motor abreviada «Salida»', /data-bottom="engine"[^>]*>Salida</.test(fake.innerHTML), 'no encontrada');
check('«Salida» conserva el title completo', /data-bottom="engine"[^>]*title="Salida de diagnóstico del motor"/.test(fake.innerHTML));
check('la 4ª pestaña «Problemas» sigue rotulada completa', /data-bottom="problems"[^>]*>Problemas</.test(fake.innerHTML));

// El CSS de producto aprieta la barra inferior para que quepan las cuatro.
let css = '';
global.document = { createElement: () => ({}), head: { appendChild: (el) => { css = el.textContent; } } };
require('../shell/webui/dist/stylesheet.dsui2.test.cjs').injectStylesheet();
check('CSS reduce el hueco de las pestañas inferiores', /#bottom-tabs \.panel-tabs__list\s*\{\s*gap:\s*7px/.test(css.replace(/\n/g, ' ')), 'sin regla');
check('CSS ajusta el espaciado de las pestañas inferiores sin achicar la letra', /#bottom-tabs \.panel-tab\s*\{[^}]*letter-spacing:\s*0\.04em/.test(css.replace(/\n/g, ' ')) && !/#bottom-tabs \.panel-tab\s*\{[^}]*font-size/.test(css.replace(/\n/g, ' ')), 'sin regla');

(async () => {
  // ── P2/P3: el refresco posterior no se pierde por coincidir con el vigente ─
  let calls = 0;
  const resolvers = [];
  const coalescer = new RefreshCoalescer(() => {
    calls += 1;
    return new Promise((resolve) => resolvers.push(resolve));
  });

  coalescer.request();
  await tick();
  check('P3: la primera petición arranca una lectura', calls === 1, `calls=${calls}`);

  // Llega el refresco posterior (tras crear la orden) mientras hay una en vuelo.
  coalescer.request();
  check('P3: la petición mientras hay una en vuelo queda encolada', coalescer.pending === true);

  // Varias más seguidas no producen ráfagas.
  coalescer.request();
  coalescer.request();
  await tick();
  check('P3: sin ráfagas, sigue habiendo UNA lectura en vuelo', calls === 1, `calls=${calls}`);

  // Termina la primera: corre exactamente UNA más (la encolada).
  resolvers[0]();
  await tick();
  await tick();
  check('P3: al terminar corre exactamente una lectura más', calls === 2, `calls=${calls}`);
  check('P3: ya no queda pendiente', coalescer.pending === false);

  resolvers[1]();
  await tick();
  await tick();
  check('P3: sin peticiones nuevas no hay más lecturas', calls === 2, `calls=${calls}`);

  await approvalCardUi();
  if (failed > 0) { console.error(`DS-UI2 UI TEST: ${failed} FAIL`); process.exitCode = 1; }
  else console.log('DS-UI2 UI TEST PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });

// H13 tarjeta: el panel real, conectado a un puente sintético,
// se monta en el documento de Chromium. No se inicia la cabina ni el motor.
async function approvalCardUi() {
  const fs = require('node:fs');
  const path = require('node:path');
  const { spawn } = require('node:child_process');
  const { resolveBrowser } = require('./browser_resolver.cjs');
  const cache = path.resolve('.zig-cache');
  fs.mkdirSync(cache, { recursive: true });
  const profile = fs.mkdtempSync(path.join(cache, 'seg012-card-'));
  const child = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe',
    `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  const pending = new Map(), errors = [];
  let buffer = '', next = 0, session, stderr = '';
  const fail = error => {
    for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
    pending.clear();
  };
  child.stderr.on('data', data => { stderr += data; });
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown' ||
          (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) errors.push(message);
      const request = pending.get(message.id);
      if (request) {
        clearTimeout(request.timer); pending.delete(message.id);
        message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result);
      }
    }
  });
  const send = (method, params = {}, sessionId = session) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 60000);
    pending.set(id, { resolve, reject, timer });
    child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    await send('Page.enable');
    await send('Emulation.setDeviceMetricsOverride', {width:1400,height:1200,deviceScaleFactor:1,mobile:false});
    const bundle = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/monitor_panel.dsui2.test.cjs'), 'utf8');
    const sheet = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/stylesheet.dsui2.test.cjs'), 'utf8');
    await evaluate(`(() => { const module = {exports:{}}; ${sheet}; module.exports.injectStylesheet(); return true; })()`);
    await evaluate(`(() => { const module = {exports:{}}; ${bundle}; window.MonitorPanel = module.exports.MonitorPanel; return true; })()`);
    const raw = 'inicio\u202Eexe\u2066prefijo\nfin\r\u061C\u200B\0\u206A\\n\\u{202E}<img src=x onerror=alert(1)>';
    await evaluate(`(async () => {
      document.body.innerHTML = '<div id="monitor"></div>';
      window.resolved = [];
      window.cardRows = [{id:701, task_id:'tarea', command_prefix:${JSON.stringify(raw)}, exe:${JSON.stringify(raw)},
        description:'Comando: tool seguro\\\\nvisible · cwd: oculto\u202E\u200B\\nfin', order_id:7},
        {id:702, command_prefix:'worktree_script', args_json:JSON.stringify({script:${JSON.stringify(raw)},script_sha256:'hash'})}];
      const core = {status:async()=>({}), catalogInfo:async()=>({}), listSessions:async()=>[],
        pendingApprovals:async()=>window.cardRows, health:async()=>[], specialists:async()=>[], ledger:async()=>[],
        modelScores:async()=>[], evolution:async()=>({}), resolveApproval:async(id,approved)=>{window.resolved.push([id,approved]);}};
      window.panel = new MonitorPanel(document.getElementById('monitor'),core);
      await window.panel.refresh(); return true;
    })()`);
    const snapshot = await evaluate(`(() => {
      const card = document.querySelector('[data-approve="701"]').closest('.row').parentElement;
      return { text:document.getElementById('monitor').innerText, meta:card.querySelector('.subtle').textContent,
        injected:document.querySelectorAll('#monitor img,#monitor script').length };
    })()`);
    const evidence = process.env.DEVAGENTS_SEG012_EVIDENCE;
    if (evidence) {
      fs.mkdirSync(evidence, {recursive:true});
      fs.writeFileSync(path.join(evidence, 'tarjeta-dom.txt'), snapshot.text);
      const screenshot = await send('Page.captureScreenshot', {format:'png', captureBeyondViewport:true});
      fs.writeFileSync(path.join(evidence, 'tarjeta.png'), Buffer.from(screenshot.data, 'base64'));
    }
    for (const expected of ['\\u{202E}', '\\u{2066}', '\\nfin\\r', '\\u{061C}', '\\u{200B}', '\\u{0000}', '\\u{206A}', '\\\\n', '\\\\u{202E}']) {
      assert(snapshot.meta.includes(expected), `CK-SEG-012 H13 tarjeta muestra ${expected}`);
    }
    assert.doesNotMatch(snapshot.text, /[\u202E\u2066\u061C\u200B\0\u206A]/, 'ningún metadato oculta texto');
    assert(!snapshot.meta.includes('\n') && !snapshot.meta.includes('\r'), 'los saltos son visibles');
    assert.equal(snapshot.injected, 0, 'el saneado conserva el escape HTML');
    assert(snapshot.text.includes('Comando: tool seguro\\nvisible'), 'el comando ya saneado conserva sus barras');
    for (const [selector, expected] of [['[data-approve="701"]',[701,true]], ['[data-reject="702"]',[702,false]]]) {
      const point = await evaluate(`(() => {const el=document.querySelector(${JSON.stringify(selector)}); el.scrollIntoView(); const r=el.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
      for (const type of ['mousePressed','mouseReleased']) await send('Input.dispatchMouseEvent', {type,...point,button:'left',clickCount:1});
      await evaluate('new Promise(r=>setTimeout(r,30))');
      assert.deepEqual(await evaluate('window.resolved.at(-1)'), expected, 'el botón conserva el id y la decisión');
    }
    assert.deepEqual(errors, [], 'sin errores de consola ni excepciones');
    console.log('PASS CK-SEG-012 H13 tarjeta real: metadatos visibles, HTML seguro y decisiones intactas (1/1)');
  } finally {
    if (child.exitCode === null) {
      try { await send('Browser.close', {}, undefined); } catch (error) { if (child.exitCode === null) child.kill(); }
      if (child.exitCode === null) await new Promise(resolve => {
        const timer = setTimeout(() => { child.kill(); resolve(); }, 3000);
        child.once('exit', () => { clearTimeout(timer); resolve(); });
      });
    }
    fail(Error('Browser closed'));
    fs.rmSync(profile, {recursive:true,force:true,maxRetries:10,retryDelay:200});
  }
}
