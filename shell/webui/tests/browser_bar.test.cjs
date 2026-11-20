// Pure model of the integrated browser bar and the breakpoint contract of the
// stylesheet. The bar DOM itself is exercised by tools/test_browser_panel.mjs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => imports[n] ?? {});
  return mod.exports;
}
const model = load('browser_model');
assert.equal(model.controlLabel('agent_control'), 'Tomar control');
assert.equal(model.controlLabel('user_control'), 'Reanudar agente');
assert.equal(model.controlLabel('session_closed'), 'Sin sesión de agente');
assert.equal(model.browserEventText({ request_id: 'r1', tool: 'browser_tabs', state: 'completed', elapsed_ms: 7 }), 'browser_tabs · completed · 7 ms · r1');
assert.equal(model.browserEventText({ request_id: 'r2', tool: 'browser_click', state: 'failed', elapsed_ms: 0, code: 'user_control' }), 'browser_click · failed · 0 ms · user_control · r2');
console.log('PASS E2P2 control humano y eventos correlacionados sin argumentos');

// normalizeAddress: what the user types becomes http(s) or an explained refusal.
const url = text => model.normalizeAddress(text).url;
const error = text => model.normalizeAddress(text).error;
assert.equal(url('localhost:3000'), 'http://localhost:3000');
assert.equal(url('127.0.0.1:5173/app'), 'http://127.0.0.1:5173/app');
assert.equal(url('[::1]:8080'), 'http://[::1]:8080');
assert.equal(url('example.com'), 'https://example.com');
assert.equal(url('https://example.com/a?b=1'), 'https://example.com/a?b=1');
assert.equal(url('about:blank'), 'about:blank');
assert.match(error('javascript://x'), /http o https/);
// 12-nov: un archivo local pasa al host, que solo sirve los de la carpeta de
// la orden por https://preview.local (y rechaza los de fuera).
assert.equal(url('file:///C:/proyecto/index.html'), 'file:///C:/proyecto/index.html');
assert.equal(url('C:/mi proyecto/index.html'), 'C:/mi proyecto/index.html');
assert.equal(url('web/index.html'), 'web/index.html');
assert.equal(url('index.html'), 'index.html');
assert.match(error('data:text/html,hola'), /completa|http/);
assert.match(error('una frase suelta'), /espacios/);
assert.match(error('palabra'), /completa/);
assert.match(error('   '), /Escribe/);
assert.match(error('x'.repeat(9000)), /larga/);
console.log('PASS normalizeAddress: http(s), localhost y rechazos explicados (sin buscador, sin javascript/data; file y rutas locales los decide el host)');

// localAppUrl: «Registrar app» solo acepta un puerto de localhost.
assert.equal(model.localAppUrl('localhost:3000'), 'http://localhost:3000');
assert.equal(model.localAppUrl('http://127.0.0.1:8080/x'), 'http://127.0.0.1:8080/x');
assert.equal(model.localAppUrl('localhost'), null);
assert.equal(model.localAppUrl('example.com:3000'), null);
assert.equal(model.localAppUrl('https://localhost:3000'), null);
assert.equal(model.localAppUrl('localhost:99999'), null);
assert.equal(model.localAppUrl(''), null);
console.log('PASS localAppUrl: solo http en localhost con puerto válido');

// bodyKind mirrors the host's ShowsPage so the card and the page never both show.
const tab = extra => ({ id: 1, title: 't', url: 'http://localhost:3000/', origin: 'http://localhost:3000', trust: 'app', loading: false, ready: true, can_back: false, can_forward: false, error: null, blocked: null, ...extra });
const state = (tabs, extra = {}) => ({ open: true, full: false, ready: true, bar_css: 76, panel_px: 600, active: 1, status: '', status_error: false, tabs, approvals: [], ...extra });
assert.equal(model.bodyKind(state([tab()])), 'page');
assert.equal(model.bodyKind(state([tab({ url: '' })])), 'empty');
assert.equal(model.bodyKind(state([tab({ ready: false })])), 'starting');
assert.equal(model.bodyKind(state([tab({ error: { code: 0, detail: 'net::ERR_X', reason: 'r' } })])), 'error');
assert.equal(model.bodyKind(state([tab({ blocked: { origin: 'o', url: 'u', reason: 'r' } })])), 'blocked');
assert.equal(model.bodyKind(state([tab()], { approvals: [{ id: 'a', origin: 'o', source: 'address' }] })), 'waiting');
assert.equal(model.bodyKind(state([tab({ url: '' })], { ready: false })), 'starting');
console.log('PASS bodyKind: pagina, vacia, iniciando, error, bloqueada y esperando decision');

