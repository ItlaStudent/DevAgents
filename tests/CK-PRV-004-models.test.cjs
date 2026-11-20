const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { externalModelRows } = require('../shell/webui/dist/external_models.test.cjs');
global.document = { dispatchEvent: () => {} };
function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../shell/webui/dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => imports[n] ?? {});
  return mod.exports;
}
const { MissionControlPanel } = load('mission_control_ux', {
  '../design/html': load('html_ux'),
  '../design/notice': { notice: () => {} },
  '../external_models': { externalModelRows },
  '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
});
const agent = { provider: 'agent:opencode', cli: 'opencode', display: 'OpenCode', session: 'suscripcion', models: [
  { slug: 'opencode/chat-free', display_name: 'Chat', free: true, text_gen: true },
  { slug: 'opencode/paid', display_name: 'Paid', free: false, text_gen: true },
  { slug: 'opencode/bge-m3-free', display_name: 'Embedding', free: true, text_gen: false },
  { slug: 'opencode/flux-free', display_name: 'Image', free: true, text_gen: false },
  { slug: 'opencode/studiovoice-free', display_name: 'Voice', free: true, text_gen: false },
] };
function panel(mode = 'free', agents = [agent]) {
  const select = { innerHTML: '', dataset: {} };
  const p = Object.create(MissionControlPanel.prototype);
  Object.assign(p, { core: {
    listProviders: async () => [{ name: 'HTTP', models: [{ name: 'free-chat', is_free: true }, { name: 'paid-chat', is_free: false }, { name: 'embed', is_free: true, text_gen: false }] }],
    getPlanModel: async () => ({}), getExecModel: async () => ({}), getAuditModel: async () => ({}), getSwarmModels: async () => [],
    getGovernance: async () => ({ mode }), getExternalAgents: async () => agents,
    modelSelection: async () => [],
    orderPreflight: async () => ({ issues: [] }),
  }, container: { querySelector: s => s === '#sel-model' ? select : null }, swarmSelection: [] });
  for (const m of ['syncSwarmControls', 'updateModelChip', 'renderPinSummary', 'renderModelList', 'renderExternalDetail', 'showConfiguration', 'syncDeterministicAvailability']) p[m] = () => {};
  return p;
}
test('CK-PRV-004 C2 external rows exclude embeddings image and voice', () => {
  assert.deepEqual(externalModelRows([agent]).map(r => r.model), ['opencode/chat-free', 'opencode/paid']);
});
test('CK-PRV-004 C3 Solo gratis excludes paid HTTP and agent:opencode rows', async () => {
  const p = panel();
  await p.refreshModelPickers();
  assert.deepEqual(p.modelRows.map(r => r.model).sort(), ['free-chat', 'opencode/chat-free']);
});
test('CK-PRV-004 C3 hybrid keeps paid chat and subscription CLI remains eligible', async () => {
  const codex = { ...agent, provider: 'agent:codex', cli: 'codex', models: [{ slug: 'gpt-fixture', display_name: 'GPT' }] };
  const p = panel('free', [codex]);
  await p.refreshModelPickers();
  assert(p.modelRows.some(r => r.model === 'gpt-fixture'));
  const hybrid = panel('hybrid');
  await hybrid.refreshModelPickers();
  assert(hybrid.modelRows.some(r => r.model === 'opencode/paid'));
});

