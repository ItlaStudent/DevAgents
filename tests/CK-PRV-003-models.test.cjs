const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../shell/webui/dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => imports[n] ?? {});
  return mod.exports;
}
const { MissionControlPanel } = load('mission_control_ux', {
  '../bridge/core_api': load('core_api_prv004'),
  './order_graph': load('order_graph_ux', { '../bridge/core_api': { eventPayload: (e) => e.payload ?? {} }, '../design/html': load('html_ux') }),
  '../design/html': load('html_ux'),
  '../external_models': load('external_models'),
  '../design/notice': { notice() {} },
  '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
  '../design/orbit_backdrop': { orbitBackdrop: () => '' },
});
global.window = { localStorage: { getItem: () => null, setItem() {} } };
function panel(elements = {}) {
  const p = Object.create(MissionControlPanel.prototype);
  Object.assign(p, { container: { querySelector: s => elements[s] ?? null, querySelectorAll: () => [] },
    modelRows: [], pinnedRoles: { plan: '', exec: '', audit: '' }, swarmSelection: [], modelQuery: '' });
  return p;
}
test('C2 Automático siempre visible incluso sin catálogo y con búsqueda', () => {
  const host = { innerHTML: '', querySelectorAll: () => [] };
  const p = panel({ '#model-list': host });
  p.modelQuery = 'no coincide'; p.renderSwarmList = () => {};
  p.renderModelList();
  assert.match(host.innerHTML, /data-val=""[^>]*>[\s\S]*?Automático/);
});
test('C2 volver a Automático limpia también una selección CLI del ejecutor', async () => {
  const p = panel(); const calls = [];
  p.pinnedRoles.exec = 'agent:opencode|x-free';
  p.core = { setPlanModel: async (...v) => calls.push(['plan', ...v]), setExecModel: async (...v) => calls.push(['exec', ...v]) };
  await p.applyOrderModelChoice('', '');
  assert.deepEqual(calls, [['plan', '', ''], ['exec', '', '']]);
});
test('C2 selector único y + rol ofrece los cinco roles sin filas fijas', () => {
  const p = panel(); p.bindShell = () => {}; p.renderBody = () => {}; p.render();
  assert.match(p.container.innerHTML, /id="btn-add-role"/);
  assert.match(p.container.innerHTML, /for="sel-model">Modelo de la orden</);
  assert.doesNotMatch(p.container.innerHTML, /id="sel-model-exec"|id="sel-model-audit"/);
  for (const role of ['Ejecutor', 'Auditor', 'Segundo auditor', 'Programador', 'Sidekick']) assert(p.container.innerHTML.includes(role));
});
test('P1-a C3 los pines no anticipan el resultado de la asignación efectiva', () => {
  const summary = {}, warning = {};
  const p = panel({ '#model-detail-pins': summary, '#model-audit-warning': warning });
  p.pinnedRoles = { plan: 'HTTP|x', exec: '', audit: 'HTTP|x' };
  p.renderPinSummary(); assert.match(warning.textContent, /Revisión por decidir/); assert.doesNotMatch(warning.textContent, /Autorrevisada|Auditada/);
  p.pinnedRoles.audit = ''; p.renderPinSummary(); assert.match(warning.textContent, /Revisión por decidir/);
});

test('P1-a C3 la orden usa solo el último evento del motor sobre modelos efectivos', () => {
  const p = panel(); p.orderId = 7; p.phase = 'running'; p.orderPin = '';
  p.events = [];
  assert.match(p.orderPinBadge(), /Revisión por decidir/);
  p.events = [{ kind: 'composer_review_v1', payload: { mode: 'independent_pending', label: 'Auditor independiente asignado' } }];
  assert.match(p.orderPinBadge(), /Auditor independiente asignado/);
  assert.doesNotMatch(p.orderPinBadge(), /Autorrevisada|Auditada/);
  p.events.push({ kind: 'composer_review_v1', payload: { mode: 'self_reviewed', label: 'Autorrevisada' } });
  assert.match(p.orderPinBadge(), /Autorrevisada/);
  assert.doesNotMatch(p.orderPinBadge(), /Auditada/);
  p.events.push({ kind: 'plan_edited', payload: {} });
  assert.match(p.orderPinBadge(), /Revisión por decidir/);
});
test('C4 Sin respaldo permanece independiente de los pines', () => {
  const chk = { checked: true, disabled: false }, lbl = { style: {} };
  const p = panel({ '#chk-deterministic': chk, '#lbl-deterministic': lbl });
  p.core = { setDeterministic: () => { throw Error('No debe apagarlo'); } };
  p.syncDeterministicAvailability(false);
  assert.equal(chk.disabled, false); assert.equal(chk.checked, true);
  p.bindShell = () => {}; p.renderBody = () => {}; p.render();
  assert.match(p.container.innerHTML, /Sin respaldo/);
});

test('C2 roles usan los pines existentes y se pueden quitar sin alterar enjambre', async () => {
  const p = panel(); const calls = [];
  p.refreshModelPickers = async () => {};
  p.swarmSelection = ['HTTP|a', 'HTTP|b']; p.swarmEnabled = true;
  p.core = { setExecModel: async (...v) => calls.push(['exec', ...v]),
    setAuditModel: async (...v) => calls.push(['audit', ...v]),
    setRoleModel: async (...v) => calls.push(v) };
  for (const role of ['exec', 'audit', 'second_audit', 'programmer', 'sidekick']) {
    await p.applyRoleModel(role, 'HTTP|a'); await p.applyRoleModel(role, '');
    assert.deepEqual(calls.slice(-2), [[role, 'HTTP', 'a'], [role, '', '']]);
  }
  assert.deepEqual(p.swarmSelection, ['HTTP|a', 'HTTP|b']); assert.equal(p.swarmEnabled, true);
});

test('C5 todos los roles usan la visibilidad, gratuidad y capacidad de CK-PRV-004', async () => {
  const select = { innerHTML: '', dataset: {} };
  const p = panel({ '#sel-model': select });
  p.core = {
    listProviders: async () => [{ name: 'HTTP', models: [
      { name: 'free-chat', is_free: true }, { name: 'paid-chat', is_free: false },
      { name: 'hidden-chat', is_free: true }, { name: 'embedding', is_free: true, text_gen: false },
    ] }], getPlanModel: async () => ({}), getExecModel: async () => ({}), getAuditModel: async () => ({}),
    getSwarmModels: async () => [], getGovernance: async () => ({ mode: 'free' }), getExternalAgents: async () => [],
    modelSelection: async () => [{ provider: 'HTTP', model: 'hidden-chat', show_in_selectors: false }],
    orderPreflight: async () => ({ allowed: true, issues: [], message: '' }),
  };
  for (const m of ['syncSwarmControls', 'updateModelChip', 'renderPinSummary', 'renderModelList', 'renderExternalDetail', 'showConfiguration', 'syncDeterministicAvailability']) p[m] = () => {};
  await p.refreshModelPickers();
  assert.match(select.innerHTML, /free-chat/);
  assert.doesNotMatch(select.innerHTML, /paid-chat|hidden-chat|embedding/);
  for (const role of ['exec', 'audit', 'second_audit', 'programmer', 'sidekick']) {
    const html = p.roleOptions('', 'Automático', role);
    assert.match(html, /free-chat/); assert.doesNotMatch(html, /paid-chat|hidden-chat|embedding/);
  }
});