// Labels never promote page text to markup (the DOM layer escapes; here: no surprises in the model).
assert.equal(model.tabLabel(tab({ url: '', title: 'x' })), 'Nueva pestaña');
assert.equal(model.tabLabel(tab({ title: '' })), 'localhost:3000');
assert.equal(model.tabLabel(tab({ title: '<b>x</b>' })), '<b>x</b>');
assert.equal(model.tabInitial(tab({ title: 'App registrada' })), 'A');
assert.equal(model.tabInitial(tab({ title: '', origin: 'http://127.0.0.1:1' })), '1');
assert.equal(model.tabInitial(tab({ url: '' })), '+');
assert.match(model.sourceLabel('redirect'), /redirección/);
assert.match(model.sourceLabel('page'), /sin que hicieras nada/);
console.log('PASS etiquetas de pestaña y origen de la peticion');

// Breakpoints measure the cabina width left beside the browser column.
assert.equal(model.breakpointFlags(1280, 0), '1400');
assert.equal(model.breakpointFlags(1280, 640), '1400 1100 1024 860 760');
assert.equal(model.breakpointFlags(1920, 960), '1400 1100 1024');
assert.equal(model.breakpointFlags(440, 220), '1400 1100 1024 860 760 620');
assert.equal(model.breakpointFlags(2560, 0), '');
console.log('PASS breakpointFlags: el ancho que queda a la cabina, no el de la ventana');