test('CK-PRV-004 C4 persistent selection visibility filters choices and preserves a manual pin', async () => {
  const p = panel('hybrid');
  p.core.modelSelection = async () => [{ provider: 'HTTP', model: 'free-chat', text_gen: true, is_free: true, show_in_selectors: false, allow_automatic: true }];
  p.core.getExecModel = async () => ({ provider: 'HTTP', model: 'free-chat' });
  p.core.getSwarmModels = async () => [{ provider: 'HTTP', model: 'free-chat' }];
  await p.refreshModelPickers();
  assert(!p.modelRows.some(r => r.model === 'free-chat'));
  assert.equal(p.pinnedRoles.exec, 'HTTP|free-chat');
  assert(!p.swarmBlocked.includes('HTTP|free-chat'), 'hiding a selector must not veto an allowed persisted swarm member');
});
const { UnifiedSettingsPanel: SettingsMemoryPanel } = load('settings_prv004', {
  '../design/html': load('html_ux'),
  '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
});
test('CK-PRV-004 C4 settings exposes both persistent switches with pin explanation', () => {
  const p = Object.create(SettingsMemoryPanel.prototype);
  Object.assign(p, { providers: [{ name: 'HTTP', models: [{ name: 'chat', is_free: true }] }], selectionRows: [], externalModels: [], planModel: {}, modelsFilter: '', modelsMsg: null, modelsError: null, catalog: null });
  const markup = p.modelsMarkup();
  assert.match(markup, /Mostrar en selectores/);
  assert.match(markup, /Permitir al router y al enjambre/);
  assert.match(markup, /fijado a mano/);
  assert.equal((markup.match(/class="model-preference-toggle"/g) || []).length, 2);
});
test('CK-PRV-004 C5 settings saves then shows the core independent-auditor warning', async () => {
  const p = Object.create(SettingsMemoryPanel.prototype);
  const callbacks = {};
  const input = { dataset: { provider: 'HTTP', model: 'chat', field: 'allow_automatic' }, checked: false, disabled: false, addEventListener: (event, cb) => callbacks[event] = cb };
  const body = { querySelectorAll: selector => selector === '.model-preference-toggle' ? [input] : [], querySelector: () => null };
  const calls = [];
  Object.assign(p, { providers: [{ name: 'HTTP', models: [{ name: 'chat' }] }], externalModels: [], selectionRows: [{ provider: 'HTTP', model: 'chat', show_in_selectors: true, allow_automatic: true }], modelsFilter: '', core: {
    setModelPreferences: async (...args) => { calls.push(args); return { issues: [{ cause: 'audit_unavailable_by_preferences', reason: 'Los vetos dejan sin auditor independiente', action: 'Permite un modelo de otro fabricante' }] }; },
  } });
  p.setSectionMarkup = () => {};
  p.modelsMarkup = () => '';
  p.bindModelsEvents = () => {};
  assert.equal(typeof p.bindModelPreferenceToggles, 'function');
  p.bindModelPreferenceToggles(body);
  await callbacks.change();
  assert.deepEqual(calls, [['HTTP', 'chat', true, false]]);
  assert.match(p.modelsMsg.text, /sin auditor independiente/);
});
const { CoreApi } = load('core_api_prv004');
test('CK-PRV-004 C4 typed bridge serializes both independent switches and propagates failures', async () => {
  const calls = [];
  const api = new CoreApi({ send: async (kind, payload) => { calls.push([kind, payload]); return { payload: kind === 'core.models.selection.v1' ? [] : { issues: [], allowed: true } }; } });
  assert.deepEqual(await api.modelSelection(), []);
  await api.setModelPreferences('HTTP', 'chat', false, true);
  assert.deepEqual(calls[1], ['core.models.preferences.set.v1', { provider: 'HTTP', model: 'chat', show_in_selectors: false, allow_automatic: true }]);
  const failed = new CoreApi({ send: async () => ({ error: 'storage failure' }) });
  await assert.rejects(() => failed.setModelPreferences('HTTP', 'chat', true, false), /storage failure/);
  const malformed = new CoreApi({ send: async () => ({ payload: {} }) });
  await assert.rejects(() => malformed.modelSelection(), /inválidos/);
});
test('CK-PRV-004 C2 all role selects honor explicit negative text capability', async () => {
  const p = panel('hybrid', []);
  p.core.modelSelection = async () => [{ provider: 'HTTP', model: 'paid-chat', text_gen: false, is_free: false, show_in_selectors: true, allow_automatic: true }];
  const selects = new Map(['#sel-model', '#sel-model-exec', '#sel-model-audit'].map(id => [id, { id: id.slice(1), innerHTML: '', dataset: {} }]));
  p.container.querySelector = id => selects.get(id) || null;
  await p.refreshModelPickers();
  for (const select of selects.values()) assert(!select.innerHTML.includes('paid-chat'));
});

test('CK-PRV-004 r2-1 warning remains visible and submit reaches the core', async () => {
  const p = panel();
  const host = { style: {}, textContent: '' };
  p.container.querySelector = s => s === '#order-configuration' ? host : null;
  p.showConfiguration = MissionControlPanel.prototype.showConfiguration;
  const check = { allowed: true, message: '', issues: [{ severity: 'warn', role: 'auditor', provider: 'Cohere', model: 'command-a', cause: 'audit_unavailable_by_preferences', reason: 'Los vetos dejan sin auditor independiente', action: 'Permite otro fabricante' }] };
  let submitted = false;
  Object.assign(p, { phase: 'idle', orderEpoch: 0, turns: [], pinnedRoles: {}, hooks: {} });
  p.core.orderPreflight = async () => check;
  p.core.submitOrder = async () => { submitted = true; return { orderId: 19 }; };
  for (const m of ['archiveCurrentOrder', 'toggleCancel', 'renderBody', 'waitForPlan']) p[m] = () => {};
  p.setPhase = phase => p.phase = phase;
  await p.submit('orden de prueba');
  assert.equal(submitted, true);
  assert.equal(p.orderId, 19);
  assert.match(host.textContent, /sin auditor independiente/);
  assert.match(host.textContent, /Puedes enviar la orden sin auditoría/);
  assert.equal(host.style.display, '');
});
