// product rendering on engine push, without a DOM emulator.
const assert = require('node:assert/strict');
const path = require('node:path');
const { buildSync } = require('esbuild');
const source = path.join(__dirname, '../src/panes/monitor_panel.ts');
const compiled = buildSync({ entryPoints: [source], bundle: true, write: false, platform: 'node', format: 'cjs' });
const product = { exports: {} };
new Function('module', 'exports', 'require', compiled.outputFiles[0].text)(product, product.exports, require);
const { MonitorPanel } = product.exports;
// 10-nov: los refrescos automáticos pasan por un temporizador agrupado.
const tick = (ms = 5) => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  let handler, title = 'before', reads = 0, release;
  const core = {
    status: async () => { reads++; if (release) await new Promise(resolve => { release = resolve; }); return {}; },
    catalogInfo: async () => ({}), listSessions: async () => [{ id: 16, title }],
    pendingApprovals: async () => [], health: async () => [], specialists: async () => [],
    ledger: async () => [], modelScores: async () => [], evolution: async () => ({}),
  };
  global.window = { setInterval: () => 1, clearInterval() {}, setTimeout, clearTimeout };
  let paints = 0, html = '';
  const container = { scrollTop: 0, querySelector: () => null, querySelectorAll: () => [],
    addEventListener() {}, getClientRects: () => [1],
    get innerHTML() { return html; }, set innerHTML(v) { paints++; html = v; } };
  const push = { onPush(fn) { handler = fn; return () => {}; } };
  const panel = new MonitorPanel(container, core, push);
  assert.equal(typeof handler, 'function', 'monitor must subscribe to product bridge pushes');
  panel.startAutoRefresh(30);
  await panel.refresh();
  title = 'CAB016_ACTIVITY_AFTER_PRIMARY_CLOSE';
  const before = reads;
  handler('engine.changed', { kind: 'core.session.fixture' });
  await tick();
  assert.ok(reads > before, 'push must trigger a motor read without waiting for interval');
  assert.match(container.innerHTML, /CAB016_ACTIVITY_AFTER_PRIMARY_CLOSE/, 'fresh activity must be painted');
  const idle = reads;
  handler('doc.saved', {});
  await tick();
  assert.equal(reads, idle, 'unrelated pushes do not reload the monitor');
  panel.stopAutoRefresh();
  handler('engine.changed', {});
  await tick();
  assert.equal(reads, idle, 'paused or hidden monitor does not reload');
  panel.startAutoRefresh(30);
  await tick(40);
  release = true;
  const pending = panel.refresh();
  title = 'CAB016_ACTIVITY_DURING_REFRESH';
  handler('engine.changed', {});
  handler('engine.changed', {});
  const resolve = release;
  release = null;
  resolve();
  await pending;
  await tick(60);
  assert.equal(reads, idle + 2, 'pushes during refresh coalesce into one trailing read');
  assert.match(container.innerHTML, /CAB016_ACTIVITY_DURING_REFRESH/);
  // 10-nov (propietario: «actualizaba cada microsegundo»): una ráfaga de avisos
  // del motor da UNA lectura por intervalo, y datos idénticos no repintan.
  await tick(40);
  const burst = reads, paintsBefore = paints;
  for (let i = 0; i < 10; i++) handler('engine.changed', {});
  await tick(60);
  assert.equal(reads, burst + 1, 'a burst of 10 engine pushes yields one motor read');
  assert.equal(paints, paintsBefore, 'identical data does not rebuild the panel');
  panel.stopAutoRefresh();

  // el botón ⧉ publica la petición donde escucha main.ts (document).
  const buttons = {};
  const docEvents = [], winEvents = [];
  global.CustomEvent = class { constructor(type, init) { this.type = type; this.detail = init?.detail; } };
  global.document = { dispatchEvent: (e) => { docEvents.push(e); return true; } };
  global.window.dispatchEvent = (e) => { winEvents.push(e); return true; };
  const bound = { innerHTML: '', scrollTop: 0, querySelectorAll: () => [], addEventListener() {}, getClientRects: () => [1],
    querySelector: (sel) => (buttons[sel] ||= { addEventListener(type, fn) { this[type] = fn; } }) };
  const panel2 = new MonitorPanel(bound, core, push);
  await panel2.refresh();
  assert.equal(typeof buttons['#mon-popout']?.click, 'function', 'the popout button must be wired');
  buttons['#mon-popout'].click();
  assert.deepEqual(docEvents.map(e => [e.type, e.detail?.vista]), [['devagents:open-window', 'monitor']],
    'popout request must reach document, where main.ts listens');
  assert.equal(winEvents.length, 0, 'nothing is published on window (main.ts does not listen there)');
  panel2.stopAutoRefresh();
  console.log('PASS CK-CAB-016: engine push paints activity; pause, filtering and in-flight coalescing; burst = one read, identical data = no repaint; popout reaches main');
})().catch(error => { console.error(error); process.exitCode = 1; });