// The stylesheet no longer keys layout on the viewport width, and the bar is there.
const tokens = load('tokens_browser');
let css = '';
global.document = { getElementById: () => null, createElement: () => ({}), head: { appendChild: el => { css = el.textContent; } } };
load('stylesheet_browser', { './tokens': tokens }).injectStylesheet();
const mediaWidth = [...css.matchAll(/@media \(max-width: (\d+)px\)/g)].map(m => Number(m[1]));
assert.deepEqual(mediaWidth, [860], 'only the titlebar rule still measures the viewport');
for (const limit of model.BREAKPOINTS) assert(css.includes(`html[data-bp~='${limit}']`), `breakpoint ${limit} must be keyed on data-bp`);
for (const needle of ['.bsurf', '.bbar', '.btab', '.bbar__progress', '.bcard', '.bdlg', "[data-browser='open']", 'var(--browser-w']) assert(css.includes(needle), needle);
assert(!/#[0-9a-fA-F]{3,8}\b/.test(css.slice(css.indexOf('Navegador integrado'), css.indexOf('Navegador integrado') + 9000).replace(/rgba\([^)]*\)/g, '')), 'the browser block uses design tokens, no literal colors');
console.log('PASS hoja de estilos: puntos de ruptura por data-bp, bloque del navegador con tokens');

// (12-nov): grafo de la orden calculado solo con eventos del motor.
{
  const graph = load('order_graph', {
    '../bridge/core_api': { eventPayload: (e) => e.payload ?? {} },
    '../design/html': (() => {
      const esc = (v) => String(v).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
      class SafeHtml { constructor(v) { this.value = v; } toString() { return this.value; } }
      const part = (v) => (v instanceof SafeHtml ? v.value : Array.isArray(v) ? v.map(part).join('') : v == null || v === false ? '' : esc(v));
      return {
        SafeHtml,
        html: (strings, ...values) => new SafeHtml(strings.reduce((out, s, i) => out + s + (i < values.length ? part(values[i]) : ''), '')),
        joinHtml: (items) => new SafeHtml(items.map(part).join('')),
      };
    })(),
  });
  const ev = (kind, payload) => ({ id: 0, ts: 0, source: 'motor', kind, payload });
  // Una orden real (835 de la copia de datos tiene ambas cosas): una tarea
  // sustituida que termina y otra que falla, más auditoría y entrega fallida.
  const g = graph.buildOrderGraph([
    ev('order_running', { order_id: 835 }),
    ev('repo_map_built', { archivos: 12 }),
    ev('task_started', { task_id: 't1', description: 'Crear <b>reloj</b>', provider: 'NVIDIA API', model: 'gemma', skills: ['python'], mcps: [] }),
    ev('task_started', { task_id: 't2', description: 'Probar', provider: 'agent:codex', model: 'gpt' }),
    ev('provider_fallback', { task_id: 't1', from_provider: 'NVIDIA API', from_model: 'gemma', to_provider: 'NVIDIA API', to_model: 'nemotron' }),
    ev('task_done', { task_id: 't1', success: true, model_used: 'nemotron' }),
    ev('task_failed', { task_id: 't2', error_msg: 'Codex falló' }),
    ev('task_audit', { task_id: 1, verdict: 'PASS' }),
    ev('order_failed', { reason: 'Una tarea falló' }),
  ], [{ id: 't3', description: 'Entregar' }], { orderId: 835 });
  const state = (key) => g.tasks.find((n) => n.key === key).state;
  assert.equal(state('t1'), 'substituted');
  assert.match(g.tasks.find((n) => n.key === 't1').detail, /gemma → NVIDIA API \/ nemotron/);
  assert.equal(state('t2'), 'failed');
  assert.equal(state('t3'), 'waiting');
  assert.deepEqual(g.before.map((n) => n.state), ['done', 'done']);
  assert.match(g.before[0].detail, /12 archivos.*Skills: python/);
  assert.deepEqual(g.after.map((n) => [n.key, n.state]), [['audit', 'done'], ['delivery', 'failed']]);
  const markup = String(graph.orderGraphMarkup(g));
  assert.equal((markup.match(/data-graph-act="retry"/g) || []).length, 2, 'Reintentar en la tarea fallida y en la entrega fallida');
  assert.ok(!markup.includes('<b>reloj</b>'), 'el texto del evento se escapa');
  // 12-nov: el grafo sigue la maqueta v2 pág. 3: carriles, raíz, roles y nodos omitidos.
  for (const lane of ['CONTEXTO', 'PLAN', 'TAREAS POR ROL', 'AUDITORÍA', 'CIERRE']) assert.ok(markup.includes(`>${lane}</text>`), lane);
  assert.ok(markup.includes('>Orden #835</text>') || markup.includes('>Orden</text>'), 'nodo raíz');
  assert.ok(markup.includes('data-graph-node="ctx-memory"') && markup.includes('data-state="skip"'), 'la memoria sin eventos sale como omitida');
  assert.ok(markup.includes('>PLANIFICADOR</text>'), 'rol del plan');
  assert.ok(markup.includes('class="ograph__legend"') && markup.includes('class="ograph__detail"'), 'leyenda y detalle');
  const dots = String(graph.orderDotsMarkup(g));
  assert.equal((dots.match(/class="ograph__dot"/g) || []).length, 7);
  // En curso: sin final, la tarea empezada va en azul y la entrega también.
  const live = graph.buildOrderGraph([ev('order_running', {}), ev('task_started', { task_id: 't1' })]);
  assert.equal(live.tasks[0].state, 'running');
  assert.equal(live.after[1].state, 'running');
  console.log('PASS CK-PUB-007 grafo: sustituto amarillo con su cambio, fallo rojo con acciones, espera gris, en curso azul, texto escapado y tira de puntos');

  // USUARIO-NUEVO B (10-nov): las subtareas delegadas en el grafo, con los
  // eventos reales de la conversación; sin plan, el nodo Plan sale omitido.
  const T0 = 1788856878000;
  const tev = (kind, payload, ts) => ({ id: 0, ts, source: 'motor', kind, payload });
  const d = graph.buildOrderGraph([
    tev('directo_started_v1', { delegate: true }, T0),
    tev('delegation_started_v1', { subtasks: [
      { index: 1, role: 'Programación', instruction: 'api', child_order_id: 5, model: null, setup_error: null },
      { index: 2, role: 'Documentación', instruction: 'guía', child_order_id: 6, model: null, setup_error: null },
      { index: 3, role: 'Pruebas', instruction: 'tests', child_order_id: 7, model: null, setup_error: null },
    ] }, T0 + 1000),
    tev('delegation_subtask_finished_v1', { index: 1, role: 'Programación', status: 'done', verdict: 'PASS', model: 'org/m-prog:free' }, T0 + 30000),
    tev('delegation_subtask_finished_v1', { index: 2, role: 'Documentación', status: 'failed', verdict: 'sin auditar', model: 'm-doc', error: 'sin archivo' }, T0 + 31000),
    tev('delegation_subtask_finished_v1', { index: 3, role: 'Pruebas', status: 'cancelled', verdict: 'sin auditar', model: '' }, T0 + 32000),
    tev('order_done', {}, T0 + 40000),
  ], [], { orderId: 900 });
  assert.deepEqual(d.tasks.map((n) => [n.key, n.state]), [['d1', 'done'], ['d2', 'failed'], ['d3', 'skip']]);
  assert.equal(d.before[1].state, 'skip', 'DevAgents no planifica: el nodo Plan sale omitido');
  assert.match(d.before[1].detail, /delegó 3 subtarea/);
  assert.match(d.tasks[1].detail, /sin archivo/);
  assert.match(d.tasks[2].detail, /Cancelada con «Detener»/);
  assert.equal(d.view.mode, 'DevAgents (Directo + delegación)');
  assert.deepEqual(d.view.groups.map((g) => g.length), [3], 'las tres corrieron a la vez: un grupo');
  assert.ok(d.view.tasks.some((n) => n.role === 'PROGRAMACIÓN' && n.sub.startsWith('m-prog:free')), JSON.stringify(d.view.tasks));
  assert.equal(d.view.audits[0].state, 'done', 'el veredicto PASS de su auditor llega al carril de auditoría');
  const dm = String(graph.orderGraphMarkup(d));
  assert.ok(dm.includes('data-graph-node="d3"'), 'la subtarea cancelada se dibuja');
  console.log('PASS USUARIO-NUEVO B grafo: subtareas delegadas con sus eventos, cancelada omitida y plan omitido');

  // T8: eventos reales del motor → nodos; sin evento → «omitido».
  const T1 = 1794000000000;
  const real = graph.buildOrderGraph([
    tev('composer_swarm_v1', true, T1),
    tev('order_running', {}, T1),
    tev('memory_lessons_v1', { count: 3, titles: ['all_tasks_failed: calculadora', '<img src=x onerror=alert(1)>'], source: 'lista' }, T1 + 500),
    tev('replan_v1', { reason: 'user_changes', from_plan_id: 1, to_plan_id: 2, same_row: true, tasks: 3, changes: 'usa azul <script>alert(1)</script>' }, T1 + 800),
    tev('task_started', { task_id: 't1', task_type: 'investigar', description: 'Investigar API' }, T1 + 1000),
    tev('sidekick_task_v1', { task_id: 't1', kind: 'investigar', provider: 'OpenRouter', model: 'claude-fixture' }, T1 + 1000),
    tev('task_done', { task_id: 't1', success: true }, T1 + 9000),
    // t2 empieza cerca de t1 y t3 mucho después: la ola paralela la dice el motor (t2+t3).
    tev('swarm_group_v1', { wave: 2, members: ['t2', 't3'], size: 2, parallel: true }, T1 + 1500),
    tev('task_started', { task_id: 't2', task_type: 'programar', description: 'API' }, T1 + 2000),
    tev('task_started', { task_id: 't3', task_type: 'investigar', description: 'Docs' }, T1 + 70000),
    tev('task_done', { task_id: 't2', success: true }, T1 + 80000),
    tev('task_done', { task_id: 't3', success: true }, T1 + 90000),
    tev('task_audit', { task_id: 2, verdict: 'PASS', provider: 'OpenAI', model: 'gpt-x', auditor_index: 1, role: 'audit' }, T1 + 95000),
    tev('task_audit', { task_id: 2, verdict: 'FAIL', provider: 'Google', model: 'gem-<b>x</b>', auditor_index: 2, role: 'second_audit' }, T1 + 96000),
    tev('memory_lesson_saved_v1', { title: 'execution_failed: calculadora' }, T1 + 97000),
    tev('order_done', {}, T1 + 99000),
  ], [], { orderId: 950 });
  const rv = real.view;
  assert.equal(rv.context[0].state, 'done', 'Memoria con lecciones consultadas');
  assert.match(rv.context[0].sub, /3 lecciones consultadas · 1 guardada/);
  assert.match(rv.context[0].detail, /y 1 más/);
  assert.deepEqual(rv.groups.map((g) => g.map((k) => rv.tasks[k].key)), [['t2', 't3']], 'la colmena son los miembros del evento, no la cercanía de horas');
  assert.equal(rv.hiveNote, '');
  assert.equal(rv.tasks.find((n) => n.key === 't1').role, 'SIDEKICK', 'sidekick solo por sidekick_task_v1');
  const replaced = graph.buildOrderGraph([
    tev('task_started', { task_id: 't1', task_type: 'investigar', provider: 'OpenRouter', model: 'old-sidekick' }, T1),
    tev('sidekick_task_v1', { task_id: 't1', kind: 'investigar', provider: 'Google', model: 'actual-after-quota' }, T1 + 1000),
    tev('task_done', { task_id: 't1', success: true }, T1 + 9000),
  ], [], { orderId: 951 });
  assert.equal(replaced.view.tasks[0].role, 'SIDEKICK');
  assert.match(replaced.view.tasks[0].sub, /actual-after-quota/);
  assert.ok(!JSON.stringify(replaced.view.tasks).includes('old-sidekick'));
  assert.equal(rv.tasks.find((n) => n.key === 't3').role, 'INVESTIGACIÓN', 'investigar sin evento no es sidekick');
  assert.equal(rv.audits.length, 2);
  assert.deepEqual(rv.audits.map((a) => [a.role, a.state]), [['AUDITOR', 'done'], ['SEGUNDO AUDITOR', 'failed']]);
  assert.deepEqual(rv.secondAudited, ['t2']);
  assert.equal(rv.replans.length, 1);
  assert.match(rv.plan.sub, /replan ×1/);
  assert.match(rv.plan.detail, /cambios pedidos por el usuario/);
  const rm = String(graph.orderGraphMarkup(real));
  assert.ok(rm.includes('data-graph-loop="plan"') && rm.includes('REPLAN ×1'), 'lazo del plan a sí mismo');
  assert.ok(rm.includes('>SEGUNDO AUDITOR</text>') && rm.includes('data-graph-node="audit-1"'), 'segundo auditor como nodo propio');
  assert.ok(rm.includes('>COLMENA · 2 EN PARALELO</text>'));
  // lo que viene en los eventos se pinta como texto.
  for (const hostile of ['<img src=x', '<script>', '<b>x</b>']) assert.ok(!rm.includes(hostile), `escapado: ${hostile}`);
  assert.ok(rm.includes('&#60;img src=x onerror=alert(1)&#62;'), 'el título hostil llega como texto visible');

  // Sin eventos nuevos (orden anterior): todo «omitido», nada inventado.
  const old = graph.buildOrderGraph([
    tev('composer_swarm_v1', true, T1),
    tev('order_running', {}, T1),
    tev('task_started', { task_id: 't1', task_type: 'investigar' }, T1 + 1000),
    tev('task_started', { task_id: 't2', task_type: 'programar' }, T1 + 1200),
    tev('task_done', { task_id: 't1', success: true }, T1 + 5000),
    tev('task_done', { task_id: 't2', success: true }, T1 + 6000),
    tev('task_audit', { task_id: 1, verdict: 'PASS', provider: 'OpenAI', model: 'a' }, T1 + 7000),
    tev('task_audit', { task_id: 2, verdict: 'PASS', provider: 'Google', model: 'b' }, T1 + 7500),
    tev('order_done', {}, T1 + 8000),
  ], [], { orderId: 951 });
  const ov = old.view;
  assert.equal(ov.context[0].state, 'skip');
  assert.match(ov.context[0].detail, /Omitida/);
  assert.deepEqual(ov.groups, [], 'sin swarm_group_v1 no hay grupo aunque empezaran a la vez');
  assert.match(ov.hiveNote, /no registró/);
  assert.ok(String(graph.orderGraphMarkup(old)).includes('COLMENA · OMITIDA'));
  assert.ok(!ov.tasks.some((n) => n.role === 'SIDEKICK'));
  assert.deepEqual(ov.audits.map((a) => [a.key, a.state]), [['audit-0', 'done'], ['audit-1', 'skip']], 'sin auditor_index 2 el segundo auditor sale omitido');
  assert.match(ov.audits[0].sub, /a, b/);
  assert.equal(ov.replans.length, 0);
  assert.ok(!String(graph.orderGraphMarkup(old)).includes('data-graph-loop'));
  console.log('PASS T8 grafo: memoria, colmena por evento, sidekick, segundo auditor y replan desde eventos; sin evento, omitido; texto hostil escapado');
}
